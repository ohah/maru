//! 연결 장애 artifact의 의존성 중립 wire 계약이다.
//!
//! 제품 Client와 파일 writer가 같은 고정 크기 표현을 소비해야 redaction, ring 예산, replay 도구가 서로 다른
//! 임시 schema를 만들지 않는다. 이 모듈은 저장소나 Client 권위를 소유하지 않고 값 검증과 canonical encoding만 맡는다.

const std = @import("std");
const builtin = @import("builtin");

pub const encoding_version: u16 = 1;
pub const payload_size: usize = 208;
pub const envelope_size: usize = 256;
pub const incident_slot_count: usize = 120;
pub const aggregate_slot_count: usize = 8;
pub const ring_size: usize = 32 * 1024;

pub const SourceSite = enum(u8) {
    client_read = 1,
    client_write = 2,
    client_response = 3,
    client_event = 4,
    client_queue = 5,
    client_cleanup = 6,
    client_slot_operation = 7,
    generation_transport = 8,
    generation_attachment = 9,
    remote_runtime_decode = 10,
    remote_runtime_pump = 11,
    remote_backend = 12,
    external_attach = 13,
    external_pump = 14,
    app_quit = 15,
    integrity = 16,
};

pub const HostClass = enum(u8) { current = 1, previous = 2, external = 3 };
pub const ParserPhase = enum(u8) { idle = 1, header = 2, payload = 3, terminal = 4 };
pub const OutboundPhase = enum(u8) { idle = 1, queued = 2, partial = 3, terminal = 4 };
pub const ConnectionReason = enum(u8) {
    connection_eof = 0,
    read_timeout = 1,
    transport_read_failure = 2,
    planned_upgrade_reconnect = 3,
    capability_incompatible = 4,
    outbound_partial_write = 5,
    outbound_write_ambiguous = 6,
    event_queue_overflow = 7,
    local_queue_exhausted = 8,
    local_resource_exhausted = 9,
    frame_malformed = 10,
    response_correlation_lost = 11,
    peer_contract_violation = 12,
    local_invariant_violation = 13,
    external_transfer_quarantined = 14,
    attachment_cleanup_failed = 15,
};
pub const Scope = enum(u8) { stream = 0, connection = 1, host = 2 };
pub const Disposition = enum(u8) { retry_status = 0, reconnect = 1, no_retry = 2, gone = 3 };

pub const IncidentId = struct {
    app_instance_nonce: u128,
    sequence: u64,
};

pub const ConnectionIncident = struct {
    version: u16 = encoding_version,
    record_kind: u8 = 1,
    flags: u8,
    incident_id: IncidentId,
    timestamp_ns: i128,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    wire_major: u16,
    reason_raw: u8,
    scope_raw: u8,
    disposition_raw: u8,
    source_site_raw: u8,
    host_class_raw: u8,
    parser_phase_raw: u8,
    outbound_phase_raw: u8,
    reserved0: u8 = 0,
    last_success_request_id: u64,
    pending_request_count: u32,
    pending_stream_count: u32,
    pending_event_count: u32,
    queue_item_count: u32,
    queue_bytes: u64,
    outbound_offset: u64,
    outbound_length: u64,
    controller_generation: u64,
    upgrade_epoch: u64,
    occurrence_count: u64 = 1,
    first_timestamp_ns: i128,
    last_timestamp_ns: i128,
    reserved_tail: [18]u8 = [_]u8{0} ** 18,
};

pub const IncidentAggregate = struct {
    version: u16 = encoding_version,
    kind: u8 = 2,
    flags: u8,
    reason_raw: u8,
    scope_raw: u8,
    source_site_raw: u8,
    host_class_raw: u8,
    count: u64,
    detail_dropped_count: u64,
    first_timestamp_ns: i128,
    last_timestamp_ns: i128,
    reserved: [152]u8 = [_]u8{0} ** 152,
};

pub const ValidationError = error{InvalidIncident};
pub const PublishError = ValidationError || error{AggregateGenerationExhausted};

pub const PublishResult = struct {
    incident_id: IncidentId,
    detail_present: bool,
    detail_slot: ?u8,
    aggregate_slot: u8,
    aggregate_generation: u64,
};

pub const ServiceError = PublishError || error{InvalidAuthority};

pub const ConnectionIncidentService = struct {
    mutex: std.atomic.Mutex = .unlocked,
    self_addr: usize = 0,
    pid: u64 = 0,
    process_nonce: u64 = 0,
    app_instance_nonce: u128 = 0,
    last_issued_sequence: u64 = 0,
    pending_slots: u128 = 0,
    lifecycle_raw: u8 = 0,
    ring: EmergencyRing = .{},

    pub fn initInPlace(out: *ConnectionIncidentService, pid: u64, process_nonce: u64, app_instance_nonce: u128) ServiceError!void {
        if (pid == 0 or process_nonce == 0 or app_instance_nonce == 0) return error.InvalidAuthority;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .pid = pid,
            .process_nonce = process_nonce,
            .app_instance_nonce = app_instance_nonce,
            .lifecycle_raw = 1,
        };
    }

    pub fn publish(
        self: *ConnectionIncidentService,
        current_pid: u64,
        current_process_nonce: u64,
        input: ConnectionIncident,
    ) ServiceError!PublishResult {
        if (!self.validAuthority(current_pid, current_process_nonce) or input.incident_id.app_instance_nonce != 0 or
            input.incident_id.sequence != 0)
            return error.InvalidAuthority;
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validAuthority(current_pid, current_process_nonce)) return error.InvalidAuthority;
        if (self.last_issued_sequence == std.math.maxInt(u64)) return error.InvalidAuthority;
        const sequence = self.last_issued_sequence + 1;
        var incident = input;
        incident.incident_id = .{ .app_instance_nonce = self.app_instance_nonce, .sequence = sequence };
        const result = try self.ring.publish(incident);
        self.last_issued_sequence = sequence;
        if (result.detail_slot) |slot| self.pending_slots |= @as(u128, 1) << @intCast(slot);
        self.pending_slots |= @as(u128, 1) << @intCast(incident_slot_count + result.aggregate_slot);
        return result;
    }

    fn recordRepeatForTest(
        self: *ConnectionIncidentService,
        current_pid: u64,
        current_process_nonce: u64,
        input: ConnectionIncident,
    ) ServiceError!PublishResult {
        if (!self.validAuthority(current_pid, current_process_nonce) or
            input.incident_id.app_instance_nonce != self.app_instance_nonce or input.incident_id.sequence == 0 or
            input.incident_id.sequence > self.last_issued_sequence)
            return error.InvalidAuthority;
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validAuthority(current_pid, current_process_nonce) or
            input.incident_id.app_instance_nonce != self.app_instance_nonce or
            input.incident_id.sequence > self.last_issued_sequence) return error.InvalidAuthority;
        const result = try self.ring.recordRepeat(input);
        self.pending_slots |= @as(u128, 1) << @intCast(incident_slot_count + result.aggregate_slot);
        return result;
    }

    fn validAuthority(self: *const ConnectionIncidentService, current_pid: u64, current_process_nonce: u64) bool {
        return self.lifecycle_raw == 1 and self.self_addr == @intFromPtr(self) and self.pid == current_pid and
            self.process_nonce == current_process_nonce and self.app_instance_nonce != 0;
    }
};

const Envelope = [envelope_size]u8;

pub const EmergencyRing = struct {
    records: [incident_slot_count + aggregate_slot_count]Envelope =
        [_]Envelope{[_]u8{0} ** envelope_size} ** (incident_slot_count + aggregate_slot_count),
    incident_count: u8 = 0,
    named_aggregate_used: [7]bool = [_]bool{false} ** 7,
    aggregate_generations: [aggregate_slot_count]u64 = [_]u64{0} ** aggregate_slot_count,

    pub fn publish(self: *EmergencyRing, incident: ConnectionIncident) PublishError!PublishResult {
        const payload = try encodeIncident(incident);
        const aggregate_index = (try self.findAggregate(incident)) orelse self.firstPristineNamedAggregate() orelse 7;
        const old_generation = self.aggregate_generations[aggregate_index];
        if (old_generation == std.math.maxInt(u64)) return error.AggregateGenerationExhausted;
        const new_generation = old_generation + 1;
        const detail_present = self.incident_count < incident_slot_count;
        const detail_slot: ?u8 = if (detail_present) self.incident_count else null;

        var aggregate = if (old_generation == 0)
            aggregateFromIncident(incident, aggregate_index == 7, !detail_present)
        else
            try decodeAggregatePayload(self.records[incident_slot_count + aggregate_index][16..224]);
        if (old_generation != 0) {
            aggregate.count = std.math.add(u64, aggregate.count, 1) catch std.math.maxInt(u64);
            if (!detail_present) {
                aggregate.detail_dropped_count = std.math.add(u64, aggregate.detail_dropped_count, 1) catch std.math.maxInt(u64);
                aggregate.flags |= 2;
            }
            aggregate.first_timestamp_ns = @min(aggregate.first_timestamp_ns, incident.timestamp_ns);
            aggregate.last_timestamp_ns = @max(aggregate.last_timestamp_ns, incident.timestamp_ns);
        }
        const aggregate_payload = try encodeAggregate(aggregate);

        if (detail_slot) |slot| {
            publishEnvelope(&self.records[slot], 1, @as(u64, slot) + 1, &payload);
            self.incident_count += 1;
        }
        publishEnvelope(
            &self.records[incident_slot_count + aggregate_index],
            2,
            new_generation,
            &aggregate_payload,
        );
        if (aggregate_index < 7) self.named_aggregate_used[aggregate_index] = true;
        self.aggregate_generations[aggregate_index] = new_generation;
        return .{
            .incident_id = incident.incident_id,
            .detail_present = detail_present,
            .detail_slot = detail_slot,
            .aggregate_slot = @intCast(aggregate_index),
            .aggregate_generation = new_generation,
        };
    }

    pub fn record(self: *const EmergencyRing, slot: usize) ?*const Envelope {
        if (slot >= self.records.len or !validEnvelope(&self.records[slot])) return null;
        return &self.records[slot];
    }

    fn recordRepeat(self: *EmergencyRing, incident: ConnectionIncident) PublishError!PublishResult {
        _ = try encodeIncident(incident);
        const aggregate_index = (try self.findAggregate(incident)) orelse 7;
        const old_generation = self.aggregate_generations[aggregate_index];
        if (old_generation == 0 or old_generation == std.math.maxInt(u64))
            return error.AggregateGenerationExhausted;
        var aggregate = try decodeAggregatePayload(self.records[incident_slot_count + aggregate_index][16..224]);
        aggregate.count = std.math.add(u64, aggregate.count, 1) catch std.math.maxInt(u64);
        aggregate.first_timestamp_ns = @min(aggregate.first_timestamp_ns, incident.timestamp_ns);
        aggregate.last_timestamp_ns = @max(aggregate.last_timestamp_ns, incident.timestamp_ns);
        const payload = try encodeAggregate(aggregate);
        const generation = old_generation + 1;
        publishEnvelope(&self.records[incident_slot_count + aggregate_index], 2, generation, &payload);
        self.aggregate_generations[aggregate_index] = generation;
        return .{
            .incident_id = incident.incident_id,
            .detail_present = false,
            .detail_slot = null,
            .aggregate_slot = @intCast(aggregate_index),
            .aggregate_generation = generation,
        };
    }

    fn findAggregate(self: *const EmergencyRing, incident: ConnectionIncident) ValidationError!?usize {
        for (self.named_aggregate_used, 0..) |used, index| {
            if (!used) continue;
            if (!validEnvelope(&self.records[incident_slot_count + index])) return error.InvalidIncident;
            const value = try decodeAggregatePayload(self.records[incident_slot_count + index][16..224]);
            if (value.reason_raw == incident.reason_raw and value.scope_raw == incident.scope_raw and
                value.source_site_raw == incident.source_site_raw and value.host_class_raw == incident.host_class_raw)
                return index;
        }
        return null;
    }

    fn firstPristineNamedAggregate(self: *const EmergencyRing) ?usize {
        for (self.named_aggregate_used, 0..) |used, index| if (!used) return index;
        return null;
    }
};

pub fn validateIncident(value: ConnectionIncident) ValidationError!void {
    if (value.version != encoding_version or value.record_kind != 1 or value.flags & ~@as(u8, 0x07) != 0)
        return error.InvalidIncident;
    if (value.incident_id.app_instance_nonce == 0 or value.incident_id.sequence == 0 or value.timestamp_ns < 0)
        return error.InvalidIncident;
    const identity_present = value.flags & 0x04 != 0;
    const complete_identity = value.host_id != 0 and value.host_adapter_generation != 0 and
        value.connection_generation != 0 and value.wire_major != 0;
    if (identity_present != complete_identity) return error.InvalidIncident;
    if (value.source_site_raw < 1 or value.source_site_raw > 16 or
        value.host_class_raw < 1 or value.host_class_raw > 3 or
        value.parser_phase_raw < 1 or value.parser_phase_raw > 4 or
        value.outbound_phase_raw < 1 or value.outbound_phase_raw > 4)
        return error.InvalidIncident;
    if (value.reason_raw > @intFromEnum(ConnectionReason.attachment_cleanup_failed) or
        value.scope_raw != @intFromEnum(Scope.connection)) return error.InvalidIncident;
    const reason: ConnectionReason = @enumFromInt(value.reason_raw);
    const expected = switch (reason) {
        .event_queue_overflow,
        .local_queue_exhausted,
        .frame_malformed,
        .response_correlation_lost,
        .peer_contract_violation,
        .local_invariant_violation,
        .external_transfer_quarantined,
        .attachment_cleanup_failed,
        => false,
        else => true,
    };
    const disposition: Disposition = if (reason == .capability_incompatible) .no_retry else .reconnect;
    if ((value.flags & 1 != 0) != expected or value.flags & 2 != 0 or
        value.disposition_raw != @intFromEnum(disposition)) return error.InvalidIncident;
    if (value.outbound_offset > value.outbound_length or value.occurrence_count != 1 or
        value.first_timestamp_ns != value.timestamp_ns or value.last_timestamp_ns != value.timestamp_ns or
        value.reserved0 != 0 or !allZero(&value.reserved_tail))
        return error.InvalidIncident;
    const outbound_idle = value.outbound_phase_raw == @intFromEnum(OutboundPhase.idle);
    if (outbound_idle != (value.outbound_offset == 0 and value.outbound_length == 0))
        return error.InvalidIncident;
}

pub fn encodeIncident(value: ConnectionIncident) ValidationError![payload_size]u8 {
    try validateIncident(value);
    var result = [_]u8{0} ** payload_size;
    var writer = std.Io.Writer.fixed(&result);
    writeInt(&writer, u16, value.version);
    writer.writeByte(value.record_kind) catch unreachable;
    writer.writeByte(value.flags) catch unreachable;
    writeInt(&writer, u128, value.incident_id.app_instance_nonce);
    writeInt(&writer, u64, value.incident_id.sequence);
    writeInt(&writer, i128, value.timestamp_ns);
    writeInt(&writer, u128, value.host_id);
    writeInt(&writer, u64, value.host_adapter_generation);
    writeInt(&writer, u64, value.connection_generation);
    writeInt(&writer, u16, value.wire_major);
    inline for (.{ value.reason_raw, value.scope_raw, value.disposition_raw, value.source_site_raw, value.host_class_raw, value.parser_phase_raw, value.outbound_phase_raw, value.reserved0 }) |byte|
        writer.writeByte(byte) catch unreachable;
    writeInt(&writer, u64, value.last_success_request_id);
    inline for (.{ value.pending_request_count, value.pending_stream_count, value.pending_event_count, value.queue_item_count }) |number|
        writeInt(&writer, u32, number);
    inline for (.{ value.queue_bytes, value.outbound_offset, value.outbound_length, value.controller_generation, value.upgrade_epoch, value.occurrence_count }) |number|
        writeInt(&writer, u64, number);
    writeInt(&writer, i128, value.first_timestamp_ns);
    writeInt(&writer, i128, value.last_timestamp_ns);
    writer.writeAll(&value.reserved_tail) catch unreachable;
    std.debug.assert(writer.buffered().len == payload_size);
    return result;
}

pub fn encodeAggregate(value: IncidentAggregate) ValidationError![payload_size]u8 {
    const other = value.flags & 1 != 0;
    const named_identity_valid = value.source_site_raw >= 1 and value.source_site_raw <= 16 and
        value.host_class_raw >= 1 and value.host_class_raw <= 3;
    const other_identity_valid = value.reason_raw == 0 and value.scope_raw == 0 and
        value.source_site_raw == 0 and value.host_class_raw == 0;
    if (value.version != encoding_version or value.kind != 2 or value.flags & ~@as(u8, 0x03) != 0 or
        (if (other) !other_identity_valid else !named_identity_valid) or value.count == 0 or value.detail_dropped_count > value.count or
        value.first_timestamp_ns < 0 or value.last_timestamp_ns < value.first_timestamp_ns or !allZero(&value.reserved))
        return error.InvalidIncident;
    var result = [_]u8{0} ** payload_size;
    var writer = std.Io.Writer.fixed(&result);
    writeInt(&writer, u16, value.version);
    inline for (.{ value.kind, value.flags, value.reason_raw, value.scope_raw, value.source_site_raw, value.host_class_raw }) |byte|
        writer.writeByte(byte) catch unreachable;
    writeInt(&writer, u64, value.count);
    writeInt(&writer, u64, value.detail_dropped_count);
    writeInt(&writer, i128, value.first_timestamp_ns);
    writeInt(&writer, i128, value.last_timestamp_ns);
    writer.writeAll(&value.reserved) catch unreachable;
    std.debug.assert(writer.buffered().len == payload_size);
    return result;
}

fn aggregateFromIncident(incident: ConnectionIncident, other: bool, detail_dropped: bool) IncidentAggregate {
    return .{
        .flags = (if (other) @as(u8, 1) else 0) | (if (detail_dropped) @as(u8, 2) else 0),
        .reason_raw = if (other) 0 else incident.reason_raw,
        .scope_raw = if (other) 0 else incident.scope_raw,
        .source_site_raw = if (other) 0 else incident.source_site_raw,
        .host_class_raw = if (other) 0 else incident.host_class_raw,
        .count = 1,
        .detail_dropped_count = if (detail_dropped) 1 else 0,
        .first_timestamp_ns = incident.timestamp_ns,
        .last_timestamp_ns = incident.timestamp_ns,
    };
}

fn decodeAggregatePayload(payload: []const u8) ValidationError!IncidentAggregate {
    if (payload.len != payload_size) return error.InvalidIncident;
    var cursor: usize = 0;
    var result: IncidentAggregate = .{
        .flags = 0,
        .reason_raw = 0,
        .scope_raw = 0,
        .source_site_raw = 0,
        .host_class_raw = 0,
        .count = 0,
        .detail_dropped_count = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };
    result.version = readInt(u16, payload, &cursor);
    result.kind = payload[cursor];
    cursor += 1;
    result.flags = payload[cursor];
    cursor += 1;
    result.reason_raw = payload[cursor];
    cursor += 1;
    result.scope_raw = payload[cursor];
    cursor += 1;
    result.source_site_raw = payload[cursor];
    cursor += 1;
    result.host_class_raw = payload[cursor];
    cursor += 1;
    result.count = readInt(u64, payload, &cursor);
    result.detail_dropped_count = readInt(u64, payload, &cursor);
    result.first_timestamp_ns = readInt(i128, payload, &cursor);
    result.last_timestamp_ns = readInt(i128, payload, &cursor);
    @memcpy(&result.reserved, payload[cursor..][0..result.reserved.len]);
    _ = try encodeAggregate(result);
    return result;
}

fn publishEnvelope(destination: *Envelope, kind: u8, generation: u64, payload: *const [payload_size]u8) void {
    destination.* = [_]u8{0} ** envelope_size;
    std.mem.writeInt(u16, destination[0..2], encoding_version, .little);
    destination[2] = kind;
    std.mem.writeInt(u16, destination[4..6], payload_size, .little);
    std.mem.writeInt(u64, destination[8..16], generation, .little);
    @memcpy(destination[16..224], payload);
    std.crypto.hash.Blake3.hash(destination[0..224], destination[224..256], .{});
    destination[3] = 1;
}

fn validEnvelope(value: *const Envelope) bool {
    if (value[3] != 1 or std.mem.readInt(u16, value[0..2], .little) != encoding_version or
        (value[2] != 1 and value[2] != 2) or std.mem.readInt(u16, value[4..6], .little) != payload_size or
        std.mem.readInt(u16, value[6..8], .little) != 0 or std.mem.readInt(u64, value[8..16], .little) == 0)
        return false;
    var canonical = value.*;
    canonical[3] = 0;
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(canonical[0..224], &digest, .{});
    return std.mem.eql(u8, &digest, value[224..256]);
}

fn readInt(comptime T: type, bytes: []const u8, cursor: *usize) T {
    const size = @sizeOf(T);
    defer cursor.* += size;
    return std.mem.readInt(T, bytes[cursor.*..][0..size], .little);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    writer.writeAll(&bytes) catch unreachable;
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .error_union => |info| containsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn fixture() ConnectionIncident {
    return .{
        .flags = 0x05,
        .incident_id = .{ .app_instance_nonce = 1, .sequence = 1 },
        .timestamp_ns = 7,
        .host_id = 2,
        .host_adapter_generation = 3,
        .connection_generation = 4,
        .wire_major = 1,
        .reason_raw = @intFromEnum(ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(Scope.connection),
        .disposition_raw = @intFromEnum(Disposition.reconnect),
        .source_site_raw = @intFromEnum(SourceSite.client_read),
        .host_class_raw = @intFromEnum(HostClass.current),
        .parser_phase_raw = @intFromEnum(ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(OutboundPhase.idle),
        .last_success_request_id = 0,
        .pending_request_count = 0,
        .pending_stream_count = 0,
        .pending_event_count = 0,
        .queue_item_count = 0,
        .queue_bytes = 0,
        .outbound_offset = 0,
        .outbound_length = 0,
        .controller_generation = 0,
        .upgrade_epoch = 0,
        .first_timestamp_ns = 7,
        .last_timestamp_ns = 7,
    };
}

fn unpublishedFixture() ConnectionIncident {
    var value = fixture();
    value.incident_id = .{ .app_instance_nonce = 0, .sequence = 0 };
    return value;
}

test "CR0b incident payload는 canonical encoding 208바이트다" {
    const original = fixture();
    const encoded = try encodeIncident(original);
    try std.testing.expectEqual(payload_size, encoded.len);
    try std.testing.expect(!containsPointer(ConnectionIncident));
    try std.testing.expect(!containsPointer(IncidentAggregate));
    try std.testing.expect(!containsPointer(PublishResult));

    // 길이만 고정하면 새 scalar가 transcript에서 빠져도 테스트가 통과한다. 유효한 각 축을 독립 변경해
    // canonical bytes가 실제 schema 전체에 결속되는지 확인한다.
    const variants = [_]ConnectionIncident{
        blk: {
            var value = original;
            value.incident_id.sequence += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.incident_id.app_instance_nonce += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.timestamp_ns += 1;
            value.first_timestamp_ns += 1;
            value.last_timestamp_ns += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.host_id += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.host_adapter_generation += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.connection_generation += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.wire_major += 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.source_site_raw = @intFromEnum(SourceSite.client_write);
            break :blk value;
        },
        blk: {
            var value = original;
            value.host_class_raw = @intFromEnum(HostClass.previous);
            break :blk value;
        },
        blk: {
            var value = original;
            value.parser_phase_raw = @intFromEnum(ParserPhase.header);
            break :blk value;
        },
        blk: {
            var value = original;
            value.outbound_phase_raw = @intFromEnum(OutboundPhase.queued);
            value.outbound_length = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.last_success_request_id = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.pending_request_count = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.pending_stream_count = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.pending_event_count = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.queue_item_count = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.queue_bytes = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.controller_generation = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.upgrade_epoch = 1;
            break :blk value;
        },
        blk: {
            var value = original;
            value.reason_raw = @intFromEnum(ConnectionReason.frame_malformed);
            value.flags &= ~@as(u8, 1);
            break :blk value;
        },
        blk: {
            var value = original;
            value.reason_raw = @intFromEnum(ConnectionReason.capability_incompatible);
            value.disposition_raw = @intFromEnum(Disposition.no_retry);
            break :blk value;
        },
    };
    for (variants) |variant| {
        const changed = try encodeIncident(variant);
        try std.testing.expect(!std.mem.eql(u8, &encoded, &changed));
    }
}

test "CR0b ring 산술은 256바이트 record 128개로 정확히 32 KiB다" {
    try std.testing.expectEqual(@as(usize, 128), incident_slot_count + aggregate_slot_count);
    try std.testing.expectEqual(ring_size, envelope_size * (incident_slot_count + aggregate_slot_count));
    try std.testing.expectEqual(envelope_size, 16 + payload_size + 32);
}

test "CR0b SourceSite는 1부터 16까지 빈 raw 값 없이 닫혀 있다" {
    const tags = std.meta.tags(SourceSite);
    try std.testing.expectEqual(@as(usize, 16), tags.len);
    inline for (tags, 1..) |tag, raw| try std.testing.expectEqual(raw, @intFromEnum(tag));
}

test "CR0b incident는 불완전한 host identity를 거부한다" {
    var value = fixture();
    value.connection_generation = 0;
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
    value.flags &= ~@as(u8, 0x04);
    value.host_id = 0;
    value.host_adapter_generation = 0;
    value.wire_major = 0;
    try validateIncident(value);
}

test "CR0b incident는 outbound phase와 descriptor를 함께 검증한다" {
    var value = fixture();
    value.outbound_length = 4;
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
    value.outbound_phase_raw = @intFromEnum(OutboundPhase.partial);
    value.outbound_offset = 5;
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
}

test "CR0b incident는 CR0a reason decision 조합만 허용한다" {
    var value = fixture();
    value.flags &= ~@as(u8, 1);
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
    value.flags |= 1;
    value.reason_raw = @intFromEnum(ConnectionReason.local_invariant_violation);
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
    value.flags &= ~@as(u8, 1);
    try validateIncident(value);
    value.reason_raw = @intFromEnum(ConnectionReason.capability_incompatible);
    value.flags |= 1;
    value.disposition_raw = @intFromEnum(Disposition.reconnect);
    try std.testing.expectError(error.InvalidIncident, validateIncident(value));
}

test "CR0b aggregate canonical schema도 payload 208바이트를 정확히 채운다" {
    const encoded = try encodeAggregate(.{
        .flags = 0,
        .reason_raw = @intFromEnum(ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(Scope.connection),
        .source_site_raw = @intFromEnum(SourceSite.client_read),
        .host_class_raw = @intFromEnum(HostClass.current),
        .count = 2,
        .detail_dropped_count = 1,
        .first_timestamp_ns = 7,
        .last_timestamp_ns = 9,
    });
    try std.testing.expectEqual(payload_size, encoded.len);
}

test "CR0b ring은 최초 incident와 aggregate를 같은 publication에서 기록한다" {
    var ring: EmergencyRing = .{};
    const published = try ring.publish(fixture());
    try std.testing.expect(published.detail_present);
    try std.testing.expectEqual(@as(?u8, 0), published.detail_slot);
    try std.testing.expectEqual(@as(u8, 0), published.aggregate_slot);
    try std.testing.expect(ring.record(0) != null);
    try std.testing.expect(ring.record(incident_slot_count) != null);
}

test "CR0b ring은 상세 120개 뒤에도 aggregate detail dropped 증거를 남긴다" {
    var ring: EmergencyRing = .{};
    var value = fixture();
    for (0..incident_slot_count + 1) |index| {
        value.incident_id.sequence = index + 1;
        value.timestamp_ns = @intCast(index + 1);
        value.first_timestamp_ns = value.timestamp_ns;
        value.last_timestamp_ns = value.timestamp_ns;
        const published = try ring.publish(value);
        try std.testing.expectEqual(index < incident_slot_count, published.detail_present);
    }
    const aggregate = try decodeAggregatePayload(ring.records[incident_slot_count][16..224]);
    try std.testing.expectEqual(@as(u64, incident_slot_count + 1), aggregate.count);
    try std.testing.expectEqual(@as(u64, 1), aggregate.detail_dropped_count);
    try std.testing.expectEqual(@as(u8, 2), aggregate.flags & 2);
}

test "CR0b ring은 named aggregate 일곱 개 뒤 고정 other만 갱신한다" {
    var ring: EmergencyRing = .{};
    var value = fixture();
    for (0..9) |index| {
        value.incident_id.sequence = index + 1;
        value.source_site_raw = @intCast(index + 1);
        value.timestamp_ns = @intCast(index + 1);
        value.first_timestamp_ns = value.timestamp_ns;
        value.last_timestamp_ns = value.timestamp_ns;
        const published = try ring.publish(value);
        try std.testing.expectEqual(@as(u8, @intCast(@min(index, 7))), published.aggregate_slot);
    }
    const other = try decodeAggregatePayload(ring.records[incident_slot_count + 7][16..224]);
    try std.testing.expectEqual(@as(u8, 1), other.flags & 1);
    try std.testing.expectEqual(@as(u64, 2), other.count);
}

test "CR0b envelope는 committed와 header와 digest drift를 모두 거부한다" {
    var ring: EmergencyRing = .{};
    _ = try ring.publish(fixture());
    try std.testing.expect(ring.record(0) != null);
    inline for (.{ @as(usize, 3), 4, 8, 16, 224 }) |offset| {
        const original = ring.records[0][offset];
        ring.records[0][offset] ^= 1;
        try std.testing.expect(ring.record(0) == null);
        ring.records[0][offset] = original;
    }
}

test "CR0b aggregate generation exhaustion은 ring을 변경하지 않는다" {
    var ring: EmergencyRing = .{};
    _ = try ring.publish(fixture());
    ring.aggregate_generations[0] = std.math.maxInt(u64);
    const before = ring;
    try std.testing.expectError(error.AggregateGenerationExhausted, ring.publish(fixture()));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&ring));
}

test "CR0b service는 app nonce와 checked sequence를 incident에 exact once 발급한다" {
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    const first = try service.publish(7, 9, unpublishedFixture());
    const second = try service.publish(7, 9, unpublishedFixture());
    try std.testing.expectEqual(IncidentId{ .app_instance_nonce = 11, .sequence = 1 }, first.incident_id);
    try std.testing.expectEqual(IncidentId{ .app_instance_nonce = 11, .sequence = 2 }, second.incident_id);
    try std.testing.expectEqual(@as(u128, 0b11) | (@as(u128, 1) << incident_slot_count), service.pending_slots);
}

test "CR0b service는 copied address와 PID domain mismatch를 ring mutation 전에 거부한다" {
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    var copied = service;
    const copied_before = copied;
    try std.testing.expectError(error.InvalidAuthority, copied.publish(7, 9, unpublishedFixture()));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&copied_before), std.mem.asBytes(&copied));
    const before = service;
    try std.testing.expectError(error.InvalidAuthority, service.publish(8, 9, unpublishedFixture()));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&service));
}

test "CR0b service는 fork child를 상속 mutex 접근 전에 거부한다" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var service: ConnectionIncidentService = .{};
    const parent_pid: u64 = @intCast(std.c.getpid());
    try ConnectionIncidentService.initInPlace(&service, parent_pid, 9, 11);
    lock(&service.mutex);
    const child = std.c.fork();
    if (child < 0) {
        service.mutex.unlock();
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        const child_pid: u64 = @intCast(std.c.getpid());
        _ = service.publish(child_pid, 9, unpublishedFixture()) catch |err| {
            std.c._exit(if (err == error.InvalidAuthority) 73 else 125);
        };
        std.c._exit(124);
    }
    var status: c_int = 0;
    const waited = std.c.waitpid(child, &status, 0);
    service.mutex.unlock();
    try std.testing.expectEqual(child, waited);
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 73), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
    try std.testing.expectEqual(@as(u64, 0), service.last_issued_sequence);
    try std.testing.expectEqual(@as(u128, 0), service.pending_slots);
}

test "CR0b service는 동시 최초 publication에 중복 없는 sequence를 발급한다" {
    const thread_count = 8;
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    var results: [thread_count]IncidentId = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(owner: *ConnectionIncidentService, out: *IncidentId, timestamp: i128) void {
                var input = unpublishedFixture();
                input.timestamp_ns = timestamp;
                input.first_timestamp_ns = timestamp;
                input.last_timestamp_ns = timestamp;
                out.* = (owner.publish(7, 9, input) catch @panic("동시 incident publication 실패")).incident_id;
            }
        }.run, .{ &service, &results[index], @as(i128, @intCast(index + 1)) });
    }
    for (threads) |thread| thread.join();
    var seen: u16 = 0;
    for (results) |result| {
        try std.testing.expectEqual(@as(u128, 11), result.app_instance_nonce);
        try std.testing.expect(result.sequence >= 1 and result.sequence <= thread_count);
        const bit = @as(u16, 1) << @intCast(result.sequence - 1);
        try std.testing.expect(seen & bit == 0);
        seen |= bit;
    }
    try std.testing.expectEqual(@as(u16, (1 << thread_count) - 1), seen);
    try std.testing.expectEqual(@as(u64, thread_count), service.last_issued_sequence);
}

test "CR0b service sequence exhaustion은 마지막 발급 뒤 mutation 없이 닫힌다" {
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    service.last_issued_sequence = std.math.maxInt(u64);
    const before = service;
    try std.testing.expectError(error.InvalidAuthority, service.publish(7, 9, unpublishedFixture()));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&service));
}

test "CR0b repeat는 incident sequence와 detail slot을 소비하지 않고 aggregate만 갱신한다" {
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    const first = try service.publish(7, 9, unpublishedFixture());
    var repeat = fixture();
    repeat.incident_id = first.incident_id;
    repeat.timestamp_ns = 12;
    repeat.first_timestamp_ns = 12;
    repeat.last_timestamp_ns = 12;
    const result = try service.recordRepeatForTest(7, 9, repeat);
    try std.testing.expect(!result.detail_present);
    try std.testing.expectEqual(@as(u64, 1), service.last_issued_sequence);
    try std.testing.expectEqual(@as(u8, 1), service.ring.incident_count);
    const aggregate = try decodeAggregatePayload(service.ring.records[incident_slot_count][16..224]);
    try std.testing.expectEqual(@as(u64, 2), aggregate.count);
    try std.testing.expectEqual(@as(i128, 7), aggregate.first_timestamp_ns);
    try std.testing.expectEqual(@as(i128, 12), aggregate.last_timestamp_ns);
}

test "CR0b repeat는 foreign incident ID를 aggregate mutation 전에 거부한다" {
    var service: ConnectionIncidentService = .{};
    try ConnectionIncidentService.initInPlace(&service, 7, 9, 11);
    _ = try service.publish(7, 9, unpublishedFixture());
    var repeat = fixture();
    repeat.incident_id = .{ .app_instance_nonce = 12, .sequence = 1 };
    const before = service;
    try std.testing.expectError(error.InvalidAuthority, service.recordRepeatForTest(7, 9, repeat));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&service));
}

test "CR0b ring은 기존 aggregate digest 손상을 새 fingerprint로 우회하지 않는다" {
    var ring: EmergencyRing = .{};
    _ = try ring.publish(fixture());
    ring.records[incident_slot_count][224] ^= 1;
    const before = ring;
    try std.testing.expectError(error.InvalidIncident, ring.publish(fixture()));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&ring));
}
