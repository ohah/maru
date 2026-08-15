const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 16 * 1024 * 1024;

test "2c3e C1 경계는 decoder borrow를 scoped owner와 C2 제품 caller 하나로 제한한다" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    var decoder_facade_declarations: usize = 0;
    var decoder_product_calls: usize = 0;
    var client_decoder_declarations: usize = 0;
    var client_decoder_calls: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(
            std.testing.io,
            entry.path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        const facade_count = countIdentifierOutsideTopLevelTests(source, "executePreparedRequestWithDecoderOwned");
        const client_count = countIdentifierOutsideTopLevelTests(source, "executeGenerationRpcDecoded");
        if (isSessionHostPath(entry.path, "generation_transport.zig")) {
            decoder_facade_declarations += facade_count;
            client_decoder_calls += client_count;
        } else {
            decoder_product_calls += facade_count;
            if (isSessionHostPath(entry.path, "client_slot.zig"))
                client_decoder_declarations += client_count
            else
                client_decoder_calls += client_count;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), decoder_facade_declarations);
    try std.testing.expectEqual(@as(usize, 1), decoder_product_calls);
    try std.testing.expectEqual(@as(usize, 1), client_decoder_declarations);
    try std.testing.expectEqual(@as(usize, 1), client_decoder_calls);

    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const facade = sliceBetween(
        transport,
        "pub fn executePreparedRequestWithDecoderOwned(",
        "/// Package-level attachment seam.",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "RpcExecutedResponse",
        "RpcResponseBorrow",
        "RpcResponseFinishTxn",
        "client_mod.Client",
        "std.mem.Allocator",
        "[]u8",
    }) |forbidden| try std.testing.expectEqual(@as(usize, 0), count(facade, forbidden));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "context: *anyopaque"));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "decoder: contract.RpcDecoder"));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "Error!contract.RpcDecodeDisposition"));
    const socket_fixture = sliceBetween(
        transport,
        "fn runScopedDecoderSocket(",
        "test \"2c3e C1 actual socket은 정상 응답",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(socket_fixture, "executePreparedRequestWithDecoderOwned"));

    const response = try readSource(allocator, "src/platform/macos/session_host/rpc_executed_response.zig");
    defer allocator.free(response);
    const bridge = sliceBetween(
        response,
        "pub fn decodeBorrowedRpcResponse(",
        "pub fn withBorrowedRpcResponseBytesForTest(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "callback("));
    try std.testing.expectEqual(@as(usize, 2), count(bridge, "response.liveExact"));
    try std.testing.expectEqual(@as(usize, 2), count(bridge, "borrow.exactFor"));

    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(transport, "callOwned"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(transport, "callGenerationRpc"));
    const client_slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(client_slot, "callGenerationRpc"));
}

fn isSessionHostPath(path: []const u8, basename: []const u8) bool {
    const prefix = "platform/macos/session_host/";
    return std.mem.startsWith(u8, path, prefix) and
        std.mem.eql(u8, path[prefix.len..], basename);
}

fn sliceBetween(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return null;
    return tail[0..end];
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (test_body_depth == null and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted))
            {
                result += 1;
            },
            else => {},
        }
    }
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn countIdentifier(source: []const u8, wanted: []const u8) usize {
    return count(source, wanted);
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
