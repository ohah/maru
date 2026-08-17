//! `SSH_MSG_KEXINIT` 만들기·읽기·협상(RFC 4253 §7.1) + strict KEX 표시자.
//!
//! 페이로드는 이렇게 생겼다:
//!
//! ```text
//!   byte         SSH_MSG_KEXINIT (20)
//!   byte[16]     cookie          (임의값)
//!   name-list    kex_algorithms
//!   name-list    server_host_key_algorithms
//!   name-list    encryption_algorithms_client_to_server
//!   name-list    encryption_algorithms_server_to_client
//!   name-list    mac_algorithms_client_to_server
//!   name-list    mac_algorithms_server_to_client
//!   name-list    compression_algorithms_client_to_server
//!   name-list    compression_algorithms_server_to_client
//!   name-list    languages_client_to_server
//!   name-list    languages_server_to_client
//!   boolean      first_kex_packet_follows
//!   uint32       0 (reserved)
//! ```
//!
//! **이 페이로드 전체가 교환 해시에 들어간다**(§8) — 보낸 바이트와 받은 바이트를 **그대로**
//! 보관해야 한다. 다시 만들어 쓰면 cookie 가 달라져 해시가 안 맞는다.
//!
//! **MAC 목록은 AEAD 라도 비워 보내지 않는다**(계약 §3) — 협상 대상이 아니어도 서버가 그
//! 자리를 파싱한다.

const std = @import("std");
const wire = @import("wire.zig");

pub const msg_kexinit: u8 = 20;
pub const cookie_len = 16;

/// strict KEX 표시자(draft-ietf-sshm-strict-kex §3.1). **표준과 구형을 둘 다 보낸다** —
/// 표준 이름만 보내면 구형만 아는 서버가 못 알아듣고, 구형만 보내면 그 반대다.
///
/// **실측(2026-08-17, OpenSSH 10.2)**: 서버는 `kex-strict-s-v00@openssh.com` **하나만** 보낸다 —
/// 표준 이름은 아직 안 쓴다. 즉 우리가 표준 이름만 보냈다면 오늘의 OpenSSH 와 strict KEX 가
/// **조용히 안 켜졌을** 것이다(그리고 그것을 알 방법이 없다).
pub const strict_c = "kex-strict-c";
pub const strict_c_v00 = "kex-strict-c-v00@openssh.com";
pub const strict_s = "kex-strict-s";
pub const strict_s_v00 = "kex-strict-s-v00@openssh.com";

/// 우리가 지원하는 것(계약 §3). **순서가 곧 선호**다(RFC 4253 §7.1 은 클라이언트 선호를 따른다).
pub const our = struct {
    pub const kex = [_][]const u8{ "curve25519-sha256", "curve25519-sha256@libssh.org" };
    pub const host_key = [_][]const u8{"ssh-ed25519"};
    pub const cipher = [_][]const u8{"chacha20-poly1305@openssh.com"};
    /// AEAD 라 쓰이지 않지만 **자리는 채운다**(계약 §3).
    pub const mac = [_][]const u8{"hmac-sha2-256"};
    pub const compression = [_][]const u8{"none"};
};

pub const Error = error{
    /// KEXINIT 이 아니다.
    NotKexInit,
    /// 우리와 서버가 겹치는 알고리즘이 없다.
    NoCommonAlgorithm,
} || wire.Error || wire.Writer.WriteError;

/// 서버 KEXINIT 에서 읽어 낸 목록들.
pub const Peer = struct {
    kex: wire.NameList,
    host_key: wire.NameList,
    cipher_c2s: wire.NameList,
    cipher_s2c: wire.NameList,
    mac_c2s: wire.NameList,
    mac_s2c: wire.NameList,
    comp_c2s: wire.NameList,
    comp_s2c: wire.NameList,

    /// 서버가 strict KEX 를 말하나(표준·구형 어느 쪽이든).
    pub fn strictKex(self: Peer) bool {
        return self.kex.has(strict_s) or self.kex.has(strict_s_v00);
    }
};

/// 협상 결과.
pub const Negotiated = struct {
    kex: []const u8,
    host_key: []const u8,
    cipher_c2s: []const u8,
    cipher_s2c: []const u8,
    /// 양쪽이 다 말했을 때만 참(draft §3.1 — 한쪽만으로는 안 켠다).
    strict_kex: bool,
};

/// 우리 KEXINIT 페이로드를 쓴다. **쓴 바이트를 그대로 보관해 교환 해시에 쓴다.**
pub fn write(out: []u8, rand: std.Random) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_kexinit);
    var cookie: [cookie_len]u8 = undefined;
    rand.bytes(&cookie);
    try w.raw(&cookie);

    // **strict KEX 표시자를 kex 목록에 같이 넣는다**(draft §3.1 — 별도 필드가 아니다).
    try w.nameList(&(our.kex ++ [_][]const u8{ strict_c, strict_c_v00 }));
    try w.nameList(&our.host_key);
    try w.nameList(&our.cipher); // c2s
    try w.nameList(&our.cipher); // s2c
    try w.nameList(&our.mac); // c2s
    try w.nameList(&our.mac); // s2c
    try w.nameList(&our.compression); // c2s
    try w.nameList(&our.compression); // s2c
    try w.nameList(&.{}); // languages c2s
    try w.nameList(&.{}); // languages s2c
    // **추측 패킷을 안 보낸다.** 보내면 서버가 우리 추측과 다를 때 그것을 버려야 하고,
    // 그 규칙(§7.1)을 지키는 코드가 하나 더 는다 — 왕복 한 번을 아끼자고 할 일이 아니다.
    try w.boolean(false);
    try w.u32be(0); // reserved
    return w.written();
}

/// 서버 KEXINIT 페이로드를 읽는다. **메시지 번호부터** 넘긴다.
pub fn parse(payload: []const u8) Error!Peer {
    var r = wire.Reader.init(payload);
    if ((try r.byte()) != msg_kexinit) return Error.NotKexInit;
    _ = try r.fixed(cookie_len);
    const p: Peer = .{
        .kex = try r.nameList(),
        .host_key = try r.nameList(),
        .cipher_c2s = try r.nameList(),
        .cipher_s2c = try r.nameList(),
        .mac_c2s = try r.nameList(),
        .mac_s2c = try r.nameList(),
        .comp_c2s = try r.nameList(),
        .comp_s2c = try r.nameList(),
    };
    _ = try r.nameList(); // languages c2s
    _ = try r.nameList(); // languages s2c
    _ = try r.boolean(); // first_kex_packet_follows
    _ = try r.u32be(); // reserved
    return p;
}

/// 겹치는 것을 고른다. **우리 선호 순서**를 따른다(RFC 4253 §7.1).
pub fn negotiate(peer: Peer) Error!Negotiated {
    // **압축은 `none` 만 받는다**(계약 §3). 서버가 그것을 안 주면 붙지 않는다 — 조용히
    // 다른 것을 고르면 우리가 못 푸는 데이터를 받게 된다.
    if (peer.comp_c2s.pick(&our.compression) == null) return Error.NoCommonAlgorithm;
    if (peer.comp_s2c.pick(&our.compression) == null) return Error.NoCommonAlgorithm;
    return .{
        .kex = peer.kex.pick(&our.kex) orelse return Error.NoCommonAlgorithm,
        .host_key = peer.host_key.pick(&our.host_key) orelse return Error.NoCommonAlgorithm,
        .cipher_c2s = peer.cipher_c2s.pick(&our.cipher) orelse return Error.NoCommonAlgorithm,
        .cipher_s2c = peer.cipher_s2c.pick(&our.cipher) orelse return Error.NoCommonAlgorithm,
        .strict_kex = peer.strictKex(),
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

const test_server_kexinit = blk: {
    // OpenSSH 9.x 가 보내는 것과 같은 모양(우리 것과 겹치는 알고리즘을 포함).
    @setEvalBranchQuota(10000);
    break :blk struct {
        fn build(out: []u8, opts: struct {
            strict: bool = true,
            kex: []const u8 = "curve25519-sha256,ecdh-sha2-nistp256",
            host_key: []const u8 = "rsa-sha2-512,ssh-ed25519",
            cipher: []const u8 = "aes128-ctr,chacha20-poly1305@openssh.com",
            comp: []const u8 = "none,zlib@openssh.com",
            comp_s2c: ?[]const u8 = null,
        }) ![]const u8 {
            var w = wire.Writer.init(out);
            try w.byte(msg_kexinit);
            try w.raw(&[_]u8{0} ** cookie_len);
            if (opts.strict) {
                var buf: [512]u8 = undefined;
                const joined = try std.fmt.bufPrint(&buf, "{s},{s}", .{ opts.kex, strict_s_v00 });
                try w.string(joined);
            } else try w.string(opts.kex);
            try w.string(opts.host_key);
            try w.string(opts.cipher);
            try w.string(opts.cipher);
            try w.string("hmac-sha2-256");
            try w.string("hmac-sha2-256");
            try w.string(opts.comp);
            try w.string(opts.comp_s2c orelse opts.comp);
            try w.string("");
            try w.string("");
            try w.boolean(false);
            try w.u32be(0);
            return w.written();
        }
    };
};

test "우리 KEXINIT 을 우리가 다시 읽는다" {
    var prng = std.Random.DefaultPrng.init(1);
    var out: [1024]u8 = undefined;
    const payload = try write(&out, prng.random());
    const p = try parse(payload);
    try std.testing.expect(p.kex.has("curve25519-sha256"));
    try std.testing.expect(p.host_key.has("ssh-ed25519"));
    try std.testing.expect(p.cipher_c2s.has("chacha20-poly1305@openssh.com"));
    // **MAC 자리를 비우지 않는다**(계약 §3).
    try std.testing.expect(p.mac_c2s.raw.len > 0);
}

test "strict KEX 표시자를 표준·구형 둘 다 보낸다" {
    // 하나만 보내면 다른 쪽만 아는 서버와 안 켜진다 — 켜졌다고 착각하면 더 나쁘다.
    var prng = std.Random.DefaultPrng.init(2);
    var out: [1024]u8 = undefined;
    const p = try parse(try write(&out, prng.random()));
    try std.testing.expect(p.kex.has(strict_c));
    try std.testing.expect(p.kex.has(strict_c_v00));
}

test "cookie 는 매번 달라야 한다" {
    // 같은 cookie 를 쓰면 교환 해시가 재사용 가능해진다.
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    var p1 = std.Random.DefaultPrng.init(3);
    var p2 = std.Random.DefaultPrng.init(4);
    const wa = try write(&a, p1.random());
    const wb = try write(&b, p2.random());
    try std.testing.expect(!std.mem.eql(u8, wa[1..][0..cookie_len], wb[1..][0..cookie_len]));
}

test "서버 목록에서 우리 선호대로 고른다" {
    var out: [1024]u8 = undefined;
    const n = try negotiate(try parse(try test_server_kexinit.build(&out, .{})));
    try std.testing.expectEqualStrings("curve25519-sha256", n.kex);
    try std.testing.expectEqualStrings("ssh-ed25519", n.host_key); // 서버가 rsa 를 먼저 적었어도
    try std.testing.expectEqualStrings("chacha20-poly1305@openssh.com", n.cipher_s2c);
    try std.testing.expect(n.strict_kex);
}

test "서버가 strict 를 안 말하면 안 켠다" {
    // **한쪽만으로는 안 켠다**(draft §3.1) — 켜졌다고 착각하면 시퀀스 리셋이 어긋나 연결이 깨진다.
    var out: [1024]u8 = undefined;
    const n = try negotiate(try parse(try test_server_kexinit.build(&out, .{ .strict = false })));
    try std.testing.expect(!n.strict_kex);
}

test "겹치는 것이 없으면 붙지 않는다" {
    var out: [1024]u8 = undefined;
    // ed25519 호스트키가 없는 서버 — 계약대로 실패한다(조용히 다른 것을 고르지 않는다).
    try std.testing.expectError(Error.NoCommonAlgorithm, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .host_key = "rsa-sha2-512,ecdsa-sha2-nistp256" }),
    )));
    // 우리 암호가 없는 서버.
    try std.testing.expectError(Error.NoCommonAlgorithm, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .cipher = "aes128-ctr,aes256-gcm@openssh.com" }),
    )));
    // **압축을 강제하는 서버** — `none` 이 없으면 우리가 못 푼다. **방향을 따로 잰다**:
    // 한 방향만 검사하면 나머지 방향의 가드를 지워도 안 드러난다(변이로 확인했다).
    // c2s 만 막힌 서버(s2c 는 멀쩡하다) — 두 방향을 다 검사해야 잡힌다.
    try std.testing.expectError(Error.NoCommonAlgorithm, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .comp = "zlib@openssh.com", .comp_s2c = "none" }),
    )));
    // s2c 만 막힌 서버.
    try std.testing.expectError(Error.NoCommonAlgorithm, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .comp_s2c = "zlib@openssh.com" }),
    )));
}

test "KEXINIT 이 아닌 것은 거절한다" {
    var buf = [_]u8{ 21, 0, 0, 0, 0 }; // NEWKEYS
    try std.testing.expectError(Error.NotKexInit, parse(&buf));
}

test "잘린 KEXINIT 은 거절한다" {
    // **네트워크에서 온 바이트다** — 목록 중간에서 끊긴 것을 받아도 안 죽어야 한다.
    var out: [1024]u8 = undefined;
    const full = try test_server_kexinit.build(&out, .{});
    var i: usize = 1;
    while (i < full.len) : (i += 7) {
        _ = parse(full[0..i]) catch continue;
    }
}

// ── 실서버 벡터 ─────────────────────────────────────────────────────────────
//
// **우리 인코더가 만든 바이트로만 테스트하면 자기충족이다** — 우리가 틀린 방식으로 쓰고 같은
// 방식으로 읽으면 통과한다. 아래는 **진짜 OpenSSH 10.2 가 보낸 KEXINIT 패킷**을 그대로 박은
// 것이다(2026-08-17, `localhost:22` 에서 캡처). 상호운용의 첫 증거이고, 우리 가정이 실제와
// 어긋나면 여기서 깨진다.
const openssh_10_2_kexinit_packet =
    "\x00\x00\x04\x0c\x09\x14\xad\x4d\x3a\x13\x21\xd1\x63\x70\x55\xbe\xae\x63\xde\x59\x19\x05\x00\x00\x00\xdf\x65\x63\x64\x68\x2d\x73" ++
    "\x68\x61\x32\x2d\x6e\x69\x73\x74\x70\x32\x35\x36\x2c\x6d\x6c\x6b\x65\x6d\x37\x36\x38\x78\x32\x35\x35\x31\x39\x2d\x73\x68\x61\x32" ++
    "\x35\x36\x2c\x73\x6e\x74\x72\x75\x70\x37\x36\x31\x78\x32\x35\x35\x31\x39\x2d\x73\x68\x61\x35\x31\x32\x2c\x73\x6e\x74\x72\x75\x70" ++
    "\x37\x36\x31\x78\x32\x35\x35\x31\x39\x2d\x73\x68\x61\x35\x31\x32\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x63\x75\x72" ++
    "\x76\x65\x32\x35\x35\x31\x39\x2d\x73\x68\x61\x32\x35\x36\x2c\x63\x75\x72\x76\x65\x32\x35\x35\x31\x39\x2d\x73\x68\x61\x32\x35\x36" ++
    "\x40\x6c\x69\x62\x73\x73\x68\x2e\x6f\x72\x67\x2c\x65\x63\x64\x68\x2d\x73\x68\x61\x32\x2d\x6e\x69\x73\x74\x70\x33\x38\x34\x2c\x65" ++
    "\x63\x64\x68\x2d\x73\x68\x61\x32\x2d\x6e\x69\x73\x74\x70\x35\x32\x31\x2c\x65\x78\x74\x2d\x69\x6e\x66\x6f\x2d\x73\x2c\x6b\x65\x78" ++
    "\x2d\x73\x74\x72\x69\x63\x74\x2d\x73\x2d\x76\x30\x30\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x00\x00\x00\x39\x72\x73\x61" ++
    "\x2d\x73\x68\x61\x32\x2d\x35\x31\x32\x2c\x72\x73\x61\x2d\x73\x68\x61\x32\x2d\x32\x35\x36\x2c\x65\x63\x64\x73\x61\x2d\x73\x68\x61" ++
    "\x32\x2d\x6e\x69\x73\x74\x70\x32\x35\x36\x2c\x73\x73\x68\x2d\x65\x64\x32\x35\x35\x31\x39\x00\x00\x00\x6c\x61\x65\x73\x31\x32\x38" ++
    "\x2d\x67\x63\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x61\x65\x73\x32\x35\x36\x2d\x67\x63\x6d\x40\x6f\x70\x65\x6e" ++
    "\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x63\x68\x61\x63\x68\x61\x32\x30\x2d\x70\x6f\x6c\x79\x31\x33\x30\x35\x40\x6f\x70\x65\x6e\x73\x73" ++
    "\x68\x2e\x63\x6f\x6d\x2c\x61\x65\x73\x31\x32\x38\x2d\x63\x74\x72\x2c\x61\x65\x73\x31\x39\x32\x2d\x63\x74\x72\x2c\x61\x65\x73\x32" ++
    "\x35\x36\x2d\x63\x74\x72\x00\x00\x00\x6c\x61\x65\x73\x31\x32\x38\x2d\x67\x63\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d" ++
    "\x2c\x61\x65\x73\x32\x35\x36\x2d\x67\x63\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x63\x68\x61\x63\x68\x61\x32\x30" ++
    "\x2d\x70\x6f\x6c\x79\x31\x33\x30\x35\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x61\x65\x73\x31\x32\x38\x2d\x63\x74\x72" ++
    "\x2c\x61\x65\x73\x31\x39\x32\x2d\x63\x74\x72\x2c\x61\x65\x73\x32\x35\x36\x2d\x63\x74\x72\x00\x00\x00\xd5\x68\x6d\x61\x63\x2d\x73" ++
    "\x68\x61\x32\x2d\x32\x35\x36\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61" ++
    "\x32\x2d\x32\x35\x36\x2c\x75\x6d\x61\x63\x2d\x36\x34\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x75\x6d" ++
    "\x61\x63\x2d\x31\x32\x38\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x32" ++
    "\x2d\x35\x31\x32\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x31\x2d\x65" ++
    "\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x75\x6d\x61\x63\x2d\x36\x34\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63" ++
    "\x6f\x6d\x2c\x75\x6d\x61\x63\x2d\x31\x32\x38\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61" ++
    "\x32\x2d\x35\x31\x32\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x31\x00\x00\x00\xd5\x68\x6d\x61\x63\x2d\x73\x68\x61\x32\x2d\x32\x35\x36" ++
    "\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x32\x2d\x32\x35\x36\x2c\x75" ++
    "\x6d\x61\x63\x2d\x36\x34\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x75\x6d\x61\x63\x2d\x31\x32\x38\x2d" ++
    "\x65\x74\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x32\x2d\x35\x31\x32\x2d\x65\x74" ++
    "\x6d\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x31\x2d\x65\x74\x6d\x40\x6f\x70\x65\x6e" ++
    "\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x75\x6d\x61\x63\x2d\x36\x34\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x75\x6d\x61\x63" ++
    "\x2d\x31\x32\x38\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x2c\x68\x6d\x61\x63\x2d\x73\x68\x61\x32\x2d\x35\x31\x32\x2c\x68" ++
    "\x6d\x61\x63\x2d\x73\x68\x61\x31\x00\x00\x00\x15\x6e\x6f\x6e\x65\x2c\x7a\x6c\x69\x62\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f" ++
    "\x6d\x00\x00\x00\x15\x6e\x6f\x6e\x65\x2c\x7a\x6c\x69\x62\x40\x6f\x70\x65\x6e\x73\x73\x68\x2e\x63\x6f\x6d\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

test "실서버(OpenSSH 10.2) KEXINIT 을 읽고 협상한다" {
    const packet = @import("packet.zig");
    const dec = try packet.read(openssh_10_2_kexinit_packet);
    try std.testing.expectEqual(@as(u8, msg_kexinit), dec.payload[0]);

    const p = try parse(dec.payload);
    const n = try negotiate(p);
    // 서버가 먼저 적은 것(ecdh-sha2-nistp256·mlkem…)이 아니라 **우리 선호**가 이긴다.
    try std.testing.expectEqualStrings("curve25519-sha256", n.kex);
    try std.testing.expectEqualStrings("ssh-ed25519", n.host_key);
    try std.testing.expectEqualStrings("chacha20-poly1305@openssh.com", n.cipher_c2s);
    try std.testing.expectEqualStrings("chacha20-poly1305@openssh.com", n.cipher_s2c);
    // **요즘 OpenSSH 는 strict KEX 를 말한다** — 이것이 false 로 나오면 표시자 이름이 틀린 것이다.
    try std.testing.expect(n.strict_kex);
}

test "실서버 KEXINIT 은 우리 패킷 계층의 규칙도 만족한다" {
    const packet = @import("packet.zig");
    const dec = try packet.read(openssh_10_2_kexinit_packet);
    // 전체가 블록 배수이고 패딩이 4 이상이다 — 우리 인코더의 가정이 서버와 같은지 본다.
    try std.testing.expectEqual(@as(usize, 0), dec.consumed % packet.plain_block);
    try std.testing.expect(openssh_10_2_kexinit_packet[4] >= packet.min_padding);
}
