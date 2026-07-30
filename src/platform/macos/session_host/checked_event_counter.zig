//! Saturating event-generation transition shared by session-host quarantine owners.
//!
//! A counter value is both the durable latch (`value != 0`) and the generation returned to a
//! receipt. Keeping overflow and CAS retry semantics in this neutral leaf prevents two owners from
//! assigning different meanings to the same process-global counter.

const std = @import("std");

pub fn increment(counter: *std.atomic.Value(u64)) ?u64 {
    var observed = counter.load(.acquire);
    while (true) {
        if (observed == std.math.maxInt(u64)) return null;
        if (counter.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        return observed + 1;
    }
}

test "checked event counter increments and rejects saturation without wrapping" {
    var counter: std.atomic.Value(u64) = .init(0);
    try std.testing.expectEqual(@as(?u64, 1), increment(&counter));
    try std.testing.expectEqual(@as(u64, 1), counter.load(.acquire));
    counter.store(std.math.maxInt(u64), .release);
    try std.testing.expectEqual(@as(?u64, null), increment(&counter));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        counter.load(.acquire),
    );
}
