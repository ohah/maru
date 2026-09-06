//! 캐시 세대 정리의 전제 — `cache-cleanup.yml` 이 main 그룹마다 **최신 1개**만 남기는 것은 ci.yml 의 모든 캐시 복원이
//! `restore-keys` 접두 폴백을 갖고 있을 때만 안전하다(정확한 sha 키가 지워져도 그룹의 최신 항목을 적중한다). 폴백 없는
//! 복원 스텝이 하나라도 생기거나, 청소가 다시 2개 이상을 남기게 바뀌면 여기서 걸린다(실측 2026-09-06: 2세대 정책에서
//! 29개 10.8GB 로 한도 초과, 1세대면 4.9GB).
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

test "cache cleanup keeps one generation because every ci.yml restore has a prefix fallback" {
    const allocator = std.testing.allocator;
    const ci = try read(allocator, ".github/workflows/ci.yml", 1024 * 1024);
    defer allocator.free(ci);
    const cleanup = try read(allocator, ".github/workflows/cache-cleanup.yml", 256 * 1024);
    defer allocator.free(cleanup);

    // 복원 스텝마다 restore-keys 블록이 하나씩 — 폴백 없는 복원은 sha 키가 지워지면 콜드가 된다.
    const restores = count(ci, "actions/cache/restore@");
    try std.testing.expect(restores >= 1);
    try std.testing.expectEqual(restores, count(ci, "          restore-keys: |\n"));
    // 폴백 줄은 그 그룹의 접두(hashFiles 까지)로 끝난다 — sha 만 빠진 형태. 블록마다 하나 이상이다(경계 샤드 블록은
    // 예전 통합 키와 check 키로도 폴백해 여럿이다).
    try std.testing.expect(count(ci, "tools/ci/prune-zig-cache.sh') }}-\n") >= restores);

    // 청소는 main 그룹마다 최신 1개만 남긴다.
    try std.testing.expectEqual(@as(usize, 1), count(cleanup, "for c in items[1:]:"));
    try std.testing.expectEqual(@as(usize, 0), count(cleanup, "for c in items[2:]:"));
    try std.testing.expectEqual(@as(usize, 1), count(cleanup, "최신 1개 초과\")"));
    // main CI 가 끝날 때마다 돈다 — 저장이 생기는 시점과 걷어내는 시점이 붙어 있어야 한도에 안 닿는다.
    try std.testing.expectEqual(@as(usize, 1), count(cleanup, "  workflow_run:\n    workflows: [\"CI\"]\n    types: [completed]\n    branches: [main]\n"));
}
