//! Binds a current release job to the one GitHub Actions deployment that actually waited on the
//! protected `release` environment. These fixtures cover component semantics only; transport,
//! pagination, workflow wiring, and repository-side policy remain separate gates.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const github_deployment = @import("release_adapter_github_deployment");
const github_environment = @import("release_adapter_github_environment");

const source_sha = "0123456789abcdef0123456789abcdef01234567";
const expected: context_mod.Context = .{
    .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = source_sha,
    .build = .{
        .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
        .run_id = 33_335_653_781,
        .run_attempt = 2,
    },
    .protected_tag = true,
};

const environment: github_environment.Observation = .{
    .id = 161_088_068,
    .name = "release",
    .can_admins_bypass = false,
    .required_reviewer_count = 1,
    .prevent_self_review = true,
    .wait_timer_minutes = 0,
    .branch_policy_rule = false,
    .protected_branches = false,
    .custom_branch_policies = false,
    .unknown_rule_count = 0,
};

const jobs =
    \\{"total_count":2,"jobs":[
    \\ {"id":90618357139,"run_id":33335653781,"run_attempt":2,"head_sha":"0123456789abcdef0123456789abcdef01234567","status":"completed","conclusion":"success","name":"setup","workflow_name":"Release","html_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357139"},
    \\ {"id":90618357140,"run_id":33335653781,"run_attempt":2,"head_sha":"0123456789abcdef0123456789abcdef01234567","status":"in_progress","conclusion":null,"name":"universal dmg (signed + notarized)","workflow_name":"Release","html_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","additive":true}]}
;

const deployments =
    \\[{"id":5659920836,"sha":"1123456789abcdef0123456789abcdef01234567","ref":"v1.2.3","task":"deploy","environment":"release","original_environment":"release","statuses_url":"https://api.github.com/repos/ohah/maru/deployments/5659920836/statuses","repository_url":"https://api.github.com/repos/ohah/maru","performed_via_github_app":{"id":15368,"slug":"github-actions","owner":{"login":"github"}}},
    \\ {"id":5659920837,"sha":"0123456789abcdef0123456789abcdef01234567","ref":"v1.2.3","task":"deploy","environment":"release","original_environment":"release","statuses_url":"https://api.github.com/repos/ohah/maru/deployments/5659920837/statuses","repository_url":"https://api.github.com/repos/ohah/maru","performed_via_github_app":{"id":15368,"slug":"github-actions","owner":{"login":"github"}},"creator":{"login":"ohah"}}]
;

const statuses =
    \\[{"id":9004,"state":"queued","environment":"release","log_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","target_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","url":"https://api.github.com/repos/ohah/maru/deployments/5659920837/statuses/9004","deployment_url":"https://api.github.com/repos/ohah/maru/deployments/5659920837","repository_url":"https://api.github.com/repos/ohah/maru"},
    \\ {"id":9003,"state":"pending","environment":"release","log_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","target_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","url":"https://api.github.com/repos/ohah/maru/deployments/5659920837/statuses/9003","deployment_url":"https://api.github.com/repos/ohah/maru/deployments/5659920837","repository_url":"https://api.github.com/repos/ohah/maru"},
    \\ {"id":9005,"state":"in_progress","environment":"release","log_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","target_url":"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140","url":"https://api.github.com/repos/ohah/maru/deployments/5659920837/statuses/9005","deployment_url":"https://api.github.com/repos/ohah/maru/deployments/5659920837","repository_url":"https://api.github.com/repos/ohah/maru"}]
;

test "current attempt job binds exactly one protected release deployment" {
    const backing = [_]github_deployment.StatusBacking{.{
        .deployment_id = 5_659_920_837,
        .bytes = statuses,
    }};
    const observation = try github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &backing,
        expected,
        environment,
    );
    try std.testing.expectEqual(@as(u64, 90_618_357_140), observation.job_id);
    try std.testing.expectEqual(@as(u64, 5_659_920_837), observation.deployment_id);
    try std.testing.expectEqual(environment.id, observation.environment_id);
}

test "non-bypass environment protection and official pending history are both mandatory" {
    const backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = statuses }};
    var unprotected = environment;
    unprotected.required_reviewer_count = 0;
    unprotected.prevent_self_review = false;
    try std.testing.expectError(error.UnprotectedEnvironment, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &backing,
        expected,
        unprotected,
    ));
    var forged = environment;
    forged.required_reviewer_count = 7;
    try std.testing.expectError(error.UnprotectedEnvironment, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &backing,
        expected,
        forged,
    ));

    var bypassable = environment;
    bypassable.can_admins_bypass = true;
    try std.testing.expectError(error.UnprotectedEnvironment, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &backing,
        expected,
        bypassable,
    ));

    const no_pending = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        statuses,
        "\"state\":\"pending\"",
        "\"state\":\"queued\"",
    ) catch unreachable;
    defer std.testing.allocator.free(no_pending);
    const no_pending_backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = no_pending }};
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &no_pending_backing,
        expected,
        environment,
    ));
}

test "foreign replayed and ambiguous job or deployment identity fails closed" {
    const replacements = [_]struct { source: []const u8, from: []const u8, to: []const u8 }{
        .{ .source = jobs, .from = "\"run_attempt\":2", .to = "\"run_attempt\":3" },
        .{ .source = jobs, .from = source_sha, .to = "1123456789abcdef0123456789abcdef01234567" },
        .{ .source = jobs, .from = "\"status\":\"in_progress\"", .to = "\"status\":\"completed\"" },
        .{ .source = jobs, .from = "\"conclusion\":null", .to = "\"conclusion\":\"success\"" },
        .{ .source = deployments, .from = "\"ref\":\"v1.2.3\"", .to = "\"ref\":\"v1.2.4\"" },
        .{ .source = deployments, .from = "\"slug\":\"github-actions\"", .to = "\"slug\":\"foreign\"" },
        .{ .source = statuses, .from = "/job/90618357140", .to = "/job/90618357141" },
        .{ .source = statuses, .from = "/deployments/5659920837/statuses/9005", .to = "/deployments/5659920838/statuses/9005" },
        .{ .source = statuses, .from = "/deployments/5659920837\"", .to = "/deployments/5659920838\"" },
        .{ .source = statuses, .from = "/repos/ohah/maru\"", .to = "/repos/foreign/maru\"" },
    };
    for (replacements) |replacement| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, replacement.source, replacement.from, replacement.to);
        defer std.testing.allocator.free(changed);
        const actual_jobs = if (replacement.source.ptr == jobs.ptr) changed else jobs;
        const actual_deployments = if (replacement.source.ptr == deployments.ptr) changed else deployments;
        const changed_backing = [_]github_deployment.StatusBacking{.{
            .deployment_id = 5_659_920_837,
            .bytes = if (replacement.source.ptr == statuses.ptr) changed else statuses,
        }};
        try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
            std.testing.allocator,
            actual_jobs,
            actual_deployments,
            &changed_backing,
            expected,
            environment,
        ));
    }

    const ambiguous_deployments = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        deployments,
        "1123456789abcdef0123456789abcdef01234567",
        source_sha,
    );
    defer std.testing.allocator.free(ambiguous_deployments);
    const ambiguous_backing = [_]github_deployment.StatusBacking{
        .{ .deployment_id = 5_659_920_836, .bytes = statuses },
        .{ .deployment_id = 5_659_920_837, .bytes = statuses },
    };
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        ambiguous_deployments,
        &ambiguous_backing,
        expected,
        environment,
    ));
}

test "status backing identity coverage and order-independent exact current lifecycle fail closed" {
    const missing = [_]github_deployment.StatusBacking{};
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &missing,
        expected,
        environment,
    ));
    const duplicate = [_]github_deployment.StatusBacking{
        .{ .deployment_id = 5_659_920_837, .bytes = statuses },
        .{ .deployment_id = 5_659_920_837, .bytes = statuses },
    };
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &duplicate,
        expected,
        environment,
    ));
    const completed = try std.mem.replaceOwned(u8, std.testing.allocator, statuses, "\"state\":\"in_progress\"", "\"state\":\"success\"");
    defer std.testing.allocator.free(completed);
    const completed_backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = completed }};
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &completed_backing,
        expected,
        environment,
    ));

    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, statuses, "\"state\":\"queued\"", "\"state\":\"future\"");
    defer std.testing.allocator.free(unknown);
    const unknown_backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = unknown }};
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &unknown_backing,
        expected,
        environment,
    ));

    const duplicate_current = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        statuses,
        "\"state\":\"queued\"",
        "\"state\":\"in_progress\"",
    );
    defer std.testing.allocator.free(duplicate_current);
    const duplicate_current_backing = [_]github_deployment.StatusBacking{.{
        .deployment_id = 5_659_920_837,
        .bytes = duplicate_current,
    }};
    try std.testing.expectError(error.DeploymentMismatch, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &duplicate_current_backing,
        expected,
        environment,
    ));
}

test "malformed duplicate wrong type trailing and response caps fail closed" {
    const backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = statuses }};
    const malformed = [_][]const u8{ "{", jobs ++ "null", "{\"total_count\":2,\"total_count\":2,\"jobs\":[]}" };
    for (malformed) |bytes| try std.testing.expectError(error.InvalidJson, github_deployment.parseAndBind(
        std.testing.allocator,
        bytes,
        deployments,
        &backing,
        expected,
        environment,
    ));
    const oversized = " " ** (github_deployment.max_response_bytes + 1);
    try std.testing.expectError(error.ResponseTooLarge, github_deployment.parseAndBind(
        std.testing.allocator,
        oversized,
        deployments,
        &backing,
        expected,
        environment,
    ));

    const malformed_deployments = [_][]const u8{
        "{",
        deployments ++ "null",
        "[{\"id\":1,\"id\":1,\"sha\":\"" ++ source_sha ++ "\",\"ref\":\"v1.2.3\",\"task\":\"deploy\",\"environment\":\"release\",\"original_environment\":\"release\",\"statuses_url\":\"x\",\"repository_url\":\"x\",\"performed_via_github_app\":{\"id\":1,\"slug\":\"github-actions\",\"owner\":{\"login\":\"github\"}}}]",
    };
    for (malformed_deployments) |bytes| try std.testing.expectError(error.InvalidJson, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        bytes,
        &backing,
        expected,
        environment,
    ));
    const malformed_status_backing = [_]github_deployment.StatusBacking{.{
        .deployment_id = 5_659_920_837,
        .bytes = statuses ++ "null",
    }};
    try std.testing.expectError(error.InvalidJson, github_deployment.parseAndBind(
        std.testing.allocator,
        jobs,
        deployments,
        &malformed_status_backing,
        expected,
        environment,
    ));
}

test "successful allocations are covered by fail-index testing" {
    const backing = [_]github_deployment.StatusBacking{.{ .deployment_id = 5_659_920_837, .bytes = statuses }};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_deployment.parseAndBindForTest,
        .{ jobs, deployments, &backing, expected, environment },
    );
}
