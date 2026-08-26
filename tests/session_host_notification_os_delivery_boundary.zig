//! P4 N2b2 product wiring and layering boundary.

const std = @import("std");

test "P4 N2b2 OS delivery boundary pins daemon ownership and macOS stable route wiring" {
    const allocator = std.testing.allocator;
    const machine = try readSource(allocator, "src/platform/macos/session_host/notification_os_delivery.zig");
    defer allocator.free(machine);
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const daemon = try readSource(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    const restore = try readSource(allocator, "src/platform/macos/session_host/restore_activation.zig");
    defer allocator.free(restore);
    const main = try readSource(allocator, "src/main.zig");
    defer allocator.free(main);
    const adapter = try readSource(allocator, "src/platform/macos/session_host_notification_adapter.m");
    defer allocator.free(adapter);
    const zig_adapter = try readSource(allocator, "src/platform/macos/session_host/notification_macos_adapter.zig");
    defer allocator.free(zig_adapter);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 0), count(machine, "@import(\"../../app_session.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(machine, "@import(\"client.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(machine, "@import(\"remote_runtime.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "notification_os_machine: notification_os_delivery.Machine"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "self.notification_os_machine.tick("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "manager.installNotificationOsAdapter(adapter)"));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "manager.installNotificationOsAdapter(adapter)"));
    try std.testing.expectEqual(@as(usize, 1), count(main, "runWithNotificationAdapter("));
    try std.testing.expectEqual(@as(usize, 1), count(main, "runSessionHostWithIdentityStartupAndNotificationAdapter("));

    try std.testing.expectEqual(@as(usize, 1), count(adapter, "requestWithIdentifier:identifier content:content trigger:nil"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "@\"hid\":"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "@\"rid\":"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "@\"eid\":"));
    try std.testing.expectEqual(@as(usize, 2), count(adapter, "attemptGeneration, MARU_NOTIFICATION_DENIED)"));
    try std.testing.expect(std.mem.indexOf(u8, adapter, "authorizationStatus == UNAuthorizationStatusDenied) {\n            maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_DENIED);") != null);
    try std.testing.expect(std.mem.indexOf(u8, adapter, "authorizationStatus == UNAuthorizationStatusNotDetermined) {\n            // Permission prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, adapter, "foreground app's authorization decision without opening its own prompt.\n            maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_TRANSIENT);") != null);
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "maruInflightTimeoutSeconds = 10.0"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "maruInflightGeneration == generation"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "void maru_session_host_notification_expire("));
    try std.testing.expectEqual(@as(usize, 1), count(zig_adapter, ".expireFn = expire"));
    try std.testing.expectEqual(@as(usize, 1), count(zig_adapter, "maru_session_host_notification_expire("));
    try std.testing.expectEqual(@as(usize, 2), count(build, "session_host_notification_adapter.m"));
    try std.testing.expect(count(build, "linkFramework(\"UserNotifications\"") >= 2);
    try std.testing.expectEqual(@as(usize, 1), count(build, "session_host_notification_adapter_compile_stub.c"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "linkSessionHostNotificationCompileStub(b, cross_exe)"));
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
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}
