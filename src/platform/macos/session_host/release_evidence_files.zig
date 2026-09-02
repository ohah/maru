//! Actual filesystem assembly for canonical session-host release evidence.
//!
//! Leaf pathnames are staging inputs, never authority. Each leaf is read once through the stable
//! no-follow file adapter, distinct opened identities are required, and publication happens only
//! after the canonical aggregate is parsed and rebound to the caller's typed release identity.

const std = @import("std");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");

pub const Error = evidence.Error || files.Error;
pub const PublishedEvidence = files.PinnedReleaseFile;

pub const BaselineRequest = struct {
    common: evidence.Common,
    default_false_path: [:0]const u8,
    signed_app_quit_path: [:0]const u8,
    output_path: [:0]const u8,
};

pub const UpgradeRequest = struct {
    common: evidence.Common,
    predecessor: evidence.Predecessor,
    designated_requirement_sha256: []const u8,
    one_path: [:0]const u8,
    near_max_path: [:0]const u8,
    output_path: [:0]const u8,
};

pub fn publishBaseline(allocator: std.mem.Allocator, request: BaselineRequest) Error!void {
    var published: PublishedEvidence = .{};
    try publishBaselineOwned(allocator, request, &published);
    try published.deinit();
}

pub fn publishBaselineOwned(allocator: std.mem.Allocator, request: BaselineRequest, result: *PublishedEvidence) Error!void {
    var validator = NoopPublicationValidator{};
    try publishBaselineOwnedValidated(allocator, request, &validator, result);
}

/// The validator runs after canonical assembly and binding, immediately before the output path is
/// opened. Publication itself does not allocate, so an orchestration owner can close allocator
/// reentrancy without moving filesystem ownership out of this module.
pub fn publishBaselineOwnedValidated(allocator: std.mem.Allocator, request: BaselineRequest, validator: anytype, result: *PublishedEvidence) !void {
    try validateResult(result, request.common, &.{ request.default_false_path, request.signed_app_quit_path, request.output_path });
    var default_false = try files.readInputAlloc(allocator, request.default_false_path, evidence.max_evidence_bytes);
    defer default_false.deinit(allocator);
    var signed_app_quit = try files.readInputAlloc(allocator, request.signed_app_quit_path, evidence.max_evidence_bytes);
    defer signed_app_quit.deinit(allocator);
    try files.requireDistinct(&.{ default_false.identity, signed_app_quit.identity });

    const aggregate = try evidence.assembleBaseline(
        allocator,
        request.common,
        default_false.bytes,
        signed_app_quit.bytes,
    );
    defer allocator.free(aggregate);
    var parsed = try evidence.parseCanonical(allocator, aggregate);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .baseline_a = request.common });
    try validator.validate();
    try files.publishSummaryOwnedExclusive(result, request.output_path, aggregate);
}

pub fn publishUpgrade(allocator: std.mem.Allocator, request: UpgradeRequest) Error!void {
    var published: PublishedEvidence = .{};
    try publishUpgradeOwned(allocator, request, &published);
    try published.deinit();
}

pub fn publishUpgradeOwned(allocator: std.mem.Allocator, request: UpgradeRequest, result: *PublishedEvidence) Error!void {
    var validator = NoopPublicationValidator{};
    try publishUpgradeOwnedValidated(allocator, request, &validator, result);
}

pub fn publishUpgradeOwnedValidated(allocator: std.mem.Allocator, request: UpgradeRequest, validator: anytype, result: *PublishedEvidence) !void {
    try validateResult(result, request.common, &.{
        request.predecessor.tag,
        request.predecessor.commit,
        request.predecessor.manifest_sha256,
        request.predecessor.dmg_sha256,
        request.predecessor.executable_sha256,
        request.designated_requirement_sha256,
        request.one_path,
        request.near_max_path,
        request.output_path,
    });
    var one = try files.readInputAlloc(allocator, request.one_path, evidence.max_evidence_bytes);
    defer one.deinit(allocator);
    var near_max = try files.readInputAlloc(allocator, request.near_max_path, evidence.max_evidence_bytes);
    defer near_max.deinit(allocator);
    try files.requireDistinct(&.{ one.identity, near_max.identity });

    const aggregate = try evidence.assembleUpgrade(
        allocator,
        request.common,
        request.predecessor,
        one.bytes,
        near_max.bytes,
    );
    defer allocator.free(aggregate);
    var parsed = try evidence.parseCanonical(allocator, aggregate);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .upgrade_b = .{
        .common = request.common,
        .predecessor = request.predecessor,
        .designated_requirement_sha256 = request.designated_requirement_sha256,
    } });
    try validator.validate();
    try files.publishSummaryOwnedExclusive(result, request.output_path, aggregate);
}

fn validateResult(result: *const PublishedEvidence, common: evidence.Common, extra: []const []const u8) Error!void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    const common_values = [_][]const u8{
        common.test_uuid,
        common.repository.owner,
        common.repository.name,
        common.release.tag,
        common.release.version,
        common.source.commit,
        common.source.tree,
        common.build.workflow_ref,
        common.candidate.dmg_sha256,
        common.candidate.executable_sha256,
    };
    for (common_values) |value| if (overlaps(result_bytes, value)) return error.InvalidOwner;
    for (extra) |value| if (overlaps(result_bytes, value)) return error.InvalidOwner;
}

const NoopPublicationValidator = struct {
    fn validate(_: *@This()) Error!void {}
};

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
