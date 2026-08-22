const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C2 release boundary remains leaf-owned and product-unwired" {
    const allocator = std.testing.allocator;
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const quarantine = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_event_quarantine.zig",
    );
    defer allocator.free(quarantine);
    const lease = try readSource(allocator, "src/platform/macos/session_host/connection_lease.zig");
    defer allocator.free(lease);
    const event_contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_event_contract.zig",
    );
    defer allocator.free(event_contract);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    const release_commit = between(
        slot,
        "pub fn commitGenerationEventRelease(",
        "pub fn discardGenerationEventForTest(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));
    inline for (.{
        "pendingEventReleaseCallbackActive",       "preflightPendingEffect",                 "settlementCorrelationDigest",
        "preflightPendingEventReleaseUnderEffect", "abortPendingEffectPreAdmissionNoFail",   "commitPendingEffectNoFail",
        "preparePendingEventReleaseBegunNoFail",   "tombstonePendingEventOwnerNoFail",       "beginPendingEventReleaseResourcesNoFail",
        "tombstonePendingEventCorrelationNoFail",  "markPendingEventMirrorTombstonedNoFail", "validatePendingEventReleaseFinal",
        "finishPendingEventReleaseNoFail",
    }) |name| try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn " ++ name ++ "("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn takeEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn releaseEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn purgeEndedStream("));

    try std.testing.expectEqual(@as(usize, 1), count(facade, "client_slot_mod.prepareGenerationEventRelease("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "generation_event.publishReleasing("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "generation_event.publishTerminal("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "client_slot_mod.commitGenerationEventRelease("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "generation_event.finalizeRelease("));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "generation_event.finalizeTerminal("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn prepareGenerationEventRelease("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn commitGenerationEventRelease("));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "@import(\"generation_event_contract.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(release_commit, "lease_mod.consumeCanonicalPinUnchecked("));
    try expectBefore(
        release_commit,
        ".consumeEventReleaseContinuationNoFail(",
        "allocator.free(owned_payload);",
    );
    try expectBefore(
        release_commit,
        ".consumeEventPinRecoveryPermitNoFail(",
        "lease_mod.consumeCanonicalPinUnchecked(",
    );
    try std.testing.expectEqual(@as(usize, 1), count(lease, "pub fn consumeCanonicalPinUnchecked("));
    try std.testing.expectEqual(@as(usize, 1), count(lease, "pub fn scalarProjectionForValidation("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, ".scalarProjectionForValidation("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "pub fn poisonDuringClientSlotOperationNoFail("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(release_commit, ".poisonDuringClientSlotOperationNoFail("),
    );
    try std.testing.expectEqual(
        // C2 owns the original release suffix and the remaining two proof-loss
        // paths; registered event-take corruption is captured for deferred CR0b publication.
        @as(usize, 3),
        try countSourceReferences(allocator, "poisonDuringClientSlotOperationNoFail("),
    );

    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".transport.takeEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".transport.releaseEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, ".transport.takeEvent("));
    // C3-1 owns the sole product wrapper while C2 still owns the release transaction itself.
    try std.testing.expectEqual(@as(usize, 1), count(attachment, ".transport.releaseEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(client, "generation_event_quarantine"));
    try std.testing.expectEqual(@as(usize, 0), count(client, "releaseGenerationEvent("));

    try std.testing.expectEqual(@as(usize, 1), count(quarantine, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "@import(\"client.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "@import(\"client_slot.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "@import(\"generation_event_contract.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "@import(\"connection_lease.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(quarantine, "pub const capacity = protocol_max_inventory_runtimes;"));
    try std.testing.expectEqual(@as(usize, 1), count(quarantine, "pub const retained_byte_cap = capacity * protocol_max_control_json;"));
}

fn expectBefore(source: []const u8, first: []const u8, second: []const u8) !void {
    const first_index = std.mem.indexOf(u8, source, first) orelse return error.TestExpectedEqual;
    const second_index = std.mem.indexOf(u8, source, second) orelse return error.TestExpectedEqual;
    try std.testing.expect(first_index < second_index);
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

fn countSourceReferences(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var result: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(max_source_bytes));
        defer allocator.free(source);
        result += count(source, needle);
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
