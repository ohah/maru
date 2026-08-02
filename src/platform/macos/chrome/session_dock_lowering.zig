//! Session Dock 전용 macOS renderer adapter.
//!
//! `chrome.components.session_dock`는 semantic `ChromeDraw`와 rect tree까지만 소유한다.
//! 이 파일은 그 결과를 실제 앱의 CoreText `DrawList`와 Metal background quad로 한 방향
//! 투영한다. 따라서 archive/AppSession 좌표 계산이나 provider 문자열 조립은 여기로
//! 들어올 수 없으며, hit rect와 paint rect의 권위는 계속 component tree 하나다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const terminal = maru.terminal;
const metal_frame = renderer.metal_frame;

/// A completed dock frame's text ops become **one** CoreText DrawList. `view.zig` already owns
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
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);

    if (cell_width_px == 0 or cell_height_px == 0 or cols == 0 or rows == 0) return error.NoSpace;
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.origin.x < 0 or text.origin.y < 0) continue;
            const col: u16 = @intCast(@min(@as(u32, @intCast(text.origin.x)) / cell_width_px, cols));
            const row: u16 = @intCast(@min(@as(u32, @intCast(text.origin.y)) / cell_height_px, rows));
            if (col >= cols or row >= rows) continue;
            const style: terminal.Style = .{ .foreground = .{ .rgb = tk.get(text.role) } };
            for (text.runs) |run| {
                var plan = chrome.text_layout.plan(run.text, col, cols, .head, null);
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

/// Session Dock card는 terminal glyph보다 먼저 그리는 layer 2에 둔다. layer 0은 renderer의
/// draw order상 terminal text 뒤라 써서는 안 된다. 이 규칙을 adapter에 고정해 카드 배경이
/// CoreText 글자를 덮는 회귀를 막는다.
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

test "Session Dock lowering preserves an NFD cluster and paints cards behind text" {
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
