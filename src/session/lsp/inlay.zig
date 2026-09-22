//! 인레이 힌트(docs/editor-surface-tooling.md §8.2n · native-editor-visual-mapping.md §4.1h) — **순수** 계산 셋.
//!
//! ① `initialize` 응답의 `inlayHintProvider`(bool·객체) → 지원 여부.
//! ② 응답 배열 → 문서 순서의 `Hint{offset, text}`: `position` 을 줄 안 byte 로(`position.offsetOf`), `label` 은 문자열이든 조각 배열이든
//!   `value` 를 잇고, `paddingLeft/Right` 는 공백 하나. **정제**: ASCII 출력 가능 문자만(그 밖은 `?`, 제어·개행은 공백) — 렌더가 `1byte = 1열` 로
//!   잘라 그린다(§4.1h). 한 힌트 `max_text` 열(넘으면 `…` 대신 ASCII `...`), 상한 `max_hints`.
//! ③ 편집 통지로 힌트 밀기 — **경계 = 뒤**: 앵커 byte 에 삽입하면 힌트가 밀린다(`let v|: Vec` 에 `x` → `let vx|: Vec`). 편집 구간 **안**(start <
//!   at < old_end)의 힌트는 버린다.
const std = @import("std");
const position = @import("position.zig");
const rpc = @import("rpc.zig");
const line_index = @import("../editor/line_index.zig");
const LineIndex = line_index.LineIndex;

/// 한 응답에서 받는 힌트 상한(§8.2n).
pub const max_hints: usize = 2_000;
/// 한 힌트의 표시 폭 상한(§4.1h) — 넘으면 `...` 로 끝난다.
pub const max_text: usize = 48;

/// 힌트 하나. `offset` 은 **문서 절대 byte**(줄 인덱스로 줄 안 byte 를 얻는다), `text` 는 정제된 ASCII(소유 — `Hints.deinit`).
pub const Hint = struct { offset: u32, text: []u8 };

pub const Hints = struct {
    items: std.ArrayList(Hint) = .empty,

    pub fn deinit(self: *Hints, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit(allocator);
    }
    pub fn clear(self: *Hints, allocator: std.mem.Allocator) void {
        for (self.items.items) |h| allocator.free(h.text);
        self.items.clearRetainingCapacity();
    }
};

/// `initialize` 응답에 `inlayHintProvider` 가 참(bool) 이거나 객체면 지원.
pub fn supportedFromResult(result: ?std.json.Value) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get("inlayHintProvider") orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// 라벨 조각을 잇고 정제한다(ASCII 출력 가능만, 상한). `pad_l`/`pad_r` 면 공백 하나씩. 소유를 넘긴다.
pub fn sanitizeLabel(allocator: std.mem.Allocator, label: std.json.Value, pad_l: bool, pad_r: bool) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (pad_l) try out.append(allocator, ' ');
    switch (label) {
        .string => |s| try appendClean(allocator, &out, s),
        .array => |parts| for (parts.items) |p| {
            if (p != .object) continue;
            const v = p.object.get("value") orelse continue;
            if (v == .string) try appendClean(allocator, &out, v.string);
        },
        else => {},
    }
    if (pad_r) try out.append(allocator, ' ');
    if (out.items.len > max_text) {
        out.shrinkRetainingCapacity(max_text - 3);
        try out.appendSlice(allocator, "...");
    }
    return try out.toOwnedSlice(allocator);
}

fn appendClean(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b >= 0x20 and b < 0x7F) {
            try out.append(allocator, b);
            i += 1;
        } else if (b < 0x20 or b == 0x7F) {
            try out.append(allocator, ' '); // 제어·개행
            i += 1;
        } else {
            try out.append(allocator, '?'); // 비 ASCII — 코드포인트 하나를 한 칸으로
            const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
            i += @max(1, @min(n, s.len - i));
        }
    }
}

/// 응답 `result`(`InlayHint[]` 또는 `null`) → 문서 순서(offset 오름차순, 같은 offset 은 응답 순)의 힌트. `null`·배열 아님은 빈 목록.
pub fn decode(allocator: std.mem.Allocator, result: ?std.json.Value, content: []const u8, lines: LineIndex, enc: rpc.PositionEncoding, out: *Hints) error{OutOfMemory}!void {
    out.clear(allocator);
    const r = result orelse return;
    if (r != .array) return;
    for (r.array.items) |it| {
        if (out.items.items.len >= max_hints) break;
        if (it != .object) continue;
        const o = it.object;
        const pos = o.get("position") orelse continue;
        if (pos != .object) continue;
        const line = u32Of(pos.object.get("line")) orelse continue;
        const character = u32Of(pos.object.get("character")) orelse continue;
        const label = o.get("label") orelse continue;
        const pad_l = boolOf(o.get("paddingLeft"));
        const pad_r = boolOf(o.get("paddingRight"));
        const text = try sanitizeLabel(allocator, label, pad_l, pad_r);
        if (text.len == 0) {
            allocator.free(text);
            continue;
        }
        const offset = position.offsetOf(content, lines, line, character, enc);
        try out.items.append(allocator, .{ .offset = @min(offset, @as(u32, @intCast(content.len))), .text = text });
    }
    std.mem.sort(Hint, out.items.items, {}, struct {
        fn f(_: void, a: Hint, b: Hint) bool {
            return a.offset < b.offset;
        }
    }.f);
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

fn boolOf(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return x == .bool and x.bool;
}

/// 편집 통지(§4.1h 「편집과의 결합」): `[start, old_end)` 가 `[start, new_end)` 로 바뀌었다. **경계 = 뒤** — `at == start` 인 힌트는 밀린다,
/// `start < at < old_end` 는 버린다, `at >= old_end` 는 `new_end - old_end` 만큼 옮긴다. 안정 정렬을 유지한다.
pub fn shift(allocator: std.mem.Allocator, hints: *Hints, start: u32, old_end: u32, new_end: u32) void {
    var keep: usize = 0;
    for (hints.items.items) |h| {
        var hh = h;
        if (h.offset > start and h.offset < old_end) {
            allocator.free(h.text);
            continue;
        }
        if (h.offset >= old_end or h.offset == start) {
            const delta: i64 = @as(i64, new_end) - @as(i64, old_end);
            if (h.offset == start and old_end == start) {
                // 삽입 — 앵커에서 밀린다.
                hh.offset = @intCast(@as(i64, h.offset) + delta);
            } else if (h.offset == start) {
                // 앵커에서 시작하는 교체/삭제 — 힌트는 그 자리에 남는다(구간의 앞 경계).
            } else {
                hh.offset = @intCast(@max(0, @as(i64, h.offset) + delta));
            }
        }
        hints.items.items[keep] = hh;
        keep += 1;
    }
    hints.items.shrinkRetainingCapacity(keep);
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "INL6 응답 → 힌트: 조각 배열 잇기·padding 공백·정제(비 ASCII → ?, 제어 → 공백)·상한 48·offset 정렬·utf-16 글자 → byte (§8.2n·§4.1h)" {
    const a = testing.allocator;
    const content = "let v = 1;\nadd(가, 2)\n";
    var lines = try line_index.build(a, content);
    defer lines.deinit();
    var p = try parse(a,
        \\[{"position":{"line":1,"character":7},"label":"b:","paddingRight":true},
        \\ {"position":{"line":0,"character":5},"label":[{"value":": "},{"value":"Vec"},{"value":"<i32>","location":{}}],"paddingLeft":false},
        \\ {"position":{"line":1,"character":4},"label":"가:\tx","paddingRight":true},
        \\ {"position":{"line":0,"character":9},"label":"0123456789012345678901234567890123456789ABCDEFGHIJKLMNOP"},
        \\ {"position":{"line":0,"character":1},"label":""},
        \\ 7, {"label":"x"}]
    );
    defer p.deinit();
    var hints: Hints = .{};
    defer hints.deinit(a);
    try decode(a, p.value, content, lines, .utf16, &hints);
    try testing.expectEqual(@as(usize, 4), hints.items.items.len);
    try testing.expectEqual(@as(u32, 5), hints.items.items[0].offset);
    try testing.expectEqualStrings(": Vec<i32>", hints.items.items[0].text);
    try testing.expectEqual(@as(u32, 9), hints.items.items[1].offset);
    try testing.expectEqual(max_text, hints.items.items[1].text.len);
    try testing.expect(std.mem.endsWith(u8, hints.items.items[1].text, "..."));
    try testing.expectEqual(@as(u32, 11 + 4), hints.items.items[2].offset); // 줄 1 글자 4 = `가` 앞
    try testing.expectEqualStrings("?: x ", hints.items.items[2].text); // 가 → ? · 탭 → 공백 · padRight
    try testing.expectEqual(@as(u32, 11 + 9), hints.items.items[3].offset); // utf-16 글자 7 = `2`(`가` 가 3 byte 라 byte 9)
    try testing.expectEqualStrings("b: ", hints.items.items[3].text);
    // null·배열 아님 → 빈 목록.
    try decode(a, null, content, lines, .utf8, &hints);
    try testing.expectEqual(@as(usize, 0), hints.items.items.len);
}

test "INL7 provider — bool·객체·거짓·없음 (§8.2n)" {
    const a = testing.allocator;
    var t = try parse(a, "{\"capabilities\":{\"inlayHintProvider\":true}}");
    defer t.deinit();
    try testing.expect(supportedFromResult(t.value));
    var o = try parse(a, "{\"capabilities\":{\"inlayHintProvider\":{\"resolveProvider\":true}}}");
    defer o.deinit();
    try testing.expect(supportedFromResult(o.value));
    var f = try parse(a, "{\"capabilities\":{\"inlayHintProvider\":false}}");
    defer f.deinit();
    try testing.expect(!supportedFromResult(f.value));
    var n = try parse(a, "{\"capabilities\":{}}");
    defer n.deinit();
    try testing.expect(!supportedFromResult(n.value));
    try testing.expect(!supportedFromResult(null));
}

test "INL8 편집 밀기 — 경계 = 뒤: 앵커에 삽입하면 밀리고, 구간 안은 버리고, 뒤는 옮기고, 앵커에서 시작하는 삭제는 남는다 (§4.1h)" {
    const a = testing.allocator;
    var hints: Hints = .{};
    defer hints.deinit(a);
    for ([_]u32{ 5, 10, 12, 20 }) |off| try hints.items.append(a, .{ .offset = off, .text = try a.dupe(u8, "h") });
    // 앵커 5 에 2 byte 삽입 → 5 는 7 로, 뒤는 +2.
    shift(a, &hints, 5, 5, 7);
    try testing.expectEqual(@as(u32, 7), hints.items.items[0].offset);
    try testing.expectEqual(@as(u32, 12), hints.items.items[1].offset);
    try testing.expectEqual(@as(u32, 22), hints.items.items[3].offset);
    // [11, 15) 를 3 byte 로 교체 → 구간 안(12·14)은 버림, 뒤(22)는 -1.
    shift(a, &hints, 11, 15, 14);
    try testing.expectEqual(@as(usize, 2), hints.items.items.len);
    try testing.expectEqual(@as(u32, 7), hints.items.items[0].offset);
    try testing.expectEqual(@as(u32, 21), hints.items.items[1].offset);
    // 앵커 7 에서 시작하는 삭제 [7, 9) → 힌트 7 은 남고(앞 경계), 뒤는 -2.
    shift(a, &hints, 7, 9, 7);
    try testing.expectEqual(@as(u32, 7), hints.items.items[0].offset);
    try testing.expectEqual(@as(u32, 19), hints.items.items[1].offset);
    // 구간 끝 경계(`at == old_end`)는 「뒤」다 — 옮겨진다.
    shift(a, &hints, 3, 7, 5);
    try testing.expectEqual(@as(u32, 5), hints.items.items[0].offset);
}
