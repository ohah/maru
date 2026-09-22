const std = @import("std");

test "CR6e-c1 boundary keeps the worker handoff bounded pointer-free and product-dormant" {
    const allocator = std.testing.allocator;
    const owner = try read(allocator, "src/platform/macos/session_host/reconnect_worker_owner.zig");
    defer allocator.free(owner);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const persistent = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try read(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const verification = try read(allocator, "docs/verification-matrix.md");
    defer allocator.free(verification);

    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const max_jobs: usize = 32;"));
    inline for (.{ "*RemoteRuntime", "*Client", "*HostAdapter", "std.Thread.spawn", "connectExistingHostUntil" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), count(owner, forbidden));
    try std.testing.expectEqual(@as(usize, 0), count(app, "reconnect_worker_owner"));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "CR6e-c 자동 reconnect 제품 배선 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "**CR6e-c**") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification, "c1은 app-global bounded host job/completion") != null);
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
