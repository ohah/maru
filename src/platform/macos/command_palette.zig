//! 커맨드 팝업 카탈로그 필터 — **platform 전용 순수 로직**. UI 상태(open/query/preedit/selected)는 chrome 컴포넌트
//! (src/chrome/components/palette.zig)로 이주했다(C1b). 여기엔 chrome이 만질 수 없는 것만 남는다: command_catalog
//! (forbidden import)를 쿼리로 필터해 인덱스를 내고, 선택 인덱스를 Action으로 해석하는 것. AppSession이 이 두
//! 함수를 호출해 필터 결과(palette_filtered)를 들고, 컴포넌트엔 필터된 행(Row)만 주입한다(neutral 경계 보존).
//! 베이스/의사결정: action 집합은 config/action.zig(단일 출처), title은 UI 표시 문자열이라 command_catalog에 둔다.

const std = @import("std");
const maru = @import("maru");
const command_catalog = @import("command_catalog.zig");

const Action = maru.config.Action;

/// ASCII 대소문자 무시 부분일치 — needle이 비면 true(전체 통과). title은 영문이라 ASCII fold로 충분.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

/// 쿼리로 command_catalog.entries를 필터해 통과한 인덱스를 `out`에 채운다(title 대소문자 무시 부분일치, 표시 순서).
/// `out`은 호출자 소유(capacity 재사용 — clearRetainingCapacity 후 채운다). OOM이면 에러(호출자가 비워 안전 처리).
pub fn filter(allocator: std.mem.Allocator, query: []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    for (command_catalog.entries, 0..) |entry, i| {
        if (containsIgnoreCase(entry.title, query)) try out.append(allocator, i);
    }
}

/// 필터된 인덱스 목록에서 selected 위치의 Action(없으면 null). AppSession이 받아 dispatch + hide 한다. selected는
/// filtered 범위 안이라고 가정하지 않는다(범위 밖이면 null) — 컴포넌트 clamp와 platform 필터가 한 frame 어긋나도 안전.
pub fn actionAt(filtered: []const usize, selected: usize) ?Action {
    if (selected >= filtered.len) return null;
    return command_catalog.entries[filtered[selected]].action;
}

test "containsIgnoreCase: 빈 needle 통과·대소문자 무시·부분일치" {
    try std.testing.expect(containsIgnoreCase("Split Right", ""));
    try std.testing.expect(containsIgnoreCase("Split Right", "spl"));
    try std.testing.expect(containsIgnoreCase("Split Right", "RIGHT"));
    try std.testing.expect(containsIgnoreCase("Split Right", "it R"));
    try std.testing.expect(!containsIgnoreCase("Split Right", "zzz"));
    try std.testing.expect(!containsIgnoreCase("ab", "abc")); // needle이 더 길면 false
}

test "filter: 빈 쿼리=전부·부분일치·actionAt 해석" {
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
    // 선택이 범위 밖이면 null(크래시 없음).
    try std.testing.expect(actionAt(out.items, 5) == null);

    // 매칭 없으면 빈 목록·actionAt null.
    try filter(allocator, "zzzznope", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(actionAt(out.items, 0) == null);
}

test "filter: 'find'로 Find 명령군이 팝업에 노출된다(toggle_find/replace/next/previous)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(allocator);

    // "find" → Find / Find and Replace / Find: Match Case / Find: Whole Word /
    // Find: In Selection / Find Next / Find Previous 7개. 카탈로그 순서대로.
    //
    // **바꾸기와 규칙 토글이 팔레트에 있어야 하는 이유**: 빌트인 `⌥⌘F`·`⌥⌘C`·`⌥⌘W`는 사용자가
    // `unbind`하거나 다른 액션으로 덮어쓸 수 있다(configuration-input.md §keybind). 그때 팔레트가
    // 유일한 도달 경로다.
    try filter(allocator, "find", &out);
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expect(actionAt(out.items, 0).? == .toggle_find);
    try std.testing.expect(actionAt(out.items, 1).? == .toggle_find_replace);
    try std.testing.expect(actionAt(out.items, 2).? == .toggle_find_match_case);
    try std.testing.expect(actionAt(out.items, 3).? == .toggle_find_whole_word);
    try std.testing.expect(actionAt(out.items, 4).? == .toggle_find_in_selection);
    try std.testing.expect(actionAt(out.items, 5).? == .find_next);
    try std.testing.expect(actionAt(out.items, 6).? == .find_previous);
}
