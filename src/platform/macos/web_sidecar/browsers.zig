//! 브라우저 명령 수행(W1c) — maru 의 create·destroy·resize·set_hidden·set_focus·navigate 를 CEF 호출로 옮긴다.
//! 모두 CEF UI 스레드에서 돈다(명령은 `dispatch.zig` 가, 콜백은 CEF 가 그 스레드에서 부른다).
//!
//! 종료: 열린 브라우저가 있는 채로 CEF 를 내리면 안 된다 — `beginShutdown` 이 모두 닫기를 요청하고, 마지막
//! `on_before_close` 에서 메시지 루프를 끝낸다. 닫힘이 멈추면 `shutdown_grace_ms` 뒤 그래도 끝내고, UI 스레드마저
//! 멈추면 `watchdog.zig` 가 프로세스를 끝낸다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const events = @import("events.zig");
const dispatch = @import("dispatch.zig");
const registry_mod = @import("registry.zig");
const client = @import("client.zig");
const watchdog = @import("watchdog.zig");

const Message = protocol.message.Message;
const BrowserId = protocol.message.BrowserId;
const ViewSize = protocol.message.ViewSize;
const FailureCode = protocol.message.FailureCode;

const shutdown_grace_ms = 5000;

pub const State = struct {
    api: *const library.Api,
    writer: *events.Writer,
    registry: registry_mod.Registry = .{},
    /// `create_browser_sync` 가 돌아와 목록에 넣기 전에도 CEF 가 view 크기를 묻는다 — 그때 답할 크기.
    creating_size: ?ViewSize = null,
    shutting_down: bool = false,
    quit_requested: bool = false,
};

pub var state: State = undefined;
var grace_task: c.cef_task_t = undefined;

pub fn init(api: *const library.Api, writer: *events.Writer) void {
    state = .{ .api = api, .writer = writer };
    grace_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&grace_task.base);
    grace_task.execute = &graceExpired;
}

pub fn handler() dispatch.Handler {
    return .{ .context = undefined, .browser_command = &command };
}

fn command(_: *anyopaque, message: Message, writer: *events.Writer) void {
    if (state.shutting_down) return;
    switch (message) {
        .create_browser => |value| create(value, writer),
        .destroy_browser => |browser| destroy(browser, writer),
        .resize => |value| resize(value, writer),
        .set_hidden => |value| if (hostFor(value.browser, writer)) |host| {
            defer object.release(host);
            host.*.was_hidden.?(host, @intFromBool(value.value));
        },
        .set_focus => |value| if (hostFor(value.browser, writer)) |host| {
            defer object.release(host);
            host.*.set_focus.?(host, @intFromBool(value.value));
        },
        .navigate => |value| navigate(value, writer),
        else => {},
    }
}

fn create(value: protocol.message.CreateBrowser, writer: *events.Writer) void {
    if (state.registry.byId(value.browser) != null) return fail(writer, value.browser, .duplicate_browser, "browser id already exists");
    if (state.registry.full()) return fail(writer, value.browser, .browser_create_failed, "too many browsers");

    var window_info = object.zeroed(c.cef_window_info_t);
    window_info.windowless_rendering_enabled = 1;
    window_info.shared_texture_enabled = 1;
    var settings = object.zeroed(c.cef_browser_settings_t);
    settings.windowless_frame_rate = 60;
    var url = std.mem.zeroes(c.cef_string_t);
    library.setString(state.api, &url, value.url);
    defer state.api.string_utf16_clear(&url);

    state.creating_size = value.size;
    defer state.creating_size = null;
    const browser = state.api.browser_host_create_browser_sync(&window_info, client.get(), &url, &settings, null, null);
    if (browser == null) return fail(writer, value.browser, .browser_create_failed, "CEF refused to create the browser");

    const cef_id = browser.*.get_identifier.?(browser);
    state.registry.add(.{ .id = value.browser, .cef_id = cef_id, .handle = @ptrCast(browser), .size = value.size }) catch {
        // 위에서 확인했으니 오지 않는다 — 와도 새지 않게 닫는다.
        closeBrowser(browser);
        object.release(browser);
        return fail(writer, value.browser, .browser_create_failed, "registry refused the browser");
    };
    if (value.hidden) {
        const host = browser.*.get_host.?(browser);
        defer object.release(host);
        host.*.was_hidden.?(host, 1);
    }
    writer.send(.{ .browser_created = value.browser }) catch {};
}

fn destroy(browser_id: BrowserId, writer: *events.Writer) void {
    const entry = state.registry.byId(browser_id) orelse return fail(writer, browser_id, .unknown_browser, "no such browser");
    if (entry.closing) return;
    entry.closing = true;
    closeBrowser(browserOf(entry));
}

fn resize(value: protocol.message.Resize, writer: *events.Writer) void {
    const entry = state.registry.byId(value.browser) orelse return fail(writer, value.browser, .unknown_browser, "no such browser");
    const scale_changed = entry.size.scale != value.size.scale;
    entry.size = value.size;
    const browser = browserOf(entry);
    const host = browser.*.get_host.?(browser);
    defer object.release(host);
    if (scale_changed) host.*.notify_screen_info_changed.?(host);
    host.*.was_resized.?(host);
}

fn navigate(value: protocol.message.Navigate, writer: *events.Writer) void {
    const entry = state.registry.byId(value.browser) orelse return fail(writer, value.browser, .unknown_browser, "no such browser");
    const browser = browserOf(entry);
    const frame = browser.*.get_main_frame.?(browser);
    if (frame == null) return fail(writer, value.browser, .unknown_browser, "browser has no main frame");
    defer object.release(frame);
    var url = std.mem.zeroes(c.cef_string_t);
    library.setString(state.api, &url, value.url);
    defer state.api.string_utf16_clear(&url);
    frame.*.load_url.?(frame, &url);
}

/// 모두 닫기를 요청한다. 열린 브라우저가 없으면 바로 루프를 끝낸다.
pub fn beginShutdown() void {
    if (state.shutting_down) return;
    state.shutting_down = true;
    watchdog.start();
    for (&state.registry.slots) |*slot| {
        if (slot.*) |*entry| if (!entry.closing) {
            entry.closing = true;
            closeBrowser(browserOf(entry));
        };
    }
    if (state.registry.count() == 0) return quit();
    _ = state.api.post_delayed_task(c.TID_UI, &grace_task, shutdown_grace_ms);
}

/// `on_before_close` 에서 부른다 — 목록이 쥔 참조를 풀고 maru 에 알린다.
pub fn onClosed(cef_id: c_int) void {
    if (state.registry.remove(cef_id)) |entry| {
        const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
        object.release(browser);
        state.writer.send(.{ .browser_closed = entry.id }) catch {};
    }
    if (state.shutting_down and state.registry.count() == 0) quit();
}

fn graceExpired(_: [*c]c.cef_task_t) callconv(.c) void {
    if (state.registry.count() != 0) std.debug.print("maru-web-host: {d} browser(s) did not close in time, quitting anyway\n", .{state.registry.count()});
    quit();
}

fn quit() void {
    if (state.quit_requested) return;
    state.quit_requested = true;
    state.api.quit_message_loop();
}

fn browserOf(entry: *registry_mod.Entry) [*c]c.cef_browser_t {
    return @ptrCast(@alignCast(entry.handle));
}

fn hostFor(browser_id: BrowserId, writer: *events.Writer) ?[*c]c.cef_browser_host_t {
    const entry = state.registry.byId(browser_id) orelse {
        fail(writer, browser_id, .unknown_browser, "no such browser");
        return null;
    };
    const browser = browserOf(entry);
    return browser.*.get_host.?(browser);
}

fn closeBrowser(browser: [*c]c.cef_browser_t) void {
    const host = browser.*.get_host.?(browser);
    defer object.release(host);
    // 강제 닫기 — 페이지의 beforeunload 가 닫힘을 붙잡지 못하게(대화상자는 W5).
    host.*.close_browser.?(host, 1);
}

fn fail(writer: *events.Writer, browser: BrowserId, code: FailureCode, detail: []const u8) void {
    writer.send(.{ .failure = .{ .browser = browser, .code = code, .detail = detail } }) catch {};
}
