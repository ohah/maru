const std = @import("std");

// The focused artifact deliberately collects the two runtime tests owned by
// generation_transport.zig beside this independent source-boundary oracle.
const generation_transport_tests = @import("generation_transport_tests");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3b internal rpc substrate keeps the strict path private" {
    _ = generation_transport_tests;
    const allocator = std.testing.allocator;
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);
    const remote_runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(remote_runtime);

    const transport_product = productPrefix(transport);
    const slot_product = productPrefix(slot);
    const remote_runtime_product = productPrefix(remote_runtime);

    // The shipped attach facade remains byte-for-byte typed around ExecutedResponse.
    try std.testing.expectEqual(
        @as(usize, 1),
        count(
            transport_product,
            "pub fn executePreparedRequest(\n        self: *GenerationTransport,\n        receipt: contract.PreparedCallReceipt,\n        response_out: *executed_response_mod.ExecutedResponse,\n    ) Error!contract.ExecuteResult {",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot_product, "const ResponseDestination = union(enum) {\n    attach: *executed_response_mod.ExecutedResponse,\n    rpc: void,\n};"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot_product, "fn resolveResponseDestination("));

    // There is one private transport wrapper and one module-public, pointer-free substrate
    // entry. No second call path may bypass either ownership boundary.
    try std.testing.expectEqual(@as(usize, 1), count(transport_product, "fn executePreparedRpcSubstrate("));
    try std.testing.expectEqual(@as(usize, 0), count(transport_product, "pub fn executePreparedRpcSubstrate("));
    const substrate = between(
        transport_product,
        "fn executePreparedRpcSubstrate(",
        "comptime {",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(substrate, "client_slot_mod.executeGenerationRpcSubstrate("),
    );
    try std.testing.expectEqual(@as(usize, 0), count(substrate, "rpc_response"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot_product, "pub fn executeGenerationRpcSubstrate("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(transport_product, "client_slot_mod.executeGenerationRpcSubstrate("),
    );

    const strict_entry = between(
        slot_product,
        "pub fn executeGenerationRpcSubstrate(",
        "fn canonicalRpcResponseAddress(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(strict_entry, "executePreparedRpcPrivate("));
    try std.testing.expectEqual(@as(usize, 1), count(strict_entry, ".{ .canonical = {} }"));
    try std.testing.expectEqual(@as(usize, 0), count(strict_entry, "fail_stop_required"));
    try std.testing.expectEqual(@as(usize, 0), count(strict_entry, "return .*RpcExecutedResponse"));

    // Decoder/product integration remains out of scope: RemoteRuntime must not acquire the
    // private bridge, raw response owner, borrow, finish, reset, or slot-address vocabulary.
    inline for (.{
        "executePreparedRpcSubstrate",
        "executeGenerationRpcSubstrate",
        "RpcExecutedResponse",
        "RpcResponseBorrow",
        "RpcResponseFinishTxn",
        "rpc_response_addr",
        "rpc_response",
    }) |forbidden| try std.testing.expectEqual(
        @as(usize, 0),
        countCodeTokens(remote_runtime_product, forbidden),
    );

    // The public GenerationTransport method set is recursively checked by this comptime oracle;
    // adding a raw response owner/capability to any parameter or return fails compilation.
    try std.testing.expectEqual(@as(usize, 1), count(transport_product, "const methods = .{"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(transport_product, "if (isForbiddenFacadeType(Param))"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(transport_product, "if (isForbiddenFacadeType(Return))"),
    );
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
    );
}

fn productPrefix(source: []const u8) []const u8 {
    return source[0 .. std.mem.indexOf(u8, source, "\ntest \"") orelse source.len];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

fn countCodeTokens(source: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        result += count(line, needle);
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
