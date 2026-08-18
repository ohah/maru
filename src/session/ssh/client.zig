//! **SSH 클라이언트 세션 하나** — 버전 교환부터 셸까지를 잇는 sans-io 상태기계.
//!
//! **왜 이 파일이 있나.** 지금까지 만든 것은 조각이다(패킷·KEX·암호·전송·인증·채널). 그것을
//! 순서대로 엮는 코드가 검증 도구 안에만 있었는데, 모바일도 **같은 순서**가 필요하다. 두 벌을
//! 두면 갈리고, 갈리는 순간 한쪽에서만 나는 결함이 생긴다 — 이 저장소에서 여러 번 겪은 모양이다.
//!
//! **밀어 넣는 구조다.** 검증 도구는 "읽힐 때까지 막고" 짤 수 있었지만 모바일은 그럴 수 없다 —
//! host 가 소켓을 들고 바이트를 밀어 넣는다(모바일 §3: 브리지엔 OS 호출이 0). 그래서 여기는
//! `feed(입력) → (선에 보낼 바이트, 화면에 그릴 바이트)` 인 상태기계이고, 막지 않는다.
//!
//! **비밀은 호출자가 든다.** 개인키는 인자로 받는다 — 모바일에서는 host 가 Keychain·Keystore 에서
//! 꺼내 온다(계약 §3.4). 이 층은 파일도 키체인도 모른다.

const std = @import("std");
const version = @import("version.zig");
const kexinit = @import("kexinit.zig");
const kex = @import("kex.zig");
const cipher = @import("cipher.zig");
const transport = @import("transport.zig");
const hostkey = @import("hostkey.zig");
const userauth = @import("userauth.zig");
const channel = @import("channel.zig");
const wire = @import("wire.zig");
const packet = @import("packet.zig");

pub const Error = error{
    /// 상대가 우리가 기대한 것과 다른 메시지를 보냈다.
    UnexpectedMessage,
    /// 호스트키를 아직 승인받지 못했다 — `acceptHostKey` 를 부르거나 끊는다.
    HostKeyNotAccepted,
    /// 사용자가 호스트키를 거절했다(또는 `known_hosts` 가 다르다).
    HostKeyRejected,
    /// 인증이 거절됐다.
    AuthFailed,
    /// 서버가 채널을 안 열어 줬다.
    ChannelRefused,
    /// 채널 요청(`pty-req`·`shell`)이 거절됐다.
    RequestFailed,
    /// 서버가 끊었다(`SSH_MSG_DISCONNECT`).
    Disconnected,
    /// 아직 셸이 안 떴는데 쓰려 한다.
    NotReady,
    /// `start` 를 안 부르고 `feed` 했다. **조용한 무동작보다 낫다** — 안 그러면 호출자가 아무
    /// 일도 안 하면서 영원히 읽는다(실측으로 그 모양을 여러 번 겪었다).
    NotStarted,
    /// 호출자 버퍼가 모자란다.
    ShortBuffer,
} || transport.Error || kexinit.Error || kex.Error || hostkey.Error ||
    userauth.Error || channel.Error || version.Error || wire.Error;

/// 지금 어디까지 왔나. **UI 가 이 값을 그대로 보여 줄 수 있게** 이름을 짓는다.
pub const State = enum {
    /// 아직 시작 안 함.
    idle,
    /// 서버 버전 줄을 기다린다.
    version_exchange,
    /// 서버 `KEXINIT` 을 기다린다.
    negotiating,
    /// 서버 `KEX_ECDH_REPLY` 를 기다린다.
    key_exchange,
    /// **호스트키를 사용자에게 물어야 한다**(계약 §4 — 자동 승인은 없다). `acceptHostKey` 를
    /// 부르기 전에는 한 발도 안 나간다.
    host_key_decision,
    /// 서버 `NEWKEYS` 를 기다린다.
    awaiting_new_keys,
    /// `ssh-userauth` 수락을 기다린다.
    requesting_service,
    /// 인증 결과를 기다린다.
    authenticating,
    /// 채널 열기 확인을 기다린다.
    opening_channel,
    /// `pty-req` 답을 기다린다.
    requesting_pty,
    /// `shell` 답을 기다린다.
    starting_shell,
    /// **셸이 떴다** — 이제 화면 바이트가 오고 키 입력을 보낼 수 있다.
    ready,
    /// 끝났다.
    closed,
};

/// 연결에 필요한 것들. **비밀은 호출자가 든다.**
pub const Options = struct {
    user: []const u8,
    /// `seed(32) ‖ public(32)`. host 가 Keychain·Keystore 에서 꺼내 온다.
    secret_key: [userauth.secret_key_len]u8,
    /// `TERM` 값. 원격이 이것으로 terminfo 를 고른다.
    term: []const u8 = "xterm-256color",
    size: channel.TerminalSize,
    /// 이 클라이언트의 버전 문자열 꼬리(`SSH-2.0-maru_<이것>`).
    app_version: []const u8 = "0.1",
    /// 우리가 광고할 채널 윈도. 0 이면 기본(2MiB).
    window: u32 = 0,
    /// **pty 를 요청하나.** 터미널이면 참이다(기본).
    ///
    /// 끄면 stdout 과 stderr 가 **따로** 온다(`CHANNEL_DATA`·`CHANNEL_EXTENDED_DATA`). 켜면 서버가
    /// 그것을 pty 로 합쳐 보내고, **우리가 보낸 것도 그대로 되돌아온다**(터미널 에코) — 검증에서
    /// 그 에코를 명령 출력으로 오해했다(실측). 즉 이 값은 화면에 무엇이 오는지를 바꾼다.
    pty: bool = true,
};

/// `feed` 한 걸음이 **선에 낼 수 있는 최대치**. 인증 요청이 가장 크다(키 blob + 서명 + 사용자 이름).
///
/// 호출자 버퍼가 이보다 작으면 한 걸음도 못 나가는데, 그것을 조용히 두면 **아무 일도 안 하면서
/// 도는 루프**가 된다 — 그래서 `feed` 가 입구에서 거절한다.
pub const min_wire_out = 4096;

/// `feed` 한 번의 결과.
///
/// **`banner` 와 `exit_signal` 은 `Client` 안을 가리킨다** — `wire`·`screen` 이 호출자 버퍼를
/// 가리키는 것과 다르다. 다음 `feed` 까지만 살고, `Client` 를 복사·이동하면 그 순간 어긋난다.
/// 들고 있어야 하면 **복사한다**. 전송기의 `Received.payload` 와 같은 규칙이다(계약 §4.5).
pub const Step = struct {
    /// 입력에서 소비한 바이트. 호출자는 그만큼 앞으로 민다.
    consumed: usize,
    /// **선에 보낼 바이트**(호출자가 준 `wire_out` 안). 비어 있을 수 있다.
    wire: []const u8,
    /// **화면에 그릴 바이트**(호출자가 준 `screen_out` 안). 원격의 stdout·stderr 를 합친 것이다 —
    /// pty 를 쓰면 서버가 이미 합쳐 보내므로 여기서도 가르지 않는다.
    screen: []const u8,
    state: State,
    /// 셸이 끝났다면 그 코드.
    exit_status: ?u32 = null,
    /// 신호로 죽었다면 그 이름(`SIG` 접두 없이). `exit_status` 와 **둘 중 하나**만 온다(§6.10).
    exit_signal: ?[]const u8 = null,
    /// 서버가 보낸 배너(RFC 4252 §5.4 — 법적 고지 등). **이미 걸러져 있다**(제어문자 제거) —
    /// 서버가 고른 문자열이 그대로 화면에 가면 OSC 로 창 제목·클립보드에 손댈 수 있다.
    banner: ?[]const u8 = null,
};

/// **약 10KiB 다.** 교환 해시에 쓸 원문(`I_C`·`I_S` 각 4KiB)을 그대로 들어야 해서 그렇다 —
/// 다시 만들면 cookie 가 달라져 해시가 안 맞는다(계약 §4.2).
///
/// **자리를 고정해서 든다**(전역·힙). 값으로 옮기면 10KiB 를 복사할 뿐 아니라, 앞선 `Step` 이
/// 가리키던 `banner`·`exit_signal` 이 옛 자리를 보게 된다.
pub const Client = struct {
    state: State = .idle,
    t: transport.Transport = .{},
    ch: channel.Channel = .{},
    opts: Options,
    rand: std.Random,

    /// 교환 해시 재료. **버전 줄과 `KEXINIT` 원문은 그대로 보관해야 한다** — 다시 만들면 cookie 가
    /// 달라져 해시가 안 맞는다(계약 §4.2).
    v_c_buf: [64]u8 = undefined,
    v_c_len: usize = 0,
    v_s_buf: [version.max_line]u8 = undefined,
    v_s_len: usize = 0,
    i_c_buf: [4096]u8 = undefined,
    i_c_len: usize = 0,
    i_s_buf: [4096]u8 = undefined,
    i_s_len: usize = 0,

    eph: ?kex.Ephemeral = null,
    k: [kex.shared_len]u8 = undefined,
    h: [kex.hash_len]u8 = undefined,
    /// **첫 `H`** — 재키잉해도 안 바뀐다(RFC 4253 §7.2).
    session_id: [kex.hash_len]u8 = undefined,
    strict_kex_initial: bool = false,

    /// 호스트키 blob(사용자에게 보여 줄 지문을 여기서 뽑는다).
    host_key_buf: [512]u8 = undefined,
    host_key_len: usize = 0,
    host_key_accepted: bool = false,

    /// 재키잉 중에 미뤄 둔 채널 응답. **재키잉 중에는 채널 메시지를 못 보낸다**(계약 §3.0.1).
    deferred_close: bool = false,
    /// 모르는 채널 요청에 답할 것이 밀려 있나(§5.4 — `want_reply` 면 답해야 한다).
    deferred_request_failure: bool = false,
    /// 재키잉 중인가(우리가 시작했든 서버가 시작했든).
    rekeying: bool = false,
    exit_status: ?u32 = null,
    /// 신호로 죽었을 때 그 이름. **`exit_status` 를 `null` 로 두고 끝내면 "끝났는지" 조차 모른다** —
    /// 옛 드라이버는 이것을 오류로 올렸는데, 오류는 세션을 죽이므로 정보만 남기는 편이 낫다.
    exit_signal_buf: [32]u8 = undefined,
    exit_signal_len: usize = 0,
    /// 재키잉 횟수(진단용). 0 이면 그 경로를 안 탔다는 뜻이다.
    rekeys: usize = 0,
    /// 걸러 둔 배너. `feed` 한 번이 돌려주고 다음 호출에서 비운다.
    banner_buf: [1024]u8 = undefined,
    banner_len: usize = 0,
    /// **셸이 한 번이라도 떴나.** `state` 는 재키잉 중에 `key_exchange` 로 돌아가는데, 그때
    /// `write` 가 `NotReady` 를 내면 **호출자가 재키잉을 알아야** 한다 — 알 필요가 없어야 한다.
    /// 그래서 "쓸 수 있는 세션인가"(이 값)와 "지금 보낼 수 있나"(윈도·§7.1)를 가른다.
    shell_ready: bool = false,

    pub fn init(opts: Options, rand: std.Random) Client {
        var c: Client = .{ .opts = opts, .rand = rand };
        if (opts.window != 0) {
            c.ch.local_window_max = opts.window;
            c.ch.local_window = opts.window;
        }
        return c;
    }

    /// 비밀을 지운다. **연결이 끝나면 부른다.**
    ///
    /// **지운 뒤에는 못 쓴다.** 처음에는 상태를 그대로 뒀는데, 그러면 키가 0 인 채로 세션이
    /// 계속 굴러간다 — 그 결과는 "왜인지 서버가 다 거절한다" 로 나타나고 원인이 여기라는 것을
    /// 짚기 어렵다(실측). 그래서 `closed` 로 못박는다.
    ///
    /// **`h`·`session_id` 는 안 지운다.** 비밀이 아니다 — `H` 는 공개 값들과 `K` 의 해시이고
    /// 서버가 거기에 **서명해서 보내는** 값이며, `session_id` 는 인증 서명에 그대로 들어간다.
    /// 지울 이유가 없는 것을 지우면 다음 사람이 "이건 왜 안 지우지" 를 거꾸로 묻게 된다.
    pub fn clear(self: *Client) void {
        self.t.clear();
        if (self.eph) |*e| e.clear();
        std.crypto.secureZero(u8, &self.k);
        std.crypto.secureZero(u8, &self.opts.secret_key);
        self.state = .closed;
        self.shell_ready = false;
    }

    /// 우리 버전 줄을 낸다. **`feed` 보다 먼저 한 번 부른다.**
    pub fn start(self: *Client, wire_out: []u8) Error![]const u8 {
        if (self.state != .idle) return Error.UnexpectedMessage;
        const line = version.clientLine("0.1");
        if (line.len > self.v_c_buf.len) return Error.ShortBuffer;
        @memcpy(self.v_c_buf[0..line.len], line);
        self.v_c_len = line.len;
        if (line.len + 2 > wire_out.len) return Error.ShortBuffer;
        @memcpy(wire_out[0..line.len], line);
        wire_out[line.len] = '\r';
        wire_out[line.len + 1] = '\n';
        self.state = .version_exchange;
        return wire_out[0 .. line.len + 2];
    }

    /// 사용자가 호스트키를 승인했다(계약 §4 — TOFU).
    pub fn acceptHostKey(self: *Client) void {
        self.host_key_accepted = true;
    }

    /// 사용자에게 보여 줄 지문. `host_key_decision` 상태에서 유효하다.
    pub fn hostKeyFingerprint(self: *Client, out: []u8) Error![]const u8 {
        return hostkey.fingerprint(out, self.host_key_buf[0..self.host_key_len]);
    }

    /// 선에서 읽은 바이트를 먹인다. **막지 않는다** — 더 필요하면 `consumed` 만큼만 먹고 돌아온다.
    pub fn feed(self: *Client, input: []const u8, wire_out: []u8, screen_out: []u8) Error!Step {
        // **버퍼가 한 걸음도 못 담으면 시작하지 않는다.** 조용히 0 을 돌려주면 호출자가 영원히
        // 맴돈다 — 이 저장소에서 "아무것도 안 하면서 초록" 을 여러 번 겪었다.
        // **`start` 를 안 불렀으면 오류다.** 조용히 아무 일도 안 하면 호출자가 영원히 읽는다.
        if (self.state == .idle) return Error.NotStarted;
        if (wire_out.len < min_wire_out) return Error.ShortBuffer;
        if (screen_out.len < self.ch.local_max_packet) return Error.ShortBuffer;
        var w: Out = .{ .buf = wire_out };
        var s: Out = .{ .buf = screen_out };
        var consumed: usize = 0;
        self.banner_len = 0; // 지난 호출의 것을 물려주지 않는다

        // **진행은 "먹었나" 만이 아니다 — "상태가 옮겨졌나" 도 진행이다.**
        //
        // 처음에는 `consumed` 만 봤는데, 그러면 호스트키 승인처럼 **입력을 안 먹고 상태만 옮기는**
        // 걸음 뒤에 루프가 끊긴다. 그때 이미 버퍼에 들어와 있던 서버 `NEWKEYS` 를 안 먹고 나가고,
        // 호출자는 더 읽으려 하는데 서버는 이미 다 보낸 뒤라 **20초를 멈춘다**(실서버에서 실측).
        while (true) {
            // **버퍼가 찰 것 같으면 멈춘다.** 호출자 버퍼는 유한하고(모바일은 특히), 한 번에
            // 다 담으려 들면 `ShortBuffer` 로 죽는다 — 실측으로 겪었다. 여기서 멈추면 호출자가
            // 비우고 다시 부르면 되고, 입력은 `consumed` 만큼만 먹었으므로 잃는 것이 없다.
            // 한 걸음이 실제로 필요한 만큼만 남겨 둔다. 넉넉히 잡으면(예: 패킷 상한 256KiB)
            // 모바일이 못 쓸 크기를 요구하게 된다.
            if (w.remaining() < min_wire_out or s.remaining() < self.ch.local_max_packet) break;
            const before_consumed = consumed;
            const before_state = self.state;
            try self.step(input[consumed..], &consumed, &w, &s);
            if (consumed == before_consumed and self.state == before_state) break;
        }
        return .{
            .consumed = consumed,
            .wire = w.written(),
            .screen = s.written(),
            .state = self.state,
            .exit_status = self.exit_status,
            .exit_signal = if (self.exit_signal_len == 0) null else self.exit_signal_buf[0..self.exit_signal_len],
            .banner = if (self.banner_len == 0) null else self.banner_buf[0..self.banner_len],
        };
    }

    /// 키 입력을 보낸다. `ready` 에서만 쓸 수 있다.
    ///
    /// **상대가 허락한 만큼만 나간다**(계약 §3.1). 다 못 보내면 보낸 만큼을 알려 주고, 호출자는
    /// 나머지를 다음에 다시 준다 — 넘겨 보내면 서버가 조용히 흘린다.
    pub fn write(self: *Client, data: []const u8, wire_out: []u8) Error!struct { wire: []const u8, sent: usize } {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return .{ .wire = wire_out[0..0], .sent = 0 };
        const room = self.ch.sendableLen();
        if (room == 0) return .{ .wire = wire_out[0..0], .sent = 0 };
        const n = @min(@as(usize, room), data.len);
        var buf: [packet.max_packet]u8 = undefined;
        const payload = try self.ch.writeData(&buf, data[0..n]);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return .{ .wire = w.written(), .sent = n };
    }

    /// **더 보낼 것이 없다**(§5.3). 원격 명령이 stdin 끝을 봐야 끝나는 경우에 필요하다
    /// (`cat`·`wc` 같은 것). **채널은 아직 열려 있다** — 반대 방향 출력은 계속 온다.
    pub fn eof(self: *Client, wire_out: []u8) Error![]const u8 {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return wire_out[0..0];
        // **이미 알렸거나 채널이 닫혔으면 할 일이 없다.** 오류가 아니다 — 보내는 동안 상대가
        // 먼저 닫을 수 있고(실측), 그때 EOF 를 못 보낸다고 세션을 실패로 만들 이유는 없다.
        if (self.ch.state != .open) return wire_out[0..0];
        var buf: [64]u8 = undefined;
        const payload = try self.ch.writeEof(&buf);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return w.written();
    }

    /// 터미널 크기가 바뀌었다(§6.7).
    pub fn resize(self: *Client, size: channel.TerminalSize, wire_out: []u8) Error![]const u8 {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return wire_out[0..0];
        var buf: [256]u8 = undefined;
        const payload = try self.ch.writeWindowChange(&buf, size);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return w.written();
    }

    // ---- 안쪽 ----

    const Out = struct {
        buf: []u8,
        len: usize = 0,

        fn append(self: *Out, bytes: []const u8) Error!void {
            if (self.len + bytes.len > self.buf.len) return Error.ShortBuffer;
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        fn written(self: Out) []const u8 {
            return self.buf[0..self.len];
        }

        fn remaining(self: Out) usize {
            return self.buf.len - self.len;
        }
    };

    /// payload 하나를 전송기에 태워 선 바이트로 만든다.
    fn emit(self: *Client, w: *Out, payload: []const u8) Error!void {
        var buf: [packet.max_packet + 64]u8 = undefined;
        const n = try self.t.send(&buf, payload, self.rand);
        try w.append(buf[0..n]);
    }

    /// 한 걸음. 입력에서 먹을 수 있으면 먹고, 상태를 옮긴다.
    fn step(self: *Client, input: []const u8, consumed: *usize, w: *Out, s: *Out) Error!void {
        switch (self.state) {
            .idle => unreachable, // `feed` 가 입구에서 막는다
            // **닫힌 뒤에 온 것은 흘려보낸다.** 세션은 끝났고 그 바이트로 할 일이 없다 — 파싱하면
            // 오류가 나는데(예: 버전 줄), 끝난 연결에서 그것을 실패로 올릴 이유가 없다.
            .closed => {
                consumed.* += input.len;
                return;
            },
            .version_exchange => {
                const p = version.parse(input) catch |e| {
                    if (e == version.Error.Incomplete) return;
                    return e;
                };
                // **길이 검사가 필요 없다 — 구조가 보장한다.** 버퍼가 `version.max_line` 이고
                // `version.parse` 가 그보다 긴 줄을 `LineTooLong` 으로 이미 거절한다. 검사를
                // 두면 영영 안 도는 가지가 되고, 그런 가지는 변이 검사에서 살아남아 "구멍" 처럼
                // 보인다(적대적 검증에서 실제로 그렇게 보였다).
                @memcpy(self.v_s_buf[0..p.line.len], p.line);
                self.v_s_len = p.line.len;
                consumed.* += p.consumed;
                // 우리 KEXINIT 을 낸다. **원문을 보관한다**(교환 해시).
                const i_c = try kexinit.write(&self.i_c_buf, self.rand);
                self.i_c_len = i_c.len;
                try self.emit(w, i_c);
                self.state = .negotiating;
            },
            .host_key_decision => {
                if (!self.host_key_accepted) return; // 답을 기다린다 — 한 발도 안 나간다
                try self.afterHostKey(w);
            },
            else => try self.stepPacket(input, consumed, w, s),
        }
    }

    /// 패킷 하나를 꺼내 지금 상태에 맞게 다룬다.
    fn stepPacket(self: *Client, input: []const u8, consumed: *usize, w: *Out, s: *Out) Error!void {
        if (input.len == 0) return;
        var pkt: [packet.max_packet]u8 = undefined;
        const got = (self.t.feed(&pkt, input) catch |e| {
            if (e == packet.Error.Incomplete) return;
            return e;
        }) orelse return;
        switch (got) {
            .discarded => |d| {
                consumed.* += d.consumed;
                return;
            },
            .packet => |p| {
                consumed.* += p.consumed;
                try self.dispatch(p.payload, w, s);
            },
        }
    }

    fn dispatch(self: *Client, payload: []const u8, w: *Out, s: *Out) Error!void {
        const msg = payload[0];
        // **전송 계층 잡 메시지는 어느 상태에서나 온다**(계약 §3.2). 분류는 S7c 가 넓히고,
        // 여기서는 세션을 죽이지 않게만 다룬다.
        if (msg == msg_disconnect) return Error.Disconnected;
        if (msg == msg_ignore or msg == msg_debug or msg == msg_unimplemented) return;
        if (msg == msg_global_request) return; // `want_reply` 는 S7c 가 다룬다

        // **배너는 어느 상태에서나 온다** — RFC 4252 §5.4 는 "at any time after this
        // authentication protocol starts and before authentication is successful" 라고 못박는다.
        //
        // 예전에는 `authenticating` 에서만 받았고, 그러면 `requesting_service`(SERVICE_ACCEPT 를
        // 기다리는 사이)에 온 배너가 `UnexpectedMessage` 로 **세션을 죽인다**. **OpenSSH 는 그
        // 자리에서 안 보낸다**(실측 — 배너를 켠 sshd 로 확인했고 옛 코드도 통과했다). 즉 이것은
        // 명세가 허락하는데 우리가 안 받던 자리이지, OpenSSH 에서 재현된 결함은 아니다.
        // 그래도 받는다: 비용이 한 줄이고 서버는 OpenSSH 만 있는 것이 아니다.
        if (msg == userauth.msg_userauth_banner) return self.onBanner(payload);

        // **서버가 재키잉을 요구했다**(계약 §3.0.1). 어느 상태에서나 올 수 있다.
        if (msg == kexinit.msg_kexinit and self.state != .negotiating) return self.beginRekey(payload, w);

        switch (self.state) {
            .negotiating => try self.onKexInit(payload, w),
            .key_exchange => try self.onKexReply(payload, w),
            .awaiting_new_keys => try self.onNewKeys(payload, w),
            .requesting_service => {
                try userauth.parseServiceAccept(payload);
                try self.sendAuth(w);
            },
            .authenticating => try self.onAuthResponse(payload, w),
            .opening_channel, .requesting_pty, .starting_shell, .ready => try self.onChannel(payload, w, s),
            else => return Error.UnexpectedMessage,
        }
    }

    fn onKexInit(self: *Client, payload: []const u8, w: *Out) Error!void {
        if (payload.len > self.i_s_buf.len) return Error.ShortBuffer;
        @memcpy(self.i_s_buf[0..payload.len], payload);
        self.i_s_len = payload.len;
        const peer = try kexinit.parse(self.i_s_buf[0..self.i_s_len]);
        const neg = try kexinit.negotiate(peer, .initial);
        self.strict_kex_initial = neg.strict_kex;
        try self.t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

        var seed: [32]u8 = undefined;
        self.rand.bytes(&seed);
        self.eph = try kex.Ephemeral.fromSeed(seed);
        var buf: [128]u8 = undefined;
        try self.emit(w, try kex.writeInit(&buf, self.eph.?.public));
        self.state = .key_exchange;
    }

    fn onKexReply(self: *Client, payload: []const u8, w: *Out) Error!void {
        const reply = try kex.parseReply(payload);
        if (reply.host_key.len > self.host_key_buf.len) return Error.ShortBuffer;
        @memcpy(self.host_key_buf[0..reply.host_key.len], reply.host_key);
        self.host_key_len = reply.host_key.len;

        self.k = try self.eph.?.sharedSecret(reply.q_s);
        self.h = try kex.exchangeHash(.{
            .v_c = self.v_c_buf[0..self.v_c_len],
            .v_s = self.v_s_buf[0..self.v_s_len],
            .i_c = self.i_c_buf[0..self.i_c_len],
            .i_s = self.i_s_buf[0..self.i_s_len],
            .k_s = reply.host_key,
            .q_c = &self.eph.?.public,
            .q_s = reply.q_s,
            .k = self.k,
        });
        // **서명부터 본다.** 서명이 안 맞으면 지문을 보여 줄 이유도 없다 — 그 지문은 서버 것이
        // 아닐 수 있다.
        try hostkey.verifyExchangeHash(reply.host_key, reply.signature, &self.h);
        if (self.rekeying) {
            // 재키잉에서는 다시 묻지 않는다 — 지문이 바뀌었으면 위 검증이 이미 실패한다.
            return self.afterHostKey(w);
        }
        self.session_id = self.h;
        // **여기서 멈춘다**(계약 §4 — 자동 승인은 없다).
        self.state = .host_key_decision;
    }

    /// 호스트키가 승인된 뒤 — `NEWKEYS` 를 보낸다.
    fn afterHostKey(self: *Client, w: *Out) Error!void {
        try self.emit(w, &[_]u8{msg_newkeys});
        self.state = .awaiting_new_keys;
    }

    fn onNewKeys(self: *Client, payload: []const u8, w: *Out) Error!void {
        if (payload[0] != msg_newkeys) return Error.UnexpectedMessage;
        var key_c2s: [64]u8 = undefined;
        var key_s2c: [64]u8 = undefined;
        try kex.deriveKey(&key_c2s, self.k, self.h, .enc_c2s, &self.session_id);
        try kex.deriveKey(&key_s2c, self.k, self.h, .enc_s2c, &self.session_id);
        var cs = cipher.Cipher.initMove(&key_c2s);
        var cr = cipher.Cipher.initMove(&key_s2c);
        try self.t.enableSendKeys(&cs);
        try self.t.enableRecvKeys(&cr);
        if (self.eph) |*e| e.clear();
        self.eph = null;

        if (self.rekeying) {
            self.rekeying = false;
            self.rekeys += 1;
            try self.flushDeferred(w);
            self.state = .ready;
            return;
        }
        var buf: [64]u8 = undefined;
        try self.emit(w, try userauth.writeServiceRequest(&buf));
        self.state = .requesting_service;
    }

    fn sendAuth(self: *Client, w: *Out) Error!void {
        var kb: [128]u8 = undefined;
        const key_blob = try userauth.publicKeyBlob(&kb, self.opts.secret_key);
        var sd: [512]u8 = undefined;
        const signed = try userauth.signedData(&sd, &self.session_id, self.opts.user, key_blob);
        var sig: [128]u8 = undefined;
        const sig_blob = try userauth.signBlob(&sig, self.opts.secret_key, signed);
        var req: [1024]u8 = undefined;
        try self.emit(w, try userauth.writePublicKeyRequest(&req, self.opts.user, key_blob, sig_blob));
        self.state = .authenticating;
    }

    /// 배너를 걸러 보관한다. **거르는 것이 계약이다**(§4.4.2) — 서버가 고른 문자열이 그대로
    /// 화면에 가면 OSC 0/2·52 로 창 제목을 바꾸고 클립보드에 쓴다. 이 층이 표시를 모르므로
    /// **여기서 걸러 두고** 호출자에게는 안전한 것만 준다.
    fn onBanner(self: *Client, payload: []const u8) Error!void {
        var r = wire.Reader.init(payload);
        _ = try r.byte();
        const message = try r.string();
        const clean = userauth.sanitizeBanner(&self.banner_buf, message) catch {
            // 너무 길면 버린다 — 배너 때문에 세션을 죽일 이유는 없다.
            self.banner_len = 0;
            return;
        };
        self.banner_len = clean.len;
    }

    fn onAuthResponse(self: *Client, payload: []const u8, w: *Out) Error!void {
        switch (try userauth.parseResponse(payload, .publickey)) {
            .success => {
                var buf: [256]u8 = undefined;
                try self.emit(w, try self.ch.writeOpen(&buf, 0));
                self.state = .opening_channel;
            },
            .banner => {}, // 위 `onBanner` 가 이미 처리한다(여기 오지 않는다)
            .failure => return Error.AuthFailed,
            else => return Error.UnexpectedMessage,
        }
    }

    fn onChannel(self: *Client, payload: []const u8, w: *Out, s: *Out) Error!void {
        var buf: [1024]u8 = undefined;
        switch (try self.ch.receive(payload)) {
            .opened => {
                if (self.opts.pty) {
                    try self.emit(w, try self.ch.writePtyReq(&buf, self.opts.term, self.opts.size, ""));
                    self.state = .requesting_pty;
                } else {
                    try self.emit(w, try self.ch.writeShell(&buf));
                    self.state = .starting_shell;
                }
            },
            .open_failed => return Error.ChannelRefused,
            .request_success => switch (self.state) {
                .requesting_pty => {
                    try self.emit(w, try self.ch.writeShell(&buf));
                    self.state = .starting_shell;
                },
                .starting_shell => {
                    self.state = .ready;
                    self.shell_ready = true;
                },
                else => {},
            },
            .request_failure => return Error.RequestFailed,
            .data => |d| try s.append(d),
            .extended_data => |x| try s.append(x.data),
            .exit_status => |code| self.exit_status = code,
            .exit_signal => |sig| {
                const n = @min(sig.name.len, self.exit_signal_buf.len);
                @memcpy(self.exit_signal_buf[0..n], sig.name[0..n]);
                self.exit_signal_len = n;
            },
            .eof => {},
            .closed => {
                self.deferred_close = true;
                self.state = .closed;
            },
            .window_adjusted => {},
            // **`want_reply` 면 답해야 한다**(§5.4 — "If the request is not recognized ...
            // SSH_MSG_CHANNEL_FAILURE is returned"). 안 답하면 서버가 기다린다 — OpenSSH 는
            // `keepalive@openssh.com` 을 그렇게 보내고, 답이 없으면 연결이 죽은 것으로 본다.
            .unknown_request => |u| if (u.want_reply) {
                self.deferred_request_failure = true;
            },
        }
        try self.flushDeferred(w);
    }

    /// 미뤄 둔 채널 송신과 흐름 제어 보충. **재키잉 중에는 아무것도 안 보낸다**(계약 §3.0.1).
    fn flushDeferred(self: *Client, w: *Out) Error!void {
        if (!self.t.canSendChannelMessages()) return;
        var buf: [256]u8 = undefined;
        if (self.deferred_request_failure) {
            self.deferred_request_failure = false;
            try self.emit(w, try self.ch.writeChannelFailure(&buf));
        }
        if (self.deferred_close) {
            self.deferred_close = false;
            if (self.ch.state != .closed) try self.emit(w, try self.ch.writeClose(&buf));
        }
        if (self.ch.pendingWindowAdjust() != 0) {
            try self.emit(w, try self.ch.writeWindowAdjust(&buf));
        }
    }

    /// 서버가 `KEXINIT` 을 다시 보냈다 — 재키잉을 시작한다(계약 §3.0.1).
    fn beginRekey(self: *Client, i_s: []const u8, w: *Out) Error!void {
        if (i_s.len > self.i_s_buf.len) return Error.ShortBuffer;
        @memcpy(self.i_s_buf[0..i_s.len], i_s);
        self.i_s_len = i_s.len;

        try self.t.beginRekey();
        self.rekeying = true;
        const i_c = try kexinit.write(&self.i_c_buf, self.rand);
        self.i_c_len = i_c.len;
        try self.emit(w, i_c);

        const peer = try kexinit.parse(self.i_s_buf[0..self.i_s_len]);
        const neg = try kexinit.negotiate(peer, .{ .rekey = self.strict_kex_initial });
        try self.t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

        var seed: [32]u8 = undefined;
        self.rand.bytes(&seed);
        self.eph = try kex.Ephemeral.fromSeed(seed);
        var buf: [128]u8 = undefined;
        try self.emit(w, try kex.writeInit(&buf, self.eph.?.public));
        self.state = .key_exchange;
    }
};

const msg_disconnect: u8 = 1;
const msg_ignore: u8 = 2;
const msg_unimplemented: u8 = 3;
const msg_debug: u8 = 4;
const msg_newkeys: u8 = 21;
const msg_global_request: u8 = 80;

const testing = std.testing;

test "상수는 RFC 4253 §12 그대로다" {
    try testing.expectEqual(@as(u8, 1), msg_disconnect);
    try testing.expectEqual(@as(u8, 2), msg_ignore);
    try testing.expectEqual(@as(u8, 3), msg_unimplemented);
    try testing.expectEqual(@as(u8, 4), msg_debug);
    try testing.expectEqual(@as(u8, 21), msg_newkeys);
    try testing.expectEqual(@as(u8, 80), msg_global_request);
}

test "시작하면 버전 줄을 내고 서버 것을 기다린다" {
    var prng = std.Random.DefaultPrng.init(1);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [256]u8 = undefined;
    const line = try c.start(&out);
    try testing.expect(std.mem.startsWith(u8, line, "SSH-2.0-maru_"));
    try testing.expect(std.mem.endsWith(u8, line, "\r\n"));
    try testing.expectEqual(State.version_exchange, c.state);

    // 두 번 부르면 안 된다.
    try testing.expectError(Error.UnexpectedMessage, c.start(&out));
}

test "서버 버전 줄을 받으면 KEXINIT 을 낸다" {
    var prng = std.Random.DefaultPrng.init(2);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);

    // **배너가 앞에 와도 된다**(계약 §3.2.2).
    const input = "hello banner\r\nSSH-2.0-OpenSSH_10.2\r\n";
    const step = try c.feed(input, &out, &screen);
    try testing.expectEqual(input.len, step.consumed);
    try testing.expectEqual(State.negotiating, step.state);
    try testing.expect(step.wire.len > 0);

    // 낸 것이 KEXINIT 패킷이다.
    const dec = try packet.read(step.wire);
    try testing.expectEqual(kexinit.msg_kexinit, dec.payload[0]);
}

test "불완전한 입력은 먹지 않고 돌아온다" {
    // **막지 않는 것이 요점이다**(모바일 §3 — host 가 밀어 넣는다). 다 안 왔으면 0 을 소비하고
    // 돌아와야 호출자가 더 읽어 올 수 있다.
    var prng = std.Random.DefaultPrng.init(3);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);

    const step = try c.feed("SSH-2.0-Open", &out, &screen);
    try testing.expectEqual(@as(usize, 0), step.consumed);
    try testing.expectEqual(State.version_exchange, step.state);
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "제어문자가 든 버전 줄은 거절한다" {
    // 계약 §3.2.2 — 그 줄은 아직 아무것도 검증 안 된 상대가 보낸 것이고 TOFU 프롬프트에 그대로
    // 올라간다. 드라이버가 오류를 삼키면 그 방어가 안 보인다(검증 도구에서 그렇게 겪었다).
    var prng = std.Random.DefaultPrng.init(4);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    try testing.expectError(
        version.Error.MalformedVersion,
        c.feed("SSH-2.0-evil\x1b]0;pwned\x07\r\n", &out, &screen),
    );
}

test "ready 가 아니면 쓰지 못한다" {
    var prng = std.Random.DefaultPrng.init(5);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [256]u8 = undefined;
    try testing.expectError(Error.NotReady, c.write("ls\n", &out));
    try testing.expectError(Error.NotReady, c.resize(.{ .cols = 100, .rows = 40 }, &out));
}

test "clear 는 비밀을 지운다" {
    var prng = std.Random.DefaultPrng.init(6);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(9),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.k = @splat(7);
    c.clear();
    try testing.expect(std.mem.allEqual(u8, &c.k, 0));
    try testing.expect(std.mem.allEqual(u8, &c.opts.secret_key, 0));
}

/// 셸이 뜬 클라이언트를 만든다 — 채널 사건만 시험하려는 테스트용.
///
/// **전송기를 평문으로 둔다.** 암호를 붙이면 이 테스트가 KEX 를 다시 짜야 하는데, 여기서 보려는
/// 것은 채널 사건 처리이지 암호가 아니다.
fn readyClient() Client {
    var prng = std.Random.DefaultPrng.init(99);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.state = .ready;
    c.shell_ready = true;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    c.ch.state = .open;
    c.ch.local_id = 0;
    c.ch.remote_id = 0;
    c.ch.remote_window = 1 << 20;
    c.ch.remote_max_packet = 32768;
    return c;
}

/// 채널 페이로드 하나를 평문 패킷으로 싸서 먹인다.
fn feedChannel(c: *Client, payload: []const u8, wire_out: []u8, screen_out: []u8) !Step {
    var buf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&buf, payload, prng.random());
    return c.feed(buf[0..n], wire_out, screen_out);
}

test "모르는 채널 요청에 want_reply 면 답한다" {
    // **리팩터가 지웠던 자리다.** 검증 도구에는 있었는데 상태기계로 옮기며 빠졌다 — §5.4 는
    // "If the request is not recognized ... SSH_MSG_CHANNEL_FAILURE is returned" 라고 못박고,
    // OpenSSH 는 `keepalive@openssh.com` 을 그렇게 보낸다. 안 답하면 연결이 죽은 것으로 본다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("keepalive@openssh.com");
    try wr.boolean(true);
    const step = try feedChannel(&c, wr.written(), &w, &scr);

    // 답이 나갔다 — `CHANNEL_FAILURE`(100) 이고 상대 채널 번호로 간다.
    const dec = try packet.read(step.wire);
    try testing.expectEqual(channel.msg_channel_failure, dec.payload[0]);
}

test "want_reply 가 거짓이면 답하지 않는다" {
    // 안 물었는데 답하면 상대가 그것을 다른 요청의 답으로 읽는다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("nothing@example.com");
    try wr.boolean(false);
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "신호로 죽으면 그 이름을 잃지 않는다" {
    // §6.10 은 `exit-status` 와 `exit-signal` 중 하나만 온다고 한다. 신호 쪽을 버리면 사용자에게
    // "끝났는지" 조차 못 알려 준다 — 옛 드라이버는 오류로 올렸는데, 오류는 세션을 죽이므로
    // 정보만 남기는 편이 낫다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("exit-signal");
    try wr.boolean(false);
    try wr.string("TERM");
    try wr.boolean(false);
    try wr.string("");
    try wr.string("");
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqualStrings("TERM", step.exit_signal.?);
    try testing.expectEqual(@as(?u32, null), step.exit_status);
}

test "화면 바이트는 stdout 과 stderr 를 합친다" {
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_data);
    try wr.u32be(0);
    try wr.string("out");
    const a = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqualStrings("out", a.screen);

    var wr2 = wire.Writer.init(&buf);
    try wr2.byte(channel.msg_channel_extended_data);
    try wr2.u32be(0);
    try wr2.u32be(channel.extended_data_stderr);
    try wr2.string("err");
    const b = try feedChannel(&c, wr2.written(), &w, &scr);
    try testing.expectEqualStrings("err", b.screen);
}

test "버퍼가 한 걸음도 못 담으면 조용히 0 이 아니라 오류다" {
    // 조용히 0 을 돌려주면 호출자가 아무 일도 안 하면서 영원히 맴돈다.
    var c = readyClient();
    var tiny_wire: [16]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed("", &tiny_wire, &scr));

    var w: [8192]u8 = undefined;
    var tiny_screen: [16]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed("", &w, &tiny_screen));
}

test "재키잉 중에도 쓰기는 오류가 아니라 0 바이트다" {
    // **호출자가 재키잉을 알 필요가 없다.** `NotReady` 를 내면 모든 드라이버가 재키잉 상태를
    // 알아야 하고, 그러면 그 지식이 두 층에 생긴다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    try c.t.beginRekey();
    const r = try c.write("ls\n", &w);
    try testing.expectEqual(@as(usize, 0), r.sent);
    try testing.expectEqual(@as(usize, 0), r.wire.len);
    // 세션 자체는 여전히 쓸 수 있다 — `NotReady` 가 아니다.
    try testing.expect(c.shell_ready);
}

test "윈도가 0 이면 쓰기가 0 바이트다" {
    var c = readyClient();
    c.ch.remote_window = 0;
    var w: [8192]u8 = undefined;
    const r = try c.write("x", &w);
    try testing.expectEqual(@as(usize, 0), r.sent);
}

test "상대가 허락한 만큼만 나간다" {
    var c = readyClient();
    c.ch.remote_window = 10;
    c.ch.remote_max_packet = 10;
    var w: [8192]u8 = undefined;
    const r = try c.write("0123456789abcdef", &w);
    try testing.expectEqual(@as(usize, 10), r.sent);
    try testing.expect(r.wire.len > 0);
}

test "clear 뒤에는 못 쓴다" {
    // **적대적 검증 3회차가 찾은 것.** 지운 뒤에도 상태를 그대로 두면 키가 0 인 채로 세션이
    // 계속 굴러간다 — 결과는 "왜인지 서버가 다 거절한다" 로 나타나고 원인을 짚기 어렵다.
    var prng = std.Random.DefaultPrng.init(41);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0xAB), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    c.clear();
    try testing.expectEqual(State.closed, c.state);
    // 더 먹여도 아무 데도 안 간다(닫힘은 조용히 넘긴다 — 정상 종료 뒤 메시지가 오므로).
    const step = try c.feed("SSH-2.0-x\r\n", &out, &scr);
    try testing.expectEqual(State.closed, step.state);
    try testing.expectError(Error.NotReady, c.write("x", &out));
}

test "start 없이 feed 하면 조용히 넘기지 않는다" {
    var prng = std.Random.DefaultPrng.init(43);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.NotStarted, c.feed("SSH-2.0-x\r\n", &out, &scr));
}

test "호스트키를 승인하기 전에는 한 발도 안 나간다" {
    // 계약 §4 — 자동 승인은 없다. 여기서 새면 TOFU 가 무의미해진다.
    var prng = std.Random.DefaultPrng.init(47);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    c.state = .host_key_decision;

    for (0..5) |_| {
        const step = try c.feed("", &out, &scr);
        try testing.expectEqual(@as(usize, 0), step.wire.len);
        try testing.expectEqual(State.host_key_decision, step.state);
    }

    c.acceptHostKey();
    const step = try c.feed("", &out, &scr);
    try testing.expect(step.wire.len > 0);
    try testing.expectEqual(State.awaiting_new_keys, step.state);
}

test "서버가 거대한 KEXINIT 을 보내도 버퍼를 안 넘는다" {
    // **여기는 죽은 가지가 아니다.** `KEXINIT` 페이로드는 패킷 상한(256KiB)까지 올 수 있는데
    // 우리 보관 버퍼는 4KiB 다 — 교환 해시에 쓸 원문만 담으면 되기 때문이다. 검사를 빼면
    // 적대적 서버가 스택을 넘긴다.
    var prng = std.Random.DefaultPrng.init(51);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    _ = try c.feed("SSH-2.0-x\r\n", &out, &scr);

    var big: [8192]u8 = undefined;
    @memset(&big, 0);
    big[0] = kexinit.msg_kexinit;
    var wire_buf: [16384]u8 = undefined;
    const n = try packet.write(&wire_buf, &big, prng.random());
    try testing.expectError(Error.ShortBuffer, c.feed(wire_buf[0..n], &out, &scr));
}

test "서버가 거대한 호스트키 blob 을 보내도 버퍼를 안 넘는다" {
    // 호스트키는 wire string 이라 `max_field`(128KiB)까지 올 수 있다. 우리 버퍼는 512B —
    // ed25519 blob 은 51B 다. 검사를 빼면 적대적 서버가 스택을 넘긴다.
    var prng = std.Random.DefaultPrng.init(53);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    c.state = .key_exchange;
    c.t.phase = .initial_kex;

    var payload: [4096]u8 = undefined;
    var w = wire.Writer.init(&payload);
    try w.byte(kex.msg_kex_ecdh_reply);
    try w.string(&([_]u8{7} ** 1024)); // 512 보다 큰 호스트키
    try w.string(&([_]u8{8} ** 32));
    try w.string(&([_]u8{9} ** 64));

    var wire_buf: [8192]u8 = undefined;
    const n = try packet.write(&wire_buf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed(wire_buf[0..n], &out, &scr));
}

test "거대한 exit-signal 이름은 잘라서 담는다" {
    // 신호 이름도 wire string 이라 상한이 크다. 여기서 자르지 않으면 32B 버퍼를 넘는다.
    // **자르는 것이 맞다** — 이름은 사용자에게 보여 줄 값이고, 그것 때문에 세션을 죽일 이유는 없다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [512]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("exit-signal");
    try wr.boolean(false);
    try wr.string(&([_]u8{'A'} ** 200));
    try wr.boolean(false);
    try wr.string("");
    try wr.string("");
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqual(@as(usize, 32), step.exit_signal.?.len);
}

/// 인증 프로토콜 중인 클라이언트를 만든다(암호는 안 붙인다 — 여기서 볼 것은 배너 처리다).
fn authPhaseClient(state: State) Client {
    var prng = std.Random.DefaultPrng.init(61);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    c.state = state;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    return c;
}

fn bannerPayload(buf: []u8, message: []const u8) ![]const u8 {
    var w = wire.Writer.init(buf);
    try w.byte(userauth.msg_userauth_banner);
    try w.string(message);
    try w.string("en");
    return w.written();
}

test "배너는 인증 중 어느 상태에서나 받는다" {
    // **적대적 검증 6회차가 찾은 것.** RFC 4252 §5.4: "at any time after this authentication
    // protocol starts and before authentication is successful". `authenticating` 에서만 받으면
    // `requesting_service` 에 온 배너가 `UnexpectedMessage` 로 세션을 죽인다.
    //
    // **OpenSSH 는 그 자리에서 안 보낸다**(실측) — 그래서 실서버 스모크로는 안 잡힌다. 명세가
    // 허락하는 자리를 우리가 안 받던 것이고, 판정은 이 테스트가 소유한다.
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "legal notice");

    for ([_]State{ .requesting_service, .authenticating }) |st| {
        var c = authPhaseClient(st);
        var w: [8192]u8 = undefined;
        var scr: [64 * 1024]u8 = undefined;
        var pbuf: [1024]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(3);
        const n = try packet.write(&pbuf, payload, prng.random());
        const step = try c.feed(pbuf[0..n], &w, &scr);
        try testing.expectEqual(st, step.state); // 상태가 안 바뀐다 — 세션이 산다
        try testing.expectEqualStrings("legal notice", step.banner.?);
    }
}

test "배너는 걸러서 준다" {
    // 계약 §4.4.2 — 서버가 고른 문자열이다. 그대로 화면에 가면 OSC 0/2·52 로 창 제목을 바꾸고
    // 클립보드에 쓴다. 이 층이 표시를 모르므로 여기서 걸러 두고 안전한 것만 준다.
    var c = authPhaseClient(.authenticating);
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "hi\x1b]0;pwned\x07 there\n");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    const n = try packet.write(&pbuf, payload, prng.random());
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &w, &scr);
    const b = step.banner.?;
    try testing.expect(std.mem.indexOfScalar(u8, b, 0x1b) == null); // ESC 가 없다
    try testing.expect(std.mem.indexOfScalar(u8, b, 0x07) == null); // BEL 도 없다
    try testing.expect(std.mem.indexOf(u8, b, "there") != null); // 본문은 남는다
    try testing.expect(std.mem.indexOfScalar(u8, b, '\n') != null); // 줄바꿈은 남긴다
}

test "배너는 다음 feed 로 물려주지 않는다" {
    // 한 번 준 것을 계속 주면 호출자가 같은 고지를 여러 번 띄운다.
    var c = authPhaseClient(.authenticating);
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "once");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&pbuf, payload, prng.random());
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(pbuf[0..n], &w, &scr);
    const second = try c.feed("", &w, &scr);
    try testing.expectEqual(@as(?[]const u8, null), second.banner);
}

test "화면 버퍼가 차면 멈추고 나머지는 다음에 준다" {
    // **적대적 검증 8회차가 찾은 구멍.** 입구 검사(너무 작은 버퍼는 오류)는 덮여 있었지만
    // **중간에 멈추는 것**은 안 덮였다. 호출자 버퍼는 유한하고(모바일은 특히), 한 번에 다
    // 담으려 들면 `ShortBuffer` 로 죽는다 — 멈추고 `consumed` 만큼만 먹었다고 알려야 한다.
    var c = readyClient();
    c.ch.local_max_packet = 4096; // 화면 버퍼 요구치를 낮춘다
    var prng = std.Random.DefaultPrng.init(71);

    // 데이터 패킷 셋을 한 입력에 담는다.
    var payload: [2048]u8 = undefined;
    @memset(&payload, 'x');
    var one: [4096]u8 = undefined;
    var wr = wire.Writer.init(&one);
    try wr.byte(channel.msg_channel_data);
    try wr.u32be(0);
    try wr.string(&payload);
    var input: [16384]u8 = undefined;
    var len: usize = 0;
    for (0..3) |_| len += try packet.write(input[len..], wr.written(), prng.random());

    // 화면 버퍼가 둘밖에 못 담는다.
    var w: [8192]u8 = undefined;
    var scr: [5000]u8 = undefined;
    const step = try c.feed(input[0..len], &w, &scr);
    try testing.expect(step.consumed < len); // 다 안 먹었다
    try testing.expect(step.screen.len > 0); // 그래도 진행했다

    // 나머지는 다음 호출에서 나온다 — 잃는 것이 없다.
    const rest = try c.feed(input[step.consumed..len], &w, &scr);
    try testing.expect(rest.consumed > 0);
}

test "shell 수락이 세션을 쓸 수 있게 만든다" {
    // `readyClient` 는 `shell_ready` 를 손으로 세우므로 **진짜 전이**가 안 덮였다 —
    // 그것을 안 세워도 테스트가 다 통과했다(적대적 검증 8회차).
    var prng = std.Random.DefaultPrng.init(73);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    c.state = .starting_shell;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    c.ch.state = .open;
    c.ch.remote_window = 1 << 20;
    c.ch.remote_max_packet = 32768;

    var out: [8192]u8 = undefined;
    // 아직은 못 쓴다.
    try testing.expectError(Error.NotReady, c.write("x", &out));

    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_success);
    try wr.u32be(0);
    var scr: [64 * 1024]u8 = undefined;
    const step = try feedChannel(&c, wr.written(), &out, &scr);
    try testing.expectEqual(State.ready, step.state);

    // 이제 쓸 수 있다.
    const r = try c.write("ls\n", &out);
    try testing.expectEqual(@as(usize, 3), r.sent);
}
