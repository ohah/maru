const std = @import("std");
const terminal = @import("../terminal.zig");

pub const ProcessState = enum {
    starting,
    running,
    exited,
};

// `Surface`는 [Facade 계약](../../docs/facade-contracts.md)의 단일 출처 이름을 따른다.
// 하나의 사용 가능한 terminal surface(TerminalCore + metadata)를 나타낸다.
// live PtySession handle은 여기 저장하지 않는다. 장차 SurfaceRuntime이
// Surface와 PtySession을 연결하면, workspace restore는 live process handle 없이
// 복구 가능한 metadata만 저장할 수 있다.
// 이 타입은 자신이 tab인지 split인지 window인지 모른다. 그 결정은 상위 app/platform layer가 한다.
pub const Surface = struct {
    id: u64,
    title: []const u8 = "shell",
    cwd: ?[]const u8 = null,
    process_state: ProcessState = .starting,
    core: terminal.TerminalCore,

    pub fn init(allocator: std.mem.Allocator, id: u64, size: terminal.Size) !Surface {
        return .{
            .id = id,
            .core = try terminal.TerminalCore.init(allocator, size),
        };
    }

    pub fn deinit(self: *Surface) void {
        self.core.deinit();
    }
};
