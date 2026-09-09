//! Contract tests for the downloaded Release attestation/semantic/final-fence transaction.

const std = @import("std");
const observation = @import("release_adapter_remote_release_observation");
const bridge = @import("release_adapter_remote_release_semantic_files");
const attestation = @import("release_adapter_github_attestation");
const fence_mod = @import("release_adapter_remote_release_fence");
const semantics = @import("release_adapter_remote_release_semantics");
const metadata = @import("release_adapter_remote_release_metadata");
const evidence = @import("release_evidence");
const asset_tests = @import("session_host_release_adapter_remote_release_assets.zig");
const semantic_tests = @import("session_host_release_adapter_remote_release_semantics.zig");

test "baseline held release publishes only after four attestations semantics and final fence" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expectEqual(evidence.Profile.baseline_a, result.value().?.profile);
    try std.testing.expectEqual(@as(u64, 88), result.value().?.release_id);
    try std.testing.expectEqual(@as(usize, 4), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.fence_verifier.calls);
    try std.testing.expect(fixture.assets.fence.value() != null);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    copied.owner = null;
}

test "upgrade held release publishes authenticated profile" {
    var fixture: Fixture = undefined;
    try fixture.init(.upgrade_b);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expectEqual(evidence.Profile.upgrade_b, result.value().?.profile);
}

test "attestation failure unwinds partial receipts and preserves caller owners" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    fixture.attestor.fail_at = 3;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.AttestationFailed, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.assets.result.value() != null);
    try std.testing.expect(fixture.assets.fence.candidate() != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.fence_verifier.calls);
}

test "semantic failure runs after four receipts and before final fence" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    fixture.binder.fail = true;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.SemanticFailed, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(@as(usize, 4), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.fence_verifier.calls);
}

test "last fence failure publishes nothing and preserves retry authority" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    fixture.fence_verifier.fail = true;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.FinalFenceFailed, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.assets.result.value() != null);
    try std.testing.expect(fixture.assets.fence.candidate() != null);
}

test "preowned and aliased output fail before attestation or semantics" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{ .fence_owner = &fixture.assets.fence };
    try std.testing.expectError(error.InvalidOwner, fixture.compose(std.testing.allocator, &result));
    try std.testing.expectEqual(@as(usize, 0), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.binder.calls);
}

test "output and attestation scratch alias fails before external observation" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try std.testing.expectError(error.InvalidOwner, observation.composeUntilWith(&fixture.authority, &fixture.attestor, &fixture.executor, &fixture.binder, &fixture.fence_verifier, std.testing.allocator, asset_tests.context(), &fixture.assets.fence, &fixture.assets.result, "/fake-gh", &fixture.assets.pinned, "token", &fixture.metadata_response, std.mem.asBytes(&result), &fixture.assets.deadline, &result));
    try std.testing.expectEqual(@as(usize, 0), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.binder.calls);
}

test "invalid token fails before held filesystem and attestation" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try std.testing.expectError(error.InvalidToken, observation.composeUntilWith(&fixture.authority, &fixture.attestor, &fixture.executor, &fixture.binder, &fixture.fence_verifier, std.testing.allocator, asset_tests.context(), &fixture.assets.fence, &fixture.assets.result, "/fake-gh", &fixture.assets.pinned, "", &fixture.metadata_response, &fixture.attestation_output, &fixture.assets.deadline, &result));
    try std.testing.expectEqual(@as(usize, 0), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.binder.calls);
}

test "invalid scratch bounds fail before attestation or semantics" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try std.testing.expectError(error.ResponseTooLarge, observation.composeUntilWith(&fixture.authority, &fixture.attestor, &fixture.executor, &fixture.binder, &fixture.fence_verifier, std.testing.allocator, asset_tests.context(), &fixture.assets.fence, &fixture.assets.result, "/fake-gh", &fixture.assets.pinned, "token", fixture.metadata_response[0..0], &fixture.attestation_output, &fixture.assets.deadline, &result));
    try std.testing.expectEqual(@as(usize, 0), fixture.attestor.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.binder.calls);
}

test "dirty embedded semantic storage is rejected before attestation" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    result.semantics.release_id = 1;
    try std.testing.expectError(error.InvalidOwner, fixture.compose(std.testing.allocator, &result));
    try std.testing.expectEqual(@as(usize, 0), fixture.attestor.calls);
}

test "wrong run receipt is rejected before semantic binding" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    fixture.attestor.wrong_run = true;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.AuthorityChanged, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.binder.calls);
}

test "owned allocations remain reclaimable after caller asset drift" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &result);
    fixture.assets.result.file_count -= 1;
    try std.testing.expect(result.value() == null);
    try result.deinit(std.testing.allocator);
    fixture.assets.result.file_count += 1;
}

test "deadline expiry after completed fence revokes observation publication" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    const expires = fixture.assets.deadline.expires_ns;
    fixture.fence_verifier.expire_deadline = true;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.InvalidOwner, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.assets.fence.value() != null);
    fixture.assets.deadline.expires_ns = expires;
}

test "final CLI drift after completed fence revokes observation publication" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    fixture.authority.fail_at = 9;
    var result: observation.Observation = .{};
    try std.testing.expectError(error.ExecutableChanged, fixture.compose(std.testing.allocator, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(fixture.assets.fence.value() != null);
    try std.testing.expect(fixture.assets.result.value() != null);
}

test "all allocation failures leave transaction unpublished and inputs caller-owned" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var result: observation.Observation = .{};
    try fixture.compose(allocator, &result);
    try result.deinit(allocator);
}

const Fixture = struct {
    semantic: semantic_tests.Fixture,
    assets: asset_tests.Fixture,
    authority: Authority = .{},
    attestor: Attestor = .{},
    executor: Executor = .{},
    binder: Binder = .{},
    fence_verifier: FenceVerifier,
    metadata_response: [64 * 1024]u8 = undefined,
    attestation_output: [64 * 1024]u8 = undefined,

    fn init(self: *@This(), profile: evidence.Profile) !void {
        self.semantic = try semantic_tests.Fixture.init(profile);
        errdefer self.semantic.deinit();
        if (profile == .baseline_a)
            try self.assets.initWithPayloads(.{ "dmg", "host", self.semantic.evidence_bytes, self.semantic.manifest_bytes })
        else
            try self.assets.initWithPayloadsNamed(.{ "dmg", "host", self.semantic.evidence_bytes, self.semantic.manifest_bytes }, "upgrade-evidence.json");
        errdefer self.assets.deinit();
        self.authority = .{};
        self.attestor = .{};
        self.executor = .{};
        self.binder = .{};
        self.fence_verifier = .{ .response = &.{} };
        self.fence_verifier.response = self.assets.metadata;
        try self.assets.run();
    }

    fn compose(self: *@This(), allocator: std.mem.Allocator, result: *observation.Observation) !void {
        try observation.composeUntilWith(&self.authority, &self.attestor, &self.executor, &self.binder, &self.fence_verifier, allocator, asset_tests.context(), &self.assets.fence, &self.assets.result, "/fake-gh", &self.assets.pinned, "token", &self.metadata_response, &self.attestation_output, &self.assets.deadline, result);
    }

    fn deinit(self: *@This()) void {
        self.assets.deinit();
        self.semantic.deinit();
    }
};

const Authority = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.ExecutableChanged;
    }
};

const Executor = struct {};

const Attestor = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    wrong_run: bool = false,
    pub fn verify(self: *@This(), _: anytype, allocator: std.mem.Allocator, _: []const u8, token: []const u8, _: std.c.fd_t, path: []const u8, expected: attestation.Expected, _: []u8, budget: i128) !attestation.Observed {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.AttestationFailed;
        try std.testing.expectEqualStrings("token", token);
        try std.testing.expect(budget > 0);
        var expected_path: [metadata.max_name_bytes + 3]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_path, "./{s}", .{expected.subject_name}), path);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
        return .{ .parsed = parsed, .verified = true, .run_id = expected.context.build.run_id + @intFromBool(self.wrong_run), .run_attempt = expected.context.build.run_attempt, .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};

const Binder = struct {
    calls: usize = 0,
    fail: bool = false,
    pub fn bind(self: *@This(), allocator: std.mem.Allocator, context: @import("release_adapter_context").Context, downloaded: anytype, result: *semantics.Owner) !void {
        self.calls += 1;
        if (self.fail) return error.SemanticFailed;
        try bridge.bind(allocator, context, downloaded, result);
    }
};

const FenceVerifier = struct {
    response: []const u8,
    calls: usize = 0,
    fail: bool = false,
    expire_deadline: bool = false,
    pub fn verify(self: *@This(), allocator: std.mem.Allocator, context: @import("release_adapter_context").Context, executable: [:0]const u8, pinned: *const @import("release_adapter_github_cli_authority").PinnedExecutable, token: []const u8, output: []u8, deadline: *@import("release_adapter_deadline").Deadline, release_fence: *fence_mod.Fence) !void {
        self.calls += 1;
        if (self.fail) return error.FinalFenceFailed;
        var ops = FenceOps{ .response = self.response };
        try fence_mod.verifyAfterUntilWith(&ops, &ops, deadline, allocator, context, executable, pinned, token, output, release_fence);
        if (self.expire_deadline) deadline.expires_ns = deadline.started_ns;
    }
};

const FenceOps = struct {
    response: []const u8,
    pub fn revalidate(_: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: *const fence_mod.PinnedExecutable) !void {}
    pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, output: []u8, _: i128) ![]const u8 {
        @memcpy(output[0..self.response.len], self.response);
        return output[0..self.response.len];
    }
};
