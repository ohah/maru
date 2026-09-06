//! Reopens a retained release aggregate and binds every local bundle to its exact artifact.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const release_manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_aggregate_handoff");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const safe_open = @import("safe_open");

const artifact_count: usize = 3;
const verification_count: usize = 4;

pub const Error = files.Error || attestation.Error || cli_authority.Error || deadline_mod.Error || error{
    InvalidPath,
    InvalidInventory,
    InvalidOwner,
    AuthorityChanged,
    AttestationMismatch,
    CleanupFailed,
    DescriptorCloseFailed,
};

pub const Paths = struct {
    directory: [:0]const u8,
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    manifest: [:0]const u8,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

pub const Phase = enum { pristine, preparing, verified, closed };

pub const View = struct {
    verified: bool,
    context: context_mod.Context,
    directory: []const u8,
    evidence_name: []const u8,
    entries: [handoff.role_count]files.ExecutableObservation,
    artifact_names: [artifact_count][]const u8,
    artifacts: [artifact_count]files.ExecutableObservation,
};

const StoredContext = struct {
    repository_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,

    fn value(self: *const @This()) context_mod.Context {
        return .{
            .repository = .{ .id = self.repository_id, .owner = "ohah", .name = "maru" },
            .tag = self.tag[0..self.tag_len],
            .source_commit = &self.source_commit,
            .build = .{
                .workflow_ref = self.workflow_ref[0..self.workflow_ref_len],
                .run_id = self.run_id,
                .run_attempt = self.run_attempt,
            },
            .protected_tag = true,
        };
    }
};

pub const ReopenedAggregate = struct {
    owner: ?*ReopenedAggregate = null,
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
    artifact_paths: [artifact_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    artifact_path_lens: [artifact_count]usize = @splat(0),
    artifacts: [artifact_count]files.PinnedReleaseFile = @splat(.{}),
    cli_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli_path_len: usize = 0,
    context: StoredContext = .{},
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.phase != .verified or !validStorage(self) or
            !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return null;
        var entries: [handoff.role_count]files.ExecutableObservation = undefined;
        var artifact_names: [artifact_count][]const u8 = undefined;
        var artifacts: [artifact_count]files.ExecutableObservation = undefined;
        for (&self.entries, 0..) |*entry, index| entries[index] = entry.value() orelse return null;
        for (&self.artifacts, 0..) |*artifact, index| {
            artifacts[index] = artifact.value() orelse return null;
            artifact_names[index] = std.fs.path.basename(self.artifact_paths[index][0..self.artifact_path_lens[index]]);
        }
        return .{
            .verified = true,
            .context = self.context.value(),
            .directory = self.directory[0..self.directory_len],
            .evidence_name = self.names[0][0..self.name_lens[0]],
            .entries = entries,
            .artifact_names = artifact_names,
            .artifacts = artifacts,
        };
    }

    pub fn fence(self: *const @This()) Error!View {
        if (self.phase != .verified) return error.InvalidOwner;
        try self.fenceInternal();
        return self.value() orelse error.InvalidOwner;
    }

    pub fn close(self: *@This()) Error!void {
        if (self.value() == null) return error.InvalidOwner;
        try self.fenceInternal();
        self.phase = .closed;
        self.seal = metadataSeal(self);
        try self.closeDescriptors(false);
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.phase != .verified) return error.InvalidOwner;
        self.phase = .closed;
        self.seal = metadataSeal(self);
        try self.closeDescriptors(false);
    }

    fn fenceInternal(self: *const @This()) Error!void {
        if (self.owner != self or (self.phase != .preparing and self.phase != .verified) or
            !validStorage(self) or !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return error.AuthorityChanged;
        try self.revalidateDirectory();
        try self.requireExactInventory();
        for (&self.entries, 0..) |*entry, index| {
            const path: [:0]const u8 = self.paths[index][0..self.path_lens[index] :0];
            _ = entry.revalidate(path) catch return error.AuthorityChanged;
            if (!parentMatches(entry.parent_fd, self.directory_fd)) return error.AuthorityChanged;
        }
        for (&self.artifacts, 0..) |*artifact, index| {
            const path: [:0]const u8 = self.artifact_paths[index][0..self.artifact_path_lens[index] :0];
            _ = artifact.revalidate(path) catch return error.AuthorityChanged;
        }
        try requireAllDistinct(self);
    }

    fn revalidateDirectory(self: *const @This()) Error!void {
        const directory: [:0]const u8 = self.directory[0..self.directory_len :0];
        const current_fd = safe_open.openAbsoluteNoFollow(directory, true) catch return error.AuthorityChanged;
        defer _ = c.close(current_fd);
        var held: posix.Stat = undefined;
        var current: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        var parent: posix.Stat = undefined;
        const leaf: [:0]const u8 = self.directory_leaf[0..self.directory_leaf_len :0];
        if (c.fstat(self.directory_fd, &held) != 0 or c.fstat(current_fd, &current) != 0 or
            c.fstatat(self.parent_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or c.fstat(self.parent_fd, &parent) != 0)
            return error.AuthorityChanged;
        if (!validDirectoryStat(held) or !sameIdentityStat(held, current) or !sameIdentityStat(held, named) or
            @as(u64, @intCast(held.dev)) != self.directory_device or @as(u64, @intCast(held.ino)) != self.directory_inode or
            !posix.S.ISDIR(parent.mode)) return error.AuthorityChanged;
    }

    fn requireExactInventory(self: *const @This()) Error!void {
        var observed: [handoff.role_count]bool = @splat(false);
        const scan_fd = c.openat(self.directory_fd, ".", posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (scan_fd < 0) return error.AuthorityChanged;
        const directory = c.fdopendir(scan_fd) orelse {
            _ = c.close(scan_fd);
            return error.AuthorityChanged;
        };
        defer _ = c.closedir(directory);
        var count: usize = 0;
        c._errno().* = 0;
        while (c.readdir(directory)) |entry| {
            const name = std.mem.sliceTo(entry.name[0..], 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            count = std.math.add(usize, count, 1) catch return error.AuthorityChanged;
            if (count > handoff.role_count) return error.AuthorityChanged;
            var matched = false;
            for (0..handoff.role_count) |index| {
                if (std.mem.eql(u8, name, self.names[index][0..self.name_lens[index]])) {
                    if (observed[index]) return error.AuthorityChanged;
                    observed[index] = true;
                    matched = true;
                    break;
                }
            }
            if (!matched) return error.AuthorityChanged;
        }
        if (c._errno().* != 0) return error.AuthorityChanged;
        if (count != handoff.role_count) return error.AuthorityChanged;
        for (observed) |present| if (!present) return error.AuthorityChanged;
    }

    fn closeDescriptors(self: *@This(), reset: bool) Error!void {
        var descriptors: [handoff.role_count * 2 + artifact_count * 2 + 2]c.fd_t = undefined;
        var count: usize = 0;
        for (&self.entries) |*entry| {
            descriptors[count] = entry.fd;
            descriptors[count + 1] = entry.parent_fd;
            count += 2;
            entry.* = .{};
        }
        for (&self.artifacts) |*artifact| {
            descriptors[count] = artifact.fd;
            descriptors[count + 1] = artifact.parent_fd;
            count += 2;
            artifact.* = .{};
        }
        descriptors[count] = self.directory_fd;
        descriptors[count + 1] = self.parent_fd;
        self.directory_fd = -1;
        self.parent_fd = -1;
        var failed = false;
        for (descriptors[0 .. count + 2]) |fd| if (fd >= 0 and c.close(fd) != 0) {
            failed = true;
        };
        if (reset) self.* = .{};
        if (failed) return error.DescriptorCloseFailed;
    }
};

pub fn openAndVerify(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    paths: Paths,
    cli: Cli,
    output: []u8,
    budget_ns: i128,
    result: *ReopenedAggregate,
) Error!void {
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(budget_ns, &deadline);
    defer deadline.deinit() catch {};
    var executor = attestation.BoundedExecutor{ .io = io };
    var cli_impl = RealCli{};
    var verifier = RealVerifier{};
    return openAndVerifyUsing(&cli_impl, &verifier, &executor, &deadline, allocator, context, paths, cli, output, result);
}

pub fn openAndVerifyUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    paths: Paths,
    cli: Cli,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *ReopenedAggregate,
) Error!void {
    _ = try deadline.remaining();
    var executor = attestation.BoundedExecutor{ .io = io };
    var cli_impl = RealCli{};
    var verifier = RealVerifier{};
    return openAndVerifyUsing(&cli_impl, &verifier, &executor, deadline, allocator, context, paths, cli, output, result);
}

pub fn openAndVerifyWith(
    cli_impl: anytype,
    verifier: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    paths: Paths,
    cli: Cli,
    output: []u8,
    result: *ReopenedAggregate,
) !void {
    if (!builtin.is_test) @compileError("openAndVerifyWith is a test-only seam");
    return openAndVerifyUsing(cli_impl, verifier, executor, deadline, allocator, context, paths, cli, output, result);
}

fn openAndVerifyUsing(
    cli_impl: anytype,
    verifier: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    paths: Paths,
    cli: Cli,
    output: []u8,
    result: *ReopenedAggregate,
) !void {
    try validateInputs(context, paths, cli, output, result);
    result.* = .{ .owner = result, .phase = .preparing };
    openAndVerifyCore(cli_impl, verifier, executor, deadline, allocator, context, paths, cli, output, result) catch |err| {
        result.closeDescriptors(true) catch return error.CleanupFailed;
        return err;
    };
}

fn openAndVerifyCore(
    cli_impl: anytype,
    verifier: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    paths: Paths,
    cli: Cli,
    output: []u8,
    result: *ReopenedAggregate,
) !void {
    try storeInputs(result, context, paths, cli.path);
    revalidateCli(cli_impl, allocator, cli.path, cli.pinned) catch |err| switch (err) {
        error.ExecutableChanged => return error.AuthorityChanged,
        else => return err,
    };
    try openDirectory(result, paths.directory);
    try discoverNames(result);
    try pinEntries(result);
    try pinArtifacts(result);
    result.seal = metadataSeal(result);
    try result.fenceInternal();
    revalidateCli(cli_impl, allocator, cli.path, cli.pinned) catch |err| switch (err) {
        error.ExecutableChanged => return error.AuthorityChanged,
        else => return err,
    };

    const artifact_indexes = [_]usize{ 0, 1, 0, 2 };
    const bundle_indexes = [_]usize{ 1, 2, 3, 4 };
    for (0..verification_count) |index| {
        _ = try deadline.remaining();
        try result.fenceInternal();
        revalidateCli(cli_impl, allocator, cli.path, cli.pinned) catch |err| switch (err) {
            error.ExecutableChanged => return error.AuthorityChanged,
            else => return err,
        };
        const artifact_path: []const u8 = if (index == 2)
            result.paths[0][0..result.path_lens[0]]
        else
            result.artifact_paths[artifact_indexes[index]][0..result.artifact_path_lens[artifact_indexes[index]]];
        const artifact_observation = if (index == 2)
            result.entries[0].value().?
        else
            result.artifacts[artifact_indexes[index]].value().?;
        const bundle_path = result.paths[bundle_indexes[index]][0..result.path_lens[bundle_indexes[index]]];
        const expected: attestation.Expected = .{
            .context = result.context.value(),
            .subject_name = std.fs.path.basename(artifact_path),
            .subject_sha256 = &artifact_observation.sha256,
        };
        var plan_storage: attestation.ArgsStorage = undefined;
        _ = try attestation.planBundle(&plan_storage, artifact_path, bundle_path, expected);
        var observed = try verifier.verifyBundleWith(
            executor,
            allocator,
            cli.path,
            artifact_path,
            bundle_path,
            expected,
            output,
            try deadline.remaining(),
        );
        defer observed.deinit(allocator);
        if (!observed.verified or observed.run_id != expected.context.build.run_id or
            observed.run_attempt != expected.context.build.run_attempt or
            !std.mem.eql(u8, observed.subject_name, expected.subject_name) or
            !std.mem.eql(u8, observed.subject_sha256, expected.subject_sha256)) return error.AttestationMismatch;
        try result.fenceInternal();
        revalidateCli(cli_impl, allocator, cli.path, cli.pinned) catch |err| switch (err) {
            error.ExecutableChanged => return error.AuthorityChanged,
            else => return err,
        };
    }
    _ = try deadline.remaining();
    try result.fenceInternal();
    revalidateCli(cli_impl, allocator, cli.path, cli.pinned) catch |err| switch (err) {
        error.ExecutableChanged => return error.AuthorityChanged,
        else => return err,
    };
    result.phase = .verified;
    result.seal = metadataSeal(result);
}

fn revalidateCli(cli_impl: anytype, allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable) !void {
    try cli_impl.revalidate(allocator, path, pinned);
}

const RealCli = struct {
    fn revalidate(_: *@This(), allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable) !void {
        try cli_authority.revalidate(allocator, path, pinned);
    }
};

const RealVerifier = struct {
    fn verifyBundleWith(
        _: *@This(),
        executor: *attestation.BoundedExecutor,
        allocator: std.mem.Allocator,
        executable: []const u8,
        artifact_path: []const u8,
        bundle_path: []const u8,
        expected: attestation.Expected,
        output: []u8,
        budget_ns: i128,
    ) !attestation.Observed {
        return attestation.verifyBundleWith(executor, allocator, executable, artifact_path, bundle_path, expected, output, budget_ns);
    }
};

fn validateInputs(context: context_mod.Context, paths: Paths, cli: Cli, output: []u8, result: *const ReopenedAggregate) Error!void {
    if (!pristine(result)) return error.InvalidOwner;
    const all_paths = [_][]const u8{ paths.directory, paths.dmg, paths.frozen_executable, paths.manifest, cli.path };
    for (all_paths) |path| if (!canonicalAbsolute(path)) return error.InvalidPath;
    for (all_paths, 0..) |left, index| for (all_paths[index + 1 ..]) |right| {
        if (std.mem.eql(u8, left, right)) return error.InvalidPath;
    };
    for (all_paths[1..]) |path| if (sameOrDescendant(paths.directory, path)) return error.InvalidPath;
    if (context.repository.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or !context.protected_tag or
        context.tag.len < 2 or context.tag.len > context_mod.max_value_bytes or
        context.source_commit.len != 40 or context.build.workflow_ref.len == 0 or
        context.build.workflow_ref.len > context_mod.max_value_bytes or context.build.run_id == 0 or
        context.build.run_attempt == 0 or output.len == 0 or output.len > attestation.max_response_bytes) return error.InvalidPath;
    var expected_dmg: [context_mod.max_value_bytes]u8 = undefined;
    var expected_frozen: [context_mod.max_value_bytes]u8 = undefined;
    var expected_manifest: [context_mod.max_value_bytes]u8 = undefined;
    const version = context.tag[1..];
    const dmg_name = std.fmt.bufPrint(&expected_dmg, "Maru-{s}-universal.dmg", .{version}) catch return error.InvalidPath;
    const frozen_name = std.fmt.bufPrint(&expected_frozen, "maru-session-host-{s}", .{version}) catch return error.InvalidPath;
    const manifest_name = std.fmt.bufPrint(&expected_manifest, "Maru-{s}-session-host-release.json", .{version}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.dmg), dmg_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.frozen_executable), frozen_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.manifest), manifest_name)) return error.InvalidPath;
    const owner = std.mem.asBytes(result);
    const regions = [_][]const u8{
        context.repository.owner,   context.repository.name, context.tag,                 context.source_commit,
        context.build.workflow_ref, paths.directory,         paths.dmg,                   paths.frozen_executable,
        paths.manifest,             cli.path,                std.mem.asBytes(cli.pinned), output,
    };
    for (regions, 0..) |region, index| {
        if (overlaps(owner, region)) return error.InvalidOwner;
        for (regions[0..index]) |prior| if (overlaps(region, prior)) return error.InvalidOwner;
    }
}

fn storeInputs(result: *ReopenedAggregate, context: context_mod.Context, paths: Paths, cli_path: [:0]const u8) Error!void {
    result.directory_len = try storePath(&result.directory, paths.directory);
    result.artifact_path_lens[0] = try storePath(&result.artifact_paths[0], paths.dmg);
    result.artifact_path_lens[1] = try storePath(&result.artifact_paths[1], paths.frozen_executable);
    result.artifact_path_lens[2] = try storePath(&result.artifact_paths[2], paths.manifest);
    result.cli_path_len = try storePath(&result.cli_path, cli_path);
    result.context.repository_id = context.repository.id;
    result.context.tag_len = context.tag.len;
    @memcpy(result.context.tag[0..context.tag.len], context.tag);
    @memcpy(&result.context.source_commit, context.source_commit);
    result.context.workflow_ref_len = context.build.workflow_ref.len;
    @memcpy(result.context.workflow_ref[0..context.build.workflow_ref.len], context.build.workflow_ref);
    result.context.run_id = context.build.run_id;
    result.context.run_attempt = context.build.run_attempt;
}

fn openDirectory(result: *ReopenedAggregate, path: [:0]const u8) Error!void {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_storage, "{s}", .{parent_path}) catch return error.InvalidPath;
    result.parent_fd = safe_open.openAbsoluteNoFollow(parent_z, true) catch return error.InvalidPath;
    result.directory_fd = safe_open.openAbsoluteNoFollow(path, true) catch return error.InvalidInventory;
    const leaf = std.fs.path.basename(path);
    result.directory_leaf_len = try storeName(&result.directory_leaf, leaf);
    var held: posix.Stat = undefined;
    var named: posix.Stat = undefined;
    const leaf_z: [:0]const u8 = result.directory_leaf[0..result.directory_leaf_len :0];
    if (c.fstat(result.directory_fd, &held) != 0 or c.fstatat(result.parent_fd, leaf_z.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !validDirectoryStat(held) or !sameIdentityStat(held, named)) return error.InvalidInventory;
    result.directory_device = @intCast(held.dev);
    result.directory_inode = @intCast(held.ino);
}

fn discoverNames(result: *ReopenedAggregate) Error!void {
    var found: [verification_count]bool = @splat(false);
    var evidence_name: [std.fs.max_name_bytes:0]u8 = @splat(0);
    var evidence_len: usize = 0;
    const scan_fd = c.openat(result.directory_fd, ".", posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (scan_fd < 0) return error.InvalidInventory;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.InvalidInventory;
    };
    defer _ = c.closedir(directory);
    var count: usize = 0;
    c._errno().* = 0;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count > handoff.role_count or !validComponent(name)) return error.InvalidInventory;
        var role: ?usize = null;
        for (0..verification_count) |index| {
            if (std.mem.eql(u8, name, handoff.destinationName(@enumFromInt(index + 1), ""))) {
                role = index;
                break;
            }
        }
        if (role) |index| {
            if (found[index]) return error.InvalidInventory;
            found[index] = true;
        } else {
            if (evidence_len != 0) return error.InvalidInventory;
            evidence_len = try storeName(&evidence_name, name);
        }
    }
    if (c._errno().* != 0) return error.InvalidInventory;
    if (count != handoff.role_count or evidence_len == 0) return error.InvalidInventory;
    for (found) |present| if (!present) return error.InvalidInventory;
    result.name_lens[0] = try storeName(&result.names[0], evidence_name[0..evidence_len]);
    for (1..handoff.role_count) |index| {
        result.name_lens[index] = try storeName(&result.names[index], handoff.destinationName(@enumFromInt(index), ""));
    }
}

fn pinEntries(result: *ReopenedAggregate) Error!void {
    const directory: [:0]const u8 = result.directory[0..result.directory_len :0];
    for (0..handoff.role_count) |index| {
        const name = result.names[index][0..result.name_lens[index]];
        const path = std.fmt.bufPrintZ(&result.paths[index], "{s}/{s}", .{ directory, name }) catch return error.InvalidPath;
        result.path_lens[index] = path.len;
        files.pinReleaseFileObserved(&result.entries[index], path, false, if (index == 0) release_manifest.max_evidence_bytes else handoff.max_attestation_bundle_bytes) catch return error.InvalidInventory;
        const observation = result.entries[index].value().?;
        if (observation.mode & 0o777 != 0o600 or !parentMatches(result.entries[index].parent_fd, result.directory_fd)) return error.InvalidInventory;
    }
    var identities: [handoff.role_count]files.Identity = undefined;
    for (&result.entries, 0..) |*entry, index| identities[index] = entry.value().?.identity;
    files.requireDistinct(&identities) catch return error.InvalidInventory;
}

fn pinArtifacts(result: *ReopenedAggregate) Error!void {
    const caps = [_]u64{ files.max_release_asset_bytes, files.max_release_asset_bytes, release_manifest.max_manifest_bytes };
    for (&result.artifacts, 0..) |*artifact, index| {
        const path: [:0]const u8 = result.artifact_paths[index][0..result.artifact_path_lens[index] :0];
        files.pinReleaseFileObserved(artifact, path, index == 1, caps[index]) catch return error.InvalidInventory;
    }
    try requireAllDistinct(result);
}

fn requireAllDistinct(result: *const ReopenedAggregate) Error!void {
    var identities: [handoff.role_count + artifact_count]files.Identity = undefined;
    for (&result.entries, 0..) |*entry, index| identities[index] = (entry.value() orelse return error.AuthorityChanged).identity;
    for (&result.artifacts, 0..) |*artifact, index| identities[handoff.role_count + index] = (artifact.value() orelse return error.AuthorityChanged).identity;
    files.requireDistinct(&identities) catch return error.AuthorityChanged;
}

fn pristine(result: *const ReopenedAggregate) bool {
    if (result.owner != null or result.phase != .pristine or result.parent_fd >= 0 or result.directory_fd >= 0 or
        result.directory_len != 0 or result.directory_leaf_len != 0 or result.cli_path_len != 0) return false;
    for (result.entries) |entry| if (entry.owner != null or entry.fd >= 0 or entry.parent_fd >= 0) return false;
    for (result.artifacts) |artifact| if (artifact.owner != null or artifact.fd >= 0 or artifact.parent_fd >= 0) return false;
    return true;
}

fn validStorage(result: *const ReopenedAggregate) bool {
    if (result.directory_len == 0 or result.directory_len >= result.directory.len or result.directory[result.directory_len] != 0 or
        result.directory_leaf_len == 0 or result.directory_leaf_len >= result.directory_leaf.len or result.directory_leaf[result.directory_leaf_len] != 0 or
        result.cli_path_len == 0 or result.cli_path_len >= result.cli_path.len or result.cli_path[result.cli_path_len] != 0 or
        !std.mem.eql(u8, std.fs.path.basename(result.directory[0..result.directory_len]), result.directory_leaf[0..result.directory_leaf_len])) return false;
    for (0..handoff.role_count) |index| {
        if (result.name_lens[index] == 0 or result.name_lens[index] >= result.names[index].len or result.names[index][result.name_lens[index]] != 0 or
            result.path_lens[index] == 0 or result.path_lens[index] >= result.paths[index].len or result.paths[index][result.path_lens[index]] != 0 or
            !std.mem.eql(u8, std.fs.path.basename(result.paths[index][0..result.path_lens[index]]), result.names[index][0..result.name_lens[index]]) or
            !std.mem.eql(u8, std.fs.path.dirname(result.paths[index][0..result.path_lens[index]]) orelse return false, result.directory[0..result.directory_len])) return false;
    }
    for (0..artifact_count) |index| if (result.artifact_path_lens[index] == 0 or
        result.artifact_path_lens[index] >= result.artifact_paths[index].len or
        result.artifact_paths[index][result.artifact_path_lens[index]] != 0) return false;
    return true;
}

fn metadataSeal(result: *const ReopenedAggregate) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const address = @intFromPtr(result);
    hasher.update(std.mem.asBytes(&address));
    hasher.update(std.mem.asBytes(&result.phase));
    hasher.update(std.mem.asBytes(&result.directory_device));
    hasher.update(std.mem.asBytes(&result.directory_inode));
    hasher.update(result.directory[0..result.directory_len]);
    hasher.update(result.directory_leaf[0..result.directory_leaf_len]);
    hasher.update(result.cli_path[0..result.cli_path_len]);
    hasher.update(std.mem.asBytes(&result.context.repository_id));
    hasher.update(result.context.tag[0..result.context.tag_len]);
    hasher.update(&result.context.source_commit);
    hasher.update(result.context.workflow_ref[0..result.context.workflow_ref_len]);
    hasher.update(std.mem.asBytes(&result.context.run_id));
    hasher.update(std.mem.asBytes(&result.context.run_attempt));
    for (0..handoff.role_count) |index| {
        hasher.update(result.names[index][0..result.name_lens[index]]);
        hasher.update(result.paths[index][0..result.path_lens[index]]);
        if (result.entries[index].value()) |observation| hashObservation(&hasher, observation);
    }
    for (0..artifact_count) |index| {
        hasher.update(result.artifact_paths[index][0..result.artifact_path_lens[index]]);
        if (result.artifacts[index].value()) |observation| hashObservation(&hasher, observation);
    }
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn hashObservation(hasher: *std.crypto.hash.Blake3, observation: files.ExecutableObservation) void {
    hasher.update(std.mem.asBytes(&observation.identity.device));
    hasher.update(std.mem.asBytes(&observation.identity.inode));
    hasher.update(std.mem.asBytes(&observation.size));
    hasher.update(std.mem.asBytes(&observation.mode));
    hasher.update(&observation.sha256);
}

fn parentMatches(parent_fd: c.fd_t, directory_fd: c.fd_t) bool {
    var parent: posix.Stat = undefined;
    var directory: posix.Stat = undefined;
    return c.fstat(parent_fd, &parent) == 0 and c.fstat(directory_fd, &directory) == 0 and sameIdentityStat(parent, directory);
}

fn validDirectoryStat(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o700;
}

fn sameIdentityStat(left: posix.Stat, right: posix.Stat) bool {
    return left.dev == right.dev and left.ino == right.ino and left.mode == right.mode and left.uid == right.uid;
}

fn storePath(storage: *[std.fs.max_path_bytes:0]u8, value: []const u8) Error!usize {
    if (!canonicalAbsolute(value) or value.len >= storage.len) return error.InvalidPath;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return value.len;
}

fn storeName(storage: *[std.fs.max_name_bytes:0]u8, value: []const u8) Error!usize {
    if (!validComponent(value) or value.len >= storage.len) return error.InvalidInventory;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return value.len;
}

fn canonicalAbsolute(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len == 0 or value.len >= std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, value, 0) != null or (value.len > 1 and std.mem.endsWith(u8, value, "/"))) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| if (!validComponent(component)) return false;
    return true;
}

fn validComponent(value: []const u8) bool {
    return value.len != 0 and value.len <= std.fs.max_name_bytes and !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..") and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn sameOrDescendant(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
