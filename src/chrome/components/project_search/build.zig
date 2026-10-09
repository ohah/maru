//! 고정 입력 머리와 보이는 결과 창을 같은 tree에 발행한다. 그려지지 않은 행에는 동작이 없다.
const std = @import("std");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
pub fn fieldId(index: usize) u64 {
    return 10 + index;
}
pub fn optionId(index: usize) u64 {
    return 20 + index;
}
pub fn rowId(index: usize) u64 {
    return 100 + index;
}
pub const Buffers = struct { nodes: []tree.UiNode, entries: []tree.RectEntry, items: []layout.Item, flex: []layout.FlexScratch, rects: []layout.UiRect, actions: []ids.Entry };
pub const Frame = struct { tree: tree.UiRectTree, actions: []const ids.Entry, metrics: types.Metrics };
pub fn size(rows: usize) usize {
    return rows +| 30;
}
pub fn build(p: types.Props, b: Buffers) !Frame {
    const m = types.Metrics.resolveReplace(p.scale, p.expanded, p.replacing);
    if (p.shift >= m.row) return error.InvalidGeometry;
    const count = std.math.cast(u32, p.rows.len) orelse return error.InvalidGeometry;
    const content_height = std.math.mul(u32, m.row, count) catch return error.InvalidGeometry;
    if (b.nodes.len < size(p.rows.len)) return error.InsufficientBuffer;
    var table = ids.Table.init(b.actions);
    var n: usize = 0;
    const header = b.nodes[n..][0 .. (if (p.expanded) @as(usize, 6) else 4) + @intFromBool(p.replacing)];
    n += header.len;
    const fields = b.nodes[n..][0..4];
    n += 4;
    for (fields, 0..) |*node, index| node.* = tree.card(.{
        .id = fieldId(index),
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } },
        .action = if (index == 0 or index == 3 and p.replacing or index > 0 and index < 3 and p.expanded) try table.append(p.generation, .{ .field = index }, true) else null,
        .paint = .{ .background = .surface_bg, .shadow = .none, .border_widths_px = .{ 1, 1, 1, 1 }, .border = .muted_fg, .corner_radii_px = .{ 2, 2, 2, 2 } },
        .semantics = .{ .role = .text, .label = if (index == 3) p.replacement_label else p.field_labels[index], .value = if (index == 3) p.replacement else p.fields[index], .focusable = true, .selected = p.focused == index },
    }, &.{});
    const opts = b.nodes[n..][0..8];
    n += 8;
    for (opts, 0..) |*node, index| node.* = tree.card(.{
        .id = optionId(index),
        .style = .{ .width = .{ .percent = 1.0 / 8.0 }, .height = .{ .percent = 1 }, .flex = .{ .shrink = 0 } },
        .action = try table.append(p.generation, if (index < 4) .{ .option = index } else if (index == 4) .run else if (index == 5) .cancel else .{ .option = index }, commandEnabled(p, index)),
        .paint = .{ .background = if (selected(p, index)) .tab_active_bg else .surface_bg, .shadow = .none },
        .semantics = .{ .role = .button, .label = if (index == 6) p.replace_label else if (index == 7) p.back_label else p.option_labels[index], .selected = selected(p, index), .enabled = commandEnabled(p, index) },
    }, &.{});
    header[0] = tree.container(.{ .id = 3, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } } }, fields[0..1]);
    header[1] = tree.container(.{ .id = 4, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } }, .direction = .row }, opts);
    var tail: usize = 2;
    if (p.expanded) {
        header[2] = tree.container(.{ .id = 5, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } } }, fields[1..2]);
        header[3] = tree.container(.{ .id = 6, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } } }, fields[2..3]);
        tail = 4;
    }
    if (p.replacing) {
        header[tail] = tree.container(.{ .id = 14, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } } }, fields[3..4]);
        tail += 1;
    }
    header[tail] = tree.card(.{ .id = 7, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } }, .paint = .{ .opacity = 0, .shadow = .none }, .semantics = .{ .role = .text, .label = p.scopes } }, &.{});
    header[tail + 1] = tree.card(.{ .id = 8, .style = .{ .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } }, .paint = .{ .opacity = 0, .shadow = .none }, .semantics = .{ .role = .text, .label = p.status } }, &.{});
    const rows = b.nodes[n..][0..p.rows.len];
    n += rows.len;
    for (rows, p.rows) |*node, row| node.* = tree.card(.{
        .id = rowId(row.index),
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.row) }, .flex = .{ .shrink = 0 } },
        .action = if (row.enabled) try table.append(p.generation, .{ .row = row.index }, true) else null,
        .paint = .{ .background = if (row.file) .tab_active_bg else if (row.kind == .added) .diff_added_bg else if (row.kind == .removed) .diff_removed_bg else .surface_bg, .shadow = .none, .opacity = if (row.kind == .normal) 255 else 46 },
        .semantics = .{ .role = .list_item, .label = row.label, .enabled = row.enabled, .expanded = if (row.file) row.expanded else null },
    }, &.{});
    b.nodes[n] = tree.container(.{ .id = 9, .direction = .column, .style = .{ .height = .{ .px = @floatFromInt(content_height) }, .flex = .{ .shrink = 0 } } }, rows);
    const scroll_child = b.nodes[n .. n + 1];
    n += 1;
    b.nodes[n] = tree.container(.{ .id = 2, .direction = .column, .style = .{ .height = .{ .px = @floatFromInt(m.header) }, .flex = .{ .shrink = 0 } } }, header);
    n += 1;
    b.nodes[n] = tree.scrollArea(.{ .id = 30, .style = .{ .height = .{ .px = @max(0, p.viewport.height - @as(f32, @floatFromInt(m.header))) }, .flex = .{ .shrink = 0 } }, .scroll = .{ .first_item_origin_y_px = -@as(i32, @intCast(p.shift)), .content_h_px = content_height } }, scroll_child);
    const children = b.nodes[n - 1 .. n + 1];
    const root = tree.container(.{ .id = 1, .direction = .column, .overflow = .clip }, children);
    const built = try tree.build(root, .{ .root_size = p.viewport, .max_entries = b.entries.len, .max_depth = 5 }, .{ .entries = b.entries, .items = b.items, .flex_scratch = b.flex, .child_rects = b.rects });
    return .{ .tree = .{ .entries = built.entries, .generation = p.generation }, .actions = table.slice(), .metrics = m };
}

fn selected(p: types.Props, index: usize) bool {
    return if (index < 3) p.options[index] else if (index == 3) p.expanded else if (index == 6) p.replacing else false;
}

fn commandEnabled(p: types.Props, index: usize) bool {
    return if (index == 4) p.can_search else if (index == 5) p.running else if (index == 7) p.previewing else true;
}
