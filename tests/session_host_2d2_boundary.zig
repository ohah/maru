const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "CR3a-2d2 경계는 aggregate terminal handoff와 typed teardown owner를 고정한다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/terminal_cleanup_handoff_contract.zig");
    defer allocator.free(contract);
    const registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(registry);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/remote_attachment.zig");
    defer allocator.free(attachment);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/generation_batch_adapter.zig");
    defer allocator.free(adapter);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const generation = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(generation);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const Identity = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn orderedTokenDigest("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub const TerminalCleanupHandoff = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn preflightTerminalCleanup("));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "pub fn commitTerminalCleanupNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn beginTerminalCleanupPublicationNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn publishTerminalTokenNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "fn terminalCleanupView("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn preflightTerminalCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn tryDeinitWithTerminalCleanup("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(generation, ".terminal_handoff => {"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-2d2\""));
    // 최종 gate는 contract/registry/attachment/slot/product 다섯 owner category를 각각 등록한다.
    try std.testing.expectEqual(@as(usize, 5), count(build, "session_host_2d2_step,"));
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
