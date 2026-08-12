const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "CR3a-2d3 경계는 terminal drain continuation과 RED inventory를 고정한다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/terminal_cleanup_handoff_contract.zig");
    defer allocator.free(contract);
    const red_source = try readSource(allocator, "tests/session_host_2d3_red.zig");
    defer allocator.free(red_source);
    const registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(registry);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainIdentity = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainState = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainCallbackBinding = struct {"));
    try std.testing.expectEqual(@as(usize, 9), count(red_source, "test \"CR3a-2d3 component"));
    try std.testing.expectEqual(@as(usize, 3), count(red_source, "test \"CR3a-2d3 subprocess"));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "pub fn commitTerminalCleanupNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-2d3\""));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
