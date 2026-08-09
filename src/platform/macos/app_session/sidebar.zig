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
const workspace_ops = @import("workspace.zig");
const settings_ops = @import("settings.zig");
const scroll_ops = @import("scroll.zig");
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const metal_frame = app_session_mod.metal_frame;
const agentBrandColor = AppSession.agentBrandColor;
const isAgentSpinnerCp = app_session_mod.isAgentSpinnerCp;
const sidebarFolderLine = app_session_mod.sidebarFolderLine;
const chrome_system_text = app_session_mod.chrome_system_text;
const packStraightRgbU32 = app_session_mod.packStraightRgbU32;
const sidebarBandCell = app_session_mod.sidebarBandCell;
const sidebar_search_icon_col = app_session_mod.sidebar_search_icon_col;
const workspaceLabel = app_session_mod.workspaceLabel;
const MeasuredTextCache = app_session_mod.MeasuredTextCache;
const agentIconCodepoint = app_session_mod.agentIconCodepoint;
const notificationBadgeCol = AppSession.notificationBadgeCol;
const packRgbAlpha = app_session_mod.packRgbAlpha;
const sidebar_scrollbar_min_thumb_px = app_session_mod.sidebar_scrollbar_min_thumb_px;
const sidebar_toggle_codepoint = app_session_mod.sidebar_toggle_codepoint;
const tab_bg_tint_alpha = app_session_mod.tab_bg_tint_alpha;
const AgentKind = app_session_mod.AgentKind;
const agentTermOf = AppSession.agentTermOf;
const blendRgb = app_session_mod.blendRgb;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const diag_gate = app_session_mod.diag_gate;
const dock_list_scroll_drag_payload = app_session_mod.dock_list_scroll_drag_payload;
const pane_ops = @import("pane.zig");
const sidebar_scrollbar_inset_px = app_session_mod.sidebar_scrollbar_inset_px;
const spinnerBarCp = app_session_mod.spinnerBarCp;
const terminal = app_session_mod.terminal;
const traffic_light_clearance_pt = app_session_mod.traffic_light_clearance_pt;
const CollectedPane = AppSession.CollectedPane;
const GapDropPlan = AppSession.GapDropPlan;
const HeaderPart = AppSession.HeaderPart;
const SidebarScissor = AppSession.SidebarScissor;
const SidebarScrollExtent = AppSession.SidebarScrollExtent;
const SidebarSearchLine = AppSession.SidebarSearchLine;
const WorkspaceAgent = AppSession.WorkspaceAgent;
const clampMoveToGroup = app_session_mod.clampMoveToGroup;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const file_panel_ops = @import("file_panel.zig");
const icons = app_session_mod.icons;
const layout_math = app_session_mod.layout_math;
const packOpaqueRgb = app_session_mod.packOpaqueRgb;
const renderer = app_session_mod.renderer;
const scrollbar_alpha_full = app_session_mod.scrollbar_alpha_full;
const sidebarCwdPath = app_session_mod.sidebarCwdPath;
const sidebar_max_pt = app_session_mod.sidebar_max_pt;
const sidebar_min_pt = app_session_mod.sidebar_min_pt;
const sidebar_scroll_ids = app_session_mod.sidebar_scroll_ids;
const sidebar_scroll_max_entries = app_session_mod.sidebar_scroll_max_entries;
const sidebar_scrollbar_width_px = app_session_mod.sidebar_scrollbar_width_px;
const sidebar_search_text_col = app_session_mod.sidebar_search_text_col;
const spinner_bar_count = app_session_mod.spinner_bar_count;
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

/// SG4 — 사이드바 카드 드래그로 그룹에 넣기/빼기(docs/sidebar-groups.md §9·§10). 드롭 타겟 표시 row(raw_row)와
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
            .agent_toggle, .agent => {},
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
        .card => |c| c.tab < self.tabs.items.len and self.enclosingGroupMarkerIndex(c.tab) == null, // 타겟이 최상위면 최상위 복귀
        .agent_toggle, .agent => false, // 에이전트 목록 행은 드롭 타겟이 아니다
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
            const tl = self.topLevelGroupMarkerIndex(c.tab) orelse return null; // 그룹 밖 카드 → gap 아님
            if (self.groupSubtreeEnd(tl, null, null) != c.tab + 1) return null; // c가 최상위 그룹의 마지막 원소 아님 → 일반 멤버 드롭
            break :blk .{ .m = tl, .j = c.tab + 1 }; // 위 가드가 j==c.tab+1 확립 → 재사용
        },
        .agent_toggle, .agent => return null, // 에이전트 목록 행은 그룹 gap 판정 대상이 아니다
        .group_header => |h| blk: {
            if (h.tab >= len) return null;
            if (!h.collapsed) return null; // 펼친 헤더 아래 경계 = 첫 멤버(모호) → skip(일반 헤더 드롭)
            if (self.effectiveDepthAt(h.tab, null, null) != 1) return null; // 최상위 접힌 그룹만(중첩 접힌 헤더 gap은 모호)
            break :blk .{ .m = h.tab, .j = self.groupSubtreeEnd(h.tab, null, null) };
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
        .agent_toggle, .agent => return null, // 목록 행은 탭 인덱스 도메인이 아니다
        .group_header => |h| h.tab,
    };
    if (target_tab >= len) return null;
    // 첫 그룹 시작 = 최상위 구간의 끝(§2.1). **핀 리전(§12 GP1)**: 앵커는 드래그 그룹 m이 속한 핀 리전에 국소화한다
    // (각 리전 안에서 §2.1가 다시 성립 — 비고정 리전이면 [pinned_count, len)의 첫 마커). 마커가 그 리전에 없으면 리전
    // 끝(reg.hi). 고정 그룹 0개면 m은 비고정 리전이라 리전 앵커=전역 앵커·reg.hi=len → 옛 `firstGroupStartIndex() orelse
    // len`과 byte-identical. (그룹 통째 이동 자체의 리전 clamp는 GP3 clampGroupMoveToRegion.)
    const reg = self.pinRegionBounds(m);
    const first_group = self.firstGroupStartInRegion(reg.lo, reg.hi) orelse reg.hi;

    // **§14.6 SR4 인터리빙**: target이 **그룹 밖 top카드**(enclosing 마커 없음 = top_level 탭/그 sticky follower)면, 그
    // 카드가 속한 **최상위 run**을 한 단위로 보고 그룹을 그 앞/뒤로 끼운다(그룹↔탭 순서 교환). 그룹 헤더/멤버 row는 enclosing
    // 이 non-null이라 이 분기를 안 타고 아래 그룹 경계 로직으로 간다.
    if (self.enclosingGroupMarkerIndex(target_tab) == null) {
        // 최상위 run [run_lo, run_hi): run_lo=run 개시 카드(top_level 플래그가 선 카드 또는 리전 시작), run_hi=다음 마커/
        // 리전 끝. 위로 스캔은 개시 카드(top_level=true)에서 멈추고, 그 앞이 다른 최상위 카드일 때만 이어간다.
        var run_lo = target_tab;
        while (run_lo > reg.lo and !self.tabs.items[run_lo].top_level and
            self.enclosingGroupMarkerIndex(run_lo - 1) == null) run_lo -= 1;
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
    return self.groupSubtreeEnd(gi, null, null);
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
    }
}

/// 에이전트 행이 그리는 줄 수 — 라벨(항상) + 폴더·브랜치(그 Term의 cwd를 알 때, §2.1). 마지막 대화 두 줄은
/// transcript 보강(4·5단계)이 붙으면 여기서 함께 센다. 카드와 같은 규율로 이 값이 행 높이의 입력이다.
pub fn sidebarAgentRowLines(self: *AppSession, tab: *Tab, ag: WorkspaceAgent) u8 {
    const term = agentTermOf(tab, ag) orelse return 1;
    var n: u8 = 1; // 라벨(종류 · 상태)은 항상
    // **termGitBranch를 먼저** 부른다 — 이 호출이 관측(cwd)을 refresh하므로, sidebarHasCwd를 앞세우면 관측이
    // stale한 rebuild에서 줄 수를 1로 재고 같은 rebuild의 렌더는 2줄을 그려 행 높이와 글자가 어긋난다
    // (code-review max). sidebarCardLines가 쓰는 순서와 같게 맞춘다.
    const has_branch = self.termGitBranch(term) != null;
    if (sidebarHasCwd(term)) {
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
pub fn sidebarHasCwd(term: *Term) bool {
    return term.rt.observation.availability != .unavailable and term.rt.observation.cwd.items.len > 0;
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
    if (self.termGitBranch(term) != null) {
        if (self.loaded_config.config.sidebar.show_branch) n += 1;
        if (self.loaded_config.config.sidebar.show_folder and sidebarHasCwd(term)) n += 1;
    }
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

/// 카드 줄 수가 투영 당시와 달라졌으면 사이드바를 다시 투영한다.
///
/// **왜 필요한가**: 카드 줄 수는 활성 Term의 관측(cwd·git 브랜치)에서 파생되는데, 그 값은 투영 **뒤에** 바뀔 수
/// 있다. 두 경로가 실측으로 확인됐다(사용자 제보):
///
/// 1. **새 워크스페이스** — 관측이 채워지기 전에 투영돼 브랜치가 없는 1줄로 박힌다. 곧 관측이 도착해 렌더는
///    3줄을 그리지만 `Row.card.lines`는 1로 남는다.
/// 2. **Term 전환**(터미널 ↔ web 패널) — web Term은 cwd·브랜치가 없어 카드가 1줄, 터미널은 3줄이다. 같은 Pane
///    안에서 탭을 옮기면 카드 줄 수가 3↔1로 바뀐다.
///
/// 둘 다 결과가 같다: 밴드·hit-test가 쓰는 행 높이와 실제로 그려지는 글자가 어긋나, 활성 밴드가 이름줄이 아니라
/// 브랜치 줄에 걸린다. 에이전트 행에서 같은 클래스를 고쳤지만(응답 도착 시 재투영) 카드는 파생 경로가 달라
/// 여기서 막는다.
///
/// **고정 높이(min-height)로 덮지 않는 이유**: 그러면 1줄 카드도 3줄 자리를 차지해 목록이 그만큼 길어지고,
/// "카드 높이는 내용에 따라 다르다"는 이 기능의 전제(docs/sidebar-agent-list.md §3)와 정면으로 충돌한다.
/// 어긋남의 원인은 높이가 변하는 것이 아니라 **변한 뒤 다시 투영하지 않는 것**이다.
///
/// `sidebarCardLines`가 줄 수의 단일 출처이므로 그 값과 박힌 값을 그대로 대조한다. 값이 실제로 달라졌을 때만
/// 재투영하며, `termGitBranch`는 cwd가 바뀔 때만 재계산하므로 대부분의 tick에서 이 비교는 필드 읽기 몇 번이다.
pub fn reprojectSidebarIfCardLinesStale(self: *AppSession) void {
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
pub fn sidebarRowHoverBg(self: *const AppSession) u32 {
    const bg = self.appearance.theme.sidebar_background;
    const ac = self.appearance.theme.sidebar_active;
    const step = struct {
        fn f(b: u8, a: u8) u32 {
            const bi: i32 = @intCast(b);
            const ai: i32 = @intCast(a);
            const v = ai + @divTrunc(ai - bi, 1); // 배경→활성 델타만큼 한 번 더
            return @intCast(std.math.clamp(v, 0, 255));
        }
    }.f;
    return 0xFF00_0000 | (step(bg.r, ac.r) << 16) | (step(bg.g, ac.g) << 8) | step(bg.b, ac.b);
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

/// 사이드바 콘텐츠(표시 카드 전체 높이)가 헤더 아래 뷰포트를 넘는 양(backing px). 0이면 스크롤 불필요.
/// 순수 산술은 sidebarMaxScrollPx에 둬(헤드리스 단위 테스트) self는 필드만 떠 넘긴다.
pub fn sidebarMaxScroll(self: *const AppSession) u32 {
    // 가변 높이(카드=slot_h·헤더=header_row_h): 콘텐츠 높이를 rows.len*slot_h 대신 contentHeight 누적으로 구한다
    // (code-review #7 — 헤더를 slot_h로 세면 over-travel). 카드만이면 rows.len*slot_h와 같아 동작 보존.
    // 도메인은 **sidebarRenderRows()**(SG8): collapsed 그룹 드래그는 subtree를 force-emit해 preview_rows가 sidebar_rows
    // 보다 길어지는데, 짧은 sidebar_rows로 content 높이를 재면 스크롤이 안 되고(max=0) thumb가 과대해진다. 렌더가
    // 보는 rows와 같은 도메인으로 재야 정합. 비드래그면 preview=null이라 sidebar_rows와 동일(byte-identical).
    const content_h = chrome.components.sidebar.contentHeight(sidebarRenderRows(self), sidebarMetrics(self));
    // 사이드바 뷰포트도 상태바 위에서 끝난다 — 안 빼면 마지막 카드가 상태바 뒤로 숨고 스크롤로 꺼낼 수 없다.
    return sidebarMaxScrollPx(content_h, self.backing_height_px -| self.statusBarHeightPx(), self.sidebar_header_height_px);
}

/// 사이드바 스크롤 오프셋을 [0, sidebarMaxScroll]로 잡는다. 탭 추가/삭제·검색 필터·resize·휠로 콘텐츠/뷰포트가
/// 바뀌면 stale 오프셋이 자동 정정된다(tab_scroll_cols 재clamp 선례). rebuildSidebar가 표시 탭 재계산 직후 호출.
pub fn clampSidebarScroll(self: *AppSession) void {
    const max = sidebarMaxScroll(self);
    if (self.sidebar_scroll_offset_px > max) self.sidebar_scroll_offset_px = max;
}

/// SG8d — 렌더가 소비하는 표시 행(docs/sidebar-groups.md §9 SG8, 렌더/hit-test 도메인 분리). **카드 드래그 프리뷰**
/// 중(sidebar_drag_preview!=null)엔 고스트를 담은 `sidebar_preview_rows`를, 아니면 원본 `sidebar_rows`를 돌려준다.
/// hit-test(slotAt·dragTargetSlot·visibleTab·sidebarGroupDropTargetTab)는 **항상 원본 sidebar_rows**를 봐 드래그 중
/// self.tabs·plan 계산 기준이 불변이라 yo-yo가 원천 차단된다 — 오직 렌더 소비자(view·glyph·py_top·tint/accent·⌘배지)만
/// 이 헬퍼로 preview_rows를 본다. move(순열) 모델이라 두 배열 길이가 같아 스크롤 높이·정합이 흔들리지 않는다.
pub fn sidebarRenderRows(self: *const AppSession) []const chrome.components.sidebar.Row {
    return if (self.sidebar_drag_preview != null) self.sidebar_preview_rows.items else self.sidebar_rows.items;
}

/// 사이드바 표시 row가 고정 핀(📌)을 그리는가(그룹 고정 C2 — docs/sidebar-groups.md §12.8 GP4). buildSidebarTitleFrame이
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
        .agent_toggle, .agent => false, // 목록 행 자체는 pin 대상이 아니다(소속 카드가 든다)
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

/// SG8d/e 드래그 프리뷰 확정(docs/sidebar-groups.md §9 SG8) — 마지막 plan을 실제 move로 **정확히 1회** 커밋하고 프리뷰를
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
                if (self.localPinPrefixBounds(origin)) |b| {
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
                self.enclosingGroupMarkerIndex(origin - 1) != null;
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
        .group_sibling => |g| _ = self.moveGroupSibling(origin, g.insert_before), // SG5-1 형제 + SG5-4 빼기
        .group_nest => |g| _ = self.moveGroupNesting(origin, g.insert_before, g.target_depth), // SG5-4 넣기
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
    self.sidebar_cells.clearRetainingCapacity();
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
            .agent_toggle, .agent => null,
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
            .agent_toggle, .agent => {},
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
            .agent_toggle, .agent => continue, // 목록 행은 per-card tint/accent 대상이 아니다(소속 카드가 그린다)
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
                .agent_toggle, .agent => 1,
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
                        .card, .agent_toggle, .agent => false,
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
    sidebar_cells_present: bool,
    header_height_px: u32,
    scroll_offset_px: u32,
    status_bar_height_px: u32,
) SidebarScissor {
    const none = SidebarScissor{ .top = 0, .bottom = 0 };
    if (!sidebar_cells_present or backing_height_px == 0) return none;

    const scroll_clip = scroll_offset_px > 0 and header_height_px < backing_height_px;
    const bottom_clip = status_bar_height_px > 0;
    if (!scroll_clip and !bottom_clip) return none;

    const top: u32 = if (scroll_clip) header_height_px else 0;
    const bottom: u32 = if (status_bar_height_px < backing_height_px)
        backing_height_px - status_bar_height_px
    else
        0;
    if (bottom <= top) return none; // 겹친 구간을 내느니 안 자른다(뒤집힌 rect 방지)
    return .{ .top = top, .bottom = bottom };
}

pub fn sidebarMaxScrollPx(content_height_px: u32, backing_height_px: u32, header_height_px: u32) u32 {
    const viewport: u64 = if (backing_height_px > header_height_px) backing_height_px - header_height_px else 0;
    if (content_height_px <= viewport) return 0;
    return @intCast(@min(@as(u64, content_height_px) - viewport, @as(u64, std.math.maxInt(u32))));
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
pub fn sidebarScrollClipQuad(self: *const AppSession, abs_y: f32, h: f32) ?struct { y: f32, h: f32, clipped: bool } {
    const header: f32 = @floatFromInt(self.sidebar_header_height_px);
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
    const header = self.sidebar_header_height_px;
    const bottom = self.backing_height_px -| self.statusBarHeightPx();
    if (bottom <= header) return null;
    const max_offset = sidebarMaxScroll(self);
    if (max_offset == 0) return null; // 안 넘침 — 스크롤바 없음
    return .{
        .rect = .{ .x = 0, .y = header, .w = self.sidebar_width_px, .h = bottom - header },
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
    return .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .thumb_y = h.y,
        .thumb_h = h.height,
        .max_offset_px = self.sidebar_scroll_max_offset_px,
    };
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
    // gpu_quad(rich 밴드)는 슬롯 상대 y를 절대 좌표로 박으므로 상단 헤더만큼 내려야 한다 — .m이 header_h 시프트하는
    // 건 sidebar_cells(텍스트·tui 밴드)뿐이라 gpu_quad는 여기서 header_h를 더한다(위치 정합). 좌측 accent 막대는
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
                .agent_toggle, .agent => {},
                .group_header => |h| {
                    // SG5-2: 그룹 헤더 밴드에 그룹 공통 색을 블렌드(카드 배경 tint와 **같은** blend 경로·같은 알파). 층
                    // 분리 — 그룹 색은 헤더 밴드·소속 카드 막대에만 실리고 개별 카드 background_color와 안 겹친다(서로 다른 row).
                    if (h.tab < self.tabs.items.len and self.tabs.items[h.tab].group_color != 0)
                        color = blendRgb(color, self.tabs.items[h.tab].group_color & 0x00FF_FFFF, tab_bg_tint_alpha);
                },
            };
            const has_radius = q.corner_radii[0] != 0 or q.corner_radii[1] != 0 or q.corner_radii[2] != 0 or q.corner_radii[3] != 0;
            if (!has_radius) {
                // tui: 직각 → 셀 밴드. 세로 위치·높이를 chrome이 준 **content-상대 rowTop(q.rect.y)·row 높이(q.rect.h)**로
                // 그대로 셀에 실어(.m이 균일 row*slot_h 대신 그걸 씀) 그룹 헤더(얇은 한 줄)와 정합한다(code-review #7).
                // past-end(리스트 아래 새 워크스페이스 드롭 행)도 bandFill이 q.rect.y=contentHeight로 내므로, 옛
                // `sidebarBandRow(q.rect.y) orelse continue`가 null로 삼키던 드롭 하이라이트 셀이 이제 방출된다(#8).
                if (q.rect.y < 0) continue; // 이 경로 y는 항상 ≥0(방어)
                const origin_y: u32 = @intCast(q.rect.y);
                // .row는 tint 역매핑·디버그용 표시 row(past-end면 rows.len — .m 세로 위치는 origin_y가 단일 출처).
                const ri = sidebarBandRow(self, q.rect.y) orelse rrows.len;
                const row: u16 = @intCast(@min(ri, @as(usize, std.math.maxInt(u16))));
                // 드롭 타겟(.drop_zone)은 드래그 중 "어디 떨어질지" 단서라 window.opacity 미적용 — focus 테두리·accent와 동급(불투명 유지).
                // 나머지 밴드(활성/호버)만 셀 경로 premultiply. drop_zone은 α=1이라 premult==straight로 어느 경로든 안전.
                const band_bg = if (q.fill_role == .drop_zone) color else self.chromeCellBg(color);
                if (sidebarBandCell(self.sidebar_width_px, self.cell_width_px, row, origin_y, q.rect.h, band_bg)) |cell| {
                    self.sidebar_cells.append(self.allocator, cell) catch {};
                }
            } else {
                // rich: GPU quad 프리미티브(둥근 밴드) — 셀 그리드와 별개 파이프라인으로 렌더된다.
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

/// running 상태줄/라벨 파형 문자열 "▁▅▇▃ 진행중"(owned). 사이드바 카드(workspaceStatusLine)와 단일 Term
/// 폴백(agentStatusLine)이 **같은 문자열**을 쓰도록 단일화(code-review max — 옛 두 곳 중복 방지).
pub fn runningStatusLine(self: *AppSession) ![]const u8 {
    const bars = try spinnerBarsUtf8(self, self.allocator);
    defer self.allocator.free(bars);
    return std.fmt.allocPrint(self.allocator, "{s} 진행중", .{bars});
}

/// 사이드바 상태줄은 워크스페이스 대표 상태(blocked > running > idle > unknown)를 표시한다.
pub fn workspaceStatusLine(self: *AppSession, tab: *Tab) ![]const u8 {
    const representative = tab_ops.tabAgentRepresentative(tab) orelse return self.allocator.dupe(u8, "");
    return agentStatusLine(self, representative.term);
}

/// 한 Term의 상태줄 텍스트(owned). 에이전트 아니면(none) "" — 그 줄은 생략된다. running이면 "▁▅▇▃ 진행중"(파형),
/// blocked/idle/unknown도 오해 없는 짧은 상태 문구로 표시한다.
/// 사이드바는 workspaceStatusLine이 고른 대표 Term을 이 함수로 넘긴다.
/// 에이전트 행 **1행 텍스트**(owned) — 종류 이름 + 상태 문구. 카드 상태줄(agentStatusLine)이 상태 마커·문구의
/// 단일 출처이므로 그대로 쓰고, 앞에 종류 이름을 붙여 "무엇이 어떤 상태인지"를 한 줄로 읽게 한다.
/// 예: `✓ 대기중` → `Claude Code · ✓ 대기중`. 마지막 프롬프트로 이 자리를 대체하는 것은 transcript 보강(4·5단계)이다.
pub fn agentRowLabelOwned(self: *AppSession, term: *Term) ![]const u8 {
    const status = try agentStatusLine(self, term);
    defer self.allocator.free(status);
    // 마지막 **사용자 프롬프트**가 있으면 종류 이름·상태 문구 대신 그것을 싣는다(§7). 사용자가 이 행에서 알고
    // 싶은 건 "무엇을 시켰는가"이고, 진행 여부는 앞의 마커(파형·✓)가 이미 말한다. 종류는 gutter 아이콘에 남는다.
    const prompt = term.agent_transcript.prompt();
    if (prompt.len > 0) {
        // 상태 문구는 "<마커> <문구>" 꼴이라(agentStatusLine 단일 출처) 첫 공백 앞이 마커다 — 파형 애니메이션도
        // 그 자리에서 그대로 살아 있다. 마커를 따로 만들지 않는 이유는 상태 문구가 바뀔 때 둘이 어긋나지 않게.
        const marker_end = std.mem.indexOfScalar(u8, status, ' ') orelse status.len;
        const marker = status[0..marker_end];
        if (marker.len == 0) return self.allocator.dupe(u8, prompt);
        return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, prompt });
    }
    const kind_name: []const u8 = switch (term.agent_kind) {
        .claude => "Claude Code",
        .codex => "Codex",
        .none => "",
    };
    if (status.len == 0) return self.allocator.dupe(u8, kind_name);
    return std.fmt.allocPrint(self.allocator, "{s} \u{00b7} {s}", .{ kind_name, status });
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
    const path = try sidebarCwdPath(self.allocator, term);
    defer self.allocator.free(path);
    if (path.len == 0) return self.allocator.dupe(u8, "");
    const leaf = std.fs.path.basename(path);
    const folder: []const u8 = if (leaf.len > 0) leaf else path;
    return std.fmt.allocPrint(self.allocator, "{s}  " ++ icons.utf8(.folder) ++ " {s}", .{ indent, folder });
}

/// 에이전트 행 **브랜치 줄**(owned) — git repo 안일 때만(카드 보조줄과 같은 규칙). **폴더와 같은 줄에 합치지
/// 않는다**: 사이드바 폭에서 둘을 한 줄에 넣으면 브랜치가 잘린다(사용자 실측 피드백 — 설계의 "이어 붙인다"를 정정).
pub fn agentRowBranchOwned(self: *AppSession, term: *Term, indent: []const u8) ![]const u8 {
    const branch = self.termGitBranch(term) orelse return self.allocator.dupe(u8, "");
    return std.fmt.allocPrint(self.allocator, "{s}  " ++ icons.utf8(.mark_github) ++ " {s}", .{ indent, branch });
}

pub fn agentStatusLine(self: *AppSession, term: *Term) ![]const u8 {
    if (term.agent_kind == .none) return self.allocator.dupe(u8, "");
    return switch (term.agent_state) {
        .running => runningStatusLine(self), // codex식 4칸 파형 "▁▅▇▃ 진행중"(단일 출처)
        .blocked => self.allocator.dupe(u8, "? 입력 대기"),
        .idle => self.allocator.dupe(u8, "\u{2713} 대기중"),
        .unknown => self.allocator.dupe(u8, "\u{00b7} 상태 확인 중"),
    };
}

pub fn buildSidebarTitleDrawList(self: *AppSession) !renderer.DrawList {
    const cw = self.cell_width_px;
    if (cw == 0 or self.tabs.items.len == 0) return error.NoSidebar;
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
    var agents: std.ArrayList(u21) = .empty;
    defer agents.deinit(self.allocator);
    var pins: std.ArrayList(bool) = .empty;
    defer pins.deinit(self.allocator);
    // 카드당 대표 kind·running을 **한 번만** 스캔해 담는다(표시 슬롯 순서) — 아이콘·상태줄(여기)과 아래 색칠 루프가
    // 재사용해 tabAgentKind/tabHasRunningAgent(O(panes×terms))를 카드마다 여러 번 재스캔하지 않게(code-review high).
    var card_kinds: std.ArrayList(AgentKind) = .empty;
    defer card_kinds.deinit(self.allocator);
    var card_running: std.ArrayList(bool) = .empty;
    defer card_running.deinit(self.allocator);
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
                const toggle_summary: []const u8 = if (t.collapsed and t.tab < self.tabs.items.len) blk: {
                    const rep = tab_ops.tabAgentRepresentative(self.tabs.items[t.tab]) orelse break :blk try self.allocator.dupe(u8, "");
                    const st = try agentStatusLine(self, rep.term);
                    defer self.allocator.free(st);
                    if (st.len == 0) break :blk try self.allocator.dupe(u8, "");
                    break :blk try std.fmt.allocPrint(self.allocator, " \u{00b7} {s}", .{st});
                } else try self.allocator.dupe(u8, "");
                defer self.allocator.free(toggle_summary);
                try names.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{d} agents{s}",
                    .{ indent_buf[0..ind_n], t.count, toggle_summary },
                ));
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try agents.append(self.allocator, if (t.collapsed) @as(u21, 0x25B6) else @as(u21, 0x25BC));
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
                    try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ ind, label }));
                } else {
                    try names.append(self.allocator, try self.allocator.dupe(u8, ""));
                }
                // 2·3행: 그 Term의 폴더와 브랜치(§2.1 — 항상 표시, 카드 헤더와 달리 **그 에이전트가 도는 자리**).
                // **한 줄에 합치지 않는다**: 사이드바 폭에서 폴더+브랜치를 한 줄에 넣으면 브랜치가 잘린다(실측).
                try branch_lines.append(self.allocator, if (aterm) |t|
                    try agentRowFolderOwned(self, t, ind)
                else
                    try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, if (aterm) |t|
                    try agentRowBranchOwned(self, t, ind)
                else
                    try self.allocator.dupe(u8, ""));
                // 4행: 마지막 **응답**(§7). sidebarAgentRowLines의 줄 수 조건과 1:1이다.
                try status_lines.append(self.allocator, if (aterm) |t|
                    try agentRowReplyOwned(self, t, ind)
                else
                    try self.allocator.dupe(u8, ""));
                // gutter 아이콘: 그 Term의 kind(카드 대표 아이콘이 사라진 자리를 행마다 대신한다).
                try agents.append(self.allocator, if (aterm) |t| agentIconCodepoint(t.agent_kind) else 0);
                try pins.append(self.allocator, false);
                try card_kinds.append(self.allocator, if (aterm) |t| t.agent_kind else .none);
                try card_running.append(self.allocator, if (aterm) |t| (t.agent_state == .running) else false);
                try close_rows.append(self.allocator, aterm != null); // 에이전트 행 ✕ = 그 Term 닫기
                try ages.append(self.allocator, try agentAgeOwned(self, aterm));
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
                    const label: []const u8 = if (gname.len > 0) gname else "그룹";
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
            const branch = self.termGitBranch(term); // cwd 변경 시에만 .git/HEAD 재읽기(캐시) — repo 판정에도 씀
            const show_branch = self.loaded_config.config.sidebar.show_branch;
            const show_folder = self.loaded_config.config.sidebar.show_folder;
            // 브랜치줄 prefix = GitHub octocat(0xF0009). 예전 git-branch(0xF0001)는 얇은 선+링 3개라 카드 셀 크기
            // (~8~12px)로 area-average 다운스케일되면 내부 구조가 뭉개져 ├(U+251C)처럼 보였다(사용자 피드백). octocat은
            // 꽉 찬 단색 실루엣이라 작은 크기에서도 외곽이 살아 GitHub 마크로 읽힌다(icon_glyph fillCoverage 경로 동일).
            // 폭은 wideIconPredicate가 PUA를 **2칸(~16px)** 렌더해 width-1(~8px)일 때 동그란 링처럼 뭉개지던 걸 키웠다 —
            // 폴더줄(0xF000A)·에이전트 gutter 아이콘과 같은 크기로 통일(사용자 피드백 "깃 아이콘이 너무 작다").
            // 각 보조줄은 **비어있지 않을 때만** indent를 붙인다(빈 줄은 그대로 "" — 카드 줄 수 계산 정합).
            try branch_lines.append(self.allocator, if (show_branch) (if (branch) |b| try std.fmt.allocPrint(self.allocator, "{s}" ++ icons.utf8(.mark_github) ++ " {s}", .{ indent, b }) else try self.allocator.dupe(u8, "")) else try self.allocator.dupe(u8, ""));
            try path_lines.append(self.allocator, if (show_folder and branch != null) blk: {
                const fl = try sidebarFolderLine(self.allocator, term);
                if (indent.len == 0 or fl.len == 0) break :blk fl; // depth 0 or 빈 줄 — 그대로(빈 줄에 공백 붙이면 4번째 줄이 생긴다)
                defer self.allocator.free(fl);
                break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ indent, fl });
            } else try self.allocator.dupe(u8, ""));
            // 상태줄은 **탭 단위** — running이면(어느 pane/Term이든) 파형 스피너, 아니면 활성 Term 상태(위에서 계산한 running 재사용).
            // **빈 상태줄(에이전트 아님)엔 indent를 붙이지 않는다** — 안 그러면 공백-only 줄이 돼 buildSidebarDrawList가
            // 빈 줄로 생략하지 못하고 **없던 4번째 줄이 렌더**된다(사용자 제보 버그). 빈 줄은 반드시 ""로 유지.
            // 상태줄 없음: 대표 하나로 압축하던 자리를 **에이전트 목록**이 대체한다(§2 "기존 대표 표시는 제거").
            // 대표를 고르는 규칙(blocked > running > idle)도 목록 앞에서는 의미가 없다.
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
    var draw_list = try coretext_frame_builder.buildSidebarDrawList(self.allocator, names.items, branch_lines.items, path_lines.items, status_lines.items, agents.items, pins.items, sidebar_cols, fg, close_rows.items, ages.items, null, active_row, active_fg, editing_row);
    // 에이전트 아이콘(✶ claude / ◆ codex)과 상태줄 running 스피너(이퀄라이저 바 ▁~█)에 **브랜드색**을 입힌다 — claude=Anthropic 코랄,
    // codex=OpenAI 청록. 종류를 색으로 구분하고, **관측 상태는 상태줄**(running=이퀄라이저 파형[브랜드색]·idle=✓ 대기중)이 담당한다
    // (옛 아이콘 밝기 펄스는 폐기 — 아래 루프는 아이콘·스피너 모두 솔리드 브랜드색). 색은 `term.agent_kind` 단일 출처로 고른다.
    // **오염 방지**: 아이콘은 gutter `col 0` + 합성 codepoint로 좁히고, 스피너는 **상태줄(카드 마지막 줄)**에만 색칠한다 —
    // 워크스페이스 이름/브랜치/경로 줄(line_index<line_count-1)에 블록 글자가 들어가도 안 오염(code-review high #2).
    // 슬롯(탭)별 kind·running은 위 조립 루프가 카드당 1회 스캔해 담은 `card_kinds`/`card_running`을 **그대로 재사용**한다
    // (표시 슬롯 = 배열 인덱스) — 셀·슬롯마다 tabAgentKind/tabHasRunningAgent(O(panes×terms))를 다시 안 돌린다(code-review high).
    for (draw_list.cells) |*c| {
        const is_icon = c.col == 0 and (c.codepoint == icons.codepoint(.sparkle) or c.codepoint == icons.codepoint(.diamond)); // ✶ claude / ◆ codex
        // 셀 row에서 표시 슬롯 인덱스를 디코드(row=slot*sidebar_line_base+줄offset, 줄offset<base라 아이콘/스피너 같은 슬롯).
        const slot = c.row / coretext_frame_builder.sidebar_line_base; // = card_kinds/card_running 인덱스(조립 순서와 동일)
        if (slot >= card_kinds.items.len) continue;
        // 이퀄라이저 바(블록 ▁~█)는 이제 **에이전트 목록 행**에 있다 — 카드 상태줄이 목록으로 이동했기 때문
        // (docs/sidebar-agent-list.md §2). 옛 게이트는 "카드의 마지막 줄"(line_index==line_count-1)로 좁혀서,
        // 목록 행의 첫 줄에 오는 파형을 못 잡아 브랜드색이 빠졌다(사용자 제보). row **종류**로 게이트하면
        // 위치가 바뀌어도 따라오고, 이름·경로 줄의 우연한 블록 문자가 오염되는 것도 막는다.
        const on_agent_row = slot < rrows.len and (rrows[slot] == .agent or rrows[slot] == .agent_toggle);
        const is_spinner = on_agent_row and isAgentSpinnerCp(c.codepoint);
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
    const ch = m.line_h;
    if (cells.len == 0 or ch == 0) return;
    const base = coretext_frame_builder.sidebar_line_base; // 32 — sidebarGlyphRow 인코딩 단일 출처
    var content_tops: std.ArrayList(u32) = .empty;
    defer content_tops.deinit(allocator);
    // **목록 위 여백에서 시작한다** — `rowTop`(밴드·hit-test·caret이 쓰는 기준)이 content_pad_v를 더하므로
    // 여기서 0부터 누적하면 글자만 여백 위로 올라가 **밴드가 글자보다 한 줄 아래로 밀린다**(사용자 제보).
    // 세 좌표계(밴드·글자·클릭)가 같은 기준을 써야 "보이는 곳 = 눌리는 곳"이 성립한다.
    var acc: u32 = m.content_pad_v;
    for (rows) |row| {
        content_tops.append(allocator, acc) catch return; // 카드·헤더 모두 한 엔트리(slot=row 인덱스). OOM: 이 프레임 skip
        acc +|= chrome.components.sidebar.rowHeight(row, m); // 카드=줄 수 기반·헤더=header_row_h
    }
    for (cells) |*c| {
        if (c.slot_id == 0) continue; // 밴드/배경 셀 — 자체 경로(row 인덱스)
        const slot: usize = c.row / base;
        if (slot >= content_tops.items.len) continue; // 방어 — 매핑 밖(비정상)이면 건너뜀
        const rem = c.row % base;
        const line_count: u32 = rem / 4;
        const line_index: u32 = rem % 4;
        const row_h = chrome.components.sidebar.rowHeight(rows[slot], m); // 이 row의 실제 높이(헤더=얇은 줄)
        const block_off: u32 = (row_h -| sidebarBlockHeight(line_count, ch)) / 2; // renameCaretRect와 같은 정수 블록중앙(정합)
        c.origin_y = content_tops.items[slot] +| block_off +| line_index *| m.line_step; // 줄 스텝=ch+여유(촘촘함 완화)
    }
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
pub fn appendBellAndBadge(self: *AppSession, cells: *std.ArrayList(renderer.DrawCell), bell_col: u16, fg: terminal.Color, round_badge: bool) !void {
    try cells.append(self.allocator, .{ .row = 0, .col = bell_col, .codepoint = icons.codepoint(.bell), .width = 2, .style = .{ .foreground = fg } });
    if (self.notification_unread == 0) return;
    if (round_badge) {
        // 펼침 헤더: 종 **우상단** 빨강 원형 배지(iOS/macOS식). 빨강 원은 GPU quad(appendNotificationBadge, layer 4 —
        // 헤더 글리프 '뒤')가 그리고, 여기선 그 원 위에 올라갈 **흰 숫자**만 셀로 둔다(같은 col=bell_col+2 단일 출처 —
        // notificationBadgeCol). 원형 1칸 제약상 1~9는 숫자, 10개 이상은 '9'로 cap한다(2칸 "9+"는 종 우측에 ◧가 붙어
        // 자리가 없다 — docs/notifications.md §3). 배경은 default(투명)라 원 quad가 비친다.
        const white: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
        const digit: u21 = '0' + @as(u21, @intCast(@min(self.notification_unread, 9)));
        try cells.append(self.allocator, .{ .row = 0, .col = notificationBadgeCol(bell_col), .codepoint = digit, .style = .{ .foreground = white } });
    } else {
        // 접힘 타이틀바: 종 **좌측** 빨강 텍스트 배지(기존 유지). 접힘 헤더는 터미널 위에 그려져 layer 4 quad가 터미널
        // 셀에 가리므로(원형 quad 부적합) 텍스트 배지로 둔다. 1~9는 숫자 1칸, 10개 이상은 "9+" 2칸.
        const badge_rgb: terminal.Color = .{ .rgb = .{ .r = 0xE0, .g = 0x5A, .b = 0x4A } };
        if (self.notification_unread > 9) {
            try cells.append(self.allocator, .{ .row = 0, .col = bell_col -| 2, .codepoint = '9', .style = .{ .foreground = badge_rgb } });
            try cells.append(self.allocator, .{ .row = 0, .col = bell_col -| 1, .codepoint = '+', .style = .{ .foreground = badge_rgb } });
        } else {
            try cells.append(self.allocator, .{ .row = 0, .col = bell_col -| 1, .codepoint = '0' + @as(u21, @intCast(self.notification_unread)), .style = .{ .foreground = badge_rgb } });
        }
    }
}

/// 사이드바 헤더 glyph의 DrawList(접힘이면 좌상단 토글 — buildCollapsedToggleDrawList 위임; 조건 미달이면 null).
/// 멀티 페인 통합(collectShaped)이 직접 써 통합 placeMultiPane으로 한 atlas 세대에 묶는다.
pub fn buildSidebarHeaderDrawList(self: *AppSession, part: HeaderPart) !?renderer.DrawList {
    const cw = self.cell_width_px;
    if (cw == 0 or self.cell_height_px == 0 or self.tabs.items.len == 0) return null;
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
    const sb_icon = chrome.components.sidebar;
    if (part == .icons) {
        try appendBellAndBadge(self, &cells, cols - 12, fg, true); // 펼침: 종(cols-12) 우상단 원형 배지(흰 숫자 cols-10 + 빨강 원 quad)
        try cells.append(self.allocator, .{ .row = 0, .col = @intCast(sb_icon.headerIconCol(.toggle_sidebar, cols)), .codepoint = sidebar_toggle_codepoint, .style = .{ .foreground = fg } });
        try cells.append(self.allocator, .{ .row = 0, .col = @intCast(sb_icon.headerIconCol(.view_options, cols)), .codepoint = icons.codepoint(.gear), .style = .{ .foreground = fg } });
        try cells.append(self.allocator, .{ .row = 0, .col = @intCast(sb_icon.headerIconCol(.new_workspace, cols)), .codepoint = icons.codepoint(.plus), .style = .{ .foreground = fg } });
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
        self.collectMeasuredTextFromCache(collected, dl, cache, builder, .{ .sidebar_search = .{
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
    const bell_col = self.collapsedBellCol();
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
