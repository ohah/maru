//! 복사·잘라내기(문서 모델 §3.4)의 **순수 판정** — 무엇을 담고 무엇을 지우는가. 시스템 클립보드에 쓰기·문서 적용은
//! 호출자(L4 `app_session/editor` 의 `copySelection`·`cutSelection`)가 한다. 조각 경계의 기억(`clipboard.Meta`)과
//! 붙여넣기 분배는 옆 `../clipboard.zig` 가 소유한다 — 이 파일은 그 기억에 들어갈 값을 만든다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const line_index = @import("../line_index.zig");
const selection = @import("../selection.zig");

const LineIndex = line_index.LineIndex;
const Selection = selection.Selection;

/// 한 번의 복사가 담을 것 — 클립보드 문자열과 조각마다의 끝 offset(`clipboard.Meta.ends` 의 뜻 그대로).
pub const Copied = struct {
    text: []u8,
    ends: []usize,
    /// **선택 없이 복사했는가** — caret 이 있는 줄 전체를 담았다(붙여넣기가 줄 단위로 넣는다).
    from_empty: bool,

    pub fn deinit(self: *Copied, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.ends);
        self.* = undefined;
    }
};

const Range = struct { start: usize, end: usize };

/// **커서가 여럿이면 조각도 여럿이다**(§3.4) — 문서 순서로 `\n` 연결하고 조각 경계를 함께 낸다. **선택이 없으면
/// primary 가 있는 줄 전체**(줄 끝 문자 포함 — 줄 단위 삽입이 그것으로 줄을 만든다). 선택과 빈 caret 이 섞이면 고른
/// 것만 담는다(§3.4 — 빈 caret 은 아무것도 안 보탠다). `sels` 의 순서는 상관없다.
pub fn planCopy(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, primary: Selection) !?Copied {
    if (sels.len == 0) return null;
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);
    for (sels) |sel| {
        const lo = sel.start();
        const hi = @min(sel.end(), content.len);
        if (hi <= lo or lo >= content.len) continue; // caret 뿐이거나 낡은 offset 이다
        try ranges.append(allocator, .{ .start = lo, .end = hi });
    }
    const from_empty = ranges.items.len == 0;
    if (from_empty) {
        const line = lines.line(lines.lineAt(@min(primary.focus, content.len))) orelse return null;
        try ranges.append(allocator, .{ .start = line.start, .end = line.end_with_ending });
    }
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var ends: std.ArrayList(usize) = .empty;
    errdefer ends.deinit(allocator);
    for (ranges.items, 0..) |r, i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, content[r.start..r.end]);
        try ends.append(allocator, out.items.len);
    }
    const text = try out.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    return .{ .text = text, .ends = try ends.toOwnedSlice(allocator), .from_empty = from_empty };
}

/// 잘라내기가 무엇을 지울지.
pub const Cut = union(enum) {
    /// **선택이 하나도 없다 = 줄 전체다**(§3.4) — primary 의 줄을 고르고 나머지 커서는 버린 뒤 지운다.
    whole_line: Selection,
    /// 모든 커서가 선택이다 — 그대로 지운다.
    all,
    /// **선택과 빈 caret 이 섞였다 — 고른 것만 지운다**(§3.4, 결함 9). 지우기 전 남길 선택(`keep` — primary 먼저)과,
    /// 지운 **뒤** 빈 caret 을 되돌릴 자리(`empties`). 빈 caret 마다 다음 글자를 지우면 클립보드에도 문서에도 없는 글자가
    /// 사라졌다.
    chosen: struct { keep: []Selection, empties: []usize },

    pub fn deinit(self: *Cut, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .chosen => |c| {
                allocator.free(c.keep);
                allocator.free(c.empties);
            },
            else => {},
        }
        self.* = undefined;
    }
};

/// `sels` 는 문서 순서, `primary` 는 그 안의 primary 인덱스(`selectionsForEdit` 의 모양). 줄을 못 찾으면 `null`.
pub fn planCut(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, sels: []const Selection, primary: usize) !?Cut {
    if (sels.len == 0 or primary >= sels.len) return null;
    var empties: usize = 0;
    for (sels) |sel| {
        if (sel.isEmpty()) empties += 1;
    }
    if (empties == sels.len) {
        const line = lines.line(lines.lineAt(@min(sels[primary].focus, content.len))) orelse return null;
        return .{ .whole_line = Selection.fromPoints(line.start, line.end_with_ending) };
    }
    if (empties == 0) return .all;

    // 남길 것 — primary 가 빈 caret 이면 문서상 첫 선택이 이어받는다.
    const keep = try allocator.alloc(Selection, sels.len - empties);
    errdefer allocator.free(keep);
    var k: usize = 1;
    keep[0] = if (sels[primary].isEmpty()) blk: {
        for (sels) |sel| if (!sel.isEmpty()) break :blk sel;
        unreachable; // 위에서 선택이 하나 이상임을 확인했다
    } else sels[primary];
    var taken_first = !sels[primary].isEmpty();
    for (sels, 0..) |sel, i| {
        if (sel.isEmpty()) continue;
        if (!sels[primary].isEmpty() and i == primary) continue;
        if (!taken_first) {
            taken_first = true; // primary 로 올린 첫 선택은 이미 keep[0]
            continue;
        }
        keep[k] = sel;
        k += 1;
    }
    // 빈 caret 은 그 앞에서 지운 길이만큼 당긴 자리.
    const at = try allocator.alloc(usize, empties);
    var w: usize = 0;
    for (sels) |sel| {
        if (!sel.isEmpty()) continue;
        var removed: usize = 0;
        for (sels) |other| {
            if (!other.isEmpty() and other.end() <= sel.focus) removed += other.end() - other.start();
        }
        at[w] = sel.focus - removed;
        w += 1;
    }
    return .{ .chosen = .{ .keep = keep, .empties = at } };
}

// ── 순수 test ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "복사 — 커서마다 조각, 문서 순서로 잇고 경계를 기억한다" {
    const a = testing.allocator;
    const content = "ab cd ef\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // 순서가 뒤집혀 와도 문서 순서로 담는다.
    var c = (try planCopy(a, content, lines, &.{ Selection.fromPoints(6, 8), Selection.fromPoints(0, 2) }, Selection.fromPoints(6, 8))).?;
    defer c.deinit(a);
    try testing.expectEqualStrings("ab\nef", c.text);
    try testing.expectEqualSlices(usize, &.{ 2, 5 }, c.ends);
    try testing.expect(!c.from_empty);
}

test "복사 — 선택이 없으면 primary 의 줄 전체(줄 끝 포함)" {
    const a = testing.allocator;
    const content = "ab\ncd\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var c = (try planCopy(a, content, lines, &.{ Selection.at(4), Selection.at(1) }, Selection.at(4))).?;
    defer c.deinit(a);
    try testing.expectEqualStrings("cd\n", c.text);
    try testing.expect(c.from_empty);
}

test "결함 9 — 섞인 잘라내기는 고른 것만 지우고 빈 caret 을 당긴 자리에 되돌린다" {
    const a = testing.allocator;
    const content = "ab cd\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // 문서 순서: [0,2) "ab", 4 (빈 caret). primary 는 선택.
    var cut = (try planCut(a, content, lines, &.{ Selection.fromPoints(0, 2), Selection.at(4) }, 0)).?;
    defer cut.deinit(a);
    try testing.expectEqual(@as(usize, 1), cut.chosen.keep.len);
    try testing.expectEqual(@as(usize, 2), cut.chosen.keep[0].end());
    try testing.expectEqualSlices(usize, &.{2}, cut.chosen.empties); // "c|d"
    // 복사한 것도 "ab" 뿐이다.
    var c = (try planCopy(a, content, lines, &.{ Selection.fromPoints(0, 2), Selection.at(4) }, Selection.fromPoints(0, 2))).?;
    defer c.deinit(a);
    try testing.expectEqualStrings("ab", c.text);
}

test "잘라내기 — primary 가 빈 caret 이면 문서상 첫 선택이 primary 를 이어받는다" {
    const a = testing.allocator;
    const content = "ab cd ef\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var cut = (try planCut(a, content, lines, &.{ Selection.at(0), Selection.fromPoints(3, 5), Selection.fromPoints(6, 8) }, 0)).?;
    defer cut.deinit(a);
    try testing.expectEqual(@as(usize, 2), cut.chosen.keep.len);
    try testing.expectEqual(@as(usize, 3), cut.chosen.keep[0].start());
    try testing.expectEqual(@as(usize, 6), cut.chosen.keep[1].start());
    try testing.expectEqualSlices(usize, &.{0}, cut.chosen.empties);
}

test "잘라내기 — 선택이 없으면 줄 전체, 모두 선택이면 그대로" {
    const a = testing.allocator;
    const content = "ab\ncd\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var whole = (try planCut(a, content, lines, &.{Selection.at(4)}, 0)).?;
    defer whole.deinit(a);
    try testing.expectEqual(@as(usize, 3), whole.whole_line.start());
    try testing.expectEqual(@as(usize, 6), whole.whole_line.end());
    var all = (try planCut(a, content, lines, &.{Selection.fromPoints(0, 2)}, 0)).?;
    defer all.deinit(a);
    try testing.expect(all == .all);
}
