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
        // **자리를 못 얻으면 뒤 항목도 시도하지 않는다.** 배열 순서가 우선순위이므로(§3), 앞이 못 들어간
        // 자리에 뒤가 들어가면 정체가 뒤바뀐다 — 폭이 넓은 앞 항목이 화면에서 사라지고 뒤 항목이 그
        // 자리로 올라온다. 이 항목과 남은 항목을 한 번씩만 센다(폭 0으로 이미 센 앞 항목과 겹치지 않는다).
        if (cursor < gap +| w +| content_x) {
            dropped += right_widths_px.len - i;
            break;
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
        // 우측과 같은 규율 — 앞이 못 들어가면 거기서 멈춘다(§3 "앞이 더 오래 살아남는다").
        if (start +| w > left_limit) {
            dropped += left_widths_px.len - i;
            break;
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
    /// 입력을 기다리며 멈춘 에이전트. running과 **별도 항목**이다 — 한 항목에 두 상태를 섞으면 개수가
    /// 무엇의 개수인지 모호해진다.
    blocked_agents = 5,
    /// 편집기 pane이 활성일 때만 나타나는 넷(native-editor-layering.md §2.2). **더하는 순서가 곧 폭
    /// 부족 시 버려지는 순서**이고, 우측 묶음은 먼저 더한 것이 오른쪽에 서므로 **뒤로 갈수록 먼저
    /// 버려진다** — 그래서 "축소가 일어났다"는 사실이 가장 오래 남는다(§2.2: 조용히 줄어들면 사용자는
    /// 버그로 읽는다).
    ///
    /// **문서 둘 사이의 긴장을 여기서 푼다.** visual-mapping §은 읽기 전용·저하를 "커서 위치 왼쪽"에
    /// 두자고 했지만 이 배치에서 왼쪽은 곧 **먼저 버려지는 자리**다. 그 문서가 스스로 "최종 배치·버리는
    /// 순서는 status-bar.md가 소유한다"고 양보했고, §2.2가 "저하를 앞쪽에"라고 정했으므로 살아남는
    /// 쪽을 택한다.
    editor_degraded = 7,
    editor_readonly = 8,
    editor_eol = 9,
    /// 커서 위치(줄:열). §2.2 표의 **첫 항목**이라 편집기 묶음에서 가장 오래 살아남아야 하는데,
    /// 우측 묶음은 **먼저 더한 것이 오른쪽에 서고 뒤로 갈수록 먼저 버려지므로** 이 값을 마지막에
    /// 두면 그 반대가 된다. 그래서 값은 뒤여도 **더하는 자리는 편집기 묶음의 맨 앞**이다 —
    /// id는 의미이고 순서는 더하는 곳이 정한다(이 enum 위 문단).
    editor_cursor = 10,
    /// 이 창의 터미널 프로세스 자원(메모리·CPU). 누르면 탭별 내역 팝오버가 뜬다.
    /// id는 **클릭 동작이 없던 첫 판부터** 넣어 두었다 — `publish`가 폭 배열과 **같은 순서의 id 배열**을
    /// 슬롯 index로 되짚으므로, 항목만 늘리고 id를 빠뜨리면 인덱스가 밀려 "누른 것과 실행된 것"이 갈린다.
    /// 클릭이 나중에 붙어도 이 이유는 그대로다.
    resource = 6,
    /// 앱 전역 workspace checkpoint가 연속 실패 중일 때 모든 일반 창에 남는 비모달 경고.
    /// 우측 배열의 첫 항목으로 조립해 좁은 창에서도 가장 오래 보존한다.
    workspace_checkpoint_failure = 11,
    /// host 연결이 죽어 **새 Term이 in-process로 열리는** 상태(`host_connect_failed`). 체크포인트 실패와
    /// 같은 급의 데이터 보존 경고라 같은 대우를 한다 — 앱 전역이고, 비모달이고, 우측 최우선이다.
    ///
    /// **notice로는 부족해서 생겼다.** 폴백은 `!host_connect_failed` 가드 때문에 **첫 번째 한 번만**
    /// notice를 띄우고, 그 notice 마저 아무 키나 누르면 닫힌다(터미널 앱에서 다음 행동은 타이핑이다).
    /// 그런데 강등은 프로세스가 끝날 때까지 남는다 — 그 뒤 여는 터미널은 전부 앱과 함께 죽는데 화면
    /// 어디에도 그 사실이 없었다. 영속 세션은 이 제품의 약속이므로 **깨진 동안에는 화면에 남아야 한다**.
    ///
    /// **표시 전용이다.** 누르면 다시 잇는 동작은 실제 socket reconnect(CR4)가 소유하므로 여기서 만들지
    /// 않는다 — 지금 붙이면 선행 gate 우회다(implementation-plan.md CR 절).
    session_host_disconnected = 12,
    /// 폰이 붙어 세션이 좁아졌다(S11-6). **표시 전용** — 누르는 동작이 없다. 이 상태는 폰이
    /// 떠나면 host 가 크기를 되돌리며 저절로 사라진다.
    viewport_narrowed = 13,
};

/// **우측 묶음에 실릴 수 있는 항목 전부** — `ItemId`에서 좌측 전용을 뺀 것.
///
/// 조립 배열의 상한을 이 길이에서 되짚는다. 항목을 하나 더하고 상한을 안 올리면 **마지막 후보가
/// 폭과 무관하게 사라지는데**(실측: 커서 위치를 더했을 때 리소스가 2,500px 남은 채로 빠졌다),
/// 그건 폭 규칙이 아니라 배열 상한이라 화면만 봐서는 "폭이 모자랐나 보다"로 읽힌다 —
/// `status-bar.md` §3이 금지한 조용한 절단이다.
///
/// **enum에서 파생시키는 것이 요점이다.** 손으로 적는 목록이면 원장을 잊는 실수가 그대로 남는다.
pub const right_candidates = blk: {
    const all = std.enums.values(ItemId);
    var out: [all.len]ItemId = undefined;
    var n: usize = 0;
    for (all) |id| switch (id) {
        // 좌측 전용만 뺀다. **여기 안 적은 새 항목은 자동으로 우측 후보가 된다** — 손으로 유지하는
        // 목록이면 "항목만 더하고 원장을 잊는" 실수가 그대로 남는데, 그게 이 상수가 막으려던 사고다.
        // 좌측 항목을 여기 안 더하는 실수는 상한이 넉넉해지는 방향이라 조용한 절단을 안 만든다.
        .git_branch, .cwd => {},
        else => {
            out[n] = id;
            n += 1;
        },
    };
    const final = out[0..n].*;
    break :blk final;
};

pub const PublishError = error{InsufficientEntryBuffer};

/// 배치된 슬롯을 상호작용 tree로 발행한다. **그리기는 하지 않는다** — 항목 렌더는 기존 lowering 경로가
/// 그대로 하고, 이 tree는 hover/클릭 판정에만 쓴다(`chrome/components/divider.zig`와 같은 규율).
///
/// `ids`는 `compute`에 넘긴 폭 배열과 **같은 순서**여야 한다 — 슬롯의 `index`로 되짚기 때문이다.
/// 자리를 못 얻은 항목은 tree에 없다(안 보이는 것은 눌리지도 않는다).
pub fn publish(
    m: Metrics,
    slots: []const Slot,
    ids: []const ItemId,
    /// 항목 좌우로 넓힐 여백(px, 한쪽). 글자에 딱 붙은 호버 배경은 답답해 보인다 — 그런데 **판정 rect가
    /// 곧 호버 rect**이므로 여기서 한 번 넓히면 보이는 자리와 눌리는 자리가 **구조적으로** 같이 넓어진다.
    /// 배치(`compute`)는 건드리지 않는다: 항목 사이 간격(`gap_px`)이 이 여백보다 넓어야 서로 안 겹친다.
    pad_px: u32,
    generation: u64,
    out: []tree.RectEntry,
) PublishError!tree.UiRectTree {
    if (out.len < slots.len) return error.InsufficientEntryBuffer;
    const bar_left = m.bar_x;
    const bar_right = m.bar_x +| m.bar_w;
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.index >= ids.len) continue; // 호출자 실수 — 조용히 빼는 편이 잘못된 항목을 실행하는 것보다 낫다
        const id: u64 = @intFromEnum(ids[slot.index]);
        // 바 밖으로는 못 나간다 — 첫/마지막 항목이 `edge_pad` 일부를 먹는 것은 의도지만 바를 넘으면 안 된다.
        const left = @max(bar_left, slot.x -| pad_px);
        const right = @min(bar_right, slot.x +| slot.w +| pad_px);
        out[count] = .{
            .id = id,
            .parent_index = null,
            .kind = .button, // 아이콘 + 텍스트 + 액션 = button 노드의 정의 그대로다
            .rect = .{
                .x = @floatFromInt(left),
                .y = @floatFromInt(slot.y),
                .width = @floatFromInt(right -| left),
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
    const t1 = try publish(metrics(1000), wide.left, &ids, 0, 7, &entries); // pad 0 = 슬롯 그대로
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
    const t = try publish(metrics(1000), only_cwd.left, &ids, 0, 1, &entries);
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
    const t = try publish(metrics(300), narrow.left, &ids, 0, 1, &entries);
    try testing.expectEqual(@as(usize, 1), t.entries.len);
    try testing.expectEqual(@intFromEnum(ItemId.git_branch), t.entries[0].id); // 살아남은 것만

    // 버퍼가 모자라면 조용히 자르지 않고 에러다.
    var tiny: [0]tree.RectEntry = undefined;
    try testing.expectError(error.InsufficientEntryBuffer, publish(metrics(300), narrow.left, &ids, 0, 1, &tiny));
}

// 호버 배경이 글자에 딱 붙으면 답답해 보인다. 좌우로 넓히되 **판정 rect가 곧 호버 rect**라 둘이 함께
// 넓어진다 — 보이는 자리와 눌리는 자리가 갈릴 수 없다. 대신 두 가지를 지켜야 한다: 바 밖으로 안 나가고,
// 이웃끼리 안 겹친다.
test "SB1: publish의 좌우 여백은 바를 안 넘고 이웃과 안 겹친다" {
    var lbuf: [4]Slot = undefined;
    var rbuf: [4]Slot = undefined;
    var entries: [8]tree.RectEntry = undefined;
    const m = metrics(1000); // edge_pad 8, gap 12

    const out = compute(m, &.{ 100, 60 }, &.{}, &lbuf, &rbuf);
    const ids = [_]ItemId{ .git_branch, .cwd };
    const t = try publish(m, out.left, &ids, 4, 1, &entries);
    try testing.expectEqual(@as(usize, 2), t.entries.len);

    // 좌우로 4px씩 넓어졌다(슬롯 100 → 108).
    try testing.expectEqual(@as(f32, @floatFromInt(out.left[0].x - 4)), t.entries[0].rect.x);
    try testing.expectEqual(@as(f32, @floatFromInt(out.left[0].w + 8)), t.entries[0].rect.width);

    // 이웃과 안 겹친다 — gap(12)이 여백 둘(4+4)보다 넓어야 성립한다.
    try testing.expect(t.entries[0].rect.x + t.entries[0].rect.width <= t.entries[1].rect.x);

    // 바 밖으로 안 나간다. 첫 항목은 edge_pad(8) 일부를 먹지만 바 좌단(0) 아래로는 안 간다.
    for (t.entries) |e| {
        try testing.expect(e.rect.x >= 0);
        try testing.expect(e.rect.x + e.rect.width <= 1000);
    }

    // 여백이 edge_pad보다 커도 바를 안 넘는다(clamp).
    const huge = try publish(m, out.left, &ids, 999, 1, &entries);
    try testing.expectEqual(@as(f32, 0), huge.entries[0].rect.x);
    try testing.expect(huge.entries[0].rect.x + huge.entries[0].rect.width <= 1000);
}

// 좌측 우선순위는 **배열 순서**다(§3: "앞이 더 왼쪽이자 더 오래 살아남고", "뒤쪽 항목부터 통째로 버린다").
// 앞 항목이 자리를 못 얻었는데 뒤 항목이 그 자리를 차지하면 우선순위가 뒤집힌다 — 긴 브랜치명 + 짧은
// 경로에서 실제로 일어난다(브랜치가 사라지고 경로가 그 자리로 올라온다). 이름 길이에 따라 **표시되는
// 항목의 정체가 바뀌는** 것이 이 역전의 실제 해악이다.
test "좌측은 앞 항목이 못 들어가면 뒤 항목도 넣지 않는다(우선순위 역전 금지)" {
    var left: [2]Slot = undefined;
    var right: [1]Slot = undefined;
    const m: Metrics = .{
        .bar_x = 0,
        .bar_y = 0,
        .bar_w = 60, // edge_pad 4+4를 빼면 52 — 앞(100)은 못 들어가고 뒤(20)만 들어갈 폭
        .bar_h = 20,
        .edge_pad_px = 4,
        .gap_px = 8,
    };
    const lay = compute(m, &.{ 100, 20 }, &.{}, &left, &right);
    try std.testing.expectEqual(@as(usize, 0), lay.left.len);
    try std.testing.expectEqual(@as(usize, 2), lay.dropped);
}

// 우측도 같은 규율이다(§3: "배열 순서가 곧 우선순위다 ... 우측은 앞이 더 오른쪽"). 앞 항목이 자리를
// 못 얻었는데 뒤 항목이 가장 오른쪽을 차지하면, 좌측과 똑같이 정체가 뒤바뀐다.
test "우측도 앞 항목이 못 들어가면 뒤 항목을 넣지 않는다" {
    var left: [1]Slot = undefined;
    var right: [2]Slot = undefined;
    const m: Metrics = .{
        .bar_x = 0,
        .bar_y = 0,
        .bar_w = 60,
        .bar_h = 20,
        .edge_pad_px = 4,
        .gap_px = 8,
    };
    const lay = compute(m, &.{}, &.{ 100, 20 }, &left, &right);
    try std.testing.expectEqual(@as(usize, 0), lay.right.len);
    try std.testing.expectEqual(@as(usize, 2), lay.dropped);
}
