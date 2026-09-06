//! Proves that fresh cleanup discovers current asset IDs twice around the existing attestation.

const std = @import("std");
const builtin = @import("builtin");
const subject = @import("release_adapter_candidate_published_cleanup_authority");
const post = @import("release_adapter_github_post_publish_attestation");

const paths = [_][]const u8{
    "/tmp/Maru-1.2.3-universal.dmg",
    "/tmp/maru-session-host-1.2.3",
    "/tmp/evidence.json",
    "/tmp/Maru-1.2.3-session-host-release.json",
};

fn expected() subject.Expected {
    var assets: [subject.asset_count]subject.ExpectedAsset = undefined;
    for (&assets, 0..) |*asset, index| asset.* = .{
        .path = paths[index],
        .name = std.fs.path.basename(paths[index]),
        .size = 100 + index,
        .sha256 = [_]u8{'a' + @as(u8, @intCast(index))} ** 64,
    };
    return .{
        .context = .{
            .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" },
            .tag = "v1.2.3",
            .source_commit = "0123456789abcdef0123456789abcdef01234567",
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 44, .run_attempt = 2 },
            .protected_tag = true,
        },
        .release_id = 88,
        .cli_sha256 = [_]u8{'f'} ** 64,
        .assets = assets,
    };
}

const Source = struct {
    value: subject.Expected = expected(),
    calls: usize = 0,
    drift_at: ?usize = null,
    fail_at: ?usize = null,

    pub fn snapshot(self: *@This()) !subject.Expected {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.OutOfMemory;
        var result = self.value;
        if (self.drift_at) |at| {
            if (self.calls >= at) result.assets[1].size += 1;
        }
        return result;
    }
};

const Remote = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    drift_final: bool = false,
    ids: [subject.asset_count]u64 = .{ 1000, 1001, 1002, 1003 },

    pub fn fetch(self: *@This(), _: subject.Expected, _: i128) !subject.ObservedPublished {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.RemoteFailed;
        var ids = self.ids;
        if (self.drift_final and self.calls == 2) ids[3] += 100;
        return .{ .release_id = 88, .asset_ids = ids };
    }
};

const AttestationDriver = struct {
    calls: usize = 0,
    fail_at: ?usize = null,

    pub fn resolve(self: *@This(), expected_snapshot: post.Snapshot, _: i128) !post.ResolvedTag {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.AttestationFailed;
        return .{
            .tag_ref_sha = "fedcba9876543210fedcba9876543210fedcba98".*,
            .source_commit = expected_snapshot.source_commit[0..40].*,
        };
    }

    pub fn verify(self: *@This(), expected_snapshot: post.Snapshot, resolved: post.ResolvedTag, index: ?usize, _: i128) !post.Observation {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.AttestationFailed;
        return post.testing_api.observe(expected_snapshot, resolved, index);
    }
};

const Verifier = struct {
    driver: AttestationDriver = .{},
    check_copy: bool = false,

    pub fn verify(self: *@This(), authority: anytype, deadline: anytype, result: *post.VerifiedRelease) !void {
        if (self.check_copy) {
            var copied = authority.*;
            try std.testing.expectError(error.InvalidOwner, copied.snapshot());
        }
        try post.testing_api.verify(authority, &self.driver, deadline, result);
    }
};

const Deadline = struct {
    calls: usize = 0,
    expire_at: ?usize = null,

    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.expire_at == self.calls) return error.TimedOut;
        return 1_000_000 - @as(i128, @intCast(self.calls));
    }
};

fn run(source: *Source, remote: *Remote, verifier: *Verifier, deadline: *Deadline, result: *post.VerifiedRelease) !void {
    try subject.testing_api.authenticate(source, remote, verifier, deadline, result);
}

test "two exact published reads bracket one sealed post-publish attestation" {
    var source = Source{};
    var remote = Remote{};
    var verifier = Verifier{ .check_copy = true };
    var deadline = Deadline{};
    var result: post.VerifiedRelease = .{};
    try run(&source, &remote, &verifier, &deadline, &result);
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    try std.testing.expectEqual([_]u64{ 1000, 1001, 1002, 1003 }, value.artifact_ids);
    try std.testing.expectEqual(@as(usize, 2), remote.calls);
    try std.testing.expectEqual(@as(usize, 6), verifier.driver.calls);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit();
}

test "final published ID exchange removes the temporary local receipt" {
    var source = Source{};
    var remote = Remote{ .drift_final = true };
    var verifier = Verifier{};
    var deadline = Deadline{};
    var result: post.VerifiedRelease = .{};
    try std.testing.expectError(error.PublishedChanged, run(&source, &remote, &verifier, &deadline, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(post.VerifiedRelease{}, result);
}

test "local graph drift at every attestation fence publishes nothing" {
    inline for (2..12) |drift_at| {
        var source = Source{ .drift_at = drift_at };
        var remote = Remote{};
        var verifier = Verifier{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.AuthorityChanged, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
    inline for (1..12) |fail_at| {
        var source = Source{ .fail_at = fail_at };
        var remote = Remote{};
        var verifier = Verifier{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.OutOfMemory, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "both published lookups fail closed without a receipt" {
    inline for (1..3) |fail_at| {
        var source = Source{};
        var remote = Remote{ .fail_at = fail_at };
        var verifier = Verifier{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.RemoteFailed, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "every attestation child failure publishes nothing" {
    inline for (1..7) |fail_at| {
        var source = Source{};
        var remote = Remote{};
        var verifier = Verifier{ .driver = .{ .fail_at = fail_at } };
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.AttestationFailed, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "invalid and aliased discovered IDs are rejected before attestation" {
    inline for (.{ [_]u64{ 0, 2, 3, 4 }, [_]u64{ 1, 2, 2, 4 } }) |ids| {
        var source = Source{};
        var remote = Remote{ .ids = ids };
        var verifier = Verifier{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.InvalidPublished, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expectEqual(@as(usize, 0), verifier.driver.calls);
        try std.testing.expect(result.value() == null);
    }
}

test "preowned result and deadline expiry preserve no new authority" {
    var source = Source{};
    var remote = Remote{};
    var verifier = Verifier{};
    var deadline = Deadline{};
    var occupied: post.VerifiedRelease = .{ .release_id = 1 };
    try std.testing.expectError(error.InvalidOwner, run(&source, &remote, &verifier, &deadline, &occupied));
    try std.testing.expectEqual(@as(usize, 0), remote.calls);

    var aggregate: @import("release_adapter_candidate_aggregate_reopen").ReopenedAggregate = .{};
    var pinned: @import("release_adapter_github_cli_authority").PinnedExecutable = .{
        .path_sha256 = @splat(0),
        .path_len = 0,
        .identity = .{ .device = 0, .inode = 0 },
        .size = 0,
        .mode = 0,
        .sha256 = @splat(0),
    };
    var product_deadline: @import("release_adapter_deadline").Deadline = .{};
    var response: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, subject.authenticateUntil(
        std.testing.io,
        std.testing.allocator,
        &aggregate,
        .{ .path = "/usr/bin/false", .pinned = &pinned },
        "token",
        &response,
        &product_deadline,
        &occupied,
    ));

    var pristine_product: post.VerifiedRelease = .{};
    const aliased_response = std.mem.asBytes(&pristine_product);
    try std.testing.expectError(error.InvalidOwner, subject.authenticateUntil(
        std.testing.io,
        std.testing.allocator,
        &aggregate,
        .{ .path = "/usr/bin/false", .pinned = &pinned },
        "token",
        aliased_response,
        &product_deadline,
        &pristine_product,
    ));

    inline for (1..13) |expire_at| {
        source = .{};
        remote = .{};
        verifier = .{};
        deadline = .{ .expire_at = expire_at };
        var result: post.VerifiedRelease = .{};
        try std.testing.expectError(error.TimedOut, run(&source, &remote, &verifier, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "published response parser binds lifecycle and exact four assets independent of order" {
    const exp = expected();
    const bytes =
        \\{"id":88,"tag_name":"v1.2.3","target_commitish":"0123456789abcdef0123456789abcdef01234567","draft":false,"prerelease":false,"immutable":true,"assets":[
        \\{"id":1003,"name":"Maru-1.2.3-session-host-release.json","size":103,"state":"uploaded","digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","content_type":"application/octet-stream"},
        \\{"id":1000,"name":"Maru-1.2.3-universal.dmg","size":100,"state":"uploaded","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","content_type":"application/octet-stream"},
        \\{"id":1002,"name":"evidence.json","size":102,"state":"uploaded","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","content_type":"application/octet-stream"},
        \\{"id":1001,"name":"maru-session-host-1.2.3","size":101,"state":"uploaded","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","content_type":"application/octet-stream"}]}
    ;
    const observed = try subject.testing_api.parse(std.testing.allocator, bytes, exp);
    try std.testing.expectEqual([_]u64{ 1000, 1001, 1002, 1003 }, observed.asset_ids);

    const wrong_lifecycle = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"immutable\":true", "\"immutable\":false");
    defer std.testing.allocator.free(wrong_lifecycle);
    try std.testing.expectError(error.InvalidResponse, subject.testing_api.parse(std.testing.allocator, wrong_lifecycle, exp));

    const extra = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "]}", ",{\"id\":9999,\"name\":\"foreign\",\"size\":1,\"state\":\"uploaded\",\"digest\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"content_type\":\"application/octet-stream\"}]}");
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.InvalidResponse, subject.testing_api.parse(std.testing.allocator, extra, exp));

    const missing_start = std.mem.indexOf(u8, bytes, "{\"id\":1001").?;
    const missing_end = std.mem.indexOfPos(u8, bytes, missing_start, "}").? + 1;
    const missing = try std.mem.concat(std.testing.allocator, u8, &.{ bytes[0 .. missing_start - 1], bytes[missing_end..] });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidResponse, subject.testing_api.parse(std.testing.allocator, missing, exp));

    const duplicate_id = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"id\":1003", "\"id\":1000");
    defer std.testing.allocator.free(duplicate_id);
    try std.testing.expectError(error.InvalidResponse, subject.testing_api.parse(std.testing.allocator, duplicate_id, exp));

    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithFailingAllocator, .{ bytes, exp });
}

fn parseWithFailingAllocator(allocator: std.mem.Allocator, bytes: []const u8, exp: subject.Expected) !void {
    _ = try subject.testing_api.parse(allocator, bytes, exp);
}

test "ReleaseFast diagnostic measures the whole injected composition" {
    if (builtin.mode != .ReleaseFast) return error.SkipZigTest;
    var samples: [20]u64 = undefined;
    const fd_before = try openFdCount();
    var external_calls: usize = 0;
    for (&samples) |*sample| {
        var source = Source{};
        var remote = Remote{};
        var verifier = Verifier{};
        var deadline = Deadline{};
        var result: post.VerifiedRelease = .{};
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        try run(&source, &remote, &verifier, &deadline, &result);
        sample.* = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started);
        external_calls += remote.calls + verifier.driver.calls;
        try result.deinit();
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const fd_after = try openFdCount();
    std.debug.print("published_cleanup_reauthentication mode=ReleaseFast samples=20 failures=0 fd_delta={d} external_calls={d} median_ns={d} p95_ns={d} max_ns={d}\n", .{
        @as(i64, fd_after) - @as(i64, fd_before), external_calls, samples[10], samples[18], samples[19],
    });
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
