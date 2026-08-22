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
const ids = @import("ids.zig");
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
    actions: []ids.Entry,
};

pub const Frame = struct {
    tree: tree.UiRectTree,
    metrics: types.Metrics,
    actions: []const ids.Entry,
};

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer };

/// 호출자가 잡아야 할 버퍼 크기. 행 수에서 파생되므로 호출부가 상수를 따로 들지 않는다.
pub fn bufferSizes(row_count: usize) struct { nodes: usize, entries: usize, actions: usize } {
    return .{ .nodes = row_count + 2, .entries = row_count + 2, .actions = row_count };
}

pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    const m = types.Metrics.resolve(props.scale_milli);
    const sizes = bufferSizes(props.rows.len);
    if (buffers.nodes.len < sizes.nodes) return error.InsufficientNodeBuffer;

    if (buffers.actions.len < sizes.actions) return error.InsufficientActionBuffer;
    var table = ids.Table.init(buffers.actions);
    const row_nodes = buffers.nodes[0..props.rows.len];
    for (row_nodes, props.rows, 0..) |*node, row, index| {
        // **빈 자리 행은 누를 수 없다.** 그 행은 "폴더를 여세요" 안내이지 항목이 아니고, 여는 일은
        // 배경 클릭(picker)이 이미 맡는다 — 여기에 action 을 달면 같은 동작이 두 주인을 갖는다.
        const action: ?tree.UiAction = if (row.kind == .empty)
            null
        else
            table.append(props.snapshot_generation, .{ .activate_row = row.model_index }, true) catch
                return error.InsufficientActionBuffer;
        node.* = rowNode(NodeIds.row(index), m, action);
    }

    // 목록 컨테이너가 **좌우 여백을 소유한다.** 행마다 margin을 주면 선택 밴드가 있는 행과 없는 행의
    // rect가 달라져 라벨 x가 상태에 따라 흔들린다 — 여백을 부모가 한 번 떼면 모든 행이 같은 폭이다.
    const list_h = @as(u32, @intCast(@min(props.rows.len, std.math.maxInt(u32) / @max(m.row_h, 1)))) *| m.row_h;
    const list = tree.container(.{
        .id = NodeIds.list,
        .style = .{
            .width = .{ .percent = 1 },
            .height = .{ .px = @floatFromInt(list_h) },
            // **여백을 여기서 떼지 않는다.** 밴드는 좌우로 들어가 보여야 하지만 **누르는 자리는 행
            // 전체**여야 한다 — 컨테이너에서 떼면 그 여백이 클릭 사각지대가 된다(FT2 테스트가 왼쪽
            // 가장자리 우클릭으로 잡았다). 그래서 여백은 `view` 가 밴드를 그릴 때만 적용한다.
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
    return .{
        .tree = .{ .entries = buffers.entries[0..built.entries.len], .generation = props.snapshot_generation },
        .metrics = m,
        .actions = table.slice(),
    };
}

/// 행 노드는 **히트 대상이고 그림이 아니다**(FT2). 면은 `view` 가 그린다 — 밴드는 좌우로 들여야
/// 하는데 누르는 자리는 전폭이어야 해서, 그 둘을 한 rect 로 표현할 수 없기 때문이다. 여백을 부모
/// 컨테이너에서 떼면 그 여백이 클릭 사각지대가 된다(테스트가 왼쪽 가장자리 우클릭으로 잡았다).
///
/// 그래서 `opacity = 0` 이고, 이 컴포넌트의 `view` 는 `ui_paint` 를 태우지 않는다. 그래도 이 선언을
/// 남기는 이유는 다른 소비자가 이 tree 를 그리려 들 때 **"여기엔 그릴 것이 없다"** 가 값으로 보여야
/// 하기 때문이다. 상태(선택·활성·호버)는 `view` 의 `bandRole` 이 소유한다.
fn rowNode(id: u64, m: types.Metrics, action: ?tree.UiAction) tree.UiNode {
    const style: layout.UiStyle = .{
        .width = .{ .percent = 1 },
        .height = .{ .px = @floatFromInt(m.row_h) },
        // **줄어들면 안 된다.** 목록은 뷰포트보다 길고(그게 스크롤의 정의다) flex 의 기본 `shrink = 1`은
        // 넘치는 만큼을 자식에서 깎는다 — 실측으로 26px 행이 25.21875px 로 그려졌다. 그러면 그린 행 높이와
        // 히트테스트가 쓰는 행 높이가 갈려 **아래로 내려갈수록 누른 행이 밀린다**(적대적 검증에서 잡았다).
        .flex = .{ .shrink = 0 },
    };
    // **모든 행이 card 다**(FT2). 예전에는 밴드가 필요한 행만 card 로 올렸는데, 그러면 나머지 행에
    // action 을 달 수 없어 히트테스트가 published tree 밖에 남는다(`container` 는 action 을 안 든다).
    // 쉬는 상태의 면은 `surface_bg` — 도크 배경과 **같은 role** 이라 눈에는 없는 것과 같고, 호버는
    // `paint_style.resolveCard` 가 `row_hover_bg` 로 덮는다(그 판정의 주인이 하나가 된다).
    return tree.card(.{
        .id = id,
        .style = style,
        .variant = .surface,
        .paint = .{
            .opacity = 0,
            .border_widths_px = .{ 0, 0, 0, 0 },
            .shadow = .none,
        },
        .action = action,
        // 이 면 위의 커서는 component 가 선언한다 — host 가 "누를 수 있나"를 다시 추론하면 판정의
        // 주인이 둘이 된다(`.press` 는 host 에서 pointing hand 로 풀린다).
        .cursor = if (action != null) .press else .auto,
        .overflow = .clip,
    }, &.{});
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_actions: [64]ids.Entry = undefined;

fn testBuild(props: types.Props, nodes: []tree.UiNode, entries: []tree.RectEntry, items: []layout.Item, flex: []layout.FlexScratch, rects: []layout.UiRect) BuildError!Frame {
    return build(props, .{ .nodes = nodes, .entries = entries, .layout_items = items, .flex_scratch = flex, .child_rects = rects, .actions = &test_actions });
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

test "행 rect 는 전폭이고 상태와 무관하게 같다" {
    // 선택 밴드가 생겼다고 라벨이 옆으로 움직이면 안 된다 — 그래서 여백은 부모가 소유한다.
    const rows = [_]types.Row{
        .{ .kind = .file, .label = "a", .icon_kind = 0 },
        .{ .kind = .file, .label = "b", .icon_kind = 0, .selected = true },
        .{ .kind = .file, .label = "c", .icon_kind = 0, .active = true },
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
    // **행 rect 는 전폭이다** — 밴드만 들어가고 누르는 자리는 가장자리까지다(FT2).
    try testing.expectEqual(@as(f32, 0), first.?.x);
    try testing.expectEqual(@as(f32, 300), first.?.width);
}

test "모든 행이 action 을 든 card 이고 쉬는 면은 도크 배경색이다" {
    const rows = [_]types.Row{
        .{ .kind = .file, .label = "plain", .icon_kind = 0 },
        .{ .kind = .file, .label = "sel", .icon_kind = 0, .selected = true },
        .{ .kind = .file, .label = "act", .icon_kind = 0, .active = true },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var items: [8]layout.Item = undefined;
    var flex: [8]layout.FlexScratch = undefined;
    var rects: [8]layout.UiRect = undefined;
    const frame = try testBuild(.{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows }, &nodes, &entries, &items, &flex, &rects);
    // **셋 다 card 이고 셋 다 누를 수 있다.** 하나라도 container 면 그 행의 히트테스트가 published tree
    // 밖으로 새고, 그러면 그린 자리와 누르는 자리의 출처가 다시 둘이 된다(FT2 가 없앤 것).
    for (0..rows.len) |i| {
        const entry = frame.tree.entries[frame.tree.find(NodeIds.row(i)).?];
        try testing.expectEqual(tree.NodeKind.card, entry.kind);
        try testing.expect(entry.action != null);
        try testing.expectEqual(tree.CursorHint.press, entry.cursor);
        try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, entry.visual.card.paint.border_widths_px.?);
    }
    // 행 노드는 **그림이 아니다** — 면은 `view` 가 그린다(밴드는 들이고 히트는 전폭이라야 해서).
    for (0..rows.len) |i| {
        const entry = frame.tree.entries[frame.tree.find(NodeIds.row(i)).?];
        try testing.expectEqual(@as(u8, 0), entry.visual.card.paint.opacity);
    }
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
