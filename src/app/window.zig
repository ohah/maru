const std = @import("std");
const session = @import("session.zig");
const terminal = @import("../terminal.zig");

pub const AppWindow = struct {
    tabs: []session.TerminalSession,
    active_tab: usize = 0,

    pub fn active(self: *AppWindow) ?*session.TerminalSession {
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
    var tabs = [_]session.TerminalSession{
        try session.TerminalSession.init(std.testing.allocator, 1, terminal.Size.default),
        try session.TerminalSession.init(std.testing.allocator, 2, .{ .cols = 120, .rows = 40 }),
    };
    defer tabs[0].deinit();
    defer tabs[1].deinit();

    var window: AppWindow = .{ .tabs = &tabs };

    try std.testing.expectEqual(@as(u64, 1), window.active().?.id);
    try std.testing.expect(window.selectTab(1));
    try std.testing.expectEqual(@as(u64, 2), window.active().?.id);
    try std.testing.expect(!window.selectTab(3));
}
