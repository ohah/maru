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

test "rgb holds three independent 8-bit channels" {
    const std = @import("std");
    const c: Rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    try std.testing.expectEqual(@as(u8, 0x10), c.r);
    try std.testing.expectEqual(@as(u8, 0x20), c.g);
    try std.testing.expectEqual(@as(u8, 0x30), c.b);
}
