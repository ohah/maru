//! **원격 파일 변경 결과 wire**(RF6a — [계획](../../docs/plans/remote-file-tree.md) §2.3 ⑶).
//!
//! 원격 헬퍼(`maru-remote-watch` 판 4 의 `mv`)가 **내고**, GUI 의 변경 백엔드가 **읽는** 한 벌의
//! 코덱이다. 목록 wire([remote_file_listing.zig](remote_file_listing.zig))와 같은 규율이다 —
//! 양끝이 이 모듈 하나를 쓰고, 반대편을 손으로 미러하지 않는다.
//!
//! ## 왜 결과가 「exit code 하나」가 아닌가
//!
//! 화면이 할 말이 **실패마다 다르기 때문**이다. 「이름이 이미 있다」는 사용자가 다른 이름을 고르면
//! 되고, 「그 사이 다른 것이 들어왔다」는 트리를 다시 읽어야 하며, 「권한 없음」은 저쪽 문제다.
//! exit code 로만 오면 그 셋이 한 덩어리가 되어 §2.5(「못 하면 화면이 말한다」)를 못 지킨다.
//! 그래서 **로컬 실패 분류와 1:1** 인 코드를 싣는다(`file_tree_mutation_backend.Result.Failure`).
//!
//! ## wire v1
//!
//! ```text
//! maru-rfmv 1\n         머리 — 판이 다르면 즉시 거부(구 GUI ↔ 신 헬퍼의 조용한 오독 방지)
//! S <code>\n            결과 코드(아래 Outcome) — 정확히 한 줄, 이것이 꼬리다
//! ! <len> <메시지>\n     진단(선택) — `S` **앞에** 온다. 표시가 아니라 로그용이다
//! ```
//!
//! `S` 를 못 보면 **잘린 것**이다 — 전송이 중간에 끊겨도 「성공」으로 읽지 않는다(목록 wire 의 `X`
//! 와 같은 자리). 그리고 성공(`S 0`)은 **저쪽이 실제로 rename 을 끝냈다는 뜻**이라, 잘림을 성공으로
//! 오독하면 화면이 안 바뀐 파일을 바뀐 것으로 그린다.
//!
//! **여기는 순수 계층이다** — 바이트를 만들고 해석할 뿐, 실행도 전송도 하지 않는다.

const std = @import("std");

pub const wire_version: u32 = 1;
pub const header_line = "maru-rfmv 1";

/// 진단 메시지의 상한(바이트). 넘으면 자른다 — 이 값은 **표시가 아니라 로그**라, 잘려도 뜻이 상하지
/// 않는다(이름과 다르다 — 이름은 자르면 존재하지 않는 항목이 되므로 목록 wire 는 안 자르고 뺀다).
pub const max_message_bytes: usize = 512;

/// 답 하나의 상한. 머리 + 코드 한 줄 + 진단 한 줄이면 충분하다.
pub const max_wire_bytes: usize = 1024;

/// 변경의 결말. **로컬 실패 분류와 1:1** 로 둔다 — 두 갈래가 같은 화면을 쓰므로 뜻이 갈리면 안 된다.
pub const Outcome = enum(u8) {
    /// 저쪽이 실제로 끝냈다.
    ok = 0,
    /// **신원이 달랐다** — 우리가 보던 그 파일이 아니다(§2.3 ⑶ 의 재확인이 걸렀다). 트리를 다시 읽어야
    /// 한다. 로컬의 「사라졌다」와 같은 자리이지만 원인이 달라 코드를 따로 둔다(진단이 남는다).
    stale = 1,
    /// 그 이름이 이미 있다. **비대체 rename** 이 판정한다 — 미리 물어보면 그 사이가 창이다.
    collision = 2,
    /// 원본이 없다.
    not_found = 3,
    /// 권한 없음.
    denied = 4,
    /// 이름이 이름일 수 없다(빈 이름·`/`·NUL 등). 정상 경로로는 안 오지만, 오면 거른다.
    invalid = 5,
    /// 그 밖의 입출력 실패.
    io = 6,
    /// **비대체 rename 을 이 원격에서 못 한다.** 대체(덮어쓰기) rename 으로 조용히 내려가지 않는다 —
    /// 그러면 사용자가 모르는 사이 남의 파일이 사라진다(fail-closed, §2.5).
    unsupported = 7,

    pub fn fromByte(v: u8) ?Outcome {
        return switch (v) {
            0...7 => @enumFromInt(v),
            else => null,
        };
    }
};

// ── 인코더 — 헬퍼가 쓴다(헬퍼는 std 만 임포트하므로 **사본**을 든다. 왕복 게이트가 드리프트를 잡는다)

/// 답 한 벌을 버퍼에 잇는다. 진단은 선택이고 `S` **앞에** 온다.
pub fn appendResult(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, outcome: Outcome, message: ?[]const u8) !void {
    try out.appendSlice(allocator, header_line);
    try out.append(allocator, '\n');
    if (message) |m| {
        const clipped = if (m.len > max_message_bytes) m[0..max_message_bytes] else m;
        var num: [24]u8 = undefined;
        const len_text = std.fmt.bufPrint(&num, "{d}", .{clipped.len}) catch return error.OutOfMemory;
        try out.appendSlice(allocator, "! ");
        try out.appendSlice(allocator, len_text);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, clipped);
        try out.append(allocator, '\n');
    }
    var num2: [8]u8 = undefined;
    const code_text = std.fmt.bufPrint(&num2, "{d}", .{@intFromEnum(outcome)}) catch return error.OutOfMemory;
    try out.appendSlice(allocator, "S ");
    try out.appendSlice(allocator, code_text);
    try out.append(allocator, '\n');
}

// ── 파서 — GUI 백엔드가 쓴다 ────────────────────────────────────────────────────────────────────

pub const ParseError = error{
    /// 머리가 없거나 판이 다르다.
    UnsupportedVersion,
    /// 레코드 형태가 계약과 다르다.
    Malformed,
    /// 모르는 결과 코드 — 새 헬퍼가 낸 값을 옛 GUI 가 「성공」으로 읽으면 안 된다.
    UnknownOutcome,
    /// 진단이 상한을 넘는다고 주장한다 — 원격이 주는 값이므로 믿지 않는다.
    MessageTooLong,
    /// `S` 를 못 봤다 — **잘린 답**이다(성공으로 읽으면 안 바뀐 파일을 바뀐 것으로 그린다).
    Truncated,
    /// `S` 뒤에 바이트가 더 있다 — 답 두 개가 섞였다.
    TrailingData,
};

pub const Parsed = struct {
    outcome: Outcome,
    /// 진단(없으면 빈 슬라이스). **입력 바이트를 빌린다** — 복사하지 않는다.
    message: []const u8 = &.{},
};

/// 완결된 바이트에서 답 하나를 읽는다. 스트리밍이 아니다(전송이 상한까지 읽어 통째로 준다).
pub fn parse(bytes: []const u8) ParseError!Parsed {
    var rest = bytes;
    // 머리.
    const head_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.UnsupportedVersion;
    if (!std.mem.eql(u8, rest[0..head_end], header_line)) return error.UnsupportedVersion;
    rest = rest[head_end + 1 ..];

    var message: []const u8 = &.{};
    var outcome: ?Outcome = null;
    while (rest.len != 0) {
        if (outcome != null) return error.TrailingData; // `S` 가 꼬리다
        switch (rest[0]) {
            '!' => {
                if (message.len != 0) return error.Malformed; // 진단은 한 번뿐이다
                if (rest.len < 2 or rest[1] != ' ') return error.Malformed;
                rest = rest[2..];
                const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.Malformed;
                const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return error.Malformed;
                if (len > max_message_bytes) return error.MessageTooLong;
                rest = rest[sp + 1 ..];
                if (rest.len < len + 1) return error.Truncated;
                message = rest[0..len];
                if (rest[len] != '\n') return error.Malformed; // 길이가 이름 경계를 정한다
                rest = rest[len + 1 ..];
            },
            'S' => {
                if (rest.len < 2 or rest[1] != ' ') return error.Malformed;
                rest = rest[2..];
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.Truncated;
                const code = std.fmt.parseInt(u8, rest[0..nl], 10) catch return error.Malformed;
                outcome = Outcome.fromByte(code) orelse return error.UnknownOutcome;
                rest = rest[nl + 1 ..];
            },
            else => return error.Malformed,
        }
    }
    return .{ .outcome = outcome orelse return error.Truncated, .message = message };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────────────────────

test "RF6a wire: 성공·실패·진단이 왕복한다" {
    const a = std.testing.allocator;
    for ([_]Outcome{ .ok, .stale, .collision, .not_found, .denied, .invalid, .io, .unsupported }) |want| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        try appendResult(&buf, a, want, null);
        const got = try parse(buf.items);
        try std.testing.expectEqual(want, got.outcome);
        try std.testing.expectEqual(@as(usize, 0), got.message.len);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try appendResult(&buf, a, .denied, "Permission denied");
    const got = try parse(buf.items);
    try std.testing.expectEqual(Outcome.denied, got.outcome);
    try std.testing.expectEqualStrings("Permission denied", got.message);
}

test "RF6a wire: 진단에 개행이 들어도 길이가 경계를 정한다" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    // 저쪽 `strerror` 가 개행을 물고 올 수 있다 — 줄 지향인데 내용에 개행이 있어도 안 깨져야 한다.
    try appendResult(&buf, a, .io, "two\nlines");
    const got = try parse(buf.items);
    try std.testing.expectEqual(Outcome.io, got.outcome);
    try std.testing.expectEqualStrings("two\nlines", got.message);
}

test "RF6a wire: 잘린 답을 성공으로 안 읽는다" {
    // **이 판정자가 이 wire 의 존재 이유다.** 전송이 끊긴 답을 「성공」으로 읽으면 안 바뀐 파일을
    // 바뀐 것으로 그린다(목록의 `X` 꼬리와 같은 자리).
    try std.testing.expectError(error.Truncated, parse("maru-rfmv 1\n"));
    try std.testing.expectError(error.Truncated, parse("maru-rfmv 1\nS 0"));
    try std.testing.expectError(error.Truncated, parse("maru-rfmv 1\n! 5 abc"));
}

test "RF6a wire: 판이 다르거나 형태가 어긋나면 거부한다" {
    try std.testing.expectError(error.UnsupportedVersion, parse("maru-rfmv 2\nS 0\n"));
    try std.testing.expectError(error.UnsupportedVersion, parse("S 0\n"));
    try std.testing.expectError(error.UnsupportedVersion, parse(""));
    // 모르는 코드를 성공으로 접지 않는다(새 헬퍼 ↔ 옛 GUI).
    try std.testing.expectError(error.UnknownOutcome, parse("maru-rfmv 1\nS 9\n"));
    try std.testing.expectError(error.Malformed, parse("maru-rfmv 1\nQ\n"));
    try std.testing.expectError(error.Malformed, parse("maru-rfmv 1\nS0\n"));
    // 답 두 개가 섞이면 거부한다.
    try std.testing.expectError(error.TrailingData, parse("maru-rfmv 1\nS 0\nS 0\n"));
    // 진단 두 번도 거부한다.
    try std.testing.expectError(error.Malformed, parse("maru-rfmv 1\n! 1 a\n! 1 b\nS 0\n"));
    // 상한을 넘는다고 주장하는 길이는 안 믿는다.
    try std.testing.expectError(error.MessageTooLong, parse("maru-rfmv 1\n! 99999 x\nS 0\n"));
}
