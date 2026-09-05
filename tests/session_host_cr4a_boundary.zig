const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    var consumed: usize = 0;
    while (std.mem.indexOf(u8, rest, identifier)) |relative| {
        const at = consumed + relative;
        const end = at + identifier.len;
        const left_ok = at == 0 or !identifierByte(haystack[at - 1]);
        const right_ok = end == haystack.len or !identifierByte(haystack[end]);
        if (left_ok and right_ok) total += 1;
        consumed = end;
        rest = haystack[consumed..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn countProductSourcesExcept(
    allocator: std.mem.Allocator,
    needle: []const u8,
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
        total += count(source, needle);
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

test "CR4a 경계는 observer attach와 final candidate 준비만 연다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_attachment_contract.zig",
    );
    defer allocator.free(contract);
    const attachment = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_attachment.zig",
    );
    defer allocator.free(attachment);
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const remote_attachment = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_attachment.zig",
    );
    defer allocator.free(remote_attachment);
    const client_slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(client_slot);
    const host_adapter = try readSource(
        allocator,
        "src/platform/macos/session_host/host_adapter.zig",
    );
    defer allocator.free(host_adapter);
    const batch_adapter = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_batch_adapter.zig",
    );
    defer allocator.free(batch_adapter);
    const client = try readSource(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client);
    const cleanup_registry = try readSource(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(cleanup_registry);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const server = try readSource(
        allocator,
        "src/platform/macos/session_host/server.zig",
    );
    defer allocator.free(server);
    const snapshot = try readSource(
        allocator,
        "src/platform/macos/session_host/screen_snapshot.zig",
    );
    defer allocator.free(snapshot);
    const assembler = try readSource(
        allocator,
        "src/session/screen_assembler.zig",
    );
    defer allocator.free(assembler);
    const runtime_manager = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_manager.zig",
    );
    defer allocator.free(runtime_manager);
    const catchup = try readSource(
        allocator,
        "src/platform/macos/session_host/catchup_barrier_contract.zig",
    );
    defer allocator.free(catchup);
    const catchup_stage = try readSource(
        allocator,
        "src/platform/macos/session_host/catchup_stage_contract.zig",
    );
    defer allocator.free(catchup_stage);
    const protocol = try readSource(
        allocator,
        "src/platform/macos/session_host/protocol.zig",
    );
    defer allocator.free(protocol);
    const connection_turn = try readSource(
        allocator,
        "src/platform/macos/session_host/connection_turn.zig",
    );
    defer allocator.free(connection_turn);
    const poll_owner = try readSource(
        allocator,
        "src/platform/macos/session_host/poll_owner.zig",
    );
    defer allocator.free(poll_owner);
    const daemon = try readSource(
        allocator,
        "src/platform/macos/session_host/daemon.zig",
    );
    defer allocator.free(daemon);
    const restore_activation = try readSource(
        allocator,
        "src/platform/macos/session_host/restore_activation.zig",
    );
    defer allocator.free(restore_activation);
    const catchup_wire = try readSource(
        allocator,
        "src/platform/macos/session_host/catchup_barrier_wire.zig",
    );
    defer allocator.free(catchup_wire);
    const host_connect = try readSource(
        allocator,
        "src/platform/macos/session_host/host_connect.zig",
    );
    defer allocator.free(host_connect);
    const remote_backend = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_term_backend.zig",
    );
    defer allocator.free(remote_backend);
    const process_seal = try readSource(
        allocator,
        "src/platform/macos/session_host/process_seal_service.zig",
    );
    defer allocator.free(process_seal);
    const cleanup_seal = try readSource(
        allocator,
        "src/platform/macos/session_host/event_cleanup_seal.zig",
    );
    defer allocator.free(cleanup_seal);
    const runtime_product = runtime[0..std.mem.indexOf(u8, runtime, "const testing = std.testing;").?];
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const build_cr4a_start = std.mem.indexOf(u8, build, "const session_host_cr4a_step =").?;
    const build_cr4a_end = std.mem.indexOfPos(u8, build, build_cr4a_start, "const session_host_cr4b_step =").?;
    const build_cr4a = build[build_cr4a_start..build_cr4a_end];

    try std.testing.expectEqual(@as(usize, 4), count(contract, "attach_observer,"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn attachObserver() RuntimeRequest"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn prepareObserverAttach("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "contract.RuntimeRequest.attachObserver()"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".prepareObserverAttach(args.adapter, args.runtime_id)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareObserverAttach(", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "attachObserver()", &.{
            "platform/macos/session_host/generation_attachment_contract.zig",
            "platform/macos/session_host/generation_attachment.zig",
        }),
    );
    // Observer tag consumers stay closed to the wire contract, attachment preparation,
    // cleanup policy and the reconnect owner. No unrelated product source may admit it.
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, ".attach_observer", &.{
            "platform/macos/session_host/generation_attachment_contract.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/attachment_cleanup_registry.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 8), count(contract, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 3), count(cleanup_registry, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".attach_observer"));
    try std.testing.expectEqual(
        @as(usize, 0),
        count(runtime_product, "if (self.statePtr().role == .observer) return error.Unauthorized;"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "return mapGenerationDecodedError(err);"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(cleanup_registry, "tag == .attach_observer and identity.role == .observer"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(cleanup_registry, ".tag = .attach_observer, .lifecycle = .reserved, .role = .observer"),
    );
    try std.testing.expectEqual(@as(usize, 2), count(client_slot, "\\\"mode\\\":\\\"observer\\\""));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "fn initObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn prepareObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn prepareObserverReconnectCandidateUntil("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "self.generation_owner.prepareAfterClientReplacement("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_product, "initObserverReconnectCandidate,"));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "test \"CR4a "));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a frontier는"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot, "test \"CR4a frontier는"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "next_screen_sequence: ?u64 = null"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "sub.screen_sequence = sequence"));
    try std.testing.expectEqual(@as(usize, 1), count(assembler, "admitted_sequence != expected_sequence"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_attachment, "prepared_screen.prepareRecoveryFrontierFrom(screen)"));
    try std.testing.expectEqual(@as(usize, 1), count(assembler, "pub fn prepareRecoveryFrontierFrom("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "base, next_sequence, self.allocator"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "screenPtr().?.requireSequencedDeltas()"));
    try std.testing.expectEqual(@as(usize, 3), count(runtime_manager, ".{ .generation = generation, .sequence = sequence }"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_manager, "base: []const u8, sequence: u64,"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot, ".{ .generation = 7, .sequence = 1 }"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "runtime.prepareObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn publishCr4aReplacementPrerequisite("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "candidate_adapter == &adapter"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "\"test-session-host-cr4a\""));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a actual socket observer"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a actual socket catchup hostile은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "screen-stream: catchup decoded cell accounting"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a catchup apply leaf는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a observer 실패"));
    try std.testing.expectEqual(@as(usize, 3), count(build_cr4a, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "--maru-expect-tests=3"));
    try std.testing.expectEqual(@as(usize, 0), count(build_cr4a, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 0), count(build_cr4a, "--maru-expect-tests=5"));
    try std.testing.expectEqual(@as(usize, 2), count(build_cr4a, "--maru-expect-tests=6"));
    try std.testing.expectEqual(@as(usize, 13), count(build_cr4a, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a frontier는 snapshot zero"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a frontier는 output admission"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a barrier"));
    try std.testing.expectEqual(@as(usize, 2), count(build_cr4a, "CR4a catchup"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host pending은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host capability는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host admission은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host frontier batch는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "MARU_CR4A_HOST_FRONTIER_ROLE"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "maru-cr4a-host-frontier-fresh-v1"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a poll owner는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a restore exec bootstrap은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "MARU_CR4A_RESTORE_EXEC_ROLE"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "maru-cr4a-restore-parent-v1"));
    try std.testing.expectEqual(@as(usize, 2), count(build_cr4a, "CR4a host barrier frame"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a client demux는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a actual issuer는 bounded"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a actual issuer job은"));
    try std.testing.expectEqual(@as(usize, 1), count(host_connect, "pub fn connectExistingHostUntil("));
    try std.testing.expectEqual(@as(usize, 6), count(remote_backend, "test \"CR4a actual issuer job은"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "const HostReconnectJob = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "host_reconnect_job: ?*HostReconnectJob = null"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "host_reconnect_preparing: bool = false"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "pub fn beginHostReconnectConnect("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "pub fn abortHostReconnectConnect("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "pub fn publishHostReconnectReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn publishReconnectClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "RemoteRuntime.backend_api.publishReconnectClientReplacement("));
    // CR5b-2c adds one typed failure-to-terminal classification from the active row.
    try std.testing.expectEqual(@as(usize, 10), count(remote_backend, "HostReconnectJobState.replacement_published"));
    // CR5b-2c excludes pre-shared replacement failure from cursor-bearing states.
    try std.testing.expectEqual(@as(usize, 7), count(remote_backend, "HostReconnectJobState.replacement_failed"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn preflightReconnectClientReplacementFailure("));
    try std.testing.expectEqual(@as(usize, 3), count(remote_backend, "preflightReconnectClientReplacementFailure("));
    // Product backend deinit and the CR5b-2b shared-publication fixture each reclaim the
    // canonical retired Client through the same tick-end leaf.
    try std.testing.expectEqual(@as(usize, 2), count(remote_backend, "adapter.prepareRetiredClientReclaim(&reclaim)"));
    try std.testing.expectEqual(@as(usize, 2), count(remote_backend, "adapter.commitRetiredClientReclaimAtTickEndNoFail(&reclaim)"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "host_connect.connectExistingHostUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(cleanup_seal, "pub const HostReconnectJobSealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "candidate_failure_reason_raw: u8 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "adapter.preflightAttachmentConnectionFailedClosed(failure_reason)"));
    try std.testing.expectEqual(@as(usize, 1), count(host_adapter, "pub fn preflightAttachmentConnectionFailedClosed("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn preflightAttachmentConnectionFailedClosed("));
    try std.testing.expectEqual(@as(usize, 1), count(host_adapter, "pub fn failCloseAttachmentConnection("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn failCloseAttachmentConnection("));
    try std.testing.expectEqual(@as(usize, 1), count(host_adapter, "pub fn preflightAttachmentConnectionUsable("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn preflightAttachmentConnectionUsable("));
    // CR4a candidate prepare and CR4c forced-resize failure share the same forward-only close leaf.
    try std.testing.expectEqual(@as(usize, 2), count(remote_backend, "adapter.failCloseAttachmentConnection(reason)"));
    try std.testing.expectEqual(@as(usize, 5), count(remote_backend, "adapter.preflightAttachmentConnectionUsable()"));
    try std.testing.expectEqual(@as(usize, 1), count(process_seal, "pub fn hostReconnectJobSeal("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "connectExistingHostUntil", &.{
            "platform/macos/session_host/host_connect.zig",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/reconnect_worker_issuer.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "preflightReconnectClientReplacementFailure", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "beginHostReconnectConnect", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "publishHostReconnectReplacement", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "publishReconnectClientReplacement", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(client, "const catchup_barrier_contract = @import"));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn readCatchupBarrierUntil("));
    try std.testing.expectEqual(@as(usize, 7), count(client, "readCatchupBarrierUntil("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "readCatchupBarrierUntil", &.{
            "platform/macos/session_host/client.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "pending_catchup_barriers: std.ArrayListUnmanaged(BufferedCatchupBarrier) = .empty"),
    );
    try std.testing.expectEqual(@as(usize, 6), count(client, "test \"CR4a client demux는"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const ScreenFrontier = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const CatchupIdentity = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Barrier = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const HostState = union(enum)"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Pending = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Admitted = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Terminal = struct"));
    try std.testing.expectEqual(@as(usize, 2), count(catchup, "test \"CR4a barrier"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "test \"CR4a host pending은"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_stage, "pub const max_batches: u32 = 64"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_stage, "pub const max_encoded_bytes: u64 = 16 * 1024 * 1024"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_stage, "pub const max_decoded_cells: u64 = 1024 * 1024"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_stage, "pub const PreparedStage = struct"));
    try std.testing.expectEqual(@as(usize, 2), count(catchup_stage, "test \"CR4a catchup"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn prepareCatchupStage("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn validateCatchupStage("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn abortCatchupStage("));
    // Deadline-aware candidate construction is one closed owner chain. Every identifier is
    // inventoried both outside and inside its allowed files so aliases cannot add a second caller.
    inline for (.{
        .{ "executePreparedBlockingRpcStorageUntilObserved", &.{
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
        } },
        .{ "executeGenerationRequestUntil", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_transport.zig",
        } },
        .{ "readInitialSnapshotGuardedUntil", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_transport.zig",
        } },
        .{ "executePreparedRequestUntil", &.{
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
        } },
        .{ "executePreparedAttachUntil", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "readInitialSnapshotUntil", &.{
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "catchupStageAuthorityMatches", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "prepareReconnectObserverStage", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "validateReconnectObserverStage", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "validateReconnectObserverStageForCleanup", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "abortReconnectObserverStage", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "prepareObserverReconnectCandidateUntil", &.{
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "prepareHostReconnectObserverStage", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        } },
    }) |entry| {
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductIdentifiersExcept(allocator, entry[0], entry[1]),
        );
    }
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(client, "executePreparedBlockingRpcStorageUntilObserved"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "executePreparedBlockingRpcStorageUntilObserved"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "executeGenerationRequestUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(transport, "executeGenerationRequestUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "readInitialSnapshotGuardedUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(transport, "readInitialSnapshotGuardedUntil"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(transport, "executePreparedRequestUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "executePreparedRequestUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "executePreparedAttachUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "executePreparedAttachUntil"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(transport, "readInitialSnapshotUntil"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(attachment, "readInitialSnapshotUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "readInitialSnapshotUntil"));
    // CR4a cleanup validation + CR4b deadline-first controller transfer validation.
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(attachment, "catchupStageAuthorityMatches"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(runtime, "catchupStageAuthorityMatches"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "prepareReconnectObserverStage"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(remote_backend, "prepareReconnectObserverStage"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "validateReconnectObserverStageForCleanup"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(remote_backend, "validateReconnectObserverStageForCleanup"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "abortReconnectObserverStage"));
    // CR4a issuer teardown + CR4b usable authority-conflict teardown.
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(remote_backend, "abortReconnectObserverStage"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(runtime, "prepareObserverReconnectCandidateUntil"));
    // CR5b-2c reuses the product observer-stage entry for success, usable
    // kth-failure rows, and the shared-Client terminal-after-success guard.
    // CR6e-c3b2b adds the reviewed one-state frame driver caller.
    try std.testing.expectEqual(@as(usize, 11), countIdentifier(remote_backend, "prepareHostReconnectObserverStage"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn catchupProjection("));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(transport, "catchupProjection"));
    // CR4a prepare/validate 두 경로와 CR4b controller-evidence 재검증 한 경로.
    // prepare/validate plus CR4c promoted-resize revalidation share the same closed projection.
    try std.testing.expectEqual(@as(usize, 4), countIdentifier(attachment, "catchupProjection"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "catchupProjection", &.{
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".prepareCatchupStage("));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, ".prepareCatchupStage("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "prepareCatchupStage", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn readCatchupBarrierPlanUntil("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "readCatchupBarrierPlanUntil", &.{
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "requestAttachmentCatchupUntil", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "requestCatchupUntil", &.{
            "platform/macos/session_host/generation_batch_adapter.zig",
            "platform/macos/session_host/generation_attachment.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, "pumpCatchupScreen", &.{
            "platform/macos/session_host/remote_attachment.zig",
            "platform/macos/session_host/generation_attachment.zig",
        }),
    );
    inline for (.{ "validateCatchupStage", "abortCatchupStage" }) |identifier| {
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductIdentifiersExcept(allocator, identifier, &.{
                "platform/macos/session_host/generation_attachment.zig",
                "platform/macos/session_host/remote_runtime.zig",
            }),
        );
    }
    // The external zero boundary above is paired with this per-owner inventory so adding an
    // alias or a second caller inside an already allowed file cannot launder the closed chain.
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(client, "readCatchupBarrierPlanUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "readCatchupBarrierPlanUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "readCatchupBarrierPlanUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "readCatchupBarrierPlanUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "requestAttachmentCatchupUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "requestAttachmentCatchupUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "requestCatchupUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "requestCatchupUntil"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(remote_attachment, "pumpCatchupScreen"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "pumpCatchupScreen"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(attachment, "prepareCatchupStage"));
    // CR4a public validator와 CR4b takeover preflight가 같은 canonical validator를 공유한다.
    // CR4a public validation remains declaration+hostile tests; CR4b uses the raw-safe authority matcher.
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(attachment, "validateCatchupStage"));
    try std.testing.expectEqual(@as(usize, 10), countIdentifier(runtime, "validateCatchupStage"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "abortCatchupStage"));
    // CR4a coordinator consumers exact2 + CR4a/CR4b hostile fixture consumers exact4.
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(runtime, "abortCatchupStage"));
    try std.testing.expectEqual(@as(usize, 1), count(server, ".subscription_id = subscription_text"));
    try std.testing.expectEqual(@as(usize, 1), count(server, ".connection_id = connection_id_text"));
    try std.testing.expectEqual(@as(usize, 1), count(server, ".connection_generation = connection_generation_text"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "catchup_barrier_contract.zig", &.{
            "platform/macos/session_host/catchup_barrier_contract.zig",
            "platform/macos/session_host/server.zig",
            "platform/macos/session_host/connection_turn.zig",
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/catchup_stage_contract.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_screen.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "catchup_stage_contract.zig", &.{
            "platform/macos/session_host/catchup_stage_contract.zig",
            "platform/macos/session_host/remote_attachment.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const capability ="));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "kind_raw: u16 = 14"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "version: u16 = 1"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "payload_size: usize = 96"));
    try std.testing.expectEqual(@as(usize, 0), count(catchup, "process_nonce"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "const catchup_barrier_contract = @import"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "runtime_catchup_barrier_v1: bool = false"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "catchup: catchup_barrier_contract.HostState = .idle"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a host capability는"));
    try std.testing.expectEqual(@as(usize, 1), count(server, ".runtime_catchup => self.dispatchCatchup"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, ".catchup_arm_requested =>"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "self.commitCatchupArm(&prepared)"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn commitCatchupArm("));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "sub.catchup = prepared.after"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn validateProcessIdentity("));
    try std.testing.expectEqual(@as(usize, 2), count(poll_owner, "const process_identity = process_seal_service.currentReadyIdentity() catch"));
    try std.testing.expectEqual(@as(usize, 2), count(poll_owner, ".process_identity = process_identity"));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "test \"CR4a poll owner는"));
    try std.testing.expectEqual(@as(usize, 0), count(poll_owner, "pub fn requireCurrentProcess("));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "pub fn requireCurrentProcessOrFatal("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "error.ProcessIdentityUnavailable => error.ProcessIdentityUnavailable"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, ".authority_lost => fd_owner.requireCurrentProcessOrFatal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, ".authority_lost => owner.requireCurrentProcessOrFatal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "const process_seal_service = @import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "test \"CR4a restore exec bootstrap은"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "fn bootstrapProcessSeal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "process_seal_service.commitReady(try process_seal_service.prepare(process_pid, process_nonce))"));
    const restore_run_start = std.mem.indexOf(u8, restore_activation, "pub fn run(") orelse
        return error.TestUnexpectedResult;
    const restore_run_end = std.mem.indexOfPos(u8, restore_activation, restore_run_start, "fn bootstrapProcessSeal()") orelse
        return error.TestUnexpectedResult;
    const restore_run = restore_activation[restore_run_start..restore_run_end];
    // 호출 **위치**만 본다. 이 경계가 고정하는 것은 seal → arm → activate 라는 순서이지 오류 전파
    // 표현이 아니다. 예전 needle 은 `_ = try bootstrapProcessSeal();` 전체였는데, 실패 단계를 로그로
    // 남기려고 `try` 를 `catch |err| { … }` 로 바꾸자 순서가 그대로인데도 경계가 깨졌다.
    const bootstrap_pos = std.mem.indexOf(u8, restore_run, "bootstrapProcessSeal()") orelse
        return error.TestUnexpectedResult;
    const arm_pos = std.mem.indexOf(u8, restore_run, "upgrade_bootstrap.armRestoreInvocation(") orelse
        return error.TestUnexpectedResult;
    const activate_pos = std.mem.indexOf(u8, restore_run, "activateValidated(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(bootstrap_pos < arm_pos);
    try std.testing.expect(arm_pos < activate_pos);
    const daemon_turn = daemon[std.mem.indexOf(u8, daemon, "while (true) {\n        fd_owner.requireCurrentProcessOrFatal();") orelse
        return error.TestUnexpectedResult ..];
    try std.testing.expect(std.mem.indexOf(u8, daemon_turn, "server.tickOwner();") != null);
    const restore_turn = restore_activation[std.mem.indexOf(u8, restore_activation, "while (true) {\n        owner.requireCurrentProcessOrFatal();") orelse
        return error.TestUnexpectedResult ..];
    try std.testing.expect(std.mem.indexOf(u8, restore_turn, "server.tickOwner();") != null);
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "test \"CR4a host admission은"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "test \"CR4a host frontier batch는"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "MARU_CR4A_HOST_FRONTIER_ROLE"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "maru-cr4a-host-frontier-fresh-v1"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "pub const PreparedCatchupBatch = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "owner_addr: usize = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "owner_thread_id: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn validatePreparedCatchup("));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn consumePreparedCatchup("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "prepared.active_raw = 0;"));
    try std.testing.expectEqual(@as(usize, 2), count(connection_turn, "prepared.active_raw = 0;"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "catchup_barrier_wire.zig", &.{
            "platform/macos/session_host/catchup_barrier_contract.zig",
            "platform/macos/session_host/protocol.zig",
            "platform/macos/session_host/catchup_barrier_wire.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(protocol, "screen_frontier_barrier = catchup_barrier_wire.kind_raw"));
    try std.testing.expectEqual(@as(usize, 1), count(protocol, "test \"CR4a host barrier frame"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a host barrier frame은"));
    try std.testing.expectEqual(@as(usize, 0), count(connection_turn, ".barrier => return false"));
    // One product validator plus changed-screen and no-change socket transcript oracles. All
    // decode the canonical fixed payload instead of trusting the MRSH header alone.
    try std.testing.expectEqual(@as(usize, 3), count(connection_turn, "catchup_barrier_contract.Barrier.decode(payload)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareObserverReconnectCandidate(", &.{
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
}
