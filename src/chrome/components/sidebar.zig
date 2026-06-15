//! Sidebar — 세로 워크스페이스 사이드바의 hit-test + 밴드 렌더. chrome **마우스 hit-test 컴포넌트**(divider 동형 —
//! State 없는 순수 함수). 드래그 재정렬이 인덱스 기반(`sidebar_drag_index: usize`)이라 라이브 포인터 부담이
//! divider(`*Split`)보다 적다(§6). host가 중립 `Tab`(라벨·활성)을 주입하고, platform이 라이브 상태(폭·드래그
//! 인덱스·hover)·제목 glyph 렌더(`buildSidebarTitleFrame` — CoreText는 platform 책임)·밴드 fill lowering을 맡는다.
//! 이 컴포넌트는 (1) hit-test 순수 함수(옛 app_dev_session의 xInSidebar 등 이전)와 (2) 밴드 view(활성/호버 fill)를
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

// ── hit-test (옛 app_dev_session 순수 함수 이전, 같은 수학) ────────────────────────

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

/// 사이드바 y(backing px) → 탭 슬롯 인덱스(y / slot_height). 슬롯 높이 0·탭 0·비유한·음수·범위 밖이면 null
/// (@intFromFloat 전에 [0, count) 검사로 OOB cast trap 방지).
pub fn slotAt(y_px: f64, slot_height_px: u32, tab_count: usize) ?usize {
    if (slot_height_px == 0 or tab_count == 0 or !std.math.isFinite(y_px) or y_px < 0) return null;
    const slot_f = y_px / @as(f64, @floatFromInt(slot_height_px));
    if (slot_f >= @as(f64, @floatFromInt(tab_count))) return null;
    return @intFromFloat(slot_f);
}

/// 사이드바 y가 "+"(새 워크스페이스) 버튼 슬롯(탭 목록 바로 아래, 인덱스 tab_count) 안인가 — y in
/// [count×h, (count+1)×h). 밴드/glyph가 그 행에 그려지는 위치와 정렬. 슬롯 높이 0·비유한·음수면 false.
pub fn inPlus(y_px: f64, slot_height_px: u32, tab_count: usize) bool {
    if (slot_height_px == 0 or !std.math.isFinite(y_px) or y_px < 0) return false;
    const slot_f = y_px / @as(f64, @floatFromInt(slot_height_px));
    const tc: f64 = @floatFromInt(tab_count);
    return slot_f >= tc and slot_f < tc + 1;
}

/// x가 사이드바 슬롯의 닫기(✕) zone(우측 2칸) 안인가 — 호버 시 ✕를 그 자리에 그리므로 그 폭만큼을 닫기 영역으로 본다.
pub fn closeButton(x_px: f64, sidebar_width_px: u32, cell_width_px: u32) bool {
    if (sidebar_width_px == 0 or cell_width_px == 0) return false;
    const width: f64 = @floatFromInt(sidebar_width_px);
    const zone: f64 = @as(f64, @floatFromInt(cell_width_px)) * 2.0;
    return x_px >= width - zone and x_px < width;
}

/// 드래그 중 사이드바 y → 타겟 슬롯(항상 valid 인덱스로 clamp — slotAt과 달리 슬롯 아래 빈 영역도 마지막 슬롯으로
/// 본다, 드래그를 끝까지 끌 수 있게). 슬롯 높이/탭 0이면 0.
pub fn dragTargetSlot(y_px: f64, slot_height_px: u32, tab_count: usize) usize {
    if (slot_height_px == 0 or tab_count == 0 or !std.math.isFinite(y_px) or y_px <= 0) return 0;
    const last = tab_count - 1;
    const slot_f = y_px / @as(f64, @floatFromInt(slot_height_px));
    if (slot_f >= @as(f64, @floatFromInt(last))) return last;
    return @intFromFloat(slot_f);
}

// ── view (밴드 fill — 옛 rebuildSidebar 대체) ──────────────────────────────────────

/// 사이드바 밴드(활성 슬롯·호버 슬롯·"+" 호버)를 fill op으로 `out`에 emit한다. 슬롯 r 밴드 = (0, r×slot_h, width,
/// slot_h). **slot_height_px는 cell 높이가 아니다**(= cell_h × ratio, 더 크다) — platform이 `sidebar_slot_height_px`를
/// 넘긴다. strip 배경·제목 glyph는 platform이 따로(밴드만 chrome). 활성 우선(활성 슬롯은 호버여도 활성 색). tabs
/// 빈(사이드바 꺼짐)이거나 메트릭 0이면 무동작. 순수: tabs·hover 상태만 읽는다. out·op은 호출자 frame arena 소유.
pub fn view(tabs: []const Tab, hovered_slot: ?usize, hovered_plus: bool, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const w = p.metrics.sidebar_width_px;
    const slot_h = p.metrics.sidebar_slot_height_px;
    if (w == 0 or slot_h == 0 or tabs.len == 0) return;

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

    // "+"(새 워크스페이스) 호버 밴드 — 탭 목록 바로 아래 행(row=탭 개수).
    if (hovered_plus) try out.append(arena, bandFill(tabs.len, w, slot_h, .tab_hover_bg, p.shape));
}

/// 슬롯 r의 전체-폭 밴드 fill op. row→y는 slot_h 배수(한 탭=한 슬롯). platform lowerSidebar가 sidebarBandCell로 lower.
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

test "sidebar hit-test: inSidebar·onResizeEdge·slotAt·inPlus·closeButton·dragTargetSlot 경계" {
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
    // slotAt: y/slot_h, 범위 밖 null. slot_h=16, count=3.
    try std.testing.expectEqual(@as(?usize, 0), slotAt(8, 16, 3));
    try std.testing.expectEqual(@as(?usize, 2), slotAt(40, 16, 3)); // 2번 슬롯
    try std.testing.expectEqual(@as(?usize, null), slotAt(48, 16, 3)); // 슬롯 아래 빈 영역
    try std.testing.expectEqual(@as(?usize, null), slotAt(8, 16, 0)); // 탭 없음
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 0, 3)); // 슬롯 높이 0
    try std.testing.expectEqual(@as(?usize, null), slotAt(std.math.nan(f64), 16, 3)); // 비유한
    // inPlus: [count×h, (count+1)×h). count=3, h=16 → [48, 64).
    try std.testing.expect(inPlus(50, 16, 3));
    try std.testing.expect(!inPlus(40, 16, 3)); // 탭 슬롯
    try std.testing.expect(!inPlus(64, 16, 3)); // + 아래
    // closeButton: [w-2cw, w). w=100, cw=8 → [84, 100).
    try std.testing.expect(closeButton(90, 100, 8));
    try std.testing.expect(!closeButton(83, 100, 8));
    // dragTargetSlot: 항상 clamp. 아래 빈 영역도 마지막.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(999, 16, 3)); // 끝으로 clamp
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(8, 16, 3));
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(50, 16, 0)); // 탭 없음 → 0
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

    // 활성(idx 1) + 호버(idx 0) + "+" 호버 → 밴드 3개.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&tabs, 0, true, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
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
    // "+": row 3(탭 개수) → y=120.
    try std.testing.expectEqual(@as(i32, 120), out.items[2].quad.rect.y);

    // 호버 슬롯 == 활성이면 호버 밴드 생략(활성 색 우선).
    out.clearRetainingCapacity();
    try view(&tabs, 1, false, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성만

    // 사이드바 꺼짐(폭 0)·slot_h 0·탭 없음이면 무동작.
    out.clearRetainingCapacity();
    var off = p;
    off.metrics.sidebar_width_px = 0;
    try view(&tabs, null, false, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    off = p;
    off.metrics.sidebar_slot_height_px = 0;
    try view(&tabs, 0, true, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // rich shape(corner_radius>0): 같은 밴드가 둥근 quad로(radii 실림 → lowering이 GPU quad). tui와 같은 view 코드.
    out.clearRetainingCapacity();
    var rich_p = p;
    rich_p.shape = .{ .corner_radius_px = 8, .border_width_px = 1 };
    try view(&tabs, null, false, rich_p, arena, &out);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expectEqual(@as(u16, 8), out.items[0].quad.corner_radii[0]);

    // U1: accent_bar_width>0이면 활성 슬롯 밴드 뒤에 좌측 막대 op(폭=accent_bar_width, role accent_bar, x=0).
    out.clearRetainingCapacity();
    var bar_p = p;
    bar_p.shape = .{ .accent_bar_width_px = 3 };
    try view(&tabs, null, false, bar_p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 활성 밴드(idx 1) + 좌측 막대
    try std.testing.expect(out.items[1].quad.fill_role == .accent_bar);
    try std.testing.expectEqual(@as(u32, 3), out.items[1].quad.rect.w); // 막대 폭 3px
    try std.testing.expectEqual(@as(i32, 0), out.items[1].quad.rect.x); // 좌측 가장자리
    try std.testing.expectEqual(@as(i32, 40), out.items[1].quad.rect.y); // 활성 슬롯(idx 1) y = 1×slot_h(40)

    // U2: card_gap>0이면 카드(밴드)·막대가 슬롯 안쪽 사방 패딩으로 — 카드 사이 여백. slot_h=40, gap=4.
    out.clearRetainingCapacity();
    var card_p = p;
    card_p.shape = .{ .corner_radius_px = 8, .accent_bar_width_px = 3, .card_gap_px = 4 };
    try view(&tabs, null, false, card_p, arena, &out);
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
