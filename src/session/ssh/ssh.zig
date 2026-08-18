//! SSH 층 전체를 한 번에 컴파일·테스트하는 진입점.
//!
//! **세 최적화 모드로 다 돌리려고 있다**(`zig build check-ssh-modes`). `std` 의 몇몇 검사가
//! `if (std.debug.runtime_safety)` 뒤에 있어 **배포가 쓰는 ReleaseFast 에서 사라지는데**,
//! `zig build test` 는 Debug 라 CI 가 영영 못 본다 — 실제로 개인키 공개키 대조가 그렇게 빠져
//! 있었다(계약 §4.4.4).

const std = @import("std");

pub const packet = @import("packet.zig");
pub const wire = @import("wire.zig");
pub const version = @import("version.zig");
pub const kexinit = @import("kexinit.zig");
pub const kex = @import("kex.zig");
pub const cipher = @import("cipher.zig");
pub const transport = @import("transport.zig");
pub const hostkey = @import("hostkey.zig");
pub const known_hosts = @import("known_hosts.zig");
pub const userauth = @import("userauth.zig");
pub const private_key = @import("private_key.zig");

test {
    std.testing.refAllDecls(@This());
}

// **조립 검사.** 개별 모듈이 다 맞아도 한 연결 안에서 순서대로 안 맞물리면 방향이 틀린 것이다.
// 여기가 모든 모듈을 아는 유일한 자리라 이 테스트가 여기 산다(전송기가 협상 모듈을 import 하면
// 층이 양방향이 된다). 실서버 왕복은 S8 이 보고, 여기서는 **API 가 계약 §4.5 의 순서대로
// 불릴 수 있는지**를 본다.

test "조립: 버전 교환 → KEXINIT → strict 켜기 → 폐기 처리" {
    var prng = std.Random.DefaultPrng.init(2026);
    const rand = prng.random();

    // 1) 우리 KEXINIT 을 쓴다. **원문을 보관해야 한다**(교환 해시 I_C).
    var i_c_buf: [4096]u8 = undefined;
    const i_c = try kexinit.write(&i_c_buf, rand);

    // 2) 서버 KEXINIT 을 만든다(추측 패킷을 붙였다고 표시 — 폐기 경로를 태운다).
    var srv_buf: [4096]u8 = undefined;
    var w = wire.Writer.init(&srv_buf);
    try w.byte(kexinit.msg_kexinit);
    var cookie: [16]u8 = undefined;
    rand.bytes(&cookie);
    try w.raw(&cookie);
    try w.nameList(&[_][]const u8{ "curve25519-sha256@libssh.org", "curve25519-sha256", kexinit.strict_s_v00 });
    try w.nameList(&[_][]const u8{"ssh-ed25519"});
    try w.nameList(&[_][]const u8{"chacha20-poly1305@openssh.com"});
    try w.nameList(&[_][]const u8{"chacha20-poly1305@openssh.com"});
    try w.nameList(&[_][]const u8{"hmac-sha2-256"});
    try w.nameList(&[_][]const u8{"hmac-sha2-256"});
    try w.nameList(&[_][]const u8{"none"});
    try w.nameList(&[_][]const u8{"none"});
    try w.nameList(&.{});
    try w.nameList(&.{});
    try w.boolean(true); // first_kex_packet_follows — 추측을 붙였다
    try w.u32be(0);
    const i_s_wire = w.written();

    // 3) 선에 올린다: 서버 KEXINIT + (틀린 추측 패킷) + 진짜 ECDH_REPLY 자리
    var line: [8192]u8 = undefined;
    var n: usize = 0;
    n += try packet.write(line[n..], i_s_wire, rand);
    n += try packet.write(line[n..], &[_]u8{ 31, 0xDE, 0xAD }, rand); // 서버의 틀린 추측
    n += try packet.write(line[n..], &[_]u8{ 31, 0xBE, 0xEF }, rand); // 진짜 REPLY

    // 4) 드라이버.
    var t: transport.Transport = .{};
    var out: [4096]u8 = undefined;
    var rest: []const u8 = line[0..n];

    // 4-1) 서버 KEXINIT 을 읽고 **원문을 복사해 보관한다**(계약: payload 는 다음 feed 까지만 산다).
    const first = (try t.feed(&out, rest)).?;
    switch (first) {
        .discarded => return error.UnexpectedDiscard,
        .packet => |p| {
            var i_s: [4096]u8 = undefined;
            @memcpy(i_s[0..p.payload.len], p.payload);
            const i_s_kept = i_s[0..p.payload.len];
            rest = rest[p.consumed..];

            const peer = try kexinit.parse(i_s_kept);
            const neg = try kexinit.negotiate(peer, .initial);
            try std.testing.expect(neg.strict_kex);
            try std.testing.expect(neg.discard_guess); // 우리는 추측을 안 붙였으니 틀렸다

            // 4-2) 협상 결과를 전송기에 반영한다.
            // **한 번에 반영한다** — 반쪽만 반영되는 상태가 안 생긴다.
            try t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

            // 4-3) 다음 패킷은 **버려져야** 한다 — 타입이 그것을 말한다.
            const second = (try t.feed(&out, rest)).?;
            try std.testing.expect(second == .discarded);
            rest = rest[second.discarded.consumed..];

            // 4-4) 그 다음이 진짜 REPLY.
            const third = (try t.feed(&out, rest)).?.packet;
            try std.testing.expectEqual(@as(u8, 31), third.payload[0]);

            // 보관한 I_S 는 세 번의 feed 를 지나도 그대로다.
            try std.testing.expectEqualSlices(u8, i_s_wire, i_s_kept);
            try std.testing.expect(i_c.len > 0);
        },
    }
}
