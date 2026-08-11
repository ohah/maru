//! 지원하는 N-1 host의 종료 capability를 성공 응답 추측이 아닌 frozen profile로 판정한다.

const std = @import("std");
const contract = @import("shutdown_contract.zig");
const compatibility = @import("session_host_compatibility");

pub const RuntimeManifestIdentity = struct {
    artifact_sha256: contract.Digest,
    wire_major: u32,
    endpoint_digest: contract.Digest,
};

pub const FrozenShutdownTranscript = struct {
    artifact_sha256: contract.Digest,
    wire_major: u32,
    list_semantics_digest: contract.Digest,
    terminate_semantics_digest: contract.Digest,
};

pub const ValidatedShutdownProfile = struct {
    profile: contract.ShutdownProfile,
    endpoint_digest: contract.Digest,
    transcript_digest: contract.Digest,
};

pub const ValidationError = error{
    ArtifactMismatch,
    MajorMismatch,
    EndpointMismatch,
    MissingCapability,
    FalseBarrierElevation,
    TranscriptMismatch,
};

pub fn validate(
    profile: contract.ShutdownProfile,
    manifest: RuntimeManifestIdentity,
    transcript: FrozenShutdownTranscript,
    expected_endpoint_digest: contract.Digest,
    expected_transcript_digest: contract.Digest,
) ValidationError!ValidatedShutdownProfile {
    if (profile.cross_connection_admin_barrier) return error.FalseBarrierElevation;
    if (!profile.complete()) return error.MissingCapability;
    if (!std.mem.eql(u8, &profile.artifact_sha256, &manifest.artifact_sha256) or
        !std.mem.eql(u8, &profile.artifact_sha256, &transcript.artifact_sha256)) return error.ArtifactMismatch;
    if (profile.wire_major != manifest.wire_major or profile.wire_major != transcript.wire_major)
        return error.MajorMismatch;
    if (!std.mem.eql(u8, &manifest.endpoint_digest, &expected_endpoint_digest)) return error.EndpointMismatch;
    if (!profile.gui_runtime_list or !profile.gui_runtime_terminate) return error.MissingCapability;
    const actual_transcript = shutdownTranscriptDigest(transcript);
    if (!std.mem.eql(u8, &actual_transcript, &expected_transcript_digest)) return error.TranscriptMismatch;
    return .{
        .profile = profile,
        .endpoint_digest = manifest.endpoint_digest,
        .transcript_digest = actual_transcript,
    };
}

pub const N1AmbiguousDecision = struct {
    outcome: contract.BoundedUnconfirmed,
    destructive_request_count: u8,
};

pub fn sentAmbiguous(attempt_key: contract.ShutdownAttemptKey, consumed_connection: contract.Digest) N1AmbiguousDecision {
    return .{
        .outcome = .{ .post_connection = .{
            .reason = .n1_sent_ambiguous,
            .attempt_key = attempt_key,
            .consumed_connection = consumed_connection,
        } },
        .destructive_request_count = 0,
    };
}

fn shutdownTranscriptDigest(transcript: FrozenShutdownTranscript) contract.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&transcript.artifact_sha256);
    var major: [4]u8 = undefined;
    std.mem.writeInt(u32, &major, transcript.wire_major, .little);
    hasher.update(&major);
    hasher.update(&transcript.list_semantics_digest);
    hasher.update(&transcript.terminate_semantics_digest);
    return hasher.finalResult();
}

fn fixture(byte: u8) struct {
    profile: contract.ShutdownProfile,
    manifest: RuntimeManifestIdentity,
    transcript: FrozenShutdownTranscript,
    endpoint: contract.Digest,
    transcript_digest: contract.Digest,
} {
    const artifact = [_]u8{byte} ** 32;
    const endpoint = [_]u8{byte +% 1} ** 32;
    const transcript: FrozenShutdownTranscript = .{
        .artifact_sha256 = artifact,
        .wire_major = 2,
        .list_semantics_digest = [_]u8{byte +% 2} ** 32,
        .terminate_semantics_digest = [_]u8{byte +% 3} ** 32,
    };
    return .{
        .profile = .{
            .artifact_sha256 = artifact,
            .wire_major = 2,
            .gui_runtime_list = true,
            .gui_runtime_terminate = true,
            .cross_connection_admin_barrier = false,
        },
        .manifest = .{ .artifact_sha256 = artifact, .wire_major = 2, .endpoint_digest = endpoint },
        .transcript = transcript,
        .endpoint = endpoint,
        .transcript_digest = shutdownTranscriptDigest(transcript),
    };
}

test "C3-3b6 N-1 profile은 frozen artifact digest를 exact match한다" {
    const row = fixture(1);
    _ = try validate(row.profile, row.manifest, row.transcript, row.endpoint, row.transcript_digest);
    var drift = row.manifest;
    drift.artifact_sha256[0] ^= 1;
    try std.testing.expectError(error.ArtifactMismatch, validate(row.profile, drift, row.transcript, row.endpoint, row.transcript_digest));
}

test "C3-3b6 N-1 profile은 wire major mismatch를 mutation 없이 거부한다" {
    const row = fixture(2);
    var drift = row.transcript;
    drift.wire_major += 1;
    try std.testing.expectError(error.MajorMismatch, validate(row.profile, row.manifest, drift, row.endpoint, row.transcript_digest));
}

test "C3-3b6 N-1 profile은 runtime manifest endpoint를 매 connection 재검증한다" {
    const row = fixture(3);
    var endpoint = row.endpoint;
    endpoint[31] ^= 1;
    try std.testing.expectError(error.EndpointMismatch, validate(row.profile, row.manifest, row.transcript, endpoint, row.transcript_digest));
}

test "C3-3b6 N-1 profile은 list와 terminate capability를 모두 요구한다" {
    const row = fixture(4);
    var profile = row.profile;
    profile.gui_runtime_list = false;
    try std.testing.expectError(error.MissingCapability, validate(profile, row.manifest, row.transcript, row.endpoint, row.transcript_digest));
    profile = row.profile;
    profile.gui_runtime_terminate = false;
    try std.testing.expectError(error.MissingCapability, validate(profile, row.manifest, row.transcript, row.endpoint, row.transcript_digest));
}

test "C3-3b6 N-1 profile은 transcript splice와 false barrier elevation을 거부한다" {
    const row = fixture(5);
    var transcript = row.transcript;
    transcript.terminate_semantics_digest[0] ^= 1;
    try std.testing.expectError(error.TranscriptMismatch, validate(row.profile, row.manifest, transcript, row.endpoint, row.transcript_digest));
    var profile = row.profile;
    profile.cross_connection_admin_barrier = true;
    try std.testing.expectError(error.FalseBarrierElevation, validate(profile, row.manifest, row.transcript, row.endpoint, row.transcript_digest));
}

test "C3-3b6 N-1 profile은 incompatible target을 request 없이 bounded로 닫는다" {
    // 보존한 기준 행이 있어도 exact artifact/capability가 다른 target에는 요청을 보내지 않는다.
    try std.testing.expect(compatibility.profileForMajor(1).?.shutdown_profile.?.complete());
    const row = fixture(6);
    var profile = row.profile;
    profile.gui_runtime_list = false;
    const request_count: u8 = 0;
    try std.testing.expectError(error.MissingCapability, validate(profile, row.manifest, row.transcript, row.endpoint, row.transcript_digest));
    try std.testing.expectEqual(@as(u8, 0), request_count);
}

test "C3-3b6 N-1 profile은 sent ambiguous를 destructive retry 없이 닫는다" {
    const decision = sentAmbiguous(.{
        .close_request_generation = 7,
        .target_digest = [_]u8{9} ** 32,
        .attempt_generation = 2,
    }, [_]u8{8} ** 32);
    try std.testing.expectEqual(@as(u8, 0), decision.destructive_request_count);
    try std.testing.expectEqual(contract.PostConnectionReason.n1_sent_ambiguous, decision.outcome.post_connection.reason);
}
