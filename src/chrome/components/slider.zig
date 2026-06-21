//! Slider — 범위 숫자 위젯(f32/u32 + range). divider와 같은 **State 없는 순수 함수 모듈**: 값은 셸이 들고(config
//! 단일 출처), 컴포넌트는 rect + ratio(0..1)를 받아 트랙·채운 구간·thumb를 그리고(view), 클릭/드래그 x를 ratio로
//! 환산한다(ratioAt — divider.dragRatio 패턴). 값↔ratio 매핑(min/max·step·클램프)과 드래그 상태는 셸이 소유한다
//! (toggle은 자기 값을 토글하지만 slider는 연속값이라 셸이 매핑). 모양은 tokens.space(rich>0 → 둥근 트랙/원형
//! thumb, tui=0 → 직각)로 분기 없이 두 룩. 색: 트랙=muted_fg, 채움=accent_bar(maru 앰버), thumb=surface_fg.
//! 단일 출처: docs/config-gui.md §2·§6, docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");

/// 슬라이더 control 영역 폭(px) — 셸이 행 control 열 예약에 쓴다. 트랙이 thumb 여러 자리 + 여유를 갖게 행 높이의 5배.
pub fn width(row_height_px: u32) u32 {
    return row_height_px * 5;
}

/// 드래그/클릭 x → ratio(0..1, 클램프). 트랙 좌단=0, 우단=1. thumb 중심이 커서를 따라가게 thumb 반지름만큼 보정한다
/// (양끝에서 thumb가 트랙 밖으로 안 나가게 — divider.dragRatio가 bounds로 정규화하는 것과 같은 취지). 0폭/비유한=0.
pub fn ratioAt(rect: draw.Rect, x_px: f64) f32 {
    if (rect.w == 0 or !std.math.isFinite(x_px)) return 0;
    const td: f64 = @floatFromInt(thumbDiameter(rect.h));
    const usable: f64 = @as(f64, @floatFromInt(rect.w)) - td; // thumb가 움직일 수 있는 폭
    if (usable <= 0) return 0;
    const left: f64 = @as(f64, @floatFromInt(rect.x)) + td / 2; // thumb 중심 최소 위치
    const r = (x_px - left) / usable;
    return @floatCast(std.math.clamp(r, 0, 1));
}

/// (x,y)가 슬라이더 control rect 안인가 — 클릭/드래그 시작 hit-test. 트랙 전체 높이를 잡는다(thumb가 작아도 잡기 쉽게).
pub fn hitTest(rect: draw.Rect, x_px: f64, y_px: f64) bool {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

/// thumb 한 변(=지름). 트랙 높이보다 크게 잡아 손잡이가 트랙 위로 도드라진다(행 높이의 ~3/4).
fn thumbDiameter(row_height_px: u32) u32 {
    return @max(@as(u32, 4), row_height_px * 3 / 4);
}

/// view와 ratioAt이 공유하는 기하(§5.4 단일 레이아웃). 트랙(가는 가로 바, 세로 중앙) + 채운 구간(좌단~thumb 중심) +
/// thumb(정사각, ratio 위치). thumb는 [rect.x, rect.x+w-td] 범위를 움직인다(ratioAt의 usable과 짝).
const Geom = struct {
    track: draw.Rect,
    filled: draw.Rect,
    thumb: draw.Rect,
};

fn geom(rect: draw.Rect, ratio: f32) Geom {
    const r = std.math.clamp(ratio, 0, 1);
    const td = thumbDiameter(rect.h);
    const track_h = @max(@as(u32, 2), rect.h / 4);
    const track_y = rect.y + @as(i32, @intCast((rect.h -| track_h) / 2));
    const usable = rect.w -| td;
    const thumb_x = rect.x + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * r)));
    const thumb_center = thumb_x + @as(i32, @intCast(td / 2));
    const filled_w: u32 = @intCast(@max(@as(i32, 0), thumb_center - rect.x));
    return .{
        .track = .{ .x = rect.x, .y = track_y, .w = rect.w, .h = track_h },
        .filled = .{ .x = rect.x, .y = track_y, .w = filled_w, .h = track_h },
        .thumb = .{ .x = thumb_x, .y = rect.y + @as(i32, @intCast((rect.h -| td) / 2)), .w = td, .h = td },
    };
}

/// 트랙(muted_fg) → 채운 구간(accent_bar, 좌단~thumb) → thumb(surface_fg)를 그린다(painter 순서 — thumb가 위).
/// rich(space.corner_radius_px>0)면 트랙/thumb를 둥글게(트랙 반지름=track_h/2, thumb=원), tui(0)면 직각. 순수:
/// rect·ratio·tokens만 읽는다. out/op은 호출자(셸) frame arena 소유.
pub fn view(
    rect: draw.Rect,
    ratio: f32,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (rect.w == 0 or rect.h == 0) return;
    const g = geom(rect, ratio);
    const round = tk.space.corner_radius_px > 0;
    // 두 룩의 차이는 셀 vs sub-pixel lowering 때문이다:
    //  rich(round>0): GPU quad(SDF)라 얇은 muted 트랙 + 채움(accent_bar) + 원형 thumb를 그대로 그린다(우아).
    //  tui(round=0): paintRectBg가 셀 단위라 셀보다 얇은 사각형(track h=rect.h/4)은 r0==r1로 사라진다. 또 muted_fg가
    //   밝은 테마에선 행 전체 높이 muted 트랙이 패널을 덮어 큰 흰 블록처럼 보인다. 그래서 tui는 **트랙을 안 그리고**
    //   (패널 bg=빈 트랙) 채움(accent_bar, 좌단~thumb, 행 전체 높이) + thumb(surface_fg, 행 전체 높이)만 그린다 —
    //   진행 막대처럼 값이 읽힌다(blocky, 토글과 같은 규율). x/폭은 두 룩 공통(geom — ratioAt 매핑과 일치).
    if (round) {
        const track_r: u16 = @intCast(@min(g.track.h / 2, @as(u32, std.math.maxInt(u16))));
        const thumb_r: u16 = @intCast(@min(g.thumb.h / 2, @as(u32, std.math.maxInt(u16))));
        try out.append(arena, .{ .quad = .{ .rect = g.track, .fill_role = .muted_fg, .corner_radii = .{ track_r, track_r, track_r, track_r } } });
        if (g.filled.w > 0) try out.append(arena, .{ .quad = .{ .rect = g.filled, .fill_role = .accent_bar, .corner_radii = .{ track_r, track_r, track_r, track_r } } });
        try out.append(arena, .{ .quad = .{ .rect = g.thumb, .fill_role = .surface_fg, .corner_radii = .{ thumb_r, thumb_r, thumb_r, thumb_r } } });
    } else {
        const fill_w = @max(g.filled.w, @as(u32, 1)); // 최소 1px(ratio 0이어도 좌단 표식 — paintRectBg가 1셀은 칠한다)
        try out.append(arena, .{ .quad = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = fill_w, .h = rect.h }, .fill_role = .accent_bar } });
        try out.append(arena, .{ .quad = .{ .rect = .{ .x = g.thumb.x, .y = rect.y, .w = g.thumb.w, .h = rect.h }, .fill_role = .surface_fg } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 100, .h = 20 };

test "slider width: 행 높이 × 5" {
    try std.testing.expectEqual(@as(u32, 100), width(20));
}

test "slider ratioAt: 좌단=0·우단=1·중앙≈0.5·클램프·비유한=0" {
    // td=15(20*3/4), usable=85, left=100+7.5=107.5.
    try std.testing.expectEqual(@as(f32, 0), ratioAt(test_rect, 107.5)); // 좌단(thumb 중심 최소)
    try std.testing.expectEqual(@as(f32, 1), ratioAt(test_rect, 192.5)); // 우단(107.5+85)
    try std.testing.expect(@abs(ratioAt(test_rect, 150) - 0.5) < 0.02); // 중앙쯤
    try std.testing.expectEqual(@as(f32, 0), ratioAt(test_rect, 0)); // 왼쪽 밖 → 클램프 0
    try std.testing.expectEqual(@as(f32, 1), ratioAt(test_rect, 9999)); // 오른쪽 밖 → 클램프 1
    try std.testing.expectEqual(@as(f32, 0), ratioAt(test_rect, std.math.inf(f64)));
    try std.testing.expectEqual(@as(f32, 0), ratioAt(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 50));
}

test "slider hitTest: rect 안=true, 밖/비유한=false" {
    try std.testing.expect(hitTest(test_rect, 150, 60));
    try std.testing.expect(hitTest(test_rect, 100, 50)); // 좌상 경계
    try std.testing.expect(!hitTest(test_rect, 200, 60)); // 우측 밖(>=200)
    try std.testing.expect(!hitTest(test_rect, 150, 70)); // 하단 밖
    try std.testing.expect(!hitTest(test_rect, std.math.inf(f64), 60));
    try std.testing.expect(!hitTest(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 0, 0));
}

test "slider view: tui=채움+thumb(트랙 없음·행 높이·직각), rich=얇은 muted 트랙+채움+원형 thumb" {
    const Rgb = @import("../../color.zig").Rgb;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tui = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var out: std.ArrayList(draw.Op) = .empty;

    // tui ratio=0: 채움(accent_bar, 좌단) + thumb(surface_fg, x=100). 트랙(muted) 없음(패널 bg=빈 트랙). 행 높이·직각.
    try view(test_rect, 0, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[0].quad.fill_role); // 채움
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[1].quad.fill_role); // thumb
    try std.testing.expectEqual(@as(i32, 100), out.items[1].quad.rect.x); // ratio 0 → thumb 좌단(rect.x)
    try std.testing.expectEqual(@as(u32, 20), out.items[1].quad.rect.h); // 행 높이(rect.h)
    try std.testing.expectEqual(@as(u16, 0), out.items[0].quad.corner_radii[0]); // tui 직각

    // tui ratio=1: thumb 우단(x = 100 + usable(85) = 185).
    out.clearRetainingCapacity();
    try view(test_rect, 1, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(i32, 185), out.items[1].quad.rect.x);

    // rich: 얇은 muted 트랙 + 채움 + 원형 thumb(3 ops, 둥글).
    out.clearRetainingCapacity();
    var rich = tui;
    rich.space.corner_radius_px = 8;
    try view(test_rect, 0.5, &rich, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[0].quad.fill_role); // 얇은 트랙
    try std.testing.expect(out.items[0].quad.corner_radii[0] > 0); // 트랙 둥글
    try std.testing.expect(out.items[2].quad.corner_radii[0] > 0); // thumb 둥글
    try std.testing.expect(out.items[0].quad.rect.h < 20); // 얇은 트랙(행 높이보다 작음)
}
