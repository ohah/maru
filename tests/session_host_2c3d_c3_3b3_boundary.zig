//! C3-3b3 원자적 정산이 단일 방향 권위 그래프를 유지하는지 검증한다.

const std = @import("std");

test "C3-3b3 atomic settlement boundary" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/pending_event_settlement_contract.zig");
    defer allocator.free(contract);
    const event_contract = try readSource(allocator, "src/platform/macos/session_host/generation_event_contract.zig");
    defer allocator.free(event_contract);
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
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "validEventReleasePostContext(post_context, post, completion)"));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(registry, "@import(\"runtime_lifetime_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(pending, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(lifetime, "@import(\"pending_event_settlement.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(settlement, "RemoteRuntime"));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(settlement, "RuntimeObservation"));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(settlement, "EventDrain"));
    try std.testing.expectEqual(@as(usize, 1), countProductCalls(settlement, "forkRejectedSettlementProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "fn forkRejectedSettlementProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "if (!builtin.is_test) unreachable;"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "const ProofLossRunnerChannel = if (builtin.is_test) struct"));
    try std.testing.expectEqual(@as(usize, 0), count(client_slot, "pub fn armEventReleaseProofLossMarkerForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn armEventReleaseProofLossMarker("));
    try std.testing.expectEqual(@as(usize, 8), count(settlement, "hashPristineRecord(&pristine_hasher,"));
    inline for (.{
        .{ "runtime-settlement-lease", 1 },
        .{ "effect-commit-evidence", 1 },
        .{ "event-release-completion", 3 },
        .{ "prepared-effect-permit", 1 },
        .{ "prepared-event-release-permit", 3 },
        .{ "prepared-pending-settlement-permit", 1 },
        .{ "pending-event-release-begun", 3 },
        .{ "settlement-disposition", 1 },
    }) |role| {
        const needle = comptime ", \"" ++ role[0] ++ "\", " ++ std.fmt.comptimePrint("{d}", .{role[1]}) ++ ",";
        try std.testing.expectEqual(@as(usize, 1), count(settlement, needle));
    }
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "pub fn settlePendingEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "const SettlementDeathStage = enum(u8)"));
    try std.testing.expectEqual(@as(usize, 1), count(settlement, "fn writeSettlementDeathMarker("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(runtime_adapter, "settlePendingEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn preflightPendingSettlementTransport("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "test \"C3-3b3 preparation facade 결과는 재귀적으로 pointer-free다\""));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn commitPendingEffectNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn commitPendingReleaseNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(lifetime, "pub fn acquireSettlement("));
    try std.testing.expectEqual(@as(usize, 1), countProductCalls(settlement, "lifetime_owner.acquireSettlement("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(settlement, "settlement_contention"));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn preflightSettlement("));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn armSettlementNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(pending, "pub fn publishSettlementNoFail("));
    try std.testing.expectEqual(
        @as(usize, 1),
        countProductCalls(pending, "!self.settlementArmPreflightValid(permit, binding)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countProductCalls(pending, "!self.pendingSettlementPermitMatches(permit, binding)"),
    );
    try std.testing.expectEqual(@as(usize, 1), countProductCalls(pending, "admitSettlementNoFail("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(settlement, "admitSettlementNoFail("));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostProductCalls(allocator, ".admitSettlementNoFail("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client_slot, "node.cleanup_registry.preflightPreparedEventRelease("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countProductCalls(attachment, "self.transport.finishPendingEventReleaseNoFail("),
    );
    try std.testing.expectEqual(@as(usize, 0), count(transport, "beginEventReleaseNoFail"));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub const testing = if (builtin.is_test) struct"));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn replacePayload(owner: *EventOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn restorePayload(owner: *EventOwner"));
    // Attachment가 호출하는 settlement owner 표면은 이 13개와 정확히 같아야 하며 test-only facade는 포함하지 않는다.
    inline for (.{
        "pendingEventReleaseCallbackActive",
        "preflightPendingEffect",
        "settlementCorrelationDigest",
        "preflightPendingEventReleaseUnderEffect",
        "abortPendingEffectPreAdmissionNoFail",
        "commitPendingEffectNoFail",
        "preparePendingEventReleaseBegunNoFail",
        "tombstonePendingEventOwnerNoFail",
        "beginPendingEventReleaseResourcesNoFail",
        "tombstonePendingEventCorrelationNoFail",
        "markPendingEventMirrorTombstonedNoFail",
        "validatePendingEventReleaseFinal",
        "finishPendingEventReleaseNoFail",
    }) |name| {
        const declaration = comptime "    pub fn " ++ name ++ "(";
        try std.testing.expectEqual(@as(usize, 1), count(transport, declaration));
    }

    const gate_start = std.mem.indexOf(u8, build, "const event_c3_3b3_module") orelse return error.MissingGateStart;
    const gate_end = std.mem.indexOfPos(u8, build, gate_start, "const control_c1_runtime_tests") orelse return error.MissingGateEnd;
    const gate = build[gate_start..gate_end];
    try std.testing.expectEqual(@as(usize, 4), count(gate, ", 6);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=5"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 preparation facade 결과"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 pending payload callback 중 동일 대상"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 begun authority는"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 canonical effect plan은"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 canonical effect executor는"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, "tools/session_host_c3b3_test_runner.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "C3-3b3 proof-loss child"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "addArtifactArg(event_c3_3b3_death_child_tests)"));
}

fn countSessionHostProductCalls(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countProductCalls(source, needle);
    }
    return total;
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
