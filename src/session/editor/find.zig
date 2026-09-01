//! 문서 내 검색의 **일치 계산** — 문서 내용만의 함수라 L2다
//! ([native-editor-visual-mapping.md](../../../docs/native-editor-visual-mapping.md) §5.1).
//!
//! **UI는 기존 find 오버레이를 재사용한다.** 그 컴포넌트는 `Target`으로 검색 대상이 갈리는 구조라
//! 값 하나를 더하는 확장이고, `State`는 `current`/`match_count`만 들며 **매치 리스트는 세션 소유**다
//! — 편집기도 같은 자리에 둔다. 그래서 이 모듈은 리스트를 만들기만 하고 어디에도 걸지 않는다.
//!
//! **대소문자 규칙을 터미널과 공유한다**(`terminal.selection.foldCase`). 같은 오버레이에 같은
//! 검색어를 치는데 pane 종류에 따라 대소문자 규칙이 갈리면 사용자는 그것을 결함으로 읽는다 —
//! §5.1이 정규식 엔진을 두 개 두지 말라고 적은 것과 같은 이유다.
//!
//! **매치 수에 상한이 없다.** 큰 파일에서 흔한 글자를 치면 목록이 그만큼 커진다(매치 하나에 12 byte).
//! 상한을 두지 않은 이유는 **둘 중 덜 나쁜 쪽**이어서다: 잘라 내면 카운터가 실제보다 작은 수를
//! 말하고 마지막 매치 뒤로는 Enter가 안 가는데, 그것이 바로 이 슬라이스가 고치려던 부류(조용히
//! 잘못 동작한다)다. 잘라 낸 것을 말하려면 오버레이에 자리가 필요하고 그것은 별도 결정이다.
//! **터미널 스크롤백 검색도 상한이 없다** — 같은 오버레이가 두 규칙을 갖지 않는다.
//! 할당이 실패하면 매치 0으로 떨어진다(호출자가 `catch`로 비운다) — 크래시가 아니라 저하다.
//!
//! **줄을 넘는 매치는 없다.** 검색 입력이 한 줄이라 개행을 담을 수 없고, 터미널 쪽이 줄을 잇는
//! 것은 soft-wrap(한 논리 줄이 여러 행으로 접힌 것)을 되돌리는 일이지 **다른 줄을 잇는 것이 아니다**.
//! 문서에는 soft-wrap이 저장돼 있지 않으므로 대응물이 없다.

const std = @import("std");
const terminal = @import("../../terminal.zig");
/// 낱말 경계의 단일 출처(§3.2) — 더블클릭이 잡는 범위와 같은 것을 쓴다.
const editor_selection = @import("selection.zig");

/// 한 매치 — **줄 안의 byte 범위**다. 렌더가 요구하는 축이 그것이고(`frame.Mark`), §3.1의 문서
/// offset은 `line_index`가 줄 시작을 알므로 언제든 더해 얻는다.
///
/// **문서 offset으로 두지 않는 이유**: 매치를 그리려면 결국 줄로 잘라야 하는데(선택이 `buildSelectionMarks`
/// 에서 그러듯), 매치는 애초에 한 줄 안에서만 난다 — 합쳤다 다시 자르면 자르는 코드만 는다.
pub const Match = struct {
    /// **문서 줄 인덱스**(0-based). 보이는 줄이 아니다 — 접힘은 뷰 상태이고 검색은 문서 전체를 본다.
    line: u32,
    /// 줄 시작으로부터의 byte offset.
    start: u32,
    /// 매치 byte 길이. **`needle.len`과 같다고 가정하지 않는다** — 지금 `foldCase`가 덮는 블록은
    /// 전부 인코딩 길이를 보존하지만, 표가 넓어져 1:N 폴딩(ß→ss)이 들어오면 그 가정이 깨진다.
    /// 실제로 훑은 만큼을 적어 두면 그날 이 자리가 조용히 틀리지 않는다.
    len: u32,
};

/// `line`의 `from`(byte)에서 needle이 시작하는가. 맞으면 매치 **끝 byte**, 아니면 `null`.
///
/// **양쪽을 나란히 훑는다 — 어느 쪽도 미리 펴 두지 않는다.**
///
/// 초판은 needle을 `[]u21`로 한 번 펴 두고 재사용했다. 그것을 버린 이유가 둘이다.
///   1. **cluster 규율 가드가 그 모양을 잡는다**(`tests/boundary/chrome_text_clusters.zig` CG1).
///      "문자열 → 코드포인트 슬라이스" 변환기는 셀 방출 루프에서 돌면 결합 문자를 흩뜨리므로
///      규칙 대상이다. 여기서는 셀을 만들지 않지만, 그 사실을 허용목록에 적는 것은 **부채 목록에
///      부채가 아닌 것을 적는** 일이라 목록이 거짓말하게 된다.
///   2. **할당이 사라진다.** 검색어는 입력 상자 한 줄이라 짧고, 매번 다시 디코드해도 비용이
///      후보 위치당 needle 길이뿐이다 — 순진한 부분 문자열 탐색이 원래 하는 그 일이다.
fn matchAt(line: []const u8, from: usize, needle_utf8: []const u8, opts: Options) ?usize {
    var i = from;
    var n: usize = 0;
    while (n < needle_utf8.len) {
        if (i >= line.len) return null;
        const nl = std.unicode.utf8ByteSequenceLength(needle_utf8[n]) catch return null;
        if (n + nl > needle_utf8.len) return null;
        const hl = std.unicode.utf8ByteSequenceLength(line[i]) catch return null;
        if (i + hl > line.len) return null;
        const want = std.unicode.utf8Decode(needle_utf8[n .. n + nl]) catch return null;
        // 못 읽는 자리는 **이 시작점의 불일치**다. 호출자가 `stepBytes`로 1 byte만 밀어 다음
        // 자리를 다시 보므로, 여기서 몇 byte를 봤는지 알릴 필요가 없다.
        const have = std.unicode.utf8Decode(line[i .. i + hl]) catch return null;
        if (opts.match_case) {
            if (have != want) return null;
        } else if (terminal.selection.foldCase(have) != terminal.selection.foldCase(want)) return null;
        i += hl;
        n += nl;
    }
    // **낱말 경계는 마지막에 본다.** 시작과 끝을 다 알아야 「이 범위가 낱말 하나와 같은가」를
    // 물을 수 있다. 판정은 `selection.wordRangeAt` 이 소유한다(§3.2 더블클릭이 잡는 그 범위) —
    // 여기서 `isWordByte` 를 다시 쓰면 앱 안에 낱말 규칙이 둘이 된다.
    if (opts.whole_word and !isWholeWord(line, from, i)) return null;
    return i;
}

/// `line[lo..hi]` 가 그 자리의 **낱말과 정확히 같은가**. `occurrence.seedIsWord` 와 같은 판정이고,
/// 같은 소유자(`selection.wordRangeAt`)를 쓴다.
fn isWholeWord(line: []const u8, lo: usize, hi: usize) bool {
    if (lo >= hi or hi > line.len) return false;
    const w = editor_selection.wordRangeAt(line, lo);
    return w.lo == lo and w.hi == hi;
}

/// 다음 코드포인트 경계까지의 byte 수 — **읽을 수 있을 때만** 그 길이다.
///
/// **선언된 길이를 믿지 않는다.** lead byte는 "내가 n byte짜리다"라고 말하지만 뒤따르는 byte가
/// 잘렸거나 continuation이 아니면 그 말은 거짓이고, 그 거짓을 믿고 커서를 밀면 **뒤따르는 성한
/// byte까지 삼킨다**. 적대적 검증이 실행으로 잡은 것이 그것이다(2026-08-23):
///
/// | 줄 | 검색어 | 옛 동작 | 기대 |
/// |---|---|---|---|
/// | `"\xE0abcabc"` | `abc` | 매치 1개(4에서) | 2개 — 1이 사라졌다 |
/// | `"aa\xF0target"` | `target` | **0개** | 1개 — `tar`가 0xF0의 4-byte 폭에 먹혔다 |
///
/// 읽을 수 없으면 **1 byte만** 민다. 그러면 못 읽는 byte 하나만 잃고 다음 자리부터 다시 본다.
fn stepBytes(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i .. i + n]) catch return 1;
    return n;
}

/// 문서 줄 배열에서 needle을 찾아 `out`에 채운다(호출자 소유, 매번 비운다).
///
/// **같은 줄 안에서 겹치지 않는다** — 매치 뒤부터 다시 본다. 터미널 검색과 같은 규칙이고,
/// `aaa`에서 `aa`를 찾으면 둘이 아니라 하나다.
///
/// **깨진 UTF-8 줄은 그 byte 하나만 넘긴다**(`stepBytes`). 문서는 열 때 UTF-8을 검사하므로(§3.5)
/// 여기 오는 줄은 성한 것이지만, 그 검사가 파일 전체를 보는 것이라 **이 함수 혼자로는 보장이
/// 아니다** — 그리고 N2에서 편집이 붙으면 `editor_lines`가 그 검사를 안 지나는 순간이 온다.
/// 초판은 이 걱정을 doc에 적어 두고 **구현이 그 걱정을 못 막았다**(`stepBytes`의 표).
/// 검색 규칙 토글(§5.1). **편집기 타깃에만 산다** — 스크롤백·웹은 이 값을 안 본다.
///
/// 기본값 둘 다 `false` 가 **종전 동작**이다: 대소문자 무시, 낱말 경계 안 봄.
pub const Options = struct {
    /// 켜면 대소문자를 **가린다**. 끄면 `foldCase` 로 접어 비교한다(터미널과 같은 규칙).
    match_case: bool = false,
    /// 켜면 매치가 **낱말 하나와 정확히 같을 때만** 센다. 판정은 `selection.wordRangeAt` 이
    /// 소유한다 — 더블클릭이 잡는 그 범위와 **같은 것**이어야 앱 안에 낱말 규칙이 둘 안 생긴다.
    whole_word: bool = false,
};

pub fn findMatches(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    needle_utf8: []const u8,
    opts: Options,
    out: *std.ArrayList(Match),
) !void {
    out.clearRetainingCapacity();
    if (needle_utf8.len == 0) return;
    // **깨진 검색어는 매치 0이다.** 여기서 한 번 보면 아래 훑기가 needle 쪽 디코드 실패를
    // "이 자리 불일치"로만 다뤄도 된다 — 줄마다 같은 판정을 되풀이하지 않는다.
    _ = std.unicode.Utf8View.init(needle_utf8) catch return;

    for (lines, 0..) |line, li| {
        var i: usize = 0;
        while (i < line.len) {
            if (matchAt(line, i, needle_utf8, opts)) |end| {
                try out.append(allocator, .{
                    .line = @intCast(li),
                    .start = @intCast(i),
                    .len = @intCast(end - i),
                });
                i = end;
                continue;
            }
            // 다음 **코드포인트 경계**로. byte 단위로 밀면 멀티바이트 글자 중간에서 시작하는
            // 비교를 하게 되고, 그것은 UTF-8에서 절대 맞지 않으므로 헛걸음이다.
            i += stepBytes(line, i);
        }
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn collect(lines: []const []const u8, needle: []const u8) !std.ArrayList(Match) {
    return collectOpts(lines, needle, .{});
}

fn collectOpts(lines: []const []const u8, needle: []const u8, opts: Options) !std.ArrayList(Match) {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(testing.allocator);
    try findMatches(testing.allocator, lines, needle, opts, &out);
    return out;
}

test "FND20 대소문자를 가리면 접힌 짝이 빠진다 — 끄면 종전 그대로 (§5.1)" {
    // **기본값이 종전 동작**이라는 것이 이 판정자의 절반이다. 옵션을 더하면서 안 켠 사용자의
    // 결과가 달라지면 그것은 기능이 아니라 회귀다.
    const lines = [_][]const u8{"Foo foo FOO fOo"};

    var off = try collectOpts(&lines, "foo", .{});
    defer off.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), off.items.len); // 넷 다 — 종전과 같다

    var on = try collectOpts(&lines, "foo", .{ .match_case = true });
    defer on.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), on.items.len);
    try testing.expectEqual(@as(u32, 4), on.items[0].start); // 두 번째 `foo` 하나만

    // **대문자 검색어도 같은 규칙이다** — 한쪽만 접으면 「Foo 로 찾으면 foo 가 걸리는데 그 반대는
    // 안 되는」 비대칭이 생긴다.
    var upper = try collectOpts(&lines, "FOO", .{ .match_case = true });
    defer upper.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), upper.items.len);
    try testing.expectEqual(@as(u32, 8), upper.items[0].start);
}

test "FND21 낱말 단위는 안에 박힌 것을 뺀다 — 더블클릭이 잡는 낱말과 같다 (§5.1)" {
    // 이것이 이 옵션의 존재 이유다: `id` 로 찾으면 `width`·`valid`·`invalid` 가 다 걸려
    // 코드에서 식별자를 정확히 찾을 방법이 없었다.
    const lines = [_][]const u8{"id width valid invalid id_x x_id id"};

    var off = try collectOpts(&lines, "id", .{});
    defer off.deinit(testing.allocator);
    try testing.expect(off.items.len > 3); // 박힌 것까지 다 — 종전과 같다

    var on = try collectOpts(&lines, "id", .{ .whole_word = true });
    defer on.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), on.items.len); // 맨 앞과 맨 뒤의 홀로 선 `id` 둘
    try testing.expectEqual(@as(u32, 0), on.items[0].start);
    try testing.expectEqual(@as(u32, 33), on.items[1].start);

    // **`_` 는 낱말 글자다** — `id_x`·`x_id` 는 낱말 하나라 그 안의 `id` 는 안 잡힌다.
    // 이 규칙을 여기서 새로 정하지 않는다: `selection.wordRangeAt` 이 소유하고
    // 더블클릭이 잡는 범위와 **같은 것**이다(§3.2).
    const w = editor_selection.wordRangeAt(lines[0], 23);
    try testing.expectEqual(@as(usize, 23), w.lo);
    try testing.expectEqual(@as(usize, 27), w.hi); // `id_x` 통째로
}

test "FND22 두 옵션은 곱해진다 — 켠 것만큼만 좁아진다 (§5.1)" {
    // 둘을 따로 재면 「하나를 켜면 다른 하나도 켜지는」 배선 실수를 못 본다.
    const lines = [_][]const u8{"Id id ID id_x"};

    var both = try collectOpts(&lines, "id", .{ .match_case = true, .whole_word = true });
    defer both.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), both.items.len); // 소문자이면서 홀로 선 것 하나
    try testing.expectEqual(@as(u32, 3), both.items[0].start);

    // 낱말만: 대소문자는 안 가리므로 셋(`Id`·`id`·`ID`), `id_x` 안은 제외
    var word_only = try collectOpts(&lines, "id", .{ .whole_word = true });
    defer word_only.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), word_only.items.len);

    // 대소문자만: 낱말을 안 보므로 `id` 와 `id_x` 안의 `id` 둘
    var case_only = try collectOpts(&lines, "id", .{ .match_case = true });
    defer case_only.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), case_only.items.len);
}

test "FND1: 한 줄에 여러 매치가 각각 선다" {
    // 이 판정자가 이 슬라이스의 이유다 — 선택 마크 저장소는 **줄당 하나**라(`editor_selection_mark_buf`)
    // 검색을 그 위에 얹으면 한 줄의 둘째 매치부터 조용히 사라진다.
    const lines = [_][]const u8{"foo bar foo baz foo"};
    var m = try collect(&lines, "foo");
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.items.len);
    try testing.expectEqual(@as(u32, 0), m.items[0].start);
    try testing.expectEqual(@as(u32, 8), m.items[1].start);
    try testing.expectEqual(@as(u32, 16), m.items[2].start);
    for (m.items) |it| {
        try testing.expectEqual(@as(u32, 0), it.line);
        try testing.expectEqual(@as(u32, 3), it.len);
    }
}

test "FND2: 매치는 겹치지 않는다 — aaa에서 aa는 하나다" {
    const lines = [_][]const u8{"aaa"};
    var m = try collect(&lines, "aa");
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.items.len);
    try testing.expectEqual(@as(u32, 0), m.items[0].start);
}

test "FND3: 대소문자를 무시한다 — 터미널과 같은 규칙" {
    // ASCII만이 아니다. 터미널 검색이 덮는 블록(Latin-1·Greek·Cyrillic)이 여기서도 같아야
    // "같은 검색어인데 pane에 따라 다르다"가 안 생긴다.
    const lines = [_][]const u8{ "Hello World", "ÉCOLE", "ΑΒΓ", "ПРИВЕТ" };

    // **양방향으로 잰다.** 소문자 검색어만 넣으면 **haystack만 접어도** 전부 통과한다 —
    // 실제로 그 뮤턴트가 이 판정자를 뚫고 살아남았다(2라운드 적대적 검증). 사용자로 치면
    // "찾기 상자에 `HELLO`를 치면 아무것도 안 나온다"가 L2 판정자 열 개를 그대로 지나간다.
    const lower = [_][]const u8{ "hello", "école", "αβγ", "привет" };
    const upper = [_][]const u8{ "HELLO", "ÉCOLE", "ΑΒΓ", "ПРИВЕТ" };
    for (lower, upper, 0..) |lo, up, line| {
        var a = try collect(&lines, lo);
        defer a.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), a.items.len);
        try testing.expectEqual(@as(u32, @intCast(line)), a.items[0].line);

        var b = try collect(&lines, up); // ← 이쪽이 needle 축을 잰다
        defer b.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), b.items.len);
        try testing.expectEqual(@as(u32, @intCast(line)), b.items[0].line);
    }

    // 폴딩이 **byte 길이를 보존**한다(덮는 블록이 전부 같은 인코딩 길이라서) — 그 사실도 못 박는다.
    var e = try collect(&lines, "école");
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, "ÉCOLE".len), e.items[0].len);
}

test "FND4: 줄 번호와 줄 안 offset이 각자 축을 지킨다" {
    const lines = [_][]const u8{ "no", "xx target", "target" };
    var m = try collect(&lines, "target");
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), m.items.len);
    try testing.expectEqual(@as(u32, 1), m.items[0].line);
    try testing.expectEqual(@as(u32, 3), m.items[0].start); // 줄 시작 기준 — 문서 offset이 아니다
    try testing.expectEqual(@as(u32, 2), m.items[1].line);
    try testing.expectEqual(@as(u32, 0), m.items[1].start);
}

test "FND5: 빈 검색어·깨진 검색어는 매치 0 (무한 루프가 아니다)" {
    const lines = [_][]const u8{"whatever"};
    var a = try collect(&lines, "");
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a.items.len);

    var b = try collect(&lines, "\xff\xfe"); // UTF-8 아님
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), b.items.len);
}

test "FND6: 멀티바이트 글자 중간에서 매치가 시작하지 않는다" {
    // "한글"의 둘째 byte부터 비교를 시작하면 UTF-8에선 절대 안 맞지만, 그렇게 미는 구현은
    // 매치 **끝**도 byte로 밀어 글자 중간을 가리키는 Mark를 만들 수 있다 — 렌더가 그 자리에서
    // 열을 잘못 센다. 경계로만 움직이는 것을 여기서 못 박는다.
    const lines = [_][]const u8{"가나다나"};
    var m = try collect(&lines, "나");
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), m.items.len);
    try testing.expectEqual(@as(u32, 3), m.items[0].start);
    try testing.expectEqual(@as(u32, 3), m.items[0].len);
    try testing.expectEqual(@as(u32, 9), m.items[1].start);
}

test "FND7: 매치 목록은 줄 순서·줄 안 순서로 정렬돼 나온다" {
    // 네비게이션(Enter/Shift+Enter)이 인덱스 ±1로 앞뒤를 오가므로 이 순서가 곧 **문서 순서**여야
    // 한다. 정렬을 따로 하지 않고 훑는 순서에 기대므로, 그 기댐을 판정자로 고정한다.
    const lines = [_][]const u8{ "a x a", "x", "a" };
    var m = try collect(&lines, "a");
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.items.len); // 첫 줄에 둘, 가운데 줄에 없음, 끝 줄에 하나
    var prev: ?Match = null;
    for (m.items) |it| {
        if (prev) |p| try testing.expect(it.line > p.line or (it.line == p.line and it.start > p.start));
        prev = it;
    }
}

test "FND8: 재사용하는 out은 이전 결과를 남기지 않는다" {
    // 증분 검색이라 타이핑마다 같은 리스트에 다시 채운다 — 안 비우면 매치 수가 계속 늘어
    // 카운터가 거짓말한다.
    var out: std.ArrayList(Match) = .empty;
    defer out.deinit(testing.allocator);
    const lines = [_][]const u8{"aaa bbb"};
    try findMatches(testing.allocator, &lines, "a", .{}, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try findMatches(testing.allocator, &lines, "b", .{}, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try findMatches(testing.allocator, &lines, "zzz", .{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "FND9: 깨진 lead byte가 뒤따르는 성한 byte를 삼키지 않는다" {
    // **적대적 검증이 실행으로 잡은 결함**(2026-08-23). 초판은 lead byte가 **선언한** 길이만큼
    // 커서를 밀어서, 디코드가 실패해도 최대 4 byte를 건너뛰었다 — 그 안에 든 매치가 사라졌다.
    //
    // 오늘 제품 경로는 여기 못 닿는다(`document.open`이 UTF-8을 검사해 거절한다). 그래도 재는
    // 이유는 **모듈 doc이 바로 이 걱정을 적어 두고 구현이 그것을 못 막고 있었기 때문**이고,
    // N2에서 편집이 붙으면 `editor_lines`가 그 검사를 안 지나는 순간이 온다.
    {
        const lines = [_][]const u8{"\xE0abcabc"}; // 0xE0은 3 byte라 선언하지만 뒤가 안 맞는다
        var m = try collect(&lines, "abc");
        defer m.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), m.items.len); // 옛 동작은 1개
        try testing.expectEqual(@as(u32, 1), m.items[0].start);
        try testing.expectEqual(@as(u32, 4), m.items[1].start);
    }
    {
        const lines = [_][]const u8{"aa\xF0target"}; // 0xF0은 4 byte 선언 — `tar`를 삼켰다
        var m = try collect(&lines, "target");
        defer m.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), m.items.len); // 옛 동작은 0개
        try testing.expectEqual(@as(u32, 3), m.items[0].start);
    }
}

test "FND10: 정규화는 하지 않는다 — NFD 문서에 NFC 검색어는 안 맞는다" {
    // **적어 두는 이유는 이것이 결정이기 때문이다**(적대적 검증 2026-08-23이 "빠진 결정"으로
    // 지적했다). 이 저장소는 한글 NFD를 1급으로 다루는데(`docs/grapheme-clustering.md`), 검색은
    // 코드포인트 단위 비교라 `가`(NFC, U+AC00)와 `ᄀ`+`ᅡ`(NFD)가 **다른 것**이다.
    //
    // 정규화를 넣지 않은 이유: 그것은 검색만의 결정이 아니다 — 선택·복사·낱말 경계가 같은 축을
    // 쓴다. 여기서 한쪽만 정규화하면 **검색 결과와 선택 범위가 어긋난다**.
    //
    // 이 판정자는 그 동작을 **고정**한다. 나중에 정규화를 들이면 이 테스트가 먼저 빨개져
    // "그때 무엇을 함께 바꾸는지" 묻게 한다 — 조용히 바뀌지 않는다.
    const nfc = [_][]const u8{"\u{AC00}"}; // 가 (완성형)
    const nfd = [_][]const u8{"\u{1100}\u{1161}"}; // ᄀ + ᅡ (조합형)

    var a = try collect(&nfc, "\u{1100}\u{1161}");
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a.items.len);

    var b = try collect(&nfd, "\u{AC00}");
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), b.items.len);

    // 같은 표현끼리는 맞는다 — 위 둘이 "검색이 통째로 깨졌다"가 아님을 보인다.
    var c = try collect(&nfd, "\u{1100}\u{1161}");
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), c.items.len);
}
