const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "CR3a-2d3 경계는 terminal drain continuation과 제품 proof-loss owner를 고정한다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/terminal_cleanup_handoff_contract.zig");
    defer allocator.free(contract);
    const client_slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(registry);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const runner = try readSource(allocator, "tools/session_host_2d3_test_runner.zig");
    defer allocator.free(runner);
    const proof_loss = sliceBetween(
        client_slot,
        "fn terminalDrainProofLoss(comptime message: []const u8) noreturn {",
        "var alias_quarantine_events:",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainIdentity = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainState = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const TerminalDrainCallbackBinding = struct {"));
    try std.testing.expectEqual(@as(usize, 8), count(client_slot, "test \"CR3a-2d3 component"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "CR3a-2d3 component 실제 attachment terminal drain은"));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "test \"CR3a-2d3 subprocess"));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "child는 선택된 stage를 dispatch한다"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "const TerminalDrainCallbackBinding = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn terminalDrainProofLoss(comptime message: []const u8) noreturn {"));
    try std.testing.expectEqual(@as(usize, 1), count(proof_loss, "process_seal_service.fatalIntegrity(.proof_loss);"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn armTerminalDrainProofLoss(fd:"));
    try std.testing.expectEqual(@as(usize, 1), count(runner, "const stage_prefix = \"--maru-2d3-proof-stage=\";"));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "pub fn commitTerminalCleanupNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn tryDeinitWithTerminalCleanup(self: *ClientSlot) DeinitOutcome {"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-2d3\""));
}

fn sliceBetween(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_at = std.mem.indexOf(u8, source, start) orelse return null;
    const rest = source[start_at..];
    const end_at = std.mem.indexOf(u8, rest, end) orelse return null;
    return rest[0..end_at];
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
