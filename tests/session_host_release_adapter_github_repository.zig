//! Proves strict semantic binding of a bounded GitHub repository REST response. This component
//! does not claim that the bytes came from GitHub; command execution and transport are later seams.

const std = @import("std");
const github_repository = @import("release_adapter_github_repository");
const manifest = @import("release_manifest");

const expected: manifest.Repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" };

const valid =
    \\{"id":1257870483,"name":"maru","full_name":"ohah/maru","private":false,
    \\ "owner":{"login":"ohah","id":1},"visibility":"public"}
;

test "repository response binds numeric and textual identity while allowing additive fields" {
    var parsed = try github_repository.parseAndBind(std.testing.allocator, valid, expected);
    defer parsed.deinit();
    try std.testing.expectEqual(expected.id, parsed.repository().id);
    try std.testing.expectEqualStrings(expected.owner, parsed.repository().owner);
    try std.testing.expectEqualStrings(expected.name, parsed.repository().name);
}

test "response cap is enforced before parsing" {
    const oversized = " " ** (github_repository.max_response_bytes + 1);
    try std.testing.expectError(
        error.ResponseTooLarge,
        github_repository.parseAndBind(std.testing.allocator, oversized, expected),
    );
}

test "malformed missing wrong-type duplicate and trailing JSON fail closed" {
    const cases = [_][]const u8{
        "{",
        "{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{}}",
        "{\"id\":\"1257870483\",\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}",
        "{\"id\":1257870483,\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}",
        "{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\",\"login\":\"ohah\"}}",
        valid ++ "null",
    };
    for (cases, 0..) |bytes, index| {
        if (github_repository.parseAndBind(std.testing.allocator, bytes, expected)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            std.debug.print("unexpected accepted invalid JSON case {d}\n", .{index});
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.InvalidJson, err);
        }
    }
}

test "zero and internally inconsistent or foreign repository identities fail closed" {
    const cases = [_][]const u8{
        "{\"id\":0,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}",
        "{\"id\":1257870483,\"name\":\"other\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}",
        "{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"attacker/maru\",\"owner\":{\"login\":\"ohah\"}}",
        "{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"attacker\"}}",
    };
    for (cases) |bytes| {
        try std.testing.expectError(
            error.RepositoryMismatch,
            github_repository.parseAndBind(std.testing.allocator, bytes, expected),
        );
    }

    var wrong_id = expected;
    wrong_id.id += 1;
    try std.testing.expectError(
        error.RepositoryMismatch,
        github_repository.parseAndBind(std.testing.allocator, valid, wrong_id),
    );
}

test "every successful allocation is covered by fail-index testing" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        github_repository.parseAndBindForTest,
        .{ valid, expected },
    );
}
