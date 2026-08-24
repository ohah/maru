//! "다음 일치 추가" — 커서를 하나 더 놓을 자리를 고른다
//! ([native-editor-ui.md](../../../docs/native-editor-ui.md) §9.1, [문서 모델](../../../docs/native-editor-document-model.md) §3.2).
//!
//! VSCode `⌘D`가 하는 일이다: 지금 고른 것과 **같은 텍스트**가 다음에 나오는 자리를 찾아 커서를
//! 하나 더 놓는다. 아무것도 안 골랐으면 **커서 밑 낱말**을 먼저 고른다.
//!
//! **`find.zig`와 규칙이 다르다 — 일부러 그렇다.**
//!
//! | | `find.zig`(⌘F) | 여기(다음 일치 추가) |
//! |---|---|---|
//! | 대소문자 | 무시한다 | **가린다** |
//! | 낱말 경계 | 안 본다 | **씨앗이 낱말이면 본다** |
//!
//! 검색은 *"어디 있나"*를 묻는 것이라 넓게 잡는 편이 낫고, 이쪽은 *"여기도 같이 고치겠다"*라
//! 넓게 잡으면 **의도하지 않은 자리를 편집한다.** `foo`를 고치려는데 `Foo`까지 딸려 오면
//! 사용자가 되돌릴 방법은 undo뿐이다. VSCode도 두 기능의 기본값을 이렇게 가른다.
//!
//! **낱말 경계는 씨앗의 모양에서 파생한다 — 상태를 들지 않는다.** VSCode는 "이번 멀티커서
//! 세션이 낱말에서 시작했는가"를 기억하지만, 그러려면 제품이 그 상태를 들고 언제 버릴지도
//! 정해야 한다. 여기서는 **지금 고른 범위가 그 자리의 낱말과 정확히 같으면** 낱말 경계를 본다.
//! 커서에서 시작한 흐름(커서 → 낱말 → 다음 낱말)은 같은 결과를 내고, 갈리는 경우는 하나다:
//! 손으로 `int`를 정확히 고른 뒤 누르면 여기서는 `print` 안을 건너뛰고 VSCode는 잡는다.
//! **그 대가로 제품에 상태가 하나 안 생긴다.**
//!
//! **L2다.** 문서 bytes와 selection 배열만 본다 — 화면도 뷰도 모른다.

const std = @import("std");
const selection = @import("selection.zig");

/// 새로 커서를 놓을 문서 범위.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// 다음에 커서를 놓을 자리. 없으면 `null`.
///
/// `null`이 되는 경우 셋: 고른 것이 빈 낱말 자리다 · 씨앗 텍스트가 문서에 더 없다 ·
/// **남은 일치가 전부 이미 골라져 있다**(전부 고른 뒤 한 번 더 누른 경우).
///
/// **이미 고른 자리를 건너뛴다.** 안 건너뛰면 같은 자리에 커서가 겹쳐 쌓이고, 그 상태로 타이핑하면
/// 한 글자가 두 번 들어간다.
pub fn nextOccurrence(
    content: []const u8,
    selections: []const selection.Selection,
    primary: usize,
) ?Range {
    if (selections.len == 0 or primary >= selections.len) return null;
    const seed = selections[primary];

    // ① 아무것도 안 골랐으면 커서 밑 낱말을 고른다. **그 자체가 "다음 일치"다** — 커서 하나에서
    //    시작하는 흐름의 첫 걸음이고, 여기서 낱말을 안 고르면 씨앗 텍스트가 비어 있다.
    if (seed.len() == 0) {
        const w = selection.wordRangeAt(content, @min(seed.focus, content.len));
        if (w.hi <= w.lo) return null;
        return .{ .start = w.lo, .end = w.hi };
    }

    const lo = seed.start();
    const hi = seed.end();
    if (hi > content.len or lo >= hi) return null;
    const needle = content[lo..hi];

    const whole_word = seedIsWord(content, lo, hi);

    // ② 이미 고른 것 중 **가장 뒤**부터 찾는다. 그래야 누를 때마다 아래로 내려간다 —
    //    primary 뒤부터 찾으면 커서를 여럿 놓은 뒤 순서가 뒤엉킨다.
    var from: usize = 0;
    for (selections) |s| from = @max(from, s.end());

    if (scan(content, needle, from, content.len, whole_word, selections)) |r| return r;
    // ③ 문서 끝까지 없으면 처음으로 돌아간다(VSCode도 감는다).
    return scan(content, needle, 0, from, whole_word, selections);
}

/// `[from, limit)` 안에서 아직 안 고른 일치를 찾는다.
fn scan(
    content: []const u8,
    needle: []const u8,
    from: usize,
    limit: usize,
    whole_word: bool,
    selections: []const selection.Selection,
) ?Range {
    if (needle.len == 0 or from >= limit) return null;
    var i = from;
    while (i + needle.len <= limit) {
        const at = std.mem.indexOfPos(u8, content[0..limit], i, needle) orelse return null;
        if (at + needle.len > limit) return null;
        const r = Range{ .start = at, .end = at + needle.len };
        if ((!whole_word or seedIsWord(content, r.start, r.end)) and !alreadySelected(selections, r)) {
            return r;
        }
        i = at + 1;
    }
    return null;
}

/// 이 범위가 그 자리의 **낱말과 정확히 같은가**. 낱말 규칙은 `selection.wordRangeAt`이 소유한다 —
/// 소스 코드용 경계(`foo.bar()`에서 `foo`만)를 두 곳에 적으면 갈린다.
fn seedIsWord(content: []const u8, lo: usize, hi: usize) bool {
    if (lo >= hi or hi > content.len) return false;
    const w = selection.wordRangeAt(content, lo);
    return w.lo == lo and w.hi == hi;
}

fn alreadySelected(selections: []const selection.Selection, r: Range) bool {
    for (selections) |s| {
        if (s.start() == r.start and s.end() == r.end) return true;
    }
    return false;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "OCC1: 커서만 있으면 그 밑 낱말을 고른다" {
    const content = "alpha beta gamma";
    var sels = [_]selection.Selection{selection.Selection.at(8)}; // "beta" 안
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqualStrings("beta", content[r.start..r.end]);
}

test "OCC2: 고른 텍스트의 다음 자리를 찾는다" {
    const content = "foo bar foo baz foo";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 3)}; // 첫 "foo"
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 8), r.start);
    try testing.expectEqual(@as(usize, 11), r.end);
}

test "OCC3: 이미 고른 자리는 건너뛴다 — 커서가 겹쳐 쌓이지 않는다" {
    const content = "foo bar foo baz foo";
    var sels = [_]selection.Selection{
        selection.Selection.fromPoints(0, 3),
        selection.Selection.fromPoints(8, 11),
    };
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 16), r.start); // 세 번째 foo
}

test "OCC4: 끝까지 없으면 처음으로 감는다" {
    const content = "foo bar foo";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(8, 11)}; // 마지막 foo
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 0), r.start); // 감아서 첫 번째
}

test "OCC5: 전부 골랐으면 null — 눌러도 아무 일이 없다" {
    const content = "foo bar foo";
    var sels = [_]selection.Selection{
        selection.Selection.fromPoints(0, 3),
        selection.Selection.fromPoints(8, 11),
    };
    try testing.expectEqual(@as(?Range, null), nextOccurrence(content, &sels, 0));
}

test "OCC6: 대소문자를 가린다 — find.zig와 다르다" {
    const content = "foo Foo FOO foo";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 3)};
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 12), r.start); // "Foo"·"FOO"를 건너뛴 마지막 "foo"
}

test "OCC7: 씨앗이 낱말이면 낱말 경계를 본다 — print 안의 int를 안 잡는다" {
    const content = "int x; print(); int y;";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 3)}; // "int" — 낱말이다
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 16), r.start); // print 안(8..11)이 아니라 두 번째 int
}

test "OCC8: 씨앗이 낱말 조각이면 경계를 안 본다" {
    const content = "printing int printer";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 3)}; // "pri" — 낱말 조각
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 13), r.start); // "printer"의 "pri"
}

test "OCC9: 찾을 것이 없으면 null" {
    const content = "aaa bbb";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 3)}; // "aaa" 하나뿐
    try testing.expectEqual(@as(?Range, null), nextOccurrence(content, &sels, 0));
}

test "OCC10: 낱말 범위가 비는 자리에서는 커서가 늘지 않는다" {
    // `wordRangeAt`이 빈 범위를 내는 자리가 실재한다(실측): 줄바꿈으로 끝나는 문서의 끝(`"ab\n"`의
    // offset 3 → 2..2)과 줄바꿈만 있는 문서의 처음(`"\n"`의 0 → 0..0). 거기서 범위를 그대로
    // 돌려주면 **호출자가 길이 0짜리 커서를 쌓는다** — 화면에 안 보이는데 타이핑은 그리로 간다.
    const at_end = "ab\n";
    var sels_end = [_]selection.Selection{selection.Selection.at(3)};
    try testing.expectEqual(@as(?Range, null), nextOccurrence(at_end, &sels_end, 0));

    const only_newline = "\n";
    var sels_nl = [_]selection.Selection{selection.Selection.at(0)};
    try testing.expectEqual(@as(?Range, null), nextOccurrence(only_newline, &sels_nl, 0));

    // 공백 런은 낱말로 잡히므로(0..3) 커서가 늘어난다 — 그것은 정상이고, 빈 범위가 아니다.
    const spaces = "   \n   ";
    var sels_sp = [_]selection.Selection{selection.Selection.at(1)};
    const r = nextOccurrence(spaces, &sels_sp, 0).?;
    try testing.expect(r.len() > 0);
}

test "OCC11: 가장 뒤 커서부터 찾는다 — 누를 때마다 아래로 내려간다" {
    // **배치가 판정의 전부다.** 골라 둔 커서 *사이*에 안 고른 일치가 남아 있어야 두 규칙이 갈린다.
    // primary(0..1)와 셋째(8..9)를 골라 두면 안 고른 것은 둘째(4)와 넷째(12)다.
    //   · 가장 뒤부터  → 9 다음 → **12**
    //   · primary 뒤부터 → 1 다음 → 4
    // 처음 쓴 판정자는 안 고른 것이 뒤쪽에만 있어 두 규칙이 같은 답을 냈고, 뮤턴트가 살아남았다.
    const content = "x . x . x . x";
    var sels = [_]selection.Selection{
        selection.Selection.fromPoints(0, 1),
        selection.Selection.fromPoints(8, 9),
    };
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqual(@as(usize, 12), r.start);
}

test "OCC12: 빈 selection 배열·범위 밖 primary는 null" {
    const content = "abc";
    const empty = [_]selection.Selection{};
    try testing.expectEqual(@as(?Range, null), nextOccurrence(content, &empty, 0));

    var one = [_]selection.Selection{selection.Selection.fromPoints(0, 3)};
    try testing.expectEqual(@as(?Range, null), nextOccurrence(content, &one, 5));
}

test "OCC13: 문서 끝을 넘는 selection은 null — 편집 뒤 낡은 offset이 슬라이스를 넘기지 않는다" {
    const content = "abc";
    var stale = [_]selection.Selection{selection.Selection.fromPoints(2, 99)};
    try testing.expectEqual(@as(?Range, null), nextOccurrence(content, &stale, 0));
}

test "OCC14: 멀티바이트 문서에서도 byte 축으로 정확히 답한다" {
    const content = "한글 test 한글";
    var sels = [_]selection.Selection{selection.Selection.fromPoints(0, 6)}; // "한글" (6 byte)
    const r = nextOccurrence(content, &sels, 0).?;
    try testing.expectEqualStrings("한글", content[r.start..r.end]);
    try testing.expectEqual(@as(usize, 12), r.start);
}
