//! Per-view horizontal navigation. Document bytes and history are never mutated;
//! readonly views use the same selection rules as writable views.
const std = @import("std");
const selection = @import("selection.zig");
const edit_doc = @import("edit_doc.zig");
const motion = @import("motion.zig");
const grapheme = @import("../../grapheme.zig");

pub const Command = enum { left, right, word_left, word_right, line_start, line_end, document_start, document_end, select_all };

pub const View = struct {
    items: std.ArrayList(selection.Selection) = .empty,
    primary: usize = 0,
    visible: bool = false,

    pub fn deinit(self: *View, a: std.mem.Allocator) void {
        self.items.deinit(a);
        self.* = .{};
    }

    /// Allocate before publishing any state. A failed first key leaves the view
    /// unchanged, so the host can consume it without leaking it to the shell.
    pub fn move(self: *View, a: std.mem.Allocator, file: *const edit_doc.EditableFile, command: Command, extend: bool) !void {
        if (self.items.items.len == 0) try self.items.append(a, selection.Selection.at(0));
        if (command == .select_all) {
            self.items.items[0] = selection.Selection.fromPoints(0, file.content.len);
            self.items.items.len = 1;
            self.primary = 0;
        } else {
            for (self.items.items) |*s| {
                const focus = snap(file, s.focus);
                const anchor = snap(file, s.fixedEnd());
                // Plain left/right first collapse an existing selection, rather
                // than skipping the character next to its selected edge.
                const target = if (!extend and !s.isEmpty() and (command == .left or command == .right))
                    snap(file, if (command == .left) s.start() else s.end())
                else
                    destination(file, focus, command);
                s.* = if (extend) selection.Selection.fromPoints(anchor, target) else selection.Selection.at(target);
            }
            const merged = selection.mergeOverlapping(self.items.items, self.primary);
            self.items.items.len = merged.len;
            self.primary = merged.primary;
        }
        self.visible = true;
    }
};

fn snap(file: *const edit_doc.EditableFile, offset: usize) usize {
    const at = @min(offset, file.content.len);
    const line = file.lines.lines[file.lines.lineAt(at)];
    // CRLF is an indivisible line ending; a stale offset in it snaps to EOL.
    return line.start + grapheme.snapToBoundary(file.content[line.start..line.contentEnd()], @min(at, line.contentEnd()) - line.start);
}

fn destination(file: *const edit_doc.EditableFile, at: usize, command: Command) usize {
    const index = file.lines.lineAt(at);
    const line = file.lines.lines[index];
    const bytes = file.content[line.start..line.contentEnd()];
    return switch (command) {
        .left => if (at == line.start) (if (index == 0) 0 else file.lines.lines[index - 1].contentEnd()) else line.start + grapheme.prevBoundary(bytes, at - line.start),
        .right => if (at == line.contentEnd()) (if (index + 1 == file.lines.lines.len) file.content.len else file.lines.lines[index + 1].start) else line.start + grapheme.clusterEnd(bytes, at - line.start),
        .word_left => snap(file, motion.wordLeft(file.content, at)),
        .word_right => snap(file, motion.wordRight(file.content, at)),
        .line_start => snap(file, motion.lineStartSmart(file.content, line, at)),
        .line_end => line.contentEnd(),
        .document_start => 0,
        .document_end => file.content.len,
        .select_all => unreachable,
    };
}

test "Editor navigation: NFD and emoji move as clusters without touching readonly bytes" {
    const a = std.testing.allocator;
    const bytes = "a\u{1100}\u{1161}\u{11a8}\u{1f468}\u{200d}\u{1f469}z";
    var file = try edit_doc.EditableFile.init(a, bytes, true);
    defer file.deinit();
    var view: View = .{};
    defer view.deinit(a);
    const stops = [_]usize{ 1, 10, 21, 22 };
    for (stops) |stop| {
        try view.move(a, &file, .right, false);
        try std.testing.expectEqual(stop, view.items.items[0].focus);
    }
    var i = stops.len;
    while (i > 0) {
        i -= 1;
        try view.move(a, &file, .left, false);
        try std.testing.expectEqual(if (i == 0) @as(usize, 0) else stops[i - 1], view.items.items[0].focus);
    }
    try std.testing.expectEqualStrings(bytes, file.content);
    try std.testing.expectEqual(@as(u64, 0), file.revision);
    try std.testing.expect(file.read_only);
}

test "Editor navigation: CRLF is atomic and smart home toggles" {
    const a = std.testing.allocator;
    var file = try edit_doc.EditableFile.init(a, "  a\r\nb\r\n", true);
    defer file.deinit();
    var view: View = .{};
    defer view.deinit(a);
    try view.move(a, &file, .line_end, false);
    try std.testing.expectEqual(@as(usize, 3), view.items.items[0].focus);
    try view.move(a, &file, .right, false);
    try std.testing.expectEqual(@as(usize, 5), view.items.items[0].focus);
    try view.move(a, &file, .left, false);
    try std.testing.expectEqual(@as(usize, 3), view.items.items[0].focus);
    try view.move(a, &file, .line_start, false);
    try std.testing.expectEqual(@as(usize, 2), view.items.items[0].focus);
    try view.move(a, &file, .line_start, false);
    try std.testing.expectEqual(@as(usize, 0), view.items.items[0].focus);
}

test "Editor navigation: reverse selection keeps anchor and plain arrow only collapses" {
    const a = std.testing.allocator;
    var file = try edit_doc.EditableFile.init(a, "abcdef", true);
    defer file.deinit();
    var view: View = .{};
    defer view.deinit(a);
    try view.move(a, &file, .document_end, false);
    try view.move(a, &file, .left, true);
    try view.move(a, &file, .left, true);
    try std.testing.expectEqual(@as(usize, 6), view.items.items[0].fixedEnd());
    try std.testing.expectEqual(@as(usize, 4), view.items.items[0].focus);
    try view.move(a, &file, .right, false);
    try std.testing.expectEqual(@as(usize, 6), view.items.items[0].focus);
    try std.testing.expect(view.items.items[0].isEmpty());
    try view.move(a, &file, .select_all, false);
    try std.testing.expectEqual(@as(usize, 6), view.items.items[0].len());
}

test "Editor navigation: multicursors merge and independent views keep their positions" {
    const a = std.testing.allocator;
    var file = try edit_doc.EditableFile.init(a, "abc", true);
    defer file.deinit();
    var view: View = .{};
    defer view.deinit(a);
    var other: View = .{};
    defer other.deinit(a);
    try view.items.appendSlice(a, &.{ selection.Selection.at(1), selection.Selection.at(2) });
    view.primary = 1;
    try view.move(a, &file, .document_end, false);
    try std.testing.expectEqual(@as(usize, 1), view.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), view.primary);
    try other.move(a, &file, .right, false);
    try std.testing.expectEqual(@as(usize, 1), other.items.items[0].focus);
    try std.testing.expectEqual(@as(usize, 3), view.items.items[0].focus);
}

test "Editor navigation: allocation failure publishes no caret" {
    const a = std.testing.allocator;
    var file = try edit_doc.EditableFile.init(a, "abc", true);
    defer file.deinit();
    var view: View = .{};
    defer view.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, view.move(failing.allocator(), &file, .right, false));
    try std.testing.expectEqual(@as(usize, 0), view.items.items.len);
    try std.testing.expect(!view.visible);
}
