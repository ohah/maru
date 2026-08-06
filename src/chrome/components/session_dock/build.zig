//! Bounded Session Dock geometry and action projection.
//!
//! A caller supplies every backing slice. Failed candidates clear through `ui.tree.build`, so a
//! half-built dock can never replace the previous tree/action snapshot in the platform host.

const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const types = @import("types.zig");

/// 마지막 그룹에는 밀어내는 것이 없다. `tree`의 clamp는 이 값을 그냥 상한으로 쓴다.
const no_next_group = @import("std").math.floatMax(f32);

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

    /// Scrollbar는 목록 아이템과 달리 virtualization 평행이동을 받지 않으므로 item lane 밖의 고정
    /// id를 쓴다. track이 먼저, thumb이 나중에 발행된다(`hitAction`이 reverse z-order라 thumb이 이긴다).
    pub const scroll_track: u64 = 0x5344_0008;
    pub const scroll_thumb: u64 = 0x5344_0009;

    /// 상단에 고정된 그룹 헤더. 이것도 평행이동을 안 받으므로 item lane 밖이다. 이 헤더가 가리키는
    /// 그룹은 virtualization 창 밖일 수 있어 `item(index)`로는 부를 수 없다.
    pub const sticky_group: u64 = 0x5344_000A;
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

/// `build`가 이 items로 성공하는 데 필요한 최소 버퍼 크기다.
///
/// 이 산술은 build가 하는 것과 **같은 것**이므로 호출처가 복제하면 안 된다. 작게 잡으면 build가
/// `InsufficientNodeBuffer`로 실패하고, 호출처가 그 실패를 삼키면 도크가 통째로 멈춘다(실제로
/// 스크롤바를 추가하다 겪었다). 크게 잡으면 그 실패 조건을 테스트가 영영 못 본다.
pub const BufferSizes = struct {
    nodes: usize,
    entries: usize,
    layout_items: usize,
    flex_scratch: usize,
    child_rects: usize,
    actions: usize,
};

/// 스크롤 **텍스트**를 자를 뷰포트(published tree 좌표). 스크롤 영역에서 고정 헤더가 가리는 밴드를
/// 뺀 것이다.
///
/// 밴드를 빼는 이유는 quad와 text가 서로 다른 레이어이기 때문이다 — 나중에 그린 헤더 배경이 앞서
/// 그린 카드 글자를 덮지 못하므로, 헤더 밑을 지나는 글자는 아예 잘라 없애야 한다(draw.zig 참조).
/// 헤더 자신은 `above_scroll`이라 자기 rect로 잘려 이 밴드 안에서 살아남는다.
///
/// 헤더는 항상 뷰포트 상단이거나 그 위다(걸린 그룹은 top ≤ offset이라 자연 y가 0 이하다). 그래서
/// "위를 내린다" 하나로 세 상태가 전부 표현된다.
///
/// **host마다 다시 계산하지 않는다.** 제품 host와 Lab이 갈리면 골든이 제품과 다른 그림을 증명한다.
pub fn scrollTextViewport(published: tree.UiRectTree) ?layout.UiRect {
    const content_index = published.find(NodeIds.content) orelse return null;
    const content_rect = published.entries[content_index].rect;
    if (content_rect.width <= 0 or content_rect.height <= 0) return null;
    const band_bottom = if (published.find(NodeIds.sticky_group)) |index| blk: {
        const head = published.entries[index].rect;
        break :blk head.y + head.height;
    } else content_rect.y;
    const top = @max(content_rect.y, band_bottom);
    return .{
        .x = content_rect.x,
        .y = top,
        .width = content_rect.width,
        .height = @max(content_rect.y + content_rect.height - top, 0),
    };
}

pub fn bufferSizes(items: []const types.Item) BufferSizes {
    var expanded_nodes: usize = 0;
    var expanded_actions: usize = 0;
    for (items) |item| switch (item) {
        .group => {},
        .card => |card| if (card.expanded) |expanded| {
            expanded_nodes += 5 + @as(usize, @intFromBool(expanded.focus_live_enabled));
            expanded_actions += 2 + @as(usize, @intFromBool(expanded.focus_live_enabled));
        },
    };
    const node_count = items.len + expanded_nodes + 7;
    return .{
        .nodes = node_count,
        // +1은 root, +2는 목록이 넘칠 때 `scrollArea`가 preorder 안에서 내는 track/thumb, +1은 sticky다.
        // scratch 셋도 같은 상한을 쓴다 — `tree.build`가 `max_entries` 이상을 요구한다.
        // sticky 헤더는 `UiNode`가 아니라 `tree.build`가 내는 entry다 — 노드 버퍼는 안 늘고 여기만 는다.
        // 스크롤바와 같은 규율로 **선언 여부와 무관하게** 예약한다. 자리를 선언에 따라 늘렸다 줄였다
        // 하면 상한이 props를 따라 흔들려 host가 미리 잡아 둘 수 없다.
        .entries = node_count + 4,
        .layout_items = node_count + 4,
        .flex_scratch = node_count + 4,
        .child_rects = node_count + 4,
        // +2는 scrollbar track/thumb action, +1은 고정 헤더의 toggle_group이다.
        .actions = items.len + 8 + expanded_actions,
    };
}

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer, TooManyTurns };

/// Builds a column whose text is emitted later from the resulting rect tree. Every interactive
/// rectangle belongs to this one candidate tree: no platform y-row arithmetic is allowed to make
/// a second hit region for scopes/groups/cards.
pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    for (props.items) |item| switch (item) {
        .group => {},
        .card => |card| if (card.expanded) |expanded| {
            if (expanded.turns.len > 3) return error.TooManyTurns;
        },
    };
    // item roots + nested expansion + 3 scopes + header/scope-row/search/content.
    const needed_nodes = bufferSizes(props.items).nodes;
    if (buffers.nodes.len < needed_nodes) return error.InsufficientNodeBuffer;

    const m = types.DockMetrics.resolve(props.scale_milli);
    var table = ids.Table.init(buffers.actions);
    const refresh = table.append(props.snapshot_generation, .refresh, true) catch return error.InsufficientActionBuffer;
    const workspace = table.append(props.snapshot_generation, .{ .scope = .workspace }, true) catch return error.InsufficientActionBuffer;
    const project = table.append(props.snapshot_generation, .{ .scope = .project }, true) catch return error.InsufficientActionBuffer;
    const all = table.append(props.snapshot_generation, .{ .scope = .all }, true) catch return error.InsufficientActionBuffer;
    const search = table.append(props.snapshot_generation, .focus_search, true) catch return error.InsufficientActionBuffer;

    // Children are stored first, then parent slices borrow these stable ranges. `UiNode` is a
    // value tree, so this avoids heap allocation and makes the buffer cap part of the contract.
    const item_nodes = buffers.nodes[0..props.items.len];
    var nested_cursor: usize = props.items.len;
    for (props.items, item_nodes, 0..) |item, *node, index| {
        switch (item) {
            .group => |group| {
                const action = table.append(props.snapshot_generation, .{ .toggle_group = group.identity }, true) catch return error.InsufficientActionBuffer;
                node.* = tree.card(.{
                    .id = NodeIds.item(index),
                    .style = .{ .height = .{ .px = @floatFromInt(m.group_h) }, .margin = .{ .bottom = @floatFromInt(m.item_gap) }, .flex = list_item_flex },
                    .variant = .surface,
                    .paint = dividedRowPaint(),
                    .action = action,
                    .overflow = .clip,
                }, &.{});
            },
            .card => |card| {
                const select = table.append(props.snapshot_generation, .{ .select_card = card.identity }, true) catch return error.InsufficientActionBuffer;
                if (card.expanded) |expanded| {
                    const action_count: usize = 2 + @as(usize, @intFromBool(expanded.focus_live_enabled));
                    const nested = buffers.nodes[nested_cursor .. nested_cursor + 3 + action_count];
                    nested_cursor += nested.len;
                    nested[0] = sessionCardNode(NodeIds.cardHeader(index), select, card.selected, m.card_h);
                    nested[1] = tree.card(.{
                        .id = NodeIds.expandedDetail(index),
                        .style = .{ .height = .{ .px = @floatFromInt(m.expanded_detail_h) } },
                        .variant = .raised,
                        .paint = .{},
                        .overflow = .clip,
                    }, &.{});
                    const action_nodes = nested[3..][0..action_count];
                    const resume_action = table.append(props.snapshot_generation, .resume_session, true) catch return error.InsufficientActionBuffer;
                    const reveal = table.append(props.snapshot_generation, .reveal_log, true) catch return error.InsufficientActionBuffer;
                    const action_width = expansionActionWidth(props.viewport_px.width, m, action_count);
                    action_nodes[0] = expansionActionNode(NodeIds.resumeAction(index), resume_action, expanded.state == .ready and expanded.resume_enabled, .primary, action_width);
                    action_nodes[1] = expansionActionNode(NodeIds.reveal(index), reveal, expanded.state == .ready and expanded.reveal_enabled, .secondary, action_width);
                    if (expanded.focus_live_enabled) {
                        const focus = table.append(props.snapshot_generation, .focus_live, true) catch return error.InsufficientActionBuffer;
                        action_nodes[2] = expansionActionNode(NodeIds.focusLive(index), focus, expanded.state == .ready, .secondary, action_width);
                    }
                    nested[2] = tree.container(.{
                        .id = NodeIds.expandedActions(index),
                        // Buttons divide the remaining main-axis width after this explicit gap;
                        // percentage widths would add the gap on top and overflow the published clip.
                        .style = .{ .height = .{ .px = @floatFromInt(m.expanded_actions_h) }, .gap = @floatFromInt(m.action_gap) },
                        .direction = .row,
                        .overflow = .clip,
                    }, action_nodes);
                    node.* = tree.container(.{
                        .id = NodeIds.item(index),
                        .style = .{ .height = .{ .px = @floatFromInt(m.card_h + m.expanded_detail_h + m.expanded_actions_h) }, .margin = .{ .bottom = @floatFromInt(m.item_gap) }, .flex = list_item_flex },
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
        .style = .{ .height = .{ .px = @floatFromInt(m.header_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap), .right = @floatFromInt(m.root_inset) } },
        // Header text has no enclosing card in the dock reference. It remains a Card only so
        // refresh retains one completed action rect.  Its bottom rule is deliberately explicit:
        // a borderless header must not make the fixed chrome merge into the control/list area.
        .variant = .surface,
        .paint = .{ .background = .surface_bg, .border = .divider, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .action = refresh,
        .overflow = .clip,
    }, &.{});
    top[1] = tree.card(.{
        .id = NodeIds.scope_row,
        .style = .{ .height = .{ .px = @floatFromInt(m.scope_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap), .right = @floatFromInt(m.root_inset) }, .gap = @floatFromInt(m.item_gap) },
        .direction = .row,
        .variant = .surface,
        // The segmented control is one outlined surface. Child scope cards paint only their
        // selected state, so the inactive thirds do not turn into three unrelated buttons.
        .paint = .{ .border = .divider },
        .overflow = .clip,
    }, scope_nodes);
    top[2] = tree.card(.{
        .id = NodeIds.search,
        .style = .{ .height = .{ .px = @floatFromInt(m.search_h) }, .margin = .{ .bottom = @floatFromInt(m.control_gap), .right = @floatFromInt(m.root_inset) } },
        .variant = if (props.search_focused) .selected else .surface,
        .paint = .{},
        .action = search,
        .overflow = .clip,
    }, &.{});
    // 스크롤바 action은 발행 여부와 무관하게 미리 만든다 — 발행할지는 `build`가 기하를 보고 정하고,
    // 그때는 action table을 만들 수 없다. 안 쓰이면 table에 남기만 한다(hit-test는 published entry만 본다).
    const scroll_track = table.append(props.snapshot_generation, .scroll_track, true) catch return error.InsufficientActionBuffer;
    const scroll_thumb = table.append(props.snapshot_generation, .scroll_thumb, true) catch return error.InsufficientActionBuffer;
    // 고정 헤더는 흐름 위의 그 그룹 행과 **같은 행위**를 해야 한다 — 눌러 접는 것이 목록 위치에 따라
    // 달라지면 같은 헤더가 두 물건이 된다. 같은 `toggle_group` identity를 다시 등록한다.
    const sticky: ?tree.StickyDeclaration = if (props.sticky_group) |head| .{
        .id = NodeIds.sticky_group,
        .action = table.append(props.snapshot_generation, .{ .toggle_group = head.group.identity }, true) catch return error.InsufficientActionBuffer,
        .paint = dividedRowPaint(),
        .height_px = @floatFromInt(m.group_h),
        .top_px = @floatFromInt(head.top_px),
        // 다음 그룹의 top에서 item gap을 뺀다 — 그 gap은 다음 헤더 **앞**의 빈 자리라, 밀어내기는
        // 헤더가 아니라 그 빈 자리가 올라오는 순간부터 시작해야 목록이 튀지 않는다.
        .next_top_px = if (head.next_top_px) |next| @floatFromInt(next -| m.item_gap) else no_next_group,
    } else null;
    // 선언 하나다. 자식 평행이동·viewport clip·track/thumb 발행은 `tree.build`가 한다
    // (docs/scroll-area.md §4.1). 이 컴포넌트가 손으로 하던 세 단계가 여기서 사라졌다.
    top[3] = tree.scrollArea(.{
        .id = NodeIds.content,
        .style = .{ .height = .{ .fill = 1 } },
        .scroll = .{
            .offset_px = props.scroll_offset_px,
            .content_h_px = props.scroll_content_height_px,
            .first_item_origin_y_px = props.content_first_item_origin_y_px,
            // scroll-area 오른쪽에 남은 도크 padding. root가 소유한 여백이라 카드/버튼이 절대 침범하지
            // 않는 유일한 자리이고, 여기 놓으면 스크롤바가 나타나고 사라져도 목록 폭이 reflow하지 않는다.
            .gutter_px = @floatFromInt(m.root_inset),
            .metrics = m.scrollbarMetrics(),
            .track = .{ .id = NodeIds.scroll_track, .action = scroll_track, .paint = scrollbarPaint(m, .inset_bg) },
            .thumb = .{ .id = NodeIds.scroll_thumb, .action = scroll_thumb, .paint = scrollbarPaint(m, .muted_fg) },
            .drag = .{
                // thumb을 누른 것 자체가 스크롤 의사이고 그 지점에 경쟁할 click이 없으므로 threshold는 0이다.
                // track도 같은 payload를 선언한다 — 눌러 점프한 뒤 손을 떼지 않고 이어 끌 수 있어야 한다.
                .payload = scroll_drag_payload,
                .axis = .vertical,
                .threshold_px = 0,
            },
            .sticky = sticky,
        },
    }, item_nodes);

    const root = tree.container(.{
        .id = NodeIds.root,
        // All dock layers share this bounded content rect. Keeping the clipping boundary here
        // prevents a fixed chrome width from overflowing after margins are applied and keeps
        // list dividers on the same logical edge as the header/search controls.
        // 오른쪽 여백은 root가 아니라 scroll-area의 gutter가 소유한다 — 스크롤바가 그 안에 놓여야 자기
        // 컨테이너의 clip에 안 잘린다(CSS `scrollbar-gutter`와 같은 자리). 고정 chrome은 각자
        // `margin.right`로 같은 여백을 가지며, 그 margin이 먹으려면 폭이 stretch여야 한다(percent는
        // border box 전체 크기라 margin을 무시한다 — CSS `width: 100%`가 넘치는 것과 같다).
        .style = .{ .padding = .{ .top = @floatFromInt(m.root_inset), .bottom = @floatFromInt(m.root_inset), .left = @floatFromInt(m.root_inset) } },
        .overflow = .clip,
    }, top);
    const built = try tree.build(root, .{
        .root_size = props.viewport_px,
        // root + 목록이 넘칠 때 `scrollArea`가 내는 track/thumb + 고정 헤더. 셋 다 이제 build의 preorder
        // 안에서 나오므로 상한에 함께 들어간다(예전에는 tree 밖에서 배열 끝에 붙였다).
        .max_entries = needed_nodes + 4,
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
    return .{ .tree = built, .actions = table.slice() };
}

/// thumb drag가 싣는 opaque payload. tree/interaction은 이 값의 의미를 모르고, host의 intent 해석만 안다.
pub const scroll_drag_payload: u64 = 0x5344_5342;

/// 스크롤바 조각의 paint. thumb의 기본색은 `muted_fg`(패널보다 확실히 밝은 중간 회색)이고 track은
/// `inset_bg`의 옅은 홈이다 — 둘의 명암 차가 작으면 스크롤바가 있어도 안 보인다. hover/drag에서는
/// `paint_style.resolveCard`가 상태 배경을 얹으므로 컴포넌트가 상태 색을 따로 두지 않는다.
fn scrollbarPaint(m: types.DockMetrics, background: @import("../../tokens.zig").ColorRole) tree.PaintStyle {
    const radius: u16 = @intCast(m.scrollbar_width / 2);
    return .{
        .background = background,
        .corner_radii_px = .{ radius, radius, radius, radius },
        .border_widths_px = .{ 0, 0, 0, 0 },
        .shadow = .none,
    };
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

/// 스크롤 목록의 아이템은 **줄어들지 않는다**. `content`는 `fill` 컨테이너라 자식 총합이 viewport를
/// 넘으면 `layout.distributeFlex`가 기본 shrink=1로 전부 균등 축소하는데, 가상화는 마지막 아이템이 항상
/// viewport를 넘도록 창을 잡으므로 그 축소가 상시 상태가 된다. 그러면 published rect와, 같은 값을 읽어야
/// 하는 scroll projection·view의 텍스트 offset(둘 다 축소 전 `DockMetrics`)이 갈라진다. 목록은 넘치면
/// 잘려야 하고(`content`의 overflow=clip), 줄어들어서는 안 된다.
const list_item_flex: layout.FlexStyle = .{ .shrink = 0 };

fn sessionCardNode(id: u64, action: tree.UiAction, selected: bool, height: u32) tree.UiNode {
    return tree.card(.{
        .id = id,
        .style = .{ .height = .{ .px = @floatFromInt(height) }, .flex = list_item_flex },
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
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
    const header_visual = switch (frame.tree.entries[frame.tree.find(NodeIds.header).?].visual) {
        .card => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try @import("std").testing.expectEqual(@as(?@import("../../tokens.zig").ColorRole, .divider), header_visual.paint.border);
    try @import("std").testing.expectEqual(@as(?[4]u16, .{ 0, 0, 1, 0 }), header_visual.paint.border_widths_px);
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
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
    // 고정 chrome은 오른쪽 여백을 자기 margin으로 갖고, scroll-area는 같은 폭을 gutter로 갖는다.
    // 그래서 scroll-area rect는 그만큼 넓지만 **목록 항목은 고정 chrome과 같은 폭**이다 — 스크롤바가
    // 그 옆 gutter를 차지하고, 나타나고 사라져도 목록 폭이 reflow하지 않는다.
    try @import("std").testing.expectEqual(header.rect.width + @as(f32, @floatFromInt(m.root_inset)), content.rect.width);
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

    var nodes_a: [32]tree.UiNode = undefined;
    var entries_a: [32]tree.RectEntry = undefined;
    var layout_items_a: [32]layout.Item = undefined;
    var flex_scratch_a: [32]layout.FlexScratch = undefined;
    var child_rects_a: [32]layout.UiRect = undefined;
    var actions_a: [32]ids.Entry = undefined;
    const frame_a = try build(base_props, .{
        .nodes = &nodes_a,
        .entries = &entries_a,
        .layout_items = &layout_items_a,
        .flex_scratch = &flex_scratch_a,
        .child_rects = &child_rects_a,
        .actions = &actions_a,
    });
    var nodes_b: [32]tree.UiNode = undefined;
    var entries_b: [32]tree.RectEntry = undefined;
    var layout_items_b: [32]layout.Item = undefined;
    var flex_scratch_b: [32]layout.FlexScratch = undefined;
    var child_rects_b: [32]layout.UiRect = undefined;
    var actions_b: [32]ids.Entry = undefined;
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
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

// 사용자 보고 회귀: 목록을 스크롤하면 카드 글자가 자기 카드 밖으로 새고 펼친 카드의 버튼이 빈 상자가
// 됐다. 루트 코즈는 렌더가 아니라 layout이다 — `content`는 `fill` 컨테이너이고 목록 아이템은 그 flex
// 자식이라, 아이템 총합이 viewport를 넘으면 `distributeFlex`가 **모두 균등 축소**한다. 가상화는 마지막
// 아이템이 항상 viewport를 넘도록 창을 잡으므로(scroll_area.project) 이 축소는 예외가 아니라 상시 상태다.
//
// 그런데 scroll projection·view의 텍스트 offset은 축소 전 `DockMetrics`를 읽는다. 즉 published rect와
// 스크롤/그리기 좌표가 서로 다른 높이를 쓰게 되고, 이는 문서가 명시적으로 금지한 상태다
// (docs/agent-session-list.md: "scroll projection·paint·clip·hit-test는 같은 DockMetrics를 읽으므로
// 밀도 변경 뒤에도 보이는 위치와 눌리는 위치가 갈라지지 않는다").
//
// 스크롤 목록은 넘치면 **잘려야** 하고 줄어들어서는 안 된다. 그래서 아이템은 shrink 대상이 아니다.
test "SessionDock list items keep their DockMetrics height instead of shrinking to the viewport" {
    const std = @import("std");
    // 확장 카드(112+256+48=416) + 카드(112) = 528이 스크롤 영역보다 확실히 크도록 잡는다.
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 640 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 3,
        .displayed_count = 2,
        .expanded_identity = 1,
        .items = &.{
            .{ .card = .{
                .identity = 1,
                .provider = .claude,
                .title = "expanded",
                .summary = "summary",
                .metadata = "meta",
                .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true, .turns = &.{.{ .role = .user, .text = "turn" }} },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "next", .summary = "summary", .metadata = "meta" } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
    const frame = try build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const m = types.DockMetrics.resolve(props.scale_milli);
    const content = frame.tree.entries[frame.tree.find(NodeIds.content).?];
    // 전제가 살아 있는지부터 본다 — 목록이 스크롤 영역보다 실제로 커야 이 테스트가 축소를 잡는다.
    const total_h: f32 = @floatFromInt(m.card_h + m.expanded_detail_h + m.expanded_actions_h + m.card_h);
    try std.testing.expect(total_h > content.rect.height);

    const header = frame.tree.entries[frame.tree.find(NodeIds.cardHeader(0)).?];
    const detail = frame.tree.entries[frame.tree.find(NodeIds.expandedDetail(0)).?];
    const action_row = frame.tree.entries[frame.tree.find(NodeIds.expandedActions(0)).?];
    const resume_action = frame.tree.entries[frame.tree.find(NodeIds.resumeAction(0)).?];
    const next_card = frame.tree.entries[frame.tree.find(NodeIds.item(1)).?];
    try std.testing.expectEqual(@as(f32, @floatFromInt(m.card_h)), header.rect.height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(m.expanded_detail_h)), detail.rect.height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(m.expanded_actions_h)), action_row.rect.height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(m.expanded_actions_h)), resume_action.rect.height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(m.card_h)), next_card.rect.height);
}

test "SessionDock virtualization translates an expanded card's whole subtree" {
    // Scrolling publishes a negative first-item origin. An expanded card owns nested detail and
    // action rects, so translating only the direct content children would leave that inline
    // detail painted at its unscrolled y — visibly overlapping the cards that scrolled past it.
    const props = types.Props{
        // 목록 아이템이 더 이상 축소되지 않으므로, 확장 카드(112+256+48)와 이웃 카드가 모두 실제로
        // 스크롤 영역 안에 들어가는 viewport를 준다. 예전 480은 축소 덕분에만 전부 들어갔다.
        .viewport_px = .{ .width = 320, .height = 960 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 5,
        .displayed_count = 2,
        .expanded_identity = 12,
        .items = &.{
            .{ .card = .{ .identity = 12, .provider = .claude, .title = "expanded", .summary = "summary", .metadata = "meta", .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true } } },
            .{ .card = .{ .identity = 13, .provider = .claude, .title = "next", .summary = "summary", .metadata = "meta" } },
        },
    };
    var scrolled_props = props;
    scrolled_props.content_first_item_origin_y_px = -37;

    var nodes_a: [32]tree.UiNode = undefined;
    var entries_a: [32]tree.RectEntry = undefined;
    var layout_items_a: [32]layout.Item = undefined;
    var flex_scratch_a: [32]layout.FlexScratch = undefined;
    var child_rects_a: [32]layout.UiRect = undefined;
    var actions_a: [32]ids.Entry = undefined;
    const rested = try build(props, .{
        .nodes = &nodes_a,
        .entries = &entries_a,
        .layout_items = &layout_items_a,
        .flex_scratch = &flex_scratch_a,
        .child_rects = &child_rects_a,
        .actions = &actions_a,
    });
    var nodes_b: [32]tree.UiNode = undefined;
    var entries_b: [32]tree.RectEntry = undefined;
    var layout_items_b: [32]layout.Item = undefined;
    var flex_scratch_b: [32]layout.FlexScratch = undefined;
    var child_rects_b: [32]layout.UiRect = undefined;
    var actions_b: [32]ids.Entry = undefined;
    const scrolled = try build(scrolled_props, .{
        .nodes = &nodes_b,
        .entries = &entries_b,
        .layout_items = &layout_items_b,
        .flex_scratch = &flex_scratch_b,
        .child_rects = &child_rects_b,
        .actions = &actions_b,
    });

    const content_index = scrolled.tree.find(NodeIds.content).?;
    const content = scrolled.tree.entries[content_index];
    inline for (.{
        NodeIds.item(0),
        NodeIds.cardHeader(0),
        NodeIds.expandedDetail(0),
        NodeIds.expandedActions(0),
        NodeIds.resumeAction(0),
        NodeIds.reveal(0),
        NodeIds.item(1),
    }) |id| {
        const before = rested.tree.entries[rested.tree.find(id).?];
        const after = scrolled.tree.entries[scrolled.tree.find(id).?];
        try @import("std").testing.expectEqual(before.rect.y - 37, after.rect.y);
        try @import("std").testing.expectEqual(before.rect.x, after.rect.x);
        // Every translated descendant keeps the one content clip that paint and hit testing share.
        const clip = after.effective_clip orelse return error.TestUnexpectedResult;
        try @import("std").testing.expect(clip.y >= content.rect.y);
        try @import("std").testing.expect(clip.y + clip.height <= content.rect.y + content.rect.height);
    }
    // The detail's own rect still bounds its clip, so a partially scrolled disclosure cannot paint
    // its turns over the card that follows it.
    const detail = scrolled.tree.entries[scrolled.tree.find(NodeIds.expandedDetail(0)).?];
    const detail_clip = detail.effective_clip.?;
    try @import("std").testing.expect(detail_clip.y >= detail.rect.y);
    try @import("std").testing.expect(detail_clip.y + detail_clip.height <= detail.rect.y + detail.rect.height);

    // The real defect was containment, not a wrong delta: the nested rects stayed behind and left
    // their own item, so they painted over neighbouring cards. Assert the structural invariant.
    const outer = scrolled.tree.entries[scrolled.tree.find(NodeIds.item(0)).?];
    const next = scrolled.tree.entries[scrolled.tree.find(NodeIds.item(1)).?];
    inline for (.{ NodeIds.cardHeader(0), NodeIds.expandedDetail(0), NodeIds.expandedActions(0) }) |id| {
        const nested = scrolled.tree.entries[scrolled.tree.find(id).?];
        try @import("std").testing.expect(nested.rect.y >= outer.rect.y);
        try @import("std").testing.expect(nested.rect.y + nested.rect.height <= outer.rect.y + outer.rect.height);
        try @import("std").testing.expect(nested.rect.y + nested.rect.height <= next.rect.y);
    }
    // Over-clipping would be just as wrong as no clipping. Every translated entry's clip is exactly
    // its own translated rect intersected with the content viewport: the first card loses only the
    // 37px scrolled above the top, and the rects fully inside stay fully paintable.
    inline for (.{ NodeIds.item(0), NodeIds.cardHeader(0), NodeIds.expandedDetail(0), NodeIds.resumeAction(0) }) |id| {
        const entry = scrolled.tree.entries[scrolled.tree.find(id).?];
        const clip = entry.effective_clip.?;
        try @import("std").testing.expectEqual(@max(entry.rect.y, content.rect.y), clip.y);
        try @import("std").testing.expectEqual(
            @min(entry.rect.y + entry.rect.height, content.rect.y + content.rect.height),
            clip.y + clip.height,
        );
        try @import("std").testing.expect(clip.height > 0);
    }
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
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

// 이 테스트가 증명하는 것: scrollbar가 도크의 **같은 published tree**에 실리고, 스크롤 목록의
// 평행이동을 따라가지 않으며, thumb이 track보다 뒤에 와서 hit-test에서 이긴다.
//
// 왜 중요한가 — scrollbar를 별도 tree나 host 계산으로 빼면 paint·hit-test·clip이 서로 다른 출처를
// 읽게 되고, 그때부터 "보이는 곳과 눌리는 곳"이 갈라진다. 반대로 scroll-area의 자식으로 넣으면
// virtualization origin을 함께 받아 스크롤할 때 스크롤바가 목록과 같이 흘러내린다.
test "SessionDock publishes a scrollbar that stays put while the list scrolls" {
    const std = @import("std");
    const items = [_]types.Item{
        .{ .card = .{ .identity = 1, .provider = .claude, .title = "a", .summary = "b", .metadata = "c" } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "d", .summary = "e", .metadata = "f" } },
    };
    const base = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 77,
        .displayed_count = 2,
        .items = &items,
        // 실제 목록은 뷰포트보다 훨씬 길다 — 보이는 카드는 둘뿐이어도 scrollbar는 전체를 대표한다.
        .scroll_content_height_px = 4000,
        .scroll_offset_px = 0,
    };

    const Built = struct {
        entries: [16]tree.RectEntry = undefined,
        nodes: [12]tree.UiNode = undefined,
        layout_items: [16]layout.Item = undefined,
        flex_scratch: [16]layout.FlexScratch = undefined,
        child_rects: [16]layout.UiRect = undefined,
        actions: [16]ids.Entry = undefined,

        fn run(self: *@This(), props: types.Props) !Frame {
            return build(props, .{
                .nodes = &self.nodes,
                .entries = &self.entries,
                .layout_items = &self.layout_items,
                .flex_scratch = &self.flex_scratch,
                .child_rects = &self.child_rects,
                .actions = &self.actions,
            });
        }
    };

    var rested_storage = Built{};
    const rested = try rested_storage.run(base);
    const track_index = rested.tree.find(NodeIds.scroll_track) orelse return error.TestUnexpectedResult;
    const thumb_index = rested.tree.find(NodeIds.scroll_thumb) orelse return error.TestUnexpectedResult;
    const track = rested.tree.entries[track_index];
    const thumb = rested.tree.entries[thumb_index];

    // thumb이 **마지막** entry다. reverse z-order라 track이 뒤에 오면 thumb 위 down이 track click으로
    // 판정돼 드래그 대신 점프가 일어난다.
    try std.testing.expectEqual(rested.tree.entries.len - 1, thumb_index);
    try std.testing.expect(track_index < thumb_index);

    // 같은 track 위에 있고, thumb은 보이는 비율만큼 짧다.
    try std.testing.expectEqual(track.rect.x, thumb.rect.x);
    try std.testing.expectEqual(track.rect.width, thumb.rect.width);
    try std.testing.expect(thumb.rect.height < track.rect.height);

    // scroll-area 안에 들어 있다(카드와 같은 content rect를 오른쪽에서 공유한다).
    const content = rested.tree.entries[rested.tree.find(NodeIds.content).?];
    try std.testing.expectEqual(content.rect.y, track.rect.y);
    try std.testing.expectEqual(content.rect.height, track.rect.height);
    // scroll-area가 자기 폭에서 떼어 놓은 gutter 안에 있다 — 항목 오른쪽이고 그 위에 겹치지 않는다.
    const item = rested.tree.entries[rested.tree.find(NodeIds.item(0)).?];
    try std.testing.expect(track.rect.x >= item.rect.x + item.rect.width);
    try std.testing.expect(track.rect.x + track.rect.width <= content.rect.x + content.rect.width);

    // thumb만 drag를 선언하지 않는다 — track도 선언한다. track을 눌러 점프한 뒤 그대로 끌 수 있어야 한다.
    try std.testing.expectEqual(tree.DragAxis.vertical, thumb.drag.?.axis);
    try std.testing.expectEqual(@as(f32, 0), thumb.drag.?.threshold_px);
    try std.testing.expectEqual(scroll_drag_payload, track.drag.?.payload);

    // 둘 다 published action을 갖는다(hover/capture 피드백이 generic paint에서 나온다).
    var table = ids.Table.init(@constCast(rested.actions));
    table.count = rested.actions.len;
    try std.testing.expectEqual(@as(?ids.Intent, .scroll_track), table.resolve(track.action.?.id, base.snapshot_generation));
    try std.testing.expectEqual(@as(?ids.Intent, .scroll_thumb), table.resolve(thumb.action.?.id, base.snapshot_generation));

    // 목록을 스크롤하면 카드는 움직이지만 track은 제자리다. thumb만 track 안에서 내려간다.
    var scrolled_props = base;
    scrolled_props.content_first_item_origin_y_px = -37;
    scrolled_props.scroll_offset_px = 2000;
    var scrolled_storage = Built{};
    const scrolled = try scrolled_storage.run(scrolled_props);
    const scrolled_track = scrolled.tree.entries[scrolled.tree.find(NodeIds.scroll_track).?];
    const scrolled_thumb = scrolled.tree.entries[scrolled.tree.find(NodeIds.scroll_thumb).?];
    try std.testing.expectEqual(track.rect.y, scrolled_track.rect.y);
    try std.testing.expectEqual(track.rect.height, scrolled_track.rect.height);
    try std.testing.expect(scrolled_thumb.rect.y > thumb.rect.y);
    // 그리고 track 밖으로 나가지 않는다.
    try std.testing.expect(scrolled_thumb.rect.y + scrolled_thumb.rect.height <= scrolled_track.rect.y + scrolled_track.rect.height + 0.01);
    // 카드는 실제로 평행이동했다(전제 확인 — 안 움직였다면 위 단언이 공허하다).
    try std.testing.expect(scrolled.tree.entries[scrolled.tree.find(NodeIds.item(0)).?].rect.y < rested.tree.entries[rested.tree.find(NodeIds.item(0)).?].rect.y);
}

// 넘치지 않는 목록에는 scrollbar가 없다. 있는 척하면 사용자에게 없는 여백을 있다고 말하는 셈이고,
// 잡을 수 없는 track이 카드 우측 클릭을 가로챈다.
test "bufferSizes는 build가 성공하는 최소치이고 한 칸만 줄여도 실패한다" {
    const std = @import("std");
    const items = [_]types.Item{
        .{ .group = .{ .identity = 1, .label = "g", .count = 2 } },
        .{ .card = .{ .identity = 1, .provider = .claude, .title = "a", .summary = "b", .metadata = "c" } },
        .{ .card = .{
            .identity = 2,
            .provider = .claude,
            .title = "d",
            .summary = "e",
            .metadata = "f",
            .expanded = .{ .state = .ready, .turns = &.{}, .action_record_count = 0, .focus_live_enabled = true },
        } },
    };
    const props = types.Props{
        .viewport_px = .{ .width = 480, .height = 720 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 5,
        .displayed_count = items.len,
        .items = &items,
        .scroll_content_height_px = 4000,
        .scroll_offset_px = 500,
        // 고정 헤더도 자리를 차지한다. 선언 없이 재면 sticky 몫이 늘 남아돌아, 정작 헤더가 붙은
        // 스크롤 위치에서만 버퍼가 터지는 걸 이 테스트가 못 본다.
        .sticky_group = .{ .group = .{ .identity = 1, .label = "g", .count = 2 }, .top_px = 0, .next_top_px = null },
    };
    const sizes = bufferSizes(&items);

    var nodes: [78]tree.UiNode = undefined;
    var entries: [78]tree.RectEntry = undefined;
    var layout_items: [78]layout.Item = undefined;
    var flex_scratch: [78]layout.FlexScratch = undefined;
    var child_rects: [78]layout.UiRect = undefined;
    var actions: [78]ids.Entry = undefined;
    const Run = struct {
        fn go(p: types.Props, z: BufferSizes, n: []tree.UiNode, e: []tree.RectEntry, li: []layout.Item, fs: []layout.FlexScratch, cr: []layout.UiRect, a: []ids.Entry) BuildError!Frame {
            return build(p, .{
                .nodes = n[0..z.nodes],
                .entries = e[0..z.entries],
                .layout_items = li[0..z.layout_items],
                .flex_scratch = fs[0..z.flex_scratch],
                .child_rects = cr[0..z.child_rects],
                .actions = a[0..z.actions],
            });
        }
    };

    // 보고한 크기로는 스크롤바까지 포함해 성공한다.
    const frame = try Run.go(props, sizes, &nodes, &entries, &layout_items, &flex_scratch, &child_rects, &actions);
    try std.testing.expect(frame.tree.find(NodeIds.scroll_thumb) != null);
    try std.testing.expect(frame.tree.find(NodeIds.sticky_group) != null);

    // 어느 하나라도 한 칸 모자라면 실패한다 — 넉넉히 보고하면 호출처가 실패 조건을 영영 못 본다.
    inline for (@typeInfo(BufferSizes).@"struct".fields) |field| {
        var tight = sizes;
        @field(tight, field.name) -= 1;
        // 어떤 종류의 부족인지는 버퍼마다 다르다(node/action/entry/depth). 중요한 것은 그 크기로는
        // **성공하지 않는다**는 것이다 — 성공하면 보고한 값이 최소치가 아니라 넉넉한 값이라는 뜻이다.
        if (Run.go(props, tight, &nodes, &entries, &layout_items, &flex_scratch, &child_rects, &actions)) |_| {
            std.debug.print("bufferSizes.{s}를 한 칸 줄여도 build가 성공했다 — 최소치가 아니다\n", .{field.name});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "SessionDock publishes no scrollbar when the list fits" {
    const std = @import("std");
    const items = [_]types.Item{
        .{ .card = .{ .identity = 1, .provider = .claude, .title = "a", .summary = "b", .metadata = "c" } },
    };
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 5,
        .displayed_count = 1,
        .items = &items,
        .scroll_content_height_px = 100,
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]layout.Item = undefined;
    var flex_scratch: [32]layout.FlexScratch = undefined;
    var child_rects: [32]layout.UiRect = undefined;
    var actions: [32]ids.Entry = undefined;
    const frame = try build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    try std.testing.expect(frame.tree.find(NodeIds.scroll_track) == null);
    try std.testing.expect(frame.tree.find(NodeIds.scroll_thumb) == null);
}
