//! Chrome-native logical spacing scale.
//!
//! Components resolve this closed scale once at a backing scale and pass resulting pixels through
//! a completed `UiRectTree`. They do not accept CSS utility strings or re-derive padding from
//! terminal cell metrics.

const std = @import("std");

pub const Space = enum(u8) {
    xxs = 4,
    xs = 8,
    sm = 12,
    md = 16,
    lg = 20,
    xl = 24,
    xxl = 32,
};

pub fn pointsPx(points: u16, scale_milli: u32) u32 {
    const scale = @max(scale_milli, 1);
    const scaled = @as(u64, points) * @as(u64, scale);
    return @intCast(@min((scaled + 999) / 1000, std.math.maxInt(u32)));
}

pub fn px(step: Space, scale_milli: u32) u32 {
    return pointsPx(@intFromEnum(step), scale_milli);
}

test "spacing resolves logical steps once at backing scale" {
    try std.testing.expectEqual(@as(u32, 16), px(.md, 1000));
    try std.testing.expectEqual(@as(u32, 24), px(.sm, 2000));
    try std.testing.expectEqual(@as(u32, 1), pointsPx(1, 1));
}
