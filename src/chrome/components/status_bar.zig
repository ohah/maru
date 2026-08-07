//! 창 바닥 상태표시줄의 **순수 배치**(SB1-S3). 항목을 좌/우 두 무리로 나눠 배치하고, 둘이 부딪히면
//! 무엇을 먼저 버릴지 정한다. AppKit/renderer/PTY 의존은 없다 — `dock_layout`과 같은 규율이다.
//!
//! **셀 격자가 아니라 픽셀로 센다.** 상태바는 터미널 grid 밖(바닥)이라 grid 행/열이 없고, 렌더도
//! 절대 origin으로 놓인 자기 frame을 쓴다(`metal_frame.zig`가 `row >= frame.size.rows`인 셀을 조용히
//! 버리므로 grid 좌표로는 애초에 그릴 수 없다). 그래서 이 모듈은 폭을 px로 받는다 — 호출자가 실제
//! 셰이핑으로 잰 폭을 넘긴다(글꼴·CJK 폭을 여기서 추측하지 않는다).

const std = @import("std");

/// 배치가 쓰는 여백. 값은 호출자가 pt→px로 환산해 넘긴다(이 모듈은 스케일을 모른다).
pub const Metrics = struct {
    /// 바 rect(창 전폭). x는 항상 0이지만 명시로 받는다 — 나중에 바가 전폭이 아니게 되면 여기만 바뀐다.
    bar_x: u32,
    bar_y: u32,
    bar_w: u32,
    bar_h: u32,
    /// 좌/우 가장자리 안쪽 여백.
    edge_pad_px: u32,
    /// 항목 사이 간격.
    gap_px: u32,
};

/// 배치된 항목 하나. `index`는 호출자가 넘긴 폭 배열에서의 위치라, 어떤 항목이 어디로 갔는지 되짚을 수 있다.
pub const Slot = struct {
    index: usize,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// 배치 결과. `left_placed`/`right_placed`는 실제로 자리를 얻은 개수다 — 넘긴 개수보다 **적을 수 있다**.
pub const Layout = struct {
    left: []const Slot,
    right: []const Slot,
    /// 자리가 없어 통째로 버린 항목 수(좌+우). 0이 아니면 호출자가 알 수 있게 남긴다 — 조용한 절단은
    /// "다 그렸다"로 읽히므로 셈을 노출한다.
    dropped: usize,
};

/// 좌측은 왼쪽부터, 우측은 오른쪽부터 채운다. **둘이 부딪히면 우측을 먼저 지킨다** — 우측 항목(위치·인코딩
/// 같은 상태값)은 폭이 작고 고정적이라 잘리면 의미가 사라지는 반면, 좌측(경로·브랜치)은 길어서 부딪히는
/// 원인 자체가 대개 좌측이기 때문이다. 좌측은 자리가 모자라면 **뒤쪽 항목부터** 통째로 버린다(부분 절단은
/// 호출자가 텍스트 단계에서 할 일이지 배치가 글자를 자를 수는 없다).
///
/// 버퍼는 호출자가 준다(할당 없음 — 렌더 hot path). `left_out`/`right_out`은 각각 입력 개수 이상이어야 한다.
pub fn compute(
    m: Metrics,
    left_widths_px: []const u32,
    right_widths_px: []const u32,
    left_out: []Slot,
    right_out: []Slot,
) Layout {
    std.debug.assert(left_out.len >= left_widths_px.len);
    std.debug.assert(right_out.len >= right_widths_px.len);
    if (m.bar_w == 0 or m.bar_h == 0) return .{ .left = &.{}, .right = &.{}, .dropped = left_widths_px.len + right_widths_px.len };

    const content_x = m.bar_x +| m.edge_pad_px;
    const content_right = (m.bar_x +| m.bar_w) -| m.edge_pad_px;
    if (content_right <= content_x) {
        return .{ .left = &.{}, .right = &.{}, .dropped = left_widths_px.len + right_widths_px.len };
    }

    var dropped: usize = 0;

    // 우측 먼저 — 오른쪽 끝에서 왼쪽으로 쌓는다. 여기서 정해진 좌단이 좌측의 상한이 된다.
    var right_n: usize = 0;
    var cursor = content_right;
    for (right_widths_px, 0..) |w, i| {
        if (w == 0) {
            dropped += 1;
            continue;
        }
        const gap: u32 = if (right_n == 0) 0 else m.gap_px;
        // 이 항목을 놓으면 좌단이 `cursor - gap - w`가 된다. 그게 content_x보다 왼쪽이면 자리가 없다.
        // 포화 뺄셈을 두 번 하는 대신 더하기로 옮겨 쓴다(같은 부등식, underflow 걱정 없음).
        if (cursor < gap +| w +| content_x) {
            dropped += 1;
            continue;
        }
        cursor -|= gap;
        const x = cursor -| w;
        cursor = x;
        right_out[right_n] = .{ .index = i, .x = x, .y = m.bar_y, .w = w, .h = m.bar_h };
        right_n += 1;
    }
    const left_limit = if (right_n == 0) content_right else cursor -| m.gap_px;

    // 좌측 — 왼쪽부터. 우측이 잡아 둔 좌단(left_limit)을 넘지 않는다.
    var left_n: usize = 0;
    var x = content_x;
    for (left_widths_px, 0..) |w, i| {
        if (w == 0) {
            dropped += 1;
            continue;
        }
        const gap: u32 = if (left_n == 0) 0 else m.gap_px;
        const start = x +| gap;
        if (start +| w > left_limit) {
            dropped += 1;
            continue;
        }
        left_out[left_n] = .{ .index = i, .x = start, .y = m.bar_y, .w = w, .h = m.bar_h };
        left_n += 1;
        x = start +| w;
    }

    return .{ .left = left_out[0..left_n], .right = right_out[0..right_n], .dropped = dropped };
}

const testing = std.testing;

fn metrics(bar_w: u32) Metrics {
    return .{ .bar_x = 0, .bar_y = 938, .bar_w = bar_w, .bar_h = 22, .edge_pad_px = 8, .gap_px = 12 };
}

test "SB1-S3a: 좌측은 왼쪽부터·우측은 오른쪽부터 채우고 간격을 지킨다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    const out = compute(metrics(1000), &.{ 100, 60 }, &.{ 40, 80 }, &lbuf, &rbuf);

    try testing.expectEqual(@as(usize, 2), out.left.len);
    try testing.expectEqual(@as(usize, 2), out.right.len);
    try testing.expectEqual(@as(usize, 0), out.dropped);

    // 좌: edge_pad(8)부터, 둘째는 gap(12)만큼 띄운다.
    try testing.expectEqual(@as(u32, 8), out.left[0].x);
    try testing.expectEqual(@as(u32, 8 + 100 + 12), out.left[1].x);
    // 우: 오른쪽 끝(1000-8)에서 왼쪽으로. 첫 항목이 가장 오른쪽이다.
    try testing.expectEqual(@as(u32, 1000 - 8 - 40), out.right[0].x);
    try testing.expectEqual(@as(u32, 1000 - 8 - 40 - 12 - 80), out.right[1].x);
    // 모든 슬롯이 바 높이·y를 그대로 쓴다(세로 정렬은 호출자가 baseline으로 한다).
    for (out.left) |s| try testing.expectEqual(@as(u32, 938), s.y);
    for (out.right) |s| try testing.expectEqual(@as(u32, 22), s.h);
}

test "SB1-S3a: 좁으면 좌측 뒤쪽부터 버리고 우측을 지킨다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    // 우측 120 + 좌측 100이면 딱 맞지만, 좌측 둘째(200)는 들어갈 자리가 없다.
    const out = compute(metrics(300), &.{ 100, 200 }, &.{120}, &lbuf, &rbuf);

    try testing.expectEqual(@as(usize, 1), out.right.len); // 우측은 지켜진다
    try testing.expectEqual(@as(usize, 1), out.left.len); // 좌측 첫 항목만
    try testing.expectEqual(@as(usize, 0), out.left[0].index);
    try testing.expectEqual(@as(usize, 1), out.dropped); // 버린 걸 셈으로 노출한다
    // 겹치지 않는다 — 좌측 우단이 우측 좌단을 넘지 않는다.
    try testing.expect(out.left[0].x + out.left[0].w <= out.right[0].x);
}

test "SB1-S3a: 우측이 자리를 다 먹으면 좌측은 전부 버려지고, 그래도 겹치지 않는다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    // 220 = pad(8) + 90 + gap(12) + 90 + pad(8) + 12여유 → 우측 둘이 딱 들어가고 좌측은 자리가 없다.
    const out = compute(metrics(220), &.{ 80, 80 }, &.{ 90, 90 }, &lbuf, &rbuf);

    try testing.expectEqual(@as(usize, 2), out.right.len); // 우측 우선 규칙
    try testing.expectEqual(@as(usize, 0), out.left.len);
    try testing.expectEqual(@as(usize, 2), out.dropped);
    // 배치된 우측끼리도 겹치지 않는다.
    try testing.expect(out.right[1].x + out.right[1].w <= out.right[0].x);
    for (out.right) |s| try testing.expect(s.x >= 8); // edge_pad 안쪽을 침범하지 않는다
}

// 좌측이 하나만 들어갈 만큼만 남는 경계 — "전부 버림"과 "다 들어감" 사이가 실제로 동작하는지 본다.
// (이 케이스를 처음엔 "좌측 전부 버려짐"으로 잘못 예상했다가 실측으로 바로잡았다.)
test "SB1-S3a: 우측이 하나만 들어가면 남은 자리에 좌측 하나가 들어간다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    const out = compute(metrics(200), &.{ 80, 80 }, &.{ 90, 90 }, &lbuf, &rbuf);

    try testing.expectEqual(@as(usize, 1), out.right.len);
    try testing.expectEqual(@as(usize, 1), out.left.len);
    try testing.expectEqual(@as(usize, 2), out.dropped);
    try testing.expect(out.left[0].x + out.left[0].w <= out.right[0].x); // 겹치지 않는다
}

test "SB1-S3a: 폭 0 항목과 0폭 바는 조용히 사라지지 않고 dropped로 센다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;

    const zero_item = compute(metrics(1000), &.{ 0, 50 }, &.{}, &lbuf, &rbuf);
    try testing.expectEqual(@as(usize, 1), zero_item.left.len);
    try testing.expectEqual(@as(usize, 1), zero_item.left[0].index); // 살아남은 것은 둘째다
    try testing.expectEqual(@as(usize, 1), zero_item.dropped);

    const zero_bar = compute(metrics(0), &.{50}, &.{50}, &lbuf, &rbuf);
    try testing.expectEqual(@as(usize, 0), zero_bar.left.len);
    try testing.expectEqual(@as(usize, 0), zero_bar.right.len);
    try testing.expectEqual(@as(usize, 2), zero_bar.dropped);

    // 여백이 바보다 큰 degenerate 창 — 겹친 rect를 내느니 전부 버린다.
    const tiny = compute(metrics(10), &.{5}, &.{5}, &lbuf, &rbuf);
    try testing.expectEqual(@as(usize, 0), tiny.left.len);
    try testing.expectEqual(@as(usize, 0), tiny.right.len);
    try testing.expectEqual(@as(usize, 2), tiny.dropped);
}
