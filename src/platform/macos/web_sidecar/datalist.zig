//! 제안 목록(datalist — W6m①), 브라우저 프로세스 쪽. CEF Alloy 에는 Chromium 의 datalist 팝업(브라우저 쪽 자동 완성 UI)이 없어
//! 칸을 누르거나 글자를 쳐도 아무것도 뜨지 않는다(§7 실측). W5c 의 대리 스크립트 길을 같이 쓴다 — 알림 스크립트와 한 스크립트로
//! 넣고(`notifications.install` — 한 문서에서 숨긴 `send` 를 꺼내는 스크립트는 하나여야 한다), datalist 부분은 `send('dl', json)`
//! 로 칸의 자리와 거른 항목을, `send('dl', function)` 으로 「고르기」 함수를 한 번 넘긴다(`renderer.zig`).
//!
//! 규칙은 Chrome 154 실측(§7)을 따른다: 칸을 누르거나(왼쪽 누름) ↓ 를 치면 지금 값으로 거른 목록, 글자를 치면 다시 거른 목록,
//! 지워서 빈 칸이 되거나 일치가 없으면 닫는다. 거르기는 값·레이블에서 대소문자를 무시한 부분 일치, 순서는 원래대로, `disabled`
//! 와 빈 값은 뺀다. 칸이 초점을 잃거나 그 칸을 품은 스크롤·창 크기 바뀜·페이지 떠남이면 닫는다. 고르면 그 값을 넣고 `input`·`change` 를
//! 보낸 뒤 닫는다(`isTrusted` 는 false — 대리 스크립트가 보낸 사건이다, 드러나는 차이).
//!
//! 렌더러의 말은 믿지 않는다 — 주 프레임에서 온 것만(iframe 은 W6m③), 항목은 글 규칙으로 다듬고 상한 안에서, 칸 자리는 view 와
//! 겹칠 때만 보낸다(maru 가 그 pane 안으로 다시 자른다). 고르기는 maru 가 받은 목록 번호(`list`)로만 그 문서(표식)에 돌려보낸다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const renderer = @import("renderer.zig");
const page = @import("datalist_page.zig");

const message = protocol.message;
const BrowserId = message.BrowserId;

pub const script_part = page.script_part;

/// 지금 보인 목록 — 브라우저마다 하나. 고르기를 그 프레임의 그 문서(표식)·그 판(`version`)으로 돌려보낸다.
const max_frame_id_bytes = 128;
const Shown = struct {
    browser: BrowserId,
    list: u32,
    frame_buf: [max_frame_id_bytes]u8 = undefined,
    frame_len: usize = 0,
    token_buf: [16]u8 = undefined,
    version: i32,
};
var shown: [64]?Shown = [_]?Shown{null} ** 64;
var next_list: u32 = 1;

/// 브라우저마다 마지막으로 들은 문서 표식과, 주 프레임에 새 문서가 온 때 그 표식(떠난 문서). 떠난 문서가 이동 직전에 보낸 보이기가
/// 닫기(`reset`) 뒤에 도착하면 옛 표식으로 목록이 다시 서고, 새 문서의 닫기는 표식이 달라 그것을 닫지 못한다(적대 검증) — 새
/// 문서가 온 뒤 잠깐(`retired_ms`)은 떠난 표식의 보이기를 버린다. 잠깐만인 것은 뒤로 가기 캐시가 같은 문서(같은 표식)를 되살리기
/// 때문이다. 시험하지 못한 방어다(판정자로 그 경쟁을 만들지 못했다).
const Heard = struct {
    browser: BrowserId,
    last: [16]u8 = undefined,
    has_last: bool = false,
    retired: [16]u8 = undefined,
    retired_at_ms: i64 = 0,
};
var heard: [64]?Heard = [_]?Heard{null} ** 64;
const retired_ms: i64 = 1000;

fn heardOf(id: BrowserId) ?*Heard {
    for (&heard) |*slot| {
        if (slot.*) |*h| if (h.browser == id) return h;
    }
    return null;
}

fn heardFor(id: BrowserId) ?*Heard {
    var free: ?*?Heard = null;
    for (&heard) |*slot| {
        if (slot.*) |*h| {
            if (h.browser == id) return h;
        } else if (free == null) free = slot;
    }
    const slot = free orelse return null;
    slot.* = .{ .browser = id };
    return &slot.*.?;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// 렌더러 글을 읽는 버퍼 — UI 스레드에서만 쓴다(메시지마다 할당하지 않게).
var payload_buf: [renderer.max_datalist_payload_units * 3]u8 = undefined;
var items_buf: [message.max_datalist_bytes]u8 = undefined;

/// 그 프레임이 지금 그 브라우저의 주 프레임인가(떠나는 문서의 프레임이 아닌가).
fn isCurrentMain(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) bool {
    if (frame.*.is_valid.?(frame) == 0 or frame.*.is_main.?(frame) == 0) return false;
    const api = browsers.state.api;
    const main = browser.*.get_main_frame.?(browser);
    if (main == null) return false;
    defer object.release(main);
    const a = frame.*.get_identifier.?(frame);
    if (a == null) return false;
    defer api.string_userfree_utf16_free(a);
    const b = main.*.get_identifier.?(main);
    if (b == null) return false;
    defer api.string_userfree_utf16_free(b);
    if (a.*.length == 0 or a.*.str == null or b.*.str == null) return false;
    return a.*.length == b.*.length and std.mem.eql(u16, a.*.str[0..a.*.length], b.*.str[0..b.*.length]);
}

fn shownFor(id: BrowserId) ?*?Shown {
    for (&shown) |*slot| {
        if (slot.*) |s| if (s.browser == id) return slot;
    }
    return null;
}

fn freeSlot() ?*?Shown {
    for (&shown) |*slot| if (slot.* == null) return slot;
    return null;
}

/// client 의 `on_process_message_received` 에서 — 렌더러의 `maru.datalist`.
pub fn onMessage(id: BrowserId, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, msg: [*c]c.cef_process_message_t, view: message.ViewSize) void {
    const api = browsers.state.api;
    // 지금 주 프레임만(W6m①) — 같은 프로세스의 iframe 문서도 스크립트가 돌지만 자리를 주 프레임 view 로 옮기지 못한다(W6m③).
    if (!isCurrentMain(browser, frame)) return;
    const list = msg.*.get_argument_list.?(msg);
    if (list == null) return;
    defer object.release(list);
    const payload_str = list.*.get_string.?(list, 0);
    if (payload_str == null) return;
    defer api.string_userfree_utf16_free(payload_str);
    const token_str = list.*.get_string.?(list, 1);
    if (token_str == null) return;
    defer api.string_userfree_utf16_free(token_str);
    var token_buf: [32]u8 = undefined;
    const token = library.readString(api, token_str, &token_buf);
    if (token.len != 16) return;
    _ = std.fmt.parseInt(u64, token, 16) catch return;
    const h = heardFor(id);
    // 떠난 문서가 늦게 보낸 것 — 버린다(위 `Heard`).
    if (h) |x| if (x.retired_at_ms != 0 and nowMs() - x.retired_at_ms < retired_ms and std.mem.eql(u8, &x.retired, token)) return;
    if (h) |x| {
        @memcpy(&x.last, token[0..16]);
        x.has_last = true;
    }
    // 넘치는 글은 버리지 않고 닫는다 — 버리면 maru 에 옛 목록이 남는다(렌더러도 넘치면 닫기로 바꿔 보낸다).
    if (payload_str.*.length > renderer.max_datalist_payload_units) return closeFor(id, token);
    const payload = library.readString(api, payload_str, &payload_buf);
    if (payload.len >= payload_buf.len) return closeFor(id, token);
    const parsed = page.parse(payload, view, &items_buf) orelse {
        // 보일 수 없는 목록(view 밖·항목 없음·모양이 틀림) — 그 문서의 목록이 떠 있었으면 닫는다.
        closeFor(id, token);
        return;
    };
    switch (parsed) {
        .hide => closeFor(id, token),
        .show => |s| {
            const slot = shownFor(id) orelse freeSlot() orelse return;
            const list_id = next_list;
            next_list +%= 1;
            if (next_list == 0) next_list = 1;
            var entry: Shown = .{ .browser = id, .list = list_id, .version = s.version };
            const frame_id = frame.*.get_identifier.?(frame);
            if (frame_id == null) return;
            defer api.string_userfree_utf16_free(frame_id);
            const text = library.readString(api, frame_id, &entry.frame_buf);
            if (text.len == 0 or text.len >= entry.frame_buf.len) return;
            entry.frame_len = text.len;
            @memcpy(&entry.token_buf, token[0..16]);
            slot.* = entry;
            browsers.state.writer.send(.{ .datalist_show = .{ .browser = id, .list = list_id, .field = s.field, .count = s.count, .items = s.items } }) catch {};
        },
    }
}

/// 그 문서(표식)의 목록이 떠 있으면 닫는다 — 다른 문서가 보낸 닫기는 지금 목록을 닫지 않는다.
fn closeFor(id: BrowserId, token: []const u8) void {
    const slot = shownFor(id) orelse return;
    if (!std.mem.eql(u8, &slot.*.?.token_buf, token)) return;
    const list_id = slot.*.?.list;
    slot.* = null;
    browsers.state.writer.send(.{ .datalist_hide = .{ .browser = id, .list = list_id } }) catch {};
}

/// 사용자가 골랐다 — 지금 목록이면 그 프레임의 그 문서에 고르라고 보낸다(렌더러가 표식을, 대리 스크립트가 판·초점을 본다).
pub fn pick(value: message.DatalistPick) void {
    const slot = shownFor(value.browser) orelse return;
    const entry = slot.*.?;
    if (entry.list != value.list) return;
    const registered = browsers.state.registry.byId(value.browser) orelse return;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(registered.handle));
    const api = browsers.state.api;
    var frame_id = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &frame_id, entry.frame_buf[0..entry.frame_len]);
    defer api.string_utf16_clear(&frame_id);
    const frame = browser.*.get_frame_by_identifier.?(browser, &frame_id);
    if (frame == null) return;
    defer object.release(frame);
    var name = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &name, renderer.datalist_pick_message);
    defer api.string_utf16_clear(&name);
    const msg = api.process_message_create(&name) orelse return;
    const list = msg.*.get_argument_list.?(msg);
    if (list == null) {
        object.release(msg);
        return;
    }
    defer object.release(list);
    _ = list.*.set_int.?(list, 0, entry.version);
    _ = list.*.set_int.?(list, 1, value.index);
    var token = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &token, &entry.token_buf);
    defer api.string_utf16_clear(&token);
    _ = list.*.set_string.?(list, 2, &token);
    // 넘긴 메시지의 참조는 CEF 로 옮겨 간다.
    frame.*.send_process_message.?(frame, c.PID_RENDERER, msg);
}

/// 주 프레임에 새 문서가 오거나(이동·오류 페이지) 렌더러가 죽었다 — 떠 있던 목록을 닫는다(옛 문서는 닫기를 보내지 못한다).
pub fn reset(id: BrowserId) void {
    // 한 번만 은퇴시킨다 — 그대로 두면 다음 새 문서마다 같은 옛 표식을 다시 은퇴시켜, 뒤로 가기 캐시가 되살린 그 문서의 처음
    // 1 초를 막았다(적대 검증 2 차). 목록을 쓴 적 없는 브라우저에는 칸을 잡지 않는다.
    if (heardOf(id)) |h| if (h.has_last) {
        h.retired = h.last;
        h.retired_at_ms = nowMs();
        h.has_last = false;
    };
    const slot = shownFor(id) orelse return;
    const list_id = slot.*.?.list;
    slot.* = null;
    browsers.state.writer.send(.{ .datalist_hide = .{ .browser = id, .list = list_id } }) catch {};
}

/// 브라우저가 닫혔다 — 알릴 곳이 없으니 기록만 놓는다(maru 는 그 탭의 목록을 함께 버린다).
pub fn forgetBrowser(id: BrowserId) void {
    if (shownFor(id)) |slot| slot.* = null;
    for (&heard) |*slot| {
        if (slot.*) |x| if (x.browser == id) {
            slot.* = null;
        };
    }
}
