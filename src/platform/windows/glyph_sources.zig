//! Invert DirectWrite's UTF-16 -> first-glyph cluster map without allocating.
//! Numeric glyph order need not follow text order (RTL and reordered scripts).
const std = @import("std");

pub const Source = struct {
    known: bool = false,
    utf16_start: u32 = 0,
    utf16_length: u32 = 0,
    cluster_glyph_start: u32 = 0,
    // Native pre-transform values, captured without guessing a fixed-cell origin.
    baseline_x: f32 = 0,
    baseline_y: f32 = 0,
    advance_offset: f32 = 0,
    ascender_offset: f32 = 0,
    bidi_level: u32 = 0,
};

pub const Error = error{ BufferTooSmall, InvalidClusterMap };

/// The caller initializes positioning fields. Only source/cluster fields change.
/// Output is unspecified on error, but every write stays inside the given slice.
pub fn assign(map: []const u16, glyph_count: usize, text_position: u32, out: []Source) Error!void {
    if (out.len < glyph_count) return error.BufferTooSmall;
    const max = std.math.maxInt(u32);
    if (glyph_count > max or map.len > max - text_position) return error.InvalidClusterMap;
    if (glyph_count == 0) {
        if (map.len != 0) return error.InvalidClusterMap;
        return;
    }
    if (map.len == 0) return error.InvalidClusterMap;
    var has_zero = false;
    for (map) |index| {
        if (index >= glyph_count) return error.InvalidClusterMap;
        has_zero = has_zero or index == 0;
    }
    if (!has_zero) return error.InvalidClusterMap;
    for (out[0..glyph_count]) |*item| {
        item.known = false;
        item.utf16_start = 0;
        item.utf16_length = 0;
        item.cluster_glyph_start = 0;
    }
    // Anchor each cluster at its first glyph. Repeated non-contiguous anchors
    // would describe disjoint text as one cluster; reject instead of guessing.
    var text: usize = 0;
    while (text < map.len) {
        const first = map[text];
        var end = text + 1;
        while (end < map.len and map[end] == first) : (end += 1) {}
        if (out[first].known) return error.InvalidClusterMap;
        out[first].known = true;
        out[first].utf16_start = text_position + @as(u32, @intCast(text));
        out[first].utf16_length = @intCast(end - text);
        out[first].cluster_glyph_start = first;
        text = end;
    }
    // A cluster can emit several glyphs. Fill the interval until the next
    // numeric anchor, even when text anchors were encountered in reverse order.
    var head: usize = 0;
    for (out[0..glyph_count], 0..) |*item, glyph| {
        if (item.known) head = glyph;
        item.known = true;
        item.utf16_start = out[head].utf16_start;
        item.utf16_length = out[head].utf16_length;
        item.cluster_glyph_start = @intCast(head);
    }
}
