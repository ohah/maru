//! LSP 자동완성 목록(docs/editor-surface-tooling.md §8.2g · native-editor-ui §8.2) — `CompletionList{isIncomplete, items}` 또는
//! `CompletionItem[]` 을 항목으로 펴고, **로컬 필터**(접두사, 대소문자 무시)·**정렬**(`sortText`, 같으면 label)·`preselect` 를 계산하며,
//! 고른 항목을 §3.6 의 `Change[]`(주 편집 `[word_start, caret)` → newText + `additionalTextEdits`, 한 delta)로 만든다. 슬라이스는 응답
//! 트리를 빌린다(트리가 사는 동안 유효) — 제품이 필요한 것을 복사한다. 순수 계산.

const std = @import("std");
const delta_mod = @import("../editor/delta.zig");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const text_edits = @import("text_edits.zig");
const LineIndex = @import("../editor/line_index.zig").LineIndex;

pub const Pos = struct { line: u32, character: u32 };

pub const Item = struct {
    label: []const u8,
    /// 필터 기준(`filterText` 없으면 label).
    filter: []const u8,
    /// 정렬 기준(`sortText` 없으면 label).
    sort: []const u8,
    /// 넣을 글(`textEdit.newText` → `insertText` → label).
    insert: []const u8,
    detail: ?[]const u8 = null,
    preselect: bool = false,
    /// `textEdit.range`(있을 때) — `start` 가 낱말 시작을 이긴다(§8.2g 「낱말」).
    edit_range: ?struct { start: Pos, end: Pos } = null,
    /// `additionalTextEdits`(응답 트리의 배열).
    additional: ?[]std.json.Value = null,
};

pub const List = struct {
    items: []Item = &.{},
    incomplete: bool = false,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        if (self.items.len > 0) allocator.free(self.items);
        self.* = .{};
    }
};

pub const Error = error{ Malformed, OutOfMemory };

/// `result` 는 응답의 `result`. `null` 이면 빈 목록. 모양이 틀린 항목은 건너뛴다(목록 하나가 통째로 죽지 않게) — 배열도 객체도 아니면 `Malformed`.
pub fn parse(allocator: std.mem.Allocator, result: ?std.json.Value) Error!List {
    const v = result orelse return .{};
    var incomplete = false;
    const arr: []std.json.Value = switch (v) {
        .array => |a| a.items,
        .object => |o| blk: {
            if (o.get("isIncomplete")) |inc| incomplete = inc == .bool and inc.bool;
            const items = o.get("items") orelse return error.Malformed;
            if (items != .array) return error.Malformed;
            break :blk items.array.items;
        },
        .null => return .{},
        else => return error.Malformed,
    };
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(allocator);
    for (arr) |it| {
        if (it != .object) continue;
        const o = it.object;
        const label = strOf(o.get("label")) orelse continue;
        var item: Item = .{ .label = label, .filter = strOf(o.get("filterText")) orelse label, .sort = strOf(o.get("sortText")) orelse label, .insert = strOf(o.get("insertText")) orelse label, .detail = strOf(o.get("detail")) };
        if (o.get("preselect")) |p| item.preselect = p == .bool and p.bool;
        if (o.get("textEdit")) |te| if (te == .object) {
            if (strOf(te.object.get("newText"))) |nt| item.insert = nt;
            // `TextEdit.range` 또는 `InsertReplaceEdit.insert`(VS Code `insertMode = insert` 와 같다).
            const range = te.object.get("range") orelse te.object.get("insert");
            if (range) |r| if (r == .object) {
                if (posOf(r.object.get("start"))) |s| if (posOf(r.object.get("end"))) |e| {
                    item.edit_range = .{ .start = s, .end = e };
                };
            };
        };
        if (o.get("additionalTextEdits")) |ad| if (ad == .array and ad.array.items.len > 0) {
            item.additional = ad.array.items;
        };
        try out.append(allocator, item);
    }
    return .{ .items = try out.toOwnedSlice(allocator), .incomplete = incomplete };
}

/// 접두사(대소문자 무시)로 `filter` 가 시작하는 항목의 **첨자**를 — **대소문자까지 맞는 것이 먼저**, 그 안에서 `sort`(같으면 label) 순으로.
/// 빈 접두사면 전부. 대소문자 우선은 clangd 실측에서 나왔다: `pri` 에 `•PRId16`(index 의 매크로) 의 sortText 가 `printf` 보다 앞서 매크로가
/// 창을 채웠다 — VS Code 는 자기 fuzzy 점수(정확한 접두사 가산)를 sortText 앞에 둔다. fuzzy 는 다음 조각이지만 이 한 축은 지금 든다.
pub fn filterSort(allocator: std.mem.Allocator, list: List, prefix: []const u8) error{OutOfMemory}![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    for (list.items, 0..) |it, i| {
        if (startsWithIgnoreCase(it.filter, prefix)) try out.append(allocator, i);
    }
    const Ctx = struct { items: []const Item, prefix: []const u8 };
    std.mem.sort(usize, out.items, Ctx{ .items = list.items, .prefix = prefix }, struct {
        fn less(c: Ctx, a: usize, b: usize) bool {
            const x = c.items[a];
            const y = c.items[b];
            const xe = std.mem.startsWith(u8, x.filter, c.prefix);
            const ye = std.mem.startsWith(u8, y.filter, c.prefix);
            if (xe != ye) return xe;
            const s = std.mem.order(u8, x.sort, y.sort);
            if (s != .eq) return s == .lt;
            return std.mem.order(u8, x.label, y.label) == .lt;
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

/// 정렬된 첨자 목록에서 처음 고를 자리 — `preselect` 가 있으면 그 자리, 없으면 0.
pub fn preselectIndex(list: List, order: []const usize) usize {
    for (order, 0..) |idx, i| if (list.items[idx].preselect) return i;
    return 0;
}

pub fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    if (prefix.len > hay.len) return false;
    for (prefix, hay[0..prefix.len]) |p, h| {
        if (std.ascii.toLower(p) != std.ascii.toLower(h)) return false;
    }
    return true;
}

pub const ChangesError = error{ Overlap, Malformed, OutOfMemory };

/// 고른 항목의 §3.6 변경 목록: 주 편집 `[start, caret)` → `insert`(`start` = `edit_range.start` 가 있으면 그것, 아니면 `word_start`) +
/// `additionalTextEdits`(있으면 `toChanges` 로 — `allow_additional` 이 false 면 버린다: 응답 뒤 문서가 바뀌었고 그 편집이 낱말 앞에서 끝나지
/// 않을 때, §8.2g 「적용」). 정렬·겹침 검사는 하나의 목록에서 한다.
pub fn changesFor(allocator: std.mem.Allocator, item: Item, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding, word_start: usize, caret: usize, allow_additional: bool) ChangesError!text_edits.Changes {
    var start = word_start;
    if (item.edit_range) |r| {
        const s = position.offsetOf(content, lines, r.start.line, r.start.character, enc);
        if (s <= caret) start = s;
    }
    if (start > caret) start = caret;
    var extra: text_edits.Changes = .{};
    defer extra.deinit(allocator);
    if (allow_additional) {
        if (item.additional) |ad| {
            extra = try text_edits.toChanges(allocator, .{ .array = .{ .items = ad, .capacity = ad.len, .allocator = allocator } }, content, lines, enc);
        }
    }
    return merge(allocator, extra.items, start, caret, item.insert);
}

/// `additional`(이미 byte 로 옮긴 것) + 주 편집 `[start, caret)` → `insert` 를 하나의 정렬된 목록으로. 겹치면 `Overlap`. 텍스트는 복사.
pub fn merge(allocator: std.mem.Allocator, additional: []const delta_mod.Change, start: usize, caret: usize, insert: []const u8) ChangesError!text_edits.Changes {
    const n = additional.len + 1;
    var texts = try allocator.alloc([]u8, n);
    var owned: usize = 0;
    errdefer {
        for (texts[0..owned]) |t| allocator.free(t);
        allocator.free(texts);
    }
    const items = try allocator.alloc(delta_mod.Change, n);
    errdefer allocator.free(items);
    for (additional, 0..) |c, i| {
        texts[owned] = try allocator.dupe(u8, c.text);
        owned += 1;
        items[i] = .{ .start = c.start, .end = c.end, .text = texts[i] };
    }
    texts[owned] = try allocator.dupe(u8, insert);
    owned += 1;
    items[n - 1] = .{ .start = @min(start, caret), .end = caret, .text = texts[n - 1] };
    std.mem.sort(delta_mod.Change, items, {}, struct {
        fn f(_: void, a: delta_mod.Change, b: delta_mod.Change) bool {
            return a.start < b.start;
        }
    }.f);
    var prev_end: usize = 0;
    for (items, 0..) |c, i| {
        if (i > 0 and c.start < prev_end) return error.Overlap;
        prev_end = c.end;
    }
    return .{ .items = items, .texts = texts };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn posOf(v: ?std.json.Value) ?Pos {
    const x = v orelse return null;
    if (x != .object) return null;
    const l = x.object.get("line") orelse return null;
    const c = x.object.get("character") orelse return null;
    if (l != .integer or c != .integer or l.integer < 0 or c.integer < 0) return null;
    return .{ .line = @intCast(@min(l.integer, std.math.maxInt(u32))), .character = @intCast(@min(c.integer, std.math.maxInt(u32))) };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const line_index = @import("../editor/line_index.zig");

fn parseJson(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "CPL1 목록 파싱 — 배열·객체(isIncomplete) 두 모양, filterText/sortText/insertText/textEdit/detail/preselect 폴백, 틀린 항목은 건너뜀, null 은 빈 목록 (§8.2g)" {
    const a = testing.allocator;
    var p = try parseJson(a,
        \\{"isIncomplete":true,"items":[
        \\ {"label":"printf","detail":"int (const char *, ...)","sortText":"0001","insertText":"printf"},
        \\ {"label":"add","filterText":"add","textEdit":{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":4}},"newText":"add"},"preselect":true},
        \\ {"label":"fake_import","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"#include \"fake.h\"\n"}]},
        \\ 7, {"nolabel":1}
        \\]}
    );
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    try testing.expect(l.incomplete);
    try testing.expectEqual(@as(usize, 3), l.items.len);
    try testing.expectEqualStrings("printf", l.items[0].label);
    try testing.expectEqualStrings("0001", l.items[0].sort);
    try testing.expectEqualStrings("int (const char *, ...)", l.items[0].detail.?);
    try testing.expectEqualStrings("add", l.items[1].sort); // sortText 없으면 label
    try testing.expectEqualStrings("add", l.items[1].insert); // textEdit.newText
    try testing.expect(l.items[1].preselect);
    try testing.expectEqual(@as(u32, 2), l.items[1].edit_range.?.start.character);
    try testing.expectEqualStrings("fake_import", l.items[2].insert); // insertText 도 textEdit 도 없으면 label
    try testing.expectEqual(@as(usize, 1), l.items[2].additional.?.len);
    var arr = try parseJson(a, "[{\"label\":\"x\"}]");
    defer arr.deinit();
    var l2 = try parse(a, arr.value);
    defer l2.deinit(a);
    try testing.expect(!l2.incomplete and l2.items.len == 1);
    var n = try parse(a, null);
    defer n.deinit(a);
    try testing.expectEqual(@as(usize, 0), n.items.len);
    var bad = try parseJson(a, "\"x\"");
    defer bad.deinit();
    try testing.expectError(error.Malformed, parse(a, bad.value));
    var noitems = try parseJson(a, "{\"isIncomplete\":false}");
    defer noitems.deinit();
    try testing.expectError(error.Malformed, parse(a, noitems.value));
}

test "CPL2 로컬 필터·정렬·preselect — 접두사는 대소문자 무시로 filterText 시작, sortText 순(같으면 label), 빈 접두사는 전부 (§8.2g)" {
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"Zeta\",\"sortText\":\"b\"},{\"label\":\"alpha\",\"sortText\":\"a\"},{\"label\":\"ab\",\"filterText\":\"zz\"},{\"label\":\"Abc\",\"sortText\":\"a\",\"preselect\":true},{\"label\":\"other\"}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    const all = try filterSort(a, l, "");
    defer a.free(all);
    try testing.expectEqual(@as(usize, 5), all.len);
    const o = try filterSort(a, l, "A");
    defer a.free(o);
    // 'A' 로 시작(무시): Abc·alpha — sortText 둘 다 "a" → label 순 Abc < alpha. 'ab' 는 filterText 가 zz 라 빠진다.
    try testing.expectEqual(@as(usize, 2), o.len);
    try testing.expectEqualStrings("Abc", l.items[o[0]].label);
    try testing.expectEqualStrings("alpha", l.items[o[1]].label);
    try testing.expectEqual(@as(usize, 0), preselectIndex(l, o)); // Abc 가 preselect
    const z = try filterSort(a, l, "z");
    defer a.free(z);
    try testing.expectEqual(@as(usize, 2), z.len); // Zeta(label) · ab(filterText zz)
    try testing.expectEqualStrings("ab", l.items[z[0]].label); // sort "ab" < "b"
    try testing.expectEqual(@as(usize, 0), preselectIndex(l, z)); // preselect 없으면 0
    const none = try filterSort(a, l, "q");
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    // 대소문자까지 맞는 것이 먼저 — `a` 에는 alpha 가 Abc 를 이긴다(sortText 는 같다).
    const lower = try filterSort(a, l, "a");
    defer a.free(lower);
    try testing.expectEqual(@as(usize, 2), lower.len);
    try testing.expectEqualStrings("alpha", l.items[lower[0]].label);
    try testing.expectEqualStrings("Abc", l.items[lower[1]].label);
    try testing.expectEqual(@as(usize, 1), preselectIndex(l, lower)); // preselect 는 정렬 뒤의 자리
}

test "CPL3 changesFor — 주 편집은 [start, caret) → insert(textEdit.start 가 낱말 시작을 이긴다), additional 은 합쳐 정렬, 겹치면 거부, 안 허용하면 버림, 인코딩 (§8.2g)" {
    const a = testing.allocator;
    const content = "가 x;\n  pri\n";
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    var p = try parseJson(a,
        \\[{"label":"printf","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"#include <stdio.h>\n"}]},
        \\ {"label":"fromedit","textEdit":{"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":5}},"newText":"E"}},
        \\ {"label":"bad","additionalTextEdits":[{"range":{"start":{"line":1,"character":3},"end":{"line":1,"character":4}},"newText":"q"}]}]
    );
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    const word_start: usize = 9; // "  pri" 의 p (7 + 2)
    const caret: usize = 12;
    var c = try changesFor(a, l.items[0], content, idx, .utf8, word_start, caret, true);
    defer c.deinit(a);
    try testing.expectEqual(@as(usize, 2), c.items.len);
    try testing.expectEqual(@as(usize, 0), c.items[0].start); // import 가 앞
    try testing.expectEqualStrings("#include <stdio.h>\n", c.items[0].text);
    try testing.expectEqual(@as(usize, 9), c.items[1].start);
    try testing.expectEqual(@as(usize, 12), c.items[1].end);
    try testing.expectEqualStrings("printf", c.items[1].text);
    try testing.expect(c.delta().isWellFormed());
    // additional 을 안 허용하면 주 편집만.
    var c0 = try changesFor(a, l.items[0], content, idx, .utf8, word_start, caret, false);
    defer c0.deinit(a);
    try testing.expectEqual(@as(usize, 1), c0.items.len);
    // textEdit.start(줄 1, 글자 1 → byte 8)가 낱말 시작(9)을 이긴다. utf-16 인코딩에서도 줄 1 은 ASCII 라 같다.
    var c1 = try changesFor(a, l.items[1], content, idx, .utf16, word_start, caret, true);
    defer c1.deinit(a);
    try testing.expectEqual(@as(usize, 8), c1.items[0].start);
    try testing.expectEqualStrings("E", c1.items[0].text);
    // additional 이 주 편집과 겹치면 거부.
    try testing.expectError(error.Overlap, changesFor(a, l.items[2], content, idx, .utf8, word_start, caret, true));
    // caret 앞의 edit start 만 인정 — start > caret 이면 caret 으로 접는다.
    var c2 = try changesFor(a, l.items[1], content, idx, .utf8, 12, 8, true);
    defer c2.deinit(a);
    try testing.expectEqual(@as(usize, 8), c2.items[0].start);
    try testing.expectEqual(@as(usize, 8), c2.items[0].end);
}
