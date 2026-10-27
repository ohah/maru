//! Native bitmap tests: shaping placement must not clip negative bearings.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("maru").dwrite_font;
const w = 96;
const h = 64;
const pitch = w * 4;
const Bitmap = [pitch * h]u8;

fn draw(r: *font.Rasterizer, x: f32, y: f32, pixels: *Bitmap) !u32 {
    const scratch = try std.testing.allocator.alloc(u8, font.Rasterizer.scratchSize(w, h));
    defer std.testing.allocator.free(scratch);
    @memset(pixels, 0);
    return r.rasterizeGlyphAtOrigin(r.glyphFor('j') orelse return error.TestUnexpectedResult, 22, w, h, x, y, pitch, pixels, scratch);
}

fn shifted(a: *const Bitmap, b: *const Bitmap, dx: i32, dy: i32) !void {
    for (0..h) |y| for (0..w) |x| {
        const sx = @as(i32, @intCast(x)) - dx;
        const sy = @as(i32, @intCast(y)) - dy;
        const actual = b[(y * w + x) * 4 ..][0..4];
        if (sx < 0 or sx >= w or sy < 0 or sy >= h) {
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, actual);
        } else {
            const offset = (@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))) * 4;
            try std.testing.expectEqualSlices(u8, a[offset..][0..4], actual);
        }
    };
}

test "Windows raster origin native horizontal translation preserves every pixel" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try font.Rasterizer.createStyled(std.testing.allocator, "Consolas", "", 22, .italic);
    defer r.destroy();
    var a: Bitmap = undefined;
    var b: Bitmap = undefined;
    const count = try draw(r, 16, 40, &a);
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(count, try draw(r, 23, 40, &b));
    try shifted(&a, &b, 7, 0);
}

test "Windows raster origin native vertical translation preserves every pixel" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try font.Rasterizer.create(std.testing.allocator, "Consolas", "", 22);
    defer r.destroy();
    var a: Bitmap = undefined;
    var b: Bitmap = undefined;
    const count = try draw(r, 16, 40, &a);
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(count, try draw(r, 16, 36, &b));
    try shifted(&a, &b, 0, -4);
}

test "Windows raster origin legacy wrapper matches explicit existing baseline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try font.Rasterizer.create(std.testing.allocator, "Consolas", "", 22);
    defer r.destroy();
    var a: Bitmap = @splat(0);
    var b: Bitmap = undefined;
    const scratch = try std.testing.allocator.alloc(u8, font.Rasterizer.scratchSize(w, h));
    defer std.testing.allocator.free(scratch);
    const count = try r.rasterizeGlyphAtSize(r.glyphFor('j').?, 22, w, h, pitch, &a, scratch);
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(count, try draw(r, 0, font.glyphBaselineForSize(r.design, 22, h), &b));
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "Windows raster origin negative bearing is retained by padding and clips safely" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try font.Rasterizer.createStyled(std.testing.allocator, "Consolas", "", 22, .italic);
    defer r.destroy();
    var a: Bitmap = undefined;
    var b: Bitmap = undefined;
    const padded = try draw(r, 16, 40, &a);
    const clipped = try draw(r, 0, 40, &b);
    try std.testing.expect(padded > clipped and clipped > 0);
    try shifted(&a, &b, -16, 0);
    try std.testing.expectEqual(@as(u32, 0), try draw(r, -100, -100, &b));
    for (b) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "Windows raster origin invalid geometry and buffers preserve destination" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try font.Rasterizer.create(std.testing.allocator, "Consolas", "", 22);
    defer r.destroy();
    var pixels: Bitmap = @splat(0x5a);
    const choice = r.glyphFor('j').?;
    const scratch = try std.testing.allocator.alloc(u8, font.Rasterizer.scratchSize(w, h));
    defer std.testing.allocator.free(scratch);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtOrigin(choice, 22, w, h, bad, 40, pitch, &pixels, &.{}));
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtOrigin(choice, 22, w, h, 16, bad, pitch, &pixels, &.{}));
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtOrigin(choice, bad, w, h, 16, 40, pitch, &pixels, &.{}));
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtSize(choice, bad, w, h, pitch, &pixels, &.{}));
    }
    for ([_]f32{ 0, -1 }) |bad| {
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtOrigin(choice, bad, w, h, 16, 40, pitch, &pixels, scratch));
        try std.testing.expectError(error.InvalidRasterGeometry, r.rasterizeGlyphAtSize(choice, bad, w, h, pitch, &pixels, scratch));
    }
    try std.testing.expectError(error.BufferTooSmall, r.rasterizeGlyphAtOrigin(choice, 22, w, h, 16, 40, pitch - 1, &pixels, scratch));
    try std.testing.expectError(error.BufferTooSmall, r.rasterizeGlyphAtOrigin(choice, 22, w, h, 16, 40, pitch, pixels[0 .. pixels.len - 1], scratch));
    try std.testing.expectError(error.BufferTooSmall, r.rasterizeGlyphAtOrigin(choice, 22, w, h, 16, 40, pitch, &pixels, &.{}));
    for (pixels) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}
