//! Prepare a recursive native watch off the frame thread using a validated directory.
//! The owner retains a request until completion; cancel never drops worker storage.
//! The allocator and Io must outlive the request and any returned Prepared value.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const protocol = maru.app.file_tree_root_validation;
const backend = maru.app.file_tree_backend;
const Watcher = @import("directory_watch.zig").Watcher;

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    pending: protocol.Pending,
    directory: ?std.Io.Dir,
    watcher: ?*Watcher,
    references: usize = 1,
    pub fn retain(self: *Prepared) !void {
        if (self.references == 0) return error.Retiring;
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }
    pub fn release(self: *Prepared) !bool {
        if (self.references == 0) return error.AlreadyReleased;
        self.references -= 1;
        return self.references == 0;
    }
    /// Retain this object after false or an error. True destroys it.
    pub fn pollRetire(self: *Prepared) !bool {
        if (self.references != 0) return error.StillReferenced;
        if (self.watcher) |watch| {
            try watch.beginDestroy();
            if (!try watch.finishDestroy()) return false;
            self.watcher = null;
        }
        if (self.directory) |dir| dir.close(self.io);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
        return true;
    }
    /// Shutdown only: on failure the caller still owns this exact retired object.
    pub fn destroyRetiredBlocking(self: *Prepared) !void {
        if (self.references != 0) return error.StillReferenced;
        if (self.watcher) |watch| {
            try watch.destroy();
            self.watcher = null;
        }
        if (self.directory) |dir| dir.close(self.io);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    fn destroyForTest(self: *Prepared) void {
        if (self.watcher) |watch| watch.destroy() catch unreachable;
        if (self.directory) |dir| dir.close(self.io);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};
pub const Outcome = union(enum) { ready: *Prepared, discard: *Prepared, canceled, failed: anyerror };
const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    directory: ?std.Io.Dir,
    pending: protocol.Pending,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: Outcome = .canceled,
    fn perform(self: *State) !*Prepared {
        if (self.canceled.load(.acquire)) return error.Canceled;
        const dir = self.directory orelse return error.MissingDirectory;
        const identity = try backend.captureDirectoryIdentity(self.io, dir);
        const expected = self.pending.identity orelse return error.MissingIdentity;
        if (!expected.eql(identity.value)) return error.RootIdentityChanged;
        if (self.canceled.load(.acquire)) return error.Canceled;
        const prepared = try self.allocator.create(Prepared);
        errdefer self.allocator.destroy(prepared);
        const watch = try Watcher.createRecursive(self.allocator, dir);
        // No fallible operation after native ownership is established.
        prepared.* = .{ .allocator = self.allocator, .io = self.io, .path = self.path.?, .pending = self.pending, .directory = dir, .watcher = watch };
        self.path = null;
        self.directory = null;
        return prepared;
    }
    fn worker(self: *State) void {
        self.result = if (self.perform()) |ready| .{ .ready = ready } else |err| if (err == error.Canceled) .canceled else .{ .failed = err };
        if (self.directory) |dir| {
            dir.close(self.io);
            self.directory = null;
        }
        // This is the final State access. The owner may free State after acquire.
        self.done.store(true, .release);
    }
};
pub const Job = struct {
    state: ?*State,
    taken: bool = false,
    /// On success only, ownership of directory moves to the worker.
    pub fn start(a: std.mem.Allocator, io: std.Io, path: []const u8, directory: std.Io.Dir, pending: protocol.Pending) !Job {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (pending.round != 1 or pending.identity == null or pending.operation == .none) return error.InvalidValidation;
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        const state = try a.create(State);
        errdefer a.destroy(state);
        state.* = .{ .allocator = a, .io = io, .path = owned, .directory = directory, .pending = pending };
        const thread = try std.Thread.spawn(.{}, State.worker, .{state});
        thread.detach();
        return .{ .state = state };
    }
    pub fn cancel(self: *Job) void {
        if (self.state) |state| state.canceled.store(true, .release);
    }
    pub fn poll(self: *Job) ?Outcome {
        const state = self.state orelse return null;
        if (self.taken or !state.done.load(.acquire)) return null;
        self.taken = true;
        var result = state.result;
        state.result = .canceled;
        // Late cancellation transfers resources for retirement, never for commit.
        if (state.canceled.load(.acquire) and result == .ready) {
            const prepared = result.ready;
            result = .{ .discard = prepared };
        }
        return result;
    }
    /// Nonblocking: an active request or an unharvested resource remains owned.
    pub fn deinit(self: *Job) !void {
        const state = self.state orelse return;
        if (!state.done.load(.acquire)) return error.RequestStillRunning;
        if (!self.taken and state.result == .ready) return error.UnharvestedResult;
        if (state.path) |path| state.allocator.free(path);
        self.state = null;
        state.allocator.destroy(state);
    }
};

fn waitForTest(job: *Job) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!job.state.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn cleanupOutcomeForTest(outcome: Outcome) void {
    switch (outcome) {
        .ready, .discard => |prepared| prepared.destroyForTest(),
        else => {},
    }
}
fn cleanupJobForTest(job: *Job) void {
    if (job.state == null) return;
    job.cancel();
    waitForTest(job) catch unreachable;
    if (job.poll()) |result| cleanupOutcomeForTest(result);
    job.deinit() catch unreachable;
}
fn validatedForTest(tmp: *std.testing.TmpDir) !backend.ValidatedRoot {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    return (try backend.validateRootSnapshot(std.testing.allocator, std.testing.io, path)) orelse error.InvalidFixtureRoot;
}
fn pendingForTest(root: backend.ValidatedRoot) protocol.Pending {
    return .{ .request_id = 7, .expected_root_generation = 9, .operation = .add, .round = 1, .identity = root.identity };
}
test "Windows root watch preparation retains native directory capability and request metadata" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var job = try Job.start(a, io, root.path, root.dir.?, pendingForTest(root));
    root.dir = null;
    defer cleanupJobForTest(&job);
    try waitForTest(&job);
    const outcome = job.poll().?;
    defer cleanupOutcomeForTest(outcome);
    try std.testing.expect(outcome == .ready);
    try std.testing.expectEqual(@as(u64, 7), outcome.ready.pending.request_id);
    try std.testing.expectEqual(@as(u64, 9), outcome.ready.pending.expected_root_generation);
    try std.testing.expectEqual(protocol.Operation.add, outcome.ready.pending.operation);
    try std.testing.expect(outcome.ready.directory != null and outcome.ready.watcher != null and job.poll() == null);
    try std.testing.expectEqualStrings(root.path, outcome.ready.path);
}
test "Windows root watch preparation late cancellation returns resources only for retirement" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var job = try Job.start(a, io, root.path, root.dir.?, pendingForTest(root));
    root.dir = null;
    defer cleanupJobForTest(&job);
    try waitForTest(&job);
    job.cancel();
    const outcome = job.poll().?;
    defer cleanupOutcomeForTest(outcome);
    try std.testing.expect(outcome == .discard);
}
test "Windows root watch preparation refuses disposal of an active owner without freeing state" {
    const a = std.testing.allocator;
    const state = try a.create(State);
    state.* = .{ .allocator = a, .io = std.testing.io, .path = null, .directory = null, .pending = .{ .request_id = 7, .expected_root_generation = 9, .operation = .add } };
    var job: Job = .{ .state = state };
    defer if (job.state) |retained| {
        retained.done.store(true, .release);
        job.deinit() catch unreachable;
    };
    try std.testing.expect(job.poll() == null);
    try std.testing.expectError(error.RequestStillRunning, job.deinit());
}
test "Windows root watch preparation start failure leaves the directory with its caller" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Job.start(failing.allocator(), io, root.path, root.dir.?, pendingForTest(root)));
    _ = try root.dir.?.stat(io);
}
test "Windows root watch preparation rejects a mismatched validated identity on its worker" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var pending = pendingForTest(root);
    pending.identity.?.inode ^= 1;
    var job = try Job.start(a, io, root.path, root.dir.?, pending);
    root.dir = null;
    defer cleanupJobForTest(&job);
    try waitForTest(&job);
    const outcome = job.poll().?;
    defer cleanupOutcomeForTest(outcome);
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqual(error.RootIdentityChanged, outcome.failed);
}
test "Windows root watch preparation retirement waits for all model references" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var job = try Job.start(a, io, root.path, root.dir.?, pendingForTest(root));
    root.dir = null;
    defer cleanupJobForTest(&job);
    try waitForTest(&job);
    const outcome = job.poll().?;
    try std.testing.expect(outcome == .ready);
    var prepared: ?*Prepared = outcome.ready;
    defer if (prepared) |retained| retained.destroyForTest();
    try prepared.?.retain();
    try std.testing.expect(!try prepared.?.release());
    try std.testing.expectError(error.StillReferenced, prepared.?.pollRetire());
    try std.testing.expect(try prepared.?.release());
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 3 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try prepared.?.pollRetire()) {
            prepared = null;
            return;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.RetirementTimeout;
}

test "Windows root watch preparation refuses disposal before harvesting native resources" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try validatedForTest(&tmp);
    defer root.deinit(a, io);
    var job = try Job.start(a, io, root.path, root.dir.?, pendingForTest(root));
    root.dir = null;
    defer cleanupJobForTest(&job);
    try waitForTest(&job);
    try std.testing.expect(job.state.?.result == .ready);
    const prepared = job.state.?.result.ready;
    // Fault-injected early disposal must still have independent native cleanup.
    defer if (job.state == null) prepared.destroyForTest();
    try std.testing.expectError(error.UnharvestedResult, job.deinit());
}
