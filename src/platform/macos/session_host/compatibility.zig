//! Current/N-1 adapter 지원표의 단일 출처.
//!
//! MRSH major, exact screen codec, frozen-release fingerprint를 Client와 HostAdapter가 각자 추론하면 다음 major bump에서
//! 한쪽만 갱신될 수 있다. 지원 범위를 이 작은 표로 고정하고, 표에 없는 조합은 handshake 전에 fail-close한다.

const std = @import("std");
const protocol = @import("protocol.zig");
const screen_stream = @import("maru").session.screen_stream;
const shutdown_n1_baseline = @import("shutdown_n1_baseline.zig");
const metadata_n1_baseline = @import("metadata_n1_baseline.zig");

pub const ShutdownProfile = struct {
    artifact_sha256: [32]u8 = [_]u8{0} ** 32,
    wire_major: u32 = 0,
    gui_runtime_list: bool = false,
    gui_runtime_terminate: bool = false,
    cross_connection_admin_barrier: bool = false,

    pub fn complete(self: ShutdownProfile) bool {
        return !std.mem.eql(u8, &self.artifact_sha256, &([_]u8{0} ** 32)) and
            self.wire_major != 0 and
            self.gui_runtime_list and
            self.gui_runtime_terminate and
            !self.cross_connection_admin_barrier;
    }
};

pub const Kind = enum {
    current,
    previous,
};

pub const AttachSchema = enum {
    frozen_controller_only,
    granted_roles,
};

pub const Profile = struct {
    kind: Kind,
    wire_major: u16,
    screen_codec_version: u16,
    required_fingerprint: ?[]const u8,
    attach_schema: AttachSchema,
    shutdown_profile: ?ShutdownProfile,
};

// 공개된 release row는 산술로 추론하지 않는다. 다음 major/codec bump는 먼저 이 표와 frozen fixture를 갱신해야
// compile된다. 특히 v3에서 "v2인데 v1 fingerprint" 같은 조용한 오접속을 막는 gate다.
pub const profiles = [_]Profile{
    .{
        .kind = .current,
        .wire_major = 2,
        .screen_codec_version = 2,
        .required_fingerprint = null,
        .attach_schema = .granted_roles,
        .shutdown_profile = null,
    },
    .{
        .kind = .previous,
        .wire_major = 1,
        .screen_codec_version = 1,
        .required_fingerprint = "screen_stream_v1_current_body",
        // The frozen image is v1 only at the protocol/screen identity. Its actual attach reply
        // already uses granted roles + controller_generation; source_commit and executable E2E
        // are the oracle, not an inferred pre-history schema.
        .attach_schema = .granted_roles,
        .shutdown_profile = .{
            .artifact_sha256 = shutdown_n1_baseline.artifact_sha256,
            .wire_major = shutdown_n1_baseline.wire_major,
            .gui_runtime_list = shutdown_n1_baseline.gui_runtime_list,
            .gui_runtime_terminate = shutdown_n1_baseline.gui_runtime_terminate,
            .cross_connection_admin_barrier = shutdown_n1_baseline.cross_connection_admin_barrier,
        },
    },
};

comptime {
    if (protocol.version_major != 2 or screen_stream.codec_version != 2)
        @compileError("update the explicit current/N-1 compatibility table and frozen fixtures before bumping protocol/screen");
}

pub fn profileForMajor(wire_major: u16) ?Profile {
    for (profiles) |profile| {
        if (profile.wire_major == wire_major) return profile;
    }
    return null;
}

/// GUI restore may bypass a historical missing screen fingerprint only for this exact frozen
/// capability-less artifact. Shutdown has a separate baseline because its maintenance-only trust
/// boundary and source history are not interchangeable with screen attach.
pub fn frozenGuiArtifactForMajor(wire_major: u16) ?[32]u8 {
    const profile = profileForMajor(wire_major) orelse return null;
    if (profile.kind != .previous or wire_major != metadata_n1_baseline.wire_major or
        profile.screen_codec_version != metadata_n1_baseline.screen_codec_version or
        metadata_n1_baseline.runtime_metadata_v1)
        return null;
    return metadata_n1_baseline.artifact_sha256;
}

pub fn artifactBuildIdMatches(build_id: []const u8, digest: [32]u8) bool {
    if (build_id.len != "sha256:".len + 64 or !std.mem.startsWith(u8, build_id, "sha256:"))
        return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, build_id["sha256:".len..], &expected);
}

test "P3-e4d-2b artifact build ID attestation is exact" {
    const digest = [_]u8{0xAB} ** 32;
    try std.testing.expect(artifactBuildIdMatches(
        "sha256:abababababababababababababababababababababababababababababababab",
        digest,
    ));
    try std.testing.expect(!artifactBuildIdMatches(
        "sha256:abababababababababababababababababababababababababababababababac",
        digest,
    ));
    try std.testing.expect(!artifactBuildIdMatches(
        "SHA256:abababababababababababababababababababababababababababababababab",
        digest,
    ));
    try std.testing.expect(!artifactBuildIdMatches("sha256:ab", digest));
}

test "compatibility table has one exact current and one fingerprinted N-1 profile" {
    const current = profileForMajor(protocol.version_major).?;
    try std.testing.expectEqual(Kind.current, current.kind);
    try std.testing.expectEqual(screen_stream.codec_version, current.screen_codec_version);
    try std.testing.expectEqual(AttachSchema.granted_roles, current.attach_schema);
    try std.testing.expect(current.required_fingerprint == null);
    try std.testing.expect(current.shutdown_profile == null);
    const previous = profileForMajor(1).?;
    try std.testing.expectEqual(Kind.previous, previous.kind);
    try std.testing.expectEqual(@as(u16, 1), previous.screen_codec_version);
    try std.testing.expectEqualStrings("screen_stream_v1_current_body", previous.required_fingerprint.?);
    try std.testing.expectEqual(AttachSchema.granted_roles, previous.attach_schema);
    const shutdown = previous.shutdown_profile.?;
    try std.testing.expect(shutdown.complete());
    try std.testing.expectEqual(@as(u32, 1), shutdown.wire_major);
    try std.testing.expectEqualSlices(u8, &shutdown_n1_baseline.artifact_sha256, &shutdown.artifact_sha256);
    try std.testing.expectEqualSlices(
        u8,
        &metadata_n1_baseline.artifact_sha256,
        &frozenGuiArtifactForMajor(1).?,
    );
    try std.testing.expect(profileForMajor(0) == null);
}
