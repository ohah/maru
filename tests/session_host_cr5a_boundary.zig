//! CR5a canonical multi-runtime ledger contract and CR5b backend-owner consumer boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5a 경계는 CR2e enum을 재사용한 canonical runtime-set contract와 backend owner를 고정한다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/host_reconnect_runtime_ledger.zig");
    defer allocator.free(contract);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const transaction = try readSource(
        allocator,
        "src/platform/macos/session_host/host_reconnect_runtime_transaction.zig",
    );
    defer allocator.free(transaction);

    inline for (.{
        "pub const HostJobIdentity = struct {",
        "pub const RuntimeIdentity = struct {",
        "pub const RuntimeRow = struct {",
        "pub const TerminalSummary = struct {",
        "pub fn validateCanonicalRows(",
        "pub fn summarizeTerminalRows(",
        "pub fn inputAllowed(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(contract, declaration));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const RuntimeLedger = reconnect_reducer.RuntimeLedger;"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const LocalState = reconnect_reducer.LocalState;"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const MutationState = reconnect_reducer.MutationState;"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub const max_runtime_rows: usize = protocol.max_inventory_runtimes;"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "    job: HostJobIdentity,"));
    try std.testing.expectEqual(@as(usize, 2), count(contract, "std.meta.eql(row.identity.job, job)"));
    try std.testing.expectEqual(@as(usize, 4), count(contract, "test \"CR5a runtime ledger는"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "summarizeTerminalRows", &.{
            "platform/macos/session_host/host_reconnect_runtime_ledger.zig",
            "platform/macos/session_host/host_reconnect_runtime_transaction.zig",
            "platform/macos/session_host/host_reconnect_window_transaction.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "inputAllowed",
        &.{"platform/macos/session_host/host_reconnect_runtime_ledger.zig"},
    ));
    // CR5c adds the all-row terminal-connection summary consumer to the same cursor contract.
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(transaction, "summarizeTerminalRows"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(backend, "validateCanonicalRows"));
    // CR5c validates its retained all-row terminal summary against the same canonical ledger.
    // CR5d-2 also recomputes the surviving terminal summary after one Window abandons its row.
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(backend, "summarizeTerminalRows"));
    // CR5b-2c terminal validation, CR5c all-row failure, and CR5d-2's private Window projection
    // plus terminal-row shrink reuse this ledger owner.
    // 36 번째는 terminal summary 진단이 쓰는 타입 참조 하나다 — 원장을 **소유하지 않고** 이미 만들어진
    // 요약을 읽어 로그로 흘릴 뿐이라 이 경계가 지키려는 owner 집합은 그대로다.
    try std.testing.expectEqual(@as(usize, 36), countIdentifier(backend, "host_reconnect_runtime_ledger"));
    inline for (.{ "validateCanonicalRows", "host_reconnect_runtime_ledger.zig" }) |identifier|
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductIdentifiersExcept(allocator, identifier, &.{
                "platform/macos/session_host/host_reconnect_runtime_ledger.zig",
                "platform/macos/session_host/host_reconnect_runtime_transaction.zig",
                "platform/macos/session_host/host_reconnect_window_transaction.zig",
                "platform/macos/session_host/remote_term_backend.zig",
            }),
        );

    const gate = between(build, "const session_host_cr5a_step =", "const session_host_cr5b1_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5a\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5a_step.dependOn(session_host_cr4c_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=4"));
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
