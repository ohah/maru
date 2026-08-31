//! workspace·window — 창 캡처/복원/이동, 창 종류·불투명도·드래그 영역, workspace 포커스와 범위 해석.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F10).
//!
//! **F 시리즈 중 ABI 비중이 가장 높다** — 24개 중 12개를 Swift 호스트가 직접 부른다. 창은 호스트가
//! 소유하고 Zig는 그 상태를 캡처·복원·질의하는 쪽이라 그렇다. 그 12개는 `app_session.zig`에 얇은
//! facade로 남고 본문만 여기로 온다.
//!
//! 이름 함정을 걸렀다.
//!   - `scmDrawWindow`: 이름은 window지만 `scm_scroll`을 보는 **SCM 뷰의 그리기 창**이다. 앱 창이 아니다.
//!   - `closeTargetHasRunningJob`·`writeEndedPlaceholderGuidance`: 창 닫기 흐름이 유일한 호출자지만
//!     본문은 터미널 종료 수명(실행 중 job 확인, ended placeholder 안내문)이다. 어느 그룹도 주장하지
//!     않는 교차 로직이라 허브에 남긴다.
//!
//! 파서 함정도 여기서 처음 잡았다 — `app_session.zig`에는 `AppSession` 말고도 최상위 struct가 있고
//! 그 메서드도 4칸 들여쓰기다(`ProviderEnvGuard.capture`·`MeasuredTextCache.store` 등 **12개**).
//! 이름만 보고 그룹을 잡으면 남의 struct 메서드를 끌어올 수 있다. F1~F9에서는 이름이 겹치지 않아
//! 사고가 없었지만(실측 0건), 이 그룹부터는 struct 소유를 보고 거른다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const scm_dock_ops = @import("scm_dock.zig"); // 고른 비교 기준을 세션에 되싣는다(§3.5 P7b)
const session_host = @import("../session_host.zig");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const setenv = app_session_mod.setenv;
const unsetenv = app_session_mod.unsetenv;
const usableRestoreCwd = app_session_mod.usableRestoreCwd;
const term_ops = @import("term.zig");
const notification_ops = @import("notification.zig");
const assertPinnedPrefixRuntime = @import("tab.zig").assertPinnedPrefixRuntime;
const file_tree_backend = app_session_mod.file_tree_backend;
const file_tree = app_session_mod.file_tree;
const preparePendingPasteTransfer = AppSession.preparePendingPasteTransfer;
const StructuralCompositionReservation = AppSession.StructuralCompositionReservation;
const RestoreAccountingSnapshot = AppSession.RestoreAccountingSnapshot;
const WorkspaceSession = AppSession.WorkspaceSession;
const agent_dock = app_session_mod.agent_dock;
const image_gallery_ops = @import("image_gallery.zig");
const config_mod = app_session_mod.config_mod;
const dock_panel = app_session_mod.dock_panel;
const pane_ops = @import("pane.zig");
const CloseScope = app_session_mod.CloseScope;
const PaneTree = app_session_mod.PaneTree;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const dock_ops = @import("dock.zig");
const file_panel_ops = @import("file_panel.zig");
const settings_ops = @import("settings.zig");
const sidebar_ops = @import("sidebar.zig");
const surface_move = app_session_mod.surface_move;
const tab_ops = @import("tab.zig");
const termLabel = app_session_mod.termLabel;
// close graph는 syscall 없는 scalar leaf라 ABI 교차 빌드에서도 실제 타입으로 분석해야 한다. 제품 backend
// 실행만 advanceWindowClose의 comptime macOS 가지가 소유한다.
const close_graph = app_session_mod.session_host.pending_term_close_graph;
const max_window_close_targets = app_session_mod.session_host.protocol.max_inventory_runtimes;

pub fn advanceSessionHostWindowGraph(self: *AppSession) void {
    self.session_host_window_graph_generation = std.math.add(
        u64,
        self.session_host_window_graph_generation,
        1,
    ) catch close_graph.fatalProofLoss();
}

/// rename 중인 대상 판정(렌더가 편집 텍스트로 라벨을 대체할 때 쓴다). 라이브 포인터 동일성 비교.
pub fn renamingWorkspace(self: *const AppSession, tab: *Tab) bool {
    const r = self.rename orelse return false;
    return switch (r) {
        .workspace => |t| t == tab,
        else => false,
    };
}

/// 워크스페이스 cascade(close_tab/close_term이 단일 pane에서 떨어질 때)를 범위로 해석한다 — split이면 활성 pane만
/// collapse, 단일 pane이면 탭(마지막 탭이면 세션 전체)을 닫는다. resolveCloseScope의 하위 단계(단일 출처).
pub fn resolveWorkspaceScope(self: *AppSession) CloseScope {
    if (pane_ops.activeTabHasSplit(self)) return .pane;
    if (self.tabs.items.len == 1) return .session;
    return .{ .tab = self.app_window.active_tab };
}

/// 빨간 닫기 버튼/창 단위 닫기 ABI(maru_macos_app_session_request_window_close)가 부른다. 실행 중 명령이 있으면
/// 확인 모달을 열고 true(deferred — Swift가 windowShouldClose에서 false 반환해 보류), 없으면 false(Swift가 평소대로
/// 닫음 → windowWillClose가 정리). pending은 .window로 두고 confirm_accept가 latchSessionClose로 마무리한다.
fn windowCloseTarget(term: *app_session_mod.Term) bool {
    return term_ops.hasClosablePty(term);
}

fn windowCloseGraphTarget(term: *app_session_mod.Term, preparing: bool) bool {
    if (preparing) return windowCloseTarget(term);
    return !std.meta.eql(term.rt.pending_close, close_graph.PendingTermClose{});
}

fn collectWindowCloseTargets(
    self: *AppSession,
    out: *[max_window_close_targets]close_graph.TargetProjection,
    preparing: bool,
) ?[]const close_graph.TargetProjection {
    var count: usize = 0;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!windowCloseGraphTarget(term, preparing)) continue;
        if (count == out.len) return null;
        const generation = if (preparing)
            std.math.add(u64, term.rt.close_generation, 1) catch return null
        else
            term.rt.close_generation;
        out[count] = .{
            .term_addr = @intFromPtr(term),
            .surface_id = term.surface.id,
            .handle = term.rt.handle,
            .term_close_generation = generation,
        };
        count += 1;
    };
    return out[0..count];
}

fn advanceWindowClose(self: *AppSession) maru.app.term_runtime_backend.CloseProgress {
    if (builtin.os.tag != .macos or app_session_mod.app_remote_backend == null) {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (!windowCloseGraphTarget(term, true)) continue;
            if (self.backendFor(term).closeAndDetach(term.rt.handle) == .event_pending) return .event_pending;
            term.rt.close_complete = true;
        };
        return .complete;
    }

    var target_storage: [max_window_close_targets]close_graph.TargetProjection = undefined;
    const graph_pristine = std.meta.eql(self.pending_window_close_graph, close_graph.PendingTermCloseGraph{});
    const targets = collectWindowCloseTargets(self, &target_storage, graph_pristine) orelse
        close_graph.fatalProofLoss();
    if (targets.len == 0) return .complete;

    const backend = &app_session_mod.app_remote_backend.?;
    if (graph_pristine) {
        // 모든 fallible readiness와 destination pristine 검증을 먼저 끝내야 뒤 target 실패가 앞 target routing을
        // 반쯤 tombstone하는 rollback 불가능 상태가 생기지 않는다.
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (!windowCloseGraphTarget(term, true)) continue;
            if (!std.meta.eql(term.rt.pending_close, close_graph.PendingTermClose{})) close_graph.fatalProofLoss();
            if (term.surface.remote != null) _ = backend.windowCloseReadiness(term.rt.handle);
        };
        const graph_generation = std.math.add(u64, self.next_window_close_graph_generation, 1) catch
            close_graph.fatalProofLoss();
        var remote_handles: [max_window_close_targets]u64 = undefined;
        var remote_count: usize = 0;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (!windowCloseGraphTarget(term, true) or term.surface.remote == null) continue;
            remote_handles[remote_count] = term.rt.handle;
            remote_count += 1;
        };
        var ticket_reservation: session_host.remote_term_backend.WindowCloseTicketReservation = .{};
        if (remote_count != 0)
            backend.reserveWindowCloseTickets(remote_handles[0..remote_count], &ticket_reservation) catch
                close_graph.fatalProofLoss();
        close_graph.prepareGraph(
            &self.pending_window_close_graph,
            @intFromPtr(self),
            self.close_session_generation,
            graph_generation,
            targets,
        ) catch close_graph.fatalProofLoss();
        close_graph.publishGraph(&self.pending_window_close_graph, targets) catch close_graph.fatalProofLoss();
        var target_index: usize = 0;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (!windowCloseTarget(term)) continue;
            term.rt.close_generation = targets[target_index].term_close_generation;
            close_graph.prepareTerm(
                &term.rt.pending_close,
                &self.pending_window_close_graph,
                targets[target_index],
                graph_generation,
            ) catch close_graph.fatalProofLoss();
            target_index += 1;
        };
        if (remote_count != 0)
            backend.publishWindowCloseAuthoritiesNoFail(remote_handles[0..remote_count], &ticket_reservation);
        self.next_window_close_graph_generation = graph_generation;
    } else if (!close_graph.validGraph(&self.pending_window_close_graph, @intFromPtr(self), targets)) {
        close_graph.fatalProofLoss();
    }

    var target_index: usize = 0;
    var pending = false;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!windowCloseGraphTarget(term, false)) continue;
        const target = targets[target_index];
        if (!close_graph.validTerm(&term.rt.pending_close, &self.pending_window_close_graph, target))
            close_graph.fatalProofLoss();
        const phase = std.enums.fromInt(close_graph.TermLifecycle, term.rt.pending_close.phase_raw) orelse
            close_graph.fatalProofLoss();
        if (phase == .backend_complete) {
            target_index += 1;
            continue;
        }
        const progress = self.backendFor(term).closeAndDetach(term.rt.handle);
        close_graph.advanceTerm(
            &term.rt.pending_close,
            &self.pending_window_close_graph,
            target,
            if (progress == .complete) .backend_complete else .backend_pending,
        ) catch close_graph.fatalProofLoss();
        if (progress == .complete) term.rt.close_complete = true else pending = true;
        target_index += 1;
    };
    if (pending) return .event_pending;
    target_index = 0;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!windowCloseGraphTarget(term, false)) continue;
        close_graph.advanceTerm(
            &term.rt.pending_close,
            &self.pending_window_close_graph,
            targets[target_index],
            .consumed,
        ) catch close_graph.fatalProofLoss();
        target_index += 1;
    };
    close_graph.advanceGraph(&self.pending_window_close_graph, targets, .complete) catch close_graph.fatalProofLoss();
    close_graph.advanceGraph(&self.pending_window_close_graph, targets, .consumed) catch close_graph.fatalProofLoss();
    tab_ops.destroyAllTabsForApprovedWindowClose(self);
    return .complete;
}

/// 확인을 이미 통과했거나 확인이 필요 없는 창 닫기를 한 단계 진행한다. pending이면 tick만 같은 요청을
/// 재시도하고, 모든 runtime이 complete가 된 뒤에만 programmatic window-close latch를 게시한다.
pub fn advancePendingWindowClose(self: *AppSession) void {
    if (!self.window_close_pending) return;
    if (advanceWindowClose(self) == .event_pending) return;
    self.window_close_pending = false;
    if (!self.ended_seen) self.latchSessionClose();
}

pub fn requestWindowClose(self: *AppSession) bool {
    if (file_panel_ops.blockSessionExitForFilePanels(self)) return true;
    if (self.window_close_pending) {
        advancePendingWindowClose(self);
        return !self.ended_seen;
    }
    if (!self.closeTargetHasRunningJob(.window)) {
        if (advanceWindowClose(self) == .complete) return false;
        self.window_close_pending = true;
        return true;
    }
    self.showConfirm(.app_close_window_running, .window);
    return true;
}

/// 실행 중 명령 확인을 수락한 window 요청을 일반 session latch로 우회시키지 않고 같은 runtime close graph에 넣는다.
pub fn confirmWindowClose(self: *AppSession) void {
    self.window_close_pending = true;
    advancePendingWindowClose(self);
}

/// 이 창의 trust 분류(§8A.5) — chrome_minimal이면 quick, 아니면 normal. cross-window 이동의 trust boundary
/// (`crossesTrustBoundary`) 판정에 쓴다. quick은 이동 단위에서 제외(§4)라 v1 실 경로는 normal↔normal뿐이지만,
/// revoke_caps guard+hook을 정확히 계산하려면 kind가 필요하다.
pub fn windowKind(self: *const AppSession) maru.session.WindowKind {
    return if (self.chrome_minimal) .quick else .normal;
}

/// `idx` 워크스페이스의 surface 수(범위 밖=0). moveWorkspaceToSession의 참 이동 개수(버퍼 절단과 무관, [6]).
pub fn workspaceSurfaceCount(self: *AppSession, idx: usize) usize {
    if (idx >= self.tabs.items.len) return 0;
    return tab_ops.tabSurfaceCount(self.tabs.items[idx]);
}

/// M3d-2b 단일 카드 이동 배선 — 활성 워크스페이스(탭) 인덱스(read-only). Swift 메뉴가 이 인덱스를
/// `moveWorkspaceToSession`(ABI move_workspace_to)에 넘겨 활성 카드 **하나**만 다른 창으로 옮긴다(merge는
/// 전체라 인덱스 불요). `app_window`는 `surface_initialized` 전엔 `undefined`(1215)라 그 전/탭 전무면 null —
/// 호출부(ABI)가 sentinel로 접어 Swift가 무동작. `activeTab()`과 같은 `app_window.active_tab` 활성 단일 출처.
pub fn activeWorkspaceIndex(self: *const AppSession) ?usize {
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    return self.app_window.active_tab;
}

/// M3d-2a-i 이동 **범위 게이트**(code-review [1]) — 이 워크스페이스가 라이브 이동 지원 범위 안인가. M3d-2a-i는
/// **비-그룹·비-pinned** 워크스페이스만 옮긴다(그룹 마커 문자열 free·pinned prefix 재정규화는 M3d-2a-ii). 범위 밖이면
/// `adoptTab`의 이탈 정규화(top_level/local_pinned만 리셋)로는 불변식(pinned prefix·그룹 파티션)이 깨져 다음 pin/group/
/// sidebar 연산의 `assertPinnedPrefixRuntime`가 패닉한다. 범위 밖 = **pinned**(전역 고정 프리픽스) or **group_start!=null**
/// (그룹 시작 마커) or **그룹 멤버**(enclosingGroupMarkerIndex != null). caller는 detach(비가역) **전에** 검사해 거부한다.
pub fn isMovableWorkspace(self: *const AppSession, idx: usize) bool {
    if (idx >= self.tabs.items.len) return false;
    const tab = self.tabs.items[idx];
    if (tab.pinned or tab.group_start != null) return false;
    return tab_ops.enclosingGroupMarkerIndex(self, idx) == null;
}

/// 라이브 cross-window workspace 이동(M3d-2a-i) — src의 `idx` 워크스페이스를 detach(무-destroy)해 dst에 adopt(무-재시작).
/// outcome을 라이브 수술 결과에서 **직접** 채운다(§1.3): cross_window=src!=dst · source_window_closed=cross-window로 src가
/// 빈 경우 · moved_surfaces=이동 서브트리의 surface_id(out_ids backing) · revoke_caps=cross_window && trust boundary 교차.
/// same-window(src==dst)면 reorder로 보존(재구현 아님). idx 범위 밖 or dst OOM이면 error — 원자성: dst capacity를 detach
/// **전에** 예약해 실패 시 source 불변(promotePaneToNewWorkspace 선례). 빈 source면 `ended_seen`을 직접 latch(§1.6 —
/// activeSurface 접근 없이; 실제 창 close는 M3d-2b Swift가 source_window_closed 신호로 수행).
pub fn moveWorkspaceToSession(src: *AppSession, dst: *AppSession, idx: usize, out_ids: []u64) !surface_move.MoveOutcome {
    if (idx >= src.tabs.items.len) return error.InvalidCoordinate;
    // 범위 게이트(code-review [1]): M3d-2a-i는 비-그룹·비-pinned 워크스페이스만. detach(비가역) **전에** 거부해 source
    // 불변(pinned/group 워크스페이스 이동은 M3d-2a-ii). 안 막으면 adoptTab의 부분 정규화가 pinned prefix·그룹 파티션을 깬다.
    if (!isMovableWorkspace(src, idx)) return error.UnsupportedMove;
    // 창당 경로 유일성(§1)은 merge뿐 아니라 **워크스페이스 이동**에도 적용된다 — 이 워크스페이스가 든
    // 파일이 destination에 이미 열려 있으면 이동 뒤 같은 경로가 두 Term으로 공존한다. detach(비가역)
    // 전에 거부한다. 병합처럼 자동 해소하지 않는 이유는 여기서는 **한 워크스페이스만** 옮기는 것이라
    // 어느 쪽을 닫아도 사용자가 고르지 않은 창이 바뀌기 때문이다(code-review max).
    if (src != dst) {
        for (src.tabs.items[idx].panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (file_panel_ops.fileEntryForPath(dst, entry.path) != null) {
                    // 거부는 조용하면 안 된다 — ABI는 move_failed로만 돌아가고 Swift는 그걸 그냥 흘린다.
                    src.showNoticeKey(.ws_move_target_has_file);
                    return error.UnsupportedMove;
                }
            }
        }
        if (file_panel_ops.fileEntryCount(dst) + file_panel_ops.countTabFileEntries(src.tabs.items[idx]) > dock_panel.max_entries) {
            src.showNoticeKey(.ws_move_target_tabs_full);
            return error.UnsupportedMove;
        }
        // 옮겨가는 파일을 destination 탐색기·watch 집합에 등록한다 — 안 하면 그 파일의 외부 변경
        // 감지가 죽고 최근 목록에도 안 뜬다(mergeFilePanelStateInto와 같은 계약, code-review max).
        try file_panel_ops.adoptMovedFileTermsIntoExplorer(dst, src.tabs.items[idx], src);
    }
    // before(수술 전, 순수): 이동 서브트리 surface_id 수집 + trust kind. surface_id는 이동 중 불변이라 순서만 안정하면 된다.
    const moved = tab_ops.collectTabSurfaceIds(src.tabs.items[idx], out_ids);
    const from_kind = windowKind(src);
    const to_kind = windowKind(dst);
    const cross_window = src != dst;
    // 원자성(§8A.3): dst capacity를 detach(비가역 src 수술) **전에** 예약 — 실패하면 src 불변. adoptTab도 자체 예약(dst
    // 단독 원자성)하지만, 이 pre-reserve가 두-세션 트랜잭션의 source 불변을 보장한다(예약됨 → adoptTab 내부 예약은 no-op).
    try dst.tabs.ensureUnusedCapacity(dst.allocator, 1);
    try dst.surface_ptrs.ensureUnusedCapacity(dst.allocator, 1);
    // 활성 input owner가 바뀌는 세션의 client-local preedit을 구조 수술 전에 원 surface로 확정한다.
    // cross-window는 active source가 떠날 수 있고 adoptTab이 destination의 active tab을 바꾸므로, 필요한
    // 양쪽 terminal queue capacity를 모두 먼저 예약한다. 둘째 예약 OOM 뒤 첫 owner만 확정되는 partial
    // commit을 막고, 어느 실패에서도 detach 전 양쪽 overlay/pin/queue의 논리 상태를 보존한다.
    const src_owner_changes = if (cross_window) idx == src.app_window.active_tab else idx != src.app_window.active_tab;
    const dst_owner_changes = cross_window;
    var src_composition: ?StructuralCompositionReservation = null;
    errdefer if (src_composition) |*reservation| reservation.rollback();
    var dst_composition: ?StructuralCompositionReservation = null;
    errdefer if (dst_composition) |*reservation| reservation.rollback();
    if (src_owner_changes) src_composition = try src.reserveCompositionForStructuralMove();
    if (dst_owner_changes) dst_composition = try dst.reserveCompositionForStructuralMove();
    // source composition을 commit하면 moved queue remainder가 늘 수 있다. 그 최댓값까지 destination
    // buffer를 먼저 확보해, 이 시점 이후에는 composition/queue/tree가 모두 infallible하게 전이된다.
    const source_extra_id = if (src_composition) |reservation| reservation.target_id else null;
    const source_extra_len = if (src_composition) |reservation| reservation.preedit_len else 0;
    var pending_transfer = try preparePendingPasteTransfer(
        src,
        dst,
        src.tabs.items[idx .. idx + 1],
        if (cross_window) source_extra_id else null,
        if (cross_window) source_extra_len else 0,
    );
    defer pending_transfer.deinit();
    if (src_composition) |*reservation| reservation.commit(!cross_window);
    if (dst_composition) |*reservation| reservation.commit(true);
    pending_transfer.capture(src, dst);
    pending_transfer.commit(dst);
    const tab = tab_ops.detachTabForMove(src, idx, false, cross_window).?; // 위에서 idx 검증 → non-null. 단일 이동이라 즉시 사이드바 재빌드.
    try tab_ops.adoptTab(dst, tab, false); // capacity 예약됨 → 무실패. insert+정규화+resize+trace 재지정.
    if (cross_window) {
        advanceSessionHostWindowGraph(src);
        advanceSessionHostWindowGraph(dst);
    }
    const source_closed = cross_window and src.tabs.items.len == 0; // §1.6: cross-window로 src가 비었나
    if (source_closed) src.ended_seen = true; // 빈 source 종료 latch(직접 — activeSurface 안 만짐, 실제 close는 M3d-2b)
    return .{
        .moved_surfaces = moved,
        .from_window = @intCast(@intFromPtr(src)), // opaque window_id(§1 — 라우팅 키 아님). M3d-2b가 Swift window_id로 대체.
        .to_window = @intCast(@intFromPtr(dst)),
        .cross_window = cross_window,
        .revoke_caps = cross_window and surface_move.crossesTrustBoundary(from_kind, to_kind),
        .source_window_closed = source_closed,
    };
}

/// 고정 시작 디렉터리(config `workspace.root`)를 spawn cwd로 해석한다 — **첫 창**과, inherit 토글이 꺼졌거나
/// 상속할 포커스 cwd가 없을 때의 폴백. 설정돼 있으면 `~` 확장·절대경로 필터(resolveWorkspaceRoot)를 거치고,
/// 비어 있으면 launch cwd를 상속하되 그게 `/`이면 $HOME으로 올린다(homeForRootCwd — .app 더블클릭 친절).
/// null이면 자식이 maru의 cwd를 그대로 상속한다. 결과 슬라이스는 `buf`(또는 config arena)에 묶이므로 호출자는
/// spawn이 끝날 때까지 `buf`를 살려 둔다. $HOME·getcwd 같은 env/I/O는 platform layer만 아는 값이라 여기서 읽는다.
pub fn workspaceRootCwd(self: *const AppSession, buf: []u8) ?[]const u8 {
    const home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
    const configured = self.loaded_config.config.workspace.root;
    if (configured.len > 0) return resolveWorkspaceRoot(buf, configured, home);
    // 미설정: launch cwd 상속이 기본. 단 launch cwd가 `/`였으면(.app 더블클릭) home으로 올린다. `/` 판정은
    // init에서 한 번 캐시한 launch_cwd_is_root를 쓴다 — maru는 자기 cwd를 안 바꿔 새 탭/분할마다 getcwd 불요.
    return homeForRootCwd(buf, self.launch_cwd_is_root, home);
}

/// 마지막 복원이 조용히 버린 항목 수를 소비한다(읽고 0으로 리셋 — 다른 take_* 게터와 같은 규약). Swift는 apply
/// 성공 직후 이걸 읽어 0이 아니면 checkpoint 차단 래치를 세운다. 소비형인 이유: 창마다 apply가 따로 호출되므로
/// 창별 결과를 누적 없이 봐야 하고, 한 번 읽은 뒤 남겨 두면 다음 창의 판정을 오염시킨다.
pub fn takeWorkspaceRestoreDropped(self: *AppSession) u32 {
    const dropped = self.workspace_restore_dropped;
    self.workspace_restore_dropped = 0;
    return dropped;
}

pub fn focusWorkspaceInput(self: *AppSession) void {
    dock_ops.cancelPendingDockFocus(self);
    // A terminal/body click takes the keyboard owner away from the archive list.  Without
    // releasing that ownership, Enter/PageUp/PageDown would keep driving an open dock while
    // the user was visibly typing in the workspace terminal.
    agent_dock.releaseAgentSessionDockKeyFocus(self);
    image_gallery_ops.releaseKeyFocus(self);
    self.agent_session_dock_interaction.capture = null;
    self.focus_owner = .workspace;
    self.workspace_focus_pending = false;
    self.file_tree_focus_pending = false;
    self.file_tree_restore_surface_pending = null;
    self.metal_dirty = true;
}

pub fn takeWorkspaceFocusAction(self: *AppSession) bool {
    const pending = self.workspace_focus_pending;
    self.workspace_focus_pending = false;
    return pending;
}

/// 창의 **어느 탭에든** web Term이 있나(FrameSummary.web_surfaces_present 원천). **유지 카운터가 아니라 매 tick
/// 트리에서 계산**한 신호라 창 간 이동(moveWorkspaceToSession=detach/adopt 포인터 relocate, destroy/create 없음)·
/// 재부모화·닫기 어느 경로에도 트리가 단일 출처로 자동 정합한다(옛 유지 카운터는 이동에서 원본 stuck-high·대상
/// stuck-0으로 드리프트했다). alloc-free 재귀.
///
/// FP16c로 `collectWebSurfaces` 수집 범위가 창 전체가 됐으므로 presence 신호도 같은 범위여야
/// 한다 — 활성 탭만 보면 비활성 워크스페이스의 첫 web surface 생성 전이가 영영 미적용된다(FP3이 도크에서
/// 실측으로 겪은 것과 같은 결함).
pub fn windowHasWebTerm(self: *AppSession) bool {
    if (!self.surface_initialized or self.tabs.items.len == 0) return false;
    for (self.tabs.items) |tab| {
        if (PaneTree.anyLeaf(tab.tree, pane_ops.paneHasWebTerm)) return true;
    }
    return false;
}

/// 이 창의 전체 Term 수. 병합 계획이 "이만큼 닫으면 창이 빈다"를 누적으로 판정할 때 쓴다.
pub fn windowTermCount(self: *const AppSession) usize {
    var n: usize = 0;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| n += pane.terms.items.len;
    }
    return n;
}

/// 세팅 GUI에서 시작 디렉터리(workspace.root) 커밋 — loader와 같은 형식 규칙(`loader.isValidWorkspaceRoot`)으로
/// 검증해 드리프트를 막는다(config-gui.md §1·§6.6a). 빈 값=상속 cwd로 클리어, 절대경로/`~`는 저장(arena dupe),
/// 상대경로·`~user`는 무시+안내. `~` 확장·존재 검증은 spawn 시점(resolveWorkspaceRoot)이 하므로 여기선 형식만 본다.
/// root는 셸 spawn 시점에만 쓰이므로 라이브 재적용 없이 dirty만 찍는다(다음 새 Term부터 — shell.args/env와 같은 결).
pub fn setWorkspaceRoot(self: *AppSession, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.loaded_config.config.workspace.root = ""; // 클리어 → 상속 cwd(기본)
        settings_ops.markConfigKeyDirty(self, "workspace.root");
        return;
    }
    if (!config_mod.loader.isValidWorkspaceRoot(trimmed)) {
        self.chrome_host.settings.setMessage(maru.i18n.t(.ws_cwd_must_be_absolute));
        return;
    }
    const owned = self.loaded_config.arena.allocator().dupe(u8, trimmed) catch return;
    self.loaded_config.config.workspace.root = owned;
    settings_ops.markConfigKeyDirty(self, "workspace.root");
}

/// 이 워크스페이스의 **모든 Term**을 트리 순서(Pane 순회 → Pane 안 Term 순서)로 모은다.
/// 상태나 시각으로 재정렬하지 않는다 — 같은 자리의 세션이 상태 변화마다 목록에서 튀면 클릭 대상이 흔들린다(§2).
///
/// **에이전트만이 아니라 터미널도 낸다**(사용자 결정 2026-08-11 — docs/sidebar-agent-list.md §2). 예전엔
/// `agent_kind == .none`을 걸러 에이전트만 행이 됐고, 그래서 에이전트를 안 돌리는 터미널은 목록에 존재하지
/// 않았다. "화면에 안 보이는 것을 없는 것처럼 만들지 않는다"는 §2의 원칙은 에이전트만의 것이 아니다 —
/// 가려진 탭의 터미널도 PTY도 프로세스도 살아 있다.
///
/// **한 Term은 한 행이다.** 에이전트를 돌리는 Term은 `agent_kind != .none`이라 에이전트 행으로 그려지고,
/// 같은 Term이 터미널 행으로 또 나오지 않는다 — "터미널이 에이전트를 실행 중이면 에이전트만 보인다"는
/// 요구가 별도 중복 제거 없이 이 1:1 규율에서 그대로 나온다.
///
/// **kind로도 거르지 않는다**(사용자 결정 2026-08-11). 브라우저 Term과 파일·마크다운 Term도 그 워크스페이스가
/// 들고 있는 것이고, 가려진 탭에 있으면 터미널과 똑같이 "없는 것처럼" 보인다. 그래서 이 목록의 축은
/// "무엇이 돌고 있는가"가 아니라 **"이 워크스페이스가 무엇을 들고 있는가"**다. PTY가 없는 Term은 관측이
/// `availability == .unavailable`이라 폴더·브랜치 줄이 자연히 비어 라벨 한 줄로 줄어든다 — 행 규칙을 분기하지
/// 않고 같은 경로를 탄다(`refreshTermObservation`도 `kind != .terminal`에서 이미 early-return한다).
pub fn collectWorkspaceSessions(tab: *Tab, out: *std.ArrayList(WorkspaceSession), allocator: std.mem.Allocator) void {
    for (tab.panes.items, 0..) |pane, pi| {
        for (pane.terms.items, 0..) |_, ti| {
            out.append(allocator, .{ .pane = pi, .term = ti }) catch return; // OOM: 이번 투영만 짧게(다음 rebuild가 복구)
        }
    }
}

/// 창 뒤 배경 블러의 **유효 반경**(px). config `window.blur`를 그대로 주되, `window.opacity >= 1`이면(불투명 창 —
/// 뒤가 안 비쳐 블러가 보이지 않음) 0으로 깎는다. 이 게이트 정책이 Zig 단일 출처고, platform host는 이 값을
/// 그대로 OS 창 속성에 싣는다(macOS=CGS, 추후 Win=DWM·Linux=컴포지터). Ghostty `ghostty_set_window_background_blur`가
/// `background-opacity >= 1.0`에서 early-return하는 게이트와 동등. (F3-1)
pub fn windowBlurRadius(self: *const AppSession) u32 {
    return effectiveWindowBlur(self.loaded_config.config.window_blur, self.loaded_config.config.window_opacity);
}

/// 창 제목으로 보여줄 문자열(OSC 0/2 제목 우선, 없으면 cwd basename, 둘 다 없으면 빈 슬라이스).
/// 우선순위 로직은 core가 소유한다(native 최소) — Swift는 받아서 빈값이면 앱 이름으로 폴백만.
/// 반환은 core 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효하다(별도 복사 없음).
pub fn windowTitle(self: *AppSession) []const u8 {
    if (!self.surface_initialized) return &.{};
    // 4e: 활성 Term이 web이면 sentinel core엔 OSC 제목이 없어 빈값이 나온다 — kind 파생 라벨("Browser"/
    // "Markdown", custom_name 우선)을 창 제목으로 쓴다(termLabel 단일 해석). terminal 경로는 그대로.
    if (!term_ops.activeTermIsTerminal(self)) return termLabel(pane_ops.activePane(self).activeTerm());
    const term = pane_ops.activePane(self).activeTerm();
    term_ops.refreshTermObservation(self, term, false, false);
    if (term.rt.observation.availability == .unavailable) return &.{};
    return term.rt.observation.window_title.items;
}

pub fn captureWorkspaceWindow(self: *AppSession, arena: std.mem.Allocator, is_active: bool, frame: ?maru.session.workspace.Frame) !maru.session.workspace.Window {
    var tabs: std.ArrayList(maru.session.workspace.Tab) = .empty;
    for (self.tabs.items) |tab| try tabs.append(arena, try tab_ops.captureWorkspaceTab(self, arena, tab));
    const dock = if (self.dock_initialized) try file_panel_ops.persistFilePanelState(self, arena) else dock_panel.PersistedState{};
    const explorer_roots: ?[]const []const u8 = if (self.file_tree_initialized and self.file_tree.rootMode() == .explicit) blk: {
        const roots = try arena.alloc([]const u8, self.file_tree.rootCount());
        for (roots, 0..) |*root, i| root.* = try arena.dupe(u8, self.file_tree.rootAt(i).?);
        break :blk roots;
    } else null;
    // 고른 비교 기준(§3.5 P7b). 세션이 든 짝을 그대로 낸다 — 저장 쪽 검사(절대 경로·ref 형태·중복)는
    // `workspace.serialize`가 다시 걸므로 여기서 또 판정하지 않는다(같은 규칙이 두 곳에 살지 않게).
    const scm_bases = try arena.alloc(maru.session.workspace.ScmBase, self.scm_base_len);
    for (scm_bases, self.scm_base_entries[0..self.scm_base_len]) |*out, entry| {
        out.* = .{ .repo = try arena.dupe(u8, entry.repo), .base = try arena.dupe(u8, entry.base) };
    }
    return .{ .active_tab = self.app_window.active_tab, .active = is_active, .frame = frame, .tabs = try tabs.toOwnedSlice(arena), .dock = dock, .explorer = .{ .roots = explorer_roots }, .scm_bases = scm_bases };
}

/// 이 창의 workspace 블록(헤더 없는 `window …` 텍스트)을 직렬화해 세션-소유 버퍼로 돌려준다(R5 저장 ABI).
/// 캡처는 임시 arena로 하고, 결과 텍스트만 self.allocator로 보관한다(다음 호출/deinit까지 유효 — cwd ABI와
/// 같은 소유 규칙). Swift가 멀티 창 저장에서 세션마다 호출해 `maru.workspace.v1` 헤더 아래로 모은다.
pub fn serializeWorkspaceWindow(self: *AppSession, is_active: bool, frame: ?maru.session.workspace.Frame) ![]const u8 {
    if (self.workspace_buffer) |b| {
        self.allocator.free(b);
        self.workspace_buffer = null;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const win = try captureWorkspaceWindow(self, arena.allocator(), is_active, frame);
    const text = try maru.session.workspace.serializeWindow(self.allocator, win);
    self.workspace_buffer = text;
    return text;
}

/// 저장된 workspace 모델(한 창)을 이 세션에 적용해 탭/pane split 트리/Term을 재생성한다(R4 복원). 일반 live
/// 세션은 init이 만든 모델을 교체하고, 시작 restore용 deferred 세션은 빈 모델에 첫 publish한다. runtime-handle이
/// 살아 있으면 기존 host runtime에 attach하고, handle이 없는 선언적 surface만 저장 cwd에서 새 셸을 spawn한다.
/// title/command는 정적 기본(셸이 OSC 0/2로 곧 재설정)·size는 모델값(이후 resize가 창에 맞게 보정). 새 탭들을
/// 먼저 다 빌드한 뒤 기존 탭을 teardown하고 swap한다 — 빌드 실패면 새 것만 정리하고 기존 live 모델 또는 deferred
/// 빈 상태를 보존한다. 빈 모델은 live 세션에선 무동작, deferred 세션에선 오류다. 빈 cwd spawn은 기본 cwd를 쓴다.
pub fn applyWorkspaceWindow(self: *AppSession, win: maru.session.workspace.Window) !void {
    if (win.tabs.len == 0) {
        if (!self.surface_initialized) return error.EmptyWorkspace;
        return;
    }
    // 공개 ABI가 시작 복원 외의 라이브 세션에도 호출될 수 있으므로, old dock을 교체하기 전에 보호 중인
    // CM6/close/reload/mutation 상태를 fail-close한다. 새 모델 준비 뒤 검사하면 외부 작업과의 사이에 폐기
    // window가 생기므로 admission의 첫 read-only gate로 둔다.
    if (self.hasProtectedFilePanelsForExit() or file_panel_ops.hasFilePanelCloseTransition(self) or file_panel_ops.fileTreeNamespaceMutationBusy(self))
        return error.UnsupportedMove;

    // restore build가 OOM/후속 surface 실패로 publish되지 않으면 후보 Term이 올린 notice/drop 회계도 존재하지 않았던
    // 일이어야 한다. 모델 교체와 같은 transaction에 묶어 다음 tick/재시도에 유령 count가 남지 않게 한다.
    const restore_accounting_before = RestoreAccountingSnapshot.capture(self);
    errdefer restore_accounting_before.restore(self);

    var new_dock = try dock_panel.DockPanel.restore(self.allocator, &app_session_mod.app_runtime.entry_ids, win.dock);
    var new_dock_owned = true;
    errdefer if (new_dock_owned) new_dock.deinit();
    // 복원이 **조용히 버리는 것 셋**(손상된 파일 패널 entry, 그 결과로 비워진 dock 그룹, 접근 불가 explorer root)을
    // 한 지역 변수에 모아 성공 publish 뒤 세션 필드로 넘긴다. 실패 경로에서는 기록하지 않는다 — 창 apply 자체가
    // 실패하면 Swift가 이미 checkpoint 차단 래치를 세우므로 신호가 중복이고, errdefer 롤백과 순서를 다툴 이유도 없다.
    var dropped: usize = 0;
    const newly_ended_before = self.ended_placeholder_dropped_pending;
    dropped += file_panel_ops.pruneInvalidRestoredFilePanelEntries(self, &new_dock);
    // FP16 2-2r: 여기서 소유를 목록으로 옮긴다. 이후 단계(파일 트리·watcher·rows)는 dock 구조가 아니라
    // 이 목록을 소비하고, 실제 배치(어느 pane의 Term이 되나)는 탭이 생긴 뒤에 정한다.
    var restored_entries = try dock_ops.flattenRestoredDock(self.allocator, &new_dock);
    // 성공 경로에서도 backing buffer를 반납해야 한다 — 이관이 소유를 가져가도 ArrayList 자체는 남는다.
    // 이관이 건너뛰어진 경우(탭 0개)엔 path 문자열까지 여기서 회수된다.
    defer restored_entries.deinit(self.allocator);
    for (restored_entries.items.items) |*entry| {
        if (entry.surface_id == 0) entry.surface_id = self.surface_ids.next();
    }

    // Explorer roots, watcher union, projected rows, and backend lifetime are staged before the
    // first live tab/dock teardown. Missing or inaccessible persisted roots degrade only that root;
    // allocation failure leaves the whole current session untouched.
    var new_file_tree = file_tree.Tree.init(self.allocator);
    var new_file_tree_owned = true;
    errdefer if (new_file_tree_owned) new_file_tree.deinit();
    {
        for (restored_entries.items.items) |entry| {
            const root = try file_tree_backend.projectRootForFile(self.allocator, self.io, entry.path);
            defer self.allocator.free(root);
            try new_file_tree.recordOpened(entry.path, root);
        }
    }
    // 기억해 둔 비교 기준을 되싣는다(§3.5 P7b). **저장소가 지금 있는지는 안 본다** — 없는 저장소의
    // 기억은 화면에 아무 영향이 없고(그 저장소를 열 때만 쓰인다), 여기서 지우면 잠시 마운트가 빠진
    // 외장 디스크의 저장소 기억이 조용히 사라진다.
    for (win.scm_bases) |entry| {
        if (!scm_dock_ops.rememberScmBase(self, entry.repo, entry.base)) break; // 상한을 넘으면 거기서 멈춘다
    }
    if (win.explorer.roots) |roots| {
        var validated: [file_tree.max_roots]file_tree_backend.ValidatedRoot = undefined;
        var validated_len: usize = 0;
        defer for (validated[0..validated_len]) |*root| root.deinit(self.allocator, self.io);
        for (roots) |root_path| {
            const root = try file_tree_backend.validateRootSnapshot(self.allocator, self.io, root_path) orelse {
                dropped += 1; // 미존재·접근 불가 root는 그 root만 버리고 복원을 계속한다 — 버린 사실은 위로 알린다.
                continue;
            };
            validated[validated_len] = root;
            validated_len += 1;
        }
        var canonical: [file_tree.max_roots][]const u8 = undefined;
        for (validated[0..validated_len], 0..) |root, i| canonical[i] = root.path;
        try new_file_tree.replaceExplicitRoots(canonical[0..validated_len]);
        for (validated[0..validated_len]) |root| _ = new_file_tree.pinRootIdentity(root.path, root.identity);
    }
    try file_panel_ops.resetFileTreeWatchRootsForEntries(&new_file_tree, restored_entries.items.items, null);
    var new_file_tree_backend = try file_tree_backend.Backend.init(self.allocator, self.io);
    var new_file_tree_backend_owned = true;
    errdefer if (new_file_tree_backend_owned) new_file_tree_backend.deinit();
    var new_file_tree_open_states: std.ArrayList(file_tree.OpenState) = .empty;
    defer new_file_tree_open_states.deinit(self.allocator);
    var new_file_tree_rows: std.ArrayList(file_tree.Row) = .empty;
    defer new_file_tree_rows.deinit(self.allocator);
    // 활성 해소는 pane 배치(`transferRestoredFileEntries`)와 **같은 규칙**이어야 한다 — 영속된 활성이
    // 검증에서 버려졌으면 첫 유효 entry가 활성이다. 두 곳이 갈리면 pane은 A를 보여 주는데 트리는
    // 아무것도 활성으로 안 칠하는 어긋남이 난다(code-review max).
    if (restored_entries.items.items.len != 0 and restored_entries.active_index == null)
        restored_entries.active_index = 0;
    try file_panel_ops.buildFileTreeRowsForEntries(
        self.allocator,
        restored_entries.items.items,
        restored_entries.active_index,
        &new_file_tree,
        &new_file_tree_open_states,
        &new_file_tree_rows,
    );

    // 1) 새 탭들을 먼저 다 빌드한다(아직 self.tabs에 안 넣음 — 실패하면 기존 세션 그대로 유지).
    var new_tabs: std.ArrayList(*Tab) = .empty;
    defer new_tabs.deinit(self.allocator);
    errdefer for (new_tabs.items) |t| tab_ops.destroyTabStandalone(self, t);
    try new_tabs.ensureTotalCapacity(self.allocator, win.tabs.len);
    for (win.tabs) |tab_model| {
        new_tabs.appendAssumeCapacity(try tab_ops.buildWorkspaceTab(self, tab_model));
    }
    try assignEndedManifestOrdinals(new_tabs.items, win);

    // 2) swap이 실패하지 않게 컬렉션 capacity를 미리 잡는다(teardown 뒤 append가 무실패여야 half-state가 없다).
    // FP16 2-2r: 탭이 다 생긴 지금이 배치 시점이다. staged 목록의 entry를 **활성 워크스페이스의 활성 pane**에
    // 파일 Term으로 이관한다(§5.0 마이그레이션 규칙 — dock-entry는 창 레벨 키라 pane별 배치 정보가 없다).
    // 아직 staged 구간이라 실패하면 errdefer가 새 탭과 목록을 함께 되돌린다.
    if (restored_entries.items.items.len != 0 and new_tabs.items.len != 0) {
        const target_tab = new_tabs.items[@min(win.active_tab, new_tabs.items.len - 1)];
        const target_pane = target_tab.panes.items[@min(target_tab.active_pane, target_tab.panes.items.len - 1)];
        try file_panel_ops.transferRestoredFileEntries(self, &restored_entries, target_pane);
    }
    try self.tabs.ensureTotalCapacity(self.allocator, new_tabs.items.len);
    try self.surface_ptrs.ensureTotalCapacity(self.allocator, new_tabs.items.len);

    // 여기까지 왔으면 뒤의 publish는 무실패다. staging provenance를 지워 이후 사용자 close가 기존 runtime을 정상
    // terminate하게 한다. 이 지우기 전의 모든 errdefer는 attach-only runtime을 detach로 rollback한다.
    for (new_tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| term.rt.restored_existing = false;
        }
    }

    // 3) 기존 탭 teardown(closeTab의 teardown과 같은 순서 — 마지막-탭 latch는 안 탄다) 후 새 탭 설치.
    for (self.tabs.items) |tab| tab_ops.destroyTabStandalone(self, tab);
    self.tabs.clearRetainingCapacity();
    self.surface_ptrs.clearRetainingCapacity();
    for (new_tabs.items) |tab| {
        self.tabs.appendAssumeCapacity(tab);
        self.surface_ptrs.appendAssumeCapacity(tab.activePane().activeTerm().surface);
    }
    self.app_window.tabs = self.surface_ptrs.items;
    self.app_window.active_tab = @min(win.active_tab, self.tabs.items.len - 1);
    // deferred restore 세션은 이 publish 지점까지 PTY/surface/frame loop가 0개였다. 저장 모델의 Term들이 모두
    // stage된 뒤에만 첫 surface를 활성화하므로 성공 복원은 throwaway fresh shell을 만들지 않는다.
    term_ops.finishInitialSurface(self);
    file_panel_ops.resetFilePanelTransientStateForDockReplacement(self);
    if (self.dock_initialized) self.dock.deinit();
    self.dock = new_dock;
    self.dock_initialized = true;
    new_dock_owned = false;
    var old_file_tree = self.file_tree;
    var old_file_tree_backend = self.file_tree_backend;
    var old_file_tree_open_states = self.file_tree_open_states;
    var old_file_tree_rows = self.file_tree_rows;
    self.file_tree = new_file_tree;
    self.file_tree_backend = new_file_tree_backend;
    self.file_tree_open_states = new_file_tree_open_states;
    self.file_tree_rows = new_file_tree_rows;
    new_file_tree_owned = false;
    new_file_tree_backend_owned = false;
    new_file_tree_open_states = .empty;
    new_file_tree_rows = .empty;
    old_file_tree_backend.deinit();
    old_file_tree.deinit();
    old_file_tree_open_states.deinit(self.allocator);
    old_file_tree_rows.deinit(self.allocator);
    file_panel_ops.advanceFileTreeProjectionGeneration(self);
    self.file_tree_rows_dirty = false;
    self.file_tree_watch_reset_pending = true;
    // **트리를 통째로 갈았으니 따라가기 기억도 버린다**(ET-CWD — docs/file-explorer.md §1). 남겨 두면
    // "이 cwd는 이미 따라갔다"로 읽혀, 복원된 root가 활성 터미널과 다른데도 `cd` 전까지 따라가지 않는다.
    if (self.file_tree_followed_cwd) |prev| self.allocator.free(prev);
    self.file_tree_followed_cwd = null;
    // 고정-prefix 불변식 강제(복원): clampMoveToGroup/countPinnedTabs는 "고정 탭이 앞쪽 [0, pinned_count)에
    // 연속"을 가정한다. 저장 순서를 그대로 복원하면(재정렬 안 함) #685 이전 빌드가 만든 [P,u,P,u]처럼 섞인
    // workspace가 들어와 드래그/토글 clamp가 엉뚱한 슬롯에 떨어진다. 여기서 stable-partition으로 고정을 전부
    // 앞으로 모은다(고정끼리·비고정끼리 상대 순서 유지). 불변식을 모든 진입 경로(토글·드래그·복원)에서 성립시킨다.
    // 복원 순서(그룹 고정 C2, docs/sidebar-groups-pinning.md §12.5·§12.9 GP2): **(1)탭 설치→(2)normalize→(3)stablePartition**.
    // stablePartition 앞에 normalizePinnedFromGroups를 명시 호출해, 손상/레거시 혼합 파일(멤버 pinned=1·마커=0, 또는 마커
    // pinned=1·멤버=0 desync)을 **마커 기준 canonical**로 흡수한 뒤(멤버 pinned := enclosing 마커 pinned) stablePartition이
    // 고정 그룹을 **통째** 프리픽스로 모은다(정규화 누락 시 마커만 앞으로 가 그룹 shred가 실패 모드). 여긴 드래그 없는
    // 시작/재적용 경로라 게이트(sidebar_drag_preview==null)는 자명히 통과한다.
    // 복원된 활성 파일에 publish 대기 barrier를 건다. `resetFilePanelTransientStateForDockReplacement`가
    // 위에서 transient를 전부 지우므로 **커밋 뒤**여야 한다 — 라이브 열기와 같은 계약이라, typed ack
    // 전까지 PTY·paste·close가 새 WKWebView 대신 터미널로 잘못 라우팅되지 않는다.
    if (file_panel_ops.activeFileEntry(self)) |restored_active| dock_ops.requestDockEntryFocus(self, restored_active);
    self.normalizePinnedFromGroups();
    tab_ops.stablePartitionPinned(self);
    self.floatLocalPinsAllGroups(); // 복원 로컬 pin 재float(GL §13.4 배선 (3) — 복원 특례도 항상 stablePartitionPinned 뒤, local-pinned 영속 반영)
    // 트리·탭을 통째로 교체했으니 해제된 옛 트리를 가리키던 상호작용 포인터를 비워야 하는데, 위 destroyTabStandalone
    // 루프의 destroyPane이 invalidateForFreedPane(S1 chokepoint)으로 옛 Pane을 가리키던 호버·드래그 포인터를 이미
    // 비웠다(표적 무효화라 옛 Pane을 가리키던 tab_drag_pane도 포함). 지금은 시작 전용이라 드래그가 없지만,
    // mid-session 재적용(repo별 workspace 후속)에서도 같은 chokepoint가 UAF를 막는다 — 따로 리셋하지 않는다.
    // 복원된 모든 탭을 현재 창 grid로 맞춘다. apply는 resize를 안 부르고 각 surface는 저장 grid로 spawn되며,
    // caller의 resizeAppSessionFromWindow→resize()는 (활성 탭만 + last_resize_size dedup) 배경 탭과 primary
    // 활성 탭을 빠뜨린다. 여기서 전 탭을 명시적으로 맞춰 dedup·활성탭-한정을 둘 다 우회한다(best-effort).
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    // §7 묘비 안내는 **resize 뒤**에 쓴다 — 최종 pane 폭이 정해진 다음이어야 reflow로 줄이 어긋나지 않는다.
    // 멱등 래치가 있어 재적용에도 덧쓰지 않는다. 비-묘비 Term은 함수 첫 줄에서 no-op이다.
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| self.writeEndedPlaceholderGuidance(term);
        }
    }
    // 활성 탭의 대표 surface는 위 swap 루프가 이미 surface_ptrs[*]에 바인딩했고 active_pane도 빌드 때
    // 세팅됐다(focusPane(active==active)는 early-return no-op이라 호출하지 않는다). 좌표·사이드바만 갱신.
    pane_ops.recomputeActivePaneRect(self);
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
    // publish가 끝난 뒤에만 기록한다(실패 경로는 창 apply 실패로 이미 신호가 있다). Swift가 apply 성공 직후
    // take_workspace_restore_dropped로 소비해 0이 아니면 이번 실행의 checkpoint를 마지막 완전본 백업 뒤에 쓴다.
    dropped += self.ended_placeholder_dropped_pending - newly_ended_before;
    self.workspace_restore_dropped = std.math.lossyCast(u32, dropped);
    if (builtin.mode == .Debug) assertPinnedPrefixRuntime(self); // 복원 후 불변식 확인(디버그)
}

/// Reconciliation numbers only runtime-bound Workspace surfaces, in Window/Tab/Pane/surface order.
/// Bind that same ordinal to each staged durable tombstone before the graph is published. The full
/// handle remains necessary but is not sufficient: CR6b must replace the exact reserved slot.
fn assignEndedManifestOrdinals(tabs: []*Tab, win: maru.session.workspace.Window) !void {
    var manifest_index: usize = 0;
    for (win.tabs) |tab_model| for (tab_model.panes) |pane_model| for (pane_model.surfaces) |surface| {
        if (surface.runtime_id.len == 0) continue;
        if (manifest_index >= maru.session.runtime_reconcile.max_runtime_bindings)
            return error.TooManyBindings;
        if (surface.runtime_state == .ended) {
            var found: ?*Term = null;
            for (tabs) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
                if (!term.rt.ended_placeholder or
                    !std.mem.eql(u8, term.rt.ended_runtime_host_id, surface.runtime_host_id) or
                    !std.mem.eql(u8, term.rt.ended_runtime_id, surface.runtime_id)) continue;
                if (found != null) return error.InvalidRuntimeIdentity;
                found = term;
            };
            const tomb = found orelse return error.InvalidRuntimeIdentity;
            tomb.rt.ended_manifest_index = app_session_mod.recoveredEndedManifestIndexForRestore(
                surface.runtime_host_id,
                surface.runtime_id,
            ) orelse std.math.maxInt(u16);
        }
        manifest_index += 1;
    };
}

/// `window.opacity`(0~1)를 chrome **배경** alpha 바이트(0~255)로 환산한다 — 1.0이면 0xFF(불투명, 회귀 없음).
/// 터미널 기본 배경만 투명해지던 iTerm2/Ghostty `background-opacity` 모델을 사이드바·탭 바 **배경**까지 확장하는
/// 단일 출처다(사용자 요청 "사이드 탭까지 투명"). 전경 텍스트·아이콘·accent 막대·divider·focus 테두리는 배경이
/// 아니므로 이 경로를 안 거치고 `packOpaqueRgb`로 불투명 유지한다 — 텍스트 가독성과 포커스 단서를 보존한다.
pub fn windowOpacityByte(self: *const AppSession) u8 {
    return @intFromFloat(@round(std.math.clamp(self.appearance.window_opacity, 0.0, 1.0) * 255.0));
}

/// (x,y backing px)가 창 chrome의 '빈' 영역(아이콘·검색·접힘 버튼이 아닌 곳)인가. Swift가 1이면 네이티브 타이틀바처럼
/// 창 이동(performDrag)·더블클릭 확대(zoom)를 한다. MaruMetalTerminalView는 mouseDownCanMoveWindow=false라(터미널/
/// 사이드바가 자체 마우스 사용) 콘텐츠 자동 드래그가 없고, 여기만 창 드래그 영역이다. 두 부분:
///   ① 사이드바 헤더(펼침, 좌측)의 빈 영역 — headerHit==.none(아이콘·검색 제외, 신호등 옆 빈 공간 포함).
///   ② 상단 타이틀바 띠(터미널 위·접힘 시 전체)의 빈 영역 — y<titlebar_strip_px, 접힘 ◧ 펼치기 버튼은 제외(클릭).
/// quick terminal(chrome_minimal — 신호등 없는 borderless)이면 항상 false.
pub fn isWindowDragRegion(self: *const AppSession, x_px: f64, y_px: f64) bool {
    if (self.chrome_minimal) return false;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px) or y_px < 0) return false;
    // ① 사이드바 헤더(펼침): 3줄 헤더의 빈 영역.
    if (self.sidebar_width_px > 0 and self.sidebar_header_height_px > 0 and sidebar_ops.inSidebar(self, x_px)) {
        if (y_px >= @as(f64, @floatFromInt(self.sidebar_header_height_px))) return false;
        return chrome.components.sidebar.headerHit(x_px, y_px, self.sidebar_width_px, self.cell_width_px, self.cell_height_px, self.sidebar_header_height_px, sidebar_ops.sidebarSearchBandTopPx(self)) == .none;
    }
    // ② 상단 타이틀바 띠(터미널 위, 또는 접힘 시 전체 폭): 한 줄. 접힘 ◧ 펼치기 버튼·알림 종 위면 드래그 아님(클릭).
    if (self.titlebar_strip_px > 0 and y_px < @as(f64, @floatFromInt(self.titlebar_strip_px))) {
        if (self.collapsedToggleRect()) |r| {
            const rx: f64 = @floatFromInt(r.x);
            if (x_px >= rx and x_px < rx + @as(f64, @floatFromInt(r.w))) return false;
        }
        if (notification_ops.collapsedNotificationRect(self)) |r| {
            const rx: f64 = @floatFromInt(r.x);
            if (x_px >= rx and x_px < rx + @as(f64, @floatFromInt(r.w))) return false; // 접힘 종 클릭 영역 — 창 드래그 아님
        }
        if (file_panel_ops.filePanelDockControlRect(self)) |r| {
            const rx: f64 = @floatFromInt(r.x);
            if (x_px >= rx and x_px < rx + @as(f64, @floatFromInt(r.w))) return false; // 도크 접힘 펼치기 토글(우상단) — 창 드래그 아님(안 제외하면 클릭이 performDrag로 새 토글이 안 눌린다)
        }
        return true;
    }
    return false;
}

/// 리네임 caret 줄 수 계산용 — workspaceStatusLine이 non-empty 상태줄을 낼지 텍스트 생성 없이 순수 판정한다(caret은
/// 파형 문자열이 필요 없고, runningStatusLine 할당·spinner 조회를 피한다). 에이전트가 있으면 unknown도
/// "상태 확인 중"을 표시한다. 위 workspaceStatusLine의 non-empty 조건과 반드시 동기다.
pub fn workspaceHasStatusLine(tab: *Tab) bool {
    return tab_ops.tabAgentRepresentative(tab) != null;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// config `workspace.root`(시작 창·새 워크스페이스 탭 전용)를 spawn cwd로 해석한다. 빈 값이면 null(상속
// cwd로 spawn — maru를 띄운 디렉터리). `~`·`~/…`는 `home`($HOME)으로 확장해 `buf`에 쓰고 그 슬라이스를
// 돌려준다(확장 없으면 `configured`를 그대로 빌린다 — loaded_config arena가 세션 동안 소유). 최종 형식 필터는
// **usableRestoreCwd 단일 출처에 위임**한다(빈/과길이/비절대 → null) — 상대경로를 넘기면 자식이 앱 cwd 기준으로
// chdir해 예측 불가. 존재·디렉터리 여부는 검사하지 않는다 — childExec가 chdir 실패 시 $HOME으로 graceful 폴백한다
// (TOCTOU 회피, usableRestoreCwd와 같은 결). 반환 슬라이스는 `buf`가 살아 있는 동안(=spawn 호출까지) 유효하다.
// loader는 raw 문자열만 보관하므로 env 의존(`~` 확장)을 여기 platform layer에서 처리한다.
pub fn resolveWorkspaceRoot(buf: []u8, configured: []const u8, home: ?[]const u8) ?[]const u8 {
    if (configured.len == 0) return null;
    var path = configured;
    // `~` 단독 또는 `~/…`를 $HOME으로 확장한다(셸의 tilde expansion은 셸을 안 거치는 execve엔 안 일어난다).
    // $HOME이 없거나(드묾) **빈 문자열/상대경로**면 확장 못 하므로 null(상속 cwd) — `~`로 시작하는 상대경로를
    // 그대로 넘기지 않는다. 빈 home 가드가 핵심: getenv는 `HOME=""`도 non-null로 주므로 `home orelse`만으론
    // 빈 home이 통과해 `~/proj`가 `/proj`(절대경로처럼 보임)로 오해석된다. isAbsolute("")==false라 한 검사로 둘 다 막는다.
    if (std.mem.eql(u8, configured, "~") or std.mem.startsWith(u8, configured, "~/")) {
        const h = home orelse return null;
        if (!std.fs.path.isAbsolute(h)) return null; // 빈/상대 home → 확장 불가(폴백 spawn)
        const rest = configured[1..]; // "" 또는 "/…"
        path = std.fmt.bufPrint(buf, "{s}{s}", .{ h, rest }) catch return null; // 너무 길면 null(폴백 spawn)
    }
    return usableRestoreCwd(path); // 절대경로·길이 필터(단일 출처 재사용 — 비절대/과길이는 null)
}

// config `workspace.root` **미설정** 시 첫 창/폴백 cwd를 정한다. maru의 launch cwd가 `/`였으면(`launch_is_root`
// — .app 더블클릭·launchd·open으로 뜬 흔한 증상) `home`(절대경로)을 `buf`에 써서 돌려주고, 그 외(정상 cwd·home
// 없음/상대·`/` 아님)는 null(=launch cwd를 그대로 상속). Ghostty가 launchd/open 실행을 `home`으로 보는 것과 같은
// 결인데, 침습적 런처 감지 대신 "cwd가 `/`" 증상으로 좁혀 잡는다(터미널에서 띄운 정상 세션은 cwd가 `/`가 아니라
// 그대로 상속). `launch_is_root`는 init에서 getcwd로 한 번만 판정해 주입한다(maru는 자기 cwd를 안 바꿔 시작 시
// 한 번이면 충분 — 새 탭/분할마다 getcwd 시스템콜을 반복하지 않는다). 그래서 이 함수는 I/O 없이 순수(테스트 가능).
pub fn homeForRootCwd(buf: []u8, launch_is_root: bool, home: ?[]const u8) ?[]const u8 {
    if (!launch_is_root) return null; // 정상 cwd면 그대로 상속(폴백 안 함)
    const h = home orelse return null;
    if (!std.fs.path.isAbsolute(h) or h.len > buf.len) return null;
    @memcpy(buf[0..h.len], h);
    return buf[0..h.len];
}

/// 창 뒤 배경 블러(window.blur, F3-1)의 **유효 반경**(px). config 반경을 그대로 주되, 창이 불투명(opacity>=1)이면
/// 뒤가 안 비쳐 블러가 보이지 않으므로 0으로 깎는다 — Ghostty `ghostty_set_window_background_blur`가
/// `background-opacity >= 1.0`에서 early-return하는 게이트와 동등. 이 정책이 단일 출처고, platform host(macOS=CGS,
/// 추후 Win=DWM·Linux=컴포지터)는 반환값을 그대로 OS 창 속성에 싣는다. 순수 함수라 헤드리스 단위 테스트 가능.
pub fn effectiveWindowBlur(blur: u32, opacity: f32) u32 {
    if (blur == 0) return 0;
    if (opacity >= 1.0) return 0; // 불투명 창 — 블러 안 보임
    return blur;
}

/// provider fixture 테스트가 실제 사용자 홈·설정·캐시를 건드리지 않도록 관련 env를 저장했다가 되돌린다. 이 테스트들은
/// **실 파일시스템에 쓰는** 경로를 검증하므로 tmp로 밀어 넣는 것이 필수다.
pub const ProviderEnvGuard = struct {
    const names = [_][:0]const u8{ "HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "MARU_CONFIG" };

    a: std.mem.Allocator,
    saved: [names.len]?[:0]u8 = .{null} ** names.len,

    pub fn capture(a: std.mem.Allocator) !ProviderEnvGuard {
        var self = ProviderEnvGuard{ .a = a };
        for (names, &self.saved) |name, *slot| {
            if (std.c.getenv(name.ptr)) |raw| slot.* = try a.dupeZ(u8, std.mem.span(raw));
        }
        return self;
    }

    pub fn restore(self: *ProviderEnvGuard) void {
        for (names, self.saved) |name, old| {
            if (old) |value| {
                _ = setenv(name.ptr, value.ptr, 1);
                self.a.free(value);
            } else {
                _ = unsetenv(name.ptr);
            }
        }
    }
};
