//! Executable sentinel for the pre-token control authority and post-commit token binding split.

const pump = @import("client_pump");

pub fn main() !void {
    const plan = pump.planRecoverySnapshotBinding(.{ .client_recovery = .{
        .awaiting_snapshot = .{
            .context = .{ .epoch = 5, .deadline_ns = 30 },
            .recovery_barrier_absolute = 11,
        },
    } }, .{
        .origin = .client,
        .recovery_epoch = 5,
        .is_snapshot = true,
        .start_absolute = 11,
        .end_absolute = 12,
        .committed_token_generation = 9,
    });
    if (plan.disposition != .bound or
        plan.next.client_recovery.snapshot_in_flight.expected_token_generation != 9)
        return error.LedgerTokenNotBound;
}
