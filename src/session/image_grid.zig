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
    /// 타일 한 변. 썸네일 픽셀(160)과 **다를 수 있다** — 화면 크기는 레이아웃이, 텍스처 크기는 디코드가 정한다.
    tile: u32,
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

pub const Layout = struct {
    /// 한 행에 몇 칸인가. 0 이면 폭이 모자라 하나도 못 그린다.
    cols: u32,
    /// 실제로 자리를 얻은 칸 수.
    visible: usize,
    /// 자리를 못 얻은 칸 수. **「이미지가 없다」와 「화면에 안 들어간다」를 가르는 값**이다.
    overflow: usize,
};

/// 격자에 몇 칸이 들어가는지 센다. 사각형은 `rectAt` 이 준다.
pub fn layout(area: Rect, m: Metrics, count: usize) Layout {
    if (m.tile == 0 or count == 0) return .{ .cols = 0, .visible = 0, .overflow = count };
    // 여백을 빼고 남는 폭·높이. `-|` 로 음수 대신 0 이 되게 한다 — 좁은 도크에서 언더플로가 나면
    // 열 수가 거대해져 화면 밖에 칸을 그린다.
    const inner_w = area.w -| (m.pad *| 2);
    const inner_h = area.h -| (m.pad *| 2);
    if (inner_w < m.tile or inner_h < m.tile) return .{ .cols = 0, .visible = 0, .overflow = count };

    // 첫 칸은 간격 없이 들어가고 그 다음부터 (간격 + 타일)씩 먹는다.
    // **세로는 라벨까지가 한 칸이다** — 라벨 높이를 빼먹으면 마지막 행 글자가 도크 밖으로 나간다.
    const cell_h = m.tile +| m.label;
    if (inner_h < cell_h) return .{ .cols = 0, .visible = 0, .overflow = count };
    const step = m.tile +| m.gap;
    const step_y = cell_h +| m.gap;
    const cols = 1 + (inner_w - m.tile) / step;
    const rows = 1 + (inner_h - cell_h) / step_y;
    const capacity = @as(usize, cols) *| @as(usize, rows);
    const visible = @min(count, capacity);
    return .{ .cols = cols, .visible = visible, .overflow = count - visible };
}

/// `n` 번째 칸의 사각형. `layout` 이 센 `visible` 밖이면 `null` — 화면 밖에 그리지 않는다.
pub fn rectAt(area: Rect, m: Metrics, l: Layout, n: usize) ?Rect {
    if (l.cols == 0 or n >= l.visible) return null;
    const step = m.tile +| m.gap;
    const step_y = m.tile +| m.label +| m.gap;
    const col: u32 = @intCast(n % l.cols);
    const row: u32 = @intCast(n / l.cols);
    return .{
        .x = area.x +| m.pad +| col *| step,
        .y = area.y +| m.pad +| row *| step_y,
        .w = m.tile,
        .h = m.tile,
    };
}

/// `n` 번째 칸의 **라벨** 자리. 라벨 높이가 0 이면 `null` — 그릴 자리가 없다는 뜻이다.
///
/// `rectAt` 에서 파생한다(hitTest 와 같은 규율) — 좌표를 따로 풀면 글자가 그림에서 밀린다.
pub fn labelRectAt(area: Rect, m: Metrics, l: Layout, n: usize) ?Rect {
    if (m.label == 0) return null;
    const tile = rectAt(area, m, l, n) orelse return null;
    return .{ .x = tile.x, .y = tile.y +| tile.h, .w = tile.w, .h = m.label };
}

/// `(px, py)` 위에 있는 칸. 없으면 `null` — 간격·여백을 누르면 아무 일도 없다.
///
/// **`rectAt` 에서 파생한다.** 좌표를 여기서 따로 풀면 배치를 바꿀 때 그린 자리와 눌리는 자리가
/// 갈라지고, 그때 사용자에게는 「엉뚱한 이미지가 열린다」로 보인다 — 화면 없이는 못 잡는 종류의 버그다.
pub fn hitTest(area: Rect, m: Metrics, l: Layout, px: u32, py: u32) ?usize {
    if (l.cols == 0 or l.visible == 0) return null;
    const step = m.tile +| m.gap;
    const step_y = m.tile +| m.label +| m.gap;
    if (step == 0 or step_y == 0) return null;
    const ox = area.x +| m.pad;
    const oy = area.y +| m.pad;
    if (px < ox or py < oy) return null;
    const col = (px - ox) / step;
    const row = (py - oy) / step_y;
    if (col >= l.cols) return null;
    const n = @as(usize, row) *| @as(usize, l.cols) +| @as(usize, col);
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
    // inner = 400-16 = 384, step = 88 → 1 + (384-80)/88 = 1+3 = 4열
    // inner_h = 300-16 = 284 → 1 + (284-80)/88 = 1+2 = 3행 → 12칸
    const l = layout(area_400x300, m80, 100);
    try testing.expectEqual(@as(u32, 4), l.cols);
    try testing.expectEqual(@as(usize, 12), l.visible);
    try testing.expectEqual(@as(usize, 88), l.overflow);
}

test "칸이 자리보다 적으면 넘치는 것이 없다" {
    const l = layout(area_400x300, m80, 5);
    try testing.expectEqual(@as(usize, 5), l.visible);
    try testing.expectEqual(@as(usize, 0), l.overflow);
}

test "폭이 모자라면 하나도 안 그린다 — 반쪽 칸을 만들지 않는다" {
    const narrow = Rect{ .x = 0, .y = 0, .w = 90, .h = 300 }; // inner 74 < tile 80
    const l = layout(narrow, m80, 10);
    try testing.expectEqual(@as(u32, 0), l.cols);
    try testing.expectEqual(@as(usize, 0), l.visible);
    // **「없다」가 아니라 「안 보인다」다.** 이 구분이 없으면 좁은 도크에서 「이미지가 없습니다」로 거짓말한다.
    try testing.expectEqual(@as(usize, 10), l.overflow);
}

test "언더플로가 열 수를 폭주시키지 않는다 — 여백이 폭보다 큰 경우" {
    const tiny = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    const l = layout(tiny, m80, 10);
    try testing.expectEqual(@as(u32, 0), l.cols);
    try testing.expectEqual(@as(usize, 0), l.visible);
}

test "사각형은 왼쪽 위부터 행 우선으로 놓이고 서로 겹치지 않는다" {
    const l = layout(area_400x300, m80, 12);
    const r0 = rectAt(area_400x300, m80, l, 0).?;
    const r1 = rectAt(area_400x300, m80, l, 1).?;
    const r4 = rectAt(area_400x300, m80, l, 4).?;

    try testing.expectEqual(@as(u32, 108), r0.x); // 100 + pad 8
    try testing.expectEqual(@as(u32, 58), r0.y); // 50 + pad 8
    try testing.expectEqual(r0.x + 88, r1.x); // 같은 행, 한 칸 옆
    try testing.expectEqual(r0.y, r1.y);
    try testing.expectEqual(r0.x, r4.x); // 4열이라 5번째는 다음 행 첫 칸
    try testing.expectEqual(r0.y + 88, r4.y);

    // 겹치지 않는다 — 간격이 0 이 되면 여기서 걸린다.
    try testing.expect(r0.x + r0.w <= r1.x);
    try testing.expect(r0.y + r0.h <= r4.y);
}

test "보이는 범위 밖은 null — 화면 밖에 그리지 않는다" {
    const l = layout(area_400x300, m80, 3);
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
    const l = layout(area_400x300, m80, 12);
    for (0..l.visible) |n| {
        const r = rectAt(area_400x300, m80, l, n).?;
        // 왼쪽 위 모서리·가운데·오른쪽 아래 직전 — 세 점 다 같은 칸이어야 한다.
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x, r.y));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x + r.w / 2, r.y + r.h / 2));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m80, l, r.x + r.w - 1, r.y + r.h - 1));
    }
}

test "hitTest: 간격·여백·바깥은 아무 칸도 아니다" {
    const l = layout(area_400x300, m80, 12);
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
    const l = layout(area_400x300, m80, 3);
    const full = layout(area_400x300, m80, 12);
    const r3 = rectAt(area_400x300, m80, full, 3).?;
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m80, l, r3.x + 2, r3.y + 2));
    try testing.expectEqual(@as(?usize, 2), hitTest(area_400x300, m80, l, r3.x - 88 + 2, r3.y + 2));
}

test "라벨 띠: 세로 칸이 라벨만큼 커지고 그 자리가 타일 바로 아래다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    // inner_h = 284, cell_h = 96, step_y = 104 → 1 + (284-96)/104 = 1+1 = 2행(라벨 없을 때는 3행이었다)
    const l = layout(area_400x300, m, 100);
    try testing.expectEqual(@as(u32, 4), l.cols);
    try testing.expectEqual(@as(usize, 8), l.visible);

    const r0 = rectAt(area_400x300, m, l, 0).?;
    const lab0 = labelRectAt(area_400x300, m, l, 0).?;
    try testing.expectEqual(r0.x, lab0.x);
    try testing.expectEqual(r0.y + r0.h, lab0.y); // 타일 **바로 아래**
    try testing.expectEqual(r0.w, lab0.w);
    try testing.expectEqual(@as(u32, 16), lab0.h);

    // 두 번째 행은 라벨 높이만큼 더 내려간다 — 안 그러면 글자가 다음 행 그림 위에 얹힌다.
    const r4 = rectAt(area_400x300, m, l, 4).?;
    try testing.expectEqual(r0.y + 80 + 16 + 8, r4.y);
}

test "라벨 띠: 라벨이 0 이면 예전 배치 그대로다" {
    const with_label = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 0 };
    const l = layout(area_400x300, with_label, 100);
    const old = layout(area_400x300, m80, 100);
    try testing.expectEqual(old.cols, l.cols);
    try testing.expectEqual(old.visible, l.visible);
    try testing.expectEqual(rectAt(area_400x300, m80, old, 7).?.y, rectAt(area_400x300, with_label, l, 7).?.y);
    try testing.expect(labelRectAt(area_400x300, with_label, l, 0) == null);
}

test "라벨 띠: 마지막 행이 영역 안에 들어간다 — 글자가 도크 밖으로 안 나간다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    const l = layout(area_400x300, m, 100);
    const last = l.visible - 1;
    const lab = labelRectAt(area_400x300, m, l, last).?;
    try testing.expect(lab.y + lab.h <= area_400x300.y + area_400x300.h);
}

test "라벨 띠: 그림 아래 글자를 눌러도 그 칸이 열린다" {
    const m = Metrics{ .tile = 80, .gap = 8, .pad = 8, .label = 16 };
    const l = layout(area_400x300, m, 8);
    for (0..l.visible) |n| {
        const lab = labelRectAt(area_400x300, m, l, n).?;
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m, l, lab.x + 2, lab.y + 2));
        try testing.expectEqual(@as(?usize, n), hitTest(area_400x300, m, l, lab.x + lab.w - 1, lab.y + lab.h - 1));
    }
    // 라벨 아래 간격은 여전히 아무 칸도 아니다.
    const lab0 = labelRectAt(area_400x300, m, l, 0).?;
    try testing.expectEqual(@as(?usize, null), hitTest(area_400x300, m, l, lab0.x, lab0.y + lab0.h));
}
