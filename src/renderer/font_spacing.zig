//! Cell spacing shared by native hosts. Natural glyph width is never squeezed
//! to the grid advance, including when negative letter spacing is configured.
const std = @import("std");
pub const Metrics = struct { advance_width_px: u32, glyph_width_px: u32, height_px: u32 };

pub fn apply(base_width_px: u32, base_height_px: u32, line_height: f32, letter_spacing_pt: f32, scale_milli: u32) Metrics {
    const height: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_height_px)) * line_height));
    const spacing = letter_spacing_pt * @as(f32, @floatFromInt(scale_milli)) / 1000.0;
    const width: i64 = @as(i64, base_width_px) + @as(i64, @intFromFloat(@round(spacing)));
    return .{ .advance_width_px = @intCast(@max(@as(i64, 1), width)), .glyph_width_px = base_width_px, .height_px = height };
}

test "font spacing default preserves native metrics" {
    try std.testing.expectEqual(Metrics{ .advance_width_px = 9, .glyph_width_px = 9, .height_px = 19 }, apply(9, 19, 1, 0, 1000));
}
test "font spacing negative advance preserves natural bitmap width" {
    try std.testing.expectEqual(Metrics{ .advance_width_px = 6, .glyph_width_px = 9, .height_px = 19 }, apply(9, 19, 1, -3, 1000));
}
test "font spacing clamps grid advance before zero" {
    try std.testing.expectEqual(@as(u32, 1), apply(4, 19, 1, -8, 1000).advance_width_px);
}
test "font spacing applies fractional device scale" {
    try std.testing.expectEqual(@as(u32, 12), apply(9, 19, 1, 2, 1500).advance_width_px);
}
test "font spacing line height rounds independently of natural width" {
    try std.testing.expectEqual(Metrics{ .advance_width_px = 9, .glyph_width_px = 9, .height_px = 29 }, apply(9, 19, 1.5, 0, 1000));
}
