//! 전송 루프 — 시퀀스 번호·`NEWKEYS` 전환·strict KEX 수신 게이트.
//!
//! **sans-io 다**(계약 §2). 선에서 온 바이트를 받아 패킷 하나를 꺼내고, payload 를 받아 보낼
//! 바이트를 만든다. 소켓은 L4 가 든다.
//!
//! 이 층이 있는 이유는 **아래 두 모듈이 각자로는 못 지키는 성질**이 있어서다:
//!   - `packet.zig`·`cipher.zig` 는 패킷 **하나**를 안다. 시퀀스 번호는 연결 전체의 상태다.
//!   - 평문 구간과 암호 구간의 프레이밍이 다른데, 그 전환점(`NEWKEYS`)은 방향마다 따로 온다.
//!   - strict KEX 의 요구 넷 중 셋은 **"지금까지 무엇을 받았나" 를 기억해야** 판정된다.
//!
//! **시퀀스 번호는 방향마다 따로 센다.** 보낸 패킷마다 `send_seq` 가, 받은 패킷마다 `recv_seq` 가
//! 오른다 — **버리는 패킷도 센다**(RFC 4253 §7.1 의 추측 패킷, `SSH_MSG_IGNORE` 전부). 여기서
//! 하나만 빠뜨리면 그 뒤 **모든** AEAD 태그가 어긋나고, 증상은 KEX 가 아니라 한참 뒤 채널
//! 데이터에서 나온다(계약 §4.3).
//!
//! **`NEWKEYS` 는 옛 키로 보내고 그 직후에 바꾼다**(RFC 4253 §7.3). strict KEX 면 같은 자리에서
//! 시퀀스 번호를 0 으로 리셋한다(draft §3.3) — 보내는 쪽과 받는 쪽이 **각각** 자기 것을 리셋한다.

const std = @import("std");
const packet = @import("packet.zig");
const cipher = @import("cipher.zig");

/// KEX 구간에서 허용되는 메시지 번호(draft §3.2). 우리는 ECDH 만 하므로 목록이 짧다 —
/// 여기 없는 번호가 초기 KEX 중에 오면 **연결을 끊는다**.
pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_unimplemented: u8 = 3;
pub const msg_debug: u8 = 4;
pub const msg_kexinit: u8 = 20;
pub const msg_newkeys: u8 = 21;
pub const msg_kex_ecdh_init: u8 = 30;
pub const msg_kex_ecdh_reply: u8 = 31;

pub const Error = error{
    /// strict KEX 중에 KEX 메시지가 아닌 것이 왔다(draft §3.2 — 끊는다).
    NonKexMessageDuringInitialKex,
    /// 상대의 **첫 메시지**가 KEXINIT 이 아니었다(draft §3.2 — 사후 검사).
    FirstMessageNotKexInit,
    /// 초기 KEX 가 끝나기 전에 시퀀스 번호가 한 바퀴 돌았다(draft §3.2).
    SequenceWrapBeforeKexComplete,
    /// KEX 메시지가 예상보다 여러 번 왔다(draft §3.2 — "the expected number of times").
    DuplicateKexMessage,
    /// 암호 구간인데 키가 없다(또는 그 반대) — 전환 순서가 어긋났다.
    WrongPhase,
} || packet.Error || cipher.Error;

/// 연결이 어느 구간인가. **strict KEX 의 판정이 이 값에 달렸다.**
pub const Phase = enum {
    /// 초기 KEX — strict KEX 면 여기서 KEX 메시지 말고는 못 받는다.
    initial_kex,
    /// 초기 KEX 완료. 이후 재키잉은 이 상태에서 시작한다.
    established,
};

/// 꺼낸 패킷 하나.
pub const Received = struct {
    /// 메시지 번호부터. **`out` 안을 가리킨다.**
    payload: []const u8,
    /// 선 버퍼에서 먹은 바이트 수. 호출자는 그만큼 앞으로 민다.
    consumed: usize,
    /// 이 패킷에 매겨진 시퀀스 번호. `SSH_MSG_UNIMPLEMENTED` 로 되돌려 줄 때 쓴다(draft §3.3).
    seq: u32,
};

pub const Transport = struct {
    send_seq: u32 = 0,
    recv_seq: u32 = 0,
    /// 암호가 붙기 전에는 `null` 이고, 그동안은 `packet.zig` 의 평문 프레이밍을 쓴다.
    send_cipher: ?cipher.Cipher = null,
    recv_cipher: ?cipher.Cipher = null,
    strict_kex: bool = false,
    phase: Phase = .initial_kex,
    /// 상대에게서 패킷을 하나라도 받았나 — 첫 것이 KEXINIT 이었는지 되짚기 위해 든다.
    got_first_from_peer: bool = false,
    /// **추측 패킷 하나를 버려야 한다**(RFC 4253 §7.1). `kexinit.negotiate` 의 `discard_guess`
    /// 를 여기 넣어 두면 다음 패킷을 먹되 **시퀀스 번호는 올린다**.
    pending_discard: bool = false,
    /// 초기 KEX 동안 각 KEX 메시지를 몇 번 받았나(draft §3.2 — 정해진 횟수만 받는다).
    seen_kexinit: u8 = 0,
    seen_ecdh_reply: u8 = 0,

    /// payload 하나를 선에 나갈 바이트로 만든다. **시퀀스 번호를 여기서 올린다.**
    ///
    /// `NEWKEYS` 를 보낼 때도 그냥 부르면 된다 — 그 패킷은 **옛 키로** 나가야 하고, 전환은
    /// 호출자가 그 뒤에 `enableSendKeys` 로 한다(RFC 4253 §7.3).
    pub fn send(
        self: *Transport,
        out: []u8,
        payload: []const u8,
        rand: std.Random,
    ) Error!usize {
        const n = if (self.send_cipher) |c|
            try c.seal(out, self.send_seq, payload, rand)
        else
            try packet.write(out, payload, rand);
        self.send_seq +%= 1;
        return n;
    }

    /// 보낼 바이트 수를 미리 묻는다(버퍼를 잡기 전에).
    pub fn sendLen(self: Transport, payload_len: usize) usize {
        return if (self.send_cipher != null)
            cipher.Cipher.sealedLen(payload_len)
        else
            packet.writtenLen(payload_len);
    }

    /// 선 버퍼에서 패킷 하나를 꺼낸다. **덜 왔으면 `null`** 이다(오류가 아니라 상태).
    ///
    /// `out` 은 payload 를 담을 자리다(암호 구간에서 복호 결과가 여기 들어간다). **`buf` 와
    /// 겹치면 안 된다**(`cipher.open` 주석).
    ///
    /// 시퀀스 번호는 **꺼낸 패킷마다** 오른다 — 버리는 패킷도 마찬가지다.
    pub fn feed(self: *Transport, out: []u8, buf: []const u8) Error!?Received {
        const got = (try self.readOne(out, buf)) orelse return null;
        const seq = self.recv_seq;

        // **번호는 무엇을 하든 오른다.** 아래에서 버리거나 끊더라도 이미 하나 받은 것이다.
        self.recv_seq +%= 1;
        if (self.strict_kex and self.phase == .initial_kex and self.recv_seq == 0) {
            return Error.SequenceWrapBeforeKexComplete;
        }

        const msg = got.payload[0];

        // **첫 패킷은 KEXINIT 이어야 한다**(draft §3.2 — 사후 검사라 여기서 한 번만 본다).
        if (!self.got_first_from_peer) {
            self.got_first_from_peer = true;
            if (self.strict_kex and msg != msg_kexinit) return Error.FirstMessageNotKexInit;
        }

        // **추측 패킷을 버린다**(RFC 4253 §7.1). 번호는 이미 올렸다 — 그것이 이 순서의 요점이다.
        if (self.pending_discard) {
            self.pending_discard = false;
            return .{ .payload = got.payload[0..0], .consumed = got.consumed, .seq = seq };
        }

        if (self.strict_kex and self.phase == .initial_kex) {
            if (!isKexMessage(msg)) return Error.NonKexMessageDuringInitialKex;
            // **정해진 횟수만 받는다**(draft §3.2). 서버 KEXINIT 과 ECDH_REPLY 는 각 한 번이다.
            switch (msg) {
                msg_kexinit => {
                    self.seen_kexinit += 1;
                    if (self.seen_kexinit > 1) return Error.DuplicateKexMessage;
                },
                msg_kex_ecdh_reply => {
                    self.seen_ecdh_reply += 1;
                    if (self.seen_ecdh_reply > 1) return Error.DuplicateKexMessage;
                },
                else => {},
            }
        }

        return .{ .payload = got.payload, .consumed = got.consumed, .seq = seq };
    }

    /// 우리가 `NEWKEYS` 를 **보낸 직후** 부른다. 그 패킷은 옛 키로 나갔고 여기서 새 키로 바꾼다.
    pub fn enableSendKeys(self: *Transport, c: cipher.Cipher) void {
        if (self.send_cipher) |*old| old.clear();
        self.send_cipher = c;
        // strict KEX 면 보내는 번호를 0 으로 리셋한다(draft §3.3).
        if (self.strict_kex) self.send_seq = 0;
        self.settlePhase();
    }

    /// 상대의 `NEWKEYS` 를 **받은 직후** 부른다.
    pub fn enableRecvKeys(self: *Transport, c: cipher.Cipher) void {
        if (self.recv_cipher) |*old| old.clear();
        self.recv_cipher = c;
        if (self.strict_kex) self.recv_seq = 0;
        self.settlePhase();
    }

    /// 양쪽 키가 다 붙으면 초기 KEX 가 끝난 것이다 — 이후에는 §3.2 의 제한이 안 걸린다.
    ///
    /// **두 함수 모두 이것을 불러야 한다.** `NEWKEYS` 를 주고받는 순서는 정해져 있지 않아서,
    /// 받는 쪽에서만 판정하면 "받고 나서 보낸" 연결이 영원히 `initial_kex` 에 갇힌다 — 그러면
    /// 정상 트래픽(`SSH_MSG_IGNORE`·채널 데이터)이 전부 §3.2 위반으로 끊긴다.
    fn settlePhase(self: *Transport) void {
        if (self.send_cipher != null and self.recv_cipher != null) self.phase = .established;
    }

    /// 키를 전부 지운다. 연결이 끝날 때 부른다.
    pub fn clear(self: *Transport) void {
        if (self.send_cipher) |*c| c.clear();
        if (self.recv_cipher) |*c| c.clear();
        self.send_cipher = null;
        self.recv_cipher = null;
    }

    fn readOne(self: Transport, out: []u8, buf: []const u8) Error!?packet.Decoded {
        const c = self.recv_cipher orelse {
            const dec = packet.read(buf) catch |err| switch (err) {
                packet.Error.Incomplete => return null,
                else => return err,
            };
            return dec;
        };
        // 암호 구간: 길이 먼저, 그 다음 몸통 + 태그가 다 왔는지 본다.
        if (buf.len < cipher.length_len) return null;
        const body_len = try c.decryptLength(self.recv_seq, buf[0..cipher.length_len].*);
        const total = cipher.length_len + body_len + cipher.tag_len;
        if (buf.len < total) return null;
        const payload = try c.open(out, self.recv_seq, buf[0..total]);
        return .{ .payload = payload, .consumed = total };
    }
};

/// draft §3.2 의 허용 목록. **우리는 ECDH 만 하므로** 그 밖의 KEX 메시지는 애초에 안 온다 —
/// 온다면 협상하지 않은 알고리즘의 것이라 거절이 맞다.
fn isKexMessage(msg: u8) bool {
    return switch (msg) {
        msg_kexinit, msg_newkeys, msg_kex_ecdh_init, msg_kex_ecdh_reply => true,
        else => false,
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

const test_key: [cipher.key_len]u8 = @splat(0x5a);

fn plainKexInit(out: []u8, rand: std.Random) []const u8 {
    return out[0..(packet.write(out, &[_]u8{msg_kexinit} ++ [_]u8{0} ** 16, rand) catch unreachable)];
}

test "시퀀스 번호는 방향마다 따로 오른다" {
    var prng = std.Random.DefaultPrng.init(1);
    var t: Transport = .{};
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    _ = try t.send(&out, &[_]u8{msg_ignore}, prng.random());
    _ = try t.send(&out, &[_]u8{msg_ignore}, prng.random());
    try std.testing.expectEqual(@as(u32, 2), t.send_seq);
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq); // 받은 것은 없다

    const wire_bytes = plainKexInit(&out, prng.random());
    const got = (try t.feed(&plain, wire_bytes)).?;
    try std.testing.expectEqual(@as(u32, 0), got.seq); // 첫 수신은 0 번
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
    try std.testing.expectEqual(@as(u32, 2), t.send_seq); // 보내는 쪽은 안 움직인다
}

test "덜 온 바이트는 null 이다 (평문·암호 둘 다)" {
    var prng = std.Random.DefaultPrng.init(2);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{};
    const wire_bytes = plainKexInit(&out, prng.random());
    var i: usize = 0;
    while (i < wire_bytes.len) : (i += 1) {
        try std.testing.expectEqual(@as(?Received, null), try t.feed(&plain, wire_bytes[0..i]));
        try std.testing.expectEqual(@as(u32, 0), t.recv_seq); // **안 받았으면 안 센다**
    }
    _ = (try t.feed(&plain, wire_bytes)).?;

    // 암호 구간도 같다 — 길이 필드조차 덜 온 경우와 몸통이 덜 온 경우 둘 다.
    var e: Transport = .{ .recv_cipher = cipher.Cipher.init(test_key) };
    var sender = cipher.Cipher.init(test_key);
    const n = try sender.seal(&out, 0, &[_]u8{msg_ignore} ++ "hello".*, prng.random());
    i = 0;
    while (i < n) : (i += 1) {
        try std.testing.expectEqual(@as(?Received, null), try e.feed(&plain, out[0..i]));
        try std.testing.expectEqual(@as(u32, 0), e.recv_seq);
    }
    _ = (try e.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u32, 1), e.recv_seq);
}

test "NEWKEYS 전환: 옛 키로 보내고 그 다음 바꾼다" {
    var prng = std.Random.DefaultPrng.init(3);
    var t: Transport = .{ .strict_kex = true };
    var out: [256]u8 = undefined;

    // 평문 구간에서 몇 개 보낸 뒤 NEWKEYS.
    _ = try t.send(&out, &[_]u8{msg_kexinit}, prng.random());
    const newkeys_len = try t.send(&out, &[_]u8{msg_newkeys}, prng.random());
    // **그 패킷은 평문 프레이밍이어야 한다** — 전환이 먼저 일어나면 서버가 못 읽는다.
    try std.testing.expectEqual(packet.writtenLen(1), newkeys_len);
    try std.testing.expectEqual(@as(u32, 2), t.send_seq);

    t.enableSendKeys(cipher.Cipher.init(test_key));
    try std.testing.expectEqual(@as(u32, 0), t.send_seq); // strict KEX 리셋(draft §3.3)
    // 이제부터는 암호 프레이밍이다.
    try std.testing.expectEqual(cipher.Cipher.sealedLen(1), t.sendLen(1));
    _ = try t.send(&out, &[_]u8{msg_ignore}, prng.random());
    try std.testing.expectEqual(@as(u32, 1), t.send_seq);
}

test "NEWKEYS 를 받으면 받는 번호도 0 으로 리셋한다" {
    // **0 에서 시작해 0 을 확인하면 아무것도 안 재는 것이다** — 실제로 그 탓에 `recv_seq` 리셋을
    // 지우는 변이가 살아남았다. 평문 구간에서 몇 개 받아 번호를 올려 둔 뒤에 잰다.
    //
    // 리셋이 빠지면 **그 뒤 모든 패킷의 태그가 어긋난다**(상대는 0 부터 세는데 우리는 이어 센다).
    // 그 결과까지 관측한다 — 번호만 보면 "왜 0 이어야 하는지" 가 안 남는다.
    var prng = std.Random.DefaultPrng.init(12);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
    for ([_]u8{ msg_kexinit, msg_kex_ecdh_reply, msg_newkeys }) |msg| {
        const n = try packet.write(&out, &[_]u8{msg}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
    }
    try std.testing.expectEqual(@as(u32, 3), t.recv_seq);

    t.enableRecvKeys(cipher.Cipher.init(test_key));
    t.enableSendKeys(cipher.Cipher.init(test_key)); // 우리도 NEWKEYS 를 보냈다 → established
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq);

    // 상대는 `NEWKEYS` 뒤 첫 패킷을 **0 번으로** 봉인한다. 우리가 0 으로 안 돌아갔으면 태그가
    // 안 맞아 여기서 깨진다 — 번호만 보면 "왜 0 이어야 하는지" 가 안 남으므로 그 결과까지 잰다.
    var server_send = cipher.Cipher.init(test_key);
    const n = try server_send.seal(&out, 0, &[_]u8{ 94, 0, 0, 0, 1 }, prng.random());
    const got = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u32, 0), got.seq);
    try std.testing.expectEqual(@as(u8, 94), got.payload[0]);
}

test "strict KEX 가 아니면 번호를 리셋하지 않는다" {
    // draft §3.3 은 strict KEX 일 때의 규칙이다. 아니면 번호가 계속 오른다 — 잘못 리셋하면
    // 상대와 어긋나 그 뒤 모든 태그가 깨진다.
    var prng = std.Random.DefaultPrng.init(4);
    var t: Transport = .{ .strict_kex = false };
    var out: [256]u8 = undefined;
    _ = try t.send(&out, &[_]u8{msg_kexinit}, prng.random());
    _ = try t.send(&out, &[_]u8{msg_newkeys}, prng.random());
    t.enableSendKeys(cipher.Cipher.init(test_key));
    try std.testing.expectEqual(@as(u32, 2), t.send_seq);

    t.enableRecvKeys(cipher.Cipher.init(test_key));
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq); // 받은 것이 없어 0 일 뿐이다
}

test "양방향 왕복 — 보낸 쪽 번호와 받는 쪽 번호가 맞물린다" {
    var prng = std.Random.DefaultPrng.init(5);
    var client: Transport = .{
        .send_cipher = cipher.Cipher.init(test_key),
        .recv_cipher = cipher.Cipher.init(test_key),
        .phase = .established,
    };
    var server: Transport = .{
        .send_cipher = cipher.Cipher.init(test_key),
        .recv_cipher = cipher.Cipher.init(test_key),
        .phase = .established,
        .got_first_from_peer = true,
    };
    var out: [512]u8 = undefined;
    var plain: [512]u8 = undefined;

    // 번호가 함께 올라야 태그가 맞는다 — 여러 번 돌려 어긋남이 누적되는지 본다.
    for (0..8) |i| {
        const payload = [_]u8{ msg_ignore, @intCast(i) };
        const n = try client.send(&out, &payload, prng.random());
        const got = (try server.feed(&plain, out[0..n])).?;
        try std.testing.expectEqualSlices(u8, &payload, got.payload);
        try std.testing.expectEqual(@as(u32, @intCast(i)), got.seq);
    }
    try std.testing.expectEqual(@as(u32, 8), client.send_seq);
    try std.testing.expectEqual(@as(u32, 8), server.recv_seq);
}

test "strict KEX: 초기 KEX 중 KEX 아닌 메시지는 끊는다" {
    // draft §3.2 의 MUST. `SSH_MSG_IGNORE`·`DEBUG` 도 이 구간에서는 허용되지 않는다 —
    // Terrapin 은 바로 그 여분 메시지로 시퀀스 번호를 밀어 넣는 공격이다.
    var prng = std.Random.DefaultPrng.init(6);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    for ([_]u8{ msg_ignore, msg_debug, msg_unimplemented, 50, 80 }) |bad| {
        var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
        const n = try packet.write(&out, &[_]u8{bad}, prng.random());
        try std.testing.expectError(Error.NonKexMessageDuringInitialKex, t.feed(&plain, out[0..n]));
        // **끊더라도 번호는 이미 올랐다** — 받은 것은 받은 것이다.
        try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
    }

    // KEX 메시지는 통과한다 — 위가 "무조건 거절" 이 아님을 못박는다.
    for ([_]u8{ msg_kexinit, msg_newkeys, msg_kex_ecdh_reply }) |ok| {
        var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
        const n = try packet.write(&out, &[_]u8{ok}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
    }

    // strict KEX 가 아니면 같은 메시지가 정상이다(§3.2 는 언제든 올 수 있다고 한다).
    var loose: Transport = .{ .strict_kex = false, .got_first_from_peer = true };
    const n = try packet.write(&out, &[_]u8{msg_ignore}, prng.random());
    _ = (try loose.feed(&plain, out[0..n])).?;
}

test "strict KEX: 상대의 첫 메시지는 KEXINIT 이어야 한다" {
    // draft §3.2 — "implementations MUST verify that the SSH_MSG_KEXINIT was the first
    // message received from the peer". **사후 검사**라 따로 기억해야 한다.
    var prng = std.Random.DefaultPrng.init(7);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true };
    const n = try packet.write(&out, &[_]u8{msg_kex_ecdh_reply}, prng.random()); // KEX 메시지지만 첫 것이 아니어야 한다
    try std.testing.expectError(Error.FirstMessageNotKexInit, t.feed(&plain, out[0..n]));

    // KEXINIT 이 먼저면 그 뒤 KEX 메시지는 정상이다.
    var ok: Transport = .{ .strict_kex = true };
    const k = try packet.write(&out, &[_]u8{msg_kexinit}, prng.random());
    _ = (try ok.feed(&plain, out[0..k])).?;
    const r = try packet.write(&out, &[_]u8{msg_kex_ecdh_reply}, prng.random());
    _ = (try ok.feed(&plain, out[0..r])).?;

    // strict KEX 가 아니면 이 검사를 안 한다.
    var loose: Transport = .{ .strict_kex = false };
    const l = try packet.write(&out, &[_]u8{msg_kex_ecdh_reply}, prng.random());
    _ = (try loose.feed(&plain, out[0..l])).?;
}

test "strict KEX: 같은 KEX 메시지를 두 번 받지 않는다" {
    // draft §3.2 — "any message permitted during KEX can be only accepted the expected
    // number of times". 서버 KEXINIT 과 ECDH_REPLY 는 각각 한 번이다.
    var prng = std.Random.DefaultPrng.init(8);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    for ([_]u8{ msg_kexinit, msg_kex_ecdh_reply }) |msg| {
        var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
        const n = try packet.write(&out, &[_]u8{msg}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
        try std.testing.expectError(Error.DuplicateKexMessage, t.feed(&plain, out[0..n]));
    }

    // `NEWKEYS` 는 이 계수 대상이 아니다(재키잉마다 다시 온다) — 두 번 와도 여기서는 안 막는다.
    var nk: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
    const n = try packet.write(&out, &[_]u8{msg_newkeys}, prng.random());
    _ = (try nk.feed(&plain, out[0..n])).?;
    _ = (try nk.feed(&plain, out[0..n])).?;
}

test "strict KEX: 초기 KEX 전에 번호가 한 바퀴 돌면 끊는다" {
    // draft §3.2 의 사후 검사. 실제로 2^32 개를 받아 볼 수는 없으므로 번호를 끝에 놓고 잰다.
    var prng = std.Random.DefaultPrng.init(9);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{
        .strict_kex = true,
        .got_first_from_peer = true,
        .recv_seq = std.math.maxInt(u32),
    };
    const n = try packet.write(&out, &[_]u8{msg_kexinit}, prng.random());
    try std.testing.expectError(Error.SequenceWrapBeforeKexComplete, t.feed(&plain, out[0..n]));

    // 초기 KEX 가 끝난 뒤에는 감싸 도는 것이 정상이다(재키잉이 그 전에 일어나야 하지만,
    // 그 정책은 이 층이 아니라 상위의 것이다).
    var done: Transport = .{
        .strict_kex = true,
        .got_first_from_peer = true,
        .phase = .established,
        .recv_seq = std.math.maxInt(u32),
    };
    _ = (try done.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u32, 0), done.recv_seq);
}

test "추측 패킷은 먹되 번호는 올린다" {
    // RFC 4253 §7.1 — 서버 추측이 틀렸으면 다음 패킷 하나를 조용히 버린다. **버려도 받은 것은
    // 받은 것이라 번호는 오른다**(계약 §4). 여기서 안 올리면 그 뒤 모든 태그가 어긋난다.
    var prng = std.Random.DefaultPrng.init(10);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true, .pending_discard = true };
    // 버릴 패킷은 **KEX 메시지가 아니어도** 된다 — 버리는 것이 먼저라 §3.2 검사에 안 걸린다.
    const n = try packet.write(&out, &[_]u8{msg_kex_ecdh_reply}, prng.random());
    const got = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(usize, 0), got.payload.len); // 빈 payload = 버렸다는 뜻
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
    try std.testing.expect(!t.pending_discard); // 한 번만 버린다

    // 그 다음 패킷은 정상으로 처리된다 — 그리고 이번엔 §3.2 계수에 잡힌다.
    const got2 = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(usize, 1), got2.payload.len);
    try std.testing.expectEqual(@as(u32, 1), got2.seq);
    try std.testing.expectEqual(@as(u32, 2), t.recv_seq);
}

test "양쪽 키가 붙어야 established 이고 순서를 안 탄다" {
    // **`NEWKEYS` 를 주고받는 순서는 정해져 있지 않다.** 처음에는 받는 쪽에서만 판정했는데,
    // 그러면 "받고 나서 보낸" 연결이 영원히 `initial_kex` 에 갇혀 정상 트래픽이 전부 §3.2
    // 위반으로 끊긴다. 두 순서를 다 잰다.
    for ([_]bool{ true, false }) |recv_first| {
        var t: Transport = .{ .strict_kex = true };
        try std.testing.expectEqual(Phase.initial_kex, t.phase);
        if (recv_first) {
            t.enableRecvKeys(cipher.Cipher.init(test_key));
            try std.testing.expectEqual(Phase.initial_kex, t.phase); // 한쪽만으로는 아니다
            t.enableSendKeys(cipher.Cipher.init(test_key));
        } else {
            t.enableSendKeys(cipher.Cipher.init(test_key));
            try std.testing.expectEqual(Phase.initial_kex, t.phase);
            t.enableRecvKeys(cipher.Cipher.init(test_key));
        }
        try std.testing.expectEqual(Phase.established, t.phase);
    }
}

test "established 뒤에는 KEX 아닌 메시지가 정상이다" {
    // 위 결함의 **관측 가능한 결과**가 이것이다 — phase 가 안 넘어가면 여기서 연결이 끊긴다.
    var prng = std.Random.DefaultPrng.init(11);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true, .got_first_from_peer = true };
    t.enableRecvKeys(cipher.Cipher.init(test_key));
    t.enableSendKeys(cipher.Cipher.init(test_key));

    var sender = cipher.Cipher.init(test_key);
    const n = try sender.seal(&out, 0, &[_]u8{ 94, 0, 0, 0, 0 }, prng.random()); // CHANNEL_DATA
    const got = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u8, 94), got.payload[0]);
}

test "clear 는 양쪽 키를 지운다" {
    var t: Transport = .{
        .send_cipher = cipher.Cipher.init(test_key),
        .recv_cipher = cipher.Cipher.init(test_key),
    };
    t.clear();
    try std.testing.expectEqual(@as(?cipher.Cipher, null), t.send_cipher);
    try std.testing.expectEqual(@as(?cipher.Cipher, null), t.recv_cipher);
}

test "메시지 번호는 명세 값 그대로다" {
    // 상수를 쓰는 쪽과 읽는 쪽에 함께 쓰면 자기충족이다(앞선 슬라이스들에서 실제로 겪었다).
    try std.testing.expectEqual(@as(u8, 1), msg_disconnect); // RFC 4253 §12
    try std.testing.expectEqual(@as(u8, 2), msg_ignore);
    try std.testing.expectEqual(@as(u8, 3), msg_unimplemented);
    try std.testing.expectEqual(@as(u8, 4), msg_debug);
    try std.testing.expectEqual(@as(u8, 20), msg_kexinit);
    try std.testing.expectEqual(@as(u8, 21), msg_newkeys);
    try std.testing.expectEqual(@as(u8, 30), msg_kex_ecdh_init); // RFC 5656 §7.1
    try std.testing.expectEqual(@as(u8, 31), msg_kex_ecdh_reply);
}
