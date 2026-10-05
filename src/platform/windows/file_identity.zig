//! Handle-bound identity for save preconditions and conditional rollback.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const abi = @import("abi.zig");
extern "kernel32" fn GetFileInformationByHandleEx(w.HANDLE, u32, *anyopaque, u32) callconv(abi.winapi) w.BOOL;
pub const Error = error{ UnsupportedPlatform, IdentityQueryFailed };

// FILE_ID_INFO combines a volume serial with the entire 128-bit identifier.
// Truncating to the legacy 64-bit index can mistake another object for our file.
// https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info
pub const Identity = extern struct {
    volume: u64,
    file: [16]u8,

    pub fn capture(handle: w.HANDLE) Error!Identity {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var value: Identity = undefined;
        if (!GetFileInformationByHandleEx(handle, 18, &value, @sizeOf(Identity)).toBool()) return error.IdentityQueryFailed;
        return value;
    }

    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume == b.volume and std.mem.eql(u8, &a.file, &b.file);
    }
};

test "Windows safe save identity compares every identifier byte and the volume" {
    const original: Identity = .{ .volume = 0x123456789abcdef0, .file = .{0} ** 16 };
    try std.testing.expect(original.eql(original));
    for (0..16) |i| {
        var other = original;
        other.file[i] = 1;
        try std.testing.expect(!original.eql(other));
    }
    var other = original;
    other.volume ^= @as(u64, 1) << 63;
    try std.testing.expect(!original.eql(other));
}

test "Windows safe save identity follows the object after rename and rejects a reused name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    const original = try tmp.dir.openFile(io, "original.txt", .{});
    defer original.close(io);
    const before = try Identity.capture(original.handle);
    try tmp.dir.rename("original.txt", tmp.dir, "moved.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "competitor" });
    const moved = try tmp.dir.openFile(io, "moved.txt", .{});
    defer moved.close(io);
    const competitor = try tmp.dir.openFile(io, "original.txt", .{});
    defer competitor.close(io);
    try std.testing.expect(before.eql(try Identity.capture(original.handle)));
    try std.testing.expect(before.eql(try Identity.capture(moved.handle)));
    try std.testing.expect(!before.eql(try Identity.capture(competitor.handle)));
}

test "Windows safe save identity refuses an invalid native handle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.IdentityQueryFailed, Identity.capture(w.INVALID_HANDLE_VALUE));
}
