//! Archive scope의 현재-Term git root를 main actor 밖에서 확인한다.
//!
//! Archive scanner와 별개인 작은 worker다. scope 전환·검색·frame tick은 이
//! backend의 immutable result만 소비해, `.git` ancestor walk가 입력을 멈추지 않는다.

const std = @import("std");

pub const Result = struct {
    request_id: u64,
    project_root: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.project_root) |path| allocator.free(path);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),
    result: ?Result = null,
    inflight: bool = false,
    shutting_down: bool = false,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(!self.inflight);
        if (self.result) |*result| result.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct { state: *State, cwd: []u8, request_id: u64 };

pub const Backend = struct {
    state: ?*State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// Caller retains cwd when false; worker owns it when true.  One in-flight
    /// request is enough because a newer focus can request again after this
    /// short bounded ancestor walk publishes.
    pub fn submit(self: *Backend, cwd: []u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight = true;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);
        const job = state.allocator.create(Job) catch {
            finishWithoutResult(state);
            return false;
        };
        job.* = .{ .state = state, .cwd = cwd, .request_id = request_id };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.destroy(job);
            finishWithoutResult(state);
            return false;
        };
        thread.detach();
        return true;
    }

    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.result orelse return null;
        state.result = null;
        return result;
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        if (state.result) |*result| result.deinit(state.allocator);
        state.result = null;
        state.mutex.unlock(state.io);
        state.release();
    }
};

fn finishWithoutResult(state: *State) void {
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn worker(job: *Job) void {
    const state = job.state;
    var result = Result{ .request_id = job.request_id, .project_root = canonicalGitRoot(state.allocator, state.io, job.cwd) };
    state.allocator.free(job.cwd);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    if (state.shutting_down) {
        state.mutex.unlock(state.io);
        result.deinit(state.allocator);
    } else {
        if (state.result) |*old| old.deinit(state.allocator);
        state.result = result;
        state.mutex.unlock(state.io);
    }
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn canonicalGitRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(cwd) or cwd.len == 0) return null;
    var canonical_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_len = std.Io.Dir.realPathFileAbsolute(io, cwd, &canonical_buf) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, canonical_buf[0..canonical_len], .{}) catch return null;
    dir.close(io);
    var cursor: []const u8 = canonical_buf[0..canonical_len];
    while (true) {
        var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, "{s}/.git", .{cursor}) catch return null;
        if (std.Io.Dir.cwd().statFile(io, marker, .{})) |_| return allocator.dupe(u8, cursor) catch null else |_| {}
        const parent = std.fs.path.dirname(cursor) orelse return null;
        if (std.mem.eql(u8, parent, cursor)) return null;
        cursor = parent;
    }
}

test "scope worker resolves a canonical git root and rejects a missing cwd" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    try repo.createDir(io, "src", .default_dir);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const nested = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "repo/src" });
    defer allocator.free(nested);
    const actual = canonicalGitRoot(allocator, io, nested) orelse return error.TestUnexpectedResult;
    defer allocator.free(actual);
    const expected = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "repo" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(canonicalGitRoot(allocator, io, "/definitely/missing/maru-cwd") == null);
}
