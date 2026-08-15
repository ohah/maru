const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-3a2 dormant final admission boundary" {
    const allocator = std.testing.allocator;
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

    try std.testing.expectEqual(@as(usize, 1), count(slot, "const FinalAdmissionTransaction = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransaction("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransactionWithOperation("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn beginRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn endRegisteredOperationExecutionLease("));

    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(slot, "finalAdmissionTransaction"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot, "finalAdmissionTransactionWithOperation"),
    );
    try std.testing.expectEqual(@as(usize, 3), try countSessionHostProductIdentifier(
        allocator,
        "beginRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 4), try countSessionHostProductIdentifier(
        allocator,
        "endRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 2), try countSessionHostProductIdentifier(
        allocator,
        "bufferedControllerRevokeUnderRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub const ClientOperationFence = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "const max_final_admission_protected_ranges = 4;"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "\n    owns_registered_operation_raw: u8 = 0"));
    // Pending event release begun scratch의 닫힌 lifecycle이 세 번째 raw lifecycle owner다.
    try std.testing.expectEqual(@as(usize, 3), count(slot, "lifecycle_raw: u8 = @intFromEnum"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "FinalAdmissionMutex"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "FinalAdmissionGeneration"));
}

fn countSessionHostProductIdentifier(
    allocator: std.mem.Allocator,
    wanted: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var result: usize = 0;
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
        result = try std.math.add(
            usize,
            result,
            countIdentifierOutsideTopLevelTests(source, wanted),
        );
    }
    return result;
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
