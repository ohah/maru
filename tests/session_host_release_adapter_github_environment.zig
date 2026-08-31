//! Proves strict semantic parsing of the GitHub `release` environment response. These fixtures
//! expose configured policy facts only; they do not prove that the current workflow job passed
//! those rules or authenticate the transport that captured the response.

const std = @import("std");
const github_environment = @import("release_adapter_github_environment");

const protected_valid =
    \\{"id":161088068,"name":"release","can_admins_bypass":false,"url":"https://api.github.test/environments/release",
    \\ "protection_rules":[
    \\   {"id":3736,"type":"wait_timer","wait_timer":30},
    \\   {"id":3755,"type":"required_reviewers","prevent_self_review":true,
    \\    "reviewers":[{"type":"User","reviewer":{"id":42,"login":"ohah"}}]},
    \\   {"id":3756,"type":"branch_policy"},
    \\   {"id":4000,"type":"future_policy","future":true}],
    \\ "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
;

test "release environment preserves recognized protection and branch policy facts" {
    var parsed = try github_environment.parseAndBind(std.testing.allocator, protected_valid);
    defer parsed.deinit();
    const observation = parsed.observation();
    try std.testing.expectEqual(@as(u64, 161088068), observation.id);
    try std.testing.expectEqualStrings("release", observation.name);
    try std.testing.expect(!observation.can_admins_bypass);
    try std.testing.expectEqual(@as(u8, 1), observation.required_reviewer_count);
    try std.testing.expect(observation.prevent_self_review);
    try std.testing.expectEqual(@as(u32, 30), observation.wait_timer_minutes);
    try std.testing.expect(observation.branch_policy_rule);
    try std.testing.expect(!observation.protected_branches);
    try std.testing.expect(observation.custom_branch_policies);
    try std.testing.expectEqual(@as(u64, 1), observation.unknown_rule_count);
}

test "an exact environment without configured protection remains an unprotected fact" {
    const bytes =
        \\{"id":8,"name":"release","can_admins_bypass":false,"protection_rules":[],"deployment_branch_policy":null,
        \\ "created_at":"2026-08-27T00:00:00Z"}
    ;
    var parsed = try github_environment.parseAndBind(std.testing.allocator, bytes);
    defer parsed.deinit();
    const observation = parsed.observation();
    try std.testing.expectEqual(@as(u8, 0), observation.required_reviewer_count);
    try std.testing.expect(!observation.prevent_self_review);
    try std.testing.expectEqual(@as(u32, 0), observation.wait_timer_minutes);
    try std.testing.expect(!observation.branch_policy_rule);
    try std.testing.expect(!observation.protected_branches);
    try std.testing.expect(!observation.custom_branch_policies);
}

test "response cap is enforced before parsing" {
    const oversized = " " ** (github_environment.max_response_bytes + 1);
    try std.testing.expectError(
        error.ResponseTooLarge,
        github_environment.parseAndBind(std.testing.allocator, oversized),
    );
}

test "malformed missing wrong-type duplicate and trailing JSON fail closed" {
    const cases = [_][]const u8{
        "{",
        "{\"id\":1,\"name\":\"release\",\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"can_admins_bypass\":\"false\",\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":\"1\",\"name\":\"release\",\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":{},\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[],\"deployment_branch_policy\":false}",
        "{\"id\":1,\"id\":1,\"name\":\"release\",\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"name\":\"release\",\"protection_rules\":[],\"deployment_branch_policy\":null}",
        protected_valid ++ "null",
    };
    for (cases) |bytes| {
        if (github_environment.parseAndBind(std.testing.allocator, bytes)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.InvalidJson, err);
    }
}

test "foreign identity duplicate rules and incoherent branch policy fail closed" {
    const cases = [_][]const u8{
        "{\"id\":0,\"name\":\"release\",\"can_admins_bypass\":false,\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"staging\",\"can_admins_bypass\":false,\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"can_admins_bypass\":true,\"protection_rules\":[],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"wait_timer\"},{\"id\":2,\"type\":\"future\"}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"wait_timer\"},{\"id\":3,\"type\":\"wait_timer\"}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"branch_policy\"}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[],\"deployment_branch_policy\":{\"protected_branches\":true,\"custom_branch_policies\":false}}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"branch_policy\"}],\"deployment_branch_policy\":{\"protected_branches\":true,\"custom_branch_policies\":true}}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":0,\"type\":\"wait_timer\"}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"wait_timer\",\"wait_timer\":0}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"wait_timer\",\"wait_timer\":43201}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"required_reviewers\",\"prevent_self_review\":false,\"reviewers\":[]}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"required_reviewers\",\"prevent_self_review\":false,\"reviewers\":[{\"type\":\"Bot\",\"reviewer\":{\"id\":3}}]}],\"deployment_branch_policy\":null}",
        "{\"id\":1,\"name\":\"release\",\"protection_rules\":[{\"id\":2,\"type\":\"branch_policy\",\"wait_timer\":30}],\"deployment_branch_policy\":{\"protected_branches\":true,\"custom_branch_policies\":false}}",
    };
    for (cases) |bytes| {
        try std.testing.expectError(
            error.EnvironmentMismatch,
            github_environment.parseAndBind(std.testing.allocator, bytes),
        );
    }
}

test "every successful allocation is covered by fail-index testing" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_environment.parseAndBindForTest,
        .{protected_valid},
    );
}
