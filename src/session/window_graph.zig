//! WindowGraph — window→workspace→pane→surface_ref 배치의 **순수 모델**과 move/merge 연산 (L2 순수, OS-중립).
//! M1(docs/window-surface-mobility.md §3·§4·§8, docs/control-plane.md §3).
//!
//! `WindowGraph`는 "어떤 window/workspace/pane 위치에 어떤 surface_ref가 보이는지"의 순수 모델이다
//! (docs/window-surface-mobility.md §3). live surface(PTY reader/TerminalCore/WKWebView 핸들)는 **소유하지 않는다**
//! — 그 소유는 M2 `LiveSurfaceRegistry`(L4 platform)이고, 이 그래프는 surface_id 값과 트리 구조만 든다. AppRuntime
//! (L4)이 이 순수 graph와 live registry를 함께 갱신하는 단일 정책 소유자다(§3). 즉 이 파일은 트리 재배치·focus 보정
//! **정책 판정**만 하고, 실제 핸들 이동·창 생성/닫기는 platform이 이 graph diff를 받아 수행한다.
//!
//! **범위(M1, 딱 이것만)**: 순수 노드 + `moveSurface`/`movePane`/`moveWorkspace`/`mergeWindow` + no-op 가드 +
//! empty-source 정리 + focus/active 보정. 실제 live surface 이동(재시작 없음 증명)은 M2, Swift drag/ABI는 M4~M6,
//! 그룹 정규화(마커 승계·핀 리전 재정규화)는 **M3**이다. M1은 **group-agnostic 골격**이라 workspace의 그룹 필드
//! (`group_start`·`top_level`·`local_pinned`·`pinned`)를 **pass-through로 보존만** 하고 정규화하지 않는다 — 정규화
//! 권위는 L4 `app_session`의 `inheritGroupMarker`/`normalizePinnedFromGroups`이고, 그 L2 리프트 여부는 M3이 실제
//! 그룹 workspace를 옮길 때 결정한다(L2 조기 재구현은 L4와 발산 → docs/window-surface-mobility.md §8 M1).
//! generation도 M0a/M0b와 동일하게 M1 범위 밖 — surface_ref는 surface_id만 든다(런타임 respawn 경로는 M2에서 모델).
//!
//! **베이스·설계 결정**(docs/document-basis-and-decision 규칙):
//! - **노드 표현 = 자체 경량 순수 노드(id·구조 참조), session_model.Tab/Pane/Term을 참조하지 않는다.** 이유:
//!   session_model.Model(Rt)는 런타임 `Rt`(PTY 결합)·`Surface`(그리드/스크롤백)·split 레이아웃 트리를 들어 무겁고
//!   런타임 수명(M2)과 얽힌다. §3이 요구하는 건 "surface_ref 배치의 순수 모델"이라, surface_id를 든 leaf + 순번
//!   컨테이너로 충분하다. platform이 M2/M3에서 이 graph를 라이브 모델과 배선한다.
//! - **containment(순번 리스트) 모델, split 기하 트리는 M1 범위 밖.** window→workspace 리스트, workspace→pane
//!   리스트, pane→surface 리스트로 각 층을 순번 컨테이너로 둔다. §3은 최종 형태를 "pane tree"라 부르지만 M1은
//!   골격(§8)이라, move/merge가 필요로 하는 **소속 재배치**만 담고 split 레이아웃(방향·ratio 기하)은
//!   session_model.PaneTree가 계속 소유한다(L2에 split-tree 수술을 재구현하면 split_tree.zig와 발산 — 그룹 정규화를
//!   defer한 것과 같은 결). AppRuntime이 M2/M3에서 기하 트리를 라이브 모델 쪽에 유지한다.
//! - **노드는 heap 할당 + 부모 리스트에 pointer 저장**(session_model.Tab/Pane, app/live_pty_registry 선례). 포인터
//!   식별이 안정적이라 move=포인터 재배치(내용 deep-copy 없음)이고, 리스트 재배열이 다른 노드를 무효화하지 않는다.
//! - **focus 규칙(M1, 로컬 최소)**: (1) 이동한 요소는 **직속 목적지 부모**에서 active가 된다(surface→dst pane
//!   .active_surface, pane→dst workspace.active_pane, workspace→dst window.active_workspace). (2) 조상 active는
//!   source-쪽 empty 정리로 컨테이너가 구조 변경될 때만 removal-clamp로 보정한다. (3) **window 층 예외**: source
//!   window가 비어 제거될 때(moveWorkspace 마지막 이탈·mergeWindow) `active_window`가 그 창을 가리켰으면 **목적지
//!   window로 따라간다**(§8이 merge에 명시한 "active window 보정"). (4) 이동이 OS 초점까지 목적지로 올릴지(전체
//!   viewport focus)는 M3 command 배선·M4~M5 drag의 UX 정책이지 M1 순수 모델에 넣지 않는다.
//! - **스레드**: 메인 스레드 전용(surface_id.zig 계약과 동일 — 세션 트리는 메인 이벤트에서만 만진다). L2 순수라
//!   런타임 assert 대신 주석으로 고정한다.

const std = @import("std");
const window_membership = @import("window_membership.zig");

/// window 분류자 — M0b가 도입한 중립 enum을 재사용한다(normal/quick). 값에 라우팅 의미 없음(분류만).
pub const WindowKind = window_membership.WindowKind;

/// surface leaf. M1은 surface_id만 든다(generation은 M2 런타임 수명에서 — 위 주석). live 핸들은 M2 registry 소유.
pub const SurfaceRef = struct {
    surface_id: u64,
};

/// pane = surface_ref들의 순번 묶음(+active). session_model.Pane의 Term 가로 탭에 대응하지만 런타임 없이 id만.
pub const Pane = struct {
    /// 이 pane 안 surface_ref들(순서 보존). WindowGraph가 소유(heap Pane의 필드) — leaf라 값 저장.
    surfaces: std.ArrayList(SurfaceRef) = .empty,
    /// 활성(보이는) surface 인덱스. surfaces가 비면 무의미(그 pane은 empty-정리로 제거된다).
    active_surface: usize = 0,
};

/// workspace의 그룹 메타데이터(pass-through 보존 전용). **M1은 이 값을 정규화하지 않고 이동 시 그대로 실어 나른다**
/// (docs/window-surface-mobility.md §4·§8 M1). session_model.Tab의 그룹 필드 중 §4가 이동 케이스로 지목한 것만 든다.
/// 문자열(group_start)은 **borrowed**다 — graph는 소유하지 않는다(WindowMembershipSnapshot.surface_ids와 같은 계약,
/// 소유는 collector/라이브 모델). 정규화(마커 승계·핀 리전 재정규화)는 M3이 L4 `inheritGroupMarker` 기준으로 한다.
pub const WorkspaceMeta = struct {
    /// 사이드바 그룹 **시작 마커**(위치 파생 소속 — docs/sidebar-groups.md §2.1). null=마커 아님. borrowed.
    group_start: ?[]const u8 = null,
    /// 전역 위치 고정(핀 프리픽스, §12). pass-through — target 핀 리전 정규화는 M3.
    pinned: bool = false,
    /// 그룹-로컬 pin(GL, §13). 이탈 시 의미를 잃어 M3이 리셋하지만, M1 골격은 보존만 한다.
    local_pinned: bool = false,
    /// 서브파티션 top-level 복귀 마커(§14). 이탈 시 의미를 잃어 M3이 리셋하지만, M1 골격은 보존만 한다.
    top_level: bool = false,
};

/// workspace(사이드바 탭) = pane들의 순번 묶음(+active) + 그룹 메타. session_model.Tab에 대응(런타임/split 기하 제외).
pub const Workspace = struct {
    /// 이 workspace 안 pane들(순서 보존). heap `*Pane`를 든다 — move가 포인터 재배치라 리스트 재배열이 pane을 무효화 안 함.
    panes: std.ArrayList(*Pane) = .empty,
    /// 활성 pane 인덱스. panes가 비면 무의미(empty-정리로 제거).
    active_pane: usize = 0,
    /// 그룹 메타데이터(pass-through 보존). M1은 정규화하지 않는다.
    meta: WorkspaceMeta = .{},
};

/// window = workspace들의 순번 묶음(+active) + 분류자. OS NSWindow 하나에 대응하지만 여기선 순수 배치 노드다.
pub const Window = struct {
    /// 위치 메타데이터(opaque, 라우팅 키 아님 — docs/window-surface-mobility.md §1).
    window_id: u64,
    /// normal/quick(M0b enum). quick 정책은 열거/scope에서 다뤄지고 여기선 분류만.
    kind: WindowKind,
    /// 이 window 안 workspace들(순서 보존). heap `*Workspace`.
    workspaces: std.ArrayList(*Workspace) = .empty,
    /// 활성 workspace 인덱스. workspaces가 비면 그 window는 제거된다.
    active_workspace: usize = 0,
};

/// (win) 좌표.
pub const WindowAddr = usize;
/// (win, ws) 좌표.
pub const WorkspaceAddr = struct { win: usize, ws: usize };
/// (win, ws, pane) 좌표.
pub const PaneAddr = struct { win: usize, ws: usize, pane: usize };
/// (win, ws, pane, surface) 좌표.
pub const SurfaceAddr = struct { win: usize, ws: usize, pane: usize, surface: usize };

/// move/merge 실패. `InvalidCoordinate`=좌표가 현재 구조 밖(bounds). 순수 함수 계약이라 no-op(같은 자리)은 에러가
/// 아니라 조용한 무변경으로 반환한다(성공). 할당 실패는 목적지 append에서만 날 수 있다.
pub const MoveError = error{InvalidCoordinate} || std.mem.Allocator.Error;

/// window→workspace→pane→surface_ref 배치 그래프. 노드는 heap 소유, 부모 리스트가 pointer로 참조한다.
pub const WindowGraph = struct {
    allocator: std.mem.Allocator,
    /// 살아있는 window들(순서 보존). 첫 window가 관례상 primary지만 라우팅은 window_id/kind로 한다.
    windows: std.ArrayList(*Window) = .empty,
    /// 활성 window 인덱스. windows가 비면 0(무의미).
    active_window: usize = 0,

    pub fn init(allocator: std.mem.Allocator) WindowGraph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WindowGraph) void {
        for (self.windows.items) |win| self.destroyWindow(win);
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    // ── 빌더(테스트·미래 collector용) — 부모 포인터를 받아 자식 heap 노드를 만들어 붙이고 그 포인터를 돌려준다 ──

    pub fn addWindow(self: *WindowGraph, window_id: u64, kind: WindowKind) MoveError!*Window {
        const win = try self.allocator.create(Window);
        win.* = .{ .window_id = window_id, .kind = kind };
        errdefer self.allocator.destroy(win);
        try self.windows.append(self.allocator, win);
        return win;
    }

    pub fn addWorkspace(self: *WindowGraph, win: *Window, meta: WorkspaceMeta) MoveError!*Workspace {
        const ws = try self.allocator.create(Workspace);
        ws.* = .{ .meta = meta };
        errdefer self.allocator.destroy(ws);
        try win.workspaces.append(self.allocator, ws);
        return ws;
    }

    pub fn addPane(self: *WindowGraph, ws: *Workspace) MoveError!*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = .{};
        errdefer self.allocator.destroy(pane);
        try ws.panes.append(self.allocator, pane);
        return pane;
    }

    pub fn addSurface(self: *WindowGraph, pane: *Pane, surface_id: u64) MoveError!void {
        try pane.surfaces.append(self.allocator, .{ .surface_id = surface_id });
    }

    // ── 좌표 해석(bounds 검사) ────────────────────────────────────────────────────────────────────────────

    fn windowAt(self: *WindowGraph, i: usize) MoveError!*Window {
        if (i >= self.windows.items.len) return error.InvalidCoordinate;
        return self.windows.items[i];
    }

    fn workspaceAt(self: *WindowGraph, addr: WorkspaceAddr) MoveError!*Workspace {
        const win = try self.windowAt(addr.win);
        if (addr.ws >= win.workspaces.items.len) return error.InvalidCoordinate;
        return win.workspaces.items[addr.ws];
    }

    fn paneAt(self: *WindowGraph, addr: PaneAddr) MoveError!*Pane {
        const ws = try self.workspaceAt(.{ .win = addr.win, .ws = addr.ws });
        if (addr.pane >= ws.panes.items.len) return error.InvalidCoordinate;
        return ws.panes.items[addr.pane];
    }

    // ── move 연산 ────────────────────────────────────────────────────────────────────────────────────────

    /// surface를 pane 간 이동. 같은 pane이면 no-op(조용한 무변경). 이동한 surface는 dst pane에서 active가 된다
    /// (focus 규칙 1). source pane이 비면 정리(pane→workspace→window로 empty 전파, 위 focus 규칙 2·3).
    pub fn moveSurface(self: *WindowGraph, src: SurfaceAddr, dst: PaneAddr) MoveError!void {
        const win_src = try self.windowAt(src.win);
        const ws_src = try self.workspaceAt(.{ .win = src.win, .ws = src.ws });
        const p_src = try self.paneAt(.{ .win = src.win, .ws = src.ws, .pane = src.pane });
        if (src.surface >= p_src.surfaces.items.len) return error.InvalidCoordinate;

        const win_dst = try self.windowAt(dst.win);
        const p_dst = try self.paneAt(dst);
        if (p_src == p_dst) return; // 같은 pane = no-op

        const ref = p_src.surfaces.orderedRemove(src.surface);
        p_src.active_surface = activeAfterRemoval(p_src.active_surface, src.surface, p_src.surfaces.items.len);

        try p_dst.surfaces.append(self.allocator, ref);
        p_dst.active_surface = p_dst.surfaces.items.len - 1; // 이동한 surface가 dst에서 active(focus 따라감)

        self.pruneEmptyPane(win_src, ws_src, p_src, win_dst);
    }

    /// pane을 workspace 간(같은/다른 window) 이동. 같은 workspace면 no-op. 이동한 pane은 dst workspace에서 active.
    /// source workspace가 비면 정리(workspace→window empty 전파).
    pub fn movePane(self: *WindowGraph, src: PaneAddr, dst: WorkspaceAddr) MoveError!void {
        const win_src = try self.windowAt(src.win);
        const ws_src = try self.workspaceAt(.{ .win = src.win, .ws = src.ws });
        if (src.pane >= ws_src.panes.items.len) return error.InvalidCoordinate;

        const win_dst = try self.windowAt(dst.win);
        const ws_dst = try self.workspaceAt(dst);
        if (ws_src == ws_dst) return; // 같은 workspace = no-op

        const pane = ws_src.panes.orderedRemove(src.pane);
        ws_src.active_pane = activeAfterRemoval(ws_src.active_pane, src.pane, ws_src.panes.items.len);

        try ws_dst.panes.append(self.allocator, pane);
        ws_dst.active_pane = ws_dst.panes.items.len - 1; // 이동한 pane이 dst에서 active

        self.pruneEmptyWorkspace(win_src, ws_src, win_dst);
    }

    /// workspace를 window 간 이동. 같은 window면 no-op. 이동한 workspace는 dst window에서 active. 그룹 메타는
    /// pass-through(정규화 없음 — §8 M1). source window가 비면 제거(active_window는 dst로 따라감 — focus 규칙 3).
    pub fn moveWorkspace(self: *WindowGraph, src: WorkspaceAddr, dst_win: WindowAddr) MoveError!void {
        const win_src = try self.windowAt(src.win);
        if (src.ws >= win_src.workspaces.items.len) return error.InvalidCoordinate;

        const win_dst = try self.windowAt(dst_win);
        if (win_src == win_dst) return; // 같은 window = no-op

        const ws = win_src.workspaces.orderedRemove(src.ws);
        win_src.active_workspace = activeAfterRemoval(win_src.active_workspace, src.ws, win_src.workspaces.items.len);

        try win_dst.workspaces.append(self.allocator, ws);
        win_dst.active_workspace = win_dst.workspaces.items.len - 1; // 이동한 workspace가 dst에서 active

        self.pruneEmptyWindow(win_src, win_dst);
    }

    /// source window의 workspace를 **전부** target window로 옮기고(순서 보존) 빈 source window를 닫는 bulk 연산
    /// (docs/window-surface-mobility.md §1·§4). 같은 window면 no-op. target의 active_workspace는 그대로 두고
    /// (target은 보던 것을 유지), `active_window`가 source였으면 target으로 따라간다(focus 규칙 3 = "active window 보정").
    pub fn mergeWindow(self: *WindowGraph, src_win: WindowAddr, dst_win: WindowAddr) MoveError!void {
        const win_src = try self.windowAt(src_win);
        const win_dst = try self.windowAt(dst_win);
        if (win_src == win_dst) return; // 같은 window = no-op

        // source workspace를 앞에서부터 떼어 target 뒤에 붙인다 → 상대 순서 보존.
        while (win_src.workspaces.items.len > 0) {
            const ws = win_src.workspaces.orderedRemove(0);
            try win_dst.workspaces.append(self.allocator, ws);
        }
        // source는 이제 비었다 → 닫는다. active_window는 target으로 따라간다(source가 active였다면).
        self.removeWindow(win_src, win_dst);
    }

    // ── empty-source 정리(source 경로만, focus 규칙 2; window 층은 dst로 focus-follow=규칙 3) ────────────────

    fn pruneEmptyPane(self: *WindowGraph, win: *Window, ws: *Workspace, pane: *Pane, focus_to_win: *Window) void {
        if (pane.surfaces.items.len != 0) return;
        const pi = indexOfPane(ws, pane).?;
        _ = ws.panes.orderedRemove(pi);
        pane.surfaces.deinit(self.allocator);
        self.allocator.destroy(pane);
        ws.active_pane = activeAfterRemoval(ws.active_pane, pi, ws.panes.items.len);
        self.pruneEmptyWorkspace(win, ws, focus_to_win);
    }

    fn pruneEmptyWorkspace(self: *WindowGraph, win: *Window, ws: *Workspace, focus_to_win: *Window) void {
        if (ws.panes.items.len != 0) return;
        const wi = indexOfWorkspace(win, ws).?;
        _ = win.workspaces.orderedRemove(wi);
        ws.panes.deinit(self.allocator);
        self.allocator.destroy(ws);
        win.active_workspace = activeAfterRemoval(win.active_workspace, wi, win.workspaces.items.len);
        self.pruneEmptyWindow(win, focus_to_win);
    }

    fn pruneEmptyWindow(self: *WindowGraph, win: *Window, focus_to_win: *Window) void {
        if (win.workspaces.items.len != 0) return;
        self.removeWindow(win, focus_to_win);
    }

    /// window를 그래프에서 제거·해제한다. `active_window` 보정: 제거 대상이 active였으면 `focus_to`(이동 목적지)로
    /// 따라가고(focus 규칙 3), 아니면 removal-shift로 보정한다. focus_to는 제거 대상과 다른, 살아남는 window여야 한다.
    fn removeWindow(self: *WindowGraph, win: *Window, focus_to: *Window) void {
        const idx = indexOfWindowIn(self.windows.items, win).?;
        const focus_idx_before = indexOfWindowIn(self.windows.items, focus_to);
        _ = self.windows.orderedRemove(idx);
        win.workspaces.deinit(self.allocator); // 비어 있음(workspace는 이미 이동/제거됨)
        self.allocator.destroy(win);

        const new_len = self.windows.items.len;
        if (new_len == 0) {
            self.active_window = 0;
            return;
        }
        if (self.active_window == idx) {
            // active였던 창이 사라짐 → 이동 목적지로 따라간다(제거로 인한 인덱스 shift 반영).
            if (focus_idx_before) |fib| {
                self.active_window = fib - @intFromBool(fib > idx);
            } else {
                self.active_window = @min(idx, new_len - 1);
            }
        } else {
            self.active_window = activeAfterRemoval(self.active_window, idx, new_len);
        }
    }

    // ── 읽기 헬퍼(M0b membership 정합 검증·미래 collector용) ────────────────────────────────────────────────

    /// window 안 모든 surface_id를 순서대로(workspace→pane→surface) `out`에 채워 slice 반환. `out`이 모자라면
    /// 앞에서부터 잘라 채운다(window_membership.collectVisibleSurfaces와 같은 조용한 절단 계약 — 버퍼는 호출자 보장).
    pub fn collectWindowSurfaceIds(self: *WindowGraph, win_index: usize, out: []u64) MoveError![]u64 {
        const win = try self.windowAt(win_index);
        var n: usize = 0;
        for (win.workspaces.items) |ws| {
            for (ws.panes.items) |pane| {
                for (pane.surfaces.items) |ref| {
                    if (n >= out.len) return out[0..n];
                    out[n] = ref.surface_id;
                    n += 1;
                }
            }
        }
        return out[0..n];
    }

    // ── 내부 teardown ────────────────────────────────────────────────────────────────────────────────────

    fn destroyWindow(self: *WindowGraph, win: *Window) void {
        for (win.workspaces.items) |ws| self.destroyWorkspace(ws);
        win.workspaces.deinit(self.allocator);
        self.allocator.destroy(win);
    }

    fn destroyWorkspace(self: *WindowGraph, ws: *Workspace) void {
        for (ws.panes.items) |pane| self.destroyPane(pane);
        ws.panes.deinit(self.allocator);
        self.allocator.destroy(ws);
    }

    fn destroyPane(self: *WindowGraph, pane: *Pane) void {
        pane.surfaces.deinit(self.allocator);
        self.allocator.destroy(pane);
    }
};

/// 리스트에서 요소 하나를 index `removed`에서 제거한 뒤(새 길이 `new_len`) active 인덱스를 보정한다.
/// - active > removed: 뒤 요소가 당겨졌으므로 −1.
/// - active == removed: 제거 자리에 다음 요소가 오므로 그대로 두되, 마지막을 지웠으면 new_len−1로 클램프.
/// - active < removed: 불변.
/// new_len==0(컨테이너가 비었다 = 곧 제거됨)이면 0.
fn activeAfterRemoval(active: usize, removed: usize, new_len: usize) usize {
    if (new_len == 0) return 0;
    if (active > removed) return active - 1;
    return @min(active, new_len - 1); // active==removed(클램프) 및 active<removed(불변) 모두 포함
}

fn indexOfPane(ws: *Workspace, pane: *Pane) ?usize {
    for (ws.panes.items, 0..) |p, i| {
        if (p == pane) return i;
    }
    return null;
}

fn indexOfWorkspace(win: *Window, ws: *Workspace) ?usize {
    for (win.workspaces.items, 0..) |w, i| {
        if (w == ws) return i;
    }
    return null;
}

fn indexOfWindowIn(windows: []const *Window, win: *Window) ?usize {
    for (windows, 0..) |w, i| {
        if (w == win) return i;
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════════════
//   테스트 — 헤드리스 순수 모델. live 핸들·PTY·Swift 없이 트리 재배치·focus 보정·pass-through·membership만 검증.
// ══════════════════════════════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// activeAfterRemoval 단위(세 분기 + 빈 컨테이너 경계) ── move 연산이 이 보정 함수에 의존하므로 먼저 못박는다.
test "activeAfterRemoval: removal 후 active 보정 세 분기 + 빈 컨테이너" {
    // active > removed → 당겨져 −1.
    try testing.expectEqual(@as(usize, 1), activeAfterRemoval(2, 0, 3));
    // active < removed → 불변.
    try testing.expectEqual(@as(usize, 0), activeAfterRemoval(0, 2, 3));
    // active == removed, 뒤에 요소 있음 → 그 자리 유지(다음 요소가 옴).
    try testing.expectEqual(@as(usize, 1), activeAfterRemoval(1, 1, 3));
    // active == removed == 마지막 → new_len−1로 클램프.
    try testing.expectEqual(@as(usize, 1), activeAfterRemoval(2, 2, 2));
    // 빈 컨테이너(new_len==0) → 0.
    try testing.expectEqual(@as(usize, 0), activeAfterRemoval(0, 0, 0));
}

// ── 소규모 그래프 조립 헬퍼(테스트 가독성) ──────────────────────────────────────────────────────────────────
// 한 pane에 surface 하나씩 든 단순 그래프를 만든다. 반환 포인터로 좌표를 순번(append 순)으로 안다.

test "moveSurface: pane 간 이동 — surface가 dst로, active surface는 focus 따라감" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();

    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p0 = try g.addPane(ws); // pane 0
    const p1 = try g.addPane(ws); // pane 1
    try g.addSurface(p0, 100);
    try g.addSurface(p0, 101); // p0 = {100,101}
    try g.addSurface(p1, 200); // p1 = {200}
    p0.active_surface = 1; // active = surface 101

    // p0의 active surface(index 1 = id 101)를 p1으로 옮긴다.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 1 }, .{ .win = 0, .ws = 0, .pane = 1 });

    // p0에는 100만 남고, active는 100(index 0)으로 보정(제거된 index 1이 마지막이라 클램프).
    try testing.expectEqual(@as(usize, 1), p0.surfaces.items.len);
    try testing.expectEqual(@as(u64, 100), p0.surfaces.items[0].surface_id);
    try testing.expectEqual(@as(usize, 0), p0.active_surface);
    // p1에는 200,101 순으로, active는 이동한 101(마지막) = focus 따라감.
    try testing.expectEqual(@as(usize, 2), p1.surfaces.items.len);
    try testing.expectEqual(@as(u64, 101), p1.surfaces.items[1].surface_id);
    try testing.expectEqual(@as(usize, 1), p1.active_surface);
}

test "moveSurface: 비활성 surface를 옮겨도 목적지에선 active가 된다(focus 규칙 1 = 이동한 것이 선택됨)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p0 = try g.addPane(ws);
    const p1 = try g.addPane(ws);
    try g.addSurface(p0, 100);
    try g.addSurface(p0, 101);
    p0.active_surface = 0; // active = 100
    try g.addSurface(p1, 200);
    p1.active_surface = 0;

    // 비활성 surface 101(index 1)을 옮긴다. dst에서 active가 되어야 한다.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 1 }, .{ .win = 0, .ws = 0, .pane = 1 });
    try testing.expectEqual(@as(u64, 101), p1.surfaces.items[p1.active_surface].surface_id);
    // source active(100, index 0)는 removed index(1)보다 작아 불변.
    try testing.expectEqual(@as(usize, 0), p0.active_surface);
    try testing.expectEqual(@as(u64, 100), p0.surfaces.items[0].surface_id);
}

test "moveSurface: 같은 pane = no-op(무변경)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p0 = try g.addPane(ws);
    try g.addSurface(p0, 100);
    try g.addSurface(p0, 101);
    p0.active_surface = 1;

    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 0, .ws = 0, .pane = 0 });
    // 아무것도 안 바뀐다(순서·active 그대로).
    try testing.expectEqual(@as(usize, 2), p0.surfaces.items.len);
    try testing.expectEqual(@as(u64, 100), p0.surfaces.items[0].surface_id);
    try testing.expectEqual(@as(u64, 101), p0.surfaces.items[1].surface_id);
    try testing.expectEqual(@as(usize, 1), p0.active_surface);
}

test "moveSurface: source pane의 마지막 surface가 빠지면 그 pane이 정리된다(empty-source cascade)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p0 = try g.addPane(ws); // 이동 후 비게 됨
    const p1 = try g.addPane(ws);
    try g.addSurface(p0, 100); // p0 = {100}(하나뿐)
    try g.addSurface(p1, 200);
    ws.active_pane = 0; // active pane = p0(제거될 것)

    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 0, .ws = 0, .pane = 1 });

    // p0는 비어 제거 → workspace에 pane 하나(p1)만.
    try testing.expectEqual(@as(usize, 1), ws.panes.items.len);
    try testing.expectEqual(p1, ws.panes.items[0]);
    // active_pane은 제거(index 0)로 보정 → 0(남은 p1).
    try testing.expectEqual(@as(usize, 0), ws.active_pane);
    // surface는 p1로 이동, 거기서 active.
    try testing.expectEqual(@as(u64, 100), p1.surfaces.items[p1.active_surface].surface_id);
}

test "movePane: workspace 간(다른 window) 이동 + 이동 pane이 dst에서 active" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p_a = try g.addPane(ws0);
    const p_b = try g.addPane(ws0);
    try g.addSurface(p_a, 100);
    try g.addSurface(p_b, 101);
    ws0.active_pane = 0;
    const p_c = try g.addPane(ws1);
    try g.addSurface(p_c, 200);
    ws1.active_pane = 0;

    // ws0의 pane b(index 1)를 window1의 ws1으로 옮긴다.
    try g.movePane(.{ .win = 0, .ws = 0, .pane = 1 }, .{ .win = 1, .ws = 0 });

    // ws0에는 p_a만.
    try testing.expectEqual(@as(usize, 1), ws0.panes.items.len);
    try testing.expectEqual(p_a, ws0.panes.items[0]);
    try testing.expectEqual(@as(usize, 0), ws0.active_pane); // 불변(active 0 < removed 1)
    // ws1에는 p_c, p_b 순. 이동한 p_b가 active(마지막).
    try testing.expectEqual(@as(usize, 2), ws1.panes.items.len);
    try testing.expectEqual(p_b, ws1.panes.items[1]);
    try testing.expectEqual(@as(usize, 1), ws1.active_pane);
}

test "movePane: source workspace의 마지막 pane이 빠지면 그 workspace가 정리된다(empty-source workspace)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const ws_a = try g.addWorkspace(w0, .{}); // 비게 됨
    const ws_b = try g.addWorkspace(w0, .{});
    const p0 = try g.addPane(ws_a);
    try g.addSurface(p0, 100);
    const p1 = try g.addPane(ws_b);
    try g.addSurface(p1, 200);
    w0.active_workspace = 0; // ws_a active(제거될 것)

    try g.movePane(.{ .win = 0, .ws = 0, .pane = 0 }, .{ .win = 0, .ws = 1 });

    // ws_a는 비어 제거 → window에 ws_b만.
    try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len);
    try testing.expectEqual(ws_b, w0.workspaces.items[0]);
    try testing.expectEqual(@as(usize, 0), w0.active_workspace); // 제거 index 0 보정 → 남은 것
    // pane은 ws_b로 이동.
    try testing.expectEqual(@as(usize, 2), ws_b.panes.items.len);
    try testing.expectEqual(p0, ws_b.panes.items[1]);
}

test "moveWorkspace: window 간 이동 + 그룹 필드 pass-through 보존(정규화 없음)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source window에 workspace 둘: 하나는 그룹 마커+핀 메타를 지닌다.
    const marker = "project-alpha";
    const ws_grouped = try g.addWorkspace(w0, .{
        .group_start = marker,
        .pinned = true,
        .local_pinned = true,
        .top_level = true,
    });
    _ = try g.addPane(ws_grouped);
    const ws_keep = try g.addWorkspace(w0, .{});
    _ = try g.addPane(ws_keep);
    const ws_dst = try g.addWorkspace(w1, .{});
    _ = try g.addPane(ws_dst);

    // 그룹 메타를 지닌 ws_grouped(index 0)를 window1로 옮긴다.
    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1);

    // window1에 두 workspace, 이동분이 마지막·active.
    try testing.expectEqual(@as(usize, 2), w1.workspaces.items.len);
    try testing.expectEqual(ws_grouped, w1.workspaces.items[1]);
    try testing.expectEqual(@as(usize, 1), w1.active_workspace);
    // **pass-through 보존**: 그룹 필드가 이동 후에도 그대로다(정규화·리셋 안 함 — M1 group-agnostic).
    try testing.expect(ws_grouped.meta.group_start != null);
    try testing.expectEqualStrings(marker, ws_grouped.meta.group_start.?);
    try testing.expect(ws_grouped.meta.pinned);
    try testing.expect(ws_grouped.meta.local_pinned); // M3이라면 리셋했겠지만 M1은 보존만
    try testing.expect(ws_grouped.meta.top_level);
    // source window에는 ws_keep만 남는다.
    try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len);
    try testing.expectEqual(ws_keep, w0.workspaces.items[0]);
}

test "moveWorkspace: source window의 마지막 workspace가 빠지면 그 window가 닫힌다(empty-source window)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal); // 비게 됨
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(ws0);
    const ws1 = try g.addWorkspace(w1, .{});
    _ = try g.addPane(ws1);
    g.active_window = 0; // w0 active(닫힐 것)

    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1);

    // w0는 비어 닫힘 → graph에 window 하나(w1)만.
    try testing.expectEqual(@as(usize, 1), g.windows.items.len);
    try testing.expectEqual(w1, g.windows.items[0]);
    // active_window는 닫힌 w0에서 이동 목적지 w1으로 따라간다(focus 규칙 3).
    try testing.expectEqual(@as(usize, 0), g.active_window);
    try testing.expectEqual(ws0, w1.workspaces.items[w1.active_workspace]);
}

test "moveWorkspace: 같은 window = no-op" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(ws0);
    const ws1 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(ws1);
    w0.active_workspace = 1;

    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 0);
    // 순서·active 불변.
    try testing.expectEqual(@as(usize, 2), w0.workspaces.items.len);
    try testing.expectEqual(ws0, w0.workspaces.items[0]);
    try testing.expectEqual(ws1, w0.workspaces.items[1]);
    try testing.expectEqual(@as(usize, 1), w0.active_workspace);
}

test "mergeWindow: source workspace 전부 target으로 + 빈 source 닫힘 + active window 보정" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal); // target
    const w1 = try g.addWindow(2, .normal); // source(닫힐 것)
    // target에 workspace 하나.
    const t0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(t0);
    w0.active_workspace = 0;
    // source에 workspace 둘.
    const s0 = try g.addWorkspace(w1, .{});
    _ = try g.addPane(s0);
    const s1 = try g.addWorkspace(w1, .{});
    _ = try g.addPane(s1);
    g.active_window = 1; // source가 active(닫히면 target으로 보정돼야)

    try g.mergeWindow(1, 0);

    // graph엔 target(w0) 하나만.
    try testing.expectEqual(@as(usize, 1), g.windows.items.len);
    try testing.expectEqual(w0, g.windows.items[0]);
    // target에 t0,s0,s1 순(순서 보존).
    try testing.expectEqual(@as(usize, 3), w0.workspaces.items.len);
    try testing.expectEqual(t0, w0.workspaces.items[0]);
    try testing.expectEqual(s0, w0.workspaces.items[1]);
    try testing.expectEqual(s1, w0.workspaces.items[2]);
    // target의 active_workspace는 그대로(target은 보던 것 유지).
    try testing.expectEqual(@as(usize, 0), w0.active_workspace);
    // active_window는 닫힌 source에서 target으로 따라간다("active window 보정").
    try testing.expectEqual(@as(usize, 0), g.active_window);
}

test "mergeWindow: active_window가 source도 target도 아니면 removal-shift로 보정" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal); // target
    const w1 = try g.addWindow(2, .normal); // source(index 1, 닫힘)
    const w2 = try g.addWindow(3, .normal); // 방관자(index 2, active)
    const t0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(t0);
    const s0 = try g.addWorkspace(w1, .{});
    _ = try g.addPane(s0);
    const b0 = try g.addWorkspace(w2, .{});
    _ = try g.addPane(b0);
    g.active_window = 2; // 방관자 w2

    try g.mergeWindow(1, 0);

    // source(index 1) 제거 → w2가 index 1로 당겨짐, active_window도 2→1.
    try testing.expectEqual(@as(usize, 2), g.windows.items.len);
    try testing.expectEqual(w2, g.windows.items[1]);
    try testing.expectEqual(@as(usize, 1), g.active_window);
}

test "mergeWindow: 같은 window = no-op" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(ws0);

    try g.mergeWindow(0, 0);
    try testing.expectEqual(@as(usize, 1), g.windows.items.len);
    try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len);
}

test "InvalidCoordinate: 범위 밖 좌표는 조용한 실패로 걸린다(각 연산)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p = try g.addPane(ws);
    try g.addSurface(p, 100);

    // 없는 window/workspace/pane/surface index.
    try testing.expectError(error.InvalidCoordinate, g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 5 }, .{ .win = 0, .ws = 0, .pane = 0 }));
    try testing.expectError(error.InvalidCoordinate, g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 9, .ws = 0, .pane = 0 }));
    try testing.expectError(error.InvalidCoordinate, g.movePane(.{ .win = 0, .ws = 0, .pane = 3 }, .{ .win = 0, .ws = 0 }));
    try testing.expectError(error.InvalidCoordinate, g.moveWorkspace(.{ .win = 0, .ws = 7 }, 0));
    try testing.expectError(error.InvalidCoordinate, g.moveWorkspace(.{ .win = 0, .ws = 0 }, 4));
    try testing.expectError(error.InvalidCoordinate, g.mergeWindow(0, 8));
    // 실패 후에도 구조가 온전(mutate 전에 검증하므로).
    try testing.expectEqual(@as(usize, 1), w.workspaces.items.len);
    try testing.expectEqual(@as(usize, 1), p.surfaces.items.len);
}

test "M0a/M0b 결합: 이동 후에도 surface_id 전역 유일성·window membership 정합이 유지된다" {
    const surface_id_mod = @import("surface_id.zig");
    var ids: surface_id_mod.SurfaceIdAllocator = .{};

    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();

    // 두 window, 각 window에 workspace/pane, 앱 전역 allocator에서 발급한 surface_id들.
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws1);
    const sid_a = ids.next();
    const sid_b = ids.next();
    const sid_c = ids.next();
    try g.addSurface(p0, sid_a);
    try g.addSurface(p0, sid_b); // window0 = {a,b}
    try g.addSurface(p1, sid_c); // window1 = {c}

    // 이동 전: window0={a,b}, window1={c}. M0b snapshot으로 scope 판정.
    {
        var buf0: [8]u64 = undefined;
        var buf1: [8]u64 = undefined;
        const w0_ids = try g.collectWindowSurfaceIds(0, &buf0);
        const w1_ids = try g.collectWindowSurfaceIds(1, &buf1);
        const snaps = [_]window_membership.WindowMembershipSnapshot{
            .{ .window_id = 1, .window_kind = .normal, .surface_ids = w0_ids },
            .{ .window_id = 2, .window_kind = .normal, .surface_ids = w1_ids },
        };
        // caller=a는 window scope로 b는 보지만 c(다른 창)는 못 본다.
        try testing.expect(window_membership.scopeAllowsSurface(&snaps, sid_a, .window, sid_b));
        try testing.expect(!window_membership.scopeAllowsSurface(&snaps, sid_a, .window, sid_c));
    }

    // surface b를 window1의 p1으로 옮긴다(cross-window). membership이 따라가야 한다.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 1 }, .{ .win = 1, .ws = 0, .pane = 0 });

    // 이동 후: window0={a}, window1={c,b}. 전역 유일성은 여전히 성립(중복·유실 없음).
    {
        var seen = std.AutoHashMap(u64, void).init(testing.allocator);
        defer seen.deinit();
        var total: usize = 0;
        var wi: usize = 0;
        while (wi < g.windows.items.len) : (wi += 1) {
            var buf: [8]u64 = undefined;
            const win_ids = try g.collectWindowSurfaceIds(wi, &buf);
            for (win_ids) |sid| {
                try testing.expect(!seen.contains(sid)); // 어느 창에서도 중복 등장 안 함
                try seen.put(sid, {});
                total += 1;
            }
        }
        try testing.expectEqual(@as(usize, 3), total); // a,b,c 셋 그대로(유실 없음)

        // membership 정합: 이제 b는 window1에 속해, window0 caller(a)의 window scope에서 안 보이고
        // window1 caller(c)의 window scope에서 보인다.
        var buf0: [8]u64 = undefined;
        var buf1: [8]u64 = undefined;
        const w0_ids = try g.collectWindowSurfaceIds(0, &buf0);
        const w1_ids = try g.collectWindowSurfaceIds(1, &buf1);
        const snaps = [_]window_membership.WindowMembershipSnapshot{
            .{ .window_id = 1, .window_kind = .normal, .surface_ids = w0_ids },
            .{ .window_id = 2, .window_kind = .normal, .surface_ids = w1_ids },
        };
        try testing.expect(!window_membership.scopeAllowsSurface(&snaps, sid_a, .window, sid_b)); // 이제 다른 창
        try testing.expect(window_membership.scopeAllowsSurface(&snaps, sid_c, .window, sid_b)); // c와 같은 창
    }
}

test "deinit: 여러 window/workspace/pane/surface를 누수 없이 해제(testing.allocator가 검증)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    var wi: u64 = 0;
    while (wi < 3) : (wi += 1) {
        const w = try g.addWindow(wi + 1, if (wi == 2) .quick else .normal);
        var wsi: usize = 0;
        while (wsi < 2) : (wsi += 1) {
            const ws = try g.addWorkspace(w, .{ .group_start = "g" });
            const p = try g.addPane(ws);
            try g.addSurface(p, wi * 10 + wsi);
        }
    }
    try testing.expectEqual(@as(usize, 3), g.windows.items.len);
    // defer deinit이 전부 해제. leak이 있으면 testing.allocator가 실패시킨다.
}
