const std = @import("std");

test "P4 E2a cache remains a platform leaf after product wiring" {
    const allocator = std.testing.allocator;
    const cache = try readSource(allocator, "src/platform/macos/session_host/runtime_observation_cache.zig");
    defer allocator.free(cache);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(cache, "pub const Cache = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(cache, "pub fn prepare("));
    try std.testing.expectEqual(@as(usize, 1), count(cache, "pub fn commit("));
    try std.testing.expectEqual(@as(usize, 0), count(cache, "@import(\"server.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(cache, "@import(\"runtime_manager.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(cache, "std.posix"));
    try std.testing.expectEqual(@as(usize, 0), count(cache, "std.c"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-e2a\""));
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
