//! 호스트키 — `ssh-ed25519` 공개키·서명 파싱과 **교환 해시 검증**(RFC 8709), 그리고 지문.
//!
//! **sans-io 다**(계약 §2). `known_hosts` 파일을 읽는 것은 L4 이고, 이 층은 바이트만 본다.
//!
//! **여기가 중간자를 막는 자리다.** KEX 까지는 "누군가와" 암호를 걸었을 뿐이고, 그 누군가가
//! 우리가 붙으려던 서버인지는 **이 서명이 유일한 증거**다 — 서버는 교환 해시 `H` 에 서명하고,
//! `H` 에는 양쪽 임시 공개키와 KEXINIT 원문이 다 들어간다(계약 §4.2). 그래서 서명이 맞으면
//! **우리 `H` 가 서버 것과 같다**는 뜻이기도 하다 — S3 가 명세를 제대로 읽었는지의 증명이다.
//!
//! 형식은 둘 다 길이 접두 문자열 두 개다(RFC 8709 §4):
//!
//! ```text
//!   공개키 blob: string "ssh-ed25519" · string key(32)
//!   서명   blob: string "ssh-ed25519" · string signature(64)
//! ```
//!
//! **지문은 blob 전체를 해싱한다** — 알고리즘 이름 문자열까지 포함이다. 키 32바이트만 해싱하면
//! `ssh-keygen -lf` 와 다른 값이 나오고, 그러면 사용자가 대조할 수 없다.

const std = @import("std");
const wire = @import("wire.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// 우리가 받는 유일한 호스트키 알고리즘(계약 §3). 다른 것을 주는 서버에는 **못 붙는다** —
/// 조용히 실패하지 말고 그 사실을 그대로 보여 준다.
pub const alg_name = "ssh-ed25519";
pub const key_len = Ed25519.PublicKey.encoded_length;
pub const sig_len = Ed25519.Signature.encoded_length;

/// `SHA256:` + padding 없는 base64(43자). OpenSSH 가 보여 주는 것과 같은 모양이다.
pub const fingerprint_len = "SHA256:".len + 43;

pub const Error = error{
    /// blob 이 `ssh-ed25519` 가 아니다 — 협상이 어긋났거나 서버가 다른 키를 보냈다.
    UnsupportedAlgorithm,
    /// 길이가 명세와 다르다(키 32 · 서명 64).
    MalformedBlob,
    /// **서명이 안 맞는다.** 중간자이거나 `H` 가 서버 것과 다르다 — 어느 쪽이든 붙으면 안 된다.
    BadSignature,
    /// 지문을 담을 자리가 모자란다.
    ShortBuffer,
} || wire.Error;

/// 서버 호스트키 blob(`K_S`)에서 ed25519 공개키를 꺼낸다.
pub fn parsePublicKey(blob: []const u8) Error![key_len]u8 {
    var r = wire.Reader.init(blob);
    if (!std.mem.eql(u8, try r.string(), alg_name)) return Error.UnsupportedAlgorithm;
    const key = try r.string();
    if (key.len != key_len) return Error.MalformedBlob;
    return key[0..key_len].*;
}

/// 서명 blob 에서 64바이트 서명을 꺼낸다.
pub fn parseSignature(blob: []const u8) Error![sig_len]u8 {
    var r = wire.Reader.init(blob);
    if (!std.mem.eql(u8, try r.string(), alg_name)) return Error.UnsupportedAlgorithm;
    const sig = try r.string();
    if (sig.len != sig_len) return Error.MalformedBlob;
    return sig[0..sig_len].*;
}

/// **교환 해시에 대한 서명을 검증한다.** 이것이 통과해야 상대가 그 호스트키의 주인이다.
///
/// 검증은 **cofactored** 방식을 쓴다(`std.crypto` 의 `verify`). RFC 8032 §8.2 는 둘 다 허용하고,
/// 차이는 작은 위수 성분이 섞인 **악의적으로 만든** 서명에서만 나타난다 — 상호운용을 넓게 잡는
/// 쪽을 택했고, 그 선택을 여기 적어 둔다.
pub fn verifyExchangeHash(
    host_key_blob: []const u8,
    signature_blob: []const u8,
    h: []const u8,
) Error!void {
    const key = try parsePublicKey(host_key_blob);
    const sig = try parseSignature(signature_blob);
    const pk = Ed25519.PublicKey.fromBytes(key) catch return Error.BadSignature;
    Ed25519.Signature.fromBytes(sig).verify(h, pk) catch return Error.BadSignature;
}

/// 사용자에게 보여 주는 지문 — `SHA256:<base64, padding 없음>`.
///
/// **`blob` 전체를 해싱한다**(알고리즘 이름 문자열 포함). 키 32바이트만 해싱하면 `ssh-keygen -lf`
/// 와 다른 값이 나오고, 그러면 **사용자가 대조할 수 없다** — 지문의 존재 이유가 사라진다.
pub fn fingerprint(out: []u8, blob: []const u8) Error![]const u8 {
    if (out.len < fingerprint_len) return Error.ShortBuffer;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(blob, &digest, .{});
    @memcpy(out[0.."SHA256:".len], "SHA256:");
    const enc = std.base64.standard_no_pad.Encoder;
    const body = enc.encode(out["SHA256:".len..][0..43], &digest);
    return out[0 .. "SHA256:".len + body.len];
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

// **독립 구현이 계산한 값으로 못박는다.** 우리가 만든 값끼리 맞춰 보면 자기충족이다.
//   - 지문: `ssh-keygen -t ed25519` 로 만든 **일회용** 키와 `ssh-keygen -lf` 가 낸 지문이다
//     (실제 기계의 호스트키는 안 쓴다 — 공개키라도 기계를 식별한다).
//   - 서명: RFC 8032 §7.1 TEST 2 의 공개 벡터.
const openssh_vector = struct {
    /// `ssh-keygen` 이 낸 공개키 blob 원문(base64 를 푼 것).
    const blob = [_]u8{
        0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39,
        0x00, 0x00, 0x00, 0x20, 0x6d, 0x9e, 0x18, 0x8a, 0x55, 0x1d, 0x57, 0x5b, 0xc4, 0x8b, 0xe1,
        0xd1, 0x81, 0x51, 0xf4, 0x35, 0x3d, 0xf1, 0xfa, 0x97, 0xc3, 0xf5, 0x23, 0x22, 0xc2, 0x3d,
        0x74, 0x7f, 0xcb, 0x13, 0x44, 0x52,
    };
    /// `ssh-keygen -lf` 가 낸 지문.
    const fp = "SHA256:4PGj8S88M7XqkDtVxpnZ8QNSVl2OHXl8Nb/4t3gk414";
};

/// RFC 8032 §7.1 TEST 2 — 공개키·메시지·서명.
const rfc8032_test2 = struct {
    const public_key = [_]u8{
        0x3d, 0x40, 0x17, 0xc3, 0xe8, 0x43, 0x89, 0x5a, 0x92, 0xb7, 0x0a, 0xa7, 0x4d, 0x1b, 0x7e, 0xbc,
        0x9c, 0x98, 0x2c, 0xcf, 0x2e, 0xc4, 0x96, 0x8c, 0xc0, 0xcd, 0x55, 0xf1, 0x2a, 0xf4, 0x66, 0x0c,
    };
    const message = [_]u8{0x72};
    const signature = [_]u8{
        0x92, 0xa0, 0x09, 0xa9, 0xf0, 0xd4, 0xca, 0xb8, 0x72, 0x0e, 0x82, 0x0b, 0x5f, 0x64, 0x25, 0x40,
        0xa2, 0xb2, 0x7b, 0x54, 0x16, 0x50, 0x3f, 0x8f, 0xb3, 0x76, 0x22, 0x23, 0xeb, 0xdb, 0x69, 0xda,
        0x08, 0x5a, 0xc1, 0xe4, 0x3e, 0x15, 0x99, 0x6e, 0x45, 0x8f, 0x36, 0x13, 0xd0, 0xf1, 0x1d, 0x8c,
        0x38, 0x7b, 0x2e, 0xae, 0xb4, 0x30, 0x2a, 0xee, 0xb0, 0x0d, 0x29, 0x16, 0x12, 0xbb, 0x0c, 0x00,
    };
};

/// 테스트용 blob 조립 — 실제 서버가 보내는 모양과 같다.
fn buildBlob(out: []u8, alg: []const u8, body: []const u8) ![]const u8 {
    var w = wire.Writer.init(out);
    try w.string(alg);
    try w.string(body);
    return w.written();
}

test "OpenSSH 가 만든 공개키 blob 을 판다" {
    try std.testing.expectEqualSlices(u8, openssh_vector.blob[19..51], &(try parsePublicKey(&openssh_vector.blob)));
}

test "지문이 ssh-keygen 과 같다" {
    // **독립 구현의 값이다.** 우리 계산이 틀리면 사용자가 대조할 수 없고, 그러면 TOFU 가
    // 무의미해진다(계약 §4).
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(openssh_vector.fp, try fingerprint(&out, &openssh_vector.blob));

    // **blob 전체를 해싱한다** — 키 32바이트만 해싱하면 다른 값이 나온다. 그 차이를 못박는다.
    var only_key: [64]u8 = undefined;
    const wrong = try fingerprint(&only_key, openssh_vector.blob[19..51]);
    try std.testing.expect(!std.mem.eql(u8, openssh_vector.fp, wrong));

    // 길이와 모양(접두·padding 없음).
    try std.testing.expectEqual(fingerprint_len, openssh_vector.fp.len);
    try std.testing.expect(std.mem.startsWith(u8, openssh_vector.fp, "SHA256:"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, openssh_vector.fp, '='));

    // 자리가 모자라면 거절한다(잘라서 보여 주면 사용자가 틀린 값을 대조하게 된다).
    var tiny: [fingerprint_len - 1]u8 = undefined;
    try std.testing.expectError(Error.ShortBuffer, fingerprint(&tiny, &openssh_vector.blob));
}

test "키가 한 비트만 달라도 지문이 달라진다" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var flipped = openssh_vector.blob;
    flipped[30] ^= 1;
    try std.testing.expect(!std.mem.eql(
        u8,
        try fingerprint(&a, &openssh_vector.blob),
        try fingerprint(&b, &flipped),
    ));
}

test "RFC 8032 벡터로 서명을 검증한다" {
    var key_buf: [128]u8 = undefined;
    var sig_buf: [128]u8 = undefined;
    const key_blob = try buildBlob(&key_buf, alg_name, &rfc8032_test2.public_key);
    const sig_blob = try buildBlob(&sig_buf, alg_name, &rfc8032_test2.signature);
    try verifyExchangeHash(key_blob, sig_blob, &rfc8032_test2.message);
}

test "위조 서명을 거절한다" {
    // **여기가 중간자를 막는 자리다.** 한 비트만 뒤집어도 거절해야 한다.
    var key_buf: [128]u8 = undefined;
    var sig_buf: [128]u8 = undefined;
    const key_blob = try buildBlob(&key_buf, alg_name, &rfc8032_test2.public_key);

    for ([_]usize{ 0, 31, 32, 63 }) |i| {
        var forged = rfc8032_test2.signature;
        forged[i] ^= 1;
        const sig_blob = try buildBlob(&sig_buf, alg_name, &forged);
        try std.testing.expectError(Error.BadSignature, verifyExchangeHash(key_blob, sig_blob, &rfc8032_test2.message));
    }

    // 메시지가 다르면 거절한다 — `H` 가 서버 것과 다르면 이렇게 나타난다.
    const sig_blob = try buildBlob(&sig_buf, alg_name, &rfc8032_test2.signature);
    try std.testing.expectError(Error.BadSignature, verifyExchangeHash(key_blob, sig_blob, "different H"));
    try std.testing.expectError(Error.BadSignature, verifyExchangeHash(key_blob, sig_blob, ""));

    // 다른 키로는 안 맞는다 — 중간자가 자기 키로 서명해 오는 경우다.
    var other_key_buf: [128]u8 = undefined;
    var other = rfc8032_test2.public_key;
    other[0] ^= 1;
    const other_blob = try buildBlob(&other_key_buf, alg_name, &other);
    try std.testing.expectError(Error.BadSignature, verifyExchangeHash(other_blob, sig_blob, &rfc8032_test2.message));
}

test "우리 알고리즘이 아니면 거절한다" {
    // 계약 §3 — ed25519 만 한다. **조용히 다른 것을 받아 주면** 검증이 약해진다.
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "ssh-rsa", "rsa-sha2-512", "ecdsa-sha2-nistp256", "ssh-ed448", "" }) |alg| {
        const key_blob = try buildBlob(&buf, alg, &([_]u8{0} ** 32));
        try std.testing.expectError(Error.UnsupportedAlgorithm, parsePublicKey(key_blob));
        // **서명 쪽도 같이 잰다.** 여기 검사가 빠져도 아무 테스트가 안 잡던 자리다(변이로 확인
        // 했다) — 서버가 다른 알고리즘을 주장하는 서명을 보내도 우리가 ed25519 로 검증하게 된다.
        const sig_blob = try buildBlob(&buf, alg, &([_]u8{0} ** 64));
        try std.testing.expectError(Error.UnsupportedAlgorithm, parseSignature(sig_blob));
    }
    // 접두만 같은 이름도 거절한다(부분 일치가 아니다).
    const cert = try buildBlob(&buf, "ssh-ed25519-cert-v01@openssh.com", &([_]u8{0} ** 32));
    try std.testing.expectError(Error.UnsupportedAlgorithm, parsePublicKey(cert));
    const cert_sig = try buildBlob(&buf, "ssh-ed25519-cert-v01@openssh.com", &([_]u8{0} ** 64));
    try std.testing.expectError(Error.UnsupportedAlgorithm, parseSignature(cert_sig));

    // **검증 경로에서도 걸린다** — 파싱만 막고 검증이 딴 길로 가면 의미가 없다.
    var key_buf: [128]u8 = undefined;
    const good_key = try buildBlob(&key_buf, alg_name, &rfc8032_test2.public_key);
    const wrong_sig = try buildBlob(&buf, "ssh-rsa", &rfc8032_test2.signature);
    try std.testing.expectError(
        Error.UnsupportedAlgorithm,
        verifyExchangeHash(good_key, wrong_sig, &rfc8032_test2.message),
    );
}

test "길이가 틀린 blob 을 거절한다" {
    var buf: [256]u8 = undefined;
    const filler = [_]u8{0xAB} ** 128;
    for ([_]usize{ 0, 31, 33, 64 }) |bad| {
        const blob = try buildBlob(&buf, alg_name, filler[0..bad]);
        try std.testing.expectError(Error.MalformedBlob, parsePublicKey(blob));
    }
    for ([_]usize{ 0, 32, 63, 65, 128 }) |bad| {
        const blob = try buildBlob(&buf, alg_name, filler[0..bad]);
        try std.testing.expectError(Error.MalformedBlob, parseSignature(blob));
    }
}

test "잘린 blob 은 거절한다" {
    // **네트워크에서 온 바이트다** — 어느 자리에서 끊겨도 안 죽고 거절해야 한다.
    var buf: [256]u8 = undefined;
    const blob = try buildBlob(&buf, alg_name, &([_]u8{0x11} ** 32));
    var i: usize = 0;
    while (i < blob.len) : (i += 1) {
        if (parsePublicKey(blob[0..i])) |_| return error.TruncatedBlobAccepted else |_| {}
    }
    _ = try parsePublicKey(blob); // 전부 오면 읽힌다
}

test "상수는 명세 값 그대로다" {
    // 상수를 쓰는 쪽과 읽는 쪽에 함께 쓰면 자기충족이다(앞선 슬라이스들에서 실제로 겪었다).
    try std.testing.expectEqualStrings("ssh-ed25519", alg_name); // RFC 8709 §4
    try std.testing.expectEqual(@as(usize, 32), key_len);
    try std.testing.expectEqual(@as(usize, 64), sig_len);
    try std.testing.expectEqual(@as(usize, 50), fingerprint_len); // "SHA256:" 7 + base64 43
}
