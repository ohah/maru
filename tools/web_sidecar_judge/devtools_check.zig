//! W9-0b 판정 — maru 가 그 브라우저의 프로세스 안 DevTools 에 메서드를 부르고 결과를 조각으로 받는가(docs/plans/web-osr-backend.md
//! W9). 판정자가 **maru 역할**로 `devtools_call`·`devtools_call_data` 를 보내고 `devtools_result_data`·`devtools_result` 를 받는다.
//!
//!   dt-eval            `Runtime.evaluate` 1+1 → ok, 결과 `{"result":{"type":"number","value":2,…}}`, 알린 크기 = 받은 조각의 합
//!   dt-no-params       인자 없는 `Page.enable` → ok(`{}`)
//!   dt-params-chunked  40 000 바이트 인자(조각 셋)를 모아 부른다 — 그 글의 길이가 결과로 온다
//!   dt-result-chunked  100 000 글자 결과가 조각(16 KiB 이하)으로 와 다시 모은 것이 JSON 이고 길이가 맞다
//!   dt-cdp-error       없는 메서드 → cdp_error, 결과는 CDP 의 `error` 객체(-32601)
//!   dt-invalid-params  JSON 객체가 아닌 인자(`[1]`·`1},"id":7`)는 부르지 않고 invalid_request — 이어 붙여 메시지를 바꾸지 못한다
//!   dt-overflow        알린 크기보다 많은 인자 조각 → invalid_request
//!   dt-unknown         없는 브라우저 → unknown_browser
//!   dt-too-large       16 MiB 를 넘는 결과는 조각 없이 too_large
//!   dt-big-result-time 8 MiB 결과를 sidecar 가 다 써 보내는 시간(판정자는 바로 읽는다 — maru 의 tick 예산 지연은 재지 않는다)
//!   dt-busy            탭마다 상한(2)을 넘으면 busy
//!   dt-busy-other-tab  그 탭이 상한이어도 다른 탭은 부를 수 있다(멈춘 페이지 하나가 다른 탭을 막지 못한다)
//!   dt-closed          인자를 다 받지 못한 호출과 CDP 로 보내 답을 기다리는 호출이 브라우저를 닫으면 `browser_closed` **앞에** detached
//!   dt-renderer-gone   답을 기다리는 호출(끝나지 않는 Promise)이 렌더러가 죽으면 detached 로 끝난다
//!   dt-expired         시한을 줄인 host(`MARU_WEB_TEST_DEVTOOLS_STALE_MS`)에서 답이 오지 않는 호출이 새 호출 없이도 expired 로 끝난다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 31;
const wait_ms = 15_000;
const Status = protocol.message.DevtoolsStatus;
const chunk = protocol.message.devtools_chunk_bytes;

const Done = struct {
    status: Status,
    size: u32,
    chunks: u32,
    max_chunk: usize,
};

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    next_call: u32 = 0,
    result: std.ArrayList(u8) = .empty,
    created: bool = false,
    loaded: bool = false,
    renderer_gone: u32 = 0,
    closed: bool = false,
    /// `browser_closed` 앞에 온 detached 수.
    detached_before_close: u32 = 0,

    fn deinit(self: *Run) void {
        self.result.deinit(self.gpa);
    }

    fn other(self: *Run, message: protocol.message.Message) void {
        switch (message) {
            .browser_created => |id| if (id == browser_id) {
                self.created = true;
            },
            .load_finished => |v| if (v.browser == browser_id) {
                self.loaded = true;
            },
            .renderer_gone => |v| if (v.browser == browser_id) {
                self.renderer_gone += 1;
            },
            .browser_closed => |id| if (id == browser_id) {
                self.closed = true;
            },
            .devtools_result => |v| if (v.browser == browser_id and v.status == .detached and !self.closed) {
                self.detached_before_close += 1;
            },
            else => {},
        }
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.other(m);
        }
    }

    fn until(self: *Run, comptime field: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !@field(self, field)) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.other(m);
        }
        return @field(self, field);
    }

    fn begin(self: *Run, browser: u64, method: []const u8, params_size: u32) !u32 {
        self.next_call += 1;
        try self.host.send(.{ .devtools_call = .{ .browser = browser, .call = self.next_call, .method = method, .params_size = params_size } });
        return self.next_call;
    }

    fn data(self: *Run, browser: u64, call_id: u32, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(chunk, bytes.len - off);
            try self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = call_id, .bytes = bytes[off..][0..n] } });
            off += n;
        }
    }

    fn call(self: *Run, method: []const u8, params: []const u8) !u32 {
        const c = try self.begin(browser_id, method, @intCast(params.len));
        try self.data(browser_id, c, params);
        return c;
    }

    /// 그 호출의 끝까지 조각을 모은다(`result` 에). 시간 안에 안 오면 null.
    fn wait(self: *Run, call_id: u32, ms: u32) ?Done {
        self.result.clearRetainingCapacity();
        var chunks: u32 = 0;
        var max_chunk: usize = 0;
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(50) catch null) orelse continue;
            switch (m) {
                .devtools_result_data => |v| if (v.call == call_id) {
                    self.result.appendSlice(self.gpa, v.bytes) catch return null;
                    chunks += 1;
                    max_chunk = @max(max_chunk, v.bytes.len);
                    continue;
                },
                .devtools_result => |v| if (v.call == call_id) {
                    self.other(m);
                    return .{ .status = v.status, .size = v.size, .chunks = chunks, .max_chunk = max_chunk };
                },
                else => {},
            }
            self.other(m);
        }
        return null;
    }

    fn json(self: *Run) ?std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch null;
    }
};

fn statusName(d: ?Done) []const u8 {
    return if (d) |v| @tagName(v.status) else "답 없음";
}

/// `{"result":{"value":X}}` 의 X(정수) 또는 문자열 길이.
fn evalValue(parsed: std.json.Parsed(std.json.Value)) ?i64 {
    const root = parsed.value;
    if (root != .object) return null;
    const r = root.object.get("result") orelse return null;
    if (r != .object) return null;
    const v = r.object.get("value") orelse return null;
    return switch (v) {
        .integer => |i| i,
        .string => |s| @intCast(s.len),
        else => null,
    };
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, expired_profile_arg: [:0]const u8, port: u16) !void {
    var detail: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    const gpa = std.heap.c_allocator;

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/static") } });
    var r: Run = .{ .host = &host, .gpa = gpa };
    defer r.deinit();
    if (!r.until("created", wait_ms)) return error.BrowserNotCreated;
    _ = r.until("loaded", wait_ms);

    // dt-eval
    {
        const c = try r.call("Runtime.evaluate", "{\"expression\":\"1+1\",\"returnByValue\":true}");
        const d = r.wait(c, 5_000);
        const parsed = r.json();
        defer if (parsed) |p| p.deinit();
        const value = if (parsed) |p| evalValue(p) else null;
        const ok = d != null and d.?.status == .ok and d.?.size == r.result.items.len and value != null and value.? == 2;
        report(ok, "dt-eval", std.fmt.bufPrint(&detail, "상태 {s} · 크기 {d}/받음 {d} · 값 {?d} · 「{s}」", .{ statusName(d), if (d) |v| v.size else 0, r.result.items.len, value, r.result.items[0..@min(r.result.items.len, 120)] }) catch "");
    }
    // dt-no-params
    {
        const c = try r.call("Page.enable", "");
        const d = r.wait(c, 5_000);
        const ok = d != null and d.?.status == .ok and std.mem.eql(u8, r.result.items, "{}");
        report(ok, "dt-no-params", std.fmt.bufPrint(&detail, "상태 {s} · 결과 「{s}」", .{ statusName(d), r.result.items[0..@min(r.result.items.len, 80)] }) catch "");
    }
    // dt-params-chunked — 40 000 바이트 인자.
    {
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(gpa);
        try params.appendSlice(gpa, "{\"returnByValue\":true,\"expression\":\"'");
        const tail = "'.length\"}";
        try params.appendNTimes(gpa, 'p', 40_000 - params.items.len - tail.len);
        const letters: i64 = @intCast(params.items.len - std.mem.indexOfScalar(u8, params.items, '\'').? - 1);
        try params.appendSlice(gpa, tail);
        const c = try r.call("Runtime.evaluate", params.items);
        const d = r.wait(c, 5_000);
        const parsed = r.json();
        defer if (parsed) |p| p.deinit();
        const value = if (parsed) |p| evalValue(p) else null;
        const ok = d != null and d.?.status == .ok and value != null and value.? == letters;
        report(ok, "dt-params-chunked", std.fmt.bufPrint(&detail, "인자 {d} 바이트(조각 {d}) · 상태 {s} · 길이 {?d}(기대 {d})", .{ params.items.len, (params.items.len + chunk - 1) / chunk, statusName(d), value, letters }) catch "");
    }
    // dt-result-chunked — 100 000 글자 결과.
    {
        const c = try r.call("Runtime.evaluate", "{\"expression\":\"'y'.repeat(100000)\",\"returnByValue\":true}");
        const d = r.wait(c, 10_000);
        const parsed = r.json();
        defer if (parsed) |p| p.deinit();
        const value = if (parsed) |p| evalValue(p) else null;
        const ok = d != null and d.?.status == .ok and d.?.size == r.result.items.len and d.?.chunks >= 7 and d.?.max_chunk <= chunk and value != null and value.? == 100_000;
        report(ok, "dt-result-chunked", std.fmt.bufPrint(&detail, "상태 {s} · 크기 {d}/받음 {d} · 조각 {d}(가장 큰 {d}) · 글자 {?d}", .{ statusName(d), if (d) |v| v.size else 0, r.result.items.len, if (d) |v| v.chunks else 0, if (d) |v| v.max_chunk else 0, value }) catch "");
    }
    // dt-cdp-error
    {
        const c = try r.call("No.suchMethod", "");
        const d = r.wait(c, 5_000);
        const parsed = r.json();
        defer if (parsed) |p| p.deinit();
        const code: ?i64 = if (parsed) |p| if (p.value == .object) if (p.value.object.get("code")) |v| if (v == .integer) v.integer else null else null else null else null;
        const ok = d != null and d.?.status == .cdp_error and code != null and code.? == -32601;
        report(ok, "dt-cdp-error", std.fmt.bufPrint(&detail, "상태 {s} · 「{s}」", .{ statusName(d), r.result.items[0..@min(r.result.items.len, 120)] }) catch "");
    }
    // dt-invalid-params — 판정자는 maru 의 검사를 거치지 않고 보낸다.
    {
        var statuses: [2][]const u8 = undefined;
        var ok = true;
        for ([_][]const u8{ "[1]", "1},\"id\":7" }, 0..) |bad, i| {
            const c = try r.call("Runtime.evaluate", bad);
            const d = r.wait(c, 5_000);
            statuses[i] = statusName(d);
            ok = ok and d != null and d.?.status == .invalid_request and d.?.size == 0;
        }
        report(ok, "dt-invalid-params", std.fmt.bufPrint(&detail, "[1] → {s} · 1}},\"id\":7 → {s}", .{ statuses[0], statuses[1] }) catch "");
    }
    // dt-overflow — 2 바이트라 하고 7 바이트를 보낸다.
    {
        const c = try r.begin(browser_id, "Runtime.evaluate", 2);
        try r.data(browser_id, c, "{\"a\":1}");
        const d = r.wait(c, 5_000);
        report(d != null and d.?.status == .invalid_request, "dt-overflow", std.fmt.bufPrint(&detail, "상태 {s}", .{statusName(d)}) catch "");
    }
    // dt-unknown
    {
        const c = try r.begin(999, "Page.enable", 0);
        const d = r.wait(c, 5_000);
        report(d != null and d.?.status == .unknown_browser, "dt-unknown", std.fmt.bufPrint(&detail, "상태 {s}", .{statusName(d)}) catch "");
    }
    // dt-too-large — 17 MiB 글자.
    {
        const c = try r.call("Runtime.evaluate", "{\"expression\":\"'z'.repeat(17*1024*1024)\",\"returnByValue\":true}");
        const d = r.wait(c, 20_000);
        const ok = d != null and d.?.status == .too_large and d.?.chunks == 0 and d.?.size == 0;
        report(ok, "dt-too-large", std.fmt.bufPrint(&detail, "상태 {s} · 조각 {d}", .{ statusName(d), if (d) |v| v.chunks else 0 }) catch "");
    }
    // dt-big-result-time — 8 MiB.
    {
        const started = os.nowMs();
        const c = try r.call("Runtime.evaluate", "{\"expression\":\"'w'.repeat(8*1024*1024)\",\"returnByValue\":true}");
        const d = r.wait(c, 20_000);
        const ms = os.nowMs() - started;
        const ok = d != null and d.?.status == .ok and d.?.size == r.result.items.len and r.result.items.len > 8 * 1024 * 1024;
        report(ok and ms < 5_000, "dt-big-result-time", std.fmt.bufPrint(&detail, "상태 {s} · {d} 바이트 · 조각 {d} · {d} ms(5 초 안)", .{ statusName(d), r.result.items.len, if (d) |v| v.chunks else 0, ms }) catch "");
    }
    // dt-busy — 인자를 다 보내지 않은 호출 하나와 CDP 로 보내 답을 기다리는 호출(끝나지 않는 Promise) 하나가 탭의 자리를 차지한다
    // (이 둘은 dt-closed 가 끝낸다).
    {
        _ = try r.begin(browser_id, "Runtime.evaluate", 10);
        _ = try r.call("Runtime.evaluate", "{\"expression\":\"new Promise(function(){})\",\"awaitPromise\":true}");
        r.pump(300);
        const c = try r.begin(browser_id, "Page.enable", 0);
        const d = r.wait(c, 5_000);
        report(d != null and d.?.status == .busy, "dt-busy", std.fmt.bufPrint(&detail, "그 탭의 셋째 호출 상태 {s}", .{statusName(d)}) catch "");
    }
    // dt-busy-other-tab — 다른 탭은 부를 수 있다.
    {
        const other: u64 = browser_id + 1;
        try host.send(.{ .create_browser = .{ .browser = other, .size = .{ .width = 320, .height = 200, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/static") } });
        r.pump(1_500);
        const c = try r.begin(other, "Page.enable", 0);
        const d = r.wait(c, 5_000);
        report(d != null and d.?.status == .ok, "dt-busy-other-tab", std.fmt.bufPrint(&detail, "상한에 찬 탭 옆 다른 탭의 호출 {s}", .{statusName(d)}) catch "");
        try host.send(.{ .destroy_browser = other });
        r.pump(500);
    }
    // dt-closed — 브라우저를 닫으면 둘 모두(보내기 전·보낸 뒤) browser_closed 앞에 detached.
    {
        try host.send(.{ .destroy_browser = browser_id });
        _ = r.until("closed", wait_ms);
        const want = protocol.message.max_devtools_calls_per_browser;
        report(r.closed and r.detached_before_close == want, "dt-closed", std.fmt.bufPrint(&detail, "닫힘 {} · 그 앞의 detached {d}(기대 {d} — 인자 받는 중 1 · CDP 로 보낸 것 1)", .{ r.closed, r.detached_before_close, want }) catch "");
    }
    // dt-renderer-gone — 새 브라우저에서 끝나지 않는 Promise 를 기다리는 호출.
    {
        r.created = false;
        r.loaded = false;
        r.closed = false;
        try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/static") } });
        _ = r.until("created", wait_ms);
        _ = r.until("loaded", wait_ms);
        const c = try r.call("Runtime.evaluate", "{\"expression\":\"new Promise(function(){})\",\"awaitPromise\":true}");
        r.pump(300);
        var kids_buf: [64]c_int = undefined;
        var killed: u32 = 0;
        for (os.children(host.pid, &kids_buf)) |kid| {
            if (os.argsContain(kid, "--type=renderer")) {
                _ = std.c.kill(kid, std.c.SIG.KILL);
                killed += 1;
            }
        }
        const d = r.wait(c, 5_000);
        report(killed >= 1 and d != null and d.?.status == .detached, "dt-renderer-gone", std.fmt.bufPrint(&detail, "죽인 렌더러 {d} · 기다리던 호출 {s} · renderer_gone {d}", .{ killed, statusName(d), r.renderer_gone }) catch "");
    }
    report(host.clean, "dt-clean", std.fmt.bufPrint(&detail, "host 메시지 모두 해석 {}", .{host.clean}) catch "");
    try expired(report, host_path, expired_profile_arg, port);
}

/// 시한을 1.5 초로 줄인 host — 답이 오지 않는 호출 하나만 보내고 새 호출 없이 기다린다(주기 정리가 끝내는가).
fn expired(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [300]u8 = undefined;
    var u: [256]u8 = undefined;
    var host = try Host.spawnWith(host_path, profile_arg, null, &.{"MARU_WEB_TEST_DEVTOOLS_STALE_MS=1500"});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 320, .height = 200, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/static") } });
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    defer r.deinit();
    _ = r.until("created", wait_ms);
    _ = r.until("loaded", wait_ms);
    const started = os.nowMs();
    const c = try r.call("Runtime.evaluate", "{\"expression\":\"new Promise(function(){})\",\"awaitPromise\":true}");
    const d = r.wait(c, 8_000);
    const ms = os.nowMs() - started;
    report(d != null and d.?.status == .expired and ms >= 1_400, "dt-expired", std.fmt.bufPrint(&detail, "상태 {s} · {d} ms(시한 1500 ms · 정리 주기 375 ms)", .{ statusName(d), ms }) catch "");
}
