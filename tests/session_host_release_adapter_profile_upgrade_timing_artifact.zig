//! Credential-free canonical timing artifact publication contract.

const std = @import("std");
const artifact = @import("release_adapter_profile_upgrade_timing_artifact");

test "artifact is a final-address owner with explicit audit state" {
    var value: artifact.Artifact = .{};
    try std.testing.expect(value.isPristineForComposition());
    try std.testing.expect(value.value() == null);
    try std.testing.expect(@hasDecl(artifact.Artifact, "revalidate"));
    try std.testing.expect(@hasDecl(artifact.Artifact, "cleanup"));
}

test "production surface accepts typed context execution and output only" {
    _ = &artifact.publish;
    try std.testing.expect(!@hasDecl(artifact, "publishDurations"));
    try std.testing.expect(!@hasDecl(artifact, "publishSuccess"));
    try std.testing.expect(!@hasDecl(artifact, "publishProfile"));
}

test "canonical projection rejects invalid timing sums and overflow" {
    const valid: artifact.TimingView = .{
        .predecessor_auth_ns = 10,
        .signed_one_ns = 20,
        .signed_near_max_ns = 30,
        .runner_phase_ns = 60,
        .profile_phase_ns = 80,
    };
    try artifact.validateTiming(valid);
    var invalid = valid;
    invalid.runner_phase_ns = 49;
    try std.testing.expectError(error.InvalidTiming, artifact.validateTiming(invalid));
    invalid = valid;
    invalid.signed_one_ns = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidTiming, artifact.validateTiming(invalid));
}

test "canonical schema and profile are closed constants" {
    try std.testing.expectEqualStrings("maru.session-host-profile-upgrade-timing.v1", artifact.schema);
    try std.testing.expectEqualStrings("upgrade_b", artifact.profile);
}

test "test seam exists for deterministic publication and post-owner fence failures" {
    _ = &artifact.publishWith;
    _ = &artifact.reopen;
}
