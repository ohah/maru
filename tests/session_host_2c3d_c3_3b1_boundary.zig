const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

// C3-3b1 keeps EventAuthority as the sole lifecycle owner while replacing the revoke-only
// aggregate with one all-event blocker and allowing only ClientSlot's canonical take path to mint
// the opaque correlation paired with that authority.
test "CR3a-2c3d C3-3b1 correlation and all-event ordering boundary" {
    const allocator = std.testing.allocator;
    const registry = try readSource(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(registry);
    const slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const event_contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_event_contract.zig",
    );
    defer allocator.free(event_contract);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);

    const facade = between(
        transport,
        "pub const GenerationTransport = struct",
        "fn mapPrepareError(",
    ) orelse return error.TestExpectedEqual;
    // C3-3b3 product settlement 5개와 test-only facade 16개를 반영한 net +13 source inventory다.
    // C3-3b3 settlement이 추가한 product owner API 13개를 별도 테스트 facade와 섞지 않고 고정한다.
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));

    inline for (.{
        "revoke_blocker_count",
        "revokeBlockerCount",
        "validateRevokeBlockerCacheForTest",
    }) |obsolete| try std.testing.expectEqual(
        @as(usize, 0),
        try countSessionHostProductionIdentifiers(allocator, obsolete),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "connection_ordering_blocker_count: usize = 0"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countSessionHostSources(allocator, "pub const EventCorrelation = extern struct"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn mintEventCorrelation("));
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot, "mintEventCorrelation"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "mintEventCorrelation"));
    try std.testing.expectEqual(@as(usize, 0), count(event_contract, "mintEventCorrelation"));

    // RX progress is a narrow lease-held exception to the all-event TX blocker. It must remain a
    // single ClientSlot-owned route, stay outside the closed 15-method facade, and never acquire
    // the registry blocker gate or reach a TX helper.
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostProductionIdentifiers(
            allocator,
            "pumpRxDemuxUnderRegisteredOperationExecutionLease",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSessionHostProductionIdentifiers(allocator, "pumpGenerationRxDemux"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(transport, "pumpRxTailOwned"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "pumpRxTailOwned"));
    const rx_slot = between(
        slot,
        "pub fn pumpGenerationRxDemux(",
        "pub fn sendGenerationInput(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(rx_slot, "rxDemuxAdmissionTransactionWithOperation("));
    try std.testing.expectEqual(@as(usize, 0), count(rx_slot, "finalAdmissionTransactionWithOperation("));
    try std.testing.expectEqual(@as(usize, 0), count(rx_slot, "finalAdmissionTransactionWithOperationAndRegistry("));
    try std.testing.expectEqual(@as(usize, 0), count(rx_slot, "connectionOrderingBlockerCount"));
    try std.testing.expectEqual(@as(usize, 0), count(rx_slot, "bufferedControllerRevoke"));
    inline for (.{ "sendInput", "sendControl", "pumpPendingOutput", "pending_outbound" }) |tx_name|
        try std.testing.expectEqual(@as(usize, 0), count(rx_slot, tx_name));
    const rx_admission = between(
        slot,
        "fn rxDemuxAdmissionTransactionWithOperation(",
        "fn finalAdmissionTransactionWithOperationPermitAndRegistry(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(rx_admission, ".rx_demux"));
    try std.testing.expectEqual(@as(usize, 0), count(rx_admission, "bufferedControllerRevoke"));
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot, "rxDemuxAdmissionTransactionWithOperation"),
    );

    inline for (.{
        "EventOrderingRegistry",
        "EventOrderingLifecycle",
        "EventCorrelationRegistry",
        "EventCorrelationLifecycle",
    }) |parallel_authority| try std.testing.expectEqual(
        @as(usize, 0),
        try countSessionHostProductionIdentifiers(allocator, parallel_authority),
    );
    try std.testing.expectEqual(
        countIdentifierOutsideTopLevelTests(registry, "EventAuthority"),
        try countSessionHostProductionIdentifiers(allocator, "EventAuthority"),
    );
    try std.testing.expectEqual(
        countIdentifierOutsideTopLevelTests(registry, "EventAuthorityLifecycle"),
        try countSessionHostProductionIdentifiers(allocator, "EventAuthorityLifecycle"),
    );
}

fn countSessionHostSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countSessionHostProductionIdentifiers(
    allocator: std.mem.Allocator,
    identifier: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countIdentifierOutsideTopLevelTests(source, identifier);
    }
    return total;
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

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
