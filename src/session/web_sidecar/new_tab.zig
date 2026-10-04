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

test "a new tab goes right of its opener, after the tabs that opener already opened" {
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, null));
    try std.testing.expectEqual(@as(usize, 5), insertIndex(2, 4));
    // 이어 연 탭이 연 탭 왼쪽으로 옮겨졌으면(사용자가 끌었다) 따르지 않는다.
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, 1));
    try std.testing.expectEqual(@as(usize, 3), insertIndex(2, 2));
}
