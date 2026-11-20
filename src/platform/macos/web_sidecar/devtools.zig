//! maru 가 부르는 DevTools 메서드(W9-0b — 에이전트용 브라우저 제어의 바닥). 프로세스 안 DevTools(`send_dev_tools_message`)로
//! 보내고 결과를 조각(`devtools_result_data`)과 끝(`devtools_result`)으로 돌려준다 — 원격 디버깅 포트는 열지 않는다. 호출 표와
//! 메시지 만들기는 `devtools_table.zig`(CEF 를 모르는 부분).
//!
//! - 관찰자는 브라우저마다 처음 부를 때 등록하고 브라우저가 닫힐 때 놓는다(콜백 안에서 등록을 놓지 않는다 — 미디어 메뉴와 같다).
//!   결과는 그 브라우저의 모든 관찰자에게 가므로 제 번호 대역(`devtools_table.id_base`)만 고른다. `on_dev_tools_message`(원시 메시지)는
//!   frame 세션의 답과 root 의 떼임 사건만 본다(아래 「frame 호출」 — root 의 답은 결과 콜백으로 온다).
//! - 답을 못 받는 호출: DevTools 가 떨어지면(`on_dev_tools_agent_detached`)·렌더러가 죽으면(detach 가 오지 않을 수 있다 — 미디어
//!   메뉴 실측)·브라우저가 닫히면 `detached`, 시한(`devtools_stale_ms`)이 지나면 `expired` 로 답한다 — 기다리는 호출이 있는 동안
//!   UI 스레드에 주기 작업을 걸어 본다(새 호출이 올 때만 보면 maru 가 자리를 쥔 채 새 호출을 보내지 않아 영영 풀리지 않는다). 답은
//!   늘 `browser_closed` 앞이다. 판정자는 `MARU_WEB_TEST_DEVTOOLS_STALE_MS` 로 시한을 줄인다.
//! - 결과는 UI 스레드에서 막히는 쓰기로 보낸다 — 상한(16 MiB)까지 보내는 동안 다른 탭도 기다린다. maru 는 결과를 기다리는 동안
//!   한 번에 더 읽는다(`web_osr.pump`).
//! - **frame 호출**(wire 30 — 사용자 결정 2026-11-20 「iframe·폴더 둘 다」): `frame` 이 있는 호출은 그 다른 사이트 iframe 의 자식 세션으로 보낸다 —
//!   세션은 `devtools_frames.zig` 의 표가 쥐고, 없으면 root 로 `Target.getTargetInfo`(이 탭의 page 타깃) → `Target.getTargets`(그 OOPIF 의 타깃을 만든다 — 그
//!   iframe 의 부모 사슬이 이 탭에 닿아야) → `Target.attachToTarget{flatten}` 를 보내고 호출을 세운다. 붙기의 답은 관찰자 콜백 안에서 오므로 세운 호출은 UI task 로 보낸다(콜백 안에서 보내면 `check_reentrancy` — 흉내의 같은
//!   사고). 세션의 답은 원시 메시지로만 온다(`onRaw` — 끝의 sessionId). 세션이 사라지면(root 의 `Target.detachedFromTarget`·그 세션의 렌더러 죽음·
//!   「Session … not found」) 그 세션으로 보낸 호출은 그 CDP 오류로, 세운 호출은 `send_failed`(보내지 않았다)로 답한다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("devtools_table.zig");
const frames_mod = @import("devtools_frames.zig"); // wire 30: 다른 사이트 iframe 의 세션
const sw_raw = @import("net_body_sw.zig"); // 원시 메시지 가르기(끝의 sessionId·머리의 id·사건 이름)

const allocator = std.heap.c_allocator;
const BrowserId = message.BrowserId;
const Status = message.DevtoolsStatus;

var table: table_mod.Table = .{};
var frames: frames_mod.Table = .{};
var frame_task: c.cef_task_t = undefined;
var frame_task_ready = false;
var frame_task_posted = false;
var idle_task: c.cef_task_t = undefined;
var idle_posted = false;
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

/// 기다리는 호출이 있으면 짧은 시한(kick 의 것 — 판정자가 더 줄였으면 그것)의 1/4 뒤에 한 번 본다(이미 걸었으면 그대로). kick 이
/// 없어도 같은 주기다 — 걸어 둔 긴 검사 뒤에 온 kick 이 늦게 풀리지 않게(검사는 자리 여덟 개를 훑을 뿐이다).
fn ensureSweep() void {
    if (sweep_posted or table.isEmpty()) return;
    // 걸지 못하면(CEF 가 끝나는 중) 걸었다고 두지 않는다 — 다음 호출이 다시 건다.
    sweep_posted = browsers.state.api.post_delayed_task(c.TID_UI, &sweep_task, @max(@divTrunc(@min(table.stale_ms, table.kick_stale_ms), 4), 100)) != 0;
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
        error.Forbidden => .invalid_request, // W9d②: Network.enable·disable·Fetch.* — 본문 기록과 같은 도메인을 쓴다
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
        // 세션이 붙기를 기다리다 시한 — 보내지 않았다(넣기면 「넣었다」 가 아니다 — 공격 A1-3).
        answer(gone.browser, gone.call, if (gone.parked) .send_failed else .expired);
        // 그 세션으로 보낸 호출이 시한이다 — 그 세션의 셈을 돌려놓는다(안 그러면 쉰 세션으로 영영 떼어지지 않았다 — 적대 검증 3·4 회차 MED). 같은
        // frame 에 다시 붙은 새 세션의 셈은 건드리지 않는다(세대).
        if (!gone.parked and gone.frame_len > 0 and gone.phase == .sent) if (frames.findGen(gone.browser, gone.frame(), gone.sent_gen)) |sess| {
            sess.inflight -|= 1;
        };
    }
}

fn ensureObserver(host: [*c]c.cef_browser_host_t, cef_id: c_int, browser: BrowserId) bool {
    if (!observer_ready) {
        observer_ready = true;
        observer = object.zeroed(c.cef_dev_tools_message_observer_t);
        object.staticRefCounted(&observer.base);
        observer.on_dev_tools_method_result = &onResult;
        observer.on_dev_tools_agent_detached = &onDetached;
        observer.on_dev_tools_message = &onRaw; // wire 30: frame 세션의 답·root 의 떼임 사건
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
    if (call.frame_len > 0) return dispatchFrameCall(host, call);
    const json = table.buildMessage(allocator, call) catch |e| return drop(call, switch (e) {
        error.InvalidParams => .invalid_request,
        error.OutOfMemory => .send_failed,
    });
    defer allocator.free(json);
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) drop(call, .send_failed);
}

// ── wire 30: 다른 사이트 iframe(OOPIF)의 세션 ──────────────────────────────────────────────────────────────────────────────

/// frame 호출 — 그 세션이 있으면 그리로, 붙는 중이면 세우고, 없으면(걷기의 처음 호출이면) 붙이기를 시작하고 세운다. 원격 객체를 싣는 호출은 새로
/// 붙지 않는다(새 세션에서는 그 객체를 모른다 — `send_failed`: 확실히 안 갔다).
fn dispatchFrameCall(host: [*c]c.cef_browser_host_t, call: *table_mod.Call) void {
    const now = nowMs();
    if (frames.find(call.browser, call.frame())) |sess| switch (sess.state) {
        .ready => return sendInSession(host, call, sess, now),
        .info, .listing, .attaching => {
            call.parked = true;
            return;
        },
    };
    if (!frames_mod.attachAllowed(call.method())) return drop(call, .send_failed);
    const opened = switch (frames.open(call.browser, call.frame(), now)) {
        .full => return drop(call, .busy),
        .ok => |o| o,
    };
    // 비운 세션은 그 탭의 host 로 뗀다(다른 탭의 것일 수 있다 — 3 회차).
    if (opened.evicted) |old| if (hostOf(old.browser)) |old_host| {
        defer object.release(old_host);
        sendDetach(old_host, old.sid());
    };
    const sess = opened.session;
    sess.state = .info;
    sess.req = frames.takeId();
    call.parked = true;
    // 먼저 이 탭 자신의 page 타깃 id(붙을 iframe 의 부모 사슬이 여기 닿아야 한다 — 적대 검증 3·4 회차). 그 답 뒤 task 가 목록(그 OOPIF 의 타깃을
    // 만든다 — 찾기 전에는 없다, 실측 probe-attach-oopif)을 보낸다. 번호를 **보내기 전에** 적었다 — 브라우저 쪽 답은 보내는 중에 올 수 있다.
    if (!sendRoot(host, sess.req, "Target.getTargetInfo", "{}")) {
        frames.remove(sess);
        drop(call, .send_failed);
    }
    ensureIdleSweep();
}

fn sendInSession(host: [*c]c.cef_browser_host_t, call: *table_mod.Call, sess: *frames_mod.Session, now: i64) void {
    call.parked = false;
    const json = table.buildMessageIn(allocator, call, sess.sid()) catch |e| return drop(call, switch (e) {
        error.InvalidParams => .invalid_request,
        error.OutOfMemory => .send_failed,
    });
    defer allocator.free(json);
    sess.inflight += 1;
    sess.last_ms = now;
    call.sent_gen = sess.gen;
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) {
        sess.inflight -|= 1;
        drop(call, .send_failed);
    }
}

fn sendRoot(host: [*c]c.cef_browser_host_t, id: i32, method: []const u8, params: []const u8) bool {
    var jb: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch return false;
    return host.*.send_dev_tools_message.?(host, json.ptr, json.len) != 0;
}

fn sendDetach(host: [*c]c.cef_browser_host_t, sid: []const u8) void {
    var pb: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"sessionId\":\"{s}\"}}", .{sid}) catch return;
    _ = sendRoot(host, frames.takeId(), "Target.detachFromTarget", params);
}

fn hostOf(browser: BrowserId) ?[*c]c.cef_browser_host_t {
    const entry = browsers.state.registry.byId(browser) orelse return null;
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = b.*.get_host.?(b);
    if (host == null) return null;
    return host;
}

/// 세션이 붙지 못했다 — 세운 호출을 답한다(그 frame 이 iframe 타깃이 아니다·없다면 「No frame」 CDP 오류, 그 밖은 `send_failed`).
fn failSession(sess: *frames_mod.Session, cdp_error: ?[]const u8) void {
    const browser = sess.browser;
    var fb: [frames_mod.max_frame_bytes]u8 = undefined;
    const f = fb[0..sess.frame_len];
    @memcpy(f, sess.frame());
    frames.remove(sess);
    while (table.nextParked(browser, f)) |call| {
        if (cdp_error) |e| {
            var gone = table.take(call);
            defer gone.deinit(allocator);
            answerBytes(gone.browser, gone.call, false, e);
        } else drop(call, .send_failed);
    }
}

/// 세션이 사라졌다 — 그 세션으로 보낸 호출은 「Session … not found」 CDP 오류로(엔진이 문서가 사라졌다로 읽는다 — 넣은 뒤면 「넣었다」), 세운 호출은
/// `send_failed` 로 답하고 잊는다(다음 걷기가 다시 붙는다).
fn loseSession(sess: *frames_mod.Session) void {
    const browser = sess.browser;
    var fb: [frames_mod.max_frame_bytes]u8 = undefined;
    const f = fb[0..sess.frame_len];
    @memcpy(f, sess.frame());
    frames.remove(sess);
    while (table.takeSentIn(browser, f)) |v| {
        var gone = v;
        defer gone.deinit(allocator);
        answerBytes(gone.browser, gone.call, false, frames_mod.session_gone_error);
    }
    while (table.nextParked(browser, f)) |call| drop(call, .send_failed);
}

/// 관찰자 콜백 밖(UI task) — 목록의 답이 온 세션에 붙기를 보내고, 붙은 세션의 세운 호출을 보낸다.
fn frameTask(_: [*c]c.cef_task_t) callconv(.c) void {
    frame_task_posted = false;
    for (&frames.slots) |*slot| if (slot.*) |*sess| {
        const host = hostOf(sess.browser) orelse {
            // 탭이 없다 — 보낸 호출도 세운 호출도 답한다(ready 면 보낸 호출이 남았다 — 3 회차).
            loseSession(sess);
            continue;
        };
        defer object.release(host);
        switch (sess.state) {
            .listing => if (sess.req == 0) {
                sess.req = frames.takeId();
                if (!sendRoot(host, sess.req, "Target.getTargets", "{\"filter\":[{\"type\":\"iframe\"}]}")) failSession(sess, null);
            },
            .attaching => if (sess.req == 0) {
                sess.req = frames.takeId();
                var pb: [160]u8 = undefined;
                const params = std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{sess.frame()}) catch {
                    failSession(sess, null);
                    continue;
                };
                if (!sendRoot(host, sess.req, "Target.attachToTarget", params)) failSession(sess, null);
            },
            .ready => while (table.nextParked(sess.browser, sess.frame())) |call| sendInSession(host, call, sess, nowMs()),
            .info => {},
        }
    };
}

fn postFrameTask() void {
    if (!frame_task_ready) {
        frame_task_ready = true;
        frame_task = object.zeroed(c.cef_task_t);
        object.staticRefCounted(&frame_task.base);
        frame_task.execute = &frameTask;
        idle_task = object.zeroed(c.cef_task_t);
        object.staticRefCounted(&idle_task.base);
        idle_task.execute = &idleSweep;
    }
    if (!frame_task_posted) frame_task_posted = browsers.state.api.post_task(c.TID_UI, &frame_task) != 0;
}

/// 쉰 세션을 뗀다(공격 A1-4 — 마지막 쓴 지 `idle_ms` 넘고 보낸 호출이 없는 것만). 세션이 남아 있으면 다시 건다.
fn idleSweep(_: [*c]c.cef_task_t) callconv(.c) void {
    idle_posted = false;
    const now = nowMs();
    while (frames.takeIdle(now)) |old| {
        if (hostOf(old.browser)) |host| {
            defer object.release(host);
            sendDetach(host, old.sid());
        }
    }
    ensureIdleSweep();
}

fn ensureIdleSweep() void {
    if (idle_posted or frames.isEmpty()) return;
    postFrameTask(); // task 객체를 만든다(이미 있으면 그대로) — 붙기·세운 호출도 함께 본다
    idle_posted = browsers.state.api.post_delayed_task(c.TID_UI, &idle_task, @intCast(@divTrunc(frames_mod.idle_ms, 2))) != 0;
}

/// root 의 답 가운데 이 표의 것(목록·붙기 — 떼기의 답은 버린다). 관찰자 콜백 안이다 — 보내기는 task 로.
fn frameRootAnswered(id: c_int, success: bool, bytes: []const u8) void {
    const sess = frames.byReq(id) orelse return; // 떼기의 답
    switch (sess.state) {
        .info => {
            const own = (if (success) frames_mod.ownTargetOf(allocator, bytes, &sess.own_buf) else null) orelse return failSession(sess, frames_mod.no_frame_error);
            sess.own_len = @intCast(own.len);
            sess.state = .listing;
            sess.req = 0; // task 가 번호를 매겨 보낸다
            postFrameTask();
        },
        .listing => {
            // 그 frame 이 iframe 타깃이고 그 부모 사슬이 이 탭에 닿아야(다른 탭의 iframe·page·worker 에 붙지 않는다 — 3·4 회차).
            if (!success) return failSession(sess, frames_mod.no_frame_error);
            if (!frames_mod.targetsHaveIframeIn(allocator, bytes, sess.frame(), sess.own())) return failSession(sess, frames_mod.not_this_tab_error);
            sess.state = .attaching;
            sess.req = 0; // task 가 번호를 매겨 보낸다
            postFrameTask();
        },
        .attaching => {
            const sid = (if (success) frames_mod.sessionIdOf(bytes) else null) orelse return failSession(sess, frames_mod.no_frame_error);
            @memcpy(sess.sid_buf[0..sid.len], sid);
            sess.sid_len = @intCast(sid.len);
            sess.state = .ready;
            sess.last_ms = nowMs();
            postFrameTask();
        },
        .ready => {},
    }
}

/// 원시 메시지 — 우리 frame 세션의 답이면 그 호출에 답하고 1(삼킨다). root 의 `Target.detachedFromTarget`(우리 세션)이면 그 세션을 잊는다(0 — 다른
/// 관찰자도 본다). 그 밖은 0.
fn onRaw(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, message_ptr: ?*const anyopaque, size: usize) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (browser == null or message_ptr == null or frames.isEmpty()) return 0;
    const m = @as([*]const u8, @ptrCast(message_ptr.?))[0..size];
    const sid = sw_raw.sessionTail(m) orelse {
        if (sw_raw.eventMethod(m)) |ev| if (std.mem.eql(u8, ev, "Target.detachedFromTarget")) {
            if (frames_mod.sessionIdOf(m)) |gone_sid| if (frames.bySid(gone_sid)) |sess| loseSession(sess);
        };
        return 0;
    };
    const sess = frames.bySid(sid) orelse return 0;
    const rid = sw_raw.resultId(m) orelse {
        // 그 세션의 사건 — 켠 도메인이 없어 거의 오지 않는다. 렌더러가 죽었으면 답은 오지 않는다(공격 A1-7).
        if (sw_raw.eventMethod(m)) |ev| if (std.mem.eql(u8, ev, "Inspector.targetCrashed") or std.mem.eql(u8, ev, "Inspector.detached")) loseSession(sess);
        return 1;
    };
    // 그 세션으로 보낸 호출만(번호는 렌더러가 쓴 글 — 다른 탭·root 의 호출을 가로채거나 큰 수로 터지지 않게, 적대 검증 13 회차).
    var call = table.takeSessionAnswer(rid, sess.browser, sess.frame(), sess.gen) orelse return 1;
    defer call.deinit(allocator);
    sess.inflight -|= 1;
    sess.last_ms = nowMs();
    const body = frames_mod.rawBody(m, sid) orelse {
        // 모양을 모르는 답 — 그 호출은 렌더러에서 돌았다(「안 갔다」 가 아니다 — 4 회차 LOW: 넣기면 다시 올려 두 번이 된다).
        answerBytes(call.browser, call.call, false, frames_mod.session_gone_error);
        return 1;
    };
    if (body.body.len > message.max_devtools_result_bytes) {
        answer(call.browser, call.call, .too_large);
        return 1;
    }
    answerBytes(call.browser, call.call, body.ok, body.body);
    return 1;
}

/// 결과 바이트를 조각과 끝으로 보낸다(root·frame 세션 같이).
fn answerBytes(browser: BrowserId, call: u32, ok: bool, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(message.devtools_chunk_bytes, bytes.len - off);
        browsers.state.writer.send(.{ .devtools_result_data = .{ .browser = browser, .call = call, .bytes = bytes[off..][0..n] } }) catch return;
        off += n;
    }
    browsers.state.writer.send(.{ .devtools_result = .{
        .browser = browser,
        .call = call,
        .status = if (ok) .ok else .cdp_error,
        .size = @intCast(bytes.len),
    } }) catch {};
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id >= frames_mod.id_base and id < frames_mod.id_end) {
        // 목록은 브라우저 전체의 iframe 이라 클 수 있다 — 자르지 않는다(잘린 JSON 은 「frame 이 없다」 로 굳었다 — 3·4 회차 LOW). 결과 상한 안.
        const all: []const u8 = if (result != null) @as([*]const u8, @ptrCast(result.?))[0..@min(size, message.max_devtools_result_bytes)] else "";
        return frameRootAnswered(id, success != 0, all);
    }
    var call = table.takeByCdpId(id) orelse return; // 다른 사용처(권한·알림·미디어 메뉴)의 결과
    defer call.deinit(allocator);
    // 결과 크기는 페이지가 정할 수 있다 — 상한을 넘으면 보내지 않는다.
    if (size > message.max_devtools_result_bytes) return answer(call.browser, call.call, .too_large);
    const bytes: []const u8 = if (result != null) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
    if (call.frame_len > 0) {
        // frame 호출이 root 로 답을 받았다 — 그 세션이 이미 없다(Chromium 이 렌더러에 보내기 **전에** 「Session … not found」 로 돌려준다): 그 호출은
        // 가지 않았다 — `send_failed`(넣기면 「넣지 않았다」 — 2 회차: 그 오류를 「넣었다」 로 읽었다). 그 세션을 잊는다(같은 세대만).
        const gone = success == 0 and std.mem.indexOf(u8, bytes, "ession with given id not found") != null;
        if (frames.findGen(call.browser, call.frame(), call.sent_gen)) |sess| {
            sess.inflight -|= 1;
            if (gone) loseSession(sess);
        }
        if (gone) return answer(call.browser, call.call, .send_failed);
    }
    answerBytes(call.browser, call.call, success != 0, bytes);
}

fn failBrowser(browser: BrowserId) void {
    // 그 탭의 frame 세션도 잊는다(떨어진 root·죽은 렌더러·닫힌 탭 — 떼지 않는다).
    while (frames.takeForBrowser(browser)) |_| {}
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
