//! 비동기 분석 중 보여 줄 값만 보존한다. 트리·캡처 이름·문서 포인터는 보관하지 않는다.
const std = @import("std");
const request = @import("session/editor/syntax/request/gate.zig");
const colors = @import("chrome/components/editor_view/syntax_colors.zig");
pub const Edit = struct { start: u32, old_end: u32, new_end: u32 };
pub const Range = struct { start: u32, end: u32 };

pub const Cache = struct {
    input: ?request.Input = null,
    length: u32 = 0,
    coverage: Range = .{ .start = 0, .end = 0 },

    pub fn clear(self: *Cache, spans: *std.ArrayList(colors.ByteSpan)) void {
        self.* = .{};
        spans.clearRetainingCapacity();
    }

    /// 질의 밖으로 뻗은 상위 캡처를 잘라야 스크롤한 새 영역에 미확인 색을 쓰지 않는다.
    pub fn remember(self: *Cache, input: request.Input, length: u32, coverage: Range, spans: *std.ArrayList(colors.ByteSpan)) void {
        self.* = .{};
        if (coverage.start > coverage.end or coverage.end > length) {
            spans.clearRetainingCapacity();
            return;
        }
        var count: usize = 0;
        for (spans.items) |sp| {
            const start = @max(sp.start, coverage.start);
            const end = @min(sp.end, coverage.end);
            if (start >= end) continue;
            spans.items[count] = .{ .start = start, .end = end, .role = sp.role };
            count += 1;
        }
        spans.items.len = count;
        self.* = .{ .input = input, .length = length, .coverage = coverage };
    }

    pub fn matches(self: Cache, input: request.Input, length: usize) bool {
        return self.input != null and std.meta.eql(self.input.?, input) and self.length == length;
    }

    /// 할당 없이 현재 편집으로 옮긴다. 신원이나 편집 길이를 증명할 수 없으면 표시만 버린다.
    pub fn advance(self: *Cache, previous: ?request.Input, next: request.Input, edit: ?Edit, length: usize, spans: *std.ArrayList(colors.ByteSpan)) void {
        const old = previous orelse return self.clear(spans);
        const change = edit orelse return self.clear(spans);
        if (!self.matches(old, self.length) or !std.meta.eql(old.document, next.document) or
            !std.meta.eql(old.grammar, next.grammar) or next.revision <= old.revision or
            change.start > change.old_end or change.start > change.new_end or change.old_end > self.length or
            @as(u64, self.length) -| (change.old_end -| change.start) + (change.new_end -| change.start) != length or
            length > std.math.maxInt(u32)) return self.clear(spans);
        var count: usize = 0;
        for (spans.items) |sp| {
            const start = deleted(sp.start, change);
            const end = deleted(sp.end, change);
            // 통째로 지운 토큰의 색을 새 본문에 발명하지 않는다.
            if (start >= end) continue;
            const shifted_start = inserted(start, change, start != 0);
            const shifted_end = inserted(end, change, true);
            spans.items[count] = .{ .start = shifted_start, .end = shifted_end, .role = sp.role };
            count += 1;
        }
        spans.items.len = count;
        self.coverage = .{
            .start = inserted(deleted(self.coverage.start, change), change, false),
            .end = inserted(deleted(self.coverage.end, change), change, true),
        };
        self.input = next;
        self.length = @intCast(length);
    }
};

fn deleted(position: u32, edit: Edit) u32 {
    if (position <= edit.start) return position;
    if (position < edit.old_end) return edit.start;
    return position - (edit.old_end - edit.start);
}
fn inserted(position: u32, edit: Edit, right: bool) u32 {
    return if (position > edit.start or (right and position == edit.start)) position + (edit.new_end - edit.start) else position;
}

const testing = std.testing;
const seed: request.Input = .{ .document = .{ .owner = 1, .slot = 2, .generation = 3 }, .revision = 4, .grammar = .{ .identity = 5, .generation = 6 } };
fn successor() request.Input {
    var next = seed;
    next.revision += 1;
    return next;
}

test "syntax paint 삽입 삭제 경계와 할당 없는 보정" {
    // 경계·중간·범위 밖 편집을 서로 다른 역할 두 개로 비교한다.
    const Case = struct { edit: Edit, length: u32, expected: [2]Range };
    const cases = [_]Case{
        .{ .edit = .{ .start = 0, .old_end = 0, .new_end = 3 }, .length = 15, .expected = .{ .{ .start = 0, .end = 7 }, .{ .start = 9, .end = 13 } } },
        .{ .edit = .{ .start = 2, .old_end = 2, .new_end = 5 }, .length = 15, .expected = .{ .{ .start = 0, .end = 7 }, .{ .start = 9, .end = 13 } } },
        .{ .edit = .{ .start = 4, .old_end = 4, .new_end = 6 }, .length = 14, .expected = .{ .{ .start = 0, .end = 6 }, .{ .start = 8, .end = 12 } } },
        .{ .edit = .{ .start = 6, .old_end = 6, .new_end = 8 }, .length = 14, .expected = .{ .{ .start = 0, .end = 4 }, .{ .start = 8, .end = 12 } } },
        .{ .edit = .{ .start = 12, .old_end = 12, .new_end = 14 }, .length = 14, .expected = .{ .{ .start = 0, .end = 4 }, .{ .start = 6, .end = 10 } } },
        .{ .edit = .{ .start = 1, .old_end = 3, .new_end = 1 }, .length = 10, .expected = .{ .{ .start = 0, .end = 2 }, .{ .start = 4, .end = 8 } } },
        .{ .edit = .{ .start = 3, .old_end = 7, .new_end = 3 }, .length = 8, .expected = .{ .{ .start = 0, .end = 3 }, .{ .start = 3, .end = 6 } } },
        .{ .edit = .{ .start = 1, .old_end = 3, .new_end = 5 }, .length = 14, .expected = .{ .{ .start = 0, .end = 6 }, .{ .start = 8, .end = 12 } } },
    };
    for (cases) |case| {
        var spans: std.ArrayList(colors.ByteSpan) = .empty;
        defer spans.deinit(testing.allocator);
        try spans.appendSlice(testing.allocator, &.{ .{ .start = 0, .end = 4, .role = .syntax_keyword }, .{ .start = 6, .end = 10, .role = .syntax_string } });
        const pointer = spans.items.ptr;
        const capacity = spans.capacity;
        var cache: Cache = .{};
        cache.remember(seed, 12, .{ .start = 0, .end = 12 }, &spans);
        cache.advance(seed, successor(), case.edit, case.length, &spans);
        try testing.expect(cache.matches(successor(), case.length));
        try testing.expectEqual(@as(usize, 2), spans.items.len);
        for (spans.items, case.expected) |actual, expected| {
            try testing.expectEqual(expected.start, actual.start);
            try testing.expectEqual(expected.end, actual.end);
        }
        try testing.expectEqual(colors.ByteSpan{ .start = case.expected[1].start, .end = case.expected[1].end, .role = .syntax_string }, spans.items[1]);
        try testing.expectEqual(pointer, spans.items.ptr);
        try testing.expectEqual(capacity, spans.capacity);
    }
}

test "syntax paint 신원 길이 편집 증명 없이는 버린다" {
    for (0..12) |fault| {
        var spans: std.ArrayList(colors.ByteSpan) = .empty;
        defer spans.deinit(testing.allocator);
        try spans.append(testing.allocator, .{ .start = 0, .end = 4, .role = .syntax_keyword });
        var cache: Cache = .{};
        cache.remember(seed, 12, .{ .start = 0, .end = 12 }, &spans);
        var previous: ?request.Input = seed;
        var next = successor();
        var edit: ?Edit = .{ .start = 2, .old_end = 2, .new_end = 3 };
        var length: usize = 13;
        switch (fault) {
            0 => previous = null,
            1 => edit = null,
            2 => next.document.owner += 1,
            3 => next.document.slot += 1,
            4 => next.document.generation += 1,
            5 => next.grammar.identity += 1,
            6 => next.grammar.generation += 1,
            7 => next.revision = seed.revision,
            8 => length = 14,
            9 => edit.?.old_end = 13,
            10 => edit.?.new_end = 1,
            11 => previous.?.revision -= 1,
            else => unreachable,
        }
        cache.advance(previous, next, edit, length, &spans);
        try testing.expect(cache.input == null);
        try testing.expectEqual(@as(usize, 0), spans.items.len);
    }
}

test "syntax paint 뷰 범위 밖 캡처와 전체 치환은 남기지 않는다" {
    var spans: std.ArrayList(colors.ByteSpan) = .empty;
    defer spans.deinit(testing.allocator);
    try spans.appendSlice(testing.allocator, &.{ .{ .start = 0, .end = 12, .role = .syntax_comment }, .{ .start = 4, .end = 6, .role = .syntax_string } });
    var cache: Cache = .{};
    cache.remember(seed, 12, .{ .start = 3, .end = 8 }, &spans);
    try testing.expectEqual(@as(u32, 3), spans.items[0].start);
    try testing.expectEqual(@as(u32, 8), spans.items[0].end);
    cache.advance(seed, successor(), .{ .start = 0, .old_end = 12, .new_end = 7 }, 7, &spans);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expect(cache.matches(successor(), 7));
}

test "syntax paint 한글 CRLF 연속 편집과 새 결과 교체" {
    const original = "const 한 = 1;\r\n";
    var spans: std.ArrayList(colors.ByteSpan) = .empty;
    defer spans.deinit(testing.allocator);
    try spans.append(testing.allocator, .{ .start = 6, .end = 9, .role = .syntax_string });
    var cache: Cache = .{};
    cache.remember(seed, original.len, .{ .start = 0, .end = original.len }, &spans);
    var previous = seed;
    for (0..100) |i| {
        var next = previous;
        next.revision += 1;
        cache.advance(previous, next, .{ .start = 0, .old_end = 0, .new_end = 3 }, original.len + (i + 1) * 3, &spans);
        try testing.expectEqual(@as(u32, @intCast(6 + (i + 1) * 3)), spans.items[0].start);
        previous = next;
    }
    cache.clear(&spans);
    try spans.append(testing.allocator, .{ .start = 1, .end = 2, .role = .syntax_number });
    cache.remember(previous, 4, .{ .start = 0, .end = 4 }, &spans);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(.syntax_number, spans.items[0].role);
}
