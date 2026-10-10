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
    return fuzzyMatch(filter, prefix, null, null);
}

/// `fuzzyScore` 와 **같은 탐욕 걸음**으로 맞춘 자리(`filter` 의 글자 첫 바이트 첨자, 오름차순 — 접두사 글자 하나에 하나)를 `out` 에 쓴다 —
/// 목록이 일치 글자를 강조한다(§8.2g-e). 걸음 규칙이 하나라 「무엇을 맞췄나」의 판정이 필터와 갈리지 않는다(순위는 `filterText` 로,
/// 강조는 호출자가 고른 글 — 제품은 보이는 label — 로 잰다). 안 맞거나 `out` 이 접두사 **바이트 수**보다 짧으면 `null`(글자 수 ≤ 바이트 수라 그만큼이면 늘 넉넉하다), 빈 접두사는 빈 조각.
pub fn matchPositions(filter: []const u8, prefix: []const u8, out: []u32) ?[]const u32 {
    if (prefix.len > out.len) return null; // 글자 수 ≤ 바이트 수 — 바이트 수만큼이면 늘 모자라지 않다
    var n: usize = 0;
    _ = fuzzyMatch(filter, prefix, out[0..prefix.len], &n) orelse return null;
    return out[0..n];
}

/// 걸음은 **글자 단위**다 — ASCII 는 대소문자를 무시하고, 여러 바이트 글자(한글 등)는 바이트 전부가 같아야 맞는다. 예전에는 바이트끼리
/// 맞춰 `나`(EB 82 98)가 `난하`(EB 82 9C · ED 95 98)의 바이트 셋에 흩어져 맞았다 — 그 오탐이 강조(§8.2g-e)로 화면에 드러났다(적대적 1회차).
fn fuzzyMatch(filter: []const u8, prefix: []const u8, positions: ?[]u32, count: ?*usize) ?u32 {
    if (prefix.len == 0) return 0;
    // 접두사 둘(대소문자까지·무시)은 걸음 없이 정한다 — 자리는 접두사 글자들의 시작(온전한 UTF-8 이면 걸음과 같은 자리).
    const exact_head: ?u32 = if (std.mem.startsWith(u8, filter, prefix)) 1_000_000 else if (startsWithIgnoreCase(filter, prefix)) 900_000 else null;
    if (exact_head) |h| {
        // 접두사면 걸음 없이 자리 = 접두사 글자들의 시작 — 걸음에 맡기면 잘린 접두사(`\xEB`)가 filter 의 온전한 글자(`나`)와 안 맞아 null 이
        // 됐다(예전 바이트 걸음은 1_000_000 — 적대적 6회차).
        var n: usize = 0;
        var i: usize = 0;
        while (i < prefix.len) : (n += 1) {
            if (positions) |pos| pos[n] = @intCast(@min(i, std.math.maxInt(u32)));
            i += utf8Len(prefix, i);
        }
        if (count) |c| c.* = n;
        return h;
    }
    // 부분열 — 앞에서부터 탐욕으로 맞추되 경계·연속 가산.
    var score: u32 = 0;
    var fi: usize = 0;
    var prev_end: ?usize = null; // 앞 일치 글자 **다음** 바이트 — 연속은 글자 단위로 잰다
    var pi: usize = 0;
    var k: usize = 0;
    while (pi < prefix.len) : (k += 1) {
        const plen = utf8Len(prefix, pi);
        const pch = prefix[pi .. pi + plen];
        pi += plen;
        var found: ?usize = null;
        while (fi < filter.len) {
            const flen = utf8Len(filter, fi);
            const same = if (plen == 1 and flen == 1) std.ascii.toLower(filter[fi]) == std.ascii.toLower(pch[0]) else std.mem.eql(u8, filter[fi .. fi + flen], pch);
            fi += flen;
            if (same) {
                found = fi - flen;
                break;
            }
        }
        const at = found orelse return null;
        if (positions) |pos| pos[k] = @intCast(@min(at, std.math.maxInt(u32)));
        score += 10;
        if (filter[at] == pch[0]) score += 2; // 대소문자까지
        if (at == 0 or filter[at - 1] == '_' or (std.ascii.isUpper(filter[at]) and std.ascii.isLower(filter[at - 1]))) score += 30; // 낱말 경계
        if (prev_end) |pe| if (pe == at) {
            score += 20; // 연속 — 여러 바이트 글자도(예전 `pm + 1 == at` 은 한글에서 늘 거짓이었다, 적대적 4회차)
        };
        prev_end = at + utf8Len(filter, at);
    }
    if (count) |c| c.* = k;
    // 짧은 filter 가 같은 점수면 앞 — 접두사가 차지하는 비율이 크다. 포화 — 아주 긴 접두사(수만 글자)에서 넘치지 않는다.
    return score *| 1000 +| @as(u32, @intCast(1000 -| @min(filter.len, 999)));
}

/// `bytes[i]` 에서 시작하는 글자의 바이트 수 — 깨진 바이트·잘린 꼬리는 1(그 바이트 하나가 한 글자).
fn utf8Len(bytes: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return 1;
    if (i + n > bytes.len) return 1;
    _ = std.unicode.utf8Decode(bytes[i .. i + n]) catch return 1;
    return n;
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

/// kind 글자(§8.2g-b) — 플랫폼↔컴포넌트 사이 값이다. 화면에는 글자가 아니라 이 글자가 고르는 아이콘·색이 선다(`suggest_box.kindStyle`, §8.2g-e).
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
    return mergeMany(allocator, additional, &.{.{ .start = @min(start, caret), .end = caret }}, insert);
}

/// `mergeMany` 의 결과에서 **자리마다 넣은 글의 끝**(편집 후 offset, `sites` 순서). 정렬된 목록을 차례로 걸으며 앞 항목들의 길이 차를 쌓고,
/// 자리 자신의 항목(입력 순서의 텍스트 — `texts[additional_len + k]`)에 닿으면 그 끝을 잰다. 같은 시작의 항목은 목록 순서대로 적용되므로
/// (`delta.apply`) 「자리 시작보다 앞」으로 세면 같은 시작의 import 를 빠뜨렸다(적대적 1회차).
/// 항목은 텍스트 포인터 **와** 범위로 알아본다 — 빈 insert 면 포인터가 같을 수 있어서다(자리끼리는 범위가 겹치지 않는다).
/// 자리를 `mergeMany` 와 같은 키로 정렬해 두 포인터로 걷는다 — 커서가 수천이어도 n log n(자리마다 목록 전체를 훑으면 제곱이었다 — 적대적 5회차).
pub fn siteEnds(allocator: std.mem.Allocator, changes: text_edits.Changes, additional_len: usize, sites: []const Span) error{OutOfMemory}![]usize {
    const out = try allocator.alloc(usize, sites.len);
    errdefer allocator.free(out);
    @memset(out, 0);
    const order = try allocator.alloc(usize, sites.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, sites, struct {
        fn less(ss: []const Span, a: usize, b: usize) bool {
            const sa = @min(ss[a].start, ss[a].end);
            const sb = @min(ss[b].start, ss[b].end);
            return sa < sb or (sa == sb and ss[a].end < ss[b].end);
        }
    }.less);
    var j: usize = 0;
    var shift: i64 = 0;
    for (changes.items) |c| {
        if (j < order.len) {
            const k = order[j];
            const site = sites[k];
            if (c.text.ptr == changes.texts[additional_len + k].ptr and c.start == @min(site.start, site.end) and c.end == site.end) {
                out[k] = @intCast(@as(i64, @intCast(c.start)) + shift + @as(i64, @intCast(c.text.len)));
                j += 1;
            }
        }
        shift += @as(i64, @intCast(c.text.len)) - @as(i64, @intCast(c.end - c.start));
    }
    return out;
}

/// 주 편집 한 자리 — `[start, end)` 를 `insert` 로.
pub const Span = struct { start: usize, end: usize };

/// **멀티 커서 완성의 자리**(§8.2g-f) — VS Code 의 규칙(`snippetSession.ts` `createEditsAndSnippetsFromSelections`, MIT — 동작만): primary 가
/// 덮어쓰는 앞 글 `content[primary.start..primary.end]`(치던 접두사, 또는 서버 textEdit 의 머리)와 **같은 글**이 다른 selection 앞에 있으면 그만큼
/// 늘려 덮어쓰고, 다르면 그 selection 자리(선택이면 그 범위)에 **넣기만** 한다. 결과는 `others` 와 같은 순서이고, 둘 중 하나와 겹쳐 놓을 수 없는
/// 자리는 `null`(primary 가 덮어쓰는 범위 안의 caret — 그 caret 은 primary 편집에 흡수된다). 겹침은 먼저 늘리지 않은 자리로 물러서 본다.
pub fn multiSites(allocator: std.mem.Allocator, content: []const u8, primary: Span, others: []const Span) error{OutOfMemory}![]?Span {
    const out = try allocator.alloc(?Span, others.len);
    errdefer allocator.free(out);
    const before = content[@min(primary.start, content.len)..@min(primary.end, content.len)];
    const l = before.len;
    for (others, out) |o, *slot| {
        const plain: Span = .{ .start = @min(o.start, content.len), .end = @min(o.end, content.len) };
        const grown: ?Span = if (l > 0 and plain.start >= l and std.mem.eql(u8, content[plain.start - l .. plain.start], before)) .{ .start = plain.start - l, .end = plain.end } else null;
        slot.* = if (grown) |g| (if (!overlaps(g, primary)) g else if (!overlaps(plain, primary)) plain else null) else (if (!overlaps(plain, primary)) plain else null);
    }
    // 다른 자리끼리 — 문서 순서로 훑어 앞 자리와 겹치면 늘리지 않은 자리로, 그래도 겹치면 뺀다.
    const order = try allocator.alloc(usize, others.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, others, struct {
        fn less(os: []const Span, a: usize, b: usize) bool {
            return os[a].start < os[b].start;
        }
    }.less);
    var prev_end: ?usize = null;
    for (order) |i| {
        const site = out[i] orelse continue;
        if (prev_end) |pe| if (site.start < pe) {
            // 늘린 자리가 primary 와 안 겹쳤으면 그 부분 구간인 늘리지 않은 자리도 안 겹친다 — 앞 자리와만 다시 잰다.
            const plain: Span = .{ .start = @min(others[i].start, content.len), .end = @min(others[i].end, content.len) };
            out[i] = if (plain.start >= pe) plain else null;
        };
        if (out[i]) |kept| prev_end = kept.end;
    }
    return out;
}

/// `mergeMany` 와 **같은 판정**으로 두 변경이 함께 갈 수 있나 — (start, end) 순으로 놓았을 때 뒤의 시작이 앞의 끝보다 앞이면 겹침. 같은 자리의
/// 길이 0 둘은 함께 간다(입력 순서대로 넣는다). 확정이 Overlap 을 만나면 additional 과 이것이 참인 커서만 놓는다(§8.2g-f).
pub fn conflicts(a: Span, b: Span) bool {
    const a_first = a.start < b.start or (a.start == b.start and a.end <= b.end);
    const first = if (a_first) a else b;
    const second = if (a_first) b else a;
    return second.start < first.end;
}

/// 두 자리가 겹치나 — 맞닿는 것(`[0,3)`·`[3,6)`)은 겹침이 아니다(`mergeMany` 의 판정과 같다). 길이 0 인 둘이 같은 자리면 겹친다(같은 곳에 두 번
/// 넣는다 — `mergeMany` 는 그것을 못 가르므로 여기서 막는다; 합쳐진 커서라면 애초에 같은 자리에 둘이 없다).
fn overlaps(a: Span, b: Span) bool {
    if (a.start == a.end and b.start == b.end) return a.start == b.start;
    return a.start < b.end and b.start < a.end;
}

/// `additional` + 주 편집 여럿(`sites` 마다 `insert`) → 하나의 정렬된 목록(§8.2g-f — undo 하나). 겹치면 `Overlap`. 텍스트는 복사.
pub fn mergeMany(allocator: std.mem.Allocator, additional: []const delta_mod.Change, sites: []const Span, insert: []const u8) ChangesError!text_edits.Changes {
    const n = additional.len + sites.len;
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
    for (sites, additional.len..) |site, i| {
        texts[owned] = try allocator.dupe(u8, insert);
        owned += 1;
        items[i] = .{ .start = @min(site.start, site.end), .end = site.end, .text = texts[i] };
    }
    // (start, end) 순 — 같은 시작이면 길이 0(넣기)이 앞이다. 그래야 맞닿은 `[k,k)`·`[k,m)` 이 겹침으로 안 잡힌다(`multiSites` 의 `overlaps` 와 같은
    // 판정 — 적대적 1회차: start 만 보면 낱말 머리의 커서와 primary 가 Overlap 이 되어 다른 커서가 전부 사라졌다). 안정 정렬이라 나머지는 입력 순서다.
    std.mem.sort(delta_mod.Change, items, {}, struct {
        fn f(_: void, a: delta_mod.Change, b: delta_mod.Change) bool {
            return a.start < b.start or (a.start == b.start and a.end < b.end);
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

test "CPL11 멀티 커서 자리 — primary 가 덮는 앞 글과 같으면 늘려 덮고 다르면 넣기만, primary 범위 안 caret 은 빠지고, 겹치면 물러선다; 여러 자리를 한 목록으로 (§8.2g-f)" {
    const a = testing.allocator;
    //                p0 r1 i2 _3 a4 _5 p6 r7 i8 _9 b10 _11 x12 p13 r14 i15 _16 c17 _18 q19 q20
    const content = "pri a pri b xpri c qq";
    const primary: Span = .{ .start = 6, .end = 9 }; // 둘째 `pri` 뒤 caret, 접두사 `pri`
    const others = [_]Span{
        .{ .start = 3, .end = 3 }, // 첫 `pri` 뒤 — 같은 글 → [0, 3)
        .{ .start = 16, .end = 16 }, // `xpri` 뒤 — 앞 세 바이트가 `pri` → [13, 16)(VS Code 도 글이 같으면 늘린다)
        .{ .start = 21, .end = 21 }, // `qq` 뒤 — 다른 글 → 넣기만
        .{ .start = 8, .end = 8 }, // primary 가 덮는 범위 안 — 뺀다
        .{ .start = 19, .end = 21 }, // 선택 범위(`qq`) — 앞이 다르면 그 범위를 덮는다
    };
    const sites = try multiSites(a, content, primary, &others);
    defer a.free(sites);
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 3 }), sites[0]);
    try testing.expectEqual(@as(?Span, .{ .start = 13, .end = 16 }), sites[1]);
    try testing.expectEqual(@as(?Span, .{ .start = 21, .end = 21 }), sites[2]);
    try testing.expectEqual(@as(?Span, null), sites[3]);
    try testing.expectEqual(@as(?Span, .{ .start = 19, .end = 21 }), sites[4]); // `[19,21)` 와 `[21,21)` 은 맞닿을 뿐이다
    // primary 시작에 맞닿은 caret(`[6,6)` — 앞 글이 `pri` 가 아니라 늘리지 않는다)은 겹침이 아니다 — 남는다(적대적 6회차: `<` 를 `<=` 로 바꿔도 초록이었다).
    const touch = try multiSites(a, content, primary, &.{.{ .start = 6, .end = 6 }});
    defer a.free(touch);
    try testing.expectEqual(@as(?Span, .{ .start = 6, .end = 6 }), touch[0]);
    // 다른 자리끼리 겹치면 늘리지 않은 자리로 물러선다 — caret 2(늘릴 수 없다)와 caret 3(늘리면 [0,3) 이 2 를 덮는다).
    const tight = try multiSites(a, content, primary, &.{ .{ .start = 2, .end = 2 }, .{ .start = 3, .end = 3 } });
    defer a.free(tight);
    try testing.expectEqual(@as(?Span, .{ .start = 2, .end = 2 }), tight[0]);
    try testing.expectEqual(@as(?Span, .{ .start = 3, .end = 3 }), tight[1]);
    // 같은 자리 둘(길이 0)은 겹친다 — 같은 곳에 두 번 넣지 않는다.
    const same = try multiSites(a, content, .{ .start = 9, .end = 9 }, &.{.{ .start = 9, .end = 9 }});
    defer a.free(same);
    try testing.expectEqual(@as(?Span, null), same[0]);
    // 빈 접두사(primary 가 덮는 글 없음)면 모두 넣기만.
    const empty = try multiSites(a, content, .{ .start = 9, .end = 9 }, &.{.{ .start = 3, .end = 3 }});
    defer a.free(empty);
    try testing.expectEqual(@as(?Span, .{ .start = 3, .end = 3 }), empty[0]);
    // 한 목록으로 — additional 하나 + 자리 셋, 문서 순서, 텍스트는 각자 복사.
    const additional = [_]delta_mod.Change{.{ .start = 11, .end = 11, .text = "X" }};
    var c = try mergeMany(a, &additional, &.{ .{ .start = 6, .end = 9 }, .{ .start = 0, .end = 3 }, .{ .start = 13, .end = 16 } }, "printf");
    defer c.deinit(a);
    try testing.expectEqual(@as(usize, 4), c.items.len);
    try testing.expectEqual(@as(usize, 0), c.items[0].start);
    try testing.expectEqual(@as(usize, 6), c.items[1].start);
    try testing.expectEqualStrings("X", c.items[2].text);
    try testing.expectEqual(@as(usize, 13), c.items[3].start);
    try testing.expectEqualStrings("printf", c.items[3].text);
    try testing.expect(c.items[1].text.ptr != c.items[3].text.ptr); // 각자 복사 — 해제가 한 번씩
    try testing.expect(c.delta().isWellFormed());
    try testing.expectError(error.Overlap, mergeMany(a, &.{}, &.{ .{ .start = 0, .end = 3 }, .{ .start = 2, .end = 4 } }, "p"));
}

test "CPL12 멀티 커서 caret 끝·정렬·겹침 판정 — 같은 시작의 import 도 세고, 맞닿은 넣기는 앞에 서며, conflicts 는 mergeMany 와 같다 (§8.2g-f)" {
    const a = testing.allocator;
    // 같은 시작의 import(`[16,16)`)가 자리(`[16,19)`) 앞에 적용된다 — 「자리 시작보다 앞」으로 세면 빠뜨려 caret 이 import 글 안에 섰다.
    const imp = "import X\n";
    const additional = [_]delta_mod.Change{.{ .start = 16, .end = 16, .text = imp }};
    const sites = [_]Span{ .{ .start = 30, .end = 33 }, .{ .start = 16, .end = 19 } };
    var c = try mergeMany(a, &additional, &sites, "world");
    defer c.deinit(a);
    try testing.expectEqualStrings(imp, c.items[0].text); // import 가 같은 시작의 자리보다 앞
    const ends = try siteEnds(a, c, additional.len, &sites);
    defer a.free(ends);
    // primary: 30 + (import 9) + (16..19 → world: +2) + 5. secondary: 16 + 9 + 5.
    try testing.expectEqual(@as(usize, 30 + imp.len + 2 + 5), ends[0]);
    try testing.expectEqual(@as(usize, 16 + imp.len + 5), ends[1]);
    // 맞닿은 `[3,3)`(넣기)와 `[3,6)` 은 겹침이 아니다 — 넣기가 앞에 선다(start 만 보던 정렬은 Overlap 이라 다른 커서가 전부 사라졌다).
    const touch = [_]Span{ .{ .start = 3, .end = 6 }, .{ .start = 3, .end = 3 } };
    var t = try mergeMany(a, &.{}, &touch, "ab");
    defer t.deinit(a);
    try testing.expectEqual(@as(usize, 3), t.items[0].end); // 길이 0 이 먼저
    const te = try siteEnds(a, t, 0, &touch);
    defer a.free(te);
    try testing.expectEqual(@as(usize, 3 + 2 + 2), te[0]); // `[3,6)` 은 앞 넣기(+2) 뒤
    try testing.expectEqual(@as(usize, 3 + 2), te[1]);
    // 빈 insert — 포인터가 같아도 범위로 가른다.
    var e = try mergeMany(a, &.{}, &.{ .{ .start = 0, .end = 2 }, .{ .start = 5, .end = 7 } }, "");
    defer e.deinit(a);
    const ee = try siteEnds(a, e, 0, &.{ .{ .start = 0, .end = 2 }, .{ .start = 5, .end = 7 } });
    defer a.free(ee);
    try testing.expectEqual([2]usize{ 0, 3 }, ee[0..2].*);
    // conflicts — mergeMany 와 같은 판정.
    try testing.expect(!conflicts(.{ .start = 3, .end = 3 }, .{ .start = 3, .end = 6 }));
    try testing.expect(!conflicts(.{ .start = 3, .end = 6 }, .{ .start = 3, .end = 3 }));
    try testing.expect(!conflicts(.{ .start = 0, .end = 3 }, .{ .start = 3, .end = 6 }));
    try testing.expect(conflicts(.{ .start = 0, .end = 4 }, .{ .start = 3, .end = 6 }));
    try testing.expect(conflicts(.{ .start = 3, .end = 6 }, .{ .start = 4, .end = 4 })); // 범위 안의 넣기
    try testing.expect(!conflicts(.{ .start = 3, .end = 3 }, .{ .start = 3, .end = 3 })); // 같은 자리의 넣기 둘은 함께 간다(입력 순서)
    for ([_][2]Span{ .{ .{ .start = 0, .end = 4 }, .{ .start = 3, .end = 6 } }, .{ .{ .start = 3, .end = 3 }, .{ .start = 3, .end = 6 } }, .{ .{ .start = 5, .end = 5 }, .{ .start = 3, .end = 6 } } }) |pair| {
        const merged = mergeMany(a, &.{.{ .start = pair[0].start, .end = pair[0].end, .text = "x" }}, &.{pair[1]}, "y");
        if (merged) |m| {
            var mm = m;
            mm.deinit(a);
            try testing.expect(!conflicts(pair[0], pair[1]));
        } else |_| try testing.expect(conflicts(pair[0], pair[1]));
    }
}

test "CPL10 일치 자리 — 점수와 같은 탐욕 걸음: 접두사는 0..n, 부분열은 첫 등장, 대소문자 무시, 안 맞으면 null, 빈 접두사는 빈 조각 (§8.2g-e)" {
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, matchPositions("printf", "pri", &buf).?); // 정확 접두사
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, matchPositions("PRId16", "pri", &buf).?); // 무시 접두사
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, matchPositions("printf", "pit", &buf).?); // 부분열 — 탐욕(첫 등장): p·i·t
    try testing.expectEqualSlices(u32, &.{ 0, 6, 11 }, matchPositions("parse_tree_file", "ptf", &buf).?); // 경계 가산이 있어도 자리는 탐욕 그대로(점수 순서와 무관)
    try testing.expect(matchPositions("printf", "prx", &buf) == null);
    try testing.expectEqual(@as(usize, 0), matchPositions("printf", "", &buf).?.len);
    try testing.expect(matchPositions("printf", "printf_too_long", buf[0..4]) == null); // out 이 짧으면 자리를 못 싣는다
    // 점수와 갈리지 않는다 — 자리가 있으면 점수도 있고 그 반대도.
    for ([_][]const u8{ "pri", "pit", "ptf", "prx", "PRI", "f" }) |pre| {
        try testing.expectEqual(fuzzyScore("printf", pre) != null, matchPositions("printf", pre, &buf) != null);
    }
    // 여러 바이트 글자는 **글자 단위**로 맞춘다 — `나` 는 `난하` 에 없다(바이트로 맞추면 EB·82 가 `난` 에서, 98 이 `하` 에서 맞았다, 적대적 1회차).
    try testing.expect(matchPositions("난하", "나", &buf) == null);
    try testing.expect(fuzzyScore("난하", "나") == null);
    try testing.expectEqualSlices(u32, &.{3}, matchPositions("가나다", "나", &buf).?); // 자리는 글자 첫 바이트, 접두사 글자 하나에 하나
    try testing.expectEqualSlices(u32, &.{ 0, 3, 6 }, matchPositions("pr_라벨", "p라벨", &buf).?);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, matchPositions("pr_라벨", "pr_", &buf).?); // ASCII 는 그대로 바이트=글자
    // 연속 가산도 글자 단위 — `가나` 가 붙은 쪽이 흩어진 쪽을 앞선다(바이트로 재면 둘이 같아 짧은 쪽이 이겼다, 적대적 4회차).
    try testing.expect(fuzzyScore("x가나zz", "가나").? > fuzzyScore("x가y나", "가나").?);
    // 깨진·잘린 바이트는 한 바이트가 한 글자 — 끝에서 잘린 꼬리를 넘어 읽지 않는다(패닉 없음).
    try testing.expect(fuzzyScore("a\xEB", "a") != null);
    try testing.expectEqualSlices(u32, &.{0}, matchPositions("\xEB\x82", "\xEB", &buf).?);
    try testing.expect(matchPositions("a\xEB", "\xEB\x82", &buf) == null);
    // 잘린 접두사도 접두사다 — 점수 1_000_000, 자리는 접두사 글자 시작(적대적 6회차: 걸음에 맡기면 null).
    try testing.expectEqual(@as(?u32, 1_000_000), fuzzyScore("\xEB\x82\x98", "\xEB"));
    try testing.expectEqualSlices(u32, &.{0}, matchPositions("\xEB\x82\x98", "\xEB", &buf).?);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, matchPositions("가나다", "가나", &buf).?); // 온전한 접두사는 걸음과 같은 자리
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
    var nv = try parseJson(a, "[{\"label\":\"e\",\"documentation\":{\"kind\":\"markdown\"}}]"); // value 없는 MarkupContent — kind 를 글로 읽지 않는다(적대적 7회차 E3)
    defer nv.deinit();
    var ln = try parse(a, nv.value);
    defer ln.deinit(a);
    try testing.expect(ln.items[0].documentation == null);
    var r = try parseJson(a, "{\"label\":\"c\",\"documentation\":{\"kind\":\"plaintext\",\"value\":\"later\"}}");
    defer r.deinit();
    applyResolved(&l.items[2], r.value);
    try testing.expectEqualStrings("later", l.items[2].documentation.?);
    applyResolved(&l.items[0], r.value); // 이미 있던 것도 응답이 이긴다
    try testing.expectEqualStrings("later", l.items[0].documentation.?);
}
