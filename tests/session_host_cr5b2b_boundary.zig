//! CR5b-2b host-wide shared Client replacement boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5b-2b 경계는 all-runtime terminal 뒤 shared Client exact once publication만 연다" {
    const allocator = std.testing.allocator;
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const screen = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(screen);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "shared_replacement_reserved = 15,",
        "shared_replacement_published = 16,",
        "pub fn prepareHostReconnectSharedReplacement(",
        "pub fn commitHostReconnectSharedReplacement(",
        "test \"CR5b-2b host job은",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(backend, needle));

    const prepare = between(
        backend,
        "pub fn prepareHostReconnectSharedReplacement(",
        "pub fn commitHostReconnectSharedReplacement(",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "adapter.prepareAdmissionClose(",
        "adapter.prepareRetirementCleanup(",
        "adapter.reserveClientReplacementNode(",
        "adapter.abortReservedClientReplacementNode(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(prepare, needle));
    try std.testing.expectEqual(@as(usize, 0), count(prepare, "commitHostWideRetirementNoFail("));

    const commit = between(
        backend,
        "pub fn commitHostReconnectSharedReplacement(",
        "/// Connected job의 fresh Client",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "RemoteRuntime.backend_api.commitHostWideRetirementNoFail(",
        "adapter.commitAdmissionClose(",
        "adapter.commitRetirementCleanupNoFail(",
        "adapter.commitRetirementDetachNoFail(",
        "adapter.finishRetirementCleanup(",
        "adapter.publishReservedClientReplacementAfterRetirementNoFail(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(commit, needle));
    inline for (.{
        ".allocator.create(",
        ".allocator.alloc(",
        "std.Thread.spawn(",
        "publishHostReconnectReplacement(",
        "publishReconnectClientReplacement(",
    }) |needle| try std.testing.expectEqual(@as(usize, 0), count(commit, needle));

    const inventory = [_]struct {
        id: []const u8,
        backend: usize = 0,
        runtime: usize = 0,
        attachment: usize = 0,
        screen: usize = 0,
        adapter: usize = 0,
        slot: usize = 0,
    }{
        .{ .id = "commitHostWideRetirementNoFail", .backend = 1, .runtime = 3 },
        .{ .id = "hostWideRetirementCommittedExact", .backend = 2, .runtime = 3 },
        .{ .id = "commitHostRetirementNoFail", .runtime = 1, .attachment = 1 },
        .{ .id = "hostRetirementCommittedExact", .runtime = 1, .attachment = 1 },
        .{ .id = "commitPreparedUnavailableNoFail", .runtime = 1, .screen = 1 },
        .{ .id = "unavailableExact", .runtime = 1, .screen = 1 },
        .{ .id = "reserveClientReplacementNode", .backend = 1, .adapter = 2, .slot = 5 },
        .{ .id = "preflightReservedClientReplacementNode", .backend = 1, .adapter = 2, .slot = 5 },
        .{ .id = "abortReservedClientReplacementNode", .backend = 2, .adapter = 2, .slot = 2 },
        .{ .id = "publishReservedClientReplacementAfterRetirementNoFail", .backend = 1, .adapter = 2, .slot = 1 },
    };
    for (inventory) |entry| {
        try std.testing.expectEqual(entry.backend, countIdentifier(backend, entry.id));
        try std.testing.expectEqual(entry.runtime, countIdentifier(runtime, entry.id));
        try std.testing.expectEqual(entry.attachment, countIdentifier(attachment, entry.id));
        try std.testing.expectEqual(entry.screen, countIdentifier(screen, entry.id));
        try std.testing.expectEqual(entry.adapter, countIdentifier(adapter, entry.id));
        try std.testing.expectEqual(entry.slot, countIdentifier(slot, entry.id));
        try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
            allocator,
            entry.id,
            &.{
                "platform/macos/session_host/remote_term_backend.zig",
                "platform/macos/session_host/remote_runtime.zig",
                "platform/macos/session_host/generation_attachment.zig",
                "platform/macos/session_host/stable_screen_source.zig",
                "platform/macos/session_host/host_adapter.zig",
                "platform/macos/session_host/client_slot.zig",
            },
        ));
    }

    const gate = between(build, "const session_host_cr5b2b_step =", "const b3_1_boundary_tests =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5b2b\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5b2b_step.dependOn(session_host_cr5b2a_step);"));
    try std.testing.expectEqual(@as(usize, 3), count(gate, "--maru-expect-tests=1"));
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
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

fn countProductIdentifiersExcept(
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
        total += countIdentifier(source, identifier);
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
