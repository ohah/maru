//! backend-neutral 색 primitive.
//!
//! 색 값은 terminal cell, renderer theme, config resolve 등 여러 레이어가 공유한다.
//! 특정 도메인(예: terminal) 안에 두면 config나 renderer가 색 하나 때문에 그 도메인을
//! import해야 해서 레이어 경계가 흐려진다. 그래서 공용 top-level 모듈로 분리한다.

/// 채널당 8-bit RGB. alpha나 palette index 같은 도메인 의미는 담지 않는다. 그런
/// 의미가 필요한 곳(예: terminal `Color` union의 default/indexed)은 이 타입을 감싸서 둔다.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

// 표준 xterm 16색 팔레트(0..15). 터미널 `Color.indexed`를 화면 RGB로 풀 때 쓴다.
const ansi16 = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 }, // 0 black
    .{ .r = 128, .g = 0, .b = 0 }, // 1 red
    .{ .r = 0, .g = 128, .b = 0 }, // 2 green
    .{ .r = 128, .g = 128, .b = 0 }, // 3 yellow
    .{ .r = 0, .g = 0, .b = 128 }, // 4 blue
    .{ .r = 128, .g = 0, .b = 128 }, // 5 magenta
    .{ .r = 0, .g = 128, .b = 128 }, // 6 cyan
    .{ .r = 192, .g = 192, .b = 192 }, // 7 white
    .{ .r = 128, .g = 128, .b = 128 }, // 8 bright black
    .{ .r = 255, .g = 0, .b = 0 }, // 9 bright red
    .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
    .{ .r = 0, .g = 0, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
    .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// xterm 256색 index를 RGB로 푼다: 0..15 ANSI, 16..231 6×6×6 cube, 232..255 grayscale ramp.
pub fn xterm256(index: u8) Rgb {
    if (index < 16) return ansi16[index];
    if (index < 232) {
        const n = index - 16;
        return .{
            .r = cube_levels[n / 36],
            .g = cube_levels[(n / 6) % 6],
            .b = cube_levels[n % 6],
        };
    }
    const level: u8 = 8 + (index - 232) * 10;
    return .{ .r = level, .g = level, .b = level };
}

test "rgb holds three independent 8-bit channels" {
    const std = @import("std");
    const c: Rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    try std.testing.expectEqual(@as(u8, 0x10), c.r);
    try std.testing.expectEqual(@as(u8, 0x20), c.g);
    try std.testing.expectEqual(@as(u8, 0x30), c.b);
}

test "xterm256 resolves ansi, color cube, and grayscale ranges" {
    const std = @import("std");
    // ANSI 16
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(0));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(9));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(15));
    // 6x6x6 cube: 16 = (0,0,0), 231 = (255,255,255)
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(16));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(231));
    // cube 196 = 16 + 180 -> n=180 -> r=180/36=5(255), g=(180/6)%6=0, b=0
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(196));
    // grayscale ramp: 232 = 8, 255 = 238
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, xterm256(232));
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, xterm256(255));
}
