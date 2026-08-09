const std = @import("std");
const builtin = @import("builtin");
const client_slot = @import("client_slot.zig");
const connection_lease = @import("connection_lease.zig");
const owner_seal = @import("external_owner_seal.zig");
const protocol = @import("protocol.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");

pub const EventAdmission = union(enum) {
    accepted: runtime_event_wire.EventPreflight,
    unknown,
};

pub const EventView = struct {
    wire_major: u16,
    payload: []const u8,
    admission: EventAdmission,
};

pub const EventTakeOutcome = enum { idle, ended_pending, taken };
pub const EventError = error{ Busy, InvalidOwner, Corrupt, Terminal };
pub const EventViewError = error{ InvalidOwner, Terminal };

const Lifecycle = enum(u8) { pristine, live, releasing, terminal };
const AdmissionTag = enum(u8) { unknown, accepted };
pub const owner_storage_size = 512;
pub const max_inline_owner_bytes = owner_storage_size * protocol.max_inventory_runtimes;

const Internal = struct {
    self_addr: usize = 0,
    identity: client_slot.GenerationEventIdentity = undefined,
    wire_major: u16 = 0,
    payload: []u8 = undefined,
    admission_tag: AdmissionTag = .unknown,
    lease: connection_lease.ConnectionLease = .{},
    seal: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: Lifecycle = .pristine,
};

pub const EventOwner = extern struct {
    storage: [owner_storage_size]u8 align(@alignOf(Internal)) =
        [_]u8{0} ** owner_storage_size,

    pub fn view(self: *const EventOwner) EventViewError!EventView {
        return viewOwner(self);
    }
};

fn internal(owner: *EventOwner) *Internal {
    return @ptrCast(@alignCast(&owner.storage));
}

fn internalConst(owner: *const EventOwner) *const Internal {
    return @ptrCast(@alignCast(&owner.storage));
}

fn admissionRawValid(admission: *const AdmissionTag) bool {
    const raw = @as(*const u8, @ptrCast(admission)).*;
    return raw <= @intFromEnum(AdmissionTag.accepted);
}

fn lifecycleRawValid(lifecycle: *const Lifecycle) bool {
    const raw = @as(*const u8, @ptrCast(lifecycle)).*;
    return raw <= @intFromEnum(Lifecycle.terminal);
}

pub fn pristineExact(owner: *const EventOwner) bool {
    return std.mem.allEqual(u8, &owner.storage, 0);
}

/// Attachment-local drift check only. The binding registry remains the canonical event authority;
/// callers must not use this projection to free, drop, or settle registry state.
pub fn liveGenerationMatches(owner: *const EventOwner, generation: u64) bool {
    if (generation == 0) return false;
    const state = internalConst(owner);
    return lifecycleRawValid(&state.lifecycle) and state.lifecycle == .live and
        state.self_addr == @intFromPtr(owner) and
        state.identity.receipt.owner_addr == @intFromPtr(owner) and
        state.identity.receipt.event_generation == generation and
        std.mem.eql(u8, &state.seal, &sealFor(state));
}

pub fn activeGenerationMatches(owner: *const EventOwner, generation: u64) bool {
    if (generation == 0) return false;
    const state = internalConst(owner);
    return lifecycleRawValid(&state.lifecycle) and
        (state.lifecycle == .live or state.lifecycle == .releasing) and
        state.self_addr == @intFromPtr(owner) and
        state.identity.receipt.owner_addr == @intFromPtr(owner) and
        state.identity.receipt.event_generation == generation and
        std.mem.eql(u8, &state.seal, &sealFor(state));
}

/// A settled local envelope is necessary, but never sufficient, for attachment teardown.
pub fn settledForAttachment(owner: *const EventOwner) bool {
    return pristineExact(owner) or terminalExact(owner);
}

fn terminalExact(owner: *const EventOwner) bool {
    const state = internalConst(owner);
    if (!lifecycleRawValid(&state.lifecycle) or state.lifecycle != .terminal or
        state.self_addr != @intFromPtr(owner) or state.wire_major != 0 or
        state.payload.len != 0 or state.identity.receipt.event_generation != 0 or
        !admissionRawValid(&state.admission_tag) or state.admission_tag != .unknown or
        !std.mem.eql(u8, &state.seal, &sealFor(state)))
        return false;
    return std.mem.allEqual(u8, owner.storage[@sizeOf(Internal)..], 0);
}

pub fn leaseAddress(owner: *EventOwner) usize {
    return @intFromPtr(&internal(owner).lease);
}

pub fn releaseProjection(
    owner: *EventOwner,
) EventError!client_slot.GenerationEventReleaseProjection {
    const state = internal(owner);
    const valid = lifecycleRawValid(&state.lifecycle) and state.lifecycle == .live and
        admissionRawValid(&state.admission_tag) and
        state.self_addr == @intFromPtr(owner) and
        state.identity.receipt.owner_addr == @intFromPtr(owner) and
        state.identity.receipt.event_generation != 0 and state.wire_major != 0 and
        state.payload.len != 0 and @intFromPtr(&state.lease) != 0 and
        std.mem.eql(u8, &state.seal, &sealFor(state));
    return .{
        .identity = state.identity,
        .owner_addr = @intFromPtr(owner),
        .self_addr = state.self_addr,
        .lease_projection = state.lease.scalarProjectionForValidation(state.identity.owner.pid),
        .payload_addr = @intFromPtr(state.payload.ptr),
        .payload_len = state.payload.len,
        .wire_major = state.wire_major,
        .admission_tag = if (admissionRawValid(&state.admission_tag))
            @as(*const u8, @ptrCast(&state.admission_tag)).*
        else
            std.math.maxInt(u8),
        .owner_seal = state.seal,
        .valid = valid,
    };
}

pub fn publishTerminal(owner: *EventOwner) void {
    owner.* = .{};
    const state = internal(owner);
    state.self_addr = @intFromPtr(owner);
    state.lifecycle = .terminal;
    state.seal = sealFor(state);
}

pub fn finalizeTerminal(owner: *EventOwner) void {
    const state = internal(owner);
    if (!lifecycleRawValid(&state.lifecycle) or state.lifecycle != .terminal or
        state.self_addr != @intFromPtr(owner) or !std.mem.eql(u8, &state.seal, &sealFor(state)))
        @panic("generation event owner terminal finalization drifted");
}

pub fn publishReleasing(owner: *EventOwner, expected_seal: owner_seal.Digest) void {
    const state = internal(owner);
    if (!lifecycleRawValid(&state.lifecycle) or state.lifecycle != .live or
        !std.mem.eql(u8, &state.seal, &expected_seal) or
        !std.mem.eql(u8, &state.seal, &sealFor(state)))
        @panic("generation event owner release publication drifted");
    state.lifecycle = .releasing;
    state.seal = sealFor(state);
}

pub fn finalizeRelease(owner: *EventOwner) void {
    // Canonical completion was consumed by client_slot before the allocator callback. The callback
    // may legally mutate public owner bytes, so the no-fail local suffix must not read them again.
    owner.* = .{};
}

pub fn publish(owner: *EventOwner, publication: client_slot.GenerationEventPublication) void {
    const state = internal(owner);
    state.* = .{
        .self_addr = @intFromPtr(owner),
        .identity = publication.identity,
        .wire_major = publication.header.major,
        .payload = publication.payload,
        .admission_tag = switch (publication.admission) {
            .accepted => .accepted,
            .unknown => .unknown,
            else => unreachable,
        },
        .lifecycle = .live,
    };
    state.seal = sealFor(state);
    const pin_owner: *connection_lease.PinOwner =
        @ptrFromInt(publication.pin_projection.pin_owner_addr);
    connection_lease.ConnectionLease.initFromReservedPinUnchecked(
        &state.lease,
        pin_owner,
        publication.pin_projection.stream_id,
        publication.pin_projection.pid,
    );
    state.seal = sealFor(state);
    @memset(owner.storage[@sizeOf(Internal)..], 0);
}

fn viewOwner(owner: *const EventOwner) EventViewError!EventView {
    const state = internalConst(owner);
    if (terminalExact(owner)) return error.Terminal;
    // Only scalar registry credentials are read before the registry confirms this exact address.
    const trusted = client_slot.generationEventTrustedView(
        state.identity,
        @intFromPtr(owner),
    ) catch |err|
        return switch (err) {
            error.InvalidOwner, error.Busy => error.InvalidOwner,
            error.Corrupt, error.Terminal => error.Terminal,
        };
    if (!lifecycleRawValid(&state.lifecycle) or !admissionRawValid(&state.admission_tag) or
        state.self_addr != @intFromPtr(owner) or state.lifecycle != .live or
        state.identity.receipt.owner_addr != @intFromPtr(owner) or
        state.identity.receipt.event_generation == 0 or state.wire_major == 0 or
        state.payload.len == 0 or
        !state.lease.canRelease(state.identity.owner.pid) or
        !std.mem.eql(u8, &state.seal, &sealFor(state)))
        return error.Terminal;
    const digest = runtime_event_wire.payloadDigest(state.payload);
    if (!std.mem.eql(u8, &digest, &trusted.payload_digest) or
        trusted.wire_major != state.wire_major or
        trusted.admission_tag != @intFromEnum(state.admission_tag))
        return error.Terminal;
    const admission: EventAdmission = switch (state.admission_tag) {
        // Admission identity was sealed at ingress; replay only reconstructs the allocation-free
        // structural DTO from the unchanged payload. Binding identity is independently registry-
        // validated above and must not be retroactively imposed on identity-free event variants.
        .accepted => switch (runtime_event_wire.preflightEvent(state.payload, .{})) {
            .accepted => |accepted| if (std.mem.eql(
                u8,
                &runtime_event_wire.eventPreflightProjectionDigest(accepted),
                &trusted.admission_projection_digest,
            ))
                .{ .accepted = accepted }
            else
                return error.Terminal,
            else => return error.Terminal,
        },
        .unknown => .unknown,
    };
    return .{
        .wire_major = state.wire_major,
        .payload = state.payload,
        .admission = admission,
    };
}

fn sealFor(state: *const Internal) owner_seal.Digest {
    var writer = owner_seal.Writer.init("generation-event-owner.v1");
    writer.writeUsize(state.self_addr);
    writer.writeU64(state.identity.receipt.registry_incarnation);
    writer.writeU64(state.identity.receipt.binding_reservation_id);
    writer.writeU64(state.identity.receipt.node_incarnation);
    writer.writeU64(state.identity.receipt.stream_id);
    writer.writeU64(state.identity.receipt.event_generation);
    writer.writeUsize(state.identity.receipt.owner_addr);
    writer.writeU16(state.wire_major);
    writer.writeUsize(@intFromPtr(state.payload.ptr));
    writer.writeUsize(state.payload.len);
    writer.writeU8(@as(*const u8, @ptrCast(&state.admission_tag)).*);
    writer.writeUsize(@intFromPtr(&state.lease));
    writer.writeU8(@as(*const u8, @ptrCast(&state.lifecycle)).*);
    return writer.finish();
}

pub fn discardForTest(owner: *EventOwner) client_slot.GenerationEventError!void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    try client_slot.discardGenerationEventForTest(state.identity, state.payload);
    owner.* = .{};
}

pub fn eventGenerationForTest(owner: *const EventOwner) u64 {
    if (!builtin.is_test) unreachable;
    return internalConst(owner).identity.receipt.event_generation;
}

pub fn corruptAdmissionTagForTest(owner: *EventOwner, raw: u8) void {
    if (!builtin.is_test) unreachable;
    @as(*u8, @ptrCast(&internal(owner).admission_tag)).* = raw;
}

pub fn corruptToPristineForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    owner.* = .{};
}

pub fn corruptLeaseForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const bytes = std.mem.asBytes(&internal(owner).lease);
    bytes[0] ^= 1;
}

pub fn corruptLeaseOwnerPointerCoherentlyForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.lease.owner_addr = 1;
    state.lease.canonical_owner_addr = 1;
    state.seal = sealFor(state);
}

pub fn corruptPayloadLengthForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    internal(owner).payload.len +%= 1;
}

pub fn corruptPayloadPointerCoherentlyForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.payload.ptr = @ptrFromInt(1);
    state.seal = sealFor(state);
}

pub fn corruptEventGenerationCoherentlyForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.identity.receipt.event_generation +%= 1;
    state.seal = sealFor(state);
}

pub fn corruptLifecycleForTest(owner: *EventOwner, raw: u8) void {
    if (!builtin.is_test) unreachable;
    @as(*u8, @ptrCast(&internal(owner).lifecycle)).* = raw;
}

pub fn corruptSealForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    internal(owner).seal[0] ^= 1;
}

pub fn corruptPayloadCoherentlyForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.payload[0] ^= 1;
    state.seal = sealFor(state);
}

pub fn corruptAdmissionProjectionForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.admission_tag = .unknown;
    state.seal = sealFor(state);
}

comptime {
    if (@sizeOf(EventOwner) != owner_storage_size)
        @compileError("EventOwner opaque envelope drifted from the 2c3d budget");
    if (@sizeOf(Internal) > owner_storage_size)
        @compileError("EventOwner opaque storage budget exhausted");
    if (max_inline_owner_bytes != 2 * 1024 * 1024)
        @compileError("EventOwner maximum inline product budget drifted");
    const outcome_fields = std.meta.fields(EventTakeOutcome);
    const expected_outcomes = [_][]const u8{ "idle", "ended_pending", "taken" };
    if (outcome_fields.len != expected_outcomes.len)
        @compileError("EventTakeOutcome tag set drifted from 2c3d C1 SSOT");
    for (outcome_fields, expected_outcomes) |actual, expected|
        if (!std.mem.eql(u8, actual.name, expected))
            @compileError("EventTakeOutcome tag order drifted from 2c3d C1 SSOT");
    const admission_fields = std.meta.fields(EventAdmission);
    const expected_admissions = [_][]const u8{ "accepted", "unknown" };
    if (admission_fields.len != expected_admissions.len)
        @compileError("EventAdmission tag set drifted from 2c3d C1 SSOT");
    for (admission_fields, expected_admissions) |actual, expected|
        if (!std.mem.eql(u8, actual.name, expected))
            @compileError("EventAdmission tag order drifted from 2c3d C1 SSOT");
    const view_fields = std.meta.fields(EventView);
    const expected_view = [_][]const u8{ "wire_major", "payload", "admission" };
    if (view_fields.len != expected_view.len)
        @compileError("EventView field set drifted from 2c3d C1 SSOT");
    for (view_fields, expected_view) |actual, expected|
        if (!std.mem.eql(u8, actual.name, expected))
            @compileError("EventView field order drifted from 2c3d C1 SSOT");
}

test "CR3a-2c3d C1 event owner pristine storage is byte canonical" {
    var owner: EventOwner = .{};
    try std.testing.expect(pristineExact(&owner));
    for (&owner.storage) |*byte| {
        byte.* = 1;
        try std.testing.expect(!pristineExact(&owner));
        byte.* = 0;
    }
}

test "CR3a-2c3d C1 event admission raw tags are closed before union interpretation" {
    var admission: AdmissionTag = .unknown;
    const raw: *u8 = @ptrCast(&admission);
    var value: u16 = 0;
    while (value <= std.math.maxInt(u8)) : (value += 1) {
        raw.* = @intCast(value);
        try std.testing.expectEqual(value <= 1, admissionRawValid(&admission));
    }
}
