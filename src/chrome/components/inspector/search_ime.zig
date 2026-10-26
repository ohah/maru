//! Inspector keeps its fixed buffers and live projected filter. No host or I/O policy lives here.
const std = @import("std");
const shared = @import("../bounded_search_ime.zig");
pub const query_limit = 128;
pub const marked_limit = 128;
pub const State = shared.StateWithLimits(query_limit, marked_limit);
pub const Context = State.Context;
pub const Result = shared.Result;
pub const Key = shared.Key;
pub const Range = shared.Range;
/// Native edits are atomic; legacy paste still owns its UTF-8 prefix truncation policy.
pub fn cleanNative(bytes: []const u8, out: *[query_limit]u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    var n: usize = 0;
    for (bytes) |c| {
        if (c < 32 or c == 127) continue;
        if (n == out.len) return null;
        out[n] = c;
        n += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..n])) return null;
    return out[0..n];
}

/// The OS keeps semantic UTF-16 selection; only the painted caret snaps clusters.
pub fn paintCaret(context: *const Context) usize {
    return @import("../../../grapheme.zig").snapToBoundary(context.text(), @min(context.selected.end, context.text().len));
}

test "inspector search IME model middle replacement keeps suffix and raw NFD" {
    var s: State = .{};
    s.begin("a😀z", "");
    try std.testing.expect(s.insert("가", .{ .location = 1, .length = 2 }));
    try std.testing.expectEqual(Result.commit, s.end(false));
    try std.testing.expectEqualStrings("a가z", s.context.text());
}
test "inspector search IME model internal caret snaps paint without changing UTF16 selection" {
    var s: State = .{};
    s.begin("az", "");
    try std.testing.expect(s.marked("가", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 0 }));
    try std.testing.expectEqual(@as(usize, 1), paintCaret(&s.context));
    try std.testing.expectEqual(@as(usize, 2), s.context.selectedRange().?.location);
}
test "inspector search IME model cancel restores retained word suffix and caret" {
    var s: State = .{};
    s.begin("a😀z", "");
    try std.testing.expect(s.marked("韓", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 2 }));
    try std.testing.expect(s.marked("", .{ .location = 0, .length = 0 }, null));
    try std.testing.expectEqualStrings("a😀z", s.context.text());
    try std.testing.expectEqual(@as(usize, 3), s.context.selectedRange().?.location);
}
test "inspector search IME model commit capacity boundary is atomic" {
    var bytes: [128]u8 = undefined;
    @memset(&bytes, 'a');
    for ([_]usize{ 127, 128 }) |n| {
        var s: State = .{};
        s.begin(bytes[0..n], "");
        try std.testing.expectEqual(n == 127, s.insert("z", null));
        if (n == 128) {
            try std.testing.expectEqual(Result.rollback, s.end(false));
            try std.testing.expectEqualStrings(&bytes, s.context.text());
        }
    }
}
test "inspector search IME model marked cap and blur refusal preserve full preview" {
    var bytes: [129]u8 = undefined;
    @memset(&bytes, 'a');
    for ([_]usize{ 127, 128, 129 }) |n| {
        var s: State = .{};
        s.begin("", "");
        try std.testing.expectEqual(n <= 128, s.marked(bytes[0..n], .{ .location = n, .length = 0 }, null));
    }
    var s: State = .{};
    s.begin("a", "");
    try std.testing.expect(s.marked(bytes[0..128], .{ .location = 128, .length = 0 }, null));
    try std.testing.expect(!s.commitAll());
    try std.testing.expectEqual(@as(usize, 129), s.context.text().len);
    try std.testing.expect(s.marked("", .{ .location = 0, .length = 0 }, null));
    try std.testing.expect(s.commitAll());
    try std.testing.expectEqualStrings("a", s.context.text());
}
test "inspector search IME model invalid ranges never partially mutate" {
    for ([_]Range{ .{ .location = 2, .length = 0 }, .{ .location = 1, .length = 1 }, .{ .location = 99, .length = 0 }, .{ .location = 1, .length = std.math.maxInt(u64) } }) |range| {
        var s: State = .{};
        s.begin("a😀z", "");
        try std.testing.expect(!s.insert("lost", range));
        try std.testing.expectEqual(Result.rollback, s.end(false));
        try std.testing.expectEqualStrings("a😀z", s.context.text());
    }
}
test "inspector search IME model sanitizer preserves Unicode and removes controls" {
    var out: [query_limit]u8 = undefined;
    try std.testing.expectEqualStrings("a가😀", cleanNative("a\r\n\t\x01\x7f가😀", &out).?);
    try std.testing.expectEqualStrings("", cleanNative("\r\n\x00", &out).?);
    try std.testing.expect(cleanNative("\xc2\x00\xa9", &out) == null);
    try std.testing.expect(cleanNative("\xe3\x81", &out) == null);
}
test "inspector search IME model sanitizer capacity cannot silently truncate native text" {
    var out: [query_limit]u8 = undefined;
    var bytes: [129]u8 = undefined;
    @memset(&bytes, 'a');
    try std.testing.expectEqual(@as(usize, 128), cleanNative(bytes[0..128], &out).?.len);
    try std.testing.expect(cleanNative(&bytes, &out) == null);
}
