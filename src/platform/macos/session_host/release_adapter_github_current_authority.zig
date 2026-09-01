//! Authenticates the current GitHub release workflow and its protected-environment deployment.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const repository = @import("release_adapter_github_repository");
const run = @import("release_adapter_github_run");
const environment = @import("release_adapter_github_environment");
const deployment = @import("release_adapter_github_deployment");
const transport_macos = @import("release_adapter_github_transport_macos");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");

pub const max_total_commands: usize = 5 + deployment.max_collection_entries;
pub const Error = error{ InvalidOwner, ClockFailed, TimedOut };
pub const PinnedExecutable = cli_authority.PinnedExecutable;

pub const View = struct {
    repository_id: u64,
    run_id: u64,
    run_attempt: u64,
    source_commit: []const u8,
    job_id: u64,
    deployment_id: u64,
    environment_id: u64,
    protected_environment: bool,
};

pub const CurrentGitHubAuthority = struct {
    owner: ?*CurrentGitHubAuthority = null,
    repository_id: u64 = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    source_commit: [40]u8 = @splat(0),
    job_id: u64 = 0,
    deployment_id: u64 = 0,
    environment_id: u64 = 0,
    protected_environment: bool = false,

    pub fn value(self: *const CurrentGitHubAuthority) ?View {
        if (self.owner != self) return null;
        return .{
            .repository_id = self.repository_id,
            .run_id = self.run_id,
            .run_attempt = self.run_attempt,
            .source_commit = &self.source_commit,
            .job_id = self.job_id,
            .deployment_id = self.deployment_id,
            .environment_id = self.environment_id,
            .protected_environment = self.protected_environment,
        };
    }

    pub fn deinit(self: *CurrentGitHubAuthority) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const PinnedExecutable };

const RealClock = struct {
    fn now(_: *@This()) !i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};

const RealAuthority = struct {
    pinned: *const PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

pub fn authenticate(io: std.Io, allocator: std.mem.Allocator, expected: context_mod.Context, cli: Cli, token: []const u8, response: []u8, budget_ns: i128, result: *CurrentGitHubAuthority) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = transport_macos.BoundedExecutor{ .io = io };
    var clock = RealClock{};
    return authenticateWith(&authority, &executor, &clock, allocator, expected, cli.path, token, response, budget_ns, result);
}

pub fn authenticateUntil(io: std.Io, allocator: std.mem.Allocator, expected: context_mod.Context, cli: Cli, token: []const u8, response: []u8, deadline: *deadline_mod.Deadline, result: *CurrentGitHubAuthority) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = transport_macos.BoundedExecutor{ .io = io };
    return authenticateUntilWith(&authority, &executor, deadline, allocator, expected, cli.path, token, response, result);
}

pub fn authenticateWith(authority: anytype, executor: anytype, clock: anytype, allocator: std.mem.Allocator, expected: context_mod.Context, executable: [:0]const u8, token: []const u8, response: []u8, budget_ns: i128, result: *CurrentGitHubAuthority) !void {
    if (result.owner != null) return error.InvalidOwner;
    if (budget_ns <= 0) return error.TimedOut;
    const started = try clock.now();
    if (started < 0) return error.ClockFailed;
    const expires = std.math.add(i128, started, budget_ns) catch return error.TimedOut;
    if (expires <= started) return error.TimedOut;
    var deadline = BudgetDeadline(@TypeOf(clock)){ .clock = clock, .started = started, .expires = expires };
    return authenticateUntilWith(authority, executor, &deadline, allocator, expected, executable, token, response, result);
}

pub fn authenticateUntilWith(authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, expected: context_mod.Context, executable: [:0]const u8, token: []const u8, response: []u8, result: *CurrentGitHubAuthority) !void {
    if (result.owner != null) return error.InvalidOwner;

    const repository_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .repository, response);
    var parsed_repository = try repository.parseAndBind(allocator, repository_bytes, expected.repository);
    defer parsed_repository.deinit();
    const repository_id = parsed_repository.repository().id;

    const run_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .workflow_run = expected.build.run_id }, response);
    var parsed_run = try run.parseAndBind(allocator, run_bytes, expected);
    defer parsed_run.deinit();
    const run_observation = parsed_run.observation().*;
    var source_commit: [40]u8 = undefined;
    if (run_observation.source_commit.len != source_commit.len) return error.RunMismatch;
    @memcpy(&source_commit, run_observation.source_commit);

    const environment_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .environment, response);
    var parsed_environment = try environment.parseAndBind(allocator, environment_bytes);
    defer parsed_environment.deinit();

    var prepared: deployment.Prepared = .{};
    const jobs_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .attempt_jobs = .{ .run_id = expected.build.run_id, .attempt = expected.build.run_attempt } }, response);
    try prepared.prepareJobs(allocator, jobs_bytes, expected);
    defer prepared.deinit() catch {};
    const deployments_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .deployments = .{ .source_sha = expected.source_commit } }, response);
    try prepared.prepareDeployments(allocator, deployments_bytes, expected);
    for (try prepared.candidateIds()) |deployment_id| {
        const status_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .deployment_statuses = deployment_id }, response);
        try prepared.acceptStatuses(allocator, deployment_id, status_bytes);
    }
    const deployment_observation = try prepared.finish(parsed_environment.observation().*);

    result.repository_id = repository_id;
    result.run_id = run_observation.run_id;
    result.run_attempt = run_observation.run_attempt;
    result.source_commit = source_commit;
    result.job_id = deployment_observation.job_id;
    result.deployment_id = deployment_observation.deployment_id;
    result.environment_id = deployment_observation.environment_id;
    result.protected_environment = true;
    result.owner = result;
}

fn fetchUntil(authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, executable: [:0]const u8, token: []const u8, request: transport_macos.Request, response: []u8) ![]const u8 {
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);
    const budget_ns = try deadline.remaining();
    return transport_macos.fetchWith(executor, allocator, executable, token, request, response, budget_ns);
}

fn BudgetDeadline(comptime Clock: type) type {
    return struct {
        clock: Clock,
        started: i128,
        expires: i128,
        pub fn remaining(self: *@This()) !i128 {
            const now = try self.clock.now();
            if (now < self.started) return error.ClockFailed;
            if (now >= self.expires) return error.TimedOut;
            return self.expires - now;
        }
    };
}
