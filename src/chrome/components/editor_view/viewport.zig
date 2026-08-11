//! 문서의 **어느 부분이 화면에 있는가** — 스크롤 위치와 보이는 행 범위.
//!
//! [native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md) §4의 세로 축이며, N1에서는 랩·접힘이 없어
//! 시각 행 하나가 논리 줄 하나다. 그 단계들이 붙으면 **입력이 "논리 줄 수"에서 "시각 행 수"로만
//! 바뀌고** 이 계산은 그대로다 — 그래서 여기서는 단위를 `rows`로 부르고 줄이라고 하지 않는다.
//!
//! **컬링이 목적이다.** 100만 줄 문서에서 보이는 것은 수십 행뿐이므로, 그 범위 밖은 draw op을
//! 만들지 않는다. §3.2가 경고한 것처럼 **렌더 범위와 연산 범위를 혼동하지 않는다** — 이 모듈은
//! 그리는 범위만 답하고, 복사·삭제는 언제나 모델 전체에 작용한다.

const std = @import("std");

/// 스크롤 상태와 뷰 크기.
pub const Viewport = struct {
    /// 맨 위에 보이는 행(0-based). 세로 스크롤 위치다.
    first_row: usize = 0,
    /// **가로 스크롤 위치**(§4) — 본문을 이 열부터 그린다. `first_row`와 짝이며 gutter에는 적용되지
    /// 않는다(줄 번호·diff 색 띠는 밀리면 안 된다).
    ///
    /// 최대 범위(`가장 긴 줄의 폭 − 뷰 폭`)와 그 clamp는 **여기 없다** — 가장 긴 줄의 폭이 §2의
    /// L2 폭 합 캐시에서 오는데 그 캐시가 아직 없다. 보이는 줄만 보고 정하면 스크롤할 때마다 범위가
    /// 변해 스크롤바가 요동치므로, 근사하지 않고 그 캐시가 생기는 슬라이스로 미룬다.
    first_col: u16 = 0,
    /// 화면에 들어가는 행 수.
    rows: u16,

    /// 마지막으로 보이는 행 다음(exclusive). 문서 끝을 넘지 않는다.
    pub fn endRow(self: Viewport, total_rows: usize) usize {
        return @min(total_rows, self.first_row + self.rows);
    }

    /// 실제로 그릴 행 수. 문서가 화면보다 짧으면 `rows`보다 작다.
    pub fn visibleRows(self: Viewport, total_rows: usize) u16 {
        const end = self.endRow(total_rows);
        if (end <= self.first_row) return 0;
        return @intCast(end - self.first_row);
    }

    /// 이 행이 화면에 있는가.
    pub fn containsRow(self: Viewport, row: usize) bool {
        return row >= self.first_row and row < self.first_row + self.rows;
    }

    /// 행을 시각 행 인덱스(뷰포트 기준 0부터)로. 화면 밖이면 null.
    pub fn visualRow(self: Viewport, row: usize) ?u16 {
        if (!self.containsRow(row)) return null;
        return @intCast(row - self.first_row);
    }
};

/// 스크롤이 갈 수 있는 최대 위치.
///
/// **마지막 줄이 맨 위에 올 때까지 스크롤된다** — 문서 끝에서 화면이 한 줄만 남는 것이 아니라,
/// `total_rows - rows`에서 멈춰 **마지막 화면이 꽉 찬다**. 편집기 관례이며, 이렇게 하지 않으면
/// 문서 끝에서 빈 화면이 크게 남는다.
///
/// 문서가 화면보다 짧으면 0이다(스크롤할 것이 없다).
pub fn maxFirstRow(total_rows: usize, rows: u16) usize {
    if (total_rows <= rows) return 0;
    return total_rows - rows;
}

/// 스크롤 위치를 유효 범위로 clamp한다.
///
/// **문서가 줄어들 때가 진짜 이유다.** 긴 파일을 끝까지 스크롤한 뒤 내용이 짧아지면 `first_row`가
/// 문서 밖을 가리켜 빈 화면이 된다. 편집·되돌리기·외부 변경 뒤에 이 함수를 통과시킨다.
pub fn clampFirstRow(first_row: usize, total_rows: usize, rows: u16) usize {
    return @min(first_row, maxFirstRow(total_rows, rows));
}

/// caret이 화면에 들어오도록 스크롤을 조정한다 — **최소한만 움직인다**.
///
/// 위로 벗어나면 그 행이 맨 위에, 아래로 벗어나면 맨 아래에 오게 한다. 이미 보이면 **그대로 둔다** —
/// 커서가 화면 안에 있는데 스크롤이 움직이면 읽던 자리를 잃는다.
///
/// `margin`은 위아래로 남길 여유 행이다. 커서가 화면 가장자리에 딱 붙으면 다음 줄이 안 보여
/// 방향키를 누를 때마다 스크롤이 따라온다. VSCode의 `cursorSurroundingLines`에 대응한다.
pub fn scrollToRow(current_first: usize, row: usize, rows: u16, total_rows: usize, margin: u16) usize {
    if (rows == 0) return current_first;

    // margin이 화면 절반을 넘으면 위아래 요구가 서로 모순된다(둘 다 만족시킬 수 없다).
    // 그때는 커서를 화면 중앙에 두는 것이 그 의도에 가장 가깝다.
    const effective_margin = @min(margin, (rows - 1) / 2);

    var first = current_first;

    // 위로 벗어남: 그 행이 margin만큼 아래에 오도록.
    if (row < first + effective_margin) {
        first = row -| effective_margin;
    }

    // 아래로 벗어남: 그 행이 margin만큼 위에 오도록.
    const last_wanted = first + rows -| 1;
    if (row + effective_margin > last_wanted) {
        const wanted_first = (row + effective_margin + 1) -| rows;
        first = wanted_first;
    }

    return clampFirstRow(first, total_rows, rows);
}

const testing = std.testing;

test "문서가 화면보다 짧으면 있는 만큼만 보인다" {
    const vp = Viewport{ .first_row = 0, .rows = 40 };
    try testing.expectEqual(@as(u16, 12), vp.visibleRows(12));
    try testing.expectEqual(@as(usize, 12), vp.endRow(12));
}

test "문서가 화면보다 길면 화면 크기만큼 보인다" {
    const vp = Viewport{ .first_row = 0, .rows = 40 };
    try testing.expectEqual(@as(u16, 40), vp.visibleRows(1000));
    try testing.expectEqual(@as(usize, 40), vp.endRow(1000));
}

test "스크롤된 뷰포트는 끝에서 잘린다" {
    const vp = Viewport{ .first_row = 990, .rows = 40 };
    try testing.expectEqual(@as(u16, 10), vp.visibleRows(1000));
    try testing.expectEqual(@as(usize, 1000), vp.endRow(1000));
}

test "visualRow: 화면 밖은 null이다" {
    const vp = Viewport{ .first_row = 100, .rows = 10 };

    try testing.expectEqual(@as(?u16, null), vp.visualRow(99));
    try testing.expectEqual(@as(?u16, 0), vp.visualRow(100));
    try testing.expectEqual(@as(?u16, 9), vp.visualRow(109));
    try testing.expectEqual(@as(?u16, null), vp.visualRow(110));
}

test "maxFirstRow: 마지막 화면이 꽉 찬다 — 끝에서 빈 화면이 남지 않는다" {
    // 100줄 문서, 40행 화면 → 60에서 멈춰 마지막 화면이 60~99로 꽉 찬다.
    try testing.expectEqual(@as(usize, 60), maxFirstRow(100, 40));
    // 문서가 화면보다 짧으면 스크롤할 것이 없다.
    try testing.expectEqual(@as(usize, 0), maxFirstRow(10, 40));
    try testing.expectEqual(@as(usize, 0), maxFirstRow(40, 40));
}

test "clampFirstRow: 문서가 줄어들면 스크롤이 따라 줄어든다 — 빈 화면 방지" {
    // 1000줄을 끝까지 봤는데 문서가 50줄로 줄었다.
    try testing.expectEqual(@as(usize, 10), clampFirstRow(960, 50, 40));
    // 이미 유효하면 그대로.
    try testing.expectEqual(@as(usize, 5), clampFirstRow(5, 100, 40));
}

test "scrollToRow: 이미 보이면 움직이지 않는다 — 읽던 자리를 잃지 않는다" {
    // 화면 100~139, 커서 120.
    try testing.expectEqual(@as(usize, 100), scrollToRow(100, 120, 40, 1000, 0));
}

test "scrollToRow: 위로 벗어나면 그 행이 맨 위에 온다" {
    try testing.expectEqual(@as(usize, 50), scrollToRow(100, 50, 40, 1000, 0));
}

test "scrollToRow: 아래로 벗어나면 그 행이 맨 아래에 온다 — 최소한만 움직인다" {
    // 화면 100~139, 커서 150 → 111~150이 되어야 한다(150이 마지막 행).
    try testing.expectEqual(@as(usize, 111), scrollToRow(100, 150, 40, 1000, 0));
}

test "scrollToRow: margin이 커서 주위에 여유를 남긴다" {
    // 화면 100~139, 커서 102, margin 3 → 커서 위로 3행이 필요하므로 99로 올라간다.
    try testing.expectEqual(@as(usize, 99), scrollToRow(100, 102, 40, 1000, 3));
    // 커서 137, margin 3 → 아래로 3행이 필요하므로 101로 내려간다.
    try testing.expectEqual(@as(usize, 101), scrollToRow(100, 137, 40, 1000, 3));
}

test "scrollToRow: 문서 처음에서는 margin이 있어도 음수로 가지 않는다" {
    try testing.expectEqual(@as(usize, 0), scrollToRow(0, 1, 40, 1000, 5));
}

test "scrollToRow: 문서 끝을 넘지 않는다" {
    // 100줄 문서에서 마지막 줄로 가도 maxFirstRow(60)을 넘지 않는다.
    try testing.expectEqual(@as(usize, 60), scrollToRow(0, 99, 40, 100, 5));
}

test "scrollToRow: margin이 화면 절반을 넘으면 모순이라 중앙에 가깝게 둔다" {
    // 화면 5행에 margin 10 — 위아래 요구를 둘 다 만족시킬 수 없다. 죽거나 튀지 않아야 한다.
    const r = scrollToRow(0, 50, 5, 1000, 10);
    try testing.expect(r <= 50);
    try testing.expect(50 < r + 5); // 커서가 화면 안에 있다
}

test "scrollToRow: 화면이 0행이면 움직이지 않는다 — 0으로 나누지 않는다" {
    try testing.expectEqual(@as(usize, 7), scrollToRow(7, 100, 0, 1000, 2));
}

test "scrollToRow: 한 행짜리 화면" {
    try testing.expectEqual(@as(usize, 50), scrollToRow(0, 50, 1, 1000, 0));
    // margin이 있어도 한 행에서는 효과가 없어야 한다((rows-1)/2 == 0).
    try testing.expectEqual(@as(usize, 50), scrollToRow(0, 50, 1, 1000, 3));
}
