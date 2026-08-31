//! 원격 스트리머가 보낸 wire 를 **읽는 쪽**([계획](../../docs/plans/remote-agent-state.md) RA5).
//!
//! `maru agent-events --stdio`(RA4)가 `exec` 채널로 흘리는 줄을 받아 `{nonce, 훅 줄}` 로 풀고, 채널이
//! 살아 있는지를 판정한다. **이 파일은 순수하다** — 소켓도 시계도 안 부른다. 바이트와 «지금 몇 ms 인가»
//! 를 받아 상태를 옮길 뿐이다.
//!
//! **프레임 조립과 `hello` 판정이 여기 한 곳에 있다.** 스트리머는 «바이트를 해석하지 않는다» 는 규율을
//! 지키므로(RA4 머리말), 그 판정을 두 곳에 두면 상한과 배압 규칙이 갈린다.

const std = @import("std");
const command = @import("agent_hook_command.zig");
const hook_event = @import("agent_hook_event.zig");

/// 채널이 열렸다고 인정하기까지 기다리는 시간. §4a 가 정한 값을 그대로 쓴다.
pub const hello_deadline_ms: u64 = 5_000;

/// `hello` 를 찾기 전에 삼키는 잡음 상한. 정상 서버도 MOTD·rc 출력을 앞에 붙인다.
pub const hello_noise_max: usize = 64 * 1024;

/// 한 줄의 상한. 넘으면 그 줄을 버린다 — payload 상한(계약 §4.1)보다 넉넉히 잡는다.
pub const max_line_bytes: usize = 128 * 1024;

/// 하트비트가 이 시간 동안 없으면 **죽은 것으로 본다**.
///
/// 종료 코드로는 못 가린다 — 정상 종료가 `0`, 원격의 진짜 실패가 `255` 를 이미 쓰고 **다중화 경합으로도
/// 255 가 난다**(공개 보고). 어느 경우에도 stderr 는 비어 있었다(2026-08-29 실측). 그래서 **침묵을 잰다**.
/// 스트리머 기본 주기(5 초)의 세 배 — 한 번 놓쳐도 죽었다고 하지 않는다.
pub const silence_deadline_ms: u64 = 15_000;

pub const State = enum {
    /// 아직 `hello` 를 못 봤다. 잡음을 삼키는 중이다.
    waiting_hello,
    /// 열렸다. 이벤트를 소비한다.
    open,
    /// 닫혔다. **왜 닫혔는지는 `Closed` 가 말한다** — 조용한 폴백은 금지다(계약 §1.2).
    closed,
};

/// 축이 안 열리거나 죽은 이유. 사용자에게 보이는 문구가 아니라 **진단용 분류**다.
pub const Closed = enum {
    /// 시한 안에 `hello` 가 안 왔다. `ForceCommand`·`command=` 제한 서버가 이 모양이다 — 그런 서버는
    /// 우리 명령을 **갈아치우고 `exit 0` 을 준다**(2026-08-29 실측). 그래서 「성공했는데 hello 가 없다」
    /// 가 유일한 신호다.
    no_hello,
    /// 잡음이 상한을 넘도록 `hello` 가 안 나왔다.
    noise_overflow,
    /// 열려 있었는데 하트비트가 끊겼다.
    silent,
    /// 채널이 끝났다(원격이 종료).
    eof,
};

pub const Frame = union(enum) {
    /// 이 nonce 의 훅 줄. `line` 은 `<provider>\t<payload>` 로 로컬 로그와 **같은 모양**이다.
    event: struct { nonce: []const u8, line: []const u8 },
    /// 하트비트를 봤다(살아 있다).
    heartbeat,
    /// 이 이름의 로그를 여기까지 읽었다([계획](../../docs/plans/remote-agent-state.md) RA5-a).
    ///
    /// **로컬이 기억했다가 재접속 때 `--resume=` 으로 돌려준다.** 원격 파일에 굳히지 않는 이유는
    /// 「앱을 새로 켰다」와 「채널만 죽었다 살아났다」를 갈라야 하기 때문이다 — 앞은 다시 읽어야 배지가
    /// 서고, 뒤는 다시 읽으면 완료 알림이 재생된다. 로컬 기억은 앱과 함께 죽으므로 그 구분이 저절로 선다.
    cursor: struct { name: []const u8, offset: u64 },
    /// 이 줄에서 얻을 것이 없다(잡음·모르는 모양).
    ignored,
};

/// 한 줄을 프레임으로 푼다. **버퍼를 빌려 가리킨다** — 호출자가 다음 줄을 읽기 전에 소비해야 한다.
pub fn parseFrame(line: []const u8) Frame {
    if (line.len == 0 or line.len > max_line_bytes) return .ignored;
    if (std.mem.startsWith(u8, line, "{\"hb\":")) return .heartbeat;
    if (std.mem.startsWith(u8, line, "{\"cur\":")) return parseCursor(line);
    const nonce = jsonStringField(line, "\"nonce\":\"") orelse return .ignored;
    const raw = jsonStringField(line, "\"line\":\"") orelse return .ignored;
    // nonce 를 **다시 검증한다.** 이 값이 «어느 Term 인가» 를 정하므로, 선 위에서 바뀌었을 가능성을
    // 그냥 믿지 않는다(스트리머도 같은 클래스로 걸렀지만 그것은 저쪽 기계의 판정이다).
    // ⚠️ **파일 이름 상한으로 잰다**(`remote_pane_nonce_max` 가 아니다). 스트리머가 선에 싣는 값은
    // `nonceFromFileName` 이 돌려준 **파일 이름**이라 tmux 안에서는 뒤에 `_t<pane>` 이 붙는데, host 소유
    // nonce 는 이미 nonce 상한을 꽉 채운다(`host_<32hex>_<32hex>` = 70). nonce 상한으로 재면 그 프레임을
    // 통째로 버려 **원격 pane 만 tmux 안에서 배지가 안 선다** — 저쪽(`nonceFromFileName`)은 같은 함정을
    // 이미 고쳤는데 이쪽만 남아 있었다. 재현 조건이 좁아 눈으로는 못 찾는 자리다.
    if (nonce.len == 0 or nonce.len > command.remote_log_name_max) return .ignored;
    if (!command.instance_token_class.accepts(nonce)) return .ignored;
    return .{ .event = .{ .nonce = nonce, .line = raw } };
}

/// 커서 프레임을 푼다. **이름을 다시 검증한다** — 이 값이 「어느 로그인가」를 정하므로 선 위에서
/// 바뀌었을 가능성을 그냥 믿지 않는다(`event` 와 같은 규율).
fn parseCursor(line: []const u8) Frame {
    const name = jsonStringField(line, "\"cur\":\"") orelse return .ignored;
    if (name.len == 0 or name.len > command.remote_log_name_max) return .ignored;
    if (!command.instance_token_class.accepts(name)) return .ignored;
    const at_key = "\"at\":";
    const at = std.mem.indexOf(u8, line, at_key) orelse return .ignored;
    var end = at + at_key.len;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
    const digits = line[at + at_key.len .. end];
    if (digits.len == 0) return .ignored;
    const offset = std.fmt.parseInt(u64, digits, 10) catch return .ignored;
    return .{ .cursor = .{ .name = name, .offset = offset } };
}

/// `"<key>":"..."` 의 값 구간을 찾는다(이스케이프를 **풀지 않고** 그대로 돌려준다).
///
/// 값 안의 `\"` 를 종료로 오인하지 않는 것만 지키면 된다 — 실제 언이스케이프는 `unescapeInto` 가 한다.
fn jsonStringField(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    var i = start + key.len;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // 이스케이프된 글자는 종료가 아니다
            continue;
        }
        if (line[i] == '"') return line[start + key.len .. i];
    }
    return null;
}

/// `parseFrame` 이 돌려준 값의 이스케이프를 풀어 담는다. 그 결과가 `agent_hook_event.parseLine` 의 입력이다.
pub fn unescapeInto(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, escaped: []const u8) !void {
    var i: usize = 0;
    while (i < escaped.len) : (i += 1) {
        if (escaped[i] != '\\') {
            try out.append(allocator, escaped[i]);
            continue;
        }
        i += 1;
        if (i >= escaped.len) break;
        switch (escaped[i]) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            '/' => try out.append(allocator, '/'),
            'u' => {
                if (i + 4 >= escaped.len) break;
                const hex = escaped[i + 1 .. i + 5];
                const v = std.fmt.parseInt(u16, hex, 16) catch {
                    i += 4;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(v, &buf) catch {
                    i += 4;
                    continue;
                };
                try out.appendSlice(allocator, buf[0..n]);
                i += 4;
            },
            else => try out.append(allocator, escaped[i]),
        }
    }
}

/// 채널 하나의 수명. **시계를 안 부른다** — 호출자가 `now_ms` 를 준다.
pub const Channel = struct {
    state: State = .waiting_hello,
    closed_reason: ?Closed = null,
    opened_at_ms: u64 = 0,
    last_alive_ms: u64 = 0,
    noise_bytes: usize = 0,

    pub fn init(now_ms: u64) Channel {
        return .{ .opened_at_ms = now_ms, .last_alive_ms = now_ms };
    }

    /// 한 줄을 먹인다. 돌려주는 프레임은 **`open` 일 때만** 의미가 있다.
    pub fn feed(self: *Channel, line: []const u8, now_ms: u64) Frame {
        switch (self.state) {
            .closed => return .ignored,
            .waiting_hello => {
                if (std.mem.startsWith(u8, line, "{\"hello\":\"maru-agent-events\"")) {
                    self.state = .open;
                    self.last_alive_ms = now_ms;
                    return .ignored;
                }
                self.noise_bytes += line.len + 1;
                if (self.noise_bytes > hello_noise_max) self.close(.noise_overflow);
                return .ignored;
            },
            .open => {
                self.last_alive_ms = now_ms;
                return parseFrame(line);
            },
        }
    }

    /// 줄이 안 올 때도 불린다. 시한을 넘겼으면 닫는다.
    pub fn tick(self: *Channel, now_ms: u64) void {
        switch (self.state) {
            .closed => {},
            .waiting_hello => {
                if (now_ms -| self.opened_at_ms >= hello_deadline_ms) self.close(.no_hello);
            },
            .open => {
                if (now_ms -| self.last_alive_ms >= silence_deadline_ms) self.close(.silent);
            },
        }
    }

    pub fn eof(self: *Channel) void {
        if (self.state != .closed) self.close(.eof);
    }

    fn close(self: *Channel, why: Closed) void {
        self.state = .closed;
        if (self.closed_reason == null) self.closed_reason = why;
    }
};

/// 이 줄이 그 Term 의 상태를 어떻게 옮기는가. 소비자가 `agent_hook_event.parseLine` 을 거쳐 얻은
/// 이벤트를 그대로 기존 판정에 넘기면 되므로, 이 층은 **파싱까지만** 한다.
pub fn hookEventFrom(unescaped: []const u8) ?hook_event.Event {
    return hook_event.parseLine(unescaped);
}

const testing = std.testing;

test "hello 를 보기 전에는 잡음을 삼킨다 — 정상 서버도 MOTD 를 앞에 붙인다" {
    var ch = Channel.init(0);
    _ = ch.feed("MOTD: welcome", 10);
    _ = ch.feed("[warn] rc noise", 20);
    try testing.expectEqual(State.waiting_hello, ch.state);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 30);
    try testing.expectEqual(State.open, ch.state);
}

test "hello 가 시한 안에 안 오면 닫는다 — 제한 서버는 exit 0 을 주므로 이것이 유일한 신호다" {
    var ch = Channel.init(0);
    _ = ch.feed("FORCED_ONLY", 100); // ForceCommand 서버가 뱉는 그 모양
    ch.tick(hello_deadline_ms - 1);
    try testing.expectEqual(State.waiting_hello, ch.state);
    ch.tick(hello_deadline_ms);
    try testing.expectEqual(State.closed, ch.state);
    try testing.expectEqual(Closed.no_hello, ch.closed_reason.?);
}

test "잡음이 상한을 넘으면 닫는다" {
    var ch = Channel.init(0);
    var big: [1024]u8 = undefined;
    @memset(&big, 'x');
    var n: usize = 0;
    while (n <= hello_noise_max / big.len + 1) : (n += 1) _ = ch.feed(&big, 1);
    try testing.expectEqual(State.closed, ch.state);
    try testing.expectEqual(Closed.noise_overflow, ch.closed_reason.?);
}

test "열린 뒤 침묵이 이어지면 죽은 것으로 본다 — 종료 코드는 구분력이 없다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    ch.tick(silence_deadline_ms - 1);
    try testing.expectEqual(State.open, ch.state);
    ch.tick(silence_deadline_ms);
    try testing.expectEqual(State.closed, ch.state);
    try testing.expectEqual(Closed.silent, ch.closed_reason.?);
}

test "하트비트가 침묵 시계를 되돌린다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    var t: u64 = 0;
    while (t < silence_deadline_ms * 3) : (t += silence_deadline_ms / 2) {
        try testing.expectEqual(Frame.heartbeat, ch.feed("{\"hb\":1}", t));
        ch.tick(t);
    }
    try testing.expectEqual(State.open, ch.state);
}

test "이벤트 프레임에서 nonce 와 훅 줄을 뽑는다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    const f = ch.feed("{\"nonce\":\"4331_7\",\"line\":\"claude\\t{\\\"hook_event_name\\\":\\\"Stop\\\"}\"}", 1);
    try testing.expectEqualStrings("4331_7", f.event.nonce);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try unescapeInto(&out, testing.allocator, f.event.line);
    try testing.expectEqualStrings("claude\t{\"hook_event_name\":\"Stop\"}", out.items);
    // 그 결과가 기존 파서의 입력이다 — 원격이라고 파서를 나누지 않는다.
    const ev = hookEventFrom(out.items).?;
    try testing.expectEqual(hook_event.Kind.stop, ev.kind);
}

test "선 위에서 바뀐 nonce 는 다시 거른다 — 그 값이 어느 Term 인가를 정한다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    for ([_][]const u8{
        "{\"nonce\":\"../etc\",\"line\":\"claude\\tx\"}",
        "{\"nonce\":\"A\",\"line\":\"claude\\tx\"}",
        "{\"nonce\":\"\",\"line\":\"claude\\tx\"}",
        "{\"nonce\":\"a b\",\"line\":\"claude\\tx\"}",
    }) |bad| {
        try testing.expectEqual(Frame.ignored, ch.feed(bad, 1));
    }
}

test "값 안의 이스케이프된 따옴표를 종료로 오인하지 않는다" {
    const f = parseFrame("{\"nonce\":\"4331_7\",\"line\":\"a\\\"b\\\"c\"}");
    try testing.expectEqualStrings("a\\\"b\\\"c", f.event.line);
}

test "eof 는 닫고 사유를 남긴다 — 조용한 폴백은 금지다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    ch.eof();
    try testing.expectEqual(State.closed, ch.state);
    try testing.expectEqual(Closed.eof, ch.closed_reason.?);
    // 닫힌 뒤에는 아무것도 안 받는다.
    try testing.expectEqual(Frame.ignored, ch.feed("{\"nonce\":\"4331_7\",\"line\":\"x\"}", 1));
}

test "RA4 가 실제로 뱉은 wire 를 그대로 먹는다 — 두 층의 계약을 여기서 잠근다" {
    // 아래 줄들은 `maru agent-events --stdio` 가 **실제로 출력한 바이트**다(2026-08-29).
    // 스트리머 쪽 포맷이 바뀌면 이 테스트가 먼저 깨진다 — 그것이 이 테스트의 목적이다.
    const wire = [_][]const u8{
        "{\"hello\":\"maru-agent-events\",\"v\":1}",
        "{\"nonce\":\"4331_9\",\"line\":\"claude\\t{\\\"hook_event_name\\\":\\\"PermissionRequest\\\",\\\"tool_name\\\":\\\"Bash\\\"}\"}",
        "{\"nonce\":\"4331_7\",\"line\":\"claude\\t{\\\"hook_event_name\\\":\\\"UserPromptSubmit\\\",\\\"prompt\\\":\\\"원격 프롬프트\\\"}\"}",
        "{\"hb\":0}",
        "{\"hb\":1}",
        "{\"nonce\":\"4331_7\",\"line\":\"claude\\t{\\\"hook_event_name\\\":\\\"Stop\\\",\\\"last_assistant_message\\\":\\\"따옴표 \\\\\\\"안\\\\\\\" 과 탭\\\\t까지\\\"}\"}",
        "{\"hb\":2}",
    };
    var ch = Channel.init(0);
    var events: usize = 0;
    var beats: usize = 0;
    var saw_prompt = false;
    var saw_permission = false;
    var saw_stop_with_quotes = false;

    var now: u64 = 0;
    for (wire) |line| {
        now += 100;
        switch (ch.feed(line, now)) {
            .heartbeat => beats += 1,
            .cursor => {}, // 이 판정자는 이어읽기를 안 본다 — RA5-a 전용 test 가 따로 있다
            .event => |e| {
                events += 1;
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(testing.allocator);
                try unescapeInto(&out, testing.allocator, e.line);
                const ev = hookEventFrom(out.items) orelse return error.ParseFailed;
                switch (ev.kind) {
                    .user_prompt_submit => {
                        saw_prompt = true;
                        try testing.expectEqualStrings("4331_7", e.nonce);
                    },
                    .permission_request => {
                        saw_permission = true;
                        try testing.expectEqualStrings("4331_9", e.nonce);
                    },
                    .stop => {
                        saw_stop_with_quotes = true;
                        // 본문이 **원래 바이트로** 복원되어야 한다. payload JSON 안의 이스케이프는
                        // 그대로 남는다(우리는 wire 한 겹만 벗긴다 — payload 는 안 파싱한다).
                        try testing.expect(std.mem.indexOf(u8, out.items, "\\\"안\\\"") != null);
                        // provider 구분자 탭은 진짜 탭으로 살아 있어야 한다.
                        try testing.expect(std.mem.indexOfScalar(u8, out.items, '\t') != null);
                        try testing.expect(std.mem.startsWith(u8, out.items, "claude\t{"));
                    },
                    else => {},
                }
            },
            .ignored => {},
        }
    }
    try testing.expectEqual(State.open, ch.state); // hello 를 봤다
    try testing.expectEqual(@as(usize, 3), events);
    try testing.expectEqual(@as(usize, 3), beats);
    try testing.expect(saw_prompt and saw_permission and saw_stop_with_quotes);
}

test "이벤트 트래픽도 생존 신호다 — 하트비트가 없어도 죽었다고 하지 않는다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    var t: u64 = 0;
    while (t < 60_000) : (t += 5_000) {
        _ = ch.feed("{\"nonce\":\"4331_7\",\"line\":\"claude\\tx\"}", t);
        ch.tick(t);
    }
    try testing.expectEqual(State.open, ch.state);
}

test "닫힌 뒤에는 사유가 안 덮인다 — 첫 사유가 진짜 원인이다" {
    var ch = Channel.init(0);
    ch.tick(hello_deadline_ms); // no_hello
    try testing.expectEqual(Closed.no_hello, ch.closed_reason.?);
    ch.eof();
    ch.tick(1_000_000);
    try testing.expectEqual(Closed.no_hello, ch.closed_reason.?);
}

test "깨진 프레임은 무시하되 채널을 죽이지 않는다 — 한 줄 때문에 축이 닫히면 안 된다" {
    var ch = Channel.init(0);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 0);
    var big: [max_line_bytes + 10]u8 = undefined;
    @memset(&big, 'x');
    try testing.expectEqual(Frame.ignored, ch.feed(&big, 1)); // 상한 초과
    try testing.expectEqual(Frame.ignored, ch.feed("{\"nonce\":\"4331_7\",\"line\":\"unterminated", 2)); // 잘림
    try testing.expectEqual(Frame.ignored, ch.feed("{\"nonce\":\"4331_7\"}", 3)); // line 없음
    try testing.expectEqual(State.open, ch.state);
}

test "시계가 뒤로 가도 죽었다고 하지 않는다 — 포화 뺄셈이 그것을 막는다" {
    var ch = Channel.init(1_000_000);
    _ = ch.feed("{\"hello\":\"maru-agent-events\",\"v\":1}", 1_000_000);
    ch.tick(0);
    try testing.expectEqual(State.open, ch.state);
}

test "parseFrame: tmux 이름(`<nonce>_t<pane>`)을 버리지 않는다" {
    // **저쪽은 고쳤는데 이쪽만 남아 있던 자리.** 스트리머가 싣는 값은 `nonceFromFileName` 이 돌려준
    // **파일 이름**이라 tmux 안에서는 `_t<pane>` 이 붙는다. host 소유 nonce 는 이미 nonce 상한을 꽉
    // 채우므로(`host_<32hex>_<32hex>` = 70), nonce 상한으로 재면 그 프레임이 통째로 버려진다 —
    // 증상은 「원격 pane 만 tmux 안에서 배지가 안 선다」라 재현 조건이 좁다.
    const a = std.testing.allocator;

    // host 소유 nonce 를 상한까지 채우고 tmux 칸을 더한다 = 실제로 선에 실리는 최악 길이.
    var name: std.ArrayListUnmanaged(u8) = .empty;
    defer name.deinit(a);
    try name.appendSlice(a, "host_");
    try name.appendNTimes(a, 'a', 32);
    try name.append(a, '_');
    try name.appendNTimes(a, 'b', 32);
    try std.testing.expectEqual(command.remote_pane_nonce_max, name.items.len);
    try name.appendSlice(a, "_t24"); // tmux 칸

    const line = try std.fmt.allocPrint(a, "{{\"nonce\":\"{s}\",\"line\":\"claude\\t{{}}\"}}", .{name.items});
    defer a.free(line);

    switch (parseFrame(line)) {
        .event => |ev| try std.testing.expectEqualStrings(name.items, ev.nonce),
        else => return error.TestUnexpectedResult, // nonce 상한으로 재면 여기로 떨어진다
    }

    // 대조군: 파일 이름 상한을 **넘으면** 여전히 버린다(검증이 살아 있다는 확인).
    var too_long: std.ArrayListUnmanaged(u8) = .empty;
    defer too_long.deinit(a);
    try too_long.appendNTimes(a, 'a', command.remote_log_name_max + 1);
    const bad = try std.fmt.allocPrint(a, "{{\"nonce\":\"{s}\",\"line\":\"claude\\t{{}}\"}}", .{too_long.items});
    defer a.free(bad);
    try std.testing.expect(parseFrame(bad) == .ignored);
}

test "parseFrame: 커서 프레임을 이름과 위치로 푼다" {
    switch (parseFrame("{\"cur\":\"t24\",\"at\":4096}")) {
        .cursor => |c| {
            try std.testing.expectEqualStrings("t24", c.name);
            try std.testing.expectEqual(@as(u64, 4096), c.offset);
        },
        else => return error.TestUnexpectedResult,
    }

    // 0 은 정당하다 — 「처음부터」를 명시한 값이다.
    switch (parseFrame("{\"cur\":\"t24\",\"at\":0}")) {
        .cursor => |c| try std.testing.expectEqual(@as(u64, 0), c.offset),
        else => return error.TestUnexpectedResult,
    }

    // **성하지 않으면 버린다** — 이 값이 「어느 로그를 어디서부터」를 정하므로 그냥 믿지 않는다.
    try std.testing.expect(parseFrame("{\"cur\":\"t24\"}") == .ignored); // 위치 없음
    try std.testing.expect(parseFrame("{\"cur\":\"\",\"at\":1}") == .ignored); // 이름 없음
    try std.testing.expect(parseFrame("{\"cur\":\"../etc\",\"at\":1}") == .ignored); // 경로를 벗어난다
    try std.testing.expect(parseFrame("{\"cur\":\"t24\",\"at\":x}") == .ignored); // 숫자가 아니다

    // 이벤트·하트비트와 섞이지 않는다(같은 스트림을 나눠 쓴다).
    try std.testing.expect(parseFrame("{\"hb\":7}") == .heartbeat);
}
