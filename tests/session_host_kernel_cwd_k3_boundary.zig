//! Session-host kernel cwd K3 actual-product parity and consumer-boundary inventory.

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

test "K3 kernel cwd parity uses an actual daemon and canonical AppSession consumers" {
    const allocator = std.testing.allocator;
    const runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig", 2 * 1024 * 1024);
    defer allocator.free(runtime);
    const build = try read(allocator, "build.zig", 1024 * 1024);
    defer allocator.free(build);
    const plan = try read(allocator, "docs/plans/session-host-kernel-cwd.md", 128 * 1024);
    defer allocator.free(plan);
    const matrix = try read(allocator, "docs/verification-matrix.md", 3 * 1024 * 1024);
    defer allocator.free(matrix);
    const cwd_axis = try read(allocator, "tests/boundary/cwd_axis.zig", 128 * 1024);
    defer allocator.free(cwd_axis);

    const marker = "test \"K3 actual daemon kernel cwd survives detach and preserves authority isolation\"";
    const start = std.mem.indexOf(u8, runtime, marker) orelse return error.MissingProductGate;
    const tail = runtime[start + marker.len ..];
    const end = std.mem.indexOf(u8, tail, "\ntest \"") orelse tail.len;
    const body = tail[0..end];

    try std.testing.expectEqual(@as(usize, 1), count(runtime, marker));
    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-kernel-cwd-k3"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "K3 actual daemon kernel cwd survives detach"));
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "session_host_kernel_cwd_k3_step.dependOn(session_host_legacy_metadata_consumers_step);",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "session_host_kernel_cwd_k3_step.dependOn(&run_cwd_axis_boundary_tests.step);",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "session_host_step.dependOn(session_host_kernel_cwd_k3_step);",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "K3 - 제품 parity gate (완료)"));
    try std.testing.expectEqual(@as(usize, 1), count(matrix, "K3 actual daemon kernel cwd parity: 구현"));

    try std.testing.expect(std.mem.indexOf(u8, body, "daemon.runSessionHost") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HostAdapter.initInPlace") != null);
    try std.testing.expectEqual(@as(usize, 2), count(body, ".spawnWithAdapter("));
    try std.testing.expectEqual(@as(usize, 1), count(body, "RemoteRuntime.attachExistingWithAdapter("));
    try std.testing.expect(std.mem.indexOf(u8, body, ".shell_integration = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pumpDelta") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "testing_api") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "test_only") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "writeArtifact") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "currentGeneration().observation") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "cwd_host.items") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ssh_remote_dest_present") != null);

    try std.testing.expectEqual(@as(usize, 1), count(cwd_axis, ".fns = &.{ \"termCwd\", \"termCwdForDisplay\" }"));
}
