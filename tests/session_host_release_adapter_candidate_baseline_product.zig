//! Product ownership around the closed baseline phase is independent from live AppKit execution.

const std = @import("std");
const product = @import("release_adapter_candidate_baseline_product");

const Event = enum {
    bind,
    validate_initial,
    default_false,
    validate_after_default,
    signed_app_quit,
    validate_after_quit,
    evidence,
    validate_final,
    deadline_final,
    cleanup_evidence,
    cleanup_quit,
    cleanup_default,
};

const expected_success = [_]Event{
    .bind,
    .validate_initial,
    .default_false,
    .validate_after_default,
    .signed_app_quit,
    .validate_after_quit,
    .evidence,
    .validate_final,
    .deadline_final,
};

const Recorder = struct {
    events: [24]Event = undefined,
    len: usize = 0,
    fail: ?Event = null,
    cleanup_fail: ?Event = null,
    cleanup_fail_also: ?Event = null,
    deadline: u8 = 0,

    fn add(self: *@This(), event: Event) !void {
        self.events[self.len] = event;
        self.len += 1;
        if (self.fail == event or self.cleanup_fail == event or self.cleanup_fail_also == event) return error.Injected;
    }

    pub fn bindCandidate(self: *@This()) !void {
        try self.add(.bind);
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        return &self.deadline;
    }
    fn same(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
    }
    pub fn validateInitialCandidate(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_initial);
    }
    pub fn runDefaultFalse(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.default_false);
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
        try self.add(.validate_final);
    }
    pub fn validateFinalDeadline(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.deadline_final);
    }
    pub fn cleanupEvidence(self: *@This()) !void {
        try self.add(.cleanup_evidence);
    }
    pub fn cleanupSignedAppQuit(self: *@This()) !void {
        try self.add(.cleanup_quit);
    }
    pub fn cleanupDefaultFalse(self: *@This()) !void {
        try self.add(.cleanup_default);
    }
};

test "final-address product owner binds before one shared baseline phase" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{};
    try product.executeWith(&recorder, &execution);
    try std.testing.expectEqualSlices(Event, &expected_success, recorder.events[0..recorder.len]);
    try std.testing.expect(execution.ownsSuccessfulChildren());
}

test "copied or preowned execution is rejected before candidate binding" {
    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    var recorder: Recorder = .{};
    try std.testing.expectError(error.InvalidOwner, product.executeWith(&recorder, &copied));
    try std.testing.expectEqual(@as(usize, 0), recorder.len);
    try std.testing.expectError(error.InvalidOwner, product.executeWith(&recorder, &original));
    try std.testing.expectEqual(@as(usize, 0), recorder.len);
}

test "candidate drift unwinds only attempted children in reverse" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{ .fail = .validate_after_quit };
    try std.testing.expectError(error.Injected, product.executeWith(&recorder, &execution));
    try std.testing.expectEqualSlices(Event, &.{ .cleanup_quit, .cleanup_default }, recorder.events[recorder.len - 2 .. recorder.len]);
    try std.testing.expect(execution.owner == null);
}

test "cleanup failure retains exact execution for explicit retry" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{ .fail = .evidence, .cleanup_fail = .cleanup_quit };
    try std.testing.expectError(error.CleanupFailed, product.executeWith(&recorder, &execution));
    try std.testing.expect(execution.owner == &execution);
    try std.testing.expect(execution.needsCleanup());
    recorder.cleanup_fail = null;
    try product.retryCleanupWith(&recorder, &execution);
    try std.testing.expect(execution.owner == null);
}

test "multiple cleanup failures retain every failed child and still clean later children" {
    var execution: product.Execution = .{};
    var recorder: Recorder = .{ .fail = .deadline_final, .cleanup_fail = .cleanup_evidence, .cleanup_fail_also = .cleanup_quit };
    try std.testing.expectError(error.CleanupFailed, product.executeWith(&recorder, &execution));
    recorder.cleanup_fail = .cleanup_evidence;
    recorder.cleanup_fail_also = .cleanup_quit;
    try std.testing.expectError(error.CleanupFailed, product.retryCleanupWith(&recorder, &execution));
    try std.testing.expect(execution.evidence_attempted);
    try std.testing.expect(execution.signed_app_quit_attempted);
    try std.testing.expect(!execution.default_false_attempted);
    recorder.cleanup_fail = null;
    recorder.cleanup_fail_also = null;
    try product.retryCleanupWith(&recorder, &execution);
    try std.testing.expect(execution.owner == null);
}

test "candidate root derives app main CLI and isolated children without caller executable paths" {
    var paths: product.PathStorage = .{};
    const view = try product.derivePaths("/private/tmp/candidate", "/private/tmp/release-work", &paths);
    try std.testing.expectEqualStrings("/private/tmp/candidate/Maru.app", view.app_bundle);
    try std.testing.expectEqualStrings("/private/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app", view.app_executable);
    try std.testing.expectEqualStrings("/private/tmp/candidate/Maru.app/Contents/MacOS/maru", view.cli_executable);
    try std.testing.expect(!std.mem.eql(u8, view.default_false_root, view.signed_app_quit_root));
    try std.testing.expectError(error.InvalidPath, product.derivePaths("relative", "/private/tmp/release-work", &paths));
    try std.testing.expectError(error.InvalidPath, product.derivePaths("/private/tmp/candidate", "/private/tmp/candidate", &paths));
    try std.testing.expectError(error.InvalidPath, product.derivePaths("/private/tmp/candidate", "/private/tmp/candidate/work", &paths));
    try std.testing.expectError(error.InvalidPath, product.derivePaths("/private/tmp/release-work/candidate", "/private/tmp/release-work", &paths));
    try std.testing.expectError(error.InvalidPath, product.derivePaths("/private/tmp/../tmp/candidate", "/private/tmp/release-work", &paths));

    var aliased: product.PathStorage = .{};
    const candidate = "/private/tmp/candidate";
    @memcpy(aliased.app_bundle[0..candidate.len], candidate);
    try std.testing.expectError(
        error.InvalidPath,
        product.derivePaths(aliased.app_bundle[0..candidate.len], "/private/tmp/release-work", &aliased),
    );
}
