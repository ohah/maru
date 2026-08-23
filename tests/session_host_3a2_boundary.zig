//! P5c3c-3a2 composition and dormant-product boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "p5c3c-3a2 pre-raw owner is the sole raw commit composition and remains product dormant" {
    const allocator = std.testing.allocator;
    const owner = try read(allocator, "src/platform/macos/session_host/external_pump_owner.zig");
    defer allocator.free(owner);
    const product = owner[0 .. std.mem.indexOf(u8, owner, "\ntest \"") orelse owner.len];
    try std.testing.expectEqual(@as(usize, 1), count(product, "pub const PreRawOwner = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(product, "RawTty.enterPrepared"));
    try std.testing.expectEqual(@as(usize, 3), count(product, "external_ansi.enter_bytes"));
    try std.testing.expectEqual(@as(usize, 3), count(product, "external_ansi.leave_bytes"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifierExcept(
        allocator,
        "PreRawOwner",
        &.{"platform/macos/session_host/external_pump_owner.zig"},
    ));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, identifier)) |at| {
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        offset = end;
    }
    return total;
}

fn countProductIdentifierExcept(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    excluded: []const []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const source = try dir.readFileAlloc(
            std.testing.io,
            entry.path,
            allocator,
            .limited(8 * 1024 * 1024),
        );
        defer allocator.free(source);
        total += countIdentifier(source, identifier);
    }
    return total;
}
