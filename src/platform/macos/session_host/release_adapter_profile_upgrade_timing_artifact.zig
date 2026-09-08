//! Publishes credential-free upgrade-B timing diagnostics as one pinned private artifact.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const context_mod = @import("release_adapter_context");
const execution_mod = @import("release_adapter_profile_upgrade_execution");
const files = @import("release_adapter_files");
const safe_open = @import("safe_open");

pub const schema = "maru.session-host-profile-upgrade-timing.v1";
pub const profile = "upgrade_b";
const artifact_cap: usize = 1024 * 1024;

pub const TimingView = struct {
    predecessor_auth_ns: u64,
    signed_one_ns: u64,
    signed_near_max_ns: u64,
    runner_phase_ns: u64,
    profile_phase_ns: u64,
};

pub const Snapshot = struct {
    context: context_mod.Context,
    timing: TimingView,
};

pub const Phase = enum { pristine, open, audit_required, cleanup_required, retained_closed };

pub const Value = struct {
    path: []const u8,
    observation: files.ExecutableObservation,
    audit_required: bool,
};

pub const Artifact = struct {
    owner: ?*@This() = null,
    phase: Phase = .pristine,
    file: files.PinnedReleaseFile = .{},
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination_len: usize = 0,
    leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),
    leaf_len: usize = 0,
    leaf_present: bool = false,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.phase == .pristine and self.file.owner == null and
            self.file.fd < 0 and self.file.parent_fd < 0 and self.destination_len == 0 and self.leaf_len == 0 and !self.leaf_present;
    }

    pub fn value(self: *const @This()) ?Value {
        if (self.owner != self or (self.phase != .open and self.phase != .audit_required) or !self.leaf_present or
            self.file.owner != &self.file or !validStorage(self)) return null;
        return .{
            .path = self.destination[0..self.destination_len],
            .observation = self.file.value() orelse return null,
            .audit_required = self.phase == .audit_required,
        };
    }

    pub fn revalidate(self: *const @This()) !Value {
        const current = self.value() orelse return error.InvalidOwner;
        const path: [:0]const u8 = self.destination[0..self.destination_len :0];
        const observation = try self.file.revalidate(path);
        if (!sameObservation(current.observation, observation)) return error.FileChanged;
        try validatePrivateParent(self.file.parent_fd);
        return .{ .path = path, .observation = observation, .audit_required = current.audit_required };
    }

    /// Drops descriptor authority only after the final pathname, inode, bytes, and private parent
    /// fence. The retained pathname is deliberately not a cleanup capability; a later process
    /// must reopen and authenticate it before either upload or deletion.
    pub fn closeRetaining(self: *@This()) !void {
        if (self.owner != self or self.phase != .open or !self.leaf_present or
            self.file.owner != &self.file or !validStorage(self)) return error.InvalidOwner;
        _ = try self.revalidate();
        try self.file.deinit();
        self.phase = .retained_closed;
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self or (self.phase != .open and self.phase != .audit_required and self.phase != .cleanup_required) or
            self.file.owner != &self.file or !validStorage(self)) return error.InvalidOwner;
        if (self.leaf_present) {
            _ = self.revalidate() catch return error.CleanupFailed;
            var held: posix.Stat = undefined;
            var named: posix.Stat = undefined;
            const leaf: [:0]const u8 = self.leaf[0..self.leaf_len :0];
            if (c.fstat(self.file.fd, &held) != 0 or
                c.fstatat(self.file.parent_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                held.dev != named.dev or held.ino != named.ino or !posix.S.ISREG(held.mode) or held.nlink != 1 or
                c.unlinkat(self.file.parent_fd, leaf.ptr, 0) != 0) return error.CleanupFailed;
            self.leaf_present = false;
            self.phase = .cleanup_required;
        }
        if (c.fsync(self.file.parent_fd) != 0) return error.CleanupFailed;
        self.file.deinit() catch return error.CleanupFailed;
        self.* = .{};
    }
};

pub fn validateTiming(value: TimingView) !void {
    if (value.predecessor_auth_ns == 0 or value.signed_one_ns == 0 or value.signed_near_max_ns == 0 or
        value.runner_phase_ns == 0 or value.profile_phase_ns == 0) return error.InvalidTiming;
    const runner_min = std.math.add(u64, value.signed_one_ns, value.signed_near_max_ns) catch return error.InvalidTiming;
    if (value.runner_phase_ns < runner_min) return error.InvalidTiming;
    const profile_min = std.math.add(u64, value.predecessor_auth_ns, value.runner_phase_ns) catch return error.InvalidTiming;
    if (value.profile_phase_ns < profile_min) return error.InvalidTiming;
}

pub fn publish(allocator: std.mem.Allocator, context: context_mod.Context, execution: *const execution_mod.ProfileUpgradeExecution, output: [:0]const u8, result: *Artifact) !void {
    var authority = Authority{ .context = context, .execution = execution };
    return publishOwned(allocator, &authority, output, result);
}

pub fn publishWith(allocator: std.mem.Allocator, authority: anytype, output: [:0]const u8, result: *Artifact) !void {
    if (!builtin.is_test) @compileError("publishWith is test-only");
    return publishOwned(allocator, authority, output, result);
}

pub fn reopen(allocator: std.mem.Allocator, output: [:0]const u8, context: context_mod.Context, result: *Artifact) !void {
    if (!result.isPristineForComposition() or overlaps(std.mem.asBytes(result), output) or
        overlaps(std.mem.asBytes(result), std.mem.asBytes(&context))) return error.InvalidOwner;
    try validatePath(output);
    try context_mod.validateTrusted(context);
    const leaf = std.fs.path.basename(output);
    if (output.len >= result.destination.len or leaf.len == 0 or leaf.len >= result.leaf.len) return error.InvalidPath;
    try files.pinReleaseFileObserved(&result.file, output, false, artifact_cap);
    errdefer {
        result.file.deinit() catch {};
        result.* = .{};
    }
    try validatePrivateParent(result.file.parent_fd);
    var input = try result.file.readHeldAlloc(allocator, output, artifact_cap);
    defer input.deinit(allocator);
    const parsed = try std.json.parseFromSlice(Wire, allocator, input.bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const snapshot = try snapshotFromWire(parsed.value, context);
    const canonical = try writeCanonical(allocator, snapshot);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, input.bytes)) return error.InvalidArtifact;
    @memcpy(result.destination[0..output.len], output);
    result.destination[output.len] = 0;
    result.destination_len = output.len;
    @memcpy(result.leaf[0..leaf.len], leaf);
    result.leaf[leaf.len] = 0;
    result.leaf_len = leaf.len;
    result.leaf_present = true;
    result.owner = result;
    result.phase = .open;
    _ = try result.revalidate();
}

const Authority = struct {
    context: context_mod.Context,
    execution: *const execution_mod.ProfileUpgradeExecution,

    pub fn revalidate(self: *const @This()) !Snapshot {
        try context_mod.validateTrusted(self.context);
        if (!self.execution.ownsSuccessfulOutputs()) return error.InvalidOwner;
        const timing = timingFromExecution(self.execution.timing);
        try validateTiming(timing);
        return .{ .context = self.context, .timing = timing };
    }
};

fn publishOwned(allocator: std.mem.Allocator, authority: anytype, output: [:0]const u8, result: *Artifact) !void {
    if (!result.isPristineForComposition() or overlaps(std.mem.asBytes(result), output) or
        overlaps(std.mem.asBytes(result), std.mem.asBytes(authority))) return error.InvalidOwner;
    try validatePath(output);
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = std.fmt.bufPrintZ(&parent_buf, "{s}", .{std.fs.path.dirname(output) orelse return error.InvalidPath}) catch
        return error.InvalidPath;
    const preflight_parent_fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.UnsafePath;
    defer _ = c.close(preflight_parent_fd);
    const parent_identity = try privateParentIdentity(preflight_parent_fd);
    const leaf = std.fs.path.basename(output);
    if (output.len >= result.destination.len or leaf.len == 0 or leaf.len >= result.leaf.len) return error.InvalidPath;

    const before = try authority.revalidate();
    try validateSnapshot(before);
    const canonical = try writeCanonical(allocator, before);
    defer allocator.free(canonical);
    try files.publishSummaryOwnedExclusive(&result.file, output, canonical);
    @memcpy(result.destination[0..output.len], output);
    result.destination[output.len] = 0;
    result.destination_len = output.len;
    @memcpy(result.leaf[0..leaf.len], leaf);
    result.leaf[leaf.len] = 0;
    result.leaf_len = leaf.len;
    result.leaf_present = true;
    result.owner = result;
    result.phase = .audit_required;

    const published_parent = privateParentIdentity(result.file.parent_fd) catch return error.AuthorityChanged;
    if (parent_identity.device != published_parent.device or parent_identity.inode != published_parent.inode)
        return error.AuthorityChanged;
    const after = authority.revalidate() catch return error.AuthorityChanged;
    validateSnapshot(after) catch return error.AuthorityChanged;
    if (!sameSnapshot(before, after)) return error.AuthorityChanged;
    var current = result.file.readHeldAlloc(allocator, output, artifact_cap) catch return error.FileChanged;
    defer current.deinit(allocator);
    if (!std.mem.eql(u8, canonical, current.bytes)) return error.FileChanged;
    result.phase = .open;
}

fn timingFromExecution(value: execution_mod.TimingDiagnostic) TimingView {
    return .{
        .predecessor_auth_ns = value.predecessor_auth_ns,
        .signed_one_ns = value.signed_one_ns,
        .signed_near_max_ns = value.signed_near_max_ns,
        .runner_phase_ns = value.runner_phase_ns,
        .profile_phase_ns = value.profile_phase_ns,
    };
}

fn validateSnapshot(value: Snapshot) !void {
    try context_mod.validateTrusted(value.context);
    try validateTiming(value.timing);
}

fn writeCanonical(allocator: std.mem.Allocator, value: Snapshot) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"schema\":\"{s}\",\"profile\":\"{s}\",\"repository_id\":{d},\"repository\":\"{s}/{s}\",\"tag\":\"{s}\",\"source_commit\":\"{s}\",\"workflow_ref\":\"{s}\",\"run_id\":{d},\"run_attempt\":{d},\"predecessor_auth_ns\":{d},\"signed_one_ns\":{d},\"signed_near_max_ns\":{d},\"runner_phase_ns\":{d},\"profile_phase_ns\":{d}}}\n", .{ schema, profile, value.context.repository.id, value.context.repository.owner, value.context.repository.name, value.context.tag, value.context.source_commit, value.context.build.workflow_ref, value.context.build.run_id, value.context.build.run_attempt, value.timing.predecessor_auth_ns, value.timing.signed_one_ns, value.timing.signed_near_max_ns, value.timing.runner_phase_ns, value.timing.profile_phase_ns });
}

const Wire = struct {
    schema: []const u8,
    profile: []const u8,
    repository_id: u64,
    repository: []const u8,
    tag: []const u8,
    source_commit: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    predecessor_auth_ns: u64,
    signed_one_ns: u64,
    signed_near_max_ns: u64,
    runner_phase_ns: u64,
    profile_phase_ns: u64,
};

fn snapshotFromWire(value: Wire, context: context_mod.Context) !Snapshot {
    var repository_buf: [context_mod.max_value_bytes]u8 = undefined;
    const repository = std.fmt.bufPrint(&repository_buf, "{s}/{s}", .{ context.repository.owner, context.repository.name }) catch
        return error.InvalidArtifact;
    if (!std.mem.eql(u8, value.schema, schema) or !std.mem.eql(u8, value.profile, profile) or
        value.repository_id != context.repository.id or !std.mem.eql(u8, value.repository, repository) or
        !std.mem.eql(u8, value.tag, context.tag) or !std.mem.eql(u8, value.source_commit, context.source_commit) or
        !std.mem.eql(u8, value.workflow_ref, context.build.workflow_ref) or value.run_id != context.build.run_id or
        value.run_attempt != context.build.run_attempt) return error.BindingMismatch;
    const timing: TimingView = .{ .predecessor_auth_ns = value.predecessor_auth_ns, .signed_one_ns = value.signed_one_ns, .signed_near_max_ns = value.signed_near_max_ns, .runner_phase_ns = value.runner_phase_ns, .profile_phase_ns = value.profile_phase_ns };
    try validateTiming(timing);
    return .{ .context = context, .timing = timing };
}

fn validatePrivateParent(fd: c.fd_t) !void {
    _ = try privateParentIdentity(fd);
}

const ParentIdentity = struct { device: u64, inode: u64 };

fn privateParentIdentity(fd: c.fd_t) !ParentIdentity {
    var stat: posix.Stat = undefined;
    if (fd < 0 or c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or
        stat.uid != c.geteuid() or stat.mode & 0o777 != 0o700) return error.UnsafePath;
    return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
}

fn validatePath(value: []const u8) !void {
    if (!std.fs.path.isAbsolute(value) or value.len < 2 or value.len >= std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, value, 0) != null or std.mem.endsWith(u8, value, "/")) return error.InvalidPath;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, "..")) return error.InvalidPath;
}

fn validStorage(value: *const Artifact) bool {
    if (value.destination_len == 0 or value.destination_len >= value.destination.len or value.leaf_len == 0 or
        value.leaf_len >= value.leaf.len or value.destination[value.destination_len] != 0 or value.leaf[value.leaf_len] != 0) return false;
    return std.mem.eql(u8, std.fs.path.basename(value.destination[0..value.destination_len]), value.leaf[0..value.leaf_len]);
}

fn sameSnapshot(a: Snapshot, b: Snapshot) bool {
    return a.context.repository.id == b.context.repository.id and
        std.mem.eql(u8, a.context.repository.owner, b.context.repository.owner) and
        std.mem.eql(u8, a.context.repository.name, b.context.repository.name) and
        std.mem.eql(u8, a.context.tag, b.context.tag) and std.mem.eql(u8, a.context.source_commit, b.context.source_commit) and
        std.mem.eql(u8, a.context.build.workflow_ref, b.context.build.workflow_ref) and
        a.context.build.run_id == b.context.build.run_id and a.context.build.run_attempt == b.context.build.run_attempt and
        a.context.protected_tag == b.context.protected_tag and std.meta.eql(a.timing, b.timing);
}

fn sameObservation(a: files.ExecutableObservation, b: files.ExecutableObservation) bool {
    return a.identity.device == b.identity.device and a.identity.inode == b.identity.inode and a.size == b.size and
        a.mode == b.mode and std.mem.eql(u8, &a.sha256, &b.sha256);
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}
