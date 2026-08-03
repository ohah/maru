//! Semantic Chrome draw의 macOS renderer adapter.
//!
//! 각 `chrome.components.*`는 semantic `ChromeDraw`와 rect tree까지만 소유한다. 이 파일은
//! 그 결과를 실제 앱의 CoreText `DrawList`와 Metal background quad로 한 방향 투영한다.
//! 따라서 archive/AppSession 좌표 계산이나 provider 문자열 조립은 여기로 들어올 수 없으며,
//! hit rect와 paint rect의 권위는 계속 component tree 하나다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const terminal = maru.terminal;
const metal_frame = renderer.metal_frame;

/// B1 rich Chrome text의 immutable placement artifact. semantic draw의 px origin을 cell
/// DrawList와 함께 보존해, CoreText가 atlas slot을 준비한 뒤에도 final glyph quad가 row/col로
/// 다시 절삭되지 않게 한다. Placement는 row 하나가 아니라 text op의 column span을 들고 있어,
/// 같은 행의 scope tab·side-by-side control이 서로의 fractional origin을 훔치지 않는다.
pub const RichTextArtifact = struct {
    pub const Placement = struct {
        row: u16,
        start_col: u16,
        end_col: u16,
        offset_x_px: f32,
        offset_y_px: f32,
        foreground: u32,
        text_role: chrome.ui.typography.ChromeTextRole,
    };

    placements: []Placement,

    pub fn deinit(self: *RichTextArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.placements);
        self.* = undefined;
    }

    /// Converts an already shaped/rasterized RenderFrame to final pixel glyph placements. The
    /// frame owns atlas slots; this artifact owns only component placement/color, keeping font
    /// work out of the render tick's final assembly phase.
    pub fn appendGpuGlyphs(
        self: RichTextArtifact,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas: renderer.GlyphAtlasConfig,
        cell_width_px: u32,
        cell_height_px: u32,
        origin_x_px: u32,
        origin_y_px: u32,
        out: *std.ArrayList(metal_frame.GpuGlyph),
    ) !void {
        if (cell_width_px == 0 or cell_height_px == 0) return;
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs) |glyph| {
            const placement = placementFor(self.placements, glyph.run.row, glyph.run.col) orelse continue;
            const uv = renderer.glyph_quads.uvRectForSlot(glyph.slot, texture) catch continue;
            try out.append(allocator, .{
                .x = @as(f32, @floatFromInt(origin_x_px)) + @as(f32, @floatFromInt(glyph.run.col)) * @as(f32, @floatFromInt(cell_width_px)) + placement.offset_x_px,
                .y = @as(f32, @floatFromInt(origin_y_px)) + @as(f32, @floatFromInt(glyph.run.row)) * @as(f32, @floatFromInt(cell_height_px)) + placement.offset_y_px,
                .w = @floatFromInt(glyph.slot.width_px),
                .h = @floatFromInt(cell_height_px),
                .atlas_x_px = glyph.slot.x_px,
                .atlas_y_px = glyph.slot.y_px,
                .atlas_width_px = glyph.slot.width_px,
                .atlas_height_px = glyph.slot.height_px,
                // NativeMetalCell reserves u+2 for a CoreText-selected color glyph. The
                // independent pixel pass uses the same fragment shader, so preserve that
                // renderer contract rather than recoloring emoji with the text foreground.
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

/// Captures the semantic pixel origin for each lowerable text row. The actual glyph shape/raster
/// still comes from the shared CoreText+atlas pipeline; this is deliberately placement-only.
pub fn buildRichTextArtifact(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !RichTextArtifact {
    if (cell_width_px == 0 or cell_height_px == 0 or cols == 0 or rows == 0) return error.NoSpace;
    var out: std.ArrayList(RichTextArtifact.Placement) = .empty;
    errdefer out.deinit(allocator);
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.origin.x < 0 or text.origin.y < 0) continue;
            const col_px: u32 = @intCast(text.origin.x);
            const row_px: u32 = @intCast(text.origin.y);
            const row: u16 = @intCast(@min(row_px / cell_height_px, rows));
            if (row >= rows or col_px / cell_width_px >= cols) continue;
            const start_col: u16 = @intCast(col_px / cell_width_px);
            for (text.runs) |run| {
                const end_limit = @min(cols, std.math.add(u16, start_col, text.max_cols) catch cols);
                var plan = chrome.text_layout.plan(run.text, start_col, end_limit, text.anchor, if (text.wide_icons) &wideChromeIconGlyph else null);
                while (plan.next()) |_| {}
                const end_col = plan.endCol();
                if (end_col <= start_col) continue;
                try out.append(allocator, .{
                    .row = row,
                    .start_col = start_col,
                    .end_col = end_col,
                    .offset_x_px = @floatFromInt(col_px % cell_width_px),
                    .offset_y_px = @floatFromInt(row_px % cell_height_px),
                    .foreground = packRgb(tk.get(text.role)),
                    .text_role = text.text_role,
                });
            }
        },
        else => {},
    };
    return .{ .placements = try out.toOwnedSlice(allocator) };
}

/// The final-pixel consumers must resolve placement through this one lookup.  In particular,
/// Chrome Lab uses it to prove its submitted GpuGlyph coordinates still equal the product
/// artifact rather than a fixture-local cell reconstruction.
pub fn placementFor(placements: []const RichTextArtifact.Placement, row: u16, col: u16) ?RichTextArtifact.Placement {
    // DrawList/shape order matches semantic draw order. Reverse lookup gives a later text op
    // precedence when a component deliberately overlays an earlier run in the same cell.
    var i = placements.len;
    while (i > 0) {
        i -= 1;
        const placement = placements[i];
        if (placement.row == row and col >= placement.start_col and col < placement.end_col) return placement;
    }
    return null;
}

/// Cache key for a placement-only artifact. Font rasterization remains owned by the existing
/// shared CoreText/atlas path; this key invalidates the immutable component placement whenever
/// text, semantic color, rect, icon width policy, or grid metrics change.
pub fn richTextFingerprint(
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) u64 {
    var state: u64 = 0xcbf29ce484222325;
    fingerprintMixValue(&state, cell_width_px);
    fingerprintMixValue(&state, cell_height_px);
    fingerprintMixValue(&state, cols);
    fingerprintMixValue(&state, rows);
    for (ops) |op| switch (op) {
        .text => |text| {
            // Registered SVG/PUA icons are emitted by buildIconTextDrawList, never by the
            // proportional system-text worker. Their spinner phase may change every frame, so
            // including them here would make every detached text result stale before polling.
            if (text.wide_icons) continue;
            fingerprintMixValue(&state, 0x54);
            fingerprintMixValue(&state, @as(u32, @bitCast(text.origin.x)));
            fingerprintMixValue(&state, @as(u32, @bitCast(text.origin.y)));
            fingerprintMixValue(&state, packRgb(tk.get(text.role)));
            fingerprintMixValue(&state, @intFromEnum(text.text_role));
            fingerprintMixValue(&state, @intFromBool(text.wide_icons));
            fingerprintMixValue(&state, text.max_width_px orelse 0);
            fingerprintMixTextPlacement(&state, text.placement);
            for (text.runs) |run| {
                fingerprintMixValue(&state, run.text.len);
                fingerprintMixValue(&state, @intFromBool(run.bold));
                for (run.text) |byte| fingerprintMixByte(&state, byte);
            }
        },
        else => fingerprintMixValue(&state, 0),
    };
    return state;
}

fn fingerprintMixTextPlacement(state: *u64, placement: chrome.draw.TextPlacement) void {
    switch (placement) {
        .origin => fingerprintMixValue(state, @as(u8, 0)),
        .center_in_rect => |rect| {
            fingerprintMixValue(state, @as(u8, 1));
            fingerprintMixValue(state, @as(u32, @bitCast(rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(rect.y)));
            fingerprintMixValue(state, rect.w);
            fingerprintMixValue(state, rect.h);
        },
        .icon_in_rect => |icon| {
            fingerprintMixValue(state, @as(u8, 2));
            fingerprintMixValue(state, @as(u32, @bitCast(icon.content_rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(icon.content_rect.y)));
            fingerprintMixValue(state, icon.content_rect.w);
            fingerprintMixValue(state, icon.content_rect.h);
            fingerprintMixValue(state, icon.icon_codepoint);
            fingerprintMixValue(state, icon.icon_extent_px);
        },
        .leading_icon_group => |group| {
            fingerprintMixValue(state, @as(u8, 3));
            fingerprintMixValue(state, @as(u32, @bitCast(group.content_rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(group.content_rect.y)));
            fingerprintMixValue(state, group.content_rect.w);
            fingerprintMixValue(state, group.content_rect.h);
            fingerprintMixValue(state, group.icon_codepoint);
            fingerprintMixValue(state, group.icon_extent_px);
            fingerprintMixValue(state, group.gap_px);
        },
    }
}

fn fingerprintMixValue(state: *u64, value: anytype) void {
    const v: u64 = @intCast(value);
    inline for ([_]u6{ 0, 8, 16, 24, 32, 40, 48, 56 }) |shift| {
        fingerprintMixByte(state, @truncate(v >> shift));
    }
}

fn fingerprintMixByte(state: *u64, byte: u8) void {
    state.* = (state.* ^ byte) *% 0x100000001b3;
}

/// A completed Chrome frame's text ops become **one** CoreText DrawList. `view.zig` already owns
/// clipping/ellipsis; this adapter only places its clusters at the same component-grid origin.
/// Batching prevents a card with three labels from causing three independent CoreText shaping
/// passes on every render tick.
pub fn buildTextDrawList(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !renderer.DrawList {
    return buildTextDrawListFiltered(allocator, ops, tk, cell_width_px, cell_height_px, cols, rows, null);
}

/// Measured system text owns ordinary labels; this companion list retains only registered
/// Chrome SVG glyphs for the existing synthesized icon path.  Keeping the filter here makes
/// the two paint paths share the same semantic op and avoids duplicate monospaced text.
pub fn buildIconTextDrawList(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !renderer.DrawList {
    return buildTextDrawListFiltered(allocator, ops, tk, cell_width_px, cell_height_px, cols, rows, true);
}

fn buildTextDrawListFiltered(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
    only_wide_icons: ?bool,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);

    if (cell_width_px == 0 or cell_height_px == 0 or cols == 0 or rows == 0) return error.NoSpace;
    for (ops) |op| switch (op) {
        .text => |text| {
            if (only_wide_icons) |expected| if (text.wide_icons != expected) continue;
            if (text.origin.x < 0 or text.origin.y < 0) continue;
            const col: u16 = @intCast(@min(@as(u32, @intCast(text.origin.x)) / cell_width_px, cols));
            const row: u16 = @intCast(@min(@as(u32, @intCast(text.origin.y)) / cell_height_px, rows));
            if (col >= cols or row >= rows) continue;
            const style: terminal.Style = .{ .foreground = .{ .rgb = tk.get(text.role) } };
            for (text.runs) |run| {
                const end_limit = @min(cols, std.math.add(u16, col, text.max_cols) catch cols);
                var plan = chrome.text_layout.plan(run.text, col, end_limit, text.anchor, if (text.wide_icons) &wideChromeIconGlyph else null);
                while (plan.next()) |item| switch (item) {
                    .ellipsis => |ellipsis_col| try cells.append(allocator, .{ .row = row, .col = ellipsis_col, .codepoint = chrome.text_layout.ellipsis_glyph, .width = 1, .style = style }),
                    .cluster => |cluster| try appendCluster(allocator, &cells, &pool, run.text, cluster, row, style),
                };
            }
        },
        else => {},
    };
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = rows },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = rows - 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// The semantic draw explicitly opts in only component-owned SVG glyphs. Keeping this predicate
/// in the platform lowerer preserves the Chrome→renderer boundary while making measurement and
/// DrawCell width agree with the component's text plan.
fn wideChromeIconGlyph(codepoint: u21) bool {
    return renderer.icon_glyph.isRegisteredIcon(codepoint);
}

/// Chrome card는 terminal glyph보다 먼저 그리는 layer 2에 둔다. layer 0은 renderer의 draw
/// order상 terminal text 뒤라 써서는 안 된다. 이 규칙을 adapter에 고정해 카드 배경이 CoreText
/// 글자를 덮는 회귀를 막는다.
pub fn appendBackgroundQuads(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tk: *const chrome.Tokens,
    origin_x_px: u32,
    origin_y_px: u32,
    out: *std.ArrayList(metal_frame.GpuQuad),
) void {
    for (draws) |draws_for_layer| for (draws_for_layer.ops) |op| switch (op) {
        .quad => |quad| {
            // `ChromeDraw.Quad.alpha` is semantic paint data, not a Lab-only decoration.
            // Preserve it in the renderer's ARGB colors so loading skeletons and later hover
            // transitions keep the same token-relative contrast on the actual Metal host.
            const fill = packRgba(tk.get(quad.fill_role), quad.alpha);
            const border = if (quad.border_role) |role| packRgba(tk.get(role), quad.alpha) else 0;
            out.append(allocator, .{
                // Component draw coordinates are local to the dock content. Text receives the
                // same offset through its PaneFrame destination; quads need it explicitly
                // because GpuQuad is already in renderer backing coordinates.
                .x = @as(f32, @floatFromInt(quad.rect.x)) + @as(f32, @floatFromInt(origin_x_px)),
                .y = @as(f32, @floatFromInt(quad.rect.y)) + @as(f32, @floatFromInt(origin_y_px)),
                .w = @floatFromInt(quad.rect.w),
                .h = @floatFromInt(quad.rect.h),
                .corner_radii = .{
                    @floatFromInt(quad.corner_radii[0]),
                    @floatFromInt(quad.corner_radii[1]),
                    @floatFromInt(quad.corner_radii[2]),
                    @floatFromInt(quad.corner_radii[3]),
                },
                .border_widths = .{
                    @floatFromInt(quad.border_widths[0]),
                    @floatFromInt(quad.border_widths[1]),
                    @floatFromInt(quad.border_widths[2]),
                    @floatFromInt(quad.border_widths[3]),
                },
                .fill_color0 = fill,
                .fill_color1 = fill,
                .border_color = border,
                .gradient_kind = 0,
                .layer = 2,
            }) catch {};
        },
        else => {},
    };
}

fn appendCluster(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32),
    source: []const u8,
    cluster: chrome.text_layout.Cluster,
    row: u16,
    style: terminal.Style,
) !void {
    const base = chrome.text_layout.decodeCodepoint(source, cluster.start);
    const offset: u32 = @intCast(pool.items.len);
    var index = cluster.start + base.advance;
    const max_extra = @as(usize, std.math.maxInt(u16));
    while (index < cluster.end and index < source.len and pool.items.len - offset < max_extra) {
        const extra = chrome.text_layout.decodeCodepoint(source, index);
        try pool.append(allocator, @as(u32, extra.cp));
        index += extra.advance;
    }
    try cells.append(allocator, .{
        .row = row,
        .col = cluster.col,
        .codepoint = base.cp,
        .grapheme_offset = offset,
        .grapheme_count = @intCast(pool.items.len - offset),
        .width = @intCast(@min(cluster.cols, 2)),
        .style = style,
    });
}

fn packRgba(rgb: maru.color.Rgb, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

test "Chrome draw lowering preserves an NFD cluster and paints cards behind text" {
    const tk = chrome.tokens.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const ops_text = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 2, .y = 3 }, .runs = &.{.{ .text = "e\u{301}" }}, .role = .surface_fg } }};
    var text = try buildTextDrawList(std.testing.allocator, &ops_text, &tk, 1, 1, 20, 10);
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), text.cells.len);
    try std.testing.expectEqual(@as(usize, 1), text.grapheme_pool.len);
    try std.testing.expectEqual(@as(u16, 2), text.cells[0].col);
    try std.testing.expectEqual(@as(u16, 3), text.cells[0].row);
    var quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer quads.deinit(std.testing.allocator);
    const ops = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .fill_role = .surface_bg, .alpha = 0x7f } }};
    appendBackgroundQuads(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 11, 13, &quads);
    try std.testing.expectEqual(@as(usize, 1), quads.items.len);
    try std.testing.expectEqual(@as(u32, 2), quads.items[0].layer);
    try std.testing.expectEqual(@as(f32, 11), quads.items[0].x);
    try std.testing.expectEqual(@as(f32, 13), quads.items[0].y);
    try std.testing.expectEqual(@as(u32, 0x7f040506), quads.items[0].fill_color0);
}

test "Chrome draw lowering widens only explicitly owned registered SVG icons" {
    const tk = chrome.tokens.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = "\u{F000C}" }};
    const wide_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .wide_icons = true } }};
    var wide = try buildTextDrawList(std.testing.allocator, &wide_ops, &tk, 8, 16, 4, 1);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), wide.cells.len);
    try std.testing.expectEqual(@as(u2, 2), wide.cells[0].width);

    const plain_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg } }};
    var plain = try buildTextDrawList(std.testing.allocator, &plain_ops, &tk, 8, 16, 4, 1);
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plain.cells.len);
    try std.testing.expectEqual(@as(u2, 1), plain.cells[0].width);
}

test "icon-only lowering excludes ordinary Session Dock text" {
    const tk = chrome.tokens.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &.{.{ .text = "ordinary" }}, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 8, .y = 0 }, .runs = &.{.{ .text = "\u{F000C}" }}, .role = .surface_fg, .wide_icons = true } },
    };
    var list = try buildIconTextDrawList(std.testing.allocator, &ops, &tk, 8, 16, 20, 1);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), list.cells.len);
    try std.testing.expectEqual(@as(u21, 0xF000C), list.cells[0].codepoint);
}

test "rich text artifact preserves fractional pixel origin instead of coercing it to a cell row" {
    const tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = "가" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 19, .y = 33 }, .runs = &runs, .role = .accent_bar } }};
    var artifact = try buildRichTextArtifact(std.testing.allocator, &ops, &tk, 8, 16, 20, 10);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), artifact.placements.len);
    try std.testing.expectEqual(@as(u16, 2), artifact.placements[0].row);
    try std.testing.expectEqual(@as(u16, 2), artifact.placements[0].start_col);
    try std.testing.expectEqual(@as(u16, 4), artifact.placements[0].end_col);
    try std.testing.expectEqual(@as(f32, 3), artifact.placements[0].offset_x_px);
    try std.testing.expectEqual(@as(f32, 1), artifact.placements[0].offset_y_px);
    try std.testing.expectEqual(@as(u32, 0x00191A1B), artifact.placements[0].foreground);
}

test "rich text artifact keeps side-by-side origins independent on one cell row" {
    const tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const left_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const right_runs = [_]chrome.draw.Run{.{ .text = "B" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 1, .y = 17 }, .runs = &left_runs, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 18, .y = 19 }, .runs = &right_runs, .role = .accent_bar } },
    };
    var artifact = try buildRichTextArtifact(std.testing.allocator, &ops, &tk, 8, 16, 20, 10);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), artifact.placements.len);
    try std.testing.expectEqual(@as(f32, 1), placementFor(artifact.placements, 1, 0).?.offset_x_px);
    try std.testing.expectEqual(@as(f32, 2), placementFor(artifact.placements, 1, 2).?.offset_x_px);
    try std.testing.expectEqual(@as(f32, 3), placementFor(artifact.placements, 1, 2).?.offset_y_px);
}

test "rich text fingerprint changes for placement semantic color and typography inputs" {
    var tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = "가A" }};
    var ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 5, .y = 7 }, .runs = &runs, .role = .accent_bar } }};
    const base = richTextFingerprint(&ops, &tk, 8, 16, 20, 10);
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 9, 16, 20, 10));
    tk.palette.set(.accent_bar, .{ .r = 99, .g = 26, .b = 27 });
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 8, 16, 20, 10));
    tk.palette.set(.accent_bar, .{ .r = 25, .g = 26, .b = 27 });
    ops[0].text.text_role = .card_heading;
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 8, 16, 20, 10));
}

test "rich text fingerprint ignores animated wide icon-only ops" {
    const tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const text_runs = [_]chrome.draw.Run{.{ .text = "Stable label" }};
    const spinner_a = [_]chrome.draw.Run{.{ .text = "\u{f0002}" }};
    const spinner_b = [_]chrome.draw.Run{.{ .text = "\u{f0003}" }};
    const baseline = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 5, .y = 7 }, .runs = &text_runs, .role = .accent_bar } },
        .{ .text = .{ .origin = .{ .x = 30, .y = 7 }, .runs = &spinner_a, .role = .accent_bar, .wide_icons = true } },
    };
    const next = [_]chrome.draw.Op{
        baseline[0],
        .{ .text = .{ .origin = .{ .x = 30, .y = 7 }, .runs = &spinner_b, .role = .accent_bar, .wide_icons = true } },
    };
    try std.testing.expectEqual(richTextFingerprint(&baseline, &tk, 8, 16, 20, 10), richTextFingerprint(&next, &tk, 8, 16, 20, 10));
}
