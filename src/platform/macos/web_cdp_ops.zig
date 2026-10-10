//! Chromium(OSR) 탭의 `browser.*` 를 DevTools(CDP) 호출 차례로 푼다(W9b① — 에이전트용 브라우저 제어). 한 요청은 호출 여러
//! 번(예: click = 노드 찾기 → 화면 안으로 → 자리 → 덮였는지 → 누르기)이고, 각 호출의 결과를 보고 다음 호출을 정한다. 이 파일은
//! 그 차례만 안다 — 보내기·받기는 `web_osr.devtoolsCall`, 요청 완료는 `app_host_abi` 가 한다(CEF·control-plane 없이 시험한다).
//!
//! - 입력은 **진짜 입력**이다(`Input.dispatchMouseEvent` — 페이지에는 `isTrusted` 인 사람 클릭으로 보인다, 착수 전 실측). 그래서
//!   누르기 전에 그 자리에서 맞는 요소가 맞는지 본다 — 다른 요소가 덮었으면 누르지 않고 실패로 답한다(덮은 요소를 누르지 않게).
//! - ref 는 `n<backendNodeId>`(같은 문서 안에서 바뀌지 않는다 — WebKit 의 `e1` 은 다음 snapshot 까지만이다). 모르는 ref·없는 요소는
//!   WebKit 과 같이 `{ok:false}`.
//! - 결과의 status 숫자는 `control_browser.BrowserCompletionStatus` 계약이다(성공 = 0 + "true"/"false", 실패 = 1 + 메시지).

const std = @import("std");

pub const Status = enum(u32) { success = 0, failed = 1, timeout = 2, invalid_params = 3 };

pub const Kind = enum { click, back, forward, reload };

/// 다음에 할 일 — CDP 호출 하나(`params` 는 소유 — 부른 쪽이 놓는다) 또는 끝(`result` 소유).
pub const Step = union(enum) {
    call: struct { method: []const u8, params: []u8 },
    done: struct { status: Status, result: []u8 },
};

/// 한 호출의 결과(`web_osr.DevtoolsOutcome` 을 이 모듈이 아는 셋으로 접는다).
pub const Reply = union(enum) {
    ok: []const u8,
    cdp_error: []const u8,
    /// 보내지 못했다·답이 없다(떨어짐·시한·sidecar 죽음) — 이유 글.
    failed: []const u8,
};

const Stage = enum { document, query, describe, scroll, quads, resolve, hit_test, release, mouse_move, mouse_down, mouse_up, history, navigate_entry, reload };

pub const Op = struct {
    kind: Kind,
    stage: Stage = .document,
    selector: ?[]u8 = null,
    backend: i64 = 0,
    object_id: ?[]u8 = null,
    x: f64 = 0,
    y: f64 = 0,
    /// 덮였는지 본 결과(놓기 뒤에 쓴다).
    hit: bool = false,

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.selector) |s| gpa.free(s);
        if (self.object_id) |s| gpa.free(s);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg(click 은 `{"selector":…}` 또는 `{"ref":…}`, 나머지는 빈 것).
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8) !Op {
        var op: Op = .{ .kind = kind };
        if (kind != .click) return op;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArg;
        if (parsed.value.object.get("ref")) |r| {
            if (r != .string) return error.InvalidArg;
            op.backend = parseRef(r.string) orelse 0; // 모르는 ref — start 가 곧바로 {ok:false}
            op.stage = .scroll;
        } else if (parsed.value.object.get("selector")) |s| {
            if (s != .string) return error.InvalidArg;
            op.selector = try gpa.dupe(u8, s.string);
        } else return error.InvalidArg;
        return op;
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        return switch (self.kind) {
            .click => if (self.selector != null)
                call(gpa, "DOM.getDocument", "{{\"depth\":0}}", .{})
            else if (self.backend == 0)
                done(gpa, .success, "false")
            else
                self.scrollStep(gpa),
            .back, .forward => blk: {
                self.stage = .history;
                break :blk call(gpa, "Page.getNavigationHistory", "", .{});
            },
            .reload => blk: {
                self.stage = .reload;
                break :blk call(gpa, "Page.reload", "", .{});
            },
        };
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        const bytes = switch (reply) {
            .failed => |why| return done(gpa, .failed, why),
            .cdp_error => |e| return self.cdpError(gpa, e),
            .ok => |b| b,
        };
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return done(gpa, .failed, "malformed DevTools result");
        defer parsed.deinit();
        const v = parsed.value;
        switch (self.stage) {
            .document => {
                const root = intAt(v, &.{ "root", "nodeId" }) orelse return done(gpa, .failed, "no document");
                self.stage = .query;
                return call(gpa, "DOM.querySelector", "{{\"nodeId\":{d},\"selector\":{f}}}", .{ root, std.json.fmt(self.selector.?, .{}) });
            },
            .query => {
                const node = intAt(v, &.{"nodeId"}) orelse 0;
                if (node == 0) return done(gpa, .success, "false"); // 없는 요소 — WebKit 과 같다
                self.stage = .describe;
                return call(gpa, "DOM.describeNode", "{{\"nodeId\":{d}}}", .{node});
            },
            .describe => {
                self.backend = intAt(v, &.{ "node", "backendNodeId" }) orelse return done(gpa, .success, "false");
                return self.scrollStep(gpa);
            },
            .scroll => {
                self.stage = .quads;
                return call(gpa, "DOM.getContentQuads", "{{\"backendNodeId\":{d}}}", .{self.backend});
            },
            .quads => {
                const quad = firstQuad(v) orelse return done(gpa, .failed, "the element has no visible box");
                self.x = (quad[0] + quad[2] + quad[4] + quad[6]) / 4;
                self.y = (quad[1] + quad[3] + quad[5] + quad[7]) / 4;
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"objectGroup\":\"maru-w9b\"}}", .{self.backend});
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return done(gpa, .success, "false");
                self.object_id = try gpa.dupe(u8, oid);
                self.stage = .hit_test;
                // 그 자리에서 맞는 것이 이 요소(또는 그 안)인가 — 그림자 DOM 안이면 그 뿌리에서 본다.
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(x,y){{var r=this.getRootNode&&this.getRootNode();var d=r&&r.elementFromPoint?r:document;var h=d.elementFromPoint(x,y);return !!h&&(h===this||this.contains(h))}}\",\"arguments\":[{{\"value\":{d}}},{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(oid, .{}), self.x, self.y });
            },
            .hit_test => {
                self.hit = boolAt(v, &.{ "result", "value" }) orelse false;
                self.stage = .release;
                return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b\"}}", .{});
            },
            .release => {
                if (!self.hit) return done(gpa, .failed, "the element is covered by another element at its center");
                self.stage = .mouse_move;
                return self.mouse(gpa, "mouseMoved");
            },
            .mouse_move => {
                self.stage = .mouse_down;
                return self.mouse(gpa, "mousePressed");
            },
            .mouse_down => {
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .mouse_up => return done(gpa, .success, "true"),
            .history => {
                const current = intAt(v, &.{"currentIndex"}) orelse return done(gpa, .failed, "no navigation history");
                const entries = arrayAt(v, &.{"entries"}) orelse return done(gpa, .failed, "no navigation history");
                const target: i64 = if (self.kind == .back) current - 1 else current + 1;
                if (target < 0 or target >= entries.len) return done(gpa, .success, "false"); // 갈 곳이 없다
                const entry_id = intAt(entries[@intCast(target)], &.{"id"}) orelse return done(gpa, .failed, "no navigation history");
                self.stage = .navigate_entry;
                return call(gpa, "Page.navigateToHistoryEntry", "{{\"entryId\":{d}}}", .{entry_id});
            },
            .navigate_entry, .reload => return done(gpa, .success, "true"),
        }
    }

    fn scrollStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .scroll;
        return call(gpa, "DOM.scrollIntoViewIfNeeded", "{{\"backendNodeId\":{d}}}", .{self.backend});
    }

    fn mouse(self: *Op, gpa: std.mem.Allocator, comptime kind: []const u8) !Step {
        const button = if (std.mem.eql(u8, kind, "mouseMoved")) "none" else "left";
        return call(gpa, "Input.dispatchMouseEvent", "{{\"type\":\"" ++ kind ++ "\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"clickCount\":{d}}}", .{ self.x, self.y, button, @as(u8, if (std.mem.eql(u8, button, "left")) 1 else 0) });
    }

    /// CDP 가 오류로 답했다 — 노드가 사라졌다(문서가 바뀌었다)면 없는 요소(`{ok:false}`), selector 가 틀렸으면 invalid_params.
    fn cdpError(self: *Op, gpa: std.mem.Allocator, err_json: []const u8) !Step {
        var owned: ?[]u8 = null;
        defer if (owned) |m| gpa.free(m);
        if (std.json.parseFromSlice(std.json.Value, gpa, err_json, .{})) |parsed| {
            defer parsed.deinit();
            if (stringAt(parsed.value, &.{"message"})) |m| owned = try gpa.dupe(u8, m);
        } else |_| {}
        const message: []const u8 = owned orelse "DevTools error";
        return switch (self.stage) {
            .query => done(gpa, .invalid_params, message), // DOM.querySelector — selector 문법
            .describe, .scroll, .quads, .resolve => if (containsAny(message, &.{ "No node", "Could not find node", "not found" }))
                done(gpa, .success, "false")
            else
                done(gpa, .failed, message),
            else => done(gpa, .failed, message),
        };
    }
};

/// `n<backendNodeId>` → id(0 이상의 정수가 아니면 null).
pub fn parseRef(ref: []const u8) ?i64 {
    if (ref.len < 2 or ref[0] != 'n') return null;
    const id = std.fmt.parseInt(i64, ref[1..], 10) catch return null;
    return if (id > 0) id else null;
}

fn call(gpa: std.mem.Allocator, method: []const u8, comptime fmt: []const u8, args: anytype) !Step {
    const params = if (fmt.len == 0) try gpa.alloc(u8, 0) else try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .call = .{ .method = method, .params = params } };
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, haystack, n) != null) return true;
    return false;
}

fn at(v: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v;
    for (path) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

fn intAt(v: std.json.Value, path: []const []const u8) ?i64 {
    const x = at(v, path) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn stringAt(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    const x = at(v, path) orelse return null;
    return if (x == .string) x.string else null;
}

fn boolAt(v: std.json.Value, path: []const []const u8) ?bool {
    const x = at(v, path) orelse return null;
    return if (x == .bool) x.bool else null;
}

fn arrayAt(v: std.json.Value, path: []const []const u8) ?[]std.json.Value {
    const x = at(v, path) orelse return null;
    return if (x == .array) x.array.items else null;
}

fn firstQuad(v: std.json.Value) ?[8]f64 {
    const quads = arrayAt(v, &.{"quads"}) orelse return null;
    if (quads.len == 0 or quads[0] != .array or quads[0].array.items.len != 8) return null;
    var out: [8]f64 = undefined;
    for (quads[0].array.items, 0..) |n, i| out[i] = switch (n) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        else => return null,
    };
    return out;
}

// ── 시험: 가짜 DevTools 로 차례를 돈다 ──

const testing = std.testing;

/// 차례를 끝까지 돌린다 — `answer` 가 메서드마다 답을 준다. 지나간 메서드를 `trail` 에 남긴다.
fn drive(op: *Op, answer: *const fn (method: []const u8, params: []const u8) Reply, trail: *std.ArrayList([]const u8)) !struct { status: Status, result: []u8 } {
    var step = try op.start(testing.allocator);
    while (true) switch (step) {
        .done => |d| return .{ .status = d.status, .result = d.result },
        .call => |c| {
            defer testing.allocator.free(c.params);
            try trail.append(testing.allocator, c.method);
            step = try op.feed(testing.allocator, answer(c.method, c.params));
        },
    };
}

fn happyPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getDocument")) return .{ .ok = "{\"root\":{\"nodeId\":1}}" };
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .ok = if (std.mem.indexOf(u8, params, "#none") != null) "{\"nodeId\":0}" else "{\"nodeId\":6}" };
    if (std.mem.eql(u8, method, "DOM.describeNode")) return .{ .ok = "{\"node\":{\"backendNodeId\":9}}" };
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,0,46,0,46,20,0,20]]}" };
    if (std.mem.eql(u8, method, "DOM.resolveNode")) return .{ .ok = "{\"object\":{\"objectId\":\"o-1\"}}" };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":true}}" };
    return .{ .ok = "{}" };
}

fn coveredPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":false}}" };
    return happyPage(method, params);
}

fn badSelectorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"DOM Error while querying\"}" };
    return happyPage(method, params);
}

fn goneNodePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.scrollIntoViewIfNeeded")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"No node with given id found\"}" };
    return happyPage(method, params);
}

fn detachedPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .failed = "the browser's DevTools detached" };
    return happyPage(method, params);
}

fn history(method: []const u8, _: []const u8) Reply {
    if (std.mem.eql(u8, method, "Page.getNavigationHistory")) return .{ .ok = "{\"currentIndex\":1,\"entries\":[{\"id\":5},{\"id\":8}]}" };
    return .{ .ok = "{}" };
}

test "click(selector): 찾기 → 화면 안으로 → 자리 → 덮였는지 → 놓기 → 움직이고 누르고 떼기, 진짜 입력은 그 가운데에" {
    var trail: std.ArrayList([]const u8) = .empty;
    defer trail.deinit(testing.allocator);
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}");
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "DOM.resolveNode", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent" };
    try testing.expectEqual(want.len, trail.items.len);
    for (want, trail.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqual(@as(f64, 23), op.x);
    try testing.expectEqual(@as(f64, 10), op.y);
}

test "click(ref): n<backendNodeId> 는 찾기를 건너뛴다, 모르는 ref·없는 요소는 {ok:false}" {
    var trail: std.ArrayList([]const u8) = .empty;
    defer trail.deinit(testing.allocator);
    var op = try Op.init(testing.allocator, .click, "{\"ref\":\"n9\"}");
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("DOM.scrollIntoViewIfNeeded", trail.items[0]);
    for ([_][]const u8{ "{\"ref\":\"e1\"}", "{\"ref\":\"n0\"}", "{\"ref\":\"nx\"}", "{\"selector\":\"#none\"}" }) |arg| {
        trail.clearRetainingCapacity();
        var o = try Op.init(testing.allocator, .click, arg);
        defer o.deinit(testing.allocator);
        const x = try drive(&o, &happyPage, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(Status.success, x.status);
        try testing.expectEqualStrings("false", x.result);
        for (trail.items) |m| try testing.expect(!std.mem.eql(u8, m, "Input.dispatchMouseEvent"));
    }
}

test "click: 덮인 요소는 누르지 않고 실패, selector 문법은 invalid_params, 사라진 노드는 {ok:false}, 떨어짐은 실패" {
    var trail: std.ArrayList([]const u8) = .empty;
    defer trail.deinit(testing.allocator);
    {
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}");
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &coveredPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "covered") != null);
        for (trail.items) |m| try testing.expect(!std.mem.eql(u8, m, "Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.items[trail.items.len - 1]); // 쥔 객체는 놓는다
    }
    const cases = [_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, result: []const u8 }{
        .{ .answer = &badSelectorPage, .status = .invalid_params, .result = "DOM Error while querying" },
        .{ .answer = &goneNodePage, .status = .success, .result = "false" },
        .{ .answer = &detachedPage, .status = .failed, .result = "the browser's DevTools detached" },
    };
    for (cases) |c| {
        trail.clearRetainingCapacity();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}");
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqualStrings(c.result, r.result);
    }
}

test "click 의 selector 는 JSON 으로 감싸 넘긴다(따옴표가 메시지를 깨지 않는다)" {
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"a[title=\\\"x\\\"]\"}");
    defer op.deinit(testing.allocator);
    const s1 = try op.start(testing.allocator);
    testing.allocator.free(s1.call.params);
    const s2 = try op.feed(testing.allocator, .{ .ok = "{\"root\":{\"nodeId\":1}}" });
    defer testing.allocator.free(s2.call.params);
    try testing.expectEqualStrings("{\"nodeId\":1,\"selector\":\"a[title=\\\"x\\\"]\"}", s2.call.params);
    try testing.expect(try std.json.validate(testing.allocator, s2.call.params));
}

test "back·forward 는 방문 기록의 앞뒤 항목으로, 갈 곳이 없으면 {ok:false}, reload 는 한 번" {
    var trail: std.ArrayList([]const u8) = .empty;
    defer trail.deinit(testing.allocator);
    var back = try Op.init(testing.allocator, .back, "");
    const b = try drive(&back, &history, &trail);
    defer testing.allocator.free(b.result);
    try testing.expectEqualStrings("true", b.result);
    try testing.expectEqualStrings("Page.navigateToHistoryEntry", trail.items[1]);
    trail.clearRetainingCapacity();
    var fwd = try Op.init(testing.allocator, .forward, "");
    const f = try drive(&fwd, &history, &trail); // 지금이 마지막 항목
    defer testing.allocator.free(f.result);
    try testing.expectEqualStrings("false", f.result);
    try testing.expectEqual(@as(usize, 1), trail.items.len);
    trail.clearRetainingCapacity();
    var rel = try Op.init(testing.allocator, .reload, "");
    const r = try drive(&rel, &history, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("Page.reload", trail.items[0]);
}
