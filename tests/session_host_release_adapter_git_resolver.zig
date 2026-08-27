//! Proves bounded, cycle-safe annotated-tag traversal without choosing the product depth policy or
//! claiming that typed observations came from GitHub transport.

const std = @import("std");
const git = @import("release_adapter_github_git");
const resolver = @import("release_adapter_git_resolver");

const release_tag = "v1.2.3";
const commit_sha = "0123456789abcdef0123456789abcdef01234567";
const tag_a_sha = "89abcdef0123456789abcdef0123456789abcdef";
const tag_b_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "lightweight tag binds directly to the exact manifest commit" {
    var visited: [1]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(commit_sha, &backing);
    try chain.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .commit, .sha = commit_sha },
    }, release_tag);
    try std.testing.expectEqualStrings(commit_sha, (try chain.result()).commitSha());
}

test "annotated and nested tags converge on the exact manifest commit" {
    var visited: [2]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(commit_sha, &backing);
    try chain.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag);
    try std.testing.expectEqualStrings(tag_a_sha, (try chain.nextTag()).objectSha());

    try chain.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_a_sha,
        .target = .{ .kind = .tag, .sha = tag_b_sha },
    });
    try std.testing.expectEqualStrings(tag_b_sha, (try chain.nextTag()).objectSha());

    try chain.acceptTag(.{
        .tag = "intermediate-release",
        .object_sha = tag_b_sha,
        .target = .{ .kind = .commit, .sha = commit_sha },
    });
    try std.testing.expectEqualStrings(commit_sha, (try chain.result()).commitSha());
}

test "self and earlier-tag cycles fail closed and poison the traversal" {
    var visited: [2]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(commit_sha, &backing);
    try chain.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag);
    try std.testing.expectError(error.Cycle, chain.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_a_sha,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }));
    try std.testing.expectError(error.Terminal, chain.nextTag());

    var earlier_visited: [2]resolver.Sha = undefined;
    var earlier_backing: resolver.Backing = undefined;
    try earlier_backing.init(&earlier_visited);
    var earlier: resolver.Resolver = undefined;
    try earlier.init(commit_sha, &earlier_backing);
    try earlier.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag);
    try earlier.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_a_sha,
        .target = .{ .kind = .tag, .sha = tag_b_sha },
    });
    try std.testing.expectError(error.Cycle, earlier.acceptTag(.{
        .tag = "intermediate-release",
        .object_sha = tag_b_sha,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }));
}

test "caller backing owns the depth policy and exhaustion is terminal" {
    var visited: [1]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(commit_sha, &backing);
    try chain.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag);
    try std.testing.expectError(error.DepthExceeded, chain.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_a_sha,
        .target = .{ .kind = .tag, .sha = tag_b_sha },
    }));
    try std.testing.expectError(error.Terminal, chain.result());

    var no_backing: [0]resolver.Sha = .{};
    var direct_backing: resolver.Backing = undefined;
    try direct_backing.init(&no_backing);
    var direct_only: resolver.Resolver = undefined;
    try direct_only.init(commit_sha, &direct_backing);
    try std.testing.expectError(error.DepthExceeded, direct_only.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag));

    var invalid_backing: resolver.Backing = undefined;
    try invalid_backing.init(&visited);
    var invalid: resolver.Resolver = undefined;
    try std.testing.expectError(error.InvalidPolicy, invalid.init("not-a-commit", &invalid_backing));

    var overlapping_backing: resolver.Backing = undefined;
    const overlapping = @as([*]resolver.Sha, @ptrCast(&overlapping_backing))[0..1];
    try std.testing.expectError(error.InvalidPolicy, overlapping_backing.init(overlapping));

    var sibling: resolver.Resolver = undefined;
    try std.testing.expectError(error.BackingInUse, sibling.init(commit_sha, &backing));
}

test "foreign commit current-object replay and copied owner fail closed" {
    var visited: [2]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(commit_sha, &backing);
    try chain.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag);

    var copied = chain;
    try std.testing.expectError(error.InvalidOwner, copied.nextTag());

    try std.testing.expectError(error.IdentityMismatch, chain.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_b_sha,
        .target = .{ .kind = .commit, .sha = commit_sha },
    }));
    try std.testing.expectError(error.Terminal, chain.acceptTag(.{
        .tag = release_tag,
        .object_sha = tag_a_sha,
        .target = .{ .kind = .commit, .sha = commit_sha },
    }));

    var foreign_rows: [0]resolver.Sha = .{};
    var foreign_backing: resolver.Backing = undefined;
    try foreign_backing.init(&foreign_rows);
    var foreign: resolver.Resolver = undefined;
    try foreign.init(commit_sha, &foreign_backing);
    try std.testing.expectError(error.IdentityMismatch, foreign.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .commit, .sha = tag_b_sha },
    }, release_tag));

    var replay_rows: [0]resolver.Sha = .{};
    var replay_backing: resolver.Backing = undefined;
    try replay_backing.init(&replay_rows);
    var replay: resolver.Resolver = undefined;
    try replay.init(commit_sha, &replay_backing);
    try replay.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .commit, .sha = commit_sha },
    }, release_tag);
    try std.testing.expectError(error.InvalidState, replay.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .commit, .sha = commit_sha },
    }, release_tag));
    try std.testing.expectError(error.Terminal, replay.result());

    var copied_backing = replay_backing;
    var backing_splice: resolver.Resolver = undefined;
    try std.testing.expectError(error.InvalidOwner, backing_splice.init(commit_sha, &copied_backing));

    var drift_rows: [2]resolver.Sha = undefined;
    var drift_backing: resolver.Backing = undefined;
    try drift_backing.init(&drift_rows);
    var drift: resolver.Resolver = undefined;
    try drift.init(commit_sha, &drift_backing);
    drift_backing.rows = drift_rows[1..];
    try std.testing.expectError(error.InvalidOwner, drift.acceptRef(.{
        .tag = release_tag,
        .target = .{ .kind = .tag, .sha = tag_a_sha },
    }, release_tag));
}
