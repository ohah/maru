//! `curve25519-sha256` 키 교환(RFC 8731 + RFC 5656 §4) — 공유 비밀·교환 해시 `H`·키 유도.
//!
//! **sans-io 다**(계약 §2). 엔트로피조차 안 뽑는다 — 임시 키의 씨앗은 **호출자가 주입**한다.
//! `std.crypto.dh.X25519.KeyPair.generate` 는 `std.Io` 를 받아 OS 에서 뽑으므로 이 층에서 쓸 수
//! 없다(`tests/boundary/ssh_sans_io.zig` 가 그것을 막는다). 대신 씨앗을 받는 결정론 생성을 쓴다 —
//! 덤으로 **테스트가 키를 고정**할 수 있다.
//!
//! 흐름은 왕복 한 번이다:
//!
//! ```text
//!   C→S  SSH_MSG_KEX_ECDH_INIT (30)   string Q_C
//!   S→C  SSH_MSG_KEX_ECDH_REPLY (31)  string K_S · string Q_S · string signature
//! ```
//!
//! **여기서 서명을 검증하지 않는다.** 그것은 호스트키 검증(S5)의 일이고, 이 모듈은 검증에 필요한
//! `H` 와 `K_S` 를 값으로 넘긴다 — 경계를 그렇게 그어야 이 층이 키 형식·`known_hosts` 와 안 묶인다.
//!
//! **무엇으로 증명됐나 — 정직하게.**
//!   - X25519 는 [RFC 7748](../../../references/specs/rfc7748-curves.txt) §6.1 의 **공개 벡터**로
//!     못박았다. 작은 위수 점 거부도 알려진 점 목록으로 실측한다.
//!   - `H` 와 키 유도는 **손으로 조립한 값과 맞댄다**. SSH KEX 에는 공개된 `H` 벡터가 없어서다 —
//!     즉 "명세를 읽은 대로 짰다" 까지가 여기서 할 수 있는 전부다.
//!   - **진짜 증명은 실서버**다. 서버가 `H` 에 서명하므로, 그 서명이 검증되면(S5) 우리 `H` 가
//!     서버 것과 같다는 뜻이다. 그 왕복은 S8 스모크가 돈다. 그때까지 이 층은 "아직 상호운용이
//!     확인되지 않았다" 로 읽는다.

const std = @import("std");
const wire = @import("wire.zig");

pub const msg_kex_ecdh_init: u8 = 30;
pub const msg_kex_ecdh_reply: u8 = 31;

/// 공개키·공유 비밀 길이. **RFC 8731 §3 은 이 길이를 어긴 공개키를 받으면 끊으라고 한다** —
/// 짧은 값을 패딩해 받아 주면 상대가 고른 점으로 계산하게 된다.
pub const public_len = 32;
pub const shared_len = 32;
/// `curve25519-sha256` 의 HASH 는 SHA-256 이다(RFC 8731 §3).
pub const hash_len = 32;

const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;

pub const Error = error{
    /// 메시지 번호가 `SSH_MSG_KEX_ECDH_REPLY` 가 아니다.
    NotKexEcdhReply,
    /// 공개키 길이가 32 가 아니다(RFC 8731 §3 — 끊는다).
    BadPublicKeyLength,
    /// 공유 비밀이 전부 0 이다 — 상대가 작은 위수 점을 보냈다(RFC 8731 §3, RFC 7748 §6).
    WeakPublicKey,
    /// 씨앗이 유효한 스칼라를 못 만들었다(사실상 안 일어난다 — 뽑아 준 씨앗이 이상한 경우).
    BadSeed,
} || wire.Error || wire.Writer.WriteError;

/// 우리 임시 키쌍. **개인키는 이 값 안에만 산다.**
pub const Ephemeral = struct {
    secret: [X25519.secret_length]u8,
    /// `Q_C` — 선으로 나가는 값.
    public: [public_len]u8,

    /// 씨앗에서 만든다. **엔트로피는 호출자 것**이다(위 모듈 주석).
    pub fn generate(rand: std.Random) Error!Ephemeral {
        var seed: [X25519.seed_length]u8 = undefined;
        rand.bytes(&seed);
        return fromSeed(seed);
    }

    /// 씨앗을 그대로 받는다 — **테스트가 키를 고정**하는 문이고, `generate` 도 이것을 부른다.
    pub fn fromSeed(seed: [X25519.seed_length]u8) Error!Ephemeral {
        const pair = X25519.KeyPair.generateDeterministic(seed) catch return Error.BadSeed;
        return .{ .secret = pair.secret_key, .public = pair.public_key };
    }

    /// 상대 공개키와의 공유 비밀 `X`(RFC 8731 §3 — 32바이트 고정).
    ///
    /// **전부 0 이면 끊는다.** 상대가 작은 위수 점을 보내면 공유 비밀이 몇 안 되는 값으로
    /// 고정되고, 그러면 교환 해시가 상대 마음대로가 된다. `std.crypto` 의 스칼라곱이 그 경우를
    /// `IdentityElement` 로 거절하므로 그것을 우리 오류로 옮긴다.
    pub fn sharedSecret(self: Ephemeral, peer_public: []const u8) Error![shared_len]u8 {
        if (peer_public.len != public_len) return Error.BadPublicKeyLength;
        return X25519.scalarmult(self.secret, peer_public[0..public_len].*) catch
            return Error.WeakPublicKey;
    }

    /// 개인키를 덮어 쓴다. **KEX 가 끝나면 부른다** — 남겨 둘 이유가 없고, 남으면 코어 덤프·
    /// 스왑에 실린다.
    pub fn clear(self: *Ephemeral) void {
        std.crypto.secureZero(u8, &self.secret);
    }
};

/// `SSH_MSG_KEX_ECDH_INIT` 페이로드를 쓴다.
pub fn writeInit(out: []u8, q_c: [public_len]u8) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_kex_ecdh_init);
    try w.string(&q_c);
    return w.written();
}

/// `SSH_MSG_KEX_ECDH_REPLY` 에서 읽어 낸 값들. **셋 다 `payload` 안을 가리킨다** — 복사하지
/// 않으므로 `H` 를 만들고 서명을 검증할 때까지 그 버퍼가 살아 있어야 한다.
pub const Reply = struct {
    /// `K_S` — 서버 호스트키 blob. **교환 해시에 그대로 들어가고**(§4) 서명 검증(S5)이 이것을 판다.
    host_key: []const u8,
    /// `Q_S` — 서버 임시 공개키.
    q_s: []const u8,
    /// `H` 에 대한 서명. 이 모듈은 **검증하지 않는다**(S5 의 일).
    signature: []const u8,
};

pub fn parseReply(payload: []const u8) Error!Reply {
    var r = wire.Reader.init(payload);
    if ((try r.byte()) != msg_kex_ecdh_reply) return Error.NotKexEcdhReply;
    const host_key = try r.string();
    const q_s = try r.string();
    const signature = try r.string();
    // **길이를 여기서 잰다.** 아니면 `sharedSecret` 까지 내려가서야 걸리는데, 그때는 이미
    // 이상한 값으로 해시를 만들 수 있는 자리를 지난 뒤다(RFC 8731 §3 은 받는 즉시 끊으라고 한다).
    if (q_s.len != public_len) return Error.BadPublicKeyLength;
    return .{ .host_key = host_key, .q_s = q_s, .signature = signature };
}

/// 교환 해시 `H` 의 재료(RFC 5656 §4). **순서가 곧 계약이다** — 하나만 어긋나도 서버와 다른
/// 값이 나오고, 그러면 서명 검증이 "위조" 로 실패해 원인을 짚기 어렵다.
pub const ExchangeHashInput = struct {
    /// `V_C` — 우리 식별 문자열, **CR·LF 를 뺀** 것.
    v_c: []const u8,
    /// `V_S` — 서버 식별 문자열, **CR·LF 를 뺀** 것.
    v_s: []const u8,
    /// `I_C` — 우리가 보낸 KEXINIT **페이로드 원문**(다시 만들면 cookie 가 달라진다).
    i_c: []const u8,
    /// `I_S` — 서버 KEXINIT 페이로드 원문.
    i_s: []const u8,
    k_s: []const u8,
    q_c: []const u8,
    q_s: []const u8,
    /// 공유 비밀 `X` — **mpint 로** 먹인다(RFC 8731 §3.1: 32바이트를 부호 없는 big-endian 정수로
    /// 읽고 그것을 mpint 로 인코딩한다). 고정 길이 문자열로 먹이면 앞바이트가 0 이거나 0x80
    /// 이상인 32번에 한 번꼴로만 어긋나 **재현이 어려운 실패**가 된다.
    k: [shared_len]u8,
};

pub fn exchangeHash(in: ExchangeHashInput) Error![hash_len]u8 {
    var h = Sha256.init(.{});
    for ([_][]const u8{ in.v_c, in.v_s, in.i_c, in.i_s, in.k_s, in.q_c, in.q_s }) |s| hashString(&h, s);
    // mpint 규칙(앞 0 제거·부호 자리 0 덧대기)은 **인코더 한 곳이 소유한다** — 여기서 다시 짜면
    // 두 벌이 되고, 갈리는 순간 교환 해시만 조용히 틀린다. 최악 크기는 4 + 1 + 32 다.
    var buf: [4 + 1 + shared_len]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.mpint(&in.k);
    h.update(w.written());
    var out: [hash_len]u8 = undefined;
    h.final(&out);
    return out;
}

fn hashString(h: *Sha256, s: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(s.len), .big);
    h.update(&len);
    h.update(s);
}

/// 키 유도에 쓰는 글자(RFC 4253 §7.2). **방향이 글자에 실린다** — 헷갈리면 양쪽이 서로 다른
/// 키로 암호화해 첫 패킷부터 안 풀린다.
pub const KeyLetter = enum(u8) {
    iv_c2s = 'A',
    iv_s2c = 'B',
    enc_c2s = 'C',
    enc_s2c = 'D',
    mac_c2s = 'E',
    mac_s2c = 'F',
};

/// 키 재료를 `out` 만큼 유도한다(RFC 4253 §7.2).
///
/// ```text
///   K1 = HASH(K || H || X || session_id)
///   K2 = HASH(K || H || K1)
///   K3 = HASH(K || H || K1 || K2)
///   key = K1 || K2 || K3 || ...
/// ```
///
/// **확장 블록은 이미 만든 것을 전부 다시 먹인다** — `K2` 가 `K1` 만, `K3` 가 `K2` 만 먹는 것이
/// 아니다. chacha20-poly1305 는 512비트 키를 요구해(S4) 이 확장을 **실제로 탄다**.
///
/// `session_id` 는 **첫 KEX 의 `H`** 다. 재키잉에서도 그 값을 그대로 쓴다 — 새 `H` 로 바꾸면
/// 인증에 쓴 서명의 근거가 달라진다.
pub fn deriveKey(
    out: []u8,
    k: [shared_len]u8,
    h: [hash_len]u8,
    letter: KeyLetter,
    session_id: []const u8,
) Error!void {
    var mp: [4 + 1 + shared_len]u8 = undefined;
    var w = wire.Writer.init(&mp);
    try w.mpint(&k);
    const k_mpint = w.written();

    var produced: usize = 0;
    while (produced < out.len) {
        var hasher = Sha256.init(.{});
        hasher.update(k_mpint);
        hasher.update(&h);
        if (produced == 0) {
            hasher.update(&[_]u8{@intFromEnum(letter)});
            hasher.update(session_id);
        } else {
            hasher.update(out[0..produced]); // 지금까지 만든 것 **전부**
        }
        var block: [hash_len]u8 = undefined;
        hasher.final(&block);
        const take = @min(hash_len, out.len - produced);
        @memcpy(out[produced..][0..take], block[0..take]);
        produced += take;
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

test "메시지 번호는 명세 값 그대로다" {
    // **상수를 양쪽에 쓰면 그 테스트는 자기충족이다.** 다른 테스트들은 `msg_kex_ecdh_*` 로 쓰고
    // 같은 상수로 읽으므로, 둘을 **함께** 바꾸는 변이가 전부 살아남았다(실측했다 — 지난 슬라이스의
    // strict 표시자 이름과 똑같은 부류다). 그래서 여기서는 명세 숫자와 직접 맞댄다:
    // RFC 5656 §7.1 `#define SSH_MSG_KEX_ECDH_INIT 30` / `SSH_MSG_KEX_ECDH_REPLY 31`.
    try std.testing.expectEqual(@as(u8, 30), msg_kex_ecdh_init);
    try std.testing.expectEqual(@as(u8, 31), msg_kex_ecdh_reply);
    // 길이 상수도 같은 이유로 못박는다(RFC 8731 §3 — 32바이트 고정, HASH 는 SHA-256).
    try std.testing.expectEqual(@as(usize, 32), public_len);
    try std.testing.expectEqual(@as(usize, 32), shared_len);
    try std.testing.expectEqual(@as(usize, 32), hash_len);
}

test "INIT 을 쓰고 우리가 다시 읽는다" {
    const eph = try Ephemeral.fromSeed(@splat(7));
    var out: [64]u8 = undefined;
    const payload = try writeInit(&out, eph.public);
    try std.testing.expectEqual(msg_kex_ecdh_init, payload[0]);
    var r = wire.Reader.init(payload[1..]);
    try std.testing.expectEqualSlices(u8, &eph.public, try r.string());
}

test "REPLY 를 읽는다" {
    var out: [256]u8 = undefined;
    var w = wire.Writer.init(&out);
    try w.byte(msg_kex_ecdh_reply);
    try w.string("K_S blob");
    try w.string(&[_]u8{0xAB} ** public_len);
    try w.string("signature bytes");
    const reply = try parseReply(w.written());
    try std.testing.expectEqualStrings("K_S blob", reply.host_key);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAB} ** public_len, reply.q_s);
    try std.testing.expectEqualStrings("signature bytes", reply.signature);
}

test "REPLY 가 아닌 것과 잘린 것은 거절한다" {
    var out: [256]u8 = undefined;
    var w = wire.Writer.init(&out);
    try w.byte(msg_kex_ecdh_init); // 30 — REPLY 가 아니다
    try w.string("x");
    try std.testing.expectError(Error.NotKexEcdhReply, parseReply(w.written()));

    // **네트워크에서 온 바이트다** — 어느 자리에서 끊겨도 안 죽고 거절해야 한다.
    var full = wire.Writer.init(&out);
    try full.byte(msg_kex_ecdh_reply);
    try full.string("K_S");
    try full.string(&[_]u8{0xAB} ** public_len);
    try full.string("sig");
    const bytes = full.written();
    var i: usize = 1;
    while (i < bytes.len) : (i += 1) {
        if (parseReply(bytes[0..i])) |_| return error.TruncatedReplyAccepted else |_| {}
    }
    _ = try parseReply(bytes); // 전부 오면 읽힌다(위 루프가 "무조건 실패" 가 아님을 못박는다)
}

test "Q_S 길이가 32 가 아니면 거절한다" {
    // **RFC 8731 §3 이 끊으라고 한다.** 짧은 값을 받아 주면 상대가 고른 점으로 계산하게 된다.
    const filler = [_]u8{0xAB} ** 64;
    for ([_]usize{ 0, 31, 33, 64 }) |bad_len| {
        var out: [256]u8 = undefined;
        var w = wire.Writer.init(&out);
        try w.byte(msg_kex_ecdh_reply);
        try w.string("K_S");
        try w.string(filler[0..bad_len]);
        try w.string("sig");
        try std.testing.expectError(Error.BadPublicKeyLength, parseReply(w.written()));
    }
}

test "X25519 는 RFC 7748 §6.1 벡터와 맞는다" {
    // **우리가 만든 값끼리만 맞춰 보면 자기충족이다.** 명세가 박아 둔 값으로 못박는다
    // (references/specs/rfc7748-curves.txt §6.1 — Alice/Bob 의 키와 공유 비밀).
    const alice_secret = [_]u8{
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a, 0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    };
    const alice_public = [_]u8{
        0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54, 0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a,
        0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4, 0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a,
    };
    const bob_secret = [_]u8{
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b, 0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd, 0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
    };
    const bob_public = [_]u8{
        0xde, 0x9e, 0xdb, 0x7d, 0x7b, 0x7d, 0xc1, 0xb4, 0xd3, 0x5b, 0x61, 0xc2, 0xec, 0xe4, 0x35, 0x37,
        0x3f, 0x83, 0x43, 0xc8, 0x5b, 0x78, 0x67, 0x4d, 0xad, 0xfc, 0x7e, 0x14, 0x6f, 0x88, 0x2b, 0x4f,
    };
    const shared = [_]u8{
        0x4a, 0x5d, 0x9d, 0x5b, 0xa4, 0xce, 0x2d, 0xe1, 0x72, 0x8e, 0x3b, 0xf4, 0x80, 0x35, 0x0f, 0x25,
        0xe0, 0x7e, 0x21, 0xc9, 0x47, 0xd1, 0x9e, 0x33, 0x76, 0xf0, 0x9b, 0x3c, 0x1e, 0x16, 0x17, 0x42,
    };

    const alice: Ephemeral = .{ .secret = alice_secret, .public = alice_public };
    const bob: Ephemeral = .{ .secret = bob_secret, .public = bob_public };
    try std.testing.expectEqualSlices(u8, &shared, &(try alice.sharedSecret(&bob_public)));
    try std.testing.expectEqualSlices(u8, &shared, &(try bob.sharedSecret(&alice_public)));

    // 씨앗에서 만든 공개키가 스칼라와 일관되는지도 같이 본다(생성 경로가 벡터를 안 타므로).
    const eph = try Ephemeral.fromSeed(alice_secret);
    try std.testing.expectEqualSlices(u8, &alice_public, &eph.public);
}

test "임시 키는 연결마다 달라야 한다" {
    // **여기가 전방 비밀성이 사는 자리다.** `generate` 가 주입받은 난수를 안 쓰면 모든 연결이
    // 같은 임시 키를 쓰고, 그러면 하나만 털려도 과거·미래 세션이 통째로 풀린다. 그런데 그
    // 변이는 **아무 테스트도 안 잡았다**(다른 테스트는 전부 `fromSeed` 만 탄다).
    var p1 = std.Random.DefaultPrng.init(1);
    var p2 = std.Random.DefaultPrng.init(2);
    const a = try Ephemeral.generate(p1.random());
    const b = try Ephemeral.generate(p2.random());
    try std.testing.expect(!std.mem.eql(u8, &a.secret, &b.secret));
    try std.testing.expect(!std.mem.eql(u8, &a.public, &b.public));

    // 같은 난수원에서 연달아 뽑아도 다르다 — 씨앗을 한 번만 읽고 재사용하면 여기서 걸린다.
    var p3 = std.Random.DefaultPrng.init(3);
    const c = try Ephemeral.generate(p3.random());
    const d = try Ephemeral.generate(p3.random());
    try std.testing.expect(!std.mem.eql(u8, &c.secret, &d.secret));

    // 그리고 **주입한 난수를 실제로 쓴다** — 같은 씨앗의 난수원 둘은 같은 키를 낸다.
    var p4 = std.Random.DefaultPrng.init(7);
    var p5 = std.Random.DefaultPrng.init(7);
    const e = try Ephemeral.generate(p4.random());
    const f = try Ephemeral.generate(p5.random());
    try std.testing.expectEqualSlices(u8, &e.secret, &f.secret);

    // **공개키가 그 개인키에서 나온 것인지** 확인한다. 둘이 따로 놀면 서버는 우리가 안 가진
    // 개인키로 계산하게 되고, KEX 는 "서명 위조" 로 실패해 원인을 짚기 어렵다.
    for ([_]Ephemeral{ a, b, c, d }) |eph| {
        try std.testing.expectEqualSlices(u8, &eph.public, &(try X25519.recoverPublicKey(eph.secret)));
    }
}

test "작은 위수 점은 거절한다" {
    // **RFC 8731 §3 의 MUST.** 받아 주면 공유 비밀이 몇 안 되는 값으로 고정되고, 교환 해시가
    // 상대 마음대로가 된다. RFC 7748 §6.1 이 드는 작은 위수 점들이다.
    const eph = try Ephemeral.fromSeed(@splat(3));
    var one: [32]u8 = @splat(0);
    one[0] = 1;
    // p-1 · p · p+1 — 리틀엔디언 인코딩이라 첫 바이트가 하위다. **`0xff…ff` 는 이 목록에 없다**:
    // X25519 가 최상위 비트를 지워 u = 18 이 되고 그것은 작은 위수가 아니다(그렇게 적었다가
    // 테스트가 잡았다 — 목록을 외워 적으면 이렇게 틀린다).
    var p_minus_1: [32]u8 = @splat(0xff);
    p_minus_1[0] = 0xec;
    p_minus_1[31] = 0x7f;
    var p: [32]u8 = @splat(0xff);
    p[0] = 0xed;
    p[31] = 0x7f;
    var p_plus_1: [32]u8 = @splat(0xff);
    p_plus_1[0] = 0xee;
    p_plus_1[31] = 0x7f;
    const order8_a = [_]u8{
        0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
        0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00,
    };
    const order8_b = [_]u8{
        0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b,
        0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57,
    };
    for ([_][32]u8{ @splat(0), one, order8_a, order8_b, p_minus_1, p, p_plus_1 }) |bad| {
        try std.testing.expectError(Error.WeakPublicKey, eph.sharedSecret(&bad));
    }
    // 정상 점은 통과한다 — 위가 "무조건 거절" 로 통과하는 것이 아님을 못박는다.
    const good = try Ephemeral.fromSeed(@splat(4));
    _ = try eph.sharedSecret(&good.public);
    // 길이가 틀린 것은 다른 오류다 — 둘을 뭉뚱그리면 진단이 흐려진다.
    try std.testing.expectError(Error.BadPublicKeyLength, eph.sharedSecret(&[_]u8{0} ** 31));
}

test "개인키를 지운다" {
    var eph = try Ephemeral.fromSeed(@splat(9));
    const before = eph.secret;
    eph.clear();
    try std.testing.expect(!std.mem.eql(u8, &before, &eph.secret));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &eph.secret);
    // 공개키는 안 지운다 — 교환 해시에 `Q_C` 로 다시 들어간다.
    try std.testing.expect(!std.mem.eql(u8, &([_]u8{0} ** 32), &eph.public));
}

test "교환 해시는 재료 순서와 mpint 규칙을 지킨다" {
    // **손으로 조립한 값과 맞댄다** — `exchangeHash` 를 두 번 불러 비교하면 순서가 틀려도 통과한다.
    const in: ExchangeHashInput = .{
        .v_c = "SSH-2.0-maru_0.1.0",
        .v_s = "SSH-2.0-OpenSSH_10.2",
        .i_c = "client kexinit payload",
        .i_s = "server kexinit payload",
        .k_s = "host key blob",
        .q_c = &([_]u8{0x11} ** 32),
        .q_s = &([_]u8{0x22} ** 32),
        .k = @splat(0x33),
    };

    var expect = Sha256.init(.{});
    for ([_][]const u8{ in.v_c, in.v_s, in.i_c, in.i_s, in.k_s, in.q_c, in.q_s }) |s| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(s.len), .big);
        expect.update(&len);
        expect.update(s);
    }
    // K = 0x3333…33 은 최상위 비트가 0 이라 덧대지 않는다 — 길이 32 의 mpint.
    expect.update(&[_]u8{ 0, 0, 0, 32 });
    expect.update(&([_]u8{0x33} ** 32));
    var want: [32]u8 = undefined;
    expect.final(&want);

    try std.testing.expectEqualSlices(u8, &want, &(try exchangeHash(in)));
}

test "K 의 최상위 비트가 서면 mpint 에 0 을 덧댄다" {
    // **32번에 한 번꼴로만 나타나는 자리다** — 고정 길이 문자열로 먹이면 대부분 통과하다가
    // 가끔 KEX 만 실패한다(재현이 어렵다). 그래서 그 경우를 따로 못박는다.
    var in: ExchangeHashInput = .{
        .v_c = "V_C",
        .v_s = "V_S",
        .i_c = "I_C",
        .i_s = "I_S",
        .k_s = "K_S",
        .q_c = &([_]u8{1} ** 32),
        .q_s = &([_]u8{2} ** 32),
        .k = @splat(0x80), // 최상위 비트가 선다
    };
    var expect = Sha256.init(.{});
    for ([_][]const u8{ in.v_c, in.v_s, in.i_c, in.i_s, in.k_s, in.q_c, in.q_s }) |s| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(s.len), .big);
        expect.update(&len);
        expect.update(s);
    }
    expect.update(&[_]u8{ 0, 0, 0, 33 }); // 33 — 앞에 0 이 하나 붙는다
    expect.update(&[_]u8{0});
    expect.update(&([_]u8{0x80} ** 32));
    var want: [32]u8 = undefined;
    expect.final(&want);
    try std.testing.expectEqualSlices(u8, &want, &(try exchangeHash(in)));

    // 앞이 0 인 K 는 반대로 줄어든다 — 두 방향을 다 재야 규칙을 지킨 것이다.
    var k: [32]u8 = @splat(0x44);
    k[0] = 0;
    in.k = k;
    var shrink = Sha256.init(.{});
    for ([_][]const u8{ in.v_c, in.v_s, in.i_c, in.i_s, in.k_s, in.q_c, in.q_s }) |s| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(s.len), .big);
        shrink.update(&len);
        shrink.update(s);
    }
    shrink.update(&[_]u8{ 0, 0, 0, 31 }); // 앞 0 하나가 빠진다
    shrink.update(k[1..]);
    var want2: [32]u8 = undefined;
    shrink.final(&want2);
    try std.testing.expectEqualSlices(u8, &want2, &(try exchangeHash(in)));
}

test "재료 하나만 달라도 H 가 달라진다" {
    // 순서·경계를 잘못 그으면 서로 다른 입력이 같은 해시로 접힌다(예: 길이 접두를 빼면
    // `"ab"+"c"` 와 `"a"+"bc"` 가 같아진다). 인접한 두 재료를 옮겨 담아 그것을 확인한다.
    const base: ExchangeHashInput = .{
        .v_c = "ab",
        .v_s = "c",
        .i_c = "I_C",
        .i_s = "I_S",
        .k_s = "K_S",
        .q_c = &([_]u8{1} ** 32),
        .q_s = &([_]u8{2} ** 32),
        .k = @splat(0x05),
    };
    var moved = base;
    moved.v_c = "a";
    moved.v_s = "bc";
    try std.testing.expect(!std.mem.eql(u8, &(try exchangeHash(base)), &(try exchangeHash(moved))));

    // K 가 달라도 달라진다(K 를 안 먹이는 구현이 여기서 걸린다).
    var other_k = base;
    other_k.k = @splat(0x06);
    try std.testing.expect(!std.mem.eql(u8, &(try exchangeHash(base)), &(try exchangeHash(other_k))));
}

test "키 유도는 RFC 4253 §7.2 를 따른다" {
    const k: [32]u8 = @splat(0x41);
    const h: [32]u8 = @splat(0x42);
    const session_id = &[_]u8{0x43} ** 32;

    var mp: [37]u8 = undefined;
    var w = wire.Writer.init(&mp);
    try w.mpint(&k);
    const k_mpint = w.written();

    // K1 = HASH(K || H || 'C' || session_id)
    var first = Sha256.init(.{});
    first.update(k_mpint);
    first.update(&h);
    first.update("C");
    first.update(session_id);
    var k1: [32]u8 = undefined;
    first.final(&k1);

    var got: [32]u8 = undefined;
    try deriveKey(&got, k, h, .enc_c2s, session_id);
    try std.testing.expectEqualSlices(u8, &k1, &got);

    // 짧게 달라고 하면 **앞에서** 잘라 준다("Key data MUST be taken from the beginning").
    var short: [16]u8 = undefined;
    try deriveKey(&short, k, h, .enc_c2s, session_id);
    try std.testing.expectEqualSlices(u8, k1[0..16], &short);
}

test "64바이트 키는 K2 = HASH(K || H || K1) 로 잇는다" {
    // **chacha20-poly1305 가 512비트 키를 요구해 이 확장을 실제로 탄다**(S4). 여기가 틀리면
    // 첫 32바이트는 맞고 뒤 32바이트만 어긋나 — 길이 필드만 안 풀리는 이상한 실패가 된다.
    const k: [32]u8 = @splat(0x41);
    const h: [32]u8 = @splat(0x42);
    const session_id = &[_]u8{0x43} ** 32;

    var mp: [37]u8 = undefined;
    var w = wire.Writer.init(&mp);
    try w.mpint(&k);
    const k_mpint = w.written();

    var first = Sha256.init(.{});
    first.update(k_mpint);
    first.update(&h);
    first.update("D");
    first.update(session_id);
    var k1: [32]u8 = undefined;
    first.final(&k1);

    var second = Sha256.init(.{});
    second.update(k_mpint);
    second.update(&h);
    second.update(&k1); // **K1 전체**를 먹인다 — session_id 나 글자가 아니다
    var k2: [32]u8 = undefined;
    second.final(&k2);

    var got: [64]u8 = undefined;
    try deriveKey(&got, k, h, .enc_s2c, session_id);
    try std.testing.expectEqualSlices(u8, &k1, got[0..32]);
    try std.testing.expectEqualSlices(u8, &k2, got[32..64]);

    // 96바이트면 K3 = HASH(K || H || K1 || K2) 다 — 직전 블록만 먹이는 구현이 여기서 걸린다.
    var third = Sha256.init(.{});
    third.update(k_mpint);
    third.update(&h);
    third.update(&k1);
    third.update(&k2);
    var k3: [32]u8 = undefined;
    third.final(&k3);

    var long: [96]u8 = undefined;
    try deriveKey(&long, k, h, .enc_s2c, session_id);
    try std.testing.expectEqualSlices(u8, &k3, long[64..96]);

    // 경계에 안 맞는 길이(40)도 앞에서 자른다.
    var odd: [40]u8 = undefined;
    try deriveKey(&odd, k, h, .enc_s2c, session_id);
    try std.testing.expectEqualSlices(u8, long[0..40], &odd);
}

test "글자마다 다른 키가 나온다" {
    // **방향이 글자에 실린다.** 두 글자가 같은 값을 내면 양쪽이 같은 키로 암호화해 버린다.
    const k: [32]u8 = @splat(1);
    const h: [32]u8 = @splat(2);
    const sid = &[_]u8{3} ** 32;
    const letters = [_]KeyLetter{ .iv_c2s, .iv_s2c, .enc_c2s, .enc_s2c, .mac_c2s, .mac_s2c };
    var seen: [letters.len][32]u8 = undefined;
    for (letters, 0..) |letter, i| try deriveKey(&seen[i], k, h, letter, sid);
    for (0..letters.len) |i| {
        for (i + 1..letters.len) |j| {
            try std.testing.expect(!std.mem.eql(u8, &seen[i], &seen[j]));
        }
    }
    // 글자 값이 명세 그대로인지도 못박는다 — 상수를 바꾸면 서버와 다른 키가 나온다.
    try std.testing.expectEqual(@as(u8, 'A'), @intFromEnum(KeyLetter.iv_c2s));
    try std.testing.expectEqual(@as(u8, 'F'), @intFromEnum(KeyLetter.mac_s2c));
}

test "session_id 가 다르면 키가 다르다" {
    // 재키잉에서 `session_id` 를 새 `H` 로 바꾸면 여기서 값이 갈린다 — 그것이 곧 연결이 깨지는
    // 자리라, 이 성질을 못박아 둔다(첫 KEX 의 H 를 계속 쓴다).
    const k: [32]u8 = @splat(1);
    const h: [32]u8 = @splat(2);
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try deriveKey(&a, k, h, .enc_c2s, &[_]u8{3} ** 32);
    try deriveKey(&b, k, h, .enc_c2s, &[_]u8{4} ** 32);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
