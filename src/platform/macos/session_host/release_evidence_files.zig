//! Actual filesystem assembly for canonical session-host release evidence.
//!
//! Leaf pathnames are staging inputs, never authority. Each leaf is read once through the stable
//! no-follow file adapter, distinct opened identities are required, and publication happens only
//! after the canonical aggregate is parsed and rebound to the caller's typed release identity.

const std = @import("std");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");

pub const Error = evidence.Error || files.Error;

pub const BaselineRequest = struct {
    common: evidence.Common,
    default_false_path: [:0]const u8,
    signed_app_quit_path: [:0]const u8,
    output_path: [:0]const u8,
};

pub const UpgradeRequest = struct {
    common: evidence.Common,
    predecessor: evidence.Predecessor,
    one_path: [:0]const u8,
    near_max_path: [:0]const u8,
    output_path: [:0]const u8,
};

pub fn publishBaseline(allocator: std.mem.Allocator, request: BaselineRequest) Error!void {
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
    try files.publishSummaryExclusive(request.output_path, aggregate);
}

pub fn publishUpgrade(allocator: std.mem.Allocator, request: UpgradeRequest) Error!void {
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
    } });
    try files.publishSummaryExclusive(request.output_path, aggregate);
}
