//! Public attach pre-raw phase budget.
//!
//! This leaf owns only the semantic phase label and the transport's one monotonic absolute
//! deadline. It deliberately exposes no reset/extend operation: candidate probes, retries and
//! every request in a phase must carry the same value down to `Client`.

const std = @import("std");
const client_deadline = @import("client_deadline.zig");

pub const budget_ns: i128 = 5 * std.time.ns_per_s;

pub const Kind = enum {
    resolve,
    connect_hello,
    attach_snapshot,
    status_takeover,
};

pub const Error = error{ InvalidDeadline, WrongPhase };

pub const PhaseDeadline = struct {
    kind: Kind,
    absolute: client_deadline.AbsoluteDeadline,

    pub fn start(io: std.Io, kind: Kind) Error!PhaseDeadline {
        return .{
            .kind = kind,
            .absolute = client_deadline.AbsoluteDeadline.after(io, budget_ns) catch
                return error.InvalidDeadline,
        };
    }

    /// Test seam and the only way to carry an injected clock. The wrapper never manufactures a
    /// second deadline from this value.
    pub fn fromAbsolute(kind: Kind, absolute: client_deadline.AbsoluteDeadline) PhaseDeadline {
        return .{ .kind = kind, .absolute = absolute };
    }

    pub fn require(self: PhaseDeadline, expected: Kind) Error!client_deadline.AbsoluteDeadline {
        if (self.kind != expected) return error.WrongPhase;
        return self.absolute;
    }
};

test "attach phase deadline preserves kind and one absolute deadline" {
    const ClockFixture = struct {
        now: i128,

        fn read(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now;
        }
    };
    var clock = ClockFixture{ .now = 41 };
    const absolute = client_deadline.AbsoluteDeadline.fromInjected(
        .{ .context = &clock, .now_ns = ClockFixture.read },
        99,
    );
    const phase = PhaseDeadline.fromAbsolute(.resolve, absolute);

    try std.testing.expectError(error.WrongPhase, phase.require(.connect_hello));
    try std.testing.expectEqual(@as(i128, 58), (try phase.require(.resolve)).remainingNs());
    clock.now = 99;
    try std.testing.expectEqual(@as(i128, 0), (try phase.require(.resolve)).remainingNs());
}
