//! Upgrade-B production composition owns timing, artifacts, and retryable cleanup as one unit.

const std = @import("std");
const runner = @import("release_adapter_candidate_upgrade_runner");

test "timing diagnostic accepts only positive ordered monotonic samples" {
    const valid = try runner.timingForTest(11, 17, 100, 140);
    try std.testing.expect(valid.success);
    try std.testing.expectEqual(@as(u64, 11), valid.signed_one_ns);
    try std.testing.expectEqual(@as(u64, 17), valid.signed_near_max_ns);
    try std.testing.expectEqual(@as(u64, 40), valid.phase_ns);
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(0, 17, 100, 140));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(11, 17, 140, 100));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(30, 20, 100, 140));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(std.math.maxInt(u64), 1, 0, @as(i128, std.math.maxInt(u64)) + 1));
}

test "pre-owned and copied execution values fail closed before input access" {
    var execution: runner.Execution = .{};
    execution.owner = &execution;
    var inputs: runner.Inputs = undefined;
    inputs.source_directory_fd = -1;
    try std.testing.expectError(error.InvalidOwner, runner.run(std.testing.io, std.testing.allocator, inputs, 1, &execution));
    execution = .{};
    var copied = execution;
    copied.owner = &execution;
    try std.testing.expectError(error.InvalidOwner, runner.run(std.testing.io, std.testing.allocator, inputs, 1, &copied));
}

test "source composes the phase without ambient paths credentials or result booleans" {
    std.testing.refAllDecls(runner);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_upgrade_runner.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "phase.runWith") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "predecessor_copy.materialize") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "child.run") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "evidence_mod.publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "GH_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "success_boolean") == null);
}

test "workspace cleanup is descriptor confined to the selected signed child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&path_storage, "{s}/upgrade", .{root_buf[0..root_len]});
    var workspace: runner.Workspace = .{};
    try runner.prepareWorkspaceForTest(&workspace, root);
    const paths = try workspace.value();
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
    defer dir.close(std.testing.io);
    try dir.createDir(std.testing.io, "signed-one", .default_dir);
    try dir.createDir(std.testing.io, "signed-near-max", .default_dir);
    {
        var home = try dir.openDir(std.testing.io, "signed-one", .{});
        defer home.close(std.testing.io);
        try home.writeFile(std.testing.io, .{ .sub_path = "owned-residue", .data = "owned" });
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = "signed-one.json", .data = "owned leaf" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "signed-near-max.json", .data = "neighbor" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "foreign-session-state", .data = "must survive" });

    try runner.cleanupWorkspaceChildForTest(std.testing.io, &workspace, .one);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_one_home, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_one_leaf, .{}));
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_near_max_home, .{});
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_near_max_leaf, .{});
    try dir.access(std.testing.io, "foreign-session-state", .{});

    try runner.cleanupWorkspaceChildForTest(std.testing.io, &workspace, .near_max);
    try dir.deleteFile(std.testing.io, "foreign-session-state");
    try workspace.cleanup();
}
