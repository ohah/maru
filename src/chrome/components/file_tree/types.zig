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
            .label_line_h = typography.lineHeightPx(.list_row, scale),
            .focus_bar_w = @max(spacing.pointsPx(2, scale), 1),
        };
    }

    /// 행 안에서 **라벨이 시작하는 x**(행 rect 기준 로컬). 그리기와 폭 예산이 같은 값을 써야 하므로
    /// 두 곳에서 다시 더하지 않는다.
    pub fn labelLocalX(self: Metrics, depth: u16) u32 {
        return self.contentLocalX(depth) +| self.chevron_extent +| self.chevron_gap +|
            self.icon_extent +| self.icon_gap;
    }

    /// 행 안에서 **chevron이 시작하는 x**(행 rect 기준 로컬).
    pub fn contentLocalX(self: Metrics, depth: u16) u32 {
        return self.row_pad_x +| (self.indent_w *| depth);
    }

    /// 라벨이 쓸 수 있는 폭. 상태 슬롯과 오른쪽 패딩을 뺀 나머지이고, 남지 않으면 0이다.
    pub fn labelWidthPx(self: Metrics, row_w: u32, depth: u16, has_state: bool) u32 {
        const right = self.row_pad_x +| (if (has_state) self.state_slot_w else 0);
        return row_w -| self.labelLocalX(depth) -| right;
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

test "Metrics: 라벨 x 는 depth 마다 한 단씩 밀리고 폭 예산은 상태 슬롯을 뺀다" {
    const m = Metrics.resolve(1000);
    try std.testing.expectEqual(m.labelLocalX(0) + m.indent_w, m.labelLocalX(1));
    const wide = m.labelWidthPx(300, 0, false);
    const with_state = m.labelWidthPx(300, 0, true);
    try std.testing.expectEqual(wide - m.state_slot_w, with_state);
    // 폭이 모자라면 음수로 감기지 않고 0이다(좁힌 도크에서 실제로 온다).
    try std.testing.expectEqual(@as(u32, 0), m.labelWidthPx(10, 4, true));
}
