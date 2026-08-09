const std = @import("std");
const builtin = @import("builtin");
const client_slot = @import("client_slot.zig");
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
    admission_projection_digest: runtime_event_wire.Digest = [_]u8{0} ** 32,
    payload_digest: runtime_event_wire.Digest = [_]u8{0} ** 32,
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
        .payload_digest = runtime_event_wire.payloadDigest(publication.payload),
        .admission_projection_digest = switch (publication.admission) {
            .accepted => |accepted| runtime_event_wire.eventPreflightProjectionDigest(accepted),
            .unknown => [_]u8{0} ** 32,
            else => unreachable,
        },
        .lifecycle = .live,
    };
    state.seal = sealFor(state);
    @memset(owner.storage[@sizeOf(Internal)..], 0);
}

fn viewOwner(owner: *const EventOwner) EventViewError!EventView {
    const state = internalConst(owner);
    // Only scalar registry credentials are read before the registry confirms this exact address.
    client_slot.generationEventOwnerCurrent(state.identity, @intFromPtr(owner)) catch |err|
        return switch (err) {
            error.InvalidOwner, error.Busy => error.InvalidOwner,
            error.Corrupt, error.Terminal => error.Terminal,
        };
    if (!lifecycleRawValid(&state.lifecycle) or !admissionRawValid(&state.admission_tag) or
        state.self_addr != @intFromPtr(owner) or state.lifecycle != .live or
        state.identity.receipt.owner_addr != @intFromPtr(owner) or
        state.identity.receipt.event_generation == 0 or state.wire_major == 0 or
        state.payload.len == 0 or !std.mem.eql(u8, &state.seal, &sealFor(state)))
        return error.Terminal;
    const digest = runtime_event_wire.payloadDigest(state.payload);
    if (!std.mem.eql(u8, &digest, &state.payload_digest)) return error.Terminal;
    const admission: EventAdmission = switch (state.admission_tag) {
        // Admission identity was sealed at ingress; replay only reconstructs the allocation-free
        // structural DTO from the unchanged payload. Binding identity is independently registry-
        // validated above and must not be retroactively imposed on identity-free event variants.
        .accepted => switch (runtime_event_wire.preflightEvent(state.payload, .{})) {
            .accepted => |accepted| if (std.mem.eql(
                u8,
                &runtime_event_wire.eventPreflightProjectionDigest(accepted),
                &state.admission_projection_digest,
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
    writer.writeBytes(&state.payload_digest);
    writer.writeU8(@as(*const u8, @ptrCast(&state.admission_tag)).*);
    writer.writeBytes(&state.admission_projection_digest);
    writer.writeU8(@as(*const u8, @ptrCast(&state.lifecycle)).*);
    return writer.finish();
}

pub fn publicationForTest(owner: *const EventOwner) client_slot.GenerationEventPublication {
    if (!builtin.is_test) unreachable;
    const state = internalConst(owner);
    return .{
        .identity = state.identity,
        .header = .{ .kind = .event, .major = state.wire_major },
        .payload = state.payload,
        .admission = switch (state.admission_tag) {
            .accepted => runtime_event_wire.preflightEvent(state.payload, .{}),
            .unknown => .unknown,
        },
    };
}

pub fn corruptAdmissionTagForTest(owner: *EventOwner, raw: u8) void {
    if (!builtin.is_test) unreachable;
    @as(*u8, @ptrCast(&internal(owner).admission_tag)).* = raw;
}

pub fn corruptAdmissionProjectionForTest(owner: *EventOwner) void {
    if (!builtin.is_test) unreachable;
    const state = internal(owner);
    state.admission_projection_digest[0] ^= 1;
    // Preserve the outer owner seal so the test reaches the independent replay-projection check.
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
