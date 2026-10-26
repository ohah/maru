//! Activity search keeps its query budget while sharing all range/key semantics.
const std = @import("std");
const shared = @import("overlay_input_ime.zig");
const Field = @import("overlay_input.zig").OverlayInput;
pub const query_limit: usize = 256;
pub const Range = shared.Range;
pub const Key = shared.Key;
pub const State = struct {
    projection: shared.Projection = .{},
    transaction: shared.Transaction = .{},
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.transaction.finish(a);
        self.projection.deinit(a);
    }
    pub fn begin(self: *State, a: std.mem.Allocator, field: *Field) void {
        self.transaction.begin(a, &self.projection, field);
    }
    pub fn finish(self: *State, a: std.mem.Allocator) void {
        if (self.transaction.active and self.projection.context.value.pending) self.projection.invalidate();
        self.transaction.finish(a);
    }
    pub fn reject(self: *State) void {
        self.transaction.rejected = true;
    }
    pub fn abort(self: *State, a: std.mem.Allocator, field: *Field) void {
        if (self.transaction.active) self.projection.rollback(a, field, &self.transaction);
        self.projection.invalidate();
    }
    pub fn insert(self: *State, a: std.mem.Allocator, field: *Field, bytes: []const u8, replacement: ?Range) bool {
        if (!self.projection.insert(a, field, bytes, replacement, &self.transaction)) return false;
        // Checking the completed projection reuses shared UTF-16 replacement rules.
        // The key snapshot owns rollback, including a preview cleared by insertText.
        if (self.projection.context.value.len > query_limit) {
            self.reject();
            return false;
        }
        return true;
    }
    pub fn marked(self: *State, a: std.mem.Allocator, field: *Field, bytes: []const u8, selected: Range, replacement: ?Range) bool {
        return self.projection.marked(a, field, bytes, selected, replacement, &self.transaction);
    }
    pub fn end(self: *State, a: std.mem.Allocator, field: *Field, key: ?Key, deleted: bool) shared.Decision {
        return self.projection.finishKey(a, field, &self.transaction, key, deleted);
    }
    pub fn commitAll(self: *State, a: std.mem.Allocator, field: *Field) ?bool {
        if (self.transaction.rejected) return null;
        const c = self.projection.sync(a, field) orelse return null;
        // Marked previews remain dynamically sized; only admission is budgeted.
        if (c.len > query_limit) return null;
        return self.projection.commitAll(a, field);
    }
};

test "activity search IME model query budget rejects an entire key" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{};
    defer state.deinit(a);
    var text: [query_limit]u8 = undefined;
    @memset(&text, 'a');
    try field.query.appendSlice(a, &text);
    state.begin(a, &field);
    try std.testing.expect(!state.insert(a, &field, "x", null));
    const result = state.end(a, &field, null, false);
    try std.testing.expect(result.consumed and !result.changed);
    try std.testing.expectEqualStrings(&text, field.query.items);
}

test "activity search IME model long preedit is visible but cannot be admitted over budget" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{};
    defer state.deinit(a);
    try field.query.appendSlice(a, "a😀z");
    var text: [query_limit + 10]u8 = undefined;
    @memset(&text, 'x');
    state.begin(a, &field);
    try std.testing.expect(state.marked(a, &field, &text, .{ .location = text.len, .length = 0 }, .{ .location = 1, .length = 2 }));
    _ = state.end(a, &field, null, false);
    state.finish(a);
    try std.testing.expectEqualStrings(&text, field.preedit.items);
    try std.testing.expect(state.commitAll(a, &field) == null);
    try std.testing.expectEqualStrings("a😀z", field.query.items);
}

const inline_edit = @import("inline_edit.zig");
const text_layout = @import("../text_layout.zig");
const grapheme = @import("../../grapheme.zig");
pub const Line = struct { text: []const u8, caret_cols: u32 };
const Writer = struct {
    buf: []u8,
    len: usize = 0,
    cols: u32 = 0,
    fn append(self: *Writer, bytes: []const u8, cols: u32) bool {
        if (bytes.len > self.buf.len - self.len) return false;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cols += cols;
        return true;
    }
    fn pad(self: *Writer, col: u32) bool {
        while (self.cols < col) if (!self.append(" ", 1)) return false;
        return true;
    }
};

pub const View = struct { text: []const u8, caret: usize };
/// Copy the shared inline-edit viewport and text-layout clusters to the fixed
/// notice buffer. Geometry and paint never mix codepoint and grapheme widths.
pub fn line(buf: []u8, prompt: []const u8, view: View, hint: []const u8, cols: u32) Line {
    var prefix: Writer = .{ .buf = buf };
    var prompt_plan = text_layout.plan(prompt, 0, @intCast(@min(cols, std.math.maxInt(u16))), .head, null);
    while (prompt_plan.next()) |item| switch (item) {
        .cluster => |c| {
            if (!prefix.append(prompt[c.start..c.end], c.cols)) break;
        },
        .ellipsis => {
            if (!prefix.append("…", 1)) break;
        },
    };
    const available = @min(cols -| prefix.cols, std.math.maxInt(u16));
    const caret = grapheme.snapToBoundary(view.text, @min(view.caret, view.text.len));
    const end = inline_edit.fitLineEnd(view.text, caret, available);
    var plan = text_layout.plan(view.text[0..end], 0, @intCast(available), .tail, null);
    var content: Writer = .{ .buf = buf[prefix.len..] };
    var caret_col: u32 = 0;
    var after_caret = false;
    while (plan.next()) |item| switch (item) {
        .ellipsis => |col| {
            if (!content.pad(col) or !content.append("…", 1)) break;
        },
        .cluster => |c| {
            if (!content.pad(c.col) or !content.append(view.text[c.start..c.end], c.cols)) break;
            if (c.end <= caret) caret_col = c.col + c.cols else if (!after_caret) {
                caret_col = c.col;
                after_caret = true;
            }
        },
    };
    const visible_caret = prefix.cols + @min(caret_col, content.cols);
    const hint_cols = text_layout.displayCols(hint, null);
    if (prefix.cols + content.cols + hint_cols <= cols) _ = content.append(hint, @intCast(hint_cols));
    const n = prefix.len + content.len;
    for (buf[0..n]) |*byte| if (byte.* == '\n' or byte.* == '\r') {
        byte.* = ' ';
    };
    return .{ .text = buf[0..n], .caret_cols = visible_caret };
}

test "activity search IME model line keeps internal caret before the hint" {
    var buf: [128]u8 = undefined;
    const rendered = line(&buf, "Find: ", .{ .text = "a韓z", .caret = "a韓".len }, "  Enter", 40);
    try std.testing.expectEqualStrings("Find: a韓z  Enter", rendered.text);
    try std.testing.expectEqual(@as(u32, 9), rendered.caret_cols);
}
test "activity search IME model line paints NFD at a whole cluster boundary" {
    var buf: [128]u8 = undefined;
    const rendered = line(&buf, "", .{ .text = "한z", .caret = "ᄒ".len }, "", 20);
    try std.testing.expectEqualStrings("한z", rendered.text);
    try std.testing.expectEqual(@as(u32, 0), rendered.caret_cols);
}
test "activity search IME model line narrow windows retain bounded UTF8" {
    for ([_]u32{ 0, 1, 2, 4, 8, 20 }) |cols| {
        var buf: [128]u8 = undefined;
        const rendered = line(&buf, "Find: ", .{ .text = "a😀한suffix", .caret = "a😀".len }, " Enter", cols);
        try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.text));
        try std.testing.expect(text_layout.displayCols(rendered.text, null) <= cols);
        try std.testing.expect(rendered.caret_cols <= cols);
    }
}
test "activity search IME model line tiny byte buffers never split a grapheme" {
    var storage: [32]u8 = undefined;
    for (0..storage.len) |size| {
        const rendered = line(storage[0..size], "", .{ .text = "한é😀suffix", .caret = "한é".len }, "", 40);
        try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.text));
        try std.testing.expect(grapheme.snapToBoundary("한é😀suffix", rendered.text.len) == rendered.text.len);
        try std.testing.expect(rendered.caret_cols <= text_layout.displayCols(rendered.text, null));
    }
}
test "activity search IME model long composed preview is clipped without allocation" {
    var buf: [128]u8 = undefined;
    const rendered = line(&buf, "Find: ", .{ .text = "aabcdefghijk한suffix", .caret = "aabcdefghijk한".len }, " Enter", 16);
    try std.testing.expect(rendered.text.len > 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.text));
    try std.testing.expect(text_layout.displayCols(rendered.text, null) <= 16);
    try std.testing.expect(rendered.caret_cols <= 16);
}
