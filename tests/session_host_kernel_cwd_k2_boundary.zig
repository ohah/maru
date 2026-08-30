//! Session-host kernel cwd parity K2 product ownership boundary.

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

test "K2 kernel cwd sampler is host-owned bounded and metadata-visible" {
    const allocator = std.testing.allocator;
    const manager = try read(allocator, "src/platform/macos/session_host/runtime_manager.zig", 512 * 1024);
    defer allocator.free(manager);
    const handoff = try read(allocator, "src/platform/macos/session_host/handoff_inventory.zig", 128 * 1024);
    defer allocator.free(handoff);
    const remote_backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 512 * 1024);
    defer allocator.free(remote_backend);
    const metadata_wire = try read(allocator, "src/platform/macos/session_host/runtime_metadata_wire.zig", 256 * 1024);
    defer allocator.free(metadata_wire);
    const external_pump = try read(allocator, "src/platform/macos/session_host/client_external_pump.zig", 2 * 1024 * 1024);
    defer allocator.free(external_pump);
    const external_intent = try read(allocator, "src/platform/macos/session_host/external_rx_intent.zig", 256 * 1024);
    defer allocator.free(external_intent);
    const plan = try read(allocator, "docs/plans/session-host-kernel-cwd.md", 64 * 1024);
    defer allocator.free(plan);
    const verification = try read(allocator, "docs/verification-matrix.md", 3 * 1024 * 1024);
    defer allocator.free(verification);

    try std.testing.expectEqual(@as(usize, 1), count(manager, "const kernel_cwd_refresh_ns: i128 = 500 * std.time.ns_per_ms;"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "cwd: [posix.PATH_MAX]u8"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "hostname: [posix.HOST_NAME_MAX]u8"));
    const refresh_start = std.mem.indexOf(u8, manager, "fn refreshKernelCwdCache") orelse
        return error.TestUnexpectedResult;
    const refresh_end_relative = std.mem.indexOf(u8, manager[refresh_start..], "fn metadataSource") orelse
        return error.TestUnexpectedResult;
    const refresh = manager[refresh_start .. refresh_start + refresh_end_relative];
    try std.testing.expectEqual(@as(usize, 1), count(refresh, "self.backend_impl.backend().processCwd(handle, &cwd_buffer)"));
    try std.testing.expectEqual(@as(usize, 0), count(refresh, "lockCore"));
    const throttle = std.mem.indexOf(u8, refresh, "if (!force_eligibility_check)") orelse
        return error.TestUnexpectedResult;
    const eligibility = std.mem.indexOf(u8, refresh, "const eligible = try self.kernelCwdEligible(handle);") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(throttle < eligibility);
    try std.testing.expectEqual(@as(usize, 1), count(
        refresh,
        "force_eligibility_check and self.kernel_cwd_cache.contains(handle)",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(manager, "_ = self.kernel_cwd_cache.remove("));
    try std.testing.expectEqual(@as(usize, 1), count(handoff, "\"kernel_cwd_cache\""));
    try std.testing.expectEqual(@as(usize, 1), count(manager, ".cwd_generation = if (kernel_cwd)"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "record.cwd_generation = if (self.kernel_cwd_cache.get(handle))"));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "test \"external metadata footprint charges cwd authority bytes\"",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        external_pump,
        "external_rx_intent.appendBoundOwnerRangesForAggregate(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        external_intent,
        "pub fn appendBoundOwnerRangesForAggregate(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        remote_backend,
        "host가 observation에 넣은 paired cwd를 단독 출처로 쓴다",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(plan, "K2 - host-side kernel sampler (완료)"));
    try std.testing.expectEqual(@as(usize, 1), count(
        verification,
        "K2 host-side kernel cwd sampler: 구현, K3 제품 parity 미완",
    ));
}
