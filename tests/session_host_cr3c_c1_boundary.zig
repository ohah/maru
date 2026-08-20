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

test "CR3c C1 경계는 Client replacement와 RemoteGeneration 승격의 단일 bridge만 연다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const stable = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(stable);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn publishUnavailableAfterAttachmentRetirement("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn prepareAfterClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn publishAfterClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(stable, "pub fn promoteUnavailableToLiveWithCommit("));
    try std.testing.expectEqual(@as(usize, 1), count(stable, "pub fn publishUnavailableFromLiveWithFallibleCommit("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetirementDetachBeforeAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetirementCleanupBeforeAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightPublishedClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn preflightPublishedClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn publishReplacementForCr3c("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn reclaimAllRetiredForCr3c("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(transport, ".connection_generation = binding_reservation.identity.connection_generation,"),
    );
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR3c C1은"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-cr3c-c1\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, ".filters = &.{\"CR3c C1은\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(build, ".filters = &.{\"CR3c C1 경계는\"}"));

    for ([_][]const u8{
        "publishUnavailableAfterAttachmentRetirement(",
        "prepareAfterClientReplacement(",
        "publishAfterClientReplacement(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "promoteUnavailableToLiveWithCommit(", &.{
            "platform/macos/session_host/stable_screen_source.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "publishUnavailableFromLiveWithFallibleCommit(", &.{
            "platform/macos/session_host/stable_screen_source.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    for ([_][]const u8{
        "preflightRetirementDetachBeforeAdmissionClose(",
        "preflightRetirementCleanupBeforeAdmissionClose(",
        "preflightClientReplacement(",
        "preflightPublishedClientReplacement(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, needle, &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
            "platform/macos/session_host/remote_runtime.zig",
            // CR4a's final-address host job revalidates the published replacement in each live
            // published/candidate/controller-ledger state; CR4b adds the two closed outcome
            // validation branches without opening another publication caller.
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    // CR5b-2b's host-wide reservation validates the shared detach/cleanup while the old
    // admission is still open; the no-fail suffix revalidates only after closing it.
    try std.testing.expectEqual(@as(usize, 1), count(backend, "preflightRetirementDetachBeforeAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "preflightRetirementCleanupBeforeAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "preflightClientReplacement("));
    // Seven product state validations, CR5b-2b hostile assertion, and CR5b-2c terminal retry row.
    try std.testing.expectEqual(@as(usize, 9), count(backend, "preflightPublishedClientReplacement("));
}
