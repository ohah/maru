//! Project tree mutation policy. This module is deliberately filesystem-free: L4 resolves a
//! selected row into one of these targets, then a bounded worker executes the approved plan.
//! Keeping validation, root boundaries and dirty protection here prevents the palette, keyboard
//! and context-menu entry points from growing subtly different policies.

const std = @import("std");
const path_shape = @import("../path_shape.zig");
const file_tree = @import("file_tree.zig");

pub const Operation = enum { create_file, create_directory, rename, delete };

pub const Target = struct {
    kind: file_tree.RowKind,
    path: []const u8,
    symlink: bool = false,
    identity: ?file_tree.Identity = null,
    parent_identity: ?file_tree.Identity = null,
    root_identity: ?file_tree.Identity = null,
};

pub const Protection = struct {
    path: []const u8,
    dirty: bool = false,
    dirty_sync_pending: bool = false,
    external_change: bool = false,
    conflict_reload_pending: bool = false,

    pub fn blocksMutation(self: Protection) bool {
        return self.dirty or self.dirty_sync_pending or self.external_change or self.conflict_reload_pending;
    }
};

pub const Plan = struct {
    operation: Operation,
    target_kind: file_tree.RowKind = .file,
    root: []const u8,
    source: []const u8,
    parent: []const u8,
    name: []const u8,
    identity: ?file_tree.Identity = null,
    parent_identity: ?file_tree.Identity = null,
    root_identity: ?file_tree.Identity = null,
};

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null or
        !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
}

pub fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    // 루트 바로 아래인지 판정할 때 루트가 이미 구분자로 끝나면(`/`·`C:\`) 한 칸을 더 요구하면 안 된다.
    // 예전엔 그 예외가 POSIX 루트(`/`)만 알아 Windows 드라이브 루트에 대응이 없었다(docs/windows-platform.md §5).
    return path_shape.isRoot(root) or path_shape.isSep(path[root.len]);
}

pub fn rootForPath(roots: []const []const u8, path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (roots) |root| {
        if (!pathWithin(path, root)) continue;
        if (best == null or root.len > best.?.len) best = root;
    }
    return best;
}

pub fn planCreate(roots: []const []const u8, target: Target, name: []const u8, directory: bool) !Plan {
    try validateName(name);
    const parent = switch (target.kind) {
        .root, .directory => target.path,
        .file => std.fs.path.dirname(target.path) orelse return error.InvalidTarget,
        .recent_header, .recent_file => return error.InvalidTarget,
    };
    // A displayed symlink directory may be expanded, but it is never a mutation container.
    if ((target.kind == .root or target.kind == .directory) and target.symlink) return error.SymlinkContainer;
    const root = rootForPath(roots, parent) orelse return error.OutsideRoot;
    return .{
        .operation = if (directory) .create_directory else .create_file,
        .target_kind = target.kind,
        .root = root,
        .source = "",
        .parent = parent,
        .name = name,
        .parent_identity = if (target.kind == .file) target.parent_identity else target.identity,
        .root_identity = target.root_identity,
    };
}

pub fn planRename(roots: []const []const u8, target: Target, name: []const u8, protected: []const Protection) !Plan {
    try validateName(name);
    if (target.kind != .file and target.kind != .directory) return error.InvalidTarget;
    try ensureUnprotected(target.path, protected);
    const parent = std.fs.path.dirname(target.path) orelse return error.InvalidTarget;
    const root = rootForPath(roots, target.path) orelse return error.OutsideRoot;
    if (std.mem.eql(u8, std.fs.path.basename(target.path), name)) return error.Unchanged;
    return .{
        .operation = .rename,
        .target_kind = target.kind,
        .root = root,
        .source = target.path,
        .parent = parent,
        .name = name,
        .identity = target.identity,
        .parent_identity = target.parent_identity,
        .root_identity = target.root_identity,
    };
}

pub fn planDelete(roots: []const []const u8, target: Target, protected: []const Protection) !Plan {
    if (target.kind != .file and target.kind != .directory) return error.InvalidTarget;
    try ensureUnprotected(target.path, protected);
    const parent = std.fs.path.dirname(target.path) orelse return error.InvalidTarget;
    const root = rootForPath(roots, target.path) orelse return error.OutsideRoot;
    return .{
        .operation = .delete,
        .target_kind = target.kind,
        .root = root,
        .source = target.path,
        .parent = parent,
        .name = std.fs.path.basename(target.path),
        .identity = target.identity,
        .parent_identity = target.parent_identity,
        .root_identity = target.root_identity,
    };
}

pub fn ensureUnprotected(target_path: []const u8, protected: []const Protection) !void {
    for (protected) |entry| {
        if (entry.blocksMutation() and pathWithin(entry.path, target_path)) return error.ProtectedEntry;
    }
}

/// Rename remaps the exact entry and every descendant, but never a sibling with a shared prefix.
/// The caller owns the returned allocation; null means the path is unaffected.
pub fn remapPath(allocator: std.mem.Allocator, path: []const u8, old_prefix: []const u8, new_prefix: []const u8) !?[]u8 {
    if (!pathWithin(path, old_prefix)) return null;
    return try std.mem.concat(allocator, u8, &.{ new_prefix, path[old_prefix.len..] });
}

// 루트 바로 아래인지 판정할 때, 루트가 이미 구분자로 끝나면 한 칸을 더 요구하면 안 된다. 예전 코드는 그
// 예외를 **POSIX 루트(`/`)만** 알아서 드라이브 루트(`C:\`)에서는 첫 자식이 통째로 밖으로 보였다
// (docs/windows-platform.md §5).
test "pathWithin: 드라이브 루트와 POSIX 루트를 모두 루트로 본다" {
    // POSIX — 기존 동작 그대로.
    try std.testing.expect(pathWithin("/a", "/"));
    try std.testing.expect(pathWithin("/a/b", "/a"));
    try std.testing.expect(!pathWithin("/ab", "/a")); // 형제 접두는 포함이 아니다

    // Windows 드라이브 루트 — 옛 코드가 놓치던 자리.
    try std.testing.expect(pathWithin("C:\\a", "C:\\"));
    try std.testing.expect(pathWithin("C:/a", "C:/"));
    try std.testing.expect(pathWithin("C:\\a\\b", "C:\\a"));
    try std.testing.expect(!pathWithin("C:\\ab", "C:\\a")); // 형제 접두는 여전히 아니다

    // 자기 자신은 포함이다(기존 계약).
    try std.testing.expect(pathWithin("C:\\a", "C:\\a"));
}

test "mutation name validation allows dotfiles but rejects traversal and separators" {
    try validateName(".env");
    try validateName("문서.md");
    try std.testing.expectError(error.InvalidName, validateName(""));
    try std.testing.expectError(error.InvalidName, validateName("."));
    try std.testing.expectError(error.InvalidName, validateName(".."));
    try std.testing.expectError(error.InvalidName, validateName("a/b"));
    try std.testing.expectError(error.InvalidName, validateName("a\x00b"));
}

test "create target policy uses a file parent and rejects recent and symlink containers" {
    const roots = [_][]const u8{"/repo"};
    const from_file = try planCreate(&roots, .{ .kind = .file, .path = "/repo/docs/a.md" }, "b.md", false);
    try std.testing.expectEqualStrings("/repo/docs", from_file.parent);
    const from_dir = try planCreate(&roots, .{ .kind = .directory, .path = "/repo/docs" }, ".keep", false);
    try std.testing.expectEqualStrings("/repo/docs", from_dir.parent);
    try std.testing.expectError(error.InvalidTarget, planCreate(&roots, .{ .kind = .recent_file, .path = "/repo/a.md" }, "b.md", false));
    try std.testing.expectError(error.SymlinkContainer, planCreate(&roots, .{ .kind = .directory, .path = "/repo/link", .symlink = true }, "b.md", false));
}

test "rename and delete protect dirty descendants and root boundaries" {
    const roots = [_][]const u8{"/repo"};
    const protection = [_]Protection{.{ .path = "/repo/docs/a.md", .dirty_sync_pending = true }};
    try std.testing.expectError(error.ProtectedEntry, planRename(&roots, .{ .kind = .directory, .path = "/repo/docs" }, "notes", &protection));
    try std.testing.expectError(error.ProtectedEntry, planDelete(&roots, .{ .kind = .file, .path = "/repo/docs/a.md" }, &protection));
    try std.testing.expectError(error.InvalidTarget, planDelete(&roots, .{ .kind = .root, .path = "/repo" }, &.{}));
    try std.testing.expectError(error.OutsideRoot, planRename(&roots, .{ .kind = .file, .path = "/repository/a.md" }, "b.md", &.{}));
}

test "path remap includes descendants without matching sibling prefixes" {
    const allocator = std.testing.allocator;
    const exact = (try remapPath(allocator, "/repo/docs", "/repo/docs", "/repo/notes")).?;
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("/repo/notes", exact);
    const child = (try remapPath(allocator, "/repo/docs/a.md", "/repo/docs", "/repo/notes")).?;
    defer allocator.free(child);
    try std.testing.expectEqualStrings("/repo/notes/a.md", child);
    try std.testing.expect((try remapPath(allocator, "/repo/docs-old/a.md", "/repo/docs", "/repo/notes")) == null);
}
