//! Allocation-free request-ID state shared by the external pump and source-decision leaves.

const std = @import("std");

pub const State = union(enum) {
    available: u64,
    last_available,
    max_consumed,

    pub const SeedError = error{InvalidZero};
    pub const PrepareError = error{ Exhausted, InvalidState };
    pub const CommitError = error{ StaleState, InvalidPrepared };

    pub const Prepared = struct {
        expected: State,
        id: u64,
        next: State,
    };

    pub fn fromNext(next: u64) SeedError!State {
        if (next == 0) return error.InvalidZero;
        if (next == std.math.maxInt(u64)) return .last_available;
        return .{ .available = next };
    }

    pub fn prepare(self: State) PrepareError!Prepared {
        return switch (self) {
            .available => |next| blk: {
                if (next == 0 or next >= std.math.maxInt(u64))
                    return error.InvalidState;
                const following: State = if (next == std.math.maxInt(u64) - 1)
                    .last_available
                else
                    .{ .available = next + 1 };
                break :blk .{ .expected = self, .id = next, .next = following };
            },
            .last_available => .{
                .expected = self,
                .id = std.math.maxInt(u64),
                .next = .max_consumed,
            },
            .max_consumed => error.Exhausted,
        };
    }

    pub fn commit(self: *State, prepared: Prepared) CommitError!void {
        if (!std.meta.eql(self.*, prepared.expected)) return error.StaleState;
        const canonical = self.prepare() catch return error.InvalidPrepared;
        if (!std.meta.eql(canonical, prepared)) return error.InvalidPrepared;
        self.* = prepared.next;
    }
};

test "request ID leaf preserves zero ordinary and maximum boundaries" {
    try std.testing.expectError(error.InvalidZero, State.fromNext(0));
    var ordinary = try State.fromNext(1);
    const prepared = try ordinary.prepare();
    try std.testing.expectEqual(@as(u64, 1), prepared.id);
    try ordinary.commit(prepared);
    try std.testing.expect(std.meta.eql(
        ordinary,
        State{ .available = 2 },
    ));

    var maximum = try State.fromNext(std.math.maxInt(u64));
    const last = try maximum.prepare();
    try std.testing.expectEqual(std.math.maxInt(u64), last.id);
    try maximum.commit(last);
    try std.testing.expect(maximum == .max_consumed);
    try std.testing.expectError(error.Exhausted, maximum.prepare());
}
