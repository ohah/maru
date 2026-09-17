//! 호버 박스에 담을 **마크다운 축소**(docs/native-editor-ui.md §8.3 · editor-surface-tooling §8.2b). LSP `hover` 가 주는 짧은 문서
//! 조각을 **등폭 줄 목록**으로 편다 — 마크다운 렌더러가 아니다(§8.3 「이것은 마크다운 렌더러가 아니다」):
//!
//! - 펜스(``` · ~~~)는 안쪽 줄을 **그대로**(`.code`) — 호버 내용의 실질은 대개 시그니처(코드)다. 이 슬라이스는 색이 없다.
//! - 인라인 코드·굵게·이탤릭은 **기호만 지운다**(`` ` `` · `**` · 짝 있는 `*…*`). `_` 는 건드리지 않는다 — `snake_case` 가 문서에 흔하다.
//! - 제목 `#` 은 기호를 뗀 줄, 목록 `-`/`*`/`+` 는 `• `, 번호 목록은 그대로, 인용 `>` 은 뗀다, 수평선은 빈 줄이다.
//! - 링크 `[t](u)` → `t`, 이미지 `![a](u)` → `a`, 표 행은 셀을 두 칸으로 잇고 구분 행(`|---|`)은 버린다.
//! - HTML 엔티티 넷(`&lt;` `&gt;` `&amp;` `&nbsp;`)은 푼다 — clangd 가 그렇게 보낸다. `\r` 은 버린다.
//! - 빈 줄은 **하나로** 접고 앞뒤 빈 줄은 뗀다.
//!
//! 순수 계산. 줄 텍스트는 호출자 allocator 에 복사한다(`Lines.deinit`).

const std = @import("std");

pub const Kind = enum { text, code };

pub const Line = struct { text: []const u8, kind: Kind };

pub const Lines = struct {
    items: std.ArrayList(Line) = .empty,

    pub fn deinit(self: *Lines, allocator: std.mem.Allocator) void {
        for (self.items.items) |l| allocator.free(l.text);
        self.items.deinit(allocator);
    }
};

/// 마크다운 → 줄 목록. 실패(OOM)면 그때까지의 줄은 버린다.
pub fn reduce(allocator: std.mem.Allocator, markdown: []const u8) error{OutOfMemory}!Lines {
    var out: Lines = .{};
    errdefer out.deinit(allocator);
    var in_fence = false;
    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) {
            try push(allocator, &out, line, .code);
            continue;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const body = blockPrefix(trimmed, allocator, &buf) catch return error.OutOfMemory;
        switch (body) {
            .skip => continue,
            .blank => try pushBlank(allocator, &out),
            .text => |t| {
                var inline_buf: std.ArrayList(u8) = .empty;
                defer inline_buf.deinit(allocator);
                try reduceInline(allocator, &inline_buf, t);
                const final = std.mem.trimEnd(u8, inline_buf.items, " \t");
                if (final.len == 0) try pushBlank(allocator, &out) else try push(allocator, &out, final, .text);
            },
        }
    }
    // 뒤쪽 빈 줄을 뗀다.
    while (out.items.items.len > 0 and out.items.items[out.items.items.len - 1].text.len == 0) {
        const last = out.items.pop().?;
        allocator.free(last.text);
    }
    return out;
}

fn push(allocator: std.mem.Allocator, out: *Lines, text: []const u8, kind: Kind) error{OutOfMemory}!void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try out.items.append(allocator, .{ .text = owned, .kind = kind });
}

/// 빈 줄 — 앞이 비어 있거나(맨 앞) 직전이 빈 줄이면 넣지 않는다(하나로 접는다).
fn pushBlank(allocator: std.mem.Allocator, out: *Lines) error{OutOfMemory}!void {
    const n = out.items.items.len;
    if (n == 0 or out.items.items[n - 1].text.len == 0) return;
    try push(allocator, out, "", .text);
}

const Block = union(enum) { skip, blank, text: []const u8 };

/// 줄 머리의 블록 기호를 처리한다. 표 행은 `buf` 에 다시 조립한다.
fn blockPrefix(trimmed: []const u8, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) error{OutOfMemory}!Block {
    if (trimmed.len == 0) return .blank;
    // 수평선: `---` `***` `___`(셋 이상, 그 글자와 공백만).
    if (isRule(trimmed)) return .blank;
    // 제목.
    if (trimmed[0] == '#') {
        var i: usize = 0;
        while (i < trimmed.len and trimmed[i] == '#') i += 1;
        if (i <= 6 and i < trimmed.len and trimmed[i] == ' ') return .{ .text = std.mem.trimStart(u8, trimmed[i..], " ") };
    }
    // 인용.
    if (trimmed[0] == '>') return .{ .text = std.mem.trimStart(u8, trimmed[1..], " ") };
    // 목록.
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        try buf.appendSlice(allocator, "• ");
        try buf.appendSlice(allocator, trimmed[2..]);
        return .{ .text = buf.items };
    }
    // 표.
    if (trimmed[0] == '|') {
        const inner = std.mem.trim(u8, trimmed, "|");
        if (isTableSeparator(inner)) return .skip;
        var cells = std.mem.splitScalar(u8, inner, '|');
        var first = true;
        while (cells.next()) |cell| {
            if (!first) try buf.appendSlice(allocator, "  ");
            first = false;
            try buf.appendSlice(allocator, std.mem.trim(u8, cell, " \t"));
        }
        return .{ .text = buf.items };
    }
    return .{ .text = trimmed };
}

fn isRule(t: []const u8) bool {
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |b| {
        if (b == c) n += 1 else if (b != ' ') return false;
    }
    return n >= 3;
}

fn isTableSeparator(inner: []const u8) bool {
    if (inner.len == 0) return false;
    var has_dash = false;
    for (inner) |b| switch (b) {
        '-' => has_dash = true,
        ':', '|', ' ' => {},
        else => return false,
    };
    return has_dash;
}

/// 인라인 기호를 지운다(§8.3 「인라인 코드·굵게·이탤릭은 서식으로 해석하되 기호는 지운다」).
fn reduceInline(allocator: std.mem.Allocator, out: *std.ArrayList(u8), t: []const u8) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < t.len) {
        const b = t[i];
        // 이스케이프 — `\*` `\_` `\`` 등은 그 글자.
        if (b == '\\' and i + 1 < t.len and isPunct(t[i + 1])) {
            try out.append(allocator, t[i + 1]);
            i += 2;
            continue;
        }
        if (b == '`') {
            i += 1;
            continue;
        }
        if (b == '*') {
            if (i + 1 < t.len and t[i + 1] == '*') {
                i += 2;
                continue;
            }
            // 짝 있는 `*…*` 만 — `a * b` 의 별은 남긴다(뒤에 공백이 오면 기호가 아니다).
            if (i + 1 < t.len and t[i + 1] != ' ') {
                if (std.mem.indexOfScalarPos(u8, t, i + 1, '*')) |close| if (close > i + 1 and t[close - 1] != ' ') {
                    try reduceInline(allocator, out, t[i + 1 .. close]);
                    i = close + 1;
                    continue;
                };
            }
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        if (b == '!' and i + 1 < t.len and t[i + 1] == '[') {
            if (linkParts(t[i + 1 ..])) |lp| {
                try reduceInline(allocator, out, lp.text);
                i += 1 + lp.consumed;
                continue;
            }
        }
        if (b == '[') {
            if (linkParts(t[i..])) |lp| {
                try reduceInline(allocator, out, lp.text);
                i += lp.consumed;
                continue;
            }
        }
        if (b == '&') {
            if (entity(t[i..])) |e| {
                try out.appendSlice(allocator, e.text);
                i += e.consumed;
                continue;
            }
        }
        try out.append(allocator, b);
        i += 1;
    }
}

fn isPunct(b: u8) bool {
    return switch (b) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '<', '>', '~' => true,
        else => false,
    };
}

const LinkParts = struct { text: []const u8, consumed: usize };

/// `[text](url)` 의 text 와 소비 길이. 모양이 아니면 `null`(글자 그대로 둔다).
fn linkParts(t: []const u8) ?LinkParts {
    if (t.len < 4 or t[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
    if (close + 1 >= t.len or t[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, t, close + 2, ')') orelse return null;
    return .{ .text = t[1..close], .consumed = end + 1 };
}

const Entity = struct { text: []const u8, consumed: usize };

fn entity(t: []const u8) ?Entity {
    const table = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "&lt;", .text = "<" },
        .{ .name = "&gt;", .text = ">" },
        .{ .name = "&amp;", .text = "&" },
        .{ .name = "&nbsp;", .text = " " },
    };
    for (table) |e| if (std.mem.startsWith(u8, t, e.name)) return .{ .text = e.text, .consumed = e.name.len };
    return null;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectLines(lines: Lines, expected: []const struct { []const u8, Kind }) !void {
    try testing.expectEqual(expected.len, lines.items.items.len);
    for (expected, lines.items.items) |e, got| {
        try testing.expectEqualStrings(e[0], got.text);
        try testing.expectEqual(e[1], got.kind);
    }
}

test "HVT1 펜스는 안쪽 줄 그대로(.code), 인라인 기호는 지우고, 빈 줄은 하나로, 앞뒤 빈 줄은 뗀다 (§8.3·§8.2b)" {
    const a = testing.allocator;
    var l = try reduce(a, "\n\n```c\nint  add(int a, int b)\n```\n\n\n**bold** and `code` and *em* here\n\n");
    defer l.deinit(a);
    try expectLines(l, &.{ .{ "int  add(int a, int b)", .code }, .{ "", .text }, .{ "bold and code and em here", .text } });
}

test "HVT2 블록 기호 — 제목·목록·인용·수평선·표; 별은 짝이 있을 때만 기호다; _ 는 안 건드린다" {
    const a = testing.allocator;
    var l = try reduce(a, "# Title\n- one\n* two\n1. three\n> quoted\n---\n| a | b |\n|---|:--:|\n| 1 | 2 |\nx * y and snake_case *and* \\*lit\\*");
    defer l.deinit(a);
    try expectLines(l, &.{
        .{ "Title", .text },
        .{ "• one", .text },
        .{ "• two", .text },
        .{ "1. three", .text },
        .{ "quoted", .text },
        .{ "", .text },
        .{ "a  b", .text },
        .{ "1  2", .text },
        .{ "x * y and snake_case and *lit*", .text },
    });
}

test "HVT3 링크·이미지는 글자만, 엔티티 넷은 풀고, CR 은 버리고, ~~~ 펜스도 펜스다" {
    const a = testing.allocator;
    var l = try reduce(a, "see [docs](http://x) and ![pic](p.png) &lt;T&gt;&nbsp;&amp;\r\n~~~\n**not bold**\n~~~\n[broken](x");
    defer l.deinit(a);
    try expectLines(l, &.{ .{ "see docs and pic <T> &", .text }, .{ "**not bold**", .code }, .{ "[broken](x", .text } });
}

test "HVT4 빈 입력과 공백만인 입력은 줄이 없다" {
    const a = testing.allocator;
    var l = try reduce(a, "");
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 0), l.items.items.len);
    var m = try reduce(a, "\n \n\t\n");
    defer m.deinit(a);
    try testing.expectEqual(@as(usize, 0), m.items.items.len);
}
