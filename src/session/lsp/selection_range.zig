//! 구조 기반 선택 확장의 서버 축(docs/editor-surface-tooling.md §8.2q) — **순수** 계산 둘.
//!
//! ① `initialize` 응답의 `selectionRangeProvider`(bool·객체) → 지원 여부.
//! ② `SelectionRange[]`(위치마다 하나, `parent` 사슬) → 위치마다 문서 byte 범위 목록(안쪽부터).
//!
//! **배열 길이가 보낸 위치 수와 다르면 통째로 실패다** — 어느 답이 어느 커서의 것인지 모른다. 원소가 `null` 이거나 꼴이
//! 틀리면 그 위치만 빈 목록이다(제품이 그 커서를 1층으로 채운다).
const std = @import("std");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const line_index = @import("../editor/line_index.zig");
const LineIndex = line_index.LineIndex;

/// 한 위치에서 따라 올라갈 `parent` 사슬의 상한(§8.2q). 서버가 순환·거대 사슬을 내도 끝난다.
pub const max_depth: usize = 256;

pub const Range = struct { start: u32, end: u32 };

/// 위치마다의 범위를 한 배열에 이어 담는다 — 위치 `i` 의 범위는 `ranges[starts[i]..starts[i+1]]`.
pub const Decoded = struct {
    ranges: std.ArrayList(Range) = .empty,
    starts: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.starts.deinit(allocator);
        self.* = .{};
    }
    pub fn clear(self: *Decoded) void {
        self.ranges.clearRetainingCapacity();
        self.starts.clearRetainingCapacity();
    }
    pub fn count(self: Decoded) usize {
        return if (self.starts.items.len == 0) 0 else self.starts.items.len - 1;
    }
    pub fn at(self: Decoded, i: usize) []const Range {
        return self.ranges.items[self.starts.items[i]..self.starts.items[i + 1]];
    }
};

/// `initialize` 응답에 `selectionRangeProvider` 가 참(bool)이거나 객체면 지원.
pub fn supportedFromResult(result: ?std.json.Value) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get("selectionRangeProvider") orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// 응답 → 위치마다 범위 목록. 배열이 아니거나 길이가 `n_positions` 와 다르면 `false`(그때 `out` 은 빈 채).
pub fn decode(
    allocator: std.mem.Allocator,
    result: ?std.json.Value,
    content: []const u8,
    lines: LineIndex,
    enc: rpc.PositionEncoding,
    n_positions: usize,
    out: *Decoded,
) error{OutOfMemory}!bool {
    out.clear();
    const r = result orelse return false;
    if (r != .array) return false;
    if (r.array.items.len != n_positions) return false;
    try out.starts.append(allocator, 0);
    for (r.array.items) |item| {
        var node: ?std.json.Value = item;
        var depth: usize = 0;
        while (node) |n| : (depth += 1) {
            if (depth >= max_depth) break;
            if (n != .object) break;
            const range = n.object.get("range") orelse break;
            if (range != .object) break;
            const lo = posOf(range.object.get("start"), content, lines, enc) orelse break;
            const hi = posOf(range.object.get("end"), content, lines, enc) orelse break;
            if (hi >= lo) try out.ranges.append(allocator, .{ .start = lo, .end = hi });
            node = n.object.get("parent");
        }
        try out.starts.append(allocator, @intCast(out.ranges.items.len));
    }
    return true;
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

test "SSEL6 응답 → 위치마다 범위: parent 사슬을 안쪽부터 평탄화하고, null 원소는 빈 목록, utf-16 글자를 byte 로 (§8.2q)" {
    const a = testing.allocator;
    const content = "let 가x = 1;\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    // 위치 둘: 첫째는 x(utf-16 으로 글자 5 = `let `(4) + `가`(1)) → `가x`? 아니다 — 식별자 `가x` [4,6) utf-16 → 문장 [0,11) utf-16. 둘째는 null.
    var p = try parse(a,
        \\[{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":6}},
        \\  "parent":{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":6}},
        \\    "parent":{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}},
        \\ null]
    );
    defer p.deinit();
    var out: Decoded = .{};
    defer out.deinit(a);
    try testing.expect(try decode(a, p.value, content, lines, .utf16, 2, &out));
    try testing.expectEqual(@as(usize, 2), out.count());
    const first = out.at(0);
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expectEqualStrings("x", content[first[0].start..first[0].end]); // `가` 는 utf-16 한 글자 · byte 셋
    try testing.expectEqualStrings("가x", content[first[1].start..first[1].end]);
    try testing.expectEqualStrings("let 가x = 1;", content[first[2].start..first[2].end]);
    try testing.expectEqual(@as(usize, 0), out.at(1).len);
}

test "SSEL7 길이가 위치 수와 다르거나 배열이 아니면 통째로 실패 · provider bool/객체 · 깊이 상한 (§8.2q)" {
    const a = testing.allocator;
    const content = "x\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var out: Decoded = .{};
    defer out.deinit(a);
    {
        var p = try parse(a, "[null]");
        defer p.deinit();
        try testing.expect(!try decode(a, p.value, content, lines, .utf8, 2, &out)); // 둘을 보냈는데 하나가 왔다
        try testing.expectEqual(@as(usize, 0), out.count());
    }
    try testing.expect(!try decode(a, null, content, lines, .utf8, 1, &out));
    {
        var p = try parse(a, "{\"capabilities\":{\"selectionRangeProvider\":true}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"selectionRangeProvider\":{\"workDoneProgress\":false}}}");
        defer p.deinit();
        try testing.expect(supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{\"selectionRangeProvider\":false}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    {
        var p = try parse(a, "{\"capabilities\":{}}");
        defer p.deinit();
        try testing.expect(!supportedFromResult(p.value));
    }
    // 깊이 상한 — max_depth 보다 깊은 사슬은 거기서 끊는다(서로 다른 범위여야 상한이 보인다: 전부 같은 [0,1) 이라도 평탄화는 중복을 안 거른다).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.appendSlice(a, "[");
        var i: usize = 0;
        while (i < max_depth + 10) : (i += 1) try buf.appendSlice(a, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"parent\":");
        try buf.appendSlice(a, "null");
        i = 0;
        while (i < max_depth + 10) : (i += 1) try buf.appendSlice(a, "}");
        try buf.appendSlice(a, "]");
        var p = try std.json.parseFromSlice(std.json.Value, a, buf.items, .{ .max_value_len = null });
        defer p.deinit();
        try testing.expect(try decode(a, p.value, content, lines, .utf8, 1, &out));
        try testing.expectEqual(max_depth, out.at(0).len);
    }
}
