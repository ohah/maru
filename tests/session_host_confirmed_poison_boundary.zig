const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-3 confirmed poison boundary" {
    const allocator = std.testing.allocator;
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);
    const client = try readSource(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    const poison = between(facade, "    pub fn poison(", "    fn borrowClient(") orelse
        return error.TestExpectedEqual;
    const confirmed = between(
        slot,
        "pub fn poisonGenerationConnection(",
        "fn reasonProjection(",
    ) orelse return error.TestExpectedEqual;

    // C3-3b3 settlement이 추가한 product owner API 13개를 별도 테스트 facade와 섞지 않고 고정한다.
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(poison, "client_slot_mod.poisonGenerationConnection("),
    );
    try std.testing.expectEqual(@as(usize, 0), count(poison, "borrowClient("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn poisonGenerationConnection("));
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostSources(allocator, "poisonGenerationConnection("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostSources(allocator, "beginConfirmedGenerationPoisonExclusive("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostSources(allocator, "endConfirmedGenerationPoisonExclusive("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostSources(allocator, "markDeferredPoisonForTest("),
    );
    const deferred_test_seam = between(
        client,
        "    pub fn markDeferredPoisonForTest(",
        "    /// ClientSlot-only fail-closed publication",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(deferred_test_seam, "if (!builtin.is_test) return error.ConnectionClosed;"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(client, "poisonConfirmed"));
    try std.testing.expectEqual(@as(usize, 1), count(confirmed, "beginGenerationRequestOwner("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(confirmed, "beginConfirmedGenerationPoisonExclusive("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(confirmed, "endConfirmedGenerationPoisonExclusive("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(confirmed, "enterGenerationAllocatorCallback("));
    try std.testing.expectEqual(@as(usize, 1), count(confirmed, "allocator.free(pending.frame)"));
    try std.testing.expectEqual(@as(usize, 1), count(confirmed, "client.fd = -1"));
    try std.testing.expectEqual(@as(usize, 1), count(confirmed, "c.close(fd)"));
}

fn countSessionHostSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
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
        total += count(source, needle);
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
