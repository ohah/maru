//! Session Dock measured system-UI text adapter.
//!
//! CoreText owns CTLine/CTRun and returns only scalar glyph facts.  This module owns the
//! conversion to renderer-neutral records plus final local pixel positions; it deliberately
//! does not know about AppSession, Metal DTOs, or terminal `ResolvedAppearance`.

const std = @import("std");
const builtin = @import("builtin");
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

/// An owned, renderer-free description of the semantic text that CoreText must shape.  It can
/// cross to the detached worker because it contains no draw-list borrow, native handle, atlas
/// state, or FontIdentityRegistry reference.
pub const Request = struct {
    fingerprint: u64,
    runs: []Run,

    pub const Run = struct {
        text: []u8,
        role: chrome.ui.typography.ChromeTextRole,
        origin: chrome.draw.Px,
        max_width_px: u32,
        foreground: u32,
    };

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        for (self.runs) |run| allocator.free(run.text);
        allocator.free(self.runs);
        self.* = undefined;
    }
};

/// Scalar CoreText result which deliberately keeps the selected PostScript name as bytes rather
/// than a renderer FontId.  The worker may create this, but the main actor alone resolves it into
/// renderer registry state.
pub const UnresolvedGlyph = struct {
    glyph_id: u32,
    codepoint: u32,
    fallback: bool,
    color_glyph_kind: renderer.ColorGlyphKind,
    x_px: f32,
    advance_px: f32,
    font_name: [128]u8,
    point_size: u16,
    line_height_px: f32,
    origin: chrome.draw.Px,
    foreground: u32,
};

pub const UnresolvedArtifact = struct {
    glyphs: []UnresolvedGlyph,

    pub fn deinit(self: *UnresolvedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
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
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs) |glyph| {
            // Atlas placement may reorder/repack glyph runs.  The synthetic row/column pair is
            // the immutable record identity created in shapeOps; positional zip here would put
            // a later label at an earlier label's pixel origin and visibly stack the dock header.
            const placement_index = @as(usize, glyph.run.row) * 256 + glyph.run.col;
            if (placement_index >= self.placements.len) return error.MeasuredGlyphPlacementMissing;
            const placement = self.placements[placement_index];
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
    var request = try prepareRequest(allocator, 0, ops, tk, cell_width_px);
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

/// Copies only non-icon semantic text out of the frame-local draw list.  This is intentionally
/// cheap enough for the frame path; CoreText shaping is performed only by `shapeRequest`.
pub fn prepareRequest(
    allocator: std.mem.Allocator,
    fingerprint: u64,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
) !Request {
    var runs: std.ArrayList(Request.Run) = .empty;
    errdefer {
        for (runs.items) |run| allocator.free(run.text);
        runs.deinit(allocator);
    }
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.wide_icons or text.origin.x < 0 or text.origin.y < 0) continue;
            const max_width = std.math.mul(u32, text.max_cols, cell_width_px) catch continue;
            for (text.runs) |run| {
                if (run.text.len == 0 or max_width == 0) continue;
                try runs.append(allocator, .{
                    .text = try allocator.dupe(u8, run.text),
                    .role = text.text_role,
                    .origin = text.origin,
                    .max_width_px = max_width,
                    .foreground = packRgb(tk.get(text.role)),
                });
            }
        },
        else => {},
    };
    return .{ .fingerprint = fingerprint, .runs = try runs.toOwnedSlice(allocator) };
}

test "prepareRequest keeps a Korean button label on measured text path while excluding its SVG icon" {
    const allocator = std.testing.allocator;
    const icon_runs = [_]chrome.draw.Run{.{ .text = "\u{F000C}" }};
    const label_runs = [_]chrome.draw.Run{.{ .text = "터미널에서 이어하기" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{
            .origin = .{ .x = 24, .y = 8 },
            .runs = &icon_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 2,
            .wide_icons = true,
        } },
        .{ .text = .{
            .origin = .{ .x = 48, .y = 8 },
            .runs = &label_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 18,
        } },
    };
    const tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 17, &ops, &tk, 8);
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), request.runs.len);
    try std.testing.expectEqualStrings("터미널에서 이어하기", request.runs[0].text);
    try std.testing.expectEqual(chrome.ui.typography.ChromeTextRole.button_label, request.runs[0].role);
    try std.testing.expectEqual(@as(u32, 18 * 8), request.runs[0].max_width_px);
}

/// Calls CoreText without touching the renderer.  `Request` owns every input byte, so this is
/// safe to run in a detached worker under CoreText's documented thread-safety contract.
pub fn shapeRequest(allocator: std.mem.Allocator, request: *const Request, scale_milli: u32) !UnresolvedArtifact {
    var glyphs: std.ArrayList(UnresolvedGlyph) = .empty;
    errdefer glyphs.deinit(allocator);
    for (request.runs) |run| {
        const shaped = shapeUnresolvedRun(allocator, run, scale_milli) catch continue;
        defer allocator.free(shaped);
        try glyphs.appendSlice(allocator, shaped);
    }
    return .{ .glyphs = try glyphs.toOwnedSlice(allocator) };
}

/// Resolves a completed worker DTO on the main actor.  This bounded conversion is the sole
/// owner of FontIdentityRegistry and intentionally contains no CoreText call.
pub fn resolveArtifact(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    unresolved: UnresolvedArtifact,
) !Artifact {
    const records = try allocator.alloc(renderer.ShapedGlyphRecord, unresolved.glyphs.len);
    errdefer allocator.free(records);
    const placements = try allocator.alloc(Placement, unresolved.glyphs.len);
    for (unresolved.glyphs, records, placements, 0..) |glyph, *record, *placement, index| {
        const name = probe.cStringField(&glyph.font_name);
        const font_id = try registry.intern(.{ .postscript_name = name });
        const advance = @max(glyph.advance_px, 1.0);
        record.* = .{
            .row = @intCast(index / 256),
            .col = @intCast(index % 256),
            .cell_width = 1,
            .codepoint = @intCast(@min(glyph.codepoint, std.math.maxInt(u21))),
            .font_id = font_id,
            .glyph_id = glyph.glyph_id,
            .fallback = glyph.fallback,
            .color_glyph_kind = glyph.color_glyph_kind,
            .raster_font_size_milli = @intCast(@as(u32, glyph.point_size) * 1000),
            .raster_width_px = @intFromFloat(@ceil(advance)),
            .raster_height_px = @intFromFloat(@ceil(glyph.line_height_px)),
        };
        placement.* = .{
            .x_px = @as(f32, @floatFromInt(glyph.origin.x)) + glyph.x_px,
            .y_px = @floatFromInt(glyph.origin.y),
            .advance_px = advance,
            .line_height_px = glyph.line_height_px,
            .foreground = glyph.foreground,
        };
    }
    return .{ .records = records, .placements = placements };
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
    const owned = try allocator.dupe(u8, text);
    var request = Request{ .fingerprint = 0, .runs = &.{.{ .text = owned, .role = role, .origin = origin, .max_width_px = max_width_px, .foreground = foreground }} };
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

fn shapeUnresolvedRun(allocator: std.mem.Allocator, run: Request.Run, scale_milli: u32) ![]UnresolvedGlyph {
    // The boundary/portable test targets link this module without the macOS CoreText object
    // file. Keep the product-only bridge unreachable there instead of leaving an undefined
    // native symbol merely because a detached-worker test imports its type.
    if (builtin.os.tag != .macos) return error.UnsupportedSystemText;
    const point_size = chrome.ui.typography.token(run.role).point_size;
    const scaled_size = @as(f64, @floatFromInt(point_size)) * @as(f64, @floatFromInt(scale_milli)) / 1000.0;
    var native: bridge.NativeChromeTextShapeResult = .{};
    const capacity = @max(@as(usize, 16), run.text.len * 2);
    var glyphs = try allocator.alloc(bridge.NativeChromeTextGlyphRecord, capacity);
    defer allocator.free(glyphs);
    bridge.maru_macos_coretext_shape_chrome_text(run.text.ptr, run.text.len, scaled_size, weight(run.role), @floatFromInt(run.max_width_px), &native, glyphs.ptr, glyphs.len);
    if (native.status != 0 or native.glyph_record_overflow != 0) return error.CoreTextChromeTextShapeFailed;
    const count = @min(@as(usize, native.glyph_record_count), glyphs.len);
    const out = try allocator.alloc(UnresolvedGlyph, count);
    for (glyphs[0..count], out) |native_glyph, *glyph| {
        glyph.* = .{
            .glyph_id = native_glyph.glyph_id,
            .codepoint = native_glyph.codepoint,
            .fallback = native_glyph.fallback != 0,
            .color_glyph_kind = if (native_glyph.color_glyph_kind != 0) .color else .monochrome,
            .x_px = native_glyph.x_px,
            .advance_px = native_glyph.advance_px,
            .font_name = native_glyph.font_name,
            .point_size = point_size,
            .line_height_px = @floatFromInt(chrome.ui.typography.lineHeightPx(run.role, scale_milli)),
            .origin = run.origin,
            .foreground = run.foreground,
        };
    }
    return out;
}

test "owned request shapes proportional text before renderer registry resolution" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 12, .y = 8 },
        .runs = &runs,
        .role = .surface_fg,
        .text_role = .dock_heading,
        .max_cols = 40,
    } }};
    const tokens = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 10, .g = 10, .b = 10 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 50, .g = 50, .b = 50 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 60, .g = 80, .b = 120 },
        .cursor = .{ .r = 255, .g = 255, .b = 255 },
        .accent = .{ .r = 20, .g = 120, .b = 255 },
    });
    var request = try prepareRequest(allocator, 44, &ops, &tokens, 16);
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 2000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
}
