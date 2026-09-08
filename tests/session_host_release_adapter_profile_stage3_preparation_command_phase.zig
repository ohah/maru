const std = @import("std");
const phase = @import("release_adapter_profile_stage3_preparation_command_phase");

const Mock = struct {
    events: [64]u8 = @splat(0),
    len: usize = 0,
    fail: phase.Stage = .none,
    retained_on_durable_failure: bool = false,
    prerequisite_audit: bool = false,
    cleanup_fail_once: phase.Stage = .none,
    timing_audit: bool = false,

    fn push(self: *@This(), value: u8) !void {
        self.events[self.len] = value;
        self.len += 1;
    }
    fn run(self: *@This(), stage: phase.Stage, value: u8) !void {
        try self.push(value);
        if (self.fail == stage) return error.Injected;
    }
    pub fn validatePreflight(self: *@This()) !void {
        try self.run(.preflight, 1);
    }
    pub fn bindProfile(self: *@This()) !void {
        try self.run(.profile, 2);
    }
    pub fn runPrerequisite(self: *@This()) !void {
        try self.run(.prerequisite, 3);
    }
    pub fn prerequisiteNeedsAudit(self: *@This()) bool {
        return self.prerequisite_audit;
    }
    pub fn preparePredecessorWorkspace(self: *@This()) !void {
        try self.run(.predecessor_workspace, 4);
    }
    pub fn authenticateManifest(self: *@This()) !void {
        try self.run(.manifest_input, 5);
    }
    pub fn prepareUpgradeWorkspace(self: *@This()) !void {
        try self.run(.upgrade_workspace, 6);
    }
    pub fn bindAuthorities(self: *@This()) !void {
        try self.run(.authorities, 7);
    }
    pub fn runProfileUpgrade(self: *@This()) !void {
        try self.run(.profile_upgrade, 8);
    }
    pub fn prepareDurable(self: *@This()) !void {
        try self.run(.durable, 9);
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.retained_on_durable_failure;
    }
    pub fn publishTiming(self: *@This()) !void {
        try self.run(.timing, 10);
    }
    pub fn timingNeedsAudit(self: *@This()) bool {
        return self.timing_audit;
    }
    pub fn closeTimingRetaining(self: *@This()) !void {
        try self.run(.retained_close, 11);
    }
    pub fn cleanup(self: *@This(), stage: phase.Stage) !void {
        try self.push(100 + @intFromEnum(stage));
        if (self.cleanup_fail_once == stage) {
            self.cleanup_fail_once = .none;
            return error.InjectedCleanup;
        }
    }
};

test "driver reducer fixes the ten side effect stages and reverse cleanup order" {
    var mock = Mock{};
    var transaction: phase.Transaction = .{};
    try phase.executeWith(&mock, &transaction);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 108, 107, 106, 105, 104, 103, 102 }, mock.events[0..mock.len]);
    try std.testing.expect(transaction.isPristineForComposition());
}

test "failure before any remote commit cleans the exact local owner and returns pristine" {
    var mock = Mock{ .fail = .profile };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.Injected, phase.executeWith(&mock, &transaction));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 102 }, mock.events[0..mock.len]);
    try std.testing.expect(transaction.isPristineForComposition());
}

test "failure after durable retention is audit required and never deletes the commit" {
    var mock = Mock{ .fail = .timing };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expectEqual(phase.Stage.timing, transaction.audit_stage);
    try std.testing.expect(transaction.durable_retained);
    try std.testing.expect(transaction.localCleanupComplete());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 110, 108, 107, 106, 105, 104, 103, 102 }, mock.events[0..mock.len]);
}

test "durable callback failure preserves an observed retained commit as audit" {
    var mock = Mock{ .fail = .durable, .retained_on_durable_failure = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expectEqual(phase.Stage.durable, transaction.audit_stage);
    try std.testing.expect(transaction.durable_retained);
    try std.testing.expect(transaction.localCleanupComplete());
}

test "cleanup failure retains only failed owners and retry continues without borrowed state" {
    var mock = Mock{ .fail = .profile, .cleanup_fail_once = .profile };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.CleanupFailed, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsCleanup());
    try phase.retryCleanupWith(&mock, &transaction);
    try std.testing.expect(transaction.isPristineForComposition());
}

test "successful prerequisite makes every later failure auditable" {
    var mock = Mock{ .fail = .authorities };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expectEqual(phase.Stage.authorities, transaction.audit_stage);
    try std.testing.expect(transaction.remote_commit_observed);
    try std.testing.expect(transaction.localCleanupComplete());
}

test "prerequisite failure preserves its own remote audit signal" {
    var mock = Mock{ .fail = .prerequisite, .prerequisite_audit = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expectEqual(phase.Stage.prerequisite, transaction.audit_stage);
    try std.testing.expect(transaction.prerequisite_audit_preserved);
    try std.testing.expect(transaction.localCleanupComplete());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, mock.events[0..mock.len], &.{100 + @intFromEnum(phase.Stage.prerequisite)}));
}

test "timing owner established before publisher failure is preserved without deletion" {
    var mock = Mock{ .fail = .timing, .timing_audit = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expect(transaction.timing_audit_preserved);
    try std.testing.expect(transaction.localCleanupComplete());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, mock.events[0..mock.len], &.{100 + @intFromEnum(phase.Stage.timing)}));
}

test "timing failure before ownership cleans the attempted leaf before earlier owners" {
    var mock = Mock{ .fail = .timing };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&mock, &transaction));
    const timing_cleanup = std.mem.indexOfScalar(u8, mock.events[0..mock.len], 100 + @intFromEnum(phase.Stage.timing)) orelse return error.TestUnexpectedResult;
    const upgrade_cleanup = std.mem.indexOfScalar(u8, mock.events[0..mock.len], 100 + @intFromEnum(phase.Stage.profile_upgrade)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(timing_cleanup < upgrade_cleanup);
}
