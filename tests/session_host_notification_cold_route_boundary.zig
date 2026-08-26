//! P4 N3 notification cold-launch exact-attach product boundary.
//!
//! A Notification Center response is persisted, untrusted OS input. This gate keeps strict route
//! parsing, pre-run delegate installation, bounded pre-launch retention, and the Zig exact-handle
//! activation ABI in one reviewable slice. It intentionally does not claim the provisioned signed
//! Notification Center click gate, which remains a separate OS-level requirement.

const std = @import("std");

test "P4 N3 cold notification response routes only a coherent stable handle" {
    const allocator = std.testing.allocator;
    const swift = try readSource(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(session);
    const abi = try readSource(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try readSource(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);

    const delegate_install = try expectOne(swift, "UNUserNotificationCenter.current().delegate = delegate");
    const app_run = try expectOne(swift, "app.run()");
    try std.testing.expect(delegate_install < app_run);
    try std.testing.expectEqual(@as(usize, 0), count(swift, "UNUserNotificationCenter.current().delegate = self"));

    try expectContains(swift, "private static let maxPendingStableNotificationRoutes");
    try expectContains(swift, "parseStableNotificationRoute(");
    try expectContains(swift, "requestIdentifier:");
    try expectContains(swift, "hostNotificationIdentifier(");
    try expectContains(swift, "drainPendingStableNotificationRoutes()");
    try expectContains(swift, "maru_macos_app_session_activate_notification_runtime(");
    try expectContains(swift, "Task { @MainActor [weak self] in");
    try std.testing.expectEqual(@as(usize, 0), count(swift, "MainActor.assumeIsolated {\n            defer { completionHandler()"));

    // A stable route must never fall through to the process-local token path: token/surface ids can
    // be reused after cold launch and would select an unrelated terminal.
    try expectContains(swift, "let stableRoute = Self.parseStableNotificationRoute(");
    try expectContains(swift, "if let stableRoute {");
    try expectContains(swift, "handleStableNotificationRoute(stableRoute)");
    try expectContains(swift, "let localRoute = hasStableKey ? nil : Self.parseNotificationRoute(userInfo)");
    try expectContains(swift, "var boundSurface: TerminalSurface?");
    try expectContains(swift, "if boundSurface != nil { return }");
    try expectContains(swift, "if matched == 2 { return }");
    try expectContains(swift, "route.runtimeIdLo,\n                1");
    try expectContains(swift, "route.runtimeIdLo,\n                  2");

    try expectContains(session, "pub fn activateNotificationRuntime(");
    try expectContains(session, "pub const NotificationRuntimeAction = enum");
    try expectContains(session, "if (action == .probe_bound) return true;");
    try expectContains(session, "activateRecoveredSessionAt(");
    try expectContains(abi, "pub export fn maru_macos_app_session_activate_notification_runtime(");
    try expectContains(abi, "else => return 2");
    try expectContains(abi, "return 2;");
    try expectContains(header, "uint32_t maru_macos_app_session_activate_notification_runtime(");
}

fn expectOne(haystack: []const u8, needle: []const u8) !usize {
    try std.testing.expectEqual(@as(usize, 1), count(haystack, needle));
    return std.mem.indexOf(u8, haystack, needle) orelse error.TestExpectedEqual;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
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
