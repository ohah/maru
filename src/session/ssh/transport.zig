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
    /// 메시지 번호부터. **언제나 `out` 안을 가리키고 최소 1바이트다.**
    ///
    /// 평문 구간과 암호 구간이 **같은 소유자**를 갖게 하려고 평문도 `out` 으로 복사한다. 처음에는
    /// 평문 경로가 `packet.read` 의 슬라이스를 그대로 돌려줬는데, 그것은 **호출자의 입력 버퍼**를
    /// 가리킨다 — 문서대로 `consumed` 만큼 버퍼를 미는 드라이버가 자기가 들고 있는 `I_S`·`K_S`·
    /// `Q_S` 를 memmove 로 덮어쓰고, 그러면 교환 해시가 틀려 **증상이 중간자와 구별되지 않는다**.
    /// 초기 KEX 전체가 그 구간이라 실서버에서만 드러난다.
    payload: []const u8,
    /// 선 버퍼에서 먹은 바이트 수. 호출자는 그만큼 앞으로 민다.
    consumed: usize,
    /// 이 패킷에 매겨진 시퀀스 번호. `SSH_MSG_UNIMPLEMENTED` 로 되돌려 줄 때 쓴다(draft §3.3).
    seq: u32,
    /// **버린 추측 패킷이다**(RFC 4253 §7.1). 참이면 `payload` 를 보지 않는다 — 빈 슬라이스로
    /// 알리던 옛 방식은 `payload.len >= 1` 불변을 깨서, 문서대로 `payload[0]` 을 보는 드라이버가
    /// 정상 핸드셰이크에서 죽었다.
    discarded: bool = false,
};

pub const Transport = struct {
    send_seq: u32 = 0,
    recv_seq: u32 = 0,
    /// 암호가 붙기 전에는 `null` 이고, 그동안은 `packet.zig` 의 평문 프레이밍을 쓴다.
    send_cipher: ?cipher.Cipher = null,
    recv_cipher: ?cipher.Cipher = null,
    strict_kex: bool = false,
    phase: Phase = .initial_kex,
    /// 상대에게서 받은 **첫 메시지 번호**. `null` 이면 아직 아무것도 안 받았다.
    /// strict 여부와 무관하게 기록해 두고 `enableStrictKex` 가 되짚는다.
    first_from_peer: ?u8 = null,
    /// **추측 패킷 하나를 버려야 한다**(RFC 4253 §7.1). `kexinit.negotiate` 의 `discard_guess`
    /// 를 여기 넣어 두면 다음 패킷을 먹되 **시퀀스 번호는 올린다**.
    pending_discard: bool = false,
    /// 초기 KEX 동안 각 KEX 메시지를 몇 번 받았나(draft §3.2 — 정해진 횟수만 받는다).
    seen_kexinit: u8 = 0,
    seen_ecdh_reply: u8 = 0,
    seen_newkeys: u8 = 0,

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
        // **wrap 금지에는 방향 한정이 없다**(draft §3.2). 받는 쪽만 재면 보내는 쪽이 조용히 감싸 돈다.
        if (self.strict_kex and self.phase == .initial_kex and self.send_seq == 0) {
            return Error.SequenceWrapBeforeKexComplete;
        }
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
        const got = (self.readOne(out, buf) catch |err| {
            // **`Incomplete` 만 "아직 안 왔다" 다.** 프레이밍이 깨졌거나 태그가 틀린 것은 **이미
            // 받은 패킷**이므로 번호를 올려야 한다(계약 §4.5 는 예외 없이 "받은 것은 센다" 다).
            // 안 올리면 그 오류를 복구 가능으로 다루는 드라이버가 영구히 어긋나고, 이후 모든
            // AEAD 태그가 실패하는데 증상은 한참 뒤 채널 데이터에서 나온다.
            // **`ShortBuffer` 도 예외다 — 이것은 상대가 아니라 우리 얘기다.** 패킷은 멀쩡히
            // 왔고 우리 `out` 이 작았을 뿐이라, 드라이버가 할 자연스러운 일은 **큰 버퍼로 같은
            // 바이트를 다시 먹이는 것**이다(`consumed` 를 안 돌려줬으니 입력도 그대로다). 세
            // 버리면 그 재시도에서 번호가 두 번 올라 이후 모든 AEAD 태그가 어긋난다 — 고치려던
            // 결함과 똑같은 증상을, 이번엔 수정이 만든다.
            if (err != packet.Error.Incomplete and err != Error.ShortBuffer) self.recv_seq +%= 1;
            return err;
        }) orelse return null;
        const seq = self.recv_seq;

        // **번호는 무엇을 하든 오른다.** 아래에서 버리거나 끊더라도 이미 하나 받은 것이다.
        self.recv_seq +%= 1;
        if (self.strict_kex and self.phase == .initial_kex and self.recv_seq == 0) {
            return Error.SequenceWrapBeforeKexComplete;
        }

        const msg = got.payload[0];

        // **첫 메시지는 strict 여부와 무관하게 기억한다.** `strict_kex` 는 서버 KEXINIT 에서
        // 유도되므로 그 첫 패킷을 먹는 시점에는 **반드시 false** 다 — 여기서 조건부로 검사하면
        // draft §3.2 의 MUST 가 영영 발동하지 않는다(Terrapin 의 prefix injection 모양이다).
        // 판정은 `enableStrictKex` 가 사후에 한다.
        if (self.first_from_peer == null) self.first_from_peer = msg;

        // **계수도 strict 와 무관하게 센다.** 진짜 서버 KEXINIT 은 strict 가 켜지기 **전에**
        // 오므로, 켜진 뒤에만 세면 그것이 계수기에 안 닿아 주입된 두 번째가 0→1 로 통과한다.
        switch (msg) {
            msg_kexinit => self.seen_kexinit +|= 1,
            msg_kex_ecdh_reply => self.seen_ecdh_reply +|= 1,
            msg_newkeys => self.seen_newkeys +|= 1,
            else => {},
        }

        if (self.strict_kex and self.phase == .initial_kex) {
            // **허용 목록을 먼저 본다** — 버릴 패킷도 §3.2 의 허용 목록에 들어야 한다. 폐기를
            // 앞에 두면 공격자가 고른 임의 패킷 하나가 초기 KEX 에 조용히 수용된다.
            if (!isKexMessage(msg)) return Error.NonKexMessageDuringInitialKex;
            // **정해진 횟수만 받는다**(draft §3.2 — "can be only accepted the expected number of
            // times"). 초기 KEX 에서 클라이언트가 서버에게 받는 것은 **각각 한 번씩**이다.
            //
            // **셋을 다 세야 한다.** 처음에는 `NEWKEYS` 를 "재키잉마다 다시 오니까" 라며 안 셌는데,
            // 그 말은 초기 KEX **밖**의 얘기였다 — 이 구간에서는 한 번뿐이고, 안 세면 상대가 그것을
            // 무한히 보내 **`recv_seq` 를 아무 값으로나 밀 수 있다**. 게다가 상위가 그때마다
            // `enableRecvKeys` 를 부르면 번호가 다시 0 으로 리셋되어, 그 뒤 모든 태그가 어긋난다.
            const seen = switch (msg) {
                msg_kexinit => self.seen_kexinit,
                msg_kex_ecdh_reply => self.seen_ecdh_reply,
                msg_newkeys => self.seen_newkeys,
                else => unreachable, // `isKexMessage` 가 통과시킨 것은 이 셋뿐이다
            };
            if (seen > 1) return Error.DuplicateKexMessage;
        }

        // **폐기는 게이트 뒤다**(위 주석). 버린 패킷은 "받아들인" 것이 아니므로 계수에는 넣지
        // 않는다 — 위 계수는 이미 올라갔으니 여기서 되돌린다.
        if (self.pending_discard) {
            self.pending_discard = false;
            switch (msg) {
                msg_kexinit => self.seen_kexinit -|= 1,
                msg_kex_ecdh_reply => self.seen_ecdh_reply -|= 1,
                msg_newkeys => self.seen_newkeys -|= 1,
                else => {},
            }
            return .{ .payload = got.payload, .consumed = got.consumed, .seq = seq, .discarded = true };
        }

        return .{ .payload = got.payload, .consumed = got.consumed, .seq = seq };
    }

    /// strict KEX 를 켠다. **사후 검사가 여기서 돈다**(draft §3.2).
    ///
    /// `strict_kex` 를 필드에 그냥 쓰면 안 되는 이유가 이것이다 — 그 값은 서버 KEXINIT 을 읽고 나서야
    /// 정해지는데, "상대의 첫 메시지가 KEXINIT 이었나" 는 **그보다 앞선 일**을 되짚는 물음이다.
    pub fn enableStrictKex(self: *Transport) Error!void {
        if (self.first_from_peer) |first| {
            if (first != msg_kexinit) return Error.FirstMessageNotKexInit;
        }
        self.strict_kex = true;
    }

    /// 우리가 `NEWKEYS` 를 **보낸 직후** 부른다. 그 패킷은 옛 키로 나갔고 여기서 새 키로 바꾼다.
    ///
    /// **`c` 를 가져온다** — 호출자의 것은 여기서 지워진다(`Cipher.initMove` 와 같은 이유: 값으로
    /// 받으면 아무도 주소를 모르는 키 사본이 스택에 남는다). 재키잉마다 한 벌씩 쌓이는 자리다.
    pub fn enableSendKeys(self: *Transport, c: *cipher.Cipher) void {
        defer c.clear();
        // **이 한 줄은 변이 검사로 못 잡는다 — 증명 가능한 등가라서다.** 바로 다음 대입이 같은
        // 자리를 통째로 덮어써서 옛 키 바이트는 어차피 사라진다. 그래도 남겨 둔다: 대입이 언젠가
        // 조건부가 되면 그때는 등가가 아니게 되고, 그 변화는 눈에 안 띈다.
        if (self.send_cipher) |*old| old.clear();
        self.send_cipher = c.*;
        // strict KEX 면 보내는 번호를 0 으로 리셋한다(draft §3.3).
        if (self.strict_kex) self.send_seq = 0;
        self.settlePhase();
    }

    /// 상대의 `NEWKEYS` 를 **받은 직후** 부른다. `c` 를 가져온다(위와 같다).
    pub fn enableRecvKeys(self: *Transport, c: *cipher.Cipher) void {
        defer c.clear();
        if (self.recv_cipher) |*old| old.clear();
        self.recv_cipher = c.*;
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
            // **평문도 `out` 으로 옮긴다** — 소유자가 구간마다 달라지면 안 된다(`Received.payload`
            // 주석의 실측). 초기 KEX 는 패킷이 몇 개뿐이라 이 복사는 비용이 아니다.
            if (out.len < dec.payload.len) return Error.ShortBuffer;
            @memcpy(out[0..dec.payload.len], dec.payload);
            return .{ .payload = out[0..dec.payload.len], .consumed = dec.consumed };
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

/// draft §3.2 의 허용 목록 중 **클라이언트가 받을 수 있는 것만**이다.
///
/// **`SSH_MSG_KEX_ECDH_INIT`(30)은 없다.** 그것은 클라이언트가 **보내는** 메시지라 우리가 받을
/// 일이 없다 — 목록에 두면 상대가 그것을 무한히 보내 `recv_seq` 를 아무 값으로나 밀 수 있고,
/// 그 시퀀스 번호 조작이 정확히 strict KEX 가 없애려는 것이다(draft §3).
///
/// 우리는 ECDH 만 하므로 그 밖의 KEX 알고리즘 메시지도 안 온다 — 온다면 협상하지 않은 것이라
/// 거절이 맞다.
fn isKexMessage(msg: u8) bool {
    return switch (msg) {
        msg_kexinit, msg_newkeys, msg_kex_ecdh_reply => true,
        else => false,
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

const test_key: [cipher.key_len]u8 = @splat(0x5a);

fn plainKexInit(out: []u8, rand: std.Random) []const u8 {
    return out[0..(packet.write(out, &[_]u8{msg_kexinit} ++ [_]u8{0} ** 16, rand) catch unreachable)];
}

/// 테스트용: 고정 키 `Cipher`. `initMove`/`enable*Keys` 가 원본을 지우므로 매번 새로 만든다.
fn testCipher() cipher.Cipher {
    var k = test_key;
    return cipher.Cipher.initMove(&k);
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
    var e: Transport = .{ .recv_cipher = testCipher() };
    var sender = testCipher();
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

    {
        var c = testCipher();
        t.enableSendKeys(&c);
    }
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

    var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
    for ([_]u8{ msg_kexinit, msg_kex_ecdh_reply, msg_newkeys }) |msg| {
        const n = try packet.write(&out, &[_]u8{msg}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
    }
    try std.testing.expectEqual(@as(u32, 3), t.recv_seq);

    {
        var c = testCipher();
        t.enableRecvKeys(&c);
    }
    {
        var c = testCipher();
        t.enableSendKeys(&c);
    } // 우리도 NEWKEYS 를 보냈다 → established
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq);

    // 상대는 `NEWKEYS` 뒤 첫 패킷을 **0 번으로** 봉인한다. 우리가 0 으로 안 돌아갔으면 태그가
    // 안 맞아 여기서 깨진다 — 번호만 보면 "왜 0 이어야 하는지" 가 안 남으므로 그 결과까지 잰다.
    var server_send = testCipher();
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
    {
        var c = testCipher();
        t.enableSendKeys(&c);
    }
    try std.testing.expectEqual(@as(u32, 2), t.send_seq);

    {
        var c = testCipher();
        t.enableRecvKeys(&c);
    }
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq); // 받은 것이 없어 0 일 뿐이다
}

test "양방향 왕복 — 보낸 쪽 번호와 받는 쪽 번호가 맞물린다" {
    var prng = std.Random.DefaultPrng.init(5);
    var client: Transport = .{
        .send_cipher = testCipher(),
        .recv_cipher = testCipher(),
        .phase = .established,
    };
    var server: Transport = .{
        .send_cipher = testCipher(),
        .recv_cipher = testCipher(),
        .phase = .established,
        .first_from_peer = msg_kexinit,
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
        var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
        const n = try packet.write(&out, &[_]u8{bad}, prng.random());
        try std.testing.expectError(Error.NonKexMessageDuringInitialKex, t.feed(&plain, out[0..n]));
        // **끊더라도 번호는 이미 올랐다** — 받은 것은 받은 것이다.
        try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
    }

    // KEX 메시지는 통과한다 — 위가 "무조건 거절" 이 아님을 못박는다.
    for ([_]u8{ msg_kexinit, msg_newkeys, msg_kex_ecdh_reply }) |ok| {
        var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
        const n = try packet.write(&out, &[_]u8{ok}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
    }

    // strict KEX 가 아니면 같은 메시지가 정상이다(§3.2 는 언제든 올 수 있다고 한다).
    var loose: Transport = .{ .strict_kex = false, .first_from_peer = msg_kexinit };
    const n = try packet.write(&out, &[_]u8{msg_ignore}, prng.random());
    _ = (try loose.feed(&plain, out[0..n])).?;
}

test "strict KEX: 상대의 첫 메시지는 KEXINIT 이어야 한다" {
    // draft §3.2 — "implementations MUST verify that the SSH_MSG_KEXINIT was the first
    // message received from the peer". **사후 검사라 `strict_kex` 를 켜는 순간에 판정한다.**
    //
    // 처음에는 `feed` 안에서 `if (strict_kex and ...)` 로 봤는데 그것은 **절대 발동하지 않는다** —
    // `strict_kex` 는 서버 KEXINIT 에서 유도되므로 그 첫 패킷을 먹을 때는 반드시 false 다.
    // 즉 `Transport{}` + `feed(DEBUG)` 가 조용히 통과했다(코드리뷰가 잡았고 실측했다).
    var prng = std.Random.DefaultPrng.init(7);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    // 제품이 만들 수 있는 유일한 초기 상태에서 시작한다 — strict 는 아직 꺼져 있다.
    for ([_]u8{ msg_debug, msg_ignore, msg_kex_ecdh_reply, msg_newkeys }) |first| {
        var t: Transport = .{};
        const n = try packet.write(&out, &[_]u8{first}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?; // 그 시점에는 막을 근거가 없다
        try std.testing.expectError(Error.FirstMessageNotKexInit, t.enableStrictKex());
        try std.testing.expect(!t.strict_kex); // 실패했으면 켜지도 않는다
    }

    // KEXINIT 이 먼저였으면 켜진다.
    var ok: Transport = .{};
    const k = try packet.write(&out, &[_]u8{msg_kexinit}, prng.random());
    _ = (try ok.feed(&plain, out[0..k])).?;
    try ok.enableStrictKex();
    try std.testing.expect(ok.strict_kex);

    // **진짜 KEXINIT 이 계수에 들어가 있어야 한다** — strict 가 켜진 뒤에만 세면 주입된 두 번째가
    // 0→1 로 통과한다(같은 뿌리의 결함이다).
    try std.testing.expectError(Error.DuplicateKexMessage, ok.feed(&plain, out[0..k]));

    // 아무것도 안 받은 상태에서 켜는 것은 막지 않는다(그럴 일은 없지만 판정할 근거도 없다).
    var fresh: Transport = .{};
    try fresh.enableStrictKex();
}

test "strict KEX: 같은 KEX 메시지를 두 번 받지 않는다" {
    // draft §3.2 — "any message permitted during KEX can be only accepted the expected
    // number of times". 서버 KEXINIT 과 ECDH_REPLY 는 각각 한 번이다.
    var prng = std.Random.DefaultPrng.init(8);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    for ([_]u8{ msg_kexinit, msg_kex_ecdh_reply }) |msg| {
        var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
        const n = try packet.write(&out, &[_]u8{msg}, prng.random());
        _ = (try t.feed(&plain, out[0..n])).?;
        try std.testing.expectError(Error.DuplicateKexMessage, t.feed(&plain, out[0..n]));
    }

    // **`NEWKEYS` 도 센다.** 처음에는 "재키잉마다 다시 오니까" 라며 안 셌는데, 그 말은 초기 KEX
    // **밖**의 얘기였다 — 이 구간에서는 한 번뿐이고, 안 세면 상대가 무한히 보내 `recv_seq` 를
    // 아무 값으로나 민다. 상위가 그때마다 `enableRecvKeys` 를 부르면 번호가 다시 0 이 되어
    // 그 뒤 모든 태그가 어긋난다(코드리뷰가 잡았고 실측으로 재현했다 — 100개가 다 통과했다).
    var nk: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
    const n = try packet.write(&out, &[_]u8{msg_newkeys}, prng.random());
    _ = (try nk.feed(&plain, out[0..n])).?;
    try std.testing.expectError(Error.DuplicateKexMessage, nk.feed(&plain, out[0..n]));
    try std.testing.expectEqual(@as(u32, 2), nk.recv_seq); // 끊어도 받은 것은 받은 것이다

    // **`SSH_MSG_KEX_ECDH_INIT`(30)은 클라이언트가 보내는 메시지다** — 받을 일이 없으므로 한 번도
    // 안 받는다. 목록에 두면 상대가 무한히 보내 시퀀스 번호를 밀 수 있다.
    var init_msg: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
    const i = try packet.write(&out, &[_]u8{msg_kex_ecdh_init}, prng.random());
    try std.testing.expectError(Error.NonKexMessageDuringInitialKex, init_msg.feed(&plain, out[0..i]));
}

test "strict KEX: 초기 KEX 전에 번호가 한 바퀴 돌면 끊는다" {
    // draft §3.2 의 사후 검사. 실제로 2^32 개를 받아 볼 수는 없으므로 번호를 끝에 놓고 잰다.
    var prng = std.Random.DefaultPrng.init(9);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{
        .strict_kex = true,
        .first_from_peer = msg_kexinit,
        .recv_seq = std.math.maxInt(u32),
    };
    const n = try packet.write(&out, &[_]u8{msg_kexinit}, prng.random());
    try std.testing.expectError(Error.SequenceWrapBeforeKexComplete, t.feed(&plain, out[0..n]));

    // 초기 KEX 가 끝난 뒤에는 감싸 도는 것이 정상이다(재키잉이 그 전에 일어나야 하지만,
    // 그 정책은 이 층이 아니라 상위의 것이다).
    var done: Transport = .{
        .strict_kex = true,
        .first_from_peer = msg_kexinit,
        .phase = .established,
        .recv_seq = std.math.maxInt(u32),
    };
    _ = (try done.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u32, 0), done.recv_seq);
}

test "추측 패킷은 먹되 번호는 올린다" {
    // RFC 4253 §7.1 — 서버 추측이 틀렸으면 다음 패킷 하나를 조용히 버린다. **버려도 받은 것은
    // 받은 것이라 번호는 오른다**(계약 §4).
    var prng = std.Random.DefaultPrng.init(10);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit, .pending_discard = true };
    const n = try packet.write(&out, &[_]u8{msg_kex_ecdh_reply}, prng.random());
    const got = (try t.feed(&plain, out[0..n])).?;
    // **빈 payload 로 알리지 않는다.** 그러면 `payload.len >= 1` 불변이 깨져, 문서대로
    // `payload[0]` 을 보는 드라이버가 정상 핸드셰이크에서 죽는다(코드리뷰가 잡았다).
    try std.testing.expect(got.discarded);
    try std.testing.expectEqual(@as(usize, 1), got.payload.len);
    try std.testing.expectEqual(@as(u8, msg_kex_ecdh_reply), got.payload[0]);
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
    try std.testing.expect(!t.pending_discard); // 한 번만 버린다

    // **버린 것은 "받아들인" 것이 아니라 계수에 안 들어간다** — 그 다음 진짜 REPLY 가 살아야 한다.
    const got2 = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expect(!got2.discarded);
    try std.testing.expectEqual(@as(u32, 1), got2.seq);
    try std.testing.expectEqual(@as(u32, 2), t.recv_seq);
}

test "버릴 패킷도 strict 허용 목록을 지나야 한다" {
    // **폐기가 게이트보다 앞서면** 공격자가 고른 임의 패킷 하나가 초기 KEX 에 조용히 수용된다 —
    // 계약 §4 는 정반대를 적어 뒀다("추측 패킷을 따로 다루지 않고 — §3.2 의 허용 목록에 든
    // KEX 메시지다"). 실측으로 재현했다: IGNORE 가 흡수되고 오류도 안 났다.
    var prng = std.Random.DefaultPrng.init(11);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;
    const n = try packet.write(&out, &[_]u8{msg_ignore}, prng.random());

    var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit, .pending_discard = true };
    try std.testing.expectError(Error.NonKexMessageDuringInitialKex, t.feed(&plain, out[0..n]));
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq); // 끊어도 받은 것은 받은 것이다

    // strict 가 아니면 무엇이든 버릴 수 있다(§3.2 는 strict 일 때의 제한이다).
    var loose: Transport = .{ .first_from_peer = msg_kexinit, .pending_discard = true };
    const got = (try loose.feed(&plain, out[0..n])).?;
    try std.testing.expect(got.discarded);
}

test "양쪽 키가 붙어야 established 이고 순서를 안 탄다" {
    // **`NEWKEYS` 를 주고받는 순서는 정해져 있지 않다.** 처음에는 받는 쪽에서만 판정했는데,
    // 그러면 "받고 나서 보낸" 연결이 영원히 `initial_kex` 에 갇혀 정상 트래픽이 전부 §3.2
    // 위반으로 끊긴다. 두 순서를 다 잰다.
    for ([_]bool{ true, false }) |recv_first| {
        var t: Transport = .{ .strict_kex = true };
        try std.testing.expectEqual(Phase.initial_kex, t.phase);
        if (recv_first) {
            {
                var c = testCipher();
                t.enableRecvKeys(&c);
            }
            try std.testing.expectEqual(Phase.initial_kex, t.phase); // 한쪽만으로는 아니다
            {
                var c = testCipher();
                t.enableSendKeys(&c);
            }
        } else {
            {
                var c = testCipher();
                t.enableSendKeys(&c);
            }
            try std.testing.expectEqual(Phase.initial_kex, t.phase);
            {
                var c = testCipher();
                t.enableRecvKeys(&c);
            }
        }
        try std.testing.expectEqual(Phase.established, t.phase);
    }
}

test "established 뒤에는 KEX 아닌 메시지가 정상이다" {
    // 위 결함의 **관측 가능한 결과**가 이것이다 — phase 가 안 넘어가면 여기서 연결이 끊긴다.
    var prng = std.Random.DefaultPrng.init(11);
    var out: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    var t: Transport = .{ .strict_kex = true, .first_from_peer = msg_kexinit };
    {
        var c = testCipher();
        t.enableRecvKeys(&c);
    }
    {
        var c = testCipher();
        t.enableSendKeys(&c);
    }

    var sender = testCipher();
    const n = try sender.seal(&out, 0, &[_]u8{ 94, 0, 0, 0, 0 }, prng.random()); // CHANNEL_DATA
    const got = (try t.feed(&plain, out[0..n])).?;
    try std.testing.expectEqual(@as(u8, 94), got.payload[0]);
}

test "clear 는 양쪽 키를 지운다" {
    var t: Transport = .{
        .send_cipher = testCipher(),
        .recv_cipher = testCipher(),
    };
    t.clear();
    try std.testing.expectEqual(@as(?cipher.Cipher, null), t.send_cipher);
    try std.testing.expectEqual(@as(?cipher.Cipher, null), t.recv_cipher);
}

test "payload 는 구간과 무관하게 out 을 가리킨다" {
    // **소유자가 구간마다 다르면 안 된다.** 평문 경로가 입력 버퍼를 가리키던 탓에, 문서대로
    // `consumed` 만큼 버퍼를 미는 드라이버가 자기가 들고 있는 `I_S` 를 memmove 로 덮어썼다 —
    // 교환 해시가 틀려 **증상이 중간자와 구별되지 않는다**. 초기 KEX 전체가 그 구간이라
    // 정적 버퍼를 넘기는 헤드리스 테스트로는 안 드러났다(코드리뷰가 잡았다).
    var prng = std.Random.DefaultPrng.init(30);
    var wire_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    inline for (.{ false, true }) |encrypted| {
        var t: Transport = if (encrypted)
            .{ .recv_cipher = testCipher(), .phase = .established, .first_from_peer = msg_kexinit }
        else
            .{};
        const payload = [_]u8{ msg_kexinit, 0xAA, 0xBB, 0xCC };
        const n = if (encrypted) blk: {
            var sender = testCipher();
            break :blk try sender.seal(&wire_buf, 0, &payload, prng.random());
        } else try packet.write(&wire_buf, &payload, prng.random());

        @memset(&out, 0xC7);
        const got = (try t.feed(&out, wire_buf[0..n])).?;
        // `out` 안을 가리킨다.
        try std.testing.expect(@intFromPtr(got.payload.ptr) >= @intFromPtr(&out));
        try std.testing.expect(@intFromPtr(got.payload.ptr) < @intFromPtr(&out) + out.len);
        try std.testing.expectEqualSlices(u8, &payload, got.payload);

        // **입력 버퍼를 밀어도 payload 가 살아 있다** — 그것이 이 계약의 실제 뜻이다.
        @memset(wire_buf[0..n], 0);
        try std.testing.expectEqualSlices(u8, &payload, got.payload);
    }
}

test "out 이 모자라면 조용히 자르지 않는다" {
    var prng = std.Random.DefaultPrng.init(31);
    var wire_buf: [256]u8 = undefined;
    var t: Transport = .{};
    const n = try packet.write(&wire_buf, &[_]u8{ msg_kexinit, 1, 2, 3, 4, 5, 6, 7 }, prng.random());
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, t.feed(&tiny, wire_buf[0..n]));
}

test "readOne 에서 거절된 패킷도 번호를 센다" {
    // 계약 §4.5 는 예외 없이 "받은 것은 센다" 다. `Incomplete` 만 "아직 안 왔다" 이고, 프레이밍이
    // 깨졌거나 태그가 틀린 것은 **이미 받은 패킷**이다 — 안 세면 그 오류를 복구 가능으로 다루는
    // 드라이버가 영구히 어긋나고, 이후 모든 AEAD 태그가 실패하는데 증상은 한참 뒤에 나온다.
    var plain: [256]u8 = undefined;

    // 평문: 길이 하한 미만.
    var t: Transport = .{ .first_from_peer = msg_kexinit };
    var bad = [_]u8{ 0, 0, 0, 2, 0, 0, 0, 0 };
    try std.testing.expectError(packet.Error.MalformedPacket, t.feed(&plain, &bad));
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq);

    // 덜 온 것은 안 센다.
    var partial: Transport = .{};
    try std.testing.expectEqual(@as(?Received, null), try partial.feed(&plain, bad[0..2]));
    try std.testing.expectEqual(@as(u32, 0), partial.recv_seq);

    // 암호 구간: 태그 변조.
    var prng = std.Random.DefaultPrng.init(32);
    var out: [256]u8 = undefined;
    var sender = testCipher();
    const n = try sender.seal(&out, 0, &[_]u8{ msg_ignore, 1 }, prng.random());
    out[n - 1] ^= 1;
    var enc: Transport = .{ .recv_cipher = testCipher(), .phase = .established, .first_from_peer = msg_kexinit };
    try std.testing.expectError(cipher.Error.BadTag, enc.feed(&plain, out[0..n]));
    try std.testing.expectEqual(@as(u32, 1), enc.recv_seq);
}

test "보내는 번호의 wrap 도 막는다" {
    // draft §3.2 의 wrap 금지에는 **방향 한정이 없다**. 받는 쪽만 재면 보내는 쪽이 조용히 감싸 돈다.
    var prng = std.Random.DefaultPrng.init(33);
    var out: [256]u8 = undefined;
    var t: Transport = .{ .strict_kex = true, .send_seq = std.math.maxInt(u32) };
    try std.testing.expectError(Error.SequenceWrapBeforeKexComplete, t.send(&out, &[_]u8{msg_ignore}, prng.random()));

    // 초기 KEX 가 끝난 뒤에는 감싸 도는 것이 정상이다.
    var done: Transport = .{ .strict_kex = true, .phase = .established, .send_seq = std.math.maxInt(u32) };
    _ = try done.send(&out, &[_]u8{msg_ignore}, prng.random());
    try std.testing.expectEqual(@as(u32, 0), done.send_seq);
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

test "키를 넘기면 넘긴 쪽에는 안 남는다" {
    // **F11/F12**: 값으로 받던 시절에는 호출자의 `Cipher` 와 매개변수 사본이 세션 키를 그대로
    // 들고 남았다. 이동 의미론으로 바꾼 것이 실제로 원본을 지우는지 여기서 잰다 — 안 지우면
    // 재키잉마다 한 벌씩 쌓이고, 그 사본은 아무도 주소를 몰라 `clear()` 도 못 닿는다.
    var k = test_key;
    var c = cipher.Cipher.initMove(&k);
    try std.testing.expect(std.mem.allEqual(u8, &k, 0)); // 키 재료 원본
    try std.testing.expect(!std.mem.allEqual(u8, &c.payload_key, 0));

    var t: Transport = .{};
    t.enableSendKeys(&c);
    try std.testing.expect(std.mem.allEqual(u8, &c.payload_key, 0)); // 넘긴 쪽
    try std.testing.expect(std.mem.allEqual(u8, &c.length_key, 0));
    try std.testing.expect(!std.mem.allEqual(u8, &t.send_cipher.?.payload_key, 0)); // 받은 쪽은 산다

    // 재키잉: 옛 키는 새 키가 들어올 때 지워진다.
    const old_key = t.send_cipher.?.payload_key;
    var c2 = testCipher();
    t.enableSendKeys(&c2);
    try std.testing.expect(std.mem.eql(u8, &t.send_cipher.?.payload_key, &old_key)); // 같은 test_key

    t.clear();
    try std.testing.expectEqual(@as(?cipher.Cipher, null), t.send_cipher);
}

test "ShortBuffer 뒤 큰 버퍼로 다시 먹여도 번호가 안 어긋난다" {
    // **2회차 적대적 검증이 찾은 것**: "받은 것은 센다" 를 `Incomplete` 만 빼고 적용했더니
    // `ShortBuffer` 까지 세어, 재시도가 `recv_seq` 를 두 번 올렸다. 암호 구간에서는 그 순간부터
    // 모든 태그가 틀리고, 증상은 한참 뒤 채널 데이터에서 나온다.
    var prng = std.Random.DefaultPrng.init(77);
    var wire_buf: [256]u8 = undefined;
    const payload = [_]u8{ msg_kexinit, 9, 8, 7, 6, 5, 4, 3 };
    const n = try packet.write(&wire_buf, &payload, prng.random());

    var t: Transport = .{};
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, t.feed(&tiny, wire_buf[0..n]));
    try std.testing.expectEqual(@as(u32, 0), t.recv_seq); // 아직 아무것도 받아들이지 않았다

    var big: [256]u8 = undefined;
    const got = (try t.feed(&big, wire_buf[0..n])).?;
    try std.testing.expectEqual(@as(u32, 0), got.seq); // 첫 패킷은 0번이다
    try std.testing.expectEqualSlices(u8, &payload, got.payload);
    try std.testing.expectEqual(@as(u32, 1), t.recv_seq);
}
