const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

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
    const build = try build_source.read(allocator);
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
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-2d3"));
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
