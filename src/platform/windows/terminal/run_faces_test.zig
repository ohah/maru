//! Compare actual shaped face identities with the terminal raster banks.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const font = maru.dwrite_font;
const native = maru.dwrite_shape;

fn expectFamilyFaces(family: []const u8) !void {
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var names: [4][128]u8 = undefined;
    for ([_]font.FaceStyle{ .regular, .bold, .italic, .bold_italic }, 0..) |style, i| {
        var raster = try font.Rasterizer.createStyled(std.testing.allocator, family, "", 22, style);
        defer raster.destroy();
        var out: [16]native.GlyphRecord = undefined;
        const result = try shaper.shapeWithOptions(.{ .text = "Mi", .family = family, .fallback_csv = "", .size_px = 22 }, &out, .{ .face_style = style, .ligatures = false });
        try std.testing.expect(result.primary_found and !result.overflow);
        try std.testing.expectEqual(@as(usize, 2), result.count);
        const ps = raster.face_ps_names[0][0..raster.face_ps_name_len[0]];
        try std.testing.expect(ps.len > 0);
        for (out[0..result.count], [_]u32{ 'M', 'i' }) |glyph, cp| {
            const choice = raster.glyphFor(cp) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 0), choice.face_index);
            try std.testing.expectEqualStrings(ps, std.mem.sliceTo(&glyph.font_name, 0));
            try std.testing.expectEqual(@as(u32, choice.glyph_id), glyph.glyph_id);
        }
        names[i] = out[0].font_name;
        // An oracle sharing the same bad trait mapping could agree with the
        // shaper. Require four distinct real face identities as well.
        for (names[0..i]) |before| try std.testing.expect(!std.mem.eql(u8, &before, &names[i]));
    }
}

test "Windows run faces native parameters match four terminal styles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const weights = [_]u32{ 400, 700, 400, 700 };
    const slants = [_]u32{ 0, 0, 2, 2 };
    for ([_]font.FaceStyle{ .regular, .bold, .italic, .bold_italic }, weights, slants) |style, weight, slant| {
        try std.testing.expectEqual(weight, style.nativeWeight());
        try std.testing.expectEqual(slant, style.nativeStyle());
    }
}

test "Windows run faces native selection matches system raster face identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectFamilyFaces("Consolas");
}

test "Windows run faces bundled selection matches raster face identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectFamilyFaces("JetBrains Mono");
}

test "Windows run faces explicit regular overrides chrome semibold request" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var reference: [16]native.GlyphRecord = undefined;
    var out: [16]native.GlyphRecord = undefined;
    var request: native.Request = .{ .text = "Mi", .family = "Consolas", .fallback_csv = "", .size_px = 22 };
    const regular = try shaper.shape(request, &reference);
    request.weight = .semibold;
    const explicit = try shaper.shapeWithOptions(request, &out, .{ .face_style = .regular });
    try std.testing.expect(regular.count > 0 and !regular.overflow and !explicit.overflow);
    try std.testing.expectEqual(regular.count, explicit.count);
    for (reference[0..regular.count], out[0..explicit.count]) |a, b| {
        try std.testing.expectEqualSlices(u8, &a.font_name, &b.font_name);
        try std.testing.expectEqual(a.glyph_id, b.glyph_id);
    }
}

test "Windows run faces omitted option preserves request weight and existing defaults" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var regular: [16]native.GlyphRecord = undefined;
    var semibold: [16]native.GlyphRecord = undefined;
    var explicit: [16]native.GlyphRecord = undefined;
    var request: native.Request = .{ .text = "Mi", .family = "Consolas", .fallback_csv = "", .size_px = 22 };
    const a = try shaper.shape(request, &regular);
    request.weight = .semibold;
    const b = try shaper.shape(request, &semibold);
    const c = try shaper.shapeWithOptions(request, &explicit, .{ .face_style = .bold, .ligatures = false });
    try std.testing.expect(a.count > 0 and b.count > 0 and !a.overflow and !b.overflow and !c.overflow);
    try std.testing.expectEqual(b.count, c.count);
    try std.testing.expect(!std.mem.eql(u8, &regular[0].font_name, &semibold[0].font_name));
    for (semibold[0..b.count], explicit[0..c.count]) |left, right| {
        try std.testing.expectEqualSlices(u8, &left.font_name, &right.font_name);
        try std.testing.expectEqual(left.glyph_id, right.glyph_id);
    }
}
