//! 도크(dock) 일반 — view 전환·레이아웃·크기, 도크 리스트 스크롤바, 포커스 큐, SCM 뷰 스크롤.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F5).
//! 도크 **안에 사는 내용물**은 이미 각자의 그룹으로 갔다 — 에이전트 세션 기록은 `agent_dock.zig`(F1),
//! 파일 탐색기·패널은 `file_panel.zig`(F2). 여기 남은 것은 그 내용물을 담는 **그릇**이다.
//!
//! 그래서 이 그룹은 작다(35개·484줄). 대신 pub화가 4개뿐이라 지금까지 중 비용 대비 효율이 가장 좋다.
//!
//! 경계를 잡을 때 이름이 `dock`인데 내용이 file entry인 넷(`assignDockSurfaceIds`·`dockHasLiveSurface`·
//! `refreshDockListScrollbar`·`requeuePendingDockFocus`)은 여기 두지 않고 `file_panel.zig`로 보냈다 —
//! 파일 패널이 도크 안에 살기 때문에 생긴 이름이고, 본문은 `fileEntries`·`file_tree_perf_counters`를 만진다.
//! F1의 `dockHasContent`와 같은 판정이다(이름이 아니라 내용으로 소유를 정한다).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const dock_panel = maru.session.dock_panel;
const dock_layout = maru.session.dock_layout;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const git_ops = @import("git.zig");
const agent_ops = @import("agent.zig");
const scroll_ops = @import("scroll.zig");
const sidebar_ops = @import("sidebar.zig");
const tab_ops = @import("tab.zig");
const dock_list_scrollbar_min_thumb_px = app_session_mod.dock_list_scrollbar_min_thumb_px;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const dock_list_scroll_drag_payload = app_session_mod.dock_list_scroll_drag_payload;
const dock_list_scrollbar_inset_px = app_session_mod.dock_list_scrollbar_inset_px;
const dock_view_bar = app_session_mod.dock_view_bar;
const icons = app_session_mod.icons;
const AgentSessionArchiveSmokeProbe = app_session_mod.AgentSessionArchiveSmokeProbe;
const scm_dock_ops = @import("scm_dock.zig");
const image_gallery_ops = @import("image_gallery.zig");
const agent_dock = app_session_mod.agent_dock;
const dock_list_scroll_ids = app_session_mod.dock_list_scroll_ids;
const dock_list_scroll_max_entries = app_session_mod.dock_list_scroll_max_entries;
const dock_list_scrollbar_width_px = app_session_mod.dock_list_scrollbar_width_px;
const layout_math = app_session_mod.layout_math;
const scrollbar_alpha_full = app_session_mod.scrollbar_alpha_full;
const DockListScroll = AppSession.DockListScroll;
const RestoredFileEntries = AppSession.RestoredFileEntries;
const usizeOptEql = AppSession.usizeOptEql;
const file_panel_ops = @import("file_panel.zig");
const pane_ops = @import("pane.zig");
const agent_dock_ops = @import("agent_dock.zig");

pub fn appendDockSurfaceIds(self: *AppSession, out: []u64, start: usize) usize {
    var n = start;
    if (!self.dock_initialized) return n;
    var entry_it2 = file_panel_ops.fileEntries(self);
    while (entry_it2.next()) |entry| if (entry.surface_id != 0) {
        if (n < out.len) out[n] = entry.surface_id;
        n += 1;
    };
    return @min(n, out.len);
}

pub fn beginDockListScrollbarGesture(self: *AppSession, x_px: f64, y_px: f64) bool {
    buildDockListScrollTree(self);
    const geometry = dockListScrollbarGeometry(self) orelse return false;
    if (!geometry.trackContains(x_px, y_px)) return false;
    // down이 thumb인지 track 빈 곳인지, 잡은 지점을 어떻게 기억하는지, 점프 후 기하가 어떻게 되는지는
    // `scroll_area.Drag`가 안다. host는 published 기하를 건네고 점프 결과만 적용한다.
    if (self.dock_list_scroll_drag.begin(geometry, x_px, y_px)) |jumped| setDockListScrollOffsetPx(self, jumped);
    const snapshot = file_panel_ops.fileTreeScrollTree(self);
    if (snapshot.entries.len == 0) return false;
    _ = chrome.ui.interaction.dispatch(&self.scrollbar_interaction, snapshot, .{
        .phase = .down,
        .x_px = x_px,
        .y_px = y_px,
        .timestamp_ns = 0,
        .generation = snapshot.generation,
    }) catch return false;
    if (self.scrollbar_interaction.capture == null) {
        self.dock_list_scroll_drag.end();
        return false;
    }
    // 옛 경로는 `beginPointerGesture`가 앞선 gesture를 취소했다. 축이 갈렸어도 규율은 같다.
    sidebar_ops.clearSidebarDragPreview(self);
    self.pointer_gesture_owner = .none;
    self.dock_list_scroll_drag_owner = .{
        .root_generation = self.file_tree.rootGeneration(),
        .projection_generation = self.file_tree_projection_generation,
    };
    self.scrollbar_drag_target = .dock_list;
    self.dock_list_scrollbar_idle_ticks = 0;
    self.metal_dirty = true;
    return true;
}

pub fn queuePendingDockFocus(self: *AppSession, entry: *const dock_panel.Entry) void {
    self.pending_dock_focus = .{
        .entry_id = entry.id,
        .expected_surface_id = if (entry.surface_id == 0) null else entry.surface_id,
        .dock_async_epoch = self.dock_async_epoch,
        .request_or_entry_revision = entry.editor_revision,
    };
    self.pending_dock_focus_action = true;
}

/// 도크 접기/펴기 토글 호버 상태 — 바뀔 때만 재렌더. 헤더 아이콘과 달리 rebuildSidebar 불요(도크 크롬은 매 프레임
/// collectShaped로 재빌드되고 호버 배경도 그 패스에서 dock_toggle_hovered를 읽어 그린다), metal_dirty만 세운다.
pub fn setDockToggleHovered(self: *AppSession, hovered: bool) void {
    if (self.dock_toggle_hovered == hovered) return;
    self.dock_toggle_hovered = hovered;
    self.metal_dirty = true;
}

/// 도크를 열고 그 뷰로 바꾼다. **레이아웃 후속을 빠뜨리지 않는 것이 요점이다** — 필드만 세우면 도크는
/// 나타나는데 pane rect가 옛 폭 그대로라 다음 resize 전까지 어긋난다. 특히 이미 그 뷰였으면
/// `setDockView`가 조기 반환하므로 그쪽 resize 경로도 안 탄다. 기존 opener
/// (`activateFilePanelDockControl`)가 하는 후속과 같은 것을 한다.
pub fn openDockTo(self: *AppSession, view: dock_panel.View) void {
    const persisted_changed = !self.dock.presented or self.dock.collapsed or self.dock.view != view;
    self.dock.presented = true;
    self.dock.collapsed = false;
    enterDockView(self, view);
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    self.last_resize_size = null;
    if (persisted_changed) self.workspaceChanged(.dock);
}

/// 탐색기 스크롤바를 **공용 paint 경로**로 그린다(SV2b). 발행된 tree를 `ui_paint`가 quad op으로
/// 옮기고 `chrome_draw_lowering`이 GpuQuad로 내린다 — 도크와 같은 경로이며, 모양·색·radius를 host가
/// 손으로 다시 만들지 않는다.
///
/// **fade alpha만 여기서 얹는다.** tree에 실으면 매 프레임 달라져 entry·action 배열을 다시 복사하고
/// reconcile을 다시 돈다(docs/scroll-area.md §7). 그래서 선언은 불변으로 두고, paint가 만든 op의
/// alpha를 이 자리에서 덮는다.
pub fn appendDockListScrollbar(self: *AppSession) void {
    const snapshot = file_panel_ops.fileTreeScrollTree(self);
    if (snapshot.entries.len == 0) return;
    const emphasized = self.dock_list_scrollbar_hovered or scroll_ops.scrollbarCaptureActive(self);
    const alpha: u8 = if (emphasized) scrollbar_alpha_full else scroll_ops.scrollbarAlpha(self, self.dock_list_scrollbar_idle_ticks);

    var ops: [dock_list_scroll_max_entries]chrome.draw.Op = undefined;
    const tokens = self.buildChromeTokens();
    const draws = chrome.ui.paint.paint(snapshot, self.scrollbar_interaction, &tokens, .sidebar, .{ .ops = &ops }) catch {
        if (self.file_tree_perf_counters) |counters| counters.allocator_calls += 1;
        return;
    };
    for (ops[0..draws.ops.len]) |*op| switch (op.*) {
        .quad => |*q| q.alpha = alpha,
        else => {},
    };
    const before = self.gpu_quads.items.len;
    // rect는 이미 backing 좌표다(`buildDockListScrollTree`가 옮겼다) — origin을 다시 더하지 않는다.
    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, 0, 0, &self.gpu_quads, 2);
    if (self.file_tree_perf_counters) |counters| counters.thumb_quads += @intCast(self.gpu_quads.items.len - before);
}

pub fn dockVisible(self: *const AppSession) bool {
    return self.dock_initialized and !self.chrome_minimal and self.dock.presented and !self.dock.collapsed;
}

pub fn dockGeometry(self: *const AppSession) dock_layout.Geometry {
    return dock_layout.compute(.{
        .backing_width_px = self.backing_width_px,
        .backing_height_px = self.backing_height_px,
        .sidebar_width_px = self.sidebar_width_px,
        // 도크와 터미널이 **같은 상단 띠**에서 시작한다. 예전에는 도크만 28pt 고정 safety band를 따로
        // 받았는데, 그러면 폰트를 키우거나 사이드바를 접어 `titlebar_strip_px`가 움직일 때 두 상단 바의
        // 시작선이 갈렸다 — 아래 경계선(`chromeBarHeightPx`)을 맞춰 놔도 시작이 다르면 여전히 어긋나
        // 보인다(사용자 보고). 28pt는 그 띠의 **하한**으로 `computeTitlebarStripPx` 안에 그대로 살아 있고
        // (접힘이면 신호등 세로 높이인 30pt), 뷰와 무관하다는 계약도 그대로다.
        .titlebar_height_px = self.titlebar_strip_px,
        .status_bar_px = self.statusBarHeightPx(),
        .cell_width_px = self.cell_width_px,
        .cell_height_px = self.cell_height_px,
        .scale_milli = self.scale_milli,
        .divider_px = pane_ops.dividerThicknessPx(self),
        // view bar는 **도크의 chrome**이지 터미널의 chrome이 아니다. 그래서 예전 explorer 경로처럼
        // `paneBarHeightPx`(terminal cell 높이 + padding)를 받지 않는다 — 그 식은 뷰마다 아이콘 줄이
        // 오르내리게 했고(사용자 보고: 실측 53px ↔ 80px) 터미널 폰트가 도크 기하를 정하게 만든다
        // (layering-and-portability 금지).
        //
        // 대신 두 바가 **공유 logical token**(`space.bar_height_pt`)을 통해 같은 높이를 낸다 —
        // docs/agent-session-list-layout.md §2.1.3이 "정렬이 필요하면 terminal 쪽이 아니라 두 chrome이 공유하는
        // logical token을 새로 만든다"고 예고한 해법이다. 방향이 반대라는 점이 핵심이다: 도크가 터미널
        // 식을 물려받는 게 아니라, 터미널 탭 바가 도크가 쓰던 40pt를 함께 본다. 모든 뷰가 이 값 하나를
        // 쓰므로 뷰 전환도, 터미널 폰트 변경도 아이콘 위치를 움직이지 않는다.
        .view_bar_px = self.chromeBarHeightPx(),
        .side = if (self.dock_initialized) self.dock.side else .right,
        .size_pt = if (self.dock_initialized) self.dock.size else 0,
        .visible = dockVisible(self),
        .view = if (self.dock_initialized) self.dock.view else .explorer,
    });
}

pub fn setHoveredDockViewSlot(self: *AppSession, slot: ?usize) void {
    if (usizeOptEql(self.dock_view_hovered_slot, slot)) return;
    self.dock_view_hovered_slot = slot;
    self.metal_dirty = true;
}

/// 활성 탭을 바꾼다(`app_window.selectTab`). 성공하면 활성 탭이 바뀌었으니 재드로우를 위해
/// metal_dirty를 세우고 true. 범위 밖 index면 false(활성 불변). 입력/렌더는 activeSurface가
/// active_tab을 따라가므로 이것만으로 라우팅이 바뀐다.
/// 워크스페이스를 바꾸면 보이지 않게 된 파일의 publish 대기 barrier를 버린다 — 남겨 두면 새 화면의
/// 입력을 그 파일이 계속 소유한다(§3.4).
pub fn dropPendingDockFocusIfHidden(self: *AppSession) void {
    const pending = self.pending_dock_focus orelse return;
    // 판정과 **같은 기준**(실제 가시성)을 쓴다 — 옛 탭 단위 기준은 같은 pane의 터미널 탭으로 옮겨간
    // 상태를 "보인다"로 쳐서, 소유는 false인데 취소도 안 되는 orphan owner를 남겼다(code-review max).
    if (file_panel_ops.fileEntryForIdConst(self, pending.entry_id)) |entry| {
        if (file_panel_ops.fileEntryIsFocusTarget(self, entry)) return;
    }
    cancelPendingDockFocus(self);
    if (self.focus_owner == .dock_pending) {
        self.focusWorkspaceInput();
        self.workspace_focus_pending = true;
    }
}

pub fn dockListScrollbarMetrics(self: *const AppSession) chrome.ui.scroll_area.ScrollbarMetrics {
    _ = self;
    return .{
        .width_px = dock_list_scrollbar_width_px,
        .inset_x_px = dock_list_scrollbar_inset_px,
        .min_thumb_px = dock_list_scrollbar_min_thumb_px,
    };
}

pub fn pendingDockEntryOwnsInput(self: *const AppSession) bool {
    const owned_entry_id = switch (self.focus_owner) {
        .dock_pending => |entry_id| entry_id,
        else => return false,
    };
    const pending = self.pending_dock_focus orelse return false;
    if (pending.dock_async_epoch != self.dock_async_epoch) return false;
    // FP16: barrier가 그룹이 아니라 pending entry 자체를 대조한다. 옛 runtime_id 대조와 같은 강도로,
    // owner가 다른 파일을 가리키면 fail-close한다.
    if (owned_entry_id != pending.entry_id) return false;
    // 옛 `.dock_group`은 **보이는** group에 묶여 있었다. 같은 강도를 유지하려면 그 파일이 지금 키를
    // 받을 자리, 즉 **활성 탭의 활성 pane의 활성 Term**이어야 한다. "활성 워크스페이스에 있다"로는
    // 같은 pane의 터미널 탭이나 다른 split pane에서 타이핑하는 동안에도 barrier가 키를 삼킨다.
    // surface_id로 보지 않는 이유: 아직 sid가 없는(publish 전) entry가 이 barrier의 주 대상이다.
    const owner_entry = file_panel_ops.fileEntryForIdConst(self, pending.entry_id) orelse return false;
    if (!file_panel_ops.fileEntryIsFocusTarget(self, owner_entry)) return false;
    const entry = blk: {
        var it = file_panel_ops.fileEntriesConst(self);
        while (it.next()) |e| {
            if (e.id == pending.entry_id) break :blk e.*;
        }
        return false;
    };
    if (entry.editor_revision != pending.request_or_entry_revision) return false;
    return if (pending.expected_surface_id) |surface_id|
        entry.surface_id == surface_id
    else
        entry.surface_id == 0;
}

/// 뷰 바 오른쪽 끝의 동작 버튼. **뷰마다 다르다** — 지금은 탐색기에만 있다(소스 컨트롤은 자기 머리 줄에
/// 이미 동작을 들고 있고, 세션 목록은 새로 고칠 대상이 없다).
pub const DockAction = enum {
    /// 루트를 다시 읽는다. watcher 가 놓친 변경(원격 마운트·권한)이나 사용자가 밖에서 만든 파일을 위해서다.
    refresh,
    /// 루트만 남기고 펼친 폴더를 모두 접는다. 깊이 들어간 트리에서 돌아오는 유일한 수단이 하나씩 접기뿐이면
    /// 사용자는 도크를 닫았다 연다(그러면 선택도 잃는다).
    collapse_all,
};

const explorer_actions = [_]DockAction{ .refresh, .collapse_all };

/// 한 뷰가 가질 수 있는 동작 수의 상한. 렌더가 스택 버퍼를 잡는 근거라 목록이 늘면 **여기부터** 걸린다
/// (`dockActionGlyphs` 가 이 크기로 단언한다).
pub const max_dock_actions: usize = explorer_actions.len;

/// 지금 뷰의 동작 목록. 순서가 곧 왼쪽부터의 자리라, 여기 순서를 바꾸면 버튼 자리가 바뀐다.
pub fn dockActions(self: *const AppSession) []const DockAction {
    if (!dockVisible(self)) return &.{};
    return switch (self.dock.view) {
        .explorer => &explorer_actions,
        else => &.{},
    };
}

/// 동작 버튼의 glyph. **그림은 자산 이름으로 고른다**(codepoint 리터럴 금지 — docs/chrome-strategy.md §9.7).
/// `reset` 은 octicon sync(양방향 화살표)라 새로 고침 그림이고, 이미 세션·소스 컨트롤 도크가 같은 뜻으로 쓴다.
/// 전체 접기는 **전용 자산**이다 — chevron 하나(`>`)를 재사용해 봤더니 "다음/펼치기"로 읽혀(방향이 반대다)
/// 접기라는 뜻이 서지 않았다. 마주 보는 chevron 둘이 "모은다"를 그린다.
pub fn dockActionGlyph(action: DockAction) u21 {
    return switch (action) {
        .refresh => icons.codepointFit(.reset, .tight),
        .collapse_all => icons.codepoint(.collapse_all),
    };
}

/// 지금 뷰의 동작 glyph 를 호출자 버퍼에 담아 돌려준다. 렌더가 자기 표를 들면 동작이 늘 때 한쪽만 갱신된다.
pub fn dockActionGlyphs(self: *const AppSession, buf: *[max_dock_actions]u21) []const u21 {
    const actions = dockActions(self);
    std.debug.assert(actions.len <= buf.len);
    for (actions, 0..) |action, index| buf[index] = dockActionGlyph(action);
    return buf[0..actions.len];
}

pub fn setHoveredDockAction(self: *AppSession, slot: ?usize) void {
    if (usizeOptEql(self.dock_action_hovered_slot, slot)) return;
    self.dock_action_hovered_slot = slot;
    self.metal_dirty = true;
}

/// 동작 버튼을 눌렀을 때. **자리(index)로 받는다** — 목록은 뷰마다 다르고, 그 대응은 `dockActions` 하나가
/// 소유한다(누른 자리와 도는 동작이 두 표에서 나오면 어긋난다).
pub fn runDockAction(self: *AppSession, slot: usize) void {
    const actions = dockActions(self);
    if (slot >= actions.len) return;
    switch (actions[slot]) {
        .refresh => refreshDockTree(self),
        .collapse_all => collapseDockTree(self),
    }
}

/// 보이는 루트를 다시 읽는다. 열려 있는 하위 폴더까지 훑지 않는다 — 스캔 결과가 도착하면 그 아래는
/// 평소의 lazy 규율대로 다시 채워지고, 여기서 전부 예약하면 큰 트리에서 새로 고침 한 번이 수백 건이 된다.
fn refreshDockTree(self: *AppSession) void {
    var index: usize = 0;
    while (index < self.file_tree.rootCount()) : (index += 1) {
        const path = self.file_tree.rootAt(index) orelse continue;
        // 실패해도 조용히 넘어간다 — 큐가 꽉 찬 상황이고, 그때는 이미 예약된 스캔이 곧 같은 일을 한다.
        self.file_tree.requeueScan(path) catch continue;
    }
    self.metal_dirty = true;
}

/// 루트만 남기고 접는다. 바뀐 것이 없으면 **행 재투영도 하지 않는다** — 이미 접힌 트리에서 누르면
/// 아무 일도 일어나지 않아야 하고, 그때 선택·스크롤을 건드릴 이유가 없다.
fn collapseDockTree(self: *AppSession) void {
    if (!self.file_tree.collapseAll()) return;
    self.file_tree_rows_dirty = true;
    file_panel_ops.updateFileTree(self) catch {};
    self.metal_dirty = true;
}

/// 좌표가 동작 버튼 위인지. 그리는 조건과 **같은 chrome 기하**를 보므로 안 보이는 버튼은 눌리지도 않는다.
pub fn dockActionAt(self: *const AppSession, x_px: f64, y_px: f64) ?usize {
    if (!dockVisible(self)) return null;
    const actions = dockActions(self);
    if (actions.len == 0) return null;
    const bar = dockGeometry(self).view_bar;
    if (bar.h == 0 or x_px < 0 or y_px < 0) return null;
    if (!layout_math.pointInRect(x_px, y_px, bar)) return null;
    return dock_view_bar.actionAtPoint(
        .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h },
        self.cell_width_px,
        actions.len,
        @intFromFloat(x_px),
        @intFromFloat(y_px),
    );
}

/// 좌표가 뷰 바의 어느 슬롯 위인지(렌더·hover·클릭 공용 — 기하가 두 벌이 되지 않게).
pub fn dockViewSlotAt(self: *const AppSession, x_px: f64, y_px: f64) ?usize {
    if (!dockVisible(self)) return null;
    const bar = dockGeometry(self).view_bar;
    if (bar.h == 0 or x_px < 0 or y_px < 0) return null;
    if (!layout_math.pointInRect(x_px, y_px, bar)) return null;
    return dock_view_bar.slotAtPoint(
        .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h },
        self.cell_width_px,
        @intFromFloat(x_px),
        @intFromFloat(y_px),
    );
}

/// 지금 보이는 도크 목록이 매 프레임 내는 tree. **자식이 없다** — 행은 셀 격자라 tree 노드가 아니고(ML6의 텍스트
/// 모델 블로커), 이 선언이 사는 이유는 track/thumb을 공용 경로로 내기 위해서다. 가상화 평행이동도
/// 여기서 쓰지 않는다(셀 경로가 자기 원점 편향으로 한다 — SV2a).
pub fn buildDockListScrollTree(self: *AppSession) void {
    self.dock_list_scroll_entry_count = 0;
    self.dock_list_scroll_max_offset_px = 0;
    // 지금 보이는 목록으로 만든 스크롤바다 — 다른 뷰에 발행하면 목록과 무관한 막대가 뜨고 드래그도 먹는다.
    const axis = dockListScroll(self) orelse return;
    const rect = axis.rect;
    const extent = axis.extent;

    var entries: [dock_list_scroll_max_entries]chrome.ui.tree.RectEntry = undefined;
    var items: [dock_list_scroll_max_entries]chrome.ui.layout.Item = undefined;
    var flex: [dock_list_scroll_max_entries]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [dock_list_scroll_max_entries]chrome.ui.layout.UiRect = undefined;

    // **root에는 outer style을 주지 않는다**(`error.RootOuterStyle`). 도크는 이 노드가 컨테이너의
    // 자식이라 `height: fill`로 남은 높이를 먹지만, 탐색기는 스크롤 컨테이너 자체가 root라 크기가
    // `root_size`로 이미 정해져 있다.
    const node = chrome.ui.tree.scrollArea(.{
        .id = dock_list_scroll_ids.area,
        .scroll = .{
            .offset_px = axis.offset_px,
            .content_h_px = extent.content_h_px,
            .gutter_px = @floatFromInt(dockListScrollGutterPx(self)),
            .metrics = dockListScrollbarMetrics(self),
            // paint는 **불변**이다. fade alpha를 여기 실으면 tree가 매 프레임 달라져 entry·action
            // 배열을 다시 복사하고 reconcile을 다시 돈다(docs/scroll-area.md §7). alpha는 아래
            // `collectFileTreeScrollbar`가 paint 시점에 얹는다.
            .track = .{ .id = dock_list_scroll_ids.track, .action = .{ .id = dock_list_scroll_ids.track }, .paint = .{ .background = .surface_bg } },
            .thumb = .{ .id = dock_list_scroll_ids.thumb, .action = .{ .id = dock_list_scroll_ids.thumb }, .paint = .{ .background = .muted_fg, .corner_radii_px = .{ dock_list_scrollbar_width_px / 2, dock_list_scrollbar_width_px / 2, dock_list_scrollbar_width_px / 2, dock_list_scrollbar_width_px / 2 } } },
            // thumb을 누른 것 자체가 스크롤 의사이고 그 지점에 경쟁할 click이 없으므로 threshold는 0이다.
            // track도 같은 payload를 선언한다 — 눌러 점프한 뒤 손을 떼지 않고 이어 끌 수 있어야 한다.
            .drag = .{ .payload = dock_list_scroll_drag_payload, .axis = .vertical, .threshold_px = 0 },
        },
    }, &.{});

    const built = chrome.ui.tree.build(node, .{
        .root_size = .{ .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) },
        .max_entries = dock_list_scroll_max_entries,
        .max_depth = 2,
    }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex,
        .child_rects = &child_rects,
    }) catch return;

    // tree는 컨테이너 로컬 좌표다. 발행 전에 backing 좌표로 옮겨 hit-test·paint가 같은 값을 본다.
    self.dock_list_scroll_generation +|= 1;
    for (built.entries, 0..) |entry, i| {
        var moved = entry;
        moved.rect.x += @floatFromInt(rect.x);
        moved.rect.y += @floatFromInt(rect.y);
        if (moved.effective_clip) |*clip| {
            clip.x += @floatFromInt(rect.x);
            clip.y += @floatFromInt(rect.y);
        }
        self.dock_list_scroll_entries[i] = moved;
    }
    self.dock_list_scroll_entry_count = built.entries.len;
    self.dock_list_scroll_max_offset_px = extent.max_offset_px;
}

/// published tree가 발행한 track/thumb rect에서 스크롤바 기하를 **되읽는다**. 여기서 다시 계산하면
/// 보이는 것과 다른 두 번째 출처가 생긴다 — 그 갈라짐이 정확히 "보이는 곳과 눌리는 곳이 다른"
/// 결함이고, 도크가 같은 이유로 같은 함수를 갖는다(SV2b).
pub fn dockListScrollbarGeometry(self: *const AppSession) ?chrome.ui.scroll_area.ScrollbarGeometry {
    var track: ?chrome.ui.layout.UiRect = null;
    var thumb: ?chrome.ui.layout.UiRect = null;
    for (self.dock_list_scroll_entries[0..self.dock_list_scroll_entry_count]) |entry| {
        if (entry.id == dock_list_scroll_ids.track) track = entry.rect;
        if (entry.id == dock_list_scroll_ids.thumb) thumb = entry.rect;
    }
    const t = track orelse return null;
    const h = thumb orelse return null;
    // 잡는 자리(hit)는 tree에 안 실린다 — entry에는 **그린 rect만** 담기기 때문이다. 거터 폭으로
    // 역산해 채운다(`withHitSpan`).
    const bar: chrome.ui.scroll_area.ScrollbarGeometry = .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .hit_x = t.x,
        .hit_w = t.width,
        .thumb_y = h.y,
        .thumb_h = h.height,
        // 발행 시점에 기록한 상한을 읽는다 — 여기서 다시 계산하면 tree와 다른 값이 될 수 있다.
        .max_offset_px = self.dock_list_scroll_max_offset_px,
    };
    return bar.withHitSpan(@floatFromInt(dockListScrollGutterPx(self)));
}

/// 뷰 전환. 같은 뷰면 no-op이라 불필요한 재그리기를 만들지 않는다. 트리를 떠날 때는 키보드 포커스도 함께
/// 돌려준다 — 보이지 않는 트리가 키 입력을 계속 먹으면 안 된다(docs/file-explorer.md §3.5).
///
/// **도크를 여는 경로는 이 함수를 직접 부르지 말고 `enterDockView`를 쓴다.** 여기 있는 조기 반환은
/// 재그리기 억제가 목적이라, 진입 부작용(스캔 요청)까지 함께 건너뛰면 안 된다.
///
/// 이 함수를 그대로 쓰는 곳은 "전환만" 원하는 테스트다 — 진입 부작용 없이 상태만 세우려는 의도이므로
/// 남겨 둔다.
pub fn setDockView(self: *AppSession, view: dock_panel.View) void {
    if (self.dock.view == view) return;
    // `dock.size == 0`은 view별 자동 폭 sentinel이다. 따라서 explorer(180pt)와
    // agent_sessions(640pt) 사이에서는 창 resize를 기다리지 않고 같은 event에서 모든 pane의
    // grid와 Swift에 돌려주는 active rect를 갱신해야 한다. 수동 폭은 하나의 persisted state라
    // view 전환만으로 resize하지 않는다.
    const auto_right_width_changed = dockVisible(self) and self.dock.side == .right and self.dock.size == 0 and
        dock_layout.defaultRightPtForView(self.dock.view) != dock_layout.defaultRightPtForView(view);
    if (self.dock.view == .agent_sessions and view != .agent_sessions) agent_dock.cancelAgentSessionArchive(self);
    // 소스 컨트롤을 떠나면 커밋 상자 편집을 뗀다. 남겨 두면 조합 중이던 글자가 확정되지 않은 채
    // 남아 다음에 돌아왔을 때 그대로 떠 있고(입력기는 이미 그 조합을 잊었다), 포커스 플래그도
    // 클릭 없이 살아난다 — Session Dock 키 포커스를 같은 이유로 놓는 자리다.
    if (self.dock.view == .source_control and view != .source_control) scm_dock_ops.blurCommit(self);
    // 갤러리를 떠나면 도는 스캔을 취소한다 — 안 보는 화면 때문에 3.6 초를 끝까지 돌 이유가 없다.
    if (self.dock.view == .image_gallery and view != .image_gallery) image_gallery_ops.onLeaveView(self);
    self.dock.view = view;
    // The SessionDock's component-local keyboard/pointer focus is meaningful only while its
    // tree is visible.  Returning later must not resurrect a stale PageUp/PageDown owner.
    if (view != .agent_sessions) self.agent_session_dock_interaction = .{};
    // 뷰 전환은 어느 방향이든 도크 키보드 소유권을 놓는다. 들어올 때도 아직 누른 적이 없고,
    // 나갈 때 남겨 두면 다시 돌아왔을 때 클릭 없이 Enter를 가져간다.
    agent_dock.releaseAgentSessionDockKeyFocus(self);
    if (view != .explorer and file_panel_ops.fileTreeFocused(self)) file_panel_ops.restoreFileTreeFocus(self);
    // 뷰로 들어올 때 한 번 읽는다(§3.5의 갱신 시점 ①). 폴링하지 않는다.
    if (view == .source_control) git_ops.refreshGitStatus(self);
    // 갤러리는 **들어올 때 한 번** 훑는다(계약 §4.1) — 소스 컨트롤·아카이브와 같은 자리·같은 규율이다.
    // 폴링하지 않는다: 파일이 자란 것은 훅이 알려 준다.
    if (view == .image_gallery) image_gallery_ops.refresh(self, false);
    if (view == .agent_sessions) {
        agent_dock.refreshAgentSessionArchiveScopeSnapshots(self);
        self.agent_session_archive_project_scope_surface_id = term_ops.activeSurface(self).id;
        agent_dock.requestAgentSessionArchiveScopeRoots(self, null);
        agent_dock.refreshAgentSessionArchive(self, false);
    }
    if (auto_right_width_changed) {
        for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
        pane_ops.recomputeActivePaneRect(self);
        self.last_resize_size = null;
    }
    self.metal_dirty = true;
    self.workspaceChanged(.dock);
}

/// A cold app starts with its dock hidden.  The fixture must enter through the same titlebar
/// control a user uses before it can click the session view switcher; returning this geometry
/// does not open the dock or request a file picker.
pub fn dockLauncherSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    const rect = file_panel_ops.filePanelDockControlRect(self) orelse return .{};
    return .{
        .x_px = @floatFromInt(rect.x),
        .y_px = @floatFromInt(rect.y),
        .width_px = @floatFromInt(rect.w),
        .height_px = @floatFromInt(rect.h),
        .present = true,
        .enabled = true,
    };
}

/// 진입 훅. 같은 뷰로 다시 들어와도 불린다.
///
/// **가시성 가드가 필수다** — `setDockView`는 도크가 닫힌 상태에서도 불리므로(workspace restore 등),
/// 가드가 없으면 보이지도 않는 도크 때문에 사용자 이력 전체를 스캔한다.
///
/// 스캔 요청은 **항상 `force = false`**로 한다. 취소된 세대의 재요청은 `agent_dock.updateAgentSessionArchive`가
/// 단독으로 소유한다(그쪽만 `force = true`). 양쪽이 force를 쓰면 도크를 빠르게 여닫을 때
/// `취소 → 재요청 → 취소`가 반복된다 — 취소 시 `agent_session_archive_completed_ns`가 갱신되지 않아
/// TTL 가드도 걸리지 않기 때문이다.
pub fn onDockViewPresented(self: *AppSession, view: dock_panel.View) void {
    if (!agent_dock.shouldRefreshArchiveOnPresent(dockVisible(self), view)) return;
    agent_dock.refreshAgentSessionArchive(self, false);
}

/// 스크롤바가 정한 위치를 지금 보이는 목록에 적용한다. 각 뷰의 setter가 clamp·리페인트·fade 리셋을
/// 소유하므로 여기서는 라우팅만 한다.
pub fn setDockListScrollOffsetPx(self: *AppSession, offset_px: i64) void {
    switch (self.dock.view) {
        .explorer => file_panel_ops.setFileTreeScrollOffsetPx(self, offset_px),
        .source_control => setScmScrollOffsetPx(self, offset_px),
        else => {},
    }
}

pub fn dockListScroll(self: *AppSession) ?DockListScroll {
    if (!dockVisible(self) or self.cell_height_px == 0) return null;
    const content = dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return null;
    return switch (self.dock.view) {
        .explorer => .{
            .rect = content,
            .extent = file_panel_ops.fileTreeScrollExtent(self),
            .offset_px = file_panel_ops.fileTreeEffectiveScrollPx(self),
        },
        .source_control => .{
            .rect = .{
                .x = content.x,
                .y = content.y + self.cell_height_px,
                .w = content.w,
                .h = content.h -| self.cell_height_px,
            },
            .extent = scroll_ops.scmScrollExtent(self),
            .offset_px = scroll_ops.scmEffectiveScrollPx(self),
        },
        // 에이전트 세션 도크는 자기 tree(`session_dock.build`)를 이미 갖고 있다.
        else => null,
    };
}

/// 도크에서 **이 뷰를 보여 준다**. 도크를 여는 모든 경로가 여기를 지난다.
///
/// `setDockView`(전환)와 `onDockViewPresented`(진입)를 나누는 이유: 전환 함수는 "같은 뷰면 no-op"이
/// 맞지만, **진입은 같은 뷰여도 일어난다**. 둘을 한 함수에 두었더니 `dock.view`가 이미
/// `agent_sessions`인 채로 도크를 열면 맨 앞 조기 반환에 걸려 아카이브 스캔 요청이 아예 나가지
/// 않았다(도크를 떠날 때 `agent_dock.cancelAgentSessionArchive`가 진행 중 스캔을 취소하므로 닫았다 여는 흐름에서
/// 특히 잘 드러난다 — 목록도 스피너도 없이 비어 있고 새로 고침을 눌러야 나타났다).
pub fn enterDockView(self: *AppSession, view: dock_panel.View) void {
    setDockView(self, view);
    onDockViewPresented(self, view);
}

pub fn requestDockEntryFocus(self: *AppSession, entry: *const dock_panel.Entry) void {
    cancelPendingDockFocus(self);
    queuePendingDockFocus(self, entry);
    // Programmatic focus는 surface_id 존재만으로 native WKWebView publish를 추측하지 않는다. typed
    // completion 전에는 group owner가 text/paste/terminal close를 fail-closed로 소비하고, 실제 WebView
    // primary-down 또는 completion만 dock_surface로 승격한다.
    // surface_id가 이미 있어도 dock_surface로 승격하지 않는다 — typed completion(또는 실제 WebView
    // primary-down)만 승격이고, 그 전엔 fail-closed barrier가 text/paste/terminal close를 소비한다.
    self.focus_owner = .{ .dock_pending = entry.id };
    self.workspace_focus_pending = false;
    self.file_tree_focus_pending = false;
    self.file_tree_restore_surface_pending = null;
}

pub fn setDockSizeFromPointer(self: *AppSession, x_px: f64, y_px: f64) void {
    if (!self.dock_initialized or self.scale_milli == 0) return;
    // grab band의 어느 지점에서 시작했든 `pointer delta == divider delta`가 되게 down 때 저장한 간격을 더한다.
    // right는 x, bottom은 y 한 축만 보정한다. 이 보정이 없으면 첫 mouseDragged에서 최대 grab-band 폭만큼 점프한다.
    const offset_px = switch (self.pointer_gesture_owner) {
        .dock_outer_divider => |drag| drag.offset_px,
        else => return,
    };
    const adjusted_x = if (self.dock.side == .right) x_px + offset_px else x_px;
    const adjusted_y = if (self.dock.side == .bottom) y_px + offset_px else y_px;
    const candidate = dock_layout.sizePtForPointer(dockGeometry(self), self.dock.side, adjusted_x, adjusted_y, self.scale_milli) orelse return;
    const before = self.dock.size;
    self.dock.size = candidate;
    // 손상·과대 입력은 순수 layout이 보장하는 terminal floor로 clamp한 실효 크기를 저장한다. tree write-back과
    // 같은 sizePtForEffectiveWidth로 올림해 max clamp 경계에서 저장/복원 1px 드리프트를 없앤다(내림 회귀 수정).
    const effective_px = dockGeometry(self).dock_size_px;
    self.dock.size = dock_layout.sizePtForEffectiveWidth(effective_px, 0, self.scale_milli);
    if (self.dock.size == before) return;
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    self.last_resize_size = null;
    self.metal_dirty = true;
    self.workspaceChanged(.dock);
}

/// 소스 컨트롤 쪽 setter. 탐색기의 `setFileTreeScrollOffsetPx`와 같은 계약이다 — 상한은 스크롤바
/// 기하가 아니라 extent가 주고, 옮긴 직후의 thumb을 알아야 이어지는 드래그가 튀지 않으므로 tree를
/// 다시 낸다.
pub fn setScmScrollOffsetPx(self: *AppSession, offset_px: i64) void {
    const extent = scroll_ops.scmScrollExtent(self);
    if (!self.scm_scroll.setOffsetPx(offset_px, extent.max_offset_px)) return;
    buildDockListScrollTree(self);
    self.dock_list_scrollbar_idle_ticks = 0;
    self.metal_dirty = true;
}

/// 스크롤바가 놓일 여백(backing px). 컨테이너가 **자기 폭에서** 떼어 놓으므로 행 텍스트도 밴드도
/// 이 안으로 들어오지 않는다(docs/scroll-area.md §4). 예전에는 텍스트 **셀**을 통째로 빼서
/// (`reservedColumns`) 셀 폭에 따라 예약량이 들쭉날쭉했다.
pub fn dockListScrollGutterPx(self: *const AppSession) u32 {
    const m = dockListScrollbarMetrics(self);
    return m.width_px + m.inset_x_px;
}

pub fn setDockListScrollbarHovered(self: *AppSession, hovered: bool) void {
    if (self.dock_list_scrollbar_hovered == hovered) return;
    self.dock_list_scrollbar_hovered = hovered;
    self.metal_dirty = true;
}

pub fn cancelPendingDockFocus(self: *AppSession) void {
    self.pending_dock_focus = null;
    self.pending_dock_focus_action = false;
}

pub fn dockViewForSlot(index: usize) ?dock_panel.View {
    // 순서는 **enum 자신이 소유한다**(`dock_panel.View.forSlot`) — Windows 뷰 바도 같은 것을 쓴다.
    return dock_panel.View.forSlot(index);
}

/// 행 텍스트와 하이라이트 밴드가 쓸 수 있는 폭. 컨테이너가 gutter를 **상시** 떼어 놓으므로
/// 스크롤바가 나타나고 사라져도 이 값이 변하지 않는다 — 목록이 reflow하지 않는다는 뜻이다.
/// 스크롤바가 layer 2(텍스트 **아래**)로 내려왔으므로, 밴드가 이 폭을 넘으면 스크롤바를 덮는다.
pub fn dockListTextWidthPx(self: *const AppSession) u32 {
    return dockGeometry(self).tree_content.w -| dockListScrollGutterPx(self);
}

/// 현재 뷰가 스위처의 몇 번째 슬롯인지. chrome 컴포넌트는 도메인 enum을 모르므로(레이어 경계) 이 자리가
/// 대응을 **노출**하지만, 순서 자체는 `dock_panel.View` 가 소유한다 — 바로 위 `dockViewForSlot` 이
/// `View.forSlot` 에 위임하는 것과 같은 규율이다.
///
/// **손으로 미러링하지 않는다.** 예전에는 여기가 `switch` 를 다시 적었는데, 그러면 `View.slot` 과 이 함수가
/// 각자 순서를 갖게 되어 뷰를 하나 더할 때 한쪽만 고쳐질 수 있다. 정방향(`forSlot`)은 이미 위임하고 있었고
/// 역방향만 복사본이었다 — 그 비대칭이 드리프트의 자리다.
pub fn dockViewSlotIndex(self: *const AppSession) usize {
    return self.dock.view.slot();
}

/// 복원된 `DockPanel`의 평탄 목록에서 소유를 가져온다(panel은 비워진다). 와이어 파싱·검증·mode clamp는
/// `DockPanel.restore`가 이미 했으므로 재구현하지 않고 결과만 가져온다 — 포맷 규칙의 단일 출처 유지.
pub fn flattenRestoredDock(
    gpa: std.mem.Allocator,
    panel: *dock_panel.DockPanel,
) !RestoredFileEntries {
    var out: RestoredFileEntries = .{};
    errdefer out.deinit(gpa);
    try out.items.ensureTotalCapacity(gpa, panel.restoredCount());
    for (panel.restored.items) |entry| out.items.appendAssumeCapacity(entry); // path 소유가 목록으로 이동
    out.active_index = panel.restored_active;
    panel.restored.clearRetainingCapacity(); // panel은 더 이상 소유하지 않는다(이중 해제 방지)
    panel.restored_active = null;
    return out;
}
