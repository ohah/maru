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

test "CR3b R2b 경계는 final cleanup handle move와 gate 밖 exact once 정산만 연다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const seal_service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_service);
    const seal_contract = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_contract);

    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const PreparedRetirementCleanup = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn prepareRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn commitRetirementCleanupNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn abortRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn finishRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "test \"CR3b R2b prepared cleanup handle은 invalid raw"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "test \"CR3b R2b cleanup receipt는 stateless allocator의 zero context를"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_contract, "pub const PreparedRetirementCleanupSealInput"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn preparedRetirementCleanupSeal("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "pub const retirement_cleanup_testing_api = if (builtin.is_test) struct"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn enterExternalMode(client: *Client)"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "client_mod.retirement_cleanup_testing_api.enterExternalMode(&slot.current.client)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime, "r2a_client_slot.testing.enterExternalMode(&adapter.slot)"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            "retirement_cleanup_testing_api",
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn publishUnavailableForClientRetirementWithCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "context.slot.commitRetirementCleanupNoFail("));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "test \"CR3b R2b cleanup"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn prepareRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn abortRetirementCleanup("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn finishRetirementCleanup("));
    for ([_]struct { needle: []const u8, expected: usize }{
        .{ .needle = "prepareRetirementCleanup(", .expected = 1 },
        // CR5b-2b owns both prepare rollback and HostReconnectJob teardown rollback.
        .{ .needle = "abortRetirementCleanup(", .expected = 2 },
        .{ .needle = "finishRetirementCleanup(", .expected = 1 },
    }) |entry| {
        const needle = entry.needle;
        try std.testing.expectEqual(entry.expected, count(backend, needle));
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductSourcesExceptFour(
                allocator,
                needle,
                "platform/macos/session_host/client_slot.zig",
                "platform/macos/session_host/host_adapter.zig",
                "platform/macos/session_host/remote_runtime.zig",
                "platform/macos/session_host/remote_term_backend.zig",
            ),
        );
    }
    for ([_][]const u8{
        "preflightRetirementCleanup(",
        "commitRetirementCleanupNoFail(",
    }) |needle| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptFour(
            allocator,
            needle,
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/host_adapter.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptSix(
            allocator,
            "PreparedRetirementCleanup",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/host_adapter.zig",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/event_cleanup_seal.zig",
            "platform/macos/session_host/process_seal_service.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "process_seal_service.preparedRetirementCleanupSeal("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "preparedRetirementCleanupSeal(",
            "platform/macos/session_host/process_seal_service.zig",
            "platform/macos/session_host/client_slot.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "publishUnavailableForClientRetirementWithCleanup(",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/client_slot.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "if (cleanup.fd >= 0) _ = c.close(cleanup.fd);"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "client.fd = -1;\n        client.pending_outbound = null;"),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        count(slot, "operation.node.client.preflightExternalAdoptionDestination("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "cleanup.external_deinit_reserved_raw > 1"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "allocator.free(bytes[0..cleanup.pending_frame_len]);"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "publishReplacementClient("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "destroyRetiredClient("));
}

fn countProductSourcesExceptThree(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path)) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countProductSourcesExceptFour(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
    fourth_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path) or
            std.mem.eql(u8, entry.path, fourth_excluded_path)) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countProductSourcesExceptFive(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
    fourth_excluded_path: []const u8,
    fifth_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path) or
            std.mem.eql(u8, entry.path, fourth_excluded_path) or
            std.mem.eql(u8, entry.path, fifth_excluded_path)) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countProductSourcesExceptSix(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
    fourth_excluded_path: []const u8,
    fifth_excluded_path: []const u8,
    sixth_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path) or
            std.mem.eql(u8, entry.path, fourth_excluded_path) or
            std.mem.eql(u8, entry.path, fifth_excluded_path) or
            std.mem.eql(u8, entry.path, sixth_excluded_path)) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
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
