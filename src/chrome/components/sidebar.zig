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

/// host가 주입하는 중립 워크스페이스 탭(라벨·활성). 라벨 glyph 렌더는 platform(`buildSidebarTitleFrame`)이 맡고
/// (CoreText 경계), chrome은 밴드(fill)·hit-test만 — label은 제목 glyph 완전 이주(후속) 시 view가 text op으로 쓸 자리다.
pub const Tab = struct { label: []const u8, active: bool };

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

/// 사이드바 y(backing px) → 탭 슬롯 인덱스((y-header+scroll) / slot_height). 헤더(검색바·아이콘) 영역 y<header,
/// 슬롯 높이 0·탭 0·비유한·범위 밖이면 null(@intFromFloat 전에 [0, count) 검사로 OOB cast trap 방지).
/// header_height_px=0이면 헤더 없음(기존 동작 — 슬롯이 y=0부터).
/// scroll_offset_px는 사이드바 세로 스크롤량 — 카드가 그만큼 위로 밀려 있으므로 화면 y의 슬롯은 콘텐츠 좌표
/// (y-header+scroll)로 역산한다. 헤더는 스크롤과 무관하게 고정이라 y<header 판정엔 scroll을 안 더한다("보이는=클릭되는").
pub fn slotAt(y_px: f64, header_height_px: u32, slot_height_px: u32, scroll_offset_px: u32, tab_count: usize) ?usize {
    if (slot_height_px == 0 or tab_count == 0 or !std.math.isFinite(y_px)) return null;
    const h: f64 = @floatFromInt(header_height_px);
    if (y_px < h) return null; // 헤더(검색바·아이콘) 영역 — 슬롯 아님(스크롤 무관, 고정)
    const slot_f = (y_px - h + @as(f64, @floatFromInt(scroll_offset_px))) / @as(f64, @floatFromInt(slot_height_px));
    if (slot_f >= @as(f64, @floatFromInt(tab_count))) return null;
    return @intFromFloat(slot_f);
}

/// 슬롯 인덱스 i의 화면 상단 y(backing px) — slotAt(y→i)의 **역**(i→y). 카드 rect·드롭 인디케이터·단축키 배지가
/// 같은 식을 쓰게 하는 단일 출처(인라인 중복 금지). scroll로 위로 밀린 콘텐츠 좌표를 화면 y로 환산: header + i*slot_h
/// − scroll(헤더 위로 밀리면 음수 — 호출자가 헤더 아래로 clamp하거나 보임 판정). i64라 큰 인덱스/스크롤에도 안전.
pub fn slotTop(index: usize, header_height_px: u32, slot_height_px: u32, scroll_offset_px: u32) i64 {
    return @as(i64, header_height_px) + @as(i64, @intCast(index)) * @as(i64, slot_height_px) - @as(i64, scroll_offset_px);
}

/// 헤더 줄0 우측 **단일-셀 아이콘**의 glyph col(우측부터 +·⚙·◧). render(buildSidebarHeaderFrame)·hit-test 영역·단축키
/// 배지가 같은 col을 쓰게 하는 단일 출처(예전엔 cols-2/-5/-8을 곳곳에 하드코딩 — 어긋나면 그려진 위치와 안 맞는다).
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

/// 드래그 중 사이드바 y → 타겟 슬롯(항상 valid 인덱스로 clamp — slotAt과 달리 슬롯 아래 빈 영역도 마지막 슬롯으로
/// 본다, 드래그를 끝까지 끌 수 있게). 슬롯 높이/탭 0이면 0. scroll_offset_px는 slotAt과 같은 의미(콘텐츠가 위로
/// 밀린 양) — 콘텐츠 좌표 rel=(y-header+scroll)로 슬롯을 역산하고, rel<=0(헤더/그 위)이면 첫 슬롯으로 본다.
pub fn dragTargetSlot(y_px: f64, header_height_px: u32, slot_height_px: u32, scroll_offset_px: u32, tab_count: usize) usize {
    if (slot_height_px == 0 or tab_count == 0 or !std.math.isFinite(y_px)) return 0;
    const h: f64 = @floatFromInt(header_height_px);
    const last = tab_count - 1;
    const rel = y_px - h + @as(f64, @floatFromInt(scroll_offset_px));
    if (rel <= 0) return 0;
    const slot_f = rel / @as(f64, @floatFromInt(slot_height_px));
    if (slot_f >= @as(f64, @floatFromInt(last))) return last;
    return @intFromFloat(slot_f);
}

// ── view (밴드 fill — 옛 rebuildSidebar 대체) ──────────────────────────────────────

/// 사이드바 밴드(활성 슬롯·호버 슬롯·"+" 호버)를 fill op으로 `out`에 emit한다. 슬롯 r 밴드 = (0, r×slot_h, width,
/// slot_h). **slot_height_px는 cell 높이가 아니다**(= cell_h × ratio, 더 크다) — platform이 `sidebar_slot_height_px`를
/// 넘긴다. strip 배경·제목 glyph는 platform이 따로(밴드만 chrome). 활성 우선(활성 슬롯은 호버여도 활성 색). tabs
/// 빈(사이드바 꺼짐)이거나 메트릭 0이면 무동작. 순수: tabs·hover 상태만 읽는다. out·op은 호출자 frame arena 소유.
pub fn view(tabs: []const Tab, hovered_slot: ?usize, drop_slot: ?usize, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const w = p.metrics.sidebar_width_px;
    const slot_h = p.metrics.sidebar_slot_height_px;
    if (w == 0 or slot_h == 0 or tabs.len == 0) return;
    // 밴드는 슬롯 **상대** 좌표(row*slot_h)로 낸다 — platform lowerSidebar가 rect.y/slot_h로 슬롯 행을 역산하므로
    // 헤더 높이를 더하면 그 역산이 깨진다. 헤더(검색바·아이콘)만큼의 시프트는 .m이 사이드바 셀 py_top에 더하고
    // (sidebar_header_height_px), 헤더 높이는 hit-test(slotAt/headerHit)만 안다. 하단 "+" 밴드는 헤더 아이콘으로 이동해 폐기.

    // 활성 슬롯 밴드(첫 active=true 탭).
    var active_idx: ?usize = null;
    for (tabs, 0..) |t, i| if (t.active) {
        active_idx = i;
        break;
    };
    if (active_idx) |ai| {
        try out.append(arena, bandFill(ai, w, slot_h, .tab_active_bg, p.shape)); // 카드 배경 밴드
        // U1: 활성 슬롯 좌측 maru-accent 막대(accent_bar_width>0 — rich). 밴드 뒤에 append → 카드 배경 위에 그려진다.
        // U2: 막대도 카드 content rect(슬롯에서 card_gap inset) 좌단 가장자리에 카드 높이로 붙인다.
        if (p.shape.accent_bar_width_px > 0) {
            const g = p.shape.card_gap_px;
            const slot = draw.Rect{ .x = 0, .y = @intCast(ai * @as(usize, slot_h)), .w = w, .h = slot_h };
            const card = slot.inset(.{ .left = g, .right = g, .top = g, .bottom = g });
            try out.append(arena, .{ .quad = .{ .rect = .{ .x = card.x, .y = card.y, .w = p.shape.accent_bar_width_px, .h = card.h }, .fill_role = .accent_bar, .corner_radii = .{ 0, 0, 0, 0 } } });
        }
    }

    // 호버 슬롯 밴드(활성과 다르고 범위 안일 때만 — 활성이면 활성 색 우선).
    if (hovered_slot) |hs| {
        if (hs < tabs.len and (active_idx == null or hs != active_idx.?)) {
            try out.append(arena, bandFill(hs, w, slot_h, .tab_hover_bg, p.shape));
        }
    }

    // 드롭 타겟 하이라이트 밴드(pane grip 드래그 중에만 platform이 슬롯을 준다) — 활성/호버 위에 .drop_zone 색으로
    // 그린다. drop_slot < tabs.len이면 합칠 카드, == tabs.len이면 카드 목록 아래 행('새 워크스페이스'). 범위 검사 없이
    // 그 행에 밴드를 낸다(카드 아래 행도 유효 — platform이 드래그 중에만, 그리고 자기 카드는 제외해 넘긴다).
    if (drop_slot) |ds| {
        try out.append(arena, bandFill(ds, w, slot_h, .drop_zone, p.shape));
    }
}

/// 슬롯 r의 전체-폭 밴드 fill op. row→y는 slot_h 배수(한 탭=한 슬롯, 슬롯 상대). platform lowerSidebar가
/// sidebarBandCell로 lower하고(.m이 header_h를 더해 절대 y를 맞춘다 — 헤더 시프트는 .m 단일 책임).
fn bandFill(row: usize, w: u32, slot_h: u32, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    // U2: 슬롯 rect에서 사방 card_gap을 inset(content rect)으로 빼 카드 사이 여백을 둔다(선언적 패딩 — 좌표 산술 대신).
    // tui(gap=0)면 inset 0이라 슬롯 꽉(기존과 동일).
    const slot = draw.Rect{ .x = 0, .y = @intCast(row * @as(usize, slot_h)), .w = w, .h = slot_h };
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
    // slotAt(header=0, scroll=0): (y)/slot_h, 범위 밖 null. slot_h=16, count=3 — 기존 동작 보존.
    try std.testing.expectEqual(@as(?usize, 0), slotAt(8, 0, 16, 0, 3));
    try std.testing.expectEqual(@as(?usize, 2), slotAt(40, 0, 16, 0, 3)); // 2번 슬롯
    try std.testing.expectEqual(@as(?usize, null), slotAt(48, 0, 16, 0, 3)); // 슬롯 아래 빈 영역
    try std.testing.expectEqual(@as(?usize, null), slotAt(8, 0, 16, 0, 0)); // 탭 없음
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 0, 0, 0, 3)); // 슬롯 높이 0
    try std.testing.expectEqual(@as(?usize, null), slotAt(std.math.nan(f64), 0, 16, 0, 3)); // 비유한
    // slotAt(header=20, scroll=0): 헤더 영역(y<20)은 null, 슬롯은 (y-20)/16.
    try std.testing.expectEqual(@as(?usize, null), slotAt(10, 20, 16, 0, 3)); // 헤더 영역
    try std.testing.expectEqual(@as(?usize, 0), slotAt(20, 20, 16, 0, 3)); // 헤더 직후 = 슬롯0
    try std.testing.expectEqual(@as(?usize, 1), slotAt(40, 20, 16, 0, 3)); // (40-20)/16=1
    // slotAt 스크롤: 콘텐츠가 scroll만큼 위로 밀려 화면 같은 y가 더 아래 슬롯을 가리킨다(header=20, slot_h=16, count=5).
    try std.testing.expectEqual(@as(?usize, 1), slotAt(20, 20, 16, 16, 5)); // 헤더 직후 + scroll 16 = (0+16)/16=슬롯1
    try std.testing.expectEqual(@as(?usize, 3), slotAt(40, 20, 16, 32, 5)); // (20+32)/16=3
    try std.testing.expectEqual(@as(?usize, null), slotAt(15, 20, 16, 16, 5)); // 헤더 영역은 scroll 무관하게 null(고정)
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 20, 16, 64, 5)); // (20+64)/16=5 ≥ count → null
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
    // dragTargetSlot(header=0, scroll=0): 항상 clamp. 아래 빈 영역도 마지막.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(999, 0, 16, 0, 3)); // 끝으로 clamp
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(8, 0, 16, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(50, 0, 16, 0, 0)); // 탭 없음 → 0
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(25, 20, 16, 0, 3)); // header=20: (25-20)/16=0
    // dragTargetSlot 스크롤: rel=(y-header+scroll). header=20, slot_h=16, count=5.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(25, 20, 16, 32, 5)); // (5+32)/16=2
    try std.testing.expectEqual(@as(usize, 4), dragTargetSlot(999, 20, 16, 32, 5)); // 끝으로 clamp(scroll 무관)
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(10, 20, 16, 0, 5)); // 헤더 위(rel<0) → 0
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
    const tabs = [_]Tab{
        .{ .label = "1 sh", .active = false },
        .{ .label = "2 vim", .active = true },
        .{ .label = "3 top", .active = false },
    };

    // 활성(idx 1) + 호버(idx 0) → 밴드 2개(header_h=0, 하단 "+" 밴드는 헤더 아이콘으로 이동해 폐기).
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&tabs, 0, null, p, arena, &out);
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
    try view(&tabs, 1, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성만

    // 드롭 타겟 하이라이트: drop_slot 주면 활성/호버 위에 .drop_zone 밴드 추가(pane grip 드래그 중 platform이 준다).
    out.clearRetainingCapacity();
    try view(&tabs, null, 0, p, arena, &out); // 활성(idx1) + 드롭(slot 0)
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[1].quad.fill_role == .drop_zone);
    try std.testing.expectEqual(@as(i32, 0), out.items[1].quad.rect.y); // slot 0
    // drop_slot == tabs.len이면 카드 목록 아래 행(새 워크스페이스) — 범위 밖 행도 밴드를 낸다.
    out.clearRetainingCapacity();
    try view(&tabs, null, tabs.len, p, arena, &out);
    const last = out.items[out.items.len - 1].quad;
    try std.testing.expect(last.fill_role == .drop_zone);
    try std.testing.expectEqual(@as(i32, 3 * 40), last.rect.y); // row 3(카드 아래) = tabs.len × slot_h

    // 사이드바 꺼짐(폭 0)·slot_h 0·탭 없음이면 무동작.
    out.clearRetainingCapacity();
    var off = p;
    off.metrics.sidebar_width_px = 0;
    try view(&tabs, null, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    off = p;
    off.metrics.sidebar_slot_height_px = 0;
    try view(&tabs, 0, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // rich shape(corner_radius>0): 같은 밴드가 둥근 quad로(radii 실림 → lowering이 GPU quad). tui와 같은 view 코드.
    out.clearRetainingCapacity();
    var rich_p = p;
    rich_p.shape = .{ .corner_radius_px = 8, .border_width_px = 1 };
    try view(&tabs, null, null, rich_p, arena, &out);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expectEqual(@as(u16, 8), out.items[0].quad.corner_radii[0]);

    // U1: accent_bar_width>0이면 활성 슬롯 밴드 뒤에 좌측 막대 op(폭=accent_bar_width, role accent_bar, x=0).
    out.clearRetainingCapacity();
    var bar_p = p;
    bar_p.shape = .{ .accent_bar_width_px = 3 };
    try view(&tabs, null, null, bar_p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 활성 밴드(idx 1) + 좌측 막대
    try std.testing.expect(out.items[1].quad.fill_role == .accent_bar);
    try std.testing.expectEqual(@as(u32, 3), out.items[1].quad.rect.w); // 막대 폭 3px
    try std.testing.expectEqual(@as(i32, 0), out.items[1].quad.rect.x); // 좌측 가장자리
    try std.testing.expectEqual(@as(i32, 40), out.items[1].quad.rect.y); // 활성 슬롯(idx 1) y = 1×slot_h(40)

    // U2: card_gap>0이면 카드(밴드)·막대가 슬롯 안쪽 사방 패딩으로 — 카드 사이 여백. slot_h=40, gap=4.
    out.clearRetainingCapacity();
    var card_p = p;
    card_p.shape = .{ .corner_radius_px = 8, .accent_bar_width_px = 3, .card_gap_px = 4 };
    try view(&tabs, null, null, card_p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 활성 카드 밴드 + 좌측 막대
    const card = out.items[0].quad.rect;
    try std.testing.expectEqual(@as(i32, 4), card.x); // 좌 패딩(gap)
    try std.testing.expectEqual(@as(u32, 120 - 8), card.w); // w - 2×gap
    try std.testing.expectEqual(@as(i32, 40 + 4), card.y); // 슬롯1 y(40) + gap
    try std.testing.expectEqual(@as(u32, 40 - 8), card.h); // slot_h - 2×gap
    const bar = out.items[1].quad.rect;
    try std.testing.expectEqual(@as(i32, 4), bar.x); // 막대도 카드 좌단(gap)
    try std.testing.expectEqual(@as(u32, 40 - 8), bar.h); // 카드 높이
}
