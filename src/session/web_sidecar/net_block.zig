//! 요청 막기의 패턴(W9d③ — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」) — 순수, sidecar 와 maru 가 같은 파일을 쓴다. maru 는 에이전트가 준
//! 패턴을 풀어 오류 답(`pattern_invalid:<why>`·`not_ascii`)과 정규형(같은 규칙인지 — `already`)에 쓰고, sidecar 는 IO 스레드의 처리기 고르기에서
//! 요청 주소를 맞춘다. 한 출처라 「maru 가 받은 패턴」 과 「sidecar 가 맞추는 패턴」 이 갈리지 않는다.
//!
//! 꼴: Chrome match-pattern(`scheme://host[:port]path`) + 경로 glob. 정규식은 없다(맞추기 시간이 패턴에 묶이게).
//!   - 스킴 `http`·`https`·`*`(= 둘 다). `ws:`·`data:`·`blob:`·`file:` 등은 거절한다 — CEF 처리기가 보지 않거나(WebSocket — 실측 J-B13) 쿠키가
//!     없는 주소다.
//!   - 호스트 `*`(아무 호스트)·`*.domain`(그 도메인과 하위 — `net_policy.hostCovers` 의 점 경계)·정확한 호스트·IP(IPv6 는 괄호). ASCII 만
//!     (국제화 도메인은 punycode 로 — 주소 쪽은 GURL 이 이미 그 꼴이다). 소문자로, 끝 점은 양쪽에서 뗀다.
//!   - 포트: 없으면 아무 포트. 있으면 주소의 실제 포트(없으면 스킴의 기본 포트)와 같아야. 스킴이 정해졌으면 기본 포트는 뗀다(정규형).
//!   - 경로: `/` 로 시작하는 경로 **와 쿼리** 위의 glob — `*` 는 `/`·`?` 를 넘어 아무 길이. `#조각` 은 맞추지 않는다(주소 쪽에서 뗀다 — CEF 는
//!     조각을 싣는다, W9d① J1).
//!   - `*` 가 패턴 **어디에도**(스킴·호스트 포함) 없으면 **풀어 본 주소의 앞부분**: 정확한 호스트에 경로 앞부분. 날 글의 앞부분이 아니다 —
//!     `https://a.test` 가 `https://a.test.evil/` 에 맞지 않게. `*` 가 하나라도 있으면(스킴·호스트의 `*` 도) 경로는 양끝이 묶인다(Chrome
//!     match-pattern 과 같다): `http://a.test/ads` 는 `/ads/x.js` 도 막지만 `*://a.test/ads`·`http://*.a.test/ads` 는 `/ads` 만 막는다 —
//!     그 아래까지는 `*://a.test/ads*`·`*://a.test/ads/*` 로 쓴다(20 회 검증 A LOW-1 — 뜻은 그대로 두고 문서를 분명히 했다). 경로가 없으면 아무
//!     경로(정규형은 앞부분 꼴 `/`, glob 꼴 `/*`).
//!   - 거절: `#`, 권한 부분의 사용자 정보(`@`), 빈칸·제어 글자, ASCII 밖, 512 바이트 넘게, `*` 9 개 이상, 잘못 쓴 `%`. 그리고 **어느 주소에도 맞을
//!     수 없는 꼴**(20 회 검증 A N2 — 전에는 말없이 받아 죽은 규칙이 됐다): 끝 점이 둘인 호스트(`a.test..`), Chromium 이 다른 꼴로 바꾸는 IP
//!     호스트(`0x7f.0.0.1`·`2130706433`·`127.1`·`[0:0::1]`·`[::FFFF:1.2.3.4]` — `host`), 쿼리 앞 경로의 점 조각(`/.`·`/..`·`%2e`)·`\`·
//!     `"`·`<`·`>`(GURL 이 풀거나 `%XX` 로 바꾼다 — `path`), 쿼리의 `"`·`<`·`>`(`path`).
//!   - 정규형: 스킴·호스트 소문자, 끝 점·기본 포트 뗌, `%xx` 를 대문자로(GURL 이 만드는 이스케이프는 대문자다).
//!
//! 주소 쪽: CEF 가 넘긴 GURL 정규 꼴(UTF-16 단위 그대로 — 할당 없이 IO 스레드에서). 사용자 정보는 건너뛰고 조각은 뗀다. 그 뒤 단위 그대로
//! 비교한다 — 0x7F 위의 단위는 어느 패턴 바이트와도 같지 않다(패턴은 ASCII).
//! 알려진 빠져나가기(문서화 — 막기는 페이지에 맞선 경계가 아니라 개발 도구다): 페이지가 고른 소문자 `%xx`·`%2F` 꼴 경로, 가운데 조각을 찾는
//! 범위(경로+쿼리 앞 64 KiB — `scan_limit`)를 넘는 매우 긴 주소. 끝에 붙은 조각은 진짜 끝에 맞추므로 `*.js` 같은 꼴은 길이와 무관하다.
//!
//! 맞추기의 비용(IO 스레드 — 요청마다): 호스트 비교(253 단위 안), 경로 앞·끝 조각은 곧바로, 가운데 조각은 미리 만든 실패 표의 KMP 로 한 번씩
//! 훑는다 — 패턴 하나에 많아야 64 Ki 단위 × 조각 수가 아니라 64 Ki 단위 한 번(조각은 차례로 이어 찾는다 — 이미 선형이다). 규칙 32 개면 그
//! 32 배라, 한 **요청**의 가운데 조각 훑기는 모든 규칙을 합쳐 `request_scan_budget` 단위까지만(`Budget` — W9d③ 4 차 검증 B-LOW-4: 별 7 개 규칙
//! 32 개를 쥔 탭의 60 KiB 주소 요청 300 개가 브라우저가 함께 쓰는 IO 스레드를 붙잡아 규칙 없는 다른 탭의 fetch 가 98 → 539 ms, ReleaseFast).
//! 예산이 다해 다 보지 못한 가운데 조각은 **맞은 것으로** 친다(막는 쪽 — 새는 쪽으로 바뀌는 판정은 없다): 호스트·포트·앞 조각·끝 조각은 그대로
//! 정확히 보므로 넘치게 막는 것은 그 넷이 맞고 가운데만 남은 규칙뿐이다(문서화된 대가).
//!
//! 시험이 증명하는 것: 풀기의 거절마다(이유)·정규형(호스트 꼴·포트·이스케이프·512/513 바이트·`*` 8/9 개·스킴), 맞추기 표(앞부분 대 glob,
//! 쿼리 포함, 조각·사용자 정보, `*.a.test` 대 `evila.test`, 끝 고정, 포트, IPv6), KMP 맞추기와 단순 참조의 무작위 대조 20 만 번(u8·u16),
//! 2 MiB 주소의 반복 판정 CPU 상한, 종류 이름 표.

const array_repeat = @import("array_repeat");

const std = @import("std");
const net_policy = @import("net_policy.zig");
const message = @import("message.zig");
const url_canon = @import("url_canon.zig");

/// 탭 하나(pane 마다가 아니라 탭 전체)의 규칙 수 상한.
pub const max_rules: usize = 32;
/// 패턴 하나의 바이트 상한(입력·정규형 모두).
pub const max_pattern_bytes: usize = 512;
/// 패턴의 `*` 수 상한 — 조각 수가 묶여 맞추기 시간이 묶인다.
pub const max_stars: usize = 8;
/// 가운데 조각을 찾는 범위(경로+쿼리 앞부분, 단위). 넘는 곳의 가운데 조각은 맞지 않은 것으로 친다(문서화된 빠져나가기 — 2 MiB 주소가 IO 스레드를
/// 붙잡지 않게).
pub const scan_limit: usize = 64 * 1024;
/// 한 요청이 모든 규칙의 가운데 조각을 훑는 단위 합의 상한(4 차 검증 B-LOW-4 — 규칙 하나의 최악 한 번만큼). 넘으면 남은 가운데 조각은 맞은
/// 것으로 친다(막는 쪽).
pub const request_scan_budget: usize = scan_limit;

/// 한 요청의 맞추기 예산(`request_scan_budget` 에서 줄어든다 — 요청마다 새로).
pub const Budget = struct {
    left: usize = request_scan_budget,
};
/// DNS 이름 상한(`net_policy`·grant 와 같다).
pub const max_host_bytes: usize = message.max_net_host_bytes;

/// 풀기의 거절 까닭 — 에이전트에게 `pattern_invalid:<이름>`(ASCII 밖은 따로 `not_ascii`)으로 간다.
pub const Why = enum {
    empty,
    too_long,
    not_ascii,
    control_or_space,
    fragment,
    userinfo,
    scheme,
    host,
    port,
    path,
    too_many_stars,
    escape,

    pub fn name(self: Why) []const u8 {
        return @tagName(self);
    }
};

pub const Scheme = enum(u2) { http, https, any };
pub const HostKind = enum(u2) { any, wildcard, exact };

/// 경로 glob 의 조각 하나(`path` 안의 [start, start + len)).
const Piece = struct { start: u16 = 0, len: u16 = 0 };

/// 풀어 다듬은 패턴 — 정규형 글과 맞추기에 쓰는 표(IO 스레드에서 할당 없이 쓴다). 값 타입이다(복사해도 된다).
pub const Pattern = struct {
    scheme: Scheme = .any,
    host_kind: HostKind = .any,
    /// `exact` 면 그 호스트, `wildcard` 면 `*.` 뒤의 도메인(소문자, 끝 점 없음).
    host_buf: [max_host_bytes]u8 = undefined,
    host_len: u16 = 0,
    port: ?u16 = null,
    /// `*` 가 하나라도 있다 — 없으면 앞부분 꼴.
    glob: bool = false,
    /// 경로 꼴(정규형 — `/` 로 시작, `%xx` 대문자). 앞부분 꼴이면 앞부분, glob 꼴이면 양끝이 묶인 glob.
    path_buf: [max_pattern_bytes]u8 = undefined,
    path_len: u16 = 0,
    /// glob 꼴의 조각(`*` 사이) — `*` 가 n 개면 n+1 개(빈 조각 포함).
    pieces: [max_stars + 2]Piece = @splat(.{}),
    piece_count: u8 = 0,
    /// 조각마다의 KMP 실패 표(`path_buf` 와 같은 자리에 — 조각의 i 번째 바이트의 표 값은 `fail[piece.start + i]`).
    fail: [max_pattern_bytes]u16 = undefined,
    /// 정규형 글(`norm()`).
    norm_buf: [max_pattern_bytes + 8]u8 = undefined,
    norm_len: u16 = 0,

    pub fn host(self: *const Pattern) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn path(self: *const Pattern) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// 정규형 — 같은 글이면 같은 규칙이다(`already`).
    pub fn norm(self: *const Pattern) []const u8 {
        return self.norm_buf[0..self.norm_len];
    }

    fn piece(self: *const Pattern, i: usize) []const u8 {
        const p = self.pieces[i];
        return self.path_buf[p.start..][0..p.len];
    }
};

/// 풀기의 답 — 성공이면 패턴, 아니면 까닭.
pub const Parsed = union(enum) { ok: Pattern, err: Why };

/// 패턴 글을 풀어 다듬는다(maru 의 인자 검사·sidecar 의 규칙 묶음이 같은 함수를 쓴다).
pub fn parse(text: []const u8) Parsed {
    var p: Pattern = .{};
    if (parseInto(text, &p)) |why| return .{ .err = why };
    return .{ .ok = p };
}

fn parseInto(text: []const u8, p: *Pattern) ?Why {
    if (text.len == 0) return .empty;
    if (text.len > max_pattern_bytes) return .too_long;
    for (text) |ch| if (ch >= 0x80) return .not_ascii;
    for (text) |ch| if (ch <= 0x20 or ch == 0x7f) return .control_or_space;
    if (std.mem.indexOfScalar(u8, text, '#') != null) return .fragment;
    if (std.mem.count(u8, text, "*") > max_stars) return .too_many_stars;
    p.glob = std.mem.indexOfScalar(u8, text, '*') != null;

    const sep = std.mem.indexOf(u8, text, "://") orelse return .scheme;
    const scheme = text[0..sep];
    p.scheme = if (std.ascii.eqlIgnoreCase(scheme, "http"))
        .http
    else if (std.ascii.eqlIgnoreCase(scheme, "https"))
        .https
    else if (std.mem.eql(u8, scheme, "*"))
        .any
    else
        return .scheme;

    const rest = text[sep + 3 ..];
    const auth_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..auth_end];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return .userinfo;
    if (authority.len == 0) return .host;

    // 호스트와 포트 — IPv6 는 괄호 안의 `:` 를 포트로 읽지 않는다.
    var host_text = authority;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return .host;
        host_text = authority[0 .. close + 1];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return .host;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host_text = authority[0..colon];
        port_text = authority[colon + 1 ..];
    }
    if (parseHost(host_text, p)) |why| return why;
    if (port_text) |pt| {
        if (pt.len == 0 or pt.len > 5) return .port;
        for (pt) |ch| if (!std.ascii.isDigit(ch)) return .port;
        const v = std.fmt.parseInt(u32, pt, 10) catch return .port;
        if (v == 0 or v > 65535) return .port;
        p.port = @intCast(v);
        // 정해진 스킴의 기본 포트는 뗀다(정규형 — 주소 쪽의 GURL 도 뗀다).
        if ((p.scheme == .http and v == 80) or (p.scheme == .https and v == 443)) p.port = null;
    }

    // 경로 — 없으면 아무 경로(앞부분 꼴 `/`, glob 꼴 `/*`).
    const raw_path = rest[auth_end..];
    var n: usize = 0;
    if (raw_path.len == 0) {
        p.path_buf[0] = '/';
        n = 1;
        if (p.glob) {
            p.path_buf[1] = '*';
            n = 2;
        }
    } else {
        var i: usize = 0;
        while (i < raw_path.len) : (i += 1) {
            const ch = raw_path[i];
            if (ch == '%') {
                if (i + 2 >= raw_path.len) return .escape;
                const a = raw_path[i + 1];
                const b = raw_path[i + 2];
                if (!std.ascii.isHex(a) or !std.ascii.isHex(b)) return .escape;
                if (n + 3 > p.path_buf.len) return .too_long;
                p.path_buf[n] = '%';
                p.path_buf[n + 1] = std.ascii.toUpper(a);
                p.path_buf[n + 2] = std.ascii.toUpper(b);
                n += 3;
                i += 2;
                continue;
            }
            if (n == p.path_buf.len) return .too_long;
            p.path_buf[n] = ch;
            n += 1;
        }
    }
    p.path_len = @intCast(n);
    if (deadPath(p.path(), p.glob)) return .path;
    if (p.glob) splitPieces(p);

    // 정규형 글.
    var w: std.Io.Writer = .fixed(&p.norm_buf);
    w.writeAll(switch (p.scheme) {
        .http => "http://",
        .https => "https://",
        .any => "*://",
    }) catch return .too_long;
    switch (p.host_kind) {
        .any => w.writeAll("*") catch return .too_long,
        .wildcard => {
            w.writeAll("*.") catch return .too_long;
            w.writeAll(p.host()) catch return .too_long;
        },
        .exact => w.writeAll(p.host()) catch return .too_long,
    }
    if (p.port) |v| w.print(":{d}", .{v}) catch return .too_long;
    w.writeAll(p.path()) catch return .too_long;
    if (w.buffered().len > max_pattern_bytes) return .too_long;
    p.norm_len = @intCast(w.buffered().len);
    return null;
}

/// 호스트 꼴(`*`·`*.domain`·정확한 호스트·`[IPv6]`) — 소문자로, 끝 점은 뗀다.
fn parseHost(text: []const u8, p: *Pattern) ?Why {
    if (std.mem.eql(u8, text, "*")) {
        p.host_kind = .any;
        return null;
    }
    var h = text;
    p.host_kind = .exact;
    if (std.mem.startsWith(u8, h, "*.")) {
        p.host_kind = .wildcard;
        h = h[2..];
    }
    if (h.len > 0 and h[h.len - 1] == '.' and h[0] != '[') h = h[0 .. h.len - 1];
    if (h.len == 0 or h.len > max_host_bytes) return .host;
    if (h[0] == '[') {
        if (p.host_kind == .wildcard) return .host;
        if (h.len < 3 or h[h.len - 1] != ']') return .host;
        for (h[1 .. h.len - 1]) |ch| if (!(std.ascii.isHex(ch) or ch == ':' or ch == '.')) return .host;
    } else {
        for (h) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_';
            if (!ok) return .host;
        }
        if (h[0] == '.' or std.mem.indexOf(u8, h, "..") != null) return .host;
    }
    // 끝 점은 하나만 뗀다 — 더 남았으면(`a.test..`) GURL 의 어떤 호스트와도 같지 않다.
    if (h[h.len - 1] == '.') return .host;
    for (h, 0..) |ch, i| p.host_buf[i] = std.ascii.toLower(ch);
    p.host_len = @intCast(h.len);
    // IP 호스트는 GURL 이 한 꼴로 바꾼다(`url_canon`) — 다른 꼴로 쓴 정확한 호스트는 어느 주소에도 맞지 않는다.
    if (p.host_kind == .exact) {
        const lower = p.host();
        if (lower[0] == '[') {
            const groups = url_canon.ipv6(u8, lower[1 .. lower.len - 1]) orelse return .host;
            var tb: [39]u8 = undefined;
            if (!std.mem.eql(u8, url_canon.ipv6Text(groups, &tb), lower[1 .. lower.len - 1])) return .host;
        } else switch (url_canon.ipv4(u8, lower)) {
            .not_ip => {},
            .invalid => return .host,
            .ok => |addr| {
                var tb: [15]u8 = undefined;
                if (!std.mem.eql(u8, url_canon.ipv4Text(addr, &tb), lower)) return .host;
            },
        }
    }
    return null;
}

/// 정규형 경로(+쿼리)가 GURL 의 주소 꼴에 나올 수 없는가 — 쿼리 앞의 점 조각(`.`·`..`·`%2E` 꼴 — GURL 이 푼다)·`\`(`/` 로 바꾼다)·`"`·`<`·`>`·
/// `{`·`}`·`|`·`^`·`` ` ``(`%XX` 로 바꾼다 — 실측 CEF 154: 경로 `/a{b}c|d^e`f'g` 가 `/a%7Bb%7Dc%7Cd%5Ee%60f'g` 로 갔다), 쿼리의 `"`·`<`·`>`·`'`
/// (쿼리의 `'` 는 `%27` 로 — 같은 실측, 쿼리의 `{`·`}`·`|`·`^`·`` ` `` 는 그대로). `*` 가 낀 조각은 점 조각이 아니다(아무 글자에 맞는다).
/// 앞부분 꼴(`glob` 거짓)의 **마지막** 조각은 점 조각이어도 산다 — 주소의 더 긴 조각의 앞부분이다(`/.` 은 `/.well-known`·`/.env`, `/..` 은 `/..foo`,
/// `/x/%2E` 은 `/x/%2Ehidden` 에 맞는다 — Chromium 은 그 조각들을 그대로 둔다, 2 차 검증 N-A2-1 실측 4/4). 쿼리가 있으면 경로는 거기서 끝난다.
fn deadPath(path_text: []const u8, glob: bool) bool {
    const q = std.mem.indexOfScalar(u8, path_text, '?') orelse path_text.len;
    for (path_text[0..q]) |ch| switch (ch) {
        '\\', '"', '<', '>', '{', '}', '|', '^', '`' => return true,
        else => {},
    };
    for (path_text[q..]) |ch| switch (ch) {
        '"', '<', '>', '\'' => return true,
        else => {},
    };
    const open_tail = !glob and q == path_text.len;
    var it = std.mem.splitScalar(u8, path_text[0..q], '/');
    while (it.next()) |seg| {
        if (open_tail and it.peek() == null) break; // 앞부분 꼴의 끝 조각 — 더 긴 조각의 앞부분
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, "%2E") or std.mem.eql(u8, seg, "%2E%2E") or
            std.mem.eql(u8, seg, ".%2E") or std.mem.eql(u8, seg, "%2E.")) return true;
    }
    return false;
}

/// glob 꼴의 경로를 `*` 로 나누고 조각마다 KMP 실패 표를 만든다.
fn splitPieces(p: *Pattern) void {
    const path_text = p.path();
    var start: usize = 0;
    var count: usize = 0;
    for (path_text, 0..) |ch, i| if (ch == '*') {
        p.pieces[count] = .{ .start = @intCast(start), .len = @intCast(i - start) };
        count += 1;
        start = i + 1;
    };
    p.pieces[count] = .{ .start = @intCast(start), .len = @intCast(path_text.len - start) };
    count += 1;
    p.piece_count = @intCast(count);
    for (p.pieces[0..count]) |pc| buildFail(p.path_buf[pc.start..][0..pc.len], p.fail[pc.start..][0..pc.len]);
}

/// KMP 실패 표 — `fail[i]` 는 `needle[0..i+1]` 의 가장 긴 진짜 앞뒤 공통 길이.
fn buildFail(needle: []const u8, fail: []u16) void {
    if (needle.len == 0) return;
    fail[0] = 0;
    var k: u16 = 0;
    var i: usize = 1;
    while (i < needle.len) : (i += 1) {
        while (k > 0 and needle[i] != needle[k]) k = fail[k - 1];
        if (needle[i] == needle[k]) k += 1;
        fail[i] = k;
    }
}

// ── 종류 ─────────────────────────────────────────────────────────────────────────────────────────────

/// 종류 이름(`net_policy.resourceTypeName`)을 CEF 종류 번호의 비트로. `service_worker` 는 거절한다(서비스 워커 길의 요청은 모두 그 워커가 부른
/// fetch 라 종류로 가를 수 없다 — W9d③ 실측 sw1, 계획 §12 P1-7). 모르는 이름은 null.
pub fn typeBits(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "service_worker")) return null;
    var bits: u32 = 0;
    var rt: u8 = 0;
    while (rt <= message.max_net_resource_type) : (rt += 1) {
        if (rt == 18) continue;
        if (std.mem.eql(u8, net_policy.resourceTypeName(rt), name)) bits |= @as(u32, 1) << @intCast(rt);
    }
    return if (bits == 0) null else bits;
}

/// 종류 마스크에서 쓸 수 있는 비트(0..20, 18·서비스 워커 15 빼고).
pub const types_mask_valid: u32 = blk: {
    var m: u32 = 0;
    for (0..message.max_net_resource_type + 1) |rt| {
        if (rt == 18 or rt == 15) continue;
        m |= @as(u32, 1) << @intCast(rt);
    }
    break :blk m;
};

/// 그 종류(CEF 번호 — sidecar 가 18 을 6 으로 바꾼 뒤)가 마스크에 드는가(0 은 모든 종류).
pub fn typeMatches(mask: u32, resource_type: u8) bool {
    if (mask == 0) return true;
    if (resource_type > 31) return false;
    return mask & (@as(u32, 1) << @intCast(resource_type)) != 0;
}

/// 마스크를 이름 목록으로(`out` 에 — 같은 이름은 한 번). 결과 JSON 이 쓴다.
pub fn typeNames(mask: u32, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var rt: u8 = 0;
    while (rt <= message.max_net_resource_type) : (rt += 1) {
        if (mask & (@as(u32, 1) << @intCast(rt)) == 0) continue;
        const name = net_policy.resourceTypeName(rt);
        const dup = for (out[0..n]) |o| {
            if (std.mem.eql(u8, o, name)) break true;
        } else false;
        if (dup or n == out.len) continue;
        out[n] = name;
        n += 1;
    }
    return out[0..n];
}

// ── 주소 쪽(IO 스레드 — 할당 없음) ───────────────────────────────────────────────────────────────────

/// 주소의 부분(단위 꼴 그대로 — `T` 는 u8 이나 u16). http(s) 가 아니면 null.
pub fn UrlParts(comptime T: type) type {
    return struct {
        scheme: Scheme,
        host: []const T,
        /// 실제 포트(없으면 스킴의 기본 포트).
        port: u16,
        /// 경로 + 쿼리(조각 앞까지) — 비면 `/` 로 친다(GURL 은 늘 경로를 준다).
        path: []const T,
    };
}

/// 단위가 ASCII 글자 `ch` 인가.
inline fn isUnit(comptime T: type, u: T, ch: u8) bool {
    return u == @as(T, ch);
}

fn asciiLowerUnit(comptime T: type, u: T) T {
    if (u >= 'A' and u <= 'Z') return u + 32;
    return u;
}

/// GURL 정규 주소를 나눈다(스킴은 대소문자 무시, 사용자 정보는 건너뛴다, 조각은 뗀다). http(s) 가 아니거나 호스트가 없으면 null.
pub fn splitUrl(comptime T: type, url: []const T) ?UrlParts(T) {
    var colon: usize = 0;
    while (colon < url.len and colon < 8 and !isUnit(T, url[colon], ':')) colon += 1;
    if (colon >= url.len or !isUnit(T, url[colon], ':')) return null;
    const scheme: Scheme = if (unitsEqlIgnoreCase(T, url[0..colon], "http"))
        .http
    else if (unitsEqlIgnoreCase(T, url[0..colon], "https"))
        .https
    else
        return null;
    if (url.len < colon + 3 or !isUnit(T, url[colon + 1], '/') or !isUnit(T, url[colon + 2], '/')) return null;
    const a_start = colon + 3;
    var a_end = a_start;
    while (a_end < url.len and !isUnit(T, url[a_end], '/') and !isUnit(T, url[a_end], '?') and !isUnit(T, url[a_end], '#')) a_end += 1;
    var h_start = a_start;
    var k = a_start;
    while (k < a_end) : (k += 1) if (isUnit(T, url[k], '@')) {
        h_start = k + 1;
    };
    var h_end = a_end;
    var port: u16 = if (scheme == .https) 443 else 80;
    // 포트 — 마지막 `:` 가 IPv6 괄호 밖이면.
    var j = a_end;
    while (j > h_start) {
        j -= 1;
        if (isUnit(T, url[j], ']')) break;
        if (isUnit(T, url[j], ':')) {
            var v: u32 = 0;
            var digits: usize = 0;
            for (url[j + 1 .. a_end]) |u| {
                if (u < '0' or u > '9') return null;
                v = v * 10 + @as(u32, @intCast(u - '0'));
                digits += 1;
                if (v > 65535) return null;
            }
            if (digits > 0) port = @intCast(v);
            h_end = j;
            break;
        }
    }
    var host = url[h_start..h_end];
    if (host.len > 0 and isUnit(T, host[host.len - 1], '.')) host = host[0 .. host.len - 1];
    if (host.len == 0) return null;
    var p_end = a_end;
    while (p_end < url.len and !isUnit(T, url[p_end], '#')) p_end += 1;
    return .{ .scheme = scheme, .host = host, .port = port, .path = url[a_end..p_end] };
}

fn unitsEqlIgnoreCase(comptime T: type, units: []const T, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, ch| if (asciiLowerUnit(T, u) != @as(T, std.ascii.toLower(ch))) return false;
    return true;
}

fn unitsEql(comptime T: type, units: []const T, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, ch| if (u != @as(T, ch)) return false;
    return true;
}

/// 주소 호스트가 패턴 호스트에 드는가(대소문자 무시 — GURL 은 이미 소문자다).
fn hostMatches(comptime T: type, p: *const Pattern, host: []const T) bool {
    switch (p.host_kind) {
        .any => return true,
        .exact => return unitsEqlIgnoreCase(T, host, p.host()),
        .wildcard => {
            const d = p.host();
            if (host.len == d.len) return unitsEqlIgnoreCase(T, host, d);
            if (host.len < d.len + 1) return false;
            return isUnit(T, host[host.len - d.len - 1], '.') and unitsEqlIgnoreCase(T, host[host.len - d.len ..], d);
        },
    }
}

/// 그 주소(GURL 정규 꼴 — 단위 그대로)가 패턴에 맞는가.
pub fn matchUrl(comptime T: type, p: *const Pattern, url: []const T) bool {
    const parts = splitUrl(T, url) orelse return false;
    return matchParts(T, p, parts);
}

/// 나눠 둔 주소가 패턴에 맞는가(규칙 여럿을 맞출 때 주소를 한 번만 나눈다). 예산 없이 — 모두 훑는다(maru·시험).
pub fn matchParts(comptime T: type, p: *const Pattern, parts: UrlParts(T)) bool {
    var unlimited: Budget = .{ .left = std.math.maxInt(usize) };
    return matchPartsBudget(T, p, parts, &unlimited);
}

/// `matchParts` 와 같고, 가운데 조각 훑기가 `budget` 을 쓴다 — 예산이 다해 다 보지 못하면 맞은 것으로 친다(막는 쪽, IO 스레드의 요청마다).
pub fn matchPartsBudget(comptime T: type, p: *const Pattern, parts: UrlParts(T), budget: *Budget) bool {
    if (p.scheme != .any and p.scheme != parts.scheme) return false;
    if (!hostMatches(T, p, parts.host)) return false;
    if (p.port) |v| if (v != parts.port) return false;
    const slash = [_]T{'/'};
    const path_units: []const T = if (parts.path.len == 0) &slash else parts.path;
    if (!p.glob) {
        // 앞부분 꼴 — 경로+쿼리가 패턴 경로로 시작한다.
        const want = p.path();
        if (path_units.len < want.len) return false;
        return unitsEql(T, path_units[0..want.len], want);
    }
    return globMatch(T, p, path_units, budget);
}

/// glob(양끝 묶음): 첫 조각은 앞에, 마지막 조각은 **진짜 끝**에, 가운데 조각은 차례로 KMP(앞 `scan_limit` 단위 안). 가운데 조각이 훑는 단위는
/// `budget` 에서 뺀다 — 예산 안에서 찾지 못했고 범위가 남았으면 맞은 것으로 친다(다 보지 못했다 — 막는 쪽).
fn globMatch(comptime T: type, p: *const Pattern, text: []const T, budget: *Budget) bool {
    const n = p.piece_count;
    const first = p.piece(0);
    if (text.len < first.len or !unitsEql(T, text[0..first.len], first)) return false;
    // 경로에 `*` 가 없는 glob — 스킴·호스트에만 `*` 가 있었다(`*://a.test/ads`): 경로는 정확히 그것(Chrome match-pattern — 모듈 머리 참고).
    if (n == 1) return text.len == first.len;
    var pos: usize = first.len;
    const last = p.piece(n - 1);
    if (text.len < pos + last.len) return false;
    const tail_start = text.len - last.len;
    if (!unitsEql(T, text[tail_start..], last)) return false;
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        const pc = p.pieces[i];
        if (pc.len == 0) continue;
        const limit = @min(tail_start, scan_limit);
        const range = limit -| pos;
        const allowed = @min(range, budget.left);
        const found = kmpFind(T, p.path_buf[pc.start..][0..pc.len], p.fail[pc.start..][0..pc.len], text, pos, pos + allowed) orelse {
            budget.left -= allowed;
            return allowed < range; // 예산이 범위를 다 덮지 못했다 — 모른다, 막는 쪽
        };
        budget.left -= found + pc.len - pos;
        pos = found + pc.len;
        if (pos > tail_start) return false;
    }
    return true;
}

/// `text[from..]` 에서 `needle` 이 **끝나는 자리가 `limit` 안인** 첫 자리(시작 첨자). 없으면 null.
fn kmpFind(comptime T: type, needle: []const u8, fail: []const u16, text: []const T, from: usize, limit: usize) ?usize {
    if (needle.len == 0) return from;
    var k: usize = 0;
    var i = from;
    while (i < limit) : (i += 1) {
        const u = text[i];
        while (k > 0 and u != @as(T, needle[k])) k = fail[k - 1];
        if (u == @as(T, needle[k])) k += 1;
        if (k == needle.len) return i + 1 - needle.len;
    }
    return null;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn okPattern(text: []const u8) !Pattern {
    return switch (parse(text)) {
        .ok => |p| p,
        .err => |why| {
            std.debug.print("unexpected reject {s}: {s}\n", .{ text, why.name() });
            return error.TestUnexpectedResult;
        },
    };
}

fn expectWhy(text: []const u8, want: Why) !void {
    switch (parse(text)) {
        .ok => |p| {
            std.debug.print("unexpected accept {s} -> {s}\n", .{ text, p.norm() });
            return error.TestUnexpectedResult;
        },
        .err => |why| try testing.expectEqual(want, why),
    }
}

fn mt(pattern: []const u8, url: []const u8) !bool {
    const p = try okPattern(pattern);
    const a = matchUrl(u8, &p, url);
    // 같은 주소를 UTF-16 단위로도 — 두 꼴이 같은 답을 낸다(sidecar 는 u16 으로 맞춘다).
    var buf: [4096]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, url) catch unreachable;
    const b = matchUrl(u16, &p, buf[0..n]);
    try testing.expectEqual(a, b);
    return a;
}

test "W9d③: 패턴 풀기 — 거절마다 까닭(빈 글·512/513 바이트·ASCII 밖·빈칸·조각·사용자 정보·스킴·호스트·포트·`*` 9 개·잘못 쓴 %)" {
    try expectWhy("", .empty);
    try expectWhy("https://a.test/" ++ array_repeat.repeat("x", max_pattern_bytes - 15 + 1), .too_long);
    _ = try okPattern("https://a.test/" ++ array_repeat.repeat("x", max_pattern_bytes - 15));
    try expectWhy("https://가.test/", .not_ascii);
    try expectWhy("https://a.test/a b", .control_or_space);
    try expectWhy("https://a.test/\tx", .control_or_space);
    try expectWhy("https://a.test/x#frag", .fragment);
    try expectWhy("https://user@a.test/", .userinfo);
    try expectWhy("https://u:p@a.test/", .userinfo);
    _ = try okPattern("https://a.test/@user"); // 경로의 `@` 는 사용자 정보가 아니다
    try expectWhy("ws://a.test/", .scheme);
    try expectWhy("wss://a.test/", .scheme);
    try expectWhy("data:text/html,x", .scheme);
    try expectWhy("blob:https://a.test/x", .scheme);
    try expectWhy("file:///etc/passwd", .scheme);
    try expectWhy("a.test/x", .scheme);
    try expectWhy("ht*p://a.test/", .scheme);
    try expectWhy("https:///x", .host);
    try expectWhy("https://a*.test/", .host);
    try expectWhy("https://*a.test/", .host);
    try expectWhy("https://a.*.test/", .host);
    try expectWhy("https://a..test/", .host);
    try expectWhy("https://*./", .host);
    try expectWhy("https://[zz]/", .host);
    try expectWhy("https://*.[::1]/", .host);
    try expectWhy("https://a.test:/", .port);
    try expectWhy("https://a.test:0/", .port);
    try expectWhy("https://a.test:65536/", .port);
    try expectWhy("https://a.test:8*/", .port);
    try expectWhy("https://a.test:+80/", .port);
    _ = try okPattern("*://*/" ++ array_repeat.repeat("*", 6)); // 8 개
    try expectWhy("*://*/" ++ array_repeat.repeat("*", 7), .too_many_stars);
    try expectWhy("https://a.test/%", .escape);
    try expectWhy("https://a.test/%4", .escape);
    try expectWhy("https://a.test/%zz", .escape);
}

test "W9d③: 정규형 — 스킴·호스트 소문자, 끝 점·기본 포트 뗌, %xx 대문자, 빈 경로는 앞부분 꼴 `/`·glob 꼴 `/*`" {
    try testing.expectEqualStrings("https://a.test/X?q=%2F", (try okPattern("HTTPS://A.Test./X?q=%2f")).norm());
    try testing.expectEqualStrings("https://a.test/", (try okPattern("https://a.test:443")).norm());
    try testing.expectEqualStrings("http://a.test/", (try okPattern("http://a.test:80/")).norm());
    try testing.expectEqualStrings("https://a.test:80/", (try okPattern("https://a.test:80/")).norm());
    try testing.expectEqualStrings("*://a.test:443/*", (try okPattern("*://a.test:443")).norm()); // 스킴이 둘이면 기본 포트를 떼지 않는다
    try testing.expectEqualStrings("*://*.a.test/*", (try okPattern("*://*.A.test")).norm());
    try testing.expectEqualStrings("https://[::1]:8443/x", (try okPattern("https://[::1]:8443/x")).norm());
    try testing.expectEqualStrings("*://*/*.js", (try okPattern("*://*/*.js")).norm());
    // 같은 규칙은 같은 정규형 — maru 가 `already` 를 가른다.
    try testing.expectEqualStrings((try okPattern("https://a.test")).norm(), (try okPattern("https://A.TEST/")).norm());
    try testing.expect(!(try okPattern("https://a.test/x")).glob);
    try testing.expect((try okPattern("https://a.test/x*")).glob);
}

test "W9d③: 맞추기 — 앞부분 꼴은 풀어 본 주소의 앞부분(날 글이 아니다), 쿼리 포함, 조각·사용자 정보는 보지 않는다" {
    try testing.expect(try mt("https://a.test", "https://a.test/"));
    try testing.expect(try mt("https://a.test", "https://a.test/any/path?x=1"));
    try testing.expect(!(try mt("https://a.test", "https://a.test.evil/"))); // 날 글 앞부분이 아니다
    try testing.expect(!(try mt("https://a.test", "https://sub.a.test/"))); // 앞부분 꼴의 호스트는 정확히
    try testing.expect(!(try mt("https://a.test", "http://a.test/"))); // 스킴
    try testing.expect(try mt("https://a.test/api", "https://a.test/api/v1?k=v"));
    try testing.expect(try mt("https://a.test/api?k=", "https://a.test/api?k=1"));
    try testing.expect(!(try mt("https://a.test/api", "https://a.test/ap")));
    try testing.expect(try mt("https://a.test/api", "https://u:p@a.test/api#x")); // 사용자 정보 건너뜀, 조각 뗌
    try testing.expect(!(try mt("https://a.test/x", "https://a.test/y#/x")));
    try testing.expect(try mt("https://a.test/", "https://a.test")); // GURL 은 늘 경로를 준다 — 빈 경로는 `/`
    try testing.expect(try mt("https://a.test.", "https://a.test./x")); // 끝 점은 양쪽에서
    try testing.expect(!(try mt("https://a.test/x", "wss://a.test/x")));
    try testing.expect(!(try mt("*://*/*", "data:text/html,x")));
    try testing.expect(!(try mt("*://*/*", "blob:https://a.test/1")));
    try testing.expect(!(try mt("*://*/*", "file:///x")));
}

test "W9d③: 맞추기 — glob 은 양끝이 묶이고 `*` 는 `/`·`?` 를 넘는다, `*.a.test` 는 점 경계, 포트, IPv6, 끝 조각은 진짜 끝" {
    try testing.expect(try mt("*://*.a.test/*", "https://a.test/"));
    try testing.expect(try mt("*://*.a.test/*", "http://x.y.a.test/z"));
    try testing.expect(!(try mt("*://*.a.test/*", "https://evila.test/")));
    try testing.expect(!(try mt("*://*.a.test/*", "https://a.test.evil/")));
    try testing.expect(try mt("*://*/*.js", "https://cdn.test/lib/x.js"));
    try testing.expect(!(try mt("*://*/*.js", "https://cdn.test/lib/x.js?v=1"))); // 쿼리까지가 경로 — 끝이 묶인다
    try testing.expect(try mt("*://*/*.js*", "https://cdn.test/lib/x.js?v=1"));
    try testing.expect(try mt("https://a.test/api/*/items", "https://a.test/api/v1/x/items"));
    try testing.expect(!(try mt("https://a.test/api/*/items", "https://a.test/api/v1/items/x")));
    try testing.expect(try mt("https://a.test/*track*", "https://a.test/a?q=track&z"));
    try testing.expect(!(try mt("https://a.test/api*", "https://a.test/ap")));
    try testing.expect(try mt("*://a.test/*", "http://a.test/"));
    try testing.expect(!(try mt("https://a.test:8443/*", "https://a.test/")));
    try testing.expect(try mt("https://a.test:8443/*", "https://a.test:8443/x"));
    try testing.expect(try mt("http://a.test:8080/", "http://a.test:8080/x"));
    try testing.expect(try mt("https://a.test:443/*", "https://a.test/x")); // 기본 포트를 뗐다 — 아무 포트
    try testing.expect(try mt("*://a.test/*", "https://a.test:9/x")); // 포트가 없으면 아무 포트
    try testing.expect(try mt("http://[::1]:8080/*", "http://[::1]:8080/a"));
    try testing.expect(!(try mt("http://[::1]/*", "http://[::2]/a")));
    try testing.expect(try mt("http://127.0.0.1/blk/*", "http://127.0.0.1:5555/blk/x"));
    try testing.expect(try mt("*://*/*", "https://anything.test/at/all?x"));
    try testing.expect(try mt("https://a.test/a*a*a", "https://a.test/aaa"));
    try testing.expect(!(try mt("https://a.test/a*a*a", "https://a.test/aa")));
}

/// 단순 참조 — glob 을 재귀로(시험 전용, 짧은 글만).
fn naiveGlob(pat: []const u8, text: []const u8) bool {
    if (pat.len == 0) return text.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) if (naiveGlob(pat[1..], text[i..])) return true;
        return false;
    }
    if (text.len == 0 or text[0] != pat[0]) return false;
    return naiveGlob(pat[1..], text[1..]);
}

test "W9d③: KMP glob 과 단순 참조를 무작위로 20 만 번 대조한다(u8·u16, 반복 많은 작은 글자 모음)" {
    var prng = std.Random.DefaultPrng.init(0x9d3);
    const r = prng.random();
    const alphabet = "ab/?";
    var pat_buf: [24]u8 = undefined;
    var text_buf: [40]u8 = undefined;
    var url_buf: [64]u8 = undefined;
    var url16: [64]u16 = undefined;
    var disagreements: usize = 0;
    for (0..200_000) |_| {
        // 경로 글 — `/` 로 시작, 글자 몇 개와 `*` 몇 개.
        const pl = r.intRangeAtMost(usize, 0, 12);
        pat_buf[0] = '/';
        var stars: usize = 0;
        for (1..pl + 1) |i| {
            if (stars < max_stars and r.intRangeLessThan(u8, 0, 4) == 0) {
                pat_buf[i] = '*';
                stars += 1;
            } else pat_buf[i] = alphabet[r.intRangeLessThan(usize, 0, 2)];
        }
        const pat_path = pat_buf[0 .. pl + 1];
        const tl = r.intRangeAtMost(usize, 0, 30);
        text_buf[0] = '/';
        for (1..tl + 1) |i| text_buf[i] = alphabet[r.intRangeLessThan(usize, 0, alphabet.len)];
        const text_path = text_buf[0 .. tl + 1];
        var pb: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pb, "https://a.test{s}", .{pat_path}) catch unreachable;
        const p = try okPattern(pattern);
        const url = std.fmt.bufPrint(&url_buf, "https://a.test{s}", .{text_path}) catch unreachable;
        for (url, 0..) |ch, i| url16[i] = ch;
        const want = if (p.glob) naiveGlob(pat_path, text_path) else std.mem.startsWith(u8, text_path, pat_path);
        const got8 = matchUrl(u8, &p, url);
        const got16 = matchUrl(u16, &p, url16[0..url.len]);
        if (got8 != want or got16 != want) disagreements += 1;
    }
    try testing.expectEqual(@as(usize, 0), disagreements);
}

test "W9d③: 0x7F 위의 단위는 패턴 바이트와 같지 않다 — `/é` 의 UTF-16 단위 0xE9 가 `/\\xE9` 꼴로 맞지 않는다" {
    const p = try okPattern("https://a.test/*x");
    const url = [_]u16{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'a', '.', 't', 'e', 's', 't', '/', 0x0178, 'x' };
    try testing.expect(matchUrl(u16, &p, &url));
    const q = try okPattern("https://a.test/x");
    const url2 = [_]u16{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'a', '.', 't', 'e', 's', 't', '/', 0x0178 };
    try testing.expect(!matchUrl(u16, &q, &url2));
    // 0x178 의 아래 바이트(0x78 = 'x')로 잘못 비교하면 맞을 자리.
    const url3 = [_]u16{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'a', '.', 't', 'e', 's', 't', '/', 0x0178 & 0xff00 | 'x' };
    try testing.expect(!matchUrl(u16, &q, &url3));
}

test "W9d③: 2 MiB 주소의 규칙 32개 반복 판정은 스레드 CPU 예산 안이다" {
    const gpa = testing.allocator;
    const len = 2 * 1024 * 1024;
    const url = try gpa.alloc(u16, len);
    defer gpa.free(url);
    const head = "https://a.test/";
    for (head, 0..) |ch, i| url[i] = ch;
    for (url[head.len..]) |*u| u.* = 'a';
    var rules: [max_rules]Pattern = undefined;
    for (&rules) |*r| r.* = try okPattern("https://a.test/*" ++ array_repeat.repeat("a", 40) ++ "b*" ++ array_repeat.repeat("a", 30) ++ "c");
    const resolution = std.Io.Clock.cpu_thread.resolution(testing.io) catch |err| switch (err) {
        error.ClockUnavailable => return error.SkipZigTest,
        else => return err,
    };
    if (resolution.nanoseconds <= 0) return error.SkipZigTest;
    const t0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    const c0 = std.Io.Clock.cpu_thread.now(testing.io).nanoseconds;
    var hits: usize = 0;
    for (&rules) |*r| {
        if (matchUrl(u16, r, url)) hits += 1;
    }
    const cpu_ns = std.Io.Clock.cpu_thread.now(testing.io).nanoseconds - c0;
    const wall_ns = std.Io.Clock.awake.now(testing.io).nanoseconds - t0;
    std.debug.print("net_block repeated URL checks: wall_ns={d} cpu_ns={d}\n", .{ wall_ns, cpu_ns });
    try testing.expectEqual(@as(usize, 0), hits);
    // 단일 스레드 계산이므로 CPU 대기를 예산에 넣지 않는다. Linux 제어 재현에서 단독
    // wall/CPU 162/162ms, 한 코어 8중 경쟁은 1240/157ms였다. 예산 500ms는 그대로다.
    // 이 fixture는 끝 조각 c가 맞지 않아 URL 분해를 32번 재며, KMP 최악 경로는 아니다.
    try testing.expect(cpu_ns > 0 and cpu_ns < 500 * std.time.ns_per_ms);
}

test "W9d③: 종류 이름 — 아는 이름의 비트, preload 는 둘(19·20), service_worker 와 모르는 이름은 거절, 마스크를 이름으로 되돌린다" {
    try testing.expectEqual(@as(u32, 1 << 4), typeBits("image").?);
    try testing.expectEqual(@as(u32, (1 << 19) | (1 << 20)), typeBits("preload").?);
    try testing.expectEqual(@as(u32, (1 << 6)), typeBits("other").?);
    try testing.expect(typeBits("service_worker") == null);
    try testing.expect(typeBits("websocket") == null);
    try testing.expect(typeMatches(0, 13));
    try testing.expect(typeMatches(typeBits("xhr").?, 13));
    try testing.expect(!typeMatches(typeBits("xhr").?, 4));
    try testing.expect(types_mask_valid & (1 << 15) == 0 and types_mask_valid & (1 << 18) == 0);
    var names: [24][]const u8 = undefined;
    const got = typeNames(typeBits("preload").? | typeBits("script").?, &names);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("script", got[0]);
    try testing.expectEqualStrings("preload", got[1]);
}

test "W9d③ 변이: 풀기의 빈틈 — DEL·앞 점 호스트·포트 붙은 `*.[IPv6]` 는 거절, 밑줄 호스트는 받는다, `%xx` 의 두 글자 모두 대문자" {
    try expectWhy("https://a.test/a\x7fb", .control_or_space);
    try expectWhy("https://.a.test/", .host);
    try expectWhy("https://*.[::1]:8080/", .host); // 괄호 앞의 `*.` — 포트가 있어도 와일드카드 IPv6 는 없다
    try testing.expect(try mt("https://a_b.test/x", "https://a_b.test/x/y"));
    try testing.expectEqualStrings("https://a.test/%AF%0B", (try okPattern("https://a.test/%af%0b")).norm());
}

test "W9d③ 변이: 가운데 조각은 앞 scan_limit 단위 안에서 끝나야 맞는다(경계 양쪽), KMP 실패 표가 되돌아갈 자리를 잃으면 놓친다" {
    const gpa = testing.allocator;
    const p = try okPattern("https://a.test/*X*");
    const head = "https://a.test";
    const url = try gpa.alloc(u8, head.len + scan_limit + 16);
    defer gpa.free(url);
    @memcpy(url[0..head.len], head);
    const path = url[head.len..];
    // 경로의 scan_limit - 1 자리에서 끝나는 조각은 범위 안이다.
    @memset(path, 'a');
    path[0] = '/';
    path[scan_limit - 1] = 'X';
    try testing.expect(matchUrl(u8, &p, url));
    // 한 자리 뒤(scan_limit 자리에서 시작 — 끝이 범위 밖)는 맞지 않는다(문서화된 빠져나가기의 경계).
    path[scan_limit - 1] = 'a';
    path[scan_limit] = 'X';
    try testing.expect(!matchUrl(u8, &p, url));
    // `aabaaaa` 는 실패 표가 0 이 아닌 자리로 되돌아가야 `aabaaabaaaa` 의 넷째 자리에서 찾는다(무작위 대조의 짧은 조각으로는 닿지 않는다).
    try testing.expect(try mt("https://a.test/*aabaaaa*", "https://a.test/aabaaabaaaa"));
}

test "W9d③ 4 차 검증 B-LOW-4: 한 요청의 맞추기 예산 — 가운데 조각 훑기만 예산을 쓰고, 다 보지 못하면 맞은 것으로 친다(막는 쪽), 호스트·앞·끝 조각은 예산과 무관하게 정확하다" {
    const p = try okPattern("https://a.test/*X*Y");
    var url: [64]u8 = undefined;
    const head = "https://a.test/";
    @memcpy(url[0..head.len], head);
    @memset(url[head.len..], 'a');
    url[head.len + 30] = 'X';
    url[url.len - 1] = 'Y';
    const parts = splitUrl(u8, &url).?;
    // 넉넉하면 정확하다 — 찾은 자리까지만 쓴다(경로 `/` 뒤 30 단위 + 조각 길이).
    var b: Budget = .{ .left = 1000 };
    try testing.expect(matchPartsBudget(u8, &p, parts, &b));
    try testing.expectEqual(@as(usize, 1000 - 31), b.left);
    // 조각이 없으면 범위만큼 쓰고 거짓.
    url[head.len + 30] = 'a';
    b = .{ .left = 1000 };
    try testing.expect(!matchPartsBudget(u8, &p, splitUrl(u8, &url).?, &b));
    try testing.expectEqual(@as(usize, 1000 - (url.len - 1 - head.len)), b.left);
    // 예산이 범위보다 작다 — 다 보지 못했다: 맞은 것으로(막는 쪽), 예산은 다 쓴다.
    b = .{ .left = 10 };
    try testing.expect(matchPartsBudget(u8, &p, splitUrl(u8, &url).?, &b));
    try testing.expectEqual(@as(usize, 0), b.left);
    // 예산이 0 이어도 끝 조각·앞 조각·호스트는 정확히 본다.
    b = .{ .left = 0 };
    url[url.len - 1] = 'Z';
    try testing.expect(!matchPartsBudget(u8, &p, splitUrl(u8, &url).?, &b));
    url[url.len - 1] = 'Y';
    try testing.expect(!matchPartsBudget(u8, &(try okPattern("https://a.test/b*X*Y")), splitUrl(u8, &url).?, &b));
    try testing.expect(!matchPartsBudget(u8, &(try okPattern("https://b.test/*X*Y")), splitUrl(u8, &url).?, &b));
    try testing.expect(matchPartsBudget(u8, &p, splitUrl(u8, &url).?, &b));
    // 예산 없는 matchParts 는 그대로 정확하다(maru·시험).
    try testing.expect(!matchParts(u8, &p, splitUrl(u8, &url).?));
}
