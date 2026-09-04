const std = @import("std");
const preparation = @import("release_adapter_candidate_baseline_preparation");

test "preparation publishes one successful owner after one shared deadline" {
    std.testing.refAllDecls(preparation);
    var steps = Steps{};
    var execution: preparation.Execution = .{};
    try preparation.executeWith(&steps, &execution);
    try std.testing.expect(execution.ownsSuccessfulOutputs());
    try std.testing.expectEqualStrings("preflight,start,workspace,app,runner,final,deadline,close-deadline", steps.log());
    try std.testing.expectEqual(@as(usize, 5), steps.deadline_identity_count);
}

test "preparation rejects pre-owned and copied execution before callbacks" {
    var steps = Steps{};
    var execution: preparation.Execution = .{};
    execution.owner = &execution;
    try std.testing.expectError(error.InvalidOwner, preparation.executeWith(&steps, &execution));
    var copied = execution;
    try std.testing.expectError(error.InvalidOwner, preparation.executeWith(&steps, &copied));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
}

test "preflight rejects storage aliases before deadline start" {
    var steps = Steps{ .fail_at = .preflight };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.InvalidOwner, preparation.executeWith(&steps, &execution));
    try std.testing.expectEqualStrings("preflight", steps.log());
    try std.testing.expect(!execution.needsCleanup());
}

test "preflight cannot mutate transaction state before deadline start" {
    var steps = Steps{ .mutate_preflight = true };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.InvalidOwner, preparation.executeWith(&steps, &execution));
    try std.testing.expectEqualStrings("preflight", steps.log());
    try std.testing.expect(!execution.needsCleanup());
}

test "deadline start failure is pristine" {
    var steps = Steps{ .fail_at = .start };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.Injected, preparation.executeWith(&steps, &execution));
    try std.testing.expect(!execution.needsCleanup());
    try std.testing.expectEqualStrings("preflight,start", steps.log());
}

test "every failed attempted owner unwinds in reverse order" {
    const cases = [_]struct { point: Point, expected: []const u8 }{
        .{ .point = .workspace, .expected = "preflight,start,workspace,clean-workspace,close-deadline" },
        .{ .point = .app, .expected = "preflight,start,workspace,app,clean-app,clean-workspace,close-deadline" },
        .{ .point = .runner, .expected = "preflight,start,workspace,app,runner,clean-runner,clean-app,clean-workspace,close-deadline" },
        .{ .point = .final, .expected = "preflight,start,workspace,app,runner,final,clean-runner,clean-app,clean-workspace,close-deadline" },
        .{ .point = .deadline, .expected = "preflight,start,workspace,app,runner,final,deadline,clean-runner,clean-app,clean-workspace,close-deadline" },
    };
    for (cases) |case| {
        var steps = Steps{ .fail_at = case.point };
        var execution: preparation.Execution = .{};
        try std.testing.expectError(error.Injected, preparation.executeWith(&steps, &execution));
        try std.testing.expectEqualStrings(case.expected, steps.log());
        try std.testing.expect(!execution.needsCleanup());
    }
}

test "cleanup failure overrides original error and preserves exact retry set" {
    var steps = Steps{ .fail_at = .final, .cleanup_fail = .app };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, preparation.executeWith(&steps, &execution));
    try std.testing.expect(execution.needsCleanup());
    try std.testing.expect(!execution.runner_attempted);
    try std.testing.expect(execution.app_attempted);
    try std.testing.expect(!execution.workspace_attempted);
    try std.testing.expect(!execution.deadline_started);
    steps.cleanup_fail = .none;
    try preparation.retryCleanupWith(&steps, &execution);
    try std.testing.expect(!execution.needsCleanup());
}

test "each output cleanup failure preserves only its exact retry owner" {
    const cases = [_]Cleanup{ .runner, .app, .workspace };
    for (cases) |failed| {
        var steps = Steps{ .fail_at = .final, .cleanup_fail = failed };
        var execution: preparation.Execution = .{};
        try std.testing.expectError(error.CleanupFailed, preparation.executeWith(&steps, &execution));
        try std.testing.expectEqual(failed == .runner, execution.runner_attempted);
        try std.testing.expectEqual(failed == .app, execution.app_attempted);
        try std.testing.expectEqual(failed == .workspace, execution.workspace_attempted);
        try std.testing.expect(!execution.deadline_started);
        steps.cleanup_fail = .none;
        try preparation.retryCleanupWith(&steps, &execution);
        try std.testing.expect(!execution.needsCleanup());
    }
}

test "successful output cleanup is reverse ordered and terminal" {
    var steps = Steps{};
    var execution: preparation.Execution = .{};
    try preparation.executeWith(&steps, &execution);
    steps.length = 0;
    try preparation.cleanupWith(&steps, &execution);
    try std.testing.expectEqualStrings("clean-runner,clean-app,clean-workspace", steps.log());
    try std.testing.expect(!execution.needsCleanup());
    try std.testing.expect(!execution.ownsSuccessfulOutputs());
}

test "successful cleanup retains only the owner whose cleanup failed" {
    var steps = Steps{};
    var execution: preparation.Execution = .{};
    try preparation.executeWith(&steps, &execution);
    steps.length = 0;
    steps.cleanup_fail = .app;
    try std.testing.expectError(error.CleanupFailed, preparation.cleanupWith(&steps, &execution));
    try std.testing.expect(!execution.runner_attempted);
    try std.testing.expect(execution.app_attempted);
    try std.testing.expect(!execution.workspace_attempted);
    steps.cleanup_fail = .none;
    try preparation.retryCleanupWith(&steps, &execution);
    try std.testing.expect(!execution.needsCleanup());
}

test "foreign deadline identity fails before successful publication" {
    var steps = Steps{ .foreign_deadline = true };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.ForeignDeadline, preparation.executeWith(&steps, &execution));
    try std.testing.expect(!execution.ownsSuccessfulOutputs());
    try std.testing.expectEqualStrings("preflight,start,workspace,app,runner,final,clean-runner,clean-app,clean-workspace,close-deadline", steps.log());
}

test "deadline cleanup failure is normalized and keeps retry authority" {
    var steps = Steps{ .cleanup_fail = .deadline };
    var execution: preparation.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, preparation.executeWith(&steps, &execution));
    try std.testing.expect(execution.needsCleanup());
    try std.testing.expect(execution.deadline_started);
    try std.testing.expect(!execution.runner_attempted);
    try std.testing.expect(!execution.app_attempted);
    try std.testing.expect(!execution.workspace_attempted);
    steps.cleanup_fail = .none;
    try preparation.retryCleanupWith(&steps, &execution);
    try std.testing.expect(!execution.needsCleanup());
}

const Point = enum { none, preflight, start, workspace, app, runner, final, deadline };
const Cleanup = enum { none, workspace, app, runner, deadline };

const Steps = struct {
    deadline: u8 = 0,
    events: [512]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    foreign_deadline: bool = false,
    mutate_preflight: bool = false,
    expected_deadline: ?*u8 = null,
    deadline_identity_count: usize = 0,

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
    fn observeDeadline(self: *@This(), deadline: *u8) !void {
        if (self.foreign_deadline and self.deadline_identity_count == 3) return error.ForeignDeadline;
        if (self.expected_deadline) |expected| {
            if (expected != deadline) return error.ForeignDeadline;
        } else self.expected_deadline = deadline;
        self.deadline_identity_count += 1;
    }
    pub fn validatePreflight(self: *@This(), execution: *preparation.Execution) !void {
        self.add("preflight");
        if (self.fail_at == .preflight) return error.InvalidOwner;
        if (self.mutate_preflight) execution.workspace_attempted = true;
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        self.add("start");
        if (self.fail_at == .start) return error.Injected;
        return &self.deadline;
    }
    pub fn prepareWorkspace(self: *@This(), deadline: *u8) !void {
        self.add("workspace");
        try self.observeDeadline(deadline);
        if (self.fail_at == .workspace) return error.Injected;
    }
    pub fn bindCandidateApp(self: *@This(), deadline: *u8) !void {
        self.add("app");
        try self.observeDeadline(deadline);
        if (self.fail_at == .app) return error.Injected;
    }
    pub fn runBaseline(self: *@This(), deadline: *u8) !void {
        self.add("runner");
        try self.observeDeadline(deadline);
        if (self.fail_at == .runner) return error.Injected;
    }
    pub fn validateFinalCandidate(self: *@This(), deadline: *u8) !void {
        self.add("final");
        try self.observeDeadline(deadline);
        if (self.fail_at == .final) return error.Injected;
    }
    pub fn validateFinalDeadline(self: *@This(), deadline: *u8) !void {
        self.add("deadline");
        try self.observeDeadline(deadline);
        if (self.fail_at == .deadline) return error.Injected;
    }
    pub fn cleanupRunner(self: *@This()) !void {
        self.add("clean-runner");
        if (self.cleanup_fail == .runner) return error.InjectedCleanup;
    }
    pub fn cleanupApp(self: *@This()) !void {
        self.add("clean-app");
        if (self.cleanup_fail == .app) return error.InjectedCleanup;
    }
    pub fn cleanupWorkspace(self: *@This()) !void {
        self.add("clean-workspace");
        if (self.cleanup_fail == .workspace) return error.InjectedCleanup;
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *u8) !void {
        self.add("close-deadline");
        if (self.expected_deadline != deadline) return error.ForeignDeadline;
        if (self.cleanup_fail == .deadline) return error.InjectedCleanup;
    }
    pub fn retryCleanupDeadline(self: *@This()) !void {
        self.add("close-deadline");
        if (self.cleanup_fail == .deadline) return error.InjectedCleanup;
    }
};
