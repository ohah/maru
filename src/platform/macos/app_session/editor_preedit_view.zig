//! A borrowed document view for IME painting. Only the affected logical lines are copied;
//! the saved document, its line index and its fold state remain canonical.
//! Pass an arena allocator: returned rows and intermediate annotation lists share its lifetime.
const std = @import("std");
const maru = @import("maru");
const ranges = maru.session.editor.text_input;
const index = maru.session.editor.line_index;
const view = maru.chrome.components.editor_view;

pub const Point = struct { row: usize, byte: usize };
pub const View = struct {
    lines: []const []const u8,
    starts: []const usize,
    sources: []const ?usize,
    numbers: []const ?u32,
    folds: []const view.gutter.Fold,
    replacement: ranges.ByteRange,
    inserted_len: usize,
    source_index: index.LineIndex,
    source_content: []const u8,
    total_lines: usize,

    pub fn forward(self: View, at: usize) usize {
        if (at <= self.replacement.start) return at;
        if (at < self.replacement.end) return self.replacement.start;
        return self.replacement.start + self.inserted_len + (at - self.replacement.end);
    }
    pub fn afterInsertion(self: View, at: usize) usize {
        if (at >= self.replacement.end) return self.replacement.start + self.inserted_len + (at - self.replacement.end);
        return self.forward(at);
    }
    pub fn backward(self: View, at: usize) usize {
        if (at <= self.replacement.start) return at;
        const end = self.replacement.start + self.inserted_len;
        if (at < end) return self.replacement.start;
        return self.replacement.end + (at - end);
    }
    pub fn point(self: View, at: usize) ?Point {
        var lo: usize = 0;
        var hi = self.starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= at) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const row = lo - 1;
        if (at > self.starts[row] + self.lines[row].len) return null; // hidden fold or newline interior
        return .{ .row = row, .byte = at - self.starts[row] };
    }
    pub fn sourcePoint(self: View, row: usize, byte: usize) usize {
        return self.backward(self.starts[row] + @min(byte, self.lines[row].len));
    }
    pub fn rowForSource(self: View, source: usize) usize {
        const line = self.source_index.line(source) orelse return 0;
        if (self.point(self.forward(line.start))) |p| return p.row;
        return 0;
    }

    /// Paint surviving canonical annotations as separate prefix/suffix pieces. No stale color
    /// or search match is allowed to cover the new marked text.
    pub fn surviving(self: View, a: usize, b: usize) [2]?ranges.ByteRange {
        var out: [2]?ranges.ByteRange = .{ null, null };
        if (a < @min(b, self.replacement.start)) out[0] = .{ .start = a, .end = @min(b, self.replacement.start) };
        if (@max(a, self.replacement.end) < b) out[1] = .{ .start = self.afterInsertion(@max(a, self.replacement.end)), .end = self.afterInsertion(b) };
        return out;
    }
};

pub fn build(allocator: std.mem.Allocator, content: []const u8, lines: index.LineIndex, visible_numbers: []const ?u32, folds: []const view.gutter.Fold, replacement: ranges.ByteRange, marked: []const u8) !View {
    if (replacement.start > replacement.end or replacement.end > content.len) return error.InvalidRange;
    const first = lines.lineAt(replacement.start);
    const last = lines.lineAt(replacement.end);
    const head = lines.line(first).?;
    const tail = lines.line(last).?;
    // Include complete boundary lines, including CRLF, so the existing line-index oracle
    // determines where new rows begin. Interior document lines are never copied.
    const prefix = content[head.start..replacement.start];
    const suffix = content[replacement.end..tail.end_with_ending];
    const joined = try allocator.alloc(u8, prefix.len + marked.len + suffix.len);
    @memcpy(joined[0..prefix.len], prefix);
    @memcpy(joined[prefix.len..][0..marked.len], marked);
    @memcpy(joined[prefix.len + marked.len ..], suffix);
    const joined_index = try index.build(allocator, joined);
    const joined_count = joined_index.lines.len - @as(usize, if (tail.ending == .none) 0 else 1);
    const axis_len = if (visible_numbers.len > 0) visible_numbers.len else lines.lines.len;
    var texts: std.ArrayList([]const u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var sources: std.ArrayList(?usize) = .empty;
    var numbers: std.ArrayList(?u32) = .empty;
    var fold_marks: std.ArrayList(view.gutter.Fold) = .empty;
    var inserted = false;
    const delta_lines: i64 = @as(i64, @intCast(joined_count)) - @as(i64, @intCast(last - first + 1));
    for (0..axis_len) |row| {
        const source = if (visible_numbers.len > 0) @as(usize, (visible_numbers[row] orelse continue) - 1) else row;
        if (source == first) {
            inserted = true;
            for (joined_index.lines[0..joined_count], 0..) |line, i| {
                try texts.append(allocator, joined[line.start..line.contentEnd()]);
                try starts.append(allocator, head.start + line.start);
                try sources.append(allocator, if (i == 0) first else if (i + 1 == joined_count) last else null);
                try numbers.append(allocator, @intCast(first + i + 1));
                try fold_marks.append(allocator, .none);
            }
        }
        if (source >= first and source <= last) continue;
        const line = lines.line(source) orelse continue;
        try texts.append(allocator, content[line.start..line.contentEnd()]);
        try starts.append(allocator, if (source < first) line.start else replacement.start + marked.len + (line.start - replacement.end));
        try sources.append(allocator, source);
        try numbers.append(allocator, @intCast(@as(i64, @intCast(source + 1)) + if (source > last) delta_lines else 0));
        try fold_marks.append(allocator, if (row < folds.len) folds[row] else .none);
    }
    if (!inserted) return error.HiddenComposition;
    return .{ .lines = texts.items, .starts = starts.items, .sources = sources.items, .numbers = numbers.items, .folds = fold_marks.items, .replacement = replacement, .inserted_len = marked.len, .source_index = lines, .source_content = content, .total_lines = @intCast(@as(i64, @intCast(lines.lines.len)) + delta_lines) };
}

test "IME_VIEW_MODEL1 multiline replacement preserves suffix and canonical offsets" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const content = "ab😀\r\nold\n끝cd\ntail";
    var idx = try index.build(a, content);
    defer idx.deinit();
    const projected = try build(arena.allocator(), content, idx, &.{}, &.{}, .{ .start = 2, .end = 15 }, "한\n나");
    try std.testing.expectEqualStrings("ab한", projected.lines[0]);
    try std.testing.expectEqualStrings("나cd", projected.lines[1]);
    try std.testing.expectEqualStrings("tail", projected.lines[2]);
    try std.testing.expectEqualDeep(Point{ .row = 1, .byte = 3 }, projected.point(9).?);
    try std.testing.expectEqual(@as(usize, 16), projected.sourcePoint(1, 4));
    try std.testing.expectEqualStrings(content, projected.source_content);
}

fn rowLists(comptime T: type, allocator: std.mem.Allocator, count: usize) ![]std.ArrayList(T) {
    const lists = try allocator.alloc(std.ArrayList(T), count);
    @memset(lists, .empty);
    return lists;
}
fn slices(comptime T: type, allocator: std.mem.Allocator, lists: []const std.ArrayList(T)) ![]const []const T {
    const rows = try allocator.alloc([]const T, lists.len);
    for (rows, lists) |*row, list| row.* = list.items;
    return rows;
}
fn sourceAt(numbers: []const ?u32, row: usize) ?usize {
    return if (numbers.len == 0) row else if (row < numbers.len) @as(usize, (numbers[row] orelse return null) - 1) else null;
}
fn addSpan(projected: View, allocator: std.mem.Allocator, lists: []std.ArrayList(view.frame.Mark), a: usize, b: usize) !void {
    if (a >= b) return;
    const first = projected.point(a) orelse return;
    const last = projected.point(b) orelse return;
    for (first.row..last.row + 1) |row| {
        const lo = if (row == first.row) first.byte else 0;
        const hi = if (row == last.row) last.byte else projected.lines[row].len;
        if (lo < hi) try lists[row].append(allocator, .{ .start = @intCast(lo), .len = @intCast(hi - lo) });
    }
}
pub fn marks(projected: View, allocator: std.mem.Allocator, numbers: []const ?u32, original: ?[]const []const view.frame.Mark, selected: ?ranges.ByteRange) ![]const []const view.frame.Mark {
    const lists = try rowLists(view.frame.Mark, allocator, projected.lines.len);
    if (original) |rows| for (rows, 0..) |row, i| {
        const source = sourceAt(numbers, i) orelse continue;
        const line = projected.source_index.line(source) orelse continue;
        for (row) |mark| for (projected.surviving(line.start + mark.start, line.start + mark.start + mark.len)) |piece| {
            if (piece) |p| try addSpan(projected, allocator, lists, p.start, p.end);
        };
    };
    if (selected) |s| try addSpan(projected, allocator, lists, s.start, s.end);
    for (lists) |*list| std.mem.sort(view.frame.Mark, list.items, {}, struct {
        fn less(_: void, a: view.frame.Mark, b: view.frame.Mark) bool {
            return a.start < b.start;
        }
    }.less);
    return slices(view.frame.Mark, allocator, lists);
}
pub fn carets(projected: View, allocator: std.mem.Allocator, offsets: []const usize) ![]const []const u32 {
    const lists = try rowLists(u32, allocator, projected.lines.len);
    for (offsets) |at| if (projected.point(at)) |p| try lists[p.row].append(allocator, @intCast(p.byte));
    for (lists) |*list| std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return slices(u32, allocator, lists);
}
fn columnWith(text: []const u8, tab: u8, byte: usize, hints: []const view.content.Inlay) u32 {
    const offsets = [_]u32{@intCast(byte)};
    var result: [1]u32 = undefined;
    view.content.columnsAtOffsetsWith(text, tab, &offsets, &result, std.math.maxInt(u32), hints);
    return result[0];
}
pub fn colors(projected: View, allocator: std.mem.Allocator, numbers: []const ?u32, original: []const []const view.content.ColorSpan, tab: u8, original_inlays: view.content.InlayWindow, projected_inlays: view.content.InlayWindow) ![]const []const view.content.ColorSpan {
    const lists = try rowLists(view.content.ColorSpan, allocator, projected.lines.len);
    for (original, 0..) |row, i| {
        const source = sourceAt(numbers, i) orelse continue;
        const line = projected.source_index.line(source) orelse continue;
        const text = projected.source_content[line.start..line.contentEnd()];
        if (source < projected.source_index.lineAt(projected.replacement.start) or source > projected.source_index.lineAt(projected.replacement.end)) {
            if (projected.point(projected.forward(line.start))) |p| try lists[p.row].appendSlice(allocator, row);
            continue;
        }
        for (row) |color| {
            const lo = view.content.byteAtPointWith(text, tab, 0, 0, 0, std.math.maxInt(u32), @intCast(@min(color.start_col, std.math.maxInt(i32) / 2) * 2), 2, original_inlays.at(i));
            const hi = view.content.byteAtPointWith(text, tab, 0, 0, 0, std.math.maxInt(u32), @intCast(@min(color.end_col, std.math.maxInt(i32) / 2) * 2), 2, original_inlays.at(i));
            for (projected.surviving(line.start + lo, line.start + hi)) |piece| if (piece) |p| {
                const start = projected.point(p.start) orelse continue;
                const end = projected.point(p.end) orelse continue;
                if (start.row != end.row) continue;
                try lists[start.row].append(allocator, .{ .start_col = columnWith(projected.lines[start.row], tab, start.byte, projected_inlays.at(start.row)), .end_col = columnWith(projected.lines[end.row], tab, end.byte, projected_inlays.at(end.row)), .role = color.role });
            };
        }
    }
    return slices(view.content.ColorSpan, allocator, lists);
}

pub fn inlays(projected: View, allocator: std.mem.Allocator, numbers: []const ?u32, original: view.content.InlayWindow) !view.content.InlayWindow {
    const lists = try rowLists(view.content.Inlay, allocator, projected.lines.len);
    for (original.rows, 0..) |row, i| {
        const source = sourceAt(numbers, original.first + i) orelse continue;
        const line = projected.source_index.line(source) orelse continue;
        for (row) |inlay| {
            const at = line.start + inlay.at;
            if (at >= projected.replacement.start and at < projected.replacement.end) continue;
            const p = projected.point(projected.afterInsertion(at)) orelse continue;
            try lists[p.row].append(allocator, .{ .at = @intCast(p.byte), .text = inlay.text });
        }
    }
    return .{ .rows = try slices(view.content.Inlay, allocator, lists), .generation = original.generation };
}

/// Row-only chrome (fold arrows, diagnostic markers and conflict widgets) follows its
/// surviving source line. Synthetic composition rows have no canonical annotation.
pub fn rowValues(comptime T: type, projected: View, allocator: std.mem.Allocator, numbers: []const ?u32, original: []const T, empty: T) ![]const T {
    const rows = try allocator.alloc(T, projected.lines.len);
    @memset(rows, empty);
    for (original, 0..) |value, i| {
        const source = sourceAt(numbers, i) orelse continue;
        const line = projected.source_index.line(source) orelse continue;
        if (line.start >= projected.replacement.start and line.start < projected.replacement.end) continue;
        if (projected.point(projected.forward(line.start))) |p| rows[p.row] = value;
    }
    return rows;
}

test "IME_VIEW_MODEL2 projected rows match a separate flattened line-index oracle including CRLF" {
    const a = std.testing.allocator;
    const source = "ab😀\r\nold\n끝cd\ntail";
    var idx = try index.build(a, source);
    defer idx.deinit();
    const boundaries = [_]usize{ 0, 1, 2, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 18, 19, 20, 21, 22 };
    for (boundaries, 0..) |start, i| for (boundaries[i..]) |end| for ([_][]const u8{ "한", "가\n나", "\r\n", "\r", "\n한\n", "😀\r\n끝" }) |marked| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        const projected = try build(allocator, source, idx, &.{}, &.{}, .{ .start = start, .end = end }, marked);
        const oracle = try std.mem.concat(allocator, u8, &.{ source[0..start], marked, source[end..] });
        const oracle_index = try index.build(allocator, oracle);
        try std.testing.expectEqual(oracle_index.lines.len, projected.lines.len);
        for (oracle_index.lines, projected.lines, projected.starts) |line, actual, at| {
            try std.testing.expectEqualStrings(oracle[line.start..line.contentEnd()], actual);
            try std.testing.expectEqual(line.start, at);
        }
    };
}

pub fn taggedMarks(comptime T: type, projected: View, allocator: std.mem.Allocator, numbers: []const ?u32, original: []const []const T) ![]const []const T {
    const lists = try rowLists(T, allocator, projected.lines.len);
    for (original, 0..) |row, i| {
        const source = sourceAt(numbers, i) orelse continue;
        const line = projected.source_index.line(source) orelse continue;
        for (row) |mark| for (projected.surviving(line.start + mark.start, line.start + mark.start + mark.len)) |piece| if (piece) |p| {
            const start = projected.point(p.start) orelse continue;
            const end = projected.point(p.end) orelse continue;
            if (start.row != end.row) continue;
            var mapped = mark;
            mapped.start = @intCast(start.byte);
            mapped.len = @intCast(end.byte - start.byte);
            try lists[start.row].append(allocator, mapped);
        };
    }
    return slices(T, allocator, lists);
}
pub fn sourceVisible(projected: View, numbers: []const ?u32, row: usize) ?usize {
    const source = sourceAt(numbers, row) orelse return null;
    const line = projected.source_index.line(source) orelse return null;
    if (line.start >= projected.replacement.start and line.start < projected.replacement.end) return null;
    return if (projected.point(projected.forward(line.start))) |p| p.row else null;
}

test "IME_VIEW_MODEL3 folds annotations and hints retain surviving bytes" {
    const a = std.testing.allocator;
    const source = "abXXcd\nhidden\nfold\ntail";
    var idx = try index.build(a, source);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const numbers = [_]?u32{ 1, 3, 4 };
    const folded = [_]view.gutter.Fold{ .none, .collapsed, .none };
    const v = try build(allocator, source, idx, &numbers, &folded, .{ .start = 2, .end = 4 }, "한\n나");
    try std.testing.expectEqual(@as(usize, 5), v.total_lines);
    try std.testing.expectEqualStrings("ab한", v.lines[0]);
    try std.testing.expectEqualStrings("나cd", v.lines[1]);
    try std.testing.expectEqualStrings("fold", v.lines[2]);
    try std.testing.expectEqual(@as(?u32, 4), v.numbers[2]);
    try std.testing.expectEqual(view.gutter.Fold.collapsed, v.folds[2]);
    const originals = [_][]const view.frame.Mark{ &.{.{ .start = 0, .len = 6 }}, &.{}, &.{} };
    const mapped = try marks(v, allocator, &numbers, &originals, .{ .start = 2, .end = 9 });
    // The source prefix and suffix survive, and marked selection occupies the new rows.
    try std.testing.expectEqual(@as(usize, 2), mapped[0].len);
    try std.testing.expectEqual(view.frame.Mark{ .start = 0, .len = 2 }, mapped[0][0]);
    try std.testing.expectEqual(view.frame.Mark{ .start = 2, .len = 3 }, mapped[0][1]);
    try std.testing.expectEqual(@as(usize, 2), mapped[1].len);
    const original_hints = view.content.InlayWindow{ .rows = &.{&.{ .{ .at = 1, .text = "p" }, .{ .at = 3, .text = "removed" }, .{ .at = 5, .text = "s" } }} };
    const hints = try inlays(v, allocator, &numbers, original_hints);
    try std.testing.expectEqual(@as(usize, 1), hints.at(0).len);
    try std.testing.expectEqual(@as(u32, 1), hints.at(0)[0].at);
    try std.testing.expectEqual(@as(usize, 1), hints.at(1).len);
    try std.testing.expectEqual(@as(u32, 4), hints.at(1)[0].at);
}

test "IME_VIEW_MODEL4 insertion affinity does not paint source annotations over marked bytes" {
    const a = std.testing.allocator;
    var idx = try index.build(a, "ab");
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const v = try build(allocator, "ab", idx, &.{}, &.{}, .{ .start = 1, .end = 1 }, "한\n나");
    const original = [_][]const view.frame.Mark{&.{.{ .start = 0, .len = 2 }}};
    const mapped = try marks(v, allocator, &.{}, &original, null);
    try std.testing.expectEqual(view.frame.Mark{ .start = 0, .len = 1 }, mapped[0][0]);
    try std.testing.expectEqual(view.frame.Mark{ .start = 3, .len = 1 }, mapped[1][0]);
    const hints = try inlays(v, allocator, &.{}, .{ .rows = &.{&.{.{ .at = 1, .text = "old" }}} });
    try std.testing.expectEqual(@as(usize, 0), hints.at(0).len);
    try std.testing.expectEqual(@as(u32, 3), hints.at(1)[0].at);
    const original_colors = [_][]const view.content.ColorSpan{&.{.{ .start_col = 0, .end_col = 2, .role = .surface_fg }}};
    const mapped_colors = try colors(v, allocator, &.{}, &original_colors, 4, .{}, .{});
    try std.testing.expectEqual(view.content.ColorSpan{ .start_col = 0, .end_col = 1, .role = .surface_fg }, mapped_colors[0][0]);
    try std.testing.expectEqual(view.content.ColorSpan{ .start_col = 2, .end_col = 3, .role = .surface_fg }, mapped_colors[1][0]);
}
