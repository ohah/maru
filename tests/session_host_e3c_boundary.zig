//! P4 E3c GUI client idle-pump product evidence boundary.

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

test "P4 E3c client idle pump owns actual generation-backed scale evidence" {
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 512 * 1024);
    defer allocator.free(backend);
    const runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig", 1200 * 1024);
    defer allocator.free(runtime);
    const slot = try read(allocator, "src/platform/macos/session_host/client_slot.zig", 1400 * 1024);
    defer allocator.free(slot);
    const e2e = try read(allocator, "tests/session_host_client_idle_pump_e2e.zig", 256 * 1024);
    defer allocator.free(e2e);
    const validator = try read(allocator, "tools/perf/session_host_client_idle_pump_validator.zig", 256 * 1024);
    defer allocator.free(validator);

    try std.testing.expectEqual(@as(usize, 1), count(backend, "client_idle_pump_evidence.recordSelectedOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "client_idle_pump_evidence.recordPumpDelta"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "client_idle_pump_evidence.recordTimestampSeal"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "client_idle_pump_evidence.recordRegistryVisit"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "const runtime_counts = [_]u32{ 1, 10, 15, 100 }"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "const idle_frame_count: u32 = 60"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, ".uses_generation_attachment = true"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "expected_selected_owner_count"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "artifact.client_fds_closed"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "artifact.directory_removed"));
}
