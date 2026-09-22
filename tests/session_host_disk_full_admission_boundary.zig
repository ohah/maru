//! Actual ENOSPC admission gate의 순서, process evidence와 test-only 경계를 고정한다.

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

test "disk full admission gate uses real ENOSPC before product budget prepare" {
    const allocator = std.testing.allocator;
    const daemon = try read(allocator, "src/platform/macos/session_host/daemon.zig", 256 * 1024);
    defer allocator.free(daemon);
    const loop = try read(allocator, "src/platform/macos/session_host/upgrade_loop.zig", 128 * 1024);
    defer allocator.free(loop);
    const coordinator = try read(allocator, "src/platform/macos/session_host/upgrade_product_coordinator.zig", 256 * 1024);
    defer allocator.free(coordinator);
    const process_test = try read(allocator, "tests/session_host_disk_full_admission_e2e.zig", 96 * 1024);
    defer allocator.free(process_test);
    const harness = try read(allocator, "tools/ci/session-host-disk-full-admission.sh", 16 * 1024);
    defer allocator.free(harness);
    const build = try build_source.read(allocator);
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(
        process_test,
        "test \"actual disk full admission resumes before quiesce and keeps daemon live\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, process_test, "prepareUpgrade(") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "upgradeStatus(") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "runtimeInventory(") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "host.info") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "host.upgrade.prepare") == null);

    const fixture_name = "processArmedPreclosedDiskFullAdmissionFixture(";
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, fixture_name));
    const fixture_start = std.mem.indexOf(u8, coordinator, "pub fn " ++ fixture_name) orelse
        return error.MissingCoordinatorFixture;
    const fixture_tail = coordinator[fixture_start..];
    const fixture_end = std.mem.indexOf(u8, fixture_tail, "\nfn processArmedMode") orelse
        return error.MissingCoordinatorFixtureEnd;
    try std.testing.expect(std.mem.indexOf(
        u8,
        fixture_tail[0..fixture_end],
        "@compileError(\"disk full admission fixture is test-only\")",
    ) != null);
    const fill = std.mem.indexOf(u8, coordinator, "fillOwnerVolumeUntilEnospcForFixture(") orelse
        return error.MissingRealDiskFill;
    const prepare = std.mem.indexOf(u8, coordinator, "budget_admission.prepare(") orelse
        return error.MissingBudgetPrepare;
    try std.testing.expect(fill < prepare);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "posix.E.NOSPC") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        coordinator,
        "defer if (disk_full_fixture_active) removeDiskFullFixture(ctx.owner_dir, attempt_id)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, ".disk-full-fixture-") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_test, "runtime.terminate") != null);

    try std.testing.expectEqual(@as(usize, 1), count(loop, "processPreclosedDiskFullAdmissionFixture("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "runSessionHostWithDiskFullAdmissionFixture("));
    try std.testing.expect(std.mem.indexOf(u8, daemon, "MARU_SESSION_HOST_UPGRADE_DISK_FULL") == null);
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 본다 — 문자열은 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expect(graph.step("test-session-host-upgrade-disk-full-admission") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "run_disk_full_admission_process_tests.addArtifactArg") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness, "--maru-expect-tests=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness, "fixture_root=$(mktemp -d /tmp/maru-disk-full.XXXXXX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness, "image=\"$fixture_root/fixture.dmg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness, "mktemp /tmp/maru-disk-full.XXXXXX.dmg") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "run_disk_full_admission_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    ) != null);
}
