//! Extra native source identity for process-local archive snapshots.
//! Primitive values cross the worker boundary; native handle queries stay in the adapter.
const std = @import("std");
const builtin = @import("builtin");
const windows_identity = @import("../platform/windows/file_identity.zig");

pub const Identity = struct {
    volume: u64,
    file: [16]u8,
    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume == b.volume and std.mem.eql(u8, &a.file, &b.file);
    }
};

pub fn capture(file: std.Io.File) !?Identity {
    if (comptime builtin.os.tag != .windows) return null;
    const value = try windows_identity.Identity.capture(file.handle);
    return .{ .volume = value.volume, .file = value.file };
}

pub fn same(a: ?Identity, b: ?Identity) bool {
    if (a) |left| return if (b) |right| left.eql(right) else false;
    return b == null;
}

test "agent_session_archive_backend native identity preserves volume every byte and missing verdict" {
    const a: Identity = .{ .volume = 9, .file = .{0} ** 16 };
    try std.testing.expect(same(a, a));
    try std.testing.expect(same(null, null));
    try std.testing.expect(!same(a, null));
    try std.testing.expect(!same(null, a));
    for (0..16) |i| {
        var b = a;
        b.file[i] = 1;
        try std.testing.expect(!same(a, b));
    }
    var b = a;
    b.volume += 1;
    try std.testing.expect(!same(a, b));
}

test "agent_session_archive_backend native query failure has no missing identity fallback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bad: std.Io.File = .{ .handle = std.os.windows.INVALID_HANDLE_VALUE, .flags = .{ .nonblocking = false } };
    try std.testing.expectError(error.IdentityQueryFailed, capture(bad));
}
