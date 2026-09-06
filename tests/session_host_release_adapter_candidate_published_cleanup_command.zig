//! Specifies the stage-8 executable orchestration before the product owner exists.

const std = @import("std");
const command = @import("release_adapter_candidate_published_cleanup_command");

const Event = enum { classify, recover, reopen, token, deadline, authenticate, begin, settle, timing };

const Driver = struct {
    plan: command.Plan,
    recovery_outcome: command.Outcome = .success,
    begin_outcome: command.Outcome = .success,
    fail_at: ?Event = null,
    close_failure_at_classify: bool = false,
    events: [9]Event = undefined,
    count: usize = 0,

    fn hit(self: *@This(), event: Event) !void {
        self.events[self.count] = event;
        self.count += 1;
        if (self.fail_at == event) return error.Injected;
    }

    pub fn classify(self: *@This()) !command.Plan {
        try self.hit(.classify);
        if (self.close_failure_at_classify) return error.DescriptorCloseFailed;
        return self.plan;
    }
    pub fn recover(self: *@This()) !command.Outcome {
        try self.hit(.recover);
        return self.recovery_outcome;
    }
    pub fn reopen(self: *@This()) !void {
        try self.hit(.reopen);
    }
    pub fn readToken(self: *@This()) !void {
        try self.hit(.token);
    }
    pub fn startDeadline(self: *@This()) !void {
        try self.hit(.deadline);
    }
    pub fn authenticate(self: *@This()) !void {
        try self.hit(.authenticate);
    }
    pub fn begin(self: *@This()) !command.Outcome {
        try self.hit(.begin);
        return self.begin_outcome;
    }
    pub fn settle(self: *@This()) !void {
        try self.hit(.settle);
    }
    pub fn publishTiming(self: *@This()) !void {
        try self.hit(.timing);
    }
};

fn expectEvents(driver: *const Driver, expected: []const Event) !void {
    try std.testing.expectEqualSlices(Event, expected, driver.events[0..driver.count]);
}

test "initial cleanup authenticates before publishing durable deletion intent" {
    var driver = Driver{ .plan = .initial };
    try std.testing.expectEqual(command.Outcome.success, command.testingExecuteWith(&driver));
    try expectEvents(&driver, &.{ .classify, .deadline, .reopen, .token, .authenticate, .begin, .settle, .timing });
}

test "durable recovery is credential free and never reopens product aggregate" {
    var driver = Driver{ .plan = .recoverable };
    try std.testing.expectEqual(command.Outcome.success, command.testingExecuteWith(&driver));
    try expectEvents(&driver, &.{ .classify, .recover, .settle, .timing });
}

test "audit classification performs no token GitHub or cleanup mutation" {
    var driver = Driver{ .plan = .audit_required };
    try std.testing.expectEqual(command.Outcome.audit_required, command.testingExecuteWith(&driver));
    try expectEvents(&driver, &.{ .classify, .settle });
}

test "classification descriptor close uncertainty remains distinct" {
    var driver = Driver{ .plan = .initial, .close_failure_at_classify = true };
    try std.testing.expectEqual(command.Outcome.descriptor_close_failed, command.testingExecuteWith(&driver));
    try expectEvents(&driver, &.{ .classify, .settle });
}

test "durable cleanup and descriptor uncertainty remain distinct outcomes" {
    var retry = Driver{ .plan = .recoverable, .recovery_outcome = .cleanup_required };
    try std.testing.expectEqual(command.Outcome.cleanup_required, command.testingExecuteWith(&retry));
    try expectEvents(&retry, &.{ .classify, .recover, .settle });

    var close = Driver{ .plan = .initial, .begin_outcome = .descriptor_close_failed };
    try std.testing.expectEqual(command.Outcome.descriptor_close_failed, command.testingExecuteWith(&close));
    try expectEvents(&close, &.{ .classify, .deadline, .reopen, .token, .authenticate, .begin, .settle });
}

test "closed result vocabulary maps to stable exit codes and redacted stderr" {
    try std.testing.expectEqual(@as(u8, 0), command.exitCode(.success));
    try std.testing.expectEqual(@as(u8, 21), command.exitCode(.audit_required));
    try std.testing.expectEqual(@as(u8, 22), command.exitCode(.cleanup_required));
    try std.testing.expectEqual(@as(u8, 23), command.exitCode(.descriptor_close_failed));
    try std.testing.expectEqualStrings("success\n", command.stderrLine(.success));
    try std.testing.expectEqualStrings("audit_required\n", command.stderrLine(.audit_required));
    try std.testing.expectEqualStrings("cleanup_required\n", command.stderrLine(.cleanup_required));
    try std.testing.expectEqualStrings("descriptor_close_failed\n", command.stderrLine(.descriptor_close_failed));
}

test "timing formatter separates injected samples and preserves null remote intervals" {
    var execution = command.Execution{
        .classification_ns = 11,
        .cleanup_ns = 22,
        .total_ns = 33,
    };
    try std.testing.expectEqualStrings(
        "{\"schema\":\"maru.session-host-release-cleanup-command-perf.v1\",\"sample\":\"injected\",\"classification_ns\":11,\"first_lookup_ns\":null,\"attestation_ns\":null,\"final_lookup_ns\":null,\"cleanup_ns\":22,\"total_ns\":33}\n",
        try command.testingFormatTiming(&execution, .injected),
    );
}

test "execution reuse rejects residual timing and authority state" {
    var timing = command.Execution{ .timing_len = 1 };
    try std.testing.expect(!timing.isPristine());
    var digest = command.Execution{};
    digest.authority_digest[0] = 1;
    try std.testing.expect(!digest.isPristine());
}

test "owner bootstrap response and token regions must be pairwise disjoint" {
    var bytes: [64]u8 = @splat(0);
    try command.testingValidateAliases(bytes[0..8], bytes[8..16], bytes[16..24], bytes[24..32]);
    try std.testing.expectError(error.InvalidOwner, command.testingValidateAliases(bytes[0..8], bytes[4..12], bytes[16..24], bytes[24..32]));
    try std.testing.expectError(error.InvalidOwner, command.testingValidateAliases(bytes[0..8], bytes[8..16], bytes[12..20], bytes[24..32]));
    try std.testing.expectError(error.InvalidOwner, command.testingValidateAliases(bytes[0..8], bytes[8..16], bytes[16..24], bytes[20..28]));
}

test "production source owns real composition and segmented timing boundaries" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_published_cleanup_command.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "cleanup_recovery.classify(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "cleanup_recovery.recover(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "published_authority.authenticateUntilObserved(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "cleanup_recovery.begin(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.writeInt(usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "execution.aggregate_path.value()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "execution.manifest_path.value()") != null);
}
