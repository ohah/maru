//! 에이전트의 성능 trace 를 maru 가 쥐는 자리(W9e② — docs/plans/web-osr-backend.md 「W9e② 결정·실측」) — L2 순수.
//!
//! Chromium 의 trace 는 **프로세스 단위**로 모인다(실측 o1–o3·a2): 그 탭 주 프레임의 렌더러 프로세스 전체(같은 프로세스에 들어온 **사용자 탭의 같은
//! 사이트 iframe**·그 탭이 연 팝업), 브라우저 프로세스(다른 탭의 이동·입력 박자), GPU 프로세스가 섞인다. 범주는 고정해 큰 것을 뺐지만(`loading`·
//! 원문·`latencyInfo` — sidecar `trace_plan.zig`) 범주로는 같은 프로세스의 남의 프레임을 막지 못한다. 그래서 maru 가 받은 gzip 을 **두 번 읽어**
//! 거른다(PLAN v2 §4.2):
//!   - **F1 브라우저·GPU**: 허용 목록만 — 메타데이터(프로세스·스레드 이름 — `process_labels` 는 탭 제목이라 뺀다), `TracingStartedInBrowser`·
//!     `FrameCommittedInBrowser`(그 탭의 것만 나온다 — a2; 주소는 투영), `Screenshot`(그 탭 것만 — a2). 나머지는 버린다.
//!   - **F2 렌더러**: 그 탭 **주 프레임**이 쓴 pid 만(TSIB 의 주 프레임·주 프레임 FCIB — 다른 사이트 이동 뒤 새 pid). 워커 스레드
//!     (`TracingSessionIdForWorker`)와 프로세스 전체 수(`UpdateCounters`)는 버린다. 다른 렌더러 pid(그 탭의 다른 사이트 iframe 프로세스 —
//!     사용자 탭과 나눌 수 있다, t2)는 버린다. 그 pid 안에서도 **스레드는 허용 목록**이다(적대 검증 v20c N1 HIGH): 주 스레드(`CrRendererMain`
//!     — F3 가 프레임으로 가른다)·컴포지터(`Compositor` — F3′ 이 layer tree 로 가른다)만 남기고, V8 프로파일러 스레드(`v8:ProfEvntProc`)의
//!     `ProfileChunk` 는 **주 스레드 isolate 의 프로파일 번호**(같은 `id` 의 `Profile` 이 주 스레드에서 났다)일 때만 남긴다. 그 밖(전용 워커·
//!     스레드 풀의 백그라운드 컴파일·GC 도우미·래스터·IO 등)은 프레임 칸이 없어 누구 것인지 가를 수 없다 — 뺀다. 같은 프로세스에 든 사용자
//!     iframe 의 전용 워커 표본이 함수 이름·토큰 든 스크립트 주소째 남았다(워커 스레드만 빼고 그 isolate 의 `ProfileChunk` 는 남겼다). 그리고
//!     남길 pid 의 워커가 **가족 밖 프레임**의 것이면(`TracingSessionIdForWorker.data.frame`) F3 처럼 통째로 버린다.
//!   - **F3 폐기**: 남긴 이벤트 어디에든 그 탭 가족(sidecar 의 `trace_frames` — 시작 전 프레임 트리 + 기록 중 붙고 옮긴 프레임) **밖의 프레임 id**
//!     가 있으면 **통째로 버린다**(`mixed_content` — 이유를 늘 싣는다, 사용자 결정 6). 사용자 iframe·그 팝업·bfcache 되살림·postMessage 모두 이것으로
//!     잡혔고 그 탭 혼자·제 팝업·제 OOPIF 는 헛폐기 0 이었다(a2).
//!   - **F3′ layer tree**(W9e② 적대 검증 1 회차 A1-1): 컴포지터 스레드 이벤트(`BeginFrame`·`DrawFrame` 등)는 프레임 칸 없이 `layerTreeId` 로만
//!     위젯을 가리킨다 — 같은 프로세스의 사용자 iframe 이 컴포지터만으로 움직이면(CSS 애니메이션) 그 박자가 F3 를 지나 결과에 남았고
//!     `frames_presented` 가 그 iframe 의 프레임으로 부풀었다(실측 151 대 5). 첫째 읽기에서 `SetLayerTreeId{frame, layerTreeId}`(DevTools
//!     timeline 범주만 — 페이지의 user timing 위장은 믿지 않는다)로 **가족 프레임의 layer tree**(프로세스마다)를 모으고, 남길 이벤트가 그 밖의
//!     `layerTreeId` 를 실으면 F3 처럼 통째로 버린다. 가족 위젯이 주 스레드를 쉬어 `SetLayerTreeId` 를 내지 않는 일은 sidecar 가 기록 시작에 가족
//!     탭마다 주 스레드 프레임 하나를 불러 막는다(`trace_plan.bind_world_name`).
//!   - **가족 씨앗과 막힌 탭**(적대 검증 v20b V-A1·사용자 결정 12): 가족 집합은 sidecar 의 `trace_frames` 에 브라우저가 낸 `TracingStartedInBrowser` 의
//!     프레임(그 탭의 프레임 트리)을 더한다 — 둘 다 비면 `renderer_unresponsive`. 그 탭의 렌더러가 기록 내내 답하지 않아(`renderer_silent`) 그 프로세스에
//!     가족 layer tree 가 없으면 F3′ 은 가를 수 없다: 그 프로세스에 가족 밖의 프레임이 들 수 있었으면(`shared_process`) 주 스레드 밖의 이벤트·묶이지 않은
//!     layer tree 를 실은 이벤트만 빼고(`compositor_events_dropped`), 아니면 모두 가족 것으로 남긴다. F3 는 그대로다.
//!   - **F4 네트워크**: `Resource*` 이벤트의 주소는 사용자 정보를 지우고, 머리는 이름만 남긴다(값을 지운다 — 응답 머리 값이 실렸다: t6).
//! 요약(`Summary` ≤ 8 KiB)은 남긴 이벤트에서 센다(주 스레드 긴 작업·FCP/LCP 후보·이동·요청, 프레임은 가족 layer tree 의 `DrawFrame` 만). sidecar 가
//! gzip 상한 앞에서 잘랐으면(`Options.truncated` — A4-1) 덮은 시간은 남은 주 스레드 이벤트의 끝까지로 다시 잰다.
//!
//! 시험이 증명하는 것: 인자 표(동작·길이·모르는 키·까닭 이름), 거르기 fixture — 브라우저 쪽 허용 목록·`process_labels` 뺌, 주 프레임 pid 만·새 pid
//! 따라감, 워커 스레드·UpdateCounters 뺌, 렌더러 스레드 허용 목록(주·컴포지터·주 isolate 의 ProfileChunk 만 — 워커 isolate 의 표본·이름 모를
//! 스레드·뺀 스레드의 이름 메타는 뺀다, 페이지의 「Profile」 위장은 번호를 들이지 못한다), 가족 밖 프레임의 워커면 통째 폐기, 가족 밖 프레임 id 하나면 통째 폐기(어느 깊이의 칸이든·대소문자), 가족 안이면 헛폐기 없음, 가족에 묶이지
//! 않은 layer tree 의 이벤트면 통째 폐기(다른 프로세스의 같은 번호·user timing 위장은 묶지 않는다), 프레임 수는 가족 layer tree 만, TSIB 씨앗(브라우저
//! pid 만)·차례와 무관한 가름·씨앗이 없으면 `renderer_unresponsive`, 막힌 탭의 나눔 있음(가를 수 없는 것만 뺌·경고)·없음(모두 남김)·남의 프레임이면 버림, 잘린 trace 의
//! 덮은 시간, 머리 값·사용자
//! 정보 지움, 요약 셈(긴 작업 50 ms 문턱·TBT·바쁨 %, FCP·LCP, 요청 수·바이트·느린 것), 다시 압축한 gzip 이 풀리고 DevTools 꼴(`traceEvents`),
//! 망가진 gzip·JSON 은 실패(풀다 멈춤).

const std = @import("std");
const ws = @import("web_sidecar/root.zig");

const msg = ws.message;
const flate = std.compress.flate;

pub const Action = enum { start, stop, status, abort, read };

/// `read` 한 번에 내주는 gzip 바이트(base64 로 약 342 KiB — 컨트롤 frame 1 MiB 안).
pub const read_chunk_bytes: u32 = 256 * 1024;

pub const default_duration_ms: u32 = 5_000;

pub const Params = struct {
    action: Action,
    reload: bool = false,
    duration_ms: u32 = default_duration_ms,
    screenshots: bool = true,
    /// stop: gzip 바이트를 받는다(CLI·MCP 가 준 경로에 쓴다 — 사용자 결정 1).
    file: bool = false,
    /// read: 거른 gzip 의 오프셋.
    offset: u32 = 0,
};

pub const Why = enum { unknown_key, action_invalid, duration_invalid, reload_invalid, screenshots_invalid, file_invalid, offset_invalid };

pub fn whyMessage(why: Why) []const u8 {
    return switch (why) {
        .unknown_key => "unknown key — browser.trace takes id, action, reload, duration_ms, screenshots, file and offset",
        .action_invalid => "action is start, stop, status, abort or read (reload, duration_ms and screenshots go with start, file with stop, offset with read)",
        .duration_invalid => "duration_ms is a whole number from 1000 to 30000",
        .reload_invalid => "reload is true or false (with start)",
        .screenshots_invalid => "screenshots is true or false (with start)",
        .file_invalid => "file is true or false (with stop)",
        .offset_invalid => "offset is a whole number of bytes from 0 (with read)",
    };
}

const ParamError = error{InvalidParams};

fn fail(why: *?Why, w: Why) ParamError {
    why.* = w;
    return error.InvalidParams;
}

const top_keys = [_][]const u8{ "id", "action", "reload", "duration_ms", "screenshots", "file", "offset" };

pub fn parseParams(params: ?std.json.Value, why: *?Why) ParamError!Params {
    why.* = null;
    const obj = switch (params orelse return fail(why, .action_invalid)) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    var it = obj.iterator();
    while (it.next()) |kv| {
        var known = false;
        for (top_keys) |k| if (std.mem.eql(u8, kv.key_ptr.*, k)) {
            known = true;
        };
        if (!known) return fail(why, .unknown_key);
    }
    const action_text = switch (obj.get("action") orelse return fail(why, .action_invalid)) {
        .string => |s| s,
        else => return fail(why, .action_invalid),
    };
    const action = std.meta.stringToEnum(Action, action_text) orelse return fail(why, .action_invalid);
    var p: Params = .{ .action = action };
    if (action != .start) for ([_][]const u8{ "reload", "duration_ms", "screenshots" }) |k| if (obj.get(k) != null) return fail(why, .action_invalid);
    if (action != .stop and obj.get("file") != null) return fail(why, .action_invalid);
    if (action != .read and obj.get("offset") != null) return fail(why, .action_invalid);
    if (obj.get("offset")) |v| p.offset = switch (v) {
        .integer => |i| if (i < 0 or i > msg.max_trace_gz_bytes) return fail(why, .offset_invalid) else @intCast(i),
        else => return fail(why, .offset_invalid),
    };
    if (obj.get("reload")) |v| p.reload = switch (v) {
        .bool => |b| b,
        else => return fail(why, .reload_invalid),
    };
    if (obj.get("screenshots")) |v| p.screenshots = switch (v) {
        .bool => |b| b,
        else => return fail(why, .screenshots_invalid),
    };
    if (obj.get("file")) |v| p.file = switch (v) {
        .bool => |b| b,
        else => return fail(why, .file_invalid),
    };
    if (obj.get("duration_ms")) |v| {
        const n: f64 = switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return fail(why, .duration_invalid),
        };
        if (n != @floor(n) or n < msg.min_trace_duration_ms or n > msg.max_trace_duration_ms) return fail(why, .duration_invalid);
        p.duration_ms = @intFromFloat(n);
    }
    return p;
}

/// op.arg — 정규형(앱이 같은 `parseParams` 로 다시 푼다).
pub fn serializeArg(gpa: std.mem.Allocator, p: Params) std.mem.Allocator.Error![]u8 {
    return switch (p.action) {
        .start => std.fmt.allocPrint(gpa, "{{\"action\":\"start\",\"reload\":{},\"duration_ms\":{d},\"screenshots\":{}}}", .{ p.reload, p.duration_ms, p.screenshots }),
        .stop => std.fmt.allocPrint(gpa, "{{\"action\":\"stop\",\"file\":{}}}", .{p.file}),
        .status => gpa.dupe(u8, "{\"action\":\"status\"}"),
        .abort => gpa.dupe(u8, "{\"action\":\"abort\"}"),
        .read => std.fmt.allocPrint(gpa, "{{\"action\":\"read\",\"offset\":{d}}}", .{p.offset}),
    };
}

// ── 프레임 집합 ─────────────────────────────────────────────────────────────────────────────────────────

/// 그 탭 가족의 프레임 id(대문자로 쥔다 — Chromium 은 대문자 16 진을 낸다, 사건은 소문자일 수 있다).
pub const FrameSet = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) FrameSet {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *FrameSet) void {
        self.set.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn count(self: *const FrameSet) usize {
        return self.set.count();
    }

    pub fn add(self: *FrameSet, id: []const u8) !void {
        if (!ws.trace_fields.frameIdOk(id)) return;
        const up = try self.arena.allocator().alloc(u8, id.len);
        for (id, up) |c, *o| o.* = std.ascii.toUpper(c);
        try self.set.put(self.arena.child_allocator, up, {});
    }

    pub fn contains(self: *const FrameSet, id: []const u8) bool {
        var up: [msg.max_trace_frame_id_bytes]u8 = undefined;
        if (id.len > up.len) return false;
        for (id, up[0..id.len]) |c, *o| o.* = std.ascii.toUpper(c);
        return self.set.contains(up[0..id.len]);
    }
};

/// 프레임 id 로 보이는 글(16 진 16..64 자 — Chromium 은 32 자) — 「parent」 같은 이름의 다른 글을 프레임으로 잘못 보지 않게.
fn looksLikeFrameId(s: []const u8) bool {
    if (s.len < 16 or s.len > msg.max_trace_frame_id_bytes) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const frame_keys = [_][]const u8{ "frame", "frameId", "frameID", "parent", "parentFrameId", "frame_id" };

/// 값 안의(어느 깊이든) 프레임 칸이 집합 밖이면 그 id 를 돌려준다.
fn foreignFrame(v: std.json.Value, set: *const FrameSet, depth: usize) ?[]const u8 {
    // 너무 깊으면 다 보지 못한다 — 남김이 아니라 폐기로(닫힌 쪽으로 실패 — 구현 적대 리뷰 M4).
    if (depth > 32) return "nesting-too-deep";
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                const val = kv.value_ptr.*;
                for (frame_keys) |k| if (std.mem.eql(u8, kv.key_ptr.*, k)) {
                    if (val == .string and looksLikeFrameId(val.string) and !set.contains(val.string)) return val.string;
                };
                if (foreignFrame(val, set, depth + 1)) |f| return f;
            }
        },
        .array => |a| for (a.items) |x| if (foreignFrame(x, set, depth + 1)) |f| return f,
        else => {},
    }
    return null;
}

// ── 거르기 ─────────────────────────────────────────────────────────────────────────────────────────────

/// `renderer_unresponsive` — 그 탭의 프레임을 알 수 없었다(V-A1: 주 스레드가 기록 내내 막혀 sidecar 의 프레임 트리 물음에 답하지 않았고, trace 에도
/// 브라우저가 낸 그 탭의 프레임이 없다).
pub const Outcome = enum { kept, mixed_content, malformed, renderer_unresponsive };

pub const Slow = struct { url: []const u8, ms: u32 };

pub const Summary = struct {
    covered_ms: u32 = 0,
    events_kept: u64 = 0,
    events_dropped: u64 = 0,
    json_bytes: u64 = 0,
    gz_bytes: u64 = 0,
    navigations: u32 = 0,
    first_url: []const u8 = "",
    fcp_ms: ?f64 = null,
    lcp_ms: ?f64 = null,
    long_task_count: u32 = 0,
    long_task_total_ms: f64 = 0,
    total_blocking_ms: f64 = 0,
    main_busy_ms: f64 = 0,
    frames: u32 = 0,
    screenshots: u32 = 0,
    requests: u32 = 0,
    request_bytes: u64 = 0,
    slowest: [5]Slow = @splat(.{ .url = "", .ms = 0 }),
    slowest_len: usize = 0,
    /// sidecar 가 gzip 상한 앞에서 잘랐다(A4-1).
    truncated: bool = false,
    /// 결정 12: 누구 것인지 가를 수 없어 뺀 이벤트 수(막힌 탭 — 나눠 쓰일 수 있는 프로세스의 주 스레드 밖·묶이지 않은 layer tree).
    compositor_dropped: u64 = 0,
};

pub const Result = struct {
    outcome: Outcome,
    /// 폐기면 처음 본 남의 프레임 id(로그용 — 결과에는 싣지 않는다).
    foreign: []const u8 = "",
    /// 거른 trace 의 gzip(남김일 때만).
    gz: []u8 = &.{},
    summary: Summary = .{},
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    /// 그 탭 주 프레임 렌더러 pid 를 모를 때(TSIB 가 없다) 쓸 것 — 시험용.
    covered_ms: u32 = 0,
    /// sidecar 의 프레임 집합이 비었다 — 그 탭의 렌더러가 기록 내내 `Page.getFrameTree` 에 답하지 않았다(주 스레드가 막혔다, V-A1). 그 프로세스에
    /// 가족 layer tree 가 하나도 묶이지 않았으면(`SetLayerTreeId` 는 주 스레드가 낸다) 그 프로세스의 컴포지터 이벤트는 누구 것인지 가를 수 없다 —
    /// 사용자 결정 12(2026-10-30): 통째로 버리지 않고 **가를 수 없는 것만 뺀다**(`shared_process`).
    renderer_silent: bool = false,
    /// sidecar 가 기록하는 동안 그 탭의 렌더러 프로세스에 가족 밖의 프레임이 들 수 있었다고 했다(`trace_state.shared_process`). 가족 layer tree 를
    /// 모르는 그 프로세스에서 — 참이면 주 스레드 밖(컴포지터·래스터·V8 프로파일러 등 — 프레임 칸이 없다)의 이벤트와 묶이지 않은 layer tree 를 실은
    /// 이벤트를 빼고(`Summary.compositor_dropped`), 거짓이면 그 프로세스는 가족만 쓰니 모두 가족 것으로 남긴다. 주 스레드 이벤트는 어느 쪽이든 F3
    /// (남의 프레임이면 통째 버림)를 지난다.
    shared_process: bool = false,
    /// sidecar 가 gzip 상한 앞에서 잘랐다(A4-1) — 덮은 시간을 남은 주 스레드 이벤트로 다시 잰다.
    truncated: bool = false,
    /// 남긴 이벤트를 gzip 으로 쓴다(파일을 청했을 때만 — 아니면 요약만).
    write_gz: bool = true,
};

/// 두 번 읽기의 첫째에서 모은 것.
const Scan = struct {
    browser_pid: ?i64 = null,
    gpu_pid: ?i64 = null,
    renderer_pids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    worker_threads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    main_threads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 렌더러의 컴포지터 스레드(`thread_name` 「Compositor」 — 프레임 칸 없이 `layerTreeId` 로 위젯을 가리킨다, F3′ 이 가른다).
    compositor_threads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// V8 CPU 프로파일러의 표본 처리 스레드(`v8:ProfEvntProc` — isolate 마다 하나, `ProfileChunk` 를 낸다). 메타데이터만 남기고 이벤트는
    /// `main_profiles` 로 가른다.
    profiler_threads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 적대 검증 v20c N1: 주 스레드 isolate 의 V8 프로파일 번호(`key2(pid, Profile 의 id)`). `ProfileChunk` 는 프로파일러 스레드에서 나와 프레임
    /// 칸이 없고 어느 isolate 의 표본인지는 같은 `id` 의 `Profile` 이벤트가 난 스레드로만 안다 — 그 스레드가 그 pid 의 주 스레드인 것만 남긴다.
    main_profiles: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 가족 프레임의 layer tree(프로세스마다 — `key2(pid, layerTreeId)`; 번호는 프로세스 안에서만 겹치지 않는다).
    family_trees: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 가족 layer tree 가 하나라도 묶인 프로세스.
    family_tree_pids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    start_ts: ?f64 = null,
    /// 메타데이터(`process_name` 「Browser」)가 정한 브라우저 pid — `TracingStartedInBrowser` 의 프레임을 가족 씨앗으로 받기 전에 맞춰 본다.
    meta_browser_pid: ?i64 = null,
    /// 첫째 읽기 끝에 가족 집합으로 가르는 것(V-A1 — 집합이 읽는 동안 `TracingStartedInBrowser` 로 자라므로, 그 앞에 온 이벤트도 끝에 가른다):
    /// 주 프레임 커밋(프레임 → 렌더러 pid), `SetLayerTreeId`(프레임 → 그 프로세스의 layer tree).
    main_commits: std.ArrayList(FrameRef) = .empty,
    tree_binds: std.ArrayList(FrameRef) = .empty,
    /// `Profile` 이벤트(pid, 프로파일 번호, 그 isolate 의 스레드) — 메타데이터와 차례가 어긋나도 되게 끝에 가른다.
    profiles: std.ArrayList(ProfileRef) = .empty,
    /// 적대 검증 v20c N1: 워커의 `TracingSessionIdForWorker` 가 실은 그 워커를 만든 프레임(pid 와 함께) — 남길 렌더러 pid 의 워커가 가족 밖
    /// 프레임의 것이면 F3 처럼 통째로 버린다(워커 스레드는 이 프레임 칸을 싣고 나오지만 F2 가 먼저 빼서 F3 가 보지 못했다).
    worker_frames: std.ArrayList(FrameRef) = .empty,
    refs: std.heap.ArenaAllocator,

    const ProfileRef = struct { pid: i64, id: i64, tid: i64 };

    const FrameRef = struct { frame: []const u8, pid: i64, value: i64 = 0 };

    fn init(gpa: std.mem.Allocator) Scan {
        return .{ .refs = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Scan, gpa: std.mem.Allocator) void {
        self.renderer_pids.deinit(gpa);
        self.worker_threads.deinit(gpa);
        self.main_threads.deinit(gpa);
        self.compositor_threads.deinit(gpa);
        self.profiler_threads.deinit(gpa);
        self.main_profiles.deinit(gpa);
        self.profiles.deinit(gpa);
        self.worker_frames.deinit(gpa);
        self.family_trees.deinit(gpa);
        self.family_tree_pids.deinit(gpa);
        self.main_commits.deinit(gpa);
        self.tree_binds.deinit(gpa);
        self.refs.deinit();
    }

    fn note(self: *Scan, gpa: std.mem.Allocator, list: *std.ArrayList(FrameRef), frame: []const u8, pid: i64, value: i64) !void {
        if (!ws.trace_fields.frameIdOk(frame)) return;
        try list.append(gpa, .{ .frame = try self.refs.allocator().dupe(u8, frame), .pid = pid, .value = value });
    }

    /// 첫째 읽기 끝 — 다 모인 가족 집합으로 주 프레임 렌더러 pid·가족 layer tree·주 스레드 isolate 의 프로파일을 정한다. 남길 렌더러 pid 의
    /// 워커가 가족 밖 프레임의 것이면 그 프레임 id 를 돌려준다(통째 버림 — N1).
    fn resolve(self: *Scan, gpa: std.mem.Allocator, set: *const FrameSet) !?[]const u8 {
        for (self.main_commits.items) |m| if (set.contains(m.frame)) try self.renderer_pids.put(gpa, m.pid, {});
        for (self.tree_binds.items) |b| if (set.contains(b.frame)) {
            try self.family_trees.put(gpa, key2(b.pid, b.value), {});
            try self.family_tree_pids.put(gpa, b.pid, {});
        };
        for (self.profiles.items) |p| if (self.main_threads.contains(key2(p.pid, p.tid))) try self.main_profiles.put(gpa, key2(p.pid, p.id), {});
        for (self.worker_frames.items) |w| if (self.renderer_pids.contains(w.pid) and !set.contains(w.frame)) return w.frame;
        return null;
    }
};

/// 값 안(어느 깊이든)의 `layerTreeId` 가 그 프로세스의 가족 layer tree 밖이면 참(A1-1). 너무 깊으면 다 보지 못한다 — 남김이 아니라 폐기로.
fn foreignLayerTree(v: std.json.Value, pid: i64, scan: *const Scan, depth: usize) bool {
    if (depth > 32) return true;
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "layerTreeId")) {
                    const id: ?i64 = switch (kv.value_ptr.*) {
                        .integer => |i| i,
                        .float => |f| if (std.math.isFinite(f) and @abs(f) < 9.0e15) @intFromFloat(f) else null,
                        else => null,
                    };
                    if (id) |x| if (!scan.family_trees.contains(key2(pid, x))) return true;
                }
                if (foreignLayerTree(kv.value_ptr.*, pid, scan, depth + 1)) return true;
            }
        },
        .array => |a| for (a.items) |x| if (foreignLayerTree(x, pid, scan, depth + 1)) return true,
        else => {},
    }
    return false;
}

fn key2(pid: i64, tid: i64) u64 {
    return (@as(u64, @bitCast(pid)) << 32) ^ @as(u64, @bitCast(tid));
}

fn getStr(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| i,
        // 범위 밖의 수는 정수로 바꾸지 않는다(안전 검사 panic — sidecar 바이트는 공격 입력, 구현 적대 리뷰 M3).
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn getNum(o: std.json.ObjectMap, k: []const u8) ?f64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn getObj(o: std.json.ObjectMap, k: []const u8) ?std.json.ObjectMap {
    const v = o.get(k) orelse return null;
    return if (v == .object) v.object else null;
}

/// `Profile`·`ProfileChunk` 의 프로파일 번호 — `"id":"0x3"`(Chromium 은 16 진 글을 낸다)·10 진 글·정수, 또는 `"id2":{"local":…}`. 모르면 null
/// (그 표본은 남기지 않는다 — 닫힌 쪽).
fn profileId(o: std.json.ObjectMap) ?i64 {
    const v = o.get("id") orelse blk: {
        const id2 = getObj(o, "id2") orelse return null;
        break :blk id2.get("local") orelse id2.get("global") orelse return null;
    };
    return switch (v) {
        .integer => |i| i,
        .string => |t| if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
            std.fmt.parseInt(i64, t[2..], 16) catch null
        else
            std.fmt.parseInt(i64, t, 10) catch null,
        else => null,
    };
}

/// 이벤트 배열의 원소를 하나씩 꺼낸다(`{"traceEvents":[…]}` 또는 `[…]`) — 글·괄호를 따라 원소의 바이트를 모은다.
const Splitter = struct {
    started: bool = false,
    done: bool = false,
    depth: usize = 0,
    in_string: bool = false,
    escape: bool = false,
    buf: std.ArrayList(u8) = .empty,

    const max_event_bytes: usize = 16 * 1024 * 1024;

    /// 바이트를 먹이고 원소가 끝날 때마다 `sink.event(bytes)` 를 부른다.
    fn feed(self: *Splitter, gpa: std.mem.Allocator, bytes: []const u8, sink: anytype) !void {
        for (bytes) |c| {
            if (self.done) return;
            if (!self.started) {
                if (c == '[') self.started = true;
                continue;
            }
            if (self.depth == 0) {
                switch (c) {
                    '{' => {
                        self.depth = 1;
                        self.buf.clearRetainingCapacity();
                        try self.buf.append(gpa, c);
                    },
                    ']' => self.done = true,
                    else => {},
                }
                continue;
            }
            if (self.buf.items.len >= max_event_bytes) return error.EventTooLarge;
            try self.buf.append(gpa, c);
            if (self.in_string) {
                if (self.escape) self.escape = false else if (c == '\\') self.escape = true else if (c == '"') self.in_string = false;
                continue;
            }
            switch (c) {
                '"' => self.in_string = true,
                '{', '[' => self.depth += 1,
                '}', ']' => {
                    self.depth -= 1;
                    if (self.depth == 0) try sink.event(self.buf.items);
                },
                else => {},
            }
        }
    }
};

/// gzip 을 풀며 원소마다 `sink.event` 를 부른다.
fn eachEvent(gpa: std.mem.Allocator, gz: []const u8, sink: anytype) !void {
    var in: std.Io.Reader = .fixed(gz);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .gzip, &window);
    var sp: Splitter = .{};
    defer sp.buf.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = d.reader.readSliceShort(&chunk) catch return error.Malformed;
        if (n == 0) break;
        try sp.feed(gpa, chunk[0..n], sink);
        if (n < chunk.len) {
            // 짧게 읽혔다 — 끝이거나 더 온다(readSliceShort 는 끝에서만 짧다).
            break;
        }
    }
    if (!sp.started) return error.Malformed;
}

const ScanSink = struct {
    gpa: std.mem.Allocator,
    scan: *Scan,
    /// 가족 집합 — `TracingStartedInBrowser` 의 프레임으로 자란다(V-A1).
    set: *FrameSet,
    arena: std.heap.ArenaAllocator,

    fn event(self: *ScanSink, bytes: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), bytes, .{}) catch return error.Malformed;
        if (v != .object) return;
        const o = v.object;
        const name = getStr(o, "name") orelse return;
        const pid = getInt(o, "pid") orelse return;
        const ph = getStr(o, "ph") orelse "";
        if (getNum(o, "ts")) |ts| if (ph.len > 0 and ph[0] != 'M') {
            if (self.scan.start_ts == null or ts < self.scan.start_ts.?) self.scan.start_ts = ts;
        };
        const args = getObj(o, "args");
        if (std.mem.eql(u8, ph, "M")) {
            if (std.mem.eql(u8, name, "process_name")) if (args) |a| if (getStr(a, "name")) |pn| {
                if (std.mem.eql(u8, pn, "GPU Process")) self.scan.gpu_pid = pid;
                if (std.mem.eql(u8, pn, "Browser")) {
                    self.scan.browser_pid = pid;
                    self.scan.meta_browser_pid = pid;
                }
            };
            if (std.mem.eql(u8, name, "thread_name")) if (args) |a| if (getStr(a, "name")) |tn| {
                const key = key2(pid, getInt(o, "tid") orelse 0);
                if (std.mem.eql(u8, tn, "CrRendererMain")) try self.scan.main_threads.put(self.gpa, key, {});
                if (std.mem.eql(u8, tn, "Compositor")) try self.scan.compositor_threads.put(self.gpa, key, {});
                if (std.mem.eql(u8, tn, "v8:ProfEvntProc")) try self.scan.profiler_threads.put(self.gpa, key, {});
            };
            return;
        }
        // N1: V8 프로파일의 시작 — 그 isolate 의 스레드에서 난다(주 스레드면 그 번호의 `ProfileChunk` 만 남긴다). 범주가 있으면 CPU 프로파일러의
        // 것만 믿는다 — 페이지의 `performance.measure("Profile")` 는 주 스레드에서 작은 번호의 비동기 이벤트가 되어 워커 프로파일의 번호를 「주
        // 스레드 것」 으로 만들 수 있다.
        const profiler_cat = if (getStr(o, "cat")) |cat| std.mem.indexOf(u8, cat, "v8.cpu_profiler") != null else true;
        if (std.mem.eql(u8, name, "Profile") and profiler_cat and std.mem.eql(u8, ph, "P")) {
            if (profileId(o)) |id| try self.scan.profiles.append(self.gpa, .{ .pid = pid, .id = id, .tid = getInt(o, "tid") orelse 0 });
            return;
        }
        // 페이지가 같은 이름의 user timing(`performance.mark("TracingStartedInBrowser")` — 범주 blink.user_timing)을 내면 렌더러를 브라우저로
        // 보게 된다 — 범주가 있으면 DevTools timeline 의 것만 믿는다(구현 적대 리뷰 LOW).
        const timeline = if (getStr(o, "cat")) |cat| std.mem.indexOf(u8, cat, "devtools.timeline") != null else true;
        // 브라우저가 낸 것인가 — 메타데이터가 브라우저 pid 를 정했으면 그 pid 여야 한다(렌더러가 같은 범주·이름을 흉내 내도 가족 씨앗이 되지 않게).
        const from_browser = timeline and (self.scan.meta_browser_pid == null or self.scan.meta_browser_pid.? == pid);
        if (std.mem.eql(u8, name, "TracingStartedInBrowser") and from_browser) {
            self.scan.browser_pid = pid;
            const data = getObj(args orelse return, "data") orelse return;
            const frames = data.get("frames") orelse return;
            if (frames != .array) return;
            for (frames.array.items) |f| {
                if (f != .object) continue;
                const fid = getStr(f.object, "frame") orelse continue;
                // V-A1: 그 탭의 프레임 트리(브라우저가 안다 — trace 를 그 탭의 DevTools 세션으로 시작했다)를 가족 씨앗에 더한다. sidecar 의 씨앗
                // (`Page.getFrameTree`)은 렌더러가 답하는데, 주 스레드가 기록 내내 막힌 탭은 답하지 않아 집합이 비고 그 탭 자신의 주 프레임을
                // 남의 것으로 보아 `mixed_content` 로 버렸다(적대 검증 v20b A1-1 b1-jank).
                try self.set.add(fid);
                if (f.object.get("parent") != null) continue; // 하위 프레임의 프로세스는 남기지 않는다(F2)
                if (getInt(f.object, "processId")) |p| try self.scan.note(self.gpa, &self.scan.main_commits, fid, p, 0);
            }
            return;
        }
        if (std.mem.eql(u8, name, "FrameCommittedInBrowser") and from_browser) {
            const data = getObj(args orelse return, "data") orelse return;
            const fid = getStr(data, "frame") orelse return;
            if (data.get("parent") != null) return;
            if (getInt(data, "processId")) |p| try self.scan.note(self.gpa, &self.scan.main_commits, fid, p, 0);
            return;
        }
        if (std.mem.eql(u8, name, "TracingSessionIdForWorker")) {
            const data = getObj(args orelse return, "data") orelse return;
            // 워커를 만든 프레임(N1) — 범주와 무관하게 받는다(가족 밖이면 버리는 닫힌 쪽이라 위장이 남길 것을 늘리지 못한다).
            if (getStr(data, "frame")) |f| try self.scan.note(self.gpa, &self.scan.worker_frames, f, pid, 0);
            // 스레드 빼기는 DevTools timeline 의 것만 — 페이지가 같은 이름의 mark 로 주 스레드를 「워커」 로 만들어 지우지 못하게.
            if (timeline) if (getInt(data, "workerThreadId")) |tid| try self.scan.worker_threads.put(self.gpa, key2(pid, tid), {});
            return;
        }
        // A1-1: 가족 프레임의 위젯 — 그 프로세스의 layer tree 번호를 가족으로(DevTools timeline 의 것만 — 페이지가 같은 이름의 mark 로 남의 layer
        // tree 를 가족으로 들이지 못하게, 범주가 없는 시험 fixture 는 믿는다).
        if (std.mem.eql(u8, name, "SetLayerTreeId") and timeline) {
            const data = getObj(args orelse return, "data") orelse return;
            const fid = getStr(data, "frame") orelse return;
            if (getInt(data, "layerTreeId")) |lt| try self.scan.note(self.gpa, &self.scan.tree_binds, fid, pid, lt);
        }
    }
};

/// 남긴 이벤트를 쓰고 요약을 센다.
const KeepSink = struct {
    gpa: std.mem.Allocator,
    scan: *const Scan,
    set: *const FrameSet,
    arena: std.heap.ArenaAllocator,
    out: ?*std.Io.Writer,
    first: bool = true,
    summary: *Summary,
    result_arena: std.mem.Allocator,
    foreign: ?[]const u8 = null,
    renderer_silent: bool = false,
    shared_process: bool = false,
    json_bytes: u64 = 0,
    /// 요청 번호 → (시작 ts, 주소) — 느린 요청.
    reqs: std.StringHashMapUnmanaged(struct { ts: f64, url: []const u8 }) = .empty,
    last_nav_ts: ?f64 = null,
    /// 남긴 주 스레드 이벤트의 가장 늦은 끝(ts + dur, µs).
    main_end_ts: ?f64 = null,

    fn keepMeta(name: []const u8) bool {
        for ([_][]const u8{ "process_name", "thread_name", "process_sort_index", "thread_sort_index" }) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }

    fn event(self: *KeepSink, bytes: []const u8) !void {
        if (self.foreign != null) return; // 이미 버렸다 — 더 볼 것이 없다
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.Malformed;
        if (v != .object) return self.drop();
        const o = &v.object;
        const name = getStr(o.*, "name") orelse return self.drop();
        const pid = getInt(o.*, "pid") orelse return self.drop();
        const tid = getInt(o.*, "tid") orelse 0;
        const ph = getStr(o.*, "ph") orelse "";
        const is_meta = std.mem.eql(u8, ph, "M");
        const is_browser = self.scan.browser_pid != null and pid == self.scan.browser_pid.?;
        const is_gpu = self.scan.gpu_pid != null and pid == self.scan.gpu_pid.?;
        const is_renderer = self.scan.renderer_pids.contains(pid);
        if (is_meta) {
            if (!(is_browser or is_gpu or is_renderer) or !keepMeta(name)) return self.drop();
            // N1: 렌더러의 스레드 이름은 남기는 스레드의 것만(「DedicatedWorker thread」 처럼 뺀 스레드가 있었다는 것도 남기지 않는다).
            if (is_renderer and !(is_browser or is_gpu) and isThreadMeta(name) and !self.keptThread(pid, tid)) return self.drop();
            return self.write(bytes);
        }
        var modified = false;
        if (is_browser or is_gpu) {
            const allowed = std.mem.eql(u8, name, "TracingStartedInBrowser") or std.mem.eql(u8, name, "FrameCommittedInBrowser") or std.mem.eql(u8, name, "Screenshot");
            if (!allowed) return self.drop();
            if (std.mem.eql(u8, name, "Screenshot")) self.summary.screenshots += 1;
            if (std.mem.eql(u8, name, "FrameCommittedInBrowser")) self.noteNavigation(o.*);
        } else if (is_renderer) {
            if (self.scan.worker_threads.contains(key2(pid, tid))) return self.drop();
            if (std.mem.eql(u8, name, "UpdateCounters")) return self.drop();
            // N1(적대 검증 v20c — 허용 목록): 렌더러 pid 에서 남기는 스레드는 주 스레드(F3 가 프레임으로 가른다)와 컴포지터(F3′ 이 layer tree 로
            // 가른다)뿐이다. 그 밖(워커·스레드 풀의 백그라운드 컴파일·GC 도우미·래스터·IO·오디오 등)은 프레임 칸이 없어 같은 프로세스에 든
            // 사용자 iframe 의 것인지 가를 수 없다 — 기본으로 뺀다. 예외 하나: V8 프로파일러 스레드의 `ProfileChunk` 는 주 스레드 isolate 의
            // 프로파일 번호일 때만(같은 프로세스 사용자 iframe 의 전용 워커 표본이 함수 이름·토큰 든 스크립트 주소째 남았다).
            const main = self.scan.main_threads.contains(key2(pid, tid));
            const compositor = self.scan.compositor_threads.contains(key2(pid, tid));
            const main_chunk = std.mem.eql(u8, name, "ProfileChunk") and if (profileId(o.*)) |id| self.scan.main_profiles.contains(key2(pid, id)) else false;
            if (!main and !compositor and !main_chunk) return self.drop();
            if (std.mem.eql(u8, name, "Screenshot")) self.summary.screenshots += 1;
        } else return self.drop();
        // 결정 12: 가족 layer tree 를 모르는(막힌) 프로세스이고 남의 프레임이 들 수 있었다 — 주 스레드 밖의 이벤트는 누구 것인지 가를 수 없다(뺀다).
        const blind = self.blindPid(pid);
        if (blind and self.shared_process and !self.scan.main_threads.contains(key2(pid, tid))) return self.dropUnattributable();
        // F3 — 남길 이벤트에 가족 밖의 프레임이 하나라도 있으면 통째로.
        if (foreignFrame(v, self.set, 0)) |f| {
            self.foreign = try self.result_arena.dupe(u8, f);
            return;
        }
        // F3′ — 가족에 묶이지 않은 layer tree(컴포지터만 쓰는 남의 위젯 — A1-1)도 통째로. 브라우저·GPU 의 것은 허용 목록이 이미 거른다.
        if (is_renderer) if (getObj(o.*, "args")) |args| if (foreignLayerTree(.{ .object = args }, pid, self.scan, 0)) {
            // V-A1·결정 12: 그 탭의 렌더러가 기록 내내 답하지 않았고 이 프로세스에 가족 layer tree 가 하나도 없다 — 주 스레드가 막혀 아무 위젯도
            // `SetLayerTreeId` 를 내지 못했다(한 프로세스는 주 스레드를 함께 쓴다). 남의 것이 들 수 있었으면 이 이벤트만 빼고, 가족만 쓰는
            // 프로세스면 가족의 것이다(남긴다).
            if (blind) {
                if (self.shared_process) return self.dropUnattributable();
            } else {
                self.foreign = "layer-tree";
                return;
            }
        };
        // F4 — 네트워크 이벤트의 머리 값·사용자 정보.
        if (std.mem.startsWith(u8, name, "Resource")) modified = try self.projectResource(o.*);
        if (is_renderer) self.count(o.*, name, pid, tid);
        if (modified) {
            var aw: std.Io.Writer.Allocating = .init(a);
            std.json.Stringify.value(v, .{}, &aw.writer) catch return error.OutOfMemory;
            return self.write(aw.written());
        }
        return self.write(bytes);
    }

    fn drop(self: *KeepSink) void {
        self.summary.events_dropped += 1;
    }

    fn isThreadMeta(name: []const u8) bool {
        return std.mem.eql(u8, name, "thread_name") or std.mem.eql(u8, name, "thread_sort_index");
    }

    /// 렌더러에서 이벤트를 남길 수 있는 스레드(주 스레드·컴포지터·주 isolate 의 표본을 내는 프로파일러 스레드 — N1).
    fn keptThread(self: *const KeepSink, pid: i64, tid: i64) bool {
        const k = key2(pid, tid);
        return self.scan.main_threads.contains(k) or self.scan.compositor_threads.contains(k) or self.scan.profiler_threads.contains(k);
    }

    /// 결정 12: 그 탭의 렌더러가 기록 내내 답하지 않았고(`renderer_silent`) 이 프로세스에 가족 layer tree 가 하나도 없다.
    fn blindPid(self: *const KeepSink, pid: i64) bool {
        return self.renderer_silent and self.scan.renderer_pids.contains(pid) and !self.scan.family_tree_pids.contains(pid);
    }

    fn dropUnattributable(self: *KeepSink) void {
        self.summary.compositor_dropped += 1;
        self.drop();
    }

    fn write(self: *KeepSink, bytes: []const u8) !void {
        self.summary.events_kept += 1;
        self.json_bytes += bytes.len + 1;
        const w = self.out orelse return;
        if (!self.first) try w.writeAll(",");
        self.first = false;
        try w.writeAll(bytes);
    }

    fn rel(self: *const KeepSink, ts: f64) f64 {
        return (ts - (self.scan.start_ts orelse ts)) / 1000.0;
    }

    fn noteNavigation(self: *KeepSink, o: std.json.ObjectMap) void {
        const args = getObj(o, "args") orelse return;
        const data = getObj(args, "data") orelse return;
        if (data.get("parent") != null) return;
        self.summary.navigations += 1;
        if (self.summary.first_url.len == 0) if (getStr(data, "url")) |u| {
            self.summary.first_url = self.result_arena.dupe(u8, stripUserinfo(self.result_arena, u) catch "") catch "";
        };
    }

    fn count(self: *KeepSink, o: std.json.ObjectMap, name: []const u8, pid: i64, tid: i64) void {
        const ts = getNum(o, "ts") orelse return;
        const main = self.scan.main_threads.contains(key2(pid, tid));
        // 잘린 trace 의 덮은 시간(A4-1) — 남은 주 스레드 이벤트의 끝.
        if (main and std.math.isFinite(ts)) {
            const end = ts + (getNum(o, "dur") orelse 0);
            if (std.math.isFinite(end) and (self.main_end_ts == null or end > self.main_end_ts.?)) self.main_end_ts = end;
        }
        if (main and std.mem.eql(u8, name, "RunTask")) {
            if (getNum(o, "dur")) |dur_us| {
                const ms = dur_us / 1000.0;
                self.summary.main_busy_ms += ms;
                if (ms > 50) {
                    self.summary.long_task_count += 1;
                    self.summary.long_task_total_ms += ms;
                    self.summary.total_blocking_ms += ms - 50;
                }
            }
        } else if (std.mem.eql(u8, name, "navigationStart")) {
            self.last_nav_ts = ts;
        } else if (std.mem.eql(u8, name, "firstContentfulPaint")) {
            if (self.summary.fcp_ms == null) self.summary.fcp_ms = (ts - (self.last_nav_ts orelse self.scan.start_ts orelse ts)) / 1000.0;
        } else if (std.mem.eql(u8, name, "largestContentfulPaint::Candidate")) {
            self.summary.lcp_ms = (ts - (self.last_nav_ts orelse self.scan.start_ts orelse ts)) / 1000.0;
        } else if (std.mem.eql(u8, name, "DrawFrame")) {
            // 가족 layer tree 의 것만(A1-1 — 묶이지 않은 것은 위 F3′ 이 이미 버렸다; 번호가 없는 DrawFrame 은 세지 않는다).
            const lt = getInt(getObj(o, "args") orelse return, "layerTreeId") orelse return;
            // 결정 12: 가족만 쓰는 막힌 프로세스의 layer tree 는 가족의 것이다.
            if (self.scan.family_trees.contains(key2(pid, lt)) or (self.blindPid(pid) and !self.shared_process)) self.summary.frames += 1;
        } else if (std.mem.eql(u8, name, "ResourceSendRequest")) {
            const data = getObj(getObj(o, "args") orelse return, "data") orelse return;
            self.summary.requests += 1;
            const id = getStr(data, "requestId") orelse return;
            const url = getStr(data, "url") orelse "";
            const key = self.result_arena.dupe(u8, id) catch return;
            const u = stripUserinfo(self.result_arena, self.result_arena.dupe(u8, url) catch return) catch return;
            self.reqs.put(self.gpa, key, .{ .ts = ts, .url = u }) catch {};
        } else if (std.mem.eql(u8, name, "ResourceFinish")) {
            const data = getObj(getObj(o, "args") orelse return, "data") orelse return;
            if (getNum(data, "encodedDataLength")) |n| if (n > 0) {
                self.summary.request_bytes +|= std.math.lossyCast(u64, n);
            };
            const id = getStr(data, "requestId") orelse return;
            const r = self.reqs.get(id) orelse return;
            const ms: u32 = std.math.lossyCast(u32, @max(0, (ts - r.ts) / 1000.0));
            self.noteSlow(r.url, ms);
        }
    }

    fn noteSlow(self: *KeepSink, url: []const u8, ms: u32) void {
        const s = self.summary;
        var i: usize = 0;
        while (i < s.slowest_len and s.slowest[i].ms >= ms) i += 1;
        if (i >= s.slowest.len) return;
        var j = @min(s.slowest_len, s.slowest.len - 1);
        while (j > i) : (j -= 1) s.slowest[j] = s.slowest[j - 1];
        s.slowest[i] = .{ .url = url, .ms = ms };
        if (s.slowest_len < s.slowest.len) s.slowest_len += 1;
    }

    /// F4 — 머리 값을 지우고(이름만) 주소의 사용자 정보를 지운다. 바꿨으면 참.
    fn projectResource(self: *KeepSink, o: std.json.ObjectMap) !bool {
        const args = getObj(o, "args") orelse return false;
        var data_v = args.getPtr("data") orelse return false;
        if (data_v.* != .object) return false;
        var changed = false;
        const data = &data_v.object;
        if (data.getPtr("url")) |u| if (u.* == .string) {
            const stripped = try stripUserinfo(self.arena.allocator(), u.string);
            if (stripped.len != u.string.len) {
                u.* = .{ .string = stripped };
                changed = true;
            }
        };
        for ([_][]const u8{ "headers", "requestHeaders", "responseHeaders" }) |hk| if (data.getPtr(hk)) |h| {
            switch (h.*) {
                .object => |*ho| {
                    var it = ho.iterator();
                    while (it.next()) |kv| if (kv.value_ptr.* != .string or kv.value_ptr.string.len != 0) {
                        kv.value_ptr.* = .{ .string = "" };
                        changed = true;
                    };
                },
                .array => |*arr| for (arr.items) |*item| if (item.* == .object) {
                    if (item.object.getPtr("value")) |val| if (val.* != .string or val.string.len != 0) {
                        val.* = .{ .string = "" };
                        changed = true;
                    };
                },
                else => {},
            }
        };
        return changed;
    }
};

/// `scheme://user:pass@host/…` → `scheme://host/…`(권한 안의 마지막 `@` 까지 — 경로의 `@` 는 그대로). 사용자 정보가 없으면 그 글 그대로.
pub fn stripUserinfo(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const auth_start = scheme_end + 3;
    const rest = url[auth_start..];
    const auth_end = auth_start + (std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len);
    const at = std.mem.lastIndexOfScalar(u8, url[auth_start..auth_end], '@') orelse return url;
    return std.mem.concat(a, u8, &.{ url[0..auth_start], url[auth_start + at + 1 ..] });
}

/// 거른다 — 두 번 읽는다(첫째: 브라우저·GPU·주 프레임 렌더러 pid·워커 스레드·주 스레드, 둘째: 거르며 쓰고 센다). `set` 은 그 탭 가족의 프레임
/// 집합. 주 스레드 밖에서 돈다(30 s trace 를 풀면 100–160 MB — PHASE0 t8·a3_flood).
/// `set` 은 sidecar 가 보낸 가족 프레임 집합 — 거르는 동안 `TracingStartedInBrowser`(브라우저가 낸 그 탭의 프레임 트리)로
/// 자란다(V-A1). 둘을 합쳐도 비면 가족을 모른다 — `renderer_unresponsive`(남의 것이 섞였다는 틀린 이유를 주지 않는다).
pub fn filter(gpa: std.mem.Allocator, gz: []const u8, set: *FrameSet, opts: Options) !Result {
    var result: Result = .{ .outcome = .kept, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    var scan: Scan = .init(gpa);
    defer scan.deinit(gpa);
    {
        var sink: ScanSink = .{ .gpa = gpa, .scan = &scan, .set = set, .arena = std.heap.ArenaAllocator.init(gpa) };
        defer sink.arena.deinit();
        eachEvent(gpa, gz, &sink) catch |e| switch (e) {
            error.Malformed, error.EventTooLarge => {
                result.outcome = .malformed;
                return result;
            },
            else => return e,
        };
    }
    const foreign_worker = try scan.resolve(gpa, set);
    if (set.count() == 0) {
        // V-A1: sidecar 의 씨앗(렌더러가 답한다)도 브라우저의 씨앗도 없다 — 그 탭의 프레임을 모르니 가를 수 없다.
        result.outcome = .renderer_unresponsive;
        result.summary = .{ .covered_ms = opts.covered_ms };
        return result;
    }
    if (foreign_worker) |f| {
        // N1: 남길 렌더러 프로세스에 가족 밖 프레임(같은 프로세스에 든 사용자 iframe)의 워커가 있었다 — 그 워커의 일은 주 스레드 표본·GC 등에
        // 섞여 들 수 있다(F3 와 같은 판단 — 통째로 버리고 이유를 싣는다).
        result.outcome = .mixed_content;
        result.foreign = try result.arena.allocator().dupe(u8, f);
        result.summary = .{ .covered_ms = opts.covered_ms };
        return result;
    }
    // Compress 는 내보낼 곳에 버퍼가 있어야 한다(8 바이트 넘게 — 처음부터 64 KiB 를 잡는다).
    var out_buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer out_buf.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var comp: ?flate.Compress = if (opts.write_gz) try flate.Compress.init(&out_buf.writer, &window, .gzip, .level_1) else null;
    var keep: KeepSink = .{
        .gpa = gpa,
        .scan = &scan,
        .set = set,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .out = if (comp) |*c| &c.writer else null,
        .summary = &result.summary,
        .result_arena = result.arena.allocator(),
        .renderer_silent = opts.renderer_silent,
        .shared_process = opts.shared_process,
    };
    defer keep.arena.deinit();
    defer keep.reqs.deinit(gpa);
    if (keep.out) |w| try w.writeAll("{\"traceEvents\":[");
    eachEvent(gpa, gz, &keep) catch |e| switch (e) {
        error.Malformed, error.EventTooLarge => {
            result.outcome = .malformed;
            return result;
        },
        else => return e,
    };
    if (keep.foreign) |f| {
        result.outcome = .mixed_content;
        result.foreign = f;
        result.summary = .{ .covered_ms = opts.covered_ms };
        return result;
    }
    if (keep.out) |w| try w.writeAll("],\"metadata\":{\"source\":\"maru\",\"dataOrigin\":\"TraceEvents\"}}");
    if (comp) |*c| {
        try c.writer.flush();
        try c.finish();
        result.gz = try result.arena.allocator().dupe(u8, out_buf.written());
    }
    result.summary.covered_ms = opts.covered_ms;
    if (opts.truncated) {
        // 잘린 trace 는 기록한 시간 전부를 덮지 않는다 — 시작(가장 이른 이벤트)부터 남은 주 스레드 이벤트의 끝까지(기록한 시간을 넘지 않게).
        result.summary.truncated = true;
        const span_ms: f64 = if (keep.main_end_ts) |e| (if (scan.start_ts) |st| @max(0, (e - st) / 1000.0) else 0) else 0;
        result.summary.covered_ms = @min(opts.covered_ms, std.math.lossyCast(u32, span_ms));
    }
    result.summary.json_bytes = keep.json_bytes;
    result.summary.gz_bytes = result.gz.len;
    return result;
}

// ── 결과 JSON ──────────────────────────────────────────────────────────────────────────────────────────

/// 요약 JSON(≤ 8 KiB — 주소는 512 B 로 자른다).
pub fn writeSummary(s: *std.json.Stringify, sum: *const Summary) !void {
    try s.beginObject();
    try s.objectField("covered_ms");
    try s.write(sum.covered_ms);
    if (sum.truncated) {
        try s.objectField("truncated");
        try s.write(true);
    }
    if (sum.compositor_dropped > 0) {
        try s.objectField("compositor_events_dropped");
        try s.write(sum.compositor_dropped);
    }
    try s.objectField("events_kept");
    try s.write(sum.events_kept);
    try s.objectField("events_dropped");
    try s.write(sum.events_dropped);
    try s.objectField("json_bytes");
    try s.write(sum.json_bytes);
    try s.objectField("gz_bytes");
    try s.write(sum.gz_bytes);
    try s.objectField("navigations");
    try s.write(sum.navigations);
    if (sum.first_url.len > 0) {
        try s.objectField("url");
        try s.write(sum.first_url[0..@min(sum.first_url.len, 512)]);
    }
    if (sum.fcp_ms) |v| {
        try s.objectField("fcp_ms");
        try s.print("{d:.1}", .{v});
    }
    if (sum.lcp_ms) |v| {
        try s.objectField("lcp_ms");
        try s.print("{d:.1}", .{v});
    }
    try s.objectField("long_tasks");
    try s.beginObject();
    try s.objectField("count");
    try s.write(sum.long_task_count);
    try s.objectField("total_ms");
    try s.print("{d:.1}", .{sum.long_task_total_ms});
    try s.objectField("total_blocking_ms");
    try s.print("{d:.1}", .{sum.total_blocking_ms});
    try s.endObject();
    try s.objectField("main_thread_busy_pct");
    const pct: f64 = if (sum.covered_ms > 0) @min(100, sum.main_busy_ms * 100 / @as(f64, @floatFromInt(sum.covered_ms))) else 0;
    try s.print("{d:.1}", .{pct});
    try s.objectField("frames_presented");
    try s.write(sum.frames);
    try s.objectField("screenshots");
    try s.write(sum.screenshots);
    try s.objectField("requests");
    try s.beginObject();
    try s.objectField("count");
    try s.write(sum.requests);
    try s.objectField("bytes");
    try s.write(sum.request_bytes);
    try s.objectField("slowest");
    try s.beginArray();
    for (sum.slowest[0..sum.slowest_len]) |x| {
        try s.beginObject();
        try s.objectField("url");
        try s.write(x.url[0..@min(x.url.len, 512)]);
        try s.objectField("ms");
        try s.write(x.ms);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
}

// ── 시험 ───────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn gzipOf(gpa: std.mem.Allocator, json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, .gzip, .level_1);
    try c.writer.writeAll(json);
    try c.writer.flush();
    try c.finish();
    return gpa.dupe(u8, out.written());
}

fn gunzip(gpa: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return gpa.dupe(u8, out.written());
}

fn parse(json: []const u8, why: *?Why) !Params {
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer v.deinit();
    return parseParams(v.value, why);
}

test "W9e②: trace 인자 — 동작마다 받는 키, 길이 1000..30000 정수, 모르는 키, 기본값" {
    var why: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"start\",\"duration_ms\":8000,\"reload\":true,\"screenshots\":false}", &why);
    try testing.expect(p.action == .start and p.duration_ms == 8000 and p.reload and !p.screenshots);
    const d = try parse("{\"id\":1,\"action\":\"start\"}", &why);
    try testing.expect(d.duration_ms == default_duration_ms and d.screenshots and !d.reload);
    try testing.expect((try parse("{\"id\":1,\"action\":\"stop\",\"file\":true}", &why)).file);
    const bad = [_]struct { j: []const u8, w: Why }{
        .{ .j = "{\"id\":1,\"action\":\"start\",\"nope\":1}", .w = .unknown_key },
        .{ .j = "{\"id\":1,\"action\":\"pause\"}", .w = .action_invalid },
        .{ .j = "{\"id\":1,\"action\":\"start\",\"duration_ms\":999}", .w = .duration_invalid },
        .{ .j = "{\"id\":1,\"action\":\"start\",\"duration_ms\":30001}", .w = .duration_invalid },
        .{ .j = "{\"id\":1,\"action\":\"start\",\"duration_ms\":1500.5}", .w = .duration_invalid },
        .{ .j = "{\"id\":1,\"action\":\"stop\",\"duration_ms\":5000}", .w = .action_invalid },
        .{ .j = "{\"id\":1,\"action\":\"start\",\"file\":true}", .w = .action_invalid },
        .{ .j = "{\"id\":1,\"action\":\"start\",\"reload\":1}", .w = .reload_invalid },
        .{ .j = "{\"id\":1,\"action\":\"stop\",\"file\":\"yes\"}", .w = .file_invalid },
        .{ .j = "{\"id\":1,\"action\":\"stop\",\"offset\":3}", .w = .action_invalid },
        .{ .j = "{\"id\":1,\"action\":\"read\",\"offset\":-1}", .w = .offset_invalid },
    };
    try testing.expectEqual(@as(u32, 65536), (try parse("{\"id\":1,\"action\":\"read\",\"offset\":65536}", &why)).offset);
    for (bad) |b| {
        try testing.expectError(error.InvalidParams, parse(b.j, &why));
        try testing.expectEqual(b.w, why.?);
    }
    const arg = try serializeArg(testing.allocator, p);
    defer testing.allocator.free(arg);
    const again = try parse(arg, &why);
    try testing.expect(again.duration_ms == 8000 and again.reload and !again.screenshots);
}

const A = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1"; // 그 탭 주 프레임
const A2 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2"; // 그 탭의 iframe
const U = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB9"; // 사용자 탭의 같은 사이트 iframe(같은 렌더러 프로세스)

fn fixture(comptime extra: []const u8) []const u8 {
    return fixtureFront("", extra);
}

/// `front` 는 메타데이터 바로 뒤(TracingStartedInBrowser 앞)에 — JSON 의 이벤트 차례는 ts 차례가 아니다(스레드 버퍼마다 나온다).
fn fixtureFront(comptime front: []const u8, comptime extra: []const u8) []const u8 {
    return "{\"traceEvents\":[" ++
        "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"tid\":0,\"args\":{\"name\":\"Browser\"}}," ++
        "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":2,\"tid\":0,\"args\":{\"name\":\"GPU Process\"}}," ++
        "{\"name\":\"process_labels\",\"ph\":\"M\",\"pid\":10,\"tid\":0,\"args\":{\"labels\":\"SECRET USER TAB TITLE\"}}," ++
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":10,\"tid\":11,\"args\":{\"name\":\"CrRendererMain\"}}," ++
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":10,\"tid\":12,\"args\":{\"name\":\"Compositor\"}}," ++
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":10,\"tid\":20,\"args\":{\"name\":\"v8:ProfEvntProc\"}}," ++
        front ++
        // 주 스레드 isolate 의 V8 프로파일(번호 0x1 — 그 `ProfileChunk` 는 프로파일러 스레드 20 에서 난다).
        "{\"name\":\"Profile\",\"cat\":\"disabled-by-default-v8.cpu_profiler\",\"ph\":\"P\",\"pid\":10,\"tid\":11,\"ts\":1500,\"id\":\"0x1\",\"args\":{\"data\":{\"startTime\":1500}}}," ++
        "{\"name\":\"TracingStartedInBrowser\",\"ph\":\"I\",\"pid\":1,\"tid\":1,\"ts\":1000,\"args\":{\"data\":{\"frames\":[{\"frame\":\"" ++ A ++ "\",\"url\":\"http://a.test/\",\"processId\":10},{\"frame\":\"" ++ A2 ++ "\",\"parent\":\"" ++ A ++ "\",\"url\":\"http://b.test/\",\"processId\":30}]}}}," ++
        "{\"name\":\"UkmPageLoadTimingUpdate\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":1100,\"dur\":5,\"args\":{\"url\":\"http://bank.test/?acct=SECRET\"}}," ++
        "{\"name\":\"Screenshot\",\"ph\":\"O\",\"pid\":1,\"tid\":1,\"ts\":1200,\"args\":{\"snapshot\":\"/9j/\"}}," ++
        "{\"name\":\"GPUTask\",\"ph\":\"X\",\"pid\":2,\"tid\":3,\"ts\":1200,\"dur\":5,\"args\":{}}," ++
        "{\"name\":\"RunTask\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":2000,\"dur\":120000,\"args\":{}}," ++
        "{\"name\":\"RunTask\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":130000,\"dur\":30000,\"args\":{}}," ++
        "{\"name\":\"RunTask\",\"ph\":\"X\",\"pid\":30,\"tid\":31,\"ts\":2000,\"dur\":90000,\"args\":{}}," ++
        "{\"name\":\"UpdateCounters\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":2100,\"args\":{\"data\":{\"documents\":5}}}," ++
        "{\"name\":\"TracingSessionIdForWorker\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":2200,\"args\":{\"data\":{\"workerThreadId\":19}}}," ++
        "{\"name\":\"FunctionCall\",\"ph\":\"X\",\"pid\":10,\"tid\":19,\"ts\":2300,\"dur\":5,\"args\":{\"data\":{\"url\":\"sw.js\"}}}," ++
        "{\"name\":\"navigationStart\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":3000,\"args\":{\"frame\":\"" ++ A ++ "\"}}," ++
        "{\"name\":\"firstContentfulPaint\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":53000,\"args\":{\"frame\":\"" ++ A ++ "\"}}," ++
        "{\"name\":\"largestContentfulPaint::Candidate\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":83000,\"args\":{\"frame\":\"" ++ A ++ "\",\"data\":{\"size\":100}}}," ++
        "{\"name\":\"ResourceSendRequest\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":4000,\"args\":{\"data\":{\"requestId\":\"r1\",\"frame\":\"" ++ A ++ "\",\"url\":\"http://u:p@a.test/x?q=1\",\"headers\":[{\"name\":\"Authorization\",\"value\":\"Bearer TOKEN\"}]}}}," ++
        "{\"name\":\"ResourceReceiveResponse\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":5000,\"args\":{\"data\":{\"requestId\":\"r1\",\"frame\":\"" ++ A ++ "\",\"headers\":[{\"name\":\"X-Secret-Resp\",\"value\":\"RESPHEADERSECRET\"}]}}}," ++
        "{\"name\":\"ResourceFinish\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":9000,\"args\":{\"data\":{\"requestId\":\"r1\",\"encodedDataLength\":1234}}}," ++
        "{\"name\":\"ParseHTML\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":3100,\"dur\":10,\"args\":{\"beginData\":{\"frame\":\"" ++ A ++ "\",\"url\":\"http://a.test/\"}}}" ++
        extra ++ "],\"metadata\":{\"cpu-brand\":\"X\"}}";
}

fn familySet(gpa: std.mem.Allocator) !FrameSet {
    var set = FrameSet.init(gpa);
    try set.add(A);
    try set.add(A2);
    return set;
}

test "W9e②: 거르기 — 브라우저·GPU 는 허용 목록만, process_labels·다른 프로세스·워커 스레드·UpdateCounters 를 빼고, 머리 값·사용자 정보를 지운다, 요약을 센다" {
    const gpa = testing.allocator;
    const gz = try gzipOf(gpa, fixture(""));
    defer gpa.free(gz);
    var set = try familySet(gpa);
    defer set.deinit();
    var r = try filter(gpa, gz, &set, .{ .covered_ms = 1000 });
    defer r.deinit();
    try testing.expectEqual(Outcome.kept, r.outcome);
    const json = try gunzip(gpa, r.gz);
    defer gpa.free(json);
    for ([_][]const u8{ "SECRET USER TAB TITLE", "bank.test", "GPUTask", "UpdateCounters", "sw.js", "TOKEN", "RESPHEADERSECRET", "u:p@", "cpu-brand" }) |needle| {
        if (std.mem.indexOf(u8, json, needle) != null) {
            std.debug.print("leaked {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "\"traceEvents\":[", "TracingStartedInBrowser", "Screenshot", "CrRendererMain", "ParseHTML", "\"name\":\"Authorization\"" }) |needle| try testing.expect(std.mem.indexOf(u8, json, needle) != null);
    // 다른 렌더러(그 탭의 다른 사이트 iframe 프로세스 30)는 남기지 않는다.
    try testing.expect(std.mem.indexOf(u8, json, "\"pid\":30") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const s = r.summary;
    try testing.expectEqual(@as(u32, 1), s.long_task_count); // 120 ms 하나(30 ms 는 아니다)
    try testing.expectEqual(@as(f64, 70), s.total_blocking_ms);
    try testing.expectEqual(@as(f64, 150), s.main_busy_ms);
    try testing.expectEqual(@as(f64, 50), s.fcp_ms.?);
    try testing.expectEqual(@as(f64, 80), s.lcp_ms.?);
    try testing.expectEqual(@as(u32, 1), s.requests);
    try testing.expectEqual(@as(u64, 1234), s.request_bytes);
    try testing.expectEqual(@as(u32, 5), s.slowest[0].ms);
    try testing.expectEqualStrings("http://a.test/x?q=1", s.slowest[0].url);
    try testing.expectEqual(@as(u32, 1), s.screenshots);
    try testing.expect(s.events_dropped >= 6);
}

test "W9e②: F3 — 가족 밖의 프레임이 하나라도 남길 이벤트에 있으면 통째로 버린다(어느 깊이든·대소문자), 가족 안이면 헛폐기 없음" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    const cases = [_][]const u8{
        ",{\"name\":\"ParseHTML\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"beginData\":{\"frame\":\"" ++ U ++ "\"}}}",
        ",{\"name\":\"EventDispatch\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"data\":{\"type\":\"click\",\"frame\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb9\"}}}",
        ",{\"name\":\"X\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"data\":{\"stack\":[{\"frameId\":\"" ++ U ++ "\"}]}}}",
        ",{\"name\":\"Y\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"data\":{\"parent\":\"" ++ U ++ "\"}}}", // parent 칸만(변이 M2)
    };
    inline for (cases) |extra| {
        const gz = try gzipOf(gpa, fixture(extra));
        defer gpa.free(gz);
        var r = try filter(gpa, gz, &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
        try testing.expectEqual(@as(usize, 0), r.gz.len);
    }
    // 가족의 iframe(A2) 프레임·소문자 id·짧은 「parent」 글은 폐기가 아니다.
    const fine = ",{\"name\":\"ParseHTML\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"beginData\":{\"frame\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2\",\"parent\":\"none\"}}}";
    const gz = try gzipOf(gpa, fixture(fine));
    defer gpa.free(gz);
    var r = try filter(gpa, gz, &set, .{});
    defer r.deinit();
    try testing.expectEqual(Outcome.kept, r.outcome);
    // 버린 프로세스(브라우저의 다른 이벤트)의 남의 프레임은 폐기 사유가 아니다 — 남기지 않으니까.
    const browser_other = ",{\"name\":\"RenderFrameHostImpl::X\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":4000,\"dur\":1,\"args\":{\"frame\":\"" ++ U ++ "\"}}";
    const gz2 = try gzipOf(gpa, fixture(browser_other));
    defer gpa.free(gz2);
    var r2 = try filter(gpa, gz2, &set, .{});
    defer r2.deinit();
    try testing.expectEqual(Outcome.kept, r2.outcome);
}

test "W9e② 적대 리뷰: 너무 깊은 값은 폐기(닫힌 쪽), 페이지의 같은 이름 user timing 은 브라우저·렌더러 판정을 바꾸지 않는다, 범위 밖의 수에 죽지 않는다" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    // 깊이 40 의 배열 — 끝까지 보지 못하면 남기지 않는다.
    const deep = comptime (",{\"name\":\"X\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"data\":" ++ @import("array_repeat").repeat("[", 40) ++ @import("array_repeat").repeat("]", 40) ++ "}}");
    const gz = try gzipOf(gpa, fixture(deep));
    defer gpa.free(gz);
    var r = try filter(gpa, gz, &set, .{});
    defer r.deinit();
    try testing.expectEqual(Outcome.mixed_content, r.outcome);
    // 렌더러(pid 10)의 user timing 「TracingStartedInBrowser」 — 렌더러의 일(RunTask)은 그대로 남고 긴 작업으로 센다.
    const mark = ",{\"name\":\"TracingStartedInBrowser\",\"cat\":\"blink.user_timing\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":4000,\"args\":{\"data\":{\"frames\":[{\"frame\":\"" ++ A ++ "\",\"processId\":30}]}}}";
    const gz2 = try gzipOf(gpa, fixture(mark));
    defer gpa.free(gz2);
    var r2 = try filter(gpa, gz2, &set, .{});
    defer r2.deinit();
    try testing.expectEqual(Outcome.kept, r2.outcome);
    try testing.expectEqual(@as(u32, 1), r2.summary.long_task_count);
    const json = try gunzip(gpa, r2.gz);
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"pid\":30") == null); // 하위 프레임 프로세스는 여전히 버린다
    // 범위 밖의 수(pid·바이트·시각) — 정수로 바꾸다 죽지 않는다.
    const huge = ",{\"name\":\"Layout\",\"ph\":\"X\",\"pid\":1e300,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{}}" ++
        ",{\"name\":\"ResourceSendRequest\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":-1e300,\"args\":{\"data\":{\"requestId\":\"r9\",\"url\":\"http://a.test/h\"}}}" ++
        ",{\"name\":\"ResourceFinish\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":1e300,\"args\":{\"data\":{\"requestId\":\"r9\",\"encodedDataLength\":1e300}}}";
    const gz3 = try gzipOf(gpa, fixture(huge));
    defer gpa.free(gz3);
    var r3 = try filter(gpa, gz3, &set, .{});
    defer r3.deinit();
    try testing.expectEqual(Outcome.kept, r3.outcome);
}

test "W9e②: F2 — 그 탭 주 프레임이 다른 사이트로 옮기면(FrameCommittedInBrowser 의 새 pid) 그 pid 도 남긴다, 하위 프레임의 커밋 pid 는 아니다" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    // 새 프로세스들의 주 스레드 이름(N1 — 렌더러에서는 이름이 정해진 스레드의 이벤트만 남는다).
    const extra = ",{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":40,\"tid\":41,\"args\":{\"name\":\"CrRendererMain\"}}" ++
        ",{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":50,\"tid\":51,\"args\":{\"name\":\"CrRendererMain\"}}" ++
        ",{\"name\":\"FrameCommittedInBrowser\",\"ph\":\"I\",\"pid\":1,\"tid\":1,\"ts\":6000,\"args\":{\"data\":{\"frame\":\"" ++ A ++ "\",\"url\":\"http://c.test/\",\"processId\":40}}}" ++
        ",{\"name\":\"FrameCommittedInBrowser\",\"ph\":\"I\",\"pid\":1,\"tid\":1,\"ts\":6000,\"args\":{\"data\":{\"frame\":\"" ++ A2 ++ "\",\"parent\":\"" ++ A ++ "\",\"url\":\"http://d.test/\",\"processId\":50}}}" ++
        ",{\"name\":\"Layout\",\"ph\":\"X\",\"pid\":40,\"tid\":41,\"ts\":7000,\"dur\":1,\"args\":{}}" ++
        ",{\"name\":\"Layout\",\"ph\":\"X\",\"pid\":50,\"tid\":51,\"ts\":7000,\"dur\":1,\"args\":{}}";
    const gz = try gzipOf(gpa, fixture(extra));
    defer gpa.free(gz);
    var r = try filter(gpa, gz, &set, .{});
    defer r.deinit();
    try testing.expectEqual(Outcome.kept, r.outcome);
    const json = try gunzip(gpa, r.gz);
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"pid\":40") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"pid\":50") == null);
    try testing.expectEqual(@as(u32, 1), r.summary.navigations); // 주 프레임 커밋 하나(하위 프레임 커밋·TSIB 는 세지 않는다)
}

test "W9e②: 망가진 gzip·JSON 은 malformed(풀다 멈춤), 요약만이면 gzip 을 쓰지 않는다, 요약 JSON 은 8 KiB 안" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    var r1 = try filter(gpa, "\x1f\x8b\x08\x00garbage", &set, .{});
    defer r1.deinit();
    try testing.expectEqual(Outcome.malformed, r1.outcome);
    const bad_json = try gzipOf(gpa, "{\"traceEvents\":[{\"name\":}]}");
    defer gpa.free(bad_json);
    var r2 = try filter(gpa, bad_json, &set, .{});
    defer r2.deinit();
    try testing.expectEqual(Outcome.malformed, r2.outcome);
    const gz = try gzipOf(gpa, fixture(""));
    defer gpa.free(gz);
    var r3 = try filter(gpa, gz, &set, .{ .write_gz = false, .covered_ms = 300 });
    defer r3.deinit();
    try testing.expectEqual(@as(usize, 0), r3.gz.len);
    try testing.expect(r3.summary.events_kept > 0);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    var big = r3.summary;
    const long = @import("array_repeat").repeat("x", 4000);
    big.first_url = long;
    big.slowest_len = 5;
    for (&big.slowest) |*x| x.* = .{ .url = long, .ms = 1 };
    try writeSummary(&s, &big);
    try testing.expect(aw.written().len <= 8 * 1024);
    const st = try stripUserinfo(gpa, "http://u:p@h.test/a");
    defer gpa.free(st);
    try testing.expectEqualStrings("http://h.test/a", st);
    try testing.expectEqualStrings("http://h.test/a@b", try stripUserinfo(gpa, "http://h.test/a@b"));
    const st2 = try stripUserinfo(gpa, "http://u:p@q@h.test/");
    defer gpa.free(st2);
    try testing.expectEqualStrings("http://h.test/", st2); // 권한 안의 마지막 @ 까지(변이 M9)
}

fn filterOf(gpa: std.mem.Allocator, json: []const u8, set: *FrameSet, opts: Options) !Result {
    const gz = try gzipOf(gpa, json);
    defer gpa.free(gz);
    return filter(gpa, gz, set, opts);
}

test "W9e② A1-1: 가족에 묶이지 않은 layer tree 의 이벤트(컴포지터만 쓰는 남의 위젯)면 통째로 버린다, 프레임은 가족 layer tree 의 DrawFrame 만 센다" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    const bind = ",{\"name\":\"SetLayerTreeId\",\"cat\":\"devtools.timeline\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ A ++ "\",\"layerTreeId\":1}}}";
    const draw1 = ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4000,\"args\":{\"layerTreeId\":1,\"frameSeqId\":5}}";
    const begin1 = ",{\"name\":\"BeginFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":3900,\"args\":{\"layerTreeId\":1}}";
    // 가족의 것만 — 남김, 프레임 1(번호 없는 DrawFrame 은 세지 않는다).
    {
        var r = try filterOf(gpa, fixture(bind ++ begin1 ++ draw1 ++ ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4100,\"args\":{}}"), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u32, 1), r.summary.frames);
    }
    const bad = [_][]const u8{
        // 묶이지 않은 번호 2 — 같은 프로세스 사용자 iframe 의 CSS 애니메이션(a1-anim 의 꼴).
        bind ++ draw1 ++ ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4200,\"args\":{\"layerTreeId\":2}}",
        // 깊은 칸의 번호도.
        bind ++ ",{\"name\":\"Commit\",\"ph\":\"X\",\"pid\":10,\"tid\":12,\"ts\":4200,\"dur\":1,\"args\":{\"data\":{\"layerTreeId\":2}}}",
        // 다른 프로세스(그 탭의 OOPIF 프로세스 30)에서 묶인 같은 번호는 이 프로세스의 가족이 아니다.
        ",{\"name\":\"SetLayerTreeId\",\"cat\":\"devtools.timeline\",\"ph\":\"I\",\"pid\":30,\"tid\":31,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ A2 ++ "\",\"layerTreeId\":2}}}" ++
            ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4200,\"args\":{\"layerTreeId\":2}}",
        // 페이지의 user timing 위장(같은 이름의 mark)은 묶지 않는다.
        ",{\"name\":\"SetLayerTreeId\",\"cat\":\"blink.user_timing\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ A ++ "\",\"layerTreeId\":2}}}" ++
            ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4200,\"args\":{\"layerTreeId\":2}}",
        // 가족이 아닌 프레임에 묶인 번호 — 그 SetLayerTreeId 자체가 남의 프레임(F3).
        ",{\"name\":\"SetLayerTreeId\",\"cat\":\"devtools.timeline\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ U ++ "\",\"layerTreeId\":2}}}",
    };
    inline for (bad, 0..) |extra, i| {
        var r = try filterOf(gpa, fixture(extra), &set, .{});
        defer r.deinit();
        if (r.outcome != .mixed_content) {
            std.debug.print("layer tree case {d} kept\n", .{i});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, 0), r.gz.len);
    }
    // 브라우저 프로세스의 layer tree 이벤트는 허용 목록이 이미 버린다 — 폐기 사유가 아니다.
    var r2 = try filterOf(gpa, fixture(bind ++ ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":1,\"tid\":1,\"ts\":4200,\"args\":{\"layerTreeId\":9}}"), &set, .{});
    defer r2.deinit();
    try testing.expectEqual(Outcome.kept, r2.outcome);
}

test "W9e② A4-1: sidecar 가 자른 trace — 끝나지 않은 마지막 이벤트는 버리고 남김, 덮은 시간은 남은 주 스레드 이벤트의 끝까지, 요약에 truncated" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    const full = fixture("");
    const at = std.mem.indexOf(u8, full, "{\"name\":\"UpdateCounters\"").? + 12;
    var r = try filterOf(gpa, full[0..at], &set, .{ .covered_ms = 5000, .truncated = true });
    defer r.deinit();
    try testing.expectEqual(Outcome.kept, r.outcome);
    try testing.expect(r.summary.truncated);
    // 시작 ts 1000 µs, 주 스레드의 마지막 끝은 RunTask 130000 + 30000 µs — 159 ms(기록한 5 s 가 아니다).
    try testing.expectEqual(@as(u32, 159), r.summary.covered_ms);
    try testing.expectEqual(@as(u32, 1), r.summary.long_task_count);
    const json = try gunzip(gpa, r.gz);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeSummary(&s, &r.summary);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"truncated\":true") != null);
    // 자르지 않았으면 덮은 시간은 sidecar 의 것 그대로이고 표시가 없다.
    var r2 = try filterOf(gpa, full, &set, .{ .covered_ms = 5000 });
    defer r2.deinit();
    try testing.expectEqual(@as(u32, 5000), r2.summary.covered_ms);
    try testing.expect(!r2.summary.truncated);
}

test "W9e② V-A1: 가족 씨앗은 브라우저의 TracingStartedInBrowser 에서도 — sidecar 집합이 비어도(멈춘 렌더러) 그 탭 trace 를 남김, 둘 다 비면 renderer_unresponsive" {
    const gpa = testing.allocator;
    // sidecar 가 보낸 집합이 비었다(`Page.getFrameTree` 에 렌더러가 답하지 않았다) — TSIB 의 A·A2 로 가족을 안다.
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        var r = try filterOf(gpa, fixture(""), &empty, .{ .renderer_silent = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u32, 1), r.summary.long_task_count); // 주 프레임 pid(10)도 TSIB 에서
        try testing.expect(empty.contains(A) and empty.contains(A2));
    }
    // 그래도 남의 프레임(U)이 남길 이벤트에 있으면 폐기(씨앗은 그 탭의 프레임만이다).
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        var r = try filterOf(gpa, fixture(",{\"name\":\"ParseHTML\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"beginData\":{\"frame\":\"" ++ U ++ "\"}}}"), &empty, .{ .renderer_silent = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
    }
    // TSIB 도 없고 집합도 비었다 — 가를 수 없다.
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        const no_tsib = "{\"traceEvents\":[{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"tid\":0,\"args\":{\"name\":\"Browser\"}}," ++
            "{\"name\":\"RunTask\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":2000,\"dur\":5,\"args\":{}}]}";
        var r = try filterOf(gpa, no_tsib, &empty, .{ .renderer_silent = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.renderer_unresponsive, r.outcome);
        try testing.expectEqual(@as(usize, 0), r.gz.len);
    }
}

test "W9e② V-A1: 렌더러가 같은 이름·범주의 TracingStartedInBrowser 를 흉내 내도 가족 씨앗이 되지 않는다(브라우저 pid 만)" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    // 렌더러(pid 10)가 낸 「TracingStartedInBrowser」 — 남의 프레임 U 를 싣는다. 씨앗이 되면 U 가 가족이 되어 아래 U 의 이벤트가 남는다.
    const fake = ",{\"name\":\"TracingStartedInBrowser\",\"cat\":\"disabled-by-default-devtools.timeline\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":1500,\"args\":{\"data\":{\"frames\":[{\"frame\":\"" ++ U ++ "\",\"processId\":10}]}}}" ++
        ",{\"name\":\"ParseHTML\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"beginData\":{\"frame\":\"" ++ U ++ "\"}}}";
    var r = try filterOf(gpa, fixture(fake), &set, .{});
    defer r.deinit();
    try testing.expectEqual(Outcome.mixed_content, r.outcome);
    try testing.expect(!set.contains(U));
}

test "W9e② V-A1·결정 12: 차례와 무관 — TSIB 보다 앞에 온 SetLayerTreeId 도 가족 layer tree, 막힌 탭은 가를 수 없는 것만 빼고 남김, 남의 프레임이 보이면 버림" {
    const gpa = testing.allocator;
    const bind = ",{\"name\":\"SetLayerTreeId\",\"cat\":\"devtools.timeline\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ A ++ "\",\"layerTreeId\":1}}}";
    const draw1 = ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4000,\"args\":{\"layerTreeId\":1,\"frameSeqId\":5}}";
    const draw2 = ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4100,\"args\":{\"layerTreeId\":2,\"frameSeqId\":6}}";
    // 묶기가 TSIB 앞(JSON 차례)이고 sidecar 집합에는 주 프레임이 없다(A2 만) — TSIB 가 A 를 더하고 끝에 가르므로 가족 layer tree 다.
    {
        var partial = FrameSet.init(gpa);
        defer partial.deinit();
        try partial.add(A2);
        var r = try filterOf(gpa, fixtureFront(bind[1..] ++ ",", draw1), &partial, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u32, 1), r.summary.frames);
    }
    // 결정 12 — 멈춘 렌더러(sidecar 집합이 비었다)이고 그 프로세스에 가족 layer tree 가 없다. 남의 프레임이 들 수 있었으면(`shared_process`) 가를 수
    // 없는 것만 뺀다: 묶이지 않은 layer tree·주 스레드 밖(V8 프로파일러 스레드 20 의 ProfileChunk)은 빼고, 주 스레드의 긴 작업은 남긴다.
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        const chunk = ",{\"name\":\"ProfileChunk\",\"ph\":\"P\",\"pid\":10,\"tid\":20,\"ts\":4300,\"id\":\"0x1\",\"args\":{\"data\":{\"cpuProfile\":{\"nodes\":[]}}}}";
        // 주 스레드의 이벤트라도 묶이지 않은 layer tree 를 실으면 뺀다.
        const main_lt = ",{\"name\":\"UpdateLayerTree\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4500,\"dur\":1,\"args\":{\"data\":{\"layerTreeId\":2}}}";
        var r = try filterOf(gpa, fixture(draw2 ++ chunk ++ main_lt), &empty, .{ .renderer_silent = true, .shared_process = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u64, 3), r.summary.compositor_dropped); // 컴포지터 스레드(12)의 DrawFrame·프로파일러 스레드(20)의 ProfileChunk·주 스레드의 묶이지 않은 layer tree
        try testing.expectEqual(@as(u32, 0), r.summary.frames);
        try testing.expectEqual(@as(u32, 1), r.summary.long_task_count); // 주 스레드의 120 ms
        const json = try gunzip(gpa, r.gz);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "ProfileChunk") == null and std.mem.indexOf(u8, json, "\"layerTreeId\":2") == null);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try writeSummary(&s, &r.summary);
        try testing.expect(std.mem.indexOf(u8, aw.written(), "\"compositor_events_dropped\":3") != null);
    }
    // 가족만 쓰는 프로세스였으면(`shared_process` 거짓) 그 컴포지터·프로파일은 가족 것이다 — 남기고 프레임도 센다.
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        const chunk = ",{\"name\":\"ProfileChunk\",\"ph\":\"P\",\"pid\":10,\"tid\":20,\"ts\":4300,\"id\":\"0x1\",\"args\":{\"data\":{\"cpuProfile\":{\"nodes\":[]}}}}";
        var r = try filterOf(gpa, fixture(draw2 ++ chunk), &empty, .{ .renderer_silent = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u64, 0), r.summary.compositor_dropped);
        try testing.expectEqual(@as(u32, 1), r.summary.frames);
        const json = try gunzip(gpa, r.gz);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "ProfileChunk") != null);
    }
    // 가를 수 있는 남의 것(주 스레드 이벤트의 남의 프레임)이 보이면 막힌 탭이어도 통째로 버린다(F3 그대로).
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        const foreign = ",{\"name\":\"TimerFire\",\"ph\":\"X\",\"pid\":10,\"tid\":11,\"ts\":4000,\"dur\":1,\"args\":{\"data\":{\"frame\":\"" ++ U ++ "\"}}}";
        var r = try filterOf(gpa, fixture(draw2 ++ foreign), &empty, .{ .renderer_silent = true, .shared_process = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
        try testing.expectEqual(@as(usize, 0), r.gz.len);
    }
    // 렌더러가 답했다면(집합이 있다) 같은 꼴은 그대로 남의 위젯(A1-1).
    {
        var set = try familySet(gpa);
        defer set.deinit();
        var r = try filterOf(gpa, fixture(draw2), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
    }
    // 멈췄어도 그 프로세스에 가족 layer tree 가 있으면 묶이지 않은 번호는 남의 것이다.
    {
        var empty = FrameSet.init(gpa);
        defer empty.deinit();
        var r = try filterOf(gpa, fixture(bind ++ draw2), &empty, .{ .renderer_silent = true });
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
    }
}

test "W9e② N1: 렌더러 스레드는 허용 목록 — 주 isolate 의 ProfileChunk 만 남기고 워커 isolate 의 표본·이름 모를 스레드·뺀 스레드의 이름 메타는 뺀다, 「Profile」 위장은 번호를 들이지 못한다" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    const meta = "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":10,\"tid\":19,\"args\":{\"name\":\"DedicatedWorker thread\"}}," ++
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":10,\"tid\":21,\"args\":{\"name\":\"ThreadPoolForegroundWorker\"}},";
    const chunk = struct {
        fn of(comptime id: []const u8, comptime fn_name: []const u8) []const u8 {
            return ",{\"name\":\"ProfileChunk\",\"cat\":\"disabled-by-default-v8.cpu_profiler\",\"ph\":\"P\",\"pid\":10,\"tid\":20,\"ts\":4300,\"id\":\"" ++ id ++
                "\",\"args\":{\"data\":{\"cpuProfile\":{\"nodes\":[{\"callFrame\":{\"functionName\":\"" ++ fn_name ++ "\",\"url\":\"http://a.test/s.js?tok=" ++ fn_name ++ "\"},\"id\":2}]}}}}";
        }
    };
    const extra = comptime
        // 같은 프로세스 사용자 iframe 의 전용 워커 — 그 isolate 의 프로파일(워커 스레드 19 에서 시작)과 표본(프로파일러 스레드 20).
        ",{\"name\":\"Profile\",\"cat\":\"disabled-by-default-v8.cpu_profiler\",\"ph\":\"P\",\"pid\":10,\"tid\":19,\"ts\":1600,\"id\":\"0x2\",\"args\":{\"data\":{}}}" ++
        chunk.of("0x2", "USERSECRETFN") ++
        chunk.of("0x1", "AGENTMAINFN") ++
        // 페이지의 `performance.measure("Profile")` — 주 스레드의 작은 번호 비동기 이벤트. 이 번호의 표본을 주 스레드 것으로 들이지 않는다.
        ",{\"name\":\"Profile\",\"cat\":\"blink.user_timing\",\"ph\":\"b\",\"pid\":10,\"tid\":11,\"ts\":1700,\"id\":\"0x3\",\"args\":{}}" ++
        chunk.of("0x3", "FORGEDFN") ++
        // 번호 없는 표본은 남기지 않는다(닫힌 쪽).
        ",{\"name\":\"ProfileChunk\",\"ph\":\"P\",\"pid\":10,\"tid\":20,\"ts\":4400,\"args\":{\"data\":{\"cpuProfile\":{\"nodes\":[{\"callFrame\":{\"functionName\":\"NOIDFN\"}}]}}}}" ++
        // 스레드 풀의 백그라운드 파싱(스크립트 주소를 싣는다 — 프레임 칸 없음), 이름 모를 스레드 99.
        ",{\"name\":\"v8.parseOnBackground\",\"ph\":\"X\",\"pid\":10,\"tid\":21,\"ts\":4500,\"dur\":3,\"args\":{\"data\":{\"url\":\"http://u.test/BGSECRET.js\"}}}" ++
        ",{\"name\":\"v8.compile\",\"ph\":\"X\",\"pid\":10,\"tid\":99,\"ts\":4600,\"dur\":3,\"args\":{\"data\":{\"url\":\"http://u.test/UNKNOWNTHREAD.js\"}}}" ++
        // 컴포지터 스레드의 가족 layer tree 이벤트는 남는다.
        ",{\"name\":\"SetLayerTreeId\",\"cat\":\"devtools.timeline\",\"ph\":\"I\",\"pid\":10,\"tid\":11,\"ts\":3500,\"args\":{\"data\":{\"frame\":\"" ++ A ++ "\",\"layerTreeId\":1}}}" ++
        ",{\"name\":\"DrawFrame\",\"ph\":\"I\",\"pid\":10,\"tid\":12,\"ts\":4000,\"args\":{\"layerTreeId\":1}}";
    var r = try filterOf(gpa, fixtureFront(meta, extra), &set, .{});
    defer r.deinit();
    try testing.expectEqual(Outcome.kept, r.outcome);
    const json = try gunzip(gpa, r.gz);
    defer gpa.free(json);
    for ([_][]const u8{ "USERSECRETFN", "FORGEDFN", "NOIDFN", "BGSECRET", "UNKNOWNTHREAD", "DedicatedWorker thread", "ThreadPoolForegroundWorker" }) |needle| {
        if (std.mem.indexOf(u8, json, needle) != null) {
            std.debug.print("leaked {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "AGENTMAINFN", "\"Compositor\"", "v8:ProfEvntProc", "DrawFrame" }) |needle| try testing.expect(std.mem.indexOf(u8, json, needle) != null);
    try testing.expectEqual(@as(u32, 1), r.summary.frames);
    // 번호는 정수·10 진 글·`id2.local` 꼴도 같은 번호다.
    const forms = [_][]const u8{ "\"id\":1", "\"id\":\"1\"", "\"id2\":{\"local\":\"0x1\"}" };
    inline for (forms) |form| {
        const c2 = ",{\"name\":\"ProfileChunk\",\"ph\":\"P\",\"pid\":10,\"tid\":20,\"ts\":4300," ++ form ++ ",\"args\":{\"data\":{\"cpuProfile\":{\"nodes\":[{\"callFrame\":{\"functionName\":\"FORMFN\"}}]}}}}";
        var r2 = try filterOf(gpa, fixture(c2), &set, .{});
        defer r2.deinit();
        const j2 = try gunzip(gpa, r2.gz);
        defer gpa.free(j2);
        try testing.expect(std.mem.indexOf(u8, j2, "FORMFN") != null);
    }
}

test "W9e② N1: 남길 렌더러 프로세스의 워커가 가족 밖 프레임의 것이면 통째로 버린다, 가족의 워커·버리는 프로세스의 워커는 아니다" {
    const gpa = testing.allocator;
    var set = try familySet(gpa);
    defer set.deinit();
    const worker = struct {
        fn of(comptime pid: []const u8, comptime frame: []const u8) []const u8 {
            return ",{\"name\":\"TracingSessionIdForWorker\",\"cat\":\"disabled-by-default-devtools.timeline\",\"ph\":\"I\",\"pid\":" ++ pid ++ ",\"tid\":77,\"ts\":2200,\"args\":{\"data\":{\"frame\":\"" ++ frame ++ "\",\"url\":\"http://a.test/w.js\",\"workerThreadId\":77}}}";
        }
    };
    {
        var r = try filterOf(gpa, fixture(worker.of("10", U)), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.mixed_content, r.outcome);
        try testing.expectEqual(@as(usize, 0), r.gz.len);
        try testing.expectEqualStrings(U, r.foreign);
    }
    // 가족 프레임의 워커 — 버리지 않는다(그 워커 스레드는 F2 가 뺀다).
    {
        var r = try filterOf(gpa, fixture(worker.of("10", A2)), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
    }
    // 남기지 않는 렌더러(그 탭의 다른 사이트 iframe 프로세스 30)의 남의 워커는 폐기 사유가 아니다.
    {
        var r = try filterOf(gpa, fixture(worker.of("30", U)), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
    }
    // 페이지의 같은 이름 mark(범주 user timing)는 주 스레드를 워커로 만들어 지우지 못한다.
    {
        const fake = ",{\"name\":\"TracingSessionIdForWorker\",\"cat\":\"blink.user_timing\",\"ph\":\"R\",\"pid\":10,\"tid\":11,\"ts\":2200,\"args\":{\"data\":{\"workerThreadId\":11}}}";
        var r = try filterOf(gpa, fixture(fake), &set, .{});
        defer r.deinit();
        try testing.expectEqual(Outcome.kept, r.outcome);
        try testing.expectEqual(@as(u32, 1), r.summary.long_task_count);
    }
}
