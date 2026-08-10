//! C3-3b3 source boundary: atomic settlement keeps one directed authority graph.

const std = @import("std");

test "C3-3b3 atomic settlement boundary" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/pending_event_settlement_contract.zig");
    defer allocator.free(contract);
    const settlement = try readSource(allocator, "src/platform/macos/session_host/pending_event_settlement.zig");
    defer allocator.free(settlement);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const client_slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    const registry = try readSource(allocator, "src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer allocator.free(registry);
    const pending = try readSource(allocator, "src/platform/macos/session_host/pending_event_owner.zig");
    defer allocator.free(pending);
    const lifetime = try readSource(allocator, "src/platform/macos/session_host/runtime_lifetime_owner.zig");
    defer allocator.free(lifetime);
    const runtime_adapter = try readSource(allocator, "src/platform/macos/session_host/remote_runtime_pending_event.zig");
    defer allocator.free(runtime_adapter);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 0), count(contract, "@import(\"client_slot.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(contract, "@import(\"attachment_cleanup_registry.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(contract, "@import(\"remote_runtime.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(settlement, "@import(\"client_slot.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(settlement, "@import(\"attachment_cleanup_registry.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "@import(\"generation_attachment.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "@import(\"pending_event_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "@import(\"runtime_lifetime_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "@import(\"pending_event_settlement_contract.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "@import(\"pending_event_settlement_contract.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(lifetime, "@import(\"pending_event_settlement_contract.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(client_slot, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(pending, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(lifetime, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(settlement, "RemoteRuntime"));
    try std.testing.expectEqual(@as(usize, 0), count(settlement, "RuntimeObservation"));
    try std.testing.expectEqual(@as(usize, 0), count(settlement, "EventDrain"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "pub fn settlePendingEvent("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(runtime_adapter, "settlePendingEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn preflightPendingSettlementTransport("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn commitPendingEffectNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn commitPendingReleaseNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(lifetime, "pub fn acquireSettlement("));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn preflightSettlement("));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn armSettlementNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn publishSettlementNoFail("));
    try std.testing.expectEqual(@as(usize, 0), count(transport, "beginEventReleaseNoFail") - 1);

    const gate_start = std.mem.indexOf(u8, build, "const event_c3_3b3_module") orelse return error.MissingGateStart;
    const gate_end = std.mem.indexOfPos(u8, build, gate_start, "const control_c1_runtime_tests") orelse return error.MissingGateEnd;
    const gate = build[gate_start..gate_end];
    try std.testing.expectEqual(@as(usize, 4), count(gate, ", 6);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=3"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn countProductCalls(source: []const u8, needle: []const u8) usize {
    const test_start = std.mem.indexOf(u8, source, "test \"") orelse source.len;
    return count(source[0..test_start], needle);
}
