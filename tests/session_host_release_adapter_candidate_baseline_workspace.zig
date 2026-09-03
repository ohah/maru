//! Baseline release children share one descriptor-owned private root and cannot clean user state.

const std = @import("std");
const baseline = @import("release_adapter_candidate_baseline_workspace");

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "one private root seals both homes leaves and aggregate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var owner: baseline.Workspace = .{};
    try baseline.prepare(&owner, root);
    const paths = try owner.value();
    try std.testing.expectEqualStrings("default-false", std.fs.path.basename(paths.default_false_home));
    try std.testing.expectEqualStrings("signed-app-quit", std.fs.path.basename(paths.signed_app_quit_home));
    try std.testing.expectEqualStrings("default-false.json", std.fs.path.basename(paths.default_false_leaf));
    try std.testing.expectEqualStrings("signed-app-quit.json", std.fs.path.basename(paths.signed_app_quit_leaf));
    try std.testing.expectEqualStrings("baseline-evidence.json", std.fs.path.basename(paths.evidence));
    inline for (.{ paths.default_false_home, paths.signed_app_quit_home, paths.default_false_leaf, paths.signed_app_quit_leaf, paths.evidence }) |path| {
        try std.testing.expectEqualStrings(root, std.fs.path.dirname(path).?);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, path, .{}));
    }
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, root, .{});
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try owner.cleanup();
}

test "copied owner and owner storage input are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var owner: baseline.Workspace = .{};
    try baseline.prepare(&owner, root);
    var copied = owner;
    try std.testing.expectError(error.InvalidOwner, copied.value());
    try std.testing.expectError(error.InvalidOwner, baseline.prepare(&owner, root));
    _ = try owner.value();
    try owner.cleanup();

    var aliased: baseline.Workspace = .{};
    const bytes = std.mem.asBytes(&aliased);
    const path: [:0]const u8 = @ptrCast(bytes[0..8 :0]);
    try std.testing.expectError(error.InvalidOwner, baseline.prepare(&aliased, path));
}

test "occupied child preserves exact cleanup retry authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var owner: baseline.Workspace = .{};
    try baseline.prepare(&owner, root);
    const paths = try owner.value();
    try std.Io.Dir.createDirAbsolute(std.testing.io, paths.default_false_home, .default_dir);
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.testing.expect(owner.owner == &owner);
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, paths.default_false_home);
    try owner.cleanup();
}

test "root replacement never removes the foreign directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    const moved = try absolute(&tmp, "owned-moved", &moved_storage);
    var owner: baseline.Workspace = .{};
    try baseline.prepare(&owner, root);
    try std.Io.Dir.renameAbsolute(root, moved, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    {
        var foreign = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
        defer foreign.close(std.testing.io);
        try foreign.writeFile(std.testing.io, .{ .sub_path = "foreign", .data = "foreign" });
    }
    try std.testing.expectError(error.FileChanged, owner.value());
    try std.testing.expectError(error.CleanupFailed, owner.cleanup());
    try std.Io.Dir.cwd().access(std.testing.io, root, .{});
    try std.Io.Dir.cwd().deleteTree(std.testing.io, root);
    try std.Io.Dir.renameAbsolute(moved, root, std.testing.io);
    try owner.cleanup();
}

test "workspace source has no ambient user namespace lookup" {
    std.testing.refAllDecls(baseline);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_baseline_workspace.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_SESSION_HOST_ROOT") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "/tmp/maru-") == null);
}
