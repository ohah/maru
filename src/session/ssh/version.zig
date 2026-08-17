//! 프로토콜 버전 교환(RFC 4253 §4.2).
//!
//! 양쪽이 `SSH-2.0-<softwareversion>` 한 줄을 주고받는 것으로 시작한다. **그 줄들은 교환
//! 해시에 그대로 들어가므로**(§8) CR/LF 를 뺀 원문을 보관해야 한다 — 여기서 한 글자만 달라도
//! KEX 가 조용히 실패한다.
//!
//! **서버는 버전 앞에 아무 줄이나 보낼 수 있다**(§4.2 — 법적 고지·배너). 첫 줄만 읽고 판단하면
//! 배너 있는 서버에 못 붙는다. `SSH-` 로 시작하는 줄이 나올 때까지 넘긴다.

const std = @import("std");

/// **식별 문자열**의 상한(RFC 4253 §4.2 — "The maximum length of the string is 255 characters,
/// **including the Carriage Return and Line Feed**"). 그래서 재는 대상은 CR·LF 를 **뺀** 길이가
/// 아니라 줄 전체다 — 뺀 길이로 재면 256바이트짜리가 통과한다.
pub const max_line = 255;

/// **배너 한 줄**의 상한. §4.2 는 배너 길이를 정하지 않는다("Clients MUST be able to process
/// such lines") — 식별 문자열의 255 를 배너에 그대로 쓰면 한 줄짜리 법적 고지를 보내는 점프
/// 호스트·어플라이언스에 **못 붙는다**. 그래서 상한은 우리가 따로 정한다.
///
/// **L4 에 주는 뜻**: 줄이 안 끝난 채 이만큼 쌓이면 `LineTooLong` 이므로, 읽기 버퍼가 이보다
/// 작으면 정상 배너를 못 담아 영원히 `Incomplete` 를 받는다.
///
/// **4KiB 인 이유**: 아래 `max_banner_lines` 와 곱한 값이 이 층이 버전 교환에 쓰는 **최악 버퍼**다
/// (`consumed` 는 버전 줄을 찾은 뒤에야 나오므로 호출자는 그때까지 배너를 다 들고 있어야 한다).
/// 4KiB × 64 = 256KiB 로 **패킷 상한과 같게** 맞췄다 — 상한을 늘리면 그 곱이 조용히 커져서, 이
/// 층이 SSH 경로에서 가장 큰 버퍼를 요구하게 된다.
pub const max_banner_line = 4 * 1024;

/// 버전 줄을 몇 줄까지 기다리나. 명세에 수가 없어 우리가 정한다 — 배너가 이보다 길면
/// 정상적인 sshd 가 아니다.
pub const max_banner_lines = 64;

/// 버전 교환이 요구하는 **최악 버퍼**. L4 는 읽기 버퍼를 이보다 작게 잡으면 안 된다.
pub const max_exchange_bytes = max_banner_line * max_banner_lines;

pub const Error = error{
    /// 줄이 상한을 넘었다(또는 배너가 너무 많다).
    LineTooLong,
    /// 2.0 을 말하지 않는다 — SSH-1 서버이거나 SSH 가 아니다.
    UnsupportedProtocol,
    /// 버전 줄에 제어문자가 있다(§4.2 — NUL 은 MUST NOT, 나머지는 printable US-ASCII).
    MalformedVersion,
    /// 아직 줄이 다 안 왔다. 더 읽어서 다시 부른다.
    Incomplete,
};

/// 2.0 을 말하는 접두들. **`SSH-1.99-` 도 2.0 이다** — RFC 4253 §5.1 은 "Clients using protocol
/// 2.0 **MUST** be able to identify this as identical to \"2.0\"" 라고 못박는다. 호환 모드로 켜 둔
/// sshd 와 네트워크 장비(Cisco IOS 계열)가 이것을 보내고, 이 줄을 거절하면 **2.0 을 완벽히
/// 말하는 서버에 못 붙는다**.
const v2_prefixes = [_][]const u8{ "SSH-2.0-", "SSH-1.99-" };

/// §4.2 가 금지하는 바이트. NUL 은 명시적 MUST NOT 이고 나머지 C0·DEL 도 printable 이 아니다.
///
/// **이것이 보안 문제인 이유**: 이 줄은 **아직 아무것도 검증되지 않은 상대가 보낸 바이트**인데
/// 계약 §4 는 그것을 TOFU 프롬프트에 서버 신원으로 보여 준다. 그 표시 경로 중 하나라도 VT 파서를
/// 거치면(로그·에코·터미널 셀 본문) 끝이다 — maru 코어는 OSC 0/2(제목)와 OSC 52(클립보드 쓰기)를
/// 실제로 처리한다(`src/terminal/osc.zig`). **표시 경로마다 안전한지 따지는 것보다 입구에서 막는
/// 편이 싸고 확실하다.** 게다가 원문은 교환 해시에 들어가야 해서 **씻어 낼 수도 없다** — 씻으면
/// 해시가 서버와 안 맞는다. 그러니 받지 않는다(OpenSSH 도 같은 자리에서 연결을 끊는다).
/// **0x80 이상은 일부러 통과시킨다.** §4.2 는 US-ASCII 를 요구하지만, 거기까지 거절하면 주석
/// 자리에 UTF-8 을 넣는 장비에 못 붙는다 — 그리고 그 바이트들은 CSI·OSC 를 열지 못해 위 위험과
/// 무관하다. 막는 대상은 **제어문자**다.
fn hasControlChar(line: []const u8) bool {
    for (line) |c| if (c < 0x20 or c == 0x7F) return true;
    return false;
}

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
            // 줄이 안 끝났다 — 남은 길이가 이미 상한을 넘었으면 더 기다릴 이유가 없다. **여기서
            // 재는 것은 배너 상한이다**: 아직 이 줄이 배너인지 식별 문자열인지 모르므로 둘 중
            // 넉넉한 쪽으로 봐야 정상 배너를 안 자른다.
            if (buf.len - start > max_banner_line) return Error.LineTooLong;
            return Error.Incomplete;
        };
        var line = buf[start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.startsWith(u8, line, "SSH-")) {
            // **CR·LF 를 포함해** 잰다(§4.2). `line` 은 둘 다 빠진 값이라 그것으로 재면 하나 넘친다.
            if (nl + 1 - start > max_line) return Error.LineTooLong;
            if (hasControlChar(line)) return Error.MalformedVersion;
            for (v2_prefixes) |p| {
                if (std.mem.startsWith(u8, line, p)) return .{ .line = line, .consumed = nl + 1 };
            }
            return Error.UnsupportedProtocol;
        }
        // 배너는 명세가 길이를 안 정한다 — 우리 상한만 본다(위 `max_banner_line` 주석).
        if (line.len > max_banner_line) return Error.LineTooLong;
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

test "SSH-1 은 안 받지만 1.99 는 2.0 이다" {
    // **§5.1 MUST**: 호환 모드 서버가 보내는 1.99 를 2.0 과 같게 본다. 이것을 거절하면 2.0 을
    // 완벽히 말하는 장비(Cisco IOS 계열·legacy Protocol 설정 sshd)에 못 붙는다.
    const compat = try parse("SSH-1.99-Cisco-1.25\r\n");
    try std.testing.expectEqualStrings("SSH-1.99-Cisco-1.25", compat.line);
    // **원문 그대로 보관한다** — 교환 해시에 들어가는 것은 "2.0 으로 고쳐 쓴 값" 이 아니다.
    try std.testing.expect(std.mem.startsWith(u8, compat.line, "SSH-1.99-"));

    try std.testing.expectError(Error.UnsupportedProtocol, parse("SSH-1.5-Cisco\r\n"));
    try std.testing.expectError(Error.UnsupportedProtocol, parse("SSH-3.0-Future\r\n"));
    // 접두가 **정확히** 맞아야 한다 — `SSH-2.0` 뒤의 `-` 가 없으면 식별 문자열이 아니다.
    try std.testing.expectError(Error.UnsupportedProtocol, parse("SSH-2.01-Weird\r\n"));
}

test "버전 줄의 제어문자를 거절한다" {
    // **이 줄은 사용자에게 그대로 보인다**(TOFU 프롬프트). 거르지 않으면 서버가 OSC 0/52 로
    // 창 제목을 바꾸고 클립보드에 쓴다. 원문이 교환 해시에 들어가 씻어 낼 수 없으므로 받지 않는다.
    try std.testing.expectError(Error.MalformedVersion, parse("SSH-2.0-\x1b]0;pwned\x07\r\n"));
    try std.testing.expectError(Error.MalformedVersion, parse("SSH-2.0-a\x00b\r\n")); // NUL 은 MUST NOT
    try std.testing.expectError(Error.MalformedVersion, parse("SSH-2.0-a\x7Fb\r\n")); // DEL
    try std.testing.expectError(Error.MalformedVersion, parse("SSH-2.0-a\rb\r\n")); // 줄 안의 CR
    try std.testing.expectError(Error.MalformedVersion, parse("SSH-2.0-a\tb\r\n")); // TAB

    // 공백과 주석은 정당하다(§4.2 — SP 뒤는 'comments').
    const ok = try parse("SSH-2.0-OpenSSH_9.6 Ubuntu-3ubuntu13\r\n");
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6 Ubuntu-3ubuntu13", ok.line);

    // **0x80 이상은 일부러 통과시킨다**(위 `hasControlChar` 주석). 주석 자리에 UTF-8 을 넣는
    // 장비가 있고, 그 바이트들은 CSI·OSC 를 못 여니 위 위험과 무관하다 — 여기까지 거절하면
    // 안전해지는 것 없이 못 붙는 서버만 는다.
    const utf8 = try parse("SSH-2.0-Router_1.0 사내망 전용\r\n");
    try std.testing.expectEqualStrings("SSH-2.0-Router_1.0 사내망 전용", utf8.line);
}

test "배너의 제어문자는 거르지 않고 그냥 넘긴다" {
    // **배너는 우리가 안 보여 준다** — 그래서 §4.2 가 말하는 "표시한다면 control character
    // filtering" 이 우리 얘기가 아니다. 여기에 버전 줄과 같은 검사를 씌우면 TAB 으로 칸을 맞춘
    // 흔한 법적 고지에 **못 붙는다**. 얻는 안전은 0 이고 잃는 것은 상호운용이다.
    const got = try parse("경고:\t허가받은 사용자만\r\n\x1b[1m배너\x1b[0m\r\nSSH-2.0-OpenSSH_9.6\r\n");
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", got.line);
}

test "식별 문자열 상한은 CR·LF 를 포함해 센다" {
    // §4.2: "maximum length of the string is 255 characters, **including** the CR and LF".
    // CR·LF 를 뺀 길이로 재면 여기서 256바이트가 통과한다.
    var buf: [300]u8 = undefined;
    const head = "SSH-2.0-";
    @memcpy(buf[0..head.len], head);
    @memset(buf[head.len..300], 'x');

    // 총 256바이트(내용 253 + CR + LF + 1) — 넘는다.
    buf[254] = '\r';
    buf[255] = '\n';
    try std.testing.expectError(Error.LineTooLong, parse(buf[0..256]));

    // 총 255바이트 — 딱 맞으므로 통과한다(경계 바로 아래도 같이 못박는다).
    buf[253] = '\r';
    buf[254] = '\n';
    const ok = try parse(buf[0..255]);
    try std.testing.expectEqual(@as(usize, 253), ok.line.len);
}

test "배너 줄에는 식별 문자열 상한을 안 씌운다" {
    // **§4.2 는 배너 길이를 안 정한다.** 255 를 그대로 씌우면 한 줄짜리 법적 고지를 보내는
    // 서버에 못 붙는다 — 배너 건너뛰기를 만든 이유 자체가 무너진다.
    var buf: [1024]u8 = undefined;
    @memset(buf[0..300], 'B');
    buf[300] = '\r';
    buf[301] = '\n';
    const tail = "SSH-2.0-OpenSSH_9.6\r\n";
    @memcpy(buf[302..][0..tail.len], tail);
    const got = try parse(buf[0 .. 302 + tail.len]);
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", got.line);
}

test "버전 교환의 최악 버퍼는 패킷 상한을 안 넘는다" {
    // **상한 둘의 곱이 계약이다.** 배너 줄 상한만 보고 늘리면 호출자가 들고 있어야 할 최악
    // 버퍼가 조용히 커져, 이 층이 SSH 경로에서 가장 큰 메모리를 요구하게 된다.
    const packet = @import("packet.zig");
    try std.testing.expectEqual(max_exchange_bytes, max_banner_line * max_banner_lines);
    try std.testing.expect(max_exchange_bytes <= packet.max_packet);
}

test "긴 배너가 조각으로 오는 중에는 Incomplete 다" {
    // **미완성 줄에 거는 상한도 배너 기준이어야 한다.** 아직 이 줄이 배너인지 식별 문자열인지
    // 모르는데 255 로 끊으면, 300바이트 법적 고지를 TCP 조각으로 받는 순간 **더 읽어 보지도 않고**
    // 연결이 죽는다. 변이로 확인했다(이 테스트가 없을 때 `max_line` 으로 되돌려도 전부 초록이었다).
    var buf: [400]u8 = undefined;
    @memset(&buf, 'B');
    try std.testing.expectError(Error.Incomplete, parse(buf[0..300]));

    // 그 줄이 끝나고 버전 줄이 오면 정상으로 읽힌다 — 위가 "무조건 Incomplete" 가 아님을 못박는다.
    buf[300] = '\r';
    buf[301] = '\n';
    const tail = "SSH-2.0-OpenSSH_9.6\r\n";
    @memcpy(buf[302..][0..tail.len], tail);
    try std.testing.expectEqualStrings("SSH-2.0-OpenSSH_9.6", (try parse(buf[0 .. 302 + tail.len])).line);
}

test "끝없는 배너로 우리를 못 채운다" {
    // 상한이 없으면 서버가 배너만 계속 보내 버퍼를 먹는다. **줄이 안 끝나는 경우**와
    // **끝난 줄이 너무 긴 경우**를 따로 잰다 — 하나만 재면 나머지 가드를 지워도 안 드러난다.
    var buf: [max_banner_line * 2]u8 = undefined;
    @memset(&buf, 'x');
    try std.testing.expectError(Error.LineTooLong, parse(&buf)); // 줄이 안 끝나는데 상한 초과

    buf[max_banner_line + 1] = '\n'; // 끝났지만 상한을 넘긴 배너 줄
    try std.testing.expectError(Error.LineTooLong, parse(&buf));

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
