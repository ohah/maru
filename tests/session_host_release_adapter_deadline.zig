const std = @import("std");
const deadline_mod = @import("release_adapter_deadline");

const Clock = struct {
    values: []const i128,
    index: usize = 0,
    pub fn now(self: *@This()) !i128 {
        if (self.index >= self.values.len) return error.ClockExhausted;
        const value = self.values[self.index];
        self.index += 1;
        return value;
    }
};

test "one absolute expiry yields non-increasing remaining time" {
    var clock = Clock{ .values = &.{ 100, 101, 101, 130, 199 } };
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.startWith(&clock, 100, &deadline);
    try std.testing.expectEqual(@as(i128, 99), try deadline.remainingWith(&clock));
    try std.testing.expectEqual(@as(i128, 99), try deadline.remainingWith(&clock));
    try std.testing.expectEqual(@as(i128, 70), try deadline.remainingWith(&clock));
    try std.testing.expectEqual(@as(i128, 1), try deadline.remainingWith(&clock));
    try deadline.deinit();
}

test "exact expiry and later observations time out without extension" {
    var clock = Clock{ .values = &.{ 10, 20, 21 } };
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.startWith(&clock, 10, &deadline);
    try std.testing.expectError(error.TimedOut, deadline.remainingWith(&clock));
    try std.testing.expectError(error.TimedOut, deadline.remainingWith(&clock));
    try deadline.deinit();
}

test "zero negative overflow and rollback fail closed" {
    var zero_clock = Clock{ .values = &.{0} };
    var deadline: deadline_mod.Deadline = .{};
    try std.testing.expectError(error.InvalidBudget, deadline_mod.startWith(&zero_clock, 0, &deadline));
    try std.testing.expectError(error.InvalidBudget, deadline_mod.startWith(&zero_clock, -1, &deadline));
    var overflow_clock = Clock{ .values = &.{std.math.maxInt(i128)} };
    try std.testing.expectError(error.InvalidBudget, deadline_mod.startWith(&overflow_clock, 1, &deadline));
    var rollback_clock = Clock{ .values = &.{ 100, 99 } };
    try deadline_mod.startWith(&rollback_clock, 10, &deadline);
    try std.testing.expectError(error.ClockFailed, deadline.remainingWith(&rollback_clock));
    try deadline.deinit();
}

test "copied pre-owned and empty owners expose no deadline" {
    var clock = Clock{ .values = &.{ 5, 6 } };
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.startWith(&clock, 10, &deadline);
    var copied = deadline;
    try std.testing.expectError(error.InvalidOwner, copied.remainingWith(&clock));
    var occupied: deadline_mod.Deadline = .{};
    occupied.owner = &occupied;
    try std.testing.expectError(error.InvalidOwner, deadline_mod.startWith(&clock, 10, &occupied));
    try deadline.deinit();
    try std.testing.expectError(error.InvalidOwner, deadline.remainingWith(&clock));
}

test "real monotonic product leaf is compiled" {
    _ = deadline_mod.start;
    _ = deadline_mod.Deadline.remaining;
}
