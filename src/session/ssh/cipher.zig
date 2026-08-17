//! `chacha20-poly1305@openssh.com` — 패킷 암호화·인증([draft-ietf-sshm-chacha20-poly1305]).
//!
//! **sans-io 다**(계약 §2). 바이트를 받아 바이트를 낸다.
//!
//! 두 chacha20 인스턴스를 쓴다. **이름이 두 출처에서 반대라 여기부터 못박는다**(계약 §3):
//! 우리는 draft §6 명명을 쓰고, 거기서 **`K_2` 가 길이 필드**를 **`K_1` 이 나머지와 Poly1305 키**를
//! 맡는다. `K_1` 은 키 재료의 **앞** 256비트, `K_2` 는 **뒤** 256비트다. 구형 OpenSSH
//! `PROTOCOL.chacha20poly1305` 는 정확히 반대로 이름 붙였으므로 섞어 읽으면 두 인스턴스를
//! 맞바꿔 걸게 되고, 그러면 모든 서버에서 "길이가 쓰레기로 풀린다" 로 실패한다.
//!
//! ```text
//!   nonce      = uint64(seq)  (SSH 관례대로 big-endian)
//!   길이 4B    = K_2, block counter 0
//!   몸통       = K_1, block counter 1..
//!   Poly1305 키 = K_1, block counter 0 의 앞 32바이트
//!   태그       = Poly1305(암호화된 길이 ‖ 암호화된 몸통)
//! ```
//!
//! **받을 때는 태그를 먼저 검사한다**(draft §7 — "the MAC MUST be checked before decryption").
//! 길이를 먼저 풀어야 몸통이 다 왔는지 알 수 있는데, 그 복호가 곧 오라클이 되는 계열(CVE-2008-5161)을
//! **길이 전용 키를 따로 둬서** 막는다 — 길이 복호로 얻는 정보가 몸통 암호와 무관해진다.
//!
//! **패딩 규칙이 평문 프레이밍과 다르다.** `packet.zig` 는 RFC 4253 §6 대로 **길이 필드를 포함해**
//! 8의 배수를 맞추지만, 여기서는 길이 필드가 따로 암호화되므로 **빼고** 맞춘다. draft 는 이 규칙을
//! 문장으로 적지 않았고 **Appendix A 의 워크드 예제가 유일한 근거**다: payload 65바이트에 패딩이
//! 6이고 `1 + 65 + 6 = 72` 가 8의 배수다(길이 필드를 넣었다면 76이라 배수가 아니다). 그래서 두
//! 규칙을 한 함수로 합치지 않고 각자 두고, 서로를 가리키게 해 뒀다.

const std = @import("std");
const packet = @import("packet.zig");

const ChaCha20 = std.crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = std.crypto.onetimeauth.Poly1305;

/// 키 유도가 내는 바이트 수(draft §6 — 512비트). `kex.deriveKey` 에 이만큼 달라고 한다.
pub const key_len = 64;
/// Poly1305 태그.
pub const tag_len = Poly1305.mac_length;
/// 암호화된 길이 필드.
pub const length_len = 4;
/// 패딩 배수. **길이 필드를 뺀** 나머지가 이 배수여야 한다(위 모듈 주석).
pub const block_size = 8;
/// 패딩 최소치(RFC 4253 §6).
pub const min_padding = 4;

pub const Error = error{
    /// 태그가 안 맞는다 — **변조됐거나 키가 어긋났다**. 둘을 구분해 알려 주지 않는다.
    BadTag,
    /// 출력 버퍼가 모자란다(`sealedLen`·길이 필드로 미리 물어본다).
    ShortBuffer,
    /// 패딩·길이가 규칙을 어겼다.
    MalformedPacket,
    /// 길이가 상한을 넘었다(`packet.max_packet`).
    PacketTooLarge,
};

/// 한 방향의 암호. **방향마다 하나씩** 만든다(c2s·s2c 의 키가 다르다).
pub const Cipher = struct {
    /// `K_1` — 몸통과 Poly1305 키(키 재료의 앞 절반).
    payload_key: [32]u8,
    /// `K_2` — 길이 필드 전용(키 재료의 뒤 절반).
    length_key: [32]u8,

    pub fn init(key: [key_len]u8) Cipher {
        return .{ .payload_key = key[0..32].*, .length_key = key[32..64].* };
    }

    /// 키를 덮어 쓴다. **재키잉 뒤와 연결이 끝날 때 부른다.**
    pub fn clear(self: *Cipher) void {
        std.crypto.secureZero(u8, &self.payload_key);
        std.crypto.secureZero(u8, &self.length_key);
    }

    /// 평문 payload 하나를 선에 나갈 바이트로 만든다. `out` 은 `sealedLen(payload.len)` 이상.
    ///
    /// **`payload` 와 `out` 은 겹치면 안 된다**(`packet.write` 와 같은 이유 — 그쪽 주석에 실측을
    /// 적어 뒀다).
    pub fn seal(
        self: Cipher,
        out: []u8,
        seq: u32,
        payload: []const u8,
        rand: std.Random,
    ) Error!usize {
        const pad = paddingFor(payload.len);
        const body_len = 1 + payload.len + pad;
        if (length_len + body_len > packet.max_packet) return Error.PacketTooLarge;
        const total = sealedLen(payload.len);
        if (out.len < total) return Error.ShortBuffer;

        const nonce = nonceFor(seq);

        // 길이 필드 — K_2, counter 0.
        var len_be: [length_len]u8 = undefined;
        std.mem.writeInt(u32, &len_be, @intCast(body_len), .big);
        ChaCha20.xor(out[0..length_len], &len_be, 0, self.length_key, nonce);

        // 몸통을 평문으로 조립한 뒤 K_1, counter 1 로 덮어 쓴다.
        const body = out[length_len..][0..body_len];
        body[0] = @intCast(pad);
        @memcpy(body[1..][0..payload.len], payload);
        rand.bytes(body[1 + payload.len ..][0..pad]);
        ChaCha20.xor(body, body, 1, self.payload_key, nonce);

        // 태그는 **암호문 전체**(길이 + 몸통) 위에서 계산한다.
        var tag: [tag_len]u8 = undefined;
        self.authenticate(&tag, nonce, out[0 .. length_len + body_len]);
        @memcpy(out[length_len + body_len ..][0..tag_len], &tag);
        return total;
    }

    /// `seal` 이 쓸 바이트 수.
    pub fn sealedLen(payload_len: usize) usize {
        return length_len + 1 + payload_len + paddingFor(payload_len) + tag_len;
    }

    /// 길이 필드만 푼다. **몸통이 다 왔는지 알려면 이것이 먼저 필요하다** — 그래서 이 값은
    /// 아직 인증되지 않았다(태그 검사는 `open` 이 한다). 위 모듈 주석의 오라클 얘기가 이 자리다.
    ///
    /// 돌려주는 값은 **몸통 길이**다(길이 필드와 태그는 안 센다). 선에서 더 읽어야 할 바이트는
    /// `body_len + tag_len` 이다.
    pub fn decryptLength(self: Cipher, seq: u32, encrypted: [length_len]u8) Error!u32 {
        var plain: [length_len]u8 = undefined;
        ChaCha20.xor(&plain, &encrypted, 0, self.length_key, nonceFor(seq));
        const body_len = std.mem.readInt(u32, &plain, .big);
        if (body_len > packet.max_packet) return Error.PacketTooLarge;
        // 몸통에는 최소한 패딩 길이 바이트 + 메시지 번호 + 패딩 4 가 있다.
        if (body_len < 1 + 1 + min_padding) return Error.MalformedPacket;
        if (body_len % block_size != 0) return Error.MalformedPacket;
        return body_len;
    }

    /// 태그를 검사하고 몸통을 푼다. `buf` 는 **길이 4 + 몸통 + 태그 16** 전부다.
    ///
    /// 돌려주는 것은 `out` 안의 payload(메시지 번호부터)다. **태그가 안 맞으면 아무것도 안 푼다.**
    pub fn open(self: Cipher, out: []u8, seq: u32, buf: []const u8) Error![]const u8 {
        if (buf.len < length_len + 1 + min_padding + tag_len) return Error.MalformedPacket;
        const body_len = buf.len - length_len - tag_len;
        if (body_len % block_size != 0) return Error.MalformedPacket;
        if (out.len < body_len) return Error.ShortBuffer;

        const nonce = nonceFor(seq);

        // **태그 먼저**(draft §7). 안 맞으면 몸통을 건드리지 않는다.
        var want: [tag_len]u8 = undefined;
        self.authenticate(&want, nonce, buf[0 .. length_len + body_len]);
        const got = buf[length_len + body_len ..][0..tag_len];
        if (!std.crypto.timing_safe.eql([tag_len]u8, want, got.*)) return Error.BadTag;

        const body = out[0..body_len];
        ChaCha20.xor(body, buf[length_len..][0..body_len], 1, self.payload_key, nonce);

        const pad: usize = body[0];
        if (pad < min_padding) return Error.MalformedPacket;
        // **payload 는 최소 1바이트다** — 메시지 번호가 있어야 한다(`packet.read` 와 같은 이유).
        if (1 + pad >= body_len) return Error.MalformedPacket;
        return body[1 .. body_len - pad];
    }

    /// Poly1305 키는 **몸통과 같은 인스턴스의 block counter 0** 에서 나온다(draft §6).
    fn authenticate(self: Cipher, out: *[tag_len]u8, nonce: [8]u8, ciphertext: []const u8) void {
        var block: [64]u8 = undefined;
        ChaCha20.stream(&block, 0, self.payload_key, nonce);
        defer std.crypto.secureZero(u8, &block);
        Poly1305.create(out, ciphertext, block[0..Poly1305.key_length]);
    }
};

/// 패딩 길이. **4 이상이면서 `padding_length + payload + padding` 을 8의 배수로** 만드는 가장
/// 작은 값이다 — **길이 필드는 안 센다**(위 모듈 주석의 근거).
fn paddingFor(payload_len: usize) usize {
    const unpadded = 1 + payload_len;
    var pad = block_size - (unpadded % block_size);
    if (pad < min_padding) pad += block_size;
    return pad;
}

/// nonce 는 시퀀스 번호를 **SSH 관례대로 big-endian uint64** 로 적은 것이다(draft §6).
fn nonceFor(seq: u32) [8]u8 {
    var nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce, seq, .big);
    return nonce;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

// **명세가 박아 둔 워크드 예제**(draft Appendix A). 우리가 만든 값끼리 맞춰 보는 것은 자기충족이라,
// 명세가 끝까지 계산해 둔 이 벡터로 못박는다 — 키·시퀀스 번호·평문·최종 wire 가 전부 있다.
const vector = struct {
    /// Figure 5 — c2s 방향의 64바이트 키 재료.
    const key = [_]u8{
        0x8b, 0xbf, 0xf6, 0x85, 0x5f, 0xc1, 0x02, 0x33, 0x8c, 0x37, 0x3e, 0x73, 0xaa, 0xc0, 0xc9, 0x14,
        0xf0, 0x76, 0xa9, 0x05, 0xb2, 0x44, 0x4a, 0x32, 0xee, 0xca, 0xff, 0xea, 0xe2, 0x2b, 0xec, 0xc5,
        0xe9, 0xb7, 0xa7, 0xa5, 0x82, 0x5a, 0x82, 0x49, 0x34, 0x6e, 0xc1, 0xc2, 0x83, 0x01, 0xcf, 0x39,
        0x45, 0x43, 0xfc, 0x75, 0x69, 0x88, 0x7d, 0x76, 0xe1, 0x68, 0xf3, 0x75, 0x62, 0xac, 0x07, 0x40,
    };
    const seq: u32 = 7;
    /// Figure 4 — 암호화 전 패킷 전체(길이 4 + 몸통 72).
    const plain = [_]u8{
        0x00, 0x00, 0x00, 0x48, 0x06, 0x5e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x4c, 0x6f,
        0x72, 0x65, 0x6d, 0x20, 0x69, 0x70, 0x73, 0x75, 0x6d, 0x20, 0x64, 0x6f, 0x6c, 0x6f, 0x72, 0x20,
        0x73, 0x69, 0x74, 0x20, 0x61, 0x6d, 0x65, 0x74, 0x2c, 0x20, 0x63, 0x6f, 0x6e, 0x73, 0x65, 0x63,
        0x74, 0x65, 0x74, 0x75, 0x72, 0x20, 0x61, 0x64, 0x69, 0x70, 0x69, 0x73, 0x69, 0x63, 0x69, 0x6e,
        0x67, 0x20, 0x65, 0x6c, 0x69, 0x74, 0x4e, 0x43, 0xe8, 0x04, 0xdc, 0x6c,
    };
    /// Figure 18 — 선으로 나가는 전체(암호문 76 + 태그 16).
    const wire = [_]u8{
        0x2c, 0x3e, 0xcc, 0xe4, 0xa5, 0xbc, 0x05, 0x89, 0x5b, 0xf0, 0x7a, 0x7b, 0xa9, 0x56, 0xb6, 0xc6,
        0x88, 0x29, 0xac, 0x7c, 0x83, 0xb7, 0x80, 0xb7, 0x00, 0x0e, 0xcd, 0xe7, 0x45, 0xaf, 0xc7, 0x05,
        0xbb, 0xc3, 0x78, 0xce, 0x03, 0xa2, 0x80, 0x23, 0x6b, 0x87, 0xb5, 0x3b, 0xed, 0x58, 0x39, 0x66,
        0x23, 0x02, 0xb1, 0x64, 0xb6, 0x28, 0x6a, 0x48, 0xcd, 0x1e, 0x09, 0x71, 0x38, 0xe3, 0xcb, 0x90,
        0x9b, 0x8b, 0x2b, 0x82, 0x9d, 0xd1, 0x8d, 0x2a, 0x35, 0xff, 0x82, 0xd9, 0x95, 0x34, 0x9e, 0x85,
        0x5b, 0xf0, 0x2c, 0x29, 0x8e, 0xf7, 0x75, 0xf2, 0xd1, 0xa7, 0xe8, 0xb8,
    };
    /// 평문 payload(패딩 길이 바이트와 패딩을 뺀 것) — 메시지 번호 0x5e 부터 65바이트.
    const payload = plain[5..70];
};

/// 벡터의 패딩을 그대로 내는 난수원 — `seal` 이 만드는 바이트를 명세 것과 **바이트 단위로** 맞대려면
/// 패딩까지 같아야 한다.
const FixedPadding = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn fill(ctx: *anyopaque, buf: []u8) void {
        const self: *FixedPadding = @ptrCast(@alignCast(ctx));
        for (buf) |*b| {
            b.* = self.bytes[self.pos % self.bytes.len];
            self.pos += 1;
        }
    }

    fn random(self: *FixedPadding) std.Random {
        return .{ .ptr = self, .fillFn = fill };
    }
};

test "명세 워크드 예제와 바이트가 같다 (draft Appendix A)" {
    var padding = FixedPadding{ .bytes = vector.plain[70..76] }; // 4e 43 e8 04 dc 6c
    var cipher = Cipher.init(vector.key);
    var out: [128]u8 = undefined;
    const n = try cipher.seal(&out, vector.seq, vector.payload, padding.random());
    try std.testing.expectEqual(vector.wire.len, n);
    try std.testing.expectEqualSlices(u8, &vector.wire, out[0..n]);
}

test "명세 벡터를 우리가 다시 푼다" {
    var cipher = Cipher.init(vector.key);
    // 길이 필드부터 — 몸통이 얼마나 올지 이것으로 안다.
    const body_len = try cipher.decryptLength(vector.seq, vector.wire[0..length_len].*);
    try std.testing.expectEqual(@as(u32, 0x48), body_len);

    var out: [128]u8 = undefined;
    const payload = try cipher.open(&out, vector.seq, &vector.wire);
    try std.testing.expectEqualSlices(u8, vector.payload, payload);
    try std.testing.expectEqual(@as(u8, 0x5e), payload[0]); // SSH2_MSG_CHANNEL_DATA
}

test "패딩은 길이 필드를 빼고 8의 배수를 맞춘다" {
    // **평문 프레이밍(`packet.zig`)과 다른 규칙이다.** 근거는 명세 Appendix A 의 예제뿐이라
    // 그 숫자를 직접 못박는다: payload 65 → 패딩 6, 그리고 1 + 65 + 6 = 72 가 8의 배수다.
    try std.testing.expectEqual(@as(usize, 6), paddingFor(65));
    try std.testing.expectEqual(@as(usize, 0), (1 + 65 + paddingFor(65)) % block_size);
    // 길이 필드를 넣었다면 76 이라 배수가 아니다 — 두 규칙이 실제로 다르다는 것도 못박는다.
    try std.testing.expect((length_len + 1 + 65 + paddingFor(65)) % block_size != 0);

    // 경계를 훑는다 — 어디서도 패딩이 4 미만으로 떨어지면 안 되고 배수가 깨지면 안 된다.
    var len: usize = 0;
    while (len < 128) : (len += 1) {
        const pad = paddingFor(len);
        try std.testing.expect(pad >= min_padding);
        try std.testing.expect(pad <= min_padding + block_size);
        try std.testing.expectEqual(@as(usize, 0), (1 + len + pad) % block_size);
    }
}

test "왕복한다" {
    var prng = std.Random.DefaultPrng.init(11);
    var cipher = Cipher.init(vector.key);
    var out: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for ([_]usize{ 1, 2, 7, 8, 63, 64, 65, 200 }) |len| {
        var payload: [200]u8 = undefined;
        for (payload[0..len], 0..) |*b, i| b.* = @intCast(i % 251);
        const n = try cipher.seal(&out, 3, payload[0..len], prng.random());
        try std.testing.expectEqual(Cipher.sealedLen(len), n);
        const got = try cipher.open(&plain, 3, out[0..n]);
        try std.testing.expectEqualSlices(u8, payload[0..len], got);
    }
}

test "시퀀스 번호가 다르면 안 풀린다" {
    // **nonce 가 시퀀스 번호다.** 번호를 안 올리거나 어긋나면 여기서 걸린다 — strict KEX 의
    // 리셋이 한쪽만 돌았을 때 나타나는 증상이 정확히 이것이다(계약 §4).
    var prng = std.Random.DefaultPrng.init(12);
    var cipher = Cipher.init(vector.key);
    var out: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const n = try cipher.seal(&out, 5, "hello", prng.random());
    try std.testing.expectError(Error.BadTag, cipher.open(&plain, 6, out[0..n]));
    _ = try cipher.open(&plain, 5, out[0..n]);

    // 길이 필드도 번호에 묶인다 — 다른 번호로 풀면 엉뚱한 값이 나온다(그래서 태그가 최종 판정이다).
    const right = try cipher.decryptLength(5, out[0..length_len].*);
    const wrong = cipher.decryptLength(6, out[0..length_len].*);
    try std.testing.expectEqual(@as(u32, 16), right); // 1 + 5 + 10
    if (wrong) |v| try std.testing.expect(v != right) else |_| {}
}

test "변조를 거부한다" {
    // **태그가 안 맞으면 아무것도 안 푼다**(draft §7 — MAC before decryption).
    var prng = std.Random.DefaultPrng.init(13);
    var cipher = Cipher.init(vector.key);
    var out: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const n = try cipher.seal(&out, 1, "tamper me", prng.random());

    // 몸통 한 비트, 길이 한 비트, 태그 한 비트 — 셋 다 거부해야 한다.
    for ([_]usize{ 0, 3, length_len, n - tag_len, n - 1 }) |i| {
        var bad = out;
        bad[i] ^= 1;
        try std.testing.expectError(Error.BadTag, cipher.open(&plain, 1, bad[0..n]));
    }
    // 원본은 여전히 풀린다.
    _ = try cipher.open(&plain, 1, out[0..n]);
}

test "태그가 틀리면 출력 버퍼를 건드리지 않는다" {
    // **draft §7 의 MUST 는 "MAC before decryption" 이다.** 그런데 순서를 뒤집어 먼저 풀고 나중에
    // 태그를 봐도 반환값은 똑같이 `BadTag` 라, 그 변이가 살아남았다(실측했다). 차이는 **출력
    // 버퍼에 위조 패킷의 평문이 쓰이는지**뿐이고, 그것이 바로 이 MUST 가 막으려는 것이다 —
    // 호출자가 실패한 버퍼를 재사용하거나 들여다보면 공격자가 고른 바이트를 보게 된다.
    var prng = std.Random.DefaultPrng.init(21);
    var cipher = Cipher.init(vector.key);
    var out: [128]u8 = undefined;
    const n = try cipher.seal(&out, 1, "do not decrypt me", prng.random());

    var bad = out;
    bad[length_len + 3] ^= 0x40; // 몸통 변조 → 태그 불일치

    var plain: [128]u8 = undefined;
    const canary: u8 = 0xC7;
    @memset(&plain, canary);
    try std.testing.expectError(Error.BadTag, cipher.open(&plain, 1, bad[0..n]));
    for (plain) |b| try std.testing.expectEqual(canary, b);

    // 정상 패킷이면 물론 쓴다 — 위가 "아무것도 안 쓴다" 로 통과하는 것이 아님을 못박는다.
    _ = try cipher.open(&plain, 1, out[0..n]);
    try std.testing.expect(std.mem.indexOfScalar(u8, &plain, canary) == null or plain[0] != canary);
}

test "인증됐어도 패딩 규칙을 어긴 패킷은 거절한다" {
    // 태그가 맞는다는 것은 **상대가 진짜 서버라는 뜻일 뿐**, 그가 규칙을 지켰다는 뜻이 아니다.
    // 패딩이 4 미만이면 RFC 4253 §6 위반이고, 받아 주면 패딩 바이트가 payload 로 새어 상위가
    // 메시지 뒤에 붙은 쓰레기를 파싱한다. 키를 우리가 쥐고 있으니 그런 패킷을 만들어 확인한다.
    var cipher = Cipher.init(vector.key);
    for ([_]u8{ 0, 1, 3 }) |bad_pad| {
        var body = [_]u8{0} ** 16;
        body[0] = bad_pad;
        body[1] = 21; // SSH_MSG_NEWKEYS — 그럴듯한 메시지 번호
        var buf: [length_len + 16 + tag_len]u8 = undefined;
        const nonce = nonceFor(31);
        var len_be: [length_len]u8 = undefined;
        std.mem.writeInt(u32, &len_be, 16, .big);
        ChaCha20.xor(buf[0..length_len], &len_be, 0, cipher.length_key, nonce);
        ChaCha20.xor(buf[length_len..][0..16], &body, 1, cipher.payload_key, nonce);
        var tag: [tag_len]u8 = undefined;
        cipher.authenticate(&tag, nonce, buf[0 .. length_len + 16]);
        @memcpy(buf[length_len + 16 ..][0..tag_len], &tag);

        var plain: [64]u8 = undefined;
        try std.testing.expectError(Error.MalformedPacket, cipher.open(&plain, 31, &buf));
    }
}

test "키가 다르면 안 풀린다" {
    var prng = std.Random.DefaultPrng.init(14);
    var a = Cipher.init(vector.key);
    var other = vector.key;
    other[0] ^= 1;
    var b = Cipher.init(other);
    var out: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const n = try a.seal(&out, 0, "secret", prng.random());
    try std.testing.expectError(Error.BadTag, b.open(&plain, 0, out[0..n]));
}

test "두 인스턴스를 맞바꾸면 못 푼다" {
    // **K_1/K_2 는 이름이 두 출처에서 반대다**(모듈 주석). 맞바꿔 걸면 길이가 쓰레기로 풀린다 —
    // 키 재료의 앞뒤를 뒤집어 그것을 실측한다.
    var swapped = vector.key;
    @memcpy(swapped[0..32], vector.key[32..64]);
    @memcpy(swapped[32..64], vector.key[0..32]);
    var cipher = Cipher.init(swapped);
    const body_len = cipher.decryptLength(vector.seq, vector.wire[0..length_len].*);
    // 0x48 이 나오면 안 된다 — 거절되거나 다른 값이어야 한다.
    if (body_len) |v| try std.testing.expect(v != 0x48) else |_| {}
    var plain: [128]u8 = undefined;
    try std.testing.expectError(Error.BadTag, cipher.open(&plain, vector.seq, &vector.wire));
}

test "깨진 프레이밍은 거절한다" {
    var prng = std.Random.DefaultPrng.init(15);
    var cipher = Cipher.init(vector.key);
    var out: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const n = try cipher.seal(&out, 2, "x", prng.random());

    // 몸통이 8의 배수가 아닌 길이로 오면 태그를 세기 전에 거절한다.
    try std.testing.expectError(Error.MalformedPacket, cipher.open(&plain, 2, out[0 .. n - 1]));
    // 태그조차 못 담을 만큼 짧은 것.
    try std.testing.expectError(Error.MalformedPacket, cipher.open(&plain, 2, out[0..8]));
    // 출력 버퍼가 모자란 것.
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, cipher.open(&tiny, 2, out[0..n]));
}

test "길이 필드가 규칙을 어기면 거절한다" {
    // `decryptLength` 는 **아직 인증되지 않은** 값을 다룬다 — 그래서 여기서 거르는 것이 의미가 있다.
    // 상한·배수·하한을 어긴 길이를 만들어 내는 암호문을 역산해 넣는다.
    var cipher = Cipher.init(vector.key);
    const nonce = nonceFor(9);
    for ([_]u32{ 0, 1, 5, 7, 9, packet.max_packet + 8 }) |bad_len| {
        var plain_len: [length_len]u8 = undefined;
        std.mem.writeInt(u32, &plain_len, bad_len, .big);
        var enc: [length_len]u8 = undefined;
        ChaCha20.xor(&enc, &plain_len, 0, cipher.length_key, nonce);
        try std.testing.expectError(
            if (bad_len > packet.max_packet) Error.PacketTooLarge else Error.MalformedPacket,
            cipher.decryptLength(9, enc),
        );
    }
    // 정당한 길이는 통과한다 — 위가 "무조건 거절" 이 아님을 못박는다.
    var ok_len: [length_len]u8 = undefined;
    std.mem.writeInt(u32, &ok_len, 16, .big);
    var enc_ok: [length_len]u8 = undefined;
    ChaCha20.xor(&enc_ok, &ok_len, 0, cipher.length_key, nonce);
    try std.testing.expectEqual(@as(u32, 16), try cipher.decryptLength(9, enc_ok));
}

test "payload 가 0바이트인 패킷은 거절한다" {
    // `packet.read` 와 같은 이유 — SSH 메시지는 전부 메시지 번호로 시작한다. 몸통 8바이트에
    // 패딩 7 이면 payload 가 0 이 되는데, 다른 가드는 전부 통과한다.
    var cipher = Cipher.init(vector.key);
    var body = [_]u8{0} ** 8;
    body[0] = 7; // 패딩 7 → payload 0
    var wire_bytes: [length_len + 8 + tag_len]u8 = undefined;
    const nonce = nonceFor(4);
    var len_be: [length_len]u8 = undefined;
    std.mem.writeInt(u32, &len_be, 8, .big);
    ChaCha20.xor(wire_bytes[0..length_len], &len_be, 0, cipher.length_key, nonce);
    ChaCha20.xor(wire_bytes[length_len..][0..8], &body, 1, cipher.payload_key, nonce);
    var tag: [tag_len]u8 = undefined;
    cipher.authenticate(&tag, nonce, wire_bytes[0 .. length_len + 8]);
    @memcpy(wire_bytes[length_len + 8 ..][0..tag_len], &tag);

    var plain: [64]u8 = undefined;
    try std.testing.expectError(Error.MalformedPacket, cipher.open(&plain, 4, &wire_bytes));
}

test "키를 지운다" {
    var cipher = Cipher.init(vector.key);
    cipher.clear();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &cipher.payload_key);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &cipher.length_key);
}

test "상수는 명세 값 그대로다" {
    // 상수를 쓰는 쪽과 읽는 쪽에 함께 쓰면 자기충족이다(지난 슬라이스들에서 실제로 겪었다).
    try std.testing.expectEqual(@as(usize, 64), key_len); // draft §6 — 512비트
    try std.testing.expectEqual(@as(usize, 16), tag_len);
    try std.testing.expectEqual(@as(usize, 4), length_len);
    try std.testing.expectEqual(@as(usize, 8), block_size);
    try std.testing.expectEqual(@as(usize, 4), min_padding);
}
