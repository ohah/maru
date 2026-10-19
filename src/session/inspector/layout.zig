//! Inspector presentation is independent from workspace panes and the file/SCM dock.
//! The host supplies pixels; this module owns placement, bounds and resize limits.
const std = @import("std");
const Rect = @import("../split_tree.zig").Rect;
pub const Placement = enum(u3) { top, right, bottom, left, window };
pub const minimum_window_pt: u32 = 400;
pub const State = struct {
    open: bool = false,
    placement: Placement = .right,
    width_pt: u32 = 360,
    height_pt: u32 = 300,
    window_width_px: u32 = 720,
    window_height_px: u32 = 520,
    window_scale: u32 = 1000,
};
pub const Geometry = struct { content: Rect, remaining: Rect, divider: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
pub fn geometry(s: State, raw_available: Rect, scale: u32) Geometry {
    var available = raw_available;
    available.w = @min(available.w, std.math.maxInt(u32) - available.x);
    available.h = @min(available.h, std.math.maxInt(u32) - available.y);
    if (!s.open) return .{ .content = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .remaining = available };
    if (s.placement == .window) return .{ .content = .{ .x = 0, .y = 0, .w = @min(s.window_width_px, 16384), .h = @min(s.window_height_px, 16384) }, .remaining = available };
    const horizontal = s.placement == .left or s.placement == .right;
    const extent = if (horizontal) available.w else available.h;
    // Reserve a useful source viewport, while allowing a large inspector. Tiny windows
    // split their limited extent evenly instead of underflowing the minimum.
    const wanted: u32 = @intCast(@min(@as(u64, if (horizontal) s.width_pt else s.height_pt) * @max(scale, 1) / 1000, std.math.maxInt(u32)));
    const reserve: u32 = @intCast(@min(@as(u64, extent / 2), @as(u64, 160) * @max(scale, 1) / 1000));
    const size = @min(@max(wanted, 80), extent -| reserve -| @min(extent, 1));
    const seam = @min(@as(u32, 1), extent -| size);
    var rest = available;
    var content = available;
    var divider = available;
    switch (s.placement) {
        .left => {
            content.w = size;
            divider.x += size;
            divider.w = seam;
            rest.x += size + seam;
            rest.w -|= size + seam;
        },
        .right => {
            rest.w -|= size + seam;
            divider.x += rest.w;
            divider.w = seam;
            content.x = divider.x + seam;
            content.w = size;
        },
        .top => {
            content.h = size;
            divider.y += size;
            divider.h = seam;
            rest.y += size + seam;
            rest.h -|= size + seam;
        },
        .bottom => {
            rest.h -|= size + seam;
            divider.y += rest.h;
            divider.h = seam;
            content.y = divider.y + seam;
            content.h = size;
        },
        .window => unreachable,
    }
    return .{ .content = content, .remaining = rest, .divider = divider };
}
pub fn contains(r: Rect, x: f64, y: f64) bool {
    return std.math.isFinite(x) and std.math.isFinite(y) and x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and x < @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) and y < @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h));
}
test "inspector independent geometry preserves the workspace for all placements and tiny extents" {
    for ([_]u32{ 0, 1, 2, 160, 640, 4096 }) |size| for ([_]u32{ 250, 1000, 2000, 8000 }) |scale| {
        const available: Rect = .{ .x = 31, .y = 29, .w = size, .h = size };
        inline for (std.meta.tags(Placement)) |p| {
            const g = geometry(.{ .open = true, .placement = p, .width_pt = std.math.maxInt(u32), .height_pt = std.math.maxInt(u32) }, available, scale);
            try std.testing.expect(g.remaining.w <= size and g.remaining.h <= size);
            if (p == .window) try std.testing.expectEqual(available, g.remaining) else {
                try std.testing.expect(g.remaining.w >= @min(size / 2, 160 * scale / 1000));
                try std.testing.expect(g.remaining.h >= @min(size / 2, 160 * scale / 1000));
                try std.testing.expect(g.content.x + g.content.w <= available.x + size);
                try std.testing.expect(g.content.y + g.content.h <= available.y + size);
            }
        }
    };
}

test "inspector geometry rejects invalid points and clamps damaged viewport arithmetic" {
    const available: Rect = .{ .x = std.math.maxInt(u32) - 10, .y = std.math.maxInt(u32) - 10, .w = 100, .h = 100 };
    inline for (std.meta.tags(Placement)) |placement| {
        const g = geometry(.{ .open = true, .placement = placement }, available, 2000);
        try std.testing.expect(g.remaining.w <= 10 and g.remaining.h <= 10);
        try std.testing.expect(!contains(g.content, std.math.nan(f64), 0));
        try std.testing.expect(!contains(g.content, 0, std.math.inf(f64)));
        try std.testing.expect(!contains(g.content, -1, -1));
    }
}
