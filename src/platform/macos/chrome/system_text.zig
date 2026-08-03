//! Session Dock measured system-UI text adapter.
//!
//! CoreText owns CTLine/CTRun and returns only scalar glyph facts.  This module owns the
//! conversion to renderer-neutral records plus final local pixel positions; it deliberately
//! does not know about AppSession, Metal DTOs, or terminal `ResolvedAppearance`.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const bridge = @import("../coretext_smoke_bridge.zig");
const probe = @import("../coretext_probe.zig");
const metal_frame = renderer.metal_frame;

pub const Placement = struct {
    x_px: f32,
    y_px: f32,
    advance_px: f32,
    line_height_px: f32,
    foreground: u32,
};

pub const Artifact = struct {
    records: []renderer.ShapedGlyphRecord,
    placements: []Placement,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.placements);
        self.* = undefined;
    }

    pub fn appendGpuGlyphs(
        self: Artifact,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas: renderer.GlyphAtlasConfig,
        origin_x_px: u32,
        origin_y_px: u32,
        out: *std.ArrayList(metal_frame.GpuGlyph),
    ) !void {
        if (frame.glyph_quad_frame.glyphs.len != self.placements.len) return error.MeasuredGlyphCountMismatch;
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs, self.placements) |glyph, placement| {
            const uv = try renderer.glyph_quads.uvRectForSlot(glyph.slot, texture);
            try out.append(allocator, .{
                .x = @as(f32, @floatFromInt(origin_x_px)) + placement.x_px,
                .y = @as(f32, @floatFromInt(origin_y_px)) + placement.y_px,
                .w = @floatFromInt(glyph.slot.width_px),
                .h = @floatFromInt(glyph.slot.height_px),
                .atlas_x_px = glyph.slot.x_px,
                .atlas_y_px = glyph.slot.y_px,
                .atlas_width_px = glyph.slot.width_px,
                .atlas_height_px = glyph.slot.height_px,
                .u0 = if (glyph.run.cache_key.color_glyph_kind == .color) uv.u0 + 2.0 else uv.u0,
                .v0 = uv.v0,
                .u1 = uv.u1,
                .v1 = uv.v1,
                .foreground = placement.foreground,
                .layer = 0,
            });
        }
    }
};

/// Shapes every non-icon Session Dock text op into one immutable artifact. Registered SVG icon
/// ops stay on the legacy synthesized-glyph path until their vector texture migration lands;
/// treating their PUA values as system UI text would silently erase affordances.
pub fn shapeOps(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    scale_milli: u32,
) !Artifact {
    var records: std.ArrayList(renderer.ShapedGlyphRecord) = .empty;
    errdefer records.deinit(allocator);
    var placements: std.ArrayList(Placement) = .empty;
    errdefer placements.deinit(allocator);
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.wide_icons or text.origin.x < 0 or text.origin.y < 0) continue;
            const max_width = std.math.mul(u32, text.max_cols, cell_width_px) catch continue;
            for (text.runs) |run| {
                var shaped = shapeRun(allocator, registry, run.text, text.text_role, text.origin, max_width, packRgb(tk.get(text.role)), scale_milli) catch continue;
                defer shaped.deinit(allocator);
                const base = records.items.len;
                try records.appendSlice(allocator, shaped.records);
                try placements.appendSlice(allocator, shaped.placements);
                for (records.items[base..], base..) |*record, index| {
                    record.row = @intCast(index / 256);
                    record.col = @intCast(index % 256);
                }
            }
        },
        else => {},
    };
    return .{ .records = try records.toOwnedSlice(allocator), .placements = try placements.toOwnedSlice(allocator) };
}

pub fn emptyDrawList(allocator: std.mem.Allocator, glyph_count: usize) !renderer.DrawList {
    const rows: u16 = @intCast(@max(@as(usize, 1), (glyph_count + 255) / 256));
    return .{
        .size = .{ .cols = 256, .rows = rows },
        .cursor = .{ .visible = false },
        .dirty = .{ .start_row = 0, .end_row = rows - 1 },
        .cells = try allocator.alloc(renderer.DrawCell, 0),
        .grapheme_pool = try allocator.alloc(u32, 0),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

fn weight(role: chrome.ui.typography.ChromeTextRole) u32 {
    return switch (chrome.ui.typography.token(role).weight) {
        .regular => 0,
        .medium, .semibold => 1,
    };
}

fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// Shapes exactly one semantic run.  `origin` is the component's final local line-box origin;
/// the native bridge supplies proportional advances and actual fallback face identity.
pub fn shapeRun(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    text: []const u8,
    role: chrome.ui.typography.ChromeTextRole,
    origin: chrome.draw.Px,
    max_width_px: u32,
    foreground: u32,
    scale_milli: u32,
) !Artifact {
    if (text.len == 0 or max_width_px == 0) return .{ .records = try allocator.alloc(renderer.ShapedGlyphRecord, 0), .placements = try allocator.alloc(Placement, 0) };
    const point_size = chrome.ui.typography.token(role).point_size;
    const scaled_size = @as(f64, @floatFromInt(point_size)) * @as(f64, @floatFromInt(scale_milli)) / 1000.0;
    var native: bridge.NativeChromeTextShapeResult = .{};
    const capacity = @max(@as(usize, 16), text.len * 2);
    var glyphs = try allocator.alloc(bridge.NativeChromeTextGlyphRecord, capacity);
    defer allocator.free(glyphs);
    bridge.maru_macos_coretext_shape_chrome_text(text.ptr, text.len, scaled_size, weight(role), @floatFromInt(max_width_px), &native, glyphs.ptr, glyphs.len);
    if (native.status != 0 or native.glyph_record_overflow != 0) return error.CoreTextChromeTextShapeFailed;
    const count = @min(@as(usize, native.glyph_record_count), glyphs.len);
    const records = try allocator.alloc(renderer.ShapedGlyphRecord, count);
    errdefer allocator.free(records);
    const placements = try allocator.alloc(Placement, count);
    for (glyphs[0..count], records, placements, 0..) |native_glyph, *record, *placement, index| {
        const name = probe.cStringField(&native_glyph.font_name);
        const font_id = try registry.intern(.{ .postscript_name = name });
        const advance = @max(native_glyph.advance_px, 1.0);
        const line_height: f32 = @floatFromInt(chrome.ui.typography.lineHeightPx(role, scale_milli));
        record.* = .{
            .row = 0,
            .col = @intCast(index),
            .cell_width = 1,
            .codepoint = @intCast(@min(native_glyph.codepoint, std.math.maxInt(u21))),
            .font_id = font_id,
            .glyph_id = native_glyph.glyph_id,
            .fallback = native_glyph.fallback != 0,
            .color_glyph_kind = if (native_glyph.color_glyph_kind != 0) .color else .monochrome,
            .raster_font_size_milli = @intCast(@as(u32, point_size) * 1000),
            .raster_width_px = @intFromFloat(@ceil(advance)),
            .raster_height_px = @intFromFloat(@ceil(line_height)),
        };
        placement.* = .{
            .x_px = @as(f32, @floatFromInt(origin.x)) + native_glyph.x_px,
            .y_px = @floatFromInt(origin.y),
            .advance_px = advance,
            .line_height_px = line_height,
            .foreground = foreground,
        };
    }
    return .{ .records = records, .placements = placements };
}
