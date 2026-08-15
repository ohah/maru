const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "C3-3c 제품 socket과 raw Client source-zero 경계는 검토된 event와 effect owner만 허용한다" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(
            std.testing.io,
            entry.path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        if (!isRawEventOwner(entry.path)) {
            inline for (.{ "takeEventForStream", "releaseEvent", "dropBufferedStream" }) |name| {
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countIdentifierOutsideTopLevelTests(source, name),
                );
            }
        }
        if (!isRawEffectOwner(entry.path)) {
            inline for (.{
                "preflightPendingEffect",
                "commitPendingEffectNoFail",
                "preflightPendingEventReleaseUnderEffect",
            }) |name| {
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countIdentifierOutsideTopLevelTests(source, name),
                );
            }
        }
    }

    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const legacy = sliceBetween(
        runtime,
        "fn drainLegacyObservationEvents(",
        "fn drainGenerationObservationEvents(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(legacy, "takeEventForStream"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(legacy, "releaseEvent"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(legacy, "dropBufferedStream"));
    const generation = sliceBetween(
        runtime,
        "fn drainGenerationObservationEvents(",
        "fn decodeResizeReply(",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{ "takeEventForStream", "releaseEvent", "dropBufferedStream" }) |name| {
        try std.testing.expectEqual(@as(usize, 0), countIdentifier(generation, name));
    }

    const c3c_tests = sliceBetween(
        runtime,
        "test \"C3-3c 열린 peer의 revoked",
        "fn expectActualSocketWireZero(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), count(c3c_tests, "test \"C3-3c 열린 peer의"));
    try std.testing.expectEqual(@as(usize, 3), count(c3c_tests, "writeC3cEventWire("));
    try std.testing.expectEqual(@as(usize, 3), count(c3c_tests, "readStreamBatch(7)"));
    try std.testing.expectEqual(@as(usize, 0), count(c3c_tests, "bufferGenerationEventForTest"));
}

fn isRawEventOwner(path: []const u8) bool {
    return isSessionHostPath(path, "client.zig") or
        isSessionHostPath(path, "client_slot.zig") or
        isSessionHostPath(path, "generation_transport.zig") or
        isSessionHostPath(path, "generation_attachment.zig") or
        isSessionHostPath(path, "remote_runtime.zig");
}

fn isRawEffectOwner(path: []const u8) bool {
    return isSessionHostPath(path, "client_slot.zig") or
        isSessionHostPath(path, "generation_transport.zig") or
        isSessionHostPath(path, "generation_attachment.zig") or
        isSessionHostPath(path, "pending_event_settlement.zig");
}

fn isSessionHostPath(path: []const u8, basename: []const u8) bool {
    const prefix = "platform/macos/session_host/";
    return std.mem.startsWith(u8, path, prefix) and
        std.mem.eql(u8, path[prefix.len..], basename);
}

fn sliceBetween(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return null;
    return tail[0..end];
}

fn countIdentifier(source: []const u8, wanted: []const u8) usize {
    return count(source, wanted);
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
