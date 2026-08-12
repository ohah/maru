const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "2c3e C3 경계는 RX-first와 decoder cadence의 유일한 제품 owner를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);

    try std.testing.expectEqual(@as(usize, 12), count(runtime, "test \"2c3e C3 socket cadence는"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".legacy => |client| try client.ingestReadableOutOfBandEvidence(),"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".generation => |adapter| try adapter.ingestRuntimeReadableEvidence(),"));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn ingestReadableOutOfBandEvidence("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "RuntimeAttachment.preDecodeBufferedEvents(&self.attachment)"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "executePreparedRequestWithDecoderOwned("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.executeGenerationRpcDecoded(.{"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "C3CadenceNotImplemented"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".generation => |*value| client.call("));
    const owner_seam = between(
        attachment,
        "pub fn executeRequestWithDecoderOwned(",
        "fn rawLifecycleValid(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), count(owner_seam, "logicalClient()"));
    try std.testing.expectEqual(@as(usize, 0), count(owner_seam, "client_mod.Client"));

    const ordered = between(
        runtime,
        "fn callDecoded(\n        self: *RemoteRuntime,",
        "fn callDecodedAfterFlush(",
    ) orelse
        return error.TestUnexpectedResult;
    const rx = std.mem.indexOf(u8, ordered, "ingestReadableOutOfBandEvidence") orelse
        return error.TestUnexpectedResult;
    const settle = std.mem.indexOf(u8, ordered, "preDecodeBufferedEvents") orelse
        return error.TestUnexpectedResult;
    const tx = std.mem.indexOf(u8, ordered, "flushQueuedInputBlocking") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(rx < settle and settle < tx);
}

fn between(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return null;
    return tail[0..end];
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
