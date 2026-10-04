//! 행과 펼침 버튼을 하나의 immutable tree에 둔다. 버튼 hit-test를 host가 다시 계산하지 않는다.
const std = @import("std");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");

pub const root_id = 1;
pub fn rowId(index: usize) u64 {
    return 16 + @as(u64, @intCast(index)) * 2;
}
pub fn disclosureId(index: usize) u64 {
    return rowId(index) + 1;
}

pub const Buffers = struct {
    nodes: []tree.UiNode,
    entries: []tree.RectEntry,
    layout_items: []layout.Item,
    flex_scratch: []layout.FlexScratch,
    child_rects: []layout.UiRect,
    actions: []ids.Entry,
};
pub const Frame = struct { tree: tree.UiRectTree, actions: []const ids.Entry, metrics: types.Metrics };
pub const BuildError = tree.BuildError || error{InsufficientBuffer};

pub fn bufferSizes(rows: usize) struct { nodes: usize, entries: usize, actions: usize } {
    return .{ .nodes = rows * 2 + 2, .entries = rows * 2 + 2, .actions = rows * 2 };
}

pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    const m = types.Metrics.resolve(props.scale_milli);
    const size = bufferSizes(props.rows.len);
    if (buffers.nodes.len < size.nodes or buffers.actions.len < size.actions) return error.InsufficientBuffer;
    var table = ids.Table.init(buffers.actions);
    const rows = buffers.nodes[0..props.rows.len];
    for (rows, props.rows, 0..) |*node, row, index| {
        const child = &buffers.nodes[props.rows.len + index];
        const left = m.left(props.viewport_px.width, row.depth);
        // 극단적으로 좁은 폭에서는 이름 몫을 먼저 남기고 펼침 버튼을 줄인다.
        const disclosure_w = @min(@as(f32, @floatFromInt(m.disclosure)), @max(0, props.viewport_px.width - left - @as(f32, @floatFromInt(m.inset)) - @min(props.viewport_px.width / 2, 40)));
        child.* = tree.card(.{
            .id = disclosureId(row.model_index),
            .style = .{ .width = .{ .px = disclosure_w }, .height = .{ .percent = 1 }, .flex = .{ .shrink = 0 } },
            .action = if (row.enabled and row.expandable) table.append(props.generation, .{ .toggle = row.model_index }, true) catch return error.InsufficientBuffer else null,
            .cursor = if (row.expandable) .press else .auto,
            .paint = .{ .opacity = 0, .shadow = .none },
            .semantics = if (row.expandable) .{ .role = .button, .label = row.label, .expanded = row.expanded, .enabled = row.enabled } else null,
        }, &.{});
        node.* = tree.card(.{
            .id = rowId(row.model_index),
            .style = .{
                .width = .{ .percent = 1 },
                .height = .{ .px = @floatFromInt(m.row_h) },
                .flex = .{ .shrink = 0 },
                .padding = .{ .left = left },
            },
            .action = if (row.enabled) table.append(props.generation, .{ .navigate = row.model_index }, true) catch return error.InsufficientBuffer else null,
            .variant = if (row.active) .selected else .surface,
            .paint = .{ .background = if (row.active) .tab_active_bg else .surface_bg, .shadow = .none, .border_widths_px = .{ 0, 0, 0, 0 }, .corner_radii_px = .{ 0, 0, 0, 0 } },
            .cursor = if (row.enabled) .press else .arrow,
            .align_items = .start,
            .semantics = .{ .role = if (row.enabled) .tree_item else .text, .label = row.label, .enabled = row.enabled, .selected = row.active, .expanded = if (row.expandable) row.expanded else null, .level = row.depth +| 1 },
        }, buffers.nodes[props.rows.len + index .. props.rows.len + index + 1]);
    }
    const list_h = @as(u32, @intCast(@min(props.rows.len, std.math.maxInt(u32)))) *| m.row_h;
    const list_index = props.rows.len * 2;
    buffers.nodes[list_index] = tree.container(.{
        .id = 2,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(list_h) }, .flex = .{ .shrink = 0 } },
        .direction = .column,
    }, rows);
    const root = tree.scrollArea(.{
        .id = root_id,
        .scroll = .{ .first_item_origin_y_px = -@as(i32, @intCast(@min(props.origin_shift_px, std.math.maxInt(i32)))), .content_h_px = list_h },
    }, buffers.nodes[list_index .. list_index + 1]);
    const built = try tree.build(root, .{ .root_size = props.viewport_px, .max_entries = size.entries, .max_depth = 4 }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    return .{ .tree = .{ .entries = built.entries, .generation = props.generation }, .actions = table.slice(), .metrics = m };
}
