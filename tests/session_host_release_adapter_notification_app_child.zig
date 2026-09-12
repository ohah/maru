const std = @import("std");
const child = @import("release_adapter_notification_app_child");
const receipt = @import("release_adapter_notification_app_receipt");

const host = "00000000000000000000000000000001";
const runtime = "00000000000000000000000000000002";
const request = "maru-" ++ host ++ "-" ++ runtime ++ "-7";
const nonce = "123e4567-e89b-42d3-a456-426614174000";
const root = "/private/tmp/mn-123e4567e89b42d3a456426614174000";

fn inputs() child.Inputs {
    return .{
        .executable = "/Applications/Maru.app/Contents/MacOS/Maru",
        .expected = .{
            .scenario = .gui_zero,
            .request_identifier = request,
            .host_id = host,
            .runtime_id = runtime,
            .event_id = 7,
            .clicked_at_ns = 30,
            .deadline_ns = 100,
        },
        .runner_nonce = nonce,
        .runner_root = root,
    };
}

test "R2b2 app child plan passes one canonical closed environment and fd 3" {
    var storage: child.CommandStorage = .{};
    const plan = try child.commandPlanForTest(inputs(), &storage);
    try std.testing.expectEqualStrings("/Applications/Maru.app/Contents/MacOS/Maru", plan.executable);
    const expected = [_][]const u8{
        "MARU_SESSION_HOST_NOTIFICATION_APP_SCENARIO=maru-release-v1",
        "MARU_SESSION_HOST_NOTIFICATION_SCENARIO=gui-zero",
        "MARU_SESSION_HOST_NOTIFICATION_REQUEST=" ++ request,
        "MARU_SESSION_HOST_NOTIFICATION_HOST_ID=" ++ host,
        "MARU_SESSION_HOST_NOTIFICATION_RUNTIME_ID=" ++ runtime,
        "MARU_SESSION_HOST_NOTIFICATION_EVENT_ID=7",
        "MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS=100",
        "MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD=3",
        "MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE=" ++ nonce,
        "MARU_SESSION_HOST_NOTIFICATION_RUNNER_ROOT=" ++ root,
        "MARU_SESSION_HOST_ROOT=" ++ root ++ "/s",
        "HOME=" ++ root ++ "/h",
        "CFFIXED_USER_HOME=" ++ root ++ "/h",
    };
    try std.testing.expectEqual(expected.len, plan.environment.len);
    for (expected, plan.environment) |want, actual| try std.testing.expectEqualStrings(want, actual);
}

test "R2b2 app child rejects identity nonce root and executable drift before spawn" {
    var storage: child.CommandStorage = .{};
    var value = inputs();
    value.runner_root = "/private/tmp/mn-foreign";
    try std.testing.expectError(error.InvalidInput, child.commandPlanForTest(value, &storage));
    value = inputs();
    value.runner_nonce = "123e4567-e89b-32d3-a456-426614174000";
    try std.testing.expectError(error.InvalidInput, child.commandPlanForTest(value, &storage));
    value = inputs();
    value.executable = "relative";
    try std.testing.expectError(error.InvalidInput, child.commandPlanForTest(value, &storage));
    for ([_][:0]const u8{
        "/Applications//Maru.app/Contents/MacOS/Maru",
        "/Applications/./Maru.app/Contents/MacOS/Maru",
        "/Applications/../Maru.app/Contents/MacOS/Maru",
        "/Applications/Maru.app/Contents/MacOS/Maru/",
        "/Applications/Maru.app/Contents/MacOS/Maru\x01",
    }) |invalid| {
        value = inputs();
        value.executable = invalid;
        try std.testing.expectError(error.InvalidInput, child.commandPlanForTest(value, &storage));
    }
    value = inputs();
    value.expected.event_id = 0;
    try std.testing.expectError(error.InvalidExpected, child.commandPlanForTest(value, &storage));
}

test "R2b2 app child rejects output storage that aliases any borrowed input" {
    var executor: Executor = .{};
    var execution: child.Execution = .{};
    var value = inputs();
    value.runner_root = std.mem.asBytes(&execution);
    try std.testing.expectError(error.InvalidOwner, child.launchWith(&executor, value, &execution));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expect(execution.owner == null);
}

const Executor = struct {
    calls: usize = 0,
    fail_after_owner: bool = false,
    fail_pristine: bool = false,

    pub fn spawn(self: *@This(), plan: child.Plan, result: anytype) !void {
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 13), plan.environment.len);
        if (self.fail_pristine) return error.Injected;
        result.* = .{ .owner = result, .pid = 41, .fd = 42 };
        if (self.fail_after_owner) return error.Injected;
    }
};

test "R2b2 app child publishes owner only after the bounded child owns its process" {
    var executor: Executor = .{};
    var execution: child.Execution = .{};
    try child.launchWith(&executor, inputs(), &execution);
    try std.testing.expect(execution.owner == &execution);
    try std.testing.expect(execution.child.owner == &execution.child);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
}

test "R2b2 app child preserves ambiguous spawned authority and resets pristine failure" {
    var ambiguous_executor: Executor = .{ .fail_after_owner = true };
    var ambiguous: child.Execution = .{};
    try std.testing.expectError(error.Injected, child.launchWith(&ambiguous_executor, inputs(), &ambiguous));
    try std.testing.expect(ambiguous.owner == &ambiguous);
    try std.testing.expect(ambiguous.child.owner == &ambiguous.child);

    var pristine_executor: Executor = .{ .fail_pristine = true };
    var pristine: child.Execution = .{};
    try std.testing.expectError(error.Injected, child.launchWith(&pristine_executor, inputs(), &pristine));
    try std.testing.expect(pristine.owner == null);
    try std.testing.expect(pristine.child.owner == null);
}

test "R2b2 app child plan uses receipt SSOT scenarios" {
    var storage: child.CommandStorage = .{};
    var value = inputs();
    value.expected.scenario = receipt.Scenario.gui_live_then_quit;
    const plan = try child.commandPlanForTest(value, &storage);
    try std.testing.expectEqualStrings("MARU_SESSION_HOST_NOTIFICATION_SCENARIO=gui-live-then-quit", plan.environment[1]);
}

test "R2b2 app cleanup command and receipt are canonical and exact-request bound" {
    var command_storage: [320]u8 = undefined;
    var receipt_storage: [320]u8 = undefined;
    const expected = inputs().expected;
    const command = try child.formatCleanupCommand(expected, &command_storage);
    const acknowledgement = try child.formatCleanupReceipt(expected, &receipt_storage);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"maru.session-host-notification-cleanup-command.v1\",\"request_identifier\":\"" ++ request ++ "\"}",
        command,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"maru.session-host-notification-cleanup-receipt.v1\",\"request_identifier\":\"" ++ request ++ "\"}",
        acknowledgement,
    );
    var too_short: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, child.formatCleanupCommand(expected, &too_short));
}
