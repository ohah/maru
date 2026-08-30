//! term · surface — 터미널 생성/파괴, surface 등록과 조회, 포커스 이동, 종료 처리,
//! 세션 복원 어댑터.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F16).
//! **가장 마지막에 남겨 둔 그룹**이다 — `Term`과 `Surface`는 거의 모든 도메인이 참조하는 핵심 타입이라
//! 이름으로 잡으면 다른 그룹의 진입점이 대량으로 딸려온다.
//!
//! 실제로 후보 55개 중 15개를 걸렀다.
//!   - **얇은 facade 9개**(자동): `activeWebSurfaceId`·`hasWebSurface`·`webSurfaceTransition*`(→web, F11),
//!     `markNotificationsReadBySurface`(→notification, F13), `workspaceSurfaceCount`(→workspace, F10),
//!     `termRect`(→dock, F5). F15에서 넣은 "유효 코드 3줄 이하 + `_ops.` 호출" 규칙이 손대지 않고 잡았다.
//!   - **내용이 남의 도메인인 6개**: `activateExistingFileTerm`·`diffSidesForSurface`·
//!     `focusFilePanelSurface`·`setFilePanelModeBySurface`·`takeFileTreeRestoreSurfaceAction`(→file_panel, F2),
//!     `pendingDockFocusSurface`(→dock, F5).
//!
//!   - **소유권 게이트가 고정한 3개**: `ensureRestoreHostAdapter`·`logRestoreAdapterInitFailure`·
//!     `backendForNew`. `tests/boundary/imports.zig`의 "CR3a-1 ownership capabilities stay in their
//!     exact production boundaries"가 `RemoteSessionAdapter.initInPlace(`의 호출 위치를 **파일 단위로**
//!     고정한다. 옮기면 그 게이트가 깨지므로 허브에 남긴다 — 게이트를 느슨하게 하는 쪽이 아니라
//!     경계를 지키는 쪽을 골랐다.
//!
//! 남은 것이 진짜 term·surface 수명이다 — 만들고, 등록하고, 찾고, 포커스를 옮기고, 죽은 것을 거두고,
//! 복원 어댑터를 세운다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const buildPastePreview = AppSession.buildPastePreview;
const session_host = app_session_mod.session_host;
const diag_gate = app_session_mod.diag_gate;
const paste_confirm_key = AppSession.paste_confirm_key;
const markHostConnectFailedError = app_session_mod.markHostConnectFailedError;
const freeDiffEntryState = app_session_mod.freeDiffEntryState;
const ensureRestoreHostAdapter = app_session_mod.ensureRestoreHostAdapter;
const classifyAttachError = AppSession.classifyAttachError;
const barMetrics = app_session_mod.barMetrics;
const is_macos = app_session_mod.is_macos;
const layout_math = app_session_mod.layout_math;
const PaneTree = app_session_mod.PaneTree;
const TermBarLoc = AppSession.TermBarLoc;
const activeIndexAfterRemoval = app_session_mod.activeIndexAfterRemoval;
const dock_ops = @import("dock.zig");
const file_panel_ops = @import("file_panel.zig");
const renderer = app_session_mod.renderer;
const settings_ops = @import("settings.zig");
const web_ops = @import("web.zig");
const Pane = app_session_mod.Pane;
const SurfaceClosedCallback = app_session_mod.SurfaceClosedCallback;
const Term = app_session_mod.Term;
const TermLoc = AppSession.TermLoc;
const agent_ops = @import("agent.zig");
const app = app_session_mod.app;
const pane_ops = @import("pane.zig");
const editor_ops = @import("editor.zig");
const tab_ops = @import("tab.zig");
const git_ops = @import("git.zig");
const terminal = app_session_mod.terminal;
const usableRestoreCwd = app_session_mod.usableRestoreCwd;
const workspace_ops = @import("workspace.zig");

/// 첫 live tab이 준비된 뒤에만 renderer/frame loop를 세운다. 일반 init과 deferred workspace apply가 공유해
/// "세션 생성 → throwaway shell → restore" 경로를 만들지 않는다.
pub fn finishInitialSurface(self: *AppSession) void {
    if (self.surface_initialized) return;
    std.debug.assert(self.tabs.items.len > 0);
    self.surface_initialized = true;
    // 상태줄 훅을 config에 맞춘다(설치/복원). 사용자 파일을 건드리는 유일한 자리라 시작 시 한 번만 조정하고,
    // config를 다시 적용할 때 같은 함수가 다시 맞춘다.
    agent_ops.removeAgentStatuslineHook(self);
    // provider 훅도 같은 자리에서 맞춘다(docs/agent-hooks.md §5). 게이트가 꺼져 있으면 그 함수가 즉시 나간다.
    agent_ops.reconcileAgentHooks(self);
    // 지난 실행이 남긴 이벤트 로그를 지운다 — **게이트와 무관**하고 **시작할 때만** 돈다(계약 §4.2).
    agent_ops.cleanupAgentHookLogs(self);
    ensureRendererState(self);
    self.frame_loop = app.AppFrameLoop.init(
        self.allocator,
        &self.app_window,
        self.runtime,
        &pane_ops.activePane(self).activeTerm().rt.pump,
        &self.renderer_state,
        self.io,
    );
    self.frame_loop_initialized = true;
    pane_ops.recomputeActivePaneRect(self);
}

/// RendererState는 terminal frame뿐 아니라 0-tab Recovered Sessions chrome의 CoreText/atlas도
/// 소유한다. live Term 생성과 결속하지 않아야 복구 선택기를 그리려고 placeholder PTY를 만들 필요가 없다.
pub fn ensureRendererState(self: *AppSession) void {
    if (self.renderer_initialized) return;
    self.renderer_state = renderer.RendererState.init(self.allocator, .{});
    self.renderer_initialized = true;
}

pub fn renamingTerm(self: *const AppSession, term: *Term) bool {
    const r = self.rename orelse return false;
    return switch (r) {
        .term => |t| t == term,
        else => false,
    };
}

/// term이 속한 pane의 바·그 탭 인덱스(rename caret 위치 계산용). 못 찾으면 null.
pub fn termBarLocation(self: *AppSession, term: *Term) ?TermBarLoc {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return null;
    for (leaf_rects.items) |lr| {
        // 보이는 순서(드래그 중이면 preview)로 찾는다 — 이 위치는 탭 세그먼트 기하의 근거라 paint와 같은
        // 순서를 써야 한다(§4.4).
        for (pane_ops.paneTermOrder(self, lr.leaf), 0..) |t, ti| {
            if (t == term) {
                const pb = pane_ops.paneBar(self, lr.rect, lr.leaf) orelse return null;
                return .{ .pb = pb, .tab_index = ti, .count = lr.leaf.terms.items.len, .scroll = lr.leaf.tab_scroll_cols };
            }
        }
    }
    return null;
}

/// layout grid를 이 Term에 적용하는 **단일 출처**.
///
/// **계약**: 이 함수가 돌아온 뒤 그 Term의 **표시 grid(core)는 항상 레이아웃 크기**다. runtime(PTY winsize·
/// 원격 host)에 전달하지 못하면 그 실패를 error로 **보고**하되, 표시 grid는 그래도 맞춘다. 이 비대칭이
/// 핵심이다 — 렌더러는 셀을 `pane origin + col×cell_w`로만 두고 **pane 클리핑이 없어서**
/// (maru_metal_renderer.m의 셀 패스에는 scissor가 없다), 옛 grid가 남은 Term은 divider를 넘어 **옆 pane
/// 글자 위에 겹쳐 그려진다**. 즉 "runtime에 못 보냈다"는 표시 grid를 낡은 채 두어도 되는 근거가 아니다.
///
/// PTY 없는/못 미치는 Term의 갈래를 여기서 모두 갈라, 호출부가 `kind == .web` 스킵을 각자 복사하지 않게 한다.
/// - web(4e-2 §6): sentinel이고 WKWebView frame은 surfaceDiff가 따로 sync하므로 대상이 아니다(no-op).
/// - §7 종료 placeholder: live link가 없어 `SurfaceRuntime.resize`가 `UnknownSurface`를 낸다(runtime.zig).
///   묘비는 **렌더는 해야 하므로** 그냥 스킵하면 저장 grid에 갇혀 창 크기와 어긋난 화면이 남는다.
/// - 자식이 끝난 Term(`process_state == .exited`)·link가 사라진 Term(host runtime 사망): runtime이 dead
///   adapter로의 라우팅을 **문서화된 계약대로** 거부한다([surface-runtime-api.md]). 거부는 runtime 쪽 사실일 뿐
///   레이아웃 사실이 아니므로, 표시 grid는 여기서 직접 맞춘다.
pub fn resizeTermForLayout(self: *AppSession, term: *Term, size: terminal.Size) app.RuntimeError!void {
    // PTY가 없는 갈래는 runtime에 보낼 것이 없다. 편집기는 뷰 크기를 자기 프레임 빌드에서 읽는다(N1 §4).
    if (term.kind == .web or term.kind == .editor) return;
    if (term.rt.ended_placeholder) {
        resizeTermCoreToLayout(self, term, size);
        return;
    }
    self.runtime.resize(term.surface.id, size, self.io) catch |err| {
        // `UnknownSurface`/`ProcessExited`는 core에 닿기 전에 반환되므로 표시 grid가 옛 크기로 남는다.
        // `ResizeFailed`(core는 이미 적용, PTY ioctl만 실패)에서도 같은 값을 다시 적용할 뿐이라 무해하다.
        resizeTermCoreToLayout(self, term, size);
        return err;
    };
}

/// 표시 grid(core)만 레이아웃 크기로 맞춘다 — PTY winsize·trace recorder 없이 **reflow만**. 묘비(§7)와
/// runtime 전달 실패가 같은 코드를 쓰게 해, "표시 grid는 레이아웃이 소유한다"는 규칙의 구현이 한 곳에 있게 한다.
pub fn resizeTermCoreToLayout(self: *AppSession, term: *Term, size: terminal.Size) void {
    const grid = terminal.clampGridSize(size); // runtime.resize와 같은 clamp(core는 cols>=2를 요구)
    {
        term.surface.lockCore(self.io);
        defer term.surface.unlockCore(self.io);
        term.surface.core.resize(grid.cols, grid.rows) catch return; // OOM이면 기존 grid 유지(표시만 영향)
    }
    // 관측 캐시도 함께 옮긴다. 묘비는 `live_initialized == false`라 `refreshTermObservation`이 즉시 반환하므로
    // 여기서 갱신하지 않으면 생성 시 심은 저장 grid에 영원히 갇힌다 — `captureWorkspaceTab`은 core.size보다
    // observation.size를 **우선**하므로, 창을 키운 채 종료하면 예전 grid가 저장되고 다음 실행의 새 셸이 창과
    // 다른 winsize로 떠 시작 프로그램이 잘못된 기하로 레이아웃한다(code-review). 살아 있는 Term에서도 같은
    // 이유로 맞춰 둔다(runtime이 살아나면 `refreshTermObservation`이 곧 자기 값으로 덮는다).
    term.rt.observation.size = grid;
}

/// 활성 pane 안에서 보이는 Term(가로 탭)을 term_index로 바꾼다(탭 전환). 활성 Term surface를 탭
/// 대표(`surface_ptrs[active_tab]` = `app_window.active()`)에 재바인딩하고 좌표 origin을 다시 계산한다.
/// 같은 Term이거나 범위 밖이면 무동작. pane/워크스페이스는 안 바꾼다.
/// #2(#505 리뷰): 활성 Term이 가로 스크롤 창 밖이면 보이도록 tab_scroll_cols를 조정한다(focusTerm·⌘[]·클릭 후).
/// 안 넘침(has_scroll=false)이면 무동작. 활성 탭 좌단이 창보다 왼쪽이면 좌단으로, 우단이 창보다 오른쪽이면 우단이 보이게.
pub fn ensureActiveTermVisible(self: *AppSession, pane: *Pane) void {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        if (lr.leaf != pane) continue;
        const pb = pane_ops.paneBar(self, lr.rect, pane) orelse return;
        const m = barMetrics(pb.tabs, self.cell_width_px, pane.terms.items.len, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return;
        if (!m.has_scroll) return; // 안 넘침 — 다 보임
        // **드래그 중에는 스크롤을 건드리지 않는다.** 보이는 슬롯은 preview 공간인데 `tab_scroll_cols`는
        // model-영속 상태라, 그 값으로 옮겨 두면 순서가 복원돼도 스크롤만 남아 바가 아무것도 가리키지 않는
        // 구간에 머문다(복원 트리거는 순서와 `active_term`만 되돌린다). 손을 뗀 뒤 다음 `focusTerm`이
        // model 기준으로 맞춘다 — 끌고 있는 동안 바가 스스로 스크롤하지 않는 편이 조작에도 방해가 없다.
        if (tab_ops.tabDragTransaction(self, pane) != null) return;
        const abs_start = @as(u32, @intCast(pane.active_term)) * m.tab_w;
        if (abs_start < m.scroll_cols) {
            pane.tab_scroll_cols = abs_start; // 좌단 잘림 → 좌단이 보이게
        } else if (abs_start + m.tab_w > m.scroll_cols + m.tab_cols) {
            pane.tab_scroll_cols = abs_start + m.tab_w - m.tab_cols; // 우단 잘림 → 우단이 보이게
        }
        return;
    }
}

pub fn focusTerm(self: *AppSession, term_index: usize) void {
    const pane = pane_ops.activePane(self);
    if (term_index >= pane.terms.items.len or pane.active_term == term_index) return;
    self.commitComposition(); // 새 Term으로 확정 바이트/preedit이 넘어가지 않게 target pin을 먼저 비운다.
    self.invalidatePositionalPendingClose(); // 닫기 모달 보류 중 Term 이동 → 보류 무효화(stale 대상 close 방지)
    pane.active_term = term_index;
    self.surface_ptrs.items[self.app_window.active_tab] = pane.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    ensureActiveTermVisible(self, pane); // #2(리뷰): 스크롤 밖 탭 선택 시 보이게 tab_scroll_cols 조정
    // pane 안 탭 전환도 파일의 가시성을 바꾼다 — 보이지 않게 된 파일의 publish 대기 barrier를 여기서
    // 버린다(워크스페이스 전환·창 병합과 같은 규칙, code-review max).
    dock_ops.dropPendingDockFocusIfHidden(self);
    self.file_tree_rows_dirty = true; // 활성 파일이 바뀌었을 수 있다 — 트리 활성 마커 갱신
    pane_ops.recomputeActivePaneRect(self);
    self.metal_dirty = true;
    self.workspaceChanged(.selection);
}

/// 활성 pane의 Term을 delta(+1=다음, -1=이전)만큼 wrap-around로 옮긴다(⌘⌥]/⌘⌥[). Term이 1개면 무동작.
/// **이동은 보이는 순서에서 센다** — 드래그 중이면 탭 바가 preview 순서를 그리므로, model 인덱스로 세면
/// "오른쪽 다음 탭"이 화면에서 인접하지 않은 탭이 된다(§4.4 "보이는 것이 조작되는 것").
pub fn focusTermRelative(self: *AppSession, delta: i64) void {
    const pane = pane_ops.activePane(self);
    const n = pane.terms.items.len;
    if (n <= 1) return;
    const order = pane_ops.paneTermOrder(self, pane);
    if (order.len != n) return;
    const cur: i64 = @intCast(pane_ops.paneActiveTermIndex(self, pane));
    const next_slot: usize = @intCast(@mod(cur + delta, @as(i64, @intCast(n))));
    // 고른 것은 슬롯이고 `focusTerm`은 model 인덱스를 받는다.
    focusTerm(self, termModelIndex(self, pane, order[next_slot]) orelse return);
}

/// 모든 탭/panel/Term을 순회해 predicate가 처음 참인 Term의 위치를 돌려준다(없으면 null). reap 대상 찾기
/// (findTerminatedTerm)와 알림 클릭 역조회(activateSurfaceById)가 같은 3중 순회를 공유하는 단일 출처다 —
/// 순회 규칙(탭→panel→Term, 첫 매치 반환)이 한 곳에만 있어 갈릴 여지가 없다. 반환한 *Pane은 heap-pin이라
/// 트리 변형 전까지 안정. predicate는 comptime이라 호출부마다 인라인된다(함수 포인터 간접호출 없음).
pub fn findTermWhere(self: *AppSession, context: anytype, comptime pred: fn (@TypeOf(context), *Term) bool) ?TermLoc {
    for (self.tabs.items, 0..) |tab, ti| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items, 0..) |term, tj| {
                if (pred(context, term)) return .{ .tab_index = ti, .pane = pane, .term_index = tj };
            }
        }
    }
    return null;
}

/// 모든 탭/panel을 훑어 첫 'terminated'(셸 exit 관측 완료) Term의 위치를 찾는다(reap 대상). 없으면 null.
/// §7 종료 placeholder는 **후보에서 제외**한다. 묘비는 `terminated=false`로 만들어지므로 지금도 걸리지 않지만,
/// reap은 사용자 확인 없이 Term을 닫고 마지막 Term이면 탭까지 닫으므로(closeTermAt → 캐스케이드) 복원해 놓은
/// 레이아웃이 조용히 사라지는 경로다. 방어적으로 명시해 나중에 누가 묘비를 terminated로 표시해도 안전하게 둔다.
pub fn findTerminatedTerm(self: *AppSession) ?TermLoc {
    return findTermWhere(self, {}, struct {
        fn pred(_: void, term: *Term) bool {
            return term.rt.terminated and !term.rt.ended_placeholder;
        }
    }.pred);
}

/// 셸이 exit한 개별 Term을 자동으로 닫는다(exit 자동 collapse, PR5b). 살아있는 Term이 하나라도
/// 있으면 죽은 Term을 **Term → pane(빈 pane collapse) → 워크스페이스(빈 탭 close)** cascade로 정리한다.
/// 전부 죽었으면(단일/마지막 Term) reap하지 않고 세션 종료 latch(allTabsTerminated)에 맡긴다 — 기존 단일 탭
/// exit→창 닫힘 동작을 보존. 구조가 매번 바뀌므로 한 번에 하나씩 닫고 다시 스캔한다(stale 인덱스/포인터 방지).
/// guard는 폭주 backstop(정상이면 죽은 Term 수만큼만 돈다). tick의 drain이 종료를 관측한 뒤 부른다.
pub fn reapTerminatedTerms(self: *AppSession) void {
    if (self.termination_finished) return;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        if (self.allTabsTerminated()) return; // 전부 죽음 → 세션 종료가 마지막을 닫는다(여기선 reap 안 함)
        const loc = findTerminatedTerm(self) orelse return; // 더 닫을 죽은 Term 없음
        // 닫기 확인 모달이 보류 중이면, 곧 닫을 closeTermAt이 탭/pane 인덱스·활성 선택을 바꿔 보류 표적이 stale가
        // 된다 → 무효화(.window 제외). 첫 reap에서 한 번 취소하면 이후는 무동작(pending null).
        self.invalidatePositionalPendingClose();
        closeTermAt(self, loc.tab_index, loc.pane, loc.term_index);
    }
}

/// backend에 close를 보낼 대상인가 — **닫을 PTY가 실제로 있는 Term만** true다.
///
/// **왜 술어인가.** 이 네 항이 `workspace.zig`의 창 닫기 판정과 **글자 그대로 같았고**, 편집기가
/// 들어오며 다섯 항이 될 참이었다. 한쪽만 고치면 "빨간 버튼으로는 확인 모달이 뜨는데 탭 닫기는
/// 그냥 닫힌다" 같은 식으로 조용히 갈린다 — 두 자리가 같은 질문을 하고 있으므로 이름을 준다.
///
/// PTY가 없는 갈래가 셋이다: web(sentinel), 편집기(문서만), 종료 placeholder(묘비). 셋 다 backend에
/// 보낼 handle이 없고, `close_complete`는 이미 보낸 것이다.
pub fn hasClosablePty(term: *const Term) bool {
    return term.rt.live_initialized and
        term.kind == .terminal and
        !term.rt.ended_placeholder and
        !term.rt.close_complete;
}

/// 임의 탭(tab_index)의 pane에서 term_index Term을 닫고 cascade한다(exit 자동 정리·일반화). Term을 teardown·
/// 제거하고: pane에 Term이 남으면 active_term clamp, 비면 split이면 collapse, 단일 pane이면 워크스페이스(탭)를
/// close한다. 활성/배경 탭 모두 대상이라 closeActiveTerm(활성 전용)과 달리 위치를 인자로 받는다.
pub fn closeTermAt(self: *AppSession, tab_index: usize, pane: *Pane, term_index: usize) void {
    const tab = self.tabs.items[tab_index];
    const target = pane.terms.items[term_index];
    if (hasClosablePty(target)) {
        if (self.backendFor(target).closeAndDetach(target.rt.handle) == .event_pending) return;
        target.rt.close_complete = true;
    }
    cancelPointerGestureForTermRemoval(self, tab_index, pane, term_index);
    const term = pane.terms.orderedRemove(term_index);
    destroyTerm(self, term);
    if (pane.terms.items.len > 0) {
        // 임의 위치(종료된 Term)를 빼므로 활성 인덱스를 시프트 보정한다(단일 출처 activeIndexAfterRemoval) —
        // 배경 형제 reap 시 활성이 엉뚱한 Term으로 튀던 버그.
        pane.active_term = activeIndexAfterRemoval(pane.active_term, term_index, pane.terms.items.len);
        refreshAfterReap(self, tab_index);
    } else if (tab.panes.items.len > 1) {
        pane_ops.collapsePaneIn(self, tab, pane); // 빈 pane을 형제로 collapse(active_pane clamp 포함)
        refreshAfterReap(self, tab_index);
    } else {
        tab_ops.closeTab(self, tab_index); // 탭의 마지막 pane이 비었다 — 워크스페이스 close(대표 surface·active_tab은 closeTab가 처리)
    }
}

/// CR5d-2 forward-only local retirement.  The reducer has already published
/// `abandoned_to_inventory`; remove the local shell through the ordinary topology cascade but make
/// destroyTerm detach the remote runtime without a terminate RPC.
pub fn abandonTermAt(
    self: *AppSession,
    tab_index: usize,
    pane: *Pane,
    term_index: usize,
    backend: *app_session_mod.session_host.remote_term_backend.RemoteTermBackend,
) void {
    if (tab_index >= self.tabs.items.len or term_index >= pane.terms.items.len)
        app_session_mod.session_host.pending_term_close_graph.fatalProofLoss();
    const target = pane.terms.items[term_index];
    if (!target.rt.live_initialized or target.surface.remote == null or target.rt.handle == 0 or
        target.rt.abandoned_to_inventory)
        app_session_mod.session_host.pending_term_close_graph.fatalProofLoss();
    target.rt.close_complete = true;
    target.rt.abandoned_to_inventory = true;
    cancelPointerGestureForTermRemoval(self, tab_index, pane, term_index);
    const term = pane.terms.orderedRemove(term_index);
    destroyTermWithAbandonBackend(self, term, backend);
    if (pane.terms.items.len > 0) {
        pane.active_term = activeIndexAfterRemoval(pane.active_term, term_index, pane.terms.items.len);
        refreshAfterReap(self, tab_index);
    } else if (self.tabs.items[tab_index].panes.items.len > 1) {
        pane_ops.collapsePaneIn(self, self.tabs.items[tab_index], pane);
        refreshAfterReap(self, tab_index);
    } else {
        tab_ops.closeTab(self, tab_index);
    }
}

/// Read-only fixture evidence that opening an inline archive disclosure did not replace the
/// user's active terminal surface. A zero result means there is no initialized active
/// surface, never an archive-detail sentinel.
pub fn agentSessionArchiveSmokeActiveSurfaceId(self: *const AppSession) u64 {
    if (!self.surface_initialized or self.tabs.items.len == 0) return 0;
    return activeSurfaceConst(self).id;
}

/// Read-only fixture evidence for the same ownership boundary. The count covers every
/// visible tab/pane Term, so a former archive-tab implementation would change it when the
/// card was activated. Saturation keeps this observer total even for malformed fixtures.
pub fn agentSessionArchiveSmokeTermCount(self: *const AppSession) u32 {
    var count: u32 = 0;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            count = std.math.add(u32, count, @intCast(pane.terms.items.len)) catch return std.math.maxInt(u32);
        }
    }
    return count;
}

/// P2 seam(docs/persistent-session-host.md §13 P2): 이 창의 terminal runtime 계약 표면. GUI는 이 backend에
/// opaque handle(`Term.rt.handle`)을 넘겨 spawn/attach/pump/close/terminate/observe를 수행하고 `*LivePtySession`을
/// 직접 만지지 않는다. backend는 참조만 드는 값이라 매번 만들어도 무해하고, 반환된 vtable의 ctx는
/// `&self.term_backend`(heap-pin AppSession)라 호출 스코프 안에서 안정적이다.
pub fn termBackend(self: *AppSession) app.TermRuntimeBackend {
    return self.term_backend.backend();
}

/// 화면 외 runtime metadata cache를 갱신한다. host-backed Term은 placeholder core를 절대 읽지 않고 remote event
/// cache만 복사한다. in-process Term은 core가 곧 runtime SSOT이므로 title_generation(OSC 0/2/7/RIS)을 cheap gate로
/// 삼아 sidebar/frame hot path의 불필요한 lock+allocation을 피한다. `force`는 workspace/control snapshot처럼
/// semantic_state까지 즉시 coherent해야 하는 저빈도 경로용이다.
pub fn refreshTermObservation(self: *AppSession, term: *Term, include_foreground: bool, force: bool) void {
    if (term.kind != .terminal or !term.rt.live_initialized or term.rt.terminated) return;
    if (!force) {
        if (term.surface.remote != null) return; // remote pump/poll이 event cache를 갱신한다.
        const generation = term.surface.core.title_generation.load(.monotonic);
        if (term.rt.observation.availability == .current and
            term.rt.observation.title_generation == generation) return;
    }
    self.backendFor(term).readObservation(term.rt.handle, self.allocator, &term.rt.observation, include_foreground) catch {
        if (term.rt.observation.availability == .current)
            term.rt.observation.availability = .stale;
    };
}

/// 한 Term(터미널)을 만든다 — backend가 registry `LiveSurface` 번들 슬롯 소유 + live PTY spawn + surface init을
/// 한 단위로 하고(P2 seam), GUI에는 복구 가능한 `*Surface`와 opaque handle만 준다. M3a: `surface`·`live_pty` 소유가
/// 둘 다 앱 전역 `live_registry` 번들 슬롯에 있어(안정 heap 슬롯) reader가 잡는 `&live_pty.reader`·`&surface.core`를
/// 그 슬롯이 고정한다. Term은 surface를 포인터로 참조하고 runtime은 handle로 다룬다(surface_id·pty_id 발급=앱 전역
/// surface_ids). spawn 성공 후 이후 단계 실패는 `errdefer be.remove(id)`로 번들을 회수하고, spawn 자체 실패는 backend
/// 내부 2-pass 정리가 맡는다. Pane에 거는 건 호출자(createPane/⌘T)가 한다.
pub fn createTerm(
    self: *AppSession,
    request: maru.pty.SpawnRequest,
    size: terminal.Size,
    queue_capacity: usize,
    title: []const u8,
    command: []const u8,
) !*Term {
    const id = self.surface_ids.next(); // 앱 전역 allocator에서 발급. surface_id·pty_id 동일 값(서로 다른 네임스페이스라 무방), 재사용 안 함
    var req = request;
    req.pane_id = id; // 컨트롤 플레인 self selector는 계속 surface.id
    // 훅 로그 경로의 두 칸(docs/agent-hooks.md §4). 인스턴스 칸은 `surface.id` 가 **프로세스마다 1 부터**라
    // maru 를 두 개 띄우면 두 인스턴스의 첫 pane 이 같은 파일 이름을 갖는 문제를 가른다. pane 칸은
    // control-plane selector(`MARU_PANE_ID`)와 **갈라진 변수**다 — 같은 값(surface.id)을 싣지만 의미가 다르고,
    // host 가 소유하는 자식은 여기에 `runtime_id` 를 싣는다(그 자식은 GUI 보다 오래 산다).
    //
    // 버퍼는 이 함수 스택에 둔다 — env 는 아래 `be.spawn` 안에서 굳으므로 그 호출까지만 살아 있으면 된다.
    var hook_instance_buf: [maru.session.agent_hook_command.instance_token_max]u8 = undefined;
    var hook_pane_buf: [maru.session.agent_hook_command.pane_token_max]u8 = undefined;
    req.hook_instance = agent_ops.hookInstanceToken(&hook_instance_buf);
    req.hook_pane = maru.session.agent_hook_command.formatSurfacePane(&hook_pane_buf, id);
    // P2 seam(docs/persistent-session-host.md §13 P2): terminal runtime 계약 backend로 spawn한다. backend가 앱 전역
    // registry의 `LiveSurface` 번들 슬롯 생성 + live PTY spawn(live_pty.init) + surface init을 한 단위로(내부 2-pass
    // 부분-init 정리 포함) 수행하고, GUI에는 복구 가능한 *Surface와 opaque handle(id)만 준다 — GUI는 `*LivePtySession`을
    // 직접 안 든다. handle 값은 surface_id(=pty_id)와 같지만 backend에 되돌려 주는 불투명 handle로만 다룬다. reader가
    // 잡는 `&live_pty.reader`·`&surface.core`는 backend 내부에서 registry heap 슬롯이 고정한다(heap-pin 유지 — Term-inline
    // 시절과 같은 메커니즘). generation=0으로 시작. id는 앱 전역 유일이라 중복 등록 없음.
    var be = self.backendForNew(); // P3-e3: keep-alive+연결 성공 시 원격 backend, 아니면 in-process(기본). #3 폴백 시 아래서 갱신.
    // P3-e3-5 재접속: persistent identity가 있으면 host namespace를 먼저 대조한 뒤 attach한다. keep-alive가 켜진
    // 복원에서 host/runtime이 없거나 달라졌는데 fresh spawn으로 폴백하면 "이어진 세션"처럼 보이는 데이터 손실이므로
    // loud-fail한다. keep-alive를 끈 복원은 identity를 명시적으로 무시하고 일반 in-process spawn으로 전환한다.
    const reconnect_host_id = self.restore_runtime_host_id;
    const reconnect_id = self.restore_runtime_id;
    const force_reconnect = self.restore_runtime_force_attach;
    self.restore_runtime_host_id = "";
    self.restore_runtime_id = "";
    self.restore_runtime_force_attach = false;
    var reconnected = false; // attach(재접속) 경로면 true — errdefer가 terminate 대신 detach로 되돌린다(아래).
    // 새 host runtime은 reader를 시작하기 전에 이 snapshot을 적용해야 한다. spawn 뒤 별도 RPC만 쓰면 child가
    // 즉시 낸 첫 출력이 기본 폭/scrollback/theme으로 parse되는 race가 생긴다. in-process도 같은 값으로 시작하고,
    // 재접속은 아래 attach 뒤 명령으로 현재 GUI config를 다시 맞춘다.
    const runtime_config: maru.session.core_command.RuntimeConfig = .{
        .max_scrollback = self.loaded_config.config.scrollback.lines,
        .ambiguous_wide = self.loaded_config.config.ambiguous_width == .wide,
        .emoji_wide = self.loaded_config.config.emoji_width == .wide,
        .palette = self.appearance.theme.palette,
        .default_colors = .{
            .foreground = self.appearance.theme.foreground,
            .background = self.appearance.theme.background,
        },
        .cell_metrics = if (self.cell_width_px > 0 and self.cell_height_px > 0) .{
            .width = self.cell_width_px,
            .height = self.cell_height_px,
        } else null,
        // config cursor.shape — 원격 core는 host 소유라 spawn snapshot에 실어야 첫 출력 전에 기본 모양이 선다
        // (in-process는 아래 chokepoint가 같은 값을 직접 주입 — 로컬/원격 동일 규칙).
        .default_cursor_shape = settings_ops.configCursorShape(self),
    };
    const surface = surface: {
        if (is_macos and (app_session_mod.appKeepAlivePolicyValue() or force_reconnect) and reconnect_id.len > 0) {
            if (reconnect_id.len != 32) return error.InvalidPersistentRuntimeIdentity;
            var reconnect_host: u128 = 0;
            if (reconnect_host_id.len > 0) {
                if (reconnect_host_id.len != 32) return error.InvalidPersistentRuntimeIdentity;
                reconnect_host = std.fmt.parseInt(u128, reconnect_host_id, 16) catch
                    return error.InvalidPersistentRuntimeIdentity;
            } else if (app_session_mod.app_remote_host_pool) |*pool| {
                reconnect_host = pool.spawnHostId() orelse return error.PersistentRuntimeUnavailable;
            } else if (app_session_mod.app_remote_client) |legacy| {
                reconnect_host = legacy.host_id;
            } else {
                return error.PersistentRuntimeUnavailable;
            }

            // Exact saved host를 먼저 복구한다. current host bootstrap 실패로 pool/backend가 없어도 이 함수가
            // N-1 query-only 연결에서 둘을 만들 수 있어, 새 host 가용성과 기존 세션 복원이 독립적이다.
            const legacy_matches = app_session_mod.app_remote_host_pool == null and
                app_session_mod.app_remote_client != null and app_session_mod.app_remote_client.?.host_id == reconnect_host;
            if (!legacy_matches and (app_session_mod.app_remote_host_pool != null or reconnect_host_id.len > 0)) {
                // 여기서 처음으로 "영구"와 "일시"가 갈린다. host 프로세스가 사라졌다는 긍정적 증거(host_gone)만
                // PersistentRuntimeGone으로 올린다 — caller가 그 Term만 종료 placeholder로 둘 수 있게 하는 신호다.
                // 나머지는 종전처럼 Unavailable(fail-closed)이다. 오분류 비용이 비대칭이라 보수적으로 가른다:
                // 영구를 일시로 보면 창 복원이 한 번 실패할 뿐이지만, 일시를 영구로 보면 살아 있는 세션을
                // placeholder로 굳혀 사용자가 되찾을 길이 사라진다(§7 접속 실패 행렬).
                switch (self.ensureRestoreHostAdapter(reconnect_host)) {
                    .ready => {},
                    .host_gone => return error.PersistentRuntimeGone,
                    .unavailable => return error.PersistentRuntimeUnavailable,
                }
            }
            const rb = if (app_session_mod.app_remote_backend) |*remote| remote else return error.PersistentRuntimeUnavailable;
            // `backendForNew()`는 이 함수 초입에서 평가된다. current host bootstrap이 실패한 뒤
            // `ensureRestoreHostAdapter()`가 N-1 pool/backend를 방금 만든 경우에는 그 값이 아직 local backend다.
            // 기존 runtime attach 뒤의 attach/config/pump/observation도 반드시 같은 remote backend를 써야 하므로
            // restored runtime의 실제 owner로 다시 고정한다.
            be = rb.backend();
            const pooled = app_session_mod.app_remote_host_pool != null;
            const legacy_client = if (!pooled) app_session_mod.app_remote_client else null;
            if (pooled and app_session_mod.app_remote_host_pool.?.get(reconnect_host) == null)
                return error.PersistentRuntimeUnavailable;
            var rid: [32]u8 = undefined;
            @memcpy(&rid, reconnect_id[0..32]);
            const attached = if (pooled)
                rb.attachTermOnHost(reconnect_host, id, rid, size) catch |err| return classifyAttachError(err)
            else blk: {
                if (reconnect_host != legacy_client.?.host_id) return error.PersistentRuntimeUnavailable;
                break :blk rb.attachTerm(id, rid, size) catch |err| return classifyAttachError(err);
            };
            reconnected = true;
            // host는 두 번째 controller를 거절하지 않고 **조용히 observer로 강등**한다(§9). attach는 성공으로
            // 돌아오지만 이 Term은 화면만 받고 입력은 전부 거부된다. 알리지 않으면 사용자는 "화면은 나오는데
            // 키가 안 먹는" 터미널을 이유도 모른 채 마주한다 — 실제로 그 상태로 한참을 쓰게 된다.
            if (rb.attachedAsObserver(id)) self.observer_attach_notice_pending = true;
            break :surface attached;
        }
        break :surface be.spawn(.{
            .handle = id,
            .request = req,
            .size = size,
            .queue_capacity = queue_capacity,
            .initial_config = runtime_config,
        }) catch |err| {
            // #3: keep-alive 원격 backend인데 host 연결이 죽었으면(ConnectionClosed/WriteFailed) createTerm이 실패해 새
            // 터미널을 못 여는 대신 **in-process로 폴백**한다 — 사용자가 앱 재시작 없이 계속 쓰게. host_connect_failed를 세워
            // 이후 backendForNew도 죽은 원격을 안 타고, 다음 tick notice가 "유지 안 됨"을 알린다. 원격이 아니거나(로컬 spawn
            // 실패는 그대로) 연결사 외 에러(OOM 등 — in-process도 실패할 것)는 폴백 없이 전파한다. 기존 host-backed Term은
            // 각자 pump가 read_error로 관측한다(별도). remote spawn 실패는 backend 내부에서 정리돼 handle을 재사용해도 안전.
            const remote_dead = is_macos and !reconnected and app_session_mod.app_remote_backend != null and !app_session_mod.host_connect_failed and
                (err == error.ConnectionClosed or err == error.WriteFailed or err == error.UnsupportedSpawnContract);
            if (!remote_dead) return err;
            self.markHostConnectFailedError(.runtime_death, err);
            be = termBackend(self); // errdefer·이후 단계가 in-process backend를 쓰도록 갱신.
            break :surface try be.spawn(.{
                .handle = id,
                .request = req,
                .size = size,
                .queue_capacity = queue_capacity,
                .initial_config = runtime_config,
            });
        };
    };
    // spawn 성공 후 이후 단계(config·attach·pump) 실패 시 번들 슬롯을 회수한다(backend.remove = 번들 deinit = live_pty
    // reader join + surface.deinit + 슬롯 해제). spawn 자체 실패는 backend 내부 2-pass 정리(removeUninitialized)가
    // 처리하므로 이 errdefer는 spawn 성공 후에만 등록돼 이후 단계 실패만 잡는다.
    // 단 **재접속(attach)** 성공 경로는 우리가 띄운 게 아니라 기존 host runtime이므로 remove(=terminate)를 쓰면 안 된다 —
    // 이후 단계 실패 시 detachTerm(client-side만 회수, terminate 없음)으로 되돌려 재접속했던 runtime을 살려 둔다(§7,
    // deinit pass2와 같은 detach 규율). spawn 경로만 remove(terminate)로 우리가 만든 runtime을 회수한다.
    errdefer if (is_macos and reconnected) {
        if (app_session_mod.app_remote_backend) |*rb| rb.detachTerm(id);
    } else {
        if (be.remove(id) != .removed) @panic("construction rollback lost its terminal runtime");
    };
    // GUI Term은 backend admission·spawn이 모두 성공한 뒤에만 만든다. remote cap+1이나 host/RPC 실패가
    // AppSession allocator/layout에 부분 객체를 남기지 않게 하고, 이후 실패는 위 runtime rollback과 함께 회수한다.
    const term = try self.allocator.create(Term);
    errdefer self.allocator.destroy(term);
    term.* = .{};
    term.surface = surface; // backend가 init한 번들 슬롯 surface를 참조(소유는 registry)
    term.rt.handle = id; // opaque runtime handle(= surface_id, in-process) — 이후 backend 호출의 라우팅 키
    term.rt.live_initialized = true;
    term.rt.restored_existing = reconnected;
    term.rt.spawned_at_ns = std.Io.Clock.awake.now(self.io).nanoseconds; // uptime(비정상 시작 사망 grace) 기준 시각
    // 비정상 시작 사망으로 held된 창에 새 셸이 뜨면 held를 풀어(re-arm), 이 새 세션이 정상 종료할 때 세션 종료
    // latch가 다시 판정하게 한다(held→⌘T 새 셸→쓰다 exit→정상 앱 종료). 모든 surface spawn의 단일 chokepoint.
    // held였다면 pending_zombie_reap을 세워, 이 live Term이 붙은 뒤 tick이 남은 죽은 Term을 reap한다(좀비 탭 방지).
    // 또한 total_output_events를 리셋한다 — holdOnStartupExit의 "usable 미도달=무출력" 신호는 세션 누적 카운터라,
    // 리셋 안 하면 1차 시도의 출력이 남아 재시도가 조용히 실패해도 "usable"로 오판돼 창이 닫힌다(재시도는 새 시도).
    if (self.startup_held) {
        self.pending_zombie_reap = true;
        self.total_output_events = 0;
    }
    self.startup_held = false;

    // config: backend가 돌려준 surface에 GUI가 표시 정책을 적용한다(config는 GUI layout 소유 — backend는 프로세스
    // 수명만 안다). surface init 자체는 backend.spawn이 이미 했고, 모든 surface가 이 chokepoint를 첫 출력 전에
    // 지나므로 arena 교체·palette 주입이 안전하다.
    // 스크롤백 cell arena를 mmap 기반 page_allocator로(§11 P4 — demand-commit + 콜드 OS swap + free 즉시 반납,
    // history > RAM). 이 chokepoint는 모든 live surface가 첫 출력 전(페이지 0개)에 지나므로 arena 교체가 안전하다.
    term.surface.core.setScrollbackArena(std.heap.page_allocator);
    // config 스크롤백 ring 크기를 주입한다(모든 surface가 이 chokepoint를 지난다 — init 첫 탭·새 탭·split·
    // restore). lazy-alloc(첫 scroll) 전이라 안전. 0이면 스크롤백 비활성.
    term.surface.core.setMaxScrollback(self.loaded_config.config.scrollback.lines);
    // EAW Ambiguous(동그란 번호 등) 폭(text.ambiguous-width). 같은 chokepoint라 모든 surface가 일관된 폭으로
    // putCell한다(grid·커서·렌더 단일 출처). 기본 narrow — wide면 동그란 번호 등을 2칸 advance.
    term.surface.core.ambiguous_wide = self.loaded_config.config.ambiguous_width == .wide;
    // 이모지 표현(VS16/키캡) 폭(text.emoji-width, 기본 wide). 같은 chokepoint라 모든 surface가 일관되게 이모지를
    // 2칸으로 putCell한다 — ❤️·2️⃣가 1칸에 작게 나오던 것을 풀고 TUI 레이아웃과 정합(grid·커서·렌더 단일 출처).
    term.surface.core.emoji_wide = self.loaded_config.config.emoji_width == .wide;
    // config theme.palette(ANSI 16색 base)를 코어에 주입한다 — OSC 4 query 응답이 렌더(metal_frame)와 같은
    // 우선순위(OSC4 override > config base > xterm256)를 보도록(화면·보고 정합). RIS/OSC104는 override만 리셋.
    term.surface.core.setConfigPalette(self.appearance.theme.palette);
    // config cursor.shape를 코어 **기본** 커서 모양으로 주입한다(DECSCUSR 0·RIS 복귀 지점). 앱이 DECSCUSR로
    // 명시하면 그게 이기고(vim 모드별 bar/block), 거둬들이면 이 값으로 돌아온다. 원격은 위 runtime_config가
    // 같은 값을 host core에 싣는다 — 여기 직접 주입은 in-process 경로(placeholder core는 host가 덮어씀).
    term.surface.core.setDefaultCursorShape(settings_ops.configCursorShape(self));
    term.surface.title = title;
    term.surface.command = command;

    // interactive 셸(login 래핑)만 리더 코어-처리를 켠다 — 렌더 tick에 안 묶여 OSC 응답이 즉시 나간다
    // (docs/io-render-threading.md PR3). controlled_smoke(login=false, 테스트)는 큐-드레인 유지.
    _ = try be.attach(id, request.login); // interactive(login)만 process_in_reader — 계약이 attachSurface로 위임
    // attach 뒤의 backend가 실제 core 소유자다. 신규 spawn은 initial_config를 reader 시작 전에 이미 적용했지만,
    // 이 재적용은 기존 runtime 재접속과 향후 attach 경로가 현재 GUI config로 수렴하게 한다. attach 전
    // `term.surface.core`는 원격 client placeholder라 직접 대입만으로 host parser/grid/OSC query는 바뀌지 않는다.
    try be.enqueueCoreCommand(id, .{ .set_runtime_config = runtime_config }, self.io);
    // MARU_TRACE: 이 창의 trace 레코더를 방금 attach한 링크에 per-link로 붙인다(모든 surface spawn 단일 chokepoint —
    // 첫탭·⌘T·split·restore 다 여기). 앱-전역 runtime이라 창끼리 안 섞이도록 싱글톤이 아니라 링크별로 건다(리뷰 [0]).
    // recorder는 self 소유(안정 주소)라 링크가 든 포인터가 세션 내내 유효하다. 붙는 순간 초기 grid baseline resize 기록.
    if (self.trace_recorder != null) try self.runtime.setSurfaceTraceRecorder(term.surface.id, &self.trace_recorder.?);
    // pump를 **앱 전역 라우팅**에 바인딩(M3b) — 창을 옮겨도(M3d) surface_id 키드 라우팅이 그대로 유효하다(§8A.2).
    // backend가 handle의 live PTY 이벤트 큐로 pump를 만든다(계약이 LivePtySession.pump로 위임).
    term.rt.pump = try be.pump(id);
    // 첫 sidebar/title/SSH/agent frame 전에 initial observation을 확보한다. 새 host는 attach response에 full metadata를
    // 싣고, in-process는 실제 core/PTY를 lock-copy한다. 구 host는 unavailable로 남아 empty와 구분된다.
    be.readObservation(id, self.allocator, &term.rt.observation, true) catch {};
    return term;
}

/// 한 Term을 teardown하고 heap 해제한다(closeAndDetach → live_registry.remove(번들 deinit=reader join + custom_name
/// 해제 + surface.deinit + 슬롯 해제, M3a) → destroy). runtime이 살아 있을 때만 detach. createPane/⌘T errdefer·close·
/// split 실패 정리에 쓴다. (deinit은 surface 정리를 config/appearance 해제 앞에 두려 2-pass를 직접 풀어 쓴다 — 여기 쓰지 않는다.)
pub fn destroyTerm(self: *AppSession, term: *Term) void {
    return destroyTermWithAbandonBackend(self, term, null);
}

fn destroyTermWithAbandonBackend(
    self: *AppSession,
    term: *Term,
    abandon_backend: ?*app_session_mod.session_host.remote_term_backend.RemoteTermBackend,
) void {
    const surface_id = term.surface.id;
    // 탭 드래그 preview는 `*Term`을 **프레임 간 캐시**하는 유일한 자리라, 다른 Term 포인터 보유 상태
    // (rename·context_menu_target)와 같은 barrier가 여기 필요하다. `cancelPointerGestureForTermRemoval`은
    // `pane.terms`에서 빼는 경로만 덮는데, **in-place 교체**(respawnEndedPlaceholder·rebuildFileTermSurface)는
    // 길이를 안 바꾸고 슬롯만 갈아끼운 뒤 옛 Term을 해제한다 — 길이 검사만으로는 그 dangling을 못 잡는다.
    tab_ops.cancelTabDragForTerm(self, term);
    // 편집기 막대 드래그도 `*Term`을 프레임 간 들고 있다 — 같은 barrier가 필요하다(죽은 포인터로
    // 스크롤하면 그 자리에서 터진다).
    // **본문 선택 제스처도 같은 부류다**(§4.1g 배선). `PointerGestureOwner.editor_selection`이
    // `*Term`을 프레임 간 들고, tick의 자동 스크롤과 다음 마우스 move가 그것을 역참조한다 —
    // barrier가 없으면 죽은 `Term.rt`를 읽는다. 형제 둘에는 걸어 두고 이것만 빠져 있었다.
    // 비교 뷰 선택 제스처도 같은 부류다 — `*Term`을 프레임 간 든다.
    if (self.pointerGestureIs(.editor_diff_selection_drag) and
        self.pointer_gesture_owner.editor_diff_selection_drag.term == term)
    {
        self.finishPointerGesture();
    }
    if (self.pointerGestureIs(.editor_selection) and self.pointer_gesture_owner.editor_selection.term == term) {
        self.editor_drag_autoscroll = 0;
        self.editor_drag_autoscroll_accum_ms = 0;
        self.finishPointerGesture();
    }
    if (self.editor_scrollbar_term == term) {
        self.editor_scrollbar_term = null;
        self.dock_list_scroll_drag.end();
        self.editor_hscroll_drag.end();
        if (self.scrollbar_drag_target == .editor_vertical or self.scrollbar_drag_target == .editor_horizontal) {
            self.scrollbar_drag_target = .none;
        }
    }
    notifySurfaceClosed(self, surface_id);
    // 이 surface로 가던 미전송 입력 큐를 회수한다 — flush는 맵 순회 중이라 엔트리를 못 지우고 비우기만 한다
    // (pending_pastes 주석). 잔여 바이트는 대상이 사라졌으니 버린다(다시 쓸 수 없다).
    if (self.pending_pastes.fetchRemove(surface_id)) |kv| {
        var q = kv.value;
        q.buf.deinit(self.allocator);
    }
    // rename 대상이 이 Term이면 stale 포인터 방지로 비운다(teardown 중 — 직접 null, closeRename 부수효과 없이).
    if (renamingTerm(self, term)) {
        self.rename = null;
        self.rename_input.clear();
    }
    // 컨텍스트 메뉴 대상이 이 Term이면 메뉴를 닫고 대상을 비운다(stale 포인터 방지).
    if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .term and t.term == term) {
        self.context_menu_target = null;
        self.chrome_host.context_menu.hide();
    };
    // Phase 7e-2a: 이 Term(web browser)을 주소창 편집 중이면 편집·관련 pending을 정리한다(stale surface_id 방지 —
    // remove가 슬롯을 해제하기 전에 surface_id로 판정). 비-web·비대상이면 무동작(surface_id 불일치 = no-op).
    web_ops.dropAddrEditIfSurface(self, term.surfaceId());
    if (term.pending_url) |u| { // WP-P: 아직 로드 못 한 복원 URL(owned) 회수
        self.allocator.free(u);
        term.pending_url = null;
    }
    // 편집기 Term이 소유한 문서·줄·경로를 먼저 놓는다. 아래 슬롯 해제가 돌면 `term.surface`가
    // 무효가 되므로 순서가 중요하다(문서는 surface와 무관하지만 한 곳에서 끝내는 편이 안전하다).
    if (term.kind == .editor) editor_ops.releaseEditorTerm(self, term);
    if (term.kind == .web or term.kind == .editor or term.rt.ended_placeholder) {
        // 4e-1 web Term: PTY·reader·라우팅 없음(sentinel surface). detach/closeAndDetach 없이 registry.remove만
        // 부른다 — union web arm deinit(custom_name 해제 + sentinel surface.deinit + 슬롯 해제)이 소유를 정리한다.
        // surface_id는 remove 실행 전에 읽는다(remove가 슬롯을 해제하므로 이후 term.surface deref 금지).
        // §7 종료 placeholder도 같은 슬롯 모양(web arm sentinel)이라 여기로 온다. 이 조건에서 빠뜨리면
        // `live_initialized=false`라 아래 분기도 못 타 슬롯이 누수되고, 반대로 아래로 보내면 handle=0에
        // `closeAndDetach`를 부른다(둘 다 틀렸다).
        self.live_registry.remove(surface_id) catch {};
    } else if (term.rt.live_initialized) {
        // P2 seam: detach(runtime routing) 선행 → backend.remove가 번들 소유를 teardown(deinit=live_pty reader join →
        // custom_name 해제 → surface.deinit → 슬롯 해제). backend 계약에 handle을 넘겨 수행하며, GUI는 `*LivePtySession`을
        // 직접 만지지 않는다. closeAndDetach가 reader를 먼저 join하므로(멱등) reader가 잡던 `&surface.core`가 번들
        // deinit의 surface.deinit 순간까지 살아 있다. handle(= surface_id)은 remove 실행 전에 읽었다(remove가 슬롯을
        // 해제하므로 이후 term.surface/handle deref 금지).
        if (is_macos and term.rt.abandoned_to_inventory and term.surface.remote != null) {
            const rb = abandon_backend orelse app_session_mod.session_host.pending_term_close_graph.fatalProofLoss();
            rb.detachAbandonedWindowTerm(term.rt.handle);
        } else if (is_macos and term.rt.restored_existing and term.surface.remote != null) {
            // restore staging rollback: 기존 runtime의 subscription/client state만 회수한다. terminate는 절대 보내지 않는다.
            if (app_session_mod.app_remote_backend) |*rb| rb.detachTerm(term.rt.handle);
        } else {
            if (!term.rt.close_complete and self.runtime_initialized and self.backendFor(term).closeAndDetach(term.rt.handle) == .event_pending)
                @panic("term destruction bypassed a pending close operation");
            if (self.backendFor(term).remove(term.rt.handle) != .removed)
                @panic("term destruction lost its terminal runtime");
        }
        term.rt.live_initialized = false;
    }
    // 파일 entry(FP16 §1)는 Term 소유다 — 여기서 해제하지 않으면 탭을 닫을 때마다 path와 Entry가 샌다.
    // 소유권 경계가 여기 하나뿐이라(생성은 파일 열기, 해제는 여기) 중간 상태가 없다.
    if (term.file_entry) |entry| {
        self.allocator.free(entry.path);
        self.freeDiffEntryState(entry);
        self.allocator.destroy(entry);
        term.file_entry = null;
    }
    // git 브랜치 캐시·auto_title(Term-owned)만 여기서 해제 — custom_name·surface는 번들 deinit이 소유한다(M3a §8A.1).
    if (term.git_branch) |b| self.allocator.free(b);
    if (term.git_branch_cwd) |c| self.allocator.free(c);
    term.auto_title.deinit(self.allocator);
    term.rt.observation.deinit(self.allocator);
    if (term.rt.ended_command.len > 0) self.allocator.free(term.rt.ended_command); // §7 묘비 owned command(deinit과 동기 유지)
    if (term.rt.ended_runtime_host_id.len > 0) self.allocator.free(term.rt.ended_runtime_host_id);
    if (term.rt.ended_runtime_id.len > 0) self.allocator.free(term.rt.ended_runtime_id);
    self.allocator.destroy(term);
}

/// platform 관찰 훅을 설치한다. 세션/Term 소유권은 바뀌지 않고, callback은 teardown을 시작한 같은 메인 스레드에서
/// 동기 호출된다. 테스트와 비-macOS 경로는 기본 null을 유지한다.
pub fn setSurfaceClosedCallback(self: *AppSession, context: ?*anyopaque, callback: ?SurfaceClosedCallback) void {
    self.surface_closed_context = context;
    self.surface_closed_callback = callback;
}

pub fn notifySurfaceClosed(self: *AppSession, surface_id: u64) void {
    if (self.surface_closed_callback) |callback| callback(self.surface_closed_context, surface_id);
}

/// surface.id로 그 surface가 속한 (탭, panel, Term)을 찾아 그 자리로 활성화한다(찾으면 true). 데스크톱 알림
/// OSC 9/777 클릭이 발신 터미널로 점프하는 단일 경로다 — Swift가 알림 식별자의 (창 토큰,
/// surface_id)에서 토큰으로 올바른 창(세션)을 고른 뒤, 이 세션에 surface_id만 넘긴다(surface.id는 이제 앱 전역
/// surface_ids로 발급돼 창 간 유일하다 — M0a. 창 토큰은 id 충돌 방지용 복합키가 아니라 대상 창을 빠르게 고르는
/// 위치 메타데이터고, 세션 내 (탭·panel·Term) 역조회는 Zig가 분담한다).
///
/// **순서가 핵심**: focusPaneByPtr는 활성 탭의 panes만, focusTerm은 활성 pane만 보므로
/// switchTab→focusPaneByPtr→focusTerm 순으로 해야 한다 — 먼저 대상 탭을 활성으로 만들지 않으면 focusPaneByPtr가
/// 다른 탭의 panes에서 못 찾아 false가 되고, focusTerm도 엉뚱한 pane을 만진다. 이 순서 의존성을 여기 한 곳에
/// 가둔다(단일 출처). 세 호출은 같은 자리면 각자 no-op이라 이미 활성인 surface를 다시 눌러도 무해하다.
///
/// id는 재사용하지 않으므로(surface_ids 단조 증가) stale id가 다른 surface로 오인 활성화될 위험이 없다 — 알림 후
/// 그 Term이 닫혔으면 못 찾아 false(무동작). 클릭 시점에 실시간 3중 순회하므로 알림 도착 후 탭/pane이 재배치돼도
/// 인덱스 캐시 없이 정확히 현재 위치로 점프한다.
/// surface id 로 살아 있는 Term 을 찾는다. 없으면 null(닫힌 Term).
///
/// **떠 있는 UI 가 대상을 포인터가 아니라 이 id 로 들게 하려고 낸다.** 포인터를 들면 그 Term 이
/// 닫힐 때마다 비워 주는 규율이 하나 더 생기고, 그 규율은 빠뜨리기 쉽다(rename 대상이 그 규율을
/// 진다). id 는 재사용되지 않으므로 stale 이면 그냥 못 찾는다.
pub fn termBySurfaceId(self: *AppSession, id: u64) ?*Term {
    const loc = findTermWhere(self, id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.surface.id == want;
        }
    }.pred) orelse return null;
    return loc.pane.terms.items[loc.term_index];
}

pub fn activateSurfaceById(self: *AppSession, id: u64) bool {
    const loc = findTermWhere(self, id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.surface.id == want;
        }
    }.pred) orelse return false; // 못 찾음(닫힌 Term) → 무동작
    // 순서가 핵심(위 doc): switchTab으로 대상 탭을 활성으로 만든 뒤라야 focusPaneByPtr가 그 탭의 panes에서
    // loc.pane을 찾고, 그 뒤라야 focusTerm이 올바른 활성 pane을 만진다.
    _ = tab_ops.switchTab(self, loc.tab_index);
    _ = pane_ops.focusPaneByPtr(self, loc.pane);
    focusTerm(self, loc.term_index);
    return true;
}

/// Term 배열 mutation 직전의 위치 기반 gesture barrier. 같은 pane의 terminal-tab index는 어느 항목 제거에서도
/// shift될 수 있어 전부 취소한다. scrollbar는 현재 active Term 자체가 사라질 때만 취소해 배경 reap은 보존한다.
pub fn cancelPointerGestureForTermRemoval(self: *AppSession, tab_index: usize, pane: *Pane, term_index: usize) void {
    switch (self.pointer_gesture_owner) {
        .terminal_tab => |drag| if (drag.pane == pane) self.finishPointerGesture(),
        .scrollbar => if (tab_index == self.app_window.active_tab and pane == pane_ops.activePane(self) and term_index == pane.active_term)
            self.finishPointerGesture(),
        else => {},
    }
}

/// 이 Term에 셸이 아닌 포그라운드 명령이 실행 중인가 — 닫기 확인의 단위 판정. live_pty 미초기화(attach 전)나
/// 이미 종료(exited)면 false(명령 없음). 실행 여부는 코어의 `cursorIsAtPrompt`(셸 통합 OSC 133 + alt 화면,
/// OS-중립)로 판정한다 — 프롬프트에 idle하게 있으면 실행 중 아님. pgid syscall을 안 쓰므로 login(1) fork
/// (child_pid=login이라 셸 pgid와 영영 불일치) 오판이 없고 Linux·Windows·web에 그대로 이식된다.
/// `cursorIsAtPrompt`가 읽는 코어 필드(semantic_state·alt_active)는 reader 스레드가 `core.write`로 갱신하므로,
/// 메인 스레드 읽기는 **lockCore 아래**에서 한다(surface.zig 불변식·torn read 방지 — cwd/scrollback 형제와 동일).
/// 단일 출처: docs/macos-app-host-boundary.md "닫기 확인", src/terminal/core.zig cursorIsAtPrompt.
pub fn termHasRunningJob(term: *Term, io: std.Io) bool {
    if (!term.rt.live_initialized) return false;
    if (term.surface.process_state == .exited) return false;
    // in-process core가 실제 runtime SSOT다. 테스트의 직접 fixture mutate뿐 아니라 닫기 직전 최신 OSC 133 상태를
    // 별도 cache cadence 없이 즉시 본다.
    if (term.surface.remote == null) {
        term.surface.lockCore(io);
        defer term.surface.unlockCore(io);
        return !term.surface.core.cursorIsAtPrompt();
    }
    if (term.rt.observation.availability != .unavailable) {
        return term.rt.observation.alt_active or switch (term.rt.observation.semantic_state) {
            .prompt, .input => false,
            .command, .unknown => true,
        };
    }
    // 구 remote host/metadata 미확정은 "idle"로 위장하지 않고 확인을 요구한다.
    return true;
}

/// 죽은/PTY 없는 surface의 core에 안내 텍스트를 쓰는 **락 규율 단일 출처**. 리더가 없거나 이미 멈춘 surface라
/// 락 아래 안전하며, `~` 확장·에스케이프는 core가 파싱한다(평범한 텍스트 + SGR). 화면 콘텐츠라 notice 토스트와
/// 달리 키 입력으로 사라지지 않는다 — 복구 방법이 계속 보이는 것이 요점이다(#5 지속성).
pub fn writeSurfaceGuidance(self: *AppSession, surface: *maru.session.Surface, line: []const u8) void {
    surface.lockCore(self.io);
    defer surface.unlockCore(self.io);
    surface.core.write(line) catch {};
}

/// 이 세션의 모든 워크스페이스 surface 총수 — mergeSessionInto(cross-window)의 참 이동 개수(버퍼 절단과 무관, [6]).
pub fn totalSurfaceCount(self: *AppSession) usize {
    var n: usize = 0;
    for (self.tabs.items) |tab| n += tab_ops.tabSurfaceCount(tab);
    var entry_it14 = file_panel_ops.fileEntriesConst(self);
    while (entry_it14.next()) |entry| if (entry.surface_id != 0) {
        n += 1;
    };
    return n;
}

/// 활성 pane의 활성 Term(가로 탭)을 닫는다. pane에 Term이 2개 이상일 때만 — teardown(destroyTerm)하고
/// terms에서 빼고 active_term을 보정한 뒤 새 활성 Term surface로 재바인딩한다. Term이 1개뿐이면 무동작
/// (closeActiveTermOrPane이 pane/워크스페이스 close로 보낸다). tree leaf는 pane이라 Term close엔 안 바뀐다.
pub fn closeActiveTerm(self: *AppSession) void {
    const pane = pane_ops.activePane(self);
    if (pane.terms.items.len <= 1) return;
    const idx = pane.active_term;
    cancelPointerGestureForTermRemoval(self, self.app_window.active_tab, pane, idx);
    const closing = pane.terms.items[idx];
    _ = pane.terms.orderedRemove(idx);
    destroyTerm(self, closing);
    // active_term 보정: 닫은 게 마지막이면 이전, 아니면 그 자리로 온 다음 Term(같은 인덱스).
    pane.active_term = if (idx >= pane.terms.items.len) pane.terms.items.len - 1 else idx;
    self.surface_ptrs.items[self.app_window.active_tab] = pane.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    pane_ops.recomputeActivePaneRect(self);
    self.metal_dirty = true;
}

/// 새 split(팬)·새 Term(서페이스)이 상속할 cwd — 포커스된(활성 pane의 활성) Term이 OSC 7로 보고한 현재
/// cwd(절대경로 형식일 때만; usableRestoreCwd 필터)를 **`buf`로 복사해** 돌려준다. 못 받았으면(셸 통합 없음·
/// 첫 프롬프트 전) null.
///
/// **락**: interactive 세션은 reader 스레드가 core_mutex 아래 `core.write`로 OSC 7을 처리하며 옛 cwd 슬라이스를
/// free한다(dispatchOscCwd). 메인 스레드가 그 슬라이스를 락 없이 읽어 들고 있으면, spawn까지의 창에서 reader가
/// free·재할당해 use-after-free/torn read가 난다(그 cwd가 자식 chdir로 감). 그래서 lockCore 아래에서 읽고 **즉시
/// 복사**해 끊는다 — 반환 슬라이스는 core가 아니라 `buf` 소유라 그 뒤 reader가 core.cwd를 바꿔도 안전하다.
/// cwd 상속 출처가 될 Term을 고른다 — 활성 Term이 terminal이면 그것, 활성 Term이 web(sentinel core라 cwd
/// 없음)이면 같은 pane의 첫 terminal 형제로 상속한다. web-only pane(터미널 형제 없음)이면 null → 호출자가 root
/// 폴백. web Term의 sentinel core를 읽어 cwd 상속이 루트로 떨어지는 4e 회귀를 막는다.
pub fn cwdSourceTerm(self: *AppSession) ?*Term {
    const pane = pane_ops.activePane(self);
    const active = pane.activeTerm();
    if (active.kind == .terminal) return active;
    for (pane.terms.items) |t| if (t.kind == .terminal) return t; // web 활성이면 pane 내 터미널 형제로 상속
    return null; // web-only pane: 상속원 없음 → 루트 폴백
}

pub fn focusedTermCwd(self: *AppSession, buf: []u8) ?[]const u8 {
    const term = cwdSourceTerm(self) orelse return null;
    refreshTermObservation(self, term, false, false);
    if (term.rt.observation.availability == .unavailable) return null;
    // **원격 cwd는 상속하지 않는다.** 그 경로는 원격 파일시스템의 것이라 로컬 spawn에 넘기면 자식이 chdir에
    // 실패해 $HOME으로 조용히 폴백한다(pty/macos.zig childExec) — 사용자는 "새 탭이 엉뚱한 데서 열린다"만 본다.
    // 여기서 null을 내면 호출자가 설정된 workspace.root로 폴백해 **의도한 자리**에서 연다(ssh-integration.md §9.4).
    if (app_session_mod.termCwdIsRemote(term)) return null;
    const cwd = usableRestoreCwd(term.rt.observation.cwd.items) orelse return null;
    if (cwd.len > buf.len) return null; // 방어(usableRestoreCwd가 이미 max_path_bytes 미만 보장)
    @memcpy(buf[0..cwd.len], cwd); // runtime observation owned cache → spawn용 caller buffer
    return buf[0..cwd.len];
}

/// 새 surface(탭/Term/split)가 열릴 cwd를 정한다(Ghostty `*-inherit-working-directory` 모델). `inherit`가
/// 켜졌고 포커스 Term이 cwd를 보고했으면 그 cwd를 상속(focusedTermCwd), 아니면 고정 `root`로 폴백
/// (workspaceRootCwd). 호출자는 surface 종류별 토글(tab_inherit_cwd/split_inherit_cwd)을 `inherit`로 넘긴다.
/// 두 경로 모두 결과를 `buf`에 쓰므로(focusedTermCwd는 락 아래 복사, workspaceRootCwd는 ~ 확장/home), 반환
/// 슬라이스는 `buf` 또는 config arena 소유 — 호출자가 spawn 호출까지 `buf`를 살린다. null이면 req.cwd 미설정.
pub fn newSurfaceCwd(self: *AppSession, buf: []u8, inherit: bool) ?[]const u8 {
    if (inherit) {
        if (focusedTermCwd(self, buf)) |c| return c; // 포커스 Term cwd 상속(켜짐 + 보고됨) — buf로 복사됨
    }
    return workspace_ops.workspaceRootCwd(self, buf); // 꺼졌거나 상속할 cwd 없음 → 고정 root
}

pub fn focusedDockSurface(self: *const AppSession) ?u64 {
    if (self.focus_owner != .workspace or self.tabs.items.len == 0) return null;
    const tab = self.tabs.items[self.app_window.active_tab];
    if (tab.panes.items.len == 0) return null;
    const pane = tab.panes.items[@min(tab.active_pane, tab.panes.items.len - 1)];
    if (pane.terms.items.len == 0) return null;
    const entry = pane.activeTerm().file_entry orelse return null;
    return if (entry.surface_id == 0) null else entry.surface_id;
}

/// 현재 활성 탭의 surface. 모든 입력/IME/스크롤/마우스/렌더 경로가 이 seam을 거친다 —
/// `app_window.active_tab`을 따라가므로 멀티-탭(후속 PR)에서 탭을 전환하면 자동으로 활성 탭에
/// 라우팅된다. 지금은 단일 탭이라 항상 `surfaces[0]`이고 외부 동작은 불변이다. 호출자는 기존대로
/// `surface_initialized`로 가드하므로 `active()`는 non-null이 보장된다.
pub fn activeSurface(self: *AppSession) *maru.session.Surface {
    return self.app_window.active().?;
}

/// `activeSurface`의 읽기 전용(`*const self`) 변형 — `pxToCell`/`imeCursorRect`처럼 surface를
/// 안 바꾸는 const 메서드가 같은 seam을 거치게 한다.
pub fn activeSurfaceConst(self: *const AppSession) *const maru.session.Surface {
    return self.app_window.activeConst().?;
}

/// [4e-2, web-panel.md §6] 활성 탭·활성 pane의 **보이는 Term이 terminal인가**. web이면 활성 render 경로
/// (readActiveSnapshot·shapeOnlyBuild·cell_colors·kitty·find·terminal_bg)와 일부 입력 핸들러가 web **sentinel
/// core**를 만지지 않도록 gate한다(활성 web = 본문 blank·no-terminal-frame, WKWebView는 4e-3서 채움). 활성 없음
/// (surface 미초기화·0탭)은 terminal로 취급해 기존 경로가 그대로 돈다(0탭 조기 반환은 tick 상단이 이미 처리).
/// **web Term이 하나도 없으면 항상 true**라 터미널 렌더·입력이 byte-identical이다. `activeSurface()`와 **같은
/// active_tab 인덱스**를 봐 정합한다(surface_ptrs[active_tab]가 activePane().activeTerm().surface로 동기 유지 —
/// focusTerm/focusPane 등이 재바인딩). `*const`라 mutable tick 경로와 const metalFrame 경로가 함께 쓴다.
pub fn activeTermIsTerminal(self: *const AppSession) bool {
    if (!self.surface_initialized or self.tabs.items.len == 0) return true;
    const tab = self.tabs.items[self.app_window.active_tab];
    const pane = tab.panes.items[tab.active_pane];
    const term = pane.terms.items[pane.active_term];
    return term.kind == .terminal;
}

/// [4e-2, web-panel.md §6] 활성 Term이 terminal이면 그 surface(=`activeSurface()`), web이면 null. 활성 render
/// 경로가 코어를 lock/deref하기 전에 이걸로 gate해 web sentinel deref를 막는다(활성 web = 의도적 no-terminal-frame).
/// terminal이면 `if (activeTerminalSurface(self)) |s|`가 `if (self.surface_initialized) { const s = activeSurface(self); … }`와
/// **동형**이라 byte-identical. surface 미초기화면 null(app_window undefined deref 방지 — 옛 `surface_initialized` 가드 동형).
pub fn activeTerminalSurface(self: *AppSession) ?*maru.session.Surface {
    if (!self.surface_initialized) return null;
    if (!activeTermIsTerminal(self)) return null;
    return activeSurface(self);
}

/// 남아 있는 텍스트 선택(하이라이트)을 해제한다 — 코어 mutate라 reader에 위임한다(docs/io-render-threading.md
/// §9 P3-4의 선택 위임 규율; host-backed면 명령이 host로 라우팅돼 **진짜 코어**에 적용된다).
/// 호출 지점은 "선택을 만든 주체가 아닌 쪽"이 그 선택을 무효로 만드는 곳들이다: 마우스 리포팅 중 버튼
/// 이벤트·휠(그 pane의 마우스는 앱이 소유하니 하이라이트만 남으면 유령), alt-scroll 화살표 변환,
/// 타이핑·Esc(`input.selection-clear-on-typing`). 이 경로들이 없으면 ⌘A(select_all) 선택을 지울 방법이
/// "이동 없는 클릭"과 좌표 무효화(resize reflow·alt 전환)뿐이라, 트래킹 TUI pane에서 하이라이트가 영구히
/// 남는다(클릭이 리포팅으로 빠져 선택을 손도 안 댄다). 베이스: Ghostty Surface.zig — 같은 세 지점에서
/// `setSelection(null)`. 선택이 없으면 코어의 `selectionClear`가 즉시 return하므로 반복 호출은 무해하다.
pub fn clearSurfaceSelection(self: *AppSession, surface_id: u64) void {
    self.enqueueCoreCommandForSurface(surface_id, .select_clear) catch {};
    self.metal_dirty = true; // 해제된 하이라이트가 한 프레임 더 남지 않게(다른 선택 사이트와 같은 규율)
}

/// 그 대상이 bracketed paste 를 켜 두었는가. 터미널 Term 이 아니면 null.
///
/// **`submitPaste` 가 안에서 쓰는 그 판정을 밖에서도 읽어야 한다** — [선택 영역 보내기]
/// (../../../../docs/send-selection-to-agent.md) §4 가 "꺼진 대상에는 여러 줄을 보내지 않는다" 로
/// 정했고, 그 결정은 **페이로드를 만들기 전에** 내려야 하기 때문이다(만든 뒤에 자르면 잘린 인용이
/// 나간다). 판정 규칙 자체는 여기가 아니라 `submitPaste` 와 **같은 두 갈래**를 그대로 쓴다 —
/// host-backed 는 관측, 로컬은 코어 lock 아래 bool 하나.
pub fn bracketedPasteFor(self: *AppSession, target_id: u64) ?bool {
    const loc = findTermWhere(self, target_id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.kind == .terminal and term.surface.id == want;
        }
    }.pred) orelse return null;
    const term = loc.pane.terms.items[loc.term_index];
    if (term.surface.remote != null) {
        // **별칭을 안 만든다** — `const obs = &term.rt.observation` 는 cwd 축 게이트가 세는 우회로다
        // (그 게이트가 이 자리를 잡았다). 두 필드를 직접 읽으면 재고를 올릴 이유가 없다.
        return term.rt.observation.availability != .unavailable and term.rt.observation.bracketed_paste;
    }
    term.surface.lockCore(self.io);
    defer term.surface.unlockCore(self.io);
    return term.surface.core.bracketedPasteEnabled();
}

/// 이 창에서 **보낼 수 있는 대상**들을 §5 순서로 모은다(에이전트 먼저 · 그 안에서 화면 순서).
/// 정렬·라벨 정책은 `session/agent_selection.zig` 가 소유한다 — 여기서는 열거만 한다.
///
/// **폴더 문자열은 호출자 버퍼에 쓴다**(`folder_bufs`). `termCwdForDisplay` 가 버퍼를 받는 API 라
/// 어딘가에 자리가 있어야 하고, 그 자리는 **후보가 사는 동안** 살아 있어야 한다 — 스택 임시에
/// 쓰면 돌아가는 순간 슬라이스가 매달린다.
///
/// **브랜치는 캐시다.** `termGitBranch` 는 cwd 가 바뀔 때만 `.git/HEAD` 를 다시 읽으므로(사이드바가
/// 매 프레임 쓰는 그 함수) 우클릭 경로에서 불러도 된다.
pub fn collectAgentTargets(
    self: *AppSession,
    out: []maru.session.agent_selection.Candidate,
    folder_bufs: [][std.fs.max_path_bytes]u8,
) []maru.session.agent_selection.Candidate {
    var n: usize = 0;
    var order: u32 = 0;
    const tab = self.tabs.items[self.app_window.active_tab];
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            if (term.kind != .terminal) continue;
            if (n >= out.len or n >= folder_bufs.len) break;
            // **폴더와 브랜치로 가른다**(§5) — 사이드바 카드가 쓰는 그 두 축이다. 같은 정보를 두
            // 곳에서 다르게 부르면 사용자가 다른 것으로 읽는다. 폴더가 없으면(원격·비-repo) 그 자리를
            // 비우고 Term 이름으로 대신한다 — 이름조차 없는 줄을 만들지 않는다.
            const folder = git_ops.termCwdForDisplay(self, term, &folder_bufs[n]);
            out[n] = .{
                .surface_id = term.surface.id,
                .kind = switch (term.agent_kind) {
                    .claude => .claude,
                    .codex => .codex,
                    .none => .shell,
                },
                // 실제 셸 이름(zsh 등)은 아직 안 읽는다(§한계) — 지금은 종류만 말한다.
                .shell_name = maru.i18n.t(.ctx_target_shell),
                .where = folder orelse app_session_mod.termLabel(term),
                .branch = git_ops.termGitBranch(self, term),
                .order = order,
            };
            n += 1;
            order += 1;
        }
    }
    const items = out[0..n];
    maru.session.agent_selection.orderCandidates(items);
    return items;
}

pub fn terminalSurfaceById(self: *AppSession, id: u64) ?*maru.session.Surface {
    const loc = findTermWhere(self, id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.surface.id == want;
        }
    }.pred) orelse return null;
    const term = loc.pane.terms.items[loc.term_index];
    if (term.kind != .terminal) return null;
    return term.surface;
}

/// 이 세션(트리)이 `id` surface를 소유하는가(terminal·web 무관 — `terminalSurfaceById`와 달리 kind 필터 없음).
/// grant 확인 모달을 **대상 web surface 소유 창**에 띄우는 판정(§9.2 target-window 모달, app_host_abi가 소비).
pub fn ownsSurface(self: *AppSession, id: u64) bool {
    return findTermWhere(self, id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.surface.id == want;
        }
    }.pred) != null;
}

/// 드롭 지점이 그 pane의 **Term 탭** 위면 그 Term 인덱스(아니면 null — 본문·grip/라벨·‹›/+ 존). 클릭 경로
/// (renameTargetAt)와 같은 paneBar/barMetrics 기하를 쓴다 — 같은 자리를 같은 Term으로 친다.
pub fn dropTermIndexAt(self: *AppSession, pane: *Pane, leaf_rects: []const PaneTree.LeafRect, x_px: f64, y_px: f64) ?usize {
    const rect = for (leaf_rects) |lr| {
        if (lr.leaf == pane) break lr.rect;
    } else return null;
    const pb = pane_ops.paneBar(self, rect, pane) orelse return null;
    if (!layout_math.pointInRect(x_px, y_px, pb.full)) return null; // 바 밖(본문) — pane 활성 Term이 대상
    if (x_px < @as(f64, @floatFromInt(pb.tabs.x))) return null; // grip/라벨 세그먼트
    const count = pane.terms.items.len;
    const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return null;
    if (m.inScrollLeftZone(x_px) or m.inScrollRightZone(x_px) or m.inPlusZone(x_px)) return null; // ‹›/+ 은 대상 아님
    const tab = m.tabIndex(count, x_px);
    // 좌표 → **보이는** 슬롯 → 그 Term → model 인덱스. 반환값은 `pane.terms` 인덱스로 소비되므로(호출자가
    // `terms.items[i]`·`focusTerm(i)`) 변환이 필요하다. renameTargetAt과 같은 자리를 같은 Term으로 치겠다는
    // 이 함수의 약속은 드래그 중에도 지켜져야 한다 — 그쪽은 보이는 순서로 고른다(§4.4).
    const order = pane_ops.paneTermOrder(self, pane);
    if (tab >= order.len) return null;
    return termModelIndex(self, pane, order[tab]);
}

/// `*Term`의 model 인덱스(`pane.terms` 안 위치). 보이는 슬롯으로 고른 Term을 model 인덱스를 기대하는
/// 소비자(focusTerm·moveTermToPane·terms.items[i])에게 넘길 때 쓴다.
pub fn termModelIndex(self: *const AppSession, pane: *const Pane, term: *const Term) ?usize {
    _ = self;
    for (pane.terms.items, 0..) |t, i| {
        if (t == term) return i;
    }
    return null;
}

/// OSC 52 클립보드 쓰기가 상한(≈16MB)을 넘어 거부됐으면 notice로 표면화한다 — 무음 폐기 대신 "왜 복사가
/// 안 됐는지"를 보여주는 값싼 UX 우위(Ghostty의 무음 폐기를 넘음, terminal-compatibility-policy.md §OSC52).
/// pendingClipboard(쓰기 drain)와 같은 활성 surface 스코프. **불청 이벤트라** 오버레이(세팅/find 등)가 열려
/// 있으면 건너뛴다 — showNotice가 그 모달을 닫아 사용자를 끊지 않게(정보는 비필수라 유실 무해). flag 읽기·clear는 락 아래.
pub fn surfaceClipboardWriteRejected(self: *AppSession) void {
    // 인터랙티브 모달(세팅·find·palette·확인 등)이 열려 있으면 건너뛴다 — showNotice가 그걸 닫아 사용자를
    // 끊지 않게. notice는 제외(anyModalOverlayOpen) — 기존 토스트 위엔 그냥 교체돼도 무방하므로.
    if (!self.surface_initialized or self.anyModalOverlayOpen()) return;
    const s = activeSurface(self);
    s.lockCore(self.io);
    const rejected = s.core.takeClipboardWriteRejected();
    s.unlockCore(self.io);
    if (!rejected) return;
    // 값이 끼는 문장 — §6.3 보간 진입점. 버퍼 부족은 `i18n.format`이 UTF-8 경계 절단으로 흡수하므로
    // 옛 `catch <짧은 폴백>` 은 필요 없다(끼는 값이 숫자라 길이가 사실상 고정이다).
    const mb = terminal.clipboard_max_bytes / 1_000_000;
    self.showNoticeFmt(.term_clipboard_too_large, &.{.{ .d = @intCast(mb) }});
}

// --- 호출 그래프로 소유가 확인돼 옮겨 온 함수 ---
// 이름에 도메인 단어가 없어 F 시리즈가 못 잡았고, 이 그룹을 과반으로 부르며 만지는 상태도 이 그룹이다.

/// reap으로 구조가 바뀐 탭의 대표 surface를 그 탭의 현재 활성 Term으로 재바인딩하고(닫힌 Term을 가리키던
/// stale/dangling 방지) panel을 새 leaf rect로 resize한다(collapse면 형제가 빈자리 확장 — 배경 탭도 전환
/// 즉시 올바른 크기). 활성 탭이면 좌표 origin도 재계산하고 redraw를 표시한다(배경 탭 변경은 화면에 안 보임).
pub fn refreshAfterReap(self: *AppSession, tab_index: usize) void {
    const tab = self.tabs.items[tab_index];
    self.surface_ptrs.items[tab_index] = tab.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    pane_ops.resizeTabPanes(self, tab);
    self.hovered_tab = null; // 트리/탭 변경 — stale 호버 정리
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버도 함께 정리(stale 하이라이트 방지)
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    if (tab_index == self.app_window.active_tab) {
        pane_ops.recomputeActivePaneRect(self);
        self.metal_dirty = true;
    }
}

/// 최종 payload(escape 적용 후 평문)를 인코딩해 PTY 큐에 넣는다. allow_unsafe=false면 paste protection
/// 게이트를 먼저 통과해야 하고, 위험(개행/ESC[201~ 인젝션)하면 payload를 세션 소유 버퍼에 보관하고 확인
/// 모달을 띄운 뒤 반환한다(confirmPendingPaste가 allow_unsafe=true로 재호출). 게이트 판정은 core가 단일
/// 출처(pasteNeedsConfirmation — bracketed 상태·설정 반영). 큐/flush는 기존 non-blocking 경로 그대로.
pub fn submitPaste(self: *AppSession, payload: []const u8, allow_unsafe: bool, target_id: u64) void {
    // 대상 surface를 **id로** 잡는다(활성이 아니라). 없거나(닫힌 Term) web이면 붙일 PTY가 없으니 no-op —
    // 예전엔 activeSurface를 그때그때 다시 읽어, 확인 모달을 거친 재진입(confirmPendingPaste)에서 그 사이
    // 바뀐 활성 pane에 payload가 주입되거나 web sentinel의 core를 만져 조용히 사라졌다(code-review).
    const surface = terminalSurfaceById(self, target_id) orelse return;
    var needs_confirm: bool = undefined;
    var bracketed: bool = undefined;
    if (surface.remote != null) {
        // host-backed(영속 세션): placeholder core에는 bracketed-paste 모드가 없다(진짜 코어는 host 프로세스라
        // DECSET 2004는 host core만 안다). 관측(RuntimeObservation.bracketed_paste)에서 온 실제 모드로 판정·인코딩해야
        // Claude Code 등이 붙여넣은 파일 경로를 [Image]로 인식한다(§입력 패리티). bracketed는 paste-protection 게이트에도
        // 필요한 클라 판단 모드라 관측으로 스트리밍한다(mouse_tracking과 같은 게이트-모드). 관측은 client cache라 core lock 불요.
        const loc = findTermWhere(self, surface.id, struct {
            fn pred(id: u64, term: *Term) bool {
                return term.kind == .terminal and term.surface.id == id;
            }
        }.pred) orelse return;
        const obs = &loc.pane.terms.items[loc.term_index].rt.observation;
        bracketed = obs.availability != .unavailable and obs.bracketed_paste;
        needs_confirm = !allow_unsafe and maru.terminal.pasteNeedsConfirmationWith(
            bracketed,
            payload,
            self.loaded_config.config.input.paste_protection,
            self.loaded_config.config.input.bracketed_paste_is_safe,
        );
    } else {
        // **로컬 코어 접근은 lockCore 하에서** — 대상이 활성 pane이 아닐 수 있고(대상 고정), 그 pane의 PTY reader
        // 스레드가 같은 코어를 쓴다. 판정(pasteNeedsConfirmation)과 인코딩에 필요한 bracketed를 한 번에 잠금 안에서
        // 끝내고, 모달 열기·큐 적재는 잠금 밖에서 한다(모달/할당을 잠금 안에서 하지 않는다 — 경합 시간 최소).
        surface.lockCore(self.io);
        needs_confirm = !allow_unsafe and surface.core.pasteNeedsConfirmation(
            payload,
            self.loaded_config.config.input.paste_protection,
            self.loaded_config.config.input.bracketed_paste_is_safe,
        );
        bracketed = surface.core.bracketedPasteEnabled(); // 인코딩에 필요한 유일한 코어 상태 — bool만 복사
        surface.unlockCore(self.io);
    }
    // **인코딩은 락 밖에서**: 멀티MB payload의 할당·복사를 코어 뮤텍스 안에서 하면 그동안 그 pane의 PTY
    // reader 스레드가 막힌다(code-review). 순수 변형(encodePasteWith)이 bool 하나만 받는다.
    const encoded_opt: ?[]u8 = if (needs_confirm) null else (maru.terminal.encodePasteWith(bracketed, self.allocator, payload) catch null);
    if (needs_confirm) {
        // 위험 → 바로 실행 대신 확인. showConfirmButtons가 (paste 포함) 다른 보류를 비우므로 그 호출
        // *뒤에* 보관한다(requestAppQuit의 pending_quit 순서와 동형 — 자기 payload를 자기가 안 지움).
        self.showConfirmKeys(.{ .paste = target_id }, paste_confirm_key, .{ .confirm = .btn_paste });
        // 미리보기 주입: 붙여넣을 내용을 확인창에 함께 보여준다(Ghostty식). show가 body를 리셋하므로 그 뒤에 준다.
        self.chrome_host.confirm.body = self.buildPastePreview(payload);
        self.pending_paste_confirm.clearRetainingCapacity();
        self.pending_paste_confirm.appendSlice(self.allocator, payload) catch {
            // 보관 실패(OOM): 유령 확인(예 눌러도 아무것도 안 붙는)을 막으려 모달도 닫는다.
            self.pending_paste_confirm.clearRetainingCapacity();
            self.chrome_host.confirm.dismiss();
        };
        return;
    }
    const encoded = encoded_opt orelse return; // 인코딩 실패(OOM) — 조용히 버린다
    defer self.allocator.free(encoded);
    // 대상 surface 큐에 쌓고 즉시 flush를 시도한다. 자식이 읽는 중이면 보통 이 자리에서 다 들어가고,
    // 안 읽으면(vim 다이얼로그 등) 잔여가 tick마다 흘러나간다 — blocking 단일 write로 UI가
    // 동결되던 것을 없앤다. 큐는 surface별 FIFO라 bracketed paste 감싸기 순서는 깨지지 않는다.
    _ = self.enqueueInputBytes(target_id, encoded, false); // OOM이면 유실(best-effort — 크래시보다 낫다)
}

/// OSC 52 클립보드 쓰기 요청을 내부 버퍼로 돌려준다(없으면 빈 슬라이스). Swift가 NSPasteboard에 쓴다.
/// **정책**(terminal-compatibility-policy.md §OSC52, 사용자 결정 2026-06-20): write는 기본 `allow` — 로컬
/// 단일 사용자 데스크톱 터미널이라 트래킹 앱의 드래그 복사를 시스템 클립보드에 반영한다(iTerm2/Ghostty도 유사).
/// **read**는 클립보드 탈취 방지로 계속 deny한다 — core가 `?` 쿼리에 응답하지 않아 read 요청은 여기 안 온다.
/// 코어 pending을 비워(한 번 쓰고 소비) 같은 데이터가 다음 tick에 또 쓰이지 않게 한다. ask(요청별 확인 UI)는 후속.
pub fn pendingClipboard(self: *AppSession) []const u8 {
    if (!self.surface_initialized) return &.{};
    // 슬라이스 4: 주소창 ⌘X가 넣은 클립보드 쓰기가 있으면 우선 반환(OSC52 write와 같은 drain 경로 — Swift가 NSPasteboard에
    // 씀). 소유권을 clipboard_out_buffer로 이전해 반환 수명(다음 pendingClipboard까지) 계약을 그대로 만족한다.
    if (self.chrome_clipboard_write.len > 0) {
        if (self.clipboard_out_buffer.len > 0) self.allocator.free(self.clipboard_out_buffer);
        self.clipboard_out_buffer = self.chrome_clipboard_write;
        self.chrome_clipboard_write = &.{};
        return self.clipboard_out_buffer;
    }
    // host-backed: core는 빈 placeholder라 OSC 52가 안 들어온다. host가 관측 seq로 알려 준 요청만 RPC로
    // 텍스트를 가져온다(텍스트가 커서 관측에 못 싣는다). 정책(write allow)과 NSPasteboard 쓰기는 로컬과
    // 동일하게 client가 한다 — §기능을 어느 쪽에 둘 것인가.
    if (is_macos and activeSurface(self).remote != null) {
        const term = pane_ops.activePane(self).activeTerm();
        const rb = &(app_session_mod.app_remote_backend orelse return &.{});
        const fetched = rb.clipboardWriteFor(term.rt.handle) orelse return &.{};
        if (fetched.too_large) {
            // 로컬의 오버사이즈 안내와 같은 자리(조용한 유실 금지). 텍스트는 없다.
            const kb = session_host.runtime_manager.max_clipboard_wire_bytes / 1024;
            self.showNoticeFmt(.term_remote_clipboard_too_large, &.{.{ .d = @intCast(kb) }});
            return &.{};
        }
        const text = fetched.text orelse return &.{};
        if (self.clipboard_out_buffer.len > 0) self.allocator.free(self.clipboard_out_buffer);
        self.clipboard_out_buffer = text; // backend allocator 소유 바이트를 그대로 인계(다음 호출까지 유효)
        return self.clipboard_out_buffer;
    }
    const pending = activeSurface(self).core.pendingClipboardWrite();
    if (pending.len == 0) return &.{};
    if (self.clipboard_out_buffer.len > 0) {
        self.allocator.free(self.clipboard_out_buffer);
        self.clipboard_out_buffer = &.{};
    }
    self.clipboard_out_buffer = self.allocator.dupe(u8, pending) catch return &.{};
    activeSurface(self).core.clearClipboardWrite();
    return self.clipboard_out_buffer;
}

/// MARU_DEBUG일 때 활성 surface의 cell 격자를 찍는다. CJK 등 비-ASCII는 텍스트 줄에서
/// 공백으로 보이지만 배경 줄(b...)의 'B'로 영역을 알 수 있어, 파란 배경 줄과 프롬프트 줄이
/// 같은 row에 겹치는지(개행 안 됨) 다른 row인지 데이터로 구분한다.
pub fn logScreenIfDebug(self: *AppSession) void {
    if (!diag_gate.maruDebugEnabled() or !self.surface_initialized) return;
    if (!activeTermIsTerminal(self)) return; // [4e-2, §6] 활성 web Term은 sentinel core라 화면 덤프 skip
    const core = &activeSurface(self).core;
    const cols = @min(@as(usize, core.size.cols), 240);
    // 헤더에 OSC 133 마지막 명령 종료코드도 찍는다(셸 통합이 emit하면 채워진다).
    if (core.last_command_exit) |code| {
        screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) last_exit={d} ===", .{
            core.size.cols, core.size.rows, core.screen.cursor.row, core.screen.cursor.col, code,
        });
    } else {
        screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) ===", .{
            core.size.cols, core.size.rows, core.screen.cursor.row, core.screen.cursor.col,
        });
    }
    // 창 제목/사이드바와 같은 runtime observation cwd를 찍는다(host-backed placeholder core 오진 방지).
    const cwd = pane_ops.activePane(self).activeTerm().rt.observation.cwd.items;
    if (cwd.len > 0) screen_diag.info("cwd={s}", .{cwd});
    var text: [240]u8 = undefined;
    var bg: [240]u8 = undefined;
    const grid_cols: usize = core.size.cols;
    for (0..core.size.rows) |row| {
        var any = false;
        for (0..cols) |col| {
            const cell = core.screen.cells[row * grid_cols + col];
            const cp = cell.codepoint;
            text[col] = if (cp >= 0x20 and cp < 0x7f) @intCast(cp) else ' ';
            const has_bg = switch (cell.style.background) {
                .default => false,
                else => true,
            };
            bg[col] = if (has_bg) 'B' else '.';
            if ((cp != 0 and cp != ' ') or has_bg) any = true;
        }
        // soft-wrap 플래그를 함께 찍는다(w=다음 줄로 이어짐, .=hard 줄끝). reflow 피드백 루프
        // 회귀는 hard 줄(프롬프트)이 w로 잘못 찍히는 것으로 드러나므로, wrapped인 빈 줄도 보인다.
        const w_mark: u8 = if (row < core.screen.wrapped.len and core.screen.wrapped[row]) 'w' else '.';
        // OSC 133 semantic 분류(P=프롬프트 I=입력 C=명령출력 ·=미분류). 셸 통합이 마커를 emit하면
        // 채워진다 — 프롬프트/입력/출력이 어떤 행으로 잡히는지 데이터로 본다(거터 PR 전 조기 확인).
        const p_mark: u8 = if (row < core.screen.prompt_marks.len) switch (core.screen.prompt_marks[row].kind) {
            .unknown => '.',
            .prompt => 'P',
            .input => 'I',
            .command => 'C',
        } else '.';
        if (!any and w_mark != 'w' and p_mark == '.') continue;
        screen_diag.info("r{d:0>2} {c}{c} t|{s}|", .{ row, w_mark, p_mark, text[0..cols] });
        screen_diag.info("r{d:0>2} {c}{c} b|{s}|", .{ row, w_mark, p_mark, bg[0..cols] });
    }
}

/// 프레임마다 셸 의미 이벤트(OSC 133/7)를 소비한다 — MARU_DEBUG면 명령 경계를 구조화 한 줄씩
/// 찍고, 항상 비워 core의 이벤트 버퍼를 bounded하게 유지한다(누구도 drain 안 하면 cap에서 드롭).
/// 같은 도메인 데이터를 후속 trace writer도 바로 이 자리에서 drain하면 된다(관측 가능성 원칙).
///
/// **이 스트림을 제품 신호로 쓰지 마라.** 비우는 대상이 **활성 Term 하나**고(원격은 통째로 skip) 매 프레임
/// 비우므로, 비활성 Term의 이벤트는 아무도 못 보고 활성 Term의 이벤트도 다른 소비자가 보기 전에 사라진다.
/// `.cwd_changed`를 "OSC 7이 방금 왔다"는 신호로 쓰려다 여기서 걸렸다(docs/editor-surface-dock.md §3.5의
/// 낡은 OSC 7 항목). 필요하면 이 자리에서 함께 drain하도록 소비자를 여기에 붙이거나, 그 전에 드레인 범위를
/// 전체 Term으로 넓혀라. 스트림 자체의 단일 출처는 docs/trace-replay.md의 "Shell integration event"다 —
/// 이 배선 제약도 거기 적혀 있다.
pub fn drainShellEventsForFrame(self: *AppSession) void {
    if (!self.surface_initialized) return;
    if (!activeTermIsTerminal(self)) return; // [4e-2, §6] 활성 web Term은 sentinel(셸 이벤트 없음) — skip
    if (pane_ops.activePane(self).activeTerm().surface.remote != null) return; // host shell-event transport는 아직 없음; placeholder 진단 금지
    const core = &activeSurface(self).core;
    if (core.shellEvents().len == 0 and !core.shellEventsOverflowed()) return;
    if (diag_gate.maruDebugEnabled()) {
        for (core.shellEvents()) |ev| switch (ev) {
            .prompt_start => |r| shell_diag.info("shell.prompt-start row={d}", .{r}),
            .input_start => |r| shell_diag.info("shell.input-start row={d}", .{r}),
            .command_start => |r| shell_diag.info("shell.command-start row={d}", .{r}),
            .command_end => |ce| if (ce.exit) |code|
                shell_diag.info("shell.command-end row={d} exit={d}", .{ ce.row, code })
            else
                shell_diag.info("shell.command-end row={d} exit=?", .{ce.row}),
            .cwd_changed => shell_diag.info("shell.cwd-changed cwd={s}", .{core.currentCwd()}),
        };
        // 조용한 손실 방지: cap을 넘어 드롭된 이벤트가 있으면 보고한다.
        if (core.shellEventsOverflowed()) shell_diag.info("shell.events OVERFLOW: cap 초과로 일부 이벤트 드롭", .{});
    }
    core.clearShellEvents();
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// 화면 상태 진단 logger. MARU_DEBUG일 때 frame build마다 TerminalCore의 cell 격자(cursor 위치 +
// 줄별 텍스트/배경)를 찍어, "개행 안 되고 덮어씀" 같은 cursor/scroll 동작을 데이터로 확인한다.
// MARU_DEBUG 게이트는 diag.zig가 단일 출처로 소유한다.
pub const screen_diag = std.log.scoped(.screen);

// 셸 의미 이벤트(OSC 133/7) 진단 logger. MARU_DEBUG일 때 frame마다 core가 기록한 명령 경계
// 이벤트를 구조화 한 줄씩 찍는다 — 같은 도메인 데이터를 테스트·후속 trace writer도 이 자리에서
// drain한다(관측 가능성 원칙). 게이트는 diag.zig 단일 출처.
pub const shell_diag = std.log.scoped(.shell);
