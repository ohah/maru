//! Native rollback/outcome queries without Registry access. Admission moves a
//! complete prepared image; even failed replies return all native ownership.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const preparation = @import("save_prepare_worker.zig");
const transactions = @import("transaction.zig");
const grants = @import("document_grant.zig");
const editor = maru.session.editor;

pub const Action = enum { rollback, reconcile };
pub const Result = struct {
    prepared: preparation.Prepared,
    failure: ?anyerror,
    outcome: transactions.Outcome,
    thread_id: std.Thread.Id,
};
const Native = struct {
    fn rollback(tx: *transactions.Transaction) !void {
        try tx.rollback();
    }
    fn reconcile(tx: *transactions.Transaction) !transactions.Outcome {
        return tx.reconcile();
    }
};
const Job = struct {
    prepared: preparation.Prepared,
    action: Action,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    fn run(self: *Job, comptime Driver: type) void {
        const failure: ?anyerror = blk: {
            switch (self.action) {
                .rollback => Driver.rollback(&self.prepared.attempt.transaction) catch |err| break :blk err,
                .reconcile => _ = Driver.reconcile(&self.prepared.attempt.transaction) catch |err| break :blk err,
            }
            break :blk null;
        };
        const outcome: transactions.Outcome = switch (self.prepared.attempt.transaction.phase) {
            .committed => .committed,
            .rolled_back => .aborted,
            else => .undetermined,
        };
        self.result = .{ .prepared = self.prepared, .failure = failure, .outcome = outcome, .thread_id = std.Thread.getCurrentId() };
        self.done.store(true, .release);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    address: ?*Worker = null,

    pub fn submit(self: *Worker, prepared: *preparation.Prepared, action: Action) !void {
        try self.submitWith(prepared, action, Native);
    }
    fn submitWith(self: *Worker, prepared: *preparation.Prepared, action: Action, comptime Driver: type) !void {
        if (self.address != null and self.address != self) return error.CopiedSettlementWorker;
        if (self.job != null) return error.SaveBusy;
        if (action == .reconcile and prepared.attempt.transaction.phase != .uncertain) return error.InvalidState;
        if (action == .rollback and (prepared.attempt.transaction.phase == .closed or prepared.attempt.transaction.phase == .committed or prepared.attempt.transaction.phase == .rolled_back)) return error.InvalidState;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .prepared = prepared.*, .action = action };
        const Runner = struct {
            fn run(value: *Job) void {
                value.run(Driver);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.run, .{job});
        thread.detach();
        // No fallible operation follows spawn. The caller no longer owns any
        // copied native handles or image, and must drain before releasing owner.
        prepared.* = undefined;
        self.job = job;
        self.address = self;
    }
    pub fn takeResult(self: *Worker) !?Result {
        if (self.address != null and self.address != self) return error.CopiedSettlementWorker;
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        const result = job.result.?;
        self.job = null;
        self.allocator.destroy(job);
        return result;
    }
    pub fn deinit(self: *Worker) !void {
        if (self.address != null and self.address != self) return error.CopiedSettlementWorker;
        // A dropped callback is not rollback evidence. Keep even an already
        // completed result until its owner takes it, including unknown outcomes.
        if (self.job != null) return error.SaveBusy;
    }
};

fn awaitResult(worker: *Worker) !Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try worker.takeResult()) |result| return result;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.SettlementDidNotComplete;
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
        var worker: preparation.Worker = .{ .allocator = std.testing.allocator };
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

test "Windows save settlement worker rolls back on another thread without acknowledgment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared, .rollback);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(transactions.Outcome.aborted, result.outcome);
    try std.testing.expectEqual(transactions.Phase.rolled_back, result.prepared.attempt.transaction.phase);
    try std.testing.expectEqual(@as(u64, 0), f.registry.get(f.opened.view).?.persistence.acknowledged);
    try f.disk("\xef\xbb\xbfbase\r\n");
}
test "Windows save settlement worker retains completed ownership and rejects copied owners" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared, .rollback);
    // The busy test supplies a separately valid value, never a moved input.
    var other_fixture = try Fixture.init();
    defer other_fixture.deinit();
    var other = try other_fixture.prepared();
    defer other.close(std.testing.io) catch unreachable;
    try std.testing.expectError(error.SaveBusy, worker.submit(&other, .rollback));
    try std.testing.expectError(error.SaveBusy, worker.deinit());
    var copy = worker;
    try std.testing.expectError(error.CopiedSettlementWorker, copy.takeResult());
    try std.testing.expectError(error.CopiedSettlementWorker, copy.deinit());
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect((try worker.takeResult()) == null);
}
test "Windows save settlement worker preserves failed native ownership for real retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    const Refuse = struct {
        fn rollback(tx: *transactions.Transaction) !void {
            tx.phase = .uncertain;
            return error.RollbackUncertain;
        }
        fn reconcile(tx: *transactions.Transaction) !transactions.Outcome {
            return tx.reconcile();
        }
    };
    try worker.submitWith(&prepared, .rollback, Refuse);
    var failed = try awaitResult(&worker);
    var failed_owned = true;
    defer if (failed_owned) failed.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(failed.failure != null);
    try std.testing.expectEqual(error.RollbackUncertain, failed.failure.?);
    try std.testing.expectEqual(transactions.Outcome.undetermined, failed.outcome);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", failed.prepared.image.bytes);
    try std.testing.expectEqual(transactions.Phase.uncertain, failed.prepared.attempt.transaction.phase);
    try worker.submit(&failed.prepared, .rollback);
    failed_owned = false;
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(transactions.Outcome.aborted, result.outcome);
    try f.disk("\xef\xbb\xbfbase\r\n");
}
test "Windows save settlement worker distinguishes unknown reconciliation from aborted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    prepared.attempt.transaction.phase = .uncertain;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared, .reconcile);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(transactions.Outcome.undetermined, result.outcome);
    try std.testing.expectEqual(transactions.Phase.uncertain, result.prepared.attempt.transaction.phase);
    try f.disk("\xef\xbb\xbfbase\r\n");
}
test "Windows save settlement worker observes an actual lost commit reply without rollback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    try prepared.commit(std.testing.io, &f.opened.grant, &f.request);
    prepared.attempt.transaction.phase = .uncertain;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared, .reconcile);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(transactions.Outcome.committed, result.outcome);
    try result.prepared.attempt.transaction.acknowledgeDocument(&f.request);
    try std.testing.expect(!f.registry.get(f.opened.view).?.opened.?.isDirty());
    try f.disk("\xef\xbb\xbfXbase\r\n");
}
test "Windows save settlement worker failed admission leaves the native image with its caller" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    defer prepared.close(std.testing.io) catch unreachable;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var worker: Worker = .{ .allocator = failing.allocator() };
    defer worker.deinit() catch unreachable;
    try std.testing.expectError(error.OutOfMemory, worker.submit(&prepared, .rollback));
    try std.testing.expect(worker.job == null);
    try std.testing.expectEqual(transactions.Phase.prepared, prepared.attempt.transaction.phase);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", prepared.image.bytes);
    try std.testing.expectError(error.InvalidState, worker.submit(&prepared, .reconcile));
}
test "Windows save settlement worker owns the copied image after releasing the main request" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    prepared.preparation_error = error.NativeWriteFailed;
    f.request.deinit();
    f.request_owned = false;
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit() catch unreachable;
    try worker.submit(&prepared, .rollback);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.prepared.preparation_error != null);
    try std.testing.expectEqual(error.NativeWriteFailed, result.prepared.preparation_error.?);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", result.prepared.image.bytes);
    try std.testing.expectEqual(transactions.Outcome.aborted, result.outcome);
    try f.disk("\xef\xbb\xbfbase\r\n");
}
