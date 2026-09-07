//! Protected profile to signed upgrade execution composition contract.

const std = @import("std");
const predecessor = @import("release_adapter_profile_predecessor_authority");
const runner = @import("release_adapter_candidate_upgrade_runner");
const deadline = @import("release_adapter_deadline");
const composition = @import("release_adapter_profile_upgrade_execution");

test "profile execution owns deadline predecessor authority runner and timing" {
    var result: composition.ProfileUpgradeExecution = .{};
    try std.testing.expect(@TypeOf(result.deadline) == deadline.Deadline);
    try std.testing.expect(@TypeOf(result.predecessor) == predecessor.AuthenticatedPredecessor);
    try std.testing.expect(@TypeOf(result.execution) == runner.Execution);
    try std.testing.expect(@TypeOf(result.timing) == composition.TimingDiagnostic);
    try std.testing.expect(result.isPristineForComposition());
}

test "caller cannot submit predecessor evidence or git observations" {
    inline for (.{ "predecessor", "authenticated", "held_manifest", "assets", "ref", "tags", "runtime_count" }) |name|
        try std.testing.expect(!@hasField(composition.Inputs, name));
}

test "timing requires positive nested intervals and a containing profile phase" {
    const runner_timing: runner.TimingDiagnostic = .{ .success = true, .signed_one_ns = 10, .signed_near_max_ns = 20, .phase_ns = 40 };
    const measured = try composition.timingForTest(30, runner_timing, 100, 180);
    try std.testing.expect(measured.success);
    try std.testing.expectEqual(@as(u64, 80), measured.profile_phase_ns);
    try std.testing.expectError(error.InvalidTiming, composition.timingForTest(0, runner_timing, 100, 180));
    try std.testing.expectError(error.InvalidTiming, composition.timingForTest(30, runner_timing, 100, 169));
}

test "production surface exposes run cleanup and retry only" {
    _ = &composition.run;
    _ = &composition.ProfileUpgradeExecution.cleanup;
    _ = &composition.retryCleanup;
}
