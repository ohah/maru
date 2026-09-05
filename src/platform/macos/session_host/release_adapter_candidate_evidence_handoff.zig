//! Promotes verified baseline evidence out of an ephemeral runner workspace.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");

pub const Error = files.Error || error{
    InvalidPath,
    SourceChanged,
    CleanupFailed,
};

pub const Value = struct {
    path: []const u8,
    observation: files.ExecutableObservation,
};

pub const DurableEvidence = struct {
    owner: ?*DurableEvidence = null,
    file: files.PinnedReleaseFile = .{},
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination_len: usize = 0,
    leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),
    leaf_len: usize = 0,
    leaf_present: bool = false,

    pub fn value(self: *const @This()) ?Value {
        if (self.owner != self or !self.leaf_present or !validStorage(self) or
            self.file.owner != &self.file)
            return null;
        const observation = self.file.value() orelse return null;
        return .{ .path = self.destination[0..self.destination_len], .observation = observation };
    }

    pub fn revalidate(self: *const @This()) Error!Value {
        const current = self.value() orelse return error.InvalidOwner;
        const path: [:0]const u8 = self.destination[0..self.destination_len :0];
        const observation = try self.file.revalidate(path);
        if (!sameObservation(current.observation, observation)) return error.FileChanged;
        return .{ .path = path, .observation = observation };
    }

    /// Deletes only the exact inode published by this owner. A pathname replacement remains
    /// untouched and leaves this owner available for explicit recovery/audit.
    pub fn cleanup(self: *@This()) Error!void {
        if (self.owner != self or self.file.owner != &self.file or !validStorage(self))
            return error.InvalidOwner;
        if (self.leaf_present) {
            const path: [:0]const u8 = self.destination[0..self.destination_len :0];
            const expected = self.file.revalidate(path) catch return error.CleanupFailed;
            var held: posix.Stat = undefined;
            var named: posix.Stat = undefined;
            const leaf: [:0]const u8 = self.leaf[0..self.leaf_len :0];
            if (c.fstat(self.file.fd, &held) != 0 or
                c.fstatat(self.file.parent_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                held.dev != expected.identity.device or held.ino != expected.identity.inode or
                !posix.S.ISREG(held.mode) or held.nlink != 1 or
                named.dev != held.dev or named.ino != held.ino or
                c.unlinkat(self.file.parent_fd, leaf.ptr, 0) != 0)
                return error.CleanupFailed;
            self.leaf_present = false;
        }
        if (c.fsync(self.file.parent_fd) != 0) return error.CleanupFailed;
        self.file.deinit() catch return error.CleanupFailed;
        self.* = .{};
    }
};

pub fn promote(
    allocator: std.mem.Allocator,
    source: *const files.PinnedReleaseFile,
    workspace_root: [:0]const u8,
    source_path: [:0]const u8,
    destination: [:0]const u8,
    result: *DurableEvidence,
) Error!void {
    const result_bytes = std.mem.asBytes(result);
    const source_bytes = std.mem.asBytes(source);
    if (!pristine(result) or source.value() == null or
        overlaps(result_bytes, source_bytes) or overlaps(result_bytes, workspace_root) or
        overlaps(result_bytes, source_path) or overlaps(result_bytes, destination) or
        overlaps(source_bytes, workspace_root) or overlaps(source_bytes, source_path) or
        overlaps(source_bytes, destination) or overlaps(workspace_root, source_path) or
        overlaps(workspace_root, destination) or overlaps(source_path, destination))
        return error.InvalidOwner;
    try validatePath(workspace_root, false);
    try validatePath(source_path, true);
    try validatePath(destination, true);
    if (!directChild(workspace_root, source_path) or sameOrDescendant(workspace_root, destination))
        return error.InvalidPath;

    const destination_leaf = std.fs.path.basename(destination);
    if (destination_leaf.len == 0 or destination_leaf.len >= result.leaf.len) return error.InvalidPath;
    if (destination.len >= result.destination.len) return error.InvalidPath;

    const source_before = source.revalidate(source_path) catch return error.SourceChanged;
    var input = source.readHeldAlloc(allocator, source_path, evidence.max_evidence_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SourceChanged,
    };
    defer input.deinit(allocator);
    const source_after = source.revalidate(source_path) catch return error.SourceChanged;
    if (!sameObservation(source_before, source_after) or input.size != source_before.size or
        !std.mem.eql(u8, &input.sha256, &source_before.sha256))
        return error.SourceChanged;

    try files.publishSummaryOwnedExclusive(&result.file, destination, input.bytes);
    @memcpy(result.destination[0..destination.len], destination);
    result.destination[destination.len] = 0;
    result.destination_len = destination.len;
    @memcpy(result.leaf[0..destination_leaf.len], destination_leaf);
    result.leaf[destination_leaf.len] = 0;
    result.leaf_len = destination_leaf.len;
    result.leaf_present = true;
    result.owner = result;

    const published = result.revalidate() catch {
        result.cleanup() catch return error.CleanupFailed;
        return error.FileChanged;
    };
    if (sameIdentity(source_before.identity, published.observation.identity) or
        source_before.size != published.observation.size or
        !std.mem.eql(u8, &source_before.sha256, &published.observation.sha256))
    {
        result.cleanup() catch return error.CleanupFailed;
        return error.FileChanged;
    }
}

fn pristine(value: *const DurableEvidence) bool {
    return value.owner == null and value.file.owner == null and value.file.fd < 0 and value.file.parent_fd < 0 and
        value.destination_len == 0 and value.leaf_len == 0 and !value.leaf_present;
}

fn validStorage(value: *const DurableEvidence) bool {
    if (value.destination_len == 0 or value.destination_len >= value.destination.len or
        value.leaf_len == 0 or value.leaf_len >= value.leaf.len or
        value.destination[value.destination_len] != 0 or value.leaf[value.leaf_len] != 0)
        return false;
    const destination = value.destination[0..value.destination_len];
    return std.mem.eql(u8, std.fs.path.basename(destination), value.leaf[0..value.leaf_len]);
}

fn validatePath(value: []const u8, require_leaf: bool) Error!void {
    if (!std.fs.path.isAbsolute(value) or value.len == 0 or value.len >= std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, value, 0) != null or (value.len > 1 and std.mem.endsWith(u8, value, "/")))
        return error.InvalidPath;
    if (require_leaf and value.len < 2) return error.InvalidPath;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.InvalidPath;
    }
}

fn directChild(root: []const u8, child: []const u8) bool {
    if (root.len == 1 and root[0] == '/') return std.mem.indexOfScalar(u8, child[1..], '/') == null;
    if (child.len <= root.len + 1 or !std.mem.startsWith(u8, child, root) or child[root.len] != '/') return false;
    return std.mem.indexOfScalar(u8, child[root.len + 1 ..], '/') == null;
}

fn sameOrDescendant(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (root.len == 1 and root[0] == '/') return true;
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn sameIdentity(left: files.Identity, right: files.Identity) bool {
    return left.device == right.device and left.inode == right.inode;
}

fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return sameIdentity(left.identity, right.identity) and left.size == right.size and left.mode == right.mode and
        std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
