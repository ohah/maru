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
const group_normalize = @import("group_normalize.zig"); // M3c: 그룹 정규화 순수 함수(승계·핀 재정규화·depth·로컬핀 위생)

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

/// workspace의 그룹 메타데이터. **M1 골격은 이 값을 정규화하지 않고 pass-through로 실어 날랐고, M3c부터 `moveWorkspace`가
/// L2 순수 함수(`group_normalize`)로 실제 정규화한다**(docs/window-surface-mobility.md §4·§8A.4). session_model.Tab의 그룹
/// 필드를 미러한다 — §4 (a)~(d) 케이스가 요구하는 승계·핀 재정규화·depth 파생에 필요한 필드 전부를 든다(effectiveDepthAt은
/// group_depth를, inheritGroupMarker는 group_collapsed·group_color 승계를 읽으므로 M1의 4필드로는 부족했다). 문자열
/// (group_start)은 **borrowed**다 — graph는 소유하지 않는다(WindowMembershipSnapshot.surface_ids와 같은 계약, 소유는
/// collector/라이브 모델). 정규화 권위는 L2 `group_normalize`(L4 `inheritGroupMarker`/`normalizePinnedFromGroups`에서 리프트).
pub const WorkspaceMeta = struct {
    /// 사이드바 그룹 **시작 마커**(위치 파생 소속 — docs/sidebar-groups.md §2.1). null=마커 아님. borrowed.
    group_start: ?[]const u8 = null,
    /// 그룹 접힘(group_start!=null일 때만 의미 — §2.1). inheritGroupMarker가 승계 시 다음 노드로 이전한다.
    group_collapsed: bool = false,
    /// 중첩 그룹 깊이(SG5-3, group_start!=null일 때만 의미 — 1=최상위·2=중첩·…). effectiveDepthAt의 위치 파생 입력.
    group_depth: u8 = 1,
    /// 그룹 공통 색(0xRRGGBB, 0=없음 — SG5-2). inheritGroupMarker가 승계 시 다음 노드로 이전한다.
    group_color: u32 = 0,
    /// 전역 위치 고정(핀 프리픽스, §12). moveWorkspace가 §4 (c)/(d)로 정규화(top-level 개별 pin=보존, 그룹 멤버=이탈 시 unpin).
    pinned: bool = false,
    /// 그룹-로컬 pin(GL, §13). 이탈 시 의미를 잃어 moveWorkspace가 리셋(§4 (d) — clearStaleLocalPins 위생).
    local_pinned: bool = false,
    /// 서브파티션 top-level 복귀 마커(§14). moveWorkspace가 목적지 top-level로 넣을 때 명시 set(§4 (d) 결정).
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

        // append(fallible)를 remove(infallible) **앞에** 둔다 — OOM이면 source가 그대로라 구조 불변이다
        // (remove-후-append 순서면 append 실패 시 SurfaceRef가 어느 pane에도 없어 surface_id가 그래프에서 유실).
        const ref = p_src.surfaces.items[src.surface];
        try p_dst.surfaces.append(self.allocator, ref);
        _ = p_src.surfaces.orderedRemove(src.surface);
        p_src.active_surface = activeAfterRemoval(p_src.active_surface, src.surface, p_src.surfaces.items.len);
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

        // append(fallible) 먼저 — OOM이면 source 불변(remove-후-append면 *Pane이 어느 리스트에도 없어 leak+그래프 손상).
        const pane = ws_src.panes.items[src.pane];
        try ws_dst.panes.append(self.allocator, pane);
        _ = ws_src.panes.orderedRemove(src.pane);
        ws_src.active_pane = activeAfterRemoval(ws_src.active_pane, src.pane, ws_src.panes.items.len);
        ws_dst.active_pane = ws_dst.panes.items.len - 1; // 이동한 pane이 dst에서 active

        self.pruneEmptyWorkspace(win_src, ws_src, win_dst);
    }

    /// workspace를 window 간 이동. 같은 window면 no-op. 이동한 workspace는 dst window에서 active. source window가
    /// 비면 제거(active_window는 dst로 따라감 — focus 규칙 3).
    ///
    /// **M3c 그룹 정규화(docs/window-surface-mobility.md §4·§8A.4)**: M1은 그룹 필드를 pass-through로 보존만 했지만,
    /// M3c부터 L2 순수 함수(`group_normalize`)로 §4 케이스 (a)~(d)를 실현한다 — 소속이 tab-순서 파생이라 창을 떠나는
    /// 순간 소속·핀 리전이 바뀐다. 정규화는 **행동 발산 금지**로 L4 `closeTab`/`removeFromGroupForTab`과 같은 함수를 쓴다.
    ///  - **(a) 그룹 멤버 이동**: source에서 빠지면 소속이 재-파생 → source를 `normalizePinnedFromGroups` +
    ///    `clearStaleLocalPins`로 재정규화(= removeFromGroup이 도는 것).
    ///  - **(b) group_start 마커 이동**: `inheritGroupMarker`로 마커를 source의 다음 카드에 승계(그룹 잔존)하거나,
    ///    승계 불가면 그룹 소멸. 이동분은 목적지에서 마커가 아닌 최상위 카드가 된다(group_start=null).
    ///  - **(c) 전역 pinned 최상위 카드 이동**: 그룹 소속이 아니면 pinned 유지(목적지 핀 리전으로 — "고정 요소 흡수
    ///    불가", top_level=true가 그룹 흡수를 차단). 핀 리전 내 **위치**(프리픽스) 안착은 라이브 트리/M3d 몫(그래프는
    ///    append + 플래그 정규화만; 그래프는 라이브 미러가 아니라 순수 오라클+직렬화 포맷 — §8A.6).
    ///  - **(d) 이탈 정규화**: `local_pinned:=false`(clearStaleLocalPins 명시 리셋 대칭), `top_level:=true`(**명시 set**
    ///    — 목적지는 append-to-end라 위치-암묵 top-level이 성립 안 함: 뒤 그룹에 흡수되므로 서브파티션 break 플래그가
    ///    필수. §14.9 "고정 탭은 top_level 강제"와도 정합), 그룹 멤버였으면(마커 포함) pinned 캐시 이탈로 `pinned:=false`
    ///    (§12.7 보강4 — 그룹 고정은 source 잔존 그룹에 남고 이탈분은 unpin). **top_level 결정 근거**: L4 removeFromGroup은
    ///    같은-창이라 "첫 마커 앞으로 재배치"(위치-암묵)로 top-level을 만들지만, 창 간 이동은 목적지에 소스 위치 맥락이
    ///    없고 append 위치가 뒤 그룹 안이라 **명시 top_level=true**가 아니면 흡수된다 → red test로 "명시 set" 확정.
    pub fn moveWorkspace(self: *WindowGraph, src: WorkspaceAddr, dst_win: WindowAddr) MoveError!void {
        const win_src = try self.windowAt(src.win);
        if (src.ws >= win_src.workspaces.items.len) return error.InvalidCoordinate;

        const win_dst = try self.windowAt(dst_win);
        if (win_src == win_dst) return; // 같은 window = no-op

        const ws = win_src.workspaces.items[src.ws];

        // 임시 `[]*WorkspaceMeta`(원본 meta를 가리킴) — 정규화 순수 함수의 `[]*T` 계약에 맞춘다. **구조 mutation 전에**
        // 할당(fallible)해 OOM이면 source가 완전히 불변이다(아래 append 실패와 함께 유일한 fallible 지점). append 후는
        // 전부 infallible(정규화 함수는 할당 없이 플래그만 mutate).
        const src_len = win_src.workspaces.items.len;
        const metas = try self.allocator.alloc(*WorkspaceMeta, src_len);
        defer self.allocator.free(metas);
        for (win_src.workspaces.items, 0..) |w, i| metas[i] = &w.meta;

        // group_start는 정규화가 건드리지 않으므로(pinned/local_pinned만 mutate) append 전에 읽어도 canonical 뒤와 동일.
        const was_marker = ws.meta.group_start != null;

        // append(fallible) — OOM이면 source 불변(metas는 defer로 free, ws는 아직 source에만).
        try win_dst.workspaces.append(self.allocator, ws);

        // ── 이하 infallible ──
        // **정규화-먼저(리뷰 [1])**: 소속 판정·마커 승계 **전에** source를 canonical화한다. L4 closeTab/removeFromGroupForTab은
        // 항상 정규 상태에서만 inherit하는데(inheritGroupMarker는 승계 대상 next가 마커와 **같은 pin**일 때만 이전), moveWorkspace가
        // 비정규 source(마커 직후 pin-desync 멤버)를 그대로 먹이면 same-pin 게이트가 실패해 그룹이 통째 소멸한다(미래 restore/M3d
        // build가 비정규 상태를 먹이는 경로 방어). 정규화는 할당 없이 플래그만 mutate(infallible)라 append(유일한 fallible) 뒤에
        // 둬 "OOM이면 source 불변"을 지킨다. ws가 아직 source(metas[src.ws])에 있는 상태로 전체를 canonical화한다.
        group_normalize.normalizePinnedFromGroups(WorkspaceMeta, metas);
        group_normalize.clearStaleLocalPins(WorkspaceMeta, metas);

        // source membership 판정(canonical 상태, ws가 아직 source에 있을 때): 그룹 소속(마커 포함)이면 이탈 시 unpin, 순수 최상위
        // 카드면 pinned 유지(§4 (c) vs (d)). enclosingGroupMarkerIndex는 마커면 자기 자신을 찾아 non-null → 마커도 "그룹 소속"으로 분류.
        const keep_pin = group_normalize.enclosingGroupMarkerIndex(WorkspaceMeta, metas, src.ws) == null;

        // (b) 마커 승계: source의 다음 카드로 마커를 넘겨 그룹을 살린다(마지막 멤버면 false=소멸). canonical source라 마커 직후 첫
        // 멤버가 pin-synced → same-pin 게이트 통과. ws가 source에 아직 있을 때 실행.
        if (was_marker) _ = group_normalize.inheritGroupMarker(WorkspaceMeta, metas, src.ws);

        _ = win_src.workspaces.orderedRemove(src.ws);
        win_src.active_workspace = activeAfterRemoval(win_src.active_workspace, src.ws, win_src.workspaces.items.len);
        win_dst.active_workspace = win_dst.workspaces.items.len - 1; // 이동한 workspace가 dst에서 active

        // (b)(d) 이동분 = 목적지 최상위 카드로 정규화. 마커였으면 승계로 group_start가 이미 null이거나(성공) 아직 남아 있다
        // (소멸=승계 불가). 어느 쪽이든 목적지에선 마커 아님이므로 그룹 필드 기본값 복귀.
        ws.meta.group_start = null;
        ws.meta.group_collapsed = false;
        ws.meta.group_color = 0;
        ws.meta.group_depth = 1;
        ws.meta.local_pinned = false; // (d) 이탈 시 로컬 pin 상실(clearStaleLocalPins 명시 리셋 대칭)
        ws.meta.top_level = true; // (d) 목적지 최상위 — append-to-end라 명시 set 필수(위 결정 근거)
        if (!keep_pin) ws.meta.pinned = false; // (d) 그룹 멤버/마커 이탈 = 그룹 고정 캐시 상실(§12.7 보강4). (c) 최상위 pin은 유지.

        // (a) source 재정규화: 승계/이탈로 남은 그룹 구성이 바뀌었으니 멤버 pinned 캐시를 마커 기준 재동기 + stale 로컬핀 위생.
        // metas에서 이동한 src.ws 항목을 제거(compact)해 source-after 뷰를 만든다(할당 없음 — infallible).
        std.mem.copyForwards(*WorkspaceMeta, metas[src.ws..], metas[src.ws + 1 ..]);
        const src_after = metas[0 .. src_len - 1];
        group_normalize.normalizePinnedFromGroups(WorkspaceMeta, src_after);
        group_normalize.clearStaleLocalPins(WorkspaceMeta, src_after);

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
            // append(fallible) 먼저 — OOM이면 이 ws가 아직 source에 남아 leak/손상 없음(부분 merge지만 모든 ws가
            // 정확히 한 window에 속한 유효 상태). remove-후-append면 실패 시 서브트리 leak + source 반쪽 상태.
            const ws = win_src.workspaces.items[0];
            try win_dst.workspaces.append(self.allocator, ws);
            _ = win_src.workspaces.orderedRemove(0);
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

// ── M3c 그룹 정규화 §4 (a)~(d) (docs/window-surface-mobility.md §8A.4) ──────────────────────────────────────
// M1은 그룹 필드를 pass-through 보존만 했으나, M3c부터 moveWorkspace가 L2 group_normalize로 §4 케이스를 정규화한다.
// 아래 테스트들은 옛 pass-through 동작에 대해 red다(top_level 명시 set·마커 승계·멤버 unpin·로컬핀 리셋을 단언).

test "moveWorkspace §4(a): 그룹 멤버 이동 = 암묵 이탈 + source 재정규화(잔존 그룹 canonical·sandwich desync 치유)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: 고정 그룹 [marker(pin), a(pin), bad(pin=F desync), good(pin)] — 위치 파생 멤버.
    const marker = try g.addWorkspace(w0, .{ .group_start = "g", .pinned = true });
    _ = try g.addPane(marker);
    const a = try g.addWorkspace(w0, .{ .pinned = true });
    _ = try g.addPane(a);
    const bad = try g.addWorkspace(w0, .{ .pinned = false }); // desync 멤버(마커 pin과 어긋남)
    _ = try g.addPane(bad);
    const good = try g.addWorkspace(w0, .{ .pinned = true });
    _ = try g.addPane(good);
    const dst = try g.addWorkspace(w1, .{});
    _ = try g.addPane(dst);

    // 멤버 a(index 1)를 window1로 옮긴다.
    try g.moveWorkspace(.{ .win = 0, .ws = 1 }, 1);

    // (a) 이동분 a = 목적지 최상위(암묵 이탈): group_start 없음·top_level·그룹 멤버였으니 pinned 상실(§4 d).
    try testing.expect(a.meta.group_start == null);
    try testing.expect(a.meta.top_level);
    try testing.expect(!a.meta.pinned);
    try testing.expect(!a.meta.local_pinned);
    // source 재정규화: 잔존 그룹 [marker(pin), bad, good]에서 sandwich desync `bad`가 마커 pin으로 치유됨(normalize).
    try testing.expectEqual(@as(usize, 3), w0.workspaces.items.len);
    try testing.expect(marker.meta.group_start != null); // 그룹 잔존
    try testing.expect(bad.meta.pinned); // desync → 마커 pin(T)로 canonical 치유
    try testing.expect(good.meta.pinned);
}

test "moveWorkspace §4(b): group_start 마커 이동 = source 마커 승계(그룹 잔존) + 이동분 목적지 최상위" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: [marker(group_start="g", collapsed, color, depth), m1(member), m2(member)]
    const marker = try g.addWorkspace(w0, .{ .group_start = "g", .group_collapsed = true, .group_color = 0xABCDEF, .group_depth = 1 });
    _ = try g.addPane(marker);
    const m1 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(m1);
    const m2 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(m2);
    const dst = try g.addWorkspace(w1, .{});
    _ = try g.addPane(dst);

    // 마커(index 0)를 window1로 옮긴다.
    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1);

    // 이동분 marker = 목적지에서 마커 아님(승계로 group_start 넘어감) + 최상위 카드.
    try testing.expect(marker.meta.group_start == null);
    try testing.expect(marker.meta.top_level);
    try testing.expect(marker.meta.group_color == 0);
    try testing.expect(!marker.meta.group_collapsed);
    // source: m1이 마커를 승계(그룹 잔존) — group_start·collapsed·color·depth 이전.
    try testing.expectEqual(@as(usize, 2), w0.workspaces.items.len);
    try testing.expect(m1.meta.group_start != null);
    try testing.expectEqualStrings("g", m1.meta.group_start.?);
    try testing.expect(m1.meta.group_collapsed);
    try testing.expectEqual(@as(u32, 0xABCDEF), m1.meta.group_color);
    try testing.expect(m2.meta.group_start == null); // m2는 여전히 멤버(위치 파생)
}

test "moveWorkspace §4(b) 소멸: 마지막 멤버 마커 이동 = 승계 불가 → 그룹 소멸 + 이동분 최상위" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: [plain(top-level card), marker(group_start="solo", 마지막 = 다음 카드 없음)]
    const plain = try g.addWorkspace(w0, .{});
    _ = try g.addPane(plain);
    const marker = try g.addWorkspace(w0, .{ .group_start = "solo" });
    _ = try g.addPane(marker);
    const dst = try g.addWorkspace(w1, .{});
    _ = try g.addPane(dst);

    // 마지막 카드인 마커(index 1)를 옮긴다 — 승계 대상(다음 카드) 없음 → 그룹 소멸.
    try g.moveWorkspace(.{ .win = 0, .ws = 1 }, 1);

    // 이동분 marker = 목적지 최상위(그룹 소멸로 마커 없음).
    try testing.expect(marker.meta.group_start == null);
    try testing.expect(marker.meta.top_level);
    // source: plain만 남고 그룹은 소멸(어떤 workspace도 group_start 없음).
    try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len);
    try testing.expect(plain.meta.group_start == null);
}

test "moveWorkspace §4(c): 전역 pinned 최상위 카드 이동 = pinned 유지(목적지 흡수 불가 — top_level)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: [pinned_top(pinned, 그룹 미소속 최상위 카드), other]
    const pinned_top = try g.addWorkspace(w0, .{ .pinned = true });
    _ = try g.addPane(pinned_top);
    const other = try g.addWorkspace(w0, .{});
    _ = try g.addPane(other);
    // dest에 기존 그룹 [d_marker, d_member] — 흡수 위험.
    const d_marker = try g.addWorkspace(w1, .{ .group_start = "dg" });
    _ = try g.addPane(d_marker);
    const d_member = try g.addWorkspace(w1, .{});
    _ = try g.addPane(d_member);

    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1);

    // (c) 전역 pin(그룹 미소속 최상위)은 이동해도 유지되고, top_level로 목적지 그룹에 흡수되지 않는다("고정 요소 흡수 불가").
    try testing.expect(pinned_top.meta.pinned);
    try testing.expect(pinned_top.meta.top_level);
    // 목적지에서 흡수 안 됨: dest 메타 뷰로 enclosing 마커가 null(그룹 밖)인지 확인.
    var metas: [3]*WorkspaceMeta = undefined;
    for (w1.workspaces.items, 0..) |w, i| metas[i] = &w.meta;
    try testing.expect(group_normalize.enclosingGroupMarkerIndex(WorkspaceMeta, &metas, 2) == null);
}

test "moveWorkspace §4(d): 그룹 멤버 local_pinned·pinned 이탈 = 리셋 + top_level 명시 set(목적지 append 흡수 방지)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: 고정 그룹 [marker(pin), m(pin, local_pinned)] — m은 그룹-로컬 pin된 멤버.
    const marker = try g.addWorkspace(w0, .{ .group_start = "g", .pinned = true });
    _ = try g.addPane(marker);
    const m = try g.addWorkspace(w0, .{ .pinned = true, .local_pinned = true });
    _ = try g.addPane(m);
    // dest에 기존 그룹 [d_marker, d_member] — m이 append-to-end로 이 그룹 뒤에 붙는다(흡수 위험).
    const d_marker = try g.addWorkspace(w1, .{ .group_start = "dg" });
    _ = try g.addPane(d_marker);
    const d_member = try g.addWorkspace(w1, .{});
    _ = try g.addPane(d_member);

    // 멤버 m(index 1)을 window1로 옮긴다.
    try g.moveWorkspace(.{ .win = 0, .ws = 1 }, 1);

    // (d) 이탈 리셋: local_pinned:=false·pinned:=false(그룹 멤버 unpin, §12.7 보강4)·top_level:=true(명시).
    try testing.expect(!m.meta.local_pinned);
    try testing.expect(!m.meta.pinned);
    try testing.expect(m.meta.top_level);
    // **top_level 명시 결정 검증**: dest는 [d_marker, d_member, m] append라, top_level=true가 아니면 m이 dg 그룹에
    // 위치 파생으로 흡수된다. enclosing 마커가 null이어야(그룹 밖) "목적지 최상위"가 성립 — top_level 명시 set의 근거.
    var metas: [3]*WorkspaceMeta = undefined;
    for (w1.workspaces.items, 0..) |w, i| metas[i] = &w.meta;
    try testing.expect(group_normalize.enclosingGroupMarkerIndex(WorkspaceMeta, &metas, 2) == null);
}

// 리뷰 [1]: 마커 승계는 **canonical(정규화된) source**에서만 성립한다 — inheritGroupMarker는 승계 대상 next가 마커와
// 같은 pin일 때만 이전한다. moveWorkspace가 비정규 source(마커 직후 pin-desync 멤버)를 그대로 먹이면 same-pin 게이트가
// 실패해 그룹이 통째 소멸한다(L4 closeTab/removeFromGroup은 항상 canonical에서 inherit — moveWorkspace만 어긋났다).
// 정규화-먼저 수정 전엔 red: desync 멤버가 마커를 승계 못 받아 group_start가 어디에도 안 남는다.
test "moveWorkspace §4(b) desync: 마커 직후 pin-desync 멤버가 있어도 마커 이동 시 그룹 보존(정규화-먼저)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    // source: 고정 그룹 [marker(group_start="g", pin=T), desync(pin=F, 마커와 어긋남), tail(pin=T)].
    // 마커 직후 첫 멤버가 desync라, canonical화 없이는 inheritGroupMarker의 same-pin 게이트를 통과 못 한다.
    const marker = try g.addWorkspace(w0, .{ .group_start = "g", .pinned = true });
    _ = try g.addPane(marker);
    const desync = try g.addWorkspace(w0, .{ .pinned = false });
    _ = try g.addPane(desync);
    const tail = try g.addWorkspace(w0, .{ .pinned = true });
    _ = try g.addPane(tail);
    const dst = try g.addWorkspace(w1, .{});
    _ = try g.addPane(dst);

    // 마커(index 0)를 window1로 옮긴다.
    try g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1);

    // 이동분 marker = 목적지 최상위 카드(승계로 group_start 넘어감).
    try testing.expect(marker.meta.group_start == null);
    try testing.expect(marker.meta.top_level);
    // **핵심(green)**: source를 먼저 canonical화(desync.pin := 마커 pin=T)한 덕에 desync가 마커를 승계 → 그룹 잔존.
    try testing.expectEqual(@as(usize, 2), w0.workspaces.items.len);
    try testing.expect(desync.meta.group_start != null); // 그룹 소멸하지 않고 desync가 이어받음
    try testing.expectEqualStrings("g", desync.meta.group_start.?);
    try testing.expect(desync.meta.pinned); // canonical화로 마커 pin(T) 승계
    try testing.expect(tail.meta.group_start == null); // tail은 여전히 위치 파생 멤버
    try testing.expect(tail.meta.pinned);
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

// ── OOM 안전(code-review max 반영): move는 append(fallible)를 remove(infallible) **앞에** 두므로, 목적지 append가
//    OOM으로 실패해도 source가 불변이라 SurfaceRef/노드 유실·leak이 없다. 아래는 fail_index=0으로 첫 alloc
//    (=빈 dst로의 append)을 실패시켜 그 불변식을 못박는다. leak이 생기면 deinit이 놓쳐 testing.allocator가 실패시킨다.

test "moveSurface OOM: append 실패면 SurfaceRef 유실 없이 source 불변" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p0 = try g.addPane(ws);
    const p1 = try g.addPane(ws); // 빈 pane — 첫 append가 반드시 alloc
    try g.addSurface(p0, 100);
    try g.addSurface(p0, 101);

    var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = fail.allocator();
    try testing.expectError(error.OutOfMemory, g.moveSurface(
        .{ .win = 0, .ws = 0, .pane = 0, .surface = 0 },
        .{ .win = 0, .ws = 0, .pane = 1 },
    ));
    g.allocator = testing.allocator; // deinit 복구

    try testing.expectEqual(@as(usize, 2), p0.surfaces.items.len); // 100,101 그대로(유실 없음)
    try testing.expectEqual(@as(u64, 100), p0.surfaces.items[0].surface_id);
    try testing.expectEqual(@as(usize, 0), p1.surfaces.items.len); // dst 비어 있음
}

test "movePane OOM: append 실패면 *Pane leak·유실 없이 source 불변" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws0 = try g.addWorkspace(w, .{});
    const ws1 = try g.addWorkspace(w, .{}); // 빈 workspace — 첫 append가 alloc
    const p = try g.addPane(ws0);
    try g.addSurface(p, 100);

    var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = fail.allocator();
    try testing.expectError(error.OutOfMemory, g.movePane(.{ .win = 0, .ws = 0, .pane = 0 }, .{ .win = 0, .ws = 1 }));
    g.allocator = testing.allocator;

    try testing.expectEqual(@as(usize, 1), ws0.panes.items.len); // 그대로(leak이면 testing.allocator가 실패)
    try testing.expectEqual(p, ws0.panes.items[0]);
    try testing.expectEqual(@as(usize, 0), ws1.panes.items.len);
}

test "moveWorkspace OOM: 정규화 temp/append 실패 둘 다 source 불변(구조 mutation 전 두 fallible 지점)" {
    // M3c로 moveWorkspace의 fallible 지점이 둘이다: (0) 정규화용 임시 `[]*WorkspaceMeta` 할당, (1) dest append.
    // 둘 다 **구조 mutation·정규화 전**이라 어느 쪽이 실패해도 source가 완전히 불변이다(temp는 defer로 free).
    inline for (.{ 0, 1 }) |fail_index| {
        var g = WindowGraph.init(testing.allocator);
        defer g.deinit();
        const w0 = try g.addWindow(1, .normal);
        const w1 = try g.addWindow(2, .normal); // 빈 window
        const ws = try g.addWorkspace(w0, .{});
        const p = try g.addPane(ws);
        try g.addSurface(p, 100);

        var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        g.allocator = fail.allocator();
        try testing.expectError(error.OutOfMemory, g.moveWorkspace(.{ .win = 0, .ws = 0 }, 1));
        g.allocator = testing.allocator;

        try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len); // 서브트리 그대로
        try testing.expectEqual(ws, w0.workspaces.items[0]);
        try testing.expectEqual(@as(usize, 0), w1.workspaces.items.len);
    }
}

test "mergeWindow OOM: append 실패면 leak 없이 부분 상태가 유효(모든 ws가 정확히 한 window에)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal); // src
    const w1 = try g.addWindow(2, .normal); // dst(빈) — 첫 append가 alloc
    const ws = try g.addWorkspace(w0, .{});
    const p = try g.addPane(ws);
    try g.addSurface(p, 100);

    var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = fail.allocator();
    try testing.expectError(error.OutOfMemory, g.mergeWindow(0, 1));
    g.allocator = testing.allocator;

    // 첫 append 실패 → src에 ws 그대로, src window 닫히지 않음(2창 유지), dst 비어 있음. 유효한 부분 상태.
    try testing.expectEqual(@as(usize, 2), g.windows.items.len);
    try testing.expectEqual(@as(usize, 1), w0.workspaces.items.len);
    try testing.expectEqual(ws, w0.workspaces.items[0]);
    try testing.expectEqual(@as(usize, 0), w1.workspaces.items.len);
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// collectWindowSurfaceIds: (a) out 버퍼가 모자라면 window_membership.collectVisibleSurfaces와 같은 조용한 절단
// (앞에서부터 채우고 멈춤), (b) 범위 밖 win_index는 InvalidCoordinate. 기존 결합 테스트는 늘 충분한 버퍼를 써
// 이 두 분기(`if (n >= out.len)`·`windowAt` 실패)를 안 밟았다.
test "collectWindowSurfaceIds: out 절단(모자란 버퍼) + 범위 밖 win_index는 InvalidCoordinate" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w = try g.addWindow(1, .normal);
    const ws = try g.addWorkspace(w, .{});
    const p = try g.addPane(ws);
    try g.addSurface(p, 100);
    try g.addSurface(p, 101);
    try g.addSurface(p, 102); // window 0 = {100,101,102}

    // 절단: out이 2칸뿐이면 앞 2개만.
    var small: [2]u64 = undefined;
    const got = try g.collectWindowSurfaceIds(0, &small);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualSlices(u64, &.{ 100, 101 }, got);
    // out.len==0 극단: 아무것도 안 쓰고 빈 slice.
    var none: [0]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), (try g.collectWindowSurfaceIds(0, &none)).len);
    // 범위 밖 window index → InvalidCoordinate.
    var buf: [8]u64 = undefined;
    try testing.expectError(error.InvalidCoordinate, g.collectWindowSurfaceIds(5, &buf));
}

// empty-source 정리 **전 계단**(pane→workspace→window)이 moveSurface 하나로 연쇄해 source window가 닫히고
// active_window가 목적지로 따라가는 경로. 기존 moveSurface 테스트는 전부 source에 resident surface를 남겨
// pane 정리에서 멈췄다 — surface 이동이 창을 통째로 닫는 full cascade는 안 밟혔다(focus 규칙 2→3 연쇄).
test "moveSurface full cascade: source의 마지막 surface가 빠지면 pane→ws→window가 연쇄 정리되고 active_window가 dst로 따라간다" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    // win0: 단일 ws/pane/surface(100). win1: ws/pane/surface(200).
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const p0 = try g.addPane(ws0);
    try g.addSurface(p0, 100);
    const ws1 = try g.addWorkspace(w1, .{});
    const p1 = try g.addPane(ws1);
    try g.addSurface(p1, 200);
    g.active_window = 0; // win0가 active(닫힐 것)

    // win0의 유일 surface(100)를 win1로 옮긴다 → win0의 pane·ws·window가 전부 비어 연쇄 제거.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 });

    try testing.expectEqual(@as(usize, 1), g.windows.items.len); // win0 닫힘.
    try testing.expectEqual(w1, g.windows.items[0]);
    try testing.expectEqual(@as(usize, 0), g.active_window); // 닫힌 win0(idx0) → dst win1로 따라감(shift 반영).
    // 이동한 surface는 win1의 pane에 append돼 active.
    try testing.expectEqual(@as(usize, 2), p1.surfaces.items.len);
    try testing.expectEqual(@as(u64, 100), p1.surfaces.items[1].surface_id);
    try testing.expectEqual(@as(usize, 1), p1.active_surface);
}

// removeWindow의 focus-follow 산술 `fib - @intFromBool(fib > idx)`의 **fib>idx 참 분기**: active였던 source가
// 닫히고 목적지가 source보다 **뒤 인덱스**에 있어 제거 shift로 당겨질 때. 기존 merge 테스트는 target이 source보다
// 앞(fib<idx)이라 이 분기를 안 밟았다.
test "mergeWindow focus-follow: 목적지가 source보다 뒤 인덱스여도 active_window가 정확히 따라간다(fib>idx 보정)" {
    var g = WindowGraph.init(testing.allocator);
    defer g.deinit();
    const w0 = try g.addWindow(1, .normal); // source(idx0, active, 닫힐 것)
    const w1 = try g.addWindow(2, .normal); // 방관자(idx1)
    const w2 = try g.addWindow(3, .normal); // target(idx2, source보다 뒤)
    const s0 = try g.addWorkspace(w0, .{});
    _ = try g.addPane(s0);
    const b0 = try g.addWorkspace(w1, .{});
    _ = try g.addPane(b0);
    const t0 = try g.addWorkspace(w2, .{});
    _ = try g.addPane(t0);
    g.active_window = 0; // source가 active

    try g.mergeWindow(0, 2); // source(idx0)를 target(idx2)로 merge → source 닫힘.

    // 남은 창: [w1, w2], w2는 idx1로 당겨짐. active_window는 target(w2=이제 idx1)로 따라간다.
    try testing.expectEqual(@as(usize, 2), g.windows.items.len);
    try testing.expectEqual(w1, g.windows.items[0]);
    try testing.expectEqual(w2, g.windows.items[1]);
    try testing.expectEqual(@as(usize, 1), g.active_window);
    // target에 자기 것 + source 것(순서 보존).
    try testing.expectEqual(@as(usize, 2), w2.workspaces.items.len);
    try testing.expectEqual(t0, w2.workspaces.items[0]);
    try testing.expectEqual(s0, w2.workspaces.items[1]);
}
