//! `known_hosts` 대조 — 이 서버가 **우리가 아는 그 서버**인가.
//!
//! **sans-io 다**(계약 §2). 파일을 읽는 것은 L4 이고, 이 층은 그 내용을 바이트로 받아 판정만 한다.
//!
//! S5a 의 서명 검증은 "상대가 이 호스트키의 주인" 임을 증명한다. 그런데 **중간자도 자기 키로
//! 서명해 오면 그 검증은 통과한다** — 그 키가 우리가 아는 그 서버의 키인지는 여기서 정해진다.
//!
//! 형식은 RFC 가 아니라 **OpenSSH `sshd(8)` 의 `SSH_KNOWN_HOSTS FILE FORMAT`** 이 정한다:
//!
//! ```text
//!   [marker] hostnames keytype base64-key [comment]
//! ```
//!
//! - `marker` 는 `@cert-authority` 또는 `@revoked` 뿐이고 한 줄에 하나다.
//! - `hostnames` 는 쉼표로 나뉜 패턴 목록(`*`·`?` 와일드카드, 앞의 `!` 는 부정). 비표준 포트는
//!   `[host]:port` 로 감싼다.
//! - 또는 **해시 한 개**(`|1|salt|hash`) — 그때는 와일드카드·부정이 안 쓰인다.
//! - `#` 로 시작하는 줄과 빈 줄은 주석이다.
//!
//! **우리는 인증서를 안 다룬다**(계약 §3). `@cert-authority` 줄은 **판정에서 뺀다** — CA 키를
//! 평범한 호스트키로 읽으면 그 CA 가 서명한 **모든** 호스트를 그 키 하나로 신뢰하게 된다.

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

/// 해시 호스트명 접두(OpenSSH `HASH_MAGIC`). 지금 쓰이는 것은 `|1|` 뿐이다.
pub const hash_magic = "|1|";

/// 한 줄에서 읽을 base64 키의 상한. ed25519 blob 은 51바이트(base64 68자)지만, 다른 종류의
/// 키가 섞인 파일도 훑어야 하므로 넉넉히 잡는다 — 넘는 줄은 **건너뛴다**(우리 키일 수 없다).
pub const max_key_bytes = 1024;

/// 판정. **`revoked` 가 가장 세다** — 같은 호스트에 신뢰 줄이 또 있어도 이긴다.
pub const Verdict = enum {
    /// 이 호스트의 이 키를 안다 — 붙어도 된다.
    trusted,
    /// **이 호스트를 아는데 키가 다르다.** 중간자이거나 서버가 키를 바꿨다 — 사용자가 명시로
    /// 지우기 전까지 붙지 않는다(계약 §4).
    mismatch,
    /// `@revoked` 로 표시된 키다 — 절대 받지 않는다.
    revoked,
    /// 이 호스트를 모른다 — TOFU 프롬프트로 간다.
    unknown,
};

pub const Marker = enum { none, cert_authority, revoked };

/// 파싱한 줄 하나. **문자열은 전부 입력 버퍼를 가리킨다.**
pub const Line = struct {
    marker: Marker,
    /// `hostnames` 필드 원문(쉼표 목록 또는 해시 하나).
    hosts: []const u8,
    key_type: []const u8,
    key_b64: []const u8,
};

/// 줄 하나를 판다. 주석·빈 줄·필드가 모자란 줄은 `null` 이다(**오류가 아니다** — 남의 파일이라
/// 우리가 모르는 줄이 섞여 있는 것이 정상이다).
pub fn parseLine(line: []const u8) ?Line {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    var first = it.next() orelse return null;
    if (first[0] == '#') return null;

    var marker: Marker = .none;
    if (first[0] == '@') {
        marker = if (std.mem.eql(u8, first, "@cert-authority"))
            .cert_authority
        else if (std.mem.eql(u8, first, "@revoked"))
            .revoked
        else
            return null; // 모르는 marker — 통째로 건너뛴다(추측해서 신뢰하면 안 된다)
        first = it.next() orelse return null;
    }
    const key_type = it.next() orelse return null;
    const key_b64 = it.next() orelse return null;
    return .{ .marker = marker, .hosts = first, .key_type = key_type, .key_b64 = key_b64 };
}

/// `hostnames` 필드가 이 호스트에 맞나.
///
/// **부정(`!`)이 이긴다** — 한 패턴이라도 부정으로 맞으면 그 줄은 이 호스트의 것이 아니다.
///
/// **대소문자를 안 가린다.** DNS 가 그렇고 OpenSSH 도 그렇다(실측: `ssh-keygen -F EXAMPLE.COM`
/// 이 `example.com` 줄을 찾는다). 가리면 사용자가 대문자로 적은 순간 아는 호스트가 "모르는
/// 호스트" 가 되고, 그러면 **`mismatch`(하드 실패)가 `unknown`(프롬프트)으로 강등된다** —
/// 중간자 앞에서 정확히 그 차이가 위험하다. 해시 쪽은 아래 `matchesHashed` 를 본다.
pub fn matchesHost(hosts: []const u8, host: []const u8) bool {
    // **빈 이름은 호스트가 아니다.** 안 막으면 `*` 줄에 맞아 `verify` 가 `trusted` 를 낸다 —
    // 호출자가 빈 문자열을 넘긴 실수가 **조용한 신뢰**가 되는, 이 층에서 가장 나쁜 방향이다.
    if (host.len == 0) return false;
    if (std.mem.startsWith(u8, hosts, hash_magic)) return matchesHashed(hosts, host);
    var it = std.mem.splitScalar(u8, hosts, ',');
    var positive = false;
    while (it.next()) |pattern| {
        if (pattern.len == 0) continue;
        if (pattern[0] == '!') {
            if (matchPattern(pattern[1..], host)) return false; // 부정이 이긴다
        } else if (matchPattern(pattern, host)) {
            positive = true;
        }
    }
    return positive;
}

/// `|1|<base64 salt>|<base64 HMAC-SHA1(salt, host)>`. 소금이 키이고 호스트명이 메시지다.
///
/// **호스트명을 소문자로 바꾼 뒤 해싱한다.** `ssh-keygen -H` 가 그렇게 만들기 때문이다(실측:
/// `EXAMPLE.COM` 으로 해시한 줄을 `example.com` 으로 찾으면 나오고 `EXAMPLE.COM` 으로 찾으면
/// 안 나온다). 원문 그대로 해싱하면 해시된 `known_hosts` 를 쓰는 사용자가 대문자를 적는 순간
/// 아는 호스트를 못 찾는다.
///
/// 소문자 변환은 **버퍼 없이 조각으로 먹인다** — 호스트명 길이에 상한을 두지 않으려는 것이다
/// (상한을 두면 그 길이를 넘는 이름이 조용히 "안 맞음" 이 되고, 그것도 같은 강등이다).
/// 조각 크기는 임의다(HMAC 은 스트리밍이라 결과가 같다) — 그 숫자를 바꾸는 변이가 살아남는 것은
/// 정상이고 테스트 구멍이 아니다.
fn matchesHashed(hosts: []const u8, host: []const u8) bool {
    const rest = hosts[hash_magic.len..];
    const bar = std.mem.indexOfScalar(u8, rest, '|') orelse return false;
    var salt: [64]u8 = undefined;
    var want: [64]u8 = undefined;
    const salt_bytes = decodeBase64(&salt, rest[0..bar]) orelse return false;
    const want_bytes = decodeBase64(&want, rest[bar + 1 ..]) orelse return false;
    if (want_bytes.len != HmacSha1.mac_length) return false;
    var got: [HmacSha1.mac_length]u8 = undefined;
    var mac = HmacSha1.init(salt_bytes);
    var i: usize = 0;
    while (i < host.len) {
        var chunk: [64]u8 = undefined;
        const n = @min(chunk.len, host.len - i);
        for (chunk[0..n], host[i..][0..n]) |*dst, c| dst.* = std.ascii.toLower(c);
        mac.update(chunk[0..n]);
        i += n;
    }
    mac.final(&got);
    // 상수 시간 비교 — 이 값은 상대가 고른 호스트명으로도 흔들 수 있는 자리다.
    return std.crypto.timing_safe.eql([HmacSha1.mac_length]u8, got, want_bytes[0..HmacSha1.mac_length].*);
}

/// `*`·`?` 와일드카드. **`*` 는 `.` 도 넘는다**(OpenSSH 와 같다 — 도메인 경계를 안 본다).
/// 글자 비교는 **대소문자를 안 가린다**(위 `matchesHost` 주석의 실측).
fn matchPattern(pattern: []const u8, host: []const u8) bool {
    if (pattern.len == 0) return host.len == 0;
    switch (pattern[0]) {
        '*' => {
            // `*` 뒤가 비면 전부 맞는다. 아니면 남은 호스트의 모든 자리에서 시도한다.
            if (pattern.len == 1) return true;
            var i: usize = 0;
            while (i <= host.len) : (i += 1) {
                if (matchPattern(pattern[1..], host[i..])) return true;
            }
            return false;
        },
        '?' => return host.len > 0 and matchPattern(pattern[1..], host[1..]),
        else => return host.len > 0 and
            std.ascii.toLower(host[0]) == std.ascii.toLower(pattern[0]) and
            matchPattern(pattern[1..], host[1..]),
    }
}

fn decodeBase64(out: []u8, text: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(text) catch return null;
    if (n > out.len) return null;
    dec.decode(out[0..n], text) catch return null;
    return out[0..n];
}

/// 파일 전체를 훑어 판정한다. `key_blob` 은 서버가 준 `K_S` **원문 바이트**다.
///
/// **`revoked` 가 가장 세다.** 같은 호스트에 신뢰 줄이 또 있어도 이긴다 — 훔친 키가 파일 어딘가에
/// 아직 남아 있을 수 있으므로 "하나라도 맞으면 신뢰" 로 읽으면 안 된다.
///
/// **키 종류가 다른 줄은 판정에서 뺀다.** 우리는 ed25519 만 하므로(계약 §3) RSA 줄이 있다고 해서
/// "키가 바뀌었다" 가 아니다 — 그것을 `mismatch` 로 읽으면 정상 서버에 못 붙는다.
pub fn verify(file: []const u8, host: []const u8, key_type: []const u8, key_blob: []const u8) Verdict {
    // **첫 일치에서 끝내면 안 된다.** 신뢰 줄이 폐기 줄보다 **먼저** 나오면 폐기를 못 보고
    // `trusted` 를 내게 된다 — 훔친 키가 파일 어딘가에 아직 남아 있는 정확히 그 상황이다.
    // 그래서 파일을 끝까지 훑고 가장 센 판정을 고른다.
    var found_host = false;
    var found_key = false;
    var it = std.mem.splitScalar(u8, file, '\n');
    while (it.next()) |raw| {
        const line = parseLine(raw) orelse continue;
        // 인증서 CA 줄은 우리 얘기가 아니다(위 모듈 주석 — 이것을 호스트키로 읽으면 큰일난다).
        if (line.marker == .cert_authority) continue;
        if (!std.mem.eql(u8, line.key_type, key_type)) continue;
        if (!matchesHost(line.hosts, host)) continue;

        var buf: [max_key_bytes]u8 = undefined;
        const stored = decodeBase64(&buf, line.key_b64) orelse continue;
        const same = std.mem.eql(u8, stored, key_blob);
        if (line.marker == .revoked) {
            if (same) return .revoked; // 가장 센 판정 — 더 볼 것이 없다
            continue; // 다른 키의 폐기 줄은 우리와 무관하다
        }
        if (same) found_key = true else found_host = true;
    }
    if (found_key) return .trusted;
    return if (found_host) .mismatch else .unknown;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

/// S5a 테스트와 같은 일회용 키(실제 기계 것이 아니다).
const vector_b64 = "AAAAC3NzaC1lZDI1NTE5AAAAIG2eGIpVHVdbxIvh0YFR9DU98fqXw/UjIsI9dH/LE0RS";
const vector_blob = [_]u8{
    0x00, 0x00, 0x00, 0x0b, 0x73, 0x73, 0x68, 0x2d, 0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39,
    0x00, 0x00, 0x00, 0x20, 0x6d, 0x9e, 0x18, 0x8a, 0x55, 0x1d, 0x57, 0x5b, 0xc4, 0x8b, 0xe1,
    0xd1, 0x81, 0x51, 0xf4, 0x35, 0x3d, 0xf1, 0xfa, 0x97, 0xc3, 0xf5, 0x23, 0x22, 0xc2, 0x3d,
    0x74, 0x7f, 0xcb, 0x13, 0x44, 0x52,
};
const ed = "ssh-ed25519";

/// 다른 키(한 비트 다름) — 중간자가 자기 키로 서명해 오는 경우다.
fn otherBlob() [vector_blob.len]u8 {
    var b = vector_blob;
    b[30] ^= 1;
    return b;
}

test "줄을 판다 — marker·주석·모자란 줄" {
    const plain = parseLine("example.com ssh-ed25519 AAAA comment here").?;
    try std.testing.expectEqual(Marker.none, plain.marker);
    try std.testing.expectEqualStrings("example.com", plain.hosts);
    try std.testing.expectEqualStrings("ssh-ed25519", plain.key_type);
    try std.testing.expectEqualStrings("AAAA", plain.key_b64);

    try std.testing.expectEqual(Marker.revoked, parseLine("@revoked h ssh-ed25519 AAAA").?.marker);
    try std.testing.expectEqual(Marker.cert_authority, parseLine("@cert-authority h ssh-ed25519 AAAA").?.marker);

    // 주석·빈 줄·필드 부족은 **오류가 아니라 건너뛰기**다(남의 파일이다).
    for ([_][]const u8{ "", "   ", "# comment", "#", "only-host", "host ssh-ed25519" }) |bad| {
        try std.testing.expectEqual(@as(?Line, null), parseLine(bad));
    }
    // **모르는 marker 는 통째로 건너뛴다** — 추측해서 신뢰하면 안 된다.
    try std.testing.expectEqual(@as(?Line, null), parseLine("@future-marker h ssh-ed25519 AAAA"));
    // 탭 구분도 받는다.
    try std.testing.expectEqualStrings("h", parseLine("h\tssh-ed25519\tAAAA").?.hosts);
}

test "호스트명은 대소문자를 안 가린다 (OpenSSH 실측)" {
    // **`ssh-keygen -F` 로 확인한 동작이다**: `EXAMPLE.COM` 이 `example.com` 줄을 찾고,
    // `git.WILD.com` 이 `*.wild.com` 을 찾고, `[JUMP.org]:2222` 가 `[jump.org]:2222` 를 찾는다.
    //
    // **가리면 위험하다.** 사용자가 대문자로 적는 순간 아는 호스트가 "모르는 호스트" 가 되고,
    // 그러면 중간자 앞에서 `mismatch`(하드 실패)가 `unknown`(프롬프트)으로 **강등된다**.
    for ([_][]const u8{ "EXAMPLE.COM", "Example.Com", "example.com" }) |h| {
        try std.testing.expect(matchesHost("example.com", h));
    }
    try std.testing.expect(matchesHost("*.wild.com", "git.WILD.com"));
    try std.testing.expect(matchesHost("[jump.org]:2222", "[JUMP.org]:2222"));
    // 패턴 쪽이 대문자여도 같다.
    try std.testing.expect(matchesHost("EXAMPLE.COM", "example.com"));
    // 부정도 대소문자를 안 가려야 한다 — 가리면 대문자로 적어 제외를 우회할 수 있다.
    try std.testing.expect(!matchesHost("*.example.com,!SECRET.example.com", "secret.example.com"));

    // 판정까지 이어진다 — **강등이 실제로 안 일어나는지**를 잰다.
    const file = "example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(file, "EXAMPLE.COM", ed, &vector_blob));
    const other = otherBlob();
    try std.testing.expectEqual(Verdict.mismatch, verify(file, "EXAMPLE.COM", ed, &other));
}

test "해시 호스트명도 소문자로 바꿔 해싱한다 (OpenSSH 실측)" {
    // `ssh-keygen -H` 가 **소문자로 바꾼 뒤** 해싱한다: `EXAMPLE.COM` 으로 해시한 줄을
    // `example.com` 으로 찾으면 나오고 `EXAMPLE.COM` 으로 찾으면 안 나온다(실측).
    // 원문 그대로 해싱하면 해시된 파일을 쓰는 사용자가 대문자를 적는 순간 못 찾는다.
    const hashed = "|1|9GynkVIVFafP+0NWUHjrabu0z5o=|jE4vNVarJ+VnEWapE1NLmaws8mU=";
    for ([_][]const u8{ "example.com", "EXAMPLE.COM", "Example.Com" }) |h| {
        try std.testing.expect(matchesHost(hashed, h));
    }
    try std.testing.expect(!matchesHost(hashed, "example.org"));

    // 청크 경계(64바이트)를 넘는 긴 이름도 같은 값을 내야 한다 — 조각으로 먹이는 구현이라
    // 경계에서 갈리면 여기서 걸린다.
    var long: [200]u8 = undefined;
    @memset(&long, 'a');
    long[199] = 'b';
    var upper: [200]u8 = undefined;
    for (&upper, long) |*dst, c| dst.* = std.ascii.toUpper(c);
    const salt = "9GynkVIVFafP+0NWUHjrabu0z5o=";
    var salt_bytes: [64]u8 = undefined;
    const s = decodeBase64(&salt_bytes, salt).?;
    var want: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&want, &long, s); // 소문자 원문으로 계산한 정답
    var b64: [64]u8 = undefined;
    const want_b64 = std.base64.standard.Encoder.encode(&b64, &want);
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "|1|{s}|{s}", .{ salt, want_b64 }) catch unreachable;
    try std.testing.expect(matchesHost(line, &long));
    try std.testing.expect(matchesHost(line, &upper)); // 대문자로 물어도 같은 값이어야 한다
}

test "주석 처리한 줄은 되살아나지 않는다" {
    // **`#` 검사가 살아 있는 가드다.** `ssh` 는 `known_hosts` 에 `hostname,ipaddr` 를 함께 적는다.
    // 그 줄을 주석 처리하면 `#` 이 **첫 패턴에만** 붙고 쉼표 뒤 패턴은 멀쩡해서, 검사가 없으면
    // 그 줄이 그대로 살아난다(실측: 변이가 살아남아 이 모양을 찾았다).
    const commented = "#example.com,203.0.113.9 " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.unknown, verify(commented, "203.0.113.9", ed, &vector_blob));
    // 와일드카드가 섞인 경우도 같다 — 이쪽이 더 위험하다(아무 호스트나 맞는다).
    const commented_wild = "#old.example.com,* " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.unknown, verify(commented_wild, "anything.example.net", ed, &vector_blob));

    // 주석을 푼 줄은 물론 산다 — 위가 "무조건 unknown" 이 아님을 못박는다.
    const live = "example.com,203.0.113.9 " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(live, "203.0.113.9", ed, &vector_blob));
}

test "호스트 매칭 — 목록·와일드카드·부정·포트" {
    try std.testing.expect(matchesHost("example.com", "example.com"));
    try std.testing.expect(!matchesHost("example.com", "example.org"));
    try std.testing.expect(matchesHost("a.com,b.com,c.com", "b.com"));

    // 와일드카드. **`*` 는 `.` 도 넘는다**(OpenSSH 와 같다).
    try std.testing.expect(matchesHost("*.example.com", "git.example.com"));
    try std.testing.expect(matchesHost("*.example.com", "a.b.example.com"));
    try std.testing.expect(matchesHost("*", "anything"));
    try std.testing.expect(matchesHost("host?.example.com", "host1.example.com"));
    try std.testing.expect(!matchesHost("host?.example.com", "host12.example.com"));

    // **부정이 이긴다** — 다른 패턴이 맞아도 그 줄은 이 호스트의 것이 아니다.
    try std.testing.expect(!matchesHost("*.example.com,!secret.example.com", "secret.example.com"));
    try std.testing.expect(matchesHost("*.example.com,!secret.example.com", "public.example.com"));

    // 비표준 포트는 `[host]:port` 원문 그대로 맞댄다.
    try std.testing.expect(matchesHost("[jump.example.org]:2222", "[jump.example.org]:2222"));
    try std.testing.expect(!matchesHost("[jump.example.org]:2222", "jump.example.org"));

    // **빈 이름은 호스트가 아니다.** 안 막으면 `*` 줄에 맞아 조용히 신뢰가 된다(탐침으로 찾았다).
    try std.testing.expect(!matchesHost("*", ""));
    try std.testing.expect(!matchesHost("example.com", ""));
    try std.testing.expect(!matchesHost("|1|9GynkVIVFafP+0NWUHjrabu0z5o=|jE4vNVarJ+VnEWapE1NLmaws8mU=", ""));
    const wild_file = "* " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.unknown, verify(wild_file, "", ed, &vector_blob));

    // 부정만 있는 줄은 아무것도 안 맞는다(양의 일치가 있어야 한다).
    try std.testing.expect(!matchesHost("!x.example.com", "y.example.com"));
    // 쉼표만 있는 필드·모르는 해시 버전도 안 맞는다(fail-closed).
    try std.testing.expect(!matchesHost(",,,", "example.com"));
    try std.testing.expect(!matchesHost("|9|abc|def", "example.com"));
}

test "해시 호스트명이 ssh-keygen -H 와 맞는다" {
    // **독립 구현이 만든 값이다.** `ssh-keygen -H` 가 아래 두 줄을 냈다 — 우리 HMAC-SHA1 이
    // 틀리면 해시된 `known_hosts` 를 쓰는 사용자가 전부 "모르는 호스트" 가 된다.
    const hashed_example = "|1|9GynkVIVFafP+0NWUHjrabu0z5o=|jE4vNVarJ+VnEWapE1NLmaws8mU=";
    const hashed_port = "|1|TRqvGfmMvVbBL2mDE1MZxCNu0Bo=|QXxAbgZI1Yp1SLgk0GivraQIIwI=";

    try std.testing.expect(matchesHost(hashed_example, "example.com"));
    try std.testing.expect(matchesHost(hashed_port, "[jump.example.org]:2222"));

    // 다른 호스트는 안 맞는다 — 소금이 같아도 메시지가 다르면 값이 다르다.
    try std.testing.expect(!matchesHost(hashed_example, "example.org"));
    try std.testing.expect(!matchesHost(hashed_example, "[jump.example.org]:2222"));
    try std.testing.expect(!matchesHost(hashed_port, "example.com"));
    try std.testing.expect(!matchesHost(hashed_example, ""));

    // 깨진 해시 줄은 조용히 안 맞는다(죽지 않는다) — 남의 파일이다.
    for ([_][]const u8{
        "|1|",
        "|1|nosalt",
        "|1|!!!!|jE4vNVarJ+VnEWapE1NLmaws8mU=",
        "|1|9GynkVIVFafP+0NWUHjrabu0z5o=|!!!!",
        "|1|9GynkVIVFafP+0NWUHjrabu0z5o=|QUJD", // 길이가 SHA-1 이 아니다
        "|2|9GynkVIVFafP+0NWUHjrabu0z5o=|jE4vNVarJ+VnEWapE1NLmaws8mU=",
    }) |bad| {
        try std.testing.expect(!matchesHost(bad, "example.com"));
    }
}

test "아는 호스트의 같은 키는 trusted 다" {
    const file = "example.com " ++ ed ++ " " ++ vector_b64 ++ " comment\n";
    try std.testing.expectEqual(Verdict.trusted, verify(file, "example.com", ed, &vector_blob));
}

test "아는 호스트인데 키가 다르면 mismatch 다" {
    // **여기가 중간자를 잡는 자리다.** 서명은 통과했는데(중간자도 자기 키로 서명한다) 그 키가
    // 우리가 아는 키가 아니다 — 계약 §4 는 사용자가 명시로 지우기 전까지 붙지 말라고 한다.
    const file = "example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    const other = otherBlob();
    try std.testing.expectEqual(Verdict.mismatch, verify(file, "example.com", ed, &other));
}

test "모르는 호스트는 unknown 이다 (TOFU 로 간다)" {
    const file = "other.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.unknown, verify(file, "example.com", ed, &vector_blob));
    try std.testing.expectEqual(Verdict.unknown, verify("", "example.com", ed, &vector_blob));
    try std.testing.expectEqual(Verdict.unknown, verify("# 전부 주석\n\n", "example.com", ed, &vector_blob));
}

test "revoked 가 가장 세다" {
    // 훔친 키가 파일 어딘가에 아직 남아 있을 수 있다 — "하나라도 맞으면 신뢰" 로 읽으면 안 된다.
    // 폐기 줄이 **뒤에** 있든 **앞에** 있든 이겨야 한다.
    const trusted_line = "example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    const revoked_line = "@revoked example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.revoked, verify(trusted_line ++ revoked_line, "example.com", ed, &vector_blob));
    try std.testing.expectEqual(Verdict.revoked, verify(revoked_line ++ trusted_line, "example.com", ed, &vector_blob));

    // **다른 키의 폐기 줄은 우리와 무관하다** — 그것으로 정상 접속을 막으면 안 된다.
    var other = otherBlob();
    var other_b64: [128]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const other_text = enc.encode(&other_b64, &other);
    var buf: [512]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "@revoked example.com {s} {s}\nexample.com {s} {s}\n", .{ ed, other_text, ed, vector_b64 }) catch unreachable;
    try std.testing.expectEqual(Verdict.trusted, verify(file, "example.com", ed, &vector_blob));
}

test "cert-authority 줄은 호스트키로 읽지 않는다" {
    // **CA 키를 평범한 호스트키로 읽으면** 그 CA 가 서명한 모든 호스트를 이 키 하나로 신뢰하게
    // 된다. 우리는 인증서를 안 다루므로(계약 §3) 그 줄은 판정에서 뺀다 — `unknown` 이라 TOFU 로
    // 가고, 사용자가 그 서버의 실제 호스트키를 승인하게 된다.
    const file = "@cert-authority *.example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.unknown, verify(file, "git.example.com", ed, &vector_blob));
    // 키가 달라도 mismatch 가 아니다(그 줄을 아예 안 본다).
    const other = otherBlob();
    try std.testing.expectEqual(Verdict.unknown, verify(file, "git.example.com", ed, &other));
}

test "한 호스트에 키가 여럿이면 하나만 맞아도 trusted 다" {
    // `sshd(8)` 은 "같은 이름에 여러 줄이 있을 수 있다" 고 하고, 서버가 키를 교체하는 동안
    // 실제로 그런 파일이 된다. **하나라도 맞으면 신뢰**이고 순서를 안 타야 한다 — 안 그러면
    // 옛 줄이 앞에 있다는 이유로 정상 접속이 `mismatch` 로 끊긴다.
    var other = otherBlob();
    var other_b64: [128]u8 = undefined;
    const other_text = std.base64.standard.Encoder.encode(&other_b64, &other);
    var buf: [512]u8 = undefined;

    const old_first = std.fmt.bufPrint(&buf, "example.com {s} {s}\nexample.com {s} {s}\n", .{ ed, other_text, ed, vector_b64 }) catch unreachable;
    try std.testing.expectEqual(Verdict.trusted, verify(old_first, "example.com", ed, &vector_blob));

    var buf2: [512]u8 = undefined;
    const new_first = std.fmt.bufPrint(&buf2, "example.com {s} {s}\nexample.com {s} {s}\n", .{ ed, vector_b64, ed, other_text }) catch unreachable;
    try std.testing.expectEqual(Verdict.trusted, verify(new_first, "example.com", ed, &vector_blob));

    // 둘 다 우리 키가 아니면 `mismatch` 다(호스트는 아니까).
    var third = vector_blob;
    third[31] ^= 1;
    try std.testing.expectEqual(Verdict.mismatch, verify(old_first, "example.com", ed, &third));
}

test "키 종류가 다른 줄은 판정에서 뺀다" {
    // 우리는 ed25519 만 한다(계약 §3). RSA 줄이 있다고 "키가 바뀌었다" 가 아니다 — 그것을
    // mismatch 로 읽으면 **정상 서버에 못 붙는다**.
    const file = "example.com ssh-rsa AAAAB3NzaC1yc2E=\n";
    try std.testing.expectEqual(Verdict.unknown, verify(file, "example.com", ed, &vector_blob));

    // 같은 호스트에 ed25519 줄이 함께 있으면 그것으로 판정한다.
    const both = file ++ "example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(both, "example.com", ed, &vector_blob));
}

test "와일드카드·해시 줄로도 판정된다" {
    const wild = "*.example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(wild, "git.example.com", ed, &vector_blob));
    const other = otherBlob();
    try std.testing.expectEqual(Verdict.mismatch, verify(wild, "git.example.com", ed, &other));

    const hashed = "|1|9GynkVIVFafP+0NWUHjrabu0z5o=|jE4vNVarJ+VnEWapE1NLmaws8mU= " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(hashed, "example.com", ed, &vector_blob));
    try std.testing.expectEqual(Verdict.unknown, verify(hashed, "other.com", ed, &vector_blob));
}

test "깨진 파일에도 안 죽는다" {
    // **남의 파일이다** — 우리가 모르는 줄이 섞여 있는 것이 정상이고, 그 탓에 판정이 흔들리면 안 된다.
    const file =
        "\n# 주석\n" ++
        "깨진 줄\n" ++
        "host-only\n" ++
        "example.com " ++ ed ++ " !!!not-base64!!!\n" ++ // 디코드 실패 → 그 줄만 건너뛴다
        "example.com " ++ ed ++ " " ++ vector_b64 ++ "\n";
    try std.testing.expectEqual(Verdict.trusted, verify(file, "example.com", ed, &vector_blob));

    // CRLF 파일도 읽는다(윈도에서 편집한 파일).
    const crlf = "example.com " ++ ed ++ " " ++ vector_b64 ++ "\r\n";
    try std.testing.expectEqual(Verdict.trusted, verify(crlf, "example.com", ed, &vector_blob));

    // 아주 긴 키(우리 상한 초과)는 건너뛴다 — 우리 키일 수 없다.
    var long_buf: [max_key_bytes * 3]u8 = undefined;
    @memset(&long_buf, 'A');
    var file_buf: [max_key_bytes * 4]u8 = undefined;
    const long_file = std.fmt.bufPrint(&file_buf, "example.com {s} {s}\n", .{ ed, long_buf[0..] }) catch unreachable;
    try std.testing.expectEqual(Verdict.unknown, verify(long_file, "example.com", ed, &vector_blob));
}

test "상수는 OpenSSH 형식 그대로다" {
    try std.testing.expectEqualStrings("|1|", hash_magic);
    try std.testing.expectEqual(@as(usize, 20), HmacSha1.mac_length); // SHA-1
}
