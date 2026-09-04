//! Final-address paths for one isolated baseline product run.
//!
//! The generic descriptor-owned workspace remains the filesystem SSOT. This wrapper closes its
//! baseline child set so later runners cannot derive an ambient user config or registry path.

const std = @import("std");
const workspace = @import("release_adapter_pre_publish_workspace");

pub const Paths = struct {
    default_false_home: [:0]const u8,
    signed_app_quit_home: [:0]const u8,
    default_false_leaf: [:0]const u8,
    signed_app_quit_leaf: [:0]const u8,
    evidence: [:0]const u8,
};

pub const Workspace = struct {
    owner: ?*Workspace = null,
    root: workspace.Workspace = .{},
    default_false_home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    signed_app_quit_home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    default_false_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    signed_app_quit_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return pristine(self);
    }

    pub fn value(self: *@This()) !Paths {
        if (self.owner != self) return error.InvalidOwner;
        try self.root.validate();
        return self.paths();
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.root.cleanup() catch return error.CleanupFailed;
        self.* = .{};
    }

    fn paths(self: *@This()) Paths {
        return .{
            .default_false_home = std.mem.sliceTo(&self.default_false_home, 0),
            .signed_app_quit_home = std.mem.sliceTo(&self.signed_app_quit_home, 0),
            .default_false_leaf = std.mem.sliceTo(&self.default_false_leaf, 0),
            .signed_app_quit_leaf = std.mem.sliceTo(&self.signed_app_quit_leaf, 0),
            .evidence = std.mem.sliceTo(&self.evidence, 0),
        };
    }
};

pub fn prepare(result: *Workspace, root_path: [:0]const u8) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), root_path)) return error.InvalidOwner;
    workspace.prepare(&result.root, root_path) catch |err| {
        // The root owner intentionally survives failures whose durable cleanup could not finish.
        // Expose that same retry authority through this final-address wrapper.
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
    _ = try result.root.baselineChildPath(.baseline_default_false_home, &result.default_false_home);
    _ = try result.root.baselineChildPath(.baseline_signed_app_quit_home, &result.signed_app_quit_home);
    _ = try result.root.baselineChildPath(.baseline_default_false_leaf, &result.default_false_leaf);
    _ = try result.root.baselineChildPath(.baseline_signed_app_quit_leaf, &result.signed_app_quit_leaf);
    _ = try result.root.baselineChildPath(.baseline_evidence, &result.evidence);
}

fn pristine(result: *const Workspace) bool {
    return result.owner == null and result.root.owner == null and result.root.parent_fd < 0 and result.root.root_fd < 0 and
        !result.root.root_present and result.root.root_device == 0 and result.root.root_inode == 0 and result.root.path_len == 0 and
        allZero(&result.default_false_home) and allZero(&result.signed_app_quit_home) and
        allZero(&result.default_false_leaf) and allZero(&result.signed_app_quit_leaf) and allZero(&result.evidence);
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
