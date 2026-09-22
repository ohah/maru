//! 실제 kernel cleanup 연속 실패 gate의 관측·제품 경계와 exact inventory를 고정한다.

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

test "kernel cleanup fault gate observes real errno and keeps injection test-only" {
    const allocator = std.testing.allocator;
    const store = try read(allocator, "src/platform/macos/session_host/handoff_store.zig", 256 * 1024);
    defer allocator.free(store);
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

    try std.testing.expectEqual(@as(usize, 1), count(
        store,
        "test \"reservation cleanup observes consecutive kernel permission and nonempty failures\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, store, "KernelCleanupEvidence") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        store,
        "if (!builtin.is_test) @compileError(\"kernel cleanup observation is test-only\")",
    ) != null);
    try std.testing.expectEqual(@as(usize, 3), count(store, "if (comptime builtin.is_test)"));
    try std.testing.expectEqual(@as(usize, 2), count(store, "value.* = posix.errno(-1)"));
    try std.testing.expectEqual(@as(usize, 1), count(store, "value.attempt_remove = posix.errno(-1)"));
    try std.testing.expectEqual(@as(usize, 2), count(store, "expectEqual(posix.E.ACCES"));
    try std.testing.expectEqual(@as(usize, 1), count(store, "expectEqual(posix.E.NOTEMPTY"));
    try std.testing.expectEqual(@as(usize, 1), count(
        daemon,
        "pub fn runSessionHostWithIdentityKernelCleanupFaultFixture(",
    ));
    const fixture_start = std.mem.indexOf(
        u8,
        daemon,
        "pub fn runSessionHostWithIdentityKernelCleanupFaultFixture(",
    ) orelse return error.MissingFixtureEntrypoint;
    const fixture_tail = daemon[fixture_start..];
    const fixture_end = std.mem.indexOf(u8, fixture_tail, "\nconst UpgradeFixtureFault") orelse
        return error.MissingFixtureEntrypointEnd;
    const fixture = fixture_tail[0..fixture_end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        fixture,
        "if (!builtin.is_test) @compileError(\"kernel cleanup fault fixture is test-only\")",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), count(loop, "processPreclosedKernelCleanupFaultFixture("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "processArmedPreclosedKernelCleanupFaultFixture("));
    const loop_start = std.mem.indexOf(u8, loop, "pub fn processPreclosedKernelCleanupFaultFixture(") orelse
        return error.MissingLoopFixture;
    const loop_tail = loop[loop_start..];
    const loop_end = std.mem.indexOf(u8, loop_tail, "\nconst ProcessMode") orelse
        return error.MissingLoopFixtureEnd;
    try std.testing.expect(std.mem.indexOf(
        u8,
        loop_tail[0..loop_end],
        "@compileError(\"kernel cleanup fault fixture is test-only\")",
    ) != null);
    const coordinator_start = std.mem.indexOf(
        u8,
        coordinator,
        "pub fn processArmedPreclosedKernelCleanupFaultFixture(",
    ) orelse return error.MissingCoordinatorFixture;
    const coordinator_tail = coordinator[coordinator_start..];
    const coordinator_end = std.mem.indexOf(u8, coordinator_tail, "\nfn processArmedMode") orelse
        return error.MissingCoordinatorFixtureEnd;
    try std.testing.expect(std.mem.indexOf(
        u8,
        coordinator_tail[0..coordinator_end],
        "@compileError(\"kernel cleanup fault fixture is test-only\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, daemon, "MARU_SESSION_HOST_UPGRADE_CLEANUP") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "host.upgrade.prepare") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "prepareUpgrade(") != null);
    try std.testing.expectEqual(@as(usize, 1), count(
        process_test,
        "test \"daemon kernel cleanup faults exit nonzero and remove listener authority\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, process_test, "attempt_stat.mode & 0o777") != null);
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 본다 — 문자열은 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expect(graph.step("test-session-host-upgrade-kernel-cleanup-faults") != null);
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_kernel_cleanup_component_tests", "--maru-expect-tests=1"));
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_kernel_cleanup_process_tests", "--maru-expect-tests=1"));
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_kernel_cleanup_boundary_tests", "--maru-expect-tests=1"));
}
