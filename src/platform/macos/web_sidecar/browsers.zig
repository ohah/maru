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
const ring_producer = @import("ring_producer.zig");
const iosurface = @import("iosurface.zig");
const input = @import("input.zig");

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
    /// maru 의 받는 port(W2). 오기 전의 그리기는 링에 쥐어 두었다가 오면 알린다(`ring_producer` 의 `pending`).
    channel: ?ring_producer.Channel = null,
    ring_retry_posted: bool = false,
};

pub var state: State = undefined;
var grace_task: c.cef_task_t = undefined;
var ring_retry_task: c.cef_task_t = undefined;

pub fn init(api: *const library.Api, writer: *events.Writer) void {
    state = .{ .api = api, .writer = writer };
    grace_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&grace_task.base);
    grace_task.execute = &graceExpired;
    ring_retry_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&ring_retry_task.base);
    ring_retry_task.execute = &retryRings;
}

pub fn handler() dispatch.Handler {
    return .{ .context = undefined, .browser_command = &command };
}

fn command(_: *anyopaque, message: Message, writer: *events.Writer) void {
    if (state.shutting_down) return;
    if (input.handle(message)) return;
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
        .nav_action => |value| navAction(value, writer),
        .frame_channel => |value| frameChannel(value, writer),
        else => {},
    }
}

fn create(value: protocol.message.CreateBrowser, writer: *events.Writer) void {
    if (state.registry.byId(value.browser) != null) return fail(writer, value.browser, .duplicate_browser, "browser id already exists");
    if (state.registry.full()) return fail(writer, value.browser, .browser_create_failed, "too many browsers");

    var window_info = object.zeroed(c.cef_window_info_t);
    window_info.windowless_rendering_enabled = 1;
    // 판정자 전용(`MARU_WEB_TEST_CPU_PAINT`): 공유 텍스처를 꺼 CEF 가 CPU 경로(`on_paint`)로 그리게 한다 — D9 거부 경로를
    // 재현하는 유일한 방법이다(`--disable-gpu` 로도 GPU 경로였다, 실측). 제품 사용자가 켤 이유는 없다.
    window_info.shared_texture_enabled = if (std.c.getenv("MARU_WEB_TEST_CPU_PAINT") != null) 0 else 1;
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
    const producer = std.heap.c_allocator.create(ring_producer.Producer) catch {
        closeBrowser(browser);
        object.release(browser);
        return fail(writer, value.browser, .browser_create_failed, "out of memory");
    };
    producer.* = .{ .browser = value.browser, .scale = value.size.scale };
    state.registry.add(.{ .id = value.browser, .cef_id = cef_id, .handle = @ptrCast(browser), .size = value.size, .frames = producer }) catch {
        std.heap.c_allocator.destroy(producer);
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
    producerOf(entry).scale = value.size.scale;
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

/// 뒤로·앞으로·새로고침·멈춤(W3b — 주소창 버튼). 갈 곳이 없으면 CEF 가 무시한다.
fn navAction(value: protocol.message.NavAction, writer: *events.Writer) void {
    const entry = state.registry.byId(value.browser) orelse return fail(writer, value.browser, .unknown_browser, "no such browser");
    const browser = browserOf(entry);
    switch (value.action) {
        .back => browser.*.go_back.?(browser),
        .forward => browser.*.go_forward.?(browser),
        .reload => browser.*.reload.?(browser),
        .stop => browser.*.stop_load.?(browser),
    }
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
        if (entry.frames) |frames| {
            const producer: *ring_producer.Producer = @ptrCast(@alignCast(frames));
            producer.deinit();
            std.heap.c_allocator.destroy(producer);
        }
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

fn producerOf(entry: *registry_mod.Entry) *ring_producer.Producer {
    return @ptrCast(@alignCast(entry.frames.?));
}

/// 받는 port 를 (다시) 정한다. 두 번째면 옛 권리를 놓고, 이미 있는 링을 새 받는 쪽에 다시 알린다 — 그리기가 멈춘 정적
/// 페이지도 받는 port 가 늦게 오거나 바뀐 뒤 링을 받는다.
fn frameChannel(value: protocol.message.FrameChannel, writer: *events.Writer) void {
    const fresh = ring_producer.Channel.connect(value.service, value.token) catch return fail(writer, 0, .frame_channel_failed, "cannot look up the frame channel");
    if (state.channel) |old| {
        old.close();
        for (&state.registry.slots) |*slot| {
            if (slot.*) |*entry| producerOf(entry).reannounce();
        }
    }
    state.channel = fresh;
    postRingRetry(0);
}

/// 그리기 콜백에서 부른다 — 본 화면 픽셀을 이 브라우저의 링에 넣는다. 아직 못 알린 링이면 재시도를 건다.
pub fn deliverFrame(entry: *registry_mod.Entry, source: iosurface.Ref) void {
    const channel: ?*const ring_producer.Channel = if (state.channel) |*channel| channel else null;
    const now = client.nowMs();
    const painted = producerOf(entry).paint(channel, source, now) catch |err| {
        std.debug.print("maru-web-host: frame for browser {d} dropped: {s}\n", .{ entry.id, @errorName(err) });
        return;
    };
    if (painted == .pending) if (producerOf(entry).retryAt()) |at| postRingRetry(at -| now);
}

/// 못 알린 링을 다시 알릴 task 를 하나만 올린다. 받는 port 가 없으면 올리지 않는다(`frame_channel` 이 올린다).
fn postRingRetry(delay_ms: u64) void {
    if (state.channel == null or state.ring_retry_posted) return;
    state.ring_retry_posted = true;
    _ = state.api.post_delayed_task(c.TID_UI, &ring_retry_task, @intCast(@max(delay_ms, 1)));
}

fn retryRings(_: [*c]c.cef_task_t) callconv(.c) void {
    state.ring_retry_posted = false;
    const channel: ?*const ring_producer.Channel = if (state.channel) |*channel| channel else null;
    const now = client.nowMs();
    var next: ?u64 = null;
    for (&state.registry.slots) |*slot| {
        if (slot.*) |*entry| {
            const producer = producerOf(entry);
            if (producer.flush(channel, now) == .pending) {
                if (producer.retryAt()) |at| next = @min(next orelse at, at);
            }
        }
    }
    if (next) |at| postRingRetry(at -| now);
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
