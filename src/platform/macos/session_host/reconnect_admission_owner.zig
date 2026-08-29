//! CR0b reconnect scheduler admission의 process-local bounded owner.
//!
//! Inline row가 final-address sealed admission을 소유하고 scheduler에는 pointer-free projection만 준다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");
const policy = @import("reconnect_admission_policy.zig");
const publication = @import("maru").observability.incident_publication_contract;

pub const capacity: usize = policy.max_queued_admissions;
pub const Error = error{ InvalidOwner, Busy, Full, NotFound, AttemptExhausted };
const Lifecycle = enum(u8) { pristine = 0, ready = 1, closed = 2 };
const RowLifecycle = enum(u8) { pristine = 0, admitted = 1, claimed = 2, scheduled = 3 };

pub const DispatchOutcome = enum(u8) {
    scheduled = 1,
    retry_later = 2,
    discarded_stale = 3,
};

pub const PreparedReconnectDispatch = struct {
    pub const Lifecycle = enum(u8) { pristine = 0, prepared = 1, consumed = 2 };

    self_addr: u64 = 0,
    owner_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    slot_index: u8 = 0,
    slot_generation: u64 = 0,
    host_id: u128 = 0,
    host_adapter_generation: u64 = 0,
    connection_generation: u64 = 0,
    incident_id: @import("maru").observability.connection_incident.IncidentId = .{
        .app_instance_nonce = 0,
        .sequence = 0,
    },
    attempt_generation: u64 = 0,
    lifecycle: PreparedReconnectDispatch.Lifecycle = .pristine,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

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
    attempt_generation: u64 = 0,
    dispatch_addr: u64 = 0,
    lifecycle: RowLifecycle = .pristine,
    admission: publication.ReconnectAdmission = .{},
};

pub const Owner = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    next_generation: u64 = 1,
    next_attempt_generation: u64 = 1,
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
            if (row.lifecycle != .pristine and row.admission.host_id == input.host_id and
                row.admission.connection_generation == input.connection_generation) return error.Busy;
        }
        for (&self.rows) |row| if (row.lifecycle == .pristine) return;
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
            if (row.lifecycle == .pristine and target == null) target = row;
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
        row.* = .{ .generation = generation, .lifecycle = .admitted, .admission = value };
        self.next_generation = generation + 1;
        self.count += 1;
    }

    pub fn peek(self: *Owner) Error!?Projection {
        try self.validate();
        for (&self.rows, 0..) |*row, index| if (row.lifecycle == .admitted) {
            if (!validRow(row)) return error.InvalidOwner;
            return projection(row, @intCast(index));
        };
        return null;
    }

    pub fn consume(self: *Owner, expected: Projection) Error!void {
        try self.validate();
        if (expected.slot_index >= capacity) return error.NotFound;
        const row = &self.rows[expected.slot_index];
        if (row.lifecycle != .admitted or !validRow(row) or
            !std.meta.eql(expected, projection(row, expected.slot_index))) return error.NotFound;
        row.* = .{};
        self.count -= 1;
    }

    /// CR1 scheduler는 raw admission pointer를 받지 않는다. caller-owned final address를
    /// exact row와 attempt generation에 봉인하고 row 자체를 claimed로 바꾼다.
    pub fn prepareDispatch(self: *Owner, out: *PreparedReconnectDispatch) Error!void {
        try self.validate();
        // `out`을 읽거나 쓰기 전에 owner 전체 extent와 겹침을 닫는다. Row 내부를
        // destination으로 위조하면 pristine bytes여도 claim publication이 owner를 덮을 수 있다.
        if (objectsOverlap(self, out) or !std.meta.eql(out.*, PreparedReconnectDispatch{}))
            return error.InvalidOwner;
        if (self.next_attempt_generation == 0 or self.next_attempt_generation == std.math.maxInt(u64))
            return error.AttemptExhausted;
        for (&self.rows, 0..) |*row, index| {
            if (row.lifecycle != .admitted) continue;
            if (!validRow(row)) return error.InvalidOwner;
            const attempt_generation = self.next_attempt_generation;
            out.* = .{
                .self_addr = @intFromPtr(out),
                .owner_addr = @intFromPtr(self),
                .pid = self.pid,
                .process_nonce = self.process_nonce,
                .owner_thread = self.owner_thread,
                .slot_index = @intCast(index),
                .slot_generation = row.generation,
                .host_id = row.admission.host_id,
                .host_adapter_generation = row.admission.host_adapter_generation,
                .connection_generation = row.admission.connection_generation,
                .incident_id = row.admission.incident_id,
                .attempt_generation = attempt_generation,
                .lifecycle = .prepared,
            };
            out.seal = dispatchSeal(out.*);
            row.attempt_generation = attempt_generation;
            row.dispatch_addr = @intFromPtr(out);
            row.lifecycle = .claimed;
            self.next_attempt_generation = attempt_generation + 1;
            return;
        }
        return error.NotFound;
    }

    pub fn settleDispatch(
        self: *Owner,
        dispatch: *PreparedReconnectDispatch,
        outcome: DispatchOutcome,
    ) Error!void {
        try self.validate();
        if (!dispatchLifecycleValid(dispatch.lifecycle) or dispatch.lifecycle != .prepared or
            dispatch.slot_index >= capacity or !validDispatch(self, dispatch)) return error.InvalidOwner;
        const row = &self.rows[dispatch.slot_index];
        if (row.lifecycle != .claimed or !validRow(row) or row.dispatch_addr != @intFromPtr(dispatch) or
            row.attempt_generation != dispatch.attempt_generation or row.generation != dispatch.slot_generation or
            !std.meta.eql(projection(row, dispatch.slot_index), dispatchProjection(dispatch.*)))
            return error.InvalidOwner;
        switch (outcome) {
            .scheduled => {
                row.lifecycle = .scheduled;
                row.dispatch_addr = 0;
            },
            .retry_later => {
                row.lifecycle = .admitted;
                row.dispatch_addr = 0;
            },
            .discarded_stale => {
                row.* = .{};
                self.count -= 1;
            },
        }
        dispatch.lifecycle = .consumed;
        dispatch.seal = dispatchSeal(dispatch.*);
    }

    /// Backend callers must validate the final-address dispatch before using any field to select
    /// or mutate runtimes. `settleDispatch` performs the same proof again at commit time.
    pub fn preparedProjection(
        self: *Owner,
        dispatch: *const PreparedReconnectDispatch,
    ) Error!Projection {
        try self.validate();
        if (!dispatchLifecycleValid(dispatch.lifecycle) or dispatch.lifecycle != .prepared or
            dispatch.slot_index >= capacity or !validDispatch(self, dispatch))
            return error.InvalidOwner;
        const row = &self.rows[dispatch.slot_index];
        if (row.lifecycle != .claimed or !validRow(row) or row.dispatch_addr != @intFromPtr(dispatch) or
            row.attempt_generation != dispatch.attempt_generation or row.generation != dispatch.slot_generation or
            !std.meta.eql(projection(row, dispatch.slot_index), dispatchProjection(dispatch.*)))
            return error.InvalidOwner;
        return dispatchProjection(dispatch.*);
    }

    pub fn peekScheduled(self: *Owner) Error!?Projection {
        try self.validate();
        for (&self.rows, 0..) |*row, index| if (row.lifecycle == .scheduled) {
            if (!validRow(row)) return error.InvalidOwner;
            return projection(row, @intCast(index));
        };
        return null;
    }

    pub fn consumeScheduled(self: *Owner, expected: Projection) Error!void {
        try self.validate();
        if (expected.slot_index >= capacity) return error.NotFound;
        const row = &self.rows[expected.slot_index];
        if (row.lifecycle != .scheduled or !validRow(row) or
            !std.meta.eql(expected, projection(row, expected.slot_index))) return error.NotFound;
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
        var occupied: u8 = 0;
        for (&self.rows) |*row| {
            if (row.lifecycle != .pristine) occupied += 1;
        }
        if (occupied != self.count) return error.InvalidOwner;
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
    return row.generation != 0 and row.lifecycle != .pristine and
        switch (row.lifecycle) {
            .pristine => false,
            .admitted => row.dispatch_addr == 0,
            .claimed => row.attempt_generation != 0 and row.dispatch_addr != 0,
            .scheduled => row.attempt_generation != 0 and row.dispatch_addr == 0,
        } and
        publication.validReconnectAdmissionShape(row.admission, @intFromPtr(&row.admission)) and
        std.mem.eql(u8, &row.admission.seal, &admissionSeal(row.admission));
}

fn dispatchProjection(value: PreparedReconnectDispatch) Projection {
    return .{
        .slot_index = value.slot_index,
        .slot_generation = value.slot_generation,
        .host_id = value.host_id,
        .host_adapter_generation = value.host_adapter_generation,
        .connection_generation = value.connection_generation,
        .incident_id = value.incident_id,
    };
}

fn dispatchLifecycleValid(value: PreparedReconnectDispatch.Lifecycle) bool {
    return @as(*const u8, @ptrCast(&value)).* <= @intFromEnum(PreparedReconnectDispatch.Lifecycle.consumed);
}

fn objectsOverlap(first: anytype, second: anytype) bool {
    const first_start = @intFromPtr(first);
    const second_start = @intFromPtr(second);
    const first_end = std.math.add(usize, first_start, @sizeOf(@TypeOf(first.*))) catch return true;
    const second_end = std.math.add(usize, second_start, @sizeOf(@TypeOf(second.*))) catch return true;
    return first_start < second_end and second_start < first_end;
}

fn validDispatch(self: *const Owner, value: *const PreparedReconnectDispatch) bool {
    return value.self_addr == @intFromPtr(value) and value.owner_addr == @intFromPtr(self) and
        value.pid == self.pid and value.process_nonce == self.process_nonce and
        value.owner_thread == self.owner_thread and value.slot_generation != 0 and
        value.host_id != 0 and value.host_adapter_generation != 0 and
        value.connection_generation != 0 and value.incident_id.app_instance_nonce != 0 and
        value.incident_id.sequence != 0 and value.attempt_generation != 0 and
        std.mem.eql(u8, &value.seal, &dispatchSeal(value.*));
}

fn dispatchSeal(value: PreparedReconnectDispatch) process_seal.CleanupSeal {
    return process_seal.preparedReconnectDispatchSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .owner_addr = value.owner_addr,
        .owner_thread = value.owner_thread,
        .slot_index = value.slot_index,
        .slot_generation = value.slot_generation,
        .host_id = value.host_id,
        .host_adapter_generation = value.host_adapter_generation,
        .connection_generation = value.connection_generation,
        .incident_app_instance_nonce = value.incident_id.app_instance_nonce,
        .incident_sequence = value.incident_id.sequence,
        .attempt_generation = value.attempt_generation,
        .lifecycle_raw = @intFromEnum(value.lifecycle),
    }) catch process_seal.fatalIntegrity(.incident_authority);
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

test "CR0b reconnect admission owner는 prepared projection을 mutation 전에 봉인 검증한다" {
    try @import("client_slot.zig").ClientSlot.initializeProcessRuntime();
    var owner: Owner = .{};
    try owner.initInPlace(@import("client_slot.zig").ClientSlot.publicationProcessIdentity().?.process_nonce);
    try owner.admit(fixtureResult(1, true), fixtureInput(1));
    var dispatch: PreparedReconnectDispatch = .{};
    try owner.prepareDispatch(&dispatch);
    const expected = try owner.preparedProjection(&dispatch);
    dispatch.incident_id.sequence += 1;
    try std.testing.expectError(error.InvalidOwner, owner.preparedProjection(&dispatch));
    dispatch.incident_id.sequence -= 1;
    try std.testing.expectEqualDeep(expected, try owner.preparedProjection(&dispatch));
    try owner.settleDispatch(&dispatch, .retry_later);
}
