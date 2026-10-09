//! 선택한 원문 범위의 바꾸기 계획. 파일 쓰기·Undo·문서 포인터를 소유하지 않는다.
const std = @import("std");
const find = @import("../find.zig");
const lines = @import("../line_index.zig");
const diff = @import("../diff.zig");
const query = @import("query.zig");
const event = @import("event.zig");
const delta = @import("../delta.zig");
/// 대체 문자열은 after 안의 범위로 식별한다. output 성장 중의 포인터를 보관하지 않는다.
pub const Edit = struct { start: usize, end: usize, after_start: usize, after_end: usize };
pub const Row = struct { kind: diff.RowKind, line: u32, text: []const u8, context_start: usize = 0 };
pub const Plan = struct {
    before: []u8,
    after: []u8,
    rows: std.ArrayList(Row) = .empty,
    replacements: usize,
    edits: std.ArrayList(Edit) = .empty,
    /// 반환 배열만 호출자가 소유하고 text는 Plan.after를 빌린다. 실제 적용이 끝날 때까지 Plan을 보존한다.
    pub fn changes(self: *const Plan, a: std.mem.Allocator) ![]delta.Change {
        const result = try a.alloc(delta.Change, self.edits.items.len);
        for (result, self.edits.items) |*change, edit| change.* = .{ .start = edit.start, .end = edit.end, .text = self.after[edit.after_start..edit.after_end] };
        return result;
    }
    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        self.edits.deinit(a);
        self.rows.deinit(a);
        a.free(self.before);
        a.free(self.after);
    }
};
fn offset(index: lines.LineIndex, text: []const u8, pos: event.Position) !usize {
    const line = index.line(pos.line) orelse return error.StaleMatch;
    if (pos.byte > line.end_with_ending - line.start) return error.StaleMatch;
    const at = line.start + pos.byte;
    if (at < text.len and text[at] & 0xc0 == 0x80) return error.StaleMatch;
    return at;
}
fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, limit: usize) !void {
    if (text.len > limit -| out.items.len) return error.TooLarge;
    try out.appendSlice(a, text);
}
/// 좌표가 맞더라도 다른 엔진의 캡처를 추측하지 않는다. 정규식은 같은 전문을 순회해 범위를 재현한다.
pub fn prepare(a: std.mem.Allocator, original: []const u8, needle: []const u8, replacement: []const u8, opts: query.Options, ranges: []const event.Range, limit: usize, cancelled: *const std.atomic.Value(bool)) !Plan {
    if (original.len > limit) return error.TooLarge;
    if (needle.len == 0 or !std.unicode.utf8ValidateSlice(original) or !std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
    const before = try a.dupe(u8, original);
    errdefer a.free(before);
    var index = try lines.build(a, before);
    defer index.deinit();
    var pattern: ?find.regex.Pattern = if (opts.regex) try find.regex.Pattern.initDocument(needle, opts.match_case, .anycrlf) else null;
    defer if (pattern) |*p| p.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    var copied: usize = 0;
    var previous: ?find.regex.Span = null;
    var scan: usize = 0;
    for (ranges) |range| {
        if (cancelled.load(.acquire)) return error.Cancelled;
        const lo = try offset(index, before, range.start);
        const hi = try offset(index, before, range.end);
        if (lo < copied or hi < lo or (if (previous) |span| span.start == lo and span.end == hi else false)) return error.StaleMatch;
        previous = .{ .start = lo, .end = hi };
        var expanded: ?[]u8 = null;
        defer if (expanded) |bytes| a.free(bytes);
        if (pattern) |*p| {
            while (scan <= before.len) {
                if (cancelled.load(.acquire)) return error.Cancelled;
                const from = scan;
                const found = (try p.matchValidated(before, from, false)) orelse return error.StaleMatch;
                scan = if (found.end == before.len) before.len + 1 else if (found.end > found.start) found.end else found.end + try std.unicode.utf8ByteSequenceLength(before[found.end]);
                if (opts.whole_word and !find.isWholeWord(before, found.start, found.end)) continue;
                if (found.start < lo) continue;
                if (found.start != lo or found.end != hi) return error.StaleMatch;
                expanded = try p.expandFromValidated(a, before, found, replacement, from);
                break;
            }
            if (expanded == null) return error.StaleMatch;
        } else {
            // 평문도 화면에 있던 위치의 원문이 실제 검색 규칙을 만족해야 한다.
            var from = lo;
            const found = (try find.nextLiteralBatch(before, needle, .{ .match_case = opts.match_case, .whole_word = opts.whole_word }, &from, before.len +| 1, cancelled)) orelse return error.StaleMatch;
            if (found.start != lo or found.end != hi) return error.StaleMatch;
        }
        try append(a, &output, before[copied..lo], limit);
        const after_start = output.items.len;
        try append(a, &output, expanded orelse replacement, limit);
        if (!std.mem.eql(u8, before[lo..hi], expanded orelse replacement))
            try edits.append(a, .{ .start = lo, .end = hi, .after_start = after_start, .after_end = output.items.len });
        copied = hi;
    }
    try append(a, &output, before[copied..], limit);
    const after = try output.toOwnedSlice(a);
    errdefer a.free(after);
    var plan: Plan = .{ .before = before, .after = after, .replacements = ranges.len, .edits = edits };
    edits = .empty;
    errdefer plan.edits.deinit(a);
    errdefer plan.rows.deinit(a);
    var right = try lines.build(a, after);
    defer right.deinit();
    const left_text = try a.alloc([]const u8, index.lineCount());
    defer a.free(left_text);
    const right_text = try a.alloc([]const u8, right.lineCount());
    defer a.free(right_text);
    for (left_text, 0..) |*text, i| {
        const line = index.line(i).?;
        text.* = before[line.start..line.end_with_ending];
    }
    for (right_text, 0..) |*text, i| {
        const line = right.line(i).?;
        text.* = after[line.start..line.end_with_ending];
    }
    var view = try diff.compute(a, left_text, right_text, .{});
    defer if (view == .compare) view.compare.deinit(a);
    if (view == .unchanged) {
        plan.edits.clearRetainingCapacity();
        return plan;
    }
    if (view != .compare) return error.DiffTooLarge;
    // unified 표시도 기존 줄 대응을 소비한다. 전문은 Plan이 보관하므로 row는 안전하게 빌린다.
    for (view.compare.left, view.compare.right) |left, added| {
        if (cancelled.load(.acquire)) return error.Cancelled;
        var prefix: usize = 0;
        if (left.kind == .removed and added.kind == .added) while (prefix < @min(left.text.len, added.text.len) and left.text[prefix] == added.text[prefix]) : (prefix += 1) {
            if (prefix & 0x3fff == 0 and cancelled.load(.acquire)) return error.Cancelled;
        };
        var left_start = if (left.kind == .removed) prefix -| 64 else 0;
        var right_start = if (added.kind == .added) prefix -| 64 else 0;
        while (left_start > 0 and left_start < left.text.len and left.text[left_start] & 0xc0 == 0x80) left_start -= 1;
        while (right_start > 0 and right_start < added.text.len and added.text[right_start] & 0xc0 == 0x80) right_start -= 1;
        if (left.kind != .filler) try plan.rows.append(a, .{ .kind = left.kind, .line = left.line.?, .text = left.text, .context_start = left_start });
        if (added.kind == .added) try plan.rows.append(a, .{ .kind = .added, .line = added.line.?, .text = added.text, .context_start = right_start });
    }
    return plan;
}

test "project replace preview preserves raw newlines and expands selected multiline captures" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    var plan = try prepare(a, "foo\r\nbar\nfoo", "(foo)(\\r\\nbar)?", "$2:$1", .{ .regex = true, .match_case = true }, &.{.{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 1, .byte = 3 } }}, 1024, &stop);
    defer plan.deinit(a);
    try std.testing.expectEqualStrings("\r\nbar:foo\nfoo", plan.after);
    try std.testing.expectEqualStrings("foo\r\nbar\nfoo", plan.before);
}
test "project replace preview rejects changed ranges cancellation and oversized expansion" {
    const stop = std.atomic.Value(bool).init(false);
    const range: event.Range = .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } };
    try std.testing.expectError(error.StaleMatch, prepare(std.testing.allocator, "bar", "foo", "x", .{}, &.{range}, 10, &stop));
    try std.testing.expectError(error.TooLarge, prepare(std.testing.allocator, "foo", "foo", "longer", .{}, &.{range}, 3, &stop));
    const cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, prepare(std.testing.allocator, "foo", "foo", "x", .{}, &.{range}, 10, &cancelled));
}
fn allocationCase(a: std.mem.Allocator) !void {
    const stop = std.atomic.Value(bool).init(false);
    var plan = try prepare(a, "foo\nfoo", "(foo)", "$1x", .{ .regex = true }, &.{ .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } }, .{ .start = .{ .line = 1, .byte = 0 }, .end = .{ .line = 1, .byte = 3 } } }, 100, &stop);
    defer plan.deinit(a);
    try std.testing.expectEqualStrings("foox\nfoox", plan.after);
    const changes = try plan.changes(a);
    defer a.free(changes);
    try std.testing.expectEqual(@as(usize, 2), changes.len);
}
test "project replace preview releases every failed preparation allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "project replace preview replays skipped regex context empty spans and Unicode byte widths" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    const cases = [_]struct { text: []const u8, query: []const u8, replace: []const u8, lo: u32, hi: u32, expected: []const u8, regex: bool = true }{
        .{ .text = "foo bar", .query = "foo \\K(bar)", .replace = "$1$1", .lo = 4, .hi = 7, .expected = "foo barbar" },
        .{ .text = "foofoo", .query = "\\Gfoo", .replace = "X", .lo = 3, .hi = 6, .expected = "fooX" },
        .{ .text = "foobar", .query = "(?<=foo)bar", .replace = "X", .lo = 3, .hi = 6, .expected = "fooX" },
        .{ .text = "A", .query = "(?:)", .replace = "_", .lo = 1, .hi = 1, .expected = "A_" },
        .{ .text = "K", .query = "k", .replace = "x", .lo = 0, .hi = 3, .expected = "x", .regex = false },
    };
    for (cases) |case| {
        var plan = try prepare(a, case.text, case.query, case.replace, .{ .regex = case.regex }, &.{.{ .start = .{ .line = 0, .byte = case.lo }, .end = .{ .line = 0, .byte = case.hi } }}, 100, &stop);
        defer plan.deinit(a);
        try std.testing.expectEqualStrings(case.expected, plan.after);
    }
    const long = try a.alloc(u8, 10003);
    defer a.free(long);
    @memset(long[0..10000], 'a');
    @memcpy(long[10000..], "foo");
    var excerpt = try prepare(a, long, "foo", "bar", .{ .match_case = true }, &.{.{ .start = .{ .line = 0, .byte = 10000 }, .end = .{ .line = 0, .byte = 10003 } }}, 20000, &stop);
    defer excerpt.deinit(a);
    try std.testing.expect(excerpt.rows.items[0].context_start > 0);
    const shown = excerpt.rows.items[0].text[excerpt.rows.items[0].context_start..];
    try std.testing.expect((std.mem.indexOf(u8, shown, "foo") orelse return error.MissingChangedContext) < 256);
    const empty: event.Range = .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 0 } };
    try std.testing.expectError(error.StaleMatch, prepare(a, "A", "(?:)", "_", .{ .regex = true }, &.{ empty, empty }, 100, &stop));
    const split: event.Range = .{ .start = .{ .line = 0, .byte = 1 }, .end = .{ .line = 0, .byte = 3 } };
    try std.testing.expectError(error.StaleMatch, prepare(a, "가", "가", "x", .{}, &.{split}, 100, &stop));
}

/// 미리보기 문자열 조립과 별개인 실제 문서 편집 엔진으로 정방향·역방향을 대조한다.
fn verifyChanges(a: std.mem.Allocator, plan: *const Plan) !void {
    const changes = try plan.changes(a);
    defer a.free(changes);
    try std.testing.expect((delta.Delta{ .changes = changes }).isWellFormed());
    var doc = try @import("../edit_doc.zig").EditableFile.initContent(a, plan.before, false);
    defer doc.deinit();
    const selection = @import("../selection.zig");
    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = selection.Selections.init(&items, 0);
    var inverse = try doc.apply(.{ .changes = changes }, &sels);
    defer inverse.deinit();
    try std.testing.expectEqualStrings(plan.after, doc.content);
    var redo = try doc.apply(inverse.delta(), &sels);
    defer redo.deinit();
    try std.testing.expectEqualStrings(plan.before, doc.content);
}
test "project replace preview compact edits apply and undo raw multiline capture deletion and empty matches" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    const cases = [_]struct { original: []const u8, needle: []const u8, replacement: []const u8, regex: bool, ranges: []const event.Range }{
        .{ .original = "α\r\nfoo\nβfoo", .needle = "(foo)", .replacement = "$1$1", .regex = true, .ranges = &.{ .{ .start = .{ .line = 1, .byte = 0 }, .end = .{ .line = 1, .byte = 3 } }, .{ .start = .{ .line = 2, .byte = 2 }, .end = .{ .line = 2, .byte = 5 } } } },
        .{ .original = "foo bar foo", .needle = "foo", .replacement = "", .regex = false, .ranges = &.{ .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } }, .{ .start = .{ .line = 0, .byte = 8 }, .end = .{ .line = 0, .byte = 11 } } } },
        .{ .original = "A", .needle = "(?:)", .replacement = "_", .regex = true, .ranges = &.{ .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 0 } }, .{ .start = .{ .line = 0, .byte = 1 }, .end = .{ .line = 0, .byte = 1 } } } },
        .{ .original = "foofoo", .needle = "\\Gfoo", .replacement = "X", .regex = true, .ranges = &.{.{ .start = .{ .line = 0, .byte = 3 }, .end = .{ .line = 0, .byte = 6 } }} },
    };
    for (cases) |case| {
        var plan = try prepare(a, case.original, case.needle, case.replacement, .{ .regex = case.regex }, case.ranges, 1024, &stop);
        defer plan.deinit(a);
        try verifyChanges(a, &plan);
        try std.testing.expectEqual(case.ranges.len, plan.edits.items.len);
    }
}
test "project replace preview single match retains only its range and replacement in the edit list" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    const original = "prefix unchanged foo suffix unchanged";
    var plan = try prepare(a, original, "foo", "X", .{}, &.{.{ .start = .{ .line = 0, .byte = 17 }, .end = .{ .line = 0, .byte = 20 } }}, 1024, &stop);
    defer plan.deinit(a);
    const changes = try plan.changes(a);
    defer a.free(changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(@as(usize, 3), changes[0].removedLen());
    try std.testing.expectEqualStrings("X", changes[0].text);
    try std.testing.expect(changes[0].text.ptr == plan.after.ptr + plan.edits.items[0].after_start);
    try verifyChanges(a, &plan);
}

test "project replace preview identical replacements do not create mutation entries" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    var plan = try prepare(a, "foo", "foo", "foo", .{}, &.{.{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } }}, 1024, &stop);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), plan.edits.items.len);
    try std.testing.expectEqualStrings(plan.before, plan.after);
}

test "project replace preview randomized subsets match an independent string oracle and inverse" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    var random = std.Random.DefaultPrng.init(0x4266a11);
    const replacements = [_][]const u8{ "X", "", "한\r\n글", "foo", "$literal" };
    for (0..256) |_| {
        var original: std.ArrayList(u8) = .empty;
        defer original.deinit(a);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(a);
        const replacement = replacements[random.random().uintLessThan(usize, replacements.len)];
        for (0..1 + random.random().uintLessThan(usize, 32)) |_| {
            const prefix: []const u8 = if (random.random().boolean()) "🙂\r\n" else "한 ";
            try original.appendSlice(a, prefix);
            try expected.appendSlice(a, prefix);
            if (random.random().boolean()) {
                try starts.append(a, original.items.len);
                try expected.appendSlice(a, replacement);
            } else try expected.appendSlice(a, "foo");
            try original.appendSlice(a, "foo");
        }
        var index = try lines.build(a, original.items);
        defer index.deinit();
        const ranges = try a.alloc(event.Range, starts.items.len);
        defer a.free(ranges);
        for (ranges, starts.items) |*range, start| {
            const line = index.lineAt(start);
            const byte: u32 = @intCast(start - index.line(line).?.start);
            range.* = .{ .start = .{ .line = @intCast(line), .byte = byte }, .end = .{ .line = @intCast(line), .byte = byte + 3 } };
        }
        var plan = try prepare(a, original.items, "foo", replacement, .{ .match_case = true }, ranges, 8192, &stop);
        defer plan.deinit(a);
        try std.testing.expectEqualStrings(expected.items, plan.after);
        try verifyChanges(a, &plan);
    }
}

test "project replace preview cancelling capture replacements do not create a net edit" {
    const a = std.testing.allocator;
    const stop = std.atomic.Value(bool).init(false);
    var plan = try prepare(a, "aa", "((?<=a)a|)a?", "$1$1", .{ .regex = true }, &.{
        .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 1 } },
        .{ .start = .{ .line = 0, .byte = 1 }, .end = .{ .line = 0, .byte = 2 } },
    }, 1024, &stop);
    defer plan.deinit(a);
    try std.testing.expectEqualStrings("aa", plan.after);
    try std.testing.expectEqual(@as(usize, 0), plan.edits.items.len);
    try verifyChanges(a, &plan);
}
