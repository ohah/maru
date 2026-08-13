//! CR0b Client poison publication의 의존성 중립 입력과 반복 권위 계약.
//!
//! Client owner는 mutex를 잡기 전에 이 값만 완성한다. service가 Client나 queue 포인터를
//! 역참조하지 않게 고정해야 publication suffix가 allocation 없는 구간으로 남는다.

const std = @import("std");
const incident = @import("connection_incident.zig");

pub const Digest = [32]u8;

pub const IncidentInput = struct {
    timestamp_ns: i128 = 0,
    host_id: u128 = 0,
    host_adapter_generation: u64 = 0,
    connection_generation: u64 = 0,
    wire_major: u16 = 0,
    reason_raw: u8 = 0,
    scope_raw: u8 = 0,
    disposition_raw: u8 = 0,
    source_site_raw: u8 = 0,
    host_class_raw: u8 = 0,
    parser_phase_raw: u8 = 0,
    outbound_phase_raw: u8 = 0,
    last_success_request_id: u64 = 0,
    pending_request_count: u32 = 0,
    pending_stream_count: u32 = 0,
    pending_event_count: u32 = 0,
    queue_item_count: u32 = 0,
    queue_bytes: u64 = 0,
    outbound_offset: u64 = 0,
    outbound_length: u64 = 0,
    controller_generation: u64 = 0,
    upgrade_epoch: u64 = 0,
};

pub const IncidentRepeatKey = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    client_addr: u64 = 0,
    connection_generation: u64 = 0,
    incident_id: incident.IncidentId = .{ .app_instance_nonce = 0, .sequence = 0 },
    fingerprint: Digest = [_]u8{0} ** 32,
    binding_seal: Digest = [_]u8{0} ** 32,
    lifecycle_raw: u8 = 0,
    seal: Digest = [_]u8{0} ** 32,
};

pub const RepeatKeyLifecycle = enum(u8) { pristine = 0, published = 1, consumed = 2 };

pub const IncidentOperationAuthority = struct {
    slot_addr: u64 = 0,
    slot_generation: u64 = 0,
    node_addr: u64 = 0,
    node_generation: u64 = 0,
    client_addr: u64 = 0,
    connection_generation: u64 = 0,
    operation_id: u64 = 0,
    operation_receipt_seal: Digest = [_]u8{0} ** 32,
    binding_seal: Digest = [_]u8{0} ** 32,
};

pub const FirstPublicationCommit = struct {
    authority: IncidentOperationAuthority = .{},
    input_digest: Digest = [_]u8{0} ** 32,
    incident_id: incident.IncidentId = .{ .app_instance_nonce = 0, .sequence = 0 },
    fingerprint: Digest = [_]u8{0} ** 32,
    reason_raw: u8 = 0,
};

pub const ClientOperationLifecycle = enum(u8) { pristine = 0, held = 1, bound = 2, consumed = 3 };

pub const PreparedIncidentClientOperation = struct {
    self_addr: u64 = 0,
    authority: IncidentOperationAuthority = .{},
    registry_index: u16 = 0,
    pid: u32 = 0,
    owner_thread: u64 = 0,
    authority_digest: Digest = [_]u8{0} ** 32,
    commit_digest: Digest = [_]u8{0} ** 32,
    repeat_key_seal: Digest = [_]u8{0} ** 32,
    lifecycle_raw: u8 = 0,
    seal: Digest = [_]u8{0} ** 32,
};

pub const PublicationKind = enum(u8) { first = 1, repeat = 2 };
pub const PublicationLifecycle = enum(u8) { pristine = 0, held = 1, evidence_committed = 2, published = 3 };

pub const PublisherLeaseProjection = struct {
    registry_addr: u64 = 0,
    registry_generation: u64 = 0,
    authority_addr: u64 = 0,
    runtime_addr: u64 = 0,
    runtime_generation: u64 = 0,
    service_addr: u64 = 0,
    service_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    lease_generation: u64 = 0,
    seal: Digest = [_]u8{0} ** 32,
};

/// Platform coordinator가 service mutex와 Client operation을 동시에 소유하는 동안만 유효하다.
/// runtime/service 포인터를 넣지 않아 copied value가 새 권위를 만들지 못하게 한다.
pub const PreparedIncidentPublication = struct {
    self_addr: u64 = 0,
    kind_raw: u8 = 0,
    publisher: PublisherLeaseProjection = .{},
    service: incident.PreparedServicePublication = .{},
    client: PreparedIncidentClientOperation = .{},
    input_digest: Digest = [_]u8{0} ** 32,
    lifecycle_raw: u8 = 0,
    seal: Digest = [_]u8{0} ** 32,
};

pub const InputError = error{InvalidInput};

/// service가 incident ID만 채우도록 나머지 wire 의미를 한 번에 고정한다.
/// 별도 변환기가 flags나 timestamp 복제 규칙을 다시 추론하면 Client seal과 ring evidence가 갈라질 수 있다.
pub fn serviceInput(value: IncidentInput) InputError!incident.ConnectionIncident {
    if (!validInputShape(value)) return error.InvalidInput;
    const decision = incident.decisionForReason(@enumFromInt(value.reason_raw));
    var result: incident.ConnectionIncident = .{
        .flags = 0x04 | @as(u8, @intFromBool(decision.expected)),
        .incident_id = .{ .app_instance_nonce = 1, .sequence = 1 },
        .timestamp_ns = value.timestamp_ns,
        .host_id = value.host_id,
        .host_adapter_generation = value.host_adapter_generation,
        .connection_generation = value.connection_generation,
        .wire_major = value.wire_major,
        .reason_raw = value.reason_raw,
        .scope_raw = value.scope_raw,
        .disposition_raw = value.disposition_raw,
        .source_site_raw = value.source_site_raw,
        .host_class_raw = value.host_class_raw,
        .parser_phase_raw = value.parser_phase_raw,
        .outbound_phase_raw = value.outbound_phase_raw,
        .last_success_request_id = value.last_success_request_id,
        .pending_request_count = value.pending_request_count,
        .pending_stream_count = value.pending_stream_count,
        .pending_event_count = value.pending_event_count,
        .queue_item_count = value.queue_item_count,
        .queue_bytes = value.queue_bytes,
        .outbound_offset = value.outbound_offset,
        .outbound_length = value.outbound_length,
        .controller_generation = value.controller_generation,
        .upgrade_epoch = value.upgrade_epoch,
        .first_timestamp_ns = value.timestamp_ns,
        .last_timestamp_ns = value.timestamp_ns,
    };
    incident.validateIncident(result) catch return error.InvalidInput;
    result.incident_id = .{ .app_instance_nonce = 0, .sequence = 0 };
    return result;
}

/// encoder 검증용 고정 sentinel ID `{1,1}`을 쓰되 실제 service-issued ID와는 독립인 fixed wire transcript다.
pub fn inputDigest(value: IncidentInput) InputError!Digest {
    var canonical = try serviceInput(value);
    canonical.incident_id = .{ .app_instance_nonce = 1, .sequence = 1 };
    const payload = incident.encodeIncident(canonical) catch return error.InvalidInput;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.incident-input.v1");
    hasher.update(&payload);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

/// repeat capability가 허용하는 aggregate identity 네 필드만 별도 domain으로 봉인한다.
pub fn fingerprint(value: IncidentInput) InputError!Digest {
    _ = try serviceInput(value);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.incident-fingerprint.v1");
    hasher.update(&.{ value.reason_raw, value.scope_raw, value.source_site_raw, value.host_class_raw });
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn validInputShape(value: IncidentInput) bool {
    return value.timestamp_ns >= 0 and value.host_id != 0 and value.host_adapter_generation != 0 and
        value.connection_generation != 0 and value.wire_major != 0 and
        std.enums.fromInt(incident.ConnectionReason, value.reason_raw) != null and
        std.enums.fromInt(incident.Scope, value.scope_raw) != null and
        std.enums.fromInt(incident.Disposition, value.disposition_raw) != null and
        std.enums.fromInt(incident.SourceSite, value.source_site_raw) != null and
        std.enums.fromInt(incident.HostClass, value.host_class_raw) != null and
        std.enums.fromInt(incident.ParserPhase, value.parser_phase_raw) != null and
        std.enums.fromInt(incident.OutboundPhase, value.outbound_phase_raw) != null and
        value.outbound_offset <= value.outbound_length;
}

pub fn validRepeatKeyShape(value: IncidentRepeatKey, expected_addr: usize) bool {
    return value.self_addr == expected_addr and value.pid != 0 and value.process_nonce != 0 and
        value.client_addr != 0 and value.connection_generation != 0 and
        value.incident_id.app_instance_nonce != 0 and value.incident_id.sequence != 0 and
        !std.mem.allEqual(u8, &value.fingerprint, 0) and !std.mem.allEqual(u8, &value.binding_seal, 0) and
        value.lifecycle_raw == @intFromEnum(RepeatKeyLifecycle.published) and
        !std.mem.allEqual(u8, &value.seal, 0);
}

fn recursivelyPointerFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => false,
        .array => |info| recursivelyPointerFree(info.child),
        .optional => |info| recursivelyPointerFree(info.child),
        .error_union => |info| recursivelyPointerFree(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

test "CR0b poison publication 계약은 입력과 repeat key를 재귀 pointer-free로 유지한다" {
    try std.testing.expect(recursivelyPointerFree(IncidentInput));
    try std.testing.expect(recursivelyPointerFree(IncidentRepeatKey));
    try std.testing.expect(recursivelyPointerFree(IncidentOperationAuthority));
    try std.testing.expect(recursivelyPointerFree(FirstPublicationCommit));
    try std.testing.expect(recursivelyPointerFree(PreparedIncidentClientOperation));
    try std.testing.expect(recursivelyPointerFree(PublisherLeaseProjection));
    try std.testing.expect(recursivelyPointerFree(PreparedIncidentPublication));
}

test "CR0b poison publication 계약은 composite kind와 lifecycle raw를 닫힌 값으로 유지한다" {
    inline for (.{ PublicationKind.first, PublicationKind.repeat }) |kind|
        try std.testing.expect(std.enums.fromInt(PublicationKind, @intFromEnum(kind)) != null);
    try std.testing.expect(std.enums.fromInt(PublicationKind, 0) == null);
    inline for (.{
        PublicationLifecycle.pristine,
        PublicationLifecycle.held,
        PublicationLifecycle.evidence_committed,
        PublicationLifecycle.published,
    }) |lifecycle| try std.testing.expect(std.enums.fromInt(PublicationLifecycle, @intFromEnum(lifecycle)) != null);
    try std.testing.expect(std.enums.fromInt(PublicationLifecycle, 4) == null);
}

test "CR0b poison publication 계약은 입력의 closed raw 값과 outbound 범위를 검증한다" {
    var value: IncidentInput = .{
        .host_id = 1,
        .host_adapter_generation = 2,
        .connection_generation = 3,
        .wire_major = 1,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
    };
    try std.testing.expect(validInputShape(value));
    value.source_site_raw = 0;
    try std.testing.expect(!validInputShape(value));
    value.source_site_raw = @intFromEnum(incident.SourceSite.client_read);
    value.outbound_offset = 2;
    value.outbound_length = 1;
    try std.testing.expect(!validInputShape(value));
}

test "CR0b poison publication 계약은 repeat key의 final address와 nonzero lineage를 요구한다" {
    var key: IncidentRepeatKey = .{};
    key.self_addr = @intFromPtr(&key);
    key.pid = 1;
    key.process_nonce = 2;
    key.client_addr = 3;
    key.connection_generation = 4;
    key.incident_id = .{ .app_instance_nonce = 5, .sequence = 6 };
    key.fingerprint[0] = 1;
    key.binding_seal[0] = 2;
    key.lifecycle_raw = @intFromEnum(RepeatKeyLifecycle.published);
    key.seal[0] = 3;
    try std.testing.expect(validRepeatKeyShape(key, @intFromPtr(&key)));
    try std.testing.expect(!validRepeatKeyShape(key, @intFromPtr(&key) + 1));
}

test "CR0b poison publication 계약은 입력을 canonical service record와 digest로 한 번만 변환한다" {
    const value: IncidentInput = .{
        .timestamp_ns = 7,
        .host_id = 1,
        .host_adapter_generation = 2,
        .connection_generation = 3,
        .wire_major = 1,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
        .last_success_request_id = 8,
        .pending_request_count = 9,
        .pending_stream_count = 10,
        .pending_event_count = 11,
        .queue_item_count = 12,
        .queue_bytes = 13,
        .controller_generation = 14,
        .upgrade_epoch = 15,
    };
    const record = try serviceInput(value);
    try std.testing.expectEqual(incident.IncidentId{ .app_instance_nonce = 0, .sequence = 0 }, record.incident_id);
    try std.testing.expectEqual(value.timestamp_ns, record.timestamp_ns);
    try std.testing.expectEqual(value.host_id, record.host_id);
    try std.testing.expectEqual(value.host_adapter_generation, record.host_adapter_generation);
    try std.testing.expectEqual(value.connection_generation, record.connection_generation);
    try std.testing.expectEqual(value.wire_major, record.wire_major);
    try std.testing.expectEqual(value.reason_raw, record.reason_raw);
    try std.testing.expectEqual(value.scope_raw, record.scope_raw);
    try std.testing.expectEqual(value.disposition_raw, record.disposition_raw);
    try std.testing.expectEqual(value.source_site_raw, record.source_site_raw);
    try std.testing.expectEqual(value.host_class_raw, record.host_class_raw);
    try std.testing.expectEqual(value.parser_phase_raw, record.parser_phase_raw);
    try std.testing.expectEqual(value.outbound_phase_raw, record.outbound_phase_raw);
    try std.testing.expectEqual(value.last_success_request_id, record.last_success_request_id);
    try std.testing.expectEqual(value.pending_request_count, record.pending_request_count);
    try std.testing.expectEqual(value.pending_stream_count, record.pending_stream_count);
    try std.testing.expectEqual(value.pending_event_count, record.pending_event_count);
    try std.testing.expectEqual(value.queue_item_count, record.queue_item_count);
    try std.testing.expectEqual(value.queue_bytes, record.queue_bytes);
    try std.testing.expectEqual(value.outbound_offset, record.outbound_offset);
    try std.testing.expectEqual(value.outbound_length, record.outbound_length);
    try std.testing.expectEqual(value.controller_generation, record.controller_generation);
    try std.testing.expectEqual(value.upgrade_epoch, record.upgrade_epoch);
    try std.testing.expectEqual(value.timestamp_ns, record.first_timestamp_ns);
    try std.testing.expectEqual(value.timestamp_ns, record.last_timestamp_ns);
    try std.testing.expectEqual(@as(u8, 0x05), record.flags);
    try std.testing.expect(!std.mem.allEqual(u8, &(try inputDigest(value)), 0));
    try std.testing.expect(!std.mem.allEqual(u8, &(try fingerprint(value)), 0));
    var expected_record = record;
    expected_record.incident_id = .{ .app_instance_nonce = 1, .sequence = 1 };
    const expected_payload = try incident.encodeIncident(expected_record);
    var expected_hasher = std.crypto.hash.Blake3.init(.{});
    expected_hasher.update("maru.incident-input.v1");
    expected_hasher.update(&expected_payload);
    var expected_digest: Digest = undefined;
    expected_hasher.final(&expected_digest);
    try std.testing.expectEqualSlices(u8, &expected_digest, &(try inputDigest(value)));

    const base_digest = try inputDigest(value);
    const base_fingerprint = try fingerprint(value);
    var non_identity_cases = [_]IncidentInput{value} ** 14;
    non_identity_cases[0].timestamp_ns += 1;
    non_identity_cases[1].host_id += 1;
    non_identity_cases[2].host_adapter_generation += 1;
    non_identity_cases[3].connection_generation += 1;
    non_identity_cases[4].wire_major += 1;
    non_identity_cases[5].parser_phase_raw = @intFromEnum(incident.ParserPhase.header);
    non_identity_cases[6].last_success_request_id += 1;
    non_identity_cases[7].pending_request_count += 1;
    non_identity_cases[8].pending_stream_count += 1;
    non_identity_cases[9].pending_event_count += 1;
    non_identity_cases[10].queue_item_count += 1;
    non_identity_cases[11].queue_bytes += 1;
    non_identity_cases[12].controller_generation += 1;
    non_identity_cases[13].upgrade_epoch += 1;
    for (non_identity_cases) |changed| {
        try std.testing.expect(!std.mem.eql(u8, &base_digest, &(try inputDigest(changed))));
        try std.testing.expectEqualSlices(u8, &base_fingerprint, &(try fingerprint(changed)));
    }

    var outbound_base = value;
    outbound_base.outbound_phase_raw = @intFromEnum(incident.OutboundPhase.queued);
    outbound_base.outbound_length = 1;
    const outbound_base_digest = try inputDigest(outbound_base);
    var outbound_cases = [_]IncidentInput{outbound_base} ** 3;
    outbound_cases[0].outbound_phase_raw = @intFromEnum(incident.OutboundPhase.partial);
    outbound_cases[1].outbound_offset = 1;
    outbound_cases[2].outbound_length = 2;
    for (outbound_cases) |changed| {
        try std.testing.expect(!std.mem.eql(u8, &outbound_base_digest, &(try inputDigest(changed))));
        try std.testing.expectEqualSlices(u8, &base_fingerprint, &(try fingerprint(changed)));
    }

    var identity_cases = [_]IncidentInput{value} ** 4;
    identity_cases[0].reason_raw = @intFromEnum(incident.ConnectionReason.read_timeout);
    identity_cases[1].source_site_raw = @intFromEnum(incident.SourceSite.client_write);
    identity_cases[2].host_class_raw = @intFromEnum(incident.HostClass.previous);
    identity_cases[3].scope_raw = @intFromEnum(incident.Scope.host);
    for (identity_cases[0..3]) |changed| {
        try std.testing.expect(!std.mem.eql(u8, &base_digest, &(try inputDigest(changed))));
        try std.testing.expect(!std.mem.eql(u8, &base_fingerprint, &(try fingerprint(changed))));
    }
    // connection-only wire v1에서는 scope 변화가 closed validation에서 거부된다.
    try std.testing.expectError(error.InvalidInput, fingerprint(identity_cases[3]));

    const decision_cases = [_]struct {
        reason: incident.ConnectionReason,
        expected: bool,
        disposition: incident.Disposition,
    }{
        .{ .reason = .connection_eof, .expected = true, .disposition = .reconnect },
        .{ .reason = .read_timeout, .expected = true, .disposition = .reconnect },
        .{ .reason = .transport_read_failure, .expected = true, .disposition = .reconnect },
        .{ .reason = .planned_upgrade_reconnect, .expected = true, .disposition = .reconnect },
        .{ .reason = .capability_incompatible, .expected = true, .disposition = .no_retry },
        .{ .reason = .outbound_partial_write, .expected = true, .disposition = .reconnect },
        .{ .reason = .outbound_write_ambiguous, .expected = true, .disposition = .reconnect },
        .{ .reason = .event_queue_overflow, .expected = false, .disposition = .reconnect },
        .{ .reason = .local_queue_exhausted, .expected = false, .disposition = .reconnect },
        .{ .reason = .local_resource_exhausted, .expected = true, .disposition = .reconnect },
        .{ .reason = .frame_malformed, .expected = false, .disposition = .reconnect },
        .{ .reason = .response_correlation_lost, .expected = false, .disposition = .reconnect },
        .{ .reason = .peer_contract_violation, .expected = false, .disposition = .reconnect },
        .{ .reason = .local_invariant_violation, .expected = false, .disposition = .reconnect },
        .{ .reason = .external_transfer_quarantined, .expected = false, .disposition = .reconnect },
        .{ .reason = .attachment_cleanup_failed, .expected = false, .disposition = .reconnect },
    };
    try std.testing.expectEqual(std.meta.fields(incident.ConnectionReason).len, decision_cases.len);
    for (decision_cases) |case| {
        const reason = case.reason;
        var decision_case = value;
        decision_case.reason_raw = @intFromEnum(reason);
        const decision = incident.decisionForReason(reason);
        try std.testing.expectEqual(case.expected, decision.expected);
        try std.testing.expectEqual(case.disposition, decision.disposition);
        decision_case.disposition_raw = @intFromEnum(case.disposition);
        const decision_record = try serviceInput(decision_case);
        try std.testing.expectEqual(case.expected, decision_record.flags & 1 != 0);
        try std.testing.expectEqual(@intFromEnum(case.disposition), decision_record.disposition_raw);
        try std.testing.expect(!std.mem.allEqual(u8, &(try inputDigest(decision_case)), 0));
        try std.testing.expect(!std.mem.allEqual(u8, &(try fingerprint(decision_case)), 0));
    }
}
