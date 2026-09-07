//! Upgrade-B release children share one descriptor-owned private root and cannot touch app state.

const std = @import("std");
const upgrade = @import("release_adapter_candidate_upgrade_workspace");

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "private root seals two homes two execution copies two leaves and aggregate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "upgrade", &root_storage);
    var owner: upgrade.Workspace = .{};
    try upgrade.prepare(&owner, root);
    const paths = try owner.value();
    const expected = [_][]const u8{ "signed-one", "signed-near-max", "predecessor-executable", "current-executable", "signed-one.json", "signed-near-max.json", "upgrade-evidence.json" };
    inline for (.{ paths.signed_one_home, paths.signed_near_max_home, paths.predecessor_executable, paths.current_executable, paths.signed_one_leaf, paths.signed_near_max_leaf, paths.evidence }, expected) |path, name| {
        try std.testing.expectEqualStrings(name, std.fs.path.basename(path));
        try std.testing.expectEqualStrings(root, std.fs.path.dirname(path).?);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, path, .{}));
    }
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, root, .{});
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try owner.cleanup();
}

test "copied preowned and aliased workspace owners fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "upgrade", &root_storage);
    var owner: upgrade.Workspace = .{};
    try upgrade.prepare(&owner, root);
    var copied = owner;
    try std.testing.expectError(error.InvalidOwner, copied.value());
    try std.testing.expectError(error.InvalidOwner, upgrade.prepare(&owner, root));
    try owner.cleanup();
    var aliased: upgrade.Workspace = .{};
    const path: [:0]const u8 = @ptrCast(std.mem.asBytes(&aliased)[0..8 :0]);
    try std.testing.expectError(error.InvalidOwner, upgrade.prepare(&aliased, path));
}

test "occupied child preserves cleanup retry without deleting it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "upgrade", &root_storage);
    var owner: upgrade.Workspace = .{};
    try upgrade.prepare(&owner, root);
    const paths = try owner.value();
    try std.Io.Dir.createDirAbsolute(std.testing.io, paths.signed_one_home, .default_dir);
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.testing.expect(owner.owner == &owner);
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, paths.signed_one_home);
    try owner.cleanup();
}

test "root replacement preserves the foreign directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "upgrade", &root_storage);
    const moved = try absolute(&tmp, "owned-moved", &moved_storage);
    var owner: upgrade.Workspace = .{};
    try upgrade.prepare(&owner, root);
    try std.Io.Dir.renameAbsolute(root, moved, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    try std.testing.expectError(error.FileChanged, owner.value());
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.Io.Dir.cwd().access(std.testing.io, root, .{});
    try std.Io.Dir.cwd().deleteTree(std.testing.io, root);
    try std.Io.Dir.renameAbsolute(moved, root, std.testing.io);
    try owner.cleanup();
}

test "workspace source has no ambient user namespace lookup" {
    std.testing.refAllDecls(upgrade);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_upgrade_workspace.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_SESSION_HOST_ROOT") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "/tmp/maru-") == null);
}
