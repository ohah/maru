const std = @import("std");
const post = @import("release_adapter_github_post_publish_attestation");

const paths = [_][]const u8{ "/tmp/Maru.dmg", "/tmp/maru-session-host", "/tmp/evidence.json", "/tmp/manifest.json" };

fn expectedSnapshot() post.Snapshot {
    var artifacts: [post.artifact_count]post.Artifact = undefined;
    for (&artifacts, 0..) |*artifact, index| artifact.* = .{
        .id = 1000 + index,
        .path = paths[index],
        .name = std.fs.path.basename(paths[index]),
        .size = 100 + index,
        .sha256 = [_]u8{'a' + @as(u8, @intCast(index))} ** 64,
    };
    return .{ .release_id = 88, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .cli_sha256 = [_]u8{'f'} ** 64, .artifacts = artifacts };
}

const Authority = struct {
    current: post.Snapshot = expectedSnapshot(),
    calls: usize = 0,
    drift_at: ?usize = null,
    fail_at: ?usize = null,
    pub fn snapshot(self: *@This()) !post.Snapshot {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.OutOfMemory;
        var value = self.current;
        if (self.drift_at) |at| {
            if (self.calls >= at) value.artifacts[2].size += 1;
        }
        return value;
    }
};

const Driver = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    foreign_at: ?usize = null,
    foreign_source: bool = false,
    pub fn resolve(self: *@This(), expected: post.Snapshot, _: i128) !post.ResolvedTag {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.ChildFailed;
        var result: post.ResolvedTag = undefined;
        @memcpy(&result.tag_ref_sha, "fedcba9876543210fedcba9876543210fedcba98");
        @memcpy(&result.source_commit, if (self.foreign_source) "ffffffffffffffffffffffffffffffffffffffff" else expected.source_commit);
        return result;
    }
    pub fn verify(self: *@This(), expected: post.Snapshot, tag: post.ResolvedTag, artifact_index: ?usize, _: i128) !post.Observation {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.ChildFailed;
        var result = post.testing_api.observe(expected, tag, artifact_index);
        if (self.foreign_at == self.calls) result.release_id += 1;
        return result;
    }
};

const Deadline = struct {
    remaining_calls: usize = 0,
    expire_at: ?usize = null,
    pub fn remaining(self: *@This()) !i128 {
        self.remaining_calls += 1;
        if (self.expire_at == self.remaining_calls) return error.TimedOut;
        return 1000 - @as(i128, @intCast(self.remaining_calls));
    }
};

test "tag chain then release and four held assets publish one verified owner" {
    var authority = Authority{};
    var driver = Driver{};
    var deadline = Deadline{};
    var result: post.VerifiedRelease = .{};
    try post.testing_api.verify(&authority, &driver, &deadline, &result);
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba98", value.tag_ref_sha);
    try std.testing.expectEqual([_]u64{ 1000, 1001, 1002, 1003 }, value.artifact_ids);
    try std.testing.expectEqual([_]u8{'d'} ** 64, value.artifact_sha256[3]);
    try std.testing.expectEqual(@as(usize, 6), driver.calls);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    const saved = result.artifact_ids[3];
    result.artifact_ids[3] = result.artifact_ids[2];
    try std.testing.expect(result.value() == null);
    result.artifact_ids[3] = saved;
    try result.deinit();
}

test "every child failure publishes no verified authority" {
    inline for (1..7) |fail_at| {
        var authority = Authority{};
        var driver = Driver{ .fail_at = fail_at };
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.ChildFailed, post.testing_api.verify(&authority, &driver, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "foreign release or asset statement publishes no verified authority" {
    inline for (2..7) |foreign_at| {
        var authority = Authority{};
        var driver = Driver{ .foreign_at = foreign_at };
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.AttestationMismatch, post.testing_api.verify(&authority, &driver, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "authority drift at every child fence publishes no verified authority" {
    inline for (2..8) |drift_at| {
        var authority = Authority{ .drift_at = drift_at };
        var driver = Driver{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.AuthorityChanged, post.testing_api.verify(&authority, &driver, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "deadline expiry at every external phase publishes no verified authority" {
    inline for (1..9) |expire_at| {
        var authority = Authority{};
        var driver = Driver{};
        var deadline = Deadline{ .expire_at = expire_at };
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.TimedOut, post.testing_api.verify(&authority, &driver, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "allocation failure at every authority fence publishes no verified authority" {
    inline for (1..8) |fail_at| {
        var authority = Authority{ .fail_at = fail_at };
        var driver = Driver{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.OutOfMemory, post.testing_api.verify(&authority, &driver, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "preowned result and invalid source convergence fail closed" {
    var authority = Authority{};
    var driver = Driver{};
    var deadline = Deadline{};
    var result: post.VerifiedRelease = .{};
    result.release_id = 1;
    try std.testing.expectError(error.InvalidOwner, post.testing_api.verify(&authority, &driver, &deadline, &result));
    result = .{};
    driver.foreign_source = true;
    try std.testing.expectError(error.SourceMismatch, post.testing_api.verify(&authority, &driver, &deadline, &result));
}

test "production boundary is instantiated and rejects preowned result before borrowed input" {
    var result: post.VerifiedRelease = .{ .release_id = 1 };
    try std.testing.expectError(error.InvalidOwner, post.verifyUntil(
        std.testing.io,
        undefined,
        undefined,
        undefined,
        undefined,
        "",
        &.{},
        undefined,
        &result,
    ));
}
