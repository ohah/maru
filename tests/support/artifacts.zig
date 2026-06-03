const std = @import("std");

pub fn writeText(path: []const u8, contents: []const u8) !void {
    // Test artifacts are deliberately local files. They make failures easier
    // to inspect without turning debug output into committed fixtures.
    try ensureParent(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

pub fn writeTextWithFinalNewline(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    // Screen dumps are easier to inspect in terminals and editors when the
    // artifact file ends with a newline. The comparison logic can still keep
    // exact screen contents separate from this file-format convenience.
    const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{contents});
    defer allocator.free(with_newline);

    try writeText(path, with_newline);
}

fn ensureParent(path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash == 0) return;
        try std.Io.Dir.cwd().createDirPath(std.testing.io, path[0..slash]);
    }
}
