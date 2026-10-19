const std = @import("std");
const draw = @import("../../draw.zig");
const props = @import("../../props.zig");
const tokens = @import("../../tokens.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const interaction = @import("../../ui/interaction.zig");
const paint = @import("../../ui/paint.zig");
const spacing = @import("../../ui/spacing.zig");
const typography = @import("../../ui/typography.zig");
const i18n = @import("../../../i18n.zig");
const fields = @import("fields.zig");
pub const Tab = enum { overview, path, terminal, events };
pub const Hit = union(enum) {
    tab: Tab,
    tool: usize,
    privacy,
    placement: usize,
    pub fn nodeId(self: Hit) u64 {
        return switch (self) {
            .tab => |t| 20 + @as(u64, @intCast(@backingInt(t))),
            .tool => |i| 10 + i,
            .privacy => 7,
            .placement => |i| 40 + i,
        };
    }
};
const Label = struct { id: u64, text: []const u8, accent: bool = false, muted: bool = false };
const Frame = struct { rects: tree.UiRectTree, labels: []const Label, row: u32 };

// DevTools-inspired bands share one immutable pixel tree for paint and input.
fn build(a: std.mem.Allocator, p: props.ChromeProps, scale: u32, labels: []const Label, body_count: usize) !Frame {
    const w = props.workspaceRect(p.metrics);
    const inset = spacing.px(.md, scale);
    const gap = spacing.px(.xs, scale);
    const compact = w.w >= spacing.pointsPx(640, scale);
    const row = spacing.pointsPx(if (compact) 24 else 32, scale);
    const width = w.w;
    const height = w.h;
    const n = 100 + body_count * 3;
    const nodes = try a.alloc(tree.UiNode, n);
    const main = nodes[0..6];
    const tools = nodes[6..14];
    const tabs = nodes[14..18];
    const header = nodes[18..25];
    const footer = nodes[25..29];
    const columns = nodes[29..31];
    const rows = nodes[31..][0..body_count];
    const cells = nodes[31 + body_count ..][0 .. body_count * 2];
    for (tools, 0..) |*node, i| node.* = tree.button(.{ .id = 10 + i, .action = .{ .id = 1 + i }, .variant = .ghost, .paint = .{ .corner_radii_px = .{ 4, 4, 4, 4 }, .border_widths_px = .{ 0, 0, 0, 0 } }, .style = .{ .width = .{ .px = @floatFromInt(spacing.pointsPx(if (i == 2 or i == 3) 96 else if (i == 5) 112 else 56, scale)) }, .height = .{ .percent = 1 }, .flex = .{ .shrink = 0 } }, .semantics = .{ .role = .button, .label = if (i == 0) i18n.t(.inspector_previous) else if (i == 1) i18n.t(.inspector_next) else if (i == 4) i18n.t(.inspector_refresh) else if (i == 7) i18n.t(.inspector_close) else labels[1 + i].text } });
    header[0] = tree.container(.{ .id = 3, .style = .{ .height = .{ .px = @floatFromInt(row) }, .flex = .{ .shrink = 0 } } }, &.{});
    for (0..5) |i| header[i + 1] = tools[i];
    header[6] = tools[7];
    const tool_widths = [_]f32{ 0.10, 0.10, 0.26, 0.22, 0.16, 0.16 };
    for (header[1..], tool_widths) |*node, fraction| node.style.width = .{ .percent = fraction };
    nodes[n - 2] = tree.container(.{ .id = 29, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(row) } } }, header[1..]);
    const bands = try a.alloc(tree.UiNode, 2);
    bands[0] = header[0];
    bands[1] = nodes[n - 2];
    if (compact) {
        bands[0].style.height = .{ .percent = 1 };
        bands[0].style.flex.grow = 1;
        bands[1].style.width = .{ .percent = 0.65 };
        bands[1].style.height = .{ .percent = 1 };
    }
    main[0] = tree.container(.{ .id = 4, .direction = if (compact) .row else .column, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 32 else 64, scale)) }, .padding = .{ .left = @floatFromInt(inset), .right = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } } }, bands);
    const placement_nodes = try a.alloc(tree.UiNode, 5);
    for (placement_nodes, 0..) |*node, i| node.* = tree.button(.{ .id = 40 + i, .action = .{ .id = 14 + i }, .variant = .ghost, .style = .{ .width = .{ .percent = 0.2 }, .height = .{ .percent = 1 } }, .semantics = .{ .role = .button, .label = placementLabel(i), .selected = labels[18 + i].accent } });
    const header_bands = try a.alloc(tree.UiNode, 2);
    header_bands[0] = main[0];
    header_bands[1] = tree.container(.{ .id = 46, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(28, scale)) }, .flex = .{ .shrink = 0 } } }, placement_nodes);
    main[0] = tree.container(.{ .id = 45, .direction = .column, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 60 else 92, scale)) }, .flex = .{ .shrink = 0 } } }, header_bands);
    for (tabs, 0..) |*node, i| node.* = tree.button(.{ .id = 20 + i, .action = .{ .id = 9 + i }, .variant = .ghost, .paint = .{ .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 } }, .style = .{ .width = .{ .percent = 0.25 }, .height = .{ .percent = 1 } }, .semantics = .{ .role = .tab, .label = labels[9 + i].text, .selected = labels[9 + i].accent } });
    main[1] = tree.container(.{ .id = 5, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 28 else 32, scale)) }, .padding = .{ .left = @floatFromInt(gap), .right = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } } }, tabs);
    main[2] = tree.card(.{ .id = 6, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 28 else 32, scale)) }, .margin = .{ .left = @floatFromInt(inset), .right = @floatFromInt(inset), .top = @floatFromInt(gap), .bottom = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } }, .paint = .{ .background = .inset_bg, .corner_radii_px = .{ 4, 4, 4, 4 }, .shadow = .none, .border_widths_px = .{ 1, 1, 1, 1 }, .border = .divider } }, &.{});
    for (columns, 0..) |*node, i| node.* = tree.container(.{ .id = 26 + i, .style = .{ .width = .{ .percent = if (i == 0) 0.36 else 0.64 }, .height = .{ .percent = 1 } } }, &.{});
    main[3] = tree.card(.{ .id = 8, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(row) }, .flex = .{ .shrink = 0 } }, .paint = .{ .background = .inset_bg, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 }, .shadow = .none } }, columns);
    for (rows, 0..) |*node, i| {
        const pair = cells[i * 2 ..][0..2];
        for (pair, 0..) |*cell, col| cell.* = tree.container(.{ .id = 101 + i * 3 + col, .style = .{ .width = .{ .percent = if (col == 0) 0.36 else 0.64 }, .height = .{ .percent = 1 } } }, &.{});
        node.* = tree.container(.{ .id = 100 + i * 3, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(row) }, .flex = .{ .shrink = 0 } } }, pair);
    }
    main[4] = tree.container(.{ .id = 10000, .style = .{ .height = .{ .fill = 1 } }, .overflow = .clip }, rows);
    footer[0] = tree.container(.{ .id = 28, .style = .{ .height = .{ .percent = 1 }, .flex = .{ .grow = 1 } } }, &.{});
    footer[1] = tree.button(.{ .id = 7, .action = .{ .id = 13 }, .variant = .ghost, .style = .{ .width = .{ .px = @floatFromInt(spacing.pointsPx(144, scale)) }, .height = .{ .percent = 1 }, .flex = .{ .shrink = 0 } } });
    footer[2] = tools[5];
    footer[3] = tools[6];
    main[5] = tree.container(.{ .id = 9, .direction = .row, .align_items = .center, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 32 else 40, scale)) }, .padding = .{ .left = @floatFromInt(inset), .right = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } } }, footer);
    footer[0].style.width = .{ .px = 0 };
    footer[0].style.flex.grow = 0;
    footer[1].style.width = .{ .percent = 0.44 };
    footer[2].style.width = .{ .percent = 0.34 };
    footer[3].style.width = .{ .percent = 0.22 };
    nodes[n - 1] = tree.card(.{ .id = 2, .style = .{ .width = .{ .px = @floatFromInt(width) }, .height = .{ .px = @floatFromInt(height) } }, .paint = .{ .background = .surface_bg, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 1, 1, 1, 1 }, .border = .divider }, .variant = .surface, .overflow = .clip }, main);
    const root = tree.container(.{ .id = 1, .justify = .center, .align_items = .center, .style = .{ .padding = .{ .left = @floatFromInt(w.x), .top = @floatFromInt(w.y), .right = @floatFromInt(p.metrics.backing_width_px -| w.x -| w.w), .bottom = @floatFromInt(p.metrics.backing_height_px -| w.y -| w.h) } } }, nodes[n - 1 .. n]);
    const built = try tree.build(root, .{ .root_size = .{ .width = @floatFromInt(p.metrics.backing_width_px), .height = @floatFromInt(p.metrics.backing_height_px) }, .max_entries = n, .max_depth = 6 }, .{ .entries = try a.alloc(tree.RectEntry, n), .items = try a.alloc(layout.Item, n), .flex_scratch = try a.alloc(layout.FlexScratch, n), .child_rects = try a.alloc(layout.UiRect, n) });
    return .{ .rects = built, .labels = labels, .row = row };
}

fn labelsFor(a: std.mem.Allocator, tab: Tab, paused: bool, pinned: bool, anonymize: bool, query: []const u8, status: []const u8) ![]Label {
    const labels = try a.alloc(Label, 23);
    labels[0] = .{ .id = 3, .text = if (status.len > 0) try std.fmt.allocPrint(a, "{s} · {s}", .{ i18n.t(.inspector_title), status }) else i18n.t(.inspector_title) };
    const tools = [_][]const u8{ "‹", "›", if (pinned) i18n.t(.inspector_pinned) else i18n.t(.inspector_follow), if (paused) i18n.t(.inspector_paused) else i18n.t(.inspector_live), "↻", i18n.t(.inspector_copy), i18n.t(.inspector_save), "×" };
    for (tools, 0..) |text, i| labels[i + 1] = .{ .id = 10 + i, .text = text };
    const tabs = [_][]const u8{ i18n.t(.inspector_overview), i18n.t(.inspector_path), i18n.t(.inspector_terminal), i18n.t(.inspector_events) };
    for (tabs, 0..) |text, i| labels[i + 9] = .{ .id = 20 + i, .text = text, .accent = i == @backingInt(tab) };
    labels[13] = .{ .id = 6, .text = if (query.len == 0) i18n.t(.inspector_filter) else query, .muted = query.len == 0 };
    labels[14] = .{ .id = 7, .text = if (anonymize) i18n.t(.inspector_export_anonymized) else i18n.t(.inspector_export_raw), .accent = true };
    labels[15] = .{ .id = 28, .text = if (status.len > 0) status else i18n.t(.inspector_help), .muted = true };
    labels[16] = .{ .id = 26, .text = i18n.t(.inspector_property), .muted = true };
    labels[17] = .{ .id = 27, .text = i18n.t(.inspector_value), .muted = true };
    const placements = [_][]const u8{ "↑", "→", "↓", "←", "↗" };
    for (placements, 0..) |text, i| labels[18 + i] = .{ .id = 40 + i, .text = text };
    return labels;
}
// Visual arrows are icons; assistive labels describe the action in the UI language.
fn placementLabel(index: usize) []const u8 {
    return switch (index) {
        0 => i18n.t(.inspector_dock_top),
        1 => i18n.t(.inspector_dock_right),
        2 => i18n.t(.inspector_dock_bottom),
        3 => i18n.t(.inspector_dock_left),
        else => i18n.t(.inspector_detach),
    };
}
pub const Cursor = enum { arrow, text, hand };
// Share the filter's exact paint geometry with attached and detached hover handling.
pub fn cursor(p: props.ChromeProps, scale: u32, a: std.mem.Allocator, x: f64, y: f64) Cursor {
    if (caretRect(p, scale, a)) |r| {
        if (x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and x < @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) and y < @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h))) return .text;
    }
    return if (hit(p, scale, a, x, y) != null) .hand else .arrow;
}
pub fn hit(p: props.ChromeProps, scale: u32, a: std.mem.Allocator, x: f64, y: f64) ?Hit {
    const labels = labelsFor(a, .overview, false, false, true, "", "") catch return null;
    const f = build(a, p, scale, labels, 0) catch return null;
    const h = interaction.hitAction(f.rects, x, y) orelse return null;
    if (h.action_id <= 8) return .{ .tool = @intCast(h.action_id - 1) };
    if (h.action_id <= 12) return .{ .tab = @fromBackingInt(@as(u2, @intCast(h.action_id - 9))) };
    if (h.action_id == 13) return .privacy;
    return .{ .placement = @intCast(h.action_id - 14) };
}
pub fn controlRect(p: props.ChromeProps, scale: u32, a: std.mem.Allocator, id: u64) ?draw.Rect {
    const labels = labelsFor(a, .overview, false, false, true, "", "") catch return null;
    const f = build(a, p, scale, labels, 0) catch return null;
    return rectOf(f.rects.entries[f.rects.find(id) orelse return null].rect);
}
pub fn caretRect(p: props.ChromeProps, scale: u32, a: std.mem.Allocator) ?draw.Rect {
    const labels = labelsFor(a, .overview, false, false, true, "", "") catch return null;
    const f = build(a, p, scale, labels, 0) catch return null;
    const entry = f.rects.entries[f.rects.find(6) orelse return null];
    return rectOf(entry.rect);
}
fn rectOf(r: layout.UiRect) draw.Rect {
    return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(@max(0, r.width)), .h = @intFromFloat(@max(0, r.height)) };
}
fn contains(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    return false;
}
pub fn collect(tab: Tab, placement: usize, paused: bool, pinned: bool, anonymize: bool, query: []const u8, offset: *usize, status: []const u8, json: []const u8, p: props.ChromeProps, scale: u32, tk: *const tokens.Tokens, a: std.mem.Allocator, hovered: ?u64, out: *std.ArrayList(draw.ChromeDraw)) !void {
    const base = try labelsFor(a, tab, paused, pinned, anonymize, query, status);
    if (placement < 5) base[18 + placement].accent = true;
    var all: std.ArrayList(fields.Row) = .empty;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{ .allocate = .alloc_always });
    if (parsed.value == .object) if (parsed.value.object.get(@tagName(tab))) |section| try fields.flatten(a, section, "", &all);
    var filtered: std.ArrayList(fields.Row) = .empty;
    for (all.items) |row| {
        if (query.len == 0 or (!row.heading and (contains(row.key, query) or contains(row.label, query) or contains(row.value, query)))) try filtered.append(a, row);
    }
    if (filtered.items.len == 0) try filtered.append(a, .{ .key = "", .label = i18n.t(.inspector_empty) });
    const height = props.workspaceRect(p.metrics).h;
    const compact = props.workspaceRect(p.metrics).w >= spacing.pointsPx(640, scale);
    const rows: usize = (height -| spacing.pointsPx(if (compact) 180 else 244, scale)) / @max(spacing.pointsPx(if (compact) 24 else 32, scale), 1);
    offset.* = @min(offset.*, filtered.items.len -| rows);
    const count = @min(rows, filtered.items.len - offset.*);
    const labels = try a.alloc(Label, base.len + count * 2);
    @memcpy(labels[0..base.len], base);
    for (0..count) |i| {
        const row = filtered.items[offset.* + i];
        labels[base.len + i * 2] = .{ .id = 101 + i * 3, .text = row.label, .accent = row.heading, .muted = !row.heading };
        labels[base.len + i * 2 + 1] = .{ .id = 102 + i * 3, .text = if (row.missing) i18n.t(.inspector_unavailable) else row.value, .muted = row.missing };
    }
    const frame = try build(a, p, scale, labels, count);
    const ops = try a.alloc(draw.Op, frame.rects.entries.len + labels.len + count * 2 + 12);
    const painted = try paint.paint(frame.rects, .{ .hovered = hovered }, tk, .sidebar, .{ .ops = ops });
    var n = painted.ops.len;
    // Thin rules distinguish bands and rows; selected tabs use an underline, not a pill.
    for ([_]u64{ 4, 5, 8 }) |id| {
        const r = rectOf(frame.rects.entries[frame.rects.find(id).?].rect);
        ops[n] = .{ .quad = .{ .rect = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) - 1, .w = r.w, .h = 1 }, .fill_role = .divider } };
        n += 1;
    }
    const active = rectOf(frame.rects.entries[frame.rects.find(20 + @as(u64, @intCast(@backingInt(tab)))).?].rect);
    ops[n] = .{ .quad = .{ .rect = .{ .x = active.x, .y = active.y + @as(i32, @intCast(active.h)) - 2, .w = active.w, .h = 2 }, .fill_role = .surface_fg } };
    n += 1;
    for (0..count) |i| {
        const r = rectOf(frame.rects.entries[frame.rects.find(100 + i * 3).?].rect);
        const row = filtered.items[offset.* + i];
        if (row.heading) {
            ops[n] = .{ .quad = .{ .rect = r, .fill_role = .inset_bg } };
            n += 1;
        }
        ops[n] = .{ .quad = .{ .rect = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) - 1, .w = r.w, .h = 1 }, .fill_role = .divider } };
        n += 1;
    }
    for (labels) |label| {
        const entry = frame.rects.entries[frame.rects.find(label.id) orelse continue];
        const r = rectOf(entry.rect);
        const clip = rectOf(if (entry.effective_clip) |c| layout.intersectRect(c, entry.rect) else entry.rect);
        const run = try a.alloc(draw.Run, 1);
        const text = if (label.id == 21 and r.w < spacing.pointsPx(100, scale)) label.text[0 .. std.mem.indexOf(u8, label.text, " / ") orelse label.text.len] else label.text;
        run[0] = .{ .text = text, .bold = label.accent or label.id == 3 };
        const pad: i32 = @intCast(spacing.px(.sm, scale));
        const centered = (label.id >= 10 and label.id <= 23) or label.id == 7 or (label.id >= 40 and label.id <= 44);
        const text_role: typography.ChromeTextRole = if (label.id == 3) .group_heading else .control;
        const text_y = r.y + @as(i32, @intCast((r.h -| typography.lineHeightPx(text_role, scale)) / 2));
        ops[n] = .{ .text = .{ .origin = .{ .x = r.x + pad, .y = text_y }, .runs = run, .role = if (label.muted) .list_secondary_fg else .surface_fg, .text_role = text_role, .max_width_px = r.w -| @as(u32, @intCast(pad * 2)), .placement = if (centered) .{ .center_in_rect = r } else .origin, .clip = clip, .scroll_clipped = true, .above_scroll = true } };
        n += 1;
    }

    try out.append(a, .{ .layer = .sidebar, .ops = ops[0..n], .independent_panel = true });
}

// Preserve the original boundary regression while moving geometry to the shared tree.
test "inspector hit testing shares responsive tab and toolbar geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 961, .backing_height_px = 600 } };
    const labels = try labelsFor(a, .overview, false, false, true, "", "");
    const f = try build(a, p, 1000, labels, 0);
    const rect = f.rects.entries[f.rects.find(23).?].rect;
    const found = hit(p, 1000, a, rect.x + rect.width / 2, rect.y + rect.height / 2).?;
    try std.testing.expectEqual(Tab.events, found.tab);
    try std.testing.expect(hit(p, 1000, a, -1, -1) == null);
}

test "inspector cursor uses filter and action geometry at narrow wide and retina sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 360, 720 }) |width| for ([_]u32{ 1000, 2000 }) |scale| {
        var p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = width, .backing_height_px = 600 } };
        p.metrics.backing_width_px = width * scale / 1000;
        p.metrics.backing_height_px = 600 * scale / 1000;
        const filter = controlRect(p, scale, a, 6).?;
        try std.testing.expectEqual(Cursor.text, cursor(p, scale, a, @as(f64, @floatFromInt(filter.x)) + 1, @as(f64, @floatFromInt(filter.y)) + 1));
        const button = controlRect(p, scale, a, 40).?;
        try std.testing.expectEqual(Cursor.hand, cursor(p, scale, a, @as(f64, @floatFromInt(button.x)) + 1, @as(f64, @floatFromInt(button.y)) + 1));
        try std.testing.expectEqual(Cursor.arrow, cursor(p, scale, a, -1, -1));
    };
}
