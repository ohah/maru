//! Descriptor-owned private root for one pre-publish validation phase.
//!
//! Child compositions still own their directories and files. This owner only derives the closed
//! set of absent child paths and removes the exact empty root after those children are cleaned.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const safe_open = @import("safe_open");

pub const Child = enum { current_manifest, predecessor_manifest, predecessor_assets, dmg, current_assets };

pub const Error = error{
    InvalidOwner,
    InvalidPath,
    DestinationExists,
    CreateFailed,
    SyncFailed,
    FileChanged,
    ChildOccupied,
    CleanupFailed,
};

pub const Workspace = struct {
    owner: ?*Workspace = null,
    parent_fd: c.fd_t = -1,
    root_fd: c.fd_t = -1,
    root_present: bool = false,
    root_device: u64 = 0,
    root_inode: u64 = 0,
    path_len: usize = 0,
    path_storage: [std.fs.max_path_bytes:0]u8 = undefined,
    leaf_storage: [std.fs.max_name_bytes:0]u8 = undefined,
    sync_fn: *const fn (c.fd_t) bool = systemSync,

    pub fn childPath(self: *@This(), child: Child, output: *[std.fs.max_path_bytes:0]u8) Error![:0]const u8 {
        if (rangesOverlap(std.mem.asBytes(self), std.mem.asBytes(output))) return error.InvalidOwner;
        try self.revalidate(true);
        const name = childName(child);
        var observed: posix.Stat = undefined;
        if (c.fstatat(self.root_fd, name.ptr, &observed, posix.AT.SYMLINK_NOFOLLOW) == 0)
            return error.ChildOccupied;
        if (posix.errno(-1) != .NOENT) return error.FileChanged;
        return std.fmt.bufPrintZ(output, "{s}/{s}", .{ self.path_storage[0..self.path_len], name }) catch
            return error.InvalidPath;
    }

    pub fn cleanup(self: *@This()) Error!void {
        if (self.owner != self or self.parent_fd < 0) return error.InvalidOwner;
        if (self.root_present) {
            self.revalidate(false) catch return error.CleanupFailed;
            if (!self.sync_fn(self.root_fd)) return error.CleanupFailed;
            if (c.unlinkat(self.parent_fd, self.leaf_storage[0..].ptr, posix.AT.REMOVEDIR) != 0)
                return error.CleanupFailed;
            self.root_present = false;
            _ = c.close(self.root_fd);
            self.root_fd = -1;
        }
        if (!self.sync_fn(self.parent_fd)) return error.CleanupFailed;
        _ = c.close(self.parent_fd);
        self.* = .{};
    }

    fn revalidate(self: *@This(), require_private_mode: bool) Error!void {
        if (self.owner != self or !self.root_present or self.parent_fd < 0)
            return error.InvalidOwner;
        var reopened_root = false;
        if (self.root_fd < 0) {
            self.root_fd = systemOpenRoot(self.parent_fd, self.leaf_storage[0..].ptr);
            if (self.root_fd < 0) return error.FileChanged;
            reopened_root = true;
        }
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(self.root_fd, &held) != 0 or
            c.fstatat(self.parent_fd, self.leaf_storage[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !sameDirectory(held, self.root_device, self.root_inode, require_private_mode) or
            !sameDirectory(named, self.root_device, self.root_inode, require_private_mode))
        {
            if (reopened_root) {
                _ = c.close(self.root_fd);
                self.root_fd = -1;
            }
            return error.FileChanged;
        }
        if (require_private_mode) {
            const path = self.path_storage[0..self.path_len :0];
            const reopened = safe_open.openAbsoluteNoFollow(path, true) catch return error.FileChanged;
            defer _ = c.close(reopened);
            var current: posix.Stat = undefined;
            if (c.fstat(reopened, &current) != 0 or
                !sameDirectory(current, self.root_device, self.root_inode, true))
                return error.FileChanged;
        }
    }
};

pub fn prepare(result: *Workspace, path: [:0]const u8) Error!void {
    return prepareWithOperations(result, path, systemSync, systemOpenRoot, systemStatRoot);
}

pub fn prepareWithSync(
    result: *Workspace,
    path: [:0]const u8,
    sync_fn: *const fn (c.fd_t) bool,
) Error!void {
    return prepareWithOperations(result, path, sync_fn, systemOpenRoot, systemStatRoot);
}

pub fn prepareWithOpen(
    result: *Workspace,
    path: [:0]const u8,
    open_fn: *const fn (c.fd_t, [*:0]const u8) c.fd_t,
) Error!void {
    return prepareWithOperations(result, path, systemSync, open_fn, systemStatRoot);
}

pub fn prepareWithStat(
    result: *Workspace,
    path: [:0]const u8,
    stat_fn: *const fn (c.fd_t, [*:0]const u8, *posix.Stat) bool,
) Error!void {
    return prepareWithOperations(result, path, systemSync, systemOpenRoot, stat_fn);
}

fn prepareWithOperations(
    result: *Workspace,
    path: [:0]const u8,
    sync_fn: *const fn (c.fd_t) bool,
    open_fn: *const fn (c.fd_t, [*:0]const u8) c.fd_t,
    stat_fn: *const fn (c.fd_t, [*:0]const u8, *posix.Stat) bool,
) Error!void {
    if (rangesOverlap(std.mem.asBytes(result), path) or result.owner != null) return error.InvalidOwner;
    if (path.len >= std.fs.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidPath;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const leaf = path[slash + 1 ..];
    if (path.len < 2 or path[0] != '/' or !validLeaf(leaf)) return error.InvalidPath;
    result.path_len = path.len;
    @memcpy(result.path_storage[0..path.len], path);
    result.path_storage[path.len] = 0;
    _ = std.fmt.bufPrintZ(&result.leaf_storage, "{s}", .{leaf}) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_path = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidPath;
    result.parent_fd = safe_open.openAbsoluteNoFollow(parent_path, true) catch return error.InvalidPath;
    result.owner = result;
    result.sync_fn = sync_fn;
    if (c.mkdirat(result.parent_fd, result.leaf_storage[0..].ptr, 0o700) != 0) {
        const err: Error = if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
        _ = c.close(result.parent_fd);
        result.* = .{};
        return err;
    }
    result.root_present = true;
    result.root_fd = open_fn(result.parent_fd, result.leaf_storage[0..].ptr);
    var held: posix.Stat = undefined;
    if (result.root_fd >= 0 and c.fstat(result.root_fd, &held) == 0 and posix.S.ISDIR(held.mode)) {
        result.root_device = @intCast(held.dev);
        result.root_inode = @intCast(held.ino);
    }
    var named: posix.Stat = undefined;
    if (result.root_device == 0 or result.root_inode == 0) {
        if (!stat_fn(result.parent_fd, result.leaf_storage[0..].ptr, &named) or !posix.S.ISDIR(named.mode))
            return error.CreateFailed;
        result.root_device = @intCast(named.dev);
        result.root_inode = @intCast(named.ino);
        return fail(result, error.CreateFailed);
    }
    if (!stat_fn(result.parent_fd, result.leaf_storage[0..].ptr, &named) or
        !sameDirectory(named, result.root_device, result.root_inode, false) or
        c.fchmodat(result.parent_fd, result.leaf_storage[0..].ptr, 0o700, @intCast(posix.AT.SYMLINK_NOFOLLOW)) != 0 or
        !result.sync_fn(result.root_fd) or !result.sync_fn(result.parent_fd))
        return fail(result, error.SyncFailed);
}

fn fail(result: *Workspace, err: Error) Error {
    if (result.root_device != 0 and result.root_inode != 0) result.cleanup() catch return err;
    return err;
}

fn systemSync(fd: c.fd_t) bool {
    return c.fsync(fd) == 0;
}

fn systemOpenRoot(parent_fd: c.fd_t, leaf: [*:0]const u8) c.fd_t {
    return c.openat(parent_fd, leaf, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0));
}

fn systemStatRoot(parent_fd: c.fd_t, leaf: [*:0]const u8, result: *posix.Stat) bool {
    return c.fstatat(parent_fd, leaf, result, posix.AT.SYMLINK_NOFOLLOW) == 0;
}

fn sameDirectory(observed: posix.Stat, device: u64, inode: u64, require_private_mode: bool) bool {
    return posix.S.ISDIR(observed.mode) and (!require_private_mode or observed.mode & 0o777 == 0o700) and
        observed.dev == device and observed.ino == inode;
}

fn validLeaf(leaf: []const u8) bool {
    return leaf.len > 0 and leaf.len <= std.fs.max_name_bytes and
        !std.mem.eql(u8, leaf, ".") and !std.mem.eql(u8, leaf, "..") and
        std.mem.indexOfScalar(u8, leaf, '/') == null and std.mem.indexOfScalar(u8, leaf, 0) == null;
}

fn childName(child: Child) [:0]const u8 {
    return switch (child) {
        .current_manifest => "current-manifest",
        .predecessor_manifest => "predecessor-manifest",
        .predecessor_assets => "predecessor-assets",
        .dmg => "dmg",
        .current_assets => "current-assets",
    };
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
