//! TextField bridge for the shared UTF-16 projection. No host or OS state lives
//! here: prepare storage before publishing, and roll back one rejected key.
const std = @import("std");
const grapheme = @import("../../grapheme.zig");
const input = @import("../../inline_text_input.zig");
const Owned = @import("../../inline_text_input_owned.zig").OwnedContext;
const Field = @import("text_field.zig").TextField;
pub const Range = input.Range;
pub const Key = enum { enter, backspace, other };

pub const Normalization = enum { hangul_nfc, verbatim };

pub const State = struct {
    normalization: Normalization = .hangul_nfc,
    context: Owned = .{},
    before: ?Owned = null,
    in_key: bool = false,
    rejected: bool = false,
    before_caret: usize = 0,
    before_selection: ?Field.Selection = null,
    before_preedit_caret: ?usize = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.finish(allocator);
        self.context.deinit(allocator);
    }

    pub fn finish(self: *State, allocator: std.mem.Allocator) void {
        if (self.before) |*value| value.deinit(allocator);
        self.before = null;
        self.in_key = false;
        self.rejected = false;
    }

    pub fn invalidate(self: *State, allocator: std.mem.Allocator) void {
        self.finish(allocator);
        self.context.value.valid = false;
    }

    fn matches(self: *State, field: *const Field) bool {
        const c = &self.context.value;
        if (!c.matches(field.text.items, field.preedit.items)) return false;
        if (c.marked) |mark| return field.caret == mark.start and field.selection == null;
        const sel = field.selection;
        return c.selected.start == (if (sel) |s| s.lo() else field.caret) and
            c.selected.end == (if (sel) |s| s.hi() else field.caret);
    }

    pub fn projection(self: *State, allocator: std.mem.Allocator, field: *const Field) ?*input.DynamicContext {
        if (self.matches(field)) return &self.context.value;
        if (self.in_key and self.rejected) return null;
        const range = input.ranges.utf16Range(field.text.items, .{
            .start = if (field.selection) |s| s.lo() else field.caret,
            .end = if (field.selection) |s| s.hi() else field.caret,
        }) orelse return null;
        self.context.reserve(allocator, field.text.items.len, field.preedit.items.len) catch return null;
        const c = &self.context.value;
        if (!c.reset(field.text.items, "")) return null;
        c.selected = input.ranges.byteRange(c.text(), range) orelse return null;
        if (field.preedit.items.len > 0 and !c.setMarked(field.preedit.items, .{
            .location = input.ranges.utf16Length(field.preedit.items) orelse return null,
            .length = 0,
        }, null)) return null;
        return c;
    }

    fn prepare(self: *State, allocator: std.mem.Allocator, field: *Field, extra: usize) bool {
        const n = std.math.add(usize, self.context.value.len, extra) catch return false;
        self.context.reserve(allocator, n, n) catch return false;
        field.text.ensureTotalCapacity(allocator, n) catch return false;
        field.preedit.ensureTotalCapacity(allocator, n) catch return false;
        return true;
    }

    // Canonical text excludes the marked span. Keeping its suffix is essential:
    // a middle-of-URL composition must never be appended to the end of the URL.
    fn publish(self: *State, field: *Field) void {
        const c = &self.context.value;
        field.text.clearRetainingCapacity();
        field.preedit.clearRetainingCapacity();
        field.selection = null;
        field.preedit_caret = null;
        if (c.marked) |mark| {
            field.text.appendSliceAssumeCapacity(c.text()[0..mark.start]);
            field.text.appendSliceAssumeCapacity(c.text()[mark.end..]);
            field.preedit.appendSliceAssumeCapacity(c.preedit());
            field.caret = mark.start;
            field.preedit_caret = c.selected.end - mark.start;
        } else {
            field.text.appendSliceAssumeCapacity(c.text());
            field.caret = c.selected.end;
            if (c.selected.start != c.selected.end) field.selection = .{ .anchor = c.selected.start, .focus = c.selected.end };
        }
        @memcpy(c.base[0..field.text.items.len], field.text.items);
        c.base_len = field.text.items.len;
    }

    pub fn begin(self: *State, allocator: std.mem.Allocator, field: *Field) void {
        self.finish(allocator);
        self.before_caret = field.caret;
        self.before_selection = field.selection;
        self.before_preedit_caret = field.preedit_caret;
        _ = self.projection(allocator, field) orelse {
            self.in_key = true;
            self.rejected = true;
            return;
        };
        self.before = self.context.clone(allocator) catch {
            self.in_key = true;
            self.rejected = true;
            return;
        };
        self.in_key = true;
    }

    fn rollback(self: *State, allocator: std.mem.Allocator, field: *Field, before: *?Owned) void {
        if (before.*) |saved| {
            self.context.deinit(allocator);
            self.context = saved;
            before.* = null;
            self.publish(field);
        }
    }

    fn apply(self: *State, allocator: std.mem.Allocator, field: *Field, bytes: []const u8, selected: ?Range, replacement: ?Range) bool {
        if (self.rejected) return false;
        _ = self.projection(allocator, field) orelse {
            if (self.in_key) self.rejected = true;
            return false;
        };
        const old_caret = field.caret;
        const old_selection = field.selection;
        const old_preedit_caret = field.preedit_caret;
        var outside: ?Owned = if (!self.in_key) self.context.clone(allocator) catch return false else null;
        defer if (outside) |*value| value.deinit(allocator);
        // An empty marked update cancels a preview, not its retained committed word.
        const cancelled_suffix: ?usize = if (selected != null and bytes.len == 0)
            if (self.context.value.marked) |mark| self.context.value.len - mark.end else null
        else
            null;
        const prepared = self.prepare(allocator, field, bytes.len);
        const accepted = prepared and if (selected) |range|
            self.context.value.setMarked(bytes, range, replacement)
        else
            self.context.value.insert(bytes, replacement);
        if (!accepted) {
            if (self.in_key) self.rejected = true else {
                self.rollback(allocator, field, &outside);
                field.caret = old_caret;
                field.selection = old_selection;
                field.preedit_caret = old_preedit_caret;
            }
            return false;
        }
        if (cancelled_suffix) |suffix| {
            const c = &self.context.value;
            const pending = c.pending;
            const length = c.committed_len;
            @memcpy(c.scratch[0..length], c.committed[0..length]);
            _ = c.reset(c.scratch[0..length], "");
            const caret = length - @min(length, suffix);
            c.selected = .{ .start = caret, .end = caret };
            c.pending = pending;
        }
        self.publish(field);
        if (!self.in_key and selected == null) self.context.value.accepted(field.text.items);
        return true;
    }

    fn reject(self: *State) bool {
        if (self.in_key) self.rejected = true;
        return false;
    }
    pub fn insert(self: *State, allocator: std.mem.Allocator, field: *Field, bytes: []const u8, replacement: ?Range) bool {
        if (self.normalization == .verbatim) return self.apply(allocator, field, bytes, null, replacement);
        // Address bands retain their existing NFC Hangul storage contract.
        const composed = grapheme.composeHangul(allocator, bytes) catch return self.reject();
        defer allocator.free(composed);
        return self.apply(allocator, field, composed, null, replacement);
    }
    pub fn marked(self: *State, allocator: std.mem.Allocator, field: *Field, bytes: []const u8, selected: Range, replacement: ?Range) bool {
        const local = input.ranges.byteRange(bytes, selected) orelse return self.reject();
        if (self.normalization == .verbatim) return self.apply(allocator, field, bytes, selected, replacement);
        const composed = grapheme.composeHangul(allocator, bytes) catch return self.reject();
        defer allocator.free(composed);
        const prefix = grapheme.composeHangul(allocator, bytes[0..local.start]) catch return self.reject();
        defer allocator.free(prefix);
        const normalized_end = grapheme.composeHangul(allocator, bytes[0..local.end]) catch return self.reject();
        defer allocator.free(normalized_end);
        const n = input.ranges.utf16Length(composed) orelse return self.reject();
        const start_at = @min(n, input.ranges.utf16Length(prefix) orelse return self.reject());
        const end_at = @min(n, input.ranges.utf16Length(normalized_end) orelse return self.reject());
        return self.apply(allocator, field, composed, .{ .location = start_at, .length = end_at - start_at }, replacement);
    }

    pub fn end(self: *State, allocator: std.mem.Allocator, field: *Field, deleted: bool) bool {
        if (self.rejected) {
            if (self.before != null) {
                self.rollback(allocator, field, &self.before);
                field.caret = self.before_caret;
                field.selection = self.before_selection;
                field.preedit_caret = self.before_preedit_caret;
            }
            return true;
        }
        const c = &self.context.value;
        if (!c.pending) return false;
        if (deleted) c.cancelInsertedScalar();
        self.publish(field);
        c.accepted(field.text.items);
        return true;
    }

    pub fn finishKey(self: *State, allocator: std.mem.Allocator, field: *Field, key: ?Key, changed: bool, deleted: bool) bool {
        if (self.end(allocator, field, deleted) or changed) return true;
        if (key) |value| {
            if (value == .enter and field.preedit.items.len > 0) return true;
            if (value == .backspace and deleted) {
                _ = self.deleteBackward(allocator, field);
                return true;
            }
            return false;
        }
        return true;
    }

    pub fn deleteBackward(self: *State, allocator: std.mem.Allocator, field: *Field) bool {
        _ = self.projection(allocator, field) orelse return false;
        if (!self.prepare(allocator, field, 0) or !self.context.value.deleteBackward()) return false;
        self.publish(field);
        self.context.value.accepted(field.text.items);
        return true;
    }

    pub fn commitAll(self: *State, allocator: std.mem.Allocator, field: *Field) bool {
        if (self.rejected) return false;
        const c = self.projection(allocator, field) orelse return false;
        if (!self.prepare(allocator, field, 0) or !c.admitMarked()) return false;
        self.publish(field);
        c.accepted(field.text.items);
        return true;
    }
};

test "address IME middle selection keeps suffix and UTF16 coordinates" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "a😀z");
    f.caret = 5;
    f.selection = .{ .anchor = 5, .focus = 1 };
    const p = s.projection(a, &f).?;
    try std.testing.expectEqual(Range{ .location = 1, .length = 2 }, p.selectedRange().?);
    s.begin(a, &f);
    try std.testing.expect(s.marked(a, &f, "한", .{ .location = 1, .length = 0 }, null));
    try std.testing.expectEqualStrings("az", f.text.items);
    try std.testing.expectEqualStrings("한", f.preedit.items);
    try std.testing.expectEqual(@as(usize, 1), f.caret);
    try std.testing.expectEqualStrings("a한z", s.context.value.text());
    try std.testing.expect(s.insert(a, &f, "韓", null));
    try std.testing.expect(s.end(a, &f, false));
    s.finish(a);
    try std.testing.expectEqualStrings("a韓z", f.text.items);
    try std.testing.expectEqual(@as(usize, 4), f.caret);
}

test "address IME rejects surrogate split and rolls back whole key" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "a😀z");
    f.caret = 1;
    s.begin(a, &f);
    try std.testing.expect(s.insert(a, &f, "x", null));
    try std.testing.expect(!s.insert(a, &f, "bad", .{ .location = 3, .length = 0 }));
    try std.testing.expect(s.end(a, &f, false));
    s.finish(a);
    try std.testing.expectEqualStrings("a😀z", f.text.items);
    try std.testing.expectEqual(@as(usize, 1), f.caret);
}

test "address IME reconversion cancel keeps the committed word and URL suffix" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "a한/z");
    f.caret = 4;
    s.begin(a, &f);
    try std.testing.expect(s.insert(a, &f, "한", .{ .location = 1, .length = 1 }));
    try std.testing.expect(s.marked(a, &f, "韓", .{ .location = 0, .length = 1 }, .{ .location = 1, .length = 1 }));
    _ = s.end(a, &f, false);
    s.finish(a);
    s.begin(a, &f);
    try std.testing.expect(s.marked(a, &f, "", .{ .location = 0, .length = 0 }, null));
    _ = s.end(a, &f, false);
    s.finish(a);
    try std.testing.expectEqualStrings("a한/z", f.text.items);
    try std.testing.expectEqualStrings("", f.preedit.items);
    try std.testing.expectEqual(@as(usize, 4), f.caret);
}

test "address IME NFC selected range and preedit caret agree" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "az");
    f.caret = 1;
    try std.testing.expect(s.marked(a, &f, "\u{1112}\u{1161}\u{11ab}", .{ .location = 3, .length = 0 }, null));
    try std.testing.expectEqualStrings("한", f.preedit.items);
    try std.testing.expectEqual(Range{ .location = 2, .length = 0 }, s.context.value.selectedRange().?);
    const field_model = @import("text_field.zig");
    const layout = field_model.fieldLayout(f.view(), .{ .cols = 40, .nav_end = 0 });
    try std.testing.expectEqual(@as(u32, 3), layout.caret_block_col);
    try std.testing.expect(s.marked(a, &f, "한", .{ .location = 0, .length = 0 }, null));
    const inside = field_model.fieldLayout(f.view(), .{ .cols = 40, .nav_end = 0 });
    try std.testing.expectEqual(@as(u32, 1), inside.caret_block_col);
    try std.testing.expect(s.commitAll(a, &f));
    try std.testing.expectEqualStrings("a한z", f.text.items);
}

test "address IME insert then next marked and deletion keep suffix" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "az");
    f.caret = 1;
    s.begin(a, &f);
    try std.testing.expect(s.insert(a, &f, "한", null));
    try std.testing.expect(s.marked(a, &f, "ㄱ", .{ .location = 1, .length = 0 }, null));
    try std.testing.expect(s.end(a, &f, true));
    s.finish(a);
    try std.testing.expectEqualStrings("az", f.text.items);
    try std.testing.expectEqualStrings("ㄱ", f.preedit.items);
    try std.testing.expectEqual(@as(usize, 1), f.caret);
    try std.testing.expect(s.commitAll(a, &f));
    try std.testing.expectEqualStrings("aㄱz", f.text.items);
}

test "address IME allocation failures retain a complete field and selection" {
    const a = std.testing.allocator;
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..20) |failure| {
        var f: Field = .{};
        defer f.deinit(a);
        try f.setText(a, "a😀z");
        f.caret = 1;
        f.selection = .{ .anchor = 1, .focus = 5 };
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure });
        const alloc = failing.allocator();
        var s: State = .{};
        defer s.deinit(alloc);
        s.begin(alloc, &f);
        const accepted = s.marked(alloc, &f, "한", .{ .location = 1, .length = 0 }, null);
        _ = s.end(alloc, &f, false);
        s.finish(alloc);
        if (!accepted) {
            failures += 1;
            try std.testing.expectEqualStrings("a😀z", f.text.items);
            try std.testing.expectEqualStrings("", f.preedit.items);
            try std.testing.expectEqual(@as(usize, 1), f.caret);
            try std.testing.expectEqual(@as(usize, 1), f.selection.?.lo());
            try std.testing.expectEqual(@as(usize, 5), f.selection.?.hi());
        } else {
            successes += 1;
            try std.testing.expectEqualStrings("az", f.text.items);
            try std.testing.expectEqualStrings("한", f.preedit.items);
        }
    }
    try std.testing.expect(failures > 0 and successes > 0);
}

test "address IME NFD insert preserves normalized document offsets" {
    const a = std.testing.allocator;
    var f: Field = .{};
    defer f.deinit(a);
    var s: State = .{};
    defer s.deinit(a);
    try f.setText(a, "az");
    f.caret = 1;
    try std.testing.expect(s.insert(a, &f, "\u{1112}\u{1161}\u{11ab}", null));
    try std.testing.expectEqualStrings("a한z", f.text.items);
    try std.testing.expectEqual(Range{ .location = 2, .length = 0 }, s.context.value.selectedRange().?);
}

test "inline rename IME preserves NFD text and UTF16 selection" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{ .normalization = .verbatim };
    defer state.deinit(a);
    try field.setText(a, "aZ");
    field.caret = 1;
    const nfd = "\u{1112}\u{1161}\u{11ab}";
    try std.testing.expect(state.marked(a, &field, nfd, .{ .location = 3, .length = 0 }, null));
    try std.testing.expectEqualStrings(nfd, field.preedit.items);
    try std.testing.expectEqual(Range{ .location = 4, .length = 0 }, state.context.value.selectedRange().?);
    try std.testing.expect(state.insert(a, &field, nfd, null));
    try std.testing.expectEqualStrings("a" ++ nfd ++ "Z", field.text.items);
    try std.testing.expect(state.insert(a, &field, "韓", .{ .location = 1, .length = 3 }));
    try std.testing.expectEqualStrings("a韓Z", field.text.items);
}

test "inline rename IME rejected key cannot publish through blur" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{ .normalization = .verbatim };
    defer state.deinit(a);
    try field.setText(a, "old");
    state.begin(a, &field);
    try std.testing.expect(!state.marked(a, &field, "한", .{ .location = 99, .length = 0 }, null));
    try std.testing.expect(!state.commitAll(a, &field));
    try std.testing.expectEqualStrings("old", field.text.items);
}

test "inline rename IME invalid UTF16 ranges never change canonical text" {
    const a = std.testing.allocator;
    const invalid = [_]Range{
        .{ .location = 2, .length = 0 }, // Inside the emoji surrogate pair.
        .{ .location = 1, .length = 1 }, // Ends inside the surrogate pair.
        .{ .location = 0, .length = 99 },
        .{ .location = std.math.maxInt(u32), .length = 1 },
        .{ .location = 1, .length = std.math.maxInt(u32) },
    };
    for (invalid) |range| {
        var f: Field = .{};
        defer f.deinit(a);
        var s: State = .{ .normalization = .verbatim };
        defer s.deinit(a);
        try f.setText(a, "a😀z");
        try std.testing.expect(!s.insert(a, &f, "韓", range));
        try std.testing.expectEqualStrings("a😀z", f.text.items);
        try std.testing.expectEqualStrings("", f.preedit.items);
    }
}

test "inline rename IME allocation failures preserve NFD and caret" {
    const a = std.testing.allocator;
    var failures: usize = 0;
    var successes: usize = 0;
    const nfd = "\u{1112}\u{1161}\u{11ab}";
    for (0..20) |failure| {
        var f: Field = .{};
        defer f.deinit(a);
        try f.setText(a, "aZ");
        f.caret = 1;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure });
        const alloc = failing.allocator();
        var s: State = .{ .normalization = .verbatim };
        defer s.deinit(alloc);
        s.begin(alloc, &f);
        const accepted = s.marked(alloc, &f, nfd, .{ .location = 3, .length = 0 }, null);
        _ = s.end(alloc, &f, false);
        s.finish(alloc);
        try std.testing.expectEqualStrings("aZ", f.text.items);
        try std.testing.expectEqual(@as(usize, 1), f.caret);
        if (!accepted) {
            failures += 1;
            try std.testing.expectEqualStrings("", f.preedit.items);
        } else {
            successes += 1;
            try std.testing.expectEqualStrings(nfd, f.preedit.items);
        }
    }
    try std.testing.expect(failures > 0 and successes > 0);
}

test "project search IME model candidate key is consumed then bare Enter remains an action" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{ .normalization = .verbatim };
    defer state.deinit(a);
    state.begin(a, &field);
    try std.testing.expect(state.marked(a, &field, "한", .{ .location = 1, .length = 0 }, null));
    try std.testing.expect(state.insert(a, &field, "韓", null));
    try std.testing.expect(state.finishKey(a, &field, .enter, true, false));
    state.finish(a);
    try std.testing.expectEqualStrings("韓", field.text.items);
    state.begin(a, &field);
    try std.testing.expect(!state.finishKey(a, &field, .enter, false, false));
}

test "project search IME model NFD range uses source UTF16 units" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var state: State = .{ .normalization = .verbatim };
    defer state.deinit(a);
    try field.setText(a, "a한z");
    state.begin(a, &field);
    try std.testing.expect(state.marked(a, &field, "韓", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 3 }));
    try std.testing.expectEqualStrings("a韓z", state.context.value.text());
    try std.testing.expect(state.insert(a, &field, "韓", null));
    try std.testing.expect(state.finishKey(a, &field, .enter, true, false));
    try std.testing.expectEqualStrings("a韓z", field.text.items);
}
