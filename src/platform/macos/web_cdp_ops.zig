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
//! - 검사는 DOM 속성을 프로토타입 getter 로 읽는다 — 이름 속성(DOM clobbering)은 격리 world 에서도 보인다(3 회차 실측).
//! - 다른 frame 의 요소(같은 출처 iframe 노드를 ref 로)는 누르지 않는다 — 자리는 주 화면 좌표인데 검사는 그 frame 문서에서 돌아
//!   어긋난다. 그림자 DOM 의 slot 에 꽂힌 내용·host 는 그 요소 안으로 본다.
//! - 자리는 요소 상자와 화면(layout viewport)이 겹친 곳의 가운데다(화면보다 큰 요소의 가운데가 화면 밖이면 거기서는 아무것도 맞지
//!   않는다). 원격 객체는 요청마다 다른 묶음(`maru-w9b-<번호>`)이라 같은 탭의 다른 요청이 놓지 못한다.
//! - ref 는 `n<backendNodeId>`(같은 문서 안에서 바뀌지 않는다 — WebKit 의 `e1` 은 다음 snapshot 까지만이다). 모르는 ref·없는 요소는
//!   WebKit 과 같이 `{ok:false}`.
//! - 결과의 status 숫자는 `control_browser.BrowserCompletionStatus` 계약이다(성공 = 0 + "true"/"false", 실패 = 1 + 메시지).

const std = @import("std");
const web_cdp_snapshot = @import("web_cdp_snapshot.zig");

pub const Status = enum(u32) { success = 0, failed = 1, timeout = 2, invalid_params = 3 };

pub const Kind = enum { click, back, forward, reload, type_text, scroll, wait, snapshot };

/// 다음에 할 일 — CDP 호출 하나(`params` 는 소유 — 부른 쪽이 놓는다) 또는 끝(`result` 소유).
pub const Step = union(enum) {
    call: struct { method: []const u8, params: []u8 },
    done: struct { status: Status, result: []u8 },
    /// 이만큼(ms) 뒤에 `wake` 로 다시 부른다(wait 의 확인 간격 — 페이지 타이머를 쓰지 않는다: 숨긴 탭은 그것을 늦춘다).
    sleep: u32,
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

/// 여러 줄 링크의 줄 상자 상한 — 화면보다 긴 링크는 앞줄이 화면 밖일 수 있어 넉넉히(3 회차 — 8 이면 9 줄째부터 보여도 실패했다).
const max_boxes = 64;

/// wait 의 확인 간격(백오프) — 50 ms 에서 두 배씩 500 ms 까지. 확인 한 번 = DevTools 호출 둘(world·평가). 이벤트로 깨우는 길은
/// DevTools 이벤트를 받는 W9c 에서(그때 이 되풀이 확인을 없앤다).
pub const wait_first_interval_ms: u32 = 50;
pub const wait_max_interval_ms: u32 = 500;

const Stage = enum { document, query, describe, scroll, quads, metrics, frame_tree, world, resolve, hit_test, mouse_down, mouse_up, release, history, navigate_entry, reload, focus, select, insert, delete_down, delete_up, verify, ax_tree, check, sleeping };

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
    /// type 의 글(소유).
    text: ?[]u8 = null,
    /// wait — selector 가 보일 때까지(null 이면 문서가 다 불릴 때까지), 시한.
    wait_selector: ?[]u8 = null,
    wait_timeout_ms: u32 = 0,
    wait_deadline_ms: i64 = 0,
    /// 다음 확인까지의 간격 — 처음엔 짧게(곧 생기는 요소를 빨리), 두 배씩 늘려 `wait_max_interval_ms` 에서 멈춘다(오래 기다리는
    /// 동안의 DevTools 호출을 줄인다).
    wait_interval_ms: u32 = wait_first_interval_ms,
    /// 부른 쪽이 넣는 지금 시각(start·wake 전에)과 그 탭이 불러오는 중인가(wait --load — sidecar 의 nav_state).
    now_ms: i64 = 0,
    page_loading: bool = false,
    /// type — 고른 요소(넣은 뒤 다시 읽는다, 소유)와 넣기 전 값의 해시·길이(다시 읽을 때 「바뀌지 않았나·덧붙지 않았나」를 본다 —
    /// 값 자체는 싣지 않는다: 큰 글 상자면 DevTools 인자 상한(64 KiB)을 넘고, 결과의 서로게이트 정화가 값을 바꾼다 — 3 회차).
    object_id: ?[]u8 = null,
    before_hash: i64 = -1,
    before_len: i64 = 0,
    /// snapshot 선택.
    snap: web_cdp_snapshot.Options = .{},

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.selector) |s| gpa.free(s);
        if (self.frame_id) |s| gpa.free(s);
        if (self.text) |s| gpa.free(s);
        if (self.wait_selector) |s| gpa.free(s);
        if (self.object_id) |s| gpa.free(s);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg — click·scroll `{"selector"|"ref"}`, type `{…, "text"}`, wait `{"condition","selector"?,
    /// "timeout_ms"}`, snapshot `{"interactive_only","max_depth"?,"selector"?}`, back·forward·reload 는 빈 것. `id` 는 원격 객체
    /// 묶음 이름에 쓴다.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8, id: u64) !Op {
        var op: Op = .{ .kind = kind, .id = id };
        errdefer op.deinit(gpa);
        switch (kind) {
            .back, .forward, .reload => return op,
            else => {},
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArg;
        const o = parsed.value.object;
        switch (kind) {
            .wait => {
                const cond = o.get("condition") orelse return error.InvalidArg;
                if (cond != .string) return error.InvalidArg;
                if (std.mem.eql(u8, cond.string, "selector")) {
                    const sel = o.get("selector") orelse return error.InvalidArg;
                    if (sel != .string) return error.InvalidArg;
                    op.wait_selector = try gpa.dupe(u8, sel.string);
                } else if (!std.mem.eql(u8, cond.string, "load")) return error.InvalidArg;
                const t = o.get("timeout_ms") orelse return error.InvalidArg;
                if (t != .integer or t.integer <= 0) return error.InvalidArg;
                op.wait_timeout_ms = @intCast(@min(t.integer, std.math.maxInt(u32)));
                return op;
            },
            .snapshot => {
                if (o.get("interactive_only")) |v| if (v == .bool) {
                    op.snap.interactive_only = v.bool;
                };
                if (o.get("max_depth")) |v| if (v == .integer and v.integer >= 0) {
                    op.snap.max_depth = @intCast(@min(v.integer, std.math.maxInt(u32)));
                };
                if (o.get("selector")) |v| if (v == .string) {
                    op.selector = try gpa.dupe(u8, v.string);
                };
                return op;
            },
            .type_text => {
                const t = o.get("text") orelse return error.InvalidArg;
                if (t != .string) return error.InvalidArg;
                // 넣기·다시 읽기가 글을 DevTools 인자(64 KiB)에 싣는다 — 다시 읽기 JS 와 함께 넘치지 않게 JSON 으로 48 KiB 까지(넘으면
                // 넣은 뒤 다시 읽기만 거절돼 「들어갔는데 실패」가 됐다 — 적대 리뷰 4 회차).
                if (jsonStringBytes(t.string) > max_type_text_json_bytes) return error.InvalidArg;
                op.text = try gpa.dupe(u8, t.string);
            },
            else => {},
        }
        if (o.get("ref")) |r| {
            if (r != .string) return error.InvalidArg;
            op.backend = parseRef(r.string) orelse 0; // 모르는 ref — start 가 곧바로 {ok:false}
            op.stage = .scroll;
        } else if (o.get("selector")) |sel| {
            if (sel != .string) return error.InvalidArg;
            op.selector = try gpa.dupe(u8, sel.string);
        } else return error.InvalidArg;
        return op;
    }

    /// 이미 페이지에 누름을 보냈다 — 남은 호출(떼기·놓기)은 그 요청이 철회돼도 보낸다(버튼을 눌린 채 두지 않는다).
    pub fn committed(self: *const Op) bool {
        return switch (self.stage) {
            // 누름·Delete 키 누름을 보냈다 — 뗌·놓기를 끝까지. 넣은 뒤의 다시 읽기도(읽기만 한다 — 놓기까지 가게).
            .mouse_up, .release, .delete_up, .verify => true,
            else => false,
        };
    }

    /// `sleep` 뒤에 다시 부른다(부른 쪽이 `now_ms` 를 넣은 뒤) — 시한이 지났으면 timeout, 아니면 다음 확인.
    pub fn wake(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.now_ms >= self.wait_deadline_ms) return done(gpa, .timeout, "");
        return if (self.frame_id == null) self.frameTreeStep(gpa) else self.worldStep(gpa);
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        return switch (self.kind) {
            .click, .type_text, .scroll => if (self.selector != null)
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
            .wait => blk: {
                self.wait_deadline_ms = self.now_ms + self.wait_timeout_ms;
                break :blk self.frameTreeStep(gpa);
            },
            .snapshot => if (self.selector != null) call(gpa, "DOM.getDocument", "{{\"depth\":0}}", .{}) else self.axStep(gpa),
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
            // 고르기·넣기·다시 읽기의 시한 — 묶음을 놓고 timeout(Delete 를 눌렀으면 뗀 뒤).
            .select, .insert, .verify, .delete_up => {
                self.late = reply.timed_out;
                return self.releaseStep(gpa);
            },
            .delete_down => {
                self.late = reply.timed_out;
                self.stage = .delete_up;
                return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyUp\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
            },
            // wait 의 확인이 시한 — 다음 확인으로(시한은 wake 가 본다).
            .check, .world => if (self.kind == .wait) return self.sleepOrTimeout(gpa),
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
                if (node == 0) return self.missing(gpa); // 없는 요소 — WebKit 과 같다
                self.stage = .describe;
                return call(gpa, "DOM.describeNode", "{{\"nodeId\":{d}}}", .{node});
            },
            .describe => {
                self.backend = intAt(v, &.{ "node", "backendNodeId" }) orelse return self.missing(gpa);
                if (self.kind == .snapshot) {
                    self.snap.root_backend = self.backend;
                    return self.axStep(gpa);
                }
                return self.scrollStep(gpa);
            },
            .scroll => switch (self.kind) {
                .scroll => return done(gpa, .success, "true"),
                .type_text => {
                    self.stage = .focus;
                    return call(gpa, "DOM.focus", "{{\"backendNodeId\":{d}}}", .{self.backend});
                },
                else => {
                    self.stage = .quads;
                    return call(gpa, "DOM.getContentQuads", "{{\"backendNodeId\":{d}}}", .{self.backend});
                },
            },
            .focus => return self.frameTreeStep(gpa),
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
                return self.frameTreeStep(gpa);
            },
            .frame_tree => {
                const fid = stringAt(v, &.{ "frameTree", "frame", "id" }) orelse return done(gpa, .failed, "no main frame");
                self.frame_id = try gpa.dupe(u8, fid);
                return self.worldStep(gpa);
            },
            .world => {
                self.context_id = intAt(v, &.{"executionContextId"}) orelse return done(gpa, .failed, "no isolated world");
                if (self.kind == .wait) {
                    // 한 번 확인한다(격리 world — 이동했으면 새 문서의 world 다, 객체를 쥐지 않는다).
                    self.stage = .check;
                    const expr = try std.fmt.allocPrint(gpa, "(function(sel,load){{try{{var D=Document.prototype;if(load)return Object.getOwnPropertyDescriptor(D,'readyState').get.call(document)==='complete';var e=D.querySelector.call(document,sel);if(!e)return false;var r=Element.prototype.getBoundingClientRect.call(e),cs=getComputedStyle(e);return r.width>0&&r.height>0&&cs.visibility!=='hidden'&&cs.display!=='none'}}catch(x){{return 'error'}}}})({f},{})", .{ std.json.fmt(self.wait_selector orelse "", .{}), self.wait_selector == null });
                    defer gpa.free(expr);
                    return call(gpa, "Runtime.evaluate", "{{\"expression\":{f},\"contextId\":{d},\"returnByValue\":true}}", .{ std.json.fmt(expr, .{}), self.context_id });
                }
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.backend, self.context_id, self.id });
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return done(gpa, .success, "false");
                if (self.kind == .type_text) {
                    self.object_id = try gpa.dupe(u8, oid);
                    // 격리 world 에서 그 요소의 글을 고른다(입력칸·글 상자·contenteditable) — 그 위에 넣으면 바꿔 쓴다(WebKit 의 type 과 같다).
                    // 프로토타입 함수·getter 로 부른다(DOM clobbering).
                    self.stage = .select;
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(){{var t=this,P=function(o,k){{return Object.getOwnPropertyDescriptor(o,k).get}};var od=P(Node.prototype,'ownerDocument'),ok=false,before='',H=function(s){{var h=2166136261;for(var i=0;i<s.length;i++){{h=Math.imul(h^String.prototype.charCodeAt.call(s,i),16777619)}}return h|0}};var val=function(e){{return (e instanceof HTMLInputElement)?P(HTMLInputElement.prototype,'value').call(e):(e instanceof HTMLTextAreaElement)?P(HTMLTextAreaElement.prototype,'value').call(e):P(Node.prototype,'textContent').call(e)}};if(t instanceof HTMLInputElement){{var ty=P(HTMLInputElement.prototype,'type').call(t);if(!{{text:1,search:1,url:1,tel:1,email:1,password:1,number:1}}[ty])return {{r:'not editable'}};before=val(t);HTMLInputElement.prototype.select.call(t);ok=true}}else if(t instanceof HTMLTextAreaElement){{before=val(t);HTMLTextAreaElement.prototype.select.call(t);ok=true}}else if(t instanceof HTMLElement&&P(HTMLElement.prototype,'isContentEditable').call(t)){{before=val(t);var d=od.call(t);var g=Document.prototype.getSelection.call(d),r=Document.prototype.createRange.call(d);Range.prototype.selectNodeContents.call(r,t);Selection.prototype.removeAllRanges.call(g);Selection.prototype.addRange.call(g,r);ok=true}}if(!ok)return {{r:'not editable'}};var gr=Node.prototype.getRootNode,dae=P(Document.prototype,'activeElement'),sae=P(ShadowRoot.prototype,'activeElement'),host=P(ShadowRoot.prototype,'host'),ce=P(HTMLElement.prototype,'isContentEditable');var cur=t,root=gr.call(cur);for(var i=0;i<64;i++){{var ae=(root instanceof ShadowRoot)?sae.call(root):(root instanceof Document)?dae.call(root):null;if(ae!==cur&&!(cur===t&&ae&&ce.call(t)&&Node.prototype.contains.call(t,ae)))return {{r:'focus moved'}};if(!(root instanceof ShadowRoot))return {{r:'ok',h:H(before),n:before.length}};cur=host.call(root);root=gr.call(cur)}}return {{r:'focus moved'}}}}\",\"returnByValue\":true}}", .{std.json.fmt(oid, .{})});
                }
                self.stage = .hit_test;
                // 격리 world 에서 — 그 자리에서 맞는 것이 이 요소(또는 그 안)인가. 다른 frame 의 요소면 "frame"(자리가 주 화면 좌표라
                // 그 frame 에서 보면 어긋난다). 그림자 DOM 안이면 그 뿌리에서 맞히고, slot 에 꽂힌 내용·host 를 따라 올라가며 본다.
                // **DOM 속성은 프로토타입의 getter 로 읽는다** — 격리 world 여도 `<form>` 안의 `<input name=parentNode>` 같은 이름
                // 속성(DOM clobbering)이 `n.parentNode` 를 가린다: 실측으로 걷기가 끝없이 돌거나(렌더러 멈춤) 덮인 요소를 「맞음」으로
                // 통과시켰다(W9b①a 적대 리뷰 3 회차). 걷기는 4096 단계로 끊는다.
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(x,y){{var G=function(p,k){{return Object.getOwnPropertyDescriptor(p,k).get}};var od=G(Node.prototype,'ownerDocument'),pn=G(Node.prototype,'parentNode'),es=G(Element.prototype,'assignedSlot'),ts=G(Text.prototype,'assignedSlot'),hs=G(ShadowRoot.prototype,'host');var grn=Node.prototype.getRootNode,def=Document.prototype.elementFromPoint,sef=ShadowRoot.prototype.elementFromPoint;var me=this;if(me instanceof Text)me=G(Node.prototype,'parentElement').call(me)||me;if((od.call(me)||me)!==document)return 'frame';var r=grn.call(me);var h=(r instanceof ShadowRoot)?sef.call(r,x,y):def.call(document,x,y);for(var n=h,i=0;n&&i<4096;i++){{if(n===me)return 'ok';var s=(n instanceof Element)?es.call(n):(n instanceof Text)?ts.call(n):null;n=s||pn.call(n)||((n instanceof ShadowRoot)?hs.call(n):null)}}return 'covered'}}\",\"arguments\":[{{\"value\":{d}}},{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(oid, .{}), self.x, self.y });
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
            .select => {
                const verdict = stringAt(v, &.{ "result", "value", "r" }) orelse "";
                self.before_hash = intAt(v, &.{ "result", "value", "h" }) orelse -1;
                self.before_len = intAt(v, &.{ "result", "value", "n" }) orelse 0;
                if (std.mem.eql(u8, verdict, "focus moved")) {
                    // 페이지가 초점을 다른 곳으로 옮겼다(모달의 초점 가두기 등) — 넣으면 엉뚱한 칸(다른 출처 iframe 일 수도)에 간다.
                    self.miss = "focus moved away from the element (the page moved it) — nothing was typed";
                    return self.releaseStep(gpa);
                }
                if (!std.mem.eql(u8, verdict, "ok")) {
                    self.miss = "the element is not editable";
                    return self.releaseStep(gpa);
                }
                // 빈 글이면 고른 것을 지운다(Delete 키 — 진짜 입력). 아니면 고른 것 위에 넣는다(`Input.insertText` — 한 번의 입력 이벤트).
                if (self.text.?.len == 0) {
                    self.stage = .delete_down;
                    return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyDown\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
                }
                self.stage = .insert;
                return call(gpa, "Input.insertText", "{{\"text\":{f}}}", .{std.json.fmt(self.text.?, .{})});
            },
            .delete_down => {
                self.stage = .delete_up;
                return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyUp\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
            },
            .insert, .delete_up => {
                // 넣은 뒤 다시 읽는다 — readonly·disabled·maxlength·형식(number 에 글자)은 insertText 가 조용히 안 넣거나 자른다.
                self.stage = .verify;
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(want,bh,bn){{var t=this,P=function(o,k){{return Object.getOwnPropertyDescriptor(o,k).get}},S=String.prototype,J=Array.prototype.join,H=function(s){{var h=2166136261;for(var i=0;i<s.length;i++){{h=Math.imul(h^String.prototype.charCodeAt.call(s,i),16777619)}}return h|0}};var same=function(s){{return s.length===bn&&H(s)===bh}};var flat=function(s){{return J.call(S.split.call(J.call(S.split.call(s,String.fromCharCode(13)),''),String.fromCharCode(10)),'')}};var field=(t instanceof HTMLInputElement)||(t instanceof HTMLTextAreaElement);var v=(t instanceof HTMLInputElement)?P(HTMLInputElement.prototype,'value').call(t):(t instanceof HTMLTextAreaElement)?P(HTMLTextAreaElement.prototype,'value').call(t):P(Node.prototype,'textContent').call(t);if(v===want)return 'ok';if(field&&(v===S.trim.call(want)||v===flat(want)||v===S.trim.call(flat(want))))return 'ok';if(same(v)&&!same(want))return 'rejected';if(field&&v.length<want.length&&S.indexOf.call(want,v)===0)return 'rejected';if(bn>0&&v.length===bn+want.length&&((S.slice.call(v,bn)===want&&same(S.slice.call(v,0,bn)))||(S.slice.call(v,0,want.length)===want&&same(S.slice.call(v,want.length)))))return 'rejected';return 'ok'}}\",\"arguments\":[{{\"value\":{f}}},{{\"value\":{d}}},{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object_id.?, .{}), std.json.fmt(self.text.?, .{}), self.before_hash, self.before_len });
            },
            .verify => {
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                // 값이 바뀌지 않았거나·넣은 글의 앞부분으로 잘렸거나·원래 값 앞뒤에 덧붙었을 때만 거절한다 — 칸의 줄바꿈·앞뒤 공백 정리,
                // 입력 마스크가 바꾼 값은 들어간 것이다.
                if (!std.mem.eql(u8, verdict, "ok")) self.miss = "the field did not take the text (read-only, disabled, a length limit or its type)";
                return self.releaseStep(gpa);
            },
            .ax_tree => {
                const json = web_cdp_snapshot.build(gpa, bytes, self.snap) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => done(gpa, .failed, "malformed accessibility tree"),
                };
                return .{ .done = .{ .status = .success, .result = json } };
            },
            .check => {
                const value = at(v, &.{ "result", "value" }) orelse return self.sleepOrTimeout(gpa);
                if (value == .string) return done(gpa, .invalid_params, "Invalid selector");
                // load 는 그 문서가 다 불렸고 Chromium 이 불러오는 중이 아닐 때(이동이 시작된 옛 문서의 complete 를 믿지 않는다).
                const met = value == .bool and value.bool and !(self.wait_selector == null and self.page_loading);
                if (met) return done(gpa, .success, "true");
                return self.sleepOrTimeout(gpa);
            },
            .sleeping => unreachable, // 잠든 동안은 답이 오지 않는다(wake 로 깨운다)
        }
    }

    /// 없는 요소 — click·type·scroll 은 `{ok:false}`(WebKit 과 같다), snapshot 은 빈 트리.
    fn missing(self: *Op, gpa: std.mem.Allocator) !Step {
        return if (self.kind == .snapshot) done(gpa, .success, "{\"tree\":[]}") else done(gpa, .success, "false");
    }

    fn worldStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .world;
        return call(gpa, "Page.createIsolatedWorld", "{{\"frameId\":{f},\"worldName\":\"maru-w9b\"}}", .{std.json.fmt(self.frame_id.?, .{})});
    }

    /// wait — 아직이면 다음 간격 뒤 다시(시한을 넘겨 자지 않는다, 시한이 지났으면 timeout). 간격은 두 배씩 늘린다.
    fn sleepOrTimeout(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.now_ms >= self.wait_deadline_ms) return done(gpa, .timeout, "");
        const left: u32 = @intCast(@min(self.wait_deadline_ms - self.now_ms, std.math.maxInt(u32)));
        const ms = @min(self.wait_interval_ms, left);
        self.wait_interval_ms = @min(self.wait_interval_ms *| 2, wait_max_interval_ms);
        self.stage = .sleeping;
        return .{ .sleep = @max(ms, 1) };
    }

    fn frameTreeStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .frame_tree;
        return call(gpa, "Page.getFrameTree", "", .{});
    }

    fn axStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .ax_tree;
        return call(gpa, "Accessibility.getFullAXTree", "", .{});
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
            .query => if (gone) self.missing(gpa) else done(gpa, .invalid_params, message),
            .describe, .scroll, .quads, .resolve => if (gone) self.missing(gpa) else done(gpa, .failed, message),
            .focus => done(gpa, .failed, "the element cannot be focused"),
            // wait 의 world·확인 오류 — 이동 중이라 문서·world 가 사라졌다: 다음 확인으로(새 문서의 world).
            // world 오류면 주 frame 이 바뀌었을 수 있다(prerender 등) — 다음엔 frame tree 부터 다시 받는다.
            .world, .check => if (self.kind == .wait) blk: {
                if (self.stage == .world) if (self.frame_id) |f| {
                    gpa.free(f);
                    self.frame_id = null;
                };
                break :blk self.sleepOrTimeout(gpa);
            } else done(gpa, .failed, message),
            // 고르기·넣기 실패 — 쥔 묶음은 놓고 실패.
            .select, .insert, .delete_down, .delete_up, .verify => blk: {
                // 다시 읽기의 오류면 글은 이미 들어갔다 — 「넣지 못했다」 고 하지 않는다.
                self.miss = if (self.stage == .verify) "the text was entered but could not be read back" else "the text could not be entered";
                break :blk self.releaseStep(gpa);
            },
            .mouse_up => self.releaseStep(gpa), // 떼기 실패 — 그래도 묶음은 놓는다
            // 검사·누름이 CDP 오류 — 누르지 못했다. 쥔 묶음은 놓고 실패로 답한다(3 회차 — 그냥 끝내 묶음이 남았다).
            .hit_test => blk: {
                self.miss = "could not check what is at the element's position";
                break :blk self.releaseStep(gpa);
            },
            .mouse_down => blk: {
                self.miss = "the click could not be dispatched";
                break :blk self.releaseStep(gpa);
            },
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

/// type 의 글 상한(JSON 으로 쓴 길이).
pub const max_type_text_json_bytes = 48 * 1024;

/// 글을 JSON 문자열로 쓴 바이트 수(따옴표 빼고) — 제어 문자는 `\u00XX`, `"`·`\` 는 두 바이트.
fn jsonStringBytes(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += if (c < 0x20) 6 else if (c == '"' or c == '\\') 2 else 1;
    return n;
}

test "type: 글이 JSON 으로 48 KiB 를 넘으면 시작하지 않는다(제어 문자는 여섯 바이트로 센다)" {
    const big = try testing.allocator.alloc(u8, max_type_text_json_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    const arg = try std.fmt.allocPrint(testing.allocator, "{{\"selector\":\"#in\",\"text\":{f}}}", .{std.json.fmt(big, .{})});
    defer testing.allocator.free(arg);
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .type_text, arg, 1));
    const fits = try std.fmt.allocPrint(testing.allocator, "{{\"selector\":\"#in\",\"text\":{f}}}", .{std.json.fmt(big[0..max_type_text_json_bytes], .{})});
    defer testing.allocator.free(fits);
    var ok = try Op.init(testing.allocator, .type_text, fits, 1); // 상한과 같으면 시작한다
    ok.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6 + 2 + 1), jsonStringBytes("\n\"a"));
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
    sleeps: usize = 0,

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
        .sleep => |ms| {
            // 가짜 시계 — 잠든 만큼 흘려 깨운다.
            trail.sleeps += 1;
            op.now_ms += ms;
            step = try op.wake(testing.allocator);
        },
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

fn stuckReleasePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mouseReleased") != null) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn stuckGroupReleasePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn hitErrorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Cannot find context\"}" };
    return happyPage(method, params);
}

fn pressErrorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent")) return .{ .cdp_error = "{\"code\":-32602,\"message\":\"bad\"}" };
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
    // 떼기가 시한 → 놓기를 마저 보내고 timeout, 놓기만 시한 → 눌렀으니 성공, 누름이 CDP 오류 → 묶음을 놓고 실패.
    const more = [_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, presses: usize }{
        .{ .answer = &stuckReleasePage, .status = .timeout, .presses = 2 },
        .{ .answer = &stuckGroupReleasePage, .status = .success, .presses = 2 },
        .{ .answer = &pressErrorPage, .status = .failed, .presses = 1 },
        .{ .answer = &hitErrorPage, .status = .failed, .presses = 0 },
    };
    for (more) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 14);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqual(c.presses, trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
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

// ── W9b①b: type·scroll·wait·snapshot ──

const tiny_ax =
    \\{"nodes":[{"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":"t"},"backendDOMNodeId":5,"childIds":["2"]},
    \\{"nodeId":"2","role":{"value":"button"},"name":{"value":"Go"},"backendDOMNodeId":9,"parentId":"1","childIds":[]}]}
;

fn editorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Accessibility.getFullAXTree")) return .{ .ok = tiny_ax };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null and std.mem.indexOf(u8, params, "function(want,bh,bn)") == null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"ok\",\"h\":123,\"n\":3}}}" };
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        // wait 의 한 번 확인 — `#late` 면 보인다, `#never` 면 아직, `[` 면 selector 오류, load 는 complete.
        if (std.mem.indexOf(u8, params, "#never") != null) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":false}}" };
        if (std.mem.indexOf(u8, params, "\\\"[\\\"") != null) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"error\"}}" };
        return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":true}}" };
    }
    return happyPage(method, params);
}

fn notEditablePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"not editable\"}}}" };
    return editorPage(method, params);
}

test "type: 찾기 → 화면 안으로 → 초점 → 격리 world 에서 글 고르기(프로토타입 함수) → 그 위에 insertText → 놓기" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"새 \\\"값\\\"\"}", 21);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &editorPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.focus", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Input.insertText", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "HTMLInputElement.prototype.select.call") != null);
    try testing.expectEqualStrings("{\"text\":\"새 \\\"값\\\"\"}", trail.params.items[9]);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[8]));
    // 고른 뒤 초점이 그 요소인지 보고, 넣은 뒤 값을 다시 읽는다(넣은 글을 인자로).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "focus moved") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[10], "\"arguments\":[{\"value\":\"새 \\\"값\\\"\"},{\"value\":123},{\"value\":3}]") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[10]));
}

fn focusStealPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"focus moved\"}}}" };
    return editorPage(method, params);
}

fn rejectingPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(want,bh,bn)") != null) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"rejected\"}}" };
    return editorPage(method, params);
}

test "type: 페이지가 초점을 옮겼으면 넣지 않고, 넣은 값이 거부됐으면(readonly·maxlength·형식) 실패 — 묶음은 놓는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, want: []const u8, inserts: usize }{
        .{ .answer = &focusStealPage, .want = "focus moved", .inserts = 0 },
        .{ .answer = &rejectingPage, .want = "did not take", .inserts = 1 },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"x\"}", 31);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(c.inserts, trail.count("Input.insertText"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "type: 빈 글은 고른 것을 Delete 키로 지우고, 편집할 수 없는 요소는 넣지 않고 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .type_text, "{\"ref\":\"n9\",\"text\":\"\"}", 22);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("true", r.result);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.insertText"));
        try testing.expectEqual(@as(usize, 2), trail.count("Input.dispatchKeyEvent"));
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#cb\",\"text\":\"x\"}", 23);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &notEditablePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "not editable") != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.insertText"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "scroll: 화면 안으로 스크롤하고 끝, 없는 요소는 {ok:false}" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .scroll, "{\"selector\":\"#far\"}", 24);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &editorPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("DOM.scrollIntoViewIfNeeded", trail.methods.items[trail.methods.items.len - 1]);
    trail.reset();
    var none = try Op.init(testing.allocator, .scroll, "{\"selector\":\"#none\"}", 25);
    defer none.deinit(testing.allocator);
    const n = try drive(&none, &editorPage, &trail);
    defer testing.allocator.free(n.result);
    try testing.expectEqualStrings("false", n.result);
}

test "wait: 격리 world 에서 한 번씩 본다(간격 50→100→200…→500 ms) — 보이면 성공, 시한이면 timeout, selector 오류는 invalid_params" {
    var trail: Trail = .{};
    defer trail.deinit();
    const cases = [_]struct { arg: []const u8, status: Status, sleeps: usize }{
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"#late\",\"timeout_ms\":5000}", .status = .success, .sleeps = 0 },
        // 350 ms: 50 + 100 + 200(남은 만큼) — 시한에서 끝.
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"#never\",\"timeout_ms\":350}", .status = .timeout, .sleeps = 3 },
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"[\",\"timeout_ms\":100}", .status = .invalid_params, .sleeps = 0 },
        .{ .arg = "{\"condition\":\"load\",\"timeout_ms\":100}", .status = .success, .sleeps = 0 },
    };
    for (cases) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .wait, c.arg, 26);
        defer op.deinit(testing.allocator);
        op.now_ms = 1000;
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqual(c.sleeps, trail.sleeps);
        const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate" };
        for (want, trail.methods.items[0..3]) |w, got| try testing.expectEqualStrings(w, got);
        try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "\"contextId\":7") != null); // 격리 world
        try testing.expect(try std.json.validate(testing.allocator, trail.params.items[2]));
        // 확인마다 world 를 다시 받는다(이동했으면 새 문서의 world) — 잠든 수만큼 더.
        // (시한으로 끝나는 마지막 깨어남은 world 를 받지 않는다.)
        try testing.expectEqual(if (c.status == .timeout) c.sleeps else 1 + c.sleeps, trail.count("Page.createIsolatedWorld"));
    }
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"timeout_ms\":5}", 1));
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .wait, "{\"condition\":\"idle\",\"timeout_ms\":5}", 1));
}

var navigating_checks: usize = 0;
fn navigatingPage(method: []const u8, params: []const u8) Reply {
    // 처음 두 번은 이동 중이라 문서·world 가 사라진다 — 그다음 새 문서에서 보인다.
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        navigating_checks += 1;
        if (navigating_checks <= 2) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Execution context was destroyed.\"}" };
    }
    return editorPage(method, params);
}

fn loadingPage(method: []const u8, params: []const u8) Reply {
    return editorPage(method, params);
}

test "wait: 이동 중 world 가 사라져도 다음 확인으로 넘긴다, load 는 그 탭이 불러오는 중이면 기다린다" {
    var trail: Trail = .{};
    defer trail.deinit();
    navigating_checks = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#result\",\"timeout_ms\":5000}", 32);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &navigatingPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 2), trail.sleeps);
    trail.reset();
    var load = try Op.init(testing.allocator, .wait, "{\"condition\":\"load\",\"timeout_ms\":250}", 33);
    defer load.deinit(testing.allocator);
    load.page_loading = true; // 이동이 시작됐다 — 옛 문서의 complete 를 믿지 않는다
    const l = try drive(&load, &loadingPage, &trail);
    defer testing.allocator.free(l.result);
    try testing.expectEqual(Status.timeout, l.status);
    try testing.expect(trail.sleeps >= 2);
}

test "snapshot: 접근성 트리를 WebKit 모양으로, selector 는 그 노드부터, 없는 selector 는 빈 트리" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":false}", 27);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[{\"role\":\"button\",\"name\":\"Go\",\"ref\":\"n9\"}]}", r.result);
        try testing.expectEqual(@as(usize, 1), trail.methods.items.len);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":true,\"selector\":\"#b\"}", 28);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[{\"role\":\"button\",\"name\":\"Go\",\"ref\":\"n9\"}]}", r.result);
        try testing.expectEqualStrings("Accessibility.getFullAXTree", trail.methods.items[trail.methods.items.len - 1]);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":false,\"selector\":\"#none\"}", 29);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[]}", r.result);
    }
}

test "wait 의 간격은 두 배씩 늘어 500 ms 에서 멈추고, 시한을 넘겨 자지 않는다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"load\",\"timeout_ms\":3000}", 40);
    defer op.deinit(testing.allocator);
    op.now_ms = 0;
    op.wait_deadline_ms = 3000;
    var got: [8]u32 = undefined;
    for (&got) |*g| {
        const step = try op.sleepOrTimeout(testing.allocator);
        g.* = step.sleep;
        op.now_ms += g.*;
        if (op.now_ms >= op.wait_deadline_ms) break;
    }
    try testing.expectEqualSlices(u32, &.{ 50, 100, 200, 400, 500, 500, 500, 500 }, &got);
    // 남은 시간이 간격보다 짧으면 남은 만큼만.
    op.now_ms = 2990;
    try testing.expectEqual(@as(u32, 10), (try op.sleepOrTimeout(testing.allocator)).sleep);
    op.now_ms = 3000;
    const end = try op.sleepOrTimeout(testing.allocator);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.timeout, end.done.status);
}

fn frameGonePage(method: []const u8, params: []const u8) Reply {
    // 주 frame 이 바뀌었다 — 옛 frame id 의 world 는 늘 오류, frame tree 를 다시 받으면 새 id.
    if (std.mem.eql(u8, method, "Page.createIsolatedWorld") and std.mem.indexOf(u8, params, "\"F1\"") != null and frame_gone_seen > 0) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"No frame for given id found\"}" };
    if (std.mem.eql(u8, method, "Page.getFrameTree")) {
        frame_gone_seen += 1;
        return .{ .ok = if (frame_gone_seen == 1) "{\"frameTree\":{\"frame\":{\"id\":\"F1\"}}}" else "{\"frameTree\":{\"frame\":{\"id\":\"F2\"}}}" };
    }
    if (std.mem.eql(u8, method, "Runtime.evaluate") and frame_gone_seen == 1) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":false}}" };
    return editorPage(method, params);
}
var frame_gone_seen: usize = 0;

test "wait: world 오류(주 frame 이 바뀜)면 frame tree 부터 다시 받는다 — 옛 id 로 시한까지 헛돌지 않는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    frame_gone_seen = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#late\",\"timeout_ms\":5000}", 41);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &frameGonePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 2), trail.count("Page.getFrameTree"));
}
