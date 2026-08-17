//! 프로토콜 버전 교환(RFC 4253 §4.2).
//!
//! 양쪽이 `SSH-2.0-<softwareversion>` 한 줄을 주고받는 것으로 시작한다. **그 줄들은 교환
//! 해시에 그대로 들어가므로**(§8) CR/LF 를 뺀 원문을 보관해야 한다 — 여기서 한 글자만 달라도
//! KEX 가 조용히 실패한다.
//!
//! **서버는 버전 앞에 아무 줄이나 보낼 수 있다**(§4.2 — 법적 고지·배너). 첫 줄만 읽고 판단하면
//! 배너 있는 서버에 못 붙는다. `SSH-` 로 시작하는 줄이 나올 때까지 넘긴다.

const std = @import("std");

/// 줄 하나의 상한(RFC 4253 §4.2 — CR·LF 포함 255). **상한이 없으면 배너를 무한히 보내는
/// 서버가 우리 버퍼를 채운다.**
pub const max_line = 255;

/// 버전 줄을 몇 줄까지 기다리나. 명세에 수가 없어 우리가 정한다 — 배너가 이보다 길면
/// 정상적인 sshd 가 아니다.
pub const max_banner_lines = 64;

pub const Error = error{
    /// 줄이 상한을 넘었다(또는 배너가 너무 많다).
    LineTooLong,
    /// `SSH-2.0-` 이 아니다 — SSH-1 서버이거나 SSH 가 아니다.
    UnsupportedProtocol,
    /// 아직 줄이 다 안 왔다. 더 읽어서 다시 부른다.
    Incomplete,
};

/// 우리가 보내는 줄. **`-` 뒤는 소프트웨어 이름**이고 공백이 오면 그 뒤는 주석이다(§4.2).
/// 이름에 공백·마이너스를 넣지 않는다 — 넣으면 파싱하는 쪽이 갈린다.
pub fn clientLine(comptime version: []const u8) []const u8 {
    return "SSH-2.0-maru_" ++ version;
}

pub const Parsed = struct {
    /// CR/LF 를 뺀 서버 버전 줄. **교환 해시에 이 원문이 들어간다.**
    line: []const u8,
    /// 이 줄까지 먹은 바이트 수(배너 포함).
    consumed: usize,
};

/// 버퍼에서 서버 버전 줄을 찾는다. 배너는 넘긴다.
///
/// **CR 은 선택이다.** 명세는 CRLF 를 요구하지만 LF 만 보내는 구현이 있고, OpenSSH 도 그것을
/// 받아 준다 — 우리가 더 깐깐하게 굴 이유가 없다(상호운용이 목적이다).
pub fn parse(buf: []const u8) Error!Parsed {
    var start: usize = 0;
    var lines: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse {
            // 줄이 안 끝났다 — 남은 길이가 이미 상한을 넘었으면 더 기다릴 이유가 없다.
            if (buf.len - start > max_line) return Error.LineTooLong;
            return Error.Incomplete;
        };
        var line = buf[start..nl];
        if (line.len > max_line) return Error.LineTooLong;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.startsWith(u8, line, "SSH-")) {
            // **2.0 만 받는다.** `SSH-1.99-` 는 양쪽을 다 말한다는 뜻이지만 우리는 2.0 만 한다.
            if (!std.mem.startsWith(u8, line, "SSH-2.0-")) return Error.UnsupportedProtocol;
            return .{ .line = line, .consumed = nl + 1 };
        }
        lines += 1;
        if (lines > max_banner_lines) return Error.LineTooLong;
        start = nl + 1;
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

test "CRLF 와 LF 를 둘 다 받는다" {
    const crlf = try parse("SSH-2.0-OpenSSH_9.6\r\n");
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", crlf.line);
    try std.testing.expectEqual(@as(usize, 21), crlf.consumed);

    const lf = try parse("SSH-2.0-OpenSSH_9.6\n");
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", lf.line);
}

test "버전 앞 배너 여러 줄을 넘긴다" {
    // **이게 없으면 배너 있는 서버에 못 붙는다**(§4.2 — 법적 고지를 먼저 보내는 서버가 흔하다).
    const in = "경고: 허가받은 사용자만\r\n두 번째 줄\r\nSSH-2.0-OpenSSH_9.6\r\n";
    const got = try parse(in);
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", got.line);
    try std.testing.expectEqual(in.len, got.consumed);
}

test "줄이 덜 오면 Incomplete 다" {
    try std.testing.expectError(Error.Incomplete, parse("SSH-2.0-Open"));
    try std.testing.expectError(Error.Incomplete, parse("배너 한 줄\r\nSSH-2.0-Open"));
}

test "SSH-1 은 안 받는다" {
    try std.testing.expectError(Error.UnsupportedProtocol, parse("SSH-1.99-OpenSSH\r\n"));
    try std.testing.expectError(Error.UnsupportedProtocol, parse("SSH-1.5-Cisco\r\n"));
}

test "끝없는 배너로 우리를 못 채운다" {
    // 상한이 없으면 서버가 배너만 계속 보내 버퍼를 먹는다.
    var buf: [max_line * 4]u8 = undefined;
    @memset(&buf, 'x');
    try std.testing.expectError(Error.LineTooLong, parse(&buf)); // 줄이 안 끝나는데 상한 초과

    var many: [8 * (max_banner_lines + 2) + 16]u8 = undefined;
    var n: usize = 0;
    for (0..max_banner_lines + 2) |_| {
        @memcpy(many[n..][0..8], "banner\r\n");
        n += 8;
    }
    @memcpy(many[n..][0..11], "SSH-2.0-X\r\n");
    n += 11;
    try std.testing.expectError(Error.LineTooLong, parse(many[0..n]));
}

test "우리 줄은 SSH-2.0- 로 시작하고 공백이 없다" {
    const line = clientLine("0.1.0");
    try std.testing.expect(std.mem.startsWith(u8, line, "SSH-2.0-"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line, ' '));
    try std.testing.expect(line.len <= max_line - 2); // CRLF 자리를 남긴다
}

// **실서버 원문**(2026-08-17, `localhost:22` 캡처). 우리가 만든 문자열로만 테스트하면
// 자기충족이다 — 진짜 서버가 보내는 줄로 한 번 못박는다.
test "실서버(OpenSSH 10.2) 버전 줄" {
    const got = try parse("SSH-2.0-OpenSSH_10.2\r\n");
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_10.2", got.line);
    // **교환 해시에 이 원문이 들어간다** — CR 이 남으면 해시가 서버와 안 맞아 KEX 가 조용히 깨진다.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, got.line, '\r'));
}
