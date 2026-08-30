//! Daemon cleanup fail-stop process gate의 제품/test 경계와 exact inventory를 고정한다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

test "daemon cleanup fail-stop fixture stays test-only and exact" {
    const allocator = std.testing.allocator;
    const daemon = try read(allocator, "src/platform/macos/session_host/daemon.zig", 256 * 1024);
    defer allocator.free(daemon);
    const loop = try read(allocator, "src/platform/macos/session_host/upgrade_loop.zig", 128 * 1024);
    defer allocator.free(loop);
    const coordinator = try read(allocator, "src/platform/macos/session_host/upgrade_product_coordinator.zig", 256 * 1024);
    defer allocator.free(coordinator);
    const process_test = try read(allocator, "tests/session_host_daemon_cleanup_fail_stop_e2e.zig", 64 * 1024);
    defer allocator.free(process_test);
    const build = try read(allocator, "build.zig", 1024 * 1024);
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(daemon, "pub fn runSessionHostWithIdentityCleanupCollisionFixture("));
    try std.testing.expect(std.mem.indexOf(u8, daemon, "if (!builtin.is_test) @compileError") != null);
    try std.testing.expectEqual(@as(usize, 1), count(loop, "processPreclosedCleanupCollisionFixture("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "processArmedPreclosedCleanupCollisionFixture("));
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "after_budget_prepare:") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "host.upgrade.prepare") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "prepareUpgrade(") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "c.W.EXITSTATUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "error.ConnectFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "test-session-host-upgrade-daemon-cleanup-fail-stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "run_daemon_cleanup_fail_stop_tests.addArg(\"--maru-expect-tests=1\")") != null);
}
