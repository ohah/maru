//! Bounded settings-search transaction policy. UTF-16 edits stay in the shared
//! projection; the component publishes canonical search/filter changes only at commit.
const std = @import("std");
const input = @import("../../inline_text_input.zig");
pub const query_limit = 64;
pub const marked_limit = 32;
pub const Context = input.BoundedContext(query_limit, marked_limit);
pub const Range = input.Range;
pub const Result = enum { none, commit, rollback };
pub const Key = enum { enter, backspace, other };
pub const Decision = struct { result: Result = .none, consumed: bool };

pub const State = struct {
    context: Context = .{},
    before: ?Context = null,
    in_key: bool = false,
    rejected: bool = false,

    pub fn invalidate(self: *State) void {
        self.* = .{};
    }
    pub fn sync(self: *State, query: []const u8, preedit: []const u8) ?*Context {
        if (self.in_key and self.rejected) return null;
        if (!self.context.matches(query, preedit) and !self.context.reset(query, preedit)) return null;
        return &self.context;
    }
    pub fn begin(self: *State, query: []const u8, preedit: []const u8) void {
        self.finish();
        const context = self.sync(query, preedit) orelse {
            self.in_key = true;
            self.rejected = true;
            return;
        };
        self.before = context.*;
        self.in_key = true;
    }
    pub fn finish(self: *State) void {
        self.before = null;
        self.in_key = false;
        self.rejected = false;
    }
    pub fn insert(self: *State, bytes: []const u8, replacement: ?Range) bool {
        if (self.rejected) return false;
        const before = self.context;
        if (!self.context.insert(bytes, replacement)) {
            self.context = before;
            if (self.in_key) self.rejected = true;
            return false;
        }
        return true;
    }
    pub fn marked(self: *State, bytes: []const u8, selected: Range, replacement: ?Range) bool {
        if (self.rejected) return false;
        const before = self.context;
        if (!self.context.setMarked(bytes, selected, replacement)) {
            self.context = before;
            if (self.in_key) self.rejected = true;
            return false;
        }
        // Clearing a candidate preview restores the retained committed word;
        // deleting the preview bytes alone would erase it from the projection.
        if (bytes.len == 0) if (before.marked) |mark| {
            const suffix = before.len - mark.end;
            const length = before.committed_len;
            _ = self.context.reset(before.committed[0..length], "");
            const at = length - @min(length, suffix);
            self.context.selected = .{ .start = at, .end = at };
            self.context.pending = before.pending;
        };
        return true;
    }
    pub fn end(self: *State, deleted: bool) Result {
        if (self.rejected) {
            if (self.before) |before| self.context = before;
            return .rollback;
        }
        if (!self.context.pending) return .none;
        if (deleted) self.context.cancelInsertedScalar();
        return .commit;
    }
    pub fn finishKey(self: *State, key: ?Key, changed: bool, deleted: bool) Decision {
        const result = self.end(deleted);
        if (result != .none) return .{ .result = result, .consumed = true };
        if (changed) return .{ .consumed = true };
        const value = key orelse return .{ .consumed = true };
        if (value == .enter and self.context.preedit().len > 0) return .{ .consumed = true };
        if (value == .backspace and deleted) {
            return .{ .result = if (self.context.deleteBackward()) .commit else .none, .consumed = true };
        }
        return .{ .consumed = false };
    }
    pub fn commitAll(self: *State) bool {
        return !self.rejected and self.context.admitMarked();
    }
};

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
