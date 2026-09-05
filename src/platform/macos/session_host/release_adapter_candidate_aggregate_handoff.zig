//! Atomically promotes evidence and four local attestation bundles out of ephemeral roots.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const evidence_mod = @import("release_evidence");
const bundle_contract = @import("release_adapter_attestation_bundle_contract");
const files = @import("release_adapter_files");
const safe_open = @import("safe_open");

extern "c" fn renameatx_np(from_dir_fd: c_int, from: [*:0]const u8, to_dir_fd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
const rename_excl: c_uint = 0x00000004;

pub const max_attestation_bundle_bytes: u64 = bundle_contract.max_bytes;
pub const max_aggregate_bytes: u64 = evidence_mod.max_evidence_bytes + 4 * max_attestation_bundle_bytes;
pub const role_count: usize = 5;

pub const Error = files.Error || error{
    InvalidPath,
    SourceChanged,
    AggregateTooLarge,
    CleanupFailed,
    DescriptorCloseFailed,
};
const TestError = Error || error{InjectedFailure};

pub const Role = enum(u3) {
    evidence,
    candidate_dmg_bundle,
    candidate_frozen_bundle,
    evidence_bundle,
    manifest_bundle,
};

const bundle_names = [_][]const u8{
    "candidate-dmg.attestation.json",
    "candidate-frozen.attestation.json",
    "evidence.attestation.json",
    "manifest.attestation.json",
};

pub fn destinationName(role: Role, evidence_name: []const u8) []const u8 {
    return switch (role) {
        .evidence => evidence_name,
        .candidate_dmg_bundle => bundle_names[0],
        .candidate_frozen_bundle => bundle_names[1],
        .evidence_bundle => bundle_names[2],
        .manifest_bundle => bundle_names[3],
    };
}

pub const Source = struct {
    file: *const files.PinnedReleaseFile,
    root: [:0]const u8,
    path: [:0]const u8,
};

pub const Sources = struct {
    evidence: Source,
    candidate_dmg_bundle: Source,
    candidate_frozen_bundle: Source,
    evidence_bundle: Source,
    manifest_bundle: Source,

    pub fn at(self: @This(), role: Role) Source {
        return switch (role) {
            .evidence => self.evidence,
            .candidate_dmg_bundle => self.candidate_dmg_bundle,
            .candidate_frozen_bundle => self.candidate_frozen_bundle,
            .evidence_bundle => self.evidence_bundle,
            .manifest_bundle => self.manifest_bundle,
        };
    }
};

pub const Phase = enum { pristine, open, cleanup_required, retained_closed };

pub const Entry = struct {
    path: []const u8,
    observation: files.ExecutableObservation,
};

pub const Value = struct {
    directory: []const u8,
    entries: [role_count]Entry,
};

pub const DurableAggregate = struct {
    owner: ?*DurableAggregate = null,
    phase: Phase = .pristine,
    parent_fd: c.fd_t = -1,
    directory_fd: c.fd_t = -1,
    directory_device: u64 = 0,
    directory_inode: u64 = 0,
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination_len: usize = 0,
    directory_leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),
    directory_leaf_len: usize = 0,
    paths: [role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    path_lens: [role_count]usize = @splat(0),
    names: [role_count][std.fs.max_name_bytes:0]u8 = @splat(@splat(0)),
    name_lens: [role_count]usize = @splat(0),
    files: [role_count]files.PinnedReleaseFile = @splat(.{}),
    present: [role_count]bool = @splat(false),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?Value {
        if (self.owner != self or self.phase != .open or !validStorage(self) or !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return null;
        var entries: [role_count]Entry = undefined;
        for (0..role_count) |index| {
            if (self.files[index].owner != &self.files[index]) return null;
            entries[index] = .{
                .path = self.paths[index][0..self.path_lens[index]],
                .observation = self.files[index].value() orelse return null,
            };
        }
        return .{ .directory = self.destination[0..self.destination_len], .entries = entries };
    }

    pub fn revalidate(self: *const @This()) Error!Value {
        const current = self.value() orelse return error.InvalidOwner;
        try self.revalidateDirectory();
        var result = current;
        var identities: [role_count]files.Identity = undefined;
        for (0..role_count) |index| {
            const path: [:0]const u8 = self.paths[index][0..self.path_lens[index] :0];
            const observed = self.files[index].revalidate(path) catch return error.FileChanged;
            if (!sameObservation(current.entries[index].observation, observed)) return error.FileChanged;
            result.entries[index].observation = observed;
            identities[index] = observed.identity;
        }
        try files.requireDistinct(&identities);
        return result;
    }

    fn revalidateDirectory(self: *const @This()) Error!void {
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        const leaf: [:0]const u8 = self.directory_leaf[0..self.directory_leaf_len :0];
        if (c.fstat(self.directory_fd, &held) != 0 or
            c.fstatat(self.parent_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(held.mode) or !posix.S.ISDIR(named.mode) or
            @as(u64, @intCast(held.dev)) != self.directory_device or @as(u64, @intCast(held.ino)) != self.directory_inode or
            held.dev != named.dev or held.ino != named.ino or held.mode & 0o777 != 0o700)
            return error.FileChanged;
    }

    /// Deletes only a fully revalidated aggregate. Validation precedes the first unlink so a
    /// pathname replacement cannot turn a partial cleanup into deletion of foreign data.
    pub fn cleanup(self: *@This()) Error!void {
        return self.cleanupCore(null) catch |err| switch (err) {
            error.InjectedFailure => unreachable,
            else => |production_error| return production_error,
        };
    }

    pub fn cleanupFailingForTest(self: *@This(), fail_after_unlinks: usize) TestError!void {
        if (!builtin.is_test) @compileError("cleanup fault injection is test-only");
        if (fail_after_unlinks > role_count) return error.InvalidExpected;
        return self.cleanupCore(fail_after_unlinks);
    }

    fn cleanupCore(self: *@This(), fail_after_unlinks: ?usize) TestError!void {
        if (self.owner != self or (self.phase != .open and self.phase != .cleanup_required)) return error.InvalidOwner;
        if (self.phase == .open) {
            if (!validStorage(self)) return error.InvalidOwner;
            _ = self.revalidate() catch return error.CleanupFailed;
            var tomb_storage: [std.fs.max_name_bytes:0]u8 = undefined;
            const tomb = cleanupName(&tomb_storage) catch return error.CleanupFailed;
            const final_leaf: [:0]const u8 = self.directory_leaf[0..self.directory_leaf_len :0];
            if (renameatx_np(self.parent_fd, final_leaf.ptr, self.parent_fd, tomb.ptr, rename_excl) != 0)
                return error.CleanupFailed;
            @memset(&self.directory_leaf, 0);
            @memcpy(self.directory_leaf[0..tomb.len], tomb);
            self.directory_leaf_len = tomb.len;
            self.phase = .cleanup_required;
        }
        var unlinked: usize = 0;
        if (fail_after_unlinks == 0) return error.InjectedFailure;
        for (0..role_count) |offset| {
            const index = role_count - 1 - offset;
            if (!self.present[index]) continue;
            var held: posix.Stat = undefined;
            var named: posix.Stat = undefined;
            const name: [:0]const u8 = self.names[index][0..self.name_lens[index] :0];
            if (c.fstat(self.files[index].fd, &held) != 0 or
                c.fstatat(self.directory_fd, name.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                held.dev != named.dev or held.ino != named.ino or held.nlink != 1 or
                c.unlinkat(self.directory_fd, name.ptr, 0) != 0)
                return error.CleanupFailed;
            self.present[index] = false;
            unlinked += 1;
            if (fail_after_unlinks == unlinked) return error.InjectedFailure;
        }
        if (c.fsync(self.directory_fd) != 0) return error.CleanupFailed;
        const leaf: [:0]const u8 = self.directory_leaf[0..self.directory_leaf_len :0];
        if (c.unlinkat(self.parent_fd, leaf.ptr, posix.AT.REMOVEDIR) != 0 or c.fsync(self.parent_fd) != 0)
            return error.CleanupFailed;
        tombstoneAndClose(self) catch return error.DescriptorCloseFailed;
        self.* = .{};
    }

    pub fn closeRetaining(self: *@This()) Error!void {
        _ = try self.revalidate();
        self.phase = .retained_closed;
        try tombstoneAndClose(self);
    }
};

pub fn promote(allocator: std.mem.Allocator, sources: Sources, destination: [:0]const u8, result: *DurableAggregate) Error!void {
    var injector = NoFault{};
    return promoteCore(allocator, sources, destination, result, &injector) catch |err| switch (err) {
        error.InjectedFailure => unreachable,
        else => |production_error| return production_error,
    };
}

pub const TestCheckpoint = enum {
    staging_created,
    evidence_written,
    evidence_copied,
    candidate_dmg_written,
    candidate_dmg_copied,
    candidate_frozen_written,
    candidate_frozen_copied,
    evidence_bundle_written,
    evidence_bundle_copied,
    manifest_bundle_written,
    manifest_bundle_copied,
    staging_synced,
    final_renamed,
    parent_synced,
};

pub fn promoteFailingForTest(allocator: std.mem.Allocator, sources: Sources, destination: [:0]const u8, result: *DurableAggregate, checkpoint: TestCheckpoint) TestError!void {
    if (!builtin.is_test) @compileError("fault injection is test-only");
    var injector = Fault{ .fail_at = checkpoint };
    return promoteCore(allocator, sources, destination, result, &injector);
}

const NoFault = struct {
    fn hit(_: *@This(), _: TestCheckpoint) TestError!void {}
};
const Fault = struct {
    fail_at: TestCheckpoint,
    fn hit(self: *@This(), checkpoint: TestCheckpoint) TestError!void {
        if (self.fail_at == checkpoint) return error.InjectedFailure;
    }
};

const Working = struct {
    parent_fd: c.fd_t,
    directory_fd: c.fd_t,
    directory_device: u64,
    directory_inode: u64,
    stage_leaf: [std.fs.max_name_bytes:0]u8,
    stage_leaf_len: usize,
    stage_path: [std.fs.max_path_bytes:0]u8,
    stage_path_len: usize,
    files: [role_count]files.PinnedReleaseFile = @splat(.{}),
    present: [role_count]bool = @splat(false),
    names: [role_count][std.fs.max_name_bytes:0]u8 = @splat(@splat(0)),
    name_lens: [role_count]usize = @splat(0),
    paths: [role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    path_lens: [role_count]usize = @splat(0),
    renamed: bool = false,
    adopted: bool = false,

    fn cleanupChecked(self: *@This()) Error!void {
        if (self.adopted) return;
        var failed = false;
        for (0..role_count) |offset| {
            const index = role_count - 1 - offset;
            if (self.files[index].value() != null) {
                const name: [:0]const u8 = self.names[index][0..self.name_lens[index] :0];
                if (!unlinkExact(self.directory_fd, name, self.files[index].fd)) failed = true;
                self.files[index].deinit() catch {
                    failed = true;
                };
            } else if (self.present[index] and self.name_lens[index] != 0) {
                const name: [:0]const u8 = self.names[index][0..self.name_lens[index] :0];
                if (c.unlinkat(self.directory_fd, name.ptr, 0) != 0) failed = true;
            }
        }
        if (!self.renamed) {
            const leaf: [:0]const u8 = self.stage_leaf[0..self.stage_leaf_len :0];
            if (!sameDirectoryAt(self.parent_fd, leaf, self.directory_fd) or c.unlinkat(self.parent_fd, leaf.ptr, posix.AT.REMOVEDIR) != 0 or c.fsync(self.parent_fd) != 0) failed = true;
        }
        if (c.close(self.directory_fd) != 0) failed = true;
        if (c.close(self.parent_fd) != 0) failed = true;
        self.adopted = true;
        if (failed) return error.CleanupFailed;
    }
};

fn promoteCore(allocator: std.mem.Allocator, sources: Sources, destination: [:0]const u8, result: *DurableAggregate, injector: anytype) TestError!void {
    try validateInputs(sources, destination, result);
    const observations = try sourceObservations(sources);
    var total: u64 = 0;
    for (observations, 0..) |observation, index| {
        const cap: u64 = if (index == 0) evidence_mod.max_evidence_bytes else max_attestation_bundle_bytes;
        if (observation.size > cap) return error.TooLarge;
        total = std.math.add(u64, total, observation.size) catch return error.AggregateTooLarge;
    }
    if (total > max_aggregate_bytes) return error.AggregateTooLarge;

    var parent_leaf: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(destination, &parent_leaf);
    var parent_owned = true;
    defer {
        if (parent_owned) _ = c.close(parent.fd);
    }
    var existing: posix.Stat = undefined;
    if (c.fstatat(parent.fd, parent.leaf.ptr, &existing, posix.AT.SYMLINK_NOFOLLOW) == 0) return error.DestinationExists;
    if (posix.errno(-1) != .NOENT) return error.InvalidPath;

    var stage_leaf: [std.fs.max_name_bytes:0]u8 = undefined;
    const stage_name = try createStage(parent.fd, &stage_leaf);
    var stage_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const destination_parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    const stage_path_value = if (std.mem.eql(u8, destination_parent, "/"))
        std.fmt.bufPrintZ(&stage_path, "/{s}", .{stage_name}) catch unreachable
    else
        std.fmt.bufPrintZ(&stage_path, "{s}/{s}", .{ destination_parent, stage_name }) catch unreachable;
    const directory_fd = c.openat(parent.fd, stage_name.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (directory_fd < 0) {
        _ = c.unlinkat(parent.fd, stage_name.ptr, posix.AT.REMOVEDIR);
        return error.CreateFailed;
    }
    var directory_stat: posix.Stat = undefined;
    if (c.fstat(directory_fd, &directory_stat) != 0 or !posix.S.ISDIR(directory_stat.mode) or directory_stat.mode & 0o777 != 0o700) {
        _ = c.close(directory_fd);
        _ = c.unlinkat(parent.fd, stage_name.ptr, posix.AT.REMOVEDIR);
        return error.CreateFailed;
    }
    var working = Working{
        .parent_fd = parent.fd,
        .directory_fd = directory_fd,
        .directory_device = @intCast(directory_stat.dev),
        .directory_inode = @intCast(directory_stat.ino),
        .stage_leaf = stage_leaf,
        .stage_leaf_len = stage_name.len,
        .stage_path = stage_path,
        .stage_path_len = stage_path_value.len,
    };
    parent_owned = false;
    completePromotion(allocator, sources, observations, destination, parent.leaf, result, injector, &working) catch |err| {
        if (!working.adopted) working.cleanupChecked() catch return error.CleanupFailed;
        return err;
    };
}

fn completePromotion(allocator: std.mem.Allocator, sources: Sources, observations: [role_count]files.ExecutableObservation, destination: [:0]const u8, final_leaf: [:0]const u8, result: *DurableAggregate, injector: anytype, working: *Working) TestError!void {
    try injector.hit(.staging_created);

    const evidence_name = std.fs.path.basename(sources.evidence.path);
    const stage_path_value: [:0]const u8 = working.stage_path[0..working.stage_path_len :0];
    for (0..role_count) |index| {
        const role: Role = @enumFromInt(index);
        const source = sources.at(role);
        const name = destinationName(role, evidence_name);
        if (!validComponent(name) or name.len >= working.names[index].len) return error.InvalidPath;
        for (0..index) |prior| if (std.mem.eql(u8, name, working.names[prior][0..working.name_lens[prior]])) return error.InvalidPath;
        @memcpy(working.names[index][0..name.len], name);
        working.names[index][name.len] = 0;
        working.name_lens[index] = name.len;
        const path = std.fmt.bufPrintZ(&working.paths[index], "{s}/{s}", .{ stage_path_value, name }) catch return error.InvalidPath;
        working.path_lens[index] = path.len;
        const cap: usize = if (index == 0) evidence_mod.max_evidence_bytes else @intCast(max_attestation_bundle_bytes);
        var input = source.file.readHeldAlloc(allocator, source.path, cap) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.TooLarge,
            else => return error.SourceChanged,
        };
        defer input.deinit(allocator);
        if (!sameObservation(observations[index], .{ .identity = input.identity, .size = input.size, .mode = input.mode, .sha256 = input.sha256 })) return error.SourceChanged;
        try writeLeaf(working.directory_fd, working.names[index][0..name.len :0], input.bytes);
        working.present[index] = true;
        try injector.hit(@enumFromInt(@intFromEnum(TestCheckpoint.evidence_written) + index * 2));
        try files.pinReleaseFileObserved(&working.files[index], path, false, cap);
        const copied = working.files[index].value().?;
        if (sameIdentity(observations[index].identity, copied.identity) or observations[index].size != copied.size or !std.mem.eql(u8, &observations[index].sha256, &copied.sha256)) return error.FileChanged;
        try injector.hit(@enumFromInt(@intFromEnum(TestCheckpoint.evidence_copied) + index * 2));
    }
    var copied_identities: [role_count]files.Identity = undefined;
    for (&working.files, 0..) |*file, index| copied_identities[index] = file.value().?.identity;
    try files.requireDistinct(&copied_identities);
    if (c.fsync(working.directory_fd) != 0) return error.SyncFailed;
    try injector.hit(.staging_synced);

    const stage_name: [:0]const u8 = working.stage_leaf[0..working.stage_leaf_len :0];
    if (renameatx_np(working.parent_fd, stage_name.ptr, working.parent_fd, final_leaf.ptr, rename_excl) != 0) {
        if (posix.errno(-1) == .EXIST) return error.DestinationExists;
        return error.PublishFailed;
    }
    working.renamed = true;
    adoptAfterRename(working, destination, final_leaf, result);
    try injector.hit(.final_renamed);
    if (c.fsync(result.parent_fd) != 0) return error.SyncFailed;
    try injector.hit(.parent_synced);
    _ = try result.revalidate();
}

fn adoptAfterRename(working: *Working, destination: [:0]const u8, final_leaf: [:0]const u8, result: *DurableAggregate) void {
    var adopted: DurableAggregate = .{
        .parent_fd = working.parent_fd,
        .directory_fd = working.directory_fd,
        .directory_device = working.directory_device,
        .directory_inode = working.directory_inode,
        .destination_len = destination.len,
        .directory_leaf_len = final_leaf.len,
    };
    @memcpy(adopted.destination[0..destination.len], destination);
    adopted.destination[destination.len] = 0;
    @memcpy(adopted.directory_leaf[0..final_leaf.len], final_leaf);
    adopted.directory_leaf[final_leaf.len] = 0;
    for (0..role_count) |index| {
        const name = working.names[index][0..working.name_lens[index]];
        const final_path = std.fmt.bufPrintZ(&adopted.paths[index], "{s}/{s}", .{ destination, name }) catch unreachable;
        adopted.path_lens[index] = final_path.len;
        @memcpy(adopted.names[index][0..name.len], name);
        adopted.names[index][name.len] = 0;
        adopted.name_lens[index] = name.len;
        adopted.files[index] = working.files[index];
        adopted.present[index] = true;
        adopted.files[index].owner = &adopted.files[index];
        adopted.files[index].path_len = final_path.len;
        std.crypto.hash.sha2.Sha256.hash(final_path, &adopted.files[index].path_sha256, .{});
        working.files[index] = .{};
    }
    result.* = adopted;
    result.owner = result;
    result.phase = .open;
    for (&result.files) |*file| file.owner = file;
    result.seal = metadataSeal(result);
    working.adopted = true;
}

fn validateInputs(sources: Sources, destination: [:0]const u8, result: *const DurableAggregate) Error!void {
    if (!pristine(result)) return error.InvalidOwner;
    if (!canonicalAbsolute(destination)) return error.InvalidPath;
    const evidence_name = std.fs.path.basename(sources.evidence.path);
    const destination_parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    if (destination_parent.len + 1 + ".maru-aggregate-ffffffffffffffff".len >= std.fs.max_path_bytes) return error.InvalidPath;
    for (0..role_count) |index| {
        const name = destinationName(@enumFromInt(index), evidence_name);
        if (!validComponent(name) or destination.len + 1 + name.len >= std.fs.max_path_bytes) return error.InvalidPath;
        for (0..index) |prior| if (std.mem.eql(u8, name, destinationName(@enumFromInt(prior), evidence_name))) return error.InvalidPath;
    }
    const result_bytes = std.mem.asBytes(result);
    var identities: [role_count]files.Identity = undefined;
    for (0..role_count) |index| {
        const source = sources.at(@enumFromInt(index));
        const observation = source.file.value() orelse return error.InvalidOwner;
        identities[index] = observation.identity;
        if (!canonicalAbsolute(source.root) or !canonicalAbsolute(source.path) or !directChild(source.root, source.path) or sameOrDescendant(source.root, destination)) return error.InvalidPath;
        if (overlaps(result_bytes, std.mem.asBytes(source.file)) or overlaps(result_bytes, source.root) or overlaps(result_bytes, source.path) or overlaps(result_bytes, destination)) return error.InvalidOwner;
        for (0..index) |prior| {
            const previous = sources.at(@enumFromInt(prior));
            if (overlaps(std.mem.asBytes(source.file), std.mem.asBytes(previous.file))) return error.InvalidOwner;
        }
    }
    try files.requireDistinct(&identities);
}

fn sourceObservations(sources: Sources) Error![role_count]files.ExecutableObservation {
    var result: [role_count]files.ExecutableObservation = undefined;
    for (0..role_count) |index| {
        const source = sources.at(@enumFromInt(index));
        result[index] = source.file.revalidate(source.path) catch return error.SourceChanged;
    }
    return result;
}

fn tombstoneAndClose(self: *DurableAggregate) Error!void {
    var descriptors: [role_count * 2 + 2]c.fd_t = undefined;
    var count: usize = 0;
    for (&self.files) |*file| {
        descriptors[count] = file.fd;
        descriptors[count + 1] = file.parent_fd;
        count += 2;
        file.* = .{};
    }
    descriptors[count] = self.directory_fd;
    descriptors[count + 1] = self.parent_fd;
    self.directory_fd = -1;
    self.parent_fd = -1;
    var failed = false;
    for (descriptors[0 .. count + 2]) |fd| if (fd >= 0 and c.close(fd) != 0) {
        failed = true;
    };
    if (failed) return error.DescriptorCloseFailed;
}

fn writeLeaf(directory_fd: c.fd_t, name: [:0]const u8, bytes: []const u8) Error!void {
    if (bytes.len == 0) return error.TooLarge;
    const fd = c.openat(directory_fd, name.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    var keep = false;
    defer {
        _ = c.close(fd);
        if (!keep) _ = c.unlinkat(directory_fd, name.ptr, 0);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.WriteFailed;
        }
        if (written == 0) return error.WriteFailed;
        offset += @intCast(written);
    }
    if (c.fchmod(fd, 0o600) != 0 or c.fsync(fd) != 0) return error.SyncFailed;
    keep = true;
}

const Parent = struct { fd: c.fd_t, leaf: [:0]const u8 };

fn openParent(path: [:0]const u8, leaf_storage: *[std.fs.max_name_bytes:0]u8) Error!Parent {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const leaf = std.fs.path.basename(path);
    if (!canonicalAbsolute(path) or !validComponent(leaf)) return error.InvalidPath;
    const leaf_z = std.fmt.bufPrintZ(leaf_storage, "{s}", .{leaf}) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_storage, "{s}", .{parent_path}) catch return error.InvalidPath;
    return .{ .fd = safe_open.openAbsoluteNoFollow(parent_z, true) catch return error.InvalidPath, .leaf = leaf_z };
}

fn createStage(parent_fd: c.fd_t, storage: *[std.fs.max_name_bytes:0]u8) Error![:0]const u8 {
    for (0..8) |_| {
        var nonce: u64 = undefined;
        c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
        const name = std.fmt.bufPrintZ(storage, ".maru-aggregate-{x}", .{nonce}) catch return error.CreateFailed;
        if (c.mkdirat(parent_fd, name.ptr, 0o700) == 0) return name;
        if (posix.errno(-1) != .EXIST) return error.CreateFailed;
    }
    return error.CreateFailed;
}

fn cleanupName(storage: *[std.fs.max_name_bytes:0]u8) Error![:0]const u8 {
    var nonce: u64 = undefined;
    c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    return std.fmt.bufPrintZ(storage, ".maru-aggregate-cleanup-{x}", .{nonce}) catch error.CleanupFailed;
}

fn unlinkExact(parent_fd: c.fd_t, name: [:0]const u8, held_fd: c.fd_t) bool {
    var held: posix.Stat = undefined;
    var named: posix.Stat = undefined;
    return c.fstat(held_fd, &held) == 0 and c.fstatat(parent_fd, name.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) == 0 and held.dev == named.dev and held.ino == named.ino and c.unlinkat(parent_fd, name.ptr, 0) == 0;
}

fn sameDirectoryAt(parent_fd: c.fd_t, name: [:0]const u8, held_fd: c.fd_t) bool {
    var held: posix.Stat = undefined;
    var named: posix.Stat = undefined;
    return c.fstat(held_fd, &held) == 0 and c.fstatat(parent_fd, name.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) == 0 and posix.S.ISDIR(held.mode) and posix.S.ISDIR(named.mode) and held.dev == named.dev and held.ino == named.ino;
}

fn pristine(value: *const DurableAggregate) bool {
    if (value.owner != null or value.phase != .pristine or value.parent_fd >= 0 or value.directory_fd >= 0 or value.destination_len != 0 or value.directory_leaf_len != 0) return false;
    for (value.files) |file| if (file.owner != null or file.fd >= 0 or file.parent_fd >= 0) return false;
    return true;
}

fn validStorage(value: *const DurableAggregate) bool {
    if (value.parent_fd < 0 or value.directory_fd < 0 or value.destination_len == 0 or value.destination_len >= value.destination.len or
        value.directory_leaf_len == 0 or value.directory_leaf_len >= value.directory_leaf.len or value.destination[value.destination_len] != 0 or
        value.directory_leaf[value.directory_leaf_len] != 0 or !std.mem.eql(u8, std.fs.path.basename(value.destination[0..value.destination_len]), value.directory_leaf[0..value.directory_leaf_len])) return false;
    const evidence_name = value.names[0][0..value.name_lens[0]];
    for (0..role_count) |index| {
        if (value.path_lens[index] == 0 or value.path_lens[index] >= value.paths[index].len or value.name_lens[index] == 0 or value.name_lens[index] >= value.names[index].len or
            value.paths[index][value.path_lens[index]] != 0 or value.names[index][value.name_lens[index]] != 0 or
            !std.mem.eql(u8, std.fs.path.basename(value.paths[index][0..value.path_lens[index]]), value.names[index][0..value.name_lens[index]]) or
            !std.mem.eql(u8, std.fs.path.dirname(value.paths[index][0..value.path_lens[index]]) orelse return false, value.destination[0..value.destination_len]) or
            !std.mem.eql(u8, value.names[index][0..value.name_lens[index]], destinationName(@enumFromInt(index), evidence_name))) return false;
    }
    return true;
}

fn metadataSeal(value: *const DurableAggregate) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const self_address = @intFromPtr(value);
    hasher.update(std.mem.asBytes(&self_address));
    hasher.update(std.mem.asBytes(&value.directory_device));
    hasher.update(std.mem.asBytes(&value.directory_inode));
    hasher.update(std.mem.asBytes(&value.destination_len));
    hasher.update(value.destination[0..value.destination_len]);
    hasher.update(std.mem.asBytes(&value.directory_leaf_len));
    hasher.update(value.directory_leaf[0..value.directory_leaf_len]);
    for (0..role_count) |index| {
        hasher.update(std.mem.asBytes(&value.path_lens[index]));
        hasher.update(value.paths[index][0..value.path_lens[index]]);
        hasher.update(std.mem.asBytes(&value.name_lens[index]));
        hasher.update(value.names[index][0..value.name_lens[index]]);
        const observation = value.files[index].value() orelse continue;
        hasher.update(std.mem.asBytes(&observation.identity.device));
        hasher.update(std.mem.asBytes(&observation.identity.inode));
        hasher.update(std.mem.asBytes(&observation.size));
        hasher.update(std.mem.asBytes(&observation.mode));
        hasher.update(&observation.sha256);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn canonicalAbsolute(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len == 0 or value.len >= std.fs.max_path_bytes or std.mem.indexOfScalar(u8, value, 0) != null or (value.len > 1 and std.mem.endsWith(u8, value, "/"))) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| if (!validComponent(component)) return false;
    return true;
}

fn validComponent(value: []const u8) bool {
    return value.len != 0 and value.len <= std.fs.max_name_bytes and !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..") and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn directChild(root: []const u8, child: []const u8) bool {
    if (root.len == 1) return std.mem.indexOfScalar(u8, child[1..], '/') == null;
    return child.len > root.len + 1 and std.mem.startsWith(u8, child, root) and child[root.len] == '/' and std.mem.indexOfScalar(u8, child[root.len + 1 ..], '/') == null;
}

fn sameOrDescendant(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
}

fn sameIdentity(left: files.Identity, right: files.Identity) bool {
    return left.device == right.device and left.inode == right.inode;
}
fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return sameIdentity(left.identity, right.identity) and left.size == right.size and left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
