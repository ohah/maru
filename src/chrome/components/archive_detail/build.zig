//! Bounded geometry and opaque action projection for ArchiveSessionDetailPanel.

const tree = @import("../../ui/tree.zig");
const ui_button = @import("../../ui/button.zig");
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
    // Button의 유일한 Text child. label이 tree에 들어오면서 그 identity도 published tree가 소유한다.
    pub const resume_label: u64 = 0x4152_0210;
    pub const reveal_label: u64 = 0x4152_0211;
    pub const focus_live_label: u64 = 0x4152_0212;

    pub fn turn(index: usize) u64 {
        return turn_base + index;
    }
};

/// Action label은 tree가 소유한다. 예전에는 view가 문자열 상수를 들고 직접 그려, 같은 label이
/// hit rect와 다른 곳에서 계산될 여지가 있었다. 단축키 표기는 계약대로 label이 명시로 포함하며
/// Button이 도메인별로 합성하지 않는다.
pub const labels = struct {
    // 두 아이콘은 등록된 Chrome SVG glyph다(recent.svg / document.svg). 지금은 label 문자열의
    // 일부로 그려지며, `leading_icon` 슬롯으로 옮기는 것은 registry 주입 경로가 생기는 후속이다.
    pub const resume_session = "\u{F000C} 터미널에서 이어하기  ⌘↵";
    pub const reveal = "\u{F0011} 로그 보기  ⌘L";
    pub const focus_live = "열린 세션으로 이동";
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

pub const BuildError = tree.BuildError || ui_button.ButtonError || error{ InsufficientNodeBuffer, InsufficientActionBuffer, TooManyTurns };

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
    // label은 Button의 자식이지만 호출자 버퍼에 살아 있어야 한다(값의 주소를 실으면 dangling).
    // 그래서 action마다 node 두 개 — Button 하나와 그 label 하나 — 를 쓴다.
    const needed_nodes = visible_turns.len + action_count * 2 + 5;
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

    // label 슬롯을 먼저 잡고, Button이 그 슬라이스를 자식으로 든다. 두 배열은 같은 버퍼의 서로 다른
    // 구간이라 label은 published tree가 살아 있는 동안 유효하다.
    const label_nodes = buffers.nodes[visible_turns.len..][0..action_count];
    const action_nodes = buffers.nodes[visible_turns.len + action_count ..][0..action_count];
    label_nodes[0] = tree.text(.{ .id = NodeIds.resume_label, .value = labels.resume_session });
    label_nodes[1] = tree.text(.{ .id = NodeIds.reveal_label, .value = labels.reveal });
    if (focus_live != null) label_nodes[2] = tree.text(.{ .id = NodeIds.focus_live_label, .value = labels.focus_live });
    // Button 계약 위반은 그대로 전파한다. 예전에는 셋 다 `InsufficientNodeBuffer`로 덮여, 미등록
    // 아이콘이나 floor 위반이 "버퍼가 작다"로 보고돼 버퍼를 키워도 영영 낫지 않았다.
    const dock_scale = props.scale_milli;
    action_nodes[0] = try actionNode(NodeIds.resume_session, resume_action, resume_enabled, action_count, .primary, label_nodes[0..1], dock_scale);
    action_nodes[1] = try actionNode(NodeIds.reveal, reveal, reveal_enabled, action_count, .secondary, label_nodes[1..2], dock_scale);
    if (focus_live) |action| action_nodes[2] = try actionNode(NodeIds.focus_live, action, true, action_count, .secondary, label_nodes[2..3], dock_scale);

    const top = buffers.nodes[visible_turns.len + action_count * 2 ..][0..5];
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
    // published entry = root + top 5 + turns + action_count buttons + action_count labels
    //                 = needed_nodes + 1.
    // `validateBuildInputs`가 네 scratch 버퍼를 **`max_entries` 기준**으로 검사하므로 이 값을 부풀리면
    // 실제 entry 수에 맞춘 올바른 호출자가 오히려 fail-close된다. 정확한 값만 요구한다.
    // 깊이는 Button이 label을 자식으로 들면서 한 단 깊어졌다(root > actions > button > label).
    const built = try tree.build(root, .{
        .root_size = props.viewport_px,
        .max_entries = needed_nodes + 1,
        .max_depth = 4,
    }, .{
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

/// Action 표면은 generic Button이다. 예전에는 `tree.card`를 눌리는 표면으로 쓰고 label을 view가
/// 따로 그렸다 — 그러면 label의 전경·정렬을 컴포넌트가 알고 있어야 하고, 두 번째 소비자가 같은
/// 결정을 다시 내린다. 이제 label은 Button의 유일한 Text child이므로 tree가 소유한다.
///
/// `variant`는 색을 직접 고르지 않고 의미를 고른다. 재개는 이 패널의 주 command라 `primary`,
/// 나머지는 `secondary`다. 비활성은 variant가 아니라 `action.enabled`가 표현하며 `paint_style`이
/// disabled를 언제나 마지막에 얹는다.
fn actionNode(
    id: u64,
    action: tree.UiAction,
    enabled: bool,
    action_count: usize,
    variant: tree.ButtonVariant,
    label: []const tree.UiNode,
    scale_milli: u32,
) ui_button.ButtonError!tree.UiNode {
    return ui_button.button(.{
        .id = id,
        // floor는 logical point이므로 이 스냅샷의 scale로 환산해야 한다. 넘기지 않으면 기본 1000이
        // 걸려 32 backing pixel 리터럴이 되고, 1×의 작은 cell에서는 행을 넘겨 clip되고 2×에서는
        // floor가 사실상 사라진다.
        .scale_milli = scale_milli,
        // `UiNode` validates a button both as its row child and as an independently composable
        // node. A definite percent share therefore keeps all action nodes materialized instead
        // of relying on a row-only `.fill` interpretation.
        .style = .{ .width = .{ .percent = 1.0 / @as(f32, @floatFromInt(action_count)) }, .height = .{ .percent = 1 } },
        .variant = variant,
        .action = .{ .id = action.id, .enabled = enabled },
        .overflow = .clip,
    }, label);
}

test "archive detail action identities disable stale source effects and omit absent live navigation" {
    const stale_turns = [_]types.Turn{
        .{ .role = .assistant, .text = "must not be republished" },
        .{ .role = .assistant, .text = "ignored beyond the ready cap" },
        .{ .role = .assistant, .text = "still ignored" },
        .{ .role = .assistant, .text = "must not fail the stale shell" },
    };
    const props = types.Props{ .viewport_px = .{ .width = 320, .height = 480 }, .cell_width_px = 8, .cell_height_px = 16, .snapshot_generation = 7, .state = .stale, .provider = .codex, .title = "title", .metadata = "metadata", .turns = &stale_turns, .focus_live_enabled = true };
    var nodes: [14]tree.UiNode = undefined;
    var entries: [16]tree.RectEntry = undefined;
    var items: [16]layout.Item = undefined;
    var scratch: [16]layout.FlexScratch = undefined;
    var rects: [16]layout.UiRect = undefined;
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
