//! Private fork/exec failure record. EOF means no reported setup error, not shell readiness.
const std = @import("std");
pub const frame_size = 12;
pub const Stage = enum(u8) { session = 1, terminal = 2, stdin = 3, stdout = 4, stderr = 5, exec = 6 };
pub const Failure = struct { stage: Stage, native_errno: u32 };

/// Fixed bytes avoid native struct padding and allocation in the forked child.
pub fn encode(failure: Failure) [frame_size]u8 {
    var bytes: [frame_size]u8 = .{ 'M', 'P', 'S', 'E', 1, @backingInt(failure.stage), 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, bytes[8..12], failure.native_errno, .big);
    return bytes;
}
pub fn decode(bytes: []const u8) error{InvalidChildSetupStatus}!Failure {
    if (bytes.len != frame_size) return error.InvalidChildSetupStatus;
    if (!std.mem.eql(u8, bytes[0..4], "MPSE") or bytes[4] != 1 or bytes[6] != 0 or bytes[7] != 0)
        return error.InvalidChildSetupStatus;
    const stage = std.enums.fromInt(Stage, bytes[5]) orelse return error.InvalidChildSetupStatus;
    const native_errno = std.mem.readInt(u32, bytes[8..12], .big);
    if (native_errno == 0 or native_errno > std.math.maxInt(i32)) return error.InvalidChildSetupStatus;
    return .{ .stage = stage, .native_errno = native_errno };
}
