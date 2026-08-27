//! Release adapter가 pathname 검사 뒤 다시 여는 TOCTOU를 만들지 않도록 실제 fd 권위를 검증한다.
//!
//! 이 gate는 GitHub/codesign/DMG 의미를 검증하지 않는다. 외부 명령에 넘길 로컬 bytes와 summary/work-dir
//! publication이 symlink·special file·hardlink alias·기존 목적지를 통해 바뀌지 않는지만 실제 macOS FS에서 고정한다.

const std = @import("std");
const files = @import("release_adapter_files");

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

test "release adapter reads one bounded regular file through a stable descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest", .data = "canonical\n" });
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "manifest", &path_buf);
    var input = try files.readInputAlloc(std.testing.allocator, path, 10);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("canonical\n", input.bytes);
    try std.testing.expectEqual(@as(u64, 10), input.size);
    try std.testing.expectEqual(@as(usize, 64), input.sha256.len);
}

test "release adapter rejects final and intermediate symlinks plus non-regular input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "real", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real/value", .data = "x" });
    try tmp.dir.symLink(std.testing.io, "real/value", "leaf-link", .{});
    try tmp.dir.symLink(std.testing.io, "real", "dir-link", .{});
    var leaf_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var middle_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.UnsafePath, files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "leaf-link", &leaf_buf), 16));
    try std.testing.expectError(error.UnsafePath, files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "dir-link/value", &middle_buf), 16));
    try std.testing.expectError(error.NotRegular, files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "real", &dir_buf), 16));
}

test "release adapter rejects oversized input before allocating its bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large", .data = "12345" });
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.TooLarge, files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "large", &path_buf), 4));
}

test "release adapter rejects hardlink aliases by opened file identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "left", .data = "same" });
    try tmp.dir.symLink(std.testing.io, "left", "unused-link", .{});
    try std.testing.expectEqual(@as(i32, 0), std.c.linkat(tmp.dir.handle, "left", tmp.dir.handle, "right", 0));
    var left_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var right_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var left = try files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "left", &left_buf), 16);
    defer left.deinit(std.testing.allocator);
    var right = try files.readInputAlloc(std.testing.allocator, try absolute(&tmp, "right", &right_buf), 16);
    defer right.deinit(std.testing.allocator);
    try std.testing.expectError(error.PathAlias, files.requireDistinct(&.{ left.identity, right.identity }));
}

test "release adapter publishes summary and work directory only to absent destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var summary_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var work_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const summary = try absolute(&tmp, "summary.json", &summary_buf);
    const work = try absolute(&tmp, "work", &work_buf);
    try files.publishSummaryExclusive(summary, "{\"result\":\"passed\"}\n");
    try std.testing.expectError(error.DestinationExists, files.publishSummaryExclusive(summary, "replacement"));
    const previous_umask = std.c.umask(0o777);
    const work_result = files.createWorkDirExclusive(work);
    _ = std.c.umask(previous_umask);
    try work_result;
    try std.testing.expectError(error.DestinationExists, files.createWorkDirExclusive(work));
    const work_stat = try tmp.dir.statFile(std.testing.io, "work", .{});
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(work_stat.permissions.toMode() & 0o777)));
    const read = try tmp.dir.readFileAlloc(std.testing.io, "summary.json", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("{\"result\":\"passed\"}\n", read);
    const stat = try tmp.dir.statFile(std.testing.io, "summary.json", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim", .data = "untouched" });
    try tmp.dir.symLink(std.testing.io, "victim", "linked-summary", .{});
    try tmp.dir.symLink(std.testing.io, "victim", "linked-work", .{});
    var linked_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.DestinationExists, files.publishSummaryExclusive(try absolute(&tmp, "linked-summary", &linked_buf), "replacement"));
    var linked_work_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.DestinationExists, files.createWorkDirExclusive(try absolute(&tmp, "linked-work", &linked_work_buf)));
    const victim = try tmp.dir.readFileAlloc(std.testing.io, "victim", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(victim);
    try std.testing.expectEqualStrings("untouched", victim);
}
