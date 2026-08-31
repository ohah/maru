//! Bootstrap manifest bytes가 attestation 전에 descriptor-owned file로만 materialize되는지 검증한다.

const std = @import("std");
const manifest = @import("release_manifest");
const manifest_file = @import("release_adapter_github_manifest_file");

const bytes = "manifest-bytes";
const digest = "7abe730d8933f3f50dfd2b5e4d8be28fb52cad62481446b6f59860f6be7bed09";

fn observed() manifest_file.Input {
    return .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = digest, .bytes = bytes };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

test "manifest file materializes exact read-only bytes and cleanup removes owned workdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path_buf), observed());
    const result = file.observation() orelse return error.MissingObservation;
    try std.testing.expect(std.mem.endsWith(u8, result.path, "work/Maru-1.2.3-session-host-release.json"));
    try std.testing.expectEqual(@as(u64, bytes.len), result.size);
    try std.testing.expectEqualStrings(digest, result.sha256);
    try std.testing.expect(result.device != 0 and result.inode != 0);
    const read = try tmp.dir.readFileAlloc(std.testing.io, "work/Maru-1.2.3-session-host-release.json", std.testing.allocator, .limited(manifest.max_manifest_bytes));
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings(bytes, read);
    const stat = try tmp.dir.statFile(std.testing.io, "work/Maru-1.2.3-session-host-release.json", .{});
    try std.testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try file.cleanup();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
}

test "manifest file is move-only cleanup authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path_buf), observed());
    var copied = file;
    try std.testing.expect(copied.observation() == null);
    try std.testing.expectError(error.CleanupFailed, copied.cleanup());
    try file.cleanup();
}

test "manifest file rejects malformed bootstrap observations before filesystem publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "work", &path_buf);
    const cases = [_]manifest_file.Input{
        .{ .name = "foreign.json", .sha256 = digest, .bytes = bytes },
        .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = "ABC", .bytes = bytes },
        .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = digest, .bytes = "" },
        .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = digest, .bytes = "manifest-byteS" },
    };
    for (cases) |value| {
        var file: manifest_file.ManifestFile = .{};
        try std.testing.expectError(error.InvalidObserved, manifest_file.materialize(&file, path, value));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
    }
}

test "manifest file rejects occupied directory and symlink destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "occupied", .default_dir);
    var occupied_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try std.testing.expectError(error.DestinationExists, manifest_file.materialize(&file, try absolute(&tmp, "occupied", &occupied_buf), observed()));
    try tmp.dir.symLink(std.testing.io, "occupied", "linked", .{});
    var linked_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.DestinationExists, manifest_file.materialize(&file, try absolute(&tmp, "linked", &linked_buf), observed()));
}

test "manifest file rejects oversized bytes without residue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var oversized: [manifest.max_manifest_bytes + 1]u8 = @splat('x');
    var file: manifest_file.ManifestFile = .{};
    try std.testing.expectError(error.InvalidObserved, manifest_file.materialize(&file, try absolute(&tmp, "work", &path_buf), .{
        .name = "Maru-1.2.3-session-host-release.json",
        .sha256 = digest,
        .bytes = &oversized,
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
}
