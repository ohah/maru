//! Surface-relative mouse coordinates, independent of native message formats.
const std = @import("std");

/// 셀 좌표. 중립 `SelectAt`/`SelectStart`와 같은 모양이다.
pub const Cell = struct { row: u16, col: u16 };

/// Signed pixel coordinates preserve captured drags outside the surface.
pub const Point = struct { x: i32, y: i32 };

/// Convert client coordinates to the rendered surface's pixel coordinates before
/// cell lookup or mouse reporting. Keep signed out-of-surface drags and saturate
/// in a wide domain so unsigned layout origins cannot wrap through i32.
pub fn pointRelativeTo(point: Point, origin_x: u32, origin_y: u32) Point {
    return .{
        .x = @intCast(std.math.clamp(@as(i64, point.x) - origin_x, std.math.minInt(i32), std.math.maxInt(i32))),
        .y = @intCast(std.math.clamp(@as(i64, point.y) - origin_y, std.math.minInt(i32), std.math.maxInt(i32))),
    };
}

/// 픽셀을 셀로 바꾼다. **격자 안으로 clamp한다.**
///
/// 드래그 중 포인터가 창 밖으로 나가도 선택이 끊기면 안 된다 — `SetCapture` 때문에 창 밖 좌표가 계속
/// 오고(음수도 온다), 거기서 `null`을 내면 가장자리에서 선택이 멈춘다. 가장자리 셀로 접는 것이 맞다.
///
/// `cell_w`·`cell_h`가 0이면 나눗셈이 못 서므로 `null`이다(폰트가 아직 안 섰을 때 — §2e의 `cellsForClient`와
/// 같은 이유·같은 처리).
pub fn cellFromPixel(
    x_px: i32,
    y_px: i32,
    cell_w: u32,
    cell_h: u32,
    cols: u16,
    rows: u16,
) ?Cell {
    if (cell_w == 0 or cell_h == 0) return null;
    if (cols == 0 or rows == 0) return null;

    const col_raw: i64 = @divFloor(@as(i64, x_px), @as(i64, cell_w));
    const row_raw: i64 = @divFloor(@as(i64, y_px), @as(i64, cell_h));
    const col = std.math.clamp(col_raw, 0, @as(i64, cols) - 1);
    const row = std.math.clamp(row_raw, 0, @as(i64, rows) - 1);
    return .{ .row = @intCast(row), .col = @intCast(col) };
}

/// A cache key includes layout and metrics, because a stationary terminal cursor
/// still moves on screen when chrome is resized or the font changes.
pub const ImeCaret = struct {
    row: u16,
    col: u16,
    cell_w: u32,
    cell_h: u32,
    origin_x: u32,
    origin_y: u32,

    pub const Anchor = struct { top_left: Point, bottom_right: Point, below: Point };

    pub fn anchor(self: ImeCaret) ?Anchor {
        if (self.cell_w == 0 or self.cell_h == 0) return null;
        const left = @as(u64, self.origin_x) + @as(u64, self.col) * self.cell_w;
        const top = @as(u64, self.origin_y) + @as(u64, self.row) * self.cell_h;
        // IMM uses signed LONG coordinates. Saturate only at the API boundary,
        // after wide arithmetic, so extreme layout values cannot wrap or trap.
        return .{
            .top_left = .{ .x = pixel(left), .y = pixel(top) },
            .bottom_right = .{ .x = pixel(left + self.cell_w), .y = pixel(top + self.cell_h) },
            .below = .{ .x = pixel(left), .y = pixel(top + self.cell_h) },
        };
    }

    fn pixel(value: u64) i32 {
        return @intCast(@min(value, std.math.maxInt(i32)));
    }
};

test "IME caret geometry tracks chrome origins, metrics and extreme rows" {
    const caret: ImeCaret = .{ .row = 2, .col = 3, .cell_w = 8, .cell_h = 19, .origin_x = 300, .origin_y = 38 };
    try std.testing.expectEqualDeep(ImeCaret.Anchor{
        .top_left = .{ .x = 324, .y = 76 },
        .bottom_right = .{ .x = 332, .y = 95 },
        .below = .{ .x = 324, .y = 95 },
    }, caret.anchor().?);
    var moved = caret;
    moved.origin_x = 400;
    try std.testing.expect(!std.meta.eql(caret, moved));
    try std.testing.expectEqual(@as(i32, 424), moved.anchor().?.below.x);
    moved = caret;
    moved.origin_y = 0;
    try std.testing.expectEqual(@as(i32, 57), moved.anchor().?.below.y);
    moved = caret;
    moved.cell_h = 20;
    try std.testing.expect(!std.meta.eql(caret, moved));
    try std.testing.expectEqual(@as(i32, 98), moved.anchor().?.below.y);
    moved.cell_w = 0;
    try std.testing.expect(moved.anchor() == null);
    moved = .{ .row = 65535, .col = 65535, .cell_w = 4294967295, .cell_h = 4294967295, .origin_x = 4294967295, .origin_y = 4294967295 };
    try std.testing.expectEqualDeep(Point{ .x = 2147483647, .y = 2147483647 }, moved.anchor().?.bottom_right);
}
