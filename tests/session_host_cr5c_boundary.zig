//! CR5c shared-Client terminal failure and all-runtime unavailable boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 16 * 1024 * 1024;

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

test "CR5c 경계는 shared Client terminal 뒤 all-runtime unavailable 전이 하나만 연다" {
    const allocator = std.testing.allocator;
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const contract = try readSource(allocator, "src/platform/macos/session_host/host_reconnect_runtime_transaction.zig");
    defer allocator.free(contract);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "host_failure_complete = 18,",
        "pub fn failHostReconnectRuntimeTransactionsAfterSharedClientTerminal(",
        "test \"CR5c actual host job은 shared Client terminal에서 앞선 publication까지 host-wide unavailable로 닫는다\"",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, backend, needle));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, contract, "pub fn failAllForTerminalConnection("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, contract, "test \"CR5c cursor는"),
    );
    const inventory = [_]struct { id: []const u8, contract: usize, backend: usize }{
        .{
            .id = "failAllForTerminalConnection",
            .contract = 3,
            .backend = 1,
        },
        .{
            .id = "failHostReconnectRuntimeTransactionsAfterSharedClientTerminal",
            .contract = 0,
            // CR6e-c3b2b adds the reviewed one-state frame driver caller.
            .backend = 5,
        },
    };
    for (inventory) |entry| {
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

    const transition = between(
        backend,
        "pub fn failHostReconnectRuntimeTransactionsAfterSharedClientTerminal(",
        "/// Connected job의 fresh Client",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "RemoteRuntime.backend_api.prepareHostWideRetirement(",
        "RemoteRuntime.backend_api.commitHostWideRetirementNoFail(",
        "failAllForTerminalConnection(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, transition, needle));
    const prepare_pos = std.mem.indexOf(u8, transition, "prepareHostWideRetirement(") orelse
        return error.TestUnexpectedResult;
    const commit_pos = std.mem.indexOf(u8, transition, "commitHostWideRetirementNoFail(") orelse
        return error.TestUnexpectedResult;
    const summary_pos = std.mem.indexOf(u8, transition, "failAllForTerminalConnection(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(prepare_pos < commit_pos and commit_pos < summary_pos);
    inline for (.{ ".allocator.create(", ".allocator.alloc(", "std.Thread.spawn(" }) |needle|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, transition, needle));

    const gate = between(build, "const session_host_cr5c_step =", "const session_host_cr5d1_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, gate, "\"test-session-host-cr5c\""));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, gate, "session_host_cr5c_step.dependOn(session_host_cr5b2c_step);"),
    );
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, gate, "--maru-expect-tests=1"));
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
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
