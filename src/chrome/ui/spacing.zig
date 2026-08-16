//! Chrome 고유의 논리 spacing scale이다.
//!
//! component는 이 닫힌 scale을 backing scale에서 한 번만 해석하고, 그 결과 픽셀을 완성된
//! `UiRectTree`로 넘긴다. CSS utility 문자열을 받거나 terminal cell 메트릭에서 padding을 다시
//! 유도하지 않는다.

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
