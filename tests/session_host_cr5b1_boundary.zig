//! CR5b-1 actual backend runtime-set capture and final-address owner boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5b-1 경계는 runtime set capture를 actual connect보다 먼저 backend job 하나에 고정한다" {
    const allocator = std.testing.allocator;
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const seal = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(
        @as(usize, 1),
        count(backend, "const host_reconnect_runtime_ledger = @import(\"host_reconnect_runtime_ledger.zig\");"),
    );
    inline for (.{
        "runtime_row_count: u32 = 0,",
        "runtime_rows: [host_reconnect_runtime_ledger.max_runtime_rows]host_reconnect_runtime_ledger.RuntimeRow = undefined,",
        "runtime_rows_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,",
        "fn prepareForConnect(",
        "fn validateRuntimeSet(",
        "fn runtimeRowsDigest(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(backend, needle));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "preparing = 13,"));
    try std.testing.expectEqual(@as(usize, 2), count(backend, "test \"CR5b-1 host job"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const RuntimeSetIdentityProjection = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn reconnectRuntimeSetIdentity("));
    inline for (.{
        "runtime_row_count: u32,",
        "runtime_rows_addr: u64,",
        "runtime_rows_digest: Digest,",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(seal, needle));

    const begin = between(
        backend,
        "pub fn beginHostReconnectConnect(",
        "pub fn beginHostReconnectCandidate(",
    ) orelse return error.TestUnexpectedResult;
    const capture_pos = std.mem.indexOf(u8, begin, "job.prepareForConnect(") orelse
        return error.TestUnexpectedResult;
    const connect_pos = std.mem.indexOf(u8, begin, "host_connect.connectExistingHostUntil(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(capture_pos < connect_pos);
    try std.testing.expectEqual(@as(usize, 1), count(begin, "job.prepareForConnect("));
    try std.testing.expectEqual(@as(usize, 1), count(begin, "host_connect.connectExistingHostUntil("));

    // CR5b-2c adds ordered runtime completion; CR5c adds the all-row terminal connection
    // transition while retaining the same canonical runtime-set owner.
    // CR5d-2 reuses the sealed terminal summary/rows through the backend-private Window projection;
    // no AppSession caller receives the ledger values directly.
    // CR5d-2 adds the terminal-row shrink projection, digest and summary to the same host job owner.
    // 36 번째는 terminal summary 진단이 쓰는 타입 참조 하나다 — 원장을 **소유하지 않고** 이미 만들어진
    // 요약을 읽어 로그로 흘릴 뿐이라 이 경계가 지키려는 owner 집합은 그대로다.
    try std.testing.expectEqual(@as(usize, 36), countIdentifier(backend, "host_reconnect_runtime_ledger"));
    const backend_product = backend[0 .. std.mem.indexOf(u8, backend, "const testing = std.testing;") orelse
        return error.TestUnexpectedResult];
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(backend_product, "reconnectRuntimeSetIdentity"));
    // CR5b-2a adds one hostile oracle and CR5b-2c records prior successful rows in its product E2E.
    try std.testing.expectEqual(@as(usize, 10), countIdentifier(backend, "reconnectRuntimeSetIdentity"));
    inline for (.{ "host_reconnect_runtime_ledger", "reconnectRuntimeSetIdentity" }) |identifier|
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductIdentifiersExcept(allocator, identifier, &.{
                "platform/macos/session_host/host_reconnect_runtime_ledger.zig",
                "platform/macos/session_host/host_reconnect_runtime_transaction.zig",
                "platform/macos/session_host/host_reconnect_window_transaction.zig",
                "platform/macos/session_host/remote_term_backend.zig",
                "platform/macos/session_host/remote_runtime.zig",
            }),
        );

    const gate = between(build, "const session_host_cr5b1_step =", "const session_host_cr5b2a_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5b1\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5b1_step.dependOn(session_host_cr5a_step);"));
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
