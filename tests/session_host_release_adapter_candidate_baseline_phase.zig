//! Baseline-A signed leaf ordering is tested independently from leaf semantics.

const std = @import("std");
const phase = @import("release_adapter_candidate_baseline_phase");

const Event = enum {
    deadline,
    validate_initial_candidate,
    default_false,
    validate_after_default,
    signed_app_quit,
    validate_after_quit,
    evidence,
    validate_final_candidate,
    validate_final_deadline,
    cleanup_evidence,
    cleanup_signed_app_quit,
    cleanup_default_false,
};

const setup = [_]Event{
    .deadline,
    .validate_initial_candidate,
    .default_false,
    .validate_after_default,
    .signed_app_quit,
    .validate_after_quit,
    .evidence,
    .validate_final_candidate,
    .validate_final_deadline,
};

const Recorder = struct {
    events: [32]Event = undefined,
    len: usize = 0,
    calls: usize = 0,
    fail_call: ?usize = null,
    fail_cleanup: ?Event = null,
    deadline_storage: u8 = 0,

    fn add(self: *@This(), event: Event) !void {
        self.events[self.len] = event;
        self.len += 1;
        if (@intFromEnum(event) <= @intFromEnum(Event.validate_final_deadline)) {
            const index = self.calls;
            self.calls += 1;
            if (self.fail_call == index) return error.StepFailed;
        }
        if (self.fail_cleanup == event) return error.CleanupFailed;
    }

    fn same(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline_storage, deadline);
    }

    pub fn startDeadline(self: *@This()) !*u8 {
        try self.add(.deadline);
        return &self.deadline_storage;
    }
    pub fn runDefaultFalse(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.default_false);
    }
    pub fn validateInitialCandidate(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_initial_candidate);
    }
    pub fn validateCandidateAfterDefault(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_after_default);
    }
    pub fn runSignedAppQuit(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.signed_app_quit);
    }
    pub fn validateCandidateAfterQuit(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_after_quit);
    }
    pub fn publishEvidence(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.evidence);
    }
    pub fn validateFinalCandidate(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_final_candidate);
    }
    pub fn validateFinalDeadline(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_final_deadline);
    }
    pub fn cleanupEvidence(self: *@This()) !void {
        try self.add(.cleanup_evidence);
    }
    pub fn cleanupSignedAppQuit(self: *@This()) !void {
        try self.add(.cleanup_signed_app_quit);
    }
    pub fn cleanupDefaultFalse(self: *@This()) !void {
        try self.add(.cleanup_default_false);
    }
};

test "success uses one deadline and preserves all three outputs" {
    var recorder = Recorder{};
    try phase.runWith(&recorder);
    try std.testing.expectEqualSlices(Event, &setup, recorder.events[0..recorder.len]);
}

test "failure-pristine deadline and every later failure clean attempted outputs in reverse" {
    const cleanup_by_call = [_][]const Event{
        &.{},
        &.{},
        &.{.cleanup_default_false},
        &.{.cleanup_default_false},
        &.{ .cleanup_signed_app_quit, .cleanup_default_false },
        &.{ .cleanup_signed_app_quit, .cleanup_default_false },
        &.{ .cleanup_evidence, .cleanup_signed_app_quit, .cleanup_default_false },
        &.{ .cleanup_evidence, .cleanup_signed_app_quit, .cleanup_default_false },
        &.{ .cleanup_evidence, .cleanup_signed_app_quit, .cleanup_default_false },
    };
    for (0..setup.len) |fail_index| {
        var recorder = Recorder{ .fail_call = fail_index };
        try std.testing.expectError(error.StepFailed, phase.runWith(&recorder));
        const expected = cleanup_by_call[fail_index];
        try std.testing.expectEqualSlices(Event, expected, recorder.events[recorder.len - expected.len .. recorder.len]);
    }
}

test "cleanup failure is terminal and later cleanup still runs" {
    var recorder = Recorder{ .fail_call = 6, .fail_cleanup = .cleanup_signed_app_quit };
    try std.testing.expectError(error.CleanupFailed, phase.runWith(&recorder));
    try std.testing.expect(std.mem.indexOfScalar(Event, recorder.events[0..recorder.len], .evidence) != null);
    try std.testing.expectEqualSlices(
        Event,
        &.{ .cleanup_evidence, .cleanup_signed_app_quit, .cleanup_default_false },
        recorder.events[recorder.len - 3 .. recorder.len],
    );
}

test "candidate is revalidated between leaves and after aggregate publication" {
    var recorder = Recorder{};
    try phase.runWith(&recorder);
    try std.testing.expectEqualSlices(Event, &setup, recorder.events[0..recorder.len]);
    try std.testing.expectEqual(@as(usize, 9), recorder.calls);
}
