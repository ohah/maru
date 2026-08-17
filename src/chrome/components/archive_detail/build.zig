//! ArchiveSessionDetailPanel의 bounded geometry·opaque action 투영이다.

const icons = @import("../../../icons.zig");
const i18n = @import("../../../i18n.zig"); // 표시 문자열 단일 출처
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
/// 액션 라벨은 **아이콘 · 이름 · 단축키 셋으로 나눠서** 든다(i18n 계약 §6.2).
///
/// 예전에는 `icons.utf8(.recent) ++ " 터미널에서 이어하기  ⌘↵"` 처럼 한 문자열이었다 — 계약이
/// "최악 사례가 셋을 다 갖는다"고 지목한 바로 그 자리다. 그러면 (1) 아이콘을 바꾸려면 번역 테이블을
/// 고쳐야 하고, (2) 단축키가 keybinding 이 아니라 **문장에서** 오고, (3) 번역자가 정렬 공백까지 받는다.
///
/// 조립은 `renderActionLabel` 이 버퍼에 한다 — 세 조각의 **경계가 코드에 남아** 나중에 아이콘을
/// `leading_icon` 슬롯으로 옮기거나 단축키를 keybinding 에서 끌어올 때 그 자리가 보인다.
pub const ActionLabel = struct {
    icon: []const u8,
    name_key: i18n.Key,
    shortcut: []const u8,
};

pub const labels = struct {
    // 두 아이콘은 등록된 Chrome SVG glyph다(recent.svg / document.svg).
    pub const resume_session: ActionLabel = .{ .icon = icons.utf8(.recent), .name_key = .ad_resume_action, .shortcut = "\u{2318}\u{21B5}" };
    pub const reveal: ActionLabel = .{ .icon = icons.utf8(.document), .name_key = .ad_reveal_action, .shortcut = "\u{2318}L" };
    pub const focus_live: ActionLabel = .{ .icon = "", .name_key = .common_focus_live, .shortcut = "" };
};

/// `label` 을 `buf` 에 조립한다 — `<icon> <name>  <shortcut>`(아이콘·단축키가 없으면 그 자리도 없다).
/// 넘치면 자른다(폭은 호출자가 판단한다 — 여기서는 버퍼만 지킨다).
/// 조립 결과가 사는 자리.
///
/// **`tree.text` 는 값을 복사하지 않고 슬라이스를 그대로 든다** — 그래서 조립 버퍼는 `Frame` 보다
/// 오래 살아야 한다. 지역 배열로 두면 함수가 끝나는 순간 dangling 이 되고(빌드도 테스트도 안 잡는다),
/// `Buffers` 에 넣으면 호출부 전부가 그것을 넘겨야 하며 하나라도 빠뜨리면 빈 슬라이스에 인덱싱해
/// 죽는다(실제로 그렇게 한 번 죽였다).
///
/// 그래서 모듈 레벨에 둔다. 이 컴포넌트의 build 는 **UI 스레드에서 프레임마다 한 번** 불리고
/// (i18n 계약 §5.2 의 소유 규칙과 같은 스레드), 다음 프레임이 같은 자리를 덮는다 — 발행된 tree 는
/// 그 프레임 안에서만 읽히므로 덮이는 시점이 문제가 되지 않는다.
var action_label_storage: [3][64]u8 = undefined;

pub fn renderActionLabel(buf: []u8, label: ActionLabel) []const u8 {
    var used: usize = 0;
    const put = struct {
        fn f(dst: []u8, at: *usize, src: []const u8) void {
            const n = @min(src.len, dst.len - at.*);
            @memcpy(dst[at.* .. at.* + n], src[0..n]);
            at.* += n;
        }
    }.f;
    if (label.icon.len > 0) {
        put(buf, &used, label.icon);
        put(buf, &used, " ");
    }
    put(buf, &used, i18n.t(label.name_key));
    if (label.shortcut.len > 0) {
        put(buf, &used, "  ");
        put(buf, &used, label.shortcut);
    }
    return buf[0..used];
}

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

/// text·paint·hover·pointer dispatch가 함께 쓰는 rect tree를 정확히 하나만 만든다. 컴포넌트에는
/// 폴백 행 계산이 없다 — 숨김/비활성 action은 이 tree와 action table에 인코딩된다.
pub fn build(props: types.Props, buffers: Buffers) BuildError!Frame {
    // stale/unavailable 결과는 source identity가 거부되는 중에도 옛 DTO를 그대로 들고 있을 수 있다.
    // 그 옛 값에서 turn이나 라이브 세션 affordance를 만들지 않는다 — state 경계는 흐린 paint가 아니라
    // tree/action publish 전에 강제한다.
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
    label_nodes[0] = tree.text(.{ .id = NodeIds.resume_label, .value = renderActionLabel(&action_label_storage[0], labels.resume_session) });
    label_nodes[1] = tree.text(.{ .id = NodeIds.reveal_label, .value = renderActionLabel(&action_label_storage[1], labels.reveal) });
    if (focus_live != null) label_nodes[2] = tree.text(.{ .id = NodeIds.focus_live_label, .value = renderActionLabel(&action_label_storage[2], labels.focus_live) });
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
