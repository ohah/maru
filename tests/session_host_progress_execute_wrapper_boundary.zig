const std = @import("std");
const max_source_bytes = 8 * 1024 * 1024;

test "B3-3 private wrapper is the sole progress execute integration boundary" {
    const client = try readSource("src/platform/macos/session_host/client.zig");
    defer std.testing.allocator.free(client);
    const registry = try readSource("src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer std.testing.allocator.free(registry);
    const response_authority = try readSource("src/platform/macos/session_host/rpc_response_authority.zig");
    defer std.testing.allocator.free(response_authority);
    const slot = try readSource("src/platform/macos/session_host/client_slot.zig");
    defer std.testing.allocator.free(slot);
    const transport = try readSource("src/platform/macos/session_host/generation_transport.zig");
    defer std.testing.allocator.free(transport);

    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn preparedRpcAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn executingRpcAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn reserveRpcResponseExecution("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn rollbackRpcResponseExecution("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn settleRpcResponseExecutionTerminal("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn exhaustRpcResponseEpochForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn rpcExecutionAuthoritiesTerminalForTest("));
    // 기존 일곱 seam과 C3-3b3 registry fixture helper 세 개만 test build에서 열린다.
    try std.testing.expectEqual(@as(usize, 10), count(registry, "if (!builtin.is_test) unreachable;"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "fn ensureSettlementSealReadyForTest()"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "fn fixturePendingRegistryReceipt("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "fn fixtureRegistrySettlementBinding("));
    try std.testing.expectEqual(@as(usize, 1), count(registry, ".exhaustNextEpochForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(response_authority, "pub fn exhaustNextEpochForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(response_authority, "if (!builtin.is_test) unreachable;"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, ".preparedRpcAdmission("));
    try std.testing.expectEqual(@as(usize, 2), count(slot, ".executingRpcAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, ".reserveRpcResponseExecution("));
    try std.testing.expectEqual(@as(usize, 2), count(slot, ".rollbackRpcResponseExecution("));
    try std.testing.expectEqual(@as(usize, 3), count(slot, ".settleRpcResponseExecutionTerminal("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, ".writePreparedRequestExecution("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, ".exhaustRpcResponseEpochForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, ".rpcExecutionAuthoritiesTerminalForTest("));
    try std.testing.expectEqual(@as(usize, 9), count(slot, "executePreparedRpcTerminalSink("));
    try std.testing.expectEqual(@as(usize, 3), count(slot, "executePreparedRpcCorrelatedResponseForTest("));
    try std.testing.expectEqual(@as(usize, 0), count(transport, "PreparedRequestExecutionLease"));
    try std.testing.expectEqual(@as(usize, 0), count(transport, "executePreparedRpcTerminalSink"));

    const terminal_wrapper = between(
        slot,
        "fn executePreparedRpcTerminalSink(",
        "fn executePreparedRpcCorrelatedResponseForTest(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(terminal_wrapper, "executePreparedRpcPrivate("));
    try std.testing.expectEqual(@as(usize, 1), count(terminal_wrapper, ".terminal_sink,"));
    try std.testing.expectEqual(@as(usize, 0), count(terminal_wrapper, ".correlated_response,"));

    const wrapper_start = std.mem.indexOf(
        u8,
        slot,
        "fn executePreparedRpcPrivate(",
    ) orelse return error.TestExpectedEqual;
    const wrapper_end = std.mem.indexOfPos(
        u8,
        slot,
        wrapper_start,
        "fn publishPreparedRpcResponse(",
    ) orelse return error.TestExpectedEqual;
    const wrapper = slot[wrapper_start..wrapper_end];
    const prepared_admission = std.mem.indexOf(u8, wrapper, ".preparedRpcAdmission(") orelse
        return error.TestExpectedEqual;
    const init_txn = std.mem.indexOf(u8, wrapper, ".initBeforeReserve(") orelse
        return error.TestExpectedEqual;
    const cleanup_defer = std.mem.indexOf(u8, wrapper, "defer txn.ensureSettledOrFailStop(") orelse
        return error.TestExpectedEqual;
    const reserve = std.mem.indexOf(u8, wrapper, ".reserveResponse(") orelse
        return error.TestExpectedEqual;
    const begin_execute = std.mem.indexOf(u8, wrapper, ".commitBeginExecute(") orelse
        return error.TestExpectedEqual;
    const begin_lease = std.mem.indexOf(u8, wrapper, ".beginPreparedRequestExecutionFromRegisteredOperation(") orelse
        return error.TestExpectedEqual;
    const executing_admission = std.mem.indexOf(u8, wrapper, ".executingRpcAdmission(") orelse
        return error.TestExpectedEqual;
    const first_write = std.mem.indexOf(u8, wrapper, ".writePreparedRequestExecution(") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(prepared_admission < init_txn);
    try std.testing.expect(init_txn < cleanup_defer);
    try std.testing.expect(cleanup_defer < reserve);
    try std.testing.expect(reserve < begin_execute);
    try std.testing.expect(begin_execute < begin_lease);
    try std.testing.expect(begin_lease < executing_admission);
    try std.testing.expect(executing_admission < first_write);
    try std.testing.expectEqual(@as(usize, 0), count(wrapper, "socket_server.writeAll"));
    try std.testing.expectEqual(@as(usize, 0), count(wrapper, "ExecutedResponse.publish"));
    try std.testing.expectEqual(@as(usize, 0), count(wrapper, "RpcResponseBorrow"));
    try std.testing.expectEqual(@as(usize, 1), count(wrapper, "defer txn.ensureSettledOrFailStop("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn writePreparedRequestExecution("));

    const held_suffix = between(
        slot,
        "fn settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(",
        "/// B3-3 product-shaped private caller.",
    ) orelse return error.TestExpectedEqual;
    const settle_authorities = std.mem.indexOf(u8, held_suffix, "txn.settlePreWireForDeferredPublication(") orelse
        return error.TestExpectedEqual;
    const finish_request = std.mem.indexOf(u8, held_suffix, "txn.request.finishOrFailStop(") orelse
        return error.TestExpectedEqual;
    const release_lease = std.mem.indexOf(u8, held_suffix, "finishPreparedRpcLeaseOrFailStop(") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(settle_authorities < finish_request);
    try std.testing.expect(finish_request < release_lease);

    const pre_wire_settlement = between(
        slot,
        "fn settlePreWireWithLease(",
        "fn settlePostWriteTerminal(",
    ) orelse return error.TestExpectedEqual;
    const request_settle = std.mem.indexOf(u8, pre_wire_settlement, "self.request.rollbackPreWireWithLease(") orelse
        return error.TestExpectedEqual;
    const response_settle = std.mem.indexOf(u8, pre_wire_settlement, ".rollbackRpcResponseExecution(") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(request_settle < response_settle);
    const terminal_request_settle = std.mem.indexOf(u8, pre_wire_settlement, "self.request.settlePreWireTerminalWithLease(") orelse
        return error.TestExpectedEqual;
    const terminal_response_settle = std.mem.indexOf(u8, pre_wire_settlement, ".settleRpcResponseExecutionTerminal(") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(terminal_request_settle < terminal_response_settle);

    const post_write_settlement = between(
        slot,
        "fn settlePostWriteTerminalWithLease(",
        "fn ensureSettledOrFailStop(",
    ) orelse return error.TestExpectedEqual;
    const post_write_request_settle = std.mem.indexOf(u8, post_write_settlement, "self.request.settlePostExecuteTerminalWithLease(") orelse
        return error.TestExpectedEqual;
    const post_write_response_settle = std.mem.indexOf(u8, post_write_settlement, ".settleRpcResponseExecutionTerminal(") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(post_write_request_settle < post_write_response_settle);
}

fn readSource(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(max_source_bytes),
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn between(source: []const u8, begin: []const u8, end: []const u8) ?[]const u8 {
    const begin_at = std.mem.indexOf(u8, source, begin) orelse return null;
    const end_relative = std.mem.indexOf(u8, source[begin_at + begin.len ..], end) orelse return null;
    return source[begin_at .. begin_at + begin.len + end_relative];
}
