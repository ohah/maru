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

test "CR3b R3 경계는 cap 2 oldest tick reclaim과 dormant facade만 연다" {
    const allocator = std.testing.allocator;
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const seal_service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_service);
    const seal_contract = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_contract);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const adapter_tests_start = std.mem.indexOf(u8, adapter, "test \"") orelse
        return error.MissingHostAdapterTests;
    const adapter_product = adapter[0..adapter_tests_start];
    const build_step_start = std.mem.indexOf(
        u8,
        build,
        "const session_host_cr3b_r3_step = b.step(",
    ) orelse return error.MissingR3BuildStep;
    const build_step_end = std.mem.indexOfPos(
        u8,
        build,
        build_step_start,
        "const session_host_cr3c_c1_step = b.step(",
    ) orelse return error.MissingR3BuildStepEnd;
    const build_step = build[build_step_start..build_step_end];
    const can_retire_start = std.mem.indexOf(
        u8,
        client,
        "pub fn canRetireFromGenerationNode(",
    ) orelse return error.MissingCanRetire;
    const can_retire_end = std.mem.indexOfPos(
        u8,
        client,
        can_retire_start,
        "fn finishDeinitGraph(",
    ) orelse return error.MissingFinishDeinitGraph;
    const can_retire = client[can_retire_start..can_retire_end];
    const cr5b_reserve_start = std.mem.indexOf(
        u8,
        slot,
        "pub fn reserveClientReplacementNode(",
    ) orelse return error.MissingCr5bReservation;
    const cr5b_reserve_end = std.mem.indexOfPos(
        u8,
        slot,
        cr5b_reserve_start,
        "pub fn preflightReservedClientReplacementNode(",
    ) orelse return error.MissingCr5bReservationEnd;
    const cr5b_reserve = slot[cr5b_reserve_start..cr5b_reserve_end];

    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const max_retired_clients: usize = 2;"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "retired: [max_retired_clients]?*ClientNode"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn overlapsRetiredNode("));
    try std.testing.expectEqual(@as(usize, 7), count(slot, "self.overlapsRetiredNode("));
    try std.testing.expectEqual(@as(usize, 3), count(cr5b_reserve, "self.overlapsRetiredNode("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn canRetireFromGenerationNode("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "pub fn retirementRangeAliasesOwnedBacking("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn retirementAuthorityDigest("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn retiredClientNodeDigest("));
    try std.testing.expectEqual(@as(usize, 3), count(slot, "retiredClientNodeDigest(node)"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(can_retire, "fence.intruded(@intFromPtr(self), self.operation_fence_generation)"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(can_retire, "self.parser.bufferedBytes() != 0"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const PreparedRetiredClientReclaim = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn prepareRetiredClientReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetiredClientReclaim("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn commitRetiredClientReclaimNoFail("));
    const reclaim_commit_start = std.mem.indexOf(
        u8,
        slot,
        "pub fn commitRetiredClientReclaimNoFail(",
    ) orelse return error.MissingReclaimCommit;
    const reclaim_commit_end = std.mem.indexOfPos(
        u8,
        slot,
        reclaim_commit_start,
        "pub fn preflightRetiredClientReclaim(",
    ) orelse return error.MissingReclaimPreflight;
    const reclaim_commit = slot[reclaim_commit_start..reclaim_commit_end];
    try std.testing.expectEqual(@as(usize, 1), count(reclaim_commit, "self.node_allocator.destroy(node);"));
    try std.testing.expectEqual(@as(usize, 2), count(slot, "test \"CR3b R3 reclaim은"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "test \"CR3b R3 HostAdapter facade는"));
    try std.testing.expectEqual(
        @as(usize, 3),
        count(adapter_product, "prepareRetiredClientReclaim("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        count(adapter_product, "preflightRetiredClientReclaim("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        count(adapter_product, "commitRetiredClientReclaimAtTickEndNoFail("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(adapter_product, "self.slot.commitRetiredClientReclaimNoFail("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn reclaimAllRetiredForCr3c("));
    try std.testing.expectEqual(@as(usize, 1), count(seal_contract, "pub const PreparedRetiredClientReclaimSealInput"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn preparedRetiredClientReclaimSeal("));
    try std.testing.expectEqual(@as(usize, 1), count(build_step, "\"test-session-host-cr3b-r3\""));
    try std.testing.expectEqual(@as(usize, 1), count(build_step, ".filters = &.{\"CR3b R3 reclaim은\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build_step, ".filters = &.{\"CR3b R3 HostAdapter facade는\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build_step, ".filters = &.{\"CR3b R3 경계는\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build_step, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 2), count(build_step, "--maru-expect-tests=1"));

    for ([_][]const u8{
        "prepareRetiredClientReclaim(",
        "preflightRetiredClientReclaim(",
        "commitRetiredClientReclaimNoFail(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
            "platform/macos/session_host/remote_runtime.zig",
            // CR4a backend teardown destroys every terminal RemoteGeneration first, then drains
            // the adapter's complete retired Client inventory through this same R3 facade.
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    // CR3c2만 R3 receipt를 actual RemoteGeneration retiring owner와 조합한다.
    try std.testing.expectEqual(@as(usize, 4), count(runtime, "RetiredClientReclaim"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "destroyRetiredClient("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "canRetireFromGenerationNode(", &.{
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "retirementAuthorityDigest(", &.{
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "retirementRangeAliasesOwnedBacking(", &.{
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "preparedRetiredClientReclaimSeal(", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/process_seal_service.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "publishReplacementForGenerationForTest(", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
        }),
    );
}
