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

fn countProductSourcesExcept(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded: []const []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        var skip = false;
        for (excluded) |path| {
            if (std.mem.eql(u8, entry.path, path)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

test "CR3b R2c 경계는 final Client node와 current generation 원자 게시만 연다" {
    const allocator = std.testing.allocator;
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const seal_service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_service);
    const seal_contract = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_contract);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const PreparedClientReplacement = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn prepareClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn abortClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn publishClientReplacementNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn publishClientSlotReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn clientReplacementCandidateDigest("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "const next_generation = std.math.add(u64, expected_generation, 1)"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "source.fd < 0 or source.unusable"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, ".connection_generation = self.current.connection_generation"),
    );
    try std.testing.expectEqual(@as(usize, 2), count(slot, "test \"CR3b R2c replacement은"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_contract, "pub const PreparedClientReplacementSealInput"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn preparedClientReplacementSeal("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn reclaimPublishedRetiredForTest("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "pub fn prepareDetachedCleanupForReplacementForTest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "retired: [max_retired_clients]?*ClientNode"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "test \"CR3b R2c HostAdapter facade는"));

    for ([_][]const u8{
        "prepareClientReplacement(",
        "abortClientReplacement(",
        "publishClientReplacementNoFail(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "prepareClientReplacement("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "publishClientReplacementNoFail("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "destroyRetiredClient("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "preparedClientReplacementSeal(", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/process_seal_service.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "reclaimPublishedRetiredForTest(", &.{
            "platform/macos/session_host/client_slot.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareDetachedCleanupForReplacementForTest(", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
        }),
    );
}
