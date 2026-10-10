//! sidecar 가 쥔 DevTools 호출 표(W9-0b — CEF 를 모르는 부분, `pure_tests`). maru 가 `devtools_call` 로 시작하고 인자 조각
//! (`devtools_call_data`)을 다 보내면 CDP 메시지(`{"id","method","params"}`)를 만들어 CEF 에 보낸다(`devtools.zig`). 답은 그
//! 메시지 번호로 찾는다.
//!
//! - 메시지 번호는 다른 DevTools 사용처와 겹치지 않는 대역 `[1<<29, 1<<30)` 이다 — 권한(0 부터)·알림(20000 부터)·미디어 메뉴
//!   (1<<30 부터). 관찰자는 브라우저의 DevTools 세션을 함께 쓰므로 모두가 모든 결과를 받는다 — 대역으로 제 것만 고른다.
//! - 인자는 JSON **객체** 하나여야 한다 — 그대로 이어 붙이므로, 객체가 아니면(`1},"id":7`) 메시지 모양을 바꿀 수 있다. 메서드
//!   이름은 wire 가 이미 영숫자와 `.` 로 닫았다.
//! - 자리는 전체 `max_devtools_calls`·탭마다 `max_devtools_calls_per_browser` 개 — maru 도 그만큼만 기다리지만, 답을 영영 못 받는
//!   호출(렌더러가 멈추면 CDP 는 답도 detach 도 주지 않는다)이 자리를 막지 않게 `stale_ms` 가 지난 것은 `takeStale` 이 꺼낸다
//!   (`devtools.zig` 가 주기적으로). 탭마다 상한이 있어 멈춘 페이지 하나가 다른 탭의 호출을 막지 못한다.
//! - 인자 중첩 깊이도 본다 — CDP 파서의 깊이 한도를 넘으면 번호 없는 오류가 나 그 호출은 답을 받지 못한다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const BrowserId = message.BrowserId;

pub const capacity = message.max_devtools_calls;
pub const id_base: i32 = 1 << 29;
pub const id_end: i32 = 1 << 30;

pub const Phase = enum { collecting, sent };

pub const Call = struct {
    browser: BrowserId,
    call: u32,
    method_buf: [message.max_devtools_method_bytes]u8 = undefined,
    method_len: usize,
    params: std.ArrayList(u8) = .empty,
    params_size: u32,
    phase: Phase = .collecting,
    /// 보낸 CDP 메시지 번호(보내기 전 0).
    cdp_id: i32 = 0,
    started_ms: i64,

    pub fn method(self: *const Call) []const u8 {
        return self.method_buf[0..self.method_len];
    }

    /// 인자를 다 받았는가(인자 없는 호출은 처음부터).
    pub fn complete(self: *const Call) bool {
        return self.params.items.len == self.params_size;
    }

    pub fn deinit(self: *Call, gpa: std.mem.Allocator) void {
        self.params.deinit(gpa);
    }
};

pub const BeginError = error{ Busy, Duplicate };
pub const AddResult = union(enum) {
    /// 모르는 호출 — 버린다(이미 실패로 답했다).
    unknown,
    more,
    ready: *Call,
    /// 알린 크기보다 많다 — 그 호출은 `invalid_request` 로 답하고 버린다.
    overflow: *Call,
    out_of_memory: *Call,
};

pub const Table = struct {
    slots: [capacity]?Call = @splat(null),
    next_id: i32 = id_base,
    /// 답을 기다리는 시한(판정자는 짧게 — `devtools.zig`).
    stale_ms: i64 = message.devtools_stale_ms,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.slots) |*s| if (s.*) |*v| v.deinit(gpa);
        self.* = .{};
    }

    pub fn isEmpty(self: *const Table) bool {
        for (self.slots) |s| if (s != null) return false;
        return true;
    }

    pub fn find(self: *Table, browser: BrowserId, call: u32) ?*Call {
        for (&self.slots) |*s| if (s.*) |*v| if (v.browser == browser and v.call == call) return v;
        return null;
    }

    /// 새 호출의 자리를 잡는다. 메서드 이름·크기는 wire 가 검사했다.
    pub fn begin(self: *Table, value: message.DevtoolsCall, now_ms: i64) BeginError!*Call {
        if (self.find(value.browser, value.call) != null) return error.Duplicate;
        var of_browser: usize = 0;
        for (self.slots) |s| if (s) |v| if (v.browser == value.browser) {
            of_browser += 1;
        };
        if (of_browser >= message.max_devtools_calls_per_browser) return error.Busy;
        for (&self.slots) |*s| if (s.* == null) {
            s.* = .{ .browser = value.browser, .call = value.call, .method_len = value.method.len, .params_size = value.params_size, .started_ms = now_ms };
            @memcpy(s.*.?.method_buf[0..value.method.len], value.method);
            return &s.*.?;
        };
        return error.Busy;
    }

    pub fn addData(self: *Table, gpa: std.mem.Allocator, value: message.DevtoolsData) AddResult {
        const c = self.find(value.browser, value.call) orelse return .unknown;
        if (c.phase != .collecting) return .{ .overflow = c };
        if (c.params.items.len + value.bytes.len > c.params_size) return .{ .overflow = c };
        c.params.appendSlice(gpa, value.bytes) catch return .{ .out_of_memory = c };
        return if (c.complete()) .{ .ready = c } else .more;
    }

    fn takeId(self: *Table) i32 {
        const id = self.next_id;
        self.next_id = if (self.next_id + 1 >= id_end) id_base else self.next_id + 1;
        return id;
    }

    pub const BuildError = error{ InvalidParams, OutOfMemory };

    /// 보낼 CDP 메시지를 만들고 번호를 매긴다(부른 쪽이 해제). 인자가 JSON 객체 하나가 아니면 `InvalidParams`.
    pub fn buildMessage(self: *Table, gpa: std.mem.Allocator, c: *Call) BuildError![]u8 {
        std.debug.assert(c.complete() and c.phase == .collecting);
        const params = c.params.items;
        if (params.len != 0) {
            const first = std.mem.trimStart(u8, params, " \t\r\n");
            if (first.len == 0 or first[0] != '{') return error.InvalidParams;
            if (!try std.json.validate(gpa, params)) return error.InvalidParams;
            if (!protocol.fields.jsonDepthWithin(params, message.max_devtools_params_depth)) return error.InvalidParams;
        }
        const id = self.takeId();
        const json = if (params.len == 0)
            try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, c.method() })
        else
            try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, c.method(), params });
        c.cdp_id = id;
        c.phase = .sent;
        c.params.clearAndFree(gpa); // 보냈다 — 결과를 기다리는 동안 쥐지 않는다
        return json;
    }

    /// 그 메시지 번호로 보낸 호출을 꺼낸다(대역 밖이거나 모르면 null — 다른 사용처의 결과).
    pub fn takeByCdpId(self: *Table, cdp_id: i32) ?Call {
        if (cdp_id < id_base or cdp_id >= id_end) return null;
        for (&self.slots) |*s| if (s.*) |v| if (v.phase == .sent and v.cdp_id == cdp_id) {
            s.* = null;
            return v;
        };
        return null;
    }

    pub fn take(self: *Table, c: *Call) Call {
        for (&self.slots) |*s| if (s.*) |*v| if (v == c) {
            const out = v.*;
            s.* = null;
            return out;
        };
        unreachable;
    }

    /// 그 브라우저의 호출 하나를 꺼낸다(DevTools 가 떨어졌다·브라우저가 닫혔다 — 부른 쪽이 null 까지 되풀이해 `detached` 로 답한다).
    pub fn takeForBrowser(self: *Table, browser: BrowserId) ?Call {
        for (&self.slots) |*s| if (s.*) |v| if (v.browser == browser) {
            s.* = null;
            return v;
        };
        return null;
    }

    /// 시한이 지난 호출 하나를 꺼낸다(null 까지 되풀이해 `expired` 로 답한다).
    pub fn takeStale(self: *Table, now_ms: i64) ?Call {
        for (&self.slots) |*s| if (s.*) |v| if (now_ms - v.started_ms >= self.stale_ms) {
            s.* = null;
            return v;
        };
        return null;
    }
};

const testing = std.testing;

fn callOf(browser: BrowserId, call: u32, method: []const u8, params_size: u32) message.DevtoolsCall {
    return .{ .browser = browser, .call = call, .method = method, .params_size = params_size };
}

test "인자 조각을 모아 CDP 메시지를 만들고, 대역 안의 번호로만 답을 찾는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const params = "{\"expression\":\"1+1\",\"returnByValue\":true}";
    const c = try t.begin(callOf(3, 7, "Runtime.evaluate", params.len), 0);
    try testing.expect(!c.complete());
    try testing.expectEqual(AddResult.more, t.addData(testing.allocator, .{ .browser = 3, .call = 7, .bytes = params[0..10] }));
    const ready = t.addData(testing.allocator, .{ .browser = 3, .call = 7, .bytes = params[10..] });
    try testing.expect(ready == .ready and ready.ready == c);
    const json = try t.buildMessage(testing.allocator, c);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":536870912,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}", json);
    try testing.expectEqual(@as(usize, 0), c.params.capacity); // 보낸 뒤 인자를 쥐지 않는다
    // 다른 사용처의 번호(미디어 메뉴 1<<30 · 권한 0)는 모른다.
    try testing.expect(t.takeByCdpId(1 << 30) == null);
    try testing.expect(t.takeByCdpId(0) == null);
    var got = t.takeByCdpId(id_base).?;
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 7), got.call);
    try testing.expect(t.find(3, 7) == null);
}

test "인자 없는 호출은 params 없이, 번호는 대역 안에서 돈다" {
    var t: Table = .{ .next_id = id_end - 1 };
    defer t.deinit(testing.allocator);
    const c = try t.begin(callOf(3, 1, "Page.enable", 0), 0);
    try testing.expect(c.complete());
    const json = try t.buildMessage(testing.allocator, c);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":1073741823,\"method\":\"Page.enable\"}", json);
    try testing.expectEqual(id_base, t.next_id);
}

test "인자는 JSON 객체 하나여야 한다 — 이어 붙여 메시지 모양을 바꾸지 못한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for ([_][]const u8{ "1},\"id\":7", "[1]", "\"s\"", "{\"a\":1}x", "{\"a\":1},{\"b\":2}", "{", " ", "{\"a\":1}}" }) |bad| {
        const c = try t.begin(callOf(3, 9, "A.b", @intCast(bad.len)), 0);
        _ = t.addData(testing.allocator, .{ .browser = 3, .call = 9, .bytes = bad });
        try testing.expectError(error.InvalidParams, t.buildMessage(testing.allocator, c));
        var gone = t.take(c);
        gone.deinit(testing.allocator);
    }
    const c = try t.begin(callOf(3, 9, "A.b", 9), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 9, .bytes = " {\"a\":1}" ++ "\n" });
    const json = try t.buildMessage(testing.allocator, c);
    testing.allocator.free(json);
}

test "알린 크기를 넘는 조각·보낸 뒤의 조각은 넘침, 모르는 호출은 버림" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const c = try t.begin(callOf(3, 2, "A.b", 4), 0);
    try testing.expect(t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{\"a\":1}" }) == .overflow);
    try testing.expect(t.addData(testing.allocator, .{ .browser = 4, .call = 2, .bytes = "{}" }) == .unknown);
    var gone = t.take(c);
    gone.deinit(testing.allocator);
    const d = try t.begin(callOf(3, 2, "A.b", 2), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{}" });
    testing.allocator.free(try t.buildMessage(testing.allocator, d));
    try testing.expect(t.addData(testing.allocator, .{ .browser = 3, .call = 2, .bytes = "{}" }) == .overflow);
}

test "자리는 상한까지, 같은 번호는 거절, 브라우저·시한으로 꺼낸다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    // 탭마다 상한까지 — 전체가 찬다.
    for (0..capacity) |i| _ = try t.begin(callOf(@intCast(3 + i / message.max_devtools_calls_per_browser), @intCast(i + 1), "A.b", 0), @intCast(i * 1000));
    try testing.expectError(error.Busy, t.begin(callOf(99, 99, "A.b", 0), 0));
    try testing.expectError(error.Duplicate, t.begin(callOf(3, 1, "A.b", 0), 0));
    // 시한 — 처음 것(0 ms)만 지났다.
    try testing.expectEqual(@as(u32, 1), t.takeStale(t.stale_ms).?.call);
    try testing.expect(t.takeStale(t.stale_ms) == null);
    // 브라우저 4 의 것만 꺼낸다.
    var n: usize = 0;
    while (t.takeForBrowser(4)) |v| : (n += 1) try testing.expectEqual(@as(BrowserId, 4), v.browser);
    try testing.expectEqual(message.max_devtools_calls_per_browser, n);
    _ = try t.begin(callOf(4, 99, "A.b", 0), 0);
}

test "탭마다 상한 — 멈춘 탭 하나가 다른 탭의 자리를 막지 못한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for (0..message.max_devtools_calls_per_browser) |i| _ = try t.begin(callOf(3, @intCast(i + 1), "A.b", 0), 0);
    try testing.expectError(error.Busy, t.begin(callOf(3, 50, "A.b", 0), 0));
    _ = try t.begin(callOf(4, 50, "A.b", 0), 0);
}

test "인자 중첩이 깊으면 보내지 않는다(CDP 가 번호 없이 오류를 내 답이 오지 않는다)" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const deep = "{\"a\":" ++ "[" ** 65 ++ "]" ** 65 ++ "}";
    const c = try t.begin(callOf(3, 1, "A.b", deep.len), 0);
    _ = t.addData(testing.allocator, .{ .browser = 3, .call = 1, .bytes = deep });
    try testing.expectError(error.InvalidParams, t.buildMessage(testing.allocator, c));
}
