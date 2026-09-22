//! 같은 낱말 강조(docs/editor-surface-tooling.md §8.2p · native-editor-visual-mapping.md §5.1a) — **순수** 계산 둘.
//!
//! ① `initialize` 응답의 `documentHighlightProvider`(bool·객체) → 지원 여부.
//! ② `DocumentHighlight[]` → 문서 byte 범위 목록(시작 순 정렬·같은 범위 중복 제거·상한 `max_spans`).
//!
//! **`kind` 는 안 쓴다.** 실측(2026-09-23): clangd 는 전부 `1`(Text), rust-analyzer 는 **없는 항목**과 `2`(Read) 를 섞어 내고, tsgo 만 `2`/`3` 로
//! 읽기·쓰기를 가른다. 색으로 가르면 서버에 따라 화면이 달라지므로 한 색이다(§5.1a).
const std = @import("std");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const line_index = @import("../editor/line_index.zig");
const LineIndex = line_index.LineIndex;

/// 한 응답에서 받는 강조 상한(§8.2p). 넘으면 거기까지만 든다 — 화면에 그릴 수 있는 것보다 훨씬 많다.
pub const max_spans: usize = 500;

/// 강조 하나 — 문서 절대 byte `[start, end)`.
pub const Span = struct { start: u32, end: u32 };

pub const Spans = struct {
    items: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Spans, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = .{};
    }
    pub fn clear(self: *Spans) void {
        self.items.clearRetainingCapacity();
    }
};

/// `initialize` 응답에 `documentHighlightProvider` 가 참(bool) 이거나 객체면 지원.
pub fn supportedFromResult(result: ?std.json.Value) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get("documentHighlightProvider") orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// 응답 → 문서 순서의 범위 목록. 실패하면 `out` 은 빈 채로 둔다(강조 없음).
pub fn decode(
    allocator: std.mem.Allocator,
    result: ?std.json.Value,
    content: []const u8,
    lines: LineIndex,
    enc: rpc.PositionEncoding,
    out: *Spans,
) error{OutOfMemory}!void {
    out.clear();
    const r = result orelse return;
    if (r != .array) return;
    for (r.array.items) |it| {
        if (out.items.items.len >= max_spans) break;
        if (it != .object) continue;
        const range = it.object.get("range") orelse continue;
        if (range != .object) continue;
        const lo = posOf(range.object.get("start"), content, lines, enc) orelse continue;
        const hi = posOf(range.object.get("end"), content, lines, enc) orelse continue;
        if (hi <= lo) continue; // 빈 범위는 그릴 것이 없다
        try out.items.append(allocator, .{ .start = lo, .end = hi });
    }
    std.mem.sort(Span, out.items.items, {}, lessThan);
    // **같은 범위 중복 제거** — 서버가 같은 자리를 두 번 낼 수 있고(실측: 읽기·쓰기 둘 다인 자리), 겹쳐 그리면 알파가 두 번 얹혀 더 진해진다.
    var keep: usize = 0;
    for (out.items.items) |sp| {
        if (keep > 0 and out.items.items[keep - 1].start == sp.start and out.items.items[keep - 1].end == sp.end) continue;
        out.items.items[keep] = sp;
        keep += 1;
    }
    out.items.shrinkRetainingCapacity(keep);
}

fn lessThan(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

fn posOf(v: ?std.json.Value, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding) ?u32 {
    const p = v orelse return null;
    if (p != .object) return null;
    const line = u32Of(p.object.get("line")) orelse return null;
    const ch = u32Of(p.object.get("character")) orelse return null;
    return @min(position.offsetOf(content, lines, line, ch, enc), @as(u32, @intCast(content.len)));
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "DHL1 응답 → 범위: 문서 순서로 정렬하고 같은 범위는 한 번만, 빈 범위·kind 는 버리며 utf-16 글자를 byte 로 (§8.2p)" {
    const a = testing.allocator;
    const content = "let area = 1;\nfn 가area() {}\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // 서버는 순서를 안 지키고(둘째가 앞), 같은 범위를 두 번 내며(읽기·쓰기), 빈 범위도 섞는다. `가` 는 utf-16 한 글자다.
    var p = try parse(a,
        \\[{"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":8}},"kind":3},
        \\ {"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":8}},"kind":2},
        \\ {"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":8}}},
        \\ {"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":2}}},
        \\ 7, {"range":{}}]
    );
    defer p.deinit();
    var out: Spans = .{};
    defer out.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 2), out.items.items.len);
    try testing.expectEqual(@as(u32, 4), out.items.items[0].start);
    try testing.expectEqual(@as(u32, 8), out.items.items[0].end);
    try testing.expectEqualStrings("area", content[out.items.items[0].start..out.items.items[0].end]);
    // 둘째 줄: utf-16 으로 `fn `(3) + `가`(1) 뒤가 글자 4 — byte 로는 3 + 3 = 6 이다.
    try testing.expectEqualStrings("area", content[out.items.items[1].start..out.items.items[1].end]);
}

test "DHL2 provider·빈 응답·상한 — bool·객체·거짓·없음, null 과 배열 아님은 강조 없음 (§8.2p)" {
    const a = testing.allocator;
    const content = "x\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    {
        var p = try parse(a, "{\"capabilities\":{\"documentHighlightProvider\":true}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"documentHighlightProvider\":{\"workDoneProgress\":false}}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"documentHighlightProvider\":false}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    try testing.expect(!supportedFromResult(null));
    var out: Spans = .{};
    defer out.deinit(a);
    try decode(a, null, content, lines, .utf16, &out);
    try testing.expectEqual(@as(usize, 0), out.items.items.len);
    {
        var p = try parse(a, "{\"not\":\"array\"}");
        defer p.deinit();
        try decode(a, p.value, content, lines, .utf16, &out);
        try testing.expectEqual(@as(usize, 0), out.items.items.len);
    }
    // 상한 — 넘치게 주면 거기까지만.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.appendSlice(a, "[");
        var i: usize = 0;
        while (i < max_spans + 10) : (i += 1) {
            if (i > 0) try buf.appendSlice(a, ",");
            try buf.appendSlice(a, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}");
        }
        try buf.appendSlice(a, "]");
        var p = try parse(a, buf.items);
        defer p.deinit();
        try decode(a, p.value, content, lines, .utf16, &out);
        try testing.expectEqual(@as(usize, 1), out.items.items.len); // 전부 같은 범위라 중복 제거로 하나
    }
}
