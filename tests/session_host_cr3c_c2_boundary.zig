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

fn between(source: []const u8, start: []const u8, end: []const u8) []const u8 {
    const begin = std.mem.indexOf(u8, source, start) orelse @panic("missing start marker");
    const finish_relative = std.mem.indexOf(u8, source[begin + start.len ..], end) orelse
        @panic("missing end marker");
    return source[begin .. begin + start.len + finish_relative];
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
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

test "CR3c C2 경계는 matching RemoteGeneration 뒤 retired Client 회수만 연다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const runtime_product = runtime[0..std.mem.indexOf(u8, runtime, "const testing = std.testing;").?];
    const slot = try readSource(allocator, "src/platform/macos/session_host/reconnect_generation_slot.zig");
    defer allocator.free(slot);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const PreparedRetiringReclaim = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn prepareRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn retiringPayload("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn commitRetiringReclaimInPlaceNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const PreparedOrderedRetiringReclaim = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn prepareOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn preflightOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn commitOrderedRetiringReclaimAtTickEndNoFail("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "prepareOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "preflightOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "commitOrderedRetiringReclaimAtTickEndNoFail("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "prepareRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "preflightRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 3), count(runtime_product, "retiringPayload("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "commitRetiringReclaimInPlaceNoFail("));
    const ordered_prepare = between(
        runtime_product,
        "pub fn prepareOrderedRetiringReclaim(",
        "pub fn preflightOrderedRetiringReclaim(",
    );
    try std.testing.expectEqual(@as(usize, 1), count(ordered_prepare, "self.slot.prepareRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(ordered_prepare, "self.slot.retiringPayload("));
    const ordered_preflight = between(
        runtime_product,
        "pub fn preflightOrderedRetiringReclaim(",
        "pub fn commitOrderedRetiringReclaimAtTickEndNoFail(",
    );
    try std.testing.expectEqual(@as(usize, 1), count(ordered_preflight, "self.slot.preflightRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(ordered_preflight, "self.slot.retiringPayload("));
    const ordered_commit = between(
        runtime_product,
        "pub fn commitOrderedRetiringReclaimAtTickEndNoFail(",
        "pub fn reclaimRetiringAtTickEnd(",
    );
    try std.testing.expectEqual(@as(usize, 1), count(ordered_commit, "self.preflightOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(ordered_commit, "self.slot.commitRetiringReclaimInPlaceNoFail("));
    const tick_leaf = between(
        runtime_product,
        "pub fn reclaimRetiringAtTickEnd(",
        "pub fn deinit(self: *ReconnectGenerationOwner)",
    );
    try std.testing.expectEqual(@as(usize, 1), count(tick_leaf, "self.slot.prepareRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(tick_leaf, "self.slot.retiringPayload("));
    try std.testing.expectEqual(@as(usize, 1), count(tick_leaf, "self.slot.commitRetiringReclaimInPlaceNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(tick_leaf, "self.prepareOrderedRetiringReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(tick_leaf, "self.commitOrderedRetiringReclaimAtTickEndNoFail("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR3c C2는"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.slot.commitRetiringReclaimInPlaceNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "adapter.commitRetiredClientReclaimAtTickEndNoFail("));
    const remote_commit = std.mem.indexOf(u8, runtime, "self.slot.commitRetiringReclaimInPlaceNoFail(").?;
    const client_commit = std.mem.indexOf(u8, runtime, "adapter.commitRetiredClientReclaimAtTickEndNoFail(").?;
    try std.testing.expect(remote_commit < client_commit);
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "self.slot.commitRetiredClientReclaimNoFail("));

    for ([_][]const u8{
        "prepareOrderedRetiringReclaim(",
        "preflightOrderedRetiringReclaim(",
        "commitOrderedRetiringReclaimAtTickEndNoFail(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    for ([_][]const u8{
        "prepareRetiringReclaim(",
        "preflightRetiringReclaim(",
        "retiringPayload(",
        "commitRetiringReclaimInPlaceNoFail(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/reconnect_generation_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn reclaimRetiringAtTickEnd("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "try owner.reclaimRetiringAtTickEnd()"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "try owner.reclaimRetiringAtTickEnd()"));
    const c2_fixture = between(
        runtime,
        "fn runCr3cC1PublicationCase(",
        "test \"CR3c C1은",
    );
    try std.testing.expectEqual(@as(usize, 1), count(c2_fixture, "try executor.completeJob(&owner,"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-cr3c-c2\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, ".filters = &.{\"CR3c C2는\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build, ".filters = &.{\"CR3c C2 경계는\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "CR3c C2 ordered RemoteGeneration and retired Client reclaim gates"));
}
