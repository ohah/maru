//! SSH 바이너리 패킷 프로토콜(RFC 4253 §6) — 인코딩·디코딩.
//!
//! **sans-io 다**(계약 §2). 여기는 바이트만 다루고 소켓을 모른다 — 그래서 실서버 없이
//! 바이트 열로 못박을 수 있고, 데스크톱(`std.net`)과 모바일(host 소켓)이 **같은 코드**를 쓴다.
//!
//! 패킷 하나는 이렇게 생겼다:
//!
//! ```text
//!   uint32  packet_length   (padding_length + payload + padding 의 길이 — 자기 자신은 뺀다)
//!   byte    padding_length
//!   byte[]  payload
//!   byte[]  random padding  (4 이상)
//!   byte[]  mac             (AEAD 면 태그가 대신한다 — 여기서는 안 다룬다)
//! ```
//!
//! **패딩은 4 이상이고 전체가 블록 배수여야 한다**(RFC 4253 §6). 협상 전(평문 구간)의 블록은
//! 8 이고, AEAD 로 넘어가면 그 규칙은 암호 계층이 든다 — 이 모듈은 **평문 프레이밍**만 안다.
//!
//! **왜 payload 만 돌려주나.** 위층(KEX·인증·채널)은 메시지 번호와 그 뒤 바이트만 필요하고,
//! 패딩·길이는 이 층의 사정이다. 경계를 그렇게 그어야 위층 테스트가 패딩 규칙에 안 묶인다.

const std = @import("std");

/// 평문 구간의 블록 크기(RFC 4253 §6 — 암호가 협상되기 전에는 8 로 본다).
pub const plain_block = 8;

/// 패딩 최소치(RFC 4253 §6).
pub const min_padding = 4;

/// **패킷 길이 상한.** RFC 4253 §6.1 은 32768 을 "모든 구현이 받아야 하는 크기" 로 두고,
/// 그보다 큰 값을 받으면 **메모리를 그만큼 잡아 주게 된다** — 악의적 서버가 4GiB 를 부르면
/// 그대로 죽는다. 우리는 터미널 트래픽만 다루므로 넉넉히 256KiB 로 자른다.
pub const max_packet = 256 * 1024;

pub const Error = error{
    /// 길이가 상한을 넘었다(위 `max_packet`).
    PacketTooLarge,
    /// 패딩이 4 미만이거나 길이가 블록 배수가 아니다 — 프레이밍이 깨졌다는 뜻이다.
    MalformedPacket,
    /// 아직 다 안 왔다. 더 읽어서 다시 부른다.
    Incomplete,
};

/// 평문 패킷 하나를 쓴다. `out` 은 `writtenLen(payload.len)` 이상이어야 한다.
///
/// `rand` 는 패딩을 채운다. **패딩은 임의값이어야 한다**(RFC 4253 §6) — 0 으로 채우면 그
/// 자체로 평문 정보가 되고, 오래된 암호 조합에서는 공격 자료가 된다.
///
/// **`payload` 와 `out` 은 겹치면 안 된다.** `writtenLen` 으로 크기를 물어 한 버퍼를 잡고 그
/// 안에서 제자리로 감싸고 싶어지는데, 그러면 Debug·ReleaseSafe 에서는 `@memcpy arguments alias`
/// 로 죽고 **ReleaseFast 에서는 조용히 패킷이 망가진다**(배포 `.dmg` 가 그 모드다 — 실측했다).
/// 겹치는 검사를 런타임에 넣지 않는 이유는 그것이 정상 경로에 없는 비용이기 때문이다. 대신
/// 여기에 적어 둔다: **payload 는 별도 버퍼에서 온다.**
pub fn write(out: []u8, payload: []const u8, rand: std.Random) Error!usize {
    const pad = paddingFor(payload.len);
    const total = 4 + 1 + payload.len + pad;
    if (total > max_packet) return Error.PacketTooLarge;
    if (out.len < total) return Error.MalformedPacket;
    std.mem.writeInt(u32, out[0..4], @intCast(1 + payload.len + pad), .big);
    out[4] = @intCast(pad);
    @memcpy(out[5..][0..payload.len], payload);
    rand.bytes(out[5 + payload.len ..][0..pad]);
    return total;
}

/// `write` 가 쓸 바이트 수. 버퍼를 잡기 전에 묻는다.
pub fn writtenLen(payload_len: usize) usize {
    return 4 + 1 + payload_len + paddingFor(payload_len);
}

/// 패딩 길이. **4 이상이면서 전체(길이 필드 포함)를 블록 배수로** 만드는 가장 작은 값이다.
fn paddingFor(payload_len: usize) usize {
    const unpadded = 4 + 1 + payload_len;
    var pad = plain_block - (unpadded % plain_block);
    if (pad < min_padding) pad += plain_block;
    return pad;
}

/// 읽어 낸 패킷 하나.
pub const Decoded = struct {
    /// 메시지 번호 + 그 뒤 바이트. **`buf` 안을 가리킨다** — 복사하지 않는다.
    payload: []const u8,
    /// 이 패킷이 먹은 바이트 수. 호출자는 그만큼 버퍼를 앞으로 민다.
    consumed: usize,
};

/// 평문 패킷 하나를 읽는다. 덜 왔으면 `Incomplete` 다 — **오류가 아니라 상태**이고, 더 읽어
/// 다시 부르면 된다.
pub fn read(buf: []const u8) Error!Decoded {
    if (buf.len < 4) return Error.Incomplete;
    const len = std.mem.readInt(u32, buf[0..4], .big);
    if (len > max_packet) return Error.PacketTooLarge;
    // **길이가 0 이면 패딩 필드조차 없다.** 그대로 두면 아래에서 빈 슬라이스를 자르게 된다.
    if (len < 1 + min_padding) return Error.MalformedPacket;
    const total = 4 + len;
    if (buf.len < total) return Error.Incomplete;
    const pad: usize = buf[4];
    if (pad < min_padding) return Error.MalformedPacket;
    // **payload 는 최소 1바이트다** — SSH 메시지는 전부 메시지 번호 바이트로 시작한다(RFC 4253 §6
    // 의 payload 는 그 번호를 포함한다). 그래서 `>` 가 아니라 `>=` 다: `>` 로 두면 길이 0 payload 가
    // 모든 가드를 통과하고, 번호를 `payload[0]` 로 읽는 **첫 소비자가 죽는다**(ReleaseFast 에서는
    // 슬라이스 밖을 읽어 **공격자가 고른 패딩 바이트를 메시지 번호로** 삼는다). 실측으로 확인했다.
    // 이 검사는 아래 슬라이스의 뺄셈이 음수로 감싸 도는 것도 같이 막는다(`len - pad > 1` 이 된다).
    if (1 + pad >= len) return Error.MalformedPacket;
    if (total % plain_block != 0) return Error.MalformedPacket;
    return .{ .payload = buf[5 .. 4 + len - pad], .consumed = total };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

test "쓴 패킷을 그대로 읽는다" {
    var prng = std.Random.DefaultPrng.init(1);
    var out: [256]u8 = undefined;
    const payload = "hello ssh";
    const n = try write(&out, payload, prng.random());
    try std.testing.expectEqual(writtenLen(payload.len), n);
    const got = try read(out[0..n]);
    try std.testing.expectEqualStrings(payload, got.payload);
    try std.testing.expectEqual(n, got.consumed);
}

test "전체 길이는 블록 배수이고 패딩은 4 이상이다" {
    var prng = std.Random.DefaultPrng.init(2);
    var out: [512]u8 = undefined;
    // 경계를 훑는다 — 배수에 딱 맞는 자리에서 패딩이 4 미만으로 떨어지면 안 된다.
    var len: usize = 0;
    while (len < 64) : (len += 1) {
        const payload = out[256..][0..len];
        const n = try write(out[0..256], payload, prng.random());
        try std.testing.expectEqual(@as(usize, 0), n % plain_block);
        try std.testing.expect(out[4] >= min_padding);
    }
}

test "덜 온 바이트는 오류가 아니라 Incomplete 다" {
    var prng = std.Random.DefaultPrng.init(3);
    var out: [128]u8 = undefined;
    const n = try write(&out, "abcdef", prng.random());
    // 길이 필드조차 덜 온 경우와, 몸통이 덜 온 경우 둘 다.
    try std.testing.expectError(Error.Incomplete, read(out[0..2]));
    try std.testing.expectError(Error.Incomplete, read(out[0 .. n - 1]));
    _ = try read(out[0..n]);
}

test "터무니없는 길이는 메모리를 잡기 전에 거절한다" {
    // **이 검사가 없으면 서버가 4GiB 를 불러 우리를 죽인다**(길이만 보고 버퍼를 잡는 구조).
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xFFFF_FFFF, .big);
    try std.testing.expectError(Error.PacketTooLarge, read(&buf));
}

test "깨진 프레이밍은 거절한다" {
    var prng = std.Random.DefaultPrng.init(4);
    var out: [128]u8 = undefined;
    const n = try write(&out, "payload", prng.random());

    // 패딩이 4 미만이라고 주장하는 패킷.
    var bad = out;
    bad[4] = 3;
    try std.testing.expectError(Error.MalformedPacket, read(bad[0..n]));

    // 패딩이 내용보다 긴 패킷 — 이 검사가 없으면 슬라이스 뺄셈이 감싸 돈다.
    var bad2 = out;
    bad2[4] = 0xFF;
    try std.testing.expectError(Error.MalformedPacket, read(bad2[0..n]));

    // 길이가 1+min_padding 보다 작은 패킷.
    var bad3: [16]u8 = undefined;
    std.mem.writeInt(u32, bad3[0..4], 2, .big);
    try std.testing.expectError(Error.MalformedPacket, read(&bad3));

    // **payload 가 0바이트인 패킷.** 다른 가드(길이 하한·패딩 하한·블록 배수)를 전부 통과하는데
    // 메시지 번호가 없다 — 받아 주면 그것을 읽는 쪽이 죽는다. 길이 12, 패딩 11 이면 정확히 그 모양이다.
    var bad5: [16]u8 = undefined;
    @memset(&bad5, 0xAA);
    std.mem.writeInt(u32, bad5[0..4], 12, .big);
    bad5[4] = 11;
    try std.testing.expectError(Error.MalformedPacket, read(&bad5));

    // **payload 가 1바이트인 패킷은 정당하다** — 경계 바로 옆이라 같이 못박는다(예: NEWKEYS).
    var ok1: [16]u8 = undefined;
    @memset(&ok1, 0xAA);
    std.mem.writeInt(u32, ok1[0..4], 12, .big);
    ok1[4] = 10;
    ok1[5] = 21; // SSH_MSG_NEWKEYS
    const one = try read(&ok1);
    try std.testing.expectEqual(@as(usize, 1), one.payload.len);
    try std.testing.expectEqual(@as(u8, 21), one.payload[0]);

    // **전체가 블록 배수가 아닌 패킷.** 다른 검사(패딩 하한·패딩>내용)는 다 통과하지만
    // 프레이밍이 어긋난 것이라 거절해야 한다 — 이 검사를 지우는 변이가 통과하는 것을 보고 넣었다.
    var bad4: [32]u8 = undefined;
    @memset(&bad4, 0);
    std.mem.writeInt(u32, bad4[0..4], 9, .big); // 4+9=13 — 8 의 배수가 아니다
    bad4[4] = min_padding; // 패딩은 유효하게 둔다(다른 가드에 안 걸리게)
    try std.testing.expectError(Error.MalformedPacket, read(bad4[0..13]));
}

test "패딩은 0 으로 채우지 않는다" {
    // 임의값이어야 한다(RFC 4253 §6). 같은 payload 를 두 번 써서 패딩이 다른지 본다 —
    // 상수로 채우면 이 테스트가 잡는다.
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var p1 = std.Random.DefaultPrng.init(5);
    var p2 = std.Random.DefaultPrng.init(6);
    const n1 = try write(&a, "x", p1.random());
    const n2 = try write(&b, "x", p2.random());
    try std.testing.expectEqual(n1, n2);
    try std.testing.expect(!std.mem.eql(u8, a[0..n1], b[0..n2]));
}
