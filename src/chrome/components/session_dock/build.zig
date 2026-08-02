//! Bounded Session Dock geometry and action projection.
//!
//! A caller supplies every backing slice. Failed candidates clear through `ui.tree.build`, so a
//! half-built dock can never replace the previous tree/action snapshot in the platform host.

const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const NodeIds = struct {
    pub const root: u64 = 0x5344_0000;
    pub const header: u64 = 0x5344_0001;
    pub const scope_row: u64 = 0x5344_0002;
    pub const scope_workspace: u64 = 0x5344_0003;
    pub const scope_project: u64 = 0x5344_0004;
    pub const scope_all: u64 = 0x5344_0005;
    pub const search: u64 = 0x5344_0006;
    pub const content: u64 = 0x5344_0007;
    pub const item_base: u64 = 0x5344_1000;

    pub fn item(index: usize) u64 {
        return item_base + index;
    }
};

pub const Buffers = struct {
    /// `items + scopes + top-level children`; root itself remains a stack value.
    nodes: []tree.UiNode,
    entries: []tree.RectEntry,
    layout_items: []layout.Item,
    flex_scratch: []layout.FlexScratch,
    child_rects: []layout.UiRect,
    actions: []ids.Entry,
};

pub const Frame = struct {
    tree: tree.UiRectTree,
    actions: []const ids.Entry,
};

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer };

/// Builds a column whose text is emitted later from the resulting rect tree. Every interactive
/// rectangle belongs to this one candidate tree: no platform y-row arithmetic is allowed to make
/// a second hit region for scopes/groups/cards.
pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    const needed_nodes = props.items.len + 7; // item leaves + 3 scopes + header/scope-row/search/content
    if (buffers.nodes.len < needed_nodes) return error.InsufficientNodeBuffer;

    const m = types.Metrics.fromCellHeight(props.cell_height_px);
    var table = ids.Table.init(buffers.actions);
    const refresh = table.append(props.snapshot_generation, .refresh) catch return error.InsufficientActionBuffer;
    const workspace = table.append(props.snapshot_generation, .{ .scope = .workspace }) catch return error.InsufficientActionBuffer;
    const project = table.append(props.snapshot_generation, .{ .scope = .project }) catch return error.InsufficientActionBuffer;
    const all = table.append(props.snapshot_generation, .{ .scope = .all }) catch return error.InsufficientActionBuffer;
    const search = table.append(props.snapshot_generation, .focus_search) catch return error.InsufficientActionBuffer;

    // Children are stored first, then parent slices borrow these stable ranges. `UiNode` is a
    // value tree, so this avoids heap allocation and makes the buffer cap part of the contract.
    const item_nodes = buffers.nodes[0..props.items.len];
    for (props.items, item_nodes, 0..) |item, *node, index| {
        const action = switch (item) {
            .group => |group| table.append(props.snapshot_generation, .{ .toggle_group = group.identity }) catch return error.InsufficientActionBuffer,
            .card => |card| table.append(props.snapshot_generation, .{ .select_card = card.identity }) catch return error.InsufficientActionBuffer,
        };
        const height = switch (item) {
            .group => m.group_h,
            .card => m.card_h,
        };
        const visual: tree.CardVisual = switch (item) {
            .group => .{ .variant = .surface, .paint = .{} },
            .card => |card| .{ .variant = if (card.selected) .selected else .surface, .paint = .{} },
        };
        node.* = tree.card(.{
            .id = NodeIds.item(index),
            .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(height) }, .margin = .{ .bottom = @floatFromInt(m.gap) } },
            .variant = visual.variant,
            .paint = visual.paint,
            .action = action,
            .overflow = .clip,
        }, &.{});
    }

    const scope_nodes = buffers.nodes[props.items.len..][0..3];
    scope_nodes[0] = scopeNode(NodeIds.scope_workspace, workspace, props.workspace_scope_enabled, props.scope == .workspace);
    scope_nodes[1] = scopeNode(NodeIds.scope_project, project, props.project_scope_enabled, props.scope == .project);
    scope_nodes[2] = scopeNode(NodeIds.scope_all, all, true, props.scope == .all);

    const top = buffers.nodes[props.items.len + 3 ..][0..4];
    top[0] = tree.card(.{
        .id = NodeIds.header,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.header_h) }, .margin = .{ .bottom = @floatFromInt(m.gap) } },
        .variant = .raised,
        .paint = .{},
        .action = refresh,
        .overflow = .clip,
    }, &.{});
    top[1] = tree.container(.{
        .id = NodeIds.scope_row,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.scope_h) }, .margin = .{ .bottom = @floatFromInt(m.gap) }, .gap = @floatFromInt(m.gap) },
        .direction = .row,
        .overflow = .clip,
    }, scope_nodes);
    top[2] = tree.card(.{
        .id = NodeIds.search,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.search_h) }, .margin = .{ .bottom = @floatFromInt(m.gap) } },
        .variant = if (props.search_focused) .selected else .surface,
        .paint = .{},
        .action = search,
        .overflow = .clip,
    }, &.{});
    top[3] = tree.container(.{
        .id = NodeIds.content,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .fill = 1 } },
        .overflow = .clip,
    }, item_nodes);

    const root = tree.container(.{
        .id = NodeIds.root,
        .style = .{ .padding = .{ .top = @floatFromInt(m.pad), .right = @floatFromInt(m.pad), .bottom = @floatFromInt(m.pad), .left = @floatFromInt(m.pad) } },
        .overflow = .clip,
    }, top);
    const built = try tree.build(root, .{
        .root_size = props.viewport_px,
        .max_entries = needed_nodes + 1,
        .max_depth = 3,
    }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    return .{ .tree = built, .actions = table.slice() };
}

fn scopeNode(id: u64, action: tree.UiAction, enabled: bool, selected: bool) tree.UiNode {
    return tree.card(.{
        .id = id,
        // Row children need a definite main-axis share. Leaving width auto makes each scope's
        // rect zero-width, so its text and action silently disappear even though the row exists.
        // `UiNode` also validates the card's own column container, where width is cross-axis;
        // use a percentage rather than `fill` so this leaf remains valid in both contexts.
        .style = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .percent = 1 } },
        .variant = if (selected) .selected else .surface,
        .paint = .{},
        .action = .{ .id = action.id, .enabled = enabled },
        .overflow = .clip,
    }, &.{});
}

test "SessionDock build shares action rects with the completed tree" {
    const props = types.Props{
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 9,
        .displayed_count = 1,
        .items = &.{
            .{ .group = .{ .identity = 11, .label = "workspace", .count = 1 } },
            .{ .card = .{ .identity = 12, .provider = .codex, .title = "title", .summary = "summary", .metadata = "meta" } },
        },
    };
    var nodes: [9]tree.UiNode = undefined;
    var entries: [10]tree.RectEntry = undefined;
    var layout_items: [10]layout.Item = undefined;
    var flex_scratch: [10]layout.FlexScratch = undefined;
    var child_rects: [10]layout.UiRect = undefined;
    var actions: [8]ids.Entry = undefined;
    const frame = try build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const workspace_index = frame.tree.find(NodeIds.scope_workspace).?;
    const project_index = frame.tree.find(NodeIds.scope_project).?;
    const all_index = frame.tree.find(NodeIds.scope_all).?;
    try @import("std").testing.expect(frame.tree.entries[workspace_index].rect.width > 0);
    try @import("std").testing.expect(frame.tree.entries[project_index].rect.width > 0);
    try @import("std").testing.expect(frame.tree.entries[all_index].rect.width > 0);
    const card_index = frame.tree.find(NodeIds.item(1)).?;
    try @import("std").testing.expect(frame.tree.entries[card_index].rect.width > 0);
    var table = ids.Table.init(@constCast(frame.actions));
    table.count = frame.actions.len;
    try @import("std").testing.expectEqual(@as(?ids.Intent, .{ .select_card = 12 }), table.resolve(7, 9));
}
