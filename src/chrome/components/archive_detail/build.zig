//! Bounded geometry and opaque action projection for ArchiveSessionDetailPanel.

const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const max_turns: usize = 3;

pub const NodeIds = struct {
    pub const root: u64 = 0x4152_0000;
    pub const header: u64 = 0x4152_0001;
    pub const metadata: u64 = 0x4152_0002;
    pub const section: u64 = 0x4152_0003;
    pub const content: u64 = 0x4152_0004;
    pub const actions: u64 = 0x4152_0005;
    pub const turn_base: u64 = 0x4152_0100;
    pub const resume_session: u64 = 0x4152_0200;
    pub const reveal: u64 = 0x4152_0201;
    pub const focus_live: u64 = 0x4152_0202;

    pub fn turn(index: usize) u64 {
        return turn_base + index;
    }
};

pub const Buffers = struct {
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

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer, TooManyTurns };

/// Produces exactly one rect tree for text, paint, hover and pointer dispatch. The component has
/// no fallback row arithmetic: hidden/disabled actions are encoded in this tree and action table.
pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    // A stale/unavailable result may still carry an old DTO while its source identity is being
    // rejected. Do not materialize any turn or live-session affordance from that old value: the
    // state boundary is enforced before tree/action publication, not only by dim paint.
    const visible_turns: []const types.Turn = if (types.isActionable(props)) props.turns else &.{};
    if (visible_turns.len > max_turns) return error.TooManyTurns;
    const live_count: usize = if (types.isActionable(props) and props.focus_live_enabled) 1 else 0;
    const action_count: usize = 2 + live_count;
    const needed_nodes = visible_turns.len + action_count + 5;
    if (buffers.nodes.len < needed_nodes) return error.InsufficientNodeBuffer;

    const action_ready = types.isActionable(props);
    const resume_enabled = action_ready and props.resume_enabled;
    const reveal_enabled = action_ready and props.reveal_enabled;
    var table = ids.Table.init(buffers.actions);
    const resume_action = table.append(props.snapshot_generation, .resume_session, resume_enabled) catch return error.InsufficientActionBuffer;
    const reveal = table.append(props.snapshot_generation, .reveal_log, reveal_enabled) catch return error.InsufficientActionBuffer;
    const focus_live = if (live_count == 1)
        table.append(props.snapshot_generation, .focus_live, true) catch return error.InsufficientActionBuffer
    else
        null;
    const m = types.Metrics.fromCellHeight(props.cell_height_px);

    const turns = buffers.nodes[0..visible_turns.len];
    for (turns, 0..) |*node, index| {
        node.* = tree.card(.{
            .id = NodeIds.turn(index),
            .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.turn_h) }, .margin = .{ .bottom = @floatFromInt(m.gap) } },
            .variant = .surface,
            .paint = .{},
            .overflow = .clip,
        }, &.{});
    }

    const action_nodes = buffers.nodes[visible_turns.len..][0..action_count];
    action_nodes[0] = actionNode(NodeIds.resume_session, resume_action, resume_enabled, action_count);
    action_nodes[1] = actionNode(NodeIds.reveal, reveal, reveal_enabled, action_count);
    if (focus_live) |action| action_nodes[2] = actionNode(NodeIds.focus_live, action, true, action_count);

    const top = buffers.nodes[visible_turns.len + action_count ..][0..5];
    top[0] = tree.card(.{ .id = NodeIds.header, .style = fixed(m.header_h, m.gap), .variant = .raised, .paint = .{}, .overflow = .clip }, &.{});
    top[1] = tree.card(.{ .id = NodeIds.metadata, .style = fixed(m.metadata_h, m.gap), .variant = .surface, .paint = .{}, .overflow = .clip }, &.{});
    top[2] = tree.card(.{ .id = NodeIds.section, .style = fixed(m.section_h, m.gap), .variant = .surface, .paint = .{}, .overflow = .clip }, &.{});
    top[3] = tree.container(.{ .id = NodeIds.content, .style = .{ .width = .{ .percent = 1 }, .height = .{ .fill = 1 } }, .overflow = .clip }, turns);
    top[4] = tree.container(.{
        .id = NodeIds.actions,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.actions_h) }, .gap = @floatFromInt(m.gap) },
        .direction = .row,
        .overflow = .clip,
    }, action_nodes);
    const root = tree.container(.{
        .id = NodeIds.root,
        .style = .{ .padding = .{ .top = @floatFromInt(m.pad), .right = @floatFromInt(m.pad), .bottom = @floatFromInt(m.pad), .left = @floatFromInt(m.pad) } },
        .overflow = .clip,
    }, top);
    const built = try tree.build(root, .{ .root_size = props.viewport_px, .max_entries = needed_nodes + 1, .max_depth = 3 }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    return .{ .tree = .{ .entries = buffers.entries[0..built.entries.len] }, .actions = table.slice() };
}

fn fixed(height: u32, bottom: u32) layout.UiStyle {
    return .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(height) }, .margin = .{ .bottom = @floatFromInt(bottom) } };
}

fn actionNode(id: u64, action: tree.UiAction, enabled: bool, action_count: usize) tree.UiNode {
    return tree.card(.{
        .id = id,
        // `UiNode` validates a card both as its row child and as an independently composable
        // node. A definite percent share therefore keeps all action cards materialized instead
        // of relying on a row-only `.fill` interpretation.
        .style = .{ .width = .{ .percent = 1.0 / @as(f32, @floatFromInt(action_count)) }, .height = .{ .percent = 1 } },
        .variant = if (enabled) .selected else .surface,
        .paint = .{},
        .action = .{ .id = action.id, .enabled = enabled },
        .overflow = .clip,
    }, &.{});
}

test "archive detail action identities disable stale source effects and omit absent live navigation" {
    const stale_turns = [_]types.Turn{
        .{ .role = .assistant, .text = "must not be republished" },
        .{ .role = .assistant, .text = "ignored beyond the ready cap" },
        .{ .role = .assistant, .text = "still ignored" },
        .{ .role = .assistant, .text = "must not fail the stale shell" },
    };
    const props = types.Props{ .viewport_px = .{ .width = 320, .height = 480 }, .cell_width_px = 8, .cell_height_px = 16, .snapshot_generation = 7, .state = .stale, .provider = .codex, .title = "title", .metadata = "metadata", .turns = &stale_turns, .focus_live_enabled = true };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [9]tree.RectEntry = undefined;
    var items: [9]layout.Item = undefined;
    var scratch: [9]layout.FlexScratch = undefined;
    var rects: [9]layout.UiRect = undefined;
    var actions: [3]ids.Entry = undefined;
    const frame = try build(props, .{ .nodes = &nodes, .entries = &entries, .layout_items = &items, .flex_scratch = &scratch, .child_rects = &rects, .actions = &actions });
    try @import("std").testing.expect(frame.tree.find(NodeIds.focus_live) == null);
    try @import("std").testing.expect(frame.tree.find(NodeIds.turn(0)) == null);
    const resume_entry = frame.tree.entries[frame.tree.find(NodeIds.resume_session).?];
    try @import("std").testing.expect(!resume_entry.action.?.enabled);
    var table = ids.Table.init(@constCast(frame.actions));
    table.count = frame.actions.len;
    try @import("std").testing.expect(table.resolve(1, 7) == null);
}
