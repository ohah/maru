//! check-boundaries 샤딩의 배선 계약 — 등록은 전부 `boundary_step` 에 남고, `-Dboundary-shard=i/n` 이 있을 때만 `build()`
//! 끝에서 의존 목록을 인덱스 mod n 으로 잘라 `check-boundaries` 를 다시 만든다. CI 는 샤드 넷 + 필수 체크 이름을 지키는
//! 집계 잡이며, 집계는 네 샤드가 찍은 «내 몫 / 전체» 의 합을 다시 센다. 누군가 샤드를 하나로 되돌리거나 집계의 합 검사를
//! 빼거나 옵션 없는 로컬 실행을 부분 실행으로 바꾸면 여기서 걸린다(실측 2026-09-06: 직렬 810초가 PR 임계 경로였다).
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

test "check-boundaries runs as four index shards behind one aggregate check that re-counts the union" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig", 4 * 1024 * 1024);
    defer allocator.free(build);
    const workflow = try read(allocator, ".github/workflows/ci.yml", 1024 * 1024);
    defer allocator.free(workflow);
    const docs = try read(allocator, "docs/development-commands.md", 1024 * 1024);
    defer allocator.free(docs);

    // build.zig: 옵션 하나, 조건부 이름, 인덱스 mod n 선택, 빈 샤드 거부, «내 몫 / 전체» 한 줄.
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"boundary-shard\","));
    try std.testing.expectEqual(@as(usize, 1), count(build, "if (boundary_shard != null) \"check-boundaries-all\" else \"check-boundaries\","));
    try std.testing.expectEqual(@as(usize, 1), count(build, "if (index % shard.count != shard.index) continue;"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "selects no steps"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"check-boundaries shard {d}/{d}: {d} of {d} steps\\n\""));
    // 등록은 여전히 boundary_step 하나에 매달린다 — 샤드 스텝에 직접 등록하는 자리는 없다.
    try std.testing.expectEqual(@as(usize, 0), count(build, "sharded.dependOn(&run_"));
    try std.testing.expect(count(build, "boundary_step.dependOn(&run_") >= 100);

    // 워크플로: 샤드 매트릭스 넷(fail-fast 끔), 샤드마다 -Dboundary-shard, 집계 잡의 이름과 합 검사.
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "  check-boundaries-shard:\n"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "        shard: [0, 1, 2, 3]\n"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "      fail-fast: false\n      matrix:\n        shard: [0, 1, 2, 3]\n"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "zig build check-boundaries -Dboundary-shard=\"$SHARD/4\""));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "  check-boundaries:\n    # "));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "    name: check-boundaries\n"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "    needs: [changes, check-boundaries-shard]\n"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "[ \"$sum\" -eq \"$total\" ] ||"));
    // 샤드 캐시는 샤드별 키에 저장하고 예산은 전체의 1/3 이다 — 저장소 캐시가 10 GB 상한에 닿아 있다.
    try std.testing.expectEqual(@as(usize, 2), count(workflow, "check-boundaries-s${{ matrix.shard }}of4-${{ hashFiles('build.zig.zon', 'tools/ci/prune-zig-cache.sh') }}-${{ github.sha }}"));
    try std.testing.expectEqual(@as(usize, 1), count(workflow, "prune-zig-cache.sh 1024"));

    // 문서는 같은 이름을 안다.
    try std.testing.expect(count(docs, "boundary-shard") >= 1);
}
