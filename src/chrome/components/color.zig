//! Color — 색 값 위젯(설정 폼의 color 행). **스와치 + hex**: 스와치는 `Op.swatch`(literal RGB)로 실제 색을 보여주고
//! (다른 위젯은 ColorRole만 쓰지만 스와치는 값 미리보기라 원색 — config-gui §6.2 결정), 옆에 `#RRGGBB` 텍스트.
//! 셸이 클릭/←→로 16색 프리셋을 순환하고(schema.cycleColor) hex 영역 클릭으로 인라인 편집(text 위젯 재사용)한다.
//! State 없는 순수 함수 모듈(dropdown/slider 선례) — 값·편집 버퍼는 셸이 들고 rect+rgb+text만 받아 그린다.
//! 단일 출처: docs/config-gui.md §6.2, docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const Rgb = @import("../../color.zig").Rgb;

const swatch_cells: u32 = 2; // 스와치 폭(칸)
const gap_cells: u32 = 1; // 스와치와 hex 사이 간격(칸)

/// hex 텍스트(또는 편집 버퍼)가 시작하는 x(px) — 셸이 caret·hex 클릭 zone 판정에 공유한다.
pub fn hexX(rect: draw.Rect, cw: u32) i32 {
    return rect.x + @as(i32, @intCast((swatch_cells + gap_cells) * cw));
}

/// control rect에 스와치(2칸 literal RGB) + 텍스트(hex 또는 편집 버퍼)를 그린다. role=비편집 surface_fg/편집 accent.
/// caret(편집 중)은 셸이 hexX + 표시폭에 그린다(text 위젯과 동형). 순수: rect·rgb·text만. out/op은 셸 arena 소유.
/// corner_radius=props.shape.corner_radius_px(tui=0 직각 셀 bg, rich>0 둥근 칩) — 스와치 높이의 절반으로 cap해
/// 과도한 라운딩(pill화)을 막는다. lowering(.swatch)이 0이면 셀 bg, >0이면 둥근 GPU quad로 분기한다(C4b 동형).
pub fn view(
    rect: draw.Rect,
    rgb: Rgb,
    text: []const u8,
    role: tokens.ColorRole,
    cw: u32,
    corner_radius: u16,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (rect.w == 0 or rect.h == 0) return;
    const r: u16 = @min(corner_radius, @as(u16, @intCast(rect.h / 2))); // 칩 라운딩 — 높이 절반 초과 방지
    try out.append(arena, .{ .swatch = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = swatch_cells * cw, .h = rect.h }, .rgb = rgb, .corner_radii = .{ r, r, r, r } } });
    if (text.len > 0) {
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = text };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = hexX(rect, cw), .y = rect.y }, .runs = runs, .role = role } });
    }
}

/// 클릭 zone — 스와치(왼쪽 = 프리셋 순환) vs hex(오른쪽 = 인라인 편집) vs 밖. 셸 handlePointer가 동작을 가른다.
pub const Zone = enum { swatch, hex, outside };

pub fn zoneAt(rect: draw.Rect, cw: u32, x_px: f64, y_px: f64) Zone {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return .outside;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    if (y_px < y0 or y_px >= y0 + @as(f64, @floatFromInt(rect.h))) return .outside;
    if (x_px < x0 or x_px >= x0 + @as(f64, @floatFromInt(rect.w))) return .outside;
    return if (x_px < @as(f64, @floatFromInt(hexX(rect, cw)))) .swatch else .hex;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 80, .h = 20 };

fn testTokens() tokens.Tokens {
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "color view: 스와치(literal RGB, 2칸) + hex 텍스트(hexX에서)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    _ = tk;
    const cw: u32 = 8;
    var out: std.ArrayList(draw.Op) = .empty;

    // rich(corner_radius=8): 스와치에 둥근 모서리(8 < h/2=10이라 8 그대로).
    try view(test_rect, .{ .r = 255, .g = 0, .b = 0 }, "#ff0000", .surface_fg, cw, 8, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .swatch);
    try std.testing.expectEqual(@as(u8, 255), out.items[0].swatch.rgb.r); // literal RGB
    try std.testing.expectEqual(@as(i32, 100), out.items[0].swatch.rect.x); // 스와치 좌단
    try std.testing.expectEqual(@as(u32, 16), out.items[0].swatch.rect.w); // 2칸=16px
    try std.testing.expectEqual(@as(u16, 8), out.items[0].swatch.corner_radii[0]); // rich 둥근 칩
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("#ff0000", out.items[1].text.runs[0].text);
    try std.testing.expectEqual(@as(i32, 100 + 24), out.items[1].text.origin.x); // hexX=(2+1)*8

    // tui(corner_radius=0): 직각 → corner_radii 0(셀 bg lowering).
    out.clearRetainingCapacity();
    try view(test_rect, .{ .r = 1, .g = 2, .b = 3 }, "#010203", .surface_fg, cw, 0, arena, &out);
    try std.testing.expectEqual(@as(u16, 0), out.items[0].swatch.corner_radii[0]);

    // 라운딩은 스와치 높이의 절반으로 cap(과도한 pill화 방지) — h=20 → 최대 10.
    out.clearRetainingCapacity();
    try view(test_rect, .{ .r = 0, .g = 0, .b = 0 }, "x", .surface_fg, cw, 99, arena, &out);
    try std.testing.expectEqual(@as(u16, 10), out.items[0].swatch.corner_radii[0]);

    // 0폭 → 무동작.
    out.clearRetainingCapacity();
    try view(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, .{ .r = 1, .g = 2, .b = 3 }, "x", .surface_fg, cw, 8, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "color zoneAt: 왼쪽=swatch, 오른쪽=hex, 밖=outside" {
    const cw: u32 = 8; // hexX = 100 + 24 = 124
    try std.testing.expectEqual(Zone.swatch, zoneAt(test_rect, cw, 105, 60)); // 스와치 영역
    try std.testing.expectEqual(Zone.hex, zoneAt(test_rect, cw, 130, 60)); // hex 영역
    try std.testing.expectEqual(Zone.outside, zoneAt(test_rect, cw, 200, 60)); // 우측 밖
    try std.testing.expectEqual(Zone.outside, zoneAt(test_rect, cw, 105, 75)); // 하단 밖
    try std.testing.expectEqual(Zone.outside, zoneAt(test_rect, cw, std.math.inf(f64), 60));
}
