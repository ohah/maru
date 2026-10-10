//! Chromium(OSR) 탭의 `browser.*` 를 DevTools(CDP) 호출 차례로 푼다(W9b① — 에이전트용 브라우저 제어). 한 요청은 호출 여러
//! 번(예: click = 노드 찾기 → 화면 안으로 → 자리 → 덮였는지 → 누르기)이고, 각 호출의 결과를 보고 다음 호출을 정한다. 이 파일은
//! 그 차례만 안다 — 보내기·받기는 `web_osr.devtoolsCall`, 요청 완료는 `app_host_abi` 가 한다(CEF·control-plane 없이 시험한다).
//!
//! - 입력은 **진짜 입력**이다(`Input.dispatchMouseEvent` — 페이지에는 `isTrusted` 인 사람 클릭으로 보인다, 착수 전 실측). 그래서
//!   누르기 직전에 그 자리에서 맞는 것이 그 요소(또는 그 안)인지 본다 — 다른 요소가 덮었으면 누르지 않고 실패로 답한다. 이 검사는
//!   **격리된 world**(`Page.createIsolatedWorld`)에서 돈다: 페이지 world 에서 돌리면 페이지가 `elementFromPoint`·`contains` 를 바꿔
//!   검사를 속이고 검사 순간을 알아챘다(W9b①a 적대 리뷰 1 회차 실측 — 격리 world 는 둘 다 막는다). 검사와 누르기 사이에는 왕복이
//!   하나뿐이다. **이 검사는 오클릭 방지이지 적대 페이지에 대한 경계가 아니다** — 페이지가 검사 순간을 몰라도 덮개를 계속 켰다 껐다
//!   하면 검사는 「맞음」·누름은 덮개에 떨어지는 경우가 생긴다(W9b①a 적대 리뷰 2 회차). 누르기 전 움직임(`mouseMoved`)은 보내지
//!   않는다: 숨긴 탭에서는 답이 오지 않았고(실측) 페이지에 「곧 누른다」는 신호가 됐다. 누름을 보냈으면 떼기·놓기는 끝까지 보낸다
//!   (`committed` — 철회돼도, 누름의 답이 시한을 넘겨도 버튼을 눌린 채 두지 않는다).
//! - 다른 frame 의 요소(같은 출처 iframe 노드를 ref 로)는 누르지 않는다 — 자리는 주 화면 좌표인데 검사는 그 frame 문서에서 돌아
//!   어긋난다. 그림자 DOM 의 slot 에 꽂힌 내용·host 는 그 요소 안으로 본다.
//! - 자리는 요소 상자와 화면(layout viewport)이 겹친 곳의 가운데다(화면보다 큰 요소의 가운데가 화면 밖이면 거기서는 아무것도 맞지
//!   않는다). 원격 객체는 요청마다 다른 묶음(`maru-w9b-<번호>`)이라 같은 탭의 다른 요청이 놓지 못한다.
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
    /// 보내지 못했다·답이 없다(떨어짐·sidecar 죽음) — 이유 글.
    failed: []const u8,
    /// 시한 안에 답이 없었다 — status timeout.
    timed_out: []const u8,
};

const max_boxes = 8;

const Stage = enum { document, query, describe, scroll, quads, metrics, frame_tree, world, resolve, hit_test, mouse_down, mouse_up, release, history, navigate_entry, reload };

pub const Op = struct {
    kind: Kind,
    stage: Stage = .document,
    /// 원격 객체 묶음 이름의 번호(요청마다 다르게 — 부른 쪽의 async id).
    id: u64 = 0,
    selector: ?[]u8 = null,
    backend: i64 = 0,
    /// 요소 상자들(viewport CSS px, 앞에서 `max_boxes` 개 — 여러 줄에 걸친 링크는 줄마다 하나) — 화면과 겹친 첫 상자를 고른다.
    boxes: [max_boxes][4]f64 = undefined,
    box_count: usize = 0,
    frame_id: ?[]u8 = null,
    context_id: i64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    /// 덮였는지 본 결과의 실패 이유(놓기 뒤에 답한다). null = 맞았다.
    miss: ?[]const u8 = null,
    /// 누름·떼기의 답이 시한을 넘겼다 — 그래도 떼기·놓기를 보내고 끝에 timeout 으로 답한다.
    late: ?[]const u8 = null,

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.selector) |s| gpa.free(s);
        if (self.frame_id) |s| gpa.free(s);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg(click 은 `{"selector":…}` 또는 `{"ref":…}`, 나머지는 빈 것). `id` 는 원격 객체 묶음 이름에 쓴다.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8, id: u64) !Op {
        var op: Op = .{ .kind = kind, .id = id };
        if (kind != .click) return op;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArg;
        if (parsed.value.object.get("ref")) |r| {
            if (r != .string) return error.InvalidArg;
            op.backend = parseRef(r.string) orelse 0; // 모르는 ref — start 가 곧바로 {ok:false}
            op.stage = .scroll;
        } else if (parsed.value.object.get("selector")) |sel| {
            if (sel != .string) return error.InvalidArg;
            op.selector = try gpa.dupe(u8, sel.string);
        } else return error.InvalidArg;
        return op;
    }

    /// 이미 페이지에 누름을 보냈다 — 남은 호출(떼기·놓기)은 그 요청이 철회돼도 보낸다(버튼을 눌린 채 두지 않는다).
    pub fn committed(self: *const Op) bool {
        return self.stage == .mouse_up or self.stage == .release;
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
        // 누른 뒤의 시한 — 페이지가 막혀 답이 늦을 뿐 입력은 갔을 수 있다: 떼기·놓기를 마저 보내고 끝에 timeout 으로 답한다.
        if (reply == .timed_out) switch (self.stage) {
            .mouse_down => {
                self.late = reply.timed_out;
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .mouse_up => {
                self.late = reply.timed_out;
                return self.releaseStep(gpa);
            },
            .release => return self.finish(gpa),
            else => {},
        };
        const bytes = switch (reply) {
            .failed => |why| return done(gpa, .failed, why),
            .timed_out => |why| return done(gpa, .timeout, why),
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
                self.box_count = collectBoxes(v, &self.boxes);
                if (self.box_count == 0) return done(gpa, .failed, "the element has no visible box");
                self.stage = .metrics;
                return call(gpa, "Page.getLayoutMetrics", "", .{});
            },
            .metrics => {
                // 상자와 화면이 겹친 곳의 가운데 — 화면보다 큰 요소의 가운데가 화면 밖이어도 보이는 곳을 누른다.
                const w = numberAt(v, &.{ "cssLayoutViewport", "clientWidth" }) orelse return done(gpa, .failed, "no viewport");
                const h = numberAt(v, &.{ "cssLayoutViewport", "clientHeight" }) orelse return done(gpa, .failed, "no viewport");
                const picked = for (self.boxes[0..self.box_count]) |box| {
                    const left = @max(box[0], 0);
                    const top = @max(box[1], 0);
                    const right = @min(box[2], w);
                    const bottom = @min(box[3], h);
                    if (right > left and bottom > top) break [4]f64{ left, top, right, bottom };
                } else return done(gpa, .failed, "the element is outside the viewport");
                self.x = (picked[0] + picked[2]) / 2;
                self.y = (picked[1] + picked[3]) / 2;
                self.stage = .frame_tree;
                return call(gpa, "Page.getFrameTree", "", .{});
            },
            .frame_tree => {
                const fid = stringAt(v, &.{ "frameTree", "frame", "id" }) orelse return done(gpa, .failed, "no main frame");
                self.frame_id = try gpa.dupe(u8, fid);
                self.stage = .world;
                return call(gpa, "Page.createIsolatedWorld", "{{\"frameId\":{f},\"worldName\":\"maru-w9b\"}}", .{std.json.fmt(fid, .{})});
            },
            .world => {
                self.context_id = intAt(v, &.{"executionContextId"}) orelse return done(gpa, .failed, "no isolated world");
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.backend, self.context_id, self.id });
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return done(gpa, .success, "false");
                self.stage = .hit_test;
                // 격리 world 에서 — 그 자리에서 맞는 것이 이 요소(또는 그 안)인가. 다른 frame 의 요소면 "frame"(자리가 주 화면 좌표라
                // 그 frame 에서 보면 어긋난다). 그림자 DOM 안이면 그 뿌리에서 맞히고, slot 에 꽂힌 내용·host 를 따라 올라가며 본다.
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(x,y){{if((this.ownerDocument||this)!==document)return 'frame';var r=this.getRootNode&&this.getRootNode();var d=r&&r.elementFromPoint?r:document;for(var n=d.elementFromPoint(x,y);n;n=n.assignedSlot||n.parentNode||n.host)if(n===this)return 'ok';return 'covered'}}\",\"arguments\":[{{\"value\":{d}}},{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(oid, .{}), self.x, self.y });
            },
            .hit_test => {
                if (at(v, &.{"exceptionDetails"}) != null) {
                    self.miss = "could not check what is at the element's position";
                    return self.releaseStep(gpa);
                }
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                if (std.mem.eql(u8, verdict, "frame")) {
                    self.miss = "elements inside frames cannot be clicked yet";
                    return self.releaseStep(gpa);
                }
                if (!std.mem.eql(u8, verdict, "ok")) {
                    self.miss = "the element is covered by another element at its center";
                    return self.releaseStep(gpa);
                }
                // 맞았다 — 왕복 하나 안에 누른다(놓기는 뗀 뒤).
                self.stage = .mouse_down;
                return self.mouse(gpa, "mousePressed");
            },
            .mouse_down => {
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .mouse_up => return self.releaseStep(gpa),
            .release => return self.finish(gpa),
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

    /// 놓은 뒤의 답 — 덮였으면 실패, 누름·떼기가 시한을 넘겼으면 timeout, 아니면 눌렀다.
    fn finish(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.miss) |why| return done(gpa, .failed, why);
        if (self.late) |why| return done(gpa, .timeout, why);
        return done(gpa, .success, "true");
    }

    fn scrollStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .scroll;
        return call(gpa, "DOM.scrollIntoViewIfNeeded", "{{\"backendNodeId\":{d}}}", .{self.backend});
    }

    fn releaseStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .release;
        return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
    }

    fn mouse(self: *Op, gpa: std.mem.Allocator, comptime kind: []const u8) !Step {
        return call(gpa, "Input.dispatchMouseEvent", "{{\"type\":\"" ++ kind ++ "\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ self.x, self.y });
    }

    /// CDP 가 오류로 답했다 — selector 문법이면 invalid_params, 노드가 사라졌으면(문서가 바뀌었다) 없는 요소(`{ok:false}`). 누른 뒤의
    /// 오류는 눌렀다는 사실을 덮지 않는다(떼기·놓기 실패는 그대로 성공 — 페이지는 이미 클릭을 받았다).
    fn cdpError(self: *Op, gpa: std.mem.Allocator, err_json: []const u8) !Step {
        var owned: ?[]u8 = null;
        defer if (owned) |m| gpa.free(m);
        if (std.json.parseFromSlice(std.json.Value, gpa, err_json, .{})) |parsed| {
            defer parsed.deinit();
            if (stringAt(parsed.value, &.{"message"})) |m| owned = try gpa.dupe(u8, m);
        } else |_| {}
        const message: []const u8 = owned orelse "DevTools error";
        const gone = containsAny(message, &.{ "No node", "Could not find node", "not found", "No target" });
        return switch (self.stage) {
            .query => if (gone) done(gpa, .success, "false") else done(gpa, .invalid_params, message),
            .describe, .scroll, .quads, .resolve => if (gone) done(gpa, .success, "false") else done(gpa, .failed, message),
            .mouse_up => self.releaseStep(gpa), // 떼기 실패 — 그래도 묶음은 놓는다
            .release => self.finish(gpa),
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

fn numberAt(v: std.json.Value, path: []const []const u8) ?f64 {
    const x = at(v, path) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
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

/// `quads` 의 상자들(넓이 0 은 뺀다) — 앞에서 `out.len` 개까지. 모양이 틀린 quad 는 건너뛴다.
fn collectBoxes(v: std.json.Value, out: *[max_boxes][4]f64) usize {
    const quads = arrayAt(v, &.{"quads"}) orelse return 0;
    var n: usize = 0;
    for (quads) |q| {
        if (n == out.len) break;
        if (q != .array or q.array.items.len != 8) continue;
        var c: [8]f64 = undefined;
        const ok = for (q.array.items, 0..) |x, i| {
            c[i] = switch (x) {
                .integer => |iv| @floatFromInt(iv),
                .float => |fv| fv,
                else => break false,
            };
        } else true;
        if (!ok) continue;
        const box = [4]f64{
            @min(@min(c[0], c[2]), @min(c[4], c[6])),
            @min(@min(c[1], c[3]), @min(c[5], c[7])),
            @max(@max(c[0], c[2]), @max(c[4], c[6])),
            @max(@max(c[1], c[3]), @max(c[5], c[7])),
        };
        if (box[2] <= box[0] or box[3] <= box[1]) continue;
        out[n] = box;
        n += 1;
    }
    return n;
}

// ── 시험: 가짜 DevTools 로 차례를 돈다 ──

const testing = std.testing;

const Trail = struct {
    methods: std.ArrayList([]const u8) = .empty,
    params: std.ArrayList([]u8) = .empty,
    /// 누름을 보낸 뒤 `committed` 였는가(떼기·놓기마다).
    committed_after_press: bool = true,
    /// 누름 Step 을 받을 때 `committed` 가 거짓이었는가(누르기 직전에는 재허가를 거친다).
    uncommitted_at_press: bool = true,

    fn deinit(self: *Trail) void {
        for (self.params.items) |p| testing.allocator.free(p);
        self.params.deinit(testing.allocator);
        self.methods.deinit(testing.allocator);
    }

    fn reset(self: *Trail) void {
        self.deinit();
        self.* = .{};
    }

    fn count(self: *const Trail, method: []const u8) usize {
        var n: usize = 0;
        for (self.methods.items) |m| if (std.mem.eql(u8, m, method)) {
            n += 1;
        };
        return n;
    }
};

/// 차례를 끝까지 돌린다 — `answer` 가 메서드마다 답을 준다.
fn drive(op: *Op, answer: *const fn (method: []const u8, params: []const u8) Reply, trail: *Trail) !struct { status: Status, result: []u8 } {
    var step = try op.start(testing.allocator);
    var pressed = false;
    while (true) switch (step) {
        .done => |d| return .{ .status = d.status, .result = d.result },
        .call => |c| {
            try trail.methods.append(testing.allocator, c.method);
            try trail.params.append(testing.allocator, c.params);
            if (pressed and !op.committed()) trail.committed_after_press = false;
            if (std.mem.indexOf(u8, c.params, "mousePressed") != null) {
                if (op.committed()) trail.uncommitted_at_press = false;
                pressed = true;
            }
            step = try op.feed(testing.allocator, answer(c.method, c.params));
        },
    };
}

fn happyPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getDocument")) return .{ .ok = "{\"root\":{\"nodeId\":1}}" };
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .ok = if (std.mem.indexOf(u8, params, "#none") != null) "{\"nodeId\":0}" else "{\"nodeId\":6}" };
    if (std.mem.eql(u8, method, "DOM.describeNode")) return .{ .ok = "{\"node\":{\"backendNodeId\":9}}" };
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,0,46,0,46,20,0,20]]}" };
    if (std.mem.eql(u8, method, "Page.getLayoutMetrics")) return .{ .ok = "{\"cssLayoutViewport\":{\"pageX\":0,\"pageY\":0,\"clientWidth\":800,\"clientHeight\":600}}" };
    if (std.mem.eql(u8, method, "Page.getFrameTree")) return .{ .ok = "{\"frameTree\":{\"frame\":{\"id\":\"F1\"}}}" };
    if (std.mem.eql(u8, method, "Page.createIsolatedWorld")) return .{ .ok = "{\"executionContextId\":7}" };
    if (std.mem.eql(u8, method, "DOM.resolveNode")) return .{ .ok = "{\"object\":{\"objectId\":\"o-1\"}}" };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"ok\"}}" };
    return .{ .ok = "{}" };
}

fn coveredPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"covered\"}}" };
    return happyPage(method, params);
}

fn framePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"frame\"}}" };
    return happyPage(method, params);
}

fn twoLinePage(method: []const u8, params: []const u8) Reply {
    // 두 줄에 걸친 링크 — 첫 줄은 화면 위로 나갔고 둘째 줄이 보인다. 넓이 0 상자도 섞였다.
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,-40,100,-40,100,-20,0,-20],[5,5,5,5,5,5,5,5],[0,0,60,0,60,20,0,20]]}" };
    return happyPage(method, params);
}

fn stuckPressPage(method: []const u8, params: []const u8) Reply {
    // 누름 핸들러가 alert 를 띄웠다 — 누름의 답이 시한을 넘긴다.
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mousePressed") != null) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn throwingPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"object\"},\"exceptionDetails\":{\"text\":\"x\"}}" };
    return happyPage(method, params);
}

fn hugePage(method: []const u8, params: []const u8) Reply {
    // 화면(800×600)보다 큰 요소 — 위로 500 px 넘친다.
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,-500,1000,-500,1000,700,0,700]]}" };
    return happyPage(method, params);
}

fn offscreenPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,900,40,900,40,920,0,920]]}" };
    return happyPage(method, params);
}

fn badSelectorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"DOM Error while querying\"}" };
    return happyPage(method, params);
}

fn staleDocumentPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Could not find node with given id\"}" };
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

fn slowPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn releaseFailsPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mouseReleased") != null) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" };
    return happyPage(method, params);
}

fn history(method: []const u8, _: []const u8) Reply {
    if (std.mem.eql(u8, method, "Page.getNavigationHistory")) return .{ .ok = "{\"currentIndex\":1,\"entries\":[{\"id\":5},{\"id\":8}]}" };
    return .{ .ok = "{}" };
}

test "click(selector): 찾기 → 화면 안으로 → 자리 → 화면과 겹친 곳 → 격리 world 에서 덮였는지 → 누르고 떼기 → 놓기" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 42);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "Page.getLayoutMetrics", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    // 검사는 격리 world(페이지가 바꿔 놓은 함수를 쓰지 않는다)·묶음 이름은 요청마다.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "\"executionContextId\":7") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "\"objectGroup\":\"maru-w9b-42\"") != null);
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-42\"}", trail.params.items[12]);
    // 누르기 앞에 움직임이 없다(숨긴 탭에서 답이 없었다) — 검사 바로 다음이 누름이다.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[10], "mousePressed") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[11], "mouseReleased") != null);
    try testing.expect(trail.committed_after_press);
    try testing.expect(trail.uncommitted_at_press);
    try testing.expectEqual(@as(f64, 23), op.x);
    try testing.expectEqual(@as(f64, 10), op.y);
}

test "click: 화면보다 큰 요소는 화면과 겹친 곳의 가운데, 화면 밖은 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 1);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &hugePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqual(@as(f64, 400), op.x);
    try testing.expectEqual(@as(f64, 300), op.y);
    trail.reset();
    var off = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 2);
    defer off.deinit(testing.allocator);
    const o = try drive(&off, &offscreenPage, &trail);
    defer testing.allocator.free(o.result);
    try testing.expectEqual(Status.failed, o.status);
    try testing.expect(std.mem.indexOf(u8, o.result, "outside the viewport") != null);
    try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
}

test "click: 누름의 답이 시한을 넘겨도 떼기·놓기를 보내고 timeout, 다른 frame 의 요소는 누르지 않는다, 두 줄 링크는 보이는 줄을" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 11);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &stuckPressPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.timeout, r.status);
        try testing.expectEqual(@as(usize, 2), trail.count("Input.dispatchMouseEvent")); // 누름 + 떼기
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
        try testing.expect(trail.committed_after_press);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .click, "{\"ref\":\"n9\"}", 12);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &framePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "frames") != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"a\"}", 13);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &twoLinePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("true", r.result);
        try testing.expectEqual(@as(f64, 30), op.x); // 둘째 줄의 가운데
        try testing.expectEqual(@as(f64, 10), op.y);
    }
}

test "click(ref): n<backendNodeId> 는 찾기를 건너뛴다, 모르는 ref·없는 요소는 {ok:false}" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"ref\":\"n9\"}", 3);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("DOM.scrollIntoViewIfNeeded", trail.methods.items[0]);
    for ([_][]const u8{ "{\"ref\":\"e1\"}", "{\"ref\":\"n0\"}", "{\"ref\":\"nx\"}", "{\"selector\":\"#none\"}" }) |arg| {
        trail.reset();
        var o = try Op.init(testing.allocator, .click, arg, 4);
        defer o.deinit(testing.allocator);
        const x = try drive(&o, &happyPage, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(Status.success, x.status);
        try testing.expectEqualStrings("false", x.result);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
    }
}

test "click: 덮였거나 검사가 예외면 누르지 않고 묶음을 놓은 뒤 실패, 오류는 나눠 답한다" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, want: []const u8 }{
        .{ .answer = &coveredPage, .want = "covered" },
        .{ .answer = &throwingPage, .want = "could not check" },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 5);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    const cases = [_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, result: []const u8 }{
        .{ .answer = &badSelectorPage, .status = .invalid_params, .result = "DOM Error while querying" },
        .{ .answer = &staleDocumentPage, .status = .success, .result = "false" }, // 그사이 문서가 바뀌었다 — selector 탓이 아니다
        .{ .answer = &goneNodePage, .status = .success, .result = "false" },
        .{ .answer = &detachedPage, .status = .failed, .result = "the browser's DevTools detached" },
        .{ .answer = &slowPage, .status = .timeout, .result = "DevTools did not answer in time" },
        .{ .answer = &releaseFailsPage, .status = .success, .result = "true" }, // 눌렀다 — 떼기·놓기 오류가 그 사실을 덮지 않는다
    };
    for (cases) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 6);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqualStrings(c.result, r.result);
    }
}

test "click 의 selector 는 JSON 으로 감싸 넘긴다(따옴표가 메시지를 깨지 않는다)" {
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"a[title=\\\"x\\\"]\"}", 7);
    defer op.deinit(testing.allocator);
    const s1 = try op.start(testing.allocator);
    testing.allocator.free(s1.call.params);
    const s2 = try op.feed(testing.allocator, .{ .ok = "{\"root\":{\"nodeId\":1}}" });
    defer testing.allocator.free(s2.call.params);
    try testing.expectEqualStrings("{\"nodeId\":1,\"selector\":\"a[title=\\\"x\\\"]\"}", s2.call.params);
    try testing.expect(try std.json.validate(testing.allocator, s2.call.params));
}

test "back·forward 는 방문 기록의 앞뒤 항목으로, 갈 곳이 없으면 {ok:false}, reload 는 한 번" {
    var trail: Trail = .{};
    defer trail.deinit();
    var back = try Op.init(testing.allocator, .back, "", 8);
    const b = try drive(&back, &history, &trail);
    defer testing.allocator.free(b.result);
    try testing.expectEqualStrings("true", b.result);
    try testing.expectEqualStrings("Page.navigateToHistoryEntry", trail.methods.items[1]);
    try testing.expectEqualStrings("{\"entryId\":5}", trail.params.items[1]);
    trail.reset();
    var fwd = try Op.init(testing.allocator, .forward, "", 9);
    const f = try drive(&fwd, &history, &trail); // 지금이 마지막 항목
    defer testing.allocator.free(f.result);
    try testing.expectEqualStrings("false", f.result);
    try testing.expectEqual(@as(usize, 1), trail.methods.items.len);
    trail.reset();
    var rel = try Op.init(testing.allocator, .reload, "", 10);
    const r = try drive(&rel, &history, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("Page.reload", trail.methods.items[0]);
}
