//! 우클릭 메뉴의 미디어 항목(W6h② — Chrome 「연속 재생」·「모든 제어 기능 표시」). CEF 메뉴에는 미디어 명령이 없다(착수 전 실측 —
//! 기본 모델은 뒤로·앞으로·인쇄·소스 보기뿐). 그래서 sidecar 가 프로세스 안 DevTools 로 그 자리의 요소를 찾아 바꾼다:
//!
//! 1. 우클릭할 때 그 자리의 노드를 미리 찾는다 — 메뉴가 떠 있는 동안 배치가 바뀌어도 우클릭한 그 요소를 바꾸게. CEF 가 주는 자리는
//!    view(화면) 좌표인데 `DOM.getNodeForLocation` 은 **문서** 좌표다(실측 — 500 px 스크롤한 페이지에 view 좌표를 그대로 주면 「No node
//!    found」, W6h② 적대 검증) — `Page.getLayoutMetrics` 의 스크롤(과 pinch 배율)로 바꿔 찾는다(`metrics` → `locate`).
//! 2. 고르면 `DOM.resolveNode` → `Runtime.callFunctionOn` 으로 `loop`·`controls` 를 메뉴에 보인 체크의 반대값으로 둔다(Chrome 과 같다 —
//!    뒤집지 않는다, 2 회차) — 그 요소가 미디어이고, 그 문서가 메뉴가 온 frame 과 같은 출처이고(3·4 회차), 주소가 메뉴가 알린 주소와
//!    같을 때만(앞 32 KiB 와 길이로 — 1 회차). 아니면 3 으로. 노드를 객체로 못 얻으면(그사이 문서가 바뀌었다) 아무것도 하지 않는다(4 회차).
//!    쥔 객체는 끝나면 놓는다(`objectGroup`). 우클릭마다 DevTools 호출 둘(배율·노드), 고르면 셋(객체·호출·놓기).
//! 3. 다른 프로세스의 iframe(다른 사이트)이면 1 은 그 iframe 요소에서 멈춘다(실측) — 메뉴가 온 frame(그 iframe — 실측)에서 메뉴가
//!    알린 주소와 같은 미디어가 **딱 하나**면 그것을 바꾼다(사용자 결정 2026-10-05 — 둘 이상이면 아무것도 하지 않는다).
//!
//! `controls` 는 속성을 바꾼다 — Chrome 은 페이지가 보지 못하는 내부 값만 바꾼다(차이 — 페이지가 `controls` 를 다시 끄면 따른다).
//! 응답은 1 ms 안에 같은 UI 스레드로 온다(실측). 메뉴(`context_menu.Held`)는 답하면 곧 끝나므로 진행은 여기 따로 쥔다 — 브라우저마다
//! 하나(브라우저에 메뉴는 하나다). 메시지 번호는 다른 DevTools 사용처(권한·알림 — 0·20000 부터 오른다)와 섞이지 않게 높은 대역이다.
//! 관찰자 등록은 첫 미디어 우클릭부터 브라우저가 닫힐 때까지 둔다 — 그동안 그 브라우저의 DevTools 결과가 관찰자를 지난다(CPU 만 —
//! 콜백 안에서 등록을 놓는 위험을 피했다, W6h② 적대 검증 1 회차).

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
    /// 고른 뒤의 값 — 메뉴에 보인 체크의 반대(Chrome 과 같다 — 뒤집지 않는다: 메뉴가 떠 있는 동안 페이지가 바꿨어도 사용자가 본 것의
    /// 반대로, W6h② 적대 검증 2 회차).
    want: bool = false,
    /// 메뉴가 알린 미디어 주소(확인·보조 경로 — 소유). wire 주소 상한까지의 앞부분이고 `src_len` 이 전체 길이다 — 더 긴 주소(`data:`)는
    /// 앞부분과 길이로 확인하고 보조 경로는 쓰지 않는다(W6h② 적대 검증 1 회차).
    src: ?[]u8 = null,
    src_len: usize = 0,
    /// 메뉴가 온 frame 의 출처(`scheme://host[:port]`, 소유 — 그 출처의 문서 요소만 바꾼다: 같은 프로세스의 다른 출처 iframe 을 그 자리로
    /// 옮겨도, W6h② 적대 검증 3 회차). 주소 전체가 아니라 출처다 — 메뉴가 떠 있는 동안 플레이어가 해시·경로를 바꿔도 되게(4 회차).
    /// http·https 가 아니면(빈 문서·`data:` 등) null — 확인하지 않는다.
    doc: ?[]u8 = null,
    /// 메뉴가 온 frame(보조 경로 — 참조 하나).
    frame: [*c]c.cef_frame_t = null,
};

var slots: [registry_mod.capacity]?Slot = @splat(null);
/// 브라우저마다의 관찰자 등록(놓으면 끝난다).
var registrations: [registry_mod.capacity]?struct { cef_id: c_int, reg: [*c]c.cef_registration_t } = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
/// 읽는 응답 상한 — 우리가 묻는 것(배율·노드 번호·객체 번호·짧은 결과)은 이보다 훨씬 작다.
const max_result_bytes = 64 * 1024;
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
    if (v.doc) |b| allocator.free(b);
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
        observer.on_dev_tools_agent_detached = &onDetached;
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
    // 힙에 만든다 — 주소(32 KiB 까지)가 실린다(고정 1 KiB 로는 서명 URL 처럼 긴 주소에서 늘 실패했다, 1 회차).
    const json = std.fmt.allocPrint(allocator, "{{\"id\":{d}," ++ fmt ++ "}}", .{id} ++ args) catch return false;
    defer allocator.free(json);
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
    // 앞 진행이 노드를 쥐었을 수 있다(고른 뒤 답을 기다리는 사이 다시 우클릭) — 놓고 버린다(1 회차).
    if (slotOf(cef_id)) |old| if (old.stage == .resolve or old.stage == .call) releaseObjects(browser);
    clearFor(cef_id);
    const slot = for (&slots) |*s| {
        if (s.* == null) break s;
    } else return;
    var v: Slot = .{ .cef_id = cef_id, .menu = menu, .x = x, .y = y };
    if (src) |b| {
        v.src = allocator.dupe(u8, b[0..@min(b.len, protocol.wire.max_url_bytes)]) catch null;
        if (v.src != null) v.src_len = b.len;
    }
    if (frame != null) {
        frame.*.base.add_ref.?(&frame.*.base);
        v.frame = frame;
        const url = frame.*.get_url.?(frame);
        if (url != null) {
            defer browsers.state.api.string_userfree_utf16_free(url);
            var utf8 = std.mem.zeroes(c.cef_string_utf8_t);
            _ = browsers.state.api.string_utf16_to_utf8(url.*.str, url.*.length, &utf8);
            defer browsers.state.api.string_utf8_clear(&utf8);
            if (utf8.str != null) if (protocol.new_tab.originOf(utf8.str[0..utf8.length])) |o| {
                v.doc = allocator.dupe(u8, o) catch null;
            };
        }
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
pub fn act(browser: [*c]c.cef_browser_t, menu: u32, prop: Prop, want: bool) void {
    const s = slotOf(browser.*.get_identifier.?(browser)) orelse return;
    if (s.menu != menu or s.action != null) return;
    s.action = prop;
    s.want = want;
    if ((s.stage == .metrics or s.stage == .locate) and s.waiting != 0) return; // 결과가 오면 이어 간다
    if (s.node != 0) resolve(browser, s) else fallback(s);
}

/// 메뉴가 끝났다 — 고르지 않았으면 쥔 것을 놓는다(고른 것은 진행을 마치고 놓는다).
pub fn menuEnded(cef_id: c_int, menu: u32) void {
    for (&slots) |*s| if (s.*) |v| if (v.cef_id == cef_id and v.menu == menu and v.action == null) clear(s);
}

/// 렌더러가 죽었다 — 그 브라우저의 진행을 놓는다(기다리던 답이 새 렌더러로 다시 가거나 오지 않을 수 있다, 4 회차). 등록은 둔다.
pub fn rendererGone(cef_id: c_int) void {
    clearFor(cef_id);
}

/// 닫히는 브라우저 — 진행과 관찰자 등록을 놓는다.
pub fn forget(cef_id: c_int) void {
    clearFor(cef_id);
    for (&registrations) |*r| if (r.*) |v| if (v.cef_id == cef_id) {
        object.release(v.reg);
        r.* = null;
    };
}

/// view(DIP) 자리 → 문서(CSS px) 자리 — 스크롤(`pageX`·`pageY`)과 `cssVisualViewport.zoom`(pinch 배율 — maru 는 페이지 확대(⌘+)가 없어
/// 1 이다)으로.
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
    // 그 요소가 미디어이고 같은 출처의 문서이고 주소가 메뉴가 알린 주소와 같을 때만 고른 값으로 둔다 — 아니면(다른 사이트 iframe 요소·그사이
    // 바뀐 자리) 보조 경로로.
    // 주소는 앞부분(`s`)과 전체 길이(`n`)로 본다(긴 `data:` 주소). 주소를 모르면(복사 실패) 확인하지 않는다.
    const src_arg: []const u8 = if (s.src) |b| b else "";
    if (!sendWaiting(browser, s, .call, "\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"objectId\":{f},\"functionDeclaration\":\"function(p,s,n,w,u){{'use strict';try{{if(!(this instanceof HTMLMediaElement))return 'not-media';if(u&&this.ownerDocument.location.origin!==u)return 'other';var c=this.currentSrc;if(n&&(c.length!==n||c.slice(0,s.length)!==s))return 'other';this[p]=w;return 'ok'}}catch(e){{return 'err'}}}}\",\"arguments\":[{{\"value\":\"{s}\"}},{{\"value\":{f}}},{{\"value\":{d}}},{{\"value\":{}}},{{\"value\":{f}}}],\"returnByValue\":true}}", .{ std.json.fmt(object_id, .{}), @tagName(s.action.?), std.json.fmt(src_arg, .{}), s.src_len, s.want, std.json.fmt(s.doc orelse "", .{}) })) {
        releaseObjects(browser); // 이미 쥐었다(resolveNode) — 놓는다(1 회차)
        fallback(s);
    }
}

/// 쥔 객체(`maru-media`)를 놓는다 — 답은 기다리지 않는다.
fn releaseObjects(browser: [*c]c.cef_browser_t) void {
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Runtime.releaseObjectGroup\",\"params\":{{\"objectGroup\":\"maru-media\"}}}}", .{takeId()}) catch return;
    _ = send(browser, json);
}

/// 메뉴가 온 frame 에서(같은 출처일 때만) 그 주소의 미디어가 딱 하나면 고른 값으로 둔다(다른 프로세스 iframe — 사용자 결정 2026-10-05).
/// 그 뒤 놓는다.
/// 주소가 없거나(`srcObject` 등) 주소 상한보다 길면 아무것도 하지 않는다. 그림자 DOM 안은 보지 못한다.
fn fallback(s: *Slot) void {
    defer clearFor(s.cef_id);
    const prop = s.action orelse return;
    const src = s.src orelse return;
    if (s.frame == null or src.len == 0 or src.len != s.src_len) return; // 앞부분뿐이면 같은 주소인지 모른다
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    code.print(allocator, "(function(){{'use strict';try{{var u={f};if(u&&location.origin!==u)return;var s={f};var m=[].filter.call(document.querySelectorAll('audio,video'),function(e){{return e.currentSrc===s}});if(m.length===1)m[0].{s}={}}}catch(e){{}}}})()", .{ std.json.fmt(s.doc orelse "", .{}), std.json.fmt(src, .{}), @tagName(prop), s.want }) catch return;
    var script = std.mem.zeroes(c.cef_string_t);
    library.setString(browsers.state.api, &script, code.items);
    defer browsers.state.api.string_utf16_clear(&script);
    var url = std.mem.zeroes(c.cef_string_t);
    s.frame.*.execute_java_script.?(s.frame, &script, &url, 0);
}

/// DevTools agent 가 떨어졌다(기다리던 답은 오지 않는다 — 렌더러가 죽을 때는 오지 않는 것으로 보여 `rendererGone` 이 따로 놓는다, 4 회차)
/// — 그 브라우저의 진행을 놓는다(1 회차). 등록은 브라우저가 닫힐 때 놓는다(관찰자 콜백 안에서 등록을 놓지 않는다).
fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    clearFor(browser.*.get_identifier.?(browser));
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < (1 << 30) or browser == null) return;
    const s = slotOf(browser.*.get_identifier.?(browser)) orelse return;
    if (s.waiting != id) return;
    s.waiting = 0;
    // 응답 크기는 페이지가 정할 수 있다(거대한 `id` 의 노드 설명 등) — 상한을 넘으면 읽지 않고 실패로(3 회차).
    const bytes: []const u8 = if (result != null and size <= max_result_bytes) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
    const parsed = if (success != 0 and bytes.len != 0) std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null else null;
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
            // 노드를 못 얻었다(그사이 문서가 바뀌었다 — 같은 주소로 다시 불러온 새 문서의 요소를 보조 경로로 바꾸지 않게, 4 회차): 하지 않는다.
            // 보조 경로가 필요한 다른 사이트 iframe 은 iframe 요소로 얻어져 `call` 에서 갈린다.
            if (object_id) |oid| call(browser, s, oid) else clearFor(s.cef_id);
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
