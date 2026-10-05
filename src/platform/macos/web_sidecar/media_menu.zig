//! 우클릭 메뉴의 미디어 항목(W6h② — Chrome 「연속 재생」·「모든 제어 기능 표시」). CEF 메뉴에는 미디어 명령이 없다(착수 전 실측 —
//! 기본 모델은 뒤로·앞으로·인쇄·소스 보기뿐). 그래서 sidecar 가 프로세스 안 DevTools 로 그 자리의 요소를 찾아 바꾼다:
//!
//! 1. 우클릭할 때 그 자리의 노드를 미리 찾는다 — 메뉴가 떠 있는 동안 배치가 바뀌어도 우클릭한 그 요소를 바꾸게. CEF 가 주는 자리는
//!    view(화면) 좌표인데 `DOM.getNodeForLocation` 은 **문서** 좌표다(실측 — 500 px 스크롤한 페이지에 view 좌표를 그대로 주면 「No node
//!    found」, W6h② 적대 검증) — `Page.getLayoutMetrics` 의 스크롤·배율로 바꿔 찾는다(`metrics` → `locate`).
//! 2. 고르면 `DOM.resolveNode` → `Runtime.callFunctionOn` 으로 `loop`·`controls` 를 뒤집는다 — 그 요소가 미디어이고 주소가 메뉴가 알린
//!    주소와 같을 때만(아니면 3 으로). 쥔 객체는 끝나면 놓는다(`objectGroup`).
//! 3. 다른 프로세스의 iframe(다른 사이트)이면 1 은 그 iframe 요소에서 멈춘다(실측) — 메뉴가 온 frame(그 iframe — 실측)에서 메뉴가
//!    알린 주소와 같은 미디어가 **딱 하나**면 그것을 바꾼다(사용자 결정 2026-10-05 — 둘 이상이면 아무것도 하지 않는다).
//!
//! `controls` 는 속성을 바꾼다 — Chrome 은 페이지가 보지 못하는 내부 값만 바꾼다(차이 — 페이지가 `controls` 를 다시 끄면 따른다).
//! 응답은 1 ms 안에 같은 UI 스레드로 온다(실측). 메뉴(`context_menu.Held`)는 답하면 곧 끝나므로 진행은 여기 따로 쥔다 — 브라우저마다
//! 하나(브라우저에 메뉴는 하나다). 메시지 번호는 다른 DevTools 사용처(권한·알림 — 0·20000 부터 오른다)와 섞이지 않게 높은 대역이다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");

const allocator = std.heap.c_allocator;

pub const Prop = enum { loop, controls };

const Stage = enum { metrics, locate, resolve, call };

const Slot = struct {
    cef_id: c_int,
    menu: u32,
    /// 우클릭한 자리(view DIP).
    x: c_int,
    y: c_int,
    /// 지금 기다리는 메시지 번호(0 = 없음).
    waiting: c_int = 0,
    stage: Stage = .metrics,
    /// 찾은 노드(0 = 아직·못 찾음).
    node: i64 = 0,
    /// 고른 것(아직 안 골랐으면 null — 찾기 결과를 받아 두기만 한다).
    action: ?Prop = null,
    /// 메뉴가 알린 미디어 주소(확인·보조 경로 — 소유).
    src: ?[]u8 = null,
    /// 메뉴가 온 frame(보조 경로 — 참조 하나).
    frame: [*c]c.cef_frame_t = null,
};

var slots: [registry_mod.capacity]?Slot = @splat(null);
/// 브라우저마다의 관찰자 등록(놓으면 끝난다).
var registrations: [registry_mod.capacity]?struct { cef_id: c_int, reg: [*c]c.cef_registration_t } = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
/// 이 모듈의 메시지 번호 — 다른 사용처와 겹치지 않는 대역(1 << 30 부터).
var next_id: c_int = 1 << 30;

fn takeId() c_int {
    next_id +%= 1;
    if (next_id < (1 << 30)) next_id = 1 << 30;
    return next_id;
}

fn slotOf(cef_id: c_int) ?*Slot {
    for (&slots) |*s| if (s.*) |*v| if (v.cef_id == cef_id) return v;
    return null;
}

fn clear(s: *?Slot) void {
    const v = s.* orelse return;
    if (v.src) |b| allocator.free(b);
    if (v.frame != null) object.release(v.frame);
    s.* = null;
}

fn clearFor(cef_id: c_int) void {
    for (&slots) |*s| if (s.*) |v| if (v.cef_id == cef_id) clear(s);
}

fn ensureObserver(host: [*c]c.cef_browser_host_t, cef_id: c_int) bool {
    if (!observer_ready) {
        observer_ready = true;
        observer = object.zeroed(c.cef_dev_tools_message_observer_t);
        object.staticRefCounted(&observer.base);
        observer.on_dev_tools_method_result = &onResult;
    }
    for (registrations) |r| if (r) |v| if (v.cef_id == cef_id) return true;
    for (&registrations) |*r| if (r.* == null) {
        const reg = host.*.add_dev_tools_message_observer.?(host, &observer);
        if (reg == null) return false;
        r.* = .{ .cef_id = cef_id, .reg = reg };
        return true;
    };
    return false;
}

fn send(browser: [*c]c.cef_browser_t, json: []const u8) bool {
    const host = browser.*.get_host.?(browser);
    if (host == null) return false;
    defer object.release(host);
    return host.*.send_dev_tools_message.?(host, json.ptr, json.len) != 0;
}

/// 보내고 그 번호를 기다린다. 못 보내면 false(부른 쪽이 보조 경로로).
fn sendWaiting(browser: [*c]c.cef_browser_t, s: *Slot, stage: Stage, comptime fmt: []const u8, args: anytype) bool {
    const id = takeId();
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d}," ++ fmt ++ "}}", .{id} ++ args) catch return false;
    s.stage = stage;
    s.waiting = id;
    if (send(browser, json)) return true;
    s.waiting = 0;
    return false;
}

/// 우클릭한 미디어(동영상·오디오) — 그 자리의 노드를 미리 찾는다(스크롤·배율부터). 그 브라우저의 앞 진행은 버린다. `src` 는 이
/// 모듈이 복사한다, `frame` 은 참조를 하나 더한다.
pub fn locate(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, menu: u32, x: c_int, y: c_int, src: ?[]const u8) void {
    const cef_id = browser.*.get_identifier.?(browser);
    clearFor(cef_id);
    const slot = for (&slots) |*s| {
        if (s.* == null) break s;
    } else return;
    var v: Slot = .{ .cef_id = cef_id, .menu = menu, .x = x, .y = y };
    if (src) |b| if (b.len <= protocol.wire.max_url_bytes) {
        v.src = allocator.dupe(u8, b) catch null;
    };
    if (frame != null) {
        frame.*.base.add_ref.?(&frame.*.base);
        v.frame = frame;
    }
    // 진행을 먼저 쥔다 — DevTools 를 못 쓰면(관찰자 등록 실패) 고를 때 보조 경로만 돈다.
    slot.* = v;
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    if (!ensureObserver(host, cef_id)) return;
    _ = sendWaiting(browser, &slot.*.?, .metrics, "\"method\":\"Page.getLayoutMetrics\",\"params\":{{}}", .{});
}

/// 메뉴에서 「연속 재생」·「모든 제어 기능 표시」를 골랐다. 찾기가 끝났으면 곧바로, 아직이면 결과가 오면 바꾼다.
pub fn act(browser: [*c]c.cef_browser_t, menu: u32, prop: Prop) void {
    const s = slotOf(browser.*.get_identifier.?(browser)) orelse return;
    if (s.menu != menu or s.action != null) return;
    s.action = prop;
    if ((s.stage == .metrics or s.stage == .locate) and s.waiting != 0) return; // 결과가 오면 이어 간다
    if (s.node != 0) resolve(browser, s) else fallback(s);
}

/// 메뉴가 끝났다 — 고르지 않았으면 쥔 것을 놓는다(고른 것은 진행을 마치고 놓는다).
pub fn menuEnded(cef_id: c_int, menu: u32) void {
    for (&slots) |*s| if (s.*) |v| if (v.cef_id == cef_id and v.menu == menu and v.action == null) clear(s);
}

/// 닫히는 브라우저 — 진행과 관찰자 등록을 놓는다.
pub fn forget(cef_id: c_int) void {
    clearFor(cef_id);
    for (&registrations) |*r| if (r.*) |v| if (v.cef_id == cef_id) {
        object.release(v.reg);
        r.* = null;
    };
}

/// view(DIP) 자리 → 문서(CSS px) 자리 — 스크롤(`pageX`·`pageY`)과 페이지 배율(`zoom` — CSS 대 DIP)로.
fn documentPoint(metrics: ?std.json.Value, x: c_int, y: c_int) struct { x: i64, y: i64 } {
    var page_x: f64 = 0;
    var page_y: f64 = 0;
    var zoom: f64 = 1;
    if (metrics) |m| if (m == .object) if (m.object.get("cssVisualViewport")) |vv| if (vv == .object) {
        page_x = number(vv.object.get("pageX")) orelse 0;
        page_y = number(vv.object.get("pageY")) orelse 0;
        zoom = number(vv.object.get("zoom")) orelse 1;
        if (!(zoom > 0)) zoom = 1;
    };
    const fx = @as(f64, @floatFromInt(x)) / zoom + page_x;
    const fy = @as(f64, @floatFromInt(y)) / zoom + page_y;
    return .{ .x = @intFromFloat(std.math.clamp(@round(fx), -1e9, 1e9)), .y = @intFromFloat(std.math.clamp(@round(fy), -1e9, 1e9)) };
}

fn number(v: ?std.json.Value) ?f64 {
    const value = v orelse return null;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn findNode(browser: [*c]c.cef_browser_t, s: *Slot, metrics: ?std.json.Value) void {
    const p = documentPoint(metrics, s.x, s.y);
    if (!sendWaiting(browser, s, .locate, "\"method\":\"DOM.getNodeForLocation\",\"params\":{{\"x\":{d},\"y\":{d},\"includeUserAgentShadowDOM\":false}}", .{ p.x, p.y })) {
        if (s.action != null) fallback(s);
    }
}

fn resolve(browser: [*c]c.cef_browser_t, s: *Slot) void {
    if (!sendWaiting(browser, s, .resolve, "\"method\":\"DOM.resolveNode\",\"params\":{{\"backendNodeId\":{d},\"objectGroup\":\"maru-media\"}}", .{s.node})) fallback(s);
}

fn call(browser: [*c]c.cef_browser_t, s: *Slot, object_id: []const u8) void {
    // 그 요소가 미디어이고 주소가 메뉴가 알린 주소와 같을 때만 뒤집는다 — 아니면(다른 사이트 iframe 요소·그사이 바뀐 자리) 보조 경로로.
    const src_arg: []const u8 = if (s.src) |b| b else "";
    if (!sendWaiting(browser, s, .call, "\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"objectId\":{f},\"functionDeclaration\":\"function(p,s){{if(!(this instanceof HTMLMediaElement))return 'not-media';if(s&&this.currentSrc!==s)return 'other';this[p]=!this[p];return 'ok'}}\",\"arguments\":[{{\"value\":\"{s}\"}},{{\"value\":{f}}}],\"returnByValue\":true}}", .{ std.json.fmt(object_id, .{}), @tagName(s.action.?), std.json.fmt(src_arg, .{}) })) fallback(s);
}

/// 쥔 객체(`maru-media`)를 놓는다 — 답은 기다리지 않는다.
fn releaseObjects(browser: [*c]c.cef_browser_t) void {
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Runtime.releaseObjectGroup\",\"params\":{{\"objectGroup\":\"maru-media\"}}}}", .{takeId()}) catch return;
    _ = send(browser, json);
}

/// 메뉴가 온 frame 에서 그 주소의 미디어가 딱 하나면 뒤집는다(다른 프로세스 iframe — 사용자 결정 2026-10-05). 그 뒤 놓는다.
/// 주소가 없거나(`srcObject` 등) 주소 상한보다 길면 아무것도 하지 않는다. 그림자 DOM 안은 보지 못한다.
fn fallback(s: *Slot) void {
    defer clearFor(s.cef_id);
    const prop = s.action orelse return;
    const src = s.src orelse return;
    if (s.frame == null or src.len == 0) return;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    code.print(allocator, "(function(){{var s={f};var m=[].filter.call(document.querySelectorAll('audio,video'),function(e){{return e.currentSrc===s}});if(m.length===1)m[0].{s}=!m[0].{s}}})()", .{ std.json.fmt(src, .{}), @tagName(prop), @tagName(prop) }) catch return;
    var script = std.mem.zeroes(c.cef_string_t);
    library.setString(browsers.state.api, &script, code.items);
    defer browsers.state.api.string_utf16_clear(&script);
    var url = std.mem.zeroes(c.cef_string_t);
    s.frame.*.execute_java_script.?(s.frame, &script, &url, 0);
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < (1 << 30) or browser == null) return;
    const s = slotOf(browser.*.get_identifier.?(browser)) orelse return;
    if (s.waiting != id) return;
    s.waiting = 0;
    const bytes: []const u8 = if (result) |r| @as([*]const u8, @ptrCast(r))[0..size] else "";
    const parsed = if (success != 0) std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null else null;
    defer if (parsed) |p| p.deinit();
    const value: ?std.json.Value = if (parsed) |p| p.value else null;
    switch (s.stage) {
        // 배율·스크롤을 못 받았으면 view 좌표 그대로 찾는다(스크롤하지 않은 페이지는 같다 — 주소 확인이 엉뚱한 요소를 막는다).
        .metrics => findNode(browser, s, value),
        .locate => {
            if (value) |v| if (v == .object) if (v.object.get("backendNodeId")) |n| if (n == .integer) {
                s.node = n.integer;
            };
            if (s.action != null) {
                if (s.node != 0) resolve(browser, s) else fallback(s);
            }
        },
        .resolve => {
            const object_id: ?[]const u8 = blk: {
                const v = value orelse break :blk null;
                if (v != .object) break :blk null;
                const o = v.object.get("object") orelse break :blk null;
                if (o != .object) break :blk null;
                const oid = o.object.get("objectId") orelse break :blk null;
                break :blk if (oid == .string) oid.string else null;
            };
            if (object_id) |oid| call(browser, s, oid) else fallback(s);
        },
        .call => {
            const ok = blk: {
                const v = value orelse break :blk false;
                if (v != .object) break :blk false;
                const r = v.object.get("result") orelse break :blk false;
                if (r != .object) break :blk false;
                const rv = r.object.get("value") orelse break :blk false;
                break :blk rv == .string and std.mem.eql(u8, rv.string, "ok");
            };
            releaseObjects(browser);
            if (ok) clearFor(s.cef_id) else fallback(s);
        },
    }
}
