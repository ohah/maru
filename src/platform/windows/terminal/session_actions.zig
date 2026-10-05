//! Windows terminal gesture adapter. UI input queues requests; this shared
//! operation publishes focus only after native session creation succeeds.
const std = @import("std");

pub fn spawnFocused(allocator: std.mem.Allocator, io: std.Io, sessions: anytype, tabs: anytype, window: anytype, runtime: anytype, next_id: *usize, options: anytype, view: anytype, limit: usize, comptime spawn: anytype) !bool {
    if (sessions.items.len >= limit) return false;
    var current = options;
    if (window.active()) |surface| {
        // Reader and UI share the core; snapshot the latest geometry under its lock.
        surface.lockCore(io);
        current.size = surface.core.size;
        surface.unlockCore(io);
    }
    try spawn(allocator, sessions, tabs, window, runtime, next_id, current);
    // Failed native admission must leave the old visible document and selection intact.
    _ = window.selectTab(sessions.items.len - 1);
    view.* = .{ .terminal = sessions.items.len - 1 };
    return true;
}
