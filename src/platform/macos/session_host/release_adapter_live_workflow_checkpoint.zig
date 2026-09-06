//! Fixed, descriptor-relative reducer checkpoints for independent Actions stage processes.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const context = @import("release_adapter_context");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_live_workflow_state_handoff");
const phase = @import("release_adapter_live_workflow_phase");
const safe_open = @import("safe_open");

pub const leaf_count: usize = leaf_names.len;
const leaf_names = [_][:0]const u8{
    "00-initial.state",
    "01-candidate-pinning.state",
    "02-candidate-attestation.state",
    "03-draft-authoring.state",
    "04-authored-attestation.state",
    "05-aggregate-prepare.state",
    "06-aggregate-finalize.state",
    "07-publication.state",
    "08-aggregate-cleanup.state",
};
const stages = [_]phase.Stage{
    .candidate_pinning,
    .candidate_attestation,
    .draft_authoring,
    .authored_attestation,
    .aggregate_prepare,
    .aggregate_finalize,
    .publication,
    .aggregate_cleanup,
};

pub const Error = handoff.Error || error{
    InvalidCheckpoint,
    InvalidOwner,
    InvocationBusy,
    RootChanged,
    UnsafeRoot,
};

pub const RootIdentity = struct {
    device: u64,
    inode: u64,
    uid: u32,
    mode: u32,
};
pub const max_root_identity_token_bytes: usize = 80;
const root_identity_prefix = "maru-root-v1:";

pub fn encodeRootIdentity(storage: *[max_root_identity_token_bytes:0]u8, value: RootIdentity) Error![:0]const u8 {
    if (!validRootIdentity(value)) return error.UnsafeRoot;
    return std.fmt.bufPrintZ(storage, root_identity_prefix ++ "{x:0>16}-{x:0>16}-{x:0>8}-{x:0>8}", .{
        value.device, value.inode, value.uid, value.mode,
    }) catch return error.UnsafeRoot;
}

pub fn decodeRootIdentity(token: []const u8) Error!RootIdentity {
    if (token.len != root_identity_prefix.len + 16 + 1 + 16 + 1 + 8 + 1 + 8 or
        !std.mem.startsWith(u8, token, root_identity_prefix) or token[root_identity_prefix.len + 16] != '-' or
        token[root_identity_prefix.len + 33] != '-' or token[root_identity_prefix.len + 42] != '-') return error.UnsafeRoot;
    const offset = root_identity_prefix.len;
    const value: RootIdentity = .{
        .device = std.fmt.parseInt(u64, token[offset..][0..16], 16) catch return error.UnsafeRoot,
        .inode = std.fmt.parseInt(u64, token[offset + 17 ..][0..16], 16) catch return error.UnsafeRoot,
        .uid = std.fmt.parseInt(u32, token[offset + 34 ..][0..8], 16) catch return error.UnsafeRoot,
        .mode = std.fmt.parseInt(u32, token[offset + 43 ..][0..8], 16) catch return error.UnsafeRoot,
    };
    var canonical: [max_root_identity_token_bytes:0]u8 = undefined;
    if (!std.mem.eql(u8, token, try encodeRootIdentity(&canonical, value))) return error.UnsafeRoot;
    return value;
}

pub const Root = struct {
    owner: ?*Root = null,
    fd: c.fd_t = -1,
    device: u64 = 0,
    inode: u64 = 0,
    uid: u32 = 0,
    mode: u32 = 0,
    invocation_active: bool = false,
    path_len: usize = 0,
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn value(self: *const @This()) Error!RootIdentity {
        if (self.owner != self or self.fd < 0 or self.invocation_active) return error.InvalidOwner;
        return .{ .device = self.device, .inode = self.inode, .uid = self.uid, .mode = self.mode };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0) return error.InvalidOwner;
        if (self.invocation_active) return error.InvocationBusy;
        _ = c.close(self.fd);
        self.* = .{};
    }

    fn revalidate(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0 or self.path_len == 0) return error.InvalidOwner;
        var held: posix.Stat = undefined;
        if (c.fstat(self.fd, &held) != 0 or !self.matches(held)) return error.RootChanged;
        const reopened = safe_open.openAbsoluteNoFollow(self.path[0..self.path_len :0], true) catch return error.RootChanged;
        defer _ = c.close(reopened);
        var named: posix.Stat = undefined;
        if (c.fstat(reopened, &named) != 0 or !self.matches(named)) return error.RootChanged;
    }

    fn beginInvocation(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0) return error.InvalidOwner;
        if (self.invocation_active) return error.InvocationBusy;
        try self.revalidate();
        self.invocation_active = true;
    }

    fn endInvocation(self: *@This()) void {
        if (self.owner == self) self.invocation_active = false;
    }

    fn matches(self: *const @This(), stat: posix.Stat) bool {
        return posix.S.ISDIR(stat.mode) and stat.mode & 0o777 == 0o700 and
            stat.dev == self.device and stat.ino == self.inode and stat.uid == self.uid and
            stat.uid == c.geteuid() and @as(u32, @intCast(stat.mode)) == self.mode;
    }
};

pub fn invoke(
    root: *Root,
    payload: *anyopaque,
    call: *const fn (*anyopaque) phase.Result,
) Error!phase.Result {
    try root.beginInvocation();
    defer root.endInvocation();
    return call(payload);
}

pub fn openRoot(result: *Root, path: [:0]const u8) Error!void {
    return openRootInternal(result, path, null);
}

pub fn openRootExpected(result: *Root, path: [:0]const u8, expected: RootIdentity) Error!void {
    return openRootInternal(result, path, expected);
}

fn openRootInternal(result: *Root, path: [:0]const u8, expected: ?RootIdentity) Error!void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), path) or path.len >= std.fs.max_path_bytes)
        return error.InvalidOwner;
    const fd = safe_open.openAbsoluteNoFollow(path, true) catch return error.UnsafeRoot;
    errdefer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or stat.mode & 0o777 != 0o700 or stat.uid != c.geteuid())
        return error.UnsafeRoot;
    const observed: RootIdentity = .{
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
        .uid = @intCast(stat.uid),
        .mode = @intCast(stat.mode),
    };
    if (expected) |sealed| if (!sameRootIdentity(observed, sealed)) return error.RootChanged;
    const reopened = safe_open.openAbsoluteNoFollow(path, true) catch return error.RootChanged;
    defer _ = c.close(reopened);
    var named: posix.Stat = undefined;
    if (c.fstat(reopened, &named) != 0 or !matchesIdentity(named, observed)) return error.RootChanged;
    @memcpy(result.path[0..path.len], path);
    result.path[path.len] = 0;
    result.fd = fd;
    result.device = observed.device;
    result.inode = observed.inode;
    result.uid = observed.uid;
    result.mode = observed.mode;
    result.path_len = path.len;
    result.owner = result;
}

pub fn leafName(index: usize) Error![:0]const u8 {
    if (index >= leaf_names.len) return error.InvalidCheckpoint;
    return leaf_names[index];
}

pub fn initialize(root: *Root, workflow: context.Context) Error!void {
    try root.revalidate();
    var storage: [handoff.max_document_bytes]u8 = undefined;
    const bytes = try handoff.encode(&storage, .{}, workflow);
    try files.publishSummaryExclusiveAt(root.fd, leaf_names[0], bytes);
    try root.revalidate();
}

pub fn reopen(allocator: std.mem.Allocator, root: *Root, index: usize, workflow: context.Context) Error!phase.State {
    const leaf = try leafName(index);
    try root.revalidate();
    var input = try files.readInputAtAlloc(allocator, root.fd, leaf, handoff.max_document_bytes);
    defer input.deinit(allocator);
    if (input.mode & 0o777 != 0o600) return error.UnsafeMode;
    const state = try handoff.decode(input.bytes, workflow);
    try root.revalidate();
    return state;
}

pub fn advance(
    allocator: std.mem.Allocator,
    root: *Root,
    stage: phase.Stage,
    result: phase.Result,
    workflow: context.Context,
) Error!phase.State {
    var state = try admit(allocator, root, stage, workflow);
    try phase.apply(&state, .{ .stage = stage, .result = result });
    var storage: [handoff.max_document_bytes]u8 = undefined;
    const bytes = try handoff.encode(&storage, state, workflow);
    try files.publishSummaryExclusiveAt(root.fd, leaf_names[@intFromEnum(stage) + 1], bytes);
    try root.revalidate();
    return state;
}

/// Proves that one stage is current and its append-only destination is absent before the caller
/// performs the stage side effect. `advance` repeats this admission after the side effect so a
/// concurrent or replayed writer can never turn an already-owned destination into success.
pub fn admit(
    allocator: std.mem.Allocator,
    root: *Root,
    stage: phase.Stage,
    workflow: context.Context,
) Error!phase.State {
    if (root.invocation_active) return error.InvocationBusy;
    const index: usize = @intFromEnum(stage);
    if (index >= stages.len or stages[index] != stage) return error.UnexpectedStage;
    try root.revalidate();
    var existing: posix.Stat = undefined;
    if (c.fstatat(root.fd, leaf_names[index + 1].ptr, &existing, posix.AT.SYMLINK_NOFOLLOW) == 0)
        return error.DestinationExists;
    if (posix.errno(-1) != .NOENT) return error.UnsafePath;
    var input_stat: posix.Stat = undefined;
    if (c.fstatat(root.fd, leaf_names[index].ptr, &input_stat, posix.AT.SYMLINK_NOFOLLOW) != 0) {
        if (posix.errno(-1) == .NOENT) return error.UnexpectedStage;
        return error.UnsafePath;
    }
    var state = try reopen(allocator, root, index, workflow);
    if (state.expectedStage() != stage) return if (state.outcome == .active) error.UnexpectedStage else error.TerminalState;
    return state;
}

fn pristine(root: *const Root) bool {
    return root.owner == null and root.fd < 0 and root.device == 0 and root.inode == 0 and
        root.uid == 0 and root.mode == 0 and !root.invocation_active and root.path_len == 0 and allZero(&root.path);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn sameRootIdentity(left: RootIdentity, right: RootIdentity) bool {
    return left.device == right.device and left.inode == right.inode and left.uid == right.uid and left.mode == right.mode;
}

fn validRootIdentity(value: RootIdentity) bool {
    return value.device != 0 and value.inode != 0 and value.uid == c.geteuid() and
        posix.S.ISDIR(@intCast(value.mode)) and value.mode & 0o777 == 0o700;
}

fn matchesIdentity(stat: posix.Stat, expected: RootIdentity) bool {
    return posix.S.ISDIR(stat.mode) and stat.mode & 0o777 == 0o700 and stat.uid == c.geteuid() and
        stat.dev == expected.device and stat.ino == expected.inode and stat.uid == expected.uid and
        @as(u32, @intCast(stat.mode)) == expected.mode;
}

comptime {
    if (leaf_names.len != stages.len + 1) @compileError("workflow checkpoint inventory drift");
    for (stages, 0..) |stage, index| {
        if (@intFromEnum(stage) != index) @compileError("workflow stage order drift");
    }
}
