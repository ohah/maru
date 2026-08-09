const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-2 purge-first product drain boundary" {
    const allocator = std.testing.allocator;
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 15), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn drainGenerationObservationEvents("));

    // C3-2 keeps the existing raw Client event owner in the explicitly named legacy drain only.
    const legacy_drain = between(runtime, "fn drainLegacyObservationEvents(", "fn drainGenerationObservationEvents(") orelse
        return error.TestExpectedEqual;
    const generation_drain = between(runtime, "fn drainGenerationObservationEvents(", "fn applyObservationEvent(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(legacy_drain, "takeEventForStream"));
    try std.testing.expectEqual(@as(usize, 1), count(legacy_drain, "releaseEvent"));
    try std.testing.expectEqual(@as(usize, 1), count(legacy_drain, "dropBufferedStream"));
    try std.testing.expectEqual(@as(usize, 0), count(generation_drain, "takeEventForStream"));
    try std.testing.expectEqual(@as(usize, 0), count(generation_drain, "dropBufferedStream"));
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

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
