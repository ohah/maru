const terminal = @import("../terminal.zig");

pub const Backend = enum {
    macos_openpty,
    windows_conpty,
    remote_websocket,
};

pub const ExitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    unknown: i32,
};

// PtyEvent는 PTY backend가 SurfaceRuntime으로 올리는 최소 domain event다.
// escape parsing은 TerminalCore 책임이므로 output은 해석하지 않은 bytes로 유지한다.
pub const PtyEvent = union(enum) {
    output: []u8,
    exited: ExitStatus,

    pub fn deinit(self: PtyEvent, allocator: @import("std").mem.Allocator) void {
        switch (self) {
            .output => |bytes| allocator.free(bytes),
            .exited => {},
        }
    }
};

pub const PtyHandle = struct {
    backend: Backend,
    size: terminal.Size,
};

pub const SpawnRequest = struct {
    // command는 shell을 거치지 않고 execve에 직접 넘길 실행 파일 경로다.
    // 이렇게 두면 테스트에서 shell quoting과 process spawning 책임을 분리할 수 있다.
    command: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    size: terminal.Size = terminal.Size.default,
};

pub fn plannedBackendForMacOS() Backend {
    return .macos_openpty;
}

test "macOS backend is openpty" {
    try @import("std").testing.expectEqual(Backend.macos_openpty, plannedBackendForMacOS());
}
