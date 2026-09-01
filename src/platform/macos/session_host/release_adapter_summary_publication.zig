//! Atomic filesystem publication for canonical release validation summaries.
//!
//! Callers provide only the authenticated phase owner and an absent output pathname. Summary
//! bytes and their success/phase/digest fields never cross this API as caller-owned authority.

const std = @import("std");
const summary = @import("release_adapter_summary");
const files = @import("release_adapter_files");
const current_observation = @import("release_adapter_github_current_observation");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

pub const Error = summary.Error || files.Error;

const FilesystemPublisher = struct {
    fn publish(_: *@This(), path: [:0]const u8, bytes: []const u8) files.Error!void {
        try files.publishSummaryExclusive(path, bytes);
    }
};

pub fn publishPrePublish(
    allocator: std.mem.Allocator,
    current: *const current_observation.CurrentObservation,
    output_path: [:0]const u8,
) Error!void {
    const bytes = try summary.encodePrePublish(allocator, current);
    defer allocator.free(bytes);
    var publisher = FilesystemPublisher{};
    try publisher.publish(output_path, bytes);
}

pub fn publishPrePublishWith(
    publisher: anytype,
    allocator: std.mem.Allocator,
    current: anytype,
    output_path: [:0]const u8,
) !void {
    const bytes = try summary.encodePrePublishWith(allocator, current);
    defer allocator.free(bytes);
    try publisher.publish(output_path, bytes);
}

pub fn publishPredecessor(
    allocator: std.mem.Allocator,
    authenticated: *const authenticated_manifest.AuthenticatedManifest,
    assets: *predecessor_assets.AuthenticatedPredecessorAssets,
    output_path: [:0]const u8,
) Error!void {
    const bytes = try summary.encodePredecessor(allocator, authenticated, assets);
    defer allocator.free(bytes);
    var publisher = FilesystemPublisher{};
    try publisher.publish(output_path, bytes);
}

pub fn publishPredecessorWith(
    publisher: anytype,
    allocator: std.mem.Allocator,
    authenticated: anytype,
    assets: anytype,
    output_path: [:0]const u8,
) !void {
    const bytes = try summary.encodePredecessorWith(allocator, authenticated, assets);
    defer allocator.free(bytes);
    try publisher.publish(output_path, bytes);
}
