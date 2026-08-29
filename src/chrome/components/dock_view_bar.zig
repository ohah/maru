//! 도크 뷰 스위처 한 행의 **순수 기하**(docs/file-explorer.md §3.5).
//!
//! 도크는 컬럼 하나이고 그 안에서 어떤 뷰를 그릴지만 고른다. 이 모듈은 그 아이콘 줄의 슬롯 rect와 hit-test만
//! 계산하며, 렌더·hover·클릭이 **같은 계산**을 공유한다(파일 트리 스크롤바·아이콘과 같은 패턴 — 기하가 두 벌이 되면
//! 보이는 자리와 눌리는 자리가 어긋난다).
//!
//! I/O도 상태도 없다. 셀 폭을 받아 슬롯 폭을 셀 단위로 올림하는 이유는 chrome이 GPU 셀 격자에 정렬돼 있어서다
//! (sub-pixel quad는 셀 배경에 먹혀 사라진다 — docs 기준: tui 위젯은 셀 정렬).

const std = @import("std");

/// 도크 기하(`split_tree.Rect`)와 **같은 좌표 규약**(u32)이다. 레이어를 넘지 않으려고 타입을 재선언하되,
/// 변환을 끼우지 않는다 — 캐스팅이 끼면 그린 자리와 눌리는 자리가 어긋난다.
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// v1 슬롯 수. 어떤 뷰가 몇 번째인지는 **호출자(session)가 안다** — chrome은 도메인 enum을 모르고 자리만 센다
/// (레이어 경계: chrome 컴포넌트는 session을 import하지 않는다). 목업의 나머지 칸은 **그리지 않는다** —
/// 누를 수 없는 아이콘을 띄우지 않는다(§3.5).
pub const slot_count: usize = 4;

/// 슬롯 하나가 차지하는 셀 수. **아이콘이 2셀**(사이드바 에이전트 아이콘과 같은 `width=2` — 합성 아이콘은
/// 슬롯 크기에 맞춰 스케일되므로 2칸이면 또렷하고 크다)이고 좌우 여백 1셀씩이라 4셀이다.
pub const slot_cols: u32 = 4;

/// 슬롯 안에서 아이콘이 시작하는 셀 오프셋(좌측 여백 1셀 뒤). 렌더가 이 값을 쓰고 hit-test는 슬롯 전체를
/// 대상으로 하므로 여백을 눌러도 전환된다 — 아이콘 픽셀만 눌러야 하는 UI는 작을수록 짜증난다.
pub const icon_col_offset: u32 = 1;

/// 아이콘이 차지하는 셀 수(`DrawCell.width`).
pub const icon_cols: u32 = 2;

/// 슬롯 rect(없으면 null). 바가 접혔거나(높이 0) 폭이 모자라면 null이다. 폭이 모자랄 때 **일부만 그리지 않는다** —
/// 반쯤 잘린 스위처는 눌러도 되는지 알 수 없다.
pub fn slotRect(bar: Rect, cell_width_px: u32, index: usize) ?Rect {
    if (index >= slot_count) return null;
    if (bar.h == 0 or bar.w == 0 or cell_width_px == 0) return null;
    const slot_w = slot_cols * cell_width_px;
    const total = slot_w * @as(u32, @intCast(slot_count));
    if (total > bar.w) return null;
    const offset: u32 = slot_w * @as(u32, @intCast(index));
    return .{ .x = bar.x + offset, .y = bar.y, .w = slot_w, .h = bar.h };
}

/// 좌표가 몇 번째 슬롯 위인지. 슬롯 밖(여백 포함)은 null이라 호출자가 no-op으로 둔다.
pub fn slotAtPoint(bar: Rect, cell_width_px: u32, x: u32, y: u32) ?usize {
    if (y < bar.y or y >= bar.y + bar.h) return null;
    var index: usize = 0;
    while (index < slot_count) : (index += 1) {
        const rect = slotRect(bar, cell_width_px, index) orelse return null;
        if (x >= rect.x and x < rect.x + rect.w) return index;
    }
    return null;
}

/// 바 **오른쪽 끝**에 붙는 동작 슬롯(새로고침·전체 접기 …). 뷰 스위처와 **같은 슬롯 폭**을 쓴다 — 한 바 안에서
/// 누를 수 있는 자리의 크기가 두 종류면 어느 쪽이 버튼인지 손이 배우지 못한다.
///
/// 개수는 호출자가 준다. chrome은 **무슨 동작인지 모르고 자리만 센다**(뷰 열거를 모르는 것과 같은 이유) —
/// 뷰마다 동작 수가 다르므로 그 결정은 session이 갖는다.
///
/// `index` 0이 가장 왼쪽이다. 오른쪽 정렬이지만 **읽는 순서는 왼쪽부터**여야 목록이 늘어나도 기존 버튼의
/// 자리가 안 바뀐다(오른쪽 끝에 붙는 것은 새로 생긴 쪽).
pub fn actionRect(bar: Rect, cell_width_px: u32, count: usize, index: usize) ?Rect {
    if (index >= count or count == 0) return null;
    if (bar.h == 0 or bar.w == 0 or cell_width_px == 0) return null;
    // **오른쪽 끝은 바 픽셀 폭이 아니라 셀 격자의 끝이다.** 도크 폭은 드래그로 정해져 셀 배수가 아닌 것이
    // 보통이고, 아이콘은 셀 격자에 그려진다(`buildDockViewBarDrawList` 가 `cols = 폭 / 셀폭` 으로 받는다).
    // 픽셀 끝에 붙이면 눌리는 자리가 그린 자리보다 최대 한 셀 못 미치게 밀려, 아이콘 왼쪽을 눌러도 반응이
    // 없고 오른쪽 여백이 눌린다 — 왼쪽 정렬인 뷰 슬롯에는 없던, 오른쪽 정렬이 만든 함정이다.
    const start_col = actionStartCol(bar.w / cell_width_px, count) orelse return null;
    const col = start_col + slot_cols * @as(u32, @intCast(index));
    return .{ .x = bar.x + col * cell_width_px, .y = bar.y, .w = slot_cols * cell_width_px, .h = bar.h };
}

/// 동작 슬롯이 시작하는 **셀 열**(그릴 자리가 없으면 null). 렌더는 셀 격자에, hit-test 는 픽셀에 살지만
/// **자리를 정하는 식은 이것 하나다** — 두 벌이면 지금은 같은 값이어도 한쪽만 고쳐지는 날 어긋난다.
pub fn actionStartCol(cols: u32, count: usize) ?u32 {
    if (count == 0) return null;
    // 뷰 스위처와 겹치면 **하나도 그리지 않는다**. 반쯤 겹친 버튼은 무엇이 눌리는지 알 수 없고, 좁은 도크에서
    // 뷰 전환은 동작 버튼보다 먼저 지켜야 하는 기능이다(슬롯이 다 안 들어가면 아예 안 그리는 정책과 같은 결).
    const need = slot_cols * @as(u32, @intCast(slot_count + count));
    if (cols < need) return null;
    return cols - slot_cols * @as(u32, @intCast(count));
}

/// 좌표가 몇 번째 동작 슬롯 위인지. 동작이 안 그려지는 상황이면 null이라 호출자가 no-op으로 둔다 —
/// **보이지 않는 버튼은 눌리지도 않는다**(그리는 조건과 판정 조건이 같은 함수에서 나온다).
pub fn actionAtPoint(bar: Rect, cell_width_px: u32, count: usize, x: u32, y: u32) ?usize {
    if (y < bar.y or y >= bar.y + bar.h) return null;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const rect = actionRect(bar, cell_width_px, count, index) orelse return null;
        if (x >= rect.x and x < rect.x + rect.w) return index;
    }
    return null;
}

const testing = std.testing;

test "슬롯은 셀 정렬 폭으로 좌측부터 이어 붙는다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 180, .h = 18 };
    const a = slotRect(bar, 8, 0).?;
    const b = slotRect(bar, 8, 1).?;
    try testing.expectEqual(@as(u32, 100), a.x);
    try testing.expectEqual(@as(u32, 32), a.w); // 4셀 × 8px
    try testing.expectEqual(a.x + a.w, b.x); // 사이가 벌어지거나 겹치지 않는다
    try testing.expectEqual(bar.h, a.h);
    try testing.expect(slotRect(bar, 8, slot_count) == null);
}

test "바가 접혔거나 폭이 모자라면 슬롯을 하나도 그리지 않는다" {
    // 높이 0(낮은 도크에서 접힘)
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, 8, 0) == null);
    // 전체 슬롯이 다 안 들어가는 폭 — 일부만 그리면 눌러도 되는지 알 수 없다.
    // **폭을 `slot_count` 에서 유도한다.** 숫자를 적어 두면 뷰를 하나 더할 때 이 테스트가 계약이 아니라
    // 옛 슬롯 수를 지키게 된다(실제로 3→4 에서 그렇게 깨졌다).
    const slots_px: u32 = @intCast(slot_cols * 8 * slot_count);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = slots_px - 4, .h = 18 }, 8, 0) == null);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = slots_px, .h = 18 }, 8, 0) != null);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 200, .h = 18 }, 0, 0) == null);
}

test "hit-test는 슬롯 안에서만 자리를 돌려준다" {
    const bar = Rect{ .x = 10, .y = 5, .w = 200, .h = 18 };
    try testing.expectEqual(@as(usize, 0), slotAtPoint(bar, 8, 12, 10).?);
    try testing.expectEqual(@as(usize, 1), slotAtPoint(bar, 8, 50, 10).?);
    // 슬롯 오른쪽 여백·바 위아래는 no-op이다.
    try testing.expect(slotAtPoint(bar, 8, 190, 10) == null);
    try testing.expect(slotAtPoint(bar, 8, 12, 4) == null);
    try testing.expect(slotAtPoint(bar, 8, 12, 23) == null);
    try testing.expect(slotAtPoint(.{ .x = 10, .y = 5, .w = 200, .h = 0 }, 8, 12, 5) == null);
}

test "동작 슬롯은 오른쪽 끝에 이어 붙고 뷰 슬롯과 겹치지 않는다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 320, .h = 18 };
    const a = actionRect(bar, 8, 2, 0).?;
    const b = actionRect(bar, 8, 2, 1).?;
    try testing.expectEqual(a.x + a.w, b.x); // 사이가 벌어지거나 겹치지 않는다
    try testing.expectEqual(bar.x + bar.w, b.x + b.w); // 마지막이 바 오른쪽 끝에 붙는다
    try testing.expectEqual(@as(u32, 32), a.w); // 뷰 슬롯과 같은 폭(4셀 × 8px)
    // 뷰 슬롯 마지막 자리보다 오른쪽이다 — 겹치면 두 판정이 같은 좌표를 두고 다툰다.
    const last_view = slotRect(bar, 8, slot_count - 1).?;
    try testing.expect(a.x >= last_view.x + last_view.w);
    try testing.expect(actionRect(bar, 8, 2, 2) == null);
    try testing.expect(actionRect(bar, 8, 0, 0) == null);
}

test "폭이 모자라면 동작을 하나도 그리지 않는다 — 뷰 전환이 먼저다" {
    // 뷰 전부 + 동작 2칸이 들어갈 폭이 필요하다. 값은 `slot_count` 에서 유도한다(위 테스트와 같은 이유).
    const need: u32 = @intCast(slot_cols * 8 * (slot_count + 2));
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = need - 1, .h = 18 }, 8, 2, 0) == null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = need, .h = 18 }, 8, 2, 0) != null);
    // 그 폭에서도 뷰 슬롯은 계속 그려진다(동작만 사라진다).
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = need - 1, .h = 18 }, 8, 0) != null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = 320, .h = 0 }, 8, 2, 0) == null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = 320, .h = 18 }, 0, 2, 0) == null);
}

test "동작 hit-test 는 그려지는 자리에서만 값을 돌려준다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 320, .h = 18 };
    const a = actionRect(bar, 8, 2, 0).?;
    try testing.expectEqual(@as(usize, 0), actionAtPoint(bar, 8, 2, a.x + 1, 25).?);
    try testing.expectEqual(@as(usize, 1), actionAtPoint(bar, 8, 2, a.x + a.w + 1, 25).?);
    // 뷰 스위처 자리·바 밖은 동작이 아니다.
    try testing.expect(actionAtPoint(bar, 8, 2, bar.x + 1, 25) == null);
    try testing.expect(actionAtPoint(bar, 8, 2, a.x + 1, 10) == null);
    // 안 그려지는 폭에서는 같은 좌표라도 눌리지 않는다.
    try testing.expect(actionAtPoint(.{ .x = 100, .y = 20, .w = 159, .h = 18 }, 8, 2, 250, 25) == null);
}

test "동작 슬롯은 **셀 격자**의 오른쪽 끝에 붙는다 — 바 픽셀 폭이 아니라" {
    // 도크 폭은 드래그로 정해져 셀 배수가 아닌 것이 보통이다(여기서는 셀 8px 에 폭 325px = 40셀 + 5px).
    // 아이콘은 40셀 격자에 그려지므로 마지막 동작 슬롯의 오른쪽 끝도 40셀 자리여야 한다.
    const bar = Rect{ .x = 0, .y = 0, .w = 325, .h = 18 };
    const last = actionRect(bar, 8, 2, 1).?;
    try testing.expectEqual(@as(u32, 320), last.x + last.w); // 40셀 × 8px — 남는 5px 는 격자 밖이다
    try testing.expect(last.x + last.w < bar.x + bar.w);
    // 그 자투리를 눌러도 동작이 아니다(그리지 않은 자리는 눌리지도 않는다).
    try testing.expect(actionAtPoint(bar, 8, 2, 322, 5) == null);
    try testing.expectEqual(@as(usize, 1), actionAtPoint(bar, 8, 2, 319, 5).?);
    // 폭이 셀 배수면 격자 끝 = 바 끝이라 예전 결과와 같다(회귀 방지).
    const aligned = Rect{ .x = 0, .y = 0, .w = 320, .h = 18 };
    const last_aligned = actionRect(aligned, 8, 2, 1).?;
    try testing.expectEqual(@as(u32, 320), last_aligned.x + last_aligned.w);
}
