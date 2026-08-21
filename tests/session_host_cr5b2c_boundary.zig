//! CR5b-2c ordered per-runtime transaction and terminal-summary boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5b-2c 경계는 shared Client 아래 ordered runtime transaction과 terminal summary만 연다" {
    const allocator = std.testing.allocator;
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const contract = try readSource(
        allocator,
        "src/platform/macos/session_host/host_reconnect_runtime_transaction.zig",
    );
    defer allocator.free(contract);
    const seal = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "runtime_transactions_complete = 17,",
        "runtime_cursor: host_reconnect_runtime_transaction.Cursor = .{},",
        "terminal_summary: ?host_reconnect_runtime_ledger.TerminalSummary = null,",
        "pub fn beginNextHostReconnectRuntimeTransaction(",
        "pub fn completeHostReconnectRuntimeTransactions(",
        "pub fn failHostReconnectRuntimeTransactions(",
        "test \"CR5b-2c actual host job은 shared Client 하나로 three-runtime을 순서대로 게시한다\"",
        "test \"CR5b-2c actual host job은 kth failure에서 앞선 publication을 보존하고 suffix를 닫는다\"",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(backend, needle));
    try std.testing.expectEqual(@as(usize, 3), count(contract, "test \"CR5b-2c cursor는"));

    inline for (.{
        "runtime_cursor_next_index: u32,",
        "runtime_cursor_terminal_count: u32,",
        "runtime_cursor_failed_raw: u8,",
        "terminal_summary_digest: Digest,",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(seal, needle));

    const publish = between(
        backend,
        "pub fn publishHostReconnectGeneration(",
        "fn finishHostReconnectTakeoverOutcome(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(publish, "publishReconnectPromotedCandidateRetainingSharedClient("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(publish, "commitPublishedNew("));
    inline for (.{ ".allocator.create(", ".allocator.alloc(", "std.Thread.spawn(" }) |needle|
        try std.testing.expectEqual(@as(usize, 0), count(publish, needle));

    const complete = between(
        backend,
        "pub fn completeHostReconnectRuntimeTransactions(",
        "/// Closes the active row",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(complete, "finishSuccess("));
    try std.testing.expectEqual(@as(usize, 1), count(complete, "settleHostReconnectSharedRetirementNoFail("));
    const failure = between(
        backend,
        "pub fn failHostReconnectRuntimeTransactions(",
        "/// A terminal shared transport invalidates every runtime",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(failure, "failAndResolveRemaining("));
    inline for (.{ ".allocator.create(", ".allocator.alloc(", "std.Thread.spawn(" }) |needle| {
        try std.testing.expectEqual(@as(usize, 0), count(complete, needle));
        try std.testing.expectEqual(@as(usize, 0), count(failure, needle));
    }

    const inventory = [_]struct { id: []const u8, backend: usize, runtime: usize }{
        .{ .id = "publishReconnectPromotedCandidateRetainingSharedClient", .backend = 1, .runtime = 1 },
        .{ .id = "reclaimHostWideRetiringGenerationRetainingClient", .backend = 1, .runtime = 1 },
        // CR5c adds the all-row host-failure terminal identity validation.
        .{ .id = "hostReconnectTerminalIdentityExact", .backend = 3, .runtime = 1 },
    };
    for (inventory) |entry| {
        try std.testing.expectEqual(entry.backend, countIdentifier(backend, entry.id));
        try std.testing.expectEqual(entry.runtime, countIdentifier(runtime, entry.id));
        try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
            allocator,
            entry.id,
            &.{
                "platform/macos/session_host/remote_term_backend.zig",
                "platform/macos/session_host/remote_runtime.zig",
            },
        ));
    }

    const cursor_inventory = [_]struct { id: []const u8, contract: usize, backend: usize }{
        // CR5c adds one cursor setup publication before terminalizing the shared Client.
        .{ .id = "commitPublishedNew", .contract = 5, .backend = 1 },
        .{ .id = "failAndResolveRemaining", .contract = 4, .backend = 1 },
        .{ .id = "finishSuccess", .contract = 3, .backend = 1 },
    };
    for (cursor_inventory) |entry| {
        try std.testing.expectEqual(entry.contract, countIdentifier(contract, entry.id));
        try std.testing.expectEqual(entry.backend, countIdentifier(backend, entry.id));
        try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
            allocator,
            entry.id,
            &.{
                "platform/macos/session_host/host_reconnect_runtime_transaction.zig",
                "platform/macos/session_host/remote_term_backend.zig",
            },
        ));
    }

    const gate = between(build, "const session_host_cr5b2c_step =", "const session_host_cr5c_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5b2c\""));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(gate, "session_host_cr5b2c_step.dependOn(session_host_cr5b2b_step);"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=3"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));
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
