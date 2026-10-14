//! 페이지 콘솔(W9c① — CEF `display.on_console_message`, docs/plans/web-osr-backend.md W9c). 줄마다 탭의 양동이(`console_gate`)를
//! **글로 바꾸기 전에** 보고, 지나면 앞부분만 바꿔 다듬어 `console_message` 로 보낸다. 넘쳐 버린 줄은 수만 세어 다음 줄에 싣거나,
//! 쏟아짐이 그치면 `flush_delay_ms` 뒤 버린 수만 실은 frame 으로 보낸다(task 하나 — 브라우저가 몇이든).
//!
//! DevTools(`Runtime.enable`)를 쓰지 않는다 — 페이지가 알아챌 수 있는 봇 신호라 W9a·W5c 가 버렸다. CEF 는 줄의 프레임을 주지 않아
//! iframe(다른 출처도)·worker 의 줄도 온다(WebKit 탭은 주 프레임만 — 작성자 선택, 문서에 적었다). 처리기는 0 을 돌려준다 — Chromium 의
//! 로그 수준(WARNING)이라 1 을 돌려줘도 달라지는 것이 없었다(실측).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const gate = @import("console_gate.zig");
const registry_mod = @import("registry.zig");

const BrowserId = protocol.message.BrowserId;

/// 모든 탭이 함께 쓰는 양동이.
var global: gate.Global = .{};
var flush_task: c.cef_task_t = undefined;
var flush_ready = false;
var flush_posted = false;

fn nowMs() u64 {
    return @import("client.zig").nowMs();
}

pub fn onConsoleMessage(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, severity: c.cef_log_severity_t, message: [*c]const c.cef_string_t, source: [*c]const c.cef_string_t, line: c_int) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (browser == null) return 0;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return 0;
    if (entry.closing) return 0;
    const api = browsers.state.api;
    const now = nowMs();
    const level = gate.levelOf(@intCast(severity));
    const class = gate.classOf(level);
    // 앞 문서의 줄인가 — 방금 떠난 출처가 창 안에 있을 때만 `source` 를 바꾼다(대부분의 줄은 바꾸지 않는다).
    var src_buf: [gate.max_source_units * 3]u8 = undefined;
    var src: ?[]u8 = null;
    var old_document = false;
    if (entry.console.recent.active(now)) {
        src = library.readPrefix(api, source, gate.max_source_units, &src_buf).text;
        var origin: gate.Origin = .{};
        old_document = gate.originOf(src.?, &origin) and entry.console.recent.isOld(origin.slice(), now);
    }
    if (!entry.console.admit(&global, class, old_document, now)) {
        postFlush();
        return 0;
    }
    var raw: [gate.max_message_units * 3]u8 = undefined;
    const msg = library.readPrefix(api, message, gate.max_message_units, &raw);
    // 「Uncaught」 꼬리에만 부른 곳을 싣는다.
    if (src == null and std.mem.startsWith(u8, msg.text, "Uncaught")) src = library.readPrefix(api, source, gate.max_source_units, &src_buf).text;
    var out: [protocol.wire.max_console_text_bytes]u8 = undefined;
    const text = gate.finishText(msg.text, msg.truncated, src orelse "", line, &out);
    entry.console.charge(&global, class, old_document, text.len);
    send(entry, .{ .browser = entry.id, .level = level, .old_document = old_document, .text = text });
    return 0;
}

/// 줄(또는 버린 수만)을 보낸다 — 쌓인 버린 수를 함께 싣고, 보냈으면 비운다. 보내기가 막혔으면(관이 찼다) 모든 탭의 앞 문서 창을 늘린다
/// — 막힌 동안 앞 문서의 줄도 늦게 온다.
fn send(entry: *registry_mod.Entry, template: protocol.message.ConsoleMessage) void {
    var msg = template;
    msg.dropped_errors = entry.console.dropped[0];
    msg.dropped_other = entry.console.dropped[1];
    const t0 = nowMs();
    browsers.state.writer.send(.{ .console_message = msg }) catch return;
    entry.console.dropped = .{ 0, 0 };
    const t1 = nowMs();
    if (t1 -| t0 >= gate.blocked_send_ms) {
        for (&browsers.state.registry.slots) |*slot| if (slot.*) |*e| e.console.recent.sendBlocked(t1);
    }
}

fn sendDrops(entry: *registry_mod.Entry) void {
    if (!entry.console.hasDrops()) return;
    send(entry, .{ .browser = entry.id, .has_entry = false });
}

/// 버린 수만 보낼 task 를 하나만 올린다 — 올리지 못했으면(0) 다음 버림이 다시 해 본다.
fn postFlush() void {
    if (flush_posted) return;
    if (!flush_ready) {
        flush_ready = true;
        flush_task = object.zeroed(c.cef_task_t);
        object.staticRefCounted(&flush_task.base);
        flush_task.execute = &flushDrops;
    }
    if (browsers.state.api.post_delayed_task(c.TID_UI, &flush_task, @intCast(gate.flush_delay_ms)) != 0) flush_posted = true;
}

fn flushDrops(_: [*c]c.cef_task_t) callconv(.c) void {
    flush_posted = false;
    for (&browsers.state.registry.slots) |*slot| if (slot.*) |*entry| {
        if (!entry.closing) sendDrops(entry);
    };
}

/// 주 프레임에 새 문서가 시작된다(`on_load_start`) — `page_started` **앞에** 부른다: 쌓인 버린 수는 앞 문서의 것이고(먼저 보낸다),
/// 떠나는 출처들을 기억한다.
pub fn mainFrameStarted(entry: *registry_mod.Entry, frame: [*c]c.cef_frame_t) void {
    sendDrops(entry);
    var buf: [gate.max_source_units * 3]u8 = undefined;
    entry.console.recent.mainStarted(frameUrl(frame, &buf), nowMs());
}

/// 하위 프레임에 문서가 시작된다 — 지금 문서가 떠날 때 그 출처도 기억한다(다른 출처 iframe 의 unload 줄).
pub fn subframeStarted(entry: *registry_mod.Entry, frame: [*c]c.cef_frame_t) void {
    var buf: [gate.max_source_units * 3]u8 = undefined;
    entry.console.recent.subframeStarted(frameUrl(frame, &buf));
}

/// 주 프레임의 이동이 실패해 오류 페이지가 옛 문서를 바꿨다(`on_load_error` — `page_started` 가 없다). maru 에는 문서 경계로 알린다.
pub fn errorPage(id: BrowserId) void {
    const entry = browsers.state.registry.byId(id) orelse return;
    sendDrops(entry);
    entry.console.recent.errorPage(nowMs());
    browsers.state.writer.send(.{ .error_page = id }) catch {};
}

/// 프레임 주소의 앞부분(출처만 쓴다 — 큰 `data:` 주소를 통째로 바꾸지 않는다).
fn frameUrl(frame: [*c]c.cef_frame_t, buf: []u8) []const u8 {
    const url = frame.*.get_url.?(frame);
    if (url == null) return "";
    defer browsers.state.api.string_userfree_utf16_free(url);
    return library.readPrefix(browsers.state.api, url, gate.max_source_units, buf).text;
}
