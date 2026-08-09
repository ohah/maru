//! pane(분할 영역)·split·divider — 분할/합치기, pane 포커스·드래그, divider 히트테스트·드래그,
//! pane별 탭 바·스크롤바 발행, pane 단위 Term 생성/복원.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F4).
//!
//! 경계는 이름이 아니라 **호출 관계**로 잡았다(F1·F2의 교훈). 흡수분은 호출 사슬로 소유를 재확인했다 —
//! `createRestoredTerm`·`restoreSpawn`·`recordEndedPlaceholder`는 workspace 복원처럼 보이지만
//! `createPaneFromSurface`/`createTermFromSurface`가 부르는 **pane 생성 경로**이고,
//! `fillTabDragSmokeProbe`는 이름이 tab이지만 `dividerSmokeProbe`가 채운다.
//!
//! 이름 매칭의 함정 둘을 기록해 둔다. (1) `pane` 부분 문자열은 **`filePanel`에도 걸린다**(`filepanel`) —
//! F2가 가져간 파일 패널 함수 30개가 그 탓에 처음 seed에 섞였다. (2) 호출부를 `<변수>.method(` 패턴으로
//! 일괄 치환하면 **같은 이름의 다른 타입 메서드**까지 바뀐다(`tab.activePane()`은 Tab의 것이다).
//! 치환은 `self.`에 한정하고 나머지는 컴파일러가 짚어 준 자리만 고친다.
//!
//! `splitActivePane`·`collapsePane`·`focusPaneInDirection`이 여기 있는 것은
//! layering-and-portability.md §3.2와 어긋나지 않는다. 그 문서가 "spawn·resize 강결합이라 platform
//! 잔류"라고 한 것은 **session(L2)으로 보내지 말라**는 뜻이고 이 파일은 같은 L4다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const layout_math = maru.session.layout_math;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const web_ops = @import("web.zig");
const workspace_ops = @import("workspace.zig");
const settings_ops = @import("settings.zig");
const scroll_ops = @import("scroll.zig");
const sidebar_ops = @import("sidebar.zig");
const tab_ops = @import("tab.zig");
const dock_ops = @import("dock.zig");
const PendingDockFocus = app_session_mod.PendingDockFocus;
const file_panel_ops = @import("file_panel.zig");
const chrome_system_text = app_session_mod.chrome_system_text;
const MeasuredTextCache = app_session_mod.MeasuredTextCache;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const packRgbAlpha = app_session_mod.packRgbAlpha;
const diag_gate = app_session_mod.diag_gate;
const scrollbar_alpha_full = app_session_mod.scrollbar_alpha_full;
const tabTitleRunningMarker = @import("tab.zig").tabTitleRunningMarker;
const panelKindForEntryKind = AppSession.panelKindForEntryKind;
const restoreFailureDisposition = AppSession.restoreFailureDisposition;
const scrollbarBarWidthPx = @import("scroll.zig").scrollbarBarWidthPx;
const tabTitleBody = @import("tab.zig").tabTitleBody;
const Model = app_session_mod.Model;
const barMetrics = app_session_mod.barMetrics;
const commandName = app_session_mod.commandName;
const coretext_bridge = app_session_mod.coretext_bridge;
const sentinelBgCell = app_session_mod.sentinelBgCell;
const usableRestoreCwd = app_session_mod.usableRestoreCwd;
const CollectDest = AppSession.CollectDest;
const FileOpenResult = AppSession.FileOpenResult;
const isBrowserTerm = @import("web.zig").isBrowserTerm;
const pane_grip_cols = AppSession.pane_grip_cols;
const scrollbarThumbGeom = @import("scroll.zig").scrollbarThumbGeom;
const AgentKind = app_session_mod.AgentKind;
const FocusDirection = app_session_mod.FocusDirection;
const PendingClose = app_session_mod.PendingClose;
const activeIndexAfterRemoval = app_session_mod.activeIndexAfterRemoval;
const app = app_session_mod.app;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const dock_layout = app_session_mod.dock_layout;
const dock_panel = app_session_mod.dock_panel;
const metal_frame = app_session_mod.metal_frame;
const restoreSurfaceSize = app_session_mod.restoreSurfaceSize;
const spawnRequest = app_session_mod.spawnRequest;
const web_panel_layout = app_session_mod.web_panel_layout;
const CollectedPane = AppSession.CollectedPane;
const DividerSmokeProbe = AppSession.DividerSmokeProbe;
const FileHeaderBand = AppSession.FileHeaderBand;
const PaneBar = AppSession.PaneBar;
const PaneDropDest = AppSession.PaneDropDest;
const PaneGeometry = AppSession.PaneGeometry;
const pane_min_tab_cols = AppSession.pane_min_tab_cols;
const scrollStateOf = @import("scroll.zig").scrollStateOf;
const termHasRunningJob = AppSession.termHasRunningJob;
const termIsWebBrowser = @import("web.zig").termIsWebBrowser;
const Pane = app_session_mod.Pane;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const PaneTree = app_session_mod.PaneTree;

pub fn newWebTermInActivePane(self: *AppSession, panel_kind: web_panel_layout.PanelKind) !void {
    _ = try appendWebTermInActivePane(self, panel_kind);
}

/// **세션-트리 구조-무효화 계약(S1)의 단일 출처.** 한 Pane이 해제되기 직전 destroyPane이 부른다 — 모든
/// 트리 변형(closeTab·closeActivePane·collapsePaneIn·applyWorkspaceWindow·reap)이 노드 해제 시 destroyPane을
/// 거치므로, 이 한 지점이 흩어진 null화 없이 stale 포인터 UAF를 구조적으로 막는다(스냅샷 가드는 UAF를 못 잡는다
/// — docs/layering-and-portability.md §6, [[devsession-undefined-test-field-trap]]).
///
/// **표적 무효화**(`*Pane` 포인터): 해제되는 바로 이 Pane을 가리키던 hover/drag 포인터만 비운다 — 다른 Pane을
/// 가리키면 유지한다. 이게 핵심: 무관한 Pane 닫힘(또는 reap)이 진행 중 탭 드래그/호버를 끊지 않으면서, 드래그
/// 중인 Pane 자체가 reap으로 해제되는 비동기 UAF는 닫는다(tick reap ↔ 마우스 드래그가 메인 스레드에서 교차).
///
/// **보수적 무효화**(`hovered_slot`=슬롯 인덱스): 슬롯 인덱스는 pane 수에 의존해 어느 Pane
/// 해제든 stale이 되므로 비운다(캐시라 다음 이동이 재설정). `divider_drag`(*Split)는 여기서 안 건드린다 —
/// removeLeaf가 떼어낸 split을 돌려주므로 그 호출처(collapsePaneIn·closeActivePane)가 invalidateForFreedSplit으로
/// **표적** 무효화하고, 트리 통째 해제(destroyTabStandalone)는 거기서 따로 비운다.
pub fn invalidateForFreedPane(self: *AppSession, pane: *Pane) void {
    if (self.hovered_tab) |ht| {
        if (ht.pane == pane) self.hovered_tab = null;
    }
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버는 transient(surface_id 키) — pane 해제 시 보수적으로 비운다(다음 이동이 재설정)
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    switch (self.pointer_gesture_owner) {
        .terminal_tab => |drag| if (drag.pane == pane) self.finishPointerGesture(),
        .pane => |drag| if (drag.pane == pane) self.finishPointerGesture(),
        // scrollbar payload에는 surface identity가 없으므로 pane teardown에서 보수적으로 capture를 끝낸다.
        .scrollbar => self.finishPointerGesture(),
        else => {},
    }
    // rename 대상이 이 pane이면 stale 포인터가 안 되게 비운다(teardown 중이라 closeRename의 부수효과 없이 직접).
    if (renamingPane(self, pane)) {
        self.rename = null;
        self.rename_input.clear();
    }
    // 컨텍스트 메뉴 대상이 이 pane이면 메뉴를 닫고 대상을 비운다(stale 포인터 방지).
    if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .pane and t.pane == pane) {
        self.context_menu_target = null;
        self.chrome_host.context_menu.hide();
    };
    self.hovered_slot = null;
    // chrome ChromeState 훅(현재 무동작). 핸들 기반 드래그 상태가 C2/C3서 ChromeState로 이주하면 여기 한 줄이
    // 그 무효화를 떠맡는다 — destroyPane 단일 chokepoint라 호출처는 그대로 따라온다(docs/chrome-strategy.md §5.5).
    self.chrome_host.interaction.invalidateForStructuralChange();
}

/// 이미 열린 파일이면 그 Term으로 이동·활성화하고, 아니면 활성 pane에 새 파일 Term을 만든다.
/// 경로 유일성은 pane별이 아니라 **창 전체** 불변식이다(§1).
pub fn openFileTermInActivePane(
    self: *AppSession,
    path: []const u8,
    kind: dock_panel.EntryKind,
) !FileOpenResult {
    // diff는 위 유일성 키가 다르므로 경로만으로 기존 Term을 재사용하지 않는다(그 확인은 openDiffTerm이 한다).
    if (kind != .diff) {
        if (file_panel_ops.fileTermForPath(self, path)) |existing| return self.activateExistingFileTerm(existing);
    }

    // 창당 상한. 옛 `DockPanel.open`이 모델 불변식으로 걸던 것을 열기 시점 검사로 옮겼다(§10 열린 질문 2번).
    var count: usize = 0;
    var it = file_panel_ops.fileEntries(self);
    while (it.next()) |_| count += 1;
    if (count >= dock_panel.max_entries) return error.TooManyEntries;

    const pane = activePane(self);
    const previous_active_term: ?*Term = if (pane.terms.items.len > 0) pane.activeTerm() else null;

    const entry = try self.allocator.create(dock_panel.Entry);
    errdefer self.allocator.destroy(entry);
    const owned_path = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(owned_path);
    entry.* = .{
        .id = try app_session_mod.app_runtime.entry_ids.next(),
        .path = owned_path,
        .kind = kind,
        .mode = dock_panel.Mode.defaultFor(kind),
    };
    const term = try web_ops.createWebTerm(self, panelKindForEntryKind(kind));
    // 이 시점 term.file_entry는 null이라 destroyTerm이 entry를 건드리지 않는다 — 위 errdefer가 소유를 지킨다.
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    // 소유권이 여기서 Term으로 넘어간다. 이후 실패 지점이 없으므로 위 errdefer들은 돌지 않는다.
    term.file_entry = entry;
    entry.surface_id = term.surfaceId();
    self.focusTerm(pane.terms.items.len - 1);
    // 파일을 열면 탐색기도 함께 나타난다 — 옛 `DockPanel.open`이 세우던 자리다. FP16에서 도크가
    // 탐색기 전용이 된 뒤에도 "파일을 열면 그 파일이 있는 프로젝트를 볼 수 있어야 한다"는 계약은 같다.
    self.dock.presented = true;
    return .{ .term = term, .created = true, .previous_active_term = previous_active_term };
}

/// tick이 부르는 소비 지점 — 계약 §4.3. move 이벤트가 몇 번 왔든 최종 좌표 하나만 적용하고,
/// clamp 결과가 직전과 같으면 resize 팬아웃 자체를 하지 않는다.
pub fn applyPendingDividerResize(self: *AppSession) void {
    const point = self.divider_coalescer.take() orelse return;
    const seg = self.divider_capture_seg orelse return;
    const split = self.divider_capture_split orelse return;
    const raw = chrome.components.divider.dragRatio(seg, point.x_px, point.y_px) orelse return;
    // 클램프는 host가 한다(maru.session.clampRatio — layout과 같은 한도, chrome은 app 상수를 모른다).
    const clamped = maru.session.clampRatio(raw);
    if (!self.divider_coalescer.commitIfChanged(clamped)) return;
    split.ratio = clamped;
    self.divider_resize_applications +|= 1;
    resizeActiveTabPanes(self) catch {};
    recomputeActivePaneRect(self);
    self.metal_dirty = true;
}

pub fn paneLabelCols(pane: *const Pane, bar_cols: u32) u32 {
    const name = app.pickLabel(pane.custom_name, "");
    if (name.len == 0) return 0;
    return paneLabelColsForWidth(chrome.text_layout.displayCols(name, null), bar_cols); // pane 라벨(사용자 텍스트) — 아이콘 widen 안 함
}

/// panel 사이 divider 선 색(0xAARRGGBB) — 활성 하이라이트 색을 써서 두 panel 사이 경계가 또렷하게 보이게.
pub fn dividerColor(self: *const AppSession) u32 {
    // divider(검색바 하단 언더바·pane split 선)는 **중립 패널색(sidebar_background)**에서 파생한다 — 예전엔 sidebar_active를
    // 직접 썼는데, dark_pink처럼 sidebar_active에 **채도 높은 accent(로즈)**를 준 테마에선 그 라인이 중립 크롬 위에서 튄다
    // (사용자 피드백 "Search 언더바 색이 따로 논다"). 배경보다 살짝 밝게(+24)로 둔다 — sidebar_*를 파생으로 두는 테마에선
    // sidebar_background(=배경+24)에 +24가 곧 sidebar_active(=배경+48)라 **기존과 동일**(회귀 없음), 명시-active 테마만 중립화.
    const b = self.appearance.theme.sidebar_background;
    const r: u32 = @min(@as(u32, b.r) + 24, 255);
    const g: u32 = @min(@as(u32, b.g) + 24, 255);
    const bch: u32 = @min(@as(u32, b.b) + 24, 255);
    return 0xFF00_0000 | (r << 16) | (g << 8) | bch;
}

pub fn layoutActiveTabDividers(self: *AppSession, out: *std.ArrayList(PaneTree.DividerSeg)) !void {
    try PaneTree.layoutDividers(self.allocator, tab_ops.activeTab(self).tree, self.termRect(), out);
}

/// Cmd+W 정책(계층 cascade): 활성 pane에 Term이 2개 이상이면 활성 Term을, 1개뿐이면 pane(split이면 collapse)을,
/// 단일 pane이면 워크스페이스(탭/창)를 닫는다. cascade 판단은 resolveCloseScope 단일 출처라, 여긴 그 진입점으로
/// 위임하는 얇은 별칭이다(직접 호출하는 테스트·문서용 이름 유지).
pub fn closeActiveTermOrPane(self: *AppSession) void {
    self.executeClose(.term_or_pane);
}

/// 마우스 (x,y)가 활성 탭 어느 divider의 드래그 밴드 안인가 — 맞으면 그 DividerSeg, 아니면 null. 밴드는 경계
/// pos ± (cell 절반 + margin), 교차축은 bounds 안. 렌더 divider(같은 layoutDividers)와 정렬돼 "보이는 =
/// 잡히는". 단일 panel이면 항상 null(divider 없음). 마우스 down(1) divider 드래그 시작 판정에 쓴다.
/// 마우스 (x,y)가 어느 divider 드래그 밴드 안인가 — 맞으면 {neutral Seg, 라이브 *Split}, 아니면 null. app DividerSeg는
/// hover_divider_scratch에, neutral 변환은 divider_seg_scratch에(index 일치) — chrome `divider.hitTest`가 후자로 판정하고,
/// 그 index의 **neutral seg**(드래그/커서가 직접 씀 — 재변환 없음)와 split을 돌려준다(보이는==잡히는). split만 app.
/// ⚠️ 반환값은 두 scratch 버퍼의 **borrow**다 — **다음 dividerAtPoint 호출 전에 소비**하라(scratch를 clear+재기록하므로
/// 보관/aliasing 금지). 현 호출처(down=divider_drag_seg로 값 복사, hover=hit.seg.orientation 즉시 읽기)는 안전하다.
pub fn dividerAtPoint(self: *AppSession, x_px: f64, y_px: f64) ?struct { seg: chrome.components.divider.Seg, split: *PaneTree.Split } {
    const segs = &self.hover_divider_scratch;
    segs.clearRetainingCapacity();
    layoutActiveTabDividers(self, segs) catch return null;
    self.divider_seg_scratch.clearRetainingCapacity();
    for (segs.items) |seg| self.divider_seg_scratch.append(self.allocator, appSegToDivider(seg)) catch return null;
    const i = chrome.components.divider.hitTest(self.divider_seg_scratch.items, self.cell_width_px, self.cell_height_px, x_px, y_px) orelse return null;
    return .{ .seg = self.divider_seg_scratch.items[i], .split = segs.items[i].split };
}

/// 복원 surface 하나를 라이브 Term으로 만드는 **단일 분기점**. host runtime이 영구히 없으면
/// (`error.PersistentRuntimeGone`) 창 전체를 실패시키는 대신 **그 Term만 종료 placeholder**로 만들어, 탭·split·창
/// frame은 정상 복원한다(§7 "나머지는 attach, 누락 Term만 종료 placeholder"). `PersistentRuntimeUnavailable`은 그대로
/// 전파해 현행 fail-close를 유지한다 — 일시 실패를 placeholder로 굳히면 살아 있는 runtime을 영구히 잃는다.
/// pane 진입점과 term 진입점이 이 함수를 공유해 분기가 한 곳에만 있다.
pub fn createRestoredTerm(self: *AppSession, sm: maru.session.workspace.Surface) !*Term {
    if (sm.runtime_state == .ended) {
        recordEndedPlaceholder(self, false);
        // 이미 완전하게 표현된 tombstone은 attach/probe/spawn 경계에 들어가지 않는다. restoreSpawn도 호출하지 않아
        // 임시 identity 채널을 오염시키지 않는다.
        return try createEndedPlaceholderTerm(
            self,
            sm.title,
            sm.cwd,
            sm.command,
            restoreSurfaceSize(sm),
            sm.runtime_host_id,
            sm.runtime_id,
        );
    }
    const rs = restoreSpawn(self, sm);
    errdefer clearRestoreRuntimeIdentity(self);
    const cfg = self.new_tab_config;
    return self.createTerm(rs.req, rs.size, cfg.queue_capacity, "Maru", commandName(cfg.command_kind)) catch |err| {
        _ = try restoreFailureDisposition(err, sm.runtime_host_id.len > 0);
        clearRestoreRuntimeIdentity(self); // createTerm이 이미 소비했지만 멱등 방어
        recordEndedPlaceholder(self, true);
        // 관측: 묘비 1개당 한 줄(MARU_DEBUG 게이트). **cwd는 남기지 않는다** — 홈 경로가 노출되면
        // project-rules.md redaction 기준에 걸린다. host/runtime id는 opaque hex라 안전하다.
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.restore).info(
            "ended placeholder host={s} runtime={s} cols={d} rows={d}",
            .{ sm.runtime_host_id, sm.runtime_id, rs.size.cols, rs.size.rows },
        );
        return try createEndedPlaceholderTerm(
            self,
            sm.title,
            sm.cwd,
            sm.command,
            rs.size,
            sm.runtime_host_id,
            sm.runtime_id,
        );
    };
}

/// per-pane 가로 탭 바의 backing 픽셀 높이. 높이 자체는 도크 뷰 스위처와 공유하는 `chromeBarHeightPx`가
/// 정하고, 여기서는 **터미널 쪽 게이트만** 얹는다. 제목은 origin_y를 pad_y만큼 내려 바 가운데에 두고,
/// paneTermRect가 이 높이만큼 내려 터미널 영역을 잘라 바와 터미널 첫 줄이 안 겹친다.
/// chrome_minimal(quick terminal minimal)이면 0 — 바를 안 예약해 paneTermRect/paneBarRect가 탭 바를 통째로 끈다.
pub fn paneBarHeightPx(self: *const AppSession) u32 {
    if (self.chrome_minimal) return 0;
    return self.chromeBarHeightPx();
}

/// 활성 탭의 포커스된 panel. live_pty/pump/surface 접근(입력·커서·frame_loop pump)에 쓴다.
pub fn activePane(self: *AppSession) *Pane {
    return tab_ops.activeTab(self).activePane();
}

pub fn dividerTargetRect(rect: maru.session.SplitRect) web_panel_layout.RectF64 {
    return .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
}

/// rename 편집 텍스트의 표시폭(칸) = query(EAW) + preedit(EAW) + caret 1칸. paneBar가 편집 중 라벨 폭을 이걸로
/// 잡아, 이름이 비어도(편집 시작) 세그먼트가 떠 caret이 보인다.
pub fn renameDisplayWidth(self: *const AppSession) usize {
    return settings_ops.renameQueryCols(self) + chrome.text_layout.displayCols(self.rename_input.preedit.items, null) + 1;
}

/// 주어진 탭(활성/배경)의 각 panel을 자기 leaf rect grid로 resize한다 — reap collapse 후 형제가 빈자리
/// 확장. best-effort: 임의 탭이라 모든 Term 에러를 무시한다(resizeActiveTabPanes는 활성 Term 에러를 resize()
/// try 계약대로 전파하지만, 이 경로는 자동 정리라 한 panel 실패가 다른 재배치를 막지 않게 한다). 레이아웃
/// 실패(OOM)는 무시(다음 resize/tick이 다시 맞춘다).
pub fn resizeTabPanes(self: *AppSession, tab: *Tab) void {
    if (layoutGeometryUnknown(self)) return; // 기하 미확정 구간의 2×1 오염 방지 — layoutGeometryUnknown 주석
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    PaneTree.layout(self.allocator, tab.tree, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        const trect = paneTermRect(self, lr.rect);
        const psize = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, trect.w, trect.h);
        for (lr.leaf.terms.items) |term| {
            self.resizeTermForLayout(term, psize) catch |err| self.noteResizeDeliveryFailure(term, err); // 표시 grid는 헬퍼가 보장, 전달 실패만 관측
        }
    }
}

/// 복원 모델의 파일 Term 하나를 라이브 web Term + entry로 되살린다. 소유는 라이브 열기와 같다 —
/// Term이 entry와 path를 든다(§1).
pub fn createFileTermFromModel(self: *AppSession, m: maru.session.workspace.FileTerm) !*Term {
    const entry = try self.allocator.create(dock_panel.Entry);
    errdefer self.allocator.destroy(entry);
    const owned_path = try self.allocator.dupe(u8, m.path);
    errdefer self.allocator.free(owned_path);
    entry.* = .{
        .id = try app_session_mod.app_runtime.entry_ids.next(),
        .path = owned_path,
        .kind = m.kind,
        .mode = m.mode,
    };
    const term = try web_ops.createWebTerm(self, panelKindForEntryKind(m.kind));
    // 이 시점 term.file_entry는 null이라 destroyTerm이 entry를 건드리지 않는다 — 위 errdefer가 소유를 지킨다.
    errdefer self.destroyTerm(term);
    term.file_entry = entry;
    entry.surface_id = term.surfaceId();
    return term;
}

/// 복원 surface 하나로 panel을 만든다. `createPane`을 부르지 않고 Term 생성을 `createRestoredTerm`에 위임한 뒤
/// 빈 Pane에 담는 이유: placeholder 분기를 pane/term 두 진입점에 복사하지 않기 위해서다(`createPane`은 내부에서
/// `createTerm`을 직접 부른다). 조립 순서·errdefer는 `createPane`과 동형이다.
pub fn createPaneFromSurface(self: *AppSession, sm: maru.session.workspace.Surface) !*Pane {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);
    pane.* = .{};
    errdefer pane.terms.deinit(self.allocator);
    const term = try createRestoredTerm(self, sm);
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    pane.active_term = 0;
    // 첫 Term(=이 surface)의 사용자 rename 복원. 실패 시 위 errdefer들이 역순으로 정리한다.
    term.surface.custom_name = try self.dupeCustomName(sm.custom_name);
    return pane;
}

/// 주어진 탭(tab)에서 비어 있는 pane을 떼고(detachPaneFromTab, 형제로 collapse) 해제한다. split에서만(형제가
/// 있을 때) 일어나므로 단일 pane이면 무동작. pane.terms는 비어 있어 destroyPane이 리스트·Pane만 해제한다.
/// 활성/배경 탭 모두에 쓴다(detach + destroy의 단일 출처 — 분리·합치기는 detach만 쓰고 pane을 보존한다).
pub fn collapsePaneIn(self: *AppSession, tab: *Tab, pane: *Pane) void {
    if (!detachPaneFromTab(self, tab, pane)) return;
    destroyPane(self, pane);
}

/// 링크 조회 전용 셀 변환 — `paneTargetAt`이 준 (surface, 본문 rect)에서 좌표가 **실제 셀 위**일 때만 CellHit.
/// 탭 바·divider 밴드·주소창 밴드·grid 뒤 여백은 null이다. `pxToCellIn`(clamp)을 쓰면 그런 chrome 클릭이 첫 행
/// 셀로 접혀, 수식키+클릭이 탭 전환을 삼키고 엉뚱한 링크를 여는 오인이 생긴다(hover는 chrome 분기에서 먼저
/// 밑줄을 지우므로 "밑줄 없는 곳이 열리는" 비대칭까지 됐다). 클릭과 hover가 같이 쓴다.
pub fn paneCellAtExact(self: *const AppSession, surface: *const maru.session.Surface, rect: maru.session.SplitRect, x_px: f64, y_px: f64) ?layout_math.CellHit {
    return layout_math.pxToCellExact(self.cell_width_px, self.cell_height_px, surface.core.size.cols, surface.core.size.rows, rect, x_px, y_px);
}

/// 키보드 pane 이동 — 활성 panel에서 direction 방향의 인접 panel로 포커스를 옮긴다(있으면). split이 없거나
/// 그 방향에 panel이 없으면 무동작(best-effort: leaf rect 레이아웃 OOM도 그냥 이동 안 함). 활성 탭 leaf
/// rect를 펴 paneInDirection으로 대상을 고른 뒤 focusPaneBySurface로 옮긴다.
pub fn focusPaneInDirection(self: *AppSession, dir: FocusDirection) void {
    if (!activeTabHasSplit(self)) return;
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    if (Model.paneInDirection(leaf_rects.items, activePane(self), dir)) |pane| {
        _ = focusPaneByPtr(self, pane);
    }
}

/// drag 중이면 preview 순서, 아니면 model 순서. **paint와 hit-test가 함께 이것을 읽는다**(§4.4) — 갈리면
/// 보이는 자리와 놓이는 자리가 달라진다.
pub fn paneTermOrder(self: *AppSession, pane: *Pane) []const *Term {
    if (tab_ops.tabDragTransaction(self, pane) == null) return pane.terms.items;
    if (self.tab_drag_order.items.len != pane.terms.items.len) return pane.terms.items;
    return self.tab_drag_order.items;
}

/// 활성 워크스페이스의 split(pane)을 delta(+1=다음, -1=이전)만큼 wrap-around로 옮긴다(⌘]/⌘[). pane이
/// 1개(분할 없음)면 무동작. focusPane이 active_pane·대표 surface·active rect를 갱신한다(focusTermRelative와 동형).
pub fn focusPaneRelative(self: *AppSession, delta: i64) void {
    const tab = tab_ops.activeTab(self);
    const n = tab.panes.items.len;
    if (n <= 1) return;
    const cur: i64 = @intCast(tab.active_pane);
    const next = @mod(cur + delta, @as(i64, @intCast(n)));
    focusPane(self, @intCast(next));
}

/// split 노드가 해제되기 직전(removeLeaf 반환 → destroy 사이) 부른다 — divider_drag가 **바로 이 split**을
/// 가리키면 표적 null한다(다른 split이면 유지 → 무관한 reap-collapse가 진행 중 divider 드래그를 안 끊는다).
/// removeLeaf가 freed split을 surface하게 바뀌어 가능해진 표적 무효화(예전 보수적 blanket-null 대체).
pub fn invalidateForFreedSplit(self: *AppSession, split: *PaneTree.Split) void {
    if (self.divider_capture_split) |captured| {
        if (captured == split) endDividerCapture(self);
    }
}

/// CIM4b E2E용 탭 바 관측치. 좌표는 렌더·hit-test와 **같은 출처**(`paneBar`+`barMetrics`)에서 뽑는다 —
/// fixture가 자기 산수로 겨냥하면 제품이 잡는 지점과 갈릴 수 있다.
pub fn fillTabDragSmokeProbe(self: *AppSession, probe: *DividerSmokeProbe) void {
    probe.tab_drag_active = self.pointerGestureIs(.terminal_tab);
    const pane = activePane(self);
    const count = pane.terms.items.len;
    if (count == 0 or self.cell_width_px == 0) return;
    probe.tab_count = std.math.lossyCast(u32, count);
    probe.tab_model_first_id = pane.terms.items[0].surface.id;
    probe.tab_visible_first_id = paneTermOrder(self, pane)[0].surface.id;

    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        if (lr.leaf != pane) continue;
        const pb = paneBar(self, lr.rect, pane) orelse return;
        const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return;
        probe.tab_bar_present = true;
        probe.tab_first_x_px = @intCast(pb.tabs.x + self.cell_width_px); // 세그먼트 안쪽(✕ zone 회피)
        probe.tab_slot_w_px = m.tab_w * self.cell_width_px;
        probe.tab_bar_y_px = @intCast(pb.full.y + 1);
        return;
    }
}

/// chrome `divider.view`가 낸 Rule op(선)을 렌더러 부분 사각형 NativeMetalCell로 lower한다 — 세로선(from.x==to.x)은
/// 경계 x에 셀 1개씩(reserved=30) 행마다, 가로선(from.y==to.y)은 경계 y에 bounds 폭 한 칸(reserved=31). **셀 origin을
/// 경계(seam) 자체에 두고**, 렌더러(reserved 30/31)가 config 두께(divider_thickness_px)를 그 seam에 **중앙 정렬**하고
/// 셀 크기로 clamp한다 — 옛 −1/+1−ch offset은 ~2px 고정 가정이라 두꺼운 값이 한쪽으로 쏠렸다(code-review). 색은
/// `dividerColor()`(tui 토큰 .divider=sidebar_active). divider는 overlay가 아니라 pane chrome 셀이라 이 얇은-선 lowering을 platform이 갖는다.
pub fn lowerDividerRules(self: *AppSession, ops: []const chrome.draw.Op, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
    const color = dividerColor(self);
    for (ops) |op| switch (op) {
        .rule => |r| {
            if (r.from.x == r.to.x) { // 세로선: 경계 x(seam)에 셀 origin, y0..y1 행마다 (렌더러가 seam 중앙정렬)
                const x: u32 = @intCast(@max(r.from.x, 0));
                const y0: u32 = @intCast(@max(@min(r.from.y, r.to.y), 0));
                const y1: u32 = @intCast(@max(@max(r.from.y, r.to.y), 0));
                appendVerticalLine(self, out, x, y0, y1, 30, color); // reserved 30=divider 세로선(seam 중앙정렬 config 두께, 커서 15%와 분리)
            } else { // 가로선(from.y == to.y): 경계 y(seam)에 셀 origin, bounds 폭 한 칸 (렌더러가 seam 중앙정렬)
                const oy: u32 = @intCast(@max(r.from.y, 0));
                const x0: u32 = @intCast(@max(@min(r.from.x, r.to.x), 0));
                const x1: u32 = @intCast(@max(@max(r.from.x, r.to.x), 0));
                appendHorizontalLine(self, out, x0, oy, x1 - x0, 31, color); // reserved 31=divider 가로선(seam 중앙정렬 config 두께)
            }
        },
        else => {},
    };
}

pub fn paneBar(self: *const AppSession, rect: maru.session.SplitRect, pane: *Pane) ?PaneBar {
    const full = paneBarRect(self, rect) orelse return null;
    const cw = self.cell_width_px;
    if (cw == 0) return null;
    const bar_cols = full.w / cw;
    // grip 핸들은 항상 예약하되, 탭 영역 최소(min_tab_cols)가 안 남는 좁은 바면 생략(0). 라벨 폭은 grip을 뺀
    // 나머지(avail) 기준으로 잡아 grip+라벨+탭이 모두 들어가게 한다.
    const grip = if (bar_cols > pane_grip_cols + pane_min_tab_cols) pane_grip_cols else 0;
    const avail = bar_cols - grip;
    // rename 편집 중인 pane이면 custom_name이 비어도 편집 텍스트 폭으로 세그먼트를 띄운다(caret이 보이게).
    const label_cols = if (renamingPane(self, pane))
        paneLabelColsForWidth(renameDisplayWidth(self), avail)
    else
        paneLabelCols(pane, avail);
    return .{ .full = full, .tabs = paneTabBarRect(full, grip + label_cols, cw), .label_cols = label_cols, .grip_cols = grip };
}

/// 스크린 점(backing px) 아래 panel의 활성 Term surface + 그 터미널 본문 rect(탭 바 제외 = 셀 origin).
/// **'포인터 아래 pane이 소유' 라우팅의 단일 출처**로, 두 소비처가 공유한다.
///  - 휠: '커서 아래' surface가 스크롤백/mouse reporting을 처리하고 리포트 좌표도 그 rect 기준이라 정합한다.
///  - 링크(URL·파일 경로) 클릭/hover: 클릭한 pane의 화면에서 링크를 찾는다. 활성 pane 고정으로 두면 **활성이
///    아닌 pane의 링크가 영영 안 열린다** — `pxToCell`은 좌표를 grid 안으로 **clamp**하므로 다른 pane을 눌러도
///    null이 아니라 활성 pane의 엉뚱한 셀이 나오고, 활성이 web Term(빈 sentinel core)이면 항상 (0,0) 빈 셀만
///    보게 된다(브라우저 패널을 띄운 뒤 터미널 링크가 먹통이던 사용자 제보의 루트커즈).
///
/// 활성 탭 leaf rect를 펴 점을 담는 leaf를 찾는다(없으면 — 사이드바/밖 — null). 단일 panel이면 그 panel(=활성)을 돌려준다.
/// hit-test는 **pane 전체 rect**(탭 바 포함)로 한다 — 휠은 탭 바 위에서도 그 pane이 소유해야 자연스럽다. 반환
/// `rect`는 본문(탭 바 제외)이므로, "여기에 링크가 있나"를 묻는 소비처는 `pxToCellIn`(clamp)이 아니라
/// `paneCellAtExact`를 써서 탭 바·여백 좌표가 첫 행 셀로 접히지 않게 해야 한다(리뷰 지적 — chrome 클릭이 링크로 오인).
pub fn paneTargetAt(self: *AppSession, x_px: f64, y_px: f64) ?struct { surface: *maru.session.Surface, rect: maru.session.SplitRect } {
    if (!self.surface_initialized) return null;
    // 입력 hot path라 영속 scratch를 재사용한다(매 mouse-move 할당 회피 — web/dock scratch와 같은 패턴).
    self.pane_target_rects_scratch.clearRetainingCapacity();
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &self.pane_target_rects_scratch) catch return null;
    for (self.pane_target_rects_scratch.items) |lr| {
        if (!layout_math.pointInRect(x_px, y_px, lr.rect)) continue; // paneAtPoint와 같은 반열린 hit-test
        return .{ .surface = lr.leaf.activeTerm().surface, .rect = paneTermRect(self, lr.rect) };
    }
    return null;
}

/// DrawList 셀 중 running 플래그 ●를 종류 브랜드색으로 칠한다 — 탭바 pane 라벨·Term 탭의 flagPrefixedLabel prefix용
/// (그 draw list 단위로). none이면 무동작. ●가 라벨 텍스트에 섞일 여지는 드물고, 있어도 색만 바뀌는 사소한 오탐이라
/// per-tab 셀 범위 게이트까진 불필요(혼재 kind는 pane 대표색으로 통일 — 드문 트레이드오프, code-review max #4·#5).
/// 이번 프레임의 **모든 pane** 탭 제목을 모아 두는 누적 버퍼(이관 3단계 — docs/file-explorer.md §3.5).
///
/// pane마다 따로 셰이핑해 발행하지 **않는** 이유는 성능이 아니라 **수명**이다. `MeasuredTextCache`는
/// 슬롯이 하나뿐이고 `store`가 새 아티팩트를 넣기 전에 옛 것을 해제하는데, 소비처는 아티팩트를 복사하지
/// 않고 슬라이스 참조만 `collected`에 실어 두었다가 **프레임 말미**에 읽는다(`system_text.appendGpuGlyphs`가
/// `placements[i]`로 좌표·색을 정한다). 그래서 pane 루프 안에서 pane마다 store하면 **뒤 pane의 store가
/// 앞 pane이 이미 넘긴 placements를 해제**해, 앞 pane의 제목이 조용히 사라지거나 엉뚱한 좌표로 날아간다.
/// 해제된 버퍼가 다음 셰이핑에 재사용되는지에 따라 갈리므로 split을 옮기기만 해도 증상이 오락가락한다.
///
/// op의 origin이 창 절대 좌표라 아티팩트 하나가 모든 pane의 제목을 담을 수 있다. 그래서 pane 루프는
/// 여기에 쌓기만 하고, 루프가 끝난 뒤 `flushPaneTabTitles`가 **프레임당 한 번** 셰이핑·발행한다. 그러면
/// 프레임 안에서 store가 한 번만 일어나므로 이 경로에서 소유권이 갈릴 여지가 구조적으로 없어지고,
/// 덤으로 split이 여럿이어도 캐시가 정상적으로 hit한다(예전에는 pane마다 갈려 매번 재셰이핑했다).
pub const TabTitleBatch = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        /// 제목 본문의 **소유 복사본**. pane 루프의 `titles`는 그 반복이 끝나면 해제되는데, op의 run은
        /// 이 바이트를 슬라이스로 가리킨 채 flush까지 살아 있어야 한다.
        text: []u8,
        origin: chrome.draw.Px,
        max_width_px: u32,
        /// 그 pane의 활성 탭인가(색 역할 선택). role 값을 여기 담지 않는 것은 색 결정을 flush 한 곳에
        /// 모아 두기 위해서다 — 이 구조체는 기하와 상태만 나른다.
        active: bool,
        /// rename 편집 중인 탭인가(넘칠 때 앞을 자르는 tail 앵커 선택).
        editing: bool,
    };

    pub fn deinit(self: *TabTitleBatch, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.text);
        self.entries.deinit(allocator);
    }
};

/// 한 pane의 탭 제목을 batch에 쌓는다(발행은 `flushPaneTabTitles`가 프레임당 한 번).
///
/// 세그먼트 기하는 `tabbar.Metrics.segOf` **그대로**다. 탭 폭·✕ 자리·가로 스크롤은 셀 칸에서 나오고
/// hit-test가 같은 값을 보므로, 제목만 픽셀로 그려도 "보이는 탭 == 클릭되는 탭"이 유지된다. 제목 영역은
/// 셀 경로가 쓰던 규칙과 같다: 좌패딩 1칸, ✕가 있으면 우측 3칸을 비운다(`title_end = seg_end - 3`).
///
/// 마커(`●`)는 셀에 남으므로 마커가 있는 탭은 제목이 그만큼(2칸) 오른쪽에서 시작한다.
pub fn appendPaneTabTitles(
    self: *AppSession,
    batch: *TabTitleBatch,
    leaf: *Pane,
    pb: PaneBar,
    titles: []const []const u8,
    editing_tab: ?usize,
    bar_rect: maru.session.SplitRect,
) void {
    const cw = self.cell_width_px;
    if (cw == 0 or titles.len == 0) return;
    // hit-test(`paneTabIndexAt` 등)와 **같은 메트릭**을 쓴다 — 보이는 탭과 클릭되는 탭이 갈리면 안 된다.
    const m = barMetrics(pb.tabs, cw, paneTermOrder(self, leaf).len, self.buildChromeTokens().space.tab_width_cols, leaf.tab_scroll_cols) orelse return;
    const active = paneActiveTermIndex(self, leaf);

    // 세로 위치는 **role line box** 기준 바 중앙이다. 셀 텍스트가 쓰는 `chromeBarTextOffsetY`는
    // `(bar_h - cell_height) / 2`라 폰트가 커지면 제목이 위로 밀린다 — measured 제목의 높이는 셀이 아니라
    // role 토큰(pt)에서 나오므로 같은 식을 쓰면 어긋난다(24pt 캡처가 실제로 그 어긋남을 보여줬다).
    // 사이드바 검색 줄이 상단 바 밴드에서 쓰는 것과 **같은 공식**이다.
    const title_line_h = chrome.ui.typography.lineHeightPx(.control, self.scale_milli);
    const title_y = bar_rect.y +| (if (bar_rect.h > title_line_h) (bar_rect.h - title_line_h) / 2 else 0);

    for (titles, 0..) |title, i| {
        const body = tabTitleBody(title);
        if (body.len == 0) continue;
        const seg = m.segOf(i);
        if (seg.end_px <= seg.start_px) continue; // 우단에서 잘려 안 보이는 탭
        const lead_cols: u32 = if (tabTitleRunningMarker(title)) 3 else 1; // 좌패딩 1 + 마커(2칸)
        const trail_cols: u32 = if (seg.has_close) 3 else 1; // ✕ 좌여백·✕·우여백
        // `segOf`의 px는 `colPx`가 `bar_x`를 이미 더한 **절대 좌표**다 — 여기에 `pb.tabs.x`를 또 더하면
        // 제목이 탭 밖 오른쪽으로 밀린다(실제 캡처로 잡힌 회귀). 절대 좌표라 여러 pane의 op을 한 아티팩트에
        // 섞어도 각자 제자리에 놓인다 — 이 batch가 성립하는 근거다.
        const start_px = @as(u32, @intFromFloat(@max(seg.start_px, 0))) + lead_cols * cw;
        const end_px = @as(u32, @intFromFloat(@max(seg.end_px, 0)));
        if (end_px <= start_px + trail_cols * cw) continue; // 제목이 들어갈 자리가 없다
        const owned = self.allocator.dupe(u8, body) catch return;
        batch.entries.append(self.allocator, .{
            .text = owned,
            .origin = .{ .x = @intCast(start_px), .y = @intCast(title_y) },
            .max_width_px = end_px - start_px - trail_cols * cw,
            .active = active == i,
            .editing = editing_tab != null and editing_tab.? == i,
        }) catch {
            self.allocator.free(owned);
            return;
        };
    }
}

/// batch에 쌓인 모든 pane의 탭 제목을 **한 번에** 셰이핑해 발행한다. pane 루프가 끝난 직후에 부른다 —
/// 그 자리가 예전에 pane마다 발행하던 순서(탭 제목 → floating/sticky 오버레이)를 그대로 보존한다.
pub fn flushPaneTabTitles(
    self: *AppSession,
    batch: *TabTitleBatch,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
) void {
    const entries = batch.entries.items;
    if (entries.len == 0) return;
    const tokens = self.buildChromeTokens();

    // run 배열을 **길이가 확정된 상태로 한 번에** 잡는다. ArrayList로 키우면 realloc이 앞서 만든 op의
    // run 슬라이스를 죽이므로, run을 전부 확정한 뒤에야 op이 그것을 가리킬 수 있다.
    const runs = self.allocator.alloc(chrome.draw.Run, entries.len) catch return;
    defer self.allocator.free(runs);
    const ops = self.allocator.alloc(chrome.draw.Op, entries.len) catch return;
    defer self.allocator.free(ops);
    for (entries, runs) |e, *run| run.* = .{ .text = e.text };
    for (entries, ops, 0..) |e, *op, i| op.* = .{
        .text = .{
            .origin = e.origin,
            .runs = runs[i .. i + 1],
            // 활성 탭만 또렷하게. 셀 경로의 `active_tab_fg`/`tab_fg`에 대응하는 chrome role이다 —
            // measured는 op당 role 하나라 색을 토큰에서 받는다(비활성 색이 미세하게 달라진다).
            .role = if (e.active) .surface_fg else .muted_fg,
            .text_role = .control,
            .max_width_px = e.max_width_px,
            // rename 중인 탭만 tail 앵커 — 긴 이름을 칠 때 caret(문자열 끝)이 세그먼트 안에 남는다.
            .anchor = if (e.editing) .tail else .head,
        },
    };

    // 그리드 크기(cols·rows)는 이 소비처의 키에 싣지 않는다. 제목 op은 창 절대 좌표와 픽셀 폭을 이미
    // 담고 있어 pane이 리사이즈되면 origin·max_width가 먼저 달라지고, 폰트가 바뀌면 셀 크기 인자가 잡는다.
    // 창 전체 cols를 넣으면 이 batch에 속하지 않은 pane의 폭 변화까지 키를 흔들어 재셰이핑만 늘어난다.
    const fingerprint = chrome_draw_lowering.richTextFingerprint(ops, &tokens, self.cell_width_px, self.cell_height_px, 0, 0, 0);
    if (!MeasuredTextCache.hit(self.pane_tab_title_text_cache, fingerprint)) {
        var request = chrome_system_text.prepareRequest(self.allocator, fingerprint, ops, &tokens, self.cell_width_px, .{
            .family = self.appearance.font.family,
            .fallback = self.appearance.font.fallback,
        }) catch return;
        defer request.deinit(self.allocator);
        var unresolved = chrome_system_text.shapeRequest(self.allocator, &request, self.scale_milli) catch return;
        defer unresolved.deinit(self.allocator);
        const artifact = chrome_system_text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
        MeasuredTextCache.store(&self.pane_tab_title_text_cache, self.allocator, fingerprint, artifact, 0);
    }
    if (self.pane_tab_title_text_cache) |*cache| {
        const dl = chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return;
        // dest가 `.sidebar_search`인 것은 이름과 달리 "origin 0,0 · clip 없음"이라는 배치 규약을 고른 것이다
        // (op origin이 이미 창 절대 좌표라 여기서 더 옮길 것이 없다). 이름은 measured dest를 정리할 때 함께 손본다.
        self.collectMeasuredTextFromCache(collected, dl, cache, builder, .{ .sidebar_search = .{
            .origin_x = 0,
            .origin_y = 0,
            .colors = .{ .default_fg = self.appearance.theme.foreground },
        } });
    }
}

/// 이 pane(leaf)에 web Term이 하나라도 있는가(anyLeaf pred — pointer-identity leaf를 여기서 해석). alloc-free.
pub fn paneHasWebTerm(pane: *Pane) bool {
    for (pane.terms.items) |term| if (term.kind == .web) return true;
    return false;
}

pub fn createTermFromSurface(self: *AppSession, sm: maru.session.workspace.Surface) !*Term {
    const term = try createRestoredTerm(self, sm);
    errdefer self.destroyTerm(term);
    term.surface.custom_name = try self.dupeCustomName(sm.custom_name);
    return term;
}

/// 터미널 surface가 하나도 없는 pane(파일 Term만)의 pane 생성 seed.
pub fn createPaneFromFileTerm(self: *AppSession, m: maru.session.workspace.FileTerm) !*Pane {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);
    pane.* = .{};
    const term = try createFileTermFromModel(self, m);
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    return pane;
}

pub fn paneHasWebBrowser(pane: *Pane) bool {
    for (pane.terms.items) |t| if (termIsWebBrowser(t)) return true;
    return false;
}

/// 터미널 영역 기하가 **아직 없는가**(창 크기 미확정 — 복원 직후·첫 AppKit resize 전).
///
/// 0인 rect를 그대로 레이아웃에 넣으면 `gridFromRectPx`가 0을 내고 `clampGridSize` 하한에 걸려 **2×1**이 된다.
/// 그 값은 "이 pane은 2칸짜리 터미널"이 아니라 **"아직 모른다"**인데, 하한을 거치면서 정상 크기와 구별할 수
/// 없는 숫자가 되어 세 곳을 연쇄로 오염시킨다: ① host runtime의 진짜 크기(135×74)를 덮어쓰고 ②
/// `resizeTermCoreToLayout`이 `observation.size`에 심고 ③ `captureWorkspaceTab`이 그걸 workspace에 저장해
/// **재시작을 넘어 영구화**한다 — 다음 복원이 2×1로 재접속해 스스로를 재생산한다(실측: workspace.v1에
/// `cols=2 rows=1` 기록됨). 기하를 모를 때는 아무에게도 알리지 않는 것이 유일하게 옳다. 실제 기하가 오면
/// `resize()`가 이 패스를 다시 돌린다.
pub fn layoutGeometryUnknown(self: *const AppSession) bool {
    const r = self.termRect();
    return r.w == 0 or r.h == 0;
}

/// 탭 영역 sub-rect — 전체 바에서 좌측 라벨(label_cols)을 뗀 나머지. 탭 hit-test(barMetrics)·탭 제목 렌더가
/// 이 sub-rect를 공유해 라벨만큼 우측으로 밀린다(label_cols=0이면 전체 바 == 기존 동작).
pub fn paneTabBarRect(bar: maru.session.SplitRect, label_cols: u32, cw: u32) maru.session.SplitRect {
    const off = label_cols * cw;
    return .{ .x = bar.x + off, .y = bar.y, .w = bar.w -| off, .h = bar.h };
}

/// 활성 탭의 divider 선들을 overlay 셀로 out에 append한다(렌더). chrome `divider.view`가 seg→Rule op(선)을 내고,
/// `lowerDividerRules`가 그 Rule을 렌더러 **부분 사각형**(reserved=3 bar=좌측 ~2px / 2 underline=하단 ~2px, 커서
/// 모양과 같은 경로)으로 lower해 **얇은 선**으로 seam에 얹는다. divider 선/hit-test 수학은 chrome 컴포넌트가 단일
/// 출처(C2). 단일 panel이면 빈 채. 셀 0이면 무동작. layout과 같은 좌표계(termRect)라 경계에 정확히 얹힌다.
pub fn appendActiveTabDividers(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (dividerThicknessPx(self) == 0) return; // split.divider-thickness=0(숨김)이면 0-area 셀을 아예 안 낸다(낭비 방지)
    var app_segs: std.ArrayList(PaneTree.DividerSeg) = .empty;
    defer app_segs.deinit(self.allocator);
    layoutActiveTabDividers(self, &app_segs) catch return;
    if (app_segs.items.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var neutral: std.ArrayList(chrome.components.divider.Seg) = .empty;
    for (app_segs.items) |seg| neutral.append(arena, appSegToDivider(seg)) catch return;
    var ops: std.ArrayList(chrome.draw.Op) = .empty;
    chrome.components.divider.view(neutral.items, arena, &ops) catch return;
    lowerDividerRules(self, ops.items, out);
}

/// 얇은 **가로선**을 overlay 셀로 그린다 — origin_y에 폭(width_px→floor cols, 최소 1)만큼 sentinel 셀 1개,
/// reserved=31로 seam 중앙의 configured divider strip을 칠한다.
pub fn appendHorizontalLine(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell), origin_x: u32, origin_y: u32, width_px: u32, reserved: u16, color: u32) void {
    const cw = self.cell_width_px;
    if (cw == 0) return;
    const cols = @min(@max(width_px / cw, 1), @as(u32, std.math.maxInt(u16)));
    var c = sentinelBgCell(0, @intCast(cols), color, origin_x, origin_y);
    c.reserved = reserved;
    out.append(self.allocator, c) catch return;
}

/// 활성 탭의 모든 pane 우측에 스크롤바를 그린다 — **각 pane이 자기 idle_ticks로 독립 fade**(per-pane), 활성
/// pane만 추가로 hover/드래그 강조(세션 상태). 각 pane은 자기 core의 view_offset/scrollback을 반영. leaf rect는
/// 재사용 scratch로 계산(per-frame 할당 churn 없음), 실패(OOM)면 활성 pane만(폴백). per-frame(layer3)에서 부른다.
pub fn appendPaneScrollbars(self: *AppSession) void {
    if (!self.surface_initialized) return;
    self.scrollbar_leaf_scratch.clearRetainingCapacity();
    if (tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &self.scrollbar_leaf_scratch)) |_| {
        const active_pane = activePane(self);
        for (self.scrollbar_leaf_scratch.items) |lr| {
            const trect = paneTermRect(self, lr.rect); // 상단 탭 바를 뺀 터미널 영역(active_pane_rect와 같은 식)
            appendScrollbar(self, trect, lr.leaf, lr.leaf == active_pane);
        }
    } else |_| {
        appendScrollbar(self, self.active_pane_rect, activePane(self), true);
    }
}

/// 드래그한 Term을 src pane의 src_idx에서 빼 dst pane의 dst_idx에 넣는다(cross-pane 이동). dst를 활성 pane으로,
/// 옮긴 Term을 dst의 활성 탭으로 만들고, src가 비면 collapse한다. 그 뒤 모든 panel을 새 leaf rect grid로
/// resize + 좌표 재계산. insert 실패는 src로 원복한다. src==dst거나 인덱스 밖이면 무동작. Term은 heap-pin
/// (`*Term`)이라 pane 사이를 포인터로 옮겨도 surface/reader 주소가 안 움직인다(runtime link도 그대로).
pub fn moveTermToPane(self: *AppSession, src: *Pane, src_idx: usize, dst: *Pane, dst_idx: usize) void {
    if (src == dst or src_idx >= src.terms.items.len) return;
    const term = src.terms.orderedRemove(src_idx);
    const idx = @min(dst_idx, dst.terms.items.len);
    dst.terms.insert(self.allocator, idx, term) catch {
        src.terms.insert(self.allocator, @min(src_idx, src.terms.items.len), term) catch {}; // 원복
        return;
    };
    // insert 성공 뒤부터 구조 전이는 infallible다. dst로 input owner를 옮기기 전에 현재 조합을
    // pin된 원 surface로 확정한다(드래그 중 활성 pane이 바뀌어도 새 Term으로 새지 않게).
    self.commitComposition();
    // src에서 임의 위치(src_idx)를 뺐으니 활성 인덱스를 시프트 보정한다(단일 출처) — 비면(아래 collapse) 0 무의미.
    src.active_term = if (src.terms.items.len == 0) 0 else activeIndexAfterRemoval(src.active_term, src_idx, src.terms.items.len);
    dst.active_term = idx; // 옮긴 Term을 dst의 활성으로

    self.hovered_tab = null; // 트리/탭이 바뀌니 stale 호버 비움
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버도 함께 정리
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    if (src.terms.items.len == 0) collapsePane(self, src); // 마지막 Term이 나갔으면 src collapse(형제로)

    // dst를 활성 pane으로(collapse로 인덱스가 밀렸을 수 있어 다시 찾는다) + 대표 surface 재바인딩.
    const tab = tab_ops.activeTab(self);
    for (tab.panes.items, 0..) |p, i| {
        if (p == dst) {
            tab.active_pane = i;
            break;
        }
    }
    self.surface_ptrs.items[self.app_window.active_tab] = dst.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    resizeActiveTabPanes(self) catch {}; // 옮긴 Term을 dst term rect grid로(+ src 형제가 빈자리 확장)
    recomputeActivePaneRect(self);
    self.metal_dirty = true;
}

/// 활성 pane에 새 Term(터미널 탭)을 띄우고 그 탭으로 포커스한다(⌘T). 활성 pane의 현재 rect grid
/// 크기로 새 셸을 spawn해 pane.terms에 더한다. spawn/alloc 실패는 errdefer로 원복하고 무시(pane 불변).
pub fn newTermInActivePane(self: *AppSession) !void {
    const pane = activePane(self);
    const size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, self.active_pane_rect.w, self.active_pane_rect.h);
    var cfg = self.new_tab_config;
    cfg.size = size;
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.shellIntegrationZdotdir(), self.new_tab_ssh_bin);
    // 서페이스(새 Term)는 Term 탭이라 tab-inherit-cwd 토글을 따른다(켜지면 포커스 cwd 상속, 아니면 root).
    // append 전에 읽어야 focusedTermCwd의 activeTerm이 아직 현재(=직전 포커스) Term을 가리킨다.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    self.applySpawnCwd(&req, &root_buf, self.loaded_config.config.workspace.tab_inherit_cwd);
    const term = try self.createTerm(
        req,
        size,
        cfg.queue_capacity,
        "Maru",
        commandName(cfg.command_kind),
    );
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    self.focusTerm(pane.terms.items.len - 1); // 새 Term으로 포커스(surface 재바인딩·rect·dirty)
}

/// 활성 panel을 direction으로 둘로 나눈다(사실상 표준 멀티플렉서 split 동작 참고 — 코드 미참고). 활성 panel의
/// 현재 leaf rect를 splitRect로 a(기존)·b(새)로 나눠, b 크기로 새 셸 panel을 spawn하고, 트리에서 활성
/// leaf를 split{a: 기존 leaf, b: 새 leaf}로 교체하고, 기존 panel을 a 크기로 줄인 뒤 새 panel로 포커스를
/// 옮긴다. 단일 panel 탭이면 첫 분할(2개), 이미 split이면 활성 panel이 다시 나뉜다(중첩). spawn/alloc
/// 실패는 errdefer로 트리/탭을 원복한다(부분 상태를 남기지 않는다).
pub fn splitActivePane(self: *AppSession, direction: maru.session.SplitDirection) !void {
    const tab = tab_ops.activeTab(self);
    const active = tab.activePane();

    // 1) 활성 panel의 현재 rect를 레이아웃에서 찾는다(없으면 — 있어선 안 되지만 — 분할 안 함).
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    try tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects);
    var active_rect: ?maru.session.SplitRect = null;
    for (leaf_rects.items) |lr| {
        if (lr.leaf == active) {
            active_rect = lr.rect;
            break;
        }
    }
    const arect = active_rect orelse return error.ActivePaneNotInTree;

    // 2) active rect를 direction·0.5로 a(기존)·b(새)로 나눈 grid.
    // 두 자식 panel 각자 상단 탭 바를 예약하므로, Term grid는 leaf rect가 아니라 paneTermRect(바 아래)로 잰다.
    const parts = maru.session.splitRect(arect, direction, 0.5);
    const a_term = paneTermRect(self, parts.a);
    const b_term = paneTermRect(self, parts.b);
    const a_size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, a_term.w, a_term.h);
    const b_size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, b_term.w, b_term.h);

    // 3) 새 panel을 b 크기로 spawn(새 셸). 실패하면 트리/탭은 그대로다.
    var cfg = self.new_tab_config;
    cfg.size = b_size;
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.shellIntegrationZdotdir(), self.new_tab_ssh_bin);
    // 팬(분할)은 split-inherit-cwd면 분할되는(활성) pane의 활성 Term cwd 상속, 아니면 root. 아래 트리 변형
    // 전에 읽어 focusedTermCwd의 active가 아직 포커스 Term을 가리킨다.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    self.applySpawnCwd(&req, &root_buf, self.loaded_config.config.workspace.split_inherit_cwd);
    const new_pane = try createPane(
        self,
        req,
        b_size,
        cfg.queue_capacity,
        "Maru",
        commandName(cfg.command_kind),
    );
    errdefer destroyPane(self, new_pane);
    try tab.panes.append(self.allocator, new_pane);
    errdefer _ = tab.panes.pop();

    // 4) split 노드를 heap에 만들고 트리에서 활성 leaf를 split{a: 기존, b: 새}로 교체.
    const split = try self.allocator.create(PaneTree.Split);
    errdefer self.allocator.destroy(split);
    split.* = .{
        .direction = direction,
        .ratio = 0.5,
        .a = .{ .leaf = active },
        .b = .{ .leaf = new_pane },
    };
    if (!PaneTree.replaceLeaf(&tab.tree, active, .{ .split = split })) {
        return error.ActivePaneNotInTree; // errdefer가 split·pane을 원복(트리는 변형 전이라 무변)
    }

    // 5) 기존 panel의 모든 Term을 a 크기로 줄인다(PTY winsize 포함). 죽은 PTY라 winsize를 못 보내도 **표시
    //    grid는 반드시 줄어든다**(resizeTermForLayout 계약) — 안 그러면 그 Term이 divider를 넘어 새 panel 위에
    //    글자를 그린다. 전달 실패는 split을 막지 않고 관측 지점에만 남긴다.
    for (active.terms.items) |term| {
        self.resizeTermForLayout(term, a_size) catch |err| self.noteResizeDeliveryFailure(term, err); // 표시 grid는 헬퍼가 보장, 전달 실패만 관측
    }

    // 6) 새 panel로 포커스 이동(멀티플렉서 split 관행). focusPane이 탭 대표 surface(= app_window.active())·
    //    frame_loop pump 재바인딩 + 활성 panel rect 재계산 + metal_dirty를 한 곳에서 한다. 탭 인덱스는
    //    그대로라 사이드바 갱신은 불요.
    focusPane(self, tab.panes.items.len - 1);
}

/// 활성 탭의 divider를 capture가 볼 수 있는 tree로 다시 발행한다 — CIM2.
///
/// 선이 실제로 움직이므로 pointer move마다 재발행하고 세대를 올린다. 그래서 drag 도중 capture를
/// 넘길지는 §5의 carry verdict가 판정하며, 그것 없이는 첫 move에 죽는다. 발행과 같은 순서로
/// live `*Split`을 담아 두는데, payload를 split으로 되돌리는 역매핑은 host의 몫이기 때문이다.
pub fn publishDividerTree(self: *AppSession) ?chrome.ui.tree.UiRectTree {
    const segs = &self.hover_divider_scratch;
    segs.clearRetainingCapacity();
    layoutActiveTabDividers(self, segs) catch return null;

    self.divider_seg_scratch.clearRetainingCapacity();
    for (segs.items) |seg| self.divider_seg_scratch.append(self.allocator, appSegToDivider(seg)) catch return null;

    self.divider_entry_scratch.resize(self.allocator, self.divider_seg_scratch.items.len) catch return null;
    const published = chrome.components.divider.publish(
        self.divider_seg_scratch.items,
        self.cell_width_px,
        self.cell_height_px,
        self.divider_snapshot_generation +| 1,
        self.divider_entry_scratch.items,
    ) catch return null;
    self.divider_snapshot_generation +|= 1;

    self.divider_split_scratch.clearRetainingCapacity();
    for (segs.items) |seg| self.divider_split_scratch.append(self.allocator, seg.split) catch return null;
    return published;
}

/// 주어진 탭(tab)에서 pane을 트리(removeLeaf, 형제로 collapse)와 panes 리스트에서 떼지만 **해제하지 않고**
/// 보존한다 — pane은 살아남아 호출자가 다른 워크스페이스에 심는다(분리·합치기). 단일 pane 워크스페이스(형제
/// 없음)면 false(호출자가 no-op). 성공 시 떼어낸 split을 destroy하고 active_pane을 범위 clamp한다. pane이
/// 살아 있으므로 invalidateForFreedPane은 부르지 않는다(포인터가 유효 — destroy 경로인 collapsePaneIn만 부른다).
/// divider_drag가 이 split이면 destroy 전에 표적 null한다(무관 드래그는 보존 — removeLeaf가 freed split을 surface).
pub fn detachPaneFromTab(self: *AppSession, tab: *Tab, pane: *Pane) bool {
    if (tab.panes.items.len <= 1) return false;
    const freed_split = PaneTree.removeLeaf(&tab.tree, pane) orelse return false;
    invalidateForFreedSplit(self, freed_split);
    self.allocator.destroy(freed_split);
    var removed_index: usize = tab.panes.items.len; // 미발견 sentinel(>= 모든 활성 인덱스 → 보정 no-op)
    for (tab.panes.items, 0..) |p, i| {
        if (p == pane) {
            removed_index = i;
            _ = tab.panes.orderedRemove(i);
            break;
        }
    }
    // 임의 위치(removed_index)의 pane을 뺐으니 활성 인덱스를 시프트 보정한다(단일 출처) — 배경 pane collapse(reap
    // 경로 closeTermAt→collapsePaneIn 포함) 시 활성 pane이 엉뚱한 pane으로 튀던 버그. len>1 가드 후라 제거 후 len>=1.
    tab.active_pane = activeIndexAfterRemoval(tab.active_pane, removed_index, tab.panes.items.len);
    return true;
}

/// config split.divider-thickness(논리 pt)를 divider strip의 backing px 두께로 환산한다(× scale_milli/1000 —
/// letter-spacing·window padding과 같은 분수 scale). **0(이하)=숨김, 양수는 최소 1px 보장** — round가 0.5px 미만을
/// 0으로 없애 양수 config인데 divider가 통째 사라지는 걸 막는다(code-review: 1x에서 0.4pt 등). @intFromFloat 음수 UB도
/// 이 게이트가 막는다. metalFrame(렌더 값)·appendActiveTabDividers(0이면 셀 emit 스킵)의 단일 출처. 커서 강조선(15%)과 무관.
pub fn dividerThicknessPx(self: *const AppSession) u32 {
    if (self.scale_milli == 0 or self.appearance.split_divider_thickness <= 0.0) return 0;
    const px_f = self.appearance.split_divider_thickness * @as(f32, @floatFromInt(self.scale_milli)) / 1000.0;
    return @max(@as(u32, 1), @as(u32, @intFromFloat(@round(px_f))));
}

/// 사이드바/탭바/비활성/오버레이/floating 공용 frame builder(cursor_unfocused 없음 — 활성 panel만 cursor 모드를
/// 쓴다). macOS 전용 coretext bridge라 호출은 `if (builtin.os.tag == .macos)` 안에서만 한다(비-macOS는 lazy 미분석).
pub fn paneFrameBuilder(self: *const AppSession) coretext_frame_builder.CoreTextFrameBuilder {
    return .{
        .appearance = self.appearance,
        .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
        .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
        .scale_milli = self.scale_milli,
        .cell_width_px = @intCast(self.cell_width_px),
        .glyph_cell_width_px = @intCast(self.glyph_cell_width_px),
        .cell_height_px = @intCast(self.cell_height_px),
    };
}

/// 한 pane 탭 바의 레이아웃 단일 출처 — `full`(전체 바: 배경·클릭 판정), `grip`(좌측 grip 핸들 폭, 항상 예약:
/// pane 통째 드래그 손잡이), `label_cols`(grip 뒤 custom_name 라벨 폭, 이름 없으면 0), `tabs`(grip+라벨 뗀 탭
/// 영역: barMetrics·탭 제목·활성 밴드). 좌측 세그먼트 = `[full.x, tabs.x)` = grip + 라벨. 모든 hit-test/렌더가 이
/// 한 함수를 거쳐 "보이는 == 클릭되는"을 유지한다. 바가 없거나 cell 미상이면 null. 좁은 바(min_tab 미보장)면 grip 0.
/// pane 탭 바 **바로 아래** 한 줄 — browser 주소창 밴드와 파일 헤더 밴드가 공유하는 rect다.
/// `collectWebSurfaces`의 `inset.top = bar_h + addr_h`와 정확히 abut한다(밴드가 웹뷰를 덮지 않는다).
pub fn paneBandRect(bar: PaneBar) maru.session.SplitRect {
    return .{ .x = bar.full.x, .y = bar.full.y + bar.full.h, .w = bar.full.w, .h = bar.full.h };
}

pub fn paneHasRunningAgent(pane: *Pane) bool {
    for (pane.terms.items) |t| if (t.agent_state == .running) return true;
    return false;
}

/// capture가 살아 있는 동안의 move/up. 소비했으면 true.
pub fn routeDividerCapture(self: *AppSession, kind: i32, x_px: f64, y_px: f64) bool {
    const capture = self.divider_interaction.capture orelse return false;
    const identity = capture.id;
    const previous_key = chrome.ui.interaction.GestureCompatibility{
        .kind = identity,
        .enabled = true,
        .owner_epoch = @intFromPtr(tab_ops.activeTab(self)),
        .domain_identity = if (self.divider_capture_split) |split| @intFromPtr(split) else 0,
    };

    const tree_snapshot = publishDividerTree(self) orelse {
        endDividerCapture(self);
        return true;
    };
    const current_key = dividerCompatibilityKey(self, identity);
    const carried = chrome.ui.interaction.reconcileCarryingCapture(
        &self.divider_interaction,
        tree_snapshot,
        previous_key,
        current_key,
    ) catch {
        endDividerCapture(self);
        return true;
    };
    // carry하지 못하면 `reconcileCarryingCapture`가 capture를 이미 비웠다(그리고 drag를
    // `cancelled`로 닫았다). 그것이 곧 판정이므로 여기서 사유를 다시 묻지 않는다 — split이
    // 사라졌거나 탭이 바뀐 경우가 전부 이 한 검사로 들어온다.
    _ = carried;
    if (self.divider_interaction.capture == null) {
        endDividerCapture(self);
        return true;
    }

    const dispatched = chrome.ui.interaction.dispatch(&self.divider_interaction, tree_snapshot, .{
        .phase = if (kind == 2) .move else .up,
        .x_px = x_px,
        .y_px = y_px,
        .timestamp_ns = 0,
        .button = .left,
        .generation = tree_snapshot.generation,
    }) catch {
        endDividerCapture(self);
        return true;
    };

    if (dispatched.drag) |event| switch (event) {
        // 좌표를 모으기만 한다. 실제 resize는 tick이 최종 하나로 한 번 한다.
        .began, .moved => |update| {
            self.divider_coalescer.absorb(update.x_px, update.y_px);
            self.divider_move_events +|= 1;
        },
        .dropped => |update| {
            self.divider_coalescer.absorb(update.x_px, update.y_px);
            applyPendingDividerResize(self);
            endDividerCapture(self);
        },
        .cancelled => endDividerCapture(self),
    };
    if (kind == 3) endDividerCapture(self);
    return true;
}

/// 발행된 identity가 지금 가리키는 live split. 구조가 바뀌어 그 identity가 사라졌으면 null이다.
pub fn dividerSplitForIdentity(self: *AppSession, identity: u64) ?*PaneTree.Split {
    const index = chrome.components.divider.segIndexOf(identity, self.divider_split_scratch.items.len) orelse return null;
    return self.divider_split_scratch.items[index];
}

/// 활성 탭에서 주어진 panel을 찾아 포커스한다(찾으면 true). 마우스/키보드 hit-test가 고른 `*Pane`으로
/// 포커스를 옮길 때 쓴다(panel→index 매핑).
pub fn focusPaneByPtr(self: *AppSession, pane: *Pane) bool {
    const tab = tab_ops.activeTab(self);
    for (tab.panes.items, 0..) |p, i| {
        if (p == pane) {
            focusPane(self, i);
            return true;
        }
    }
    return false;
}

/// 활성 탭 안에서 포커스를 panel index로 옮긴다(입력/커서/IME/렌더가 따라간다). 활성 panel surface를
/// 탭 대표(`surface_ptrs[active_tab]` = `app_window.active()`)와 `frame_loop.pump`에 재바인딩하고
/// 활성 panel rect를 다시 계산한다. 같은 panel이거나 범위 밖이면 무동작. 탭 자체는 안 바꾼다.
pub fn focusPane(self: *AppSession, pane_index: usize) void {
    const tab = tab_ops.activeTab(self);
    if (pane_index >= tab.panes.items.len or tab.active_pane == pane_index) return;
    self.commitComposition(); // input owner를 바꾸기 전에 원 surface의 marked text를 확정한다.
    self.invalidatePositionalPendingClose(); // 닫기 모달 보류 중 pane 이동 → 보류 무효화(stale 대상 close 방지)
    tab.active_pane = pane_index;
    self.surface_ptrs.items[self.app_window.active_tab] = tab.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    recomputeActivePaneRect(self);
    self.metal_dirty = true;
}

/// new_workspace 드롭 하이라이트 표시 슬롯 — promotePaneToNewWorkspace가 새(비고정) 탭을 **비고정 리전의 첫 group_start
/// 마커 직전**(§12 GP1 `firstGroupStartInRegion(pinned_count, len)` = 그 리전 최상위 구간 끝)에 끼우므로, 하이라이트도
/// **그 마커의 group_header row**를 가리켜 실제 삽입 위치와 정합한다(전역 첫 헤더가 아니다 — 고정 색 그룹이 앞에 있으면
/// 전역 첫 헤더는 고정 리전이라 삽입점과 어긋난다). 거기에 .drop_zone 밴드를 그려 새 카드가 들어설 자리를 미리 보인다
/// (bandFill이 헤더 높이로 그려 카드 높이와는 살짝 다르지만 위치는 정확). 비고정 그룹이 없으면(그룹 전무·전부 고정·검색
/// 으로 헤더 숨김) 카드 목록 아래 행(rows.len)으로 폴백 = 기존 "빈 영역=새 워크스페이스" 동작 보존. 고정 그룹 0개면
/// 비고정 리전 = 전역이라 그 마커의 헤더 = 첫 group_header row → 옛 동작과 byte-identical.
pub fn newWorkspaceHighlightSlot(self: *const AppSession) usize {
    const insert_at = self.firstGroupStartInRegion(tab_ops.countPinnedTabs(self), self.tabs.items.len) orelse return self.sidebar_rows.items.len;
    for (self.sidebar_rows.items, 0..) |row, slot| switch (row) {
        .group_header => |h| if (h.tab == insert_at) return slot,
        .agent_toggle, .agent => {},
        .card => {},
    };
    return self.sidebar_rows.items.len;
}

/// 이미 순회 중인 frame leaf 하나에서 active pane의 기하를 최대 한 번 캡처한다. 이 함수는 layout이나 검색을
/// 시작하지 않으며 할당도 하지 않는다. caller가 가진 기존 chrome 순회에 projection을 융합하므로 focus border를
/// 위해 두 번째 leaf scan을 만들지 않는다. layout이 완주하지 못했으면 partial prefix를 신뢰하지 않고 null을 유지한다.
pub fn captureActivePaneGeometry(
    self: *AppSession,
    layout_complete: bool,
    active_pane: *Pane,
    leaf_rect: PaneTree.LeafRect,
    out: *?PaneGeometry,
) void {
    if (!layout_complete or out.* != null or leaf_rect.leaf != active_pane) return;
    out.* = paneGeometry(self, leaf_rect.rect);
}

/// 그 pane의 활성 Term이 파일이면 헤더 밴드 rect를 준다(아니면 null). 렌더와 hit-test의 단일 출처다.
pub fn fileHeaderBandForPane(self: *AppSession, pane: *Pane, rect: maru.session.SplitRect) ?FileHeaderBand {
    if (pane.terms.items.len == 0) return null;
    const entry = pane.activeTerm().file_entry orelse return null;
    const bar = paneBar(self, rect, pane) orelse return null;
    if (bar.full.h == 0) return null;
    return .{ .band = paneBandRect(bar), .entry = entry };
}

/// 활성 탭의 활성 panel을 닫는다(split이 있으면 pane을 하나씩 닫는다). 트리를 형제로
/// collapse(removeLeaf)하고 panel을 teardown(destroyPane)한 뒤, active_pane을 보정하고, 대표 surface·
/// pump를 새 활성 panel로 재바인딩하고, 남은 panel을 collapse된 트리의 새 leaf rect로 resize한다. panel이
/// 1개뿐이면 무동작(그 경우 resolveWorkspaceScope가 .tab/.session으로 보내 closeTab/latch가 맡는다). 활성 탭에만 적용한다.
pub fn closeActivePane(self: *AppSession) void {
    const tab = tab_ops.activeTab(self);
    if (tab.panes.items.len <= 1) return; // 단일 panel은 탭 close 경로
    const idx = tab.active_pane;
    const closing = tab.panes.items[idx];
    // 1) 트리에서 이 panel(leaf)을 떼고 형제로 collapse — removeLeaf가 떼어낸 split을 돌려주면, divider_drag가
    //    그 split이면 표적 null하고 destroy한다(Term/surface는 아래 destroyPane가).
    const freed_split = PaneTree.removeLeaf(&tab.tree, closing) orelse return;
    invalidateForFreedSplit(self, freed_split);
    self.allocator.destroy(freed_split);
    // 2) panes에서 빼고 panel teardown(모든 Term closeAndDetach → reader join → surface deinit → free).
    _ = tab.panes.orderedRemove(idx);
    destroyPane(self, closing);
    // 3) active_pane 보정: 닫은 게 마지막이면 이전, 아니면 그 자리로 온 다음 panel(같은 인덱스).
    tab.active_pane = if (idx >= tab.panes.items.len) tab.panes.items.len - 1 else idx;
    // 4) 대표 surface(= app_window.active())·pump를 새 활성 panel(의 활성 Term)로 재바인딩(닫은 포인터 dangling 방지).
    self.surface_ptrs.items[self.app_window.active_tab] = tab.activeTerm().surface;
    self.app_window.tabs = self.surface_ptrs.items;
    // 5) 남은 panel을 collapse된 트리의 새 leaf rect로 resize + 좌표 origin 재계산.
    resizeActiveTabPanes(self) catch {};
    recomputeActivePaneRect(self);
    // 닫은 Pane·해제된 split 노드를 가리키던 호버·divider 포인터는 위 destroyPane이 invalidateForFreedPane
    // (S1 chokepoint)으로 이미 비웠다 — 여기서 따로 리셋하지 않는다.
    self.metal_dirty = true;
}

pub fn dividerBandPt(self: *const AppSession, content: maru.session.SplitRect, target: web_panel_layout.RectF64, edge: web_panel_layout.DividerEdge) f64 {
    const px = web_panel_layout.dividerPassThroughBandPx(content, target, edge);
    return px * 1000.0 / @as(f64, @floatFromInt(@max(@as(u32, 1), self.scale_milli)));
}

/// close 대상 pane(활성 pane이 아닐 수 있다). `agent_term`은 그 Term이 사는 pane이다.
pub fn closeTargetPane(self: *AppSession, target: PendingClose) ?*Pane {
    switch (target) {
        .agent_term => |t| {
            if (t.tab >= self.tabs.items.len) return null;
            const tab = self.tabs.items[t.tab];
            if (t.pane >= tab.panes.items.len) return null;
            return tab.panes.items[t.pane];
        },
        else => return activePane(self),
    }
}

pub fn dockDividerGrabBandPx(self: *const AppSession) u32 {
    if (dividerThicknessPx(self) == 0) return 0;
    return dock_layout.dividerGrabBandPx(self.scale_milli);
}

/// divider drag가 끝났거나(up/drop) 취소됐을 때 host 쪽 흔적을 전부 지운다. coalescer의 `applied`
/// 까지 비우는 것이 중요하다 — 남기면 다음 drag의 첫 move가 "안 바뀌었다"로 먹힌다.
pub fn endDividerCapture(self: *AppSession) void {
    self.divider_interaction.capture = null;
    self.divider_capture_seg = null;
    self.divider_capture_split = null;
    self.divider_coalescer.reset();
}

/// Phase 7e-2a: 주소창 편집 중(addr_edit)인 surface가 **활성 탭인 leaf**의 PaneBar(밴드·caret 위치 공유 소스).
/// 편집 아님/그 surface가 활성 탭 아님/바 없음이면 null. imeCursorRect(.addr_edit caret)·mouse-down 클릭-어웨이(밴드
/// 재클릭 판정)가 같은 leaf 기하를 쓰게 한다 — 렌더 "1c"·클릭 ①b의 band(y=full.y+bar_h)와 정합.
pub fn addrEditPaneBar(self: *AppSession) ?PaneBar {
    const sid = web_ops.addrEditSurfaceId(self) orelse return null;
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return null;
    for (leaf_rects.items) |lr| {
        const at = lr.leaf.active_term;
        if (at >= lr.leaf.terms.items.len) continue;
        const term = lr.leaf.terms.items[at];
        if (isBrowserTerm(term) and term.surfaceId() == sid) {
            return paneBar(self, lr.rect, lr.leaf);
        }
    }
    return null;
}

/// 드롭 타겟 하이라이트로 강조할 사이드바 표시 슬롯 — computePaneDropDest(드롭 판정 단일 출처)에서 도출한다.
/// merge면 그 카드의 표시 슬롯(displaySlotOf), new_workspace면 첫 그룹 헤더 앞(최상위 구간 끝 = 실제 삽입 위치,
/// 그룹 없으면 카드 아래 행). 드롭 아님(밖/자기)이면 null.
pub fn paneDropHighlightSlot(self: *AppSession, x_px: f64, y_px: f64) ?usize {
    return switch (computePaneDropDest(self, x_px, y_px) orelse return null) {
        .new_workspace => newWorkspaceHighlightSlot(self), // 최상위 구간 끝(첫 그룹 헤더 앞) — 삽입 위치와 정합
        .merge => |tab_idx| self.displaySlotOf(tab_idx), // 합칠 카드의 표시 슬롯(검색 필터로 숨겨졌으면 null)
    };
}

/// 한 pane 우측에 스크롤바 thumb(둥근 GpuQuad)를 그린다 — 스크롤백이 있을 때만(sb_count>0). thumb 높이는
/// 보이는 비율, 위치는 view_offset(0=바닥, sb_count=꼭대기)을 반영한다. 셀 위(layer 3 over)에 뜬다.
/// alpha는 pane.scrollbar_idle_ticks로 fade(활성·비활성 모두 per-pane 독립). `is_active`면 추가로 hover/드래그
/// 강조(굵게+full, 세션 상태) — 상호작용(hover/드래그)은 활성 pane만이라 비활성 pane은 fade만(emphasize 없음).
/// 메모리 'UI는 Zig+GPU 렌더러로' — 네이티브 NSScroller가 아니라 chrome GpuQuad 프리미티브. 좌표는 backing 픽셀.
pub fn appendScrollbar(self: *AppSession, rect: maru.session.SplitRect, pane: *Pane, is_active: bool) void {
    if (rect.w == 0) return;
    // 코어 읽기는 **락 아래**(§9.1) — `scrollStateOf`의 계약이 그렇다(snapshot이 소스 메모리를 alias).
    // 옛 코드는 렌더 경로만 락 없이 읽어, 대량 출력 중 `scrollback_len`이 ms마다 늘면 fade 판정(락 아래
    // 값)과 thumb 기하(락 밖 값)가 서로 다른 시점에서 나와 thumb이 미세하게 튀었다. host-backed surface면
    // 이 락이 곧 RemoteScreen mutex라 계약이 더 강하다. 형제 경로(updateScrollbarFade·dragScrollbarTo)는
    // 이미 락을 잡는다 — 렌더만 예외였다.
    const surface = pane.activeTerm().surface;
    const scroll_state = blk: {
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        break :blk scrollStateOf(surface);
    };
    const geom = scrollbarThumbGeom(scroll_state.scrollback_len, scroll_state.view_offset, self.cell_height_px, rect.h) orelse return;
    const thumb_y: f32 = @as(f32, @floatFromInt(rect.y)) + geom.y;
    const thumb_h: f32 = geom.h;
    // 활성 pane만 hover/드래그로 굵게+full(세션 상태). alpha는 **per-pane fade**(각 pane scrollbar_idle_ticks) —
    // 활성·비활성 모두 자기 스크롤 활동으로 독립적으로 흐려진다(비활성 pane을 휠로 스크롤하면 그 pane만 full→fade).
    const emphasized = is_active and (self.scrollbar_hovered or self.pointerGestureIs(.scrollbar));
    const bar_w: f32 = scrollbarBarWidthPx(self.cell_width_px, emphasized);
    const x: f32 = @as(f32, @floatFromInt(rect.x + rect.w)) - bar_w - 2.0; // 우측 가장자리에서 2px 안쪽
    const alpha: u8 = if (emphasized) scrollbar_alpha_full else scroll_ops.scrollbarAlpha(self, pane.scrollbar_idle_ticks);
    const rgb = self.mutedForeground(); // muted 전경(사이드바 비활성 탭과 같은 톤)
    const color: u32 = packRgbAlpha(rgb, alpha); // 셰이더가 rgb*=a premultiply
    const r = bar_w * 0.5; // pill 모양(반지름 = 폭 절반)
    self.gpu_quads.append(self.allocator, .{
        .x = x,
        .y = thumb_y,
        .w = bar_w,
        .h = thumb_h,
        .corner_radii = .{ r, r, r, r },
        .border_widths = .{ 0, 0, 0, 0 },
        .fill_color0 = color,
        .fill_color1 = color,
        .border_color = 0,
        .gradient_kind = 0,
        .layer = 3, // over 패스(셀·사이드바 위) per-frame. layer 1(모달)이 gpu_quads에서 뒤에 append돼 위로 — 모달이 스크롤바를 가린다.
    }) catch {};
}

/// pane grip 드래그 up(drop) — 드롭 목적지에 따라 분리(promote)/합치기(merge). 사이드바 밖/자기 워크스페이스면
/// 무동작. mouse가 up(kind 3)에서 부른다(pane_drag 캡처 경로).
pub fn dropPaneAt(self: *AppSession, x_px: f64, y_px: f64) void {
    const pane = switch (self.pointer_gesture_owner) {
        .pane => |drag| drag.pane,
        else => return,
    };
    const dest = computePaneDropDest(self, x_px, y_px) orelse return;
    switch (dest) {
        .new_workspace => promotePaneToNewWorkspace(self, pane),
        .merge => |idx| mergePaneIntoWorkspace(self, pane, idx),
    }
}

/// panel leaf rect의 상단 탭 바와 window padding을 뺀 '셀 그리드 영역'. `paneGeometry` accessor라
/// bar/padding 산술을 소유하지 않는다.
pub fn paneTermRect(self: *const AppSession, rect: maru.session.SplitRect) maru.session.SplitRect {
    return paneGeometry(self, rect).grid;
}

/// 활성 탭의 각 panel을 자기 leaf rect grid로 resize한다(window resize·split 후 재배치). 단일 leaf면
/// 활성 surface 하나를 full term grid로 — 기존 resizeActiveSurface와 동일 효과. **레이아웃 적용은 개별 Term의
/// runtime 전달 실패로 중단되지 않는다**(표시 grid는 `resizeTermForLayout`이 보장하고, 못 전달한 사실은
/// `noteResizeDeliveryFailure`가 남긴다). leaf rect 계산 실패(OOM)만 전파한다.
pub fn resizeActiveTabPanes(self: *AppSession) !void {
    if (layoutGeometryUnknown(self)) return;
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    try tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects);
    for (leaf_rects.items) |lr| {
        // 각 panel은 상단 탭 바를 뺀 '터미널 영역'(paneTermRect)에 그려지므로 Term grid도 그 크기로 맞춘다.
        const trect = paneTermRect(self, lr.rect);
        const psize = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, trect.w, trect.h);
        // panel의 모든 Term(가로 탭)을 같은 rect grid로 맞춘다 — 비활성 Term도 전환 즉시 올바른 크기가 되게.
        for (lr.leaf.terms.items) |term| {
            // **레이아웃 적용은 한 Term의 runtime 전달 실패로 중단되지 않는다.** 표시 grid는
            // `resizeTermForLayout`이 이미 보장하므로 남은 error는 "PTY winsize·원격 host에 못 보냈다"뿐인데,
            // 그걸 밖으로 전파하면 `resize()`가 `recomputeActivePaneRect`·`last_resize_size`·`metal_dirty`를
            // 스킵한 half-state로 끝난다(활성 pane의 세션이 죽어 있으면 창 크기 조정이 통째로 깨짐).
            // 대신 삼키지 않고 관측 지점에 남긴다(관측 가능성 원칙).
            self.resizeTermForLayout(term, psize) catch |err| self.noteResizeDeliveryFailure(term, err);
        }
    }
}

pub fn paneHasRunningJob(pane: *Pane, io: std.Io) bool {
    for (pane.terms.items) |t| if (termHasRunningJob(t, io)) return true;
    return false;
}

/// 얇은 **세로선**을 overlay 셀로 그린다 — [y_start, y_end) 범위에 행마다(cell 높이 step) origin_x에 sentinel
/// 셀 1개씩, reserved=30으로 seam 중앙의 configured divider strip을 칠한다.
pub fn appendVerticalLine(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell), origin_x: u32, y_start: u32, y_end: u32, reserved: u16, color: u32) void {
    const ch = self.cell_height_px;
    if (ch == 0) return;
    var y = y_start;
    while (y < y_end) : (y += ch) {
        var c = sentinelBgCell(0, 1, color, origin_x, y);
        c.reserved = reserved;
        out.append(self.allocator, c) catch return;
    }
}

/// panel leaf rect의 상단 탭 바 rect(못 그리면 null — 바 없을 만큼 작거나 cell 미상). `paneGeometry` accessor.
pub fn paneBarRect(self: *const AppSession, rect: maru.session.SplitRect) ?maru.session.SplitRect {
    return paneGeometry(self, rect).bar;
}

/// Workspace SplitTree divider의 실제 chrome hit-test 폭과 같은 분수 px target. leaf bounds로 교차축과
/// 해당 leaf 쪽 절반만 제한해도 content edge와의 교집합은 실제 parent-bounds target과 동일하다.
pub fn paneDividerTarget(self: *const AppSession, leaf: maru.session.SplitRect, edge: web_panel_layout.DividerEdge) web_panel_layout.RectF64 {
    const orientation: chrome.components.divider.Orientation = if (edge == .bottom) .horizontal_line else .vertical_line;
    const half = chrome.components.divider.hitHalfExtentPx(orientation, self.cell_width_px, self.cell_height_px);
    return switch (edge) {
        .left => .{ .x = @as(f64, @floatFromInt(leaf.x)) - half, .y = @floatFromInt(leaf.y), .w = 2 * half, .h = @floatFromInt(leaf.h) },
        .right => .{ .x = @as(f64, @floatFromInt(leaf.x +| leaf.w)) - half, .y = @floatFromInt(leaf.y), .w = 2 * half, .h = @floatFromInt(leaf.h) },
        .bottom => .{ .x = @floatFromInt(leaf.x), .y = @as(f64, @floatFromInt(leaf.y +| leaf.h)) - half, .w = @floatFromInt(leaf.w), .h = 2 * half },
    };
}

pub fn renamingPane(self: *const AppSession, pane: *Pane) bool {
    const r = self.rename orelse return false;
    return switch (r) {
        .pane => |p| p == pane,
        else => false,
    };
}

/// 이미 shapeOnly된 ShapedPane을 collected에 추가한다 — append-or-deinit 꼬리의 단일 출처다(collectShaped는 DrawList를
/// shapeOnly한 뒤 이걸 부르고, 활성 panel은 frame_builder가 미리 shape한 ShapedPane을 바로 넘긴다). append 실패면 그
/// 페인만 deinit. 소유권은 collected로 이전되므로 호출자는 넘긴 ShapedPane을 더는 deinit하지 않는다(호출자가 보관
/// 변수를 null로 비운다).
pub fn collectShapedPane(self: *AppSession, collected: *std.ArrayList(CollectedPane), pane: coretext_frame_builder.ShapedPane, builder: coretext_frame_builder.CoreTextFrameBuilder, dest: CollectDest) void {
    var p = pane;
    collected.append(self.allocator, .{ .pane = p, .dest = dest, .builder = builder }) catch {
        p.deinit(self.allocator);
    };
}

/// capture를 다음 발행으로 넘길지 판정하는 §5 compatibility key. epoch와 domain identity는
/// chrome이 모르는 값이라 host가 채우고, 중립 모듈은 **같은지만** 본다. 여기서 epoch는 활성 탭
/// (탭을 바꾸면 다른 트리)이고 domain identity는 그 identity가 지금 가리키는 split이다.
pub fn dividerCompatibilityKey(self: *AppSession, identity: u64) chrome.ui.interaction.GestureCompatibility {
    return .{
        .kind = identity,
        .enabled = true,
        .owner_epoch = @intFromPtr(tab_ops.activeTab(self)),
        .domain_identity = if (dividerSplitForIdentity(self, identity)) |split| @intFromPtr(split) else 0,
    };
}

/// 한 panel(Pane)을 heap-pin으로 만든다 — Term 1개를 담은 컨테이너. 탭→pane 모델에서 Pane은 여러 Term을
/// 가로 탭으로 들 수 있고(⌘T가 추가), 생성 시엔 1개로 시작한다. heap-pin(`*Pane`)이라 트리 회전·ArrayList
/// realloc에도 본체가 안 움직인다(SplitTree leaf가 이 `*Pane`을 가리킴). 부분 실패는 errdefer로 정리.
pub fn createPane(
    self: *AppSession,
    request: maru.pty.SpawnRequest,
    size: terminal.Size,
    queue_capacity: usize,
    title: []const u8,
    command: []const u8,
) !*Pane {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);
    pane.* = .{};
    errdefer pane.terms.deinit(self.allocator);

    const term = try self.createTerm(request, size, queue_capacity, title, command);
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    pane.active_term = 0;
    return pane;
}

/// 활성 탭의 한 pane을 통째로 떼어 **다른** 워크스페이스(target_index)에 합친다(grip 핸들을 그 카드에 드롭).
/// target의 활성 pane을 좌우(`split_horizontal`)로 나눠 들어온 pane을 우측·활성으로 둔다(⌘D 관례 — 카드는
/// 방향 정보가 없어 기본 좌우). 트리 수술은 moveTermToNewSplit과 같은 모양(replaceLeaf로 target leaf → split)
/// 이되 새 pane을 만들지 않고 떼어온 pane을 재사용한다. 소스의 마지막 pane이면 빈 소스 워크스페이스를 함께
/// 제거한다. target이 자기 워크스페이스거나 범위 밖이면 무동작. 단일 출처: docs/tabs-splits-layout.md.
pub fn mergePaneIntoWorkspace(self: *AppSession, pane: *Pane, target_index: usize) void {
    const src_tab = tab_ops.activeTab(self);
    const src_index = self.app_window.active_tab;
    if (target_index == src_index or target_index >= self.tabs.items.len) return; // 자기/범위 밖 — 무동작
    const target_tab = self.tabs.items[target_index];
    const target_active = target_tab.activePane();
    // 1) 실패 가능한 alloc 먼저: split 노드 + target.panes capacity. 실패하면 src 무변.
    const split = self.allocator.create(PaneTree.Split) catch return;
    target_tab.panes.ensureUnusedCapacity(self.allocator, 1) catch {
        self.allocator.destroy(split);
        return;
    };
    split.* = .{
        .direction = .horizontal,
        .ratio = 0.5,
        .a = .{ .leaf = target_active },
        .b = .{ .leaf = pane },
    };
    // 2) target 트리에 split을 먼저 끼운다(pane이 잠시 양쪽 트리 leaf가 되지만 동기라 무해). target_active는
    //    target leaf라 false일 수 없으나, 도달 불가 분기에서 split만 해제하고 src를 안 건드린 채 빠진다.
    if (!PaneTree.replaceLeaf(&target_tab.tree, target_active, .{ .split = split })) {
        self.allocator.destroy(split);
        return;
    }
    // 이후 수술은 infallible다. target workspace로 포커스를 옮기기 전에 조합을 원 surface에 확정한다.
    self.commitComposition();
    // 3) infallible: src에서 떼고 두 탭 대표 surface 재바인딩 + target.panes에 pane 추가. 마지막 pane이면
    // 빈 workspace를 남기지 않고 Tab shell만 제거한다(Pane/Term/surface/PTY는 target이 그대로 승계).
    const source_workspace_removed = src_tab.panes.items.len == 1;
    if (source_workspace_removed) {
        self.cancelPointerGesture();
        _ = self.inheritGroupMarker(src_index);
        _ = self.reestablishTopLevelBoundaryOnMove(src_index);
        _ = self.tabs.orderedRemove(src_index);
        _ = self.surface_ptrs.orderedRemove(src_index);
        self.app_window.tabs = self.surface_ptrs.items;
    } else {
        _ = detachPaneFromTab(self, src_tab, pane);
        self.surface_ptrs.items[src_index] = src_tab.activeTerm().surface;
    }
    self.hovered_tab = null;
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버도 함께 정리
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    target_tab.panes.appendAssumeCapacity(pane);
    target_tab.active_pane = target_tab.panes.items.len - 1;
    const landed_index = if (source_workspace_removed and target_index > src_index) target_index - 1 else target_index;
    self.surface_ptrs.items[landed_index] = target_tab.activeTerm().surface;
    if (source_workspace_removed) {
        // src_tab은 이제 collection 밖의 빈 workspace shell이다. tree의 leaf와 panes 항목은 target이 소유하므로
        // destroyTabStandalone/destroyPane을 쓰지 않고 컨테이너와 owned sidebar metadata만 정리한다.
        if (workspace_ops.renamingWorkspace(self, src_tab) or self.renamingGroup(src_tab)) {
            self.rename = null;
            self.rename_input.clear();
        }
        if (self.context_menu_target) |t| {
            const hit = switch (t) {
                .workspace => |w| w == src_tab,
                .group => |g| g == src_tab,
                else => false,
            };
            if (hit) {
                self.context_menu_target = null;
                self.chrome_host.context_menu.hide();
            }
        }
        if (src_tab.custom_name) |n| self.allocator.free(n);
        if (src_tab.group_start) |g| self.allocator.free(g);
        PaneTree.deinit(self.allocator, src_tab.tree); // leaf는 해제하지 않으며 split은 단독 pane이라 없음
        src_tab.panes.deinit(self.allocator);
        self.allocator.destroy(src_tab);
        self.normalizePinnedFromGroups();
        self.floatLocalPinsAllGroups();
    }
    // 4) 소스 resize(형제 확장) 후 target을 활성으로 전환(switchTab이 target resize+좌표+사이드바 재빌드).
    if (!source_workspace_removed) resizeTabPanes(self, src_tab);
    _ = tab_ops.switchTab(self, landed_index);
    self.metal_dirty = true;
}

/// pane 라벨(탭바) 색의 대표 에이전트 종류 — running Term 우선, 없으면 활성 Term kind.
pub fn paneAgentKind(pane: *Pane) AgentKind {
    for (pane.terms.items) |t| if (t.agent_state == .running and t.agent_kind != .none) return t.agent_kind;
    return pane.activeTerm().agent_kind;
}

/// 한 panel을 teardown하고 heap 해제한다 — 담긴 모든 Term을 destroyTerm한 뒤 terms 리스트·Pane을 해제.
/// createPane errdefer·closeTab·closeActivePane·split 실패 정리에 쓴다. **모든 Pane 해제의 단일 chokepoint라,
/// 해제 직전 구조-무효화 계약(invalidateForFreedPane)을 부른다 — 이 Pane을 가리키던 호버/드래그 포인터를 정리.**
pub fn destroyPane(self: *AppSession, pane: *Pane) void {
    invalidateForFreedPane(self, pane); // S1: 포인터 비교는 해제 전 주소로(deref 없음) — 흩어진 null화 대체
    for (pane.terms.items) |term| self.destroyTerm(term);
    if (pane.custom_name) |n| self.allocator.free(n); // 사용자 rename(owned) 해제
    pane.terms.deinit(self.allocator);
    self.allocator.destroy(pane);
}

pub fn paneLabelColsForWidth(name_width: usize, bar_cols: u32) u32 {
    if (name_width == 0) return 0;
    const max_label: u32 = 20; // 긴 이름이 바를 지배하지 않게 상한
    if (bar_cols <= pane_min_tab_cols) return 0;
    const want = @min(@as(u32, @intCast(name_width)) + 2, max_label); // 좌패딩+이름+간격
    const cols = @min(want, bar_cols - pane_min_tab_cols);
    return if (cols < 3) 0 else cols; // 3칸 미만이면 패딩+글자+간격 불가 → 생략
}

/// 활성 panel의 픽셀 rect를 다시 계산해 캐시한다(`active_pane_rect`). 활성 탭 tree를 터미널 영역에서
/// 펴 활성 surface의 leaf rect를 찾는다. 못 찾거나(OOM) 단일 panel이면 터미널 영역 전체로 폴백 —
/// 단일 panel은 그게 곧 활성 rect라 결과가 같다. 레이아웃/포커스/리사이즈가 바뀔 때(split·switchTab·
/// resize·focusPane·closeTab·init) 호출해, pxToCell/imeCursorRect가 매 마우스 이벤트마다 재레이아웃
/// (할당) 없이 캐시된 origin을 읽게 한다.
pub fn recomputeActivePaneRect(self: *AppSession) void {
    const active_pane = activePane(self);
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    if (tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects)) |_| {
        for (leaf_rects.items) |lr| {
            if (lr.leaf == active_pane) {
                self.active_pane_rect = paneTermRect(self, lr.rect); // 상단 탭 바를 뺀 영역(좌표 origin)
                return;
            }
        }
    } else |_| {}
    self.active_pane_rect = paneTermRect(self, self.termRect()); // 폴백: 터미널 영역(바 아래)
}

pub fn dockDividerAtPoint(self: *const AppSession, x_px: f64, y_px: f64) bool {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    return layout_math.pointInRect(
        x_px,
        y_px,
        dock_layout.outerDividerHitRect(dock_ops.dockGeometry(self), self.dock.side, dockDividerGrabBandPx(self)),
    );
}

/// 모델 Pane → 완성된 *Pane. 첫 surface로 createPane(=1 Term)하고 나머지 surface를 Term으로 추가한다.
/// FP16 §5.0: pane은 **persisted 시퀀스**(터미널 surface + 파일 Term)를 index 순서대로 되살린다.
/// `file-term`의 index가 그 시퀀스 안의 자리이고, 나머지 자리를 `surfaces`가 순서대로 채운다.
/// pane은 항상 Term >= 1이어야 하므로(모델 불변식) 시퀀스가 비면 `EmptyPane`이다.
pub fn buildWorkspacePane(self: *AppSession, m: maru.session.workspace.Pane) !*Pane {
    const total = m.surfaces.len + m.file_terms.len;
    if (total == 0) return error.EmptyPane;

    // pane 생성은 surface 하나가 필요하다. 터미널이 하나도 없는(파일 Term만인) pane은 첫 파일로 만든다.
    var pane: *Pane = undefined;
    var next_surface: usize = 0;
    var seeded_file = false;
    if (m.surfaces.len > 0) {
        pane = try createPaneFromSurface(self, m.surfaces[0]);
        next_surface = 1;
    } else {
        pane = try createPaneFromFileTerm(self, m.file_terms[0]);
        seeded_file = true;
    }
    errdefer destroyPane(self, pane);
    pane.custom_name = try self.dupeCustomName(m.custom_name); // pane 사용자 rename 복원(errdefer destroyPane가 free)
    try pane.terms.ensureTotalCapacity(self.allocator, total);

    // 시퀀스를 앞에서부터 채운다. 각 자리는 그 index를 요구하는 file-term이 있으면 파일 Term, 없으면
    // 다음 터미널 surface다(검증 — index 중복 없음·[0,total) 전수 — 은 파서가 이미 했다). seed로 이미
    // 만든 Term은 건너뛴다.
    var slot: usize = 0;
    var seed_file_used = !seeded_file;
    while (slot < total) : (slot += 1) {
        const file_index: ?usize = blk: {
            for (m.file_terms, 0..) |ft, fi| if (ft.index == slot) break :blk fi;
            break :blk null;
        };
        if (file_index) |fi| {
            if (!seed_file_used) {
                seed_file_used = true; // seed가 곧 이 자리의 파일이다(터미널 0개인 pane)
                continue;
            }
            pane.terms.appendAssumeCapacity(try createFileTermFromModel(self, m.file_terms[fi]));
            continue;
        }
        if (next_surface >= m.surfaces.len) continue; // seed로 쓴 surface 자리
        pane.terms.appendAssumeCapacity(try createTermFromSurface(self, m.surfaces[next_surface]));
        next_surface += 1;
    }
    pane.active_term = @min(m.active_term, pane.terms.items.len - 1);

    // WP-P: 브라우저 Term을 `insert_after`(앞의 persisted Term 수) 자리에 끼워 넣는다. 뒤에서부터 삽입해야
    // 앞 record의 자리 계산이 안 밀린다(같은 insert_after가 여럿이면 등장 순서를 유지한다 — 뒤 record가 더
    // 뒤에 오도록 역순으로 넣는다). URL은 Term에 pending으로 달고, surface가 생성된 tick에 navigate로 나간다.
    if (m.browser_terms.len > 0) {
        var bi = m.browser_terms.len;
        while (bi > 0) {
            bi -= 1;
            const bt = m.browser_terms[bi];
            const at = @min(bt.insert_after, pane.terms.items.len);
            const term = web_ops.createWebTerm(self, .browser) catch continue; // 실패한 record만 버린다(창은 살린다)
            term.pending_url = self.allocator.dupe(u8, bt.url) catch null;
            pane.terms.insert(self.allocator, at, term) catch {
                self.destroyTerm(term);
                continue;
            };
            // 활성 record면 그 자리를 활성 탭으로. 아니면 삽입으로 밀린 활성 인덱스를 보정한다.
            if (m.active_browser) |ab| {
                if (ab == bi) {
                    pane.active_term = at;
                } else if (at <= pane.active_term) {
                    pane.active_term += 1;
                }
            } else if (at <= pane.active_term) {
                pane.active_term += 1;
            }
        }
        pane.active_term = @min(pane.active_term, pane.terms.items.len - 1);
    }
    return pane;
}

pub fn recordEndedPlaceholder(self: *AppSession, newly_gone: bool) void {
    self.ended_placeholder_notice_pending += 1;
    if (newly_gone) self.ended_placeholder_dropped_pending += 1;
}

/// 활성 탭의 leaf 중 pane==찾는 pane인 것의 PaneBar(rename caret 위치 계산용). 못 찾으면 null.
pub fn paneBarForLeaf(self: *AppSession, pane: *Pane) ?PaneBar {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return null;
    for (leaf_rects.items) |lr| {
        if (lr.leaf == pane) return paneBar(self, lr.rect, lr.leaf);
    }
    return null;
}

/// 활성 탭이 split(panel 2개 이상)인가. 마우스 클릭으로 panel을 전환할지(단일이면 무동작) 판정에 쓴다.
pub fn activeTabHasSplit(self: *AppSession) bool {
    return PaneTree.leafCount(tab_ops.activeTab(self).tree) > 1;
}

pub fn clearRestoreRuntimeIdentity(self: *AppSession) void {
    self.restore_runtime_host_id = "";
    self.restore_runtime_id = "";
}

/// 비어 있는 pane(모든 Term이 옮겨 나감/exit)을 활성 탭에서 collapse한다. cross-pane 이동(moveTermToPane)이
/// 쓰는 활성 탭 전용 래퍼 — 임의 탭은 collapsePaneIn을 직접 쓴다.
pub fn collapsePane(self: *AppSession, pane: *Pane) void {
    collapsePaneIn(self, tab_ops.activeTab(self), pane);
}

/// app DividerSeg(라이브 *Split 결합)를 neutral chrome `divider.Seg`로 변환한다 — chrome은 app 트리를 모르므로
/// host가 떼어 준다(palette Row 선례). 좌우 분할(horizontal)=세로선, 상하 분할(vertical)=가로선. bounds는 u32→i32.
pub fn appSegToDivider(seg: PaneTree.DividerSeg) chrome.components.divider.Seg {
    return .{
        .orientation = switch (seg.direction) {
            .horizontal => .vertical_line,
            .vertical => .horizontal_line,
        },
        .bounds = .{ .x = @intCast(seg.bounds.x), .y = @intCast(seg.bounds.y), .w = seg.bounds.w, .h = seg.bounds.h },
        .pos = seg.pos,
    };
}

pub fn dividerCaptureActive(self: *const AppSession) bool {
    return self.divider_interaction.capture != null;
}

/// 드래그한 Term을 src에서 빼 '새 pane'에 담고, target pane의 자리(leaf)를 split{...}로 바꿔 zone 방향으로
/// 끼운다(④: Term 탭을 다른 pane 본문에 드롭 → 거기 새 split). left/right=좌우(horizontal), top/bottom=
/// 상하(vertical); left/top은 새 pane이 앞(a), right/bottom은 뒤(b). 모든 alloc을 먼저 해 실패 시 트리/terms를
/// 안 건드린다(Term은 src에 남는다). 성공 후 새 pane으로 포커스, src가 비면 collapse, 전 panel resize.
/// target==src인데 src Term이 1개뿐이면(자기를 자기로 split) 무의미 — 무동작.
pub fn moveTermToNewSplit(self: *AppSession, src: *Pane, src_idx: usize, target: *Pane, zone: layout_math.PaneDropZone) void {
    if (src_idx >= src.terms.items.len) return;
    if (target == src and src.terms.items.len <= 1) return;
    const tab = tab_ops.activeTab(self);
    const dir: maru.session.SplitDirection = switch (zone) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
    };
    const new_first = switch (zone) {
        .left, .top => true,
        .right, .bottom => false,
    };
    // 1) 실패 가능한 alloc을 먼저(트리/terms는 아직 안 건드림): 빈 새 pane + terms capacity + panes append + split.
    const new_pane = self.allocator.create(Pane) catch return;
    new_pane.* = .{};
    new_pane.terms.ensureTotalCapacity(self.allocator, 1) catch {
        self.allocator.destroy(new_pane);
        return;
    };
    tab.panes.append(self.allocator, new_pane) catch {
        new_pane.terms.deinit(self.allocator);
        self.allocator.destroy(new_pane);
        return;
    };
    const split = self.allocator.create(PaneTree.Split) catch {
        _ = tab.panes.pop();
        new_pane.terms.deinit(self.allocator);
        self.allocator.destroy(new_pane);
        return;
    };
    split.* = .{
        .direction = dir,
        .ratio = 0.5,
        .a = if (new_first) .{ .leaf = new_pane } else .{ .leaf = target },
        .b = if (new_first) .{ .leaf = target } else .{ .leaf = new_pane },
    };
    // 2) 트리에서 target leaf → split{...} 교체. 미발견이면 전부 원복(트리는 변형 전이라 무변).
    if (!PaneTree.replaceLeaf(&tab.tree, target, .{ .split = split })) {
        self.allocator.destroy(split);
        _ = tab.panes.pop();
        new_pane.terms.deinit(self.allocator);
        self.allocator.destroy(new_pane);
        return;
    }
    // replace 성공 뒤는 infallible다. 새 split을 활성화하기 전에 원 surface의 marked text를 확정한다.
    self.commitComposition();
    // 3) 이제 infallible: src에서 Term을 빼 새 pane으로(capacity 확보됨). Term은 heap-pin이라 surface/reader 안 움직임.
    const term = src.terms.orderedRemove(src_idx);
    new_pane.terms.appendAssumeCapacity(term);
    new_pane.active_term = 0;
    // src에서 임의 위치(src_idx)를 뺐으니 활성 인덱스를 시프트 보정한다(단일 출처) — 비면(아래 collapse) 0 무의미.
    src.active_term = if (src.terms.items.len == 0) 0 else activeIndexAfterRemoval(src.active_term, src_idx, src.terms.items.len);
    self.hovered_tab = null; // 트리/탭 변경 — stale 호버 정리
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버도 함께 정리(stale 하이라이트 방지)
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    // **사이드바도 다시 투영한다**: 에이전트 목록 행은 pane/term **인덱스**를 들고 있어, Term이 reap으로 빠지면
    // 남은 행의 인덱스가 다른 Term을 가리킨다(범위 검사만으로는 못 걸러낸다 — 길이는 여전히 유효하므로).
    // 그대로 두면 사용자가 보는 행과 클릭이 닫는 Term이 어긋난다(code-review max).
    sidebar_ops.rebuildSidebar(self) catch {};
    if (src.terms.items.len == 0) collapsePaneIn(self, tab, src); // src가 비면 collapse(removeLeaf)
    // 4) 새 pane으로 포커스 + 대표 surface 재바인딩 + 전 panel을 새 leaf rect grid로 resize + 좌표 재계산.
    _ = focusPaneByPtr(self, new_pane);
    resizeActiveTabPanes(self) catch {};
    recomputeActivePaneRect(self);
    self.metal_dirty = true;
}

/// 활성 탭의 **보이는** 위치. `pane.active_term`은 model 인덱스라 preview와 순서가 다르면 두 해석이 갈린다 —
/// preview를 그대로 쓰는 게 아니라 model이 가리키는 `*Term`을 preview에서 되찾는다.
pub fn paneActiveTermIndex(self: *AppSession, pane: *Pane) usize {
    const order = paneTermOrder(self, pane);
    if (order.ptr == pane.terms.items.ptr) return pane.active_term;
    if (pane.active_term >= pane.terms.items.len) return pane.active_term;
    const active = pane.terms.items[pane.active_term];
    for (order, 0..) |t, i| if (t == active) return i;
    return pane.active_term;
}

/// leaf rect를 이미 든 호출자(렌더·hit-test 루프)가 아닌 곳에서 쓰는 조회판 — 활성 탭에서 그 pane의
/// leaf rect를 찾아 같은 밴드를 준다.
pub fn fileHeaderBandForPaneLookup(self: *AppSession, pane: *Pane) ?FileHeaderBand {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return null;
    for (leaf_rects.items) |lr| {
        if (lr.leaf == pane) return fileHeaderBandForPane(self, pane, lr.rect);
    }
    return null;
}

pub fn computePaneDropDest(self: *AppSession, x_px: f64, y_px: f64) ?PaneDropDest {
    if (!sidebar_ops.inSidebar(self, x_px)) return null; // 사이드바 밖 — 드롭 아님
    // 헤더(검색바·◧/⚙/+ 아이콘) 영역은 드롭 불가 — 여기서 떼면 sidebarSlotAt가 null이라 아래 폴백이 new_workspace로
    // 떨어져 '검색바에 떨어뜨려도 새 워크스페이스가 생기는' 오동작이 된다(하이라이트도 카드 아래 행에 잘못 켜진다).
    if (y_px < @as(f64, @floatFromInt(self.sidebar_header_height_px))) return null;
    if (sidebar_ops.sidebarSlotAt(self, y_px)) |slot| {
        // 유효 row 위. 카드면 그 워크스페이스에 merge. **그룹 헤더 row(visibleTab=null)면 no-op** — pane을
        // "그룹"에 넣는 개념이 없고(그룹은 워크스페이스가 아니라 묶음), 새 워크스페이스도 아니므로(옛 코드는 여기서
        // new_workspace로 falls through해 헤더에 떨어뜨려도 원치 않는 새 워크스페이스가 생겼다, code-review #3)
        // 최소 안전 동작으로 드롭을 무시한다(상단 검색 헤더 가드와 같은 결). past-end(리스트 아래)는 sidebarSlotAt이
        // null이라 이 블록을 건너뛰어 아래 new_workspace로 간다(자연스러운 "빈 영역=새 워크스페이스" 유지).
        const tab_idx = tab_ops.visibleTab(self, slot) orelse return null; // 그룹 헤더 row → 드롭 무동작(no-op)
        if (tab_idx == self.app_window.active_tab) return null; // 자기 워크스페이스 — 무의미
        return .{ .merge = tab_idx };
    }
    return .new_workspace; // 사이드바 빈 영역(카드 목록 아래) — 새 워크스페이스
}

/// 활성 탭의 한 pane(분할 영역)을 **통째로** 떼어 새 단독 워크스페이스로 분리한다(grip 핸들을 사이드바 빈
/// 영역에 드롭). Term을 옮기는 게 아니라 `*Pane` 포인터를 새 Tab의 단일 leaf 트리로 재부모화한다 — 담긴
/// Term(가로 탭)·surface/PTY는 heap-pin이라 그대로 따라온다. 단독 pane 워크스페이스(형제 없음)면 빈
/// 워크스페이스만 남으므로 **무동작**(단독 워크스페이스를 옮기는 건 사이드바 카드 재정렬의 몫). 새 탭을 끝에
/// 붙이고 활성으로 만든다(사이드바 빈 영역 = 목록 아래 = 끝). 단일 출처: docs/tabs-splits-layout.md.
pub fn promotePaneToNewWorkspace(self: *AppSession, pane: *Pane) void {
    const src_tab = tab_ops.activeTab(self);
    if (src_tab.panes.items.len <= 1) return; // 단독 pane — 무동작
    const src_index = self.app_window.active_tab;
    // 1) 실패 가능한 alloc 먼저(트리는 아직 안 건드림) — 새 Tab + 모든 리스트 capacity 예약. 실패하면 pane은
    //    src에 그대로 남는다(원자성). 예약을 다 끝낸 뒤의 단계는 infallible이라 부분 실패가 없다.
    const tab = self.allocator.create(Tab) catch return;
    tab.* = .{};
    tab.panes.ensureTotalCapacity(self.allocator, 1) catch {
        self.allocator.destroy(tab);
        return;
    };
    self.tabs.ensureUnusedCapacity(self.allocator, 1) catch {
        tab.panes.deinit(self.allocator);
        self.allocator.destroy(tab);
        return;
    };
    self.surface_ptrs.ensureUnusedCapacity(self.allocator, 1) catch {
        tab.panes.deinit(self.allocator);
        self.allocator.destroy(tab);
        return;
    };
    // 모든 실패 가능한 예약이 끝났다. pane을 새 workspace의 input owner로 만들기 전에 원 surface의
    // client-local preedit을 확정해, Surface 포인터와 함께 다른 attachment로 이동하지 않게 한다.
    self.commitComposition();
    // 2) infallible: src에서 pane을 떼고(형제로 collapse) src 대표 surface를 새 활성 Term으로 재바인딩.
    _ = detachPaneFromTab(self, src_tab, pane); // len>1 확인했으므로 true
    self.hovered_tab = null; // 트리/탭 변경 — stale 호버 정리
    self.hovered_nav_button = null; // Phase 7e-4: 밴드 nav 버튼 호버도 함께 정리(stale 하이라이트 방지)
    self.hovered_file_header_mode = null; // 파일 헤더 mode 호버도 같은 자리에서 정리(stale 강조 방지)
    self.surface_ptrs.items[src_index] = src_tab.activeTerm().surface;
    // 3) 새 Tab에 pane을 단일 leaf로 심고 tabs/surface_ptrs에 끼워 활성으로. **끝 append가 아니라 첫 group_start
    //    마커 직전**(= 최상위 구간 끝)에 넣는다 — §2.1 연속 파티션상 리스트 끝 탭은 그룹이 하나라도 있으면 항상
    //    마지막 그룹의 멤버로 위치 파생돼(들여쓰기·마지막 그룹이 접혔으면 숨김), "단독 워크스페이스로 분리"가
    //    그룹에 흡수된다. removeFromGroupForTab이 카드를 첫 마커 앞으로 옮기는 것과 같은 결(firstGroupStartInRegion 공유).
    //    tabs/surface_ptrs를 **같은 인덱스**에 insert해 병렬 배열 정합을 유지하고 active_tab을 그 인덱스로. 그룹 전무면
    //    firstGroupStartInRegion=null → 끝(=기존 동작 보존). ensureUnusedCapacity를 위에서 예약했으므로 insert는 realloc/실패 없음.
    //    **핀 리전(§12 GP1)**: 새 탭은 비고정(Tab 기본 pinned=false)이라 **비고정 리전** [pinned_count, len)의 첫 마커
    //    앞에 넣는다 — 고정 프리픽스를 침범하지 않는다. 고정 그룹 0개면 모든 마커가 비고정 리전이라 리전 앵커=전역 앵커.
    tab.panes.appendAssumeCapacity(pane);
    tab.active_pane = 0;
    tab.tree = .{ .leaf = pane };
    const insert_at = self.firstGroupStartInRegion(tab_ops.countPinnedTabs(self), self.tabs.items.len) orelse self.tabs.items.len;
    self.tabs.insertAssumeCapacity(insert_at, tab);
    self.surface_ptrs.insertAssumeCapacity(insert_at, pane.activeTerm().surface);
    self.app_window.tabs = self.surface_ptrs.items; // items 슬라이스 길이 변경 — 새 items로 재바인딩
    self.app_window.active_tab = insert_at;
    // 4) 양쪽 resize(소스는 형제가 빈자리 확장, 새 탭은 단일 leaf 풀 영역) + 좌표/사이드바 갱신.
    resizeTabPanes(self, src_tab); // 비활성이라 best-effort
    resizeActiveTabPanes(self) catch {};
    recomputeActivePaneRect(self);
    self.metal_dirty = true;
    sidebar_ops.rebuildSidebar(self) catch {};
}

/// panel leaf 하나에서 tab bar, 실제 본문 외곽, terminal cell grid를 한 번만 투영한다. focus border는 body,
/// PTY resize·셀 렌더·hit-test·IME는 grid를 소비한다. bar/padding 판정이 accessor나 renderer에 복제되면 두 rect가
/// 서로 다른 frame을 가리킬 수 있으므로 이 함수가 기하 단일 출처다. 과대 padding은 zero-size grid의 origin까지
/// body 끝에 clamp해 IME/hit-test 좌표가 pane 밖으로 탈출하지 않게 한다.
pub fn paneGeometry(self: *const AppSession, rect: maru.session.SplitRect) PaneGeometry {
    const bar_h = paneBarHeightPx(self);
    const pad = self.window_padding_px;
    const has_bar = bar_h > 0 and rect.h > bar_h;
    const bar: ?maru.session.SplitRect = if (has_bar)
        .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = bar_h }
    else
        null;
    const body: maru.session.SplitRect = if (has_bar)
        .{ .x = rect.x, .y = rect.y + bar_h, .w = rect.w, .h = rect.h - bar_h }
    else
        rect;
    const grid = layout_math.insetRect(body, pad);
    return .{ .bar = bar, .body = body, .grid = grid };
}

/// §7 **종료 placeholder**(묘비)를 만든다 — manifest엔 있었지만 host runtime이 영구히 없어 읽기 전용으로 복원하는
/// Term이다. `createWebTerm`과 같은 "PTY 없는 registry 슬롯" 패턴(web arm sentinel + 제자리 `Surface.init`)을 쓰되
/// 두 곳이 다르다: (1) `kind`는 **`.terminal` 그대로**라 기존 렌더·라벨 경로가 무변경으로 화면을 그린다,
/// (2) core를 1×1이 아니라 **저장 grid로 연다** — sentinel 1×1에 텍스트를 쓰면 한 칸만 보이고, 그 크기가 다음
/// checkpoint에 저장돼 복원마다 2×1로 열화된다(`clampGridSize`가 cols를 2로 올린다).
///
/// 마지막 알려진 값은 **이미 owned 저장소가 있는 곳**에 심어 capture 코드를 건드리지 않는다.
/// - title → `auto_title`: `syncAutoTitles`가 `!live_initialized`로 건너뛰어 덮이지 않고 `termLabel`이 라벨로 쓴다.
/// - cwd·size → `observation`(`.stale`): `refreshTermObservation`이 `!live_initialized`로 즉시 반환하므로 보존되고,
///   `captureWorkspaceTab`이 `availability != .unavailable`일 때만 읽으므로 `.stale`이어야 저장된다.
/// - command → `rt.ended_command`.
/// `surface.title`/`surface.cwd`에는 **절대 넣지 않는다** — `Surface.title`은 borrowed 계약이고 복원 입력은 파싱
/// arena 소유라 apply 직후 해제되어 댕글링이 된다.
pub fn createEndedPlaceholderTerm(
    self: *AppSession,
    title: []const u8,
    cwd: []const u8,
    command: []const u8,
    size: terminal.Size,
    runtime_host_id: []const u8,
    runtime_id: []const u8,
) !*Term {
    const term = try self.allocator.create(Term);
    errdefer self.allocator.destroy(term);
    term.* = .{}; // kind=.terminal 기본값 유지(SurfaceKind는 닫힌 열거 — 확장하지 않는다)
    term.rt.ended_placeholder = true;

    const id = self.surface_ids.next();
    const slot = try self.live_registry.create(id, 0);
    slot.* = .{ .web = .{ .internal_allocator = self.allocator } }; // PTY 없는 arm 재사용(경량 teardown)
    term.surface = &slot.web.surface;
    errdefer self.live_registry.removeUninitialized(id) catch {};
    term.surface.* = try maru.session.Surface.init(self.allocator, id, terminal.clampGridSize(size));
    errdefer self.live_registry.remove(id) catch {};
    // 아래 metadata는 Term-owned다. 중간 OOM에서도 registry뿐 아니라 이미 복사한 문자열을 모두 되돌린다.
    errdefer {
        term.auto_title.deinit(self.allocator);
        term.rt.observation.deinit(self.allocator);
        if (term.rt.ended_command.len > 0) self.allocator.free(term.rt.ended_command);
        if (term.rt.ended_runtime_host_id.len > 0) self.allocator.free(term.rt.ended_runtime_host_id);
        if (term.rt.ended_runtime_id.len > 0) self.allocator.free(term.rt.ended_runtime_id);
    }

    // createTerm과 같은 core 정책 chokepoint — 안내 텍스트가 사용자 테마·폭 규칙으로 보이게 한다.
    term.surface.core.setConfigPalette(self.appearance.theme.palette);
    term.surface.core.ambiguous_wide = self.loaded_config.config.ambiguous_width == .wide;
    term.surface.core.emoji_wide = self.loaded_config.config.emoji_width == .wide;
    term.surface.core.setDefaultCursorShape(settings_ops.configCursorShape(self));
    // 읽기 전용. 정확히는 이 surface가 `SurfaceRuntime`에 **attach되지 않으므로**(link 없음 — PTY도 backend 슬롯도
    // 없다) writeInput·enqueueCoreCommand·resize는 process_state 가드에 닿기 전에 `UnknownSurface`로 먼저 실패한다
    // (runtime.zig의 `linkBySurface orelse return error.UnknownSurface`). `process_state = .exited`를 함께 세우는 것은
    // 화면·라벨·capture가 "종료된 Term"과 같은 상태를 읽게 하기 위해서다(attach된 로컬 종료 Term과 동일 표현).
    // 결과적으로 선택·스크롤 같은 core command는 묘비에서 no-op인데, 이는 **종료된 로컬 터미널과 같은 기존 동작**이다
    // (그쪽도 `process_state == .exited`라 `ProcessExited`로 거부된다) — 묘비만의 회귀가 아니다. 화면 안내는 core에
    // 직접 쓰고(writeSurfaceGuidance), 레이아웃 resize도 core를 직접 만진다(resizeTermForLayout).
    term.surface.process_state = .exited;
    if (title.len > 0) try term.auto_title.appendSlice(self.allocator, title);
    try term.rt.observation.replace(self.allocator, .{
        .availability = .stale, // "마지막으로 알려진 값" — unavailable이면 capture가 title/cwd를 빈 문자열로 쓴다
        .size = terminal.clampGridSize(size),
        .cwd = cwd,
        .window_title = title,
    });
    term.rt.ended_command = try self.allocator.dupe(u8, command);
    term.rt.ended_runtime_host_id = try self.allocator.dupe(u8, runtime_host_id);
    term.rt.ended_runtime_id = try self.allocator.dupe(u8, runtime_id);
    return term;
}

/// pointer down이 divider 밴드에서 시작했으면 capture를 잡는다. 잡았으면 true.
pub fn beginDividerCapture(self: *AppSession, x_px: f64, y_px: f64) bool {
    const tree_snapshot = publishDividerTree(self) orelse return false;
    if (tree_snapshot.entries.len == 0) return false;
    const dispatched = chrome.ui.interaction.dispatch(&self.divider_interaction, tree_snapshot, .{
        .phase = .down,
        .x_px = x_px,
        .y_px = y_px,
        .timestamp_ns = 0,
        .generation = tree_snapshot.generation,
    }) catch return false;
    _ = dispatched;

    const capture = self.divider_interaction.capture orelse return false;
    const index = chrome.components.divider.segIndexOf(capture.id, self.divider_seg_scratch.items.len) orelse {
        endDividerCapture(self);
        return false;
    };
    // ratio의 분모가 되는 bounds는 down 시점 값을 쓴다 — drag 도중 선이 움직여도 나누는 부모
    // 영역은 그대로이고, 매 move의 재발행에서 다시 읽으면 반올림이 누적될 자리가 생긴다.
    // 옛 경로는 `beginPointerGesture`가 앞선 gesture를 취소했다. 축이 갈렸어도 그 규율은 같다.
    sidebar_ops.clearSidebarDragPreview(self);
    self.pointer_gesture_owner = .none;
    self.divider_capture_seg = self.divider_seg_scratch.items[index];
    self.divider_capture_split = self.divider_split_scratch.items[index];
    self.divider_coalescer.reset();
    self.metal_dirty = true;
    return true;
}

/// 복원 surface 하나로 spawn 준비(createPane/createTerm 공통). new_tab_config에 저장 grid를 얹고, 사용 가능한
/// (존재하는 디렉터리) cwd면 그걸 쓴다 — 마지막 create 호출만 두 함수가 다르다. 모델의 command(argv[0])·title은
/// v1 복원에선 쓰지 않는다(기본 셸·"Maru"로 spawn; 정확한 argv·제목 복원은 후속) — 저장은 향후 복원용으로만.
pub fn restoreSpawn(self: *AppSession, sm: maru.session.workspace.Surface) struct { req: maru.pty.SpawnRequest, size: terminal.Size } {
    // P3-e3-5: host-backed surface의 identity 쌍을 곧 부를 createTerm에 동기 전달한다. 두 slice는 parse arena
    // 소유지만 createTerm이 즉시 비교/memcpy하고 비우므로 수명은 충분하다. host 없는 runtime_id는 legacy migration.
    self.restore_runtime_host_id = sm.runtime_host_id;
    self.restore_runtime_id = sm.runtime_id;
    var cfg = self.new_tab_config;
    const size = restoreSurfaceSize(sm);
    cfg.size = size;
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.shellIntegrationZdotdir(), self.new_tab_ssh_bin);
    if (usableRestoreCwd(sm.cwd)) |c| req.cwd = c; // 존재하는 디렉터리면 거기서, 아니면 기본 cwd(surface 안 잃음)
    return .{ .req = req, .size = size };
}

/// 활성 pane에 새 **web Term**(`panel_kind`=markdown|browser)을 띄우고 그 탭으로 포커스한다(command
/// `new_web_tab`·File 메뉴 — 4e-5, 그리고 debug 훅 maybeDebugOpenWebPanel의 위임 대상). `newTermInActivePane`을
/// 미러링하되 PTY spawn/셸 없이 `createWebTerm(panel_kind)`로 sentinel surface를 만든다(WKWebView는
/// computeWebSurfaceTransitions가 walk해 Swift가 붙인다, §6). create→append→focus 3단계 + append 실패 errdefer
/// 롤백이 web Term 생성의 **단일 출처**다(debug 훅이 이 시퀀스를 재구현하지 않게).
pub fn appendWebTermInActivePane(self: *AppSession, panel_kind: web_panel_layout.PanelKind) !u64 {
    const pane = activePane(self);
    const term = try web_ops.createWebTerm(self, panel_kind);
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    self.focusTerm(pane.terms.items.len - 1); // web Term으로 포커스(surface 재바인딩·활성 web은 렌더 skip, 4e-2)
    self.metal_dirty = true; // focusTerm도 세우지만 명시(탭바에 web Term 탭 추가 + 활성 전환 재그림)
    return term.surfaceId();
}

// 이 테스트가 증명하는 것: `appendPaneTabTitles`가 제목 문자열의 **소유 복사본**을 batch에 넣는다는 것.
//
// 왜 터미널에서 중요한가 — pane 루프는 pane마다 제목 버퍼(`titles`)를 만들고 그 반복이 끝나면 해제한다.
// 실제 셰이핑·발행은 루프가 끝난 뒤 `flushPaneTabTitles`가 **한 번에** 하므로, batch가 원본을 참조만 하면
// 발행 시점에는 이미 죽은 메모리를 읽는다. 이 batch 구조 자체가 "다중 pane에서 탭 제목이 사라지던" 회귀
// (단일 슬롯 캐시를 pane마다 store해 앞 pane의 아티팩트가 해제되던 것)를 고치며 세운 것이라, 복사 계약이
// 무너지면 같은 증상이 다른 원인으로 되돌아온다. testing allocator가 누수·이중 해제도 함께 잡는다.
test "탭 제목 batch는 원본이 해제돼도 유효한 소유 복사본을 든다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 탭 바 기하는 셀 크기에서 나온다 — 헤드리스 init은 렌더 상태를 세우지 않으므로 여기서 준다.
    session.cell_width_px = 8;
    session.cell_height_px = 16;

    const leaf = activePane(session);
    // 바 기하는 **직접** 준다. 헤드리스 init에는 창 크기가 없어 `paneBar`가 null을 내는데, 이 테스트가 고정하려는
    // 것은 레이아웃이 아니라 문자열 수명이므로 실제 창에 의존하지 않는 편이 낫다(그래야 SKIP으로 조용히 죽지 않는다).
    const pb: PaneBar = .{
        .full = .{ .x = 0, .y = 0, .w = 800, .h = 40 },
        .tabs = .{ .x = 0, .y = 0, .w = 800, .h = 40 },
        .label_cols = 0,
        .grip_cols = 0,
    };

    var batch: TabTitleBatch = .{};
    defer batch.deinit(allocator);

    // pane 루프가 만드는 것과 **같은 수명**의 임시 제목 버퍼: append가 끝나면 그 반복과 함께 사라진다.
    {
        const transient = try allocator.dupe(u8, "세션호스트");
        defer allocator.free(transient);
        const titles = [_][]const u8{transient};
        appendPaneTabTitles(session, &batch, leaf, pb, &titles, null, pb.full);
    }

    try std.testing.expectEqual(@as(usize, 1), batch.entries.items.len);
    try std.testing.expectEqualStrings("세션호스트", batch.entries.items[0].text);
}
