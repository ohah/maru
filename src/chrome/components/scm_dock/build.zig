//! 소스 컨트롤 도크의 기하·action 투영(유계, 무할당).
//!
//! 호출자가 모든 버퍼를 준다. 실패한 후보 tree는 `ui.tree.build`에서 통째로 버려지므로 **반쯤 만들어진
//! 도크가 이전 스냅샷을 덮는 일이 없다**(Session Dock과 같은 규율).
//!
//! **상호작용 사각형은 전부 이 tree 하나에 속한다.** platform이 행 높이를 다시 곱해 두 번째 히트 영역을
//! 만들지 않는다 — 옛 셀 그리드 경로가 그렇게 갈려서 "그린 자리와 눌리는 자리"가 어긋났었다.

const badge = @import("../../ui/badge.zig");
const tokens = @import("../../tokens.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

/// 탭이 놓이는 **순서**. build가 칸을, view가 라벨을 이 순서로 읽는다 — 두 곳이 각자 배열을 들면
/// 라벨이 남의 칸에 그려진다.
pub const tab_order = [_]types.Tab{ .changes, .history, .agent };

pub const NodeIds = struct {
    pub const root: u64 = 0x5343_0000;
    pub const summary: u64 = 0x5343_0001;
    pub const content: u64 = 0x5343_0002;
    pub const branch: u64 = 0x5343_0003;
    pub const scroll_track: u64 = 0x5343_0004;
    pub const scroll_thumb: u64 = 0x5343_0005;
    pub const tabs: u64 = 0x5343_0006;
    pub const commit_box: u64 = 0x5343_0007;
    pub const commit_button: u64 = 0x5343_0008;

    /// 탭 하나의 칸. **칸을 나누는 결정은 여기(tree) 하나가 소유한다** — `view`가 자기 산수로 다시
    /// 나누면 "그린 자리와 눌리는 자리"의 주인이 둘이 된다(옛 셀 그리드 경로가 그렇게 갈렸다).
    /// 바로 위 뷰 스위처(`dock_view_bar`)가 같은 규율을 쓴다.
    pub const tab_base: u64 = 0x5343_2000;

    pub fn tab(index: usize) u64 {
        return tab_base + @as(u64, @intCast(index));
    }

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

/// 행 오른쪽 끝에 이미 앉아 있는 표식이 차지하는 폭(동작 버튼이 비켜야 하는 만큼).
///
/// 파일 행은 상태 문자, 그룹 헤더는 **개수 배지**다. 배지 폭은 자릿수·셀 폭·zoom의 함수라 상수로 어림할
/// 수 없어 `ui/badge`에게 **같은 함수로** 묻는다 — `view`가 그리는 자리와 `build`가 비키는 자리가 한
/// 출처에서 나와야 어긋나지 않는다.
fn rightMarkerExtent(item: types.Item, props: types.Props, m: types.DockMetrics) u32 {
    const base = m.inset_x + m.gap;
    return switch (item) {
        .section => |section| blk: {
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{section.count}) catch "0";
            const cols = @max(@as(u16, @intCast(text.len)), 1);
            const scale = if (props.scale_milli == 0) 1000 else props.scale_milli;
            const pill = badge.countPill(.{ .x = 0, .y = 0, .width = 100000, .height = @floatFromInt(m.section_h) }, .{
                .inset_x = m.inset_x,
                .label_cols = cols,
                .cell_width_px = @max(props.cell_width_px, 1),
                .scale_milli = scale,
                .fit = .snug,
                .label_role = .supporting,
            }) orelse break :blk base + m.status_extent;
            break :blk base + pill.box.w;
        },
        .file => base + m.status_extent,
        // 저장소 머리 줄에는 아직 행 동작 버튼이 없다(동작 아이콘 줄은 다음 조각) — 비켜설 것이 없다.
        .repo, .more, .notice => base,
    };
}

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
    // 행 + 행 동작 버튼 + 탭 칸 셋 + 고정 chrome 여섯(탭 줄·요약·스크롤 영역·브랜치 줄·커밋 상자·커밋 버튼).
    const node_count = items.len + action_buttons + tab_order.len + 6;
    return .{
        .nodes = node_count,
        // +1은 root, +2는 목록이 넘칠 때 scroll area가 preorder 안에서 내는 track/thumb다.
        // **선언 여부와 무관하게** 예약한다 — 자리를 props에 따라 늘렸다 줄이면 host가 미리 잡아 둘 수 없다.
        .entries = node_count + 3,
        .layout_items = node_count + 3,
        .flex_scratch = node_count + 3,
        .child_rects = node_count + 3,
        // 행 열기 + 행 동작 + 그룹 토글/일괄 동작은 위에서 센 것과 같은 상한 안이고, +2는 스크롤바,
        // +2는 커밋 상자(편집 진입)와 커밋 버튼이다.
        .actions = items.len * 2 + 4,
    };
}

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer };

fn actionOf(item: types.Item) types.RowAction {
    return switch (item) {
        .section => |section| section.action,
        .file => |file| file.action,
        // 저장소 머리 줄의 동작 아이콘 줄(새로고침·스테이지·커밋…)은 다음 조각이다 — 지금은 줄 전체가
        // 접기 버튼이다.
        .repo, .more, .notice => .none,
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
                .file => |file| .{ .row_action = file.model_index },
                .repo, .more, .notice => unreachable, // actionOf가 이미 `.none`으로 걸렀다
            };
            const action = table.append(props.snapshot_generation, intent, true) catch return error.InsufficientActionBuffer;
            slot[0] = tree.button(.{
                .id = NodeIds.itemAction(index),
                .style = .{
                    .width = .{ .px = @floatFromInt(m.action_extent) },
                    .height = .{ .px = @floatFromInt(m.action_extent) },
                    // **행의 오른쪽 끝 표식을 비켜 앉는다.** 파일 행은 상태 문자, 그룹 헤더는 개수 배지가
                    // 그 자리이고 둘 다 사라지면 안 되는 값이라(그 행이 선 그룹을 말한다) 비키는 쪽은
                    // 버튼이다. 겹치면 `+`가 상태 문자 위에 그려지고(실측), 배지는 **paint 전용이라
                    // 히트 사각형이 없어** 숫자를 눌렀는데 그룹 전체가 스테이지된다(실측).
                    //
                    // 배지 폭은 **`ui/badge`가 정한다** — 여기서 상수로 어림하면 자릿수가 늘 때 갈린다.
                    .margin = .{ .right = @floatFromInt(rightMarkerExtent(item, props, m)) },
                },
                // **이 버튼은 배경을 칠하지 않는다.** `ghost`의 기본 배경(`surface_bg`)은 비호버 행과 같은
                // 색이라 안 보이지만, 행 동작이 보이는 순간은 **언제나 그 행이 호버된 때**이고 그때 행
                // 배경은 `row_hover_bg`로 밝아진다 — 버튼만 원래 색으로 남아 **구멍처럼 어두운 칩**이
                // 된다(Lab 골든에서 실측: 행 밴드 (80,80,80) 위에 칩 (20,20,20)).
                //
                // 앞서 같은 자리에서 **테두리**를 고쳤는데(색 없는 테두리가 배경을 뚫었다) 채움은 남아
                // 있었다. 이 자리의 affordance는 글리프와 행 호버 밴드이지 칩이 아니므로 quad를 투명하게
                // 둔다 — `ghost`에 "배경 없음"이 없어서 `opacity`가 그 뜻을 내는 유일한 수단이다.
                .variant = .ghost,
                .paint = .{ .opacity = 0 },
                .action = action,
                .overflow = .clip,
            });
            break :blk slot;
        } else &.{};

        const row_intent: ?ids.Intent = switch (item) {
            .repo => |repo| .{ .toggle_repo = repo.index },
            .section => |section| .{ .toggle_section = section.section },
            .file => |file| .{ .open_row = file.model_index },
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
            // **모서리도 각지다.** 카드 기본 반지름을 그대로 두면 호버·선택 밴드의 양 끝이 말려, 촘촘한
            // 목록에서 그 행만 캡슐처럼 떠 보인다(사용자 지적 2026-08-16). 이 목록의 행은 카드가 아니라
            // 표의 한 줄이다 — 밴드가 줄 폭을 꽉 채워야 위아래 행과 같은 격자로 읽힌다.
            .paint = .{ .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 }, .shadow = .none },
            .action = row_action_id,
            .overflow = .clip,
        }, action_nodes);
    }

    const scroll_track = table.append(props.snapshot_generation, .scroll_track, true) catch return error.InsufficientActionBuffer;
    const scroll_thumb = table.append(props.snapshot_generation, .scroll_thumb, true) catch return error.InsufficientActionBuffer;

    // 탭 칸은 **레이아웃 엔진이 나눈다**(`fill = 1` 셋 = `flex: 1` 셋). 손으로 `width / 3`을 하면
    // 정수 나머지를 직접 처리해야 하고, 무엇보다 그 산수가 `view` 안에만 있어 **칸 rect가 남지 않는다** —
    // P4·P5에서 탭을 누를 수 있게 될 때 히트테스트가 폭을 한 번 더 나누게 되고, 그 순간 "각 탭이
    // 어디인가"의 주인이 둘이 된다.
    const tab_nodes = buffers.nodes[action_cursor..][0..tab_order.len];
    for (tab_nodes, 0..) |*node, index| {
        // **카드가 아니라 컨테이너다.** 카드는 언제나 quad를 하나 칠하는데, 자식은 부모보다 나중에
        // 칠해지므로 그 배경이 탭 줄의 **아래 divider를 덮는다**(실측: 그 선의 배경 대비가 +18에서
        // +3으로 떨어져 사실상 사라졌다). 칸에 필요한 것은 칠이 아니라 **자리와 rect 신원**뿐이고,
        // 컨테이너는 `visual = .none`이라 quad를 내지 않으면서 entry로는 남는다.
        //
        // 폭은 `width = .fill`이 아니라 `grow`로 나눈다. `fill`은 **그 노드 자신의 방향**을 기준으로
        // 검증되는데(`tree.containerFor`), 자식 없는 노드의 방향은 column이라 width가 cross축으로 걸린다.
        //
        // **P4·P5 주의**: 탭을 누를 수 있게 되면 컨테이너는 action을 못 실으므로 button으로 바꿔야 한다.
        // 그 순간 위의 덮어쓰기가 되살아난다(button도 quad를 칠한다) — 그때는 배경을 `paint`로 지우거나
        // divider를 탭 줄이 아닌 곳으로 옮겨야 한다. 칸을 나누는 자리는 그대로 여기다.
        node.* = tree.container(.{
            .id = NodeIds.tab(index),
            .style = .{ .flex = .{ .grow = 1 } },
            .overflow = .clip,
        }, &.{});
    }

    const top = buffers.nodes[action_cursor + tab_order.len ..][0..6];
    // 탭 줄은 뷰 스위처와 요약 줄 **사이**다(§3.5.1 목업). **action을 붙이지 않는다** — 히스토리·에이전트
    // 탭은 P4·P5에 생기고, 지금 눌러도 갈 곳이 없다. 그래도 그리는 이유는 P1 계약이 "누를 수 없는
    // 컨트롤은 비활성으로 **표시**한다(감추지 않는다)"이기 때문이다: 탭 줄이 통째로 없으면 사용자는
    // 이 뷰가 목록 하나뿐인 화면이라고 읽는다.
    // ── 순서(§3.5 3판): 탭 줄 → **커밋 입력 → 커밋 버튼** → 요약 → 목록 → 브랜치 줄.
    // 커밋 상자가 이 뷰의 주 동작인데 2판은 그것을 가장 먼 곳(맨 아래)에 뒀고, 목록이 길면 스크롤 밖으로
    // 밀려 보이지 않는 상태까지 생겼다. 브랜치 줄은 아래에 남는다 — 그건 "지금 어디에 있나"라는 **상태**다.
    top[0] = tree.card(.{
        .id = NodeIds.tabs,
        .style = .{ .height = .{ .px = @floatFromInt(m.tab_h) } },
        .direction = .row,
        .variant = .surface,
        .paint = .{ .background = .surface_bg, .border = .divider, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .overflow = .clip,
    }, tab_nodes);
    top[3] = tree.card(.{
        .id = NodeIds.summary,
        .style = .{ .height = .{ .px = @floatFromInt(m.summary_h) } },
        .variant = .surface,
        // 아래 경계선 하나로 고정 chrome과 목록을 가른다(테두리 없는 요약 줄이 목록에 섞이지 않게).
        .paint = .{ .background = .surface_bg, .border = .divider, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});
    top[4] = tree.scrollArea(.{
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
    top[5] = tree.card(.{
        .id = NodeIds.branch,
        .style = .{ .height = .{ .px = if (props.branch.len == 0) 0 else @floatFromInt(m.branch_h) } },
        .variant = .surface,
        .paint = if (props.branch.len == 0) .{} else .{ .background = .surface_bg, .border = .divider, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 1, 0, 0, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});

    // ── 커밋 입력·버튼(§3.5 목업 — 브랜치 줄 **아래**). 브랜치·`Fetch`는 커밋 직전에 확인하는 값이라
    // 커밋 버튼 옆이 제자리다.
    //
    // **상자 높이는 시각 행 수 × 행 높이**다(§12.2 — 내용을 따라 자라고 상한에서 멈춘다). 랩은 host가
    // 이미 계산했고(`text_area`) 컴포넌트는 그 결과인 `commit_rows`만 받는다 — 같은 계산이 두 곳이면
    // 상자 높이와 실제로 그려지는 줄 수가 갈린다.
    // 상자를 누르면 **편집이 시작된다**(P3c). caret 자리는 이 intent에 없다 — 그건 tree hit이 아니라
    // 글자 hit이라 좌표가 필요하고, host가 같은 published rect로 그 변환을 한다.
    const commit_focus = table.append(props.snapshot_generation, .commit_focus, true) catch return error.InsufficientActionBuffer;
    top[1] = tree.card(.{
        .id = NodeIds.commit_box,
        .style = .{ .height = .{ .px = @floatFromInt(m.commitBoxHeight(props.commit_rows)) } },
        .variant = .surface,
        // **포커스는 테두리로 말한다.** 채움을 바꾸면 글자 대비가 함께 흔들리고, 무엇보다 이 상자는
        // 값이 아니라 **입력란**이라 "지금 여기로 글자가 간다"가 테두리로 보이는 것이 관례다.
        .paint = .{
            .background = .inset_bg,
            .border = if (props.commit_edit.focused) .focus_accent else .divider,
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = if (props.commit_edit.focused) .{ 1, 1, 1, 1 } else .{ 1, 0, 0, 0 },
            .shadow = .none,
        },
        .action = commit_focus,
        .overflow = .clip,
    }, &.{});
    // **꺼져 있어도 action을 붙인다.** 히트 사각형을 없애면 tree가 상태에 따라 달라져 히트테스트가
    // 자기 자신을 쫓게 되고(행 동작 버튼과 같은 이유), 무엇보다 "왜 안 눌리는가"를 말할 기회가
    // 사라진다 — 켜졌는지는 host가 실제 index 상태로 다시 본다(쓰기 문서 §7).
    // **채운 버튼**이다(목업 `[커밋 ∨]`). 목록 행과 달리 이건 표의 한 줄이 아니라 **누르는 것**이라,
    // 배경이 있어야 누를 수 있는 자리로 읽힌다. 색은 테마 accent이고 글자는 배경색이다 — accent는
    // "사이드바 배경 위 글자로 읽히는 색"으로 고른 값이라 그 둘의 대비를 테마가 보장한다(배지와 같은 근거).
    //
    // 꺼졌을 때는 채우지 않는다(`inset_bg`) — 스테이지가 없으면 커밋할 것이 없고, 그 사실이 색으로 보여야
    // 한다(감추지 않고 비활성으로 **표시**한다).
    const commit_action = table.append(props.snapshot_generation, .commit, true) catch return error.InsufficientActionBuffer;
    top[2] = tree.card(.{
        .id = NodeIds.commit_button,
        .action = commit_action,
        .style = .{
            .height = .{ .px = @floatFromInt(m.commit_button_h) },
            // **좌우 여백 없이 폭을 꽉 채운다**(사용자 결정 2026-08-16). 도크가 좁아 안쪽으로 물리면
            // 버튼 면이 그만큼 작아지고, 이 뷰에서 가장 큰 동작이 가장 작은 표적이 된다.
            .margin = .{ .bottom = @floatFromInt(m.commit_pad_y) },
        },
        .variant = .surface,
        .paint = .{
            .background = if (props.commit_enabled) .accent_bar else .inset_bg,
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = .{ 0, 0, 0, 0 },
            .shadow = .none,
        },
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
        .repo, .section, .more, .notice => false,
    };
}

const std = @import("std");
const testing = std.testing;

fn testItems() [4]types.Item {
    return .{
        .{ .section = .{ .section = .staged, .count = 1, .collapsed = false, .action = .unstage } },
        // `model_index`를 **창 자리(1)와 다른 값**으로 둔다 — intent가 어느 축을 싣는지가 이 fixture의 요점이다.
        .{ .file = .{ .model_index = 42, .name = "a.zig", .dir = "src/", .status = .modified, .letter = 'M', .added = 3, .removed = 1, .has_delta = true, .action = .unstage } },
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
    // 행 4 + 버튼 3 + 탭 칸 3 + 고정 4(탭 줄·요약·목록·브랜치)
    try testing.expectEqual(items.len + 3 + tab_order.len + 6, sizes.nodes);
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
        // **모델 인덱스**를 싣는다(창 자리 1이 아니다). 창 자리를 실으면 스크롤한 뒤 누른 행과 열리는
        // 행이 어긋난다 — host가 그 값으로 모델을 다시 조회하기 때문이다.
        .open_row => |index| {
            saw_open = true;
            try testing.expectEqual(@as(u32, 42), index);
        },
        .row_action => |index| {
            saw_row_action = true;
            try testing.expectEqual(@as(u32, 42), index);
        },
        .expand_section => |section| {
            saw_expand = true;
            try testing.expectEqual(types.Section.changes, section);
        },
        .section_action, .scroll_thumb, .scroll_track, .commit_focus, .commit, .toggle_repo => {},
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
    // 고정 chrome을 전부 뺀 나머지가 목록이다 — 탭 줄·커밋 상자·커밋 버튼(아래 여백 포함)·요약·브랜치.
    const commit_h = m.commitBoxHeight(props.commit_rows) + m.commit_button_h + m.commit_pad_y;
    try testing.expectEqual(
        props.viewport_px.height - @as(f32, @floatFromInt(m.tab_h + m.summary_h + m.branch_h + commit_h)),
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

test "탭 칸 rect가 tree에 있고 줄을 균등하게 덮는다" {
    // 이 rect가 **존재한다**는 것이 이 변경의 요점이다. 없으면 P4·P5에서 히트테스트가 폭을 다시
    // 나누게 되고, 그 순간 "각 탭이 어디인가"의 주인이 둘이 된다(옛 셀 그리드 경로가 그렇게 갈렸다).
    for ([_]f32{ 180, 240, 331, 480, 1024 }) |width| {
        var storage: Storage = .{};
        const frame = try buildTest(.{
            .viewport_px = .{ .x = 0, .y = 0, .width = width, .height = 400 },
            .items = &.{},
            .branch = "main",
        }, &storage);

        const row = frame.tree.entries[frame.tree.find(NodeIds.tabs) orelse return error.MissingTabs].rect;
        var prev_right = row.x;
        for (tab_order, 0..) |_, index| {
            const entry = frame.tree.entries[frame.tree.find(NodeIds.tab(index)) orelse return error.MissingTab];
            // **칸은 칠하지 않는다.** 카드로 두면 자식이 부모보다 나중에 칠해지며 탭 줄의 아래 divider를
            // 덮는다(실측: 그 선의 배경 대비가 +18 → +3으로 떨어져 사실상 사라졌다).
            try testing.expect(entry.visual == .none);
            const slot = entry.rect;
            // 칸끼리 겹치지도 벌어지지도 않는다.
            try testing.expectEqual(prev_right, slot.x);
            // 셋이 같은 폭이다(정수 나머지는 레이아웃 엔진이 float으로 들고 있어 생기지 않는다).
            try testing.expectEqual(row.width / @as(f32, @floatFromInt(tab_order.len)), slot.width);
            try testing.expectEqual(row.height, slot.height);
            prev_right = slot.x + slot.width;
        }
        // 마지막 칸이 줄 오른쪽 끝에 정확히 닿는다 — 손으로 나눌 때 2px 모자라던 자리다.
        try testing.expectEqual(row.x + row.width, prev_right);
    }
}

test "행 동작 버튼은 상태 문자 자리를 침범하지 않는다" {
    // 둘 다 오른쪽 `inset_x`에 앉으면 `+`와 `M`이 **같은 픽셀에 겹친다**(호버 캡처로 실측). 상태 문자는
    // 그 행이 선 그룹을 말하는 값이라 호버 중에도 사라지면 안 되므로, 비키는 쪽은 버튼이다.
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
    }, &storage);

    const row = frame.tree.entries[frame.tree.find(NodeIds.item(1)) orelse return error.MissingRow].rect;
    const button = frame.tree.entries[frame.tree.find(NodeIds.itemAction(1)) orelse return error.MissingAction].rect;
    const m = types.DockMetrics.resolve(1000);

    // 상태 문자가 앉는 자리(행 오른쪽 끝에서 `inset_x` 안쪽, 폭 `status_extent`).
    const status_left = row.x + row.width - @as(f32, @floatFromInt(m.inset_x + m.status_extent));
    const button_right = button.x + button.width;
    try testing.expect(button_right <= status_left);
}

test "도크의 카드는 전부 각진 모서리다(목록은 표이지 캡슐 묶음이 아니다)" {
    // 카드 기본 반지름을 그대로 두면 행·탭 줄·요약 줄·브랜치 줄이 각자 둥근 캡슐로 떠 보인다. 이 도크의
    // 줄들은 **표의 행**이라 폭을 꽉 채워야 위아래가 같은 격자로 읽힌다(사용자 지적 2026-08-16).
    var storage: Storage = .{};
    const items = testItems();
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
    }, &storage);

    for (frame.tree.entries) |entry| {
        switch (entry.visual) {
            .card => |visual| {
                const radii = visual.paint.corner_radii_px orelse continue;
                for (radii) |r| try testing.expectEqual(@as(u16, 0), r);
            },
            else => {},
        }
    }
}

test "커밋 상자는 탭 줄 아래·요약 위이고 내용을 따라 자란다" {
    // §3.5 **3판** 순서: 탭 줄 → 커밋 입력 → 커밋 버튼 → 요약 → 목록 → 브랜치 줄. 커밋 상자가 이 뷰의
    // 주 동작인데 2판은 그것을 맨 아래에 뒀고, 목록이 길면 스크롤 밖으로 밀려 보이지 않았다.
    // 브랜치 줄은 아래에 남는다 — 그건 "지금 어디에 있나"라는 **상태**다.
    var storage: Storage = .{};
    const one = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &.{},
        .branch = "main",
        .commit_rows = 1,
    }, &storage);
    const tabs = one.tree.entries[one.tree.find(NodeIds.tabs) orelse return error.MissingTabs].rect;
    const box = one.tree.entries[one.tree.find(NodeIds.commit_box) orelse return error.MissingBox].rect;
    const button = one.tree.entries[one.tree.find(NodeIds.commit_button) orelse return error.MissingButton].rect;
    const summary = one.tree.entries[one.tree.find(NodeIds.summary) orelse return error.MissingSummary].rect;
    const branch = one.tree.entries[one.tree.find(NodeIds.branch) orelse return error.MissingBranch].rect;
    try testing.expect(tabs.y < box.y);
    try testing.expect(box.y < button.y);
    try testing.expect(button.y < summary.y);
    try testing.expect(summary.y < branch.y); // 브랜치는 여전히 바닥이다

    // **버튼은 도크 폭을 꽉 채운다.** 안쪽으로 물리면 이 뷰에서 가장 큰 동작이 가장 작은 표적이 된다.
    try testing.expectEqual(@as(f32, 0), button.x);
    try testing.expectEqual(@as(f32, 320), button.width);

    // 시각 행이 늘면 상자가 자란다(§12.2 — 내용을 따라 자라고 상한에서 멈춘다).
    var storage3: Storage = .{};
    const three = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &.{},
        .branch = "main",
        .commit_rows = 3,
    }, &storage3);
    const grown = three.tree.entries[three.tree.find(NodeIds.commit_box) orelse return error.MissingBox].rect;
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commitBoxHeight(1))), box.height);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commitBoxHeight(3))), grown.height);
    // 여백은 행 수와 무관하게 위아래 한 번씩이다 — 행이 늘어도 여백이 같이 불어나지 않는다.
    try testing.expectEqual(
        @as(f32, @floatFromInt(m.commit_row_h * 2)),
        grown.height - box.height,
    );
}

test "커밋 상자와 버튼은 **꺼져 있어도** 히트 사각형을 갖는다 (P3c)" {
    // 히트 사각형을 상태에 따라 없애면 tree가 포인터 상태를 따라 달라져 히트테스트가 자기 자신을
    // 쫓게 되고(행 동작 버튼과 같은 이유), 무엇보다 "왜 안 눌리는가"를 말할 기회가 사라진다.
    // 켜졌는지는 host가 실제 index 상태로 다시 본다(쓰기 문서 §7).
    var storage: Storage = .{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &.{},
        .branch = "main",
        .commit_enabled = false, // 스테이지 0건 — 그래도 누를 수는 있어야 한다
    }, &storage);
    const button = frame.tree.entries[frame.tree.find(NodeIds.commit_button) orelse return error.MissingButton];
    const box = frame.tree.entries[frame.tree.find(NodeIds.commit_box) orelse return error.MissingBox];
    const button_action = button.action orelse return error.MissingButtonAction;
    const box_action = box.action orelse return error.MissingBoxAction;
    // 두 컨트롤은 **서로 다른 intent**다 — 같은 값이면 상자를 눌렀는데 커밋이 돈다.
    try testing.expect(button_action.id != box_action.id);
    var saw_commit = false;
    var saw_focus = false;
    for (frame.actions) |entry| switch (entry.intent) {
        .commit => saw_commit = true,
        .commit_focus => saw_focus = true,
        else => {},
    };
    try testing.expect(saw_commit and saw_focus);
}

test "커밋 상자는 편집 중일 때 테두리로 그 사실을 말한다" {
    // 채움을 바꾸면 글자 대비가 함께 흔들린다. 이 상자는 값이 아니라 **입력란**이라 "지금 여기로
    // 글자가 간다"가 테두리로 보이는 것이 관례다.
    var idle_storage: Storage = .{};
    const idle = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
    }, &idle_storage);
    var focus_storage: Storage = .{};
    const focused = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .commit_edit = .{ .focused = true },
    }, &focus_storage);
    const idle_box = idle.tree.entries[idle.tree.find(NodeIds.commit_box) orelse return error.MissingBox];
    const focus_box = focused.tree.entries[focused.tree.find(NodeIds.commit_box) orelse return error.MissingBox];
    try testing.expectEqual(tokens.ColorRole.divider, idle_box.visual.card.paint.border.?);
    try testing.expectEqual(tokens.ColorRole.focus_accent, focus_box.visual.card.paint.border.?);
    // **높이는 안 바뀐다** — 포커스로 상자가 자라면 그 아래 목록이 통째로 밀린다.
    try testing.expectEqual(idle_box.rect.height, focus_box.rect.height);
}
