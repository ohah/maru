//! 창 바닥 상태표시줄의 **순수 배치**(SB1-S3). 항목을 좌/우 두 무리로 나눠 배치하고, 둘이 부딪히면
//! 무엇을 먼저 버릴지 정한다. AppKit/renderer/PTY 의존은 없다 — `dock_layout`과 같은 규율이다.
//!
//! **셀 격자가 아니라 픽셀로 센다.** 상태바는 터미널 grid 밖(바닥)이라 grid 행/열이 없고, 렌더도
//! 절대 origin으로 놓인 자기 frame을 쓴다(`metal_frame.zig`가 `row >= frame.size.rows`인 셀을 조용히
//! 버리므로 grid 좌표로는 애초에 그릴 수 없다). 그래서 이 모듈은 폭을 px로 받는다 — 호출자가 실제
//! 셰이핑으로 잰 폭을 넘긴다(글꼴·CJK 폭을 여기서 추측하지 않는다).

const std = @import("std");
const tree = @import("../ui/tree.zig");
const layout = @import("../ui/layout.zig");

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

/// 항목의 **의미**(무엇을 가리키는 항목인가). `publish`가 이것을 안정된 `UiId`로 쓴다 — 슬롯 인덱스를
/// id로 쓰면 항목이 하나 사라질 때(브랜치가 없는 repo 밖 등) 남은 항목의 id가 밀려, 눌린 것과 실행된 것이
/// 갈린다. 의미로 식별하면 목록이 바뀌어도 같은 항목은 같은 id다.
pub const ItemId = enum(u64) {
    git_branch = 1,
    cwd = 2,
    running_agents = 3,
    notifications = 4,
};

pub const PublishError = error{InsufficientEntryBuffer};

/// 배치된 슬롯을 상호작용 tree로 발행한다. **그리기는 하지 않는다** — 항목 렌더는 기존 lowering 경로가
/// 그대로 하고, 이 tree는 hover/클릭 판정에만 쓴다(`chrome/components/divider.zig`와 같은 규율).
///
/// `ids`는 `compute`에 넘긴 폭 배열과 **같은 순서**여야 한다 — 슬롯의 `index`로 되짚기 때문이다.
/// 자리를 못 얻은 항목은 tree에 없다(안 보이는 것은 눌리지도 않는다).
pub fn publish(
    slots: []const Slot,
    ids: []const ItemId,
    generation: u64,
    out: []tree.RectEntry,
) PublishError!tree.UiRectTree {
    if (out.len < slots.len) return error.InsufficientEntryBuffer;
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.index >= ids.len) continue; // 호출자 실수 — 조용히 빼는 편이 잘못된 항목을 실행하는 것보다 낫다
        const id: u64 = @intFromEnum(ids[slot.index]);
        out[count] = .{
            .id = id,
            .parent_index = null,
            .kind = .button, // 아이콘 + 텍스트 + 액션 = button 노드의 정의 그대로다
            .rect = .{
                .x = @floatFromInt(slot.x),
                .y = @floatFromInt(slot.y),
                .width = @floatFromInt(slot.w),
                .height = @floatFromInt(slot.h),
            },
            .effective_clip = null,
            .action = .{ .id = id },
        };
        count += 1;
    }
    return .{ .entries = out[0..count], .generation = generation };
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

test "SB1: publish는 슬롯을 button 노드로 내고 **의미**로 식별한다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    var entries: [8]tree.RectEntry = undefined;

    // 좌: 브랜치(100) + 경로(60). 둘 다 자리를 얻는다.
    const wide = compute(metrics(1000), &.{ 100, 60 }, &.{}, &lbuf, &rbuf);
    const ids = [_]ItemId{ .git_branch, .cwd };
    const t1 = try publish(wide.left, &ids, 7, &entries);
    try testing.expectEqual(@as(usize, 2), t1.entries.len);
    try testing.expectEqual(@as(u64, 7), t1.generation);
    try testing.expectEqual(@intFromEnum(ItemId.git_branch), t1.entries[0].id);
    try testing.expectEqual(@intFromEnum(ItemId.cwd), t1.entries[1].id);
    for (t1.entries) |e| {
        try testing.expectEqual(tree.NodeKind.button, e.kind); // 아이콘+텍스트+액션 = button
        try testing.expect(e.action != null);
        try testing.expectEqual(e.id, e.action.?.id);
    }
    // rect가 슬롯 그대로다 — 보이는 자리와 눌리는 자리가 같아야 한다.
    try testing.expectEqual(@as(f32, @floatFromInt(wide.left[0].x)), t1.entries[0].rect.x);
    try testing.expectEqual(@as(f32, @floatFromInt(wide.left[0].w)), t1.entries[0].rect.width);
}

// **id는 슬롯 순서가 아니라 의미다.** 브랜치가 사라지면(repo 밖) 경로가 첫 슬롯이 되는데, 그때 id가
// 밀리면 "경로를 눌렀는데 브랜치 액션이 도는" 일이 난다. 이 테스트가 그 어긋남을 막는다.
test "SB1: 앞 항목이 사라져도 남은 항목의 id는 그대로다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    var entries: [8]tree.RectEntry = undefined;

    // 브랜치가 없는 상태 — 경로 하나만 넘긴다(호출자가 ids도 같이 줄인다).
    const only_cwd = compute(metrics(1000), &.{60}, &.{}, &lbuf, &rbuf);
    const ids = [_]ItemId{.cwd};
    const t = try publish(only_cwd.left, &ids, 1, &entries);
    try testing.expectEqual(@as(usize, 1), t.entries.len);
    try testing.expectEqual(@intFromEnum(ItemId.cwd), t.entries[0].id); // 1번(브랜치)이 아니다
}

test "SB1: 자리를 못 얻은 항목은 tree에 없다(안 보이면 눌리지도 않는다)" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    var entries: [8]tree.RectEntry = undefined;

    // 좌측 둘째(200)가 자리를 못 얻는 좁은 바.
    const narrow = compute(metrics(300), &.{ 100, 200 }, &.{120}, &lbuf, &rbuf);
    try testing.expectEqual(@as(usize, 1), narrow.left.len);
    const ids = [_]ItemId{ .git_branch, .cwd };
    const t = try publish(narrow.left, &ids, 1, &entries);
    try testing.expectEqual(@as(usize, 1), t.entries.len);
    try testing.expectEqual(@intFromEnum(ItemId.git_branch), t.entries[0].id); // 살아남은 것만

    // 버퍼가 모자라면 조용히 자르지 않고 에러다.
    var tiny: [0]tree.RectEntry = undefined;
    try testing.expectError(error.InsufficientEntryBuffer, publish(narrow.left, &ids, 1, &tiny));
}
