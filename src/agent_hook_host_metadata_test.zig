//! Host-owned format must survive transport and handoff without a namespace downgrade.
test {
    _ = @import("platform/macos/session_host/remote_runtime.zig");
    _ = @import("platform/macos/session_host/client.zig");
    _ = @import("platform/macos/session_host/host_adapter.zig");
    _ = @import("platform/macos/session_host/handoff_codec.zig");
    _ = @import("platform/macos/session_host/runtime_metadata_wire.zig");
    _ = @import("platform/macos/session_host/server.zig");
    _ = @import("platform/macos/session_host/runtime_manager.zig");
}

test "agent log format provisioning authenticates handles and never follows symlinks" {
    const std = @import("std");
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const api = @import("maru").agent_log_record;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/parent/instance", .{root});
    defer std.testing.allocator.free(path);
    const dir = try api.createPrivateDirectory(io, path);
    defer dir.close(io);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(dir.handle, 0o755));
    try std.testing.expectError(error.UnsafeDirectory, api.openPrivateDirectory(io, path));
    const narrowed = try api.createPrivateDirectory(io, path);
    narrowed.close(io);
    const authenticated = try api.openPrivateDirectory(io, path);
    authenticated.close(io);
    try tmp.dir.createDir(io, "unrelated", .fromMode(0o700));
    const unrelated = try tmp.dir.openDir(io, "unrelated", .{ .iterate = true });
    defer unrelated.close(io);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(unrelated.handle, 0o755));
    try tmp.dir.symLink(io, "unrelated", "alias", .{ .is_directory = true });
    const alias = try std.fmt.allocPrint(std.testing.allocator, "{s}/alias/instance", .{root});
    defer std.testing.allocator.free(alias);
    if (api.createPrivateDirectory(io, alias)) |unsafe| {
        unsafe.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, unrelated.openDir(io, "instance", .{}));
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/unrelated", .{root});
    defer std.testing.allocator.free(target);
    try std.testing.expectError(error.UnsafeDirectory, api.openPrivateDirectory(io, target));
}
