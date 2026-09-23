//! 구조 기반 선택 확장의 **사슬 세우기**(docs/editor-surface-tooling.md §8.2q) — 순수 계산.
//!
//! 원천이 셋이다: 서버(`selectionRange`)와 tree-sitter(`Provider.enclosingRanges`)가 주는 **후보 범위**, 그리고 여기서 만드는
//! **낱말 단계**(하위 낱말 · 낱말 · 공백뿐인 줄 · 문서 전체). 그것들을 모아 **기준 범위를 품는 것만** 남기고, 안쪽부터 바깥으로
//! 「앞 단계를 품고 같지 않은」 것만 이어 사슬을 세운다. 사슬이 다른 줄로 넘어가는 자리에는 **줄 단계**(앞뒤 공백을 뺀 줄 ·
//! 줄 전체)를 끼운다. 사슬의 0 번은 언제나 기준 범위(지금 선택)다 — 축소가 거기서 멈춘다.
//!
//! 이 모듈은 **어느 원천을 쓸지**(서버가 있나, 트리가 있나)를 모른다 — 그것은 제품 배선(`editor_smart_select`)이 정한다.
const std = @import("std");
const selection = @import("selection.zig");
const line_index = @import("line_index.zig");
const LineIndex = line_index.LineIndex;

/// 문서 절대 byte `[start, end)`.
pub const Range = struct {
    start: u32,
    end: u32,

    pub fn contains(self: Range, other: Range) bool {
        return self.start <= other.start and other.end <= self.end;
    }
    pub fn eql(self: Range, other: Range) bool {
        return self.start == other.start and self.end == other.end;
    }
    /// 품고 **같지 않다** — 사슬의 한 걸음.
    pub fn strictlyContains(self: Range, other: Range) bool {
        return self.contains(other) and !self.eql(other);
    }
};

/// 한 사슬의 상한(§8.2q). 후보가 아무리 많아도 한 커서의 스택은 이만큼이다.
pub const max_steps: usize = 512;

/// 낱말 `[word_lo, word_hi)` 안에서 `at` 을 품는 **하위 낱말**(§8.2q) — `_` 경계와 소문자→대문자 전환에서 끊는다
/// (`foo_bar` 의 `bar`, `fooBar` 의 `Bar`). 끊을 자리가 없으면(낱말 전체가 한 조각) `null` — 낱말 단계와 같아서 낼 필요가 없다.
pub fn subwordAt(bytes: []const u8, word_lo: usize, word_hi: usize, at: usize) ?Range {
    if (word_hi <= word_lo or word_hi > bytes.len) return null;
    var pos = @min(@max(at, word_lo), word_hi - 1);
    // `_` 는 어느 조각에도 안 든다 — caret 이 `_` 위면 오른쪽 조각을, 없으면 왼쪽 조각을 본다.
    if (bytes[pos] == '_') {
        var r = pos;
        while (r < word_hi and bytes[r] == '_') r += 1;
        if (r < word_hi) {
            pos = r;
        } else {
            var l = pos;
            while (l > word_lo and bytes[l] == '_') l -= 1;
            if (bytes[l] == '_') return null; // 낱말 전체가 `_`
            pos = l;
        }
    }
    var lo = pos;
    while (lo > word_lo) : (lo -= 1) {
        if (isBreakBefore(bytes, lo)) break;
    }
    var hi = pos + 1;
    while (hi < word_hi) : (hi += 1) {
        if (isBreakBefore(bytes, hi)) break;
    }
    while (lo < hi and bytes[lo] == '_') lo += 1;
    while (hi > lo and bytes[hi - 1] == '_') hi -= 1;
    if (hi <= lo) return null;
    if (lo == word_lo and hi == word_hi) return null;
    return .{ .start = @intCast(lo), .end = @intCast(hi) };
}

/// `i` 앞에서 조각이 끊기는가 — `_` 의 앞뒤, 소문자 뒤의 대문자.
fn isBreakBefore(bytes: []const u8, i: usize) bool {
    const cur = bytes[i];
    const prev = bytes[i - 1];
    if (cur == '_' or prev == '_') return true;
    return isLower(prev) and isUpper(cur);
}
fn isLower(b: u8) bool {
    return b >= 'a' and b <= 'z';
}
fn isUpper(b: u8) bool {
    return b >= 'A' and b <= 'Z';
}
fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// 사슬을 세운다(§8.2q). `base` 는 지금 선택(빈 caret 이면 길이 0), `query` 는 물은 자리(낱말 단계의 기준), `provided` 는
/// 서버·tree-sitter 후보. `out[0]` 은 언제나 `base` 이고 뒤로 갈수록 넓다(각 단계가 앞 단계를 품고 같지 않다).
pub fn buildChain(
    allocator: std.mem.Allocator,
    content: []const u8,
    lines: LineIndex,
    base: Range,
    query: u32,
    provided: []const Range,
    out: *std.ArrayList(Range),
) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    const len: u32 = @intCast(content.len);
    const b: Range = .{ .start = @min(base.start, len), .end = @min(@max(base.end, base.start), len) };

    var cand: std.ArrayList(Range) = .empty;
    defer cand.deinit(allocator);
    for (provided) |r| {
        if (r.end < r.start or r.end > len) continue; // 문서 밖 · 뒤집힌 범위는 버린다
        try cand.append(allocator, r);
    }
    try appendWordSteps(allocator, content, lines, @min(query, len), &cand);

    // 기준을 품는 것만 — 안쪽부터(시작이 늦은 것 먼저, 같으면 끝이 이른 것 먼저).
    var keep: usize = 0;
    for (cand.items) |r| {
        if (!r.contains(b)) continue;
        cand.items[keep] = r;
        keep += 1;
    }
    cand.shrinkRetainingCapacity(keep);
    std.mem.sort(Range, cand.items, {}, innerFirst);

    var chain: std.ArrayList(Range) = .empty;
    defer chain.deinit(allocator);
    try chain.append(allocator, b);
    for (cand.items) |r| {
        if (chain.items.len >= max_steps) break;
        if (r.strictlyContains(chain.items[chain.items.len - 1])) try chain.append(allocator, r);
    }

    // 줄 단계 — 다른 줄로 넘어가는 자리에 「앞뒤 공백을 뺀 줄」·「줄 전체」를 한 번씩 끼운다.
    try out.append(allocator, chain.items[0]);
    for (chain.items[1..], 0..) |cur, i| {
        const prev = chain.items[i];
        if (out.items.len >= max_steps) break;
        const prev_first = lines.lineAt(prev.start);
        const prev_last = lines.lineAt(prev.end);
        if (prev_first != lines.lineAt(cur.start) or prev_last != lines.lineAt(cur.end)) {
            if (trimmedLines(content, lines, prev_first, prev_last)) |t| {
                if (t.strictlyContains(out.items[out.items.len - 1]) and cur.strictlyContains(t)) try out.append(allocator, t);
            }
            if (fullLines(lines, prev_first, prev_last)) |f| {
                if (f.strictlyContains(out.items[out.items.len - 1]) and cur.strictlyContains(f)) try out.append(allocator, f);
            }
        }
        if (out.items.len >= max_steps) break;
        try out.append(allocator, cur);
    }
}

fn innerFirst(_: void, a: Range, b: Range) bool {
    if (a.start != b.start) return a.start > b.start;
    return a.end < b.end;
}

/// 낱말 단계(§8.2q): 하위 낱말 · 낱말 · 공백뿐인 줄 · 문서 전체. 낱말은 `query` 가 낱말 글자 위일 때만.
fn appendWordSteps(allocator: std.mem.Allocator, content: []const u8, lines: LineIndex, query: u32, out: *std.ArrayList(Range)) error{OutOfMemory}!void {
    if (query < content.len and selection.isWordByte(content[query])) {
        const w = selection.wordRangeAt(content, query);
        if (w.hi > w.lo) {
            if (subwordAt(content, w.lo, w.hi, query)) |sw| try out.append(allocator, sw);
            try out.append(allocator, .{ .start = @intCast(w.lo), .end = @intCast(w.hi) });
        }
    }
    const row = lines.lineAt(query);
    if (lines.line(row)) |ln| {
        const text = content[ln.start..ln.contentEnd()];
        if (text.len > 0 and std.mem.indexOfNone(u8, text, " \t") == null) {
            try out.append(allocator, .{ .start = @intCast(ln.start), .end = @intCast(ln.contentEnd()) });
        }
    }
    try out.append(allocator, .{ .start = 0, .end = @intCast(content.len) });
}

/// `first..=last` 줄을 앞뒤 공백을 빼고 — 첫 줄의 첫 비공백부터 끝 줄의 마지막 비공백 다음까지. 어느 쪽이 공백뿐이면 `null`.
fn trimmedLines(content: []const u8, lines: LineIndex, first: usize, last: usize) ?Range {
    const a = lines.line(first) orelse return null;
    const z = lines.line(last) orelse return null;
    var lo = a.start;
    while (lo < a.contentEnd() and isSpace(content[lo])) lo += 1;
    if (lo == a.contentEnd()) return null;
    var hi = z.contentEnd();
    while (hi > z.start and isSpace(content[hi - 1])) hi -= 1;
    if (hi == z.start) return null;
    if (hi <= lo) return null;
    return .{ .start = @intCast(lo), .end = @intCast(hi) };
}

/// `first..=last` 줄 전체(줄바꿈 제외).
fn fullLines(lines: LineIndex, first: usize, last: usize) ?Range {
    const a = lines.line(first) orelse return null;
    const z = lines.line(last) orelse return null;
    if (z.contentEnd() < a.start) return null;
    return .{ .start = @intCast(a.start), .end = @intCast(z.contentEnd()) };
}

const testing = std.testing;

fn chainFor(a: std.mem.Allocator, content: []const u8, base: Range, query: u32, provided: []const Range, out: *std.ArrayList(Range)) !void {
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    try buildChain(a, content, lines, base, query, provided, out);
}

fn expectChain(content: []const u8, got: []const Range, want: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (got, want) |r, w| try testing.expectEqualStrings(w, content[r.start..r.end]);
}

test "SSEL1 하위 낱말 — `_` 경계와 소문자→대문자 전환에서 끊고, 한 조각뿐이면 없다 (§8.2q)" {
    const s = "fooBar_bazQux plain HTTPServer";
    // `fooBar_bazQux` 는 [0,13)
    try testing.expectEqualStrings("foo", sub(s, 0, 13, 1));
    try testing.expectEqualStrings("Bar", sub(s, 0, 13, 4));
    try testing.expectEqualStrings("baz", sub(s, 0, 13, 8));
    try testing.expectEqualStrings("Qux", sub(s, 0, 13, 11));
    // caret 이 `_` 위면 오른쪽 조각
    try testing.expectEqualStrings("baz", sub(s, 0, 13, 6));
    // 한 조각뿐인 낱말 — 낱말 단계와 같아 내지 않는다
    try testing.expect(subwordAt(s, 14, 19, 16) == null);
    // 대문자 연속(약어)은 소문자→대문자 전환이 아니다 — `HTTPServer` 는 끊을 자리가 `P|S`? 아니다(대문자→대문자). 한 조각.
    try testing.expect(subwordAt(s, 20, 30, 22) == null);
}

fn sub(s: []const u8, lo: usize, hi: usize, at: usize) []const u8 {
    const r = subwordAt(s, lo, hi, at) orelse return "";
    return s[r.start..r.end];
}

test "SSEL2 사슬 — 0 번은 기준, 안쪽부터 바깥, 기준을 안 품거나 같은 범위는 버린다 (§8.2q)" {
    const a = testing.allocator;
    const content = "f(fooBar + 1)";
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(a);
    // 후보: 식 `fooBar + 1` · 호출 `f(...)` · 기준을 안 품는 `1` · 같은 범위 중복 · 문서 밖
    const provided = [_]Range{
        .{ .start = 2, .end = 12 },
        .{ .start = 0, .end = 13 },
        .{ .start = 11, .end = 12 },
        .{ .start = 2, .end = 12 },
        .{ .start = 5, .end = 99 },
    };
    try chainFor(a, content, .{ .start = 3, .end = 3 }, 3, &provided, &out);
    // 기준(빈 caret) → 하위 낱말 foo → 낱말 fooBar → 식 → 호출. 호출 = 문서 전체라 문서 단계는 같은 범위로 빠진다.
    try testing.expectEqual(@as(u32, 3), out.items[0].start);
    try testing.expectEqual(@as(u32, 3), out.items[0].end);
    try expectChain(content, out.items[1..], &.{ "foo", "fooBar", "fooBar + 1", "f(fooBar + 1)" });
}

test "SSEL3 줄 단계 — 다른 줄로 넘어가는 자리에 앞뒤 공백을 뺀 줄과 줄 전체를 끼운다 (§8.2q)" {
    const a = testing.allocator;
    const content = "fn f() {\n    return x;   \n}\n";
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(a);
    const x_at: u32 = @intCast(std.mem.indexOfScalar(u8, content, 'x').?);
    const provided = [_]Range{
        .{ .start = 13, .end = 22 }, // `return x;`
        .{ .start = 7, .end = 27 }, // 블록 `{ … }`
    };
    try chainFor(a, content, .{ .start = x_at, .end = x_at }, x_at, &provided, &out);
    // x → return x; → 블록으로 넘어가며: 「공백 뺀 줄」은 `return x;` 와 같아 빠지고 「줄 전체」가 선다.
    // 블록 → 문서로 넘어가며: 「공백 뺀 줄」(함수 줄들 — 끝 개행 앞까지)이 서고 「줄 전체」는 그것과 같아 빠진다.
    try expectChain(content, out.items[1..], &.{ "x", "return x;", "    return x;   ", "{\n    return x;   \n}", "fn f() {\n    return x;   \n}", content });
}

test "SSEL4 낱말 단계만으로도 선다 — 원천이 없으면 낱말 → 문서, 공백뿐인 줄은 그 줄 (§8.2q)" {
    const a = testing.allocator;
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(a);
    const content = "alpha beta\n   \ngamma\n";
    try chainFor(a, content, .{ .start = 7, .end = 7 }, 7, &.{}, &out);
    // beta → (줄 넘어감: 줄 전체 `alpha beta`) → 문서
    try expectChain(content, out.items[1..], &.{ "beta", "alpha beta", content });
    // 공백뿐인 줄의 caret — 그 줄 → 문서
    try chainFor(a, content, .{ .start = 12, .end = 12 }, 12, &.{}, &out);
    try expectChain(content, out.items[1..], &.{ "   ", content });
    // 선택이 이미 있으면 그것보다 넓은 것만 — `alpha beta` 를 고른 채면 다음은 문서
    try chainFor(a, content, .{ .start = 0, .end = 10 }, 0, &.{}, &out);
    try expectChain(content, out.items, &.{ "alpha beta", content });
}

test "SSEL5 교차하는 후보는 안쪽 순서로 하나만 — 사슬은 언제나 포함 관계다 (§8.2q)" {
    const a = testing.allocator;
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(a);
    const content = "abcdefghij";
    // [2,8) 과 [4,10) 은 교차한다. 기준 [5,6) 을 둘 다 품는다 — 시작이 늦은 [4,10) 이 먼저 서고 [2,8) 은 그것을 못 품어 빠진다.
    const provided = [_]Range{ .{ .start = 2, .end = 8 }, .{ .start = 4, .end = 10 } };
    try chainFor(a, content, .{ .start = 5, .end = 6 }, 5, &provided, &out);
    for (out.items[1..], 0..) |r, i| try testing.expect(r.strictlyContains(out.items[i]));
    try testing.expectEqual(@as(u32, 4), out.items[1].start);
    try testing.expectEqual(@as(u32, 10), out.items[1].end);
}

test "SSEL20 사슬 상한 — 후보가 아무리 많아도 한 커서의 사슬은 max_steps 다 (§8.2q)" {
    const a = testing.allocator;
    // 서로 다른 중첩 범위를 상한보다 많이 준다(같은 범위만 주면 사슬이 중복을 거르므로 상한이 안 보인다).
    const n = max_steps + 100;
    const content = try a.alloc(u8, 2 * n + 2);
    defer a.free(content);
    @memset(content, ' ');
    var provided: std.ArrayList(Range) = .empty;
    defer provided.deinit(a);
    var i: u32 = 0;
    while (i < n) : (i += 1) try provided.append(a, .{ .start = @intCast(n - i), .end = @intCast(n + 2 + i) });
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(a);
    try chainFor(a, content, .{ .start = @intCast(n + 1), .end = @intCast(n + 1) }, @intCast(n + 1), provided.items, &out);
    try testing.expectEqual(max_steps, out.items.len);
}
