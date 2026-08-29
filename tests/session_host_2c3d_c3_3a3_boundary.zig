const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 8 * 1024 * 1024;

// C3-3a3 must activate a dedicated event-producer transaction instead of routing the
// queued event through the consumer predicate that it is about to publish as a blocker.
test "CR3a-2c3d C3-3a3 revoke ordering activation boundary" {
    const allocator = std.testing.allocator;
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const registry = try readSource(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(registry);
    const operation_identity = try readSource(
        allocator,
        "src/platform/macos/session_host/operation_thread_identity.zig",
    );
    defer allocator.free(operation_identity);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    // 2c3e C1 decoder bridge는 owner-bound module seam으로 두어 기존 facade 28개를 늘리지 않는다.
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));

    // Revoke ordering extends the existing event authority. It must not grow a parallel
    // registry/lifecycle SSOT whose state could disagree with EventAuthority.
    inline for (.{
        "RevokeRegistry",
        "RevokeLifecycle",
        "ControllerRevokeRegistry",
        "ControllerRevokeLifecycle",
    }) |forbidden| try std.testing.expectEqual(
        @as(usize, 0),
        try countSessionHostProductIdentifier(allocator, forbidden),
    );
    try std.testing.expectEqual(
        countIdentifierOutsideTopLevelTests(registry, "EventAuthority"),
        try countSessionHostProductIdentifier(allocator, "EventAuthority"),
    );
    try std.testing.expectEqual(
        countIdentifierOutsideTopLevelTests(registry, "EventAuthorityLifecycle"),
        try countSessionHostProductIdentifier(allocator, "EventAuthorityLifecycle"),
    );

    try std.testing.expectEqual(@as(usize, 1), count(slot, "const EventTakeActivationTransaction = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn beginEventTakeActivationTransaction("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransactionWithOperationAndRegistry("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransactionWithOperationPermitAndRegistry("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn pumpGenerationPendingOutput("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationInput("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationInputNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationControl("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationResyncNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn callGenerationRpc("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn beginBoundControllerMutationOwner("));
    try std.testing.expectEqual(@as(usize, 3), count(slot, "beginBoundControllerMutationOwner("));
    try std.testing.expectEqual(@as(usize, 4), count(slot, "consumeStreamOperationPermitNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn validateGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn commitGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn abortGenerationEventTakeDuringRegisteredOperation("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn abortGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn pumpPendingOutputUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendInputUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendInputNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendScrollToBottomUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendCoreCommandUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendObservationProbeNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn sendResyncNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn callUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSrcRaw(allocator, "@import(\"operation_thread_identity.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSrcProductIdentifier(allocator, "issueMintReceipt"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countSrcProductIdentifier(allocator, "consumeMintReceipt"),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        try countSrcProductIdentifier(allocator, "abortMintReceipt"),
    );
    inline for (.{
        "publishCapability",
        "pinCapability",
        "unpinCapability",
        "closeCapability",
    }) |identifier| try std.testing.expectEqual(
        @as(usize, 2),
        try countSrcProductIdentifier(allocator, identifier),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        count(slot, "errdefer _ = operation_thread_identity.abortMintReceipt"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countSrcRaw(allocator, "maru.registered-operation-execution-mint.v1"),
    );
    inline for (.{ "pub fn issueMintReceipt(", "pub fn consumeMintReceipt(", "pub fn abortMintReceipt(" }) |start| {
        const body = between(operation_identity, start, "\n}") orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(usize, 0), count(body, "for ("));
        try std.testing.expectEqual(@as(usize, 0), count(body, "while (receipts"));
    }
    const execution_end = between(
        client,
        "pub fn endRegisteredOperationExecutionLease(",
        "pub fn bufferedControllerRevokeUnderRegisteredOperationExecutionLease(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), count(execution_end, "capability.live = false"));
    try std.testing.expectEqual(@as(usize, 0), count(execution_end, "capability.seal = capability.digest()"));
    try std.testing.expectEqual(
        @as(usize, 3),
        countIdentifierOutsideTopLevelTests(slot, "mintRegisteredOperationExecutionReceipt"),
    );
    try std.testing.expectEqual(
        countIdentifierOutsideTopLevelTests(slot, "mintRegisteredOperationExecutionReceipt"),
        try countSrcProductIdentifier(allocator, "mintRegisteredOperationExecutionReceipt"),
    );

    // These seals are exact field tuples. A duplicate write is source drift even if it does not
    // immediately omit another field, because it obscures the authority schema under review.
    const activation_digest = between(
        slot,
        "    fn digest(self: *const @This()) owner_seal.Digest {\n        var writer = owner_seal.Writer.init(\"maru.event-take-activation.v1\");",
        "    fn reseal(self: *@This()) void {",
    ) orelse return error.TestExpectedEqual;
    inline for (.{
        "writer.writeUsize(self.self_addr);",
        "writer.writeU8(self.lifecycle_raw);",
        "writer.writeUsize(@intFromPtr(&self.admission));",
        "writer.writeUsize(self.prepared_addr);",
        "writer.writeU64(self.permit_registry_id);",
        "writer.writeU8(@intFromBool(self.quarantine_live));",
        "writer.writeU8(@intFromBool(self.pin_live));",
        "writer.writeU8(@intFromBool(self.authority_live));",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(activation_digest, field));
    try std.testing.expectEqual(@as(usize, 8), count(activation_digest, "writer.write"));

    const admission_digest = between(
        slot,
        "fn finalAdmissionTransactionSeal(transaction: *const FinalAdmissionTransaction) owner_seal.Digest {",
        "fn finalAdmissionDestinationValid(",
    ) orelse return error.TestExpectedEqual;
    inline for (.{
        "writer.writeUsize(transaction.self_addr);",
        "writer.writeUsize(@intFromPtr(transaction.operation.node));",
        "writer.writeU16(transaction.operation.registry_index);",
        "writer.writeU64(transaction.operation.operation_id);",
        "writer.writeU64(transaction.operation.pid);",
        "writer.writeUsize(@intFromPtr(&transaction.execution_capability));",
        "writer.writeU64(transaction.execution_capability.lease_identity);",
        "writer.writeU64(transaction.execution_capability.operation_identity);",
        "writer.writeU8(transaction.owns_registered_operation_raw);",
        "writer.writeU8(transaction.lifecycle_raw);",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(admission_digest, field));
    try std.testing.expectEqual(@as(usize, 10), count(admission_digest, "writer.write"));

    // These authority-bearing APIs have no caller closure outside session_host. Walking all of
    // src prevents a sibling product module from bypassing ClientSlot by importing Client.
    inline for (.{
        "beginRegisteredOperationExecutionLease",
        "endRegisteredOperationExecutionLease",
        "validateGenerationEventTakeUnderRegisteredOperationExecutionLease",
        "commitGenerationEventTakeUnderRegisteredOperationExecutionLease",
        "abortGenerationEventTakeUnderRegisteredOperationExecutionLease",
        "bufferedControllerRevokeUnderRegisteredOperationExecutionLease",
        "pumpPendingOutputUnderRegisteredOperationExecutionLease",
        "sendInputUnderRegisteredOperationExecutionLease",
        "sendInputNonBlockingUnderRegisteredOperationExecutionLease",
        "sendScrollToBottomUnderRegisteredOperationExecutionLease",
        "sendCoreCommandUnderRegisteredOperationExecutionLease",
        "sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease",
        "sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease",
        "sendObservationProbeNonBlockingUnderRegisteredOperationExecutionLease",
        "sendResyncNonBlockingUnderRegisteredOperationExecutionLease",
        "callUnderRegisteredOperationExecutionLease",
    }) |identifier| try std.testing.expectEqual(
        try countSessionHostProductIdentifier(allocator, identifier),
        try countSrcProductIdentifier(allocator, identifier),
    );

    // a1/a2 stay private substrates. C3-3a3 activates only the reviewed product wrappers;
    // future 2c3e still has no product caller of the owner-query transaction.
    try std.testing.expectEqual(@as(usize, 1), try countSessionHostProductIdentifier(
        allocator,
        "finalAdmissionTransaction",
    ));
    try std.testing.expectEqual(@as(usize, 2), try countSessionHostProductIdentifier(
        allocator,
        "finalAdmissionTransactionWithOperation",
    ));
    try std.testing.expectEqual(@as(usize, 6), try countSessionHostProductIdentifier(
        allocator,
        "finalAdmissionTransactionWithOperationAndRegistry",
    ));
    try std.testing.expectEqual(@as(usize, 6), try countSessionHostProductIdentifier(
        allocator,
        "finalAdmissionTransactionWithOperationPermitAndRegistry",
    ));
    try std.testing.expectEqual(@as(usize, 2), try countSessionHostProductIdentifier(
        allocator,
        "beginEventTakeActivationTransaction",
    ));

    const activated = .{
        .{ "pumpGenerationPendingOutput", @as(usize, 2) },
        .{ "sendGenerationInput", @as(usize, 2) },
        .{ "sendGenerationInputNonBlocking", @as(usize, 2) },
        .{ "sendGenerationControl", @as(usize, 2) },
        .{ "sendGenerationControlNonBlocking", @as(usize, 2) },
        .{ "sendGenerationResyncNonBlocking", @as(usize, 2) },
        .{ "callGenerationRpc", @as(usize, 2) },
    };
    inline for (activated) |entry| try std.testing.expectEqual(
        entry[1],
        try countSessionHostProductIdentifier(allocator, entry[0]),
    );

    // Every public-shared bypass has one ClientSlot production caller and no second route.
    inline for (.{
        "pumpPendingOutputUnderRegisteredOperationExecutionLease",
        "sendInputUnderRegisteredOperationExecutionLease",
        "sendInputNonBlockingUnderRegisteredOperationExecutionLease",
        "sendScrollToBottomUnderRegisteredOperationExecutionLease",
        "sendCoreCommandUnderRegisteredOperationExecutionLease",
        "sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease",
        "sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease",
        "sendObservationProbeNonBlockingUnderRegisteredOperationExecutionLease",
        "sendResyncNonBlockingUnderRegisteredOperationExecutionLease",
        "callUnderRegisteredOperationExecutionLease",
    }) |identifier| try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(slot, identifier),
    );

    const take = between(slot, "pub fn takeGenerationEvent(", "pub fn generationEventAttachmentReadiness(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(take, "beginEventTakeActivationTransaction("));
    try std.testing.expectEqual(@as(usize, 0), count(take, "finalAdmissionTransactionWithOperation("));
    try std.testing.expectEqual(@as(usize, 1), count(take, ".reserveEventGenerationWithOrdering("));
    try std.testing.expectEqual(@as(usize, 1), count(take, ".validateGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(take, ".commitGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(take, ".abortGenerationEventTakeUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(take, ".abortGenerationEventTakeDuringRegisteredOperation("));

    const blocking_control = between(slot, "pub fn sendGenerationControl(", "pub fn sendGenerationControlNonBlocking(") orelse
        return error.TestExpectedEqual;
    const nonblocking_control = between(slot, "pub fn sendGenerationControlNonBlocking(", "fn beginGenerationControlOwner(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), count(blocking_control, "finalAdmissionTransactionWithOperationPermitAndRegistry("));
    try std.testing.expectEqual(@as(usize, 3), count(nonblocking_control, "finalAdmissionTransactionWithOperationPermitAndRegistry("));

    // GenerationTransport is the sole product facade into each ClientSlot mutation family.
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.pumpGenerationPendingOutput("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationInput("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationInputNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationControl("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationResyncNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.callGenerationRpc("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.callOwned("));

    const ordered = between(runtime, "    fn callOrdered(self: *RemoteRuntime,", "    fn discardQueuedMutations(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(ordered, "self.currentGeneration().attachment.callOrdered("));
    try std.testing.expectEqual(@as(usize, 0), count(ordered, "self.client.call("));

    const attachment_ordered = between(runtime, "    fn callOrdered(\n        self: *RuntimeAttachment,", "    fn hasBufferedControllerRevoke(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(attachment_ordered, ".legacy => (client orelse return error.ProtocolError).call("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment_ordered, ".generation => |*value| value.callOrdered("));
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
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

fn countSessionHostProductIdentifier(
    allocator: std.mem.Allocator,
    wanted: []const u8,
) !usize {
    return countProductIdentifierUnder(
        allocator,
        "src/platform/macos/session_host",
        wanted,
    );
}

fn countSrcProductIdentifier(allocator: std.mem.Allocator, wanted: []const u8) !usize {
    return countProductIdentifierUnder(allocator, "src", wanted);
}

fn countSrcRaw(allocator: std.mem.Allocator, wanted: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var result: usize = 0;
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
        result = try std.math.add(usize, result, count(source, wanted));
    }
    return result;
}

fn countProductIdentifierUnder(
    allocator: std.mem.Allocator,
    root: []const u8,
    wanted: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        root,
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var result: usize = 0;
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
        result = try std.math.add(
            usize,
            result,
            countIdentifierOutsideTopLevelTests(source, wanted),
        );
    }
    return result;
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
