const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "2c3e C2 경계는 열두 제품 RPC family를 typed decoder 경로로만 실행한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);

    const rows = [_]struct {
        start: []const u8,
        end: []const u8,
        constructor: []const u8,
        call: []const u8,
    }{
        .{ .start = "pub fn resize(", .end = "const ResizeDecodeContext", .constructor = "RuntimeRequest.resize(", .call = "self.executeDecodedWithManagedPoison(" },
        .{ .start = "pub fn refreshObservation(", .end = "fn applyObservationResponse(", .constructor = "RuntimeRequest.observation()", .call = "self.callDecoded(" },
        .{ .start = "pub fn selectedText(", .end = "fn applySelectedTextResponse(", .constructor = "RuntimeRequest.selectedText(", .call = "self.callDecoded(" },
        .{ .start = "pub fn linkAt(", .end = "fn applyLinkAtResponse(", .constructor = "RuntimeRequest.linkAt(", .call = "self.callDecoded(" },
        .{ .start = "pub fn clipboardWrite(", .end = "fn applyClipboardWriteResponse(", .constructor = "RuntimeRequest.clipboardWrite()", .call = "self.callDecoded(" },
        .{ .start = "pub fn find(", .end = "fn applyFindResponse(", .constructor = "RuntimeRequest.find(", .call = "self.callDecoded(" },
        .{ .start = "pub fn selectContentAware(", .end = "fn applySelectResponse(", .constructor = "RuntimeRequest.selectOp(", .call = "self.callDecoded(" },
        .{ .start = "pub fn sendCoreCommandBlocking(", .end = "pub fn sendMouseReport(", .constructor = "RuntimeRequest.coreCommand(", .call = "self.callDecoded(" },
        .{ .start = "pub fn sendMouseReport(", .end = "pub fn takeNotification(", .constructor = "RuntimeRequest.reportMouse(", .call = "self.callDecoded(" },
        .{ .start = "pub fn takeNotification(", .end = "fn applyNotificationResponse(", .constructor = "RuntimeRequest.notification()", .call = "self.callDecoded(" },
        .{ .start = "fn terminateBestEffort(", .end = "fn detachBestEffort(", .constructor = "RuntimeRequest.terminate()", .call = "self.callDecodedAfterFlush(" },
        .{ .start = "fn detachBestEffort(", .end = "fn failCloseTeardownFlush(", .constructor = "RuntimeRequest.detach()", .call = "self.callDecodedAfterFlush(" },
    };
    try std.testing.expectEqual(@as(usize, 12), rows.len);
    for (rows) |row| {
        const body = between(runtime, row.start, row.end) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), count(body, row.constructor));
        try std.testing.expectEqual(@as(usize, 1), count(body, row.call));
        try std.testing.expectEqual(@as(usize, 0), count(body, "self.callOrdered("));
        try std.testing.expectEqual(@as(usize, 0), count(body, "self.client.call("));
    }

    const decoded = between(runtime, "fn callDecoded(\n", "fn discardQueuedMutations(") orelse
        return error.TestUnexpectedResult;
    const flush_at = std.mem.indexOf(u8, decoded, "try self.flushQueuedInputBlocking();") orelse
        return error.TestUnexpectedResult;
    const dispatch_at = std.mem.indexOf(u8, decoded, "return self.callDecodedAfterFlush(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(flush_at < dispatch_at);
    try std.testing.expectEqual(@as(usize, 1), count(decoded, "self.attachment.callDecoded("));

    const owner_seam = between(
        attachment,
        "pub fn executeRequestWithDecoderOwned(",
        "pub const testing_api",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(owner_seam, ".transport.prepareRequest(request)"));
    try std.testing.expectEqual(@as(usize, 1), count(owner_seam, "executePreparedRequestWithDecoderOwned("));
    try std.testing.expectEqual(@as(usize, 1), count(owner_seam, ".transport.abortPreparedRequest(receipt)"));

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.callOrdered(encoded.method, encoded.params)"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "self.client.call(\"runtime.terminate\""));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "self.client.call(\"runtime.detach\""));
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
