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
};

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
    /// 재키잉 중인가(우리가 시작했든 서버가 시작했든).
    rekeying: bool = false,
    exit_status: ?u32 = null,
    /// 재키잉 횟수(진단용). 0 이면 그 경로를 안 탔다는 뜻이다.
    rekeys: usize = 0,
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
    pub fn clear(self: *Client) void {
        self.t.clear();
        if (self.eph) |*e| e.clear();
        std.crypto.secureZero(u8, &self.k);
        std.crypto.secureZero(u8, &self.opts.secret_key);
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
        if (wire_out.len < min_wire_out) return Error.ShortBuffer;
        if (screen_out.len < self.ch.local_max_packet) return Error.ShortBuffer;
        var w: Out = .{ .buf = wire_out };
        var s: Out = .{ .buf = screen_out };
        var consumed: usize = 0;

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
            .idle => return,
            .version_exchange => {
                const p = version.parse(input) catch |e| {
                    if (e == version.Error.Incomplete) return;
                    return e;
                };
                if (p.line.len > self.v_s_buf.len) return Error.ShortBuffer;
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

        // **서버가 재키잉을 요구했다**(계약 §3.0.1). 어느 상태에서나 올 수 있다.
        if (msg == kexinit.msg_kexinit and self.state != .negotiating) return self.beginRekey(payload, w);

        switch (self.state) {
            // **닫힌 뒤에도 메시지가 온다.** 우리 `CHANNEL_CLOSE` 와 서버 것이 엇갈리거나,
            // `exit-status` 가 뒤따라온다 — 그것을 오류로 다루면 **정상 종료가 실패로 보인다**
            // (실측: 4KiB 왕복이 `UnexpectedMessage` 로 끝났다).
            .closed => {},
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

    fn onAuthResponse(self: *Client, payload: []const u8, w: *Out) Error!void {
        switch (try userauth.parseResponse(payload, .publickey)) {
            .success => {
                var buf: [256]u8 = undefined;
                try self.emit(w, try self.ch.writeOpen(&buf, 0));
                self.state = .opening_channel;
            },
            .banner => {}, // 배너는 넘긴다 — 보여 주기는 UI 정책이다(계약 §4.4.2)
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
            .exit_signal => self.exit_status = null,
            .eof => {},
            .closed => {
                self.deferred_close = true;
                self.state = .closed;
            },
            .window_adjusted => {},
            .unknown_request => {},
        }
        try self.flushDeferred(w);
    }

    /// 미뤄 둔 채널 송신과 흐름 제어 보충. **재키잉 중에는 아무것도 안 보낸다**(계약 §3.0.1).
    fn flushDeferred(self: *Client, w: *Out) Error!void {
        if (!self.t.canSendChannelMessages()) return;
        var buf: [256]u8 = undefined;
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
