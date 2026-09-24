//! 모든 브라우저가 함께 쓰는 `cef_client_t` 와 처리기들(W1c). CEF 는 콜백에서 browser identifier 로만 브라우저를
//! 알려 주므로 `browsers.state.registry` 에서 maru 의 `BrowserId` 를 찾아 알림을 보낸다.
//!
//! **팝업은 막는다**: 창 없는 브라우저라도 `window.open` 의 기본 동작은 네이티브 Chrome 창이다 — maru 가 통제하지
//! 못하는 창을 sidecar 가 열면 안 된다(탭으로 여는 것은 W3·W6).
//!
//! **JS 대화상자도 막는다**: `alert`·`confirm`·`prompt` 의 기본 동작도 네이티브 창이고 사용자 제스처 없이 뜬다(적대 검증).
//! 임시 안전 기본값으로 억제한다 — `alert` 는 바로 돌아오고 `confirm`·`prompt` 는 취소로 끝난다. maru 가 대화상자를
//! 그리는 것은 W5(C6)다. 떠나기 확인(beforeunload)은 떠나기로 답한다.
//!
//! **제목은 조절한다**: 같은 제목은 다시 안 보내고, 간격 안의 변경은 마지막 것만 보낸다(`title_gate.zig`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const title_gate = @import("title_gate.zig");

var client_obj: c.cef_client_t = undefined;
var life_span: c.cef_life_span_handler_t = undefined;
var render: c.cef_render_handler_t = undefined;
var display: c.cef_display_handler_t = undefined;
var load: c.cef_load_handler_t = undefined;
var request: c.cef_request_handler_t = undefined;
var jsdialog: c.cef_jsdialog_handler_t = undefined;
var title_task: c.cef_task_t = undefined;
var title_flush_posted = false;
var ready = false;

/// 프로세스 수명 동안 사는 client. 첫 호출에서 채운다(CEF UI 스레드).
pub fn get() *c.cef_client_t {
    if (!ready) {
        ready = true;
        client_obj = object.zeroed(c.cef_client_t);
        object.staticRefCounted(&client_obj.base);
        life_span = object.zeroed(c.cef_life_span_handler_t);
        object.staticRefCounted(&life_span.base);
        render = object.zeroed(c.cef_render_handler_t);
        object.staticRefCounted(&render.base);
        display = object.zeroed(c.cef_display_handler_t);
        object.staticRefCounted(&display.base);
        load = object.zeroed(c.cef_load_handler_t);
        object.staticRefCounted(&load.base);
        request = object.zeroed(c.cef_request_handler_t);
        object.staticRefCounted(&request.base);
        jsdialog = object.zeroed(c.cef_jsdialog_handler_t);
        object.staticRefCounted(&jsdialog.base);
        title_task = object.zeroed(c.cef_task_t);
        object.staticRefCounted(&title_task.base);
        title_task.execute = &flushTitles;

        client_obj.get_life_span_handler = &getLifeSpan;
        client_obj.get_render_handler = &getRender;
        client_obj.get_display_handler = &getDisplay;
        client_obj.get_load_handler = &getLoad;
        client_obj.get_request_handler = &getRequest;
        client_obj.get_jsdialog_handler = &getJsDialog;
        life_span.on_before_popup = &onBeforePopup;
        life_span.on_before_close = &onBeforeClose;
        render.get_view_rect = &getViewRect;
        render.get_screen_info = &getScreenInfo;
        render.on_paint = &onPaint;
        render.on_accelerated_paint = &onAcceleratedPaint;
        display.on_title_change = &onTitleChange;
        display.on_address_change = &onAddressChange;
        load.on_loading_state_change = &onLoadingStateChange;
        load.on_load_end = &onLoadEnd;
        request.on_render_process_terminated = &onRenderProcessTerminated;
        jsdialog.on_jsdialog = &onJsDialog;
        jsdialog.on_before_unload_dialog = &onBeforeUnloadDialog;
    }
    return &client_obj;
}

fn getLifeSpan(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_life_span_handler_t {
    return &life_span;
}
fn getRender(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_render_handler_t {
    return &render;
}
fn getDisplay(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_display_handler_t {
    return &display;
}
fn getLoad(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_load_handler_t {
    return &load;
}
fn getRequest(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_request_handler_t {
    return &request;
}
fn getJsDialog(_: [*c]c.cef_client_t) callconv(.c) [*c]c.cef_jsdialog_handler_t {
    return &jsdialog;
}

fn entryOf(browser: [*c]c.cef_browser_t) ?*@import("registry.zig").Entry {
    if (browser == null) return null;
    return browsers.state.registry.byCefId(browser.*.get_identifier.?(browser));
}

/// 목록에 넣기 전(`create_browser_sync` 안)에 CEF 가 물으면 만드는 중인 크기로 답한다.
fn sizeOf(browser: [*c]c.cef_browser_t) protocol.message.ViewSize {
    if (entryOf(browser)) |entry| return entry.size;
    return browsers.state.creating_size orelse .{ .width = 1, .height = 1, .scale = 1 };
}

fn getViewRect(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, rect: [*c]c.cef_rect_t) callconv(.c) void {
    defer object.releaseArg(browser);
    const size = sizeOf(browser);
    rect.* = .{ .x = 0, .y = 0, .width = @intCast(size.width), .height = @intCast(size.height) };
}

fn getScreenInfo(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, info: [*c]c.cef_screen_info_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    info.*.device_scale_factor = sizeOf(browser).scale;
    return 1;
}

fn countPaint(browser: [*c]c.cef_browser_t) void {
    if (entryOf(browser)) |entry| entry.paints += 1;
}

fn onPaint(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, kind: c.cef_paint_element_type_t, _: usize, _: [*c]const c.cef_rect_t, _: ?*const anyopaque, _: c_int, _: c_int) callconv(.c) void {
    defer object.releaseArg(browser);
    countPaint(browser);
    // D9 — GPU 경로가 아니라 CPU 버퍼로 그렸다. 이 브라우저는 그리지 않고 한 번 알린다(maru 가 그 pane 에 안내한다).
    if (kind != c.PET_VIEW) return;
    const entry = entryOf(browser) orelse return;
    if (entry.gpu_unavailable_sent) return;
    entry.gpu_unavailable_sent = true;
    browsers.state.writer.send(.{ .failure = .{ .browser = entry.id, .code = .gpu_unavailable, .detail = "CEF painted through the CPU path" } }) catch {};
}

fn onAcceleratedPaint(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, kind: c.cef_paint_element_type_t, _: usize, _: [*c]const c.cef_rect_t, info: [*c]const c.cef_accelerated_paint_info_t) callconv(.c) void {
    defer object.releaseArg(browser);
    countPaint(browser);
    // 팝업(PET_POPUP)은 W6 — 본 화면만 링에 넣는다. CEF surface 는 이 콜백 안에서만 유효하다(C3).
    if (kind != c.PET_VIEW or info == null) return;
    const surface = info.*.shared_texture_io_surface orelse return;
    const entry = entryOf(browser) orelse return;
    browsers.deliverFrame(entry, @ptrCast(surface));
}

fn onTitleChange(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, title: [*c]const c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(browser);
    const entry = entryOf(browser) orelse return;
    var buf: [protocol.wire.max_text_bytes]u8 = undefined;
    const text = library.readString(browsers.state.api, title, &buf);
    const now = nowMs();
    switch (entry.title.offer(text, now)) {
        .send => sendTitle(entry.id, text),
        .held => postTitleFlush(entry.title.flushAt().? -| now),
        .duplicate => {},
    }
}

fn sendTitle(id: protocol.message.BrowserId, text: []const u8) void {
    browsers.state.writer.send(.{ .title_changed = .{ .browser = id, .text = text } }) catch {};
}

/// 쥔 제목을 내보낼 task 를 하나만 올린다 — 브라우저가 몇이든 task 는 하나다.
fn postTitleFlush(delay_ms: u64) void {
    if (title_flush_posted) return;
    title_flush_posted = true;
    _ = browsers.state.api.post_delayed_task(c.TID_UI, &title_task, @intCast(@max(delay_ms, 1)));
}

fn flushTitles(_: [*c]c.cef_task_t) callconv(.c) void {
    title_flush_posted = false;
    const now = nowMs();
    var next: ?u64 = null;
    for (&browsers.state.registry.slots) |*slot| {
        if (slot.*) |*entry| {
            if (entry.title.flush(now)) |text| sendTitle(entry.id, text);
            if (entry.title.flushAt()) |at| next = @min(next orelse at, at);
        }
    }
    if (next) |at| postTitleFlush(at -| now);
}

pub fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// 주 프레임 주소만 알린다(주소창). 상한을 넘거나 비었으면 보내지 않는다 — codec 이 거절한다.
fn onAddressChange(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, url: [*c]const c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    if (frame == null or frame.*.is_main.?(frame) == 0) return;
    const entry = entryOf(browser) orelse return;
    var buf: [protocol.wire.max_url_bytes]u8 = undefined;
    const text = library.readString(browsers.state.api, url, &buf);
    if (text.len == 0 or text.len == buf.len) return; // 비었거나 잘렸다(잘린 주소는 다른 주소다)
    browsers.state.writer.send(.{ .url_changed = .{ .browser = entry.id, .url = text } }) catch {};
}

fn onLoadingStateChange(_: [*c]c.cef_load_handler_t, browser: [*c]c.cef_browser_t, loading: c_int, can_go_back: c_int, can_go_forward: c_int) callconv(.c) void {
    defer object.releaseArg(browser);
    const entry = entryOf(browser) orelse return;
    browsers.state.writer.send(.{ .nav_state = .{
        .browser = entry.id,
        .can_go_back = can_go_back != 0,
        .can_go_forward = can_go_forward != 0,
        .loading = loading != 0,
    } }) catch {};
}

fn onLoadEnd(_: [*c]c.cef_load_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, status: c_int) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    if (frame == null or frame.*.is_main.?(frame) == 0) return;
    const entry = entryOf(browser) orelse return;
    browsers.state.writer.send(.{ .load_finished = .{ .browser = entry.id, .http_status = status } }) catch {};
}

fn onRenderProcessTerminated(_: [*c]c.cef_request_handler_t, browser: [*c]c.cef_browser_t, status: c.cef_termination_status_t, _: c_int, _: [*c]const c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(browser);
    const entry = entryOf(browser) orelse return;
    const reason: protocol.message.RendererGoneReason = switch (status) {
        c.TS_PROCESS_WAS_KILLED => .killed,
        c.TS_PROCESS_CRASHED => .crashed,
        c.TS_PROCESS_OOM => .out_of_memory,
        c.TS_LAUNCH_FAILED => .launch_failed,
        c.TS_INTEGRITY_FAILURE => .integrity_failure,
        else => .abnormal,
    };
    browsers.state.writer.send(.{ .renderer_gone = .{ .browser = entry.id, .reason = reason } }) catch {};
}

fn onBeforePopup(
    _: [*c]c.cef_life_span_handler_t,
    browser: [*c]c.cef_browser_t,
    frame: [*c]c.cef_frame_t,
    _: c_int,
    _: [*c]const c.cef_string_t,
    _: [*c]const c.cef_string_t,
    _: c.cef_window_open_disposition_t,
    _: c_int,
    _: [*c]const c.cef_popup_features_t,
    _: [*c]c.cef_window_info_t,
    _: [*c][*c]c.cef_client_t,
    _: [*c]c.cef_browser_settings_t,
    _: [*c][*c]c.cef_dictionary_value_t,
    _: [*c]c_int,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    return 1; // 취소 — 네이티브 창을 열지 않는다.
}

fn onBeforeClose(_: [*c]c.cef_life_span_handler_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    browsers.onClosed(browser.*.get_identifier.?(browser));
}

fn onJsDialog(
    _: [*c]c.cef_jsdialog_handler_t,
    browser: [*c]c.cef_browser_t,
    _: [*c]const c.cef_string_t,
    _: c.cef_jsdialog_type_t,
    _: [*c]const c.cef_string_t,
    _: [*c]const c.cef_string_t,
    callback: [*c]c.cef_jsdialog_callback_t,
    suppress_message: [*c]c_int,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(callback);
    // 헤더 권장 — 억제가 콜백을 바로 부르는 것보다 낫다(Chromium 이 대화상자 남발을 이것으로 가린다).
    suppress_message.* = 1;
    return 0;
}

fn onBeforeUnloadDialog(
    _: [*c]c.cef_jsdialog_handler_t,
    browser: [*c]c.cef_browser_t,
    _: [*c]const c.cef_string_t,
    _: c_int,
    callback: [*c]c.cef_jsdialog_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(callback);
    callback.*.cont.?(callback, 1, null);
    return 1;
}
