//! P5c3c-3a1 immutable stdout-frame progress and deadline state.
//!
//! Frame bytes remain owned by `external_ansi.RepaintQueue`; this leaf only seals the clocks and
//! offset that determine replacement eligibility and bounded failure.

const std = @import("std");

pub const progress_timeout_ns: i128 = 10 * std.time.ns_per_s;
pub const absolute_timeout_ns: i128 = 30 * std.time.ns_per_s;

pub const Error = error{
    InvalidClock,
    InvalidLength,
    InvalidProgress,
    AlreadyActive,
    PartialFrame,
    DeadlineOverflow,
};

pub const Progress = struct {
    activation_ns: i128,
    last_progress_ns: ?i128 = null,
    offset: usize = 0,
    len: usize,

    pub fn activate(len: usize, now_ns: i128) Error!Progress {
        if (len == 0) return error.InvalidLength;
        if (now_ns < 0) return error.InvalidClock;
        return .{ .activation_ns = now_ns, .len = len };
    }

    pub fn replaceZeroByte(self: *Progress, len: usize) Error!void {
        if (len == 0) return error.InvalidLength;
        if (self.offset != 0) return error.PartialFrame;
        self.len = len;
    }

    pub fn recordWrite(self: *Progress, bytes: usize, now_ns: i128) Error!bool {
        if (now_ns < (self.last_progress_ns orelse self.activation_ns))
            return error.InvalidClock;
        if (bytes == 0 or bytes > self.len - self.offset) return error.InvalidProgress;
        self.offset += bytes;
        self.last_progress_ns = now_ns;
        return self.offset == self.len;
    }

    pub fn deadline(self: *const Progress) Error!i128 {
        const absolute = std.math.add(i128, self.activation_ns, absolute_timeout_ns) catch
            return error.DeadlineOverflow;
        const last_progress = self.last_progress_ns orelse return absolute;
        const progress = std.math.add(i128, last_progress, progress_timeout_ns) catch
            return error.DeadlineOverflow;
        return @min(progress, absolute);
    }

    pub fn expired(self: *const Progress, now_ns: i128) Error!bool {
        if (now_ns < 0) return error.InvalidClock;
        return now_ns >= try self.deadline();
    }
};

test "p5c3c-3a1 zero-byte replacement inherits the blocked stdout epoch" {
    var progress = try Progress.activate(10, 100);
    try progress.replaceZeroByte(20);
    try std.testing.expectEqual(@as(i128, 100), progress.activation_ns);
    try std.testing.expect(progress.last_progress_ns == null);
    try std.testing.expect(!(try progress.expired(100 + absolute_timeout_ns - 1)));
    try std.testing.expect(try progress.expired(100 + absolute_timeout_ns));
}

test "p5c3c-3a1 partial stdout frame cannot be replaced and progress has exact deadlines" {
    var progress = try Progress.activate(10, 20);
    try std.testing.expect(!(try progress.recordWrite(1, 21)));
    try std.testing.expectError(error.PartialFrame, progress.replaceZeroByte(9));
    try std.testing.expectEqual(@as(i128, 21 + progress_timeout_ns), try progress.deadline());
    try std.testing.expect(!(try progress.expired(21 + progress_timeout_ns - 1)));
    try std.testing.expect(try progress.expired(21 + progress_timeout_ns));
    try std.testing.expect(try progress.recordWrite(9, 22));
}

test "p5c3c-3a1 stdout progress rejects backwards clocks overflow and impossible writes" {
    var progress = try Progress.activate(2, 10);
    try std.testing.expectError(error.InvalidClock, progress.recordWrite(1, 9));
    try std.testing.expectError(error.InvalidProgress, progress.recordWrite(0, 10));
    try std.testing.expectError(error.InvalidProgress, progress.recordWrite(3, 10));
    var overflow = try Progress.activate(1, std.math.maxInt(i128));
    try std.testing.expectError(error.DeadlineOverflow, overflow.deadline());
}
