const std = @import("std");
const owner = @import("release_adapter_notification_process_owner");

const Event = enum { bind, root, app, helper, collect, collect_continuity, publish, clean_receipt, clean_request, clean_helper, clean_app, clean_root };
const normal = [_]Event{ .bind, .root, .app, .helper, .collect, .collect_continuity, .publish, .clean_request, .clean_helper, .clean_app, .clean_root };

const Recorder = struct {
    events: [32]Event = undefined,
    len: usize = 0,
    fail: ?Event = null,
    cleanup_fail: ?Event = null,
    deadline: u8 = 0,

    fn add(self: *@This(), event: Event) !void {
        self.events[self.len] = event;
        self.len += 1;
        if (self.fail == event or self.cleanup_fail == event) return error.Injected;
    }
    fn same(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
    }
    pub fn bind(self: *@This()) !void {
        try self.add(.bind);
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        return &self.deadline;
    }
    pub fn createRoot(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.root);
    }
    pub fn launchApp(self: *@This(), d: *u8) !void {
        try self.same(d);
        try self.add(.app);
    }
    pub fn runHelper(self: *@This(), d: *u8) !u8 {
        try self.same(d);
        try self.add(.helper);
        return 7;
    }
    pub fn collectAppReceipt(self: *@This(), d: *u8) !u8 {
        try self.same(d);
        try self.add(.collect);
        return 9;
    }
    pub fn collectContinuityReceipt(self: *@This(), d: *u8) !u8 {
        try self.same(d);
        try self.add(.collect_continuity);
        return 11;
    }
    pub fn publishReceipt(self: *@This(), d: *u8, click: u8, receipt: u8, continuity: u8) !void {
        try self.same(d);
        try std.testing.expectEqual(@as(u8, 7), click);
        try std.testing.expectEqual(@as(u8, 9), receipt);
        try std.testing.expectEqual(@as(u8, 11), continuity);
        try self.add(.publish);
    }
    pub fn cleanupReceipt(self: *@This()) !void {
        try self.add(.clean_receipt);
    }
    pub fn cleanupRequest(self: *@This()) !void {
        try self.add(.clean_request);
    }
    pub fn cleanupHelper(self: *@This()) !void {
        try self.add(.clean_helper);
    }
    pub fn cleanupApp(self: *@This()) !void {
        try self.add(.clean_app);
    }
    pub fn cleanupRoot(self: *@This()) !void {
        try self.add(.clean_root);
    }
};

test "R2b2 composes app helper receipts and exact cleanup under one deadline" {
    var execution: owner.Execution = .{};
    var recorder: Recorder = .{};
    try owner.executeWith(&recorder, &execution);
    try std.testing.expectEqualSlices(Event, &normal, recorder.events[0..recorder.len]);
    try std.testing.expect(execution.ownsReceipt());
}

test "R2b2 records every external attempt before failure and cleans in reverse" {
    const cases = .{
        .{ Event.root, &[_]Event{.clean_root} },
        .{ Event.app, &[_]Event{ .clean_request, .clean_app, .clean_root } },
        .{ Event.helper, &[_]Event{ .clean_request, .clean_helper, .clean_app, .clean_root } },
        .{ Event.collect, &[_]Event{ .clean_request, .clean_helper, .clean_app, .clean_root } },
        .{ Event.collect_continuity, &[_]Event{ .clean_request, .clean_helper, .clean_app, .clean_root } },
        .{ Event.publish, &[_]Event{ .clean_request, .clean_helper, .clean_app, .clean_root } },
    };
    inline for (cases) |case| {
        var execution: owner.Execution = .{};
        var recorder: Recorder = .{ .fail = case[0] };
        try std.testing.expectError(error.Injected, owner.executeWith(&recorder, &execution));
        try std.testing.expectEqualSlices(Event, case[1], recorder.events[recorder.len - case[1].len .. recorder.len]);
        try std.testing.expect(execution.owner == null);
    }
}

test "R2b2 never claims or removes a pre-existing receipt after exclusive publish rejects it" {
    var execution: owner.Execution = .{};
    var recorder: Recorder = .{ .fail = .publish };
    try std.testing.expectError(error.Injected, owner.executeWith(&recorder, &execution));
    try std.testing.expect(std.mem.indexOfScalar(Event, recorder.events[0..recorder.len], .clean_receipt) == null);
    try std.testing.expect(execution.owner == null);
}

test "R2b2 cleanup failure retains only its exact retry authority" {
    var execution: owner.Execution = .{};
    var recorder: Recorder = .{ .fail = .collect, .cleanup_fail = .clean_app };
    try std.testing.expectError(error.CleanupFailed, owner.executeWith(&recorder, &execution));
    try std.testing.expect(!execution.request_attempted);
    try std.testing.expect(!execution.helper_attempted);
    try std.testing.expect(execution.app_attempted);
    try std.testing.expect(!execution.root_attempted);
    recorder.cleanup_fail = null;
    try owner.retryCleanupWith(&recorder, &execution);
    try std.testing.expect(execution.owner == null);
}

test "R2b2 refuses copied preowned and successful executions" {
    var original: owner.Execution = .{};
    original.owner = &original;
    var copied = original;
    var recorder: Recorder = .{};
    try std.testing.expectError(error.InvalidOwner, owner.executeWith(&recorder, &original));
    try std.testing.expectError(error.InvalidOwner, owner.executeWith(&recorder, &copied));
    try std.testing.expectEqual(@as(usize, 0), recorder.len);
}
