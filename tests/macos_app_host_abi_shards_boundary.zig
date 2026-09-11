//! AppSession 스위트 샤딩의 배선 계약 — 같은 바이너리를 래퍼 한 스텝 안에서 4샤드로 동시에 돌고, process-global 네임스페이스를 소유하는
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

    // 샤드 수는 한 곳의 상수다. 바꾸려면 여기와 함께 바꾼다 — CI 실측(4샤드 172초, 3샤드 249~272초)이 근거다 — 경합에 약하던 반복 횟수 대기는 #3327 이 벽시계 마감으로 바꿨다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "const macos_app_host_abi_shards: usize = 4;"));
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
    // **필터로 한 모듈만 돌리는 스텝 하나는 예외다**(2026-09-10). `shutdown_admin_connector` 는 실 프로세스를
    // 띄우는데(`runActualTerminate`) 샤드 넷이 **동시에** 도는 동안 다른 데몬 스모크와 겹치면 5 초 안에 못 뜬다.
    // 배정이 `index % n` 이라 **테스트 하나가 늘 때마다 조합이 바뀌고**, 그래서 그날 세 번 터졌는데 매번 다른
    // 테스트였다(`C3-3b6` 둘, 이것 하나). 그 스텝은 여섯 개만 돌아 **355 초 임계 경로를 되살리지 않는다** —
    // 이 계약이 막으려던 것은 바이너리를 **통째로** 다시 돌리는 배선이다. 그래서 개수와 함께 **필터가 걸려
    // 있는지**도 잠근다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "b.addRunArtifact(macos_app_host_abi_tests)"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"session_host.shutdown_admin_connector.\","));
    // 그 모듈은 샤드 안에서 **안** 돈다 — 옛 `MARU_TEST_KEEP_PREFIX` 배선이 돌아오면 겹침이 되살아난다.
    try std.testing.expectEqual(@as(usize, 0), count(build, "MARU_TEST_KEEP_PREFIX"));
    // fresh 사슬의 꼬리가 그 스텝이고, top-level 은 그것을 기다린다.
    try std.testing.expectEqual(@as(usize, 1), count(build, "test_macos_app_host_abi_step.dependOn(&run_macos_shutdown_admin_fresh_tests.step);"));

    // 러너: 선택 규칙은 **이름 해시** mod n 이고, 빈 샤드는 빨개진다. 문서도 같은 이름을 안다.
    //
    // **인덱스가 아니라 이름**인 이유(2026-09-10): 인덱스 순차면 테스트 하나가 늘 때 **그 뒤 전부 밀려**
    // 실 프로세스 스모크가 한 샤드에 몰린다. 그날 세 번 CI 를 막았고 매번 다른 테스트였다 — CI 와 로컬이
    // 같은 자리였으니 부하가 아니라 배정이다. 되돌리면 그 룰렛이 돌아온다.
    try std.testing.expectEqual(@as(usize, 1), count(runner, "std.hash.Wyhash.hash(0, test_fn.name) % s.count == s.index"));
    try std.testing.expectEqual(@as(usize, 0), count(runner, "index % s.count == s.index"));
    try std.testing.expectEqual(@as(usize, 1), count(runner, "shard ran no tests"));
    try std.testing.expect(count(runner, "MARU_TEST_SHARD") >= 2);
    try std.testing.expect(count(docs, "MARU_TEST_SHARD") >= 1);
    try std.testing.expect(count(docs, "run-test-shards.sh") >= 1);
}
