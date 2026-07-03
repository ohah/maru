//! InputBox — 숫자(수치) 입력 박스 위젯. dropdown/color와 같은 **State 없는 순수 함수 모듈**: 값·편집 버퍼는
//! 셸(settings.State)이 소유하고, 컴포넌트는 control rect + 표시 문자열 + 편집 여부만 받아 **테두리 박스 + 텍스트 +
//! (편집 중) 끝 caret**을 그린다. 슬라이더(진행 막대)를 대체해 사용자가 수치를 직접 타이핑한다(사용자 요청 —
//! 프로그레스바 대신 인풋박스). 커밋 시 파싱·범위 clamp는 platform이 한다(schema.setNumber). 테두리는 dropdown 팝업·
//! color 위젯과 같은 quad 규율(border_width>0이면 quad 테두리; 0이면 텍스트만 — tui 셀 번짐 회피). caret은 표시폭 끝
//! 셀에 cursor fill 1칸(인라인 편집·palette caret 패턴). 단일 출처: docs/config-gui.md §2·§6, docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW) — caret 위치 단일 출처(한글/CJK 2칸)

/// 입력 박스 control 영역 폭(px) — 셸이 행 control 열 예약에 쓴다. 숫자값 여러 자리 + 여유를 갖게 행 높이의 5배
/// (옛 슬라이더 폭 규율을 계승 — 슬라이더 막대는 제거됐지만 숫자 입력 열은 같은 폭이면 충분).
pub fn width(row_height_px: u32) u32 {
    return row_height_px * 5;
}

/// 입력 박스를 그린다. rect=control 열(박스 경계), text=표시 문자열(비편집=현재값, 편집=편집 버퍼), editing=편집 중,
/// disabled=회색(프리셋 잠금 등). cw/ch=셀 픽셀(caret 크기·좌패딩). corner_radius/border_width>0이면 quad 테두리
/// (편집 중=focus_accent, 아니면 muted_fg). 텍스트는 좌패딩 1칸 좌측정렬. 순수: 인자만 읽는다. ops/runs는 호출자
/// frame arena 소유. 0폭/0높이면 무동작.
pub fn view(
    rect: draw.Rect,
    text: []const u8,
    editing: bool,
    disabled: bool,
    cw: u32,
    ch: u32,
    corner_radius_px: u16,
    border_width_px: u16,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (rect.w == 0 or rect.h == 0) return;
    // 테두리 박스(rich) — 편집 중이면 focus_accent로 강조해 "지금 입력 중"을 보인다. tui(border 0)는 텍스트만.
    if (border_width_px > 0) {
        const border_role: tokens.ColorRole = if (editing) .focus_accent else .muted_fg;
        try out.append(arena, .{ .quad = .{
            .rect = rect,
            .fill_role = .surface_bg,
            .corner_radii = .{ corner_radius_px, corner_radius_px, corner_radius_px, corner_radius_px },
            .border_widths = .{ border_width_px, border_width_px, border_width_px, border_width_px },
            .border_role = border_role,
        } });
    }
    const tx = rect.x + @as(i32, @intCast(cw)); // 좌패딩 1칸
    if (text.len > 0) {
        const role: tokens.ColorRole = if (editing) .accent_bar else if (disabled) .muted_fg else .surface_fg;
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = text };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = tx, .y = rect.y }, .runs = runs, .role = role } });
    }
    // 편집 중이면 표시폭 끝 셀에 caret(cursor fill 1칸) — 인라인 편집(end-caret) 규약과 동일.
    if (editing) {
        const caret_x = tx + @as(i32, @intCast(overlay_input.displayCols(text) * cw));
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = rect.y, .w = cw, .h = ch }, .role = .cursor } });
    }
}

/// (x,y) px가 박스 안인가 — 클릭(편집 진입) hit-test. 셀 0/비유한 가드.
pub fn hitTest(rect: draw.Rect, x_px: f64, y_px: f64) bool {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 120, .h = 20 };

test "input_box view: 비편집 = 테두리 박스(muted) + 값(surface_fg), caret 없음" {
    // 증명: 비편집 상태는 muted 테두리 박스 + 현재 값 텍스트만 그리고 caret은 없다 — 숫자 필드가 '박스 안 값'으로
    // 보이는 기본 모습(프로그레스바 대체). 텍스트는 좌패딩 1칸(rect.x + cw).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(test_rect, "14", false, false, 8, 16, 4, 1, arena, &out);
    // quad 박스 + 텍스트 = 2 op(caret 없음).
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[0].quad.border_role); // 비편집 테두리
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[1].text.role);
    try std.testing.expectEqual(@as(i32, 108), out.items[1].text.origin.x); // rect.x(100) + cw(8) 좌패딩
    try std.testing.expectEqualStrings("14", out.items[1].text.runs[0].text);
}

test "input_box view: 편집 = focus 테두리 + accent 텍스트 + 끝 caret(cursor)" {
    // 증명: 편집 중이면 테두리가 focus_accent로 강조되고 텍스트가 accent_bar, 표시폭 끝 셀에 caret(cursor fill)이
    // 붙는다 — 지금 입력 중임을 보이고 다음 글자 위치를 표시. caret x = 좌패딩 + 표시폭×cw.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(test_rect, "0.6", true, false, 8, 16, 4, 1, arena, &out);
    // quad + 텍스트 + caret = 3 op.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.focus_accent, out.items[0].quad.border_role); // 편집 테두리 강조
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[1].text.role);
    try std.testing.expect(out.items[2] == .fill);
    try std.testing.expectEqual(tokens.ColorRole.cursor, out.items[2].fill.role);
    // caret x = rect.x(100) + cw(8) + displayCols("0.6")=3 × 8 = 108 + 24 = 132.
    try std.testing.expectEqual(@as(i32, 132), out.items[2].fill.rect.x);
}

test "input_box view: 빈 값 편집 = 박스 + caret만(텍스트 op 없음), border 0=텍스트만" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    // 빈 값 + 편집: quad + caret = 2 op(텍스트 없음).
    try view(test_rect, "", true, false, 8, 16, 4, 1, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .fill); // caret

    // border_width 0(tui) 비편집 = 텍스트 op 1개만(테두리 quad 없음).
    out.clearRetainingCapacity();
    try view(test_rect, "80", false, false, 8, 16, 0, 0, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0] == .text);

    // 0폭 → 무동작.
    out.clearRetainingCapacity();
    try view(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, "1", false, false, 8, 16, 4, 1, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "input_box width: 행 높이 × 5(control 열 폭)" {
    try std.testing.expectEqual(@as(u32, 100), width(20));
}

test "input_box hitTest: 박스 안=true, 밖/비유한/0폭=false" {
    try std.testing.expect(hitTest(test_rect, 150, 60));
    try std.testing.expect(hitTest(test_rect, 100, 50));
    try std.testing.expect(!hitTest(test_rect, 230, 60));
    try std.testing.expect(!hitTest(test_rect, 150, 80));
    try std.testing.expect(!hitTest(test_rect, std.math.inf(f64), 60));
    try std.testing.expect(!hitTest(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 0, 0));
}
