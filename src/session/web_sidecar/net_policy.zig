//! 에이전트에게 보이는 네트워크 기록의 규칙(W9d① — docs/plans/web-osr-backend.md 「W9d① 결정」) — 순수, sidecar 와 maru 가 같은 파일을 쓴다.
//!
//! 설정 `browser.agent-network-full`(켜짐이 기본 — 사용자 결정 2026-10-15)이 켜져 있으면 다 보인다(쿠키·인증 헤더 값, 주소의 사용자 정보,
//! 다른 사이트와 다른 사이트 iframe 의 요청까지). 꺼져 있으면 보수적인 투영이다:
//!   - grant 호스트가 덮지 않는 호스트의 요청은 페이지가 고른 칸(주소·메서드·종류·시각)과 `other_site` 만 — 상태·헤더·크기·리다이렉트 대상 없음.
//!   - 다른 사이트 iframe 의 요청은 수만 센다.
//!   - 헤더 값은 허용 목록(`headerRule`)만, 나머지는 이름만. Referer 는 출처만, Location 은 덮이는 호스트의 응답에만.
//!   - 주소의 사용자 정보(`user:pass@`)는 지운다.
//! sidecar 는 꺼져 있을 때 보내기 전에 같은 규칙으로 덜어 내고(`stripHeaders` — 헤더 값이 브라우저 프로세스 밖으로 나가지 않게), maru 는
//! 읽을 때 읽는 쪽의 grant 호스트로 다시 투영한다(그쪽이 기준이다 — grant 호스트는 다시 허락으로 바뀔 수 있다).
//!
//! 「사이트」는 공개 접미사 목록 없이 grant 와 같은 규칙(호스트와 그 하위 도메인)으로 어림한다 — 두 호스트 중 하나가 다른 하나를 덮지 않으면 다른
//! 사이트다(`www.a.com` 과 `api.a.com` 도 다른 사이트로 친다 — 더 숨기는 쪽).
//!
//! 자격 증명(W9d① 적대 리뷰 3 회차 D1 — 사용자 결정 2026-10-15 「쿠키 권한 있을 때만 보임」): `Cookie`·`Set-Cookie`·`Authorization`(과 같은
//! 갈래의 `Proxy-Authorization`) 값과 주소의 사용자 정보는 설정과 무관하게 읽는 쪽이 그 요청의 호스트를 덮는 `browser_storage` grant 를 쥘 때만
//! 보인다(`credentialHeader` — 투영은 maru 가 한다, 꺼져 있으면 sidecar 가 늘 덜어 낸다).
//! 주소를 싣는 헤더(W9d① 적대 리뷰 4 회차 C1): `Location`·`Refresh`·`Content-Location`·`Link`(와 `Referer`) 값 안 주소의 사용자 정보도 주소
//! 칸과 같은 규칙이다 — 켬이면 읽는 쪽의 쿠키 권한이 **그 주소의 호스트**를 덮을 때만 보이고(maru), 끔이면 sidecar 가 늘 지운다
//! (`maskHeaderUserinfo` — 서버가 고른 글이라 GURL 보다 너그럽게 찾는다: 더 지우는 쪽).
//! 호스트(W9d① 적대 리뷰 3 회차 T1): 덮이는지는 sidecar 가 **자르기 전의 온 주소**에서 읽어 따로 싣는 호스트 칸으로만 가른다
//! (`hostOfUrl16` — 2 KiB 에서 자른 주소는 긴 사용자 정보 안에서 끊겨 `https://yyy…a.test` 가 덮이는 사이트로 읽혔다).
//!
//! 시험이 증명하는 것: 호스트 덮기의 점 경계, 사용자 정보 지우기(경로의 `@` 는 그대로), 출처만 남기기, 헤더 규칙(접두 규칙 `accept*`·
//! `sec-fetch-*`·`access-control-*` 포함, 대소문자 무시), 자격 증명 헤더, 다른 사이트 iframe 판정, 덜어 낸 덩어리의 모양, 온 주소(UTF-16)의
//! 호스트·출처(사용자 정보 너머·잘릴 길이에서도). 브라우저 탭에서 중요한 이유 — 요청 헤더에는 로그인 쿠키와 인증 토큰이 그대로 들어 있다.

const array_repeat = @import("array_repeat");

const std = @import("std");
const message = @import("message.zig");
const net_fields = @import("net_fields.zig");

// ── 호스트 ───────────────────────────────────────────────────────────────────────────────────────────────

/// `current` 가 `granted` 이거나 그 하위 도메인인가(대소문자 무시). `github.com` 은 `gist.github.com` 을 덮지만
/// `evilgithub.com` 은 덮지 않는다(점 경계). 거꾸로 하위 도메인 grant 는 부모·형제를 덮지 않는다. 어느 쪽이든 비면 false.
/// grant 의 단일 출처다 — `control_pane_grant.hostCovers` 가 이것을 그대로 쓴다.
pub fn hostCovers(granted: []const u8, current: []const u8) bool {
    if (granted.len == 0 or current.len == 0) return false;
    if (current.len == granted.len) return std.ascii.eqlIgnoreCase(current, granted);
    if (current.len < granted.len + 1) return false;
    const tail = current[current.len - granted.len ..];
    return current[current.len - granted.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, granted);
}

/// http(s) URL 의 호스트. 다른 스킴(data:·about:·file: — 쿠키가 없다)이나 호스트 없는 URL 은 null. `control_pane_grant.hostOfUrl` 의
/// 단일 출처다.
pub fn hostOfUrl(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    const host = uri.host orelse return null;
    const raw = switch (host) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    return if (raw.len == 0) null else raw;
}

/// 두 호스트가 같은 사이트인가(어림 — 한쪽이 다른 쪽을 덮는다).
pub fn sameSite(a: []const u8, b: []const u8) bool {
    return hostCovers(a, b) or hostCovers(b, a);
}

/// grant 호스트들 중 하나가 그 주소의 호스트를 덮는가(http(s) 가 아니면 거짓).
pub fn anyCovers(hosts: []const []const u8, url: []const u8) bool {
    const h = hostOfUrl(url) orelse return false;
    for (hosts) |g| if (hostCovers(g, h)) return true;
    return false;
}

/// 사이트에 묶인 grant(`granted`)로 주 프레임 이동 하나를 보여도 되는가(W9d① 적대 리뷰 2 회차 N1) — 처음 주소와 홉마다의 대상(다음 홉·마지막
/// 응답을 보낸 곳)이 모두 덮일 때만. 마지막 주소만 보면 덮이지 않는 사이트에서 시작해 덮이는 사이트로 돌아오는 이동(OAuth·결제의 돌아오기,
/// 열린 리다이렉트)이 그 사이트의 쿠키·Set-Cookie 째 보였다. initiator 는 쓰지 않는다 — 브라우저가 시작한 이동은 「null」 이다(실측).
/// 호스트는 sidecar 가 온 주소에서 읽은 칸이다(3 회차 T1 — 잘린 주소에서 다시 읽지 않는다). 빈 호스트는 덮이지 않는다.
pub fn navigationCovered(granted: []const u8, first_host: []const u8, hop_hosts: []const []const u8) bool {
    if (!hostCovers(granted, first_host)) return false;
    for (hop_hosts) |h| if (!hostCovers(granted, h)) return false;
    return true;
}

// ── 주소 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// `scheme://` 뒤 권한 부분의 `[start, end)` — 없으면 null. 규칙은 `net_fields.authoritySpan`(codec 이 잘린 주소를 보는 것과 같은 곳).
fn authority(url: []const u8) ?struct { start: usize, end: usize } {
    const a = net_fields.authoritySpan(url) orelse return null;
    return .{ .start = a.start, .end = a.end };
}

/// 주소에 사용자 정보(`user:pass@`)가 있는가.
pub fn hasUserinfo(url: []const u8) bool {
    const a = authority(url) orelse return false;
    return std.mem.indexOfScalar(u8, url[a.start..a.end], '@') != null;
}

/// 사용자 정보를 지운 주소(`out` 에 쓴다 — 없으면 `url` 그대로). 경로·질의의 `@` 는 건드리지 않는다.
pub fn stripUserinfo(url: []const u8, out: []u8) []const u8 {
    const a = authority(url) orelse return url;
    const at = std.mem.lastIndexOfScalar(u8, url[a.start..a.end], '@') orelse return url;
    const cut_end = a.start + at + 1;
    const len = url.len - (cut_end - a.start);
    if (len > out.len) return url[0..0];
    @memcpy(out[0..a.start], url[0..a.start]);
    @memcpy(out[a.start..len], url[cut_end..]);
    return out[0..len];
}

// ── 자르기 전의 온 주소(UTF-16 — sidecar 가 CEF 의 글에서, W9d① 적대 리뷰 3 회차 T1) ─────────────────────────────────────────

/// 온 주소의 권한 부분 자리(UTF-16 단위) — `start` 는 `scheme://` 뒤, `host_start` 는 사용자 정보 뒤(없으면 `start`), `end` 는 첫 `/`·`?`·`#`
/// (없으면 끝). 스킴(글자·숫자·`+`·`-`·`.`, 32 단위까지) 뒤에 `//` 가 없으면 null(`data:`·`blob:`·`about:` — 호스트가 없다). 사용자 정보의
/// `@` 는 Chromium 이 퍼센트로 바꿔 두므로 권한 안의 마지막 `@` 가 경계다.
pub const Authority16 = struct { start: usize, host_start: usize, end: usize };

pub fn authority16(units: []const u16) ?Authority16 {
    var i: usize = 0;
    while (i < units.len and i <= 32) : (i += 1) {
        const ch = units[i];
        if (ch == ':') break;
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '+' or ch == '-' or ch == '.';
        if (!ok) return null;
    }
    if (i == 0 or i + 2 >= units.len or units[i] != ':' or units[i + 1] != '/' or units[i + 2] != '/') return null;
    const start = i + 3;
    var end = start;
    var host_start = start;
    while (end < units.len) : (end += 1) {
        const ch = units[end];
        if (ch == '/' or ch == '?' or ch == '#') break;
        if (ch == '@') host_start = end + 1;
    }
    return .{ .start = start, .host_start = host_start, .end = end };
}

/// `scheme://` 와 호스트[:포트] 를 ASCII 로 `buf` 에 잇는다(사용자 정보는 건너뛴다). ASCII 가 아니거나 넘치면 null.
fn headAscii(units: []const u16, a: Authority16, buf: []u8) ?[]const u8 {
    const n = a.start + (a.end - a.host_start);
    if (n > buf.len) return null;
    for (units[0..a.start], buf[0..a.start]) |ch, *o| {
        if (ch > 0x7e) return null;
        o.* = @intCast(ch);
    }
    for (units[a.host_start..a.end], buf[a.start..n]) |ch, *o| {
        if (ch > 0x7e) return null;
        o.* = @intCast(ch);
    }
    return buf[0..n];
}

/// 온 주소의 호스트(소문자 — `out` 에 쓴다). 잘린 글이 아니라 **온 글**에서 읽으므로 긴 사용자 정보 너머의 실제 호스트다. http(s) 가 아니거나,
/// ASCII 가 아니거나(CEF 는 punycode 로 준다), 호스트 글자 규칙(`net_fields.checkHost`)을 못 지나면 빈 글 — 빈 호스트는 아무 grant 도 덮지 않는다.
pub fn hostOfUrl16(units: []const u16, out: *[message.max_net_host_bytes]u8) []const u8 {
    const a = authority16(units) orelse return "";
    var buf: [40 + message.max_net_host_bytes + 8]u8 = undefined;
    const head = headAscii(units, a, &buf) orelse return "";
    const host = hostOfUrl(head) orelse return "";
    if (host.len > out.len) return "";
    for (host, out[0..host.len]) |ch, *o| o.* = std.ascii.toLower(ch);
    net_fields.checkHost(out[0..host.len]) catch return "";
    return out[0..host.len];
}

/// 온 주소의 출처(`scheme://host[:port]` — 사용자 정보 없이). ASCII 가 아니거나 `out` 을 넘으면 빈 글(서비스 워커를 붙이지 않는다 — 더 숨기는 쪽).
pub fn originOfUrl16(units: []const u16, out: []u8) []const u8 {
    const a = authority16(units) orelse return out[0..0];
    return headAscii(units, a, out) orelse out[0..0];
}

/// 주소의 출처(`scheme://host[:port]` — 사용자 정보 없이). `out` 에 쓴다. 스킴·권한이 없으면 빈 글.
pub fn originOf(url: []const u8, out: []u8) []const u8 {
    const a = authority(url) orelse return out[0..0];
    var host_start = a.start;
    if (std.mem.lastIndexOfScalar(u8, url[a.start..a.end], '@')) |at| host_start = a.start + at + 1;
    const scheme_len = a.start; // `scheme://`
    const len = scheme_len + (a.end - host_start);
    if (len > out.len) return out[0..0];
    @memcpy(out[0..scheme_len], url[0..scheme_len]);
    @memcpy(out[scheme_len..len], url[host_start..a.end]);
    return out[0..len];
}

// ── 헤더 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// 설정이 꺼졌을 때 헤더 하나의 값을 어떻게 보이나.
pub const HeaderRule = enum {
    /// 값을 그대로.
    value,
    /// 출처만(`Referer`).
    origin_only,
    /// 덮이는 호스트의 응답에만 값(`Location`) — 투영은 덮이는 호스트의 것만 헤더를 보이므로 결과는 `value` 와 같다.
    covered_only,
    /// 이름만(쿠키·인증·그 밖 모든 것).
    name_only,
};

const credential_names = [_][]const u8{ "cookie", "set-cookie", "authorization", "proxy-authorization" };

/// 자격 증명 헤더인가(W9d① 적대 리뷰 3 회차 D1 — 사용자 결정 2026-10-15 「쿠키 권한 있을 때만 보임」, 대소문자 무시). 사용자가 이름을 댄 것은
/// `Cookie`·`Set-Cookie`·`Authorization` 이고, 같은 갈래(프록시에 보내는 자격 증명)인 `Proxy-Authorization` 도 넣었다(작성자 — 더 숨기는 쪽).
/// 값은 읽는 쪽이 그 요청의 호스트를 덮는 `browser_storage` grant 를 쥘 때만 보인다 — 설정이 켜져 있어도(maru 가 투영한다).
pub fn credentialHeader(name: []const u8) bool {
    for (credential_names) |c| if (std.ascii.eqlIgnoreCase(name, c)) return true;
    return false;
}

const allow_exact = [_][]const u8{ "content-type", "content-length", "content-encoding", "cache-control", "etag", "last-modified", "expires", "age", "vary", "user-agent" };
const allow_prefix = [_][]const u8{ "accept", "sec-fetch-", "access-control-" };

/// 허용 목록(docs/plans/web-osr-backend.md 「W9d① 결정」 — 사용자 결정 2026-10-15 의 꺼짐 쪽): content-type·length·encoding, cache-control,
/// etag, last-modified, expires, age, vary, accept*, sec-fetch-*, access-control-*, user-agent 는 값, Referer 는 출처만, Location 은 덮이는
/// 호스트에만, 나머지(Cookie·Set-Cookie·Authorization 등)는 이름만.
pub fn headerRule(name: []const u8) HeaderRule {
    if (std.ascii.eqlIgnoreCase(name, "referer")) return .origin_only;
    if (std.ascii.eqlIgnoreCase(name, "location")) return .covered_only;
    for (allow_exact) |a| if (std.ascii.eqlIgnoreCase(name, a)) return .value;
    for (allow_prefix) |p| if (name.len >= p.len and std.ascii.eqlIgnoreCase(name[0..p.len], p)) return .value;
    return .name_only;
}

/// 설정이 꺼졌을 때의 헤더 덩어리를 만든다 — 덮이지 않는 호스트면 아무것도 싣지 않고, 덮이면 규칙대로(이름만인 것은 빈 값). sidecar 가
/// 보내기 전에, maru 가 읽을 때 같은 함수를 쓴다.
pub fn stripHeaders(src: message.NetHeaderBlock, covered: bool, out: *net_fields.HeaderBuilder) void {
    if (!covered) return;
    var it = net_fields.HeaderIterator.init(src);
    var ob: [message.max_net_url_bytes]u8 = undefined;
    var mb: [message.max_net_headers_bytes]u8 = undefined;
    while (it.next()) |h| {
        _ = switch (headerRule(h.name)) {
            // 끔: 주소를 싣는 헤더(`Location`)의 사용자 정보는 쿠키 권한과 무관하게 지운다(4 회차 C1 — 주소 칸과 같다).
            .value, .covered_only => out.add(h.name, maskHeaderUserinfo(h.name, h.value, "", &mb)),
            .origin_only => out.add(h.name, originOf(h.value, &ob)),
            .name_only => out.add(h.name, ""),
        };
    }
}

// ── 주소를 싣는 헤더의 사용자 정보(W9d① 적대 리뷰 4 회차 C1) ─────────────────────────────────────────────────────

/// 값에 주소(들)를 싣는 헤더인가(대소문자 무시 — 목록은 `net_fields.urlValueHeader`: 덩어리를 만들 때 그 값을 자르지 않는 쪽과 같은 곳). 사용자가
/// 이름을 댄 것은 `Location`·`Refresh`·`Content-Location`·`Link` 이고, 요청의 `Referer` 도 넣었다(작성자 — Chromium 은 사용자 정보를 싣지 않지만 같은
/// 갈래라 같은 규칙으로). 그 밖의 헤더 값은 서버가 무엇이든 실을 수 있지만 주소 자리가 정해져 있지 않다 — 설정 켬의 「헤더 값은 다 보임」(사용자
/// 결정) 그대로다(문서에 남은 틈으로 적었다).
pub fn urlHeader(name: []const u8) bool {
    return net_fields.urlValueHeader(name);
}

/// Chromium(GURL·WHATWG URL)이 `\` 를 `/` 로 읽고 `//` 없이도 권한으로 읽는 「특별한」 스킴.
fn specialScheme(scheme: []const u8) bool {
    for ([_][]const u8{ "http", "https", "ws", "wss", "ftp", "file" }) |sp| if (std.ascii.eqlIgnoreCase(scheme, sp)) return true;
    return false;
}

fn schemeChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.';
}

/// `value[at..]` 에서 시작하는 권한의 시작 자리와 `\` 가 권한을 끝내는지 — 아니면 null. 두 갈래:
///   - `스킴:` 뒤 — 특별한 스킴이면 `/`·`\` 가 몇 개든(없어도 — `http:u:p@x`), 아니면 `//` 둘 이상일 때만.
///   - 스킴 없는 `//`(·`\\`) — 값의 처음이거나 구분 글자(공백·`<`·`"`·`'`·`=`·`,`·`;`·`(`) 뒤일 때(문서의 바탕 주소는 http(s) — 특별하다).
/// `/`·`\` 사이의 공백·탭도 건너뛴다 — URL 파서는 탭·줄바꿈을 지우는데 헤더 값에는 탭이 그대로 오고 줄바꿈은 sidecar 가 공백으로 바꿔 싣는다
/// (`http:/<탭>/u:p@x`).
fn authorityStart(value: []const u8, at: usize) ?struct { start: usize, special: bool } {
    const ch = value[at];
    if (std.ascii.isAlphabetic(ch) and (at == 0 or !schemeChar(value[at - 1]))) {
        var j = at;
        while (j < value.len and schemeChar(value[j]) and j - at <= 32) j += 1;
        if (j >= value.len or value[j] != ':') return null;
        const special = specialScheme(value[at..j]);
        var k = j + 1;
        var slashes: usize = 0;
        while (k < value.len and (value[k] == '/' or value[k] == '\\' or value[k] == ' ' or value[k] == '\t')) : (k += 1) {
            if (value[k] != ' ') slashes += 1;
        }
        if (special or slashes >= 2) return .{ .start = k, .special = special };
        return null;
    }
    if ((ch == '/' or ch == '\\') and at + 1 < value.len and (value[at + 1] == '/' or value[at + 1] == '\\')) {
        if (at != 0 and std.mem.indexOfScalar(u8, " \t<\"'=,;(", value[at - 1]) == null) return null;
        var k = at;
        while (k < value.len and (value[k] == '/' or value[k] == '\\' or value[k] == ' ' or value[k] == '\t')) k += 1;
        return .{ .start = k, .special = true };
    }
    return null;
}

/// 사용자 정보 뒤 호스트(포트 없이 — IPv6 는 `[...]` 째).
fn hostAfterUserinfo(host_port: []const u8) []const u8 {
    if (host_port.len > 0 and host_port[0] == '[') {
        const e = std.mem.indexOfScalar(u8, host_port, ']') orelse return host_port;
        return host_port[0 .. e + 1];
    }
    return host_port[0 .. std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len];
}

/// 주소를 싣는 헤더(`urlHeader`) 값 안 주소들의 사용자 정보(`user:pass@`)를 지운다 — 그 주소의 호스트를 `cookie_host`(읽는 쪽의
/// `browser_storage` grant 호스트, 비면 아무것도)가 덮으면 둔다(D1 의 주소 규칙과 같다). 다른 헤더·사용자 정보 없는 값은 `value` 그대로,
/// 지웠으면 `out` 에 쓴 것. 서버가 고른 글이라 GURL 보다 너그럽게 찾는다(더 지우는 쪽): 권한은 `/`·`?`·`#`(특별한 스킴이면 `\` 도,
/// `Link` 의 `<…>` 안이면 `>` 도)까지이고 그 안의 마지막 `@` 까지가 사용자 정보다 — 공백·`,` 에서 멈추지 않는다(사용자 정보 안의 공백은
/// GURL 이 퍼센트로 바꿔 받아들인다). `out` 이 모자라면(오지 않는다 — 덩어리 상한과 같다) 빈 값.
pub fn maskHeaderUserinfo(name: []const u8, value: []const u8, cookie_host: []const u8, out: []u8) []const u8 {
    if (!urlHeader(name) or std.mem.indexOfScalar(u8, value, '@') == null) return value;
    const link = std.ascii.eqlIgnoreCase(name, "link");
    var w: usize = 0; // `out` 에 쓴 길이
    var copied: usize = 0; // `value` 에서 옮긴 데까지
    var changed = false;
    var i: usize = 0;
    while (i < value.len) {
        const a = authorityStart(value, i) orelse {
            i += 1;
            continue;
        };
        var end = a.start;
        while (end < value.len) : (end += 1) {
            const ch = value[end];
            if (ch == '/' or ch == '?' or ch == '#') break;
            if (ch == '\\' and a.special) break;
            if (ch == '>' and link) break;
        }
        if (std.mem.lastIndexOfScalar(u8, value[a.start..end], '@')) |at_rel| {
            const at = a.start + at_rel;
            if (!hostCovers(cookie_host, hostAfterUserinfo(value[at + 1 .. end]))) {
                const keep = value[copied..a.start];
                if (w + keep.len > out.len) return out[0..0];
                @memcpy(out[w..][0..keep.len], keep);
                w += keep.len;
                copied = at + 1;
                changed = true;
            }
        }
        i = @max(end, i + 1);
    }
    if (!changed) return value;
    const rest = value[copied..];
    if (w + rest.len > out.len) return out[0..0];
    @memcpy(out[w..][0..rest.len], rest);
    return out[0 .. w + rest.len];
}

// ── 자원 종류 ────────────────────────────────────────────────────────────────────────────────────────────

/// CEF `cef_resource_type_t` 를 에이전트에게 보일 이름으로(DevTools 의 이름에 가깝게 — fetch 와 XHR 은 CEF 가 가르지 않아 `xhr` 하나).
pub fn resourceTypeName(rt: u8) []const u8 {
    return switch (rt) {
        0 => "document",
        1 => "iframe",
        2 => "stylesheet",
        3 => "script",
        4 => "image",
        5 => "font",
        6 => "other",
        7 => "object",
        8 => "media",
        9 => "worker",
        10 => "shared_worker",
        11 => "prefetch",
        12 => "favicon",
        13 => "xhr",
        14 => "ping",
        15 => "service_worker",
        16 => "csp_report",
        17 => "plugin",
        19, 20 => "preload",
        else => "other",
    };
}

/// 이름이 아는 종류인가(필터 인자 검사 — `browser.network {types}`).
pub fn knownTypeName(name: []const u8) bool {
    var rt: u8 = 0;
    while (rt <= message.max_net_resource_type) : (rt += 1) {
        if (std.mem.eql(u8, resourceTypeName(rt), name)) return true;
    }
    return false;
}

// ── 요청의 갈래 ──────────────────────────────────────────────────────────────────────────────────────────

/// 다른 사이트 iframe 의 요청인가 — 하위 프레임에서 났고, 그 프레임이 첫 사이트와 같은 사이트가 아니다. 무엇으로 가르나(CEF 154 실측 —
/// W9d① 판정 `net-attribution`):
///   - iframe 문서를 부르는 요청(`iframe` 종류)은 initiator 가 「null」 로 온다 — 그 문서 주소의 호스트로 가른다(다른 사이트 iframe 의 문서는
///     그 iframe 의 것으로 친다).
///   - iframe 안의 요청은 initiator 가 iframe 출처다. 다른 사이트 문맥이면 쿠키의 첫 사이트가 비어 온다 — 빈 첫 사이트는 다른 사이트로 친다.
/// iframe 문서의 호스트는 sidecar 가 온 주소에서 읽은 칸(`url_host` — 3 회차 T1)이다. 빈 호스트·불투명 출처는 다른 사이트로 친다(더 숨기는 쪽).
pub fn crossSiteIframe(flags: message.NetFlags, resource_type: u8, url_host: []const u8, initiator: []const u8, site: []const u8) bool {
    if (!flags.subframe) return false;
    if (site.len == 0) return true;
    const frame_host = if (resource_type == 1) url_host else hostOfUrl(initiator) orelse ""; // 불투명 출처(sandbox iframe 등)
    if (frame_host.len == 0) return true;
    return !sameSite(frame_host, site);
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d①: hostCovers 는 점 경계로 하위 도메인만 덮는다(grant 와 같은 규칙), sameSite 는 어느 쪽이든 덮으면" {
    try testing.expect(hostCovers("github.com", "gist.github.com"));
    try testing.expect(!hostCovers("github.com", "evilgithub.com"));
    try testing.expect(!hostCovers("mail.google.com", "google.com"));
    try testing.expect(!hostCovers("", "a"));
    try testing.expect(sameSite("google.com", "mail.google.com"));
    try testing.expect(sameSite("mail.google.com", "google.com"));
    try testing.expect(!sameSite("www.a.com", "api.a.com"));
    try testing.expect(anyCovers(&.{ "x.test", "a.test" }, "https://www.a.test:8443/p"));
    try testing.expect(!anyCovers(&.{"a.test"}, "data:text/plain,a.test"));
}

test "W9d① 적대 리뷰 2 회차 N1: 주 프레임 이동은 처음 주소와 홉의 대상이 모두 덮일 때만 — 덮이지 않는 곳에서 시작해 돌아오는 이동은 아니다" {
    try testing.expect(navigationCovered("a.test", "a.test", &.{}));
    try testing.expect(navigationCovered("a.test", "a.test", &.{ "www.a.test", "a.test" }));
    try testing.expect(!navigationCovered("a.test", "bank.test", &.{"a.test"}));
    try testing.expect(!navigationCovered("a.test", "a.test", &.{ "idp.test", "a.test" }));
    try testing.expect(!navigationCovered("a.test", "a.test", &.{"bank.test"}));
    try testing.expect(!navigationCovered("", "a.test", &.{}));
    try testing.expect(!navigationCovered("a.test", "", &.{})); // 호스트를 모른다(3 회차 T1 — sidecar 가 못 읽었다) — 덮이지 않는다
    try testing.expect(!navigationCovered("a.test", "a.test", &.{""}));
}

fn units16(comptime text: []const u8) [text.len]u16 {
    var out: [text.len]u16 = undefined;
    for (text, &out) |ch, *o| o.* = ch;
    return out;
}

test "W9d① 적대 리뷰 3 회차 T1: 온 주소(UTF-16)의 호스트는 사용자 정보 너머의 실제 호스트다 — 2 KiB 에서 잘리는 긴 사용자 정보여도, 소문자, 모르면 빈 글" {
    var hb: [message.max_net_host_bytes]u8 = undefined;
    // 리뷰의 꼴: `https://<y…>.a.test<…>@bank.test/` — 앞 2 KiB 만 보면 `…a.test` 가 호스트로 읽혔다.
    const pad = comptime array_repeat.repeat("y", (message.max_net_url_bytes - "https://".len - ".a.test".len));
    const long = units16("https://" ++ pad ++ ".a.testzzzzzzzz@Bank.Test:8443/home?x=1");
    try testing.expectEqualStrings("bank.test", hostOfUrl16(&long, &hb));
    // 잘린 글이 속이던 꼴(대조) — Zig 0.16 의 `std.Uri` 는 이 글의 호스트를 `….a.test` 로 읽었다. 0.17 은 254 바이트를 넘는 호스트를
    // 거절해 호스트가 안 나온다 — 어느 쪽이든 잘린 글에서는 은행이 안 나온다.
    try testing.expect(hostOfUrl("https://" ++ pad ++ ".a.test") == null);
    try testing.expectEqualStrings("evil.io", hostOfUrl16(&units16("http://github.com@evil.io/"), &hb));
    try testing.expectEqualStrings("a.test", hostOfUrl16(&units16("https://u:p@a.test"), &hb));
    try testing.expectEqualStrings("127.0.0.1", hostOfUrl16(&units16("http://127.0.0.1:9/a@b"), &hb));
    try testing.expectEqualStrings("[::1]", hostOfUrl16(&units16("http://[::1]:8080/"), &hb));
    for ([_][]const u8{ "data:text/html,https://a.test/", "about:blank", "blob:https://a.test/uuid", "file:///etc/hosts", "", "https://", "ftp://a.test/" }) |u| {
        var buf: [64]u16 = undefined;
        for (u, buf[0..u.len]) |ch, *o| o.* = ch;
        try testing.expectEqualStrings("", hostOfUrl16(buf[0..u.len], &hb));
    }
    // ASCII 가 아닌 호스트(CEF 는 punycode 로 준다 — 오면 모른다)·호스트 글자 밖은 빈 글.
    const uni = [_]u16{ 'h', 't', 't', 'p', ':', '/', '/', 0xD55C, '.', 't', 'e', 's', 't', '/' };
    try testing.expectEqualStrings("", hostOfUrl16(&uni, &hb));
    try testing.expectEqualStrings("", hostOfUrl16(&units16("https://a%2e.test/"), &hb));
    // 출처도 사용자 정보 없이, 넘치면 빈 글.
    var ob: [64]u8 = undefined;
    try testing.expectEqualStrings("https://bank.test:8443", originOfUrl16(&units16("https://u:p@bank.test:8443/x"), &ob));
    try testing.expectEqualStrings("https://Bank.Test:8443", originOfUrl16(&long, &ob)); // 사용자 정보 2 KiB 너머
    var small: [12]u8 = undefined;
    try testing.expectEqualStrings("", originOfUrl16(&long, &small));
}

test "W9d① 적대 리뷰 3 회차 D1: 자격 증명 헤더 — Cookie·Set-Cookie·Authorization·Proxy-Authorization(대소문자 무시), 그 밖은 아니다" {
    for ([_][]const u8{ "Cookie", "set-cookie", "AUTHORIZATION", "Proxy-Authorization" }) |n| try testing.expect(credentialHeader(n));
    for ([_][]const u8{ "Cookie2x", "X-Auth-Token", "Content-Type", "Referer", "WWW-Authenticate" }) |n| try testing.expect(!credentialHeader(n));
}

test "W9d①: 사용자 정보 지우기 — 권한 안의 마지막 @ 까지, 경로의 @ 는 그대로, 출처는 사용자 정보 없이" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("https://example.com/a@b", stripUserinfo("https://user:pass@example.com/a@b", &buf));
    try testing.expectEqualStrings("https://example.com/a@b", stripUserinfo("https://example.com/a@b", &buf));
    try testing.expectEqualStrings("http://evil.io/", stripUserinfo("http://github.com@evil.io/", &buf));
    try testing.expect(hasUserinfo("http://u:p@h/"));
    try testing.expect(!hasUserinfo("http://h/u@p"));
    // 스킴 뒤에 `//` 가 없는 주소 안의 `://` 는 권한이 아니다(3 회차 — sidecar 의 온 주소 규칙과 같게).
    try testing.expectEqualStrings("data:text/html,https://u:p@x/", stripUserinfo("data:text/html,https://u:p@x/", &buf));
    try testing.expect(!hasUserinfo("blob:https://u@x/1"));
    try testing.expect(!hasUserinfo("news:abc@x.test"));
    var ob: [256]u8 = undefined;
    try testing.expectEqualStrings("https://example.com:8443", originOf("https://u:p@example.com:8443/path?q#f", &ob));
    try testing.expectEqualStrings("", originOf("not a url", &ob));
}

test "W9d①: 헤더 규칙 — 허용 목록은 값, Referer 는 출처만, Location 은 덮이는 곳만, 쿠키·인증은 이름만(대소문자 무시, 접두 규칙)" {
    try testing.expectEqual(HeaderRule.value, headerRule("Content-Type"));
    try testing.expectEqual(HeaderRule.value, headerRule("accept-language"));
    try testing.expectEqual(HeaderRule.value, headerRule("Sec-Fetch-Site"));
    try testing.expectEqual(HeaderRule.value, headerRule("Access-Control-Allow-Origin"));
    try testing.expectEqual(HeaderRule.value, headerRule("User-Agent"));
    try testing.expectEqual(HeaderRule.origin_only, headerRule("Referer"));
    try testing.expectEqual(HeaderRule.covered_only, headerRule("location"));
    for ([_][]const u8{ "Cookie", "Set-Cookie", "Authorization", "X-Api-Key", "Proxy-Authorization", "sec-ch-ua", "x-accept" }) |n|
        try testing.expectEqual(HeaderRule.name_only, headerRule(n));
}

test "W9d①: stripHeaders — 덮이지 않으면 비우고, 덮이면 규칙대로 값·출처·빈 값" {
    var src: net_fields.HeaderBuilder = .{};
    _ = src.add("Cookie", "sid=secret");
    _ = src.add("Referer", "https://u:p@a.test/path?token=1");
    _ = src.add("Accept", "*/*");
    var out: net_fields.HeaderBuilder = .{};
    stripHeaders(src.block(), true, &out);
    try net_fields.checkHeaders(out.block());
    var it = net_fields.HeaderIterator.init(out.block());
    const c = it.next().?;
    try testing.expectEqualStrings("Cookie", c.name);
    try testing.expectEqualStrings("", c.value);
    try testing.expectEqualStrings("https://a.test", it.next().?.value);
    try testing.expectEqualStrings("*/*", it.next().?.value);
    var none: net_fields.HeaderBuilder = .{};
    stripHeaders(src.block(), false, &none);
    try testing.expectEqual(@as(u8, 0), none.count);
}

test "W9d①: 다른 사이트 iframe — 하위 프레임이고 그 프레임(문서면 주소, 아니면 initiator)이 첫 사이트와 다른 사이트이거나 첫 사이트가 비었을 때만" {
    const sub: message.NetFlags = .{ .subframe = true };
    try testing.expect(crossSiteIframe(sub, 13, "localhost", "http://localhost:3000", "")); // 실측 꼴 — 첫 사이트가 비었다
    try testing.expect(crossSiteIframe(sub, 13, "x", "http://localhost:3000", "127.0.0.1"));
    try testing.expect(!crossSiteIframe(sub, 13, "cdn.a.test", "https://cdn.a.test", "a.test"));
    try testing.expect(crossSiteIframe(sub, 1, "localhost", "null", "127.0.0.1")); // iframe 문서 — 주소의 호스트로
    try testing.expect(!crossSiteIframe(sub, 1, "a.test", "null", "a.test")); // 같은 사이트 iframe 문서
    try testing.expect(crossSiteIframe(sub, 1, "", "null", "a.test")); // 호스트를 모르는 iframe 문서(3 회차 T1) — 다른 사이트로
    try testing.expect(!crossSiteIframe(.{ .main_frame = true }, 13, "x", "http://localhost:3000", "127.0.0.1"));
    try testing.expect(crossSiteIframe(sub, 13, "x", "null", "a.test")); // 불투명 출처
    try testing.expect(!crossSiteIframe(.{}, 13, "x", "http://x.test", "a.test")); // worker — 프레임 없음
}

test "W9d① 적대 리뷰 4 회차 C1: 주소를 싣는 헤더의 사용자 정보 지우기 — 그 주소의 호스트를 쿠키 권한이 덮으면 둔다, GURL 이 권한으로 읽는 꼴(대소문자·역슬래시·스킴 상대·슬래시 없는 특별한 스킴·탭 자리 공백)도, 경로·질의의 @ 는 그대로" {
    var b: [512]u8 = undefined;
    const Case = struct { name: []const u8, in: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .name = "Location", .in = "https://u:p@b.test/next", .want = "https://b.test/next" },
        .{ .name = "location", .in = "HTTPS://u:p@B.Test:8443/x?y=1", .want = "HTTPS://B.Test:8443/x?y=1" },
        .{ .name = "Location", .in = "//u:p@b.test/x", .want = "//b.test/x" },
        .{ .name = "Location", .in = "https:\\\\u:p@b.test\\x", .want = "https:\\\\b.test\\x" },
        .{ .name = "Location", .in = "http:u:p@b.test/x", .want = "http:b.test/x" },
        .{ .name = "Location", .in = "http:/ /u:p@b.test/", .want = "http:/ /b.test/" }, // sidecar 가 줄바꿈을 공백으로 바꿨다
        .{ .name = "Location", .in = "http:/\t/u:p@b.test/", .want = "http:/\t/b.test/" }, // 탭은 그대로 온다(URL 파서는 지운다)
        .{ .name = "Location", .in = "https://u@v@b.test/", .want = "https://b.test/" }, // 마지막 @ 까지
        .{ .name = "Location", .in = "https://us er:p w@b.test/", .want = "https://b.test/" }, // 사용자 정보 안의 공백
        .{ .name = "Location", .in = "https://[::1]@b.test/", .want = "https://b.test/" },
        .{ .name = "Location", .in = "ftp+x://u:p@b.test/", .want = "ftp+x://b.test/" }, // 특별하지 않은 스킴도 // 면
        .{ .name = "Refresh", .in = "0; url=https://u:p@b.test/r", .want = "0; url=https://b.test/r" },
        .{ .name = "Refresh", .in = "5;URL='//u:p@b.test/r'", .want = "5;URL='//b.test/r'" },
        .{ .name = "Content-Location", .in = "https://u:p@b.test/c", .want = "https://b.test/c" },
        .{ .name = "Link", .in = "<https://u:p@b.test>; rel=preload, <https://a@c.test/2>; rel=next", .want = "<https://b.test>; rel=preload, <https://c.test/2>; rel=next" },
        .{ .name = "Referer", .in = "https://u:p@b.test/", .want = "https://b.test/" },
        // 그대로 두는 것: 경로·질의의 @, 권한 없는 스킴, 사용자 정보 없는 값, 주소를 싣지 않는 헤더.
        .{ .name = "Location", .in = "https://b.test/@user?to=a@b.test#x@y", .want = "https://b.test/@user?to=a@b.test#x@y" },
        .{ .name = "Location", .in = "/path/@me", .want = "/path/@me" },
        .{ .name = "Location", .in = "mailto:a@b.test", .want = "mailto:a@b.test" },
        .{ .name = "Link", .in = "</@scope/pkg.js>; rel=preload", .want = "</@scope/pkg.js>; rel=preload" },
        .{ .name = "X-Note", .in = "https://u:p@b.test/", .want = "https://u:p@b.test/" },
    }) |c| try testing.expectEqualStrings(c.want, maskHeaderUserinfo(c.name, c.in, "", &b));
    // 쿠키 권한이 그 주소의 호스트를 덮으면 둔다 — 덮지 않는 주소의 것만 지운다(한 값 안에서도 주소마다).
    try testing.expectEqualStrings("https://u:p@b.test/", maskHeaderUserinfo("Location", "https://u:p@b.test/", "b.test", &b));
    try testing.expectEqualStrings("https://u:p@www.b.test/", maskHeaderUserinfo("Location", "https://u:p@www.b.test/", "b.test", &b));
    try testing.expectEqualStrings("https://b.test./", maskHeaderUserinfo("Location", "https://u:p@b.test./", "b.test", &b)); // 끝의 점 — 덮지 않는 쪽으로
    try testing.expectEqualStrings("https://a.test/", maskHeaderUserinfo("Location", "https://u:p@a.test/", "b.test", &b));
    try testing.expectEqualStrings("<https://u@b.test/1>, <https://c.test/2>", maskHeaderUserinfo("Link", "<https://u@b.test/1>, <https://v@c.test/2>", "b.test", &b));
    // 끔(stripHeaders): Location 은 사용자 정보만 지운 값, 그 밖의 주소 헤더는 허용 목록 밖이라 이름만.
    var src: net_fields.HeaderBuilder = .{};
    _ = src.add("Location", "https://u:p@b.test/next");
    _ = src.add("Link", "<https://u:p@b.test/l>");
    var off: net_fields.HeaderBuilder = .{};
    stripHeaders(src.block(), true, &off);
    var it = net_fields.HeaderIterator.init(off.block());
    try testing.expectEqualStrings("https://b.test/next", it.next().?.value);
    try testing.expectEqualStrings("", it.next().?.value);
}

test "W9d① 적대 리뷰 4 회차 재현 C1(잘림): 덩어리 상한(8 KiB)에서 잘리는 주소 헤더는 앞부분을 싣지 않는다 — 사용자 정보 안에서 끊기면 `@` 가 없어 가리기가 알아보지 못한다" {
    var b: net_fields.HeaderBuilder = .{};
    _ = b.add("X-Fill", array_repeat.repeat("f", 7800));
    _ = b.add("Location", "http://" ++ array_repeat.repeat("u", 1000) ++ ":SECRETPW@b.test/");
    _ = b.add("X-Other", array_repeat.repeat("o", 1000));
    try testing.expect(b.truncated);
    try net_fields.checkHeaders(b.block());
    var it = net_fields.HeaderIterator.init(b.block());
    _ = it.next().?;
    const loc = it.next().?;
    try testing.expectEqualStrings("Location", loc.name);
    var mb: [message.max_net_headers_bytes]u8 = undefined;
    const shown = maskHeaderUserinfo("Location", loc.value, "", &mb);
    try testing.expect(std.mem.indexOf(u8, shown, "uuuu") == null); // 사용자 정보 조각이 남지 않는다
    // 주소를 싣지 않는 헤더는 그대로 앞부분만(「…」).
    if (it.next()) |o| try testing.expect(std.mem.startsWith(u8, o.value, "ooo"));
}

test "W9d①: 자원 종류 이름 — CEF 의 0..20 을 덮고, 필터 이름 검사" {
    try testing.expectEqualStrings("document", resourceTypeName(0));
    try testing.expectEqualStrings("xhr", resourceTypeName(13));
    try testing.expect(knownTypeName("xhr"));
    try testing.expect(knownTypeName("iframe"));
    try testing.expect(!knownTypeName("fetch"));
}
