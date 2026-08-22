//! 편집기 뷰의 **가로 영역 분할** — gutter와 본문이 어디서 시작하고 얼마나 넓은가.
//!
//! 계약은 [native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md) §4.1이고, 배치는 Monaco의 누적 계산을
//! 그대로 따른다(왼쪽부터 진단 → 줄 번호 → decorations → 본문). Monaco는 px로 계산하지만 우리 gutter는
//! **본문과 같은 셀 격자**에 서므로(§2.0) 여기서는 전부 **셀 수**로 센다 — Monaco도 `lineDecorationsWidth`에
//! `"2ch"` 같은 문자 폭 배수를 허용하므로 이는 이식상의 타협이 아니라 같은 개념의 다른 표현이다.
//!
//! **왜 `gutter.zig`와 별도인가**: 이 파일은 "어디에"만 답하고 `gutter.zig`는 "무엇을 그리나"에 답한다.
//! [chrome-strategy.md](../../../../docs/chrome-strategy.md) §5.4가 그리기와 hit-test가 한 레이아웃 소스를
//! 공유할 것을 요구하므로, 두 소비자가 같은 이 계산을 읽는다.

const std = @import("std");

/// Monaco `lineNumbersMinChars` 기본값과 같다. 짧은 파일에서 gutter 폭이 흔들리지 않게 하는 장치다 —
/// 이것이 없으면 9줄에서 10줄로 넘어갈 때 본문 전체가 한 칸 밀린다.
pub const min_line_number_cells: u16 = 5;

/// 줄 번호 오른쪽 여백(본문과 붙지 않게). Monaco `lineDecorationsWidth` 기본 10px에 대응하는 자리다.
pub const content_gap_cells: u16 = 1;

/// 접기 화살표가 쓰는 폭. Monaco가 접기를 켤 때만 `+16px`를 더하는 것과 같이 **켜졌을 때만** 쓴다.
///
/// **한 셀이 아니라 두 셀이다.** 초판은 1셀이었고 화살표가 그 유일한 칸에 섰는데, 줄 번호가
/// **우측 정렬**이라(`gutter.build`) 번호의 마지막 자리와 화살표가 늘 맞붙었다 — 실제 앱에서
/// *"숫자랑 너무 붙어 있다"*는 지적을 받았다(2026-08-22). 화살표를 이 span의 **오른쪽 칸**에
/// 세우면(`foldMarkCol`) 왼쪽 칸이 번호와의 여백이 되고, 오른쪽으로는 `content_gap_cells`가
/// 이미 한 칸을 두므로 **양옆이 한 칸씩** 균형을 이룬다. Monaco의 `16px`(≈2ch)와도 같은 값이다.
///
/// 넓힌 값어치가 하나 더 있다: 화살표 클릭이 **span 전체**를 받으므로(§4.1f 포인터 경로) 누를
/// 자리가 두 배가 된다. 1셀(≈8px)은 포인터로 맞히기에 좁다.
pub const folding_cells: u16 = 2;

/// gutter 맨 왼쪽 여백. Monaco의 **glyph margin에 대응하는 자리**이며, 우리는 디버거 대신 진단 마커가
/// 첫 소비자다(§4.1).
///
/// **N1에서 아무것도 그리지 않아도 자리는 잡는다.** 이유가 둘이다.
/// ⑴ Monaco는 `glyphMargin`이 기본 켜짐이라 줄 번호가 `lineNumbersLeft = glyphMarginLeft + glyphMarginWidth`만큼
///    밀려 있다. 이 자리를 비우면 줄 번호가 창 왼쪽 끝에 딱 붙어 VSCode와 다르게 보인다 —
///    **실제로 첫 캡처가 그렇게 나왔고**, 그것이 이 상수가 생긴 이유다.
/// ⑵ 처음부터 자리를 잡아 두면 N4에서 진단이 켜져도 **본문이 밀리지 않는다.** 나중에 넓히는 쪽이
///    사용자에게는 "갑자기 코드가 오른쪽으로 이동"으로 보인다.
pub const leading_margin_cells: u16 = 1;

/// 무엇을 켤지. **문서 단위로 정한다** — 줄마다 다르면 본문 좌측이 들쭉날쭉해진다(§4.1).
pub const Features = struct {
    /// 줄 번호를 그리는가. 끄면 그 영역이 사라진다(Monaco `lineNumbers: "off"`와 같다).
    line_numbers: bool = true,
    /// 접기 화살표 자리를 잡는가.
    folding: bool = true,
    /// 맨 왼쪽 여백 자리를 잡는가. **기본 켜짐**이며(Monaco `glyphMargin: true`와 같다) 여기에 N4의
    /// 진단 마커가 들어간다. 끄는 것은 gutter를 최소로 줄이려는 경우뿐이다.
    leading_margin: bool = true,
};

/// 가로 영역 하나. 셀 단위 반열림 구간 `[start, start + width)`이다.
pub const Span = struct {
    start: u16,
    width: u16,

    /// 이 구간이 실제로 자리를 차지하는가. 폭 0은 "그 기능이 꺼졌다"는 뜻이다.
    pub fn isEmpty(self: Span) bool {
        return self.width == 0;
    }

    /// 구간 끝(exclusive).
    pub fn end(self: Span) u16 {
        return self.start + self.width;
    }

    /// 셀 열이 이 구간에 드는가. hit-test가 쓴다.
    pub fn contains(self: Span, col: u16) bool {
        return col >= self.start and col < self.end();
    }
};

/// 편집기 뷰의 가로 분할 결과.
///
/// 영역 순서는 Monaco와 같다 — 진단 → 줄 번호 → decorations(접기 + 여백) → 본문. 이 순서를 바꾸면
/// VSCode 사용자가 어색해하므로(§1.1) 여기가 그 순서의 단일 출처다.
pub const Layout = struct {
    /// 맨 왼쪽 여백(N4의 진단 마커 자리). N1에서도 폭을 갖는다 — 위 `leading_margin_cells` 참고.
    leading_margin: Span,
    line_numbers: Span,
    folding: Span,
    /// 줄 번호(또는 접기)와 본문 사이 여백. Monaco에는 본문 좌측 패딩 설정이 따로 없고 이 자리가 겸한다.
    content_gap: Span,
    content: Span,

    /// 본문이 시작하는 셀 열. 커서·선택·텍스트가 전부 이 값을 더해 그려진다.
    pub fn contentLeft(self: Layout) u16 {
        return self.content.start;
    }

    /// gutter 전체 폭(본문 앞의 모든 것). 스크롤·hit-test가 본문 영역을 잘라낼 때 쓴다.
    pub fn gutterWidth(self: Layout) u16 {
        return self.content.start;
    }

    /// 접기 화살표가 실제로 **서는 열**. span은 두 셀인데 글자는 하나이므로 어느 칸인지 정해야 하고,
    /// **그리는 쪽과 클릭을 받는 쪽이 그 답을 따로 세면 갈린다**([chrome-strategy.md](../../../../docs/chrome-strategy.md) §5.4).
    /// 그래서 여기가 단일 출처다 — `gutter.build`이 그리고, hit-test는 span 전체를 받는다
    /// (누르는 자리가 그리는 자리보다 넓은 것은 괜찮지만, **다른 자리**면 안 된다).
    ///
    /// 오른쪽 칸인 이유는 `folding_cells` doc에 있다 — 왼쪽 칸을 비워 줄 번호와 떼어 놓는다.
    pub fn foldMarkCol(self: Layout) u16 {
        return self.folding.end() -| 1;
    }
};

/// 총 줄 수를 담는 데 필요한 자릿수. `lineNumbersDigitCount`에 대응한다.
///
/// 0줄은 없지만(§line_index — 빈 문서도 1줄) 방어적으로 1을 돌려준다. 자릿수 0은 어떤 소비처에서도
/// 의미가 없다.
pub fn digitCount(line_count: usize) u16 {
    if (line_count <= 1) return 1;
    var digits: u16 = 0;
    var n = line_count;
    while (n > 0) : (n /= 10) digits += 1;
    return digits;
}

/// 가로 분할을 계산한다.
///
/// `total_cols`는 편집기 뷰가 가진 전체 셀 열 수다. **gutter가 뷰보다 넓으면 본문 폭이 0이 된다** —
/// 오류로 보지 않고 그대로 둔다. 좁은 pane에서 편집기를 열면 실제로 일어나는 상태이고, 그때
/// 무엇을 할지(본문 우선 / gutter 축소)는 이 계산이 아니라 상위가 정할 판단이다. 여기서 임의로
/// gutter를 줄이면 "그려진 것 = 클릭되는 것"이 깨진다.
pub fn compute(total_cols: u16, line_count: usize, features: Features) Layout {
    var cursor: u16 = 0;

    const margin_w: u16 = if (features.leading_margin) leading_margin_cells else 0;
    const leading_margin: Span = .{ .start = cursor, .width = margin_w };
    cursor += margin_w;

    const num_w: u16 = if (features.line_numbers)
        @max(min_line_number_cells, digitCount(line_count))
    else
        0;
    const line_numbers: Span = .{ .start = cursor, .width = num_w };
    cursor += num_w;

    const fold_w: u16 = if (features.folding) folding_cells else 0;
    const folding: Span = .{ .start = cursor, .width = fold_w };
    cursor += fold_w;

    // 여백은 gutter에 무언가 있을 때만 의미가 있다. 셋 다 꺼지면 본문이 열 0에서 시작해야 한다 —
    // 빈 gutter 옆에 여백만 남기면 이유 없는 들여쓰기로 보인다.
    const gap_w: u16 = if (cursor > 0) content_gap_cells else 0;
    const content_gap: Span = .{ .start = cursor, .width = gap_w };
    cursor += gap_w;

    const content: Span = .{
        .start = cursor,
        .width = if (total_cols > cursor) total_cols - cursor else 0,
    };

    return .{
        .leading_margin = leading_margin,
        .line_numbers = line_numbers,
        .folding = folding,
        .content_gap = content_gap,
        .content = content,
    };
}

const testing = std.testing;

test "digitCount: 자릿수 경계" {
    try testing.expectEqual(@as(u16, 1), digitCount(0)); // 방어값
    try testing.expectEqual(@as(u16, 1), digitCount(1));
    try testing.expectEqual(@as(u16, 1), digitCount(9));
    try testing.expectEqual(@as(u16, 2), digitCount(10));
    try testing.expectEqual(@as(u16, 2), digitCount(99));
    try testing.expectEqual(@as(u16, 3), digitCount(100));
    try testing.expectEqual(@as(u16, 5), digitCount(99_999));
    try testing.expectEqual(@as(u16, 6), digitCount(100_000));
}

test "기본 배치: 여백 1 + 줄 번호 5 + 접기 2 + 여백 1 = 본문이 9열부터" {
    const l = compute(80, 42, .{});

    // 맨 왼쪽 여백은 N1에서도 자리를 갖는다 — 없으면 줄 번호가 창 끝에 붙는다(캡처로 확인).
    try testing.expectEqual(@as(u16, 0), l.leading_margin.start);
    try testing.expectEqual(@as(u16, 1), l.leading_margin.width);
    try testing.expectEqual(@as(u16, 1), l.line_numbers.start);
    try testing.expectEqual(@as(u16, 5), l.line_numbers.width);
    try testing.expectEqual(@as(u16, 6), l.folding.start);
    try testing.expectEqual(@as(u16, 2), l.folding.width);
    try testing.expectEqual(@as(u16, 8), l.content_gap.start);
    try testing.expectEqual(@as(u16, 9), l.contentLeft());
    try testing.expectEqual(@as(u16, 71), l.content.width);
    try testing.expectEqual(@as(u16, 9), l.gutterWidth());

    // **화살표는 접기 span의 오른쪽 칸에 선다** — 왼쪽 칸이 줄 번호와의 여백이다. 이것이 깨지면
    // 화살표가 다시 번호에 맞붙는다(2026-08-22 사용자 지적).
    try testing.expectEqual(@as(u16, 7), l.foldMarkCol());
    try testing.expectEqual(l.line_numbers.end() + 1, l.foldMarkCol()); // 번호 끝과 한 칸 뜬다
    try testing.expectEqual(l.foldMarkCol() + 1, l.content_gap.start); // 본문 쪽도 한 칸(대칭)
}

test "줄 번호는 최소 5셀을 유지한다 — 짧은 파일에서 본문이 흔들리지 않는다" {
    const one_line = compute(80, 1, .{});
    const nine = compute(80, 9, .{});
    const ten = compute(80, 10, .{});

    // 1줄이든 10줄이든 같은 자리에서 본문이 시작한다. 이것이 minChars의 목적이다.
    try testing.expectEqual(@as(u16, 5), one_line.line_numbers.width);
    try testing.expectEqual(@as(u16, 5), nine.line_numbers.width);
    try testing.expectEqual(@as(u16, 5), ten.line_numbers.width);
    try testing.expectEqual(one_line.contentLeft(), ten.contentLeft());
}

test "자릿수가 5를 넘으면 그만큼 넓어진다" {
    const big = compute(120, 123_456, .{});
    try testing.expectEqual(@as(u16, 6), big.line_numbers.width);
    try testing.expectEqual(@as(u16, 10), big.contentLeft()); // 여백 1 + 6 + 접기 2 + 여백 1
}

test "접기를 끄면 그 셀이 사라지고 본문이 왼쪽으로 당겨진다" {
    const on = compute(80, 42, .{});
    const off = compute(80, 42, .{ .folding = false });

    try testing.expect(off.folding.isEmpty());
    try testing.expectEqual(@as(u16, 7), off.contentLeft());
    try testing.expectEqual(on.contentLeft() - folding_cells, off.contentLeft());
}

test "N4에서 진단이 켜져도 본문은 밀리지 않는다 — 자리를 처음부터 잡아 뒀다" {
    // 이것이 여백을 N1부터 두는 두 번째 이유다. 나중에 넓히면 사용자에게는 "코드가 갑자기 오른쪽으로
    // 이동"으로 보인다.
    const n1 = compute(80, 42, .{});
    const n4 = compute(80, 42, .{}); // 진단은 이 자리에 그려질 뿐 폭을 새로 요구하지 않는다

    try testing.expectEqual(n1.contentLeft(), n4.contentLeft());
    try testing.expectEqual(@as(u16, 1), n1.leading_margin.width);
}

test "맨 왼쪽 여백을 끄면 줄 번호가 열 0에 붙는다 — 첫 캡처에서 나온 그 모습이다" {
    const bare = compute(80, 42, .{ .leading_margin = false });

    try testing.expect(bare.leading_margin.isEmpty());
    try testing.expectEqual(@as(u16, 0), bare.line_numbers.start);
    try testing.expectEqual(@as(u16, 8), bare.contentLeft());
}

test "gutter를 전부 끄면 본문이 열 0에서 시작한다 — 빈 gutter 옆 여백을 남기지 않는다" {
    const bare = compute(80, 42, .{ .line_numbers = false, .folding = false, .leading_margin = false });

    try testing.expect(bare.line_numbers.isEmpty());
    try testing.expect(bare.folding.isEmpty());
    try testing.expect(bare.content_gap.isEmpty());
    try testing.expectEqual(@as(u16, 0), bare.contentLeft());
    try testing.expectEqual(@as(u16, 80), bare.content.width);
}

test "gutter만 남을 만큼 좁으면 본문 폭이 0이 된다 — 오류가 아니라 상위가 판단할 상태다" {
    const narrow = compute(5, 42, .{});
    try testing.expectEqual(@as(u16, 9), narrow.contentLeft());
    try testing.expectEqual(@as(u16, 0), narrow.content.width);
    try testing.expect(narrow.content.isEmpty());
}

test "영역이 겹치지 않고 빈틈 없이 이어진다" {
    const l = compute(80, 42, .{});

    // 각 구간의 끝이 다음 구간의 시작이어야 한다. 어긋나면 그린 것과 클릭되는 것이 갈린다.
    try testing.expectEqual(l.leading_margin.end(), l.line_numbers.start);
    try testing.expectEqual(l.line_numbers.end(), l.folding.start);
    try testing.expectEqual(l.folding.end(), l.content_gap.start);
    try testing.expectEqual(l.content_gap.end(), l.content.start);
    try testing.expectEqual(@as(u16, 80), l.content.end());
}

test "contains: hit-test가 열을 영역으로 되돌린다" {
    const l = compute(80, 42, .{});

    try testing.expect(l.leading_margin.contains(0));
    try testing.expect(l.line_numbers.contains(1));
    try testing.expect(l.line_numbers.contains(5));
    try testing.expect(!l.line_numbers.contains(6));
    // **접기 span은 두 셀 다 받는다** — 그리는 칸(오른쪽)보다 넓게 잡아 화살표를 누르기 쉽게 한다.
    try testing.expect(l.folding.contains(6));
    try testing.expect(l.folding.contains(l.foldMarkCol()));
    try testing.expect(l.content.contains(9));
    try testing.expect(!l.content.contains(8));
}
