//! One-file CLI adapter for the existing app URL contract. Filesystem and process
//! effects stay in main; the app remains the authority for opening the descriptor.
const std = @import("std");
const app_url = @import("../../session/editor_app_url.zig");

pub const help =
    \\usage: maru editor open <file> [-l N | --line N] [-c N | --column N]
    \\       maru editor open [-l N | --line N] [-c N | --column N] -- <file>
    \\
    \\Open one file in the default Maru app (macOS).
    \\Line and UTF-16 column are one-based; column requires line.
    \\Success confirms OS delivery, not that the app opened the file.
    \\
;
pub const Request = struct { path: []const u8, line: ?u32 = null, column: ?u32 = null };
pub const Command = union(enum) { help, request: Request };

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    var result: Request = .{ .path = "" };
    var positional = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional and std.mem.eql(u8, arg, "--")) {
            positional = true;
        } else if (!positional and (std.mem.eql(u8, arg, "--line") or std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--column") or std.mem.eql(u8, arg, "-c"))) {
            const field = if (std.mem.eql(u8, arg, "--line") or std.mem.eql(u8, arg, "-l")) &result.line else &result.column;
            if (field.* != null or i + 1 == args.len) return error.InvalidArguments;
            i += 1;
            const value = args[i];
            if (value.len == 0) return error.InvalidArguments;
            for (value) |b| if (b < '0' or b > '9') return error.InvalidArguments;
            const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
            if (n == 0) return error.InvalidArguments;
            field.* = n;
        } else {
            if ((!positional and std.mem.startsWith(u8, arg, "-")) or arg.len == 0 or result.path.len != 0) return error.InvalidArguments;
            result.path = arg;
        }
    }
    if (result.path.len == 0 or (result.column != null and result.line == null)) return error.InvalidArguments;
    return .{ .request = result };
}

pub fn buildURL(allocator: std.mem.Allocator, request: Request, cwd: []const u8) ![]u8 {
    // Joining, rather than normalizing, preserves kernel symlink/.. semantics.
    if (cwd.len == 0 or cwd[0] != '/') return error.InvalidArguments;
    const path = if (request.path.len > 0 and request.path[0] == '/')
        try allocator.dupe(u8, request.path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, request.path });
    defer allocator.free(path);
    if (path.len > app_url.max_path_bytes) return error.TooLong;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "maru://open?path=");
    const hex = "0123456789ABCDEF";
    for (path) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~') {
            try bytes.append(allocator, b);
        } else {
            try bytes.appendSlice(allocator, &.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
    if (request.line) |n| {
        var buf: [32]u8 = undefined;
        try bytes.appendSlice(allocator, try std.fmt.bufPrint(&buf, "&line={d}", .{n}));
    }
    if (request.column) |n| {
        var buf: [32]u8 = undefined;
        try bytes.appendSlice(allocator, try std.fmt.bufPrint(&buf, "&column={d}", .{n}));
    }
    // Reuse the receiver's validation so limits and UTF-8 policy cannot drift.
    var validated = try app_url.parse(allocator, bytes.items);
    defer validated.deinit(allocator);
    return bytes.toOwnedSlice(allocator);
}

test "open CLI validates options before delivery" {
    const t = std.testing;
    const req = (try parse(&.{ "--line", "42", "a", "--column", "7" })).request;
    try t.expectEqual(@as(?u32, 42), req.line);
    try t.expectEqual(@as(?u32, 7), req.column);
    try t.expectEqualStrings("-file", (try parse(&.{ "--", "-file" })).request.path);
    try t.expect((try parse(&.{"--help"})) == .help);
    const short = (try parse(&.{ "a", "-l", "42", "-c", "7" })).request;
    try t.expectEqual(req.line, short.line);
    try t.expectEqual(req.column, short.column);
    try t.expectError(error.InvalidArguments, parse(&.{ "a", "-l", "1", "--line", "2" }));
    try t.expectError(error.InvalidArguments, parse(&.{ "a", "-l", "1", "-c", "2", "--column", "3" }));
    const cases = [_][]const []const u8{ &.{}, &.{""}, &.{ "a", "b" }, &.{ "a", "--column", "1" }, &.{ "a", "--line", "0" }, &.{ "a", "--line", "-1" }, &.{ "a", "--line", "4294967296" }, &.{ "a", "--line", "+1" }, &.{ "a", "--line", "1", "--line", "2" }, &.{ "a", "--wat" }, &.{ "a", "--line" }, &.{ "--help", "a" } };
    for (cases) |args| try t.expectError(error.InvalidArguments, parse(args));
}

test "open CLI encodes exact bytes and preserves symlink traversal" {
    const t = std.testing;
    const url = try buildURL(t.allocator, .{ .path = "link/../a +%2F&#=한😀.zig", .line = 2, .column = 3 }, "/tmp");
    defer t.allocator.free(url);
    try t.expectEqualStrings("maru://open?path=%2Ftmp%2Flink%2F..%2Fa%20%2B%252F%26%23%3D%ED%95%9C%F0%9F%98%80.zig&line=2&column=3", url);
    var decoded = try app_url.parse(t.allocator, url);
    defer decoded.deinit(t.allocator);
    try t.expectEqualStrings("/tmp/link/../a +%2F&#=한😀.zig", decoded.path);
    const absolute = try buildURL(t.allocator, .{ .path = "/a" }, "/ignored");
    defer t.allocator.free(absolute);
    try t.expectEqualStrings("maru://open?path=%2Fa", absolute);
    try t.expectError(error.InvalidURL, buildURL(t.allocator, .{ .path = "a\n" }, "/tmp"));
    try t.expectError(error.InvalidURL, buildURL(t.allocator, .{ .path = "\xff" }, "/tmp"));
    try t.expectError(error.InvalidURL, buildURL(t.allocator, .{ .path = "a", .column = 1 }, "/tmp"));
}

test "open CLI allocation failures release every intermediate buffer" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const url = try buildURL(a, .{ .path = "a %한", .line = 1 }, "/tmp");
            defer a.free(url);
        }
    }.run, .{});
}

test "open CLI boundary limits and all safe filename bytes roundtrip" {
    const t = std.testing;
    var path: [app_url.max_path_bytes + 1]u8 = @splat('a');
    path[0] = '/';
    const limit = try buildURL(t.allocator, .{ .path = path[0..app_url.max_path_bytes], .line = std.math.maxInt(u32), .column = std.math.maxInt(u32) }, "/tmp");
    defer t.allocator.free(limit);
    try t.expectError(error.TooLong, buildURL(t.allocator, .{ .path = &path }, "/tmp"));
    for (32..127) |byte| {
        const filename = [_]u8{ '/', @intCast(byte) };
        const encoded = try buildURL(t.allocator, .{ .path = &filename }, "/tmp");
        defer t.allocator.free(encoded);
        var decoded = try app_url.parse(t.allocator, encoded);
        defer decoded.deinit(t.allocator);
        try t.expectEqualSlices(u8, &filename, decoded.path);
    }
    const metacharacters = try buildURL(t.allocator, .{ .path = "$(touch injected)`id`\"'\\" }, "/tmp");
    defer t.allocator.free(metacharacters);
    try t.expect(std.mem.indexOf(u8, metacharacters, "$") == null);
    const leading_zero = (try parse(&.{ "a", "--line", "0001" })).request;
    try t.expectEqual(@as(?u32, 1), leading_zero.line);
}
