const std = @import("std");
extern fn maru_native_cell_rect_ffi(kind: u16, cw: f32, ch: f32, divider_px: u32, rect: *[4]f32) callconv(.c) void;
/// Apply the shared Metal strip policy before backend clipping. C is the
/// neutral owner because the original Objective-C renderer uses it directly.
pub fn project(kind: u16, rect: [4]f32, cw: f32, ch: f32, divider_px: u32) [4]f32 {
    var result = rect;
    maru_native_cell_rect_ffi(kind, cw, ch, divider_px, &result);
    return result;
}
fn expect(kind: u16, expected: [4]f32) !void {
    const result = project(kind, .{ 100, 200, 10, 20 }, 10, 20, 4);
    for (result, expected) |a, b| try std.testing.expectApproxEqAbs(b, a, 0.0001);
}
test "native cell rect top and bottom cursor strips keep the center empty" {
    try expect(2, .{ 100, 217, 10, 3 });
    try expect(4, .{ 100, 200, 10, 3 });
}
test "native cell rect left and right cursor strips keep the center empty" {
    try expect(3, .{ 100, 200, 2, 20 });
    try expect(5, .{ 108, 200, 2, 20 });
}
test "native cell rect text decoration is thin and centered independently" {
    try expect(9, .{ 100, 218.5, 10, 1.5 });
    try expect(10, .{ 100, 200, 10, 1.5 });
    try expect(6, .{ 100, 209.25, 10, 1.5 });
}
test "native cell rect double underline and gutter retain their gaps" {
    try expect(7, .{ 100, 215.8, 10, 1.5 });
    try expect(8, .{ 96, 200, 2, 20 });
}
test "native cell rect divider clamp and ordinary glyph preserve the original bounds" {
    try expect(0, .{ 100, 200, 10, 20 });
    try expect(32, .{ 100, 200, 10, 20 });
    try expect(30, .{ 98, 200, 4, 20 });
    try expect(31, .{ 100, 198, 10, 4 });
    try std.testing.expectEqual([4]f32{ 95, 200, 10, 20 }, project(30, .{ 100, 200, 10, 20 }, 10, 20, 100));
}
