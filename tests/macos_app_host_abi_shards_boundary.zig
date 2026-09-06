//! AppSession 스위트 샤딩의 배선 계약 — 같은 바이너리를 래퍼 한 스텝 안에서 3샤드로 동시에 돌고, process-global 네임스페이스를 소유하는
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
    const wrapper = try read(allocator, "tools/run-test-shards.sh", 64 * 1024);
    defer allocator.free(wrapper);

    // 샤드 수는 한 곳의 상수다. 바꾸려면 여기와 함께 바꾼다 — 코어(3 vCPU)당 프로세스 하나가 근거다 — 4샤드는 경합으로 타이밍 판정자가 흔들렸다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "const macos_app_host_abi_shards: usize = 3;"));
    // 병렬은 run 스텝 하나 안에서 래퍼가 한다 — Zig 0.16 빌드 러너는 stdio 를 물려받는 run 스텝을 stderr 잠금으로
    // 전역 직렬로 돌린다(PR #3302 실측: 샤드 넷이 80초 간격으로 차례로 끝났다). 래퍼는 파일 인자라 바뀌면 다시 돈다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "run_macos_app_host_abi_shards.addFileArg(b.path(\"tools/run-test-shards.sh\"));"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "run_macos_app_host_abi_shards.addArtifactArg(macos_app_host_abi_tests);"));
    // **fresh 프로세스 판정자 사슬의 머리는 샤드 스텝 뒤에 돈다.** 겹치면 CoreText 캐시·signal/seal/daemon 네임스페이스가 충돌한다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "run_macos_external_tty_fresh_tests.step.dependOn(&run_macos_app_host_abi_shards.step);"));
    // `test` 스텝(macOS)도 샤드 스텝에 의존한다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "test_step.dependOn(&run_macos_app_host_abi_shards.step);"));
    // 래퍼: 샤드마다 MARU_TEST_SHARD 를 심고, 전부 기다린 뒤 하나라도 실패하면 실패한다.
    try std.testing.expectEqual(@as(usize, 1), count(wrapper, "MARU_TEST_SHARD=\"$i/$n\" \"$bin\" \"$@\""));
    try std.testing.expectEqual(@as(usize, 1), count(wrapper, "run-test-shards: shard $i/$n exited with $r"));
    // 단일 프로세스 실행도, run 스텝 n 개 배선도 더 이상 없다.
    try std.testing.expectEqual(@as(usize, 0), count(build, "run_macos_app_host_abi_tests"));
    try std.testing.expectEqual(@as(usize, 0), count(build, "b.addRunArtifact(macos_app_host_abi_tests)"));

    // 러너: 선택 규칙은 전역 인덱스 mod n 이고, 빈 샤드는 빨개진다. 문서도 같은 이름을 안다.
    try std.testing.expectEqual(@as(usize, 1), count(runner, "index % s.count == s.index"));
    try std.testing.expectEqual(@as(usize, 1), count(runner, "shard ran no tests"));
    try std.testing.expect(count(runner, "MARU_TEST_SHARD") >= 2);
    try std.testing.expect(count(docs, "MARU_TEST_SHARD") >= 1);
    try std.testing.expect(count(docs, "run-test-shards.sh") >= 1);
}
