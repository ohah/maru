//! CR0b publisher lease와 service mutex, Client operation을 한 transaction으로 묶는 제품 coordinator.

const std = @import("std");
const publication = @import("maru").observability.incident_publication_contract;
const incident = @import("maru").observability.connection_incident;
const client_mod = @import("client.zig");
const client_slot = @import("client_slot.zig");
const registry_mod = @import("incident_publisher_registry.zig");
const runtime_mod = @import("incident_runtime.zig");
const process_seal = @import("process_seal_service.zig");

pub const Error = publication.InputError || client_slot.IncidentOperationError || registry_mod.Error || runtime_mod.Error;

const PreparedFirstOwner = struct {
    publication: publication.PreparedIncidentPublication = .{},
    lease: registry_mod.IncidentPublisherLease = .{},
};

const CoordinatorTestHook = if (@import("builtin").is_test) struct {
    threadlocal var drift_commit_authority: bool = false;
    threadlocal var transcript: ?*FixedTranscript = null;
} else struct {};

const Stage = enum(u8) {
    client_held,
    publisher_acquired,
    service_prepared,
    client_bound,
    composite_held,
    ring_evidence,
    client_committed,
    pending_unlocked,
    wake_observed,
    publisher_released,
    client_released,
    service_aborted,
    id_stored,
    key_stored,
    reason_stored,
};

const FixedTranscript = struct {
    items: [20]Stage = undefined,
    len: usize = 0,

    fn append(self: *FixedTranscript, stage: Stage) void {
        if (self.len >= self.items.len) @panic("coordinator transcript overflow");
        self.items[self.len] = stage;
        self.len += 1;
    }

    fn slice(self: *const FixedTranscript) []const Stage {
        return self.items[0..self.len];
    }
};

fn appendLeafStage(stage: Stage) void {
    if (@import("builtin").is_test) {
        if (CoordinatorTestHook.transcript) |transcript| transcript.append(stage);
    }
}

fn traceClient(stage: u8) void {
    appendLeafStage(switch (stage) {
        1 => .client_held,
        2 => .client_bound,
        3 => .id_stored,
        4 => .key_stored,
        5 => .reason_stored,
        6 => .client_released,
        else => @panic("unknown Client publication stage"),
    });
}

fn traceService(stage: u8) void {
    appendLeafStage(switch (stage) {
        1 => .service_prepared,
        2 => .ring_evidence,
        3 => .pending_unlocked,
        4 => .service_aborted,
        else => @panic("unknown service publication stage"),
    });
}

fn traceRegistry(stage: u8) void {
    appendLeafStage(switch (stage) {
        1 => .publisher_acquired,
        2 => .publisher_released,
        else => @panic("unknown registry publication stage"),
    });
}

fn traceRuntime(stage: u8) void {
    appendLeafStage(switch (stage) {
        1 => .wake_observed,
        else => @panic("unknown runtime publication stage"),
    });
}

fn armTranscript(transcript: *FixedTranscript) void {
    CoordinatorTestHook.transcript = transcript;
    client_slot.incident_publication_testing.armTrace(traceClient);
    incident.ConnectionIncidentService.transaction_testing.armTrace(traceService);
    registry_mod.transaction_testing.armTrace(traceRegistry);
    runtime_mod.ConnectionIncidentRuntime.testing_api.armPublicationTrace(traceRuntime);
}

fn disarmTranscript() void {
    client_slot.incident_publication_testing.armTrace(null);
    incident.ConnectionIncidentService.transaction_testing.armTrace(null);
    registry_mod.transaction_testing.armTrace(null);
    runtime_mod.ConnectionIncidentRuntime.testing_api.armPublicationTrace(null);
    CoordinatorTestHook.transcript = null;
}

pub fn publishFirst(
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    query: client_slot.IncidentOperationQuery,
    input: publication.IncidentInput,
) Error!publication.IncidentCommitResult {
    var owner: PreparedFirstOwner = .{};
    try prepareFirst(&owner, registry, runtime, query, input);
    return commitFirst(&owner, registry, runtime, input);
}

pub fn publishRepeat(
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    query: client_slot.IncidentOperationQuery,
    input: publication.IncidentInput,
) Error!publication.IncidentCommitResult {
    var owner: PreparedFirstOwner = .{};
    try prepareRepeat(&owner, registry, runtime, query, input);
    return commitRepeat(&owner, registry, runtime, input);
}

/// The managed caller supplies no first/repeat flag. The held Client operation is the only source
/// of that decision, so a concurrent or stale caller cannot select a weaker transaction branch.
pub fn publishCanonical(
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    query: client_slot.IncidentOperationQuery,
    input: publication.IncidentInput,
) Error!publication.IncidentCommitResult {
    var owner: PreparedFirstOwner = .{};
    const service_input_base = try publication.serviceInput(input);
    const input_digest = try publication.inputDigest(input);
    const input_fingerprint = try publication.fingerprint(input);
    try client_slot.beginIncidentClientOperation(query, &owner.publication.client);
    errdefer finishClient(&owner.publication.client);
    const client: *const client_mod.Client = @ptrFromInt(owner.publication.client.authority.client_addr);
    const first = client.first_poison_reason == null and client.first_incident_id.sequence == 0 and
        std.meta.eql(client.incident_repeat_key, publication.IncidentRepeatKey{});
    const repeat = client.first_poison_reason != null and client.first_incident_id.sequence != 0 and
        publication.validRepeatKeyShape(client.incident_repeat_key, @intFromPtr(&client.incident_repeat_key)) and
        std.mem.eql(u8, &client.incident_repeat_key.fingerprint, &input_fingerprint);
    if (!first and !repeat) return error.InvalidOwner;

    try registry.acquire(&owner.lease);
    errdefer releasePublisher(registry, &owner.lease);
    const projection = try registry.projectValidatedLease(&owner.lease);
    if (!runtime.validatesPublisherLease(projection)) return error.InvalidAuthority;
    var service_input = service_input_base;
    if (repeat) service_input.incident_id = client.incident_repeat_key.incident_id;
    if (first)
        try runtime.prepareFirstPublication(registry, &owner.lease, service_input, &owner.publication.service)
    else
        try runtime.prepareRepeatPublication(registry, &owner.lease, service_input, &owner.publication.service);
    errdefer abortService(runtime, registry, &owner.lease, &owner.publication.service);

    if (first) {
        try client_slot.bindIncidentClientPublication(&owner.publication.client, .{
            .authority = owner.publication.client.authority,
            .input_digest = input_digest,
            .incident_id = owner.publication.service.incident_id,
            .fingerprint = input_fingerprint,
            .reason_raw = input.reason_raw,
        });
    } else {
        try client_slot.bindIncidentClientRepeatPublication(&owner.publication.client, .{
            .authority = owner.publication.client.authority,
            .input_digest = input_digest,
            .incident_id = client.incident_repeat_key.incident_id,
            .fingerprint = input_fingerprint,
        });
    }
    owner.publication.self_addr = @intFromPtr(&owner.publication);
    owner.publication.kind_raw = @intFromEnum(if (first) publication.PublicationKind.first else .repeat);
    owner.publication.publisher = projection;
    owner.publication.input_digest = input_digest;
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.held);
    owner.publication.seal = compositeSeal(&owner.publication);
    appendLeafStage(.composite_held);
    return if (first)
        commitFirst(&owner, registry, runtime, input)
    else
        commitRepeat(&owner, registry, runtime, input);
}

fn prepareFirst(
    owner: *PreparedFirstOwner,
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    query: client_slot.IncidentOperationQuery,
    input: publication.IncidentInput,
) Error!void {
    if (!std.meta.eql(owner.*, PreparedFirstOwner{})) return error.InvalidOwner;
    const service_input = try publication.serviceInput(input);
    const input_digest = try publication.inputDigest(input);
    const input_fingerprint = try publication.fingerprint(input);
    try client_slot.beginIncidentClientOperation(query, &owner.publication.client);
    errdefer finishClient(&owner.publication.client);
    try registry.acquire(&owner.lease);
    errdefer releasePublisher(registry, &owner.lease);
    const lease_projection = try registry.projectValidatedLease(&owner.lease);
    if (!runtime.validatesPublisherLease(lease_projection)) return error.InvalidAuthority;
    try runtime.prepareFirstPublication(registry, &owner.lease, service_input, &owner.publication.service);
    errdefer abortService(runtime, registry, &owner.lease, &owner.publication.service);

    var commit: publication.FirstPublicationCommit = .{
        .authority = owner.publication.client.authority,
        .input_digest = input_digest,
        .incident_id = owner.publication.service.incident_id,
        .fingerprint = input_fingerprint,
        .reason_raw = input.reason_raw,
    };
    if (@import("builtin").is_test and CoordinatorTestHook.drift_commit_authority)
        commit.authority.connection_generation +%= 1;
    try client_slot.bindIncidentClientPublication(&owner.publication.client, commit);
    owner.publication.self_addr = @intFromPtr(&owner.publication);
    owner.publication.kind_raw = @intFromEnum(publication.PublicationKind.first);
    owner.publication.publisher = lease_projection;
    owner.publication.input_digest = input_digest;
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.held);
    owner.publication.seal = compositeSeal(&owner.publication);
    appendLeafStage(.composite_held);
}

fn commitFirst(
    owner: *PreparedFirstOwner,
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    input: publication.IncidentInput,
) publication.IncidentCommitResult {
    if (!validComposite(&owner.publication, .first)) process_seal.fatalIntegrity(.incident_authority);
    const commit: publication.FirstPublicationCommit = .{
        .authority = owner.publication.client.authority,
        .input_digest = owner.publication.input_digest,
        .incident_id = owner.publication.service.incident_id,
        .fingerprint = publication.fingerprint(input) catch process_seal.fatalIntegrity(.incident_authority),
        .reason_raw = input.reason_raw,
    };
    runtime.commitPreparedEvidenceChecked(registry, &owner.lease, &owner.publication.service);
    client_slot.commitFirstIncidentClientPublicationNoFail(&owner.publication.client, commit);
    appendLeafStage(.client_committed);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.evidence_committed);
    owner.publication.seal = compositeSeal(&owner.publication);
    runtime.publishPreparedPendingAndUnlockChecked(registry, &owner.lease, &owner.publication.service);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.wake_ready);
    owner.publication.seal = compositeSeal(&owner.publication);
    const wake = runtime.wakeCommittedPublication(registry, &owner.lease, &owner.publication);
    registry.release(&owner.lease) catch process_seal.fatalIntegrity(.incident_authority);
    client_slot.finishIncidentClientOperationNoFail(&owner.publication.client);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.published);
    owner.publication.seal = compositeSeal(&owner.publication);
    return .{ .publication = owner.publication.service.result, .wake = wake, .kind_raw = @intFromEnum(publication.PublicationKind.first) };
}

fn abortPreparedFirst(
    owner: *PreparedFirstOwner,
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
) void {
    if (!validComposite(&owner.publication, .first)) process_seal.fatalIntegrity(.incident_authority);
    runtime.abortPreparedPublication(registry, &owner.lease, &owner.publication.service) catch
        process_seal.fatalIntegrity(.incident_authority);
    registry.release(&owner.lease) catch process_seal.fatalIntegrity(.incident_authority);
    client_slot.finishIncidentClientOperationNoFail(&owner.publication.client);
}

fn prepareRepeat(
    owner: *PreparedFirstOwner,
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    query: client_slot.IncidentOperationQuery,
    input: publication.IncidentInput,
) Error!void {
    if (!std.meta.eql(owner.*, PreparedFirstOwner{})) return error.InvalidOwner;
    var service_input = try publication.serviceInput(input);
    const input_digest = try publication.inputDigest(input);
    const input_fingerprint = try publication.fingerprint(input);
    try client_slot.beginIncidentClientOperation(query, &owner.publication.client);
    errdefer finishClient(&owner.publication.client);
    const client: *const client_mod.Client = @ptrFromInt(owner.publication.client.authority.client_addr);
    const repeat_key = client.incident_repeat_key;
    if (!publication.validRepeatKeyShape(repeat_key, @intFromPtr(&client.incident_repeat_key)) or
        !std.mem.eql(u8, &repeat_key.fingerprint, &input_fingerprint))
        return error.InvalidOwner;
    service_input.incident_id = repeat_key.incident_id;
    try registry.acquire(&owner.lease);
    errdefer releasePublisher(registry, &owner.lease);
    const lease_projection = try registry.projectValidatedLease(&owner.lease);
    if (!runtime.validatesPublisherLease(lease_projection)) return error.InvalidAuthority;
    try runtime.prepareRepeatPublication(registry, &owner.lease, service_input, &owner.publication.service);
    errdefer abortService(runtime, registry, &owner.lease, &owner.publication.service);
    const commit: publication.RepeatPublicationCommit = .{
        .authority = owner.publication.client.authority,
        .input_digest = input_digest,
        .incident_id = repeat_key.incident_id,
        .fingerprint = input_fingerprint,
    };
    try client_slot.bindIncidentClientRepeatPublication(&owner.publication.client, commit);
    owner.publication.self_addr = @intFromPtr(&owner.publication);
    owner.publication.kind_raw = @intFromEnum(publication.PublicationKind.repeat);
    owner.publication.publisher = lease_projection;
    owner.publication.input_digest = input_digest;
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.held);
    owner.publication.seal = compositeSeal(&owner.publication);
    appendLeafStage(.composite_held);
}

fn commitRepeat(
    owner: *PreparedFirstOwner,
    registry: *registry_mod.Registry,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    input: publication.IncidentInput,
) publication.IncidentCommitResult {
    if (!validComposite(&owner.publication, .repeat)) process_seal.fatalIntegrity(.incident_authority);
    const commit: publication.RepeatPublicationCommit = .{
        .authority = owner.publication.client.authority,
        .input_digest = owner.publication.input_digest,
        .incident_id = owner.publication.service.incident_id,
        .fingerprint = publication.fingerprint(input) catch process_seal.fatalIntegrity(.incident_authority),
    };
    runtime.commitPreparedRepeatEvidenceChecked(registry, &owner.lease, &owner.publication.service);
    client_slot.commitRepeatIncidentClientPublicationNoFail(&owner.publication.client, commit);
    appendLeafStage(.client_committed);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.evidence_committed);
    owner.publication.seal = compositeSeal(&owner.publication);
    runtime.publishPreparedPendingAndUnlockChecked(registry, &owner.lease, &owner.publication.service);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.wake_ready);
    owner.publication.seal = compositeSeal(&owner.publication);
    const wake = runtime.wakeCommittedPublication(registry, &owner.lease, &owner.publication);
    registry.release(&owner.lease) catch process_seal.fatalIntegrity(.incident_authority);
    client_slot.finishIncidentClientOperationNoFail(&owner.publication.client);
    owner.publication.lifecycle_raw = @intFromEnum(publication.PublicationLifecycle.published);
    owner.publication.seal = compositeSeal(&owner.publication);
    return .{ .publication = owner.publication.service.result, .wake = wake, .kind_raw = @intFromEnum(publication.PublicationKind.repeat) };
}

fn abortService(
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    registry: *registry_mod.Registry,
    lease: *const registry_mod.IncidentPublisherLease,
    prepared: *incident.PreparedServicePublication,
) void {
    runtime.abortPreparedPublication(registry, lease, prepared) catch process_seal.fatalIntegrity(.incident_authority);
}

fn releasePublisher(registry: *registry_mod.Registry, lease: *registry_mod.IncidentPublisherLease) void {
    registry.release(lease) catch process_seal.fatalIntegrity(.incident_authority);
}

fn finishClient(prepared: *publication.PreparedIncidentClientOperation) void {
    client_slot.finishIncidentClientOperationNoFail(prepared);
}

fn compositeSeal(value: *const publication.PreparedIncidentPublication) [32]u8 {
    return process_seal.preparedIncidentPublicationSeal(value.publisher.pid, value.publisher.process_nonce, .{
        .self_addr = value.self_addr,
        .kind_raw = value.kind_raw,
        .lease_addr = value.publisher.lease_addr,
        .lease_generation = value.publisher.lease_generation,
        .lease_seal = value.publisher.seal,
        .runtime_generation = value.publisher.runtime_generation,
        .service_generation = value.publisher.service_generation,
        .service_token_addr = value.service.self_addr,
        .service_token_seal = value.service.seal,
        .service_lifecycle_raw = value.service.lifecycle_raw,
        .client_token_addr = value.client.self_addr,
        .client_token_seal = value.client.seal,
        .client_lifecycle_raw = value.client.lifecycle_raw,
        .input_digest = value.input_digest,
        .lifecycle_raw = value.lifecycle_raw,
    }) catch process_seal.fatalIntegrity(.incident_authority);
}

fn validComposite(value: *const publication.PreparedIncidentPublication, kind: publication.PublicationKind) bool {
    return value.self_addr == @intFromPtr(value) and value.kind_raw == @intFromEnum(kind) and
        value.lifecycle_raw == @intFromEnum(publication.PublicationLifecycle.held) and
        std.mem.eql(u8, &value.seal, &compositeSeal(value));
}

fn fixtureClient(allocator: std.mem.Allocator, host_id: u128) client_mod.Client {
    return .{
        .allocator = allocator,
        .fd = -1,
        .host_id = host_id,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
}

fn fixtureInput(slot: *client_slot.ClientSlot) publication.IncidentInput {
    return .{
        .timestamp_ns = 1,
        .host_id = slot.current.client.host_id,
        .host_adapter_generation = slot.current.client.incident_binding.host_adapter_generation,
        .connection_generation = slot.current.connection_generation,
        .wire_major = slot.current.client.wire_major,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
    };
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    source: client_mod.Client,
    slot: client_slot.ClientSlot,
    tmp: std.testing.TmpDir,
    runtime: *runtime_mod.ConnectionIncidentRuntime,
    registry: registry_mod.Registry,

    fn create(allocator: std.mem.Allocator, host_id: u128) !*Fixture {
        try client_slot.ClientSlot.initializeProcessRuntime();
        const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
        const result = try allocator.create(Fixture);
        errdefer allocator.destroy(result);
        result.allocator = allocator;
        result.source = fixtureClient(allocator, host_id);
        var binding: @import("maru").observability.incident_binding_contract.IncidentBindingPublication = .{};
        try client_slot.ClientSlot.initManagedInPlace(
            &result.slot,
            allocator,
            &result.source,
            host_id,
            7,
            .current,
            &binding,
        );
        result.tmp = std.testing.tmpDir(.{});
        errdefer result.tmp.cleanup();
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(result.tmp.dir.handle, 0o700));
        const fd = std.c.dup(result.tmp.dir.handle);
        try std.testing.expect(fd >= 0);
        errdefer _ = std.c.close(fd);
        result.runtime = try runtime_mod.ConnectionIncidentRuntime.create(
            allocator,
            identity.pid,
            identity.process_nonce,
            11,
            fd,
        );
        _ = std.c.close(fd);
        result.registry = .{};
        try result.registry.initInPlace(identity.process_nonce);
        try result.runtime.installPublisherRegistry(&result.registry);
        return result;
    }

    fn query(self: *Fixture) client_slot.IncidentOperationQuery {
        return .{
            .slot_addr = @intFromPtr(&self.slot),
            .slot_generation = self.slot.incarnation.tagged,
            .node_addr = @intFromPtr(self.slot.current),
        };
    }

    fn deinit(self: *Fixture) !void {
        const allocator = self.allocator;
        try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try self.runtime.shutdownPublished(&self.registry));
        self.tmp.cleanup();
        self.slot.deinit();
        allocator.destroy(self);
    }
};

test "CR0b composite coordinator는 Client operation publisher lease service lock 순서로 first를 준비한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const fixture = try Fixture.create(std.testing.allocator, 0xC0B5);
    defer fixture.deinit() catch @panic("composite fixture cleanup failed");
    var transcript: FixedTranscript = .{};
    armTranscript(&transcript);
    defer disarmTranscript();
    var owner: PreparedFirstOwner = .{};
    try prepareFirst(&owner, &fixture.registry, fixture.runtime, fixture.query(), fixtureInput(&fixture.slot));
    try std.testing.expect(validComposite(&owner.publication, .first));
    try std.testing.expectEqual(@as(u64, 1), fixture.registry.active_lease_count);
    try std.testing.expect(!fixture.runtime.service.mutex.tryLock());
    try std.testing.expect(fixture.slot.current.client.first_poison_reason == null);
    try std.testing.expectEqualSlices(Stage, &.{ .client_held, .publisher_acquired, .service_prepared, .client_bound, .composite_held }, transcript.slice());
    abortPreparedFirst(&owner, &fixture.registry, fixture.runtime);
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.active_lease_count);
}

test "CR0b composite coordinator는 service prepare 실패를 publisher와 Client operation 역순으로 회수한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const fixture = try Fixture.create(std.testing.allocator, 0xC0B6);
    defer fixture.deinit() catch @panic("composite fixture cleanup failed");
    var transcript: FixedTranscript = .{};
    armTranscript(&transcript);
    defer disarmTranscript();
    runtime_mod.ConnectionIncidentRuntime.testing_api.exhaustServiceSequence(fixture.runtime);
    defer runtime_mod.ConnectionIncidentRuntime.testing_api.restoreServiceSequence(fixture.runtime, 0);
    try std.testing.expectError(
        error.CounterExhausted,
        publishFirst(&fixture.registry, fixture.runtime, fixture.query(), fixtureInput(&fixture.slot)),
    );
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.active_lease_count);
    try std.testing.expectEqualSlices(Stage, &.{ .client_held, .publisher_acquired, .publisher_released, .client_released }, transcript.slice());
    try std.testing.expect(fixture.runtime.service.mutex.tryLock());
    fixture.runtime.service.mutex.unlock();
    var operation: publication.PreparedIncidentClientOperation = .{};
    try client_slot.beginIncidentClientOperation(fixture.query(), &operation);
    client_slot.finishIncidentClientOperationNoFail(&operation);
}

test "CR0b composite coordinator는 bind drift를 service abort publisher release Client release 역순으로 회수한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const fixture = try Fixture.create(std.testing.allocator, 0xC0B7);
    defer fixture.deinit() catch @panic("composite fixture cleanup failed");
    var transcript: FixedTranscript = .{};
    armTranscript(&transcript);
    defer disarmTranscript();
    CoordinatorTestHook.drift_commit_authority = true;
    defer CoordinatorTestHook.drift_commit_authority = false;
    try std.testing.expectError(
        error.InvalidOwner,
        publishFirst(&fixture.registry, fixture.runtime, fixture.query(), fixtureInput(&fixture.slot)),
    );
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.active_lease_count);
    try std.testing.expectEqualSlices(Stage, &.{ .client_held, .publisher_acquired, .service_prepared, .service_aborted, .publisher_released, .client_released }, transcript.slice());
    try std.testing.expect(fixture.runtime.service.mutex.tryLock());
    fixture.runtime.service.mutex.unlock();
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.service.last_issued_sequence);
    try std.testing.expect(fixture.slot.current.client.first_poison_reason == null);
    var operation: publication.PreparedIncidentClientOperation = .{};
    try client_slot.beginIncidentClientOperation(fixture.query(), &operation);
    client_slot.finishIncidentClientOperationNoFail(&operation);
}

test "CR0b composite coordinator는 ring id key reason pending wake lease operation 순서로 first를 게시한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try client_slot.ClientSlot.initializeProcessRuntime();
    const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var source = fixtureClient(std.testing.allocator, 0xC0B4);
    var slot: client_slot.ClientSlot = undefined;
    var binding: @import("maru").observability.incident_binding_contract.IncidentBindingPublication = .{};
    try client_slot.ClientSlot.initManagedInPlace(&slot, std.testing.allocator, &source, 0xC0B4, 7, .current, &binding);
    defer slot.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(tmp.dir.handle, 0o700));
    const fd = std.c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    errdefer _ = std.c.close(fd);
    const runtime = try runtime_mod.ConnectionIncidentRuntime.create(
        std.testing.allocator,
        identity.pid,
        identity.process_nonce,
        11,
        fd,
    );
    _ = std.c.close(fd);
    var registry: registry_mod.Registry = .{};
    try registry.initInPlace(identity.process_nonce);
    try runtime.installPublisherRegistry(&registry);
    runtime.testing_block_writer.store(1, .release);
    var transcript: FixedTranscript = .{};
    armTranscript(&transcript);
    defer disarmTranscript();
    const result = try publishFirst(&registry, runtime, .{
        .slot_addr = @intFromPtr(&slot),
        .slot_generation = slot.incarnation.tagged,
        .node_addr = @intFromPtr(slot.current),
    }, fixtureInput(&slot));
    try std.testing.expect(result.publication.incident_id.sequence != 0);
    try std.testing.expectEqual(publication.WakeOutcome.queued, result.wake);
    try std.testing.expect(slot.current.client.first_poison_reason != null);
    try std.testing.expectEqual(result.publication.incident_id, slot.current.client.first_incident_id);
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);
    const detail_slot = result.publication.detail_slot orelse return error.TestUnexpectedResult;
    const expected_pending = (@as(u128, 1) << @intCast(detail_slot)) |
        (@as(u128, 1) << @intCast(incident.incident_slot_count + result.publication.aggregate_slot));
    try std.testing.expectEqual(expected_pending, runtime.service.pending_slots);
    var detail: incident.IncidentWriterHandoff = .{};
    try std.testing.expectEqual(
        incident.WriterTakeResult.taken,
        try runtime.service.takePendingForWriter(runtime.pid, runtime.process_nonce, &detail),
    );
    try std.testing.expectEqual(detail_slot, detail.receipt.slot_index);
    try runtime.service.completeWriterHandoff(runtime.pid, runtime.process_nonce, detail, .failed);
    var aggregate: incident.IncidentWriterHandoff = .{};
    try std.testing.expectEqual(
        incident.WriterTakeResult.taken,
        try runtime.service.takePendingForWriter(runtime.pid, runtime.process_nonce, &aggregate),
    );
    try std.testing.expectEqual(
        @as(u8, @intCast(incident.incident_slot_count + result.publication.aggregate_slot)),
        aggregate.receipt.slot_index,
    );
    try runtime.service.completeWriterHandoff(runtime.pid, runtime.process_nonce, aggregate, .failed);
    var empty: incident.IncidentWriterHandoff = .{};
    try std.testing.expectEqual(
        incident.WriterTakeResult.inactive,
        try runtime.service.takePendingForWriter(runtime.pid, runtime.process_nonce, &empty),
    );
    try std.testing.expectEqualSlices(Stage, &.{
        .client_held,      .publisher_acquired, .service_prepared,   .client_bound,    .composite_held,
        .ring_evidence,    .id_stored,          .key_stored,         .reason_stored,   .client_committed,
        .pending_unlocked, .wake_observed,      .publisher_released, .client_released,
    }, transcript.slice());
    disarmTranscript();
    var reused: publication.PreparedIncidentClientOperation = .{};
    try client_slot.beginIncidentClientOperation(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_generation = slot.incarnation.tagged,
        .node_addr = @intFromPtr(slot.current),
    }, &reused);
    client_slot.finishIncidentClientOperationNoFail(&reused);
    runtime.testing_block_writer.store(0, .release);
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try runtime.shutdownPublished(&registry));
}

test "CR0b composite coordinator는 같은 fingerprint repeat에서 first Client 필드와 sequence를 보존하고 aggregate만 갱신한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const fixture = try Fixture.create(std.testing.allocator, 0xC0B8);
    defer fixture.deinit() catch @panic("composite fixture cleanup failed");
    fixture.runtime.testing_block_writer.store(1, .release);
    defer fixture.runtime.testing_block_writer.store(0, .release);
    const first_input = fixtureInput(&fixture.slot);
    const first = try publishFirst(&fixture.registry, fixture.runtime, fixture.query(), first_input);
    const first_id = fixture.slot.current.client.first_incident_id;
    const first_key = fixture.slot.current.client.incident_repeat_key;
    const first_reason = fixture.slot.current.client.first_poison_reason;
    var first_detail: incident.IncidentWriterHandoff = .{};
    try std.testing.expectEqual(
        incident.WriterTakeResult.taken,
        try fixture.runtime.service.takePendingForWriter(fixture.runtime.pid, fixture.runtime.process_nonce, &first_detail),
    );
    try fixture.runtime.service.completeWriterHandoff(fixture.runtime.pid, fixture.runtime.process_nonce, first_detail, .failed);
    var first_aggregate: incident.IncidentWriterHandoff = .{};
    try std.testing.expectEqual(
        incident.WriterTakeResult.taken,
        try fixture.runtime.service.takePendingForWriter(fixture.runtime.pid, fixture.runtime.process_nonce, &first_aggregate),
    );
    try fixture.runtime.service.completeWriterHandoff(fixture.runtime.pid, fixture.runtime.process_nonce, first_aggregate, .failed);
    try std.testing.expectEqual(@as(u128, 0), fixture.runtime.service.pending_slots);
    const ring_before = fixture.runtime.service.ring;
    var repeat_input = first_input;
    repeat_input.timestamp_ns = 2;
    repeat_input.queue_bytes = 7;
    const repeat = try publishRepeat(&fixture.registry, fixture.runtime, fixture.query(), repeat_input);
    try std.testing.expectEqual(first_id, repeat.publication.incident_id);
    try std.testing.expect(!repeat.publication.detail_present);
    try std.testing.expectEqual(first.publication.aggregate_slot, repeat.publication.aggregate_slot);
    try std.testing.expectEqual(first.publication.aggregate_generation + 1, repeat.publication.aggregate_generation);
    try std.testing.expectEqual(ring_before.incident_count, fixture.runtime.service.ring.incident_count);
    try std.testing.expectEqualSlices(bool, &ring_before.named_aggregate_used, &fixture.runtime.service.ring.named_aggregate_used);
    const aggregate_record_index = incident.incident_slot_count + repeat.publication.aggregate_slot;
    for (ring_before.records, 0..) |record, index| {
        if (index == aggregate_record_index) continue;
        try std.testing.expectEqualSlices(u8, &record, &fixture.runtime.service.ring.records[index]);
    }
    for (ring_before.aggregate_generations, 0..) |generation, index| {
        const expected = if (index == repeat.publication.aggregate_slot) generation + 1 else generation;
        try std.testing.expectEqual(expected, fixture.runtime.service.ring.aggregate_generations[index]);
    }
    const aggregate = &fixture.runtime.service.ring.records[aggregate_record_index];
    const aggregate_before = &ring_before.records[aggregate_record_index];
    try std.testing.expect(fixture.runtime.service.ring.record(aggregate_record_index) != null);
    try std.testing.expectEqual(
        repeat.publication.aggregate_generation,
        std.mem.readInt(u64, aggregate[8..16], .little),
    );
    // Envelope payload에서 count와 last timestamp만 repeat delta로 열고 나머지 의미 바이트는 exact 보존한다.
    try std.testing.expectEqualSlices(u8, aggregate_before[16..24], aggregate[16..24]);
    try std.testing.expectEqualSlices(u8, aggregate_before[32..56], aggregate[32..56]);
    try std.testing.expectEqualSlices(u8, aggregate_before[72..224], aggregate[72..224]);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, aggregate[24..32], .little));
    try std.testing.expectEqual(@as(i128, 1), std.mem.readInt(i128, aggregate[40..56], .little));
    try std.testing.expectEqual(@as(i128, 2), std.mem.readInt(i128, aggregate[56..72], .little));
    const aggregate_bit = @as(u128, 1) << @intCast(aggregate_record_index);
    try std.testing.expectEqual(aggregate_bit, fixture.runtime.service.pending_slots);
    try std.testing.expectEqual(first_id, fixture.slot.current.client.first_incident_id);
    try std.testing.expectEqual(first_key, fixture.slot.current.client.incident_repeat_key);
    try std.testing.expectEqual(first_reason, fixture.slot.current.client.first_poison_reason);
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.active_lease_count);
}

test "CR0b composite coordinator는 다른 fingerprint repeat를 mutation 없이 거부하고 first 권위를 보존한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const fixture = try Fixture.create(std.testing.allocator, 0xC0B9);
    defer fixture.deinit() catch @panic("composite fixture cleanup failed");
    fixture.runtime.testing_block_writer.store(1, .release);
    defer fixture.runtime.testing_block_writer.store(0, .release);
    const first_input = fixtureInput(&fixture.slot);
    _ = try publishFirst(&fixture.registry, fixture.runtime, fixture.query(), first_input);
    const first_id = fixture.slot.current.client.first_incident_id;
    const first_key = fixture.slot.current.client.incident_repeat_key;
    const first_reason = fixture.slot.current.client.first_poison_reason;
    const sequence_before = fixture.runtime.service.last_issued_sequence;
    const pending_before = fixture.runtime.service.pending_slots;
    const ring_before = fixture.runtime.service.ring;
    var mismatch = first_input;
    mismatch.timestamp_ns = 2;
    mismatch.source_site_raw = @intFromEnum(incident.SourceSite.client_event);
    try std.testing.expectError(
        error.InvalidOwner,
        publishRepeat(&fixture.registry, fixture.runtime, fixture.query(), mismatch),
    );
    try std.testing.expectEqual(first_id, fixture.slot.current.client.first_incident_id);
    try std.testing.expectEqual(first_key, fixture.slot.current.client.incident_repeat_key);
    try std.testing.expectEqual(first_reason, fixture.slot.current.client.first_poison_reason);
    try std.testing.expectEqual(sequence_before, fixture.runtime.service.last_issued_sequence);
    try std.testing.expectEqual(pending_before, fixture.runtime.service.pending_slots);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&ring_before), std.mem.asBytes(&fixture.runtime.service.ring));
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.active_lease_count);
    try std.testing.expect(fixture.runtime.service.mutex.tryLock());
    fixture.runtime.service.mutex.unlock();
    var reused: publication.PreparedIncidentClientOperation = .{};
    try client_slot.beginIncidentClientOperation(fixture.query(), &reused);
    client_slot.finishIncidentClientOperationNoFail(&reused);
}
