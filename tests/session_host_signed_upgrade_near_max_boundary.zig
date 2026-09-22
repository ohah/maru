const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "U5 signed near-max gate owns 255 real PTYs and exact GUI reattach evidence" {
    const source = @embedFile("session_host_signed_upgrade_e2e.zig");
    const build = try build_source.read(std.testing.allocator);
    defer std.testing.allocator.free(build);
    try std.testing.expectEqual(@as(usize, 1), count(source, "const near_max_runtime_count = session_host.upgrade_limits.max_runtime_count - 1;"));
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_count: usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.eql(u8, raw, \"near-max\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_set_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "verifyExactRuntimeSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (records) |*record|") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".attachExisting(") != null);
    var graph = try build_graph.parse(std.testing.allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 본다 — 문자열은 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expect(graph.step("test-session-host-signed-upgrade-near-max") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/session-host-signed-upgrade-near-max/summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "\"near-max\"") != null);
}
