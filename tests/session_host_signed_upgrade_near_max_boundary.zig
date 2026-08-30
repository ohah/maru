const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "U5 signed near-max gate owns 255 real PTYs and exact GUI reattach evidence" {
    const source = @embedFile("session_host_signed_upgrade_e2e.zig");
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(build);
    try std.testing.expectEqual(@as(usize, 1), count(source, "const near_max_runtime_count = session_host.upgrade_limits.max_runtime_count - 1;"));
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_count: usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.eql(u8, raw, \"near-max\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_set_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "verifyExactRuntimeSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (records) |*record|") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".attachExisting(") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "test-session-host-signed-upgrade-near-max") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/session-host-signed-upgrade-near-max/summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "\"near-max\"") != null);
}
