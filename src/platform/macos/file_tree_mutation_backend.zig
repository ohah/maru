//! Bounded macOS filesystem mutation worker for the project tree.
//!
//! The frame thread only enqueues owned requests, starts at most one detached worker and drains
//! completed values. Every filesystem operation is performed relative to a no-follow pinned
//! parent directory. Rename uses the platform's non-replacing primitive, and delete first stages
//! the selected entry under a visible, unpredictable sibling name before the AppKit host moves
//! that exact staged object to Trash.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const policy = maru.session.file_tree_mutation;
const file_tree = maru.session.file_tree;

pub const request_capacity: usize = 64;
pub const max_inflight: usize = 1;
pub const result_capacity: usize = 16;
/// Must stay equal to MARU_FILE_TREE_PATH_CAPACITY. The AppKit adapter uses this fixed ABI buffer.
pub const trash_path_capacity: usize = 4096;

pub const Operation = enum { create_file, create_directory, rename, stage_delete, restore_delete };

pub const Identity = struct {
    device: u64,
    inode: u64,
    kind: u32,
};
pub const IdentityKind = file_tree.IdentityKind;

pub const Request = struct {
    id: u64,
    operation: Operation,
    root: []u8,
    source: []u8,
    parent: []u8,
    name: []u8,
    identity: ?file_tree.Identity,
    parent_identity: ?file_tree.Identity,
    root_identity: ?file_tree.Identity,
    row_kind: file_tree.RowKind,
    selection_generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, id: u64, plan: policy.Plan) !Request {
        const root = try allocator.dupe(u8, plan.root);
        errdefer allocator.free(root);
        const source = try allocator.dupe(u8, plan.source);
        errdefer allocator.free(source);
        const parent = try allocator.dupe(u8, plan.parent);
        errdefer allocator.free(parent);
        const name = try allocator.dupe(u8, plan.name);
        return .{
            .id = id,
            .operation = switch (plan.operation) {
                .create_file => .create_file,
                .create_directory => .create_directory,
                .rename => .rename,
                .delete => .stage_delete,
            },
            .root = root,
            .source = source,
            .parent = parent,
            .name = name,
            .identity = plan.identity,
            .parent_identity = plan.parent_identity,
            .root_identity = plan.root_identity,
            .row_kind = plan.target_kind,
        };
    }

    pub fn initRestore(
        allocator: std.mem.Allocator,
        id: u64,
        root: []const u8,
        staged: []const u8,
        original: []const u8,
        identity: Identity,
        parent_identity: ?file_tree.Identity,
        root_identity: ?file_tree.Identity,
    ) !Request {
        const parent_path = std.fs.path.dirname(original) orelse return error.InvalidPath;
        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const source = try allocator.dupe(u8, staged);
        errdefer allocator.free(source);
        const parent = try allocator.dupe(u8, parent_path);
        errdefer allocator.free(parent);
        const name = try allocator.dupe(u8, std.fs.path.basename(original));
        return .{
            .id = id,
            .operation = .restore_delete,
            .root = owned_root,
            .source = source,
            .parent = parent,
            .name = name,
            .identity = .{ .device = identity.device, .inode = identity.inode, .kind = @intCast(identity.kind) },
            .parent_identity = parent_identity,
            .root_identity = root_identity,
            .row_kind = .file,
        };
    }

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.source);
        allocator.free(self.parent);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Result = struct {
    id: u64,
    operation: Operation,
    source: []u8,
    target: []u8,
    ok: bool,
    failure: Failure = .none,
    identity: ?Identity = null,
    parent_identity: ?file_tree.Identity = null,
    root_identity: ?file_tree.Identity = null,
    row_kind: file_tree.RowKind = .file,
    selection_generation: u64 = 0,
    recovery_required: bool = false,
    source_transferred: bool = false,
    target_transferred: bool = false,

    pub const Failure = enum { none, invalid_path, collision, not_found, denied, io };

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (!self.source_transferred) allocator.free(self.source);
        if (!self.target_transferred) allocator.free(self.target);
        self.* = undefined;
    }
};

const Job = struct { state: *State, request: Request };

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),
    requests: [request_capacity]Request = undefined,
    requests_len: usize = 0,
    results: [result_capacity]Result = undefined,
    results_len: usize = 0,
    inflight: usize = 0,
    reserved: usize = 0,
    shutting_down: bool = false,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.inflight == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Backend = struct {
    state: ?*State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// Reserve queue capacity before the caller allocates an owned request/remap snapshot.
    pub fn tryReserve(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.shutting_down or state.requests_len + state.reserved >= request_capacity) return false;
        state.reserved += 1;
        return true;
    }

    pub fn cancelReservation(self: *Backend) void {
        const state = self.state orelse return;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        std.debug.assert(state.reserved != 0);
        state.reserved -= 1;
    }

    /// Ownership always moves when a valid reservation is consumed.
    pub fn submitReserved(self: *Backend, request: Request) void {
        const state = self.state orelse unreachable;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        std.debug.assert(!state.shutting_down and state.reserved != 0 and state.requests_len < request_capacity);
        state.reserved -= 1;
        state.requests[state.requests_len] = request;
        state.requests_len += 1;
    }

    /// On true, ownership moves to the backend. On false the caller retains the request.
    pub fn submit(self: *Backend, request: Request) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.shutting_down or state.requests_len >= request_capacity) return false;
        state.requests[state.requests_len] = request;
        state.requests_len += 1;
        return true;
    }

    /// Starts at most one worker. This performs allocation/thread creation but no filesystem I/O.
    pub fn pump(self: *Backend) void {
        const state = self.state orelse return;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight >= max_inflight or state.requests_len == 0) {
            state.mutex.unlock(state.io);
            return;
        }
        var request = state.requests[0];
        for (state.requests[1..state.requests_len], 0..) |remaining, i| state.requests[i] = remaining;
        state.requests_len -= 1;
        state.inflight = 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch {
            finishWithResult(state, fallbackResult(state.allocator, &request));
            return;
        };
        job.* = .{ .state = state, .request = request };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            var failed_request = job.request;
            state.allocator.destroy(job);
            finishWithResult(state, fallbackResult(state.allocator, &failed_request));
            return;
        };
        thread.detach();
    }

    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.results_len == 0) return null;
        const result = state.results[0];
        for (state.results[1..state.results_len], 0..) |remaining, i| state.results[i] = remaining;
        state.results_len -= 1;
        return result;
    }

    pub fn pendingCount(self: *const Backend) usize {
        const state = self.state orelse return 0;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.requests_len + state.inflight + state.reserved;
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        for (state.requests[0..state.requests_len]) |*request| request.deinit(state.allocator);
        state.requests_len = 0;
        for (state.results[0..state.results_len]) |*result| result.deinit(state.allocator);
        state.results_len = 0;
        state.mutex.unlock(state.io);
        state.release();
    }
};

fn finishWithResult(state: *State, result_value: Result) void {
    var result = result_value;
    state.mutex.lockUncancelable(state.io);
    if (!state.shutting_down and state.results_len < result_capacity) {
        state.results[state.results_len] = result;
        state.results_len += 1;
    } else result.deinit(state.allocator);
    state.inflight = 0;
    state.mutex.unlock(state.io);
    state.release();
}

fn worker(job: *Job) void {
    const state = job.state;
    var request = job.request;
    state.allocator.destroy(job);
    var request_consumed = false;
    var result = execute(state.allocator, state.io, request) catch blk: {
        request_consumed = true;
        break :blk fallbackResult(state.allocator, &request);
    };
    if (!request_consumed) request.deinit(state.allocator);

    state.mutex.lockUncancelable(state.io);
    if (!state.shutting_down and state.results_len < result_capacity) {
        state.results[state.results_len] = result;
        state.results_len += 1;
    } else result.deinit(state.allocator);
    state.inflight = 0;
    state.mutex.unlock(state.io);
    state.release();
}

fn fallbackResult(allocator: std.mem.Allocator, request: *Request) Result {
    allocator.free(request.root);
    allocator.free(request.name);
    const result: Result = .{
        .id = request.id,
        .operation = request.operation,
        .source = request.source,
        .target = request.parent,
        .ok = false,
        .failure = .io,
        .row_kind = request.row_kind,
        .selection_generation = request.selection_generation,
    };
    request.* = undefined;
    return result;
}

const PinnedParent = struct { dir: std.Io.Dir, leaf: []const u8 };

fn openPinnedParent(
    io: std.Io,
    root: []const u8,
    absolute_path: []const u8,
    root_identity: ?file_tree.Identity,
    parent_identity: ?file_tree.Identity,
) !PinnedParent {
    if (!std.fs.path.isAbsolute(root) or !std.fs.path.isAbsolute(absolute_path) or !policy.pathWithin(absolute_path, root))
        return error.InvalidPath;
    const parent_path = std.fs.path.dirname(absolute_path) orelse return error.InvalidPath;
    const leaf = std.fs.path.basename(absolute_path);
    // **존재하는 이름**이므로 역슬래시를 막지 않는 쪽을 쓴다 — POSIX에서 `a\b`는 평범한 파일 이름이고,
    // 여기서 거부하면 그 파일을 이름 바꾸거나 지울 수 없다. 새 이름의 역슬래시는 이미 상류
    // (`planCreate`/`planRename`의 `validateName`)에서 막았다. **Windows 백엔드를 만들 때는 여기서
    // 역슬래시를 다시 막아야 한다** — 거기서는 `\`가 `openDir`에 대해 진짜 구분자다(W7, 계약 §5.2 ⒝).
    try policy.validateExistingName(leaf);
    var current = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    errdefer current.close(io);
    if (root_identity) |expected| if (!identityMatches(try identityOfDir(io, current), expected)) return error.IdentityChanged;
    const rel_parent = if (parent_path.len == root.len) "" else parent_path[root.len + 1 ..];
    var components = std.mem.tokenizeScalar(u8, rel_parent, '/');
    while (components.next()) |component| {
        try policy.validateExistingName(component); // 위와 같은 이유(실재하는 경로의 구성요소)
        const next = try current.openDir(io, component, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    if (parent_identity) |expected| if (!identityMatches(try identityOfDir(io, current), expected)) return error.IdentityChanged;
    return .{ .dir = current, .leaf = leaf };
}

fn identityOfDir(io: std.Io, dir: std.Io.Dir) !Identity {
    if (comptime builtin.os.tag == .macos) {
        var stat: std.posix.Stat = undefined;
        if (std.c.fstat(dir.handle, &stat) != 0) return error.StatFailed;
        return identityFromStat(stat);
    }
    const stat = try dir.stat(io);
    return .{
        .device = 0,
        .inode = @intCast(stat.inode),
        .kind = @intFromEnum(file_tree.IdentityKind.directory),
    };
}

fn identityMatches(actual: Identity, expected: file_tree.Identity) bool {
    return actual.device == expected.device and actual.inode == expected.inode and actual.kind == expected.kind;
}

fn execute(allocator: std.mem.Allocator, io: std.Io, request: Request) !Result {
    const desired = try std.fs.path.join(allocator, &.{ request.parent, request.name });
    errdefer allocator.free(desired);
    const source_owned = try allocator.dupe(u8, request.source);
    errdefer allocator.free(source_owned);
    var target_owned = desired;
    var ok = false;
    var failure: Result.Failure = .none;
    var identity: ?Identity = null;

    switch (request.operation) {
        .create_file, .create_directory => {
            var pinned = openPinnedParent(io, request.root, desired, request.root_identity, request.parent_identity) catch {
                failure = .invalid_path;
                return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
            };
            defer pinned.dir.close(io);
            if (request.operation == .create_file) {
                var file = pinned.dir.createFile(io, pinned.leaf, .{ .exclusive = true }) catch |err| {
                    failure = failureFor(err);
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                file.close(io);
            } else pinned.dir.createDir(io, pinned.leaf, .default_dir) catch |err| {
                failure = failureFor(err);
                return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
            };
            ok = true;
        },
        .rename, .stage_delete, .restore_delete => {
            var source = openPinnedParent(io, request.root, request.source, request.root_identity, request.parent_identity) catch {
                failure = .invalid_path;
                return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
            };
            defer source.dir.close(io);
            if (request.identity) |expected| {
                const actual = identityAt(allocator, io, source.dir, source.leaf) catch {
                    failure = .not_found;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                if (!identityMatches(actual, expected)) {
                    failure = .not_found;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                }
            }
            if (request.operation == .stage_delete) {
                const source_identity = identityAt(allocator, io, source.dir, source.leaf) catch {
                    failure = .not_found;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                if (request.identity) |expected| if (!identityMatches(source_identity, expected)) {
                    failure = .not_found;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                allocator.free(target_owned);
                var nonce: u64 = undefined;
                try io.randomSecure(std.mem.asBytes(&nonce));
                // A leading dot made successful items disappear from Finder's normal Trash view. Keep the
                // unpredictable sibling staging capability, but retain the original basename as a visible
                // prefix so users can see and identify the recoverable item.
                const stage_name = try std.fmt.allocPrint(allocator, "{s}.maru-trash-{x}-{x}", .{ source.leaf, request.id, nonce });
                defer allocator.free(stage_name);
                target_owned = try std.fs.path.join(allocator, &.{ request.parent, stage_name });
                // Reject before the first filesystem mutation. Otherwise the fixed-width ABI could never
                // hand the staged path to AppKit, leaving the entry stranded under its staging name.
                if (target_owned.len > trash_path_capacity) {
                    failure = .invalid_path;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                }
                std.Io.Dir.renamePreserve(source.dir, source.leaf, source.dir, stage_name, io) catch |err| {
                    failure = failureFor(err);
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                const staged_identity = identityAt(allocator, io, source.dir, stage_name) catch {
                    failure = .io;
                    // The staged name is no longer identity-verified. Never move an unverified
                    // replacement back onto the user's source path.
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure, .recovery_required = true };
                };
                if (!std.meta.eql(source_identity, staged_identity) or
                    if (request.identity) |expected| !identityMatches(staged_identity, expected) else false)
                {
                    failure = .io;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure, .recovery_required = true };
                }
                identity = staged_identity;
            } else {
                var target = openPinnedParent(io, request.root, desired, request.root_identity, request.parent_identity) catch {
                    failure = .invalid_path;
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                defer target.dir.close(io);
                std.Io.Dir.renamePreserve(source.dir, source.leaf, target.dir, target.leaf, io) catch |err| {
                    failure = failureFor(err);
                    return .{ .id = request.id, .operation = request.operation, .source = source_owned, .target = target_owned, .ok = false, .failure = failure };
                };
                identity = identityAt(allocator, io, target.dir, target.leaf) catch null;
                if (request.identity) |expected| if (identity == null or !identityMatches(identity.?, expected)) {
                    failure = .not_found;
                    return .{
                        .id = request.id,
                        .operation = request.operation,
                        .source = source_owned,
                        .target = target_owned,
                        .ok = false,
                        .failure = failure,
                        .identity = identity,
                        .recovery_required = true,
                    };
                };
            }
            ok = true;
        },
    }
    return .{
        .id = request.id,
        .operation = request.operation,
        .source = source_owned,
        .target = target_owned,
        .ok = ok,
        .failure = failure,
        .identity = identity,
        .parent_identity = request.parent_identity,
        .root_identity = request.root_identity,
        .row_kind = request.row_kind,
        .selection_generation = request.selection_generation,
    };
}

fn identityAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, leaf: []const u8) !Identity {
    if (comptime builtin.os.tag != .macos) {
        const stat = try dir.statFile(io, leaf, .{ .follow_symlinks = false });
        return identityFromIoStat(stat);
    }
    const leaf_z = try allocator.dupeZ(u8, leaf);
    defer allocator.free(leaf_z);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(dir.handle, leaf_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
    return identityFromStat(stat);
}

fn identityFromIoStat(stat: std.Io.File.Stat) Identity {
    const kind: IdentityKind = switch (stat.kind) {
        .file => .regular,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
    return .{ .device = 0, .inode = @intCast(stat.inode), .kind = @intFromEnum(kind) };
}

fn identityFromStat(stat: std.posix.Stat) Identity {
    const kind: IdentityKind = if (std.posix.S.ISREG(stat.mode))
        .regular
    else if (std.posix.S.ISDIR(stat.mode))
        .directory
    else if (std.posix.S.ISLNK(stat.mode))
        .symlink
    else
        .other;
    return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino), .kind = @intFromEnum(kind) };
}

fn testIdentityForAbsolute(allocator: std.mem.Allocator, path: []const u8) !file_tree.Identity {
    if (comptime builtin.os.tag != .macos) {
        const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
        const identity = identityFromIoStat(stat);
        return .{ .device = identity.device, .inode = identity.inode, .kind = @intCast(identity.kind) };
    }
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, path_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
    const identity = identityFromStat(stat);
    return .{ .device = identity.device, .inode = identity.inode, .kind = @intCast(identity.kind) };
}

fn failureFor(err: anyerror) Result.Failure {
    return switch (err) {
        error.PathAlreadyExists => .collision,
        error.FileNotFound => .not_found,
        error.AccessDenied => .denied,
        else => .io,
    };
}

test "mutation backend creates and renames without replacing collisions" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "docs", .default_dir);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const docs = try std.fs.path.join(allocator, &.{ root, "docs" });
    defer allocator.free(docs);
    const plan = policy.Plan{ .operation = .create_file, .root = root, .source = "", .parent = docs, .name = ".env" };
    var request = try Request.init(allocator, 1, plan);
    var result = try execute(allocator, io, request);
    request.deinit(allocator);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    const rename_plan = policy.Plan{ .operation = .rename, .root = root, .source = result.target, .parent = docs, .name = "config" };
    var rename_request = try Request.init(allocator, 2, rename_plan);
    var renamed = try execute(allocator, io, rename_request);
    rename_request.deinit(allocator);
    defer renamed.deinit(allocator);
    try std.testing.expect(renamed.ok);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/collision", .data = "keep" });
    const collision_plan = policy.Plan{ .operation = .rename, .root = root, .source = renamed.target, .parent = docs, .name = "collision" };
    var collision_request = try Request.init(allocator, 3, collision_plan);
    var collision = try execute(allocator, io, collision_request);
    collision_request.deinit(allocator);
    defer collision.deinit(allocator);
    try std.testing.expect(!collision.ok and collision.failure == .collision);
}

test "mutation backend stages symlink itself and leaves its target intact" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.md", .data = "keep" });
    try tmp.dir.symLink(io, "target.md", "link.md", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const link = try std.fs.path.join(allocator, &.{ root, "link.md" });
    defer allocator.free(link);
    const plan = policy.Plan{ .operation = .delete, .root = root, .source = link, .parent = root, .name = "link.md" };
    var request = try Request.init(allocator, 9, plan);
    var result = try execute(allocator, io, request);
    request.deinit(allocator);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    const bytes = try tmp.dir.readFileAlloc(io, "target.md", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("keep", bytes);
}

test "mutation backend rejects source parent and root identity replacement" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Leaf replacement after admission must not rename the replacement object.
    var leaf_tmp = std.testing.tmpDir(.{});
    defer leaf_tmp.cleanup();
    try leaf_tmp.dir.writeFile(io, .{ .sub_path = "source.md", .data = "original" });
    var leaf_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const leaf_root = leaf_root_buf[0..try leaf_tmp.dir.realPath(io, &leaf_root_buf)];
    const leaf_source = try std.fs.path.join(allocator, &.{ leaf_root, "source.md" });
    defer allocator.free(leaf_source);
    var leaf_request = try Request.init(allocator, 20, .{
        .operation = .rename,
        .root = leaf_root,
        .source = leaf_source,
        .parent = leaf_root,
        .name = "renamed.md",
        .identity = try testIdentityForAbsolute(allocator, leaf_source),
        .parent_identity = try testIdentityForAbsolute(allocator, leaf_root),
        .root_identity = try testIdentityForAbsolute(allocator, leaf_root),
    });
    try leaf_tmp.dir.deleteFile(io, "source.md");
    try leaf_tmp.dir.writeFile(io, .{ .sub_path = "source.md", .data = "replacement" });
    var leaf_result = try execute(allocator, io, leaf_request);
    leaf_request.deinit(allocator);
    defer leaf_result.deinit(allocator);
    try std.testing.expect(!leaf_result.ok);
    const replacement = try leaf_tmp.dir.readFileAlloc(io, "source.md", allocator, .limited(32));
    defer allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement", replacement);

    // Replacing an intermediate parent must fail before touching its new contents.
    var parent_tmp = std.testing.tmpDir(.{});
    defer parent_tmp.cleanup();
    try parent_tmp.dir.createDir(io, "work", .default_dir);
    try parent_tmp.dir.writeFile(io, .{ .sub_path = "work/source.md", .data = "original" });
    var parent_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_root = parent_root_buf[0..try parent_tmp.dir.realPath(io, &parent_root_buf)];
    const old_parent = try std.fs.path.join(allocator, &.{ parent_root, "work" });
    defer allocator.free(old_parent);
    const parent_source = try std.fs.path.join(allocator, &.{ old_parent, "source.md" });
    defer allocator.free(parent_source);
    var parent_request = try Request.init(allocator, 21, .{
        .operation = .rename,
        .root = parent_root,
        .source = parent_source,
        .parent = old_parent,
        .name = "renamed.md",
        .identity = try testIdentityForAbsolute(allocator, parent_source),
        .parent_identity = try testIdentityForAbsolute(allocator, old_parent),
        .root_identity = try testIdentityForAbsolute(allocator, parent_root),
    });
    if (std.c.renameat(parent_tmp.dir.handle, "work", parent_tmp.dir.handle, "old-work") != 0) return error.RenameFailed;
    try parent_tmp.dir.createDir(io, "work", .default_dir);
    try parent_tmp.dir.writeFile(io, .{ .sub_path = "work/source.md", .data = "replacement" });
    var parent_result = try execute(allocator, io, parent_request);
    parent_request.deinit(allocator);
    defer parent_result.deinit(allocator);
    try std.testing.expect(!parent_result.ok);
    const parent_replacement = try parent_tmp.dir.readFileAlloc(io, "work/source.md", allocator, .limited(32));
    defer allocator.free(parent_replacement);
    try std.testing.expectEqualStrings("replacement", parent_replacement);

    // Replacing the root itself is likewise rejected even when the same lexical path exists again.
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.createDir(io, "project", .default_dir);
    try root_tmp.dir.writeFile(io, .{ .sub_path = "project/source.md", .data = "original" });
    var outer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outer = outer_buf[0..try root_tmp.dir.realPath(io, &outer_buf)];
    const project = try std.fs.path.join(allocator, &.{ outer, "project" });
    defer allocator.free(project);
    const root_source = try std.fs.path.join(allocator, &.{ project, "source.md" });
    defer allocator.free(root_source);
    var root_request = try Request.init(allocator, 22, .{
        .operation = .rename,
        .root = project,
        .source = root_source,
        .parent = project,
        .name = "renamed.md",
        .identity = try testIdentityForAbsolute(allocator, root_source),
        .parent_identity = try testIdentityForAbsolute(allocator, project),
        .root_identity = try testIdentityForAbsolute(allocator, project),
    });
    if (std.c.renameat(root_tmp.dir.handle, "project", root_tmp.dir.handle, "old-project") != 0) return error.RenameFailed;
    try root_tmp.dir.createDir(io, "project", .default_dir);
    try root_tmp.dir.writeFile(io, .{ .sub_path = "project/source.md", .data = "replacement" });
    var root_result = try execute(allocator, io, root_request);
    root_request.deinit(allocator);
    defer root_result.deinit(allocator);
    try std.testing.expect(!root_result.ok);
    const root_replacement = try root_tmp.dir.readFileAlloc(io, "project/source.md", allocator, .limited(32));
    defer allocator.free(root_replacement);
    try std.testing.expectEqualStrings("replacement", root_replacement);
}

test "mutation backend stages a visible Trash name, restores it, and rejects replacement identity" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.md", .data = "original" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const original = try std.fs.path.join(allocator, &.{ root, "original.md" });
    defer allocator.free(original);
    const expected = try testIdentityForAbsolute(allocator, original);
    var request = try Request.init(allocator, 30, .{
        .operation = .delete,
        .root = root,
        .source = original,
        .parent = root,
        .name = "original.md",
        .identity = expected,
        .parent_identity = try testIdentityForAbsolute(allocator, root),
        .root_identity = try testIdentityForAbsolute(allocator, root),
    });
    var staged = try execute(allocator, io, request);
    request.deinit(allocator);
    defer staged.deinit(allocator);
    try std.testing.expect(staged.ok);
    try std.testing.expectEqual(Operation.stage_delete, staged.operation);
    try std.testing.expect(std.mem.startsWith(u8, std.fs.path.basename(staged.target), "original.md.maru-trash-"));
    try std.testing.expect(std.fs.path.basename(staged.target)[0] != '.');
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "original.md", .{}));

    var restore = try Request.initRestore(
        allocator,
        staged.id,
        root,
        staged.target,
        original,
        staged.identity.?,
        staged.parent_identity,
        staged.root_identity,
    );
    var restored = try execute(allocator, io, restore);
    restore.deinit(allocator);
    defer restored.deinit(allocator);
    try std.testing.expect(restored.ok);
    const restored_bytes = try tmp.dir.readFileAlloc(io, "original.md", allocator, .limited(32));
    defer allocator.free(restored_bytes);
    try std.testing.expectEqualStrings("original", restored_bytes);

    var replaced_request = try Request.init(allocator, 31, .{
        .operation = .delete,
        .root = root,
        .source = original,
        .parent = root,
        .name = "original.md",
        .identity = expected,
        .parent_identity = try testIdentityForAbsolute(allocator, root),
        .root_identity = try testIdentityForAbsolute(allocator, root),
    });
    try tmp.dir.deleteFile(io, "original.md");
    try tmp.dir.writeFile(io, .{ .sub_path = "original.md", .data = "replacement" });
    var result = try execute(allocator, io, replaced_request);
    replaced_request.deinit(allocator);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    const replacement = try tmp.dir.readFileAlloc(io, "original.md", allocator, .limited(32));
    defer allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement", replacement);
}

test "mutation backend request queue is bounded and rejected ownership stays with caller" {
    const allocator = std.testing.allocator;
    var backend = try Backend.init(allocator, std.testing.io);
    defer backend.deinit();
    const plan = policy.Plan{ .operation = .create_file, .root = "/tmp", .source = "", .parent = "/tmp", .name = "x" };
    for (0..request_capacity) |i| {
        const request = try Request.init(allocator, @intCast(i + 1), plan);
        try std.testing.expect(backend.submit(request));
    }
    try std.testing.expectEqual(request_capacity, backend.pendingCount());
    var rejected = try Request.init(allocator, 999, plan);
    try std.testing.expect(!backend.submit(rejected));
    rejected.deinit(allocator); // false means ownership never moved.

    backend.pump();
    var completed: ?Result = null;
    var attempts: usize = 0;
    while (completed == null and attempts < 500) : (attempts += 1) {
        completed = backend.takeResult();
        if (completed == null) std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(completed != null);
    var first = completed.?;
    first.deinit(allocator);
    const recovered = try Request.init(allocator, 1_000, plan);
    try std.testing.expect(backend.submit(recovered));
}

test "mutation backend reserves capacity before request allocation and cancellation reuses it" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    for (0..request_capacity) |_| try std.testing.expect(backend.tryReserve());
    try std.testing.expect(!backend.tryReserve());
    try std.testing.expectEqual(request_capacity, backend.pendingCount());
    backend.cancelReservation();
    try std.testing.expect(backend.tryReserve());
    for (0..request_capacity) |_| backend.cancelReservation();
    try std.testing.expectEqual(@as(usize, 0), backend.pendingCount());
}
