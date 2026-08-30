//! Session-host kernel cwd parity K1 ownership boundary.

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

test "K1 cwd authority remains the sole paired wire foundation" {
    const allocator = std.testing.allocator;
    const manager = try read(allocator, "src/platform/macos/session_host/runtime_manager.zig", 512 * 1024);
    defer allocator.free(manager);
    const remote_backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 512 * 1024);
    defer allocator.free(remote_backend);
    const plan = try read(allocator, "docs/plans/session-host-kernel-cwd.md", 64 * 1024);
    defer allocator.free(plan);
    const index = try read(allocator, "docs/implementation-plan.md", 256 * 1024);
    defer allocator.free(index);
    const verification = try read(allocator, "docs/verification-matrix.md", 3 * 1024 * 1024);
    defer allocator.free(verification);

    // Later phases may populate the field, but they must keep using K1's paired
    // observation and must not add a GUI-side process cwd syscall.
    try std.testing.expectEqual(@as(usize, 1), count(manager, ".cwd_host = cwd_host,"));
    try std.testing.expectEqual(@as(usize, 1), count(
        remote_backend,
        "fn processCwd(ctx: *anyopaque, handle: RuntimeHandle, out: []u8) ?[]const u8",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        remote_backend,
        "host가 observation에 넣은 paired cwd를 단독 출처로 쓴다",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(index, "plans/session-host-kernel-cwd.md"));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "K1 - authority model과 wire"));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "K2 - host-side kernel sampler"));
    try std.testing.expectEqual(@as(usize, 1), count(
        verification,
        "K1 cwd authority model/wire: 구현, 제품 kernel cwd parity 미완",
    ));
}
