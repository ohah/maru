//! Chromium 탭의 페이지가 여는 새 탭(W6e — docs/plans/web-osr-backend.md W6). `target=_blank`·`window.open`·⌘/가운데 클릭은
//! CEF 의 팝업(`on_before_popup`)·새 탭 이동(`on_open_urlfrom_tab`)으로 오고, sidecar 가 그것을 취소하고 주소만 maru 에 보낸다.
//! 원래 페이지와는 이어지지 않는다(`window.opener` 없음 — 사용자 결정 2026-10-04: 주소로 먼저, 이어 받기는 다음 단계).
//!
//! - 앞/뒤: Chrome 과 같다 — ⌘·가운데 클릭은 뒤(포커스 그대로), `target=_blank`·`window.open`·⌘⇧ 클릭은 앞. 팝업 창(크기를 준
//!   `window.open`)과 ⇧ 클릭(Chrome 은 새 창)도 앞 탭이다.
//! - 주소: http·https 만. `about:blank`(`window.open()` 처럼 빈 팝업 — 이어지지 않으면 페이지가 채울 수 없다)·`data:`·`file:`·
//!   `javascript:`·`maru-app:` 은 열지 않는다.
//! - 자리: 연 탭 바로 오른쪽, 그 탭이 이어 연 뒤 탭들이 있으면 그 오른쪽(Chrome 처럼 차례대로 놓인다).
//!
//! sidecar(`web_sidecar_protocol`)와 maru(`session.web_sidecar`)가 같은 파일을 쓴다 — 순수 규칙이다.

const std = @import("std");
const message = @import("message.zig");
const wire = @import("wire.zig");

pub const Placement = message.NewTabPlacement;

/// CEF `cef_window_open_disposition_t` 의 값(`include/internal/cef_types.h`). 순수 모듈이라 수로 둔다 — sidecar 가 CEF 헤더와
/// comptime 으로 맞춘다.
pub const disposition = struct {
    pub const current_tab: u32 = 1;
    pub const new_foreground_tab: u32 = 3;
    pub const new_background_tab: u32 = 4;
    pub const new_popup: u32 = 5;
    pub const new_window: u32 = 6;
};

/// 그 요청이 새 탭이면 앞/뒤, 아니면(같은 탭·저장·모르는 값) null.
pub fn placement(value: u32) ?Placement {
    return switch (value) {
        disposition.new_foreground_tab, disposition.new_popup, disposition.new_window => .foreground,
        disposition.new_background_tab => .background,
        else => null,
    };
}

/// 새 탭에 실어 열 수 있는 주소인가 — http·https, `://` 뒤가 비지 않았다, 제어 문자 없음, wire 주소 상한 안.
pub fn urlAllowed(url: []const u8) bool {
    if (url.len == 0 or url.len > wire.max_url_bytes) return false;
    const sep = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    if (sep + 3 == url.len) return false;
    for (url) |b| if (b < 0x20 or b == 0x7f) return false;
    return true;
}

/// http·https 주소의 출처(W6h② — 미디어 메뉴가 바꾸는 요소의 문서 출처 확인)(`scheme://host[:port]`) — 브라우저의 `location.origin` 과 같은 꼴(소문자 스킴·호스트는 GURL 이 이미
/// 정규화했다). 그 밖의 주소는 null.
pub fn originOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return null;
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    // 사용자 정보(`u:p@`)는 출처가 아니다(`location.origin` 에 없다 — W6h② 적대 검증 5 회차). 그 뒤만 남긴다.
    const at = std.mem.lastIndexOfScalar(u8, rest[0..end], '@') orelse return url[0 .. sep + 3 + end];
    if (at + 1 == end) return null;
    return originBuf(url[0..sep], rest[at + 1 .. end]);
}

var origin_scratch: [wire.max_url_bytes]u8 = undefined;

/// 사용자 정보를 뗀 출처를 만든다(한 스레드 — sidecar UI 스레드, 다음 부름까지 유효).
fn originBuf(scheme: []const u8, host: []const u8) ?[]const u8 {
    if (scheme.len + 3 + host.len > origin_scratch.len) return null;
    @memcpy(origin_scratch[0..scheme.len], scheme);
    @memcpy(origin_scratch[scheme.len .. scheme.len + 3], "://");
    @memcpy(origin_scratch[scheme.len + 3 .. scheme.len + 3 + host.len], host);
    return origin_scratch[0 .. scheme.len + 3 + host.len];
}

test "the origin of a frame url is scheme and authority, only for http and https" {
    try std.testing.expectEqualStrings("https://a.example", originOf("https://a.example/v?x#t=10").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", originOf("http://127.0.0.1:8080").?);
    try std.testing.expect(originOf("about:blank") == null);
    try std.testing.expect(originOf("data:text/html,x") == null);
    try std.testing.expect(originOf("https:///x") == null);
    try std.testing.expectEqualStrings("https://a.example", originOf("https://a.example#x").?);
    try std.testing.expectEqualStrings("https://a.example", originOf("https://a.example?q").?);
    try std.testing.expectEqualStrings("http://h.example:81", originOf("http://u:p@h.example:81/v").?);
    try std.testing.expect(originOf("http://u@/v") == null);
    try std.testing.expect(originOf("ftp://a.example/") == null);
}

/// 이어 받는 팝업(W6f)이 처음 갈 수 있는 주소 — 새 탭 주소(`urlAllowed`)에 더해 빈 팝업(`about:blank` — `window.open()` 뒤
/// `document.write` 로 채운다, 착수 전 실측: 이어지면 된다). CEF 는 빈 주소·`javascript:` 를 `about:blank` 로 준다(W6e 실측).
pub fn popupUrlAllowed(url: []const u8) bool {
    return urlAllowed(url) or std.mem.eql(u8, url, "about:blank");
}

/// 새 탭 한 장의 수명(ms) — Chrome 의 일시 활성화와 같은 5 초. 쓰지 않은 장이 오래 남아 나중에 아무 때나 탭을 띄우지 않게(W6f② 적대
/// 검증 4 차).
pub const activation_ms: i64 = 5_000;

/// 그 키 누름이 사용자 활성화인가(장을 주는가) — Esc 는 아니다(Chrome 과 같다). maru 는 macOS 키 코드만 싣고 Windows 키 코드는 0 이다
/// (적대 검증 4 차 — Windows 코드만 보던 검사가 제품에서는 늘 참이었다). 판정자는 Windows 코드를 싣는다 — 둘 다 본다.
pub fn grantsActivation(kind: message.KeyKind, windows_key_code: i32, native_key_code: i32) bool {
    if (kind != .raw_down and kind != .down) return false;
    return windows_key_code != 0x1b and native_key_code != 0x35; // VK_ESCAPE · kVK_Escape
}

/// 그 장이 아직 쓸 수 있는가(받은 시각 `granted_ms`, 0 이면 없음).
pub fn creditLive(granted_ms: i64, now_ms: i64) bool {
    return granted_ms != 0 and now_ms - granted_ms <= activation_ms;
}

/// maru 쪽 장 — 보낸 사용자 입력마다 하나(최대 `max_credits`, 5 초 + 전달 여유). sidecar 는 입력을 차례로 처리하며 팝업마다 장을
/// 쓰지만 maru 는 보낼 때 센다 — 빠르게 두 번 누르면 sidecar 는 팝업 둘을 열고 maru 가 하나만 받아 둘째가 열렸다 곧 닫혔다(W6f② 적대
/// 검증 5 차). 개수로 센다.
pub const Credits = struct {
    pub const max_credits = 4;
    /// sidecar 가 처리하고 팝업이 maru 에 닿기까지의 여유.
    pub const transit_ms: i64 = 1_000;
    at: [max_credits]i64 = @splat(0),
    len: usize = 0,

    fn prune(self: *Credits, now_ms: i64) void {
        var kept: usize = 0;
        for (self.at[0..self.len]) |t| if (now_ms - t <= activation_ms + transit_ms) {
            self.at[kept] = t;
            kept += 1;
        };
        self.len = kept;
    }

    pub fn grant(self: *Credits, now_ms: i64) void {
        self.prune(now_ms);
        if (self.len == max_credits) {
            var i: usize = 1;
            while (i < self.len) : (i += 1) self.at[i - 1] = self.at[i];
            self.len -= 1;
        }
        self.at[self.len] = now_ms;
        self.len += 1;
    }

    /// 가장 오래된 산 장 하나를 쓴다 — 없으면 false.
    pub fn take(self: *Credits, now_ms: i64) bool {
        self.prune(now_ms);
        if (self.len == 0) return false;
        var i: usize = 1;
        while (i < self.len) : (i += 1) self.at[i - 1] = self.at[i];
        self.len -= 1;
        return true;
    }

    pub fn any(self: *const Credits) bool {
        return self.len != 0;
    }
};

/// 새 탭을 끼울 자리(pane 의 탭 순서). `last_child` 는 같은 탭이 이어 연 마지막 뒤 탭의 자리(없으면 null) — 그것이 연 탭
/// 오른쪽에 있을 때만 따른다.
pub fn insertIndex(opener: usize, last_child: ?usize) usize {
    if (last_child) |child| if (child > opener) return child + 1;
    return opener + 1;
}

/// 새 탭을 어디에 두고 무엇을 활성으로 할지. `focus` 면 새 탭으로 옮긴다(`active` 는 새 탭 자리).
pub const Insert = struct { at: usize, active: usize, focus: bool };

/// `opener`·`active` 는 pane 안 자리. `visible` 은 연 탭이 사용자가 보고 있는 탭인가(활성 워크스페이스의 활성 pane 의 활성 탭) —
/// 아니면 앞 탭도 뒤로 둔다(사용자가 다른 탭으로 옮긴 뒤 늦게 온 `window.open` 이 끌어가지 않게 — W6e 적대 검증 1 차). 뒤로 두면
/// 활성 탭은 그대로이고, 그 앞에 끼우면 자리만 하나 민다.
pub fn place(opener: usize, active: usize, last_child: ?usize, where: Placement, visible: bool) Insert {
    const at = insertIndex(opener, last_child);
    if (where == .foreground and visible) return .{ .at = at, .active = at, .focus = true };
    return .{ .at = at, .active = if (at <= active) active + 1 else active, .focus = false };
}

/// 받지 않은 놓기의 이동인가(W6e) — Chromium 이 그 주소로 옮기자고 부른 주소(`got`)가 놓은 것과 같다. 파일이면 `expected` 는 경로이고
/// `got` 은 `file://` 주소다(퍼센트 인코딩을 풀어 비교한다 — 폴더는 끝에 `/` 가 붙는다). 링크면 같거나 끝에 `/` 하나만 더 붙었다(호스트
/// 뿐인 주소를 Chromium 이 정규화한다). `javascript:` 링크는 Chromium 이 `about:blank#blocked` 로 바꿔 부른다 — 무해한 막힘 페이지라
/// 놓은 것과 같게 본다(W6d① 판정 `drag-javascript`). 다른 주소면 놓기 뒤라도 새 탭 요청으로 다룬다(적대 검증 2 차 — 페이지가 받은 놓기도
/// 사용자 활성화라, 그 뒤 페이지가 만든 ⌘ 클릭이 놓기 이동처럼 지금 탭을 옮겼다).
pub fn dropMatches(expected: []const u8, is_path: bool, got: []const u8) bool {
    if (std.mem.eql(u8, got, "about:blank#blocked")) return true;
    if (!is_path) return std.mem.eql(u8, got, expected) or
        (got.len == expected.len + 1 and got[got.len - 1] == '/' and std.mem.startsWith(u8, got, expected));
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(got, prefix)) return false;
    var rest = got[prefix.len..];
    var i: usize = 0; // expected 안의 자리
    while (rest.len > 0) {
        var byte = rest[0];
        var used: usize = 1;
        if (byte == '%' and rest.len >= 3) {
            byte = std.fmt.parseInt(u8, rest[1..3], 16) catch return false;
            used = 3;
        }
        if (i == expected.len) return byte == '/' and rest.len == used; // 폴더 끝 `/`
        if (expected[i] != byte) return false;
        i += 1;
        rest = rest[used..];
    }
    return i == expected.len;
}

test "dispositions map to Chrome's foreground and background tabs, the rest open nothing" {
    try std.testing.expectEqual(Placement.foreground, placement(disposition.new_foreground_tab).?);
    try std.testing.expectEqual(Placement.background, placement(disposition.new_background_tab).?);
    try std.testing.expectEqual(Placement.foreground, placement(disposition.new_popup).?);
    try std.testing.expectEqual(Placement.foreground, placement(disposition.new_window).?);
    for ([_]u32{ 0, disposition.current_tab, 2, 7, 8, 9, 10, 11, 12, 13, 0xffff_ffff }) |value| try std.testing.expect(placement(value) == null);
}

test "only http and https addresses open a tab — blank popups, local and script schemes do not" {
    for ([_][]const u8{ "https://a.example/x?q=1", "http://127.0.0.1:8080/", "HTTPS://A.EXAMPLE", "https://a/새" }) |url| try std.testing.expect(urlAllowed(url));
    for ([_][]const u8{
        "",                  "about:blank",       "about:srcdoc",     "javascript:alert(1)",
        "data:text/html,hi", "file:///etc/hosts", "maru-app://x/y",   "blob:https://a/1",
        "https://",          " https://a",        "https:a",          "ftp://a/",
        "https://a/\x1b[2J", "https://a/\x7f",    "chrome://version", "view-source:https://a",
    }) |url| try std.testing.expect(!urlAllowed(url));
    var long: [wire.max_url_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0.."https://".len], "https://");
    try std.testing.expect(!urlAllowed(&long));
    try std.testing.expect(urlAllowed(long[0..wire.max_url_bytes]));
}

test "no page disposition maps to the new-window placement — only the menu's open-link-in-new-window does (W6h①)" {
    var d: u32 = 0;
    while (d < 32) : (d += 1) if (placement(d)) |p| try std.testing.expect(p != .new_window);
}

test "a foreground tab takes focus only from the tab the user is looking at; a background one keeps the active tab where it is" {
    try std.testing.expectEqual(Insert{ .at = 3, .active = 3, .focus = true }, place(2, 2, null, .foreground, true));
    try std.testing.expectEqual(Insert{ .at = 3, .active = 2, .focus = false }, place(2, 2, null, .background, true));
    try std.testing.expectEqual(Insert{ .at = 3, .active = 2, .focus = false }, place(2, 2, null, .foreground, false));
    // 연 탭이 활성 탭 왼쪽(사용자가 오른쪽 탭으로 옮겼다) — 끼운 자리 뒤로 활성 탭이 한 칸 밀린다.
    try std.testing.expectEqual(Insert{ .at = 1, .active = 4, .focus = false }, place(0, 3, null, .foreground, false));
    try std.testing.expectEqual(Insert{ .at = 1, .active = 2, .focus = false }, place(0, 1, null, .background, false));
    // 활성 탭이 끼운 자리 왼쪽이면 그대로.
    try std.testing.expectEqual(Insert{ .at = 5, .active = 1, .focus = false }, place(2, 1, 4, .background, false));
}

test "a drop's own navigation matches what was dropped — decoded file paths, a canonical trailing slash, Chromium's javascript block; nothing else" {
    try std.testing.expect(dropMatches("/Users/a/b c/한.html", true, "file:///Users/a/b%20c/%ED%95%9C.html"));
    try std.testing.expect(dropMatches("/Users/a/dir", true, "file:///Users/a/dir/"));
    try std.testing.expect(!dropMatches("/Users/a/b.html", true, "file:///Users/a/c.html"));
    try std.testing.expect(!dropMatches("/Users/a/b.html", true, "file:///Users/a/b.html.evil"));
    try std.testing.expect(!dropMatches("/Users/a/b.html", true, "https://evil.example/Users/a/b.html"));
    try std.testing.expect(!dropMatches("/a", true, "file:///a%2"));
    try std.testing.expect(dropMatches("https://a.example", false, "https://a.example/"));
    try std.testing.expect(dropMatches("https://a.example/x?q=1", false, "https://a.example/x?q=1"));
    try std.testing.expect(!dropMatches("https://a.example/x", false, "https://a.example/y"));
    try std.testing.expect(!dropMatches("https://a.example/x", false, "https://a.example/x/z"));
    try std.testing.expect(dropMatches("javascript:alert(1)", false, "about:blank#blocked"));
    try std.testing.expect(!dropMatches("javascript:alert(1)", false, "javascript:alert(1)x"));
}

test "an adopted popup may also start blank; other local or script addresses still do not open" {
    try std.testing.expect(popupUrlAllowed("about:blank"));
    try std.testing.expect(popupUrlAllowed("https://accounts.example/o/oauth2"));
    for ([_][]const u8{ "", "about:srcdoc", "about:blank#x", "data:text/html,hi", "file:///etc/hosts", "javascript:void(0)", "maru-app://x" }) |url| try std.testing.expect(!popupUrlAllowed(url));
}

test "a key down grants activation except Escape by either code; a credit lives five seconds" {
    try std.testing.expect(grantsActivation(.raw_down, 0, 0));
    try std.testing.expect(grantsActivation(.down, 'A', 0));
    try std.testing.expect(!grantsActivation(.raw_down, 0, 0x35)); // maru — macOS 코드만
    try std.testing.expect(!grantsActivation(.raw_down, 0x1b, 0)); // 판정자 — Windows 코드
    try std.testing.expect(!grantsActivation(.up, 'A', 0) and !grantsActivation(.char, 'a', 0));
    try std.testing.expect(!creditLive(0, 10));
    try std.testing.expect(creditLive(1_000, 6_000) and !creditLive(1_000, 6_001));
}

test "maru counts one credit per user input it sent, at most four, each living five seconds plus transit" {
    var c: Credits = .{};
    try std.testing.expect(!c.take(0));
    c.grant(100);
    c.grant(200); // 빠른 두 번 — 둘
    try std.testing.expect(c.take(300) and c.take(300) and !c.take(300));
    for (0..6) |i| c.grant(@intCast(1_000 + i));
    try std.testing.expectEqual(@as(usize, Credits.max_credits), c.len);
    // 넘치면 가장 오래된 것을 버리고, 쓸 때도 가장 오래된 것부터.
    try std.testing.expectEqual(@as(i64, 1_002), c.at[0]);
    try std.testing.expect(c.take(1_010));
    try std.testing.expectEqual(@as(i64, 1_003), c.at[0]);
    c.grant(10_000);
    try std.testing.expect(c.take(10_000 + activation_ms + Credits.transit_ms)); // 10 000 것만 산다
    try std.testing.expect(!c.take(10_000 + activation_ms + Credits.transit_ms));
}

test "a new tab goes right of its opener, after the tabs that opener already opened" {
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, null));
    try std.testing.expectEqual(@as(usize, 5), insertIndex(2, 4));
    // 이어 연 탭이 연 탭 왼쪽으로 옮겨졌으면(사용자가 끌었다) 따르지 않는다.
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, 1));
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, 2));
}
