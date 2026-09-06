const std = @import("std");
const command = @import("release_adapter_candidate_resume_publication_command");

const source_sha = "0123456789abcdef0123456789abcdef01234567";

test "stage7 process outcomes are closed and redacted" {
    try std.testing.expectEqual(@as(u8, 0), command.exitCode(.success));
    try std.testing.expectEqual(@as(u8, 21), command.exitCode(.audit_required));
    try std.testing.expectEqual(@as(u8, 22), command.exitCode(.cleanup_failed));
    try std.testing.expectEqualStrings("success\n", command.stderrLine(.success));
    try std.testing.expectEqualStrings("audit_required\n", command.stderrLine(.audit_required));
    try std.testing.expectEqualStrings("cleanup_failed\n", command.stderrLine(.cleanup_failed));
}

test "invalid bootstrap is audit-required after stage4 and leaves pristine storage" {
    var bootstrap = command.Bootstrap{};
    var execution = command.Execution{};
    var response: [64]u8 = undefined;
    try std.testing.expectEqual(command.Outcome.audit_required, command.runOutcome(
        undefined,
        std.testing.allocator,
        &bootstrap,
        "token",
        &response,
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.isPristineForComposition());

    bootstrap.owner = &bootstrap;
    bootstrap.cli_path_len = bootstrap.cli_path_storage.len;
    try std.testing.expectEqual(command.Outcome.audit_required, command.runOutcome(
        undefined,
        std.testing.allocator,
        &bootstrap,
        "token",
        &response,
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.isPristineForComposition());
}

test "preowned and copied command storage cannot become an outcome authority" {
    var bootstrap = command.Bootstrap{};
    var response: [64]u8 = undefined;
    var preowned = command.Execution{};
    preowned.owner = &preowned;
    try std.testing.expectEqual(command.Outcome.cleanup_failed, command.runOutcome(
        undefined,
        std.testing.allocator,
        &bootstrap,
        "token",
        &response,
        std.time.ns_per_s,
        &preowned,
    ));
    var copied = preowned;
    try std.testing.expect(!copied.needsCleanup());
    try std.testing.expectError(error.InvalidOwner, copied.retryCleanup());

    command.testing_api.corruptStoredPathLength(&preowned);
    try std.testing.expect(!preowned.needsCleanup());
    try std.testing.expectError(error.InvalidOwner, preowned.retryCleanup());

    var dirty = command.Execution{};
    command.testing_api.corruptStoredPathByte(&dirty);
    try std.testing.expect(!dirty.isPristineForComposition());
    try std.testing.expectEqual(command.Outcome.cleanup_failed, command.runOutcome(
        undefined,
        std.testing.allocator,
        &bootstrap,
        "token",
        &response,
        std.time.ns_per_s,
        &dirty,
    ));
}

test "authority snapshot detects borrowed bootstrap and pinned CLI mutation" {
    var mutable_tag = [_]u8{ 'v', '1', '.', '2', '.', '3' };
    var bootstrap = command.Bootstrap{
        .command = .{ .resume_candidate_publication = .{
            .repo = "ohah/maru",
            .tag = &mutable_tag,
            .preparation = "/tmp/preparation",
            .aggregate = "/tmp/aggregate",
            .dmg = "/tmp/Maru.dmg",
            .frozen_executable = "/tmp/session-host",
        } },
        .context = .{
            .repository = .{ .id = 123456, .owner = "ohah", .name = "maru" },
            .tag = &mutable_tag,
            .source_commit = source_sha,
            .build = .{
                .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
                .run_id = 987654,
                .run_attempt = 2,
            },
            .protected_tag = true,
        },
        .runner = .{ .workflow_sha = source_sha.* },
        .cli = .{
            .path_sha256 = @splat(1),
            .path_len = "/usr/local/bin/gh".len,
            .identity = .{ .device = 2, .inode = 3 },
            .size = 4,
            .mode = 0o755,
            .sha256 = @splat('a'),
        },
        .cli_path_len = "/usr/local/bin/gh".len,
    };
    @memcpy(bootstrap.cli_path_storage[0..bootstrap.cli_path_len], "/usr/local/bin/gh");
    bootstrap.cli_path_storage[bootstrap.cli_path_len] = 0;
    bootstrap.owner = &bootstrap;

    const initial = command.testing_api.snapshot(bootstrap.value().?);
    mutable_tag[1] = '9';
    try std.testing.expect(!std.mem.eql(u8, &initial, &command.testing_api.snapshot(bootstrap.value().?)));
    mutable_tag[1] = '1';
    bootstrap.cli.sha256[0] = 'b';
    try std.testing.expect(!std.mem.eql(u8, &initial, &command.testing_api.snapshot(bootstrap.value().?)));

    var execution = command.Execution{};
    var response: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, command.testing_api.validateAliasGraph(&execution, &bootstrap, "token", &response));
}

const DriverCall = enum { deadline, resume_fence, resume_authority, publication_fence, publish, settle, audit_cleanup };

const FakeDriver = struct {
    calls: [7]DriverCall = undefined,
    count: usize = 0,
    fail_at: ?usize = null,
    cleanup_fail: bool = false,

    fn step(self: *@This(), call: DriverCall) !void {
        self.calls[self.count] = call;
        const index = self.count;
        self.count += 1;
        if (self.fail_at == index) return error.Injected;
    }

    pub fn startDeadline(self: *@This()) !void {
        try self.step(.deadline);
    }
    pub fn requireResumeAuthority(self: *@This()) !void {
        try self.step(.resume_fence);
    }
    pub fn resumeAuthority(self: *@This()) !void {
        try self.step(.resume_authority);
    }
    pub fn requirePublicationAuthority(self: *@This()) !void {
        try self.step(.publication_fence);
    }
    pub fn publish(self: *@This()) !void {
        try self.step(.publish);
    }
    pub fn succeed(self: *@This()) !void {
        try self.step(.settle);
    }
    pub fn failAudit(self: *@This()) !void {
        try self.step(.audit_cleanup);
        if (self.cleanup_fail) return error.InjectedCleanup;
    }
};

test "production-shaped driver closes every orchestration failure through audit cleanup" {
    var success = FakeDriver{};
    try command.testing_api.execute(&success);
    try std.testing.expectEqualSlices(DriverCall, &.{ .deadline, .resume_fence, .resume_authority, .publication_fence, .publish, .settle }, success.calls[0..success.count]);

    for (0..5) |fail_at| {
        var failed = FakeDriver{ .fail_at = fail_at };
        try std.testing.expectError(error.AuditRequired, command.testing_api.execute(&failed));
        try std.testing.expectEqual(DriverCall.audit_cleanup, failed.calls[failed.count - 1]);

        var cleanup_failed = FakeDriver{ .fail_at = fail_at, .cleanup_fail = true };
        try std.testing.expectError(error.InjectedCleanup, command.testing_api.execute(&cleanup_failed));
        try std.testing.expectEqual(DriverCall.audit_cleanup, cleanup_failed.calls[cleanup_failed.count - 1]);
    }
}

test "production command uses one deadline and only borrowing product entrypoints" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_resume_publication_command.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "resume_product.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "publication_product.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "resume_product.run("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "publication_product.run("));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "try requireActive(self.execution, view);"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, source, "try driver.failAudit();"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "publication_audit_stage = self.execution.publication.auditStage()"));
}

test "production ordering closes publication before resume and deadline" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_resume_publication_command.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    const resume_call = std.mem.indexOf(u8, source, "resume_product.runBorrowingDeadline(") orelse return error.MissingResume;
    const publication_call = std.mem.indexOf(u8, source, "publication_product.runBorrowingDeadline(") orelse return error.MissingPublication;
    const settle_offset = std.mem.indexOf(u8, source, "fn settle(") orelse return error.MissingSettlement;
    const local = source[settle_offset..];
    const publication_cleanup = std.mem.indexOf(u8, local, "execution.publication.cleanup") orelse return error.MissingPublicationCleanup;
    const resume_cleanup = std.mem.indexOf(u8, local, "execution.source_execution.cleanup") orelse return error.MissingResumeCleanup;
    const deadline_cleanup = std.mem.indexOf(u8, local, "execution.deadline.deinit") orelse return error.MissingDeadlineCleanup;
    try std.testing.expect(resume_call < publication_call);
    try std.testing.expect(publication_cleanup < resume_cleanup);
    try std.testing.expect(resume_cleanup < deadline_cleanup);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, ".publication.cleanupAudit()"));
}
