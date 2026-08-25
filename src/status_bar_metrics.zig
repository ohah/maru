//! 하단 상태표시줄의 **치수** — pt 상수와 px 환산 한 곳.
//!
//! **왜 최상위 잎인가.** 입력이 `session/layout_math`(스케일 환산)이고 출력이 L3
//! `chrome/components/status_bar.Metrics` 라 어느 계층에도 안 붙는다 — `chrome` 은 `session` import 가
//! 금지이고(`tests/boundary/imports.zig`), 그 컴포넌트 헤더도 *"이 모듈은 스케일을 모른다"* 고 못 박아
//! 뒀다. `chrome_theme.zig`·`scm_items.zig` 와 같은 부류다(layering-and-portability.md §3.4).
//!
//! **왜 옮겼나.** 이 값들이 `platform/macos/app_session.zig` 안에 있어서 Windows 가 볼 수 없었다.
//! 손으로 베끼면 "바 높이" 가 두 곳이 되고, 한쪽만 고칠 때 **같은 창에서 두 OS 의 바 높이가 갈린다** —
//! 그때 틀어지는 것은 바 하나가 아니라 터미널 행 수·도크·사이드바 뷰포트 전부다(그 높이가 작업영역을
//! 깎는다). 규칙의 단일 출처는 [docs/status-bar.md](../docs/status-bar.md) §2 다.

const std = @import("std");
const layout_math = @import("session/layout_math.zig");
const status_bar = @import("chrome/components/status_bar.zig");

/// 폰트 독립 **하한** 높이(논리 pt).
pub const height_pt: u32 = 22;
/// 좌·우 가장자리 안쪽 여백(논리 pt).
pub const edge_pad_pt: u32 = 8;
/// 항목 사이 간격(논리 pt).
pub const gap_pt: u32 = 12;
/// 텍스트 위아래 여백(논리 pt, 한쪽). 바 높이가 이 값으로 텍스트 행에서 파생된다.
pub const v_pad_pt: u32 = 4;
/// **상단 경계선** 두께(논리 pt). 배경 띠 **안쪽 맨 위**에 긋는다 — 선을 더한다고 작업영역이 줄지 않는다.
pub const border_pt: u32 = 1;
/// 호버 배경이 항목 좌우로 넓어지는 여백(논리 pt, 한쪽). **항목 간격보다 두 배 이상 작아야**
/// 이웃 호버끼리 안 겹친다(4×2 < 12).
pub const item_pad_pt: u32 = 4;

/// 바 높이(backing px). **텍스트 행에 여백을 더한 높이와 고정 하한 중 큰 쪽**이다.
///
/// 고정 높이만 쓰면 둘이 깨진다: ⑴ 기본 폰트에서 22px 바에 18px 행이라 위아래 2px 밖에 안 남아 빡빡하고
/// (사용자 지적), ⑵ 폰트를 키워 셀이 바보다 커지면 세로 중앙 계산 `(h -| cell) / 2` 가 0 으로 포화돼
/// **글자가 바 아래(창 밖)로 넘친다.** 텍스트가 터미널 셀 높이를 쓰는 이상 바가 그것을 담아야 한다.
///
/// 그래도 **하한은 폰트 독립**이라 작은 폰트에서 바가 실처럼 얇아지지 않는다 — 도크 뷰 바가 폰트
/// 파생만으로 오르내리던 회귀(실측 53px↔80px)를 피한 이유가 그 하한이다.
///
/// **켜고 끄는 판정은 여기 없다**(`status-bar.show`·quick terminal). 호출자가 0 을 쓰기로 정하는
/// 자리가 플랫폼마다 다르고, 그 게이트를 여기 넣으면 config 를 이 잎이 알아야 한다.
pub fn heightPx(cell_height_px: u32, scale_milli: u32) u32 {
    const floor_px = layout_math.ptToPx(height_pt, scale_milli);
    const text_px = cell_height_px +| (2 *| layout_math.ptToPx(v_pad_pt, scale_milli));
    return @max(floor_px, text_px);
}

/// 바 사각형과 배율에서 컴포넌트가 쓰는 `Metrics` 를 만든다. **여백은 폰트에서 파생하지 않는다** —
/// 창 전폭 chrome 이라 폰트를 키웠을 때 같은 줄이 오르내리면 더 크게 드러난다(§2).
pub fn metricsFor(bar_x: u32, bar_y: u32, bar_w: u32, bar_h: u32, scale_milli: u32) status_bar.Metrics {
    return .{
        .bar_x = bar_x,
        .bar_y = bar_y,
        .bar_w = bar_w,
        .bar_h = bar_h,
        .edge_pad_px = layout_math.ptToPx(edge_pad_pt, scale_milli),
        .gap_px = layout_math.ptToPx(gap_pt, scale_milli),
    };
}

test "높이: 작은 폰트에서는 하한이, 큰 폰트에서는 텍스트가 정한다" {
    const t = std.testing;
    // 셀이 작으면 하한(22)이 이긴다 — 바가 실처럼 얇아지지 않는다.
    try t.expectEqual(@as(u32, 22), heightPx(10, 1000));
    // 셀 + 여백이 하한을 넘으면 그쪽이 이긴다.
    try t.expectEqual(@as(u32, 27), heightPx(19, 1000));
    // **큰 폰트에서 글자가 바 밖으로 안 나간다** — 이것이 고정 높이가 깨지던 자리다.
    const big = heightPx(64, 1000);
    try t.expect(big >= 64);
    try t.expectEqual(@as(u32, 72), big);
}

test "높이: 배율이 둘 다에 걸린다 — 한쪽만 곱하면 Retina 에서 갈린다" {
    const t = std.testing;
    // 2× 에서 하한은 44 px 이고, 셀은 이미 device px 라 그대로 쓰되 여백만 곱한다.
    try t.expectEqual(@as(u32, 44), heightPx(20, 2000));
    // 셀이 커지면 텍스트 쪽이 이긴다: 40 + 2×8 = 56.
    try t.expectEqual(@as(u32, 56), heightPx(40, 2000));
}

test "Metrics: 여백은 배율만 타고 폰트를 안 탄다" {
    const t = std.testing;
    const a = metricsFor(0, 100, 800, 27, 1000);
    try t.expectEqual(@as(u32, 8), a.edge_pad_px);
    try t.expectEqual(@as(u32, 12), a.gap_px);
    try t.expectEqual(@as(u32, 100), a.bar_y);
    const b = metricsFor(0, 200, 1600, 54, 2000);
    try t.expectEqual(@as(u32, 16), b.edge_pad_px);
    try t.expectEqual(@as(u32, 24), b.gap_px);
}
