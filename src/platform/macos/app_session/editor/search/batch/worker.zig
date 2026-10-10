//! 준비 중 닫힌 문서를 빌리지 않는다. 불변 snapshot과 시작 ticket만 독립 소유한다.
const std = @import("std");
const maru = @import("maru");
const search = maru.session.editor.search;
const buffer = maru.session.editor.buffer;
const Ticket = @import("../batch.zig").Ticket;

pub const Model = struct { source: search.request.Source, snapshot: buffer.Snapshot };
pub const Ready = struct {
    specification: search.batch.Specification,
    prepared: search.batch_plan.Prepared,
    ticket: Ticket,
    pub fn deinit(self: *Ready, a: std.mem.Allocator) void {
        self.prepared.deinit(a);
        self.specification.deinit(a);
        self.* = undefined;
    }
};
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
pub const Job = struct {
    a: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    specification: ?search.batch.Specification,
    models: []Model,
    ticket: Ticket,
    total_limit: usize,
    file_limit: usize,
    prepared: ?search.batch_plan.Prepared = null,
    failure: ?anyerror = null,

    /// 성공할 때만 명세·배열·snapshot의 소유권을 가져간다. allocator는 스레드 안전해야 한다.
    /// ticket은 actor가 준비 시작 전에 발급한 값이며 완료 시점에 새로 만들지 않는다.
    pub fn start(a: std.mem.Allocator, specification: *search.batch.Specification, models: []Model, ticket: Ticket, total_limit: usize, file_limit: usize) !*Job {
        if (!std.meta.eql(specification.identity, ticket.identity) or models.len != specification.targets.items.len) return error.StaleTargets;
        var bytes: usize = 0;
        for (specification.targets.items, models) |target, model| {
            if (target.source != .model or model.source != .model) return error.DiskTargetsNotSupported;
            if (model.source.model.composition != 0 or !std.meta.eql(target.source, model.source)) return error.StaleTargets;
            if (model.snapshot.byteLen() > file_limit or model.snapshot.byteLen() > total_limit -| bytes) return error.TooLarge;
            bytes += model.snapshot.byteLen();
        }
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .a = a, .specification = specification.*, .models = models, .ticket = ticket, .total_limit = total_limit, .file_limit = file_limit };
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
        thread.detach();
        specification.* = undefined;
        return job;
    }
    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }
    /// 취소 후 늦게 성공한 결과도 승격하지 않는다. 반환값은 UI 상태와 별개로 actor까지 살아야 한다.
    pub fn take(self: *Job) !?Ready {
        if (!self.done.load(.acquire)) return null;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (self.failure) |err| return err;
        if (self.specification == null or self.prepared == null) return error.AlreadyTaken;
        const result: Ready = .{ .specification = self.specification.?, .prepared = self.prepared.?, .ticket = self.ticket };
        self.specification = null;
        self.prepared = null;
        return result;
    }
    pub fn deinit(self: *Job) void {
        self.cancel();
        self.release();
    }
    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.prepared) |*prepared| prepared.deinit(self.a);
        if (self.specification) |*specification| specification.deinit(self.a);
        self.a.destroy(self);
    }
    fn execute(self: *Job) void {
        // 카운터가 0이면 마지막 snapshot/Plan 해제까지 끝났다는 뜻이어야 한다.
        defer _ = workers.fetchSub(1, .acq_rel);
        defer self.release();
        self.prepare() catch |err| {
            self.failure = err;
        };
        for (self.models) |*model| model.snapshot.deinit();
        self.a.free(self.models);
        self.done.store(true, .release);
    }
    fn prepare(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        var bodies: std.ArrayList(search.batch_plan.Body) = .empty;
        defer {
            for (bodies.items) |body| self.a.free(body.text);
            bodies.deinit(self.a);
        }
        try bodies.ensureTotalCapacity(self.a, self.models.len);
        for (self.specification.?.targets.items, self.models) |target, model| {
            if (self.cancelled.load(.acquire)) return error.Cancelled;
            const text = try model.snapshot.copyRange(self.a, 0, model.snapshot.byteLen());
            bodies.appendAssumeCapacity(.{ .absolute = target.absolute, .source = model.source, .text = text });
        }
        self.prepared = try search.batch_plan.Prepared.prepare(self.a, &self.specification.?, bodies.items, self.total_limit, self.file_limit, &self.cancelled);
    }
};

const testing = std.testing;
const identity: search.request.Identity = .{ .request = 7, .root = 8, .models = 9 };
const fixture_ticket: Ticket = .{ .identity = identity, .stamp = 10, .settings = 11 };
const source: search.request.Source = .{ .model = .{ .document = .{ .owner = 1, .slot = 0, .generation = 1 }, .revision = 2, .composition = 0 } };
fn fixture(a: std.mem.Allocator) !struct { spec: search.batch.Specification, models: []Model } {
    var second = source;
    second.model.document.slot = 1;
    const ranges = &.{search.event.Range{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } }};
    var spec = try search.batch.Specification.capture(a, identity, .complete, "foo", "bar", .{}, &.{
        .{ .absolute = if (@import("builtin").os.tag == .windows) "C:\\a" else "/a", .root_index = 0, .source = source, .ranges = ranges },
        .{ .absolute = if (@import("builtin").os.tag == .windows) "C:\\b" else "/b", .root_index = 0, .source = second, .ranges = ranges },
    });
    errdefer spec.deinit(a);
    const models = try a.alloc(Model, 2);
    errdefer a.free(models);
    var buf = try buffer.Buffer.init(a, "foo");
    defer buf.deinit();
    models[0] = .{ .source = source, .snapshot = buf.snapshot() };
    models[1] = .{ .source = second, .snapshot = buf.snapshot() };
    return .{ .spec = spec, .models = models };
}
fn cleanup(a: std.mem.Allocator, input: anytype) void {
    input.spec.deinit(a);
    for (input.models) |*model| model.snapshot.deinit();
    a.free(input.models);
}
fn wait(job: *Job) void {
    while (!job.done.load(.acquire)) std.Thread.yield() catch {};
}
fn drain() void {
    while (outstandingWorkers() != 0) std.Thread.yield() catch {};
}
test "RPBW1 worker는 원래 Buffer 종료 뒤에도 snapshot과 시작 ticket을 보존한다" {
    var input = try fixture(testing.allocator);
    const job = Job.start(testing.allocator, &input.spec, input.models, fixture_ticket, 6, 3) catch |err| {
        cleanup(testing.allocator, &input);
        return err;
    };
    defer drain();
    var owns_job = true;
    defer if (owns_job) job.deinit();
    wait(job);
    var result = (try job.take()).?;
    defer result.deinit(testing.allocator);
    try testing.expectError(error.AlreadyTaken, job.take());
    job.deinit();
    owns_job = false;
    drain();
    try testing.expectEqual(@as(usize, 2), result.prepared.effective);
    try testing.expectEqualStrings("foo", result.prepared.items.items[0].plan.before);
    try testing.expectEqualStrings("bar", result.prepared.items.items[0].plan.after);
    try testing.expectEqualStrings("bar", result.prepared.items.items[1].plan.after);
    try testing.expectEqualDeep(fixture_ticket, result.ticket);
    try testing.expectEqual(search.batch.Outcome.pending, result.specification.targets.items[0].outcome);
}
test "RPBW2 준비 완료 뒤 취소한 결과를 적용 가능한 값으로 꺼내지 않는다" {
    var input = try fixture(testing.allocator);
    const job = Job.start(testing.allocator, &input.spec, input.models, fixture_ticket, 6, 3) catch |err| {
        cleanup(testing.allocator, &input);
        return err;
    };
    defer drain();
    defer job.deinit();
    wait(job);
    job.cancel();
    try testing.expectError(error.Cancelled, job.take());
}
test "RPBW3 caller 종료와 detached worker 완료를 따로 해제한다" {
    var input = try fixture(testing.allocator);
    const job = Job.start(testing.allocator, &input.spec, input.models, fixture_ticket, 6, 3) catch |err| {
        cleanup(testing.allocator, &input);
        return err;
    };
    job.deinit();
    drain();
}
fn refused(input: anytype, owned: *bool, expected: anyerror, start_ticket: Ticket, limit: usize) !void {
    if (Job.start(testing.allocator, &input.spec, input.models, start_ticket, limit, 3)) |job| {
        // 결함 주입으로 거절이 사라져도 이미 이동한 자원을 caller가 이중 해제하지 않는다.
        owned.* = false;
        job.deinit();
        drain();
        return error.TestUnexpectedWorkerStart;
    } else |err| try testing.expectEqual(expected, err);
}
test "RPBW4 신원 예산 disk 거절은 caller 소유권을 보존한다" {
    var input = try fixture(testing.allocator);
    var owned = true;
    defer if (owned) cleanup(testing.allocator, &input);
    try refused(&input, &owned, error.TooLarge, fixture_ticket, 5);
    var stale = fixture_ticket;
    stale.identity.request += 1;
    try refused(&input, &owned, error.StaleTargets, stale, 6);
    input.models[0].source.model.revision += 1;
    try refused(&input, &owned, error.StaleTargets, fixture_ticket, 6);
    input.models[0].source = .disk;
    try refused(&input, &owned, error.DiskTargetsNotSupported, fixture_ticket, 6);
    try testing.expectEqualStrings("foo", input.spec.needle);
}
fn allocationProbe(a: std.mem.Allocator) !void {
    var input = try fixture(a);
    const job = Job.start(a, &input.spec, input.models, fixture_ticket, 6, 3) catch |err| {
        cleanup(a, &input);
        return err;
    };
    defer drain();
    defer job.deinit();
    wait(job);
    var ready = (try job.take()).?;
    defer ready.deinit(a);
    try testing.expectEqualStrings("bar", ready.prepared.items.items[0].plan.after);
}
test "RPBW5 caller와 worker의 모든 준비 할당 실패를 회수한다" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProbe, .{});
}
test "RPBW6 마지막 snapshot의 원문 충돌은 앞 Plan도 반환하지 않는다" {
    var input = try fixture(testing.allocator);
    var changed = buffer.Buffer.init(testing.allocator, "xxx") catch |err| {
        cleanup(testing.allocator, &input);
        return err;
    };
    input.models[1].snapshot.deinit();
    input.models[1].snapshot = changed.snapshot();
    changed.deinit();
    const job = Job.start(testing.allocator, &input.spec, input.models, fixture_ticket, 6, 3) catch |err| {
        cleanup(testing.allocator, &input);
        return err;
    };
    defer drain();
    defer job.deinit();
    wait(job);
    try testing.expectError(error.StaleMatch, job.take());
    try testing.expect(job.prepared == null);
    for (job.specification.?.targets.items) |target| try testing.expectEqual(search.batch.Outcome.pending, target.outcome);
}
