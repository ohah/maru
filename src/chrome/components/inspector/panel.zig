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
pub const Tab = enum { overview, path, terminal, events, elements };
pub const Hit = union(enum) {
    tab: Tab,
    tool: usize,
    privacy,
    picker,
    placement: usize,
    pub fn nodeId(self: Hit) u64 {
        return switch (self) {
            .tab => |t| 20 + @as(u64, @intCast(@backingInt(t))),
            .tool => |i| 10 + i,
            .privacy => 7,
            .picker => 48,
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
    const main = nodes[0..8];
    const tools = nodes[8..16];
    const tabs = try a.alloc(tree.UiNode, 5);
    const header = nodes[20..27];
    const footer = nodes[27..31];
    const columns = nodes[31..33];
    const rows = nodes[33..][0..body_count];
    const cells = nodes[33 + body_count ..][0 .. body_count * 2];
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
    const placement_nodes = try a.alloc(tree.UiNode, 6);
    for (placement_nodes, 0..) |*node, i| node.* = tree.button(.{ .id = if (i == 5) 48 else 40 + i, .action = .{ .id = 14 + i }, .variant = .ghost, .style = .{ .width = .{ .percent = 1.0 / 6.0 }, .height = .{ .percent = 1 } }, .semantics = .{ .role = .button, .label = if (i == 5) i18n.t(.inspector_pick) else placementLabel(i), .selected = labels[if (i == 5) 29 else 18 + i].accent } });
    const header_bands = try a.alloc(tree.UiNode, 2);
    header_bands[0] = main[0];
    header_bands[1] = tree.container(.{ .id = 46, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(28, scale)) }, .flex = .{ .shrink = 0 } } }, placement_nodes);
    main[0] = tree.container(.{ .id = 45, .direction = .column, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 60 else 92, scale)) }, .flex = .{ .shrink = 0 } } }, header_bands);
    for (tabs, 0..) |*node, i| node.* = tree.button(.{ .id = 20 + i, .action = .{ .id = if (i == 4) 20 else 9 + i }, .variant = .ghost, .paint = .{ .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 } }, .style = .{ .width = .{ .percent = 0.2 }, .height = .{ .percent = 1 } }, .semantics = .{ .role = .tab, .label = labels[if (i == 4) 28 else 9 + i].text, .selected = labels[if (i == 4) 28 else 9 + i].accent } });
    main[1] = tree.container(.{ .id = 5, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 28 else 32, scale)) }, .padding = .{ .left = @floatFromInt(gap), .right = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } } }, tabs);
    const context = try a.alloc(tree.UiNode, if (contextPoints(p, scale) == 40) 2 else 1);
    for (context, 0..) |*node, i| node.* = tree.container(.{ .id = if (context.len == 1) 32 else 31 + i, .style = .{ .height = .{ .percent = 1.0 / @as(f32, @floatFromInt(context.len)) } } }, &.{});
    main[2] = tree.container(.{ .id = 30, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(contextPoints(p, scale), scale)) }, .flex = .{ .shrink = 0 } } }, context);
    main[3] = tree.card(.{ .id = 6, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 28 else 32, scale)) }, .margin = .{ .left = @floatFromInt(inset), .right = @floatFromInt(inset), .top = @floatFromInt(gap), .bottom = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } }, .paint = .{ .background = .inset_bg, .corner_radii_px = .{ 4, 4, 4, 4 }, .shadow = .none, .border_widths_px = .{ 1, 1, 1, 1 }, .border = .divider } }, &.{});
    for (columns, 0..) |*node, i| node.* = tree.container(.{ .id = 26 + i, .style = .{ .width = .{ .percent = if (i == 0) 0.36 else 0.64 }, .height = .{ .percent = 1 } } }, &.{});
    main[4] = tree.card(.{ .id = 8, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(row) }, .flex = .{ .shrink = 0 } }, .paint = .{ .background = .inset_bg, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 }, .shadow = .none } }, columns);
    for (rows, 0..) |*node, i| {
        const pair = cells[i * 2 ..][0..2];
        for (pair, 0..) |*cell, col| cell.* = tree.container(.{ .id = 101 + i * 3 + col, .style = .{ .width = .{ .percent = if (col == 0) 0.36 else 0.64 }, .height = .{ .percent = 1 } } }, &.{});
        node.* = tree.container(.{ .id = 100 + i * 3, .direction = .row, .style = .{ .height = .{ .px = @floatFromInt(row) }, .flex = .{ .shrink = 0 } } }, pair);
    }
    main[5] = tree.container(.{ .id = 10000, .style = .{ .height = .{ .fill = 1 } }, .overflow = .clip }, rows);
    const detail = try a.alloc(tree.UiNode, 3);
    for (detail, 0..) |*node, i| node.* = tree.container(.{ .id = 61 + i, .style = .{ .height = .{ .percent = 1.0 / 3.0 } } }, &.{});
    main[6] = tree.card(.{ .id = 60, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(60, scale)) }, .flex = .{ .shrink = 0 } }, .paint = .{ .background = .inset_bg, .shadow = .none, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 } } }, detail);
    footer[0] = tree.container(.{ .id = 28, .style = .{ .height = .{ .percent = 1 }, .flex = .{ .grow = 1 } } }, &.{});
    footer[1] = tree.button(.{ .id = 7, .action = .{ .id = 13 }, .variant = .ghost, .style = .{ .width = .{ .px = @floatFromInt(spacing.pointsPx(144, scale)) }, .height = .{ .percent = 1 }, .flex = .{ .shrink = 0 } } });
    footer[2] = tools[5];
    footer[3] = tools[6];
    main[7] = tree.container(.{ .id = 9, .direction = .row, .align_items = .center, .style = .{ .height = .{ .px = @floatFromInt(spacing.pointsPx(if (compact) 32 else 40, scale)) }, .padding = .{ .left = @floatFromInt(inset), .right = @floatFromInt(gap) }, .flex = .{ .shrink = 0 } } }, footer);
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
    const labels = try a.alloc(Label, 30);
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
    for ([_]u64{ 31, 32, 61, 62, 63 }, 23..) |id, i| labels[i] = .{ .id = id, .text = "", .muted = true };
    labels[28] = .{ .id = 24, .text = i18n.t(.inspector_elements), .accent = tab == .elements };
    labels[29] = .{ .id = 48, .text = i18n.t(.inspector_pick), .accent = false };
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
    if (h.action_id == 20) return .{ .tab = .elements };
    if (h.action_id == 19) return .picker;
    if (h.action_id <= 12) return .{ .tab = @fromBackingInt(@as(u3, @intCast(h.action_id - 9))) };
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
fn contextPoints(p: props.ChromeProps, scale: u32) u16 {
    return if (props.workspaceRect(p.metrics).h >= spacing.pointsPx(480, scale)) 40 else 24;
}
const Prepared = struct { root: std.json.Value, rows: []fields.Row, count: usize, offset: usize };
fn prepare(a: std.mem.Allocator, tab: Tab, query: []const u8, json: []const u8, p: props.ChromeProps, scale: u32, offset: usize) !Prepared {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{ .allocate = .alloc_always });
    var all: std.ArrayList(fields.Row) = .empty;
    if (parsed.value == .object) if (parsed.value.object.get(@tagName(tab))) |section| {
        if (tab == .elements and section == .object) {
            // Put the inspected node first, even in a shallow top/bottom dock.
            const hovered_node = section.object.get("hovered") orelse .null;
            const selected_node = section.object.get("selected") orelse .null;
            const prefix: []const u8 = if (hovered_node == .object) "hovered" else "selected";
            const node = if (hovered_node == .object) hovered_node else selected_node;
            if (node == .object) {
                var it = node.object.iterator();
                while (it.next()) |field| {
                    const path = try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, field.key_ptr.* });
                    if ((std.mem.eql(u8, field.key_ptr.*, "rect") or std.mem.eql(u8, field.key_ptr.*, "visible_rect")) and field.value_ptr.* == .object) {
                        const r = field.value_ptr.object;
                        const rendered = try std.fmt.allocPrint(a, "{s} × {s} px · {s}, {s}", .{ try std.json.Stringify.valueAlloc(a, r.get("width") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, r.get("height") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, r.get("x") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, r.get("y") orelse .null, .{}) });
                        try all.append(a, .{ .key = path, .label = path, .value = rendered });
                    } else try fields.flatten(a, field.value_ptr.*, path, &all);
                }
            }
            if (section.object.get("coverage")) |coverage| try fields.flatten(a, coverage, "coverage", &all);
            if (section.object.get("nodes")) |nodes| try fields.flatten(a, nodes, "nodes", &all);
        } else try fields.flatten(a, section, "", &all);
    };
    try fields.decorate(a, parsed.value, @tagName(tab), all.items);
    const compact = props.workspaceRect(p.metrics).w >= spacing.pointsPx(640, scale);
    const reserve = (if (compact) @as(u16, 180) else @as(u16, 244)) + contextPoints(p, scale) + 60;
    const budget = (props.workspaceRect(p.metrics).h -| spacing.pointsPx(reserve, scale)) / @max(spacing.pointsPx(if (compact) 24 else 32, scale), 1);
    var filtered: std.ArrayList(fields.Row) = .empty;
    for (all.items) |row| {
        if (row.heading and budget < 3) continue;
        if (query.len == 0 or (!row.heading and (contains(row.key, query) or contains(row.label, query) or contains(row.value, query) or contains(row.raw_value, query) or contains(row.meaning, query) or contains(fields.sourceLabel(row.info.source), query)))) try filtered.append(a, row);
    }
    if (filtered.items.len == 0) try filtered.append(a, .{ .key = "", .label = i18n.t(.inspector_empty) });
    const start = @min(offset, filtered.items.len -| budget);
    return .{ .root = parsed.value, .rows = filtered.items, .count = @min(budget, filtered.items.len - start), .offset = start };
}
fn formatted(a: std.mem.Allocator, key: i18n.Key, args: []const i18n.Arg) ![]const u8 {
    return i18n.format(try a.alloc(u8, 1024), i18n.t(key), args);
}
fn overviewValue(a: std.mem.Allocator, root: std.json.Value, key: []const u8) ![]const u8 {
    if (root == .object) if (root.object.get("overview")) |overview| if (overview == .object) if (overview.object.get(key)) |value| return std.json.Stringify.valueAlloc(a, value, .{});
    return i18n.t(.inspector_unavailable);
}
fn selectedRow(prepared: Prepared, key: []const u8) ?fields.Row {
    if (key.len != 0) for (prepared.rows) |row| {
        if (std.mem.eql(u8, row.field_path, key)) return row;
    };
    for (prepared.rows[prepared.offset .. prepared.offset + prepared.count]) |row| if (!row.heading and row.field_path.len != 0) return row;
    return null;
}
pub const FieldPick = struct { key: []const u8, id: u64 };
pub fn fieldAt(tab: Tab, query: []const u8, offset: usize, json: []const u8, p: props.ChromeProps, scale: u32, a: std.mem.Allocator, x: f64, y: f64) ?FieldPick {
    const prepared = prepare(a, tab, query, json, p, scale, offset) catch return null;
    const f = build(a, p, scale, labelsFor(a, tab, false, false, true, query, "") catch return null, prepared.count) catch return null;
    for (prepared.rows[prepared.offset .. prepared.offset + prepared.count], 0..) |row, i| {
        if (row.heading or row.field_path.len == 0) continue;
        const id = 100 + i * 3;
        const e = f.rects.entries[f.rects.find(id) orelse continue];
        const r = if (e.effective_clip) |clip| layout.intersectRect(e.rect, clip) else e.rect;
        if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height) return .{ .key = row.field_path, .id = id };
    }
    return null;
}
pub fn dataControlRect(tab: Tab, query: []const u8, offset: usize, json: []const u8, p: props.ChromeProps, scale: u32, a: std.mem.Allocator, id: u64) ?draw.Rect {
    const prepared = prepare(a, tab, query, json, p, scale, offset) catch return null;
    const f = build(a, p, scale, labelsFor(a, tab, false, false, true, query, "") catch return null, prepared.count) catch return null;
    const e = f.rects.entries[f.rects.find(id) orelse return null];
    return rectOf(if (e.effective_clip) |clip| layout.intersectRect(e.rect, clip) else e.rect);
}
pub fn collect(tab: Tab, placement: usize, paused: bool, picking: bool, pinned: bool, anonymize: bool, query: []const u8, offset: *usize, status: []const u8, json: []const u8, p: props.ChromeProps, scale: u32, tk: *const tokens.Tokens, a: std.mem.Allocator, hovered: ?u64, selected_key: []const u8, out: *std.ArrayList(draw.ChromeDraw)) !void {
    const base = try labelsFor(a, tab, paused, pinned, anonymize, query, status);
    if (placement < 5) base[18 + placement].accent = true;
    const prepared = try prepare(a, tab, query, json, p, scale, offset.*);
    base[29].accent = picking;
    offset.* = prepared.offset;
    const filtered = prepared.rows;
    const count = prepared.count;
    const selected = selectedRow(prepared, selected_key);
    base[23].text = i18n.t(switch (tab) {
        .overview => .inspector_summary_overview,
        .path => .inspector_summary_path,
        .terminal => .inspector_summary_terminal,
        .events => .inspector_summary_events,
        .elements => .inspector_summary_elements,
    });
    base[24].text = try formatted(a, .inspector_sample_line, &.{ .{ .s = try overviewValue(a, prepared.root, "surface_id") }, .{ .s = if (paused) i18n.t(.inspector_paused) else i18n.t(.inspector_live) }, .{ .s = try overviewValue(a, prepared.root, "sampled_at_ms") } });
    if (tab == .elements and prepared.root == .object) if (prepared.root.object.get("elements")) |elements| if (elements == .object) {
        const hovered_node = elements.object.get("hovered") orelse .null;
        const node = if (hovered_node == .object) hovered_node else elements.object.get("selected") orelse .null;
        base[24].text = i18n.t(.inspector_summary_elements);
        if (node == .object) {
            const source = node.object.get("source") orelse .null;
            const id = node.object.get("id") orelse .null;
            const kind = node.object.get("kind") orelse .null;
            const rect = node.object.get("visible_rect") orelse .null;
            if (source == .string and id == .integer and kind == .string and rect == .object)
                base[24].text = try std.fmt.allocPrint(a, "{s} #{d} · {s} × {s} px · {s}, {s}", .{ source.string, id.integer, try std.json.Stringify.valueAlloc(a, rect.object.get("width") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, rect.object.get("height") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, rect.object.get("x") orelse .null, .{}), try std.json.Stringify.valueAlloc(a, rect.object.get("y") orelse .null, .{}) });
        }
    };
    if (selected) |row| {
        base[25].text = row.meaning;
        base[26].text = try formatted(a, .inspector_source_line, &.{ .{ .s = fields.sourceLabel(row.info.source) }, .{ .s = fields.availabilityLabel(row.info.availability) } });
        base[27].text = if (row.info.reason == .none) row.field_path else try formatted(a, .inspector_reason_raw, &.{ .{ .s = fields.reasonLabel(row.info.reason) }, .{ .s = row.raw_value } });
    } else base[25].text = i18n.t(.inspector_field_hint);
    const labels = try a.alloc(Label, base.len + count * 2);
    @memcpy(labels[0..base.len], base);
    for (0..count) |i| {
        const row = filtered[offset.* + i];
        labels[base.len + i * 2] = .{ .id = 101 + i * 3, .text = row.label, .accent = row.heading, .muted = !row.heading };
        labels[base.len + i * 2 + 1] = .{ .id = 102 + i * 3, .text = row.value, .muted = row.missing };
    }
    const frame = try build(a, p, scale, labels, count);
    const ops = try a.alloc(draw.Op, frame.rects.entries.len + labels.len + count * 2 + 12);
    const painted = try paint.paint(frame.rects, .{ .hovered = hovered }, tk, .sidebar, .{ .ops = ops });
    var n = painted.ops.len;
    // Thin rules distinguish bands and rows; selected tabs use an underline, not a pill.
    for ([_]u64{ 4, 5, 8, 30, 60 }) |id| {
        const r = rectOf(frame.rects.entries[frame.rects.find(id).?].rect);
        ops[n] = .{ .quad = .{ .rect = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) - 1, .w = r.w, .h = 1 }, .fill_role = .divider } };
        n += 1;
    }
    const active = rectOf(frame.rects.entries[frame.rects.find(20 + @as(u64, @intCast(@backingInt(tab)))).?].rect);
    ops[n] = .{ .quad = .{ .rect = .{ .x = active.x, .y = active.y + @as(i32, @intCast(active.h)) - 2, .w = active.w, .h = 2 }, .fill_role = .surface_fg } };
    n += 1;
    for (0..count) |i| {
        const r = rectOf(frame.rects.entries[frame.rects.find(100 + i * 3).?].rect);
        const row = filtered[offset.* + i];
        if (row.heading or hovered == 100 + i * 3 or (selected_key.len != 0 and std.mem.eql(u8, row.field_path, selected_key))) {
            ops[n] = .{ .quad = .{ .rect = r, .fill_role = if (row.heading) .inset_bg else .tab_hover_bg } };
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
        const text_role: typography.ChromeTextRole = if (label.id == 3) .group_heading else if (label.id == 31 or label.id == 32 or (label.id >= 61 and label.id <= 63)) .supporting else .control;
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

test "inspector field selection matches painted filtered rows at narrow wide retina and short sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"overview":{"backend":"in_process","window":7,"surface_id":1,"terminated":false,"sampled_at_ms":0}}
    ;
    for ([_]u32{ 360, 720 }) |width| for ([_]u32{ 300, 600 }) |height| for ([_]u32{ 1000, 2000 }) |scale| {
        const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = width * scale / 1000, .backing_height_px = height * scale / 1000 } };
        const prepared = try prepare(a, .overview, "window", json, p, scale, 0);
        if (width == 360 and height == 300) {
            try std.testing.expectEqual(@as(usize, 0), prepared.count);
            try std.testing.expect(dataControlRect(.overview, "window", 0, json, p, scale, a, 100) == null);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 1), prepared.count);
        const rect = dataControlRect(.overview, "window", 0, json, p, scale, a, 100).?;
        try std.testing.expect(rect.h > 0);
        const pick = fieldAt(.overview, "window", 0, json, p, scale, a, @as(f64, @floatFromInt(rect.x)) + 1, @as(f64, @floatFromInt(rect.y)) + 1).?;
        try std.testing.expectEqualStrings("overview.window", pick.key);
        try std.testing.expect(fieldAt(.overview, "window", 0, json, p, scale, a, -1, -1) == null);
        try std.testing.expectEqualStrings("overview.window", selectedRow(prepared, pick.key).?.field_path);
        try std.testing.expect(selectedRow(prepared, pick.key).?.meaning.len > 0);
    };
    const measured = try prepare(a, .overview, "terminated", json, .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 720, .backing_height_px = 600 } }, 1000, 0);
    try std.testing.expectEqualStrings("false", measured.rows[0].value);
    try std.testing.expectEqual(.available, measured.rows[0].info.availability);
}

test "inspector Elements and Pick controls share hit and paint in all scales" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]u32{ 1000, 2000 }) |scale| {
        const p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 720, .backing_height_px = 600 } };
        const pick = controlRect(p, scale, arena.allocator(), 48).?;
        const tab = controlRect(p, scale, arena.allocator(), 24).?;
        try std.testing.expect(hit(p, scale, arena.allocator(), @as(f64, @floatFromInt(pick.x)) + 1, @as(f64, @floatFromInt(pick.y)) + 1).? == .picker);
        try std.testing.expectEqual(Tab.elements, hit(p, scale, arena.allocator(), @as(f64, @floatFromInt(tab.x)) + 1, @as(f64, @floatFromInt(tab.y)) + 1).?.tab);
    }
}
