//! P5d release runs use one descriptor-owned scratch root and never clean ambient app state.

const std = @import("std");
const p5d = @import("release_adapter_p5d_workspace");

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "workspace starts absent and exposes one private exact path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "p5d", &storage);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, path, .{}));
    var owner: p5d.Workspace = .{};
    try p5d.prepare(&owner, path);
    try std.testing.expectEqualStrings(path, try owner.value());
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try owner.cleanup(std.testing.io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, path, .{}));
}

test "cleanup removes nested child output without following symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim", .data = "keep" });
    var storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "p5d", &storage);
    var owner: p5d.Workspace = .{};
    try p5d.prepare(&owner, path);
    const root_dir: std.Io.Dir = .{ .handle = try owner.directoryDescriptor() };
    try root_dir.createDir(std.testing.io, "home", .default_dir);
    var home = try root_dir.openDir(std.testing.io, "home", .{});
    defer home.close(std.testing.io);
    try home.createDir(std.testing.io, ".local", .default_dir);
    var local = try home.openDir(std.testing.io, ".local", .{});
    defer local.close(std.testing.io);
    try local.createDir(std.testing.io, "bin", .default_dir);
    try root_dir.writeFile(std.testing.io, .{ .sub_path = "home/.local/bin/maru", .data = "output" });
    try root_dir.symLink(std.testing.io, "../victim", "victim-link", .{});
    try owner.cleanup(std.testing.io);
    var victim = try tmp.dir.openFile(std.testing.io, "victim", .{});
    defer victim.close(std.testing.io);
}

test "copied owner and aliased input are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "p5d", &storage);
    var owner: p5d.Workspace = .{};
    try p5d.prepare(&owner, path);
    var copied = owner;
    try std.testing.expectError(error.InvalidOwner, copied.value());
    try std.testing.expectError(error.InvalidOwner, copied.cleanup(std.testing.io));
    try owner.cleanup(std.testing.io);

    var aliased: p5d.Workspace = .{};
    const bytes = std.mem.asBytes(&aliased);
    const alias: [:0]const u8 = @ptrCast(bytes[0..8 :0]);
    try std.testing.expectError(error.InvalidOwner, p5d.prepare(&aliased, alias));
}

test "root replacement preserves foreign pathname and cleanup retry authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "p5d", &root_storage);
    const moved = try absolute(&tmp, "owned-moved", &moved_storage);
    var owner: p5d.Workspace = .{};
    try p5d.prepare(&owner, root);
    try std.Io.Dir.renameAbsolute(root, moved, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    {
        var foreign = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
        defer foreign.close(std.testing.io);
        try foreign.writeFile(std.testing.io, .{ .sub_path = "foreign", .data = "keep" });
    }
    try std.testing.expectError(error.FileChanged, owner.cleanup(std.testing.io));
    try std.Io.Dir.cwd().access(std.testing.io, root, .{});
    try std.Io.Dir.cwd().deleteTree(std.testing.io, root);
    try std.Io.Dir.renameAbsolute(moved, root, std.testing.io);
    try owner.cleanup(std.testing.io);
}

test "workspace source has no ambient namespace or pathname cleanup" {
    std.testing.refAllDecls(p5d);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_p5d_workspace.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "getenv", "MARU_SESSION_HOST_ROOT", "/tmp/maru-", "cwd().deleteTree" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source, forbidden) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "rootDirectoryDescriptor") != null);
}

test "P5d harness gives external workspace deletion authority only to its caller" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/p5d_ssh_smoke.sh", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{
        "EXTERNAL_RUN_DIR=${MARU_P5D_WORKSPACE:-}",
        "RUN_DIR_OWNED=0",
        "if [ \"$RUN_DIR_OWNED\" = 1 ]; then",
        "case \"$EXTERNAL_RUN_DIR\" in",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, source, required) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "rm -rf -- \"$RUN_DIR\""));
}
