//! Authenticated pre-publish predecessor authority composition contract.

const std = @import("std");
const assets = @import("release_adapter_github_predecessor_assets");
const identity = @import("release_adapter_predecessor_evidence_identity");
const binding = @import("release_adapter_profile_predecessor_binding");
const composition = @import("release_adapter_profile_predecessor_authority");

const Step = enum { preflight, fence, child, assets, identity, binding, deadline, revalidate, cleanup_binding, cleanup_identity, cleanup_assets };

const Operations = struct {
    steps: [32]Step = undefined,
    len: usize = 0,
    fail_at: usize = 0,
    cleanup_fail: ?Step = null,
    partial_assets_fail: bool = false,

    fn record(self: *@This(), step: Step) !void {
        self.steps[self.len] = step;
        self.len += 1;
        if (self.fail_at == self.len) return error.ChildFailed;
    }
    pub fn preflight(self: *@This(), _: anytype, result: *composition.AuthenticatedPredecessor) !void {
        try self.record(.preflight);
        if (!result.isPristineForComposition()) return error.InvalidOwner;
    }
    pub fn fence(self: *@This()) !void {
        try self.record(.fence);
    }
    pub fn childPath(self: *@This(), output: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
        try self.record(.child);
        return std.fmt.bufPrintZ(output, "/private/tmp/predecessor-assets", .{});
    }
    pub fn authenticateAssets(self: *@This(), _: anytype, _: [:0]const u8, result: *assets.AuthenticatedPredecessorAssets) !void {
        try self.record(.assets);
        result.downloads.owner = &result.downloads;
        if (self.partial_assets_fail) return error.ChildFailed;
        result.owner = result;
    }
    pub fn composeIdentity(self: *@This(), _: *const assets.AuthenticatedPredecessorAssets, result: *identity.PredecessorEvidenceIdentity) !void {
        try self.record(.identity);
        result.owner = result;
    }
    pub fn bind(self: *@This(), _: *const assets.AuthenticatedPredecessorAssets, _: *const identity.PredecessorEvidenceIdentity, result: *binding.BoundPredecessor) !void {
        try self.record(.binding);
        result.owner = result;
    }
    pub fn revalidate(self: *@This(), _: *const assets.AuthenticatedPredecessorAssets, _: *const identity.PredecessorEvidenceIdentity, _: *const binding.BoundPredecessor) !void {
        try self.record(.revalidate);
    }
    pub fn cleanupBinding(self: *@This(), result: *binding.BoundPredecessor) !void {
        try self.record(.cleanup_binding);
        if (self.cleanup_fail == .cleanup_binding) return error.CleanupFailed;
        result.* = .{};
    }
    pub fn cleanupIdentity(self: *@This(), result: *identity.PredecessorEvidenceIdentity) !void {
        try self.record(.cleanup_identity);
        if (self.cleanup_fail == .cleanup_identity) return error.CleanupFailed;
        result.* = .{};
    }
    pub fn cleanupAssets(self: *@This(), result: *assets.AuthenticatedPredecessorAssets) !void {
        try self.record(.cleanup_assets);
        if (self.cleanup_fail == .cleanup_assets) return error.CleanupFailed;
        result.* = .{};
    }
};

const Deadline = struct {
    operations: *Operations,
    fail: bool = false,
    pub fn remaining(self: *@This()) !i128 {
        try self.operations.record(.deadline);
        if (self.fail) return error.TimedOut;
        return 1;
    }
};

test "authority is a nominal final-address owner of the complete predecessor graph" {
    var result: composition.AuthenticatedPredecessor = .{};
    try std.testing.expect(@TypeOf(result.assets) == assets.AuthenticatedPredecessorAssets);
    try std.testing.expect(@TypeOf(result.identity) == identity.PredecessorEvidenceIdentity);
    try std.testing.expect(@TypeOf(result.binding) == binding.BoundPredecessor);
    try std.testing.expect(result.isPristineForComposition());
}

test "download-only partial ownership is cleaned and remains retryable after uncertainty" {
    var operations = Operations{ .partial_assets_fail = true, .cleanup_fail = .cleanup_assets };
    var deadline = Deadline{ .operations = &operations };
    var result: composition.AuthenticatedPredecessor = .{};
    try std.testing.expectError(error.CleanupFailed, composition.authenticateUntilWith(&operations, &deadline, &result));
    try std.testing.expect(result.owner == &result);
    try std.testing.expect(result.assets.owner == null);
    try std.testing.expect(result.assets.downloads.owner == &result.assets.downloads);
    operations.cleanup_fail = null;
    try result.retryCleanupWith(&operations);
    try std.testing.expect(result.isPristineForComposition());
}

test "production surface exposes authentication revalidation and retry cleanup only" {
    _ = &composition.authenticateUntil;
    _ = &composition.AuthenticatedPredecessor.revalidate;
    _ = &composition.AuthenticatedPredecessor.retryCleanup;
}

test "composition follows the closed order and publishes only after final revalidation" {
    var operations = Operations{};
    var deadline = Deadline{ .operations = &operations };
    var result: composition.AuthenticatedPredecessor = .{};
    try composition.authenticateUntilWith(&operations, &deadline, &result);
    try std.testing.expect(result.owner == &result);
    try std.testing.expectEqualSlices(Step, &.{ .preflight, .fence, .child, .assets, .fence, .identity, .binding, .fence, .revalidate, .deadline }, operations.steps[0..operations.len]);
}

test "every post-ownership failure cleans in reverse order and leaves no authority" {
    inline for (4..11) |fail_at| {
        var operations = Operations{ .fail_at = fail_at };
        var deadline = Deadline{ .operations = &operations };
        var result: composition.AuthenticatedPredecessor = .{};
        try std.testing.expectError(error.ChildFailed, composition.authenticateUntilWith(&operations, &deadline, &result));
        try std.testing.expect(result.isPristineForComposition());
        const expected: []const Step = switch (fail_at) {
            4 => &.{},
            5, 6 => &.{.cleanup_assets},
            7 => &.{ .cleanup_identity, .cleanup_assets },
            8, 9, 10 => &.{ .cleanup_binding, .cleanup_identity, .cleanup_assets },
            else => unreachable,
        };
        try std.testing.expectEqualSlices(Step, expected, operations.steps[operations.len - expected.len .. operations.len]);
    }
}

test "cleanup uncertainty preserves retry owner while independent children still clean" {
    var operations = Operations{ .fail_at = 10, .cleanup_fail = .cleanup_identity };
    var deadline = Deadline{ .operations = &operations };
    var result: composition.AuthenticatedPredecessor = .{};
    try std.testing.expectError(error.CleanupFailed, composition.authenticateUntilWith(&operations, &deadline, &result));
    try std.testing.expect(result.owner == &result);
    try std.testing.expect(result.identity.owner == &result.identity);
    try std.testing.expect(result.binding.owner == null);
    try std.testing.expect(result.assets.owner == null);
    try std.testing.expect(std.mem.indexOfScalar(Step, operations.steps[0..operations.len], .cleanup_assets) != null);
    operations.cleanup_fail = null;
    operations.fail_at = 0;
    try result.retryCleanup();
    try std.testing.expect(result.isPristineForComposition());
}

test "nested pre-owned residue is rejected before the first authority callback" {
    var operations = Operations{};
    var deadline = Deadline{ .operations = &operations };
    var result: composition.AuthenticatedPredecessor = .{};
    result.assets.source_commit[0] = 'a';
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&operations, &deadline, &result));
    try std.testing.expectEqualSlices(Step, &.{.preflight}, operations.steps[0..operations.len]);
}
