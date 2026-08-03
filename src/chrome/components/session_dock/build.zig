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
    // Every projected list item gets an eight-id lane.  A closed card uses `item`; an expanded
    // card turns that same id into a container and puts its visible title/action rect in
    // `card_header`.  This keeps a stable archive item's node ids independent of virtualization.
    pub const item_base: u64 = 0x5344_1000;
    const item_stride: u64 = 8;

    pub fn item(index: usize) u64 {
        return item_base + @as(u64, @intCast(index)) * item_stride;
    }

    pub fn cardHeader(index: usize) u64 {
        return item(index) + 1;
    }

    pub fn expandedDetail(index: usize) u64 {
        return item(index) + 2;
    }

    pub fn expandedActions(index: usize) u64 {
        return item(index) + 3;
    }

    pub fn resumeAction(index: usize) u64 {
        return item(index) + 4;
    }

    pub fn reveal(index: usize) u64 {
        return item(index) + 5;
    }

    pub fn focusLive(index: usize) u64 {
        return item(index) + 6;
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

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer, TooManyTurns };

/// Builds a column whose text is emitted later from the resulting rect tree. Every interactive
/// rectangle belongs to this one candidate tree: no platform y-row arithmetic is allowed to make
/// a second hit region for scopes/groups/cards.
pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    var expanded_extra_nodes: usize = 0;
    for (props.items) |item| switch (item) {
        .group => {},
        .card => |card| if (card.expanded != null) {
            if (card.expanded.?.turns.len > 3) return error.TooManyTurns;
            // header + detail + action-row + resume/reveal, plus optional focus-live
            expanded_extra_nodes += 5 + @as(usize, @intFromBool(card.expanded.?.focus_live_enabled));
        },
    };
    const needed_nodes = props.items.len + expanded_extra_nodes + 7; // item roots + nested expansion + 3 scopes + header/scope-row/search/content
    if (buffers.nodes.len < needed_nodes) return error.InsufficientNodeBuffer;

    const m = types.DockMetrics.resolve(props.scale_milli);
    var table = ids.Table.init(buffers.actions);
    const refresh = table.append(props.snapshot_generation, .refresh) catch return error.InsufficientActionBuffer;
    const workspace = table.append(props.snapshot_generation, .{ .scope = .workspace }) catch return error.InsufficientActionBuffer;
    const project = table.append(props.snapshot_generation, .{ .scope = .project }) catch return error.InsufficientActionBuffer;
    const all = table.append(props.snapshot_generation, .{ .scope = .all }) catch return error.InsufficientActionBuffer;
    const search = table.append(props.snapshot_generation, .focus_search) catch return error.InsufficientActionBuffer;

    // Children are stored first, then parent slices borrow these stable ranges. `UiNode` is a
    // value tree, so this avoids heap allocation and makes the buffer cap part of the contract.
    const item_nodes = buffers.nodes[0..props.items.len];
    var nested_cursor: usize = props.items.len;
    for (props.items, item_nodes, 0..) |item, *node, index| {
        switch (item) {
            .group => |group| {
                const action = table.append(props.snapshot_generation, .{ .toggle_group = group.identity }) catch return error.InsufficientActionBuffer;
                node.* = tree.card(.{
                    .id = NodeIds.item(index),
                    .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.group_h) }, .margin = .{ .bottom = @floatFromInt(m.item_gap) } },
                    .variant = .surface,
                    .paint = dividedRowPaint(),
                    .action = action,
                    .overflow = .clip,
                }, &.{});
            },
            .card => |card| {
                const select = table.append(props.snapshot_generation, .{ .select_card = card.identity }) catch return error.InsufficientActionBuffer;
                if (card.expanded) |expanded| {
                    const action_count: usize = 2 + @as(usize, @intFromBool(expanded.focus_live_enabled));
                    const nested = buffers.nodes[nested_cursor .. nested_cursor + 3 + action_count];
                    nested_cursor += nested.len;
                    nested[0] = sessionCardNode(NodeIds.cardHeader(index), select, card.selected, m.card_h);
                    nested[1] = tree.card(.{
                        .id = NodeIds.expandedDetail(index),
                        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.expanded_detail_h) } },
                        .variant = .raised,
                        .paint = .{},
                        .overflow = .clip,
                    }, &.{});
                    const action_nodes = nested[3..][0..action_count];
                    const resume_action = table.append(props.snapshot_generation, .resume_session) catch return error.InsufficientActionBuffer;
                    const reveal = table.append(props.snapshot_generation, .reveal_log) catch return error.InsufficientActionBuffer;
                    const action_width = expansionActionWidth(props.viewport_px.width, m, action_count);
                    action_nodes[0] = expansionActionNode(NodeIds.resumeAction(index), resume_action, expanded.state == .ready and expanded.resume_enabled, .primary, action_width);
                    action_nodes[1] = expansionActionNode(NodeIds.reveal(index), reveal, expanded.state == .ready and expanded.reveal_enabled, .secondary, action_width);
                    if (expanded.focus_live_enabled) {
                        const focus = table.append(props.snapshot_generation, .focus_live) catch return error.InsufficientActionBuffer;
                        action_nodes[2] = expansionActionNode(NodeIds.focusLive(index), focus, expanded.state == .ready, .secondary, action_width);
                    }
                    nested[2] = tree.container(.{
                        .id = NodeIds.expandedActions(index),
                        // Buttons divide the remaining main-axis width after this explicit gap;
                        // percentage widths would add the gap on top and overflow the published clip.
                        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.expanded_actions_h) }, .gap = @floatFromInt(m.action_gap) },
                        .direction = .row,
                        .overflow = .clip,
                    }, action_nodes);
                    node.* = tree.container(.{
                        .id = NodeIds.item(index),
                        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.card_h + m.expanded_detail_h + m.expanded_actions_h) }, .margin = .{ .bottom = @floatFromInt(m.item_gap) } },
                        .overflow = .clip,
                    }, nested[0..3]);
                } else {
                    node.* = sessionCardNode(NodeIds.item(index), select, card.selected, m.card_h);
                }
            },
        }
    }

    const scope_nodes = buffers.nodes[nested_cursor..][0..3];
    scope_nodes[0] = scopeNode(NodeIds.scope_workspace, workspace, props.workspace_scope_enabled, props.scope == .workspace);
    scope_nodes[1] = scopeNode(NodeIds.scope_project, project, props.project_scope_enabled, props.scope == .project);
    scope_nodes[2] = scopeNode(NodeIds.scope_all, all, true, props.scope == .all);

    const top = buffers.nodes[nested_cursor + 3 ..][0..4];
    top[0] = tree.card(.{
        .id = NodeIds.header,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.header_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap) } },
        // Header text has no enclosing card in the dock reference. It remains a Card only so
        // refresh retains one completed action rect, while its base/background border is hidden.
        .variant = .surface,
        .paint = .{ .background = .surface_bg, .border = .surface_bg, .shadow = .none },
        .action = refresh,
        .overflow = .clip,
    }, &.{});
    top[1] = tree.card(.{
        .id = NodeIds.scope_row,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.scope_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap) }, .gap = @floatFromInt(m.item_gap) },
        .direction = .row,
        .variant = .surface,
        // The segmented control is one outlined surface. Child scope cards paint only their
        // selected state, so the inactive thirds do not turn into three unrelated buttons.
        .paint = .{ .border = .divider },
        .overflow = .clip,
    }, scope_nodes);
    top[2] = tree.card(.{
        .id = NodeIds.search,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(m.search_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap) } },
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
        // All dock layers share this bounded content rect. Keeping the clipping boundary here
        // prevents a fixed chrome width from overflowing after margins are applied and keeps
        // list dividers on the same logical edge as the header/search controls.
        .style = .{ .padding = .{ .top = @floatFromInt(m.root_inset), .right = @floatFromInt(m.root_inset), .bottom = @floatFromInt(m.root_inset), .left = @floatFromInt(m.root_inset) } },
        .overflow = .clip,
    }, top);
    const built = try tree.build(root, .{
        .root_size = props.viewport_px,
        .max_entries = needed_nodes + 1,
        // ExpandedSessionCard adds `root → content → expanded item → action row → action`.
        // Keep this explicit so a later accidental wrapper cannot silently grow the published
        // interaction tree without a bounded-cap review.
        .max_depth = 5,
    }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    // Virtualization starts at the first partially-visible item. Shift only those direct content
    // children after the generic tree has established the one shared content clip; this avoids a
    // parallel host-only y calculation for paint or hit testing.
    if (props.content_first_item_origin_y_px != 0) {
        const content_index = built.find(NodeIds.content) orelse return error.InsufficientNodeBuffer;
        const origin: f32 = @floatFromInt(props.content_first_item_origin_y_px);
        const content_clip = buffers.entries[content_index].effective_clip orelse buffers.entries[content_index].rect;
        for (buffers.entries[0..built.entries.len]) |*entry| {
            if (entry.parent_index != null and entry.parent_index.? == content_index) {
                entry.rect.y += origin;
                // `tree.build` calculated this child's clip before the virtualization translation.
                // Re-intersect against the immutable content clip here so card paint and hit test
                // observe the exact same visible partial rectangle.
                entry.effective_clip = intersect(entry.rect, content_clip);
            }
        }
    }
    return .{ .tree = .{ .entries = buffers.entries[0..built.entries.len] }, .actions = table.slice() };
}

fn intersect(a: layout.UiRect, b: layout.UiRect) layout.UiRect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = @max(right - left, 0), .height = @max(bottom - top, 0) };
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

fn sessionCardNode(id: u64, action: tree.UiAction, selected: bool, height: u32) tree.UiNode {
    return tree.card(.{
        .id = id,
        .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = @floatFromInt(height) } },
        .variant = if (selected) .selected else .surface,
        .paint = dividedRowPaint(),
        .action = action,
        .overflow = .clip,
    }, &.{});
}

fn expansionActionNode(id: u64, action: tree.UiAction, enabled: bool, variant: tree.ButtonVariant, width_px: f32) tree.UiNode {
    return tree.button(.{
        .id = id,
        .style = .{ .width = .{ .px = width_px }, .height = .{ .percent = 1 } },
        .variant = variant,
        .action = .{ .id = action.id, .enabled = enabled },
        .overflow = .clip,
    });
}

/// Action cards are leaf nodes, so their own validation cannot use main-axis `fill`: a leaf
/// defaults to a column container and correctly rejects cross-axis fill. The shared dock content
/// width is already definite when we build its one published tree, therefore divide that exact
/// width after the explicit gaps instead of weakening the generic layout invariant.
fn expansionActionWidth(viewport_width_px: f32, m: types.DockMetrics, action_count: usize) f32 {
    if (action_count == 0) return 0;
    const content_width = @max(viewport_width_px - @as(f32, @floatFromInt(m.root_inset * 2)), 0);
    const total_gap = @as(f32, @floatFromInt(m.action_gap * @as(u32, @intCast(action_count - 1))));
    return @max((content_width - total_gap) / @as(f32, @floatFromInt(action_count)), 0);
}

test "expanded action widths leave the declared gap for two and three actions" {
    const m = types.DockMetrics.resolve(1000);
    // The shared content rect owns its width; only the action gap is removed before equal
    // division for resume/reveal and the optional live-focus third action.
    try @import("std").testing.expectEqual(@as(f32, 216), expansionActionWidth(480, m, 2));
    try @import("std").testing.expectApproxEqAbs(@as(f32, 141.33333), expansionActionWidth(480, m, 3), 0.0001);
    // An ultra-narrow viewport still cannot underflow or create a negative leaf width.
    try @import("std").testing.expectEqual(@as(f32, 0), expansionActionWidth(40, m, 2));
}

fn dividedRowPaint() tree.PaintStyle {
    return .{
        .border = .divider,
        .corner_radii_px = .{ 0, 0, 0, 0 },
        .border_widths_px = .{ 0, 0, 1, 0 },
    };
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
            .{ .card = .{ .identity = 12, .provider = .codex, .title = "title", .summary = "summary", .metadata = "meta", .selected = true } },
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
    const card_visual = switch (frame.tree.entries[card_index].visual) {
        .card => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try @import("std").testing.expectEqual(tree.CardVariant.selected, card_visual.variant);
    // Divider styling must not replace the selected variant's background token.
    try @import("std").testing.expect(card_visual.paint.background == null);
    try @import("std").testing.expectEqual(@as(?[4]u16, .{ 0, 0, 1, 0 }), card_visual.paint.border_widths_px);
    var table = ids.Table.init(@constCast(frame.actions));
    table.count = frame.actions.len;
    try @import("std").testing.expectEqual(@as(?ids.Intent, .{ .select_card = 12 }), table.resolve(7, 9));
}

test "SessionDock shares one bounded content rect while group disclosure avoids double inset" {
    const props = types.Props{
        .viewport_px = .{ .width = 480, .height = 720 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 23,
        .displayed_count = 1,
        .items = &.{.{ .group = .{ .identity = 11, .label = "tmp", .count = 1 } }},
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [9]tree.RectEntry = undefined;
    var layout_items: [9]layout.Item = undefined;
    var flex_scratch: [9]layout.FlexScratch = undefined;
    var child_rects: [9]layout.UiRect = undefined;
    var actions: [8]ids.Entry = undefined;
    const frame = try build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const m = types.DockMetrics.resolve(props.scale_milli);
    const header = frame.tree.entries[frame.tree.find(NodeIds.header).?];
    const scope = frame.tree.entries[frame.tree.find(NodeIds.scope_row).?];
    const search = frame.tree.entries[frame.tree.find(NodeIds.search).?];
    const content = frame.tree.entries[frame.tree.find(NodeIds.content).?];
    const group = frame.tree.entries[frame.tree.find(NodeIds.item(0)).?];
    try @import("std").testing.expectEqual(@as(f32, @floatFromInt(m.root_inset)), header.rect.x);
    try @import("std").testing.expectEqual(header.rect.x, scope.rect.x);
    try @import("std").testing.expectEqual(header.rect.x, search.rect.x);
    try @import("std").testing.expectEqual(props.viewport_px.width - @as(f32, @floatFromInt(m.root_inset * 2)), header.rect.width);
    try @import("std").testing.expectEqual(header.rect.width, scope.rect.width);
    try @import("std").testing.expectEqual(header.rect.width, search.rect.width);
    try @import("std").testing.expectEqual(header.rect.x, content.rect.x);
    try @import("std").testing.expectEqual(content.rect.x, group.rect.x);
    try @import("std").testing.expectEqual(header.rect.width, group.rect.width);
}

test "SessionDock published geometry ignores terminal cell dimensions" {
    const base_props = types.Props{
        .viewport_px = .{ .width = 640, .height = 720 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .scale_milli = 1000,
        .snapshot_generation = 11,
        .displayed_count = 1,
        .items = &.{
            .{ .group = .{ .identity = 1, .label = "workspace", .count = 1 } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "title", .summary = "summary", .metadata = "metadata", .selected = true, .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true } } },
        },
    };
    var large_font_props = base_props;
    large_font_props.cell_width_px = 21;
    large_font_props.cell_height_px = 37;

    var nodes_a: [15]tree.UiNode = undefined;
    var entries_a: [16]tree.RectEntry = undefined;
    var layout_items_a: [16]layout.Item = undefined;
    var flex_scratch_a: [16]layout.FlexScratch = undefined;
    var child_rects_a: [16]layout.UiRect = undefined;
    var actions_a: [12]ids.Entry = undefined;
    const frame_a = try build(base_props, .{
        .nodes = &nodes_a,
        .entries = &entries_a,
        .layout_items = &layout_items_a,
        .flex_scratch = &flex_scratch_a,
        .child_rects = &child_rects_a,
        .actions = &actions_a,
    });
    var nodes_b: [15]tree.UiNode = undefined;
    var entries_b: [16]tree.RectEntry = undefined;
    var layout_items_b: [16]layout.Item = undefined;
    var flex_scratch_b: [16]layout.FlexScratch = undefined;
    var child_rects_b: [16]layout.UiRect = undefined;
    var actions_b: [12]ids.Entry = undefined;
    const frame_b = try build(large_font_props, .{
        .nodes = &nodes_b,
        .entries = &entries_b,
        .layout_items = &layout_items_b,
        .flex_scratch = &flex_scratch_b,
        .child_rects = &child_rects_b,
        .actions = &actions_b,
    });
    try @import("std").testing.expectEqual(frame_a.tree.entries.len, frame_b.tree.entries.len);
    for (frame_a.tree.entries) |entry_a| {
        const index_b = frame_b.tree.find(entry_a.id) orelse return error.TestUnexpectedResult;
        try @import("std").testing.expectEqualDeep(entry_a.rect, frame_b.tree.entries[index_b].rect);
        try @import("std").testing.expectEqualDeep(entry_a.effective_clip, frame_b.tree.entries[index_b].effective_clip);
    }
}

test "SessionDock partial item keeps one content clip for paint and hit testing" {
    const props = types.Props{
        .viewport_px = .{ .width = 320, .height = 240 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 9,
        .displayed_count = 2,
        .content_first_item_origin_y_px = -20,
        .items = &.{
            .{ .card = .{ .identity = 12, .provider = .codex, .title = "title", .summary = "summary", .metadata = "meta" } },
            .{ .card = .{ .identity = 13, .provider = .claude, .title = "next", .summary = "summary", .metadata = "meta" } },
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
    const content = frame.tree.entries[frame.tree.find(NodeIds.content).?];
    const first = frame.tree.entries[frame.tree.find(NodeIds.item(0)).?];
    try @import("std").testing.expect(first.rect.y < content.rect.y);
    try @import("std").testing.expect(first.effective_clip != null);
    const clip = first.effective_clip.?;
    try @import("std").testing.expectEqual(content.rect.y, clip.y);
    try @import("std").testing.expect(clip.height <= content.rect.height);
}

test "SessionDock expanded card keeps detail actions in the same published tree" {
    const props = types.Props{
        .viewport_px = .{ .width = 480, .height = 720 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 21,
        .displayed_count = 1,
        .expanded_identity = 12,
        .items = &.{.{ .card = .{
            .identity = 12,
            .provider = .claude,
            .title = "title",
            .summary = "summary",
            .metadata = "metadata",
            .selected = true,
            .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true },
        } }},
    };
    var nodes: [13]tree.UiNode = undefined;
    var entries: [14]tree.RectEntry = undefined;
    var layout_items: [14]layout.Item = undefined;
    var flex_scratch: [14]layout.FlexScratch = undefined;
    var child_rects: [14]layout.UiRect = undefined;
    var actions: [8]ids.Entry = undefined;
    const frame = try build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const outer = frame.tree.entries[frame.tree.find(NodeIds.item(0)).?];
    const header = frame.tree.entries[frame.tree.find(NodeIds.cardHeader(0)).?];
    const detail = frame.tree.entries[frame.tree.find(NodeIds.expandedDetail(0)).?];
    const resume_entry = frame.tree.entries[frame.tree.find(NodeIds.resumeAction(0)).?];
    const reveal = frame.tree.entries[frame.tree.find(NodeIds.reveal(0)).?];
    try @import("std").testing.expectEqual(outer.rect.x, header.rect.x);
    try @import("std").testing.expect(header.rect.y < detail.rect.y);
    try @import("std").testing.expect(detail.rect.y < resume_entry.rect.y);
    // The two leaf cards share the content width only after their explicit action gap. This
    // locks the visual separation to the same rects used by pointer hit testing.
    try @import("std").testing.expectEqual(@as(f32, 8), reveal.rect.x - (resume_entry.rect.x + resume_entry.rect.width));
    try @import("std").testing.expectEqual(resume_entry.rect.width, reveal.rect.width);
    try @import("std").testing.expectEqual(tree.NodeKind.button, resume_entry.kind);
    try @import("std").testing.expectEqual(tree.NodeKind.button, reveal.kind);
    // Command target height comes from logical Chrome metrics, not the 16px terminal row that
    // happens to be used by this fixture.
    try @import("std").testing.expectEqual(@as(f32, @floatFromInt(types.ButtonMetrics.resolve(props.scale_milli).minimum_height_px)), resume_entry.rect.height);
    try @import("std").testing.expectEqual(resume_entry.rect.height, reveal.rect.height);
    try @import("std").testing.expectEqual(tree.VisualProps{ .button = .{ .variant = .primary, .paint = .{} } }, resume_entry.visual);
    try @import("std").testing.expectEqual(tree.VisualProps{ .button = .{ .variant = .secondary, .paint = .{} } }, reveal.visual);
    try @import("std").testing.expect(resume_entry.action.?.enabled);
    try @import("std").testing.expect(reveal.action.?.enabled);
    var table = ids.Table.init(@constCast(frame.actions));
    table.count = frame.actions.len;
    try @import("std").testing.expectEqual(@as(?ids.Intent, .resume_session), table.resolve(resume_entry.action.?.id, 21));
    try @import("std").testing.expectEqual(@as(?ids.Intent, .reveal_log), table.resolve(reveal.action.?.id, 21));
}
