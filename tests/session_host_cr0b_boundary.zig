const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

test "CR0b 경계는 중립 schema와 단일 incident writer owner만 연다" {
    const allocator = std.testing.allocator;
    const incident = try readSource(allocator, "src/observability/connection_incident.zig");
    defer allocator.free(incident);
    const binding = try readSource(allocator, "src/observability/incident_binding_contract.zig");
    defer allocator.free(binding);
    const publication = try readSource(allocator, "src/observability/incident_publication_contract.zig");
    defer allocator.free(publication);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const client_slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const poison = try readSource(allocator, "src/platform/macos/session_host/client_poison.zig");
    defer allocator.free(poison);
    const storage = try readSource(allocator, "src/platform/macos/session_host/incident_artifact_store.zig");
    defer allocator.free(storage);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/incident_runtime.zig");
    defer allocator.free(runtime);
    const daemon = try readSource(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    const pool = try readSource(allocator, "src/platform/macos/session_host/host_pool.zig");
    defer allocator.free(pool);
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const publisher = try readSource(allocator, "src/platform/macos/session_host/incident_publisher_registry.zig");
    defer allocator.free(publisher);
    const seal_service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_service);
    const seal_types = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_types);

    try std.testing.expectEqual(@as(usize, 1), count(incident, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const payload_size: usize = 208;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const envelope_size: usize = 256;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const incident_slot_count: usize = 120;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const aggregate_slot_count: usize = 8;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "fn recordRepeatForTest("));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "pub fn recordRepeat("));
    try std.testing.expectEqual(@as(usize, 20), count(incident, "test \"CR0b core "));
    try std.testing.expectEqual(@as(usize, 5), count(incident, "test \"CR0b service transaction"));
    inline for (.{
        "prepareFirstPublication(",
        "commitPreparedEvidenceNoFail(",
        "publishPreparedPendingAndUnlockNoFail(",
    }) |transaction_call| {
        try std.testing.expectEqual(@as(usize, 1), count(incident, "self." ++ transaction_call));
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductSourcesExcept(allocator, transaction_call, "observability/connection_incident.zig"),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), count(incident, "self.abortPreparedPublication("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "abortPreparedPublication(", "observability/connection_incident.zig"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(incident, "@import(\"../platform"));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "incident_runtime.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "const process_seal = @import(\"process_seal_service.zig\");"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime, "error.CounterExhausted => {"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(incident, "fatalIntegrity("));
    try std.testing.expectEqual(@as(usize, 6), count(binding, "test \"CR0b binding 계약은"));
    try std.testing.expectEqual(@as(usize, 5), count(publication, "test \"CR0b poison publication 계약은"));
    inline for (.{
        "pub fn serviceInput(",
        "pub fn inputDigest(",
        "pub fn fingerprint(",
    }) |canonical_input_api| try std.testing.expectEqual(@as(usize, 1), count(publication, canonical_input_api));
    try std.testing.expectEqual(@as(usize, 0), count(publication, "../platform"));
    try std.testing.expectEqual(@as(usize, 0), count(publication, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publication, "std.mem.Allocator"));
    try std.testing.expectEqual(@as(usize, 11), count(adapter, "test \"CR0b HostPool publication은"));
    try std.testing.expectEqual(@as(usize, 3), count(pool, "return error.ManagedPublicationRequired;"));
    try std.testing.expectEqual(@as(usize, 7), count(adapter, "test \"CR0b ClientSlot binding은"));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "test \"CR0b Client incident operation은"));
    inline for (.{
        "pub fn beginIncidentClientOperation(",
        "pub fn bindIncidentClientPublication(",
        "pub fn commitFirstIncidentClientPublicationNoFail(",
        "pub fn finishIncidentClientOperationNoFail(",
    }) |facade| {
        try std.testing.expectEqual(@as(usize, 1), count(client_slot, facade));
        try std.testing.expectEqual(
            @as(usize, 0),
            try countProductSourcesExcept(allocator, facade, "platform/macos/session_host/client_slot.zig"),
        );
    }
    inline for (.{
        // declaration 1 + success/reuse 4 + alias exact/partial/table/canonical 4다.
        .{ "beginIncidentClientOperation(", 9 },
        // declaration 1 + success 1 + copied/seal/digest/coherent/commit drift 5행이다.
        .{ "bindIncidentClientPublication(", 7 },
        .{ "commitFirstIncidentClientPublicationNoFail(", 2 },
        .{ "finishIncidentClientOperationNoFail(", 6 },
    }) |entry| try std.testing.expectEqual(@as(usize, entry[1]), count(client_slot, entry[0]));
    // 중첩 owner는 상위 extent가 같은 공격을 막을 수 있으므로 각 보호 역할의 source clause도 별도로 고정한다.
    inline for (.{
        "rangesOverlapTyped(out, slot_before)",
        "rangesOverlapTyped(out, node_before)",
        "rangesOverlapTyped(out, client_before)",
        "rangesOverlapTyped(out, &client_before.incident_binding)",
        "rangesOverlapTyped(out, &client_before.incident_repeat_key)",
        "rangesOverlapTyped(out, &client_slot_registry)",
        "rangesOverlapTyped(out, &registered_node_operations)",
        "rangesOverlapTyped(out, &registered_node_operation_free_stack)",
    }) |protected_range| try std.testing.expectEqual(@as(usize, 1), count(client_slot, protected_range));
    try std.testing.expectEqual(@as(usize, 0), count(binding, "@import(\"../platform"));
    try std.testing.expectEqual(@as(usize, 0), count(binding, "client_slot.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(binding, "host_pool.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(pool, "client.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "fn publishManagedRemoteAdapter("));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "publishManagedRemoteAdapter(&app_remote_host_pool.?"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "pool.prepareManagedOwnedPublication(source.host_id,"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "pool.commitOwnedPublication(adapter,"));
    try std.testing.expectEqual(@as(usize, 4), count(app_session, "test \"CR0b AppSession publication은"));
    // 제품 정의가 파일 중간의 테스트 뒤에도 이어지므로 첫 test 이전 substring으로 자르면 실제 caller를 놓친다.
    // 전체 source의 addOwned 두 호출은 아래 기존 test fixture에만 있고 managed 제품 entrypoint는 공용 transaction만 쓴다.
    try std.testing.expectEqual(@as(usize, 2), count(app_session, ".addOwned("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "if (app_remote_backend != null and"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "backend.promoteToSpawnAndAttach(&app_remote_host_pool.?)"));
    try std.testing.expectEqual(@as(usize, 11), count(incident, "test \"CR0b writer"));
    try std.testing.expectEqual(@as(usize, 6), count(storage, "test \"CR0b 저장소"));
    try std.testing.expectEqual(@as(usize, 4), count(runtime, "test \"CR0b 기록기 수명은"));
    const runtime_product = runtime[0 .. std.mem.indexOf(u8, runtime, "\ntest \"") orelse runtime.len];
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".completeWriterHandoff("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "const incident_runtime = @import(\"incident_runtime.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_runtime.ConnectionIncidentRuntime.create("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.shutdown()"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "defer removeEmptyIncidentDirectory(dir_path);"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "c.unlinkat(owner_fd, \"incidents\", posix.AT.REMOVEDIR)"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "host_adapter.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "process_seal_service.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "@intCast(c.getpid())"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "while (process_nonce == 0)"));
    const storage_product = storage[0 .. std.mem.indexOf(u8, storage, "\ntest \"") orelse storage.len];
    try std.testing.expectEqual(@as(usize, 1), count(storage, "const incident = @import(\"maru\").observability.connection_incident;"));
    try std.testing.expectEqual(@as(usize, 0), count(storage, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(storage, "host_adapter.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub fn takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub fn completeWriterHandoff("));
    try std.testing.expectEqual(@as(usize, 0), count(client, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(client, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "@import(\"maru\").observability.connection_incident"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "@import(\"incident_artifact_store.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(storage_product, "takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 0), count(storage_product, "completeWriterHandoff("));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptTwo(
            allocator,
            "takePendingForWriter(",
            "observability/connection_incident.zig",
            "platform/macos/session_host/incident_artifact_store.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptTwo(
            allocator,
            "completeWriterHandoff(",
            "observability/connection_incident.zig",
            "platform/macos/session_host/incident_artifact_store.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), count(client, "connection_incident.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "connection_incident.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "connection_incident.zig"));
    try std.testing.expectEqual(@as(usize, 7), count(publisher, "test \"CR0b publisher"));
    try std.testing.expectEqual(@as(usize, 1), count(publisher, "const process_seal = @import(\"process_seal_service.zig\");"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "incident_runtime.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "client_slot.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "app_session.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "maru.incident-publisher-authority.v1"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "maru.incident-publisher-lease.v1"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublisherAuthoritySealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublisherLeaseSealInput = struct"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "incident_publisher_registry.Registry", "platform/macos/session_host/incident_publisher_registry.zig"),
    );

    const reason_names = [_][]const u8{
        "connection_eof",          "read_timeout",              "transport_read_failure",        "planned_upgrade_reconnect",
        "capability_incompatible", "outbound_partial_write",    "outbound_write_ambiguous",      "event_queue_overflow",
        "local_queue_exhausted",   "local_resource_exhausted",  "frame_malformed",               "response_correlation_lost",
        "peer_contract_violation", "local_invariant_violation", "external_transfer_quarantined", "attachment_cleanup_failed",
    };
    const incident_reason_block = try declarationBlock(incident, "pub const ConnectionReason = enum(u8) {");
    const poison_reason_block = try declarationBlock(poison, "pub const ConnectionReason = enum {");
    inline for (reason_names, 0..) |name, ordinal| {
        var explicit: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(&explicit, "{s} = {d},", .{ name, ordinal });
        try std.testing.expectEqual(@as(usize, 1), count(incident_reason_block, expected));
        var implicit: [80]u8 = undefined;
        const poison_tag = try std.fmt.bufPrint(&implicit, "{s},", .{name});
        try std.testing.expectEqual(@as(usize, 1), count(poison_reason_block, poison_tag));
    }
}

fn countProductSourcesExcept(allocator: std.mem.Allocator, needle: []const u8, excluded_path: []const u8) !usize {
    return countProductSourcesExceptTwo(allocator, needle, excluded_path, "");
}

fn countProductSourcesExceptTwo(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded_path: []const u8,
    second_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, excluded_path) or
            (second_excluded_path.len != 0 and std.mem.eql(u8, entry.path, second_excluded_path))) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn declarationBlock(source: []const u8, prefix: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, prefix) orelse return error.TestUnexpectedResult;
    const tail = source[start + prefix.len ..];
    const end = std.mem.indexOf(u8, tail, "};") orelse return error.TestUnexpectedResult;
    return tail[0..end];
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
