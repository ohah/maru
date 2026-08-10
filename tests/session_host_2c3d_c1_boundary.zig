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
    // Earlier contracts remain present after C3-2 adds the bounded ended-purge facade.
    try std.testing.expectEqual(@as(usize, 15), count(facade, "    pub fn "));
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
    // C3-1 activates the generation drain beside the retained legacy drain.
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".takeEvent("));
    const attachment_product = between(
        attachment,
        "pub const GenerationAttachment = struct",
        "fn rawLifecycleValid(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), count(attachment_product, ".transport.takeEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "takeGenerationEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, "takeGenerationEvent("));
    // b2b3's dormant final-address orchestration names the canonical EventCorrelation type, but it
    // still cannot call ClientSlot's event take/release registry directly.
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "client_slot_mod"));
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
