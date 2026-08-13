//! CR0b reconnect scheduler admission의 process-local bounded owner.
//!
//! Inline row가 final-address sealed admission을 소유하고 scheduler에는 pointer-free projection만 준다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");
const publication = @import("maru").observability.incident_publication_contract;

pub const capacity: usize = 64;
pub const Error = error{ InvalidOwner, Busy, Full, NotFound };
const Lifecycle = enum(u8) { pristine = 0, ready = 1, closed = 2 };

pub const Projection = struct {
    slot_index: u8,
    slot_generation: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    incident_id: @import("maru").observability.connection_incident.IncidentId,
};

const Row = struct {
    generation: u64 = 0,
    admission: publication.ReconnectAdmission = .{},
};

pub const Owner = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    next_generation: u64 = 1,
    count: u8 = 0,
    lifecycle_raw: u8 = 0,
    rows: [capacity]Row = [_]Row{.{}} ** capacity,

    pub fn initInPlace(self: *Owner, process_nonce: u64) Error!void {
        const pid = process_seal.currentProcessId();
        if (!std.meta.eql(self.*, Owner{}) or pid == 0 or process_nonce == 0) return error.InvalidOwner;
        process_seal.validateReady(pid, process_nonce) catch return error.InvalidOwner;
        self.self_addr = @intFromPtr(self);
        self.pid = pid;
        self.process_nonce = process_nonce;
        self.owner_thread = @intCast(std.Thread.getCurrentId());
        self.lifecycle_raw = @intFromEnum(Lifecycle.ready);
    }

    pub fn admit(self: *Owner, result: publication.IncidentCommitResult, input: publication.IncidentInput) Error!void {
        if (result.kind_raw != @intFromEnum(publication.PublicationKind.first) or
            input.disposition_raw != @intFromEnum(@import("maru").observability.connection_incident.Disposition.reconnect))
            return error.InvalidOwner;
        try self.preflight(input);
        // Owner-thread serialization makes this suffix no-fail after the identical preflight.
        self.admitAfterPreflightNoFail(result, input);
    }

    pub fn preflight(self: *Owner, input: publication.IncidentInput) Error!void {
        try self.validate();
        if (input.disposition_raw != @intFromEnum(@import("maru").observability.connection_incident.Disposition.reconnect))
            return error.InvalidOwner;
        for (&self.rows) |*row| {
            if (row.generation != 0 and row.admission.host_id == input.host_id and
                row.admission.connection_generation == input.connection_generation) return error.Busy;
        }
        for (&self.rows) |row| if (row.generation == 0) return;
        return error.Full;
    }

    pub fn admitAfterPreflightNoFail(
        self: *Owner,
        result: publication.IncidentCommitResult,
        input: publication.IncidentInput,
    ) void {
        self.validate() catch process_seal.fatalIntegrity(.incident_authority);
        if (result.kind_raw != @intFromEnum(publication.PublicationKind.first) or
            input.disposition_raw != @intFromEnum(@import("maru").observability.connection_incident.Disposition.reconnect))
            process_seal.fatalIntegrity(.incident_authority);
        var target: ?*Row = null;
        for (&self.rows) |*row| {
            if (row.generation == 0 and target == null) target = row;
        }
        const row = target orelse process_seal.fatalIntegrity(.incident_authority);
        const generation = self.next_generation;
        if (generation == 0 or generation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        var value: publication.ReconnectAdmission = .{
            .self_addr = @intFromPtr(&row.admission),
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .owner_thread = self.owner_thread,
            .host_id = input.host_id,
            .host_adapter_generation = input.host_adapter_generation,
            .connection_generation = input.connection_generation,
            .incident_id = result.publication.incident_id,
            .disposition_raw = input.disposition_raw,
            .lifecycle_raw = @intFromEnum(publication.ReconnectAdmissionLifecycle.admitted),
        };
        value.seal = admissionSeal(value);
        row.* = .{ .generation = generation, .admission = value };
        self.next_generation = generation + 1;
        self.count += 1;
    }

    pub fn peek(self: *Owner) Error!?Projection {
        try self.validate();
        for (&self.rows, 0..) |*row, index| if (row.generation != 0) {
            if (!validRow(row)) return error.InvalidOwner;
            return projection(row, @intCast(index));
        };
        return null;
    }

    pub fn consume(self: *Owner, expected: Projection) Error!void {
        try self.validate();
        if (expected.slot_index >= capacity) return error.NotFound;
        const row = &self.rows[expected.slot_index];
        if (!validRow(row) or !std.meta.eql(expected, projection(row, expected.slot_index))) return error.NotFound;
        row.* = .{};
        self.count -= 1;
    }

    pub fn ownedBy(self: *const Owner, pid: u32, process_nonce: u64, owner_thread: u64) bool {
        self.validate() catch return false;
        return self.pid == pid and self.process_nonce == process_nonce and self.owner_thread == owner_thread;
    }

    fn validate(self: *const Owner) Error!void {
        if (self.self_addr != @intFromPtr(self) or self.pid != process_seal.currentProcessId() or
            self.process_nonce == 0 or self.owner_thread != @as(u64, @intCast(std.Thread.getCurrentId())) or
            self.lifecycle_raw != @intFromEnum(Lifecycle.ready) or self.count > capacity) return error.InvalidOwner;
        process_seal.validateReady(self.pid, self.process_nonce) catch return error.InvalidOwner;
    }
};

fn projection(row: *const Row, index: u8) Projection {
    return .{
        .slot_index = index,
        .slot_generation = row.generation,
        .host_id = row.admission.host_id,
        .host_adapter_generation = row.admission.host_adapter_generation,
        .connection_generation = row.admission.connection_generation,
        .incident_id = row.admission.incident_id,
    };
}

fn validRow(row: *const Row) bool {
    return row.generation != 0 and publication.validReconnectAdmissionShape(row.admission, @intFromPtr(&row.admission)) and
        std.mem.eql(u8, &row.admission.seal, &admissionSeal(row.admission));
}

fn admissionSeal(value: publication.ReconnectAdmission) [32]u8 {
    return process_seal.reconnectAdmissionSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .owner_thread = value.owner_thread,
        .host_id = value.host_id,
        .host_adapter_generation = value.host_adapter_generation,
        .connection_generation = value.connection_generation,
        .incident_app_instance_nonce = value.incident_id.app_instance_nonce,
        .incident_sequence = value.incident_id.sequence,
        .disposition_raw = value.disposition_raw,
        .lifecycle_raw = value.lifecycle_raw,
    }) catch process_seal.fatalIntegrity(.incident_authority);
}

fn fixtureResult(sequence: u64, detail: bool) publication.IncidentCommitResult {
    return .{ .publication = .{
        .incident_id = .{ .app_instance_nonce = 1, .sequence = sequence },
        .detail_present = detail,
        .detail_slot = 0,
        .aggregate_slot = 0,
        .aggregate_generation = 1,
    }, .wake = .queued, .kind_raw = @intFromEnum(publication.PublicationKind.first) };
}

fn fixtureInput(generation: u64) publication.IncidentInput {
    const incident = @import("maru").observability.connection_incident;
    return .{ .timestamp_ns = 1, .host_id = 2, .host_adapter_generation = 3, .connection_generation = generation, .wire_major = 1, .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof), .scope_raw = @intFromEnum(incident.Scope.connection), .disposition_raw = @intFromEnum(incident.Disposition.reconnect), .source_site_raw = @intFromEnum(incident.SourceSite.client_read), .host_class_raw = @intFromEnum(incident.HostClass.current), .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle), .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle) };
}

test "CR0b reconnect admission owner는 first publication을 exact once 게시하고 consume한다" {
    try @import("client_slot.zig").ClientSlot.initializeProcessRuntime();
    var owner: Owner = .{};
    try owner.initInPlace(@import("client_slot.zig").ClientSlot.publicationProcessIdentity().?.process_nonce);
    try owner.admit(fixtureResult(1, true), fixtureInput(1));
    const value = (try owner.peek()).?;
    try std.testing.expectEqual(@as(u8, 1), owner.count);
    try std.testing.expectError(error.Busy, owner.admit(fixtureResult(1, true), fixtureInput(1)));
    try owner.consume(value);
    try std.testing.expectEqual(@as(u8, 0), owner.count);
    try std.testing.expectError(error.NotFound, owner.consume(value));
}

test "CR0b reconnect admission owner는 repeat와 no-retry를 mutation 없이 거부한다" {
    try @import("client_slot.zig").ClientSlot.initializeProcessRuntime();
    var owner: Owner = .{};
    try owner.initInPlace(@import("client_slot.zig").ClientSlot.publicationProcessIdentity().?.process_nonce);
    var repeat = fixtureResult(1, false);
    repeat.kind_raw = @intFromEnum(publication.PublicationKind.repeat);
    try std.testing.expectError(error.InvalidOwner, owner.admit(repeat, fixtureInput(1)));
    var input = fixtureInput(1);
    input.disposition_raw = @intFromEnum(@import("maru").observability.connection_incident.Disposition.no_retry);
    try std.testing.expectError(error.InvalidOwner, owner.admit(fixtureResult(1, true), input));
    try std.testing.expectEqual(@as(u8, 0), owner.count);
}
