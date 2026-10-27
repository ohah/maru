//! Source-span contracts needed before a run can be placed on terminal cells.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const native = maru.dwrite_shape;

test "Windows glyph sources native clusters map onto fixed cells including fallback graphemes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var glyphs: [32]native.GlyphRecord = undefined;
    var sources: [32]native.GlyphSource = undefined;
    const cells = [_]maru.renderer.draw_list.DrawCell{
        .{ .row = 0, .col = 10, .codepoint = 'A' },
        .{ .row = 0, .col = 11, .width = 2, .codepoint = 0x1f600 },
        .{ .row = 0, .col = 13, .width = 2, .codepoint = 0x1100, .grapheme_count = 2 },
        .{ .row = 0, .col = 15, .codepoint = '=' },
        .{ .row = 0, .col = 16, .codepoint = '>' },
    };
    var prepared = try maru.renderer.shaping_runs.prepare(std.testing.allocator, &cells, &.{ 0x1161, 0x11a8 });
    defer prepared.deinit(std.testing.allocator);
    const request: native.Request = .{ .text = prepared.utf8, .family = "Fira Code", .fallback_csv = "", .size_px = 22 };
    const shaped = try shaper.shapeWithOptions(request, &glyphs, .{ .glyph_sources = &sources });
    try std.testing.expect(shaped.primary_found and !shaped.overflow and shaped.count > 0);
    // Independent fixture: one ASCII, a surrogate pair, a three-unit NFD
    // grapheme, then two operators. Cell count is seven, text length eight.
    const columns = [_]u16{ 10, 11, 11, 13, 13, 13, 15, 16 };
    const widths = [_]u2{ 1, 2, 2, 2, 2, 2, 1, 1 };
    var seen: [8]bool = @splat(false);
    try std.testing.expectEqual(@as(usize, 8), prepared.utf16_owners.len);
    for (prepared.utf16_owners, columns, widths) |owner, col, width| {
        try std.testing.expectEqual(col, owner.col);
        try std.testing.expectEqual(width, owner.width);
    }
    for (sources[0..shaped.count]) |item| {
        const mapped = try native.preparedGlyphCellSpan(prepared.utf16_owners, item);
        const first = item.utf16_start;
        const last = first + item.utf16_length - 1;
        @memset(seen[first .. last + 1], true);
        try std.testing.expectEqual(columns[first], mapped.col);
        try std.testing.expectEqual(@as(u16, columns[last] + widths[last] - columns[first]), mapped.width);
    }
    for (seen) |covered| try std.testing.expect(covered);
}

fn span(source: native.GlyphSource, start: u32, length: u32, head: u32) !void {
    try std.testing.expect(source.known);
    try std.testing.expectEqual(start, source.utf16_start);
    try std.testing.expectEqual(length, source.utf16_length);
    try std.testing.expectEqual(head, source.cluster_glyph_start);
}

test "Windows glyph sources preserve text origin and native position fields" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var out: [3]native.GlyphSource = @splat(.{ .baseline_x = 7.5, .baseline_y = 14, .advance_offset = -2.5, .ascender_offset = 3.25, .bidi_level = 3 });
    try native.mapGlyphSources(&.{ 0, 1, 2 }, 3, 5, &out);
    for (out, 0..) |item, i| {
        try span(item, @intCast(5 + i), 1, @intCast(i));
        try std.testing.expectEqual(@as(f32, 7.5), item.baseline_x);
        try std.testing.expectEqual(@as(f32, 14), item.baseline_y);
        try std.testing.expectEqual(@as(f32, -2.5), item.advance_offset);
        try std.testing.expectEqual(@as(f32, 3.25), item.ascender_offset);
        try std.testing.expectEqual(@as(u32, 3), item.bidi_level);
    }
}

test "Windows glyph sources handle merged expanded RTL and reordered clusters" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var out: [5]native.GlyphSource = @splat(.{});
    try native.mapGlyphSources(&.{ 0, 0, 2, 3, 3 }, 5, 10, &out);
    try span(out[0], 10, 2, 0);
    try span(out[1], 10, 2, 0);
    try span(out[2], 12, 1, 2);
    try span(out[3], 13, 2, 3);
    try span(out[4], 13, 2, 3);
    try native.mapGlyphSources(&.{ 3, 2, 0, 0 }, 4, 20, &out);
    try span(out[0], 22, 2, 0);
    try span(out[1], 22, 2, 0);
    try span(out[2], 21, 1, 2);
    try span(out[3], 20, 1, 3);
    try native.mapGlyphSources(&.{ 2, 0, 3 }, 4, 30, &out);
    try span(out[0], 31, 1, 0);
    try span(out[1], 31, 1, 0);
    try span(out[2], 30, 1, 2);
    try span(out[3], 32, 1, 3);
}

test "Windows glyph sources reject malformed maps and guard borrowed output bounds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var guarded: [4]native.GlyphSource = @splat(.{ .baseline_x = 12345 });
    const out = guarded[1..3];
    try std.testing.expectError(error.BufferTooSmall, native.mapGlyphSources(&.{ 0, 1, 2 }, 3, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{0}, 0, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{}, 1, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{1}, 2, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{ 0, 2 }, 2, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{ 0, 1, 0 }, 2, 0, out));
    try std.testing.expectError(error.InvalidClusterMap, native.mapGlyphSources(&.{ 0, 1 }, 2, std.math.maxInt(u32) - 1, out));
    try native.mapGlyphSources(&.{}, 0, 0, out);
    try std.testing.expectEqual(@as(f32, 12345), guarded[0].baseline_x);
    try std.testing.expectEqual(@as(f32, 12345), guarded[3].baseline_x);
}

fn codepointAt(units: []const u16, index: usize) u32 {
    const hi = units[index];
    if (hi >= 0xd800 and hi <= 0xdbff and index + 1 < units.len) {
        const lo = units[index + 1];
        if (lo >= 0xdc00 and lo <= 0xdfff) return 0x10000 + ((@as(u32, hi - 0xd800) << 10) | (lo - 0xdc00));
    }
    return hi;
}

test "Windows glyph sources native fallback NFD emoji and RTL retain exact source spans" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    const texts = [_][]const u8{ "q\u{0307} 한 🙂 =>", "مرحبا" };
    for (texts, 0..) |text, example| {
        var plain: [64]native.GlyphRecord = undefined;
        var glyphs: [64]native.GlyphRecord = undefined;
        var sources: [64]native.GlyphSource = undefined;
        const request: native.Request = .{ .text = text, .family = "Fira Code", .fallback_csv = "Jetendard", .size_px = 22 };
        const before = try shaper.shape(request, &plain);
        const result = try shaper.shapeWithOptions(request, &glyphs, .{ .glyph_sources = &sources });
        try std.testing.expect(!before.overflow and !result.overflow and result.count != 0);
        try std.testing.expectEqual(before.count, result.count);
        var wide: [128]u16 = undefined;
        const units = wide[0..try std.unicode.utf8ToUtf16Le(&wide, text)];
        var has_nfd = false;
        var has_rtl = false;
        for (sources[0..result.count], glyphs[0..result.count], plain[0..result.count], 0..) |source, glyph, old, i| {
            std.debug.print("\n source example={d} glyph={d} cp={x} utf16={d}+{d} head={d} offset={d},{d} baseline={d},{d} bidi={d}", .{ example, i, glyph.codepoint, source.utf16_start, source.utf16_length, source.cluster_glyph_start, source.advance_offset, source.ascender_offset, source.baseline_x, source.baseline_y, source.bidi_level });
            try std.testing.expect(source.known and source.utf16_length > 0);
            try std.testing.expect(source.utf16_start + source.utf16_length <= units.len);
            try std.testing.expect(source.cluster_glyph_start <= i);
            const head = sources[source.cluster_glyph_start];
            try std.testing.expectEqual(head.utf16_start, source.utf16_start);
            try std.testing.expectEqual(head.utf16_length, source.utf16_length);
            if (glyph.codepoint != 0) try std.testing.expectEqual(glyph.codepoint, codepointAt(units, source.utf16_start));
            try std.testing.expectEqual(old.glyph_id, glyph.glyph_id);
            try std.testing.expectEqual(old.x_px, glyph.x_px);
            try std.testing.expectEqual(old.advance_px, glyph.advance_px);
            try std.testing.expectEqualSlices(u8, &old.font_name, &glyph.font_name);
            has_nfd = has_nfd or (source.utf16_start == 3 and source.utf16_length == 3);
            has_rtl = has_rtl or source.bidi_level % 2 == 1;
        }
        if (example == 0) try std.testing.expect(has_nfd) else try std.testing.expect(has_rtl);
    }
}

test "Windows glyph sources native short source buffers report overflow without touching canaries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var glyphs: [32]native.GlyphRecord = undefined;
    var guarded: [3]native.GlyphSource = @splat(.{ .baseline_x = 12345 });
    const request: native.Request = .{ .text = "abcdef", .family = "Consolas", .fallback_csv = "", .size_px = 22 };
    const result = try shaper.shapeWithOptions(request, &glyphs, .{ .glyph_sources = guarded[1..2] });
    try std.testing.expect(result.overflow and result.count <= 1);
    try std.testing.expectEqual(@as(f32, 12345), guarded[0].baseline_x);
    try std.testing.expectEqual(@as(f32, 12345), guarded[2].baseline_x);
    const empty = try shaper.shapeWithOptions(request, &glyphs, .{ .glyph_sources = &.{} });
    try std.testing.expect(empty.overflow and empty.count == 0);
}
