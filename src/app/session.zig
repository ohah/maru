const std = @import("std");
const terminal = @import("../terminal.zig");

pub const ProcessState = enum {
    starting,
    running,
    exited,
};

pub const TerminalSession = struct {
    id: u64,
    title: []const u8 = "shell",
    cwd: ?[]const u8 = null,
    process_state: ProcessState = .starting,
    core: terminal.TerminalCore,

    pub fn init(allocator: std.mem.Allocator, id: u64, size: terminal.Size) !TerminalSession {
        return .{
            .id = id,
            .core = try terminal.TerminalCore.init(allocator, size),
        };
    }

    pub fn deinit(self: *TerminalSession) void {
        self.core.deinit();
    }
};
