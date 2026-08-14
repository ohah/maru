//! 소스 컨트롤 도크의 기하·action 투영(유계, 무할당).
//!
//! 호출자가 모든 버퍼를 준다. 실패한 후보 tree는 `ui.tree.build`에서 통째로 버려지므로 **반쯤 만들어진
//! 도크가 이전 스냅샷을 덮는 일이 없다**(Session Dock과 같은 규율).
//!
//! **상호작용 사각형은 전부 이 tree 하나에 속한다.** platform이 행 높이를 다시 곱해 두 번째 히트 영역을
//! 만들지 않는다 — 옛 셀 그리드 경로가 그렇게 갈려서 "그린 자리와 눌리는 자리"가 어긋났었다.

const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const NodeIds = struct {
    pub const root: u64 = 0x5343_0000;
    pub const summary: u64 = 0x5343_0001;
    pub const content: u64 = 0x5343_0002;
    pub const branch: u64 = 0x5343_0003;
    pub const scroll_track: u64 = 0x5343_0004;
    pub const scroll_thumb: u64 = 0x5343_0005;
    pub const tabs: u64 = 0x5343_0006;

    /// 항목 하나가 쓰는 id 차선. 행 자신과 그 행의 동작 버튼이 같은 차선을 나눠 쓰므로, 가상화로 창이
    /// 밀려도 같은 항목이 같은 id 구조를 유지한다.
    pub const item_base: u64 = 0x5343_1000;
    const item_stride: u64 = 2;

    pub fn item(index: usize) u64 {
        return item_base + @as(u64, @intCast(index)) * item_stride;
    }

    pub fn itemAction(index: usize) u64 {
        return item(index) + 1;
    }
};

/// 스크롤 drag payload. track과 thumb이 **같은 값**을 선언한다 — 눌러 점프한 뒤 손을 떼지 않고 이어
/// 끌 수 있어야 한다.
pub const scroll_drag_payload: u64 = 0x5343_D001;

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

pub const BufferSizes = struct {
    nodes: usize,
    entries: usize,
    layout_items: usize,
    flex_scratch: usize,
    child_rects: usize,
    actions: usize,
};

/// `build`가 이 items로 성공하는 데 필요한 최소 버퍼다. **이 산술은 build가 하는 것과 같으므로 호출처가
/// 복제하면 안 된다** — 작게 잡으면 build가 실패하고, 호출처가 그 실패를 삼키면 도크가 통째로 멈춘다.
pub fn bufferSizes(items: []const types.Item) BufferSizes {
    var action_buttons: usize = 0;
    for (items) |item| if (actionOf(item) != .none) {
        action_buttons += 1;
    };
    // 행 + 행 동작 버튼 + 고정 chrome 넷(탭 줄·요약·스크롤 영역·브랜치 줄).
    const node_count = items.len + action_buttons + 4;
    return .{
        .nodes = node_count,
        // +1은 root, +2는 목록이 넘칠 때 scroll area가 preorder 안에서 내는 track/thumb다.
        // **선언 여부와 무관하게** 예약한다 — 자리를 props에 따라 늘렸다 줄이면 host가 미리 잡아 둘 수 없다.
        .entries = node_count + 3,
        .layout_items = node_count + 3,
        .flex_scratch = node_count + 3,
        .child_rects = node_count + 3,
        // 행 열기 + 행 동작 + 그룹 토글/일괄 동작은 위에서 센 것과 같은 상한 안이고, +2는 스크롤바다.
        .actions = items.len * 2 + 2,
    };
}

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer };

fn actionOf(item: types.Item) types.RowAction {
    return switch (item) {
        .section => |section| section.action,
        .file => |file| file.action,
        .more, .notice => .none,
    };
}

pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    const sizes = bufferSizes(props.items);
    if (buffers.nodes.len < sizes.nodes) return error.InsufficientNodeBuffer;

    const m = types.DockMetrics.resolve(props.scale_milli);
    var table = ids.Table.init(buffers.actions);

    // 자식을 먼저 저장하고 부모가 그 안정된 구간을 빌려 쓴다. `UiNode`는 값 tree라 이렇게 하면 힙이
    // 필요 없고 버퍼 상한이 계약의 일부가 된다.
    const row_nodes = buffers.nodes[0..props.items.len];
    var action_cursor: usize = props.items.len;
    for (props.items, row_nodes, 0..) |item, *node, index| {
        const row_action = actionOf(item);
        // **동작 버튼은 호버 여부와 무관하게 선언한다.** `build`는 포인터 상태를 모르고(그건 `view`가
        // 받는다), 무엇보다 사용자는 **호버해야만** 누를 수 있으므로 히트 사각형이 항상 있어도 안전하다.
        // 반대로 호버할 때만 선언하면 tree가 포인터마다 달라져 히트테스트가 자기 자신을 쫓게 된다.
        const action_nodes: []tree.UiNode = if (row_action != .none) blk: {
            const slot = buffers.nodes[action_cursor .. action_cursor + 1];
            action_cursor += 1;
            const intent: ids.Intent = switch (item) {
                .section => |section| .{ .section_action = section.section },
                .file => .{ .row_action = @intCast(index) },
                .more, .notice => unreachable, // actionOf가 이미 `.none`으로 걸렀다
            };
            const action = table.append(props.snapshot_generation, intent, true) catch return error.InsufficientActionBuffer;
            slot[0] = tree.button(.{
                .id = NodeIds.itemAction(index),
                .style = .{
                    .width = .{ .px = @floatFromInt(m.action_extent) },
                    .height = .{ .px = @floatFromInt(m.action_extent) },
                    .margin = .{ .right = @floatFromInt(m.inset_x) },
                },
                // 평소에는 배경 없이 글리프만 보인다(호버에서만 `view`가 칠한다).
                .variant = .ghost,
                .action = action,
                .overflow = .clip,
            });
            break :blk slot;
        } else &.{};

        const row_intent: ?ids.Intent = switch (item) {
            .section => |section| .{ .toggle_section = section.section },
            .file => .{ .open_row = @intCast(index) },
            .more => |more| .{ .expand_section = more.section },
            // 안내는 진술이지 컨트롤이 아니다 — action을 붙이지 않는다.
            .notice => null,
        };
        const row_action_id: ?tree.UiAction = if (row_intent) |intent|
            table.append(props.snapshot_generation, intent, true) catch return error.InsufficientActionBuffer
        else
            null;

        node.* = tree.card(.{
            .id = NodeIds.item(index),
            .style = .{ .height = .{ .px = @floatFromInt(m.itemHeight(item)) } },
            .direction = .row,
            // 동작 버튼은 행의 **오른쪽 끝**에 붙는다. 글자는 `view`가 rect 안에 직접 놓으므로 자식이 아니다.
            .justify = .end,
            .align_items = .center,
            // **행에는 테두리가 없다.** `surface` 기본값은 사방 divider 테두리라, 그대로 두면 행마다
            // 가로줄이 생겨 목업(VS Code)과 달리 표가 된다(사용자 지적 2026-08-14). 배경은 상태
            // 해석이 얹으므로(hover=`row_hover_bg`, 누름=`tab_active_bg`) 여기서 지우지 않는다.
            .variant = if (isSelected(item)) .selected else .surface,
            .paint = .{ .border_widths_px = .{ 0, 0, 0, 0 }, .shadow = .none },
            .action = row_action_id,
            .overflow = .clip,
        }, action_nodes);
    }

    const scroll_track = table.append(props.snapshot_generation, .scroll_track, true) catch return error.InsufficientActionBuffer;
    const scroll_thumb = table.append(props.snapshot_generation, .scroll_thumb, true) catch return error.InsufficientActionBuffer;

    const top = buffers.nodes[action_cursor..][0..4];
    // 탭 줄은 뷰 스위처와 요약 줄 **사이**다(§3.5.1 목업). **action을 붙이지 않는다** — 히스토리·에이전트
    // 탭은 P4·P5에 생기고, 지금 눌러도 갈 곳이 없다. 그래도 그리는 이유는 P1 계약이 "누를 수 없는
    // 컨트롤은 비활성으로 **표시**한다(감추지 않는다)"이기 때문이다: 탭 줄이 통째로 없으면 사용자는
    // 이 뷰가 목록 하나뿐인 화면이라고 읽는다.
    top[0] = tree.card(.{
        .id = NodeIds.tabs,
        .style = .{ .height = .{ .px = @floatFromInt(m.tab_h) } },
        .variant = .surface,
        .paint = .{ .background = .surface_bg, .border = .divider, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});
    top[1] = tree.card(.{
        .id = NodeIds.summary,
        .style = .{ .height = .{ .px = @floatFromInt(m.summary_h) } },
        .variant = .surface,
        // 아래 경계선 하나로 고정 chrome과 목록을 가른다(테두리 없는 요약 줄이 목록에 섞이지 않게).
        .paint = .{ .background = .surface_bg, .border = .divider, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});
    top[2] = tree.scrollArea(.{
        .id = NodeIds.content,
        .style = .{ .height = .{ .fill = 1 } },
        .scroll = .{
            .offset_px = props.scroll_offset_px,
            .content_h_px = props.content_h_px,
            .first_item_origin_y_px = props.content_first_item_origin_y_px,
            // 스크롤바가 목록 위에 겹치지 않게 오른쪽에 남겨 두는 자리. 스크롤바가 나타나고 사라져도
            // 행 폭이 reflow하지 않는다.
            .gutter_px = @floatFromInt(m.scrollbar_width + m.scrollbar_inset_x * 2),
            .metrics = m.scrollbarMetrics(),
            .track = .{ .id = NodeIds.scroll_track, .action = scroll_track, .paint = .{ .background = .inset_bg } },
            .thumb = .{ .id = NodeIds.scroll_thumb, .action = scroll_thumb, .paint = .{ .background = .muted_fg } },
            .drag = .{
                // thumb을 누른 것 자체가 스크롤 의사이고 그 지점에 경쟁할 click이 없으므로 threshold는 0이다.
                .payload = scroll_drag_payload,
                .axis = .vertical,
                .threshold_px = 0,
            },
        },
    }, row_nodes);
    // 브랜치 줄은 **목록 아래**다(2판 — §3.5). 브랜치를 못 잡았으면 높이 0으로 두어 그 줄이 아예 없다.
    top[3] = tree.card(.{
        .id = NodeIds.branch,
        .style = .{ .height = .{ .px = if (props.branch.len == 0) 0 else @floatFromInt(m.branch_h) } },
        .variant = .surface,
        .paint = if (props.branch.len == 0) .{} else .{ .background = .surface_bg, .border = .divider, .border_widths_px = .{ 1, 0, 0, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});

    // **root에는 outer style을 걸지 않는다**(`tree.build`가 `RootOuterStyle`로 거절한다). 크기는
    // `root_size`가 주고, 여기서 다시 선언하면 뷰포트의 출처가 둘이 된다.
    const root = tree.container(.{
        .id = NodeIds.root,
        .direction = .column,
        .overflow = .clip,
    }, top);

    const built = try tree.build(root, .{
        .root_size = .{ .width = props.viewport_px.width, .height = props.viewport_px.height },
        .max_entries = buffers.entries.len,
        // root → 고정 chrome/scroll area → 행 → 행 동작 버튼 넷이 최대 깊이다.
        .max_depth = 4,
    }, .{
        .entries = buffers.entries,
        .items = buffers.layout_items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    return .{ .tree = built, .actions = table.slice() };
}

fn isSelected(item: types.Item) bool {
    return switch (item) {
        .file => |file| file.selected,
        .section, .more, .notice => false,
    };
}

const std = @import("std");
const testing = std.testing;

fn testItems() [4]types.Item {
    return .{
        .{ .section = .{ .section = .staged, .count = 1, .collapsed = false, .action = .unstage } },
        .{ .file = .{ .name = "a.zig", .dir = "src/", .status = .modified, .letter = 'M', .added = 3, .removed = 1, .has_delta = true, .action = .unstage } },
        .{ .section = .{ .section = .changes, .count = 2, .collapsed = false, .action = .stage } },
        .{ .more = .{ .section = .changes, .hidden = 4 } },
    };
}

fn buildTest(props: types.Props, storage: anytype) !Frame {
    return build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
}

const Storage = struct {
    nodes: [32]tree.UiNode = undefined,
    entries: [40]tree.RectEntry = undefined,
    layout_items: [40]layout.Item = undefined,
    flex_scratch: [40]layout.FlexScratch = undefined,
    child_rects: [40]layout.UiRect = undefined,
    actions: [40]ids.Entry = undefined,
};

test "행마다 히트 사각형이 하나이고, 동작이 있는 행에만 버튼이 선다" {
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 300, .height = 400 },
        .items = &items,
        .branch = "main",
    }, &storage);

    // 네 항목이 전부 published tree에 있다.
    for (0..items.len) |index| try testing.expect(frame.tree.find(NodeIds.item(index)) != null);
    // 동작 버튼은 section(unstage)·file(unstage)·section(stage) 셋에만 있고 "모두 보기"에는 없다.
    try testing.expect(frame.tree.find(NodeIds.itemAction(0)) != null);
    try testing.expect(frame.tree.find(NodeIds.itemAction(1)) != null);
    try testing.expect(frame.tree.find(NodeIds.itemAction(2)) != null);
    try testing.expect(frame.tree.find(NodeIds.itemAction(3)) == null);

    // 고정 chrome 셋도 함께 선다.
    try testing.expect(frame.tree.find(NodeIds.summary) != null);
    try testing.expect(frame.tree.find(NodeIds.content) != null);
    try testing.expect(frame.tree.find(NodeIds.branch) != null);
}

test "행 높이는 DockMetrics가 정하고 뷰포트에 맞춰 줄어들지 않는다" {
    // 목록이 짧을 때 행이 세로로 늘어나면(또는 뷰포트에 맞춰 줄면) 스크롤 상한 계산과 그린 자리가 갈린다.
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 300, .height = 900 },
        .items = &items,
    }, &storage);
    const m = types.DockMetrics.resolve(1000);
    const row = frame.tree.entries[frame.tree.find(NodeIds.item(1)).?].rect;
    try testing.expectEqual(@as(f32, @floatFromInt(m.row_h)), row.height);
    const section = frame.tree.entries[frame.tree.find(NodeIds.item(0)).?].rect;
    try testing.expectEqual(@as(f32, @floatFromInt(m.section_h)), section.height);
}

test "브랜치를 못 잡으면 그 줄이 자리를 먹지 않는다" {
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 300, .height = 400 },
        .items = &items,
        .branch = "",
    }, &storage);
    const branch = frame.tree.entries[frame.tree.find(NodeIds.branch).?].rect;
    try testing.expectEqual(@as(f32, 0), branch.height);
}

test "버퍼가 모자라면 실패하고 반쯤 만든 tree를 내지 않는다" {
    // 호출처가 이 실패를 삼키면 도크가 통째로 멈추므로, 상한 산술은 `bufferSizes` 하나가 소유한다.
    const items = testItems();
    const sizes = bufferSizes(&items);
    try testing.expectEqual(items.len + 3 + 4, sizes.nodes); // 행 4 + 버튼 3 + 고정 4(탭·요약·목록·브랜치)
    var storage: Storage = .{};
    try testing.expectError(error.InsufficientNodeBuffer, build(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 300, .height = 400 },
        .items = &items,
    }, .{
        .nodes = storage.nodes[0 .. sizes.nodes - 1],
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    }));
}

test "action 표가 행마다 의도를 복원한다(히트테스트는 ID만 돌려준다)" {
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 300, .height = 400 },
        .items = &items,
    }, &storage);

    var saw_toggle = false;
    var saw_open = false;
    var saw_row_action = false;
    var saw_expand = false;
    for (frame.actions) |entry| switch (entry.intent) {
        .toggle_section => |section| {
            saw_toggle = true;
            try testing.expect(section == .staged or section == .changes);
        },
        .open_row => |index| {
            saw_open = true;
            try testing.expectEqual(@as(u32, 1), index); // 파일 행은 하나뿐이다
        },
        .row_action => |index| {
            saw_row_action = true;
            try testing.expectEqual(@as(u32, 1), index);
        },
        .expand_section => |section| {
            saw_expand = true;
            try testing.expectEqual(types.Section.changes, section);
        },
        .section_action, .scroll_thumb, .scroll_track => {},
    };
    try testing.expect(saw_toggle and saw_open and saw_row_action and saw_expand);
}

test "탭 줄은 요약 줄·목록 위에 있고 목록에서 자기 높이만큼 가져간다" {
    // 목업 순서: 뷰 스위처 → 탭 줄 → 요약 줄 → 목록 → 브랜치 줄. 순서가 어긋나면 "무엇을 커밋할
    // 것인가"를 고르기 전에 그 합계를 먼저 보게 된다. 그리고 탭 줄이 자리를 차지한 만큼 목록이
    // 줄지 않으면 목록이 브랜치 줄 아래로 흘러 잘린다.
    var storage: Storage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
    };
    const frame = try buildTest(props, &storage);

    const tabs = frame.tree.entries[frame.tree.find(NodeIds.tabs) orelse return error.MissingTabs].rect;
    const summary = frame.tree.entries[frame.tree.find(NodeIds.summary) orelse return error.MissingSummary].rect;
    const content = frame.tree.entries[frame.tree.find(NodeIds.content) orelse return error.MissingContent].rect;
    const branch = frame.tree.entries[frame.tree.find(NodeIds.branch) orelse return error.MissingBranch].rect;

    try testing.expect(tabs.y < summary.y);
    try testing.expect(summary.y < content.y);
    try testing.expect(content.y < branch.y);

    const m = types.DockMetrics.resolve(props.scale_milli);
    try testing.expectEqual(@as(f32, @floatFromInt(m.tab_h)), tabs.height);
    // 고정 chrome 셋을 뺀 나머지가 목록이다.
    try testing.expectEqual(
        props.viewport_px.height - @as(f32, @floatFromInt(m.tab_h + m.summary_h + m.branch_h)),
        content.height,
    );
}

test "탭 줄에는 action이 없다(누를 수 없는 컨트롤을 누를 수 있게 두지 않는다)" {
    // 히스토리·에이전트 탭은 P4·P5에 생긴다. 지금 action을 달면 눌러도 아무 일 없는 컨트롤이 된다 —
    // 그리는 것(비활성 표시)과 누를 수 있는 것은 다른 결정이다.
    var storage: Storage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
    };
    const frame = try buildTest(props, &storage);
    const tabs = frame.tree.entries[frame.tree.find(NodeIds.tabs) orelse return error.MissingTabs];
    try testing.expectEqual(@as(?tree.UiAction, null), tabs.action);
}
