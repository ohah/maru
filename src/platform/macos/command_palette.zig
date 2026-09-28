//! 커맨드 팝업 카탈로그 필터 — **platform 전용 순수 로직**. UI 상태(open/query/preedit/selected)는 chrome 컴포넌트
//! (src/chrome/components/palette.zig)로 이주했다(C1b). 여기엔 chrome이 만질 수 없는 것만 남는다: command_catalog
//! (forbidden import)를 쿼리로 필터해 인덱스를 내고, 선택 인덱스를 Action으로 해석하는 것. AppSession이 이 두
//! 함수를 호출해 필터 결과(palette_filtered)를 들고, 컴포넌트엔 필터된 행(Row)만 주입한다(neutral 경계 보존).
//! 베이스/의사결정: action 집합은 config/action.zig(단일 출처), title은 UI 표시 문자열이라 command_catalog에 둔다.

const std = @import("std");
const maru = @import("maru");
const command_catalog = @import("command_catalog.zig");

const Action = maru.config.Action;

/// 제목의 문자들이 쿼리 순서대로 나타나면 후보가 된다. 글자 단위로 걸어 UTF-8 한글의 바이트를
/// 섞어 가짜 일치를 만들지 않는다. 연속·앞쪽·단어 시작을 우대하되 빈 쿼리는 카탈로그 순서를 유지한다.
fn fuzzyScore(haystack: []const u8, needle: []const u8) ?i64 {
    if (needle.len == 0) return 0;
    var h = (std.unicode.Utf8View.init(haystack) catch return null).iterator();
    var n = (std.unicode.Utf8View.init(needle) catch return null).iterator();
    var want = n.nextCodepoint() orelse return 0;
    var score: i64 = 0;
    var pos: i64 = 0;
    var previous: ?i64 = null;
    var previous_cp: u21 = 0;
    while (h.nextCodepoint()) |cp| : (pos += 1) {
        const equal = if (cp < 128 and want < 128)
            std.ascii.toLower(@intCast(cp)) == std.ascii.toLower(@intCast(want))
        else
            cp == want;
        if (equal) {
            score += 10;
            if (pos == 0) score += 80;
            if (previous) |p| {
                if (pos == p + 1) score += 30 else score -= @min(pos - p - 1, 20);
            }
            if (pos > 0 and (previous_cp == ' ' or previous_cp == ':' or previous_cp == '_' or previous_cp == '-' or
                (previous_cp >= 'a' and previous_cp <= 'z' and cp >= 'A' and cp <= 'Z'))) score += 20;
            previous = pos;
            want = n.nextCodepoint() orelse return score - pos + @as(i64, if (haystack.len == needle.len) 100 else 0);
        }
        previous_cp = cp;
    }
    return null;
}

fn entryScore(entry: command_catalog.Entry, query: []const u8) ?i64 {
    const title_score = fuzzyScore(entry.title, query);
    const ko_score = fuzzyScore(entry.search_ko, query);
    if (title_score) |a| return if (ko_score) |b| @max(a, b) else a;
    return ko_score;
}

/// 쿼리로 command_catalog.entries를 필터해 통과한 인덱스를 `out`에 채운다. 빈 쿼리는 카탈로그 순서,
/// 입력이 있으면 점수 내림차순(동점은 카탈로그 순서). 결과 인덱스는 view·Enter가 함께 소비한다.
/// `out`은 호출자 소유(capacity 재사용 — clearRetainingCapacity 후 채운다). OOM이면 에러(호출자가 비워 안전 처리).
pub fn filter(allocator: std.mem.Allocator, query: []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    // macOS IME는 조합 자모(L+V+T)를 내기도 한다. 검색용 사본만 완성형으로 맞춘다.
    // 입력 모델의 원본 바이트를 바꾸면 caret와 AppKit marked range가 어긋난다.
    const normalized = try maru.grapheme.composeHangul(allocator, query);
    defer allocator.free(normalized);
    for (command_catalog.entries, 0..) |entry, i| {
        if (entryScore(entry, normalized) != null) try out.append(allocator, i);
    }
    if (normalized.len > 0) std.mem.sort(usize, out.items, normalized, struct {
        fn less(q: []const u8, a: usize, b: usize) bool {
            const sa = entryScore(command_catalog.entries[a], q).?;
            const sb = entryScore(command_catalog.entries[b], q).?;
            return if (sa != sb) sa > sb else a < b;
        }
    }.less);
}

/// 필터된 인덱스 목록에서 selected 위치의 Action(없으면 null). AppSession이 받아 dispatch + hide 한다. selected는
/// filtered 범위 안이라고 가정하지 않는다(범위 밖이면 null) — 컴포넌트 clamp와 platform 필터가 한 frame 어긋나도 안전.
pub fn actionAt(filtered: []const usize, selected: usize) ?Action {
    if (selected >= filtered.len) return null;
    return command_catalog.entries[filtered[selected]].action;
}

test "fuzzyScore: 부분열·대소문자·연속·UTF-8 코드포인트" {
    try std.testing.expectEqual(@as(?i64, 0), fuzzyScore("Split Right", ""));
    try std.testing.expect(fuzzyScore("Split Right", "srt") != null);
    try std.testing.expect(fuzzyScore("Split Right", "RIGHT") != null);
    try std.testing.expect(fuzzyScore("Split Right", "spl").? > fuzzyScore("Split Right", "slt").?);
    try std.testing.expect(fuzzyScore("Split Right", "zzz") == null);
    try std.testing.expect(fuzzyScore("ab", "abc") == null);
    try std.testing.expect(fuzzyScore("새 터미널", "새터") != null);
    try std.testing.expect(fuzzyScore("새 터미널", "새틀") == null);
}

test "filter: 빈 쿼리=전부·fuzzy 순위·actionAt 해석" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(allocator);

    try filter(allocator, "", &out);
    try std.testing.expectEqual(command_catalog.entries.len, out.items.len); // 빈 쿼리 = 전부

    // "split" → terminal pane 2개. FP16에서 도크 group split 액션 2개가 사라졌다.
    try filter(allocator, "split", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(actionAt(out.items, 0).? == .split_horizontal);
    try std.testing.expect(actionAt(out.items, 1).? == .split_vertical);
    try filter(allocator, "new t", &out);
    try std.testing.expect(out.items.len > 1); // New Terminal 외 New Editor Tab 등도 부분열 후보
    try std.testing.expect(actionAt(out.items, 0).? == .new_term); // 연속 구간이 더 길어 우선
    // 선택이 범위 밖이면 null(크래시 없음).
    try std.testing.expect(actionAt(out.items, out.items.len) == null);

    // 매칭 없으면 빈 목록·actionAt null.
    try filter(allocator, "zzzznope", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(actionAt(out.items, 0) == null);
}

test "filter: 'find'로 Find 명령군이 팝업에 노출된다(toggle_find/replace/next/previous)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(allocator);

    // "find" → Find 명령군 8개. fuzzy는 점수 순서라 카탈로그 순서에 고정하지 않는다.
    //
    // **바꾸기와 규칙 토글이 팔레트에 있어야 하는 이유**: 빌트인 `⌥⌘F`·`⌥⌘C`·`⌥⌘W`는 사용자가
    // `unbind`하거나 다른 액션으로 덮어쓸 수 있다(configuration-input.md §keybind). 그때 팔레트가
    // 유일한 도달 경로다.
    try filter(allocator, "find", &out);
    try std.testing.expect(out.items.len >= 8); // fuzzy 부분열은 관련 없는 낮은 순위 후보도 남길 수 있다
    try std.testing.expect(actionAt(out.items, 0).? == .toggle_find); // 정확한 짧은 제목이 먼저
    for ([_]Action{
        .toggle_find_replace,      .toggle_find_match_case, .toggle_find_whole_word,
        .toggle_find_in_selection, .toggle_find_diff_side,  .find_next,
        .find_previous,
    }) |expected| {
        var found = false;
        for (out.items, 0..) |_, selected| {
            if (std.meta.eql(actionAt(out.items, selected).?, expected)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "한국어 검색 별칭: 모든 명령을 영어 제목 그대로 표시하고 한글 IME 쿼리로 찾는다" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(allocator);
    for (command_catalog.entries) |entry| {
        try std.testing.expect(entry.search_ko.len > 0); // 새 명령도 한국어 검색 경로를 빠뜨리지 않는다
    }
    try filter(allocator, "새 터미널", &out);
    try std.testing.expectEqual(Action.new_term, actionAt(out.items, 0).?);
    try filter(allocator, "새 터미널", &out); // macOS IME가 내는 conjoining NFD 자모
    try std.testing.expectEqual(Action.new_term, actionAt(out.items, 0).?);
    try filter(allocator, "오른쪽 분할", &out);
    try std.testing.expectEqual(Action.split_horizontal, actionAt(out.items, 0).?);
    try filter(allocator, "빠른 수정", &out);
    try std.testing.expectEqual(Action.quick_fix, actionAt(out.items, 0).?);
}
