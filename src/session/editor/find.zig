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
fn matchAt(line: []const u8, from: usize, needle_utf8: []const u8) ?usize {
    var i = from;
    var n: usize = 0;
    while (n < needle_utf8.len) {
        if (i >= line.len) return null;
        const nl = std.unicode.utf8ByteSequenceLength(needle_utf8[n]) catch return null;
        if (n + nl > needle_utf8.len) return null;
        const hl = std.unicode.utf8ByteSequenceLength(line[i]) catch return null;
        if (i + hl > line.len) return null;
        const want = std.unicode.utf8Decode(needle_utf8[n .. n + nl]) catch return null;
        const have = std.unicode.utf8Decode(line[i .. i + hl]) catch return null;
        if (terminal.selection.foldCase(have) != terminal.selection.foldCase(want)) return null;
        i += hl;
        n += nl;
    }
    return i;
}

/// 문서 줄 배열에서 needle을 찾아 `out`에 채운다(호출자 소유, 매번 비운다).
///
/// **같은 줄 안에서 겹치지 않는다** — 매치 뒤부터 다시 본다. 터미널 검색과 같은 규칙이고,
/// `aaa`에서 `aa`를 찾으면 둘이 아니라 하나다.
///
/// **깨진 UTF-8 줄은 건너뛰지 않고 그 자리만 넘긴다.** 문서는 열 때 UTF-8을 검사하므로(§3.5)
/// 여기 오는 줄은 성한 것이지만, 그 검사가 파일 전체를 보는 것이라 **이 함수 혼자로는 보장이
/// 아니다** — 못 읽는 byte에서 멈추면 그 뒤 줄 내용이 통째로 검색에서 사라진다.
pub fn findMatches(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    needle_utf8: []const u8,
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
            if (matchAt(line, i, needle_utf8)) |end| {
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
            i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        }
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn collect(lines: []const []const u8, needle: []const u8) !std.ArrayList(Match) {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(testing.allocator);
    try findMatches(testing.allocator, lines, needle, &out);
    return out;
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
    var a = try collect(&lines, "hello");
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), a.items.len);

    var b = try collect(&lines, "école");
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), b.items.len);
    try testing.expectEqual(@as(u32, 1), b.items[0].line);
    try testing.expectEqual(@as(u32, 0), b.items[0].start);
    try testing.expectEqual(@as(u32, "ÉCOLE".len), b.items[0].len); // 폴딩이 byte 길이를 보존한다

    var c = try collect(&lines, "αβγ");
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), c.items.len);

    var d = try collect(&lines, "привет");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.items.len);
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
    try findMatches(testing.allocator, &lines, "a", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try findMatches(testing.allocator, &lines, "b", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try findMatches(testing.allocator, &lines, "zzz", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
