//! Node-local CR3a-2a stream-drop reservation substrate.
//!
//! This module owns only bounded metadata. It never imports or calls Client, GUI, socket, payload,
//! allocator, cleanup-permit, or callback code. A higher owner reserves an empty drop entry before
//! attach, binds the returned stream without allocation, and may destroy the registry only after
//! every entry has been settled by a later cleanup owner.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");

pub const max_entries: usize = 4096;

const RegistryLifecycle = enum(u8) {
    pristine,
    live,
    dead,
};

const EntryLifecycle = enum(u8) {
    empty,
    reserved,
    bound,
    drop_active,
};

const ControllerAuthority = enum(u8) {
    unavailable,
    live,
    revoke_pending,
    revoked,
};

fn registryLifecycleRawValid(value: *const RegistryLifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(RegistryLifecycle.dead);
}

fn entryLifecycleRawValid(value: *const EntryLifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(EntryLifecycle.drop_active);
}

fn controllerAuthorityRawValid(value: *const ControllerAuthority) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(ControllerAuthority.revoked);
}

/// Binding identity fields known before this registry mints its monotonic reservation ID.
/// `reserve` materializes the canonical contract identity and returns it to the caller.
pub const ReserveIdentity = struct {
    binding_incarnation: u64,
    binding_storage_addr: usize,
    destination_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    runtime_id: u128,
    role: contract.AttachmentRole,
    pid: u32,
    process_nonce: u64,

    fn materialize(self: ReserveIdentity, reservation_id: u64) ?contract.BindingIdentity {
        return contract.BindingIdentity.init(.{
            .binding_incarnation = self.binding_incarnation,
            .binding_storage_addr = self.binding_storage_addr,
            .destination_addr = self.destination_addr,
            .binding_reservation_id = reservation_id,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .connection_generation = self.connection_generation,
            .runtime_id = self.runtime_id,
            .role = self.role,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        });
    }
};

pub const Reservation = struct {
    registry_incarnation: u64,
    reservation_id: u64,
    entry_index: u16,

    pub fn valid(self: Reservation) bool {
        return self.registry_incarnation != 0 and
            self.reservation_id != 0 and
            self.entry_index < max_entries;
    }
};

pub const Reserved = struct {
    reservation: Reservation,
    identity: contract.BindingIdentity,
};

const Entry = struct {
    lifecycle: EntryLifecycle = .empty,
    reservation_id: u64 = 0,
    identity: ?contract.BindingIdentity = null,
    stream_id: u64 = 0,
    controller_authority: ControllerAuthority = .unavailable,
    transport_owner: contract.TransportOwnerSeal = .{},
    response_owner: contract.ExecutedResponseOwnerSeal = .{},

    fn clear(self: *Entry) void {
        self.* = .{};
    }
};

pub const Error = error{
    CapacityExhausted,
    IdentityExhausted,
    InvalidIdentity,
    InvalidReservation,
    InvalidState,
    InvalidStream,
    MovedOrCopied,
};

pub const DeinitOutcome = enum {
    cleaned,
    busy,
    already_dead,
    corrupt,
};

pub const AttachmentCleanupRegistry = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    next_reservation_id: u64 = 1,
    live_count: usize = 0,
    lifecycle: RegistryLifecycle = .pristine,
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    pub fn initInPlace(out: *AttachmentCleanupRegistry, incarnation: u64) Error!void {
        if (incarnation == 0) return error.InvalidIdentity;
        if (!registryLifecycleRawValid(&out.lifecycle)) return error.InvalidState;
        switch (out.lifecycle) {
            .pristine => {
                if (out.self_addr != 0 or out.incarnation != 0 or out.live_count != 0)
                    return error.InvalidState;
            },
            .dead => {
                if (out.self_addr != @intFromPtr(out) or out.live_count != 0)
                    return error.InvalidState;
                if (out.incarnation == incarnation) return error.InvalidIdentity;
            },
            .live => return error.InvalidState,
        }
        out.* = .{
            .self_addr = @intFromPtr(out),
            .incarnation = incarnation,
            .lifecycle = .live,
        };
    }

    fn valid(self: *const AttachmentCleanupRegistry) bool {
        return registryLifecycleRawValid(&self.lifecycle) and
            self.self_addr == @intFromPtr(self) and
            self.incarnation != 0 and
            self.next_reservation_id != 0 and
            self.live_count <= max_entries and
            self.lifecycle == .live;
    }

    pub fn count(self: *const AttachmentCleanupRegistry) Error!usize {
        if (!self.valid()) return error.MovedOrCopied;
        return self.live_count;
    }

    pub fn reserve(
        self: *AttachmentCleanupRegistry,
        seed: ReserveIdentity,
    ) Error!Reserved {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.live_count == max_entries) return error.CapacityExhausted;

        const index = for (&self.entries, 0..) |*entry, index| {
            if (!entryLifecycleRawValid(&entry.lifecycle)) return error.InvalidState;
            if (entry.lifecycle == .empty) break index;
        } else return error.InvalidState;

        const reservation_id = self.next_reservation_id;
        if (reservation_id == 0 or reservation_id == std.math.maxInt(u64))
            return error.IdentityExhausted;
        const identity = seed.materialize(reservation_id) orelse
            return error.InvalidIdentity;

        // Every failure point is above. Publication and counter advance are one no-fail suffix.
        self.next_reservation_id = reservation_id + 1;
        self.entries[index] = .{
            .lifecycle = .reserved,
            .reservation_id = reservation_id,
            .identity = identity,
        };
        self.live_count += 1;
        return .{
            .reservation = .{
                .registry_incarnation = self.incarnation,
                .reservation_id = reservation_id,
                .entry_index = @intCast(index),
            },
            .identity = identity,
        };
    }

    fn exactEntry(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!*Entry {
        if (!self.valid()) return error.MovedOrCopied;
        if (!reservation.valid() or
            reservation.registry_incarnation != self.incarnation or
            reservation.entry_index >= max_entries)
            return error.InvalidReservation;
        const entry = &self.entries[reservation.entry_index];
        if (!entryLifecycleRawValid(&entry.lifecycle)) return error.InvalidState;
        if (entry.lifecycle == .empty or
            entry.reservation_id != reservation.reservation_id)
            return error.InvalidReservation;
        const canonical = entry.identity orelse return error.InvalidState;
        if (!canonical.matches(identity)) return error.InvalidIdentity;
        return entry;
    }

    pub fn transportOwnerSeal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!*contract.TransportOwnerSeal {
        return &(try self.exactEntry(reservation, identity)).transport_owner;
    }

    pub fn responseOwnerSeal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!*contract.ExecutedResponseOwnerSeal {
        return &(try self.exactEntry(reservation, identity)).response_owner;
    }

    pub fn abort(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        if (entry.lifecycle != .reserved or entry.stream_id != 0)
            return error.InvalidState;
        // Clearing the canonical entry while either child authority is live would make a stale
        // parent appear harmless while leaving the actual transport/response owner unretired.
        if (!childAuthoritiesSettled(entry))
            return error.InvalidState;
        if (self.live_count == 0) return error.InvalidState;
        entry.clear();
        self.live_count -= 1;
    }

    /// Binds the host-provided stream to the already-reserved drop entry. This function allocates
    /// nothing. Validation precedes the mutation, so the successful suffix cannot fail.
    pub fn bindStream(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        if (stream_id == 0) return error.InvalidStream;
        const entry = try self.exactEntry(reservation, identity);
        if (entry.lifecycle != .reserved or entry.stream_id != 0)
            return error.InvalidState;
        entry.stream_id = stream_id;
        entry.controller_authority = if (identity.role == .controller) .live else .unavailable;
        entry.lifecycle = .bound;
    }

    pub fn controllerAuthorityLive(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!bool {
        const entry = try self.exactEntry(reservation, identity);
        if (!controllerAuthorityRawValid(&entry.controller_authority))
            return error.InvalidState;
        if (entry.lifecycle != .bound or entry.stream_id != stream_id)
            return error.InvalidState;
        return entry.controller_authority == .live;
    }

    pub fn controllerRevokePending(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!bool {
        const entry = try self.exactEntry(reservation, identity);
        if (!controllerAuthorityRawValid(&entry.controller_authority) or
            entry.lifecycle != .bound or entry.stream_id != stream_id)
            return error.InvalidState;
        return entry.controller_authority == .revoke_pending;
    }

    pub fn beginControllerRevoke(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        if (!controllerAuthorityRawValid(&entry.controller_authority) or
            entry.lifecycle != .bound or entry.stream_id != stream_id or
            identity.role != .controller or entry.controller_authority != .live)
            return error.InvalidState;
        entry.controller_authority = .revoke_pending;
    }

    pub fn finishControllerRevoke(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        if (!controllerAuthorityRawValid(&entry.controller_authority) or
            entry.lifecycle != .bound or entry.stream_id != stream_id or
            identity.role != .controller or entry.controller_authority != .revoke_pending)
            return error.InvalidState;
        entry.controller_authority = .revoked;
    }

    pub fn preflightBoundDrop(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        if (stream_id == 0) return error.InvalidStream;
        const entry = try self.exactEntry(reservation, identity);
        if (entry.lifecycle != .bound or entry.stream_id != stream_id or
            self.live_count == 0 or !dropAuthorityCanBegin(entry))
            return error.InvalidState;
    }

    pub fn beginBoundDrop(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        try self.preflightBoundDrop(reservation, identity, stream_id);
        const entry = try self.exactEntry(reservation, identity);
        // Drop admission atomically consumes the last mutation authority. The remaining
        // transport/payload destruction is therefore a release-only, no-fail suffix.
        if (entry.controller_authority == .live) entry.controller_authority = .revoked;
        entry.lifecycle = .drop_active;
    }

    pub fn completeActiveDrop(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
    ) Error!void {
        if (stream_id == 0) return error.InvalidStream;
        const entry = try self.exactEntry(reservation, identity);
        // Pristine means this neutral registry entry never minted that optional authority;
        // terminal means it was minted and explicitly fenced. Only live is forbidden to erase.
        if (entry.lifecycle != .drop_active or entry.stream_id != stream_id or
            !dropAuthoritySettled(entry) or !childAuthoritiesSettled(entry) or
            self.live_count == 0)
            return error.InvalidState;
        entry.clear();
        self.live_count -= 1;
    }

    pub fn preflightDeinit(self: *const AttachmentCleanupRegistry) DeinitOutcome {
        if (!registryLifecycleRawValid(&self.lifecycle)) return .corrupt;
        if (self.lifecycle == .dead) {
            return if (self.self_addr == @intFromPtr(self)) .already_dead else .corrupt;
        }
        if (!self.valid()) return .corrupt;
        if (self.live_count != 0) return .busy;
        for (self.entries) |entry| {
            if (!entryLifecycleRawValid(&entry.lifecycle) or
                !controllerAuthorityRawValid(&entry.controller_authority) or
                entry.lifecycle != .empty or entry.reservation_id != 0 or
                entry.identity != null or entry.stream_id != 0 or
                entry.controller_authority != .unavailable or
                entry.transport_owner.lifecycle != .pristine or
                entry.response_owner.lifecycle != .pristine)
                return .corrupt;
        }
        return .cleaned;
    }

    pub fn tryDeinit(self: *AttachmentCleanupRegistry) DeinitOutcome {
        const outcome = self.preflightDeinit();
        if (outcome == .cleaned) self.lifecycle = .dead;
        return outcome;
    }
};

fn childAuthoritiesSettled(entry: *const Entry) bool {
    return entry.transport_owner.settledExact() and entry.response_owner.settledExact();
}

fn dropAuthorityCanBegin(entry: *const Entry) bool {
    if (!controllerAuthorityRawValid(&entry.controller_authority)) return false;
    const identity = entry.identity orelse return false;
    if (!contract.attachmentRoleRawValid(&identity.role)) return false;
    return switch (identity.role) {
        .controller => entry.controller_authority == .live or
            entry.controller_authority == .revoked,
        .observer => entry.controller_authority == .unavailable,
    };
}

fn dropAuthoritySettled(entry: *const Entry) bool {
    if (!controllerAuthorityRawValid(&entry.controller_authority)) return false;
    const identity = entry.identity orelse return false;
    if (!contract.attachmentRoleRawValid(&identity.role)) return false;
    return switch (identity.role) {
        .controller => entry.controller_authority == .revoked,
        .observer => entry.controller_authority == .unavailable,
    };
}

fn fixtureSeed(destination_addr: usize, binding_incarnation: u64) ReserveIdentity {
    return .{
        .binding_incarnation = binding_incarnation,
        .binding_storage_addr = destination_addr + 1,
        .destination_addr = destination_addr,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    };
}

test "stream-drop registry reserves, aborts, binds, and gates final-zero deinit" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 3);
    const first = try registry.reserve(fixtureSeed(0x1000, 21));
    try std.testing.expectEqual(@as(usize, 1), try registry.count());
    try registry.abort(first.reservation, first.identity);
    try std.testing.expectEqual(@as(usize, 0), try registry.count());

    const guarded = try registry.reserve(fixtureSeed(0x1800, 22));
    const transport_seal = try registry.transportOwnerSeal(guarded.reservation, guarded.identity);
    try contract.TransportOwnerSeal.initInPlace(transport_seal, 27);
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(guarded.reservation, guarded.identity),
    );
    try transport_seal.terminalize(27);
    try registry.abort(guarded.reservation, guarded.identity);

    const corrupt = try registry.reserve(fixtureSeed(0x1900, 24));
    const corrupt_seal = try registry.transportOwnerSeal(corrupt.reservation, corrupt.identity);
    corrupt_seal.lifecycle = .terminal;
    try std.testing.expectError(error.InvalidState, registry.abort(corrupt.reservation, corrupt.identity));
    corrupt_seal.* = .{};
    try registry.abort(corrupt.reservation, corrupt.identity);

    const second = try registry.reserve(fixtureSeed(0x2000, 23));
    try std.testing.expect(second.reservation.reservation_id > first.reservation.reservation_id);
    try registry.bindStream(second.reservation, second.identity, 29);
    try std.testing.expectEqual(DeinitOutcome.busy, registry.tryDeinit());
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightBoundDrop(second.reservation, second.identity, 30),
    );
    const response_seal = try registry.responseOwnerSeal(second.reservation, second.identity);
    try contract.ExecutedResponseOwnerSeal.initInPlace(response_seal, 31);
    try std.testing.expectError(
        error.InvalidState,
        registry.completeActiveDrop(second.reservation, second.identity, 29),
    );
    try registry.beginBoundDrop(second.reservation, second.identity, 29);
    try std.testing.expectError(
        error.InvalidState,
        registry.completeActiveDrop(second.reservation, second.identity, 29),
    );
    try response_seal.terminalize(31);
    try registry.completeActiveDrop(second.reservation, second.identity, 29);
    try std.testing.expectError(
        error.InvalidReservation,
        registry.completeActiveDrop(second.reservation, second.identity, 29),
    );
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3a controller revoke authority is canonical absorbing and raw-tag guarded" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3A);
    const reserved = try registry.reserve(fixtureSeed(0x2C3B, 0x2C3C));
    try registry.bindStream(reserved.reservation, reserved.identity, 41);
    try std.testing.expect(try registry.controllerAuthorityLive(
        reserved.reservation,
        reserved.identity,
        41,
    ));
    try registry.beginControllerRevoke(reserved.reservation, reserved.identity, 41);
    try std.testing.expect(!(try registry.controllerAuthorityLive(
        reserved.reservation,
        reserved.identity,
        41,
    )));
    try std.testing.expect(try registry.controllerRevokePending(
        reserved.reservation,
        reserved.identity,
        41,
    ));
    const entry = &registry.entries[reserved.reservation.entry_index];
    const authority_raw: *u8 = @ptrCast(&entry.controller_authority);
    authority_raw.* = @intFromEnum(ControllerAuthority.revoked) + 1;
    try std.testing.expectError(
        error.InvalidState,
        registry.controllerRevokePending(reserved.reservation, reserved.identity, 41),
    );
    authority_raw.* = @intFromEnum(ControllerAuthority.revoke_pending);
    try registry.finishControllerRevoke(reserved.reservation, reserved.identity, 41);
    try std.testing.expect(!(try registry.controllerAuthorityLive(
        reserved.reservation,
        reserved.identity,
        41,
    )));
    try std.testing.expectError(
        error.InvalidState,
        registry.beginControllerRevoke(reserved.reservation, reserved.identity, 41),
    );
    try registry.beginBoundDrop(reserved.reservation, reserved.identity, 41);
    try registry.completeActiveDrop(reserved.reservation, reserved.identity, 41);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3a authority entrypoints reject every invalid enclosing raw lifecycle" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D);
    const reserved = try registry.reserve(fixtureSeed(0x2C3E, 0x2C3F));
    try registry.bindStream(reserved.reservation, reserved.identity, 43);

    const registry_raw: *u8 = @ptrCast(&registry.lifecycle);
    var raw: u16 = @intFromEnum(RegistryLifecycle.dead) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        registry_raw.* = @intCast(raw);
        try std.testing.expectError(error.MovedOrCopied, registry.controllerAuthorityLive(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.MovedOrCopied, registry.controllerRevokePending(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.MovedOrCopied, registry.beginControllerRevoke(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.MovedOrCopied, registry.finishControllerRevoke(
            reserved.reservation,
            reserved.identity,
            43,
        ));
    }
    registry_raw.* = @intFromEnum(RegistryLifecycle.live);

    const entry = &registry.entries[reserved.reservation.entry_index];
    const entry_raw: *u8 = @ptrCast(&entry.lifecycle);
    raw = @intFromEnum(EntryLifecycle.drop_active) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        entry_raw.* = @intCast(raw);
        try std.testing.expectError(error.InvalidState, registry.controllerAuthorityLive(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.InvalidState, registry.controllerRevokePending(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.InvalidState, registry.beginControllerRevoke(
            reserved.reservation,
            reserved.identity,
            43,
        ));
        try std.testing.expectError(error.InvalidState, registry.finishControllerRevoke(
            reserved.reservation,
            reserved.identity,
            43,
        ));
    }
    entry_raw.* = @intFromEnum(EntryLifecycle.bound);
    try registry.beginControllerRevoke(reserved.reservation, reserved.identity, 43);
    try registry.finishControllerRevoke(reserved.reservation, reserved.identity, 43);
    try registry.beginBoundDrop(reserved.reservation, reserved.identity, 43);
    try registry.completeActiveDrop(reserved.reservation, reserved.identity, 43);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3a reserve rejects every invalid raw role before publication" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3F);
    var seed = fixtureSeed(0x2C40, 0x2C41);
    const role_raw: *u8 = @ptrCast(&seed.role);
    var raw: u16 = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expectError(error.InvalidIdentity, registry.reserve(seed));
        try std.testing.expectEqual(@as(usize, 0), try registry.count());
    }
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3a bound drop atomically consumes canonical controller authority" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C40);

    const live = try registry.reserve(fixtureSeed(0x2C41, 0x2C42));
    try registry.bindStream(live.reservation, live.identity, 47);
    try registry.beginBoundDrop(live.reservation, live.identity, 47);
    const live_entry = &registry.entries[live.reservation.entry_index];
    try std.testing.expectEqual(EntryLifecycle.drop_active, live_entry.lifecycle);
    try std.testing.expectEqual(ControllerAuthority.revoked, live_entry.controller_authority);
    // Even a corrupted caller cannot erase a live or pending mutation authority.
    live_entry.controller_authority = .live;
    try std.testing.expectError(
        error.InvalidState,
        registry.completeActiveDrop(live.reservation, live.identity, 47),
    );
    live_entry.controller_authority = .revoke_pending;
    try std.testing.expectError(
        error.InvalidState,
        registry.completeActiveDrop(live.reservation, live.identity, 47),
    );
    live_entry.controller_authority = .revoked;
    try registry.completeActiveDrop(live.reservation, live.identity, 47);

    var observer_seed = fixtureSeed(0x2C43, 0x2C44);
    observer_seed.role = .observer;
    const observer = try registry.reserve(observer_seed);
    try registry.bindStream(observer.reservation, observer.identity, 49);
    try registry.beginBoundDrop(observer.reservation, observer.identity, 49);
    const observer_entry = &registry.entries[observer.reservation.entry_index];
    try std.testing.expectEqual(ControllerAuthority.unavailable, observer_entry.controller_authority);
    try registry.completeActiveDrop(observer.reservation, observer.identity, 49);

    const pending = try registry.reserve(fixtureSeed(0x2C45, 0x2C46));
    try registry.bindStream(pending.reservation, pending.identity, 51);
    try registry.beginControllerRevoke(pending.reservation, pending.identity, 51);
    try std.testing.expectError(
        error.InvalidState,
        registry.beginBoundDrop(pending.reservation, pending.identity, 51),
    );
    const pending_entry = &registry.entries[pending.reservation.entry_index];
    try std.testing.expectEqual(EntryLifecycle.bound, pending_entry.lifecycle);
    try std.testing.expectEqual(ControllerAuthority.revoke_pending, pending_entry.controller_authority);
    try registry.finishControllerRevoke(pending.reservation, pending.identity, 51);
    try registry.beginBoundDrop(pending.reservation, pending.identity, 51);
    try registry.completeActiveDrop(pending.reservation, pending.identity, 51);

    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "stream-drop registry rejects copied registry, duplicate use, splice, and slot ABA" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 31);
    const first = try registry.reserve(fixtureSeed(0x3000, 37));

    var copied = registry;
    try std.testing.expectError(error.MovedOrCopied, copied.abort(first.reservation, first.identity));
    try std.testing.expectEqual(@as(usize, 1), try registry.count());

    var foreign = first.identity;
    foreign.runtime_id += 1;
    try std.testing.expectError(error.InvalidIdentity, registry.abort(first.reservation, foreign));
    try std.testing.expectEqual(@as(usize, 1), try registry.count());

    const copied_reservation = first.reservation;
    try registry.abort(first.reservation, first.identity);
    try std.testing.expectError(error.InvalidReservation, registry.abort(copied_reservation, first.identity));

    const second = try registry.reserve(fixtureSeed(0x4000, 41));
    try std.testing.expectEqual(first.reservation.entry_index, second.reservation.entry_index);
    try std.testing.expect(second.reservation.reservation_id > first.reservation.reservation_id);
    try std.testing.expectError(error.InvalidReservation, registry.bindStream(copied_reservation, first.identity, 43));
    try registry.abort(second.reservation, second.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
    try std.testing.expectEqual(DeinitOutcome.already_dead, registry.tryDeinit());
}

test "stream-drop registry enforces exact cap and cap plus one without mutation" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 47);
    var reserved: [max_entries]Reserved = undefined;
    for (&reserved, 0..) |*item, index| {
        item.* = try registry.reserve(fixtureSeed(0x5000 + index, 101 + index));
    }
    try std.testing.expectEqual(max_entries, try registry.count());
    try std.testing.expectError(
        error.CapacityExhausted,
        registry.reserve(fixtureSeed(0x9000, 9001)),
    );
    try std.testing.expectEqual(max_entries, try registry.count());
    for (reserved) |item| try registry.abort(item.reservation, item.identity);
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "stream-drop registry burns identities and rejects same-address reincarnation ABA" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 53);
    const stale = try registry.reserve(fixtureSeed(0xA000, 59));
    try registry.abort(stale.reservation, stale.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
    try std.testing.expectError(error.InvalidIdentity, AttachmentCleanupRegistry.initInPlace(&registry, 53));
    try AttachmentCleanupRegistry.initInPlace(&registry, 61);
    const current = try registry.reserve(fixtureSeed(0xB000, 67));
    try std.testing.expectError(error.InvalidReservation, registry.abort(stale.reservation, stale.identity));
    try registry.abort(current.reservation, current.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "stream-drop registry rejects reservation identity exhaustion without mutation" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 71);
    registry.next_reservation_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, registry.reserve(fixtureSeed(0xC000, 73)));
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
    // Exhaustion is sticky because zero/reuse must never follow the maximum identity.
    try std.testing.expectError(error.IdentityExhausted, registry.reserve(fixtureSeed(0xC001, 79)));
}
