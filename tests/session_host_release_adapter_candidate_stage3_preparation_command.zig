//! The stage-3 command preserves typed mutation outcomes across the process boundary.

const std = @import("std");
const contract = @import("release_adapter_contract");
const bootstrap = @import("release_adapter_executable_bootstrap");
const workflow = @import("release_adapter_live_workflow_phase");
const command_driver = @import("release_adapter_candidate_stage3_preparation_command");

const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const commit = "0123456789abcdef0123456789abcdef01234567";

const args = [_][]const u8{
    "prepare-candidate",                         "--repo",                 "ohah/maru",             "--tag",                                "v1.2.3",               "--github-cli",       "/usr/bin/gh",
    "--github-cli-sha256",                       sha,                      "--test-uuid",           "123e4567-e89b-42d3-a456-426614174000", "--dmg",                "/tmp/candidate.dmg", "--frozen-executable",
    "/tmp/frozen",                               "--candidate-dmg-bundle", "/tmp/dmg.bundle",       "--candidate-frozen-bundle",            "/tmp/frozen.bundle",   "--dmg-work",         "/tmp/dmg-work",
    "--baseline-workspace",                      "/tmp/baseline",          "--app-main-executable", "/tmp/app-main",                        "--app-cli-executable", "/tmp/app-cli",       "--manifest",
    "/tmp/Maru-1.2.3-session-host-release.json", "--source-root",          "/tmp/source",           "--zig",                                "/tmp/zig",             "--zig-size",         "123",
    "--zig-sha256",                              sha,                      "--durable-preparation", "/tmp/durable-stage3",
};

test "contract accepts exact stage3 command and exports the real argv bound" {
    try std.testing.expectEqual(contract.max_command_args, args.len);
    const parsed = try contract.parseArgs(&args);
    const value = parsed.prepare_candidate;
    try std.testing.expectEqualStrings("/tmp/durable-stage3", value.durable_preparation);
    try std.testing.expectEqualStrings("/tmp/dmg.bundle", value.candidate_dmg_bundle);
}

test "contract rejects missing durable output, phase options, and tree aliases" {
    try std.testing.expectError(error.MissingOption, contract.parseArgs(args[0 .. args.len - 2]));
    var unknown = args;
    unknown[args.len - 2] = "--aggregate";
    try std.testing.expectError(error.UnknownOption, contract.parseArgs(&unknown));
    var alias = args;
    alias[args.len - 1] = "/tmp/baseline/retained";
    try std.testing.expectError(error.PathAlias, contract.parseArgs(&alias));
}

const ContextReader = struct {
    pub fn read(_: *@This()) !@import("release_adapter_context").Context {
        return .{ .repository = .{ .owner = "ohah", .name = "maru", .id = 1 }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 }, .protected_tag = true };
    }
};
const RunnerReader = struct {
    pub fn read(_: *@This(), _: []const u8) !@import("release_adapter_github_cli_authority").RunnerAuthority {
        return .{ .workflow_sha = commit.* };
    }
};
const Pinner = struct {
    pub fn pin(_: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: []const u8) !@import("release_adapter_github_cli_authority").PinnedExecutable {
        return .{ .path_sha256 = @splat(1), .path_len = "/usr/bin/gh".len, .identity = .{ .device = 1, .inode = 2 }, .size = 3, .mode = 0o755, .sha256 = @splat('a') };
    }
};

test "bootstrap binds stage3 command to trusted context and copied CLI path" {
    var result: bootstrap.Bootstrap = .{};
    var contexts = ContextReader{};
    var runners = RunnerReader{};
    var pinner = Pinner{};
    try bootstrap.bootstrapWith(std.testing.allocator, &args, &contexts, &runners, &pinner, &result);
    const view = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/durable-stage3", view.command.prepare_candidate.durable_preparation);
    try std.testing.expectEqualStrings("/usr/bin/gh", view.github_cli);
}

test "only proved stage3 pre-mutation failure may become local" {
    var state: workflow.State = .{ .next_index = 2 };
    try workflow.apply(&state, .{ .stage = .draft_authoring, .result = .failed_before_remote_mutation });
    try std.testing.expectEqual(workflow.Outcome.local_failure, state.outcome);

    var earlier: workflow.State = .{};
    try std.testing.expectError(error.InvalidState, workflow.apply(&earlier, .{ .stage = .candidate_pinning, .result = .failed_before_remote_mutation }));

    var conservative: workflow.State = .{ .next_index = 2 };
    try workflow.apply(&conservative, .{ .stage = .draft_authoring, .result = .failed });
    try std.testing.expectEqual(workflow.Outcome.audit_required, conservative.outcome);
}

test "closed command outcomes have stable codes and redacted names" {
    const rows = [_]struct { command_driver.Outcome, u8, []const u8 }{
        .{ .success, 0, "success\n" },
        .{ .local_failure, 20, "local_failure\n" },
        .{ .audit_required, 21, "audit_required\n" },
        .{ .cleanup_failed, 22, "cleanup_failed\n" },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row[1], command_driver.exitCode(row[0]));
        try std.testing.expectEqualStrings(row[2], command_driver.stderrLine(row[0]));
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

test "settlement never sends audit state through ordinary cleanup" {
    var local = FakeExecution{};
    local.owner = &local;
    try std.testing.expectEqual(command_driver.Outcome.local_failure, command_driver.testing_api.settle(&local));
    try std.testing.expectEqual(@as(usize, 1), local.ordinary_retries);

    var audit = FakeExecution{ .audit = true };
    audit.owner = &audit;
    try std.testing.expectEqual(command_driver.Outcome.audit_required, command_driver.testing_api.settle(&audit));
    try std.testing.expectEqual(@as(usize, 0), audit.ordinary_retries);
    try std.testing.expectEqual(@as(usize, 1), audit.audit_retries);

    var broken = FakeExecution{ .audit = true, .retry_fail = true };
    broken.owner = &broken;
    try std.testing.expectEqual(command_driver.Outcome.cleanup_failed, command_driver.testing_api.settle(&broken));
}

test "production command has one stage3 product caller and validator dispatch" {
    const driver_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_command.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(driver_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, driver_source, "stage3_product.run("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, driver_source, "candidate_release_product"));

    const validator_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/validate_release_manifest.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(validator_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, validator_source, ".prepare_candidate =>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, validator_source, "contract.max_command_args"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, validator_source, "const max_args: usize = 32"));
}
