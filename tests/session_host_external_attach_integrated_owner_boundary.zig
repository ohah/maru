//! P5c3c-3b integrated-owner dependency and caller boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 8 * 1024 * 1024;

test "p5c3c-3b boundary scanner admits the shared 8 MiB source budget" {
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), max_source_bytes);
}

test "p5c3c-3b boundary keeps one integrated owner and exactly one product CLI caller" {
    const allocator = std.testing.allocator;
    const owner = try read(allocator, "src/platform/macos/session_host/external_loop_owner.zig");
    defer allocator.free(owner);
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const IntegratedStackOwner = struct"));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "@import(\"client.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, ".pump.admitTx("));
    try std.testing.expectEqual(@as(usize, 1), try countProductIdentifierExcept(
        allocator,
        "IntegratedStackOwner",
        &.{
            "platform/macos/session_host.zig",
            "platform/macos/session_host/external_loop_owner.zig",
        },
    ));
    const caller = try read(
        allocator,
        "src/platform/macos/session_host/external_attach_cli.zig",
    );
    defer allocator.free(caller);
    try std.testing.expectEqual(@as(usize, 1), count(caller, "IntegratedStackOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(caller, "external_attach.prepare("));
    try std.testing.expectEqual(@as(usize, 1), count(caller, ".prepareInPlace("));
    try std.testing.expectEqual(@as(usize, 1), count(caller, ".commit()"));
    try std.testing.expectEqual(@as(usize, 1), count(caller, ".run(io)"));
    const main = try read(allocator, "src/main.zig");
    defer allocator.free(main);
    try std.testing.expectEqual(
        @as(usize, 1),
        count(main, "std.mem.eql(u8, command, \"attach\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(main, "session_host_attach_cli.runRequest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(main, "maru attach [--read-only | --take-over] <32-lower-hex-runtime-id>"),
    );
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
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
