//! Chromium 탭 우클릭 메뉴의 「…에서 '…' 검색」(W6h① — L2 순수). 검색 주소 틀은 설정 `browser.search-url` 이고(사용자 결정
//! 2026-10-05 — 기본 Google), `%s` 자리에 선택한 글을 퍼센트 인코딩해 넣는다. 결과는 새 탭(앞)으로 연다 — Chrome 과 같다.
//!
//! 틀은 http·https 이고 `%s` 가 꼭 하나 있어야 쓴다(`javascript:`·`file:` 같은 틀로 페이지 글을 실행·열지 않게). 아니면 기본 틀을
//! 쓴다. 메뉴 문구의 엔진 이름은 틀의 호스트에서 정한다(잘 알려진 엔진은 그 이름, 아니면 `www.` 를 뺀 호스트).

const std = @import("std");
const web_sidecar = @import("web_sidecar/root.zig");

pub const default_template = "https://www.google.com/search?q=%s";

/// 검색 주소 상한 — sidecar 로 가는 주소 상한과 같다. 넘으면 선택한 글을 글자 경계에서 줄인다.
pub const max_url_bytes = web_sidecar.wire.max_url_bytes;

/// 쓸 수 있는 틀인가 — http·https, 호스트가 있고, `%s` 가 꼭 하나(주소의 호스트 부분에는 없다), 호스트 부분에 사용자 정보(`@`)가
/// 없고, 제어 문자·빈칸 없음. 사용자 정보를 받지 않는 것은 메뉴 문구의 엔진 이름과 실제로 가는 곳이 갈리지 않게다(W6h① 적대 검증).
pub fn validTemplate(template: []const u8) bool {
    if (template.len == 0 or template.len > max_url_bytes) return false;
    const sep = std.mem.indexOf(u8, template, "://") orelse return false;
    const scheme = template[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    for (template) |b| if (b <= 0x20 or b == 0x7f) return false;
    const authority = authorityOf(template) orelse return false;
    if (std.mem.indexOf(u8, authority, "%s") != null or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    const host = hostOf(template) orelse return false;
    if (host.len == 0) return false;
    return std.mem.count(u8, template, "%s") == 1;
}

/// 쓸 틀 — 설정이 쓸 수 없으면 기본 틀.
pub fn effectiveTemplate(configured: []const u8) []const u8 {
    return if (validTemplate(configured)) configured else default_template;
}

/// `://` 뒤 첫 `/`·`?`·`#`·`\` 앞까지(브라우저는 http·https 의 `\` 를 `/` 로 읽는다).
fn authorityOf(template: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, template, "://") orelse return null;
    const rest = template[sep + 3 ..];
    return rest[0 .. std.mem.indexOfAny(u8, rest, "/?#\\") orelse rest.len];
}

/// 호스트 — 포트를 떼고, IPv6 는 `[…]` 그대로.
fn hostOf(template: []const u8) ?[]const u8 {
    const authority = authorityOf(template) orelse return null;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return authority[0 .. close + 1];
    }
    return authority[0 .. std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len];
}

const Known = struct { domain: []const u8, name: []const u8 };
/// 잘 알려진 엔진 — 호스트(앞의 `www.`·`search.` 를 뗀 것)가 이 도메인과 **똑같을 때만**(`google.evil.example` 은 Google 이 아니다).
const known = [_]Known{
    .{ .domain = "google.com", .name = "Google" },
    .{ .domain = "google.co.kr", .name = "Google" },
    .{ .domain = "google.co.jp", .name = "Google" },
    .{ .domain = "google.co.uk", .name = "Google" },
    .{ .domain = "bing.com", .name = "Bing" },
    .{ .domain = "duckduckgo.com", .name = "DuckDuckGo" },
    .{ .domain = "naver.com", .name = "NAVER" },
    .{ .domain = "daum.net", .name = "Daum" },
    .{ .domain = "yahoo.com", .name = "Yahoo!" },
    .{ .domain = "yahoo.co.jp", .name = "Yahoo!" },
    .{ .domain = "ecosia.org", .name = "Ecosia" },
    .{ .domain = "brave.com", .name = "Brave" },
    .{ .domain = "kagi.com", .name = "Kagi" },
};

/// 엔진 이름 상한(바이트) — 메뉴 문구가 선택한 글을 밀어내지 않게. 호스트는 ASCII 다(제어 문자·빈칸이 없는 틀만 쓴다).
pub const max_engine_name_bytes = 64;

/// 메뉴 문구의 엔진 이름 — 잘 알려진 엔진이면 그 이름, 아니면 `www.` 를 뗀 호스트(`max_engine_name_bytes` 에서 자른다).
pub fn engineName(template: []const u8) []const u8 {
    var host = hostOf(effectiveTemplate(template)) orelse return "Google";
    if (host.len > 4 and std.ascii.startsWithIgnoreCase(host, "www.")) host = host[4..];
    const bare = if (host.len > 7 and std.ascii.startsWithIgnoreCase(host, "search.")) host[7..] else host;
    for (known) |k| if (std.ascii.eqlIgnoreCase(bare, k.domain)) return k.name;
    return host[0..@min(host.len, max_engine_name_bytes)];
}

fn unreserved(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~';
}

/// 검색 주소 — 틀의 `%s` 를 선택한 글로(UTF-8 을 퍼센트 인코딩, 빈칸은 `%20`). 앞뒤 빈칸은 걷고 안의 줄바꿈·탭은 빈칸 하나로 접는다
/// (Chrome 도 줄바꿈을 접는다). 주소 상한을 넘으면 글을 글자 경계에서 줄인다. 걷고 나서 빈 글이면 null.
pub fn buildUrl(configured: []const u8, selection: []const u8, out: []u8) ?[]const u8 {
    const template = effectiveTemplate(configured);
    const at = std.mem.indexOf(u8, template, "%s").?;
    const head = template[0..at];
    const tail = template[at + 2 ..];
    const cap = @min(out.len, max_url_bytes);
    if (head.len + tail.len >= cap) return null;
    @memcpy(out[0..head.len], head);
    var len = head.len;
    const budget = cap - tail.len;
    const trimmed = std.mem.trim(u8, selection, " \t\r\n\x0b\x0c");
    var wrote = false;
    var pending_space = false;
    var i: usize = 0;
    while (i < trimmed.len) {
        const n = std.unicode.utf8ByteSequenceLength(trimmed[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > trimmed.len) break;
        const bytes = trimmed[i .. i + n];
        i += n;
        if (n == 1 and (bytes[0] == ' ' or bytes[0] == '\t' or bytes[0] == '\n' or bytes[0] == '\r')) {
            pending_space = wrote;
            continue;
        }
        if (n == 1 and (bytes[0] < 0x20 or bytes[0] == 0x7f)) continue;
        if (std.unicode.utf8Decode(bytes)) |_| {} else |_| continue;
        var need: usize = 0;
        for (bytes) |b| need += if (unreserved(b)) 1 else 3;
        if (pending_space) need += 3;
        if (len + need > budget) break;
        if (pending_space) {
            @memcpy(out[len .. len + 3], "%20");
            len += 3;
            pending_space = false;
        }
        for (bytes) |b| {
            if (unreserved(b)) {
                out[len] = b;
                len += 1;
            } else {
                _ = std.fmt.bufPrint(out[len .. len + 3], "%{X:0>2}", .{b}) catch unreachable;
                len += 3;
            }
        }
        wrote = true;
    }
    if (!wrote) return null;
    @memcpy(out[len .. len + tail.len], tail);
    len += tail.len;
    return out[0..len];
}

test "a search template must be http or https with a host and exactly one %s; anything else falls back to Google" {
    try std.testing.expect(validTemplate(default_template));
    try std.testing.expect(validTemplate("https://duckduckgo.com/?q=%s&ia=web"));
    try std.testing.expect(validTemplate("http://localhost:8080/s/%s"));
    for ([_][]const u8{ "", "javascript:alert(%s)", "file:///tmp/%s", "https://www.google.com/search?q=", "https://a/%s?q=%s", "https:///?q=%s", "https://%s.example/", "https://a b/?q=%s", "https://a/\x1b?q=%s", "maru-app://x/%s", "https://%s@a/", "https://a:%s/", "https://google.com@evil.example/?q=%s" }) |bad| {
        try std.testing.expect(!validTemplate(bad));
        try std.testing.expectEqualStrings(default_template, effectiveTemplate(bad));
    }
}

test "the engine name comes from the template host — known engines by name, others by host without www" {
    try std.testing.expectEqualStrings("Google", engineName(default_template));
    try std.testing.expectEqualStrings("DuckDuckGo", engineName("https://duckduckgo.com/?q=%s"));
    try std.testing.expectEqualStrings("NAVER", engineName("https://search.naver.com/search.naver?query=%s"));
    try std.testing.expectEqualStrings("Bing", engineName("https://www.bing.com/search?q=%s"));
    try std.testing.expectEqualStrings("example.org", engineName("https://www.example.org:8443/find?q=%s"));
    try std.testing.expectEqualStrings("Google", engineName("https://google.com@evil.example/?q=%s")); // 사용자 정보가 있는 틀은 쓰지 않는다(기본 틀)
    try std.testing.expectEqualStrings("Google", engineName("javascript:%s")); // 쓸 수 없는 틀은 기본 틀
    // 브라우저는 `\` 를 `/` 로 읽는다 — 이름은 실제로 가는 호스트다. 첫 이름만 맞는 다른 도메인은 그 이름이 아니다.
    try std.testing.expectEqualStrings("evil.example", engineName("https://evil.example\\@google.com/?q=%s"));
    try std.testing.expectEqualStrings("google.evil.example", engineName("https://google.evil.example/?q=%s"));
    try std.testing.expectEqualStrings("Google", engineName("https://www.google.co.kr/search?q=%s"));
    try std.testing.expectEqualStrings("[::1]", engineName("http://[::1]/?q=%s"));
    try std.testing.expectEqualStrings("[::1]", engineName("http://[::1]:8080/?q=%s"));
    const long_host = "https://" ++ "a" ** 100 ++ ".example/?q=%s";
    try std.testing.expectEqual(@as(usize, max_engine_name_bytes), engineName(long_host).len);
}

test "the search url percent-encodes the selection, folds whitespace, drops controls and stays under the url cap" {
    var buf: [max_url_bytes + 64]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.google.com/search?q=hello%20world", buildUrl(default_template, "  hello\n\n world \t", &buf).?);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=%ED%95%9C%EA%B8%80%26a%3Db%23c", buildUrl(default_template, "한글&a=b#c", &buf).?);
    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=a%2Bb&ia=web", buildUrl("https://duckduckgo.com/?q=%s&ia=web", "a+b", &buf).?);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=ab", buildUrl(default_template, "a\x07\x1bb", &buf).?);
    // 앞의 걸러진 글자 뒤 빈칸은 앞 빈칸이다 — 남기지 않는다.
    try std.testing.expectEqualStrings("https://www.google.com/search?q=a", buildUrl(default_template, "\x07 a", &buf).?);
    try std.testing.expect(buildUrl(default_template, " \n\t ", &buf) == null);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=x", buildUrl("javascript:%s", "x", &buf).?);
    // 긴 글은 글자 경계에서 줄인다 — 결과는 상한 안이고 깨진 퍼센트 인코딩이 없다.
    const long = "가" ** 2000;
    const url = buildUrl(default_template, long, &buf).?;
    try std.testing.expect(url.len <= max_url_bytes);
    try std.testing.expect(std.mem.endsWith(u8, url, "%EA%B0%80")); // 「가」 = EA B0 80 — 마지막 글자가 온전하다
    try std.testing.expectEqual(@as(usize, 0), (url.len - "https://www.google.com/search?q=".len) % 9);
    // 뒤가 있는 틀과 빈칸이 섞인 긴 글 — 빈칸의 `%20` 까지 셈해 상한 안에서 끝나고 뒤가 온전하다(출력 버퍼가 딱 상한이어도).
    var exact: [max_url_bytes]u8 = undefined;
    const tail = "https://duckduckgo.com/?q=%s&ia=web";
    const spaced = buildUrl(tail, "a " ** 20000, &exact).?;
    try std.testing.expect(spaced.len <= max_url_bytes);
    try std.testing.expect(std.mem.endsWith(u8, spaced, "&ia=web"));
    try std.testing.expect(!std.mem.endsWith(u8, spaced, "%20&ia=web"));
}
