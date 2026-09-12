//! Exact scratch-root owner for one Notification Center release scenario.
//!
//! The app and its session host may populate only `h` and `s`. Cleanup names those two entries
//! explicitly after the app child has confirmed end-all and exited; an unexpected sibling keeps
//! the root non-empty and makes cleanup fail closed.

const std = @import("std");
const c = std.c;
const base = @import("release_adapter_pre_publish_workspace");

pub const Workspace = struct {
    owner: ?*Workspace = null,
    root: base.Workspace = .{},

    pub fn cleanup(self: *@This(), io: std.Io) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.root.validate();
        const root_fd = try self.root.rootDirectoryDescriptor();
        const dir: std.Io.Dir = .{ .handle = root_fd };
        for ([_][]const u8{ "s", "h" }) |name| {
            dir.deleteTree(io, name) catch return error.CleanupFailed;
        }
        if (c.fsync(root_fd) != 0) return error.CleanupFailed;
        self.root.cleanup() catch return error.CleanupFailed;
        self.* = .{};
    }
};

pub fn prepare(result: *Workspace, path: [:0]const u8) !void {
    if (result.owner != null or result.root.owner != null or
        overlaps(std.mem.asBytes(result), path)) return error.InvalidOwner;
    base.prepare(&result.root, path) catch |err| {
        if (result.root.owner == &result.root) result.owner = result;
        return err;
    };
    result.owner = result;
    const root_fd = try result.root.rootDirectoryDescriptor();
    for ([_][*:0]const u8{ "s", "h" }) |name| {
        if (c.mkdirat(root_fd, name, 0o700) != 0) return error.CreateFailed;
    }
    if (c.fsync(root_fd) != 0) return error.SyncFailed;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
