const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
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
    const bootstrap_contract = try readSource(allocator, "src/platform/macos/session_host/incident_bootstrap_contract.zig");
    defer allocator.free(bootstrap_contract);
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
    const coordinator = try readSource(allocator, "src/platform/macos/session_host/incident_publication_coordinator.zig");
    defer allocator.free(coordinator);
    const gui_owner = try readSource(allocator, "src/platform/macos/session_host/app_process_incident_owner.zig");
    defer allocator.free(gui_owner);
    const reconnect_owner = try readSource(allocator, "src/platform/macos/session_host/reconnect_admission_owner.zig");
    defer allocator.free(reconnect_owner);
    const reconnect_product = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_product_coordinator.zig",
    );
    defer allocator.free(reconnect_product);
    const session_coordinator = try readSource(allocator, "src/platform/macos/session_host/session_host_coordinator.zig");
    defer allocator.free(session_coordinator);
    const remote_runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(remote_runtime);
    const generation_transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(generation_transport);
    const generation_attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(generation_attachment);
    const generation_batch_adapter = try readSource(allocator, "src/platform/macos/session_host/generation_batch_adapter.zig");
    defer allocator.free(generation_batch_adapter);
    const app_host_abi = try readSource(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(app_host_abi);
    const app_host_header = try readSource(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(app_host_header);
    const swift_host = try readSource(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift_host);

    try std.testing.expectEqual(@as(usize, 1), count(incident, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const payload_size: usize = 208;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const envelope_size: usize = 256;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const incident_slot_count: usize = 120;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const aggregate_slot_count: usize = 8;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "fn recordRepeatForTest("));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "pub fn recordRepeat("));
    try std.testing.expectEqual(@as(usize, 21), count(incident, "test \"CR0b core "));
    try std.testing.expectEqual(@as(usize, 5), count(incident, "test \"CR0b service transaction"));
    inline for (.{
        .{ "prepareFirstPublication(", 1, 4 },
        .{ "prepareRepeatPublication(", 1, 4 },
        .{ "commitPreparedEvidenceChecked(", 1, 3 },
        .{ "commitPreparedRepeatEvidenceChecked(", 1, 3 },
        .{ "publishPreparedPendingAndUnlockChecked(", 2, 4 },
    }) |entry| {
        const transaction_call = entry[0];
        try std.testing.expectEqual(@as(usize, entry[1]), count(incident, "self." ++ transaction_call));
        // runtime adapter 정의와 coordinator sole call만 허용한다.
        try std.testing.expectEqual(@as(usize, entry[2]), try countProductSourcesExcept(
            allocator,
            transaction_call,
            "observability/connection_incident.zig",
        ));
    }
    try std.testing.expectEqual(@as(usize, 0), count(incident, "self.abortPreparedPublication("));
    try std.testing.expectEqual(@as(usize, 4), try countProductSourcesExcept(
        allocator,
        "abortPreparedPublication(",
        "observability/connection_incident.zig",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn publishFirst("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn publishRepeat("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn publishCanonical("));
    try std.testing.expectEqual(@as(usize, 6), count(coordinator, "test \"CR0b composite coordinator는"));
    // coordinator만 Client operation과 registry/runtime transaction leaf를 조합한다.
    inline for (.{
        .{ "client_slot.beginIncidentClientOperation(", 7 },
        .{ "client_slot.bindIncidentClientPublication(", 2 },
        .{ "client_slot.bindIncidentClientRepeatPublication(", 2 },
        .{ "client_slot.commitFirstIncidentClientPublicationNoFail(", 1 },
        .{ "client_slot.commitRepeatIncidentClientPublicationNoFail(", 1 },
        .{ "client_slot.finishIncidentClientOperationNoFail(", 8 },
        .{ "runtime.prepareFirstPublication(", 2 },
        .{ "runtime.prepareRepeatPublication(", 2 },
        .{ "runtime.commitPreparedEvidenceChecked(", 1 },
        .{ "runtime.commitPreparedRepeatEvidenceChecked(", 1 },
        .{ "runtime.publishPreparedPendingAndUnlockChecked(", 2 },
        .{ "runtime.wakeCommittedPublication(", 2 },
        .{ "runtime.abortPreparedPublication(", 2 },
    }) |entry| {
        const qualified_call = entry[0];
        try std.testing.expectEqual(@as(usize, entry[1]), count(coordinator, qualified_call));
        try std.testing.expectEqual(@as(usize, 0), try countProductSourcesExcept(
            allocator,
            qualified_call,
            "platform/macos/session_host/incident_publication_coordinator.zig",
        ));
    }
    // Registry는 owner 자체의 hostile 테스트와 runtime live-row 재검증에서도 쓰이므로,
    // coordinator의 조합 호출은 이 파일 안의 exact phrase로 따로 고정한다.
    inline for (.{
        .{ "registry.acquire(", 3 },
        .{ "registry.projectValidatedLease(", 3 },
        .{ "registry.release(", 4 },
    }) |entry| try std.testing.expectEqual(@as(usize, entry[1]), count(coordinator, entry[0]));
    // Alias 이름을 바꿔도 callee symbol과 import owner inventory를 동시에 우회할 수 없다.
    inline for (.{
        "beginIncidentClientOperation(",
        "bindIncidentClientPublication(",
        "bindIncidentClientRepeatPublication(",
        "commitFirstIncidentClientPublicationNoFail(",
        "commitRepeatIncidentClientPublicationNoFail(",
        "finishIncidentClientOperationNoFail(",
    }) |callee| try std.testing.expectEqual(@as(usize, 0), try countProductSourcesExceptTwo(
        allocator,
        callee,
        "platform/macos/session_host/client_slot.zig",
        "platform/macos/session_host/incident_publication_coordinator.zig",
    ));
    inline for (.{
        "prepareFirstPublication(",
        "prepareRepeatPublication(",
        "commitPreparedEvidenceChecked(",
        "commitPreparedRepeatEvidenceChecked(",
        "publishPreparedPendingAndUnlockChecked(",
        "wakeCommittedPublication(",
        "abortPreparedPublication(",
    }) |callee| try std.testing.expectEqual(@as(usize, 0), try countProductSourcesExceptThree(
        allocator,
        callee,
        "observability/connection_incident.zig",
        "platform/macos/session_host/incident_runtime.zig",
        "platform/macos/session_host/incident_publication_coordinator.zig",
    ));
    try std.testing.expectEqual(
        @as(usize, 4),
        try countProductSourcesExcept(allocator, "@import(\"incident_publisher_registry.zig\")", "platform/macos/session_host/incident_publisher_registry.zig"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "@import(\"incident_publisher_registry.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "@import(\"incident_runtime.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 4), count(gui_owner, "test \"CR0b GUI incident owner prerequisite는"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "test \"CR0b managed public poison은"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn publishManagedPoison("));
    try std.testing.expectEqual(@as(usize, 2), count(gui_owner, "fn publishPreparedManagedPoison("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn installPublicationPort("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn revokePublicationPort("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn revokePublicationPortNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub const PublicationTimestampReceipt = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn publicationTimestampReceipt("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub const publication_port_testing_api = if (@import(\"builtin\").is_test) struct"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn install(owner: *AppProcessIncidentOwner) Error!void"));
    try std.testing.expectEqual(@as(usize, 5), count(remote_runtime, "app_process_incident_owner.publication_port_testing_api.install(&owner)"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub const PrePublicationSnapshot = PreparedPublicationSnapshot"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn armPrePublicationSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn disarmPrePublicationSnapshot() void"));
    try std.testing.expectEqual(@as(usize, 5), count(remote_runtime, "publication_port_testing_api.armPrePublicationSnapshot(&pre_publication)"));
    try std.testing.expectEqual(@as(usize, 5), count(remote_runtime, "publication_port_testing_api.disarmPrePublicationSnapshot()"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "const incident_publication_port = session_host.app_process_incident_owner;"));
    try std.testing.expectEqual(@as(usize, 3), count(app_session, "incident_publication_port.publication_port_testing_api.driftSeal()"));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "incident_publication_port.publication_port_testing_api.reset()"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublicationPortSealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublicationTimestampSealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "const incident_publication_port_domain = \"maru.incident-publication-port.v1\";"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "const incident_publication_timestamp_domain = \"maru.incident-publication-timestamp.v1\";"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn incidentPublicationPortSeal("));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn incidentPublicationTimestampSeal("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "process_seal.incidentPublicationPortSeal("));
    // existing-owner 재검증 branch와 fresh bootstrap publication branch가 같은 function 안에서 각각 호출한다.
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "incident_publication_port.installPublicationPort(&app_process_incident_owner)"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "incident_publication_port.revokePublicationPortNoFail(&app_process_incident_owner)"));
    inline for (.{
        "installPublicationPort(",
        "revokePublicationPort(",
        "revokePublicationPortNoFail(",
    }) |port_api| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            port_api,
            "platform/macos/session_host/app_process_incident_owner.zig",
            "platform/macos/app_session.zig",
        ),
    );
    inline for (.{
        "publishPreparedManagedPoison(",
        "publicationTimestampReceipt(",
    }) |port_api| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            port_api,
            "platform/macos/session_host/app_process_incident_owner.zig",
            "platform/macos/app_session.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "test \"CR0b prepared execution poison은"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "test \"CR0b actual read event pump poison은"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "test \"CR0b actual outbound RPC ambiguity는"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "test \"CR0b allocator callback deferred poison은"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "test \"CR0b registered operation deferred poison은"));
    try std.testing.expectEqual(@as(usize, 3), count(remote_runtime, "app_process_incident_owner.publicationTimestampReceipt()"));
    try std.testing.expectEqual(@as(usize, 3), count(remote_runtime, "app_process_incident_owner.publishPreparedManagedPoison("));
    try std.testing.expectEqual(@as(usize, 3), count(remote_runtime, "executeDecodedWithManagedPoison("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "self.currentGeneration().attachment.callDecoded("));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "pub const PreparedExecutionPoisonCapture = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "pub const RegisteredOperationPoisonCapture = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "pub const ReadPumpPoisonCapture = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "pub const ReadPumpPoisonCaptureLifecycle = enum(u8)"));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "reason_present_raw: u8 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn beginReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn endReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "fn captureReadPumpPoison("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "self.captureReadPumpPoison(reason)"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn beginReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn endReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn readAttachmentBatchInternal("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_batch_adapter, "pub fn armReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_batch_adapter, "pub fn disarmReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_batch_adapter, "ReadPumpPoisonCaptureLifecycle.finalized"));
    try std.testing.expectEqual(@as(usize, 1), count(generation_attachment, "pub fn armReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_attachment, "pub fn disarmReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "fn publishReadPumpPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "fn pumpDeltaInner("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "ReadPumpPoisonCaptureLifecycle.finalized"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, ".legacy => return self.pumpDeltaInner()"));
    inline for (.{
        "beginReadPumpPoisonCapture(",
        "endReadPumpPoisonCapture(",
    }) |capture_api| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            capture_api,
            "platform/macos/session_host/client.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
        ),
    );
    inline for (.{
        "armReadPumpPoisonCapture(",
        "disarmReadPumpPoisonCapture(",
    }) |capture_api| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            capture_api,
            "platform/macos/session_host/generation_batch_adapter.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub const PreparedExecutionPoisonCaptureRequest = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(publication, "allocator_source_site_raw"));
    try std.testing.expectEqual(@as(usize, 7), count(client_slot, "allocator_source_site_raw"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, ".allocator_source_site_raw = @intFromEnum(connection_incident.SourceSite.client_cleanup)"));
    try std.testing.expectEqual(@as(usize, 1), count(client, "fn capturePreparedExecutionPoison("));
    try std.testing.expectEqual(@as(usize, 2), count(client, "self.capturePreparedExecutionPoison("));
    try std.testing.expectEqual(@as(usize, 2), count(client_slot, "settlePreWireForDeferredPublication("));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "settlePreWireWithResolvedReason("));
    try std.testing.expectEqual(@as(usize, 2), count(client_slot, "settlePreWireTerminalForDeferredPublication("));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "settlePreparedRpcLeaseOwnedWithReasonAndReleaseOrFailStop("));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, "finalizePreparedExecutionPoisonCaptureNoFail("));
    inline for (.{
        "pending_request_count",
        "outbound_phase_raw",
        "outbound_offset",
        "outbound_length",
        "queue_bytes",
    }) |snapshot_field| try std.testing.expectEqual(@as(usize, 3), count(gui_owner, snapshot_field));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub const RegisteredOperationPoisonCaptureRequest = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub const registered_operation_poison_testing_api = if (builtin.is_test) struct"));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn armRegisteredOperationPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn captureRegisteredOperationPoison("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_transport, "pub fn takeEventProjectedWithPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(generation_attachment, "pub fn takeEventWithPoisonCapture("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "self.takeGenerationEventWithManagedPoison(generation)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "takeEventProjectedWithPoisonCapture(",
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "takeEventWithPoisonCapture(",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn prepareManagedPoisonRequest("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn prepareManagedPoisonRequest("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn prepareManagedPoison("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "publishManagedPoison(", "platform/macos/session_host/app_process_incident_owner.zig"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "coordinator.publishCanonical("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn ensureReady("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn publisher("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn shutdown("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub const testing_api = if (@import(\"builtin\").is_test) struct"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "pub fn markWriterFailed(self: *AppProcessIncidentOwner)"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "AppProcessIncidentOwner.testing_api.markWriterFailed("));
    const session_host_barrel = try readSource(allocator, "src/platform/macos/session_host.zig");
    defer allocator.free(session_host_barrel);
    try std.testing.expectEqual(@as(usize, 1), count(session_host_barrel, "@import(\"session_host/app_process_incident_owner.zig\")"));
    try std.testing.expectEqual(
        @as(usize, 2),
        try countProductSourcesExcept(allocator, "app_process_incident_owner.zig", "platform/macos/session_host/app_process_incident_owner.zig"),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        try countProductSourcesExcept(allocator, "AppProcessIncidentOwner", "platform/macos/session_host/app_process_incident_owner.zig"),
    );
    try std.testing.expectEqual(
        // app-global storage와 owner testing facade만 macOS 전용 namespace를 직접 쓴다. ABI outcome은
        // Linux cross-compile 가능한 app_session 중립 enum이라 owner namespace를 참조하지 않는다.
        @as(usize, 4),
        try countProductSourcesExcept(allocator, ".app_process_incident_owner", "platform/macos/session_host/app_process_incident_owner.zig"),
    );
    // daemon의 한 acquire는 incident registry가 아니라 owner-lock lifetime lease다.
    try std.testing.expectEqual(@as(usize, 1), count(daemon, ".acquire("));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "incident_registry.acquire("));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "incident_registry.release("));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, ".projectValidatedLease("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".acquire("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".release("));
    // first/repeat prepare·commit과 공통 abort/pending/wake가 live row를 각각 재검증한다.
    try std.testing.expectEqual(@as(usize, 7), count(runtime, ".projectValidatedLease("));
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
    try std.testing.expectEqual(@as(usize, 7), count(publication, "test \"CR0b poison publication 계약은"));
    try std.testing.expectEqual(@as(usize, 3), count(reconnect_owner, "test \"CR0b reconnect admission owner는"));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_owner, "pub fn admit("));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_owner, "pub fn peek("));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_owner, "pub fn consume("));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_owner, "pub fn ownedBy("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "self.reconnect_admissions.ownedBy("));
    // Publication owner와 CR1 scheduler, e3b2 stable runtime/drain, e3c1 sole drain,
    // CR6e-c3b2a product coordinator만 bounded row를 읽는다.
    // 각 소비자 import를 별도로 고정해 전역 수치만 느슨하게 늘리는 우회를 막는다.
    try std.testing.expectEqual(@as(usize, 6), try countProductSourcesExcept(
        allocator,
        "reconnect_admission_owner.zig",
        "platform/macos/session_host/reconnect_admission_owner.zig",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(session_coordinator, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_product, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "self.reconnect_admissions.preflight("));
    try std.testing.expectEqual(@as(usize, 1), count(gui_owner, "self.reconnect_admissions.admitAfterPreflightNoFail("));
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
    try std.testing.expectEqual(@as(usize, 5), count(client_slot, "test \"CR0b Client incident operation은"));
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
        .{ "beginIncidentClientOperation(", 12 },
        // declaration 1 + success 1 + copied/seal/digest/coherent/commit drift 5행이다.
        .{ "bindIncidentClientPublication(", 7 },
        .{ "commitFirstIncidentClientPublicationNoFail(", 2 },
        .{ "finishIncidentClientOperationNoFail(", 9 },
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
    try std.testing.expectEqual(@as(usize, 5), count(app_session, "test \"CR0b AppSession publication은"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "fn claimInstalledRemoteBackend("));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "if (!claimInstalledRemoteBackend("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub const DeinitTrace = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "RemoteSessionAdapter.testing_api.arm(&deinit_trace)"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "test \"CR0b GUI current first는"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "test \"CR0b GUI restore first 뒤 current는"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "test \"CR0b GUI multiple window와 adapter는"));
    try std.testing.expectEqual(@as(usize, 3), count(app_session, "test \"CR0b AppHost incident ABI prerequisite는"));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "self.ensureProcessIncidentOwner()"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_header, "uint32_t maru_macos_incident_owner_shutdown(void);"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_header, "uint32_t maru_macos_remote_backend_settle(void);"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_abi, "pub export fn maru_macos_incident_owner_shutdown() u32"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_abi, "pub export fn maru_macos_remote_backend_settle() u32"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_abi, "session_mod.shutdownProcessIncidentOwner()"));
    try std.testing.expectEqual(@as(usize, 1), count(app_host_abi, "session_mod.settleProcessRemoteBackendForTermination()"));
    try std.testing.expectEqual(@as(usize, 1), count(swift_host, "maru_macos_incident_owner_shutdown()"));
    try std.testing.expectEqual(@as(usize, 1), count(swift_host, "maru_macos_remote_backend_settle()"));
    const termination_start = std.mem.indexOf(u8, swift_host, "func applicationWillTerminate(_ notification: Notification) {") orelse return error.TestUnexpectedResult;
    const termination_end = std.mem.indexOfPos(u8, swift_host, termination_start, "\n    func applicationShouldTerminateAfterLastWindowClosed(") orelse return error.TestUnexpectedResult;
    const termination = swift_host[termination_start..termination_end];
    try std.testing.expectEqual(@as(usize, 1), count(termination, "shutdownAppSession(preserveWebPanelsFor: mainSurface)"));
    try std.testing.expectEqual(@as(usize, 1), count(termination, "maru_macos_remote_backend_settle()"));
    try std.testing.expectEqual(@as(usize, 1), count(termination, "maru_macos_incident_owner_shutdown()"));
    const shutdown_sessions = std.mem.indexOf(u8, termination, "shutdownAppSession(preserveWebPanelsFor: mainSurface)") orelse return error.TestUnexpectedResult;
    const settle_backend = std.mem.indexOf(u8, termination, "maru_macos_remote_backend_settle()") orelse return error.TestUnexpectedResult;
    const shutdown_incidents = std.mem.indexOf(u8, termination, "maru_macos_incident_owner_shutdown()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shutdown_sessions < settle_backend and settle_backend < shutdown_incidents);
    try expectExecutableSwiftStatement(termination, shutdown_sessions, "shutdownAppSession(");
    try expectExecutableSwiftStatement(termination, settle_backend, "_ = maru_macos_remote_backend_settle()");
    try expectExecutableSwiftStatement(termination, shutdown_incidents, "_ = maru_macos_incident_owner_shutdown()");
    // ordinary Window close는 process-global owner를 정산하지 않는다.
    const window_close_start = std.mem.indexOf(u8, swift_host, "func windowWillClose(_ notification: Notification) {") orelse return error.TestUnexpectedResult;
    const window_close_end = std.mem.indexOfPos(u8, swift_host, window_close_start, "\n    func windowDidResize(") orelse return error.TestUnexpectedResult;
    const window_close = swift_host[window_close_start..window_close_end];
    try std.testing.expectEqual(@as(usize, 0), count(window_close, "maru_macos_incident_owner_shutdown()"));
    try std.testing.expectEqual(@as(usize, 0), count(window_close, "maru_macos_remote_backend_settle()"));
    // shutdownAppSession은 quick과 모든 일반 Window/AppSession을 동기로 settlement하지만 incident owner는 건드리지 않는다.
    const shutdown_body_start = std.mem.indexOf(u8, swift_host, "private func shutdownAppSession(preserveWebPanelsFor summarySurface: TerminalSurface? = nil) {") orelse return error.TestUnexpectedResult;
    const shutdown_body_end = std.mem.indexOfPos(u8, swift_host, shutdown_body_start, "\n    private func smokeDurationMs(") orelse return error.TestUnexpectedResult;
    const shutdown_body = swift_host[shutdown_body_start..shutdown_body_end];
    inline for (.{ "tearDownQuickTerminalAfterGlobalPreflight()", "let snapshot = windows", "for surface in snapshot", "teardownWindowSurface(surface," }) |needle|
        try std.testing.expectEqual(@as(usize, 1), count(shutdown_body, needle));
    const quick = std.mem.indexOf(u8, shutdown_body, "tearDownQuickTerminalAfterGlobalPreflight()") orelse return error.TestUnexpectedResult;
    const snapshot = std.mem.indexOf(u8, shutdown_body, "let snapshot = windows") orelse return error.TestUnexpectedResult;
    const loop = std.mem.indexOf(u8, shutdown_body, "for surface in snapshot") orelse return error.TestUnexpectedResult;
    const teardown = std.mem.indexOf(u8, shutdown_body, "teardownWindowSurface(surface,") orelse return error.TestUnexpectedResult;
    try std.testing.expect(quick < snapshot and snapshot < loop and loop < teardown);
    try expectExecutableSwiftStatement(shutdown_body, quick, "tearDownQuickTerminalAfterGlobalPreflight()");
    try expectExecutableSwiftStatement(shutdown_body, snapshot, "let snapshot = windows");
    try expectExecutableSwiftStatement(shutdown_body, loop, "for surface in snapshot");
    try expectExecutableSwiftStatement(shutdown_body, teardown, "teardownWindowSurface(surface,");
    try std.testing.expectEqual(@as(usize, 0), count(shutdown_body, "maru_macos_incident_owner_shutdown()"));
    try std.testing.expectEqual(@as(usize, 0), count(shutdown_body, "maru_macos_remote_backend_settle()"));
    // 제품 정의가 파일 중간의 테스트 뒤에도 이어지므로 첫 test 이전 substring으로 자르면 실제 caller를 놓친다.
    // 전체 source의 addOwned 여섯 호출은 기존 actual-host fixture 둘, bootstrap5 owned-pool fixture 하나,
    // singleton rollback의 created/sibling/rejected 세 row뿐이고,
    // managed 제품 entrypoint는 공용 transaction만 쓴다.
    try std.testing.expectEqual(@as(usize, 6), count(app_session, ".addOwned("));
    // current 제품 1, 기존 fixture 2, singleton rollback의 rejected row 1만 spawn host를 직접 선택한다.
    try std.testing.expectEqual(@as(usize, 4), count(app_session, ".setSpawnHost("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "app_remote_host_pool.?.spawnHostId() == null"));
    // current promotion 1과 bootstrap5 settlement readiness의 backend-present conjunction 1이다.
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "if (app_remote_backend != null and"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "backend.promoteToSpawnAndAttach(&app_remote_host_pool.?)"));
    try std.testing.expectEqual(@as(usize, 11), count(incident, "test \"CR0b writer"));
    try std.testing.expectEqual(@as(usize, 6), count(storage, "test \"CR0b 저장소"));
    try std.testing.expectEqual(@as(usize, 7), count(runtime, "test \"CR0b 기록기 수명은"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn readyForProcessSettlement("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, ".readyForProcessSettlement()) return .inactive"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub const SettlementBlocker = enum"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, ".runtime,\n        .reservation,\n        .close_operation,\n        .close_sweep,"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "test \"CR0b daemon incident bootstrap prerequisite는"));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "pub const Transcript = extern struct"));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "pub const Role = enum(u8) { gui = 1, daemon = 2 };"));
    try std.testing.expectEqual(@as(usize, 2), count(bootstrap_contract, "expected_role"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, ".role_raw = @intFromEnum(session_host.incident_bootstrap_contract.Role.gui)"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, ".role_raw = @intFromEnum(incident_bootstrap_contract.Role.daemon)"));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "test \"CR0b bootstrap transcript 계약은"));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "test \"CR0b daemon bootstrap은 GUI와 독립된 nonce와 sequence owner를 설치한다\""));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "test \"CR0b bootstrap 4 GUI child는"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "test \"CR0b bootstrap 4 daemon child는"));
    try std.testing.expectEqual(@as(usize, 2), count(bootstrap_contract, "try runChild("));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "try std.testing.expect(!std.mem.eql(u8, gui_path, daemon_path))"));
    try std.testing.expectEqual(@as(usize, 1), count(bootstrap_contract, "std.c.kill(pid, std.c.SIG.KILL)"));
    try std.testing.expectEqual(@as(usize, 2), count(bootstrap_contract, "std.c.waitpid("));
    // 선언1 + 제품 runSessionHost1 + focused prerequisite1 + bootstrap4 child1.
    try std.testing.expectEqual(@as(usize, 4), count(daemon, "bootstrapIncidentRuntime("));
    const runtime_product = runtime[0 .. std.mem.indexOf(u8, runtime, "\ntest \"") orelse runtime.len];
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".completeWriterHandoff("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "const incident_runtime = @import(\"incident_runtime.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "const incident_publisher_registry = @import(\"incident_publisher_registry.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_runtime.ConnectionIncidentRuntime.create("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.installPublisherRegistry(&incident_registry)"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.shutdownPublished(&incident_registry)"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "incident_owner.shutdown()"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "if (remove_empty) removeEmptyIncidentDirectory(dir_path);"));
    // published shutdown과 unpublished abort 모두 clean/degraded joined에서만 path를 제거하고 detached는 보존한다.
    try std.testing.expectEqual(@as(usize, 2), count(daemon, "remove_empty = outcome == .joined or outcome == .degraded_joined"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.abortUnpublished()"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR0b 기록기 수명은 막힌 스레드를 200 ms 뒤 detach하고 backing을 보존한다\""));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "c.unlinkat(owner_fd, \"incidents\", posix.AT.REMOVEDIR)"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "host_adapter.zig"));
    // daemon bootstrap이 process seal을 직접 준비하는 한 경로만 허용한다.
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "const process_seal_service = @import(\"process_seal_service.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "process_seal_service.prepare("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "process_seal_service.commitReady("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "resetInheritedForkedDaemonProcessSealIfPresent()"));
    // 제품 bootstrap의 PID 결속 2회와 focused prerequisite의 관측 1회를 역할별로 분리한다.
    const daemon_product = daemon[0 .. std.mem.indexOf(u8, daemon, "\ntest \"") orelse daemon.len];
    try std.testing.expectEqual(@as(usize, 2), count(daemon_product, "@intCast(c.getpid())"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon[daemon_product.len..], "@intCast(c.getpid())"));
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
        // runtime writer 1개와 coordinator first/repeat prerequisite의 실 handoff 5개를 따로 고정한다.
        @as(usize, 6),
        try countProductSourcesExceptTwo(
            allocator,
            "takePendingForWriter(",
            "observability/connection_incident.zig",
            "platform/macos/session_host/incident_artifact_store.zig",
        ),
    );
    try std.testing.expectEqual(
        // coordinator first/repeat prerequisite의 detail·aggregate 완료 네 행과 runtime writer 한 행을 고정한다.
        @as(usize, 5),
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
    try std.testing.expectEqual(@as(usize, 1), count(publisher, "test \"CR0b authority exhaustion child는"));
    try std.testing.expectEqual(@as(usize, 1), count(publisher, "const process_seal = @import(\"process_seal_service.zig\");"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "incident_runtime.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "client_slot.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher, "app_session.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "maru.incident-publisher-authority.v1"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "maru.incident-publisher-lease.v1"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublisherAuthoritySealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const IncidentPublisherLeaseSealInput = struct"));
    // shipping daemon이 runtime과 같은 lifetime으로 singleton registry를 직접 소유하는 한 역할만 허용한다.
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_publisher_registry.Registry = .{}"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.installPublisherRegistry(&incident_registry)"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "incident_owner.shutdownPublished(&incident_registry)"));

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

test "CR1 reconnect scheduler 경계는 sealed inline transition만 제품에 연다" {
    const allocator = std.testing.allocator;
    const owner = try readSource(allocator, "src/platform/macos/session_host/reconnect_admission_owner.zig");
    defer allocator.free(owner);
    const scheduler = try readSource(allocator, "src/platform/macos/session_host/reconnect_scheduler.zig");
    defer allocator.free(scheduler);
    const product_coordinator = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_product_coordinator.zig",
    );
    defer allocator.free(product_coordinator);
    const seal_service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_service);
    const seal_types = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_types);

    try std.testing.expectEqual(@as(usize, 4), count(scheduler, "test \"CR1 "));
    try std.testing.expectEqual(@as(usize, 8), count(scheduler, "@import("));
    try std.testing.expectEqual(@as(usize, 1), count(scheduler, "@import(\"std\")"));
    try std.testing.expectEqual(@as(usize, 1), count(scheduler, "@import(\"reconnect_admission_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(scheduler, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(scheduler, "@import(\"client_poison.zig\")"));
    try std.testing.expectEqual(@as(usize, 2), count(scheduler, "@import(\"maru\")"));
    try std.testing.expectEqual(@as(usize, 2), count(scheduler, "@import(\"client_slot.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(scheduler, "incident_runtime.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(scheduler, "pub fn runOnce("));
    // 제품 `runOnce` 1회와 같은 파일 hostile oracle 1회를 역할별 exact inventory로 고정한다.
    try std.testing.expectEqual(@as(usize, 2), count(scheduler, "owner.prepareDispatch(&dispatch)"));
    try std.testing.expectEqual(@as(usize, 5), count(scheduler, "owner.settleDispatch(&dispatch,"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn prepareDispatch("));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn preparedProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn settleDispatch("));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn peekScheduled("));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn consumeScheduled("));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "objectsOverlap(self, out)"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_types, "pub const PreparedReconnectDispatchSealInput"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_service, "pub fn preparedReconnectDispatchSeal("));
    try std.testing.expectEqual(@as(usize, 0), try countProductSourcesExcept(
        allocator,
        "reconnect_scheduler.zig",
        "platform/macos/session_host/reconnect_scheduler.zig",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(product_coordinator, ".prepareDispatch("));
    try std.testing.expectEqual(@as(usize, 1), try countProductSourcesExceptThree(
        allocator,
        ".prepareDispatch(",
        "platform/macos/session_host/reconnect_admission_owner.zig",
        "platform/macos/session_host/reconnect_scheduler.zig",
        "platform/macos/session_host/remote_term_backend.zig",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(product_coordinator, ".settleDispatch("));
    try std.testing.expectEqual(@as(usize, 2), try countProductSourcesExceptThree(
        allocator,
        ".settleDispatch(",
        "platform/macos/session_host/reconnect_admission_owner.zig",
        "platform/macos/session_host/reconnect_scheduler.zig",
        "platform/macos/session_host/remote_term_backend.zig",
    ));
}

fn expectExecutableSwiftStatement(source: []const u8, position: usize, expected: []const u8) !void {
    if (!swiftCodeAt(source, position)) return error.TestUnexpectedResult;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..position], '\n')) |at| at + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, position, '\n') orelse source.len;
    const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
    if (!std.mem.startsWith(u8, line, expected)) return error.TestUnexpectedResult;
}

fn swiftCodeAt(source: []const u8, position: usize) bool {
    const State = enum { code, line_comment, block_comment, string, multiline_string };
    var state: State = .code;
    var block_depth: usize = 0;
    var escaped = false;
    var i: usize = 0;
    while (i < position) {
        switch (state) {
            .code => {
                if (source[i] == '#' and i + 1 < position and source[i + 1] == '"') return false;
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '*') {
                    state = .block_comment;
                    block_depth = 1;
                    i += 2;
                    continue;
                }
                if (i + 2 < position and std.mem.eql(u8, source[i .. i + 3], "\"\"\"")) {
                    state = .multiline_string;
                    i += 3;
                    continue;
                }
                if (source[i] == '"') {
                    state = .string;
                    escaped = false;
                    i += 1;
                    continue;
                }
                i += 1;
            },
            .line_comment => {
                if (source[i] == '\n') state = .code;
                i += 1;
            },
            .block_comment => {
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '*') {
                    block_depth += 1;
                    i += 2;
                    continue;
                }
                if (i + 1 < position and source[i] == '*' and source[i + 1] == '/') {
                    block_depth -= 1;
                    i += 2;
                    if (block_depth == 0) state = .code;
                    continue;
                }
                i += 1;
            },
            .string => {
                if (escaped) {
                    escaped = false;
                    i += 1;
                    continue;
                }
                if (source[i] == '\\') {
                    escaped = true;
                    i += 1;
                    continue;
                }
                if (source[i] == '"') state = .code;
                i += 1;
            },
            .multiline_string => {
                if (i + 2 < position and std.mem.eql(u8, source[i .. i + 3], "\"\"\"") and !swiftDelimiterEscaped(source, i)) {
                    state = .code;
                    i += 3;
                    continue;
                }
                i += 1;
            },
        }
    }
    return state == .code;
}

fn swiftDelimiterEscaped(source: []const u8, position: usize) bool {
    var slash_count: usize = 0;
    var i = position;
    while (i > 0 and source[i - 1] == '\\') : (i -= 1) slash_count += 1;
    return slash_count % 2 == 1;
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
    return countProductSourcesExceptThree(allocator, needle, excluded_path, second_excluded_path, "");
}

fn countProductSourcesExceptThree(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, excluded_path) or
            (second_excluded_path.len != 0 and std.mem.eql(u8, entry.path, second_excluded_path)) or
            (third_excluded_path.len != 0 and std.mem.eql(u8, entry.path, third_excluded_path))) continue;
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
