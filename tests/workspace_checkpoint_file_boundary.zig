//! P4 C2의 platform ownership과 고정 leaf·no-follow publication을 소스 경계로 고정한다.

const std = @import("std");

test "P4 C2 경계는 macOS file adapter와 fixed sibling leaves만 연다" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/workspace_checkpoint_file.zig",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(source);
    const coordinator = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/session/workspace_checkpoint.zig",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(coordinator);

    for ([_][]const u8{
        "workspace.v1",
        ".workspace.v1.tmp",
        ".NOFOLLOW = true",
        ".EXCL = true",
        "renameat",
        "0o600",
    }) |required| try std.testing.expect(std.mem.count(u8, source, required) >= 1);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, coordinator, "workspace_checkpoint_file"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "FileManager"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "fsync"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn publish("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "pub fn publishUsing("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "pub fn publishObserved("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "@import(\"builtin\").is_test"));
}
