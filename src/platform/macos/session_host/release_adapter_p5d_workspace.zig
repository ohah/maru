//! Descriptor-owned scratch root for one P5d CLI/SSH release run.
//!
//! The generic pre-publish workspace owns creation, identity, and final root removal. This wrapper
//! additionally removes child output only after the bounded child process group has been reaped.

const std = @import("std");
const c = std.c;
const workspace = @import("release_adapter_pre_publish_workspace");

const max_top_level_entries = 1024;

pub const Workspace = struct {
    owner: ?*Workspace = null,
    root: workspace.Workspace = .{},
    path_len: usize = 0,
    path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn value(self: *@This()) ![:0]const u8 {
        if (self.owner != self) return error.InvalidOwner;
        try self.root.validate();
        return self.path_storage[0..self.path_len :0];
    }

    pub fn directoryDescriptor(self: *@This()) !c.fd_t {
        if (self.owner != self) return error.InvalidOwner;
        return self.root.rootDirectoryDescriptor();
    }

    pub fn cleanup(self: *@This(), io: std.Io) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.root.validate();
        const root_fd = try self.root.rootDirectoryDescriptor();
        const root_dir: std.Io.Dir = .{ .handle = root_fd };

        // Reopen the iterator for each deletion so no borrowed entry name outlives its reader.
        // A reaped child is the only legitimate writer; the cap turns a same-user race into a
        // fail-closed cleanup error instead of an unbounded release runner.
        var removed: usize = 0;
        while (true) {
            var scan = root_dir.openDir(io, ".", .{ .follow_symlinks = false, .iterate = true }) catch
                return error.CleanupFailed;
            var iterator = scan.iterate();
            const next = iterator.next(io) catch {
                scan.close(io);
                return error.CleanupFailed;
            };
            if (next == null) {
                scan.close(io);
                break;
            }
            var name_storage: [std.fs.max_name_bytes]u8 = undefined;
            const name = next.?.name;
            if (name.len == 0 or name.len > name_storage.len) {
                scan.close(io);
                return error.CleanupFailed;
            }
            @memcpy(name_storage[0..name.len], name);
            scan.close(io);
            if (removed == max_top_level_entries) return error.CleanupFailed;
            root_dir.deleteTree(io, name_storage[0..name.len]) catch return error.CleanupFailed;
            removed += 1;
        }
        if (c.fsync(root_fd) != 0) return error.CleanupFailed;
        self.root.cleanup() catch return error.CleanupFailed;
        self.* = .{};
    }
};

pub fn prepare(result: *Workspace, path: [:0]const u8) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), path)) return error.InvalidOwner;
    workspace.prepare(&result.root, path) catch |err| {
        // Preserve the generic owner's retry authority when durable rollback could not finish.
        if (result.root.owner == &result.root) result.owner = result;
        return err;
    };
    result.path_len = path.len;
    @memcpy(result.path_storage[0..path.len], path);
    result.path_storage[path.len] = 0;
    result.owner = result;
}

fn pristine(result: *const Workspace) bool {
    return result.owner == null and result.root.owner == null and result.root.parent_fd < 0 and
        result.root.root_fd < 0 and !result.root.root_present and result.root.root_device == 0 and
        result.root.root_inode == 0 and result.root.path_len == 0 and result.path_len == 0 and
        allZero(&result.path_storage);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
