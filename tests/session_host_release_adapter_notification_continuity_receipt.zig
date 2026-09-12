const std = @import("std");
const receipt = @import("release_adapter_notification_continuity_receipt");

const host = "11111111111111111111111111111111";
const runtime = "22222222222222222222222222222222";
const request = "maru-11111111111111111111111111111111-22222222222222222222222222222222-7";
const nonce = "123e4567-e89b-42d3-a456-426614174000-gui-zero";
const app_bytes = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"maru-11111111111111111111111111111111-22222222222222222222222222222222-7\",\"host_id\":\"11111111111111111111111111111111\",\"runtime_id\":\"22222222222222222222222222222222\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":50,\"attach_kind\":\"recovered\"}";
const helper_bytes = "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"123e4567-e89b-42d3-a456-426614174000-gui-zero\",\"observed_at_ns\":20,\"clicked_at_ns\":30}\n";

fn expected() receipt.Expected {
    return .{
        .visible_nonce = nonce,
        .app = .{ .scenario = .gui_zero, .request_identifier = request, .host_id = host, .runtime_id = runtime, .event_id = 7, .clicked_at_ns = 30, .deadline_ns = 100 },
        .app_receipt_bytes = app_bytes,
        .helper_receipt_bytes = helper_bytes,
        .submitted_at_ns = 10,
        .before_marker = "MARU_BEFORE",
        .after_marker = "MARU_AFTER",
    };
}

fn canonical() []const u8 {
    return "{\"schema\":\"maru.session-host-notification-continuity-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"maru-11111111111111111111111111111111-22222222222222222222222222222222-7\",\"host_id\":\"11111111111111111111111111111111\",\"runtime_id\":\"22222222222222222222222222222222\",\"event_id\":7,\"attached_at_ns\":50,\"connection_generation_before\":9,\"connection_generation_after\":9,\"host_pid_before\":101,\"host_pid_after\":101,\"child_pid_before\":202,\"child_pid_after\":202,\"before_marker\":\"MARU_BEFORE\",\"after_marker\":\"MARU_AFTER\",\"before_observed_at_ns\":45,\"input_sent_at_ns\":60,\"after_observed_at_ns\":70}";
}

test "R2b3 derives the final scenario booleans only from an exact continuity receipt" {
    const value = try receipt.parse(std.testing.allocator, canonical(), expected());
    try std.testing.expectEqual(@as(u64, 9), value.connection_generation);
    try std.testing.expect(value.scenario.screen_before_preserved);
    try std.testing.expect(value.scenario.screen_after_writable);
    try std.testing.expectEqual(@as(u64, 101), value.scenario.daemon_pid_after);
}

test "R2b3 rejects PID generation marker and timeline drift" {
    inline for (.{
        .{ "\"host_pid_after\":101", "\"host_pid_after\":102" },
        .{ "\"connection_generation_after\":9", "\"connection_generation_after\":10" },
        .{ "\"after_marker\":\"MARU_AFTER\"", "\"after_marker\":\"MARU_BEFORE\"" },
        .{ "\"input_sent_at_ns\":60", "\"input_sent_at_ns\":50" },
    }) |replacement| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, canonical(), replacement[0], replacement[1]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(error.EvidenceMismatch, receipt.parse(std.testing.allocator, bytes, expected()));
    }
    var late_submission = expected();
    late_submission.submitted_at_ns = 20;
    try std.testing.expectError(error.EvidenceMismatch, receipt.parse(std.testing.allocator, canonical(), late_submission));
    var split_click = expected();
    split_click.app.clicked_at_ns = 31;
    try std.testing.expectError(error.EvidenceMismatch, receipt.parse(std.testing.allocator, canonical(), split_click));
}

test "R2b3 rejects noncanonical and caller-shaped outcome fields" {
    const spaced = try std.mem.replaceOwned(u8, std.testing.allocator, canonical(), "\":", "\": ");
    defer std.testing.allocator.free(spaced);
    try std.testing.expectError(error.NonCanonicalReceipt, receipt.parse(std.testing.allocator, spaced, expected()));
    const injected = try std.mem.replaceOwned(u8, std.testing.allocator, canonical(), "{\"schema\"", "{\"screen_after_writable\":true,\"schema\"");
    defer std.testing.allocator.free(injected);
    try std.testing.expectError(error.InvalidReceipt, receipt.parse(std.testing.allocator, injected, expected()));
}

fn parseWithAllocator(allocator: std.mem.Allocator) !void {
    _ = try receipt.parse(allocator, canonical(), expected());
}

test "R2b3 rejects split helper authority and unwinds every allocation failure" {
    var wrong = expected();
    wrong.helper_receipt_bytes = "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"123e4567-e89b-42d3-a456-426614174000-gui-live-then-quit\",\"observed_at_ns\":20,\"clicked_at_ns\":30}\n";
    try std.testing.expectError(error.IdentityMismatch, receipt.parse(std.testing.allocator, canonical(), wrong));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithAllocator, .{});
}
