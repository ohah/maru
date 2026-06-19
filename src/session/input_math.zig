//! L2 session core — 순수 입력/재정렬 수학(OS·platform 무관). 휠/트랙패드·페이지 스크롤 환산과 탭 재정렬
//! 인덱스 수학을 모은다. platform/macos/app_session에서 추출했다(docs/layering-and-portability.md §3 — 2차
//! 추출, "입력 수학(순수)" 그룹). 중립 입력 타입(terminal.input.Key)만 의존하고 platform/pty를 모른다 —
//! tests/boundary/imports.zig가 강제. 순수 함수라 OS·렌더 없이 단위 테스트로 동작을 고정한다.

const std = @import("std");
const terminal = @import("../terminal.zig");

/// cell 높이 미상(초기 프레임 등)일 때 쓰는 기본 cell 높이(px). 세션 cell 메트릭의 중립 기본값 — 휠 환산과
/// 플랫폼 프레임 빌더가 공유한다(platform 쪽은 alias로 참조). 단일 출처.
pub const placeholder_cell_height_px: u32 = 24;

/// 탭을 from→to로 옮긴 뒤 active_tab을 보정한다. 드래그한 탭이 active면 to를 따라가고, 사이 인덱스는
/// 이동 방향대로 한 칸 밀린다(from<to면 그 사이가 -1, to<from이면 +1). 그 밖은 불변. 순수 함수.
pub fn adjustActiveForMove(active: usize, from: usize, to: usize) usize {
    if (active == from) return to;
    if (from < to and active > from and active <= to) return active - 1;
    if (to < from and active >= to and active < from) return active + 1;
    return active;
}

/// 드래그 재정렬에서 목표 인덱스를 옮기는 탭과 같은 그룹(고정/비고정)으로 clamp한다. 베이스/결정: 사이드바는
/// 고정 탭을 항상 배열 앞쪽 `[0, pinned_count)`에 모으는 불변식을 둔다(브라우저 탭 고정의 사실상 표준 — 고정/비고정이
/// 안 섞임). 옮기는 탭이 고정이면(`moving_pinned`) 목표는 고정 영역 `[0, pinned_count-1]`로, 비고정이면 비고정 영역
/// `[pinned_count, len-1]`로 가둔다. 그래서 비고정을 위로 끌어도 고정 영역을 침범하지 않고, 고정을 아래로 끌어도 비고정
/// 영역으로 안 간다. 호출자는 `pinned_count <= len`·`len >= 1`을 보장하고, 불변식상 옮기는 탭이 고정이면 pinned_count≥1,
/// 비고정이면 len>pinned_count다. 순수 함수라 OS·렌더 없이 단위 테스트로 경계를 고정한다.
pub fn clampMoveToGroup(to: usize, moving_pinned: bool, pinned_count: usize, len: usize) usize {
    if (moving_pinned) {
        // 고정 영역 [0, pinned_count). pinned_count는 from(고정)이 있으니 ≥1.
        const hi = pinned_count - 1;
        return @min(to, hi);
    }
    // 비고정 영역 [pinned_count, len). from(비고정)이 있으니 len > pinned_count.
    return std.math.clamp(to, pinned_count, len - 1);
}

/// 슬라이스에서 from의 원소를 to로 옮긴다(사이 원소는 회전으로 한 칸 밀림). std.mem.rotate라 무할당
/// in-place — 실패 불가. from==to면 무동작. 호출자는 from/to가 범위 안임을 보장한다.
pub fn rotateMove(comptime T: type, items: []T, from: usize, to: usize) void {
    if (from < to) {
        std.mem.rotate(T, items[from .. to + 1], 1); // 좌로 1: from이 끝(to)으로
    } else if (from > to) {
        std.mem.rotate(T, items[to .. from + 1], from - to); // from이 앞(to)으로
    }
}

/// 탭 하나를 닫은 뒤 새 active_tab 인덱스. 닫은 게 active보다 앞이면 한 칸 당기고(인덱스가 밀림),
/// 그래도 새 길이를 넘으면 마지막으로 clamp한다(active 자체나 마지막 탭을 닫은 경우). new_len은 닫은
/// 뒤 길이(≥1 — 마지막 한 개를 닫는 경우는 호출자가 따로 처리). 순수 함수라 OS 무관 단위 테스트.
pub fn reselectAfterClose(closed_index: usize, active: usize, new_len: usize) usize {
    var a = active;
    if (closed_index < a) a -= 1;
    if (a >= new_len) a = new_len - 1;
    return a;
}

/// 휠/트랙패드 델타(포인트 또는 줄)를 정수 줄 수로 바꾼다. 정밀(트랙패드) 델타는 실제 cell 높이를
/// scale로 나눈 한 줄 포인트로 환산하고, 1줄 미만 잔여분은 accum에 누적한다 — round로 버리면
/// 천천히 굴릴 때 무반응이 된다. NaN/∞는 무시하고 누적은 ±1000줄로 clamp한다(trap 방지).
pub fn wheelDeltaToLines(accum: *f64, delta_y: f64, precise: bool, cell_height_px: u32, scale_milli: u32) i32 {
    if (!std.math.isFinite(delta_y)) return 0;
    var lines_f: f64 = delta_y;
    if (precise) {
        const scale: f64 = @as(f64, @floatFromInt(scale_milli)) / 1000.0;
        const ch_px: f64 = @floatFromInt(if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px);
        const line_pts: f64 = if (scale > 0) ch_px / scale else ch_px;
        if (line_pts > 0) lines_f = delta_y / line_pts;
    }
    accum.* = std.math.clamp(accum.* + lines_f, -1000.0, 1000.0);
    const whole: f64 = std.math.trunc(accum.*);
    accum.* -= whole;
    return @intFromFloat(whole);
}

/// 메인 화면에서 PageUp/PageDown를 스크롤백 페이지 스크롤로 돌릴 때의 페이지 델타(+1=위/과거, -1=아래/현재).
/// scroll_mode(input.page-keys=scroll)가 아니거나 alt 화면이거나 page 키가 아니면 0 — 그땐 일반 인코딩 경로로
/// 보내 앱(vim/less)이 \e[5~/\e[6~로 페이징하거나 셸이 그대로 받는다. 기본(passthrough)은 xterm/Ghostty와
/// 일치, scroll은 Terminal.app/iTerm2식.
pub fn pageScrollDelta(scroll_mode: bool, alt_active: bool, key: terminal.input.Key) i32 {
    if (!scroll_mode or alt_active) return 0;
    return switch (key) {
        .page_up => 1,
        .page_down => -1,
        else => 0,
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 추출 전 app_session.zig에 있던 단위 테스트를 코드와 함께 옮겼다(순수 함수라 OS 무관).

test "wheelDeltaToLines accumulates sub-line trackpad deltas instead of dropping them" {
    var accum: f64 = 0;
    // cell 34px @2.0x -> 한 줄 17pt. 6pt씩 천천히 굴리면 3번째에 1줄이 나와야 한다(이전엔 전부 0).
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 1), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    // 비정밀(휠)은 델타가 곧 줄 수.
    accum = 0;
    try std.testing.expectEqual(@as(i32, 3), wheelDeltaToLines(&accum, 3, false, 34, 2000));
    try std.testing.expectEqual(@as(i32, -2), wheelDeltaToLines(&accum, -2, false, 34, 2000));
    // NaN/∞는 무시.
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, std.math.nan(f64), true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, std.math.inf(f64), false, 34, 2000));
}

test "wheelDeltaToLines drops sub-line residue when the scroll direction flips" {
    var accum: f64 = 0;
    // 위로 0.9줄 잔여를 만든다(6pt×2 @ 17pt/줄 — scrollWheel의 방향 리셋과 짝).
    _ = wheelDeltaToLines(&accum, 6, true, 34, 2000);
    _ = wheelDeltaToLines(&accum, 6, true, 34, 2000);
    try std.testing.expect(accum > 0.5);
    // 방향 반전 잔여 리셋은 플랫폼 scrollWheel이 수행한다 — 여기선 그 계약(잔여가 반대 틱을 상쇄하면
    // 첫 반응이 사라짐)을 수치로 고정한다: 리셋 없이 -6pt를 주면 0줄이 나온다(굼뜬 반전).
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, -6, true, 34, 2000));
}

test "reselectAfterClose shifts active for earlier closes and clamps for active/last closes" {
    // 닫은 게 active보다 앞 → 인덱스가 밀려 active 한 칸 당김.
    try std.testing.expectEqual(@as(usize, 1), reselectAfterClose(0, 2, 3));
    // active(=마지막)를 닫음 → 이전 탭으로 clamp.
    try std.testing.expectEqual(@as(usize, 1), reselectAfterClose(2, 2, 2));
    // active(중간)를 닫음 → 그 자리로 온 다음 탭이 같은 인덱스(불변).
    try std.testing.expectEqual(@as(usize, 1), reselectAfterClose(1, 1, 2));
    // 닫은 게 active보다 뒤 → active 불변.
    try std.testing.expectEqual(@as(usize, 1), reselectAfterClose(2, 1, 2));
    // 첫 탭(active 0) 닫고 하나 남음 → 0.
    try std.testing.expectEqual(@as(usize, 0), reselectAfterClose(0, 0, 1));
}

test "adjustActiveForMove follows the dragged tab and shifts in-between indices" {
    try std.testing.expectEqual(@as(usize, 2), adjustActiveForMove(0, 0, 2)); // active=드래그 탭 → to
    try std.testing.expectEqual(@as(usize, 0), adjustActiveForMove(1, 0, 2)); // 사이(from<to) → -1
    try std.testing.expectEqual(@as(usize, 0), adjustActiveForMove(2, 2, 0)); // active=드래그 탭 → to
    try std.testing.expectEqual(@as(usize, 1), adjustActiveForMove(0, 2, 0)); // 사이(to<from) → +1
    try std.testing.expectEqual(@as(usize, 1), adjustActiveForMove(1, 1, 1)); // from==to 무동작
}

test "clampMoveToGroup keeps a drag target inside the dragged tab's pin group" {
    // pinned 2 + unpinned 2 (len=4, pinned_count=2).
    // 비고정 탭을 위(0)로 끌어도 비고정 영역 [2,3)으로만 — 고정 영역 침범 금지.
    try std.testing.expectEqual(@as(usize, 2), clampMoveToGroup(0, false, 2, 4));
    try std.testing.expectEqual(@as(usize, 2), clampMoveToGroup(1, false, 2, 4));
    try std.testing.expectEqual(@as(usize, 2), clampMoveToGroup(2, false, 2, 4)); // 이미 경계
    try std.testing.expectEqual(@as(usize, 3), clampMoveToGroup(3, false, 2, 4)); // 제자리
    // 고정 탭을 아래로 끌어도 고정 영역 [0,2)로만 — 비고정 영역 침범 금지.
    try std.testing.expectEqual(@as(usize, 1), clampMoveToGroup(3, true, 2, 4));
    try std.testing.expectEqual(@as(usize, 1), clampMoveToGroup(2, true, 2, 4));
    try std.testing.expectEqual(@as(usize, 0), clampMoveToGroup(0, true, 2, 4)); // 제자리
    try std.testing.expectEqual(@as(usize, 1), clampMoveToGroup(1, true, 2, 4)); // 고정끼리 swap
    // pinned 0(전부 비고정): 비고정 영역 [0, len)이라 clamp가 [0,len-1].
    try std.testing.expectEqual(@as(usize, 0), clampMoveToGroup(0, false, 0, 3));
    try std.testing.expectEqual(@as(usize, 2), clampMoveToGroup(9, false, 0, 3));
    // 전부 고정(pinned_count==len): 고정 영역 [0, len-1].
    try std.testing.expectEqual(@as(usize, 2), clampMoveToGroup(9, true, 3, 3));
}

test "rotateMove moves an element from→to, rotating the span between" {
    var fwd = [_]u8{ 'A', 'B', 'C', 'D' };
    rotateMove(u8, &fwd, 0, 2); // A를 2로 → B,C,A,D
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'B', 'C', 'A', 'D' }, &fwd);
    var bwd = [_]u8{ 'A', 'B', 'C', 'D' };
    rotateMove(u8, &bwd, 3, 1); // D를 1로 → A,D,B,C
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'A', 'D', 'B', 'C' }, &bwd);
}

test "pageScrollDelta: scroll mode + main screen scrolls; passthrough/alt sends to app" {
    // scroll 모드 + 메인 화면: PageUp=위(+1), PageDown=아래(-1) 스크롤.
    try std.testing.expectEqual(@as(i32, 1), pageScrollDelta(true, false, .page_up));
    try std.testing.expectEqual(@as(i32, -1), pageScrollDelta(true, false, .page_down));
    // scroll 모드라도 alt 화면(vim/less): 0 — 앱이 \e[5~/\e[6~로 페이징.
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(true, true, .page_up));
    // passthrough(opt-in, xterm/Ghostty): 메인 화면이어도 0 — \e[5~/\e[6~를 그대로 PTY로.
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(false, false, .page_up));
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(false, false, .page_down));
    // page 키가 아니면 무조건 0(일반 키 경로).
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(true, false, .{ .function = 5 }));
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(true, false, .home));
    try std.testing.expectEqual(@as(i32, 0), pageScrollDelta(true, false, .{ .char = 'a' }));
}
