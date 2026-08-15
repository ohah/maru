const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-3a1 event authority boundary" {
    const allocator = std.testing.allocator;
    const registry = try readSource(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(registry);
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

    const production = registry[0 .. std.mem.indexOf(u8, registry, "test \"") orelse
        return error.TestExpectedEqual];
    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    const ordinary_reserve = between(
        registry,
        "    pub fn reserveEventGeneration(",
        "    pub fn reserveEventGenerationWithOrdering(",
    ) orelse return error.TestExpectedEqual;
    const scan_oracle = between(
        registry,
        "    pub fn validateConnectionOrderingBlockerCacheForTest(",
        "    fn finishEventOrderingNoFail(",
    ) orelse return error.TestExpectedEqual;

    // C3-3b3 product settlement 5개와 test-only facade 16개를 반영한 net +13 source inventory다.
    // C3-3b3 settlement이 추가한 product owner API 13개를 별도 테스트 facade와 섞지 않고 고정한다.
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub const EventOrderingClass = enum(u8)"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "connection_ordering_blocker_count: usize = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(production, "pub fn reserveEventGenerationWithOrdering("));
    try std.testing.expectEqual(@as(usize, 0), count(production, ".reserveEventGenerationWithOrdering("));
    try std.testing.expectEqual(@as(usize, 0), count(slot, ".reserveEventGeneration("));
    try std.testing.expectEqual(@as(usize, 2), count(slot, ".reserveEventGenerationWithOrdering("));
    try std.testing.expectEqual(@as(usize, 1), count(ordinary_reserve, ".non_revoke_effect,"));
    try std.testing.expectEqual(@as(usize, 1), count(scan_oracle, "if (!builtin.is_test) unreachable;"));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "pub const EventOrderingClass = enum(u8)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "connection_ordering_blocker_count: usize = 0"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "const EventAuthority = struct"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "event_authority: EventAuthority = .{}"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostProductionIdentifiers(
            allocator,
            "reserveEventGenerationWithOrdering",
        ),
    );
    try std.testing.expectEqual(
        // C3-3b3 settlement preflight가 connection ordering blocker를 read-only로 한 번 더 확인한다.
        @as(usize, 5),
        try countSessionHostProductionIdentifiers(allocator, "connectionOrderingBlockerCount"),
    );
    const interleaved: [:0]const u8 =
        \\fn reserveEventGenerationWithOrdering() void {}
        \\test "excluded" { reserveEventGenerationWithOrdering(); }
        \\fn productAfterTest() void { reserveEventGenerationWithOrdering(); }
    ;
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(interleaved, "reserveEventGenerationWithOrdering"),
    );
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

fn countSessionHostProductionIdentifiers(
    allocator: std.mem.Allocator,
    identifier: []const u8,
) !usize {
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
        total += countIdentifierOutsideTopLevelTests(source, identifier);
    }
    return total;
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (test_body_depth == null and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted))
            {
                result += 1;
            },
            else => {},
        }
    }
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
