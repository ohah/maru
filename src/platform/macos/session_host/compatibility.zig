//! Current/N-1 adapter 지원표의 단일 출처.
//!
//! MRSH major, exact screen codec, frozen-release fingerprint를 Client와 HostAdapter가 각자 추론하면 다음 major bump에서
//! 한쪽만 갱신될 수 있다. 지원 범위를 이 작은 표로 고정하고, 표에 없는 조합은 handshake 전에 fail-close한다.

const protocol = @import("protocol.zig");
const screen_stream = @import("screen_stream.zig");

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
    },
    .{
        .kind = .previous,
        .wire_major = 1,
        .screen_codec_version = 1,
        .required_fingerprint = "screen_stream_v1_current_body",
        .attach_schema = .frozen_controller_only,
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

test "compatibility table has one exact current and one fingerprinted N-1 profile" {
    const std = @import("std");
    const current = profileForMajor(protocol.version_major).?;
    try std.testing.expectEqual(Kind.current, current.kind);
    try std.testing.expectEqual(screen_stream.codec_version, current.screen_codec_version);
    try std.testing.expectEqual(AttachSchema.granted_roles, current.attach_schema);
    try std.testing.expect(current.required_fingerprint == null);
    const previous = profileForMajor(1).?;
    try std.testing.expectEqual(Kind.previous, previous.kind);
    try std.testing.expectEqual(@as(u16, 1), previous.screen_codec_version);
    try std.testing.expectEqualStrings("screen_stream_v1_current_body", previous.required_fingerprint.?);
    try std.testing.expectEqual(AttachSchema.frozen_controller_only, previous.attach_schema);
    try std.testing.expect(profileForMajor(0) == null);
}
