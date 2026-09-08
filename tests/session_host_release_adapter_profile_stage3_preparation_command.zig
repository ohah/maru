const std = @import("std");
const command = @import("release_adapter_profile_stage3_preparation_command");

test "profile stage3 command owns the complete graph at one final address" {
    var execution: command.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(@sizeOf(command.Execution) > @sizeOf(command.Bootstrap));
    _ = command.run;
    _ = command.runOutcome;
}

test "closed profile stage3 outcomes have stable process codes" {
    const rows = [_]struct { command.Outcome, u8, []const u8 }{
        .{ .success, 0, "success\n" },
        .{ .local_failure, 20, "local_failure\n" },
        .{ .audit_required, 21, "audit_required\n" },
        .{ .cleanup_failed, 22, "cleanup_failed\n" },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row[1], command.exitCode(row[0]));
        try std.testing.expectEqualStrings(row[2], command.stderrLine(row[0]));
    }
}

const FakeExecution = struct {
    owner: ?*@This() = null,
    audit: bool = false,
    local_complete: bool = false,
    retry_fail: bool = false,
    ordinary_retries: usize = 0,
    audit_retries: usize = 0,

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.audit;
    }
    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.local_complete;
    }
    pub fn retryCleanup(self: *@This()) !void {
        self.ordinary_retries += 1;
        if (self.retry_fail) return error.Injected;
        self.owner = null;
    }
    pub fn retryAuditCleanup(self: *@This()) !void {
        self.audit_retries += 1;
        if (self.retry_fail) return error.Injected;
        self.local_complete = true;
    }
};

test "settlement preserves audit authority and scrubs only local residue" {
    var local = FakeExecution{};
    local.owner = &local;
    try std.testing.expectEqual(command.Outcome.local_failure, command.testing_api.settle(&local));
    try std.testing.expectEqual(@as(usize, 1), local.ordinary_retries);

    var audit = FakeExecution{ .audit = true };
    audit.owner = &audit;
    try std.testing.expectEqual(command.Outcome.audit_required, command.testing_api.settle(&audit));
    try std.testing.expectEqual(@as(usize, 0), audit.ordinary_retries);
    try std.testing.expectEqual(@as(usize, 1), audit.audit_retries);

    var broken = FakeExecution{ .audit = true, .retry_fail = true };
    broken.owner = &broken;
    try std.testing.expectEqual(command.Outcome.cleanup_failed, command.testing_api.settle(&broken));
}

test "production driver has one callsite for every composed product" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_profile_stage3_preparation_command.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    const calls = [_][]const u8{
        "profile_mod.bindFromEnvironment(",      "prerequisite_mod.run(",          "pre_publish_workspace.prepare(",
        "manifest_input_mod.authenticateUntil(", "upgrade_workspace_mod.prepare(", "source_authority.prepareCurrent(",
        "zig_authority.bind(",                   "upgrade_mod.run(",               "stage3_product.run(",
        "timing_mod.publish(",                   ".timing.closeRetaining(",
    };
    for (calls) |call| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, call));

    const validator = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/validate_release_manifest.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(validator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, validator, ".prepare_profile_candidate =>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, validator, "profile_stage3_command.runOutcome("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, validator, "ProfileStage3DriverUnavailable"));
}
