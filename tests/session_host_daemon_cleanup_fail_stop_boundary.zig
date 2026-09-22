//! Daemon cleanup fail-stop process gate의 제품/test 경계와 exact inventory를 고정한다.

const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

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
    const build = try build_source.read(allocator);
    defer allocator.free(build);

    const fixture_start = std.mem.indexOf(
        u8,
        daemon,
        "pub fn runSessionHostWithIdentityCleanupCollisionFixture(",
    ) orelse return error.MissingFixtureEntrypoint;
    const fixture_tail = daemon[fixture_start..];
    const fixture_end = std.mem.indexOf(u8, fixture_tail, "\nconst UpgradeFixtureFault") orelse
        return error.MissingFixtureEntrypointEnd;
    const fixture = fixture_tail[0..fixture_end];
    try std.testing.expectEqual(@as(usize, 1), count(
        daemon,
        "pub fn runSessionHostWithIdentityCleanupCollisionFixture(",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        fixture,
        "if (!builtin.is_test) @compileError(\"cleanup collision fixture is test-only\")",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), count(fixture, ".cleanup_collision"));
    try std.testing.expect(std.mem.indexOf(u8, daemon, "MARU_SESSION_HOST_UPGRADE_CLEANUP") == null);
    try std.testing.expectEqual(@as(usize, 1), count(loop, "processPreclosedCleanupCollisionFixture("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "processArmedPreclosedCleanupCollisionFixture("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "after_budget_prepare:"));
    try std.testing.expect(std.mem.indexOf(u8, process_test, "host.upgrade.prepare") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "prepareUpgrade(") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "c.W.EXITSTATUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "error.WriteFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "error.EndpointAbsent") != null);
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 본다 — 문자열은 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expect(graph.step("test-session-host-upgrade-daemon-cleanup-fail-stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "run_daemon_cleanup_fail_stop_tests.addArg(\"--maru-expect-tests=1\")") != null);
}
