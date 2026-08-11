//! 전개된 논리 줄 하나를 **시각 행으로 나눈다** — §4 세로 축의 랩 단계
//! ([native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md)).
//!
//! **입력은 이미 전개된 텍스트다.** §4가 정한 계산 순서가 `가로(가상 텍스트·탭 전개) → 세로(랩
//! 분할)`이기 때문이다. 탭이 공백으로 펴진 뒤라야 열이 확정되고, 그래야 어디서 접을지 정해진다 —
//! 원본을 나눈 뒤 전개하면 조각 2의 탭스톱이 조각 1을 지나온 열을 모르므로 들여쓰기가 어긋난다.
//!
//! ## 폭을 열수로 나누는 것으로는 답이 안 나온다
//!
//! §4는 *"문자 단위 랩이면 `시각행 수 = ceil(파생 폭 / 뷰 열수)`로 O(1)"*이라고 적었고 괄호로 CJK가
//! 2칸임까지 짚었지만, **그 식은 2칸 글자가 있으면 틀린다.** cluster를 쪼갤 수 없어서 행 끝에 한 칸이
//! 남고, 그 낭비가 행마다 누적되기 때문이다. 실측:
//!
//! | 입력 | 폭 | `ceil` | 실제 |
//! |---|---|---|---|
//! | 한글 5자, 뷰 5열 | 10 | 2 | **3** |
//! | 한글 10자, 뷰 5열 | 20 | 4 | **5** |
//! | `가a가a가`, 뷰 4열 | 8 | 2 | **3** |
//!
//! 홀수 열만의 문제가 아니다(마지막 줄이 뷰 4열이다). 그래서 이 모듈은 **실제로 훑는다**. §4의 캐시
//! 표가 "줄별 랩 분할 결과"를 word wrap 때문에 요구했는데, **문자 단위 랩도 같은 이유로 필요하다.**
//!
//! ## N1 범위
//!
//! **문자 단위 랩이다.** word wrap(UAX #14 단어 경계)이 붙으면 `next`의 경계 판정만 바뀌고 호출부는
//! 그대로다. **접힘은 여기 없다** — §4의 세로 축은 `접힘 필터 → 가상 줄 삽입 → 랩 분할` 순이고 이
//! 모듈은 마지막만 맡는다.

const std = @import("std");
const display_width = @import("../../../display_width.zig"); // §4.2 표시 폭 — 셀 배치와 같은 규칙
const text_layout = @import("../../text_layout.zig"); // cluster 분절 단일 출처

/// 시각 행 하나가 덮는 범위. `text`(전개 결과) 안의 byte 구간이다.
pub const Piece = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Piece, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};

/// 전개된 줄을 시각 행으로 끊어 내는 이터레이터.
///
/// **cluster를 쪼개지 않는다.** 2칸 글자가 행 끝에 걸치면 그 칸을 비우고 다음 행으로 넘긴다 —
/// 반쪽만 그리면 글자가 깨지고, `display_width`가 정한 폭과도 어긋난다.
pub const Pieces = struct {
    text: []const u8,
    view_cols: u16,
    wrap: bool,
    pos: usize = 0,
    done: bool = false,

    /// 다음 시각 행. 더 없으면 `null`.
    ///
    /// **빈 줄도 조각 하나를 낸다.** caret이 놓일 자리가 있어야 하고 화면에서도 한 행을 차지한다 —
    /// 조각을 0개 내면 그 줄이 통째로 사라지고 아래 줄 번호가 하나씩 밀린다.
    pub fn next(self: *Pieces) ?Piece {
        if (self.done) return null;

        // 랩이 꺼지면 줄 전체가 한 조각이다. 화면 밖은 렌더러의 `max_cols`가 자른다(가로 스크롤이
        // 붙으면 이 자리에 시작 열이 들어온다).
        if (!self.wrap or self.view_cols == 0) {
            self.done = true;
            return .{ .start = 0, .end = self.text.len };
        }

        const start = self.pos;
        if (start >= self.text.len) {
            self.done = true;
            // 줄 전체가 비었을 때만 빈 조각을 낸다. 앞에서 이미 조각을 냈다면 끝이다.
            return if (start == 0) Piece{ .start = 0, .end = 0 } else null;
        }

        var col: usize = 0;
        var i = start;
        while (i < self.text.len) {
            const base = text_layout.decodeCodepoint(self.text, i);
            const end = @min(text_layout.clusterEndAfter(self.text, i, base.advance), self.text.len);
            const n = @max(1, end - i);
            const w = display_width.clusterCols(self.text, i, i + n);

            // **안 들어가면 넣지 않는다.** 여기서 `col + w > view_cols`를 확인하지 않고 넣으면 2칸
            // 글자가 행 경계를 넘어 그려진다.
            if (col + w > self.view_cols) break;

            col += w;
            i += n;

            // 폭이 0인 cluster(결합 문자만 남은 적대적 입력)가 이어지면 `col`이 안 늘어 무한히
            // 삼킬 수 있는데, `i`는 늘 전진하므로 루프는 끝난다.
        }

        // 한 글자도 못 넣었다면 그 글자가 뷰보다 넓다(뷰 1열에 한글). **그래도 전진해야 한다** —
        // 안 그러면 같은 자리에서 빈 조각을 무한히 낸다. 넘치더라도 하나는 그리고 넘어간다.
        if (i == start) {
            const base = text_layout.decodeCodepoint(self.text, i);
            const end = @min(text_layout.clusterEndAfter(self.text, i, base.advance), self.text.len);
            i = @max(start + 1, end);
        }

        self.pos = i;
        return .{ .start = start, .end = i };
    }
};

/// 전개된 줄 하나에 대한 이터레이터를 만든다.
pub fn pieces(text: []const u8, view_cols: u16, wrap: bool) Pieces {
    return .{ .text = text, .view_cols = view_cols, .wrap = wrap };
}

/// 화면의 시각 행 하나가 어느 논리 줄의 몇 번째 조각인지.
///
/// **`content`가 채우고 `gutter`가 읽는다.** 랩이 켜지면 시각 행과 논리 줄이 1:1이 아니므로 둘이
/// 각자 세면 번호가 본문과 어긋난다 — 본문을 나눈 쪽이 답을 내고 gutter가 그것을 따른다.
pub const VisualRow = struct {
    /// 뷰포트 첫 줄로부터 몇 번째 논리 줄인가(0-based).
    line: u16,
    /// 그 줄 안에서 몇 번째 조각인가(0-based).
    piece: u16,

    /// 이 행에 줄 번호를 그리는가. **랩된 줄의 두 번째 이후에는 비운다**(§4) — 안 그러면 같은
    /// 번호가 연달아 보인다(VSCode 관례).
    pub fn showsLineNumber(self: VisualRow) bool {
        return self.piece == 0;
    }
};

/// 이 줄이 차지하는 시각 행 수. **훑어야 알 수 있다**(모듈 주석의 표 참고).
pub fn rowsForLine(text: []const u8, view_cols: u16, wrap: bool) usize {
    var it = pieces(text, view_cols, wrap);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

const testing = std.testing;

fn collect(text: []const u8, view_cols: u16, wrap: bool, buf: [][]const u8) [][]const u8 {
    var it = pieces(text, view_cols, wrap);
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) buf[n] = p.slice(text);
    return buf[0..n];
}

test "랩이 꺼지면 줄 전체가 한 조각이다 — 항등이다" {
    var buf: [8][]const u8 = undefined;
    const got = collect("abcdefghij", 5, false, &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("abcdefghij", got[0]);
}

test "ASCII는 열수대로 끊긴다" {
    var buf: [8][]const u8 = undefined;
    const got = collect("abcdefghij", 5, true, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("abcde", got[0]);
    try testing.expectEqualStrings("fghij", got[1]);
}

test "2칸 글자는 쪼개지지 않는다 — ceil이 틀리는 바로 그 경우다" {
    // 한글 5자 = 10칸, 뷰 5열. ceil(10/5)=2지만 실제는 3이다.
    var buf: [8][]const u8 = undefined;
    const got = collect("가나다라마", 5, true, &buf);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("가나", got[0]); // 4칸 + 남는 1칸은 버린다
    try testing.expectEqualStrings("다라", got[1]);
    try testing.expectEqualStrings("마", got[2]);
}

test "짝수 열에서도 어긋난다 — 혼합 폭" {
    // "가a가a가" = 8칸, 뷰 4열. ceil(8/4)=2지만 실제는 3이다.
    var buf: [8][]const u8 = undefined;
    const got = collect("가a가a가", 4, true, &buf);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("가a", got[0]);
    try testing.expectEqualStrings("가a", got[1]);
    try testing.expectEqualStrings("가", got[2]);
}

test "딱 맞으면 행이 늘지 않는다" {
    var buf: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), collect("abcde", 5, true, &buf).len);
    try testing.expectEqual(@as(usize, 2), collect("abcdef", 5, true, &buf).len);
    try testing.expectEqual(@as(usize, 1), collect("가나", 4, true, &buf).len);
}

test "빈 줄도 한 행이다 — caret 자리가 사라지면 안 된다" {
    var buf: [8][]const u8 = undefined;
    const got = collect("", 5, true, &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("", got[0]);
    try testing.expectEqual(@as(usize, 1), rowsForLine("", 5, true));
}

test "뷰보다 넓은 글자도 전진한다 — 무한 루프가 아니다" {
    var buf: [8][]const u8 = undefined;
    const got = collect("가나", 1, true, &buf); // 1열에 2칸 글자
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("가", got[0]);
    try testing.expectEqualStrings("나", got[1]);
}

test "이모지 ZWJ 가족은 한 cluster로 붙어 다닌다" {
    var buf: [8][]const u8 = undefined;
    const family = "👨‍👩‍👧"; // 한 cluster, 2칸
    const got = collect(family ++ family ++ family, 4, true, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings(family ++ family, got[0]);
    try testing.expectEqualStrings(family, got[1]);
}

test "조각들이 원본을 빠짐없이 덮는다 — 겹치지도 새지도 않는다" {
    const inputs = [_][]const u8{
        "",                 "a",
        "가",
        "abcdefghijklmnop",
        "가나다라마바사",
        "a가b나c다",
        "  들여쓰기된 한글 줄",
        "👨‍👩‍👧x가",
    };
    for (inputs) |text| {
        for ([_]u16{ 1, 2, 3, 4, 5, 8, 40 }) |cols| {
            var it = pieces(text, cols, true);
            var expect_start: usize = 0;
            while (it.next()) |p| {
                try testing.expectEqual(expect_start, p.start); // 앞 조각 끝에서 이어진다
                try testing.expect(p.end >= p.start);
                expect_start = p.end;
            }
            try testing.expectEqual(text.len, expect_start); // 끝까지 덮었다
        }
    }
}

test "어느 조각도 뷰 열수를 넘지 않는다 — 넘치는 글자 하나만 예외" {
    const text = "a가b나다라마bc👨‍👩‍👧z";
    for ([_]u16{ 2, 3, 4, 7, 10 }) |cols| {
        var it = pieces(text, cols, true);
        while (it.next()) |p| {
            const slice = p.slice(text);
            var w: usize = 0;
            var i: usize = 0;
            var clusters: usize = 0;
            while (i < slice.len) {
                const base = text_layout.decodeCodepoint(slice, i);
                const end = @min(text_layout.clusterEndAfter(slice, i, base.advance), slice.len);
                const n = @max(1, end - i);
                w += display_width.clusterCols(slice, i, i + n);
                i += n;
                clusters += 1;
            }
            // cluster가 여럿인데 넘쳤다면 경계 판정이 틀린 것이다. 하나짜리는 뷰보다 넓은 글자다.
            if (clusters > 1) try testing.expect(w <= cols);
        }
    }
}
