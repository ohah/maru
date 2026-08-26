//! P4 N1 bounded notification journal source and focused-build boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "P4 N1 notification journal 경계는 pure owner와 dormant product boundary를 고정한다" {
    const allocator = std.testing.allocator;
    const journal = try readSource(allocator, "src/platform/macos/session_host/notification_journal.zig");
    defer allocator.free(journal);
    const barrel = try readSource(allocator, "src/platform/macos/session_host.zig");
    defer allocator.free(barrel);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);

    try std.testing.expectEqual(@as(usize, 1), count(barrel, "pub const notification_journal = @import(\"session_host/notification_journal.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), count(journal, "@import("));
    try std.testing.expectEqual(@as(usize, 1), count(journal, "@import(\"std\")"));
    try std.testing.expectEqual(@as(usize, 0), count(journal, "platform/"));
    try std.testing.expectEqual(@as(usize, 0), count(journal, "TerminalCore"));
    try std.testing.expectEqual(@as(usize, 0), count(journal, "AppKit"));
    try std.testing.expectEqual(@as(usize, 0), try countProductReferences(allocator));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-notification-journal\""));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "N1 bounded notification journal 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "P4 N1 bounded notification journal") != null);
}

fn countProductReferences(allocator: std.mem.Allocator) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "platform/macos/session_host.zig") or
            std.mem.eql(u8, entry.path, "platform/macos/session_host/notification_journal.zig")) continue;
        const source = try dir.readFileAllocOptions(
            std.testing.io,
            entry.path,
            allocator,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        total += count(source, "notification_journal");
    }
    return total;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}
