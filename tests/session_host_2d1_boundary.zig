const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "CR3a-2d1 경계는 generation release 결과와 permit 발행 owner를 고정한다" {
    const allocator = std.testing.allocator;
    const registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(registry);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/remote_attachment.zig");
    defer allocator.free(attachment);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/generation_batch_adapter.zig");
    defer allocator.free(adapter);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub const GenerationReleaseResult = enum(u8) {"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub const PreparedRelease = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub const GenerationReleaseResult = generation_batch_registry.GenerationReleaseResult;"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, ") LeaseError!GenerationReleaseResult = null,"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "return slot.releaseAttachmentBatchResult(token) catch"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn releaseAttachmentBatchResult("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "self.current.batch_registry.prepareRelease(token, &prepared)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "self.current.batch_registry.releaseDecision(&prepared)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "abortPreparedReleaseUnchecked(&prepared)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "beginPreparedReleaseUnchecked(&prepared, &cleanup)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "finishPreparedReleaseUnchecked(&prepared, &cleanup)"));

    const registry_product = between(registry, "pub const Registry = struct {", "test \"CR3a-2b1") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(registry_product, "if (!builtin.is_test) return .completed;"));
    try std.testing.expectEqual(@as(usize, 0), count(registry_product, "testing.armNextRetryable"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-2d1\""));
    try std.testing.expectEqual(@as(usize, 3), count(build, "B3SettlementTest.add(b, session_host_2d1_step"));
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
