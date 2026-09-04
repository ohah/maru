//! Non-extendable monotonic deadline shared by an entire release adapter phase.

const std = @import("std");
const c = std.c;

pub const Error = error{
    InvalidOwner,
    InvalidBudget,
    ClockFailed,
    TimedOut,
};

pub const Deadline = struct {
    owner: ?*Deadline = null,
    started_ns: i128 = 0,
    expires_ns: i128 = 0,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.started_ns == 0 and self.expires_ns == 0;
    }

    pub fn remaining(self: *@This()) Error!i128 {
        var clock = RealClock{};
        return self.remainingWith(&clock) catch |err| switch (err) {
            error.InvalidOwner => error.InvalidOwner,
            error.ClockFailed => error.ClockFailed,
            error.TimedOut => error.TimedOut,
            else => error.ClockFailed,
        };
    }

    pub fn remainingWith(self: *@This(), clock: anytype) !i128 {
        if (self.owner != self or self.expires_ns <= self.started_ns)
            return error.InvalidOwner;
        const now = try clock.now();
        if (now < self.started_ns) return error.ClockFailed;
        if (now >= self.expires_ns) return error.TimedOut;
        return self.expires_ns - now;
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.expires_ns <= self.started_ns)
            return error.InvalidOwner;
        self.* = .{};
    }
};

const RealClock = struct {
    fn now(_: *@This()) Error!i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0)
            return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};

pub fn start(budget_ns: i128, result: *Deadline) Error!void {
    var clock = RealClock{};
    return startWith(&clock, budget_ns, result) catch |err| switch (err) {
        error.InvalidOwner => error.InvalidOwner,
        error.InvalidBudget => error.InvalidBudget,
        error.ClockFailed => error.ClockFailed,
        else => error.ClockFailed,
    };
}

pub fn startWith(clock: anytype, budget_ns: i128, result: *Deadline) !void {
    if (result.owner != null or result.started_ns != 0 or result.expires_ns != 0)
        return error.InvalidOwner;
    if (budget_ns <= 0) return error.InvalidBudget;
    const started = try clock.now();
    if (started < 0) return error.ClockFailed;
    const expires = std.math.add(i128, started, budget_ns) catch
        return error.InvalidBudget;
    if (expires <= started) return error.InvalidBudget;
    result.started_ns = started;
    result.expires_ns = expires;
    result.owner = result;
}
