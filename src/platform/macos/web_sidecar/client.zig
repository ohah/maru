//! 모든 브라우저가 함께 쓰는 `cef_client_t` 와 처리기들(W1c). CEF 는 콜백에서 browser identifier 로만 브라우저를
//! 알려 주므로 `browsers.state.registry` 에서 maru 의 `BrowserId` 를 찾아 알림을 보낸다.
//!
//! **팝업은 막는다**: 창 없는 브라우저라도 `window.open` 의 기본 동작은 네이티브 Chrome 창이다 — maru 가 통제하지
//! 못하는 창을 sidecar 가 열면 안 된다(탭으로 여는 것은 W3·W6).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");

var client_obj: c.cef_client_t = undefined;
var life_span: c.cef_life_span_handler_t = undefined;
var render: c.cef_render_handler_t = undefined;
var display: c.cef_display_handler_t = undefined;
var load: c.cef_load_handler_t = undefined;
var request: c.cef_request_handler_t = undefined;
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

        client_obj.get_life_span_handler = &getLifeSpan;
        client_obj.get_render_handler = &getRender;
        client_obj.get_display_handler = &getDisplay;
        client_obj.get_load_handler = &getLoad;
        client_obj.get_request_handler = &getRequest;
        life_span.on_before_popup = &onBeforePopup;
        life_span.on_before_close = &onBeforeClose;
        render.get_view_rect = &getViewRect;
        render.get_screen_info = &getScreenInfo;
        render.on_paint = &onPaint;
        render.on_accelerated_paint = &onAcceleratedPaint;
        display.on_title_change = &onTitleChange;
        load.on_load_end = &onLoadEnd;
        request.on_render_process_terminated = &onRenderProcessTerminated;
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

fn onPaint(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, _: c.cef_paint_element_type_t, _: usize, _: [*c]const c.cef_rect_t, _: ?*const anyopaque, _: c_int, _: c_int) callconv(.c) void {
    defer object.releaseArg(browser);
    countPaint(browser);
}

fn onAcceleratedPaint(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, _: c.cef_paint_element_type_t, _: usize, _: [*c]const c.cef_rect_t, _: [*c]const c.cef_accelerated_paint_info_t) callconv(.c) void {
    defer object.releaseArg(browser);
    countPaint(browser);
}

fn onTitleChange(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, title: [*c]const c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(browser);
    const entry = entryOf(browser) orelse return;
    var buf: [protocol.wire.max_text_bytes]u8 = undefined;
    const text = library.readString(browsers.state.api, title, &buf);
    browsers.state.writer.send(.{ .title_changed = .{ .browser = entry.id, .text = text } }) catch {};
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
