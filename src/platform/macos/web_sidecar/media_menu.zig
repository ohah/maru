//! 우클릭 메뉴의 미디어 항목(W6h② — Chrome 「연속 재생」·「모든 제어 기능 표시」). CEF 메뉴에는 미디어 명령이 없다(착수 전 실측 —
//! 기본 모델은 뒤로·앞으로·인쇄·소스 보기뿐). 그래서 sidecar 가 프로세스 안 DevTools 로 그 자리의 요소를 찾아 바꾼다:
//!
//! 1. 우클릭할 때(`locate`) `DOM.getNodeForLocation`(view 좌표 — 맨 위 문서와 같은 프로세스 iframe 을 지난다)로 노드를 미리
//!    찾는다 — 메뉴가 떠 있는 동안 배치가 바뀌어도 우클릭한 그 요소를 바꾸게.
//! 2. 고르면(`act`) `DOM.resolveNode` → `Runtime.callFunctionOn` 으로 `loop`·`controls` 를 뒤집는다(그 요소가 미디어일 때만).
//! 3. 다른 프로세스의 iframe(다른 사이트)이면 1 은 그 iframe 요소에서 멈춘다(실측) — 메뉴가 온 frame(그 iframe — 실측)에서
//!    메뉴가 알린 주소와 같은 미디어가 **딱 하나**면 그것을 바꾼다(사용자 결정 2026-10-05 — 둘 이상이면 아무것도 하지 않는다).
//!
//! 응답은 1 ms 안에 같은 UI 스레드로 온다(실측). 메뉴(`context_menu.Held`)는 답하면 곧 끝나므로 진행은 여기 따로 쥔다 — 브라우저마다
//! 하나(브라우저에 메뉴는 하나다). 메시지 번호는 다른 DevTools 사용처(권한·알림 — 1 부터 오른다)와 섞이지 않게 높은 대역이다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");

const allocator = std.heap.c_allocator;

pub const Prop = enum { loop, controls };

const Stage = enum { locate, resolve, call };

const Slot = struct {
    cef_id: c_int,
    menu: u32,
    /// 지금 기다리는 메시지 번호(0 = 없음).
    waiting: c_int = 0,
    stage: Stage = .locate,
    /// 찾은 노드(0 = 아직·못 찾음).
    node: i64 = 0,
    /// 고른 것(아직 안 골랐으면 null — 찾기 결과를 받아 두기만 한다).
    action: ?Prop = null,
    /// 메뉴가 알린 미디어 주소(보조 경로 — 소유).
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

/// 우클릭한 미디어(동영상·오디오) — 그 자리의 노드를 미리 찾는다. 그 브라우저의 앞 진행은 버린다. `src` 는 이 모듈이 복사한다,
/// `frame` 은 참조를 하나 더한다.
pub fn locate(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, menu: u32, x: c_int, y: c_int, src: ?[]const u8) void {
    const cef_id = browser.*.get_identifier.?(browser);
    clearFor(cef_id);
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    if (!ensureObserver(host, cef_id)) return;
    const slot = for (&slots) |*s| {
        if (s.* == null) break s;
    } else return;
    var v: Slot = .{ .cef_id = cef_id, .menu = menu };
    if (src) |b| if (b.len <= protocol.wire.max_url_bytes) {
        v.src = allocator.dupe(u8, b) catch null;
    };
    if (frame != null) {
        frame.*.base.add_ref.?(&frame.*.base);
        v.frame = frame;
    }
    const id = takeId();
    var buf: [160]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"DOM.getNodeForLocation\",\"params\":{{\"x\":{d},\"y\":{d},\"includeUserAgentShadowDOM\":false}}}}", .{ id, x, y }) catch return;
    v.waiting = id;
    slot.* = v;
    if (!send(browser, json)) slot.*.?.waiting = 0;
}

/// 메뉴에서 「연속 재생」·「모든 제어 기능 표시」를 골랐다. 찾기가 끝났으면 곧바로, 아직이면 결과가 오면 바꾼다.
pub fn act(browser: [*c]c.cef_browser_t, menu: u32, prop: Prop) void {
    const s = slotOf(browser.*.get_identifier.?(browser)) orelse return;
    if (s.menu != menu or s.action != null) return;
    s.action = prop;
    if (s.stage == .locate and s.waiting != 0) return; // 결과가 오면 이어 간다
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

fn resolve(browser: [*c]c.cef_browser_t, s: *Slot) void {
    const id = takeId();
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"DOM.resolveNode\",\"params\":{{\"backendNodeId\":{d}}}}}", .{ id, s.node }) catch return fallback(s);
    s.stage = .resolve;
    s.waiting = id;
    if (!send(browser, json)) fallback(s);
}

fn call(browser: [*c]c.cef_browser_t, s: *Slot, object_id: []const u8) void {
    const id = takeId();
    var buf: [640]u8 = undefined;
    // 그 요소가 미디어일 때만 뒤집는다 — 아니면(다른 사이트 iframe 요소) 보조 경로로.
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"objectId\":{f},\"functionDeclaration\":\"function(p){{if(!(this instanceof HTMLMediaElement))return 'not-media';this[p]=!this[p];return 'ok'}}\",\"arguments\":[{{\"value\":\"{s}\"}}],\"returnByValue\":true}}}}", .{ id, std.json.fmt(object_id, .{}), @tagName(s.action.?) }) catch return fallback(s);
    s.stage = .call;
    s.waiting = id;
    if (!send(browser, json)) fallback(s);
}

/// 메뉴가 온 frame 에서 그 주소의 미디어가 딱 하나면 뒤집는다(다른 프로세스 iframe — 사용자 결정 2026-10-05). 그 뒤 놓는다.
fn fallback(s: *Slot) void {
    defer clearFor(s.cef_id);
    const prop = s.action orelse return;
    const src = s.src orelse return;
    if (s.frame == null) return;
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
            if (ok) clearFor(s.cef_id) else fallback(s);
        },
    }
}
