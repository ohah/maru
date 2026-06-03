const std = @import("std");
const terminal = @import("terminal.zig");

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

    pub fn init(id: u64, size: terminal.Size) TerminalSession {
        return .{
            .id = id,
            .core = terminal.TerminalCore.init(size),
        };
    }
};

pub const AppWindow = struct {
    tabs: []TerminalSession,
    active_tab: usize = 0,

    pub fn active(self: *AppWindow) ?*TerminalSession {
        if (self.tabs.len == 0) return null;
        if (self.active_tab >= self.tabs.len) return null;
        return &self.tabs[self.active_tab];
    }

    pub fn selectTab(self: *AppWindow, index: usize) bool {
        if (index >= self.tabs.len) return false;
        self.active_tab = index;
        return true;
    }
};

test "window selects active tab" {
    var tabs = [_]TerminalSession{
        TerminalSession.init(1, terminal.Size.default),
        TerminalSession.init(2, .{ .cols = 120, .rows = 40 }),
    };
    var window: AppWindow = .{ .tabs = &tabs };

    try std.testing.expectEqual(@as(u64, 1), window.active().?.id);
    try std.testing.expect(window.selectTab(1));
    try std.testing.expectEqual(@as(u64, 2), window.active().?.id);
    try std.testing.expect(!window.selectTab(3));
}
