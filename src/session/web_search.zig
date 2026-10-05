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

/// 쓸 수 있는 틀인가 — http·https, 호스트가 있고, `%s` 가 꼭 하나, 제어 문자·빈칸 없음.
pub fn validTemplate(template: []const u8) bool {
    if (template.len == 0 or template.len > max_url_bytes) return false;
    const sep = std.mem.indexOf(u8, template, "://") orelse return false;
    const scheme = template[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const host = hostOf(template) orelse return false;
    if (host.len == 0 or std.mem.indexOf(u8, host, "%s") != null) return false;
    for (template) |b| if (b <= 0x20 or b == 0x7f) return false;
    return std.mem.count(u8, template, "%s") == 1;
}

/// 쓸 틀 — 설정이 쓸 수 없으면 기본 틀.
pub fn effectiveTemplate(configured: []const u8) []const u8 {
    return if (validTemplate(configured)) configured else default_template;
}

fn hostOf(template: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, template, "://") orelse return null;
    const rest = template[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..]; // 사용자 정보는 이름이 아니다
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return host;
}

const Known = struct { label: []const u8, name: []const u8 };
const known = [_]Known{
    .{ .label = "google", .name = "Google" },
    .{ .label = "bing", .name = "Bing" },
    .{ .label = "duckduckgo", .name = "DuckDuckGo" },
    .{ .label = "naver", .name = "NAVER" },
    .{ .label = "daum", .name = "Daum" },
    .{ .label = "yahoo", .name = "Yahoo!" },
    .{ .label = "ecosia", .name = "Ecosia" },
    .{ .label = "brave", .name = "Brave" },
    .{ .label = "kagi", .name = "Kagi" },
};

/// 메뉴 문구의 엔진 이름 — 호스트의 `www.`·`search.` 를 뗀 첫 이름이 잘 알려진 엔진이면 그 이름, 아니면 `www.` 를 뗀 호스트.
pub fn engineName(template: []const u8) []const u8 {
    var host = hostOf(effectiveTemplate(template)) orelse return "Google";
    for ([_][]const u8{ "www.", "search." }) |prefix| {
        if (host.len > prefix.len and std.ascii.startsWithIgnoreCase(host, prefix)) host = host[prefix.len..];
    }
    const first = host[0 .. std.mem.indexOfScalar(u8, host, '.') orelse host.len];
    for (known) |k| if (std.ascii.eqlIgnoreCase(first, k.label)) return k.name;
    return host;
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
    for ([_][]const u8{ "", "javascript:alert(%s)", "file:///tmp/%s", "https://www.google.com/search?q=", "https://a/%s?q=%s", "https:///?q=%s", "https://%s.example/", "https://a b/?q=%s", "https://a/\x1b?q=%s", "maru-app://x/%s" }) |bad| {
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
    try std.testing.expectEqualStrings("evil.example", engineName("https://google.com@evil.example/?q=%s")); // 사용자 정보는 이름이 아니다
    try std.testing.expectEqualStrings("Google", engineName("javascript:%s")); // 쓸 수 없는 틀은 기본 틀
}

test "the search url percent-encodes the selection, folds whitespace, drops controls and stays under the url cap" {
    var buf: [max_url_bytes + 64]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.google.com/search?q=hello%20world", buildUrl(default_template, "  hello\n\n world \t", &buf).?);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=%ED%95%9C%EA%B8%80%26a%3Db%23c", buildUrl(default_template, "한글&a=b#c", &buf).?);
    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=a%2Bb&ia=web", buildUrl("https://duckduckgo.com/?q=%s&ia=web", "a+b", &buf).?);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=ab", buildUrl(default_template, "a\x07\x1bb", &buf).?);
    try std.testing.expect(buildUrl(default_template, " \n\t ", &buf) == null);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=x", buildUrl("javascript:%s", "x", &buf).?);
    // 긴 글은 글자 경계에서 줄인다 — 결과는 상한 안이고 깨진 퍼센트 인코딩이 없다.
    const long = "가" ** 2000;
    const url = buildUrl(default_template, long, &buf).?;
    try std.testing.expect(url.len <= max_url_bytes);
    try std.testing.expect(std.mem.endsWith(url, "%EA%B0%80")); // 「가」 = EA B0 80 — 마지막 글자가 온전하다
    try std.testing.expectEqual(@as(usize, 0), (url.len - "https://www.google.com/search?q=".len) % 9);
}
