//! 다운로드(W10a), 브라우저 프로세스 쪽. 처리기가 없으면 CEF Alloy 는 모든 다운로드를 조용히 취소한다(§7 실측). 여기서는 받기만
//! 이어 주고 정하지 않는다 — 다운로드마다 `download_begin` 을 maru 에 보내고 `on_before_download` 의 콜백을 maru 의 `download_decide`
//! 까지 쥔다. 경로는 maru 만 정한다(maru 가 미리 만든 임시 파일 — 그 경로로만 받는다). 진행은 `download_update` 로(초당 4 번까지,
//! 상태가 바뀌면 늘), 취소·다시 받기는 마지막 진행 갱신의 item 콜백으로 한다.
//!
//! CEF 154 실측(2026-10-08, 탐침): `can_download` → 진행 갱신(경로 없음) → `on_before_download`(제안 이름·MIME·크기) → `cont` → 진행 →
//! 완료. 받는 동안 그 경로의 파일이 자라고, 완료 때 Chromium 이 격리 표지(`com.apple.quarantine`)·출처(`kMDItemWhereFroms`)를 붙인다
//! (받는 도중에는 없다). 같은 경로면 덮어쓴다. 취소하면 덜 받은 파일을 지운다(이유 40). **브라우저를 닫으면 그 다운로드가 아무 알림
//! 없이 멈추고 파일이 지워진다** — 닫힐 때 여기서 `browser_closed` 로 알린다. `interrupted` 는 끝이 아니다(이유 38 — 길이가 어긋난
//! 응답은 Chromium 이 스스로 다시 받는다).
//!
//! 서버·페이지가 정한 글(제안 이름·MIME·주소)은 보내기 전에 다듬는다(`fields.tidyDownload*` — 제어 문자·잘린 UTF-8·상한 초과가
//! 코덱에 막혀 다운로드가 붙들린 채 멈추거나 maru 가 sidecar 를 다시 띄우지 않게, W10a 설계 적대 검토).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");

const message = protocol.message;
const fields = protocol.fields;
const BrowserId = message.BrowserId;

pub var handler: c.cef_download_handler_t = undefined;
var ready = false;

pub fn get() *c.cef_download_handler_t {
    if (!ready) {
        ready = true;
        handler = object.zeroed(c.cef_download_handler_t);
        object.staticRefCounted(&handler.base);
        handler.can_download = &canDownload;
        handler.on_before_download = &onBeforeDownload;
        handler.on_download_updated = &onUpdated;
    }
    return &handler;
}

/// 진행 알림 사이의 최소 간격(같은 상태일 때) — 초당 4 번.
const progress_interval_ms: i64 = 250;

const Slot = struct {
    download: u32,
    browser: BrowserId,
    /// maru 의 결정을 기다리는 동안 쥔 콜백(`on_before_download`) — 결정하거나 브라우저가 닫히면 놓는다(쓰지 않고 놓으면 취소).
    before: [*c]c.cef_before_download_callback_t = null,
    /// 마지막 진행 갱신의 item 콜백(취소·다시 받기용) — 끝(완료·취소)이나 브라우저가 닫히면 놓는다.
    item: [*c]c.cef_download_item_callback_t = null,
    /// 결정 직후 첫 진행 갱신(item 콜백) 전에 온 취소 — 그 갱신에서 취소한다(버리지 않게 — W10a 적대 리뷰 1 회차).
    cancel_pending: bool = false,
    last_state: ?message.DownloadState = null,
    last_sent_ms: i64 = 0,
    received: i64 = 0,
    total: i64 = -1,
};

/// 동시에 쥐는 다운로드 상한 — 넘치면 받지 않는다(maru 의 동시 상한보다 넉넉히).
const max_slots = 64;
var slots: [max_slots]?Slot = [_]?Slot{null} ** max_slots;

fn slotOf(download: u32) ?*Slot {
    for (&slots) |*slot| {
        if (slot.*) |*s| if (s.download == download) return s;
    }
    return null;
}

fn freeSlot() ?*?Slot {
    for (&slots) |*slot| if (slot.* == null) return slot;
    return null;
}

fn release(s: *Slot) void {
    object.release(s.before);
    s.before = null;
    object.release(s.item);
    s.item = null;
}

fn drop(download: u32) void {
    for (&slots) |*slot| {
        if (slot.*) |*s| if (s.download == download) {
            release(s);
            slot.* = null;
            return;
        };
    }
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn entryOf(browser: [*c]c.cef_browser_t) ?*@import("registry.zig").Entry {
    if (browser == null) return null;
    return browsers.state.registry.byCefId(browser.*.get_identifier.?(browser));
}

/// 닫히는 중이거나 모르는 브라우저의 다운로드는 받지 않는다.
fn canDownload(_: [*c]c.cef_download_handler_t, browser: [*c]c.cef_browser_t, _: [*c]const c.cef_string_t, _: [*c]const c.cef_string_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    const entry = entryOf(browser) orelse return 0;
    return @intFromBool(!entry.closing);
}

fn readUserfree(value: c.cef_string_userfree_t, buf: []u8) []const u8 {
    if (value == null) return "";
    defer browsers.state.api.string_userfree_utf16_free(value);
    return library.readString(browsers.state.api, value, buf);
}

fn onBeforeDownload(_: [*c]c.cef_download_handler_t, browser: [*c]c.cef_browser_t, item: [*c]c.cef_download_item_t, suggested: [*c]const c.cef_string_t, callback: [*c]c.cef_before_download_callback_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(item);
    const entry = entryOf(browser) orelse {
        object.releaseArg(callback); // 쓰지 않고 놓으면 취소
        return 1;
    };
    const download = item.*.get_id.?(item);
    if (entry.closing or download == 0 or slotOf(download) != null) {
        object.releaseArg(callback);
        return 1;
    }
    const slot = freeSlot() orelse {
        object.releaseArg(callback);
        return 1;
    };
    var raw_name: [1024]u8 = undefined;
    var raw_url: [message.max_download_url_bytes + 8]u8 = undefined;
    var raw_mime: [256]u8 = undefined;
    var name_buf: [message.max_download_name_bytes]u8 = undefined;
    var url_buf: [message.max_download_url_bytes]u8 = undefined;
    var mime_buf: [message.max_download_mime_bytes]u8 = undefined;
    const name = fields.tidyDownloadName(library.readString(browsers.state.api, suggested, &raw_name), &name_buf);
    const url = fields.tidyDownloadText(readUserfree(item.*.get_url.?(item), &raw_url), message.max_download_url_bytes, &url_buf);
    const mime = fields.tidyDownloadText(readUserfree(item.*.get_mime_type.?(item), &raw_mime), message.max_download_mime_bytes, &mime_buf);
    const total_raw = item.*.get_total_bytes.?(item);
    const total: i64 = if (total_raw < 0) -1 else total_raw;
    slot.* = .{ .download = download, .browser = entry.id, .before = callback, .total = total };
    browsers.state.writer.send(.{ .download_begin = .{ .browser = entry.id, .download = download, .url = url, .name = name, .mime = mime, .total = total } }) catch {
        drop(download);
    };
    return 1;
}

fn stateOf(item: [*c]c.cef_download_item_t) message.DownloadState {
    if (item.*.is_complete.?(item) != 0) return .complete;
    if (item.*.is_canceled.?(item) != 0) return .canceled;
    if (item.*.is_interrupted.?(item) != 0) return .interrupted;
    return .in_progress;
}

fn onUpdated(_: [*c]c.cef_download_handler_t, browser: [*c]c.cef_browser_t, item: [*c]c.cef_download_item_t, callback: [*c]c.cef_download_item_callback_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(item);
    // `on_before_download` 전의 갱신(실측)은 maru 가 모르는 다운로드라 보내지 않는다.
    const s = slotOf(item.*.get_id.?(item)) orelse {
        object.releaseArg(callback);
        return;
    };
    object.release(s.item);
    s.item = callback;
    if (s.cancel_pending and callback != null) {
        s.cancel_pending = false;
        callback.*.cancel.?(callback);
    }
    const state = stateOf(item);
    const received = item.*.get_received_bytes.?(item);
    const total_raw = item.*.get_total_bytes.?(item);
    s.received = @max(received, 0);
    s.total = if (total_raw < 0) -1 else total_raw;
    const terminal = state == .complete or state == .canceled;
    const now = nowMs();
    if (!terminal and s.last_state == state and now - s.last_sent_ms < progress_interval_ms) return;
    s.last_state = state;
    s.last_sent_ms = now;
    const reason_raw = item.*.get_interrupt_reason.?(item);
    const reason: u16 = if (reason_raw < 0 or reason_raw > std.math.maxInt(u16)) 0 else @intCast(reason_raw);
    browsers.state.writer.send(.{ .download_update = .{ .browser = s.browser, .download = s.download, .state = state, .received = s.received, .total = s.total, .reason = reason } }) catch {};
    if (terminal) drop(s.download);
}

/// maru 가 경로를 정했다(빈 경로 = 받지 않는다). 그 브라우저의 기다리는 다운로드일 때만.
pub fn decide(value: message.DownloadDecide) void {
    const s = slotOf(value.download) orelse return;
    if (s.browser != value.browser) return;
    const cb = s.before;
    if (cb == null) return;
    s.before = null;
    defer object.release(cb);
    if (value.path.len == 0) {
        // 쓰지 않고 놓는다 = 취소. 진행 갱신이 오지 않을 수 있어 여기서 알리고 놓는다.
        browsers.state.writer.send(.{ .download_update = .{ .browser = s.browser, .download = s.download, .state = .canceled, .received = 0, .total = s.total, .reason = 0 } }) catch {};
        drop(s.download);
        return;
    }
    var path = std.mem.zeroes(c.cef_string_t);
    library.setString(browsers.state.api, &path, value.path);
    defer browsers.state.api.string_utf16_clear(&path);
    cb.*.cont.?(cb, &path, 0);
}

/// 사용자가 취소·다시 받기를 눌렀다 — 그 브라우저의 다운로드이고 진행 갱신을 받은 뒤일 때만.
pub fn control(value: message.DownloadControl) void {
    const s = slotOf(value.download) orelse return;
    if (s.browser != value.browser) return;
    if (s.before != null and value.action == .cancel) {
        // 아직 결정 전 — 받지 않는다.
        decide(.{ .browser = value.browser, .download = value.download, .path = "" });
        return;
    }
    const cb = s.item;
    if (cb == null) {
        if (value.action == .cancel) s.cancel_pending = true;
        return;
    }
    switch (value.action) {
        .cancel => cb.*.cancel.?(cb),
        .resume_download => cb.*.@"resume".?(cb),
    }
}

/// 브라우저가 닫혔다 — 그 다운로드는 CEF 가 알림 없이 멈추고 파일을 지운다(실측). maru 에 알리고 쥔 콜백을 놓는다.
pub fn browserClosed(id: BrowserId) void {
    for (&slots) |*slot| {
        if (slot.*) |*s| if (s.browser == id) {
            browsers.state.writer.send(.{ .download_update = .{ .browser = s.browser, .download = s.download, .state = .browser_closed, .received = s.received, .total = s.total, .reason = 0 } }) catch {};
            release(s);
            slot.* = null;
        };
    }
}
