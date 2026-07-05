//! Sidebar — 세로 워크스페이스 사이드바의 hit-test + 밴드 렌더. chrome **마우스 hit-test 컴포넌트**(divider 동형 —
//! State 없는 순수 함수). 드래그 재정렬이 인덱스 기반(`sidebar_drag_index: usize`)이라 라이브 포인터 부담이
//! divider(`*Split`)보다 적다(§6). host가 중립 `Tab`(라벨·활성)을 주입하고, platform이 라이브 상태(폭·드래그
//! 인덱스·hover)·제목 glyph 렌더(`buildSidebarTitleFrame` — CoreText는 platform 책임)·밴드 fill lowering을 맡는다.
//! 이 컴포넌트는 (1) hit-test 순수 함수(옛 app_session의 xInSidebar 등 이전)와 (2) 밴드 view(활성/호버 fill)를
//! 단일 출처로 든다. 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C3a).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");

/// 이 컴포넌트가 그리는 레이어 — 사이드바(가장 아래 Z, 터미널 strip 왼쪽). platform이 밴드 fill을 lower해 sidebar 셀 슬롯에.
pub const layer = draw.Layer.sidebar;

/// host(projectRows)가 주입하는 사이드바 화면 **한 줄(row)**. 카드일 수도 그룹 헤더일 수도 있다 — hit-test/view는
/// row가 어느 종류인지만 보고 균일하게 처리해 "슬롯=카드=탭 인덱스" 1:1 가정을 없앤다(docs/sidebar-groups.md §2.2).
/// SG1에선 card만 생성해 동작을 보존하고(그룹 없음), group_header는 SG3에서 채운다. 라벨 glyph 렌더는 platform
/// (`buildSidebarDrawList`)이 맡고(CoreText 경계), chrome은 밴드(fill)·hit-test만 든다.
pub const Row = union(enum) {
    /// 워크스페이스 카드. tab=원본 self.tabs 인덱스(옛 visibleTab 값), active=활성 워크스페이스,
    /// depth=그룹 안이면 1(들여쓰기 — SG3). label은 제목 glyph 완전 이주(후속) 시 view가 text op으로 쓸 자리다.
    /// pin_derived=이 카드의 `tab.pinned`가 **그룹 고정에서 파생된 캐시**(멤버)인가(그룹 고정 C2 — docs/sidebar-groups.md §12.8).
    /// 멤버 카드 pinned는 enclosing 마커의 권위를 미러한 값이라(§12.2), 그대로 렌더하면 모든 멤버에 📌 노이즈가 뜬다.
    /// projectRowsCore가 order-aware로(depth/member_count와 동형) 채운다 — **비마커 그룹 멤버=true**(파생 억제 대상),
    /// **그룹 마커 카드·최상위 개별 pin 카드=false**(마커는 권위·헤더가 인디케이터, 최상위는 자기 pin). buildSidebarDrawList가
    /// live `tab.pinned` 대신 이 힌트를 읽어 멤버 📌를 억제한다. depth와 달리 "마커 카드 vs 멤버 카드"를 구별한다(둘 다 depth>0).
    card: struct { tab: usize, label: []const u8, active: bool, depth: u8 = 0, pin_derived: bool = false },
    /// 그룹 헤더(SG3) — 접기 토글 줄(카드 아님). collapsed=접힘, member_count=접힘 시 "▸ name (N)" 표시용.
    /// tab=이 그룹을 **시작하는 원본 self.tabs 인덱스**(group_start 마커를 든 탭). 헤더 클릭 시 그 탭의 group_collapsed를
    /// 토글하고(onGroupHeader), platform이 라벨 glyph를 그 탭의 `group_start`에서 **직접 라이브로** 뽑는다(label은
    /// borrowed라 destroyTab 후 dangling 위험 — code-review #8 UAF 해소: 소스 tab 인덱스를 실어 live 재조회).
    /// depth=이 그룹의 정규화 깊이(SG5-3 중첩 — 1=최상위, 2=중첩, …). 헤더 삼각/이름 glyph는 platform이 (depth-1)*group_indent
    /// 만큼 들여쓴다(소속 카드는 depth*group_indent). 밴드(view)는 depth 무관 전폭(카드 밴드와 동형).
    /// has_color=이 그룹에 그룹 색(SG5-2)이 지정됐는가. **기본(무색) 헤더는 밴드(보더라인) 없이 화살표+이름만** 남기고
    /// (사용자 결정 — docs/sidebar-groups.md §5), 색이 지정된 그룹만 view가 헤더 밴드를 내 lowerSidebar가 그 색으로
    /// tint한다(색 구분 유지). host(projectRows)가 tab.group_color!=0로 채운다 — chrome은 role 기반이라 RGB를 못 실어
    /// "밴드를 낼지"만 판단하고, 실제 색 blend는 platform이 tab.group_color로 한다(층 분리). hover/active 밴드는 has_color와
    /// 무관하게 그대로(상호작용 하이라이트는 보더라인이 아니라 피드백이라 카드와 같은 경로로 유지).
    group_header: struct { collapsed: bool, label: []const u8, member_count: u16, tab: usize, depth: u8 = 0, has_color: bool = false },
};

/// row_index가 그룹 헤더 row인가(클릭 시 선택이 아니라 접기 토글 대상). closeButton과 같은 결의 순수 hit-test
/// 헬퍼 — host(mouseDown)가 slotAt로 얻은 row가 헤더면 group_collapsed 토글로 분기한다(docs/sidebar-groups.md §5·§7).
pub fn onGroupHeader(rows: []const Row, row_index: usize) bool {
    if (row_index >= rows.len) return false;
    return rows[row_index] == .group_header;
}

// ── hit-test (옛 app_session 순수 함수 이전, 같은 수학) ────────────────────────

/// x(backing px)가 세로 사이드바 영역(0..width) 안인가. 폭 0·x<0·width 이상이면 false.
pub fn inSidebar(x_px: f64, sidebar_width_px: u32) bool {
    return sidebar_width_px > 0 and x_px >= 0 and x_px < @as(f64, @floatFromInt(sidebar_width_px));
}

/// x가 사이드바 우측 경계(폭조절 드래그) 밴드 [width, width + cell절반+2px) 안인가 — 터미널 쪽으로만(슬롯/✕와 안 겹침).
/// 폭 0·cell 0·비유한이면 false. cell==0은 렌더 전 degenerate 상태 — platform 호출처가 sibling(pxToCell·imeCursorRect)과
/// 일관되게 placeholder 폭을 적용해 넘기므로(chrome은 placeholder 상수를 모른다) 여기선 단순히 false로 둔다.
pub fn onResizeEdge(x_px: f64, sidebar_width_px: u32, cell_width_px: u32) bool {
    if (sidebar_width_px == 0 or cell_width_px == 0 or !std.math.isFinite(x_px)) return false;
    const edge: f64 = @floatFromInt(sidebar_width_px);
    const margin = @as(f64, @floatFromInt(cell_width_px)) / 2 + 2;
    return x_px >= edge and x_px < edge + margin;
}

/// 사이드바 y(backing px) → row 인덱스(**가변 높이 누적** — 카드=card_slot_h·그룹 헤더=header_row_h). 사이드바 헤더
/// (검색바·아이콘) 영역 y<header_height_px는 null. rows 빈·비유한·콘텐츠 아래 빈 영역이면 null. header_height_px=0이면
/// 사이드바 헤더 없음(콘텐츠가 y=0부터). scroll_offset_px는 콘텐츠가 위로 밀린 양 — 화면 y의 row는 콘텐츠 좌표
/// (y-header+scroll)로 역산한다. 사이드바 헤더는 스크롤 무관 고정이라 y<header 판정엔 scroll을 안 더한다("보이는=클릭되는").
/// 각 row 높이를 누적하며 콘텐츠 y가 드는 row를 찾는다(고정 나눗셈 대신 — 헤더/카드 높이가 달라서). 카드만이면 균일과 동일.
pub fn slotAt(y_px: f64, header_height_px: u32, rows: []const Row, card_slot_h: u32, header_row_h: u32, scroll_offset_px: u32) ?usize {
    if (rows.len == 0 or !std.math.isFinite(y_px)) return null;
    const h: f64 = @floatFromInt(header_height_px);
    if (y_px < h) return null; // 사이드바 헤더(검색바·아이콘) 영역 — row 아님(스크롤 무관, 고정)
    const content = y_px - h + @as(f64, @floatFromInt(scroll_offset_px));
    if (content < 0) return null;
    var acc: f64 = 0;
    for (rows, 0..) |r, i| {
        const rh: f64 = @floatFromInt(rowHeight(r, card_slot_h, header_row_h));
        if (rh <= 0) continue;
        if (content < acc + rh) return i;
        acc += rh;
    }
    return null; // 콘텐츠 아래 빈 영역
}

// ── 가변 높이 프리미티브(SG3b — 헤더=얇은 한 줄 header_row_h, 카드=card_slot_h; docs/sidebar-groups.md §5) ──────
// 헤더 row가 카드보다 낮으므로 y↔row를 고정 나눗셈이 아니라 **각 row 높이를 누적**해 환산한다. slotAt/dragTargetSlot가
// 위에서 이 누적을 쓰고, 옛 고정 slotTop(index*slot_h)은 rowTop으로 대체됐다(app_session의 배지·rename caret도 rowTop 사용).

/// row 하나의 세로 높이(px). 카드=card_slot_h, 그룹 헤더=header_row_h(얇은 한 줄). 가변 누적의 단위.
pub fn rowHeight(row: Row, card_slot_h: u32, header_row_h: u32) u32 {
    return switch (row) {
        .card => card_slot_h,
        .group_header => header_row_h,
    };
}

/// row 인덱스의 화면 상단 y(backing px) — 옛 slotTop의 가변판(고정 `index*slot_h` 대신 앞 row 높이 누적).
/// header + Σ(rows[0..index] 높이) − scroll. index≥rows.len이면 전체 콘텐츠 하단(모든 row 합) 기준. i64라 음수(위로 밀림) 안전.
pub fn rowTop(rows: []const Row, index: usize, header_height_px: u32, card_slot_h: u32, header_row_h: u32, scroll_offset_px: u32) i64 {
    var off: i64 = 0;
    const n = @min(index, rows.len);
    for (rows[0..n]) |r| off += @as(i64, rowHeight(r, card_slot_h, header_row_h));
    return @as(i64, header_height_px) + off - @as(i64, scroll_offset_px);
}

/// 표시 콘텐츠 전체 높이(px) — 모든 row 높이 합(옛 `rows.len*slot_h`의 가변판). 세로 스크롤 clamp(sidebarMaxScroll)용.
/// u32 포화(비현실적으로 많은 row에서도 trap 없이 상한)로 clamp 계산이 degenerate하지 않게 한다.
pub fn contentHeight(rows: []const Row, card_slot_h: u32, header_row_h: u32) u32 {
    var acc: u64 = 0;
    for (rows) |r| acc += rowHeight(r, card_slot_h, header_row_h);
    return @intCast(@min(acc, @as(u64, std.math.maxInt(u32))));
}

/// 헤더 줄0 우측 **단일-셀 아이콘**의 glyph col(우측부터 +·⚙·◧). render(buildSidebarHeaderFrame)·단축키 배지가 같은
/// col을 쓰게 하는 단일 출처(예전엔 cols-2/-5/-8을 곳곳에 하드코딩). hit-test(headerHit)는 글리프 col이 아니라 **zone
/// 경계**(cols-3/-6/-9)를 별도로 둔다(클릭 영역은 글리프보다 넓다 — 의도적 분리).
/// 알림 종(🔔)은 EAW 2칸 이모지라 별도 경로(appendBellAndBadge, 좌단 cols-12). 우측 1칸(cols-1)은 패딩.
pub const HeaderIcon = enum { new_workspace, view_options, toggle_sidebar };
pub fn headerIconCol(icon: HeaderIcon, cols: u32) u32 {
    return switch (icon) {
        .new_workspace => cols - 2,
        .view_options => cols - 5,
        .toggle_sidebar => cols - 8,
    };
}

/// 헤더 줄 수(신호등 높이 흡수). render(buildSidebarHeaderFrame)·IME caret(sidebarSearchCaretRect)·hit-test(headerHit)가
/// 같은 값을 써야 아이콘·검색 glyph·caret·클릭 영역이 같은 줄에 놓인다(§5.4 단일 레이아웃 소스 — 셋이 따로 계산하면 어긋난다).
/// 아이콘은 줄0, 검색은 마지막 줄(headerRows-1), 사이 줄은 비운다.
pub fn headerRows(header_height_px: u32, cell_height_px: u32) u32 {
    if (cell_height_px == 0) return 2;
    return @max(@as(u32, 2), header_height_px / cell_height_px);
}

/// 사이드바 상단 헤더([0, header_h) 영역)의 어느 부분을 가리키는가. **아이콘 줄(row 0)**: 우측 아이콘 4개(셀 col
/// cols-2=새 워크스페이스, cols-5=view options, cols-8=사이드바 접기, cols-11=알림 종(EAW 2칸이라 cols-11·cols-10 점유)),
/// 좌측은 네이티브 신호등
/// (닫기·최소화·확대) 영역이라 none(macOS가 클릭 소비). **검색 줄(마지막 줄)**: 전체 폭 검색 입력. 사이 빈 줄·헤더 밖·
/// 폭/cell 0·비유한·cols<13(아이콘 4개가 안 들어감)은 none. 영역 경계는 buildSidebarHeaderFrame이 glyph를 그리는 cell
/// row/col(floor cols)과 정확히 같게 잡는다 — 안 그리면 hit-test도 none(그려진 것=클릭되는 것 단일 출처).
pub const HeaderRegion = enum { none, search, view_options, new_workspace, toggle_sidebar, notifications };
pub fn headerHit(x_px: f64, y_px: f64, sidebar_width_px: u32, cell_width_px: u32, cell_height_px: u32, header_height_px: u32) HeaderRegion {
    if (header_height_px == 0 or sidebar_width_px == 0 or cell_width_px == 0 or cell_height_px == 0) return .none;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return .none;
    const h: f64 = @floatFromInt(header_height_px);
    if (y_px < 0 or y_px >= h) return .none;
    if (x_px < 0 or x_px >= @as(f64, @floatFromInt(sidebar_width_px))) return .none;
    const cw: f64 = @floatFromInt(cell_width_px);
    const ch: f64 = @floatFromInt(cell_height_px);
    const cols: u32 = sidebar_width_px / cell_width_px; // buildSidebarHeaderFrame과 같은 floor — 아이콘 col 정합
    if (cols < 13) return .none; // 헤더 glyph 4개(종·◧·⚙·+)가 안 들어가는 폭 — 안 그리면 hit-test도 none(단일 출처)
    const search_row: u32 = headerRows(header_height_px, cell_height_px) - 1;
    if (y_px >= @as(f64, @floatFromInt(search_row)) * ch) return .search; // 마지막 줄 = 검색(그려진 🔍/입력 줄)
    if (y_px >= ch) return .none; // 아이콘 줄(0)과 검색 줄 사이 빈 줄
    if (x_px >= @as(f64, @floatFromInt(cols - 3)) * cw) return .new_workspace; // 줄0 우측, 그려진 '+' col(cols-2) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 6)) * cw) return .view_options; // 그려진 ⚙ col(cols-5) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 9)) * cw) return .toggle_sidebar; // 그려진 ◧ col(cols-8) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 12)) * cw) return .notifications; // 그려진 종(cols-11·cols-10)+배지(cols-12) 포함 3칸 zone[cols-12,cols-9)
    return .none; // 줄0 좌측 = 네이티브 신호등 영역(클릭은 macOS가 소비) 또는 빈 영역
}

/// x가 사이드바 슬롯의 닫기(✕) zone(우측 2칸) 안인가 — 호버 시 ✕를 그 자리에 그리므로 그 폭만큼을 닫기 영역으로 본다.
pub fn closeButton(x_px: f64, sidebar_width_px: u32, cell_width_px: u32) bool {
    if (sidebar_width_px == 0 or cell_width_px == 0) return false;
    const width: f64 = @floatFromInt(sidebar_width_px);
    const zone: f64 = @as(f64, @floatFromInt(cell_width_px)) * 2.0;
    return x_px >= width - zone and x_px < width;
}

/// 드래그 중 사이드바 y → 타겟 row(항상 valid 인덱스로 clamp — slotAt과 달리 row 아래 빈 영역도 마지막 row로 본다,
/// 드래그를 끝까지 끌 수 있게). rows 0·비유한이면 0. scroll_offset_px는 slotAt과 같은 의미(콘텐츠가 위로 밀린 양) —
/// 콘텐츠 좌표 content=(y-header+scroll)로 각 row 높이를 누적하며 역산하고, content<=0(헤더/그 위)이면 첫 row로 본다.
/// 가변 높이(카드=card_slot_h·헤더=header_row_h)라 slotAt과 같은 누적을 쓴다.
pub fn dragTargetSlot(y_px: f64, header_height_px: u32, rows: []const Row, card_slot_h: u32, header_row_h: u32, scroll_offset_px: u32) usize {
    if (rows.len == 0 or !std.math.isFinite(y_px)) return 0;
    const h: f64 = @floatFromInt(header_height_px);
    const content = y_px - h + @as(f64, @floatFromInt(scroll_offset_px));
    if (content <= 0) return 0;
    var acc: f64 = 0;
    for (rows, 0..) |r, i| {
        acc += @as(f64, @floatFromInt(rowHeight(r, card_slot_h, header_row_h)));
        if (content < acc) return i;
    }
    return rows.len - 1;
}

// ── view (밴드 fill — 옛 rebuildSidebar 대체) ──────────────────────────────────────

/// 사이드바 밴드(활성 슬롯·호버 슬롯·"+" 호버)를 fill op으로 `out`에 emit한다. 슬롯 r 밴드 = (0, r×slot_h, width,
/// slot_h). **slot_height_px는 cell 높이가 아니다**(= cell_h × ratio, 더 크다) — platform이 `sidebar_slot_height_px`를
/// 넘긴다. strip 배경·제목 glyph는 platform이 따로(밴드만 chrome). 활성 우선(활성 슬롯은 호버여도 활성 색). tabs
/// 빈(사이드바 꺼짐)이거나 메트릭 0이면 무동작. 순수: tabs·hover 상태만 읽는다. out·op은 호출자 frame arena 소유.
pub fn view(rows: []const Row, hovered_slot: ?usize, drop_slot: ?usize, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const w = p.metrics.sidebar_width_px;
    const slot_h = p.metrics.sidebar_slot_height_px;
    const header_row_h = p.metrics.sidebar_header_row_h_px;
    if (w == 0 or slot_h == 0 or rows.len == 0) return;
    // 밴드는 슬롯(row) **상대** 좌표(= 앞선 row 높이 누적 rowTop, 헤더·스크롤 제외)로 낸다 — **가변 높이**라 고정
    // row*slot_h가 아니라 각 row 높이(카드=slot_h·그룹 헤더=header_row_h)를 누적해야 그룹 헤더가 낮은 높이를 반영한다
    // (SG3b-2-ii-e — code-review 잔여). platform lowerSidebar는 이 상대 y로 row를 역산할 때 같은 누적을 쓰고(rowTop 역),
    // 헤더(검색바·아이콘)만큼의 절대 시프트는 .m이 사이드바 셀 py_top에 더한다(sidebar_header_height_px 단일 책임).

    // 그룹 헤더 밴드(SG3·SG5-2 — 색 있을 때만): 기본(무색) 헤더는 **밴드 없이 화살표+이름만** 남긴다(보더라인 제거 —
    // 사용자 결정, docs/sidebar-groups.md §5). 그룹 색이 지정된 헤더(has_color)만 얇은 한 줄(header_row_h) 밴드를 내고
    // lowerSidebar가 그 밴드 색에 그룹 색을 tint해 색 구분을 유지한다(삼각+이름 glyph는 platform이 그 위에 올린다).
    // hover/active 밴드(아래)는 has_color 무관하게 그대로 — 상호작용 피드백은 보더라인이 아니라 카드와 같은 하이라이트다.
    for (rows, 0..) |r, i| switch (r) {
        .group_header => |h| if (h.has_color) try out.append(arena, bandFill(rows, i, w, slot_h, header_row_h, .tab_hover_bg, p.shape)),
        .card => {},
    };

    // 활성 슬롯 밴드(첫 active=true 카드 row). group_header row는 활성 대상이 아니다.
    var active_idx: ?usize = null;
    for (rows, 0..) |r, i| switch (r) {
        .card => |c| if (c.active) {
            active_idx = i;
            break;
        },
        .group_header => {},
    };
    if (active_idx) |ai| {
        try out.append(arena, bandFill(rows, ai, w, slot_h, header_row_h, .tab_active_bg, p.shape)); // 카드 배경 밴드
        // 좌측 accent 막대는 여기서 내지 않는다 — 막대색이 카드별(우클릭 "바: …", tab.accent_color)이라 role 기반
        // chrome op으로 임의 RGB를 실을 수 없어, 배경 tint와 같은 이유로 **platform이 카드별 GpuQuad로 직접 그린다**
        // (app_session rebuildSidebar의 per-tab accent 루프 — 활성=기본 앰버/지정색, 비활성=지정 시에만). 카드 폭 inset과
        // 텍스트 좌측 여백은 여전히 tokens.space.accent_bar_width_px(=막대 폭)로 예약된다(밴드 위 정합·단일 출처).
    }

    // 호버 슬롯 밴드(활성과 다르고 범위 안일 때만 — 활성이면 활성 색 우선). 슬롯은 row 인덱스라 헤더/카드 무관하게 칠한다.
    if (hovered_slot) |hs| {
        if (hs < rows.len and (active_idx == null or hs != active_idx.?)) {
            // 카드·무색 헤더는 .tab_hover_bg 호버 밴드. **색 지정 그룹 헤더**는 위 색 밴드 루프가 이미 .tab_hover_bg
            // 밴드를 깔아, 같은 role 호버 밴드를 겹치면 lowerSidebar가 둘 다 같은 그룹색으로 tint해 byte-identical →
            // 호버 피드백이 안 보인다(code-review #4). 한 단계 밝은 .tab_active_bg로 오버레이해 카드처럼 하이라이트가
            // 나게 한다(docs/sidebar-groups.md §5 "hover=카드와 같은 하이라이트"; 무색 헤더·카드는 .tab_hover_bg 유지 = 회귀 없음).
            const hover_role: tokens.ColorRole = switch (rows[hs]) {
                .group_header => |gh| if (gh.has_color) .tab_active_bg else .tab_hover_bg,
                .card => .tab_hover_bg,
            };
            try out.append(arena, bandFill(rows, hs, w, slot_h, header_row_h, hover_role, p.shape));
        }
    }

    // 드롭 타겟 하이라이트 밴드(pane grip 드래그 중에만 platform이 슬롯을 준다) — 활성/호버 위에 .drop_zone 색으로
    // 그린다. drop_slot < rows.len이면 합칠 카드, == rows.len이면 카드 목록 아래 행('새 워크스페이스'). 범위 검사 없이
    // 그 행에 밴드를 낸다(카드 아래 행도 유효 — platform이 드래그 중에만, 그리고 자기 카드는 제외해 넘긴다).
    if (drop_slot) |ds| {
        try out.append(arena, bandFill(rows, ds, w, slot_h, header_row_h, .drop_zone, p.shape));
    }
}

/// row의 전체-폭 밴드 fill op. row→y는 **앞선 row 높이 누적**(rowTop의 헤더·스크롤 제외분 = 슬롯 상대) — 가변
/// 높이(카드=slot_h·헤더=header_row_h)라 고정 row*slot_h가 아니다. row==rows.len(카드 목록 아래 새 워크스페이스 행)이면
/// 콘텐츠 하단·카드 높이로 둔다. platform lowerSidebar가 같은 누적으로 row를 역산해 tint를 얹고(.m이 header_h를 더해 절대
/// y를 맞춘다 — 헤더 시프트는 .m 단일 책임).
fn bandFill(rows: []const Row, row: usize, w: u32, slot_h: u32, header_row_h: u32, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    const top: i64 = rowTop(rows, row, 0, slot_h, header_row_h, 0); // 슬롯 상대(헤더·스크롤 제외), ≥0
    const rh: u32 = if (row < rows.len) rowHeight(rows[row], slot_h, header_row_h) else slot_h; // 목록 아래 행=카드 높이
    // U2: 슬롯 rect에서 사방 card_gap을 inset(content rect)으로 빼 카드 사이 여백을 둔다(선언적 패딩 — 좌표 산술 대신).
    // tui(gap=0)면 inset 0이라 슬롯 꽉(기존과 동일).
    const slot = draw.Rect{ .x = 0, .y = @intCast(top), .w = w, .h = rh };
    const g = shape.card_gap_px;
    const card = slot.inset(.{ .left = g, .right = g, .top = g, .bottom = g });
    const r = shape.corner_radius_px;
    // tui(r=0)면 lowerSidebar가 셀 밴드로, rich(r>0)면 GPU quad(둥근)로 lower한다 — 같은 op, 토큰만 다름.
    return .{ .quad = .{ .rect = card, .fill_role = role, .corner_radii = .{ r, r, r, r } } };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "sidebar hit-test: inSidebar·onResizeEdge·slotAt·headerHit·closeButton·dragTargetSlot 경계" {
    // inSidebar: [0, w).
    try std.testing.expect(inSidebar(50, 100));
    try std.testing.expect(!inSidebar(100, 100)); // 경계 밖(반열림)
    try std.testing.expect(!inSidebar(-1, 100));
    try std.testing.expect(!inSidebar(50, 0)); // 폭 0(꺼짐)
    // onResizeEdge: [w, w + cw/2+2). w=100, cw=8 → [100, 106).
    try std.testing.expect(onResizeEdge(100, 100, 8));
    try std.testing.expect(onResizeEdge(105, 100, 8));
    try std.testing.expect(!onResizeEdge(106, 100, 8)); // 밴드 밖
    try std.testing.expect(!onResizeEdge(99, 100, 8)); // 사이드바 안쪽
    try std.testing.expect(!onResizeEdge(105, 100, 0)); // cell 0 → false(렌더 전; platform이 placeholder 적용)
    try std.testing.expect(!onResizeEdge(std.math.nan(f64), 100, 8)); // 비유한
    // slotAt: 가변 높이 누적. 카드만 rows(card_h=16·header_h 무관)로 옛 고정 동작을 그대로 재현(동작 보존).
    const vcard = Row{ .card = .{ .tab = 0, .label = "", .active = false } };
    const v3 = [_]Row{ vcard, vcard, vcard };
    const v5 = [_]Row{ vcard, vcard, vcard, vcard, vcard };
    const v0 = [_]Row{};
    // header=0: content=y, row는 누적으로. card_h=16, 3장.
    try std.testing.expectEqual(@as(?usize, 0), slotAt(8, 0, &v3, 16, 16, 0));
    try std.testing.expectEqual(@as(?usize, 2), slotAt(40, 0, &v3, 16, 16, 0)); // 2번 row
    try std.testing.expectEqual(@as(?usize, null), slotAt(48, 0, &v3, 16, 16, 0)); // row 아래 빈 영역(3*16=48)
    try std.testing.expectEqual(@as(?usize, null), slotAt(8, 0, &v0, 16, 16, 0)); // 카드 없음
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 0, &v3, 0, 0, 0)); // 높이 0(모든 row skip)
    try std.testing.expectEqual(@as(?usize, null), slotAt(std.math.nan(f64), 0, &v3, 16, 16, 0)); // 비유한
    // header=20: 헤더 영역(y<20)은 null, row는 (y-20) 누적.
    try std.testing.expectEqual(@as(?usize, null), slotAt(10, 20, &v3, 16, 16, 0)); // 헤더 영역
    try std.testing.expectEqual(@as(?usize, 0), slotAt(20, 20, &v3, 16, 16, 0)); // 헤더 직후 = row0
    try std.testing.expectEqual(@as(?usize, 1), slotAt(40, 20, &v3, 16, 16, 0)); // (40-20)/16=1
    // 스크롤: 콘텐츠가 scroll만큼 위로 밀려 화면 같은 y가 더 아래 row를 가리킨다(header=20, card_h=16, 5장).
    try std.testing.expectEqual(@as(?usize, 1), slotAt(20, 20, &v5, 16, 16, 16)); // 헤더 직후 + scroll 16 = row1
    try std.testing.expectEqual(@as(?usize, 3), slotAt(40, 20, &v5, 16, 16, 32)); // (20+32)/16=3
    try std.testing.expectEqual(@as(?usize, null), slotAt(15, 20, &v5, 16, 16, 16)); // 헤더 영역은 scroll 무관 null(고정)
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 20, &v5, 16, 16, 64)); // (20+64)/16=5 ≥ 5장 → null
    // headerHit(2줄, ch=10, header=20 → rows=2, search_row=1): row0=아이콘 줄, row1(y≥10)=검색 줄. w=160,cw=8 → cols=20.
    // 우측 아이콘 4개 zone(3칸씩): new_workspace=col cols-2(x≥(cols-3)cw=136), view_options=cols-5(x≥112),
    // toggle_sidebar=cols-8(x≥88), notifications zone[cols-12,cols-9)=x≥64(종 글리프 cols-11·cols-10, 배지 cols-12 포함).
    // 좌측(<64)=신호등 영역(none).
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 15, 160, 8, 10, 20)); // 검색 줄(y≥10)
    try std.testing.expectEqual(HeaderRegion.new_workspace, headerHit(150, 5, 160, 8, 10, 20)); // 줄0 우측 [136,160)
    try std.testing.expectEqual(HeaderRegion.view_options, headerHit(120, 5, 160, 8, 10, 20)); // 줄0 ⚙ [112,136)
    try std.testing.expectEqual(HeaderRegion.toggle_sidebar, headerHit(95, 5, 160, 8, 10, 20)); // 줄0 ◧ [88,112)
    try std.testing.expectEqual(HeaderRegion.notifications, headerHit(70, 5, 160, 8, 10, 20)); // 줄0 종 [64,88)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 5, 160, 8, 10, 20)); // 줄0 좌측 = 신호등 영역(<64)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 25, 160, 8, 10, 20)); // 헤더 밖(y≥20)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 10, 160, 8, 10, 0)); // 헤더 없음
    // 3줄 헤더(ch=10, header=30 → rows=3, search_row=2): row0=아이콘, row1=빈 줄(none), row2(y≥20)=검색.
    try std.testing.expectEqual(HeaderRegion.new_workspace, headerHit(150, 5, 160, 8, 10, 30)); // 줄0 아이콘
    try std.testing.expectEqual(HeaderRegion.none, headerHit(150, 15, 160, 8, 10, 30)); // 빈 가운데 줄(아이콘 col이어도 none)
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 25, 160, 8, 10, 30)); // 검색 줄(y≥20)
    // cols<13(너무 좁아 아이콘 4개가 안 들어감)이면 헤더 glyph가 안 그려지므로 클릭 무시(검색 무단 활성 방지).
    try std.testing.expectEqual(HeaderRegion.none, headerHit(50, 15, 96, 8, 10, 20)); // w=96,cw=8 → cols=12<13
    try std.testing.expectEqual(HeaderRegion.none, headerHit(35, 15, 40, 8, 10, 20)); // w=40,cw=8 → cols=5<13
    // closeButton: [w-2cw, w). w=100, cw=8 → [84, 100).
    try std.testing.expect(closeButton(90, 100, 8));
    try std.testing.expect(!closeButton(83, 100, 8));
    // dragTargetSlot(header=0): 항상 clamp. 아래 빈 영역도 마지막 row(가변 누적, 카드만=균일). v3/v5/v0 재사용.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(999, 0, &v3, 16, 16, 0)); // 끝으로 clamp
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(8, 0, &v3, 16, 16, 0));
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(50, 0, &v0, 16, 16, 0)); // 카드 없음 → 0
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(25, 20, &v3, 16, 16, 0)); // header=20: (25-20)/16=0
    // 스크롤: content=(y-header+scroll). header=20, card_h=16, 5장.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(25, 20, &v5, 16, 16, 32)); // (5+32)/16=2
    try std.testing.expectEqual(@as(usize, 4), dragTargetSlot(999, 20, &v5, 16, 16, 32)); // 끝으로 clamp(scroll 무관)
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(10, 20, &v5, 16, 16, 0)); // 헤더 위(content<0) → 0
}

test "sidebar view: 활성·호버·+ 밴드 fill(우선순위·좌표·role)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 120,
            .sidebar_slot_height_px = 40, // = cell_h × ratio(예: 16×2.5), cell 높이가 아님
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    };
    const rows = [_]Row{
        .{ .card = .{ .tab = 0, .label = "1 sh", .active = false } },
        .{ .card = .{ .tab = 1, .label = "2 vim", .active = true } },
        .{ .card = .{ .tab = 2, .label = "3 top", .active = false } },
    };

    // 활성(idx 1) + 호버(idx 0) → 밴드 2개(header_h=0, 하단 "+" 밴드는 헤더 아이콘으로 이동해 폐기).
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&rows, 0, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // 활성: row 1 → y=40, role tab_active_bg, 전체 폭.
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[0].quad.fill_role == .tab_active_bg);
    try std.testing.expectEqual(@as(i32, 40), out.items[0].quad.rect.y);
    try std.testing.expectEqual(@as(u32, 120), out.items[0].quad.rect.w);
    try std.testing.expectEqual(@as(u32, 40), out.items[0].quad.rect.h);
    // p.shape 기본(tui) → corner_radii 0(직각 → lowering이 셀 밴드로).
    try std.testing.expectEqual(@as(u16, 0), out.items[0].quad.corner_radii[0]);
    // 호버: row 0 → y=0, tab_hover_bg.
    try std.testing.expect(out.items[1].quad.fill_role == .tab_hover_bg);
    try std.testing.expectEqual(@as(i32, 0), out.items[1].quad.rect.y);

    // 호버 슬롯 == 활성이면 호버 밴드 생략(활성 색 우선).
    out.clearRetainingCapacity();
    try view(&rows, 1, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성만

    // 드롭 타겟 하이라이트: drop_slot 주면 활성/호버 위에 .drop_zone 밴드 추가(pane grip 드래그 중 platform이 준다).
    out.clearRetainingCapacity();
    try view(&rows, null, 0, p, arena, &out); // 활성(idx1) + 드롭(slot 0)
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[1].quad.fill_role == .drop_zone);
    try std.testing.expectEqual(@as(i32, 0), out.items[1].quad.rect.y); // slot 0
    // drop_slot == rows.len이면 카드 목록 아래 행(새 워크스페이스) — 범위 밖 행도 밴드를 낸다.
    out.clearRetainingCapacity();
    try view(&rows, null, rows.len, p, arena, &out);
    const last = out.items[out.items.len - 1].quad;
    try std.testing.expect(last.fill_role == .drop_zone);
    try std.testing.expectEqual(@as(i32, 3 * 40), last.rect.y); // row 3(카드 아래) = rows.len × slot_h

    // 사이드바 꺼짐(폭 0)·slot_h 0·탭 없음이면 무동작.
    out.clearRetainingCapacity();
    var off = p;
    off.metrics.sidebar_width_px = 0;
    try view(&rows, null, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    off = p;
    off.metrics.sidebar_slot_height_px = 0;
    try view(&rows, 0, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // rich shape(corner_radius>0): 같은 밴드가 둥근 quad로(radii 실림 → lowering이 GPU quad). tui와 같은 view 코드.
    out.clearRetainingCapacity();
    var rich_p = p;
    rich_p.shape = .{ .corner_radius_px = 8, .border_width_px = 1 };
    try view(&rows, null, null, rich_p, arena, &out);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expectEqual(@as(u16, 8), out.items[0].quad.corner_radii[0]);

    // 좌측 accent 막대는 chrome이 내지 않는다(카드별 색이라 platform이 GpuQuad로 직접 — app_session per-tab accent 루프).
    // card_gap>0이면 카드(밴드)만 슬롯 안쪽 사방 패딩으로 낸다 — 카드 사이 여백. slot_h=40, gap=4.
    out.clearRetainingCapacity();
    var card_p = p;
    card_p.shape = .{ .corner_radius_px = 8, .card_gap_px = 4 };
    try view(&rows, null, null, card_p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성 카드 밴드만(막대 op 없음)
    const card = out.items[0].quad.rect;
    try std.testing.expectEqual(@as(i32, 4), card.x); // 좌 패딩(gap)
    try std.testing.expectEqual(@as(u32, 120 - 8), card.w); // w - 2×gap
    try std.testing.expectEqual(@as(i32, 40 + 4), card.y); // 슬롯1 y(40) + gap
    try std.testing.expectEqual(@as(u32, 40 - 8), card.h); // slot_h - 2×gap
}

test "sidebar view: group_header 밴드 정책 — 무색=밴드 없음(화살표만)·색 있음=tint 밴드·hover 유지(SG5-2/보더라인 제거)" {
    // 헤더 정책(사용자 결정, docs/sidebar-groups.md §5): **기본(무색) 헤더는 밴드(보더라인) 없이** 화살표+이름만 남기고
    // (view가 헤더 row에 아무 밴드 op도 안 냄), 그룹 색이 지정된 헤더(has_color)만 얇은 한 줄(header_row_h) 밴드를 낸다
    // (lowerSidebar가 그 색으로 tint). **hover/active 밴드는 has_color 무관하게 유지** — 상호작용 피드백은 카드와 같은 경로.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 120,
            .sidebar_slot_height_px = 40,
            .sidebar_header_row_h_px = 20, // 그룹 헤더 얇은 한 줄(카드 40보다 낮다)
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    };
    // row0=무색 그룹 헤더(has_color=false), row1=활성 카드(40), row2=비활성 카드(40).
    const rows_nocolor = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "frontend", .member_count = 2, .tab = 0 } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
        .{ .card = .{ .tab = 1, .label = "docs", .active = false } },
    };
    var out: std.ArrayList(draw.Op) = .empty;
    // 무색·비호버: 헤더 밴드 없음 → 활성 카드 밴드(row1)만. 헤더 y=0에는 아무 밴드도 안 난다(보더라인 제거).
    try view(&rows_nocolor, null, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성 카드 밴드만(헤더 기본 밴드 없음)
    try std.testing.expect(out.items[0].quad.fill_role == .tab_active_bg);
    try std.testing.expectEqual(@as(i32, 20), out.items[0].quad.rect.y); // row1 y=header_row_h(20) 가변 누적
    try std.testing.expectEqual(@as(u32, 40), out.items[0].quad.rect.h);

    // 색 지정 헤더(has_color=true): 헤더 밴드(row0, y=0, h=20, tab_hover_bg) + 활성 카드 밴드(row1). lowerSidebar가 tint.
    const rows_color = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "frontend", .member_count = 2, .tab = 0, .has_color = true } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
        .{ .card = .{ .tab = 1, .label = "docs", .active = false } },
    };
    out.clearRetainingCapacity();
    try view(&rows_color, null, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 헤더 밴드(row0) + 활성 카드 밴드(row1)
    try std.testing.expect(out.items[0].quad.fill_role == .tab_hover_bg);
    try std.testing.expectEqual(@as(i32, 0), out.items[0].quad.rect.y);
    try std.testing.expectEqual(@as(u32, 20), out.items[0].quad.rect.h); // 헤더 높이(header_row_h)
    try std.testing.expect(out.items[1].quad.fill_role == .tab_active_bg);
    try std.testing.expectEqual(@as(i32, 20), out.items[1].quad.rect.y);

    // 무색 헤더 hover(row0): 기본 밴드가 없어도 호버 밴드는 그대로 난다(카드와 같은 하이라이트 피드백 유지).
    out.clearRetainingCapacity();
    try view(&rows_nocolor, 0, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 활성 카드 밴드(row1) + 헤더 호버 밴드(row0)
    // 호버 밴드는 헤더 row0(y=0)에 tab_hover_bg로 난다 — 그중 하나가 그 조건을 만족해야 한다.
    var saw_header_hover = false;
    for (out.items) |op| {
        if (op.quad.fill_role == .tab_hover_bg and op.quad.rect.y == 0 and op.quad.rect.h == 20) saw_header_hover = true;
    }
    try std.testing.expect(saw_header_hover);

    // 색 지정 헤더 hover(row0, code-review #4): 기본 색 밴드(.tab_hover_bg, row0)와 **다른** role(.tab_active_bg, 한 단계
    // 밝음)의 호버 밴드가 같은 헤더 row에 겹쳐 나야 한다 — 옛 코드는 둘 다 .tab_hover_bg라 byte-identical(호버 무피드백).
    out.clearRetainingCapacity();
    try view(&rows_color, 0, null, p, arena, &out); // 색 헤더(row0) hover, 활성 카드=row1
    var saw_base_color_band = false; // 기본 색 밴드(.tab_hover_bg @ row0)
    var saw_header_hover_active = false; // 호버 밴드(.tab_active_bg @ row0) — 색 위 오버레이로 시각 변화
    for (out.items) |op| {
        if (op.quad.rect.y == 0 and op.quad.rect.h == 20) {
            if (op.quad.fill_role == .tab_hover_bg) saw_base_color_band = true;
            if (op.quad.fill_role == .tab_active_bg) saw_header_hover_active = true;
        }
    }
    try std.testing.expect(saw_base_color_band); // 색 밴드 유지(색 구분)
    try std.testing.expect(saw_header_hover_active); // 호버가 색과 다른 role로 나 시각 변화가 생긴다
}

test "sidebar onGroupHeader: 헤더 row만 true(카드·범위 밖 false)" {
    const rows = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 1, .tab = 0 } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
    };
    try std.testing.expect(onGroupHeader(&rows, 0)); // 헤더 row
    try std.testing.expect(!onGroupHeader(&rows, 1)); // 카드 row
    try std.testing.expect(!onGroupHeader(&rows, 2)); // 범위 밖
}

test "sidebar 가변 높이: rowHeight·rowTop·contentHeight(혼합 누적 + 카드만=균일 동작 보존)" {
    // 가변 높이(§5): 헤더=header_row_h(얇은 한 줄), 카드=card_slot_h. y↔row를 고정 나눗셈이 아니라 누적으로 환산한다.
    // 핵심: **카드만이면 가변 rowTop이 옛 고정 slotTop과 정확히 같다** — SG3a 이주가 그룹 없는 현재 동작을 보존함을 증명.
    const card = Row{ .card = .{ .tab = 0, .label = "c", .active = false } };
    const hdr = Row{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 0, .tab = 0 } };
    // rowHeight: 종류별 높이(card=40, header=16).
    try std.testing.expectEqual(@as(u32, 40), rowHeight(card, 40, 16));
    try std.testing.expectEqual(@as(u32, 16), rowHeight(hdr, 40, 16));

    // 혼합 [헤더(16), 카드(40), 카드(40)], header_px=0, scroll=0: 누적 상단 y.
    const mixed = [_]Row{ hdr, card, card };
    try std.testing.expectEqual(@as(i64, 0), rowTop(&mixed, 0, 0, 40, 16, 0)); // 헤더 상단
    try std.testing.expectEqual(@as(i64, 16), rowTop(&mixed, 1, 0, 40, 16, 0)); // 헤더(16) 뒤
    try std.testing.expectEqual(@as(i64, 56), rowTop(&mixed, 2, 0, 40, 16, 0)); // 16+40
    try std.testing.expectEqual(@as(i64, 96), rowTop(&mixed, 3, 0, 40, 16, 0)); // 16+40+40 = 콘텐츠 하단
    try std.testing.expectEqual(@as(u32, 96), contentHeight(&mixed, 40, 16));

    // header_height_px·scroll 반영: header=20, scroll=10.
    try std.testing.expectEqual(@as(i64, 10), rowTop(&mixed, 0, 20, 40, 16, 10)); // 20-10
    try std.testing.expectEqual(@as(i64, 26), rowTop(&mixed, 1, 20, 40, 16, 10)); // 20+16-10

    // 카드만 → 가변 rowTop == 옛 고정 공식(header + index*card_h − scroll). header=20, card_h=40, scroll=5.
    const cards = [_]Row{ card, card, card };
    try std.testing.expectEqual(@as(i64, 20 + 2 * 40 - 5), rowTop(&cards, 2, 20, 40, 16, 5)); // = 95
    try std.testing.expectEqual(@as(i64, 20 - 5), rowTop(&cards, 0, 20, 40, 16, 5)); // = 15
    try std.testing.expectEqual(@as(u32, 120), contentHeight(&cards, 40, 16)); // 3*40(카드만이라 header_row_h 무관)

    // 빈 rows: rowTop=header-scroll, contentHeight=0.
    const empty = [_]Row{};
    try std.testing.expectEqual(@as(i64, 20), rowTop(&empty, 0, 20, 40, 16, 0));
    try std.testing.expectEqual(@as(u32, 0), contentHeight(&empty, 40, 16));
}
