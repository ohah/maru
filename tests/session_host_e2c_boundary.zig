const std = @import("std");

test "P4 E2c source change preflight stays lock free and steady state foreground sampling stays allocation free" {
    const allocator = std.testing.allocator;
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const inventory = try readSource(allocator, "src/platform/macos/session_host/handoff_inventory.zig");
    defer allocator.free(inventory);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(manager, "fn refreshForegroundCache("));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "surface.core.observerGeneration() != record.observer_generation"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "surface.core.title_generation.load(.monotonic) != record.title_generation"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "var names: [64]ForegroundProcessName = undefined"));
    try std.testing.expectEqual(@as(usize, 0), count(manager, "allocator.alloc(ForegroundProcessName"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "P4 E2c observation materialization follows runtime source changes at 1 10 100 scale"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "pub const ObservationPerformanceEvidence = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(inventory, "\"observation_core_lock_hold_total_ns\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-e2c\""));
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
