//! 완성된 소스 컨트롤 도크 rect tree의 semantic paint·텍스트 투영.
//!
//! 일반 UI painter가 카드 배경을 소유하고, 이 파일은 **컴포넌트가 소유한 글자와 호버 동작**만 더한다.
//! platform에 글리프 위치를 묻지 않으므로 backend는 계속 단방향 ChromeDraw lowerer로 남는다.

const std = @import("std");
const i18n = @import("../../../i18n.zig"); // 표시 문자열 단일 출처
const icons = @import("../../../icons.zig");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const badge = @import("../../ui/badge.zig");
const spacing = @import("../../ui/spacing.zig");
const interaction = @import("../../ui/interaction.zig");
const ui_paint = @import("../../ui/paint.zig");
const paint_style = @import("../../ui/paint_style.zig");
const text_layout = @import("../../text_layout.zig");
const file_tree_icon = @import("../../file_tree_icon.zig");
const tree = @import("../../ui/tree.zig");
const typography = @import("../../ui/typography.zig");
const text_area = @import("../text_area.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const text_field = @import("../text_field.zig");
const build = @import("build.zig");
const types = @import("types.zig");

// 그룹 접힘 표시와 브랜치는 **등록된 SVG 아이콘**이다. `▸`·`⑂` 같은 텍스트 글리프는 폴백 폰트마다
// 모양·크기가 달라 chrome affordance의 광학 크기를 약속할 수 없다(Session Dock과 같은 규율).
/// 상자 오른쪽 여백(안내 문구가 테두리에 닿지 않게). 행 inset과 같은 값을 쓴다.
const m_inset_fallback: u32 = 8;
const chevron_down_icon = icons.utf8Fit(.chevron_down, .tight);
const chevron_right_icon = icons.utf8Fit(.chevron_right, .tight);
const branch_icon = icons.utf8Fit(.git_branch, .standard);
/// "아직 안 보낸 것이 있다"는 점. **글자 하나다** — 등록 아이콘이 아니라도 되는 이유는 이것이 컨트롤이
/// 아니라 상태 표식이고(누를 수 없다), `●`는 PUA가 아니라 어떤 폰트에도 있는 BMP 글자이기 때문이다
/// (행 동작의 `+`/`−`와 같은 판단 — `∨`가 PUA라 아이콘 경로를 타야 했던 것과 대비된다).
const unpushed_dot = "●";
/// 저장소 머리 줄의 종류 아이콘. 주 워크트리는 작업 폴더 자체이고, 링크된 워크트리는 그 저장소에
/// **딸린 다른 체크아웃**이다 — 두 줄이 한 화면에 서므로 그 차이가 글리프로 보여야 한다.
const repo_icon = icons.utf8Fit(.folder, .standard);
/// 아직 안 읽은 저장소 줄에 적는 말. **배지의 빈자리와 구별해야 한다** — 배지가 없는 것을 사용자는
/// "변경 없음"으로 읽는다.
fn repoPendingLabel() []const u8 {
    return i18n.t(.scm_loading);
}
/// 읽지 못한 저장소. **"읽는 중…"과 다른 사실이다** — 그쪽은 곧 온다는 약속이다.
fn repoFailedLabel() []const u8 {
    return i18n.t(.scm_load_failed);
}
const worktree_icon = icons.utf8Fit(.git_branch, .standard);
/// 머리 줄의 동작 아이콘(②c). **이미 있는 자산을 쓴다** — 커밋 ✓는 그룹 안 버튼과 겹쳐 넣지 않는다.
const refresh_icon = icons.utf8Fit(.reset, .standard);
const stage_all_icon = icons.utf8Fit(.plus, .standard);
// 행 동작은 글자 하나다 — `+`/`−`는 어떤 폰트에도 있고, 아이콘 슬롯을 하나 더 등록하지 않아도 된다.
const stage_glyph = "+";
const unstage_glyph = "−";

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientRunBuffer, InsufficientTextBuffer, MissingRect };

/// `view`가 이 props로 성공하는 데 필요한 draw 버퍼 상한.
///
/// **방출 지점과 같은 파일에 둔다.** platform이 세면 component가 op을 하나 더할 때마다 그 산술이
/// 조용히 낡고, 증상은 "그 op이 안 보임"이 아니라 **도크 전체가 빈 화면**이다(view가 실패하면 publish
/// 까지 못 가 프레임이 통째로 버려진다). 실제로 두 번 그랬다: 증감을 두 색으로 가르며 행당 op이 하나
/// 늘었을 때, 그리고 경로가 긴 저장소에서 바이트 풀이 넘쳤을 때.
///
/// 바이트는 **추정하지 않고 실제 문자열을 더한다** — 경로 길이에 상한이 없어서(`name`+`dir`이 곧 git
/// 경로다) 행당 고정값은 어떤 값을 골라도 그보다 긴 저장소가 있다.
pub fn drawBufferSizes(props: types.Props, entry_count: usize) struct { ops: usize, runs: usize, text_bytes: usize } {
    // 고정 chrome: 탭 3 + 요약 2 + 브랜치 7(아이콘·이름·미push 점·↑·↓·원격 갱신 칩·`∨`) + 호버 동작 1.
    // **커밋 줄도 빈 안내도 고정이 아니다**(②b) — 저장소마다 나므로 아래 항목 루프가 센다.
    var text_ops: usize = 13;
    var quad_extra: usize = 0;
    var bytes: usize = 0;
    for (build.tab_order) |tab| bytes += tabTitle(tab).len + count_digits + 3; // ` (N)`
    bytes += count_digits * 2 + 4; // 요약 `+N -N`
    // 브랜치 줄 — 이름·아이콘 + `↑ N`/`↓ N` 둘(화살표 3바이트 + 공백 + 자릿수).
    bytes += props.branch.len + icon_bytes * 2 + (count_digits + 5) * 2 + unpushed_dot.len;
    // 원격 갱신 칩 — **긴 쪽으로 잡는다**(도는 중 문구가 더 길다). 모자라면 도크가 통째로 빈다.
    bytes += @max(i18n.t(.scm_fetch).len, i18n.t(.scm_fetching).len);

    for (props.items) |item| switch (item) {
        // 접힘 아이콘·(워크트리면) 종류 아이콘·이름·브랜치 칩·개수 — 다섯.
        .repo => |repo| {
            text_ops += 5 + build.repo_action_count; // 동작 아이콘 둘(②c)
            // 호버한 머리 줄은 그 아이콘 **밑을 덮는** 사각형 하나를 더 낸다(빈 띠를 없앤 대가).
            // 호버는 한 줄에만 걸리지만 예산은 **줄마다** 잡는다 — 어느 줄일지는 여기서 모르고,
            // 모자라면 그 프레임이 통째로 버려진다(이 함수 위 주석의 두 사고가 그것이었다).
            quad_extra += 1;
            bytes += icon_bytes * 2 + repo.name.len +
                @max(repo.branch.len, @max(repoPendingLabel().len, repoFailedLabel().len)) + count_digits;
        },
        // 입력은 **시각 행마다 한 조각**이고, 글자는 안내 문구와 본문 중 긴 쪽만 나간다.
        .commit_box => |box| {
            text_ops += @max(box.rows, 1);
            quad_extra += 2; // 스크롤바(막대+thumb) — 넘칠 때만 그리지만 예산은 늘 잡는다
            bytes += @max(commitPlaceholder().len, box.text.len);
        },
        // 라벨 + `∨`.
        .commit_button => {
            text_ops += 2;
            bytes += icon_bytes + @max(commitLabel().len, @max(commitRunningLabel().len, commitSlowLabel().len));
        },
        // 아이콘·이름·경로·`+N`·`-N`·상태 문자 — 증감이 두 조각이라 5가 아니다.
        .file => |file| {
            text_ops += 6;
            bytes += icon_bytes + file.name.len + file.dir.len + 1 + (count_digits + 1) * 2;
        },
        // 아이콘·제목·개수.
        .section => |section| {
            text_ops += 3;
            bytes += icon_bytes + sectionTitle(section.section).len + count_digits;
        },
        // `모두 보기 (N개 더)` — 서식 문자열이 component 것이라 여기서만 길이를 안다.
        .more => {
            text_ops += 1;
            bytes += more_label_bytes + count_digits;
        },
        // 제목·작성자·시각·해시·ref 칩·`+N` 접힘 — 여섯.
        .commit => |commit| {
            text_ops += 6;
            bytes += commit.subject.len + commit.author.len + commit.when.len + commit.short_oid.len + commit.ref.len;
            bytes += 8; // `+N` 접힘 표시(§3.5.3) — 자릿수가 늘어도 담기게 넉넉히 잡는다
        },
        // 제목·에이전트·시각 — 셋.
        .turn => |turn| {
            text_ops += 3;
            bytes += turn.title.len + turn.agent.len + turn.when.len;
        },
        // 아이콘·이름·경로·상태 문자 — 넷.
        .commit_file => |file| {
            text_ops += 4;
            bytes += icon_bytes + file.name.len + file.dir.len + 2;
        },
        .load_more => {
            text_ops += 1;
            bytes += i18n.t(.scm_load_more).len;
        },
        .notice => |text| {
            text_ops += 1;
            bytes += text.len;
        },
    };
    // 호버 동작 글리프(`+`/`−`)는 한 번에 한 행이다.
    bytes += 4;

    return .{
        // quad = entry당 배경(ui_paint) + 그룹 개수 배지(행당 최대 하나) + 활성 탭 밑줄 하나 +
        // **커밋 상자의 선택 밴드(시각 행당 최대 하나) + caret 하나**.
        // quad = entry당 배경 + 배지(행당 최대 하나) + 활성 탭 밑줄 + **커밋 상자의 선택 밴드와 caret**
        // (상자는 여럿일 수 있지만 **포커스는 하나**라 밴드는 그 상자의 시각 행 수, caret은 하나다).
        .ops = entry_count + props.items.len + 1 + commitBandBudget(props.items) + 1 + text_ops + quad_extra,
        .runs = text_ops,
        .text_bytes = bytes,
    };
}

/// 선택 밴드 예산. **포커스된 상자 하나**만 밴드를 그리므로 그 상자의 시각 행 수면 충분하다.
fn commitBandBudget(items: []const types.Item) usize {
    var max: usize = 1;
    for (items) |item| switch (item) {
        .commit_box => |box| {
            if (box.edit.focused) max = @max(max, @as(usize, @max(box.rows, 1)));
        },
        else => {},
    };
    return max;
}

/// u32 십진 최대 자릿수.
const count_digits: usize = 10;
/// UTF-8 글리프 하나(등록 아이콘은 PUA 코드포인트라 최대 4바이트).
const icon_bytes: usize = 4;
/// `모두 보기 (N개 더)`에서 숫자를 뺀 나머지 바이트(한글 3바이트).
const more_label_bytes: usize = 32;

pub fn view(
    props: types.Props,
    frame: build.Frame,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    buffers: Buffers,
) ViewError!draw.ChromeDraw {
    const painted = try ui_paint.paint(frame.tree, state, tk, .sidebar, .{ .ops = buffers.ops });
    var writer = Writer{
        .props = props,
        .cell_width_px = @max(props.cell_width_px, 1),
        .ops = buffers.ops,
        .op_count = painted.ops.len,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .state = state,
        .tokens_ref = tk,
    };

    const m = types.DockMetrics.resolve(props.scale_milli);

    // ── 탭 줄: `변경 사항 (N) │ 히스토리 │ 에이전트`(§3.5.1). **칸은 tree가 나눠 놨다** — 여기서는
    // 그 rect를 받아 글자만 얹는다.
    for (build.tab_order, 0..) |tab, index| {
        const slot = frame.tree.find(build.NodeIds.tab(index)) orelse continue;
        try writer.tabSlot(frame.tree.entries[slot], tab);
    }

    // ── 요약 줄: `+N -N`. 커밋 직전에 보는 숫자라 목록보다 위에 고정한다.
    if (props.show_summary) blk: {
        const index = frame.tree.find(build.NodeIds.summary) orelse break :blk;
        const rect = frame.tree.entries[index];
        var added_buf: [24]u8 = undefined;
        const added = std.fmt.bufPrint(&added_buf, "+{d}", .{props.summary.added}) catch "";
        try writer.line(rect, @floatFromInt(m.inset_x), added, .git_added_fg, .supporting, false);
        var removed_buf: [24]u8 = undefined;
        const removed = std.fmt.bufPrint(&removed_buf, "-{d}", .{props.summary.removed}) catch "";
        const gap: f32 = @floatFromInt(m.inset_x + m.gap);
        try writer.line(rect, gap + writer.measureBudget(added), removed, .git_deleted_fg, .supporting, false);
    }

    // ── 목록. 스크롤 영역 안이므로 backend가 "스크롤은 순수 평행이동"임을 쓸 수 있게 표시한다.
    const content_index = frame.tree.find(build.NodeIds.content) orelse return error.MissingRect;
    writer.container_clip = clipRectOf(frame.tree.entries[content_index]);
    writer.scroll_clipped = true;
    for (props.items, 0..) |item, index| {
        const row_index = frame.tree.find(build.NodeIds.item(index)) orelse continue;
        const row = frame.tree.entries[row_index];
        writer.active_clip = clipRectOf(row);
        switch (item) {
            .repo => |repo| try writer.repoRow(row, repo, m),
            .commit_box => |box| try writer.commitBox(row, box, m),
            .commit_button => |button| {
                // **면 노드**가 그 줄의 칠과 action을 갖는다(아래 여백은 줄의 것이다) — 글자·호버 해석도
                // 같은 rect를 봐야 띠의 가운데에 앉는다.
                const face_index = frame.tree.find(build.NodeIds.itemFace(index)) orelse continue;
                try writer.commitButton(frame.tree.entries[face_index], button, state, tk, m);
            },
            .commit => |commit| try writer.commitRow(row, commit, m),
            // 턴 줄도 두 줄이다: 제목 / 에이전트 · 시각. **진행 중은 시각이 없다**(끝나지 않았다).
            .turn => |turn| try writer.turnRow(row, turn, m),
            // 목록 끝의 "더 보기". `모두 보기`와 같은 자리·같은 색이다(둘 다 목록을 늘리는 컨트롤이다).
            // 펼친 커밋의 파일 줄 — 상태 문자는 오른쪽 끝, 이름은 한 칸 더 들여쓴다(그 커밋에 속한다).
            .commit_file => |file| try writer.commitFileRow(row, file, m),
            .load_more => try writer.line(row, @floatFromInt(m.iconColumnX()), i18n.t(.scm_load_more), .focus_accent, .control, false),
            .section => |section| try writer.sectionRow(row, section, m),
            .file => |file| try writer.fileRow(row, file, m),
            .more => |more| {
                var buf: [48]u8 = undefined;
                const text = i18n.format(&buf, i18n.t(.scm_show_all_more), &.{.{ .d = more.hidden }});
                try writer.line(row, @floatFromInt(m.iconColumnX()), text, .focus_accent, .control, false);
            },
            // 안내는 상태 진술이라 강조색을 쓰지 않는다(빈 안내와 같은 톤).
            .notice => |text| try writer.line(row, @floatFromInt(m.iconColumnX()), text, .muted_fg, .supporting, false),
        }
        // 머리 줄의 동작 아이콘 둘(②c). 같은 규율이다 — 히트 사각형은 늘 있고 글리프만 호버를 따른다.
        if (item == .repo) {
            const repo = item.repo;
            const hovered = isHovered(state, row.id) or hoveredRepoAction(state, index);
            if (hovered) {
                // **아이콘 밑을 먼저 덮는다**(사용자 지적 2026-08-19). 이 줄은 자리를 비워 두지 않으므로
                // 배지와 브랜치 이름이 그 밑에 이미 그려져 있다 — 안 덮으면 아이콘이 글자 위에 겹친다
                // (예약을 넣기 전 2026-08-17에 실제로 그랬던 화면이다).
                //
                // 색은 **칠하는 쪽에 되묻는다**(`resolveCard`) — 상태로 추측하면 어긋난다: 포인터가
                // 자식 버튼 위에 있으면 행 자체의 hover는 풀려서 배경이 평상시 색이고, 그때 hover 색을
                // 깔면 그 띠만 다른 색으로 뜬다. 같은 파일의 커밋 버튼 글자색이 그 교훈으로 이렇게 한다.
                if (frame.tree.find(build.NodeIds.repoAction(index, 0))) |first_index| {
                    const first = frame.tree.entries[first_index];
                    const left = first.rect.x - @as(f32, @floatFromInt(m.gap));
                    const right = row.rect.x + row.rect.width;
                    if (right > left) {
                        if (rowBackgroundRole(row, state, writer.tokens_ref)) |role| try writer.appendQuad(.{
                            .rect = .{
                                .x = @intFromFloat(@floor(left)),
                                .y = @intFromFloat(@floor(row.rect.y)),
                                .w = @intFromFloat(@ceil(right - left)),
                                .h = @intFromFloat(@ceil(row.rect.height)),
                            },
                            .fill_role = role,
                            .corner_radii = .{ 0, 0, 0, 0 },
                        });
                    }
                }
                inline for (.{ refresh_icon, stage_all_icon }, 0..) |glyph, slot| {
                    if (frame.tree.find(build.NodeIds.repoAction(index, slot))) |slot_index| {
                        const rect = frame.tree.entries[slot_index];
                        // 꺼진 버튼은 **흐리게** 그린다(감추지 않는다 — "왜 안 눌리는가"를 말할 수 있게).
                        const enabled = if (slot == 0) true else repo.can_stage_all;
                        try writer.icon(
                            rect,
                            0,
                            glyph,
                            m.icon_extent,
                            if (enabled) .surface_fg else .muted_fg,
                        );
                    }
                }
            }
        }
        // 호버한 행에만 동작 버튼의 글리프를 낸다. **히트 사각형은 항상 있고**(build), 보이는 것만
        // 호버를 따른다 — 사용자는 호버해야 누를 수 있으므로 이 둘이 어긋나지 않는다.
        if (frame.tree.find(build.NodeIds.itemAction(index))) |action_index| {
            const action_rect = frame.tree.entries[action_index];
            if (isHovered(state, row.id) or isHovered(state, action_rect.id)) {
                const glyph = switch (actionOf(item)) {
                    .stage => stage_glyph,
                    .unstage => unstage_glyph,
                    .none => "",
                };
                if (glyph.len > 0) try writer.centered(action_rect, glyph, .surface_fg, .control);
            }
        }
    }
    // **빈 안내는 목록 항목이다**(②b — `.notice`). 예전에는 스크롤 영역 rect 위쪽에 직접 그렸는데,
    // 그 자리에 저장소 머리 줄이 서면서 **글자가 겹쳤다**(제품 캡처 2026-08-17). 그리고 저장소가
    // 여럿이면 "어느 저장소가 비었나"는 그 그룹의 줄이라야 말이 된다.

    writer.scroll_clipped = false;
    writer.active_clip = null;
    writer.container_clip = null;

    // ── 브랜치 줄(목록 아래 고정). 저장소를 못 잡았으면 높이가 0이라 아무것도 그리지 않는다.
    if (props.branch.len > 0) {
        if (frame.tree.find(build.NodeIds.branch)) |index| {
            const rect = frame.tree.entries[index];
            try writer.icon(rect, @floatFromInt(m.inset_x), branch_icon, m.icon_extent, .muted_fg);
            const branch_x: f32 = @floatFromInt(m.iconColumnX()); // 아이콘 열과 같은 자리(단일 출처)
            try writer.line(rect, branch_x, props.branch, .surface_fg, .control, true);
            // **아직 보내지 않은 것이 있으면 점**(§3.5). 개수는 안 적는다 — 위 `↑`/`↓`는 **기본 브랜치**
            // 기준이라, 기준이 다른 숫자를 그 옆에 놓으면 어느 쪽이 무엇인지 읽을 수 없다.
            if (props.unpushed) {
                const name_w = writer.measureBudget(props.branch);
                const dot_x = branch_x + name_w + @as(f32, @floatFromInt(m.gap));
                const dot_w = writer.measureBudget(unpushed_dot);
                // 오른쪽 묶음(↑↓·칩)을 침범하지 않을 때만 그린다 — 겹치면 둘 다 못 읽는다.
                if (dot_x + dot_w < rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x))) {
                    try writer.line(rect, dot_x, unpushed_dot, .accent_bar, .supporting, false);
                }
            }
            // ── 원격 갱신 칩(P6). **글자는 tree가 준 rect 안에 놓는다** — 여기서 자기 산수로 자리를
            // 잡으면 "그린 자리와 눌리는 자리"의 주인이 둘이 된다(탭 칸에서 이미 겪은 갈림).
            const fetch_label = types.fetchLabel(props.fetch);
            var fetch_right: u32 = m.inset_x;
            // `∨`(P6b)는 칩 오른쪽이다 — 글리프는 그룹 접힘과 같은 자산을 쓴다(같은 뜻: "여기 더 있다").
            if (frame.tree.find(build.NodeIds.remote_menu)) |menu_index| {
                const menu_rect = frame.tree.entries[menu_index];
                // **`icon`으로 그린다**(`centered`가 아니라). PUA 글리프는 글자로 셰이핑되지 않고 등록된
                // SVG를 rect 안에 직접 그리는 경로를 타야 한다 — 글자 경로로 보내면 폰트 폴백이 **작은
                // 네모**를 낸다(제품 캡처 2026-08-18에서 실측: `∨` 자리에 깨진 상자가 떴다).
                const glyph_x = (menu_rect.rect.width - @as(f32, @floatFromInt(m.icon_extent))) / 2;
                try writer.icon(
                    menu_rect,
                    @max(glyph_x, 0),
                    chevron_down_icon,
                    m.icon_extent,
                    if (props.remote_menu_enabled) .accent_bar else .muted_fg,
                );
            }
            if (frame.tree.find(build.NodeIds.fetch)) |fetch_index| {
                const chip = frame.tree.entries[fetch_index];
                // 꺼진 버튼은 **감추지 않고 흐리게** 둔다(§3.5 — 왜 안 되는지 말할 기회를 남긴다).
                //
                // **켜진 쪽은 `accent_bar`다(`focus_accent`가 아니다).** rich 토큰셋에서 `focus_accent`는
                // `sidebar_active`(배경색)를 밝힌 값이라 **글자색으로 쓰면 오히려 어둡다** — 제품 캡처
                // 실측(2026-08-18)에서 켜진 칩이 (128,132,140)이고 꺼진 `muted_fg`가 (207,207,207)이라
                // **꺼진 것이 더 밝은** 뒤집힌 화면이 나왔다. `accent_bar`는 테마의 시그니처 색이고
                // 탭 언더바·개수 배지가 이미 그 색이라, 같은 화면 안에서 "누를 수 있는 것"으로 읽힌다.
                const role: tokens.ColorRole = if (props.fetch.enabled and !props.fetch.running) .accent_bar else .muted_fg;
                try writer.centered(chip, fetch_label, role, .control);
                // ahead/behind는 그 **묶음 전체**(칩 + `∨`)를 비켜 앉는다. 칩 폭만 빼면 `∨` 위에 겹친다.
                const group_left = chip.rect.x;
                const row_right = rect.rect.x + rect.rect.width;
                fetch_right = @intFromFloat(@max(row_right - group_left, 0));
                fetch_right += m.gap;
            }
            if (props.has_ab) {
                // ── ahead/behind는 **조각 둘**이다(사용자 지적 2026-08-18). 한 문자열로 그리면 ⑴ 화살표와
                // 숫자가 붙어 읽기 어렵고 ⑵ 색이 하나라 "보낼 것"과 "받을 것"이 같은 무게로 보인다.
                // 목록이 이미 `+N` 초록 / `-N` 빨강을 쓰므로 같은 role을 그대로 빌려 온다 — 같은 패널
                // 안에서 색의 뜻이 갈리지 않는다. **0은 회색**이다: 색은 "할 일이 있다"는 신호여야 한다.
                var behind_buf: [24]u8 = undefined;
                var ahead_buf: [24]u8 = undefined;
                const behind_text = std.fmt.bufPrint(&behind_buf, "↓ {d}", .{props.behind}) catch "";
                const ahead_text = std.fmt.bufPrint(&ahead_buf, "↑ {d}", .{props.ahead}) catch "";
                const behind_w = try writer.trailingWidth(
                    rect,
                    behind_text,
                    if (props.behind > 0) .git_deleted_fg else .muted_fg,
                    .supporting,
                    fetch_right,
                );
                _ = try writer.trailingWidth(
                    rect,
                    ahead_text,
                    if (props.ahead > 0) .git_added_fg else .muted_fg,
                    .supporting,
                    fetch_right + behind_w + m.gap,
                );
            }
        }
    }

    // **커밋 입력·버튼은 여기 없다**(②b) — 저장소마다 하나씩이라 목록 줄로 내려갔다(위 루프).

    // `ChromeDraw`는 layer와 op 슬라이스만 든다 — run·text 바이트는 op이 빌려 가리키므로 호출자가
    // 준 버퍼의 수명이 곧 그 슬라이스의 수명이다(Session Dock과 같은 계약).
    return .{ .layer = painted.layer, .ops = writer.ops[0..writer.op_count] };
}

/// 커밋 버튼 글자색. **칠해진 면에서 되짚어 고른다** — 글자색을 `commit_enabled`만 보고 정하면
/// 호버에서 사라진다: 호버는 카드 배경을 `row_hover_bg`(어두움)로 **덮어쓰는데**(`paint_style`의 상태
/// 해석은 명시 paint보다 위다) 글자는 채운 면 전제의 `surface_bg`(어두움)로 남아 **어두운 글자가 어두운
/// 면 위**에 놓인다(적대적 검증 2026-08-16 — 켜진 버튼에 마우스를 올리면 라벨이 통째로 사라졌다).
///
/// 그래서 **painter와 같은 함수**(`resolveCard`)에 같은 입력을 물어 실제 배경을 받고, 그 위에서 읽히는
/// 색을 고른다. 두 번째 상태 표를 만들지 않는다.
fn commitLabelRole(
    entry: tree.RectEntry,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    enabled: bool,
) tokens.ColorRole {
    const visual = switch (entry.visual) {
        .card => |card| card,
        else => return if (enabled) .surface_bg else .muted_fg,
    };
    const resolved = paint_style.resolveCard(entry.id, visual, entry.action, state, tk);
    // 채운 면(accent) 위에서만 reverse다. 호버·눌림·비활성 면은 전부 어두우므로 보통 글자가 읽힌다.
    if (resolved.background == .accent_bar) return .surface_bg;
    return if (enabled) .surface_fg else .muted_fg;
}

/// 그 행이 **실제로 칠해진 배경**의 색 역할. 카드가 아니면 null이다(덮을 근거가 없으므로 안 덮는다).
///
/// `commitLabelRole`과 같은 규율이다 — 상태 표를 새로 만들지 않고 painter가 쓰는 `resolveCard`에
/// 같은 입력을 물어본다. 그래야 호버·눌림·비활성에서 색이 갈리지 않는다.
fn rowBackgroundRole(
    entry: tree.RectEntry,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
) ?tokens.ColorRole {
    const visual = switch (entry.visual) {
        .card => |card| card,
        else => return null,
    };
    return paint_style.resolveCard(entry.id, visual, entry.action, state, tk).background;
}

/// 빈 커밋 상자의 안내 문구. **컴포넌트가 소유한다** — platform이 넘기면 창마다 갈릴 수 있다.
fn commitPlaceholder() []const u8 {
    return i18n.t(.scm_commit_placeholder);
}
/// 커밋 버튼 라벨.
fn commitLabel() []const u8 {
    return i18n.t(.scm_commit);
}
/// 커밋이 도는 동안의 라벨.
fn commitRunningLabel() []const u8 {
    return i18n.t(.scm_committing);
}
/// 상한을 넘겨도 **죽이지 않는다**(쓰기 문서 §3) — 그래서 "실패"가 아니라 사실을 적는다.
fn commitSlowLabel() []const u8 {
    return i18n.t(.scm_commit_slow);
}
/// 랩 결과를 담을 시각 행 상한. **상자가 보여 줄 행 수가 아니라** 메시지 전체의 행 수다 — caret이
/// 몇 번째 줄에 있는지 알려면 보이지 않는 줄까지 세야 한다. 넘치면 `wrap`이 `truncated`로 말하고,
/// 그때 caret은 마지막 행으로 붙는다(그 사실을 감추는 것보다 낫다).
const commit_wrap_max_rows: usize = 256;
/// caret 두께. 1px은 Retina에서 사라지다시피 하고 3px은 글자 사이를 벌려 보이게 한다.
const caret_width_px: u32 = 2;

/// 탭 제목. 그룹 제목과 같은 이유로 **컴포넌트가 소유한다**.
fn tabTitle(tab: types.Tab) []const u8 {
    return switch (tab) {
        .changes => i18n.t(.scm_changes),
        .history => i18n.t(.scm_history),
        .agent => i18n.t(.common_role_assistant),
    };
}

/// 그룹 제목. **컴포넌트가 소유한다** — platform이 문자열을 넘기면 같은 목록의 제목이 창마다 갈릴 수 있다.
fn sectionTitle(section: types.Section) []const u8 {
    return switch (section) {
        .staged => i18n.t(.scm_staged),
        .changes => i18n.t(.scm_changes),
    };
}

fn actionOf(item: types.Item) types.RowAction {
    return switch (item) {
        .section => |section| section.action,
        .file => |file| file.action,
        // 히스토리 줄에는 행 동작이 없다(고르기뿐이다 — P4).
        .repo, .commit, .turn, .commit_file, .load_more, .commit_box, .commit_button, .more, .notice => .none,
    };
}

/// 머리 줄의 **동작 버튼 위**에 포인터가 있나. 버튼 위에서는 행 자체의 hover가 풀리므로(자식이
/// 가져간다) 이것도 함께 봐야 아이콘이 깜빡이지 않는다.
fn hoveredRepoAction(state: interaction.InteractionState, index: usize) bool {
    const hovered = state.hovered orelse return false;
    var slot: usize = 0;
    while (slot < build.repo_action_count) : (slot += 1) {
        if (hovered == build.NodeIds.repoAction(index, slot)) return true;
    }
    return false;
}

fn isHovered(state: interaction.InteractionState, id: tree.UiId) bool {
    const hovered = state.hovered orelse return false;
    return hovered == id;
}

fn clipRectOf(entry: tree.RectEntry) draw.Rect {
    return .{
        .x = @intFromFloat(@floor(entry.rect.x)),
        .y = @intFromFloat(@floor(entry.rect.y)),
        .w = @intFromFloat(@floor(entry.rect.width)),
        .h = @intFromFloat(@floor(entry.rect.height)),
    };
}

/// 상태 문자의 색. **모양(글자)과 함께** 쓰는 보조 신호라 색만으로 구분하지 않는다(§3.5.2).
fn statusRole(status: types.StatusKind) tokens.ColorRole {
    return switch (status) {
        .modified => .git_modified_fg,
        .added => .git_added_fg,
        .deleted => .git_deleted_fg,
        // 충돌은 "고쳐야 하는 것"이라 삭제와 같은 위험 계열을 쓴다 — 동작이 없다는 사실은 버튼의
        // 부재가 말한다.
        .conflicted => .git_deleted_fg,
    };
}

const Writer = struct {
    props: types.Props,
    cell_width_px: u32,
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    state: interaction.InteractionState,
    tokens_ref: *const tokens.Tokens,
    scroll_clipped: bool = false,
    active_clip: ?draw.Rect = null,
    container_clip: ?draw.Rect = null,

    /// 탭 칸 하나. **칸을 나누는 산수는 여기 없다** — `build`가 `fill = 1` 셋으로 나눠 둔 rect를 받는다.
    /// 그 결정이 두 곳에 있으면 P4·P5에서 히트테스트가 세 번째 벌을 만들게 된다.
    ///
    /// 갈 수 없는 탭도 **감추지 않고** 비활성으로 표시한다 — P1 계약이 그렇다. 탭 줄이 통째로 없으면
    /// 사용자는 이 뷰가 목록 하나뿐인 화면이라고 읽는다.
    fn tabSlot(self: *Writer, rect: tree.RectEntry, tab: types.Tab) ViewError!void {
        const scale = effectiveScale(self.props.scale_milli);
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        if (rect.rect.height < line_h or rect.rect.width <= 0) return;

        // 활성 탭 이름 옆에만 개수를 붙인다. 나머지 둘은 아직 셀 것이 없다(P4·P5).
        var buf: [48]u8 = undefined;
        const label: []const u8 = if (tab == .changes)
            std.fmt.bufPrint(&buf, "{s} ({d})", .{ tabTitle(tab), self.props.changed_file_count }) catch tabTitle(tab)
        else
            tabTitle(tab);

        const label_w = self.measureBudget(label);
        // 칸 안에서 가운데. 라벨이 칸보다 넓으면 왼쪽에 붙이고 칸 폭으로 자른다 — 가운데에 두면 잘린
        // 글자가 **양쪽** 이웃으로 넘친다.
        const fits = label_w <= rect.rect.width;
        const label_x = if (fits) rect.rect.x + (rect.rect.width - label_w) / 2 else rect.rect.x;
        const budget = if (fits) label_w else rect.rect.width;

        const active = tab == self.props.active_tab;
        // **비활성 탭은 색으로만 구별하지 않는다** — 굵기도 함께 간다(§3.5.2와 같은 규율).
        try self.emit(
            label_x,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            label,
            self.colsFor(budget),
            if (active) .surface_fg else .muted_fg,
            .control,
            active,
            @intFromFloat(budget),
            .origin,
        );

        // 활성 표시는 **밑줄**이고 라벨이 아니라 **칸 전체**를 긋는다(등분한 탭 줄의 관례 — 라벨 폭만
        // 그으면 칸 가운데에 짧은 막대가 떠 있는 꼴이 된다). 색은 테마 accent(`accent_bar`가 탭 언더바를
        // 소유하는 그 역할)이고, 탭 줄 아래 divider 위에 겹쳐 그린다.
        if (!active) return;
        const thickness = @max(spacing.px(.xxs, scale) / 2, 1);
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(rect.rect.x)),
                .y = @intFromFloat(@floor(rect.rect.y + rect.rect.height - @as(f32, @floatFromInt(thickness)))),
                .w = @intFromFloat(@floor(rect.rect.width)),
                .h = thickness,
            },
            .fill_role = .accent_bar,
        });
    }

    /// 그룹 헤더: `접힘표시 제목 · 개수 배지`. 개수는 오른쪽 끝에 고정한다 — 제목이 길어져도 밀려
    /// 사라지지 않는다.
    /// 저장소·워크트리 머리 줄(§3.5.1c). 목록의 첫 층이라 **한 줄에 넷**이 선다:
    /// 접힘 표시 · 종류 아이콘 · 이름 · (오른쪽) 브랜치와 개수 배지.
    ///
    /// **종류 아이콘과 브랜치 칩이 같은 글리프를 쓰지 않는다.** 워크트리 줄에 `⑂`가 둘이면 둘 중 무엇이
    /// 종류이고 무엇이 브랜치인지 읽히지 않는다 — 그래서 칩은 **글자만** 그린다.
    fn repoRow(self: *Writer, rect: tree.RectEntry, repo: types.RepoItem, m: types.DockMetrics) ViewError!void {
        const scale = effectiveScale(self.props.scale_milli);
        // **동작 아이콘 자리를 비워 두지 않는다**(사용자 지적 2026-08-19). 그전에는 늘 비켜 뒀는데,
        // 아이콘은 호버해야 나타나므로 평소 화면에는 **이유를 말하지 않는 빈 띠**만 52px 남았다.
        //
        // 그렇다고 호버할 때만 비키면 브랜치와 배지가 마우스를 따라 움직인다(2026-08-17에 그래서 예약을
        // 넣었다). 그래서 세 번째 답을 쓴다 — **자리는 안 비우고, 호버하면 그 위에 덮어 그린다**:
        // 아래에서 행 배경과 같은 색 사각형을 깔고 그 위에 아이콘을 놓는다. 히트 사각형은 build가
        // 늘 두므로 클릭 판정은 그대로다(어차피 호버해야 누를 수 있어 보이는 것과 눌리는 것이 안 갈린다).
        const inset: f32 = @floatFromInt(m.inset_x);
        const right_inset: u32 = m.inset_x;
        try self.icon(rect, inset, if (repo.collapsed) chevron_right_icon else chevron_down_icon, m.icon_extent, .muted_fg);
        // 주 워크트리는 폴더, 링크된 워크트리는 브랜치 글리프 — 워크트리는 "딸린 것"이라는 사실이
        // 보여야 같은 이름의 두 줄을 사용자가 구별한다.
        // **화살표와 붙지 않게 한 칸 띄운다**(사용자 지적 2026-08-19). 이 열은 그룹 제목·브랜치 글자가
        // 이미 서 있던 자리라, 아이콘만 6px 왼쪽에 혼자 있었던 셈이다.
        const kind_x = @as(f32, @floatFromInt(m.iconColumnX()));
        try self.icon(rect, kind_x, if (repo.primary) repo_icon else worktree_icon, m.icon_extent, .muted_fg);

        // 개수 배지는 **접혀 있어도** 그린다 — "여기 뭔가 있다"를 접힌 채로도 알아야 편다.
        // 아직 안 읽은 저장소는 배지 대신 문장을 적는다: 배지가 없는 것을 사용자는 "변경 없음"으로
        // 읽는데, 그건 **아직 모르는 것**과 다른 사실이다.
        var count_buf: [16]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{repo.count}) catch "";
        const pill = if (repo.count > 0 and !repo.pending and !repo.failed) badge.countPill(rect.rect, .{
            .inset_x = right_inset,
            .label_cols = @max(@as(u16, @intCast(count_text.len)), 1),
            .cell_width_px = self.cell_width_px,
            .scale_milli = scale,
            .fit = .snug,
            .label_role = .supporting,
        }) else null;

        const name_x = kind_x + @as(f32, @floatFromInt(m.icon_extent + m.gap));
        if (repo.pending or repo.failed) {
            // 오른쪽 자리를 그대로 쓴다(브랜치가 설 자리) — 읽고 나면 그 자리에 브랜치와 배지가 온다.
            // main의 i18n 라벨 함수와 ②c의 오른쪽 여백(아이콘 자리)을 **둘 다** 쓴다.
            const label = if (repo.failed) repoFailedLabel() else repoPendingLabel();
            try self.trailing(rect, label, .muted_fg, .supporting, right_inset);
            const budget = self.measureBudget(label) + @as(f32, @floatFromInt(m.gap + right_inset));
            try self.lineWithin(rect, name_x - rect.rect.x, rect.rect.x + rect.rect.width - budget, repo.name, .surface_fg, .control, true);
            return;
        }
        const right_edge: f32 = if (pill) |p|
            // 배지 왼쪽 여백은 `gap`보다 넓다 — 칠해진 알약이라 같은 간격이면 브랜치 이름에
            // 달라붙어 보인다(사용자 지적 2026-08-19: "11이 겹쳐 보인다").
            @as(f32, @floatFromInt(p.box.x)) - @as(f32, @floatFromInt(m.badgeGapPx()))
        else
            rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(right_inset));

        // 브랜치는 오른쪽에 붙는다(이름이 길면 이름이 먼저 잘린다 — 어느 저장소인지가 어느 브랜치인지보다
        // 앞선다). 자리를 못 잡으면 아예 안 그린다.
        var branch_width: f32 = 0;
        if (repo.branch.len > 0) {
            const w = self.measureBudget(repo.branch);
            const line_h: f32 = @floatFromInt(typography.lineHeightPx(.supporting, scale));
            const x = right_edge - w;
            if (x > name_x + @as(f32, @floatFromInt(m.gap)) and rect.rect.height >= line_h) {
                try self.emit(
                    x,
                    rect.rect.y + (rect.rect.height - line_h) / 2,
                    repo.branch,
                    self.colsFor(w),
                    .muted_fg,
                    .supporting,
                    false,
                    @intFromFloat(@max(w, 0)),
                    .origin,
                );
                branch_width = w + @as(f32, @floatFromInt(m.gap));
            }
        }

        // 이름은 **굵게** — 목록의 첫 층이고, 그 아래 그룹 제목(보통 굵기)과 층이 갈려야 한다.
        try self.lineWithin(rect, name_x - rect.rect.x, right_edge - branch_width, repo.name, .surface_fg, .control, true);

        if (pill) |placed| {
            // 그룹 헤더의 개수와 **같은 프리미티브·같은 색**이다 — 같은 뜻이 한 화면에서 다르게 보이면 안 된다.
            try self.appendQuad(.{
                .rect = placed.box,
                .fill_role = .accent_bar,
                .corner_radii = .{ placed.radius_px, placed.radius_px, placed.radius_px, placed.radius_px },
            });
            if (placed.label_fits) try self.emit(
                placed.label_x,
                placed.label_y,
                count_text,
                @max(@as(u16, @intCast(count_text.len)), 1),
                .surface_bg,
                .supporting,
                false,
                @intFromFloat(placed.label_w),
                .origin,
            );
        }
    }

    fn sectionRow(self: *Writer, rect: tree.RectEntry, section: types.SectionItem, m: types.DockMetrics) ViewError!void {
        const inset: f32 = @floatFromInt(m.inset_x);
        try self.icon(rect, inset, if (section.collapsed) chevron_right_icon else chevron_down_icon, m.icon_extent, .muted_fg);

        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{section.count}) catch "";
        const cols = @max(@as(u16, @intCast(count.len)), 1);
        const scale = effectiveScale(self.props.scale_milli);
        // 개수는 제목보다 작은 보조 정보다. **상자 높이가 이 역할의 줄높이에서 나오므로**(`.snug`)
        // 그리는 역할과 `label_role`이 같아야 한다 — 다르면 숫자가 상자보다 크거나 상자가 헐거워진다.
        const count_role: typography.ChromeTextRole = .supporting;
        // 개수는 **배지(pill)**다. 치수·자리·"안 들어가면 안 그린다"는 `ui/badge`가 소유한다 — 여기서
        // 다시 풀면 그 산수가 컴포넌트마다 갈리고, 실제로 pill이 행 밖으로 내려간 회귀가 그 산수였다.
        // Session Dock 그룹 개수와 같은 프리미티브·같은 색이다: 같은 뜻이 두 도크에서 다르게 보이면 안 된다.
        //
        // 동작 버튼 자리는 `reserved_x`로 넘긴다 — 호버 때 버튼이 떠도 배지가 그 아래 깔리지 않는다.
        const pill = badge.countPill(rect.rect, .{
            .inset_x = m.inset_x,
            .label_cols = cols,
            .cell_width_px = self.cell_width_px,
            .scale_milli = scale,
            .reserved_x = m.action_extent + m.gap,
            // 행이 24px로 촘촘하다. `roomy`면 상자가 행 높이를 그대로 먹어 지름 24px 원이 되고 행
            // 위아래 경계에 닿는다(사용자 지적 2026-08-15) — 라벨 기준으로 잡아 여백을 남긴다.
            .fit = .snug,
            .label_role = count_role,
        });

        // 제목은 **배지 왼쪽에서 멈춘다.** 폭을 안 줄이면 긴 제목이 배지 밑으로 파고든다.
        const title_x = rect.rect.x + @as(f32, @floatFromInt(m.iconColumnX())); // 같은 아이콘 열
        // 제목은 **오른쪽에 있는 것 전부**를 비켜선다: 배지, 그리고 그 왼쪽의 일괄 동작 버튼.
        // 배지만 기준으로 삼으면 그 사이에 앉은 버튼 위로 긴 제목이 그려진다(적대적 검증에서 잡혔다).
        const action_reserve: f32 = if (section.action != .none) @floatFromInt(m.action_extent + m.gap) else 0;
        const title_end: f32 = (if (pill) |p|
            @as(f32, @floatFromInt(p.box.x)) - @as(f32, @floatFromInt(m.gap))
        else
            rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x))) - action_reserve;
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        if (rect.rect.height >= line_h and title_end > title_x) {
            const width = title_end - title_x;
            try self.emit(
                title_x,
                rect.rect.y + (rect.rect.height - line_h) / 2,
                sectionTitle(section.section),
                self.colsFor(width),
                .surface_fg,
                .control,
                true,
                @intFromFloat(width),
                .origin,
            );
        }

        const placed = pill orelse return;
        // **채운 칩**이다(테두리만 있는 상자가 아니다 — 속이 빈 사각형으로 보였다). 색은 테마 accent
        // (`accent_bar`)이고 숫자는 `surface_bg`다: accent는 "사이드바 배경 위 글자로 읽히는 색"으로
        // 고른 값이라(같은 색을 `git_modified_fg`가 글자색으로 쓴다) 그 둘의 대비는 테마가 보장한다.
        // 반대로 `focus_accent`를 쓰면 포커스 신호와 겹쳐, 아무 데도 포커스가 없는데 있는 것처럼 보인다.
        try self.appendQuad(.{
            .rect = placed.box,
            .fill_role = .accent_bar,
            .corner_radii = .{ placed.radius_px, placed.radius_px, placed.radius_px, placed.radius_px },
        });
        // 라벨이 상자보다 높으면 **숫자만** 생략한다 — 배지·화살표·제목은 그대로 둔다.
        if (placed.label_fits)
            try self.emit(placed.label_x, placed.label_y, count, cols, .surface_bg, count_role, false, @intFromFloat(placed.label_w), .origin);
    }

    /// 파일 행: `아이콘 · 이름 · 흐린 경로 … +N -N · 상태 문자`. 폭이 좁아지면 **경로가 먼저** 줄어든다.
    fn fileRow(self: *Writer, rect: tree.RectEntry, file: types.FileItem, m: types.DockMetrics) ViewError!void {
        // 이름은 **아이콘 폭만큼 더** 들어간다. 그룹 헤더의 화살표 자리(`disclosure_extent`)만 비우면
        // 아이콘이 이름 위에 겹쳐 그려진다(제품 캡처에서 실제로 그랬다 — 슬롯 폭과 gap은 다른 값이다).
        const inset: f32 = @floatFromInt(m.iconColumnX() + m.icon_extent + m.gap);
        // **종류 아이콘은 탐색기와 같은 분류기**를 쓴다 — 같은 파일이 두 화면에서 다른 아이콘이면 안 된다.
        if (file_tree_icon.codepoint(file_tree_icon.classify(.file, file.name, false))) |cp| {
            var glyph_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &glyph_buf) catch 0;
            if (len > 0) try self.icon(rect, @floatFromInt(m.iconColumnX()), glyph_buf[0..len], m.icon_extent, .muted_fg);
        }
        // 상태 문자는 오른쪽 끝(VS Code 배치). 색은 종류가 정하고, 글자는 그대로 그린다.
        var letter_buf: [1]u8 = .{file.letter};
        try self.trailing(rect, letter_buf[0..], statusRole(file.status), .control, m.inset_x);

        // **호버한 행은 증감을 비운다.** 그 자리에 동작 버튼이 앉기 때문이다(VS Code도 호버하면 숫자가
        // 사라지고 아이콘이 뜬다). 안 비우면 글자가 버튼 quad 위에 겹쳐 그려진다 — 증감은 writer가
        // 배경 quad보다 나중에 내므로 버튼을 덮는다.
        const hovered_row = isHovered(self.state, rect.id);
        // **증감도 색을 갖는다**(목업이 그렇다 — `+14` 초록, `−59` 빨강). 한 덩어리로 그리면 둘 다
        // 흐린 회색이 되어 "얼마나 늘고 줄었나"가 한눈에 안 들어온다(사용자 지적 2026-08-14).
        var removed_buf: [16]u8 = undefined;
        var added_buf: [16]u8 = undefined;
        const delta_removed: []const u8 = if (file.has_delta) (std.fmt.bufPrint(&removed_buf, "-{d}", .{file.removed}) catch "") else "";
        const delta_added: []const u8 = if (file.has_delta) (std.fmt.bufPrint(&added_buf, "+{d}", .{file.added}) catch "") else "";

        var right_inset = m.inset_x + m.status_extent + m.gap;
        if (hovered_row) {
            // 아무것도 그리지 않는다(위 주석).
        } else if (file.binary) {
            try self.trailing(rect, "bin", .muted_fg, .supporting, right_inset);
        } else if (file.has_delta) {
            try self.trailing(rect, delta_removed, .git_deleted_fg, .supporting, right_inset);
            right_inset += @intFromFloat(self.measureBudget(delta_removed));
            right_inset += m.gap;
            try self.trailing(rect, delta_added, .git_added_fg, .supporting, right_inset);
        }

        // 이름은 굵게, 경로는 흐리게. 이름 뒤에 경로를 이어 그리되 폭 예산은 **이름 우선**이다.
        //
        // **오른쪽 자리를 비켜선다.** 이름·경로는 `trailing` 항목들보다 **나중에** 그려지므로, 예산이 행
        // 오른쪽 끝까지 열려 있으면 긴 경로가 증감·상태 문자를 덮는다(적대적 검증에서 잡혔다 —
        // 그리는 순서가 곧 z축이다).
        const right_used: f32 = @floatFromInt(m.inset_x + m.status_extent + m.gap);
        // **호버 여부와 무관하게 같은 폭을 비운다.** 그 자리를 증감이 쓰다가 호버하면 버튼이 쓰는데,
        // 둘 중 하나로만 예산을 잡으면 포인터를 스칠 때마다 말줄임 지점이 움직여 **이름이 늘었다 줄었다
        // 한다**(적대적 검증에서 잡혔다). 둘 중 큰 쪽을 항상 비워 두면 화면이 조용하다.
        const delta_occupied: f32 = if (file.binary)
            self.measureBudget("bin") + @as(f32, @floatFromInt(m.gap))
        else if (file.has_delta)
            self.measureBudget(delta_removed) + self.measureBudget(delta_added) + @as(f32, @floatFromInt(m.gap * 2))
        else
            0;
        const action_occupied: f32 = if (file.action != .none) @floatFromInt(m.action_extent + m.gap) else 0;
        const occupied = @max(delta_occupied, action_occupied);
        const text_end = rect.rect.x + rect.rect.width - right_used - occupied;
        try self.lineWithin(rect, inset, text_end, file.name, if (file.selected) .focus_accent else .surface_fg, .control, true);
        if (file.dir.len > 0) {
            const name_px = self.measureBudget(file.name);
            try self.lineWithin(rect, inset + name_px + @as(f32, @floatFromInt(m.gap)), text_end, file.dir, .muted_fg, .supporting, false);
        }
    }

    /// 글자 하나의 대략 폭. **정확한 advance는 backend가 안다** — 여기서는 경로를 이름 뒤에 놓기 위한
    /// 보수적 추정만 하고, 겹치면 backend의 `max_width_px` 예산이 자른다.
    fn measureBudget(self: *Writer, source: []const u8) f32 {
        const cols = text_layout.displayCols(source, null);
        return @floatFromInt(cols * self.cell_width_px);
    }

    /// 행 안의 한 줄. **행 높이 안에서 세로 중앙**이다 — 목록 rect처럼 큰 상자에서 부르면 글자가
    /// 한가운데로 내려가므로, 그런 자리는 `topLine`을 쓴다.
    fn line(self: *Writer, rect: tree.RectEntry, x_offset: f32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, bold: bool) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= x_offset) return;
        const width = rect.rect.width - x_offset;
        // 큰 상자(목록 content)에서는 중앙이 아니라 위에 붙인다 — 안내가 화면 한가운데 떠 있으면
        // 목록이 있다가 사라진 것처럼 보인다.
        const y = if (rect.rect.height > line_h * 3) rect.rect.y + line_h / 2 else rect.rect.y + (rect.rect.height - line_h) / 2;
        try self.emit(
            rect.rect.x + x_offset,
            y,
            source,
            self.colsFor(width),
            role,
            text_role,
            bold,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
    }

    /// `line`과 같되 **위에 붙인다.** 여러 줄 상자는 세로 중앙에 두면 글자가 상자 한가운데 떠서 다음
    /// 줄이 어디 올지 안 보인다 — 입력란은 위에서 아래로 자란다.
    fn topLine(self: *Writer, rect: tree.RectEntry, x_offset: f32, pad_y: f32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= x_offset) return;
        const width = rect.rect.width - x_offset - @as(f32, @floatFromInt(m_inset_fallback));
        if (width <= 0) return;
        try self.emit(
            rect.rect.x + x_offset,
            rect.rect.y + pad_y, // 위 여백은 metrics가 정한다 — 아래도 같은 값만큼 남는다
            source,
            self.colsFor(width),
            role,
            text_role,
            false,
            @intFromFloat(width),
            .origin,
        );
    }

    /// 커밋 메시지 상자 한 장 — 여러 줄 글자·선택 밴드·caret.
    ///
    /// **랩은 여기서 다시 돈다.** host가 준 `commit_rows`는 상자 *높이*이고, 어느 글자가 몇 번째 줄에
    /// 오는지는 그리는 쪽이 알아야 한다. 두 계산이 갈리지 않는 이유는 입력이 하나이기 때문이다 —
    /// 열 수는 `DockMetrics.commitViewCols`가 단일 출처이고 양쪽이 그것을 부른다.
    ///
    /// **가로 축은 `text_field.fieldLayout`이 소유한다**(§12.1). caret 열과 선택 span을 여기서 다시
    /// 풀면 "그려진 caret == 클릭 caret" 불변식이 두 벌이 되고, 그 둘은 주소창이 이미 지키고 있다.
    fn commitBox(self: *Writer, rect: tree.RectEntry, item: types.CommitBoxItem, m: types.DockMetrics) ViewError!void {
        const edit = item.edit;
        const scale = effectiveScale(self.props.scale_milli);
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        const pad_y: f32 = @floatFromInt(m.commit_pad_y);
        const inset: f32 = @floatFromInt(m.inset_x);
        if (rect.rect.height < line_h + pad_y or rect.rect.width <= inset * 2) return;

        // 빈 상자에는 **안내 문구**를 흐리게 둔다. 빈 채로 두면 어디를 눌러야 할지 알 수 없고, 그 자리가
        // 입력란이라는 사실이 화면에 없다. 편집 중이어도 비어 있으면 그대로 둔다 — caret이 그 위에 서서
        // 두 사실(여기가 입력란이다 / 지금 여기로 글자가 간다)을 함께 말한다.
        if (item.text.len == 0) {
            try self.topLine(rect, inset, pad_y, commitPlaceholder(), .muted_fg, .control);
            if (edit.focused and edit.caret_visible) try self.commitCaret(rect, m, 0, 0, line_h);
            return;
        }

        var lines_buf: [commit_wrap_max_rows]text_area.VisualLine = undefined;
        const cols = m.commitViewCols(rect.rect.width, self.cell_width_px);
        const wrapped = text_area.wrap(item.text, cols, true, &lines_buf);
        if (wrapped.lines.len == 0) return;

        const field: text_field.View = .{ .text = item.text, .caret = edit.caret };
        const caret_row = text_area.lineAt(wrapped, edit.caret);
        // 첫 행이 내용을 넘어서면(메시지가 줄어든 뒤 스크롤이 남았다) 마지막 행에 붙인다 — 빈 상자를
        // 보여 주는 것보다 낫다. 스크롤을 실제로 되돌리는 것은 host의 일이다(상태는 그쪽에 있다).
        const first: usize = @min(@as(usize, edit.first_row), wrapped.lines.len - 1);
        const visible = @min(@as(usize, @max(item.rows, 1)), wrapped.lines.len - first);
        const width = rect.rect.width - inset * 2;

        // **넘치면 그 사실을 막대로 말한다**(사용자 요청 2026-08-17). 글이 상자보다 길면 지금까지는
        // 화면에 아무 표시가 없어 "여기서 끝"으로 읽혔다. 자리는 `commitGutterPx`가 늘 비워 두므로
        // 막대가 나타나고 사라져도 글이 다시 접히지 않는다.
        try self.commitScrollbar(rect, m, wrapped.lines.len, first, visible, line_h, pad_y);

        for (0..visible) |offset| {
            const row = first + offset;
            const span_line = wrapped.lines[row];
            const y = rect.rect.y + pad_y + line_h * @as(f32, @floatFromInt(offset));
            var line_view = text_area.viewForLine(field, wrapped, row);

            // 선택은 **줄마다 잘라서** 넘긴다. 통째로 넘기면 `fieldLayout`이 한 줄 전제로 열을 재서
            // 두 번째 줄부터 밴드가 엉뚱한 자리에 선다.
            if (edit.selection) |sel| {
                const lo = std.math.clamp(sel.lo(), span_line.start, span_line.end);
                const hi = std.math.clamp(sel.hi(), span_line.start, span_line.end);
                if (hi > lo) line_view.selection = .{ .anchor = lo - span_line.start, .focus = hi - span_line.start };
            }
            const lay = text_field.fieldLayout(line_view, .{ .cols = cols });

            // 밴드를 글자보다 **먼저** 그린다 — 그리는 순서가 곧 z축이다.
            if (edit.focused) {
                if (lay.selection) |span| {
                    if (span.end_col > span.start_col) try self.appendQuad(.{
                        .rect = .{
                            .x = @intFromFloat(@floor(rect.rect.x + inset + self.colWidth(span.start_col))),
                            .y = @intFromFloat(@floor(y)),
                            .w = @intFromFloat(@max(self.colWidth(span.end_col - span.start_col), 1)),
                            .h = @intFromFloat(line_h),
                        },
                        .fill_role = .selection,
                    });
                }
            }
            if (line_view.text.len > 0) try self.emit(
                rect.rect.x + inset,
                y,
                line_view.text,
                cols,
                .surface_fg,
                .control,
                false,
                @intFromFloat(@max(width, 0)),
                .origin,
            );
            if (edit.focused and edit.caret_visible and row == caret_row) {
                try self.commitCaret(rect, m, lay.caret_col, offset, line_h);
            }
        }
    }

    /// 커밋 버튼 한 줄. **채운 면 위에서 읽히는 색**을 painter와 같은 함수에 물어 고른다.
    fn commitButton(
        self: *Writer,
        face: tree.RectEntry,
        item: types.CommitButtonItem,
        state: interaction.InteractionState,
        tk: *const tokens.Tokens,
        m: types.DockMetrics,
    ) ViewError!void {
        // **면 rect를 그대로 받는다**(아래 여백은 그 줄의 것이고 이 rect에 없다). 예전에는 줄 rect에서
        // 높이만 깎아 썼는데, 칠은 줄 전체가 받아 파랑이 여백까지 덮었다 — 글자가 그 띠의 가운데보다
        // 위에 앉는 이유였다(사용자 지적 2026-08-17).
        const role = commitLabelRole(face, state, tk, item.enabled);
        // 도는 동안은 **무슨 일이 일어나는지**를 그 자리에 적는다. 눌렀는데 라벨이 그대로면 사용자는
        // 다시 누르고, 두 번째 누름은 조용히 거부된다(쓰기는 하나씩이다).
        const label = switch (item.run) {
            .idle => commitLabel(),
            .running => commitRunningLabel(),
            .slow => commitSlowLabel(),
        };
        try self.centered(face, label, role, .control);
        // 분할 표시(`∨`) — 보조 메뉴가 붙을 자리다. 지금은 그 자리를 말만 한다.
        try self.icon(face, face.rect.width - @as(f32, @floatFromInt(m.inset_x + m.icon_extent)), chevron_down_icon, m.icon_extent, role);
    }

    /// 히스토리 목록의 커밋 **두 줄**(§3.5.3).
    ///
    /// 위: (있으면) ref 칩 + 제목. 아래: 작성자 · 상대시각 · 짧은 해시(흐리게).
    /// **제목이 마지막까지 남는다** — 좁은 도크에서 잘려야 하는 것은 부가 정보다.
    fn commitRow(self: *Writer, rect: tree.RectEntry, commit: types.CommitItem, m: types.DockMetrics) ViewError!void {
        const scale = effectiveScale(self.props.scale_milli);
        const inset: f32 = @floatFromInt(m.inset_x);
        const gap: f32 = @floatFromInt(m.gap);
        const title_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        const sub_h: f32 = @floatFromInt(typography.lineHeightPx(.supporting, scale));
        if (rect.rect.height < title_h + sub_h) return;
        const pad_y = (rect.rect.height - title_h - sub_h) / 2;

        // ── 첫 줄: ref 칩 + 제목.
        var left = rect.rect.x + inset;
        if (commit.ref.len > 0) {
            const w = self.measureBudget(commit.ref);
            if (left + w < rect.rect.x + rect.rect.width - inset) {
                // 지금 체크아웃된 브랜치만 강조색이다 — 나머지 ref는 상태 진술이라 흐리다.
                try self.emit(
                    left,
                    rect.rect.y + pad_y + (title_h - sub_h) / 2,
                    commit.ref,
                    self.colsFor(w),
                    if (commit.ref_is_head) .focus_accent else .muted_fg,
                    .supporting,
                    false,
                    @intFromFloat(@max(w, 0)),
                    .origin,
                );
                left += w + gap;
            }
        }
        const title_right = rect.rect.x + rect.rect.width - inset;
        // **접힌 ref는 `+N`으로 말한다**(§3.5.3). 그리지 않은 칩이 있다는 사실 자체가 정보다 — 없으면
        // 사용자는 그 커밋에 태그가 하나뿐이라고 읽는다.
        //
        // **제목이 마지막까지 남는다**: `+N`을 그린 뒤 제목에 최소 칸 수가 안 남으면 그리지 않는다.
        // 부가 정보가 "무엇을 한 커밋인가"를 밀어내면 이 목록의 쓸모가 사라진다.
        if (commit.ref_more > 0) {
            var buf: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "+{d}", .{commit.ref_more}) catch "";
            const w = self.measureBudget(text);
            const min_subject: f32 = @floatFromInt(m.commit_subject_min_cols * @max(self.cell_width_px, 1));
            if (text.len > 0 and left + w + gap + min_subject <= title_right) {
                try self.emit(
                    left,
                    rect.rect.y + pad_y + (title_h - sub_h) / 2,
                    text,
                    self.colsFor(w),
                    .muted_fg,
                    .supporting,
                    false,
                    @intFromFloat(@max(w, 0)),
                    .origin,
                );
                left += w + gap;
            }
        }
        if (title_right > left) {
            try self.emit(
                left,
                rect.rect.y + pad_y,
                commit.subject,
                self.colsFor(title_right - left),
                .surface_fg,
                .control,
                true,
                @intFromFloat(@max(title_right - left, 0)),
                .origin,
            );
        }

        // ── 둘째 줄: 작성자 · 상대시각 · 짧은 해시. **오른쪽부터** 자리를 잡는다(해시가 열 맞춤의 기준).
        const sub_y = rect.rect.y + pad_y + title_h;
        var right = rect.rect.x + rect.rect.width - inset;
        if (commit.short_oid.len > 0) {
            const w = self.measureBudget(commit.short_oid);
            try self.emitAt(right - w, sub_y, commit.short_oid, .muted_fg, .supporting);
            right -= w + gap;
        }
        if (commit.when.len > 0) {
            const w = self.measureBudget(commit.when);
            if (right - w > rect.rect.x + inset) {
                try self.emitAt(right - w, sub_y, commit.when, .muted_fg, .supporting);
                right -= w + gap;
            }
        }
        if (commit.author.len > 0) {
            const w = self.measureBudget(commit.author);
            const x = rect.rect.x + inset;
            if (x + w < right) try self.emitAt(x, sub_y, commit.author, .muted_fg, .supporting);
        }
    }

    /// 에이전트 탭의 턴 한 줄(P5 — §3.5.4).
    ///
    /// 위: 제목(`진행 중`·`마지막 턴`·`N턴 전`). 아래: 에이전트 · 상대시각(흐리게).
    /// **진행 중은 강조색**이다 — 그 줄만 오른쪽이 작업트리라 계속 변한다는 사실을 색이 말한다.
    fn turnRow(self: *Writer, rect: tree.RectEntry, turn: types.TurnItem, m: types.DockMetrics) ViewError!void {
        const scale = effectiveScale(self.props.scale_milli);
        const inset: f32 = @floatFromInt(m.inset_x);
        const gap: f32 = @floatFromInt(m.gap);
        const title_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        const sub_h: f32 = @floatFromInt(typography.lineHeightPx(.supporting, scale));
        if (rect.rect.height < title_h + sub_h) return;
        const pad_y = (rect.rect.height - title_h - sub_h) / 2;

        const left = rect.rect.x + inset;
        const right = rect.rect.x + rect.rect.width - inset;
        if (right > left) {
            try self.emit(
                left,
                rect.rect.y + pad_y,
                turn.title,
                self.colsFor(right - left),
                // **강조색을 쓰지 않는다**: 이 테마에서 그 역할은 본문보다 흐려서, 진행 중 줄이 오히려
                // 덜 중요해 보였다(제품 캡처 2026-08-18). "진행 중"이라는 말과 빈 시각이 이미 그 사실을
                // 말하므로 색을 하나 더 얹지 않는다.
                .surface_fg,
                .control,
                true,
                @intFromFloat(@max(right - left, 0)),
                .origin,
            );
        }

        const sub_y = rect.rect.y + pad_y + title_h;
        var sub_right = right;
        if (turn.when.len > 0) {
            const w = self.measureBudget(turn.when);
            if (sub_right - w > left) {
                try self.emitAt(sub_right - w, sub_y, turn.when, .muted_fg, .supporting);
                sub_right -= w + gap;
            }
        }
        if (turn.agent.len > 0 and left + self.measureBudget(turn.agent) < sub_right) {
            try self.emitAt(left, sub_y, turn.agent, .muted_fg, .supporting);
        }
    }

    /// 펼친 커밋 아래의 파일 한 줄(P4b). 파일 행과 같은 격자이되 **동작 버튼이 없다** — 지난 커밋의
    /// 파일은 스테이지할 대상이 아니다.
    fn commitFileRow(self: *Writer, rect: tree.RectEntry, file: types.CommitFileItem, m: types.DockMetrics) ViewError!void {
        // 그 커밋에 속한다는 것을 들여쓰기로 말한다(그룹 안의 파일 행과 같은 규율 — 같은 아이콘 열).
        const indent = @as(f32, @floatFromInt(m.iconColumnX()));
        if (file_tree_icon.codepoint(file_tree_icon.classify(.file, file.name, false))) |cp| {
            var icon_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &icon_buf) catch 0;
            if (len > 0) try self.icon(rect, indent, icon_buf[0..len], m.icon_extent, .muted_fg);
        }
        var letter_buf: [1]u8 = .{file.letter};
        try self.trailing(rect, letter_buf[0..], statusRole(file.status), .supporting, m.inset_x);
        const name_x = indent + @as(f32, @floatFromInt(m.icon_extent + m.gap));
        const right = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x + m.status_extent));
        try self.lineWithin(rect, name_x - rect.rect.x, right, file.name, .surface_fg, .control, true);
    }

    /// 글자 하나를 (x, y)에 그대로 놓는다(세로 가운데 계산 없이 — 두 줄 행이 자기 y를 안다).
    fn emitAt(
        self: *Writer,
        x: f32,
        y: f32,
        text: []const u8,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
    ) ViewError!void {
        const w = self.measureBudget(text);
        try self.emit(x, y, text, self.colsFor(w), role, text_role, false, @intFromFloat(@max(w, 0)), .origin);
    }

    /// 커밋 상자의 세로 스크롤바. **목록 스크롤바와 같은 기하 함수를 쓴다**(`scroll_area`) — 두 곳이
    /// 각자 비율을 계산하면 같은 화면에서 막대 길이 규칙이 갈린다.
    ///
    /// 지금은 **그리기만** 한다: 잡아 끄는 것은 목록 스크롤바가 하는 일이고, 상자 안 스크롤은 caret이
    /// 끌고 간다(§12.2). 그래도 그리는 이유는 "더 있다"가 화면에 없으면 사용자가 글이 잘렸다고 읽기
    /// 때문이다.
    fn commitScrollbar(
        self: *Writer,
        rect: tree.RectEntry,
        m: types.DockMetrics,
        total_rows: usize,
        first_row: usize,
        visible_rows: usize,
        line_h: f32,
        pad_y: f32,
    ) ViewError!void {
        if (total_rows <= visible_rows) return; // 다 보이면 막대는 거짓 신호다
        const gutter: f32 = @floatFromInt(m.commitGutterPx());
        const inset: f32 = @floatFromInt(m.inset_x);
        const view_h = line_h * @as(f32, @floatFromInt(visible_rows));
        const content: scroll_area.ContentRect = .{
            .x = rect.rect.x + inset,
            .y = rect.rect.y + pad_y,
            .w = rect.rect.width - inset * 2 - gutter,
            .h = view_h,
            .gutter_w = gutter,
        };
        const geometry = scroll_area.scrollbarGeometry(
            content,
            @intFromFloat(line_h * @as(f32, @floatFromInt(total_rows))),
            @intFromFloat(line_h * @as(f32, @floatFromInt(first_row))),
            m.scrollbarMetrics(),
        ) orelse return;
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(geometry.track_x)),
                .y = @intFromFloat(@floor(geometry.track_y)),
                .w = @intFromFloat(@max(geometry.track_w, 1)),
                .h = @intFromFloat(@max(geometry.track_h, 1)),
            },
            .fill_role = .inset_bg,
        });
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(geometry.track_x)),
                .y = @intFromFloat(@floor(geometry.thumb_y)),
                .w = @intFromFloat(@max(geometry.track_w, 1)),
                .h = @intFromFloat(@max(geometry.thumb_h, 1)),
            },
            .fill_role = .muted_fg,
        });
    }

    /// caret 하나. **글자 위가 아니라 글자 사이**에 서는 얇은 막대다 — 블록 caret은 터미널의 것이고,
    /// 여기서는 아래 글자가 가려지면 무엇을 고치는 중인지 안 보인다.
    fn commitCaret(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics, col: u32, row_offset: usize, line_h: f32) ViewError!void {
        const inset: f32 = @floatFromInt(m.inset_x);
        const x = rect.rect.x + inset + self.colWidth(col);
        // 상자 오른쪽 끝을 넘어가면 그리지 않는다 — 넘긴 caret은 테두리 위에 서서 다른 컨트롤처럼 보인다.
        if (x > rect.rect.x + rect.rect.width - inset) return;
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(x)),
                .y = @intFromFloat(@floor(rect.rect.y + @as(f32, @floatFromInt(m.commit_pad_y)) + line_h * @as(f32, @floatFromInt(row_offset)))),
                .w = caret_width_px,
                .h = @intFromFloat(line_h),
            },
            .fill_role = .cursor,
        });
    }

    /// 열 수 → 픽셀. 셀 폭은 `props`가 준 값 하나뿐이라 랩·caret·선택이 같은 자를 쓴다.
    fn colWidth(self: *Writer, cols: u32) f32 {
        return @floatFromInt(cols * self.cell_width_px);
    }

    /// `line`과 같되 **오른쪽 끝을 호출자가 준다.** 행 오른쪽에 이미 앉은 것(증감·상태 문자·동작 버튼)을
    /// 비켜서야 하는 글자가 쓴다 — 그리는 순서가 곧 z축이라, 나중에 그리는 글자가 예산을 넘으면 앞의
    /// 것을 덮는다.
    fn lineWithin(self: *Writer, rect: tree.RectEntry, x_offset: f32, end_x: f32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, bold: bool) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h) return;
        const start = rect.rect.x + x_offset;
        if (end_x <= start) return;
        const width = end_x - start;
        try self.emit(
            start,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            source,
            self.colsFor(width),
            role,
            text_role,
            bold,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
    }

    /// 오른쪽 끝에서 `right_inset`만큼 안쪽에 놓는 글자(개수·증감·상태 문자).
    fn trailing(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, right_inset: u32) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= 0) return;
        const width = self.measureBudget(source);
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(right_inset)) - width;
        if (x < rect.rect.x) return;
        try self.emit(
            x,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            source,
            self.colsFor(width),
            role,
            text_role,
            false,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
    }

    /// `trailing`의 **폭을 돌려주는** 판. 오른쪽 끝에서부터 조각을 여러 개 쌓을 때 쓴다 — 다음 조각의
    /// `right_inset`이 이 값에서 나온다. 못 그렸으면 0이라 그 자리만큼 다음 조각이 오른쪽으로 붙는다.
    fn trailingWidth(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, right_inset: u32) ViewError!u32 {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= 0) return 0;
        const width = self.measureBudget(source);
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(right_inset)) - width;
        if (x < rect.rect.x) return 0;
        try self.emit(
            x,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            source,
            self.colsFor(width),
            role,
            text_role,
            false,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
        return @intFromFloat(@max(width, 0));
    }

    /// rect 안에서 가로·세로 중앙에 놓는 글자(행 동작 버튼).
    fn centered(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole) ViewError!void {
        const line_h = typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli));
        if (rect.rect.height < @as(f32, @floatFromInt(line_h)) or rect.rect.width <= 0) return;
        const box = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x)),
            // **반올림한다**(내림이 아니라). 남는 높이가 홀수면 내림은 글자를 늘 위쪽으로 1px 밀고,
            // 28px 면 위의 17px 줄처럼 그 차가 눈에 띄는 자리가 있다(커밋 버튼 — 사용자 지적 2026-08-17).
            .y = @intFromFloat(@round(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(line_h))) / 2)),
            .w = @intFromFloat(@floor(rect.rect.width)),
            .h = line_h,
        };
        if (box.w == 0) return;
        // 전경은 quad를 칠한 그 함수에서 받는다 — variant만 보면 hover/press에서 배경색 글자가 배경 위에 얹힌다.
        const foreground: tokens.ColorRole = switch (rect.visual) {
            .button => |visual| paint_style.resolveButton(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            else => role,
        };
        try self.emitPlaced(
            @floatFromInt(box.x),
            @floatFromInt(box.y),
            source,
            self.colsFor(@floatFromInt(box.w)),
            foreground,
            text_role,
            false,
            box.w,
            .{ .center_in_rect = box },
            false,
        );
    }

    /// 등록 SVG 아이콘 하나. **터미널 셀이 아니라 logical 슬롯**에 놓는다(`icon_in_rect`) — 셀 경로로
    /// 그리면 아이콘이 행 높이와 무관하게 구워져 글자보다 크고 세로도 어긋난다(사용자 지적 2026-08-14).
    /// 슬롯은 행 안에서 세로 중앙이고, 한 변은 `DockMetrics.icon_extent`가 정한다.
    fn icon(self: *Writer, rect: tree.RectEntry, x_offset: f32, glyph: []const u8, extent: u32, role: tokens.ColorRole) ViewError!void {
        if (rect.rect.width <= x_offset or rect.rect.height <= 0) return;
        const size: f32 = @floatFromInt(extent);
        const slot = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x + x_offset)),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - size) / 2)),
            .w = extent,
            .h = extent,
        };
        const codepoint = std.unicode.utf8Decode(glyph) catch return;
        // PUA 바이트는 글자로 셰이핑되지 않는다(`icon_in_rect`가 등록 SVG를 직접 해석한다) — 다만 atlas
        // 요청의 안정된 입력으로 남긴다(빈 run은 어느 경로도 확실히 통과하지 못한다).
        try self.emitPlaced(
            @floatFromInt(slot.x),
            @floatFromInt(slot.y),
            glyph,
            1,
            role,
            .control,
            false,
            slot.w,
            .{ .icon_in_rect = .{ .content_rect = slot, .icon_codepoint = codepoint, .icon_extent_px = @intCast(extent) } },
            false,
        );
    }

    /// **모든** 장식 quad는 이 한 곳을 지난다. clip을 명시하지 않은 quad에는 지금 열려 있는 컨테이너의
    /// clip을 싣는다 — clip을 그리는 쪽의 opt-in으로 두면 한 군데만 빠뜨려도 그 quad가 스크롤 영역 밖으로
    /// 새어 고정 chrome 위에 그려진다(Session Dock에서 실제로 겪은 회귀다).
    fn appendQuad(self: *Writer, quad: draw.Op.Quad) ViewError!void {
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        var owned = quad;
        if (owned.clip == null) owned.clip = self.active_clip orelse self.container_clip;
        self.ops[self.op_count] = .{ .quad = owned };
        self.op_count += 1;
    }

    fn colsFor(self: *Writer, width_px: f32) u16 {
        const cols = @floor(width_px / @as(f32, @floatFromInt(self.cell_width_px)));
        return @intFromFloat(@min(@max(cols, 1), @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    }

    fn emit(
        self: *Writer,
        x: f32,
        y: f32,
        source: []const u8,
        cols: u16,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        bold: bool,
        max_width_px: ?u32,
        placement: draw.TextPlacement,
    ) ViewError!void {
        return self.emitPlaced(x, y, source, cols, role, text_role, false, max_width_px, placement, bold);
    }

    fn emitPlaced(
        self: *Writer,
        x: f32,
        y: f32,
        source: []const u8,
        cols: u16,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        wide_icons: bool,
        max_width_px: ?u32,
        placement: draw.TextPlacement,
        bold: bool,
    ) ViewError!void {
        if (cols == 0 or source.len == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        // 원문을 그대로 넘긴다 — 말줄임은 실제 advance를 아는 backend가 정한다(여기서 미리 자르면
        // 그 정보가 사라져 두 렌더러가 다른 글자를 그린다).
        const start = self.text_count;
        if (source.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        @memcpy(self.text_bytes[self.text_count..][0..source.len], source);
        self.text_count += source.len;
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) },
            .runs = self.runs[self.run_count .. self.run_count + 1],
            .role = role,
            .text_role = text_role,
            .max_cols = cols,
            .anchor = .head,
            .wide_icons = wide_icons,
            .max_width_px = max_width_px,
            .placement = placement,
            .scroll_clipped = self.scroll_clipped,
            .clip = self.active_clip orelse self.container_clip,
        } };
        self.run_count += 1;
        self.op_count += 1;
    }
};

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

const testing = std.testing;

fn countTextOps(draws: draw.ChromeDraw) usize {
    var count: usize = 0;
    for (draws.ops) |op| switch (op) {
        .text => count += 1,
        else => {},
    };
    return count;
}

/// **정확히 그 글자만** 담은 text op. 부분 일치로 찾으면 요약 줄의 `+12 -3`이 행 동작의 `+`로 오인된다
/// (적대적 검증에서 이 테스트가 실제로 그렇게 통과할 뻔했다).
fn countAllQuads(draws: draw.ChromeDraw) usize {
    var n: usize = 0;
    for (draws.ops) |op| switch (op) {
        .quad => n += 1,
        else => {},
    };
    return n;
}

fn findExactText(draws: draw.ChromeDraw, needle: []const u8) ?draw.Op.Text {
    for (draws.ops) |op| switch (op) {
        .text => |text| {
            for (text.runs) |run| {
                if (std.mem.eql(u8, run.text, needle)) return text;
            }
        },
        else => {},
    };
    return null;
}

/// 탭 줄 fixture — 탭 줄만 보는 테스트는 목록이 필요 없다.
fn renderTabs(storage: *TestStorage, width: f32, count: u32) !draw.ChromeDraw {
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = width, .height = 400 },
        .branch = "main",
        .changed_file_count = count,
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    return viewBudgeted(storage, props, frame, .{});
}

/// 활성 탭 밑줄(위 `badge_min_height`가 배지와 가른다).
fn findTabUnderline(draws: draw.ChromeDraw) ?draw.Op.Quad {
    for (draws.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == .accent_bar and quad.rect.h < badge_min_height) return quad,
        else => {},
    };
    return null;
}

/// 배지와 활성 탭 밑줄을 가르는 높이. 둘 다 `accent_bar`이고 **둘 다 각지므로**(목록은 캡슐이 아니다)
/// 모양으로는 못 가른다 — 밑줄은 얇은 막대이고 배지는 글자가 들어가는 상자다.
const badge_min_height: u32 = 6;

/// 개수 배지 quad.
fn findBadgeQuad(draws: draw.ChromeDraw) ?draw.Op.Quad {
    for (draws.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == .accent_bar and quad.rect.h >= badge_min_height) return quad,
        else => {},
    };
    return null;
}

fn findText(draws: draw.ChromeDraw, needle: []const u8) ?draw.Op.Text {
    for (draws.ops) |op| switch (op) {
        .text => |text| {
            for (text.runs) |run| {
                if (std.mem.indexOf(u8, run.text, needle) != null) return text;
            }
        },
        else => {},
    };
    return null;
}

const TestStorage = struct {
    /// 커밋 줄 fixture가 쓰는 항목 둘(상자·버튼). props는 슬라이스를 빌리므로 저장소가 들고 있어야 한다.
    commit_items: [2]types.Item = undefined,
    nodes: [32]tree.UiNode = undefined,
    entries: [40]tree.RectEntry = undefined,
    layout_items: [40]@import("../../ui/layout.zig").Item = undefined,
    flex_scratch: [40]@import("../../ui/layout.zig").FlexScratch = undefined,
    child_rects: [40]@import("../../ui/layout.zig").UiRect = undefined,
    actions: [40]@import("ids.zig").Entry = undefined,
    ops: [128]draw.Op = undefined,
    runs: [64]draw.Run = undefined,
    text_bytes: [2048]u8 = undefined,
};

/// 테스트도 **host와 같은 예산으로** 그린다. 넉넉한 버퍼를 그냥 넘기면 `drawBufferSizes`가 낡아도
/// 테스트만 통과하고 제품은 빈 화면이 된다 — 실제로 그랬다(2026-08-16 GUI 확인: 커밋 줄 세 조각이
/// 예산 밖이라 **깨끗한 저장소**에서 `view`가 실패했고, 목록이 아니라 **도크가 통째로** 사라졌다.
/// 그때 이 파일의 빈 목록 테스트는 초록이었다 — 예산이 아니라 고정 버퍼로 그렸기 때문이다).
fn viewBudgeted(
    storage: *TestStorage,
    props: types.Props,
    frame: build.Frame,
    state: interaction.InteractionState,
) !draw.ChromeDraw {
    const budget = drawBufferSizes(props, frame.tree.entries.len);
    // 픽스처 버퍼가 예산보다 작으면 **예산이 아니라 픽스처가 틀린 것**이다. 조용히 줄여 그리면 이
    // 테스트가 다시 예산을 안 보게 된다.
    if (budget.ops > storage.ops.len or budget.runs > storage.runs.len or budget.text_bytes > storage.text_bytes.len)
        return error.TestStorageTooSmall;
    const tk = testTokens();
    return view(props, frame, state, &tk, .{
        .ops = storage.ops[0..budget.ops],
        .runs = storage.runs[0..budget.runs],
        .text_bytes = storage.text_bytes[0..budget.text_bytes],
    });
}

fn testTokens() tokens.Tokens {
    return tokens.Tokens.base(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
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
}

fn renderFixture(storage: *TestStorage, state: interaction.InteractionState, items: []const types.Item) !draw.ChromeDraw {
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = items,
        .branch = "main",
        .has_ab = true,
        .ahead = 2,
        .summary = .{ .added = 12, .removed = 3 },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    return viewBudgeted(storage, props, frame, state);
}

test "행 글자와 요약·브랜치가 한 번에 나온다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 2, .collapsed = false, .action = .stage } },
        .{ .file = .{ .name = "scm_view.zig", .dir = "src/session/", .status = .modified, .letter = 'M', .added = 4, .removed = 2, .has_delta = true, .action = .stage } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findText(draws, i18n.t(.scm_changes)) != null); // 그룹 제목
    try testing.expect(findText(draws, "scm_view.zig") != null);
    try testing.expect(findText(draws, "src/session/") != null);
    // 증감은 **두 조각**이다 — 색이 다르기 때문이다(늘어난 것 초록, 줄어든 것 빨강).
    try testing.expectEqual(tokens.ColorRole.git_added_fg, findExactText(draws, "+4").?.role);
    try testing.expectEqual(tokens.ColorRole.git_deleted_fg, findExactText(draws, "-2").?.role);
    try testing.expectEqual(tokens.ColorRole.git_added_fg, findExactText(draws, "+12").?.role); // 요약 줄
    try testing.expectEqual(tokens.ColorRole.git_deleted_fg, findExactText(draws, "-3").?.role);
    try testing.expect(findText(draws, "main") != null); // 브랜치 줄
    try testing.expect(findText(draws, "↑ 2") != null);
}

test "상태 문자는 종류마다 다른 색 역할로 나온다(색만으로 구분하지 않되, 색은 다르다)" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "a", .dir = "", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const modified = try renderFixture(&storage, .{}, &items);
    try testing.expectEqual(tokens.ColorRole.git_modified_fg, findExactText(modified, "M").?.role);

    var storage2: TestStorage = .{};
    const added_items = [_]types.Item{
        .{ .file = .{ .name = "b", .dir = "", .status = .added, .letter = 'A', .action = .stage } },
    };
    const added = try renderFixture(&storage2, .{}, &added_items);
    try testing.expectEqual(tokens.ColorRole.git_added_fg, findExactText(added, "A").?.role);

    var storage3: TestStorage = .{};
    const deleted_items = [_]types.Item{
        .{ .file = .{ .name = "c", .dir = "", .status = .deleted, .letter = 'D', .action = .stage } },
    };
    const deleted = try renderFixture(&storage3, .{}, &deleted_items);
    try testing.expectEqual(tokens.ColorRole.git_deleted_fg, findExactText(deleted, "D").?.role);
}

test "행 동작은 호버할 때만 보인다(히트 사각형은 항상 있다)" {
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .stage } },
    };
    var idle_storage: TestStorage = .{};
    const idle = try renderFixture(&idle_storage, .{}, &items);
    try testing.expect(findExactText(idle, "+") == null);

    var hover_storage: TestStorage = .{};
    const hovered = try renderFixture(&hover_storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    try testing.expect(findExactText(hovered, "+") != null);
}

test "언스테이지 행은 `−`를 낸다(같은 자리, 다른 방향)" {
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .unstage } },
    };
    var storage: TestStorage = .{};
    const hovered = try renderFixture(&storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    try testing.expect(findExactText(hovered, "−") != null);
    try testing.expect(findExactText(hovered, "+") == null);
}

test "안내 행은 강조색을 쓰지 않는다(상태 진술이지 컨트롤이 아니다)" {
    const items = [_]types.Item{
        .{ .notice = "git 출력이 너무 커서 목록이 잘렸습니다" },
    };
    var storage: TestStorage = .{};
    const draws = try renderFixture(&storage, .{}, &items);
    const text = findText(draws, "잘렸습니다") orelse return error.MissingNotice;
    try testing.expectEqual(tokens.ColorRole.muted_fg, text.role);
}

test "히스토리 커밋 줄은 두 줄이다(제목이 마지막까지 남는다) (P4)" {
    // 한 줄에 몰면 좁은 도크에서 제목이 거의 안 남는다 — 목록에서 가장 중요한 것이 "무엇을 한 커밋인가"다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{
            .index = 0,
            .subject = "feat(dock): 히스토리 탭",
            .author = "ohah",
            .when = "2시간 전",
            .short_oid = "abcdef1",
            .ref = "main",
            .ref_is_head = true,
        } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const title = findText(draws, "히스토리 탭") orelse return error.MissingSubject;
    const author = findText(draws, "ohah") orelse return error.MissingAuthor;
    const oid = findText(draws, "abcdef1") orelse return error.MissingOid;
    // 보조 정보는 **제목 아래**에 온다.
    try testing.expect(author.origin.y > title.origin.y);
    try testing.expectEqual(author.origin.y, oid.origin.y);
    // 해시는 오른쪽 끝, 작성자는 왼쪽 끝이다.
    try testing.expect(oid.origin.x > author.origin.x);
    // 체크아웃된 브랜치 칩만 강조색이다.
    const ref = findText(draws, "main") orelse return error.MissingRef;
    try testing.expectEqual(tokens.ColorRole.focus_accent, ref.role);
}

test "아직 안 보낸 것이 있으면 브랜치 이름 뒤에 점이 선다 (§3.5)" {
    // **개수가 아니라 사실 하나다**(2026-08-19 사용자 결정) — 위 `↑`/`↓`는 기본 브랜치 기준이라,
    // 기준이 다른 숫자를 그 옆에 놓으면 어느 쪽이 무엇인지 읽을 수 없다.
    var storage: TestStorage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "feat/x",
        .has_ab = true,
        .ahead = 3,
        .unpushed = true,
        .fetch = .{ .enabled = true },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});
    const name = findExactText(draws, "feat/x") orelse return error.MissingBranch;
    const dot = findExactText(draws, "●") orelse return error.MissingDot;
    // 이름 **뒤**에 서고, 오른쪽 묶음(↑↓)보다는 앞이다.
    try testing.expect(dot.origin.x > name.origin.x);
    const ahead = findExactText(draws, "↑ 3") orelse return error.MissingAhead;
    try testing.expect(dot.origin.x < ahead.origin.x);
    // 색은 "할 일이 있다"는 신호 — 테마 시그니처 색이다(꺼진 회색이 아니다).
    try testing.expectEqual(tokens.ColorRole.accent_bar, dot.role);

    // 보낼 것이 없으면 점도 없다 — 늘 켜져 있으면 아무 말도 하지 않는다.
    var storage_clean: TestStorage = .{};
    var clean = props;
    clean.unpushed = false;
    const clean_frame = try build.build(clean, .{
        .nodes = &storage_clean.nodes,
        .entries = &storage_clean.entries,
        .layout_items = &storage_clean.layout_items,
        .flex_scratch = &storage_clean.flex_scratch,
        .child_rects = &storage_clean.child_rects,
        .actions = &storage_clean.actions,
    });
    const clean_draws = try viewBudgeted(&storage_clean, clean, clean_frame, .{});
    try testing.expect(findExactText(clean_draws, "●") == null);
}

test "원격 갱신 칩과 ahead/behind는 같은 줄에서 겹치지 않는다 (P6)" {
    // 둘 다 브랜치 줄의 **오른쪽 끝**을 노린다 — 칩을 비켜 두지 않으면 `↑2 ↓0`이 그 위에 그려진다
    // (머리 줄 동작 아이콘에서 이미 한 번 겪은 겹침).
    var storage: TestStorage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .has_ab = true,
        .ahead = 2,
        .behind = 1,
        .fetch = .{ .enabled = true },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});

    const chip = findText(draws, i18n.t(.scm_fetch)) orelse return error.MissingFetchLabel;
    // **켜진 칩은 강조색이다** — 꺼진 것과 같은 회색이면 "누를 수 있다"가 화면에 하나도 안 남는다
    // (브랜치 줄에는 행 호버 밴드가 없어서 색이 유일한 신호다).
    try testing.expectEqual(tokens.ColorRole.accent_bar, chip.role);
    // ahead/behind는 조각 둘이고 **색이 갈린다**: 보낼 것은 초록(`+N`과 같은 role), 받을 것은 빨강.
    const ahead = findExactText(draws, "↑ 2") orelse return error.MissingAheadBehind;
    const behind = findExactText(draws, "↓ 1") orelse return error.MissingAheadBehind;
    try testing.expectEqual(tokens.ColorRole.git_added_fg, ahead.role);
    try testing.expectEqual(tokens.ColorRole.git_deleted_fg, behind.role);
    // 왼쪽부터 `↑` → `↓` → 칩 순서다. 같은 자리면 글자가 포개져 셋 다 못 읽는다.
    try testing.expect(ahead.origin.x < behind.origin.x);
    try testing.expect(behind.origin.x < chip.origin.x);
    // `∨`(P6b)도 그려지고, ahead/behind는 **묶음 전체**를 비켜 앉는다 — 칩 폭만 빼면 그 위에 겹친다.
    const menu_rect = frame.tree.entries[frame.tree.find(build.NodeIds.remote_menu) orelse return error.MissingRemoteMenu].rect;
    try testing.expect(@as(f32, @floatFromInt(behind.origin.x)) < menu_rect.x);
    // 칩은 브랜치 줄의 rect 안에 있다 — 글자가 tree가 준 자리를 벗어나면 히트 사각형과 어긋난다.
    const chip_rect = frame.tree.entries[frame.tree.find(build.NodeIds.fetch) orelse return error.MissingFetch].rect;
    try testing.expect(@as(f32, @floatFromInt(chip.origin.x)) >= chip_rect.x);
    try testing.expect(@as(f32, @floatFromInt(chip.origin.x)) < chip_rect.x + chip_rect.width);
}

test "도는 중에는 칩이 그 사실을 말한다 (P6)" {
    // 눌렀는데 표시가 없으면 사용자는 다시 누르고, 두 번째 누름은 조용히 거부된다(커밋 버튼과 같은 이유).
    var storage: TestStorage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .fetch = .{ .enabled = true, .running = true },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});
    // **정확히 그 문구다.** 부분 일치로 보면 영어에서 `Fetching…`이 `Fetch`를 포함해 둘 다 통과한다.
    var seen_running = false;
    var seen_idle = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, i18n.t(.scm_fetching))) seen_running = true;
            if (std.mem.eql(u8, run.text, i18n.t(.scm_fetch))) seen_idle = true;
        },
        else => {},
    };
    try testing.expect(seen_running);
    try testing.expect(!seen_idle); // 두 문구가 함께 뜨지 않는다
}

test "ref가 여럿이면 `+N`으로 접고, 좁으면 제목이 남는다 (§3.5.3)" {
    // 접힌 칩이 있다는 **사실 자체가 정보**다 — 없으면 사용자는 그 커밋에 태그가 하나뿐이라고 읽는다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "제목", .author = "a", .when = "방금", .short_oid = "abc1234", .ref = "main", .ref_is_head = true, .ref_more = 2 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const chip = findExactText(draws, "main") orelse return error.MissingChip;
    const more = findExactText(draws, "+2") orelse return error.MissingMore;
    const subject = findExactText(draws, "제목") orelse return error.MissingSubject;
    // 왼쪽부터 칩 → `+N` → 제목. 같은 자리면 셋 다 못 읽는다.
    try testing.expect(chip.origin.x < more.origin.x);
    try testing.expect(more.origin.x < subject.origin.x);
    // 접힘 표시는 상태 진술이라 흐리다(체크아웃된 브랜치 칩만 강조색이다).
    try testing.expectEqual(tokens.ColorRole.muted_fg, more.role);

    // 접을 것이 없으면 그리지 않는다 — `+0`은 아무 말도 하지 않는다.
    var storage_one: TestStorage = .{};
    const one = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "제목", .author = "a", .when = "방금", .short_oid = "abc1234", .ref = "main", .ref_more = 0 } },
    };
    const one_draws = try renderFixture(&storage_one, .{}, &one);
    try testing.expect(findExactText(one_draws, "+0") == null);
}

test "좁은 줄에서는 `+N`이 먼저 사라진다 — 제목이 마지막까지 남는다 (§3.5.3)" {
    // 부가 정보가 "무엇을 한 커밋인가"를 밀어내면 이 목록의 쓸모가 사라진다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "제목", .author = "a", .when = "방금", .short_oid = "abc1234", .ref = "release-candidate-2026", .ref_more = 3 } },
    };
    const props: types.Props = .{
        // 칩을 그리고 나면 제목 최소 칸(8칸)만 겨우 남는 폭 — 여기에 `+N`까지 넣으면 제목이 그 아래로
        // 내려간다. 더 좁히면 제목 자체가 잘려 "제목이 남는다"를 문자열로 확인할 수 없다.
        .viewport_px = .{ .x = 0, .y = 0, .width = 260, .height = 200 },
        .items = &items,
        .active_tab = .history,
        .show_summary = false,
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});
    try testing.expect(findExactText(draws, "+3") == null); // 접힘 표시가 먼저 빠진다
    try testing.expect(findExactText(draws, "제목") != null); // 제목은 남는다
}

test "커밋 상자는 글이 넘치면 스크롤바로 그 사실을 말한다" {
    // 넘치는데 표시가 없으면 사용자는 **글이 잘렸다**고 읽는다(사용자 요청 2026-08-17).
    var storage: TestStorage = .{};
    const short_text = "한 줄";
    const long_text = "가나다라마바사아자차카타파하 " ** 40; // 상한(8행)을 확실히 넘긴다
    const short_items = [_]types.Item{
        .{ .commit_box = .{ .repo_index = 0, .rows = 1, .text = short_text } },
    };
    const short_draws = try renderFixture(&storage, .{}, &short_items);
    const short_quads = countAllQuads(short_draws);

    var storage2: TestStorage = .{};
    const long_items = [_]types.Item{
        .{ .commit_box = .{ .repo_index = 0, .rows = 8, .text = long_text } },
    };
    const long_draws = try renderFixture(&storage2, .{}, &long_items);
    // 막대 + thumb 둘이 더 나온다 — 다 보이는 상자에는 없다(거짓 신호가 되므로).
    try testing.expectEqual(short_quads + 2, countAllQuads(long_draws));
}

test "머리 줄의 동작 아이콘은 브랜치 칩·개수 배지를 덮지 않는다 (②c)" {
    // 자리를 비켜 두지 않으면 아이콘이 그 위에 겹쳐 그려져 둘 다 못 읽는다(제품 캡처 2026-08-17).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "repo", .branch = "main", .count = 3, .can_stage_all = true } },
    };
    const draws = try renderFixture(&storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    const branch = findText(draws, "main") orelse return error.MissingBranch;
    // 아이콘 둘은 그 오른쪽에 앉는다 — 겹치면 x가 브랜치 글자 안으로 들어온다.
    var icon_left: i32 = std.math.maxInt(i32);
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            // 아이콘 조각은 글리프 하나짜리 문자열이다(`utf8Fit`) — 그 조각만 골라 본다.
            if (!std.mem.eql(u8, run.text, refresh_icon) and !std.mem.eql(u8, run.text, stage_all_icon)) continue;
            icon_left = @min(icon_left, text.origin.x);
        },
        else => {},
    };
    try testing.expect(icon_left < std.math.maxInt(i32)); // 아이콘이 실제로 그려졌다(호버 중)
    try testing.expect(icon_left > branch.origin.x);
}

test "읽지 못한 저장소는 0건이 아니라 그 사실을 적는다" {
    // 배지가 없거나 `0`이면 사용자는 "변경 없음"으로 읽는다 — 우리는 그 사실을 **모른다**.
    // 그리고 "읽는 중…"과도 달라야 한다: 그쪽은 곧 온다는 약속이다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "gone-wt", .primary = false, .failed = true } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    // 원문 대신 키로 비교한다 — 이 테스트가 재는 것은 **어느 사실을 적는가**이고, 그것은 키가
    // 더 정확히 드러낸다(원문 비교는 표시 언어에 묶여 기본값이 로케일을 따라가면 깨진다).
    try testing.expect(findText(draws, i18n.t(.scm_load_failed)) != null);
    try testing.expect(findText(draws, i18n.t(.scm_loading)) == null);
}

test "변경이 없다는 말은 그 저장소 줄 **아래**에 온다(겹치지 않는다)" {
    // 예전에는 스크롤 영역 rect 위쪽에 직접 그렸다. 목록의 첫 층이 저장소가 되면서 그 자리에 머리 줄이
    // 서고, 두 글자가 **한자리에 겹쳐** 둘 다 못 읽는 화면이 됐다(제품 캡처 2026-08-17).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "clean-probe", .branch = "main", .primary = true } },
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .commit_button = .{ .repo_index = 0 } },
        .{ .notice = "변경 사항 없음" },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const notice = findText(draws, "변경 사항 없음") orelse return error.MissingNotice;
    try testing.expectEqual(tokens.ColorRole.muted_fg, notice.role);
    const repo = findText(draws, "clean-probe") orelse return error.MissingRepoRow;
    try testing.expect(notice.origin.y > repo.origin.y);
}

test "아이콘은 셀이 아니라 logical 슬롯에 놓인다(행 높이에 맞는 크기)" {
    // 셀 경로로 그리면 아이콘이 행 높이와 무관하게 구워져 글자보다 크고 세로도 어긋난다(사용자 지적
    // 2026-08-14: "화살표랑 하단 아이콘 별론데"). 슬롯 배치는 그 크기를 `DockMetrics`가 정하게 한다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 1, .collapsed = false, .action = .none } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const m = types.DockMetrics.resolve(1000);
    var saw_icon = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .icon_in_rect => |placed| {
                saw_icon = true;
                // 슬롯은 정사각이고 한 변이 metrics 값이며, **행 높이를 넘지 않는다**.
                try testing.expectEqual(m.icon_extent, placed.content_rect.w);
                try testing.expectEqual(m.icon_extent, placed.content_rect.h);
                try testing.expectEqual(@as(u16, @intCast(m.icon_extent)), placed.icon_extent_px);
                try testing.expect(placed.content_rect.h <= m.section_h);
                // 셀 2칸 폭을 쓰던 옛 경로의 흔적(`wide_icons`)이 남아 있으면 안 된다.
                try testing.expect(!text.wide_icons);
            },
            else => {},
        },
        else => {},
    };
    try testing.expect(saw_icon);
}

test "파일 행에 종류 아이콘이 붙는다(탐색기와 같은 분류기)" {
    // 같은 파일이 두 화면에서 다른 아이콘이면 안 된다. 아이콘은 이름으로만 정해지므로 확장자가 다른
    // 두 파일이 서로 다른 슬롯을 받는지로 그 연결을 고정한다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    var icons_seen: usize = 0;
    for (draws.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .icon_in_rect => icons_seen += 1,
            else => {},
        },
        else => {},
    };
    // 파일 종류 + 브랜치 줄 아이콘 + 브랜치 줄 `∨`(P6b) = 셋. 그룹 헤더가 없는 fixture이고, **커밋 버튼의
    // `∨`는 이제 목록 항목**이라 여기 없다(②b에서 커밋 줄이 저장소 그룹 안으로 내려갔다).
    //
    // **`∨`가 아이콘 경로로 세어져야 한다**: 글자 경로로 그리면 폰트 폴백이 작은 네모를 낸다(실측).
    try testing.expectEqual(@as(usize, 3), icons_seen);
}

test "파일 이름은 아이콘 슬롯을 침범하지 않는다" {
    // 슬롯 폭(`icon_extent`)과 간격(`gap`)은 다른 값이다. 이름 들여쓰기에 아이콘 폭을 빼먹으면 글자가
    // 아이콘 위에 겹쳐 그려진다(제품 캡처에서 실제로 그랬다).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "build.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});
    // **그 행의 rect 안에 있는 아이콘만** 본다. y 어림으로 고르면 다른 줄(브랜치·커밋 버튼)의 아이콘이
    // 그 범위에 들어오는 순간 조용히 엉뚱한 것을 재게 된다 — 커밋 줄을 위로 옮기자 실제로 그랬다.
    const row_rect = frame.tree.entries[frame.tree.find(build.NodeIds.item(0)) orelse return error.MissingRow].rect;
    var icon_right: i32 = 0;
    for (draws.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .icon_in_rect => |placed| {
                const y: f32 = @floatFromInt(placed.content_rect.y);
                if (y >= row_rect.y and y < row_rect.y + row_rect.height) {
                    icon_right = placed.content_rect.x + @as(i32, @intCast(placed.content_rect.w));
                }
            },
            else => {},
        },
        else => {},
    };
    try testing.expect(icon_right > 0);
    const name = findExactText(draws, "build.zig") orelse return error.MissingName;
    try testing.expect(name.origin.x >= icon_right);
}

test "그룹 개수는 배지 상자 안에 놓인다(숫자만 떠 있지 않다)" {
    // 배지는 quad 하나 + 그 안의 숫자다. 상자를 그려 놓고 숫자를 행 baseline에 두면 숫자가 어두운
    // pill 위로 떠오른다(Session Dock에서 겪은 회귀) — 그래서 "안에 들어간다"를 좌표로 고정한다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 7, .collapsed = false, .action = .none } },
    };
    const draws = try renderFixture(&storage, .{}, &items);

    const label = findExactText(draws, "7") orelse return error.MissingCount;
    const pill = findBadgeQuad(draws) orelse return error.MissingBadgeQuad;
    const box = pill.rect;

    try testing.expect(label.origin.x >= box.x);
    try testing.expect(label.origin.x <= box.x + @as(i32, @intCast(box.w)));
    try testing.expect(label.origin.y >= box.y);
    try testing.expect(label.origin.y <= box.y + @as(i32, @intCast(box.h)));
    // 반지름은 높이의 절반 — 양끝이 반원인 pill이다. **목록 줄은 각지되 개수 배지는 둥글다**(사용자
    // 결정 2026-08-16): 줄은 표의 행이라 폭을 채워야 하고, 개수는 그 줄에 얹힌 별개의 칩이다.
    try testing.expectEqual(@as(u16, @intCast(box.h / 2)), pill.corner_radii[0]);
    // **채운 칩**이다. 테두리만 있는 상자는 속이 빈 사각형으로 보였다(사용자 지적).
    try testing.expectEqual(tokens.ColorRole.accent_bar, pill.fill_role);
    try testing.expectEqual(@as(?tokens.ColorRole, null), pill.border_role);
    // 숫자는 그 칠 위에서 읽혀야 한다 — 배경색 글자(reverse)다.
    try testing.expectEqual(tokens.ColorRole.surface_bg, label.role);
    // 스크롤 영역 밖으로 새지 않게 clip을 달고 나간다.
    try testing.expect(pill.clip != null);
    // 한 자리 수에서 넓은 pill이 되지 않는다(`.snug`) — 세로보다 아주 넓으면 빈 상자로 보인다.
    try testing.expect(box.w <= box.h * 2);
}

test "긴 제목은 배지 밑으로 파고들지 않는다" {
    // 제목 폭을 배지 왼쪽에서 끊지 않으면 긴 제목이 배지 아래로 들어간다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .staged, .count = 128, .collapsed = false, .action = .none } },
    };
    const draws = try renderFixture(&storage, .{}, &items);

    const left = (findBadgeQuad(draws) orelse return error.MissingBadgeQuad).rect.x;
    const title = findExactText(draws, sectionTitle(.staged)) orelse return error.MissingTitle;
    const budget = title.max_width_px orelse return error.MissingBudget;
    try testing.expect(title.origin.x + @as(i32, @intCast(budget)) <= left);
}

test "탭 줄은 세 탭을 전부 그리고 활성만 강조한다" {
    // P1 계약: 갈 수 없는 탭도 **감추지 않고** 비활성으로 표시한다. 탭 줄이 통째로 없으면 사용자는
    // 이 뷰가 목록 하나뿐인 화면이라고 읽는다.
    var storage: TestStorage = .{};
    const draws = try renderFixture(&storage, .{}, &.{});

    const changes = findText(draws, i18n.t(.scm_changes)) orelse return error.MissingChangesTab;
    const history = findExactText(draws, i18n.t(.scm_history)) orelse return error.MissingHistoryTab;
    const agent = findExactText(draws, i18n.t(.common_role_assistant)) orelse return error.MissingAgentTab;

    // 활성은 색과 **굵기** 둘 다로 구별한다 — 색만으로 구별하지 않는다는 규율(§3.5.2)이 여기도 간다.
    try testing.expectEqual(tokens.ColorRole.surface_fg, changes.role);
    try testing.expect(changes.runs[0].bold);
    try testing.expectEqual(tokens.ColorRole.muted_fg, history.role);
    try testing.expect(!history.runs[0].bold);
    try testing.expectEqual(tokens.ColorRole.muted_fg, agent.role);

    // 왼쪽에서 오른쪽으로 이 순서다.
    try testing.expect(changes.origin.x < history.origin.x);
    try testing.expect(history.origin.x < agent.origin.x);
    // 셋 다 같은 줄이다.
    try testing.expectEqual(changes.origin.y, history.origin.y);
    try testing.expectEqual(history.origin.y, agent.origin.y);
}

test "활성 탭 이름에만 전체 파일 수가 붙는다" {
    // 기대 문자열이 **탭 이름 + 개수** 조합("변경 사항 (42)")이라 언어에 묶인다. 이 테스트가 재는 것은
    // "개수가 활성 탭에만 붙는가"이므로 언어를 고정해 한 벌만 본다.
    const lang_before = i18n.lang();
    defer i18n.setLang(lang_before);
    i18n.setLang(.ko);

    // 개수의 출처는 platform이 준 총계다. **보이는 행을 세지 않는다** — 목록은 가상화되어 있어
    // 스크롤 위치에 따라 숫자가 흔들린다.
    var storage: TestStorage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .branch = "main",
        .changed_file_count = 42,
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});

    try testing.expect(findExactText(draws, "변경 사항 (42)") != null);
    // 나머지 두 탭은 아직 셀 것이 없다(P4·P5) — 개수를 붙이지 않는다.
    try testing.expect(findExactText(draws, i18n.t(.scm_history)) != null);
}

test "탭은 줄을 3등분해 나눠 갖고 개수가 커져도 경계가 그대로다" {
    // 라벨 폭대로 왼쪽에 몰면 이름 길이가 자리를 정해 버려, 개수가 한 자리에서 세 자리로 늘 때 탭 줄이
    // 통째로 흔들린다. 등분이면 밑줄(=칸)이 제자리에 있고 라벨만 칸 안에서 움직인다.
    const width: f32 = 330;
    var small_storage: TestStorage = .{};
    const small = try renderTabs(&small_storage, width, 7);
    var large_storage: TestStorage = .{};
    const large = try renderTabs(&large_storage, width, 128);

    const small_bar = findTabUnderline(small) orelse return error.MissingUnderline;
    const large_bar = findTabUnderline(large) orelse return error.MissingUnderline;

    // 활성 탭은 첫 칸이다 — 밑줄은 줄 왼쪽 끝에서 시작해 정확히 1/3을 덮는다.
    try testing.expectEqual(@as(i32, 0), small_bar.rect.x);
    try testing.expectEqual(@as(u32, @intFromFloat(width / 3)), small_bar.rect.w);
    // 개수가 세 자리가 되어도 칸은 같은 자리·같은 폭이다.
    try testing.expectEqual(small_bar.rect.x, large_bar.rect.x);
    try testing.expectEqual(small_bar.rect.w, large_bar.rect.w);

    // 라벨은 자기 칸 **안**에 있고, 뒤 탭은 각자 칸 안에서 시작한다.
    const slot: i32 = @intFromFloat(width / 3);
    const changes = findText(small, i18n.t(.scm_changes)) orelse return error.MissingChangesTab;
    const history = findExactText(small, i18n.t(.scm_history)) orelse return error.MissingHistoryTab;
    const agent = findExactText(small, i18n.t(.common_role_assistant)) orelse return error.MissingAgentTab;
    try testing.expect(changes.origin.x >= 0 and changes.origin.x < slot);
    try testing.expect(history.origin.x >= slot and history.origin.x < slot * 2);
    try testing.expect(agent.origin.x >= slot * 2);
}

test "그룹 헤더의 일괄 동작 버튼은 개수 배지와 겹치지 않는다" {
    // 배지는 **paint 전용**이라 히트 사각형이 없다. 버튼 rect가 배지 위로 올라오면, 사용자가 "숫자"를
    // 눌렀는데 **그 그룹 전체가 스테이지된다** — 화면이 약속하지 않은 동작이다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 128, .collapsed = false, .action = .stage } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});

    const badge_quad = findBadgeQuad(draws) orelse return error.MissingBadge;
    const action = frame.tree.entries[frame.tree.find(build.NodeIds.itemAction(0)) orelse return error.MissingAction].rect;
    const action_right = action.x + action.width;
    // 버튼은 배지 **왼쪽**에서 끝나야 한다.
    try testing.expect(action_right <= @as(f32, @floatFromInt(badge_quad.rect.x)));
}

test "그룹 제목은 일괄 동작 버튼 밑으로 파고들지 않는다" {
    // 버튼이 배지 **왼쪽**으로 옮겨 앉으면서, 전에 "배지 왼쪽에서 멈추면 됐던" 제목 예산이 그 사이의
    // 버튼을 덮게 된다. 좁은 도크에서 긴 제목이 버튼 위에 그려진다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .staged, .count = 128, .collapsed = false, .action = .unstage } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 220, .height = 400 }, // 좁은 도크
        .items = &items,
        .branch = "main",
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});

    const action = frame.tree.entries[frame.tree.find(build.NodeIds.itemAction(0)) orelse return error.MissingAction].rect;
    const title = findExactText(draws, sectionTitle(.staged)) orelse return error.MissingTitle;
    const budget = title.max_width_px orelse return error.MissingBudget;
    // 제목의 폭 예산이 버튼 **왼쪽 끝**을 넘지 않아야 한다.
    try testing.expect(title.origin.x + @as(i32, @intCast(budget)) <= @as(i32, @intFromFloat(action.x)));
}

test "파일 이름·경로는 증감·상태 문자 자리를 침범하지 않는다" {
    // 이름·경로는 `trailing` 항목들보다 **나중에** 그려지므로, 예산이 행 오른쪽 끝까지 열려 있으면
    // 긴 경로가 증감·상태 문자를 덮는다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{
            .name = "a.zig",
            .dir = "src/" ++ "very-long-directory-segment/" ** 8,
            .status = .modified,
            .letter = 'M',
            .added = 123,
            .removed = 456,
            .has_delta = true,
            .action = .stage,
        } },
    };
    const draws = try renderFixture(&storage, .{}, &items);

    const removed = findExactText(draws, "-456") orelse return error.MissingDelta;
    const dir = findText(draws, "very-long-directory-segment") orelse return error.MissingDir;
    const budget = dir.max_width_px orelse return error.MissingBudget;
    try testing.expect(dir.origin.x + @as(i32, @intCast(budget)) <= removed.origin.x);
}

test "좁은 도크에서 오른쪽 자리가 폭을 다 먹으면 이름을 아예 그리지 않는다" {
    // 예산이 음수가 되면 `colsFor`가 1로 clamp해 **한 글자가 증감 위에 그려질** 수 있다. 그릴 자리가
    // 없으면 아무것도 안 그리는 것이 맞다(잘린 한 글자는 정보가 아니라 잡음이다).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{
            .name = "a.zig",
            .dir = "src/",
            .status = .modified,
            .letter = 'M',
            .added = 999999,
            .removed = 999999,
            .has_delta = true,
            .action = .stage,
        } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 96, .height = 200 }, // 오른쪽 자리만으로 꽉 차는 폭
        .items = &items,
        .branch = "main",
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const draws = try viewBudgeted(&storage, props, frame, .{});
    // 이름이 나오더라도 증감 왼쪽에서 끝나야 한다(안 나오는 것도 정답이다).
    if (findExactText(draws, "a.zig")) |name| {
        const removed = findExactText(draws, "-999999") orelse return error.MissingDelta;
        const budget = name.max_width_px orelse return error.MissingBudget;
        try testing.expect(name.origin.x + @as(i32, @intCast(budget)) <= removed.origin.x);
    }
}

test "호버해도 이름 예산이 늘거나 줄어 글자가 튀지 않는다" {
    // 호버하면 증감이 사라지고 그 자리에 버튼이 앉는다. 두 자리가 다르면 **호버할 때마다 이름이
    // 늘었다 줄었다** 한다 — 포인터를 스치기만 해도 목록이 들썩인다.
    var storage_a: TestStorage = .{};
    var storage_b: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{
            .name = "some-file.zig",
            .dir = "src/deep/nested/",
            .status = .modified,
            .letter = 'M',
            .added = 12,
            .removed = 34,
            .has_delta = true,
            .action = .stage,
        } },
    };
    const plain = try renderFixture(&storage_a, .{}, &items);
    const row_id = build.NodeIds.item(0);
    const hovered = try renderFixture(&storage_b, .{ .hovered = row_id }, &items);

    const a = findExactText(plain, "some-file.zig") orelse return error.MissingName;
    const b = findExactText(hovered, "some-file.zig") orelse return error.MissingName;
    try testing.expectEqual(a.origin.x, b.origin.x);
    // 예산 차이는 **한 글자 폭 이내**여야 한다(증감 폭과 버튼 폭이 정확히 같을 수는 없다).
    const wa: i64 = @intCast(a.max_width_px orelse 0);
    const wb: i64 = @intCast(b.max_width_px orelse 0);
    try testing.expect(@abs(wa - wb) <= 16);
}

test "그룹 제목도 호버로 예산이 튀지 않는다" {
    // 파일 행과 같은 함정이 헤더에도 있다: 버튼은 호버해야 보이지만 **자리는 늘 잡혀 있다**.
    // 제목 예산이 호버를 따라가면 헤더 글자도 들썩인다.
    var a: TestStorage = .{};
    var b: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .staged, .count = 7, .collapsed = false, .action = .unstage } },
    };
    const plain = try renderFixture(&a, .{}, &items);
    const hovered = try renderFixture(&b, .{ .hovered = build.NodeIds.item(0) }, &items);
    const x = findExactText(plain, sectionTitle(.staged)) orelse return error.MissingTitle;
    const y = findExactText(hovered, sectionTitle(.staged)) orelse return error.MissingTitle;
    try testing.expectEqual(x.origin.x, y.origin.x);
    try testing.expectEqual(x.max_width_px, y.max_width_px);
}

test "동작이 없는 행은 그 자리를 비워 두지 않는다(충돌 행은 이름이 더 길다)" {
    // 충돌 행은 동작이 없다(`git add`가 "해결됨"으로 표시하므로). 그런데도 버튼 자리를 비우면
    // **누를 수 없는 것 때문에 이름이 짧아진다** — 화면이 거짓말을 하는 자리다.
    var a: TestStorage = .{};
    var b: TestStorage = .{};
    const with_action = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "src/", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const no_action = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "src/", .status = .conflicted, .letter = 'U', .action = .none } },
    };
    const acted = try renderFixture(&a, .{}, &with_action);
    const plain = try renderFixture(&b, .{}, &no_action);
    const wa = (findExactText(acted, "a.zig") orelse return error.MissingName).max_width_px orelse 0;
    const wb = (findExactText(plain, "a.zig") orelse return error.MissingName).max_width_px orelse 0;
    try testing.expect(wb > wa);
}

test "빈 커밋 상자는 안내 문구를, 버튼은 index 상태로만 켠다 (②b)" {
    // 빈 채로 두면 그 자리가 입력란이라는 사실이 화면에 없다. 커밋 버튼의 활성은 **실제 index 상태**로만
    // 정한다(§7 — 스테이지 여부를 추정하면 커밋할 것이 없는데 켜진다).
    var off_storage: TestStorage = .{};
    off_storage.commit_items = .{
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = false } },
    };
    const off_props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .items = &off_storage.commit_items,
    };
    const off_frame = try build.build(off_props, .{
        .nodes = &off_storage.nodes,
        .entries = &off_storage.entries,
        .layout_items = &off_storage.layout_items,
        .flex_scratch = &off_storage.flex_scratch,
        .child_rects = &off_storage.child_rects,
        .actions = &off_storage.actions,
    });
    const off = try viewBudgeted(&off_storage, off_props, off_frame, .{});
    const hint = findExactText(off, commitPlaceholder()) orelse return error.MissingPlaceholder;
    try testing.expectEqual(tokens.ColorRole.muted_fg, hint.role);
    const off_label = findExactText(off, commitLabel()) orelse return error.MissingButton;
    try testing.expectEqual(tokens.ColorRole.muted_fg, off_label.role); // 꺼짐 — 채우지 않는다

    var on_storage: TestStorage = .{};
    on_storage.commit_items = .{
        .{ .commit_box = .{ .repo_index = 0, .text = "fix: 무언가를 고친다" } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = true } },
    };
    const on_props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .items = &on_storage.commit_items,
    };
    const on_frame = try build.build(on_props, .{
        .nodes = &on_storage.nodes,
        .entries = &on_storage.entries,
        .layout_items = &on_storage.layout_items,
        .flex_scratch = &on_storage.flex_scratch,
        .child_rects = &on_storage.child_rects,
        .actions = &on_storage.actions,
    });
    const on = try viewBudgeted(&on_storage, on_props, on_frame, .{});
    try testing.expect(findExactText(on, commitPlaceholder()) == null); // 글자가 있으면 안내는 없다
    const msg = findExactText(on, "fix: 무언가를 고친다") orelse return error.MissingMessage;
    try testing.expectEqual(tokens.ColorRole.surface_fg, msg.role);
    const on_label = findExactText(on, commitLabel()) orelse return error.MissingButton;
    try testing.expectEqual(tokens.ColorRole.surface_bg, on_label.role); // 켜지면 채운 면 위 reverse
}

/// 커밋 줄 fixture. **상자는 목록 항목이다**(②b) — 그 그룹 안에 살기 때문이다.
fn renderCommit(storage: *TestStorage, message: []const u8, edit: types.CommitEdit, rows: u32) !draw.ChromeDraw {
    storage.commit_items = .{
        .{ .commit_box = .{ .repo_index = 0, .rows = rows, .text = message, .edit = edit } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = false } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .items = &storage.commit_items,
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    return viewBudgeted(storage, props, frame, .{});
}

fn countQuads(draws: draw.ChromeDraw, role: tokens.ColorRole) usize {
    var n: usize = 0;
    for (draws.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == role) {
            n += 1;
        },
        else => {},
    };
    return n;
}

fn firstQuad(draws: draw.ChromeDraw, role: tokens.ColorRole) ?draw.Op.Quad {
    for (draws.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == role) return quad,
        else => {},
    };
    return null;
}

test "여러 줄 메시지는 줄마다 한 조각으로 나온다(한 덩어리로 그리면 개행이 사라진다)" {
    // 한 op에 통째로 실으면 backend는 개행을 모르는 채 한 줄로 그린다 — 사용자가 Enter를 눌렀는데
    // 화면이 안 바뀐다.
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "제목 줄\n\n본문 줄", .{}, 3);
    try testing.expect(findExactText(draws, "제목 줄") != null);
    try testing.expect(findExactText(draws, "본문 줄") != null);
    // 빈 줄은 그릴 글자가 없다 — 그래도 **자리는 차지한다**(그래서 본문이 셋째 줄에 온다).
    const title = findExactText(draws, "제목 줄") orelse return error.MissingTitle;
    const body = findExactText(draws, "본문 줄") orelse return error.MissingBody;
    const line_h = typography.lineHeightPx(.control, 1000);
    try testing.expectEqual(@as(i32, @intCast(line_h * 2)), body.origin.y - title.origin.y);
}

test "caret은 포커스가 있을 때만 선다" {
    // 안 깜빡이는 caret은 "여기 쓰면 된다"가 아니라 "여기 뭔가 잘못됐다"로 읽힌다.
    var idle_storage: TestStorage = .{};
    const idle = try renderCommit(&idle_storage, "fix", .{ .caret = 3 }, 1);
    try testing.expectEqual(@as(usize, 0), countQuads(idle, .cursor));

    var focus_storage: TestStorage = .{};
    const focused = try renderCommit(&focus_storage, "fix", .{ .focused = true, .caret = 3 }, 1);
    const caret = firstQuad(focused, .cursor) orelse return error.MissingCaret;
    // 글자 셋 뒤에 선다 — 셀 폭 단위로(등폭 chrome 폰트, §12.3 ①).
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(i32, @intCast(m.inset_x + 3 * 8)), caret.rect.x); // 셀 폭 8은 props 기본값
}

test "caret은 줄을 따라 내려간다(둘째 줄 caret이 첫 줄에 서지 않는다)" {
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "ab\ncd", .{ .focused = true, .caret = 4 }, 2);
    const caret = firstQuad(draws, .cursor) orelse return error.MissingCaret;
    const line_h = typography.lineHeightPx(.control, 1000);
    const title = findExactText(draws, "ab") orelse return error.MissingFirst;
    try testing.expectEqual(@as(i32, @intCast(title.origin.y + @as(i32, @intCast(line_h)))), caret.rect.y);
    // 열은 그 **줄 안에서** 센다 — 문서 전체 오프셋으로 세면 둘째 줄 caret이 오른쪽으로 밀린다.
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(i32, @intCast(m.inset_x + 1 * 8)), caret.rect.x);
}

test "선택은 줄마다 잘려 밴드가 된다(줄을 넘어 한 덩어리로 칠하지 않는다)" {
    // 통째로 넘기면 `fieldLayout`이 한 줄 전제로 열을 재서 둘째 줄부터 밴드가 엉뚱한 자리에 선다.
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "ab\ncd", .{
        .focused = true,
        .caret = 4,
        .selection = .{ .anchor = 1, .focus = 4 },
    }, 2);
    try testing.expectEqual(@as(usize, 2), countQuads(draws, .selection));
}

test "포커스가 없으면 선택 밴드도 없다(꺼진 상자가 무언가 골라 둔 것처럼 보이지 않게)" {
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "ab\ncd", .{ .selection = .{ .anchor = 0, .focus = 5 } }, 2);
    try testing.expectEqual(@as(usize, 0), countQuads(draws, .selection));
}

test "상자가 보여 줄 수 있는 것보다 메시지가 길면 first_row부터 그린다" {
    // 스크롤이 없으면 긴 메시지의 끝에서 타이핑할 때 caret이 상자 밖에 선다.
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "one\ntwo\nthree", .{ .focused = true, .caret = 12, .first_row = 1 }, 2);
    try testing.expect(findExactText(draws, "one") == null); // 위로 밀려 나갔다
    try testing.expect(findExactText(draws, "two") != null);
    try testing.expect(findExactText(draws, "three") != null);
}

test "빈 메시지에도 포커스면 caret이 선다" {
    // 안내 문구만 있고 caret이 없으면 "여기 못 쓴다"로 읽힌다.
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "", .{ .focused = true }, 1);
    try testing.expect(findExactText(draws, commitPlaceholder()) != null);
    try testing.expect(firstQuad(draws, .cursor) != null);
}

test "마지막 줄이 상자 안에 있다(상자 높이와 줄 간격의 출처가 하나다)" {
    // 상자 높이는 `commitBoxHeight`(행 높이 × 행 수)이고 줄은 `.control` 줄 높이 간격으로 놓인다.
    // 둘이 다른 상수에서 나오면 줄이 늘수록 어긋나 — 크면 마지막 줄이 잘리고, 작으면 아래에 빈 띠가
    // 남으며 클릭 → 행 변환도 그만큼 밀린다. 실제로 20 vs 17로 갈려 있었다(적대적 검증 2026-08-16).
    var storage: TestStorage = .{};
    const draws = try renderCommit(&storage, "one\ntwo\nthree", .{ .focused = true, .caret = 13 }, 3);
    const last = findExactText(draws, "three") orelse return error.MissingLastLine;
    const line_h: i32 = @intCast(typography.lineHeightPx(.control, 1000));
    const m = types.DockMetrics.resolve(1000);
    // 상자 줄의 rect는 목록 항목 0이다(fixture가 상자·버튼 순으로 넣는다).
    const box = storage.entries[boxEntryIndex(&storage)].rect;
    const bottom: i32 = @intFromEnum(@as(enum(i32) { _ }, @enumFromInt(@as(i32, @intFromFloat(box.y + box.height)))));
    try testing.expect(last.origin.y + line_h <= bottom);
    try testing.expect(bottom - (last.origin.y + line_h) <= @as(i32, @intCast(m.commit_pad_y)));
    const caret = firstQuad(draws, .cursor) orelse return error.MissingCaret;
    try testing.expectEqual(last.origin.y, caret.rect.y);
}

/// fixture가 넣은 커밋 상자 행의 entry 자리.
fn boxEntryIndex(storage: *TestStorage) usize {
    for (storage.entries, 0..) |entry, index| {
        if (entry.id == build.NodeIds.item(0)) return index;
    }
    return 0;
}

test "호버해도 커밋 버튼 글자가 면에 묻히지 않는다" {
    // 호버는 카드 배경을 `row_hover_bg`(어두움)로 **덮어쓴다**(상태 해석이 명시 paint보다 위다).
    // 글자를 `enabled`만 보고 고르면 그때 어두운 글자가 어두운 면에 놓여 라벨이 사라진다.
    var storage: TestStorage = .{};
    storage.commit_items = .{
        .{ .commit_button = .{ .repo_index = 0, .enabled = true } },
        .{ .commit_box = .{ .repo_index = 0 } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .items = &storage.commit_items,
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const idle = try viewBudgeted(&storage, props, frame, .{});
    const on = findExactText(idle, commitLabel()) orelse return error.MissingButton;
    try testing.expectEqual(tokens.ColorRole.surface_bg, on.role); // 채운 면 위 = reverse

    var hover_storage: TestStorage = .{};
    hover_storage.commit_items = storage.commit_items;
    const hover_props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 500 },
        .branch = "main",
        .items = &hover_storage.commit_items,
    };
    const hover_frame = try build.build(hover_props, .{
        .nodes = &hover_storage.nodes,
        .entries = &hover_storage.entries,
        .layout_items = &hover_storage.layout_items,
        .flex_scratch = &hover_storage.flex_scratch,
        .child_rects = &hover_storage.child_rects,
        .actions = &hover_storage.actions,
    });
    // 호버가 걸리는 것은 **면 노드**다(칠·action이 거기 있다 — 아래 여백은 줄의 것이라 칠하지 않는다).
    const face_id = build.NodeIds.itemFace(0);
    const hovered = try viewBudgeted(&hover_storage, hover_props, hover_frame, .{ .hovered = face_id });
    const label = findExactText(hovered, commitLabel()) orelse return error.MissingButton;
    const button = hover_frame.tree.entries[hover_frame.tree.find(face_id) orelse return error.MissingButton];
    const tk = testTokens();
    const resolved = paint_style.resolveCard(button.id, button.visual.card, button.action, .{ .hovered = face_id }, &tk);
    try testing.expect(resolved.background != .accent_bar); // 호버가 채움을 덮는다(전제 확인)
    try testing.expectEqual(tokens.ColorRole.surface_fg, label.role);
    try testing.expect(label.role != resolved.background); // 글자와 면이 같은 역할이면 그게 사라지는 것이다
}

test "caret은 깜빡임 위상을 따른다(위상이 꺼진 반주기에는 안 그린다)" {
    // 위상은 host가 소유한다. component가 늘 그리면 상자 caret만 안 깜빡이고(도크 검색 caret이 정확히
    // 그랬다), 반대로 위상을 안 받으면 테스트·Lab에서 caret이 사라진다 — 기본이 `true`인 이유다.
    var on_storage: TestStorage = .{};
    const on = try renderCommit(&on_storage, "fix", .{ .focused = true, .caret = 3 }, 1);
    try testing.expect(firstQuad(on, .cursor) != null);

    var off_storage: TestStorage = .{};
    const off = try renderCommit(&off_storage, "fix", .{ .focused = true, .caret = 3, .caret_visible = false }, 1);
    try testing.expect(firstQuad(off, .cursor) == null);
    // 글자는 그대로다 — 깜빡이는 것은 caret뿐이다.
    try testing.expect(findExactText(off, "fix") != null);
}

test "저장소 머리 줄: 이름·브랜치·개수가 함께 서고 워크트리는 다른 아이콘이다" {
    // 같은 이름의 두 줄(주 저장소와 그 워크트리)을 사용자가 구별해야 하므로 종류가 글리프로 보여야 한다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main", .primary = true, .count = 3 } },
        .{ .repo = .{ .index = 1, .name = "wt-review", .branch = "review", .primary = false, .count = 1 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findExactText(draws, "maru3") != null);
    try testing.expect(findExactText(draws, "main") != null);
    try testing.expect(findExactText(draws, "wt-review") != null);
    // 종류 아이콘이 서로 다르다.
    var saw_repo = false;
    var saw_worktree = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, repo_icon)) saw_repo = true;
            if (std.mem.eql(u8, run.text, worktree_icon)) saw_worktree = true;
        },
        else => {},
    };
    try testing.expect(saw_repo and saw_worktree);
}

test "머리 줄: 접힘 화살표와 종류 아이콘이 붙지 않는다 (사용자 지적 2026-08-19)" {
    // 그전에는 화살표 칸이 끝나는 자리에 아이콘이 **간격 0**으로 붙어 둘이 한 덩어리로 보였다.
    // 이름 앞에만 간격이 있었고, 그래서 왼쪽 두 글리프만 유독 빽빽했다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main", .primary = true, .count = 3 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const m = types.DockMetrics.resolve(1000);

    const chevron = findExactText(draws, chevron_down_icon) orelse return error.MissingChevron;
    const folder = findExactText(draws, repo_icon) orelse return error.MissingFolder;
    // 화살표는 왼쪽 여백에, 아이콘은 **아이콘 열**에 선다 — 그 사이가 한 칸이다.
    try testing.expect(folder.origin.x - chevron.origin.x >= @as(i32, @intCast(m.disclosure_extent + m.gap)));
    try testing.expectEqual(@as(i32, @intCast(m.iconColumnX())), folder.origin.x);
}

test "머리 줄 아이콘과 파일 행 아이콘은 **같은 열**에 선다" {
    // 값이 흩어져 있으면 한 줄만 고쳤을 때 열이 어긋난다 — 그래서 `iconColumnX()` 하나에서 온다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main", .primary = true, .count = 1 } },
        .{ .file = .{ .model_index = 0, .name = "build.zig", .dir = "", .letter = 'M', .status = .modified, .action = .none } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const folder = findExactText(draws, repo_icon) orelse return error.MissingFolder;
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(i32, @intCast(m.iconColumnX())), folder.origin.x);
    // 파일 아이콘은 분류기가 고른 글리프라 이름으로 찾지 않고 **자리만** 본다: 같은 열에, 머리 줄보다 아래.
    var saw_file_icon_in_column = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| {
            if (text.origin.x == @as(i32, @intCast(m.iconColumnX())) and text.origin.y > folder.origin.y) {
                saw_file_icon_in_column = true;
            }
        },
        else => {},
    };
    try testing.expect(saw_file_icon_in_column);
}

test "머리 줄: 브랜치와 개수 배지 사이는 `gap` 하나보다 넓다 (사용자 지적 2026-08-19)" {
    // 배지는 칠해진 알약이라 같은 간격이면 시각 무게 때문에 이름에 달라붙어 보인다("11이 겹쳐 보인다").
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "feat/x", .primary = true, .count = 11 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const m = types.DockMetrics.resolve(1000);
    const pill = findBadgeQuad(draws) orelse return error.MissingBadge;
    const branch = findExactText(draws, "feat/x") orelse return error.MissingBranch;
    // 브랜치는 **오른쪽 정렬**이라 그 op의 자리 자체가 "배지 왼쪽에서 이만큼 떨어진 곳"이다.
    // 글자 폭을 여기서 다시 재면(측정기가 없다) 출처가 둘이 되므로, 방출된 폭 예산으로 끝을 구한다.
    const branch_right = branch.origin.x + @as(i32, @intCast(branch.max_width_px orelse 0));
    try testing.expect(pill.rect.x - branch_right >= @as(i32, @intCast(m.badgeGapPx())));
}

test "머리 줄: 동작 아이콘은 자리를 비워 두지 않고 호버할 때 **덮어** 그린다 (사용자 지적 2026-08-19)" {
    // 늘 비워 두면 아이콘이 호버해야 나오므로 평소 화면에는 이유를 말하지 않는 빈 띠만 남는다.
    // 덮개 없이 그리면 배지·브랜치 글자 위에 아이콘이 겹친다(예약을 넣기 전 그 화면이었다).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main", .primary = true, .count = 11, .can_stage_all = true } },
    };
    // ① 호버가 없으면 덮개도 없다 — 평소 화면에 덧칠이 늘지 않는다.
    const plain = try renderFixture(&storage, .{}, &items);
    const badge_plain = findBadgeQuad(plain) orelse return error.MissingBadge;

    // ② 호버하면 그 아이콘 자리를 덮는 사각형이 **배지보다 뒤에** 온다(그려지는 순서 = 덮는 순서).
    var storage_hover: TestStorage = .{};
    const hover = try renderFixture(&storage_hover, .{ .hovered = build.NodeIds.item(0) }, &items);
    var badge_index: ?usize = null;
    var cover_index: ?usize = null;
    for (hover.ops, 0..) |op, i| switch (op) {
        .quad => |quad| {
            if (quad.fill_role == .accent_bar and quad.rect.h >= badge_min_height) badge_index = i;
            // 덮개는 배지가 아니라 **행 배경 색**이고, 배지보다 넓다(아이콘 둘을 담는다).
            if (quad.fill_role != .accent_bar and quad.rect.w > badge_plain.rect.w) cover_index = i;
        },
        else => {},
    };
    const cover = cover_index orelse return error.MissingCover;
    const badge_at = badge_index orelse return error.MissingBadge;
    try testing.expect(cover > badge_at);
}

test "접힌 저장소도 개수 배지를 그린다(접힌 채로 '여기 뭔가 있다'를 안다)" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "main", .collapsed = true, .count = 7 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findBadgeQuad(draws) != null);
    try testing.expect(findExactText(draws, "7") != null);
    // 접힘 표시는 오른쪽 화살표다(펴짐은 아래 화살표).
    var saw_right = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, chevron_right_icon)) saw_right = true;
        },
        else => {},
    };
    try testing.expect(saw_right);
}

test "변경이 없는 저장소는 배지를 안 그린다(0은 숫자가 아니라 없음이다)" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "clean", .branch = "main", .count = 0 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findBadgeQuad(draws) == null);
    try testing.expect(findExactText(draws, "clean") != null);
}

test "이름이 길면 이름이 먼저 잘린다(어느 저장소인지가 어느 브랜치인지보다 앞선다)" {
    // 반대로 브랜치를 먼저 자르면 긴 이름 하나가 줄을 다 먹어 브랜치가 사라진다 — 그때 사용자는
    // 두 워크트리를 구별할 수 없다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .branch = "feature/x", .count = 0 } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const branch = findExactText(draws, "feature/x") orelse return error.MissingBranch;
    const name = findExactText(draws, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") orelse return error.MissingName;
    // 이름 예산은 브랜치 왼쪽에서 끝난다.
    try testing.expect(name.origin.x + @as(i32, @intCast(name.max_width_px.?)) <= branch.origin.x);
}
