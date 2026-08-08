const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "B3-4/5 transition permits remain leaf-owned and registry-mediated" {
    const allocator = std.testing.allocator;
    const leaf = try readSource(allocator, "src/platform/macos/session_host/rpc_response_authority.zig");
    defer allocator.free(leaf);
    const registry = try readSource(allocator, "src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer allocator.free(registry);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const owner = try readSource(allocator, "src/platform/macos/session_host/rpc_executed_response.zig");
    defer allocator.free(owner);
    const ledger = try readSource(allocator, "src/platform/macos/session_host/response_payload_allocation.zig");
    defer allocator.free(ledger);
    const leaf_product = productPrefix(leaf);
    const registry_product = productPrefix(registry);
    const owner_product = productPrefix(owner);
    const ledger_product = productPrefix(ledger);

    try std.testing.expectEqual(@as(usize, 1), count(leaf_product, "pub const PreparedRpcTransitionPermit = struct"));
    inline for (.{
        "preparePublish",
        "commitPublishedNoFail",
        "prepareBorrow",
        "commitBorrowedNoFail",
        "prepareBeginRelease",
        "commitReleasingNoFail",
        "prepareFinishReusable",
        "commitReusableNoFail",
        "prepareFinishTerminal",
        "commitTerminalNoFail",
        "preparePublishedTerminal",
        "commitPublishedTerminalNoFail",
    }) |name| {
        const declaration = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{name});
        defer allocator.free(declaration);
        try std.testing.expectEqual(@as(usize, 1), count(leaf_product, declaration));
        const call = try std.fmt.allocPrint(allocator, ".rpc_response_authority.{s}(", .{name});
        defer allocator.free(call);
        try std.testing.expectEqual(@as(usize, 1), count(registry_product, call));
        try std.testing.expectEqual(@as(usize, 0), count(slot, call));
        try std.testing.expectEqual(@as(usize, 0), count(transport, call));
    }

    inline for (.{
        "prepareRpcResponsePublished",
        "commitRpcResponsePublished",
        "prepareRpcResponseBorrowed",
        "commitRpcResponseBorrowed",
        "prepareRpcResponseReleasing",
        "commitRpcResponseReleasing",
        "prepareRpcResponseReusable",
        "commitRpcResponseReusable",
        "prepareRpcResponseTerminal",
        "commitRpcResponseTerminal",
        "preparePublishedRpcResponseTerminal",
        "commitPublishedRpcResponseTerminal",
    }) |name| {
        const declaration = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{name});
        defer allocator.free(declaration);
        try std.testing.expectEqual(@as(usize, 1), count(registry_product, declaration));
    }

    try std.testing.expectEqual(@as(usize, 0), count(registry_product, "rpc_response_authority: *"));
    try std.testing.expectEqual(@as(usize, 0), count(registry_product, "PreparedRpcTransitionPermit ="));
    inline for (.{ "client.zig", "client_slot.zig", "socket", "Allocator", "RemoteRuntime", "reconnect" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), countCodeTokens(leaf_product, forbidden));
    }

    try std.testing.expectEqual(
        @as(usize, 1),
        count(ledger_product, "@import(\"rpc_executed_response.zig\")"),
    );
    inline for (.{
        "response_payload_allocation.zig",
        "rpc_response_authority.zig",
        "attachment_cleanup_registry.zig",
        "client.zig",
        "client_slot.zig",
        "socket",
        "RemoteRuntime",
    }) |forbidden| try std.testing.expectEqual(
        @as(usize, 0),
        countCodeTokens(owner_product, forbidden),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(owner_product, "pub fn withBorrowedRpcResponseBytesForTest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(owner_product, "@import(\"builtin\").is_test"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(ledger_product, "pub fn transferPromotedRpcResponse("),
    );
    try std.testing.expectEqual(@as(usize, 0), count(slot, "withBorrowedRpcResponseBytesForTest"));
    try std.testing.expectEqual(@as(usize, 0), count(ledger_product, "withBorrowedRpcResponseBytesForTest"));

    const response_only = between(
        client,
        "pub fn readPreparedResponseUnderExecutionLease(",
        "fn readCorrelatedPreparedResponse(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(response_only, ".readCorrelatedPreparedResponse("));
    try std.testing.expectEqual(@as(usize, 0), count(response_only, "writePreparedRequestExecution"));
    try std.testing.expectEqual(@as(usize, 0), count(response_only, "next_request_id +="));
    try std.testing.expectEqual(@as(usize, 0), count(client, "@import(\"remote_runtime.zig\")"));

    try std.testing.expectEqual(
        @as(usize, 1),
        count(productPrefix(slot), "@import(\"rpc_executed_response.zig\")"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn beginRpcResponseBorrowForTest("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finishRpcResponseOwnedForTest("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(slot, "fn executePreparedRpcCorrelatedResponseForTest("),
    );
    const correlated_wrapper = between(
        slot,
        "fn executePreparedRpcCorrelatedResponseForTest(",
        "const RpcResponseDisposition = enum",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(correlated_wrapper, "executePreparedRpcPrivate("),
    );
    try std.testing.expectEqual(@as(usize, 1), count(correlated_wrapper, ".correlated_response,"));
    try std.testing.expectEqual(@as(usize, 0), count(correlated_wrapper, ".terminal_sink,"));

    const publication = between(
        slot,
        "fn publishPreparedRpcResponse(",
        "fn executePreparedRpcTerminalSink(",
    ) orelse return error.TestExpectedEqual;
    inline for (.{
        ".readPreparedResponseUnderExecutionLease(",
        ".classifyResponsePayloadProvenance(",
        ".revalidatePreparedResponsePublication(",
        ".prepareRpcResponsePublished(",
        ".transferPromotedRpcResponse(",
        ".commitRpcResponsePublished(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(publication, needle));
    try expectOrdered(publication, &.{
        ".readPreparedResponseUnderExecutionLease(",
        ".classifyResponsePayloadProvenance(",
        ".revalidatePreparedResponsePublication(",
        ".prepareRpcResponsePublished(",
        ".transferPromotedRpcResponse(",
        ".commitRpcResponsePublished(",
        ".settlePostExecuteReusableUnderPublicationScope(",
        "publication.finish(",
        "finishPreparedRpcLeaseOrFailStop(",
    });
    const borrow_product = between(
        slot,
        "fn beginRpcResponseBorrowForTest(",
        "fn finishRpcResponseOwnedForTest(",
    ) orelse return error.TestExpectedEqual;
    inline for (.{
        ".prepareRpcResponseBorrowed(",
        ".prepareBorrowInit(",
        ".commitRpcResponseBorrowed(",
        ".commitBorrowReceiptNoFail(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(borrow_product, needle));
    try expectOrdered(borrow_product, &.{
        ".prepareRpcResponseBorrowed(",
        ".prepareBorrowInit(",
        ".commitRpcResponseBorrowed(",
        ".commitBorrowReceiptNoFail(",
    });
    const finish_product = between(
        slot,
        "fn finishRpcResponseOwnedForTest(",
        "fn terminalizeBorrowedRpcResponseNoFree(",
    ) orelse return error.TestExpectedEqual;
    inline for (.{
        ".prepareFinish(",
        ".commitFreeNoFail(",
        ".commitFreeCall(",
        ".freeCaptured(",
        ".finishCleanNoFail(",
        ".retireFreeCall(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(finish_product, needle));
    try std.testing.expectEqual(@as(usize, 1), count(finish_product, ".prepareRpcResponseReleasing("));
    try std.testing.expectEqual(@as(usize, 1), count(finish_product, ".commitRpcResponseReleasing("));
    try expectOrdered(finish_product, &.{
        ".prepareFinish(",
        ".prepareRpcResponseReleasing(",
        ".commitFreeNoFail(",
        ".commitRpcResponseReleasing(",
        ".commitFreeCall(",
        ".freeCaptured(",
        ".prepareRpcResponseReusable(",
        ".finishCleanNoFail(",
        ".commitRpcResponseReusable(",
        ".retireFreeCall(",
    });
    const no_free = between(
        slot,
        "fn terminalizeBorrowedRpcResponseNoFree(",
        "fn failStopFreedRpcResponse(",
    ) orelse return error.TestExpectedEqual;
    try expectOrdered(no_free, &.{
        ".prepareRpcResponseReleasing(",
        ".abandonLiveNoFree(",
        ".commitRpcResponseReleasing(",
        ".prepareRpcResponseTerminal(",
        ".commitRpcResponseTerminal(",
        ".poison(",
        "@panic(",
    });
    try std.testing.expectEqual(@as(usize, 0), count(no_free, ".freeCaptured("));
    try std.testing.expectEqual(@as(usize, 0), count(no_free, ".commitFreeCall("));
    const freed_once = between(
        slot,
        "fn failStopFreedRpcResponse(",
        "/// Executes the attach-compatible request",
    ) orelse return error.TestExpectedEqual;
    try expectOrdered(freed_once, &.{
        ".commitTerminalFreedOnce(",
        ".prepareRpcResponseTerminal(",
        ".commitRpcResponseTerminal(",
        ".poison(",
        "@panic(",
    });
    try std.testing.expectEqual(@as(usize, 0), count(freed_once, ".freeCaptured("));
    const evidence = between(
        slot,
        "pub const RpcFreeEvidenceRecord = struct",
        "fn rpcFreeEvidenceSeal(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), count(evidence, "Allocator"));
    try std.testing.expectEqual(@as(usize, 0), count(evidence, "payload_addr"));
    try std.testing.expectEqual(@as(usize, 0), count(evidence, "payload_len"));
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
    var count_value: usize = 0;
    var line_iterator = std.mem.splitScalar(u8, source, '\n');
    while (line_iterator.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        count_value += count(line, needle);
    }
    return count_value;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}

fn expectOrdered(source: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const index = std.mem.indexOfPos(u8, source, cursor, needle) orelse
            return error.TestExpectedEqual;
        cursor = index + needle.len;
    }
}
