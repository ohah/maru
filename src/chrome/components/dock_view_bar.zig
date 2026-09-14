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

/// 슬롯 하나의 **기본** 셀 수(테마가 pt 토큰을 안 줄 때 = tui). **아이콘이 2셀**(사이드바 에이전트 아이콘과
/// 같은 `width=2` — 합성 아이콘은 슬롯 크기에 맞춰 스케일되므로 2칸이면 또렷하고 크다)이고 좌우 여백 1셀씩이라
/// 4셀이다.
///
/// **상수를 직접 쓰지 말고 `Grid.slot_cols`를 쓴다.** 이것을 고정으로 쓰면 슬롯의 물리적 폭이 터미널 폰트를
/// 따라가고, 폰트를 키웠을 때 스위처가 통째로 사라진다(`tokens.Space.dock_view_slot_width_pt` 참조).
pub const default_slot_cols: u32 = 4;

/// 아이콘이 차지하는 셀 수(`DrawCell.width`)는 아래 `icon_cols`다. 슬롯 안에서 아이콘이 **어느 열에서
/// 시작하는지**는 상수가 아니라 `Grid.iconOffsetCols`가 정한다 — 상수(1)로 두었더니 슬롯이 좁아진
/// 경우에 `1 + icon_cols`가 슬롯 폭을 넘어 **아이콘이 이웃 슬롯을 침범했다**(적대적 검증 6회차가
/// 셀 폭 4~64 × scale 1000~3000 전수에서 실측으로 잡았다: `slot_cols = 2`일 때 3 > 2).
///
/// hit-test는 슬롯 전체를 대상으로 하므로 여백을 눌러도 전환된다 — 아이콘 픽셀만 눌러야 하는 UI는
/// 작을수록 짜증난다.
/// 아이콘이 차지하는 셀 수(`DrawCell.width`).
pub const icon_cols: u32 = 2;

/// 이 바가 쓰는 셀 격자. **셀 폭과 슬롯 칸 수를 한 자리에서 묶는다** — 렌더(열 번호)와 hit-test(픽셀)가
/// 같은 칸 수를 봐야 그린 자리와 눌리는 자리가 안 갈린다.
pub const Grid = struct {
    cell_width_px: u32,
    /// 슬롯 하나의 셀 수. `init`이 pt 목표폭에서 환산한다.
    slot_cols: u32,

    /// `slot_width_px`는 테마 pt 토큰을 backing px로 환산한 값이다(0이면 셀 파생 = `default_slot_cols`).
    ///
    /// 반올림으로 환산한다 — 내림이면 목표폭 바로 아래에서 한 칸이 통째로 빠져 아이콘 여백이 갑자기
    /// 사라진다. 그리고 **`icon_cols` 아래로는 안 내려간다**: 슬롯이 아이콘보다 좁으면 아이콘이 이웃 슬롯을
    /// 침범해 "보이는 자리 = 눌리는 자리"가 깨진다.
    pub fn init(cell_width_px: u32, slot_width_px: u32) Grid {
        if (cell_width_px == 0) return .{ .cell_width_px = 0, .slot_cols = 0 };
        const target = if (slot_width_px == 0) default_slot_cols * cell_width_px else slot_width_px;
        const rounded = (target + cell_width_px / 2) / cell_width_px;
        return .{ .cell_width_px = cell_width_px, .slot_cols = @max(icon_cols, rounded) };
    }

    /// 슬롯 안에서 아이콘이 시작하는 셀 오프셋. **슬롯 폭에서 파생해 가운데에 놓는다** — 상수로 두면
    /// 좁은 슬롯에서 아이콘이 이웃을 침범한다(위 `icon_cols` 주석의 실측). 기본 4칸에서는 `(4-2)/2 = 1`
    /// 이라 이 커밋 전과 **같은 자리**다.
    ///
    /// `slot_cols >= icon_cols`는 `init`이 보장하므로 포화 뺄셈의 0은 `slot_cols == icon_cols`일 때뿐이고,
    /// 그때 아이콘이 슬롯을 꽉 채운다.
    pub fn iconOffsetCols(self: Grid) u32 {
        return (self.slot_cols -| icon_cols) / 2;
    }
};

/// 슬롯 rect(없으면 null). 바가 접혔거나(높이 0) 폭이 모자라면 null이다. 폭이 모자랄 때 **일부만 그리지 않는다** —
/// 반쯤 잘린 스위처는 눌러도 되는지 알 수 없다.
pub fn slotRect(bar: Rect, grid: Grid, index: usize) ?Rect {
    if (index >= slot_count) return null;
    if (bar.h == 0 or bar.w == 0 or grid.cell_width_px == 0 or grid.slot_cols == 0) return null;
    const slot_w = grid.slot_cols * grid.cell_width_px;
    const total = slot_w * @as(u32, @intCast(slot_count));
    if (total > bar.w) return null;
    const offset: u32 = slot_w * @as(u32, @intCast(index));
    return .{ .x = bar.x + offset, .y = bar.y, .w = slot_w, .h = bar.h };
}

/// 좌표가 몇 번째 슬롯 위인지. 슬롯 밖(여백 포함)은 null이라 호출자가 no-op으로 둔다.
pub fn slotAtPoint(bar: Rect, grid: Grid, x: u32, y: u32) ?usize {
    if (y < bar.y or y >= bar.y + bar.h) return null;
    var index: usize = 0;
    while (index < slot_count) : (index += 1) {
        const rect = slotRect(bar, grid, index) orelse return null;
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
pub fn actionRect(bar: Rect, grid: Grid, count: usize, index: usize) ?Rect {
    if (index >= count or count == 0) return null;
    if (bar.h == 0 or bar.w == 0 or grid.cell_width_px == 0 or grid.slot_cols == 0) return null;
    // **오른쪽 끝은 바 픽셀 폭이 아니라 셀 격자의 끝이다.** 도크 폭은 드래그로 정해져 셀 배수가 아닌 것이
    // 보통이고, 아이콘은 셀 격자에 그려진다(`buildDockViewBarDrawList` 가 `cols = 폭 / 셀폭` 으로 받는다).
    // 픽셀 끝에 붙이면 눌리는 자리가 그린 자리보다 최대 한 셀 못 미치게 밀려, 아이콘 왼쪽을 눌러도 반응이
    // 없고 오른쪽 여백이 눌린다 — 왼쪽 정렬인 뷰 슬롯에는 없던, 오른쪽 정렬이 만든 함정이다.
    const start_col = actionStartCol(bar.w / grid.cell_width_px, grid, count) orelse return null;
    const col = start_col + grid.slot_cols * @as(u32, @intCast(index));
    return .{ .x = bar.x + col * grid.cell_width_px, .y = bar.y, .w = grid.slot_cols * grid.cell_width_px, .h = bar.h };
}

/// 동작 슬롯이 시작하는 **셀 열**(그릴 자리가 없으면 null). 렌더는 셀 격자에, hit-test 는 픽셀에 살지만
/// **자리를 정하는 식은 이것 하나다** — 두 벌이면 지금은 같은 값이어도 한쪽만 고쳐지는 날 어긋난다.
pub fn actionStartCol(cols: u32, grid: Grid, count: usize) ?u32 {
    if (count == 0 or grid.slot_cols == 0) return null;
    // 뷰 스위처와 겹치면 **하나도 그리지 않는다**. 반쯤 겹친 버튼은 무엇이 눌리는지 알 수 없고, 좁은 도크에서
    // 뷰 전환은 동작 버튼보다 먼저 지켜야 하는 기능이다(슬롯이 다 안 들어가면 아예 안 그리는 정책과 같은 결).
    const need = grid.slot_cols * @as(u32, @intCast(slot_count + count));
    if (cols < need) return null;
    return cols - grid.slot_cols * @as(u32, @intCast(count));
}

/// 좌표가 몇 번째 동작 슬롯 위인지. 동작이 안 그려지는 상황이면 null이라 호출자가 no-op으로 둔다 —
/// **보이지 않는 버튼은 눌리지도 않는다**(그리는 조건과 판정 조건이 같은 함수에서 나온다).
pub fn actionAtPoint(bar: Rect, grid: Grid, count: usize, x: u32, y: u32) ?usize {
    if (y < bar.y or y >= bar.y + bar.h) return null;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const rect = actionRect(bar, grid, count, index) orelse return null;
        if (x >= rect.x and x < rect.x + rect.w) return index;
    }
    return null;
}

const testing = std.testing;

/// 테스트가 쓰는 셀 파생 격자(테마 토큰 없음 = tui 경로). 옛 `slot_cols` 상수와 같은 4칸이다.
fn cellGrid(cell_width_px: u32) Grid {
    return Grid.init(cell_width_px, 0);
}

test "슬롯은 셀 정렬 폭으로 좌측부터 이어 붙는다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 180, .h = 18 };
    const g = cellGrid(8);
    const a = slotRect(bar, g, 0).?;
    const b = slotRect(bar, g, 1).?;
    try testing.expectEqual(@as(u32, 100), a.x);
    try testing.expectEqual(@as(u32, 32), a.w); // 4셀 × 8px
    try testing.expectEqual(a.x + a.w, b.x); // 사이가 벌어지거나 겹치지 않는다
    try testing.expectEqual(bar.h, a.h);
    try testing.expect(slotRect(bar, g, slot_count) == null);
}

test "바가 접혔거나 폭이 모자라면 슬롯을 하나도 그리지 않는다" {
    const g = cellGrid(8);
    // 높이 0(낮은 도크에서 접힘)
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, g, 0) == null);
    // 전체 슬롯이 다 안 들어가는 폭 — 일부만 그리면 눌러도 되는지 알 수 없다.
    // **폭을 `slot_count` 에서 유도한다.** 숫자를 적어 두면 뷰를 하나 더할 때 이 테스트가 계약이 아니라
    // 옛 슬롯 수를 지키게 된다(실제로 3→4 에서 그렇게 깨졌다).
    const slots_px: u32 = @intCast(g.slot_cols * 8 * slot_count);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = slots_px - 4, .h = 18 }, g, 0) == null);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = slots_px, .h = 18 }, g, 0) != null);
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = 200, .h = 18 }, cellGrid(0), 0) == null);
}

test "hit-test는 슬롯 안에서만 자리를 돌려준다" {
    const bar = Rect{ .x = 10, .y = 5, .w = 200, .h = 18 };
    const g = cellGrid(8);
    try testing.expectEqual(@as(usize, 0), slotAtPoint(bar, g, 12, 10).?);
    try testing.expectEqual(@as(usize, 1), slotAtPoint(bar, g, 50, 10).?);
    // 슬롯 오른쪽 여백·바 위아래는 no-op이다.
    try testing.expect(slotAtPoint(bar, g, 190, 10) == null);
    try testing.expect(slotAtPoint(bar, g, 12, 4) == null);
    try testing.expect(slotAtPoint(bar, g, 12, 23) == null);
    try testing.expect(slotAtPoint(.{ .x = 10, .y = 5, .w = 200, .h = 0 }, g, 12, 5) == null);
}

test "동작 슬롯은 오른쪽 끝에 이어 붙고 뷰 슬롯과 겹치지 않는다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 320, .h = 18 };
    const g = cellGrid(8);
    const a = actionRect(bar, g, 2, 0).?;
    const b = actionRect(bar, g, 2, 1).?;
    try testing.expectEqual(a.x + a.w, b.x); // 사이가 벌어지거나 겹치지 않는다
    try testing.expectEqual(bar.x + bar.w, b.x + b.w); // 마지막이 바 오른쪽 끝에 붙는다
    try testing.expectEqual(@as(u32, 32), a.w); // 뷰 슬롯과 같은 폭(4셀 × 8px)
    // 뷰 슬롯 마지막 자리보다 오른쪽이다 — 겹치면 두 판정이 같은 좌표를 두고 다툰다.
    const last_view = slotRect(bar, g, slot_count - 1).?;
    try testing.expect(a.x >= last_view.x + last_view.w);
    try testing.expect(actionRect(bar, g, 2, 2) == null);
    try testing.expect(actionRect(bar, g, 0, 0) == null);
}

test "폭이 모자라면 동작을 하나도 그리지 않는다 — 뷰 전환이 먼저다" {
    const g = cellGrid(8);
    // 뷰 전부 + 동작 2칸이 들어갈 폭이 필요하다. 값은 `slot_count` 에서 유도한다(위 테스트와 같은 이유).
    const need: u32 = @intCast(g.slot_cols * 8 * (slot_count + 2));
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = need - 1, .h = 18 }, g, 2, 0) == null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = need, .h = 18 }, g, 2, 0) != null);
    // 그 폭에서도 뷰 슬롯은 계속 그려진다(동작만 사라진다).
    try testing.expect(slotRect(.{ .x = 0, .y = 0, .w = need - 1, .h = 18 }, g, 0) != null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = 320, .h = 0 }, g, 2, 0) == null);
    try testing.expect(actionRect(.{ .x = 0, .y = 0, .w = 320, .h = 18 }, cellGrid(0), 2, 0) == null);
}

test "동작 hit-test 는 그려지는 자리에서만 값을 돌려준다" {
    const bar = Rect{ .x = 100, .y = 20, .w = 320, .h = 18 };
    const g = cellGrid(8);
    const a = actionRect(bar, g, 2, 0).?;
    try testing.expectEqual(@as(usize, 0), actionAtPoint(bar, g, 2, a.x + 1, 25).?);
    try testing.expectEqual(@as(usize, 1), actionAtPoint(bar, g, 2, a.x + a.w + 1, 25).?);
    // 뷰 스위처 자리·바 밖은 동작이 아니다.
    try testing.expect(actionAtPoint(bar, g, 2, bar.x + 1, 25) == null);
    try testing.expect(actionAtPoint(bar, g, 2, a.x + 1, 10) == null);
    // 안 그려지는 폭에서는 같은 좌표라도 눌리지 않는다.
    try testing.expect(actionAtPoint(.{ .x = 100, .y = 20, .w = 159, .h = 18 }, g, 2, 250, 25) == null);
}

test "동작 슬롯은 **셀 격자**의 오른쪽 끝에 붙는다 — 바 픽셀 폭이 아니라" {
    // 도크 폭은 드래그로 정해져 셀 배수가 아닌 것이 보통이다(여기서는 셀 8px 에 폭 325px = 40셀 + 5px).
    // 아이콘은 40셀 격자에 그려지므로 마지막 동작 슬롯의 오른쪽 끝도 40셀 자리여야 한다.
    const bar = Rect{ .x = 0, .y = 0, .w = 325, .h = 18 };
    const g = cellGrid(8);
    const last = actionRect(bar, g, 2, 1).?;
    try testing.expectEqual(@as(u32, 320), last.x + last.w); // 40셀 × 8px — 남는 5px 는 격자 밖이다
    try testing.expect(last.x + last.w < bar.x + bar.w);
    // 그 자투리를 눌러도 동작이 아니다(그리지 않은 자리는 눌리지도 않는다).
    try testing.expect(actionAtPoint(bar, g, 2, 322, 5) == null);
    try testing.expectEqual(@as(usize, 1), actionAtPoint(bar, g, 2, 319, 5).?);
    // 폭이 셀 배수면 격자 끝 = 바 끝이라 예전 결과와 같다(회귀 방지).
    const aligned = Rect{ .x = 0, .y = 0, .w = 320, .h = 18 };
    const last_aligned = actionRect(aligned, g, 2, 1).?;
    try testing.expectEqual(@as(u32, 320), last_aligned.x + last_aligned.w);
}

// --- 슬롯 폭을 터미널 폰트에서 떼어낸 계약(`tokens.Space.dock_view_slot_width_pt`) ---

test "Grid: 토큰이 없으면 셀 파생 4칸 — tui 경로는 이 커밋 전과 같다" {
    try testing.expectEqual(default_slot_cols, cellGrid(8).slot_cols);
    try testing.expectEqual(default_slot_cols, cellGrid(29).slot_cols);
    // 셀이 0이면 아무것도 못 그린다(호출자가 null로 받는다).
    try testing.expectEqual(@as(u32, 0), cellGrid(0).slot_cols);
}

test "Grid: 기본 폰트의 칸 수는 «안 바뀐다» — 골든이 지키는 외형" {
    // 실측(2026-09-15, rich 토큰 32pt): font 14pt 에서 1× 셀 8px, 2× 셀 17px.
    try testing.expectEqual(@as(u32, 4), Grid.init(8, 32).slot_cols); // 1×
    try testing.expectEqual(@as(u32, 4), Grid.init(17, 64).slot_cols); // 2×
}

test "Grid: 폰트를 키워도 스위처가 «사라지지 않는다» — 이 변경의 이유" {
    // 실측: font 24pt 에서 1× 셀 14px/바 180px, 2× 셀 29px/바 360px.
    // 옛 고정 4칸이면 요구 폭이 224px·464px 로 바를 넘어 `slotRect` 가 null 이었다(스위처 통째로 실종).
    const bar_1x = Rect{ .x = 0, .y = 0, .w = 180, .h = 40 };
    const bar_2x = Rect{ .x = 0, .y = 0, .w = 360, .h = 80 };
    try testing.expect(slotRect(bar_1x, cellGrid(14), 0) == null); // 옛 동작(회귀 대조군)
    try testing.expect(slotRect(bar_2x, cellGrid(29), 0) == null);

    const g_1x = Grid.init(14, 32);
    const g_2x = Grid.init(29, 64);
    try testing.expectEqual(@as(u32, 2), g_1x.slot_cols);
    try testing.expectEqual(@as(u32, 2), g_2x.slot_cols);
    // **마지막 슬롯까지** 들어가야 한다 — 첫 칸만 보고 통과시키면 오른쪽이 잘린 것을 못 잡는다.
    const last_1x = slotRect(bar_1x, g_1x, slot_count - 1).?;
    const last_2x = slotRect(bar_2x, g_2x, slot_count - 1).?;
    try testing.expect(last_1x.x + last_1x.w <= bar_1x.x + bar_1x.w);
    try testing.expect(last_2x.x + last_2x.w <= bar_2x.x + bar_2x.w);
}

test "Grid: 슬롯은 아이콘보다 좁아지지 않는다 — 좁으면 이웃을 침범한다" {
    // 셀이 목표폭보다 크면 반올림이 1칸(또는 0칸)을 내는데, 아이콘은 `icon_cols` 칸을 차지한다.
    try testing.expectEqual(icon_cols, Grid.init(64, 32).slot_cols);
    try testing.expectEqual(icon_cols, Grid.init(1000, 32).slot_cols);
}

test "Grid: 아이콘은 «어떤 셀 폭에서도» 자기 슬롯을 안 넘는다 — 그린 자리 = 눌리는 자리" {
    // **이 판정이 이 커밋의 결함 하나를 실제로 잡았다.** 아이콘 시작 열을 상수 1로 두었을 때
    // `slot_cols = 2`(폰트 24pt)에서 `1 + 2 = 3 > 2` 로 아이콘이 이웃 슬롯을 침범했다. 한 조합만
    // 보는 판정으로는 안 잡힌다 — 기본 폰트(4칸)에서는 성립하기 때문이다. 그래서 **전수로 센다**.
    var cell: u32 = 1;
    while (cell <= 64) : (cell += 1) {
        var slot_px: u32 = 0;
        while (slot_px <= 128) : (slot_px += 8) {
            const grid = Grid.init(cell, slot_px);
            // 오프셋 + 아이콘 폭이 슬롯 안이어야 한다(렌더는 이 열에 `icon_cols` 칸짜리 셀을 놓는다).
            try testing.expect(grid.iconOffsetCols() + icon_cols <= grid.slot_cols);
            // 그리고 그 아이콘 픽셀을 누르면 **같은 슬롯**이 나와야 한다.
            const bar = Rect{ .x = 100, .y = 0, .w = grid.slot_cols * cell * @as(u32, @intCast(slot_count)) + 7, .h = 40 };
            var i: usize = 0;
            while (i < slot_count) : (i += 1) {
                const rect = slotRect(bar, grid, i) orelse return error.SlotMissing;
                const icon_x0 = bar.x + (@as(u32, @intCast(i)) * grid.slot_cols + grid.iconOffsetCols()) * cell;
                const icon_x1 = icon_x0 + icon_cols * cell;
                try testing.expect(icon_x0 >= rect.x);
                try testing.expect(icon_x1 <= rect.x + rect.w);
                try testing.expectEqual(i, slotAtPoint(bar, grid, icon_x0, 10).?);
                try testing.expectEqual(i, slotAtPoint(bar, grid, icon_x1 - 1, 10).?);
            }
        }
    }
}

test "Grid: 환산은 내림이 아니라 반올림이다" {
    // 목표 32px, 셀 7px → 32/7 = 4.57. 내림이면 4칸(28px)이라 목표에서 4px 모자라고,
    // 반올림이면 5칸(35px)으로 목표에 더 가깝다.
    try testing.expectEqual(@as(u32, 5), Grid.init(7, 32).slot_cols);
    // 경계: 셀 9px·목표 40px 는 4.44 라 내려간다(올림이 아니라 «반올림» 임을 고정).
    try testing.expectEqual(@as(u32, 4), Grid.init(9, 40).slot_cols);
}
