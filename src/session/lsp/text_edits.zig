//! LSP `TextEdit[]` → `delta.Change[]`(docs/editor-surface-tooling.md §8.2e · document-model §3.6). 줄·글자(서버 인코딩)를 byte 로 옮기고,
//! `start` 오름차순으로 정렬하고(같은 start 의 삽입은 온 순서), **겹치면 전부 거부**한다(명세 「must not overlap」 — 반만 적용된 문서를
//! 만들지 않는다). `newText` 는 여기서 복사해 `Changes.deinit` 까지 든다 — `Change.text` 는 소유하지 않는 조각이라 응답 트리가 사라져도 살아야
//! 한다. 순수 계산.

const std = @import("std");
const delta_mod = @import("../editor/delta.zig");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const LineIndex = @import("../editor/line_index.zig").LineIndex;

pub const Changes = struct {
    items: []delta_mod.Change = &.{},
    texts: [][]u8 = &.{},

    pub fn deinit(self: *Changes, allocator: std.mem.Allocator) void {
        for (self.texts) |t| allocator.free(t);
        if (self.texts.len > 0) allocator.free(self.texts);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = .{};
    }

    pub fn delta(self: Changes) delta_mod.Delta {
        return .{ .changes = self.items };
    }
};

pub const Error = error{ Overlap, Malformed, OutOfMemory };

/// `edits` 는 응답의 `result`(배열). 배열이 아니거나 비면 빈 `Changes`(적용할 것 없음). 항목의 모양이 틀리면 `Malformed`.
pub fn toChanges(allocator: std.mem.Allocator, edits: ?std.json.Value, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding) Error!Changes {
    const v = edits orelse return .{};
    const arr = switch (v) {
        .array => |a| a,
        else => return .{},
    };
    if (arr.items.len == 0) return .{};
    const Raw = struct { start: usize, end: usize, text: []const u8, order: usize };
    var raw = try allocator.alloc(Raw, arr.items.len);
    defer allocator.free(raw);
    for (arr.items, 0..) |it, i| {
        if (it != .object) return error.Malformed;
        const o = it.object;
        const range = o.get("range") orelse return error.Malformed;
        if (range != .object) return error.Malformed;
        const st = posOf(range.object.get("start")) orelse return error.Malformed;
        const en = posOf(range.object.get("end")) orelse return error.Malformed;
        const text_v = o.get("newText") orelse return error.Malformed;
        if (text_v != .string) return error.Malformed;
        const start = position.offsetOf(content, lines, st.line, st.character, enc);
        var end = position.offsetOf(content, lines, en.line, en.character, enc);
        if (end < start) end = start; // 뒤집힌 범위는 삽입으로 — 명세 밖이지만 문서를 깨지는 않는다
        raw[i] = .{ .start = start, .end = end, .text = text_v.string, .order = i };
    }
    // `start` 오름차순, 같은 start 는 온 순서(안정) — 같은 자리의 삽입 둘은 그 순서로 들어간다.
    std.mem.sort(Raw, raw, {}, struct {
        fn f(_: void, a: Raw, b: Raw) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.order < b.order;
        }
    }.f);
    // 겹침 — 앞 것의 end 를 넘어 시작해야 한다(같은 자리 삽입은 end == start 라 통과).
    var prev_end: usize = 0;
    for (raw, 0..) |r, i| {
        if (i > 0 and r.start < prev_end) return error.Overlap;
        prev_end = r.end;
    }
    var texts = try allocator.alloc([]u8, raw.len);
    var owned: usize = 0;
    errdefer {
        for (texts[0..owned]) |t| allocator.free(t);
        allocator.free(texts);
    }
    for (raw) |r| {
        texts[owned] = try allocator.dupe(u8, r.text);
        owned += 1;
    }
    const items = try allocator.alloc(delta_mod.Change, raw.len);
    for (raw, 0..) |r, i| items[i] = .{ .start = r.start, .end = r.end, .text = texts[i] };
    return .{ .items = items, .texts = texts };
}

/// 적용 **전** 본문에 대한 정렬·비겹침 `changes` 의 역연산(§8.2f 「기록」) — 적용 **뒤** 좌표로, 각 항목이 새 텍스트 자리를 원래 조각으로
/// 되돌린다. `delta.apply` 가 돌려주는 `Inverse` 는 undo 스택이 가져가므로, 파일 기록은 이것을 따로 만든다. 텍스트는 복사.
pub fn inverseOf(allocator: std.mem.Allocator, content_before: []const u8, changes: []const delta_mod.Change) error{OutOfMemory}!Changes {
    if (changes.len == 0) return .{};
    var texts = try allocator.alloc([]u8, changes.len);
    var owned: usize = 0;
    errdefer {
        for (texts[0..owned]) |t| allocator.free(t);
        allocator.free(texts);
    }
    const items = try allocator.alloc(delta_mod.Change, changes.len);
    errdefer allocator.free(items);
    var shift: i64 = 0;
    for (changes, 0..) |c, i| {
        const start = @min(c.start, content_before.len);
        const end = @min(@max(c.end, start), content_before.len);
        texts[owned] = try allocator.dupe(u8, content_before[start..end]);
        owned += 1;
        const new_start: usize = @intCast(@as(i64, @intCast(start)) + shift);
        items[i] = .{ .start = new_start, .end = new_start + c.text.len, .text = texts[i] };
        shift += @as(i64, @intCast(c.text.len)) - @as(i64, @intCast(end - start));
    }
    return .{ .items = items, .texts = texts };
}

fn posOf(v: ?std.json.Value) ?struct { line: u32, character: u32 } {
    const x = v orelse return null;
    if (x != .object) return null;
    return .{
        .line = u32Of(x.object.get("line")) orelse return null,
        .character = u32Of(x.object.get("character")) orelse return null,
    };
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const line_index = @import("../editor/line_index.zig");
const maru_buffer = @import("../editor/buffer.zig");

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "TXE1 TextEdit[] → Change[]: 인코딩으로 byte, start 오름차순, 같은 start 삽입은 온 순서, 텍스트는 복사 (§8.2e)" {
    const a = testing.allocator;
    const content = "가 x;\nint  y;\n"; // 가 = 3 byte / utf-16 1 unit
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    var p = try parse(a,
        \\[
        \\ {"range":{"start":{"line":1,"character":3},"end":{"line":1,"character":5}},"newText":" "},
        \\ {"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":2}},"newText":"A"},
        \\ {"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":2}},"newText":"B"}
        \\]
    );
    defer p.deinit();
    var ch = try toChanges(a, p.value, content, idx, .utf16);
    defer ch.deinit(a);
    try testing.expectEqual(@as(usize, 3), ch.items.len);
    // utf-16 character 2 = 가(1) + ' '(1) → byte 4. 같은 자리 삽입 둘 — A 가 먼저.
    try testing.expectEqual(@as(usize, 4), ch.items[0].start);
    try testing.expectEqualStrings("A", ch.items[0].text);
    try testing.expectEqualStrings("B", ch.items[1].text);
    try testing.expectEqual(@as(usize, 7 + 3), ch.items[2].start);
    try testing.expectEqual(@as(usize, 7 + 5), ch.items[2].end);
    try testing.expect(ch.delta().isWellFormed());
    // 텍스트는 응답 트리가 아니라 우리 것이다.
    try testing.expect(@intFromPtr(ch.items[0].text.ptr) != @intFromPtr(p.value.array.items[1].object.get("newText").?.string.ptr));
}

test "TXE3 inverseOf — 적용 뒤 좌표로 원래 조각을 되돌린다; 되감으면 원문 (§8.2f)" {
    const a = testing.allocator;
    const before = "int add(int a) { return add(a); }\n";
    // add → add2 둘, int → long 하나(길이가 다른 세 가지).
    const changes = [_]delta_mod.Change{
        .{ .start = 0, .end = 3, .text = "long" },
        .{ .start = 4, .end = 7, .text = "add2" },
        .{ .start = 24, .end = 27, .text = "add2" },
    };
    var buf = try maru_buffer.Buffer.init(a, before);
    defer buf.deinit();
    var sel_items = [_]@import("../editor/selection.zig").Selection{.{ .anchor_start = 0, .anchor_end = 0, .focus = 0 }};
    var sels = @import("../editor/selection.zig").Selections.init(&sel_items, 0);
    var inv_unused = try delta_mod.apply(a, &buf, .{ .changes = &changes }, &sels);
    defer inv_unused.deinit();
    const after = try buf.copyAll(a);
    defer a.free(after);
    try testing.expectEqualStrings("long add2(int a) { return add2(a); }\n", after);
    var inv = try inverseOf(a, before, &changes);
    defer inv.deinit(a);
    try testing.expectEqual(@as(usize, 3), inv.items.len);
    try testing.expectEqual(@as(usize, 0), inv.items[0].start);
    try testing.expectEqual(@as(usize, 4), inv.items[0].end);
    try testing.expectEqualStrings("int", inv.items[0].text);
    try testing.expectEqual(@as(usize, 5), inv.items[1].start); // "long " 뒤
    try testing.expectEqual(@as(usize, 9), inv.items[1].end);
    try testing.expectEqual(@as(usize, 26), inv.items[2].start); // 앞 둘이 +1·+1 밀었다
    try testing.expectEqual(@as(usize, 30), inv.items[2].end);
    try testing.expect(inv.delta().isWellFormed());
    // 되감으면 원문.
    var inv2 = try delta_mod.apply(a, &buf, inv.delta(), &sels);
    defer inv2.deinit();
    const back = try buf.copyAll(a);
    defer a.free(back);
    try testing.expectEqualStrings(before, back);
    var e = try inverseOf(a, before, &.{});
    defer e.deinit(a);
    try testing.expectEqual(@as(usize, 0), e.items.len);
}

test "TXE2 겹치면 전부 거부, 모양이 틀리면 Malformed, 빈 배열·배열 아님은 빈 결과, 줄 밖은 문서 끝, 뒤집힌 범위는 삽입 (§8.2e)" {
    const a = testing.allocator;
    const content = "abc\ndef\n";
    var idx = try line_index.build(a, content);
    defer idx.deinit();
    var ov = try parse(a, "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":2}},\"newText\":\"x\"},{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"y\"}]");
    defer ov.deinit();
    try testing.expectError(error.Overlap, toChanges(a, ov.value, content, idx, .utf8));
    var bad = try parse(a, "[{\"range\":{\"start\":{\"line\":0}},\"newText\":\"x\"}]");
    defer bad.deinit();
    try testing.expectError(error.Malformed, toChanges(a, bad.value, content, idx, .utf8));
    var no_text = try parse(a, "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}]");
    defer no_text.deinit();
    try testing.expectError(error.Malformed, toChanges(a, no_text.value, content, idx, .utf8));
    var empty = try parse(a, "[]");
    defer empty.deinit();
    var e = try toChanges(a, empty.value, content, idx, .utf8);
    defer e.deinit(a);
    try testing.expectEqual(@as(usize, 0), e.items.len);
    var n = try toChanges(a, null, content, idx, .utf8);
    defer n.deinit(a);
    try testing.expectEqual(@as(usize, 0), n.items.len);
    var far = try parse(a, "[{\"range\":{\"start\":{\"line\":9,\"character\":0},\"end\":{\"line\":9,\"character\":9}},\"newText\":\"z\"},{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":1}},\"newText\":\"q\"}]");
    defer far.deinit();
    var f = try toChanges(a, far.value, content, idx, .utf8);
    defer f.deinit(a);
    try testing.expectEqual(@as(usize, 2), f.items.len);
    try testing.expectEqual(@as(usize, 2), f.items[0].start); // 뒤집힌 범위 → 삽입(start=end=2)
    try testing.expectEqual(@as(usize, 2), f.items[0].end);
    try testing.expectEqual(content.len, f.items[1].start); // 줄 밖 → 문서 끝
    try testing.expectEqual(content.len, f.items[1].end);
    // 인접(앞의 end == 뒤의 start)은 겹침이 아니다.
    var adj = try parse(a, "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"newText\":\"x\"},{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":2}},\"newText\":\"y\"}]");
    defer adj.deinit();
    var ad = try toChanges(a, adj.value, content, idx, .utf8);
    defer ad.deinit(a);
    try testing.expectEqual(@as(usize, 2), ad.items.len);
}
