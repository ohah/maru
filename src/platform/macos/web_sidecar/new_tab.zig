//! 페이지가 여는 새 탭(W6e — docs/plans/web-osr-backend.md W6). CEF 의 팝업(`on_before_popup` — `target=_blank`·`window.open`)과
//! 새 탭 이동(`on_open_urlfrom_tab` — ⌘·가운데 클릭)을 모두 취소하고(sidecar 는 창을 만들지 않는다) 주소만 `open_tab` 으로 보낸다.
//! 앞/뒤·주소 규칙은 순수 모듈(`web_osr_new_tab`)이 정하고, maru 가 주소를 다시 거른다.
//!
//! **사용자 입력 하나에 탭 하나**: 착수 전 실측 — 클릭 한 번에 `window.open` 을 10 번 부르면 10 번 모두 제스처가 있는 것으로 왔다
//! (취소한 팝업은 렌더러의 활성화를 쓰지 않는다). Chrome 은 팝업 하나가 활성화를 쓴다. 그래서 maru 가 보낸 누름·키(`input`)가
//! 그 브라우저에 한 장을 주고, 새 탭 하나가 그것을 쓴다. 제스처가 없으면(페이지가 스스로 만든 ⌘ 클릭 — 실측: 제스처 0 으로 온다)
//! 열지 않는다. 메뉴의 「새 탭에서 링크 열기」는 maru 의 메뉴 답이라 장을 쓰지 않는다(`context_menu`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const rules = protocol.new_tab;

comptime {
    std.debug.assert(rules.disposition.current_tab == c.CEF_WOD_CURRENT_TAB);
    std.debug.assert(rules.disposition.new_foreground_tab == c.CEF_WOD_NEW_FOREGROUND_TAB);
    std.debug.assert(rules.disposition.new_background_tab == c.CEF_WOD_NEW_BACKGROUND_TAB);
    std.debug.assert(rules.disposition.new_popup == c.CEF_WOD_NEW_POPUP);
    std.debug.assert(rules.disposition.new_window == c.CEF_WOD_NEW_WINDOW);
}

/// 사용자 입력이 그 브라우저에 갔다 — 새 탭 한 장을 준다(쌓지 않는다). 앞 놓기의 이동 표시는 끝났다.
pub fn grant(browser: protocol.message.BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    entry.new_tab_credit = true;
    entry.drop_navigation = false;
}

/// CEF 의 새 탭 요청 하나. 열면(보냈으면) true — 부르는 쪽은 어느 쪽이든 CEF 에는 취소로 답한다.
pub fn request(browser: [*c]c.cef_browser_t, url: [*c]const c.cef_string_t, disposition: c.cef_window_open_disposition_t, user_gesture: c_int) bool {
    if (browser == null or browsers.state.shutting_down) return false;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return false;
    if (entry.closing) return false;
    const placement = rules.placement(@intCast(disposition)) orelse return false;
    if (user_gesture == 0 or !entry.new_tab_credit) return false;
    var buf: [protocol.wire.max_url_bytes + 4]u8 = undefined;
    const address = readUrl(url, &buf) orelse return false;
    if (!rules.urlAllowed(address)) return false;
    entry.new_tab_credit = false;
    browsers.state.writer.send(.{ .open_tab = .{ .browser = entry.id, .placement = placement, .url = address } }) catch return false;
    return true;
}

/// 주소 전체(wire 상한을 넘으면 null — 잘린 주소를 열지 않는다). `out` 은 상한보다 4 바이트 크다 — 글자 경계에서 잘려도 상한을
/// 넘은 것이 보인다.
fn readUrl(value: [*c]const c.cef_string_t, out: []u8) ?[]const u8 {
    const text = library.readString(browsers.state.api, value, out);
    if (text.len == 0 or text.len > protocol.wire.max_url_bytes) return null;
    return text;
}

/// `on_open_urlfrom_tab`(⌘·가운데 클릭 — 착수 전 실측: `target=_blank` 링크도 수식키와 함께면 여기로 온다). 새 탭 요청이면 열든
/// 안 열든 취소한다(1 — 안 열면 Chrome 의 팝업 차단과 같다). 같은 탭 이동이면 그대로 둔다(0).
pub fn onOpenUrlFromTab(
    _: [*c]c.cef_request_handler_t,
    browser: [*c]c.cef_browser_t,
    frame: [*c]c.cef_frame_t,
    url: [*c]const c.cef_string_t,
    disposition: c.cef_window_open_disposition_t,
    user_gesture: c_int,
) callconv(.c) c_int {
    const object = @import("object.zig");
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    if (disposition == c.CEF_WOD_CURRENT_TAB) return 0;
    // 받지 않은 놓기의 이동(W6d① — 착수 전 실측: 빈 곳에 놓은 파일·링크가 앞 탭·제스처 1 로 여기 온다). 처리기가 없던 때처럼 지금
    // 탭에서 옮긴다 — 새 탭이 아니다(Chrome 과 같다).
    if (browser != null) if (browsers.state.registry.byCefId(browser.*.get_identifier.?(browser))) |entry| if (entry.drop_navigation) {
        entry.drop_navigation = false;
        return 0;
    };
    _ = request(browser, url, disposition, user_gesture);
    return 1;
}
