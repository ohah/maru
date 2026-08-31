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
    /// 브랜치 줄의 원격 갱신 버튼(P6). 고정 chrome이라 항목 차선을 쓰지 않는다.
    pub const fetch: u64 = 0x5343_0009;
    /// 그 옆의 `∨`(P6b) — `push`/`pull`을 터미널에 넣어 주는 보조 메뉴를 연다.
    pub const remote_menu: u64 = 0x5343_000A;

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
    const item_stride: u64 = 4;

    pub fn item(index: usize) u64 {
        return item_base + @as(u64, @intCast(index)) * item_stride;
    }

    pub fn itemAction(index: usize) u64 {
        return item(index) + 1;
    }

    /// 저장소 머리 줄의 동작 버튼(0 = 새로고침, 1 = 전체 스테이지). 커밋 버튼의 면과 같은 자리를
    /// 쓰지만 **항목 종류가 다르므로 겹치지 않는다**(한 항목이 둘 다일 수 없다).
    pub fn repoAction(index: usize, slot: usize) u64 {
        return item(index) + 2 + @as(u64, @intCast(slot));
    }

    /// 커밋 버튼의 **면**. 그 줄은 면(28px)과 아래 여백(8px)으로 되어 있고 **칠은 면만** 받는다 —
    /// 줄 전체를 칠하면 파랑이 여백까지 덮어 글자가 그 띠의 가운데보다 위에 앉는다(사용자 지적
    /// 2026-08-17). 호버·눌림 해석도 이 노드가 받아야 여백을 지나갈 때 면이 밝아지지 않는다.
    pub fn itemFace(index: usize) u64 {
        return item(index) + 2;
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
        // 머리 줄의 동작 버튼은 **가장 바깥**에 앉으므로 비켜설 것이 없다(자리를 비우는 쪽은 브랜치 칩과
        // 개수 배지이고, 그건 `view.repoRow`가 같은 상수로 한다 — ②c).
        // 커밋 줄은 오른쪽 끝에 **짧은 해시**가 앉지만 동작 버튼이 없어 비켜설 것이 없다.
        .repo, .commit, .turn, .commit_file, .load_more, .commit_box, .commit_button, .more, .notice, .blocker => base,
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
/// 목록 **글자**를 자를 뷰포트 — published tree 의 `content` 사각형이다.
///
/// 이것이 없으면 measured CoreText 경로가 자를 사각형을 못 받는다. quad 는 `effective_clip` 으로
/// 잘리는데 글자는 안 잘려서, **반쯤 스크롤된 첫 행의 라벨이 목록 위 고정 chrome(요약 줄) 위에
/// 그려진다**(2026-08-25 사용자 지적 — 골든 캡처에서 발견). `view` 가 행 글자에 이미
/// `scroll_clipped = true` 를 달아 두었으므로(draw.zig 계약) 빠져 있던 것은 **뷰포트뿐**이었다.
///
/// **host 마다 다시 계산하지 않는다** — 제품 host 와 Lab 이 갈리면 골든이 제품과 다른 그림을
/// 증명한다(Session Dock 의 같은 헬퍼가 그 이유를 소유한다).
pub fn scrollTextViewport(published: tree.UiRectTree) ?layout.UiRect {
    const index = published.find(NodeIds.content) orelse return null;
    const rect = published.entries[index].rect;
    if (rect.width <= 0 or rect.height <= 0) return null;
    return rect;
}

pub fn bufferSizes(items: []const types.Item) BufferSizes {
    var action_buttons: usize = 0;
    for (items) |item| if (actionOf(item) != .none) {
        action_buttons += 1;
    };
    // 커밋 버튼 줄은 **면 노드 하나를 더** 갖고, 저장소 머리 줄은 **동작 버튼 둘**을 더 갖는다(②c).
    var faces: usize = 0;
    for (items) |item| switch (item) {
        .commit_button => faces += 1,
        .repo => faces += repo_action_count,
        else => {},
    };
    // 행 + 행 동작 버튼 + 커밋 버튼 면 + 탭 칸 셋 + 고정 chrome 넷(탭 줄·요약·스크롤 영역·브랜치 줄).
    // **커밋 상자·버튼은 고정이 아니다**(②b) — 저장소마다 하나씩이라 `items`에 들어 있다.
    // 마지막 +2는 브랜치 줄의 **원격 갱신 버튼과 `∨`**다(P6·P6b) — 원격이 없어도 자리는 늘 있으므로(비활성으로
    // 그린다) props에 따라 늘었다 줄지 않는다. 세지 않으면 목록이 꽉 찬 프레임에서 노드 버퍼가 모자라
    // **도크가 통째로 빈다**.
    const node_count = items.len + action_buttons + faces + tab_order.len + 4 + 2;
    return .{
        .nodes = node_count,
        // +1은 root, +2는 목록이 넘칠 때 scroll area가 preorder 안에서 내는 track/thumb다.
        // **선언 여부와 무관하게** 예약한다 — 자리를 props에 따라 늘렸다 줄이면 host가 미리 잡아 둘 수 없다.
        .entries = node_count + 3,
        .layout_items = node_count + 3,
        .flex_scratch = node_count + 3,
        .child_rects = node_count + 3,
        // 행 열기 + 행 동작 + 그룹 토글/일괄 동작 + 커밋 상자·버튼은 전부 **행당 둘** 상한 안이고,
        // +2는 스크롤바다.
        // 행당 둘이 상한인데 **머리 줄만 셋**이다(접기 + 동작 둘 — ②c). +2는 스크롤바다.
        // +2는 브랜치 줄의 원격 갱신과 그 보조 메뉴다(P6·P6b).
        .actions = items.len * 2 + faces + tab_order.len + 2 + 2,
    };
}

/// 머리 줄에 앉는 동작 버튼 수(새로고침·전체 스테이지). 커밋 ✓는 **넣지 않는다** — 그 그룹 안에 이미
/// 커밋 버튼 줄이 있어 같은 동작이 두 자리가 된다.
pub const repo_action_count: usize = 2;

pub const BuildError = tree.BuildError || error{ InsufficientNodeBuffer, InsufficientActionBuffer };

/// 행 하나의 칠. 목록 줄은 전부 각지고 테두리가 없지만, **커밋 줄 둘만 다르다**.
fn rowPaint(item: types.Item) tree.PaintStyle {
    const flat: tree.PaintStyle = .{ .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 0, 0 }, .shadow = .none };
    return switch (item) {
        .commit_box => |box| .{
            .background = .inset_bg,
            .border = if (box.edit.focused) .focus_accent else .divider,
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = if (box.edit.focused) .{ 1, 1, 1, 1 } else .{ 1, 0, 1, 0 },
            .shadow = .none,
            // **호버로 면이 밝아지지 않는다.** 여기서 마우스가 뜻하는 것은 "누를 수 있다"가 아니라
            // "여기에 caret을 놓는다"이고 그건 커서 모양이 말한다(사용자 지적 2026-08-17).
            .state_fill = false,
        },
        // 펼친 커밋·턴의 파일 줄은 **한 단 들어간 면**에 앉는다. 그 묶음이 바로 위 항목에 속한다는 사실을
        // 세로 안내선(`view.childRail`)과 면이 **함께** 말한다 — 들여쓰기 하나로는 좁은 도크에서 약해서,
        // 사용자 캡처에서 파일 목록이 목록 전체의 다음 항목처럼 보였다(2026-08-27).
        //
        // **고른 줄은 예외다**: 여기서 면을 지정하면 `selected` variant 의 밴드를 덮어써, 지금 열어 둔
        // 비교가 목록에서 사라진다(`resolveCard` 는 paint override 를 variant 뒤에 얹는다).
        .commit_file => |file| if (file.selected) flat else .{
            .background = .inset_bg,
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = .{ 0, 0, 0, 0 },
            .shadow = .none,
        },
        // 고른 커밋은 목록에서 **선택 밴드**로 말한다(파일 행이 `selected` variant를 쓰는 것과 같다).
        // **버튼 줄 자체는 칠하지 않는다** — 칠은 면 노드가 받는다(아래 여백까지 파래지면 글자가 그
        // 띠의 가운데보다 위에 앉는다).
        else => flat,
    };
}

/// 커밋 버튼의 **면** 칠. 채운 면이다(누르는 것이라 면이 보여야 한다). 꺼졌으면 채우지 않는다.
fn commitFacePaint(enabled: bool) tree.PaintStyle {
    return .{
        .background = if (enabled) .accent_bar else .inset_bg,
        .corner_radii_px = .{ 0, 0, 0, 0 },
        .border_widths_px = .{ 0, 0, 0, 0 },
        .shadow = .none,
    };
}

/// 그 줄 위에서 마우스가 무엇이라고 말하는가.
fn rowCursor(item: types.Item) tree.CursorHint {
    return switch (item) {
        // 상자는 누르는 것이 아니라 **caret이 서는 자리**다.
        .commit_box => .text,
        .repo, .section, .file, .more, .commit, .turn, .commit_file, .load_more => .press,
        // 안내는 상태 진술이지 컨트롤이 아니다(action도 없다).
        .notice, .blocker => .auto,
        // 버튼의 커서는 **면 노드**가 든다(아래 여백은 버튼이 아니다).
        .commit_button => .auto,
    };
}

fn actionOf(item: types.Item) types.RowAction {
    return switch (item) {
        .section => |section| section.action,
        .file => |file| file.action,
        // 머리 줄의 동작은 `RowAction`(스테이지/언스테이지) 어휘가 아니다 — 자기 버튼 둘을 따로 낸다(②c).
        .repo, .commit_box, .commit_button, .more, .notice, .blocker, .commit, .turn, .commit_file, .load_more => .none,
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
        // **좁으면 동작 버튼을 아예 만들지 않는다.** 자리를 안 비운 채 노드만 남기면 호버할 때 버튼이
        // 이름 위에 그려진다 — 그 판정은 `view` 와 **같은 함수**(`rowActionFits`)가 소유한다.
        const action_fits = m.rowActionFits(props.viewport_px.width);
        const action_nodes: []tree.UiNode = if (row_action != .none and action_fits) blk: {
            const slot = buffers.nodes[action_cursor .. action_cursor + 1];
            action_cursor += 1;
            const intent: ids.Intent = switch (item) {
                .section => |section| .{ .section_action = .{ .repo_index = section.repo_index, .section = section.section } },
                .file => |file| .{ .row_action = .{ .repo_index = file.repo_index, .model_index = file.model_index } },
                .repo, .commit_box, .commit_button, .more, .notice, .blocker, .commit, .turn, .commit_file, .load_more => unreachable, // actionOf가 이미 `.none`으로 걸렀다
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
                .cursor = .press,
                .overflow = .clip,
            });
            break :blk slot;
        } else &.{};

        // **머리 줄은 동작 버튼 둘을 자식으로 갖는다**(②c — 새로고침·전체 스테이지). 히트 사각형은
        // 늘 있고 글리프만 호버를 따른다(파일 행과 같은 규율): `build`는 포인터 상태를 모르고, 무엇보다
        // 호버할 때만 선언하면 tree가 포인터마다 달라져 히트테스트가 자기 자신을 쫓는다.
        if (item == .repo) {
            const repo = item.repo;
            const slots = buffers.nodes[action_cursor..][0..repo_action_count];
            action_cursor += repo_action_count;
            const intents = [repo_action_count]ids.Intent{
                .{ .refresh_repo = repo.index },
                .{ .stage_all_repo = repo.index },
            };
            // 새로고침은 읽기라 언제나 켠다. 전체 스테이지는 그 저장소를 읽었을 때만 — **꺼져도 그린다**
            // (감추면 "왜 안 눌리는가"를 말할 기회가 사라진다).
            const enabled = [repo_action_count]bool{ true, repo.can_stage_all };
            for (slots, 0..) |*slot, action_index| {
                const action = table.append(
                    props.snapshot_generation,
                    intents[action_index],
                    enabled[action_index],
                ) catch return error.InsufficientActionBuffer;
                slot.* = tree.button(.{
                    .id = NodeIds.repoAction(index, action_index),
                    .style = .{
                        .width = .{ .px = @floatFromInt(m.action_extent) },
                        .height = .{ .px = @floatFromInt(m.action_extent) },
                        .margin = .{ .right = @floatFromInt(if (action_index + 1 == repo_action_count) m.inset_x else m.gap) },
                    },
                    // 행 동작 버튼과 같은 규율: 칠하지 않는다(호버 밴드 위에서 구멍처럼 보인다).
                    .variant = .ghost,
                    .paint = .{ .opacity = 0 },
                    .action = action,
                    .cursor = .press,
                    .overflow = .clip,
                });
            }
            const toggle = table.append(
                props.snapshot_generation,
                .{ .toggle_repo = repo.index },
                true,
            ) catch return error.InsufficientActionBuffer;
            node.* = tree.card(.{
                .id = NodeIds.item(index),
                .style = .{ .height = .{ .px = @floatFromInt(m.itemHeight(item)) } },
                .direction = .row,
                .justify = .end,
                .align_items = .center,
                .variant = .surface,
                .paint = rowPaint(item),
                .action = toggle,
                .cursor = rowCursor(item),
                .overflow = .clip,
            }, slots);
            continue;
        }

        // 커밋 버튼 줄은 **면 노드**를 자식으로 갖는다. 칠도 action도 그 면이 받는다 — 줄 전체가
        // 칠해지면 파랑이 아래 여백까지 덮어 글자가 띠의 가운데보다 위에 앉고(사용자 지적 2026-08-17),
        // action이 줄에 있으면 그 여백을 눌러도 커밋이 걸린다.
        if (item == .commit_button) {
            const button = item.commit_button;
            const slot = buffers.nodes[action_cursor .. action_cursor + 1];
            action_cursor += 1;
            const face_action = table.append(
                props.snapshot_generation,
                .{ .commit = button.repo_index },
                true,
            ) catch return error.InsufficientActionBuffer;
            // **카드다**(버튼 노드가 아니라). 호버·눌림 해석이 `paint_style.resolveCard`를 지나야 하고
            // 라벨 색도 그 해석 결과에서 나온다 — 줄 카드들과 같은 길을 쓴다.
            slot[0] = tree.card(.{
                .id = NodeIds.itemFace(index),
                .style = .{ .height = .{ .px = @floatFromInt(m.commit_button_h) }, .flex = .{ .grow = 1 } },
                .variant = .surface,
                .paint = commitFacePaint(button.enabled),
                .action = face_action,
                // 누를 수 있는 면이라고 **컴포넌트가 말한다** — host가 intent로 다시 추론하지 않는다.
                .cursor = .press,
                .overflow = .clip,
            }, &.{});
            node.* = tree.card(.{
                .id = NodeIds.item(index),
                .style = .{ .height = .{ .px = @floatFromInt(m.itemHeight(item)) } },
                .direction = .row,
                .justify = .start,
                .align_items = .start,
                .variant = .surface,
                .paint = rowPaint(item),
                .overflow = .clip,
            }, slot);
            continue;
        }

        const row_intent: ?ids.Intent = switch (item) {
            // 머리 줄은 위에서 자기 버튼들과 함께 세웠다.
            .repo => unreachable,
            // 상자와 버튼은 **어느 저장소인지 싣는다**(②b) — 안 실으면 아래 그룹의 상자를 눌렀는데
            // 위 그룹이 편집되거나, 더 나쁘게는 다른 저장소로 커밋된다.
            .commit_box => |box| .{ .commit_focus = box.repo_index },
            // 버튼은 위에서 **면 노드**가 가져갔다(칠·action 둘 다).
            .commit_button => unreachable,
            .section => |section| .{ .toggle_section = section.section },
            .file => |file| .{ .open_row = .{ .repo_index = file.repo_index, .model_index = file.model_index } },
            .more => |more| .{ .expand_section = more.section },
            // 커밋 줄 클릭은 **고르기**다(P4). 그 커밋의 diff를 여는 것은 P4b이고, 지금 여는 것이
            // 없는데 intent만 실으면 host가 "무엇을 열지" 두 곳에서 정하게 된다.
            .commit => |commit| .{ .select_commit = commit.index },
            .load_more => .load_more_commits,
            .commit_file => |file| if (file.from_turn)
                .{ .open_turn_file = file.index }
            else
                .{ .open_commit_file = file.index },
            .turn => |turn| .{ .select_turn = turn.index },
            // 안내는 진술이지 컨트롤이 아니다 — action을 붙이지 않는다.
            .notice, .blocker => null,
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
            // 커밋 상자는 **입력란**이라 다른 줄과 다른 면을 갖는다: 눌러 쓰는 자리라는 사실이 보여야
            // 하고(움푹한 배경), 편집 중임은 **테두리**로 말한다 — 채움을 바꾸면 글자 대비가 함께 흔들린다.
            // 버튼은 채운 면이다(누르는 것이라 면이 보여야 한다). 꺼졌으면 채우지 않는다.
            .paint = rowPaint(item),
            // **모서리도 각지다.** 카드 기본 반지름을 그대로 두면 호버·선택 밴드의 양 끝이 말려, 촘촘한
            // 목록에서 그 행만 캡슐처럼 떠 보인다(사용자 지적 2026-08-16). 이 목록의 행은 카드가 아니라
            // 표의 한 줄이다 — 밴드가 줄 폭을 꽉 채워야 위아래 행과 같은 격자로 읽힌다.
            .action = row_action_id,
            // **커서도 이 층의 사실이다.** 상자는 글자를 놓는 자리(I-beam), 누를 수 있는 줄은 손,
            // 안내는 진술이라 할 말이 없다.
            .cursor = rowCursor(item),
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
        // **P4에서 버튼이 됐다.** 위 주석이 예고한 자리다: 컨테이너는 action을 실을 수 없어 탭이
        // 눌리지 않았다. 버튼은 quad를 칠하므로 **투명하게** 둔다 — 안 그러면 그 배경이 탭 줄 아래
        // divider를 덮는다(컨테이너를 쓰던 이유가 그것이었다).
        const tab_action = table.append(
            props.snapshot_generation,
            .{ .select_tab = tab_order[index] },
            true,
        ) catch return error.InsufficientActionBuffer;
        node.* = tree.button(.{
            .id = NodeIds.tab(index),
            .style = .{ .flex = .{ .grow = 1 } },
            .variant = .ghost,
            .paint = .{ .opacity = 0 },
            .action = tab_action,
            .cursor = .press,
            .overflow = .clip,
        });
    }

    const top = buffers.nodes[action_cursor + tab_order.len ..][0..4];
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
    top[1] = tree.card(.{
        .id = NodeIds.summary,
        // **끄면 자리도 없다**(적대적 검증). 그리기만 건너뛰면 히스토리 탭 위에 빈 띠가 남는다 —
        // 화면에 아무 말도 하지 않는 20px는 그냥 잃은 자리다.
        .style = .{ .height = .{ .px = if (props.show_summary) @as(f32, @floatFromInt(m.summary_h)) else 0 } },
        .variant = .surface,
        // 아래 경계선 하나로 고정 chrome과 목록을 가른다(테두리 없는 요약 줄이 목록에 섞이지 않게).
        .paint = .{ .background = .surface_bg, .border = .divider, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 0, 0, 1, 0 }, .shadow = .none },
        .overflow = .clip,
    }, &.{});
    top[2] = tree.scrollArea(.{
        .id = NodeIds.content,
        .style = .{ .height = .{ .fill = 1 } },
        .scroll = .{
            .offset_px = props.scroll_offset_px,
            .content_h_px = props.content_h_px,
            .first_item_origin_y_px = props.content_first_item_origin_y_px,
            // 스크롤바가 목록 위에 겹치지 않게 오른쪽에 남겨 두는 자리 — **넘칠 때만** 준다
            // (사용자 지적 2026-08-20: 스크롤바가 없는 화면에도 12px이 이유 없이 비어 보였다).
            //
            // 폭이 바뀌는 순간은 **목록이 창을 넘기 시작/멈추는 때**뿐이다. 그때는 어차피 행이 늘거나
            // 준 때라 폭 변화가 따로 도드라지지 않는다 — 스크롤하는 동안에는 절대 안 바뀐다(그것이
            // 원래 이 예약이 막으려던 것이다).
            .gutter_px = if (props.list_overflows)
                @floatFromInt(m.scrollbar_width + m.scrollbar_inset_x * 2)
            else
                0,
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
    //
    // 그 줄의 오른쪽 끝에 **원격 갱신 버튼**이 앉는다(P6 — 목업의 `Fetch ∨`). 자리는 늘 잡되 **누를 수
    // 있는지는 `enabled`가 말한다**: 원격이 없는 저장소나 이미 도는 중이면 꺼진다. 브랜치를 못 잡은
    // 프레임에서는 줄 자체가 높이 0이라 이 버튼도 함께 사라진다(없는 저장소를 fetch할 수는 없다).
    const fetch_slot = buffers.nodes[action_cursor + tab_order.len + 4 ..][0..2];
    const fetch_action = table.append(
        props.snapshot_generation,
        .fetch_remote,
        props.fetch.enabled and !props.fetch.running,
    ) catch return error.InsufficientActionBuffer;
    // **카드다**(투명 버튼이 아니라). 행 동작 아이콘은 행 호버 밴드가 affordance를 대신하지만 **브랜치
    // 줄에는 그 밴드가 없다** — 투명하게 두면 커서만 바뀌고 눌린다는 신호가 화면에 하나도 없다. 카드로
    // 두면 호버·눌림 해석이 `paint_style.resolveCard`를 지나 면이 밝아진다(커밋 버튼과 같은 길).
    fetch_slot[0] = tree.card(.{
        .id = NodeIds.fetch,
        .style = .{
            .width = .{ .px = @floatFromInt(m.fetchChipWidthPx()) },
            .height = .{ .px = @floatFromInt(m.action_extent) },
            // 칩과 `∨` 사이는 **좁게** 둔다 — 둘이 한 컨트롤 묶음으로 읽혀야 한다(목업의 `Fetch ∨`).
            .margin = .{ .right = @floatFromInt(m.gap) },
        },
        .variant = .surface,
        .paint = .{
            // **면을 파 내지 않는다**(사용자 지적 2026-08-18): 배경은 줄과 같고 글자색만 다르다. 그래도
            // 카드로 두는 이유는 호버·눌림 해석이다 — 그 상태에서만 면이 밝아져 "누르는 것"이라고 말한다.
            .background = .surface_bg,
            // **각진 모서리다.** 이 도크의 카드는 전부 그렇다(위 계약 — 줄들이 표의 행으로 읽혀야 한다).
            // 둥근 것이 필요한 자리는 badge(개수 pill)가 따로 있고 그건 카드가 아니라 paint다.
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = .{ 0, 0, 0, 0 },
            .shadow = .none,
        },
        .action = fetch_action,
        // 꺼져 있으면 **누르는 손이 아니다** — 커서가 "된다"고 말해 놓고 안 되면 그게 고장으로 읽힌다.
        .cursor = if (props.fetch.enabled and !props.fetch.running) .press else .arrow,
        .overflow = .clip,
    }, &.{});
    // `∨`는 **자기 히트 사각형**이다(P6b). 칩과 합치면 "갱신"과 "메뉴 열기"가 같은 클릭이 되어, 누를
    // 때마다 네트워크가 도는 컨트롤 위에 메뉴가 뜬다. **도는 중에도 열린다** — `push`/`pull`은 우리가
    // 실행하는 것이 아니라 터미널에 넣어 주는 글자라 fetch와 겹치지 않는다.
    const menu_action = table.append(
        props.snapshot_generation,
        .open_remote_menu,
        props.remote_menu_enabled,
    ) catch return error.InsufficientActionBuffer;
    fetch_slot[1] = tree.card(.{
        .id = NodeIds.remote_menu,
        .style = .{
            .width = .{ .px = @floatFromInt(m.disclosure_extent) },
            .height = .{ .px = @floatFromInt(m.action_extent) },
            .margin = .{ .right = @floatFromInt(m.inset_x) },
        },
        .variant = .surface,
        .paint = .{
            .background = .surface_bg,
            .corner_radii_px = .{ 0, 0, 0, 0 },
            .border_widths_px = .{ 0, 0, 0, 0 },
            .shadow = .none,
        },
        .action = menu_action,
        .cursor = if (props.remote_menu_enabled) .press else .arrow,
        .overflow = .clip,
    }, &.{});
    top[3] = tree.card(.{
        .id = NodeIds.branch,
        .style = .{ .height = .{ .px = if (props.branch.len == 0) 0 else @floatFromInt(m.branch_h) } },
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .variant = .surface,
        .paint = if (props.branch.len == 0) .{} else .{ .background = .surface_bg, .border = .divider, .corner_radii_px = .{ 0, 0, 0, 0 }, .border_widths_px = .{ 1, 0, 0, 0 }, .shadow = .none },
        .overflow = .clip,
    }, if (props.branch.len == 0) &.{} else fetch_slot);

    // **커밋 상자·버튼은 여기 없다**(②b). 저장소마다 하나씩이므로 목록 항목으로 내려갔다 —
    // 고정 chrome에 하나만 두면 "지금 어느 저장소로 커밋하는가"가 화면에 없고, 그 어긋남은 잘못된
    // 저장소에 커밋으로 끝난다.

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
        .commit => |commit| commit.selected,
        .turn => |turn| turn.selected,
        .commit_file => |file| file.selected,
        .repo, .load_more, .commit_box, .commit_button, .section, .more, .notice, .blocker => false,
    };
}

const std = @import("std");
const testing = std.testing;
const paint_style = @import("../../ui/paint_style.zig");

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
    // 행 4 + 버튼 3 + 탭 칸 3 + **고정 4**(탭 줄·요약·목록·브랜치) + **원격 갱신 2**(P6 칩 · P6b `∨`).
    // 커밋 상자·버튼은 ②b에서 목록 항목으로 내려갔으므로 고정에 없다 — 이 숫자가 그 사실을 잠근다.
    try testing.expectEqual(items.len + 3 + tab_order.len + 4 + 2, sizes.nodes);
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

test "브랜치 줄의 원격 갱신 칩: 자리는 늘 있고 켜짐은 원격이 정한다 (P6)" {
    var storage: Storage = .{};
    const on = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = true },
    }, &storage);

    const branch_rect = on.tree.entries[on.tree.find(NodeIds.branch) orelse return error.MissingBranch].rect;
    const chip_index = on.tree.find(NodeIds.fetch) orelse return error.MissingFetch;
    const chip = on.tree.entries[chip_index].rect;
    // 칩은 브랜치 줄 **안**의 오른쪽 끝이다(줄 밖으로 나가면 목록 위에 떠 있는 버튼이 된다).
    try testing.expect(chip.width > 0 and chip.height > 0);
    try testing.expect(chip.x >= branch_rect.x);
    try testing.expect(chip.x + chip.width <= branch_rect.x + branch_rect.width);
    try testing.expect(chip.y >= branch_rect.y and chip.y + chip.height <= branch_rect.y + branch_rect.height);
    // 누를 수 있다고 커서가 말한다.
    try testing.expectEqual(tree.CursorHint.press, on.tree.entries[chip_index].cursor);

    var enabled_seen = false;
    for (on.actions) |entry| if (entry.intent == .fetch_remote) {
        enabled_seen = entry.enabled;
    };
    try testing.expect(enabled_seen);

    // 원격이 없으면 **꺼진다** — 자리는 그대로 있고(감추지 않는다) action만 거절한다.
    var storage_off: Storage = .{};
    const off = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = false },
    }, &storage_off);
    const off_index = off.tree.find(NodeIds.fetch) orelse return error.MissingFetch;
    try testing.expect(off.tree.entries[off_index].rect.width > 0); // 감추지 않는다
    try testing.expectEqual(tree.CursorHint.arrow, off.tree.entries[off_index].cursor); // 누르는 손이 아니다
    for (off.actions) |entry| if (entry.intent == .fetch_remote) {
        try testing.expect(!entry.enabled);
    };

    // 도는 중에도 거절한다(쓰기 하나씩과 같은 규율). 그리고 **칩 폭이 안 변한다**(2026-08-20): 글자
    // 라벨이던 때는 `가져오는 중…`으로 넓어져 그 옆 `↑`/`↓`가 밀렸다 — 상태가 바뀌었다고 **다른 값의
    // 자리가 움직이면** 사용자는 숫자를 다시 찾아 읽어야 한다.
    var storage_run: Storage = .{};
    const running = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = true, .running = true },
    }, &storage_run);
    const run_chip = running.tree.entries[running.tree.find(NodeIds.fetch) orelse return error.MissingFetch].rect;
    try testing.expectEqual(chip.width, run_chip.width);
    for (running.actions) |entry| if (entry.intent == .fetch_remote) {
        try testing.expect(!entry.enabled);
    };
}

test "`∨`는 칩 오른쪽의 **자기 히트 사각형**이고 도는 중에도 열린다 (P6b)" {
    var storage: Storage = .{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = true, .running = true },
        .remote_menu_enabled = true,
    }, &storage);

    const chip = frame.tree.entries[frame.tree.find(NodeIds.fetch) orelse return error.MissingFetch].rect;
    const menu_index = frame.tree.find(NodeIds.remote_menu) orelse return error.MissingRemoteMenu;
    const menu = frame.tree.entries[menu_index].rect;
    // 칩 **오른쪽**이고 겹치지 않는다 — 겹치면 "갱신"을 누르려다 메뉴가 뜬다.
    try testing.expect(menu.x >= chip.x + chip.width);
    try testing.expect(menu.width > 0 and menu.height > 0);
    try testing.expectEqual(tree.CursorHint.press, frame.tree.entries[menu_index].cursor);

    // **fetch가 도는 중에도 메뉴는 열린다.** `push`/`pull`은 우리가 실행하는 것이 아니라 터미널에 넣어
    // 주는 글자라 네트워크 슬롯과 겹치지 않는다.
    var saw_menu = false;
    for (frame.actions) |entry| switch (entry.intent) {
        .open_remote_menu => {
            saw_menu = true;
            try testing.expect(entry.enabled);
        },
        .fetch_remote => try testing.expect(!entry.enabled), // 도는 중이라 갱신은 거절한다
        else => {},
    };
    try testing.expect(saw_menu);

    // 아직 아무것도 못 읽은 프레임에서는 둘 다 꺼진다 — 그때 아는 것은 "모른다"뿐이다.
    var storage_off: Storage = .{};
    const off = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = false },
    }, &storage_off);
    for (off.actions) |entry| switch (entry.intent) {
        .open_remote_menu, .fetch_remote => try testing.expect(!entry.enabled),
        else => {},
    };
}

test "목록이 안 넘치면 스크롤바 자리를 안 비운다 (사용자 지적 2026-08-20)" {
    // 늘 비워 두면 스크롤바가 없는 화면에도 이유를 말하지 않는 12px 띠가 남는다(머리 줄 동작 아이콘의
    // 빈 띠와 같은 종류). 반대로 넘칠 때 안 비우면 스크롤바가 행 글자 위에 앉는다 — 둘 다 계약이다.
    var storage_fit: Storage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
    };
    const fit = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
        .list_overflows = false,
    }, &storage_fit);
    const fit_row = fit.tree.entries[fit.tree.find(NodeIds.item(0)) orelse return error.MissingRow].rect;

    var storage_over: Storage = .{};
    const over = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
        .list_overflows = true,
        .content_h_px = 4000,
    }, &storage_over);
    const over_row = over.tree.entries[over.tree.find(NodeIds.item(0)) orelse return error.MissingRow].rect;

    const m = types.DockMetrics.resolve(1000);
    const gutter: f32 = @floatFromInt(m.scrollbar_width + m.scrollbar_inset_x * 2);
    // 넘칠 때만 행이 그만큼 좁다 — 그 차이가 곧 스크롤바가 앉을 자리다.
    try testing.expectEqual(fit_row.width - gutter, over_row.width);
}

test "원격이 없어도 `∨`는 열린다 — 기준 고르기가 남아 있다 (§3.5)" {
    // 이 둘을 한 값으로 묶어 두면 `origin/HEAD`가 없는 저장소, 즉 **기준을 골라야 하는 바로 그
    // 저장소**에서 메뉴가 안 열린다(원격 없는 저장소에는 `origin/HEAD`도 없다).
    var storage: Storage = .{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = false }, // 원격 없음 — 갱신은 무엇을 눌러도 실패한다
        .remote_menu_enabled = true,
    }, &storage);

    var saw_menu = false;
    for (frame.actions) |entry| switch (entry.intent) {
        .open_remote_menu => {
            saw_menu = true;
            try testing.expect(entry.enabled);
        },
        .fetch_remote => try testing.expect(!entry.enabled),
        else => {},
    };
    try testing.expect(saw_menu);
    const menu_index = frame.tree.find(NodeIds.remote_menu) orelse return error.MissingRemoteMenu;
    try testing.expectEqual(tree.CursorHint.press, frame.tree.entries[menu_index].cursor);
}

test "브랜치를 못 잡으면 원격 갱신 칩도 함께 사라진다 (P6)" {
    // 줄 자체가 높이 0인데 버튼만 남으면 **없는 저장소를 fetch하는 컨트롤**이 화면에 뜬다.
    var storage: Storage = .{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "",
        .fetch = .{ .enabled = true },
    }, &storage);
    try testing.expect(frame.tree.find(NodeIds.fetch) == null);
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
        .open_row => |ref| {
            saw_open = true;
            try testing.expectEqual(@as(u32, 42), ref.model_index);
        },
        .row_action => |ref| {
            saw_row_action = true;
            try testing.expectEqual(@as(u32, 42), ref.model_index);
        },
        .expand_section => |section| {
            saw_expand = true;
            try testing.expectEqual(types.Section.changes, section);
        },
        .section_action, .scroll_thumb, .scroll_track, .commit_focus, .commit, .toggle_repo, .refresh_repo, .stage_all_repo, .select_tab, .select_commit, .load_more_commits, .open_commit_file, .select_turn, .open_turn_file, .fetch_remote, .open_remote_menu => {},
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
    // 고정 chrome을 전부 뺀 나머지가 목록이다 — **탭 줄·요약·브랜치 셋뿐이다**(②b). 커밋 상자·버튼은
    // 저장소마다 하나씩이라 목록 **안**에 살고, 그래서 고정에서 빠진 만큼 목록이 커진다.
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
            // P4에서 컨테이너 → 버튼이 됐다(누를 수 있어야 한다) — 버튼은 quad를 내므로 **투명**으로
            // 같은 사실을 지킨다.
            try testing.expectEqual(@as(u8, 0), entry.visual.button.paint.opacity);
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

test "스크롤된 항목 rect는 뷰포트 밖으로 뻗고, 그 사실을 effective_clip이 든다" {
    // host의 히트 판정이 **항목 rect만** 보면 안 되는 이유가 여기 있다: 가상화는 창의 첫 항목을 음수
    // origin으로 올려 두므로(부분 가림), 그 rect는 목록 위쪽 띠 아래로 들어간다. 눌리는 자리를 자르는
    // 값은 `effective_clip`이고, 일반 히트테스트(`interaction.zig`)도 그것으로 후보를 자른다.
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .commit_box = .{ .repo_index = 0, .rows = 8, .text = "본문" } },
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
        // 창의 첫 항목이 8px 잘린 채 시작한다(스크롤 중간 — 가상화가 내는 그 상태다).
        .content_first_item_origin_y_px = -8,
        .content_h_px = 900,
        .scroll_offset_px = 8,
    }, &storage);

    const index = frame.tree.find(NodeIds.item(0)) orelse return error.MissingBox;
    const entry = frame.tree.entries[index];
    const clip = entry.effective_clip orelse return error.MissingClip;
    // 상자 rect는 clip 위로 뻗어 있다(그리기는 잘리지만 rect는 안 잘린다).
    try testing.expect(entry.rect.y < clip.y);
    // 그리고 그 clip은 목록 뷰포트다 — 위쪽 고정 chrome(탭·요약)보다 아래에서 시작한다.
    const content = frame.tree.entries[frame.tree.find(NodeIds.content) orelse return error.MissingContent].rect;
    try testing.expect(clip.y >= content.y);
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

test "커밋 줄은 그 저장소 머리 줄 **바로 아래**에 오고 내용을 따라 자란다 (②b)" {
    // 상자가 고정 chrome에 하나만 있으면 "지금 어느 저장소로 커밋하는가"가 화면에 없다 — 아래 그룹의
    // 파일을 보면서 위 상자에 쓰면 **다른 저장소로 커밋**된다. 그래서 상자는 그 그룹 안에 산다.
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "a", .branch = "main" } },
        .{ .commit_box = .{ .repo_index = 0, .rows = 1 } },
        .{ .commit_button = .{ .repo_index = 0 } },
        .{ .section = .{ .section = .changes, .count = 1, .collapsed = false, .action = .stage } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    const head = frame.tree.entries[frame.tree.find(NodeIds.item(0)) orelse return error.MissingRepo].rect;
    const box = frame.tree.entries[frame.tree.find(NodeIds.item(1)) orelse return error.MissingBox].rect;
    const button = frame.tree.entries[frame.tree.find(NodeIds.item(2)) orelse return error.MissingButton].rect;
    const section = frame.tree.entries[frame.tree.find(NodeIds.item(3)) orelse return error.MissingSection].rect;
    try testing.expect(head.y < box.y);
    try testing.expect(box.y < button.y);
    try testing.expect(button.y < section.y); // 파일 줄은 커밋 줄 **뒤**다

    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commitBoxHeight(1))), box.height);
    // 버튼 줄은 아래 여백까지 갖는다 — 다음 줄과 붙지 않게.
    try testing.expectEqual(@as(f32, @floatFromInt(m.commit_button_h + m.commit_pad_y)), button.height);

    // 시각 행이 늘면 상자가 자란다(§12.2). 여백은 행 수와 무관하게 위아래 한 번씩이다.
    var storage3: Storage = .{};
    const grown_items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "a", .branch = "main" } },
        .{ .commit_box = .{ .repo_index = 0, .rows = 3 } },
    };
    const three = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &grown_items,
        .branch = "main",
    }, &storage3);
    const grown = three.tree.entries[three.tree.find(NodeIds.item(1)) orelse return error.MissingBox].rect;
    try testing.expectEqual(@as(f32, @floatFromInt(m.commitBoxHeight(3))), grown.height);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commit_row_h * 2)), grown.height - box.height);
}

test "커밋 줄의 intent는 **어느 저장소인지**를 싣는다 (②b)" {
    // 안 실으면 아래 그룹의 상자를 눌렀는데 위 그룹이 편집되거나, 더 나쁘게는 다른 저장소로 커밋된다.
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "a" } },
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = false } }, // 꺼져 있어도 히트 사각형은 있다
        .{ .repo = .{ .index = 1, .name = "b" } },
        .{ .commit_box = .{ .repo_index = 1 } },
        .{ .commit_button = .{ .repo_index = 1, .enabled = true } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    var focus_repos: [4]u32 = undefined;
    var commit_repos: [4]u32 = undefined;
    var focus_n: usize = 0;
    var commit_n: usize = 0;
    for (frame.actions) |entry| switch (entry.intent) {
        .commit_focus => |index| {
            focus_repos[focus_n] = index;
            focus_n += 1;
        },
        .commit => |index| {
            commit_repos[commit_n] = index;
            commit_n += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), focus_n);
    try testing.expectEqual(@as(usize, 2), commit_n);
    try testing.expectEqual(@as(u32, 0), focus_repos[0]);
    try testing.expectEqual(@as(u32, 1), focus_repos[1]);
    try testing.expectEqual(@as(u32, 1), commit_repos[1]);
    // **꺼진 버튼도 히트 사각형을 갖는다** — 없애면 "왜 안 눌리는가"를 말할 기회가 사라진다.
    // 히트도 칠도 **면 노드**의 것이다(줄에는 아래 여백이 붙어 있어, 거기까지 누르면 커밋이 걸린다).
    const off = frame.tree.entries[frame.tree.find(NodeIds.itemFace(2)) orelse return error.MissingButton];
    try testing.expect(off.action != null);
    const row = frame.tree.entries[frame.tree.find(NodeIds.item(2)) orelse return error.MissingButton];
    try testing.expect(row.action == null); // 여백은 버튼이 아니다
    // 면은 줄보다 **아래 여백만큼 낮다** — 칠이 그 여백을 덮으면 글자가 띠의 가운데보다 위에 앉는다.
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commit_button_h)), off.rect.height);
    try testing.expectEqual(@as(f32, @floatFromInt(m.commit_button_h + m.commit_pad_y)), row.rect.height);
}

test "커밋 상자는 편집 중일 때 테두리로 그 사실을 말한다 (②b — 포커스는 상자마다 다르다)" {
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .commit_box = .{ .repo_index = 0, .edit = .{ .focused = false } } },
        .{ .commit_box = .{ .repo_index = 1, .edit = .{ .focused = true } } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    const idle = frame.tree.entries[frame.tree.find(NodeIds.item(0)) orelse return error.MissingBox];
    const focused = frame.tree.entries[frame.tree.find(NodeIds.item(1)) orelse return error.MissingBox];
    try testing.expectEqual(tokens.ColorRole.divider, idle.visual.card.paint.border.?);
    try testing.expectEqual(tokens.ColorRole.focus_accent, focused.visual.card.paint.border.?);
    // **높이는 안 바뀐다** — 포커스로 상자가 자라면 그 아래 목록이 통째로 밀린다.
    try testing.expectEqual(idle.rect.height, focused.rect.height);
}

test "커서는 컴포넌트가 선언한다(상자=I-beam·버튼 면=손·안내=할 말 없음)" {
    // host가 intent로 다시 추론하면 그 판정의 주인이 둘이 된다. 실제로 도크 전체가 탐색기 행 판정을
    // 물려받아 **화살표만** 나왔다(사용자 지적 2026-08-17).
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "a" } },
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = true } },
        .{ .notice = "변경 사항 없음" },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    const cursorOf = struct {
        fn get(f: Frame, id: u64) tree.CursorHint {
            const index = f.tree.find(id) orelse return .auto;
            return f.tree.entries[index].cursor;
        }
    }.get;
    try testing.expectEqual(tree.CursorHint.press, cursorOf(frame, NodeIds.item(0)));
    try testing.expectEqual(tree.CursorHint.text, cursorOf(frame, NodeIds.item(1)));
    try testing.expectEqual(tree.CursorHint.press, cursorOf(frame, NodeIds.itemFace(2)));
    // 버튼 **줄**은 아래 여백이라 할 말이 없다(면만 버튼이다).
    try testing.expectEqual(tree.CursorHint.auto, cursorOf(frame, NodeIds.item(2)));
    try testing.expectEqual(tree.CursorHint.auto, cursorOf(frame, NodeIds.item(3)));
}

test "커밋 상자는 호버로 면이 밝아지지 않는다(테두리는 그대로 따라간다)" {
    // 여기서 마우스가 뜻하는 것은 "누를 수 있다"가 아니라 "여기에 caret을 놓는다"이고, 그건 커서가
    // 말한다. 면까지 밝아지면 편집 중임을 말하는 테두리와 신호가 섞인다(사용자 지적 2026-08-17).
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .file = .{ .model_index = 0, .name = "a.zig", .dir = "src/", .status = .modified, .letter = 'M', .added = 1, .removed = 0, .has_delta = true, .action = .stage } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    const tk = tokens.Tokens.base(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 221, .g = 161, .b = 94 },
    });
    const box = frame.tree.entries[frame.tree.find(NodeIds.item(0)) orelse return error.MissingBox];
    const hovered_box = paint_style.resolveCard(box.id, box.visual.card, box.action, .{ .hovered = box.id }, &tk);
    try testing.expectEqual(tokens.ColorRole.inset_bg, hovered_box.background); // 면은 그대로
    // **파일 행은 반대다** — 그건 누르는 줄이라 호버가 보여야 한다(같은 규칙이 아니라 다른 사실).
    const row = frame.tree.entries[frame.tree.find(NodeIds.item(1)) orelse return error.MissingRow];
    const hovered_row = paint_style.resolveCard(row.id, row.visual.card, row.action, .{ .hovered = row.id }, &tk);
    try testing.expectEqual(tokens.ColorRole.row_hover_bg, hovered_row.background);
}

test "저장소 머리 줄은 동작 버튼 둘을 갖는다(꺼져도 히트 사각형은 있다) (②c)" {
    // 감추면 "왜 안 눌리는가"를 말할 기회가 사라진다(P1 계약). 그리고 자리는 **호버와 무관하게**
    // 예약해야 브랜치 칩·개수 배지가 마우스를 따라 움직이지 않는다.
    var storage: Storage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "a", .can_stage_all = false } },
    };
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .items = &items,
        .branch = "main",
    }, &storage);
    var refresh: ?ids.Intent = null;
    var stage_all: ?ids.Intent = null;
    var stage_enabled = true;
    for (frame.actions) |entry| switch (entry.intent) {
        .refresh_repo => refresh = entry.intent,
        .stage_all_repo => {
            stage_all = entry.intent;
            stage_enabled = entry.enabled;
        },
        else => {},
    };
    try testing.expect(refresh != null);
    try testing.expect(stage_all != null);
    // 읽지 못한 저장소라 전체 스테이지는 **꺼져 있다** — 그래도 표에 있고 히트 사각형도 있다.
    try testing.expect(!stage_enabled);
    for (0..repo_action_count) |slot| {
        const index = frame.tree.find(NodeIds.repoAction(0, slot)) orelse return error.MissingRepoAction;
        try testing.expect(frame.tree.entries[index].rect.width > 0);
        try testing.expectEqual(tree.CursorHint.press, frame.tree.entries[index].cursor);
    }
}

test "탭 줄의 칸은 누를 수 있다(P4 — 그전에는 컨테이너라 action이 없었다)" {
    // 탭 셋이 그려져 있는데 눌러도 아무 일이 없으면, 사용자는 그 화면이 목록 하나뿐인 줄로 읽는다.
    var storage: Storage = .{};
    const items = [_]types.Item{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
    }, &storage);
    var tabs_seen: usize = 0;
    for (frame.actions) |entry| switch (entry.intent) {
        .select_tab => |tab| {
            tabs_seen += 1;
            try testing.expect(tab == .changes or tab == .history or tab == .agent);
        },
        else => {},
    };
    try testing.expectEqual(tab_order.len, tabs_seen);
    // 그리고 칸에는 **칠이 없다** — 있으면 탭 줄 아래 divider를 덮는다(컨테이너를 쓰던 이유).
    const slot = frame.tree.entries[frame.tree.find(NodeIds.tab(0)) orelse return error.MissingTab];
    try testing.expectEqual(@as(u8, 0), slot.visual.button.paint.opacity);
}

test "요약 줄을 끄면 자리도 없다(히스토리 탭 위에 빈 띠가 남지 않게)" {
    // 그리기만 건너뛰면 화면에 아무 말도 하지 않는 20px가 남는다 — 좁은 도크에서 그건 잃은 자리다.
    var on_storage: Storage = .{};
    const on = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
    }, &on_storage);
    var off_storage: Storage = .{};
    const off = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .show_summary = false,
    }, &off_storage);
    const on_summary = on.tree.entries[on.tree.find(NodeIds.summary) orelse return error.MissingSummary];
    const off_summary = off.tree.entries[off.tree.find(NodeIds.summary) orelse return error.MissingSummary];
    try testing.expect(on_summary.rect.height > 0);
    try testing.expectEqual(@as(f32, 0), off_summary.rect.height);
    // 그만큼 목록이 커진다 — 자리를 뺏지 않는 것이 요점이다.
    const on_content = on.tree.entries[on.tree.find(NodeIds.content) orelse return error.MissingContent];
    const off_content = off.tree.entries[off.tree.find(NodeIds.content) orelse return error.MissingContent];
    try testing.expectEqual(on_content.rect.height + on_summary.rect.height, off_content.rect.height);
}

test "글자 뷰포트는 목록 사각형이고, 스크롤로 밀린 첫 행은 그 위로 나간다" {
    // 이 둘이 함께 있어야 계약이 성립한다: 행이 뷰포트 **위로 나가는 상태**를 만들 수 있고(가상화),
    // 그때 host 가 글자를 자를 사각형을 컴포넌트가 낼 수 있어야 한다.
    //
    // 이 값이 없던 동안 제품과 Lab 모두 measured 글자를 **아무 데도 안 잘랐고**, 반쯤 스크롤된 첫
    // 행의 라벨이 요약 줄 위에 그려졌다(2026-08-25 사용자가 골든 캡처에서 지적). quad 는 tree 의
    // `effective_clip` 이 자르고 있었기 때문에, 그 상태로도 알약을 보는 골든은 초록이었다.
    var storage: Storage = .{};
    const frame = try buildTest(.{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{
            .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main" } },
            .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
        },
        .branch = "main",
        .scroll_offset_px = 12,
        .content_first_item_origin_y_px = -12,
        .content_h_px = 900,
        .list_overflows = true,
    }, &storage);

    const content = frame.tree.entries[frame.tree.find(NodeIds.content) orelse return error.MissingContent].rect;
    const text_viewport = scrollTextViewport(frame.tree) orelse return error.NoTextViewport;
    try testing.expectEqual(content, text_viewport);

    // 첫 행은 뷰포트 위로 나간다 — 자를 것이 실제로 있다.
    const first = frame.tree.entries[frame.tree.find(NodeIds.item(0)) orelse return error.MissingFirstRow].rect;
    try testing.expect(first.y < content.y);
}

test "글자 뷰포트는 목록이 없으면 null 이다(빈 tree 에서 지어내지 않는다)" {
    var entries: [1]tree.RectEntry = undefined;
    const empty: tree.UiRectTree = .{ .entries = entries[0..0], .generation = 0 };
    try testing.expect(scrollTextViewport(empty) == null);
}
