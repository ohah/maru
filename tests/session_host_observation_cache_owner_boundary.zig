const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

test "P4 E2b product observation cache has one runtime owner and token-only subscriptions" {
    const allocator = std.testing.allocator;
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const server = try readSource(allocator, "src/platform/macos/session_host/server.zig");
    defer allocator.free(server);
    const turn = try readSource(allocator, "src/platform/macos/session_host/connection_turn.zig");
    defer allocator.free(turn);
    const inventory = try readSource(allocator, "src/platform/macos/session_host/handoff_inventory.zig");
    defer allocator.free(inventory);
    const build = try build_source.read(allocator);
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(manager, "runtime_observation_cache.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "observation_caches:"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "fn cachedObservationOp("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "cached_observation: *const fn ("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "\n        observation_token: ?u64 = null"));
    try std.testing.expectEqual(@as(usize, 0), count(server, "observation_base"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "try js.beginWriteRaw()"));
    try std.testing.expectEqual(@as(usize, 1), count(turn, "producer_observation_epoch_ns: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(turn, "collectOutputForLocalStreamAtEpoch("));
    try std.testing.expectEqual(@as(usize, 1), count(inventory, "\"observation_caches\""));
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-e2b"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}
