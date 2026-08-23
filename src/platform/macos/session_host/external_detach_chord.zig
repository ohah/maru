//! P5c3c-3a1 local detach-chord reducer.
//!
//! This leaf owns no fd, allocator, Client, or clock callback. The event-loop owner supplies one
//! monotonic timestamp per action and applies the returned bounded forwarding decision.

const std = @import("std");

pub const prefix: u8 = 0x1c;
pub const detach_byte: u8 = 'd';
pub const timeout_ns: i128 = std.time.ns_per_s;

pub const Role = enum { controller, observer };
pub const Error = error{ InvalidClock, DeadlineOverflow };

pub const Decision = struct {
    forward: [2]u8 = undefined,
    forward_len: u2 = 0,
    detached: bool = false,
    suppressed: bool = false,

    pub fn bytes(self: *const Decision) []const u8 {
        return self.forward[0..self.forward_len];
    }
};

const State = union(enum) {
    idle,
    prefix_wait: i128,
};

pub const Reducer = struct {
    role: Role,
    state: State = .idle,

    pub fn init(role: Role) Reducer {
        return .{ .role = role };
    }

    pub fn feed(self: *Reducer, byte: u8, now_ns: i128) Error!Decision {
        if (now_ns < 0) return error.InvalidClock;
        return switch (self.state) {
            .idle => if (byte == prefix) blk: {
                self.state = .{ .prefix_wait = now_ns };
                break :blk .{};
            } else self.forwardDecision(&.{byte}),
            .prefix_wait => |started| blk: {
                const deadline = std.math.add(i128, started, timeout_ns) catch
                    return error.DeadlineOverflow;
                if (now_ns >= deadline) return error.InvalidClock;
                self.state = .idle;
                if (byte == detach_byte) break :blk .{ .detached = true };
                if (byte == prefix) break :blk self.forwardDecision(&.{prefix});
                break :blk self.forwardDecision(&.{ prefix, byte });
            },
        };
    }

    pub fn expire(self: *Reducer, now_ns: i128) Error!?Decision {
        if (now_ns < 0) return error.InvalidClock;
        return switch (self.state) {
            .idle => null,
            .prefix_wait => |started| blk: {
                const deadline = std.math.add(i128, started, timeout_ns) catch
                    return error.DeadlineOverflow;
                if (now_ns < deadline) break :blk null;
                self.state = .idle;
                break :blk self.forwardDecision(&.{prefix});
            },
        };
    }

    pub fn inputEof(self: *Reducer) void {
        self.state = .idle;
    }

    pub fn nextDeadline(self: *const Reducer) Error!?i128 {
        return switch (self.state) {
            .idle => null,
            .prefix_wait => |started| std.math.add(i128, started, timeout_ns) catch
                return error.DeadlineOverflow,
        };
    }

    fn forwardDecision(self: *const Reducer, bytes_: []const u8) Decision {
        if (self.role == .observer) return .{ .suppressed = bytes_.len != 0 };
        var decision = Decision{};
        @memcpy(decision.forward[0..bytes_.len], bytes_);
        decision.forward_len = @intCast(bytes_.len);
        return decision;
    }
};

test "p5c3c-3a1 detach chord forwards exact controller byte sequences" {
    var reducer = Reducer.init(.controller);
    try std.testing.expectEqualSlices(u8, "x", (try reducer.feed('x', 0)).bytes());
    try std.testing.expectEqual(@as(?i128, timeout_ns), blk: {
        _ = try reducer.feed(prefix, 0);
        break :blk try reducer.nextDeadline();
    });
    try std.testing.expect((try reducer.feed(detach_byte, timeout_ns - 1)).detached);
    _ = try reducer.feed(prefix, 2 * timeout_ns);
    try std.testing.expectEqualSlices(u8, &.{prefix}, (try reducer.feed(prefix, 2 * timeout_ns + 1)).bytes());
    _ = try reducer.feed(prefix, 3 * timeout_ns);
    try std.testing.expectEqualSlices(u8, &.{ prefix, 'q' }, (try reducer.feed('q', 3 * timeout_ns + 1)).bytes());
}

test "p5c3c-3a1 detach chord deadline is exact and EOF drops a lone prefix" {
    var reducer = Reducer.init(.controller);
    _ = try reducer.feed(prefix, 7);
    try std.testing.expect((try reducer.expire(7 + timeout_ns - 1)) == null);
    try std.testing.expectEqualSlices(u8, &.{prefix}, (try reducer.expire(7 + timeout_ns)).?.bytes());
    _ = try reducer.feed(prefix, 9 + timeout_ns);
    reducer.inputEof();
    try std.testing.expect((try reducer.expire(20 + timeout_ns)) == null);
}

test "p5c3c-3a1 observer suppresses non-chord input but still detaches locally" {
    var reducer = Reducer.init(.observer);
    try std.testing.expect((try reducer.feed('x', 0)).suppressed);
    _ = try reducer.feed(prefix, 1);
    try std.testing.expect((try reducer.feed('q', 2)).suppressed);
    _ = try reducer.feed(prefix, 3);
    try std.testing.expect((try reducer.feed(detach_byte, 4)).detached);
}
