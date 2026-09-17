//! LSP base protocol 의 프레임(docs/editor-surface-tooling.md §8.2a) — `Content-Length: N\r\n\r\n<body>`.
//!
//! **control-plane ndjson 과 갈라 둔다**(§8.2 「Content-Length framing 을 분리한 transport」): 한 줄 = 한 메시지가 아니라 헤더가
//! 길이를 말하고 본문에 개행이 있을 수 있다. 디코더는 **부분 도착**을 받아들인다 — 비차단 fd 에서 읽은 조각이 헤더 중간·본문 중간에서
//! 끊길 수 있고, 반대로 한 번의 read 에 프레임이 여럿 붙어 올 수 있다. 순수 계산이라 여기 산다(할당은 호출자가 준 버퍼).

const std = @import("std");

/// 헤더 이름은 대소문자를 안 가린다(HTTP 관례 — 명세도 그렇다). `Content-Type` 은 무시한다(늘 utf-8 JSON).
const content_length_key = "content-length:";

/// 본문 상한 — 서버가 미친 길이를 보내도 메모리를 다 먹지 않는다(§8.2 「bounded push」). 진단 수천 개도 수백 KB 다.
pub const max_body_len: usize = 16 * 1024 * 1024;

pub const DecodeError = error{
    /// 헤더가 끝났는데 Content-Length 가 없다 — 이 스트림은 못 믿는다(호출자가 서버를 죽인다).
    MissingLength,
    /// 길이가 숫자가 아니거나 상한을 넘는다.
    BadLength,
};

pub const Frame = struct {
    /// 본문(호출자 버퍼 안의 조각 — 다음 `next` 전에 써야 한다).
    body: []const u8,
    /// 이 프레임이 버퍼에서 차지한 바이트(헤더 + 본문). 호출자가 그만큼 버린다.
    consumed: usize,
};

/// 버퍼 앞에서 프레임 하나를 뗀다. 아직 다 안 왔으면 `null`(더 읽어야 한다). 헤더가 다 왔는데 길이가 없거나 틀리면 에러.
pub fn next(buf: []const u8) DecodeError!?Frame {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    var len: ?usize = null;
    var it = std.mem.splitSequence(u8, buf[0..header_end], "\r\n");
    while (it.next()) |line| {
        if (line.len < content_length_key.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..content_length_key.len], content_length_key)) continue;
        const value = std.mem.trim(u8, line[content_length_key.len..], " \t");
        const n = std.fmt.parseInt(usize, value, 10) catch return error.BadLength;
        if (n > max_body_len) return error.BadLength;
        len = n;
    }
    const body_len = len orelse return error.MissingLength;
    const body_start = header_end + 4;
    if (buf.len < body_start + body_len) return null;
    return .{ .body = buf[body_start .. body_start + body_len], .consumed = body_start + body_len };
}

/// 헤더를 쓴다(본문은 호출자가 이어 쓴다). 돌려주는 것은 쓴 길이. `out` 이 모자라면 `null`.
pub fn writeHeader(body_len: usize, out: []u8) ?usize {
    const s = std.fmt.bufPrint(out, "Content-Length: {d}\r\n\r\n", .{body_len}) catch return null;
    return s.len;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LSF1 프레임 하나 — 헤더 대소문자 무시·여분 헤더 무시·본문에 개행이 있어도 길이대로" {
    const raw = "content-LENGTH: 10\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{\"a\":\n 1}\n";
    const f = (try next(raw)).?;
    try testing.expectEqualStrings("{\"a\":\n 1}\n", f.body);
    try testing.expectEqual(raw.len, f.consumed);
}

test "LSF2 부분 도착 — 헤더 중간·본문 중간이면 null, 두 프레임이 붙으면 하나씩 (§8.2a)" {
    const two = "Content-Length: 2\r\n\r\n{}Content-Length: 3\r\n\r\n[1]";
    try testing.expect((try next(two[0..10])) == null); // 헤더 중간
    try testing.expect((try next(two[0..22])) == null); // 본문 한 byte 모자람
    const a = (try next(two)).?;
    try testing.expectEqualStrings("{}", a.body);
    const b = (try next(two[a.consumed..])).?;
    try testing.expectEqualStrings("[1]", b.body);
    try testing.expectEqual(two.len, a.consumed + b.consumed);
}

test "LSF3 길이가 없거나 틀리거나 상한을 넘으면 에러 — 이 스트림은 못 믿는다" {
    try testing.expectError(error.MissingLength, next("Foo: bar\r\n\r\n{}"));
    try testing.expectError(error.BadLength, next("Content-Length: x\r\n\r\n{}"));
    try testing.expectError(error.BadLength, next("Content-Length: 99999999999\r\n\r\n{}"));
}

test "LSF4 헤더 쓰기 — 디코더가 되읽는다" {
    var buf: [64]u8 = undefined;
    const n = writeHeader(5, &buf).?;
    try testing.expectEqualStrings("Content-Length: 5\r\n\r\n", buf[0..n]);
    @memcpy(buf[n .. n + 5], "hello");
    const f = (try next(buf[0 .. n + 5])).?;
    try testing.expectEqualStrings("hello", f.body);
    var tiny: [4]u8 = undefined;
    try testing.expect(writeHeader(5, &tiny) == null);
}
