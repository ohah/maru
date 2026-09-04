const std = @import("std");
const authority = @import("release_adapter_source_directory_authority");

const commit = "0123456789abcdef0123456789abcdef01234567";

fn bootstrap(source_root: []const u8) authority.Bootstrap {
    var result: authority.Bootstrap = .{};
    result.command = .{ .publish_candidate = .{
        .repo = "ohah/maru",
        .tag = "v1.2.3",
        .test_uuid = "123e4567-e89b-42d3-a456-426614174000",
        .dmg = "/tmp/dmg",
        .frozen_executable = "/tmp/exe",
        .dmg_work = "/tmp/dmg-work",
        .baseline_workspace = "/tmp/baseline",
        .app_main_executable = "/tmp/app-main",
        .app_cli_executable = "/tmp/app-cli",
        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
        .source_root = source_root,
        .zig = "/tmp/zig",
        .zig_size = 123,
        .zig_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    } };
    result.context = .{
        .repository = .{ .owner = "ohah", .name = "maru", .id = 1 },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 },
        .protected_tag = true,
    };
    @memcpy(&result.runner.workflow_sha, commit);
    result.cli_path_storage[0] = 0;
    return result;
}

const Lookup = struct {
    value: ?[]const u8,
    calls: usize = 0,

    pub fn get(self: *@This(), name: [:0]const u8) ?[]const u8 {
        self.calls += 1;
        if (!std.mem.eql(u8, name, authority.required_name)) return null;
        return self.value;
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "trusted workspace binds one held same-uid directory and closes it exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "checkout/nested");
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "checkout/nested", &path_storage);
    var lookup = Lookup{ .value = path };
    var source: authority.SourceDirectory = .{};
    var trusted = bootstrap(path);
    trusted.owner = &trusted;
    try authority.prepare(&source, &trusted, &lookup);
    const value = try source.value();
    try std.testing.expectEqual(@as(usize, 1), lookup.calls);
    try std.testing.expectEqualStrings(commit, &value.source_commit);
    try std.testing.expect(std.c.fcntl(value.fd, std.c.F.GETFD, @as(c_int, 0)) & std.c.FD_CLOEXEC != 0);
    try source.revalidate(&trusted);
    var copied = source;
    try std.testing.expectError(error.InvalidOwner, copied.value());
    copied.owner = &copied;
    try std.testing.expectError(error.InvalidOwner, copied.value());
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try source.revalidate(&trusted);
    const held = value.fd;
    try source.deinit();
    try std.testing.expect(std.c.fcntl(held, std.c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectError(error.InvalidOwner, source.deinit());
}

test "identity and exact workspace mismatch fail before filesystem publication" {
    var source: authority.SourceDirectory = .{};
    var lookup = Lookup{ .value = "/tmp/other" };
    var trusted = bootstrap("/tmp/source");
    trusted.owner = &trusted;
    try std.testing.expectError(error.WorkspaceMismatch, authority.prepare(&source, &trusted, &lookup));
    try std.testing.expect(source.owner == null and source.fd < 0);
    trusted.runner.workflow_sha[0] = 'f';
    lookup = .{ .value = "/tmp/source" };
    try std.testing.expectError(error.SourceMismatch, authority.prepare(&source, &trusted, &lookup));
    try std.testing.expect(source.owner == null and source.fd < 0);
    trusted = bootstrap("/tmp/source");
    trusted.owner = &trusted;
    lookup = .{ .value = null };
    try std.testing.expectError(error.MissingKey, authority.prepare(&source, &trusted, &lookup));
    var copied = trusted;
    try std.testing.expectError(error.InvalidBootstrap, authority.prepare(&source, &copied, &lookup));
    trusted.cli_path_len = trusted.cli_path_storage.len;
    try std.testing.expectError(error.InvalidBootstrap, authority.prepare(&source, &trusted, &lookup));
    trusted.cli_path_len = 0;
    trusted.cli_path_storage[0] = 'x';
    try std.testing.expectError(error.InvalidBootstrap, authority.prepare(&source, &trusted, &lookup));
}

test "malformed symlink and non-directory paths publish no owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "real/dir");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "x" });
    try tmp.dir.symLink(std.testing.io, "real", "linked", .{});
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var source: authority.SourceDirectory = .{};
    for ([_][]const u8{ "relative", "/", "/tmp/../source", "/tmp/source/", "/tmp/\nsource" }) |path| {
        var lookup = Lookup{ .value = path };
        var trusted = bootstrap(path);
        trusted.owner = &trusted;
        try std.testing.expectError(error.InvalidPath, authority.prepare(&source, &trusted, &lookup));
    }
    for ([_][]const u8{ "linked/dir", "file" }) |leaf| {
        const path = try absolute(&tmp, leaf, &path_storage);
        var lookup = Lookup{ .value = path };
        var trusted = bootstrap(path);
        trusted.owner = &trusted;
        try std.testing.expectError(error.OpenFailed, authority.prepare(&source, &trusted, &lookup));
        try std.testing.expect(source.owner == null and source.fd < 0);
    }
}

test "final-address copied pre-owned and aliased storage are rejected" {
    var source: authority.SourceDirectory = .{};
    source.owner = &source;
    var lookup = Lookup{ .value = "/tmp/source" };
    var trusted = bootstrap("/tmp/source");
    trusted.owner = &trusted;
    try std.testing.expectError(error.InvalidOwner, authority.prepare(&source, &trusted, &lookup));
    try std.testing.expectEqual(@as(usize, 0), lookup.calls);
    source = .{};
    const alias = source.path_storage[0..11];
    @memcpy(alias, "/tmp/source");
    lookup = .{ .value = alias };
    trusted = bootstrap(alias);
    trusted.owner = &trusted;
    try std.testing.expectError(error.InvalidOwner, authority.prepare(&source, &trusted, &lookup));
    source = .{};
    trusted = bootstrap("/tmp/source");
    trusted.context.source_commit = source.path_storage[0..40];
    trusted.owner = &trusted;
    lookup = .{ .value = "/tmp/source" };
    try std.testing.expectError(error.InvalidOwner, authority.prepare(&source, &trusted, &lookup));
}

test "pathname replacement cannot retarget held directory authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "checkout", .default_dir);
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "checkout", &path_storage);
    var lookup = Lookup{ .value = path };
    var source: authority.SourceDirectory = .{};
    var trusted = bootstrap(path);
    trusted.owner = &trusted;
    try authority.prepare(&source, &trusted, &lookup);
    const before = try source.value();
    try tmp.dir.rename("checkout", tmp.dir, "held", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "checkout", .default_dir);
    try source.revalidate(&trusted);
    const after = try source.value();
    try std.testing.expectEqual(before.identity.device, after.identity.device);
    try std.testing.expectEqual(before.identity.inode, after.identity.inode);
    try source.deinit();
}
