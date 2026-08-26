const std = @import("std");
const delivery = @import("notification_os_delivery");
const journal_mod = delivery.journal_api;

const limits: journal_mod.Limits = .{
    .max_events = 8,
    .max_resident_bytes = 512,
    .max_title_bytes = 64,
    .max_body_bytes = 128,
    .max_label_bytes = 64,
};
const host_id: u128 = 0x11111111111111111111111111111111;

const ScriptedAdapter = struct {
    outcomes: []const delivery.AdapterResult,
    pos: usize = 0,
    calls: [256]delivery.Route = undefined,
    call_count: usize = 0,
    expired: [16]delivery.Route = undefined,
    expire_count: usize = 0,

    fn adapter(self: *ScriptedAdapter) delivery.Adapter {
        return .{ .context = self, .submitFn = submit, .expireFn = expire };
    }

    fn submit(context: *anyopaque, request: delivery.Request) delivery.AdapterResult {
        const self: *ScriptedAdapter = @ptrCast(@alignCast(context));
        self.calls[self.call_count] = request.route;
        self.call_count += 1;
        const result = self.outcomes[self.pos];
        self.pos += 1;
        return result;
    }

    fn expire(context: *anyopaque, route: delivery.Route) void {
        const self: *ScriptedAdapter = @ptrCast(@alignCast(context));
        self.expired[self.expire_count] = route;
        self.expire_count += 1;
    }
};

test "P4 N2b2 notification OS delivery passes typed route and acks only accepted" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const key = try journal.admit(0xaa, 7, "title", "body", "workspace");
    var scripted = ScriptedAdapter{ .outcomes = &.{.accepted} };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(10, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 1), scripted.call_count);
    try std.testing.expectEqual(delivery.Route{ .hid = host_id, .rid = 0xaa, .eid = key.event_id }, scripted.calls[0]);
    try std.testing.expect(journal.oldestPending(.os) == null);
    try std.testing.expectEqual(@as(u64, 1), machine.counters().accepted);
}

test "P4 N2b2 notification OS delivery records terminal degraded without success ack or retry" {
    inline for (.{ delivery.AdapterResult.denied, .bundle_missing, .entitlement_missing }) |outcome| {
        var journal: journal_mod.Journal = undefined;
        try journal.initInPlace(std.testing.allocator, host_id, limits);
        defer journal.deinit() catch unreachable;
        const key = try journal.admit(0xaa, 7, "secret title", "secret body", "workspace");
        var scripted = ScriptedAdapter{ .outcomes = &.{outcome} };
        var machine: delivery.Machine = undefined;
        machine.initInPlace();

        try std.testing.expectEqual(delivery.TickResult.degraded, machine.tick(10, &journal, scripted.adapter()));
        try std.testing.expectEqual(delivery.TickResult.idle, machine.tick(20, &journal, scripted.adapter()));
        try std.testing.expectEqual(@as(usize, 1), scripted.call_count);
        try std.testing.expect(!journal.peek(key).?.pending_os);
        try std.testing.expect(journal.peek(key).?.pending_gui);
        try std.testing.expectEqual(@as(u64, 1), machine.counters().terminal_degraded);
        try std.testing.expectEqual(@as(u64, 0), machine.counters().accepted);
    }
}

test "P4 N2b2 notification OS delivery retries 250ms exponential capped at 8s for six attempts" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(0xaa, 7, "title", "body", "workspace");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .transient, .transient, .transient, .transient, .transient, .transient } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    const due = [_]u64{ 0, 250_000_000, 750_000_000, 1_750_000_000, 3_750_000_000, 7_750_000_000, 15_750_000_000 };
    for (due, 0..) |now, index| {
        if (index > 0) try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(now - 1, &journal, scripted.adapter()));
        const expected: delivery.TickResult = if (index == due.len - 1) .retry_exhausted else .retry_scheduled;
        try std.testing.expectEqual(expected, machine.tick(now, &journal, scripted.adapter()));
    }
    try std.testing.expectEqual(@as(usize, 7), scripted.call_count);
    try std.testing.expectEqual(@as(u64, 1), machine.counters().retry_exhausted);
    try std.testing.expect(journal.oldestPending(.os) == null);
}

test "P4 N2b2 notification OS delivery pinned retry does not starve sibling runtime" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const first = try journal.admit(0xaa, 7, "first", "body", "left");
    const sibling = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .accepted, .accepted } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(1, &journal, scripted.adapter()));
    try std.testing.expectEqual(sibling.event_id, scripted.calls[1].eid);
    try std.testing.expect(journal.peek(first).?.pending_os);
    try std.testing.expect(!journal.peek(sibling).?.pending_os);
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(250_000_000, &journal, scripted.adapter()));
    try std.testing.expect(journal.oldestPending(.os) == null);
}

test "P4 N2b2 notification OS delivery keeps the original pin when a sibling is transient" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const first = try journal.admit(0xaa, 7, "first", "body", "left");
    const sibling = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .transient, .accepted } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.deferred, machine.tick(1, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(2, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 2), scripted.call_count);
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(250_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(first.event_id, scripted.calls[2].eid);
    try std.testing.expect(!journal.peek(first).?.pending_os);
    try std.testing.expect(journal.peek(sibling).?.pending_os);
}

test "P4 N2b2 notification OS delivery polls one asynchronous request without duplicating siblings" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const first = try journal.admit(0xaa, 7, "first", "body", "left");
    _ = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .pending, .accepted } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(49_999_999, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 1), scripted.call_count);
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(50_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(first.event_id, scripted.calls[1].eid);
}

test "P4 N2b2 notification OS delivery turns a stuck asynchronous request into bounded retry" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(0xaa, 7, "first", "body", "left");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .pending, .pending } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(10_000_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(u64, 1), machine.counters().transient_failures);
    try std.testing.expectEqual(@as(u64, 1), machine.counters().retries_scheduled);
    try std.testing.expectEqual(@as(usize, 1), scripted.expire_count);
}

test "P4 N2b2 notification OS delivery async polls do not spend the retry budget" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(0xaa, 7, "first", "body", "left");
    var outcomes = [_]delivery.AdapterResult{.pending} ** 201;
    var scripted = ScriptedAdapter{ .outcomes = &outcomes };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(0, &journal, scripted.adapter()));
    for (1..200) |poll| {
        try std.testing.expectEqual(
            delivery.TickResult.waiting,
            machine.tick(@as(u64, poll) * 50_000_000, &journal, scripted.adapter()),
        );
    }
    try std.testing.expectEqual(
        delivery.TickResult.retry_scheduled,
        machine.tick(10_000_000_000, &journal, scripted.adapter()),
    );
    try std.testing.expectEqual(@as(usize, 200), scripted.call_count);
    try std.testing.expectEqual(@as(u64, 1), machine.counters().retries_scheduled);
    try std.testing.expectEqual(@as(u64, 0), machine.counters().retry_exhausted);
    try std.testing.expectEqual(@as(usize, 1), scripted.expire_count);
}

test "P4 N2b2 notification OS delivery gives each post-backoff async request a fresh timeout" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(0xaa, 7, "first", "body", "left");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .pending, .pending, .pending } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(250_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(10_249_999_999, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(10_250_000_000, &journal, scripted.adapter()));
}

test "P4 N2b2 notification OS delivery owns an async sibling until settlement" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const primary = try journal.admit(0xaa, 7, "first", "body", "left");
    const sibling = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .pending, .accepted, .accepted } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(1, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(49_999_999, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(50_000_001, &journal, scripted.adapter()));
    try std.testing.expectEqual(sibling.event_id, scripted.calls[1].eid);
    try std.testing.expectEqual(sibling.event_id, scripted.calls[2].eid);
    try std.testing.expect(journal.peek(primary).?.pending_os);
    try std.testing.expect(!journal.peek(sibling).?.pending_os);
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(250_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(primary.event_id, scripted.calls[3].eid);
}

test "P4 N2b2 notification OS delivery expires the exact async sibling before primary resumes" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const primary = try journal.admit(0xaa, 7, "first", "body", "left");
    const sibling = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .pending, .accepted } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(1, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.deferred, machine.tick(10_000_000_001, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 1), scripted.expire_count);
    try std.testing.expectEqual(sibling.event_id, scripted.expired[0].eid);
    try std.testing.expectEqual(delivery.TickResult.accepted, machine.tick(10_000_000_002, &journal, scripted.adapter()));
    try std.testing.expectEqual(primary.event_id, scripted.calls[2].eid);
}

test "P4 N2b2 notification OS delivery expires an inflight request evicted from the journal" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    const original = try journal.admit(0xaa, 7, "first", "body", "left");
    var scripted = ScriptedAdapter{ .outcomes = &.{.pending} };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(0, &journal, scripted.adapter()));
    for (0..limits.max_events) |index| {
        _ = try journal.admit(0xbb, @intCast(index + 8), "replacement", "body", "right");
    }
    try std.testing.expect(journal.peek(original) == null);
    try std.testing.expectEqual(delivery.TickResult.stale, machine.tick(50_000_000, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 1), scripted.expire_count);
    try std.testing.expectEqual(original.event_id, scripted.expired[0].eid);
}

test "P4 N2b2 notification OS delivery expires an inflight sibling evicted from the journal" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, host_id, limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(0xaa, 7, "first", "body", "left");
    const sibling = try journal.admit(0xbb, 8, "second", "body", "right");
    var scripted = ScriptedAdapter{ .outcomes = &.{ .transient, .pending } };
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.retry_scheduled, machine.tick(0, &journal, scripted.adapter()));
    try std.testing.expectEqual(delivery.TickResult.waiting, machine.tick(1, &journal, scripted.adapter()));
    for (0..limits.max_events) |index| {
        _ = try journal.admit(0xcc, @intCast(index + 9), "replacement", "body", "right");
    }
    try std.testing.expect(journal.peek(sibling) == null);
    try std.testing.expectEqual(delivery.TickResult.stale, machine.tick(50_000_001, &journal, scripted.adapter()));
    try std.testing.expectEqual(@as(usize, 1), scripted.expire_count);
    try std.testing.expectEqual(sibling.event_id, scripted.expired[0].eid);
}
