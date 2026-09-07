//! Protected profile to signed upgrade execution composition contract.

const std = @import("std");
const predecessor = @import("release_adapter_profile_predecessor_authority");
const runner = @import("release_adapter_candidate_upgrade_runner");
const deadline = @import("release_adapter_deadline");
const composition = @import("release_adapter_profile_upgrade_execution");

const Step = enum { preflight, deadline_start, predecessor, predecessor_revalidate, runner, final_revalidate, final_deadline, success, cleanup_runner, cleanup_predecessor, cleanup_deadline };

const Operations = struct {
    steps: [32]Step = undefined,
    len: usize = 0,
    fail_at: usize = 0,
    cleanup_fail: ?Step = null,

    fn record(self: *@This(), step: Step) !void {
        self.steps[self.len] = step;
        self.len += 1;
        if (self.fail_at == self.len) return error.ChildFailed;
    }
    pub fn preflight(self: *@This(), result: *const composition.ProfileUpgradeExecution) !void {
        try self.record(.preflight);
        if (!result.isPristineForComposition()) return error.InvalidOwner;
    }
    pub fn startDeadline(self: *@This(), _: i128, result: *deadline.Deadline) !void {
        try self.record(.deadline_start);
        result.* = .{ .owner = result, .started_ns = 1, .expires_ns = 1000 };
    }
    pub fn authenticatePredecessor(self: *@This(), _: *deadline.Deadline, result: *predecessor.AuthenticatedPredecessor) !void {
        try self.record(.predecessor);
        result.owner = result;
    }
    pub fn revalidatePredecessor(self: *@This(), _: *deadline.Deadline, _: *const predecessor.AuthenticatedPredecessor) !void {
        try self.record(.predecessor_revalidate);
    }
    pub fn runSigned(self: *@This(), _: *deadline.Deadline, _: *predecessor.AuthenticatedPredecessor, result: *runner.Execution) !void {
        try self.record(.runner);
        result.owner = result;
        result.timing = .{ .success = true, .signed_one_ns = 10, .signed_near_max_ns = 20, .phase_ns = 40 };
    }
    pub fn revalidateFinal(self: *@This(), _: *deadline.Deadline, _: *const predecessor.AuthenticatedPredecessor, _: *const runner.Execution) !void {
        try self.record(.final_revalidate);
    }
    pub fn finalDeadline(self: *@This(), _: *deadline.Deadline) !void {
        try self.record(.final_deadline);
    }
    pub fn validateSuccess(self: *@This(), _: *const predecessor.AuthenticatedPredecessor, _: *const runner.Execution) !void {
        try self.record(.success);
    }
    pub fn cleanupExecution(self: *@This(), result: *runner.Execution) !void {
        try self.record(.cleanup_runner);
        if (self.cleanup_fail == .cleanup_runner) return error.CleanupChildFailed;
        result.* = .{};
    }
    pub fn cleanupPredecessor(self: *@This(), result: *predecessor.AuthenticatedPredecessor) !void {
        try self.record(.cleanup_predecessor);
        if (self.cleanup_fail == .cleanup_predecessor) return error.CleanupChildFailed;
        result.* = .{};
    }
    pub fn cleanupDeadline(self: *@This(), result: *deadline.Deadline) !void {
        try self.record(.cleanup_deadline);
        if (self.cleanup_fail == .cleanup_deadline) return error.CleanupChildFailed;
        result.* = .{};
    }
};

const Clock = struct {
    values: [3]i128 = .{ 100, 130, 180 },
    index: usize = 0,
    fail_at: usize = 0,
    pub fn now(self: *@This()) !i128 {
        const call = self.index + 1;
        if (self.fail_at == call) return error.ClockFailed;
        if (self.index == self.values.len) return error.ClockFailed;
        defer self.index += 1;
        return self.values[self.index];
    }
};

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

test "one deadline orders predecessor runner retained evidence and measured publication" {
    var operations = Operations{};
    var clock = Clock{};
    var result: composition.ProfileUpgradeExecution = .{};
    try composition.runWith(&operations, &clock, 1000, &result);
    try std.testing.expectEqualSlices(Step, &.{ .preflight, .deadline_start, .predecessor, .predecessor_revalidate, .runner, .final_revalidate, .success, .final_deadline }, operations.steps[0..operations.len]);
    try std.testing.expect(result.timing.success);
    try std.testing.expectEqual(@as(u64, 30), result.timing.predecessor_auth_ns);
    try std.testing.expectEqual(@as(u64, 80), result.timing.profile_phase_ns);
}

test "every orchestration failure cleans runner predecessor and deadline in order" {
    inline for (3..9) |fail_at| {
        var operations = Operations{ .fail_at = fail_at };
        var clock = Clock{};
        var result: composition.ProfileUpgradeExecution = .{};
        try std.testing.expectError(error.ChildFailed, composition.runWith(&operations, &clock, 1000, &result));
        try std.testing.expect(result.isPristineForComposition());
        try std.testing.expectEqualSlices(Step, &.{ .cleanup_runner, .cleanup_predecessor, .cleanup_deadline }, operations.steps[operations.len - 3 .. operations.len]);
    }
}

test "preownership failures publish no owner and perform no cleanup" {
    inline for (1..3) |fail_at| {
        var operations = Operations{ .fail_at = fail_at };
        var clock = Clock{};
        var result: composition.ProfileUpgradeExecution = .{};
        try std.testing.expectError(error.ChildFailed, composition.runWith(&operations, &clock, 1000, &result));
        try std.testing.expect(result.isPristineForComposition());
        for (operations.steps[0..operations.len]) |step| {
            try std.testing.expect(step != .cleanup_runner and step != .cleanup_predecessor and step != .cleanup_deadline);
        }
    }
}

test "clock failure at every measurement fence cleans all owned state" {
    inline for (1..4) |fail_at| {
        var operations = Operations{};
        var clock = Clock{ .fail_at = fail_at };
        var result: composition.ProfileUpgradeExecution = .{};
        try std.testing.expectError(error.ClockFailed, composition.runWith(&operations, &clock, 1000, &result));
        try std.testing.expect(result.isPristineForComposition());
        try std.testing.expectEqualSlices(Step, &.{ .cleanup_runner, .cleanup_predecessor, .cleanup_deadline }, operations.steps[operations.len - 3 .. operations.len]);
    }
}

test "cleanup uncertainty preserves owner and retry finishes every child" {
    var operations = Operations{ .fail_at = 6, .cleanup_fail = .cleanup_runner };
    var clock = Clock{};
    var result: composition.ProfileUpgradeExecution = .{};
    try std.testing.expectError(error.CleanupFailed, composition.runWith(&operations, &clock, 1000, &result));
    try std.testing.expect(result.owner == &result);
    try std.testing.expect(result.execution.owner == &result.execution);
    try std.testing.expect(result.predecessor.isPristineForComposition());
    try std.testing.expect(result.deadline.isPristineForComposition());

    operations.cleanup_fail = null;
    try composition.retryCleanupWith(&operations, &result);
    try std.testing.expect(result.isPristineForComposition());
}
