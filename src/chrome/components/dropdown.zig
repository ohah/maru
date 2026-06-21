//! Dropdown — enum 값 위젯. CS-4-1c 첫 컷은 **사이클러**: 현재 변형을 텍스트 + ▾로 보여주고, 클릭/←→로 다음/이전
//! 변형을 순환한다(셸/platform이 schema.cycleEnum으로 순환·저장 — 위젯은 현재값 표시 + hit-test만). 옵션 목록 팝업
//! (config-gui §6 "palette 정적 변형")은 후속 — 셀-grid 위 팝업 z-order·hit-test가 toggle/slider보다 무거워, 적은
//! 변형(블록/바/밑줄 등)엔 사이클러가 충분하고 시각 확인이 빠르다. State 없는 순수 함수(divider/slider 선례).
//! 단일 출처: docs/config-gui.md §2·§6.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");

const chevron = " \u{25BE}"; // " ▾"(BLACK DOWN-POINTING SMALL TRIANGLE) — dropdown 표식

/// 현재 변형 텍스트 + ▾를 control rect 좌상단에 그린다(Op.text). 색=surface_fg. 빈 current면 ▾만(방어). 순수:
/// rect·current·tokens만 읽는다. runs/op은 호출자(셸) frame arena 소유. 사이클링은 platform(schema.cycleEnum).
pub fn view(
    rect: draw.Rect,
    current: []const u8,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (rect.w == 0 or rect.h == 0) return;
    // 표시 토큰의 '_'→'-'(config 규약 — current는 정적 @tagName이라 여기 frame arena에서 변환). 그다음 " ▾" 붙임.
    const disp = try arena.dupe(u8, current);
    for (disp) |*c| {
        if (c.* == '_') c.* = '-';
    }
    const label = try std.fmt.allocPrint(arena, "{s}{s}", .{ disp, chevron });
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = label };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x, .y = rect.y }, .runs = runs, .role = .surface_fg } });
}

/// (x,y)가 dropdown control rect 안인가 — 클릭(사이클) hit-test. 셀 0/비유한 가드.
pub fn hitTest(rect: draw.Rect, x_px: f64, y_px: f64) bool {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 100, .h = 20 };

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "dropdown view: 현재값 + ▾ 텍스트(surface_fg, control rect 좌상단)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(test_rect, "block", &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0] == .text);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[0].text.role);
    try std.testing.expectEqual(@as(i32, 100), out.items[0].text.origin.x);
    try std.testing.expect(std.mem.startsWith(u8, out.items[0].text.runs[0].text, "block")); // 현재값으로 시작
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].text.runs[0].text, "\u{25BE}") != null); // ▾ 포함

    // 0폭 rect → 무동작.
    out.clearRetainingCapacity();
    try view(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, "x", &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "dropdown hitTest: rect 안=true, 밖/비유한=false" {
    try std.testing.expect(hitTest(test_rect, 150, 60));
    try std.testing.expect(hitTest(test_rect, 100, 50));
    try std.testing.expect(!hitTest(test_rect, 200, 60));
    try std.testing.expect(!hitTest(test_rect, 150, 70));
    try std.testing.expect(!hitTest(test_rect, std.math.inf(f64), 60));
    try std.testing.expect(!hitTest(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 0, 0));
}
