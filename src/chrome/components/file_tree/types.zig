//! 파일 탐색기 트리 행의 platform 중립 입력 DTO와 기하 메트릭이다.
//!
//! **행 높이가 터미널 셀에서 떨어져 나온 자리가 여기다.** 예전 렌더는 행 하나를 셀 한 줄로 그려서
//! 높이·글자 크기·들여쓰기가 전부 사용자 `font.size`에 묶여 있었다(docs/plans/file-tree-component.md
//! §0). 이 `Metrics`는 logical pt를 backing scale로 한 번만 환산하므로, 터미널 폰트를 바꿔도 트리
//! 밀도가 따라 움직이지 않는다.

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");
const typography = @import("../../ui/typography.zig");

/// 행의 성격. `session/file_tree.zig`의 `Row` union과 1:1이되, 도메인 포인터·경로를 싣지 않는다 —
/// 컴포넌트는 무엇을 그릴지만 알면 되고 무엇을 여는지는 host가 안다.
pub const RowKind = enum { root, directory, file, recent_header, recent_file, empty };

/// **호버는 여기 없다.** 그 판정의 주인은 published tree 를 보는 `InteractionState` 이고(FT2), DTO 로도
/// 받으면 같은 사실의 출처가 둘이 된다. 선택·활성은 도메인이 아는 사실이라 여기 있다.
pub const Row = struct {
    kind: RowKind,
    label: []const u8,
    depth: u16 = 0,
    /// disclosure(chevron)를 그릴 수 있는 행인가. 폴더·root·최근 파일 헤더가 참이다.
    expandable: bool = false,
    expanded: bool = false,
    /// 아직 스캔 중 — chevron 자리에 다른 표시를 낸다.
    loading: bool = false,
    /// 지금 열려 있는 파일. 라벨을 강조한다.
    active: bool = false,
    /// 저장 안 된 변경(●).
    dirty: bool = false,
    /// 외부에서 바뀜(!).
    external_change: bool = false,
    /// git이 무시하는 행. 라벨도 아이콘도 흐려진다 — **모르면 host가 false를 준다**(모르는 것을
    /// 흐리게 그리지 않는다는 규율은 docs/file-explorer.md가 소유한다).
    ignored: bool = false,
    /// `chrome/file_tree_icon.zig`의 `IconKind`를 raw로 싣는다. 분류의 소유자는 그 모듈이고
    /// 컴포넌트는 저장된 값을 옮기기만 한다(렌더가 자기 표를 들면 새 종류를 더할 때 한쪽만 갱신된다).
    icon_kind: u8,
    selected: bool = false,
    /// **도메인 목록에서의 자리.** 창(가상화) 안의 인덱스가 아니다 — intent 가 이 값을 실어야 늦게
    /// 도착한 up 이 스크롤로 밀린 다른 행을 열지 않는다.
    model_index: usize = 0,
};

pub const Props = struct {
    /// 트리 content 사각형의 크기. **스크롤바 gutter를 뺀 폭**을 host가 넘긴다 — gutter는 컨테이너가
    /// 상시 예약하므로 스크롤바 유무로 행이 reflow하지 않는다.
    viewport_px: layout.UiSize,
    /// backing scale × 도크 zoom. 모든 logical pt를 이 값으로 한 번만 환산한다.
    scale_milli: u32 = 1000,
    /// **보이는 창만** 담는다(가상화). 전체 행을 넘기면 수천 개 노드를 만들게 된다.
    rows: []const Row = &.{},
    /// 이 스냅샷의 세대. action 표가 이 값으로 태깅되고, 늦게 도착한 up 은 세대가 다르면 거부된다.
    snapshot_generation: u64 = 0,
    /// 트리가 **키보드 포커스를 갖고 있는가.** 선택 밴드의 세기가 아니라 **accent 표시자**가 이 값에
    /// 달렸다(§선택 표시 — `Metrics.focus_bar_w`).
    selection_focused: bool = true,
    /// 창의 첫 행이 뷰포트 위로 밀려 나간 픽셀. 행 컨테이너를 이만큼 **올려** 부분 행을 만든다.
    /// 위·아래로 삐져나온 몫은 root의 clip이 자른다.
    origin_shift_px: u32 = 0,
};

/// 트리 기하의 단일 출처. 값은 전부 logical pt를 `scale_milli`로 환산한 backing 픽셀이다.
pub const Metrics = struct {
    /// 행 하나의 높이. 사용자 결정(2026-08-22 "컴팩트 모던")이 26pt다 — 아이콘 16pt에 위아래 여백이
    /// 들어가는 최소치이고, 30pt 안은 한 화면 행 수가 약 2/3로 줄어 기각됐다.
    row_h: u32,
    /// depth 한 단의 들여쓰기.
    indent_w: u32,
    /// 밴드(선택·호버)가 컨테이너 좌우 가장자리에서 떨어지는 여백. 목록이 가장자리에 붙어 끝나는
    /// 것이 "허접해 보인다"의 큰 몫이라 안으로 들인다.
    band_inset_x: u32,
    /// 밴드 안쪽에서 내용이 시작하는 여백.
    row_pad_x: u32,
    /// disclosure chevron이 차지하는 정사각 변.
    chevron_extent: u32,
    /// chevron과 아이콘 사이.
    chevron_gap: u32,
    /// 종류 아이콘의 정사각 변.
    icon_extent: u32,
    /// 아이콘과 라벨 사이.
    icon_gap: u32,
    /// 우측 상태 표시(dirty ●·conflict !)가 예약하는 폭.
    state_slot_w: u32,
    /// 밴드 모서리 반경.
    corner_radius: u16,
    /// 들여쓰기 가이드 선의 두께.
    guide_w: u32,
    /// **이름이 반드시 갖는 최소 폭.** 이 값 아래로는 다른 것을 버려서라도 라벨을 지킨다(`rowLayout`).
    ///
    /// pt 로 두는 것이 맞다 — 라벨은 role 이 정한 **고정 14pt** 라 사용자 터미널 폰트와 무관하다.
    /// 80pt 는 14pt 등폭에서 대략 9~10 자다(파일명 앞부분과 확장자 일부가 보이는 최소치).
    label_floor: u32,
    /// 라벨 한 줄의 line box. 세로 중앙 정렬의 기준이다.
    label_line_h: u32,
    /// 포커스된 선택 행 **왼쪽 끝의 accent 막대** 두께.
    ///
    /// 예전 렌더는 포커스된 선택을 **accent로 행 전체를 칠하고** 글자를 테마의 대비색으로 뒤집었다.
    /// 컴포넌트는 색을 값이 아니라 role로 다루는데 이 층에는 "accent 위의 전경" role이 없어서, 그
    /// 방식을 그대로 옮기면 밝은 accent 위에 `surface_fg`가 얹혀 읽히지 않는다. 그래서 **면은 약하게
    /// 두고 포커스를 막대로** 말한다 — 글자 대비를 건드리지 않으면서 포커스가 더 또렷하다.
    focus_bar_w: u32,

    pub fn resolve(scale_milli: u32) Metrics {
        const scale = if (scale_milli == 0) 1000 else scale_milli;
        return .{
            .row_h = spacing.pointsPx(26, scale),
            .indent_w = spacing.pointsPx(14, scale),
            .band_inset_x = spacing.pointsPx(6, scale),
            .row_pad_x = spacing.px(.xs, scale),
            .chevron_extent = spacing.pointsPx(12, scale),
            .chevron_gap = spacing.pointsPx(2, scale),
            .icon_extent = spacing.pointsPx(16, scale),
            .icon_gap = spacing.pointsPx(6, scale),
            .state_slot_w = spacing.pointsPx(14, scale),
            .corner_radius = @intCast(@min(spacing.pointsPx(6, scale), std.math.maxInt(u16))),
            .guide_w = @max(spacing.pointsPx(1, scale), 1),
            .label_floor = spacing.pointsPx(80, scale),
            .label_line_h = typography.lineHeightPx(.list_row, scale),
            .focus_bar_w = @max(spacing.pointsPx(2, scale), 1),
        };
    }

    /// 행 안에서 **라벨이 시작하는 x**(행 rect 기준 로컬). 그리기와 폭 예산이 같은 값을 써야 하므로
    /// 두 곳에서 다시 더하지 않는다.
    /// 라벨이 시작하는 x. **사다리를 거친 값이다** — 좁으면 들여쓰기·chevron 이 먼저 줄어든 뒤의 자리다.
    pub fn labelLocalX(self: Metrics, row_w: u32, depth: u16) u32 {
        return self.rowLayout(row_w, depth, false).label_x;
    }

    /// 행 안에서 **chevron이 시작하는 x**(행 rect 기준 로컬).
    /// 이 폭에서 행이 실제로 쓰는 기하. **"이름은 마지막까지 남는다"** 는 규칙 하나를 값으로 옮긴 것이다.
    ///
    /// 예전에는 들여쓰기가 무한히 자라고 라벨이 그 나머지를 받았다. 그래서 좁은 도크(하한 120pt)에서
    /// depth 4 면 라벨 폭이 0 이 되고, `view` 가 그 자리를 **조용히 건너뛰어 이름이 통째로 사라졌다** —
    /// 즉 가장 먼저 버려야 할 것(들여쓰기·장식)이 아니라 **가장 지켜야 할 것**을 먼저 버리고 있었다.
    ///
    /// 순서는 넓음 → 좁음으로 이렇다: **들여쓰기 → 상태 슬롯 → chevron**. 그 아래는 못 버린다
    /// (좌우 패딩 + 종류 아이콘 + 아이콘 여백) — 아이콘까지 버리면 무엇의 행인지 알 수 없다.
    ///
    /// **결정은 폭만 본다.** 깊이나 dirty 여부로 갈리면 행마다 x 가 달라져 목록이 들쭉날쭉해지고,
    /// 스크롤로 보이는 행이 바뀔 때마다 흔들린다. 그래서 상태 슬롯은 **항상 있다고 치고**(최악) 자리를
    /// 계산하고, 실제로 그릴지는 행이 정한다.
    pub const RowLayout = struct {
        /// 이 폭에서 쓰는 한 단 들여쓰기. 0 이면 트리가 평평해진다(가이드 선도 그리지 않는다).
        indent_w: u32,
        /// 들여쓰기가 자라는 상한. 이보다 깊은 행은 같은 x 를 쓴다.
        indent_depth_cap: u16,
        show_chevron: bool,
        show_state: bool,
        content_x: u32,
        icon_x: u32,
        label_x: u32,
        label_w: u32,
    };

    pub fn rowLayout(self: Metrics, row_w: u32, depth: u16, has_state: bool) RowLayout {
        const chevron_span = self.chevron_extent +| self.chevron_gap;
        const irreducible = self.row_pad_x *| 2 +| self.icon_extent +| self.icon_gap;
        const budget = row_w -| irreducible;

        // 사다리 — 상태 슬롯은 최악(항상 예약)으로 친다(위 주석: 결정은 폭만 본다).
        var show_state = true;
        var show_chevron = true;
        var reserved = chevron_span +| self.state_slot_w;
        if (budget < self.label_floor +| reserved) {
            show_state = false;
            reserved = chevron_span;
        }
        if (budget < self.label_floor +| reserved) {
            show_chevron = false;
            reserved = 0;
        }

        const room = budget -| self.label_floor -| reserved;
        const cap: u16 = if (self.indent_w == 0) 0 else @intCast(@min(room / self.indent_w, @as(u32, std.math.maxInt(u16))));
        const indent_w: u32 = if (cap == 0) 0 else self.indent_w;
        const levels = @min(depth, cap);

        const content_x = self.row_pad_x +| (indent_w *| levels);
        const icon_x = content_x +| (if (show_chevron) chevron_span else 0);
        const label_x = icon_x +| self.icon_extent +| self.icon_gap;
        const right = self.row_pad_x +| (if (show_state and has_state) self.state_slot_w else 0);
        return .{
            .indent_w = indent_w,
            .indent_depth_cap = cap,
            .show_chevron = show_chevron,
            .show_state = show_state,
            .content_x = content_x,
            .icon_x = icon_x,
            .label_x = label_x,
            .label_w = row_w -| label_x -| right,
        };
    }

    /// 라벨이 쓸 수 있는 폭. **사다리가 정한다** — 좁으면 다른 것이 먼저 줄어든 뒤의 나머지다.
    pub fn labelWidthPx(self: Metrics, row_w: u32, depth: u16, has_state: bool) u32 {
        return self.rowLayout(row_w, depth, has_state).label_w;
    }
};

test "Metrics: 26pt 행이 아이콘 16pt와 라벨 line box를 모두 담는다" {
    const m = Metrics.resolve(1000);
    try std.testing.expectEqual(@as(u32, 26), m.row_h);
    try std.testing.expectEqual(@as(u32, 16), m.icon_extent);
    // 아이콘과 라벨 둘 다 행 안에 들어가야 세로 중앙 정렬이 잘리지 않는다.
    try std.testing.expect(m.icon_extent <= m.row_h);
    try std.testing.expect(m.label_line_h <= m.row_h);
}

test "Metrics: backing scale 은 한 번만 곱해진다" {
    const one = Metrics.resolve(1000);
    const two = Metrics.resolve(2000);
    try std.testing.expectEqual(one.row_h * 2, two.row_h);
    try std.testing.expectEqual(one.indent_w * 2, two.indent_w);
    try std.testing.expectEqual(one.icon_extent * 2, two.icon_extent);
    // scale 0은 pre-render 스냅샷에서 실제로 온다 — 1×로 떨어져야 하고 0으로 나뉘면 안 된다.
    try std.testing.expectEqual(one.row_h, Metrics.resolve(0).row_h);
}

// **"이름은 마지막까지 남는다"** — 사다리가 실제로 그 순서를 지키는가.
//
// 예전에는 들여쓰기가 무한히 자라 좁은 도크(하한 120pt)의 depth 4 행에서 라벨 폭이 0 이 됐고, `view` 가
// 그 자리를 조용히 건너뛰어 **이름이 통째로 사라졌다**(Lab 캡처로 확인). 즉 가장 지켜야 할 것을 가장
// 먼저 버리고 있었다. 이 판정자는 그 순서를 값으로 고정한다.
test "Metrics: 좁아지면 들여쓰기·상태·chevron 순으로 버리고 이름은 남긴다" {
    const m = Metrics.resolve(1000);

    // ⑴ 넓으면 아무것도 안 버린다.
    const wide = m.rowLayout(400, 3, true);
    try std.testing.expect(wide.show_chevron and wide.show_state);
    try std.testing.expectEqual(m.indent_w, wide.indent_w);
    try std.testing.expect(wide.indent_depth_cap >= 3);

    // ⑵ 도크 하한(120pt)에서도 **어느 깊이든** 이름이 바닥 이상을 받는다.
    for ([_]u16{ 0, 4, 8, 20 }) |depth| {
        const narrow = m.rowLayout(120, depth, true);
        try std.testing.expect(narrow.label_w >= m.label_floor);
    }

    // ⑶ 버리는 **순서**: 들여쓰기가 먼저 0 이 되고, 그 다음 상태 슬롯, 마지막이 chevron 이다.
    var width: u32 = 400;
    var indent_zero_at: u32 = 0;
    var state_off_at: u32 = 0;
    var chevron_off_at: u32 = 0;
    while (width > 40) : (width -= 1) {
        const l = m.rowLayout(width, 8, true);
        if (indent_zero_at == 0 and l.indent_w == 0) indent_zero_at = width;
        if (state_off_at == 0 and !l.show_state) state_off_at = width;
        if (chevron_off_at == 0 and !l.show_chevron) chevron_off_at = width;
    }
    try std.testing.expect(indent_zero_at > state_off_at); // 들여쓰기가 먼저 사라진다
    try std.testing.expect(state_off_at > chevron_off_at); // 그 다음이 상태 슬롯

    // ⑷ 못 버리는 것: 아이콘과 좌우 패딩은 어느 폭에서도 자리를 지킨다.
    const tiny = m.rowLayout(60, 5, true);
    try std.testing.expectEqual(m.row_pad_x, tiny.content_x);
    try std.testing.expectEqual(m.row_pad_x +| m.icon_extent +| m.icon_gap, tiny.label_x);
}

test "Metrics: 라벨 x 는 depth 마다 한 단씩 밀리고 폭 예산은 상태 슬롯을 뺀다" {
    const m = Metrics.resolve(1000);
    // 넓은 폭에서는 사다리가 아무것도 버리지 않으므로 depth 한 단이 그대로 들여쓰기 한 단이다.
    try std.testing.expectEqual(m.labelLocalX(400, 0) + m.indent_w, m.labelLocalX(400, 1));
    const wide = m.labelWidthPx(300, 0, false);
    const with_state = m.labelWidthPx(300, 0, true);
    try std.testing.expectEqual(wide - m.state_slot_w, with_state);
    // 폭이 모자라면 음수로 감기지 않고 0이다(좁힌 도크에서 실제로 온다).
    try std.testing.expectEqual(@as(u32, 0), m.labelWidthPx(10, 4, true));
}
