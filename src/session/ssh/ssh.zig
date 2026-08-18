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

// 어떤 바이트열도 **오류로 끝나야** 한다 — 패닉·UB 는 안 된다. ReleaseSafe 로 돌려 UB 가 잡히게 한다.
test "적대적 입력: 어떤 바이트열도 패닉시키지 못한다" {
    var prng = std.Random.DefaultPrng.init(0xA55E);
    const rand = prng.random();
    var buf: [1024]u8 = undefined;
    var out: [2048]u8 = undefined;
    var scratch: [2048]u8 = undefined;

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const len = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..len]);
        const b = buf[0..len];

        // 구조적 편향: 앞머리를 그럴싸하게 만들어 깊은 경로까지 들어가게 한다.
        if (i % 4 == 1 and len > 16) {
            b[0] = kexinit.msg_kexinit;
        } else if (i % 4 == 2 and len > 16) {
            @memcpy(b[0..15], "openssh-key-v1\x00");
        } else if (i % 4 == 3 and len > 8) {
            b[0] = 60; // userauth method-specific
        }

        _ = packet.read(b) catch {};
        _ = kexinit.parse(b) catch {};
        _ = hostkey.parsePublicKey(b) catch {};
        _ = hostkey.parseSignature(b) catch {};
        _ = private_key.kdfRounds(b) catch {};
        // **`max_kdf_rounds = 0` 이라 bcrypt 는 안 돈다** — Debug 에서 KDF 에 닿는 호출 하나가
        // 약 470ms 라 그것만으로 퍼즈가 29초가 됐다(실측). KDF 는 std 코드고 여기서 볼 것은 그
        // **앞뒤 파싱**이다. KDF 뒤 구조 파싱은 실제 키 벡터로 도는 단위 테스트가 덮는다.
        _ = private_key.parse(b, "pw", &scratch, .{ .max_kdf_rounds = 0 }) catch {};
        _ = userauth.parseResponse(b, .publickey) catch {};
        _ = userauth.parseResponse(b, .password) catch {};
        _ = version.parse(b) catch {};
        var r = wire.Reader.init(b);
        _ = r.string() catch {};
        _ = r.nameList() catch {};
        _ = r.u32be() catch {};

        var t: transport.Transport = .{};
        _ = t.feed(&out, b) catch {};
        var t2: transport.Transport = .{ .strict_kex = true, .pending_discard = true, .first_from_peer = kexinit.msg_kexinit };
        _ = t2.feed(&out, b) catch {};

        _ = known_hosts.parseLine(b);
        _ = known_hosts.matchesHost(b, "host.example");
        _ = known_hosts.verify(b, "host.example", "ssh-ed25519", &[_]u8{0} ** 32);
    }
}

// **유효한 것을 비트 단위로 망가뜨린다.** 순수 무작위는 첫 길이 검사에서 튕겨 깊은 경로에 안 닿는다.
test "적대적 입력: 유효 메시지를 망가뜨려도 패닉시키지 못한다" {
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rand = prng.random();
    var out: [4096]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    var wire_out: [4096]u8 = undefined;

    // 씨앗 1: 우리 KEXINIT 페이로드
    var kexinit_buf: [4096]u8 = undefined;
    const valid_kexinit = try kexinit.write(&kexinit_buf, rand);

    // 씨앗 2: 그것을 담은 온전한 패킷
    var pkt_buf: [4096]u8 = undefined;
    const pkt_len = try packet.write(&pkt_buf, valid_kexinit, rand);

    // 씨앗 3: ed25519 공개키 blob
    var blob_buf: [128]u8 = undefined;
    var w = wire.Writer.init(&blob_buf);
    try w.string(hostkey.alg_name);
    try w.string(&([_]u8{7} ** 32));
    const valid_blob = w.written();

    // 씨앗 4: 버전 줄
    const valid_version = "SSH-2.0-OpenSSH_10.2\r\n";

    const seeds = [_][]const u8{ valid_kexinit, pkt_buf[0..pkt_len], valid_blob, valid_version };

    var i: usize = 0;
    while (i < 2500) : (i += 1) {
        const seed = seeds[rand.uintLessThan(usize, seeds.len)];
        var mutated: [4096]u8 = undefined;
        @memcpy(mutated[0..seed.len], seed);
        var m = mutated[0..seed.len];

        // 1~4 군데를 뒤집는다.
        const flips = 1 + rand.uintLessThan(usize, 4);
        var f: usize = 0;
        while (f < flips and m.len > 0) : (f += 1) {
            m[rand.uintLessThan(usize, m.len)] ^= @as(u8, 1) << rand.int(u3);
        }
        // 가끔 길이도 자른다(잘린 입력이 다른 경로다).
        if (i % 5 == 0 and m.len > 1) m = m[0 .. rand.uintLessThan(usize, m.len) + 1];

        _ = packet.read(m) catch {};
        _ = kexinit.parse(m) catch {};
        if (kexinit.parse(m)) |peer| {
            _ = kexinit.negotiate(peer, .initial) catch {};
            _ = kexinit.negotiate(peer, .{ .rekey = true }) catch {};
        } else |_| {}
        _ = hostkey.parsePublicKey(m) catch {};
        _ = hostkey.parseSignature(m) catch {};
        _ = private_key.kdfRounds(m) catch {};
        _ = private_key.parse(m, "pw", &scratch, .{ .max_kdf_rounds = 0 }) catch {};
        _ = userauth.parseResponse(m, .publickey) catch {};
        _ = userauth.parseResponse(m, .password) catch {};
        _ = version.parse(m) catch {};
        _ = known_hosts.verify(m, "host.example", "ssh-ed25519", &([_]u8{0} ** 32));

        var t: transport.Transport = .{};
        if (t.feed(&out, m)) |maybe| {
            if (maybe) |got| switch (got) {
                .packet => |pk| std.mem.doNotOptimizeAway(pk.payload.len),
                .discarded => |d| std.mem.doNotOptimizeAway(d.consumed),
            };
        } else |_| {}
        var t2: transport.Transport = .{ .strict_kex = true, .pending_discard = true, .first_from_peer = kexinit.msg_kexinit };
        _ = t2.feed(&out, m) catch {};
        _ = t2.send(&wire_out, m[0..@min(m.len, 64)], rand) catch {};
    }
}
