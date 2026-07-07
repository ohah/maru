//! surface_move.zig — cross-window 이동 **원자 트랜잭션**(L2 순수, OS-중립). M3d-1 헤드리스 코어.
//! 단일 출처: docs/window-surface-mobility.md §8A.3(원자 트랜잭션)·§8A.5(trust boundary cap)·§8A.2(AppRuntime coordinator).
//!
//! §8A.3은 cross-window move를 AppRuntime가 **한 메인-스레드 트랜잭션**으로 원자 수행한다고 못박는다:
//!   ① 라이브 트리 수술(surface/pane/workspace 서브트리 재부모화)
//!   ② 그룹 정규화(workspace 이동일 때 — M3c `group_normalize`, `WindowGraph.moveWorkspace`가 이미 적용)
//!   ③ control-plane 구독 scope 재평가(`session.movedOut`/`movedIn` membership-changed notification 방출)
//!   ④ trust boundary cap 재평가(§8A.5 — surface-scope cap revoke, v1은 guard+hook)
//! + 빈 source window auto-close 판정(§8A.2)
//!
//! **이 모듈의 범위(M3d-1, 헤드리스)**: ①을 **순수 오라클 `WindowGraph`** 위에서 수행하고(§8A.6 — graph는 라이브
//! 미러가 아니라 순수 move 오라클 + 직렬화 포맷), ②~④ + 빈 창 판정을 **한 트랜잭션 함수**로 묶어 `MoveOutcome`으로
//! 돌려준다. ①의 **라이브 per-window 트리 수술**(두 `AppSession` 트리 재부모화 + 양-창 렌더 리프레시)과 그 Swift
//! NSWindow 생성/focus/close·command/드래그 **배선은 M3d-2**다(L4/platform — 이 L2 코어를 소비). 즉 이 파일은
//! §8A.2가 말한 "AppRuntime가 호출하는 L2 정책"이고, 라이브 핸들·창 수명은 만지지 않는다.
//!
//! **무재시작 불변식(§9)**: 이동은 `WindowGraph` 배치만 바꾸고 registry(런타임 소유)·routing(surface_id keyed)을
//! **전혀 안 건드린다**(surface_id 불변). 따라서 이동 전후 `LiveSurfaceRegistry.findBySurface`가 같은 포인터·같은
//! 스크롤백을 돌려주고 reader 재시작이 0이다 — 이 파일 테스트가 fake registry를 graph 옆에 들고 그 불변식을 못박는다.
//!
//! **원자성(§8A.3)**: "before" 읽기(순수) → `WindowGraph.move*`(fallible, append-before-remove라 OOM/InvalidCoordinate
//! 시 source 불변) → "after" 읽기(순수) → 정책(②~④, 할당 없는 순수 계산) 순서라, 트리 수술이 실패하면 outcome이
//! 만들어지지 않고(에러 전파) source가 그대로다. 정책 단계는 트리 수술 성공 후에만 돌아 "부분 재평가"가 없다.
//!
//! **스레드**: 메인 스레드 전용(window_graph.zig 계약과 동일 — 세션 트리는 메인 이벤트에서만 만진다).

const std = @import("std");
const window_graph = @import("window_graph.zig");
const window_membership = @import("window_membership.zig");
const control_plane = @import("control_plane.zig");

const WindowGraph = window_graph.WindowGraph;
const SurfaceAddr = window_graph.SurfaceAddr;
const PaneAddr = window_graph.PaneAddr;
const WorkspaceAddr = window_graph.WorkspaceAddr;
const WindowAddr = window_graph.WindowAddr;

pub const WindowKind = window_membership.WindowKind;
pub const MoveError = window_graph.MoveError;

// ── ③ 구독 재평가 이벤트 어휘(§8A.3 확정) ──────────────────────────────────────────────────────────────────
// [control-plane.md] §13 열린 질문이 §8A.3에서 확정됐다: window-scope 구독은 **유지**하고, 옮겨진 surface에 대해
// `session.movedOut`/`movedIn`(membership-changed) notification을 방출한다(`removed`/`closed` 아님 — surface는
// 살아 있다). M3d 착수 시 확정하기로 한 "정확한 event 이름"을 여기서 못박는다(§7 event 스키마 편입 지점).

/// 옮겨진 surface가 소스 창을 **떠남**을 소스-창 구독자에게 알린다(§8A.3). surface는 살아 있음(닫힘 아님).
pub const moved_out_method = "session.movedOut";
/// 옮겨진 surface가 목적지 창에 **합류**함을 목적지-창 구독자에게 알린다(§8A.3).
pub const moved_in_method = "session.movedIn";

pub const MovedDir = enum { out, in };

/// membership-changed notification 하나. `metadata:window` 구독자의 scope 재평가에 실린다(§6·§8A.3). surface_id는
/// 이동 중 불변이라(§6) selector는 그대로고, 이 이벤트는 "어느 창 membership이 바뀌었나"만 알린다.
pub const SurfaceMovedEvent = struct {
    surface_id: u64,
    from_window: u64,
    to_window: u64,
    dir: MovedDir,

    pub fn method(self: SurfaceMovedEvent) []const u8 {
        return switch (self.dir) {
            .out => moved_out_method,
            .in => moved_in_method,
        };
    }
};

// ── ④ trust boundary(§8A.5) ────────────────────────────────────────────────────────────────────────────────
// surface-scope cap(`read-output`/`write`)이 이동 중 generation 불변으로 유지되면 저신뢰 창에서 새어나간 nonce가
// 고신뢰 창으로 따라간다(§6). v1의 유일한 trust boundary는 `window_kind`(quick↔normal)인데 quick은 이동 단위·대상에서
// 제외(§4)라 **지원되는 v1 이동 중 이 경계를 넘는 경로는 없다**. 그래서 v1 산출물은 **guard + hook**이다: 이동
// 트랜잭션이 kind를 비교해 다르면 revoke를 트리거하되, UX로는 도달하지 않는다. quick→normal 추출이나 web trust-class
// 같은 미래 이동 단위가 생기면 이 훅이 이미 자리에 있다("이동이 이전에 새어나간 cap을 격리 못 한다"는 §6 한계는 유지).

/// source·dest 창이 trust boundary를 넘는가(§8A.5). v1 경계 = `window_kind` 차이(normal↔quick).
pub fn crossesTrustBoundary(src_kind: WindowKind, dst_kind: WindowKind) bool {
    return src_kind != dst_kind;
}

// ── 트랜잭션 결과 ────────────────────────────────────────────────────────────────────────────────────────────

/// cross-window move 원자 트랜잭션의 결과(§8A.3 ②~④ + 빈 창). 라이브 배선(M3d-2)이 이걸 받아 구독 이벤트 방출·cap
/// revoke·source 창 close를 수행한다 — 이 L2 코어는 **판정만** 하고 핸들·창 수명은 안 만진다(§8A.2 레이어 규율).
pub const MoveOutcome = struct {
    /// 이동된 surface_id들(순서 보존, caller 버퍼 slice). ③ 구독 재평가·④ cap 재평가 대상. **cross_window일 때만**
    /// 의미가 있다(같은 창 내부 이동은 membership 불변이라 이벤트/revoke 없음).
    moved_surfaces: []const u64,
    /// 소스 창의 위치 메타데이터(opaque window_id, 라우팅 키 아님 — §1). ③ movedOut 이벤트의 from.
    from_window: u64,
    /// 목적지 창의 window_id. ③ movedIn 이벤트의 to.
    to_window: u64,
    /// from != to(창 간 이동). false면 같은 창 내부 이동(pane/workspace reorder)이라 membership 불변 → 이벤트·revoke 없음.
    cross_window: bool,
    /// ④ trust boundary(§8A.5) 교차 → 옮겨진 surface들의 surface-scope cap을 revoke해야 하는가. v1은 도달 불가(quick 제외).
    revoke_caps: bool,
    /// §8A.2 빈 source auto-close: 이동 후 소스 창이 비어(모든 workspace가 빠져) 닫아야 하는가. 라이브 배선(M3d-2)이
    /// 이 신호를 받아 Swift NSWindow를 닫는다 — 판정은 Zig(여기), 실제 close는 platform(§1 native drag 정책 분리).
    source_window_closed: bool,
};

// ── ① 트리 수술 + ②~④ 정책을 묶는 원자 트랜잭션(순수 오라클 위) ──────────────────────────────────────────────
// 각 함수: (a) before 읽기(순수, source 서브트리의 moved surface_id + from/to window_id·kind + source Window 포인터),
// (b) `WindowGraph.move*`(fallible — 실패 시 source 불변, outcome 없음), (c) after 읽기(source Window가 prune됐나),
// (d) 정책 계산(cross_window·revoke·source_closed). moved surface_id는 `out_ids`에 채우고 그 slice를 outcome에 싣는다.

/// surface를 pane 간 이동(§8A.3). `out_ids`는 최소 1칸. dst가 다른 창이면 cross_window 트랜잭션(구독 재평가·cap 재평가).
pub fn moveSurface(graph: *WindowGraph, src: SurfaceAddr, dst: PaneAddr, out_ids: []u64) MoveError!MoveOutcome {
    const before = try readSurfaceBefore(graph, src, dst, out_ids);
    try graph.moveSurface(src, dst);
    return finishOutcome(graph, before);
}

/// pane을 workspace 간(같은/다른 창) 이동(§8A.3). pane 안 모든 surface가 이동 대상(구독/cap 재평가).
pub fn movePane(graph: *WindowGraph, src: PaneAddr, dst: WorkspaceAddr, out_ids: []u64) MoveError!MoveOutcome {
    const dst_win: WindowAddr = dst.win;
    const before = try readPaneBefore(graph, src, dst_win, out_ids);
    try graph.movePane(src, dst);
    return finishOutcome(graph, before);
}

/// workspace를 window 간 이동(§8A.3). workspace 안 모든 surface가 이동 대상. `WindowGraph.moveWorkspace`가 M3c 그룹
/// 정규화(② — 마커 승계·핀 재정규화·(d) top_level)를 이미 적용하므로 이 트랜잭션은 그 위에 ③④를 얹기만 한다.
pub fn moveWorkspace(graph: *WindowGraph, src: WorkspaceAddr, dst_win: WindowAddr, out_ids: []u64) MoveError!MoveOutcome {
    const before = try readWorkspaceBefore(graph, src, dst_win, out_ids);
    try graph.moveWorkspace(src, dst_win);
    return finishOutcome(graph, before);
}

/// source window의 workspace를 **전부** target으로 옮기고 빈 source를 닫는 bulk merge(§1·§4). source의 모든 surface가
/// 이동 대상. source는 항상 닫히므로(§8A.3) source_window_closed=true.
pub fn mergeWindow(graph: *WindowGraph, src_win: WindowAddr, dst_win: WindowAddr, out_ids: []u64) MoveError!MoveOutcome {
    const before = try readWindowBefore(graph, src_win, dst_win, out_ids);
    try graph.mergeWindow(src_win, dst_win);
    return finishOutcome(graph, before);
}

// ── ③ 이벤트 방출(순수) ──────────────────────────────────────────────────────────────────────────────────────

/// 트랜잭션 결과에서 membership-changed notification들을 `out`에 채워 slice 반환(할당 없음). cross_window일 때만 방출하고
/// (같은 창 이동은 membership 불변), 옮겨진 surface마다 movedOut + movedIn **두 개**를 낸다(소스-창·목적지-창 구독자용,
/// §8A.3). `out`이 모자라면 앞에서부터 잘라 채운다(window_membership.collectVisibleSurfaces와 같은 조용한 절단 계약).
pub fn membershipChangeEvents(outcome: MoveOutcome, out: []SurfaceMovedEvent) []SurfaceMovedEvent {
    if (!outcome.cross_window) return out[0..0];
    var n: usize = 0;
    for (outcome.moved_surfaces) |sid| {
        if (n >= out.len) break;
        out[n] = .{ .surface_id = sid, .from_window = outcome.from_window, .to_window = outcome.to_window, .dir = .out };
        n += 1;
        if (n >= out.len) break;
        out[n] = .{ .surface_id = sid, .from_window = outcome.from_window, .to_window = outcome.to_window, .dir = .in };
        n += 1;
    }
    return out[0..n];
}

/// membership-changed notification 하나를 JSON-RPC notification 바이트로 직렬화한다(§8A.3 어휘 확정). caller가 free.
/// `{"jsonrpc":"2.0","method":"session.movedOut|movedIn","params":{"surface_id":N,"from_window":F,"to_window":T}}`.
/// control_plane notification 모양(§1)을 그대로 따른다 — Phase 1 dispatcher가 이 프레임을 window-scope 구독자에게 흘린다.
pub fn serializeMovedEvent(gpa: std.mem.Allocator, evt: SurfaceMovedEvent) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeMovedEvent(&s, evt) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeMovedEvent(s: *std.json.Stringify, evt: SurfaceMovedEvent) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(control_plane.jsonrpc_version);
    try s.objectField("method");
    try s.write(evt.method());
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("surface_id");
    try s.write(evt.surface_id);
    try s.objectField("from_window");
    try s.write(evt.from_window);
    try s.objectField("to_window");
    try s.write(evt.to_window);
    try s.endObject();
    try s.endObject();
}

// ── 내부: before 읽기(순수, bounds 검사 = WindowGraph.move*와 같은 InvalidCoordinate 계약) ──────────────────────

/// before 스냅샷(트리 수술 전에 읽어 두는 값). from/to window_id·kind는 window_id가 opaque·안정이라 prune으로 인덱스가
/// 밀려도 이벤트 상관키로 안전하다. `src_window`는 이동 후 그 창이 prune됐는지 포인터로 판정하는 데 쓴다.
const Before = struct {
    moved: []const u64,
    from_window: u64,
    from_kind: WindowKind,
    to_window: u64,
    to_kind: WindowKind,
    /// 소스 window 포인터(prune 판정용). null이면 source==dest 같은 창이라 prune 대상 아님(no-op 안전).
    src_window: ?*window_graph.Window,
};

fn windowPtrAt(graph: *WindowGraph, i: usize) MoveError!*window_graph.Window {
    if (i >= graph.windows.items.len) return error.InvalidCoordinate;
    return graph.windows.items[i];
}

/// `Before` 조립 공통 tail(code-review [7]) — 4개 read*Before가 각자 bounds 검사·moved 수집 뒤 이 헬퍼로 동일한
/// from/to window_id·kind + prune 판정용 src_window(같은 창이면 null=no-op 안전)을 채운다(반복 리터럴 제거).
fn makeBefore(moved: []const u64, src_win: *window_graph.Window, dst_win: *window_graph.Window, same_window: bool) Before {
    return .{
        .moved = moved,
        .from_window = src_win.window_id,
        .from_kind = src_win.kind,
        .to_window = dst_win.window_id,
        .to_kind = dst_win.kind,
        .src_window = if (same_window) null else src_win,
    };
}

fn readSurfaceBefore(graph: *WindowGraph, src: SurfaceAddr, dst: PaneAddr, out_ids: []u64) MoveError!Before {
    const src_win = try windowPtrAt(graph, src.win);
    if (src.ws >= src_win.workspaces.items.len) return error.InvalidCoordinate;
    const ws = src_win.workspaces.items[src.ws];
    if (src.pane >= ws.panes.items.len) return error.InvalidCoordinate;
    const pane = ws.panes.items[src.pane];
    if (src.surface >= pane.surfaces.items.len) return error.InvalidCoordinate;
    const dst_win = try windowPtrAt(graph, dst.win);

    var n: usize = 0;
    if (out_ids.len > 0) {
        out_ids[0] = pane.surfaces.items[src.surface].surface_id;
        n = 1;
    }
    return makeBefore(out_ids[0..n], src_win, dst_win, src.win == dst.win);
}

fn readPaneBefore(graph: *WindowGraph, src: PaneAddr, dst_win_idx: WindowAddr, out_ids: []u64) MoveError!Before {
    const src_win = try windowPtrAt(graph, src.win);
    if (src.ws >= src_win.workspaces.items.len) return error.InvalidCoordinate;
    const ws = src_win.workspaces.items[src.ws];
    if (src.pane >= ws.panes.items.len) return error.InvalidCoordinate;
    const pane = ws.panes.items[src.pane];
    const dst_win = try windowPtrAt(graph, dst_win_idx);

    const moved = collectPaneSurfaces(pane, out_ids);
    return makeBefore(moved, src_win, dst_win, src.win == dst_win_idx);
}

fn readWorkspaceBefore(graph: *WindowGraph, src: WorkspaceAddr, dst_win_idx: WindowAddr, out_ids: []u64) MoveError!Before {
    const src_win = try windowPtrAt(graph, src.win);
    if (src.ws >= src_win.workspaces.items.len) return error.InvalidCoordinate;
    const ws = src_win.workspaces.items[src.ws];
    const dst_win = try windowPtrAt(graph, dst_win_idx);

    const moved = collectWorkspaceSurfaces(ws, out_ids);
    return makeBefore(moved, src_win, dst_win, src.win == dst_win_idx);
}

fn readWindowBefore(graph: *WindowGraph, src_win_idx: WindowAddr, dst_win_idx: WindowAddr, out_ids: []u64) MoveError!Before {
    const src_win = try windowPtrAt(graph, src_win_idx);
    const dst_win = try windowPtrAt(graph, dst_win_idx);

    var n: usize = 0;
    for (src_win.workspaces.items) |ws| n = appendWorkspaceSurfaces(ws, out_ids, n);
    return makeBefore(out_ids[0..n], src_win, dst_win, src_win_idx == dst_win_idx);
}

/// `appendPaneSurfaces`를 start=0으로 감싼 편의 — pane 안 surface_id를 `out`에 채워 slice 반환(재구현 아님, code-review [8]).
fn collectPaneSurfaces(pane: *window_graph.Pane, out: []u64) []const u64 {
    return out[0..appendPaneSurfaces(pane, out, 0)];
}

/// `appendWorkspaceSurfaces`를 start=0으로 감싼 편의 — workspace 안 모든 surface_id를 slice로(재구현 아님, code-review [8]).
fn collectWorkspaceSurfaces(ws: *window_graph.Workspace, out: []u64) []const u64 {
    return out[0..appendWorkspaceSurfaces(ws, out, 0)];
}

fn appendPaneSurfaces(pane: *window_graph.Pane, out: []u64, start: usize) usize {
    var n = start;
    for (pane.surfaces.items) |ref| {
        if (n >= out.len) break;
        out[n] = ref.surface_id;
        n += 1;
    }
    return n;
}

fn appendWorkspaceSurfaces(ws: *window_graph.Workspace, out: []u64, start: usize) usize {
    var n = start;
    for (ws.panes.items) |pane| n = appendPaneSurfaces(pane, out, n);
    return n;
}

/// after 읽기(트리 수술 성공 후) + 정책(②~④) 계산. cross_window = from != to window_id. source_window_closed =
/// 소스 창이 이동 후 graph에서 사라졌나(포인터 membership). revoke = cross_window && trust boundary 교차(§8A.5).
fn finishOutcome(graph: *WindowGraph, before: Before) MoveOutcome {
    const cross_window = before.from_window != before.to_window;
    const source_closed = if (before.src_window) |sw| !windowStillPresent(graph, sw) else false;
    return .{
        .moved_surfaces = before.moved,
        .from_window = before.from_window,
        .to_window = before.to_window,
        .cross_window = cross_window,
        .revoke_caps = cross_window and crossesTrustBoundary(before.from_kind, before.to_kind),
        .source_window_closed = source_closed,
    };
}

fn windowStillPresent(graph: *WindowGraph, win: *window_graph.Window) bool {
    for (graph.windows.items) |w| {
        if (w == win) return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════════════
//   테스트 — 헤드리스. 순수 오라클(WindowGraph) + fake registry로 무재시작·트리 정합·빈 창·그룹 정규화·구독 이벤트·
//   trust cap·원자성을 못박는다. 실제 PTY/Swift 없음(§8A.3 헤드리스 코어).
// ══════════════════════════════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const live_surface_registry = @import("live_surface_registry.zig");

/// 무재시작 불변식 증명용 fake surface 런타임(M2a `FakeRuntime`와 동형 — registry가 소유·수명 관리). `pty_id`=identity,
/// `scrollback`=TerminalCore 상태(이동이 보존해야 함), `inits`=제자리 init 횟수(정상=1, 재시작=별 인스턴스).
const FakeRt = struct {
    allocator: std.mem.Allocator = undefined,
    pty_id: u64 = 0,
    scrollback: std.ArrayList([]const u8) = .empty,
    inits: u32 = 0,

    fn init(self: *FakeRt, allocator: std.mem.Allocator, pty_id: u64) void {
        self.* = .{ .allocator = allocator, .pty_id = pty_id, .inits = 1 };
    }
    fn push(self: *FakeRt, line: []const u8) !void {
        try self.scrollback.append(self.allocator, line);
    }
    /// pub: LiveSurfaceRegistry(FakeRt) generic이 타 모듈(live_surface_registry.zig)에서 `entry.runtime.deinit()`로 부른다.
    pub fn deinit(self: *FakeRt) void {
        self.scrollback.deinit(self.allocator);
        self.* = undefined;
    }
};

const FakeRegistry = live_surface_registry.LiveSurfaceRegistry(FakeRt);

fn spawn(reg: *FakeRegistry, allocator: std.mem.Allocator, surface_id: u64, pty_id: u64) !*FakeRt {
    const rt = try reg.create(surface_id, 0);
    rt.init(allocator, pty_id);
    return rt;
}

test "moveSurface cross-window: outcome(cross_window·from/to·revoke 없음·source 유지) + 무재시작 불변식" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    var reg = FakeRegistry.init(allocator);
    defer reg.deinit();

    // window0(id=11)={S500(이동), S501(resident)}, window1(id=22)=빈 pane. registry는 500의 런타임(포인터 P, 스크롤백 2줄)만.
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    _ = try g.addPane(ws1);
    try g.addSurface(p0, 500);
    try g.addSurface(p0, 501);
    const p_before = try spawn(&reg, allocator, 500, 500);
    try p_before.push("history 1");
    try p_before.push("history 2");

    var buf: [4]u64 = undefined;
    const outcome = try moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 }, &buf);

    // 트랜잭션 outcome: 창 간 이동(11→22), moved={500}, trust 경계 안 넘음(normal↔normal)이라 revoke 없음, source 유지(501 잔존).
    try testing.expect(outcome.cross_window);
    try testing.expectEqual(@as(u64, 11), outcome.from_window);
    try testing.expectEqual(@as(u64, 22), outcome.to_window);
    try testing.expectEqualSlices(u64, &.{500}, outcome.moved_surfaces);
    try testing.expect(!outcome.revoke_caps);
    try testing.expect(!outcome.source_window_closed);

    // 무재시작(§9): registry는 안 건드렸으니 같은 포인터·같은 스크롤백·inits==1(재시작 0). 이게 이동의 핵심 계약이다.
    const p_after = reg.findBySurface(500).?;
    try testing.expectEqual(p_before, p_after);
    try testing.expectEqual(@as(u32, 1), p_after.inits);
    try testing.expectEqual(@as(usize, 2), p_after.scrollback.items.len);
    try testing.expectEqualStrings("history 1", p_after.scrollback.items[0]);

    // 배치는 진짜 옮겨졌다(비-vacuous): window0={501}, window1={500}.
    var b0: [4]u64 = undefined;
    var b1: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{501}, try g.collectWindowSurfaceIds(0, &b0));
    try testing.expectEqualSlices(u64, &.{500}, try g.collectWindowSurfaceIds(1, &b1));
}

test "moveSurface cross-window: membershipChangeEvents가 movedOut+movedIn을 방출(이름·from/to 확정)" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    _ = try g.addPane(ws1);
    try g.addSurface(p0, 500);
    try g.addSurface(p0, 501); // resident — source 창 유지

    var buf: [4]u64 = undefined;
    const outcome = try moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 }, &buf);

    var evbuf: [4]SurfaceMovedEvent = undefined;
    const events = membershipChangeEvents(outcome, &evbuf);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(MovedDir.out, events[0].dir);
    try testing.expectEqualStrings("session.movedOut", events[0].method());
    try testing.expectEqual(@as(u64, 500), events[0].surface_id);
    try testing.expectEqual(@as(u64, 11), events[0].from_window);
    try testing.expectEqual(@as(u64, 22), events[0].to_window);
    try testing.expectEqual(MovedDir.in, events[1].dir);
    try testing.expectEqualStrings("session.movedIn", events[1].method());
    try testing.expectEqual(@as(u64, 500), events[1].surface_id);
}

test "moveSurface 같은 창 내부 이동(pane→pane): membership 불변 → 이벤트 없음·revoke 없음" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w0 = try g.addWindow(11, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws0);
    try g.addSurface(p0, 500);
    try g.addSurface(p0, 501); // p0 resident로 남겨 pane prune 안 되게
    try g.addSurface(p1, 600);

    var buf: [4]u64 = undefined;
    const outcome = try moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 0, .ws = 0, .pane = 1 }, &buf);

    try testing.expect(!outcome.cross_window); // 같은 창(11→11)
    try testing.expect(!outcome.revoke_caps);
    try testing.expect(!outcome.source_window_closed);
    var evbuf: [4]SurfaceMovedEvent = undefined;
    try testing.expectEqual(@as(usize, 0), membershipChangeEvents(outcome, &evbuf).len); // 같은 창 → 이벤트 없음
}

test "moveSurface full cascade: source 창의 마지막 surface가 빠지면 source_window_closed(§8A.2 빈 창 auto-close)" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    // window0 = 단일 ws/pane/surface(700). window1 = 수신처.
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    _ = try g.addPane(ws1);
    try g.addSurface(p0, 700); // window0의 유일 surface

    var buf: [4]u64 = undefined;
    const outcome = try moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 }, &buf);

    // window0가 pane→ws→window 연쇄로 비어 사라짐 → source_window_closed=true(라이브 배선이 Swift close 신호로 소비).
    try testing.expect(outcome.cross_window);
    try testing.expect(outcome.source_window_closed);
    try testing.expectEqual(@as(usize, 1), g.windows.items.len); // window0 닫힘 — graph에 window1만
    try testing.expectEqual(w1, g.windows.items[0]);
}

test "movePane cross-window: pane 안 모든 surface가 이동 대상 + outcome" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const pa = try g.addPane(ws0); // 이동 대상 pane(가로 탭 2개)
    const pb = try g.addPane(ws0); // resident — source ws/window 유지
    try g.addSurface(pa, 800);
    try g.addSurface(pa, 801);
    try g.addSurface(pb, 900);
    const ws1p = try g.addPane(ws1);
    try g.addSurface(ws1p, 950);

    var buf: [8]u64 = undefined;
    const outcome = try movePane(&g, .{ .win = 0, .ws = 0, .pane = 0 }, .{ .win = 1, .ws = 0 }, &buf);

    try testing.expect(outcome.cross_window);
    try testing.expectEqualSlices(u64, &.{ 800, 801 }, outcome.moved_surfaces); // pane 안 두 surface 모두
    try testing.expect(!outcome.source_window_closed); // pb·900 잔존
    var evbuf: [8]SurfaceMovedEvent = undefined;
    try testing.expectEqual(@as(usize, 4), membershipChangeEvents(outcome, &evbuf).len); // 2 surface × (out+in)
}

test "moveWorkspace cross-window: workspace 안 모든 surface 이동 + M3c 그룹 정규화 적용(§8A.4)" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    // source: 고정 그룹 [marker(pin), member(pin)] — member를 옮긴다(§4 (d) 이탈 정규화).
    const marker = try g.addWorkspace(w0, .{ .group_start = "g", .pinned = true });
    const mp = try g.addPane(marker);
    try g.addSurface(mp, 100);
    const member = try g.addWorkspace(w0, .{ .pinned = true, .local_pinned = true });
    const memp = try g.addPane(member);
    try g.addSurface(memp, 200);
    try g.addSurface(memp, 201); // 이 pane에 surface 2개(모두 이동)
    const dst_ws = try g.addWorkspace(w1, .{});
    _ = try g.addPane(dst_ws);

    var buf: [8]u64 = undefined;
    const outcome = try moveWorkspace(&g, .{ .win = 0, .ws = 1 }, 1, &buf);

    // 이동 대상 surface = member workspace의 모든 surface.
    try testing.expectEqualSlices(u64, &.{ 200, 201 }, outcome.moved_surfaces);
    try testing.expect(outcome.cross_window);
    try testing.expect(!outcome.source_window_closed); // marker workspace 잔존

    // §8A.4 (d): 이동분 member는 목적지에서 top_level 명시 set·그룹 멤버 이탈 unpin·local_pin 리셋(M3c가 moveWorkspace 안에서 적용).
    try testing.expect(member.meta.top_level);
    try testing.expect(!member.meta.pinned);
    try testing.expect(!member.meta.local_pinned);
    try testing.expect(member.meta.group_start == null);
}

test "mergeWindow: source 전부 이동 + source_window_closed(항상) + 모든 surface 이동 대상" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w0 = try g.addWindow(11, .normal); // target
    const w1 = try g.addWindow(22, .normal); // source(닫힐 것)
    const t0 = try g.addWorkspace(w0, .{});
    const t0p = try g.addPane(t0);
    try g.addSurface(t0p, 100);
    const s0 = try g.addWorkspace(w1, .{});
    const s0p = try g.addPane(s0);
    try g.addSurface(s0p, 200);
    const s1 = try g.addWorkspace(w1, .{});
    const s1p = try g.addPane(s1);
    try g.addSurface(s1p, 300);

    var buf: [8]u64 = undefined;
    const outcome = try mergeWindow(&g, 1, 0, &buf);

    try testing.expect(outcome.cross_window);
    try testing.expect(outcome.source_window_closed); // merge는 source를 항상 닫는다
    try testing.expectEqualSlices(u64, &.{ 200, 300 }, outcome.moved_surfaces); // source의 모든 surface
    try testing.expectEqual(@as(usize, 1), g.windows.items.len); // source 닫힘
}

test "trust boundary(§8A.5): quick↔normal 교차 이동은 revoke_caps=true(guard+hook), normal↔normal은 false" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    // window0=normal(id=11), window1=quick(id=99). normal→quick surface 이동(가상 — v1 UX 도달 불가지만 훅 검증).
    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(99, .quick);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    _ = try g.addPane(ws1);
    try g.addSurface(p0, 500);
    try g.addSurface(p0, 501); // resident

    var buf: [4]u64 = undefined;
    const outcome = try moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 }, &buf);
    try testing.expect(outcome.revoke_caps); // trust boundary(normal↔quick) 교차 → surface-scope cap revoke 신호

    // 순수 술어 직접 검증.
    try testing.expect(crossesTrustBoundary(.normal, .quick));
    try testing.expect(crossesTrustBoundary(.quick, .normal));
    try testing.expect(!crossesTrustBoundary(.normal, .normal));
    try testing.expect(!crossesTrustBoundary(.quick, .quick));
}

test "원자성(§8A.3): 트리 수술 OOM이면 outcome이 안 만들어지고 source 불변(무재시작 유지)" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    var reg = FakeRegistry.init(allocator);
    defer reg.deinit();

    const w0 = try g.addWindow(11, .normal);
    const w1 = try g.addWindow(22, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    _ = try g.addPane(ws1); // window1의 빈 dst pane — 첫 append가 반드시 alloc
    try g.addSurface(p0, 500);
    try g.addSurface(p0, 501);
    const rt = try spawn(&reg, allocator, 500, 500);
    try rt.push("intact");

    // cross-window 이동의 dst append(fallible)를 OOM으로 실패시킨다 → moveSurface가 error.OutOfMemory, source 불변.
    var fail = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    g.allocator = fail.allocator();
    var buf: [4]u64 = undefined;
    try testing.expectError(error.OutOfMemory, moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 }, &buf));
    g.allocator = allocator; // deinit 복구

    // source 불변: p0에 {500,501} 그대로, registry 런타임·스크롤백 그대로(재시작 0). outcome은 만들어지지 않았다.
    var b0: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 500, 501 }, try g.collectWindowSurfaceIds(0, &b0));
    try testing.expectEqual(rt, reg.findBySurface(500).?);
    try testing.expectEqual(@as(u32, 1), reg.findBySurface(500).?.inits);
    try testing.expectEqualStrings("intact", reg.findBySurface(500).?.scrollback.items[0]);
}

test "InvalidCoordinate: 범위 밖 좌표는 트리 수술 전에 조용한 실패로 걸린다(source 불변)" {
    const allocator = testing.allocator;
    var g = WindowGraph.init(allocator);
    defer g.deinit();
    const w = try g.addWindow(11, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p = try g.addPane(ws);
    try g.addSurface(p, 100);

    var buf: [4]u64 = undefined;
    try testing.expectError(error.InvalidCoordinate, moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 5 }, .{ .win = 0, .ws = 0, .pane = 0 }, &buf));
    try testing.expectError(error.InvalidCoordinate, moveSurface(&g, .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 9, .ws = 0, .pane = 0 }, &buf));
    try testing.expectError(error.InvalidCoordinate, movePane(&g, .{ .win = 0, .ws = 0, .pane = 3 }, .{ .win = 0, .ws = 0 }, &buf));
    try testing.expectError(error.InvalidCoordinate, moveWorkspace(&g, .{ .win = 0, .ws = 7 }, 0, &buf));
    try testing.expectError(error.InvalidCoordinate, mergeWindow(&g, 0, 8, &buf));
    // 실패 후 구조 온전.
    try testing.expectEqual(@as(usize, 1), w.workspaces.items.len);
    try testing.expectEqual(@as(usize, 1), p.surfaces.items.len);
}

test "serializeMovedEvent: control_plane notification으로 직렬화되고 parse 왕복(이름·params 확정)" {
    const allocator = testing.allocator;
    const evt = SurfaceMovedEvent{ .surface_id = 500, .from_window = 11, .to_window = 22, .dir = .out };
    const bytes = try serializeMovedEvent(allocator, evt);
    defer allocator.free(bytes);

    // control_plane parser로 되읽으면 notification(id 없음) + method + params 정합.
    const pm = try control_plane.parseMessage(allocator, bytes);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    try testing.expectEqualStrings("session.movedOut", pm.message.notification.method);
    const params = pm.message.notification.params.?.object;
    try testing.expectEqual(@as(i64, 500), params.get("surface_id").?.integer);
    try testing.expectEqual(@as(i64, 11), params.get("from_window").?.integer);
    try testing.expectEqual(@as(i64, 22), params.get("to_window").?.integer);

    // movedIn도 이름이 확정된다.
    const evt_in = SurfaceMovedEvent{ .surface_id = 500, .from_window = 11, .to_window = 22, .dir = .in };
    const bytes_in = try serializeMovedEvent(allocator, evt_in);
    defer allocator.free(bytes_in);
    const pm_in = try control_plane.parseMessage(allocator, bytes_in);
    defer pm_in.deinit();
    try testing.expectEqualStrings("session.movedIn", pm_in.message.notification.method);
}

test "membershipChangeEvents: out 버퍼 절단(모자란 버퍼)은 앞에서부터 조용히 채운다" {
    const outcome = MoveOutcome{
        .moved_surfaces = &.{ 1, 2, 3 },
        .from_window = 11,
        .to_window = 22,
        .cross_window = true,
        .revoke_caps = false,
        .source_window_closed = false,
    };
    var small: [3]SurfaceMovedEvent = undefined; // 3칸 = surface 1.5개분(out,in,out) — 절단
    const events = membershipChangeEvents(outcome, &small);
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(@as(u64, 1), events[0].surface_id);
    try testing.expectEqual(MovedDir.out, events[0].dir);
    try testing.expectEqual(MovedDir.in, events[1].dir);
    try testing.expectEqual(@as(u64, 2), events[2].surface_id); // 두 번째 surface의 out까지만
    try testing.expectEqual(MovedDir.out, events[2].dir);
}
