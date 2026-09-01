//! Pre-publish private workspace ownership and cleanup are exercised on the actual filesystem.

const std = @import("std");
const workspace = @import("release_adapter_pre_publish_workspace");

var sync_calls: usize = 0;
fn failThreeSyncs(_: std.c.fd_t) bool {
    sync_calls += 1;
    return sync_calls > 3;
}

fn failRootOpen(_: std.c.fd_t, _: [*:0]const u8) std.c.fd_t {
    return -1;
}

fn failRootStat(_: std.c.fd_t, _: [*:0]const u8, _: *std.posix.Stat) bool {
    return false;
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "workspace creates one private root and exact absent child paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    try workspace.prepare(&owner, root);
    var copied = owner;
    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, copied.childPath(.current_manifest, &child_storage));
    inline for ([_]workspace.Child{ .current_manifest, .predecessor_manifest, .predecessor_assets, .dmg, .current_assets }) |child| {
        const path = try owner.childPath(child, &child_storage);
        try std.testing.expectEqualStrings(root, std.fs.path.dirname(path).?);
        const expected = switch (child) {
            .current_manifest => "current-manifest",
            .predecessor_manifest => "predecessor-manifest",
            .predecessor_assets => "predecessor-assets",
            .dmg => "dmg",
            .current_assets => "current-assets",
        };
        try std.testing.expectEqualStrings(expected, std.fs.path.basename(path));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, path, .{}));
    }
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, root, .{});
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try owner.cleanup();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
}

test "workspace mutable buffers cannot overlap final-address owner storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var prepare_alias: workspace.Workspace = .{};
    defer if (prepare_alias.owner == &prepare_alias) prepare_alias.cleanup() catch {};
    const aliased_root = try absolute(&tmp, "prepare-alias", &prepare_alias.path_storage);
    try std.testing.expectError(error.InvalidOwner, workspace.prepare(&prepare_alias, aliased_root));

    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    try workspace.prepare(&owner, root);
    defer if (owner.owner == &owner) owner.cleanup() catch {};
    try std.testing.expectError(error.InvalidOwner, owner.childPath(.current_manifest, &owner.path_storage));
}

test "occupied child blocks derivation and cleanup preserves retry authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    try workspace.prepare(&owner, root);
    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const child = try owner.childPath(.current_manifest, &child_storage);
    try std.Io.Dir.createDirAbsolute(std.testing.io, child, .default_dir);
    try std.testing.expectError(error.ChildOccupied, owner.childPath(.current_manifest, &child_storage));
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, child);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(root.ptr, 0));
    try owner.cleanup();
}

test "replacement and invalid destinations never release foreign roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    const moved = try absolute(&tmp, "moved", &moved_storage);
    var owner: workspace.Workspace = .{};
    try std.testing.expectError(error.InvalidPath, workspace.prepare(&owner, "relative"));
    const too_long = "/" ++ ("x" ** std.fs.max_path_bytes);
    try std.testing.expectError(error.InvalidPath, workspace.prepare(&owner, too_long));
    try std.testing.expectError(error.InvalidPath, workspace.prepare(&owner, "/tmp/bad\x00tail"));
    try workspace.prepare(&owner, root);
    try std.testing.expectError(error.InvalidOwner, workspace.prepare(&owner, moved));
    try std.Io.Dir.renameAbsolute(root, moved, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.FileChanged, owner.childPath(.current_assets, &child_storage));
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, root);
    try std.Io.Dir.renameAbsolute(moved, root, std.testing.io);
    try owner.cleanup();
}

test "initialization failure retains cleanup authority until durable removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    sync_calls = 0;
    try std.testing.expectError(error.SyncFailed, workspace.prepareWithSync(&owner, root, failThreeSyncs));
    try std.testing.expect(owner.owner == &owner);
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try owner.cleanup();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
}

test "root open failure removes the exact created directory without residue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    try std.testing.expectError(error.CreateFailed, workspace.prepareWithOpen(&owner, root, failRootOpen));
    try std.testing.expect(owner.owner == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
}

test "root pathname stat failure removes the descriptor-owned directory without residue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "workspace", &root_storage);
    var owner: workspace.Workspace = .{};
    try std.testing.expectError(error.SyncFailed, workspace.prepareWithStat(&owner, root, failRootStat));
    try std.testing.expect(owner.owner == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
}
