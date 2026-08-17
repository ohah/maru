//! `openssh-key-v1` 개인키 파싱 — 평문 키와 암호화 키(`aes256-ctr` + `bcrypt`).
//!
//! **sans-io 다**(계약 §2). 파일을 읽는 것도 암호를 묻는 것도 L4·UI 이고, 이 층은 바이트만 본다.
//! **할당도 안 한다** — 복호 작업 버퍼를 호출자가 준다.
//!
//! 형식은 RFC 가 아니라 **OpenSSH `PROTOCOL.key`** 가 정한다:
//!
//! ```text
//!   byte[]  "openssh-key-v1\0"
//!   string  ciphername · string kdfname · string kdfoptions
//!   uint32  N (키 개수)
//!   string  publickey1 … publickeyN
//!   string  암호화된 개인키 목록
//! ```
//!
//! 개인키 목록을 풀면 이렇게 생겼다:
//!
//! ```text
//!   uint32  checkint · uint32 checkint   (같아야 한다 — 암호가 맞았는지 빠르게 본다)
//!   byte[]  privatekey1 · string comment1 …
//!   byte    1, 2, 3, …                    (블록 배수까지 채우는 패딩)
//! ```
//!
//! **`checkint` 둘이 같은지가 암호 확인의 전부다.** 32비트라 **틀린 암호가 2^32 에 한 번 통과**할
//! 수 있고, 그때는 그 뒤 키 파싱이 깨져서 걸린다 — 그래서 아래는 패딩까지 검사한다.

const std = @import("std");
const wire = @import("wire.zig");
const hostkey = @import("hostkey.zig");

const Aes256 = std.crypto.core.aes.Aes256;
const modes = std.crypto.core.modes;

pub const magic = "openssh-key-v1\x00";

/// 우리가 받는 암호(계약 §3 의 범위 안에서 — OpenSSH 기본값이다).
pub const cipher_none = "none";
pub const cipher_aes256_ctr = "aes256-ctr";
pub const kdf_none = "none";
pub const kdf_bcrypt = "bcrypt";

const aes_key_len = 32;
const aes_iv_len = 16;

pub const Error = error{
    /// `openssh-key-v1\0` 로 시작하지 않는다 — 다른 형식이거나 PEM 을 안 벗겼다.
    BadMagic,
    /// 우리가 안 다루는 암호·KDF 다(예: `aes256-gcm`, 옛 PEM 키).
    UnsupportedCipher,
    /// `ssh-ed25519` 가 아니다(계약 §3).
    UnsupportedAlgorithm,
    /// **암호가 틀렸다**(`checkint` 불일치). 파일이 깨진 경우와 구분하지 않는다 — 사용자에게는
    /// 어느 쪽이든 "다시 입력" 이 답이고, 구분해 알려 주면 그 자체가 오라클이 된다.
    BadPassphrase,
    /// 구조가 깨졌다.
    MalformedKey,
    /// 키가 여럿 들어 있다 — OpenSSH 도 파일당 하나만 쓰므로 받지 않는다.
    MultipleKeys,
    /// 작업 버퍼가 모자란다(`scratchLen` 으로 미리 묻는다).
    ShortBuffer,
} || wire.Error || hostkey.Error;

/// 파싱 결과. **개인키가 여기 실린다** — 다 쓰면 `clear()` 로 지운다(계약 §4).
pub const Parsed = struct {
    /// SSH 표현의 개인키 `seed(32) ‖ public(32)` — `userauth.signBlob` 이 그대로 받는다.
    secret: [64]u8,
    public: [32]u8,

    pub fn clear(self: *Parsed) void {
        std.crypto.secureZero(u8, &self.secret);
    }
};

/// 복호에 필요한 작업 버퍼 크기. 암호문보다 작으면 안 된다.
pub fn scratchLen(blob: []const u8) usize {
    return blob.len;
}

/// 키 하나를 판다. 평문 키면 `passphrase` 는 안 쓰인다.
///
/// `scratch` 는 복호 결과가 들어갈 자리다(`scratchLen` 이상). **다 쓰면 호출자가 지운다** —
/// 개인키 평문이 그 안에 남는다.
pub fn parse(blob: []const u8, passphrase: []const u8, scratch: []u8) Error!Parsed {
    if (!std.mem.startsWith(u8, blob, magic)) return Error.BadMagic;
    var r = wire.Reader.init(blob[magic.len..]);
    const cipher_name = try r.string();
    const kdf_name = try r.string();
    const kdf_options = try r.string();
    if ((try r.u32be()) != 1) return Error.MultipleKeys;
    const public_blob = try r.string();
    const encrypted = try r.string();

    const plain = try decrypt(cipher_name, kdf_name, kdf_options, passphrase, encrypted, scratch);
    const parsed = try parsePrivateSection(plain);

    // **바깥 공개키와 안쪽 공개키가 같아야 한다.** 다르면 파일이 손댄 것이거나 우리가 잘못 풀었다 —
    // 어느 쪽이든 그 키로 서명하면 서버가 거절한다.
    const outer = try hostkey.parsePublicKey(public_blob);
    if (!std.mem.eql(u8, &outer, &parsed.public)) return Error.MalformedKey;
    return parsed;
}

fn decrypt(
    cipher_name: []const u8,
    kdf_name: []const u8,
    kdf_options: []const u8,
    passphrase: []const u8,
    encrypted: []const u8,
    scratch: []u8,
) Error![]const u8 {
    if (std.mem.eql(u8, cipher_name, cipher_none)) {
        // 평문 키. **KDF 도 `none` 이어야 한다** — 한쪽만 `none` 인 파일은 우리가 모르는 것이다.
        if (!std.mem.eql(u8, kdf_name, kdf_none)) return Error.UnsupportedCipher;
        if (encrypted.len % 8 != 0) return Error.MalformedKey; // 평문 블록은 8 이다
        return encrypted;
    }
    if (!std.mem.eql(u8, cipher_name, cipher_aes256_ctr) or !std.mem.eql(u8, kdf_name, kdf_bcrypt)) {
        return Error.UnsupportedCipher;
    }
    if (encrypted.len % aes_iv_len != 0) return Error.MalformedKey;
    if (scratch.len < encrypted.len) return Error.ShortBuffer;

    // KDF 옵션은 `string salt · uint32 rounds` 다(PROTOCOL.key §2).
    var opt = wire.Reader.init(kdf_options);
    const salt = try opt.string();
    const rounds = try opt.u32be();
    if (rounds == 0 or salt.len == 0) return Error.MalformedKey;
    // **빈 암호는 "파일이 깨졌다" 가 아니라 "암호가 틀렸다" 다.** KDF 는 둘을 같은 오류로 내는데
    // (`InvalidInput`), 사용자에게는 전혀 다른 얘기다 — 안 친 것을 파일 탓으로 돌리면 안 된다.
    if (passphrase.len == 0) return Error.BadPassphrase;

    // 키와 IV 를 **한 번에** 뽑는다(둘을 따로 뽑으면 OpenSSH 와 다른 값이 나온다).
    // **`bcrypt.pbkdf` 가 아니라 `opensshKdf` 다.** 앞의 것은 bcrypt 를 PRF 로 쓴 표준 PBKDF2 이고,
    // OpenSSH 가 쓰는 것은 이름이 비슷하지만 **다른 구성**이다(std 가 둘을 갈라 뒀다). 바꿔 쓰면
    // 복호가 조용히 쓰레기를 내고 `checkint` 불일치로만 나타나 — "암호가 틀렸다" 로 오인한다.
    var key_iv: [aes_key_len + aes_iv_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_iv);
    std.crypto.pwhash.bcrypt.opensshKdf(passphrase, salt, &key_iv, rounds) catch return Error.MalformedKey;

    const ctx = Aes256.initEnc(key_iv[0..aes_key_len].*);
    modes.ctr(@TypeOf(ctx), ctx, scratch[0..encrypted.len], encrypted, key_iv[aes_key_len..].*, .big);
    return scratch[0..encrypted.len];
}

fn parsePrivateSection(plain: []const u8) Error!Parsed {
    var r = wire.Reader.init(plain);
    const check1 = try r.u32be();
    const check2 = try r.u32be();
    // **암호 확인은 이것이 전부다**(PROTOCOL.key §3). 32비트라 틀린 암호가 드물게 통과할 수 있어
    // 아래 파싱과 패딩 검사가 두 번째 그물이 된다.
    if (check1 != check2) return Error.BadPassphrase;

    if (!std.mem.eql(u8, try r.string(), hostkey.alg_name)) return Error.UnsupportedAlgorithm;
    const public = try r.string();
    const secret = try r.string();
    if (public.len != 32 or secret.len != 64) return Error.MalformedKey;
    // **개인키 뒤쪽 32바이트가 곧 공개키다**(ed25519 의 SSH 표현). 안 맞으면 서명이 안 맞는다.
    if (!std.mem.eql(u8, public, secret[32..64])) return Error.MalformedKey;
    _ = try r.string(); // comment

    // 패딩은 `1, 2, 3, …` 이다. **틀린 암호가 `checkint` 을 우연히 통과해도 여기서 걸린다.**
    const pad = r.rest();
    for (pad, 1..) |b, i| {
        if (b != @as(u8, @truncate(i))) return Error.BadPassphrase;
    }

    return .{ .secret = secret[0..64].*, .public = public[0..32].* };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

// **독립 구현이 만든 키다.** `ssh-keygen -t ed25519` 로 만든 **일회용** 키 하나를 평문본과
// 암호본(`ssh-keygen -p`, 암호 "hunter2")으로 뽑았다 — 같은 키라 **둘을 풀면 같은 값이 나와야**
// 한다. 실제 기계의 키는 안 쓴다.
const plain_key = [_]u8{
    0x6f, 0x70, 0x65, 0x6e, 0x73, 0x73, 0x68, 0x2d, 0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x04, 0x6e, 0x6f, 0x6e, 0x65, 0x00, 0x00, 0x00, 0x04, 0x6e, 0x6f, 0x6e,
    0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x33, 0x00, 0x00,
    0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39, 0x00, 0x00,
    0x00, 0x20, 0x4e, 0x0a, 0x71, 0xc4, 0x3f, 0xf6, 0xc1, 0x37, 0x13, 0xaf, 0xef, 0x14, 0x4e,
    0x8a, 0x62, 0x39, 0x20, 0x37, 0xba, 0x3b, 0x01, 0xd4, 0xc5, 0x60, 0x17, 0xeb, 0xda, 0x0c,
    0x39, 0x77, 0xd3, 0x19, 0x00, 0x00, 0x00, 0x90, 0xf4, 0x29, 0xb7, 0xd5, 0xf4, 0x29, 0xb7,
    0xd5, 0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31,
    0x39, 0x00, 0x00, 0x00, 0x20, 0x4e, 0x0a, 0x71, 0xc4, 0x3f, 0xf6, 0xc1, 0x37, 0x13, 0xaf,
    0xef, 0x14, 0x4e, 0x8a, 0x62, 0x39, 0x20, 0x37, 0xba, 0x3b, 0x01, 0xd4, 0xc5, 0x60, 0x17,
    0xeb, 0xda, 0x0c, 0x39, 0x77, 0xd3, 0x19, 0x00, 0x00, 0x00, 0x40, 0x0c, 0xb9, 0x04, 0xae,
    0xaa, 0xf4, 0xe2, 0x43, 0xb0, 0xaa, 0x7d, 0xd9, 0x2a, 0x3c, 0xf7, 0xec, 0x8d, 0xa3, 0xbd,
    0x7b, 0x57, 0x48, 0xe7, 0xc7, 0x76, 0xc9, 0x59, 0xfa, 0x44, 0xbc, 0x0f, 0x75, 0x4e, 0x0a,
    0x71, 0xc4, 0x3f, 0xf6, 0xc1, 0x37, 0x13, 0xaf, 0xef, 0x14, 0x4e, 0x8a, 0x62, 0x39, 0x20,
    0x37, 0xba, 0x3b, 0x01, 0xd4, 0xc5, 0x60, 0x17, 0xeb, 0xda, 0x0c, 0x39, 0x77, 0xd3, 0x19,
    0x00, 0x00, 0x00, 0x09, 0x6d, 0x61, 0x72, 0x75, 0x2d, 0x74, 0x65, 0x73, 0x74, 0x01, 0x02,
    0x03, 0x04,
};

const encrypted_key = [_]u8{
    0x6f, 0x70, 0x65, 0x6e, 0x73, 0x73, 0x68, 0x2d, 0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x0a, 0x61, 0x65, 0x73, 0x32, 0x35, 0x36, 0x2d, 0x63, 0x74, 0x72, 0x00,
    0x00, 0x00, 0x06, 0x62, 0x63, 0x72, 0x79, 0x70, 0x74, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00,
    0x00, 0x10, 0x2a, 0xda, 0xf8, 0xfe, 0x33, 0x5e, 0xeb, 0x76, 0xdc, 0xad, 0x3e, 0x0e, 0x86,
    0x80, 0x8f, 0x0e, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x33,
    0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39,
    0x00, 0x00, 0x00, 0x20, 0x4e, 0x0a, 0x71, 0xc4, 0x3f, 0xf6, 0xc1, 0x37, 0x13, 0xaf, 0xef,
    0x14, 0x4e, 0x8a, 0x62, 0x39, 0x20, 0x37, 0xba, 0x3b, 0x01, 0xd4, 0xc5, 0x60, 0x17, 0xeb,
    0xda, 0x0c, 0x39, 0x77, 0xd3, 0x19, 0x00, 0x00, 0x00, 0x90, 0x79, 0x79, 0xcf, 0xaa, 0xdd,
    0xdf, 0x4d, 0x15, 0x1c, 0xd2, 0xa2, 0x6a, 0x70, 0xe3, 0x6f, 0x37, 0x7e, 0xaf, 0xfd, 0xae,
    0x6d, 0x74, 0x79, 0x29, 0xdd, 0xdd, 0xe7, 0x92, 0x88, 0xda, 0xc6, 0xcd, 0x06, 0x56, 0x2b,
    0x39, 0x6e, 0x17, 0x0f, 0xc1, 0x45, 0x86, 0xb5, 0xfe, 0x07, 0xb5, 0x85, 0x96, 0x73, 0xf4,
    0x4f, 0x25, 0x42, 0x04, 0x01, 0x29, 0x39, 0x93, 0xef, 0x48, 0x86, 0xa2, 0xb5, 0x83, 0x63,
    0x7d, 0x27, 0x4f, 0x69, 0x00, 0xe0, 0xd8, 0x7d, 0x9e, 0x74, 0x45, 0x4c, 0x8b, 0x09, 0x71,
    0x0c, 0xc7, 0xae, 0xa2, 0x02, 0xe0, 0xf1, 0x67, 0x12, 0x31, 0x27, 0x43, 0xff, 0x9c, 0x7e,
    0xf8, 0xf6, 0xf5, 0xdf, 0x8f, 0xa4, 0x2f, 0xf2, 0xb1, 0x1d, 0x16, 0xa2, 0x1b, 0x91, 0x98,
    0x6e, 0x7e, 0x15, 0x38, 0xf3, 0xe0, 0x73, 0x7b, 0xa2, 0x77, 0x20, 0xfe, 0xfa, 0xc9, 0xe4,
    0xae, 0x81, 0xb0, 0x0e, 0x6b, 0x01, 0x8a, 0x5f, 0xc9, 0x7c, 0x59, 0xad, 0x87, 0x6f, 0x1f,
    0x49, 0xc7, 0x4d, 0x50,
};

const vector_passphrase = "hunter2";
const want_public = [_]u8{
    0x4e, 0x0a, 0x71, 0xc4, 0x3f, 0xf6, 0xc1, 0x37, 0x13, 0xaf, 0xef, 0x14, 0x4e, 0x8a, 0x62, 0x39,
    0x20, 0x37, 0xba, 0x3b, 0x01, 0xd4, 0xc5, 0x60, 0x17, 0xeb, 0xda, 0x0c, 0x39, 0x77, 0xd3, 0x19,
};

test "평문 키를 판다" {
    var scratch: [512]u8 = undefined;
    var got = try parse(&plain_key, "", &scratch);
    defer got.clear();
    try std.testing.expectEqualSlices(u8, &want_public, &got.public);
    try std.testing.expectEqualSlices(u8, &want_public, got.secret[32..64]);
}

test "암호화 키를 같은 값으로 푼다 (ssh-keygen 오라클)" {
    // **같은 키의 평문본과 암호본이다.** 우리 복호가 틀리면 두 값이 갈린다 — 우리가 만든 값끼리
    // 맞추는 자기충족이 아니다(bcrypt 라운드·salt·키/IV 유도·CTR 이 전부 이 한 대조에 걸린다).
    var scratch: [512]u8 = undefined;
    var enc = try parse(&encrypted_key, vector_passphrase, &scratch);
    defer enc.clear();
    var plain = try parse(&plain_key, "", &scratch);
    defer plain.clear();
    try std.testing.expectEqualSlices(u8, &plain.secret, &enc.secret);
    try std.testing.expectEqualSlices(u8, &plain.public, &enc.public);
    try std.testing.expectEqualSlices(u8, &want_public, &enc.public);
}

test "푼 키로 서명하면 검증된다" {
    // 파싱이 맞다는 것의 **끝까지의 증거** — 이 키로 서명한 것이 그 공개키로 검증돼야 한다.
    const userauth = @import("userauth.zig");
    var scratch: [512]u8 = undefined;
    var got = try parse(&encrypted_key, vector_passphrase, &scratch);
    defer got.clear();

    var out: [256]u8 = undefined;
    const key_blob = try userauth.publicKeyBlob(out[0..128], got.secret);
    const sig = try userauth.signBlob(out[128..256], got.secret, "hello");
    try hostkey.verifyExchangeHash(key_blob, sig, "hello");
    try std.testing.expectEqualSlices(u8, &want_public, &(try hostkey.parsePublicKey(key_blob)));
}

test "암호가 틀리면 거절한다" {
    var scratch: [512]u8 = undefined;
    for ([_][]const u8{ "", "hunter", "hunter22", "HUNTER2", "hunter3" }) |bad| {
        try std.testing.expectError(Error.BadPassphrase, parse(&encrypted_key, bad, &scratch));
    }
    // 맞는 암호는 통과한다 — 위가 "무조건 거절" 이 아님을 못박는다.
    var ok = try parse(&encrypted_key, vector_passphrase, &scratch);
    ok.clear();
}

test "magic·개수·암호 종류를 본다" {
    var scratch: [512]u8 = undefined;

    var bad_magic = plain_key;
    bad_magic[0] = 'x';
    try std.testing.expectError(Error.BadMagic, parse(&bad_magic, "", &scratch));

    // 키가 여럿이라고 주장하는 파일(개수 필드는 magic 15 + none/none 헤더 뒤).
    var many = plain_key;
    many[38] = 2; // N 의 하위 바이트
    try std.testing.expectError(Error.MultipleKeys, parse(&many, "", &scratch));

    // 우리가 모르는 암호.
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..magic.len], magic);
    var w = wire.Writer.init(buf[magic.len..]);
    try w.string("aes256-gcm@openssh.com");
    try w.string(kdf_bcrypt);
    try w.string("");
    try w.u32be(1);
    try w.string("pub");
    try w.string("enc");
    try std.testing.expectError(
        Error.UnsupportedCipher,
        parse(buf[0 .. magic.len + w.written().len], "pw", &scratch),
    );

    // **한쪽만 `none` 인 파일**은 우리가 모르는 것이다 — 조용히 평문으로 읽으면 안 된다.
    var w2 = wire.Writer.init(buf[magic.len..]);
    try w2.string(cipher_none);
    try w2.string(kdf_bcrypt);
    try w2.string("");
    try w2.u32be(1);
    try w2.string("pub");
    try w2.string("enc");
    try std.testing.expectError(
        Error.UnsupportedCipher,
        parse(buf[0 .. magic.len + w2.written().len], "pw", &scratch),
    );
}

/// 평문 키를 조립한다 — **안쪽 개인키 구역을 손대는 시험**에 쓴다. 정상 파일만으로는 그 안의
/// 검사들(알고리즘·길이·공개키 일치)이 도는지 알 수 없다(변이가 살아남아 알았다).
fn buildPlainKey(
    out: []u8,
    opts: struct {
        alg: []const u8 = hostkey.alg_name,
        public: []const u8 = &want_public,
        /// 안쪽 개인키 64바이트. 기본은 평문 벡터의 것.
        secret: []const u8 = plain_key[161..225],
        /// 바깥 공개키 blob 에 실을 값(기본은 안쪽과 같다).
        outer_public: ?[]const u8 = null,
        checkint2: ?u32 = null,
    },
) ![]const u8 {
    var inner_buf: [512]u8 = undefined;
    var inner = wire.Writer.init(&inner_buf);
    try inner.u32be(0x1234_5678);
    try inner.u32be(opts.checkint2 orelse 0x1234_5678);
    try inner.string(opts.alg);
    try inner.string(opts.public);
    try inner.string(opts.secret);
    try inner.string("c");
    // 8의 배수까지 1,2,3,… 으로 채운다.
    var pad: u8 = 1;
    while (inner.pos % 8 != 0) : (pad += 1) try inner.byte(pad);

    var outer_buf: [128]u8 = undefined;
    var outer = wire.Writer.init(&outer_buf);
    try outer.string(hostkey.alg_name);
    try outer.string(opts.outer_public orelse opts.public);

    @memcpy(out[0..magic.len], magic);
    var w = wire.Writer.init(out[magic.len..]);
    try w.string(cipher_none);
    try w.string(kdf_none);
    try w.string("");
    try w.u32be(1);
    try w.string(outer.written());
    try w.string(inner.written());
    return out[0 .. magic.len + w.written().len];
}

test "조립한 정상 키가 실제 키와 같은 값을 낸다" {
    // **픽스처가 진짜인지부터 본다.** 이것이 틀리면 아래 시험들이 전부 헛것을 재게 된다.
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    var got = try parse(try buildPlainKey(&buf, .{}), "", &scratch);
    defer got.clear();
    try std.testing.expectEqualSlices(u8, &want_public, &got.public);
    var real = try parse(&plain_key, "", &scratch);
    defer real.clear();
    try std.testing.expectEqualSlices(u8, &real.secret, &got.secret);
}

test "안쪽 개인키 구역의 검사들" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;

    // **알고리즘이 다르면 거절한다**(계약 §3 — ed25519 만 한다). 이름 비교는 **정확 일치**여야
    // 한다 — 인증서 계열은 접두가 같은데 우리가 안 다루는 것이라, 접두 일치로 받으면 그것을
    // 평범한 키로 읽는다(hostkey 에서 이미 겪은 부류라 여기서도 같이 잰다).
    for ([_][]const u8{ "ssh-rsa", "ecdsa-sha2-nistp256", "ssh-ed448", "", "ssh-ed25519-cert-v01@openssh.com" }) |alg| {
        try std.testing.expectError(
            Error.UnsupportedAlgorithm,
            parse(try buildPlainKey(&buf, .{ .alg = alg }), "", &scratch),
        );
    }

    // **길이가 명세와 달라도 거절한다.** 짧은 값을 받아 주면 그 뒤 슬라이스가 엉뚱한 자리를 가리킨다.
    const filler = [_]u8{0xAB} ** 128;
    for ([_]usize{ 0, 31, 33 }) |bad| {
        try std.testing.expectError(
            Error.MalformedKey,
            parse(try buildPlainKey(&buf, .{ .public = filler[0..bad] }), "", &scratch),
        );
    }
    for ([_]usize{ 0, 63, 65, 128 }) |bad| {
        try std.testing.expectError(
            Error.MalformedKey,
            parse(try buildPlainKey(&buf, .{ .secret = filler[0..bad] }), "", &scratch),
        );
    }

    // **개인키 뒤쪽 32바이트가 곧 공개키다.** 안 맞으면 그 키로 서명해도 서버가 거절한다 —
    // 여기서 안 잡으면 "왜 인증이 안 되는지" 를 알 방법이 없다.
    var mismatched = plain_key[161..225].*;
    mismatched[40] ^= 1;
    try std.testing.expectError(
        Error.MalformedKey,
        parse(try buildPlainKey(&buf, .{ .secret = &mismatched }), "", &scratch),
    );

    // 바깥 공개키가 안쪽과 다른 파일(누가 손댄 것).
    var other_outer = want_public;
    other_outer[0] ^= 1;
    try std.testing.expectError(
        Error.MalformedKey,
        parse(try buildPlainKey(&buf, .{ .outer_public = &other_outer }), "", &scratch),
    );

    // checkint 이 다르면 암호 문제로 읽는다.
    try std.testing.expectError(
        Error.BadPassphrase,
        parse(try buildPlainKey(&buf, .{ .checkint2 = 0xDEAD_BEEF }), "", &scratch),
    );
}

test "작업 버퍼가 모자라면 거절한다" {
    // 잘라서 풀면 그 뒤 파싱이 엉뚱한 값을 낸다 — 자리부터 본다.
    var tiny: [16]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, parse(&encrypted_key, vector_passphrase, &tiny));
    try std.testing.expect(scratchLen(&encrypted_key) >= encrypted_key.len);
}

test "잘린 파일은 거절한다" {
    // **파일에서 온 바이트다** — 어느 자리에서 끊겨도 안 죽고 거절해야 한다.
    var scratch: [512]u8 = undefined;
    var i: usize = 0;
    while (i < plain_key.len) : (i += 1) {
        if (parse(plain_key[0..i], "", &scratch)) |_| return error.TruncatedKeyAccepted else |_| {}
    }
    var ok = try parse(&plain_key, "", &scratch);
    ok.clear();
}

test "clear 는 개인키를 지운다" {
    var scratch: [512]u8 = undefined;
    var got = try parse(&plain_key, "", &scratch);
    const before = got.secret;
    got.clear();
    try std.testing.expect(!std.mem.eql(u8, &before, &got.secret));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &got.secret);
    // 공개키는 안 지운다 — 지우면 호출자가 blob 을 못 만든다.
    try std.testing.expectEqualSlices(u8, &want_public, &got.public);
}

test "상수는 OpenSSH 형식 그대로다" {
    try std.testing.expectEqualStrings("openssh-key-v1\x00", magic);
    try std.testing.expectEqual(@as(usize, 15), magic.len);
    try std.testing.expectEqualStrings("aes256-ctr", cipher_aes256_ctr);
    try std.testing.expectEqualStrings("bcrypt", kdf_bcrypt);
    try std.testing.expectEqualStrings("none", cipher_none);
}
