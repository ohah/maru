//! Reopens retained stage-3 preparation as a fresh, semantically verified descriptor owner.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const evidence_mod = @import("release_evidence");
const manifest_mod = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const safe_open = @import("safe_open");

pub const Error = files.Error || handoff.Error || context_mod.Error || error{
    InvalidPath,
    InvalidInventory,
    InvalidMode,
    InvalidOwner,
    UntrustedContext,
    FileChanged,
    DescriptorCloseFailed,
};

pub const Phase = enum { pristine, verified, closed };
pub const Entry = struct { path: []const u8, observation: files.ExecutableObservation };
pub const View = struct { directory: []const u8, entries: [handoff.role_count]Entry };

const StoredContext = struct {
    repository_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,

    fn init(context: context_mod.Context) Error!@This() {
        if (!context.protected_tag or !std.mem.eql(u8, context.repository.owner, "ohah") or
            !std.mem.eql(u8, context.repository.name, "maru")) return error.UntrustedContext;
        if (context.tag.len == 0 or context.tag.len > context_mod.max_value_bytes or
            context.source_commit.len != 40 or context.build.workflow_ref.len == 0 or
            context.build.workflow_ref.len > context_mod.max_value_bytes) return error.UntrustedContext;
        var result: @This() = .{
            .repository_id = context.repository.id,
            .tag_len = context.tag.len,
            .workflow_ref_len = context.build.workflow_ref.len,
            .run_id = context.build.run_id,
            .run_attempt = context.build.run_attempt,
        };
        @memcpy(result.tag[0..context.tag.len], context.tag);
        @memcpy(&result.source_commit, context.source_commit);
        @memcpy(result.workflow_ref[0..context.build.workflow_ref.len], context.build.workflow_ref);
        return result;
    }

    fn value(self: *const @This()) context_mod.Context {
        return .{
            .repository = .{ .id = self.repository_id, .owner = "ohah", .name = "maru" },
            .tag = self.tag[0..self.tag_len],
            .source_commit = &self.source_commit,
            .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt },
            .protected_tag = true,
        };
    }
};

pub const ReopenedPreparation = struct {
    owner: ?*ReopenedPreparation = null,
    phase: Phase = .pristine,
    parent_fd: c.fd_t = -1,
    directory_fd: c.fd_t = -1,
    directory_device: u64 = 0,
    directory_inode: u64 = 0,
    directory: [std.fs.max_path_bytes:0]u8 = @splat(0),
    directory_len: usize = 0,
    directory_leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),
    directory_leaf_len: usize = 0,
    names: [handoff.role_count][std.fs.max_name_bytes:0]u8 = @splat(@splat(0)),
    name_lens: [handoff.role_count]usize = @splat(0),
    paths: [handoff.role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    path_lens: [handoff.role_count]usize = @splat(0),
    entries: [handoff.role_count]files.PinnedReleaseFile = @splat(.{}),
    context: StoredContext = .{},
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.phase != .verified or !validStorage(self) or
            !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return null;
        var entries: [handoff.role_count]Entry = undefined;
        for (&self.entries, 0..) |*entry, index| entries[index] = .{
            .path = self.paths[index][0..self.path_lens[index]],
            .observation = entry.value() orelse return null,
        };
        return .{ .directory = self.directory[0..self.directory_len], .entries = entries };
    }

    pub fn fence(self: *const @This(), allocator: std.mem.Allocator) Error!View {
        const initial = self.value() orelse return error.InvalidOwner;
        try self.revalidateDirectory();
        try exactInventory(self.directory_fd, .{
            self.names[0][0..self.name_lens[0]],
            self.names[1][0..self.name_lens[1]],
        });
        var observations: [handoff.role_count]files.ExecutableObservation = undefined;
        for (&self.entries, 0..) |*entry, index| {
            const path: [:0]const u8 = self.paths[index][0..self.path_lens[index] :0];
            observations[index] = entry.revalidate(path) catch return error.FileChanged;
            if (!sameObservation(initial.entries[index].observation, observations[index]) or
                !parentMatches(entry.parent_fd, self.directory_fd)) return error.FileChanged;
        }
        try files.requireDistinct(&.{ observations[0].identity, observations[1].identity });
        _ = try validateSemantic(allocator, self.context.value(), self.directory[0..self.directory_len :0], &self.entries, .{
            self.paths[0][0..self.path_lens[0] :0],
            self.paths[1][0..self.path_lens[1] :0],
        }, observations);
        return self.value() orelse error.InvalidOwner;
    }

    pub fn close(self: *@This(), allocator: std.mem.Allocator) Error!void {
        _ = try self.fence(allocator);
        self.phase = .closed;
        self.seal = metadataSeal(self);
        try self.closeDescriptors();
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.phase != .verified) return error.InvalidOwner;
        self.phase = .closed;
        self.seal = metadataSeal(self);
        try self.closeDescriptors();
    }

    fn closeDescriptors(self: *@This()) Error!void {
        var descriptors: [handoff.role_count * 2 + 2]c.fd_t = undefined;
        var count: usize = 0;
        for (&self.entries) |*entry| {
            descriptors[count] = entry.fd;
            descriptors[count + 1] = entry.parent_fd;
            count += 2;
            entry.* = .{};
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

    fn revalidateDirectory(self: *const @This()) Error!void {
        const path: [:0]const u8 = self.directory[0..self.directory_len :0];
        const current_fd = safe_open.openAbsoluteNoFollow(path, true) catch return error.FileChanged;
        defer _ = c.close(current_fd);
        var held: posix.Stat = undefined;
        var current: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        const leaf: [:0]const u8 = self.directory_leaf[0..self.directory_leaf_len :0];
        if (c.fstat(self.directory_fd, &held) != 0 or c.fstat(current_fd, &current) != 0 or
            c.fstatat(self.parent_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !validDirectory(held) or !sameStatIdentity(held, current) or !sameStatIdentity(held, named) or
            @as(u64, @intCast(held.dev)) != self.directory_device or @as(u64, @intCast(held.ino)) != self.directory_inode)
            return error.FileChanged;
    }
};

pub fn open(allocator: std.mem.Allocator, context: context_mod.Context, directory: [:0]const u8, result: *ReopenedPreparation) Error!void {
    if (!pristine(result)) return error.InvalidOwner;
    errdefer {
        if (result.owner == result and result.phase == .verified) result.deinit() catch {};
        result.* = .{};
    }
    if (!canonicalAbsolute(directory) or overlaps(std.mem.asBytes(result), directory)) return error.InvalidPath;
    const stored_context = try StoredContext.init(context);
    var working: ReopenedPreparation = .{ .context = stored_context };
    errdefer closeWorking(&working);
    copyZ(working.directory.len, &working.directory, &working.directory_len, directory) catch return error.InvalidPath;
    const parent_path = std.fs.path.dirname(directory) orelse return error.InvalidPath;
    const leaf = std.fs.path.basename(directory);
    copyZ(working.directory_leaf.len, &working.directory_leaf, &working.directory_leaf_len, leaf) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_storage, "{s}", .{parent_path}) catch return error.InvalidPath;
    working.parent_fd = safe_open.openAbsoluteNoFollow(parent_z, true) catch return error.InvalidPath;
    working.directory_fd = safe_open.openAbsoluteNoFollow(directory, true) catch return error.InvalidPath;
    var directory_stat: posix.Stat = undefined;
    var named_stat: posix.Stat = undefined;
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(working.directory_fd, &directory_stat) != 0 or c.fstat(working.parent_fd, &parent_stat) != 0 or
        c.fstatat(working.parent_fd, working.directory_leaf[0..working.directory_leaf_len :0].ptr, &named_stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return error.InvalidPath;
    if (!validDirectory(directory_stat) or !sameStatIdentity(directory_stat, named_stat) or !posix.S.ISDIR(parent_stat.mode))
        return error.InvalidMode;
    working.directory_device = @intCast(directory_stat.dev);
    working.directory_inode = @intCast(directory_stat.ino);
    var discovered_storage: [std.fs.max_name_bytes]u8 = undefined;
    const discovered = try discoverInventory(working.directory_fd, &discovered_storage);
    copyZ(working.names[0].len, &working.names[0], &working.name_lens[0], handoff.evidence_name) catch return error.InvalidInventory;
    copyZ(working.names[1].len, &working.names[1], &working.name_lens[1], discovered) catch return error.InvalidInventory;
    for (0..handoff.role_count) |index| {
        const path = std.fmt.bufPrintZ(&working.paths[index], "{s}/{s}", .{ directory, working.names[index][0..working.name_lens[index]] }) catch return error.InvalidPath;
        working.path_lens[index] = path.len;
        try files.pinReleaseFileObserved(&working.entries[index], path, false, if (index == 0) evidence_mod.max_evidence_bytes else manifest_mod.max_manifest_bytes);
        const observation = working.entries[index].value() orelse return error.InvalidOwner;
        if (observation.mode & 0o777 != 0o600 or !parentMatches(working.entries[index].parent_fd, working.directory_fd)) return error.InvalidMode;
    }
    const observations = [_]files.ExecutableObservation{ working.entries[0].value().?, working.entries[1].value().? };
    try files.requireDistinct(&.{ observations[0].identity, observations[1].identity });
    const semantic = try validateSemantic(allocator, stored_context.value(), directory, &working.entries, .{
        working.paths[0][0..working.path_lens[0] :0],
        working.paths[1][0..working.path_lens[1] :0],
    }, observations);
    if (!std.mem.eql(u8, semantic.manifestName(), discovered)) return error.InvalidInventory;
    result.* = working;
    result.owner = result;
    result.phase = .verified;
    for (&result.entries) |*entry| entry.owner = entry;
    result.seal = metadataSeal(result);
    working = .{};
    _ = try result.fence(allocator);
}

fn validateSemantic(allocator: std.mem.Allocator, context: context_mod.Context, directory: [:0]const u8, entries: *const [handoff.role_count]files.PinnedReleaseFile, paths: [handoff.role_count][:0]const u8, observations: [handoff.role_count]files.ExecutableObservation) Error!handoff.Semantic {
    const semantic = try handoff.validateHeldSemantic(allocator, .{
        .evidence = .{ .file = &entries[0], .root = directory, .path = paths[0] },
        .manifest = .{ .file = &entries[1], .root = directory, .path = paths[1] },
    }, observations);
    var input = try entries[1].readHeldAlloc(allocator, paths[1], manifest_mod.max_manifest_bytes);
    defer input.deinit(allocator);
    var parsed = try manifest_mod.parseCanonical(allocator, input.bytes);
    defer parsed.deinit();
    try context_mod.bindManifest(context, parsed.value().*);
    return semantic;
}

fn discoverInventory(directory_fd: c.fd_t, storage: *[std.fs.max_name_bytes]u8) Error![]const u8 {
    const scan_fd = c.openat(directory_fd, ".", posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (scan_fd < 0) return error.InvalidInventory;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.InvalidInventory;
    };
    defer _ = c.closedir(directory);
    var manifest_len: usize = 0;
    var evidence_found = false;
    var count: usize = 0;
    c._errno().* = 0;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count > handoff.role_count) return error.InvalidInventory;
        if (std.mem.eql(u8, name, handoff.evidence_name)) evidence_found = true else {
            if (manifest_len != 0 or !std.mem.startsWith(u8, name, "Maru-") or !std.mem.endsWith(u8, name, "-session-host-release.json") or name.len >= storage.len)
                return error.InvalidInventory;
            @memcpy(storage[0..name.len], name);
            manifest_len = name.len;
        }
    }
    if (c._errno().* != 0 or count != handoff.role_count or !evidence_found or manifest_len == 0) return error.InvalidInventory;
    // The caller copies before the directory stream and this stack frame disappear.
    return storage[0..manifest_len];
}

fn exactInventory(directory_fd: c.fd_t, expected: [handoff.role_count][]const u8) Error!void {
    var storage: [std.fs.max_name_bytes]u8 = undefined;
    const found = try discoverInventory(directory_fd, &storage);
    if (!std.mem.eql(u8, found, expected[1]) or !std.mem.eql(u8, expected[0], handoff.evidence_name)) return error.InvalidInventory;
}

fn pristine(value: *const ReopenedPreparation) bool {
    if (value.owner != null or value.phase != .pristine or value.parent_fd >= 0 or value.directory_fd >= 0) return false;
    for (value.entries) |entry| if (entry.owner != null or entry.fd >= 0 or entry.parent_fd >= 0) return false;
    return true;
}

fn validStorage(value: *const ReopenedPreparation) bool {
    if (value.parent_fd < 0 or value.directory_fd < 0 or value.directory_len == 0 or value.directory_len >= value.directory.len or
        value.directory[value.directory_len] != 0 or value.directory_leaf_len == 0 or value.directory_leaf_len >= value.directory_leaf.len or
        value.directory_leaf[value.directory_leaf_len] != 0 or
        !std.mem.eql(u8, std.fs.path.basename(value.directory[0..value.directory_len]), value.directory_leaf[0..value.directory_leaf_len])) return false;
    for (0..handoff.role_count) |index| if (value.path_lens[index] == 0 or value.path_lens[index] >= value.paths[index].len or
        value.name_lens[index] == 0 or value.name_lens[index] >= value.names[index].len or value.paths[index][value.path_lens[index]] != 0 or
        value.names[index][value.name_lens[index]] != 0 or
        !std.mem.eql(u8, std.fs.path.basename(value.paths[index][0..value.path_lens[index]]), value.names[index][0..value.name_lens[index]])) return false;
    return true;
}

fn metadataSeal(value: *const ReopenedPreparation) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const address = @intFromPtr(value);
    hasher.update(std.mem.asBytes(&address));
    hasher.update(std.mem.asBytes(&value.phase));
    hasher.update(std.mem.asBytes(&value.directory_device));
    hasher.update(std.mem.asBytes(&value.directory_inode));
    hasher.update(value.directory[0..value.directory_len]);
    hasher.update(value.directory_leaf[0..value.directory_leaf_len]);
    hasher.update(std.mem.asBytes(&value.context.repository_id));
    hasher.update(value.context.tag[0..value.context.tag_len]);
    hasher.update(&value.context.source_commit);
    hasher.update(value.context.workflow_ref[0..value.context.workflow_ref_len]);
    hasher.update(std.mem.asBytes(&value.context.run_id));
    hasher.update(std.mem.asBytes(&value.context.run_attempt));
    for (&value.entries, 0..) |*entry, index| {
        hasher.update(value.names[index][0..value.name_lens[index]]);
        hasher.update(value.paths[index][0..value.path_lens[index]]);
        const observed = entry.value() orelse continue;
        hasher.update(std.mem.asBytes(&observed.identity));
        hasher.update(std.mem.asBytes(&observed.size));
        hasher.update(std.mem.asBytes(&observed.mode));
        hasher.update(&observed.sha256);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn validDirectory(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.geteuid() and stat.mode & 0o777 == 0o700;
}
fn sameStatIdentity(left: posix.Stat, right: posix.Stat) bool {
    return left.dev == right.dev and left.ino == right.ino;
}
fn parentMatches(left_fd: c.fd_t, right_fd: c.fd_t) bool {
    var left: posix.Stat = undefined;
    var right: posix.Stat = undefined;
    return c.fstat(left_fd, &left) == 0 and c.fstat(right_fd, &right) == 0 and sameStatIdentity(left, right);
}
fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and left.size == right.size and
        left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}
fn copyZ(comptime N: usize, storage: *[N:0]u8, len: *usize, value: []const u8) !void {
    if (value.len == 0 or value.len >= N) return error.InvalidPath;
    @memset(storage, 0);
    @memcpy(storage[0..value.len], value);
    len.* = value.len;
}
fn canonicalAbsolute(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len == 0 or value.len >= std.fs.max_path_bytes or std.mem.indexOfScalar(u8, value, 0) != null or
        (value.len > 1 and std.mem.endsWith(u8, value, "/"))) return false;
    var iterator = std.mem.splitScalar(u8, value[1..], '/');
    while (iterator.next()) |component| if (component.len == 0 or component.len > std.fs.max_name_bytes or
        std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
fn closeWorking(value: *ReopenedPreparation) void {
    for (&value.entries) |*entry| if (entry.owner == entry) entry.deinit() catch {};
    if (value.directory_fd >= 0) _ = c.close(value.directory_fd);
    if (value.parent_fd >= 0) _ = c.close(value.parent_fd);
    value.* = .{};
}
