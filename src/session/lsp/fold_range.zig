//! `textDocument/foldingRange` 접힘 3층(docs/editor-surface-tooling.md §8.2j · native-editor-visual-mapping.md §4) — **순수** 계산 둘.
//!
//! ① `initialize` 응답의 `foldingRangeProvider`(bool 또는 객체) → 지원 여부.
//! ② 응답 배열 → 접힘 모델이 먹는 `Range` 목록: `startLine < endLine`(머리 한 줄짜리는 안 만든다 — §4.1f)·`endLine < 줄 수` 만 받고,
//!   `(startLine ↑, endLine ↓)` 로 정렬해 **같은 시작줄은 큰 것 하나**(tree-sitter 층 `best` 와 같은 규칙 — rust-analyzer 가 `let p = Point {`
//!   19..22 와 19..21 을 같이 낸다), **엇갈리는 것**(열린 범위 안에서 시작해 그 밖에서 끝남)은 버린다 — 접힘 모델은 중첩만 안다. 레벨은
//!   열린 범위 스택 깊이(구문 승격과 같은 정의). `kind`·`startCharacter`·`endCharacter`·`collapsedText` 는 안 읽는다(줄 접힘 · §8.2j 「종류」).
//!
//! `endLine` 은 서버의 것이다 — 명세가 *"folded area ends with the line's last character"* 라, rust-analyzer 는 닫는 괄호 줄을, tsgo·clangd 는
//! 그 앞 줄을 낸다(실측 2026-09-21). 정규화하지 않는다(`imports`·`comment` 처럼 괄호가 없는 범위에서 틀린다).
const std = @import("std");
const editor_fold = @import("../editor/fold.zig");

pub const Range = editor_fold.Range;

/// 한 응답에서 받는 범위 상한 — 넘치면 앞부분만(줄 수보다 많을 수 없으므로 실제로는 줄 수가 상한이다).
pub const max_ranges: usize = 50_000;

/// `initialize` 응답에 `foldingRangeProvider` 가 참(bool) 이거나 객체면 지원.
pub fn supportedFromResult(result: ?std.json.Value) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get("foldingRangeProvider") orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

const Raw = struct { start: u32, end: u32 };

fn lessRaw(_: void, a: Raw, b: Raw) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // 같은 시작이면 큰 것이 앞 — 아래 걸러내기가 「첫 것만」으로 끝난다
}

fn lineOf(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

/// 응답 `result`(`FoldingRange[]` 또는 `null`) → 정렬·검증된 `Range` 목록(소유 — 호출자가 `free`). `null`·배열 아님·빈 배열은 빈 목록.
/// **빈 목록은 「서버가 낸 것이 없다」**이고 「못 셌다」가 아니다 — 못 세는 것은 할당 실패로만 나온다(§4.1f 규율).
pub fn decode(allocator: std.mem.Allocator, result: ?std.json.Value, line_count: usize) error{OutOfMemory}![]Range {
    const r = result orelse return &.{};
    if (r != .array) return &.{};
    const items = r.array.items;
    if (items.len == 0 or line_count == 0) return &.{};

    var raw: std.ArrayList(Raw) = .empty;
    defer raw.deinit(allocator);
    for (items) |it| {
        if (it != .object) continue;
        const s = lineOf(it.object.get("startLine") orelse continue) orelse continue;
        const e = lineOf(it.object.get("endLine") orelse continue) orelse continue;
        if (s >= e) continue; // 머리 한 줄짜리(또는 뒤집힌 것)는 접어도 줄어드는 것이 없다
        if (e >= line_count) continue; // 낡은 문서의 범위 — 화면 밖을 가리킨다
        if (raw.items.len >= max_ranges) break;
        try raw.append(allocator, .{ .start = s, .end = e });
    }
    if (raw.items.len == 0) return &.{};
    std.mem.sort(Raw, raw.items, {}, lessRaw);

    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(allocator);
    var stack: [editor_fold.max_depth]u32 = undefined; // 열린 범위의 끝 줄
    var depth: usize = 0;
    var last_start: ?u32 = null;
    for (raw.items) |rr| {
        if (last_start != null and last_start.? == rr.start) continue; // 같은 시작줄 — 앞의 큰 것만
        while (depth > 0 and stack[depth - 1] < rr.start) depth -= 1;
        if (depth > 0 and rr.end > stack[depth - 1]) continue; // 엇갈림 — 열린 범위 밖에서 끝난다
        last_start = rr.start;
        if (depth < stack.len) {
            stack[depth] = rr.end;
            depth += 1;
        }
        try out.append(allocator, .{
            .head = rr.start,
            .first_hidden = rr.start + 1,
            .last_hidden = rr.end,
            .level = @intCast(@min(depth, std.math.maxInt(u16))),
        });
    }
    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "FRG1 foldingRange 응답 → 접힘 범위 — 정렬·같은 시작줄 큰 것·엇갈림 버림·한 줄·줄 수 밖·레벨·종류 무시 (§8.2j)" {
    const a = testing.allocator;
    // rust-analyzer 모양(중복)·tsgo 모양(문자 좌표)·엇갈림·한 줄·범위 밖·거꾸로·정수 아님을 한 응답에 섞는다.
    var p = try parse(a,
        \\[{"startLine":16,"endLine":26},
        \\ {"startLine":0,"endLine":1,"kind":"imports"},
        \\ {"startLine":19,"endLine":21},
        \\ {"startLine":19,"endLine":22},
        \\ {"startLine":23,"endLine":25},{"startLine":23,"endLine":25},
        \\ {"startLine":5,"startCharacter":11,"endLine":8,"endCharacter":1,"kind":"region"},
        \\ {"startLine":7,"endLine":12},
        \\ {"startLine":26,"endLine":30},
        \\ {"startLine":30,"endLine":30},
        \\ {"startLine":31,"endLine":40},
        \\ {"startLine":33,"endLine":32},
        \\ {"startLine":"3","endLine":4},
        \\ {"startLine":-1,"endLine":4},
        \\ {"endLine":4}]
    );
    defer p.deinit();
    const out = try decode(a, p.value, 40);
    defer a.free(out);
    // 기대: 0..1(L1) · 5..8(L1) · 16..26(L1) · 19..22(L2) · 23..25(L2). 7..12 는 5..8 안에서 시작해 밖에서 끝나 버림, **26..30 은 16..26 의
    // 마지막 숨은 줄에서 시작해 밖에서 끝나 버림**(적대적 A6: 열린 범위는 끝 줄까지 닫히지 않는다 — `<` 이지 `<=` 가 아니다), 30..30 한 줄,
    // 31..40 은 줄 수 40 밖(endLine 40 ≥ 40), 33..32 거꾸로, 문자열·음수·start 없음은 무시.
    try testing.expectEqual(@as(usize, 5), out.len);
    const exp = [_]struct { h: u32, l: u32, lv: u16 }{ .{ .h = 0, .l = 1, .lv = 1 }, .{ .h = 5, .l = 8, .lv = 1 }, .{ .h = 16, .l = 26, .lv = 1 }, .{ .h = 19, .l = 22, .lv = 2 }, .{ .h = 23, .l = 25, .lv = 2 } };
    for (exp, 0..) |e, i| {
        try testing.expectEqual(e.h, out[i].head);
        try testing.expectEqual(e.h + 1, out[i].first_hidden);
        try testing.expectEqual(e.l, out[i].last_hidden);
        try testing.expectEqual(e.lv, out[i].level);
    }

    // null·배열 아님·빈 배열·줄 수 0 → 빈 목록(할당 없음).
    try testing.expectEqual(@as(usize, 0), (try decode(a, null, 40)).len);
    var q = try parse(a, "{\"a\":1}");
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), (try decode(a, q.value, 40)).len);
    var e = try parse(a, "[]");
    defer e.deinit();
    try testing.expectEqual(@as(usize, 0), (try decode(a, e.value, 40)).len);
    try testing.expectEqual(@as(usize, 0), (try decode(a, p.value, 0)).len);

    // 줄 수가 범위를 자른다 — 같은 응답을 줄 20개로 읽으면 16..26·19..22·23..25 가 빠진다.
    const short = try decode(a, p.value, 20);
    defer a.free(short);
    try testing.expectEqual(@as(usize, 2), short.len);
    try testing.expectEqual(@as(u32, 5), short[1].head);
}

test "FRG2 foldingRangeProvider — bool·객체·거짓·없음·capabilities 없음 (§8.2j)" {
    const a = testing.allocator;
    var t = try parse(a, "{\"capabilities\":{\"foldingRangeProvider\":true}}");
    defer t.deinit();
    try testing.expect(supportedFromResult(t.value));
    var o = try parse(a, "{\"capabilities\":{\"foldingRangeProvider\":{\"workDoneProgress\":false}}}");
    defer o.deinit();
    try testing.expect(supportedFromResult(o.value));
    var f = try parse(a, "{\"capabilities\":{\"foldingRangeProvider\":false}}");
    defer f.deinit();
    try testing.expect(!supportedFromResult(f.value));
    var n = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer n.deinit();
    try testing.expect(!supportedFromResult(n.value));
    var c = try parse(a, "{\"serverInfo\":{}}");
    defer c.deinit();
    try testing.expect(!supportedFromResult(c.value));
    try testing.expect(!supportedFromResult(null));
}

test "FRG4 범위 상한 — 넘치면 앞부분만 (§8.2j; 적대적 A11)" {
    const a = testing.allocator;
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeByte('[');
    const n: u32 = max_ranges + 10;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try text.writer.writeByte(',');
        try text.writer.print("{{\"startLine\":{d},\"endLine\":{d}}}", .{ 2 * i, 2 * i + 1 });
    }
    try text.writer.writeByte(']');
    var p = try parse(a, text.written());
    defer p.deinit();
    const out = try decode(a, p.value, 2 * n + 1);
    defer a.free(out);
    try testing.expectEqual(max_ranges, out.len);
    try testing.expectEqual(@as(u32, 2 * (max_ranges - 1)), out[out.len - 1].head);
}

test "FRG3 깊이 상한을 넘는 중첩은 상한 레벨로 눌리고 목록에서 빠지지 않는다 (§8.2j)" {
    const a = testing.allocator;
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeByte('[');
    const n: u32 = editor_fold.max_depth + 4;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try text.writer.writeByte(',');
        try text.writer.print("{{\"startLine\":{d},\"endLine\":{d}}}", .{ i, 2 * n - i });
    }
    try text.writer.writeByte(']');
    var p = try parse(a, text.written());
    defer p.deinit();
    const out = try decode(a, p.value, 2 * n + 1);
    defer a.free(out);
    try testing.expectEqual(@as(usize, n), out.len);
    try testing.expectEqual(@as(u16, editor_fold.max_depth), out[n - 1].level);
    try testing.expectEqual(@as(u16, 1), out[0].level);
}
