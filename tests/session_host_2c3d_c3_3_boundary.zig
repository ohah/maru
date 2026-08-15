const std = @import("std");

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

// ── 경로 구분자 정규화 (호스트 이식) ─────────────────────────────────────────────────────────────
// `std.Io.Dir.Walker`의 `entry.path`는 **호스트 native 구분자**를 쓴다 — Windows에서는 `platform\macos\x.zig`.
// 이 파일의 스캐너들은 그 경로를 `"platform/macos/x.zig"` 같은 **`/` 리터럴과 비교**하므로, 그대로 두면 제외
// 목록과 매칭이 조용히 전부 빗나간다(실측: 제외됐어야 할 파일이 집계에 섞여 boundary 카운트가 부풀었다 —
// 컴파일도 통과하고 macOS CI도 초록인 채로 Windows에서만 틀렸다). 그래서 walker를 감싸 경로를 `/`로 정규화한다.
// POSIX 호스트에서는 native 구분자가 이미 `/`라 `next`가 std walker를 그대로 통과시킨다(무동작·무비용).
const PosixWalker = struct {
    inner: std.Io.Dir.Walker,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn next(self: *PosixWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
        var entry = (try self.inner.next(io)) orelse return null;
        if (std.fs.path.sep == '/') return entry;
        // 잘라내면 "제외 목록에 없는 경로"로 조용히 바뀌어 게이트가 거짓 초록이 된다 — 시끄럽게 실패시킨다.
        if (entry.path.len >= self.path_buf.len) return error.NameTooLong;
        for (entry.path, 0..) |byte, i|
            self.path_buf[i] = if (byte == std.fs.path.sep) '/' else byte;
        self.path_buf[entry.path.len] = 0;
        entry.path = self.path_buf[0..entry.path.len :0];
        return entry;
    }

    fn deinit(self: *PosixWalker) void {
        self.inner.deinit();
    }
};

fn posixWalk(dir: std.Io.Dir, allocator: std.mem.Allocator) !PosixWalker {
    return .{ .inner = try dir.walk(allocator) };
}
