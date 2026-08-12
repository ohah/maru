//! 편집기 **세로 스크롤바** — §4.1a
//! ([native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md)).
//!
//! **기하는 `ui/scroll_area.zig`를 재활용한다**(§2 레이어 표가 그렇게 정했다). 여기 있는 것은 편집기
//! 고유 규칙 둘뿐이다:
//!
//! 1. **범위가 시각 행 기준이다.** 논리 줄 수를 쓰면 랩된 문서에서 thumb 크기가 실제와 어긋난다 —
//!    한 줄이 화면 열 개를 덮어도 논리 줄로는 하나이므로 막대가 실제보다 길어 보인다.
//! 2. **셀 격자가 아니라 픽셀이다.** gutter는 폰트를 키우면 함께 커지지만(§4.1) 스크롤바는 사이드바·
//!    도크의 것과 같아 보여야 하므로 편집기 폰트와 무관하다.
//!
//! **track은 그리지 않는다.** 배경과 거의 같은 색이라 화면에 보태는 것이 없고, VSCode도 기본
//! 테마에서 track이 사실상 보이지 않는다. 잡는 자리(`hit_x`/`hit_w`)는 기하가 여전히 돌려주므로
//! 드래그를 붙일 때 track 없이도 성립한다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const scroll_area = @import("../../ui/scroll_area.zig");

const draw = chrome.draw;
const tokens = chrome.tokens;

/// thumb 색과 불투명도. **밝은 색을 흐리게** 얹는다 — VSCode 다크 테마의 스크롤바가 같은 방식이고
/// (`#79797966`), 어두운 색을 그대로 쓰면 배경과 구분되지 않는다(`divider`로 그렸더니 배경 20 위에
/// 35라 캡처에서 거의 보이지 않았다).
pub const thumb_role: tokens.ColorRole = .muted_fg;
pub const thumb_alpha: u8 = 0x66;

pub const Props = struct {
    /// 본문 영역의 픽셀 사각. **스크롤바는 이 오른쪽 gutter 안에 선다**(본문 위에 겹치지 않는다).
    content: scroll_area.ContentRect,
    /// 문서 전체의 **시각 행** 수(`visual_map.RowIndex.totalRows`).
    total_visual_rows: u32,
    /// 맨 위에 보이는 시각 행.
    first_visual_row: u32,
    cell_h_px: u16,
    metrics: scroll_area.ScrollbarMetrics,
};

pub const Written = struct {
    ops: usize,
    /// 그린 막대의 기하. 드래그·클릭을 붙일 때 호출자가 쓴다(`offsetForPointer`). 스크롤이 필요
    /// 없으면 `null`이고, 그때는 op도 0이다.
    geometry: ?scroll_area.ScrollbarGeometry = null,
};

/// 스크롤바 draw op을 채우고 쓴 양을 돌려준다. **할당하지 않는다.**
///
/// 문서가 화면에 다 들어가면 아무것도 그리지 않는다(`scrollbarGeometry`가 `null`을 준다) — 스크롤할
/// 것이 없는데 막대를 두면 사용자가 더 있는 줄 안다.
pub fn build(props: Props, out: []draw.Op) Written {
    const content_h_px = std.math.mul(u32, props.total_visual_rows, props.cell_h_px) catch
        std.math.maxInt(u32);
    const offset_px = std.math.mul(u32, props.first_visual_row, props.cell_h_px) catch
        std.math.maxInt(u32);

    const bar = scroll_area.scrollbarGeometry(
        props.content,
        content_h_px,
        offset_px,
        props.metrics,
    ) orelse return .{ .ops = 0 };

    if (out.len == 0) return .{ .ops = 0, .geometry = bar };

    // **`fill`이 아니라 `quad`다.** `fill`은 셀 격자로 내려가는데(`metal_lowering.paintRectBg`)
    // 스크롤바는 §4.1a대로 **격자 밖**(본문 오른쪽 gutter)에 서므로 열 인덱스가 범위를 벗어나
    // **조용히 버려진다** — 실제로 그 상태로 캡처가 나왔고 픽셀이 하나도 없었다. `quad`는 GPU로
    // 직접 내려가 격자와 무관하다(둥근 모서리·헤어라인이 같은 이유로 이 길을 쓴다).
    out[0] = .{
        .quad = .{
            .rect = .{
                .x = @intFromFloat(@round(bar.track_x)),
                .y = @intFromFloat(@round(bar.thumb_y)),
                .w = @intFromFloat(@round(bar.track_w)),
                .h = @intFromFloat(@round(bar.thumb_h)),
            },
            .fill_role = thumb_role,
            .alpha = thumb_alpha,
            // 막대 끝을 둥글린다 — 도크·사이드바 스크롤바와 같아 보여야 한다(§2).
            .corner_radii = .{ 4, 4, 4, 4 },
        },
    };
    return .{ .ops = 1, .geometry = bar };
}

const testing = std.testing;

fn testProps(total: u32, first: u32) Props {
    return .{
        .content = .{ .x = 0, .y = 0, .w = 400, .h = 160, .gutter_w = 12 },
        .total_visual_rows = total,
        .first_visual_row = first,
        .cell_h_px = 16,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };
}

test "문서가 화면에 다 들어가면 그리지 않는다" {
    var ops: [4]draw.Op = undefined;
    // 화면 160px = 10행. 문서가 10행 이하면 스크롤할 것이 없다.
    try testing.expectEqual(@as(usize, 0), build(testProps(10, 0), &ops).ops);
    try testing.expectEqual(@as(usize, 0), build(testProps(3, 0), &ops).ops);
    try testing.expect(build(testProps(10, 0), &ops).geometry == null);
}

test "넘치면 thumb을 그리고 길이가 비율을 따른다" {
    var ops: [4]draw.Op = undefined;
    const w = build(testProps(20, 0), &ops); // 20행 중 10행이 보인다 → 절반
    try testing.expectEqual(@as(usize, 1), w.ops);
    const bar = w.geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 80), bar.thumb_h, 1); // 160 × (10/20)
    try testing.expectApproxEqAbs(@as(f32, 0), bar.thumb_y, 1); // 맨 위
}

test "스크롤하면 thumb이 비례해서 내려간다" {
    var ops: [4]draw.Op = undefined;
    const top = build(testProps(20, 0), &ops).geometry.?;
    const mid = build(testProps(20, 5), &ops).geometry.?;
    const bottom = build(testProps(20, 10), &ops).geometry.?;

    try testing.expect(mid.thumb_y > top.thumb_y);
    try testing.expect(bottom.thumb_y > mid.thumb_y);
    // 맨 아래에서는 thumb 바닥이 track 바닥에 닿는다.
    try testing.expectApproxEqAbs(bottom.track_h, bottom.thumb_y + bottom.thumb_h, 1);
}

test "범위는 시각 행이다 — 랩된 문서에서 논리 줄로 세면 막대가 길어진다" {
    // 논리 줄 10개짜리 문서가 랩으로 시각 행 40개가 됐다고 하자.
    var ops: [4]draw.Op = undefined;
    const wrapped = build(testProps(40, 0), &ops).geometry.?;
    const logical = build(testProps(10, 0), &ops); // 논리 줄로 셌다면

    // 시각 행으로 세면 thumb이 1/4이고, 논리 줄로 세면 **아예 안 그려진다**(10행 = 화면 높이).
    try testing.expectApproxEqAbs(@as(f32, 40), wrapped.thumb_h, 1);
    try testing.expectEqual(@as(usize, 0), logical.ops);
}

test "thumb이 최소 길이보다 짧아지지 않는다 — 집을 수 없는 막대는 affordance가 아니다" {
    var ops: [4]draw.Op = undefined;
    // 10만 행이면 비례 계산으로는 0.016px다.
    const bar = build(testProps(100_000, 0), &ops).geometry.?;
    try testing.expectApproxEqAbs(@as(f32, 24), bar.thumb_h, 0.01); // min_thumb_px
}

test "행 수 × 셀 높이가 u32를 넘어도 죽지 않는다" {
    var ops: [4]draw.Op = undefined;
    // u32max 행 × 16px는 u32를 한참 넘는다 — 곱셈을 그대로 하면 오버플로로 죽는다.
    const w = build(testProps(std.math.maxInt(u32), 0), &ops);
    try testing.expectEqual(@as(usize, 1), w.ops);
    try testing.expect(w.geometry != null);
}

test "op 저장소가 없어도 기하는 돌려준다 — 호출자가 잡는 자리를 알 수 있다" {
    var none: [0]draw.Op = undefined;
    const w = build(testProps(20, 0), &none);
    try testing.expectEqual(@as(usize, 0), w.ops);
    try testing.expect(w.geometry != null);
}
