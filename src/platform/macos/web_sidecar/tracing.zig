//! 성능 trace 의 한 주인(W9e② — docs/plans/web-osr-backend.md 「W9e② 결정·실측」). maru 의 `trace`(시작·멈춤·버림)를 받아 CDP `Tracing.*`·`IO.*`
//! 를 **스스로** 낸다(제 번호 대역 [1<<25, 1<<25 + 1<<20) — maru 를 거친 DevTools 호출의 `Tracing.*`·`IO.*` 는 지킴이 막는다). Chromium 의 trace 는
//! **브라우저 전체에 하나**다(실측 t2) — 그래서 이 파일도 한 번에 하나만 쥔다.
//!
//! 차례: 그 탭 가족(그 탭·그 탭이 연 탭 사슬)마다 `Page.enable`·`Page.getFrameTree`(프레임 집합의 씨앗) → 숨은 탭이면 **focus 흉내**(사용자 결정 5 —
//! `Emulation.setFocusEmulationEnabled(true)`: 숨은 탭도 프레임·rAF 를 낸다, PHASE0_v3 a) → `Tracing.start`(`trace_plan.startParams` — 고정 범주·압축
//! 없는 스트림·32 MiB — Chromium 의 gzip 은 보이는 탭이 없으면 끝나지 않는다, `startParams` 의 주석) → 기록(가족의 `Page.frameAttached`·`frameNavigated` 로 집합을 키운다, 버퍼 90 % 면 멈춤) → 멈춤(요청·시간·버퍼): **focus 흉내를
//! 곧 끄고**(완료를 기다리지 않는다 — ATTACK_4 #12), `Tracing.end`(`Page.disable` 은 보내지 않는다 — CEF 는 브라우저마다 DevTools
//! 세션이 하나라 Blink 가 위치 보정·알림 대리의 `addScriptToEvaluateOnNewDocument` 를 지웠다: 판정 tr-page-scripts-kept, 구현 적대 리뷰 H1) → `tracingComplete` 의 스트림을 `IO.read` 128 KiB 씩 →
//! sidecar 가 gzip 으로 묶어(`trace_plan.GzStream`) `trace_data`(16 KiB 조각, 보내는 줄의 본문 몫을 먼저 잡는다) → `IO.close` → `trace_frames` → `trace_state{done}`.
//!
//! 가족은 기록 중에도 자란다(W9e② 적대 검증 1–10 회차): 기록 중 가족이 연 팝업도 가족이다(opener 사슬 — A2-1, `browserAdded`), bfcache 되살림은
//! 그 탭의 프레임 트리를 다시 받는다(A2-2), 멈춤 요청 뒤 읽는 동안 온 가족의 프레임 사건도 더한다(A2-3 — 멈춤 직전에 붙은 iframe 의 이벤트가 trace
//! 에 들었는데 그 사건이 `Tracing.end` 뒤에 왔다). 기록이 시작되면 가족 탭마다 격리된 world 에서 빈 `requestAnimationFrame` 을 걸어 그 위젯의
//! `SetLayerTreeId` 를 trace 에 남긴다(A1-1 — maru 가 그것으로 가족의 layer tree 를 가른다, `trace_plan.bind_world_name`). 보이던 탭이 기록 중에
//! 숨으면 그때 focus 흉내를 켠다(A6-1 — 사용자 결정 5 「측정하는 동안」). 받은 gzip 이 상한(16 MiB)에 닿을 것 같으면 거기서 잘라 `done` 에
//! `truncated` 를 싣는다(A4-1 — 화면이 바쁜 페이지의 스크린샷은 거의 압축되지 않는다).
//!
//! 버림(사람이 그 가족을 씀 — 누름·키·IME·굴림·편집 명령·놓음·사람의 이동, 프레임 집합이 넘침, maru 의 abort): 곧 `trace_state{discarded}` 를 보내고, Chromium 의 전역
//! trace 가 끝날 때까지(`tracingComplete`) 자리를 쥐었다가 스트림을 읽지 않고 닫는다. 그 탭이 닫히면 Chromium 이 trace 를 함께 끝낸다(완료 사건
//! 없음 — 실측 t4 K2) — `failed{tab_closed}` 로 곧 자리를 푼다.
//!
//! focus 흉내 끔은 렌더러가 죽은 동안이면 쌓았다가 그 탭의 다음 주 프레임 `on_load_start` 에 낸다(죽은 동안 보낸 끔은 35 s 무응답 — PHASE0_v3 F2;
//! 켠 채 죽으면 새 렌더러에도 남는다 — F3).
//!
//! **DevTools 관찰자 콜백 안에서는 CDP 를 곧 내지 않는다**(W9e② 적대 검증 15 회차 V-15 — W9d② 의 Target·워커 세션 명령과 같은 원칙): 답·사건
//! 콜백(`onResult`·`onEvent`) 안에서 낸 명령은 줄(`queue`)에 넣어 다음 UI task(`onFlush`)에서 낸다. 브라우저 쪽 처리기(`Tracing.*`·`IO.close`)는
//! 보내는 자리에서 곧 답을 관찰자들에게 돌리는데, CEF 가 관찰자 목록을 도는 중이면 그 목록을 다시 돌게 된다(실측 로그 「Check failed:
//! !check_reentrancy」 — 고치기 전에는 trace 마다 `IO.close` 에서 났다). 늦게 온 `Tracing.start` 의 답 안에서 곧 `Tracing.end` 를 내면 Chromium 의
//! trace 처리기가 시작을 마무리하기 전에 세션을 끝내, 약 0.5 s 뒤 그 처리기의 타이머가 지운 세션을 건드려 **CEF 브라우저 프로세스가 SIGSEGV**
//! 로 죽었다(멈춘 탭의 trace 5/5·시작 답 전의 사람 누름·abort 4/4 — 모든 웹 탭이 렌더러를 잃는다). 다음 task 로 미루면(1 ms·1.5 s 두 값 실측)
//! 살았다. 관찰자 떼기(`finish` 의 `dropAllRegs`)도 콜백 안이면 다음 task 로 미룬다(그 사이 새 trace 가 시작됐으면 떼지 않는다).
//!
//! 스레드: 모두 UI 스레드(CEF 의 관찰자·불러오기 처리기·명령 처리·지연 task).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const trace_plan = @import("trace_plan.zig");
const events = @import("events.zig");

const msg = protocol.message;
const BrowserId = msg.BrowserId;
const gpa = std.heap.c_allocator;

pub const id_base: i32 = 1 << 25;
pub const id_end: i32 = (1 << 25) + (1 << 20);

/// 시작 시한(같은 프로세스의 긴 작업에 `Tracing.start` 가 3.7 s 늦었다 — ATTACK_2 #9), 읽기 시한(30 s trace 를 읽는 데 314 ms — t8).
const start_timeout_ms: u64 = 5_000;
const read_timeout_ms: u64 = 30_000;
const read_retry_ms: u64 = 20;

const Phase = enum { idle, starting, recording, stopping, reading, draining };

const CallKind = enum { page_enable, frame_tree, focus_on, focus_off, start, end, reload, io_read, io_close, bind_world, bind_raf };

/// 가족의 한 탭 — 주 프레임 id(격리된 world 를 만들 곳)와 layer tree 묶기를 낸 적이 있는가.
const Member = struct {
    cef_id: c_int,
    main_buf: [msg.max_trace_frame_id_bytes]u8 = undefined,
    main_len: usize = 0,
    bound: bool = false,

    fn main(self: *const Member) ?[]const u8 {
        return if (self.main_len == 0) null else self.main_buf[0..self.main_len];
    }
};

const Session = struct {
    browser: BrowserId,
    cef_id: c_int,
    generation: u32,
    phase: Phase = .starting,
    duration_ms: u32,
    screenshots: bool,
    reload: bool,
    start_sent_ms: u64 = 0,
    started_ms: u64 = 0,
    stop_at_ms: u64 = 0,
    read_deadline_ms: u64 = 0,
    covered_ms: u32 = 0,
    /// 측정에 focus 흉내를 썼다(`trace_state.focus_emulated` — 끈 뒤에도 참).
    focus_emulated: bool = false,
    /// focus 흉내가 아직 켜져 있다(`releaseFocus` 가 끈다).
    focus_held: bool = false,
    stop_reason: msg.TraceReason = .requested,
    data_loss: bool = false,
    start_answered: bool = false,
    stream_buf: [64]u8 = undefined,
    stream_len: usize = 0,
    offset: u32 = 0,
    reserved: usize = 0,
    /// 받은 원 JSON 을 묶는 gzip(읽는 동안만 — `finish` 가 놓는다).
    gz: ?*trace_plan.GzStream = null,
    /// 스트림 끝을 읽었다 — 남은 gzip 을 다 보내면 끝낸다.
    eof: bool = false,
    read_inflight: bool = false,
    retry_at_ms: u64 = 0,
    /// gzip 상한에 닿을 것 같아 거기서 잘랐다(A4-1 — `trace_state.truncated`).
    truncated: bool = false,
    frames: trace_plan.FrameSet = .{},
    /// 기록하는 동안 그 탭의 렌더러 프로세스에 가족 밖의 프레임이 들 수 있었다(`emulation.processShared` — 시작·프레임이 바뀔 때·멈출 때 모은다,
    /// `trace_state.shared_process` — 사용자 결정 12: 거짓이면 maru 가 막힌 탭의 컴포지터 이벤트도 가족 것으로 남긴다).
    shared: bool = false,
    family: [registry_mod.capacity]Member = undefined,
    family_len: usize = 0,

    fn stream(self: *const Session) []const u8 {
        return self.stream_buf[0..self.stream_len];
    }

    fn member(self: *Session, cef_id: c_int) ?*Member {
        for (self.family[0..self.family_len]) |*f| if (f.cef_id == cef_id) return f;
        return null;
    }

    fn inFamily(self: *const Session, cef_id: c_int) bool {
        for (self.family[0..self.family_len]) |f| if (f.cef_id == cef_id) return true;
        return false;
    }

    fn addMember(self: *Session, cef_id: c_int) bool {
        if (self.inFamily(cef_id) or self.family_len >= self.family.len) return false;
        self.family[self.family_len] = .{ .cef_id = cef_id };
        self.family_len += 1;
        return true;
    }

    /// 프레임 사건·트리를 집합에 더하는 단계 — 멈춘 뒤 읽는 동안도(A2-3, 집합은 `trace_frames` 를 보내기 직전에 닫는다).
    fn collecting(self: *const Session) bool {
        return switch (self.phase) {
            .starting, .recording, .stopping, .reading => true,
            .idle, .draining => false,
        };
    }
};

var session: ?Session = null;
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
var regs: [registry_mod.capacity]struct { cef_id: c_int = 0, reg: [*c]c.cef_registration_t = null } = @splat(.{});
var next_id: i32 = id_base;
var pending: [512]struct { id: i32 = 0, cef_id: c_int = 0, kind: CallKind = .start, generation: u32 = 0 } = @splat(.{});
/// 렌더러가 죽어 쌓아 둔 focus 흉내 끔(그 탭의 다음 주 프레임 `on_load_start` 에).
var focus_off_pending: [registry_mod.capacity]c_int = @splat(0); // 브라우저마다 한 칸(구현 적대 리뷰 LOW — 8 칸이면 넘쳐 잃었다)
var dead: [registry_mod.capacity]c_int = @splat(0);
var tick_task: c.cef_task_t = undefined;
var tick_at_ms: u64 = 0;
var read_buf: [trace_plan.read_bytes + 1024]u8 = undefined;

/// DevTools 관찰자 콜백 안의 깊이(V-15 — 0 이 아니면 `call` 은 줄에 넣는다).
var callback_depth: u32 = 0;
/// 콜백 안에서 낸 CDP 명령(차례대로 — 줄이 비지 않았으면 콜백 밖의 명령도 그 뒤에 서서 차례를 지킨다). 한 콜백이 내는 것은 많아야 가족 수
/// (32)의 묶기 + 몇 개다.
const Queued = struct { cef_id: c_int, id: i32, kind: CallKind, generation: u32, len: u16, json: [queued_json_bytes]u8 };
const queued_json_bytes: usize = 1536;
var queue: [96]Queued = undefined;
var queue_len: usize = 0;
var flush_task: c.cef_task_t = undefined;
var flush_posted = false;
/// 콜백 안에서 세션이 끝나 관찰자 떼기를 미뤘다.
var regs_drop_pending = false;

fn logOn() bool {
    return std.c.getenv("MARU_WEB_TEST_TRACE_LOG") != null;
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn initObserver() void {
    if (observer_ready) return;
    observer_ready = true;
    observer = object.zeroed(c.cef_dev_tools_message_observer_t);
    object.staticRefCounted(&observer.base);
    observer.on_dev_tools_method_result = &onResult;
    observer.on_dev_tools_event = &onEvent;
    observer.on_dev_tools_agent_detached = &onDetached;
    tick_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&tick_task.base);
    tick_task.execute = &onTick;
    flush_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&flush_task.base);
    flush_task.execute = &onFlush;
}

fn writer() *events.Writer {
    return browsers.state.writer;
}

fn browserOf(reg: *const registry_mod.Entry) [*c]c.cef_browser_t {
    return @ptrCast(@alignCast(reg.handle));
}

fn isDead(cef_id: c_int) bool {
    for (dead) |d| if (d == cef_id) return true;
    return false;
}

fn setDead(cef_id: c_int, value: bool) void {
    for (&dead) |*d| if (d.* == cef_id) {
        if (!value) d.* = 0;
        return;
    };
    if (!value) return;
    for (&dead) |*d| if (d.* == 0) {
        d.* = cef_id;
        return;
    };
}

fn ensureReg(cef_id: c_int, host: [*c]c.cef_browser_host_t) void {
    for (regs) |r| if (r.cef_id == cef_id and r.reg != null) return;
    for (&regs) |*r| if (r.reg == null) {
        r.* = .{ .cef_id = cef_id, .reg = host.*.add_dev_tools_message_observer.?(host, &observer) };
        return;
    };
}

fn dropReg(cef_id: c_int) void {
    for (&regs) |*r| if (r.cef_id == cef_id and r.reg != null) {
        object.release(r.reg);
        r.* = .{};
    };
}

fn dropAllRegs() void {
    for (&regs) |*r| if (r.reg != null) {
        object.release(r.reg);
        r.* = .{};
    };
}

fn takeId() i32 {
    const id = next_id;
    next_id = if (next_id + 1 >= id_end) id_base else next_id + 1;
    return id;
}

/// CDP 한 호출을 낸다(관찰자를 그 브라우저에 붙인다). DevTools 관찰자 콜백 안이거나 줄에 앞선 명령이 있으면 줄에 넣고 다음 UI task 에서 낸다
/// (V-15 — 머리 주석). 보내지 못하면(줄이 차도) 거짓 — 줄에서 보내지 못한 것은 `queuedSendFailed` 가 같은 실패로 다룬다.
fn call(cef_id: c_int, kind: CallKind, generation: u32, method: []const u8, params: []const u8) bool {
    initObserver();
    if (browsers.state.registry.byCefId(cef_id) == null) return false;
    const id = takeId();
    var jb: [queued_json_bytes]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, if (params.len == 0) "{}" else params }) catch return false;
    for (&pending) |*p| if (p.id == 0) {
        p.* = .{ .id = id, .cef_id = cef_id, .kind = kind, .generation = generation };
        break;
    };
    if (callback_depth > 0 or queue_len > 0) {
        if (queue_len >= queue.len) {
            untrack(id);
            return false;
        }
        const q = &queue[queue_len];
        q.* = .{ .cef_id = cef_id, .id = id, .kind = kind, .generation = generation, .len = @intCast(json.len), .json = undefined };
        @memcpy(q.json[0..json.len], json);
        queue_len += 1;
        postFlush();
        if (logOn()) std.debug.print("trace: cdp queued cef={d} {s}\n", .{ cef_id, method });
        return true;
    }
    if (!sendNow(cef_id, json, method)) {
        untrack(id);
        return false;
    }
    return true;
}

fn untrack(id: i32) void {
    for (&pending) |*p| if (p.id == id) {
        p.* = .{};
    };
}

/// 지금 보낸다(콜백 밖에서만 — `call`·`onFlush`). 세션이 있을 때만 관찰자를 붙인다(세션 밖의 명령 — 끝난 세션의 `IO.close`·쌓아 둔 focus
/// 끔 — 은 답을 쓰지 않는다; 붙이면 다음 세션까지 남는다).
fn sendNow(cef_id: c_int, json: []const u8, what: []const u8) bool {
    const reg = browsers.state.registry.byCefId(cef_id) orelse return false;
    const b = browserOf(reg);
    const host = b.*.get_host.?(b);
    if (host == null) return false;
    defer object.release(host);
    if (session != null) ensureReg(cef_id, host);
    if (logOn()) std.debug.print("trace: cdp cef={d} {s}\n", .{ cef_id, what });
    return host.*.send_dev_tools_message.?(host, json.ptr, json.len) != 0;
}

fn postFlush() void {
    if (flush_posted) return;
    flush_posted = browsers.state.api.post_task(c.TID_UI, &flush_task) != 0;
}

/// 다음 UI task — 콜백 안에서 쌓은 명령을 차례로 낸다(이때 생긴 답의 콜백이 다시 쌓으면 그 뒤에 서고 다음 task 가 낸다).
fn onFlush(_: [*c]c.cef_task_t) callconv(.c) void {
    flush_posted = false;
    if (regs_drop_pending) {
        regs_drop_pending = false;
        if (session == null) dropAllRegs(); // 그 사이 새 trace 가 시작됐으면 그 등록을 그대로 쓴다
    }
    const n = queue_len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const q = queue[i]; // 보내는 동안 콜백이 줄 끝에 더할 수 있다(앞 n 칸은 건드리지 않는다)
        const method = methodOf(q.json[0..q.len]);
        // 적대 검증 v20c L1: 줄에 든 focus 흉내는 보낼 때 탭 닫힘·렌더러 죽음을 다시 본다 — 줄에 넣은 콜백과 이 task 사이에 렌더러가 죽을 수
        // 있다(죽은 렌더러에 `Emulation.*` 를 내지 않는다 — W9e① E11 은 `setDeviceMetricsOverride` 로 host 가 죽었다). 끔은 새 렌더러에 낸다
        // (`focusOff` 가 쌓는다), 켬은 버린다(죽은 렌더러의 흉내는 함께 사라졌다), 닫히는 탭에는 둘 다 내지 않는다.
        if (q.kind == .focus_on or q.kind == .focus_off) {
            const reg = browsers.state.registry.byCefId(q.cef_id);
            if (reg == null or reg.?.closing or isDead(q.cef_id)) {
                untrack(q.id);
                if (reg != null and !reg.?.closing and q.kind == .focus_off) focusOff(q.cef_id);
                if (logOn()) std.debug.print("trace: queued {s} skipped cef={d} (closed or renderer gone)\n", .{ @tagName(q.kind), q.cef_id });
                continue;
            }
        }
        if (!sendNow(q.cef_id, q.json[0..q.len], method)) queuedSendFailed(q);
    }
    std.mem.copyForwards(Queued, queue[0 .. queue_len - n], queue[n..queue_len]);
    queue_len -= n;
    if (queue_len > 0) postFlush();
}

/// 로그용 — 줄에 넣은 JSON 의 메서드 이름.
fn methodOf(json: []const u8) []const u8 {
    const key = "\"method\":\"";
    const at = std.mem.indexOf(u8, json, key) orelse return "?";
    const rest = json[at + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
}

/// 줄에서 보내지 못했다(탭이 그 사이 닫혔다 등) — 곧 보냈다면 부른 쪽이 했을 실패를 한다.
fn queuedSendFailed(q: Queued) void {
    untrack(q.id);
    const s = &(session orelse return);
    if (s.generation != q.generation) return;
    switch (q.kind) {
        .start => if (s.phase == .starting) fail(s, .cdp_error),
        .end => if (s.phase == .stopping) fail(s, .cdp_error),
        .io_read => if (s.phase == .reading) {
            s.read_inflight = false;
            fail(s, .cdp_error);
        },
        else => {},
    }
}

fn sendState(s: *const Session, state: msg.TraceStateKind, reason: msg.TraceReason) void {
    const before_data = state == .starting or state == .recording;
    writer().send(.{ .trace_state = .{
        .truncated = state == .done and s.truncated,
        .shared_process = state == .done and s.shared,
        .browser = s.browser,
        .generation = s.generation,
        .state = state,
        .reason = reason,
        .focus_emulated = s.focus_emulated,
        .data_loss = if (before_data) false else s.data_loss,
        .covered_ms = s.covered_ms,
        .gz_bytes = if (before_data) 0 else s.offset,
        .frames = if (before_data) 0 else @intCast(@min(s.frames.count(), msg.max_trace_frames_total)),
    } }) catch {};
}

fn sendBare(browser: BrowserId, generation: u32, state: msg.TraceStateKind, reason: msg.TraceReason) void {
    writer().send(.{ .trace_state = .{ .browser = browser, .generation = generation, .state = state, .reason = reason } }) catch {};
}

fn schedule(at_ms: u64) void {
    initObserver();
    const now = nowMs();
    if (tick_at_ms != 0 and tick_at_ms <= at_ms and tick_at_ms > now) return; // 더 이른 것이 이미 있다
    tick_at_ms = at_ms;
    _ = browsers.state.api.post_delayed_task(c.TID_UI, &tick_task, @intCast(@max(at_ms -| now, 1)));
}

// ── focus 흉내 ───────────────────────────────────────────────────────────────────────────────────────────

fn focusOff(cef_id: c_int) void {
    if (isDead(cef_id)) {
        for (focus_off_pending) |p| if (p == cef_id) return;
        for (&focus_off_pending) |*p| if (p.* == 0) {
            p.* = cef_id;
            return;
        };
        return;
    }
    _ = call(cef_id, .focus_off, 0, "Emulation.setFocusEmulationEnabled", "{\"enabled\":false}");
}

// ── maru 의 명령 ─────────────────────────────────────────────────────────────────────────────────────────

pub fn apply(v: msg.Trace) void {
    initObserver();
    switch (v.action) {
        .start => start(v),
        .stop => if (session) |*s| {
            if (s.generation != v.generation) return;
            switch (s.phase) {
                .recording => stopRecording(s, .requested),
                .starting => discard(s, .aborted), // 기록이 시작되기 전의 멈춤 — 덮은 시간이 없다
                else => {},
            }
        },
        .abort => if (session) |*s| {
            if (s.generation != v.generation) return;
            switch (s.phase) {
                .starting, .recording, .stopping, .reading => discard(s, .aborted),
                else => {},
            }
        },
    }
}

fn start(v: msg.Trace) void {
    if (session) |s| {
        if (s.phase != .idle) return sendBare(v.browser, v.generation, .failed, .busy);
    }
    const reg = browsers.state.registry.byId(v.browser) orelse return sendBare(v.browser, v.generation, .failed, .not_found);
    if (reg.closing) return sendBare(v.browser, v.generation, .failed, .not_found);
    session = .{ .browser = v.browser, .cef_id = reg.cef_id, .generation = v.generation, .duration_ms = v.duration_ms, .screenshots = v.screenshots, .reload = v.reload };
    const s = &session.?;
    familyOf(s);
    s.shared = @import("emulation.zig").processShared(s.cef_id); // 결정 12
    // 프레임 집합의 씨앗과 그 뒤의 사건 — 가족마다.
    for (s.family[0..s.family_len]) |f| seedMember(s, f.cef_id);
    // 숨은 탭이면 측정하는 동안만 focus 흉내(사용자 결정 5).
    if (reg.hidden and !isDead(reg.cef_id)) {
        if (call(reg.cef_id, .focus_on, s.generation, "Emulation.setFocusEmulationEnabled", "{\"enabled\":true}")) {
            s.focus_emulated = true;
            s.focus_held = true;
        }
    }
    var pb: [1024]u8 = undefined;
    const params = trace_plan.startParams(v.screenshots, &pb) catch unreachable; // 고정 인자 — 버퍼에 든다(시험)
    s.start_sent_ms = nowMs();
    if (!call(reg.cef_id, .start, s.generation, "Tracing.start", params)) return fail(s, .cdp_error);
    schedule(s.start_sent_ms + start_timeout_ms);
    if (logOn()) std.debug.print("trace: start b={d} gen={d} hidden={} family={d}\n", .{ v.browser, v.generation, reg.hidden, s.family_len });
}

/// 프레임 집합의 씨앗(그 탭의 지금 프레임 트리)과 그 뒤의 사건을 청한다.
fn seedMember(s: *Session, cef_id: c_int) void {
    _ = call(cef_id, .page_enable, s.generation, "Page.enable", "{}");
    _ = call(cef_id, .frame_tree, s.generation, "Page.getFrameTree", "{}");
}

fn openerOf(e: *const registry_mod.Entry) c_int {
    const b = browserOf(e);
    const host = b.*.get_host.?(b);
    if (host == null) return 0;
    defer object.release(host);
    return host.*.get_opener_identifier.?(host);
}

/// T 가족 — T 와 연 탭 사슬이 T 에 닿는 등록된 브라우저(`get_opener_identifier`).
fn familyOf(s: *Session) void {
    s.family[0] = .{ .cef_id = s.cef_id };
    s.family_len = 1;
    var changed = true;
    while (changed) {
        changed = false;
        for (&browsers.state.registry.slots) |*slot| {
            const e = &(slot.* orelse continue);
            if (e.closing or s.inFamily(e.cef_id)) continue;
            const opener = openerOf(e);
            if (opener != 0 and s.inFamily(opener) and s.addMember(e.cef_id)) changed = true;
        }
    }
}

/// A1-1: 가족 탭의 위젯이 trace 에 `SetLayerTreeId` 를 남기게 한다 — 그 탭 주 프레임의 격리된 world 에서 빈 `requestAnimationFrame` 하나(주
/// 스레드 프레임 하나를 부른다). 기록 중에만(그 프레임이 trace 에 들어야 한다), 탭마다 한 번.
fn bindLayerTree(s: *Session, m: *Member) void {
    if (s.phase != .recording or m.bound) return;
    const id = m.main() orelse return; // 트리 답이 오면 다시 부른다
    var pb: [256]u8 = undefined;
    const params = trace_plan.bindWorldParams(id, &pb) catch return;
    m.bound = true;
    _ = call(m.cef_id, .bind_world, s.generation, "Page.createIsolatedWorld", params);
}

/// focus 흉내를 끈다(한 번만 — 멈춤·폐기·실패에서 곧, 완료를 기다리지 않는다: 멈춘 렌더러에서 영영 켜져 있지 않게 — ATTACK_4 #12).
fn releaseFocus(s: *Session) void {
    if (!s.focus_held) return;
    s.focus_held = false;
    focusOff(s.cef_id);
}

fn stopRecording(s: *Session, reason: msg.TraceReason) void {
    s.shared = s.shared or @import("emulation.zig").processShared(s.cef_id); // 결정 12 — 끝의 프레임도
    s.covered_ms = @intCast(@min(nowMs() -| s.started_ms, std.math.maxInt(u32)));
    s.stop_reason = reason;
    releaseFocus(s);
    s.phase = .stopping;
    s.read_deadline_ms = nowMs() + read_timeout_ms;
    if (!call(s.cef_id, .end, s.generation, "Tracing.end", "{}")) return fail(s, .cdp_error);
    schedule(s.read_deadline_ms);
    if (logOn()) std.debug.print("trace: stop reason={s} covered={d}\n", .{ @tagName(reason), s.covered_ms });
}

/// 버린다 — 곧 알리고, Chromium 의 전역 trace 가 끝날 때까지 자리를 쥔다(완료에 스트림을 닫는다).
fn discard(s: *Session, reason: msg.TraceReason) void {
    if (logOn()) std.debug.print("trace: discard reason={s} phase={s}\n", .{ @tagName(reason), @tagName(s.phase) });
    const was = s.phase;
    if (was == .starting or was == .recording) {
        if (was == .recording) s.covered_ms = @intCast(@min(nowMs() -| s.started_ms, std.math.maxInt(u32)));
        releaseFocus(s);
        if (s.start_answered) _ = call(s.cef_id, .end, s.generation, "Tracing.end", "{}");
    }
    sendState(s, .discarded, reason);
    switch (was) {
        .reading => {
            closeStream(s);
            finish(s);
        },
        else => {
            s.phase = .draining;
            s.read_deadline_ms = nowMs() + read_timeout_ms;
            schedule(s.read_deadline_ms);
        },
    }
}

fn fail(s: *Session, reason: msg.TraceReason) void {
    if (logOn()) std.debug.print("trace: fail reason={s} phase={s}\n", .{ @tagName(reason), @tagName(s.phase) });
    const was = s.phase;
    if (was == .starting or was == .recording) {
        releaseFocus(s);
        if (s.start_answered) _ = call(s.cef_id, .end, s.generation, "Tracing.end", "{}");
    }
    if (was == .reading) closeStream(s);
    sendState(s, .failed, reason);
    // 시작했으면 Chromium 의 전역 trace 가 끝날 때까지 자리를 쥔다(다음 start 가 「already started」 로 실패하지 않게 — t4).
    if ((was == .starting and s.start_answered) or was == .recording or was == .stopping) {
        s.phase = .draining;
        s.read_deadline_ms = nowMs() + read_timeout_ms;
        schedule(s.read_deadline_ms);
    } else if (was == .starting) {
        // 답이 아직이다 — 늦게 ok 가 오면 끝낸다(draining).
        s.phase = .draining;
        s.read_deadline_ms = nowMs() + read_timeout_ms;
        schedule(s.read_deadline_ms);
    } else finish(s);
}

fn finish(s: *Session) void {
    releaseFocus(s);
    if (s.gz) |g| g.destroy(gpa);
    s.gz = null;
    if (s.reserved > 0) writer().releaseBody(s.reserved);
    s.frames.deinit(gpa);
    // 관찰자를 떼므로(`dropAllRegs`) 아직 답이 오지 않은 호출(세대 0 의 IO.close·focus 끔 포함)의 답은 영영 오지 않는다 — 칸을 모두 비운다
    // (전에는 세대가 같은 것만 비워 trace 마다 칸이 새고, 칸이 차면 `Tracing.start` 의 답을 못 받아 전역 trace 가 켜진 채 남았다 — 구현 적대
    // 리뷰 M1). 세션은 하나뿐이고 세션 밖 호출(쌓아 둔 focus 끔)은 답을 쓰지 않는다.
    for (&pending) |*p| p.* = .{};
    session = null;
    // 관찰자 콜백 안이면 관찰자 목록을 그 자리에서 건드리지 않는다(V-15 — 다음 task 에서, 그 사이 새 trace 가 없을 때만).
    if (callback_depth > 0) {
        regs_drop_pending = true;
        postFlush();
    } else dropAllRegs();
}

fn closeStream(s: *Session) void {
    if (s.stream_len > 0) {
        var pb: [128]u8 = undefined;
        const params = std.fmt.bufPrint(&pb, "{{\"handle\":\"{s}\"}}", .{s.stream()}) catch return;
        _ = call(s.cef_id, .io_close, 0, "IO.close", params);
        s.stream_len = 0;
    }
}

// ── 읽기 ────────────────────────────────────────────────────────────────────────────────────────────────

const chunk = msg.trace_chunk_bytes;
const data_head_bytes: usize = protocol.wire.prefix_len + protocol.wire.common_len + 8 + 4 + 4 + 2;
/// 읽기 한 번에 잡는 본문 몫 — 원 JSON `read_bytes` 를 먹이면 압축기가 버퍼(창 64 KiB)와 함께 내놓을 수 있는 최대(압축이 안 되는 최악 —
/// 창 둘 + 남은 덜 찬 조각)를 조각 단위로. 끝(`GzStream.finish`)도 같은 몫 안에 든다.
const read_reserve_chunks: usize = (trace_plan.read_bytes + 2 * std.compress.flate.max_window_len) / chunk + 3;
const read_reserve_bytes: usize = read_reserve_chunks * (chunk + data_head_bytes);

fn readNext(s: *Session) void {
    if (s.read_inflight) return;
    if (s.reserved == 0) {
        if (!writer().reserveBody(read_reserve_bytes)) {
            // 보내는 줄의 본문 몫이 찼다(maru 가 잠시 읽지 않는다) — 기다리지 않고 조금 뒤에 다시.
            s.retry_at_ms = nowMs() + read_retry_ms;
            schedule(s.retry_at_ms);
            return;
        }
        s.reserved = read_reserve_bytes;
    }
    if (s.eof) return finishData(s);
    var pb: [160]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"handle\":\"{s}\",\"size\":{d}}}", .{ s.stream(), trace_plan.read_bytes }) catch return fail(s, .cdp_error);
    if (!call(s.cef_id, .io_read, s.generation, "IO.read", params)) return fail(s, .cdp_error);
    s.read_inflight = true;
}

/// 압축기가 내놓은 gzip 을 조각으로 보낸다(잡은 몫 안 — 몫은 최악을 덮는다).
fn sendReady(s: *Session) bool {
    const g = s.gz orelse return false;
    const ready = g.ready(chunk);
    if (@as(u64, s.offset) + ready.len > msg.max_trace_gz_bytes) {
        fail(s, .too_large);
        return false;
    }
    var off: usize = 0;
    while (off < ready.len) {
        const n = @min(chunk, ready.len - off);
        writer().sendBody(.{ .trace_data = .{ .browser = s.browser, .generation = s.generation, .offset = s.offset, .bytes = ready[off .. off + n] } }) catch {
            fail(s, .cdp_error);
            return false;
        };
        s.offset += @intCast(n);
        s.reserved -|= n + data_head_bytes;
        off += n;
    }
    g.took(ready.len);
    return true;
}

fn onRead(s: *Session, ok: bool, bytes: []const u8) void {
    s.read_inflight = false;
    if (!ok) return fail(s, .cdp_error);
    const r = trace_plan.parseRead(gpa, bytes, &read_buf) orelse return fail(s, .cdp_error);
    // 읽기가 나아가는 동안은 시한을 늦춘다(큰 trace 는 압축하지 않은 JSON 이 100 MB 를 넘는다 — Debug 빌드의 압축은 느리다).
    s.read_deadline_ms = nowMs() + read_timeout_ms;
    if (s.gz == null) s.gz = trace_plan.GzStream.create(gpa) catch return fail(s, .cdp_error);
    // A4-1: 이 조각을 먹이면 gzip 이 상한을 넘을 수 있다 — 여기서 자르고 앞부분으로 끝낸다(maru 의 거르기는 끝나지 않은 마지막 이벤트를 버린다,
    // 덮은 시간은 maru 가 남은 이벤트로 다시 잰다).
    if (!trace_plan.gzFits(msg.max_trace_gz_bytes, s.offset, s.gz.?.ready(1).len, r.len)) {
        s.truncated = true;
        s.eof = true;
        if (logOn()) std.debug.print("trace: truncated at gz={d}\n", .{s.offset});
        return finishData(s);
    }
    s.gz.?.feed(read_buf[0..r.len]) catch return fail(s, .cdp_error);
    if (!sendReady(s)) return;
    if (r.eof) {
        s.eof = true;
        return finishData(s);
    }
    if (s.reserved > 0) writer().releaseBody(s.reserved);
    s.reserved = 0;
    readNext(s);
}

/// 스트림 끝 — 압축을 끝내고 남은 gzip 을 보낸 뒤 스트림을 닫고 프레임 집합·`done` 을 보낸다.
fn finishData(s: *Session) void {
    if (s.gz == null) s.gz = trace_plan.GzStream.create(gpa) catch return fail(s, .cdp_error);
    s.gz.?.finish() catch return fail(s, .cdp_error);
    if (!sendReady(s)) return;
    if (s.reserved > 0) writer().releaseBody(s.reserved);
    s.reserved = 0;
    closeStream(s);
    sendFrames(s);
    sendState(s, .done, s.stop_reason);
    if (logOn()) std.debug.print("trace: done gz={d} frames={d}\n", .{ s.offset, s.frames.count() });
    finish(s);
}

fn sendFrames(s: *Session) void {
    var i: usize = 0;
    while (i < s.frames.count()) {
        var f: msg.TraceFrames = .{ .browser = s.browser, .generation = s.generation, .count = 0 };
        while (i < s.frames.count() and f.count < msg.max_trace_frame_ids) : (i += 1) {
            f.ids[f.count] = s.frames.get(i);
            f.count += 1;
        }
        writer().send(.{ .trace_frames = f }) catch return;
    }
}

// ── CDP 답·사건 ──────────────────────────────────────────────────────────────────────────────────────────

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    callback_depth += 1; // V-15: 이 안에서 낸 CDP 는 다음 task 로
    defer callback_depth -= 1;
    if (id < id_base or id >= id_end) return;
    for (&pending) |*p| if (p.id == id) {
        const kind = p.kind;
        const generation = p.generation;
        const cef_id = p.cef_id;
        p.* = .{};
        const bytes: []const u8 = if (result != null and size > 0) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
        handleResult(kind, generation, cef_id, success != 0, bytes);
        return;
    };
}

fn handleResult(kind: CallKind, generation: u32, cef_id: c_int, ok: bool, bytes: []const u8) void {
    if (logOn()) std.debug.print("trace: result {s} ok={} {s}\n", .{ @tagName(kind), ok, bytes[0..@min(bytes.len, 200)] });
    const s = &(session orelse return);
    if (s.generation != generation) return;
    switch (kind) {
        .frame_tree => if (ok) {
            if (!s.collecting()) return;
            if (!(trace_plan.collectFrameTree(gpa, bytes, &s.frames) catch false) and logOn()) std.debug.print("trace: frame tree not understood\n", .{});
            if (s.frames.overflow) return discard(s, .frames_overflow);
            if (s.member(cef_id)) |m| {
                if (trace_plan.mainFrameId(gpa, bytes, &m.main_buf)) |id| m.main_len = id.len;
                bindLayerTree(s, m);
            }
        },
        .bind_world => if (ok) {
            const ctx = trace_plan.contextIdOf(gpa, bytes) orelse return;
            var pb: [256]u8 = undefined;
            const params = trace_plan.bindRafParams(ctx, &pb) catch return;
            _ = call(cef_id, .bind_raf, s.generation, "Runtime.evaluate", params);
        },
        .start => {
            s.start_answered = ok;
            if (s.phase == .draining) {
                // 시작 전에 버렸다·실패했다 — 늦게 시작됐으면 끝낸다(완료가 자리를 푼다). 이 답의 콜백 안이라 `Tracing.end` 는 다음 task 에
                // 나간다(`call` 이 줄에 넣는다 — V-15: 여기서 곧 내면 시작을 마무리하지 못한 Chromium 처리기의 타이머가 sidecar 를 죽였다).
                if (ok) _ = call(s.cef_id, .end, s.generation, "Tracing.end", "{}") else finish(s);
                return;
            }
            if (s.phase != .starting) return;
            if (!ok) {
                const busy = std.mem.indexOf(u8, bytes, "already") != null;
                return fail(s, if (busy) .busy else .cdp_error);
            }
            s.phase = .recording;
            s.started_ms = nowMs();
            s.stop_at_ms = s.started_ms + s.duration_ms;
            schedule(s.stop_at_ms);
            if (s.reload) _ = call(s.cef_id, .reload, s.generation, "Page.reload", "{}");
            for (s.family[0..s.family_len]) |*m| bindLayerTree(s, m); // A1-1
            sendState(s, .recording, .none);
        },
        .end => if (!ok and s.phase == .stopping) fail(s, .cdp_error),
        .io_read => if (s.phase == .reading) onRead(s, ok, bytes),
        else => {},
    }
}

fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

fn onEvent(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, method_s: [*c]const c.cef_string_t, params: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    callback_depth += 1; // V-15: 이 안에서 낸 CDP 는 다음 task 로
    defer callback_depth -= 1;
    if (browser == null) return;
    var mb: [96]u8 = undefined;
    const method = library.readString(browsers.state.api, method_s, &mb);
    if (logOn()) std.debug.print("trace: event cef={d} {s} session={}\n", .{ browser.*.get_identifier.?(browser), method, session != null });
    const s = &(session orelse return);
    const cef_id = browser.*.get_identifier.?(browser);
    if (!s.inFamily(cef_id)) return;
    const p: []const u8 = if (params != null and size > 0) @as([*]const u8, @ptrCast(params.?))[0..size] else "";
    if (std.mem.startsWith(u8, method, "Page.frame")) {
        if (!s.collecting()) return; // 멈춘 뒤 읽는 동안도 더한다(A2-3)
        var ib: [msg.max_trace_frame_id_bytes]u8 = undefined;
        if (trace_plan.eventFrameId(gpa, method, p, &ib)) |id| {
            _ = s.frames.add(gpa, id) catch {};
            if (s.frames.overflow) return discard(s, .frames_overflow);
        }
        // A2-2: bfcache 되살림은 하위 프레임의 `frameAttached` 를 다시 내지 않는다 — 그 탭의 트리를 다시 받는다(가족 탭의 것이라 남을 들이지 않는다).
        // 되살린 문서는 새 world 를 받아야 하니 layer tree 묶기도 다시(트리 답이 낸다).
        if (trace_plan.isBfcacheRestore(gpa, method, p)) {
            if (s.member(cef_id)) |m| m.bound = false;
            _ = call(cef_id, .frame_tree, s.generation, "Page.getFrameTree", "{}");
        }
        return;
    }
    if (cef_id != s.cef_id) return;
    if (std.mem.eql(u8, method, "Tracing.bufferUsage")) {
        if (s.phase != .recording) return;
        const used = trace_plan.parseBufferUsage(gpa, p) orelse return;
        if (used >= trace_plan.buffer_stop_fraction) stopRecording(s, .buffer_full);
        return;
    }
    if (std.mem.eql(u8, method, "Tracing.tracingComplete")) {
        var hb: [64]u8 = undefined;
        const done = trace_plan.parseComplete(gpa, p, &hb) orelse trace_plan.Complete{ .data_loss = false, .stream = "" };
        switch (s.phase) {
            .stopping => {
                s.data_loss = done.data_loss;
                if (done.stream.len == 0) return fail(s, .cdp_error);
                @memcpy(s.stream_buf[0..done.stream.len], done.stream);
                s.stream_len = done.stream.len;
                s.phase = .reading;
                sendState(s, .receiving, .none);
                readNext(s);
            },
            .draining => {
                if (done.stream.len > 0) {
                    @memcpy(s.stream_buf[0..done.stream.len], done.stream);
                    s.stream_len = done.stream.len;
                    closeStream(s);
                }
                finish(s);
            },
            else => {},
        }
    }
}

fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    // DevTools 가 떨어졌다(렌더러 죽음 등) — trace 는 브라우저 쪽이라 계속된다(실측 t5). 기다리던 읽기가 사라지면 읽기 시한이 끝낸다.
}

// ── 시한 ────────────────────────────────────────────────────────────────────────────────────────────────

fn onTick(_: [*c]c.cef_task_t) callconv(.c) void {
    tick_at_ms = 0;
    const s = &(session orelse return);
    const now = nowMs();
    switch (s.phase) {
        .starting => if (now >= s.start_sent_ms + start_timeout_ms) return fail(s, .start_timeout) else schedule(s.start_sent_ms + start_timeout_ms),
        .recording => if (now >= s.stop_at_ms) return stopRecording(s, .duration) else schedule(s.stop_at_ms),
        .stopping => if (now >= s.read_deadline_ms) return fail(s, .read_timeout) else schedule(s.read_deadline_ms),
        .reading => {
            if (now >= s.read_deadline_ms) return fail(s, .read_timeout);
            if (!s.read_inflight and s.retry_at_ms != 0 and now >= s.retry_at_ms) {
                s.retry_at_ms = 0;
                readNext(s);
            }
            schedule(@min(s.read_deadline_ms, if (s.retry_at_ms != 0) s.retry_at_ms else s.read_deadline_ms));
        },
        .draining => if (now >= s.read_deadline_ms) finish(s) else schedule(s.read_deadline_ms),
        .idle => {},
    }
}

// ── CEF 사건 ───────────────────────────────────────────────────────────────────────────────────────────

/// maru 가 보낸 사람 입력(누름·뗌·키·IME·굴림·편집 명령·놓음 — `nav_exempt.humanUseOf`)·사람의 이동 — 그 가족을 trace 하는 중이면 버린다(사용자
/// 결정 Q2 — 사람의 입력 시각·화면이 trace 에 든다: ATTACK_3 #6).
pub fn humanInput(browser: BrowserId) void {
    const s = &(session orelse return);
    if (s.phase != .starting and s.phase != .recording) return;
    const reg = browsers.state.registry.byId(browser) orelse return;
    if (!s.inFamily(reg.cef_id)) return;
    discard(s, .human_input);
}

/// 브라우저가 등록됐다(maru 가 만든 것·이어 받은 팝업 — `browsers.register`). trace 중이고 연 탭이 가족이면 가족에 더한다(A2-1 — 기록 중 가족이
/// 연 같은 사이트 팝업은 같은 렌더러 프로세스라 그 이벤트가 trace 에 들고, 집합에 없으면 남의 프레임으로 보여 통째로 버렸다; 시작 때와 같은 길).
pub fn browserAdded(cef_id: c_int) void {
    const s = &(session orelse return);
    if (!s.collecting() or s.inFamily(cef_id)) return;
    const reg = browsers.state.registry.byCefId(cef_id) orelse return;
    const opener = openerOf(reg);
    if (opener == 0 or !s.inFamily(opener)) return;
    if (!s.addMember(cef_id)) return;
    if (logOn()) std.debug.print("trace: family += cef={d} (opener {d})\n", .{ cef_id, opener });
    seedMember(s, cef_id);
}

/// maru 가 그 탭을 숨겼다·보였다(`set_hidden`). 보이던 탭이 기록 중(또는 시작 중)에 숨으면 그때 focus 흉내를 켠다(A6-1 — 사용자 결정 5 「측정하는
/// 동안」: 숨은 채 잰 trace 가 흉내도 경고도 없이 보이는 탭 결과로 나왔다). 끄는 길은 시작 때 켠 것과 같다(멈춤·버림·실패에서 곧). 다시 보여도
/// 끝까지 켜 둔다(측정하는 동안 — 켜고 끄기를 되풀이하지 않는다).
pub fn hiddenChanged(browser: BrowserId, hidden: bool) void {
    const s = &(session orelse return);
    if (!hidden or s.browser != browser or s.focus_held) return;
    if (s.phase != .starting and s.phase != .recording) return;
    if (isDead(s.cef_id)) return;
    if (call(s.cef_id, .focus_on, s.generation, "Emulation.setFocusEmulationEnabled", "{\"enabled\":true}")) {
        s.focus_emulated = true;
        s.focus_held = true;
        if (logOn()) std.debug.print("trace: hidden mid-trace — focus emulation on\n", .{});
    }
}

/// 어느 탭이든 프레임이 시작됐다(`on_load_start`) — 기록 중이면 그 탭의 렌더러 프로세스에 가족 밖의 프레임이 들 수 있게 됐는지 모은다(결정 12 —
/// 한 번이라도 그랬으면 끝까지 참: 나간 프레임의 이벤트도 trace 에 남아 있다).
pub fn framesChanged() void {
    const s = &(session orelse return);
    if (s.shared or (s.phase != .starting and s.phase != .recording)) return;
    s.shared = @import("emulation.zig").processShared(s.cef_id);
}

/// 렌더러가 죽었다 — 그 탭의 focus 흉내 끔은 쌓는다.
pub fn rendererGone(cef_id: c_int) void {
    setDead(cef_id, true);
}

/// 주 프레임 `on_load_start` — 새 렌더러: 쌓아 둔 focus 흉내 끔을 낸다.
pub fn loadStart(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) void {
    if (browser == null or frame == null or frame.*.is_main.?(frame) == 0) return;
    const cef_id = browser.*.get_identifier.?(browser);
    if (!isDead(cef_id)) return;
    setDead(cef_id, false);
    for (&focus_off_pending) |*p| if (p.* == cef_id) {
        p.* = 0;
        focusOff(cef_id);
    };
}

/// 브라우저가 닫힌다(`on_before_close`). 그 탭이면 Chromium 이 trace 를 함께 끝낸다(완료 사건 없음 — t4 K2) — 곧 자리를 푼다.
pub fn browserClosed(cef_id: c_int) void {
    setDead(cef_id, false);
    for (&focus_off_pending) |*p| if (p.* == cef_id) {
        p.* = 0;
    };
    for (&pending) |*p| if (p.cef_id == cef_id) {
        p.* = .{};
    };
    dropReg(cef_id);
    const s = &(session orelse return);
    if (s.cef_id != cef_id) {
        // 가족의 팝업이 닫혔다 — 그 등록만 뗀다.
        var i: usize = 0;
        while (i < s.family_len) {
            if (s.family[i].cef_id == cef_id) {
                s.family[i] = s.family[s.family_len - 1];
                s.family_len -= 1;
            } else i += 1;
        }
        return;
    }
    if (s.phase != .draining) sendState(s, .failed, .tab_closed);
    if (s.reserved > 0) writer().releaseBody(s.reserved);
    s.reserved = 0;
    s.stream_len = 0;
    s.focus_held = false; // 닫힌 탭에는 끄지 않는다
    finish(s);
}
