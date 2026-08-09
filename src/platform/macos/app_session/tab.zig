//! 탭(tab) — 생성·닫기·전환·이동·고정·그룹, 탭 제목과 실행 표시, 탭 단위 표면 집계.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F6).
//!
//! 두 종류가 섞여 있다. 하나는 `*AppSession` 메서드(탭 목록을 수술하고 사이드바·pane·표면을 함께
//! 갱신한다), 다른 하나는 `*Tab` 하나만 보는 순수 판정(`tabAgentKind`·`tabSurfaceCount`·
//! `tabTitleBody` 등 10개)이다. 후자는 `AppSession`을 받지 않으므로 free 함수 전환도 필요 없었다.
//!
//! 경계를 잡을 때 이름 함정을 걸렀다 — `tab`이 `stable`·`established`·`editable`·`executable`의
//! 부분 문자열이라 `stablePartitionPinned`·`webContextIsEditable` 등 6개가 단순 부분 일치로 딸려온다.
//! 단어 경계로 걸러 제외했다(F4의 `pane`↔`filePanel`과 같은 유형이다).
//!
//! 반대로 호출 관계로만 딸려오는 `projectRowsFrom`(사이드바 행 투영)·`setHoveredScroll`(스크롤 hover)은
//! 유일한 호출자가 탭 함수일 뿐 내용은 각각 F7·F8 소유라 여기 두지 않았다. 지금 옮기면 다음 그룹에서
//! 도로 옮겨야 하고, 남겨서 치르는 값은 pub화 1개뿐이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const scroll_ops = @import("scroll.zig");
const sidebar_ops = @import("sidebar.zig");
const Tab = app_session_mod.Tab;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const app = app_session_mod.app;
const commandName = app_session_mod.commandName;
const adjustActiveForMove = app_session_mod.adjustActiveForMove;
const is_macos = app_session_mod.is_macos;
const spawnRequest = app_session_mod.spawnRequest;
const termLabel = app_session_mod.termLabel;
const Model = app_session_mod.Model;
const PanePlacement = AppSession.PanePlacement;
const ScrollRef = app_session_mod.ScrollRef;
const agentStatePriority = AppSession.agentStatePriority;
const barMetrics = app_session_mod.barMetrics;
const layout_math = app_session_mod.layout_math;
const max_group_nesting = app_session_mod.max_group_nesting;
const plausibleSurfaceSize = app_session_mod.plausibleSurfaceSize;
const rotateMove = app_session_mod.rotateMove;
const sentinelBgCell = app_session_mod.sentinelBgCell;
const tabRefEql = app_session_mod.tabRefEql;
const AgentKind = app_session_mod.AgentKind;
const AgentRepresentative = AppSession.AgentRepresentative;
const BarHover = AppSession.BarHover;
const GroupCreateKind = AppSession.GroupCreateKind;
const Pane = app_session_mod.Pane;
const PaneTree = app_session_mod.PaneTree;
const TabRef = app_session_mod.TabRef;
const Term = app_session_mod.Term;
const addr_nav_url_cap = app_session_mod.addr_nav_url_cap;
const agentFlagUtf8 = AppSession.agentFlagUtf8;
const assertPinnedPrefixRuntime = AppSession.assertPinnedPrefixRuntime;
const blendRgb = app_session_mod.blendRgb;
const clampMoveToGroup = app_session_mod.clampMoveToGroup;
const dock_ops = @import("dock.zig");
const metal_frame = app_session_mod.metal_frame;
const pane_ops = @import("pane.zig");
const renderer = app_session_mod.renderer;
const reselectAfterClose = app_session_mod.reselectAfterClose;
const workspaceLabel = app_session_mod.workspaceLabel;

/// 현재 활성 탭(`*Tab`). live_pty/pump 등 탭 내부에 접근할 때 쓴다. `app_window.active_tab`을
/// 인덱스로 쓰므로 surface 라우팅(activeSurface)과 같은 활성 탭을 본다. 호출자는 탭이 있을 때만
/// 부른다(surface_initialized·tabs 비어있지 않음).
pub fn activeTab(self: *AppSession) *Tab {
    return self.tabs.items[self.app_window.active_tab];
}

/// 활성 탭의 SplitTree를 터미널 영역 rect 안에서 각 panel(leaf)의 (surface, rect)로 편다(멀티-panel
/// 렌더용 — 각 surface를 자기 rect에 그린다). 단일 leaf면 [{활성 surface, term_rect}] 하나; split 이후
/// 여러 rect가 된다. term_rect는 사이드바를 뺀 터미널 영역(렌더가 termRect로 계산해 넘김).
pub fn activeTabLeafRects(
    self: *AppSession,
    allocator: std.mem.Allocator,
    term_rect: maru.session.SplitRect,
    out: *std.ArrayList(PaneTree.LeafRect),
) !void {
    try PaneTree.layout(allocator, activeTab(self).tree, term_rect, out);
}

/// minimal(chrome 없는 quick terminal) 세션에서 탭이 여러 개일 때 **우상단에 작은 "탭 점" 인디케이터**를 overlay
/// 셀로 append한다 — 사이드바·pane 탭 바가 숨겨져 안 보이는 탭을 글랜서블하게 보여준다. 적응형: 워크스페이스가
/// 여러 개면 워크스페이스(⌘1..9)를, 아니면 활성 pane의 Term(⌘])을 점으로 — 한 줄로 가장 관련 있는 차원만.
/// 점 = sentinel-bg 셀: strip(sidebarBg) 위에 활성=sidebarActiveBg(밝게)·나머지=sidebarHoverBg(중간 톤).
/// chrome_minimal이 아니거나(full은 사이드바/탭 바가 이미 보여줌) 단일(탭 1개)이면 무동작.
pub fn appendMinimalTabIndicator(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
    if (!self.chrome_minimal) return;
    const cw = self.cell_width_px;
    if (cw == 0) return;

    // 적응형 차원: 워크스페이스 우선(여러 개면 그쪽), 아니면 활성 pane의 Term. 둘 다 1개면 표시 안 함.
    const pane = pane_ops.activePane(self);
    var count: u32 = undefined;
    var active: u32 = undefined;
    if (self.tabs.items.len > 1) {
        count = @intCast(self.tabs.items.len);
        active = @intCast(self.app_window.active_tab);
    } else if (pane.terms.items.len > 1) {
        count = @intCast(pane.terms.items.len);
        active = @intCast(pane.active_term);
    } else return;

    // 화면 폭(셀 칸). minimal이라 사이드바 없음. paneTermRect가 window padding을 inset하므로(minimal은 바 없음)
    // 점 인디케이터도 셀 그리드와 같은 padding 안쪽에 정렬된다. 칸 0이면 안 그림.
    const term_rect = pane_ops.paneTermRect(self, self.termRect());
    const cols = term_rect.w / cw;
    if (cols == 0) return;

    // 레이아웃(칸): strip 좌우 1칸 패딩 + 점 1칸 + 점 사이 간격 1칸 → band 폭 = 2*count+1, 점은 band-local 1,3,5...
    const pad: u32 = 1;
    const band_width: u32 = 2 * count + 1;
    const right_margin: u32 = 1;
    // band가 우상단에 안 들어가면(극단적 탭 수 + 좁은 패널) 아예 안 그린다 — 안 그러면 band_start가 0으로
    // saturate돼 좌상단에 전체 폭으로 그려져(우상단 의도와 반대) 터미널을 덮는다.
    if (band_width + right_margin > cols) return;
    // 우상단 정렬(band_width+right_margin <= cols라 saturate 없이 정확히 우측에 붙는다).
    const band_start: u32 = cols - band_width - right_margin;

    const u16_max: u32 = std.math.maxInt(u16);
    // strip 배경(넓은 sentinel 셀 1개) → 그 위에 점들(append 순서 = painter 순서라 점이 strip 위에 그려진다).
    out.append(self.allocator, sentinelBgCell(
        @intCast(@min(band_start, u16_max)),
        @intCast(@min(band_width, u16_max)),
        self.chromeCellBg(sidebar_ops.sidebarBg(self)), // window.opacity(셀 premultiply)
        term_rect.x,
        term_rect.y,
    )) catch return;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const col = band_start + pad + i * 2;
        const color = self.chromeCellBg(if (i == active) sidebar_ops.sidebarActiveBg(self) else sidebar_ops.sidebarHoverBg(self)); // window.opacity(셀 premultiply)
        out.append(self.allocator, sentinelBgCell(@intCast(@min(col, u16_max)), 1, color, term_rect.x, term_rect.y)) catch return;
    }
}

/// CIM4b(§4.4): 탭 드래그 시작 순서를 transaction 버퍼에 보관한다. 실패(OOM)하면 false — 호출자는 드래그를
/// arm하지 않는다(preview 없이 드래그를 시작하면 재정렬이 조용히 무동작이 되므로 fail-close).
pub fn beginTabDragOrder(self: *AppSession, pane: *Pane, index: usize) bool {
    if (index >= pane.terms.items.len) return false;
    self.tab_drag_start.clearRetainingCapacity();
    self.tab_drag_preview.clearRetainingCapacity();
    self.tab_drag_order.clearRetainingCapacity();
    // 세 버퍼의 용량을 **여기서 한 번에** 확보한다 — 이후 드래그 동안 길이가 늘지 않으므로 `syncTabDragOrder`는
    // 실패할 수 없고, 실패 처리를 뒤로 끌고 다니지 않아도 된다(그 폴백은 뷰만 비워 preview와 어긋난 상태를
    // 만들었다: paint는 model, commit은 회전된 preview).
    self.tab_drag_start.ensureTotalCapacity(self.allocator, pane.terms.items.len) catch return false;
    self.tab_drag_preview.ensureTotalCapacity(self.allocator, pane.terms.items.len) catch return false;
    self.tab_drag_order.ensureTotalCapacity(self.allocator, pane.terms.items.len) catch return false;
    for (pane.terms.items) |t| {
        self.tab_drag_start.appendAssumeCapacity(@intFromPtr(t));
        self.tab_drag_preview.appendAssumeCapacity(@intFromPtr(t));
    }
    syncTabDragOrder(self);
    return true;
}

/// preview(identity)에서 `*Term` 뷰를 다시 만든다. paint·hit-test가 이 뷰 하나만 읽으므로 preview를 바꾼
/// 모든 자리가 이것을 뒤따라 불러야 한다. 용량은 `beginTabDragOrder`가 이미 확보했다(길이 불변).
pub fn syncTabDragOrder(self: *AppSession) void {
    self.tab_drag_order.clearRetainingCapacity();
    for (self.tab_drag_preview.items) |id| self.tab_drag_order.appendAssumeCapacity(@ptrFromInt(id));
}

/// 해제되려는 Term이 지금 드래그의 preview에 실려 있으면 제스처를 통째로 끝낸다(§4.4 "집합이 바뀌면
/// provisional 배열을 폐기한다"). preview는 해제된 뒤에도 남을 수 있는 유일한 `*Term` 캐시다.
/// **teardown 중이라 저수준 `clearPointerGesture`를 쓴다** — 그 Term은 곧 해제되고 `pane.terms`는 아직
/// 그것을 담고 있어, 스크롤 정정이 레이아웃을 다시 재는 것이 이 시점에 안전한 일이 아니다. 정정은 이
/// pane이 살아남았다면 다음 `focusTerm`이 한다.
pub fn cancelTabDragForTerm(self: *AppSession, term: *Term) void {
    if (!self.pointerGestureIs(.terminal_tab)) return;
    const id = @intFromPtr(term);
    for (self.tab_drag_preview.items) |item| {
        if (item != id) continue;
        self.clearPointerGesture();
        return;
    }
}

/// 드래그 중 pane의 Term 집합이 밖에서 바뀌었는가(추가·제거·교체). §4.4는 그 경우 provisional 배열을
/// 재봉합하지 않고 **폐기**하라고 정한다 — 폐기하지 않으면 `tabDragTransaction`이 영구히 null을 돌려줘
/// 나머지 드래그가 조용한 무동작이 되고, floating 고스트만 커서를 계속 따라다닌다.
pub fn tabDragSetChanged(self: *const AppSession) bool {
    if (!self.pointerGestureIs(.terminal_tab)) return false;
    const pane = self.pointer_gesture_owner.terminal_tab.pane;
    if (self.tab_drag_preview.items.len != pane.terms.items.len) return true;
    for (pane.terms.items) |t| {
        const id = @intFromPtr(t);
        if (std.mem.indexOfScalar(u64, self.tab_drag_preview.items, id) == null) return true;
    }
    return false;
}

/// 지금 이 pane에 유효한 transaction. 집합이 어긋나면 null인데, 그 상태로 드래그를 끌고 가지 않도록
/// `tick`이 매 프레임 `tabDragSetChanged`로 폐기한다.
/// clamp는 주입하지 않는다: pin 그룹은 워크스페이스(`self.tabs`) 축 전용이고 `pane.terms`에는 없으며,
/// 목적지 범위 clamp는 `Metrics.tabIndex`가 이미 [0,len)으로 한다.
pub fn tabDragTransaction(self: *AppSession, pane: *Pane) ?chrome.ui.provisional_order.Transaction {
    if (!self.pointerGestureIs(.terminal_tab)) return null;
    const drag = self.pointer_gesture_owner.terminal_tab;
    if (drag.pane != pane) return null;
    if (drag.index >= pane.terms.items.len) return null;
    if (self.tab_drag_start.items.len != pane.terms.items.len) return null;
    if (self.tab_drag_preview.items.len != pane.terms.items.len) return null;
    return .{
        .start = self.tab_drag_start.items,
        .preview = self.tab_drag_preview.items,
        .source = @intFromPtr(pane.terms.items[drag.index]),
    };
}

/// 드래그 중인 Term 탭을 현재 마우스 x에 따라 소스 pane 바 안에서 재정렬한다(PR-E1: pane 내). 소스 pane의
/// 바를 찾아 x→타겟 탭(tabIndexInBar, x clamp)을 잡고 **preview만** 회전한다 — model(`pane.terms`·
/// `active_term`)은 up까지 그대로다(§4.4 provisional live reorder). 보이는 순서가 따라가는 것은 paint·
/// hit-test가 `paneTermOrder`/`paneActiveTermIndex`로 preview를 읽기 때문이다. `drag.index`는 **시작 model
/// 인덱스로 고정**한다 — dropTabAt(moveTermToPane·moveTermToNewSplit)과 floating 미리보기 라벨이 그 해석을
/// 쓴다. 탭 1개거나 소스 pane을 못 찾으면(레이아웃 실패) 무동작. mouse가 drag(kind 2)에서 호출.
pub fn dragTabTo(self: *AppSession, x_px: f64) void {
    const drag = switch (self.pointer_gesture_owner) {
        .terminal_tab => |drag| drag,
        else => return,
    };
    const pane = drag.pane;
    if (pane.terms.items.len <= 1) return;
    var txn = tabDragTransaction(self, pane) orelse return;
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        if (lr.leaf != pane) continue;
        const pb = pane_ops.paneBar(self, lr.rect, pane) orelse return;
        const m = barMetrics(pb.tabs, self.cell_width_px, pane.terms.items.len, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return;
        const target = m.tabIndex(pane.terms.items.len, x_px);
        const before = txn.destination();
        txn.moveTo(target);
        if (txn.destination() != before) {
            syncTabDragOrder(self);
            self.metal_dirty = true;
        }
        return;
    }
}

/// up에서 preview를 model에 한 번 반영한다(§4.4 "up에서만 commit"). destination은 **up 좌표를 다시
/// hit-test한 결과**(`up_slot`)이며 preview가 마지막에 멈춘 자리가 아니다 — 계약 §5가 그 좌표를 commit의
/// 권위로 정한다. 결과가 시작 자리와 같으면 effect 0(model도 active_term도 안 건드린다). 같은 pane 안
/// 재정렬 전용이며, 다른 pane으로의 이동/split은 preview를 버리고(=시작 순서 유지) moveTermToPane·
/// moveTermToNewSplit이 model 인덱스로 처리한다.
pub fn commitTabDragOrder(self: *AppSession, pane: *Pane, up_slot: usize) void {
    var txn = tabDragTransaction(self, pane) orelse return;
    txn.moveTo(up_slot); // up 좌표가 최종 권위 — 마지막 move와 다르면 그쪽으로 맞춘다
    const drag = self.pointer_gesture_owner.terminal_tab;
    // 권위 있는 판정은 이 하나뿐이다: 끌던 항목이 시작 자리와 다른 자리에 있는가. `txn.changed()`는
    // 여기서 같은 말이고(`moveTo`는 source 하나만 회전한다), `destination()`은 구성상 null이 될 수 없다 —
    // 셋을 늘어놓으면 어느 것이 권위인지 읽는 사람이 매번 증명해야 한다.
    const to = txn.destination() orelse return;
    if (to == drag.index) return; // effect 0 — model도 active_term도 안 건드린다
    rotateMove(*Term, pane.terms.items, drag.index, to);
    pane.active_term = adjustActiveForMove(pane.active_term, drag.index, to);
    self.metal_dirty = true;
}

/// 탭 드래그 up(drop) 시 마우스가 '소스가 아닌 다른 pane'의 바 위면 그 pane으로 Term을 옮긴다(cross-pane,
/// PR-E2). **같은 pane의 바 위면 preview를 model에 commit한다**(§4.4 — up이 유일한 commit 지점). 어느 바도
/// 아니고 drop-zone도 아니면 commit 없이 끝나 시작 순서가 남는다(§4.4 "유효한 destination을 못 짚으면
/// commit 없이 시작 순서 복원" — model을 안 건드렸으므로 복원은 아무 일도 안 하는 것과 같다). 드롭 위치
/// (x)로 dst 안 삽입 인덱스를 잡는다. mouse가 up(kind 3)에서 호출.
pub fn dropTabAt(self: *AppSession, x_px: f64, y_px: f64) void {
    const drag = switch (self.pointer_gesture_owner) {
        .terminal_tab => |drag| drag,
        else => return,
    };
    const src = drag.pane;
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        const pb = pane_ops.paneBar(self, lr.rect, lr.leaf) orelse continue;
        if (layout_math.pointInRect(x_px, y_px, pb.full)) { // 클릭 판정은 전체 바(라벨 포함)
            const dst_count = lr.leaf.terms.items.len; // dst pane은 항상 Term ≥1(빈 pane은 collapse됨)
            const m = barMetrics(pb.tabs, self.cell_width_px, dst_count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return;
            if (lr.leaf == src) { // 같은 pane — 여기가 preview의 유일한 commit 지점(§4.4)
                // destination의 권위는 **up 좌표의 재hit-test**다(§5) — 마지막 move가 남긴 preview 자리가
                // 아니다. 둘은 갈릴 수 있다: 마지막 move가 tick coalescing에 먹힌 뒤 다른 x에서 떼거나,
                // ‹/›/+ zone 위에서 떼면 preview는 그 좌표를 한 번도 본 적이 없다.
                commitTabDragOrder(self, src, m.tabIndex(dst_count, x_px));
                return;
            }
            pane_ops.moveTermToPane(self, src, drag.index, lr.leaf, m.tabIndex(dst_count, x_px));
            return;
        }
    }
    // 바가 아니면 어느 pane '본문' drop-zone(상/하/좌/우 절반) 위인지 — 그 방향으로 새 split을 만든다(④:
    // Term을 다른 pane 본문에 떨어뜨려 재배치). 단일 Term pane을 자기 본문에 떨어뜨리면 무의미라 무동작.
    for (leaf_rects.items) |lr| {
        const body = pane_ops.paneTermRect(self, lr.rect);
        if (layout_math.paneDropZone(body, x_px, y_px)) |zone| {
            pane_ops.moveTermToNewSplit(self, src, drag.index, lr.leaf, zone);
            return;
        }
    }
}

/// 탭 드래그 중이면 끌리는 Term의 제목을 담은 'floating 탭'(박스 + 제목) frame을 만들어 PaneFrame으로 돌려준다
/// (커서 중심에 배치). built_frames가 소유(deinit)하고, 반환 PaneFrame은 호출자가 pane_frames '맨 뒤'(맨 위)에
/// 넣는다. 드래그 중이 아니거나 메트릭/제목을 못 구하면 null. macOS 렌더 패스(CoreText)에서만 부른다.
/// floating 탭 미리보기의 DrawList + 배치(드래그 중이 아니면 null). 멀티 페인 통합(collect)·단발
/// (buildFloatingTabFrame)이 공유한다 — 같은 DrawList/배치 계산 단일 출처.
pub fn buildFloatingTabDrawListAndPlacement(self: *AppSession) ?struct { dl: renderer.DrawList, placement: PanePlacement } {
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0) return null;
    // tab(Term 1개) 또는 pane(분할 영역 통째) 드래그 중 끌리는 대상의 라벨·커서 좌표를 고른다(둘은 상호배타).
    var title: []const u8 = undefined;
    var drag_x: f64 = undefined;
    var drag_y: f64 = undefined;
    switch (self.pointer_gesture_owner) {
        .terminal_tab => |drag| {
            const pane = drag.pane;
            if (drag.index >= pane.terms.items.len) return null;
            // 드래그 미리보기 라벨도 탭과 같은 해석(rename custom_name 우선). 탭바와 floating 미리보기가 어긋나지 않게.
            title = termLabel(pane.terms.items[drag.index]);
            drag_x = drag.x;
            drag_y = drag.y;
        },
        .pane => |drag| {
            const pane = drag.pane;
            // pane 미리보기 라벨: custom_name 우선, 없으면 활성 Term 라벨(grip만 있는 pane도 의미 있게).
            title = app.pickLabel(pane.custom_name, termLabel(pane.activeTerm()));
            drag_x = drag.x;
            drag_y = drag.y;
        },
        else => return null,
    }
    const cols: u16 = @intCast(std.math.clamp(title.len + 2, @as(usize, 8), @as(usize, 24))); // 제목+패딩, [8,24]
    const fg: terminal.Color = .{ .rgb = self.appearance.theme.foreground };
    const bg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_active }; // 솔리드 박스 색(활성 강조색)
    const dl = coretext_frame_builder.buildFloatingTabDrawList(self.allocator, title, cols, fg, bg) catch return null;
    // 커서 중심으로 박스 배치(왼쪽 위가 음수면 0으로 clamp).
    const box_w: f64 = @floatFromInt(@as(u32, cols) * cw);
    const ox = drag_x - box_w / 2;
    const oy = drag_y - @as(f64, @floatFromInt(ch)) / 2;
    return .{
        .dl = dl,
        .placement = .{
            .origin_x = if (ox > 0) @intFromFloat(@min(ox, @as(f64, @floatFromInt(std.math.maxInt(u32))))) else 0,
            .origin_y = if (oy > 0) @intFromFloat(@min(oy, @as(f64, @floatFromInt(std.math.maxInt(u32))))) else 0,
            .colors = .{ .default_fg = self.appearance.theme.foreground },
        },
    };
}

/// 새 탭을 만든다 — Tab과 첫 panel을 heap-pin하고, panel의 surface로 단일-leaf 트리를 세우고,
/// `tabs`/`surface_ptrs`에 추가하고 `app_window.tabs`를 갱신하고 새 탭을 활성으로 만든다. 새 Tab 포인터
/// 반환. 부분 실패는 errdefer로 정리한다(create tab→panes 리스트→pane→append 역순).
pub fn createTab(
    self: *AppSession,
    request: maru.pty.SpawnRequest,
    size: terminal.Size,
    queue_capacity: usize,
    title: []const u8,
    command: []const u8,
) !*Tab {
    const tab = try self.allocator.create(Tab);
    errdefer self.allocator.destroy(tab);
    tab.* = .{};
    errdefer tab.panes.deinit(self.allocator); // 실패 시 panes 리스트 backing 해제(pane은 아래 errdefer가)

    const pane = try pane_ops.createPane(self, request, size, queue_capacity, title, command);
    errdefer pane_ops.destroyPane(self, pane);

    try tab.panes.append(self.allocator, pane);
    tab.active_pane = 0;
    // SplitTree 루트를 단일 leaf로 — 이 탭은 panel 1개(= 풀 탭 영역). leaf는 Pane을 가리킨다(Pane이
    // heap-pin이라 포인터 안정). split이 이 leaf를 split 노드로 나눈다.
    tab.tree = .{ .leaf = pane };

    // **끝 append가 아니라 비고정 리전 첫 group_start 마커 직전**(= 그 리전 최상위 구간 끝)에 끼운다 — 리스트 끝 탭은
    // 그룹이 하나라도 있으면 마지막 그룹의 멤버로 위치 파생(§2.1)돼 **새 워크스페이스가 그룹에 흡수**된다(그러면 그 카드
    // 우클릭 pin이 cardPinRole=.local로 라우팅돼 그룹 안으로 float — 사용자엔 "최상위 카드가 그룹에 흡수"로 보인다).
    // promotePaneToNewWorkspace(3088)와 **같은 결·firstGroupStartInRegion 공유** — 새 탭은 비고정(Tab 기본 pinned=false)이라
    // 비고정 리전 [pinned_count, len)의 첫 마커 앞에 넣어 고정 프리픽스를 침범하지 않는다. 그룹 전무(init 첫 탭 포함)면
    // firstGroupStartInRegion=null → 끝(=기존 append 동작 byte-identical). 두 병렬 배열 capacity를 **먼저** 예약해
    // insert를 infallible로 만든다(둘 다 성공해야 삽입 — 예약 실패는 위 errdefer가 pane/tab을 무른다, 부분 삽입 없음).
    // **§2.1 재설계(§14) 정합**: 첫 마커 **앞**(그 리전 최상위 구간)에 끼우므로 새 탭은 위치 파생상 depth 0 최상위 카드다 —
    // 마커 뒤가 아니라 앞이라 top_level 세팅이 불필요하다(top_level은 "그룹 뒤/사이 최상위 복귀"용, 여기선 애초에 그룹 앞).
    // Tab 기본 top_level=false로 충분(버그1 수정으로 그룹 흡수를 삽입 위치로 이미 막음 — SR3 write 경로와 직교).
    try self.tabs.ensureUnusedCapacity(self.allocator, 1);
    try self.surface_ptrs.ensureUnusedCapacity(self.allocator, 1);
    const insert_at = self.firstGroupStartInRegion(countPinnedTabs(self), self.tabs.items.len) orelse self.tabs.items.len;
    // 여기부터는 infallible이고 active_tab이 새 surface로 바뀐다. 생성 실패 때 기존 조합을 불필요하게
    // 확정하지 않으면서도, 성공 시에는 입력 owner가 바뀌기 전에 원 surface의 marked text를 커밋한다.
    self.commitComposition();
    self.tabs.insertAssumeCapacity(insert_at, tab);
    self.surface_ptrs.insertAssumeCapacity(insert_at, pane.activeTerm().surface); // 탭 대표 = 활성 panel의 활성 Term surface
    // surface_ptrs가 realloc됐을 수 있으니 app_window.tabs를 새 items로 재바인딩(stale 슬라이스 방지).
    self.app_window.tabs = self.surface_ptrs.items;
    self.app_window.active_tab = insert_at;
    pane_ops.recomputeActivePaneRect(self); // 새 탭이 활성이 됐으니 좌표 origin 갱신(init 중엔 사이드바 폭이 아직
    // 0이라 init 끝의 recompute가 다시 잡고, post-init newTab은 여기서 바로 맞는다)
    // 탭 집합/활성이 바뀌었으니 사이드바 셀을 다시 만든다. 실패는 탭 생성을 무르지 않고(탭은 이미
    // 완성·append됨) 빈 사이드바로 degrade한다 — 여기서 try면 errdefer가 멀쩡한 탭을 헐어버린다.
    sidebar_ops.rebuildSidebar(self) catch {};
    return tab;
}

pub fn switchTab(self: *AppSession, index: usize) bool {
    const prev_tab = self.app_window.active_tab;
    if (index >= self.app_window.tabs.len) return false;
    if (index != prev_tab) self.commitComposition();
    if (!self.app_window.selectTab(index)) return false;
    // 실제 탭이 바뀔 때만 보류 닫기 무효화 — selectTab은 index<len이면 같은 탭 재선택에도 true를 돌려주므로
    // (window.zig), 알림 클릭이 이미 활성인 탭의 Term을 activateSurfaceById→switchTab(same)로 지날 때 유효한
    // 닫기 모달을 헛되이 취소하던 것 방지(code-review — focusPane/focusTerm은 자체 early-return이 no-op을 거른다).
    if (index != prev_tab) self.invalidatePositionalPendingClose();
    if (index != prev_tab) dock_ops.dropPendingDockFocusIfHidden(self);
    // 전환한 탭을 현재 창 grid로 맞춘다. resize()는 활성 탭만 만지고 last_resize_size는 세션-전역이라, 다른
    // 탭이 활성인 동안 창이 리사이즈됐거나 복원으로 저장 grid로 spawn된 탭은 전환 시점까지 stale grid다 —
    // 여기서 lazy 보정한다(복원·일반 둘 다). best-effort: 죽은 PTY 등은 무시(resizeTabPanes 계약).
    pane_ops.resizeTabPanes(self, activeTab(self));
    self.metal_dirty = true;
    pane_ops.recomputeActivePaneRect(self); // 새 탭의 활성 panel rect로 좌표 origin 갱신
    sidebar_ops.rebuildSidebar(self) catch {}; // 활성 탭이 바뀌었으니 하이라이트 밴드를 새 행으로 옮긴다
    return true;
}

pub fn tabHasRunningJob(tab: *Tab, io: std.Io) bool {
    for (tab.panes.items) |p| if (pane_ops.paneHasRunningJob(p, io)) return true;
    return false;
}

pub fn tabHasRunningAgent(tab: *Tab) bool {
    for (tab.panes.items) |p| if (pane_ops.paneHasRunningAgent(p)) return true;
    return false;
}

/// 워크스페이스 대표 상태. 사용자 조치가 필요한 blocked를 running보다 먼저, 그 뒤 idle/unknown 순으로 고른다.
/// 같은 우선순위면 활성 Term을 유지해 카드 라벨과 종류가 불필요하게 흔들리지 않는다.
pub fn tabAgentRepresentative(tab: *Tab) ?AgentRepresentative {
    var best: ?AgentRepresentative = if (tab.activeTerm().agent_kind != .none)
        .{ .term = tab.activeTerm(), .state = tab.activeTerm().agent_state }
    else
        null;
    for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.agent_kind == .none) continue;
        if (best == null or agentStatePriority(term.agent_state) > agentStatePriority(best.?.state))
            best = .{ .term = term, .state = term.agent_state };
    };
    return best;
}

/// 카드 아이콘·색의 대표 에이전트 종류는 대표 상태와 같은 Term에서 가져온다.
pub fn tabAgentKind(tab: *Tab) AgentKind {
    return if (tabAgentRepresentative(tab)) |representative| representative.term.agent_kind else .none;
}

pub fn tabHasWebBrowser(tab: *Tab) bool {
    for (tab.panes.items) |p| if (pane_ops.paneHasWebBrowser(p)) return true;
    return false;
}

/// 탭을 닫는다. 마지막 한 개면 창(세션)을 닫는다 — 탭을 헐지 않고 종료를 latch해 기존 terminate/
/// deinit 경로가 정리하게 한다(빈 tabs 리스트로 activeSurface가 패닉하는 걸 피한다). 그 외엔 teardown
/// (deinit과 같은 순서: closeAndDetach(runtime) → live_registry.remove(reader join·슬롯 해제, M2b) → surface.deinit
/// → Tab heap 해제) 후 tabs/surface_ptrs에서 빼고 app_window.tabs를 재바인딩하고 active_tab을 clamp한다
/// (reselectAfterClose). 범위 밖 index면 무동작.
pub fn closeTab(self: *AppSession, index: usize) void {
    if (index >= self.tabs.items.len) return;
    // sidebar tab/group payload는 index/marker를 mouse-down 시점에 고정한다. source close 뒤 late drag/up이
    // 당겨진 index의 다른 workspace를 움직이지 않도록 collection mutation보다 먼저 공용 gesture를 끊는다.
    self.cancelPointerGesture();
    if (self.tabs.items.len == 1) {
        // 마지막 탭 = 창 닫기. 종료 latch는 latchSessionClose 단일 출처(빨간 버튼 확인 경로와 공유) — 탭은 deinit이 정리.
        self.latchSessionClose();
        return;
    }

    // 사이드바 그룹 마커 승계(SG3c §2.1·§10) — 그룹 시작 탭이 닫히면 그 group_start 마커를 **다음 탭**으로 넘겨
    // 그룹이 안 사라지게 한다(그룹 첫 카드를 닫아도 나머지가 그룹에 남게). 승계 실패(다음 없음·이미 마커)면 승계
    // 없이 closing.group_start가 남아 아래 destroyTabStandalone이 free한다(그룹 소멸). inheritGroupMarker 공유(#11).
    _ = self.inheritGroupMarker(index);

    // §14 경계 유지(code-review finding #2): 닫는 카드가 **top_level 경계 홀더**면, 제거 후 그 뒤 sticky follower가 앞
    // 그룹에 흡수되지 않게 경계를 다음 카드에 재확립한다(togglePin·simulateDrop·commit과 동형 단일 출처 헬퍼). 제거는
    // 항상 일어나므로 반환값(재확립 여부)은 무시한다 — 제자리 revert가 필요 없다(그 처리는 no-op move 가능한 togglePin 몫).
    _ = self.reestablishTopLevelBoundaryOnMove(index);

    const tab = self.tabs.orderedRemove(index);
    _ = self.surface_ptrs.orderedRemove(index);
    // 길이가 줄었으니(realloc은 안 해도) app_window.tabs를 새 items로 재바인딩(stale 슬라이스 방지).
    self.app_window.tabs = self.surface_ptrs.items;

    // teardown — destroyTabStandalone가 모든 panel destroyPane(closeAndDetach → reader join → surface deinit
    // → free) + tree split 노드 해제 + panes/Tab 해제. tabs/surface_ptrs는 위에서 이미 뺐다(이 헬퍼는 컬렉션을
    // 안 건드림). applyWorkspaceWindow와 같은 teardown 단일 출처라 순서가 갈라지지 않는다.
    destroyTabStandalone(self, tab);

    self.app_window.active_tab = reselectAfterClose(index, self.app_window.active_tab, self.tabs.items.len);
    pane_ops.recomputeActivePaneRect(self); // 새 활성 탭의 활성 panel rect로 좌표 origin 갱신
    // 이 탭의 Pane/split 노드가 해제됐으니 stale 호버·divider 포인터를 비워야 하는데, 위 destroyTabStandalone의
    // destroyPane 루프가 invalidateForFreedPane(S1 chokepoint)으로 이미 처리했다(다음 이동이 재설정).
    // 그룹 고정 C2(§12.5 GP2): 위 inheritGroupMarker 마커 승계 뒤 멤버 pinned 캐시를 마커 기준으로 재동기(비프리뷰
    // 경로 — 탭 닫기라 드래그 게이트는 normalize 내부가 처리). 승계로 그룹 구성이 바뀌었을 수 있어 shred 방지.
    self.normalizePinnedFromGroups();
    self.floatLocalPinsAllGroups(); // 그룹-로컬 pin 재float(GL §13.4 배선 — normalize 뒤, 마커 승계로 subtree 재구성 반영)
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// src 트리에서 `index` 워크스페이스(탭)를 **destroy 없이** 떼어 `*Tab`을 반환한다(dst가 소유 승계) — closeTab tail과
/// 동형이되 `destroyTabStandalone`을 **생략**한다. 담긴 Term/surface/PTY는 heap-pin + 앱-전역 registry 소유라 그대로
/// 따라온다(이동이지 파괴가 아님). 잔존(src) 측은 closeTab처럼 재정규화·reselect·사이드바 재빌드한다. 마지막 워크스페이스를
/// 떼면(빈 source, §1.6) active-의존 refresh(reselectAfterClose new_len=0 underflow·recomputeActivePaneRect activePane
/// deref)를 **건너뛴다** — `ended_seen` latch는 caller가 cross-window로 실제 비었을 때만 세운다(same-window 이동은 곧
/// re-adopt해 src가 안 닫히므로 detach가 세우면 오탐; `latchSessionClose`도 activeSurface UB라 못 씀). index 범위 밖이면 null.
/// 이동으로 이 탭이 src 트리를 **떠날** 때, 이 탭(워크스페이스/그룹)·그 안 pane/Term/split을 가리키던 src의 UI-target
/// 포인터를 비운다 — closeTab의 destroyTabStandalone(+destroyPane→invalidateForFreedPane·destroyTerm)가 하던 stale
/// 정리를 **해제 없이** 미러한다(탭은 파괴가 아니라 dst로 이동하므로 메모리는 살아 있으나, src UI가 계속 참조하면 다른
/// 창 소유 탭을 조작하는 stale 포인터가 된다 — context_menu_target/rename/divider_drag/hover·drag; code-review [2]).
pub fn clearStaleUiTargetsForMovedTab(self: *AppSession, tab: *Tab, clear_pending_pastes: bool) void {
    // 워크스페이스/그룹 rename·context_menu (destroyTabStandalone 상단 미러 — 둘 다 *Tab을 든다).
    if (self.renamingWorkspace(tab) or self.renamingGroup(tab)) {
        self.rename = null;
        self.rename_input.clear();
    }
    if (self.context_menu_target) |t| {
        const hit = switch (t) {
            .workspace => |w| w == tab,
            .group => |g| g == tab,
            else => false,
        };
        if (hit) {
            self.context_menu_target = null;
            self.chrome_host.context_menu.hide();
        }
    }
    // pane/Term 수준 정리(destroyPane→invalidateForFreedPane + destroyTerm 미러 — 해제 없이 포인터 비교만).
    for (tab.panes.items) |pane| {
        pane_ops.invalidateForFreedPane(self, pane); // hovered_tab·tab_drag_pane·pane_drag_pane·rename(pane)·context_menu(pane)·hovered_slot
        for (pane.terms.items) |term| {
            if (self.renamingTerm(term)) {
                self.rename = null;
                self.rename_input.clear();
            }
            if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .term and t.term == term) {
                self.context_menu_target = null;
                self.chrome_host.context_menu.hide();
            };
            // 미전송 입력 큐도 회수한다(destroyTerm 미러). 안 하면 **옮겨간 surface의 큐가 이 창에 남아**,
            // 이 창의 tick이 계속 그 surface의 PTY로 잔여를 쓴다(runtime은 앱-전역이라 write가 성공한다).
            // 그 사이 새 창에서 같은 pane에 붙여넣으면 두 창의 바이트가 한 PTY에서 뒤섞여 bracketed paste
            // 괄호(ESC[200~ … ESC[201~)가 쪼개진다 — 셸이 이어붙은 명령을 실행할 수 있다(code-review).
            if (clear_pending_pastes) {
                if (self.pending_pastes.fetchRemove(term.surface.id)) |kv| {
                    var q = kv.value;
                    q.buf.deinit(self.allocator);
                }
            }
        }
    }
    // divider_drag가 이 탭 트리 소속 split이면 표적 null(무관한 탭 트리를 가리키면 유지 — destroyTabStandalone 동형).
    if (self.divider_capture_split) |captured| {
        if (PaneTree.containsSplit(tab.tree, captured)) pane_ops.endDividerCapture(self);
    }
}

/// `defer_rebuild`=true면 src 사이드바 재빌드를 caller가 배치(mergeSessionInto 끝 1회, code-review [4]) — merge의
/// 중간 detach마다 양-창 사이드바를 재빌드하던 O(K²)를 피한다. 단일 이동(moveWorkspaceToSession)은 false=즉시 재빌드.
pub fn detachTabForMove(self: *AppSession, index: usize, defer_rebuild: bool, clear_pending_pastes: bool) ?*Tab {
    if (index >= self.tabs.items.len) return null;
    self.cancelPointerGesture();
    // closeTab tail과 동일한 src-측 그룹 위생: 마커 승계 + top_level 경계 재확립. 범위(M3d-2a-i)가 비-그룹이라 이동
    // 탭 자신엔 무동작(group_start==null·top_level=false)이지만, 잔존 탭 재정규화의 단일 출처를 갈리지 않게 그대로 부른다.
    _ = self.inheritGroupMarker(index);
    _ = self.reestablishTopLevelBoundaryOnMove(index);
    const tab = self.tabs.orderedRemove(index);
    _ = self.surface_ptrs.orderedRemove(index);
    self.app_window.tabs = self.surface_ptrs.items; // 길이 변경 — 새 items로 재바인딩(stale 슬라이스 방지)
    // 옮긴 탭을 가리키던 src UI-target 포인터를 비운다(destroyTabStandalone은 생략하지만 그 stale 정리는 필요, [2]).
    clearStaleUiTargetsForMovedTab(self, tab, clear_pending_pastes);
    // destroyTabStandalone 생략(dst 승계). Pane/split·Term·surface는 안 건드린다.
    if (self.tabs.items.len == 0) {
        // 빈 source(§1.6): active-의존 refresh를 건너뛴다(0탭 UB 회피). ended_seen은 caller가 세운다(위 doc).
        self.metal_dirty = true;
        return tab;
    }
    self.app_window.active_tab = reselectAfterClose(index, self.app_window.active_tab, self.tabs.items.len);
    pane_ops.recomputeActivePaneRect(self);
    self.normalizePinnedFromGroups(); // 잔존 탭 멤버 pin 재동기(closeTab tail 동형 — src 측 재정규화 §1.4)
    self.floatLocalPinsAllGroups();
    if (!defer_rebuild) sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
    return tab;
}

/// 떼어온 `*Tab`을 이 세션(dst) 트리에 붙인다 — createTab tail과 동형이되 `createPane`을 **생략**한다(Term/surface는
/// 이미 존재). 원자성: tabs/surface_ptrs capacity를 **먼저** 예약(fallible)해 실패 시 dst 불변. 그 뒤는 infallible —
/// createTab과 같은 삽입점(비고정 리전 첫 group_start 마커 앞 = 그 리전 최상위 구간 끝, 그룹 흡수 방지)에 insert하고,
/// §8A.4(d) 이탈 정규화(top_level:=true·local_pinned:=false), 각 Term 라우팅 링크의 trace_recorder 재지정,
/// **dst cell metric**으로 resize(surface_id 키드 resize라 무재시작), 좌표·사이드바 갱신.
/// adoptTab 전용: 방금 붙여 **활성**이 된 탭 트리를 dst grid로 resize하면서 활성 pane rect를 **같은 layout 1회**에서
/// 캐시한다 — resizeTabPanes(PTY resize)와 recomputeActivePaneRect(rect 캐시)가 각각 `tab.tree`를 layout하던 중복을
/// 제거한다(code-review [5]). resize는 best-effort(임의 Term 에러 무시, resizeTabPanes 동형), rect는 recomputeActivePaneRect와
/// 동일 폴백(활성 pane을 leaf_rects에서 못 찾음/layout OOM = 터미널 영역 전체). `tab`은 caller가 방금 active로 세팅한다.
pub fn resizeAdoptedTabAndCaptureActiveRect(self: *AppSession, tab: *Tab) void {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    const active_pane = tab.activePane();
    var captured = false;
    if (PaneTree.layout(self.allocator, tab.tree, self.termRect(), &leaf_rects)) |_| {
        for (leaf_rects.items) |lr| {
            const trect = pane_ops.paneTermRect(self, lr.rect);
            const psize = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, trect.w, trect.h);
            for (lr.leaf.terms.items) |term| {
                self.resizeTermForLayout(term, psize) catch |err| self.noteResizeDeliveryFailure(term, err); // 표시 grid는 헬퍼가 보장, 전달 실패만 관측
            }
            if (lr.leaf == active_pane) {
                self.active_pane_rect = trect; // 상단 탭 바를 뺀 영역(좌표 origin) — recomputeActivePaneRect 동형
                captured = true;
            }
        }
    } else |_| {}
    if (!captured) {
        self.active_pane_rect = pane_ops.paneTermRect(self, self.termRect()); // 폴백(단일 leaf면 위 루프가 이미 세팅)
    }
}

/// `defer_rebuild`=true면 dst 사이드바 재빌드를 caller가 배치(mergeSessionInto 끝 1회, code-review [4]).
pub fn adoptTab(self: *AppSession, tab: *Tab, defer_rebuild: bool) !void {
    // 1) fallible 먼저(원자성) — 두 병렬 배열 capacity 예약. 실패하면 tab은 안 붙고 dst 불변(caller가 전파).
    try self.tabs.ensureUnusedCapacity(self.allocator, 1);
    try self.surface_ptrs.ensureUnusedCapacity(self.allocator, 1);
    // 2) infallible: createTab tail과 같은 삽입점(비고정 리전 첫 마커 앞). 병렬 배열을 같은 인덱스에 insert해 정합 유지.
    const insert_at = self.firstGroupStartInRegion(countPinnedTabs(self), self.tabs.items.len) orelse self.tabs.items.len;
    self.tabs.insertAssumeCapacity(insert_at, tab);
    self.surface_ptrs.insertAssumeCapacity(insert_at, tab.activeTerm().surface);
    self.app_window.tabs = self.surface_ptrs.items;
    self.app_window.active_tab = insert_at;
    // 3) §8A.4(d) 이탈 정규화 — 목적지 위치 맥락이 없고 append-to-end라 위치-암묵 top-level이 불성립 → 명시 set으로
    //    그룹 흡수를 막는다(§14.9 정합). local_pin은 그룹 leaf 위치 고정이라 이탈 시 무의미(clearStaleLocalPins 대칭).
    //    pinned은 M3d-2a-i 범위상 비-pinned라 안 건드린다(pinned workspace 이동은 M3d-2a-ii).
    tab.top_level = true;
    tab.local_pinned = false;
    // 4) 옮긴 각 Term의 앱-전역 라우팅 링크 trace_recorder를 이 창(dst)으로 재지정 — 링크는 surface_id 키드라 살아
    //    있고, src recorder를 가리키던 채면 떠난 창 trace로 샌다. dst에 recorder 있으면 붙이고(초기 baseline resize
    //    기록), 없으면 끊는다(§8A.8 M3d-2a). 수술은 이미 커밋됐고 링크는 반드시 있으나, 트레이스는 부수기록이라 best-effort.
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            if (self.trace_recorder != null) {
                self.runtime.setSurfaceTraceRecorder(term.surface.id, &self.trace_recorder.?) catch {};
            } else {
                self.runtime.clearSurfaceTraceRecorder(term.surface.id) catch {};
            }
        }
    }
    // 5) dst cell metric으로 옮겨온 트리를 dst 창 grid에 맞춘다(resize는 surface_id 키드 → 무재시작) + 좌표 캐시를
    //    한 번의 layout으로([5]) + 사이드바(merge면 caller가 끝에 1회 배치, [4]).
    resizeAdoptedTabAndCaptureActiveRect(self, tab);
    if (!defer_rebuild) sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 한 워크스페이스(탭)의 모든 Term surface_id를 preorder(pane→Term)로 `out`에 채워 slice 반환(할당 없음, 버퍼 초과분은
/// 조용히 절단 — surface_move.collectWorkspaceSurfaces와 같은 계약). MoveOutcome.moved_surfaces backing.
pub fn collectTabSurfaceIds(tab: *Tab, out: []u64) []const u64 {
    return out[0..appendTabSurfaceIds(tab, out, 0)];
}

pub fn appendTabSurfaceIds(tab: *Tab, out: []u64, start: usize) usize {
    var n = start;
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            if (n >= out.len) break;
            out[n] = term.surface.id;
            n += 1;
        }
    }
    return n;
}

/// 한 워크스페이스(탭)의 총 surface(Term) 수 — ABI moved_count 참값(surface_id 버퍼 절단과 무관, code-review [6]).
pub fn tabSurfaceCount(tab: *Tab) usize {
    var n: usize = 0;
    for (tab.panes.items) |pane| n += pane.terms.items.len;
    return n;
}

/// 사이드바 고정 탭(우클릭 Pin) 개수. 불변식: 고정 탭은 항상 배열 앞쪽 `[0, pinned_count)`에 연속으로 모인다
/// (toggle/drag 경로가 그 불변식을 유지). 따라서 이 개수가 곧 고정/비고정 영역의 경계 인덱스다(pinned_count).
/// pin 토글 정렬과 moveTab 그룹 clamp가 단일 출처로 이 헬퍼를 쓴다.
pub fn countPinnedTabs(self: *const AppSession) usize {
    var n: usize = 0;
    for (self.tabs.items) |t| if (t.pinned) {
        n += 1;
    };
    return n;
}

/// 탭을 from→to로 옮긴다(드래그 재정렬). 베이스/결정: 고정 탭은 배열 앞쪽 `[0, pinned_count)`에 모이는 불변식을
/// 두고(브라우저 탭 고정의 사실상 표준 — 고정/비고정이 안 섞임), 목표 `to`를 from과 **같은 그룹**으로 clamp한다
/// (clampMoveToGroup, session core 단일 출처). 그래서 비고정을 위로 끌어도 고정 영역을 침범하지 않고, 고정을 아래로
/// 끌어도 비고정 영역으로 안 간다 — 고정끼리·비고정끼리만 재정렬된다. clamp 후 from==to면 무동작. tabs/surface_ptrs를
/// 같이 회전(무할당 in-place)하고 active_tab을 보정한다. Tab은 heap-pin이라 포인터만 셔플되고 surface/PTY/reader
/// 포인터는 안 흔들린다. app_window.tabs는 surface_ptrs.items(같은 backing 배열, 내용만 재정렬)라 재바인딩 불요.
/// 범위 밖이면 무동작.
/// clamp으로 확정된 **최종 안착 인덱스**를 반환한다(no-op·범위 밖이면 from) — 드래그 핫패스가 pre-clamp를
/// 따로 안 하고 이 반환값을 단일 출처로 쓴다(countPinnedTabs O(n)가 drag당 1회로 준다). 반환값 무시도 호환된다.
pub fn moveTab(self: *AppSession, from: usize, raw_to: usize) usize {
    const len = self.tabs.items.len;
    if (from >= len or raw_to >= len) return from;
    const to = clampMoveToGroup(raw_to, self.tabs.items[from].pinned, countPinnedTabs(self), len);
    if (from == to) return from; // 같은 그룹으로 clamp한 결과 제자리면 무동작
    rotateMove(*Tab, self.tabs.items, from, to);
    rotateMove(*maru.session.Surface, self.surface_ptrs.items, from, to);
    self.app_window.active_tab = adjustActiveForMove(self.app_window.active_tab, from, to);
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
    return to;
}

pub fn sidebarGroupDropTargetTab(self: *AppSession, raw_row: usize, from: usize) ?usize {
    if (raw_row >= self.sidebar_rows.items.len) return null;
    const len = self.tabs.items.len;
    if (len == 0) return null;
    switch (self.sidebar_rows.items[raw_row]) {
        .card => |c| return c.tab, // 그 카드 위치로 — 위치 파생이 소속을 정한다(같은 그룹/최상위)
        .agent_toggle, .agent => return null, // 에이전트 목록 행은 그룹 소속 판정 대상이 아니다(그 카드의 부속)
        .group_header => |h| {
            const m = h.tab; // 그룹 시작(마커) 탭 인덱스
            if (m >= len) return null;
            if (h.collapsed) {
                // 접힘 → 그룹 끝(subtree [m, j), 자식 그룹 포함 SG5-3). 펼친 헤더 브랜치와 같은 **drag-direction 보정**:
                // from<m이면 dragged 제거로 subtree가 한 칸 당겨져 마지막 멤버 자리 = j-1, from>m이면 subtree가 안
                // 밀리니 마커 뒤 마지막 자리 = j. 옛 코드는 항상 j-1이라 marker-only(j==m+1 → j-1==m)에 from>m 드롭이
                // moveTab(from>m, m)으로 카드를 마커 **앞**에 떨궈 그룹 밖으로 샜다(code-review #2). 이제 두 방향 모두
                // 마커 뒤(그룹 안)로 떨어진다. from==m(마커 탭)은 호출 전 제외(그룹 통째=SG5).
                const j = self.groupSubtreeEnd(m, null, null);
                if (from < m) return j - 1;
                return @min(j, len - 1);
            }
            // 펼침 → 그룹 첫 몸통 카드 자리(마커 직후). from==m은 마커 탭이라 이 경로 호출 전 제외됨(무동작 가드).
            if (from < m) return m;
            return @min(m + 1, len - 1);
        },
    }
}

/// tabs/surface_ptrs를 새 순서로 재배열하는 공통 스캐폴딩(code-review #10) — 활성 *Tab을 캡처해 재배열 후 새 인덱스로
/// 보정하고, 임시 버퍼 2개를 alloc/free한다. `fill`(comptime)이 context와 self로 새 순서를 채운다(정확히 1:1 순열;
/// 반환값은 caller가 해석 — moveGroupRange는 새 마커 인덱스, stablePartitionPinned는 미사용). tabs가 비었거나 alloc
/// 실패면 null(재배열 생략, 순서 불변). moveGroupRange(블록 이동)·stablePartitionPinned(고정 파티션)가 공유 —
/// 옛 두 곳의 active 캡처/임시 버퍼/memcpy/active 재find 중복을 한 곳으로 모은다. Tab은 heap-pin이라 포인터만 셔플되고
/// surface_ptrs.items는 app_window.tabs와 같은 backing이라 in-place memcpy면 재바인딩 불요(moveTab과 동형).
pub fn reorderTabs(
    self: *AppSession,
    context: anytype,
    comptime fill: fn (@TypeOf(context), *AppSession, []*Tab, []*maru.session.Surface) usize,
) ?usize {
    const len = self.tabs.items.len;
    if (len == 0) return null;
    const active_ptr: ?*Tab = if (self.app_window.active_tab < len) self.tabs.items[self.app_window.active_tab] else null;
    const new_tabs = self.allocator.alloc(*Tab, len) catch return null;
    defer self.allocator.free(new_tabs);
    const new_surfaces = self.allocator.alloc(*maru.session.Surface, len) catch return null;
    defer self.allocator.free(new_surfaces);
    const result = fill(context, self, new_tabs, new_surfaces);
    @memcpy(self.tabs.items, new_tabs);
    @memcpy(self.surface_ptrs.items, new_surfaces);
    if (active_ptr) |ap| for (self.tabs.items, 0..) |t, i| if (t == ap) { // active *Tab의 새 인덱스로 보정
        self.app_window.active_tab = i;
        break;
    };
    return result;
}

/// 카드/마커 `tab`이 속한 그룹의 **최상위(depth 1) 시작 마커 탭**(§2.1 상향 파생, 핀 리전 클램프 — enclosingGroupMarkerIndex
/// 공유). 최상위 카드(그룹 미소속)면 null. 개별 카드 pin 입구 차단(§12.7 보강5)이 "그룹 멤버 우클릭 pin = 그룹째 위임"을
/// 판정·실행할 때 쓴다(멤버면 이 마커로 toggleGroupPin, 최상위면 togglePin).
/// **top-level 해소(§12.1 pin ⊃ group ⊃ nest)**: 그룹 고정은 **top-level 그룹 속성**이라, nearest(중첩 subgroup) 마커에
/// 걸면 그 subtree만 pin돼 부모에서 떨어져 나간다. enclosing 마커를 effectiveDepthAt이 1이 될 때까지 부모로 상향해
/// (중첩 subgroup 헤더/카드에서 눌러도) 항상 최상위 그룹 통째를 토글한다. subtree는 pin 균일(I3)이라 마커 pinned로 라벨을
/// 정하는 호출처(buildContextMenuItems)도 nearest·top-level이 같은 값이라 정합한다.
pub fn enclosingGroupMarkerTab(self: *AppSession, tab: *const Tab) ?*Tab {
    for (self.tabs.items, 0..) |t, i| if (t == tab) {
        var mi = self.enclosingGroupMarkerIndex(i) orelse return null;
        // depth 1(top-level)까지 부모 마커로 상향. mi는 매 반복 strictly 감소(mi-1에서 재조회)라 종료가 보장된다.
        // 형제 subgroup을 먼저 만나도 depth>1이라 계속 올라가 결국 top-level 마커에 닿는다(리전/리스트 시작에서 break).
        while (self.effectiveDepthAt(mi, null, null) > 1) {
            if (mi == 0) break;
            mi = self.enclosingGroupMarkerIndex(mi - 1) orelse break;
        }
        return self.tabs.items[mi];
    };
    return null;
}

/// 워크스페이스에 그룹 시작 마커를 얹는다(create_group — 활성/클릭 대상). 그 아래 연속 카드가 위치 파생으로 자동
/// 소속된다(§2.1). **중첩(SG5-3)**: 그룹 **안** 카드에서 실행하면 그 카드의 현재 depth+1로 자식 그룹 마커를 만든다.
/// 최상위 카드에서는 depth 1. 위치 파생상 이 마커 뒤 형제 카드들은 새 자식 그룹으로 흡수된다(§9 create_group 규칙).
pub fn createGroupForTab(self: *AppSession, tab: *Tab) void {
    beginGroupForTab(self, tab, .nested, true);
}

/// 워크스페이스에 **형제** 그룹 시작 마커를 얹는다(create_sibling_group — SG5-3, create_group과 명시적 분리). 그룹 안
/// 카드에서 실행하면 그 카드의 현재 그룹과 **같은 depth**의 형제 그룹을 시작한다(그 카드부터 현재 그룹에서 분할돼
/// 형제로 시작 — 위치 파생상 마커 뒤 형제 카드들이 새 그룹으로 흡수). 최상위 카드면 depth 1(create_group과 결과 동일).
/// create_group(depth+1 중첩)의 미러 — depth 계산만 다르다(현재 depth vs +1). §10 "형제 못 만듦" tension 해소 경로.
pub fn createSiblingGroupForTab(self: *AppSession, tab: *Tab) void {
    beginGroupForTab(self, tab, .sibling, true);
}

/// **테스트/스크린샷 전용** — SR3 이전 "마커 뒤 리스트 끝까지 전부 흡수" 그룹 생성(§14.5 요구1 도입 전 동작). 프로덕션
/// createGroup은 이제 **선택 탭만 그룹**(다음 탭에 `top_level:=true` write)이지만, 그룹 크기와 무관한 기능(중첩·로컬핀·
/// 그룹핀·빼기·드래그·헤더)을 **다중 멤버 그룹**으로 검증하는 기존 테스트/FORCE 스크린샷 훅이 이 흡수 변형을 쓴다. 다중
/// 멤버 그룹은 SR4 드래그로도 도달하는 정상 상태이며, `break_next=false`로 top_level write를 생략해 SR3 이전과 byte-identical
/// 하게 재현한다(전 탭 top_level=false → 인라인 depth 리셋도 never-fire).
pub fn createGroupAbsorbForTab(self: *AppSession, tab: *Tab) void {
    beginGroupForTab(self, tab, .nested, false);
}

pub fn createSiblingGroupAbsorbForTab(self: *AppSession, tab: *Tab) void {
    beginGroupForTab(self, tab, .sibling, false);
}

/// create_group/create_sibling_group 공통 — 카드 tab에 group_start 마커를 얹고 group_depth를 세팅한다(kind만 다름).
/// 이미 그룹 시작이면 no-op(중복 방지·기존 이름 보존; 이름 변경은 rename_group). 기본 이름 "그룹 N"(N=기존 마커 수+1).
/// group_start는 owned(destroyTab/deinit이 free — custom_name과 같은 규율). depth는 **group_start 세팅 전에** 계산한다 —
/// 그래야 effectiveDepthAt이 이 탭을 아직 마커가 아닌 "소속 카드"로 보고 현재(소속) depth를 돌려준다(최상위=0).
pub fn beginGroupForTab(self: *AppSession, tab: *Tab, kind: GroupCreateKind, break_next: bool) void {
    if (tab.group_start != null) return;
    // 단일 패스로 (1) 전체 마커 수(group_count — 기본 이름 "그룹 N"용)와 (2) tab 위치의 enclosing depth(위치 파생 스택,
    // effectiveDepthAt과 동형)를 함께 구한다 — 옛 코드는 count 루프 후 effectiveDepthAt이 0부터 스택을 다시 훑었다
    // (code-review #15). tab은 아직 마커가 아니므로(위 가드) 카드 = 자기 앞 마커들의 스택 top depth(최상위=0). depth는
    // tab 도달 시점에 캡처하고(이후 마커는 depth 무관), group_count는 tab 이후 마커도 세야 하므로 루프를 끝까지 돈다.
    // tab_index는 §14.5 "선택 탭만 그룹"의 top_level write 대상(마커 뒤 첫 탭)을 찾는 데 쓴다.
    var group_count: usize = 0;
    var enclosing_depth: u8 = 0;
    var found_depth = false;
    var tab_index: usize = 0; // tab의 리스트 인덱스(top_level write 대상 = tab_index+1, §14.5 요구1)
    var stack: [max_group_nesting]u8 = undefined; // 위치 파생 정규화 depth 스택(projectRows pass1과 동형)
    var top: usize = 0;
    var prev_pinned: ?bool = null; // 핀 리전 경계 추적(§12 GP1 — effectiveDepthAt과 동형)
    for (self.tabs.items, 0..) |t, i| {
        // 핀 리전 경계 + §2.1 재설계(§14.3·§14.5 SR3) **top_level edge 경계**에서 depth 스택 리셋(projectRows pass1과 동형).
        // 핀 리전: subtree는 핀 리전을 못 넘는다(effectiveDepthAt 7263~). 이게 없으면 고정 그룹(스택에 depth push) 뒤
        // **비고정 top카드**의 enclosing_depth가 고정 그룹 depth를 상속해, 중첩 그룹을 만들면 group_depth가 (고정 그룹
        // depth)+1로 잘못 저장된다(unpin 후 오중첩·persist). top_level: 최상위 복귀 카드도 depth 0으로 리셋해야 그 뒤
        // 카드가 그룹 depth를 상속하지 않는다(SR1이 SR3로 미룬 pass1 미러). 전 탭 top_level=false면 이 항은 never-fire라
        // 옛 동작과 byte-identical. 저장 depth는 정확해야 한다.
        if ((prev_pinned != null and t.pinned != prev_pinned.?) or t.top_level) {
            top = 0;
        }
        prev_pinned = t.pinned;
        if (!found_depth and t == tab) { // 이 카드 위치의 소속 그룹 depth = 스택 top(없으면 최상위 0)
            tab_index = i;
            enclosing_depth = if (top > 0) stack[top - 1] else 0;
            found_depth = true;
        }
        if (t.group_start != null) {
            group_count += 1;
            const dd: u8 = @max(@as(u8, 1), t.group_depth); // declared로 pop 판정(gap 클램프 정규화)
            while (top > 0 and stack[top - 1] >= dd) top -= 1;
            const parent: u8 = if (top > 0) stack[top - 1] else 0;
            if (top < stack.len) {
                stack[top] = parent + 1;
                top += 1;
            }
        }
    }
    // 중첩 = 현재 그룹 depth+1(max_group_nesting 클램프로 무한 들여쓰기/u8 오버플로 방지). 형제 = 현재 그룹과 같은
    // depth(최상위 카드는 0→1이라 두 kind가 동일). projectRows가 저장 depth로 gap을 다시 클램프하지만 저장값도 합리적으로.
    const new_depth: u8 = switch (kind) {
        .nested => @intCast(@min(@as(usize, enclosing_depth) + 1, max_group_nesting)),
        .sibling => @max(@as(u8, 1), enclosing_depth),
    };
    const name = std.fmt.allocPrint(self.allocator, "그룹 {d}", .{group_count + 1}) catch return;
    tab.group_start = name; // owned
    tab.group_collapsed = false;
    tab.group_depth = new_depth;
    // §2.1 재설계(§14.5·leaf-only §13.8): 마커는 top_level 금지 — top_level 최상위 카드를 그룹으로 묶으면(카드→마커 전이)
    // 그 top_level을 clear한다(마커의 "형제 top-level 그룹"은 group_depth pop으로 표현, §13.8). 카드가 top_level이 아니었으면
    // no-op(byte-identical) — 흡수 경로(break_next=false)도 안전.
    tab.top_level = false;
    // leaf-only §13.8: 마커는 local_pinned도 금지(로컬 pin은 "그룹 안 leaf 멤버의 위치 고정", 마커는 leaf 아님). 로컬 pin
    // 멤버 카드를 그룹 마커로 전이시키면 stale local_pinned=1 마커가 남아(leaf-only 위반) sidebarRowShowsPin 선두 분기가
    // 마커에 📌를 살린다. 여기서 클리어하고, 아래 clearStaleLocalPins가 이 create로 top_level 전이한 카드(break_next write)
    // 의 stale local_pinned도 함께 스윕한다(ungroup·removeFromGroup·promote·commit과 동형 위생 — §13.7 전이 지점).
    tab.local_pinned = false;
    // §2.1 재설계(§14.5, 요구1) **"선택 탭만 그룹"**: 마커 뒤 첫 탭에 `top_level:=true`를 써 위치 파생 흡수를 top_level
    // break로 끊는다(정책 b — 단일 탭 그룹 + 뒤 탭들 promote: 첫 탭이 최상위 복귀 run을 개시해 그 뒤 카드도 sticky-reset로
    // 최상위). break_next=false는 SR3 이전 "마커 뒤 전부 흡수"를 재현하는 테스트/스크린샷 경로(위 tab.top_level clear만).
    // **엣지 안전 처리**: (1) 다음 탭 없음(마커가 리스트 끝) → 흡수할 게 없어 write 생략, (2) 다음이 이미 마커
    // (group_start!=null, 연속 그룹) → 그 자체가 그룹 경계라 write 불필요·leaf-only상 마커엔 top_level 금지, (3) 다음이
    // 다른 핀 리전(pinned 불일치) → 핀 경계가 이미 subtree를 끊음(§12 GP1). 위 3경우가 아니면 다음 leaf 카드에 top_level
    // write(이미 true여도 idempotent). normalize/float **전에** 써야 그들이 top_level break를 인식해 멤버 범위를 정확히 잡는다.
    if (break_next) {
        const ni = tab_index + 1;
        if (ni < self.tabs.items.len) {
            const next = self.tabs.items[ni];
            if (next.group_start == null and next.pinned == tab.pinned) next.top_level = true;
        }
    }
    // 그룹 고정 C2(§12.5 GP2): 새 마커 밑으로 흡수된 멤버 카드의 pinned 캐시를 마커 기준으로 재동기(비프리뷰 경로).
    // 보통은 새 마커 pinned=0(create는 pin을 안 건드림)이라 멤버도 0(무변화)이지만, 고정 top-level 카드를 마커로 만든
    // 경우엔 흡수 멤버가 마커 pinned를 따르게 canonical화한다(마커 = 그룹 고정 권위, §12.2).
    self.normalizePinnedFromGroups();
    self.floatLocalPinsAllGroups(); // 그룹-로컬 pin 재float(GL §13.4 배선 — 새 마커 subtree에 흡수된 로컬 pin 멤버 정렬)
    self.clearStaleLocalPins(); // 위생(GL §13.7): 마커 전이·top_level break로 leaf 아니게 된 카드의 stale local_pinned 클리어(고아 📌 방지)
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 워크스페이스가 속한 그룹을 푼다(ungroup) — 그 탭 위(자기 포함)에서 가장 가까운 group_start 마커를 제거한다
/// (§2.1 소속 파생). 아래 카드는 위 마커/최상위로 자동 재소속. 그룹에 안 속하면 no-op.
pub fn ungroupTab(self: *AppSession, tab: *Tab) void {
    var idx: ?usize = null;
    for (self.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    const mi = self.enclosingGroupMarkerIndex(idx orelse return) orelse return; // 최상위 카드 → no-op
    // 그룹째 고정 인계 차단(사용자 정책 "그룹 속성은 그룹 속성에서만" — 그룹 고정 C2 §12.2): 마커 `pinned`=그룹째 고정
    // **권위**, 멤버 `pinned`=파생 캐시다. ungroup은 그룹을 **소멸**시키므로(마커의 group_start 제거) 그룹째 고정은
    // 소멸하고 **멤버에 인계되면 안 된다** — 안 그러면 옛 멤버가 개별 고정(pinned=1)으로 잔류한다. 마커 제거 **전**(mi가
    // 아직 유효 마커일 때) subtree 범위 [mi, e)(마커·멤버·중첩 자식 통째, groupSubtreeEnd는 핀 리전/top_level 경계를
    // 존중해 비고정 꼬리는 안 삼킨다)를 캡처해 pinned 캐시를 클리어한다 → 멤버는 비고정 최상위 탭으로 복귀한다. **비고정
    // 그룹**은 이미 멤버 pinned=0이라 이 클리어가 no-op(회귀 0)이고, **고정 그룹**만 동작한다. local_pinned은 아래
    // clearStaleLocalPins가 top-level로 전이한 멤버만 골라 정리하므로(중첩 생존 subgroup 멤버 로컬 pin은 보존) 여기선
    // 안 건드린다 — 전 subtree를 무조건 클리어하면 살아남는 자식 그룹 멤버의 유효 로컬 pin까지 지운다.
    const e = self.groupSubtreeEnd(mi, null, null); // 마커 제거 전 subtree 범위(mi가 유효 마커일 때만 정확)
    // **top-level 그룹 vs 중첩 subgroup 판정(마커 제거 전 — mi가 유효 마커일 때만 effectiveDepthAt가 정확)**: 그룹째
    // 고정은 **top-level 그룹 속성**(§12.1 pin ⊃ group ⊃ nest)이라 ungroup의 pinned 처리가 대상 깊이에 달렸다.
    //  - **top-level 그룹**(effectiveDepthAt==1): 그룹을 통째 소멸시키므로 그룹째 고정도 소멸 → 멤버 pinned 캐시를
    //    [mi,e) 클리어하고, 남은 고정 프리픽스를 stablePartitionPinned로 복구한다(고정 그룹이 다른 고정 단위 **앞**이던
    //    경계에서 I1 무결 — ungroup-pin(d)).
    //  - **중첩 subgroup**(effectiveDepthAt>1): 마커만 사라지고 멤버는 **부모 그룹으로 재소속**되므로 부모 pinned를
    //    **상속**해야 한다 — pinned를 클리어하면 멤버가 부모에서 튕겨나가 비고정 리전으로 eject된다. 클리어도 partition도
    //    하지 않는다(pin count 불변이라 프리픽스 무결·아래 normalize가 부모 마커 기준으로 canonical 재동기). **[5]도 함께
    //    닫힘**: groupSubtreeEnd가 trailing 고정 top_level 카드(그룹 밖)를 [mi,e)에서 제외하므로, 중첩 ungroup에서
    //    partition을 스킵하면 그 **무관 고정 top카드**가 stablePartitionPinned로 맨 앞으로 front-jump하던 갭이 사라진다
    //    (partition 범위/조건이 top-level 게이트로 정합 — 무관 top카드 pinned·위치 유지).
    const is_top_level = self.effectiveDepthAt(mi, null, null) == 1;
    self.allocator.free(self.tabs.items[mi].group_start.?); // owned 마커 해제
    self.tabs.items[mi].group_start = null;
    self.tabs.items[mi].group_collapsed = false;
    if (is_top_level) {
        var k = mi;
        while (k < e) : (k += 1) self.tabs.items[k].pinned = false; // 마커+멤버 pinned 캐시 클리어 — top-level 그룹째 고정 소멸(인계 금지)
        self.stablePartitionPinned(); // 남은 고정 프리픽스 무결 복구(중첩은 스킵 — 무관 고정 top카드 front-jump 방지 [5])
    }
    // 그룹 고정 C2(§12.5 GP2): 마커가 사라져 아래 카드가 위 마커/최상위로 재소속됐으니 pinned 캐시를 새 enclosing 기준
    // 으로 재동기(비프리뷰 경로). 옛 멤버가 최상위가 되면 자기 값 유지(top-level이면 위에서 0으로 클리어), 상위 그룹으로
    // 재소속되면 그 마커 pinned를 따른다(중첩 자식 ungroup이 부모로 재소속·부모 pin 상속하는 경로).
    self.normalizePinnedFromGroups();
    self.floatLocalPinsAllGroups(); // 그룹-로컬 pin 재float(GL §13.4 배선 — 마커 제거로 상위 그룹에 재소속된 멤버 정렬)
    self.clearStaleLocalPins(); // 위생(GL §13.7): 그룹 밖 top-level로 나간 옛 멤버의 stale local_pinned 클리어(고아 📌 방지)
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
    if (builtin.mode == .Debug) assertPinnedPrefixRuntime(self); // ungroup 후 프리픽스·정렬 불변식(toggleGroupPin과 동형)
}

/// tab이 어느 그룹에 속하는가(§2.1 소속 파생: 자기 위 가장 가까운 마커에 소속, 없으면 최상위). 우클릭
/// "그룹에서 빼기"를 **그룹 소속 카드에만** 주입하는 조건이자 removeFromGroupForTab no-op 판정과 같은 단일 출처.
/// 최상위(위에 마커 없음·top-level run·그룹 전무)면 false → 메뉴에 항목이 안 뜨고 액션도 no-op.
pub fn tabIsInGroup(self: *const AppSession, tab: *const Tab) bool {
    // §2.1 재설계(§14): "그룹 안" = enclosingGroupMarkerIndex가 non-null(자기 위 같은 핀 리전에 마커가 있고, 그
    // 사이에 top_level 최상위 복귀가 없다). 옛 "리전 첫 마커 이후" 판정은 **그룹 뒤 top카드**를 그룹 안으로 오판했으나
    // (첫 마커 이후라는 이유만으로), enclosing 기반은 top_level 상향 클램프로 정확히 밖으로 본다. 전 탭 top_level=false면
    // enclosing(상향 최근접 마커)과 "리전 첫 마커 이후"가 동치(연속 파티션)라 옛 판정과 byte-identical.
    for (self.tabs.items, 0..) |t, i| if (t == tab) return self.enclosingGroupMarkerIndex(i) != null;
    return false;
}

/// 워크스페이스 **하나만** 자기 그룹에서 빼 완전 최상위(어느 그룹에도 안 속함)로 옮긴다(remove_from_group — 우클릭
/// "그룹에서 빼기"·팔레트·config). §2.1: 최상위 = 첫 group_start 마커 **이전** 구간이라, 그 카드를 첫 마커 직전으로
/// moveTab한다(중첩 깊이 무관 완전 최상위). ungroup이 그룹 시작 마커를 지워 그룹을 통째 해제하는 반면, 이건 카드 하나만
/// 뽑고 그룹은 살린다. 이미 최상위(첫 마커 이전·그룹 전무)면 no-op. 이 카드가 **그룹 시작 마커**면 먼저 그 마커를 다음
/// 소속 카드로 **승계**(closeTab 마커 승계와 동형 — group_collapsed/group_depth/group_color 함께)해 그룹을 살린 뒤
/// 자기 마커를 떼고 최상위로 옮긴다(다음이 없거나 이미 다른 마커면 승계 불가 → 그룹 소멸, 마커 free). moveTab이 없으면
/// (마커 뗀 뒤 이미 최상위 구간이거나 남은 마커 없음) 재투영만 한다.
pub fn removeFromGroupForTab(self: *AppSession, tab: *Tab) void {
    var idx: ?usize = null;
    for (self.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    const ix = idx orelse return;
    // **핀 리전(§12 GP1)**: 빼기는 이 카드가 속한 핀 리전 **안의** 최상위(그 리전 첫 마커 앞)로만 옮긴다 — 고정
    // 프리픽스를 침범하지 않는다. reg는 pinned 기반이라 아래 마커 승계(그룹 필드만 이동, pinned 불변)에도 안정하다.
    const reg = self.pinRegionBounds(ix);
    // **그룹 밖 no-op 가드(code-review, promote 5617과 동형)**: 옛 `ix < fm0`(첫 마커 이전)은 §2.1 인터리빙에서 **그룹 뒤
    // top_level 카드**를 out-of-group으로 못 봤다(그 카드는 첫 마커 뒤라 `ix >= fm0`이지만 enclosing 마커가 없어 실제론
    // 그룹 밖). `!tabIsInGroup`(enclosing 기반)으로 바꿔 top카드·top-level run·그룹 전무를 모두 밖으로 정확히 판정한다
    // (그룹 뒤 top카드 remove = no-op). top_level 0개면 enclosing과 "첫 마커 이후"가 동치라 byte-identical.
    if (!tabIsInGroup(self, tab)) return;

    // 이 카드가 그룹 시작 마커면 그룹이 사라지지 않게 마커를 다음 소속 카드로 승계(inheritGroupMarker 공유, #11).
    // 승계 불가(그룹이 이 카드뿐·마지막 탭)면 마커를 free해 그룹 소멸. 이 탭은 살아남으므로 그룹 필드를 기본값 복귀.
    if (tab.group_start != null) {
        if (!self.inheritGroupMarker(ix)) {
            self.allocator.free(tab.group_start.?); // 승계 대상 없음 → 그룹 소멸
            tab.group_start = null;
        }
        // 승계됐으면 inheritGroupMarker가 이미 tab.group_start=null. 나머지 그룹 필드는 마커 아님으로 복귀(기본값).
        tab.group_collapsed = false;
        tab.group_color = 0;
        tab.group_depth = 1;
    }

    // 그룹 고정 C2(§12.7 보강 4 GP3): **고정** 그룹에서 빼기 = pin 상실. `clampMoveToGroup`은 카드를 자기 pin 그룹에
    // 가두는 pin-trap이라, 고정인 채로 moveTab하면 고정 리전에 붙잡혀 비고정 최상위로 못 나간다. 그래서 **move 전에**
    // unpin을 결정하고, 비고정 리전 시작(= 남은 고정 수)으로 옮긴 뒤 **move 후에** normalize한다 — 카드가 구조상 아직
    // 그룹 안일 때 normalize하면 suffix-exclusion이 사이 낀 것으로 보고 재흡수할 수 있어, 비고정 top카드 위치로 옮기고
    // 정규화해야 "빼기=고정 상실"이 안정된다(남은 그룹은 마커 기준 canonical, 빠진 카드는 비고정 유지).
    if (tab.pinned) {
        tab.pinned = false; // §12.7 보강 4 — 빼기로 고정 상실(move 전 결정)
        const to = countPinnedTabs(self); // unpin 반영된 비고정 리전 시작
        _ = moveTab(self, ix, to); // 비고정 리전 최상위로(clamp가 비고정 영역 [pinned_count, len)로 가둠)
        self.normalizePinnedFromGroups(); // move 후 — 남은 그룹 재동기, 빠진 카드는 비고정 top카드라 안 흡수
        self.floatLocalPinsAllGroups(); // 빼기 후 남은 그룹 로컬 pin 재float(빠진 카드=최상위)
        self.clearStaleLocalPins(); // 위생(GL §13.7): 빠진 카드=top-level → stale local_pinned 클리어(빼기=pin·로컬 pin 상실)
        sidebar_ops.rebuildSidebar(self) catch {};
        self.metal_dirty = true;
        return;
    }

    // 그룹 고정 C2(§12.5 GP2): 마커 승계/제거로 남은 그룹 구성이 바뀌었으니 멤버 pinned 캐시를 재동기(비프리뷰 경로).
    // 아래 moveTab/rebuild 두 종료 경로 모두 앞서 한 번 정규화하면 충분하다(빼낸 카드는 최상위로 이동해 자기 값 유지,
    // 남은 그룹은 마커 기준 canonical). 비고정 멤버는 pin-trap이 없어 그 리전 최상위로 그대로 뺀다(고정 경로는 위에서 처리).
    self.normalizePinnedFromGroups();

    // 승계 후(또는 마커 아니었으면) 남은 첫 마커(이 핀 리전 안) 직전으로 옮긴다. 이 카드가 첫 마커였다면 승계로 마커가
    // ix+1로 내려가 이미 그 앞(최상위)이 되므로 moveTab 불필요 — 재투영만. moveTab이 tabs/surface/active를 처리한다.
    // **GL §13.4 배선**: floatLocalPins는 moveTab이 `ix`를 소비한 **뒤**에 부른다(early-return 대신 fall-through) —
    // 그 앞에 float하면 로컬 pin 멤버가 옮겨져 stale ix로 딴 카드를 moveTab할 위험이 있다. 빠진 카드는 최상위로 나가
    // 남은 그룹 float만 갱신되고, 나간 카드의 stale local_pinned은 아래 위생 스윕(§13.7)에서 클리어한다.
    if (self.firstGroupStartInRegion(reg.lo, reg.hi)) |fm| {
        if (ix > fm) _ = moveTab(self, ix, fm);
    }
    self.floatLocalPinsAllGroups();
    self.clearStaleLocalPins(); // 위생(GL §13.7): 빠진 카드=top-level → stale local_pinned 클리어(고아 📌 방지)
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 그룹 멤버 카드를 **제자리에서** 최상위 섬으로 승격한다(promote-in-place — 우클릭 "여기서 최상위로 분리", §14.5·§14.7).
/// `top_level:=true`만 세팅해 그 카드부터 최상위 복귀 run을 개시한다(위치·순서 불변 — 그룹 안 gap에 최상위 섬으로 남고,
/// sticky-reset로 뒤 멤버까지 그룹에서 끊긴다, §14.1). **removeFromGroupForTab과 구별되는 eject flavor divergence(§14.7)**:
///  - removeFromGroup = 카드를 그 리전 첫 마커 **앞으로 이동** + **고정 상실**(unpin, §12.7 보강4).
///  - promote-in-place = **제자리** top_level 세팅 + **pin 불변**(고정 리전 안이면 고정 top카드로 남음 — §14.7 (2)).
/// 마커 카드(group_start!=null)면 no-op(마커는 이미 그룹 시작이라 승격 무의미·leaf-only상 top_level 금지). 그룹 밖(최상위·
/// top-level run·그룹 전무 = tabIsInGroup=false)이면 no-op(승격할 소속이 없음). top_level 하드 break로 이 카드가 그룹 subtree
/// 에서 빠졌으니 pinned 캐시를 재동기(§14.4 top_level 인식 normalize)하고, top-level로 전이한 카드의 stale local_pinned를
/// 클리어한다(GL §13.7 전이 4번째 지점 — ungroup·removeFromGroup·드래그와 동형 위생).
pub fn promoteTabToTopLevelInPlace(self: *AppSession, tab: *Tab) void {
    if (tab.group_start != null) return; // 마커 카드 → no-op(leaf-only §13.8, 승격 무의미)
    if (!tabIsInGroup(self, tab)) return; // 그룹 밖(최상위·top-level run) → no-op(승격할 소속 없음)
    tab.top_level = true; // 제자리 최상위 복귀(위치·pin 불변 — §14.7 eject flavor divergence)
    self.normalizePinnedFromGroups(); // 그룹 고정 C2(§14.4): top_level 하드 break로 빠진 카드 반영, 남은 그룹 canonical
    self.floatLocalPinsAllGroups(); // 남은 그룹 로컬 pin 재float(승격 카드는 이제 최상위)
    self.clearStaleLocalPins(); // 위생(GL §13.7): top-level 전이한 카드의 stale local_pinned 클리어(고아 📌 방지)
    sidebar_ops.rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 워크스페이스가 속한 그룹에 공통 색을 지정한다(SG5-2 — 우클릭 "그룹 색: …"). 그 탭 위(자기 포함)에서 가장 가까운
/// group_start 마커 탭을 찾아 group_color를 세팅한다(ungroupTab과 같은 상향 탐색). 그룹 색은 마커 탭 **하나에만**
/// 저장하고 소속 카드는 위치 파생으로 그 색을 따른다(별도 저장 없음 — §2.1 위치 파생과 동형). color=0이면 색 해제
/// (기본 폴백). 그룹에 안 속하면 no-op(색을 얹을 마커가 없음 — ungroup 무동작과 같은 결).
pub fn setGroupColorForTab(self: *AppSession, tab: *Tab, color: u32) void {
    var idx: ?usize = null;
    for (self.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    const mi = self.enclosingGroupMarkerIndex(idx orelse return) orelse return; // 최상위 카드 → no-op(색 얹을 그룹 없음)
    self.tabs.items[mi].group_color = color; // 그룹 시작 마커에만 색 저장(소속 카드는 위치 파생)
    sidebar_ops.rebuildSidebar(self) catch {}; // 헤더 밴드 tint·소속 카드 막대 즉시 반영
    self.metal_dirty = true;
}

/// 워크스페이스가 속한 그룹의 이름을 인라인 편집한다(rename_group — 헤더 더블클릭·팔레트·우클릭). 그 탭 위(자기 포함)
/// 에서 가장 가까운 group_start 탭을 찾아 startRename(.group). 그룹에 안 속하면 no-op(편집할 이름이 없음).
pub fn startRenameGroupForTab(self: *AppSession, tab: *Tab) void {
    var idx: ?usize = null;
    for (self.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    const mi = self.enclosingGroupMarkerIndex(idx orelse return) orelse return; // 그룹에 안 속함 → no-op
    self.startRename(.{ .group = self.tabs.items[mi] });
}

/// 사용자 액션(Cmd+T)으로 새 탭을 연다 — 첫 탭과 같은 종류의 셸을 '현재 창 크기'로 띄운다(보관한
/// new_tab_config/zdotdir, term은 loaded_config). createTab이 새 탭을 활성으로 만든다.
pub fn newTab(self: *AppSession) !*Tab {
    var cfg = self.new_tab_config;
    // 새 탭은 단일 panel(전체 터미널 영역)이다. 직전 활성 surface의 core grid(activeSurface().core.size)를 쓰면,
    // 그 탭이 split이었을 때 activeSurface()가 분할된 '한 panel'이라 grid가 작아져, 새 탭이 그 작은 크기로 spawn돼
    // 직전 활성 탭 사이즈를 물려받는다(resizeActiveTabPanes가 전체로 다시 펴는 강제 리사이즈 전까지 고착). 단일
    // leaf가 실제로 차지할 영역(paneTermRect(termRect))의 grid로 잡아, init 첫 탭(spawn_config.size=전체 grid)과
    // 같은 계약을 따른다 — resizeActiveTabPanes가 단일 leaf에 적용하는 grid와도 정확히 일치한다.
    const full = pane_ops.paneTermRect(self, self.termRect());
    cfg.size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, full.w, full.h);
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.shellIntegrationZdotdir(), self.new_tab_ssh_bin);
    // 새 워크스페이스 탭: tab-inherit-cwd면 포커스 cwd 상속, 아니면 root(Ghostty tab-inherit 모델).
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    self.applySpawnCwd(&req, &root_buf, self.loaded_config.config.workspace.tab_inherit_cwd);
    return createTab(
        self,
        req,
        cfg.size,
        cfg.queue_capacity,
        "Maru",
        commandName(cfg.command_kind),
    );
}

/// 검색어(이름·브랜치·폴더 대소문자 무시 substring)에 맞는 첫 탭 인덱스. 빈 검색어면 null. P3 필터·Enter 공유.
pub fn firstMatchingTab(self: *AppSession) ?usize {
    const q = self.sidebar_search_input.query.items;
    if (q.len == 0) return null;
    for (self.tabs.items, 0..) |tab, i| if (tabMatchesSearch(self, tab, q)) return i;
    return null;
}

/// 검색 필터·그룹 마커·접힘을 self.tabs에 투영해 sidebar_rows(표시 행)를 채운다 — **identity order + 라이브 group_depth**를
/// 순열/depth 순수 코어 projectRowsFrom에 넘기는 얇은 래퍼(docs/sidebar-groups.md §9 SG8a). SG8b simulateDrop이 여기
/// order/group_depth를 가상 배치(고스트 프리뷰)로 갈아끼워 같은 코어를 재사용한다 — identity면 옛 flat 투영과
/// **byte-identical row 산출**(동작 보존). order[i]=i, group_depth[i]=마커 저장 depth(비마커는 pass1에서 안 읽힘).
pub fn recomputeVisibleTabs(self: *AppSession) void {
    const n = self.tabs.items.len;
    const searching = self.sidebar_search_active and self.sidebar_search_input.query.items.len > 0;
    const q: []const u8 = if (searching) self.sidebar_search_input.query.items else "";
    // identity 순열 + 라이브 group_depth. OOM(극단)이면 그룹 무시 flat(projectFlatFallback이 clear까지 함께).
    const order = self.allocator.alloc(usize, n) catch return self.projectFlatFallback(&self.sidebar_rows, q);
    defer self.allocator.free(order);
    const group_depth = self.allocator.alloc(u8, n) catch return self.projectFlatFallback(&self.sidebar_rows, q);
    defer self.allocator.free(group_depth);
    for (self.tabs.items, 0..) |tab, i| {
        order[i] = i;
        group_depth[i] = tab.group_depth;
    }
    self.projectRowsFrom(order, group_depth);
}

/// 표시 슬롯 → 원본 tab 인덱스(검색 필터 역매핑). 범위 밖이면 null. slotAt/click/hover가 표시 슬롯을 실제 탭으로.
pub fn visibleTab(self: *const AppSession, display_slot: usize) ?usize {
    if (display_slot >= self.sidebar_rows.items.len) return null;
    return switch (self.sidebar_rows.items[display_slot]) {
        .card => |c| c.tab,
        .agent_toggle, .agent => null, // 선택 대상이 아님(각자 접기 토글·Term 이동으로 분기)
        .group_header => null, // 헤더 row는 탭이 아님 — 클릭 시 선택 아니라 접기 토글(SG3c)
    };
}

/// 탭이 검색어에 매칭하는가 — 이름(라벨)·git 브랜치·폴더(cwd) 중 하나라도 query를 포함(ASCII 대소문자 무시,
/// 한글 등은 그대로). 빈 query는 항상 true(필터 없음). 사이드바 카드 필터·Enter 첫 매칭이 공유한다.
pub fn tabMatchesSearch(self: *AppSession, tab: *Tab, query: []const u8) bool {
    if (query.len == 0) return true;
    const term = tab.activePane().activeTerm();
    const name = workspaceLabel(tab);
    const branch = self.termGitBranch(term) orelse "";
    const folder = if (term.rt.observation.availability != .unavailable) term.rt.observation.cwd.items else "";
    return std.ascii.indexOfIgnoreCase(name, query) != null or
        std.ascii.indexOfIgnoreCase(branch, query) != null or
        std.ascii.indexOfIgnoreCase(folder, query) != null;
}

/// 가로 스와이프(delta_x→cols)를 커서 아래 pane의 탭 바 가로 스크롤로 바꾼다(#2b). 그 pane이 탭 넘침(has_scroll)이
/// 아니면 무동작. 클릭 ‹›와 같이 eff(=bm.scroll_cols, [0,max] clamp된 값) 기준이라 stale tab_scroll_cols가 자동
/// 정정된다(다음 렌더 tabLayout이 다시 clamp). natural 방향: 오른쪽 스와이프(cols>0)면 왼쪽 탭으로(scroll 감소).
pub fn scrollTabBarAt(self: *AppSession, x_px: f64, y_px: f64, cols: i32) void {
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return;
    for (leaf_rects.items) |lr| {
        if (!layout_math.pointInRect(x_px, y_px, lr.rect)) continue; // 커서가 이 pane(탭 바+터미널) 영역일 때만
        const pb = pane_ops.paneBar(self, lr.rect, lr.leaf) orelse return;
        const count = lr.leaf.terms.items.len;
        const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return;
        if (!m.has_scroll) return; // 탭이 안 넘침 — 가로 스크롤할 것 없음
        const eff = m.scroll_cols; // clamp된 현재 스크롤(stale 정정 기준 — 클릭 ‹›와 동일)
        const mag: u32 = @intCast(@abs(cols));
        lr.leaf.tab_scroll_cols = if (cols > 0) eff -| mag else eff + mag; // cols>0(오른쪽 스와이프)→왼쪽 탭(감소), cols<0→오른쪽(증가, 렌더서 [0,max] clamp)
        self.metal_dirty = true;
        return;
    }
}

pub fn captureWorkspaceTab(self: *AppSession, arena: std.mem.Allocator, tab: *Tab) !maru.session.workspace.Tab {
    var panes: std.ArrayList(maru.session.workspace.Pane) = .empty;
    for (tab.panes.items) |pane| {
        var surfaces: std.ArrayList(maru.session.workspace.Surface) = .empty;
        // FP16 §5.0: persisted 시퀀스는 **터미널 + 파일 Term**이다(브라우저는 계속 미영속). 파일 Term은
        // `pane` 줄의 `file-term` 반복 필드로 나가고, 그 index가 이 시퀀스 안의 위치다.
        var file_terms: std.ArrayList(maru.session.workspace.FileTerm) = .empty;
        // WP-P: 브라우저는 **현재 URL만** 싣는다. `insert_after`는 persisted 시퀀스 안 자리가 아니라 "앞의
        // persisted Term 수"라 기존 인덱스 값을 하나도 바꾸지 않는다 — 구버전 리더가 창을 폴백하지 않는 이유다
        // (docs/workspace-restore.md §WP-P).
        var browser_terms: std.ArrayList(maru.session.workspace.BrowserTerm) = .empty;
        var active_browser: ?usize = null;
        var persisted_index: usize = 0;
        for (pane.terms.items, 0..) |term, term_i| {
            if (term.file_entry) |entry| {
                // **diff는 persisted 시퀀스에 들지 않는다**(docs/editor-surface.md §3.5 — 저장하지 않는다).
                // 여기서 빼지 않고 writer에서만 빼면, 이미 부여한 index가 줄어든 총계와 안 맞아 복원 시
                // `index >= total`로 **그 창 전체가 fail-close**된다(리뷰에서 잡힌 결함). 자리를 아예 만들지
                // 않으므로 브라우저 `insert_after`도 같은 기준을 본다.
                if (entry.kind == .diff) continue;
                try file_terms.append(arena, .{
                    .index = persisted_index,
                    .kind = entry.kind,
                    .mode = entry.mode,
                    .path = try arena.dupe(u8, entry.path),
                });
                persisted_index += 1;
                continue;
            }
            if (term.kind == .web) {
                // 브라우저: 관측된 현재 URL을 싣는다. URL이 없거나(아직 아무것도 안 띄운 빈 패널) 주소창
                // navigate 상한을 넘으면(큰 data: URI — 한 줄 길이·512 필드 cap 위협) **저장하지 않는다**.
                if (self.webNavState(term.surfaceId())) |nav| {
                    if (nav.url.len > 0 and nav.url.len <= addr_nav_url_cap) {
                        if (pane.active_term == term_i) active_browser = browser_terms.items.len;
                        try browser_terms.append(arena, .{
                            .insert_after = persisted_index,
                            .url = try arena.dupe(u8, nav.url),
                        });
                    }
                }
                // 브라우저는 persisted 시퀀스에 안 든다(인덱스 불변).
                continue;
            }
            persisted_index += 1;
            self.refreshTermObservation(term, false, true);
            const observed_size = plausibleSurfaceSize(term.rt.observation.size) orelse
                plausibleSurfaceSize(term.surface.core.size) orelse
                // metadata unavailable fallback; SurfaceRuntime이 현재 layout grid로 동기화. 둘 다 못 믿으면
                // 기본 grid를 쓴다 — 복원이 창 크기에 맞춰 곧 다시 resize하므로 근사값이면 충분하다.
                terminal.Size.default;
            // P3-e3-5: host-backed Term은 host_id + runtime_id를 함께 저장한다. runtime_id 단독으로 저장하면 host가
            // 바뀐 뒤 같은 숫자 namespace를 잘못 attach할 수 있으므로 live capture는 둘 중 하나만 만들지 않는다.
            var runtime_host_id: []const u8 = "";
            var runtime_id: []const u8 = "";
            var runtime_state: maru.session.workspace.RuntimeState = .live;
            if (term.rt.ended_placeholder) {
                runtime_host_id = try arena.dupe(u8, term.rt.ended_runtime_host_id);
                runtime_id = try arena.dupe(u8, term.rt.ended_runtime_id);
                runtime_state = .ended;
            } else if (is_macos and term.surface.remote != null) {
                const rb = if (app_session_mod.app_remote_backend) |*remote| remote else return error.PersistentRuntimeUnavailable;
                const rid = rb.runtimeIdFor(term.rt.handle) orelse return error.PersistentRuntimeUnavailable;
                const runtime_host = rb.runtimeHostId(term.rt.handle) orelse return error.PersistentRuntimeUnavailable;
                runtime_host_id = try std.fmt.allocPrint(arena, "{x:0>32}", .{runtime_host});
                runtime_id = try arena.dupe(u8, &rid);
            }
            try surfaces.append(arena, .{
                // custom_name = 사용자 rename(owned, 없으면 ""), title = 자동 제목(OSC). 둘은 별도 필드로 저장한다.
                .custom_name = try arena.dupe(u8, term.surface.custom_name orelse ""),
                .title = try arena.dupe(u8, if (term.rt.observation.availability != .unavailable) term.rt.observation.window_title.items else ""),
                .cwd = try arena.dupe(u8, if (term.rt.observation.availability != .unavailable) term.rt.observation.cwd.items else ""),
                // §7 종료 placeholder는 spawn을 안 해 `surface.command`가 비어 있다 — 복원 입력에서 옮겨 둔 owned
                // 사본을 쓴다. title·cwd·grid는 생성 시 observation에 `.stale`로 심어서 위 두 줄이 그대로 읽는다.
                .command = try arena.dupe(u8, if (term.rt.ended_placeholder) term.rt.ended_command else (term.surface.command orelse "")),
                .runtime_host_id = runtime_host_id,
                .runtime_id = runtime_id,
                .runtime_state = runtime_state,
                .cols = observed_size.cols,
                .rows = observed_size.rows,
            });
        }
        // web-only pane(모든 Term이 web): surfaces가 비면 buildWorkspacePane이 error.EmptyPane로 **전체 복원을
        // 중단**한다 — 기본 셸 placeholder 1개를 넣어 그 pane이 기본 로그인 셸로 복원되게 한다(제목/cwd/command/
        // agent 전부 빈값 → restoreSpawn 기본 셸; 브라우저 콘텐츠는 어차피 미영속). 크기는 pane 첫 Term의 (sentinel여도
        // 유효한) core size에서 취한다.
        // FP16 §5.0: 조건이 "PTY 목록이 비었나"가 아니라 "**복원할 Term이 0인가**"다 — 파일 Term만 있는
        // pane에 엉뚱한 셸 placeholder가 끼면 복원 때 안 열었던 터미널이 생긴다.
        // WP-P: URL 있는 브라우저도 이제 복원되므로 **같은 이유로** 세어야 한다(docs/workspace-restore.md
        // §WP-P). 안 그러면 브라우저만 있던 pane이 브라우저 + 안 열었던 셸 탭으로 되살아난다.
        // URL 없는 브라우저만 있는 pane은 여전히 복원할 것이 0이라 종전대로 placeholder를 받는다.
        if (surfaces.items.len == 0 and file_terms.items.len == 0 and browser_terms.items.len == 0) {
            const c = &pane.terms.items[0].surface.core; // sentinel이어도 size 유효(1×1)
            try surfaces.append(arena, .{
                .custom_name = try arena.dupe(u8, ""),
                .title = try arena.dupe(u8, ""),
                .cwd = try arena.dupe(u8, ""),
                .command = try arena.dupe(u8, ""),
                .cols = c.size.cols,
                .rows = c.size.rows,
            });
        }
        // active_term 보정(리뷰 [0]): web Term을 스킵했으므로 저장 active_term은 verbatim이 아니라 **원래 active_term
        // 앞의 비-web(터미널) Term 수**로 remap한다. 활성이 터미널이면 그 압축 인덱스, 활성이 web이면 다음 터미널
        // 인덱스가 된다. buildWorkspacePane의 @min(active_term, terms.len-1)은 상한만 clamp하지 스킵 시프트는 remap
        // 안 하므로(그래서 [browser, termA, termB]서 termA 활성이면 복원 시 termB로 오포커스했다), 여기서 정확히 remap.
        // web-only pane(placeholder 1개)은 앞 터미널 0개라 0.
        // FP16 §5.0: remap 기준이 "앞의 비-web Term 수"에서 "**앞의 persisted Term 수**"(터미널 + 파일)로
        // 넓어진다. 활성이 브라우저면 다음 persisted Term을 가리키며, 이는 현행 web 활성 시 성질과 같다.
        var restored_active: usize = 0;
        for (pane.terms.items[0..pane.active_term]) |t| {
            // diff Term은 persisted 시퀀스에 없으므로 앞자리로도 세지 않는다(위 capture 규칙과 같은 기준).
            if (t.file_entry) |e| {
                if (e.kind != .diff) restored_active += 1;
                continue;
            }
            if (t.kind != .web) restored_active += 1;
        }
        // **범위로 clamp한다.** "활성이 브라우저면 다음 persisted Term을 가리킨다"는 **다음이 있을 때만** 참이다 —
        // 활성 브라우저가 pane의 **마지막** Term이면 위 카운트가 persisted_total과 같아져 `active-term`이 한 칸
        // 넘친다. 그러면 저장 파일이 §5.0 불변식(`active-term < persisted_total`)을 스스로 위반하고,
        // 같은 pane에 파일 Term이 하나라도 있으면 reader의 `validatePaneFileTerms`가 그 창을 **fail-close로
        // 강등해 파일 탭이 통째로 사라진다**(사용자 제보 "파일 유지 안 됨"의 재현 경로:
        // [터미널, 파일, 브라우저(활성·마지막)] → 저장 active-term=2 = persisted_total → 복원 시 창 폐기).
        // 파일 Term이 없던 pane에서 이 값이 여태 무해했던 건 그 검증이 `file_terms.len == 0`에서 조기 반환하고
        // buildWorkspacePane이 상한만 clamp했기 때문이다 — 즉 파일 Term 도입(FP16)이 잠재 결함을 깨운 자리다.
        const persisted_total = surfaces.items.len + file_terms.items.len;
        if (persisted_total > 0 and restored_active >= persisted_total) restored_active = persisted_total - 1;
        try panes.append(arena, .{
            .active_term = restored_active,
            .custom_name = try arena.dupe(u8, pane.custom_name orelse ""), // pane 사용자 rename(없으면 "")
            .surfaces = try surfaces.toOwnedSlice(arena),
            .file_terms = try file_terms.toOwnedSlice(arena),
            .browser_terms = try browser_terms.toOwnedSlice(arena),
            .active_browser = active_browser,
        });
    }
    var tree: std.ArrayList(maru.session.workspace.TreeNode) = .empty;
    try Model.flattenTree(arena, tab, tab.tree, &tree);
    return .{
        .active_pane = tab.active_pane,
        // 워크스페이스(탭)의 사용자 rename(없으면 ""). 예전엔 데이터 출처가 없어 reserved placeholder였으나, 이제
        // tab.custom_name이 출처다(docs/workspace-restore.md "사용자 지정 이름과 자동 제목").
        .custom_name = try arena.dupe(u8, tab.custom_name orelse ""),
        .pinned = tab.pinned,
        .background_color = tab.background_color,
        .accent_color = tab.accent_color,
        // 사이드바 그룹 시작 마커(위치 파생 — docs/sidebar-groups.md). null=그룹 아님(arena라 부분 실패 누수
        // 걱정 없음 — 캡처 arena가 통째 정리). group_collapsed는 그룹 시작 탭에만 의미.
        .group_start = if (tab.group_start) |g| try arena.dupe(u8, g) else null,
        .group_collapsed = tab.group_collapsed,
        .group_depth = tab.group_depth, // 중첩 그룹 깊이(SG5-3) — 그룹 시작 탭에만 의미(기본 1)
        .group_color = tab.group_color, // 그룹 공통 색(SG5-2) — 그룹 시작 탭에만 의미(무색=0)
        .local_pinned = tab.local_pinned, // 그룹-로컬 pin(GL §13) — 멤버 카드에만 의미(기본 false)
        .top_level = tab.top_level, // §2.1 재설계 서브파티션 마커(§14) — 비마커 leaf 카드에만 의미(기본 false)
        .tree = try tree.toOwnedSlice(arena),
        .panes = try panes.toOwnedSlice(arena),
    };
}

/// 컬렉션에 안 든 Tab을 teardown·해제한다(closeTab의 teardown 부분 — 단, tabs/surface_ptrs는 호출자가 관리).
/// 트리(tab.tree)가 세팅된 '완성된' 탭에만 쓴다(buildWorkspaceTab은 자기 granular errdefer로 미완성을 정리).
pub fn destroyTabStandalone(self: *AppSession, tab: *Tab) void {
    // restore 실패/교체처럼 closeTab을 통하지 않는 teardown도 raw pane/split 및 sidebar payload의 수명 장벽이다.
    self.cancelPointerGesture();
    // rename 대상이 이 워크스페이스(또는 그 안 pane/Term)·이 탭이 시작하는 그룹이면 비운다 — pane/Term은 아래
    // destroyPane/destroyTerm 가드가 처리하지만, 워크스페이스·그룹 rename은 여기서. teardown 중이라 직접 null.
    // (renamingGroup은 `r.group == tab`의 **포인터 비교**(1984)라 group_start 유무와 무관하다 — 마커 승계로 group_start가
    //  다음 탭으로 넘어갔어도, 이 *Tab이 편집 대상이면 true다. 이 탭이 지금 파괴되므로 편집을 취소해 dangling *Tab을 안 남긴다.)
    if (self.renamingWorkspace(tab) or self.renamingGroup(tab)) {
        self.rename = null;
        self.rename_input.clear();
    }
    // 컨텍스트 메뉴 대상이 이 워크스페이스**나 이 탭이 시작하는 그룹**이면 메뉴를 닫고 대상을 비운다(stale 포인터
    // 방지). 둘 다 *Tab을 들므로 이 탭이 파괴되면 dangling → 메뉴 accept 시 startRename UAF(code-review #1). 위
    // renamingGroup 가드와 같은 방식으로 .group 대상도 클리어한다(마커 승계로 group_start가 넘어갔어도 *Tab 자체가
    // 파괴되므로 대상 포인터를 반드시 비운다). pane/Term은 아래 destroyPane/destroyTerm가 처리.
    if (self.context_menu_target) |t| {
        const hit = switch (t) {
            .workspace => |w| w == tab,
            .group => |g| g == tab,
            else => false,
        };
        if (hit) {
            self.context_menu_target = null;
            self.chrome_host.context_menu.hide();
        }
    }
    for (tab.panes.items) |pane| pane_ops.destroyPane(self, pane);
    // 트리를 통째 해제하기 전에, divider_drag가 이 트리 소속 split이면 표적 null(다른 탭 트리를 가리키면 유지 —
    // 무관한 탭 close가 진행 중 divider 드래그를 안 끊는다). collapse 경로의 invalidateForFreedSplit과 같은 규율.
    if (self.divider_capture_split) |captured| {
        if (PaneTree.containsSplit(tab.tree, captured)) pane_ops.endDividerCapture(self);
    }
    if (tab.custom_name) |n| self.allocator.free(n); // 워크스페이스 사용자 rename(owned) 해제
    if (tab.group_start) |g| self.allocator.free(g); // 사이드바 그룹 시작 마커(owned) 해제
    PaneTree.deinit(self.allocator, tab.tree); // heap split 노드 해제(leaf surface는 destroyPane가 이미)
    tab.panes.deinit(self.allocator);
    self.allocator.destroy(tab);
}

/// 모델 Tab → 완성된 *Tab(panes + split 트리). pane들을 먼저 만들고(각 첫 surface로 spawn + 나머지 Term 추가),
/// 트리를 모델 preorder대로 직접 짓는다(leaf 인덱스 → 그 pane, split → 새 PaneTree.Split). 부분 실패는 granular
/// errdefer로 정리(트리는 아직 미세팅이라 destroyTabStandalone 안 씀). capacity 예약으로 append를 무실패화.
pub fn buildWorkspaceTab(self: *AppSession, m: maru.session.workspace.Tab) !*Tab {
    if (m.panes.len == 0) return error.EmptyTab;
    const tab = try self.allocator.create(Tab);
    errdefer self.allocator.destroy(tab);
    tab.* = .{};
    errdefer tab.panes.deinit(self.allocator);
    errdefer for (tab.panes.items) |p| pane_ops.destroyPane(self, p);

    try tab.panes.ensureTotalCapacity(self.allocator, m.panes.len);
    for (m.panes) |pm| tab.panes.appendAssumeCapacity(try pane_ops.buildWorkspacePane(self, pm));

    // 트리 빌드 — 새로 만든 split 노드를 추적해 에러 시 전부 해제(트리 미완성이라 PaneTree.deinit 못 씀).
    // capacity를 split 노드 수만큼 미리 잡아 추적 append를 무실패화한다: create 직후 append가 OOM이면 그
    // split이 추적되지 않아 누수되므로, 예약된 무실패 append로 create↔추적 사이의 빈틈을 없앤다.
    var split_count: usize = 0;
    for (m.tree) |n| switch (n) {
        .split => split_count += 1,
        .leaf => {},
    };
    var splits: std.ArrayList(*PaneTree.Split) = .empty;
    defer splits.deinit(self.allocator);
    try splits.ensureTotalCapacity(self.allocator, split_count);
    errdefer for (splits.items) |s| self.allocator.destroy(s);
    // 트리 leaf↔pane 1:1 검증용(corruption graceful). 손상 파일이 같은 pane을 두 leaf로 참조하면 같은 *Pane이
    // 트리에 두 번 들어가 close 시 removeLeaf가 첫 매치만 접고 destroyPane이 free → 두 번째 leaf가 dangling(UAF).
    // 미참조 pane은 보이지 않는 라이브 셸(고아)이 된다. 각 pane이 정확히 1회 참조되는지 확인해 둘 다 막는다.
    const used = try self.allocator.alloc(bool, tab.panes.items.len);
    defer self.allocator.free(used);
    @memset(used, false);
    var idx: usize = 0;
    const root = try Model.buildTreeNode(self.allocator, tab.panes.items, m.tree, &idx, &splits, used);
    if (idx != m.tree.len) return error.MalformedTree; // preorder를 다 안 소비했다(노드 수 불일치)
    for (used) |u| if (!u) return error.MalformedTree; // 트리가 참조 안 한 고아 pane(보이지 않는 라이브 셸) 차단
    tab.tree = root;
    tab.active_pane = @min(m.active_pane, tab.panes.items.len - 1);
    // 그룹 시작 마커(owned) 복원 — fallible dupe라 errdefer로 보호한다. destroyTabStandalone의 errdefer는
    // custom_name/group_start 같은 스칼라 owned 문자열을 정리하지 않으므로(위 errdefer는 panes·tab 구조만),
    // 이어지는 custom_name dupe가 OOM으로 실패해도 이 마커가 누수되지 않게 여기서 명시 errdefer를 건다.
    // group_collapsed는 non-fallible 대입. null=그룹 아님(빈 문자열도 유효한 "이름 없는 그룹").
    tab.group_start = if (m.group_start) |g| try self.allocator.dupe(u8, g) else null;
    errdefer if (tab.group_start) |g| self.allocator.free(g);
    tab.group_collapsed = m.group_collapsed;
    tab.group_depth = m.group_depth; // 중첩 그룹 깊이 복원(SG5-3) — 기본 1, projectRows가 gap 클램프
    tab.group_color = m.group_color; // 그룹 공통 색 복원(SG5-2) — 무색=0 폴백
    tab.local_pinned = m.local_pinned; // 그룹-로컬 pin 복원(GL §13) — 멤버 카드 subtree-로컬 float 상태(기본 false)
    tab.top_level = m.top_level; // §2.1 재설계 서브파티션 마커 복원(§14) — 비마커 leaf 카드의 최상위 복귀 신호(기본 false)
    // 워크스페이스 사용자 rename 복원 — 마지막 fallible 단계. OOM 시 위 errdefer(panes·tab·group_start)가 정리한다.
    tab.custom_name = try self.dupeCustomName(m.custom_name);
    tab.pinned = m.pinned; // 위치 고정 복원
    tab.background_color = m.background_color; // 카드 배경 tint 복원
    tab.accent_color = m.accent_color; // 카드 좌측 accent 막대색 복원
    return tab;
}

/// 호버 중인 per-pane 탭을 갱신한다. 바뀌면 재드로우한다(호버 ✕가 생기거나 사라진다). 같은 탭이면 무동작.
pub fn setHoveredTab(self: *AppSession, tab: ?TabRef) void {
    if (tabRefEql(self.hovered_tab, tab)) return;
    self.hovered_tab = tab;
    self.metal_dirty = true;
}

/// 마우스가 어느 pane의 탭 바 위면 (그 pane, 탭 index)으로 호버 탭을 갱신하고, 아니면 null로 비운다. 좌측
/// grip+라벨 세그먼트면 grip(grab 커서). 활성 탭 leaf rect를 펴 각 pane 바를 hit-test한다. hoverCursor이 호출한다.
pub fn updateHoveredTab(self: *AppSession, x_px: f64, y_px: f64) BarHover {
    var next: ?TabRef = null;
    var next_scroll: ?ScrollRef = null;
    var on_bar = false; // 탭 바 위 여부(탭 영역) — hoverCursor가 pointingHand(클릭 가능) 판정에 쓴다
    var on_grip = false; // 좌측 grip+라벨 세그먼트 위 여부 — grab(openHand) 커서
    // 매 이동마다 새 ArrayList를 안 만들고 재사용 scratch에 레이아웃을 다시 깐다(할당 churn 제거, 결과는 최신).
    const leaf_rects = &self.hover_leaf_scratch;
    leaf_rects.clearRetainingCapacity();
    if (activeTabLeafRects(self, self.allocator, self.termRect(), leaf_rects)) |_| {
        for (leaf_rects.items) |lr| {
            const pb = pane_ops.paneBar(self, lr.rect, lr.leaf) orelse continue;
            if (layout_math.pointInRect(x_px, y_px, pb.full)) {
                on_bar = true; // 탭 바 위 — 탭·‹/›·+·pane 포커스 모두 클릭 가능 영역
                // 좌측 grip+라벨 영역 = 드래그 손잡이(grab 커서). 탭 호버 아님(탭0 ✕ 오표시 방지) — 그 뒤 탭 영역만 hit-test.
                if ((pb.grip_cols > 0 or pb.label_cols > 0) and x_px < @as(f64, @floatFromInt(pb.tabs.x))) {
                    on_grip = true;
                    break;
                }
                const count = lr.leaf.terms.items.len;
                const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse break; // 메트릭 불가(초소형 바) → 호버 없음
                if (m.inScrollLeftZone(x_px)) { // #5b: ‹ 버튼 호버 — 탭 호버 아님
                    next_scroll = .{ .pane = lr.leaf, .right = false };
                    break;
                }
                if (m.inScrollRightZone(x_px)) { // #5b: › 버튼 호버
                    next_scroll = .{ .pane = lr.leaf, .right = true };
                    break;
                }
                if (m.inPlusZone(x_px)) break; // "+" 버튼 위 — 탭 호버 아님(마지막 탭에 ✕ 오표시 방지)
                next = .{ .pane = lr.leaf, .tab = m.tabIndex(count, x_px) };
                break;
            }
        }
    } else |_| {}
    setHoveredTab(self, next);
    scroll_ops.setHoveredScroll(self, next_scroll);
    return if (on_grip) .grip else if (on_bar) .tabs else .none;
}

/// 활성 탭 강조(rich) — **연결형 cutout**: 활성 탭을 터미널 본문색(bg=theme.background)으로 채워 아래 본문과
/// 이어져 보이게 하고(strip에서 도려낸 듯), 하단에 굵은 테마 accent 언더바(active/focus indicator, 탭 seg 폭)를 얹는다.
/// 옛 "평평한 약한 배경(sidebarActiveBg)"을 본문색으로 바꿔 깊이(strip↔본문)를 만든다(U-tab2). 배경·언더바 둘 다
/// layer 2(셀 part1 제목 아래)라 본문색 quad가 하단 하이라인(appendTabBarUnderline)을 활성 탭 구간에서 덮어 "연결"이
/// 끊기지 않는다. segOf 픽셀 경계로 hit-test·제목 glyph와 정합(§6 단일 소스). overflow 탭이면 무동작.
/// `space.tab_active_style`(chrome.tab-style §7)로 분기: **connected**=본문색 cutout(바 전체) + 앰버 언더바, **underline**=
/// 앰버 언더바만(bg fill 없음 — strip 그대로), **pill**=둥근 inset 캡슐을 **lifted 회색(`lifted_bg`)으로 채워** 띄우고 옅은 밝은
/// 테두리만(실제 Warp 벤치마킹 — 밝은 fill로 올린다, 어두운 외곽선 아님). bg=본문색(connected cutout), lifted_bg=strip보다 밝은
/// 색(pill fill·포커스 밝기), accent=포커스 앰버/비포커스 muted(connected·underline 언더바). 세 스타일 모두 **세그먼트 기하
/// 불변**이라 hit-test/✕/드래그 공통(스타일은 세그먼트 안 fill만 바꿈, §5.4). 모두 layer 2(per-frame, dropQuadsByLayer(2)가 비움). tui는 tabbarHighlightCell 셀 밴드.
pub fn appendActiveTabHighlight(self: *AppSession, m: chrome.components.tabbar.Metrics, tab_index: usize, bg: u32, lifted_bg: u32, accent: u32, space: chrome.tokens.Spacing, border: chrome.tokens.Border) void {
    const seg = m.segOf(tab_index);
    if (seg.end_col <= seg.start_col) return; // overflow(탭 영역 밖, 안 보이는) 탭
    const x: f32 = @floatCast(seg.start_px);
    const w: f32 = @floatCast(seg.end_px - seg.start_px);
    const by: f32 = @floatFromInt(m.bar_y);
    const bh: f32 = @floatFromInt(m.bar_h);
    switch (space.tab_active_style) {
        .connected, .underline => {
            const uw: f32 = @min(@as(f32, @floatFromInt(space.tab_underbar_px)), bh); // 바보다 두꺼우면 바 높이로 clamp(언더바가 바 위로 안 샘 — #496 리뷰)
            if (space.tab_active_style == .connected) self.appendSolidQuad(x, by, w, bh, bg, 2); // 본문색 cutout(strip 하이라인을 덮음). underline은 배경 fill 생략
            self.appendSolidQuad(x, by + bh - uw, w, uw, accent, 2); // 하단 테마 accent/muted 언더바(active/focus indicator, 탭 폭)
        },
        .pill => {
            // 떠 있는 pill(실제 Warp 벤치마킹): 바 위아래로 inset한 둥근 캡슐을 **strip보다 밝은 lifted 회색**(`lifted_bg`)으로
            // 채워 "올라온 알약"으로 보이게 하고(Warp는 어두운 외곽선이 아니라 밝은 fill로 띄운다), 옅은 더 밝은 hairline 테두리만
            // 얹는다(Warp의 faint 테두리). 포커스 구분은 fill 밝기(focus=sidebarActiveBg / 비포커스=sidebarHoverBg) — 언더바·앰버 테두리 아님.
            const inset: f32 = @min(@as(f32, @floatFromInt(space.tab_pill_inset_px)), bh / 2.0); // inset>바높이/2면 clamp(ph≥0)
            const radius: f32 = @floatFromInt(space.corner_radius_px);
            const bw: f32 = @floatFromInt(border.line_thickness_px);
            const ph: f32 = @max(bh - 2.0 * inset, 1.0);
            self.gpu_quads.append(self.allocator, .{
                .x = x,
                .y = by + inset,
                .w = w,
                .h = ph,
                .corner_radii = .{ radius, radius, radius, radius },
                .border_widths = .{ bw, bw, bw, bw },
                .fill_color0 = lifted_bg,
                .fill_color1 = lifted_bg,
                .border_color = blendRgb(lifted_bg, 0xFFFFFF, 0x28), // lifted_bg를 흰색으로 ~16% 블렌딩 — Warp식 옅은 밝은 테두리(가라앉은 앰버 외곽선 폐기)
                .gradient_kind = 0,
                .layer = 2,
            }) catch {};
        },
    }
}

/// 탭바 하단 구분선(divider 색)을 layer 2 GpuQuad로 — 탭바를 터미널 콘텐츠와 시각 분리(rich). 활성 탭 영역은
/// 활성 밴드(나중 append)가 위에 덮어 자연히 밴드 색이 되고, 비활성 영역엔 divider 구분선이 보인다.
/// 두께는 `border.line_thickness_px` 토큰(rich 2px)을 받는다 — 1px GpuQuad는 SDF AA(maru_quad_fragment
/// 78행 `cov=1-smoothstep(-aa,aa,d)`)가 1px-tall(half_size.y=0.5)에서 cov≈0.84로 옅게 그려 선이 흐리고
/// HiDPI 분수 스케일에서 떨린다. 형제 선 헬퍼(appendHorizontalLine)가 셀+reserved ~2px를 쓰는 것과 같은
/// 이유로 토큰 두께(≥2px)면 중심 행이 cov≈1로 선명하다. 두께만큼 바 하단 안쪽에 둔다(바 위로 안 새게).
pub fn appendTabBarUnderline(self: *AppSession, bar: maru.session.SplitRect, thickness: u32) void {
    self.appendSolidQuad(@floatFromInt(bar.x), @floatFromInt(bar.y + bar.h -| thickness), @floatFromInt(bar.w), @floatFromInt(thickness), pane_ops.dividerColor(self), 2);
}

/// 이 탭 제목이 running 마커로 시작하는가. `flagPrefixedLabel`이 붙인 prefix를 되읽는 단일 판정이다 —
/// 마커를 셀에, 제목을 measured에 보내려면 둘을 같은 기준으로 갈라야 한다.
pub fn tabTitleRunningMarker(title: []const u8) bool {
    return std.mem.startsWith(u8, title, agentFlagUtf8());
}

/// 마커·구분 공백을 뗀 제목 본문. 마커가 없으면 원본 그대로.
pub fn tabTitleBody(title: []const u8) []const u8 {
    if (!tabTitleRunningMarker(title)) return title;
    const rest = title[agentFlagUtf8().len..];
    return if (std.mem.startsWith(u8, rest, " ")) rest[1..] else rest;
}
