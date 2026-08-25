const std = @import("std");

test "P4 E2b product observation cache has one runtime owner and token-only subscriptions" {
    const allocator = std.testing.allocator;
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const server = try readSource(allocator, "src/platform/macos/session_host/server.zig");
    defer allocator.free(server);
    const turn = try readSource(allocator, "src/platform/macos/session_host/connection_turn.zig");
    defer allocator.free(turn);
    const inventory = try readSource(allocator, "src/platform/macos/session_host/handoff_inventory.zig");
    defer allocator.free(inventory);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(manager, "runtime_observation_cache.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "observation_caches:"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "fn cachedObservationOp("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "cached_observation: *const fn ("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "\n        observation_token: ?u64 = null"));
    try std.testing.expectEqual(@as(usize, 0), count(server, "observation_base"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "try js.beginWriteRaw()"));
    try std.testing.expectEqual(@as(usize, 1), count(turn, "producer_observation_epoch_ns: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(turn, "collectOutputForLocalStreamAtEpoch("));
    try std.testing.expectEqual(@as(usize, 1), count(inventory, "\"observation_caches\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-e2b\""));
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
