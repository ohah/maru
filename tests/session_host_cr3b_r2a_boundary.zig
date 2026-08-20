const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}

test "CR3b R2a 경계는 callback 없는 placeholder와 detached tombstone만 게시한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const proxy = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(proxy);

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn publishUnavailableForClientRetirement("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "publishUnavailableForClientRetirement(",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/client_slot.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetirementDetach("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn commitRetirementDetachNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn validateRetirementPlaceholder("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "test \"CR3b R2a Client tombstone은"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn retirementProjection(slot: *ClientSlot)"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "pub fn retirementProjection(self: *ClientSlot)"));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "pub fn publishUnavailableFromLiveWithCommit("));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "test \"CR3b R2a stable proxy reader는"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "context.slot.commitRetirementDetachNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "adapter.slot.validateRetirementPlaceholder("));
    // The third comparison is CR4a's forward-failed replacement projection. CR5b-2a adds the
    // prepare and exact-validation halves; CR5b-2b adds the committed exact projection.
    try std.testing.expectEqual(@as(usize, 6), count(runtime, ".generation => |current_adapter| if (current_adapter != adapter)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            ".retirement_lifecycle",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            ".placeholder_generation",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "finishDetachedCleanup("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "destroyRetiredClient("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "publishReplacementClient("));
}

fn countProductSourcesExceptTwo(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path)) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}
