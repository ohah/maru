//! Terminal native cleanup outside the UI thread. Only a confirmed KTM outcome
//! releases handles; failures/unknown outcomes return the complete attempt.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const preparation = @import("save_prepare_worker.zig");
const transactions = @import("transaction.zig");
const grants = @import("document_grant.zig");
const editor = maru.session.editor;
const w = std.os.windows;
extern "kernel32" fn GetHandleInformation(w.HANDLE, *u32) callconv(maru.win32_abi.winapi) w.BOOL;
fn handleAlive(handle: w.HANDLE) bool {
    var flags: u32 = undefined;
    return GetHandleInformation(handle, &flags).toBool();
}

pub const Released = struct {
    image: editor.save_request.Image,
    allocator: std.mem.Allocator,
    outcome: transactions.Outcome,
    cleanup_error: ?anyerror,
    thread_id: std.Thread.Id,

    pub fn deinit(self: *Released) void {
        self.allocator.free(self.image.bytes);
        self.* = undefined;
    }
};
pub const Result = union(enum) {
    released: Released,
    retained: struct { prepared: preparation.Prepared, failure: anyerror, thread_id: std.Thread.Id },
};
const Native = struct {
    fn query(tx: *transactions.Transaction) !transactions.Outcome {
        return tx.queryOutcome();
    }
    fn close(attempt: *grants.Attempt, io: std.Io) !void {
        try attempt.close(io);
    }
};
const Job = struct {
    prepared: preparation.Prepared,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    fn retain(self: *Job, failure: anyerror) void {
        self.result = .{ .retained = .{ .prepared = self.prepared, .failure = failure, .thread_id = std.Thread.getCurrentId() } };
    }
    fn cleanup(self: *Job, io: std.Io, comptime Driver: type) void {
        const tx = &self.prepared.attempt.transaction;
        const outcome = Driver.query(tx) catch |failure| {
            tx.phase = .uncertain;
            self.retain(failure);
            return;
        };
        if (outcome == .undetermined) {
            tx.phase = .uncertain;
            self.retain(error.SaveUncertain);
            return;
        }
        // A local phase is not proof: the real KTM decision wins. Committed
        // transport must still match the bound native image and checksum.
        tx.phase = if (outcome == .committed) .committed else .rolled_back;
        if (outcome == .committed) {
            const bound = tx.request_image orelse {
                self.retain(error.WrongSaveRequest);
                return;
            };
            if (!bound.sameRequest(self.prepared.image)) {
                self.retain(error.WrongSaveRequest);
                return;
            }
            self.prepared.image.validate(tx.source_hash) catch |failure| {
                self.retain(failure);
                return;
            };
        }
        const cleanup_error: ?anyerror = blk: {
            Driver.close(&self.prepared.attempt, io) catch |failure| break :blk failure;
            break :blk null;
        };
        if (tx.phase != .closed) {
            self.retain(cleanup_error orelse error.NativeCleanupIncomplete);
            return;
        }
        self.result = .{ .released = .{ .image = self.prepared.image, .allocator = self.prepared.allocator, .outcome = outcome, .cleanup_error = cleanup_error, .thread_id = std.Thread.getCurrentId() } };
    }
    fn run(self: *Job, comptime Driver: type) void {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.cleanup(threaded.io(), Driver);
        threaded.deinit();
        self.done.store(true, .release);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    address: ?*Worker = null,

    pub fn submit(self: *Worker, prepared: *preparation.Prepared) !void {
        try self.submitWith(prepared, Native);
    }
    fn submitWith(self: *Worker, prepared: *preparation.Prepared, comptime Driver: type) !void {
        if (self.address != null and self.address != self) return error.CopiedCleanupWorker;
        if (self.job != null) return error.SaveBusy;
        if (prepared.attempt.transaction.phase != .committed and prepared.attempt.transaction.phase != .rolled_back) return error.SaveUncertain;
        // Native pinned buffers must carry the stateless thread-safe allocator;
        // never free an arena belonging to a live main-thread grant on worker.
        if (prepared.allocator.vtable != std.heap.smp_allocator.vtable or prepared.attempt.pinned.allocator.vtable != std.heap.smp_allocator.vtable) return error.NonWorkerOwnedAttempt;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .prepared = prepared.* };
        const Runner = struct {
            fn run(value: *Job) void {
                value.run(Driver);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.run, .{job});
        thread.detach();
        prepared.* = undefined;
        self.job = job;
        self.address = self;
    }
    pub fn takeResult(self: *Worker) !?Result {
        if (self.address != null and self.address != self) return error.CopiedCleanupWorker;
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        const result = job.result.?;
        self.job = null;
        self.allocator.destroy(job);
        return result;
    }
    pub fn deinit(self: *Worker) !void {
        if (self.address != null and self.address != self) return error.CopiedCleanupWorker;
        if (self.job != null) return error.SaveBusy;
    }
};

fn awaitResult(worker: *Worker) !Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try worker.takeResult()) |result| return result;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CleanupDidNotComplete;
}
// Tests drain every returned ownership path before releasing their fixtures.
fn dispose(result: *Result) void {
    switch (result.*) {
        .released => |*value| value.deinit(),
        .retained => |*value| value.prepared.close(std.testing.io) catch unreachable,
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    registry: *editor.document_registry.Registry,
    opened: grants.Opened,
    request: editor.save_request.Request,
    request_owned: bool = true,
    fn init() !Fixture {
        const a = std.testing.allocator;
        const registry = try a.create(editor.document_registry.Registry);
        registry.* = .{ .allocator = a };
        errdefer a.destroy(registry);
        errdefer registry.deinit() catch unreachable;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
        var opened = try grants.Grant.openExperimental(a, std.testing.io, tmp.dir, "file.txt", registry, 128);
        errdefer opened.grant.deinit(std.testing.io);
        errdefer _ = registry.release(opened.view) catch unreachable;
        const state = registry.get(opened.view).?;
        var selection: editor.selection.Selections = .{ .items = &.{}, .primary = 0 };
        const changes = [_]editor.delta.Change{.{ .start = 0, .end = 0, .text = "X" }};
        var inverse = try state.opened.?.file.apply(.{ .changes = &changes }, &selection);
        inverse.deinit();
        const request = try editor.save_request.Request.begin(a, registry, opened.view, 128);
        return .{ .tmp = tmp, .registry = registry, .opened = opened, .request = request };
    }
    fn prepared(self: *Fixture) !preparation.Prepared {
        return self.preparedWithAllocator(std.heap.smp_allocator);
    }
    fn preparedWithAllocator(self: *Fixture, a: std.mem.Allocator) !preparation.Prepared {
        var worker: preparation.Worker = .{ .allocator = a };
        defer worker.deinit(std.testing.io) catch unreachable;
        try worker.submit(&self.opened.grant, &self.request, 128);
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
        while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
            if (try worker.takeResult()) |result| return switch (result) {
                .prepared => |value| value,
                .failure => |err| err,
            };
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.PreparationDidNotComplete;
    }
    fn disk(self: *Fixture, expected: []const u8) !void {
        const bytes = try self.tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    fn deinit(self: *Fixture) void {
        if (self.request_owned) self.request.deinit();
        self.opened.grant.deinit(std.testing.io);
        _ = self.registry.release(self.opened.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        std.testing.allocator.destroy(self.registry);
        self.tmp.cleanup();
    }
};

test "Windows save cleanup worker closes committed native handles on another thread without ack" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.commit(std.testing.io, &f.opened.grant, &f.request);
    const tx_handle = prepared.attempt.transaction.transaction;
    const file_handle = prepared.attempt.pinned.original.handle;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .released);
    try std.testing.expectEqual(transactions.Outcome.committed, result.released.outcome);
    try std.testing.expect(result.released.thread_id != std.Thread.getCurrentId());
    try std.testing.expect(result.released.cleanup_error == null);
    try std.testing.expect(!handleAlive(tx_handle));
    try std.testing.expect(!handleAlive(file_handle));
    try std.testing.expect(result.released.image.sameRequest(f.request.image()));
    try std.testing.expectEqual(@as(u64, 0), f.registry.get(f.opened.view).?.persistence.acknowledged);
    try std.testing.expect(f.registry.get(f.opened.view).?.opened.?.isDirty());
    try f.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save cleanup worker preserves confirmed rollback image and original disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.attempt.transaction.rollback();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .released);
    try std.testing.expectEqual(transactions.Outcome.aborted, result.released.outcome);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", result.released.image.bytes);
    try std.testing.expectEqual(@as(u64, 0), f.registry.get(f.opened.view).?.persistence.acknowledged);
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save cleanup worker rechecks KTM and retains a forged terminal local phase" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    const tx_handle = prepared.attempt.transaction.transaction;
    const file_handle = prepared.attempt.pinned.original.handle;
    prepared.attempt.transaction.phase = .committed;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .retained);
    try std.testing.expectEqual(error.SaveUncertain, result.retained.failure);
    try std.testing.expectEqual(transactions.Phase.uncertain, result.retained.prepared.attempt.transaction.phase);
    try std.testing.expect(handleAlive(tx_handle));
    try std.testing.expect(handleAlive(file_handle));
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save cleanup worker preserves query failure ownership for actual retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.attempt.transaction.rollback();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    const Refuse = struct {
        fn query(_: *transactions.Transaction) !transactions.Outcome {
            return error.InjectedQueryFailure;
        }
        fn close(attempt: *grants.Attempt, io: std.Io) !void {
            try attempt.close(io);
        }
    };
    try worker.submitWith(&prepared, Refuse);
    var failed = try awaitResult(&worker);
    var failed_owned = true;
    defer if (failed_owned) dispose(&failed);
    try std.testing.expect(failed == .retained);
    try std.testing.expectEqual(error.InjectedQueryFailure, failed.retained.failure);
    try std.testing.expect(handleAlive(failed.retained.prepared.attempt.transaction.transaction));
    try std.testing.expectEqual(transactions.Outcome.aborted, try failed.retained.prepared.attempt.transaction.reconcile());
    try worker.submit(&failed.retained.prepared);
    failed_owned = false;
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .released);
    try std.testing.expectEqual(transactions.Outcome.aborted, result.released.outcome);
}

test "Windows save cleanup worker preserves cleanup reply failure after handles close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.commit(std.testing.io, &f.opened.grant, &f.request);
    const tx_handle = prepared.attempt.transaction.transaction;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    const LostReply = struct {
        fn query(tx: *transactions.Transaction) !transactions.Outcome {
            return tx.queryOutcome();
        }
        fn close(attempt: *grants.Attempt, io: std.Io) !void {
            try attempt.close(io);
            return error.NativeCleanupReplyLost;
        }
    };
    try worker.submitWith(&prepared, LostReply);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .released);
    try std.testing.expect(result.released.cleanup_error != null);
    try std.testing.expectEqual(error.NativeCleanupReplyLost, result.released.cleanup_error.?);
    try std.testing.expectEqual(transactions.Outcome.committed, result.released.outcome);
    try std.testing.expect(!handleAlive(tx_handle));
    try f.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save cleanup worker refuses corrupted committed transport before closing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.commit(std.testing.io, &f.opened.grant, &f.request);
    const tx_handle = prepared.attempt.transaction.transaction;
    @constCast(prepared.image.bytes)[3] = '!';
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .retained);
    try std.testing.expectEqual(error.CorruptSaveImage, result.retained.failure);
    try std.testing.expect(handleAlive(tx_handle));
    try f.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save cleanup worker refuses main allocator ownership without moving handles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.preparedWithAllocator(std.testing.allocator);
    var prepared_owned = true;
    defer if (prepared_owned) prepared.close(std.testing.io) catch unreachable;
    try prepared.attempt.transaction.rollback();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    // Drain any erroneously admitted value, so the negative test never leaves
    // a worker borrowing the testing allocator or closes moved handles twice.
    if (worker.submit(&prepared)) |_| {
        prepared_owned = false;
        var result = try awaitResult(&worker);
        defer dispose(&result);
        return error.TestUnexpectedResult;
    } else |failure| try std.testing.expectEqual(error.NonWorkerOwnedAttempt, failure);
    try std.testing.expect(handleAlive(prepared.attempt.transaction.transaction));
}

test "Windows save cleanup worker rejects unconfirmed phases and failed allocation retains the caller image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    defer prepared.close(std.testing.io) catch unreachable;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var worker: Worker = .{ .allocator = failing.allocator() };
    defer worker.deinit() catch unreachable;
    try std.testing.expectError(error.SaveUncertain, worker.submit(&prepared));
    try prepared.attempt.transaction.rollback();
    try std.testing.expectError(error.OutOfMemory, worker.submit(&prepared));
    try std.testing.expect(worker.job == null);
    try std.testing.expect(handleAlive(prepared.attempt.transaction.transaction));
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", prepared.image.bytes);
}

test "Windows save cleanup worker retains a completed slot and rejects copied owners" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.attempt.transaction.rollback();
    var other_fixture = try Fixture.init();
    defer other_fixture.deinit();
    var other = try other_fixture.prepared();
    defer other.close(std.testing.io) catch unreachable;
    try other.attempt.transaction.rollback();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer {
        if (worker.job != null) {
            var late = awaitResult(&worker) catch unreachable;
            dispose(&late);
        }
        worker.deinit() catch unreachable;
    }
    try worker.submit(&prepared);
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (!worker.job.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.CleanupDidNotComplete;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.SaveBusy, worker.deinit());
    try std.testing.expectError(error.SaveBusy, worker.submit(&other));
    var copy = worker;
    try std.testing.expectError(error.CopiedCleanupWorker, copy.takeResult());
    try std.testing.expectError(error.CopiedCleanupWorker, copy.deinit());
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect((try worker.takeResult()) == null);
}

test "Windows save cleanup worker retains copied completion image after releasing the main request" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.commit(std.testing.io, &f.opened.grant, &f.request);
    const token = f.request.image();
    f.request.deinit();
    f.request_owned = false;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared);
    var result = try awaitResult(&worker);
    defer dispose(&result);
    try std.testing.expect(result == .released);
    try std.testing.expect(result.released.image.sameRequest(token));
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", result.released.image.bytes);
    try std.testing.expect(f.registry.get(f.opened.view).?.opened.?.isDirty());
    try f.disk("\xef\xbb\xbfXbase\r\n");
}
