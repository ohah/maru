const std = @import("std");

test "CR6e-c2 boundary keeps the blocking issuer exact-host move-only and product dormant" {
    const allocator = std.testing.allocator;
    const issuer = try read(allocator, "src/platform/macos/session_host/reconnect_worker_issuer.zig");
    defer allocator.free(issuer);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const persistent = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);

    try std.testing.expectEqual(@as(usize, 1), count(issuer, "host_connect.connectExistingHostUntil("));
    try std.testing.expectEqual(@as(usize, 0), count(issuer, "std.Thread.spawn"));
    inline for (.{ "*RemoteRuntime", "*HostAdapter", "HostPool" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), count(issuer, forbidden));
    try std.testing.expectEqual(@as(usize, 0), count(app, "reconnect_worker_issuer"));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "CR6e-c2 issuer 경계") != null);
    try std.testing.expect(std.mem.indexOf(u8, persistent, "`retry_later`로 보존") != null);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |at| {
        result += 1;
        start = at + needle.len;
    }
    return result;
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
