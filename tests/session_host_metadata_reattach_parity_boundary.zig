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
