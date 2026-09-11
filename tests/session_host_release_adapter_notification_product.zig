const std = @import("std");
const product = @import("release_adapter_notification_product");

const Event = enum { bind, initial, zero, after_zero, live, after_live, cleanup_notifications, after_cleanup, publish, final, deadline, clean_publish, clean_live, clean_zero };
const success = [_]Event{ .bind, .initial, .zero, .after_zero, .live, .after_live, .cleanup_notifications, .after_cleanup, .publish, .final, .deadline };

const Recorder = struct {
    events: [32]Event = undefined,
    len: usize = 0,
    fail: ?Event = null,
    cleanup_fail: ?Event = null,
    cleanup_fail_also: ?Event = null,
    deadline_value: u8 = 0,

    fn add(self: *@This(), event: Event) !void {
        self.events[self.len] = event;
        self.len += 1;
        if (self.fail == event or self.cleanup_fail == event or self.cleanup_fail_also == event) return error.Injected;
    }
    fn same(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline_value, deadline);
    }
    pub fn bindAuthorities(self: *@This()) !void {
        try self.add(.bind);
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        return &self.deadline_value;
    }
    pub fn validateInitialAuthorities(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.initial);
    }
    pub fn runGuiZero(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.zero);
    }
    pub fn validateAfterGuiZero(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.after_zero);
    }
    pub fn runGuiLiveThenQuit(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.live);
    }
    pub fn validateAfterGuiLiveThenQuit(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.after_live);
    }
    pub fn cleanupNotifications(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.cleanup_notifications);
    }
    pub fn validateAfterCleanup(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.after_cleanup);
    }
    pub fn publishEvidence(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.publish);
    }
    pub fn validateFinalAuthorities(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.final);
    }
    pub fn validateFinalDeadline(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.deadline);
    }
    pub fn cleanupEvidence(self: *@This()) !void {
        try self.add(.clean_publish);
    }
    pub fn cleanupGuiLiveThenQuit(self: *@This()) !void {
        try self.add(.clean_live);
    }
    pub fn cleanupGuiZero(self: *@This()) !void {
        try self.add(.clean_zero);
    }
};

test "R2a binds one deadline and revalidates every authority between real OS scenarios" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{};
    try product.executeWith(&recorder, &execution);
    try std.testing.expectEqualSlices(Event, &success, recorder.events[0..recorder.len]);
    try std.testing.expect(execution.ownsSuccessfulOutputs());
}

test "R2a rejects copied and preowned executions before authority binding" {
    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    var recorder: Recorder = .{};
    try std.testing.expectError(error.InvalidOwner, product.executeWith(&recorder, &original));
    try std.testing.expectError(error.InvalidOwner, product.executeWith(&recorder, &copied));
    try std.testing.expectEqual(@as(usize, 0), recorder.len);
}

test "R2a records a child before delegation and cleans exact attempts in reverse" {
    const cases = .{
        .{ Event.zero, &[_]Event{.clean_zero} },
        .{ Event.after_zero, &[_]Event{.clean_zero} },
        .{ Event.live, &[_]Event{ .clean_live, .clean_zero } },
        .{ Event.after_live, &[_]Event{ .clean_live, .clean_zero } },
        .{ Event.cleanup_notifications, &[_]Event{ .clean_live, .clean_zero } },
        .{ Event.after_cleanup, &[_]Event{} },
        .{ Event.publish, &[_]Event{.clean_publish} },
        .{ Event.final, &[_]Event{.clean_publish} },
        .{ Event.deadline, &[_]Event{.clean_publish} },
    };
    inline for (cases) |case| {
        const failure = case[0];
        const cleanup = case[1];
        var execution: product.Execution = .{};
        var recorder: Recorder = .{ .fail = failure };
        try std.testing.expectError(error.Injected, product.executeWith(&recorder, &execution));
        try std.testing.expectEqualSlices(Event, cleanup, recorder.events[recorder.len - cleanup.len .. recorder.len]);
        try std.testing.expect(execution.owner == null);
    }
}

test "R2a retains only failed cleanup authorities and retry is exact" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{ .fail = .after_live, .cleanup_fail = .clean_live, .cleanup_fail_also = .clean_zero };
    try std.testing.expectError(error.CleanupFailed, product.executeWith(&recorder, &execution));
    try std.testing.expect(!execution.evidence_attempted);
    try std.testing.expect(execution.gui_live_then_quit_attempted);
    try std.testing.expect(execution.gui_zero_attempted);
    recorder.cleanup_fail = null;
    recorder.cleanup_fail_also = null;
    try product.retryCleanupWith(&recorder, &execution);
    try std.testing.expect(execution.owner == null);
}
