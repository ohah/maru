//! Bounded single-line IME projection. Canonical query stays with its caller; this value
//! owns only the tentative document observed during a key/composition transaction.
const std = @import("std");
pub const ranges = @import("session/editor/text_input.zig");
pub const Range = ranges.Utf16Range;
const Span = ranges.ByteRange;
pub const query_limit = 256;
pub const marked_limit = 256;

pub const Context = ContextWithStorage(false);
pub const DynamicContext = ContextWithStorage(true);

// Storage policy changes ownership, not IME semantics. The fixed Session Dock
// value keeps its original limits; dynamic callers reserve and snapshot first.
fn ContextWithStorage(comptime dynamic: bool) type {
    return struct {
        const Self = @This();
        storage: if (dynamic) []u8 else [query_limit + marked_limit]u8 = if (dynamic) &.{} else undefined,
        scratch: if (dynamic) []u8 else void = if (dynamic) &.{} else {},
        len: usize = 0,
        base: if (dynamic) []u8 else [query_limit]u8 = if (dynamic) &.{} else undefined,
        base_len: usize = 0,
        committed: if (dynamic) []u8 else [query_limit]u8 = if (dynamic) &.{} else undefined,
        committed_len: usize = 0,
        selected: Span = .{ .start = 0, .end = 0 },
        marked: ?Span = null,
        pending: bool = false,
        last_insert: ?Span = null,
        last_scalar_projected: ?Span = null,
        valid: bool = false,

        fn queryCapacity(self: *const Self) usize {
            return self.base.len;
        }
        fn markedCapacity(self: *const Self) usize {
            return self.storage.len - self.base.len;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.storage[0..self.len];
        }
        pub fn preedit(self: *const Self) []const u8 {
            const span = self.marked orelse return "";
            return self.text()[span.start..span.end];
        }
        pub fn matches(self: *const Self, query: []const u8, marked: []const u8) bool {
            return self.valid and std.mem.eql(u8, self.base[0..self.base_len], query) and std.mem.eql(u8, self.preedit(), marked);
        }
        pub fn reset(self: *Self, query: []const u8, marked: []const u8) bool {
            if (query.len > self.queryCapacity() or marked.len > self.markedCapacity() or ranges.utf16Length(query) == null or ranges.utf16Length(marked) == null) return false;
            if (dynamic) {
                // Reset metadata without losing caller-owned storage slices.
                const buffers = self.*;
                self.* = .{ .storage = buffers.storage, .base = buffers.base, .committed = buffers.committed, .scratch = buffers.scratch };
            } else self.* = .{};
            @memcpy(self.base[0..query.len], query);
            self.base_len = query.len;
            @memcpy(self.committed[0..query.len], query);
            self.committed_len = query.len;
            @memcpy(self.storage[0..query.len], query);
            @memcpy(self.storage[query.len..][0..marked.len], marked);
            self.len = query.len + marked.len;
            self.selected = .{ .start = self.len, .end = self.len };
            if (marked.len > 0) self.marked = .{ .start = query.len, .end = self.len };
            self.valid = true;
            return true;
        }
        pub fn selectedRange(self: *const Self) ?Range {
            return ranges.utf16Range(self.text(), self.selected);
        }
        pub fn markedRange(self: *const Self) ?Range {
            return ranges.utf16Range(self.text(), self.marked orelse .{ .start = self.selected.start, .end = self.selected.start });
        }
        fn requested(self: *const Self, explicit: ?Range) ?Span {
            if (explicit) |value| return ranges.byteRange(self.text(), value);
            return self.marked orelse self.selected;
        }
        // All validation precedes writes, including arithmetic and UTF-16 surrogate boundaries.
        fn replace(self: *Self, span: Span, bytes: []const u8) bool {
            if (span.start > span.end or span.end > self.len or ranges.utf16Length(bytes) == null) return false;
            const length = std.math.add(usize, self.len - (span.end - span.start), bytes.len) catch return false;
            if (length > self.storage.len) return false;
            // Callers may replace from a substring of this projection. Preserve it before shifting.
            var fixed_replacement: if (dynamic) void else [query_limit + marked_limit]u8 = undefined;
            const replacement = if (dynamic) self.scratch else fixed_replacement[0..];
            @memcpy(replacement[0..bytes.len], bytes);
            const tail = self.len - span.end;
            if (span.start + bytes.len > span.end)
                std.mem.copyBackwards(u8, self.storage[span.start + bytes.len ..][0..tail], self.storage[span.end..][0..tail])
            else
                std.mem.copyForwards(u8, self.storage[span.start + bytes.len ..][0..tail], self.storage[span.end..][0..tail]);
            @memcpy(self.storage[span.start..][0..bytes.len], replacement[0..bytes.len]);
            self.len = length;
            return true;
        }
        pub fn insert(self: *Self, bytes: []const u8, replacement: ?Range) bool {
            if (!self.valid) return false;
            const span = self.requested(replacement) orelse return false;
            if (self.len - (span.end - span.start) > self.queryCapacity() or bytes.len > self.queryCapacity() - (self.len - (span.end - span.start))) return false;
            if (!self.replace(span, bytes)) return false;
            self.selected = .{ .start = span.start + bytes.len, .end = span.start + bytes.len };
            self.last_insert = .{ .start = span.start, .end = self.selected.end };
            var scalar_start = self.selected.end;
            if (bytes.len > 0) {
                scalar_start -= 1;
                while (scalar_start > span.start and self.storage[scalar_start] & 0xc0 == 0x80) scalar_start -= 1;
            }
            self.last_scalar_projected = if (bytes.len > 0) .{ .start = scalar_start, .end = self.selected.end } else null;
            @memcpy(self.committed[0..self.len], self.text());
            self.committed_len = self.len;
            self.marked = null;
            self.pending = true;
            return true;
        }
        pub fn setMarked(self: *Self, bytes: []const u8, selected: Range, replacement: ?Range) bool {
            if (!self.valid) return false;
            if (bytes.len > self.markedCapacity()) return false;
            const local = ranges.byteRange(bytes, selected) orelse return false;
            const span = self.requested(replacement) orelse return false;
            if (self.len - (span.end - span.start) > self.queryCapacity()) return false;
            // Track only the visible last scalar; a preview may replace it entirely.
            const scalar = if (self.last_scalar_projected) |old| blk: {
                if (old.end <= span.start) break :blk old;
                if (old.start >= span.end) break :blk Span{ .start = old.start - (span.end - span.start) + bytes.len, .end = old.end - (span.end - span.start) + bytes.len };
                break :blk null;
            } else null;
            if (!self.replace(span, bytes)) return false;
            self.last_scalar_projected = scalar;
            self.marked = if (bytes.len > 0) .{ .start = span.start, .end = span.start + bytes.len } else null;
            self.selected = .{ .start = span.start + local.start, .end = span.start + local.end };
            return true;
        }
        pub fn cancelInsertedScalar(self: *Self) void {
            const inserted = self.last_insert orelse return;
            if (inserted.start == inserted.end) return;
            var start = inserted.end - 1;
            while (start > inserted.start and self.committed[start] & 0xc0 == 0x80) start -= 1;
            const removed = inserted.end - start;
            std.mem.copyForwards(u8, self.committed[start..][0 .. self.committed_len - inserted.end], self.committed[inserted.end..self.committed_len]);
            self.committed_len -= removed;
            if (self.last_scalar_projected) |span| {
                if (!self.replace(span, "")) unreachable;
                self.selected.start = if (self.selected.start >= span.end) self.selected.start - removed else @min(self.selected.start, span.start);
                self.selected.end = if (self.selected.end >= span.end) self.selected.end - removed else @min(self.selected.end, span.start);
                if (self.marked) |*mark| {
                    if (mark.start >= span.end) {
                        mark.start -= removed;
                        mark.end -= removed;
                    }
                }
            }
            self.last_insert = null;
            self.last_scalar_projected = null;
        }
        pub fn deleteBackward(self: *Self) bool {
            if (!self.valid or self.marked != null) return false;
            var span = self.selected;
            if (span.start == span.end and span.start > 0) {
                span.start -= 1;
                while (span.start > 0 and self.storage[span.start] & 0xc0 == 0x80) span.start -= 1;
            }
            const range = ranges.utf16Range(self.text(), span) orelse return false;
            return self.insert("", range);
        }
        pub fn committedLength(self: *const Self) usize {
            return self.committed_len;
        }
        pub fn copyCommitted(self: *const Self, out: []u8) void {
            @memcpy(out[0..self.committed_len], self.committed[0..self.committed_len]);
        }
        pub fn admitMarked(self: *Self) bool {
            if (self.len > self.queryCapacity()) return false;
            @memcpy(self.committed[0..self.len], self.text());
            self.committed_len = self.len;
            self.marked = null;
            self.pending = true;
            return true;
        }
        pub fn accepted(self: *Self, query: []const u8) void {
            @memcpy(self.base[0..query.len], query);
            self.base_len = query.len;
            self.pending = false;
            self.last_insert = null;
            self.last_scalar_projected = null;
        }
        // TSM may inspect one UTF-16 unit of an emoji while discovering a conversion
        // word. Return the whole scalar with its actual range; edit ranges stay strict.
        pub fn substringForInputMethod(self: *const Self, requested_range: Range) ?struct { bytes: []const u8, actual: Range } {
            if (!self.valid) return null;
            const total = ranges.utf16Length(self.text()) orelse return null;
            if (requested_range.location > total) return null;
            var actual = Range{ .location = requested_range.location, .length = @min(total - requested_range.location, requested_range.length) };
            if (ranges.byteRange(self.text(), .{ .location = actual.location, .length = 0 }) == null) {
                if (actual.location == 0) return null;
                actual.location -= 1;
                actual.length += 1;
            }
            if (ranges.byteRange(self.text(), .{ .location = actual.location + actual.length, .length = 0 }) == null) {
                if (actual.location + actual.length >= total) return null;
                actual.length += 1;
            }
            const part = self.substring(actual) orelse return null;
            return .{ .bytes = part.bytes, .actual = part.actual };
        }

        pub fn substring(self: *const Self, requested_range: Range) ?struct { bytes: []const u8, actual: Range } {
            if (!self.valid) return null;
            const total = ranges.utf16Length(self.text()) orelse return null;
            if (requested_range.location > total) return null;
            const actual = Range{ .location = requested_range.location, .length = @min(total - requested_range.location, requested_range.length) };
            const span = ranges.byteRange(self.text(), actual) orelse return null;
            return .{ .bytes = self.text()[span.start..span.end], .actual = actual };
        }
    };
}

test "inline IME input method reads expand surrogate boundaries without admitting edits" {
    var context: Context = .{};
    try std.testing.expect(context.reset("a😀한", ""));
    for ([_]Range{ .{ .location = 1, .length = 1 }, .{ .location = 2, .length = 1 }, .{ .location = 2, .length = 0 } }) |requested| {
        const part = context.substringForInputMethod(requested) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("😀", part.bytes);
        try std.testing.expectEqual(Range{ .location = 1, .length = 2 }, part.actual);
    }
    try std.testing.expect(context.substringForInputMethod(.{ .location = 5, .length = 0 }) == null);
    const tail = context.substringForInputMethod(.{ .location = 2, .length = std.math.maxInt(u64) }).?;
    try std.testing.expectEqualStrings("😀한", tail.bytes);
    try std.testing.expectEqual(Range{ .location = 1, .length = 3 }, tail.actual);
    try std.testing.expect(!context.insert("x", .{ .location = 2, .length = 0 }));
    try std.testing.expectEqualStrings("a😀한", context.text());
}

test "inline IME projects marked text and queued replacement without changing canonical bytes" {
    var context: Context = .{};
    try std.testing.expect(context.reset("a😀z", ""));
    try std.testing.expect(context.setMarked("한", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 2 }));
    try std.testing.expectEqualStrings("a한z", context.text());
    try std.testing.expectEqualStrings("a😀z", context.base[0..context.base_len]);
    try std.testing.expectEqual(Range{ .location = 2, .length = 0 }, context.selectedRange().?);
    try std.testing.expect(context.insert("韓", null));
    try std.testing.expectEqualStrings("a韓z", context.text());
    try std.testing.expect(context.insert("漢", .{ .location = 1, .length = 1 }));
    try std.testing.expectEqualStrings("a漢z", context.text());
    // An input method can commit an original syllable then preview a candidate in one key.
    // The preview must not erase the committed query or change its filter.
    try std.testing.expect(context.reset("한", ""));
    try std.testing.expect(context.insert("한", .{ .location = 0, .length = 1 }));
    try std.testing.expect(context.setMarked("韓", .{ .location = 1, .length = 0 }, .{ .location = 0, .length = 1 }));
    var committed: [query_limit]u8 = undefined;
    context.copyCommitted(&committed);
    try std.testing.expectEqualStrings("한", committed[0..context.committedLength()]);
    try std.testing.expectEqualStrings("韓", context.text());
    try std.testing.expect(context.reset("a漢z", ""));
    const part = context.substring(.{ .location = 1, .length = std.math.maxInt(u64) }).?;
    try std.testing.expectEqualStrings("漢z", part.bytes);
}

test "inline IME rejects malformed and oversized ranges before touching its projection" {
    var context: Context = .{};
    try std.testing.expect(context.reset("a😀z", ""));
    const original = context;
    for ([_]Range{ .{ .location = 2, .length = 0 }, .{ .location = 99, .length = 1 }, .{ .location = 1, .length = std.math.maxInt(u64) } }) |span| {
        try std.testing.expect(!context.insert("x", span));
        try std.testing.expectEqualStrings(original.text(), context.text());
    }
    try std.testing.expect(!context.insert("\xff", null));
    var oversized: [257]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expect(!context.insert(&oversized, null));
    try std.testing.expect(!context.setMarked("😀", .{ .location = 1, .length = 0 }, null));
    try std.testing.expectEqualStrings(original.text(), context.text());

    // The strict substring primitive rejects surrogate interiors. The input-method
    // adapter above explicitly adjusts them and reports that different actual range.
    for ([_]Range{ .{ .location = 2, .length = 0 }, .{ .location = 1, .length = 1 }, .{ .location = 99, .length = 0 }, .{ .location = std.math.maxInt(u64), .length = 1 } }) |span| {
        try std.testing.expect(context.substring(span) == null);
    }
    const at_end = context.substring(.{ .location = 4, .length = std.math.maxInt(u64) }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", at_end.bytes);
    try std.testing.expectEqual(Range{ .location = 4, .length = 0 }, at_end.actual);
    const clipped = context.substring(.{ .location = 1, .length = std.math.maxInt(u64) }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("😀z", clipped.bytes);
    try std.testing.expectEqual(Range{ .location = 1, .length = 3 }, clipped.actual);

    // The cap itself is legal. Cap+1 must fail without discarding the old marked text or
    // admitting a partial query; testing only rejection could hide a disabled blur path.
    var full: [query_limit]u8 = undefined;
    @memset(&full, 'x');
    try std.testing.expect(context.reset("a", &full));
    const before_blur = context;
    try std.testing.expect(!context.admitMarked());
    try std.testing.expectEqualStrings(before_blur.text(), context.text());
    try std.testing.expectEqual(before_blur.selected, context.selected);
    try std.testing.expectEqual(before_blur.markedRange(), context.markedRange());
    try std.testing.expectEqual(@as(usize, 1), context.committedLength());
    try std.testing.expect(!context.pending);
    try std.testing.expect(context.reset("", &full));
    try std.testing.expect(context.admitMarked());
    try std.testing.expectEqual(query_limit, context.committedLength());
    try std.testing.expect(context.pending and context.marked == null);
    var admitted: [query_limit]u8 = undefined;
    context.copyCommitted(&admitted);
    try std.testing.expectEqualStrings(&full, &admitted);
}

test "inline IME backspace follows replacement caret and cancels only the last inserted scalar" {
    var context: Context = .{};
    try std.testing.expect(context.reset("a😀z", ""));
    try std.testing.expect(context.insert("韓", .{ .location = 1, .length = 2 }));
    try std.testing.expect(context.deleteBackward());
    try std.testing.expectEqualStrings("az", context.text());
    try std.testing.expect(context.insert("a😀", .{ .location = 1, .length = 0 }));
    context.cancelInsertedScalar();
    try std.testing.expectEqualStrings("aaz", context.text());
    try std.testing.expect(context.reset("", ""));
    try std.testing.expect(context.insert("😀", null));
    try std.testing.expect(context.setMarked("ab", .{ .location = 1, .length = 0 }, null));
    context.cancelInsertedScalar();
    try std.testing.expectEqualStrings("ab", context.text());
    try std.testing.expectEqual(Range{ .location = 1, .length = 0 }, context.selectedRange().?);
    try std.testing.expectEqual(Range{ .location = 0, .length = 2 }, context.markedRange().?);
    try std.testing.expect(context.reset("abcd", ""));
    try std.testing.expect(context.insert(context.text()[0..3], .{ .location = 1, .length = 0 }));
    try std.testing.expectEqualStrings("aabcbcd", context.text());
    try std.testing.expect(context.reset("", ""));
    try std.testing.expect(context.insert("😀", null));
    try std.testing.expect(context.setMarked("x", .{ .location = 1, .length = 0 }, .{ .location = 0, .length = 2 }));
    context.cancelInsertedScalar();
    try std.testing.expectEqualStrings("x", context.text());
    try std.testing.expectEqual(@as(usize, 0), context.committedLength());
    try std.testing.expect(context.reset("", ""));
    try std.testing.expect(context.insert("ab", null));
    try std.testing.expect(context.setMarked("😀", .{ .location = 2, .length = 0 }, .{ .location = 0, .length = 1 }));
    context.cancelInsertedScalar();
    try std.testing.expectEqualStrings("😀", context.text());
    try std.testing.expectEqual(Range{ .location = 2, .length = 0 }, context.selectedRange().?);
}
