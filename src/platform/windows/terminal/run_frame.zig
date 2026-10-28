//! Native run shaping and whole-frame partitioning. Input DrawList is consumed.
const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const native = maru.dwrite_shape;
const text = maru.win32_text;

fn pen(glyph: native.GlyphRecord, source: native.GlyphSource) f32 {
    return if (source.bidi_level & 1 != 0) source.baseline_x - (glyph.x_px - source.baseline_x) else glyph.x_px;
}

/// Strict one-run entry. Always consumes list, including validation failures.
pub fn buildRun(
    a: std.mem.Allocator,
    list: renderer.DrawList,
    state: *renderer.RendererState,
    cell_shaper: text.Shaper,
    rasterizer: text.NeutralRasterizer,
    shaper: *native.Shaper,
    fallback_csv: []const u8,
    ligatures: bool,
) !renderer.RenderFrame {
    var owned = list;
    errdefer owned.deinit(a);
    const cw = state.text_config.cell_width_px;
    const ch = state.text_config.cell_height_px;
    if (cw == 0 or ch == 0) return error.InvalidGrid;
    var records: std.ArrayList(renderer.shaped_records.ShapedGlyphRecord) = .empty;
    defer records.deinit(a);
    try appendNativeRun(a, list, state, cell_shaper, shaper, fallback_csv, ligatures, &records);
    return finish(a, list, state, rasterizer, records.items);
}

fn finish(a: std.mem.Allocator, list: renderer.DrawList, state: *renderer.RendererState, rasterizer: text.NeutralRasterizer, records: []const renderer.shaped_records.ShapedGlyphRecord) !renderer.RenderFrame {
    var shaped = try renderer.shaped_records.buildGlyphRunListFromShapedRecordsWithSurface(a, records, state.text_config, .{ .size = list.size, .cursor = list.cursor, .dirty = list.dirty, .overlays = list.overlays });
    defer shaped.deinit(a);
    var adapter = rasterizer;
    adapter.registry = &state.font_registry;
    adapter.registry_face_policy = .terminal_style;
    return state.buildFrameFromGlyphRunListWithRasterizer(a, list, shaped.runs, adapter);
}

fn appendNativeRun(
    a: std.mem.Allocator,
    list: renderer.DrawList,
    state: *renderer.RendererState,
    cell_shaper: text.Shaper,
    shaper: *native.Shaper,
    fallback_csv: []const u8,
    ligatures: bool,
    records: *std.ArrayList(renderer.shaped_records.ShapedGlyphRecord),
) !void {
    const cw = state.text_config.cell_width_px;
    const ch = state.text_config.cell_height_px;
    if (list.cells.len == 0) return;
    const key = renderer.shaping_runs.styleKey(list.cells[0], list.cursor);
    for (list.cells) |cell| {
        if (renderer.shaping_runs.styleKey(cell, list.cursor) != key) return error.MixedShapingRun;
        if (renderer.isSynthesizedCodepoint(cell.codepoint)) return error.SynthesizedRunRequiresPartition;
    }
    var prepared = try renderer.shaping_runs.prepare(a, list.cells, list.grapheme_pool);
    defer prepared.deinit(a);
    const face: usize = renderer.shaping_runs.faceKey(list.cells[0].style);
    const bank = if (face == 0) cell_shaper.raster else cell_shaper.variants[face - 1] orelse return error.MissingStyleBank;
    var capacity = try std.math.add(usize, try std.math.mul(usize, prepared.utf16_owners.len, 4), 1);
    var glyphs = try a.alloc(native.GlyphRecord, capacity);
    defer a.free(glyphs);
    var sources = try a.alloc(native.GlyphSource, capacity);
    defer a.free(sources);
    const result = while (true) {
        const result = try shaper.shapeWithOptions(.{ .text = prepared.utf8, .family = bank.family, .fallback_csv = fallback_csv, .size_px = bank.em_size_px }, glyphs, .{
            .glyph_sources = sources,
            .face_style = @fromBackingInt(@intCast(face)),
            .ligatures = ligatures and key & renderer.shaping_runs.cursor_bit == 0,
        });
        if (!result.overflow) break result;
        capacity = try std.math.mul(usize, capacity, 2);
        glyphs = try a.realloc(glyphs, capacity);
        sources = try a.realloc(sources, capacity);
    };
    for (glyphs[0..result.count], sources[0..result.count]) |glyph, source| {
        if (glyph.glyph_id == 0) {
            // Match the existing Windows cell shaper: missing text is blank,
            // explicitly counted as replacement, and never aborts other rows.
            const span = try native.preparedGlyphCellSpan(prepared.utf16_owners, source);
            const ps = std.mem.sliceTo(&glyph.font_name, 0);
            if (bank.faceIndexForName(ps) == null) return error.MissingNativeFace;
            const id = try state.font_registry.intern(.{ .postscript_name = ps });
            for (list.cells) |cell| {
                if (cell.col < span.col or @as(u32, cell.col) >= @as(u32, span.col) + span.width) continue;
                try records.append(a, .{ .row = cell.row, .col = cell.col, .cell_width = @max(1, cell.width), .codepoint = cell.codepoint, .font_id = id, .glyph_id = 0, .fallback = true, .replacement = true, .style = cell.style, .placement = .{} });
            }
            continue;
        }
        if (!source.ink_known) return error.MissingInkMetrics;
        if (!std.math.isFinite(source.ink_left_px) or !std.math.isFinite(source.ink_right_px)) return error.InvalidNativePosition;
        if (source.ink_right_px <= source.ink_left_px) continue;
        const span = try native.preparedGlyphCellSpan(prepared.utf16_owners, source);
        const first = prepared.utf16_owners[source.utf16_start].cell_index;
        var anchor: usize = source.cluster_glyph_start;
        if (anchor >= result.count) return error.InvalidNativeCluster;
        // A fallback can split a grapheme into several native font runs.
        // Anchor all of them to the earliest text position of its base cell.
        for (sources[0..result.count], 0..) |candidate, i| {
            if (!candidate.known or candidate.utf16_start >= prepared.utf16_owners.len) continue;
            if (prepared.utf16_owners[candidate.utf16_start].cell_index == first and
                (candidate.utf16_start < sources[anchor].utf16_start or
                    (candidate.utf16_start == sources[anchor].utf16_start and i < anchor))) anchor = i;
        }
        const rtl = source.bidi_level & 1 != 0;
        // DWRITE_GLYPH_OFFSET: positive advance follows run direction;
        // positive ascent points up. The terminal keeps logical cell order.
        // https://learn.microsoft.com/windows/win32/api/dwrite/ns-dwrite-dwrite_glyph_offset
        const x = @as(f32, @floatFromInt(@as(u32, span.col) * cw)) +
            (if (rtl) @as(f32, @floatFromInt(@as(u32, span.width) * cw)) else 0) +
            pen(glyph, source) - pen(glyphs[anchor], sources[anchor]) -
            (if (rtl) glyph.advance_px else 0) + (if (rtl) -source.advance_offset else source.advance_offset);
        const y = maru.dwrite_font.glyphBaselineForSize(bank.design, bank.em_size_px, ch) +
            source.baseline_y - sources[anchor].baseline_y - source.ascender_offset;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidNativePosition;
        const ps = std.mem.sliceTo(&glyph.font_name, 0);
        if (bank.faceIndexForName(ps) == null) return error.MissingNativeFace;
        const id = try state.font_registry.intern(.{ .postscript_name = ps });
        // The bitmap is clipped in local cell coordinates. Its baseline is
        // ink identity; placement merely moves this clipped mask on screen.
        for (list.cells) |target| {
            const width = @max(@as(u32, 1), target.width);
            const left: f32 = @floatFromInt(@as(u32, target.col) * cw);
            const right = left + @as(f32, @floatFromInt(width * cw));
            if (right <= x + source.ink_left_px - 2 or left >= x + source.ink_right_px + 2) continue;
            const owner = target;
            try records.append(a, .{
                .row = owner.row,
                .col = owner.col,
                .cell_width = @max(1, owner.width),
                .codepoint = if (list.cells[first].codepoint == 0) ' ' else list.cells[first].codepoint,
                .font_id = id,
                .glyph_id = glyph.glyph_id,
                .style = owner.style,
                .fallback = !std.ascii.eqlIgnoreCase(ps, bank.face_ps_names[0][0..bank.face_ps_name_len[0]]),
                .raster_width_px = std.math.cast(u16, width * cw) orelse return error.InvalidGrid,
                .raster_height_px = ch,
                .raster_origin = try renderer.glyph_layout.GlyphRasterOrigin.fromPixels(x - left, y),
                .placement = .{},
            });
        }
    }
}

const boundary = @import("native_shaping_run_c");

/// One native font call cannot cross rows, gaps, faces or the visible cursor.
/// Synthesized geometry is isolated by the Windows adapter before native text.
pub fn runEnd(cells: []const renderer.DrawCell, cursor: maru.terminal.Cursor, start: usize) usize {
    var end = start + 1;
    while (end < cells.len) : (end += 1) {
        const previous = cells[end - 1];
        const current = cells[end];
        if (renderer.isSynthesizedCodepoint(previous.codepoint) or renderer.isSynthesizedCodepoint(current.codepoint)) break;
        if (!boundary.maru_native_run_continues(previous.row, previous.col, previous.width, renderer.shaping_runs.styleKey(previous, cursor), current.row, current.col, renderer.shaping_runs.styleKey(current, cursor))) break;
    }
    return end;
}

/// Publish one frame only after every run has been shaped. No partial frame is
/// returned when a later native run or allocation fails.
pub fn build(
    a: std.mem.Allocator,
    list: renderer.DrawList,
    state: *renderer.RendererState,
    cell_shaper: text.Shaper,
    rasterizer: text.NeutralRasterizer,
    shaper: *native.Shaper,
    fallback_csv: []const u8,
    ligatures: bool,
) !renderer.RenderFrame {
    var owned = list;
    errdefer owned.deinit(a);
    if (state.text_config.cell_width_px == 0 or state.text_config.cell_height_px == 0) return error.InvalidGrid;
    var records: std.ArrayList(renderer.shaped_records.ShapedGlyphRecord) = .empty;
    defer records.deinit(a);
    var start: usize = 0;
    while (start < list.cells.len) {
        const end = runEnd(list.cells, list.cursor, start);
        const cell = list.cells[start];
        if (renderer.isSynthesizedCodepoint(cell.codepoint)) {
            // Font-independent geometry is dispatched before registry lookup.
            try records.append(a, .{ .row = cell.row, .col = cell.col, .cell_width = @max(1, cell.width), .codepoint = cell.codepoint, .font_id = 0, .glyph_id = 0, .style = cell.style });
        } else {
            var run = list;
            run.cells = list.cells[start..end];
            try appendNativeRun(a, run, state, cell_shaper, shaper, fallback_csv, ligatures, &records);
        }
        start = end;
    }
    return finish(a, list, state, rasterizer, records.items);
}
