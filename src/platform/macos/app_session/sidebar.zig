//! 사이드바 — 행 모델 재구축·스크롤·드래그/드롭 프리뷰·카드 렌더·헤더와 접힘 토글.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F7).
//!
//! `*AppSession` 메서드와, 인자만 보는 순수 기하/판정 함수(`sidebarBlockHeight`·`sidebarLineStep`·
//! `sidebarMaxScrollPx`·`sidebarScissorPx`·`sidebarHasCwd`·`sidebarCardTerm`·`fillSidebarGlyphPyTop`)가
//! 섞여 있다. 후자는 `AppSession`을 받지 않으므로 free 함수 전환이 필요 없었다 — F6의 `*Tab` 판정 10개와
//! 같은 모양이다. 줄 기하의 단일 출처는 `chrome.components.sidebar`이고 여기서는 그것을 부를 뿐이다.
//!
//! **탭 그룹 모델은 여기 없다.** `moveGroupSibling`·`moveGroupRange`·`relevelBlock`·`groupSubtreeEnd`·
//! `stablePartitionPinned` 등은 사이드바 드래그에서만 불리지만 본문은 탭 그룹 마커·depth를 수술한다.
//! 사이드바는 그 모델을 **표시**할 뿐이라 소유가 아니다 — F6가 이름에 `tab`이 없어 놓친 것이고,
//! 별도 후속(§4.1 F6 보정)으로 `tab.zig`에 보낸다. 여기로 옮기면 잘못된 소유가 굳는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const DropPlan = AppSession.DropPlan;
const GroupNestPlan = AppSession.GroupNestPlan;
const coretext_bridge = app_session_mod.coretext_bridge;
const dock_list_scrollbar_inset_px = app_session_mod.dock_list_scrollbar_inset_px;
const dock_list_scrollbar_min_thumb_px = app_session_mod.dock_list_scrollbar_min_thumb_px;
const dock_list_scrollbar_width_px = app_session_mod.dock_list_scrollbar_width_px;
const spinner_wave = app_session_mod.spinner_wave;
const git_ops = @import("git.zig");
const notification_ops = @import("notification.zig");
// 헤더 아이콘 줄의 **정의는 공유 모듈이 소유한다**(`platform/cell_text.zig`) — Windows 사이드바가
// 같은 줄을 그린다(W8.8⒝). 여기는 `AppSession` 에서 필드를 꺼내 넘기는 껍질만 남는다.
const cell_text = maru.cell_text;
const workspace_ops = @import("workspace.zig");
const settings_ops = @import("settings.zig");
const scroll_ops = @import("scroll.zig");
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const metal_frame = app_session_mod.metal_frame;
const agentBrandColor = @import("agent.zig").agentBrandColor;
const chrome_system_text = app_session_mod.chrome_system_text;
const workspaceLabel = app_session_mod.workspaceLabel;
const MeasuredTextCache = app_session_mod.MeasuredTextCache;
const agentIconCodepoint = app_session_mod.agentIconCodepoint;
const notificationBadgeCol = @import("notification.zig").notificationBadgeCol;
const packRgbAlpha = app_session_mod.packRgbAlpha;
const AgentKind = app_session_mod.AgentKind;
const agentTermOf = @import("agent.zig").agentTermOf;
const blendRgb = app_session_mod.blendRgb;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const diag_gate = app_session_mod.diag_gate;
const dock_list_scroll_drag_payload = app_session_mod.dock_list_scroll_drag_payload;
const pane_ops = @import("pane.zig");
const terminal = app_session_mod.terminal;
const traffic_light_clearance_pt = app_session_mod.traffic_light_clearance_pt;
const CollectedPane = AppSession.CollectedPane;
const GapDropPlan = AppSession.GapDropPlan;
const HeaderPart = AppSession.HeaderPart;
const SidebarScissor = AppSession.SidebarScissor;
const SidebarScrollExtent = AppSession.SidebarScrollExtent;
const SidebarViewport = AppSession.SidebarViewport;
const SidebarSearchLine = AppSession.SidebarSearchLine;
const WorkspaceSession = AppSession.WorkspaceSession;
const clampMoveToGroup = app_session_mod.clampMoveToGroup;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const file_panel_ops = @import("file_panel.zig");
const icons = app_session_mod.icons;
const layout_math = app_session_mod.layout_math;
const packOpaqueRgb = app_session_mod.packOpaqueRgb;
const renderer = app_session_mod.renderer;
const scrollbar_alpha_full = app_session_mod.scrollbar_alpha_full;
const sidebarCwdPath = app_session_mod.sidebarCwdPath;
const sidebar_scroll_max_entries = app_session_mod.sidebar_scroll_max_entries;
const tab_ops = @import("tab.zig");

/// 사이드바 상단 헤더 높이 = 신호등 띠 + 상단 바. 헤더의 두 줄(아이콘·검색)이 창 오른쪽의 두 밴드와 1:1로
/// 대응하므로 높이도 그 둘의 합이다 — 왼쪽만 다른 식을 쓰면 검색 줄과 탭 바가 어긋난다(docs/file-explorer.md §3.5).
/// `refreshCellMetrics`가 `sidebar_header_height_px`에 스탬프하고, 접힘 토글도 띠 높이가 바뀌므로 다시 스탬프한다.
pub fn sidebarHeaderHeightPx(self: *const AppSession) u32 {
    if (self.cell_height_px == 0) return 0;
    return self.titlebar_strip_px +| self.chromeBarHeightPx();
}

/// 헤더 검색 줄이 놓이는 밴드의 상단 y(= 띠 아래, 상단 바 시작). 렌더(검색 frame origin)·hit-test·caret이 공유하는
/// 단일 출처다 — 셋이 갈리면 "보이는 곳 ≠ 눌리는 곳"이 된다.
pub fn sidebarSearchBandTopPx(self: *const AppSession) u32 {
    return self.titlebar_strip_px;
}

/// 헤더 아이콘 줄(🔔◧⚙+)의 셀 **상단** y — 렌더러가 이 줄에 실제로 쓰는 py_top과 같은 식이다
/// (`maru_metal_renderer.m`: `py_top = (strip - ch) * 0.5`). 이 줄만 `row × ch`가 아니라 신호등 띠
/// [0, titlebar_strip_px] 안 세로 중앙에 놓이므로, 이 줄 위에 무언가를 얹으려면 이 값이 원점이다.
///
/// **셀이 아닌 GPU quad(알림 배지 원)도 이 원점을 써야 한다.** 배지는 한때 `ch * 0.46`으로 "줄이 y=0에서
/// 시작한다"를 가정했는데, 띠가 셀보다 높은 실제 창에서는 원만 `(strip-ch)/2`만큼 위로 떠 숫자가 원
/// 밖으로 빠져나갔다. 셀 세로 위치는 렌더러가, quad 세로 위치는 host가 정하므로 이 함수가 유일한 접점이다.
pub fn sidebarHeaderIconRowTopPx(self: *const AppSession) u32 {
    const ch = self.cell_height_px;
    const band = sidebarSearchBandTopPx(self);
    return if (band > ch) (band - ch) / 2 else 0;
}

/// 헤더 아이콘 줄(🔔◧⚙+)의 세로 중앙 y — 띠 안 세로 중앙에 그려진 한 셀 줄의 가운데.
/// 렌더러(`maru_metal_renderer.m`의 띠 중앙 공식)·hit-test(`sidebar.headerHit`)와 **같은 기하**를 푼다.
pub fn sidebarHeaderIconRowCenterPx(self: *const AppSession) u32 {
    return sidebarHeaderIconRowTopPx(self) + self.cell_height_px / 2;
}

/// 검색 줄 glyph의 세로 origin — 상단 바 밴드 안 세로 중앙. `row = 0` frame과 짝이라 `py_top = origin_y`가 된다.
pub fn sidebarSearchGlyphOriginY(self: *const AppSession) u32 {
    const bar_h = self.chromeBarHeightPx();
    const ch = self.cell_height_px;
    const centered = if (bar_h > ch) (bar_h - ch) / 2 else 0;
    return sidebarSearchBandTopPx(self) +| centered;
}

/// 사이드바 최소 폭(pt) — 헤더 아이콘 줄(좌측 네이티브 신호등 ~72pt + 우측 🔔/◧/⚙/+ 아이콘, sidebar.zig headerHit)이
/// 겹치지 않는 하한. 아이콘은 cell 폭에 비례하므로 고정 sidebar_min_pt(120)로는 큰 폰트에서 신호등과 겹친다 — 신호등
/// 클리어런스 + 13칸을 px로 잡아 pt 환산한 값과 sidebar_min_pt 중 큰 쪽이다. 13칸 = 알림 그룹의 좌단(펼침 헤더의 종
/// 글리프 좌단 `cols-12`, 종 점유 `cols-12·cols-11`, 우상단 배지 `cols-10`)까지를 클리어런스 오른쪽에 둔다 — 예전 10칸은
/// ◧(`cols-8`)까지만 잡아 종+배지가 신호등과 겹쳤다(사용자 피드백). **단 sidebar_max_pt를 넘지 않게 cap**(clamp 하한이 상한을 넘으면
/// std.math.clamp가 assert로 패닉 — 거대 폰트에선 max 우선). 폭을 정하는 **모든 경로**(드래그 setSidebarWidthPx·메트릭 변경
/// refreshCellMetrics)가 공유하는 단일 출처라 어느 경로로도 겹침이 새지 않는다.
pub fn sidebarMinPt(self: *const AppSession) u32 {
    if (self.scale_milli == 0) return sidebar_min_pt;
    const header_min_px = layout_math.ptToPx(traffic_light_clearance_pt, self.scale_milli) + 13 * self.cell_width_px;
    return @min(@max(sidebar_min_pt, header_min_px * 1000 / self.scale_milli), sidebar_max_pt);
}

/// 사이드바 우측 경계 드래그(kind 2) — 폭을 x_px(backing, 경계가 갈 위치)로 잡고 [sidebar_min_pt,
/// sidebar_max_pt] pt로 clamp한다. pt를 권위 있게 저장(DPI 변경에도 유지), backing px·grid는 거기서 파생.
/// 사이드바 폭이 모든 탭의 터미널 폭을 바꾸므로 전 탭 panel을 새 grid로 resize하고 활성 rect·사이드바를
/// 갱신한다. 폭이 그대로면(같은 pt) 무동작 — SIGWINCH·재배치 storm 방지.
pub fn setSidebarWidthPx(self: *AppSession, x_px: f64) void {
    if (self.scale_milli == 0 or !std.math.isFinite(x_px)) return;
    const clamped_x = if (x_px < 0) 0 else @min(x_px, @as(f64, @floatFromInt(std.math.maxInt(u32))));
    const px: u32 = @intFromFloat(clamped_x);
    // 헤더 아이콘이 겹치지 않는 동적 하한(sidebarMinPt — 신호등 + 아이콘 칸, max로 cap)으로 clamp.
    const pt: u32 = std.math.clamp(px * 1000 / self.scale_milli, sidebarMinPt(self), sidebar_max_pt);
    if (pt == self.sidebar_width_pt) return;
    self.sidebar_width_pt = pt;
    self.sidebar_width_px = layout_math.ptToPx(pt, self.scale_milli);
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab); // 모든 탭의 term 폭이 바뀐다(best-effort)
    pane_ops.recomputeActivePaneRect(self);
    rebuildSidebar(self) catch {}; // sidebar_cols 환산이 바뀌므로 밴드 재생성
    self.metal_dirty = true;
}

/// 사이드바 접기/펼치기 토글 — 헤더 토글 아이콘·접힘 시 좌상단 펼치기 버튼이 부른다. 접으면 effective 폭이 0(카드·
/// 검색 숨김, 터미널이 그 자리까지 확장)이고 폭(pt)은 sidebar_width_pt에 보존돼 펼치면 복원된다. 폭이 모든 탭 term을
/// 바꾸므로 setSidebarWidthPx와 같은 재배치(전 탭 resize + 활성 rect + 사이드바 재빌드)를 한다.
pub fn toggleSidebarCollapsed(self: *AppSession) void {
    if (self.chrome_minimal) return; // quick terminal minimal은 항상 사이드바 없음 — 토글 대상 아님
    // 접으면 검색 입력칸이 사라지니 검색을 비활성화한다(안 그러면 inputFocus가 .sidebar_search로 남아 키가 보이지
    // 않는 검색에 갇히고 매 blink마다 재투영). 검색어는 보존(blur 규율) — 호출 경로(◧ 클릭/향후 키바인딩)와 무관하게
    // 토글 자체가 책임진다. 아래 rebuildSidebar가 필터 일시정지를 반영한다.
    self.sidebar_search_active = false;
    self.hovered_collapsed_toggle = false; // 토글 전후로 stale 호버 배경이 남지 않게(다음 hoverCursor가 다시 판정)
    self.sidebar_collapsed = !self.sidebar_collapsed;
    self.sidebar_width_px = if (self.sidebar_collapsed) 0 else layout_math.ptToPx(self.sidebar_width_pt, self.scale_milli);
    self.titlebar_strip_px = self.computeTitlebarStripPx(); // 접힘=신호등 높이, 펼침=한 줄 — termRect/grid 전에 갱신
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// SG4 — 사이드바 카드 드래그로 그룹에 넣기/빼기(docs/plans/sidebar-groups.md §9, docs/sidebar-groups.md §10). 드롭 타겟 표시 row(raw_row)와
/// 드래그 중 원본 탭(from)을 받아 `moveTab`에 넘길 **목표 탭 인덱스**를 계산한다. 소속은 저장하지 않고 self.tabs
/// 순서에서 파생하므로(§2.1) "어느 위치로 옮기느냐가 곧 소속"이다 — 여기선 드롭 row를 그 위치로 번역하기만 한다.
/// 규칙:
///  - **카드 row**: 그 카드 탭 위치(c)로. moveTab이 방향(아래=insert-after·위=insert-before)대로 그 카드에 붙여,
///    그 카드와 같은 그룹으로 위치 파생된다(그룹 A 몸통 카드 위에 놓으면 A, 최상위 카드 위면 최상위 = 빼기).
///  - **펼친 그룹 헤더**: 그 그룹 첫 몸통 카드 자리(마커 바로 뒤)로 — 그룹에 넣기(§1). 마커 탭은 group_start를
///    든 그 탭 자체라 그 앞엔 못 넣고(마커가 따라 밀림) 마커 **직후**가 그룹 최상단이다. 방향 보정: from<M이면 to=M
///    (마커가 M-1로 밀리며 dragged가 마커 뒤), from>M이면 to=M+1(마커 불변, dragged가 마커 뒤).
///  - **접힌 그룹 헤더**: 그 그룹 **끝**(다음 group_start 직전 = 연속 파티션 [M,j)의 j-1)으로 — 접혀서 드롭 위치가
///    안 보이니 그룹 끝에 추가(§10 "접힌 그룹에 넣기", 브라우저 탭 그룹 관례).
/// raw_row 범위 밖·마커 인덱스 이상이면 null(무동작). 반환값은 pre-clamp(moveTab이 pinned 경계로 다시 clamp).
/// **연속 파티션 불변식은 공짜**다 — 마커는 탭에 얹혀 있고 이 경로는 마커 없는 카드만 재정렬하므로(마커 탭 드래그는
/// 호출 전 제외), 어떤 재배열이든 그룹은 항상 [마커, 다음 마커) 연속 구간으로 유지된다(§2.1, 위반 자체가 불가능).
/// 드롭 좌표가 **에이전트 목록 행**에 떨어졌으면 그 행이 딸린 **카드 row**로 접어 준다. 목록은 카드의 부속이라
/// "그 워크스페이스 위에 떨어뜨렸다"로 보는 것이 사용자 기대이고, 접지 않으면 카드 높이의 몇 배나 되는 목록
/// 영역 전체가 드롭 불가 사각지대가 된다(code-review max — 재정렬·그룹 이동이 조용히 무효).
pub fn sidebarCardRowFor(self: *const AppSession, raw_row: usize) usize {
    const rows = sidebarRenderRows(self);
    var r = raw_row;
    while (r < rows.len) : (r -= 1) {
        switch (rows[r]) {
            .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
            else => return r,
        }
        if (r == 0) break;
    }
    return raw_row;
}

/// **§14.6 SR4 model-2 — 드롭 컨텍스트 top_level 분류**(요구2). 카드 드래그의 드롭 표시 row(raw_row)를 보고 착지가 "그룹
/// 밖 gap(최상위 복귀)"인지 "그룹 안(멤버)"인지 판정해 DropPlan.card.top_level **의도**를 낸다. sidebarGroupDropTargetTab이
/// 착지 **위치**를 정하는 것과 짝(위치=소속, top_level=서브파티션 비트). 규칙:
///  - **카드 row**: 그 타겟 카드가 **최상위(그룹 밖 = enclosing 마커 없음)**면 그 옆에 붙는 드래그 카드도 최상위 복귀(true) —
///    그룹 사이/뒤에 낀 top카드(SR3 인터리빙) 옆 드롭이 이 경로. 타겟이 **그룹 멤버**면 그 그룹에 흡수(false, 기존 SG4).
///  - **그룹 헤더 row**(펼침·접힘): 헤더에 드롭 = 그 그룹 **안으로**(멤버) → false.
/// 이 값은 **의도**일 뿐이고, simulateDrop/commit이 hasGroupMarkerAboveInRegion 게이트와 AND해 최소 표현으로 굽는다(그룹
/// 없는 flat·leading은 true여도 게이트가 false라 write 없음 → 회귀 0). 범위 밖이면 false(그룹 밖=흡수 안 함이 안전 기본).
pub fn sidebarCardDropTopLevel(self: *AppSession, raw_row: usize) bool {
    if (raw_row >= self.sidebar_rows.items.len) return false;
    return switch (self.sidebar_rows.items[raw_row]) {
        .card => |c| c.tab < self.tabs.items.len and tab_ops.enclosingGroupMarkerIndex(self, c.tab) == null, // 타겟이 최상위면 최상위 복귀
        .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => false, // 목록/system 행은 드롭 타겟이 아니다
        .group_header => false, // 헤더 드롭 = 그룹 안(멤버)
    };
}

/// 드래그 커서 y가 표시 row `raw_row`의 **아래 경계 영역**(하단 40%)에 있는가 — "그룹 뒤 빈 gap" 드롭 존 판정(§14.6 SR5
/// 요구2). row 모델엔 그룹 사이 빈 gap row가 없어(연속 파티션), 마지막 멤버/접힌 헤더의 하단 밴드를 gap 드롭 존으로 쓴다.
/// rowTop/rowHeight(가변 높이 누적, chrome 단일 출처)로 row 안 상대 위치를 구해 frac>=0.6이면 아래 경계. 높이 0/범위 밖은 false.
pub fn dragInRowLowerBoundary(self: *AppSession, raw_row: usize, y_px: f64) bool {
    const rows = self.sidebar_rows.items;
    if (raw_row >= rows.len or !std.math.isFinite(y_px)) return false;
    const top = chrome.components.sidebar.rowTop(rows, raw_row, self.sidebar_header_height_px, sidebarMetrics(self), self.sidebar_scroll_offset_px);
    const h = chrome.components.sidebar.rowHeight(rows[raw_row], sidebarMetrics(self));
    if (h == 0) return false;
    const frac = (y_px - @as(f64, @floatFromInt(top))) / @as(f64, @floatFromInt(h));
    return frac >= 0.6;
}

/// **§14.6 SR5 요구2 — "그룹 뒤 빈 gap" 카드 드롭(첫 인터리브)**. SR4가 기존 top카드 **옆** 드롭으로 인터리빙을 열었지만,
/// 그룹 사이에 top카드가 아직 없으면(빈 gap) row 모델에 그 자리를 가리킬 row가 없어 드래그로 첫 top카드를 못 만들었다.
/// 이 함수는 커서가 **최상위 그룹의 마지막 멤버 카드**(또는 **접힌 최상위 그룹 헤더**)의 **아래 경계 영역**(dragInRowLowerBoundary)
/// 에 있으면, 드래그 카드를 그 그룹 **subtree 끝**(그룹 밖 gap)에 `top_level:=true`로 착지시키는 plan을 낸다. 위치 계산은
/// 접힌 헤더 드롭(sidebarGroupDropTargetTab)과 **동형**(from<m이면 j-1·아니면 min(j,len-1))이라 방향 보정을 공유하고, top_level
/// 만 다르다(멤버 흡수 대신 그룹 밖 최상위 복귀). 착지 후 commit이 hasGroupMarkerAboveInRegion 게이트로 실제 write를 굽는다
/// (SR4 카드 경로와 동일). 발화 조건이 아니면 null → 호출자가 기존 sidebarGroupDropTargetTab/sidebarCardDropTopLevel 경로로
/// 폴백(byte-identical). **제약**: (1) **같은 그룹 안 카드**(from∈[m,j)) 드래그는 null(그룹 안 재정렬 — gap-promote는 밖에서
/// 끌어올 때만), (2) **펼친 그룹 헤더** 아래 경계는 null(첫 멤버와 모호 — 접힌 헤더만), (3) **중첩 그룹**은 top-level 그룹 끝만
/// (중첩 subgroup 뒤 gap = sticky-reset이 depth를 0으로만 되돌리는 §14.7 제약이라 top-level만 착지).
pub fn sidebarCardDropAfterGroup(self: *AppSession, raw_row: usize, from: usize, y_px: f64) ?GapDropPlan {
    const len = self.tabs.items.len;
    if (raw_row >= self.sidebar_rows.items.len or len == 0) return null;
    if (!dragInRowLowerBoundary(self, raw_row, y_px)) return null; // 아래 경계 영역만 발화
    // m=최상위 그룹 마커, j=그 subtree 끝. 카드 branch는 아래 가드가 이미 `groupSubtreeEnd(tl)==c.tab+1`을 확립하므로
    // j를 재계산하지 않고 c.tab+1을 재사용한다(code-review 효율). 헤더 branch만 groupSubtreeEnd를 계산한다.
    const mj: struct { m: usize, j: usize } = switch (self.sidebar_rows.items[raw_row]) {
        .card => |c| blk: {
            if (c.tab >= len) return null;
            const tl = tab_ops.topLevelGroupMarkerIndex(self, c.tab) orelse return null; // 그룹 밖 카드 → gap 아님
            if (tab_ops.groupSubtreeEnd(self, tl, null, null) != c.tab + 1) return null; // c가 최상위 그룹의 마지막 원소 아님 → 일반 멤버 드롭
            break :blk .{ .m = tl, .j = c.tab + 1 }; // 위 가드가 j==c.tab+1 확립 → 재사용
        },
        .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => return null, // 목록/system 행은 그룹 gap 대상이 아니다
        .group_header => |h| blk: {
            if (h.tab >= len) return null;
            if (!h.collapsed) return null; // 펼친 헤더 아래 경계 = 첫 멤버(모호) → skip(일반 헤더 드롭)
            if (tab_ops.effectiveDepthAt(self, h.tab, null, null) != 1) return null; // 최상위 접힌 그룹만(중첩 접힌 헤더 gap은 모호)
            break :blk .{ .m = h.tab, .j = tab_ops.groupSubtreeEnd(self, h.tab, null, null) };
        },
    };
    const m = mj.m;
    const j = mj.j;
    if (from >= m and from < j) return null; // 같은 그룹 안 카드 → 일반 재정렬(gap-promote 아님)
    const target = if (from < m) j - 1 else @min(j, len - 1); // 접힌 헤더 드롭과 동형 방향 보정
    return .{ .target_tab = target, .top_level = true };
}

/// 그룹 통째 드래그의 드롭 타겟 해석. 드롭 표시 row(raw_row)와 드래그 중인 그룹 마커 m을 받아 moveGroupRange에 넘길
/// **삽입 경계**(다른 그룹 시작 인덱스·top_level run 경계 또는 len)를 계산한다. 규칙(방향 기반 — sidebarGroupDropTargetTab의
/// from<M/from>M 결과 patterns 동형): raw_row가 가리키는 **최상위 단위**(그룹 subtree 또는 top_level 탭 run)를 찾아, 그
/// 단위가 드래그 그룹보다 **위면 그 앞**, **아래면 그 뒤**에 끼운다 — 항상 단위 경계라 연속 파티션 유지. 리딩 카드(첫 그룹
/// 이전·플래그 없음) row에 드롭하면 첫 그룹 앞(그룹들 최상단, 옛 동작). 자기 단위면 null(무동작).
///
/// **§14.6 SR4 인터리빙 — 그룹↔top_level 탭 순서 교환(이 함수의 핵심 수정)**: §2.1 재설계(§14)로 top_level 탭이 그룹
/// 뒤/사이에 오는데, 옛 코드는 최상위 카드를 전부 "리딩 zone"(첫 그룹 이전)으로만 보고 `first_group`으로 clamp해 **그룹이
/// top_level 탭 위/사이로 못 갔다**(증상: `[탭X, 그룹A]`에서 A를 X 앞으로 못 끎). 아래 인터리빙 분기가 **그룹 밖 top카드**
/// (`enclosingGroupMarkerIndex==null`)를 하나의 최상위 run 단위로 인식해 그룹을 그 앞/뒤로 끼운다. **리딩 카드는 제외**
/// (run이 리전 첫머리에서 시작하고 개시 카드에 top_level 플래그가 없으면 = 옛 리딩 zone) → 옛 clamp로 폴백해 SG5-1
/// byte-identical. run 통째로 끼워 sticky follower가 이동한 그룹 마커에 흡수되는 것을 막는다(유효 단위 경계 = {마커,
/// top_level 카드, 리전 끝}만).
pub fn sidebarGroupDropBoundary(self: *AppSession, raw_row: usize, m: usize) ?usize {
    const len = self.tabs.items.len;
    if (m >= len or raw_row >= self.sidebar_rows.items.len) return null;
    const target_tab: usize = switch (self.sidebar_rows.items[raw_row]) {
        .card => |c| c.tab,
        .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => return null, // 목록/system 행은 탭 인덱스 도메인이 아니다
        .group_header => |h| h.tab,
    };
    if (target_tab >= len) return null;
    // 첫 그룹 시작 = 최상위 구간의 끝(§2.1). **핀 리전(§12 GP1)**: 앵커는 드래그 그룹 m이 속한 핀 리전에 국소화한다
    // (각 리전 안에서 §2.1가 다시 성립 — 비고정 리전이면 [pinned_count, len)의 첫 마커). 마커가 그 리전에 없으면 리전
    // 끝(reg.hi). 고정 그룹 0개면 m은 비고정 리전이라 리전 앵커=전역 앵커·reg.hi=len → 옛 `firstGroupStartIndex() orelse
    // len`과 byte-identical. (그룹 통째 이동 자체의 리전 clamp는 GP3 clampGroupMoveToRegion.)
    const reg = tab_ops.pinRegionBounds(self, m);
    const first_group = self.firstGroupStartInRegion(reg.lo, reg.hi) orelse reg.hi;

    // **§14.6 SR4 인터리빙**: target이 **그룹 밖 top카드**(enclosing 마커 없음 = top_level 탭/그 sticky follower)면, 그
    // 카드가 속한 **최상위 run**을 한 단위로 보고 그룹을 그 앞/뒤로 끼운다(그룹↔탭 순서 교환). 그룹 헤더/멤버 row는 enclosing
    // 이 non-null이라 이 분기를 안 타고 아래 그룹 경계 로직으로 간다.
    if (tab_ops.enclosingGroupMarkerIndex(self, target_tab) == null) {
        // 최상위 run [run_lo, run_hi): run_lo=run 개시 카드(top_level 플래그가 선 카드 또는 리전 시작), run_hi=다음 마커/
        // 리전 끝. 위로 스캔은 개시 카드(top_level=true)에서 멈추고, 그 앞이 다른 최상위 카드일 때만 이어간다.
        var run_lo = target_tab;
        while (run_lo > reg.lo and !self.tabs.items[run_lo].top_level and
            tab_ops.enclosingGroupMarkerIndex(self, run_lo - 1) == null) run_lo -= 1;
        // 리딩 zone(옛 동작 보존): run이 리전 첫머리에서 시작하고 개시 카드에 플래그가 없으면 = 그룹은 리딩 카드 뒤라는
        // 옛 가정. 이 경우만 아래 `first_group` clamp로 폴백한다(SG5-1 byte-identical). 그 외(플래그 있는 인터리브 top카드
        // ·그룹 뒤 top카드)는 run 단위로 순서 교환한다.
        const leading = run_lo == reg.lo and !self.tabs.items[run_lo].top_level;
        if (!leading) {
            var run_hi = target_tab + 1;
            // 위 run_lo가 top_level 개시 카드에서 멈추는 것과 **대칭**: run_hi도 다음 top_level 카드에서 멈춘다 —
            // 그 카드는 새 최상위 run을 개시하는 경계라 현재 run에 포함하면 두 인접 top카드가 한 run으로 잘못 병합된다
            // (그룹↔탭 순서 교환이 어긋남). 마커 경계(group_start)와 top_level 경계 둘 다서 정지(§14, code-review).
            while (run_hi < reg.hi and self.tabs.items[run_hi].group_start == null and !self.tabs.items[run_hi].top_level) run_hi += 1;
            // run은 마커가 없어 드래그 그룹 subtree와 겹치지 않는다(전부 위 또는 전부 아래). 위면 run 앞, 아래면 run 뒤.
            if (run_lo < m) return run_lo;
            return run_hi;
        }
    }

    if (target_tab < first_group) {
        // 리딩 카드에 드롭 → 그룹들 최상단(첫 그룹 앞). 자기가 이미 첫 그룹이면 no-op.
        if (m == first_group) return null;
        return first_group;
    }
    // target_tab이 속한 그룹의 마커 g_i(자기 위에서 가장 가까운 group_start).
    var gi: usize = target_tab;
    while (gi > 0 and self.tabs.items[gi].group_start == null) gi -= 1;
    if (gi == m) return null; // 자기 그룹 — no-op(jitter 방지)
    if (gi < m) return gi; // 대상 그룹이 위 → 그 앞에 삽입(위로 이동)
    // 대상 그룹이 아래(gi > m) → 그 그룹 subtree 뒤(자식 그룹 포함, SG5-3)에 삽입.
    return tab_ops.groupSubtreeEnd(self, gi, null, null);
}

pub fn setSidebarScrollbarHovered(self: *AppSession, hovered: bool) void {
    if (self.sidebar_scrollbar_hovered == hovered) return;
    self.sidebar_scrollbar_hovered = hovered;
    self.metal_dirty = true;
}

/// 사이드바 스크롤 offset을 적용한다. clamp·재배치·재드로우는 휠 경로와 같은 자리를 쓴다 —
/// 드래그가 휠과 다른 상한을 갖게 되면 막대 끝과 목록 끝이 어긋난다.
pub fn setSidebarScrollOffsetPx(self: *AppSession, offset_px: u32) void {
    const clamped = @min(offset_px, sidebarMaxScroll(self));
    if (clamped == self.sidebar_scroll_offset_px) return;
    self.sidebar_scroll_offset_px = clamped;
    rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 사이드바 스크롤바를 잡는다. 도크 목록과 **같은 타입**(`scroll_area.Drag`)을 쓰고 태그만 다르다.
pub fn beginSidebarScrollbarGesture(self: *AppSession, x_px: f64, y_px: f64) bool {
    buildSidebarScrollTree(self);
    const geometry = sidebarScrollbarGeometry(self) orelse return false;
    if (!geometry.trackContains(x_px, y_px)) return false;
    if (self.dock_list_scroll_drag.begin(geometry, x_px, y_px)) |jumped| setSidebarScrollOffsetPx(self, jumped);
    const snapshot = sidebarScrollTree(self);
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
    // 사이드바 카드 드래그·일반 포인터 gesture와 동시에 살 수 없다 — 도크 경로와 같은 규율이다.
    clearSidebarDragPreview(self);
    self.pointer_gesture_owner = .none;
    self.scrollbar_drag_target = .sidebar;
    self.sidebar_scrollbar_idle_ticks = 0;
    self.metal_dirty = true;
    return true;
}

/// capture가 살아 있는 동안의 move/up(사이드바). 도크 경로와 같은 형태이되 **carry key가 없다** —
/// 사이드바는 목록이 하나뿐이라 "다른 목록으로 바뀌었는가"를 물을 대상이 없고, 대신 아래
/// 기하 비교가 "같은 막대를 계속 잡고 있는가"를 판정한다(도크에서도 그 축은 기하가 지킨다).
pub fn routeSidebarScrollbarCapture(self: *AppSession, kind: i32, y_px: f64) bool {
    buildSidebarScrollTree(self);
    const snapshot = sidebarScrollTree(self);
    if (snapshot.entries.len == 0) {
        scroll_ops.endScrollbarCapture(self);
        return true;
    }
    const live = sidebarScrollbarGeometry(self) orelse {
        scroll_ops.endScrollbarCapture(self);
        return true;
    };
    if (!file_panel_ops.fileTreeScrollbarSameSnapshot(self.dock_list_scroll_drag.geometry, live)) {
        scroll_ops.endScrollbarCapture(self);
        return true;
    }
    // 매 move마다 tree를 다시 발행하므로(thumb이 움직인다) capture를 **넘겨야** 한다 — 평범한
    // `reconcile`은 그것을 버려 드래그가 첫 move에서 끊긴다. carry key는 사이드바에 고정값을 쓴다:
    // 도크와 달리 "다른 목록으로 바뀌었는가"를 물을 대상이 없고(목록이 하나다), 그 축은 위의 기하
    // 비교가 이미 지킨다.
    const key = chrome.ui.interaction.GestureCompatibility{
        .kind = dock_list_scroll_drag_payload,
        .enabled = true,
        .owner_epoch = 0,
        .domain_identity = 0,
    };
    _ = chrome.ui.interaction.reconcileCarryingCapture(&self.scrollbar_interaction, snapshot, key, key) catch {
        scroll_ops.endScrollbarCapture(self);
        return true;
    };
    if (self.scrollbar_interaction.capture == null) {
        scroll_ops.endScrollbarCapture(self);
        return true;
    }
    const dispatched = chrome.ui.interaction.dispatch(&self.scrollbar_interaction, snapshot, .{
        .phase = if (kind == 2) .move else .up,
        .x_px = @as(f64, self.dock_list_scroll_drag.geometry.track_x) + @as(f64, self.dock_list_scroll_drag.geometry.track_w) / 2,
        .y_px = y_px,
        .timestamp_ns = 0,
        .button = .left,
        .generation = snapshot.generation,
    }) catch {
        scroll_ops.endScrollbarCapture(self);
        return true;
    };
    if (dispatched.drag) |event| switch (event) {
        .began, .moved => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            self.scrollbar_move_events +|= 1;
        },
        .dropped => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            scroll_ops.applyPendingScrollbarScroll(self);
            scroll_ops.endScrollbarCapture(self);
        },
        .cancelled => scroll_ops.endScrollbarCapture(self),
    };
    if (kind == 3) scroll_ops.endScrollbarCapture(self);
    return true;
}

/// 사이드바 검색바 키 — handleRenameKey 동형(평문 글자·backspace·Enter·Esc). 모달이 아니라 활성 중에만 키를
/// 소비한다. Enter=첫 매칭 세션으로 이동·검색 종료, Esc=종료(검색어 비움). 단축키 조합(⌘ 등)은 안 쌓는다.
/// 입력이 바뀌면 rebuildSidebar로 카드 필터(visible_slots)를 다시 적용한다.
pub fn handleSidebarSearchKey(self: *AppSession, ev: chrome.input.InputEvent) void {
    switch (ev) {
        .key => |k| switch (k.key) {
            .escape => closeSidebarSearch(self),
            .enter => {
                _ = self.sidebar_search_input.commitPreedit(self.allocator); // 조합 잔여 확정
                sidebarSearchActivateFirst(self);
            },
            .backspace => {
                self.sidebar_search_input.backspace();
                rebuildSidebar(self) catch {};
                self.resetCursorBlink();
                self.metal_dirty = true;
            },
            .char => {
                if (k.mods.command or k.mods.control or k.mods.option) return; // 단축키 조합은 안 쌓음
                self.sidebar_search_input.appendChar(self.allocator, k.codepoint) catch {};
                rebuildSidebar(self) catch {};
                self.resetCursorBlink();
                self.metal_dirty = true;
            },
            else => {},
        },
        .pointer => {}, // 사이드바 검색바는 포인터를 안 받는다(CS-4-0 — 모달 위젯 포인터는 chrome_host 경로).
    }
}

/// 검색바를 닫는다(검색어·조합 비움 + 비활성 + 필터 해제 후 재빌드). Esc·Enter(이동 후)처럼 검색을 '끝낼' 때만.
pub fn closeSidebarSearch(self: *AppSession) void {
    self.sidebar_search_active = false;
    self.sidebar_search_input.clear();
    rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 검색바를 blur한다(포커스 아웃 — 검색 영역 밖 클릭). 비활성만 하고 **검색어는 보존**한다 — 다시 검색바를
/// 클릭하면 그 검색어로 이어서 편집·필터한다(rename은 확정/취소뿐이라 다르지만, 검색은 '초안 보존'이 자연스럽다).
/// 비활성이라 recomputeVisibleTabs가 필터를 일시정지(전체 표시)하므로, blur 중 새 워크스페이스를 만들어도
/// 필터에 숨지 않는다. 완전히 비우려면 Esc(closeSidebarSearch). 키 포커스는 터미널로 돌아간다(inputFocus).
pub fn blurSidebarSearch(self: *AppSession) void {
    self.sidebar_search_active = false;
    rebuildSidebar(self) catch {}; // 비활성 → 필터 일시정지(전체), 검색어 텍스트는 헤더에 유지
    self.metal_dirty = true;
}

/// 검색 Enter — 필터된 첫 매칭 세션으로 전환하고 검색을 종료한다. 매칭 없으면 무동작(검색 유지).
pub fn sidebarSearchActivateFirst(self: *AppSession) void {
    if (tab_ops.firstMatchingTab(self)) |idx| {
        _ = tab_ops.switchTab(self, idx);
        closeSidebarSearch(self);
        return;
    }
    const query = self.sidebar_search_input.query.items;
    if (query.len == 0) return;
    for (self.recoveredSessionsRows(self.is_primary_window), 0..) |row, index| {
        if (std.ascii.indexOfIgnoreCase(&row.label, query) == null) continue;
        self.activateRecoveredSessionAt(index) catch {
            self.showNoticeKey(.app_recovered_session_failed);
            return;
        };
        closeSidebarSearch(self);
        return;
    }
}

/// 에이전트 행이 그리는 줄 수 — 라벨(항상) + 폴더·브랜치(그 Term의 cwd를 알 때, §2.1). 마지막 대화 두 줄은
/// transcript 보강(4·5단계)이 붙으면 여기서 함께 센다. 카드와 같은 규율로 이 값이 행 높이의 입력이다.
pub fn sidebarAgentRowLines(self: *AppSession, tab: *Tab, ag: WorkspaceSession) u8 {
    const term = agentTermOf(tab, ag) orelse return 1;
    // 라벨 줄은 항상 있다 — 에이전트면 (마커 + 프롬프트/종류·문구), 아니면 Term 라벨(2026-08-11). 아래 세 조건은 종류로
    // 분기하지 않는다: PTY 없는 Term(브라우저·파일)은 관측이 `.unavailable`이라 폴더·브랜치가 자연히 0줄이고,
    // 에이전트 아닌 Term은 transcript가 비어 응답 줄도 0이다. 즉 비-에이전트 행은 라벨 1줄로 수렴한다.
    var n: u8 = 1;
    // **termGitBranch를 먼저** 부른다 — 이 호출이 관측(cwd)을 refresh하므로, sidebarHasCwd를 앞세우면 관측이
    // stale한 rebuild에서 줄 수를 1로 재고 같은 rebuild의 렌더는 2줄을 그려 행 높이와 글자가 어긋난다
    // (code-review max). sidebarCardLines가 쓰는 순서와 같게 맞춘다. (둘 다 같은 해석 지점을 거치게 된
    // 지금은 순서가 무해하지만, 규율은 그대로 둔다 — 한쪽만 바뀌어도 어긋나지 않게.)
    const has_branch = git_ops.termGitBranch(self, term) != null;
    if (sidebarHasCwd(self, term)) {
        n += 1; // 폴더 줄
        if (has_branch) n += 1; // 브랜치 줄(repo 안일 때만 — 카드 보조줄과 같은 규칙)
    }
    // 마지막 **응답** 줄(§7). 프롬프트는 라벨 줄이 자리를 내주므로 줄 수를 늘리지 않는다. 세션 기록을 못 읽으면
    // (계약 1) 이 줄이 없어 행이 예전 높이로 돌아간다 — 조립부의 append 조건과 1:1이어야 한다.
    if (term.agent_transcript.reply().len > 0) n += 1;
    return n;
}

/// 카드 정보(줄 수·브랜치·경로)의 기준 Term — 활성 pane의 활성 Term이되 **teardown 중간 상태에서 null**을 낸다.
/// reap/close 캐스케이드는 Term을 제거한 뒤 pane/탭을 정리하기 **전에** 사이드바를 다시 투영할 수 있고, 그때
/// `tab.activePane().activeTerm()`은 길이 0 리스트를 인덱싱해 패닉한다(실측). 인덱스도 함께 clamp해 활성 인덱스가
/// 아직 시프트 보정되기 전이어도 안전하다.
pub fn sidebarCardTerm(tab: *Tab) ?*Term {
    if (tab.panes.items.len == 0) return null;
    const pane = tab.panes.items[@min(tab.active_pane, tab.panes.items.len - 1)];
    if (pane.terms.items.len == 0) return null;
    return pane.terms.items[@min(pane.active_term, pane.terms.items.len - 1)];
}

/// 이 Term이 **경로줄에 쓸 cwd**를 갖고 있는가 — `sidebarCwdPath`가 ""를 내는 조건의 할당 없는 판정판이다
/// (줄 수 계산은 매 rebuild마다 도므로 문자열을 만들지 않는다). 두 곳이 어긋나면 줄 수와 렌더가 갈린다.
pub fn sidebarHasCwd(self: *AppSession, term: *Term) bool {
    // 관측만 보던 자리다. 이제 소스 컨트롤·탐색기와 **같은 2단 규칙**(OSC 7 → 커널 조회)을 쓴다 — 판정과
    // 표시가 어긋나지 않게 `sidebarCwdPath`와 정확히 같은 해석 지점을 부른다. 여전히 **할당은 없다**
    // (스택 버퍼 + Term별 저주기 캐시라 OSC 7이 있는 Term은 syscall도 0이다).
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return git_ops.termCwdForDisplay(self, term, &buf) != null;
}

/// 카드가 **폴더줄을 그리는가** — 줄 수 계산(`sidebarCardLines`)과 조립부(`buildSidebarTitleFrame`)가 공유하는
/// 단일 판정이다. 두 곳이 어긋나면 행 높이와 글자가 갈려 "보이는 곳과 눌리는 곳이 다른" 회귀가 난다(이 파일의
/// 다른 줄 수 판정과 같은 규율).
///
/// 규칙은 "show-folder 토글 + cwd 있음"에 더해 **repo 안이거나 원격**이다. repo 조건만 두던 예전 규칙은 원격
/// 세션에서 폴더줄을 통째로 지웠다 — 브랜치는 로컬 `.git/HEAD` 읽기라 원격 경로에서는 항상 null이기 때문이다.
/// 원격에서는 이 줄이 "지금 어느 호스트의 어디에 있나"를 알려 주는 유일한 자리이므로 repo 여부와 무관하게
/// 그린다(docs/ssh-integration.md §9.3). 로컬 동작은 예전 그대로다.
pub fn sidebarFolderLineShown(self: *AppSession, term: *Term) bool {
    if (!self.loaded_config.config.sidebar.show_folder) return false;
    if (!sidebarHasCwd(self, term)) return false;
    if (app_session_mod.termCwdIsRemote(term)) return true;
    return git_ops.termGitBranch(self, term) != null;
}

/// 카드가 **실제로 그리는 줄 수**(이름 + 브랜치? + 경로? + 상태?). 카드 높이가 이 값에서 나오므로
/// (docs/sidebar-agent-list.md §3) 행 높이·hit-test·밴드·glyph 배치와 렌더(빈 줄을 생략하는 카드 조립부)가
/// **반드시 같은 값**을 봐야 한다 — 어긋나면 "보이는 곳과 눌리는 곳이 다른" 회귀가 난다. 그래서 조건을 카드
/// 조립부(buildSidebarTitleFrame)의 append 조건과 1:1로 맞춘 이 함수가 단일 출처다.
pub fn sidebarCardLines(self: *AppSession, tab: *Tab) u8 {
    const term = sidebarCardTerm(tab) orelse return 1; // teardown 중간 상태(빈 pane) 방어 — 아래 헬퍼 주석

    var n: u8 = 1; // 이름줄은 항상 그린다(사용자 요청 — 보조줄만 조건부)
    // 브랜치·경로줄은 **git repo 안**일 때만 존재한다(maru는 repo 밖 cwd 줄을 그리지 않는다). 그 전제 아래
    // 각 토글(show-branch·show-folder)이 독립적으로 줄을 켠다.
    if (git_ops.termGitBranch(self, term) != null) {
        if (self.loaded_config.config.sidebar.show_branch) n += 1;
        if (self.loaded_config.config.sidebar.show_folder and sidebarHasCwd(self, term)) n += 1;
    } else if (sidebarFolderLineShown(self, term)) n += 1;
    // 에이전트 상태줄은 카드에서 빠졌다(목록 행이 대체) — 줄 수도 그만큼 줄어 카드가 짧아진다.
    return n;
}

pub fn sidebarSearchLine(self: *const AppSession, max_col: u16) SidebarSearchLine {
    const ov = chrome.components.overlay_input;
    // 창(truncated/query/preedit) 계산은 find·palette와 **같은 단일 출처**(inputLineView)를 재사용한다 — 오버플로 규칙이
    // 한쪽만 바뀌어 드리프트하지 않게. 사이드바만 다른 건 caret 규약: '|' 글리프라 내용 **뒤**(query 끝+preedit)에 두므로,
    // inputLineView가 주는 query-끝 caret 대신 보이는 내용 폭(선두 "…"+query+preedit)으로 caret을 따로 계산한다.
    const line = ov.inputLineView(&self.sidebar_search_input, sidebar_search_text_col, max_col);
    const lead: u32 = if (line.truncated) 1 else 0; // 선두 "…" 1칸
    const shown: u32 = lead + ov.displayCols(line.query) + ov.displayCols(line.preedit);
    const caret: u16 = @intCast(@min(@as(u32, sidebar_search_text_col) + shown, @as(u32, max_col)));
    return .{ .truncated = line.truncated, .query = line.query, .preedit = line.preedit, .caret_col = caret };
}

/// 검색 caret rect(헤더 검색 영역) — IME 후보창이 붙는 자리. 렌더가 measured로 옮겨 갔으므로 **셰이핑된
/// advance**에서 얻는다(셀 col 환산이 아니라). caret 글리프 자체는 텍스트 run 끝의 `|`라 별도 좌표가 필요 없고,
/// 이 rect는 오직 후보창 anchor 용도다.
///
/// 캐시에 아티팩트가 없으면(첫 프레임 등) 텍스트 rect의 **시작점**으로 폴백한다 — 후보창이 잠깐 왼쪽에 뜨는 것이
/// 아예 안 뜨는 것보다 낫고, 다음 프레임에 정확한 자리로 옮겨간다.
pub fn sidebarSearchCaretRect(self: *AppSession) ?chrome.draw.Rect {
    if (!self.sidebar_search_active) return null;
    const rect = sidebarSearchTextRect(self) orelse return null;
    var advance: f32 = 0;
    if (self.sidebar_search_text_cache) |cache| {
        for (cache.placements) |p| advance = @max(advance, p.x_px + p.advance_px);
    }
    // 넘치면 CoreText가 앞을 잘라(anchor `.tail`) 내용이 rect 폭 안에 들어오므로, caret은 그 오른쪽 끝이다.
    const caret_x = rect.x + @as(i32, @intFromFloat(@min(advance, @as(f32, @floatFromInt(rect.w)))));
    return .{ .x = caret_x, .y = rect.y, .w = @max(self.cell_width_px, 1), .h = rect.h };
}

/// 행(카드·에이전트) 줄 수가 투영 당시와 달라졌으면 사이드바를 다시 투영한다.
///
/// **왜 필요한가**: 카드 줄 수는 활성 Term의 관측(cwd·git 브랜치)에서 파생되는데, 그 값은 투영 **뒤에** 바뀔 수
/// 있다. 두 경로가 실측으로 확인됐다(사용자 제보):
///
/// 1. **새 워크스페이스** — 관측이 채워지기 전에 투영돼 브랜치가 없는 1줄로 박힌다. 곧 관측이 도착해 렌더는
///    3줄을 그리지만 `Row.card.lines`는 1로 남는다.
/// 2. **Term 전환**(터미널 ↔ web 패널) — web Term은 cwd·브랜치가 없어 카드가 1줄, 터미널은 3줄이다. 같은 Pane
///    안에서 탭을 옮기면 카드 줄 수가 3↔1로 바뀐다.
///
/// 3. **cwd가 커널 폴백으로 늦게 온다** — 커널 조회는 자식이 foreground process group을 잡은 뒤에야 답하므로
///    첫 투영 때는 비고 다음 폴링에서 채워진다. 이건 **에이전트 행**에서 특히 잘 보인다(폴더줄이 다음 행의
///    라벨 위에 겹친다 — 제품 스크린샷으로 확인). 셸 통합이 없는 셸과 재개 Term이 상시 이 상태다.
///
/// 셋 다 결과가 같다: 밴드·hit-test가 쓰는 행 높이와 실제로 그려지는 글자가 어긋나, 활성 밴드가 이름줄이 아니라
/// 브랜치 줄에 걸리거나 보조줄이 아래 행을 침범한다. 에이전트 행은 응답 도착 경로만 재투영을 걸고 있어 cwd
/// 경로가 비어 있었다 — 그래서 여기서 **두 종류를 함께** 본다.
///
/// **고정 높이(min-height)로 덮지 않는 이유**: 그러면 1줄 카드도 3줄 자리를 차지해 목록이 그만큼 길어지고,
/// "카드 높이는 내용에 따라 다르다"는 이 기능의 전제(docs/sidebar-agent-list.md §3)와 정면으로 충돌한다.
/// 어긋남의 원인은 높이가 변하는 것이 아니라 **변한 뒤 다시 투영하지 않는 것**이다.
///
/// `sidebarCardLines`·`sidebarAgentRowLines`가 각 행 줄 수의 단일 출처이므로 그 값과 박힌 값을 그대로 대조한다. 값이 실제로 달라졌을 때만
/// 재투영한다.
///
/// **비용**: 이 비교는 카드마다 `termGitBranch`와 `sidebarHasCwd`를 부르고 둘 다 `termCwd`를 거친다. OSC 7을
/// 받는 Term은 그 자리에서 관측 값을 돌려주므로 syscall이 0이고, 안 받는 Term만 `proc_pidinfo`로 내려가는데
/// 그것도 **Term별 0.5초 캐시**(`term.rt.proc_cwd_*`)를 지난다. 즉 최악이 Term당 초당 2회이며, 그 캐시가
/// AppSession 단일 슬롯이 아니라 Term별인 이유가 정확히 여기다 — 한 칸이면 이 루프가 카드마다 서로를 밀어내
/// 매 tick 전수 syscall이 된다. `.git/HEAD` 읽기는 그 위에서 cwd가 바뀔 때만 도는 별도 캐시다.
pub fn reprojectSidebarIfRowLinesStale(self: *AppSession) void {
    if (self.sidebar_collapsed or self.chrome_minimal) return; // 그릴 자리가 없으면 볼 이유도 없다
    var stale = false;
    for (self.sidebar_rows.items) |row| switch (row) {
        .card => |c| {
            if (c.tab >= self.tabs.items.len) continue;
            if (sidebarCardLines(self, self.tabs.items[c.tab]) != c.lines) {
                stale = true;
                break;
            }
        },
        // **에이전트 행도 같은 이유로 낡는다.** 예전에는 카드만 봤는데, 그때는 이 행의 보조줄(폴더·브랜치)이
        // OSC 7에만 달려 있었고 그 값은 대개 첫 투영 **전에** 도착해 어긋남이 드물었다. cwd가 커널 폴백까지
        // 가면서 값이 투영 **뒤에** 오는 경우가 흔해졌다 — 커널 조회는 자식이 foreground process group을 잡은
        // 뒤에야 답하므로 첫 투영 때는 비고 다음 폴링에서 채워진다. 그러면 행 높이는 1줄인데 렌더는 2줄을
        // 그려 **폴더줄이 다음 행의 라벨 위에 겹친다**(제품 스크린샷으로 실제 확인).
        .agent => |g| {
            if (g.tab >= self.tabs.items.len) continue;
            if (sidebarAgentRowLines(self, self.tabs.items[g.tab], .{ .pane = g.pane, .term = g.term }) != g.lines) {
                stale = true;
                break;
            }
        },
        else => {},
    };
    if (!stale) return;
    rebuildSidebar(self) catch return;
    self.metal_dirty = true;
}

/// 사이드바 strip 배경색(0xAARRGGBB). resolved 테마의 `sidebar_background`를 읽기만 한다 — 색 파생
/// (명시 없으면 배경 +24)은 config resolver(resolveTheme)가 단일 출처로 소유한다. 테마가 명시하면 그 색.
pub fn sidebarBg(self: *const AppSession) u32 {
    return packOpaqueRgb(self.appearance.theme.sidebar_background);
}

/// 활성 탭 하이라이트 밴드 배경색(0xAARRGGBB). resolved 테마의 `sidebar_active`를 읽기만 한다 — 명시
/// 없으면 배경 +48(사이드바 배경보다 한 단계 밝게)로 resolveTheme가 파생한다. 테마가 명시하면 그 색.
pub fn sidebarActiveBg(self: *const AppSession) u32 {
    return packOpaqueRgb(self.appearance.theme.sidebar_active);
}

/// 호버 슬롯 하이라이트 배경색(0xAARRGGBB) — 사이드바 배경(+24)과 활성(+48)의 중간으로 파생한다.
/// 별도 테마 필드 없이 두 resolved 색의 채널 평균을 써서, 사용자가 사이드바 색을 커스텀해도 호버가
/// 그 사이 톤을 따라간다(활성보다 약하고 배경보다 또렷한 호버 피드백).
/// 목록 행(에이전트 행·토글) 호버 배경 — **활성 밴드 위에 겹쳐도 구분되도록** 활성색을 배경 반대 방향으로 한
/// 단계 더 민다. 배경↔활성이 이루는 방향을 그대로 연장하므로 사용자가 사이드바 색을 바꿔도 관계가 유지된다
/// (호버가 활성보다 한 톤 밝다). 채널 포화는 클램프한다.
/// **식은 `chrome.tokens.rowHoverBg`가 소유한다.** 2026-08-17까지 같은 계산이 이 파일에도 있었고 토큰
/// 쪽은 `sidebar_active`를 그대로 담고 있었다 — 그래서 사이드바만 활성보다 밝은 호버를 얻고 chrome
/// 컴포넌트(도크 카드·버튼)는 활성과 **완전히 같은 색**을 받았다(적대적 검증에서 드러났다). 식을 토큰
/// 층으로 올리고 여기서 호출한다(`tokens.statusBarBg`와 같은 관계).
pub fn sidebarRowHoverBg(self: *const AppSession) u32 {
    const hover = chrome.tokens.rowHoverBg(
        self.appearance.theme.sidebar_background,
        self.appearance.theme.sidebar_active,
    );
    return 0xFF00_0000 | (@as(u32, hover.r) << 16) | (@as(u32, hover.g) << 8) | hover.b;
}

pub fn sidebarHoverBg(self: *const AppSession) u32 {
    const a = self.appearance.theme.sidebar_background;
    const b = self.appearance.theme.sidebar_active;
    const r: u32 = (@as(u32, a.r) + b.r) / 2;
    const g: u32 = (@as(u32, a.g) + b.g) / 2;
    const bch: u32 = (@as(u32, a.b) + b.b) / 2;
    return 0xFF00_0000 | (r << 16) | (g << 8) | bch;
}

/// 스크린 x가 세로 사이드바 영역 안인가(순수 `xInSidebar` 래퍼).
pub fn inSidebar(self: *const AppSession, x_px: f64) bool {
    return chrome.components.sidebar.inSidebar(x_px, self.sidebar_width_px);
}

/// 사이드바 y → 탭 슬롯 인덱스(순수 `sidebarSlot` 래퍼 — 슬롯 높이·탭 수·스크롤로 판정).
pub fn sidebarSlotAt(self: *const AppSession, y_px: f64) ?usize {
    // 가변 높이(카드=slot_h·헤더=cell_h). 반환은 row 인덱스(호출처 visibleTab이 row→tab). header_row_h는 SG3b-2에서
    // 헤더 row가 실제로 생길 때 의미를 갖고, 지금(카드만)은 안 쓰인다 — cell_height_px를 근사로 넘긴다.
    return chrome.components.sidebar.slotAt(y_px, self.sidebar_header_height_px, self.sidebar_rows.items, sidebarMetrics(self), self.sidebar_scroll_offset_px);
}

/// Deferred launch can intentionally have no terminal surface while `Recovered Sessions` is the
/// only actionable UI.  `AppSession.mouse` normally rejects every pointer event in that state, so
/// this narrow pre-surface seam admits only a primary click on a typed recovered row.  It cannot
/// select, close, drag, rename, or reach terminal input because every other coordinate returns
/// false and remains behind the ordinary surface gate.
pub fn activateRecoveredRowBeforeInitialSurface(
    self: *AppSession,
    kind: i32,
    x_px: f64,
    y_px: f64,
    button: i32,
) bool {
    if (self.surface_initialized or kind != 1 or button != 0 or !inSidebar(self, x_px)) return false;
    const slot = sidebarSlotAt(self, y_px) orelse return false;
    if (slot >= self.sidebar_rows.items.len or self.sidebar_rows.items[slot] != .recovered_session)
        return false;
    const candidate = self.sidebar_rows.items[slot].recovered_session;
    self.activateRecoveredSessionAt(candidate.projection_index) catch {
        self.showNoticeKey(.app_recovered_session_failed);
    };
    return true;
}

/// 사이드바 뷰포트의 세로 구간(backing px) — **하단 경계의 단일 출처**(`AppSession.SidebarViewport` 문서 참조).
/// 순수 산술이라 헤드리스로 단언할 수 있고, self 래퍼는 아래 `sidebarViewport`다.
pub fn sidebarViewportPx(backing_height_px: u32, header_height_px: u32, status_bar_height_px: u32) SidebarViewport {
    return .{ .top = header_height_px, .bottom = backing_height_px -| status_bar_height_px };
}

/// 세션 필드로 `sidebarViewportPx`를 부르는 래퍼. 소비처(스크롤·scissor·스크롤바)가 "헤더는 빼고 상태바도
/// 빼고"라는 조합을 각자 다시 적지 않게 한다 — 그렇게 흩어져 있다가 한 곳이 상태바를 빠뜨린 것이 이 함수가
/// 생긴 이유다.
pub fn sidebarViewport(self: *const AppSession) SidebarViewport {
    return sidebarViewportPx(self.backing_height_px, self.sidebar_header_height_px, self.statusBarHeightPx());
}

/// 사이드바 콘텐츠(표시 카드 전체 높이)가 뷰포트를 넘는 양(backing px). 0이면 스크롤 불필요.
/// 순수 산술은 sidebarMaxScrollPx에 둬(헤드리스 단위 테스트) self는 뷰포트 높이만 떠 넘긴다.
pub fn sidebarMaxScroll(self: *const AppSession) u32 {
    // 가변 높이(카드=slot_h·헤더=header_row_h): 콘텐츠 높이를 rows.len*slot_h 대신 contentHeight 누적으로 구한다
    // (code-review #7 — 헤더를 slot_h로 세면 over-travel). 카드만이면 rows.len*slot_h와 같아 동작 보존.
    // 도메인은 **sidebarRenderRows()**(SG8): collapsed 그룹 드래그는 subtree를 force-emit해 preview_rows가 sidebar_rows
    // 보다 길어지는데, 짧은 sidebar_rows로 content 높이를 재면 스크롤이 안 되고(max=0) thumb가 과대해진다. 렌더가
    // 보는 rows와 같은 도메인으로 재야 정합. 비드래그면 preview=null이라 sidebar_rows와 동일(byte-identical).
    const content_h = chrome.components.sidebar.contentHeight(sidebarRenderRows(self), sidebarMetrics(self));
    // 뷰포트는 헤더 아래에서 시작해 상태바 위에서 끝난다 — 그 산술은 sidebarViewport가 소유한다.
    return sidebarMaxScrollPx(content_h, sidebarViewport(self).height());
}

/// 사이드바 스크롤 오프셋을 [0, sidebarMaxScroll]로 잡는다. 탭 추가/삭제·검색 필터·resize·휠로 콘텐츠/뷰포트가
/// 바뀌면 stale 오프셋이 자동 정정된다(tab_scroll_cols 재clamp 선례). rebuildSidebar가 표시 탭 재계산 직후 호출.
pub fn clampSidebarScroll(self: *AppSession) void {
    const max = sidebarMaxScroll(self);
    if (self.sidebar_scroll_offset_px > max) self.sidebar_scroll_offset_px = max;
}

/// SG8d — 렌더가 소비하는 표시 행(docs/plans/sidebar-groups.md §9 SG8, 렌더/hit-test 도메인 분리). **카드 드래그 프리뷰**
/// 중(sidebar_drag_preview!=null)엔 고스트를 담은 `sidebar_preview_rows`를, 아니면 원본 `sidebar_rows`를 돌려준다.
/// hit-test(slotAt·dragTargetSlot·visibleTab·sidebarGroupDropTargetTab)는 **항상 원본 sidebar_rows**를 봐 드래그 중
/// self.tabs·plan 계산 기준이 불변이라 yo-yo가 원천 차단된다 — 오직 렌더 소비자(view·glyph·py_top·tint/accent·⌘배지)만
/// 이 헬퍼로 preview_rows를 본다. move(순열) 모델이라 두 배열 길이가 같아 스크롤 높이·정합이 흔들리지 않는다.
pub fn sidebarRenderRows(self: *const AppSession) []const chrome.components.sidebar.Row {
    return if (self.sidebar_drag_preview != null) self.sidebar_preview_rows.items else self.sidebar_rows.items;
}

/// 사이드바 표시 row가 고정 핀(📌)을 그리는가(그룹 고정 C2 — docs/sidebar-groups-pinning.md §12.8 GP4). buildSidebarTitleFrame이
/// `pins[]`를 채울 때와 헤드리스 테스트가 공유하는 **단일 출처**(rename 억제는 호출처 몫 — 편집 폭 보존). 규칙:
///  · **group_header row = 그룹 고정 인디케이터**: 마커 탭(gh.tab) pinned이면 📌(헤더 이름줄 우측 끝). "이 그룹 고정됨"을
///    헤더 하나에만 표시한다(멤버 카드마다 뜨는 노이즈 대신). 마커 = 그룹 고정 권위(§12.2)라 라이브 pinned가 곧 그룹 고정.
///  · **card row = 개별 최상위 pin만**: (0) **local_pinned(그룹-로컬 pin GL §13.6)면 📌 — pin_derived보다 먼저 보는 선두
///    분기**. 로컬 pin은 실제 사용자 pin이라(그룹째 고정 파생 캐시와 달리) 억제하지 않고 멤버 카드에 📌를 살린다(그룹째 고정
///    그룹 안 로컬 pin 멤버 공존 시 헤더 그룹📌 + 멤버 로컬📌, 단일 글리프 U+1F4CC 수용 — §13.6 결정). (1) pin_derived(멤버
///    파생 캐시)면 억제 — 그룹 고정은 헤더가 든다. (2) 그룹 마커 카드(group_start!=null)면 억제 — 마커의 자기 카드도 그룹
///    소속이라 헤더 인디케이터로 대체(pin_derived=false지만 억제). (3) 그 외 최상위 카드만 live `tab.pinned` 그대로 📌(개별
///    위치 고정). 도메인은 sidebarRenderRows()(드래그 중 preview_rows).
pub fn sidebarRowShowsPin(self: *const AppSession, row: chrome.components.sidebar.Row) bool {
    return switch (row) {
        .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => false, // 목록/system 행은 pin 대상이 아니다.
        .group_header => |gh| gh.tab < self.tabs.items.len and self.tabs.items[gh.tab].pinned,
        .card => |c| blk: {
            if (c.local_pinned) break :blk true; // 로컬 pin 멤버 📌(§13.6 선두 분기 — pin_derived 억제보다 우선)
            if (c.pin_derived) break :blk false; // 멤버 파생 pin 억제(§12.8) — 그룹 헤더가 인디케이터
            if (c.tab >= self.tabs.items.len) break :blk false;
            const tab = self.tabs.items[c.tab];
            if (tab.group_start != null) break :blk false; // 그룹 마커 카드 — 헤더로 인디케이터(자기 카드 📌 억제)
            break :blk tab.pinned; // 최상위 개별 pin만 📌 유지
        },
    };
}

/// 카드 드래그 프리뷰 정리(up 확정·드래그 취소·teardown 공통) — 고스트 상태와 투영 버퍼를 비운다. 이후 rebuild가
/// sidebarRenderRows()로 원본 sidebar_rows 렌더에 복귀한다(preview=null이면 원본을 돌려줌).
pub fn clearSidebarDragPreview(self: *AppSession) void {
    self.sidebar_drag_preview = null;
    self.sidebar_preview_rows.clearRetainingCapacity();
}

/// SG8d/e 드래그 프리뷰 확정(docs/plans/sidebar-groups.md §9 SG8) — 마지막 plan을 실제 move로 **정확히 1회** 커밋하고 프리뷰를
/// 정리한다(재계산 금지 = up-시점 재계산은 프리뷰-확정 타이밍 divergence). 카드(moveTab)·그룹 형제(moveGroupSibling)·
/// 중첩(moveGroupNesting)·none(제자리) 모두 처리한다 — simulateDrop이 이 함수들과 등가임을 SG8b 헤드리스가 고정해
/// 프리뷰(고스트)와 확정이 갈리지 않는다. 프리뷰를 **먼저** 비워 move 내부 rebuild가 원본(preview=null) 레이아웃 위에
/// 확정 순서를 반영하고, move가 no-op(변화 없음)이거나 none이어도 고스트가 남지 않게 끝에서 rebuild+dirty를 보장한다
/// (up 경로라 중복 rebuild 비용 무시 가능). 프리뷰가 없으면 no-op(드래그 중 이동 프레임이 없던 up).
pub fn commitSidebarDragPreview(self: *AppSession) void {
    const dp = self.sidebar_drag_preview orelse return;
    const plan = dp.plan;
    const origin = dp.origin;
    clearSidebarDragPreview(self);
    switch (plan) {
        .card => |c| {
            // **고정 흡수 금지(확정)**: 드래그 소스가 pinned면 top_level=true를 강제한다(cardDropPlan/simulateDrop과 동일 규칙).
            // moveTab이 origin을 회전시켜 이동 후엔 origin 위치가 소스가 아니므로 **moveTab 전에** 라이브 pinned를 캡처한다.
            const source_pinned = origin < self.tabs.items.len and self.tabs.items[origin].pinned;
            // GL §13.5(프리뷰=확정 엣지): 로컬 pin 멤버 드래그는 commit도 simulateDrop과 **같은** subtree-로컬 프리픽스
            // clamp를 태운다. 마커 자기 카드 위로 드롭하면 raw moveTab이 카드를 마커 **앞**(top-level)으로 eject해 뒤이은
            // floatLocalPins가 회수 못 하던(프리뷰≠확정) 엣지를 닫는다. clampMoveToGroup(전역 핀 리전) 위에
            // localPinPrefixBounds(subtree 프리픽스)를 겹쳐 simulateDrop 카드 경로와 **동일 착지**를 낸다. bounds=null
            // (비-로컬-pin)이면 raw target 그대로(moveTab 내부 clampMoveToGroup만) = 기존 카드 드래그 동작. self.tabs는
            // clearSidebarDragPreview가 안 건드려(프리뷰 상태만 clear) moveTab 직전까지 canonical이라 clamp가 정직하다.
            var target = c.target_tab;
            if (origin < self.tabs.items.len and target < self.tabs.items.len) {
                if (tab_ops.localPinPrefixBounds(self, origin)) |b| {
                    const region = clampMoveToGroup(target, self.tabs.items[origin].pinned, tab_ops.countPinnedTabs(self), self.tabs.items.len);
                    target = std.math.clamp(region, b.lo, b.hi);
                }
            }
            // §14 경계 유지(finding #2): origin이 **top_level 경계 홀더**면 뒤 sticky follower에 경계를 재확립한다 — 이동으로
            // origin이 빠져도 follower가 앞 그룹에 흡수되지 않게. simulateDrop 프리뷰의 **같은 조건·같은 지점**(rotateMove 전)과
            // 대칭이라 프리뷰=확정. 실제 이동이 없으면(landed==origin, 제자리 드롭) 경계 소실이 없으니 아래에서 되돌린다.
            const len0 = self.tabs.items.len;
            const restore_boundary = origin > 0 and origin < len0 and origin + 1 < len0 and
                self.tabs.items[origin].top_level and
                self.tabs.items[origin + 1].group_start == null and !self.tabs.items[origin + 1].top_level and
                self.tabs.items[origin + 1].pinned == self.tabs.items[origin].pinned and
                tab_ops.enclosingGroupMarkerIndex(self, origin - 1) != null;
            if (restore_boundary) self.tabs.items[origin + 1].top_level = true;
            const landed = tab_ops.moveTab(self, origin, target); // SG8d 카드 — 반환값 = clamp 후 실제 안착 인덱스(no-op이면 origin)
            if (restore_boundary and landed == origin and origin + 1 < self.tabs.items.len)
                self.tabs.items[origin + 1].top_level = false; // 제자리 드롭 = 경계 소실 없음 → spurious flag 되돌림
            // §14.6 SR4 model-2: 드롭 컨텍스트 top_level 전이를 **실제 write**로 확정한다(프리뷰의 가상 override와 등가).
            // 실제로 옮겼을 때(landed != origin)만 전이하고, simulateDrop 카드 경로와 **같은** 게이트(hasGroupMarkerAboveInRegion —
            // null=post-move self.tabs 직접)를 적용해 프리뷰=확정을 맞춘다. moveTab이 clamp한 landed가 simulateDrop의 `to`와
            // 같아(같은 clampMoveToGroup+localPin) 프리뷰가 본 착지에 그대로 write한다. 그룹 안 드롭(c.top_level=false)은 false
            // write라 top카드가 멤버로 흡수될 때 stale flag를 clear한다. 전이 안 하는 드래그(그룹 없음·leading·in-place)는 게이트
            // 가 false거나 landed==origin이라 write가 없어 byte-identical(회귀 0). normalize/float는 아래에서 이 write를 반영한다.
            // 고정 소스는 `c.top_level or source_pinned`로 강제 true(simulateDrop 프리뷰와 대칭 → 프리뷰=확정). MARU_DEBUG면
            // 저장 plan.top_level vs 실제 write를 한 줄로 찍어 "commit이 저장 plan을 그대로 쓴다"(프리뷰=확정)를 실증한다
            // (cardDropPlan 로그와 짝 — 사용자 재현 대비). landed==origin(제자리)이면 write 없음(top_level 불변).
            if (landed != origin and landed < self.tabs.items.len) {
                const tl = (c.top_level or source_pinned) and self.hasGroupMarkerAboveInRegion(landed, null, null);
                self.tabs.items[landed].top_level = tl;
                if (diag_gate.maruDebugEnabled()) std.log.scoped(.sidebar_card_drag).info(
                    "commit card: origin={d} landed={d} plan_top_level={} src_pinned={} top_level_written={}",
                    .{ origin, landed, c.top_level, source_pinned, tl },
                );
            } else if (diag_gate.maruDebugEnabled()) std.log.scoped(.sidebar_card_drag).info(
                "commit card: origin={d} landed={d} plan_top_level={} src_pinned={} (no move — top_level unchanged)",
                .{ origin, landed, c.top_level, source_pinned },
            );
        },
        .group_sibling => |g| _ = tab_ops.moveGroupSibling(self, origin, g.insert_before), // SG5-1 형제 + SG5-4 빼기
        .group_nest => |g| _ = tab_ops.moveGroupNesting(self, origin, g.insert_before, g.target_depth), // SG5-4 넣기
        .none => {}, // 제자리 — 고스트만 제거(아래 rebuild가 원본 복귀)
    }
    // 그룹 고정 C2(§12.5 GP2): 드래그 확정으로 카드/그룹이 재배치됐으니 멤버 pinned 캐시를 새 위치의 enclosing 마커
    // 기준으로 재동기. 위 clearSidebarDragPreview로 sidebar_drag_preview=null이 된 **커밋 후**라 normalize 게이트를
    // 통과한다(프리뷰 중엔 안 돌던 것이 여기서 처음 도는 정직한 지점 — SG8 "드래그 내내 self.tabs 불변" 보존).
    self.normalizePinnedFromGroups();
    // 그룹-로컬 pin 재float(GL §13.4 배선 + §13.5 re-partition-on-commit): 로컬 pin 멤버 드래그의 확정. simulateDrop이
    // 프리뷰를 subtree-로컬 프리픽스로 clamp한 것과 **대칭**으로, moveTab이 프리픽스 밖으로 냈어도 여기서 다시 float해
    // 프리픽스로 snap-back한다 → 프리뷰=확정(SG8 불변식 B). clearSidebarDragPreview 후라 stablePartitionSubtree 게이트 통과.
    self.floatLocalPinsAllGroups();
    // 위생(GL §13.7): 드래그로 그룹 밖 top-level로 나간 카드의 stale local_pinned 클리어(고아 📌 방지). 로컬 pin 멤버는
    // 위 프리픽스 clamp가 그룹 안에 가둬 실제로는 안 나가지만(clamp 대상=그룹 안 이동), 비-pin 카드가 그룹 밖으로 빠지는
    // 경로·desync를 방어하는 단일 출처 위생 스윕이다(ungroup·removeFromGroup과 동형). float 뒤라 멤버는 이미 프리픽스 안착.
    self.clearStaleLocalPins();
    rebuildSidebar(self) catch {}; // 고스트 제거 + 확정 레이아웃(move 내부 rebuild와 idempotent — no-op/none도 정리)
    self.metal_dirty = true;
}

/// 세로 사이드바 셀(탭 엔트리 밴드)을 다시 만든다 — 활성 탭 행에 하이라이트 밴드, 그리고 호버 슬롯이
/// 활성과 다르면 그 행에 (더 약한) 호버 밴드를 emit한다. 탭 i는 행 i에 대응한다(한 탭=한 슬롯). 제목
/// glyph는 여기서 안 만든다(tick의 제목 패스가 따로 더해 metal_buffer가 밴드와 머지). 사이드바가
/// 꺼졌거나(폭 0) cell 폭 미상이면 비운다. 탭 추가/전환/메트릭/호버 변경 때 호출한다. 실패(OOM)는
/// 세션을 죽이지 않고 빈 사이드바로 degrade한다(호출부가 catch).
pub fn rebuildSidebar(self: *AppSession) !void {
    // **자기 레이어(0)만 비운다.** 옛 코드는 `gpu_quads`를 통째로 비웠는데, 이 함수는 hover·드래그·탭 전환 등
    // 수십 개 이벤트 핸들러에서 **tick 사이에** 불린다. 그 직후 tick이 full 투영이 아니면(sync hold + chrome
    // 애니메이션 없음 → idle 분기) per-frame 레이어(탭 밴드 2·스크롤바 3·배지 4)가 재충전되지 않아 **그 프레임에
    // 통째로 사라진다** — 지금까지는 그 조합이 드물어 드러나지 않았을 뿐이고, per-frame 표면이 하나 늘 때마다
    // 노출이 커진다. layer 0만 비우면 retained 계약(사이드바는 이 함수가 소유)과 정확히 일치한다.
    self.dropQuadsByLayer(0);
    tab_ops.recomputeVisibleTabs(self); // 검색 필터로 표시 카드(sidebar_rows) 갱신 — 아래는 전부 표시 슬롯 기준
    clampSidebarScroll(self); // 표시 카드 수/뷰포트가 바뀌었을 수 있으니 stale 스크롤 정정 — 아래 quad가 이 오프셋을 쓴다
    if (self.tabs.items.len == 0) return;
    // 밴드(활성/호버 슬롯·"+" 호버)는 chrome `sidebar.view`가 fill op으로 단일 출처. `lowerSidebar`가 그 fill을
    // sidebarBandCell(행=슬롯)로 lower한다(색·NativeMetalCell은 platform). host가 중립 Tab(활성)을 주입(palette Row 선례).
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // SG8d: 렌더는 sidebarRenderRows()(카드 드래그 중=고스트 포함 preview_rows, 아니면 원본 sidebar_rows)를 본다.
    // recomputeVisibleTabs(위)가 sidebar_rows를 채우고(hit-test 도메인), refreshDragPreview가 preview_rows를 채운다.
    const rows = sidebarRenderRows(self);
    // 드롭 타겟 하이라이트 슬롯: 이제 **pane grip 드래그(pane_drop_slot)만** 이 밴드를 쓴다(SG8f) — 사이드바 카드·그룹
    // 드래그(SG4/SG5/SG8)는 고스트+삽입선 프리뷰로 전환돼 옛 sidebar_drop_slot 하이라이트를 제거했다. 사이드바 드래그
    // 프리뷰 중(sidebar_drag_preview!=null)엔 밴드 하이라이트를 아예 끈다(고스트+삽입선이 대체 — 원본 인덱스 drop_slot을
    // preview_rows에 얹으면 엉뚱한 row 오강조). pane grip 드래그는 별도 경로라 프리뷰와 상호배타(둘 중 하나만 활성).
    const pane_drop_slot: ?usize = switch (self.pointer_gesture_owner) {
        .pane => |drag| drag.drop_slot,
        else => null,
    };
    const drop_slot = if (self.sidebar_drag_preview != null) null else pane_drop_slot;
    var ops: std.ArrayList(chrome.draw.Op) = .empty;
    chrome.components.sidebar.view(rows, self.hovered_slot, drop_slot, self.buildChromeProps(), arena, &ops) catch return;
    lowerSidebar(self, ops.items);
    // 헤더(검색바) 하단 구분선 — 검색 줄과 카드 목록 사이 경계를 명확히(사용자 요청 "Searchbar에 언더바"). divider
    // 색·border 두께로 사이드바 폭 전체에 가로선(layer 0=사이드바 retained). 검색 줄 바로 아래(=header_h 하단)에 둔다.
    if (self.sidebar_width_px > 0 and self.sidebar_header_height_px > 0) {
        const tk = self.buildChromeTokens();
        const thickness: f32 = @floatFromInt(@max(@as(u32, 1), tk.border.line_thickness_px));
        const uy: f32 = @as(f32, @floatFromInt(self.sidebar_header_height_px)) - thickness;
        self.appendSolidQuad(0, uy, @floatFromInt(self.sidebar_width_px), thickness, pane_ops.dividerColor(self), 0);
    }
    // 헤더 아이콘 호버 배경(웹 버튼 hover) — hovered_header_region이 아이콘이면 그 아이콘 뒤에 둥근 quad(layer 0,
    // 아이콘 셀 아래). 아이콘 col은 buildSidebarHeaderDrawList과 같은 단일 레이아웃(◧ cols-8·⚙ cols-5·+ cols-2).
    // 아이콘은 .m이 1.7×로 확대+py_nudge 0.30하므로 셀 중심(가로)·~0.8ch(세로)에 앉는다 — quad를 거기에 맞춰 약 2칸×
    // 1.7줄로 덮고 가운데 정렬. 색은 탭 ‹›/슬롯 호버와 같은 sidebarHoverBg(중간 톤).
    if (self.hovered_header_region) |hr| {
        if (self.cell_width_px > 0 and self.cell_height_px > 0 and self.sidebar_width_px / self.cell_width_px >= 10) {
            const cols: u32 = self.sidebar_width_px / self.cell_width_px;
            const icon_col: u32 = switch (hr) {
                .toggle_sidebar => cols -| 8,
                .view_options => cols -| 5,
                .new_workspace => cols -| 2,
                .notifications => cols -| 12, // 벨 글리프(col cols-12, 2칸 폭)와 hover 정렬 — 2.6칸 폭 quad가 cols-12·cols-11 글리프를 덮는다
                .search, .none => cols, // 도달 안 함(setHoveredHeaderRegion이 정규화) — 안전값
            };
            const cw: f32 = @floatFromInt(self.cell_width_px);
            const ch: f32 = @floatFromInt(self.cell_height_px);
            // hover quad 중심 = 글리프 중심. 1칸 아이콘(◧⚙+)은 셀 중심 (icon_col+0.5)cw. 종(notifications)은 EAW
            // width 2라 .m(is_bell_icon)이 2칸 footprint 중앙 (icon_col+1)cw에 그리므로 +1.0이라야 한다 — +0.5면 왼쪽
            // 셀(cols-12) 중심에 박스가 떨어져 좁아진 종이 박스 우측으로 치우쳐 보인다(예전 3.4cw 종은 박스보다 커서
            // 0.5cw 어긋남이 안 보였으나, width-2 수정으로 1.7cw가 되며 드러난 기존 버그).
            const center_cells: f32 = if (hr == .notifications) 1.0 else 0.5;
            const center_x: f32 = (@as(f32, @floatFromInt(icon_col)) + center_cells) * cw; // 글리프 중심(=.m gscale/footprint 중심)
            const w: f32 = cw * 2.6; // 좌우 패딩을 더 줘 버튼처럼(아이콘 ~1.7칸 + 양옆 여백) — 사용자 피드백
            const h: f32 = ch * 1.7;
            const radius: f32 = @min(w, h) * 0.28; // 둥근 버튼
            // 호버 배경은 **전경색(밝음) 기반 반투명**으로 둔다. 헤더 아이콘 glyph는 터미널 셀 패스(draw 1b)에,
            // 이 호버 quad는 layer 0(under, draw 3)이라 아이콘 '뒤'가 아니라 '위'에 그려진다(그 사이에 끼울 패스가
            // 없음). 그래서 중간톤/불투명이면 아이콘을 어둡게 덮었다(사용자 피드백). 밝은 전경색을 낮은 알파로 깔면
            // 어두운 사이드바 배경 위엔 밝은 하이라이트로 보이고, 밝은 아이콘 위엔 같은 밝기라 아이콘이 안 어두워진다.
            // GpuQuad는 **straight-alpha**(packRgbAlpha) — SDF quad 셰이더가 rgb*=a로 직접 premultiply한다
            // (스크롤바 quad와 같은 규약). premultipliedRgba를 쓰면 셰이더가 또 곱해 ~4배 흐려진다(코드리뷰 발견).
            const hover_fill = packRgbAlpha(self.appearance.theme.sidebar_foreground, 0x40); // ≈25% 밝은 하이라이트
            self.gpu_quads.append(self.allocator, .{
                .x = center_x - w / 2.0,
                .y = 0,
                .w = w,
                .h = h,
                .corner_radii = .{ radius, radius, radius, radius },
                .border_widths = .{ 0, 0, 0, 0 },
                .fill_color0 = hover_fill,
                .fill_color1 = hover_fill,
                .border_color = 0,
                .gradient_kind = 0,
                .layer = 0,
            }) catch {};
        }
    }
    // per-tab 카드별 색(우클릭 메뉴 "배경: …"·"바: …") — chrome draw op은 role 기반이라 임의 RGB를 못 실어, 배경 tint와
    // 좌측 accent 막대 **둘 다** platform이 명시-색 GpuQuad로 직접 lower한다(같은 카드를 한 번에 처리하는 단일 패스).
    // 한 카드에서 tint를 먼저, 막대(좌단 불투명)를 뒤에 append해 막대가 tint 위에 또렷이 얹힌다(텍스트 셀은 그 위 패스).
    // 막대는 활성 카드=지정색 or 기본 테마 accent·비활성 카드=지정 시에만. y는 f32 도메인으로 곱해 i32 overflow 회피.
    const slot_h = self.sidebar_slot_height_px;
    const card_tk = self.buildChromeTokens();
    const bar_w = card_tk.space.accent_bar_width_px;
    // 카드 rect는 **chrome이 준다**(`sidebar.spanRect`/`cardSpanEnd` — 밴드 `bandFillSpan`과 같은 함수).
    // 여기서 좌표를 다시 계산하지 않는다: per-card 배경 tint·좌측 accent 막대·드래그 고스트는 밴드와 **겹쳐**
    // 그려지므로 기하가 두 벌이면 반드시 드리프트한다(사방 card_gap 인셋을 폐기할 때 실제로 겪었다 —
    // docs/sidebar-agent-list.md §3.2). platform이 더하는 건 **헤더 시프트와 색**뿐이다.
    const default_accent = packOpaqueRgb(card_tk.palette.get(.accent_bar)); // 기본(지정 없음) 활성 카드 accent(테마-구동)
    // SG5-2: 지금 순회 중인 카드가 속한 그룹의 공통 색(위 그룹 헤더에서 얻음). projectRows가 헤더를 소속 카드보다
    // 먼저 내므로(§6·연속 파티션), 헤더 row를 지날 때 갱신해 두면 이후 카드 막대에 그 색을 실을 수 있다(위치 파생
    // 동형 — 카드에 색을 저장하지 않고 순회 중 "위 마커의 색"을 따른다). 최상위 카드는 첫 헤더 이전이라 0으로 유지된다.
    var current_group_color: u32 = 0;
    var prev_pinned: ?bool = null; // 핀 리전 경계 추적(§12 GP1) — 리전 경계에서 그룹 색 상속 차단
    if (slot_h > 0 and self.sidebar_width_px > 0) for (rows, 0..) |row, i| {
        // 핀 리전 경계(고정→비고정 등)에서 current_group_color를 리셋한다 — 이 색은 헤더 row에서만 갱신되므로,
        // "고정 색 그룹" 뒤 **비고정 top카드**(다른 리전·자기 리전 첫 마커 이전이라 무색이어야 함, depth 0)가 그 색을
        // 상속하는 것을 막는다(§12). 헤더/카드 모두 자기 마커 탭의 pinned로 리전을 판정한다 — 헤더는 곧 색을 덮어쓰므로
        // 리셋이 무해하고, 비고정 top카드는 리셋된 무색을 그대로 쓴다(비고정 헤더 뒤 멤버는 리전 동일이라 안 리셋).
        // ghost 카드도 self.tabs pinned가 드래그 내내 불변이라 추적이 안정. 고정 그룹 0개면 flip이 없어 no-op(byte-identical).
        const row_pinned: ?bool = switch (row) {
            .card => |c| if (c.tab < self.tabs.items.len) self.tabs.items[c.tab].pinned else null,
            .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => null,
            .group_header => |h| if (h.tab < self.tabs.items.len) self.tabs.items[h.tab].pinned else null,
        };
        if (row_pinned) |rp| {
            if (prev_pinned) |pp| if (rp != pp) {
                current_group_color = 0;
            };
            prev_pinned = rp;
        }
        // §14 재설계 경계(code-review): **top_level 카드**(그룹 밖 최상위 복귀, depth 0)는 같은 핀 리전 안 앞선 색 그룹의
        // 색을 상속하면 안 된다 — 핀 리전 경계 리셋(위)과 **동형**으로 여기서 current_group_color를 리셋한다(파생 7 subtree-
        // 스캔 경계 처리와 같은 결). 헤더 row는 아래 switch에서 곧 색을 덮으므로 무관하고(마커=leaf-only라 top_level 불가),
        // top카드는 리셋된 무색을 그대로 accent 막대에 쓴다. top_level 0개면 flip이 없어 no-op(byte-identical).
        switch (row) {
            .card => |c| if (c.tab < self.tabs.items.len and self.tabs.items[c.tab].top_level) {
                current_group_color = 0;
            },
            .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
            .group_header => {},
        }
        const orig = switch (row) {
            .card => |c| c.tab,
            .group_header => |h| {
                // 헤더 row는 카드 tint/accent 대상 아님(헤더 밴드의 그룹 색 tint는 lowerSidebar가 밴드 색에 블렌드 —
                // 카드 배경 tint와 같은 경로). 여기선 이후 소속 카드 막대에 실을 그룹 색만 기억하고 넘어간다.
                current_group_color = if (h.tab < self.tabs.items.len) self.tabs.items[h.tab].group_color else 0;
                continue;
            },
            .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => continue, // 목록/system 행은 per-card tint/accent 대상이 아니다.
        };
        // SG8d: 고스트 카드(preview_rows[ghost_lo,hi))는 아래 반투명 밴드+삽입선으로만 표시하고 per-card 배경 tint·
        // 불투명 accent 막대는 생략한다 — 불투명 막대가 "떠 있는" 반투명 고스트를 깨뜨리기 때문. current_group_color
        // 추적은 헤더 branch에서만 갱신되므로 카드 skip이 소속 색 추적을 깨지 않는다.
        const is_ghost = if (self.sidebar_drag_preview) |dp| (i >= dp.ghost_lo and i < dp.ghost_hi) else false;
        if (is_ghost) continue;
        const tab = self.tabs.items[orig]; // 표시 슬롯 i → 원본 탭(검색 필터)
        // 카드 rect = **chrome 밴드와 같은 rect**. 카드 + 그 카드에 딸린 에이전트 목록 행까지 한 덩어리다 —
        // 배경 tint·좌측 accent 막대가 밴드(bandFillSpan)와 같은 범위를 써야 목록 옆에서 막대가 끊기지
        // 않는다(사용자 피드백). 범위·기하를 여기서 다시 누적하지 않고 `cardSpanEnd`+`spanRect`를 부른다 —
        // 예전엔 같은 누적이 chrome·platform 두 벌이라 한쪽 인셋만 바꾸면 막대가 밴드 안쪽에 떠 보였다.
        const card_rect = chrome.components.sidebar.spanRect(rows, i, chrome.components.sidebar.cardSpanEnd(rows, i), self.sidebar_width_px, sidebarMetrics(self));
        // spanRect는 슬롯 상대(헤더 제외)라 헤더 높이를 더해 절대 y로 올린다(헤더 시프트는 platform 단일 책임).
        // 스크롤은 sidebarScrollClipQuad가 빼므로 여기서 더하지 않는다(이중 차감 방지).
        const card_top: f32 = @floatFromInt(card_rect.y + @as(i32, @intCast(self.sidebar_header_height_px)));
        const card_h: f32 = @floatFromInt(card_rect.h);
        // ① 배경 tint — **밴드 없는 idle 슬롯에만** 오버레이 quad. 활성/호버/드롭 슬롯은 lowerSidebar가 밴드 색에
        // tint를 blend하므로 여기서 또 그리면 이중 tint(code-review). 카드 rect(=행)·둥근 모서리를 밴드와 맞춘다.
        // straight-alpha(셰이더 rgb*=a) — premultipliedRgba면 이중 premultiply로 밴드 blend 경로보다 흐려진다.
        const is_hovered = if (self.hovered_slot) |hs| hs == i else false;
        const is_drop = if (drop_slot) |ds| ds == i else false;
        const has_band = orig == self.app_window.active_tab or is_hovered or is_drop;
        if (tab.background_color != 0 and !has_band) {
            if (sidebarScrollClipQuad(self, card_top, card_h)) |sr| {
                const c = packStraightRgbU32(tab.background_color, tab_bg_tint_alpha);
                const r: f32 = if (sr.clipped) 0 else @floatFromInt(card_tk.space.corner_radius_px); // 헤더에 걸려 잘리면 라운드 죽임(밴드와 동일)
                self.gpu_quads.append(self.allocator, .{
                    .x = @floatFromInt(card_rect.x), // chrome 밴드 rect 그대로(x·w) — 좌표 재계산 금지
                    .y = sr.y,
                    .w = @floatFromInt(card_rect.w),
                    .h = sr.h,
                    .corner_radii = .{ r, r, r, r },
                    .border_widths = .{ 0, 0, 0, 0 },
                    .fill_color0 = c,
                    .fill_color1 = c,
                    .border_color = 0,
                    .gradient_kind = 0,
                    .layer = 0,
                }) catch {};
            }
        }
        // ② 좌측 accent 막대(불투명, 직각 strip). 색 층 우선순위: 개별 지정색(tab.accent_color) > 그룹 공통 색
        // (current_group_color, SG5-2 — 소속 카드 공통 막대, 브라우저 탭 그룹식으로 활성·비활성 모두) > 활성만 기본
        // accent(테마-구동) > 없음(비활성 무색 카드는 막대 없음). 개별 accent가 그룹 색보다 위 = 개별 지정이 더 명시적
        // (design 지침). 막대는 카드 좌단(x=0 — 밴드가 행 전체라 행 왼쪽 끝)·카드 높이. solid 직각 quad라 appendSolidQuad 재사용(divider 등과 동일 헬퍼).
        if (bar_w > 0) {
            const word: u32 = if (tab.accent_color != 0)
                packStraightRgbU32(tab.accent_color, 0xFF)
            else if (current_group_color != 0)
                packStraightRgbU32(current_group_color, 0xFF)
            else if (orig == self.app_window.active_tab) default_accent else continue;
            if (sidebarScrollClipQuad(self, card_top, card_h)) |sr| {
                self.appendSolidQuad(@floatFromInt(card_rect.x), sr.y, @floatFromInt(bar_w), sr.h, word, 0);
            }
        }
    };
    // 드래그 고스트 — preview_rows[ghost_lo,hi) 구간에 드롭 피드백을 얹는다. plan에 따라 시각이 갈린다(사용자 확정 정책):
    //  ⑴ **.group_nest(Cmd 중첩)** = 타깃 그룹 하이라이트(부모 그룹 배경 tint로 "여기 안으로") + **들여쓴** 반투명 고스트
    //     밴드(기존 group_depth 반영 — 한 단계 안쪽) + 들여쓴 삽입선. "폴더 안에 넣기"를 시각화.
    //  ⑵ **.group_sibling(Cmd 없음 형제)** = **삽입선만**(중첩 아님 = 단순 위치 지시). 고스트 밴드·하이라이트 없음.
    //  ⑶ **.card / .none** = 기존 SG8d 카드 드래그(반투명 밴드 + 삽입선, 전폭). 카드 경로는 modifier와 무관하게 불변.
    // rowTop은 rows(=preview_rows)와 같은 도메인이라 위치가 정합하고, hit-test·plan은 원본 sidebar_rows(불변)라 무관하다.
    // 고스트 glyph는 buildSidebarTitleDrawList가 muted 색으로 dim해 밴드와 함께 "고스트"로 읽힌다.
    if (self.sidebar_drag_preview) |dp| {
        if (dp.ghost_hi > dp.ghost_lo and dp.ghost_lo < rows.len and slot_h > 0 and self.sidebar_width_px > 0) {
            // 고스트 구간도 카드 rect와 같은 `spanRect`로 잰다(밴드와 한 벌 — 누적을 여기서 다시 굴리지 않는다).
            const ghost_rect = chrome.components.sidebar.spanRect(rows, dp.ghost_lo, dp.ghost_hi, self.sidebar_width_px, sidebarMetrics(self));
            const top_abs: f32 = @floatFromInt(ghost_rect.y + @as(i32, @intCast(self.sidebar_header_height_px)));
            const band_h: u32 = ghost_rect.h;
            const is_nest = dp.plan == .group_nest;
            const is_sibling = dp.plan == .group_sibling;
            // 고스트 depth(첫 고스트 row = 드래그 마커/카드) — nest면 relevel된 새(더 깊은) depth를 든다.
            const ghost_depth: u8 = switch (rows[dp.ghost_lo]) {
                .group_header => |h| h.depth,
                .card => |c| c.depth,
                // 목록 행은 드래그 대상이 아니라 고스트가 될 수 없다 — 방어적으로 최상위 depth를 쓴다.
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => 1,
            };
            // nest 들여쓰기(기존 group_depth 반영) — 헤더 glyph indent (depth-1)*group_indent와 정렬. 형제/카드는 0(전폭).
            const indent_px: f32 = if (is_nest and ghost_depth > 1)
                @floatFromInt(@as(u32, ghost_depth - 1) * @as(u32, card_tk.space.group_indent_px))
            else
                0;
            const w_full: f32 = @as(f32, @floatFromInt(ghost_rect.w)) - indent_px; // 밴드 rect 폭 − nest 들여쓰기
            // ⑴ nest: 타깃 그룹 하이라이트 — 부모 그룹(고스트를 담는 그룹)의 rows [parent_row, ghost_lo)에 은은한 배경 tint로
            //    "이 그룹 안으로 들어간다"를 보인다. parent_row = 고스트 위로 스캔해 depth==ghost_depth-1인 첫 group_header
            //    (= 타깃 그룹 마커). 못 찾으면(방어) 하이라이트 생략. 밴드는 부모 그룹 상단부터 고스트 아래까지 감싼다.
            if (is_nest and ghost_depth > 1) {
                const want: u8 = ghost_depth - 1;
                var pr: usize = dp.ghost_lo; // 못 찾으면 ghost_lo 유지 → 아래 `pr < ghost_lo` 가드로 하이라이트 생략
                var scan: usize = dp.ghost_lo;
                while (scan > 0) {
                    scan -= 1;
                    const hit = switch (rows[scan]) {
                        .group_header => |h| h.depth == want, // 타깃 그룹 마커(depth == ghost_depth-1)
                        .card, .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => false,
                    };
                    if (hit) {
                        pr = scan;
                        break;
                    }
                }
                if (pr < dp.ghost_lo) {
                    // 부모 그룹 상단 ~ 고스트 하단 = rows [pr, ghost_hi) 한 구간 — 같은 spanRect로 잰다.
                    const hl_rect = chrome.components.sidebar.spanRect(rows, pr, dp.ghost_hi, self.sidebar_width_px, sidebarMetrics(self));
                    const parent_top: f32 = @floatFromInt(hl_rect.y + @as(i32, @intCast(self.sidebar_header_height_px)));
                    if (sidebarScrollClipQuad(self, parent_top, @floatFromInt(hl_rect.h))) |sr| {
                        const rr: f32 = if (sr.clipped) 0 else @floatFromInt(card_tk.space.corner_radius_px);
                        const hl_fill = packRgbAlpha(card_tk.palette.get(.accent_bar), 0x22); // 타깃 그룹 accent tint(≈13%)
                        self.gpu_quads.append(self.allocator, .{
                            .x = @floatFromInt(hl_rect.x),
                            .y = sr.y,
                            .w = @floatFromInt(hl_rect.w),
                            .h = sr.h,
                            .corner_radii = .{ rr, rr, rr, rr },
                            .border_widths = .{ 0, 0, 0, 0 },
                            .fill_color0 = hl_fill,
                            .fill_color1 = hl_fill,
                            .border_color = 0,
                            .gradient_kind = 0,
                            .layer = 0,
                        }) catch {};
                    }
                }
            }
            // ⑵ 형제(is_sibling)는 밴드를 생략하고 삽입선만 낸다. nest·card는 반투명 고스트 밴드(nest는 indent_px만큼 들여씀).
            if (!is_sibling) {
                if (sidebarScrollClipQuad(self, top_abs, @floatFromInt(band_h))) |sr| {
                    const rr: f32 = if (sr.clipped) 0 else @floatFromInt(card_tk.space.corner_radius_px);
                    const ghost_fill = packRgbAlpha(self.appearance.theme.sidebar_foreground, 0x30); // ≈19% 반투명
                    self.gpu_quads.append(self.allocator, .{
                        .x = @as(f32, @floatFromInt(ghost_rect.x)) + indent_px,
                        .y = sr.y,
                        .w = w_full,
                        .h = sr.h,
                        .corner_radii = .{ rr, rr, rr, rr },
                        .border_widths = .{ 0, 0, 0, 0 },
                        .fill_color0 = ghost_fill,
                        .fill_color1 = ghost_fill,
                        .border_color = 0,
                        .gradient_kind = 0,
                        .layer = 0,
                    }) catch {};
                }
            }
            // 삽입선(accent 색) — 고스트 상단 경계에 얇은 quad로 "여기에 놓인다"를 또렷이 보인다(divider보다 대비 높은
            // accent로 스크린샷 가독성 확보 — 브라우저/VSCode 드래그 삽입선 관례). 두께 ≥2px. nest는 indent_px만큼 들여씀(형제=전폭).
            const line_thick: f32 = @floatFromInt(@max(@as(u32, 2), card_tk.border.line_thickness_px));
            if (sidebarScrollClipQuad(self, top_abs, line_thick)) |sr| {
                self.appendSolidQuad(@as(f32, @floatFromInt(ghost_rect.x)) + indent_px, sr.y, w_full, sr.h, packOpaqueRgb(card_tk.palette.get(.accent_bar)), 0);
            }
        }
    }
    // 접힘 펼치기 토글(◧) 호버 배경 — 접힘 시 위 헤더-아이콘 호버 경로(sidebar_width_px>0 가드)가 안 타므로 여기서
    // 별도로 그린다. 토글 글리프는 .m이 titlebar_strip 안 세로 중앙 + 1.7×로 그리므로(metalFrame.titlebar_strip_px),
    // quad도 같은 중심에 맞춘다: 가로=셀 중심(col+0.5), 세로=띠 중앙, 폭≈2.6칸. 색·알파·둥글기는 헤더 아이콘 호버와
    // 동일(밝은 fg 반투명 — straight-alpha packRgbAlpha; premultipliedRgba면 셰이더 이중 premultiply로 흐려짐).
    if (self.sidebar_collapsed and self.hovered_collapsed_toggle and self.cell_width_px > 0 and self.cell_height_px > 0 and self.titlebar_strip_px > 0) {
        const cw: f32 = @floatFromInt(self.cell_width_px);
        const ch: f32 = @floatFromInt(self.cell_height_px);
        const strip: f32 = @floatFromInt(self.titlebar_strip_px);
        const w: f32 = cw * 2.6; // 아이콘(~1.7칸) + 좌우 여백 — 헤더 아이콘 호버와 같은 폭
        const h: f32 = ch * 1.7; // 글리프(1.7× 셀)와 같은 높이 — 헤더 아이콘 호버와 동일. cap하면 큰 폰트(1.7ch>strip)서
        const radius: f32 = @min(w, h) * 0.28; // 글리프가 pill 밖으로 삐져나가므로(code-review) 무cap으로 글리프와 정확히 일치
        const hover_fill = packRgbAlpha(self.appearance.theme.sidebar_foreground, 0x40); // ≈25% 밝은 하이라이트
        self.gpu_quads.append(self.allocator, .{
            .x = (@as(f32, @floatFromInt(self.collapsedToggleCol())) + 0.5) * cw - w / 2.0, // 셀 중심 기준 중앙
            .y = (strip - h) / 2.0, // 글리프와 같은 중심(strip/2). 1.7ch>strip이면 y<0(글리프도 띠 밖으로 나가므로 일치) — 렌더러 clip
            .w = w,
            .h = h,
            .corner_radii = .{ radius, radius, radius, radius },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = hover_fill,
            .fill_color1 = hover_fill,
            .border_color = 0,
            .gradient_kind = 0,
            .layer = 0,
        }) catch {};
    }
}

pub fn sidebarScissorPx(
    backing_height_px: u32,
    has_sidebar_content: bool,
    header_height_px: u32,
    scroll_offset_px: u32,
    status_bar_height_px: u32,
) SidebarScissor {
    const none = SidebarScissor{ .top = 0, .bottom = 0 };
    if (!has_sidebar_content or backing_height_px == 0) return none;

    // 구간 값은 뷰포트가 소유하고, 여기서는 "언제 자르나"만 정한다(위아래 이유가 다르다 — SidebarScissor 문서).
    const viewport = sidebarViewportPx(backing_height_px, header_height_px, status_bar_height_px);
    const scroll_clip = scroll_offset_px > 0 and viewport.top < backing_height_px;
    const bottom_clip = status_bar_height_px > 0;
    if (!scroll_clip and !bottom_clip) return none;

    const top: u32 = if (scroll_clip) viewport.top else 0;
    if (viewport.bottom <= top) return none; // 겹친 구간을 내느니 안 자른다(뒤집힌 rect 방지)
    return .{ .top = top, .bottom = viewport.bottom };
}

/// 콘텐츠가 **뷰포트 높이**를 넘는 양. 뷰포트를 직접 받는다 — 예전엔 (backing, header)를 받아 여기서 다시
/// 빼는 바람에 "상태바를 빼야 한다"를 아는 곳이 하나 더 생겼다. 뺄셈은 큰 쪽에서 작은 쪽을 빼므로 u32로 닫힌다.
pub fn sidebarMaxScrollPx(content_height_px: u32, viewport_height_px: u32) u32 {
    if (content_height_px <= viewport_height_px) return 0;
    return content_height_px - viewport_height_px;
}

/// 사이드바 스크롤바를 **공용 paint 경로**로 그린다(SV4a). 발행된 tree를 `ui_paint`가 quad op으로
/// 옮기고 `chrome_draw_lowering`이 GpuQuad로 내린다 — 탐색기·소스 컨트롤과 같은 경로다.
///
/// 옛 코드는 여기서 pill 모양·반지름·색·트랙 산술을 손으로 다시 만들고 layer 3(카드 **위**)에
/// 얹었다. 이제 layer 2로 내려오므로 밴드가 이 자리를 덮지 않도록 `sidebar.view`가 gutter를 자기
/// 폭에서 뗀다(§4) — 그것이 이 슬라이스에서 카드가 좁아지는 이유다.
///
/// **fade alpha만 여기서 얹는다.** 선언에 실으면 매 프레임 tree가 달라져 reconcile을 다시 돈다(§7).
pub fn appendSidebarScrollbar(self: *AppSession) void {
    buildSidebarScrollTree(self);
    const snapshot = sidebarScrollTree(self);
    if (snapshot.entries.len == 0) return;
    // 호버·드래그 중이면 full로 — 커서를 안 바꾸는 대신 이 강조가 "잡을 수 있다"를 알린다(도크와 같은 규율).
    const emphasized = self.sidebar_scrollbar_hovered or (self.scrollbar_drag_target == .sidebar);
    const alpha: u8 = if (emphasized) scrollbar_alpha_full else scroll_ops.scrollbarAlpha(self, self.sidebar_scrollbar_idle_ticks);

    var ops: [sidebar_scroll_max_entries]chrome.draw.Op = undefined;
    const tokens = self.buildChromeTokens();
    const draws = chrome.ui.paint.paint(snapshot, .{}, &tokens, .sidebar, .{ .ops = &ops }) catch return;
    for (ops[0..draws.ops.len]) |*op| switch (op.*) {
        .quad => |*q| q.alpha = alpha,
        else => {},
    };
    // rect는 이미 backing 좌표다(`buildSidebarScrollTree`가 옮겼다) — origin을 다시 더하지 않는다.
    // over(3)를 **발행 시점에** 지정한다(SV6a). 렌더러는 layer 2를 맨 처음 그리고 그 위에 자기가
    // 소유한 사이드바 배경 strip을 덮으므로, 2로 내리면 막대가 발행돼도 화면에서 사라진다(실측).
    // 예전에는 2로 내린 뒤 뒤에서 되돌렸는데, 그 되돌리기가 "같은 역할이 두 층에 흩어진" 증상이었다.
    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, 0, 0, &self.gpu_quads, 3);
}

/// chrome `sidebar.view`가 낸 밴드 fill op을 sidebar 셀(NativeMetalCell)로 lower한다 — fill rect.y / slot_h = 슬롯 행,
/// role(tab_active_bg/tab_hover_bg) → sidebarActiveBg/HoverBg. sidebarBandCell이 폭을 cell로 floor해 한 칸 밴드로.
/// (옛 rebuildSidebar의 밴드 emit을 view 경로로 — 색 해석·NativeMetalCell은 platform 책임, divider lowerDividerRules와 동형.)
/// 슬롯 콘텐츠 GpuQuad(밴드·accent 막대·배경 tint)의 절대 y(슬롯 상대 y + 헤더 시프트는 호출자가 더해 넘김)와
/// 높이에 사이드바 세로 스크롤을 적용하고 헤더 아래로 클립한다. 헤더 quad(검색 underline·아이콘 호버·배지)는 고정이라
/// 이걸 안 거친다. 반환 null = 완전히 헤더 위(스킵). clipped=true면 위쪽이 잘려(상단이 헤더 경계에 abut) 호출자가 둥근
/// 상단 모서리를 죽인다(라운드 quad가 헤더 경계에서 어색하지 않게). 셀(밴드 sentinel·glyph)은 .m이 frame 오프셋으로
/// 따로 스크롤+scissor하므로 이 경로는 GpuQuad 전용이다(둘 다 같은 sidebar_scroll_offset_px를 쓴다 — 단일 출처).
///
/// **하단은 여기서 자르지 않는다.** 뷰포트 아래(상태바 띠)는 렌더러가 `SidebarScissor`로 셀과 quad를 함께
/// 자른다 — 안전망을 호출자마다 반복하지 않기 위해서다. 여기 남은 상단 산술은 "라운드 모서리를 죽인다"는
/// **시각 규칙** 때문이지 안전망이 아니다: scissor는 자를 수 있어도 모서리를 각지게 만들 수는 없다.
pub fn sidebarScrollClipQuad(self: *const AppSession, abs_y: f32, h: f32) ?struct { y: f32, h: f32, clipped: bool } {
    const header: f32 = @floatFromInt(sidebarViewport(self).top);
    const off: f32 = @floatFromInt(self.sidebar_scroll_offset_px);
    var y = abs_y - off;
    var hh = h;
    if (y + hh <= header) return null; // 헤더 위로 완전히 스크롤됨 — 안 그림
    var clipped = false;
    if (y < header) { // 상단 일부가 헤더에 걸침 — 헤더 경계에서 자른다
        hh -= (header - y);
        y = header;
        clipped = true;
    }
    return .{ .y = y, .h = hh, .clipped = clipped };
}

/// 밴드 slot-상대 y(chrome bandFill이 rowTop 누적으로 낸 값 + card_gap inset) → 표시 row 인덱스. 가변 높이
/// (카드=slot_h·헤더=header_row_h)라 고정 y/slot_h 나눗셈 대신 각 row 높이를 누적해 역산한다(bandFill의 역).
/// 콘텐츠 아래(목록 끝 초과)·음수면 null. lowerSidebar의 tint 역매핑·tui 셀 밴드 행 산출의 단일 출처.
pub fn sidebarBandRow(self: *const AppSession, band_y: i32) ?usize {
    if (band_y < 0) return null;
    const metrics = sidebarMetrics(self);
    const y: u32 = @intCast(band_y);
    var acc: u32 = 0;
    // SG8d: 밴드 op은 view(sidebarRenderRows())가 냈으므로 역매핑도 같은 도메인(카드 드래그 중=preview_rows)을 쓴다.
    for (sidebarRenderRows(self), 0..) |row, i| {
        const rh = chrome.components.sidebar.rowHeight(row, metrics);
        if (rh == 0) continue;
        if (y < acc +| rh) return i;
        acc +|= rh;
    }
    return null; // 콘텐츠 아래(목록 끝 행 = 새 워크스페이스 드롭) — tint 없음
}

pub fn sidebarScrollbarMetrics(self: *const AppSession) chrome.ui.scroll_area.ScrollbarMetrics {
    _ = self;
    return .{
        .width_px = sidebar_scrollbar_width_px,
        .inset_x_px = sidebar_scrollbar_inset_px,
        .min_thumb_px = sidebar_scrollbar_min_thumb_px,
    };
}

/// 사이드바 카드 줄의 열 배치. **그리는 자리와 눌리는 자리의 단일 출처**(`chrome.components.sidebar.columns`)에
/// 토큰·gutter 값만 주입한다 — 산술은 chrome이 갖고 platform은 값만 안다. `buildSidebarTitleDrawList`(렌더)와
/// `sidebarCloseButtonAt`(hit-test)이 둘 다 이걸 부르므로 gutter·inset이 바뀌어도 한쪽만 움직일 수 없다.
pub fn sidebarColumns(self: *const AppSession) ?chrome.components.sidebar.Columns {
    const sp = self.buildChromeTokens().space;
    return chrome.components.sidebar.columns(
        self.sidebar_width_px,
        self.cell_width_px,
        sidebarScrollGutterPx(self),
        sp.card_gap_px + sp.accent_bar_width_px, // 좌측 accent 막대 + 카드 패딩
        sp.card_gap_px, // 우측 카드 패딩
    );
}

/// x가 카드 줄의 ✕ 칸 안인가. 배치를 못 내는 폭이면 false(그 폭에서는 ✕를 그리지도 않는다).
pub fn sidebarCloseButtonAt(self: *const AppSession, x_px: f64) bool {
    const cols_layout = sidebarColumns(self) orelse return false;
    return chrome.components.sidebar.closeButton(x_px, cols_layout, self.cell_width_px);
}

/// 밴드·카드 텍스트가 스크롤바에 내주는 폭. **스크롤 여부와 무관하게 상시**다 — 넘칠 때만 떼면
/// 목록이 마지막 카드 하나에 reflow한다(docs/scroll-area.md §4).
pub fn sidebarScrollGutterPx(self: *const AppSession) u32 {
    if (self.sidebar_width_px == 0) return 0;
    const m = sidebarScrollbarMetrics(self);
    return m.width_px + m.inset_x_px;
}

pub fn sidebarScrollExtent(self: *const AppSession) ?SidebarScrollExtent {
    if (self.sidebar_width_px == 0) return null;
    const viewport = sidebarViewport(self); // 트랙 = 뷰포트. thumb이 끝에 닿는 순간 스크롤도 끝나야 하므로 같은 구간이다.
    if (viewport.isEmpty()) return null;
    const max_offset = sidebarMaxScroll(self);
    if (max_offset == 0) return null; // 안 넘침 — 스크롤바 없음
    return .{
        .rect = .{ .x = 0, .y = viewport.top, .w = self.sidebar_width_px, .h = viewport.height() },
        .content_h_px = chrome.components.sidebar.contentHeight(sidebarRenderRows(self), sidebarMetrics(self)),
        .max_offset_px = max_offset,
    };
}

/// 사이드바 스크롤바를 **선언**한다(SV4a). 도크·탐색기·소스 컨트롤과 같은 `scrollArea` 노드이며,
/// 모양·최소 thumb·트랙 배치를 host가 손으로 다시 만들지 않는다.
pub fn buildSidebarScrollTree(self: *AppSession) void {
    self.sidebar_scroll_entry_count = 0;
    self.sidebar_scroll_max_offset_px = 0;
    const extent = sidebarScrollExtent(self) orelse return;

    var entries: [sidebar_scroll_max_entries]chrome.ui.tree.RectEntry = undefined;
    var items: [sidebar_scroll_max_entries]chrome.ui.layout.Item = undefined;
    var flex: [sidebar_scroll_max_entries]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [sidebar_scroll_max_entries]chrome.ui.layout.UiRect = undefined;

    const node = chrome.ui.tree.scrollArea(.{
        .id = sidebar_scroll_ids.area,
        .scroll = .{
            .offset_px = self.sidebar_scroll_offset_px,
            .content_h_px = extent.content_h_px,
            .gutter_px = @floatFromInt(sidebarScrollGutterPx(self)),
            .metrics = sidebarScrollbarMetrics(self),
            // fade alpha는 선언에 싣지 않는다 — 매 프레임 달라져 reconcile을 다시 돌게 한다(§7).
            // thumb을 누른 것 자체가 스크롤 의사라 threshold는 0이다. track도 같은 payload를 선언해
            // 눌러 점프한 뒤 손을 떼지 않고 이어 끌 수 있다(도크·탐색기와 같은 규율).
            .drag = .{ .payload = dock_list_scroll_drag_payload, .axis = .vertical, .threshold_px = 0 },
            .track = .{ .id = sidebar_scroll_ids.track, .action = .{ .id = sidebar_scroll_ids.track }, .paint = .{ .background = .surface_bg } },
            .thumb = .{ .id = sidebar_scroll_ids.thumb, .action = .{ .id = sidebar_scroll_ids.thumb }, .paint = .{ .background = .muted_fg, .corner_radii_px = .{ sidebar_scrollbar_width_px / 2, sidebar_scrollbar_width_px / 2, sidebar_scrollbar_width_px / 2, sidebar_scrollbar_width_px / 2 } } },
        },
    }, &.{});

    const built = chrome.ui.tree.build(node, .{
        .root_size = .{ .width = @floatFromInt(extent.rect.w), .height = @floatFromInt(extent.rect.h) },
        .max_entries = sidebar_scroll_max_entries,
        .max_depth = 2,
    }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex,
        .child_rects = &child_rects,
    }) catch return;

    self.sidebar_scroll_generation +|= 1;
    for (built.entries, 0..) |entry, i| {
        var moved = entry;
        moved.rect.x += @floatFromInt(extent.rect.x);
        moved.rect.y += @floatFromInt(extent.rect.y);
        if (moved.effective_clip) |*clip| {
            clip.x += @floatFromInt(extent.rect.x);
            clip.y += @floatFromInt(extent.rect.y);
        }
        self.sidebar_scroll_entries[i] = moved;
    }
    self.sidebar_scroll_entry_count = built.entries.len;
    self.sidebar_scroll_max_offset_px = extent.max_offset_px;
}

/// 이 지점이 사이드바 스크롤바 트랙 위인가. hover·hit-test가 슬롯 대신 막대를 보게 하는 게이트다.
/// **발행된 tree를 읽기만 한다** — 여기서 다시 발행하면 hover가 매 프레임 세대를 올려 드래그 carry를
/// 흔든다.
pub fn pointOnSidebarScrollbar(self: *const AppSession, x_px: f64, y_px: f64) bool {
    const geometry = sidebarScrollbarGeometry(self) orelse return false;
    return geometry.trackContains(x_px, y_px);
}

pub fn sidebarScrollbarGeometry(self: *const AppSession) ?chrome.ui.scroll_area.ScrollbarGeometry {
    var track: ?chrome.ui.layout.UiRect = null;
    var thumb: ?chrome.ui.layout.UiRect = null;
    for (self.sidebar_scroll_entries[0..self.sidebar_scroll_entry_count]) |entry| {
        if (entry.id == sidebar_scroll_ids.track) track = entry.rect;
        if (entry.id == sidebar_scroll_ids.thumb) thumb = entry.rect;
    }
    const t = track orelse return null;
    const h = thumb orelse return null;
    // 잡는 자리(hit)는 tree에 안 실린다 — entry에는 그린 rect만 담긴다. 거터 폭으로 역산해 채운다.
    const bar: chrome.ui.scroll_area.ScrollbarGeometry = .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .hit_x = t.x,
        .hit_w = t.width,
        .thumb_y = h.y,
        .thumb_h = h.height,
        .max_offset_px = self.sidebar_scroll_max_offset_px,
    };
    return bar.withHitSpan(@floatFromInt(sidebar_scrollbar_width_px + sidebar_scrollbar_inset_px));
}

pub fn sidebarScrollTree(self: *const AppSession) chrome.ui.tree.UiRectTree {
    return .{
        .entries = self.sidebar_scroll_entries[0..self.sidebar_scroll_entry_count],
        .generation = self.sidebar_scroll_generation,
    };
}

pub fn lowerSidebar(self: *AppSession, ops: []const chrome.draw.Op) void {
    const slot_h = sidebarMetrics(self).line_h; // 렌더 전 degenerate 판정(카드 높이는 줄 기하에서 나온다)
    if (slot_h == 0) return;
    // SG8d: tint 소스 역매핑도 렌더 도메인(카드 드래그 중=preview_rows) — 밴드 op을 낸 view와 같은 rows를 본다.
    const rrows = sidebarRenderRows(self);
    // gpu_quad(밴드)는 슬롯 상대 y를 절대 좌표로 박으므로 상단 헤더만큼 내려야 한다 — .m이 header_h 시프트하는
    // 건 사이드바 셀(= 제목 glyph)뿐이라 gpu_quad는 여기서 header_h를 더한다(위치 정합). 좌측 accent 막대는
    // chrome op이 아니라 카드별 색으로 rebuildSidebar의 per-tab accent 루프가 직접 그린다(배경 tint와 같은 경로).
    const header_f: f32 = @floatFromInt(self.sidebar_header_height_px);
    for (ops) |op| switch (op) {
        .quad => |q| {
            var color = switch (q.fill_role) {
                .tab_active_bg => sidebarActiveBg(self),
                .drop_zone => packOpaqueRgb(self.buildChromeTokens().palette.get(.drop_zone)), // pane 드롭 타겟(rich=밝게)
                .row_hover_bg => sidebarRowHoverBg(self), // 활성 밴드 위에서도 보이도록 활성보다 한 단계 밝게
                else => sidebarHoverBg(self),
            };
            // 이 슬롯 탭에 배경 tint가 있으면 밴드 색에 섞는다 — tui 활성/호버 슬롯은 불투명 밴드(셀)가 tint quad를
            // 덮으므로, 밴드 색 자체를 tint로 당겨 활성/호버 슬롯에서도 색이 보이게 한다(idle 슬롯은 밴드가 없어 quad가 그대로).
            // 가변 높이(SG3c): 밴드 y는 rowTop 누적이라 고정 y/slot_h로 row를 못 역산한다 — sidebarBandRow가 누적으로 역산한다.
            if (sidebarBandRow(self, q.rect.y)) |ri| switch (rrows[ri]) { // 표시 슬롯 ri — 밴드가 카드/헤더냐로 tint 소스가 갈린다
                .card => |c| {
                    if (self.tabs.items[c.tab].background_color != 0) // 카드 배경 tint(개별 background_color)
                        color = blendRgb(color, self.tabs.items[c.tab].background_color & 0x00FF_FFFF, tab_bg_tint_alpha);
                },
                // 목록 행은 **배경 tint 소스가 없을 뿐** 밴드 자체는 그려야 한다. 예전 `continue`는 Zig에서 바깥
                // for를 탈출해 밴드 op을 통째로 버렸고, 그 결과 에이전트 행 호버 하이라이트가 100% 사라졌다
                // (code-review max — view()가 일부러 내는 밴드를 platform이 삼킨 것).
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                .group_header => |h| {
                    // SG5-2: 그룹 헤더 밴드에 그룹 공통 색을 블렌드(카드 배경 tint와 **같은** blend 경로·같은 알파). 층
                    // 분리 — 그룹 색은 헤더 밴드·소속 카드 막대에만 실리고 개별 카드 background_color와 안 겹친다(서로 다른 row).
                    if (h.tab < self.tabs.items.len and self.tabs.items[h.tab].group_color != 0)
                        color = blendRgb(color, self.tabs.items[h.tab].group_color & 0x00FF_FFFF, tab_bg_tint_alpha);
                },
            };
            {
                // 밴드는 **GPU quad 프리미티브**다 — 셀 그리드와 별개 파이프라인으로 렌더된다.
                //
                // 옛 tui 룩에서는 여기 갈래가 하나 더 있었다: quad radius가 0이면 셀 밴드(`sidebar_cells`)로
                // 낮췄다. tui 제거로 `Tokens.rich`가 유일 토큰셋이 되어 `shape.corner_radius_px`가 항상 8이고
                // (`chrome/components/sidebar.zig`의 `bandFill`이 그 값을 그대로 radii에 싣는다), 그 갈래는
                // 도달할 수 없게 됐다 — 테스트 전 범위·실앱 기본·실앱 그룹 헤더 강제에서 모두 도달 0회로 실측했다.
                const sr = sidebarScrollClipQuad(self, @as(f32, @floatFromInt(q.rect.y)) + header_f, @floatFromInt(q.rect.h)) orelse continue;
                // 상단이 헤더에 걸려 잘리면 둥근 모서리를 죽인다(헤더 경계에 abut한 라운드 상단이 어색하지 않게).
                const radii: [4]f32 = if (sr.clipped) .{ 0, 0, 0, 0 } else .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) };
                // 드롭 타겟은 불투명 유지(tui 분기와 동일 이유), 나머지 밴드만 window.opacity(quad straight-alpha). 한 번만 계산해 두 fill에 공유.
                const band_bg = if (q.fill_role == .drop_zone) color else self.chromeQuadBg(color);
                self.gpu_quads.append(self.allocator, .{
                    .x = @floatFromInt(q.rect.x),
                    .y = sr.y,
                    .w = @floatFromInt(q.rect.w),
                    .h = sr.h,
                    .corner_radii = radii,
                    .border_widths = .{ 0, 0, 0, 0 },
                    .fill_color0 = band_bg,
                    .fill_color1 = band_bg,
                    .border_color = 0,
                    .gradient_kind = 0,
                    .layer = 0, // under — 사이드바 밴드(셀 위·제목 아래)
                }) catch {};
            }
        },
        else => {},
    };
}

/// 현재 프레임의 codex식 4칸 이퀄라이저 바를 UTF-8로 만든다(owned). 각 바 = 현재 프레임 높이의 블록 글리프(최대 3바이트).
/// 사이드바 상태줄("{bars} 진행중")과 탭바 라벨 prefix("{bars} {이름}")가 공유한다 — 색칠은 각 표시 경로가 브랜드색으로.
pub fn spinnerBarsUtf8(self: *const AppSession, allocator: std.mem.Allocator) ![]u8 {
    var bars: [spinner_bar_count * 3]u8 = undefined;
    var used: usize = 0;
    for (0..spinner_bar_count) |bar| {
        used += std.unicode.utf8Encode(spinnerBarCp(self.agent_spin_frame, bar), bars[used..]) catch 0;
    }
    return allocator.dupe(u8, bars[0..used]);
}

/// running 상태의 **문구**만. 파형과 따로 두는 이유는 소비처가 둘로 갈리기 때문이다 — 카드·목록 행의 상태줄은
/// 파형 + 문구를 함께 쓰지만(`runningStatusLine`), 토글 행의 접힘 요약은 **문구만** 쓴다(`agentSummaryLine`).
/// 문자열을 두 곳에 따로 적으면 문구를 바꿀 때 한쪽만 바뀐다.
pub fn runningLabel() []const u8 {
    return maru.i18n.t(.sb_in_progress);
}

/// running 상태줄/라벨 파형 문자열 "▁▅▇▃ 진행중"(owned). 사이드바 카드(workspaceStatusLine)와 단일 Term
/// 폴백(agentStatusLine)이 **같은 문자열**을 쓰도록 단일화(code-review max — 옛 두 곳 중복 방지).
pub fn runningStatusLine(self: *AppSession, detail: []const u8) ![]const u8 {
    const bars = try spinnerBarsUtf8(self, self.allocator);
    defer self.allocator.free(bars);
    // 문구가 런타임 값이 되어 `++`(comptime 결합)를 쓸 수 없다 — 파형과 문구를 인자로 넘긴다.
    //
    // `detail` 은 훅 모드의 **진행 중 세부**(계약 §2)다. 비어 있으면 — 관측 모드거나 아직 도구를 안 부른
    // 구간 — 예전과 **바이트가 같은** 문자열이 나온다. 세부를 «없으면 빈 칸» 으로 채우지 않는 이유는
    // 그것이 곧 줄 끝의 떠 있는 구분자가 되기 때문이다.
    if (detail.len == 0) return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ bars, runningLabel() });
    return std.fmt.allocPrint(self.allocator, "{s} {s} \u{00b7} {s}", .{ bars, runningLabel(), detail });
}

/// 배지의 **색 구간** — 어느 열 범위가 어느 종류인지. 색칠 루프가 셀만 보고는 알 수 없기 때문에 있다:
/// 두 종류의 배지는 **같은 블록 문자**를 쓰고 종류를 색으로만 가르므로(사용자 결정), 문자로는 구분이 안 된다.
/// 조립 루프가 문자열을 만들면서 같은 좌표계로 기록하고 색칠 루프가 그대로 읽는다 — 두 곳이 폭 계산을
/// 각자 하면 색이 한 칸씩 밀린다.
///
/// 그래서 색칠 루프는 이 구간을 스피너 판정보다 **먼저** 본다. 스피너 경로는 그 행의 **대표 kind 한 색**만 칠하므로,
/// claude·codex가 함께 도는 줄에서 배지 둘이 모두 대표색을 받아 종류 구분(배지의 존재 이유)이 사라진다.
///
/// 접힘 요약은 이제 파형을 싣지 않지만(`agentSummaryLine`) 그 순서는 그대로 필요하다 — 위 이유는 배지 **둘 사이**의
/// 문제라 요약과 무관하다. 요약이 파형을 다시 갖게 되면 그때는 "한 줄에 두 색 체계"까지 이 구간이 떠받친다.
pub const BadgeSpan = struct {
    slot: usize,
    start_col: u16, // 포함
    end_col: u16, // 제외
    kind: AgentKind,
};

/// running 집계 배지 문자열(owned) + 색 구간. running이 없으면 빈 문자열이고 구간도 비어 있다.
///
/// 형태는 종류마다 `▁▅▇▃`(현재 프레임) + 공백 + 개수다. **개수가 1이면 숫자를 붙이지 않는다** — "하나 돌고 있다"는
/// 파형만으로 이미 말하고, `1`은 잡음이다. 종류가 둘이면 공백 둘로 나란히 둔다(`▁▅▇▃ 2  ▁▅▇▃`).
/// 종류 아이콘을 붙이지 않는 이유: 색이 그 일을 한다(사용자 결정 2026-08-12).
///
/// **본문만 만들고 앞뒤는 호출자가 붙인다.** 이 배지는 `sessions` 토글 행의 라벨·요약과 한 줄을 나눠 쓰므로
/// (`▸ 1  ▁▅▇▃ 2 · 진행중`), 들여쓰기를 함수가 소유하면 앞에 붙는 개수 라벨만큼 span이 어긋난다. 그래서 시작 열을
/// **인자로 받는다** — 호출자가 이미 만든 prefix의 표시 폭을 그대로 넘기면 색이 밀리지 않는다.
///
/// 집계도 **인자로 받는다**(tab이 아니라 `RunningCounts`). 호출자는 배지 앞 간격을 붙일지 정하려고 같은 집계를
/// 이미 봐야 하는데, 함수가 tab에서 다시 세면 «running > 0» 조건이 두 곳에 따로 적힌다 — 한쪽만 바뀌면
/// "간격은 있는데 배지가 없는" 줄이 나온다. 한 번 센 값을 나눠 쓰면 그 어긋남이 구조적으로 불가능하다.
pub fn runningBadgeText(self: *AppSession, counts: tab_ops.RunningCounts, start_col: u16, spans: *std.ArrayList(BadgeSpan), slot: usize) ![]const u8 {
    if (counts.total() == 0) return self.allocator.dupe(u8, ""); // running 0 — 배지 없음(호출자가 prefix만 쓴다)
    const bars = try spinnerBarsUtf8(self, self.allocator);
    defer self.allocator.free(bars);
    // 폭은 **표시 칸**으로 센다. 블록 문자는 1칸이라 bar 개수와 같다.
    var col: u16 = start_col;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(self.allocator);
    const order = [_]struct { kind: AgentKind, count: u16 }{
        .{ .kind = .claude, .count = counts.claude },
        .{ .kind = .codex, .count = counts.codex },
    };
    var first = true;
    for (order) |entry| {
        if (entry.count == 0) continue;
        if (!first) {
            // 종류 사이는 **두 칸**이다. 파형과 개수 사이가 한 칸이므로(아래), 종류 간격도 한 칸이면 어디까지가
            // 한 배지인지 흐려진다 — 색이 다르더라도 폭이 같으면 눈이 그룹을 못 가른다.
            try text.appendSlice(self.allocator, "  ");
            col += 2;
        }
        first = false;
        const start = col;
        try text.appendSlice(self.allocator, bars);
        col += @intCast(spinner_bar_count);
        if (entry.count > 1) {
            // 파형과 개수 사이 한 칸 — 붙여 쓰면 숫자가 마지막 바에 달라붙어 읽기 어렵다(사용자 피드백 2026-08-12).
            try text.append(self.allocator, ' ');
            col += 1;
            var num_buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{entry.count}) catch "";
            try text.appendSlice(self.allocator, num);
            col += @intCast(num.len);
        }
        try spans.append(self.allocator, .{ .slot = slot, .start_col = start, .end_col = col, .kind = entry.kind });
    }
    return text.toOwnedSlice(self.allocator);
}

/// 사이드바 상태줄은 워크스페이스 대표 상태(blocked > running > idle > unknown)를 표시한다.
pub fn workspaceStatusLine(self: *AppSession, tab: *Tab) ![]const u8 {
    const representative = tab_ops.tabAgentRepresentative(tab) orelse return self.allocator.dupe(u8, "");
    return agentStatusLine(self, representative.term);
}

/// 한 Term의 상태줄 텍스트(owned). 에이전트 아니면(none) "" — 그 줄은 생략된다. running이면 "▁▅▇▃ 진행중"(파형),
/// blocked/idle/unknown도 오해 없는 짧은 상태 문구로 표시한다.
/// 사이드바는 workspaceStatusLine이 고른 대표 Term을 이 함수로 넘긴다.
/// 세션 목록 행의 **gutter 아이콘** codepoint(0 = 아이콘 없음). 에이전트는 kind 아이콘(✶/◆)을 그대로 쓰고,
/// 비-에이전트 Term은 종류로 가른다 — 목록이 터미널·브라우저·파일을 함께 담게 되면서(2026-08-11) 아이콘이
/// 없으면 행이 전부 라벨 한 줄로만 구분돼 종류를 눈으로 못 가른다.
///
/// 파일 Term은 **탐색기 트리와 같은 분류기**(`chrome.file_tree_icon.classify`)를 태운다. 같은 파일이 트리와
/// 사이드바에서 다른 아이콘으로 보이면 같은 것으로 안 읽힌다. 일반 터미널만 0(아이콘 없음)이다 — 등록된
/// 터미널 아이콘 자산이 없고, 임의 유니코드 글리프는 아이콘 폰트 fit 규약(`icons.hasFit`) 밖이라 크기가 튄다.
pub fn sessionRowIconCodepoint(term: *Term) u21 {
    if (term.agent_kind != .none) return agentIconCodepoint(term.agent_kind);
    if (term.file_entry) |entry| {
        const kind = chrome.file_tree_icon.classify(.file, std.fs.path.basename(entry.path), false);
        return chrome.file_tree_icon.codepoint(kind) orelse icons.codepoint(.document);
    }
    if (term.kind == .web) return icons.codepoint(.web);
    // N1 편집기 Term도 파일을 여는 것이므로 확장자 아이콘을 쓴다 — 위 파일 패널 분기와 같은
    // 규칙이다(폴백은 `.document`). 이 가드가 없으면 `0`으로 떨어져 **아이콘만 빠진 행**이 된다.
    if (term.kind == .editor) {
        if (term.rt.editor_path) |p| {
            const kind = chrome.file_tree_icon.classify(.file, std.fs.path.basename(p), false);
            return chrome.file_tree_icon.codepoint(kind) orelse icons.codepoint(.document);
        }
        return icons.codepoint(.document);
    }
    return 0;
}

/// 상태줄(`agentStatusLine`)을 **마커**와 **문구**로 가른 것. 상태줄은 `"<마커> <문구>"` 꼴 하나뿐이라 첫 공백이
/// 경계다. 마커를 따로 만들지 않고 잘라 쓰는 이유는 상태 문구가 바뀔 때 둘이 어긋나지 않게 하려는 것이고,
/// 자르는 코드를 여기 한 곳에 두는 이유는 소비처가 둘(프롬프트 있는 행·없는 행)이기 때문이다 — 각자 자르면
/// 한쪽만 옛 규칙에 남는다(그 어긋남이 바로 이 구조를 만든 결함이다: 아래 `agentRowLabelOwned` 주석).
const StatusParts = struct { marker: []const u8, text: []const u8 };

fn splitStatusLine(status: []const u8) StatusParts {
    const sep = std.mem.indexOfScalar(u8, status, ' ') orelse return .{ .marker = status, .text = "" };
    return .{ .marker = status[0..sep], .text = status[sep + 1 ..] };
}

/// 에이전트 행 **1행 텍스트**(owned) — `<상태 마커> <본문>`. 본문은 마지막 사용자 프롬프트이고, 그것을 아직
/// 모르면 `<종류 이름> <상태 문구>`로 폴백한다(§2 표). 상태 마커·문구의 단일 출처는 `agentStatusLine`이다.
///
/// **마커는 두 형태 모두 맨 앞이다**(사용자 결정 2026-08-13). 예전 폴백은 상태줄을 통째로 뒤에 붙여
/// `◆ Codex · ▁▅▇▃ 진행중`이었고, 프롬프트가 있는 행은 `◆ ▁▅▇▃ 지금 용량 …`이라 **같은 목록에서 파형이 서로
/// 다른 열에 섰다**(사용자 보고 — "코덱스 스피너 도는 위치가 다르다"). 두 파형은 같은 `agent_spin_frame`을 쓰므로
/// 어긋난 것은 애니메이션이 아니라 **자리**다. 원인은 폴백만 마커를 본문 뒤에 두는 것이었으므로, 폴백도 마커를
/// 앞으로 빼 "아이콘 다음이 상태 마커"라는 읽기 규칙을 목록 전체에서 하나로 만든다(비-에이전트 행의 dirty `*`가
/// 이미 그 자리를 쓴다).
///
/// 종류와 문구를 가르던 `·`는 함께 걷는다 — 마커가 앞으로 오면 `▁▅▇▃ Codex 진행중`처럼 종류와 문구가 한 구절로
/// 읽혀 구분자가 할 일이 없고, 좁은 사이드바에서 두 칸은 그대로 프롬프트·문구의 말줄임이 된다.
/// 덤으로 unknown의 `Codex · · 상태 확인 중`(마커 `·`와 구분자 `·`가 겹쳐 점이 둘)도 사라진다.
pub fn agentRowLabelOwned(self: *AppSession, term: *Term) ![]const u8 {
    // **비-에이전트 행**(터미널·브라우저·파일, 2026-08-11)은 상태 문구도 프롬프트도 없다 — 아래 경로를 그대로
    // 태우면 kind_name·status가 모두 빈 문자열이라 라벨 없는 행이 나온다. 탭 바·창 제목과 **같은** `termLabel`
    // (custom_name > OSC 제목/패널 라벨 > 파일 basename)을 써서 같은 Term이 어디서 보이든 같은 이름으로 읽히게 한다.
    if (term.agent_kind == .none) {
        const label = app_session_mod.termLabel(term);
        // 저장 안 된 편집이 있는 파일 Term은 라벨 앞에 `*`를 붙인다(사용자 요청 2026-08-11). 앞에 두는 이유는
        // 에이전트 행이 상태 마커를 같은 자리(라벨 선두)에 두기 때문이다 — 한 목록에서 "행 앞이 상태"라는
        // 읽기 규칙이 하나로 유지된다. 뒤에 붙이면 우측 정렬된 시각과 자리를 다툰다.
        // NOTE: 파일 패널 **헤더**는 같은 dirty를 `●`(U+25CF)로 그린다(`dock_layout.dirty_col`). 한 상태에 마커가
        // 둘이라 정합이 필요하면 그쪽과 맞춘다 — 사용자가 `*`를 지정했으므로 여기서는 그대로 둔다.
        const dirty = if (term.file_entry) |e| e.dirty else false;
        if (!dirty) return self.allocator.dupe(u8, label);
        return std.fmt.allocPrint(self.allocator, "* {s}", .{label});
    }
    const status = try agentStatusLine(self, term);
    defer self.allocator.free(status);
    const parts = splitStatusLine(status);
    // **본문은 상태가 정한다**(사용자 결정 2026-08-22). 예전에는 프롬프트가 있으면 언제나 그것을 실었는데,
    // 훅 모드가 실제로 돌기 시작하니 프롬프트가 **항상** 있어 상태 문구가 영영 가려졌다:
    //
    // - `running` — «무엇을 하는 중인가»(§2 진행 중 세부). 그 세부는 이 행 말고 보일 자리가 없다.
    //   프롬프트로 덮으면 훅 모드에서만 얻는 정보를 훅 모드에서 못 보게 된다.
    // - `blocked` — «입력 대기». **사용자의 행동을 요구하는 유일한 상태**라 기호 하나(`?`)로 두지 않는다.
    //   나머지 둘은 마커만으로도 읽힌다(파형은 움직이고 `✓`는 끝을 뜻한다) — 이것만 말이 필요하다.
    // - `idle` — 마지막 프롬프트(«무엇을 시켰나»). 턴이 끝난 뒤 그 행에 남을 값은 그것이다.
    //
    // 종류 이름은 프롬프트를 아는 동안 싣지 않는다 — gutter 아이콘이 이미 말한다(아래 폴백은 그것도 모를 때다).
    const prompt = term.agent_transcript.prompt();
    if (prompt.len > 0) {
        const body = if (term.agent_state == .idle) prompt else parts.text;
        if (parts.marker.len == 0) return self.allocator.dupe(u8, body);
        if (body.len == 0) return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ parts.marker, prompt });
        return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ parts.marker, body });
    }
    const kind_name: []const u8 = switch (term.agent_kind) {
        .claude => "Claude Code",
        .codex => "Codex",
        .none => "",
    };
    // 폴백도 **마커가 먼저**다(위 주석). 마커만 있고 문구가 없는 상태 문자열이 생겨도 종류 이름은 남긴다 —
    // 라벨이 마커 하나로 쪼그라들면 그 행이 무엇인지 gutter 아이콘 말고는 답할 것이 없다.
    if (parts.marker.len == 0) return self.allocator.dupe(u8, kind_name);
    if (parts.text.len == 0) return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ parts.marker, kind_name });
    return std.fmt.allocPrint(self.allocator, "{s} {s} {s}", .{ parts.marker, kind_name, parts.text });
}

/// 에이전트 행 **마지막 활동 시각**(owned, `"5m"`·`"now"`·빈 문자열).
///
/// 기준은 그 Term이 마지막으로 출력한 **wall clock** 시각이다. transcript 파일 mtime을 쓰지 않는
/// 이유는 그것이 **대화** 기록의 시각이라 도구 실행처럼 대화 없이 오래 도는 구간을 "멈춘 것"으로 보이게 하기
/// 때문이다. 행이 답해야 하는 건 "이 에이전트가 살아 움직이는가"다.
///
/// 앱을 새로 켜면 출력 스탬프가 없어(0) 아래 mtime 폴백으로 넘어간다. 둘 다 없으면 빈 문자열이다.
pub fn agentAgeOwned(self: *AppSession, term: ?*Term) ![]const u8 {
    const t = term orelse return self.allocator.dupe(u8, "");
    var buf: [8]u8 = undefined;
    const now_wall: i96 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
    if (t.agent_last_output_wall_ns != 0) {
        // **wall clock으로 잰다.** awake clock은 시스템이 잠든 동안 멈춰, 밤새 재운 뒤에도 "3m"으로 보인다
        // (code-review max). 시계 되감김은 `now`로 방어한다.
        if (now_wall <= t.agent_last_output_wall_ns) return self.allocator.dupe(u8, "now");
        const age_ms: u64 = @intCast(@divTrunc(now_wall - t.agent_last_output_wall_ns, std.time.ns_per_ms));
        return self.allocator.dupe(u8, chrome.components.sidebar.formatRelativeAge(age_ms, &buf));
    }
    // **폴백**: 앱을 새로 켠 직후에는 `agent_last_output_ms`(awake clock)가 0이라 아무 값도 못 낸다. 그런데
    // 사이드바를 보는 이유가 바로 "언제 마지막으로 움직였나"인 순간이 그때다. 그래서 세션 기록 파일의 mtime을
    // 쓴다 — wall clock이라 앱 생애와 무관하고, 그 Term에 이미 매핑된 파일이라 추가 IO가 없다.
    //
    // mtime은 **대화만이 아니라 도구 실행도** 따라간다(실측: 도구만 연달아 도는 세션의 mtime이 25초 전 —
    // tool_use/tool_result가 그때그때 기록된다). 그래서 "대화가 없으면 멈춘 것처럼 보인다"는 걱정은 근거가
    // 없다. 그럼에도 출력을 **우선**하는 이유는 두 가지다: PTY 출력은 파일 쓰기보다 촘촘하고 즉각적이며,
    // 이 캐시의 mtime은 우리가 마지막으로 폴링해 **읽은** 시점 기준이라 최대 폴링 주기만큼 뒤처진다.
    const mtime_ns = t.agent_transcript.read_mtime_ns;
    if (mtime_ns == 0) return self.allocator.dupe(u8, "");
    if (now_wall <= mtime_ns) return self.allocator.dupe(u8, "now"); // 시계 되감김·미래 mtime 방어
    const age_ms: u64 = @intCast(@divTrunc(now_wall - mtime_ns, std.time.ns_per_ms));
    return self.allocator.dupe(u8, chrome.components.sidebar.formatRelativeAge(age_ms, &buf));
}

/// 에이전트 행 **응답 줄**(owned) — 마지막 에이전트 응답(§7). 없으면 빈 문자열이라 렌더가 그 줄을 건너뛴다.
pub fn agentRowReplyOwned(self: *AppSession, term: *Term, indent: []const u8) ![]const u8 {
    const reply = term.agent_transcript.reply();
    if (reply.len == 0) return self.allocator.dupe(u8, "");
    return std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ indent, reply });
}

/// 에이전트 행 **폴더 줄**(owned) — 그 Term이 도는 디렉터리(§2.1). 카드 헤더가 활성 Term 기준이라 다른 Pane에서
/// 도는 에이전트의 자리는 여기서만 드러난다. 폭이 좁으므로 경로 전체가 아니라 **마지막 세그먼트**만 쓴다.
pub fn agentRowFolderOwned(self: *AppSession, term: *Term, indent: []const u8) ![]const u8 {
    const path = try sidebarCwdPath(self, term);
    defer self.allocator.free(path);
    if (path.len == 0) return self.allocator.dupe(u8, "");
    const leaf = std.fs.path.basename(path);
    const folder: []const u8 = if (leaf.len > 0) leaf else path;
    return std.fmt.allocPrint(self.allocator, "{s}  " ++ icons.utf8(.folder) ++ " {s}", .{ indent, folder });
}

/// 에이전트 행 **브랜치 줄**(owned) — git repo 안일 때만(카드 보조줄과 같은 규칙). **폴더와 같은 줄에 합치지
/// 않는다**: 사이드바 폭에서 둘을 한 줄에 넣으면 브랜치가 잘린다(사용자 실측 피드백 — 설계의 "이어 붙인다"를 정정).
pub fn agentRowBranchOwned(self: *AppSession, term: *Term, indent: []const u8) ![]const u8 {
    const branch = git_ops.termGitBranch(self, term) orelse return self.allocator.dupe(u8, "");
    return std.fmt.allocPrint(self.allocator, "{s}  " ++ icons.utf8(.mark_github) ++ " {s}", .{ indent, branch });
}

pub fn agentStatusLine(self: *AppSession, term: *Term) ![]const u8 {
    if (term.agent_kind == .none) return self.allocator.dupe(u8, "");
    return switch (term.agent_state) {
        // codex식 4칸 파형 "▁▅▇▃ 진행중"(단일 출처). 훅 모드면 **무엇을 하는 중인지**까지 붙는다.
        .running => runningStatusLine(self, term.agent_hook_tool.text()),
        // 마커(`?`·`✓`·`·`)는 **번역 대상이 아니다** — 기호이지 문장이 아니다. 문구만 키를 거친다.
        .blocked => std.fmt.allocPrint(self.allocator, "? {s}", .{maru.i18n.t(.sb_awaiting_input)}),
        .idle => std.fmt.allocPrint(self.allocator, "\u{2713} {s}", .{maru.i18n.t(.sb_agent_idle)}),
        .unknown => std.fmt.allocPrint(self.allocator, "\u{00b7} {s}", .{maru.i18n.t(.sb_agent_unknown)}),
    };
}

/// 토글 행 **접힘 요약**의 상태 텍스트(owned). 상태 문구는 `agentStatusLine`을 단일 출처로 그대로 쓰되,
/// running만 파형을 뺀 문구(`runningLabel()`)로 바꾼다.
///
/// 요약이 상태줄과 갈리는 이유는 **자리**다: 이 텍스트는 running 집계 배지와 한 줄을 나눠 쓰고, 배지는 접힘과
/// 무관하게 늘 같은 파형을 그린다(docs/sidebar-agent-list.md §2). 상태줄을 통째로 실으면 같은 프레임의 파형이
/// 한 줄에 **두 번** 나와, 왼쪽(무엇이 몇 개 도는가)과 오른쪽(대표 상태)이 같은 애니메이션을 중복해 보여준다
/// (사용자 결정 2026-08-13 — 세션이 하나뿐이면 `▶ 1  ▁▅▇▃ · ▁▅▇▃ 진행중`처럼 두 파형이 같은 것을 말한다).
///
/// blocked/idle/unknown의 마커(`?`·`✓`·`·`)는 그대로 둔다 — 배지는 running만 세므로 그 상태들을 말하지 않고,
/// 마커가 사라지면 요약이 상태 없는 문구가 된다.
pub fn agentSummaryLine(self: *AppSession, term: *Term) ![]const u8 {
    if (term.agent_kind != .none and term.agent_state == .running)
        return self.allocator.dupe(u8, runningLabel());
    return agentStatusLine(self, term);
}

pub fn buildSidebarTitleDrawList(self: *AppSession) !renderer.DrawList {
    const cw = self.cell_width_px;
    // A deferred persistent-session launch can intentionally have no terminal tab while the
    // Recovered Sessions system rows are the only launch surface. Those rows are already the
    // canonical sidebar projection and must remain drawable before adoption.
    if (cw == 0 or (self.tabs.items.len == 0 and self.sidebar_rows.items.len == 0)) return error.NoSidebar;
    // U2/B2: 제목 영역 = 슬롯 폭에서 좌측(카드 패딩 + accent 막대)·우측(카드 패딩)을 inset한 content rect(선언적
    // 패딩, Rect.inset). 그 좌단을 셀 col로 ceil 환산(indent_cols)해 제목을 좌측 막대 우측·카드 안에 둔다(rich).
    // tui(0)면 left=right=0이라 전체 폭·indent 0(기존과 동일).
    const sp = self.buildChromeTokens().space; // 아래 그룹 들여쓰기 등 다른 토큰 소비자가 계속 쓴다
    // 열 배치는 **chrome이 단일 출처**다(`sidebar.columns`). 예전에는 이 함수가 gutter·inset·indent를 직접
    // 유도하고 hit-test(`closeButton`)는 `w - 3cw`로 따로 유도해, gutter가 상시 예약된 뒤 ✕의 보이는 자리와
    // 눌리는 자리가 아예 갈렸다(사용자 보고). 이제 그리는 쪽도 누르는 쪽도 이 한 값을 본다.
    const cols_layout = sidebarColumns(self) orelse return error.NoSidebar;
    const indent_cols: u16 = cols_layout.indent_cols;
    const sidebar_cols: u16 = cols_layout.cols;

    // 탭 카드를 소유 버퍼로 모은다(buildSidebarDrawList가 코드포인트로 디코드): names=이름줄(동작/활성 마커 ·/* prefix,
    // 번호 없음), branch_lines=octocat() 브랜치줄, path_lines=경로줄, status_lines=상태줄(빈 보조줄은 생략 → 1~4줄).
    // agents=에이전트 아이콘 코드포인트(0=없음) — 이름과 분리해 슬롯 세로 중앙에 독립 배치. pins=고정 핀(📌) 표시 여부
    // (buildSidebarDrawList가 이름줄 **우측 끝**에 그림 — 선두가 아니라, 마커가 가려지지 않게).
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |l| self.allocator.free(l);
        names.deinit(self.allocator);
    }
    var branch_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (branch_lines.items) |l| self.allocator.free(l);
        branch_lines.deinit(self.allocator);
    }
    var path_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (path_lines.items) |l| self.allocator.free(l);
        path_lines.deinit(self.allocator);
    }
    // 상태줄(4번째 줄): 에이전트 포그라운드일 때만 — running/blocked/idle/unknown을 짧은 상태 문구로 표시한다.
    // provider 답변이나 완료 의미를 추측하지 않는다. none이면 ""라 그 줄을 생략한다(docs/agent-session.md).
    var status_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (status_lines.items) |l| self.allocator.free(l);
        status_lines.deinit(self.allocator);
    }
    var agents: std.ArrayList(u21) = .empty; // 왼쪽 독립 gutter(접기 토글 삼각 전용 — 세션 행은 아래 inline)
    defer agents.deinit(self.allocator);
    var inline_icons: std.ArrayList(u21) = .empty; // 이름줄 선두 아이콘(세션 행의 kind·web·파일 아이콘)
    defer inline_icons.deinit(self.allocator);
    var pins: std.ArrayList(bool) = .empty;
    defer pins.deinit(self.allocator);
    // 카드당 대표 kind·running을 **한 번만** 스캔해 담는다(표시 슬롯 순서) — 아이콘·상태줄(여기)과 아래 색칠 루프가
    // 재사용해 tabAgentKind/tabHasRunningAgent(O(panes×terms))를 카드마다 여러 번 재스캔하지 않게(code-review high).
    var card_kinds: std.ArrayList(AgentKind) = .empty;
    defer card_kinds.deinit(self.allocator);
    var card_running: std.ArrayList(bool) = .empty;
    defer card_running.deinit(self.allocator);
    // 배지 줄의 색 구간(슬롯·열 범위·종류). 같은 블록 문자를 색으로만 가르므로 색칠 루프가 셀만 보고는 종류를
    // 알 수 없다 — 문자열을 만든 쪽이 좌표를 함께 기록해 넘긴다(`BadgeSpan` 주석).
    var badge_spans: std.ArrayList(BadgeSpan) = .empty;
    defer badge_spans.deinit(self.allocator);
    // 인덱스 도메인 통일(SG3c): 아래 카드-정보 배열(names/card_kinds…)은 **표시 row 인덱스**로 색인된다 —
    // group_header row도 padding 엔트리(삼각+이름 name, 빈 보조줄·아이콘 0·핀 false)를 하나 append해 배열 인덱스
    // i == 표시 row 인덱스가 되게 한다. buildSidebarDrawList도 이 i로 슬롯을 인코딩(sidebarGlyphRow)하고, active/close를
    // 비교한다. 그래서 active_row/close_row도 **row 인덱스**(displaySlotOf·hovered_slot과 같은 도메인)라 헤더가 섞여도
    // 강조가 어긋나지 않는다. glyph 세로 위치는 이 slot(=row)을 인코딩하되, .m의 균일 slot*slot_h 대신 Zig가 rowTop 기반
    // py_top을 origin_y에 실어 헤더(header_row_h<slot_h)를 반영한다(applySidebarGlyphPyTop — 카드·헤더 통일 content_tops).
    // (옛 "압축 카드 서수"는 헤더를 skip해 만들었으나, 헤더를 실제로 그리는 SG3c에선 헤더가 slot을 차지하므로 row 인덱스로 통일.)
    const cw2 = self.cell_width_px;
    const group_indent_cols: u16 = if (sp.group_indent_px > 0 and cw2 > 0) @intCast(@min((@as(u32, sp.group_indent_px) + cw2 - 1) / cw2, @as(u32, std.math.maxInt(u16)))) else 0;
    // 들여쓰기 공백 버퍼(카드 depth·중첩 헤더 depth-1 공유). depth×group_indent_cols가 24를 넘으면 clamp(오버플로 없음).
    const indent_buf = [_]u8{' '} ** 24;
    var active_row: ?usize = null;
    // 닫기 ✕는 **호버 전용이 아니라 행별 고정 표시**다(사용자 요청) — 카드는 그 워크스페이스를, 에이전트 행은
    // 그 Term을 닫는다. row별 bool로 실어 여러 행이 동시에 ✕를 가질 수 있게 한다.
    // 각 행의 **마지막 활동 상대 시각**("5m"·"now", 빈 문자열=표시 안 함). close_rows와 같은 per-row 병렬
    // 배열이라 **모든 분기가 정확히 한 번씩** append해야 한다 — 하나라도 빠지면 이후 모든 행의 시각이 밀린다
    // (close_rows에서 실제로 겪은 회귀).
    var ages: std.ArrayList([]const u8) = .empty;
    defer {
        for (ages.items) |a| self.allocator.free(a);
        ages.deinit(self.allocator);
    }
    var close_rows: std.ArrayList(bool) = .empty;
    defer close_rows.deinit(self.allocator);
    var editing_row: ?usize = null; // rename 중인 표시 슬롯(카드 또는 그룹 헤더) — buildSidebarDrawList가 그 이름줄을 tail 앵커로.
    // SG8d: 카드 드래그 프리뷰 중엔 고스트를 담은 preview_rows를 glyph로 조립한다(비드래그=원본 sidebar_rows). 아래
    // applySidebarGlyphPyTop·view 밴드도 같은 rows를 봐 세로 위치가 정합한다(단일 렌더 도메인).
    const rrows = sidebarRenderRows(self);
    for (rrows, 0..) |disp_row, row_i| {
        const card = switch (disp_row) {
            .card => |c| c,
            // 에이전트 목록 행: 카드와 같은 "row 하나 = 배열 엔트리 하나" 규율로 자기 줄을 채우고 넘어간다
            // (group_header padding 엔트리와 동형 — i == row 인덱스 유지). 표시 텍스트는 Row에 실린 인덱스로
            // **라이브 재조회**해 만든다(상태·시각이 매 tick 변하고, borrowed 슬라이스는 dangling 위험).
            .agent_toggle => |t| {
                // 삼각은 **텍스트 줄이 아니라 gutter 아이콘 경로**로 그린다 — 텍스트 줄의 글리프는 1칸이라
                // 이 자리에서 너무 작아 "눌러야 할 토글"로 안 읽혔다(사용자 피드백 2회). gutter는 에이전트 kind
                // 아이콘과 같은 **2칸 렌더**라 또렷하다(카드 아이콘이 크게 보이는 그 경로).
                const ind_n = @min(@as(usize, t.depth) * @as(usize, group_indent_cols), indent_buf.len);
                // **접혔을 때만** 상태 요약을 붙인다. 접으면 행들이 사라져 "무엇이 돌고 있는지"를 알 방법이
                // 아예 없어지기 때문이다(사용자 피드백 — 카드 상태줄을 없앤 판단의 빈틈). 펼친 상태에서는 각 행이
                // 자기 상태를 보여주므로 요약이 잉여라 붙이지 않는다. 요약 상태는 기존 대표 규칙
                // (blocked > running > idle > unknown)을 그대로 써 **주의가 필요한 것이 먼저** 드러나게 한다.
                // 텍스트는 `agentStatusLine`이 아니라 `agentSummaryLine`이다 — running의 파형은 같은 줄의 집계
                // 배지가 이미 그리므로 요약에서는 뺀다(그 함수의 doc이 근거).
                const toggle_summary: []const u8 = if (t.collapsed and t.tab < self.tabs.items.len) blk: {
                    const rep = tab_ops.tabAgentRepresentative(self.tabs.items[t.tab]) orelse break :blk try self.allocator.dupe(u8, "");
                    const st = try agentSummaryLine(self, rep.term);
                    defer self.allocator.free(st);
                    if (st.len == 0) break :blk try self.allocator.dupe(u8, "");
                    break :blk try std.fmt.allocPrint(self.allocator, " \u{00b7} {s}", .{st});
                } else try self.allocator.dupe(u8, "");
                defer self.allocator.free(toggle_summary);
                // 라벨은 **개수 숫자만**이다. 예전엔 `1 sessions`처럼 단어를 붙였는데, 옆에 running 집계 배지가 오면서
                // 좁은 사이드바에서 단어가 배지·상태 문구를 밀어내 말줄임을 만들었다(사용자 결정 2026-08-12:
                // "세션스라는 텍스트를 없애 달라"). 숫자는 남긴다 — 배지는 **running만** 세므로 idle을 포함한 전체
                // 세션 수는 숫자만이 답한다(둘은 다른 질문이다).
                //
                // 배지는 **접힘과 무관하게 항상** 붙인다. 카드에서 배지를 걷어낸 뒤로 이 줄이 "무엇이 몇 개 도는가"의
                // 유일한 자리이기 때문이다 — 접었을 때만 보이면 «안 보이는 것을 없는 것처럼 만들지 않는다»가 펼침에서
                // 뒤집힌다. 반면 뒤따르는 대표 상태 요약(`· 진행중`)은 **접혔을 때만**이다(위 toggle_summary): 펼치면
                // 각 행이 자기 상태를 보여줘 잉여이고, 배지와 달리 목록이 답할 수 있는 질문이다.
                // 집계는 **한 번만** 센다 — 아래 간격과 배지 본문이 같은 «running > 0»을 보므로, 두 번 세면 그
                // 조건이 두 곳에 따로 적혀 어긋날 수 있다(간격만 남은 줄).
                const badge_counts: tab_ops.RunningCounts = if (t.tab < self.tabs.items.len)
                    tab_ops.tabRunningCountsByKind(self.tabs.items[t.tab])
                else
                    .{};
                // 배지가 없으면 개수 뒤 간격도 없앤다 — 안 그러면 running 0인 행만 꼬리 공백이 남아 상태 문구가 밀린다.
                const badge_gap: []const u8 = if (badge_counts.total() > 0) "  " else "";
                const badge_prefix = try std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ indent_buf[0..ind_n], t.count, badge_gap });
                defer self.allocator.free(badge_prefix);
                // 시작 열 = **gutter 아이콘 폭 + prefix 표시 폭**이다.
                //
                // 이 행은 삼각(▼/▶)을 gutter에 실으므로 빌더가 이름줄 텍스트를 `sidebar_row_icon_cols`만큼 민다
                // (`buildSidebarDrawList`의 `text_col`). 그 폭을 빼먹으면 색 구간만 왼쪽으로 밀려 **파형 대신 라벨이
                // 브랜드색을 받는다**. 카드 배지 시절엔 이 문제가 없었다 — 배지가 gutter 없는 보조줄(status)에 있었다.
                // 한 종류만 도는 화면에서는 밀려난 칸이 스피너 경로에서 **대표 kind의 같은 색**을 받아 증상이 가려지고,
                // claude·codex가 함께 도는 화면에서만 색이 갈려 드러난다(적대적 검증 2회차에서 이렇게 잡혔다).
                //
                // prefix는 공백과 숫자(ASCII 1칸)뿐이라 byte 길이와 칸 수가 같다 — 다국어 문자가 섞이면 이 등식이
                // 깨지므로 라벨을 숫자로 유지하는 것이 span 정합의 전제다.
                const badge_start_col: u16 = coretext_frame_builder.sidebar_row_icon_cols + @as(u16, @intCast(badge_prefix.len));
                const badge = try runningBadgeText(self, badge_counts, badge_start_col, &badge_spans, row_i);
                defer self.allocator.free(badge);
                // 조립한 이름줄은 **중간 변수로 받아** append 실패 시 직접 해제한다. `append(alloc, try allocPrint(…))`로
                // 바로 넘기면 문자열은 만들어졌는데 append가 OOM으로 실패했을 때 아무도 그것을 소유하지 않아 샌다
                // (이 코드베이스가 에이전트 행 라벨에서 이미 한 번 겪은 실패다). `errdefer`가 아니라 `catch`인 이유는,
                // append가 **성공한 뒤** 아래 다른 append가 실패하면 errdefer가 이미 names 소유가 된 것을 또 해제해
                // 이중 해제가 되기 때문이다.
                const toggle_name = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ badge_prefix, badge, toggle_summary });
                names.append(self.allocator, toggle_name) catch |e| {
                    self.allocator.free(toggle_name);
                    return e;
                };
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try agents.append(self.allocator, if (t.collapsed) @as(u21, 0x25B6) else @as(u21, 0x25BC));
                try inline_icons.append(self.allocator, 0); // 토글 삼각은 gutter에 남는다(텍스트 줄이면 1칸이라 안 읽힌다)
                try pins.append(self.allocator, false);
                // 접힘 요약의 파형도 **브랜드색**이어야 한다 — 요약은 접었을 때 유일한 상태 단서인데, kind=none·
                // running=false를 실으면 색칠 루프가 그 자리만 흐린 회색으로 남긴다(code-review max).
                const trep = if (t.tab < self.tabs.items.len) tab_ops.tabAgentRepresentative(self.tabs.items[t.tab]) else null;
                try card_kinds.append(self.allocator, if (trep) |r| r.term.agent_kind else .none);
                try card_running.append(self.allocator, if (trep) |r| (r.state == .running) else false);
                try close_rows.append(self.allocator, false); // 토글 자체는 닫기 대상이 아니다(접기만)
                // 접힘 요약이 상태의 유일한 단서이므로 시각도 대표 에이전트 것으로 채운다(파형 색과 같은 이유).
                // **접혔을 때만**이다 — 펼친 상태에선 바로 아래 행이 자기 시각을 이미 보여줘 중복이고, 요약을
                // 접힘 전용으로 둔 규칙(toggle_summary)과도 어긋난다(code-review max).
                try ages.append(self.allocator, if (t.collapsed)
                    try agentAgeOwned(self, if (trep) |r| r.term else null)
                else
                    try self.allocator.dupe(u8, ""));
                continue;
            },
            .agent => |ar| {
                const atab: ?*Tab = if (ar.tab < self.tabs.items.len) self.tabs.items[ar.tab] else null;
                const aterm: ?*Term = if (atab) |t| agentTermOf(t, .{ .pane = ar.pane, .term = ar.term }) else null;
                const ind_n = @min(@as(usize, ar.depth) * @as(usize, group_indent_cols), indent_buf.len);
                const ind = indent_buf[0..ind_n];
                // 1행: 상태 마커 + 종류 이름 + 상태 문구. 시각(우측 정렬)은 폭 계산이 필요해 후속 슬라이스로 미룬다.
                // 라벨은 owned라 **중간 변수로 받아 반드시 해제**한다 — 예전엔 allocPrint 인자로 바로 넘겨
                // 바깥 문자열만 names가 소유하고 안쪽이 매 rebuild마다 누수됐다(code-review max).
                if (aterm) |t| {
                    const label = try agentRowLabelOwned(self, t);
                    defer self.allocator.free(label);
                    // 아이콘 자리는 **빌더가 이름줄만** 밀어 준다(inline_icons) — 여기서 공백으로 밀면
                    // 보조줄까지 따라 밀린다. 그래서 라벨은 indent만 붙이고 그대로 넘긴다.
                    try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ ind, label }));
                } else {
                    try names.append(self.allocator, try self.allocator.dupe(u8, ""));
                }
                // 2·3행: 그 Term의 폴더와 브랜치(§2.1 — 항상 표시, 카드 헤더와 달리 **그 에이전트가 도는 자리**).
                // **한 줄에 합치지 않는다**: 사이드바 폭에서 폴더+브랜치를 한 줄에 넣으면 브랜치가 잘린다(실측).
                // 보조줄 좌단을 **이름 본문**(아이콘 뒤)에 맞춘다. 보조줄 포맷이 indent 뒤에 2칸을 이미
                // 붙이므로 한 칸을 더 줘야 아이콘 폭(2)+간격(1)과 합이 맞는다.
                var aux_indent_buf: [64]u8 = undefined;
                const aux_ind: []const u8 = blk: {
                    if (ind.len + 1 > aux_indent_buf.len) break :blk ind;
                    @memcpy(aux_indent_buf[0..ind.len], ind);
                    aux_indent_buf[ind.len] = ' ';
                    break :blk aux_indent_buf[0 .. ind.len + 1];
                };
                try branch_lines.append(self.allocator, if (aterm) |t|
                    try agentRowFolderOwned(self, t, aux_ind)
                else
                    try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, if (aterm) |t|
                    try agentRowBranchOwned(self, t, aux_ind)
                else
                    try self.allocator.dupe(u8, ""));
                // 4행: 마지막 **응답**(§7). sidebarAgentRowLines의 줄 수 조건과 1:1이다.
                try status_lines.append(self.allocator, if (aterm) |t|
                    try agentRowReplyOwned(self, t, aux_ind)
                else
                    try self.allocator.dupe(u8, ""));
                // 종류 아이콘은 **이름줄 선두**에 인라인으로 둔다 — 옛 왼쪽 gutter는 글리프 하나 때문에 행의
                // 모든 줄에서 3칸을 뺏고(폭의 7%), 슬롯 세로 중앙에 놓여 줄 수가 다른 행끼리 열도 못 이뤘다
                // (사용자 피드백). gutter는 접기 토글 삼각만 계속 쓴다.
                // 아이콘이 없는 일반 터미널 행도 `icon_slot_reserve`로 **자리는 잡아** 라벨 좌단을 맞춘다.
                const row_icon: u21 = if (aterm) |t| sessionRowIconCodepoint(t) else 0;
                // 아이콘 없는 행도 **자리는 잡아야** 한다 — 안 그러면 그 행만 라벨이 아이콘 폭만큼 왼쪽으로
                // 튀어 목록 좌단이 어긋난다(사용자 제보).
                try agents.append(self.allocator, 0); // gutter는 접기 토글 삼각 전용
                try inline_icons.append(self.allocator, if (row_icon == 0) coretext_frame_builder.icon_slot_reserve else row_icon);
                try pins.append(self.allocator, false);
                try card_kinds.append(self.allocator, if (aterm) |t| t.agent_kind else .none);
                try card_running.append(self.allocator, if (aterm) |t| (t.agent_state == .running) else false);
                try close_rows.append(self.allocator, aterm != null); // 에이전트 행 ✕ = 그 Term 닫기
                try ages.append(self.allocator, try agentAgeOwned(self, aterm));
                continue;
            },
            .recovered_sessions_header => {
                try names.append(self.allocator, try self.allocator.dupe(u8, "Recovered Sessions"));
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try agents.append(self.allocator, 0);
                try inline_icons.append(self.allocator, 0);
                try pins.append(self.allocator, false);
                try card_kinds.append(self.allocator, .none);
                try card_running.append(self.allocator, false);
                try close_rows.append(self.allocator, false);
                try ages.append(self.allocator, try self.allocator.dupe(u8, ""));
                continue;
            },
            .recovered_session => |candidate| {
                const recovered = self.recoveredSessionsRows(self.is_primary_window);
                const label: []const u8 = if (candidate.projection_index < recovered.len)
                    recovered[candidate.projection_index].label[0..]
                else
                    "";
                try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "  {s}", .{label}));
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try agents.append(self.allocator, 0);
                try inline_icons.append(self.allocator, 0);
                try pins.append(self.allocator, false);
                try card_kinds.append(self.allocator, .none);
                try card_running.append(self.allocator, false);
                try close_rows.append(self.allocator, false);
                try ages.append(self.allocator, try self.allocator.dupe(u8, ""));
                continue;
            },
            .group_header => |gh| {
                // 그룹 헤더 padding 엔트리 — 삼각(펼침 ▾ U+25BE / 접힘 ▸ U+25B8) + 그룹 이름(접힘 시 " (N)" 배지).
                // 이름은 소스 탭의 group_start를 **live 재조회**(#8 UAF 회피 — borrowed label 미사용). 빈 이름은 "그룹" 폴백.
                const tri: []const u8 = if (gh.collapsed) "\u{25B8}" else "\u{25BE}";
                const gtab: ?*Tab = if (gh.tab < self.tabs.items.len) self.tabs.items[gh.tab] else null;
                // 중첩 헤더 들여쓰기(SG5-3): eff_depth d 헤더는 (d-1)*group_indent(소속 카드는 d*group_indent). 최상위
                // (d=1)=0이라 비중첩 렌더는 그대로. 삼각/이름 앞에 공백을 넣어 폴더 트리처럼 자식 그룹이 더 들여쓰인다.
                const hindent_lvl: usize = if (gh.depth > 0) gh.depth - 1 else 0;
                const hindent_n = @min(hindent_lvl * @as(usize, group_indent_cols), indent_buf.len);
                const hindent = indent_buf[0..hindent_n];
                const header_text = if (gtab != null and self.renamingGroup(gtab.?)) blk: {
                    // 이 그룹 이름 rename 중 → 삼각 뒤에 편집 텍스트(+caret). 접힘 배지는 편집 집중 위해 숨긴다.
                    editing_row = row_i; // 이 헤더 이름줄을 tail 앵커로(긴 이름 caret 유지)
                    const edit = try settings_ops.renameEditText(self, self.allocator);
                    defer self.allocator.free(edit);
                    break :blk try std.fmt.allocPrint(self.allocator, "{s}{s} {s}", .{ hindent, tri, edit });
                } else blk: {
                    const gname: []const u8 = if (gtab) |t| (t.group_start orelse "") else "";
                    const label: []const u8 = if (gname.len > 0) gname else maru.i18n.t(.sb_group);
                    break :blk if (gh.collapsed)
                        try std.fmt.allocPrint(self.allocator, "{s}{s} {s} ({d})", .{ hindent, tri, label, gh.member_count })
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}{s} {s}", .{ hindent, tri, label });
                };
                try names.append(self.allocator, header_text); // owned
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try agents.append(self.allocator, 0); // 헤더엔 에이전트 아이콘 없음
                try inline_icons.append(self.allocator, 0);
                // 그룹 고정 인디케이터(§12.8 GP4): 마커 pinned면 헤더 이름줄 우측 끝에 📌 — "이 그룹 고정됨"을 헤더 하나에
                // (멤버 카드 📌 노이즈 대신). rename 중엔 억제(편집 폭 보존 — 카드 pin과 같은 규칙). sidebarRowShowsPin이 단일 출처.
                const header_renaming = gtab != null and self.renamingGroup(gtab.?);
                try pins.append(self.allocator, if (header_renaming) false else sidebarRowShowsPin(self, disp_row));
                try card_kinds.append(self.allocator, .none); // 색칠 루프 인덱스 정합(헤더=none → 무색)
                try card_running.append(self.allocator, false);
                try close_rows.append(self.allocator, false); // 그룹 헤더엔 ✕ 없음
                try ages.append(self.allocator, try self.allocator.dupe(u8, "")); // 시각은 에이전트 행 전용
                continue; // 헤더 row 엔트리 1개 append 완료 — 다음 row로(i==row 인덱스 유지)
            },
        };
        const orig = card.tab;
        if (orig == self.app_window.active_tab) active_row = row_i;

        const tab = self.tabs.items[orig]; // 표시 슬롯 순서 → 원본 탭(검색 필터)
        // **의도된 기준 분리(사용자 결정 A)**: 카드의 이름·브랜치(저장소)·경로는 **활성 Term**(아래 `term`) 기준이고,
        // 스피너·gutter 아이콘·브랜드색은 **워크스페이스(탭) 전체**(tabHasRunningAgent/tabAgentKind, 아무 pane/Term) 기준이다.
        // 이유: 사이드바는 **비활성 워크스페이스의 상태까지 한눈에** 보여주는 유일한 곳이라(탭바는 활성 워크스페이스만),
        // 백그라운드 Term의 에이전트도 "이 워크스페이스가 바쁨"으로 떠야 개요가 산다. **활성 Term과 running Term이 다른**
        // (다른 repo이거나 같은 repo 다른 하위 디렉터리·브랜치) 경우에만 repo/경로(활성)와 스피너(다른 Term)가 시각적으로
        // 어긋난다 — 개요 가치를 위해 수용(code-review max 확인).
        const term = tab.activePane().activeTerm();
        const renaming = workspace_ops.renamingWorkspace(self, tab);
        if (renaming) editing_row = row_i; // 이 카드 이름줄을 tail 앵커로(긴 이름 caret 유지)
        // 카드당 1회 스캔: 대표 kind + running(색칠 루프·상태줄과 공유). **rename 중에도** 실제 값을 계산한다 —
        // 편집 중에도 running 파형(상태줄)을 보여야 하기 때문(사용자 요청). 아이콘만 rename 중 숨긴다(캐럿 정렬).
        const card_kind: AgentKind = tab_ops.tabAgentKind(tab);
        const running = tab_ops.tabHasRunningAgent(tab);
        try card_kinds.append(self.allocator, card_kind);
        try card_running.append(self.allocator, running);
        // 에이전트 아이콘은 슬롯 중앙에 독립 배치. 단 rename 중엔 숨긴다(0) — 안 그러면 편집 텍스트가 icon_cols
        // 만큼 우측으로 밀려 renameCaretRect(아이콘 오프셋 미반영)의 caret/IME 후보창과 어긋난다.
        // 아이콘은 **탭 대표 kind**(running Term 우선) — 백그라운드 Term의 에이전트도 카드 gutter에 종류 아이콘을 띄운다.
        // 대표 아이콘 없음: 종류·상태는 **에이전트 목록 행**이 행마다 보여주므로(docs/sidebar-agent-list.md §2)
        // 카드에 대표 하나를 또 그리면 같은 정보가 두 곳에 다른 형태로 나온다. gutter는 목록 행이 쓴다.
        try agents.append(self.allocator, 0);
        try inline_icons.append(self.allocator, 0); // 카드 이름줄 선두는 동작/활성 마커(·/*) 전용
        // 이름줄 = custom_name(rename) 우선, 없으면 활성 Term 라벨. rename 중이면 편집 텍스트로 대체하고 보조줄은 숨긴다.
        if (renaming) {
            // rename 중엔 마커·핀을 안 붙인다 — 마커 prefix를 붙이면 편집 텍스트가 2칸 밀려 renameCaretRect(이름줄
            // 좌단=indent 가정)의 caret/IME 후보창과 어긋나고, 핀은 편집 폭을 잡아먹는다. 편집 동안만 전체 폭 사용.
            try names.append(self.allocator, try settings_ops.renameEditText(self, self.allocator)); // owned → names가 소유
            try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
            try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
            // **상태줄은 rename 중에도 표시** — 편집하는 워크스페이스가 running이면 파형 스피너를 보여준다(사용자 요청:
            // "리네임하면 애니메이션이 안 보인다"). 캐럿은 이름줄에만 있어 간섭 없고, "편집 이름 + 상태줄" 레이아웃은
            // non-git 에이전트 워크스페이스(브랜치/경로 없이 상태줄만)와 동형이라 안전하다. 브랜치/경로는 편집 집중 위해 계속 숨김.
            try status_lines.append(self.allocator, try workspaceStatusLine(self, tab));
            try pins.append(self.allocator, false);
            // ✕도 편집 중엔 숨긴다(핀과 같은 이유 — 편집 폭 확보). **append 자체를 빼면 안 된다**: close_rows는
            // row별 병렬 배열이라 한 칸이 비면 이후 모든 행의 ✕가 한 줄씩 밀리고 마지막 행은 "안 보이는데
            // 눌리는" 파괴적 hotspot이 된다(code-review max).
            try close_rows.append(self.allocator, false);
            try ages.append(self.allocator, try self.allocator.dupe(u8, "")); // 편집 중엔 시각도 숨긴다(핀·✕와 같은 이유)
        } else {
            const base = workspaceLabel(tab);
            // 이름줄 선두 = 동작/활성 마커: 활성 워크스페이스='*', 그 외='·'(U+00B7). 핀(📌)은 옛 설계처럼 선두에 박지
            // 않고 buildSidebarDrawList가 이름줄 우측 끝에 따로 그린다 — 선두 칼럼을 마커 전용으로 비워 핀이 "동작/활성"
            // 표시를 가리지 않게 한다(사용자 요청). 마커는 이름줄(line 0) 색을 따라간다(활성=강조, 그 외=흐림).
            const marker: []const u8 = if (orig == self.app_window.active_tab) "* " else "\u{00B7} ";
            // SG3: 그룹 안 카드(depth>0)는 group_indent만큼 들여쓴다(소속 시각화). **카드 전체**(이름·브랜치·경로·상태
            // 모든 줄)에 같은 indent를 붙여 폴더 트리처럼 일관되게 밀린다(사용자 요청 — 예전엔 이름줄만 밀려 비대칭).
            // 헤더 삼각과 같은 gutter(col 0) 기준. 공백은 ellipsis 폭에 자연 반영돼 오버플로가 없다. 빈 보조줄엔 안 붙인다
            // (빈 줄은 buildSidebarDrawList가 생략하므로, 공백만 붙이면 빈 줄이 렌더돼 줄 수가 어긋난다). depth 0은 무들여쓰기.
            // 중첩(SG5-3): depth가 2+면 자동으로 더 들여쓰인다(값 범위만 확장, 산술은 동일 — 위 hoisted indent_buf 공유).
            const indent_n = @min(@as(usize, card.depth) * @as(usize, group_indent_cols), indent_buf.len);
            const indent = indent_buf[0..indent_n];
            try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ indent, marker, base }));
            // 그룹 고정 C2(§12.8 GP4): live tab.pinned 대신 sidebarRowShowsPin(pin_derived 힌트)을 읽어 **멤버 파생 pin·
            // 그룹 마커 카드의 📌를 억제**한다(그룹 고정은 헤더 인디케이터가 든다). 최상위 개별 pin만 📌 유지. 옛 `tab.pinned`
            // 직접 읽기는 그룹 멤버 캐시 pinned=1을 그대로 그려 모든 멤버에 📌 노이즈를 냈다(§12.8 루트커즈).
            try pins.append(self.allocator, sidebarRowShowsPin(self, disp_row));
            try close_rows.append(self.allocator, true); // 카드 ✕ = 그 워크스페이스 닫기(고정 표시)
            // 카드 헤더엔 시각을 두지 않는다 — 카드는 워크스페이스이지 한 에이전트가 아니라 "언제"의 주체가
            // 모호하고, 아래 목록의 행마다 자기 시각이 이미 있다.
            try ages.append(self.allocator, try self.allocator.dupe(u8, ""));
            // 브랜치줄·경로줄: cwd가 git repo 안일 때만(branch != null) + view options 토글로 표시 여부 결정.
            // 이름줄은 항상 표시(사용자 요청). show-branch=false면 브랜치줄 생략, show-folder=false면 경로줄 생략.
            // 토글은 독립적이다 — 둘 다 "git repo 안"을 전제로 하되(maru는 repo 밖 cwd 줄을 안 그림) 서로 안 묶인다.
            const branch = git_ops.termGitBranch(self, term); // cwd 변경 시에만 .git/HEAD 재읽기(캐시) — repo 판정에도 씀
            const show_branch = self.loaded_config.config.sidebar.show_branch;
            // show-folder 토글은 sidebarFolderLineShown 안에서 본다(줄 수 계산과 같은 함수를 공유하려고 옮겼다).
            // 브랜치줄 prefix = GitHub octocat(0xF0009). 예전 git-branch(0xF0001)는 얇은 선+링 3개라 카드 셀 크기
            // (~8~12px)로 area-average 다운스케일되면 내부 구조가 뭉개져 ├(U+251C)처럼 보였다(사용자 피드백). octocat은
            // 꽉 찬 단색 실루엣이라 작은 크기에서도 외곽이 살아 GitHub 마크로 읽힌다(icon_glyph fillCoverage 경로 동일).
            // 폭은 wideIconPredicate가 PUA를 **2칸(~16px)** 렌더해 width-1(~8px)일 때 동그란 링처럼 뭉개지던 걸 키웠다 —
            // 폴더줄(0xF000A)·에이전트 gutter 아이콘과 같은 크기로 통일(사용자 피드백 "깃 아이콘이 너무 작다").
            // 각 보조줄은 **비어있지 않을 때만** indent를 붙인다(빈 줄은 그대로 "" — 카드 줄 수 계산 정합).
            try branch_lines.append(self.allocator, if (show_branch) (if (branch) |b| try std.fmt.allocPrint(self.allocator, "{s}" ++ icons.utf8(.mark_github) ++ " {s}", .{ indent, b }) else try self.allocator.dupe(u8, "")) else try self.allocator.dupe(u8, ""));
            try path_lines.append(self.allocator, if (sidebarFolderLineShown(self, term)) blk: {
                const fl = try sidebarFolderLine(self, term);
                if (indent.len == 0 or fl.len == 0) break :blk fl; // depth 0 or 빈 줄 — 그대로(빈 줄에 공백 붙이면 4번째 줄이 생긴다)
                defer self.allocator.free(fl);
                break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ indent, fl });
            } else try self.allocator.dupe(u8, ""));
            // 카드에는 상태줄이 없다. 대표 하나로 압축하던 자리는 **에이전트 목록**이 대체했고(§2 "기존 대표 표시는
            // 제거"), 목록이 접혔을 때의 빈틈은 카드가 아니라 **`sessions` 토글 행의 집계 배지**가 메운다
            // (사용자 결정 2026-08-12: "세션 위의 부모 탭에서도 나온다 — 없애 달라").
            //
            // 카드로 되돌리지 않는 이유는 배지가 토글 행에서 **더 적은 비용으로 같은 질문에 답하기** 때문이다:
            // 토글 행은 목록의 접힘 여부와 무관하게 항상 한 줄 있으므로, 카드에 4번째 줄을 만들지 않고도
            // "무엇이 몇 개 도는가"가 늘 보인다. 카드 줄 수가 구성마다 달라지던 문제도 함께 사라진다.
            //
            // **빈 줄은 반드시 ""다** — 공백-only 줄은 buildSidebarDrawList가 빈 줄로 생략하지 못해 **없던 4번째 줄이
            // 렌더**된다(사용자 제보 버그). indent를 붙이지 않는 것이 그 규율이다.
            try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
        }
    }

    // 비활성 워크스페이스 제목은 흐린 색(muted), 활성 워크스페이스(active_tab 행)는 full sidebar_foreground로 강조한다.
    const fg: terminal.Color = .{ .rgb = self.mutedForeground() };
    const active_fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    // 호버 슬롯엔 닫기 ✕(없으면 null). plus_row = 탭 개수 → 목록 아래 행에 "+"(새 워크스페이스) 버튼.
    // plus_row=null — 하단 "+" 버튼은 헤더 우측 아이콘으로 이동·폐기(P2). 호버 슬롯엔 닫기 ✕(없으면 null).
    // close_row/active_row는 **표시 row 인덱스**(위 padding 루프가 헤더도 slot을 차지하게 해 i==row) — buildSidebarDrawList가
    // 이 i로 슬롯을 인코딩·비교하므로 도메인이 일치한다(SG3c). 헤더 row는 위 루프가 close_row를 안 세워 ✕가 안 붙는다.
    var draw_list = try coretext_frame_builder.buildSidebarDrawList(self.allocator, names.items, branch_lines.items, path_lines.items, status_lines.items, agents.items, inline_icons.items, pins.items, sidebar_cols, fg, close_rows.items, ages.items, null, active_row, active_fg, editing_row);
    // 에이전트 아이콘(✶ claude / ◆ codex)과 상태줄 running 스피너(이퀄라이저 바 ▁~█)에 **브랜드색**을 입힌다 — claude=Anthropic 코랄,
    // codex=OpenAI 청록. 종류를 색으로 구분하고, **관측 상태는 상태줄**(running=이퀄라이저 파형[브랜드색]·idle=✓ 대기중)이 담당한다
    // (옛 아이콘 밝기 펄스는 폐기 — 아래 루프는 아이콘·스피너 모두 솔리드 브랜드색). 색은 `term.agent_kind` 단일 출처로 고른다.
    // **오염 방지**: 아이콘은 gutter `col 0` + 합성 codepoint로 좁히고, 스피너는 **상태줄(카드 마지막 줄)**에만 색칠한다 —
    // 워크스페이스 이름/브랜치/경로 줄(line_index<line_count-1)에 블록 글자가 들어가도 안 오염(code-review high #2).
    // 슬롯(탭)별 kind·running은 위 조립 루프가 카드당 1회 스캔해 담은 `card_kinds`/`card_running`을 **그대로 재사용**한다
    // (표시 슬롯 = 배열 인덱스) — 셀·슬롯마다 tabAgentKind/tabHasRunningAgent(O(panes×terms))를 다시 안 돌린다(code-review high).
    for (draw_list.cells) |*c| {
        // ✶ claude / ◆ codex. 열 게이트는 **아이콘이 놓일 수 있는 자리**만 허용한다 — gutter는 col 0, 인라인은
        // `session_row_indent_cols`(행 들여쓰기)다. 그 상한을 안 두면 사용자 텍스트에 우연히 섞인 같은 PUA가
        // 브랜드색으로 칠해진다(code-review high #2의 오염 방지 규율).
        const is_icon = c.col <= coretext_frame_builder.session_row_indent_cols and
            (c.codepoint == icons.codepoint(.sparkle) or c.codepoint == icons.codepoint(.diamond));
        // 셀 row에서 표시 슬롯 인덱스를 디코드(row=slot*sidebar_line_base+줄offset, 줄offset<base라 아이콘/스피너 같은 슬롯).
        const slot = c.row / coretext_frame_builder.sidebar_line_base; // = card_kinds/card_running 인덱스(조립 순서와 동일)
        if (slot >= card_kinds.items.len) continue;
        // 이퀄라이저 바(블록 ▁~█)는 이제 **에이전트 목록 행**에 있다 — 카드 상태줄이 목록으로 이동했기 때문
        // (docs/sidebar-agent-list.md §2). 옛 게이트는 "카드의 마지막 줄"(line_index==line_count-1)로 좁혀서,
        // 목록 행의 첫 줄에 오는 파형을 못 잡아 브랜드색이 빠졌다(사용자 제보). row **종류**로 게이트하면
        // 위치가 바뀌어도 따라오고, 이름·경로 줄의 우연한 블록 문자가 오염되는 것도 막는다.
        const on_agent_row = slot < rrows.len and (rrows[slot] == .agent or rrows[slot] == .agent_toggle);
        const is_spinner = on_agent_row and isAgentSpinnerCp(c.codepoint);
        // **집계 배지가 먼저다.** 아래 스피너 경로는 그 행의 **대표 kind 한 색**만 칠하므로, 먼저 잡히면 claude·codex
        // 배지가 모두 같은 색이 된다(배지의 존재 이유가 사라진다). 그래서 문자열을 만든 쪽이 기록한 열 구간
        // (`badge_spans`)을 스피너 판정보다 앞에서 본다. 개수 숫자도 같은 구간에 들어 파형과 같은 색을 받는다
        // (한 배지 = 한 색). 구간에 걸리지 않은 셀은 그대로 아래 경로로 흐른다.
        //
        // 접힘 요약은 파형을 싣지 않는다(`agentSummaryLine`) — 배지가 이미 같은 파형을 그리는 줄이라 상태줄을 통째로
        // 실으면 한 줄에 같은 애니메이션이 두 번 나온다. 따라서 이 줄의 블록 문자는 지금 전부 배지 것이지만, 순서는
        // 위 이유(배지 둘 사이의 색 구분)만으로 이미 필요하다.
        //
        // **줄까지 좁힌다.** `span.slot`은 *행*을 고를 뿐이고 한 행은 여러 *줄*을 가질 수 있어서, slot만 보면 같은 행의
        // 다른 줄에서 같은 열에 온 글자가 배지색을 받는다(카드 배지 시절 `line_index + 1 == line_count`로 좁히던
        // 규율 — 옮기면서 빠졌다). 배지는 토글 행의 **이름줄**에만 있으므로 `line_index == 0`이 그 자리다. 지금은
        // 토글이 보조줄을 비워 1줄이라 증상이 없지만, 줄이 하나 붙는 순간 조용히 오염된다.
        //
        // row 종류(`.agent_toggle`) 게이트는 **중복 방어**로 남긴다 — `span.slot`이 이미 행을 좁히므로 없어도
        // 오염되지 않지만, 배지가 토글 행 전용이라는 계약을 색칠 쪽에도 적어 두면 나중에 span 출처가 늘어날 때
        // 이 루프가 먼저 걸린다.
        // **글리프까지 본다.** 구간은 열 범위일 뿐이라, 그 자리에 배지가 아닌 글자가 오면 그것도 색을 받는다. 배지
        // 구간에 정당하게 올 수 있는 것은 **파형**과 **개수 숫자**뿐이므로 스피너 경로와 같은 규율을 여기에도 둔다
        // (옮겨 오면서 이쪽만 빠져 있었다).
        //
        // 정직하게 적어 둔다: 이 게이트가 막는 상황을 **실제로 재현하지는 못했다**. 좁은 사이드바의 말줄임
        // `…`(U+2026)을 노렸지만, 배지가 줄 앞부분이라 `…`은 구간 뒤에 오거나 그 폭에서는 아예 나오지 않았다
        // (적대적 검증 12회차 — 폭 90·72·56 실측). 그럼에도 남기는 이유는 비용이 0이고, "색은 자기 글리프에만"이
        // 이 루프가 아이콘·스피너에 이미 적용하는 규율이기 때문이다. 재현하지 못한 것을 테스트로 굳히지는 않았다.
        const badge_glyph = isAgentSpinnerCp(c.codepoint) or (c.codepoint >= '0' and c.codepoint <= '9');
        var badge_painted = false;
        const badge_line_index = (c.row % coretext_frame_builder.sidebar_line_base) % 4;
        if (badge_glyph and badge_line_index == 0 and slot < rrows.len and rrows[slot] == .agent_toggle) {
            for (badge_spans.items) |span| {
                if (span.slot != slot or c.col < span.start_col or c.col >= span.end_col) continue;
                if (agentBrandColor(span.kind)) |badge_brand| {
                    c.style.foreground = .{ .rgb = badge_brand };
                    badge_painted = true;
                }
                break;
            }
        }
        if (badge_painted) continue;
        if (!is_icon and !is_spinner) continue;
        // 스피너 색칠은 **어느 Term이든 running일 때만** — idle/blocked/unknown 상태 문구에 블록 글자가 우연히 있어도
        // 브랜드색으로 오염되지 않게 한다(넓힌 블록 게이트 부작용 차단, code-review high). 아이콘은 상태 무관 솔리드.
        if (is_spinner and !card_running.items[slot]) continue;
        const brand = agentBrandColor(card_kinds.items[slot]) orelse continue; // kind=none(이름 글자 등) — 색칠 안 함.
        // 아이콘·스피너 모두 **솔리드 브랜드색**(running 펄스 폐기). 작업 중 애니메이션은 상태줄 파형이 담당, 아이콘은 종류/presence.
        c.style.foreground = .{ .rgb = brand };
    }
    // U2/B2: 제목·✕·+ 셀을 content rect 좌단(indent_cols)만큼 우측으로 민다 — 좌측 maru-accent 막대 + 카드 패딩 안 가리게(rich만; tui indent=0 no-op).
    if (indent_cols > 0) {
        for (draw_list.cells) |*c| c.col += indent_cols;
        // 시프트로 셀이 [indent_cols, sidebar_cols+indent_cols)로 가므로 surface 폭도 full_cols로 넓힌다 — 안 그러면
        // 폭을 꽉 채운 긴 경로줄이 size.cols(=sidebar_cols)를 넘어 ShapedRecordOutsideSurface로 프레임이 통째로 실패
        // (짧은 이름은 안 걸리던 잠재 버그를 경로줄이 깨움). full_cols ≥ sidebar_cols+indent_cols라 항상 수용한다.
        draw_list.size.cols = cols_layout.full_cols;
    }
    // SG8d: 고스트 카드 glyph를 살짝만 dim한 muted 색으로(반투명 밴드+삽입선과 짝 — "떠 있는" 카드로 읽히되 무슨
    // 카드인지는 또렷이 읽히게). slot = c.row/sidebar_line_base = 표시 row 인덱스라 preview_rows[ghost_lo,hi) 셀만 고른다.
    // brand 색 루프 뒤에 적용해 고스트 안 에이전트 아이콘/스피너도 함께 흐려진다(고스트는 어느 셀이든 흐림 — 의도).
    // 옛 35/65는 반투명 밴드(≈0x30 밝힘)와 겹쳐 텍스트가 배경에 묻혀 "무슨 카드인지 안 보임"(사용자 피드백)이라
    // fg 비율을 70/30으로 올렸다 — "고스트 느낌"은 밴드 반투명+삽입선이 전담하고, 텍스트는 거의 정상 밝기로 읽힌다.
    if (self.sidebar_drag_preview) |dp| {
        if (dp.ghost_hi > dp.ghost_lo) {
            const f = self.appearance.theme.sidebar_foreground;
            const b = self.appearance.theme.background;
            const ghost_fg: terminal.Color = .{
                .rgb = .{ // 70% fg / 30% bg — 텍스트 가독성 확보(밴드 반투명이 고스트 신호를 전담)
                    .r = @intCast((@as(u32, f.r) * 70 + @as(u32, b.r) * 30) / 100),
                    .g = @intCast((@as(u32, f.g) * 70 + @as(u32, b.g) * 30) / 100),
                    .b = @intCast((@as(u32, f.b) * 70 + @as(u32, b.b) * 30) / 100),
                },
            };
            for (draw_list.cells) |*c| {
                const slot = c.row / coretext_frame_builder.sidebar_line_base;
                if (slot >= dp.ghost_lo and slot < dp.ghost_hi) c.style.foreground = ghost_fg;
            }
        }
    }
    return draw_list;
}

/// 사이드바 **카드 glyph 셀**의 세로 위치(py_top)를 Zig에서 `rowTop` 기반으로 완전 계산해 각 셀 `origin_y`에 싣는다
/// (docs/sidebar-groups.md §10 옵션2 — SG3b-2-ii-(b)+(d)). .m 렌더러는 옛 `slot_idx*slot_h + 블록중앙` 균일 기하 대신
/// 이 origin_y에 헤더 시프트·스크롤만 더한다(maru_metal_renderer.m 사이드바 카드 glyph 분기). 그룹 헤더(높이
/// header_row_h<slot_h)가 앞서면 카드 glyph가 헤더 높이만큼 위로 어긋나던 버그(code-review #1·#5·#6)를 닫고,
/// renameCaretRect의 `(slot_h -| line*ch)/2` 정수 블록중앙과 자동 정합한다(caret·⌘배지 정합). origin_y는 **content
/// 상대**(헤더·스크롤 제외, ≥0)라 스크롤만 바뀌는 프레임엔 재계산이 필요 없다(.m이 live로 header−scroll 적용 — 밴드와
/// 같은 단일 스크롤 소스). slot=압축 카드 서수(sidebarGlyphRow 인코딩과 동일 도메인). 밴드/배경 셀(slot_id==0)은
/// 손대지 않는다(그 경로는 row 인덱스·별도 기하). replace/replaceSidebar 직후 metal_buffer.sidebar_cells에 in-place 적용.
pub fn applySidebarGlyphPyTop(self: *AppSession) void {
    fillSidebarGlyphPyTop(self.allocator, self.metal_buffer.sidebar_cells, sidebarRenderRows(self), sidebarMetrics(self));
}

/// 사이드바 카드 줄의 세로 **스텝**(줄 top-to-top, px) = cell_height + 여유(≈0.15×ch). 예전엔 줄이 딱 ch 간격으로
/// 붙어 촘촘했다(사용자 요청 "line-height 여유"). fillSidebarGlyphPyTop(줄 배치)·renameCaretRect(caret y)가 이 한
/// 곳을 공유해 caret과 그려진 줄이 어긋나지 않는다. ch로 두면(여유 0) 옛 동작과 동일.
pub fn sidebarLineStep(ch: u32) u32 {
    return chrome.components.sidebar.lineStep(ch); // 줄 기하 단일 출처는 chrome(높이 계산이 거기서 난다)
}

/// (테스트) 표시 row의 화면 y **중앙**. 카드 높이가 줄 수에 따라 달라지므로 테스트가 `sidebar_slot_height_px`를
/// 곱해 좌표를 만들면 카드 밖(아래)을 가리킨다 — 실제 `rowTop`/`rowHeight`로 계산해야 "보이는 곳"을 누른다.
pub fn testSidebarRowCenterY(self: *AppSession, row: usize) f64 {
    const rows = self.sidebar_rows.items;
    const m = sidebarMetrics(self);
    const top = chrome.components.sidebar.rowTop(rows, row, self.sidebar_header_height_px, m, self.sidebar_scroll_offset_px);
    const h: u32 = if (row < rows.len) chrome.components.sidebar.rowHeight(rows[row], m) else chrome.components.sidebar.cardHeight(1, m);
    return @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(h)) / 2.0;
}

/// 이 세션의 사이드바 세로 레이아웃 메트릭(카드 높이는 줄 수에서 나온다 — docs/sidebar-agent-list.md §3).
/// hit-test·밴드·glyph 배치가 **같은 값**을 쓰도록 여기 한 곳에서만 만든다.
pub fn sidebarMetrics(self: *const AppSession) chrome.components.sidebar.Metrics {
    return self.sidebar_metrics;
}

/// `line_count` 줄이 차지하는 블록 높이(px) = (line_count-1)×step + ch(마지막 줄 뒤엔 여유 없음). 슬롯 안 블록중앙
/// 정렬에 쓴다. step=ch면 옛 `line_count×ch`와 같아 회귀 없음.
pub fn sidebarBlockHeight(line_count: u32, ch: u32) u32 {
    return chrome.components.sidebar.blockHeight(line_count, .init(ch, 0)); // header_row_h는 블록 높이와 무관
}

/// (순수) 사이드바 glyph 셀(카드 + 그룹 헤더)의 origin_y를 **content-상대 rowTop py**로 채운다 — applySidebarGlyphPyTop의
/// headless-테스트 가능한 코어(self 없이 rows·메트릭만). slot=**표시 row 인덱스**(sidebarGlyphRow 인코딩; SG3c에서 헤더도
/// slot을 차지해 카드·헤더 통일 도메인). content_tops는 **모든 row**(카드·헤더)에 한 엔트리씩 = Σ(앞선 row 높이;
/// 카드=slot_h·헤더=header_row_h) — rowTop의 헤더·스크롤 제외분. 블록중앙은 그 row 높이(rowHeight; 헤더=header_row_h·
/// 카드=slot_h)로 잡아 헤더 한 줄이 얇은 밴드 안에서 세로 중앙에 온다. 밴드/배경 셀(slot_id==0)은 손대지 않는다(row 인덱스·별도 기하).
pub fn fillSidebarGlyphPyTop(allocator: std.mem.Allocator, cells: []metal_frame.NativeMetalCell, rows: []const chrome.components.sidebar.Row, m: chrome.components.sidebar.Metrics) void {
    // 규칙은 **중립이 소유한다**(`sidebar_glyph_rows.fillOriginY`) — 접는 쪽(`sidebarGlyphRow`)과
    // 한 파일에 있어야 갈리지 않고, Windows 사이드바도 같은 것을 쓴다.
    maru.sidebar_glyph_rows.fillOriginY(allocator, cells, rows, m);
}

/// 사이드바 상단 헤더 glyph(검색 placeholder + view options ⚙·새 워크스페이스 + 아이콘) frame을 만든다.
/// 카드(buildSidebarTitleFrame)와 달리 절대 좌표라 .m 헤더 시프트 대상이 아니다 — replace가 origin(0,0)
/// 기반 cells로 헤더 영역 [0, header)에 직접 박는다(카드·밴드는 .m이 header_h만큼 아래로 시프트). 폭이 너무
/// 좁거나 헤더 없으면 null(헤더 안 그림). 아이콘 우측 정렬(⚙=cols-4, +=cols-2)은 sidebar.headerHit과 같은
/// 레이아웃 — 그려진 아이콘과 클릭 영역이 일치한다(§5.4 단일 레이아웃 소스). 검색 입력 텍스트·caret은 P3.
/// 알림 종(🔔) + 안 읽은 개수 배지를 row 0의 `bell_col`에 추가한다 — 펼침 헤더(buildSidebarHeaderDrawList)와 접힘 토글
/// (buildCollapsedToggleDrawList)의 **단일 출처**라 글리프(U+1F514, EAW 2칸)·배지 색(coral)·"9+" 규칙이 두 곳에서
/// 드리프트하지 않는다. 배지는 안 읽은 알림이 있을 때만 종 한 칸 왼쪽부터: 1~9는 숫자 1칸(`bell_col-1`), 10개 이상은
/// "9+" 2칸(`bell_col-2`·`bell_col-1`). 종 색은 fg(sidebar_foreground), 배지는 coral. 호출처가 폭을 보장해
/// (펼침 cols≥13 → bell_col=cols-11≥2, 접힘 bell_col≥5) `bell_col-2` saturating은 실제로 안 닿는다(방어).
/// 종과 배지 — **정의는 공유 모듈이 소유한다**(`cell_text.appendSidebarBellAndBadge`). 여기는
/// `AppSession` 에서 안 읽은 수를 꺼내 넘기는 껍질이다. 빨강 원 quad 는 `appendNotificationBadge` 가
/// 따로 그린다(표면마다 경로가 다르다).
pub fn appendBellAndBadge(self: *AppSession, cells: *std.ArrayList(renderer.DrawCell), bell_col: u16, fg: terminal.Color, round_badge: bool) !void {
    try cell_text.appendSidebarBellAndBadge(self.allocator, cells, bell_col, fg, self.notification_unread, round_badge);
}

/// 사이드바 헤더 glyph의 DrawList(접힘이면 좌상단 토글 — buildCollapsedToggleDrawList 위임; 조건 미달이면 null).
/// 멀티 페인 통합(collectShaped)이 직접 써 통합 placeMultiPane으로 한 atlas 세대에 묶는다.
pub fn buildSidebarHeaderDrawList(self: *AppSession, part: HeaderPart) !?renderer.DrawList {
    const cw = self.cell_width_px;
    if (cw == 0 or self.cell_height_px == 0) return null;
    // Deferred recovery는 의도적으로 tab/PTY를 하나도 만들지 않은 채 첫 제품 chrome을 그린다.
    // 일반 empty session에는 header를 새로 열지 않고, 실제 recovery row가 있는 0-tab chooser에만
    // 정상 sidebar affordance를 허용한다.
    if (self.tabs.items.len == 0 and self.recoveredSessionsRows(self.is_primary_window).len == 0) return null;
    // 접힘이면 헤더 대신 좌상단 펼치기 버튼만 — 사이드바 폭 0이라 터미널 좌상단에 겹쳐 그린다(replace가 커서 suffix
    // '앞'에 끼워 터미널 위에 보임). 헤더 높이·검색·카드는 없다(완전히 숨김 + 좌상단 버튼).
    // 접힘은 아이콘 파트가 대표해서 낸다 — 검색 줄이 없으므로 search 파트는 아무것도 내지 않는다(두 번 내면
    // 같은 토글이 두 frame으로 겹쳐 그려진다).
    if (self.sidebar_collapsed) return if (part == .icons) buildCollapsedToggleDrawList(self) else null;
    if (self.sidebar_header_height_px == 0) return null;
    const cols: u16 = @intCast(@min(self.sidebar_width_px / cw, @as(u32, std.math.maxInt(u16))));
    if (cols < 13) return null; // 검색 줄 + 우측 아이콘 4개(종/◧/⚙/+, 각 3칸 간격)가 들어갈 최소 폭(headerHit cols<13과 정합)

    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(self.allocator);
    const muted: terminal.Color = .{ .rgb = self.mutedForeground() };
    const fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    // 헤더: 줄0(신호등 줄)은 좌측 네이티브 신호등(닫기·최소화·확대) 영역을 비우고 우측에 사이드바 접기(◧)·view
    // options(⚙)·새 워크스페이스(+) 아이콘. 검색 줄에는 🔍만 셀로 남고 입력/placeholder/caret은 measured 경로가
    // 그린다(`collectSidebarSearchText`). 두 파트 모두 자기 frame의 **첫 줄**이다. 검색 줄의 세로 위치는 셀 row가 아니라 frame origin
    // (sidebarSearchGlyphOriginY — 상단 바 밴드 중앙)이 정한다.
    const search_row: u16 = 0;
    // 줄0: 우측 아이콘 3개 — 사이드바 접기(◧ cols-8)·view options(⚙ cols-5)·새 워크스페이스(+ cols-2). 3칸 간격,
    // 우측 1칸 패딩(cols-1 비움). 아이콘이 ~1.7칸 폭이라 2칸 간격이면 서로 붙어 보여(사용자 피드백) 3칸으로 띄운다.
    // headerHit의 toggle/view_options/new_workspace zone과 같은 col(단일 레이아웃 소스).
    // 아이콘 색은 호버 여부와 무관하게 항상 sidebar_foreground다 — hover 강조는 아래 호버 배경 quad(밝은 반투명)가
    // 맡는다. 예전엔 호버 아이콘을 sidebar_active로 재색칠했는데, Ghostty 테마에선 sidebar_active가 밝은 전경색이
    // 아니라 어두운 밴드색이라 아이콘이 오히려 어두워졌다(사용자 피드백) — 재색칠을 제거한다.
    // 알림 종(글리프 좌단 col cols-12, EAW 2칸이라 cols-12·cols-11 점유, 렌더 -0.5 nudge로 중심 (cols-11.5)*cw) + 종 우상단
    // 원형 배지(흰 숫자 cols-10 + 빨강 원 quad는 appendNotificationBadge). 종을 cols-12에 둬 배지(cols-10)와 ◧(cols-8)
    // 사이에 cols-9 한 칸 간격을 둔다 — ◧가 1.7×라 cols-9로 번져, 배지를 cols-9에 두면 ◧에 닿던 것을 떼기 위함(사용자 피드백).
    // headerHit의 notifications zone(cols-12..cols-9)이 종 글리프(cols-12·cols-11)와 배지(cols-10)를 모두 포함한다(클릭→패널).
    // 종 글리프는 🔔(U+1F514) — 🔍(검색)과 같은 이모지 경로(CoreText fallback). 글리프·색·배지 규칙은 appendBellAndBadge가
    // 접힘 토글과 공유(접힘은 좌측 텍스트 배지 — round_badge=false). 1~9 숫자·10+ "9" cap은 원형 1칸 제약(docs §3).
    // 아이콘 glyph col은 sidebar.headerIconCol 단일 출처(배지·hit-test와 공유 — 종은 2칸 이모지라 별도 cols-12).
    if (part == .icons) {
        // **공유 모듈이 그린다** — 종·◧·⚙·＋ 의 열과 배지 규칙은 `cell_text` 가 단일 출처로 소유한다.
        _ = try cell_text.appendSidebarHeaderIcons(self.allocator, &cells, cols, fg, self.notification_unread);
        return renderer.DrawList{
            .size = .{ .cols = cols, .rows = 1 },
            .cursor = .{ .row = 0, .col = 0 },
            .dirty = null,
            .cells = try cells.toOwnedSlice(self.allocator),
            .overlays = try self.allocator.alloc(renderer.DrawOverlay, 0),
        };
    }
    // 검색 줄: 🔍(EAW 2칸) + 입력 텍스트(query+preedit, EAW 한글 2칸), 비면 placeholder "Search"(muted).
    // 검색어는 blur(비활성)돼도 보존해 그대로 그린다 — 다시 클릭해 이어서 편집·필터(초안 보존). preedit은 활성일
    // 때만 존재. caret/IME 후보창은 sidebarSearchCaretRect가 잡는다(활성일 때만).
    try cells.append(self.allocator, .{ .row = search_row, .col = sidebar_search_icon_col, .codepoint = icons.codepoint(.search), .width = 2, .style = .{ .foreground = muted } });
    // 검색어·placeholder·caret은 **셀이 아니라 measured 경로**로 그린다(`collectSidebarSearchText`).
    // 🔍만 셀에 남는 이유는 등록 PUA 합성 아이콘이라 셀 슬롯에 꽉 차게 그려지는 편이 정확하기 때문이다 —
    // measured로 옮겨야 하는 것은 **폰트 크기가 바 밴드를 넘치는** 텍스트 쪽이다(docs/file-explorer.md §3.5).
    return renderer.DrawList{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .cells = try cells.toOwnedSlice(self.allocator),
        .overlays = try self.allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 검색 줄 텍스트가 놓이는 사각형(사이드바 내부 상대 px). 렌더·caret·IME 후보창이 공유하는 단일 출처다.
/// 세로는 상단 바 밴드 안에서 **role line box** 기준 중앙이다 — 셀 높이가 아니라 role 토큰(pt)에서 나오므로
/// 폰트를 키워도 밴드를 넘치지 않는다(이 이관의 목적).
pub fn sidebarSearchTextRect(self: *const AppSession) ?chrome.draw.Rect {
    const cw = self.cell_width_px;
    if (cw == 0 or self.sidebar_header_height_px == 0) return null;
    const cols = self.sidebar_width_px / cw;
    if (cols < 13) return null; // 헤더가 안 그려지는 폭(buildSidebarHeaderDrawList와 정합)
    const max_col = cols -| 4; // 우측 아이콘 영역 침범 방지(셀 경로와 같은 여백 규칙)
    if (max_col <= sidebar_search_text_col) return null;
    const x = @as(u32, sidebar_search_text_col) * cw;
    const w = (max_col - sidebar_search_text_col) * cw;
    const bar = self.chromeBarHeightPx();
    const line_h = chrome.ui.typography.lineHeightPx(.control, self.scale_milli);
    const y = sidebarSearchBandTopPx(self) +| (if (bar > line_h) (bar - line_h) / 2 else 0);
    return .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(line_h) };
}

/// 검색 줄에 그릴 문자열을 한 버퍼로 합친다(owned). query + IME preedit + caret을 **한 run**으로 두는 이유는
/// 셋을 따로 lower하면 각자 자기 원점에서 다시 시작해 겹치기 때문이다(Session Dock 검색과 같은 처방).
/// caret이 문자열 **끝**에 오므로, 넘칠 때 앞을 자르는 `.tail` 앵커면 방금 친 글자와 caret이 항상 남는다.
/// 빈 검색 + 비활성이면 placeholder를 돌려주고 `muted`를 true로 준다.
pub fn sidebarSearchTextAlloc(self: *AppSession, muted: *bool) ?[]u8 {
    const has_text = self.sidebar_search_input.query.items.len > 0 or self.sidebar_search_input.preedit.items.len > 0;
    const show_caret = self.sidebar_search_active and self.blink_visible;
    if (!has_text) {
        if (show_caret) {
            muted.* = false;
            return self.allocator.dupe(u8, "|") catch null;
        }
        if (self.sidebar_search_active) return null; // 활성 + 빈 검색 + blink off 위상 = 아무것도 안 그린다
        muted.* = true;
        return self.allocator.dupe(u8, "Search") catch null;
    }
    muted.* = false;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(self.allocator, self.sidebar_search_input.query.items) catch return null;
    out.appendSlice(self.allocator, self.sidebar_search_input.preedit.items) catch {
        out.deinit(self.allocator);
        return null;
    };
    if (show_caret) out.append(self.allocator, '|') catch {
        out.deinit(self.allocator);
        return null;
    };
    return out.toOwnedSlice(self.allocator) catch null;
}

/// 사이드바 검색 줄 텍스트를 measured 경로로 수집한다. 캐시가 hit이면 CoreText를 아예 부르지 않는다 —
/// 이 함수는 `rebuildSidebar`가 아니라 프레임 조립에서 불리지만, 사이드바는 hover·드래그마다 다시 그려지므로
/// 캐시가 없으면 그 이벤트마다 셰이핑이 돈다(docs/file-explorer.md §3.5의 이관 선행 조건).
pub fn collectSidebarSearchText(
    self: *AppSession,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
) void {
    if (self.sidebar_collapsed) return;
    const rect = sidebarSearchTextRect(self) orelse return;
    var muted = false;
    const text = sidebarSearchTextAlloc(self, &muted) orelse return;
    defer self.allocator.free(text);

    const tokens = self.buildChromeTokens();
    const runs = [_]chrome.draw.Run{.{ .text = text }};
    const ops = [_]chrome.draw.Op{.{
        .text = .{
            .origin = .{ .x = rect.x, .y = rect.y },
            .runs = &runs,
            .role = if (muted) .muted_fg else .surface_fg,
            .text_role = .control,
            .max_width_px = rect.w,
            // 넘치면 **앞**을 자른다 — caret과 방금 친 글자가 끝에 있다.
            .anchor = .tail,
        },
    }};
    const cols: u16 = @intCast(@min(self.sidebar_width_px / @max(self.cell_width_px, 1), @as(u32, std.math.maxInt(u16))));
    const fingerprint = chrome_draw_lowering.richTextFingerprint(&ops, &tokens, self.cell_width_px, self.cell_height_px, cols, 1, 0);
    if (!MeasuredTextCache.hit(self.sidebar_search_text_cache, fingerprint)) {
        var request = chrome_system_text.prepareRequest(self.allocator, fingerprint, &ops, &tokens, self.cell_width_px, .{
            .family = self.appearance.font.family,
            .fallback = self.appearance.font.fallback,
        }) catch return;
        defer request.deinit(self.allocator);
        var unresolved = chrome_system_text.shapeRequest(self.allocator, &request, self.scale_milli) catch return;
        defer unresolved.deinit(self.allocator);
        const artifact = chrome_system_text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
        MeasuredTextCache.store(&self.sidebar_search_text_cache, self.allocator, fingerprint, artifact, 0);
    }
    if (self.sidebar_search_text_cache) |*cache| {
        const dl = chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return;
        // 뷰포트 `null` 은 **고른 답이다** — 이 글자는 스크롤 목록이 아니라 고정 밴드에 앉는다(위 규약).
        self.collectMeasuredTextFromCache(collected, dl, cache, builder, null, .{ .sidebar_search = .{
            .origin_x = 0,
            .origin_y = 0,
            .colors = .{ .default_fg = self.appearance.theme.foreground },
        } });
    }
}

/// 접힘 상태 좌상단 펼치기 버튼(◧)만 그린 frame — 사이드바 폭 0이라 터미널 좌상단에 겹쳐 그린다(replace가 커서
/// suffix 앞에 끼워 터미널 '위'에). 신호등 오른쪽 col(collapsedToggleCol) 줄0에 1글자. 헤더 frame과 같은 절대 좌표 경로.
pub fn buildCollapsedToggleDrawList(self: *AppSession) !?renderer.DrawList {
    const cw = self.cell_width_px;
    if (cw == 0 or self.cell_height_px == 0 or self.tabs.items.len == 0) return null;
    const fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    const btn_col = self.collapsedToggleCol();
    const bell_col = notification_ops.collapsedBellCol(self);
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(self.allocator);
    // 좌→우: 종+배지(가장 왼쪽, 펼침 헤더와 같은 순서) → ◧ 펼치기 토글. 알림 종은 접힘에도 유지 — 펼침 헤더와 같은
    // 글리프/색/"9+" 규칙(appendBellAndBadge 단일 출처). 렌더러가 접힘 헤더 줄0 글리프(종·배지·◧)를 타이틀바 띠
    // 세로 중앙에 함께 정렬한다(terminal_origin_x_px==0 분기).
    try appendBellAndBadge(self, &cells, bell_col, fg, false); // 접힘: 종 좌측 텍스트 배지(터미널 위라 quad 부적합)
    try cells.append(self.allocator, .{ .row = 0, .col = btn_col, .codepoint = sidebar_toggle_codepoint, .style = .{ .foreground = fg } });
    return renderer.DrawList{
        .size = .{ .cols = btn_col + 2, .rows = 1 }, // ◧(가장 오른쪽, 1칸) + 여유 1칸
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .cells = try cells.toOwnedSlice(self.allocator),
        .overlays = try self.allocator.alloc(renderer.DrawOverlay, 0),
    };
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub const sidebar_min_pt: u32 = 120; // 너무 좁으면 제목/✕가 안 보임

// 사이드바 접기/펼치기 토글 아이콘 코드포인트(등록 PUA `sidebar_collapse` — 좌측 절반 채운 사각형 = 왼쪽 패널, 옛 ◧ U+25E7 대체). 헤더 아이콘 줄(펼침)·
// 접힘 시 좌상단 버튼·.m 확대 분기가 공유하는 단일 출처.
/// maru 아이콘 PUA(icon_glyph): sidebar-collapse(◧ 대체). 헤더·접힘 토글 공유.
/// **정의는 공유 모듈**(`cell_text`) — Windows 헤더가 같은 글리프를 쓴다.
pub const sidebar_toggle_codepoint: u21 = cell_text.sidebar_toggle_codepoint;

pub const sidebar_search_text_col: u16 = sidebar_search_icon_col + 3; // 🔍(2칸)+공백(1) 뒤 = 입력/caret 시작 col(=4)

/// 사이드바 스크롤바 치수(SV4a). 도크 목록과 **같은 값**을 쓴다 — 한 창에 두 스크롤바가 나란히 서므로
/// 굵기가 다르면 그 자체가 결함으로 보인다. 별도 상수로 두는 것은 사이드바 폭이 사용자 드래그로
/// 변하는 값이라 나중에 갈릴 여지를 남겨 두기 위해서다.
pub const sidebar_scrollbar_width_px: u32 = dock_list_scrollbar_width_px;

pub const sidebar_scrollbar_inset_px: u32 = dock_list_scrollbar_inset_px;

pub const sidebar_scrollbar_min_thumb_px: u32 = dock_list_scrollbar_min_thumb_px;

/// 사이드바가 내는 tree의 노드 id. 도크 목록과 **다른 값**이어야 한다 — 둘은 동시에 발행돼 있고,
/// id가 겹치면 hit-test·capture가 어느 스크롤바인지 구분하지 못한다.
pub const sidebar_scroll_ids = struct {
    pub const area: chrome.ui.tree.UiId = 0x5342_0001;
    pub const track: chrome.ui.tree.UiId = 0x5342_0002;
    pub const thumb: chrome.ui.tree.UiId = 0x5342_0003;
};

/// 카드 폴더줄(owned) = 폴더 아이콘(0xF000A) prefix + 순수 cwd(sidebarCwdPath). 브랜치줄 octocat(0xF0009)과 같은
/// "아이콘 + 공백 + 텍스트" 조립 패턴 — 표현(아이콘)은 카드 조립부에, 경로 파생은 sidebarCwdPath에 둔다. cwd 비면 "".
pub fn sidebarFolderLine(self: *AppSession, term: *Term) ![]const u8 {
    const allocator = self.allocator;
    const path = try sidebarCwdPath(self, term);
    defer allocator.free(path);
    if (path.len == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, icons.utf8(.folder) ++ " {s}", .{path});
}

/// 0xRRGGBB(카드별 프리셋 색 등) + alpha를 GpuQuad 색 워드(0xAARRGGBB, straight-alpha — 셰이더가 rgb*=a)로 패킹.
/// packRgbAlpha(Rgb)의 u32-입력 버전 — 사이드바 배경 tint·좌측 막대가 임의 프리셋 RGB를 담을 때 공유(0x00FF_FFFF 마스크 단일 출처).
pub fn packStraightRgbU32(rgb: u32, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (rgb & 0x00FF_FFFF);
}

/// 사이드바 하이라이트/색 밴드 셀 1개를 만든다(못 만들면 null). 사이드바 폭을 cell 폭으로 floor해 칸 수
/// (sidebar_cols)를 구하고 — 밴드가 origin_x를 넘어 터미널 영역을 침범하지 않게 floor한다(우측에 한 칸
/// 미만 여백이 살짝 inset처럼 남는다) — 그 폭만큼 한 칸(col 0, width=sidebar_cols)으로 사이드바를 채우는
/// sentinel-UV(-1) 배경 셀을 만든다. u16 width 상한도 같이 막는다. **가변 높이(code-review #7)**: 세로 위치는
/// `origin_y`(content-상대 rowTop = 헤더·스크롤 제외)로, 높이는 `height`(카드=slot_h·그룹 헤더=header_row_h)로
/// 실어 준다 — .m 렌더러가 옛 균일 `row*slot_h`/`slot_h` 대신 이 둘을 써 그룹 헤더(얇은 한 줄)와 정합한다(glyph 옵션2와
/// 동형). height는 glyph 없는 sentinel 셀이라 미사용인 `atlas_height_px` 필드로 나른다(atlas 미참조라 안전). `row`는
/// tint 역매핑·디버그용 표시 row(세로 위치는 origin_y가 단일 출처). 순수 함수라 OS와 무관하게 단위 테스트한다
/// per-tab 배경색(우클릭 "배경: …") tint 세기 — rich gpu_quad·tui 밴드 두 경로 단일 출처. 0xB0 ≈ 69%
/// (0x66 ≈ 40%에서 올림 — 옅어서 안 보인다는 라이브 요청). 0=투명, 0xFF=완전 불투명.
pub const tab_bg_tint_alpha: u8 = 0xB0;

/// 이퀄라이저 바 개수 = 위상 테이블 길이(단일 출처 — 둘이 어긋나 spinnerBarCp가 OOB 나지 않게 파생, code-review high 후속).
pub const spinner_bar_count: usize = spinner_bar_phase.len;

/// 프레임 f, 바 c의 블록 codepoint(▁~█). 높이 h(1~8) → base+h(▁=U+2581 … █=U+2588). frame은 이미 wave 길이로 wrap됨.
pub fn spinnerBarCp(frame: u8, bar: usize) u21 {
    const h = spinner_wave[(@as(usize, frame) + spinner_bar_phase[bar]) % spinner_wave.len];
    return spinner_block_base + @as(u21, h);
}

/// codepoint가 스피너 바 글리프(블록 ▁~█)인가 — 색칠 루프 게이트(상태줄 row로 좁힌 뒤 이 체크). 범위는 emit(spinnerBarCp)이
/// 내는 [base+1, base+max(wave)]와 **자동으로** 일치한다(wave 높이가 바뀌어도 게이트가 따라감 — 단일 출처, code-review high 후속).
pub fn isAgentSpinnerCp(cp: u21) bool {
    const max_h = comptime std.mem.max(u8, &spinner_wave);
    return cp > spinner_block_base and cp <= spinner_block_base + @as(u21, max_h);
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// 검색 줄 레이아웃 — 렌더(buildSidebarHeaderDrawList)·caret(sidebarSearchCaretRect)가 공유하는 단일 출처. 🔍를 왼쪽
// 끝(col 0)에 붙이지 않고 좌측 패딩 1칸을 둔다(사용자 피드백: 너무 붙음). 입력/placeholder/caret은 🔍(2칸)+공백(1) 뒤.
pub const sidebar_search_icon_col: u16 = 1; // 🔍 좌측 패딩 1칸

/// 각 바의 위상 offset(파형 길이 14 위, 간격 4·4·4·2) — 바마다 파형을 다른 지점에서 읽어 시차를 두고 오르내린다. 삼각 파형이라
/// 프레임에 따라 인접 두 바가 같은 높이로 겹치는 순간도 있지만(자연스러운 마루/골) 전체적으로 파도처럼 흐른다. 바 개수는 이 길이가 단일 출처.
pub const spinner_bar_phase = [_]u8{ 0, 4, 8, 12 };

/// 블록 글리프 베이스 codepoint(U+2580). 높이 h(1~8)를 더하면 ▁(U+2581)~█(U+2588). emit(sidebar_ops.spinnerBarCp)·색칠 게이트(sidebar_ops.isAgentSpinnerCp)의 단일 출처.
pub const spinner_block_base: u21 = 0x2580;

// --- 호출 그래프로 소유가 확인돼 옮겨 온 함수 ---
// 이름에 도메인 단어가 없어 F 시리즈가 못 잡았고, 이 그룹을 과반으로 부르며 만지는 상태도 이 그룹이다.

/// **(A) 카드 드래그 한 프레임의 드롭 plan을 커서 y(backing px)에서 산출한다 — mouse 핸들러와 헤드리스 테스트의 단일
/// 출처**(y_px→raw_row→plan 실경로). 두 단계로 판정한다:
///  1. **"그룹 뒤 top_level 탈출"(sidebarCardDropAfterGroup)** — 드래그 소스 카드가 프리뷰에서 자기 자리를 비워 그 아래
///     콘텐츠가 소스 높이만큼 위로 밀리는 **프리뷰 시프트**를 보정한 `y_esc`로 판정한다. hit-test는 불변 원본 sidebar_rows
///     (소스가 아직 자기 자리에 있음)로 하는데 사용자는 소스가 빠진 프리뷰를 보므로, 보정 없이는 "사용자가 그룹 꼬리를
///     겨냥해도 원본 좌표론 멤버 행 중앙에 떨어져 흡수"됐다(증상 A). 소스가 raw_row **위**면(드래그 다운) y에 소스 행 높이를
///     더해, 프리뷰의 그룹 꼬리를 겨냥한 커서가 원본 마지막 멤버의 하단 경계(탈출 존)에 맞게 한다.
///  2. **일반 위치 판정(sidebarGroupDropTargetTab + sidebarCardDropTopLevel)** — 보정 **없는** raw_row로. moveTab의 from/to가
///     소스 제거를 이미 보정하므로 여기에 시프트를 더하면 이중 보정으로 flat 재정렬이 어긋난다(그래서 탈출 판정에만 보정).
/// 유효 드롭 없음(범위 밖·마커)이면 .none(제자리 프리뷰). MARU_DEBUG면 실값(raw_row·y_esc·gap·top_level)을 로깅해
/// 실앱 드래그에서 왜 흡수(top_level=false)인지 자기검증한다(관측 가능성 — diag.zig 단일 게이트).
pub fn cardDropPlan(self: *AppSession, origin: usize, y_px: f64) DropPlan {
    const rows = self.sidebar_rows.items;
    // 목록 행에 떨어졌으면 **소속 카드 row로 접는다** — 목록은 카드의 부속이라 그 위 드롭은 "그 워크스페이스에
    // 떨어뜨렸다"가 자연스럽고, 접지 않으면 목록 높이만큼이 드롭 사각지대가 된다(code-review max).
    const raw_row = sidebarCardRowFor(self, chrome.components.sidebar.dragTargetSlot(y_px, self.sidebar_header_height_px, rows, sidebarMetrics(self), self.sidebar_scroll_offset_px));
    // 프리뷰 시프트 보정: 소스 카드 행이 raw_row **위**면(드래그 다운) 프리뷰가 그 아래 콘텐츠를 소스 높이만큼 위로 당긴다.
    // **카드 + 그 에이전트 목록 행 전체**가 함께 들리므로(projectRowsCore가 묶음으로 옮긴다) 그 합만큼 보정해야
    // 한다 — 카드 높이만 더하면 목록이 있는 워크스페이스에서 보정이 모자라 그룹 탈출 판정이 어긋난다(code-review max).
    var y_esc = y_px;
    if (self.displaySlotOf(origin)) |os| if (os < raw_row) {
        // 들리는 높이 = 카드 span 높이. **누적을 여기서 다시 굴리지 않는다** — 밴드·tint·accent 막대가 쓰는
        // `cardSpanEnd`+`spanRect`와 같은 함수를 부른다(docs/sidebar-agent-list.md §3.3). 예전엔 이 자리에
        // 같은 while 누적 사본이 남아 있어, span 소속 규칙이 바뀌면 렌더는 따라오는데 이 보정만 안 따라와
        // 그룹 탈출 판정이 어긋났다(code-review max — 같은 계열 회귀를 이미 한 번 겪은 자리다).
        const span = chrome.components.sidebar.spanRect(rows, os, chrome.components.sidebar.cardSpanEnd(rows, os), self.sidebar_width_px, sidebarMetrics(self));
        y_esc = y_px + @as(f64, @floatFromInt(span.h));
    };
    // y_esc가 y_px와 같으면(드래그 업/동일 슬롯 — os >= raw_row라 보정이 없음) dragTargetSlot 결과도 raw_row와 동일하므로
    // 재계산을 건너뛰고 재사용한다(code-review 효율 — 드래그 다운일 때만 재계산). 부동소수 == 비교라도 보정을 안 한 경로면
    // 두 값이 **같은 리터럴**(y_esc = y_px 대입)이라 정확히 같다.
    const raw_esc = if (y_esc != y_px)
        sidebarCardRowFor(self, chrome.components.sidebar.dragTargetSlot(y_esc, self.sidebar_header_height_px, rows, sidebarMetrics(self), self.sidebar_scroll_offset_px))
    else
        raw_row;
    // **고정(pinned) 흡수 금지(사용자 정책 — "고정된 건 어디에도 흡수 안 됨")**: 드래그 소스 카드가 pinned면 드롭 위치가
    // 그룹 한복판이어도 top_level=true를 **무조건** 낸다(위치 판정과 무관). 고정 탭은 고정 리전 안 top_level 서브파티션으로만
    // 존재해야 하므로(고정 그룹과 인터리브), 위치 기반 sidebarCardDropTopLevel(그룹 멤버=false)을 OR로 덮어 흡수를 원천 차단한다.
    // 비고정 소스는 기존 위치 판정 유지(그룹 안=멤버·밖=top_level). simulateDrop/commit도 같은 source_pinned를 OR해 프리뷰=확정.
    // (착지 위치의 고정 리전 clamp는 simulateDrop/moveTab의 clampMoveToGroup이 별도로 보장 — 고정 소스는 [0,pinned_count)에 갇힌다.)
    const source_pinned = origin < self.tabs.items.len and self.tabs.items[origin].pinned;
    const gap = sidebarCardDropAfterGroup(self, raw_esc, origin, y_esc);
    const plan: DropPlan = if (gap) |g|
        // §14.6 SR5 요구2: "그룹 뒤/사이 gap" 드롭 = 그룹 밖 top카드로 착지(top_level=true, 흡수 아님).
        .{ .card = .{ .target_tab = g.target_tab, .top_level = g.top_level or source_pinned } }
    else if (tab_ops.sidebarGroupDropTargetTab(self, raw_row, origin)) |target_tab| blk: {
        // §14.6 SR4 model-2: 착지 위치 + 드롭 컨텍스트 top_level 의도(타깃이 최상위 카드면 true·그룹 멤버면 false). 고정 소스는 강제 true.
        // **[2] 고정 탭은 그룹 안에 착지 금지(§14.9 정합 — "흡수 금지"가 "그룹 split"이 되면 안 됨)**: source_pinned가
        // 그룹 멤버 사이(subtree 한복판)에 착지하면 위 top_level 강제가 그 자리에 top_level break를 써 **뒤 멤버를 그룹에서
        // eject**(그룹 쪼갬)한다. 착지 target을 그룹 subtree **밖 경계**로 clamp해 고정 탭이 그룹 경계에만 착지하게 한다 —
        // 그러면 top_level break가 그룹 무결을 안 깬다(경계 뒤엔 자를 멤버가 없다). 방향: 소스가 그룹 **위**(origin<gm)면
        // 그룹 **뒤 끝**(ge-1, moveTab from<to가 그룹 다음 자리에 안착), 소스가 그룹 **아래/안**이면 그룹 **앞 마커**(gm,
        // from>to가 마커 앞에 안착). topLevelGroupMarkerIndex가 null(타깃이 그룹 밖 top카드)이면 clamp 없음 — 고정 top카드
        // 옆 인터리브(SR4(d))는 무변경. 비고정 소스는 이 clamp를 안 타 그룹 흡수 능력 보존.
        var tt = target_tab;
        if (source_pinned) {
            if (tab_ops.topLevelGroupMarkerIndex(self, tt)) |gm| {
                const ge = tab_ops.groupSubtreeEnd(self, gm, null, null);
                tt = if (origin < gm) ge - 1 else gm;
            }
        }
        break :blk .{ .card = .{ .target_tab = tt, .top_level = sidebarCardDropTopLevel(self, raw_row) or source_pinned } };
    } else .none;
    if (diag_gate.maruDebugEnabled()) std.log.scoped(.sidebar_card_drag).info(
        "cardDropPlan: origin={d} y={d:.1} raw_row={d} y_esc={d:.1} raw_esc={d} gap_target={?} src_pinned={} plan_top_level={}",
        .{ origin, y_px, raw_row, y_esc, raw_esc, if (gap) |g| g.target_tab else null, source_pinned, switch (plan) {
            .card => |c| c.top_level,
            else => false,
        } },
    );
    return plan;
}

/// 그룹 통째 드래그의 한 프레임(헤더 드래그·마커 카드 드래그 공통). 커서 y로 드롭 타겟 row를 **원본 sidebar_rows(불변)**로
/// hit-test하고, 라이브 tab_ops.moveGroupNesting/Sibling 커밋을 **제거**한 **비커밋 프리뷰**(SG8e — docs/plans/sidebar-groups.md §9)를
/// 재투영한다: 드롭 컨텍스트로 plan만 계산해(헤더 드롭=`.group_nest`·카드/최상위 드롭=`.group_sibling`·무효=`.none`)
/// refreshDragPreview로 subtree 고스트를 sidebar_preview_rows에 투영한다(self.tabs 불변이라 yo-yo 원천 차단). up이 이
/// 마지막 plan을 실제 move로 **정확히 1회** 커밋한다(commitSidebarDragPreview). self.tabs가 불변이라 마커 인덱스가 드래그
/// 내내 안정해 **호출자의 마커를 갱신할 필요가 없다** — SG8f: 옛 라이브 팔로우의 새-마커 추적·반환값 대입 잔재를 걷어내 void.
///
/// **중첩 vs 형제 = Cmd(⌘) modifier로 구분(사용자 확정 정책)**: `cmd_held`면 드롭 row가 **다른 그룹의 헤더**일 때 그 그룹의
/// 자식으로 **중첩**(`groupNestPlan` → `.group_nest{insert_before, target_depth}`, dragged 마커 depth=타겟 그룹 depth+1,
/// subtree 상대 depth 유지 = "폴더 안에 넣기"). `cmd_held`가 **아니면 nest를 아예 시도하지 않아**(nest=null) 헤더 드롭이라도
/// **형제 경계 이동**만 된다(중첩 절대 안 됨). 헤더가 아닌 카드/최상위 드롭은 Cmd 유무와 무관하게 **형제 경계 이동**
/// (`sidebarGroupDropBoundary` → `.group_sibling{insert_before}`)으로, 얕은 위치면 자연 eff depth로 **빼기(un-nest)**가
/// 확정 시 gap-clamp+relevel로 반영된다. (과거 SG5-4는 modifier 없이 헤더 드롭=넣기였으나, 사용자 요청으로 Cmd 게이트를 얹었다 —
/// 확정 경로 tab_ops.moveGroupNesting/Sibling과 동일 plan.)
pub fn groupDragPreviewFrame(self: *AppSession, marker: usize, y_px: f64, cmd_held: bool) void {
    const raw_row = chrome.components.sidebar.dragTargetSlot(y_px, self.sidebar_header_height_px, self.sidebar_rows.items, sidebarMetrics(self), self.sidebar_scroll_offset_px);
    // plan 판정(사용자 확정 정책): **Cmd(⌘) 눌림 = 중첩 시도(안으로 넣기)**, **Cmd 없음 = 항상 형제(중첩 절대 안 함)**.
    //  - Cmd O: 헤더 드롭이면 groupNestPlan이 `.group_nest`를 내고(그 그룹의 자식으로), 헤더가 아닌 카드/최상위 드롭이면
    //           groupNestPlan이 null이라 아래 형제 경계로 폴백한다(N4 — Cmd라도 넣을 헤더가 없으면 형제).
    //  - Cmd X: nest를 아예 시도하지 않아(nest=null) 헤더 드롭이라도 `.group_sibling`(단순 위치 변경)만 된다(N1).
    // hit-test는 원본 sidebar_rows(불변)로. Cmd 없이는 중첩이 불가능하다는 게 이 함수의 핵심 게이트다.
    const nest: ?GroupNestPlan = if (cmd_held) tab_ops.groupNestPlan(self, raw_row, marker) else null;
    const plan: DropPlan = if (nest) |np|
        .{ .group_nest = .{ .insert_before = np.insert_before, .target_depth = np.target_depth } }
    else if (sidebarGroupDropBoundary(self, raw_row, marker)) |boundary|
        // 그룹 고정 C2(§12.6 GP3): insert_before를 **plan에 굽기 전** 드래그 그룹의 pin 리전으로 clamp한다 —
        // 이동 함수(tab_ops.moveGroupRange/tab_ops.simulateGroupMove)가 아니라 여기 단일 지점이라 프리뷰=확정이 같은 clamp 값을
        // 재사용해 SG8 이중경로 divergence가 없다. (nest는 groupNestPlan이 same-pin 그룹만 내므로 이미 리전 안이다.)
        .{ .group_sibling = .{ .insert_before = self.clampGroupMoveToRegion(marker, boundary) } }
    else
        .none;
    // MARU_DEBUG 관측(관측 가능성 원칙, diag.zig 단일 게이트): 실제 앱 드래그에서 **Cmd 없이=형제 / Cmd=중첩**이 지켜지는지
    // 자기검증한다 — 헤드리스 N1~N6가 mouse(mods) 직접 시뮬로 커버하지 못하는 **Swift 드래그 경로**(mouseDragged→handleMouse→
    // modsBits→maru_macos_app_session_mouse→mouse의 cmd_held)를 실측으로 잇는 단일 로그. Cmd 없이 드래그인데 plan=group_nest면
    // Swift mods 오전달(command 비트 32 오염) 확정, plan=group_sibling이면 게이트 정상. 미설정이면 분기 하나(캐시 히트)뿐.
    if (diag_gate.maruDebugEnabled()) std.log.scoped(.group_drag).info(
        "groupDragPreviewFrame: marker={d} raw_row={d} cmd_held={} plan={s}",
        .{ marker, raw_row, cmd_held, @tagName(plan) },
    );
    // 비커밋 프리뷰 재투영(self.tabs 불변). 카드 드래그(SG8d)와 동형 — 원본-도메인 drop_slot은 프리뷰 렌더에 오강조를
    // 주므로 세팅하지 않는다(subtree 고스트+삽입선이 하이라이트를 대체). 매 프레임 재투영이라 rebuild + dirty.
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    tab_ops.refreshDragPreview(self, marker, plan, y_px, arena_state.allocator()) catch {};
    rebuildSidebar(self) catch {};
    self.metal_dirty = true;
}

/// 현재 font·scale_milli에 대한 cell 픽셀 크기(advance 폭 × line-height)를 CoreText에서
/// 뽑아 갱신한다. 분수 scale을 그대로 곱한 device 픽셀 font size로 조회한다. macOS가
/// 아니거나(테스트/CI) 조회 실패면 같은 device 픽셀 font size의 정사각으로 대체한다.
/// scale_milli가 바뀌는 resize에서도 호출한다.
pub fn refreshCellMetrics(self: *AppSession) void {
    const device_font_size = renderer.deviceFontSizeFromMilli(self.appearance.font.size, self.scale_milli);
    const square: u32 = @intFromFloat(@round(device_font_size));
    self.cell_width_px = square;
    self.cell_height_px = square;
    // extern native 호출은 macOS에서만 컴파일/링크한다(.m을 링크하지 않는 Linux 계약
    // 빌드에서 undefined symbol이 되지 않게 comptime으로 막는다).
    if (builtin.os.tag == .macos) {
        var metrics: coretext_bridge.CellMetricsResult = .{};
        coretext_bridge.maru_macos_coretext_font_cell_metrics(
            self.appearance.font.family.ptr,
            self.appearance.font.family.len,
            device_font_size,
            &metrics,
        );
        if (metrics.status == 0 and metrics.cell_width_px > 0 and metrics.cell_height_px > 0) {
            self.cell_width_px = metrics.cell_width_px;
            self.cell_height_px = metrics.cell_height_px;
            // **소수까지 남긴다.** 격자·atlas 는 위 정수 cell 을 그대로 쓰고, chrome 텍스트처럼 role 이
            // 정한 다른 크기로 그리는 소비자는 이 값으로 비율을 낸다 — 정수만 쓰면 최대 0.5px 이
            // 버려지고, 그 손실이 이어 그리는 글자를 겹치게 했다(scm_dock `measureRun`).
            self.glyph_advance_milli_px = metrics.advance_milli_px;
        }
    }
    // line-height(행간)·letter-spacing(자간) config를 적용한다 — native/fallback이 base cell 크기를 정한 '직후',
    // grid·atlas·hit-test·IME가 파생되기 '전'. **자간은 cell_width_px(grid advance=셀 배치 간격)에만 가산하고,
    // 글리프 비트맵 폭(glyph_cell_width_px=atlas slot·화면 quad 폭)은 자연폭(base) 그대로 둔다**(applyFontSpacing
    // 단일 출처). 이렇게 분리해야 음수 자간이 slot을 좁혀 일반 글자를 "셀보다 넓다"로 오판→축소+ink세로중앙(글자마다
    // 세로 흔들림)시키던 버그가 사라진다 — 글리프는 자연폭 slot에 온전히 그려지고, 좁힘은 셀 배치 step에만 반영돼
    // 이웃 글자와 겹친다(Ghostty식). line-height는 cell_height_px에 곱한다. 기본값(1.0/0.0)이면 둘 다 base.
    const spaced = applyFontSpacing(
        self.cell_width_px,
        self.cell_height_px,
        self.appearance.font.line_height,
        self.appearance.font.letter_spacing,
        self.scale_milli,
    );
    self.cell_width_px = spaced.advance_width_px;
    self.glyph_cell_width_px = spaced.glyph_width_px;
    self.cell_height_px = spaced.height_px;
    // 세로 사이드바 폭도 분수 scale에 맞춰 backing 픽셀로 환산한다(메트릭과 같은 단일 출처). 폭은 현재
    // 논리 폭(sidebar_width_pt — 사용자 드래그로 바뀔 수 있음)에서 파생하므로 DPI 변경에도 유지된다.
    // **폰트/DPI가 바뀌어 cell 폭이 커지면 헤더 아이콘 하한(sidebarMinPt)이 올라가므로**, 저장된 폭을 그 하한 이상으로
    // 끌어올린다(드래그 경로뿐 아니라 메트릭 변경 경로도 겹침 방지 — 단일 출처). 기본값 180pt가 하한 미만이 되는 큰-폰트
    // 첫 실행도 여기서 보정된다. cap(sidebar_max_pt)도 sidebarMinPt가 보장.
    self.sidebar_width_pt = std.math.clamp(self.sidebar_width_pt, sidebarMinPt(self), sidebar_max_pt);
    // minimal 세션(quick terminal)·접힘(사용자 토글)이면 사이드바 폭 0 고정(터미널이 전폭). 폭(pt)은 보존돼 펼치면 복원.
    self.sidebar_width_px = if (self.chrome_minimal or self.sidebar_collapsed) 0 else layout_math.ptToPx(self.sidebar_width_pt, self.scale_milli);
    // window padding도 같은 단일 출처(논리 pt × 분수 scale)로 backing px 환산 — DPI 변경에도 유지된다.
    // termRect/gridFromBacking이 이 px를 inset으로 쓴다(렌더 origin·hit-test·IME 자동 정합). minimal 세션도
    // 동일 적용(터미널 콘텐츠 inset이라 chrome 유무와 무관).
    self.window_padding_px = .{
        .left = layout_math.ptToPx(self.appearance.window_padding_left, self.scale_milli),
        .right = layout_math.ptToPx(self.appearance.window_padding_right, self.scale_milli),
        .top = layout_math.ptToPx(self.appearance.window_padding_top, self.scale_milli),
        .bottom = layout_math.ptToPx(self.appearance.window_padding_bottom, self.scale_milli),
    };
    // 탭 슬롯 높이 = cell 높이 × 2.5(큰 슬롯). cell_height_px가 이미 위에서 갱신됐으므로
    // 그걸 쓴다 — 슬롯 높이도 cell 메트릭과 같은 단일 출처에서 파생한다.
    self.sidebar_slot_height_px = self.cell_height_px * sidebar_slot_height_ratio_milli / 1000;
    self.sidebar_header_row_h_px = self.cell_height_px * sidebar_header_row_h_ratio_milli / 1000; // 그룹 헤더 row(얇은 한 줄; SG3b-2-ii)
    // 카드 높이는 줄 수 기반이라 cell·헤더 높이가 바뀔 때마다 함께 파생한다(줄 기하 공식은 chrome이 소유).
    self.sidebar_metrics = .init(self.cell_height_px, self.sidebar_header_row_h_px);
    // 상단 타이틀바 띠(신호등·헤더 아이콘 줄, 탭 바는 그 아래). 펼침=한 줄, 접힘=신호등 높이 확보(computeTitlebarStripPx).
    self.titlebar_strip_px = self.computeTitlebarStripPx();
    // 헤더 높이는 **띠 + 상단 바**다 — 사이드바 헤더의 두 줄이 창 오른쪽의 두 밴드(신호등 띠 / pane 탭 바·도크 뷰
    // 스위처)와 한 줄로 읽혀야 하기 때문이다(docs/file-explorer.md §3.5). 그래서 `titlebar_strip_px`·
    // `chromeBarHeightPx` 뒤에 계산한다.
    //
    // 예전에는 `cell_height × 3.0`이었고 그래서 **왼쪽만 terminal 폰트에 묶여** 있었다: 14pt에서 검색 줄 중심이
    // 45pt인데 탭 바 중심은 48pt였고, 헤더 하단 54pt와 상단 바 하단 68pt가 갈렸다. 고정 오차가 아니라 단위계
    // 불일치라 폰트를 키우면 벌어진다(24pt면 헤더만 93pt). 오른쪽 두 바가 이미 쓰던 계약에서 사이드바 헤더만
    // 빠져 있던 것이 원인이다(사용자 보고 2026-08-09).
    self.sidebar_header_height_px = sidebarHeaderHeightPx(self);
    // 사이드바 폭/cell 폭이 바뀌면 밴드의 칸 환산(sidebar_cols)도 달라지므로 다시 만든다.
    rebuildSidebar(self) catch {};
    // 폰트/DPI 변경을 활성 surface 코어에 즉시 반영(kitty 자동 크기 advance용 — renderFrame 안전망보다
    // 먼저, 변경 직후 첫 PTY 출력에서 정확하도록). surface 생성 전(init 순서)이면 surface_initialized로 가드.
    if (self.surface_initialized) {
        // Phase 3 위임(docs/plans/io-render-threading.md §9 P3-3): 폰트/DPI 변경 시 셀 메트릭을 reader로 위임한다(메인
        // 직접 mutate 없음). 모든 Term에 보내 inactive host runtime도 다음 kitty 출력 전에 새 metric을 보게 한다.
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (term.kind != .terminal) continue;
                    self.enqueueCoreCommandForTerm(term, .{ .set_cell_metrics = .{
                        .width = self.cell_width_px,
                        .height = self.cell_height_px,
                    } }) catch {};
                }
            }
        }
    }
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub const sidebar_max_pt: u32 = 480; // 너무 넓으면 터미널이 좁아짐

// 사이드바 탭 슬롯 한 칸의 높이를 cell 높이의 몇 배로 할지(천분율). 5200 = 5.2× — 최대 4줄 카드(이름·브랜치·
// 경로·상태, 각 1×cell = 4×cell)를 위아래 여백 두고 담을 큰 슬롯. 1~3줄 탭도 같은 슬롯에 블록 세로 중앙(빈 줄
// 없음). 에이전트 상태줄(4번째)을 추가하며 3.8×→4.6×로 키웠고, 4줄 카드 하단 여백이 빡빡하다는 피드백으로 4.6×→5.2×
// 로 더 키웠다(4줄 상·하 여백 각 0.3×→0.6×cell로 배증; 균일 슬롯이라 1~3줄 카드도 함께 여유가 는다). refreshCellMetrics가
// cell_height_px × 이 비율로 backing 픽셀 슬롯 높이를 구한다.
pub const sidebar_slot_height_ratio_milli: u32 = 5200;

// 그룹 헤더 row 높이 = cell 높이 × 3.0(위아래 여백 넉넉히; 카드 슬롯 5.2×보다는 얇다). 가변 높이의 헤더
// 높이(SG3b-2-ii, docs/sidebar-groups.md §5). 사용자 요청으로 1.5→3.0(위아래 높이 2배, 텍스트 크기는 불변 — glyph는 밴드 중앙).
pub const sidebar_header_row_h_ratio_milli: u32 = 3000;

/// font.line-height(배수)·font.letter-spacing(논리 pt)을 base cell px에 적용한다(refreshCellMetrics의 단일
/// 적용점이 호출하는 순수 helper — OS·CoreText 없이 곱/가산 산술을 단위 테스트로 못박는다). line-height는
/// cell_height_px에 곱하고, letter-spacing은 논리 pt를 backing px(× scale_milli/1000, padding px 환산과 동형)로
/// 바꿔 cell_width_px에 가산한다(음수 가능 → 최소 1px로 saturate해 0폭 grid를 막는다). 두 px가 grid·atlas·
/// hit-test의 진실 소스라, 여기 한 곳만 바꾸면 나머지가 자동 정합한다. 기본값(1.0/0.0)이면 입력 그대로 통과.
pub fn applyFontSpacing(
    base_width_px: u32,
    base_height_px: u32,
    line_height: f32,
    letter_spacing_pt: f32,
    scale_milli: u32,
) struct { advance_width_px: u32, glyph_width_px: u32, height_px: u32 } {
    const height_px: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_height_px)) * line_height));
    // 논리 pt → backing px(분수 scale 그대로). padding px 환산(× scale_milli / 1000)과 같은 방식.
    const spacing_px: f32 = letter_spacing_pt * @as(f32, @floatFromInt(scale_milli)) / 1000.0;
    // i64로 가산해(음수 spacing) 1px 미만이면 1로 saturate — 0폭이면 grid가 div-by-cell에서 폭주한다.
    const width_i: i64 = @as(i64, base_width_px) + @as(i64, @intFromFloat(@round(spacing_px)));
    const advance_width_px: u32 = @intCast(@max(@as(i64, 1), width_i));
    // **자간은 grid advance(셀 간격)만 바꾸고, 글리프 비트맵 폭은 자연폭(base) 그대로 둔다.** 음수 자간이 slot을
    // 좁혀 일반 글자가 "셀보다 넓다"로 오판→축소+ink세로중앙(글자마다 세로 흔들림)되던 버그를 끊는다(code-review).
    // 즉 글리프 래스터·atlas slot·화면 quad 폭 = glyph_width_px(자연), 셀 배치 step = advance_width_px(자간 반영).
    // Ghostty도 일반 텍스트를 자연 bearing으로 두고 셀폭 조정은 배치에만 적용한다(face.zig "left-aligned within the cell").
    return .{ .advance_width_px = advance_width_px, .glyph_width_px = base_width_px, .height_px = height_px };
}

/// **사이드바 검색이 열려 있을 때**의 PageUp/PageDown/Home/End — 카드 목록을 굴린다.
///
/// 도크 둘(`agent_dock`·`scm_dock`)과 같은 규율이되 **키를 언제 갖는가가 다르다.** 사이드바는 늘
/// 보이지만 그것이 소유권은 아니다 — 터미널에서 친 Page 가 카드 목록을 굴리면 안 된다. 사이드바가
/// 키를 드는 상태는 **검색이 열린 동안** 하나뿐이고(`sidebar_search_active` — 그 라우팅이
/// `handleKeyEvent` 에서 모든 키를 소비한다), 그래서 이 함수도 그 안에서만 산다.
///
/// **지금 그 넷은 삼켜지고 있다.** `handleSidebarSearchKey` 는 escape·enter·글자만 다루고 나머지를
/// `else => {}` 로 버리는데, 그 블록은 무조건 소비하고 돌아간다 — 즉 검색 중 PageDown 은 목록도 안
/// 굴리고 터미널로도 안 간다. 그래서 이 변경은 **잃는 것이 없다**(탐색기가 그 넷을 「선택 이동」으로
/// 이미 쓰고 있어 대상에서 빠진 것과 대비된다 — ScrollArea 계약 §4.5).
pub fn handleSidebarScrollKey(self: *AppSession, event: terminal.KeyEvent) bool {
    if (!self.sidebar_search_active) return false;
    if (event.modifiers.command or event.modifiers.control or event.modifiers.option or event.modifiers.shift)
        return false;
    const max_offset = sidebarMaxScroll(self);
    // 한 카드를 화면에 남긴다 — 다만 **사이드바 카드는 높이가 고정이 아니다**(이름만인 카드부터
    // 이름+브랜치+경로+상태까지, `cardHeight(lines, m)`). 그래서 «가장 작은 카드»(한 줄)를 기준으로
    // 둔다: 남는 것이 한 줄짜리면 정확히 하나, 여러 줄짜리면 그 일부다. page step 의 목적은 읽던
    // 자리를 남기는 것이므로 이 정도면 족하고, 반대로 가장 큰 카드로 재면 화면이 거의 안 넘어간다.
    const min_card_h = chrome.components.sidebar.cardHeight(1, sidebarMetrics(self));
    const step = chrome.ui.scroll_area.pageStepPx(sidebarViewport(self).height(), min_card_h);
    const next = sidebarScrollKeyOffset(event.key, self.sidebar_scroll_offset_px, step, max_offset) orelse return false;
    // `setSidebarScrollOffsetPx` 가 clamp·재빌드·metal_dirty 를 한 자리에서 한다(휠·스크롤바와 같은 문).
    setSidebarScrollOffsetPx(self, next);
    return true;
}

/// 위 핸들러의 **산술만** 떼어낸 순수 함수. 키가 스크롤 대상이 아니면 `null`(호출자가 흘려보낸다).
///
/// **왜 떼어냈나 — 상태 주입으로는 못 잰다.** `setSidebarScrollOffsetPx` 는 `rebuildSidebar` 를
/// 부르고 그것이 `recomputeVisibleTabs` 로 `sidebar_rows` 를 **실제 탭에서 다시 만든다**. 그래서
/// 테스트가 카드를 손으로 채워 스크롤 상한을 만들어도 첫 적용에서 그 행들이 사라지고 상한이 0 이
/// 되어 값이 도로 clamp 된다(적대적 검증에서 `expected 600, found 0` 으로 잡혔다). 산술을 여기 두면
/// 그 재생성과 무관하게 **값 자체**를 못 박을 수 있고, 핸들러는 게이트와 적용만 남는다.
pub fn sidebarScrollKeyOffset(key: terminal.Key, current_px: u32, step_px: u32, max_offset_px: u32) ?u32 {
    return switch (key) {
        .page_up => current_px -| step_px, // 포화 뺄셈 — 맨 위에서 더 올려도 0 아래로 안 간다
        .page_down => @intCast(@min(@as(u64, current_px) + @as(u64, step_px), @as(u64, max_offset_px))),
        .home => 0,
        .end => max_offset_px,
        else => null,
    };
}

test "사이드바 키보드 스크롤 산술: 한 카드를 남기고 · 끝으로 가고 · 0 아래로 안 간다" {
    const max: u32 = 1000;
    const step: u32 = 600;

    // PageDown 은 한 카드를 남긴 만큼 내려가고 상한에서 멈춘다.
    try std.testing.expectEqual(@as(?u32, 600), sidebarScrollKeyOffset(.page_down, 0, step, max));
    try std.testing.expectEqual(@as(?u32, 1000), sidebarScrollKeyOffset(.page_down, 600, step, max));
    try std.testing.expectEqual(@as(?u32, 1000), sidebarScrollKeyOffset(.page_down, 1000, step, max));

    // PageUp 은 **포화 뺄셈**이다 — 맨 위에서 더 올려도 0 아래로 안 간다(u32 언더플로 방지).
    try std.testing.expectEqual(@as(?u32, 400), sidebarScrollKeyOffset(.page_up, 1000, step, max));
    try std.testing.expectEqual(@as(?u32, 0), sidebarScrollKeyOffset(.page_up, 400, step, max));
    try std.testing.expectEqual(@as(?u32, 0), sidebarScrollKeyOffset(.page_up, 0, step, max));

    // Home/End 는 양 끝이다.
    try std.testing.expectEqual(@as(?u32, 0), sidebarScrollKeyOffset(.home, 700, step, max));
    try std.testing.expectEqual(@as(?u32, 1000), sidebarScrollKeyOffset(.end, 0, step, max));

    // step 이 0 이면(뷰포트가 카드보다 작다) 자리에 머문다 — 고정 chrome 치수에서 움직임을 만들지 않는다.
    try std.testing.expectEqual(@as(?u32, 300), sidebarScrollKeyOffset(.page_down, 300, 0, max));
    try std.testing.expectEqual(@as(?u32, 300), sidebarScrollKeyOffset(.page_up, 300, 0, max));

    // 스크롤 키가 아니면 null — 호출자가 그대로 흘려보낸다.
    try std.testing.expectEqual(@as(?u32, null), sidebarScrollKeyOffset(.enter, 0, step, max));
    try std.testing.expectEqual(@as(?u32, null), sidebarScrollKeyOffset(.escape, 0, step, max));
}

test "사이드바 키보드 스크롤 게이트: 검색이 열렸을 때만 · 수식키는 넘긴다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // ① **검색이 닫혀 있으면 안 잡는다.** 사이드바는 늘 보이지만 그것이 키 소유권은 아니다 —
    //    여기서 true 를 돌리면 터미널에서 친 PageDown 이 카드 목록을 굴린다.
    session.sidebar_search_active = false;
    try std.testing.expect(!handleSidebarScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    try std.testing.expect(!handleSidebarScrollKey(session, .{ .key = .end, .modifiers = .{} }));

    // ② 검색이 열리면 그 넷을 가져간다(값은 위 산술 테스트가 못 박는다 — 여기서는 소유권만).
    session.sidebar_search_active = true;
    try std.testing.expect(handleSidebarScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    try std.testing.expect(handleSidebarScrollKey(session, .{ .key = .home, .modifiers = .{} }));

    // ③ 수식키가 붙으면 넘긴다(⌘Home 등은 다른 주인이 있다). ④ 스크롤 키가 아닌 것도 흘린다.
    try std.testing.expect(!handleSidebarScrollKey(session, .{ .key = .end, .modifiers = .{ .command = true } }));
    try std.testing.expect(!handleSidebarScrollKey(session, .{ .key = .enter, .modifiers = .{} }));

    // ⑤ **제품 키 경로로도 태운다**(적대적 검증 — 변이로 확인). 위 ①~④ 는 핸들러를 직접 부르므로
    //    `handleKeyEvent` 의 라우팅 줄을 지워도 초록으로 남는다(실제로 그렇게 잡혔다). 여기서는
    //    **진짜 탭**으로 목록을 넘치게 만들어(주입한 `sidebar_rows` 는 `rebuildSidebar` →
    //    `recomputeVisibleTabs` 가 실제 탭에서 다시 만들어 지운다) 오프셋이 움직이는 것을 잰다.
    session.backing_height_px = 320; // 뷰포트를 좁혀 적은 탭으로도 넘치게 한다
    var made: usize = 0;
    while (made < 8) : (made += 1) {
        _ = try tab_ops.createTab(
            session,
            .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
            .{ .cols = 20, .rows = 5 },
            16,
            "w",
            "sh",
        );
    }
    try rebuildSidebar(session);
    const max_offset = sidebarMaxScroll(session);
    try std.testing.expect(max_offset > 0); // fixture 가 실제로 넘치는지 — 0 이면 아래가 아무것도 안 잰다

    session.sidebar_search_active = true;
    setSidebarScrollOffsetPx(session, 0);
    _ = try session.handleKeyEvent(.{ .key = .end, .modifiers = .{} });
    try std.testing.expectEqual(max_offset, session.sidebar_scroll_offset_px);
    _ = try session.handleKeyEvent(.{ .key = .home, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 0), session.sidebar_scroll_offset_px);
}
