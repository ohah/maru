const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-1 inline attachment event boundary" {
    const allocator = std.testing.allocator;
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_owner: generation_transport_mod.EventOwner = .{}"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_generation_mirror: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn takeEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn viewEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn releaseEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.reserveEventOwnerInPlace("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.eventReadinessOwned("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".takeEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".releaseEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "dropBufferedStream("));

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 14), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 0), count(facade, "    pub fn purgeEndedStream("));
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
