const terminal = @import("../terminal.zig");

pub const Backend = enum {
    macos_forkpty,
    windows_conpty,
    remote_websocket,
};

pub const PtyHandle = struct {
    backend: Backend,
    size: terminal.Size,
};

pub const SpawnRequest = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    size: terminal.Size = terminal.Size.default,
};

pub fn plannedBackendForMacOS() Backend {
    return .macos_forkpty;
}

test "macOS backend is forkpty" {
    try @import("std").testing.expectEqual(Backend.macos_forkpty, plannedBackendForMacOS());
}
