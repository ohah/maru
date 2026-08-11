//! wire-major 1 제품을 종료 프로토콜의 회귀 기준으로 동결한다.
//!
//! 배포된 사용자 설치본과의 호환성을 나타내지 않는다. manifest와 함께 보존한 실제 universal 실행 파일로
//! ambiguous 응답 뒤 destructive retry가 없는지만 검증한다. 기준을 바꿀 때는 이 파일과 실제 제품 transcript를
//! 한 transaction으로 교체한다.

pub const source_commit = "314b7912613c2e84cbf11e2cc8b0775e9e3f99fb";
pub const source_patch_sha256 = hexDigest("bb9a180c4e085859dc35c4ff264fc0b90c0692f98810c56b6cd5982d5b106fb4");
pub const artifact_sha256 = hexDigest("4004256667fee2b40d41c7fe678ef44c7b5385fd4ff25410c40a9198344ce64c");
pub const wire_major: u32 = 1;
pub const screen_codec_version: u16 = 1;
pub const gui_runtime_list = true;
pub const gui_runtime_terminate = true;
pub const cross_connection_admin_barrier = false;
pub const list_semantics_sha256 = hexDigest("4812c7ec3c0e58b9fcec61a1ee7064dc85e667de4bd216d10150324e1fea964a");
pub const terminate_semantics_sha256 = hexDigest("266581757fd62858e9ea1d66eeb5a5ccec9945e222c7ca55c7c48c58ae16971b");

fn hexDigest(comptime source: *const [64:0]u8) [32]u8 {
    var result: [32]u8 = undefined;
    for (&result, 0..) |*byte, index| {
        byte.* = (hexNibble(source[index * 2]) << 4) | hexNibble(source[index * 2 + 1]);
    }
    return result;
}

fn hexNibble(value: u8) u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        else => @compileError("N-1 manifest digest는 소문자 16진수여야 한다"),
    };
}

test "C3-3b6 N-1 기준 manifest는 wire와 capability를 닫힌 값으로 고정한다" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), wire_major);
    try std.testing.expectEqual(@as(u16, 1), screen_codec_version);
    try std.testing.expect(gui_runtime_list and gui_runtime_terminate);
    try std.testing.expect(!cross_connection_admin_barrier);
    try std.testing.expect(!std.mem.eql(u8, &source_patch_sha256, &([_]u8{0} ** 32)));
    try std.testing.expect(!std.mem.eql(u8, &artifact_sha256, &([_]u8{0} ** 32)));
}
