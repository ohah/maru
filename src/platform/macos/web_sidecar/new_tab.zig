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
const registry_mod = @import("registry.zig");
const object = @import("object.zig");
const drag = @import("drag.zig");
const rules = protocol.new_tab;

comptime {
    std.debug.assert(rules.disposition.current_tab == c.CEF_WOD_CURRENT_TAB);
    std.debug.assert(rules.disposition.new_foreground_tab == c.CEF_WOD_NEW_FOREGROUND_TAB);
    std.debug.assert(rules.disposition.new_background_tab == c.CEF_WOD_NEW_BACKGROUND_TAB);
    std.debug.assert(rules.disposition.new_popup == c.CEF_WOD_NEW_POPUP);
    std.debug.assert(rules.disposition.new_window == c.CEF_WOD_NEW_WINDOW);
}

// ── W6f: 팝업 이어 받기 ─────────────────────────────────────────────────────────────────────────────────────
// maru 가 맡긴 번호(`popup_reserve`)가 있으면 페이지의 팝업을 창 없는 CEF 브라우저로 만들게 두고(`on_before_popup` 0) 그 번호로
// 등록한다 — 원래 페이지와 이어진다(착수 전 실측: `window.opener`·`postMessage`·이름 창 재사용·`close`·`document.write`). CEF 는
// `on_before_popup` 바로 뒤(같은 UI 스레드, 실측 6 ms)에 새 브라우저로 `on_after_created` 를 부르고, 만들지 못하면 연 브라우저로
// `on_before_popup_aborted` 를 부른다 — 기다리는 팝업을 차례대로 짝짓는다. 이어 받지 않은 팝업 브라우저는 하나도 남기지 않는다.

var reserved: [protocol.message.max_popup_reserve]protocol.message.BrowserId = undefined;
var reserved_len: usize = 0;

const PendingPopup = struct {
    opener: protocol.message.BrowserId,
    opener_cef: c_int,
    popup_id: c_int,
    browser: protocol.message.BrowserId,
    placement: protocol.message.NewTabPlacement,
    size: protocol.message.ViewSize,
    url: []u8,
};
var pending: [protocol.message.max_popup_reserve]PendingPopup = undefined;
var pending_len: usize = 0;
const allocator = std.heap.c_allocator;

/// maru 가 번호를 맡겼다. 이미 쓰는 번호·맡은 번호·넘치는 것은 버린다(maru 의 번호는 다시 쓰이지 않으므로 잃어도 된다).
pub fn onReserve(id: protocol.message.BrowserId) void {
    if (browsers.state.registry.byId(id) != null or reserved_len == reserved.len) return;
    for (reserved[0..reserved_len]) |r| if (r == id) return;
    for (pending[0..pending_len]) |p| if (p.browser == id) return;
    reserved[reserved_len] = id;
    reserved_len += 1;
}

/// 그 브라우저가 닫힌다 — 그것이 연 기다리는 팝업을 지운다(CEF 헤더 — `OnBeforeClose` 가 그 브라우저의 기다리는 팝업을 끝낸다).
/// 번호는 다시 맡긴다.
pub fn openerClosed(cef_id: c_int) void {
    var i: usize = 0;
    while (i < pending_len) {
        if (pending[i].opener_cef == cef_id) {
            const taken = takePending(i);
            allocator.free(taken.url);
            onReserve(taken.browser);
        } else i += 1;
    }
}

/// maru 가 그 번호로 브라우저를 직접 만든다 — 맡긴 것에서 뺀다(같은 번호로 팝업을 등록하려다 거절되지 않게 — W6f① 적대 검증).
pub fn forgetReserved(id: protocol.message.BrowserId) void {
    var i: usize = 0;
    while (i < reserved_len) {
        if (reserved[i] == id) {
            var j = i + 1;
            while (j < reserved_len) : (j += 1) reserved[j - 1] = reserved[j];
            reserved_len -= 1;
        } else i += 1;
    }
}

/// `on_before_popup` — 이어 받을 수 있으면 창 없는 브라우저로 만들게 두고 0, 아니면 주소만 보내고(W6e) 1.
pub fn beforePopup(
    browser: [*c]c.cef_browser_t,
    popup_id: c_int,
    url: [*c]const c.cef_string_t,
    disposition: c.cef_window_open_disposition_t,
    user_gesture: c_int,
    window_info: [*c]c.cef_window_info_t,
) c_int {
    // 맡긴 번호가 없거나, 기다리는 팝업이 넘치거나, 목록에 자리가 없으면(만들게 둔 뒤 등록을 못 해 곧 닫히는 팝업이 되지 않게 — W6f①
    // 적대 검증) W6e 처럼 주소만.
    if (reserved_len == 0 or pending_len == pending.len or browser == null or browsers.state.shutting_down or
        browsers.state.registry.count() + pending_len >= registry_mod.capacity)
    {
        _ = request(browser, url, disposition, user_gesture);
        return 1;
    }
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return 1;
    if (entry.closing) return 1;
    const placement = rules.placement(@intCast(disposition)) orelse return 1;
    if (user_gesture == 0 or !rules.creditLive(entry.new_tab_credit_ms, nowMs())) return 1;
    var buf: [protocol.wire.max_url_bytes + 4]u8 = undefined;
    // 빈 주소만 `about:blank` 다(CEF 는 보통 그렇게 준다). 상한을 넘는 주소는 거절한다 — 잘린 주소로 규칙을 보면 안 된다(W6f① 적대
    // 검증 — 「없음」으로 접어 `about:blank` 로 통과시키고 CEF 는 원래의 긴 주소로 열었다).
    const empty = url == null or url.*.str == null or url.*.length == 0;
    const address = if (empty) "about:blank" else readUrl(url, &buf) orelse return 1;
    if (!rules.popupUrlAllowed(address)) return 1;
    const owned = allocator.dupe(u8, address) catch return 1;
    entry.new_tab_credit_ms = 0;
    // 맡긴 차례대로 쓴다.
    const id = reserved[0];
    var i: usize = 1;
    while (i < reserved_len) : (i += 1) reserved[i - 1] = reserved[i];
    reserved_len -= 1;
    pending[pending_len] = .{
        .opener = entry.id,
        .opener_cef = entry.cef_id,
        .popup_id = popup_id,
        .browser = id,
        .placement = placement,
        .size = entry.size,
        .url = owned,
    };
    pending_len += 1;
    // 만들어지는 동안 CEF 가 묻는 크기는 연 탭의 크기로(등록 전이라 목록에 없다 — maru 가 붙인 뒤 맞춘다).
    browsers.state.creating_size = entry.size;
    window_info.*.windowless_rendering_enabled = 1;
    window_info.*.shared_texture_enabled = if (std.c.getenv("MARU_WEB_TEST_CPU_PAINT") != null) 0 else 1;
    return 0;
}

fn takePending(index: usize) PendingPopup {
    const p = pending[index];
    var i = index;
    while (i + 1 < pending_len) : (i += 1) pending[i] = pending[i + 1];
    pending_len -= 1;
    return p;
}

/// 만들지 못했다 — 그 번호를 다시 맡긴다.
pub fn onBeforePopupAborted(_: [*c]c.cef_life_span_handler_t, browser: [*c]c.cef_browser_t, popup_id: c_int) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    for (pending[0..pending_len], 0..) |p, i| if (p.opener_cef == cef_id and p.popup_id == popup_id) {
        const taken = takePending(i);
        allocator.free(taken.url);
        browsers.state.creating_size = null;
        onReserve(taken.browser);
        return;
    };
}

/// 새 브라우저가 만들어졌다. maru 가 만든 것(`create_browser` — 등록은 그쪽이 한다)이 아니고 팝업이면 기다리던 첫 팝업으로 등록한다.
/// 짝이 없는 팝업은 닫는다(쥘 번호가 없다 — 이어 받지 않은 브라우저를 남기지 않는다).
pub fn onAfterCreated(_: [*c]c.cef_life_span_handler_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    if (browser == null) return;
    if (browser.*.is_popup.?(browser) == 0 or browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) != null) {
        object.releaseArg(browser);
        return;
    }
    // 연 브라우저로 짝짓는다(CEF 헤더 — 기다리는 팝업은 연 브라우저마다 따로 끝난다). 같은 브라우저가 둘을 기다리면 먼저 온 것부터.
    const opener_cef = blk: {
        const host = browser.*.get_host.?(browser);
        if (host == null) break :blk @as(c_int, 0);
        defer object.release(host);
        break :blk host.*.get_opener_identifier.?(host);
    };
    const index = for (pending[0..pending_len], 0..) |p, i| {
        if (p.opener_cef == opener_cef) break i;
    } else null;
    if (index == null or browsers.state.shutting_down) {
        if (index) |i| allocator.free(takePending(i).url);
        browsers.state.creating_size = null;
        return browsers.discard(browser);
    }
    browsers.state.creating_size = null;
    const p = takePending(index.?);
    defer allocator.free(p.url);
    // 넘겨받은 참조 하나는 목록이 쥔다(실패하면 `register` 가 닫고 푼다 — maru 에 알린다: 그 번호는 쓰이지 않았다).
    browsers.register(browser, p.browser, p.size) catch {
        browsers.state.writer.send(.{ .failure = .{ .browser = p.browser, .code = .browser_create_failed, .detail = "popup not adopted" } }) catch {};
        return;
    };
    browsers.state.writer.send(.{ .popup_created = .{ .opener = p.opener, .browser = p.browser, .placement = p.placement, .url = p.url } }) catch {};
}

/// 사용자 입력이 그 브라우저에 갔다 — 새 탭 한 장을 준다(쌓지 않는다). 앞 놓기의 이동 표시는 끝났다.
pub fn grant(browser: protocol.message.BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    entry.new_tab_credit_ms = nowMs();
}

/// 놓기 뒤 그 이동을 지금 탭으로 보는 시간. 렌더러의 답은 곧 온다 — 페이지가 놓기를 받아 이동이 없었으면 표시가 남지 않게 짧게
/// (W6e 적대 검증 2 차 — 처음엔 다음 입력까지 남아, 그사이 제스처 없는 요청도 지금 탭에서 옮겼다).
pub const drop_navigation_ms = 2_000;

pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// CEF 의 새 탭 요청 하나. 열면(보냈으면) true — 부르는 쪽은 어느 쪽이든 CEF 에는 취소로 답한다.
pub fn request(browser: [*c]c.cef_browser_t, url: [*c]const c.cef_string_t, disposition: c.cef_window_open_disposition_t, user_gesture: c_int) bool {
    if (browser == null or browsers.state.shutting_down) return false;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return false;
    if (entry.closing) return false;
    const placement = rules.placement(@intCast(disposition)) orelse return false;
    if (user_gesture == 0 or !rules.creditLive(entry.new_tab_credit_ms, nowMs())) return false;
    var buf: [protocol.wire.max_url_bytes + 4]u8 = undefined;
    const address = readUrl(url, &buf) orelse return false;
    if (!rules.urlAllowed(address)) return false;
    entry.new_tab_credit_ms = 0;
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
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    if (disposition == c.CEF_WOD_CURRENT_TAB) return 0;
    // 받지 않은 놓기의 이동(W6d① — 착수 전 실측: 빈 곳에 놓은 파일·링크가 앞 탭·제스처 1 로 여기 온다). 처리기가 없던 때처럼 지금
    // 탭에서 옮긴다 — 새 탭이 아니다(Chrome 과 같다).
    if (browser != null) if (browsers.state.registry.byCefId(browser.*.get_identifier.?(browser))) |entry| if (entry.drop_at_ms != 0) {
        if (nowMs() - entry.drop_at_ms > drop_navigation_ms) {
            drag.forgetDrop(entry);
        } else if (disposition == c.CEF_WOD_NEW_FOREGROUND_TAB and user_gesture != 0) if (entry.drop_url) |expected| {
            var buf: [protocol.wire.max_url_bytes + 4]u8 = undefined;
            const got = readUrl(url, &buf) orelse "";
            if (rules.dropMatches(expected, entry.drop_is_path, got)) {
                drag.forgetDrop(entry);
                return 0;
            }
        };
    };
    _ = request(browser, url, disposition, user_gesture);
    return 1;
}
