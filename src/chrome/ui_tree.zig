//! 중첩 native chrome component tree를 ML1 flex solver의 한 sibling line으로 내리는 순수 seam이다.
//!
//! 이 모듈은 TUI cell/ANSI, Metal draw, `ChromeHost` effect dispatch를 읽지 않는다. caller가 준
//! backing-pixel root size와 bounded frame buffers만 써서 `UiNode`를 flat `UiRectTree`로 만든다.
//! draw/hit/focus/virtualization은 이 tree를 공유해야 하며, caller는 성공한 tree만 publish한다.
//! 단일 출처: docs/metal-ui-layout.md §2, §5, §8 ML2a.

const std = @import("std");
const layout = @import("layout.zig");

pub const UiId = u64;
pub const UiActionId = u64;

pub const UiAction = struct {
    id: UiActionId,
    enabled: bool = true,
};

pub const ContainerOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    justify: layout.Justify = .start,
    align_items: layout.Align = .stretch,
    overflow: layout.Overflow = .visible,
};

pub const CardOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    action: ?UiAction = null,
    direction: layout.Direction = .column,
    justify: layout.Justify = .start,
    align_items: layout.Align = .stretch,
    overflow: layout.Overflow = .visible,
};

pub const TextOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    value: []const u8,
    measure_context: ?*const anyopaque = null,
    measure: ?layout.MeasureFn = null,
};

pub const NodeProps = union(enum) {
    column: struct {
        justify: layout.Justify,
        align_items: layout.Align,
        overflow: layout.Overflow,
    },
    row: struct {
        justify: layout.Justify,
        align_items: layout.Align,
        overflow: layout.Overflow,
    },
    card: struct {
        action: ?UiAction,
        direction: layout.Direction,
        justify: layout.Justify,
        align_items: layout.Align,
        overflow: layout.Overflow,
    },
    text: struct {
        value: []const u8,
        measure_context: ?*const anyopaque,
        measure: ?layout.MeasureFn,
    },
};

pub const NodeKind = enum { column, row, card, text };

/// children slice의 수명과 순서는 builder caller가 소유한다. node address나 형제 index는
/// identity가 아니며, 한 build 안에 같은 `id`가 있으면 `DuplicateIdentity`로 끝난다.
pub const UiNode = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    props: NodeProps,
    children: []const UiNode = &.{},

    pub fn kind(self: UiNode) NodeKind {
        return switch (self.props) {
            .column => .column,
            .row => .row,
            .card => .card,
            .text => .text,
        };
    }
};

pub fn column(options: ContainerOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .column = .{
            .justify = options.justify,
            .align_items = options.align_items,
            .overflow = options.overflow,
        } },
        .children = children,
    };
}

pub fn row(options: ContainerOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .row = .{
            .justify = options.justify,
            .align_items = options.align_items,
            .overflow = options.overflow,
        } },
        .children = children,
    };
}

pub fn card(options: CardOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .card = .{
            .action = options.action,
            .direction = options.direction,
            .justify = options.justify,
            .align_items = options.align_items,
            .overflow = options.overflow,
        } },
        .children = children,
    };
}

pub fn text(options: TextOptions) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .text = .{
            .value = options.value,
            .measure_context = options.measure_context,
            .measure = options.measure,
        } },
    };
}

pub const RectEntry = struct {
    id: UiId,
    parent_index: ?usize,
    kind: NodeKind,
    rect: layout.UiRect,
    /// Parent overflow clip과 own overflow clip을 교차한 backing-pixel rect다. null은
    /// 이 entry와 모든 visible ancestor가 clip하지 않는다는 뜻이다.
    effective_clip: ?layout.UiRect,
    action: ?UiAction,
};

/// entries는 preorder라 parent는 항상 child보다 먼저 나온다. direct child 탐색에는
/// `parent_index`를 쓰며, subtree 전체는 다음 sibling parent boundary까지의 range다.
pub const UiRectTree = struct {
    entries: []const RectEntry,

    pub fn find(self: UiRectTree, id: UiId) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }
};

pub const BuildOptions = struct {
    root_size: layout.UiSize,
    /// root를 포함한다. zero는 invalid이며 partial publish를 허용하지 않는다.
    max_entries: usize,
    /// root depth=1 기준이다. zero는 invalid이다.
    max_depth: usize,
};

/// 모든 슬라이스는 caller frame arena가 소유하는 *candidate* tree다. 이전 completed tree를
/// 유지하려면 published snapshot과 이 버퍼를 공유하지 않는다. 세 scratch 슬라이스는
/// `max_entries` 이상이어야 한다. `items`/`flex_scratch`는 child flex 계산이 끝나면
/// level마다 재사용하고, `child_rects`만은 활성 조상 sibling을 보존하도록 stack range로
/// 예약한다. 이 방식은 tree build가 heap allocation이나 component-local rect cache를 만들지
/// 못하게 한다.
pub const BuildBuffers = struct {
    entries: []RectEntry,
    items: []layout.Item,
    flex_scratch: []layout.FlexScratch,
    child_rects: []layout.UiRect,
};

pub const BuildError = layout.LayoutError || error{
    InvalidLimit,
    InsufficientBuffer,
    MaxEntriesExceeded,
    MaxDepthExceeded,
    DuplicateIdentity,
    LeafHasChildren,
    RootOuterStyle,
    RebuildCounterOverflow,
};

/// `ChromeHost`가 props/style/size dirty일 때만 호출하는 completed-build 계수다. 실패한
/// build는 tree publish와 이 counter 둘 다 바꾸지 않는다.
pub const RebuildCounter = struct {
    completed: u64 = 0,

    pub fn rebuild(self: *RebuildCounter, root: UiNode, options: BuildOptions, buffers: BuildBuffers) BuildError!UiRectTree {
        if (self.completed == std.math.maxInt(u64)) {
            clearEntries(buffers.entries);
            return error.RebuildCounterOverflow;
        }
        const tree = try build(root, options, buffers);
        self.completed += 1;
        return tree;
    }
};

/// 성공했을 때만 caller가 반환 tree를 publish한다. 실패 시 new-frame entries를 모두
/// zero로 지워 stale rect/action을 실수로 재사용하지 않게 한다.
pub fn build(root: UiNode, options: BuildOptions, buffers: BuildBuffers) BuildError!UiRectTree {
    clearEntries(buffers.entries);
    try validateBuildInputs(options, buffers);

    var state = BuildState{ .options = options, .buffers = buffers };
    errdefer clearEntries(buffers.entries);
    try state.appendSubtree(root, null, .{
        .x = 0,
        .y = 0,
        .width = options.root_size.width,
        .height = options.root_size.height,
    }, null, 1, 0);
    return .{ .entries = buffers.entries[0..state.entry_count] };
}

const BuildState = struct {
    options: BuildOptions,
    buffers: BuildBuffers,
    entry_count: usize = 0,

    fn appendSubtree(
        self: *BuildState,
        node: UiNode,
        parent_index: ?usize,
        rect: layout.UiRect,
        parent_clip: ?layout.UiRect,
        depth: usize,
        rect_stack_start: usize,
    ) BuildError!void {
        if (depth > self.options.max_depth) return error.MaxDepthExceeded;
        if (self.entry_count == self.options.max_entries) return error.MaxEntriesExceeded;
        if (hasIdentity(self.buffers.entries[0..self.entry_count], node.id)) return error.DuplicateIdentity;
        if (node.kind() == .text and node.children.len != 0) return error.LeafHasChildren;
        if (parent_index == null) try validateRootOuterStyle(node.style);
        if (node.children.len > self.options.max_entries - self.entry_count - 1) return error.MaxEntriesExceeded;

        const container = try containerFor(node, rect);
        const child_count = node.children.len;
        const child_items = self.buffers.items[0..child_count];
        const child_scratch = self.buffers.flex_scratch[0..child_count];
        if (rect_stack_start > self.buffers.child_rects.len or
            child_count > self.buffers.child_rects.len - rect_stack_start) return error.MaxEntriesExceeded;
        const child_rects = self.buffers.child_rects[rect_stack_start..][0..child_count];
        for (node.children, child_items) |child, *item| item.* = itemFor(child);
        const result = try layout.layoutFlex(container, child_items, child_scratch, child_rects);

        const own_clip = if (result.clip_rect) |content_rect|
            try offsetRect(content_rect, rect.x, rect.y)
        else
            null;
        const effective_clip = try intersectClip(parent_clip, own_clip);
        const own_index = self.entry_count;
        self.buffers.entries[own_index] = .{
            .id = node.id,
            .parent_index = parent_index,
            .kind = node.kind(),
            .rect = rect,
            .effective_clip = effective_clip,
            .action = actionFor(node),
        };
        self.entry_count += 1;

        for (node.children, child_rects) |child, child_rect| {
            try self.appendSubtree(child, own_index, try offsetRect(child_rect, rect.x, rect.y), effective_clip, depth + 1, rect_stack_start + child_count);
        }
    }
};

fn validateBuildInputs(options: BuildOptions, buffers: BuildBuffers) BuildError!void {
    if (options.max_entries == 0 or options.max_depth == 0) return error.InvalidLimit;
    if (buffers.entries.len < options.max_entries or
        buffers.items.len < options.max_entries or
        buffers.flex_scratch.len < options.max_entries or
        buffers.child_rects.len < options.max_entries) return error.InsufficientBuffer;
    if (!std.math.isFinite(options.root_size.width) or !std.math.isFinite(options.root_size.height) or
        options.root_size.width < 0 or options.root_size.height < 0) return error.InvalidNumber;
}

fn validateRootOuterStyle(style: layout.UiStyle) BuildError!void {
    if (!isAuto(style.width) or !isAuto(style.height) or
        style.min_width != null or style.max_width != null or
        style.min_height != null or style.max_height != null or
        style.margin.top != 0 or style.margin.right != 0 or
        style.margin.bottom != 0 or style.margin.left != 0 or
        style.flex.grow != 0 or style.flex.shrink != 1 or style.flex.basis != null or
        style.align_self != null) return error.RootOuterStyle;
}

fn isAuto(length: layout.UiLength) bool {
    return switch (length) {
        .auto => true,
        else => false,
    };
}

fn containerFor(node: UiNode, rect: layout.UiRect) BuildError!layout.FlexContainer {
    const container: layout.FlexContainer = switch (node.props) {
        .column => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = .column,
            .justify = value.justify,
            .align_items = value.align_items,
            .overflow = value.overflow,
        },
        .row => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = .row,
            .justify = value.justify,
            .align_items = value.align_items,
            .overflow = value.overflow,
        },
        .card => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = value.direction,
            .justify = value.justify,
            .align_items = value.align_items,
            .overflow = value.overflow,
        },
        .text => .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = .column,
        },
    };
    try layout.validateItemStyle(node.style, container.direction);
    return container;
}

fn itemFor(node: UiNode) layout.Item {
    return switch (node.props) {
        .text => |value| .{
            .style = node.style,
            .measure_context = value.measure_context,
            .measure = value.measure,
        },
        else => .{ .style = node.style },
    };
}

fn actionFor(node: UiNode) ?UiAction {
    return switch (node.props) {
        .card => |value| value.action,
        else => null,
    };
}

fn hasIdentity(entries: []const RectEntry, id: UiId) bool {
    for (entries) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

fn offsetRect(rect: layout.UiRect, x: f32, y: f32) BuildError!layout.UiRect {
    const result: layout.UiRect = .{
        .x = x + rect.x,
        .y = y + rect.y,
        .width = rect.width,
        .height = rect.height,
    };
    try validateRect(result);
    return result;
}

fn intersectClip(parent: ?layout.UiRect, own: ?layout.UiRect) BuildError!?layout.UiRect {
    if (parent == null) return own;
    if (own == null) return parent;
    const left = @max(parent.?.x, own.?.x);
    const top = @max(parent.?.y, own.?.y);
    const right = @min(parent.?.x + parent.?.width, own.?.x + own.?.width);
    const bottom = @min(parent.?.y + parent.?.height, own.?.y + own.?.height);
    const result: layout.UiRect = .{
        .x = left,
        .y = top,
        .width = @max(0, right - left),
        .height = @max(0, bottom - top),
    };
    try validateRect(result);
    return result;
}

fn validateRect(rect: layout.UiRect) BuildError!void {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidNumber;
    if (rect.width < 0 or rect.height < 0) return error.NegativeValue;
}

fn clearEntries(entries: []RectEntry) void {
    for (entries) |*entry| entry.* = std.mem.zeroes(RectEntry);
}

fn measuredText(_: ?*const anyopaque, _: layout.MeasureConstraint) layout.UiSize {
    return .{ .width = 20, .height = 10 };
}

test "nested UiNode produces one preorder rect tree for cards and text" {
    const root = column(.{ .id = 1, .style = .{ .padding = .{ .top = 4, .left = 3 }, .gap = 2 }, .overflow = .clip }, &.{
        card(.{ .id = 2, .style = .{ .height = .{ .px = 24 }, .padding = .{ .left = 2 } }, .action = .{ .id = 90 } }, &.{
            text(.{ .id = 3, .value = "adsf", .measure = measuredText }),
        }),
        text(.{ .id = 4, .value = "tail", .measure = measuredText }),
    });
    var entries: [4]RectEntry = undefined;
    var items: [4]layout.Item = undefined;
    var scratch: [4]layout.FlexScratch = undefined;
    var child_rects: [4]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 100, .height = 80 }, .max_entries = 4, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectEqual(@as(usize, 4), tree.entries.len);
    try std.testing.expectEqual(@as(?usize, null), tree.entries[0].parent_index);
    try std.testing.expectEqual(@as(?usize, 0), tree.entries[1].parent_index);
    try std.testing.expectEqual(@as(?usize, 1), tree.entries[2].parent_index);
    try std.testing.expectEqual(@as(?usize, 0), tree.entries[3].parent_index);
    try std.testing.expectEqual(NodeKind.card, tree.entries[1].kind);
    try std.testing.expectEqual(@as(?UiAction, .{ .id = 90, .enabled = true }), tree.entries[1].action);
    try std.testing.expectApproxEqAbs(@as(f32, 3), tree.entries[1].rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), tree.entries[1].rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), tree.entries[1].rect.height, 0.001);
    try std.testing.expect(tree.entries[2].effective_clip != null);
    try std.testing.expectEqual(@as(?usize, 2), tree.find(3));
}

test "build fails closed for duplicate identity and leaves no new rect entries" {
    const root = column(.{ .id = 1 }, &.{
        text(.{ .id = 2, .value = "first" }),
        text(.{ .id = 2, .value = "duplicate" }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    try std.testing.expectError(error.DuplicateIdentity, build(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(std.mem.zeroes(RectEntry), entry);
}

test "build rejects depth, capacity, and leaf children without partial tree" {
    const nested = column(.{ .id = 1 }, &.{
        card(.{ .id = 2 }, &.{
            text(.{ .id = 3, .value = "deep" }),
        }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const buffers: BuildBuffers = .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    };
    try std.testing.expectError(error.MaxDepthExceeded, build(nested, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));
    try std.testing.expectError(error.MaxEntriesExceeded, build(nested, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 2, .max_depth = 3 }, buffers));

    const invalid_leaf = UiNode{
        .id = 8,
        .props = .{ .text = .{ .value = "leaf", .measure_context = null, .measure = null } },
        .children = &.{text(.{ .id = 9, .value = "child" })},
    };
    try std.testing.expectError(error.LeafHasChildren, build(invalid_leaf, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));

    const invalid_root = column(.{ .id = 10, .style = .{ .width = .{ .px = 10 } } }, &.{});
    try std.testing.expectError(error.RootOuterStyle, build(invalid_root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));

    const invalid_root_padding = column(.{ .id = 11, .style = .{ .padding = .{ .left = -1 } } }, &.{});
    try std.testing.expectError(error.NegativeValue, build(invalid_root_padding, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));
}

test "nested overflow clips intersect and row children use parent rect origin" {
    const root = row(.{ .id = 1, .style = .{ .padding = .{ .left = 5 }, .gap = 3 }, .overflow = .clip }, &.{
        card(.{ .id = 2, .style = .{ .width = .{ .px = 30 } }, .overflow = .clip }, &.{
            text(.{ .id = 3, .value = "clip" }),
        }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 50, .height = 20 }, .max_entries = 3, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 5), tree.entries[1].rect.x, 0.001);
    try std.testing.expect(tree.entries[1].effective_clip != null);
    try std.testing.expect(tree.entries[2].effective_clip != null);
    try std.testing.expectApproxEqAbs(tree.entries[1].effective_clip.?.x, tree.entries[2].effective_clip.?.x, 0.001);
}

test "deep first sibling cannot overwrite later parent sibling rect" {
    const root = column(.{ .id = 1, .style = .{ .gap = 2 } }, &.{
        card(.{ .id = 2, .style = .{ .height = .{ .px = 30 } } }, &.{
            text(.{ .id = 3, .value = "one", .measure = measuredText }),
            text(.{ .id = 4, .value = "two", .measure = measuredText }),
        }),
        text(.{ .id = 5, .value = "later", .measure = measuredText }),
    });
    var entries: [5]RectEntry = undefined;
    var items: [5]layout.Item = undefined;
    var scratch: [5]layout.FlexScratch = undefined;
    var child_rects: [5]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 80, .height = 80 }, .max_entries = 5, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectEqual(@as(?usize, 0), tree.entries[4].parent_index);
    try std.testing.expectApproxEqAbs(@as(f32, 32), tree.entries[4].rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), tree.entries[4].rect.height, 0.001);
}

test "nested rect offset overflow fails closed instead of publishing infinity" {
    const max = std.math.floatMax(f32);
    const root = row(.{ .id = 1 }, &.{
        card(.{
            .id = 2,
            .style = .{ .width = .{ .px = 0 }, .margin = .{ .left = max / 2 }, .padding = .{ .left = max } },
            .overflow = .clip,
        }, &.{}),
    });
    var entries: [2]RectEntry = undefined;
    var items: [2]layout.Item = undefined;
    var scratch: [2]layout.FlexScratch = undefined;
    var child_rects: [2]layout.UiRect = undefined;
    try std.testing.expectError(error.InvalidNumber, build(root, .{ .root_size = .{ .width = max, .height = 10 }, .max_entries = 2, .max_depth = 2 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(std.mem.zeroes(RectEntry), entry);
}

test "rebuild counter advances only after completed tree build" {
    const valid = text(.{ .id = 1, .value = "ready" });
    const duplicate = column(.{ .id = 2 }, &.{
        text(.{ .id = 3, .value = "one" }),
        text(.{ .id = 3, .value = "two" }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const options: BuildOptions = .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 };
    const buffers: BuildBuffers = .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    };
    var counter: RebuildCounter = .{};
    _ = try counter.rebuild(valid, options, buffers);
    try std.testing.expectEqual(@as(u64, 1), counter.completed);
    try std.testing.expectError(error.DuplicateIdentity, counter.rebuild(duplicate, options, buffers));
    try std.testing.expectEqual(@as(u64, 1), counter.completed);
}

test "active sibling scratch beyond tree cap reports max entries, not buffer failure" {
    const root = column(.{ .id = 1 }, &.{
        card(.{ .id = 2 }, &.{
            text(.{ .id = 3, .value = "one" }),
            text(.{ .id = 4, .value = "two" }),
        }),
        text(.{ .id = 5, .value = "three" }),
        text(.{ .id = 6, .value = "four" }),
    });
    var entries: [4]RectEntry = undefined;
    var items: [4]layout.Item = undefined;
    var scratch: [4]layout.FlexScratch = undefined;
    var child_rects: [4]layout.UiRect = undefined;
    try std.testing.expectError(error.MaxEntriesExceeded, build(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 4, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(std.mem.zeroes(RectEntry), entry);
}

test "rebuild counter overflow clears candidate entries before fail-close" {
    const root = text(.{ .id = 1, .value = "ready" });
    var entries: [1]RectEntry = .{.{
        .id = 99,
        .parent_index = null,
        .kind = .text,
        .rect = .{ .width = 1, .height = 1 },
        .effective_clip = null,
        .action = .{ .id = 77 },
    }};
    var items: [1]layout.Item = undefined;
    var scratch: [1]layout.FlexScratch = undefined;
    var child_rects: [1]layout.UiRect = undefined;
    var counter: RebuildCounter = .{ .completed = std.math.maxInt(u64) };
    try std.testing.expectError(error.RebuildCounterOverflow, counter.rebuild(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 1, .max_depth = 1 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    try std.testing.expectEqual(std.mem.zeroes(RectEntry), entries[0]);
}
