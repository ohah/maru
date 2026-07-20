//! File explorer vertical scrollbar geometry. This module is deliberately state-free: render,
//! hover, track clicks, and drag all consume the same `Geometry` value.

const std = @import("std");

pub const min_thumb_px: f32 = 24;
pub const bar_width_px: u32 = 8;
pub const edge_inset_px: u32 = 3;

/// Number of complete text cells that must be withheld from row layout so the track and its
/// right inset never overlap the last rendered cell. The reservation is derived from the same
/// integer pixel geometry as `compute`; one hard-coded cell is insufficient for narrow fonts.
pub fn reservedColumns(content_w: u32, cell_w: u32) u32 {
    if (content_w == 0 or cell_w == 0) return 0;
    const width = @min(bar_width_px, content_w);
    const inset = @min(edge_inset_px, content_w - width);
    const occupied = width + inset;
    return occupied / cell_w + @intFromBool(occupied % cell_w != 0);
}

pub const Geometry = struct {
    total_rows: usize,
    visible_rows: usize,
    max_scroll: usize,
    scroll_rows: usize,
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,

    pub fn thumbContains(self: Geometry, x: f64, y: f64) bool {
        return x >= self.track_x and x < self.track_x + self.track_w and
            y >= self.thumb_y and y < self.thumb_y + self.thumb_h;
    }

    pub fn trackContains(self: Geometry, x: f64, y: f64) bool {
        return x >= self.track_x and x < self.track_x + self.track_w and
            y >= self.track_y and y < self.track_y + self.track_h;
    }

    pub fn sameSnapshot(self: Geometry, other: Geometry) bool {
        return self.total_rows == other.total_rows and self.visible_rows == other.visible_rows and
            self.track_x == other.track_x and self.track_y == other.track_y and
            self.track_w == other.track_w and self.track_h == other.track_h and
            self.thumb_h == other.thumb_h;
    }

    pub fn withScroll(self: Geometry, scroll_rows: usize) Geometry {
        var next = self;
        next.scroll_rows = @min(scroll_rows, self.max_scroll);
        const travel = self.track_h - self.thumb_h;
        const ratio = @as(f32, @floatFromInt(next.scroll_rows)) / @as(f32, @floatFromInt(self.max_scroll));
        next.thumb_y = self.track_y + travel * ratio;
        return next;
    }
};

pub fn compute(
    total_rows: usize,
    visible_rows: usize,
    scroll_rows: usize,
    content_x: u32,
    content_y: u32,
    content_w: u32,
    content_h: u32,
) ?Geometry {
    if (visible_rows == 0 or total_rows <= visible_rows or content_w == 0 or content_h == 0) return null;
    const max_scroll = total_rows - visible_rows;
    const track_h: f32 = @floatFromInt(content_h);
    const proportional = track_h * @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows));
    const thumb_h = @min(track_h, @max(min_thumb_px, proportional));
    const travel = track_h - thumb_h;
    const clamped_scroll = @min(scroll_rows, max_scroll);
    const ratio = @as(f32, @floatFromInt(clamped_scroll)) / @as(f32, @floatFromInt(max_scroll));
    const width = @min(bar_width_px, content_w);
    const inset = @min(edge_inset_px, content_w - width);
    return .{
        .total_rows = total_rows,
        .visible_rows = visible_rows,
        .max_scroll = max_scroll,
        .scroll_rows = clamped_scroll,
        .track_x = @floatFromInt(content_x + content_w - width - inset),
        .track_y = @floatFromInt(content_y),
        .track_w = @floatFromInt(width),
        .track_h = track_h,
        .thumb_y = @as(f32, @floatFromInt(content_y)) + travel * ratio,
        .thumb_h = thumb_h,
    };
}

/// Maps an absolute pointer y to scroll rows while keeping the captured point inside the thumb.
pub fn scrollForPointer(geometry: Geometry, pointer_y: f64, grab_y: f32) usize {
    if (!std.math.isFinite(pointer_y) or !std.math.isFinite(grab_y)) return geometry.scroll_rows;
    const travel = geometry.track_h - geometry.thumb_h;
    if (travel <= 0 or geometry.max_scroll == 0) return 0;
    const thumb_top_f64 = std.math.clamp(
        pointer_y - @as(f64, grab_y),
        @as(f64, geometry.track_y),
        @as(f64, geometry.track_y + travel),
    );
    const thumb_top: f32 = @floatCast(thumb_top_f64);
    const ratio = (thumb_top - geometry.track_y) / travel;
    return @intFromFloat(@round(ratio * @as(f32, @floatFromInt(geometry.max_scroll))));
}

/// Track clicks center the thumb at the click and use the same drag mapping thereafter.
pub fn scrollForTrackClick(geometry: Geometry, pointer_y: f64) usize {
    return scrollForPointer(geometry, pointer_y, geometry.thumb_h / 2);
}

test "file tree scrollbar: overflow only and endpoints" {
    try std.testing.expect(compute(10, 10, 0, 0, 0, 200, 200) == null);
    const top = compute(100, 10, 0, 10, 20, 200, 300).?;
    const bottom = compute(100, 10, 90, 10, 20, 200, 300).?;
    try std.testing.expectEqual(@as(f32, 20), top.thumb_y);
    try std.testing.expectApproxEqAbs(top.track_y + top.track_h - top.thumb_h, bottom.thumb_y, 0.01);
    try std.testing.expectEqual(@as(usize, 0), scrollForTrackClick(top, -100));
    try std.testing.expectEqual(@as(usize, 90), scrollForTrackClick(top, 1000));
}

test "file tree scrollbar: drag round trips every row" {
    const geometry = compute(257, 17, 0, 0, 5, 180, 400).?;
    const travel = geometry.track_h - geometry.thumb_h;
    for (0..geometry.max_scroll + 1) |wanted| {
        const y = geometry.track_y + travel * @as(f32, @floatFromInt(wanted)) /
            @as(f32, @floatFromInt(geometry.max_scroll));
        try std.testing.expectEqual(wanted, scrollForPointer(geometry, y, 0));
    }
}

test "file tree scrollbar: non-finite drag preserves scroll and huge finite values clamp" {
    const geometry = compute(100, 10, 35, 0, 0, 200, 300).?;
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, std.math.nan(f64), 0));
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, std.math.inf(f64), 0));
    try std.testing.expectEqual(@as(usize, 35), scrollForPointer(geometry, -std.math.inf(f64), 0));
    try std.testing.expectEqual(@as(usize, 90), scrollForPointer(geometry, std.math.floatMax(f64), 0));
    try std.testing.expectEqual(@as(usize, 0), scrollForPointer(geometry, -std.math.floatMax(f64), 0));
}

test "file tree scrollbar: pixel reservation never overlaps the last content cell" {
    try std.testing.expectEqual(@as(u32, 2), reservedColumns(160, 8));
    const content_x: u32 = 17;
    for (1..17) |cell_w_usize| {
        const cell_w: u32 = @intCast(cell_w_usize);
        for (0..cell_w) |remainder_usize| {
            const remainder: u32 = @intCast(remainder_usize);
            const content_w = cell_w * 20 + remainder;
            const geometry = compute(100, 10, 0, content_x, 0, content_w, 300).?;
            const total_cols = content_w / cell_w;
            const content_cols = total_cols -| reservedColumns(content_w, cell_w);
            const last_content_right = content_x + content_cols * cell_w;
            try std.testing.expect(@as(f32, @floatFromInt(last_content_right)) <= geometry.track_x);
        }
    }
}
