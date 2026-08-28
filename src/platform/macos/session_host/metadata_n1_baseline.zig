//! P3-e4d-2b capability-less N-1 GUI restore artifact identity.
//!
//! Shutdown ambiguity keeps its older independent fixture. This baseline is rebuilt from the
//! recorded source commit and patch only when the GUI attach compatibility row intentionally moves.

pub const source_commit = "314b7912613c2e84cbf11e2cc8b0775e9e3f99fb";
pub const source_patch_sha256 = hexDigest("fd313ecc0ae8377fc635b24ce0365fda9e21975b23a5737cb4d4e95d8a0b6735");
pub const artifact_sha256 = hexDigest("cf438580121adcd76c08ae5969880583e3afc88ef302f15664ba78cb8d480303");
pub const manifest_sha256 = hexDigest("a53f26a4656ff2150c92db36647307ab3c4c74d087366d4d57fb8add54b15a1a");
pub const wire_major: u16 = 1;
pub const screen_codec_version: u16 = 1;
pub const runtime_metadata_v1 = false;

fn hexDigest(comptime source: *const [64:0]u8) [32]u8 {
    var result: [32]u8 = undefined;
    for (&result, 0..) |*byte, index|
        byte.* = (hexNibble(source[index * 2]) << 4) | hexNibble(source[index * 2 + 1]);
    return result;
}

fn hexNibble(value: u8) u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        else => @compileError("metadata N-1 manifest digest must be lowercase hexadecimal"),
    };
}

test "P3-e4d-2b metadata N-1 baseline is capability-less and nonzero" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 1), wire_major);
    try std.testing.expectEqual(@as(u16, 1), screen_codec_version);
    try std.testing.expect(!runtime_metadata_v1);
    try std.testing.expect(!std.mem.eql(u8, &artifact_sha256, &([_]u8{0} ** 32)));
    try std.testing.expect(!std.mem.eql(u8, &source_patch_sha256, &([_]u8{0} ** 32)));
    try std.testing.expect(!std.mem.eql(u8, &manifest_sha256, &([_]u8{0} ** 32)));
}
