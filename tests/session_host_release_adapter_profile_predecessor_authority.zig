//! Authenticated pre-publish predecessor authority composition contract.

const std = @import("std");
const assets = @import("release_adapter_github_predecessor_assets");
const identity = @import("release_adapter_predecessor_evidence_identity");
const binding = @import("release_adapter_profile_predecessor_binding");
const composition = @import("release_adapter_profile_predecessor_authority");

test "authority is a nominal final-address owner of the complete predecessor graph" {
    var result: composition.AuthenticatedPredecessor = .{};
    try std.testing.expect(@TypeOf(result.assets) == assets.AuthenticatedPredecessorAssets);
    try std.testing.expect(@TypeOf(result.identity) == identity.PredecessorEvidenceIdentity);
    try std.testing.expect(@TypeOf(result.binding) == binding.BoundPredecessor);
    try std.testing.expect(result.value() == null);
    try std.testing.expect(result.isPristineForComposition());
}

test "production surface exposes authentication revalidation and retry cleanup only" {
    _ = &composition.authenticateUntil;
    _ = &composition.AuthenticatedPredecessor.revalidate;
    _ = &composition.AuthenticatedPredecessor.retryCleanup;
}
