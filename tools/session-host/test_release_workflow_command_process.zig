//! Actual wrapper->validator process chain and local timing with an isolated checkpoint root.

const std = @import("std");
const c = std.c;
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");
const report_mod = @import("release_workflow_command_process_report");
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const max_iterations: usize = @intCast(report_mod.max_iterations);
const stage_count = 5;

pub fn main(init: std.process.Init) !void {
    var input = try init.minimal.args.iterateAllocator(init.gpa);
    defer input.deinit();
    _ = input.next();
    const wrapper_input = input.next() orelse return error.MissingWrapper;
    const validator_input = input.next() orelse return error.MissingValidator;
    const iteration_text = input.next() orelse return error.MissingIterations;
    if (input.next() != null) return error.TooManyArguments;
    const iterations = try std.fmt.parseInt(usize, iteration_text, 10);
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterations;
    const wrapper = try std.Io.Dir.cwd().realPathFileAlloc(init.io, wrapper_input, init.gpa);
    defer init.gpa.free(wrapper);
    const validator_fixture = try std.Io.Dir.cwd().realPathFileAlloc(init.io, validator_input, init.gpa);
    defer init.gpa.free(validator_fixture);

    const warm = try std.process.run(init.gpa, init.io, .{ .argv = &.{"/usr/bin/true"}, .stdout_limit = .limited(1), .stderr_limit = .limited(1) });
    defer init.gpa.free(warm.stdout);
    defer init.gpa.free(warm.stderr);
    switch (warm.term) {
        .exited => |code| if (code != 0) return error.WarmupFailed,
        else => return error.WarmupFailed,
    }
    const fd_before = try openFdCount(init.io);
    var durations: [stage_count][max_iterations]u64 = undefined;
    var successful: usize = 0;
    var failures: usize = 0;
    var pid_collisions: usize = 0;
    var checkpoint_residue: usize = 0;
    for (0..iterations) |index| {
        const sample = runSuccessChain(init.io, init.gpa, wrapper, validator_fixture, index) catch |err| {
            std.debug.print("workflow command process {d} failed: {s}\n", .{ index, @errorName(err) });
            failures += 1;
            continue;
        };
        for (0..stage_count) |stage_index| durations[stage_index][successful] = sample.durations[stage_index];
        pid_collisions += sample.pid_collisions;
        checkpoint_residue += sample.checkpoint_residue;
        successful += 1;
    }
    try runTerminalCase(init.io, init.gpa, wrapper, validator_fixture, iterations);
    if (successful == 0) return error.NoSuccessfulRuns;
    const fd_after = try openFdCount(init.io);
    if (fd_after < fd_before) return error.ProcessInvariantFailed;
    var times: [stage_count]report_mod.Times = undefined;
    for (0..stage_count) |index| times[index] = summarize(durations[index][0..successful]);
    const report: report_mod.Report = .{
        .schema = report_mod.schema,
        .iterations = iterations,
        .successful_runs = successful,
        .draft_authoring_ns = times[0],
        .aggregate_prepare_ns = times[1],
        .aggregate_finalize_ns = times[2],
        .publication_ns = times[3],
        .aggregate_cleanup_ns = times[4],
        .failures = failures,
        .child_pid_collisions = pid_collisions,
        .parent_fd_delta = fd_after - fd_before,
        .checkpoint_residue = checkpoint_residue,
    };
    var storage: [4096]u8 = undefined;
    const bytes = try report_mod.render(&storage, report);
    var parsed = try report_mod.parseCanonical(init.gpa, bytes);
    defer parsed.deinit();
    var output_buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    if (successful != iterations or failures != 0 or pid_collisions != 0 or report.parent_fd_delta != 0 or checkpoint_residue != 0)
        return error.ProcessInvariantFailed;
}

const Sample = struct { durations: [stage_count]u64, pid_collisions: usize, checkpoint_residue: usize };

fn runSuccessChain(io: std.Io, allocator: std.mem.Allocator, wrapper: []const u8, fixture: []const u8, index: usize) !Sample {
    var workspace = try Workspace.init(io, allocator, fixture, index, "success");
    defer workspace.deinit(io);
    var environment = try workspace.environment(allocator);
    defer environment.deinit();
    const token = try workspace.bootstrap(io, allocator);
    try workspace.settle(io, allocator, token, .candidate_pinning);
    try workspace.settle(io, allocator, token, .candidate_attestation);
    var durations: [stage_count]u64 = undefined;
    var child_pids: [stage_count]c.pid_t = undefined;

    var stage3 = workspace.prepareArgs();
    durations[0] = try runWrapper(io, allocator, wrapper, workspace.checkpointPath(), token, &stage3, &environment);
    child_pids[0] = try workspace.readPid(io, workspace.preparationPath());
    try workspace.settle(io, allocator, token, .authored_attestation);
    var prepare_aggregate = workspace.prepareAggregateArgs();
    durations[1] = try runWrapper(io, allocator, wrapper, workspace.checkpointPath(), token, &prepare_aggregate, &environment);
    child_pids[1] = try workspace.readPid(io, workspace.aggregatePath());
    var finalize_aggregate = workspace.finalizeAggregateArgs();
    durations[2] = try runWrapper(io, allocator, wrapper, workspace.checkpointPath(), token, &finalize_aggregate, &environment);
    child_pids[2] = try workspace.readPid(io, workspace.manifestPath());
    var publication = workspace.publicationArgs();
    durations[3] = try runWrapper(io, allocator, wrapper, workspace.checkpointPath(), token, &publication, &environment);
    child_pids[3] = try workspace.readPid(io, workspace.preparationPath());
    var cleanup = workspace.cleanupArgs();
    durations[4] = try runWrapper(io, allocator, wrapper, workspace.checkpointPath(), token, &cleanup, &environment);
    child_pids[4] = try workspace.readPid(io, workspace.manifestPath());
    var collisions: usize = 0;
    for (child_pids, 0..) |pid, left| {
        if (pid == c.getpid()) collisions += 1;
        for (child_pids[0..left]) |earlier| if (pid == earlier) {
            collisions += 1;
        };
    }
    try workspace.expectFinal(io, allocator, token, .succeeded);
    workspace.remove(io);
    return .{ .durations = durations, .pid_collisions = collisions, .checkpoint_residue = if (workspace.exists(io)) 1 else 0 };
}

fn runTerminalCase(io: std.Io, allocator: std.mem.Allocator, wrapper: []const u8, fixture: []const u8, index: usize) !void {
    var workspace = try Workspace.init(io, allocator, fixture, index, "local-failure");
    defer workspace.deinit(io);
    var environment = try workspace.environment(allocator);
    defer environment.deinit();
    const token = try workspace.bootstrap(io, allocator);
    try workspace.settle(io, allocator, token, .candidate_pinning);
    try workspace.settle(io, allocator, token, .candidate_attestation);
    var args = workspace.prepareArgs();
    try runWrapperExpectFailure(io, allocator, wrapper, workspace.checkpointPath(), token, &args, &environment);
    try workspace.expectFinal(io, allocator, token, .local_failure);
}

fn runWrapper(io: std.Io, allocator: std.mem.Allocator, wrapper: []const u8, root: []const u8, token: []const u8, args: []const []const u8, environment: *const std.process.Environ.Map) !u64 {
    const started = monotonicNs();
    const result = try invokeWrapper(io, allocator, wrapper, root, token, args, environment);
    const elapsed = monotonicNs() - started;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.WrapperFailed,
        else => return error.WrapperFailed,
    }
    if (result.stdout.len != 0 or result.stderr.len != 0 or elapsed == 0) return error.UnexpectedOutput;
    return elapsed;
}

fn runWrapperExpectFailure(io: std.Io, allocator: std.mem.Allocator, wrapper: []const u8, root: []const u8, token: []const u8, args: []const []const u8, environment: *const std.process.Environ.Map) !void {
    const result = try invokeWrapper(io, allocator, wrapper, root, token, args, environment);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return error.ExpectedFailure,
        else => return error.WrapperFailed,
    }
    if (result.stdout.len != 0 or result.stderr.len != 0) return error.UnexpectedOutput;
}

fn invokeWrapper(io: std.Io, allocator: std.mem.Allocator, wrapper: []const u8, root: []const u8, token: []const u8, args: []const []const u8, environment: *const std.process.Environ.Map) !std.process.RunResult {
    var argv: [1 + 3 + 39][]const u8 = undefined;
    argv[0] = wrapper;
    argv[1] = "run";
    argv[2] = root;
    argv[3] = token;
    for (args, 0..) |arg, index| argv[index + 4] = arg;
    return std.process.run(allocator, io, .{ .argv = argv[0 .. args.len + 4], .environ_map = environment, .stdout_limit = .limited(1), .stderr_limit = .limited(1) });
}

const Workspace = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    mode: []const u8,
    validator: []u8,
    checkpoint_path: []u8,
    preparation: []u8,
    aggregate: []u8,
    manifest: []u8,
    dmg: []u8,
    frozen_executable: []u8,
    dmg_work: []u8,
    baseline_workspace: []u8,
    app_main_executable: []u8,
    app_cli_executable: []u8,
    source_root: []u8,
    zig_path: []u8,
    candidate_dmg_bundle: []u8,
    candidate_frozen_bundle: []u8,
    evidence: []u8,
    evidence_bundle: []u8,
    manifest_bundle: []u8,
    validator_sha: [64]u8,
    token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = @splat(0),
    token_len: usize = 0,
    removed: bool = false,

    fn init(io: std.Io, allocator: std.mem.Allocator, fixture: []const u8, index: usize, mode: []const u8) !Workspace {
        var template_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const template = try std.fmt.bufPrintZ(&template_storage, "/private/tmp/maru-live-command-{d}-{s}.XXXXXX", .{ index, mode });
        const created = std.mem.span(mkdtemp(template.ptr) orelse return error.TempRootFailed);
        const root = try allocator.dupe(u8, created);
        errdefer allocator.free(root);
        var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
        defer dir.close(io);
        try dir.createDirPath(io, "zig-out/bin");
        try dir.createDir(io, "checkpoint", .default_dir);
        try dir.createDir(io, "work", .default_dir);
        var checkpoint_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const checkpoint_path = try std.fmt.bufPrintZ(&checkpoint_storage, "{s}/checkpoint", .{root});
        if (c.chmod(checkpoint_path.ptr, 0o700) != 0) return error.PrivateRootFailed;
        const fixture_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(fixture_bytes);
        try dir.writeFile(io, .{ .sub_path = "zig-out/bin/maru-session-host-release-validator", .data = fixture_bytes });
        const validator = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/maru-session-host-release-validator", .{root});
        errdefer allocator.free(validator);
        var validator_z: [std.fs.max_path_bytes:0]u8 = undefined;
        const validator_path = try std.fmt.bufPrintZ(&validator_z, "{s}", .{validator});
        if (c.chmod(validator_path.ptr, 0o755) != 0) return error.ExecutableModeFailed;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fixture_bytes, &digest, .{});
        const checkpoint_path_owned = try std.fmt.allocPrint(allocator, "{s}/checkpoint", .{root});
        errdefer allocator.free(checkpoint_path_owned);
        const preparation = try std.fmt.allocPrint(allocator, "{s}/work/{s}", .{ root, if (std.mem.eql(u8, mode, "local-failure")) "local-failure" else "preparation" });
        errdefer allocator.free(preparation);
        const aggregate = try std.fmt.allocPrint(allocator, "{s}/work/aggregate", .{root});
        errdefer allocator.free(aggregate);
        const manifest = try std.fmt.allocPrint(allocator, "{s}/work/Maru-1.2.3-session-host-release.json", .{root});
        errdefer allocator.free(manifest);
        const dmg = try std.fmt.allocPrint(allocator, "{s}/work/Maru-1.2.3-universal.dmg", .{root});
        errdefer allocator.free(dmg);
        const frozen_executable = try std.fmt.allocPrint(allocator, "{s}/work/maru-session-host-1.2.3", .{root});
        errdefer allocator.free(frozen_executable);
        const dmg_work = try std.fmt.allocPrint(allocator, "{s}/work/dmg", .{root});
        errdefer allocator.free(dmg_work);
        const baseline_workspace = try std.fmt.allocPrint(allocator, "{s}/work/baseline", .{root});
        errdefer allocator.free(baseline_workspace);
        const app_main_executable = try std.fmt.allocPrint(allocator, "{s}/work/maru-macos-app", .{root});
        errdefer allocator.free(app_main_executable);
        const app_cli_executable = try std.fmt.allocPrint(allocator, "{s}/work/maru", .{root});
        errdefer allocator.free(app_cli_executable);
        const source_root = try std.fmt.allocPrint(allocator, "{s}/source", .{root});
        errdefer allocator.free(source_root);
        const zig_path = try std.fmt.allocPrint(allocator, "{s}/work/zig-placeholder", .{root});
        errdefer allocator.free(zig_path);
        const candidate_dmg_bundle = try std.fmt.allocPrint(allocator, "{s}/work/candidate-dmg.json", .{root});
        errdefer allocator.free(candidate_dmg_bundle);
        const candidate_frozen_bundle = try std.fmt.allocPrint(allocator, "{s}/work/candidate-frozen.json", .{root});
        errdefer allocator.free(candidate_frozen_bundle);
        const evidence = try std.fmt.allocPrint(allocator, "{s}/work/evidence.json", .{root});
        errdefer allocator.free(evidence);
        const evidence_bundle = try std.fmt.allocPrint(allocator, "{s}/work/evidence-bundle.json", .{root});
        errdefer allocator.free(evidence_bundle);
        const manifest_bundle = try std.fmt.allocPrint(allocator, "{s}/work/manifest-bundle.json", .{root});
        errdefer allocator.free(manifest_bundle);
        return .{
            .allocator = allocator,
            .root = root,
            .mode = mode,
            .validator = validator,
            .checkpoint_path = checkpoint_path_owned,
            .preparation = preparation,
            .aggregate = aggregate,
            .manifest = manifest,
            .dmg = dmg,
            .frozen_executable = frozen_executable,
            .dmg_work = dmg_work,
            .baseline_workspace = baseline_workspace,
            .app_main_executable = app_main_executable,
            .app_cli_executable = app_cli_executable,
            .source_root = source_root,
            .zig_path = zig_path,
            .candidate_dmg_bundle = candidate_dmg_bundle,
            .candidate_frozen_bundle = candidate_frozen_bundle,
            .evidence = evidence,
            .evidence_bundle = evidence_bundle,
            .manifest_bundle = manifest_bundle,
            .validator_sha = std.fmt.bytesToHex(digest, .lower),
        };
    }

    fn deinit(self: *Workspace, io: std.Io) void {
        if (!self.removed) std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
        self.allocator.free(self.manifest_bundle);
        self.allocator.free(self.evidence_bundle);
        self.allocator.free(self.evidence);
        self.allocator.free(self.candidate_frozen_bundle);
        self.allocator.free(self.candidate_dmg_bundle);
        self.allocator.free(self.app_cli_executable);
        self.allocator.free(self.app_main_executable);
        self.allocator.free(self.zig_path);
        self.allocator.free(self.source_root);
        self.allocator.free(self.baseline_workspace);
        self.allocator.free(self.dmg_work);
        self.allocator.free(self.frozen_executable);
        self.allocator.free(self.dmg);
        self.allocator.free(self.manifest);
        self.allocator.free(self.aggregate);
        self.allocator.free(self.preparation);
        self.allocator.free(self.checkpoint_path);
        self.allocator.free(self.validator);
        self.allocator.free(self.root);
    }

    fn remove(self: *Workspace, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch return;
        self.removed = true;
    }

    fn exists(self: *Workspace, io: std.Io) bool {
        return if (std.Io.Dir.cwd().access(io, self.root, .{})) |_| true else |_| false;
    }

    fn checkpointPath(self: *Workspace) []const u8 {
        return self.checkpoint_path;
    }

    fn preparationPath(self: *Workspace) []const u8 {
        return self.preparation;
    }

    fn aggregatePath(self: *Workspace) []const u8 {
        return self.aggregate;
    }

    fn manifestPath(self: *Workspace) []const u8 {
        return self.manifest;
    }

    fn bootstrap(self: *Workspace, io: std.Io, allocator: std.mem.Allocator) ![:0]const u8 {
        _ = io;
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_storage, "{s}/checkpoint", .{self.root});
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, path);
        defer root.deinit() catch {};
        const identity = try checkpoint.initializeOrRecoverInitial(allocator, &root, workflowContext());
        const token = try checkpoint.encodeRootIdentity(&self.token_storage, identity);
        self.token_len = token.len;
        return self.token_storage[0..self.token_len :0];
    }

    fn settle(self: *Workspace, io: std.Io, allocator: std.mem.Allocator, token: []const u8, stage: phase.Stage) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_storage, "{s}/checkpoint", .{self.root});
        var root: checkpoint.Root = .{};
        try checkpoint.openRootExpected(&root, path, try checkpoint.decodeRootIdentity(token));
        defer root.deinit() catch {};
        _ = try checkpoint.admit(allocator, &root, stage, workflowContext());
        _ = try checkpoint.advance(allocator, &root, stage, .succeeded, workflowContext());
        _ = io;
    }

    fn expectFinal(self: *Workspace, io: std.Io, allocator: std.mem.Allocator, token: []const u8, expected: phase.Outcome) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_storage, "{s}/checkpoint", .{self.root});
        var root: checkpoint.Root = .{};
        try checkpoint.openRootExpected(&root, path, try checkpoint.decodeRootIdentity(token));
        defer root.deinit() catch {};
        const count: u8 = if (expected == .succeeded) 8 else 3;
        const state = try checkpoint.reopen(allocator, &root, count, workflowContext());
        try std.testing.expectEqual(expected, state.outcome);
        _ = io;
    }

    fn environment(self: *Workspace, allocator: std.mem.Allocator) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(allocator);
        errdefer map.deinit();
        const values = [_]struct { key: []const u8, value: []const u8 }{
            .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },
            .{ .key = "GITHUB_REPOSITORY_ID", .value = "12345" },
            .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },
            .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
            .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },
            .{ .key = "GITHUB_SHA", .value = source_sha },
            .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" },
            .{ .key = "GITHUB_RUN_ID", .value = "333" },
            .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },
            .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
            .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },
            .{ .key = "GITHUB_WORKFLOW_SHA", .value = source_sha },
            .{ .key = "RUNNER_ENVIRONMENT", .value = "github-hosted" },
            .{ .key = "RUNNER_OS", .value = "macOS" },
            .{ .key = "RUNNER_ARCH", .value = "ARM64" },
            .{ .key = "GITHUB_WORKSPACE", .value = self.root },
            .{ .key = "GH_TOKEN", .value = "inert-test-token" },
        };
        for (values) |entry| try map.put(entry.key, entry.value);
        return map;
    }

    fn readPid(self: *Workspace, io: std.Io, marker: []const u8) !c.pid_t {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, marker, self.allocator, .limited(64));
        defer self.allocator.free(bytes);
        return std.fmt.parseInt(c.pid_t, std.mem.trim(u8, bytes, "\r\n"), 10);
    }

    fn prepareArgs(self: *Workspace) [39][]const u8 {
        return .{
            "prepare-candidate",          "--repo",                               "ohah/maru",              "--tag",                "v1.2.3",                "--github-cli",         self.validator,           "--github-cli-sha256",     &self.validator_sha,
            "--test-uuid",                "123e4567-e89b-42d3-a456-426614174000", "--dmg",                  self.dmg,               "--frozen-executable",   self.frozen_executable, "--dmg-work",             self.dmg_work,             "--baseline-workspace",
            self.baseline_workspace,      "--app-main-executable",                self.app_main_executable, "--app-cli-executable", self.app_cli_executable, "--manifest",           self.manifestPath(),      "--source-root",           self.source_root,
            "--zig",                      self.zig_path,                          "--zig-size",             "1",                    "--zig-sha256",          &self.validator_sha,    "--candidate-dmg-bundle", self.candidate_dmg_bundle, "--candidate-frozen-bundle",
            self.candidate_frozen_bundle, "--durable-preparation",                self.preparationPath(),
        };
    }

    fn prepareAggregateArgs(self: *Workspace) [21][]const u8 {
        return .{
            "prepare-candidate-aggregate", "--repo",      "ohah/maru",              "--tag",                   "v1.2.3",                    "--github-cli",               self.validator,      "--github-cli-sha256", &self.validator_sha,
            "--evidence",                  self.evidence, "--candidate-dmg-bundle", self.candidate_dmg_bundle, "--candidate-frozen-bundle", self.candidate_frozen_bundle, "--evidence-bundle", self.evidence_bundle,  "--manifest-bundle",
            self.manifest_bundle,          "--aggregate", self.aggregatePath(),
        };
    }

    fn finalizeAggregateArgs(self: *Workspace) [17][]const u8 {
        return .{ "finalize-candidate-aggregate", "--repo", "ohah/maru", "--tag", "v1.2.3", "--github-cli", self.validator, "--github-cli-sha256", &self.validator_sha, "--aggregate", self.aggregatePath(), "--dmg", self.dmg, "--frozen-executable", self.frozen_executable, "--manifest", self.manifestPath() };
    }

    fn publicationArgs(self: *Workspace) [17][]const u8 {
        return .{ "resume-candidate-publication", "--repo", "ohah/maru", "--tag", "v1.2.3", "--github-cli", self.validator, "--github-cli-sha256", &self.validator_sha, "--preparation", self.preparationPath(), "--aggregate", self.aggregatePath(), "--dmg", self.dmg, "--frozen-executable", self.frozen_executable };
    }

    fn cleanupArgs(self: *Workspace) [17][]const u8 {
        return .{ "cleanup-candidate-aggregate", "--repo", "ohah/maru", "--tag", "v1.2.3", "--github-cli", self.validator, "--github-cli-sha256", &self.validator_sha, "--aggregate", self.aggregatePath(), "--dmg", self.dmg, "--frozen-executable", self.frozen_executable, "--manifest", self.manifestPath() };
    }
};

fn summarize(values: []u64) report_mod.Times {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{ .median = values[values.len / 2], .p95 = values[@min(values.len - 1, (values.len * 95 + 99) / 100 - 1)], .max = values[values.len - 1] };
}

fn workflowContext() context.Context {
    return .{ .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = source_sha, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };
}

fn openFdCount(io: std.Io) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: u64 = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn monotonicNs() u64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC_RAW, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

const source_sha = "0123456789abcdef0123456789abcdef01234567";
