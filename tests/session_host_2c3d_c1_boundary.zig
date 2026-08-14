const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C1 event facade remains closed and product-unwired" {
    const allocator = std.testing.allocator;
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const event_contract = try readSource(allocator, "src/platform/macos/session_host/generation_event_contract.zig");
    defer allocator.free(event_contract);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    // 기존 15개 facade와 C3-3b3의 Attachment-owned settlement 13개만 허용한다.
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

    const owner = between(event_contract, "pub const EventOwner = extern struct", "fn internal(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(owner, "    pub fn view("));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "Client"));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "Allocator"));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "stream_id"));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "receipt"));

    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.takeGenerationEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn takeGenerationEvent("));
    // 제품 pump의 canonical take 하나와 test-only close fixture의 직접 take 셋을 분리해 고정한다.
    const runtime_product = between(runtime, "pub const RemoteRuntime = struct", "pub const testing_api = if (builtin.is_test) struct") orelse
        return error.TestExpectedEqual;
    const runtime_tests = runtime[(std.mem.indexOf(u8, runtime, "pub const testing_api = if (builtin.is_test) struct") orelse
        return error.TestExpectedEqual)..];
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".takeEvent("));
    try std.testing.expectEqual(@as(usize, 3), count(runtime_tests, ".takeEvent("));
    try std.testing.expectEqual(@as(usize, 4), count(runtime, ".takeEvent("));
    const attachment_product = between(
        attachment,
        "pub const GenerationAttachment = struct",
        "fn rawLifecycleValid(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), count(attachment_product, ".transport.takeEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "takeGenerationEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, "takeGenerationEvent("));
    // EventCorrelation, 두 CR0b capture request, registered-operation test seam만 열고,
    // ClientSlot의 event take/release registry 직접 호출은 계속 닫는다.
    try std.testing.expectEqual(@as(usize, 6), count(runtime, "client_slot_mod"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "client_slot_mod.takeGenerationEvent("));

    try std.testing.expectEqual(@as(usize, 1), count(client, "try self.bufferCanonicalEvent(frame)"));
    try std.testing.expectEqual(@as(usize, 0), count(client, "try self.bufferLegacyEventForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "fn bufferLegacyEventForTest("));
    const canonical_ingress = between(
        client,
        "    fn bufferCanonicalEvent(",
        "    fn bufferEventWithAllocator(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(canonical_ingress, "frame.header.major != self.wire_major"));
    try std.testing.expectEqual(@as(usize, 1), count(canonical_ingress, "frame.header.payload_len != frame.payload.len"));
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

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
