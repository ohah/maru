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
    /// `labelDetails.detail`(§8.2g-c) — label 바로 뒤에 붙는 꼬리(시그니처·import 표시).
    label_detail: ?[]const u8 = null,
    /// `labelDetails.description`(§8.2g-c) — 오른쪽 열(없으면 행은 `detail` 을 쓴다).
    description: ?[]const u8 = null,
    /// `documentation`(§8.2g-d) — 문자열 또는 `MarkupContent.value`(마크다운/평문 — 패널이 `hover_text.reduce` 로 줄을 만든다).
    documentation: ?[]const u8 = null,
    preselect: bool = false,
    /// LSP `kind`(숫자, 없으면 0). 버퍼 단어는 `word_kind`.
    kind: u8 = 0,
    /// 원래 항목(트리 안) — `completionItem/resolve` 에 그대로 되돌려 준다. 버퍼 단어는 `null`.
    raw: ?std.json.Value = null,
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
        var item: Item = .{ .label = label, .filter = strOf(o.get("filterText")) orelse label, .sort = strOf(o.get("sortText")) orelse label, .insert = strOf(o.get("insertText")) orelse label, .detail = strOf(o.get("detail")), .raw = it };
        if (o.get("preselect")) |p| item.preselect = p == .bool and p.bool;
        if (o.get("labelDetails")) |ld| if (ld == .object) {
            item.label_detail = strOf(ld.object.get("detail"));
            item.description = strOf(ld.object.get("description"));
        };
        item.documentation = docOf(o.get("documentation"));
        if (o.get("kind")) |k| if (k == .integer and k.integer >= 0 and k.integer <= 255) {
            item.kind = @intCast(k.integer);
        };
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

/// fuzzy 점수(§8.2g-b) — 접두사의 글자들이 `filter` 에 **순서대로 부분열**로 있으면 후보. 높을수록 앞. 없으면 `null`.
/// 정확한 접두사(대소문자까지) > 접두사(무시) > 낱말 경계 일치(`_`·camelCase 뒤) > 연속 일치 > 나머지 — ①-a 의 「대소문자 맞는 접두사 우선」
/// (clangd 실측: `pri` 에 `•PRId16` 가 `printf` 를 앞섰다)이 그대로 최상위다. 빈 접두사는 0(전부 같다).
pub fn fuzzyScore(filter: []const u8, prefix: []const u8) ?u32 {
    if (prefix.len == 0) return 0;
    if (std.mem.startsWith(u8, filter, prefix)) return 1_000_000;
    if (startsWithIgnoreCase(filter, prefix)) return 900_000;
    // 부분열 — 앞에서부터 탐욕으로 맞추되 경계·연속 가산.
    var score: u32 = 0;
    var fi: usize = 0;
    var prev_match: ?usize = null;
    for (prefix) |pc| {
        var found: ?usize = null;
        while (fi < filter.len) : (fi += 1) {
            if (std.ascii.toLower(filter[fi]) == std.ascii.toLower(pc)) {
                found = fi;
                fi += 1;
                break;
            }
        }
        const at = found orelse return null;
        score += 10;
        if (filter[at] == pc) score += 2; // 대소문자까지
        if (at == 0 or filter[at - 1] == '_' or (std.ascii.isUpper(filter[at]) and std.ascii.isLower(filter[at - 1]))) score += 30; // 낱말 경계
        if (prev_match) |pm| if (pm + 1 == at) {
            score += 20; // 연속
        };
        prev_match = at;
    }
    // 짧은 filter 가 같은 점수면 앞 — 접두사가 차지하는 비율이 크다.
    return score * 1000 + @as(u32, @intCast(1000 -| @min(filter.len, 999)));
}

/// 후보의 **첨자**를 점수 내림차순, 같으면 `sort`(같으면 label) 순으로. 빈 접두사면 전부(점수 0).
pub fn filterSort(allocator: std.mem.Allocator, list: List, prefix: []const u8) error{OutOfMemory}![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    var scores = try allocator.alloc(u32, list.items.len);
    defer allocator.free(scores);
    for (list.items, 0..) |it, i| {
        if (fuzzyScore(it.filter, prefix)) |sc| {
            scores[i] = sc;
            try out.append(allocator, i);
        }
    }
    const Ctx = struct { items: []const Item, scores: []const u32 };
    std.mem.sort(usize, out.items, Ctx{ .items = list.items, .scores = scores }, struct {
        fn less(c: Ctx, a: usize, b: usize) bool {
            if (c.scores[a] != c.scores[b]) return c.scores[a] > c.scores[b];
            const x = c.items[a];
            const y = c.items[b];
            const s = std.mem.order(u8, x.sort, y.sort);
            if (s != .eq) return s == .lt;
            return std.mem.order(u8, x.label, y.label) == .lt;
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

/// 버퍼 단어의 kind(LSP 숫자 밖 — `Text` 는 1 이지만 우리 것은 따로 표시한다).
pub const word_kind: u8 = 255;

/// kind 글자(§8.2g-b) — 등폭 상자의 한 글자 열.
pub fn kindGlyph(kind: u8) u8 {
    return switch (kind) {
        2, 3, 4 => 'f', // Method · Function · Constructor
        5, 6, 21 => 'v', // Field · Variable · Constant
        7, 8, 13, 22, 23 => 't', // Class · Interface · Enum · Struct · Event → 타입
        14 => 'k', // Keyword
        9 => 'm', // Module
        15 => 's', // Snippet
        10 => 'p', // Property
        word_kind => 'w',
        else => ' ',
    };
}

pub const max_word_scan_bytes: usize = 1024 * 1024;
pub const max_words: usize = 2000;

/// 버퍼 단어 후보(§8.2g-b) — 식별자 run 을 첫 등장 순으로 중복 없이, 앞 `max_word_scan_bytes`·`max_words` 까지. 숫자로 시작하는 run 과
/// `exclude`(지금 치는 낱말)는 뺀다. 슬라이스는 `content` 를 빌린다.
pub fn bufferWords(allocator: std.mem.Allocator, content: []const u8, exclude: []const u8) error{OutOfMemory}![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    const limit = @min(content.len, max_word_scan_bytes);
    var i: usize = 0;
    while (i < limit and out.items.len < max_words) {
        if (!isIdent(content[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < limit and isIdent(content[j])) j += 1;
        const word = content[i..j];
        i = j;
        if (std.ascii.isDigit(word[0])) continue;
        if (std.mem.eql(u8, word, exclude)) continue;
        const gop = try seen.getOrPut(allocator, word);
        if (gop.found_existing) continue;
        try out.append(allocator, word);
    }
    return out.toOwnedSlice(allocator);
}

pub fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// LSP 항목 + 버퍼 단어 병합(§8.2g-b) — 같은 label 은 LSP 것이 이긴다(단어를 버린다). 버퍼 단어는 `sort` = `~`+단어(LSP 뒤), kind `word_kind`.
/// 결과 항목의 `sort` 문자열은 `allocator` 소유 — `MergedList.deinit` 이 놓는다.
pub const MergedList = struct {
    list: List,
    sorts: [][]u8,

    pub fn deinit(self: *MergedList, allocator: std.mem.Allocator) void {
        for (self.sorts) |s| allocator.free(s);
        if (self.sorts.len > 0) allocator.free(self.sorts);
        self.list.deinit(allocator);
    }
};

pub fn mergeSources(allocator: std.mem.Allocator, lsp_items: []const Item, words: []const []const u8, incomplete: bool) error{OutOfMemory}!MergedList {
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(allocator);
    var sorts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (sorts.items) |s| allocator.free(s);
        sorts.deinit(allocator);
    }
    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(allocator);
    for (lsp_items) |it| {
        try items.append(allocator, it);
        try labels.put(allocator, it.label, {});
    }
    for (words) |w| {
        if (labels.contains(w)) continue;
        const sort = try std.fmt.allocPrint(allocator, "~{s}", .{w});
        {
            // append 가 실패하면 여기서만 놓는다 — 들어간 뒤로는 바깥 `sorts` 의 errdefer 가 놓는다(둘이 겹치면 이중 해제).
            errdefer allocator.free(sort);
            try sorts.append(allocator, sort);
        }
        try items.append(allocator, .{ .label = w, .filter = w, .sort = sort, .insert = w, .kind = word_kind });
    }
    // 두 슬라이스를 차례로 굳힌다 — 둘째가 실패하면 첫째를 놓는다(FailingAllocator 판정자가 이 길을 지난다).
    const sorts_slice = try sorts.toOwnedSlice(allocator);
    errdefer {
        for (sorts_slice) |s| allocator.free(s);
        allocator.free(sorts_slice);
    }
    const items_slice = try items.toOwnedSlice(allocator);
    return .{ .list = .{ .items = items_slice, .incomplete = incomplete }, .sorts = sorts_slice };
}

/// `completionItem/resolve` 응답을 항목에 합친다(§8.2g-b) — `additionalTextEdits`·`insertText`/`textEdit`·`detail` 이 오면 갈아 끼운다.
/// 응답 트리를 빌린다.
pub fn applyResolved(item: *Item, resolved: std.json.Value) void {
    if (resolved != .object) return;
    const o = resolved.object;
    if (o.get("additionalTextEdits")) |ad| if (ad == .array and ad.array.items.len > 0) {
        item.additional = ad.array.items;
    };
    if (strOf(o.get("detail"))) |d| item.detail = d;
    if (docOf(o.get("documentation"))) |d| item.documentation = d; // §8.2g-d — 패널의 글
    if (strOf(o.get("insertText"))) |t| item.insert = t;
    if (o.get("textEdit")) |te| if (te == .object) {
        if (strOf(te.object.get("newText"))) |nt| item.insert = nt;
    };
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

/// `documentation` — 문자열이거나 `MarkupContent{kind, value}`(§8.2g-d). 그 밖은 없음.
fn docOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |t| t,
        .object => |o| strOf(o.get("value")),
        else => null,
    };
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
    // 'A': Abc(정확한 접두사) → alpha(무시 접두사) → Zeta(부분열 `a`). 'ab' 는 filterText 가 zz 라 빠지고, other 에는 a 가 없다.
    try testing.expectEqual(@as(usize, 3), o.len);
    try testing.expectEqualStrings("Abc", l.items[o[0]].label);
    try testing.expectEqualStrings("alpha", l.items[o[1]].label);
    try testing.expectEqualStrings("Zeta", l.items[o[2]].label);
    try testing.expectEqual(@as(usize, 0), preselectIndex(l, o)); // Abc 가 preselect
    const z = try filterSort(a, l, "z");
    defer a.free(z);
    try testing.expectEqual(@as(usize, 2), z.len); // Zeta(label) · ab(filterText zz)
    try testing.expectEqualStrings("ab", l.items[z[0]].label); // sort "ab" < "b"
    try testing.expectEqual(@as(usize, 0), preselectIndex(l, z)); // preselect 없으면 0
    const none = try filterSort(a, l, "q");
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    // 대소문자까지 맞는 것이 먼저 — `a` 에는 alpha 가 Abc 를 이긴다(sortText 는 같다). Zeta 는 부분열로 뒤.
    const lower = try filterSort(a, l, "a");
    defer a.free(lower);
    try testing.expectEqual(@as(usize, 3), lower.len);
    try testing.expectEqualStrings("alpha", l.items[lower[0]].label);
    try testing.expectEqualStrings("Abc", l.items[lower[1]].label);
    try testing.expectEqual(@as(usize, 1), preselectIndex(l, lower)); // preselect 는 정렬 뒤의 자리
}

test "CPL4 버퍼 단어 — 첫 등장 순·중복 없음·숫자 시작 제외·치는 낱말 제외·상한 (§8.2g-b)" {
    const a = testing.allocator;
    const w = try bufferWords(a, "int printf(int x) { return x + 42 + printf2; } // 가나 printf", "pri");
    defer a.free(w);
    try testing.expectEqual(@as(usize, 6), w.len);
    try testing.expectEqualStrings("int", w[0]);
    try testing.expectEqualStrings("printf", w[1]);
    try testing.expectEqualStrings("x", w[2]);
    try testing.expectEqualStrings("return", w[3]);
    try testing.expectEqualStrings("printf2", w[4]); // 42 는 숫자 시작이라 빠진다
    try testing.expectEqualStrings("가나", w[5]);
    const ex = try bufferWords(a, "foo foo bar", "foo");
    defer a.free(ex);
    try testing.expectEqual(@as(usize, 1), ex.len);
    try testing.expectEqualStrings("bar", ex[0]);
    // 상한 — 2,000 개 넘는 단어는 버린다.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(a);
    var n: usize = 0;
    var nb: [16]u8 = undefined;
    while (n < 2500) : (n += 1) try big.appendSlice(a, try std.fmt.bufPrint(&nb, "w{d} ", .{n}));
    const capped = try bufferWords(a, big.items, "");
    defer a.free(capped);
    try testing.expectEqual(max_words, capped.len);
    // 바이트 상한 — 앞 1 MiB 뒤의 단어는 안 본다(적대적 1회차 A5: 개수 상한만 재고 있었다).
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(a);
    try long.appendNTimes(a, 'a', max_word_scan_bytes + 1);
    try long.appendSlice(a, " zzz");
    const cut = try bufferWords(a, long.items, "");
    defer a.free(cut);
    try testing.expectEqual(@as(usize, 1), cut.len);
    try testing.expectEqual(max_word_scan_bytes, cut[0].len); // 상한에서 잘린 run
}

test "CPL5 병합 — 같은 label 은 LSP 것이 이기고, 버퍼 단어는 sortText `~`+단어·kind w 로 뒤에 선다 (§8.2g-b)" {
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"printf\",\"detail\":\"int\",\"kind\":3},{\"label\":\"puts\"}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    const words = [_][]const u8{ "printf", "pri", "put" };
    var m = try mergeSources(a, l.items, &words, false);
    defer m.deinit(a);
    try testing.expectEqual(@as(usize, 4), m.list.items.len); // printf(LSP)·puts·pri·put
    try testing.expectEqualStrings("int", m.list.items[0].detail.?); // LSP 의 printf 가 남았다
    try testing.expectEqual(@as(u8, 3), m.list.items[0].kind);
    try testing.expectEqualStrings("pri", m.list.items[2].label);
    try testing.expectEqualStrings("~pri", m.list.items[2].sort);
    try testing.expectEqual(word_kind, m.list.items[2].kind);
    try testing.expect(m.list.items[2].raw == null);
    const o = try filterSort(a, m.list, "p");
    defer a.free(o);
    // 전부 `p` 로 시작 — 점수가 같으니 sortText: printf("printf") < puts("puts") < ~pri < ~put.
    try testing.expectEqualStrings("printf", m.list.items[o[0]].label);
    try testing.expectEqualStrings("puts", m.list.items[o[1]].label);
    try testing.expectEqualStrings("pri", m.list.items[o[2]].label);
}

test "CPL6 fuzzy — 부분열이면 후보, 정확한 접두사 > 무시 접두사 > 경계 > 연속 > 나머지, 없으면 탈락, 빈 접두사는 전부 (§8.2g-b)" {
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"printf\"},{\"label\":\"PRId16\"},{\"label\":\"fprintf\"},{\"label\":\"parse_tree_file\"},{\"label\":\"xyz\"},{\"label\":\"pRINT\"}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    const o = try filterSort(a, l, "pri");
    defer a.free(o);
    // printf(정확 접두사) → PRId16·pRINT(무시 접두사; sortText 순 PRId16 < pRINT) → fprintf(부분열, 연속) → parse_tree_file(부분열: p·r·i 흩어짐). xyz 탈락.
    try testing.expectEqual(@as(usize, 5), o.len);
    try testing.expectEqualStrings("printf", l.items[o[0]].label);
    try testing.expectEqualStrings("PRId16", l.items[o[1]].label);
    try testing.expectEqualStrings("pRINT", l.items[o[2]].label);
    try testing.expectEqualStrings("fprintf", l.items[o[3]].label);
    try testing.expectEqualStrings("parse_tree_file", l.items[o[4]].label);
    // `ptf` — parse_tree_file 은 경계 셋(p·_t·_f), fprintf 는 p·t·f 흩어짐 → 경계가 이긴다.
    const o2 = try filterSort(a, l, "ptf");
    defer a.free(o2);
    try testing.expectEqualStrings("parse_tree_file", l.items[o2[0]].label);
    try testing.expect(fuzzyScore("printf", "prtf") != null);
    // 같은 점수면 짧은 filter 가 앞 — 접두사가 차지하는 비율이 크다(적대적 1회차 A13).
    try testing.expect(fuzzyScore("a_b", "ab").? > fuzzyScore("a_b_long", "ab").?);
    try testing.expect(fuzzyScore("printf", "prx") == null);
    try testing.expectEqual(@as(u32, 0), fuzzyScore("anything", "").?);
    const all = try filterSort(a, l, "");
    defer a.free(all);
    try testing.expectEqual(@as(usize, 6), all.len);
}

test "CPL7 kind 글자와 resolve 합치기 (§8.2g-b)" {
    try testing.expectEqual(@as(u8, 'f'), kindGlyph(3));
    try testing.expectEqual(@as(u8, 'v'), kindGlyph(6));
    try testing.expectEqual(@as(u8, 't'), kindGlyph(22));
    try testing.expectEqual(@as(u8, 'k'), kindGlyph(14));
    try testing.expectEqual(@as(u8, 'w'), kindGlyph(word_kind));
    try testing.expectEqual(@as(u8, ' '), kindGlyph(0));
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"lazy\",\"kind\":3}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    var r = try parseJson(a, "{\"label\":\"lazy\",\"detail\":\"int lazy()\",\"additionalTextEdits\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"#include <l.h>\\n\"}],\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"lazy()\"}}");
    defer r.deinit();
    applyResolved(&l.items[0], r.value);
    try testing.expectEqualStrings("int lazy()", l.items[0].detail.?);
    try testing.expectEqualStrings("lazy()", l.items[0].insert);
    try testing.expectEqual(@as(usize, 1), l.items[0].additional.?.len);
    try testing.expect(l.items[0].raw != null);
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

test "CPL8 labelDetails — detail·description 둘·하나·없음을 읽고, filter·insert 는 그대로 (§8.2g-c)" {
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"HashMap\",\"labelDetails\":{\"detail\":\"(use std::collections::HashMap)\",\"description\":\"HashMap<K, V>\"},\"filterText\":\"HashMap\"},{\"label\":\" printf\",\"labelDetails\":{\"detail\":\"(const char *, ...)\"},\"detail\":\"int\",\"filterText\":\"printf\"},{\"label\":\"plain\",\"labelDetails\":\"bogus\"},{\"label\":\"none\"}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 4), l.items.len);
    try testing.expectEqualStrings("(use std::collections::HashMap)", l.items[0].label_detail.?);
    try testing.expectEqualStrings("HashMap<K, V>", l.items[0].description.?);
    try testing.expectEqualStrings("HashMap", l.items[0].filter); // filterText 는 그대로
    try testing.expectEqualStrings("HashMap", l.items[0].insert);
    try testing.expectEqualStrings("(const char *, ...)", l.items[1].label_detail.?);
    try testing.expect(l.items[1].description == null); // clangd — 반환형은 detail
    try testing.expectEqualStrings("int", l.items[1].detail.?);
    try testing.expect(l.items[2].label_detail == null and l.items[2].description == null); // 객체가 아니면 무시
    try testing.expect(l.items[3].label_detail == null and l.items[3].description == null);
}

test "CPL9 documentation — 문자열·MarkupContent.value·없음·그 밖(무시), resolve 로 합치기 (§8.2g-d)" {
    const a = testing.allocator;
    var p = try parseJson(a, "[{\"label\":\"a\",\"documentation\":\"plain doc\"},{\"label\":\"b\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"# H\\ntext\"}},{\"label\":\"c\"},{\"label\":\"d\",\"documentation\":7}]");
    defer p.deinit();
    var l = try parse(a, p.value);
    defer l.deinit(a);
    try testing.expectEqualStrings("plain doc", l.items[0].documentation.?);
    try testing.expectEqualStrings("# H\ntext", l.items[1].documentation.?);
    try testing.expect(l.items[2].documentation == null);
    try testing.expect(l.items[3].documentation == null);
    var r = try parseJson(a, "{\"label\":\"c\",\"documentation\":{\"kind\":\"plaintext\",\"value\":\"later\"}}");
    defer r.deinit();
    applyResolved(&l.items[2], r.value);
    try testing.expectEqualStrings("later", l.items[2].documentation.?);
    applyResolved(&l.items[0], r.value); // 이미 있던 것도 응답이 이긴다
    try testing.expectEqualStrings("later", l.items[0].documentation.?);
}
