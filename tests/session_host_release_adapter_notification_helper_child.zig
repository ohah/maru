const std = @import("std");
const bounded = @import("bounded_process");
const child = @import("release_adapter_notification_helper_child");
const receipt = @import("release_adapter_notification_helper_receipt");

const executable: [:0]const u8 = "/Applications/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper";
const nonce = "123e4567-e89b-42d3-a456-426614174000-gui-zero";
const expected: receipt.Expected = .{ .visible_nonce = nonce, .deadline_ns = 43 };
const canonical = "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"" ++ nonce ++ "\",\"observed_at_ns\":41,\"clicked_at_ns\":42}\n";

const Executor = struct {
    calls: usize = 0,
    termination: bounded.Termination = .{ .exited = 0 },
    stdout: []const u8 = canonical,
    stderr: []const u8 = "",

    pub fn observe(self: *@This(), plan: child.Plan, stdout_buffer: []u8, stderr_buffer: []u8, budget_ns: i128) !bounded.Observation {
        self.calls += 1;
        try std.testing.expectEqual(executable.ptr, plan.argv[0].?);
        try std.testing.expectEqualStrings("click", std.mem.span(plan.argv[1].?));
        try std.testing.expectEqualStrings(nonce, std.mem.span(plan.argv[2].?));
        try std.testing.expectEqualStrings("43", std.mem.span(plan.argv[3].?));
        try std.testing.expect(plan.argv[4] == null);
        try std.testing.expect(plan.environment[0] == null);
        try std.testing.expectEqual(@as(i128, 99), budget_ns);
        try std.testing.expect(stdout_buffer.len == receipt.max_receipt_bytes and stderr_buffer.len == 1);
        return .{ .termination = self.termination, .stdout = self.stdout, .stderr = self.stderr };
    }
};

test "R2b2 helper child runs exact closed argv and parses clicked receipt" {
    var executor: Executor = .{};
    var storage: child.Storage = .{};
    const result = try child.runWith(&executor, std.testing.allocator, executable, expected, 99, &storage);
    try std.testing.expectEqual(@as(u64, 42), result.clicked.clicked_at_ns);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expect(!storage.in_use);
}

test "R2b2 helper child preserves typed provisioning exits only with empty streams" {
    inline for (.{ .{ @as(u8, 70), child.Provisioning.accessibility }, .{ @as(u8, 71), child.Provisioning.aqua } }) |case| {
        var executor: Executor = .{ .termination = .{ .exited = case[0] }, .stdout = "" };
        var storage: child.Storage = .{};
        const result = try child.runWith(&executor, std.testing.allocator, executable, expected, 99, &storage);
        try std.testing.expectEqual(case[1], result.not_provisioned);
    }
    var noisy: Executor = .{ .termination = .{ .exited = 70 }, .stdout = "noise" };
    var storage: child.Storage = .{};
    try std.testing.expectError(error.UnexpectedOutput, child.runWith(&noisy, std.testing.allocator, executable, expected, 99, &storage));
}

test "R2b2 helper child rejects helper failure signal and stderr" {
    var failed: Executor = .{ .termination = .{ .exited = 72 }, .stdout = "" };
    var storage: child.Storage = .{};
    try std.testing.expectError(error.HelperFailed, child.runWith(&failed, std.testing.allocator, executable, expected, 99, &storage));
    var signaled: Executor = .{ .termination = .{ .signal = 9 }, .stdout = "" };
    try std.testing.expectError(error.HelperFailed, child.runWith(&signaled, std.testing.allocator, executable, expected, 99, &storage));
    var noisy: Executor = .{ .stderr = "x" };
    try std.testing.expectError(error.UnexpectedOutput, child.runWith(&noisy, std.testing.allocator, executable, expected, 99, &storage));
}

test "R2b2 helper child rejects malformed input before process execution" {
    var executor: Executor = .{};
    var storage: child.Storage = .{};
    try std.testing.expectError(error.InvalidInput, child.runWith(&executor, std.testing.allocator, "relative", expected, 99, &storage));
    try std.testing.expectError(error.InvalidInput, child.runWith(&executor, std.testing.allocator, executable, expected, 0, &storage));
    var invalid = expected;
    invalid.visible_nonce = "not-a-nonce";
    try std.testing.expectError(error.InvalidExpected, child.runWith(&executor, std.testing.allocator, executable, invalid, 99, &storage));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "R2b2 helper child rejects live or aliased storage" {
    var executor: Executor = .{};
    var storage: child.Storage = .{ .in_use = true };
    try std.testing.expectError(error.InvalidOwner, child.runWith(&executor, std.testing.allocator, executable, expected, 99, &storage));
    storage.in_use = false;
    var aliased = expected;
    aliased.visible_nonce = std.mem.asBytes(&storage);
    try std.testing.expectError(error.InvalidOwner, child.runWith(&executor, std.testing.allocator, executable, aliased, 99, &storage));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "R2b2 helper child clears transient argv and capture bytes after parse failure" {
    var executor: Executor = .{ .stdout = "{}" };
    var storage: child.Storage = .{};
    try std.testing.expectError(error.InvalidReceipt, child.runWith(&executor, std.testing.allocator, executable, expected, 99, &storage));
    try std.testing.expect(!storage.in_use);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&storage.stdout), 0));
    try std.testing.expect(storage.argv[0] == null and storage.environment[0] == null);
}
