//! Modal paint and input consume the same workspace and panel padding.
//! The workspace comes from dock layout: inferring it from the backing size
//! would put settings over the native caption and the status bar.
const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;

pub fn props(width: u32, height: u32, cw: u32, ch: u32, sidebar: u32, workspace: maru.session.split_tree.Rect, tk: *const chrome.Tokens) chrome.props.ChromeProps {
    return .{
        .shape = .fromTokens(tk),
        .metrics = .{
            .cell_width_px = cw,
            .cell_height_px = ch,
            .sidebar_width_px = sidebar,
            .backing_width_px = width,
            .backing_height_px = height,
            // Zero is an authoritative collapsed workspace, not missing geometry.
            .workspace_present = true,
            .workspace_x_px = workspace.x,
            .workspace_y_px = workspace.y,
            .workspace_width_px = workspace.w,
            .workspace_height_px = workspace.h,
        },
    };
}

pub const Paint = struct {
    panel_done: bool = false,

    /// Expand just the modal panel before solid/gradient lowering. Text and
    /// controls keep their own coordinates; later rounded buttons are not panels.
    pub fn prepare(self: *Paint, operation: chrome.draw.Op, tk: *const chrome.Tokens) chrome.draw.Op {
        var painted = operation;
        if (!self.panel_done and painted == .quad) {
            self.panel_done = true;
            painted.quad.rect = painted.quad.visibleRect(tk.space.modal_padding_px);
        }
        return painted;
    }
};

fn tokens() chrome.Tokens {
    return chrome.Tokens.rich(std.mem.zeroes(chrome.tokens.ThemeColors));
}

fn panel() chrome.draw.Op {
    return .{ .quad = .{
        .rect = .{ .x = 100, .y = 80, .w = 240, .h = 160 },
        .fill_role = .surface_bg,
        .corner_radii = .{ 8, 8, 8, 8 },
    } };
}

test "Windows modal workspace preserves caption status bar and the whole dock" {
    const tk = tokens();
    const p = props(1000, 700, 9, 17, 300, .{ .x = 300, .y = 34, .w = 700, .h = 641 }, &tk);
    try std.testing.expectEqual(chrome.props.PaneRect{ .x = 300, .y = 34, .w = 700, .h = 641 }, chrome.props.workspaceRect(p.metrics));
    try std.testing.expectEqual(@as(u32, 700), p.metrics.backing_height_px);
    try std.testing.expectEqual(@as(u32, 9), p.metrics.cell_width_px);
    try std.testing.expectEqual(@as(u32, 17), p.metrics.cell_height_px);
    try std.testing.expectEqual(chrome.props.ShapeTokens.fromTokens(&tk), p.shape);
}

test "Windows modal collapsed workspace never falls back to the backing size" {
    const tk = tokens();
    const p = props(1000, 700, 9, 17, 300, .{ .x = 300, .y = 34, .w = 0, .h = 0 }, &tk);
    try std.testing.expectEqual(chrome.props.PaneRect{ .x = 300, .y = 34, .w = 0, .h = 0 }, chrome.props.workspaceRect(p.metrics));
    try std.testing.expect(chrome.components.modal_box.layout(20, 10, p, &tk) == null);
}

test "Windows modal layout and pointer use the declared workspace" {
    const tk = tokens();
    const p = props(1000, 700, 9, 17, 300, .{ .x = 300, .y = 34, .w = 700, .h = 641 }, &tk);
    const box = chrome.components.modal_box.layout(20, 10, p, &tk).?;
    const visible = chrome.components.modal_box.visibleRect(box, p);
    try std.testing.expect(visible.x >= 300 and visible.y >= 34);
    try std.testing.expect(visible.y + @as(i32, @intCast(visible.h)) <= 675);
    try std.testing.expect(!visible.containsPx(500, 16));
}

test "Windows modal paint includes the same padding as pointer geometry" {
    const tk = tokens();
    const original = panel();
    var paint: Paint = .{};
    const actual = paint.prepare(original, &tk);
    try std.testing.expectEqual(original.quad.visibleRect(tk.space.modal_padding_px), actual.quad.rect);
    try std.testing.expect(actual.quad.rect.containsPx(99, 79));
    try std.testing.expectEqual(original.quad.corner_radii, actual.quad.corner_radii);
}

test "Windows modal paint preserves gradient border alpha and clip" {
    const tk = tokens();
    var original = panel();
    original.quad.gradient = .vertical;
    original.quad.fill_role_end = .focus_accent;
    original.quad.alpha = 127;
    original.quad.border_widths = .{ 1, 2, 3, 4 };
    original.quad.clip = .{ .x = 90, .y = 70, .w = 120, .h = 100 };
    var paint: Paint = .{};
    const actual = paint.prepare(original, &tk);
    var expected = original;
    expected.quad.rect = original.quad.visibleRect(tk.space.modal_padding_px);
    try std.testing.expectEqualDeep(expected, actual);
}

test "Windows modal paint does not expand later rounded controls" {
    const tk = tokens();
    var paint: Paint = .{};
    _ = paint.prepare(panel(), &tk);
    const control = panel();
    try std.testing.expectEqualDeep(control, paint.prepare(control, &tk));
}

test "Windows modal paint ignores fills before the panel" {
    const tk = tokens();
    var paint: Paint = .{};
    const fill: chrome.draw.Op = .{ .fill = .{ .rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .role = .surface_bg } };
    try std.testing.expectEqualDeep(fill, paint.prepare(fill, &tk));
    try std.testing.expect(!paint.panel_done);
    const original = panel();
    try std.testing.expectEqual(original.quad.visibleRect(tk.space.modal_padding_px), paint.prepare(original, &tk).quad.rect);
}

test "Windows modal explicit zero padding and square panels remain unchanged" {
    const tk = tokens();
    var original = panel();
    original.quad.panel_padding_px = 0;
    var paint: Paint = .{};
    try std.testing.expectEqualDeep(original, paint.prepare(original, &tk));
    paint = .{};
    original = panel();
    original.quad.corner_radii = .{ 0, 0, 0, 0 };
    try std.testing.expectEqualDeep(original, paint.prepare(original, &tk));
}
