//! Allocation-free aggregate proof for callback cleanup authorities.
//!
//! Each owner exports only the canonical allocations it will actually free. Mirrors and borrowed
//! views are collapsed by that owner before append. The pump sorts the combined set once and
//! rejects any cross-owner overlap before entering the no-fail commit suffix.

const std = @import("std");

pub const max_ranges: usize = 22_560;

pub const Range = struct {
    start: usize,
    len: usize,
};

pub const Error = error{
    ArithmeticOverflow,
    InvalidRange,
    RangeCapacityExceeded,
    OverlappingAuthority,
};

pub const Scratch = struct {
    ranges: [max_ranges]Range = undefined,
    len: usize = 0,

    pub fn reset(self: *Scratch) void {
        self.len = 0;
    }

    pub fn append(self: *Scratch, start: usize, len: usize) Error!void {
        if (len == 0) return;
        if (start == 0) return error.InvalidRange;
        _ = std.math.add(usize, start, len) catch
            return error.ArithmeticOverflow;
        if (self.len == self.ranges.len) return error.RangeCapacityExceeded;
        self.ranges[self.len] = .{ .start = start, .len = len };
        self.len += 1;
    }

    pub fn validate(
        self: *Scratch,
        forbidden: []const Range,
    ) Error!void {
        for (self.ranges[0..self.len]) |range| {
            const range_end = range.start + range.len;
            for (forbidden) |blocked| {
                if (blocked.len == 0) continue;
                const blocked_end = std.math.add(
                    usize,
                    blocked.start,
                    blocked.len,
                ) catch return error.ArithmeticOverflow;
                if (range.start < blocked_end and blocked.start < range_end)
                    return error.OverlappingAuthority;
            }
        }
        std.mem.sort(Range, self.ranges[0..self.len], {}, lessThan);
        for (self.ranges[1..self.len], self.ranges[0 .. self.len - 1]) |current, prior| {
            const prior_end = prior.start + prior.len;
            if (current.start < prior_end) return error.OverlappingAuthority;
        }
    }
};

fn lessThan(_: void, a: Range, b: Range) bool {
    return a.start < b.start or (a.start == b.start and a.len < b.len);
}

test "aggregate owner ranges reject overlap and forbidden destinations" {
    var scratch: Scratch = .{};
    try scratch.append(0x1000, 8);
    try scratch.append(0x2000, 8);
    try scratch.validate(&.{.{ .start = 0x3000, .len = 8 }});
    scratch.reset();
    try scratch.append(0x1000, 8);
    try scratch.append(0x1004, 8);
    try std.testing.expectError(error.OverlappingAuthority, scratch.validate(&.{}));
}
