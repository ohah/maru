//! 열/블록 선택의 **파생** — 사각형 하나를 줄마다 selection 으로 푼다
//! ([문서 모델](../../../docs/native-editor-document-model.md) §3.2a).
//!
//! **L2 순수 함수다.** `AppSession` 도 `Term` 도 안 받는다 — 그래야 판정자가 가짜 `ColumnMap` 을
//! 주입해 탭 폭·CJK·랩을 좌표 하나로 재현할 수 있다(§4.1g 의 `hitTestBody` 가 같은 규율이다).
//!
//! **원본은 `Selections.column`(단수)이고 결과가 배열이다.** 마우스가 하나라 두 사각형을 동시에
//! 끌 수 없다.

const std = @import("std");
const selection = @import("selection.zig");
const motion = @import("motion.zig");

/// 한 시각 행의 텍스트와 그 시작 문서 offset.
///
/// **랩이 켜지면 「행」은 랩된 조각이다**(§3.2a) — 논리 줄 전체를 넘기면 둘째 조각부터 열이 앞 조각
/// 폭만큼 밀린다. `chrome/ui/visual_map.zig` 의 `Piece{ start, end }` 가 그대로 이 모양이고,
/// 호출자가 `piece.slice(line)` 과 `piece.start` 를 실어 준다. **이 파일이 chrome 을 import 하지
/// 않는 이유가 그것이다** — 층 경계를 넘지 않고도 조각을 받는다.
pub const Row = struct {
    /// 이 조각이 문서에서 시작하는 byte offset.
    start: usize,
    /// 조각 텍스트(줄 끝 개행 제외).
    text: []const u8,
};

/// 사각형을 줄마다 selection 으로 푼다. 쓴 개수를 낸다.
///
/// `rows` 는 **`to_row` 에서 시작해 `from_row` 쪽으로** 늘어놓은 조각들이다(§3.2a) — 그 순서가 곧
/// 상한에 걸렸을 때 **살아남는 쪽**이다. VSCode 는 `from` 부터 훑지만(`fromLineNumber + (reversed ? -i : i)`)
/// 그쪽은 자르기를 파생이 아니라 `setStates` 의 `slice(0, limit)` 가 해서 순서가 답을 안 바꾼다.
///
/// `out.len` 이 곧 상한이다 — 호출자가 `selection.max_cursors` 로 재단해 넘긴다.
pub fn derive(
    rows: []const Row,
    anchor: selection.ColumnAnchor,
    map: motion.ColumnMap,
    out: []selection.Selection,
) usize {
    const is_ltr = anchor.from_col < anchor.to_col;
    const is_rtl = anchor.from_col > anchor.to_col;

    var n: usize = 0;
    for (rows) |row| {
        if (n >= out.len) break; // 상한 — 끌고 있는 쪽부터 채웠으므로 반대편이 잘린다
        const so = map.offsetOf(map.ctx, row.text, anchor.from_col);
        const eo = map.offsetOf(map.ctx, row.text, anchor.to_col);

        // **왕복해서 어긋나면 그 줄은 뺀다**(§3.2a). 탭 가운데를 지나면 되돌린 값이 탭스톱까지 튀고,
        // 줄이 짧으면 clamp 되어 줄 끝으로 당겨진다 — 둘 다 "이 줄에는 그 사각형이 안 닿는다"다.
        const vs = map.columnOf(map.ctx, row.text, so);
        const ve = map.columnOf(map.ctx, row.text, eo);
        if (is_ltr and (vs > anchor.to_col or ve < anchor.from_col)) continue;
        if (is_rtl and (ve > anchor.from_col or vs < anchor.to_col)) continue;

        // `kind` 는 승계하지 않는다 — 사각형에서 나온 범위는 낱말도 줄도 아니다(§3.2a).
        // goal 도 비운다: 목표 열은 사각형 자신(`ColumnAnchor`)이 든다.
        out[n] = selection.Selection.fromPoints(row.start + so, row.start + eo);
        n += 1;
    }

    // **한 줄도 안 남으면 줄 끝에 세운다**(§3.2a) — 사각형이 가장 긴 줄보다 오른쪽에 통째로 있을 때다.
    // 아무것도 안 만들면 드래그가 통째로 사라져 사용자는 왜 아무 일도 안 났는지 모른다.
    // VSCode 도 같은 갈래를 둔다(*"We are after all the lines"*).
    if (n == 0) {
        for (rows) |row| {
            if (n >= out.len) break;
            out[n] = selection.Selection.at(row.start + row.text.len);
            n += 1;
        }
    }
    return n;
}

const testing = std.testing;

/// 판정자용 가짜 `ColumnMap` — 탭 폭 4, CJK 두 칸, 나머지 한 칸.
///
/// **제품 구현을 안 부른다**(그쪽은 chrome 을 지난다). 이 파일이 재는 것은 *"사각형을 어떻게 푸나"*
/// 이지 *"열을 어떻게 세나"* 가 아니다 — 후자는 `columnsAtOffsets`·`byteAtPoint` 의 판정자가 잰다.
const FakeMap = struct {
    fn width(ch: u8) u32 {
        return if (ch == '\t') 0 else if (ch >= 0x80) 0 else 1; // 멀티바이트는 아래서 따로
    }
    fn colsAt(text: []const u8, upto: usize) u32 {
        var c: u32 = 0;
        var i: usize = 0;
        while (i < upto and i < text.len) {
            const ch = text[i];
            if (ch == '\t') {
                c = (c / 4 + 1) * 4;
                i += 1;
            } else if (ch < 0x80) {
                c += 1;
                i += 1;
            } else {
                c += 2; // CJK 두 칸 — 3 byte 로 가정
                i += 3;
            }
        }
        return c;
    }
    fn columnOf(_: *const anyopaque, line: []const u8, byte_in_line: usize) u32 {
        return colsAt(line, byte_in_line);
    }
    /// **가까운 쪽으로 붙는다**(§3.2a) — 같은 거리면 앞이다.
    fn offsetOf(_: *const anyopaque, line: []const u8, column: u32) usize {
        var i: usize = 0;
        var before: u32 = 0;
        while (i <= line.len) {
            const c = colsAt(line, i);
            if (c >= column) {
                if (i == 0) return 0;
                const after_delta = c - column;
                const before_delta = column - before;
                if (after_delta < before_delta) return i;
                // 앞 경계로 되돌린다
                var j = i;
                while (j > 0) {
                    j -= 1;
                    if (line[j] < 0x80 or line[j] >= 0xC0) break;
                }
                return j;
            }
            before = c;
            i += 1;
            while (i < line.len and (line[i] & 0xC0) == 0x80) i += 1;
        }
        return line.len;
    }
    fn map() motion.ColumnMap {
        return .{ .ctx = undefined, .columnOf = columnOf, .offsetOf = offsetOf };
    }
};

fn rowsOf(comptime texts: []const []const u8, starts: []const usize, buf: []Row) []Row {
    for (texts, 0..) |t, i| buf[i] = .{ .start = starts[i], .text = t };
    return buf[0..texts.len];
}

test "COL1 파생 기본 — 정방향·역방향·폭 0·빈 selection 이 남는다 (§3.2a)" {
    var buf: [8]Row = undefined;
    var out: [8]selection.Selection = undefined;
    const rows = rowsOf(&.{ "abcdefgh", "bb", "cccccccc" }, &.{ 0, 9, 12 }, &buf);

    // ⑴ 정방향: 세 줄이 다 2~4열을 갖는다… 'bb' 는 2열까지뿐이라 걸러진다(COL2 가 잰다).
    var n = derive(rows, .{ .from_row = 0, .from_col = 1, .to_row = 2, .to_col = 3 }, FakeMap.map(), &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 1), out[0].anchorLo());
    try testing.expectEqual(@as(usize, 3), out[0].focus);

    // ⑵ **폭 0 이면 줄마다 caret 하나** — 그것이 「여러 줄에 커서 세우기」다.
    n = derive(rows, .{ .from_row = 0, .from_col = 1, .to_row = 2, .to_col = 1 }, FakeMap.map(), &out);
    try testing.expectEqual(@as(usize, 3), n);
    for (out[0..n]) |s| try testing.expectEqual(s.anchorLo(), s.focus); // 전부 빈 selection

    // ⑶ **역방향은 anchor·focus 가 뒤집힌다** — 순서만 뒤집는 것이 아니다.
    n = derive(rows, .{ .from_row = 0, .from_col = 3, .to_row = 2, .to_col = 1 }, FakeMap.map(), &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(out[0].focus < out[0].anchorLo());

    // ⑷ **역방향에서도 짧은 줄은 걸러진다.** ⑶ 은 세 줄이 다 통과하는 픽스처라 **RTL 필터를 지워도
    //    답이 같다**(변이 C2 가 그렇게 살아남았다) — 걸러질 줄이 있어야 그 조건이 관측된다.
    //    빈 줄은 두 모서리가 모두 0열로 clamp 되어 `vs < to_col` 이 참이 된다.
    {
        var rbuf: [4]Row = undefined;
        const short = rowsOf(&.{ "abcdefgh", "" }, &.{ 0, 9 }, &rbuf);
        const m = derive(short, .{ .from_row = 0, .from_col = 6, .to_row = 1, .to_col = 4 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 1), m); // 빈 줄이 빠진다 — 필터 없으면 2
        try testing.expectEqual(@as(usize, 6), out[0].anchorLo());
    }
}

test "COL2 걸러 내기 — 탭 가운데·짧은 줄, 그리고 한 줄도 안 남으면 줄 끝 (§3.2a)" {
    var buf: [8]Row = undefined;
    var out: [8]selection.Selection = undefined;

    // ⑴ **탭은 안 걸린다** — 가까운 쪽 스냅이 이미 흡수하므로 왕복이 안 튄다(§3.2a).
    //    처음엔 반대로 적었고 구현 실측이 그것을 반증했다: '\tx' 의 1열은 탭 **앞**(0열)으로 붙는다.
    {
        const rows = rowsOf(&.{ "abcd", "\tx" }, &.{ 0, 5 }, &buf);
        const n = derive(rows, .{ .from_row = 0, .from_col = 1, .to_row = 1, .to_col = 3 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 2), n); // 둘 다 남는다
        try testing.expectEqual(@as(usize, 5), out[1].anchorLo()); // '\tx' 의 탭 앞
        try testing.expectEqual(@as(usize, 6), out[1].focus); // 탭 뒤(3열이 탭 끝에 가깝다)
    }

    // ⑵ **짧은 줄은 뺀다** — 빈 줄에는 4~6열이 없다.
    {
        const rows = rowsOf(&.{ "abcdefgh", "" }, &.{ 0, 9 }, &buf);
        const n = derive(rows, .{ .from_row = 0, .from_col = 4, .to_row = 1, .to_col = 6 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 1), n);
    }

    // ⑶ **한 줄도 안 남으면 각 줄 끝에 caret** — 안 만들면 드래그가 통째로 사라진다.
    {
        const rows = rowsOf(&.{ "ab", "cd" }, &.{ 0, 3 }, &buf);
        const n = derive(rows, .{ .from_row = 0, .from_col = 30, .to_row = 1, .to_col = 32 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(usize, 2), out[0].focus); // "ab" 끝
        try testing.expectEqual(@as(usize, 5), out[1].focus); // start 3 + len 2
    }
}

test "COL3 좌표계 — 조각 시작 offset 이 더해지고 CJK 가운데는 가까운 쪽이다 (§3.2a)" {
    var buf: [8]Row = undefined;
    var out: [8]selection.Selection = undefined;

    // ⑴ **랩 조각**: 논리 줄 "abcdefgh" 가 4열씩 두 조각. 둘째 조각의 offset 에 start 가 더해진다.
    {
        const rows = rowsOf(&.{ "abcd", "efgh" }, &.{ 0, 4 }, &buf);
        const n = derive(rows, .{ .from_row = 0, .from_col = 1, .to_row = 1, .to_col = 3 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(usize, 1), out[0].anchorLo());
        try testing.expectEqual(@as(usize, 5), out[1].anchorLo()); // 4 + 1 — start 를 안 더하면 1 이다
    }

    // ⑵ **CJK 가운데(3열)는 가까운 쪽** — 같은 거리면 앞이다. '가나다' 에서 3열은 '나' 한가운데다.
    {
        const rows = rowsOf(&.{"가나다"}, &.{0}, &buf);
        const n = derive(rows, .{ .from_row = 0, .from_col = 3, .to_row = 0, .to_col = 3 }, FakeMap.map(), &out);
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expectEqual(@as(usize, 3), out[0].focus); // '가' 뒤 — 뒤로 올리면 6 이 된다
    }
}

test "COL5 상한 — out 이 곧 상한이고 끌고 있는 쪽이 남는다 (§3.2a)" {
    var buf: [8]Row = undefined;
    var out: [2]selection.Selection = undefined;
    // rows 는 **to_row 부터** 늘어놓는다 — 호출자가 그 순서로 준다.
    const rows = rowsOf(&.{ "cccccccc", "bbbbbbbb", "aaaaaaaa" }, &.{ 12, 9, 0 }, &buf);
    const n = derive(rows, .{ .from_row = 2, .from_col = 1, .to_row = 0, .to_col = 3 }, FakeMap.map(), &out);
    try testing.expectEqual(@as(usize, 2), n); // 셋이 아니라 둘
    try testing.expectEqual(@as(usize, 13), out[0].anchorLo()); // 'cccccccc' — to_row 쪽이 살았다
    try testing.expectEqual(@as(usize, 10), out[1].anchorLo());
}
