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
//! 시험이 증명하는 것: 호스트 덮기의 점 경계, 사용자 정보 지우기(경로의 `@` 는 그대로), 출처만 남기기, 헤더 규칙(접두 규칙 `accept*`·
//! `sec-fetch-*`·`access-control-*` 포함, 대소문자 무시), 다른 사이트 iframe 판정, 덜어 낸 덩어리의 모양. 브라우저 탭에서 중요한 이유 —
//! 요청 헤더에는 로그인 쿠키와 인증 토큰이 그대로 들어 있다.

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
pub fn navigationCovered(granted: []const u8, first_url: []const u8, hop_urls: []const []const u8) bool {
    const one = [_][]const u8{granted};
    if (!anyCovers(&one, first_url)) return false;
    for (hop_urls) |u| if (!anyCovers(&one, u)) return false;
    return true;
}

// ── 주소 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// `scheme://` 뒤 권한 부분의 `[start, end)` — 없으면 null.
fn authority(url: []const u8) ?struct { start: usize, end: usize } {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const start = sep + 3;
    const end = start + (std.mem.indexOfAny(u8, url[start..], "/?#") orelse url.len - start);
    return .{ .start = start, .end = end };
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
    while (it.next()) |h| {
        _ = switch (headerRule(h.name)) {
            .value, .covered_only => out.add(h.name, h.value),
            .origin_only => out.add(h.name, originOf(h.value, &ob)),
            .name_only => out.add(h.name, ""),
        };
    }
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
pub fn crossSiteIframe(flags: message.NetFlags, resource_type: u8, url: []const u8, initiator: []const u8, site: []const u8) bool {
    if (!flags.subframe) return false;
    if (site.len == 0) return true;
    const frame_host = (if (resource_type == 1) hostOfUrl(url) else hostOfUrl(initiator)) orelse return true; // 불투명 출처(sandbox iframe 등)
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
    try testing.expect(navigationCovered("a.test", "https://a.test/login", &.{}));
    try testing.expect(navigationCovered("a.test", "https://a.test/go", &.{ "https://www.a.test/x", "https://a.test/cb" }));
    try testing.expect(!navigationCovered("a.test", "https://bank.test/sso?return=https://a.test/cb", &.{"https://a.test/cb"}));
    try testing.expect(!navigationCovered("a.test", "https://a.test/go", &.{ "https://idp.test/auth", "https://a.test/cb" }));
    try testing.expect(!navigationCovered("a.test", "https://a.test/go", &.{"https://bank.test/"}));
    try testing.expect(!navigationCovered("", "https://a.test/", &.{}));
}

test "W9d①: 사용자 정보 지우기 — 권한 안의 마지막 @ 까지, 경로의 @ 는 그대로, 출처는 사용자 정보 없이" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("https://example.com/a@b", stripUserinfo("https://user:pass@example.com/a@b", &buf));
    try testing.expectEqualStrings("https://example.com/a@b", stripUserinfo("https://example.com/a@b", &buf));
    try testing.expectEqualStrings("http://evil.io/", stripUserinfo("http://github.com@evil.io/", &buf));
    try testing.expect(hasUserinfo("http://u:p@h/"));
    try testing.expect(!hasUserinfo("http://h/u@p"));
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
    try testing.expect(crossSiteIframe(sub, 13, "http://localhost:3000/api", "http://localhost:3000", "")); // 실측 꼴 — 첫 사이트가 비었다
    try testing.expect(crossSiteIframe(sub, 13, "http://x/", "http://localhost:3000", "127.0.0.1"));
    try testing.expect(!crossSiteIframe(sub, 13, "https://cdn.a.test/x", "https://cdn.a.test", "a.test"));
    try testing.expect(crossSiteIframe(sub, 1, "http://localhost:3000/frame", "null", "127.0.0.1")); // iframe 문서 — 주소로
    try testing.expect(!crossSiteIframe(sub, 1, "https://a.test/frame", "null", "a.test")); // 같은 사이트 iframe 문서
    try testing.expect(!crossSiteIframe(.{ .main_frame = true }, 13, "http://x/", "http://localhost:3000", "127.0.0.1"));
    try testing.expect(crossSiteIframe(sub, 13, "http://x/", "null", "a.test")); // 불투명 출처
    try testing.expect(!crossSiteIframe(.{}, 13, "http://x/", "http://x.test", "a.test")); // worker — 프레임 없음
}

test "W9d①: 자원 종류 이름 — CEF 의 0..20 을 덮고, 필터 이름 검사" {
    try testing.expectEqualStrings("document", resourceTypeName(0));
    try testing.expectEqualStrings("xhr", resourceTypeName(13));
    try testing.expect(knownTypeName("xhr"));
    try testing.expect(knownTypeName("iframe"));
    try testing.expect(!knownTypeName("fetch"));
}
