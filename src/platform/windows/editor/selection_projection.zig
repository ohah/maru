//! Paint borrows these reusable buffers only during frame construction. Row
//! indices are document indices, even when the viewport starts below line zero.
const std = @import("std");
const maru = @import("maru");
const editor = maru.session.editor;
const frame = maru.chrome.components.editor_view.frame;

pub const Projection = struct {
    marks: std.ArrayList(frame.Mark) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    mark_rows: std.ArrayList([]const frame.Mark) = .empty,
    caret_rows: std.ArrayList([]const u32) = .empty,
    touched_carets: std.ArrayList(usize) = .empty,
    mark_first: usize = 0,
    mark_count: usize = 0,

    pub fn deinit(self: *Projection, a: std.mem.Allocator) void {
        self.marks.deinit(a);
        self.offsets.deinit(a);
        self.mark_rows.deinit(a);
        self.caret_rows.deinit(a);
        self.touched_carets.deinit(a);
        self.* = .{};
    }

    pub fn build(self: *Projection, a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile, view: *const editor.view_navigation.View, first: usize, count: usize) !void {
        // Clear old borrowed slices before any backing buffer can move. Failed
        // preparation cannot leave dangling row slices for the next frame.
        for (self.touched_carets.items) |i| self.caret_rows.items[i] = &.{};
        self.touched_carets.clearRetainingCapacity();
        const old_end = @min(self.mark_rows.items.len, self.mark_first + self.mark_count);
        if (self.mark_first < old_end) @memset(self.mark_rows.items[self.mark_first..old_end], &.{});
        self.mark_count = 0;
        self.marks.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
        if (!view.visible) {
            self.mark_rows.clearRetainingCapacity();
            self.caret_rows.clearRetainingCapacity();
            return;
        }
        const lines = file.lines.lines;
        const old_marks = self.mark_rows.items.len;
        const old_carets = self.caret_rows.items.len;
        try self.mark_rows.resize(a, lines.len);
        if (old_marks < lines.len) @memset(self.mark_rows.items[old_marks..], &.{});
        try self.caret_rows.resize(a, lines.len);
        if (old_carets < lines.len) @memset(self.caret_rows.items[old_carets..], &.{});
        const begin = @min(first, lines.len);
        const end = begin + @min(count, lines.len - begin);
        try self.marks.ensureTotalCapacity(a, try std.math.mul(usize, end - begin, view.items.items.len));
        try self.offsets.ensureTotalCapacity(a, view.items.items.len);
        try self.touched_carets.ensureTotalCapacity(a, view.items.items.len);
        for (lines[begin..end], begin..) |line, index| {
            const mark_start = self.marks.items.len;
            for (view.items.items) |s| {
                const lo = @max(line.start, @min(s.start(), file.content.len));
                const hi = @min(line.contentEnd(), @min(s.end(), file.content.len));
                if (hi > lo) self.marks.appendAssumeCapacity(.{ .start = @intCast(lo - line.start), .len = @intCast(hi - lo) });
            }
            self.mark_rows.items[index] = self.marks.items[mark_start..];
        }
        self.mark_first = begin;
        self.mark_count = end - begin;
        var group_start: usize = 0;
        var group_line: ?usize = null;
        for (view.items.items) |s| {
            const at = @min(s.focus, file.content.len);
            const index = file.lines.lineAt(at);
            if (group_line != index) {
                if (group_line) |previous| self.caret_rows.items[previous] = self.offsets.items[group_start..];
                group_start = self.offsets.items.len;
                group_line = index;
                self.touched_carets.appendAssumeCapacity(index);
            }
            const line = lines[index];
            self.offsets.appendAssumeCapacity(@intCast(@min(at, line.contentEnd()) - line.start));
        }
        if (group_line) |previous| self.caret_rows.items[previous] = self.offsets.items[group_start..];
    }
};

test "Windows editor input: scrolled marks use document indices and old rows clear" {
    const a = std.testing.allocator;
    var file = try editor.edit_doc.EditableFile.init(a, "a\r\nbc\r\ndef", true);
    defer file.deinit();
    var view: editor.view_navigation.View = .{};
    defer view.deinit(a);
    try view.move(a, &file, .select_all, false);
    var projection: Projection = .{};
    defer projection.deinit(a);
    try projection.build(a, &file, &view, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), projection.mark_rows.items[0].len);
    try std.testing.expectEqual(@as(u32, 2), projection.mark_rows.items[1][0].len);
    try std.testing.expectEqual(@as(u32, 3), projection.caret_rows.items[2][0]);
    try projection.build(a, &file, &view, 2, 1);
    try std.testing.expectEqual(@as(usize, 0), projection.mark_rows.items[1].len);
    try std.testing.expectEqual(@as(u32, 3), projection.mark_rows.items[2][0].len);
    try view.move(a, &file, .document_start, false);
    try projection.build(a, &file, &view, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), projection.caret_rows.items[2].len);
    try std.testing.expectEqual(@as(u32, 0), projection.caret_rows.items[0][0]);
}

test "Windows editor input: projection allocation failures release every prefix" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var file = try editor.edit_doc.EditableFile.init(a, "abcd\r\nefgh", true);
            defer file.deinit();
            var view: editor.view_navigation.View = .{};
            defer view.deinit(a);
            try view.items.appendSlice(a, &.{ editor.selection.Selection.fromPoints(0, 1), editor.selection.Selection.fromPoints(2, 3), editor.selection.Selection.fromPoints(6, 8) });
            view.visible = true;
            var projection: Projection = .{};
            defer projection.deinit(a);
            try projection.build(a, &file, &view, 0, 1);
            try std.testing.expectEqual(@as(usize, 2), projection.mark_rows.items[0].len);
            try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, projection.caret_rows.items[0]);
            try projection.build(a, &file, &view, 1, 1);
            try std.testing.expectEqual(@as(usize, 0), projection.mark_rows.items[0].len);
            try std.testing.expectEqual(@as(u32, 2), projection.mark_rows.items[1][0].len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
