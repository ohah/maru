//! CR5d boundary: CR5d-1 stays the sole contract owner while CR5d-2 first opens the backend bridge.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5d-1 경계는 sealed Window transaction과 product caller zero를 고정한다" {
    const allocator = std.testing.allocator;
    const contract_path = "src/platform/macos/session_host/host_reconnect_window_transaction.zig";
    const contract = try readSource(allocator, contract_path);
    defer allocator.free(contract);
    const seal = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal);
    const service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(service);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);

    inline for (.{
        "pub const WindowBinding = struct {",
        "pub const ActionRequest = struct {",
        "pub const Owner = struct {",
        "pub const Transaction = struct {",
        "pub fn prepare(",
        "pub fn validate(",
        "pub fn consume(",
        "pub fn recycleConsumed(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(contract, needle));
    try std.testing.expectEqual(@as(usize, 3), count(contract, "test \"CR5d-1 Window transaction은"));
    try std.testing.expectEqual(@as(usize, 1), count(seal, "pub const HostReconnectWindowTransactionSealInput = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(seal, "pub const HostReconnectWindowOwnerSealInput = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(service, "pub fn hostReconnectWindowTransactionSeal("));
    try std.testing.expectEqual(@as(usize, 1), count(service, "pub fn hostReconnectWindowOwnerSeal("));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(service, "HostReconnectWindowTransactionSealInput"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(contract, "hostReconnectWindowTransactionSeal"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "host_reconnect_window_transaction", &.{
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/app_session/session_host_window.zig",
            "platform/macos/session_host.zig",
        }),
    );
    // CR5d-2 validates the consumed lifecycle and target before shrinking the terminal host job.
    try std.testing.expectEqual(@as(usize, 31), countIdentifier(backend, "host_reconnect_window_transaction"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn prepareHostReconnectWindowTransaction("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn consumeHostReconnectWindowTransaction("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "hostReconnectWindowTransactionSeal", &.{
            "platform/macos/session_host/host_reconnect_window_transaction.zig",
            "platform/macos/session_host/process_seal_service.zig",
        }),
    );

    const gate = between(build, "const session_host_cr5d1_step =", "const session_host_cr5d2_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5d1\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5d1_step.dependOn(session_host_cr5c_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=3"));
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
