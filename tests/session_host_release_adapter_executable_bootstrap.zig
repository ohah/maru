//! The executable bootstrap closes command, process identity, runner, and checkout-prepinned CLI
//! authority before either release phase may perform network or output side effects.

const std = @import("std");
const bootstrap = @import("release_adapter_executable_bootstrap");
const context_mod = @import("release_adapter_context");
const authority = @import("release_adapter_github_cli_authority");

const source_sha = "0123456789abcdef0123456789abcdef01234567";
const cli_sha = "f6d97bdb40d0d71bd1f0424dedfbae0927373c93ba3fb18f67300d8fc41e7176";

fn trustedContext() context_mod.Context {
    return .{
        .repository = .{ .id = 123456, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = source_sha,
        .build = .{
            .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
            .run_id = 987654,
            .run_attempt = 2,
        },
        .protected_tag = true,
    };
}

const Trace = struct {
    calls: [3]enum { context, runner, pin } = undefined,
    count: usize = 0,

    fn record(self: *@This(), call: @TypeOf(self.calls[0])) void {
        self.calls[self.count] = call;
        self.count += 1;
    }
};

const ContextReader = struct {
    trace: *Trace,
    value: context_mod.Context = trustedContext(),

    pub fn read(self: *@This()) !context_mod.Context {
        self.trace.record(.context);
        return self.value;
    }
};

const RunnerReader = struct {
    trace: *Trace,
    fail: bool = false,

    pub fn read(self: *@This(), expected: []const u8) !authority.RunnerAuthority {
        self.trace.record(.runner);
        if (self.fail) return error.UntrustedRunner;
        return authority.validateRunner(.{
            .workflow_sha = source_sha,
            .runner_environment = "github-hosted",
            .runner_os = "macOS",
            .runner_arch = "ARM64",
        }, expected);
    }
};

const Pinner = struct {
    trace: *Trace,
    seen_path: [bootstrap.max_cli_path_bytes]u8 = undefined,
    seen_path_len: usize = 0,
    seen_sha: []const u8 = "",

    pub fn pin(self: *@This(), _: std.mem.Allocator, path: [:0]const u8, sha: []const u8) !authority.PinnedExecutable {
        self.trace.record(.pin);
        self.seen_path_len = path.len;
        @memcpy(self.seen_path[0..path.len], path);
        self.seen_sha = sha;
        return .{
            .path_sha256 = @splat(1),
            .path_len = path.len,
            .identity = .{ .device = 2, .inode = 3 },
            .size = 4,
            .mode = 0o755,
            .sha256 = @splat('a'),
        };
    }
};

fn prePublishArgs(path: []const u8) [21][]const u8 {
    return .{
        "pre-publish",                               "--repo",     "ohah/maru",           "--tag",                 "v1.2.3",
        "--github-cli",                              path,         "--github-cli-sha256", cli_sha,                 "--manifest",
        "/tmp/Maru-1.2.3-session-host-release.json", "--evidence", "/tmp/evidence.json",  "--dmg",                 "/tmp/Maru.dmg",
        "--frozen-executable",                       "/tmp/maru",  "--work-dir",          "/tmp/pre-publish-work", "--summary-out",
        "/tmp/summary.json",
    };
}

fn predecessorArgs(path: []const u8) [15][]const u8 {
    return .{
        "verify-predecessor",                        "--repo",     "ohah/maru",           "--tag",         "v1.2.3",
        "--github-cli",                              path,         "--github-cli-sha256", cli_sha,         "--manifest",
        "/tmp/Maru-1.2.3-session-host-release.json", "--work-dir", "/tmp/work",           "--summary-out", "/tmp/summary.json",
    };
}

fn candidateArgs(path: []const u8) [37][]const u8 {
    return .{
        "publish-candidate",                        "--repo",                               "ohah/maru",                                             "--tag",                                   "v1.2.3",                                      "--github-cli",                                                     path,                                               "--github-cli-sha256",                   cli_sha,
        "--test-uuid",                              "123e4567-e89b-42d3-a456-426614174000", "--dmg",                                                 "/tmp/candidate/Maru-1.2.3-universal.dmg", "--frozen-executable",                         "/tmp/candidate/maru-session-host-1.2.3",                           "--dmg-work",                                       "/tmp/dmg-work",                         "--baseline-workspace",
        "/tmp/baseline-work",                       "--app-main-executable",                "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app", "--app-cli-executable",                    "/tmp/candidate/Maru.app/Contents/MacOS/maru", "--manifest",                                                       "/tmp/output/Maru-1.2.3-session-host-release.json", "--source-root",                         "/tmp/candidate",
        "--zig",                                    "/usr/local/bin/zig",                   "--zig-size",                                            "123456",                                  "--zig-sha256",                                "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "--candidate-dmg-bundle",                           "/tmp/attest/candidate-dmg.bundle.json", "--candidate-frozen-bundle",
        "/tmp/attest/candidate-frozen.bundle.json",
    };
}

fn prepareAggregateArgs(path: []const u8) [21][]const u8 {
    return .{
        "prepare-candidate-aggregate",      "--repo",                           "ohah/maru",                      "--tag",                            "v1.2.3",
        "--github-cli",                     path,                               "--github-cli-sha256",            cli_sha,                            "--evidence",
        "/tmp/source/evidence.json",        "--candidate-dmg-bundle",           "/tmp/source/candidate-dmg.json", "--candidate-frozen-bundle",        "/tmp/source/candidate-frozen.json",
        "--evidence-bundle",                "/tmp/source/evidence-bundle.json", "--manifest-bundle",              "/tmp/source/manifest-bundle.json", "--aggregate",
        "/tmp/handoff/candidate-aggregate",
    };
}

fn finalizeAggregateArgs(path: []const u8) [17][]const u8 {
    return .{
        "finalize-candidate-aggregate",     "--repo",                                              "ohah/maru",               "--tag",               "v1.2.3",
        "--github-cli",                     path,                                                  "--github-cli-sha256",     cli_sha,               "--aggregate",
        "/tmp/handoff/candidate-aggregate", "--dmg",                                               "/tmp/artifacts/Maru.dmg", "--frozen-executable", "/tmp/artifacts/maru-session-host",
        "--manifest",                       "/tmp/artifacts/Maru-1.2.3-session-host-release.json",
    };
}

test "all commands bind context and pin only after identity authority" {
    for ([_]enum { pre_publish, verify_predecessor, publish_candidate, prepare_aggregate, finalize_aggregate }{ .pre_publish, .verify_predecessor, .publish_candidate, .prepare_aggregate, .finalize_aggregate }) |kind| {
        var trace = Trace{};
        var contexts = ContextReader{ .trace = &trace };
        var runners = RunnerReader{ .trace = &trace };
        var pinner = Pinner{ .trace = &trace };
        const pre = prePublishArgs("/usr/local/bin/gh");
        const predecessor = predecessorArgs("/usr/local/bin/gh");
        const candidate = candidateArgs("/usr/local/bin/gh");
        const prepare = prepareAggregateArgs("/usr/local/bin/gh");
        const finalize = finalizeAggregateArgs("/usr/local/bin/gh");
        var result = bootstrap.Bootstrap{};
        switch (kind) {
            .pre_publish => try bootstrap.bootstrapWith(std.testing.allocator, &pre, &contexts, &runners, &pinner, &result),
            .verify_predecessor => try bootstrap.bootstrapWith(std.testing.allocator, &predecessor, &contexts, &runners, &pinner, &result),
            .publish_candidate => try bootstrap.bootstrapWith(std.testing.allocator, &candidate, &contexts, &runners, &pinner, &result),
            .prepare_aggregate => try bootstrap.bootstrapWith(std.testing.allocator, &prepare, &contexts, &runners, &pinner, &result),
            .finalize_aggregate => try bootstrap.bootstrapWith(std.testing.allocator, &finalize, &contexts, &runners, &pinner, &result),
        }
        const view = result.value().?;
        try std.testing.expectEqualSlices(@TypeOf(trace.calls[0]), &.{ .context, .runner, .pin }, trace.calls[0..trace.count]);
        try std.testing.expectEqualStrings("/usr/local/bin/gh", view.github_cli);
        try std.testing.expectEqualStrings(cli_sha, pinner.seen_sha);
        try std.testing.expectEqualStrings(view.github_cli, pinner.seen_path[0..pinner.seen_path_len]);
        switch (view.command) {
            .pre_publish => |command| try std.testing.expectEqualStrings("/tmp/pre-publish-work", command.work_dir),
            .verify_predecessor => |command| try std.testing.expectEqualStrings("/tmp/work", command.work_dir),
            .publish_candidate => |command| {
                try std.testing.expectEqualStrings("123e4567-e89b-42d3-a456-426614174000", command.test_uuid);
                try std.testing.expectEqualStrings("/usr/local/bin/zig", command.zig);
                try std.testing.expectEqual(@as(u64, 123456), command.zig_size);
                try std.testing.expectEqualStrings("/tmp/attest/candidate-dmg.bundle.json", command.candidate_dmg_bundle);
                try std.testing.expectEqualStrings("/tmp/attest/candidate-frozen.bundle.json", command.candidate_frozen_bundle);
            },
            .prepare_candidate => |command| try std.testing.expectEqualStrings("/tmp/durable-stage3", command.durable_preparation),
            .prepare_candidate_aggregate => |command| try std.testing.expectEqualStrings("/tmp/handoff/candidate-aggregate", command.aggregate),
            .finalize_candidate_aggregate => |command| try std.testing.expectEqualStrings("/tmp/artifacts/Maru.dmg", command.dmg),
        }
        try std.testing.expect(!@hasField(bootstrap.PrePublish, "github_cli"));
        try std.testing.expect(!@hasField(bootstrap.VerifyPredecessor, "github_cli_sha256"));
        try std.testing.expect(!@hasField(bootstrap.PublishCandidate, "github_cli"));
        try std.testing.expect(!@hasField(bootstrap.PrepareCandidateAggregate, "github_cli"));
        try std.testing.expect(!@hasField(bootstrap.FinalizeCandidateAggregate, "github_cli_sha256"));
        var copied = result;
        try std.testing.expect(copied.value() == null);
        try std.testing.expectError(error.InvalidOwner, bootstrap.bootstrapWith(
            std.testing.allocator,
            &pre,
            &contexts,
            &runners,
            &pinner,
            &result,
        ));
        try std.testing.expectEqual(@as(usize, 3), trace.count);
    }

    var trace = Trace{};
    var contexts = ContextReader{ .trace = &trace };
    var runners = RunnerReader{ .trace = &trace };
    var pinner = Pinner{ .trace = &trace };
    var result = bootstrap.Bootstrap{};
    const maximum_path = "/" ++ ("g" ** (bootstrap.max_cli_path_bytes - 1));
    const args = predecessorArgs(maximum_path);
    try bootstrap.bootstrapWith(std.testing.allocator, &args, &contexts, &runners, &pinner, &result);
    try std.testing.expectEqual(bootstrap.max_cli_path_bytes, result.value().?.github_cli.len);
}

test "repository or tag drift fails before opening the CLI pathname" {
    var trace = Trace{};
    var contexts = ContextReader{ .trace = &trace };
    contexts.value.tag = "v1.2.4";
    var runners = RunnerReader{ .trace = &trace };
    var pinner = Pinner{ .trace = &trace };
    var result = bootstrap.Bootstrap{};
    const args = prePublishArgs("/does/not/exist");
    try std.testing.expectError(error.ContextMismatch, bootstrap.bootstrapWith(
        std.testing.allocator,
        &args,
        &contexts,
        &runners,
        &pinner,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 2), trace.count);
    try std.testing.expect(result.value() == null);
}

test "untrusted runner fails before binding or pinning filesystem authority" {
    var trace = Trace{};
    var contexts = ContextReader{ .trace = &trace };
    var runners = RunnerReader{ .trace = &trace, .fail = true };
    var pinner = Pinner{ .trace = &trace };
    var result = bootstrap.Bootstrap{};
    const args = predecessorArgs("/does/not/exist");
    try std.testing.expectError(error.UntrustedRunner, bootstrap.bootstrapWith(
        std.testing.allocator,
        &args,
        &contexts,
        &runners,
        &pinner,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 2), trace.count);
}

test "actual CLI authority rejects non executable and digest drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "trusted-gh" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "gh", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var trace = Trace{};
    var contexts = ContextReader{ .trace = &trace };
    var runners = RunnerReader{ .trace = &trace };
    var real = bootstrap.CurrentPinner{};
    var result = bootstrap.Bootstrap{};
    const args = prePublishArgs(path);
    try std.testing.expectError(error.NotExecutable, bootstrap.bootstrapWith(
        std.testing.allocator,
        &args,
        &contexts,
        &runners,
        &real,
        &result,
    ));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
    var digest_drift = prePublishArgs(path);
    digest_drift[8] = "0" ** 64;
    var second_trace = Trace{};
    var second_contexts = ContextReader{ .trace = &second_trace };
    var second_runners = RunnerReader{ .trace = &second_trace };
    var second_result = bootstrap.Bootstrap{};
    try std.testing.expectError(error.DigestMismatch, bootstrap.bootstrapWith(
        std.testing.allocator,
        &digest_drift,
        &second_contexts,
        &second_runners,
        &real,
        &second_result,
    ));
}

test "process entrypoint compiles without treating the local shell as trusted CI" {
    const args = predecessorArgs("/does/not/exist");
    var result = bootstrap.Bootstrap{};
    bootstrap.current(std.testing.allocator, &args, &result) catch {};
}
