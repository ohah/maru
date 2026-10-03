//! 밖에서 끌어 놓기(W6d① — docs/plans/web-osr-backend.md W6). macOS 끌기 세션은 maru 의 view 가 받는다 — maru 는 끌어 온 것을
//! `drag_data` 조각으로 보내고 포인터가 그 탭 본문에 들어오면 `drag_target`(enter·over·leave·drop)을 보낸다. sidecar 는 조각을
//! 브라우저마다 쌓았다가 enter 에서 CEF drag data 를 만들어 `drag_target_drag_enter` 에 넘기고, 페이지가 받아들이는 동작이
//! 바뀌면(`update_drag_cursor`) `drag_operation` 으로 알린다.
//!
//! 규칙(착수 전 실측 — exp/w6d-probe):
//! - 파일은 놓은 뒤에만 페이지에 보인다(끄는 동안 `files.length` 0 — Chromium 의 보호 모드). 폴더는 안의 파일까지 읽힌다(Chrome
//!   과 같다 — 사용자 결정 2026-10-03).
//! - 페이지가 받지 않는 곳에 놓으면 Chromium 이 그 파일·주소로 이동한다(Chrome 과 같다 — 사용자 결정). `javascript:` 주소는
//!   실행하지 않고 `about:blank#blocked` 로 간다. 그렇게 열린 file:// 페이지는 옆 파일을 읽지 못한다.
//! - 새 요소에 처음 들어간 over 는 동작 0 으로 온다 — 놓기 직전 동작이 0 이면 CEF 가 놓기를 나가기로 바꾼다. macOS 는 멈춰
//!   있어도 over 를 계속 보내므로 실제 끌기에는 문제가 없다.
//!
//! enter 없이 온 over·drop 은 버린다(조각만 남은 채 나가면 버린다). 쌓은 조각은 enter·leave·drop·브라우저 닫힘·렌더러 사망에
//! 비운다. 조각 상한 — 경로 `max_paths` 개, 글·HTML 은 각각 `max_text_total` 바이트(넘는 조각은 통째로 버린다 — 조각마다 글자
//! 경계라 남은 글이 UTF-8 로 남는다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const input_map = @import("input_map.zig");

const message = protocol.message;
const allocator = std.heap.c_allocator;

pub const max_paths = 4096;
pub const max_text_total = 1024 * 1024;

// macOS `NSDragOperation` 과 CEF 의 동작 비트가 같다 — maru 는 macOS 값을 그대로 보낸다.
comptime {
    std.debug.assert(c.DRAG_OPERATION_COPY == 1);
    std.debug.assert(c.DRAG_OPERATION_LINK == 2);
    std.debug.assert(c.DRAG_OPERATION_GENERIC == 4);
    std.debug.assert(c.DRAG_OPERATION_PRIVATE == 8);
    std.debug.assert(c.DRAG_OPERATION_MOVE == 16);
    std.debug.assert(c.DRAG_OPERATION_DELETE == 32);
}

/// 브라우저마다 쌓은 조각과 끌기 상태(`registry.Entry.drag` 가 불투명하게 든다).
const Pending = struct {
    paths: std.ArrayList([]u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    url: ?[]u8 = null,
    url_title: ?[]u8 = null,
    /// CEF 에 enter 를 넘겼고 아직 leave·drop 하지 않았다.
    entered: bool = false,

    fn clear(self: *Pending) void {
        for (self.paths.items) |p| allocator.free(p);
        self.paths.clearAndFree(allocator);
        self.text.clearAndFree(allocator);
        self.html.clearAndFree(allocator);
        if (self.url) |u| allocator.free(u);
        if (self.url_title) |t| allocator.free(t);
        self.url = null;
        self.url_title = null;
    }
};

fn pendingOf(entry: *registry_mod.Entry) ?*Pending {
    const raw = entry.drag orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn ensurePending(entry: *registry_mod.Entry) ?*Pending {
    if (pendingOf(entry)) |p| return p;
    const p = allocator.create(Pending) catch return null;
    p.* = .{};
    entry.drag = p;
    return p;
}

/// 끌기 tag 면 수행하고 true.
pub fn handle(msg: message.Message) bool {
    switch (msg) {
        .drag_data => |value| if (liveEntry(value.browser)) |entry| add(entry, value),
        .drag_target => |value| if (liveEntry(value.browser)) |entry| target(entry, value),
        else => return false,
    }
    return true;
}

fn add(entry: *registry_mod.Entry, value: message.DragData) void {
    const p = ensurePending(entry) orelse return;
    switch (value.kind) {
        .path => {
            if (p.paths.items.len >= max_paths) return;
            const copy = allocator.dupe(u8, value.bytes) catch return;
            p.paths.append(allocator, copy) catch allocator.free(copy);
        },
        .text => appendCapped(&p.text, value.bytes),
        .html => appendCapped(&p.html, value.bytes),
        .url => replace(&p.url, value.bytes),
        .url_title => replace(&p.url_title, value.bytes),
    }
}

fn appendCapped(list: *std.ArrayList(u8), bytes: []const u8) void {
    if (list.items.len + bytes.len > max_text_total) return;
    list.appendSlice(allocator, bytes) catch {};
}

fn replace(slot: *?[]u8, bytes: []const u8) void {
    const copy = allocator.dupe(u8, bytes) catch return;
    if (slot.*) |old| allocator.free(old);
    slot.* = copy;
}

fn target(entry: *registry_mod.Entry, value: message.DragTarget) void {
    // enter 의 조각은 그 enter 에만 쓴다 — 아래에서 실패해도(호스트 없음·drag data 못 만듦) 비운다. 남으면 다음 끌기의 조각과
    // 섞여 사용자가 이번에 끌지 않은 파일이 페이지로 갔다(W6d① 적대 검증 1 차).
    defer if (value.kind == .enter) if (pendingOf(entry)) |p| p.clear();
    const cef_browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = cef_browser.*.get_host.?(cef_browser);
    if (host == null) return;
    defer object.release(host);
    var event: c.cef_mouse_event_t = .{ .x = value.point.x, .y = value.point.y, .modifiers = input_map.flags(value.modifiers) };
    const allowed: c.cef_drag_operations_mask_t = @intCast(value.allowed);
    switch (value.kind) {
        .enter => {
            const p = ensurePending(entry) orelse return;
            const data = build(p) orelse return;
            // 새 끌기 — 첫 동작은 같은 값이어도 다시 알린다.
            entry.drag_operation = null;
            // 넘긴 drag data 의 참조 하나가 CEF 로 옮겨 간다(`object.release_callback_args` 주석) — 우리는 풀지 않는다.
            host.*.drag_target_drag_enter.?(host, data, &event, allowed);
            p.entered = true;
        },
        .over => if (pendingOf(entry)) |p| if (p.entered) host.*.drag_target_drag_over.?(host, &event, allowed),
        .leave => if (pendingOf(entry)) |p| {
            if (p.entered) host.*.drag_target_drag_leave.?(host);
            p.entered = false;
            p.clear();
        },
        .drop => if (pendingOf(entry)) |p| {
            if (p.entered) host.*.drag_target_drop.?(host, &event);
            p.entered = false;
            p.clear();
        },
    }
}

/// 쌓은 조각으로 CEF drag data 를 만든다(참조 하나 — 호출자가 CEF 로 넘긴다).
fn build(p: *Pending) ?*c.cef_drag_data_t {
    const api = browsers.state.api;
    const created = api.drag_data_create();
    if (created == null) return null;
    const data: *c.cef_drag_data_t = created;
    for (p.paths.items) |path| {
        var s = std.mem.zeroes(c.cef_string_t);
        library.setString(api, &s, path);
        defer api.string_utf16_clear(&s);
        data.add_file.?(data, &s, null);
    }
    setText(data, p.text.items, data.set_fragment_text.?);
    setText(data, p.html.items, data.set_fragment_html.?);
    if (p.url) |u| setText(data, u, data.set_link_url.?);
    if (p.url_title) |t| setText(data, t, data.set_link_title.?);
    return data;
}

fn setText(data: *c.cef_drag_data_t, bytes: []const u8, setter: anytype) void {
    if (bytes.len == 0) return;
    const api = browsers.state.api;
    var s = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &s, bytes);
    defer api.string_utf16_clear(&s);
    setter(data, &s);
}

/// `render.update_drag_cursor` — 페이지가 받아들이는 동작이 바뀌었다. 비트가 둘 이상이면 가장 낮은 하나(Chromium 은 하나만 준다).
pub fn onUpdateDragCursor(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, operation: c.cef_drag_operations_mask_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    if (entry.closing) return;
    const masked: u32 = @as(u32, @intCast(operation)) & message.drag_operation_mask;
    const one: u32 = if (masked == 0) 0 else masked & (~masked +% 1);
    if (entry.drag_operation) |last| if (last == one) return;
    entry.drag_operation = one;
    browsers.state.writer.send(.{ .drag_operation = .{ .browser = entry.id, .operation = one } }) catch {};
}

/// 브라우저가 닫혔다·렌더러가 죽었다 — 쌓은 조각과 끌기 상태를 버린다(닫힘이면 상태도 푼다).
pub fn reset(entry: *registry_mod.Entry, free: bool) void {
    const p = pendingOf(entry) orelse return;
    p.clear();
    p.entered = false;
    entry.drag_operation = null;
    if (free) {
        allocator.destroy(p);
        entry.drag = null;
    }
}

fn liveEntry(browser: message.BrowserId) ?*registry_mod.Entry {
    const entry = browsers.state.registry.byId(browser) orelse return null;
    if (entry.closing or browsers.state.shutting_down) return null;
    return entry;
}
