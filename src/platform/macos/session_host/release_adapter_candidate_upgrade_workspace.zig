//! Final-address paths for one isolated upgrade-B signed product run.

const std = @import("std");
const workspace = @import("release_adapter_pre_publish_workspace");

pub const Paths = struct {
    signed_one_home: [:0]const u8,
    signed_near_max_home: [:0]const u8,
    predecessor_executable: [:0]const u8,
    signed_one_leaf: [:0]const u8,
    signed_near_max_leaf: [:0]const u8,
    evidence: [:0]const u8,
};

pub const Workspace = struct {
    owner: ?*Workspace = null,
    root: workspace.Workspace = .{},
    signed_one_home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    signed_near_max_home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    predecessor_executable: [std.fs.max_path_bytes:0]u8 = @splat(0),
    signed_one_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    signed_near_max_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn value(self: *@This()) !Paths {
        if (self.owner != self) return error.InvalidOwner;
        try self.root.validate();
        return self.paths();
    }

    pub fn directoryDescriptor(self: *@This()) !std.c.fd_t {
        if (self.owner != self) return error.InvalidOwner;
        return self.root.rootDirectoryDescriptor();
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.root.cleanup() catch return error.CleanupFailed;
        self.* = .{};
    }

    fn paths(self: *@This()) Paths {
        return .{
            .signed_one_home = std.mem.sliceTo(&self.signed_one_home, 0),
            .signed_near_max_home = std.mem.sliceTo(&self.signed_near_max_home, 0),
            .predecessor_executable = std.mem.sliceTo(&self.predecessor_executable, 0),
            .signed_one_leaf = std.mem.sliceTo(&self.signed_one_leaf, 0),
            .signed_near_max_leaf = std.mem.sliceTo(&self.signed_near_max_leaf, 0),
            .evidence = std.mem.sliceTo(&self.evidence, 0),
        };
    }
};

pub fn prepare(result: *Workspace, root_path: [:0]const u8) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), root_path)) return error.InvalidOwner;
    workspace.prepare(&result.root, root_path) catch |err| {
        if (result.root.owner == &result.root) result.owner = result;
        return err;
    };
    result.owner = result;
    derivePaths(result) catch |err| {
        result.root.cleanup() catch return error.CleanupFailed;
        result.* = .{};
        return err;
    };
}

fn derivePaths(result: *Workspace) !void {
    _ = try result.root.upgradeChildPath(.signed_one_home, &result.signed_one_home);
    _ = try result.root.upgradeChildPath(.signed_near_max_home, &result.signed_near_max_home);
    _ = try result.root.upgradeChildPath(.predecessor_executable, &result.predecessor_executable);
    _ = try result.root.upgradeChildPath(.signed_one_leaf, &result.signed_one_leaf);
    _ = try result.root.upgradeChildPath(.signed_near_max_leaf, &result.signed_near_max_leaf);
    _ = try result.root.upgradeChildPath(.evidence, &result.evidence);
}

fn pristine(result: *const Workspace) bool {
    return result.owner == null and result.root.owner == null and result.root.parent_fd < 0 and result.root.root_fd < 0 and
        !result.root.root_present and result.root.root_device == 0 and result.root.root_inode == 0 and result.root.path_len == 0 and
        allZero(&result.signed_one_home) and allZero(&result.signed_near_max_home) and allZero(&result.predecessor_executable) and
        allZero(&result.signed_one_leaf) and allZero(&result.signed_near_max_leaf) and allZero(&result.evidence);
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
