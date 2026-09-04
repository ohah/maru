//! Official release baseline children execute only the Zig toolchain pinned by the tag workflow.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const toolchain = @import("release_adapter_zig_toolchain_authority");

const commit = "0123456789abcdef0123456789abcdef01234567";
const digest = "18eb450dcefda3a3c3bb7b4c4ab78376880681736c02a1c8c3254d7c72c35e72";

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{
            .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
            .run_id = 333,
            .run_attempt = 2,
        },
        .protected_tag = true,
    };
}

fn createExecutable(tmp: *std.testing.TmpDir, storage: []u8) ![:0]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zig", .data = "trusted-zig" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "zig", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(root.ptr, 0o700));
    return std.fmt.bufPrintZ(storage, "{s}", .{root});
}

fn bind(tmp: *std.testing.TmpDir, result: *toolchain.ZigToolchainAuthority, storage: []u8) ![:0]const u8 {
    const path = try createExecutable(tmp, storage);
    try toolchain.bind(context(), .{ .workflow_sha = commit.* }, path, .{ .size = 11, .sha256 = digest.* }, result);
    return path;
}

test "binds exact protected workflow toolchain and revalidates unchanged pathname" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var result: toolchain.ZigToolchainAuthority = .{};
    const path = try bind(&tmp, &result, &path_storage);
    defer result.deinit() catch unreachable;
    const view = try result.revalidate();
    try std.testing.expectEqualStrings(path, view.executable);
    try std.testing.expectEqual(@as(u64, 11), view.size);
    try std.testing.expectEqualStrings(digest, &view.sha256);
}

test "rejects copied pre-owned and foreign workflow authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try createExecutable(&tmp, &path_storage);
    var occupied: toolchain.ZigToolchainAuthority = .{};
    occupied.owner = &occupied;
    try std.testing.expectError(error.InvalidOwner, toolchain.bind(context(), .{ .workflow_sha = commit.* }, path, .{ .size = 11, .sha256 = digest.* }, &occupied));
    var invalid = context();
    invalid.protected_tag = false;
    var result: toolchain.ZigToolchainAuthority = .{};
    try std.testing.expectError(error.InvalidContext, toolchain.bind(invalid, .{ .workflow_sha = commit.* }, path, .{ .size = 11, .sha256 = digest.* }, &result));
    try std.testing.expectError(error.InvalidContext, toolchain.bind(context(), .{ .workflow_sha = "1123456789abcdef0123456789abcdef01234567".* }, path, .{ .size = 11, .sha256 = digest.* }, &result));
}

test "rejects invalid capture executable mode and symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zig", .data = "trusted-zig" });
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const raw = try tmp.dir.realPathFileAlloc(std.testing.io, "zig", std.testing.allocator);
    defer std.testing.allocator.free(raw);
    const path = try std.fmt.bufPrintZ(&path_storage, "{s}", .{raw});
    var result: toolchain.ZigToolchainAuthority = .{};
    try std.testing.expectError(error.NotExecutable, toolchain.bind(context(), .{ .workflow_sha = commit.* }, path, .{ .size = 11, .sha256 = digest.* }, &result));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
    try std.testing.expectError(error.SizeMismatch, toolchain.bind(context(), .{ .workflow_sha = commit.* }, path, .{ .size = 10, .sha256 = digest.* }, &result));
    try std.testing.expectError(error.DigestMismatch, toolchain.bind(context(), .{ .workflow_sha = commit.* }, path, .{ .size = 11, .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".* }, &result));
    try tmp.dir.symLink(std.testing.io, "zig", "alias", .{});
    var alias_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const alias = try std.fmt.bufPrintZ(&alias_storage, "{s}/alias", .{std.fs.path.dirname(path).?});
    try std.testing.expectError(error.UnsafePath, toolchain.bind(context(), .{ .workflow_sha = commit.* }, alias, .{ .size = 11, .sha256 = digest.* }, &result));
}

test "pathname bytes mode and parent drift fail revalidation" {
    const Mutation = enum { bytes, mode, parent };
    inline for (.{ Mutation.bytes, Mutation.mode, Mutation.parent }) |mutation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var result: toolchain.ZigToolchainAuthority = .{};
        const path = try bind(&tmp, &result, &path_storage);
        defer result.deinit() catch unreachable;
        switch (mutation) {
            .bytes => try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zig", .data = "changed-zig" }),
            .mode => try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o600)),
            .parent => {
                const root = std.fs.path.dirname(path).?;
                var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
                const moved = try std.fmt.bufPrintZ(&moved_storage, "{s}-moved", .{root});
                try std.Io.Dir.renameAbsolute(root, moved, std.testing.io);
                try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
                try std.testing.expectError(error.ExecutableChanged, result.revalidate());
                try std.Io.Dir.deleteDirAbsolute(std.testing.io, root);
                try std.Io.Dir.renameAbsolute(moved, root, std.testing.io);
            },
        }
        if (mutation != .parent)
            try std.testing.expectError(error.ExecutableChanged, result.revalidate());
    }
}

test "deinit closes authority and copied owner cannot revalidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var result: toolchain.ZigToolchainAuthority = .{};
    _ = try bind(&tmp, &result, &path_storage);
    var copied = result;
    try std.testing.expectError(error.InvalidOwner, copied.revalidate());
    try result.deinit();
    try std.testing.expectError(error.InvalidOwner, result.revalidate());
}
