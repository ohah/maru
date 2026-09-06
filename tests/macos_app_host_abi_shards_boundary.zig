//! AppSession 스위트 샤딩의 배선 계약 — 같은 바이너리를 4샤드로 나눠 돌고, process-global 네임스페이스를 소유하는
//! fresh 프로세스 판정자는 **모든 샤드 뒤에** 돈다. 누군가 샤드를 하나로 되돌리거나 fresh 판정자를 샤드와 겹치게
//! 배선하면 여기서 걸린다(실측 2026-09-06: 단일 프로세스 355초가 file explorer 잡의 임계 경로였다).
const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "AppSession suite runs as index shards and fresh process judges wait for every shard" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig", 4 * 1024 * 1024);
    defer allocator.free(build);
    const runner = try read(allocator, "tools/simple_test_runner.zig", 256 * 1024);
    defer allocator.free(runner);
    const docs = try read(allocator, "docs/development-commands.md", 1024 * 1024);
    defer allocator.free(docs);

    // 샤드 수는 한 곳의 상수다. 바꾸려면 여기와 함께 바꾼다 — 시뮬레이션(N=4: 94초, N=3: 145초)이 근거다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "const macos_app_host_abi_shards: usize = 4;"));
    // 샤드마다 같은 아티팩트에 MARU_TEST_SHARD={i}/N 만 다르게 심는다.
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "run.setEnvironmentVariable(\"MARU_TEST_SHARD\", b.fmt(\"{d}/{d}\", .{ shard, macos_app_host_abi_shards }));",
    ));
    // **fresh 프로세스 판정자 사슬의 머리는 모든 샤드 뒤에 돈다.** 겹치면 CoreText 캐시·signal/seal/daemon 네임스페이스가 충돌한다.
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "for (macos_app_host_abi_shard_runs) |shard_run| run_macos_external_tty_fresh_tests.step.dependOn(&shard_run.step);",
    ));
    // `test` 스텝(macOS)도 샤드 전부에 의존한다 — 한 샤드만 매달면 나머지 3/4 가 조용히 빠진다.
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "for (macos_app_host_abi_shard_runs) |shard_run| test_step.dependOn(&shard_run.step);",
    ));
    // 단일 프로세스 실행은 더 이상 없다.
    try std.testing.expectEqual(@as(usize, 0), count(build, "run_macos_app_host_abi_tests"));

    // 러너: 선택 규칙은 전역 인덱스 mod n 이고, 빈 샤드는 빨개진다. 문서도 같은 이름을 안다.
    try std.testing.expectEqual(@as(usize, 1), count(runner, "index % s.count == s.index"));
    try std.testing.expectEqual(@as(usize, 1), count(runner, "shard ran no tests"));
    try std.testing.expect(count(runner, "MARU_TEST_SHARD") >= 2);
    try std.testing.expect(count(docs, "MARU_TEST_SHARD") >= 1);
}
