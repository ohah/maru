//! 이미지 갤러리 **격자 배치** 계산 — 계약 [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §2.
//!
//! 순수 계산이다. 픽셀도 텍스처도 모르고, 사각형만 돌려준다 — 그래야 「어느 칸이 어디인가」를 화면 없이
//! 시험할 수 있고, **그린 자리와 눌리는 자리가 갈라지지 않는다**(도크 뷰 바가 같은 이유로 chrome 에
//! 기하를 두는 것과 같은 규율).
//!
//! 스크롤은 아직 없다 — **보이는 행만** 계산한다. 넘치는 것은 `overflow` 로 밝힌다(「없다」와 「안 보인다」는
//! 다른 사실이다).

const std = @import("std");

/// 도크 안 격자의 여백과 간격(backing px). 값 자체는 디자인이 정할 일이라 호출자가 넘긴다.
pub const Metrics = struct {
    /// 타일 **최소 가로**. 이 값이 **열 수를 정하고**, 실제로 그리는 폭은 `Layout.tile_w` 다(남는 폭을
    /// 열에 나눠 주므로 늘 이 값 이상이다).
    ///
    /// 썸네일 픽셀(160)과 **다를 수 있다** — 화면 크기는 레이아웃이, 텍스처 크기는 디코드가 정한다.
    tile: u32,
    /// 타일 **세로**. 0 이면 정사각(`tile`).
    ///
    /// **정사각이 기본이 아닌 이유는 실측이다**(2026-08-30, 실제 트랜스크립트 600장): 에이전트가
    /// 다루는 이미지는 가로/세로 비율 **중앙 2.00**, 79% 가 가로로 길고 36% 는 비율 3 이상이다.
    /// 정사각 타일은 그 절반 이상을 여백으로 버리고, 같은 도크 높이에 들어가는 칸 수도 절반이 된다.
    tile_h: u32 = 0,
    /// 타일 사이 간격.
    gap: u32 = 8,
    /// 격자 바깥 여백.
    pad: u32 = 8,
    /// 타일 **아래** 라벨 한 줄의 높이. 0 이면 라벨이 없다(그때는 예전 배치와 byte-identical 이다).
    ///
    /// 칸 높이에 포함된다 — 라벨을 칸 밖에 그리면 다음 행 그림 위에 글자가 얹힌다.
    label: u32 = 0,
};

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// 타일 세로. `tile_h` 가 0 이면 정사각이다 — 이 파생을 한 곳에 두어 배치·hit-test·라벨이 갈리지 않게 한다.
pub fn tileHeight(m: Metrics) u32 {
    return if (m.tile_h > 0) m.tile_h else m.tile;
}

pub const Layout = struct {
    /// 한 행에 몇 칸인가. 0 이면 폭이 모자라 하나도 못 그린다.
    cols: u32,
    /// 화면에 자리를 얻은 **첫 칸의 절대 인덱스**(스크롤이 정한다).
    first: usize = 0,
    /// 그 뒤로 몇 칸이 보이는가.
    visible: usize,
    /// 지금 화면 밖에 있는 칸 수(위아래 합). **「이미지가 없다」와 「화면에 안 들어간다」를 가른다.**
    overflow: usize,
    /// 세로로 더 내려갈 수 있는 최대 오프셋(px). 0 이면 스크롤할 것이 없다.
    max_scroll: u32 = 0,
    /// 이 배치가 반영한 스크롤 오프셋(px). `rectAt` 이 y 에서 뺀다 — 배치와 그리기가 **같은 값**을
    /// 쓰게 묶어 둔다(따로 넘기면 한쪽만 갱신된 프레임이 생긴다).
    scroll_px: u32 = 0,
    /// **실제로 그리는** 칸 크기. `Metrics.tile` 은 최소치일 뿐이고, 남는 폭을 열에 나눠 여기서 늘린다 —
    /// 그래야 2열일 때 좌우가 꽉 찬다.
    ///
    /// 배치·라벨·hit-test 가 **모두 이 값**을 쓴다. 한 곳이라도 `Metrics.tile` 로 남으면 그린 자리와
    /// 눌리는 자리가 갈라진다.
    tile_w: u32 = 0,
    tile_h: u32 = 0,
};

/// 남는 폭을 열에 나눠 실제 칸 크기를 정한다. 세로는 최소치의 비율을 그대로 따른다.
fn resolveTile(m: Metrics, inner_w: u32, cols: u32) struct { w: u32, h: u32 } {
    if (cols == 0) return .{ .w = m.tile, .h = tileHeight(m) };
    // 간격은 열 사이에만 들어간다(첫 칸 앞·마지막 칸 뒤는 `pad` 가 맡는다).
    const gaps = m.gap *| (cols -| 1);
    const w = (inner_w -| gaps) / cols;
    if (w <= m.tile) return .{ .w = m.tile, .h = tileHeight(m) }; // 늘릴 폭이 없다
    const base_h = tileHeight(m);
    // 비율 유지. u64 로 올려 곱셈이 넘치지 않게 한다.
    const h: u32 = @intCast(@min(
        @as(u64, std.math.maxInt(u32)),
        (@as(u64, w) *| @as(u64, base_h)) / @max(@as(u64, 1), @as(u64, m.tile)),
    ));
    return .{ .w = w, .h = @max(1, h) };
}

/// 격자 배치. `scroll_px` 만큼 내려간 상태에서 **보이는 창**을 센다. 사각형은 `rectAt` 이 준다.
///
/// 스크롤은 계약 §2 의 「가상 스크롤」이다. 없으면 실제 세션(실측 151 장)에서 **2.6%**만 닿을 수
/// 있었다 — 기능이 성립하지 않는 수준이다.
pub fn layout(area: Rect, m: Metrics, count: usize, scroll_px: u32) Layout {
    if (m.tile == 0 or count == 0) return .{ .cols = 0, .visible = 0, .overflow = count };
    // 여백을 빼고 남는 폭·높이. `-|` 로 음수 대신 0 이 되게 한다 — 좁은 도크에서 언더플로가 나면
    // 열 수가 거대해져 화면 밖에 칸을 그린다.
    const inner_w = area.w -| (m.pad *| 2);
    const inner_h = area.h -| (m.pad *| 2);
    if (inner_w < m.tile or inner_h < tileHeight(m)) return .{ .cols = 0, .visible = 0, .overflow = count };

    // 첫 칸은 간격 없이 들어가고 그 다음부터 (간격 + 타일)씩 먹는다.
    // **세로는 라벨까지가 한 칸이다** — 라벨 높이를 빼먹으면 마지막 행 글자가 도크 밖으로 나간다.
    const cell_h = tileHeight(m) +| m.label;
    if (inner_h < cell_h) return .{ .cols = 0, .visible = 0, .overflow = count };
    const cols = 1 + (inner_w - m.tile) / (m.tile +| m.gap);

    // **여기서 늘린다.** 열 수를 정한 뒤라야 한 칸이 얼마를 더 가져갈 수 있는지 알 수 있다.
    var tile = resolveTile(m, inner_w, cols);
    // 늘린 세로가 도크 높이를 넘으면 거기까지만 — 안 그러면 한 행도 못 그려 「없다」처럼 보인다.
    // 그림 자체는 `fitInside` 가 비율을 지키므로 칸이 조금 납작해지는 것은 해롭지 않다.
    if (tile.h +| m.label > inner_h) tile.h = inner_h -| m.label;
    if (tile.h == 0) return .{ .cols = 0, .visible = 0, .overflow = count };

    const cell_h2 = tile.h +| m.label;
    const step_y = cell_h2 +| m.gap;
    const rows_in_view = 1 + (inner_h - cell_h2) / step_y;
    const total_rows = (count + cols - 1) / cols;

    // **스크롤은 행 단위로 스냅한다.** `Rect.y` 가 `u32` 라 음수를 표현할 수 없어서, 반쯤 걸친 행을
    // 허용하면 그 행이 «위로 -42» 대신 **0 으로 포화**되어 도크 밖(탭 바 위)에 그려진다. 실제로
    // 그렇게 냈다가 test 가 잡았다. 행 단위로 끊으면 그 표현 불가능이 사라지고, 잘라 그릴 수 없는
    // 글자(라벨) 문제도 함께 없어진다 — 썸네일 격자에서는 흔한 동작이기도 하다.
    const scrollable_rows: u32 = @intCast(@min(
        @as(u64, std.math.maxInt(u32)),
        @as(u64, total_rows) -| @as(u64, rows_in_view),
    ));
    const max_scroll = scrollable_rows *| step_y;
    const first_row: u32 = @min(scroll_px, max_scroll) / step_y;
    const scroll = first_row *| step_y;

    const first = @as(usize, first_row) *| @as(usize, cols);
    if (first >= count) return .{ .cols = cols, .first = count, .visible = 0, .overflow = count, .max_scroll = max_scroll, .scroll_px = scroll, .tile_w = tile.w, .tile_h = tile.h };
    const capacity = @as(usize, rows_in_view) *| @as(usize, cols);
    const visible = @min(count - first, capacity);
    return .{
        .cols = cols,
        .first = first,
        .visible = visible,
        .overflow = count - visible,
        .max_scroll = max_scroll,
        .scroll_px = scroll,
        .tile_w = tile.w,
        .tile_h = tile.h,
    };
}

/// `n` 번째(**절대 인덱스**) 칸의 사각형. 보이는 창 밖이면 `null` — 화면 밖에 그리지 않는다.
pub fn rectAt(area: Rect, m: Metrics, l: Layout, n: usize) ?Rect {
    if (l.cols == 0 or n < l.first or n >= l.first + l.visible) return null;
    const step = l.tile_w +| m.gap;
    const step_y = l.tile_h +| m.label +| m.gap;
    const col: u32 = @intCast(n % l.cols);
    const row: u32 = @intCast(n / l.cols);
    const top = area.y +| m.pad +| row *| step_y;
    // 스크롤만큼 올린다. `layout` 이 행 단위로 스냅해 두므로 이 뺄셈은 **절대 음수가 되지 않는다**
    // (`first` 행의 top 이 정확히 `scroll_px` 만큼 앞서 있다).
    return .{
        .x = area.x +| m.pad +| col *| step,
        .y = top -| l.scroll_px,
        .w = l.tile_w,
        .h = l.tile_h,
    };
}

/// `n` 번째 칸의 **라벨** 자리. 라벨 높이가 0 이면 `null` — 그릴 자리가 없다는 뜻이다.
///
/// `rectAt` 에서 파생한다(hitTest 와 같은 규율) — 좌표를 따로 풀면 글자가 그림에서 밀린다.
pub fn labelRectAt(area: Rect, m: Metrics, l: Layout, n: usize) ?Rect {
    if (m.label == 0) return null;
    const tile = rectAt(area, m, l, n) orelse return null;
    const y = tile.y +| tile.h;
    // 행 단위 스냅 덕에 여기 걸리는 경우는 없다. 그래도 남겨 둔다 — 스냅을 나중에 풀면 이 한 줄이
    // 글자가 도크 밖으로 삐져나가는 것을 막는 마지막 방어선이다(글자는 잘라 그릴 수 없다).
    if (y < area.y or y +| m.label > area.y +| area.h) return null;
    return .{ .x = tile.x, .y = y, .w = tile.w, .h = m.label };
}

/// `n` 번째 칸이 보이도록 만드는 스크롤 오프셋. 이미 보이면 **지금 값을 그대로** 돌려준다 —
/// 보이는데도 움직이면 사용자가 보던 자리가 이유 없이 흔들린다.
///
/// 크게 보기에서 ←→ 로 넘길 때 쓴다. 그것이 없으면 넘기다 닫았을 때 격자가 **옛 자리**를 보여주고,
/// 방금 보던 이미지가 화면 밖에 있다.
pub fn scrollToShow(area: Rect, m: Metrics, count: usize, scroll_px: u32, n: usize) u32 {
    const l = layout(area, m, count, scroll_px);
    if (l.cols == 0) return scroll_px;
    if (n >= l.first and n < l.first + l.visible) return l.scroll_px; // 이미 보인다
    const step_y = l.tile_h +| m.label +| m.gap;
    const row: u32 = @intCast(n / l.cols);
    if (n < l.first) {
        // 위로 간다 — 그 행이 첫 행이 되게.
        return @min(row *| step_y, l.max_scroll);
    }
    // 아래로 간다 — 그 행이 **마지막** 보이는 행이 되게(한 행만 겨우 넘어갔을 때 덜 움직인다).
    const rows_in_view = @max(1, l.visible / @max(1, @as(usize, l.cols)));
    const first_row = row -| @as(u32, @intCast(rows_in_view -| 1));
    return @min(first_row *| step_y, l.max_scroll);
}

/// `(px, py)` 위에 있는 칸. 없으면 `null` — 간격·여백을 누르면 아무 일도 없다.
///
/// **`rectAt` 에서 파생한다.** 좌표를 여기서 따로 풀면 배치를 바꿀 때 그린 자리와 눌리는 자리가
/// 갈라지고, 그때 사용자에게는 「엉뚱한 이미지가 열린다」로 보인다 — 화면 없이는 못 잡는 종류의 버그다.
pub fn hitTest(area: Rect, m: Metrics, l: Layout, px: u32, py: u32) ?usize {
    if (l.cols == 0 or l.visible == 0) return null;
    const step = l.tile_w +| m.gap;
    const step_y = l.tile_h +| m.label +| m.gap;
    if (step == 0 or step_y == 0) return null;
    const ox = area.x +| m.pad;
    const oy = area.y +| m.pad;
    if (px < ox) return null;
    const col = (px - ox) / step;
    if (col >= l.cols) return null;
    // **스크롤을 되더한다** — 그리기가 뺀 값을 여기서 도로 넣지 않으면 누른 자리와 열리는 것이
    // 스크롤한 만큼 어긋난다(깊이 내릴수록 크게 어긋나 재현이 헷갈린다).
    //
    // 더하는 쪽으로 계산한다. 원점에서 빼면 `u32` 포화로 스크롤이 여백보다 클 때 0 으로 눌리고,
    // 그 순간 행 계산이 통째로 틀어진다 — 실제로 그렇게 냈다가 test 가 `expected 44, found null`
    // 로 잡았다.
    const abs_y = @as(u64, py) +| @as(u64, l.scroll_px);
    if (abs_y < oy) return null;
    const row: u64 = (abs_y - oy) / step_y;
    const n = @as(usize, @intCast(@min(row, @as(u64, std.math.maxInt(u32))))) *| @as(usize, l.cols) +| @as(usize, col);
    // 후보를 **그리는 함수에 되물어** 확인한다 — 간격에 떨어진 점은 여기서 걸러진다.
    // **라벨도 그 칸이다**: 그림 아래 글자를 눌렀는데 아무 일이 없으면 어디를 눌러야 하는지 알 수 없다.
    const r = rectAt(area, m, l, n) orelse return null;
    if (px < r.x or py < r.y or px >= r.x +| r.w) return null;
    if (py >= r.y +| r.h +| m.label) return null;
    return n;
}

/// 원본 비율을 지키며 타일 안에 넣는 사각형(letterbox). 타일을 꽉 채우지 않고 **가운데 정렬**한다 —
/// 늘리면 스크린샷의 글자가 찌그러지고, 자르면 무엇이 찍혔는지 못 알아본다.
pub fn fitInside(tile: Rect, w: u32, h: u32) Rect {
    if (w == 0 or h == 0 or tile.w == 0 or tile.h == 0) return tile;
    // 정수 비교로 어느 축이 먼저 닿는지 고른다(부동소수 없이).
    const by_width = @as(u64, w) * @as(u64, tile.h) >= @as(u64, h) * @as(u64, tile.w);
    var out_w: u32 = tile.w;
    var out_h: u32 = tile.h;
    if (by_width) {
        out_h = @intCast(@max(1, @as(u64, tile.w) * @as(u64, h) / @as(u64, w)));
        if (out_h > tile.h) out_h = tile.h;
    } else {
        out_w = @intCast(@max(1, @as(u64, tile.h) * @as(u64, w) / @as(u64, h)));
        if (out_w > tile.w) out_w = tile.w;
    }
    return .{
        .x = tile.x + (tile.w - out_w) / 2,
        .y = tile.y + (tile.h - out_h) / 2,
        .w = out_w,
        .h = out_h,
    };
}

// ── 테스트 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const area_400x300 = Rect{ .x = 100, .y = 50, .w = 400, .h = 300 };
const m80 = Metrics{ .tile = 80, .gap = 8, .pad = 8 };

test "열·행 수는 여백과 간격을 뺀 자리에서 나온다" {
    // **열 수는 최소 폭이 정한다**: inner = 400-16 = 384, 최소 step = 88 → 1 + (384-80)/88 = 4열.
    // 그 다음 남는 폭을 나눠 칸을 늘린다: (384 - 간격 24)/4 = 90. 세로도 비율을 따라 90 이 된다.
    // inner_h = 284, step_y = 98 → 1 + (284-90)/98 = 2행 → 8칸.
    const l = layout(area_400x300, m80, 100, 0);
    try testing.expectEqual(@as(u32, 4), l.cols);
    try testing.expectEqual(@as(u32, 90), l.tile_w);
    try testing.expectEqual(@as(usize, 8), l.visible);
    try testing.expectEqual(@as(usize, 92), l.overflow);
}

test "칸을 늘려 한 행이 폭을 꽉 채운다 — 오른쪽에 띠가 남지 않는다" {
    // 사용자 요청: 2열이면 좌우가 꽉 차야 한다. 늘리기 전에는 열 수를 정하고 **남은 폭이 통째로**
    // 오른쪽 여백이 됐다(2열 도크에서 눈에 띄는 띠였다).
    //
    // 여러 폭에서 「마지막 칸의 오른쪽 끝 = 영역 오른쪽 - pad」를 요구한다. 나눗셈 나머지(열 수보다
    // 작다)만 허용한다 — 그 이상 남으면 나누지 않았다는 뜻이다.
    for ([_]u32{ 200, 260, 333, 400, 640, 901 }) |w| {
        const area = Rect{ .x = 0, .y = 0, .w = w, .h = 400 };
        const m = Metrics{ .tile = 80, .tile_h = 40, .gap = 8, .pad = 8, .label = 16 };
        const l = layout(area, m, 40, 0);
        if (l.cols == 0) continue;
        const last_in_row = @min(l.cols - 1, l.visible - 1);
        const r = rectAt(area, m, l, last_in_row).?;
        const right_edge = area.x + area.w - m.pad;
        try testing.expect(r.x + r.w <= right_edge);
        try testing.expect(right_edge - (r.x + r.w) < l.cols); // 남는 것은 나머지뿐
        try testing.expect(l.tile_w >= m.tile); // 줄이지는 않는다
    }
}

test "칸이 자리보다 적으면 넘치는 것이 없다" {
    const l = layout(area_400x300, m80, 5, 0);
    try testing.expectEqual(@as(usize, 5), l.visible);
    try testing.expectEqual(@as(usize, 0), l.overflow);
}

test "폭이 모자라면 하나도 안 그린다 — 반쪽 칸을 만들지 않는다" {
    const narrow = Rect{ .x = 0, .y = 0, .w = 90, .h = 300 }; // inner 74 < tile 80
    const l = layout(narrow, m80, 10, 0);
    try testing.expectEqual(@as(u32, 0), l.cols);
    try testing.expectEqual(@as(usize, 0), l.visible);
    // **「없다」가 아니라 「안 보인다」다.** 이 구분이 없으면 좁은 도크에서 「이미지가 없습니다」로 거짓말한다.
    try testing.expectEqual(@as(usize, 10), l.overflow);
}

test "언더플로가 열 수를 폭주시키지 않는다 — 여백이 폭보다 큰 경우" {
    const tiny = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    const l = layout(tiny, m80, 10, 0);
    try testing.expectEqual(@as(u32, 0), l.cols);
    try testing.expectEqual(@as(usize, 0), l.visible);
}

test "사각형은 왼쪽 위부터 행 우선으로 놓이고 서로 겹치지 않는다" {
    const l = layout(area_400x300, m80, 12, 0);
    const r0 = rectAt(area_400x300, m80, l, 0).?;
    const r1 = rectAt(area_400x300, m80, l, 1).?;
    const r4 = rectAt(area_400x300, m80, l, 4).?;

    try testing.expectEqual(@as(u32, 108), r0.x); // 100 + pad 8
    try testing.expectEqual(@as(u32, 58), r0.y); // 50 + pad 8
    // 한 칸 옆·한 행 아래는 **늘린 크기 + 간격**만큼이다(최소 폭이 아니다).
    try testing.expectEqual(r0.x + l.tile_w + m80.gap, r1.x);
    try testing.expectEqual(r0.y, r1.y);
    try testing.expectEqual(r0.x, r4.x); // 4열이라 5번째는 다음 행 첫 칸
    try testing.expectEqual(r0.y + l.tile_h + m80.gap, r4.y);

    // 겹치지 않는다 — 간격이 0 이 되면 여기서 걸린다.
    try testing.expect(r0.x + r0.w <= r1.x);
    try testing.expect(r0.y + r0.h <= r4.y);
}

test "보이는 범위 밖은 null — 화면 밖에 그리지 않는다" {
    const l = layout(area_400x300, m80, 3, 0);
    try testing.expect(rectAt(area_400x300, m80, l, 3) == null);
    try testing.expect(rectAt(area_400x300, m80, l, 999) == null);
}

test "letterbox: 비율을 지키고 가운데 정렬한다 — 늘리지도 자르지도 않는다" {
    const tile = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };

    // 가로로 긴 이미지 → 폭이 꽉 차고 높이가 줄고, 위아래가 남는다.
    const wide = fitInside(tile, 200, 100);
    try testing.expectEqual(@as(u32, 100), wide.w);
    try testing.expectEqual(@as(u32, 50), wide.h);
    try testing.expectEqual(@as(u32, 25), wide.y); // (100-50)/2

    // 세로로 긴 이미지(실측 최대 1440×14771 이 이 모양이다) → 높이가 꽉 찬다.
    const tall = fitInside(tile, 1440, 14771);
    try testing.expectEqual(@as(u32, 100), tall.h);
    try testing.expect(tall.w < 100 and tall.w >= 1);
    try testing.expectEqual((100 - tall.w) / 2, tall.x);

    // 정사각형은 그대로.
    const square = fitInside(tile, 512, 512);
    try testing.expectEqual(@as(u32, 100), square.w);
    try testing.expectEqual(@as(u32, 100), square.h);
}

test "letterbox: 0 크기는 타일을 그대로 준다 — 나눗셈으로 죽지 않는다" {
    const tile = Rect{ .x = 3, .y = 4, .w = 100, .h = 100 };
    try testing.expectEqual(tile.w, fitInside(tile, 0, 10).w);
    try testing.expectEqual(tile.h, fitInside(tile, 10, 0).h);
}

test "letterbox 결과는 언제나 타일 안에 있다" {
    const tile = Rect{ .x = 10, .y = 20, .w = 64, .h = 64 };
    for ([_][2]u32{ .{ 1, 10000 }, .{ 10000, 1 }, .{ 3, 7 }, .{ 1920, 1080 }, .{ 1, 1 } }) |wh| {
        const r = fitInside(tile, wh[0], wh[1]);
        try testing.expect(r.x >= tile.x and r.y >= tile.y);
        try testing.expect(r.x + r.w <= tile.x + tile.w);
        try testing.expect(r.y + r.h <= tile.y + tile.h);
        try testing.expect(r.w >= 1 and r.h >= 1);
    }
}

test "hitTest: 그린 자리를 누르면 그 칸이 나온다" {
    const l = layout(area_400x300, m80, 12, 0);
    for (0..l.visible) |n| {
        const r = rectAt(area_400x300, m80, l, n).?;
        // 왼쪽 위 모서리·가운데·오른쪽 아래 직전 — 세 점 다 같은 칸이어야 한다.
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x, r.y));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x + r.w / 2, r.y + r.h / 2));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x + r.w - 1, r.y + r.h - 1));
    }
}

test "hitTest: 간격·여백·바깥은 아무 칸도 아니다" {
    const l = layout(area_400x300, m80, 12, 0);
    const r0 = rectAt(area_400x300, m80, l, 0).?;
    // 칸 바로 오른쪽(간격 안).
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, r0.x + r0.w, r0.y));
    // 여백 안(격자 시작 전).
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, area_400x300.x, area_400x300.y));
    // 영역 왼쪽·위 바깥.
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, 0, 0));
    // 열 수를 넘는 오른쪽.
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, area_400x300.x + area_400x300.w, r0.y));
}

test "hitTest: 자리는 있는데 칸이 없으면 null — overflow 자리를 누르지 않는다" {
    // 12칸이 들어가는 격자에 이미지가 3장뿐이다. 4번째 자리를 눌러도 열 것이 없다.
    const l = layout(area_400x300, m80, 3, 0);
    const full = layout(area_400x300, m80, 12, 0);
    const r3 = rectAt(area_400x300, m80, full, 3).?;
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, r3.x + 2, r3.y + 2));
    try testing.expectEqual(@as(?usize, 2), hitTest(area_400x300, m80, l, r3.x - 88 + 2, r3.y + 2));
}

test "라벨 띠: 세로 칸이 라벨만큼 커지고 그 자리가 타일 바로 아래다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    // 늘린 뒤 cell_h = tile_h + label, step_y = cell_h + gap 로 행 수가 나온다.
    const l = layout(area_400x300, m, 100, 0);
    try testing.expectEqual(@as(u32, 4), l.cols);
    try testing.expectEqual(@as(u32, 90), l.tile_h); // 정사각이라 늘린 가로와 같다
    try testing.expectEqual(@as(usize, 8), l.visible); // 1 + (284-106)/114 = 2행 × 4열

    const r0 = rectAt(area_400x300, m, l, 0).?;
    const lab0 = labelRectAt(area_400x300, m, l, 0).?;
    try testing.expectEqual(r0.x, lab0.x);
    try testing.expectEqual(r0.y + r0.h, lab0.y); // 타일 **바로 아래**
    try testing.expectEqual(r0.w, lab0.w);
    try testing.expectEqual(@as(u32, 16), lab0.h);

    // 두 번째 행은 라벨 높이만큼 더 내려간다 — 안 그러면 글자가 다음 행 그림 위에 얹힌다.
    const r4 = rectAt(area_400x300, m, l, 4).?;
    try testing.expectEqual(r0.y + l.tile_h + 16 + 8, r4.y);
}

test "라벨 띠: 라벨이 0 이면 예전 배치 그대로다" {
    const with_label = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 0 };
    const l = layout(area_400x300, with_label, 100, 0);
    const old = layout(area_400x300, m80, 100, 0);
    try testing.expectEqual(old.cols, l.cols);
    try testing.expectEqual(old.visible, l.visible);
    try testing.expectEqual(rectAt(area_400x300, m80, old, 7).?.y, rectAt(area_400x300, with_label, l, 7).?.y);
    try testing.expect(labelRectAt(area_400x300, with_label, l, 0) == null);
}

test "라벨 띠: 마지막 행이 영역 안에 들어간다 — 글자가 도크 밖으로 안 나간다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    const l = layout(area_400x300, m, 100, 0);
    const last = l.visible - 1;
    const lab = labelRectAt(area_400x300, m, l, last).?;
    try testing.expect(lab.y + lab.h <= area_400x300.y + area_400x300.h);
}

test "라벨 띠: 그림 아래 글자를 눌러도 그 칸이 열린다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    const l = layout(area_400x300, m, 8, 0);
    for (0..l.visible) |n| {
        const lab = labelRectAt(area_400x300, m, l, n).?;
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m, l, lab.x + 2, lab.y + 2));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m, l, lab.x + lab.w - 1, lab.y + lab.h - 1));
    }
    // 라벨 아래 간격은 여전히 아무 칸도 아니다.
    const lab0 = labelRectAt(area_400x300, m, l, 0).?;
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m, l, lab0.x, lab0.y + lab0.h));
}

test "스크롤: 내려가면 다른 칸이 보인다 — 전부 닿을 수 있다" {
    // 실제 세션(151장)에서 스크롤 없이는 4장(2.6%)만 닿을 수 있었다. 그게 이 test 의 이유다.
    const l0 = layout(area_400x300, m80, 100, 0);
    try testing.expectEqual(@as(usize, 0), l0.first);
    try testing.expect(l0.max_scroll > 0); // 100칸이면 내려갈 곳이 있다

    // 끝까지 내리면 **마지막 칸이 보인다**.
    const lend = layout(area_400x300, m80, 100, l0.max_scroll);
    try testing.expect(lend.first + lend.visible == 100);
    try testing.expect(rectAt(area_400x300, m80, lend, 99) != null);

    // 상한을 넘겨 넣어도 그 자리에서 멈춘다(호출자가 clamp 를 잊어도 안전하다).
    const over = layout(area_400x300, m80, 100, l0.max_scroll + 10_000);
    try testing.expectEqual(lend.first, over.first);
    try testing.expectEqual(lend.scroll_px, over.scroll_px);
}

test "스크롤: 다 들어가면 내려갈 곳이 없다" {
    const l = layout(area_400x300, m80, 4, 0);
    try testing.expectEqual(@as(u32, 0), l.max_scroll);
    try testing.expectEqual(@as(usize, 0), l.overflow);
    // 내리려 해도 배치가 안 바뀐다.
    const l2 = layout(area_400x300, m80, 4, 500);
    try testing.expectEqual(@as(u32, 0), l2.scroll_px);
    try testing.expectEqual(rectAt(area_400x300, m80, l, 0).?.y, rectAt(area_400x300, m80, l2, 0).?.y);
}

test "스크롤: 그린 자리와 눌리는 자리가 함께 움직인다" {
    // **여기가 갈리면 스크롤한 만큼 어긋난 이미지가 열린다** — 깊이 내릴수록 크게 어긋나 재현이 헷갈린다.
    const l0 = layout(area_400x300, m80, 100, 0);
    const scrolled = layout(area_400x300, m80, 100, l0.max_scroll / 2);
    try testing.expect(scrolled.first > 0);
    var n = scrolled.first;
    while (n < scrolled.first + scrolled.visible) : (n += 1) {
        const r = rectAt(area_400x300, m80, scrolled, n) orelse continue;
        // 영역 안에 있는 점만 본다(반쯤 걸친 첫 행은 위로 나가 있다).
        if (r.y < area_400x300.y) continue;
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, scrolled, r.x + 2, r.y + 2));
    }
}

test "스크롤: 행 단위로 스냅한다 — 반쯤 걸친 행을 만들지 않는다" {
    // `Rect.y` 가 u32 라 음수를 표현할 수 없다. 반쯤 걸친 행을 허용하면 그 행이 0 으로 포화되어
    // **도크 밖에 그려진다**(실제로 그렇게 냈다).
    // **늘린 세로**로 step 을 잡는다 — 최소 폭으로 잡으면 배치와 다른 눈금을 재게 된다.
    const base = layout(area_400x300, m80, 100, 0);
    const step_y = base.tile_h + m80.label + m80.gap;
    const l = layout(area_400x300, m80, 100, step_y / 2);
    try testing.expectEqual(@as(u32, 0), l.scroll_px); // 반 칸은 0 으로 스냅
    const l2 = layout(area_400x300, m80, 100, step_y + 3);
    try testing.expectEqual(step_y, l2.scroll_px);
    // 첫 칸이 언제나 영역 안에서 시작한다.
    try testing.expect(rectAt(area_400x300, m80, l2, l2.first).?.y >= area_400x300.y);
    // max_scroll 도 행의 배수다.
    try testing.expectEqual(@as(u32, 0), l.max_scroll % step_y);
}

test "스크롤: 어느 깊이에서도 라벨이 영역 안에 있다" {
    // 행 단위 스냅의 결과다 — 글자는 이미지와 달리 잘라 그릴 수 없으므로 이것이 지켜져야 한다.
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    const base = layout(area_400x300, m, 100, 0);
    var scroll: u32 = 0;
    while (scroll <= base.max_scroll) : (scroll += 7) { // 행 배수가 아닌 값도 섞어 넣는다
        const l = layout(area_400x300, m, 100, scroll);
        var n = l.first;
        while (n < l.first + l.visible) : (n += 1) {
            const lab = labelRectAt(area_400x300, m, l, n) orelse continue;
            try testing.expect(lab.y >= area_400x300.y);
            try testing.expect(lab.y + lab.h <= area_400x300.y + area_400x300.h);
        }
    }
}

test "비정사각 타일: 세로가 tile_h 를 따르고 같은 높이에 더 많이 들어간다" {
    // 실측(600장): 가로/세로 중앙 2.00 · 79% 가 가로로 길다. 정사각은 절반을 여백으로 버린다.
    const square = Metrics{ .tile = 80, .gap = 8, .pad = 8 };
    const wide = Metrics{ .tile = 80, .tile_h = 40, .gap = 8, .pad = 8 };
    try testing.expectEqual(@as(u32, 80), tileHeight(square));
    try testing.expectEqual(@as(u32, 40), tileHeight(wide));

    const ls = layout(area_400x300, square, 100, 0);
    const lw = layout(area_400x300, wide, 100, 0);
    try testing.expectEqual(ls.cols, lw.cols); // 가로는 그대로
    try testing.expect(lw.visible > ls.visible); // 세로로 더 들어간다

    const r = rectAt(area_400x300, wide, lw, 0).?;
    // 늘린 뒤에도 **비율은 그대로 2:1** 이다 — 늘리면서 납작해지면 실측 비율과 어긋난다.
    try testing.expectEqual(lw.tile_w, r.w);
    try testing.expectEqual(lw.tile_w / 2, r.h);
    try testing.expect(r.w > wide.tile); // 실제로 늘어났다
    // 두 번째 행은 늘린 세로 기준으로 내려간다.
    const r2 = rectAt(area_400x300, wide, lw, lw.cols).?;
    try testing.expectEqual(r.y + lw.tile_h + 8, r2.y);
}

test "비정사각 타일: 라벨과 hitTest 가 같은 세로를 쓴다" {
    // 셋 중 하나라도 `tile` 을 세로로 쓰면 글자가 그림에서 밀리거나 누른 자리가 어긋난다.
    const wide = Metrics{ .tile = 80, .tile_h = 40, .gap = 8, .pad = 8, .label = 16 };
    const l = layout(area_400x300, wide, 40, 0);
    var n: usize = 0;
    while (n < l.visible) : (n += 1) {
        const r = rectAt(area_400x300, wide, l, n).?;
        const lab = labelRectAt(area_400x300, wide, l, n).?;
        try testing.expectEqual(r.y + l.tile_h, lab.y); // 라벨은 타일 **세로** 바로 아래
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, wide, l, r.x + 2, r.y + 2));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, wide, l, lab.x + 2, lab.y + 2));
    }
}

test "scrollToShow: 보이면 그대로, 안 보이면 그 칸이 보이게" {
    const m = m80;
    const count: usize = 100;
    const l0 = layout(area_400x300, m, count, 0);
    // 이미 보이는 칸은 스크롤을 안 건드린다 — 흔들리면 보던 자리를 잃는다.
    try testing.expectEqual(@as(u32, 0), scrollToShow(area_400x300, m, count, 0, 0));
    try testing.expectEqual(@as(u32, 0), scrollToShow(area_400x300, m, count, 0, l0.visible - 1));

    // 아래쪽 칸으로 가면 그 칸이 창에 든다.
    const s99 = scrollToShow(area_400x300, m, count, 0, 99);
    const l99 = layout(area_400x300, m, count, s99);
    try testing.expect(99 >= l99.first and 99 < l99.first + l99.visible);

    // 거기서 다시 0 번으로 오면 위로 올라온다.
    const back = scrollToShow(area_400x300, m, count, s99, 0);
    const lb = layout(area_400x300, m, count, back);
    try testing.expectEqual(@as(usize, 0), lb.first);
}

test "scrollToShow: 상한을 넘지 않고 행 배수다" {
    const m = Metrics{ .tile = 80, .tile_h = 40, .gap = 8, .pad = 8, .label = 16 };
    const count: usize = 200;
    const base = layout(area_400x300, m, count, 0);
    const step_y = base.tile_h + m.label + m.gap; // 배치가 쓴 눈금과 **같은 값**이어야 한다
    var n: usize = 0;
    while (n < count) : (n += 7) {
        const sc = scrollToShow(area_400x300, m, count, 0, n);
        try testing.expect(sc <= base.max_scroll);
        try testing.expectEqual(@as(u32, 0), sc % step_y);
        // 그 칸이 실제로 보인다.
        const l = layout(area_400x300, m, count, sc);
        try testing.expect(n >= l.first and n < l.first + l.visible);
    }
}

test "scrollToShow: 다 들어가면 움직이지 않는다" {
    const l = layout(area_400x300, m80, 4, 0);
    try testing.expectEqual(@as(u32, 0), l.max_scroll);
    try testing.expectEqual(@as(u32, 0), scrollToShow(area_400x300, m80, 4, 0, 3));
}
