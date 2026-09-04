const std = @import("std");
const phase = @import("release_adapter_candidate_release_phase");

test "candidate release owns exact phase order on one borrowed deadline" {
    std.testing.refAllDecls(phase);
    var deadline: u8 = 0;
    var steps = Steps{};
    var release: phase.Release = .{};
    try phase.executeWith(&steps, &deadline, &release);
    try std.testing.expect(release.ownsCompleteRelease());
    try std.testing.expectEqualStrings("preflight,fence,prerequisite,fence,baseline,fence,publication,fence", steps.log());
    try std.testing.expectEqual(@as(usize, 4), steps.deadline_observations);
}

test "pre-owned copied and preflight-mutated release run no phases" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var release: phase.Release = .{};
    release.owner = &release;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &release));
    var copied = release;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &copied));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
    release = .{};
    steps = .{ .mutate_preflight = true };
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &release));
    try std.testing.expect(release.isPristineForComposition());
    try std.testing.expectEqualStrings("preflight", steps.log());
}

test "pre-draft prerequisite failure returns pristine" {
    var deadline: u8 = 0;
    inline for (.{ Point.initial_fence, Point.prerequisite_local }) |point| {
        var steps = Steps{ .fail_at = point };
        var release: phase.Release = .{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &deadline, &release));
        try std.testing.expect(release.isPristineForComposition());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
    }
}

test "pre-draft prerequisite cleanup failure preserves exact retry owner" {
    var deadline: u8 = 0;
    var steps = Steps{ .fail_at = .prerequisite_cleanup };
    var release: phase.Release = .{};
    try std.testing.expectError(error.CleanupFailed, phase.executeWith(&steps, &deadline, &release));
    try std.testing.expect(release.needsCleanup());
    try std.testing.expect(release.prerequisite_attempted);
    try std.testing.expect(!release.baseline_attempted);
    steps.fail_at = .none;
    try phase.retryCleanupWith(&steps, &release);
    try std.testing.expect(release.isPristineForComposition());
    try std.testing.expectEqualStrings("preflight,fence,prerequisite,clean-prerequisite", steps.log());
}

test "prerequisite terminal state is audit required and non-retryable" {
    var deadline: u8 = 0;
    var steps = Steps{ .fail_at = .prerequisite_audit };
    var release: phase.Release = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &release));
    try std.testing.expect(release.needsAudit());
    try std.testing.expectEqual(phase.AuditStage.prerequisite, release.auditStage());
    try std.testing.expectError(error.InvalidOwner, phase.retryCleanupWith(&steps, &release));
}

test "unclassified prerequisite failure fails closed as audit required" {
    var deadline: u8 = 0;
    var steps = Steps{ .fail_at = .prerequisite_unclassified };
    var release: phase.Release = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &release));
    try std.testing.expect(release.needsAudit());
    try std.testing.expectEqual(phase.AuditStage.prerequisite, release.auditStage());
}

test "all failures after ready draft preserve exact audit stage" {
    var deadline: u8 = 0;
    inline for (.{ Point.prerequisite_fence, Point.baseline, Point.baseline_fence, Point.publication, Point.final_fence }) |point| {
        var steps = Steps{ .fail_at = point };
        var release: phase.Release = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &release));
        try std.testing.expect(release.needsAudit());
        const expected: phase.AuditStage = switch (point) {
            .prerequisite_fence => .prerequisite,
            .baseline, .baseline_fence => .baseline,
            .publication, .final_fence => .publication,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, release.auditStage());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
    }
}

test "foreign deadline follows draft mutation boundary" {
    var deadline: u8 = 0;
    var local_steps = Steps{ .foreign_at = 1 };
    var local: phase.Release = .{};
    try std.testing.expectError(error.ForeignDeadline, phase.executeWith(&local_steps, &deadline, &local));
    try std.testing.expect(local.isPristineForComposition());
    var remote_steps = Steps{ .foreign_at = 2 };
    var remote: phase.Release = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&remote_steps, &deadline, &remote));
    try std.testing.expect(remote.needsAudit());
}

test "complete release cleanup closes local owners in reverse order" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var release: phase.Release = .{};
    try phase.executeWith(&steps, &deadline, &release);
    steps.length = 0;
    try phase.cleanupWith(&steps, &release);
    try std.testing.expectEqualStrings("clean-publication,clean-baseline,clean-prerequisite", steps.log());
    try std.testing.expect(release.isPristineForComposition());
}

test "complete release cleanup failure preserves failed owner and dependencies" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var release: phase.Release = .{};
    try phase.executeWith(&steps, &deadline, &release);
    steps.length = 0;
    steps.cleanup_fail = .baseline;
    try std.testing.expectError(error.CleanupFailed, phase.cleanupWith(&steps, &release));
    try std.testing.expect(release.needsCleanup());
    try std.testing.expect(!release.publication_attempted);
    try std.testing.expect(release.baseline_attempted);
    try std.testing.expect(release.prerequisite_attempted);
    steps.cleanup_fail = .none;
    try phase.retryCleanupWith(&steps, &release);
    try std.testing.expect(release.isPristineForComposition());
    try std.testing.expectEqual(@as(usize, 1), steps.prerequisite_calls);
    try std.testing.expectEqual(@as(usize, 1), steps.baseline_calls);
    try std.testing.expectEqual(@as(usize, 1), steps.publication_calls);
}

const Point = enum {
    none,
    initial_fence,
    prerequisite_local,
    prerequisite_cleanup,
    prerequisite_audit,
    prerequisite_unclassified,
    prerequisite_fence,
    baseline,
    baseline_fence,
    publication,
    final_fence,
};
const Cleanup = enum { none, prerequisite, baseline, publication };

const Steps = struct {
    events: [512]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    mutate_preflight: bool = false,
    expected_deadline: ?*u8 = null,
    deadline_observations: usize = 0,
    foreign_at: usize = 0,
    prerequisite_calls: usize = 0,
    baseline_calls: usize = 0,
    publication_calls: usize = 0,
    prerequisite_audit: bool = false,
    prerequisite_cleanup: bool = false,
    prerequisite_unclassified: bool = false,
    cleanup_count: usize = 0,

    fn add(self: *@This(), value: []const u8) void {
        if (self.length != 0) {
            self.events[self.length] = ',';
            self.length += 1;
        }
        @memcpy(self.events[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn log(self: *const @This()) []const u8 {
        return self.events[0..self.length];
    }
    pub fn validatePreflight(self: *@This(), release: *phase.Release, deadline: *u8) !void {
        self.add("preflight");
        self.expected_deadline = deadline;
        if (self.mutate_preflight) release.prerequisite_attempted = true;
    }
    pub fn validateAuthority(self: *@This(), deadline: *u8) !void {
        self.add("fence");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        self.deadline_observations += 1;
        if (self.foreign_at == self.deadline_observations) return error.ForeignDeadline;
        const point: Point = switch (self.deadline_observations) {
            1 => .initial_fence,
            2 => .prerequisite_fence,
            3 => .baseline_fence,
            4 => .final_fence,
            else => unreachable,
        };
        if (self.fail_at == point) return error.Injected;
    }
    pub fn runPrerequisite(self: *@This(), deadline: *u8) !void {
        self.add("prerequisite");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        self.prerequisite_calls += 1;
        if (self.fail_at == .prerequisite_local) return error.Injected;
        if (self.fail_at == .prerequisite_cleanup) {
            self.prerequisite_cleanup = true;
            return error.CleanupFailed;
        }
        if (self.fail_at == .prerequisite_audit) {
            self.prerequisite_audit = true;
            return error.AuditRequired;
        }
        if (self.fail_at == .prerequisite_unclassified) {
            self.prerequisite_unclassified = true;
            return error.Injected;
        }
    }
    pub fn prerequisiteNeedsCleanup(self: *const @This()) bool {
        return self.prerequisite_cleanup;
    }
    pub fn prerequisiteNeedsAudit(self: *const @This()) bool {
        return self.prerequisite_audit;
    }
    pub fn prerequisiteIsPristine(self: *const @This()) bool {
        return !self.prerequisite_cleanup and !self.prerequisite_audit and !self.prerequisite_unclassified;
    }
    pub fn runBaseline(self: *@This(), deadline: *u8) !void {
        self.add("baseline");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        self.baseline_calls += 1;
        if (self.fail_at == .baseline) return error.Injected;
    }
    pub fn runPublication(self: *@This(), deadline: *u8) !void {
        self.add("publication");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        self.publication_calls += 1;
        if (self.fail_at == .publication) return error.Injected;
    }
    pub fn cleanupPrerequisite(self: *@This()) !void {
        try self.clean("clean-prerequisite", .prerequisite);
        self.prerequisite_cleanup = false;
    }
    pub fn cleanupBaseline(self: *@This()) !void {
        try self.clean("clean-baseline", .baseline);
    }
    pub fn cleanupPublication(self: *@This()) !void {
        try self.clean("clean-publication", .publication);
    }
    fn clean(self: *@This(), name: []const u8, target: Cleanup) !void {
        self.add(name);
        self.cleanup_count += 1;
        if (self.cleanup_fail == target) return error.InjectedCleanup;
    }
};
