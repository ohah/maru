//! GUI와 public CLI가 공유하는 Maru cache base 순수 정책.

const std = @import("std");

pub fn maruBaseAlloc(
    allocator: std.mem.Allocator,
    xdg_cache_home: ?[]const u8,
    home: ?[]const u8,
) std.mem.Allocator.Error!?[]u8 {
    if (xdg_cache_home) |xdg| if (xdg.len != 0)
        return try std.fmt.allocPrint(allocator, "{s}/maru", .{std.mem.trimEnd(u8, xdg, "/")});
    const value = home orelse return null;
    if (value.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}/.cache/maru", .{std.mem.trimEnd(u8, value, "/")});
}

test "Maru cache base normalizes XDG and HOME identically" {
    const xdg = (try maruBaseAlloc(std.testing.allocator, "/tmp/cache/", "/home/me")).?;
    defer std.testing.allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/cache/maru", xdg);
    const home = (try maruBaseAlloc(std.testing.allocator, null, "/home/me/")).?;
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("/home/me/.cache/maru", home);
    try std.testing.expect((try maruBaseAlloc(std.testing.allocator, null, null)) == null);
}
