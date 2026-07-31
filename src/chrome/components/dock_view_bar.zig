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
pub const slot_count: usize = 3;

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
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 92, .h = 18 }, 8, 0) == null);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 96, .h = 18 }, 8, 0) != null); // 3슬롯 × 32px = 96
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
