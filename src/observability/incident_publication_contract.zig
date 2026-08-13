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
