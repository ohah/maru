//! maru 가 부르는 DevTools 메서드(W9-0b — 에이전트용 브라우저 제어의 바닥). 프로세스 안 DevTools(`send_dev_tools_message`)로
//! 보내고 결과를 조각(`devtools_result_data`)과 끝(`devtools_result`)으로 돌려준다 — 원격 디버깅 포트는 열지 않는다. 호출 표와
//! 메시지 만들기는 `devtools_table.zig`(CEF 를 모르는 부분).
//!
//! - 관찰자는 브라우저마다 처음 부를 때 등록하고 브라우저가 닫힐 때 놓는다(콜백 안에서 등록을 놓지 않는다 — 미디어 메뉴와 같다).
//!   결과는 그 브라우저의 모든 관찰자에게 가므로 제 번호 대역(`devtools_table.id_base`)만 고른다. `on_dev_tools_message` 는 두지
//!   않는다(원시 메시지가 필요 없다 — 결과·떨어짐 콜백만 쓴다).
//! - 답을 못 받는 호출: DevTools 가 떨어지면(`on_dev_tools_agent_detached`)·렌더러가 죽으면(detach 가 오지 않을 수 있다 — 미디어
//!   메뉴 실측)·브라우저가 닫히면 `detached`, 시한(`devtools_stale_ms`)이 지나면 `expired` 로 답한다 — 기다리는 호출이 있는 동안
//!   UI 스레드에 주기 작업을 걸어 본다(새 호출이 올 때만 보면 maru 가 자리를 쥔 채 새 호출을 보내지 않아 영영 풀리지 않는다). 답은
//!   늘 `browser_closed` 앞이다. 판정자는 `MARU_WEB_TEST_DEVTOOLS_STALE_MS` 로 시한을 줄인다.
//! - 결과는 UI 스레드에서 막히는 쓰기로 보낸다 — 상한(16 MiB)까지 보내는 동안 다른 탭도 기다린다. maru 는 결과를 기다리는 동안
//!   한 번에 더 읽는다(`web_osr.pump`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("devtools_table.zig");

const allocator = std.heap.c_allocator;
const BrowserId = message.BrowserId;
const Status = message.DevtoolsStatus;

var table: table_mod.Table = .{};
var registrations: [registry_mod.capacity]?struct { cef_id: c_int, browser: BrowserId, reg: [*c]c.cef_registration_t } = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
var sweep_task: c.cef_task_t = undefined;
var sweep_ready = false;
var sweep_posted = false;

fn initSweep() void {
    if (sweep_ready) return;
    sweep_ready = true;
    sweep_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&sweep_task.base);
    sweep_task.execute = &sweep;
    // 판정자 전용 — 시한을 줄여 `expired` 경로를 잰다.
    if (std.c.getenv("MARU_WEB_TEST_DEVTOOLS_STALE_MS")) |v| {
        table.stale_ms = std.fmt.parseInt(i64, std.mem.span(v), 10) catch table.stale_ms;
    }
}

/// 기다리는 호출이 있으면 시한의 1/4 뒤에 한 번 본다(이미 걸었으면 그대로).
fn ensureSweep() void {
    if (sweep_posted or table.isEmpty()) return;
    sweep_posted = true;
    _ = browsers.state.api.post_delayed_task(c.TID_UI, &sweep_task, @max(@divTrunc(table.stale_ms, 4), 100));
}

fn sweep(_: [*c]c.cef_task_t) callconv(.c) void {
    sweep_posted = false;
    expireStale();
    ensureSweep();
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn answer(browser: BrowserId, call: u32, status: Status) void {
    browsers.state.writer.send(.{ .devtools_result = .{ .browser = browser, .call = call, .status = status, .size = 0 } }) catch {};
}

/// DevTools 명령이면 처리하고 true.
pub fn handle(msg: message.Message) bool {
    switch (msg) {
        .devtools_call => |v| begin(v),
        .devtools_call_data => |v| data(v),
        else => return false,
    }
    return true;
}

fn begin(v: message.DevtoolsCall) void {
    initSweep();
    expireStale();
    if (browsers.state.registry.byId(v.browser) == null) return answer(v.browser, v.call, .unknown_browser);
    const call = table.begin(v, nowMs()) catch |e| return answer(v.browser, v.call, switch (e) {
        error.Busy => .busy,
        error.Duplicate => .invalid_request,
    });
    ensureSweep();
    if (call.complete()) dispatchCall(call);
}

fn data(v: message.DevtoolsData) void {
    switch (table.addData(allocator, v)) {
        .unknown, .more => {},
        .ready => |call| dispatchCall(call),
        .overflow => |call| drop(call, .invalid_request),
        .out_of_memory => |call| drop(call, .send_failed),
    }
}

fn drop(call: *table_mod.Call, status: Status) void {
    var gone = table.take(call);
    defer gone.deinit(allocator);
    answer(gone.browser, gone.call, status);
}

fn expireStale() void {
    const now = nowMs();
    while (table.takeStale(now)) |v| {
        var gone = v;
        defer gone.deinit(allocator);
        answer(gone.browser, gone.call, .expired);
    }
}

fn ensureObserver(host: [*c]c.cef_browser_host_t, cef_id: c_int, browser: BrowserId) bool {
    if (!observer_ready) {
        observer_ready = true;
        observer = object.zeroed(c.cef_dev_tools_message_observer_t);
        object.staticRefCounted(&observer.base);
        observer.on_dev_tools_method_result = &onResult;
        observer.on_dev_tools_agent_detached = &onDetached;
    }
    for (registrations) |r| if (r) |v| if (v.cef_id == cef_id) return true;
    for (&registrations) |*r| if (r.* == null) {
        const reg = host.*.add_dev_tools_message_observer.?(host, &observer);
        if (reg == null) return false;
        r.* = .{ .cef_id = cef_id, .browser = browser, .reg = reg };
        return true;
    };
    return false;
}

fn dispatchCall(call: *table_mod.Call) void {
    const entry = browsers.state.registry.byId(call.browser) orelse return drop(call, .unknown_browser);
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = browser.*.get_host.?(browser);
    if (host == null) return drop(call, .send_failed);
    defer object.release(host);
    if (!ensureObserver(host, entry.cef_id, entry.id)) return drop(call, .send_failed);
    const json = table.buildMessage(allocator, call) catch |e| return drop(call, switch (e) {
        error.InvalidParams => .invalid_request,
        error.OutOfMemory => .send_failed,
    });
    defer allocator.free(json);
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) drop(call, .send_failed);
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    var call = table.takeByCdpId(id) orelse return; // 다른 사용처(권한·알림·미디어 메뉴)의 결과
    defer call.deinit(allocator);
    // 결과 크기는 페이지가 정할 수 있다 — 상한을 넘으면 보내지 않는다.
    if (size > message.max_devtools_result_bytes) return answer(call.browser, call.call, .too_large);
    const bytes: []const u8 = if (result != null) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(message.devtools_chunk_bytes, bytes.len - off);
        browsers.state.writer.send(.{ .devtools_result_data = .{ .browser = call.browser, .call = call.call, .bytes = bytes[off..][0..n] } }) catch return;
        off += n;
    }
    browsers.state.writer.send(.{ .devtools_result = .{
        .browser = call.browser,
        .call = call.call,
        .status = if (success != 0) .ok else .cdp_error,
        .size = @intCast(bytes.len),
    } }) catch {};
}

fn failBrowser(browser: BrowserId) void {
    while (table.takeForBrowser(browser)) |v| {
        var gone = v;
        defer gone.deinit(allocator);
        answer(gone.browser, gone.call, .detached);
    }
}

/// DevTools agent 가 떨어졌다 — 기다리던 답은 오지 않는다. 등록은 브라우저가 닫힐 때 놓는다.
fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    for (registrations) |r| if (r) |v| if (v.cef_id == cef_id) return failBrowser(v.browser);
}

/// 렌더러가 죽었다(detach 가 오지 않을 수 있다) — 그 브라우저의 호출을 끝낸다.
pub fn rendererGone(browser: BrowserId) void {
    failBrowser(browser);
}

/// 닫히는 브라우저 — 호출을 끝내고(`browser_closed` 앞) 관찰자 등록을 놓는다.
pub fn forget(cef_id: c_int, browser: BrowserId) void {
    failBrowser(browser);
    for (&registrations) |*r| if (r.*) |v| if (v.cef_id == cef_id) {
        object.release(v.reg);
        r.* = null;
    };
}
