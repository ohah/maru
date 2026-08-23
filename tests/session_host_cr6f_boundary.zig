const std = @import("std");

test "CR6f output wake keeps reader publication separate from owner-thread delta production" {
    const allocator = std.testing.allocator;
    const queue = try readSource(allocator, "src/app/pty_reader.zig");
    defer allocator.free(queue);
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const owner = try readSource(allocator, "src/platform/macos/session_host/poll_owner.zig");
    defer allocator.free(owner);
    const socket_server = try readSource(allocator, "src/platform/macos/session_host/socket_server.zig");
    defer allocator.free(socket_server);
    const daemon = try readSource(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    const restore = try readSource(allocator, "src/platform/macos/session_host/restore_activation.zig");
    defer allocator.free(restore);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(queue, "pub const WakeNotifier = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(queue, "pub fn setWakeNotifier"));
    try std.testing.expectEqual(@as(usize, 3), count(queue, "wake.notify(wake.ctx)"));
    try std.testing.expectEqual(@as(usize, 0), count(queue, "collectDeltas"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "const OutputWake = struct"));
    try std.testing.expectEqual(@as(usize, 2), count(manager, "eventQueue().setWakeNotifier"));
    try std.testing.expectEqual(@as(usize, 0), count(manager, "collectDeltas"));

    try std.testing.expectEqual(@as(usize, 1), count(owner, "self.server.drainOwnerWake()"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "self.scheduleProducerNow(now_ns)"));
    try std.testing.expectEqual(@as(usize, 1), count(socket_server, "pub const delta_tick_ms: i32 = 20"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "manager.enableOutputWake()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore, "manager.enableOutputWake()"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-cr6f\""));
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
