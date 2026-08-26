//! P4 N2b3 GUI history and Notification Center stable-route boundary.

const std = @import("std");

test "P4 N2b3 GUI history stable route boundary projects one typed key without taking OS ownership" {
    const allocator = std.testing.allocator;
    const session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(session);
    const notifications = try readSource(allocator, "src/platform/macos/app_session/notification.zig");
    defer allocator.free(notifications);
    const abi = try readSource(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try readSource(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);
    const swift = try readSource(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const daemon_adapter = try readSource(allocator, "src/platform/macos/session_host_notification_adapter.m");
    defer allocator.free(daemon_adapter);
    const route_formatter = try readSource(allocator, "src/platform/macos/session_host_notification_route.c");
    defer allocator.free(route_formatter);

    try std.testing.expect(std.mem.indexOf(u8, session, "const StableNotificationRoute = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, session, "route: ?StableNotificationRoute") != null);
    try std.testing.expect(std.mem.indexOf(u8, notifications, "notif.route") != null);
    try std.testing.expect(std.mem.indexOf(u8, notifications, "route.occurred_at_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, notifications, "notif.display_label") != null);

    try std.testing.expect(std.mem.indexOf(u8, abi, "route_present_out") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "uint32_t *route_present_out") != null);
    try std.testing.expectEqual(@as(usize, 1), count(route_formatter, "maru-%016llx%016llx-%016llx%016llx-%llu"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "maru_session_host_notification_format_identifier("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon_adapter, "maru_session_host_notification_format_identifier("));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "maru-%016"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon_adapter, "maru-%016"));
    try std.testing.expect(std.mem.indexOf(u8, swift, "\"hid\": stableHostId") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "\"rid\": stableRuntimeId") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "\"eid\": eventId") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "identifier = UUID().uuidString") != null);

    // GUI consumes only the journal's GUI delivery through runtime.notification. OS ownership
    // remains daemon-internal; importing its machine here would create a second acknowledgement owner.
    try std.testing.expectEqual(@as(usize, 0), count(notifications, "notification_os_delivery"));
    try std.testing.expectEqual(@as(usize, 0), count(notifications, "ackOs"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
