//! 문서 offset 선택 범위를 **화면 행마다의 `Mark`** 로 자른다.
//!
//! `frame.Props.selection_marks` 가 받는 모양을 만드는 산술이다. 여섯 줄짜리 계산이지만 경계가
//! 셋(줄 시작·줄 끝·선택 양끝) 겹쳐서 틀리기 쉽고, macOS·Windows 가 각자 적으면 한쪽만 고쳐진다.
//!
//! ## 축이 이 파일 밖에 있다
//!
//! **행 → 문서 줄 대응은 호출자가 푼다.** 접혀 있으면 렌더가 받는 배열은 보이는 줄이고
//! `paintSelection` 은 그 축의 인덱스로 읽는다 — 문서 줄 축으로 만들면 접힘이 켜지는 순간 **화면이
//! 조용히 거짓말한다**: 실측으로 보이는 줄의 띠가 사라지고(1→0), 숨긴 줄을 고르면 엉뚱한 보이는
//! 줄에 띠가 섰다(0→1).
//!
//! 그래서 이 함수는 **행마다 그 줄이 문서의 어디부터 어디까지인지**(`Span`)를 받는다. 그 값을
//! 만드는 것이 축을 정하는 일이고, 그것은 문서 모델을 아는 쪽(session·플랫폼)의 몫이다.

const std = @import("std");

const frame = @import("frame.zig");

/// 한 화면 행이 덮는 **문서 byte 범위**. `end` 는 줄 끝 문자 **앞**이다(개행을 안 넣는다) —
/// 넣으면 줄 끝에서 선택 띠가 다음 줄로 새는 것처럼 보인다.
pub const Span = struct {
    start: usize,
    end: usize,

    /// 그릴 것이 없는 행(짝을 맞추려 넣은 빈 행 등). `start == end` 로도 표현되지만 이름을 준다.
    pub const none: Span = .{ .start = 0, .end = 0 };
};

/// `[lo, hi)` 를 행마다 잘라 `out_rows` 를 채운다.
///
/// - `out_rows` 와 `out_buf` 는 `row_spans` 와 **같은 길이**여야 한다. 짧으면 아무것도 안 한다.
/// - 선택에 안 걸리는 행은 빈 슬라이스다(`&.{}`) — `null` 이 아니다. 렌더가 행마다 읽으므로 길이가
///   맞아야 한다.
///
/// **`lo == hi`(caret 뿐)면 전부 빈 슬라이스다.** 폭 0 짜리 띠를 그리면 글자 사이에 한 픽셀이 서는데,
/// caret 은 플랫폼이 따로 그린다.
pub fn build(lo: usize, hi: usize, row_spans: []const Span, out_rows: [][]const frame.Mark, out_buf: []frame.Mark) void {
    if (out_rows.len < row_spans.len or out_buf.len < row_spans.len) return;
    @memset(out_rows[0..row_spans.len], &.{});
    if (hi <= lo) return;

    for (row_spans, 0..) |span, i| {
        if (span.end <= lo or span.start >= hi) continue; // 이 행은 선택 밖
        const from = if (lo > span.start) lo - span.start else 0;
        const to = @min(hi, span.end) - span.start;
        if (to <= from) continue;
        out_buf[i] = .{ .start = @intCast(from), .len = @intCast(to - from) };
        out_rows[i] = out_buf[i .. i + 1];
    }
}

const testing = std.testing;

fn run(lo: usize, hi: usize, spans: []const Span, rows: [][]const frame.Mark, buf: []frame.Mark) void {
    build(lo, hi, spans, rows, buf);
}

test "한 줄 안의 선택" {
    const spans = [_]Span{ .{ .start = 0, .end = 10 }, .{ .start = 11, .end = 20 } };
    var rows: [2][]const frame.Mark = undefined;
    var buf: [2]frame.Mark = undefined;
    run(3, 7, &spans, &rows, &buf);
    try testing.expectEqual(@as(usize, 1), rows[0].len);
    try testing.expectEqual(@as(u32, 3), rows[0][0].start);
    try testing.expectEqual(@as(u32, 4), rows[0][0].len);
    try testing.expectEqual(@as(usize, 0), rows[1].len);
}

test "여러 줄에 걸치면 가운데 줄은 통째로다" {
    const spans = [_]Span{
        .{ .start = 0, .end = 10 },
        .{ .start = 11, .end = 20 },
        .{ .start = 21, .end = 30 },
    };
    var rows: [3][]const frame.Mark = undefined;
    var buf: [3]frame.Mark = undefined;
    run(7, 25, &spans, &rows, &buf);
    // 첫 줄: 7 부터 끝까지
    try testing.expectEqual(@as(u32, 7), rows[0][0].start);
    try testing.expectEqual(@as(u32, 3), rows[0][0].len);
    // 가운데: 통째로
    try testing.expectEqual(@as(u32, 0), rows[1][0].start);
    try testing.expectEqual(@as(u32, 9), rows[1][0].len);
    // 끝 줄: 시작부터 4 바이트(21..25)
    try testing.expectEqual(@as(u32, 0), rows[2][0].start);
    try testing.expectEqual(@as(u32, 4), rows[2][0].len);
}

test "caret 뿐이면(lo == hi) 아무 띠도 없다" {
    const spans = [_]Span{.{ .start = 0, .end = 10 }};
    var rows: [1][]const frame.Mark = undefined;
    var buf: [1]frame.Mark = undefined;
    run(5, 5, &spans, &rows, &buf);
    try testing.expectEqual(@as(usize, 0), rows[0].len);
}

test "줄 끝에서 다음 줄로 안 샌다 — 개행은 span 밖이다" {
    // 줄 0 은 0..10, 줄 1 은 11..20. 개행(10)은 어느 span 에도 없다.
    const spans = [_]Span{ .{ .start = 0, .end = 10 }, .{ .start = 11, .end = 20 } };
    var rows: [2][]const frame.Mark = undefined;
    var buf: [2]frame.Mark = undefined;
    // 첫 줄 끝(10)까지만 고른다 — 둘째 줄에 띠가 서면 안 된다.
    run(8, 10, &spans, &rows, &buf);
    try testing.expectEqual(@as(u32, 8), rows[0][0].start);
    try testing.expectEqual(@as(u32, 2), rows[0][0].len);
    try testing.expectEqual(@as(usize, 0), rows[1].len);
    // 개행 하나만 고르면(10..11) **어느 줄에도** 띠가 없다.
    run(10, 11, &spans, &rows, &buf);
    try testing.expectEqual(@as(usize, 0), rows[0].len);
    try testing.expectEqual(@as(usize, 0), rows[1].len);
}

test "선택 밖 행은 빈 슬라이스다 — null 이 아니다" {
    const spans = [_]Span{ .{ .start = 0, .end = 5 }, .{ .start = 6, .end = 9 } };
    var rows: [2][]const frame.Mark = undefined;
    var buf: [2]frame.Mark = undefined;
    // 이전 호출의 찌꺼기를 심어 둔다 — `@memset` 이 없으면 여기서 드러난다.
    rows[0] = buf[0..1];
    rows[1] = buf[0..1];
    run(100, 200, &spans, &rows, &buf);
    try testing.expectEqual(@as(usize, 0), rows[0].len);
    try testing.expectEqual(@as(usize, 0), rows[1].len);
}

test "저장소가 짧으면 아무것도 안 한다" {
    const spans = [_]Span{ .{ .start = 0, .end = 5 }, .{ .start = 6, .end = 9 } };
    var rows: [1][]const frame.Mark = undefined;
    var buf: [1]frame.Mark = undefined;
    rows[0] = &.{};
    run(0, 100, &spans, &rows, &buf);
    // 손대지 않는다 — 반쯤 채우면 렌더가 어긋난 축을 읽는다.
    try testing.expectEqual(@as(usize, 0), rows[0].len);
}

test "빈 행(span 폭 0)은 선택 안에 있어도 띠가 없다" {
    const spans = [_]Span{ .{ .start = 5, .end = 5 }, .{ .start = 6, .end = 9 } };
    var rows: [2][]const frame.Mark = undefined;
    var buf: [2]frame.Mark = undefined;
    run(0, 100, &spans, &rows, &buf);
    try testing.expectEqual(@as(usize, 0), rows[0].len);
    try testing.expectEqual(@as(u32, 3), rows[1][0].len);
}
