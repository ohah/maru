//! Stage 8 deletes a retained aggregate only after a sealed publication receipt is rebound.

const std = @import("std");
const retention = @import("release_adapter_candidate_aggregate_retention");
const post = @import("release_adapter_github_post_publish_attestation");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

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
    return .{
        .release_id = 88,
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .cli_sha256 = [_]u8{'f'} ** 64,
        .artifacts = artifacts,
    };
}

const ReceiptAuthority = struct {
    pub fn snapshot(_: *@This()) !post.Snapshot {
        return expectedSnapshot();
    }
};

const ReceiptDriver = struct {
    calls: usize = 0,
    pub fn resolve(self: *@This(), expected: post.Snapshot, _: i128) !post.ResolvedTag {
        self.calls += 1;
        var result: post.ResolvedTag = undefined;
        @memcpy(&result.tag_ref_sha, "fedcba9876543210fedcba9876543210fedcba98");
        @memcpy(&result.source_commit, expected.source_commit);
        return result;
    }
    pub fn verify(self: *@This(), expected: post.Snapshot, tag: post.ResolvedTag, index: ?usize, _: i128) !post.Observation {
        self.calls += 1;
        return post.testing_api.observe(expected, tag, index);
    }
};

const ReceiptDeadline = struct {
    pub fn remaining(_: *@This()) !i128 {
        return 1_000;
    }
};

fn receipt(result: *post.VerifiedRelease) !void {
    var authority = ReceiptAuthority{};
    var driver = ReceiptDriver{};
    var deadline = ReceiptDeadline{};
    try post.testing_api.verify(&authority, &driver, &deadline, result);
}

const Op = enum { validate, fence, rename, fence_tomb, unlink_4, unlink_3, unlink_2, unlink_1, unlink_0, sync_directory, remove_directory, sync_parent, close };

const Driver = struct {
    calls: std.ArrayList(Op) = .empty,
    fail: ?Op = null,
    close_failed: bool = false,

    fn record(self: *@This(), op: Op) !void {
        try self.calls.append(std.testing.allocator, op);
        if (self.fail == op) return error.InjectedFailure;
    }

    pub fn sourceAddress(_: *@This()) usize {
        return 0x1234;
    }

    pub fn validate(self: *@This(), value: post.View) !void {
        try self.record(.validate);
        const expected = expectedSnapshot();
        if (value.release_id != expected.release_id or !std.mem.eql(u8, value.tag, expected.tag) or
            !std.mem.eql(u8, value.source_commit, expected.source_commit) or
            !std.mem.eql(u64, &value.artifact_ids, &.{ 1000, 1001, 1002, 1003 })) return error.BindingMismatch;
        for (value.artifact_sha256, expected.artifacts) |actual, artifact|
            if (!std.mem.eql(u8, &actual, &artifact.sha256)) return error.BindingMismatch;
    }

    pub fn fence(self: *@This()) !void {
        try self.record(.fence);
    }

    pub fn renameToTomb(self: *@This(), deletion: *retention.Deletion) !void {
        deletion.tomb_len = ".maru-aggregate-cleanup-1".len;
        @memcpy(deletion.tomb[0..deletion.tomb_len], ".maru-aggregate-cleanup-1");
        try self.record(.rename);
    }

    pub fn fenceTomb(self: *@This(), _: *retention.Deletion) !void {
        try self.record(.fence_tomb);
    }

    pub fn unlink(self: *@This(), _: *retention.Deletion, index: usize) !void {
        try self.record(@enumFromInt(@intFromEnum(Op.unlink_4) + (4 - index)));
    }

    pub fn syncDirectory(self: *@This(), _: *retention.Deletion) !void {
        try self.record(.sync_directory);
    }

    pub fn removeDirectory(self: *@This(), _: *retention.Deletion) !void {
        try self.record(.remove_directory);
    }

    pub fn syncParent(self: *@This(), _: *retention.Deletion) !void {
        try self.record(.sync_parent);
    }

    pub fn closeDescriptors(self: *@This(), _: *retention.Deletion) !void {
        try self.record(.close);
        if (self.close_failed) return error.DescriptorCloseFailed;
    }

    fn deinit(self: *@This()) void {
        self.calls.deinit(std.testing.allocator);
    }
};

const success_order = [_]Op{ .validate, .fence, .rename, .fence_tomb, .unlink_4, .unlink_3, .unlink_2, .unlink_1, .unlink_0, .sync_directory, .remove_directory, .sync_parent, .close };

test "sealed publication receipt permits one exact reverse deletion" {
    var verified: post.VerifiedRelease = .{};
    try receipt(&verified);
    defer if (verified.value() != null) verified.deinit() catch {};
    var driver = Driver{};
    defer driver.deinit();
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.success, try retention.testing_api.execute(&driver, &verified, &deletion));
    try std.testing.expectEqualSlices(Op, &success_order, driver.calls.items);
    try std.testing.expect(deletion.isPristine());
}

test "validation and final fence failures perform no deletion mutation" {
    inline for (.{ Op.validate, Op.fence }) |failure| {
        var verified: post.VerifiedRelease = .{};
        try receipt(&verified);
        defer verified.deinit() catch {};
        var driver = Driver{ .fail = failure };
        defer driver.deinit();
        var deletion: retention.Deletion = .{};
        try std.testing.expectEqual(retention.Outcome.audit_required, try retention.testing_api.execute(&driver, &verified, &deletion));
        try std.testing.expect(std.mem.indexOfScalar(Op, driver.calls.items, .rename) == null);
        try std.testing.expect(deletion.isPristine());
    }
}

test "every post-rename failure retains a monotonic retry suffix" {
    inline for (.{ Op.fence_tomb, Op.unlink_4, Op.unlink_3, Op.unlink_2, Op.unlink_1, Op.unlink_0, Op.sync_directory, Op.remove_directory, Op.sync_parent }) |failure| {
        var verified: post.VerifiedRelease = .{};
        try receipt(&verified);
        defer verified.deinit() catch {};
        var driver = Driver{ .fail = failure };
        defer driver.deinit();
        var deletion: retention.Deletion = .{};
        try std.testing.expectEqual(retention.Outcome.cleanup_required, try retention.testing_api.execute(&driver, &verified, &deletion));
        const prefix_len = driver.calls.items.len;
        driver.fail = null;
        try std.testing.expectEqual(retention.Outcome.success, try retention.testing_api.retry(&driver, &deletion));
        try std.testing.expect(deletion.isPristine());
        const resumed = driver.calls.items[prefix_len..];
        try std.testing.expect(resumed.len != 0);
        try std.testing.expectEqual(failure, resumed[0]);
        try std.testing.expect(std.mem.indexOfScalar(Op, resumed, .rename) == null);
        if (failure == .fence_tomb)
            try std.testing.expect(std.mem.indexOfScalar(Op, driver.calls.items[0..prefix_len], .unlink_4) == null);
    }
}

test "descriptor close uncertainty is terminal and never retries the fd number" {
    var verified: post.VerifiedRelease = .{};
    try receipt(&verified);
    defer verified.deinit() catch {};
    var driver = Driver{ .close_failed = true };
    defer driver.deinit();
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.descriptor_close_failed, try retention.testing_api.execute(&driver, &verified, &deletion));
    const calls = driver.calls.items.len;
    try std.testing.expectError(error.NonRetryable, retention.testing_api.retry(&driver, &deletion));
    try std.testing.expectEqual(calls, driver.calls.items.len);
}

test "copied deletion and mutated receipt fail before rename" {
    var verified: post.VerifiedRelease = .{};
    try receipt(&verified);
    defer verified.deinit() catch {};
    var driver = Driver{ .fail = .unlink_4 };
    defer driver.deinit();
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.cleanup_required, try retention.testing_api.execute(&driver, &verified, &deletion));
    var copied = deletion;
    driver.fail = null;
    try std.testing.expectError(error.InvalidOwner, retention.testing_api.retry(&driver, &copied));
    verified.release_id += 1;
    var pristine: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.audit_required, try retention.testing_api.execute(&driver, &verified, &pristine));
}

test "corrupt cleanup ledger fails closed without another operation" {
    var verified: post.VerifiedRelease = .{};
    try receipt(&verified);
    defer verified.deinit() catch {};
    var driver = Driver{ .fail = .unlink_2 };
    defer driver.deinit();
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.cleanup_required, try retention.testing_api.execute(&driver, &verified, &deletion));
    deletion.testing_api_corruptLedger();
    const calls = driver.calls.items.len;
    driver.fail = null;
    try std.testing.expectError(error.InvalidOwner, retention.testing_api.retry(&driver, &deletion));
    try std.testing.expectEqual(calls, driver.calls.items.len);
}

test "production entrypoint accepts only reopened aggregate and same-process verified receipt" {
    var deletion: retention.Deletion = .{};
    var verified: post.VerifiedRelease = .{};
    try std.testing.expectError(error.InvalidOwner, retention.deleteVerifiedAggregate(
        std.testing.allocator,
        undefined,
        &verified,
        &deletion,
    ));
}

test "stage 8 deletion primitive is credential free and has no executable caller yet" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_aggregate_retention.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "GH_TOKEN", "std.process", "std.posix.getenv" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn deleteVerifiedAggregate("));
    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try posixWalk(src, std.testing.allocator);
    defer walker.deinit();
    var callers: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const product = try src.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(product);
        callers += std.mem.count(u8, product, "release_adapter_candidate_aggregate_retention");
    }
    try std.testing.expectEqual(@as(usize, 0), callers);
}
