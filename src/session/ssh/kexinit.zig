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
    /// 겹치는 KEX 알고리즘이 없다.
    NoCommonKex,
    /// **겹치는 호스트키 알고리즘이 없다** — 계약 §3 은 이때 "이 서버는 ed25519 호스트키를 안
    /// 준다" 를 사용자에게 그대로 보여 주라고 한다. 여섯 경우를 오류 하나로 뭉개면 **어떤
    /// 호출자도 그 문장을 만들 수 없다**(모바일에는 `ssh -vvv` 같은 대안도 없다).
    NoCommonHostKey,
    /// 겹치는 암호가 없다(방향은 아래 둘로 가른다 — 한 방향만 막힌 서버가 실제로 있다).
    NoCommonCipherC2s,
    NoCommonCipherS2c,
    /// 압축을 `none` 으로 못 한다.
    NoCommonCompressionC2s,
    NoCommonCompressionS2c,
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
    /// 서버가 **추측 패킷을 뒤에 붙였나**(RFC 4253 §7.1). 참인데 추측이 틀렸으면 그 패킷을
    /// 조용히 버려야 한다 — 안 버리면 KEX 응답이 와야 할 자리에서 그것을 먹는다.
    first_kex_packet_follows: bool,

    /// 서버가 strict KEX 를 말하나(표준·구형 어느 쪽이든).
    ///
    /// **일부러 비공개다.** 표시자는 초기 KEXINIT 에서만 유효한데(draft §3.1), 이것이 공개면
    /// 바깥에서 아무 KEXINIT 에나 물어볼 수 있고 그것이 정확히 고치려던 결함이다. 단일 진입점은
    /// `negotiate` 이고, 거기서 `Phase` 가 "초기냐 재키잉이냐" 를 강제한다.
    fn strictKex(self: Peer) bool {
        return self.kex.has(strict_s) or self.kex.has(strict_s_v00);
    }
};

/// 이 KEXINIT 이 초기 것인가 재키잉인가.
///
/// **왜 인자로 받나.** strict KEX 표시자는 **초기 KEXINIT 에서만 유효**하고 이후 것은 "MUST be
/// ignored" 다(draft §3.1). 표시자를 볼 때마다 다시 계산하면 표시자를 안 붙이는 재키잉에서
/// **Terrapin 보호가 조용히 꺼진다** — 우리는 시퀀스 리셋을 멈추고 서버는 리셋해서, 그 뒤 모든
/// AEAD 태그가 어긋난다. 반대로 비-strict 서버가 재키잉에 표시자를 붙여도 켜지면 안 된다.
///
/// 재키잉 쪽이 **연결이 초기 KEX 에서 정한 값을 들고 오게** 해서, 그 값을 잊는 실수를 타입이
/// 막는다(잊으면 컴파일이 안 된다).
pub const Phase = union(enum) {
    initial,
    rekey: bool,
};

/// 협상 결과.
pub const Negotiated = struct {
    kex: []const u8,
    host_key: []const u8,
    cipher_c2s: []const u8,
    cipher_s2c: []const u8,
    /// 양쪽이 다 말했을 때만 참(draft §3.1 — 한쪽만으로는 안 켠다). 재키잉에서는 초기값을 잇는다.
    strict_kex: bool,
    /// **다음 패킷 하나를 조용히 버려라**(RFC 4253 §7.1). 서버가 추측 패킷을 붙였는데 그 추측이
    /// 우리 것과 달랐다는 뜻이다 — 안 버리면 KEX 응답 자리에서 그 패킷을 읽는다.
    discard_guess: bool,
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
    // **와이어 순서대로 지역 변수에 먼저 읽는다.** 구조체 리터럴 안에서 읽으면 "필드를 적은
    // 순서가 곧 와이어 순서" 라는 암묵 규칙이 생겨, 그 둘이 어긋나는 순간 자리가 조용히 밀린다.
    // 게다가 `first_kex_packet_follows` 는 languages 뒤에 오므로 리터럴 안에서는 `undefined` 를
    // 한 번 거쳐야 한다 — 읽기와 조립을 떼면 둘 다 사라진다.
    const kex = try r.nameList();
    const host_key = try r.nameList();
    const cipher_c2s = try r.nameList();
    const cipher_s2c = try r.nameList();
    const mac_c2s = try r.nameList();
    const mac_s2c = try r.nameList();
    const comp_c2s = try r.nameList();
    const comp_s2c = try r.nameList();
    _ = try r.nameList(); // languages c2s
    _ = try r.nameList(); // languages s2c
    const first_kex_packet_follows = try r.boolean();
    _ = try r.u32be(); // reserved
    return .{
        .kex = kex,
        .host_key = host_key,
        .cipher_c2s = cipher_c2s,
        .cipher_s2c = cipher_s2c,
        .mac_c2s = mac_c2s,
        .mac_s2c = mac_s2c,
        .comp_c2s = comp_c2s,
        .comp_s2c = comp_s2c,
        .first_kex_packet_follows = first_kex_packet_follows,
    };
}

/// 서버의 추측이 틀렸나(RFC 4253 §7.1). 추측은 **각 목록의 첫 항목**이고, kex 와 호스트키가
/// **둘 다** 우리 첫 항목과 같아야 맞은 것이다.
fn guessWrong(peer: Peer) bool {
    const peer_kex = peer.kex.first() orelse return true;
    const peer_host_key = peer.host_key.first() orelse return true;
    return !std.mem.eql(u8, peer_kex, our.kex[0]) or
        !std.mem.eql(u8, peer_host_key, our.host_key[0]);
}

/// 겹치는 것을 고른다. **우리 선호 순서**를 따른다(RFC 4253 §7.1).
pub fn negotiate(peer: Peer, phase: Phase) Error!Negotiated {
    // **압축은 `none` 만 받는다**(계약 §3). 서버가 그것을 안 주면 붙지 않는다 — 조용히
    // 다른 것을 고르면 우리가 못 푸는 데이터를 받게 된다.
    if (peer.comp_c2s.pick(&our.compression) == null) return Error.NoCommonCompressionC2s;
    if (peer.comp_s2c.pick(&our.compression) == null) return Error.NoCommonCompressionS2c;
    return .{
        .kex = peer.kex.pick(&our.kex) orelse return Error.NoCommonKex,
        .host_key = peer.host_key.pick(&our.host_key) orelse return Error.NoCommonHostKey,
        .cipher_c2s = peer.cipher_c2s.pick(&our.cipher) orelse return Error.NoCommonCipherC2s,
        .cipher_s2c = peer.cipher_s2c.pick(&our.cipher) orelse return Error.NoCommonCipherS2c,
        .strict_kex = switch (phase) {
            // 표시자는 **초기 KEXINIT 에서만** 유효하다(draft §3.1).
            .initial => peer.strictKex(),
            // 이후 KEXINIT 의 표시자는 유무에 관계없이 무시하고 연결이 정한 값을 잇는다.
            .rekey => |established| established,
        },
        .discard_guess = peer.first_kex_packet_follows and guessWrong(peer),
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

const test_server_kexinit = blk: {
    // OpenSSH 9.x 가 보내는 것과 같은 모양(우리 것과 겹치는 알고리즘을 포함).
    @setEvalBranchQuota(10000);
    break :blk struct {
        /// **방향마다 손잡이가 있어야 한다.** c2s 와 s2c 를 같은 값으로만 만들면 두 자리를
        /// 맞바꾸는 변이가 전부 살아남는다(실제로 그랬다 — cipher·mac 맞바꿈 셋이 통과했다).
        fn build(out: []u8, opts: struct {
            /// 서버가 광고할 strict 표시자. `null` 이면 안 보낸다.
            strict: ?[]const u8 = strict_s_v00,
            kex: []const u8 = "curve25519-sha256,ecdh-sha2-nistp256",
            host_key: []const u8 = "rsa-sha2-512,ssh-ed25519",
            cipher: []const u8 = "aes128-ctr,chacha20-poly1305@openssh.com",
            cipher_s2c: ?[]const u8 = null,
            mac: []const u8 = "hmac-sha2-256",
            mac_s2c: ?[]const u8 = null,
            comp: []const u8 = "none,zlib@openssh.com",
            comp_s2c: ?[]const u8 = null,
            guess: bool = false,
        }) ![]const u8 {
            var w = wire.Writer.init(out);
            try w.byte(msg_kexinit);
            try w.raw(&[_]u8{0} ** cookie_len);
            if (opts.strict) |marker| {
                var buf: [512]u8 = undefined;
                const joined = try std.fmt.bufPrint(&buf, "{s},{s}", .{ opts.kex, marker });
                try w.string(joined);
            } else try w.string(opts.kex);
            try w.string(opts.host_key);
            try w.string(opts.cipher);
            try w.string(opts.cipher_s2c orelse opts.cipher);
            try w.string(opts.mac);
            try w.string(opts.mac_s2c orelse opts.mac);
            try w.string(opts.comp);
            try w.string(opts.comp_s2c orelse opts.comp);
            try w.string("");
            try w.string("");
            try w.boolean(opts.guess);
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

test "우리가 보내는 첫 항목이 곧 우리 추측이다" {
    // `guessWrong` 은 `our.kex[0]`·`our.host_key[0]` 를 "우리가 보낸 첫 항목" 으로 믿는다.
    // **믿는 값과 실제로 선 위에 나가는 값이 갈리면** 추측 판정이 통째로 뒤집힌다 — 예컨대
    // strict 표시자를 목록 **앞**에 붙이도록 `write` 를 바꾸면 그렇게 된다. 여기서 그 둘을 맞댄다.
    var prng = std.Random.DefaultPrng.init(9);
    var out: [1024]u8 = undefined;
    const p = try parse(try write(&out, prng.random()));
    try std.testing.expectEqualStrings(our.kex[0], p.kex.first().?);
    try std.testing.expectEqualStrings(our.host_key[0], p.host_key.first().?);
    // 그리고 우리는 추측을 안 보낸다 — 보내면 §7.1 의 "틀렸을 때" 규칙이 우리 쪽에도 생긴다.
    try std.testing.expect(!p.first_kex_packet_follows);
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
    const n = try negotiate(try parse(try test_server_kexinit.build(&out, .{})), .initial);
    try std.testing.expectEqualStrings("curve25519-sha256", n.kex);
    try std.testing.expectEqualStrings("ssh-ed25519", n.host_key); // 서버가 rsa 를 먼저 적었어도
    try std.testing.expectEqualStrings("chacha20-poly1305@openssh.com", n.cipher_s2c);
    try std.testing.expect(n.strict_kex);
}

test "방향별 목록을 자기 자리에 넣는다" {
    // **c2s 와 s2c 를 맞바꾸는 변이가 전부 살아남던 자리다** — 두 방향에 다른 값을 주고
    // `Peer` 를 직접 잰다. `negotiate` 만 보면 우리가 암호를 하나만 지원해 구분이 안 된다.
    var out: [1024]u8 = undefined;
    const p = try parse(try test_server_kexinit.build(&out, .{
        .cipher = "aes128-ctr",
        .cipher_s2c = "chacha20-poly1305@openssh.com",
        .mac = "hmac-sha1",
        .mac_s2c = "hmac-sha2-512",
        .comp = "none",
        .comp_s2c = "zlib@openssh.com",
    }));
    try std.testing.expectEqualStrings("aes128-ctr", p.cipher_c2s.raw);
    try std.testing.expectEqualStrings("chacha20-poly1305@openssh.com", p.cipher_s2c.raw);
    try std.testing.expectEqualStrings("hmac-sha1", p.mac_c2s.raw);
    try std.testing.expectEqualStrings("hmac-sha2-512", p.mac_s2c.raw);
    try std.testing.expectEqualStrings("none", p.comp_c2s.raw);
    try std.testing.expectEqualStrings("zlib@openssh.com", p.comp_s2c.raw);
}

test "암호 협상도 방향을 따로 본다" {
    // 한 방향에만 우리 암호를 주는 서버는 합법이다(§7.1 은 두 목록을 독립으로 둔다). 그런데
    // 그때 붙으면 **서버가 안 준 암호로 첫 패킷을 쓴다** — 두 방향을 다 봐야 잡힌다.
    var out: [1024]u8 = undefined;
    try std.testing.expectError(Error.NoCommonCipherS2c, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .cipher_s2c = "aes128-ctr" }),
    ), .initial));
    try std.testing.expectError(Error.NoCommonCipherC2s, negotiate(try parse(
        try test_server_kexinit.build(&out, .{
            .cipher = "aes128-ctr",
            .cipher_s2c = "chacha20-poly1305@openssh.com",
        }),
    ), .initial));
}

test "서버가 strict 를 안 말하면 안 켠다" {
    // **한쪽만으로는 안 켠다**(draft §3.1) — 켜졌다고 착각하면 시퀀스 리셋이 어긋나 연결이 깨진다.
    var out: [1024]u8 = undefined;
    const n = try negotiate(try parse(try test_server_kexinit.build(&out, .{ .strict = null })), .initial);
    try std.testing.expect(!n.strict_kex);
}

test "표시자 이름은 명세 문자열 그대로다" {
    // **상수를 픽스처에도 쓰면 그 테스트는 자기충족이다** — `strict_s` 를 오타로 바꿔도 서버 픽스처가
    // 같은 오타를 보내므로 전부 초록이었다(변이로 확인했다). 그래서 여기서는 **리터럴**과 맞댄다.
    // draft-ietf-sshm-strict-kex §3.1 이 정한 네 이름이고, 한 글자만 달라도 보호가 조용히 꺼진다.
    try std.testing.expectEqualStrings("kex-strict-c", strict_c);
    try std.testing.expectEqualStrings("kex-strict-c-v00@openssh.com", strict_c_v00);
    try std.testing.expectEqualStrings("kex-strict-s", strict_s);
    try std.testing.expectEqualStrings("kex-strict-s-v00@openssh.com", strict_s_v00);
}

test "서버 표시자는 표준·구형 어느 쪽이어도 켠다" {
    // draft §3.1 은 서버가 둘 중 아무 이름이나 써도 된다고 한다. **픽스처는 리터럴로 보낸다** —
    // 상수를 쓰면 오타가 양쪽에 똑같이 반영돼 아무것도 못 잡는다.
    var out: [1024]u8 = undefined;
    for ([_][]const u8{ "kex-strict-s", "kex-strict-s-v00@openssh.com" }) |marker| {
        const n = try negotiate(try parse(
            try test_server_kexinit.build(&out, .{ .strict = marker }),
        ), .initial);
        try std.testing.expect(n.strict_kex);
    }
    // 우리 것(클라이언트 이름)을 서버가 보낸 것은 표시자가 아니다 — 방향을 헷갈리면 안 켜야 한다.
    for ([_][]const u8{ "kex-strict-c", "kex-strict-c-v00@openssh.com" }) |wrong_side| {
        const n = try negotiate(try parse(
            try test_server_kexinit.build(&out, .{ .strict = wrong_side }),
        ), .initial);
        try std.testing.expect(!n.strict_kex);
    }
}

test "재키잉 KEXINIT 의 표시자는 무시하고 초기값을 잇는다" {
    // draft §3.1: 표시자는 **초기 KEXINIT 에서만** 유효하고 이후 것은 "MUST be ignored" 다.
    var out: [1024]u8 = undefined;

    // 표시자가 사라진 재키잉 — 그래도 켜져 있어야 한다. 여기서 꺼지면 우리는 시퀀스 리셋을
    // 멈추고 서버는 리셋해서 이후 AEAD 태그가 전부 어긋난다.
    const no_marker = try parse(try test_server_kexinit.build(&out, .{ .strict = null }));
    try std.testing.expect((try negotiate(no_marker, .{ .rekey = true })).strict_kex);

    // 표시자가 붙은 재키잉 — 비-strict 연결이 뒤늦게 켜지면 안 된다.
    const with_marker = try parse(try test_server_kexinit.build(&out, .{}));
    try std.testing.expect(!(try negotiate(with_marker, .{ .rekey = false })).strict_kex);
}

test "서버 추측이 틀리면 다음 패킷을 버리라고 알린다" {
    // RFC 4253 §7.1: "If the other party's guess was wrong, and this field was TRUE, the next
    // packet MUST be silently ignored." 이 값을 안 실어 주면 상위가 그 패킷을 **KEX 응답으로**
    // 먹는다 — 초기 KEX 중 공격자 제어 여분 메시지를 받아들이는 것이고, strict KEX §3.2 가
    // 막으려는 바로 그 모양이다.
    var out: [1024]u8 = undefined;

    // 서버 추측(ecdh-sha2-nistp256 / rsa-sha2-512)이 우리 것과 다르다 → 버린다.
    const wrong = try parse(try test_server_kexinit.build(&out, .{ .guess = true }));
    try std.testing.expect(wrong.first_kex_packet_follows);
    try std.testing.expect((try negotiate(wrong, .initial)).discard_guess);

    // 추측을 안 붙였으면 버릴 것도 없다.
    const none = try parse(try test_server_kexinit.build(&out, .{}));
    try std.testing.expect(!(try negotiate(none, .initial)).discard_guess);

    // kex·호스트키 **둘 다** 우리 첫 항목과 같으면 추측이 맞은 것이다 → 버리지 않는다.
    const right = try parse(try test_server_kexinit.build(&out, .{
        .guess = true,
        .kex = "curve25519-sha256",
        .host_key = "ssh-ed25519",
    }));
    try std.testing.expect(!(try negotiate(right, .initial)).discard_guess);

    // 하나만 맞은 것은 맞은 것이 아니다 — 한쪽만 비교하는 구현이 여기서 걸린다.
    const kex_only = try parse(try test_server_kexinit.build(&out, .{
        .guess = true,
        .kex = "curve25519-sha256",
        .host_key = "rsa-sha2-512,ssh-ed25519",
    }));
    try std.testing.expect((try negotiate(kex_only, .initial)).discard_guess);
    const key_only = try parse(try test_server_kexinit.build(&out, .{
        .guess = true,
        .kex = "ecdh-sha2-nistp256,curve25519-sha256",
        .host_key = "ssh-ed25519",
    }));
    try std.testing.expect((try negotiate(key_only, .initial)).discard_guess);
}

test "겹치는 것이 없으면 붙지 않는다" {
    var out: [1024]u8 = undefined;
    // ed25519 호스트키가 없는 서버 — 계약대로 실패한다(조용히 다른 것을 고르지 않는다).
    // **어떤 실패인지 구분해서 알려 준다** — 계약 §3 이 "이 서버는 ed25519 호스트키를 안 준다"
    // 를 보여 주라고 하는데, 오류 하나로 뭉개면 호출자가 그 문장을 만들 수 없다.
    try std.testing.expectError(Error.NoCommonHostKey, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .host_key = "rsa-sha2-512,ecdsa-sha2-nistp256" }),
    ), .initial));
    try std.testing.expectError(Error.NoCommonKex, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .kex = "diffie-hellman-group14-sha256" }),
    ), .initial));
    // 우리 암호가 없는 서버.
    try std.testing.expectError(Error.NoCommonCipherC2s, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .cipher = "aes128-ctr,aes256-gcm@openssh.com" }),
    ), .initial));
    // **압축을 강제하는 서버** — `none` 이 없으면 우리가 못 푼다. **방향을 따로 잰다**:
    // 한 방향만 검사하면 나머지 방향의 가드를 지워도 안 드러난다(변이로 확인했다).
    // c2s 만 막힌 서버(s2c 는 멀쩡하다) — 두 방향을 다 검사해야 잡힌다.
    try std.testing.expectError(Error.NoCommonCompressionC2s, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .comp = "zlib@openssh.com", .comp_s2c = "none" }),
    ), .initial));
    // s2c 만 막힌 서버.
    try std.testing.expectError(Error.NoCommonCompressionS2c, negotiate(try parse(
        try test_server_kexinit.build(&out, .{ .comp_s2c = "zlib@openssh.com" }),
    ), .initial));
}

test "KEXINIT 이 아닌 것은 거절한다" {
    var buf = [_]u8{ 21, 0, 0, 0, 0 }; // NEWKEYS
    try std.testing.expectError(Error.NotKexInit, parse(&buf));
}

test "잘린 KEXINIT 은 거절한다" {
    // **네트워크에서 온 바이트다** — 목록 중간에서 끊긴 것을 받아도 안 죽어야 한다.
    //
    // **거절을 실제로 단언한다.** `catch continue` 로 성공값을 삼키면 이 테스트는 이름만 남고
    // 하드 크래시밖에 못 잡는다 — `parse` 끝의 읽기들을 "어차피 안 쓰니까" 지우는 정리가
    // 통과하고, 그러면 서버가 끝내 안 보낸 바이트를 가리키는 `NameList` 들이 상위로 넘어간다.
    var out: [1024]u8 = undefined;
    const full = try test_server_kexinit.build(&out, .{});
    var i: usize = 1;
    while (i < full.len) : (i += 1) {
        if (parse(full[0..i])) |_| return error.TruncatedKexInitAccepted else |_| {}
    }
    // 전부 오면 읽힌다 — 위 루프가 "무조건 실패" 로 통과하는 것이 아님을 못박는다.
    _ = try parse(full);
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
    const n = try negotiate(p, .initial);
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
