//! 글자 안 문맥 — caret·괄호가 **문자열·주석 안인가**(계획 editor-typing-rules TR4 · 문서 모델 §3.7·§3.9a).
//!
//! 구문 트리의 하이라이트 capture(`string…`·`comment…`·`embedded`)를 **겹치지 않는 구간 목록**으로 편다 — 가장 안쪽 capture 가 이긴다
//! (템플릿 `${…}`·f-string `{…}`·셸 `$(…)` 의 `embedded` 는 문자열 안이어도 다시 코드다). 소비처(자동 닫기·Enter·닫는 괄호의 짝 찾기)는
//! 그 목록만 본다. 트리가 없거나 낡았으면 목록이 없고(`null`) 소비처는 줄 스캐너로 간다 — 트리는 보정이지 1급 경로가 아니다(계획 「설계 구멍 —
//! 트리 신선도」).
//!
//! **L2 다 — 트리를 모른다.** capture 이름과 byte 범위만 받는다(그 이름은 grammar 가 소유하는 하이라이트 관례다 — 색과 같은 출처).
const std = @import("std");

pub const Kind = enum { string, comment };

/// 문자열·주석 한 조각 — 문서 절대 byte `[start, end)`. 목록은 위치 오름차순이고 겹치지 않는다.
pub const Span = struct { start: usize, end: usize, kind: Kind };

/// caret 자리의 문맥. `unknown` 은 트리가 답하지 못했다(소비처는 문맥 없이 — 종전대로).
pub const Literal = enum { unknown, code, string, comment };

/// 하이라이트 capture 하나(트리 쿼리의 결과 그대로).
pub const Capture = struct { start: usize, end: usize, name: []const u8 };

const Class = enum { code, string, comment };

fn classOf(name: []const u8) ?Class {
    if (std.mem.startsWith(u8, name, "string")) return .string;
    if (std.mem.startsWith(u8, name, "comment")) return .comment;
    if (std.mem.eql(u8, name, "embedded")) return .code;
    return null;
}

const Item = struct { start: usize, end: usize, class: Class };

fn itemLess(_: void, a: Item, b: Item) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // 같은 자리면 바깥(긴 것)이 먼저 — 안쪽이 뒤에 쌓여 이긴다
}

/// capture 들을 겹치지 않는 문자열·주석 구간으로 편다(`out` 을 비우고 채운다). capture 는 트리 노드라 서로 품거나 떨어져 있다 — 엇갈리면
/// 바깥 것의 끝에서 자른다.
pub fn flatten(allocator: std.mem.Allocator, captures: []const Capture, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(allocator);
    for (captures) |c| {
        const class = classOf(c.name) orelse continue;
        if (c.end <= c.start) continue;
        try items.append(allocator, .{ .start = c.start, .end = c.end, .class = class });
    }
    std.mem.sort(Item, items.items, {}, itemLess);
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(allocator);
    var cur: usize = 0;
    for (items.items) |raw| {
        var it = raw;
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].end <= it.start) {
            const top = stack.pop().?;
            try emit(allocator, out, cur, top.end, top.class);
            cur = top.end;
        }
        if (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            try emit(allocator, out, cur, it.start, top.class);
            it.end = @min(it.end, top.end);
        }
        cur = @max(cur, it.start);
        try stack.append(allocator, it);
    }
    while (stack.pop()) |top| {
        try emit(allocator, out, cur, top.end, top.class);
        cur = @max(cur, top.end);
    }
}

fn emit(allocator: std.mem.Allocator, out: *std.ArrayList(Span), start: usize, end: usize, class: Class) error{OutOfMemory}!void {
    if (end <= start) return;
    const kind: Kind = switch (class) {
        .code => return,
        .string => .string,
        .comment => .comment,
    };
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (last.kind == kind and last.end == start) {
            last.end = end;
            return;
        }
    }
    try out.append(allocator, .{ .start = start, .end = end, .kind = kind });
}

/// `pos` 앞에서 시작한 조각의 수 — 마지막 것의 인덱스 + 1(없으면 0).
pub fn countBefore(spans: []const Span, pos: usize) usize {
    var lo: usize = 0;
    var hi = spans.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (spans[mid].start < pos) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// caret `pos` 의 문맥. 조각이 caret 을 **안쪽에** 품어야 한다 — `|"ab"` 와 `"ab"|` 는 밖이다. 줄 주석은 줄 끝까지라 그 끝(`// a|`)도
/// 안이다: 끝이 줄 끝(또는 문서 끝)이고 닫는 표식(`*/`·`-->`)으로 끝나지 않으면.
pub fn at(spans: []const Span, content: []const u8, pos: usize) Literal {
    const n = countBefore(spans, pos);
    if (n == 0) return .code;
    const s = spans[n - 1];
    if (pos < s.end) return switch (s.kind) {
        .string => .string,
        .comment => .comment,
    };
    if (pos == s.end and s.kind == .comment and openEnded(content, s)) return .comment;
    return .code;
}

fn openEnded(content: []const u8, s: Span) bool {
    if (s.end < content.len and content[s.end] != '\n' and content[s.end] != '\r') return false;
    const text = content[s.start..@min(s.end, content.len)];
    // 개행까지 품은 조각(Rust `///` 문서 주석 — 외부 스캐너가 줄바꿈을 먹는다)은 그 개행에서 끝났다 — 다음 줄은 밖이다.
    if (std.mem.endsWith(u8, text, "\n")) return false;
    return !std.mem.endsWith(u8, text, "*/") and !std.mem.endsWith(u8, text, "-->");
}

/// byte `i` 가 조각 안인가(`start <= i < end`) — 괄호 하나를 셀지 가른다.
pub fn covers(spans: []const Span, i: usize) bool {
    const n = countBefore(spans, i + 1);
    return n > 0 and i < spans[n - 1].end;
}

/// `bytes`(문서 byte `base` 부터)를 `out` 에 베끼되 조각 안 byte 는 공백으로 — 줄 규칙이 코드만 읽게. `out` 은 `bytes` 만큼 길어야 한다.
pub fn blank(spans: []const Span, base: usize, bytes: []const u8, out: []u8) []u8 {
    const dst = out[0..bytes.len];
    @memcpy(dst, bytes);
    var k = countBefore(spans, base + 1) -| 1;
    while (k < spans.len) : (k += 1) {
        const s = spans[k];
        if (s.start >= base + bytes.len) break;
        if (s.end <= base) continue;
        const a = @max(s.start, base) - base;
        const b = @min(s.end, base + bytes.len) - base;
        @memset(dst[a..b], ' ');
    }
    return dst;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn flat(captures: []const Capture) !std.ArrayList(Span) {
    var out: std.ArrayList(Span) = .empty;
    try flatten(testing.allocator, captures, &out);
    return out;
}

test "LIT1: capture 를 겹치지 않는 조각으로 편다 — 가장 안쪽이 이긴다" {
    // `x = `a${f("b")}c` // n` — 템플릿(0..) 안 `${…}` 는 코드, 그 안 `"b"` 는 다시 문자열. 주석과 그 문서 주석(같은 범위)은 하나.
    //       0123456789012345678901
    const caps = [_]Capture{
        .{ .start = 4, .end = 18, .name = "string" }, // `a${f("b")}c`
        .{ .start = 6, .end = 16, .name = "embedded" }, // ${f("b")}
        .{ .start = 10, .end = 13, .name = "string" }, // "b"
        .{ .start = 11, .end = 12, .name = "string.escape" }, // 안쪽의 안쪽 — 같은 종류라 이어 붙는다
        .{ .start = 19, .end = 23, .name = "comment" },
        .{ .start = 19, .end = 23, .name = "comment.documentation" },
        .{ .start = 2, .end = 3, .name = "operator" }, // 관심 없는 capture 는 버린다
        .{ .start = 30, .end = 30, .name = "string" }, // 폭 0 은 버린다
    };
    var out = try flat(&caps);
    defer out.deinit(testing.allocator);
    try testing.expectEqualSlices(Span, &.{
        .{ .start = 4, .end = 6, .kind = .string },
        .{ .start = 10, .end = 13, .kind = .string },
        .{ .start = 16, .end = 18, .kind = .string },
        .{ .start = 19, .end = 23, .kind = .comment },
    }, out.items);
}

test "LIT2: 들어온 순서와 무관하다 · 맞닿은 같은 종류는 하나로" {
    const caps = [_]Capture{
        .{ .start = 5, .end = 9, .name = "comment" },
        .{ .start = 0, .end = 5, .name = "comment" },
        .{ .start = 12, .end = 14, .name = "string.special" },
        .{ .start = 9, .end = 12, .name = "string" },
    };
    var out = try flat(&caps);
    defer out.deinit(testing.allocator);
    try testing.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 9, .kind = .comment },
        .{ .start = 9, .end = 14, .kind = .string },
    }, out.items);
}

test "LIT3: caret 문맥 — 조각이 caret 을 안쪽에 품어야 하고, 줄 주석은 그 끝도 안이다" {
    //            0         1         2
    //            0123456789012345678901234567
    const src = "a(\"bc\") /* d */ e // fg\nh";
    const spans = [_]Span{
        .{ .start = 2, .end = 6, .kind = .string },
        .{ .start = 8, .end = 15, .kind = .comment },
        .{ .start = 18, .end = 23, .kind = .comment },
    };
    try testing.expectEqual(Literal.code, at(&spans, src, 0));
    try testing.expectEqual(Literal.code, at(&spans, src, 2)); // `|"bc"`
    try testing.expectEqual(Literal.string, at(&spans, src, 3));
    try testing.expectEqual(Literal.string, at(&spans, src, 5)); // `"bc|"`
    try testing.expectEqual(Literal.code, at(&spans, src, 6)); // `"bc"|`
    try testing.expectEqual(Literal.comment, at(&spans, src, 12));
    try testing.expectEqual(Literal.code, at(&spans, src, 15)); // `*/|` — 닫혔다
    try testing.expectEqual(Literal.comment, at(&spans, src, 21));
    try testing.expectEqual(Literal.comment, at(&spans, src, 23)); // `// fg|` — 줄 끝
    try testing.expectEqual(Literal.code, at(&spans, src, 24)); // 다음 줄
    // 문서 끝의 줄 주석·문서 끝에서 닫힌 블록 주석.
    try testing.expectEqual(Literal.comment, at(&.{.{ .start = 0, .end = 4, .kind = .comment }}, "# ab", 4));
    try testing.expectEqual(Literal.code, at(&.{.{ .start = 0, .end = 4, .kind = .comment }}, "/**/", 4));
    try testing.expectEqual(Literal.code, at(&.{.{ .start = 0, .end = 8, .kind = .comment }}, "<!--a-->", 8));
    // 끝이 줄 끝이 아니면(같은 줄에 코드가 이어진다) 밖이다.
    try testing.expectEqual(Literal.code, at(&.{.{ .start = 0, .end = 2, .kind = .string }}, "''x", 2));
    try testing.expectEqual(Literal.code, at(&.{}, "abc", 1));
    // 개행을 품은 줄 주석 뒤의 빈 줄은 밖이다(`/// a⏎|⏎`).
    try testing.expectEqual(Literal.comment, at(&.{.{ .start = 0, .end = 6, .kind = .comment }}, "/// a\n\n", 5));
    try testing.expectEqual(Literal.code, at(&.{.{ .start = 0, .end = 6, .kind = .comment }}, "/// a\n\n", 6));
}

test "LIT4: 괄호 하나를 셀지(covers)와 코드만 남긴 사본(blank)" {
    const spans = [_]Span{
        .{ .start = 3, .end = 6, .kind = .string },
        .{ .start = 10, .end = 14, .kind = .comment },
    };
    try testing.expect(!covers(&spans, 2));
    try testing.expect(covers(&spans, 3));
    try testing.expect(covers(&spans, 5));
    try testing.expect(!covers(&spans, 6));
    try testing.expect(covers(&spans, 13));
    try testing.expect(!covers(&spans, 14));
    var buf: [16]u8 = undefined;
    // `f("{") { // {` — 문자열 [2,5)·주석 [9,13).
    const line = [_]Span{
        .{ .start = 2, .end = 5, .kind = .string },
        .{ .start = 9, .end = 13, .kind = .comment },
    };
    try testing.expectEqualStrings("f(   ) {     ", blank(&line, 0, "f(\"{\") { // {", buf[0..]));
    // 줄 머리가 조각 가운데서 시작한다(여러 줄 문자열의 둘째 줄) — 문서 byte 3 부터.
    try testing.expectEqualStrings("  ) {", blank(&line, 3, "{\") {", buf[0..]));
}
