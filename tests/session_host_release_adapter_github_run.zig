//! Binds one bounded GitHub workflow-run REST response to the already validated Actions context.
//! Transport authority and protected-environment deployment evidence remain separate seams.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const github_run = @import("release_adapter_github_run");

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

const valid =
    \\{"id":33335653781,"run_attempt":2,"event":"push",
    \\ "head_sha":"0123456789abcdef0123456789abcdef01234567",
    \\ "path":".github/workflows/release.yml",
    \\ "status":"in_progress","conclusion":null,"pull_requests":[],
    \\ "repository":{"id":1257870483,"name":"maru","full_name":"ohah/maru","owner":{"login":"ohah"}},
    \\ "head_repository":{"id":1257870483,"name":"maru","full_name":"ohah/maru","owner":{"login":"ohah"}},
    \\ "display_title":"additive"}
;

test "workflow run response binds current push run source workflow and same repository head" {
    var parsed = try github_run.parseAndBind(std.testing.allocator, valid, expected);
    defer parsed.deinit();
    const observation = parsed.observation();
    try std.testing.expectEqual(expected.build.run_id, observation.run_id);
    try std.testing.expectEqual(expected.build.run_attempt, observation.run_attempt);
    try std.testing.expectEqualStrings(expected.source_commit, observation.source_commit);
    try std.testing.expectEqualStrings(
        ".github/workflows/release.yml",
        observation.workflow_path,
    );
}

test "workflow run response cap is enforced before parsing" {
    const oversized = " " ** (github_run.max_response_bytes + 1);
    try std.testing.expectError(
        error.ResponseTooLarge,
        github_run.parseAndBind(std.testing.allocator, oversized, expected),
    );
}

test "workflow run malformed missing wrong-type duplicate and trailing JSON fail closed" {
    const cases = [_][]const u8{
        "{",
        "{\"id\":33335653781}",
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"id\":33335653781", "\"id\":\"33335653781\"") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"event\":\"push\"", "\"event\":\"push\",\"event\":\"push\"") catch unreachable,
        valid ++ "null",
    };
    defer std.testing.allocator.free(cases[2]);
    defer std.testing.allocator.free(cases[3]);
    for (cases, 0..) |bytes, index| {
        if (github_run.parseAndBind(std.testing.allocator, bytes, expected)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted malformed run case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.InvalidJson, err);
    }

    const wrong_types = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "\"run_attempt\":2", .to = "\"run_attempt\":\"2\"" },
        .{ .from = "\"event\":\"push\"", .to = "\"event\":true" },
        .{ .from = "\"head_sha\":\"" ++ source_sha ++ "\"", .to = "\"head_sha\":null" },
        .{ .from = "\"path\":\".github/workflows/release.yml\"", .to = "\"path\":[]" },
        .{ .from = "\"status\":\"in_progress\"", .to = "\"status\":null" },
        .{ .from = "\"conclusion\":null", .to = "\"conclusion\":1" },
        .{ .from = "\"pull_requests\":[]", .to = "\"pull_requests\":{}" },
        .{ .from = "\"repository\":{", .to = "\"repository\":false,\"ignored_repository\":" ++ "{" },
        .{ .from = "\"head_repository\":{", .to = "\"head_repository\":[],\"ignored_head_repository\":" ++ "{" },
    };
    for (wrong_types, 0..) |replacement, index| {
        const bytes = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            valid,
            replacement.from,
            replacement.to,
        );
        defer std.testing.allocator.free(bytes);
        if (github_run.parseAndBind(std.testing.allocator, bytes, expected)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted wrong-type run case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| try std.testing.expect(
            err == error.InvalidJson or err == error.RunMismatch,
        );
    }
}

test "workflow run foreign identity lifecycle workflow and pull request fail closed" {
    const replacements = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "33335653781", .to = "33335653782" },
        .{ .from = "\"run_attempt\":2", .to = "\"run_attempt\":3" },
        .{ .from = "\"event\":\"push\"", .to = "\"event\":\"pull_request\"" },
        .{ .from = source_sha, .to = "1123456789abcdef0123456789abcdef01234567" },
        .{ .from = "release.yml\"", .to = "other.yml\"" },
        .{ .from = "\"status\":\"in_progress\"", .to = "\"status\":\"completed\"" },
        .{ .from = "\"conclusion\":null", .to = "\"conclusion\":\"success\"" },
        .{ .from = "\"pull_requests\":[]", .to = "\"pull_requests\":[{}]" },
        .{ .from = "\"repository\":{\"id\":1257870483", .to = "\"repository\":{\"id\":1257870484" },
        .{ .from = "\"head_repository\":{\"id\":1257870483", .to = "\"head_repository\":null,\"ignored\":{\"id\":1257870483" },
        .{ .from = "\"head_repository\":{\"id\":1257870483", .to = "\"head_repository\":{\"id\":1257870484" },
    };
    for (replacements) |replacement| {
        const bytes = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            valid,
            replacement.from,
            replacement.to,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(
            error.RunMismatch,
            github_run.parseAndBind(std.testing.allocator, bytes, expected),
        );
    }

    var forged = expected;
    forged.build.workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.4";
    try std.testing.expectError(
        error.RunMismatch,
        github_run.parseAndBind(std.testing.allocator, valid, forged),
    );
}

test "workflow run successful allocations are covered by fail-index testing" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_run.parseAndBindForTest,
        .{ valid, expected },
    );
}
