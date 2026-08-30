//! Strict component binding for a GitHub release job and its protected-environment deployment.
//!
//! The caller supplies bounded, complete REST response bytes for one run attempt, the matching
//! deployment query, and every source/tag/environment candidate's status history. This module
//! proves their semantic join. It does not authenticate transport, endpoints, or pagination.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const contract = @import("release_adapter_contract");
const github_json = @import("release_adapter_github_json");
const github_environment = @import("release_adapter_github_environment");

pub const max_response_bytes = github_json.max_response_bytes;
pub const max_collection_entries: usize = 100;

const StrictU64 = struct {
    value: u64,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StrictU64 {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};

const ApiJobs = struct {
    total_count: StrictU64,
    jobs: []const ApiJob,
};

const ApiJob = struct {
    id: StrictU64,
    run_id: StrictU64,
    run_attempt: StrictU64,
    head_sha: []const u8,
    status: []const u8,
    conclusion: ?[]const u8,
    name: []const u8,
    workflow_name: []const u8,
    html_url: []const u8,
};

const ApiDeployment = struct {
    id: StrictU64,
    sha: []const u8,
    ref: []const u8,
    task: []const u8,
    environment: []const u8,
    original_environment: []const u8,
    statuses_url: []const u8,
    repository_url: []const u8,
    performed_via_github_app: ApiApp,
};

const ApiApp = struct {
    id: StrictU64,
    slug: []const u8,
    owner: ApiOwner,
};

const ApiOwner = struct {
    login: []const u8,
};

const ApiStatus = struct {
    id: StrictU64,
    state: []const u8,
    environment: []const u8,
    log_url: ?[]const u8,
    target_url: ?[]const u8,
    url: []const u8,
    deployment_url: []const u8,
    repository_url: []const u8,
};

pub const StatusBacking = struct {
    deployment_id: u64,
    bytes: []const u8,
};

pub const Observation = struct {
    job_id: u64,
    deployment_id: u64,
    environment_id: u64,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    UnprotectedEnvironment,
    DeploymentMismatch,
} || std.mem.Allocator.Error;

const Job = struct {
    id: u64,
    url: []const u8,
};

/// Binds exact component observations. Input slices need only remain valid for this call.
pub fn parseAndBind(
    allocator: std.mem.Allocator,
    jobs_bytes: []const u8,
    deployments_bytes: []const u8,
    status_backings: []const StatusBacking,
    expected: context_mod.Context,
    environment: github_environment.Observation,
) Error!Observation {
    if (!recognizedProtection(environment)) return error.UnprotectedEnvironment;

    var jobs = try parse(ApiJobs, allocator, jobs_bytes);
    defer jobs.deinit();
    if (jobs.value.jobs.len > max_collection_entries) return error.DeploymentMismatch;
    const job = try bindJob(jobs.value, expected);

    var deployments = try parse([]const ApiDeployment, allocator, deployments_bytes);
    defer deployments.deinit();
    if (deployments.value.len > max_collection_entries or
        status_backings.len > max_collection_entries) return error.DeploymentMismatch;
    try validateBackingIdentity(status_backings);

    var bound_count: u8 = 0;
    var bound_deployment_id: u64 = 0;
    for (deployments.value) |deployment| {
        if (!baseDeploymentMatches(deployment, expected)) continue;
        if (!deploymentAuthorityMatches(deployment)) return error.DeploymentMismatch;
        const backing = backingFor(status_backings, deployment.id.value) orelse
            return error.DeploymentMismatch;
        if (try statusesBind(allocator, backing.bytes, deployment, job.url)) {
            bound_count = std.math.add(u8, bound_count, 1) catch
                return error.DeploymentMismatch;
            bound_deployment_id = deployment.id.value;
        }
    }
    if (bound_count != 1) return error.DeploymentMismatch;

    // A backing for a foreign or filtered-out deployment is ambiguous caller input. The transport
    // layer must give this resolver exactly the status histories it requested for base candidates.
    for (status_backings) |backing| {
        var found = false;
        for (deployments.value) |deployment| {
            if (deployment.id.value == backing.deployment_id and
                baseDeploymentMatches(deployment, expected))
            {
                found = true;
                break;
            }
        }
        if (!found) return error.DeploymentMismatch;
    }

    return .{
        .job_id = job.id,
        .deployment_id = bound_deployment_id,
        .environment_id = environment.id,
    };
}

fn parse(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(T) {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

fn bindJob(response: ApiJobs, expected: context_mod.Context) Error!Job {
    if (response.total_count.value != response.jobs.len) return error.DeploymentMismatch;
    var matched: ?Job = null;
    for (response.jobs) |job| {
        if (!std.mem.eql(u8, job.name, contract.release_signing_job_name)) continue;
        if (matched != null or job.id.value == 0 or
            job.run_id.value != expected.build.run_id or
            job.run_attempt.value != expected.build.run_attempt or
            !std.mem.eql(u8, job.head_sha, expected.source_commit) or
            !std.mem.eql(u8, job.status, "in_progress") or job.conclusion != null or
            !std.mem.eql(u8, job.workflow_name, contract.release_workflow_name) or
            !canonicalJobUrl(job.html_url, expected.build.run_id, job.id.value))
            return error.DeploymentMismatch;
        matched = .{ .id = job.id.value, .url = job.html_url };
    }
    return matched orelse error.DeploymentMismatch;
}

fn canonicalJobUrl(url: []const u8, run_id: u64, job_id: u64) bool {
    var buffer: [context_mod.max_value_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &buffer,
        "https://github.com/ohah/maru/actions/runs/{d}/job/{d}",
        .{ run_id, job_id },
    ) catch return false;
    return std.mem.eql(u8, url, expected);
}

fn baseDeploymentMatches(deployment: ApiDeployment, expected: context_mod.Context) bool {
    return deployment.id.value != 0 and
        std.mem.eql(u8, deployment.sha, expected.source_commit) and
        std.mem.eql(u8, deployment.ref, expected.tag) and
        std.mem.eql(u8, deployment.task, "deploy") and
        std.mem.eql(u8, deployment.environment, contract.protected_environment_name) and
        std.mem.eql(u8, deployment.original_environment, contract.protected_environment_name);
}

fn deploymentAuthorityMatches(deployment: ApiDeployment) bool {
    if (deployment.performed_via_github_app.id.value == 0 or
        !std.mem.eql(u8, deployment.performed_via_github_app.slug, "github-actions") or
        !std.mem.eql(u8, deployment.performed_via_github_app.owner.login, "github")) return false;
    var repository_url: [context_mod.max_value_bytes]u8 = undefined;
    const expected_repository = std.fmt.bufPrint(
        &repository_url,
        "https://api.github.com/repos/{s}",
        .{contract.repository_name},
    ) catch return false;
    if (!std.mem.eql(u8, deployment.repository_url, expected_repository)) return false;
    var statuses_url: [context_mod.max_value_bytes]u8 = undefined;
    const expected_statuses = std.fmt.bufPrint(
        &statuses_url,
        "{s}/deployments/{d}/statuses",
        .{ expected_repository, deployment.id.value },
    ) catch return false;
    return std.mem.eql(u8, deployment.statuses_url, expected_statuses);
}

fn validateBackingIdentity(backings: []const StatusBacking) Error!void {
    for (backings, 0..) |backing, index| {
        if (backing.deployment_id == 0) return error.DeploymentMismatch;
        for (backings[0..index]) |earlier| {
            if (earlier.deployment_id == backing.deployment_id) return error.DeploymentMismatch;
        }
    }
}

fn backingFor(backings: []const StatusBacking, deployment_id: u64) ?StatusBacking {
    for (backings) |backing| if (backing.deployment_id == deployment_id) return backing;
    return null;
}

fn statusesBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    deployment: ApiDeployment,
    job_url: []const u8,
) Error!bool {
    var statuses = try parse([]const ApiStatus, allocator, bytes);
    defer statuses.deinit();
    if (statuses.value.len == 0 or statuses.value.len > max_collection_entries) return false;
    for (statuses.value, 0..) |status, index| {
        if (status.id.value == 0 or status.state.len == 0 or
            !statusAuthorityMatches(status, deployment)) return error.DeploymentMismatch;
        for (statuses.value[0..index]) |earlier| {
            if (earlier.id.value == status.id.value) return error.DeploymentMismatch;
        }
    }

    const newest = statuses.value[0];
    if (!statusForJob(newest, "in_progress", job_url)) return false;
    var saw_waiting = false;
    for (statuses.value[1..]) |status| {
        if (statusForJob(status, "waiting", job_url)) saw_waiting = true;
    }
    return saw_waiting;
}

fn statusAuthorityMatches(status: ApiStatus, deployment: ApiDeployment) bool {
    if (!std.mem.eql(u8, status.repository_url, deployment.repository_url)) return false;
    var deployment_url: [context_mod.max_value_bytes]u8 = undefined;
    const expected_deployment = std.fmt.bufPrint(
        &deployment_url,
        "{s}/deployments/{d}",
        .{ deployment.repository_url, deployment.id.value },
    ) catch return false;
    if (!std.mem.eql(u8, status.deployment_url, expected_deployment)) return false;
    var status_url: [context_mod.max_value_bytes]u8 = undefined;
    const expected_status = std.fmt.bufPrint(
        &status_url,
        "{s}/statuses/{d}",
        .{ expected_deployment, status.id.value },
    ) catch return false;
    return std.mem.eql(u8, status.url, expected_status);
}

fn statusForJob(status: ApiStatus, state: []const u8, job_url: []const u8) bool {
    return std.mem.eql(u8, status.state, state) and
        std.mem.eql(u8, status.environment, contract.protected_environment_name) and
        status.log_url != null and std.mem.eql(u8, status.log_url.?, job_url) and
        status.target_url != null and std.mem.eql(u8, status.target_url.?, job_url);
}

fn recognizedProtection(environment: github_environment.Observation) bool {
    if (environment.id == 0 or
        !std.mem.eql(u8, environment.name, contract.protected_environment_name)) return false;
    if (environment.required_reviewer_count > 6 or
        (environment.required_reviewer_count == 0 and environment.prevent_self_review) or
        environment.wait_timer_minutes > 43_200 or
        (environment.branch_policy_rule !=
            (environment.protected_branches != environment.custom_branch_policies))) return false;
    return environment.required_reviewer_count > 0 or
        environment.wait_timer_minutes > 0 or
        (environment.branch_policy_rule and
            (environment.protected_branches != environment.custom_branch_policies));
}

/// Public only so std's allocation-failure harness can cover the complete successful path.
pub fn parseAndBindForTest(
    allocator: std.mem.Allocator,
    jobs_bytes: []const u8,
    deployments_bytes: []const u8,
    status_backings: []const StatusBacking,
    expected: context_mod.Context,
    environment: github_environment.Observation,
) !void {
    _ = try parseAndBind(
        allocator,
        jobs_bytes,
        deployments_bytes,
        status_backings,
        expected,
        environment,
    );
}
