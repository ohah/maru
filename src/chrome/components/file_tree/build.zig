//! 파일 탐색기 트리 행의 bounded geometry 투영이다.
//!
//! **행 하나가 노드 하나다.** 들여쓰기·chevron·아이콘·라벨은 행 rect 안의 로컬 좌표(`types.Metrics`)로
//! 풀고 자식 노드를 만들지 않는다 — 트리는 행이 수천 개가 될 수 있어서 행마다 노드 넷을 내면 노드
//! 예산과 layout 비용이 행 수에 네 배로 붙는다. 그래서 이 컴포넌트가 발행하는 노드 수는
//! `보이는 행 + 2`(root scroll area + 목록 컨테이너)로 묶인다.
//!
//! **스크롤바를 발행하지 않는다.** track/thumb은 `app_session/dock.zig`의 `buildDockListScrollTree`가
//! 도크 목록 공용으로 이미 낸다(docs/file-explorer.md §3). 여기서 또 선언하면 막대가 둘이 된다 —
//! `ScrollDeclaration`은 track·thumb이 **둘 다 있을 때만** 스크롤바를 내므로, 이 root는 가상화
//! 평행이동(`first_item_origin_y_px`)만 쓴다.

const std = @import("std");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const tokens = @import("../../tokens.zig");
const types = @import("types.zig");

pub const NodeIds = struct {
    /// 'FT' — 다른 컴포넌트 id 공간과 겹치지 않는 구간.
    pub const root: u64 = 0x4654_0000;
    pub const list: u64 = 0x4654_0001;
    pub const row_base: u64 = 0x4654_0100;

    /// **보이는 창 안의 인덱스**가 아니라 창의 시작 인덱스를 더한 값을 쓰지 않는다 — 이 id는 한
    /// 프레임 안에서만 유효하고, 스크롤하면 같은 자리에 다른 행이 온다. 행의 도메인 신원은 host가
    /// 자기 인덱스로 들고 있다(FT2에서 action이 붙을 때 그 신원이 함께 실린다).
    pub fn row(window_index: usize) u64 {
        return row_base + window_index;
    }
};

pub const Buffers = struct {
    nodes: []tree.UiNode,
    entries: []tree.RectEntry,
    layout_items: []layout.Item,
    flex_scratch: []layout.FlexScratch,
    child_rects: []layout.UiRect,
};

pub const Frame = struct {
    tree: tree.UiRectTree,
    metrics: types.Metrics,
};

pub const BuildError = tree.BuildError || error{InsufficientNodeBuffer};

/// 호출자가 잡아야 할 버퍼 크기. 행 수에서 파생되므로 호출부가 상수를 따로 들지 않는다.
pub fn bufferSizes(row_count: usize) struct { nodes: usize, entries: usize } {
    return .{ .nodes = row_count + 2, .entries = row_count + 2 };
}

pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    const m = types.Metrics.resolve(props.scale_milli);
    const sizes = bufferSizes(props.rows.len);
    if (buffers.nodes.len < sizes.nodes) return error.InsufficientNodeBuffer;

    const row_nodes = buffers.nodes[0..props.rows.len];
    for (row_nodes, props.rows, 0..) |*node, row, index| {
        node.* = rowNode(NodeIds.row(index), row, m);
    }

    // 목록 컨테이너가 **좌우 여백을 소유한다.** 행마다 margin을 주면 선택 밴드가 있는 행과 없는 행의
    // rect가 달라져 라벨 x가 상태에 따라 흔들린다 — 여백을 부모가 한 번 떼면 모든 행이 같은 폭이다.
    const list_h = @as(u32, @intCast(@min(props.rows.len, std.math.maxInt(u32) / @max(m.row_h, 1)))) *| m.row_h;
    const list = tree.container(.{
        .id = NodeIds.list,
        .style = .{
            .width = .{ .percent = 1 },
            .height = .{ .px = @floatFromInt(list_h) },
            .padding = .{ .left = @floatFromInt(m.band_inset_x), .right = @floatFromInt(m.band_inset_x) },
            // 목록 자신도 안 줄어든다 — 줄어들면 그 안의 행들이 다시 그만큼 깎인다(위 행 주석과 같은 사고).
            .flex = .{ .shrink = 0 },
        },
        .direction = .column,
        .overflow = .visible,
    }, row_nodes);

    // **자식 슬라이스를 만들기 전에 값을 넣는다.** 슬라이스는 버퍼를 가리키므로 나중에 채워도 돌지만,
    // 그러면 "언제 채워지는가"가 읽는 사람에게 안 보인다 — 순서를 코드로 고정한다.
    buffers.nodes[props.rows.len] = list;
    const list_slice = buffers.nodes[props.rows.len .. props.rows.len + 1];

    // root는 **자기 크기를 `root_size`로 받는다**(도크 스크롤 tree와 같은 이유로 outer style을 주지
    // 않는다). 가상화로 위로 밀린 몫은 음수 origin으로 주고, 위·아래로 삐져나온 행은 이 clip이 자른다.
    const root = tree.scrollArea(.{
        .id = NodeIds.root,
        .scroll = .{
            .first_item_origin_y_px = -@as(i32, @intCast(@min(props.origin_shift_px, std.math.maxInt(i32)))),
            .content_h_px = list_h,
        },
    }, list_slice);

    const built = try tree.build(root, .{
        .root_size = props.viewport_px,
        .max_entries = sizes.entries,
        .max_depth = 3,
    }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    return .{ .tree = .{ .entries = buffers.entries[0..built.entries.len] }, .metrics = m };
}

/// 선택·호버가 아닌 행은 **아무것도 그리지 않는 컨테이너**다. card로 두면 variant 기본 배경·테두리가
/// 깔려 모든 행이 칠해진 상자가 된다(`paint_style.baseCardStyle` — 모든 variant가 배경을 준다).
///
/// 선택·호버 행만 card로 올리고 테두리를 0으로 눌러 **면만** 남긴다. 상태 색은 `paint_style`이 아니라
/// 여기서 명시하는데, 그 이유는 FT1이 아직 `InteractionState`를 쓰지 않기 때문이다 — 호버 판정은
/// host가 인덱스로 들고 있고(`file_tree_hovered_row`), FT2에서 발행된 rect 기반 히트테스트로 옮기면
/// 그때 `resolveCard`의 상태 해석으로 갈아탄다.
fn rowNode(id: u64, row: types.Row, m: types.Metrics) tree.UiNode {
    const style: layout.UiStyle = .{
        .width = .{ .percent = 1 },
        .height = .{ .px = @floatFromInt(m.row_h) },
        // **줄어들면 안 된다.** 목록은 뷰포트보다 길고(그게 스크롤의 정의다) flex 의 기본 `shrink = 1`은
        // 넘치는 만큼을 자식에서 깎는다 — 실측으로 26px 행이 25.21875px 로 그려졌다. 그러면 그린 행 높이와
        // 히트테스트가 쓰는 행 높이가 갈려 **아래로 내려갈수록 누른 행이 밀린다**(적대적 검증에서 잡았다).
        .flex = .{ .shrink = 0 },
    };
    const band: ?tokens.ColorRole = if (row.selected)
        .tab_active_bg
    else if (row.active)
        // 열려 있는 파일은 선택보다 **약한** 면으로 남는다 — 둘이 같은 세기면 "지금 고른 것"이 사라진다.
        .tab_hover_bg
    else if (row.hovered)
        .row_hover_bg
    else
        null;
    if (band == null) {
        return tree.container(.{ .id = id, .style = style, .overflow = .clip }, &.{});
    }
    const radius: [4]u16 = .{ m.corner_radius, m.corner_radius, m.corner_radius, m.corner_radius };
    return tree.card(.{
        .id = id,
        .style = style,
        .variant = .surface,
        .paint = .{
            .background = band,
            .border_widths_px = .{ 0, 0, 0, 0 },
            .corner_radii_px = radius,
            .shadow = .none,
        },
        .overflow = .clip,
    }, &.{});
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testBuild(props: types.Props, nodes: []tree.UiNode, entries: []tree.RectEntry, items: []layout.Item, flex: []layout.FlexScratch, rects: []layout.UiRect) BuildError!Frame {
    return build(props, .{ .nodes = nodes, .entries = entries, .layout_items = items, .flex_scratch = flex, .child_rects = rects });
}

test "행은 노드 하나이고 발행 수는 보이는 행 + 2 다" {
    const rows = [_]types.Row{
        .{ .kind = .root, .label = "maru3", .expandable = true, .expanded = true, .icon_kind = 0 },
        .{ .kind = .directory, .label = "docs", .depth = 1, .expandable = true, .icon_kind = 0 },
        .{ .kind = .file, .label = "build.zig", .depth = 1, .icon_kind = 0 },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var items: [8]layout.Item = undefined;
    var flex: [8]layout.FlexScratch = undefined;
    var rects: [8]layout.UiRect = undefined;
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows }, &nodes, &entries, &items, &flex, &rects);
    try testing.expectEqual(bufferSizes(rows.len).entries, frame.tree.entries.len);
    for (0..rows.len) |i| try testing.expect(frame.tree.find(NodeIds.row(i)) != null);
}

test "행 rect 는 좌우 여백만큼 좁고 상태와 무관하게 같은 폭이다" {
    // 선택 밴드가 생겼다고 라벨이 옆으로 움직이면 안 된다 — 그래서 여백은 부모가 소유한다.
    const rows = [_]types.Row{
        .{ .kind = .file, .label = "a", .icon_kind = 0 },
        .{ .kind = .file, .label = "b", .icon_kind = 0, .selected = true },
        .{ .kind = .file, .label = "c", .icon_kind = 0, .hovered = true },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var items: [8]layout.Item = undefined;
    var flex: [8]layout.FlexScratch = undefined;
    var rects: [8]layout.UiRect = undefined;
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows }, &nodes, &entries, &items, &flex, &rects);
    const m = frame.metrics;
    var first: ?layout.UiRect = null;
    for (0..rows.len) |i| {
        const rect = frame.tree.entries[frame.tree.find(NodeIds.row(i)).?].rect;
        if (first) |f| {
            try testing.expectEqual(f.width, rect.width);
            try testing.expectEqual(f.x, rect.x);
        } else first = rect;
        try testing.expectEqual(@as(f32, @floatFromInt(m.row_h)), rect.height);
    }
    try testing.expectEqual(@as(f32, @floatFromInt(m.band_inset_x)), first.?.x);
    try testing.expectEqual(@as(f32, 300 - @as(f32, @floatFromInt(m.band_inset_x * 2))), first.?.width);
}

test "선택·호버만 칠하는 면을 갖는다" {
    const rows = [_]types.Row{
        .{ .kind = .file, .label = "plain", .icon_kind = 0 },
        .{ .kind = .file, .label = "sel", .icon_kind = 0, .selected = true },
        .{ .kind = .file, .label = "hov", .icon_kind = 0, .hovered = true },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var items: [8]layout.Item = undefined;
    var flex: [8]layout.FlexScratch = undefined;
    var rects: [8]layout.UiRect = undefined;
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows }, &nodes, &entries, &items, &flex, &rects);
    const plain = frame.tree.entries[frame.tree.find(NodeIds.row(0)).?];
    try testing.expectEqual(tree.NodeKind.container, plain.kind);
    for ([_]usize{ 1, 2 }) |i| {
        const entry = frame.tree.entries[frame.tree.find(NodeIds.row(i)).?];
        try testing.expectEqual(tree.NodeKind.card, entry.kind);
        // 테두리 0 — 면만 남긴다. 남겨 두면 목록 행마다 상자가 그려진다.
        try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, entry.visual.card.paint.border_widths_px.?);
        try testing.expect(entry.visual.card.paint.corner_radii_px.?[0] > 0);
    }
    try testing.expectEqual(@as(?tokens.ColorRole, .tab_active_bg), frame.tree.entries[frame.tree.find(NodeIds.row(1)).?].visual.card.paint.background);
    try testing.expectEqual(@as(?tokens.ColorRole, .row_hover_bg), frame.tree.entries[frame.tree.find(NodeIds.row(2)).?].visual.card.paint.background);
}

// **목록이 뷰포트보다 길어도 행 높이는 변하지 않는다.** flex 기본값이 `shrink = 1`이라 이 선언이 없으면
// 넘치는 만큼이 행에서 깎이고(실측 26 → 25.21875), 그리면 그린 행과 히트테스트의 행 높이가 갈려 아래로
// 갈수록 누른 행이 밀린다. 스크롤 목록에서 가장 흔한 이 사고를 값으로 못 박는다.
test "뷰포트보다 긴 목록에서도 행 높이가 깎이지 않는다" {
    var rows: [40]types.Row = undefined;
    for (&rows) |*r| r.* = .{ .kind = .file, .label = "a", .icon_kind = 0 };
    var nodes: [64]tree.UiNode = undefined;
    var entries: [64]tree.RectEntry = undefined;
    var items: [64]layout.Item = undefined;
    var flex: [64]layout.FlexScratch = undefined;
    var rects: [64]layout.UiRect = undefined;
    // 뷰포트(120px)보다 목록(40행 × 26px)이 훨씬 길다 — 이 전제가 없으면 판정할 것이 없다.
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 120 }, .rows = &rows }, &nodes, &entries, &items, &flex, &rects);
    const m = frame.metrics;
    try testing.expect(rows.len * m.row_h > 120);
    for (0..rows.len) |i| {
        const entry = frame.tree.entries[frame.tree.find(NodeIds.row(i)).?];
        try testing.expectEqual(@as(f32, @floatFromInt(m.row_h)), entry.rect.height);
        try testing.expectEqual(@as(f32, @floatFromInt(i * m.row_h)), entry.rect.y);
    }
}

test "가상화: 첫 행이 위로 밀리면 그만큼 올라가고 root 가 자른다" {
    const rows = [_]types.Row{
        .{ .kind = .file, .label = "a", .icon_kind = 0 },
        .{ .kind = .file, .label = "b", .icon_kind = 0 },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var items: [8]layout.Item = undefined;
    var flex: [8]layout.FlexScratch = undefined;
    var rects: [8]layout.UiRect = undefined;
    const shift: u32 = 7;
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows, .origin_shift_px = shift }, &nodes, &entries, &items, &flex, &rects);
    const first = frame.tree.entries[frame.tree.find(NodeIds.row(0)).?];
    try testing.expectEqual(-@as(f32, @floatFromInt(shift)), first.rect.y);
    // 위로 삐져나온 행은 clip을 들고 있어야 한다 — 없으면 도크 헤더 위로 글자가 샌다.
    try testing.expect(first.effective_clip != null);
}
