//! Windows editor keys consume the neutral event after modal/dock routing.
//! The document model stays OS-free; this adapter only chooses its commands.
const std = @import("std");
const maru = @import("maru");
const editor = maru.session.editor;
const navigation = editor.view_navigation;
const KeyEvent = maru.terminal.KeyEvent;

pub const Action = union(enum) { ignored, copy, move: navigation.Command, character: u21, newline, tab, backspace, delete_forward, undo, redo };

pub fn action(event: KeyEvent) Action {
    if (event.event_type == .release or event.modifiers.option) return .ignored;
    // win32_keys preserves shell Ctrl but maps some Ctrl+Shift chords to
    // command. Both neutral representations mean primary Ctrl in the editor.
    const primary = event.modifiers.control or event.modifiers.command;
    return switch (event.key) {
        .arrow_left => .{ .move = if (primary) .word_left else .left },
        .arrow_right => .{ .move = if (primary) .word_right else .right },
        .home => .{ .move = if (primary) .document_start else .line_start },
        .end => .{ .move = if (primary) .document_end else .line_end },
        .char => |cp| if (primary) switch (cp) {
            'c', 'C' => .copy,
            'a', 'A' => .{ .move = .select_all },
            'z', 'Z' => if (event.modifiers.shift) .redo else .undo,
            'y', 'Y' => .redo,
            else => .ignored,
        } else if (cp >= 0x20 and cp != 0x7f and cp <= 0x10ffff and (cp < 0xd800 or cp > 0xdfff)) .{ .character = cp } else .ignored,
        .enter => if (primary) .ignored else .newline,
        .tab => if (primary or event.modifiers.shift) .ignored else .tab,
        .backspace => if (primary) .ignored else .backspace,
        .delete => if (primary) .ignored else .delete_forward,
        else => .ignored,
    };
}

/// Copy uses original bytes, including CRLF. With no selection, copy caret
/// lines once each; several carets on the same line must not duplicate it.
pub fn copy(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile, view: *const navigation.View) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var selected = false;
    for (view.items.items) |s| selected = selected or !s.isEmpty();
    var last_line: ?usize = null;
    const count = @max(@as(usize, 1), view.items.items.len);
    for (0..count) |i| {
        const s = if (view.items.items.len == 0) editor.selection.Selection.at(0) else view.items.items[i];
        if (selected) {
            if (s.isEmpty()) continue;
            if (text.items.len > 0) try text.appendSlice(a, "\n");
            try text.appendSlice(a, file.content[@min(s.start(), file.content.len)..@min(s.end(), file.content.len)]);
        } else {
            const index = file.lines.lineAt(@min(s.focus, file.content.len));
            if (last_line == index) continue;
            const line = file.lines.lines[index];
            try text.appendSlice(a, file.content[line.start..line.end_with_ending]);
            last_line = index;
        }
    }
    return text.toOwnedSlice(a);
}

test "Windows editor input: primary modifiers select commands and release never moves" {
    try std.testing.expectEqual(navigation.Command.word_left, action(.{ .key = .arrow_left, .modifiers = .{ .command = true, .shift = true } }).move);
    try std.testing.expectEqual(navigation.Command.document_end, action(.{ .key = .end, .modifiers = .{ .control = true } }).move);
    try std.testing.expect(action(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true } }) == .copy);
    try std.testing.expect(action(.{ .key = .arrow_right, .event_type = .release }) == .ignored);
    try std.testing.expect(action(.{ .key = .arrow_right, .modifiers = .{ .option = true } }) == .ignored);
    try std.testing.expectEqual(@as(u21, 'x'), action(.{ .key = .{ .char = 'x' } }).character);
    try std.testing.expect(action(.{ .key = .{ .char = 'z' }, .modifiers = .{ .control = true } }) == .undo);
    try std.testing.expect(action(.{ .key = .{ .char = 'Z' }, .modifiers = .{ .command = true, .shift = true } }) == .redo);
}

test "Windows editor input: readonly copy keeps CRLF and deduplicates empty caret lines" {
    const a = std.testing.allocator;
    var file = try editor.edit_doc.EditableFile.init(a, "abc\r\ndef", true);
    defer file.deinit();
    var view: navigation.View = .{};
    defer view.deinit(a);
    try view.items.appendSlice(a, &.{ editor.selection.Selection.at(0), editor.selection.Selection.at(2), editor.selection.Selection.at(6) });
    const lines = try copy(a, &file, &view);
    defer a.free(lines);
    try std.testing.expectEqualStrings("abc\r\ndef", lines);
    try view.move(a, &file, .select_all, false);
    const selected = try copy(a, &file, &view);
    defer a.free(selected);
    try std.testing.expectEqualStrings("abc\r\ndef", selected);
    try std.testing.expectEqual(@as(u64, 0), file.revision);
}

test "Windows editor input: copy allocation failures release partial text" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var file = try editor.edit_doc.EditableFile.init(a, "abc\r\ndef", true);
            defer file.deinit();
            var view: navigation.View = .{};
            defer view.deinit(a);
            try view.items.appendSlice(a, &.{ editor.selection.Selection.fromPoints(0, 2), editor.selection.Selection.fromPoints(5, 8) });
            const text = try copy(a, &file, &view);
            defer a.free(text);
            try std.testing.expectEqualStrings("ab\ndef", text);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
