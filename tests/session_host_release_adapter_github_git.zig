//! Proves strict semantic parsing of GitHub Git ref/tag REST responses without claiming that the
//! bytes came from GitHub or choosing a maximum annotated-tag traversal depth.

const std = @import("std");
const github_git = @import("release_adapter_github_git");

const tag = "v1.2.3";
const commit_sha = "0123456789abcdef0123456789abcdef01234567";
const tag_sha = "89abcdef0123456789abcdef0123456789abcdef";

const direct_ref =
    \\{"ref":"refs/tags/v1.2.3","node_id":"x","object":{
    \\ "type":"commit","sha":"0123456789abcdef0123456789abcdef01234567","url":"https://api.github.test/commit"}}
;

const annotated_ref =
    \\{"ref":"refs/tags/v1.2.3","object":{
    \\ "type":"tag","sha":"89abcdef0123456789abcdef0123456789abcdef","url":"https://api.github.test/tag"}}
;

const annotated_tag =
    \\{"tag":"v1.2.3","sha":"89abcdef0123456789abcdef0123456789abcdef",
    \\ "message":"release","object":{"type":"commit",
    \\ "sha":"0123456789abcdef0123456789abcdef01234567","url":"https://api.github.test/commit"}}
;

test "tag ref binds exact name and returns a commit or annotated tag target" {
    var direct = try github_git.parseRef(std.testing.allocator, direct_ref, tag);
    defer direct.deinit();
    try std.testing.expectEqual(github_git.ObjectKind.commit, direct.observation().target.kind);
    try std.testing.expectEqualStrings(commit_sha, direct.observation().target.sha);

    var annotated = try github_git.parseRef(std.testing.allocator, annotated_ref, tag);
    defer annotated.deinit();
    try std.testing.expectEqual(github_git.ObjectKind.tag, annotated.observation().target.kind);
    try std.testing.expectEqualStrings(tag_sha, annotated.observation().target.sha);
}

test "annotated tag binds its own object identity and returns the next typed target" {
    var parsed = try github_git.parseTag(std.testing.allocator, annotated_tag, .{
        .tag = tag,
        .object_sha = tag_sha,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(tag, parsed.observation().tag);
    try std.testing.expectEqualStrings(tag_sha, parsed.observation().object_sha);
    try std.testing.expectEqual(github_git.ObjectKind.commit, parsed.observation().target.kind);
    try std.testing.expectEqualStrings(commit_sha, parsed.observation().target.sha);

    const nested =
        \\{"tag":"v1.2.3","sha":"89abcdef0123456789abcdef0123456789abcdef",
        \\ "object":{"type":"tag","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
    ;
    var nested_parsed = try github_git.parseTag(std.testing.allocator, nested, .{
        .tag = tag,
        .object_sha = tag_sha,
    });
    defer nested_parsed.deinit();
    try std.testing.expectEqual(github_git.ObjectKind.tag, nested_parsed.observation().target.kind);

    const nested_object =
        \\{"tag":"intermediate-release","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\ "object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    var nested_object_parsed = try github_git.parseTag(std.testing.allocator, nested_object, .{
        .tag = null,
        .object_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });
    defer nested_object_parsed.deinit();
    try std.testing.expectEqualStrings("intermediate-release", nested_object_parsed.observation().tag);
    try std.testing.expectEqual(github_git.ObjectKind.commit, nested_object_parsed.observation().target.kind);
}

test "shared response cap is enforced before endpoint parsing" {
    const oversized = " " ** (github_git.max_response_bytes + 1);
    try std.testing.expectError(error.ResponseTooLarge, github_git.parseRef(std.testing.allocator, oversized, tag));
    try std.testing.expectError(error.ResponseTooLarge, github_git.parseTag(std.testing.allocator, oversized, .{
        .tag = tag,
        .object_sha = tag_sha,
    }));
}

test "malformed missing wrong-type duplicate and trailing responses fail closed" {
    const cases = [_][]const u8{
        "{",
        "{\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"commit\"}}",
        "{\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"commit\",\"sha\":1}}",
        "{\"ref\":\"refs/tags/v1.2.3\",\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"commit\",\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        direct_ref ++ "null",
    };
    for (cases, 0..) |bytes, index| {
        if (github_git.parseRef(std.testing.allocator, bytes, tag)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted invalid ref case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.InvalidJson, err);
        }
    }

    const tag_cases = [_][]const u8{
        "{\"tag\":\"v1.2.3\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"tag\":\"v1.2.3\",\"sha\":1,\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"tag\":\"v1.2.3\",\"tag\":\"v1.2.3\",\"sha\":\"89abcdef0123456789abcdef0123456789abcdef\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"tag\":\"v1.2.3\",\"sha\":\"89abcdef0123456789abcdef0123456789abcdef\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        annotated_tag ++ "null",
    };
    for (tag_cases, 0..) |bytes, index| {
        if (github_git.parseTag(std.testing.allocator, bytes, .{ .tag = tag, .object_sha = tag_sha })) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted invalid tag case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.InvalidJson, err);
        }
    }
}

test "foreign noncanonical and unknown ref identities fail closed" {
    const cases = [_][]const u8{
        "{\"ref\":\"refs/heads/v1.2.3\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"ref\":\"refs/tags/v9.9.9\",\"object\":{\"type\":\"commit\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"tree\",\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}",
        "{\"ref\":\"refs/tags/v1.2.3\",\"object\":{\"type\":\"commit\",\"sha\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}}",
    };
    for (cases) |bytes| {
        try std.testing.expectError(error.IdentityMismatch, github_git.parseRef(std.testing.allocator, bytes, tag));
    }
    try std.testing.expectError(error.IdentityMismatch, github_git.parseRef(std.testing.allocator, direct_ref, "v01.2.3"));
    const oversized_tag = "v" ++ ("1" ** github_git.max_response_bytes) ++ ".2.3";
    try std.testing.expectError(error.IdentityMismatch, github_git.parseRef(std.testing.allocator, direct_ref, oversized_tag));
}

test "foreign annotated tag identity and malformed target fail closed" {
    const wrong_tag =
        \\{"tag":"v9.9.9","sha":"89abcdef0123456789abcdef0123456789abcdef",
        \\ "object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    const wrong_self =
        \\{"tag":"v1.2.3","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\ "object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    const wrong_target =
        \\{"tag":"v1.2.3","sha":"89abcdef0123456789abcdef0123456789abcdef",
        \\ "object":{"type":"blob","sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    for ([_][]const u8{ wrong_tag, wrong_self, wrong_target }) |bytes| {
        try std.testing.expectError(error.IdentityMismatch, github_git.parseTag(std.testing.allocator, bytes, .{
            .tag = tag,
            .object_sha = tag_sha,
        }));
    }
}

test "both successful allocation paths are covered by fail-index testing" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_git.parseRefForTest,
        .{ direct_ref, tag },
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_git.parseTagForTest,
        .{ annotated_tag, github_git.ExpectedTag{ .tag = tag, .object_sha = tag_sha } },
    );
}
