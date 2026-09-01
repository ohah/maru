const std = @import("std");
const phase = @import("release_adapter_verify_predecessor_phase");

const Step = enum {
    deadline,
    workspace,
    candidate,
    materialized,
    authenticated,
    assets,
    summary,
    cleanup_assets,
    cleanup_authenticated,
    cleanup_materialized,
    cleanup_candidate,
    cleanup_workspace,
    validate_publication,
    cleanup_deadline,
    publish,
    release_summary,
};

const Fake = struct {
    log: [32]Step = undefined,
    count: usize = 0,
    fail_step: ?Step = null,
    cleanup_fail: ?Step = null,
    deadline: u8 = 0,
    summary: u8 = 0,

    fn push(self: *@This(), step: Step) !void {
        self.log[self.count] = step;
        self.count += 1;
        if (self.fail_step == step) return error.Injected;
        if (self.cleanup_fail == step) return error.CleanupInjected;
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        try self.push(.deadline);
        return &self.deadline;
    }
    pub fn prepareWorkspace(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.workspace);
    }
    pub fn prepareCandidate(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.candidate);
    }
    pub fn materializeManifest(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.materialized);
    }
    pub fn authenticateManifest(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.authenticated);
    }
    pub fn authenticateAssets(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.assets);
    }
    pub fn prepareSummary(self: *@This(), deadline: *u8) !*u8 {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.summary);
        return &self.summary;
    }
    pub fn cleanupAssets(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_assets);
    }
    pub fn cleanupAuthenticated(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_authenticated);
    }
    pub fn cleanupMaterialized(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_materialized);
    }
    pub fn cleanupCandidate(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_candidate);
    }
    pub fn cleanupWorkspace(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_workspace);
    }
    pub fn cleanupDeadline(self: *@This(), _: *u8) !void {
        try self.push(.cleanup_deadline);
    }
    pub fn validatePublication(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        try self.push(.validate_publication);
    }
    pub fn publishSummary(self: *@This(), prepared: *u8) !void {
        try std.testing.expectEqual(&self.summary, prepared);
        try self.push(.publish);
    }
    pub fn releaseSummary(self: *@This(), prepared: *u8) void {
        std.testing.expectEqual(&self.summary, prepared) catch unreachable;
        self.push(.release_summary) catch {};
    }
};

test "published predecessor phase cleans private owners before publishing prepared summary" {
    var fake = Fake{};
    try phase.runWith(&fake);
    try std.testing.expectEqualSlices(Step, &.{ .deadline, .workspace, .candidate, .materialized, .authenticated, .assets, .summary, .cleanup_assets, .cleanup_authenticated, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .validate_publication, .cleanup_deadline, .publish, .release_summary }, fake.log[0..fake.count]);
}

test "expired final publication gate cleans deadline and releases prepared bytes" {
    var fake = Fake{ .fail_step = .validate_publication };
    try std.testing.expectError(error.Injected, phase.runWith(&fake));
    try std.testing.expect(std.mem.indexOfScalar(Step, fake.log[0..fake.count], .publish) == null);
    try std.testing.expectEqualSlices(Step, &.{ .validate_publication, .cleanup_deadline, .release_summary }, fake.log[fake.count - 3 .. fake.count]);
}

test "every validation failure skips later work and unwinds the attempted owner" {
    const cases = [_]struct { failure: Step, expected: []const Step }{
        .{ .failure = .deadline, .expected = &.{.deadline} },
        .{ .failure = .workspace, .expected = &.{ .deadline, .workspace, .cleanup_workspace, .cleanup_deadline } },
        .{ .failure = .candidate, .expected = &.{ .deadline, .workspace, .candidate, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline } },
        .{ .failure = .materialized, .expected = &.{ .deadline, .workspace, .candidate, .materialized, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline } },
        .{ .failure = .authenticated, .expected = &.{ .deadline, .workspace, .candidate, .materialized, .authenticated, .cleanup_authenticated, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline } },
        .{ .failure = .assets, .expected = &.{ .deadline, .workspace, .candidate, .materialized, .authenticated, .assets, .cleanup_assets, .cleanup_authenticated, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline } },
        .{ .failure = .summary, .expected = &.{ .deadline, .workspace, .candidate, .materialized, .authenticated, .assets, .summary, .cleanup_assets, .cleanup_authenticated, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline } },
    };
    for (cases) |case| {
        var fake = Fake{ .fail_step = case.failure };
        try std.testing.expectError(error.Injected, phase.runWith(&fake));
        try std.testing.expectEqualSlices(Step, case.expected, fake.log[0..fake.count]);
    }
}

test "cleanup failure preserves retry authority and releases prepared bytes without publication" {
    var fake = Fake{ .cleanup_fail = .cleanup_materialized };
    try std.testing.expectError(error.CleanupFailed, phase.runWith(&fake));
    try std.testing.expect(std.mem.indexOfScalar(Step, fake.log[0..fake.count], .publish) == null);
    try std.testing.expect(std.mem.indexOfScalar(Step, fake.log[0..fake.count], .release_summary) != null);
    try std.testing.expect(std.mem.indexOfScalar(Step, fake.log[0..fake.count], .cleanup_deadline) != null);
}

test "publication failure is terminal and still releases prepared bytes exactly once" {
    var fake = Fake{ .fail_step = .publish };
    try std.testing.expectError(error.Injected, phase.runWith(&fake));
    try std.testing.expectEqualSlices(Step, &.{ .deadline, .workspace, .candidate, .materialized, .authenticated, .assets, .summary, .cleanup_assets, .cleanup_authenticated, .cleanup_materialized, .cleanup_candidate, .cleanup_workspace, .validate_publication, .cleanup_deadline, .publish, .release_summary }, fake.log[0..fake.count]);
}
