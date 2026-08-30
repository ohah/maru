const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

// The signed success harness must prove the restored PTY's natural product lifetime. A cleanup
// RPC can make the test green even when the restored child cannot receive input, exit, or be
// reaped by the upgraded host, so this source boundary keeps that shortcut closed.
test "U5 signed success proves PTY exit and host-owned reap without terminate shortcut" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/session_host_signed_upgrade_e2e.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    try std.testing.expectEqual(
        @as(usize, 3),
        count(source, "\"EXIT_23\""),
    );
    try std.testing.expectEqual(@as(usize, 0), count(source, "MARU_SIGNED_UPGRADE_EXIT_23"));
    try std.testing.expectEqual(@as(usize, 1), count(source, "fn waitForRuntimeGone("));
    try std.testing.expectEqual(@as(usize, 0), count(source, "fn terminateRuntime("));
    try std.testing.expectEqual(@as(usize, 1), count(source, "client.runtimeInventory()"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "if (count < 0) return error.ChildInventoryUnavailable;"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(source, ".runtime_reaped_after_exit = true"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, ".runtime_inventory_absent_observations = 2"),
    );
}
