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
    const event_contract = try readSource(allocator, "src/platform/macos/session_host/generation_event_contract.zig");
    defer allocator.free(event_contract);

    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_owner: generation_transport_mod.EventOwner = .{}"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_generation_mirror: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn takeEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn viewEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn releaseEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.reserveEventOwnerInPlace("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 2), count(attachment, "generation_transport_mod.eventReadinessOwned("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".takeEvent("));
    // The one legacy in-process drain remains until C3-2; C3-1 adds no generation pump consumer.
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".releaseEvent("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "dropBufferedStream("));

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 14), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 0), count(facade, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub const ProjectedEventTake = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub const EventReadiness = enum"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn eventReadinessOwned("));

    // C3-1 exposes only the reviewed attachment seam. These whole-src counts deliberately include
    // tests so any new raw Client consumer or EventOwner pointer surface requires an explicit
    // boundary update instead of hiding behind a local facade count.
    try std.testing.expectEqual(@as(usize, 13), try countSourceReferences(allocator, "takeEventForStream("));
    try std.testing.expectEqual(@as(usize, 9), try countSourceReferences(allocator, "dropBufferedStream("));
    try std.testing.expectEqual(@as(usize, 23), try countSourceReferences(allocator, ".releaseEvent("));
    try std.testing.expectEqual(@as(usize, 30), try countSourceReferences(allocator, "*EventOwner"));
    try std.testing.expectEqual(@as(usize, 17), try countSourceReferences(allocator, "*const EventOwner"));
    try std.testing.expectEqual(@as(usize, 2), try countSourceReferences(allocator, "takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 3), try countSourceReferences(allocator, "eventReadinessOwned("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn liveGenerationMatches("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn activeGenerationMatches("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn settledForAttachment("));
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
    var walker = try dir.walk(allocator);
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
