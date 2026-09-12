const std = @import("std");
const receipt = @import("release_adapter_notification_helper_receipt");

const nonce = "123e4567-e89b-42d3-a456-426614174000-gui-zero";
const canonical = "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"" ++ nonce ++ "\",\"observed_at_ns\":41,\"clicked_at_ns\":42}\n";
const expected: receipt.Expected = .{ .visible_nonce = nonce, .deadline_ns = 43 };

test "R2b2 helper receipt parses the exact canonical click evidence" {
    const observed = try receipt.parse(std.testing.allocator, canonical, expected);
    try std.testing.expectEqual(@as(u64, 41), observed.observed_at_ns);
    try std.testing.expectEqual(@as(u64, 42), observed.clicked_at_ns);
}

test "R2b2 helper receipt rejects malformed duplicate unknown and noncanonical bytes" {
    try std.testing.expectError(error.InvalidReceipt, receipt.parse(std.testing.allocator, "{}", expected));
    try std.testing.expectError(error.NonCanonicalReceipt, receipt.parse(std.testing.allocator, canonical ++ "\n", expected));
    try std.testing.expectError(error.InvalidReceipt, receipt.parse(std.testing.allocator, "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"" ++ nonce ++ "\",\"observed_at_ns\":41,\"clicked_at_ns\":42}", expected));
    try std.testing.expectError(error.InvalidReceipt, receipt.parse(std.testing.allocator, "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"" ++ nonce ++ "\",\"observed_at_ns\":41,\"clicked_at_ns\":42,\"extra\":0}", expected));
}

test "R2b2 helper receipt binds exact nonce result and absolute timeline" {
    var wrong = expected;
    wrong.visible_nonce = "123e4567-e89b-42d3-a456-426614174000-gui-live-then-quit";
    try std.testing.expectError(error.IdentityMismatch, receipt.parse(std.testing.allocator, canonical, wrong));
    const wrong_result = "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"denied\",\"visible_nonce\":\"" ++ nonce ++ "\",\"observed_at_ns\":41,\"clicked_at_ns\":42}\n";
    try std.testing.expectError(error.IdentityMismatch, receipt.parse(std.testing.allocator, wrong_result, expected));
    var exact_deadline = expected;
    exact_deadline.deadline_ns = 42;
    try std.testing.expectError(error.InvalidTimeline, receipt.parse(std.testing.allocator, canonical, exact_deadline));
}

test "R2b2 helper receipt rejects cap plus one without accepting a prefix" {
    var bytes: [receipt.max_receipt_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.ReceiptTooLarge, receipt.parse(std.testing.allocator, &bytes, expected));
}

test "R2b2 helper receipt reports every allocation failure and leaks nothing" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        _ = receipt.parse(failing.allocator(), canonical, expected) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        break;
    }
    try std.testing.expect(fail_index > 0);
}
