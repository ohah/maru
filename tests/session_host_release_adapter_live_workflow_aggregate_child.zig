//! The live stage-5/6 owner derives command identity from the closed argv contract, launches one
//! actual bounded child with only the reviewed workflow environment, and applies its observation
//! directly to the reducer without exposing partial bytes or raw process errors.

const std = @import("std");
const c = std.c;
const child = @import("release_adapter_live_workflow_aggregate_child");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

const source_sha = "0123456789abcdef0123456789abcdef01234567";

test "aggregate child applies canonical prepare success from actual separated streams" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);

    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try std.testing.expectEqual(@as(u8, 5), state.next_index);
    try std.testing.expect(state.aggregate_present);
    try std.testing.expectEqual(phase.Outcome.active, state.outcome);
    try fixture.expectInvoked();
}

test "aggregate child preserves all closed finalize outcomes" {
    const rows = [_]struct { tag: []const u8, outcome: phase.Outcome }{
        .{ .tag = "v1.2.0", .outcome = .active },
        .{ .tag = "v1.2.21", .outcome = .audit_required },
        .{ .tag = "v1.2.22", .outcome = .audit_required },
    };
    for (rows) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(5);
        var storage: child.Storage = .{};
        var manifest_storage: [std.fs.max_path_bytes]u8 = undefined;
        const args = try finalizeArgs(row.tag, &manifest_storage);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            std.time.ns_per_s,
            &storage,
        ));
        try std.testing.expectEqual(row.outcome, state.outcome);
        if (row.outcome == .active) try std.testing.expectEqual(@as(u8, 6), state.next_index);
    }
    for (rows[1..]) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs(row.tag);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            std.time.ns_per_s,
            &storage,
        ));
        try std.testing.expectEqual(row.outcome, state.outcome);
    }
}

test "signal framing drift and both stream failures conservatively terminate reducer state" {
    const rows = [_]struct { tag: []const u8, result: child.RunResult, budget: i128 }{
        .{ .tag = "v1.2.9", .result = .observed, .budget = std.time.ns_per_s },
        .{ .tag = "v1.2.10", .result = .observed, .budget = std.time.ns_per_s },
        .{ .tag = "v1.2.11", .result = .observation_failed, .budget = std.time.ns_per_s },
        .{ .tag = "v1.2.12", .result = .observation_failed, .budget = std.time.ns_per_s },
        .{ .tag = "v1.2.90", .result = .observation_failed, .budget = 80 * std.time.ns_per_ms },
    };
    for (rows) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs(row.tag);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(row.result, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            row.budget,
            &storage,
        ));
        try std.testing.expectEqual(phase.Outcome.audit_required, state.outcome);
    }

    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    const missing: [:0]const u8 = "/definitely/missing/maru-aggregate-child";
    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        missing,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try std.testing.expectEqual(phase.Outcome.audit_required, state.outcome);
}

test "nonaggregate wrong-stage and terminal invocations fail before fork" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    var storage: child.Storage = .{};

    var state = try stateAt(4);
    var manifest_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cleanup = try cleanupArgs("v1.2.0", &manifest_storage);
    try std.testing.expectError(error.InvalidCommand, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &cleanup,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();

    const prepare = prepareArgs("v1.2.0");
    storage.in_use = true;
    state = try stateAt(4);
    try std.testing.expectError(error.InvalidStorage, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    storage.in_use = false;
    try fixture.expectNotInvoked();

    try std.testing.expectError(error.InvalidExecutable, child.runAndApply(
        std.testing.io,
        &state,
        "relative-validator",
        &prepare,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try std.testing.expectError(error.InvalidBudget, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        0,
        &storage,
    ));
    try fixture.expectNotInvoked();

    state = .{};
    try std.testing.expectError(error.UnexpectedStage, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();

    state = try stateAt(8);
    try std.testing.expectError(error.TerminalState, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "environment inventory and command context drift fail before fork" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const args = prepareArgs("v1.2.0");
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    var environment_storage: EnvironmentStorage = undefined;
    var environment = try trustedEnvironment("v1.2.0", &environment_storage);

    try std.testing.expectError(error.MissingKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        environment[0 .. environment.len - 1],
        std.time.ns_per_s,
        &storage,
    ));
    environment[10] = environment[0];
    try std.testing.expectError(error.DuplicateKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.0", &environment_storage);
    environment[10].name = "HOME";
    try std.testing.expectError(error.UnknownKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.1", &environment_storage);
    try std.testing.expectError(error.ContextMismatch, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.0", &environment_storage);
    environment[12].value = "self-hosted";
    try std.testing.expectError(error.UntrustedRunner, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "argument alias with owner storage fails before storage can overwrite input" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const command = "prepare-candidate-aggregate";
    @memcpy(storage.argument_bytes[0][0..command.len], command);
    var args = prepareArgs("v1.2.0");
    args[0] = storage.argument_bytes[0][0..command.len];
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();

    const canonical = prepareArgs("v1.2.0");
    storage = .{};
    var canonical_environment_storage: EnvironmentStorage = undefined;
    const canonical_environment = try trustedEnvironment("v1.2.0", &canonical_environment_storage);
    const entry_address = std.mem.alignForward(usize, @intFromPtr(&storage.argument_bytes), @alignOf(context.Entry));
    const aliased_entries: [*]context.Entry = @ptrFromInt(entry_address);
    @memcpy(aliased_entries[0..canonical_environment.len], &canonical_environment);
    state = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &canonical,
        aliased_entries[0..canonical_environment.len],
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();

    storage = .{};
    const descriptor_address = std.mem.alignForward(usize, @intFromPtr(&storage.argument_bytes), @alignOf([]const u8));
    const aliased_descriptors: [*][]const u8 = @ptrFromInt(descriptor_address);
    @memcpy(aliased_descriptors[0..canonical.len], &canonical);
    state = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        aliased_descriptors[0..canonical.len],
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();

    storage = .{};
    const aliased_state: *phase.State = @ptrCast(&storage.argv);
    aliased_state.* = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        aliased_state,
        fixture.executable,
        &canonical,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "closed child environment excludes ambient secrets" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        std.time.ns_per_s,
        &storage,
    ));
    try std.testing.expectEqual(phase.Outcome.active, state.outcome);
}

test "repeated aggregate child runs leave parent descriptor count unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const before = try countOpenFds();
    for (0..20) |_| {
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs("v1.2.0");
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment("v1.2.0", &environment_storage);
        _ = try child.runAndApply(std.testing.io, &state, fixture.executable, &args, &environment, std.time.ns_per_s, &storage);
    }
    try std.testing.expectEqual(before, try countOpenFds());
}

const EnvironmentStorage = struct {
    ref: [128]u8 = undefined,
    workflow: [256]u8 = undefined,
};

fn trustedEnvironment(tag: []const u8, storage: *EnvironmentStorage) ![child.environment_entry_count]context.Entry {
    const ref = try std.fmt.bufPrint(&storage.ref, "refs/tags/{s}", .{tag});
    const workflow = try std.fmt.bufPrint(&storage.workflow, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{tag});
    return .{
        .{ .name = "GITHUB_REPOSITORY", .value = "ohah/maru" },
        .{ .name = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .name = "GITHUB_REF", .value = ref },
        .{ .name = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .name = "GITHUB_REF_NAME", .value = tag },
        .{ .name = "GITHUB_SHA", .value = source_sha },
        .{ .name = "GITHUB_WORKFLOW_REF", .value = workflow },
        .{ .name = "GITHUB_RUN_ID", .value = "333" },
        .{ .name = "GITHUB_RUN_ATTEMPT", .value = "2" },
        .{ .name = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .name = "GITHUB_REF_PROTECTED", .value = "true" },
        .{ .name = "GITHUB_WORKFLOW_SHA", .value = source_sha },
        .{ .name = "RUNNER_ENVIRONMENT", .value = "github-hosted" },
        .{ .name = "RUNNER_OS", .value = "macOS" },
        .{ .name = "RUNNER_ARCH", .value = "ARM64" },
    };
}

fn prepareArgs(tag: []const u8) [21][]const u8 {
    return .{
        "prepare-candidate-aggregate", "--repo",                          "ohah/maru",                  "--tag",                                                            tag,
        "--github-cli",                "/tmp/maru-owner-gh",              "--github-cli-sha256",        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--evidence",
        "/tmp/maru-owner-evidence",    "--candidate-dmg-bundle",          "/tmp/maru-owner-dmg-bundle", "--candidate-frozen-bundle",                                        "/tmp/maru-owner-frozen-bundle",
        "--evidence-bundle",           "/tmp/maru-owner-evidence-bundle", "--manifest-bundle",          "/tmp/maru-owner-manifest-bundle",                                  "--aggregate",
        "/tmp/maru-owner-aggregate",
    };
}

fn finalizeArgs(tag: []const u8, manifest_storage: []u8) ![17][]const u8 {
    const manifest = try std.fmt.bufPrint(manifest_storage, "/tmp/Maru-{s}-session-host-release.json", .{tag[1..]});
    return .{
        "finalize-candidate-aggregate", "--repo",             "ohah/maru",           "--tag",                                                            tag,
        "--github-cli",                 "/tmp/maru-owner-gh", "--github-cli-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--aggregate",
        "/tmp/maru-owner-aggregate",    "--dmg",              "/tmp/maru-owner.dmg", "--frozen-executable",                                              "/tmp/maru-owner-frozen",
        "--manifest",                   manifest,
    };
}

fn cleanupArgs(tag: []const u8, manifest_storage: []u8) ![17][]const u8 {
    var args = try finalizeArgs(tag, manifest_storage);
    args[0] = "cleanup-candidate-aggregate";
    return args;
}

fn stateAt(index: usize) !phase.State {
    const stages = [_]phase.Stage{
        .candidate_pinning, .candidate_attestation, .draft_authoring, .authored_attestation,
        .aggregate_prepare, .aggregate_finalize,    .publication,     .aggregate_cleanup,
    };
    var state: phase.State = .{};
    for (stages[0..index]) |stage| try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
    return state;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    executable_storage: [std.fs.max_path_bytes:0]u8,
    marker_storage: [std.fs.max_path_bytes:0]u8,
    executable: [:0]const u8,

    fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try self.tmp.dir.realPath(std.testing.io, &root);
        self.executable = try std.fmt.bufPrintZ(&self.executable_storage, "{s}/validator-fixture", .{root[0..root_len]});
        const marker = try std.fmt.bufPrintZ(&self.marker_storage, "{s}/invoked", .{root[0..root_len]});
        var script_storage: [4096]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_storage,
            \\#!/bin/sh
            \\/usr/bin/touch '{s}'
            \\case "$GITHUB_REF_NAME" in
            \\  v1.2.0) if [ -n "${{GH_TOKEN+x}}${{HOME+x}}" ] || [ "$RUNNER_ENVIRONMENT|$RUNNER_OS|$RUNNER_ARCH|$GITHUB_WORKFLOW_SHA" != "github-hosted|macOS|ARM64|{s}" ]; then printf 'cleanup_failed\n' >&2; exit 22; fi; printf 'success\n' >&2; exit 0 ;;
            \\  v1.2.21) printf 'audit_required\n' >&2; exit 21 ;;
            \\  v1.2.22) printf 'cleanup_failed\n' >&2; exit 22 ;;
            \\  v1.2.9) kill -TERM $$ ;;
            \\  v1.2.10) printf x; printf 'success\n' >&2; exit 0 ;;
            \\  v1.2.11) printf 'success\ntrailing' >&2; exit 0 ;;
            \\  v1.2.12) printf xx; exit 0 ;;
            \\  v1.2.90) (trap '' TERM; sleep 10) & exit 0 ;;
            \\  *) printf 'cleanup_failed\n' >&2; exit 22 ;;
            \\esac
        , .{ marker, source_sha });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "validator-fixture", .data = script });
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(self.executable.ptr, 0o700));
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn expectInvoked(self: *Fixture) !void {
        try self.tmp.dir.access(std.testing.io, "invoked", .{});
    }

    fn expectNotInvoked(self: *Fixture) !void {
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.access(std.testing.io, "invoked", .{}));
    }
};

fn countOpenFds() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
