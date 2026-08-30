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
/// 원격 갱신(fetch). ⟳를 안 쓰는 이유는 그것이 같은 패널에서 **로컬 다시 읽기**를 뜻하기 때문이다.
const fetch_icon = icons.utf8Fit(.cloud_download, .standard);
/// 그 갱신이 **도는 중**. 글자 라벨을 뗐으므로 이 상태를 말할 것이 색밖에 없는데, 꺼진 칩도 같은 회색이라
/// "돌고 있다"와 "원격이 없다"가 한 그림이 된다 — 눌렀는데 표시가 없으면 사용자는 다시 누른다(그 두 번째
/// 누름은 조용히 거부된다). 그래서 **글리프를 바꾼다**.
const fetching_icon = icons.utf8Fit(.hourglass, .standard);
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
    // 원격 갱신 칩 — 이제 **글자가 아니라 아이콘**이다(2026-08-20). 상태에 따라 글리프가 갈리므로
    // 둘 중 긴 쪽으로 잡는다. 모자라면 op이 하나 빠지는 게 아니라 도크가 통째로 빈다.
    bytes += @max(fetch_icon.len, fetching_icon.len);

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
            // 위 구분선 + 선택 막대 + ref 칩의 면 — 셋. **줄마다 잡는다**: 어느 줄이 고른 줄인지·칩을
            // 갖는지는 이 예산 함수가 다시 판정할 일이 아니고, 모자라면 그 프레임이 통째로 버려진다.
            quad_extra += 3;
            bytes += commit.subject.len + commit.author.len + commit.when.len + commit.short_oid.len + commit.ref.len;
            bytes += 8; // `+N` 접힘 표시(§3.5.3) — 자릿수가 늘어도 담기게 넉넉히 잡는다
        },
        // 제목·에이전트·시각 — 셋.
        .turn => |turn| {
            text_ops += 3;
            quad_extra += 2; // 위 구분선 + 선택 막대(커밋 줄과 같은 규율)
            bytes += turn.title.len + turn.agent.len + turn.when.len;
        },
        // 아이콘·이름·경로·상태 문자·증감 둘(`-N`·`+N`) — 여섯. 소행 표시(`✎`·`·`)는 그 자리를 상태
        // 문자와 나눠 쓰지 않으므로 따로 센다.
        .commit_file => |file| {
            text_ops += 7;
            quad_extra += 2; // 세로 안내선 + 선택 막대
            bytes += icon_bytes + file.name.len + file.dir.len + 2;
            // `-N`·`+N`(부호 포함 `count_digits + 1` 씩)·`bin`·소행 표시. **u32 최대 자릿수로 잡는다** —
            // 24 로 두면 `-4294967295 +4294967295` 조합에서 한 바이트가 모자라고, 그때는 그 조각이
            // 빠지는 게 아니라 **프레임이 통째로 버려진다**(이 함수 위 주석의 두 사고가 그것이었다).
            bytes += (count_digits + 1) * 2 + 3 + icon_bytes;
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
    // 스크롤바 fade 는 **여기서** 얹는다 — tree(`frame`)는 alpha 를 모른 채 불변으로 남는다(계약 §7 ·
    // 세션 도크와 같은 축).
    const scrollbar_alpha = [_]ui_paint.IdAlpha{
        .{ .id = build.NodeIds.scroll_track, .alpha = props.scrollbar_alpha },
        .{ .id = build.NodeIds.scroll_thumb, .alpha = props.scrollbar_alpha },
    };
    const painted = try ui_paint.paintWithAlphaOverrides(frame.tree, state, tk, .sidebar, .{ .ops = buffers.ops }, &scrollbar_alpha);
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
        try writer.line(rect, gap + writer.measureRun(added, .supporting), removed, .git_deleted_fg, .supporting, false);
    }

    // ── 목록. 스크롤 영역 안이므로 backend가 "스크롤은 순수 평행이동"임을 쓸 수 있게 표시한다.
    const content_index = frame.tree.find(build.NodeIds.content) orelse return error.MissingRect;
    writer.container_clip = clipRectOf(frame.tree.entries[content_index]);
    writer.scroll_clipped = true;
    for (props.items, 0..) |item, index| {
        const row_index = frame.tree.find(build.NodeIds.item(index)) orelse continue;
        const row = frame.tree.entries[row_index];
        writer.active_clip = clipRectOf(row);
        // 동작 아이콘이 떠 있으면(호버) 그 띠의 왼쪽 경계. **한 번만 푼다** — 글자를 접는 쪽과 아이콘을
        // 그리는 쪽이 같은 값을 봐야 하고(두 벌이면 한쪽만 호버를 놓쳐 다시 겹친다), tree 탐색도 한 번이면 된다.
        const repo_actions_left: ?f32 = if (item == .repo) repoActionsLeftX(frame, state, index, m) else null;
        switch (item) {
            .repo => |repo| try writer.repoRow(row, repo, m, repo_actions_left),
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
        // 겹침은 여기서 덮어서가 아니라 **`repoRow`가 그 자리의 글자를 안 그려서** 안 난다(그 함수 설명).
        if (item == .repo) {
            const repo = item.repo;
            if (repo_actions_left != null) {
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
            // **오른쪽 묶음을 먼저 그리고, 이름은 그 앞에서 끊는다.**
            //
            // 그 전에는 이름을 `line` 으로 rect **끝까지** 썼는데, 그 rect 는 `↑↓`·fetch 칩·`∨` 를 전부
            // 품고 있어서 **긴 이름이 그 위로 올라탔다**(제품 캡처 2026-08-25: `feat/w8-sidebar-scroll`
            // 위에 `↑` 가 겹쳐 둘 다 못 읽었다). 파일 행이 같은 실패를 먼저 겪었고 거기서 세운 규칙이
            // 이것이다 — **자기 자리만큼만 쓰고 자른다.**
            //
            // **순서를 뒤집는 이유**: `↑↓` 는 오른쪽 정렬이라 폭을 재 봐야 왼쪽 끝을 안다. 이름을 먼저
            // 그리면 그 자리를 알 수가 없다. 그리는 순서는 겹치지 않는 한 화면에 영향이 없다.
            var branch_end: f32 = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x));
            // **아직 보내지 않은 것이 있으면 점**(§3.5). 개수는 안 적는다 — 위 `↑`/`↓`는 **기본 브랜치**
            // 기준이라, 기준이 다른 숫자를 그 옆에 놓으면 어느 쪽이 무엇인지 읽을 수 없다.
            if (props.unpushed) {
                const name_w = writer.measureRun(props.branch, .control); // 위 `line` 이 쓰는 role
                const dot_x = branch_x + name_w + @as(f32, @floatFromInt(m.gap));
                const dot_w = writer.measureRun(unpushed_dot, .supporting);
                // 오른쪽 묶음(↑↓·칩)을 침범하지 않을 때만 그린다 — 겹치면 둘 다 못 읽는다.
                if (dot_x + dot_w < branch_end) {
                    try writer.line(rect, dot_x, unpushed_dot, .accent_bar, .supporting, false);
                }
            }
            // ── 원격 갱신 칩(P6). **글자는 tree가 준 rect 안에 놓는다** — 여기서 자기 산수로 자리를
            // 잡으면 "그린 자리와 눌리는 자리"의 주인이 둘이 된다(탭 칸에서 이미 겪은 갈림).
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
                branch_end = @min(branch_end, menu_rect.rect.x);
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
                // **글자가 아니라 아이콘이다**(사용자 결정 2026-08-20). `가져오기` 넉 자가 브랜치 줄
                // 오른쪽을 계속 차지했고, 도는 중에는 `가져오는 중…`으로 더 넓어져 옆의 `↑`/`↓`를 밀었다.
                // 글리프는 `reset`(⟳)이 아니라 **구름↓**이다: ⟳는 같은 패널에서 이미 "로컬 다시 읽기"
                // (머리 줄 새로고침)를 뜻하고, `↓` 화살표는 바로 옆 `↓ N`(behind 개수)과 겹친다.
                const glyph_x = (chip.rect.width - @as(f32, @floatFromInt(m.icon_extent))) / 2;
                const glyph = if (props.fetch.running) fetching_icon else fetch_icon;
                try writer.icon(chip, @max(glyph_x, 0), glyph, m.icon_extent, role);
                // ahead/behind는 그 **묶음 전체**(칩 + `∨`)를 비켜 앉는다. 칩 폭만 빼면 `∨` 위에 겹친다.
                const group_left = chip.rect.x;
                branch_end = @min(branch_end, group_left);
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
                const ahead_right = fetch_right + behind_w + m.gap;
                const ahead_w = try writer.trailingWidth(
                    rect,
                    ahead_text,
                    if (props.ahead > 0) .git_added_fg else .muted_fg,
                    .supporting,
                    ahead_right,
                );
                // **`↑↓` 도 오른쪽 묶음이다.** 이것을 빼먹어 이름 위에 `↑` 가 겹쳤다(제품 캡처).
                branch_end = @min(branch_end, rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(ahead_right)) - @as(f32, @floatFromInt(ahead_w)));
            }
            // ── 이름은 **맨 나중에**, 묶음이 정한 경계 안에서 ──────────────────────────────
            try writer.lineWithin(rect, branch_x, branch_end - @as(f32, @floatFromInt(m.gap)), props.branch, .surface_fg, .control, true);
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

/// 머리 줄의 동작 아이콘이 **지금 떠 있으면** 그 아이콘 띠의 왼쪽 경계, 아니면 null이다.
///
/// 아이콘을 그리는 쪽과 그 자리의 글자(브랜치·배지·상태 라벨)를 접는 쪽이 **같은 판정**을 봐야 한다 —
/// 두 벌로 두면 한쪽만 호버를 놓쳐 다시 겹친다. 포인터가 자식 버튼 위에 있으면 행 자체의 hover는
/// 풀리므로 `hoveredRepoAction`도 함께 본다(안 그러면 아이콘이 깜빡인다).
fn repoActionsLeftX(
    frame: build.Frame,
    state: interaction.InteractionState,
    index: usize,
    m: types.DockMetrics,
) ?f32 {
    const row_index = frame.tree.find(build.NodeIds.item(index)) orelse return null;
    if (!isHovered(state, frame.tree.entries[row_index].id) and !hoveredRepoAction(state, index)) return null;
    const first_index = frame.tree.find(build.NodeIds.repoAction(index, 0)) orelse return null;
    return frame.tree.entries[first_index].rect.x - @as(f32, @floatFromInt(m.gap));
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

/// published `effective_clip`을 정수 rect로 옮긴다. **`entry.rect`가 아니다** — 스크롤로 밀린 행의
/// rect는 목록 뷰포트 **밖까지** 이어지므로(가상화가 창의 첫 항목을 음수 origin으로 올려 둔다),
/// 그것을 clip으로 실으면 그 행의 quad·글자가 위쪽 고정 chrome(탭 줄·요약 줄) 위에 그려진다
/// (사용자 지적 2026-08-21: 목록을 스크롤하면 탭 줄·요약 줄과 겹쳤다). 부모 clip까지 접힌 값은
/// tree가 소유하므로 그 값을 그대로 전달만 한다 — session_dock의 같은 이름 함수와 같은 계약이다.
fn clipRectOf(entry: tree.RectEntry) ?draw.Rect {
    const clip = entry.effective_clip orelse return null;
    return .{
        .x = @intFromFloat(@floor(clip.x)),
        .y = @intFromFloat(@floor(clip.y)),
        .w = @intFromFloat(@max(@floor(clip.width), 0)),
        .h = @intFromFloat(@max(@floor(clip.height), 0)),
    };
}

/// 상태 문자의 색. **모양(글자)과 함께** 쓰는 보조 신호라 색만으로 구분하지 않는다(§3.5.2).
/// 배지 글리프. **글자가 아니라 기호인 이유**: 파일 행은 이름이 주인이라 낱말이 들어갈 폭이 없다.
/// 뜻은 계약 §4.2 가 정하고(`✎ AI 편집`·`· 턴 중 변경`) 여기서는 그 첫 글자만 쓴다.
fn originMark(origin: types.TurnFileOrigin) ?[]const u8 {
    return switch (origin) {
        // 근거가 없으면 **아무것도 그리지 않는다** — 「모른다」를 기호로 지어내면 「셸이 고쳤다」와 섞인다.
        .unknown => null,
        .ai_edit => "✎",
        .turn_change => "·",
    };
}

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

        // 개수는 `변경 사항` 탭 이름 옆에만 붙는다 — 나머지 둘은 셀 것이 다르다(커밋·턴은 목록이 스스로
        // 길이를 말한다). **활성 탭인지와는 무관하다**: 이 수는 작업트리 사실이라 히스토리를 보는 동안에도
        // 참이고, 활성일 때만 채우면 다른 탭에서 `(0)`이 되어 화면이 "바뀐 것이 없다"고 거짓말한다.
        var buf: [48]u8 = undefined;
        const label: []const u8 = if (tab == .changes)
            std.fmt.bufPrint(&buf, "{s} ({d})", .{ tabTitle(tab), self.props.changed_file_count }) catch tabTitle(tab)
        else
            tabTitle(tab);

        const label_w = self.measureBudget(label, .control); // 아래 `emit` 이 쓰는 role
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
    /// `actions_left_x`는 **호버해서 동작 아이콘이 떠 있을 때** 그 아이콘 띠의 왼쪽 경계다(아니면 null).
    ///
    /// **동작 아이콘 자리를 평소에는 비워 두지 않는다**(사용자 지적 2026-08-19). 늘 비켜 두면 아이콘은
    /// 호버해야 나타나므로 평소 화면에는 **이유를 말하지 않는 빈 띠**만 52px 남는다.
    ///
    /// 그렇다고 호버할 때 브랜치·배지를 왼쪽으로 밀면 그것들이 마우스를 따라 움직인다(2026-08-17에
    /// 그래서 예약을 넣었다). 그래서 **호버하는 동안 그 둘을 아예 안 그린다** — 자리는 그대로고 겹치지도
    /// 않는다. 옛 답("행 배경과 같은 색 사각형을 깔고 그 위에 아이콘을 놓는다")은 **원리적으로 통하지
    /// 않았다**: chrome quad는 chrome 글자보다 **먼저** 그리는 층이라(`chrome_draw_lowering`의 layer
    /// 규약), 나중에 깐 사각형이 이미 그린 글자를 덮지 못한다. 그래서 새로고침 아이콘이 브랜치 이름
    /// 위에 겹쳐 보였다(사용자 지적 2026-08-21). 히트 사각형은 build가 늘 두므로 클릭 판정은 그대로다.
    fn repoRow(self: *Writer, rect: tree.RectEntry, repo: types.RepoItem, m: types.DockMetrics, actions_left_x: ?f32) ViewError!void {
        const scale = effectiveScale(self.props.scale_milli);
        const inset: f32 = @floatFromInt(m.inset_x);
        const right_inset: u32 = m.inset_x;
        // 아이콘이 떠 있는 동안 오른쪽 것들이 설 수 있는 한계. 아이콘 띠 왼쪽에서 멈춘다.
        const right_limit: f32 = actions_left_x orelse
            (rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(right_inset)));
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
        // 호버 중에는 배지를 안 그린다 — 아이콘 띠가 정확히 그 자리를 쓴다.
        const pill = if (repo.count > 0 and !repo.pending and !repo.failed and actions_left_x == null) badge.countPill(rect.rect, .{
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
            // main의 i18n 라벨 함수와 ②c의 오른쪽 여백(아이콘 자리)을 **둘 다** 쓴다. 브랜치와 같은
            // 이유로 호버 중에는 안 그린다(아이콘이 그 자리에 서 있다).
            const label = if (repo.failed) repoFailedLabel() else repoPendingLabel();
            if (actions_left_x == null) {
                try self.trailing(rect, label, .muted_fg, .supporting, right_inset);
                const budget = self.measureBudget(label, .supporting) + @as(f32, @floatFromInt(m.gap + right_inset));
                try self.lineWithin(rect, name_x - rect.rect.x, rect.rect.x + rect.rect.width - budget, repo.name, .surface_fg, .control, true);
            } else {
                try self.lineWithin(rect, name_x - rect.rect.x, right_limit, repo.name, .surface_fg, .control, true);
            }
            return;
        }
        const right_edge: f32 = if (pill) |p|
            // 배지 왼쪽 여백은 `gap`보다 넓다 — 칠해진 알약이라 같은 간격이면 브랜치 이름에
            // 달라붙어 보인다(사용자 지적 2026-08-19: "11이 겹쳐 보인다").
            @as(f32, @floatFromInt(p.box.x)) - @as(f32, @floatFromInt(m.badgeGapPx()))
        else
            right_limit;

        // 브랜치는 오른쪽에 붙는다(이름이 길면 이름이 먼저 잘린다 — 어느 저장소인지가 어느 브랜치인지보다
        // 앞선다). 자리를 못 잡으면 아예 안 그린다.
        var branch_width: f32 = 0;
        // 호버 중에는 브랜치도 안 그린다 — 아이콘 띠가 그 자리를 쓴다(위 설명).
        if (repo.branch.len > 0 and actions_left_x == null) {
            const w = self.measureBudget(repo.branch, .supporting);
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

        // **좁으면 배지·동작 자리를 먼저 내려놓는다**(파일 행과 같은 사다리 — `fileRowLadder`).
        // 그러지 않으면 제목이 `…` 하나로 사라진다(Lab 실측: 폭 104pt 에서 "스테이지된 변경"이 통째로
        // 없어졌다). 섹션 제목은 그 아래 행들이 **무엇의 목록인지**를 말하는 유일한 글자라, 개수보다
        // 먼저 지켜야 한다 — 개수는 목록을 세면 알 수 있지만 이름은 그렇지 않다.
        const title_x = rect.rect.x + @as(f32, @floatFromInt(m.iconColumnX())); // 같은 아이콘 열
        const title_floor = self.nameFloorPx();
        const pill_span: f32 = if (pill) |p| (rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(p.box.x))) else 0;
        const action_span: f32 = if (section.action != .none) @floatFromInt(m.action_extent + m.gap) else 0;
        const bare_end = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x));
        const show_pill = pill != null and (bare_end - pill_span - action_span - title_x) >= title_floor;
        const show_action_reserve = section.action != .none and
            (bare_end - (if (show_pill) pill_span else 0) - action_span - title_x) >= title_floor;
        // 제목은 **오른쪽에 있는 것 전부**를 비켜선다: 배지, 그리고 그 왼쪽의 일괄 동작 버튼.
        // 배지만 기준으로 삼으면 그 사이에 앉은 버튼 위로 긴 제목이 그려진다(적대적 검증에서 잡혔다).
        const action_reserve: f32 = if (show_action_reserve) action_span else 0;
        const title_end: f32 = (if (show_pill)
            @as(f32, @floatFromInt(pill.?.box.x)) - @as(f32, @floatFromInt(m.gap))
        else
            bare_end) - action_reserve;
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

        // 사다리가 배지를 내려놓았으면 그리지도 않는다 — 예산만 비우고 그리면 제목 위에 겹친다.
        if (!show_pill) return;
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
    /// 파일 행이 이 폭에서 무엇을 남기는가. **"이름은 마지막까지 남는다"** — 파일 탐색기와 같은 규칙이고
    /// (`file_tree/types.zig` 의 `rowLayout`), 이 뷰의 순서는 이렇다:
    ///
    ///   ① disclosure 열(파일 행에는 화살표가 없다 — 그룹 아래로 들여쓰는 장식일 뿐이다)
    ///   ② 증감 수(`+12 -0`·`bin`)
    ///   ③ 동작 버튼 자리(호버해야 보이는 것이라, 누르려면 폭을 넓히면 된다)
    ///   ④ 상태 문자(`M`·`U`)
    ///   — 못 버림: 좌우 패딩 · 종류 아이콘 · 이름
    ///
    /// 이 사다리가 없을 때 도크 하한(폭 104pt = 도크 120 − 스크롤 거터 16)에서 **이름이 통째로 사라지고**
    /// 증감이 아이콘 위에 겹쳐 그려졌다(Lab 캡처 실측 2026-08-25). 예산이 음수가 되면 `lineWithin` 이
    /// 조용히 아무것도 안 그리기 때문이다 — 가장 지켜야 할 것을 가장 먼저 버리고 있었다.
    ///
    /// **결정은 폭과 그 행이 실제로 그릴 것만 본다.** 호버 여부로 갈리면 포인터를 스칠 때마다 이름이
    /// 늘었다 줄었다 한다(그 규율은 아래 `occupied` 주석이 이미 소유한다).
    const FileRowLadder = struct {
        show_indent: bool,
        show_delta: bool,
        show_action_slot: bool,
        show_status: bool,
        name_x: f32,
        text_end: f32,
    };

    fn fileRowLadder(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics, delta_w: f32, action_w: f32) FileRowLadder {
        _ = self;
        const row_w = rect.rect.width;
        const icon_span: f32 = @floatFromInt(m.icon_extent + m.gap);
        const pad: f32 = @floatFromInt(m.inset_x);
        const indent: f32 = @floatFromInt(m.disclosure_extent + m.gap);
        const status: f32 = @floatFromInt(m.status_extent + m.gap);
        const floor = types.DockMetrics.name_floor_px;

        var show_indent = true;
        var show_delta = delta_w > 0;
        var show_action = action_w > 0;
        var show_status = true;

        // 남는 이름 폭 = 행 − 왼쪽(패딩 + 들여쓰기? + 아이콘) − 오른쪽(패딩 + 상태? + 증감/동작 자리)
        const remaining = struct {
            fn f(w: f32, p: f32, ind: f32, icon_w: f32, st: f32, occ: f32, i: bool, s: bool) f32 {
                return w - (p + (if (i) ind else 0) + icon_w) - (p + (if (s) st else 0) + occ);
            }
        }.f;
        var occupied = @max(if (show_delta) delta_w else 0, if (show_action) action_w else 0);
        if (remaining(row_w, pad, indent, icon_span, status, occupied, show_indent, show_status) < floor) show_indent = false;
        if (remaining(row_w, pad, indent, icon_span, status, occupied, show_indent, show_status) < floor) {
            show_delta = false;
            occupied = if (show_action) action_w else 0;
        }
        // **build 와 같은 함수로 판정한다** — 두 층이 갈리면 노드는 있는데 자리가 없는 상태가 된다.
        if (show_action and !m.rowActionFits(row_w)) {
            show_action = false;
            occupied = 0;
        }
        if (remaining(row_w, pad, indent, icon_span, status, occupied, show_indent, show_status) < floor) show_status = false;

        const left = pad + (if (show_indent) indent else 0);
        const right = pad + (if (show_status) status else 0) + occupied;
        return .{
            .show_indent = show_indent,
            .show_delta = show_delta,
            .show_action_slot = show_action,
            .show_status = show_status,
            .name_x = left + icon_span,
            .text_end = rect.rect.x + row_w - right,
        };
    }

    /// 이름에게 주려는 최소 폭 — **보장이 아니라 목표**다(파일 탐색기의 `label_floor` 와 같은 값·같은
    /// 성격). 다 버려도 모자라면 이름이 남은 것을 전부 받는다. 도크 하한에서는 목표에 못 미친다.
    fn nameFloorPx(self: *Writer) f32 {
        _ = self;
        return types.DockMetrics.name_floor_px;
    }

    fn fileRow(self: *Writer, rect: tree.RectEntry, file: types.FileItem, m: types.DockMetrics) ViewError!void {
        // 이름은 **아이콘 폭만큼 더** 들어간다. 그룹 헤더의 화살표 자리(`disclosure_extent`)만 비우면
        // 아이콘이 이름 위에 겹쳐 그려진다(제품 캡처에서 실제로 그랬다 — 슬롯 폭과 gap은 다른 값이다).
        // 증감·동작이 **실제로 차지할 폭**을 먼저 재고, 그것으로 사다리를 돌린다(무엇을 버릴지 정한다).
        var pre_removed_buf: [16]u8 = undefined;
        var pre_added_buf: [16]u8 = undefined;
        const pre_removed: []const u8 = if (file.has_delta) (std.fmt.bufPrint(&pre_removed_buf, "-{d}", .{file.removed}) catch "") else "";
        const pre_added: []const u8 = if (file.has_delta) (std.fmt.bufPrint(&pre_added_buf, "+{d}", .{file.added}) catch "") else "";
        const delta_w: f32 = if (file.binary)
            self.measureBudget("bin", .supporting) + @as(f32, @floatFromInt(m.gap))
        else if (file.has_delta)
            self.measureBudget(pre_removed, .supporting) + self.measureBudget(pre_added, .supporting) + @as(f32, @floatFromInt(m.gap * 2))
        else
            0;
        const action_w: f32 = if (file.action != .none) @floatFromInt(m.action_extent + m.gap) else 0;
        const ladder = self.fileRowLadder(rect, m, delta_w, action_w);

        const inset: f32 = ladder.name_x;
        const icon_x: f32 = @floatFromInt(if (ladder.show_indent) m.iconColumnX() else m.inset_x);
        // **종류 아이콘은 탐색기와 같은 분류기**를 쓴다 — 같은 파일이 두 화면에서 다른 아이콘이면 안 된다.
        if (file_tree_icon.codepoint(file_tree_icon.classify(.file, file.name, false))) |cp| {
            var glyph_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &glyph_buf) catch 0;
            // 아이콘은 **자기 라벨과 같은 단**이다. `muted_fg`(밝기 207)를 쓰던 동안 아이콘이 이름
            // (169)보다 밝아, 목록을 훑는 눈이 종류 표시에 먼저 걸렸다 — 파일 탐색기가 같은 이유로
            // 아이콘과 라벨을 한 위계로 묶는다.
            if (len > 0) try self.icon(rect, icon_x, glyph_buf[0..len], m.icon_extent, .list_secondary_fg);
        }
        // 상태 문자는 오른쪽 끝(VS Code 배치). 색은 종류가 정하고, 글자는 그대로 그린다.
        var letter_buf: [1]u8 = .{file.letter};
        if (ladder.show_status) try self.trailing(rect, letter_buf[0..], statusRole(file.status), .control, m.inset_x);

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

        var right_inset = m.inset_x + (if (ladder.show_status) m.status_extent + m.gap else 0);
        if (!ladder.show_delta) {
            // 사다리가 증감을 내려놓았다(좁아서 이름이 먼저다).
        } else if (hovered_row) {
            // 아무것도 그리지 않는다(위 주석).
        } else if (file.binary) {
            try self.trailing(rect, "bin", .muted_fg, .supporting, right_inset);
        } else if (file.has_delta) {
            try self.trailing(rect, delta_removed, .git_deleted_fg, .supporting, right_inset);
            right_inset += @intFromFloat(self.measureBudget(delta_removed, .supporting));
            right_inset += m.gap;
            try self.trailing(rect, delta_added, .git_added_fg, .supporting, right_inset);
        }

        // 이름은 굵게, 경로는 흐리게. 이름 뒤에 경로를 이어 그리되 폭 예산은 **이름 우선**이다.
        //
        // **오른쪽 자리를 비켜선다.** 이름·경로는 `trailing` 항목들보다 **나중에** 그려지므로, 예산이 행
        // 오른쪽 끝까지 열려 있으면 긴 경로가 증감·상태 문자를 덮는다(적대적 검증에서 잡혔다 —
        // 그리는 순서가 곧 z축이다).

        // **호버 여부와 무관하게 같은 폭을 비운다.** 그 자리를 증감이 쓰다가 호버하면 버튼이 쓰는데,
        // 둘 중 하나로만 예산을 잡으면 포인터를 스칠 때마다 말줄임 지점이 움직여 **이름이 늘었다 줄었다
        // 한다**(적대적 검증에서 잡혔다). 둘 중 큰 쪽을 항상 비워 두면 화면이 조용하다.
        // 예약 폭은 **사다리가 이미 계산했다** — 여기서 다시 재면 두 값이 갈린다.
        const text_end = ladder.text_end;
        // **목록 행 타이포**(`list_row` 14pt regular)와 **전경 위계**를 파일 탐색기와 맞춘다. 같은 도크
        // 컬럼에서 뷰만 바꿨는데 글자 크기·밝기가 달라지면 그 자체가 두 화면처럼 읽힌다.
        //
        // 이름이 굵지 않은 것도 그 위계의 일부다 — 섹션 제목이 `control` + bold 로 남으므로, 행이 regular
        // 여야 "제목 아래 항목들"로 읽힌다(예전에는 둘 다 굵어 층이 없었다).
        // **꼬리가 붙는 행에서는 이름을 자기 예약만큼으로 자른다.** 예약과 이름의 끝이 같은 수에서
        // 나와야 face 와 무관하게 겹치지 않는다 — `measureRun` 은 "열 수 × primary face advance" 라서
        // **폴백 face 가 더 넓으면 모자란다**. 실측: 이름이 `🔥🔥🔥🔥.zig` 면 이모지 advance 가 2 칸
        // 예약(1.2 em)을 넘어 `.zigsrc/session/` 처럼 붙었다(적대적 검증 2026-08-25). 자르면 그 상태가
        // **겹침이 아니라 말줄임**으로 나온다 — 읽을 수 있고, 무엇이 잘렸는지도 보인다.
        //
        // ASCII 처럼 primary face 만 쓰는 이름은 예약이 실제 폭 이상이라(올림) 아무것도 잘리지 않는다.
        const name_px = if (file.dir.len > 0) self.measureRun(file.name, .list_row) else 0;
        const name_end = if (file.dir.len > 0)
            @min(text_end, rect.rect.x + inset + name_px)
        else
            text_end;
        try self.lineWithin(rect, inset, name_end, file.name, if (file.selected) .focus_accent else .list_secondary_fg, .list_row, false);
        if (file.dir.len > 0) {
            // 경로 꼬리는 이름보다 **한 단 더** 물러난다. 예전 `muted_fg`(밝기 207)는 이름이 쓰던
            // `surface_fg` 보다는 흐렸지만, 이름이 `list_secondary_fg`(169)로 내려오면 **꼬리가 더 밝아진다**
            // — 파일 탐색기에서 같은 역전을 실제로 겪었다(무시된 행이 기본 행보다 밝았다).
            try self.lineWithin(rect, inset + name_px + @as(f32, @floatFromInt(m.gap)), text_end, file.dir, .list_disabled_fg, .supporting, false);
        }
    }

    /// 글자 하나의 대략 폭. **정확한 advance는 backend가 안다** — 여기서는 무언가를 그 글자 **뒤에**
    /// 놓기 위한 보수적 상한만 낸다.
    ///
    /// **열당 1px 을 더한다.** `cell_width_px` 는 실제 advance 의 **내림**이다(정수 셀 격자 — 예: 기본
    /// JetBrains Mono 14pt 는 8.4px 인데 셀은 8 이다). 그런데 measured chrome 텍스트는 셀에 스냅되지 않고
    /// 그 8.4px 로 그려지므로, `cols * cell` 은 **모자란다** — 열이 늘수록 벌어져서 파일 행에서는 이름과
    /// 경로 꼬리 사이의 틈이 0 이 됐다(`staged.zigsrc/session/` 처럼 붙어 읽힌다). 옛 주석은 이 값을
    /// "보수적"이라고 적었는데 방향이 반대였고, Lab 이 도크를 **비례 폰트**로 그리던 동안에는 추정이
    /// 남아돌아 골든에도 안 보였다(2026-08-24, face 를 제품과 맞추면서 드러났다).
    ///
    /// `cell = floor(advance)` 이므로 `advance < cell + 1` 이고, 열당 1px 상한은 **어떤 등폭 face 에서도**
    /// 겹치지 않는다. 과잉 확보는 열당 최대 1px 이다(10 글자면 6px 남짓 — 틈이 조금 넓어질 뿐이다).
    /// backend 는 이제 advance 의 **소수까지** 준다(`CellMetricsResult.advance_milli_px`) — 그래서
    /// `measureRun` 의 비율에는 반올림 근사가 없다. 이 상한은 그 값을 못 받은 호출부(단위 테스트·구형
    /// 배선)의 물러설 자리로만 남는다.
    ///
    /// **caret·선택 기하(`colWidth`)에는 이 보정을 넣지 않는다.** 그쪽은 플랫폼 배치와 **같은 자**를
    /// 써야 글자 위에 정확히 앉는다 — 여기 상한을 그쪽에 쓰면 커서가 글자에서 밀린다.
    ///
    /// **이 상한이 덮지 못하는 것**: 셀은 터미널 폰트 크기의 글자 폭이고 chrome 텍스트는 role 크기로
    /// 그려진다 — 둘이 벌어지면(`font.size` 12 대 `list_row` 14pt) 부족분이 1px 을 넘는다. 그래서 **런을
    /// 이어 붙이는 자리는 `measureRun`** 을 쓴다. 여기 남은 소비자는 오른쪽 예약(증감·상태 문자 자리)이라
    /// 과소 추정이 겹침이 아니라 여유 부족으로만 나타나고, 그 자리 글자는 대부분 `supporting`(12pt)이라
    /// 터미널 크기와 가까워 오차도 작다.
    /// **다음 런을 이 글자 뒤에 놓기 위한 폭.** 위 `measureBudget` 과 달리 role 의 실제 크기로 환산한다.
    ///
    /// `measureBudget` 의 상한(`cell + 1`)이 덮는 것은 셀의 **반올림 오차**뿐이다. 그런데 chrome 텍스트는
    /// 터미널 크기가 아니라 role 크기(`list_row` 14pt)로 그려지고 둘은 독립이라, 사용자가 `font.size` 를
    /// 12 로 두면 셀 7px 대 실제 8.4px 로 **열당 1.4px** 이 모자란다 — 상한을 넘는다(실측으로 그 크기에서
    /// 이름과 경로 꼬리가 다시 붙었다). 그래서 **런을 이어 붙이는 자리**는 이 함수를 쓴다.
    ///
    /// 비율을 모르면(props 기본값 0) 옛 추정으로 물러난다 — 그래야 값을 안 넘기는 호출부가 조용히
    /// 0 폭을 받지 않는다. 제품 배선은 native 메트릭의 **소수까지 온 advance** 로 그 비율을 만든다
    /// (`app_session/scm_dock.zig` 의 `advanceMilliPerPoint`) — 정수 셀에서 뽑던 근사는 사라졌다.
    fn measureRun(self: *Writer, source: []const u8, role: typography.ChromeTextRole) f32 {
        if (self.props.advance_milli_per_point == 0) return self.measureBudgetCells(source);
        const cols = text_layout.displayCols(source, null);
        const point_size: u32 = typography.token(role).point_size;
        // **총합에서 한 번만 올린다.** 열마다 올리면 10 글자에서 10px 까지 과잉 확보돼, 틈이 계약보다
        // 넓어진다 — 그것은 겹침의 반대 방향 오류일 뿐 같은 종류의 부정확이다. 올림 자체는 남긴다:
        // 셀이 정수라 비율에 반올림 오차가 있고, 모자란 쪽으로 틀리면 글자가 겹친다.
        const total_milli = @as(u64, cols) * @as(u64, self.props.advance_milli_per_point) * point_size;
        const total_px = (total_milli + 999) / 1000;
        return @floatFromInt(total_px);
    }

    fn measureBudget(self: *Writer, source: []const u8, role: typography.ChromeTextRole) f32 {
        // 비율을 받았으면 **정확한 값**을 쓴다 — 옛 상한(`cell + 1`)은 셀이 role 보다 작을 때만 여유였고,
        // 반대(터미널이 크고 role 이 작을 때)로는 넉넉히 잡아 글자가 **필요보다 일찍 잘렸다**(기본 설정:
        // 예약 9px 대 실제 `supporting` 7.2px — 세 글자짜리 증감 하나에 5px 이 남았다).
        return self.measureRun(source, role);
    }

    /// 비율을 못 받은 호출부의 물러설 자리. 셀은 실제 advance 의 반올림이라 열당 최대 1px 이 모자랄 수
    /// 있어 그만큼 더 잡는다 — 모자란 쪽으로 틀리면 글자가 겹친다.
    fn measureBudgetCells(self: *Writer, source: []const u8) f32 {
        const cols = text_layout.displayCols(source, null);
        return @floatFromInt(cols * (self.cell_width_px + 1));
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

        // 두 줄짜리 행이 이어지면 어디서 한 커밋이 끝나는지가 안 보인다 — 목록이 한 덩어리로 읽힌다.
        // **첫 줄에는 안 그린다**(위 고정 chrome 과 맞닿아 이중선이 된다).
        if (commit.index > 0) try self.rowTopDivider(rect, m);
        // 고른 줄은 **막대로도** 말한다(밴드만으로는 「조금 밝은 줄」로 읽힌다 — `accent_bar_w` 주석).
        if (commit.selected) try self.selectionBar(rect, m);

        // ── 첫 줄: ref 칩 + 제목.
        var left = rect.rect.x + inset;
        if (commit.ref.len > 0) {
            const w = self.measureBudget(commit.ref, .supporting);
            const chip_pad: f32 = @floatFromInt(m.chip_pad_x);
            if (left + w + chip_pad * 2 < rect.rect.x + rect.rect.width - inset) {
                const chip_y = rect.rect.y + pad_y + (title_h - sub_h) / 2;
                // **칩은 면을 갖는다.** 배경 없이 글자만 두면 제목과 같은 줄에서 한 덩어리로 읽혀,
                // 브랜치 이름이 커밋 제목의 앞부분처럼 보였다(사용자 캡처 2026-08-27).
                try self.appendQuad(.{
                    .rect = .{
                        .x = @intFromFloat(@floor(left)),
                        .y = @intFromFloat(@floor(chip_y)),
                        .w = @intFromFloat(@max(w + chip_pad * 2, 1)),
                        .h = @intFromFloat(@max(sub_h, 1)),
                    },
                    .fill_role = .inset_bg,
                    .corner_radii = .{ 3, 3, 3, 3 },
                });
                // 지금 체크아웃된 브랜치만 강조색이다 — 나머지 ref는 상태 진술이라 흐리다.
                try self.emit(
                    left + chip_pad,
                    chip_y,
                    commit.ref,
                    self.colsFor(w),
                    if (commit.ref_is_head) .focus_accent else .muted_fg,
                    .supporting,
                    false,
                    @intFromFloat(@max(w, 0)),
                    .origin,
                );
                left += w + chip_pad * 2 + gap;
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
            const w = self.measureBudget(text, .supporting);
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
            const w = self.measureBudget(commit.short_oid, .supporting);
            try self.emitAt(right - w, sub_y, commit.short_oid, .muted_fg, .supporting);
            right -= w + gap;
        }
        if (commit.when.len > 0) {
            const w = self.measureBudget(commit.when, .supporting);
            if (right - w > rect.rect.x + inset) {
                try self.emitAt(right - w, sub_y, commit.when, .muted_fg, .supporting);
                right -= w + gap;
            }
        }
        if (commit.author.len > 0) {
            const w = self.measureBudget(commit.author, .supporting);
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

        // 커밋 줄과 **같은 규율**이다(그 함수 주석) — 두 목록이 다른 리듬으로 갈리면 탭을 오갈 때
        // 같은 화면이 아닌 것처럼 읽힌다.
        if (turn.index > 0) try self.rowTopDivider(rect, m);
        if (turn.selected) try self.selectionBar(rect, m);

        const left = rect.rect.x + inset;
        const right = rect.rect.x + rect.rect.width - inset;
        // **요약은 제목 줄 오른쪽에 선다.** 아래 줄(에이전트 · 시각)은 이미 양끝이 차 있어 여기밖에
        // 자리가 없다. 제목이 먼저이므로 요약이 안 들어가면 요약을 뺀다 — 제목을 밀어내지 않는다.
        var title_right = right;
        if (turn.summary.len > 0) {
            const w = self.measureBudget(turn.summary, .supporting);
            if (title_right - w > left) {
                try self.emitAt(title_right - w, rect.rect.y + pad_y, turn.summary, .muted_fg, .supporting);
                title_right -= w + gap;
            }
        }
        if (title_right > left) {
            try self.emit(
                left,
                rect.rect.y + pad_y,
                turn.title,
                self.colsFor(title_right - left),
                // **강조색을 쓰지 않는다**: 이 테마에서 그 역할은 본문보다 흐려서, 진행 중 줄이 오히려
                // 덜 중요해 보였다(제품 캡처 2026-08-18). "진행 중"이라는 말과 빈 시각이 이미 그 사실을
                // 말하므로 색을 하나 더 얹지 않는다.
                .surface_fg,
                .control,
                true,
                @intFromFloat(@max(title_right - left, 0)),
                .origin,
            );
        }

        const sub_y = rect.rect.y + pad_y + title_h;
        var sub_right = right;
        if (turn.when.len > 0) {
            const w = self.measureBudget(turn.when, .supporting);
            if (sub_right - w > left) {
                try self.emitAt(sub_right - w, sub_y, turn.when, .muted_fg, .supporting);
                sub_right -= w + gap;
            }
        }
        var sub_left = left;
        if (turn.agent.len > 0 and left + self.measureBudget(turn.agent, .supporting) < sub_right) {
            try self.emitAt(left, sub_y, turn.agent, .muted_fg, .supporting);
            sub_left += self.measureBudget(turn.agent, .supporting) + gap;
        }
        // **무엇을 했는지**(AT2). 에이전트 이름 뒤 남은 폭에만 넣고 **넘치면 안 그린다** — 위치 이름
        // (`마지막 턴`)이 그 줄이 어느 턴인지를 말하므로, 자리가 없을 때 밀어낼 것은 이쪽이다.
        //
        // ⚠️ **`lineWithin` 을 쓰지 않는다.** 그것은 **행 세로 중앙**에 그리는 한 줄짜리 도우미라, 두 줄
        // 행의 아랫줄에 쓰면 제목 줄 위에 겹쳐 그린다(적대적 검증에서 그렇게 짰다가 잡았다). 이 줄은
        // `sub_y` 가 정한다.
        if (turn.reply.len > 0 and sub_right > sub_left) {
            try self.emit(
                sub_left,
                sub_y,
                turn.reply,
                self.colsFor(sub_right - sub_left),
                .muted_fg,
                .supporting,
                false,
                @intFromFloat(@max(sub_right - sub_left, 0)),
                .origin,
            );
        }
    }

    /// 펼친 커밋 아래의 파일 한 줄(P4b). 파일 행과 같은 격자이되 **동작 버튼이 없다** — 지난 커밋의
    /// 파일은 스테이지할 대상이 아니다.
    fn commitFileRow(self: *Writer, rect: tree.RectEntry, file: types.CommitFileItem, m: types.DockMetrics) ViewError!void {
        // 그 커밋에 속한다는 것을 들여쓰기로 말한다(그룹 안의 파일 행과 같은 규율 — 같은 아이콘 열).
        const indent = @as(f32, @floatFromInt(m.iconColumnX()));
        const gap: f32 = @floatFromInt(m.gap);
        const name_x = indent + @as(f32, @floatFromInt(m.icon_extent + m.gap));

        // **증감을 먼저 잰다.** 오른쪽에 무엇이 설지 정해야 이름 예산이 나온다(변경 사항 탭의 파일 행이
        // `fileRowLadder` 로 하는 일과 같은 판단 — 이 행은 동작 버튼이 없어 사다리가 한 칸 짧다).
        var removed_buf: [16]u8 = undefined;
        var added_buf: [16]u8 = undefined;
        const delta_removed: []const u8 = if (file.has_delta and !file.binary) (std.fmt.bufPrint(&removed_buf, "-{d}", .{file.removed}) catch "") else "";
        const delta_added: []const u8 = if (file.has_delta and !file.binary) (std.fmt.bufPrint(&added_buf, "+{d}", .{file.added}) catch "") else "";
        const delta_w: f32 = if (!file.has_delta)
            0
        else if (file.binary)
            self.measureBudget("bin", .supporting) + gap
        else
            self.measureBudget(delta_removed, .supporting) + self.measureBudget(delta_added, .supporting) + gap * 2;
        const mark = originMark(file.origin);
        const mark_w: f32 = if (mark) |text| self.measureBudget(text, .supporting) + gap else 0;
        const status_w: f32 = @floatFromInt(m.status_extent + m.gap);

        // 사다리: 이름이 목표 폭에 못 미치면 **증감 → 소행 표시 → 상태 문자** 순으로 내려놓는다.
        // 이름이 마지막까지 남는 이유는 파일 행과 같다 — 어느 파일인지가 이 줄의 존재 이유다.
        const floor = types.DockMetrics.name_floor_px;
        const right_edge = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(m.inset_x));
        var show_delta = delta_w > 0;
        var show_mark = mark != null;
        var show_status = true;
        const nameSpace = struct {
            fn f(edge: f32, start: f32, d: f32, mk: f32, st: f32, sd: bool, sm: bool, ss: bool) f32 {
                return edge - start - (if (sd) d else 0) - (if (sm) mk else 0) - (if (ss) st else 0);
            }
        }.f;
        if (nameSpace(right_edge, name_x, delta_w, mark_w, status_w, show_delta, show_mark, show_status) < floor) show_delta = false;
        if (nameSpace(right_edge, name_x, delta_w, mark_w, status_w, show_delta, show_mark, show_status) < floor) show_mark = false;
        if (nameSpace(right_edge, name_x, delta_w, mark_w, status_w, show_delta, show_mark, show_status) < floor) show_status = false;

        // 그 줄들이 **바로 위 커밋/턴에 속한다**는 사실을 안내선이 말한다(들여쓰기만으로는 목록의
        // 다음 항목처럼 읽혔다 — 사용자 캡처 2026-08-27).
        try self.childRail(rect, m);
        if (file.selected) try self.selectionBar(rect, m);
        if (file_tree_icon.codepoint(file_tree_icon.classify(.file, file.name, false))) |cp| {
            var icon_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &icon_buf) catch 0;
            if (len > 0) try self.icon(rect, indent, icon_buf[0..len], m.icon_extent, .list_secondary_fg); // 위 파일 행과 같은 단
        }
        var right_inset = m.inset_x;
        if (show_status) {
            var letter_buf: [1]u8 = .{file.letter};
            try self.trailing(rect, letter_buf[0..], statusRole(file.status), .supporting, right_inset);
            right_inset += m.status_extent + m.gap;
        }
        // **증감도 색을 갖는다**(변경 사항 탭과 같은 역할 토큰) — 한 덩어리로 흐리게 그리면 "얼마나 늘고
        // 줄었나"가 한눈에 안 들어온다. 이진 파일은 `0/0` 으로 거짓말하지 않고 `bin` 이라 적는다.
        if (show_delta) {
            if (file.binary) {
                try self.trailing(rect, "bin", .muted_fg, .supporting, right_inset);
                right_inset += @intFromFloat(self.measureBudget("bin", .supporting) + gap);
            } else {
                try self.trailing(rect, delta_removed, .git_deleted_fg, .supporting, right_inset);
                right_inset += @intFromFloat(self.measureBudget(delta_removed, .supporting));
                right_inset += m.gap;
                try self.trailing(rect, delta_added, .git_added_fg, .supporting, right_inset);
                right_inset += @intFromFloat(self.measureBudget(delta_added, .supporting) + gap);
            }
        }
        // **누가 바꿨나**(계약 §4.2). 상태 글자·증감 **왼쪽**에 선다 — 그것들은 다른 축이라(무엇이
        // 일어났나 / 얼마나 / 누가 했나) 한 자리에 겹칠 수 없다. `.unknown` 은 **아무것도 안 그린다**:
        // 근거가 없다는 것과 「셸이 고쳤다」는 다른 사실이라, 없는 근거를 기호로 지어내지 않는다.
        if (show_mark) {
            if (mark) |text| {
                try self.trailing(rect, text, switch (file.origin) {
                    // 본문 색이다 — 흐린 `·` 와 **대비가 나야** 두 근거가 갈려 보인다. 새 역할을 만들지
                    // 않는다(테마마다 두 곳을 고치게 된다 — `statusRole` 과 같은 규율).
                    .ai_edit => .surface_fg,
                    else => .muted_fg,
                }, .supporting, right_inset);
                right_inset += @intFromFloat(self.measureBudget(text, .supporting) + gap);
            }
        }
        // 위 변경 파일 행과 **같은 목록 행 타이포**다(한 화면에서 두 목록이 다른 크기면 안 된다).
        //
        // **이름 끝은 사다리가 쓴 그 수에서 나온다** — 위에서 조각을 놓으며 누적한 `right_inset` 을
        // 쓰면 안 된다. 그쪽은 `u32` 라 조각마다 `@intFromFloat` 으로 **버려지고**(예: 8.4 → 8),
        // 조각이 셋이면 최대 3px 이 덜 예약되어 긴 이름이 증감 위로 파고든다. 파일 행이 예약을
        // `fileRowLadder` 하나에서만 내는 이유가 그것이다(`text_end` 주석 — 두 값이 갈리면 겹친다).
        const name_end = right_edge -
            (if (show_delta) delta_w else 0) -
            (if (show_mark) mark_w else 0) -
            (if (show_status) status_w else 0);
        try self.lineWithin(rect, name_x - rect.rect.x, name_end, file.name, if (file.selected) .focus_accent else .list_secondary_fg, .list_row, false);
    }

    /// 고른 줄의 **좌측 강조 막대**. 밴드(`variant = .selected`)와 **함께** 선다 — 밴드는 「이 줄」을
    /// 말하고 막대는 「고른 줄」을 말한다. 두 줄짜리 행이 이어지는 히스토리·에이전트 목록에서는 밴드만으로
    /// 「조금 밝은 줄」과 구별되지 않는다(사용자 지적 2026-08-27).
    ///
    /// **행 왼쪽 끝에 붙는다**(들여쓰기 안이 아니라). 목록 격자의 밖이어야 그 줄 전체를 가리키는 표시로
    /// 읽히고, 안쪽에 두면 아이콘 열과 다투다.
    fn selectionBar(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics) ViewError!void {
        if (rect.rect.width <= 0 or rect.rect.height <= 0) return;
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(rect.rect.x)),
                .y = @intFromFloat(@floor(rect.rect.y)),
                .w = @max(m.accent_bar_w, 1),
                .h = @intFromFloat(@max(rect.rect.height, 1)),
            },
            .fill_role = .accent_bar,
        });
    }

    /// 항목 사이의 **얇은 가로선**. 두 줄짜리 행(커밋·턴)은 자기 안에 이미 두 층이 있어, 선이 없으면
    /// 어디서 한 항목이 끝나는지가 안 보인다 — 파일 행에는 그리지 않는다(한 줄짜리라 표가 된다는
    /// 2026-08-14 지적이 그대로 산다).
    fn rowTopDivider(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics) ViewError!void {
        if (rect.rect.width <= 0) return;
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(rect.rect.x)),
                .y = @intFromFloat(@floor(rect.rect.y)),
                .w = @intFromFloat(@max(rect.rect.width, 1)),
                .h = @max(m.rail_w, 1),
            },
            .fill_role = .divider,
        });
    }

    /// 펼친 항목 아래 파일 줄의 **세로 안내선**. 파일 탐색기의 들여쓰기 안내선과 같은 값·같은 뜻이다 —
    /// 그 줄들이 바로 위 커밋/턴에 속한다는 사실을 들여쓰기 하나로는 말하지 못한다(사용자 캡처에서
    /// 파일 목록이 목록 전체의 다음 항목처럼 보였다).
    fn childRail(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics) ViewError!void {
        if (rect.rect.width <= 0 or rect.rect.height <= 0) return;
        // 아이콘 열의 **왼쪽 절반** 자리 — 들여쓰기 칸의 가운데다. 아이콘과 다투지 않는다.
        const x = rect.rect.x + @as(f32, @floatFromInt(m.inset_x + m.disclosure_extent / 2));
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(x)),
                .y = @intFromFloat(@floor(rect.rect.y)),
                .w = @max(m.rail_w, 1),
                .h = @intFromFloat(@max(rect.rect.height, 1)),
            },
            .fill_role = .divider,
        });
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
        const w = self.measureBudget(text, text_role);
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
        const width = self.measureBudget(source, text_role);
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
        const width = self.measureBudget(source, text_role);
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

/// `renderFixture` 와 같되 **브랜치 이름과 도크 폭**을 지정한다 — 긴 이름이 오른쪽 묶음을 침범하는지
/// 보려면 그 둘을 흔들어야 한다.
fn renderFixtureBranch(storage: *TestStorage, items: []const types.Item, branch: []const u8, width: f32) !draw.ChromeDraw {
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = width, .height = 400 },
        .items = items,
        .branch = branch,
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
    return viewBudgeted(storage, props, frame, .{});
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

// **작은 터미널 폰트에서도 경로 꼬리가 이름을 파고들지 않는가.**
//
// 이 판정자가 없던 동안 `cell + 1` 상한이 "어떤 등폭 face 에서도 안전하다"고 적혀 있었는데 거짓이었다:
// 상한이 덮는 것은 셀의 반올림이고, 진짜 간극은 **터미널 크기(셀)와 role 크기(14pt)의 차이**다.
// 실측으로 셀 7px(사용자 `font.size` 12 상당)에서 `staged.zigsrc/session/` 처럼 붙었다.
test "이름 뒤 경로는 role 크기로 자리를 잡는다(작은 셀에서도 겹치지 않는다)" {
    const cell_px: u32 = 7; // font.size 12 상당
    const font_pt: u32 = 12;
    const advance_milli = cell_px * 1000 / font_pt; // 583 — face 의 포인트당 advance
    var writer = Writer{
        .props = .{
            .viewport_px = .{ .x = 0, .y = 0, .width = 480, .height = 320 },
            .cell_width_px = cell_px,
            .advance_milli_per_point = advance_milli,
            .snapshot_generation = 1,
            .items = &.{},
        },
        .ops = &.{},
        .runs = &.{},
        .text_bytes = &.{},
        .op_count = 0,
        .cell_width_px = cell_px,
        .state = .{},
        .tokens_ref = &testTokens(),
    };
    const name = "staged.zig"; // 10 열
    const reserved = writer.measureRun(name, .list_row);
    // 실제로 그려지는 폭: 14pt × (advance/pt). 예약이 그보다 작으면 다음 런이 글자를 파고든다.
    const drawn = @as(f32, @floatFromInt(name.len)) * (@as(f32, @floatFromInt(advance_milli)) * 14.0 / 1000.0);
    try testing.expect(reserved >= drawn);
    // 옛 상한(`cols * (cell + 1)`)은 **모자랐다** — 이 판정자가 무엇을 막는지 값으로 남긴다.
    const old_bound = @as(f32, @floatFromInt(name.len * (cell_px + 1)));
    try testing.expect(old_bound < drawn);
    // 그렇다고 넉넉하지도 않다(틈이 벌어지면 그것대로 읽기 나쁘다) — **총합 올림**이라 1px 미만이다.
    try testing.expect(reserved - drawn < 1.0);
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

    // **목록 행 타이포가 파일 탐색기와 같다.** 이 단언이 없으면 role 을 되돌려도 아무도 모른다 —
    // 화면에서만 보이는 종류이고, 같은 도크 컬럼에서 뷰만 바꿨을 때 글자 크기가 튀는 것이 그 증상이다.
    const name = findExactText(draws, "scm_view.zig").?;
    try testing.expectEqual(typography.ChromeTextRole.list_row, name.text_role);
    try testing.expectEqual(tokens.ColorRole.list_secondary_fg, name.role);
    try testing.expect(!name.runs[0].bold); // 섹션 제목만 굵다 — 행이 굵으면 층이 사라진다

    // 경로 꼬리는 이름보다 **한 단 더** 물러난다. 두 값이 같거나 뒤집히면 위계가 사라진 것이다
    // (파일 탐색기에서 실제로 뒤집혀 있었다).
    const dir = findExactText(draws, "src/session/").?;
    try testing.expectEqual(tokens.ColorRole.list_disabled_fg, dir.role);
    try testing.expect(dir.role != name.role);

    // **그 행의 아이콘도 라벨과 같은 단이다.** 실측으로 아이콘 207 대 라벨 169 였다 — 목록을 훑는
    // 눈이 종류 표시에 먼저 걸리는 상태였고, 그 어긋남은 화면에서만 보인다.
    //
    // **같은 행의 것만 본다** — 브랜치·접힘 같은 다른 아이콘은 `muted_fg` 가 맞고, 전부 싸잡으면
    // 이 단언이 그 자리들까지 끌고 간다(처음에 그렇게 썼다가 픽스처가 잡았다).
    // **같은 행의 아이콘을 고른다.** 두 `origin.y` 를 그대로 비교하면 안 맞는다 — 아이콘은 16px 슬롯
    // 중앙, 글자는 20px line box 중앙이라 기준이 다르다(실측으로 확인했다). 그래서 라벨과 세로로 가장
    // 가까운 아이콘을 고르고, 그 거리가 한 행 안인지까지 본다.
    var row_icon: ?tokens.ColorRole = null;
    var best_dy: i32 = std.math.maxInt(i32);
    for (draws.ops) |op| {
        if (op != .text or op.text.placement != .icon_in_rect) continue;
        const dy: i32 = @intCast(@abs(op.text.placement.icon_in_rect.content_rect.y - name.origin.y));
        if (dy < best_dy) {
            best_dy = dy;
            row_icon = op.text.role;
        }
    }
    try testing.expect(row_icon != null);
    try testing.expect(best_dy < 20); // 같은 행이다(다른 행이면 행 높이만큼 떨어진다)
    try testing.expectEqual(tokens.ColorRole.list_secondary_fg, row_icon.?);
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

    const chip = findExactText(draws, fetch_icon) orelse return error.MissingFetchLabel;
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
    // **글리프가 갈린다.** 색만으로는 못 가른다 — 꺼진 칩(원격 없음)도 같은 회색이라, 도는 중과
    // 못 누르는 것이 한 그림이 된다.
    var seen_running = false;
    var seen_idle = false;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, fetching_icon)) seen_running = true;
            if (std.mem.eql(u8, run.text, fetch_icon)) seen_idle = true;
        },
        else => {},
    };
    try testing.expect(seen_running);
    try testing.expect(!seen_idle); // 두 글리프가 함께 뜨지 않는다
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

/// 호버해서 떠 있는 동작 아이콘의 가장 왼쪽 x(하나도 안 그려졌으면 null).
fn repoActionIconLeft(draws: draw.ChromeDraw) ?i32 {
    var left: ?i32 = null;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            // 아이콘 조각은 글리프 하나짜리 문자열이다(`utf8Fit`) — 그 조각만 골라 본다.
            if (!std.mem.eql(u8, run.text, refresh_icon) and !std.mem.eql(u8, run.text, stage_all_icon)) continue;
            left = if (left) |l| @min(l, text.origin.x) else text.origin.x;
        },
        else => {},
    };
    return left;
}

test "머리 줄의 동작 아이콘은 브랜치 칩·개수 배지와 안 겹친다 (②c)" {
    // 자리를 비켜 두지도, 그 위를 덮지도 않는다 — **호버하는 동안 그 자리의 글자를 안 그린다**.
    // 덮개는 원리적으로 안 통한다(chrome quad는 chrome 글자보다 먼저 그리는 층이다): 그래서
    // 새로고침 아이콘이 브랜치 이름 위에 겹쳐 보였다(사용자 지적 2026-08-21, 제품 캡처 2026-08-17).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        // props.branch("main")와 갈리는 이름을 쓴다 — 아래 고정 브랜치 줄의 글자와 헷갈리지 않게.
        .{ .repo = .{ .index = 0, .name = "repo", .branch = "feat/x", .count = 3, .can_stage_all = true } },
    };
    const draws = try renderFixture(&storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    try testing.expect(repoActionIconLeft(draws) != null); // 아이콘이 실제로 그려졌다(호버 중)
    // 그 자리에 있던 것들은 이 프레임에 **없다** — 있으면 겹친다.
    try testing.expect(findExactText(draws, "feat/x") == null);
    try testing.expect(findBadgeQuad(draws) == null);
    // 남는 이름은 아이콘 띠 왼쪽에서 멈춘다(길면 말줄임이 되고, 아이콘 밑으로 파고들지 않는다).
    const icon_left = repoActionIconLeft(draws).?;
    const name = findExactText(draws, "repo") orelse return error.MissingName;
    try testing.expect(name.origin.x + @as(i32, @intCast(name.max_width_px orelse 0)) <= icon_left);
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
    // 파일 종류 + 브랜치 줄 아이콘 + 브랜치 줄 `∨`(P6b) + **원격 갱신 칩**(2026-08-20에 글자에서
    // 아이콘이 됐다) = 넷. 그룹 헤더가 없는 fixture이고, **커밋 버튼의 `∨`는 이제 목록 항목**이라
    // 여기 없다(②b에서 커밋 줄이 저장소 그룹 안으로 내려갔다).
    //
    // **`∨`와 칩이 아이콘 경로로 세어져야 한다**: 글자 경로로 그리면 폰트 폴백이 작은 네모를 낸다(실측).
    try testing.expectEqual(@as(usize, 4), icons_seen);
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

// [AT3 §4.2] 배지는 **상태 문자 왼쪽**에 서고 이름을 밀어낸다 — 두 축(무엇이 일어났나 / 누가 했나)이
// 한 자리에 겹치면 어느 쪽도 못 읽는다.
test "턴 파일 배지는 상태 문자와 겹치지 않고 이름보다 오른쪽이다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit_file = .{
            .name = "edited.zig",
            .status = .modified,
            .letter = 'M',
            .from_turn = true,
            .origin = .ai_edit,
        } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const mark = findExactText(draws, "✎") orelse return error.MissingBadge;
    const letter = findExactText(draws, "M") orelse return error.MissingStatus;
    const name = findText(draws, "edited.zig") orelse return error.MissingName;
    // 배지 < 상태 문자 (배지가 왼쪽)
    try testing.expect(mark.origin.x < letter.origin.x);
    // 이름 < 배지 (이름이 더 왼쪽)
    try testing.expect(name.origin.x < mark.origin.x);
    // 이름의 폭 예산이 배지를 침범하지 않는다.
    const budget = name.max_width_px orelse return error.MissingBudget;
    try testing.expect(name.origin.x + @as(i32, @intCast(budget)) <= mark.origin.x);
}

// **근거가 없으면 아무것도 그리지 않는다.** 「모른다」를 기호로 지어내면 「셸이 고쳤다」와 섞인다.
test "턴 파일 배지: 캡처가 없는 턴에는 기호가 없다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit_file = .{ .name = "x.zig", .status = .modified, .letter = 'M', .from_turn = true, .origin = .unknown } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findExactText(draws, "✎") == null);
    try testing.expect(findExactText(draws, "·") == null);
    // 대조군: 상태 문자는 그대로 있다(배지를 뺀 것이지 행을 죽인 것이 아니다).
    try testing.expect(findExactText(draws, "M") != null);
}

// [AT2] 턴 줄의 응답은 **아랫줄**에 선다 — `lineWithin`(행 중앙)으로 그리면 제목 줄에 겹친다.
test "턴 줄의 응답 제목은 제목 줄이 아니라 아랫줄에 그려진다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .turn = .{
            .title = "마지막 턴",
            .agent = "claude",
            .when = "방금",
            .reply = "테스트를 고쳤습니다",
        } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const title = findText(draws, "마지막 턴") orelse return error.MissingTitle;
    const reply = findText(draws, "테스트를 고쳤습니다") orelse return error.MissingReply;
    const agent = findText(draws, "claude") orelse return error.MissingAgent;
    // **제목보다 아래**여야 한다 — 같은 y 면 겹쳐 그린 것이다.
    try testing.expect(reply.origin.y > title.origin.y);
    // 에이전트 이름과 **같은 줄**이고 그 오른쪽이다.
    try testing.expectEqual(agent.origin.y, reply.origin.y);
    try testing.expect(reply.origin.x > agent.origin.x);
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

// 섹션 제목도 같은 규칙을 따른다 — **개수 배지보다 제목이 먼저다.**
//
// 배지가 자리를 먼저 먹던 동안 도크 하한(폭 104pt)에서 "스테이지된 변경"이 `…` 하나로 사라졌다
// (Lab 캡처 실측). 개수는 목록을 세면 알 수 있지만, 그 아래 행들이 **무엇의 목록인지**는 제목만이 말한다.
// **동작 버튼은 노드가 만들어지는 쪽과 자리를 비우는 쪽이 같은 답을 써야 한다.**
//
// 사다리를 `view` 에만 넣었더니 `build` 는 버튼 노드를 그대로 만들었고, 좁은 폭에서 자리를 안 비운 채
// 호버하면 버튼이 **이름 위에** 그려졌다(적대적 검증 2026-08-25). 그래서 판정을 `DockMetrics` 로 올려
// 두 층이 같은 함수를 부른다.
test "좁으면 행 동작 버튼 노드 자체가 안 만들어진다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "src/", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const narrow: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 104, .height = 200 },
        .items = &items,
        .branch = "main",
    };
    const narrow_frame = try build.build(narrow, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    try testing.expect(narrow_frame.tree.find(build.NodeIds.itemAction(0)) == null);

    // 넓으면 그대로 있다 — 사다리는 좁을 때만 움직인다.
    var wide_storage: TestStorage = .{};
    const wide: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 480, .height = 200 },
        .items = &items,
        .branch = "main",
    };
    const wide_frame = try build.build(wide, .{
        .nodes = &wide_storage.nodes,
        .entries = &wide_storage.entries,
        .layout_items = &wide_storage.layout_items,
        .flex_scratch = &wide_storage.flex_scratch,
        .child_rects = &wide_storage.child_rects,
        .actions = &wide_storage.actions,
    });
    try testing.expect(wide_frame.tree.find(build.NodeIds.itemAction(0)) != null);
}

test "좁은 도크에서는 개수 배지가 사라지고 섹션 제목이 남는다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .staged, .count = 3, .collapsed = false, .action = .unstage } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 104, .height = 200 },
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
    const title = findExactText(draws, sectionTitle(.staged)) orelse return error.MissingTitle;
    try testing.expect((title.max_width_px orelse 0) > 0);
    // 배지는 그리지 않는다 — 예산만 비우고 그리면 제목 위에 겹친다.
    try testing.expect(findExactText(draws, "3") == null);
}

test "좁은 도크에서는 오른쪽 자리가 먼저 사라지고 이름이 남는다" {
    // **계약이 뒤집혔다(2026-08-25).** 예전에는 오른쪽(증감·상태·동작)이 폭을 다 먹으면 이름을 아예 안
    // 그렸다 — 예산이 음수가 되면 `lineWithin` 이 조용히 건너뛰기 때문이다. 그 결과 도크 하한에서 SCM
    // 행이 **아이콘과 숫자만 남고 파일 이름이 사라졌다**(Lab 캡처 실측).
    //
    // 이제는 사다리가 뒤집는다: 들여쓰기 → 증감 → 동작 자리 → 상태 문자 순으로 버리고 이름을 지킨다
    // (`fileRowLadder`). 그러니 이 판정자가 재는 것은 "이름이 없는가"가 아니라 **"이름이 남고 오른쪽이
    // 사라졌는가"**, 그리고 둘 다 그려지는 폭에서는 여전히 **겹치지 않는가**이다.
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
    // ⑴ 이 폭에서는 **이름이 살아 있고** 증감은 내려놓았다.
    const name = findExactText(draws, "a.zig") orelse return error.MissingName;
    try testing.expect(findExactText(draws, "-999999") == null);
    try testing.expect((name.max_width_px orelse 0) > 0);

    // ⑵ 둘 다 들어가는 폭에서는 여전히 겹치지 않는다(사다리가 아무것도 안 버리는 구간).
    var wide_storage: TestStorage = .{};
    const wide_props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 480, .height = 200 },
        .items = &items,
        .branch = "main",
    };
    const wide_frame = try build.build(wide_props, .{
        .nodes = &wide_storage.nodes,
        .entries = &wide_storage.entries,
        .layout_items = &wide_storage.layout_items,
        .flex_scratch = &wide_storage.flex_scratch,
        .child_rects = &wide_storage.child_rects,
        .actions = &wide_storage.actions,
    });
    const wide_draws = try viewBudgeted(&wide_storage, wide_props, wide_frame, .{});
    const wide_name = findExactText(wide_draws, "a.zig") orelse return error.MissingName;
    const removed = findExactText(wide_draws, "-999999") orelse return error.MissingDelta;
    const budget = wide_name.max_width_px orelse return error.MissingBudget;
    try testing.expect(wide_name.origin.x + @as(i32, @intCast(budget)) <= removed.origin.x);
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

// **이름의 끝과 경로 꼬리의 시작이 같은 수에서 나오는가.**
//
// `measureRun` 은 "열 수 × primary face advance" 다. 그런데 measured chrome 경로는 x 를 셀에 스냅하지
// 않고 글자마다 **실제 advance** 로 나아가므로(`system_text` 헤더), 폴백 face 가 더 넓으면 그 예약이
// 모자란다 — 실측으로 이름이 `🔥🔥🔥🔥.zig` 일 때 이모지 advance 가 2 칸 예약(1.2 em)을 넘어
// `.zigsrc/session/` 처럼 붙었다. 예약만큼으로 이름을 자르면 그 상태가 **겹침이 아니라 말줄임**이 된다.
//
// 값으로 재는 이유: 픽셀 골든은 이 조합(이모지 이름)을 담고 있지 않고, 담더라도 폰트 설치에 흔들린다.
test "경로 꼬리는 이름의 예산이 끝나는 자리에서 시작한다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "widename.zig", .dir = "src/session/", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const ops = try renderFixture(&storage, .{}, &items);
    const name = findExactText(ops, "widename.zig") orelse return error.MissingName;
    const dir = findExactText(ops, "src/session/") orelse return error.MissingDir;
    const name_budget = name.max_width_px orelse return error.MissingNameBudget;
    // 꼬리는 이름 예산이 끝난 **뒤**에서 시작한다 — 그래야 이름이 예산을 다 써도 겹칠 자리가 없다.
    try testing.expect(dir.origin.x >= name.origin.x + @as(i32, @intCast(name_budget)));
}

test "동작이 없는 행은 그 자리를 비워 두지 않는다(충돌 행은 이름이 더 길다)" {
    // 충돌 행은 동작이 없다(`git add`가 "해결됨"으로 표시하므로). 그런데도 버튼 자리를 비우면
    // **누를 수 없는 것 때문에 이름이 짧아진다** — 화면이 거짓말을 하는 자리다.
    var a: TestStorage = .{};
    var b: TestStorage = .{};
    // **이름이 길어야 이 계약이 판정된다.** 꼬리가 붙는 행에서 이름 예산은 `min(남은 폭, 이름 예약)`
    // 이라(겹침 방지 — 위 `name_end` 주석), 짧은 이름은 어느 쪽이든 자기 폭이 예산이 되어 두 경우가
    // 같아진다. 이 판정자가 보려는 것은 "**누를 수 없는 것 때문에 이름이 짧아지는가**" 이므로, 남은
    // 폭이 실제로 제약이 되는 길이를 쓴다.
    const long_name = "a_very_long_source_file_name_that_needs_all_the_room.zig";
    const with_action = [_]types.Item{
        .{ .file = .{ .name = long_name, .dir = "src/", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const no_action = [_]types.Item{
        .{ .file = .{ .name = long_name, .dir = "src/", .status = .conflicted, .letter = 'U', .action = .none } },
    };
    const acted = try renderFixture(&a, .{}, &with_action);
    const plain = try renderFixture(&b, .{}, &no_action);
    const wa = (findExactText(acted, long_name) orelse return error.MissingName).max_width_px orelse 0;
    const wb = (findExactText(plain, long_name) orelse return error.MissingName).max_width_px orelse 0;
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

test "스크롤로 밀린 행은 목록 뷰포트 위(탭 줄·요약 줄)로 안 샌다 (사용자 지적 2026-08-21)" {
    // 가상화는 창의 첫 항목을 **음수 origin**으로 올려 두므로 그 행의 rect는 목록 위쪽 띠 아래로
    // 들어간다. 그 rect를 그대로 clip으로 실으면 clip이 뷰포트보다 커져 — 즉 clip이 아무것도 안 자르고 —
    // 행의 칠과 글자가 고정 chrome 위에 그려졌다. clip의 단일 출처는 tree의 `effective_clip`이다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "index.html", .dir = "docs/poc/", .status = .modified, .letter = 'M', .action = .stage } },
        .{ .file = .{ .name = "ask.html", .dir = "docs/poc/", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &items,
        .branch = "main",
        .summary = .{ .added = 41, .removed = 12 },
        // 창의 첫 항목이 8px 잘린 채 시작한다(스크롤 중간 — 가상화가 내는 그 상태다).
        .content_first_item_origin_y_px = -8,
        .content_h_px = 900,
        .scroll_offset_px = 8,
        .list_overflows = true,
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
    const content_index = frame.tree.find(build.NodeIds.content) orelse return error.MissingContent;
    const content = frame.tree.entries[content_index].rect;
    const top: i32 = @intFromFloat(@floor(content.y));
    try testing.expect(top > 0); // 위쪽 고정 chrome(탭 줄·요약 줄)이 실제로 있다
    var saw_scroll_text = false;
    for (draws.ops) |op| switch (op) {
        // 목록 안의 글자는 전부 뷰포트 **아래**에서 시작하는 clip을 들어야 한다.
        .text => |text| if (text.scroll_clipped) {
            const clip = text.clip orelse return error.MissingClip;
            try testing.expect(clip.y >= top);
            saw_scroll_text = true;
        },
        else => {},
    };
    try testing.expect(saw_scroll_text);
}

test "머리 줄: 평소에는 아이콘 자리를 비워 두지 않는다 (사용자 지적 2026-08-19)" {
    // 늘 비워 두면 아이콘은 호버해야 나오므로 평소 화면에는 **이유를 말하지 않는 빈 띠**만 52px 남는다.
    // 그래서 접는 것은 호버하는 동안뿐이고, 평소 프레임은 그 자리를 브랜치·배지가 그대로 쓴다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "feat/x", .primary = true, .count = 11, .can_stage_all = true } },
    };
    const plain = try renderFixture(&storage, .{}, &items);
    const pill = findBadgeQuad(plain) orelse return error.MissingBadge;
    try testing.expect(findExactText(plain, "feat/x") != null); // 브랜치도 평소에는 그린다
    try testing.expect(repoActionIconLeft(plain) == null); // 호버가 아니면 아이콘은 없다
    // 배지가 **행의 오른쪽 여백에 그대로 붙는다** — 아이콘 둘을 위해 미리 비워 둔 띠가 없다는 뜻이다.
    const m = types.DockMetrics.resolve(1000);
    try testing.expectEqual(@as(i32, 320 - @as(i32, @intCast(m.inset_x))), pill.rect.x + @as(i32, @intCast(pill.rect.w)));
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

test "고른 줄은 좌측 강조 막대를 갖는다 — 커밋·턴·파일 모두 (P4c)" {
    // 밴드(`variant = .selected`)만으로는 두 줄짜리 행이 이어지는 목록에서 「조금 밝은 줄」로만 읽힌다.
    // **예산과 함께 고정된다**: `quad_extra` 가 모자라면 `viewBudgeted` 가 아니라 `view` 가 실패해
    // 이 테스트가 깨진다(프레임이 통째로 버려지는 그 상태다).
    // **차이로 센다.** 활성 탭 언더바가 이미 `accent_bar` 라 절대 수는 그 고정 chrome 까지 세고,
    // 그러면 이 테스트는 막대가 아니라 탭 줄을 증언하게 된다(첫 판이 실제로 그랬다 — 0 을 기대했는데 1).
    var storage: TestStorage = .{};
    const unselected = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a" } },
    };
    const baseline = countQuads(try renderFixture(&storage, .{}, &unselected), .accent_bar);

    var storage2: TestStorage = .{};
    const selected = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a", .selected = true } },
    };
    try testing.expectEqual(baseline + 1, countQuads(try renderFixture(&storage2, .{}, &selected), .accent_bar));

    var storage3: TestStorage = .{};
    const file_selected = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a", .expanded = true } },
        .{ .commit_file = .{ .index = 0, .name = "a.zig", .status = .modified, .letter = 'M', .selected = true } },
    };
    try testing.expectEqual(baseline + 1, countQuads(try renderFixture(&storage3, .{}, &file_selected), .accent_bar));

    var storage4: TestStorage = .{};
    const turn_selected = [_]types.Item{
        .{ .turn = .{ .index = 0, .title = "마지막 턴", .selected = true } },
    };
    try testing.expectEqual(baseline + 1, countQuads(try renderFixture(&storage4, .{}, &turn_selected), .accent_bar));
}

test "항목 사이 가로선은 두 줄 행에만 있고 첫 줄에는 없다 (P4c)" {
    // 한 줄짜리 파일 행에까지 줄마다 선을 그으면 목록이 **표**가 된다(사용자 지적 2026-08-14).
    // 첫 줄에 그리면 위 고정 chrome 과 맞닿아 이중선이 된다.
    var storage: TestStorage = .{};
    const first_only = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a" } },
    };
    const before = countQuads(try renderFixture(&storage, .{}, &first_only), .divider);

    var storage2: TestStorage = .{};
    const two = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a" } },
        .{ .commit = .{ .index = 1, .subject = "fix: b" } },
    };
    const after = countQuads(try renderFixture(&storage2, .{}, &two), .divider);
    try testing.expectEqual(before + 1, after); // 둘째 줄에만 하나 늘었다
}

test "펼친 커밋의 파일 줄은 세로 안내선으로 소속을 말한다 (P4c)" {
    // 들여쓰기 하나로는 좁은 도크에서 약해, 사용자 캡처에서 파일 목록이 **목록의 다음 항목**처럼 보였다.
    var storage: TestStorage = .{};
    const without = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a", .expanded = true } },
    };
    const before = countQuads(try renderFixture(&storage, .{}, &without), .divider);

    var storage2: TestStorage = .{};
    const with_file = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: a", .expanded = true } },
        .{ .commit_file = .{ .index = 0, .name = "a.zig", .status = .modified, .letter = 'M' } },
    };
    const after = countQuads(try renderFixture(&storage2, .{}, &with_file), .divider);
    try testing.expectEqual(before + 1, after); // 파일 줄 하나당 안내선 하나
}

test "펼친 커밋의 파일 줄: 증감이 상태 문자 왼쪽에 서고 이름이 그 위로 안 온다 (P4c)" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: something", .expanded = true } },
        .{ .commit_file = .{
            .index = 0,
            .name = "a-rather-long-file-name-that-wants-the-whole-row.zig",
            .status = .modified,
            .letter = 'M',
            .added = 34,
            .removed = 12,
            .has_delta = true,
        } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    const added = findExactText(draws, "+34") orelse return error.MissingAdded;
    const removed = findExactText(draws, "-12") orelse return error.MissingRemoved;
    const name = findExactText(draws, "a-rather-long-file-name-that-wants-the-whole-row.zig") orelse return error.MissingName;

    // 변경 사항 탭과 **같은 순서**다: 왼쪽부터 `+N` `-N` `M`(오른쪽 끝).
    try testing.expect(added.origin.x < removed.origin.x);
    // **이름 예약이 증감 앞에서 끝난다.** 조각을 놓으며 누적한 `u32` 를 이름 끝으로 쓰면 조각마다
    // 버림이 쌓여 이 단언이 깨진다(적대적 검증 2회차에서 그 상태였다).
    const name_right = name.origin.x + @as(i32, @intCast(name.max_width_px.?));
    try testing.expect(name_right <= added.origin.x);
}

test "펼친 커밋의 파일 줄: 좁아지면 증감이 먼저 사라지고 이름이 남는다 (P4c)" {
    // 사다리의 방향이 뒤집히면 도크 하한에서 **이름이 통째로 사라진다** — 파일 행이 2026-08-25 에
    // 겪은 그 결함이고, 이 줄은 같은 격자를 쓴다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: something", .expanded = true } },
        .{ .commit_file = .{ .index = 0, .name = "renderer.zig", .status = .modified, .letter = 'M', .added = 1234, .removed = 5678, .has_delta = true } },
    };
    // 도크 하한(폭 104pt = 도크 120 − 스크롤 거터 16) — 위 파일 행 사다리 테스트와 같은 수다.
    const draws = try renderFixtureBranch(&storage, &items, "main", 104);
    try testing.expect(findExactText(draws, "renderer.zig") != null); // 이름은 끝까지 남는다
    try testing.expect(findExactText(draws, "+1234") == null); // 증감이 먼저 내려간다
}

test "펼친 커밋의 파일 줄: 이진 파일은 0이 아니라 `bin` 이라고 적는다 (P4c)" {
    // `0 -0` 으로 그리면 «안 바뀐 파일» 이라는 거짓 진술이 된다(변경 사항 탭과 같은 규율).
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "feat: art", .expanded = true } },
        .{ .commit_file = .{ .index = 0, .name = "logo.png", .status = .added, .letter = 'A', .binary = true, .has_delta = true } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findExactText(draws, "bin") != null);
    try testing.expect(findExactText(draws, "+0") == null);
    try testing.expect(findExactText(draws, "-0") == null);
}

test "펼친 커밋의 파일 줄: 증감을 못 읽었으면 그 자리를 비운다 (P4c)" {
    // 짝이 어긋난 목록은 `has_delta = false` 로 온다. 그때 0 을 그리면 **읽지 못한 것**과
    // **안 바뀐 것**이 화면에서 같아진다.
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .commit = .{ .index = 0, .subject = "fix: x", .expanded = true } },
        .{ .commit_file = .{ .index = 0, .name = "unknown.zig", .status = .modified, .letter = 'M' } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findExactText(draws, "unknown.zig") != null);
    try testing.expect(findExactText(draws, "+0") == null);
    try testing.expect(findExactText(draws, "-0") == null);
    try testing.expect(findExactText(draws, "bin") == null);
}

test "브랜치 줄: 긴 이름이 오른쪽 묶음(∨·fetch)을 침범하지 않는다 (사용자 지적 2026-08-25)" {
    // 그전에는 이름을 rect **끝까지** 썼는데 그 rect 가 `∨`·fetch 칩까지 품고 있어서, 긴 이름이
    // 그 위로 올라타 둘 다 못 읽었다(제품 캡처: `feat/w8-sidebar-scroll` 이 `∨` 와 붙었다).
    // 파일 행이 같은 실패를 먼저 겪었고 거기서 세운 규칙이 이것이다 — **자기 자리만큼만 쓴다.**
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .repo = .{ .index = 0, .name = "maru", .branch = "main", .primary = true, .count = 1 } },
    };
    const long = "feat/w8-sidebar-scroll-and-then-some-more";
    const draws = try renderFixtureBranch(&storage, &items, long, 220);

    // **브랜치 줄로 한정한다.** `∨` 글리프는 저장소 머리 줄의 접힘 화살표와 **같은 자산**이라,
    // 그냥 찾으면 왼쪽 끝의 그 화살표를 집는다(실측: x=8). 이름이 그려진 **같은 y** 의 것만 본다.
    var name_right: i32 = 0;
    var name_y: i32 = -1;
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (!std.mem.startsWith(u8, run.text, "feat/")) continue;
            const w: i32 = if (text.max_width_px) |mw| @intCast(mw) else 0;
            name_right = @max(name_right, text.origin.x + w);
            name_y = text.origin.y;
        },
        else => {},
    };
    var menu_left: i32 = std.math.maxInt(i32);
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (!std.mem.eql(u8, run.text, chevron_down_icon)) continue;
            if (@abs(text.origin.y - name_y) > 8) continue; // 같은 줄만
            menu_left = @min(menu_left, text.origin.x);
        },
        else => {},
    };
    // **`↑`/`↓` 도 오른쪽 묶음이다.** 처음 고칠 때 `∨`·칩만 보고 이것을 빼먹었고, 제품
    // 화면에서는 `↑` 가 이름 **위에** 겹쳐 둘 다 못 읽었다(제품 캡처 2026-08-25).
    var arrow_left: i32 = std.math.maxInt(i32);
    for (draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (!std.mem.startsWith(u8, run.text, "↑") and !std.mem.startsWith(u8, run.text, "↓")) continue;
            if (@abs(text.origin.y - name_y) > 8) continue;
            arrow_left = @min(arrow_left, text.origin.x);
        },
        else => {},
    };

    try testing.expect(name_right > 0); // 이름이 그려졌다
    try testing.expect(menu_left != std.math.maxInt(i32)); // 그 줄에 `∨` 가 있다
    try testing.expect(arrow_left != std.math.maxInt(i32)); // 그 줄에 `↑`/`↓` 가 있다
    // **이름이 오른쪽 묶음 전부의 왼쪽에서 끝난다.**
    try testing.expect(name_right <= menu_left);
    try testing.expect(name_right <= arrow_left);
}
