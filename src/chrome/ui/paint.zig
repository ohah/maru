//! Fixed-buffer draw emission for the new rich/Metal UiNode tree.
//!
//! Layout owns every floating-point rect, ui_interaction owns pointer-local state, and
//! `paint_style` resolves semantic variants through tokens. This file only snaps the resulting
//! rect once and emits backend-neutral ChromeDraw. Metal lowering, text shaping, clip scissor,
//! and GPU shadow emission remain the ML3b boundary.

const std = @import("std");
const draw = @import("../draw.zig");
const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
const paint_style = @import("paint_style.zig");
const tokens = @import("../tokens.zig");
const ui_tree = @import("tree.zig");

pub const PaintError = error{
    InsufficientBuffer,
    InvalidSnapshot,
    InvalidRect,
};

/// Caller-owned fixed frame storage. Paint never allocates or retains an old frame's ops: a
/// failed candidate is cleared so a host cannot publish a partly restyled tree.
pub const PaintBuffers = struct {
    ops: []draw.Op,
};

pub const ResolvedShadow = paint_style.ResolvedShadow;
pub const ResolvedCardStyle = paint_style.ResolvedCardStyle;
pub const ResolvedTextStyle = paint_style.ResolvedTextStyle;
pub const resolveCard = paint_style.resolveCard;
pub const resolveButton = paint_style.resolveButton;
pub const resolveText = paint_style.resolveText;

/// Emits one Quad per semantic Card/Button in preorder. Text is intentionally not emitted until
/// the actual CoreText layout artifact is wired; callers can still resolve its typed visual style
/// via `resolveText`. The result is safe to snapshot in a unit test but is not a production frame.
pub fn paint(
    tree: ui_tree.UiRectTree,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    layer: draw.Layer,
    buffers: PaintBuffers,
) PaintError!draw.ChromeDraw {
    clearOps(buffers.ops);
    var count: usize = 0;
    errdefer clearOps(buffers.ops);

    for (tree.entries) |entry| {
        switch (entry.visual) {
            .none => if (entry.kind != .container) return error.InvalidSnapshot,
            .card => |visual| {
                if (entry.kind != .card) return error.InvalidSnapshot;
                const clipped = if (entry.effective_clip) |clip| intersect(entry.rect, clip) else entry.rect;
                const rect = try snapRect(clipped);
                if (rect.w == 0 or rect.h == 0) continue;
                if (count == buffers.ops.len) return error.InsufficientBuffer;
                const style = paint_style.resolveCard(entry.id, visual, entry.action, state, tk);
                buffers.ops[count] = .{ .quad = .{
                    .rect = rect,
                    .fill_role = style.background,
                    .corner_radii = style.corner_radii_px,
                    .border_widths = style.border_widths_px,
                    .border_role = style.border,
                    .alpha = style.opacity,
                } };
                count += 1;
            },
            .button => |visual| {
                if (entry.kind != .button) return error.InvalidSnapshot;
                const clipped = if (entry.effective_clip) |clip| intersect(entry.rect, clip) else entry.rect;
                const rect = try snapRect(clipped);
                if (rect.w == 0 or rect.h == 0) continue;
                if (count == buffers.ops.len) return error.InsufficientBuffer;
                const style = paint_style.resolveButton(entry.id, visual, entry.action, state, tk);
                buffers.ops[count] = .{ .quad = .{
                    .rect = rect,
                    .fill_role = style.background,
                    .corner_radii = style.corner_radii_px,
                    .border_widths = style.border_widths_px,
                    .border_role = style.border,
                    .alpha = style.opacity,
                } };
                count += 1;
            },
            .text => |visual| {
                if (entry.kind != .text) return error.InvalidSnapshot;
                _ = paint_style.resolveText(visual);
            },
        }
    }
    return .{ .layer = layer, .ops = buffers.ops[0..count] };
}

fn intersect(a: layout.UiRect, b: layout.UiRect) layout.UiRect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = @max(right - left, 0), .height = @max(bottom - top, 0) };
}

/// Layout may produce fractional rects for percent/fill. Painting snaps once at the last neutral
/// boundary: floor the origin and ceil the far edge, so adjacent rects cannot reveal a gap.
fn snapRect(rect: layout.UiRect) PaintError!draw.Rect {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height) or
        rect.width < 0 or rect.height < 0) return error.InvalidRect;
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    if (!std.math.isFinite(right) or !std.math.isFinite(bottom)) return error.InvalidRect;

    const left_px = @floor(rect.x);
    const top_px = @floor(rect.y);
    const right_px = @ceil(right);
    const bottom_px = @ceil(bottom);
    const min_i32: f32 = @floatFromInt(std.math.minInt(i32));
    const max_i32: f32 = @floatFromInt(std.math.maxInt(i32));
    const max_u32: f32 = @floatFromInt(std.math.maxInt(u32));
    if (left_px < min_i32 or top_px < min_i32 or right_px > max_i32 or bottom_px > max_i32 or
        right_px < left_px or bottom_px < top_px or right_px - left_px > max_u32 or bottom_px - top_px > max_u32) return error.InvalidRect;

    return .{
        .x = @intFromFloat(left_px),
        .y = @intFromFloat(top_px),
        .w = @intFromFloat(right_px - left_px),
        .h = @intFromFloat(bottom_px - top_px),
    };
}

fn clearOps(ops: []draw.Op) void {
    for (ops) |*op| op.* = emptyOp();
}

fn emptyOp() draw.Op {
    return .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .role = .surface_bg } };
}

fn testTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
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
}

fn cardEntry(id: ui_tree.UiId, rect: layout.UiRect, visual: ui_tree.CardVisual, action: ?ui_tree.UiAction) ui_tree.RectEntry {
    return .{ .id = id, .parent_index = null, .kind = .card, .rect = rect, .effective_clip = null, .action = action, .visual = .{ .card = visual } };
}

test "resolveCard gives disabled precedence and preserves rich token shadow ownership" {
    const tk = testTokens();
    const visual: ui_tree.CardVisual = .{ .variant = .raised, .paint = .{ .background = .accent_bar, .border = .accent_bar } };
    const active = resolveCard(7, visual, .{ .id = 9 }, .{ .hovered = 7, .focused = 7, .capture = .{ .id = 7, .action_id = 9 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, active.background);
    try std.testing.expectEqual(@as(?tokens.ColorRole, .focus_accent), active.border);
    try std.testing.expect(active.shadow != null);
    try std.testing.expectEqual(tk.space.shadow_blur_px, active.shadow.?.blur_px);

    const disabled = resolveCard(7, visual, .{ .id = 9, .enabled = false }, .{ .hovered = 7, .focused = 7, .capture = .{ .id = 7, .action_id = 9 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.surface_bg, disabled.background);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, disabled.foreground);
    try std.testing.expectEqual(@as(?tokens.ColorRole, .divider), disabled.border);
    try std.testing.expectEqual(@as(u8, 0x80), disabled.opacity);
    try std.testing.expectEqual(@as(?ResolvedShadow, null), disabled.shadow);
}

test "every semantic card variant starts fully opaque" {
    const tk = testTokens();
    inline for ([_]ui_tree.CardVariant{ .surface, .raised, .selected, .danger }) |variant| {
        const resolved = resolveCard(1, .{ .variant = variant, .paint = .{} }, null, .{}, &tk);
        try std.testing.expectEqual(@as(u8, 0xFF), resolved.opacity);
    }
}

test "Button primary and secondary keep command contrast independent of Card variants" {
    const tk = testTokens();
    const primary = resolveButton(5, .{ .variant = .primary, .paint = .{} }, .{ .id = 9 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, primary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_bg, primary.foreground);
    const secondary = resolveButton(6, .{ .variant = .secondary, .paint = .{} }, .{ .id = 10 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, secondary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, secondary.foreground);
    const hovered_primary = resolveButton(5, .{ .variant = .primary, .paint = .{} }, .{ .id = 9 }, .{ .hovered = 5 }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.row_hover_bg, hovered_primary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, hovered_primary.foreground);
    const disabled = resolveButton(7, .{ .variant = .primary, .paint = .{} }, .{ .id = 11, .enabled = false }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, disabled.foreground);
    try std.testing.expectEqual(@as(u8, 0x80), disabled.opacity);
}

test "paint emits preordered snapped card quads and ignores text until shaping exists" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{
        cardEntry(1, .{ .x = 0.2, .y = 1.2, .width = 10.1, .height = 4.1 }, .{ .variant = .surface, .paint = .{} }, .{ .id = 10 }),
        .{ .id = 2, .parent_index = 0, .kind = .text, .rect = .{ .x = 1, .y = 2, .width = 2, .height = 1 }, .effective_clip = null, .action = null, .visual = .{ .text = .{ .tone = .muted, .paint = .{} } } },
        cardEntry(3, .{ .x = 10.3, .y = 1.2, .width = 2.1, .height = 4.1 }, .{ .variant = .selected, .paint = .{} }, .{ .id = 30 }),
    };
    var ops: [2]draw.Op = undefined;
    const out = try paint(.{ .entries = &entries }, .{ .hovered = 1 }, &tk, .sidebar, .{ .ops = &ops });
    try std.testing.expectEqual(draw.Layer.sidebar, out.layer);
    try std.testing.expectEqual(@as(usize, 2), out.ops.len);
    try std.testing.expect(out.ops[0] == .quad);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 1, .w = 11, .h = 5 }, out.ops[0].quad.rect);
    try std.testing.expectEqual(tokens.ColorRole.row_hover_bg, out.ops[0].quad.fill_role);
    try std.testing.expect(out.ops[1] == .quad);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, out.ops[1].quad.fill_role);
}

test "paint intersects a card with its completed tree clip" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{.{
        .id = 1,
        .parent_index = null,
        .kind = .card,
        .rect = .{ .x = 0, .y = -8, .width = 20, .height = 20 },
        .effective_clip = .{ .x = 0, .y = 0, .width = 20, .height = 12 },
        .action = .{ .id = 1 },
        .visual = .{ .card = .{ .variant = .surface, .paint = .{} } },
    }};
    var ops: [1]draw.Op = undefined;
    const out = try paint(.{ .entries = &entries }, .{}, &tk, .sidebar, .{ .ops = &ops });
    try std.testing.expectEqual(@as(usize, 1), out.ops.len);
    try std.testing.expectEqual(@as(i32, 0), out.ops[0].quad.rect.y);
    try std.testing.expectEqual(@as(u32, 12), out.ops[0].quad.rect.h);
}

test "paint fails closed for bad snapshots and fixed-capacity overflow" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{
        cardEntry(1, .{ .x = 0, .y = 0, .width = 5, .height = 5 }, .{ .variant = .surface, .paint = .{} }, null),
        cardEntry(2, .{ .x = 5, .y = 0, .width = 5, .height = 5 }, .{ .variant = .surface, .paint = .{} }, null),
    };
    var one_op: [1]draw.Op = undefined;
    try std.testing.expectError(error.InsufficientBuffer, paint(.{ .entries = &entries }, .{}, &tk, .sidebar, .{ .ops = &one_op }));
    try std.testing.expectEqual(emptyOp(), one_op[0]);

    const malformed = [_]ui_tree.RectEntry{.{ .id = 3, .parent_index = null, .kind = .text, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .effective_clip = null, .action = null, .visual = .{ .card = .{ .variant = .surface, .paint = .{} } } }};
    try std.testing.expectError(error.InvalidSnapshot, paint(.{ .entries = &malformed }, .{}, &tk, .sidebar, .{ .ops = &one_op }));

    const invalid_rect = [_]ui_tree.RectEntry{cardEntry(4, .{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 }, .{ .variant = .surface, .paint = .{} }, null)};
    try std.testing.expectError(error.InvalidRect, paint(.{ .entries = &invalid_rect }, .{}, &tk, .sidebar, .{ .ops = &one_op }));
}
