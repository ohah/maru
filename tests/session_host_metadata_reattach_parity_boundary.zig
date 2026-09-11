//! P3-e4d-1 actual metadata isolation and reconnect boundary.

const std = @import("std");

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

test "P3-e4d-1 metadata parity uses actual daemon runtimes and no test wire" {
    const allocator = std.testing.allocator;
    const runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig", 2 * 1024 * 1024);
    defer allocator.free(runtime);
    const build = try read(allocator, "build.zig", 2 * 1024 * 1024);
    defer allocator.free(build);
    const ssot = try read(allocator, "docs/persistent-session-host.md", 2 * 1024 * 1024);
    defer allocator.free(ssot);
    const matrix = try read(allocator, "docs/verification-matrix.md", 2 * 1024 * 1024);
    defer allocator.free(matrix);
    const plan = try read(allocator, "docs/implementation-plan.md", 2 * 1024 * 1024);
    defer allocator.free(plan);

    const marker = "test \"P3-e4d-1 actual metadata events stay isolated and reattach starts current\"";
    const start = std.mem.indexOf(u8, runtime, marker) orelse return error.MissingProductGate;
    const tail = runtime[start + marker.len ..];
    const end = std.mem.indexOf(u8, tail, "\ntest \"") orelse tail.len;
    const body = tail[0..end];

    try std.testing.expectEqual(@as(usize, 1), count(runtime, marker));
    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-metadata-reattach-parity"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "P3-e4d-1 actual metadata events stay isolated"));
    try std.testing.expectEqual(@as(usize, 1), count(ssot, "P3-e4d-1은 multi-runtime event 격리"));
    try std.testing.expectEqual(@as(usize, 1), count(matrix, "P3-e4d-1 metadata isolation·reattach parity"));
    // 하위 parity gate가 모두 닫힌 뒤 상위 스펙 제목만 부분 구현으로 남는 상태 드리프트를 막는다.
    try std.testing.expectEqual(@as(usize, 0), count(ssot, "P3-e4(runtime metadata parity) 🟨 부분 구현"));
    try std.testing.expectEqual(@as(usize, 1), count(ssot, "P3-e4(runtime metadata parity)"));
    try std.testing.expectEqual(@as(usize, 0), count(ssot, "실패 원인 분류(부분 구현)"));
    try std.testing.expectEqual(@as(usize, 0), count(ssot, "실제 제품 process에서 기존 checkpoint file 무변경을\n관측하는 E2E는 남아 있다"));
    try std.testing.expectEqual(@as(usize, 1), count(ssot, "실제 제품 process에서 기존 checkpoint file이\n변하지 않는지는 P4 R2a 제품 E2E가 관측한다"));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "Session host 실행 중 transport reconnect (CR0a~CR6f 완료)"));

    try std.testing.expect(std.mem.indexOf(u8, body, "daemon.runSessionHost") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HostAdapter.initInPlace") != null);
    try std.testing.expectEqual(@as(usize, 2), count(body, ".spawnWithAdapter("));
    try std.testing.expectEqual(@as(usize, 1), count(body, "RemoteRuntime.attachExistingWithAdapter("));
    try std.testing.expect(std.mem.indexOf(u8, body, ".spawn(&client") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "RemoteRuntime.attachExisting(&") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "currentGeneration().observation") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pumpDelta") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "testing_api") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "test_only") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "writeArtifact") == null);
}
