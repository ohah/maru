//! 제안 목록(datalist — W6m①), 브라우저 프로세스 쪽. CEF Alloy 에는 Chromium 의 datalist 팝업(브라우저 쪽 자동 완성 UI)이 없어
//! 칸을 누르거나 글자를 쳐도 아무것도 뜨지 않는다(§7 실측). W5c 의 대리 스크립트 길을 같이 쓴다 — 알림 스크립트와 한 스크립트로
//! 넣고(`notifications.install` — 한 문서에서 숨긴 `send` 를 꺼내는 스크립트는 하나여야 한다), datalist 부분은 `send('dl', json)`
//! 로 칸의 자리와 거른 항목을, `send('dl', function)` 으로 「고르기」 함수를 한 번 넘긴다(`renderer.zig`).
//!
//! 규칙은 Chrome 154 실측(§7)을 따른다: 칸을 누르거나(왼쪽 누름) ↓ 를 치면 지금 값으로 거른 목록, 글자를 치면 다시 거른 목록,
//! 지워서 빈 칸이 되거나 일치가 없으면 닫는다. 거르기는 값·레이블에서 대소문자를 무시한 부분 일치, 순서는 원래대로, `disabled`
//! 와 빈 값은 뺀다. 칸이 초점을 잃거나 스크롤·창 크기 바뀜·페이지 떠남이면 닫는다. 고르면 그 값을 넣고 `input`·`change` 를
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
pub fn onMessage(id: BrowserId, frame: [*c]c.cef_frame_t, msg: [*c]c.cef_process_message_t, view: message.ViewSize) void {
    const api = browsers.state.api;
    // 주 프레임만(W6m①) — 같은 프로세스의 iframe 문서도 스크립트가 돌지만 자리를 주 프레임 view 로 옮기지 못한다(W6m③).
    if (frame.*.is_main.?(frame) == 0) return;
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
    if (payload_str.*.length > renderer.max_datalist_payload_units) return;
    const payload_buf = std.heap.c_allocator.alloc(u8, renderer.max_datalist_payload_units * 3) catch return;
    defer std.heap.c_allocator.free(payload_buf);
    const payload = library.readString(api, payload_str, payload_buf);
    if (payload.len >= payload_buf.len) return;
    var items_buf: [message.max_datalist_bytes]u8 = undefined;
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
    const slot = shownFor(id) orelse return;
    const list_id = slot.*.?.list;
    slot.* = null;
    browsers.state.writer.send(.{ .datalist_hide = .{ .browser = id, .list = list_id } }) catch {};
}

/// 브라우저가 닫혔다 — 알릴 곳이 없으니 기록만 놓는다(maru 는 그 탭의 목록을 함께 버린다).
pub fn forgetBrowser(id: BrowserId) void {
    if (shownFor(id)) |slot| slot.* = null;
}
