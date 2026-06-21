//! Slider — 범위 숫자 위젯(f32/u32 + range). divider와 같은 **State 없는 순수 함수 모듈**: 값은 셸이 들고(config
//! 단일 출처), 컴포넌트는 rect + ratio(0..1)를 받아 트랙·채운 구간·thumb를 그리고(view), 클릭/드래그 x를 ratio로
//! 환산한다(ratioAt — divider.dragRatio 패턴). 값↔ratio 매핑(min/max·step·클램프)과 드래그 상태는 셸이 소유한다
//! (toggle은 자기 값을 토글하지만 slider는 연속값이라 셸이 매핑). 모양은 tokens.space로 두 룩 분기: rich(>0)=GPU
//! quad(얇은 트랙+채움+원형 thumb), tui(0, 기본)=셀 정렬 text 진행 막대 `[███   ]`(채움=`█`×ratio accent_bar,
//! 트랙=muted_fg) — quad의 paintRectBg 셀 번짐 회피(§6.1 결정). 단일 출처: docs/config-gui.md §2·§6, chrome-strategy.md §5.4.

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

const tui_fill = "\u{2588}"; // █ FULL BLOCK(합성 글리프) — 채운 칸
const tui_min_cells: usize = 3; // 최소 '[ ]'

/// slider를 control rect에 그린다. **두 룩 분기**(tokens.space.corner_radius_px):
///  - rich(>0): GPU quad — 얇은 muted 트랙 + 채움(accent_bar) + 원형 thumb(sub-pixel, 우아).
///  - tui(0): 셀 정렬 **text 진행 막대** `[███   ]` — 트랙 `[ ]`+빈칸(muted_fg), 채움 `█`×ratio(accent_bar). quad를
///    tui에서 쓰면 paintRectBg가 셀 단위라 얇은 트랙(h/4)은 r0==r1로 사라지고 행 높이 채움이 위아래로 번졌다 —
///    dropdown/toggle처럼 text 레이어로 그려 셀 정렬·선택 하이라이트 위 또렷(단일 출처: docs/config-gui.md §6 결정).
/// 순수: rect·ratio·tokens만 읽는다. `cw`는 tui 칸 수/채움 셀 오프셋용(rich는 무시). out/op은 호출자(셸) frame arena 소유.
pub fn view(
    rect: draw.Rect,
    ratio: f32,
    cw: u32,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (rect.w == 0 or rect.h == 0) return;
    const round = tk.space.corner_radius_px > 0;
    if (round) {
        const g = geom(rect, ratio);
        const track_r: u16 = @intCast(@min(g.track.h / 2, @as(u32, std.math.maxInt(u16))));
        const thumb_r: u16 = @intCast(@min(g.thumb.h / 2, @as(u32, std.math.maxInt(u16))));
        try out.append(arena, .{ .quad = .{ .rect = g.track, .fill_role = .muted_fg, .corner_radii = .{ track_r, track_r, track_r, track_r } } });
        if (g.filled.w > 0) try out.append(arena, .{ .quad = .{ .rect = g.filled, .fill_role = .accent_bar, .corner_radii = .{ track_r, track_r, track_r, track_r } } });
        try out.append(arena, .{ .quad = .{ .rect = g.thumb, .fill_role = .surface_fg, .corner_radii = .{ thumb_r, thumb_r, thumb_r, thumb_r } } });
        return;
    }
    // tui: 칸 수 = rect 폭/cw(control 열 칸과 일치). 트랙 '[' + 빈칸×inner + ']'(muted) → 채움 '█'×k(accent) 덮기.
    const cells: usize = @max(tui_min_cells, rect.w / @max(cw, 1));
    const inner = cells - 2;
    const r = std.math.clamp(ratio, 0, 1);
    const k: usize = @intFromFloat(@round(@as(f32, @floatFromInt(inner)) * r));
    // 트랙: '[' + ' '×inner + ']'.
    const track = try arena.alloc(u8, cells + 1); // '[' + inner(' ') + ']' (ASCII 1B/char)
    track[0] = '[';
    @memset(track[1 .. 1 + inner], ' ');
    track[1 + inner] = ']';
    const trun = try arena.alloc(draw.Run, 1);
    trun[0] = .{ .text = track[0..cells] };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x, .y = rect.y }, .runs = trun, .role = .muted_fg } });
    if (k > 0) {
        // 채움 '█'×k(각 3바이트 UTF-8) — 안쪽 좌(셀1)부터.
        const fill = try arena.alloc(u8, k * tui_fill.len);
        var i: usize = 0;
        while (i < k) : (i += 1) @memcpy(fill[i * tui_fill.len ..][0..tui_fill.len], tui_fill);
        const frun = try arena.alloc(draw.Run, 1);
        frun[0] = .{ .text = fill };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(cw)), .y = rect.y }, .runs = frun, .role = .accent_bar } });
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

test "slider view tui: 트랙 text '[ ]'(muted) + 채움 █×k(accent, ratio 비례)" {
    const Rgb = @import("../../color.zig").Rgb;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cw: u32 = 8; // test_rect.w=100 → cells=12, inner=10
    const tui = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var out: std.ArrayList(draw.Op) = .empty;

    // ratio=0: 트랙만(채움 0칸 → op 1개). 트랙 = '[' + ' '×10 + ']' = 12칸, muted_fg.
    try view(test_rect, 0, cw, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[0].text.role);
    try std.testing.expect(std.mem.startsWith(u8, out.items[0].text.runs[0].text, "["));
    try std.testing.expect(std.mem.endsWith(u8, out.items[0].text.runs[0].text, "]"));

    // ratio=1: 트랙 + 채움 █×inner(10칸, accent_bar, 안쪽 좌=셀1 → x=100+8=108).
    out.clearRetainingCapacity();
    try view(test_rect, 1, cw, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[1].text.role);
    try std.testing.expectEqual(@as(i32, 108), out.items[1].text.origin.x);
    try std.testing.expectEqual(@as(usize, 10 * tui_fill.len), out.items[1].text.runs[0].text.len); // █×10

    // ratio=0.5: 채움 █×5(round(10*0.5)).
    out.clearRetainingCapacity();
    try view(test_rect, 0.5, cw, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 5 * tui_fill.len), out.items[1].text.runs[0].text.len);

    // rich: 얇은 muted 트랙 + 채움 + 원형 thumb(3 quad ops, 둥글).
    out.clearRetainingCapacity();
    var rich = tui;
    rich.space.corner_radius_px = 8;
    try view(test_rect, 0.5, cw, &rich, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[0].quad.fill_role); // 얇은 트랙
    try std.testing.expect(out.items[0].quad.corner_radii[0] > 0); // 트랙 둥글
    try std.testing.expect(out.items[2].quad.corner_radii[0] > 0); // thumb 둥글
    try std.testing.expect(out.items[0].quad.rect.h < 20); // 얇은 트랙(행 높이보다 작음)
}
