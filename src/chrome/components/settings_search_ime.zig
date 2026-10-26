//! Settings capacities remain unchanged while transaction semantics are shared.
const std = @import("std");
const shared = @import("bounded_search_ime.zig");
pub const query_limit = 64;
pub const marked_limit = 32;
pub const State = shared.StateWithLimits(query_limit, marked_limit);
pub const Context = State.Context;
pub const Range = shared.Range;
pub const Result = shared.Result;
pub const Key = shared.Key;
pub const Decision = shared.Decision;

test "settings search IME replacement preserves suffix and commit boundary" {
    var s: State = .{};
    s.begin("a한Z", "");
    try std.testing.expect(s.marked("韓", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 1 }));
    try std.testing.expectEqualStrings("a韓Z", s.context.text());
    try std.testing.expectEqualStrings("a한Z", s.context.base[0..s.context.base_len]);
    try std.testing.expectEqual(Result.none, s.end(false));
    try std.testing.expect(s.insert("韓", null));
    try std.testing.expectEqual(Result.commit, s.end(false));
    try std.testing.expectEqualStrings("a韓Z", s.context.committed[0..s.context.committedLength()]);
}

test "settings search IME rejected later callback rolls back whole key and blocks blur" {
    var s: State = .{};
    s.begin("old", "");
    try std.testing.expect(s.insert("x", null));
    try std.testing.expect(!s.marked("한", .{ .location = 99, .length = 0 }, null));
    try std.testing.expect(!s.commitAll());
    try std.testing.expectEqual(Result.rollback, s.end(false));
    try std.testing.expectEqualStrings("old", s.context.text());
    s.finish();
    s.begin("old", "");
    try std.testing.expect(s.insert("y", null));
    try std.testing.expectEqualStrings("oldy", s.context.text());
}

test "settings search IME malformed range and capacity attacks are atomic" {
    const baseline = "a😀z";
    const bad_ranges = [_]Range{
        .{ .location = 2, .length = 0 },
        .{ .location = 1, .length = 1 },
        .{ .location = 0, .length = 99 },
        .{ .location = std.math.maxInt(u32), .length = 1 },
    };
    for (bad_ranges) |range| {
        var s: State = .{};
        s.begin(baseline, "");
        try std.testing.expect(!s.insert("韓", range));
        try std.testing.expectEqual(Result.rollback, s.end(false));
        try std.testing.expectEqualStrings(baseline, s.context.text());
    }
    var long: [65]u8 = undefined;
    @memset(&long, 'a');
    for ([_]usize{ 63, 64 }) |length| {
        var s: State = .{};
        s.begin(long[0..length], "");
        try std.testing.expectEqual(length == 63, s.insert("z", null));
        if (length == 64) {
            try std.testing.expectEqual(Result.rollback, s.end(false));
            try std.testing.expectEqualStrings(long[0..64], s.context.text());
        }
    }
    for ([_]usize{ 31, 32, 33 }) |length| {
        var s: State = .{};
        s.begin("", "");
        try std.testing.expectEqual(length <= 32, s.marked(long[0..length], .{ .location = 0, .length = 0 }, null));
    }
    var s: State = .{};
    s.begin(long[0..64], "");
    try std.testing.expect(s.marked("가", .{ .location = 1, .length = 0 }, null));
    try std.testing.expect(!s.commitAll());
    try std.testing.expectEqualStrings("가", s.context.preedit());
    try std.testing.expectEqualStrings(long[0..64], s.context.base[0..s.context.base_len]);
    s.finish();
    s.begin("old", "");
    try std.testing.expect(!s.insert("\xff", null));
    try std.testing.expectEqual(Result.rollback, s.end(false));
    try std.testing.expectEqualStrings("old", s.context.text());
}

test "settings search IME NFD survives range projection and scalar deletion" {
    var s: State = .{};
    s.begin("aZ", "");
    const nfd = "\u{1112}\u{1161}\u{11ab}";
    try std.testing.expect(s.insert(nfd, .{ .location = 1, .length = 0 }));
    try std.testing.expectEqualStrings("a" ++ nfd ++ "Z", s.context.text());
    try std.testing.expectEqual(Range{ .location = 4, .length = 0 }, s.context.selectedRange().?);
    try std.testing.expectEqualStrings(nfd, s.context.substring(.{ .location = 1, .length = 3 }).?.bytes);
    try std.testing.expect(s.context.deleteBackward());
    try std.testing.expectEqualStrings("a\u{1112}\u{1161}Z", s.context.text());
}

test "settings search IME empty marked cancellation restores committed word and suffix" {
    var s: State = .{};
    s.begin("a한Z", "");
    try std.testing.expect(s.marked("韓", .{ .location = 1, .length = 0 }, .{ .location = 1, .length = 1 }));
    try std.testing.expect(s.marked("", .{ .location = 0, .length = 0 }, null));
    try std.testing.expectEqualStrings("a한Z", s.context.text());
    try std.testing.expectEqual(Range{ .location = 2, .length = 0 }, s.context.selectedRange().?);
}

test "settings search IME candidate Return is consumed but a later plain Return is not" {
    var s: State = .{};
    s.begin("font", "");
    try std.testing.expect(s.marked("font", .{ .location = 4, .length = 0 }, .{ .location = 0, .length = 4 }));
    try std.testing.expect(s.insert("font", null));
    const candidate = s.finishKey(.enter, true, false);
    try std.testing.expect(candidate.consumed and candidate.result == .commit);
    s.context.accepted("font");
    s.finish();
    s.begin("font", "");
    try std.testing.expect(!s.finishKey(.enter, false, false).consumed);
}
