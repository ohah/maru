//! 폰이 컨트롤 플레인 wire 를 **프레임으로 읽는 자리**(S10d-1).
//!
//! 중계(`maru control --stdio`)는 바이트를 그대로 흘린다 — 줄을 세지도, `hello` 를 보지도
//! 않는다([컨트롤 플레인 §4a](../../../docs/control-plane.md)). **조립하는 곳은 여기 하나**이고,
//! 그래야 상한과 배압 규칙이 두 벌로 갈리지 않는다.
//!
//! **OS 를 안 부른다.** 시계도 소켓도 없다 — 시한은 host 가 재고(`timedOut`), 바이트는 host 가
//! 밀어 넣는다. 그래야 이 판정을 기기 없이 전부 테스트할 수 있다.
//!
//! **`hello` 앞에 잡음이 올 수 있다.** `exec` 은 사용자 셸을 거쳐 돌기 때문에 초기화 스크립트가
//! 낸 출력이 stdout 앞에 섞일 수 있고(RFC 4254 §6.5 가 그 부류를 경고한다), 그래서 "첫 줄이
//! `hello` 가 아니면 실패" 로 다루면 `~/.zshenv` 한 줄에 정상 서버가 못 붙는다. 찾을 때까지
//! 줄을 버리되 **버리는 양에 상한**을 둔다.

const std = @import("std");

/// 한 프레임(한 줄)의 상한. 서버 wire 는 ≈1MiB 를 허용하지만(프로토콜 §4.3) **폰은 그만큼 들지
/// 않는다** — 큰 답은 chunk notification 으로 나뉘어 오도록 프로토콜이 정해 두었고, 세션 목록
/// 한 줄은 수 KB 다. 넘으면 그 줄을 버리고 이유를 남긴다(조용히 자르면 JSON 이 깨진 채 파서로 간다).
pub const max_frame = 64 * 1024;

/// `hello` 를 찾기 전에 버릴 수 있는 총량(계약 §4a — 2026-08-20 확정). 셸 초기화가 내는 잡음은
/// 몇 줄이고, 프레임 상한을 다 쓰게 두면 아무 프로그램의 출력이나 그만큼 받아 주는 셈이 된다.
pub const max_noise = 64 * 1024;

/// 우리가 아는 프로토콜 이름. 다르면 축을 끈다 — 모르는 프로토콜을 "아마 맞겠지" 로 읽지 않는다.
pub const protocol_id = "maru.control.v1";

/// 컨트롤 축이 어디까지 왔나.
pub const State = enum {
    /// 아직 아무것도 안 왔다 — `hello` 를 기다린다.
    waiting_hello,
    /// `hello` 를 받았고 그 안을 읽었다. 이제 요청을 보낼 수 있다.
    ready,
    /// 축을 껐다. **터미널과 무관하다** — 이 축만 접는다.
    off,
};

/// 왜 껐나. **하나로 뭉치면 화면이 사용자에게 할 말을 못 고른다.**
pub const OffReason = enum {
    none,
    /// 시한 안에 `hello` 가 안 왔다(강제 명령 서버이거나 `maru` 가 없다).
    hello_timeout,
    /// 잡음이 상한을 넘었다 — `hello` 가 올 자리가 아니다.
    too_much_noise,
    /// `hello` 는 왔는데 프로토콜이 우리 것이 아니다.
    protocol_mismatch,
    /// 한 줄이 상한을 넘었다.
    frame_too_large,
};

/// `feed` 한 걸음의 결과.
pub const Step = struct {
    /// 이번에 완성된 프레임(줄) 하나. `hello` 는 여기 안 실린다 — 그것은 이 층이 소비한다.
    frame: ?[]const u8 = null,
    state: State,
    /// 상태가 `off` 면 그 이유.
    off_reason: OffReason = .none,
};

pub const Client = struct {
    state: State = .waiting_hello,
    off_reason: OffReason = .none,

    /// 조립 중인 줄.
    line: [max_frame]u8 = undefined,
    line_len: usize = 0,
    /// 이 줄이 상한을 넘었나. **넘은 줄은 통째로 버린다** — 앞부분만 파서에 주면 JSON 이 깨진
    /// 채로 간다.
    line_overflow: bool = false,
    /// `hello` 전에 버린 바이트.
    noise: usize = 0,

    /// 서버가 말한 버전(진단용). `hello` 를 읽은 뒤에만 뜻이 있다.
    server_version: [64]u8 = @splat(0),
    server_version_len: usize = 0,
    /// 서버가 광고한 메서드 이름들. **없는 메서드는 부르지 않는다**(계약 §4a — 불러 놓고 오류를
    /// 보여 주는 것과 다르다). 이름을 통째로 들지 않고 **줄 원문을 그대로** 두고 찾는다:
    /// 폰에서 목록을 복사해 들 이유가 없고, 개수 상한을 또 정하게 된다.
    caps: [max_frame]u8 = undefined,
    caps_len: usize = 0,

    /// 요청 id. **0 은 안 쓴다** — 응답을 못 맞춘 자리와 구별한다.
    next_id: u64 = 1,

    /// host 가 시한을 넘겼다고 알린다. **시계는 이 층에 없다.**
    pub fn timedOut(self: *Client) void {
        if (self.state != .waiting_hello) return;
        self.state = .off;
        self.off_reason = .hello_timeout;
    }

    /// 바이트를 밀어 넣는다. **한 걸음에 프레임 하나**를 돌려주므로, 호출자는 `consumed` 만큼
    /// 앞으로 밀고 다시 부른다(줄이 여러 개 담긴 조각을 잃지 않는다).
    pub fn feed(self: *Client, bytes: []const u8, consumed: *usize) Step {
        consumed.* = 0;
        if (self.state == .off) {
            consumed.* = bytes.len; // 껐어도 삼킨다 — 안 삼키면 호출자가 영원히 맴돈다
            return .{ .state = .off, .off_reason = self.off_reason };
        }

        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            i += 1;
            if (b != '\n') {
                if (self.line_len == self.line.len) {
                    self.line_overflow = true;
                } else {
                    self.line[self.line_len] = b;
                    self.line_len += 1;
                }
                continue;
            }

            // 줄 하나가 끝났다.
            const overflow = self.line_overflow;
            const line = self.line[0..self.line_len];
            defer {
                self.line_len = 0;
                self.line_overflow = false;
            }
            consumed.* = i;

            if (overflow) {
                self.state = .off;
                self.off_reason = .frame_too_large;
                return .{ .state = .off, .off_reason = .frame_too_large };
            }

            if (self.state == .waiting_hello) {
                if (isHello(line)) {
                    return self.acceptHello(line);
                }
                // 잡음이다 — 버리되 세어 둔다.
                self.noise += line.len + 1;
                if (self.noise > max_noise) {
                    self.state = .off;
                    self.off_reason = .too_much_noise;
                    return .{ .state = .off, .off_reason = .too_much_noise };
                }
                return .{ .state = .waiting_hello };
            }

            // 빈 줄은 프레임이 아니다(서버가 개행을 두 번 내면 그렇게 보인다).
            if (line.len == 0) return .{ .state = self.state };
            return .{ .frame = line, .state = self.state };
        }

        consumed.* = i;
        return .{ .state = self.state, .off_reason = self.off_reason };
    }

    fn acceptHello(self: *Client, line: []const u8) Step {
        if (jsonStringField(line, "protocol")) |p| {
            if (!std.mem.eql(u8, p, protocol_id)) {
                self.state = .off;
                self.off_reason = .protocol_mismatch;
                return .{ .state = .off, .off_reason = .protocol_mismatch };
            }
        } else {
            // 프로토콜 이름이 없는 `hello` 는 우리 것이 아니다.
            self.state = .off;
            self.off_reason = .protocol_mismatch;
            return .{ .state = .off, .off_reason = .protocol_mismatch };
        }

        if (jsonStringField(line, "server_version")) |v| {
            const n = @min(v.len, self.server_version.len - 1);
            @memcpy(self.server_version[0..n], v[0..n]);
            self.server_version[n] = 0;
            self.server_version_len = n;
        }
        // capabilities 는 원문을 그대로 둔다(아래 `supports` 가 그 안에서 찾는다).
        const n = @min(line.len, self.caps.len);
        @memcpy(self.caps[0..n], line[0..n]);
        self.caps_len = n;

        self.state = .ready;
        return .{ .state = .ready };
    }

    /// 서버가 그 메서드를 광고했나. **없으면 부르지 않는다**(계약 §4a).
    pub fn supports(self: *const Client, method: []const u8) bool {
        if (self.state != .ready) return false;
        const caps = self.caps[0..self.caps_len];
        const at = std.mem.indexOf(u8, caps, "\"capabilities\"") orelse return false;
        // **따옴표째 찾는다** — `sessions.list` 를 찾을 때 `sessions.listAll` 이 걸리면 안 된다.
        var needle: [128]u8 = undefined;
        if (method.len + 2 > needle.len) return false;
        needle[0] = '"';
        @memcpy(needle[1 .. 1 + method.len], method);
        needle[1 + method.len] = '"';
        return std.mem.indexOf(u8, caps[at..], needle[0 .. method.len + 2]) != null;
    }

    pub fn serverVersion(self: *const Client) []const u8 {
        return self.server_version[0..self.server_version_len];
    }

    /// 요청 한 줄을 만든다. **개행까지 붙여 준다** — 붙이는 자리를 호출자에 맡기면 잊는다.
    pub fn writeRequest(self: *Client, out: []u8, method: []const u8, params_json: ?[]const u8) error{ ShortBuffer, NotReady }![]const u8 {
        if (self.state != .ready) return error.NotReady;
        var w = std.Io.Writer.fixed(out);
        const id = self.next_id;
        if (params_json) |p| {
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, p }) catch return error.ShortBuffer;
        } else {
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}\n", .{ id, method }) catch return error.ShortBuffer;
        }
        self.next_id += 1;
        return w.buffered();
    }
};

/// 이 줄이 `hello` notification 인가. **id 가 없는 notification 이어야 한다** — 같은 이름의
/// 응답을 `hello` 로 오해하면 그 뒤 판정이 전부 어긋난다.
fn isHello(line: []const u8) bool {
    if (jsonStringField(line, "method")) |m| return std.mem.eql(u8, m, "hello");
    return false;
}

/// 아주 작은 JSON 문자열 필드 읽기. **전체 파서를 안 쓴다** — 이 층이 보는 것은 `hello` 한 줄의
/// 몇 필드뿐이고, 그 한 줄 때문에 할당자를 들이면 브리지가 실패할 자리가 는다. 프레임 본문은
/// 화면 쪽이 제대로 파싱한다.
pub fn jsonStringField(line: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 3 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    key_buf[2 + name.len] = ':';
    const key = key_buf[0 .. name.len + 3];

    var at = std.mem.indexOf(u8, line, key) orelse return null;
    at += key.len;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    if (at >= line.len or line[at] != '"') return null;
    at += 1;
    const start = at;
    while (at < line.len) : (at += 1) {
        if (line[at] == '\\') {
            at += 1; // 이스케이프 다음 글자는 값이다
            continue;
        }
        if (line[at] == '"') return line[start..at];
    }
    return null;
}

const testing = std.testing;

const hello_line = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v1\",\"server_version\":\"0.1.0\",\"capabilities\":[\"sessions.list\",\"session.capture\"]}}\n";

/// 한 조각을 다 먹을 때까지 밀어 넣고, 마지막 걸음을 돌려준다.
fn feedAll(c: *Client, bytes: []const u8) Step {
    var off: usize = 0;
    var last: Step = .{ .state = c.state };
    while (off < bytes.len) {
        var consumed: usize = 0;
        last = c.feed(bytes[off..], &consumed);
        if (consumed == 0) break;
        off += consumed;
    }
    return last;
}

test "hello 를 받으면 축이 선다" {
    var c: Client = .{};
    try testing.expectEqual(State.waiting_hello, c.state);
    const step = feedAll(&c, hello_line);
    try testing.expectEqual(State.ready, step.state);
    try testing.expectEqualStrings("0.1.0", c.serverVersion());
    // **hello 는 프레임으로 안 올린다** — 이 층이 소비한다.
    try testing.expectEqual(@as(?[]const u8, null), step.frame);
}

test "hello 앞의 잡음은 버린다 — 첫 줄로 판정하지 않는다" {
    // `exec` 은 사용자 셸을 거쳐 돌기 때문에 `~/.zshenv` 같은 것이 앞에 낀다(RFC 4254 §6.5).
    // 첫 줄로 판정하면 그 한 줄에 정상 서버가 못 붙는다.
    var c: Client = .{};
    _ = feedAll(&c, "nvm: loaded\n");
    _ = feedAll(&c, "some warning from .zshenv\n");
    try testing.expectEqual(State.waiting_hello, c.state);
    const step = feedAll(&c, hello_line);
    try testing.expectEqual(State.ready, step.state);
}

test "잡음이 상한을 넘으면 축을 끈다" {
    // 상한이 없으면 아무 프로그램의 출력이나 계속 받아 주는 셈이 된다.
    var c: Client = .{};
    var noise: [1024]u8 = @splat('x');
    noise[noise.len - 1] = '\n';
    var sent: usize = 0;
    while (sent <= max_noise) : (sent += noise.len) {
        const step = feedAll(&c, &noise);
        if (step.state == .off) {
            try testing.expectEqual(OffReason.too_much_noise, step.off_reason);
            return;
        }
    }
    return error.TestExpectedOff;
}

test "프레임이 상한을 넘으면 그 줄을 통째로 버리고 끈다" {
    // 앞부분만 파서에 주면 **JSON 이 깨진 채로** 간다 — 그 실패는 원인을 짚기 어렵다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var big: [max_frame + 16]u8 = @splat('a');
    big[big.len - 1] = '\n';
    const step = feedAll(&c, &big);
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.frame_too_large, step.off_reason);
}

test "hello 뒤의 줄은 프레임으로 올라온다 — 조각으로 와도" {
    // 패킷 경계는 줄 경계가 아니다(계약 §4a). 조각으로 와도 한 줄로 모여야 한다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    _ = feedAll(&c, "{\"jsonrpc\":\"2.0\",\"id\":1,\"resu");
    const step = feedAll(&c, "lt\":{\"sessions\":[]}}\n");
    try testing.expect(step.frame != null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessions\":[]}}", step.frame.?);
}

test "한 조각에 줄이 여럿이면 하나씩 준다 — 잃지 않는다" {
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    const two = "{\"a\":1}\n{\"b\":2}\n";
    var off: usize = 0;
    var consumed: usize = 0;
    const first = c.feed(two[off..], &consumed);
    off += consumed;
    try testing.expectEqualStrings("{\"a\":1}", first.frame.?);
    const second = c.feed(two[off..], &consumed);
    off += consumed;
    try testing.expectEqualStrings("{\"b\":2}", second.frame.?);
    try testing.expectEqual(two.len, off);
}

test "프로토콜이 다르면 축을 끈다" {
    // 모르는 프로토콜을 "아마 맞겠지" 로 읽으면 그 뒤 판정이 전부 어긋난다.
    var c: Client = .{};
    const other = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v2\"}}\n";
    const step = feedAll(&c, other);
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.protocol_mismatch, step.off_reason);
}

test "프로토콜 이름이 없는 hello 도 우리 것이 아니다" {
    var c: Client = .{};
    const step = feedAll(&c, "{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}\n");
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.protocol_mismatch, step.off_reason);
}

test "시한을 넘기면 host 가 껐다고 말할 수 있다" {
    // **시계는 이 층에 없다.** 강제 명령 서버는 무언가를 출력하며 오래 살 수도 있어, 시한이
    // 없으면 영영 안 끝난다(계약 §4a — 5초).
    var c: Client = .{};
    c.timedOut();
    try testing.expectEqual(State.off, c.state);
    try testing.expectEqual(OffReason.hello_timeout, c.off_reason);
    // 이미 선 축은 시한으로 안 꺼진다.
    var ready: Client = .{};
    _ = feedAll(&ready, hello_line);
    ready.timedOut();
    try testing.expectEqual(State.ready, ready.state);
}

test "광고 안 한 메서드는 안 부른다" {
    // 불러 놓고 `method-not-found` 를 오류로 보여 주는 것과 다르다 — 화면에서 그 기능을 지운다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    try testing.expect(c.supports("sessions.list"));
    try testing.expect(c.supports("session.capture"));
    try testing.expect(!c.supports("browser.navigate"));
    // **접두가 같은 이름에 안 걸린다.**
    try testing.expect(!c.supports("sessions.li"));
    try testing.expect(!c.supports("sessions"));
}

test "축이 서기 전에는 요청을 못 만든다" {
    var c: Client = .{};
    var out: [256]u8 = undefined;
    try testing.expectError(error.NotReady, c.writeRequest(&out, "sessions.list", null));
}

test "요청은 한 줄이고 id 가 늘어난다" {
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var out: [256]u8 = undefined;
    const first = try c.writeRequest(&out, "sessions.list", null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}\n", first);

    var out2: [256]u8 = undefined;
    const second = try c.writeRequest(&out2, "session.capture", "{\"id\":7}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.capture\",\"params\":{\"id\":7}}\n", second);
}

test "자리가 모자라면 자르지 않고 실패한다" {
    // 잘린 요청은 **다른 요청**이고, 서버는 그것을 파싱 오류로 만난다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.ShortBuffer, c.writeRequest(&tiny, "sessions.list", null));
}

test "끈 뒤에도 바이트를 삼킨다 — 호출자가 안 맴돈다" {
    var c: Client = .{};
    c.timedOut();
    var consumed: usize = 0;
    const step = c.feed("아무 바이트나\n", &consumed);
    try testing.expectEqual(State.off, step.state);
    try testing.expect(consumed > 0);
}

test "필드 읽기는 이스케이프를 넘긴다" {
    // `"cwd":"C:\\path\"quote"` 같은 값에서 끝을 잘못 잡으면 뒤 필드를 통째로 잃는다.
    const line = "{\"a\":\"x\\\"y\",\"b\":\"z\"}";
    try testing.expectEqualStrings("x\\\"y", jsonStringField(line, "a").?);
    try testing.expectEqualStrings("z", jsonStringField(line, "b").?);
    try testing.expectEqual(@as(?[]const u8, null), jsonStringField(line, "c"));
}
