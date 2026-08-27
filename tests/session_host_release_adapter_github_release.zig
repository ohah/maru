//! Proves strict semantic binding of bounded GitHub release REST responses. These component
//! fixtures do not authenticate transport or the executable that captured the response bytes.

const std = @import("std");
const github_release = @import("release_adapter_github_release");

const draft_expected: github_release.Expected = .{
    .id = 91,
    .tag = "v1.2.3",
    .publication = .draft,
};

const draft_valid =
    \\{"id":91,"tag_name":"v1.2.3",
    \\ "target_commitish":"0123456789abcdef0123456789abcdef01234567",
    \\ "draft":true,"prerelease":false,"immutable":false,"assets":[]}
;

const predecessor_valid =
    \\{"id":73,"tag_name":"v1.1.0",
    \\ "target_commitish":"fedcba9876543210fedcba9876543210fedcba98",
    \\ "draft":false,"prerelease":false,"immutable":true,"assets":[]}
;

test "draft and immutable published release responses bind exact identity and state" {
    var draft = try github_release.parseAndBind(std.testing.allocator, draft_valid, draft_expected);
    defer draft.deinit();
    try std.testing.expectEqual(draft_expected.id, draft.observation().id);
    try std.testing.expectEqualStrings(draft_expected.tag, draft.observation().tag);
    try std.testing.expectEqual(github_release.Publication.draft, draft.observation().publication);

    const draft_without_optional_immutable =
        \\{"id":91,"tag_name":"v1.2.3",
        \\ "target_commitish":"0123456789abcdef0123456789abcdef01234567",
        \\ "draft":true,"prerelease":false}
    ;
    var compatible_draft = try github_release.parseAndBind(
        std.testing.allocator,
        draft_without_optional_immutable,
        draft_expected,
    );
    compatible_draft.deinit();

    var predecessor = try github_release.parseAndBind(std.testing.allocator, predecessor_valid, .{
        .id = 73,
        .tag = "v1.1.0",
        .publication = .published_immutable,
    });
    defer predecessor.deinit();
    try std.testing.expectEqual(github_release.Publication.published_immutable, predecessor.observation().publication);
}

test "response cap is enforced before parsing" {
    const oversized = " " ** (github_release.max_response_bytes + 1);
    try std.testing.expectError(
        error.ResponseTooLarge,
        github_release.parseAndBind(std.testing.allocator, oversized, draft_expected),
    );
}

test "malformed missing wrong-type duplicate and trailing JSON fail closed" {
    const cases = [_][]const u8{
        "{",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"immutable\":false}",
        "{\"id\":\"91\",\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"draft\":true,\"prerelease\":false,\"immutable\":null}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"draft\":true,\"prerelease\":false,\"immutable\":\"false\"}",
        "{\"id\":91,\"id\":91,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"draft\":true,\"prerelease\":false,\"immutable\":false,\"immutable\":false}",
        draft_valid ++ "null",
    };
    for (cases, 0..) |bytes, index| {
        if (github_release.parseAndBind(std.testing.allocator, bytes, draft_expected)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted invalid JSON case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.InvalidJson, err);
        }
    }
}

test "zero and foreign release identity fail closed" {
    const cases = [_][]const u8{
        "{\"id\":0,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":92,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v9.9.9\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":false}",
    };
    for (cases) |bytes| {
        try std.testing.expectError(
            error.ReleaseMismatch,
            github_release.parseAndBind(std.testing.allocator, bytes, draft_expected),
        );
    }

    const invalid_expected = [_]github_release.Expected{
        .{ .id = 0, .tag = draft_expected.tag, .publication = .draft },
        .{ .id = draft_expected.id, .tag = "v01.2.3", .publication = .draft },
    };
    for (invalid_expected) |expected| {
        try std.testing.expectError(
            error.ReleaseMismatch,
            github_release.parseAndBind(std.testing.allocator, draft_valid, expected),
        );
    }
}

test "draft prerelease and immutable state mismatches fail closed" {
    const cases = [_][]const u8{
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":true,\"immutable\":false}",
        "{\"id\":91,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":true,\"prerelease\":false,\"immutable\":true}",
    };
    for (cases) |bytes| {
        try std.testing.expectError(
            error.ReleaseMismatch,
            github_release.parseAndBind(std.testing.allocator, bytes, draft_expected),
        );
    }

    var expected = draft_expected;
    expected.publication = .published_immutable;
    try std.testing.expectError(
        error.ReleaseMismatch,
        github_release.parseAndBind(std.testing.allocator, draft_valid, expected),
    );
    const published_without_immutable =
        \\{"id":73,"tag_name":"v1.1.0",
        \\ "target_commitish":"fedcba9876543210fedcba9876543210fedcba98",
        \\ "draft":false,"prerelease":false}
    ;
    try std.testing.expectError(
        error.ReleaseMismatch,
        github_release.parseAndBind(std.testing.allocator, published_without_immutable, .{
            .id = 73,
            .tag = "v1.1.0",
            .publication = .published_immutable,
        }),
    );
}

test "every successful allocation is covered by fail-index testing" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_release.parseAndBindForTest,
        .{ draft_valid, draft_expected },
    );
}
