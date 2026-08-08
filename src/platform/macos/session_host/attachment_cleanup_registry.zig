//! Node-local CR3a-2a stream-drop reservation substrate.
//!
//! This module owns only bounded metadata. It never imports or calls Client, GUI, socket, payload,
//! allocator, cleanup-permit, or callback code. A higher owner reserves an empty drop entry before
//! attach, binds the returned stream without allocation, and may destroy the registry only after
//! every entry has been settled by a later cleanup owner.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");
const prepared_request_authority = @import("prepared_request_authority.zig");
const rpc_response_authority = @import("rpc_response_authority.zig");

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
    stream_id: u64 = 0,
    controller_authority: ControllerAuthority = .unavailable,
    transport_owner: contract.TransportOwnerSeal = .{},
    response_owner: contract.ExecutedResponseOwnerSeal = .{},
    prepared_request: prepared_request_authority.Authority = .{},
    rpc_response_authority: rpc_response_authority.Authority = .{},

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
        };
        self.entries[index].rpc_response_authority.initInPlace(self.incarnation, identity) catch unreachable;
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
        const canonical = currentEntryBinding(entry, self.incarnation) orelse
            return error.InvalidState;
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

    pub fn publishPreparedRequest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        entry.prepared_request.publish(prepared) catch return error.InvalidState;
    }

    pub fn preparedRequestMatches(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
    ) Error!bool {
        return (try self.exactEntry(reservation, identity)).prepared_request.matches(prepared);
    }

    pub fn executingRequestMatches(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
    ) Error!bool {
        return (try self.exactEntry(reservation, identity)).prepared_request
            .matchesExecuting(prepared);
    }

    pub fn executingRequestForReceipt(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
    ) Error!?prepared_request_authority.Prepared {
        return self.requestForReceipt(
            reservation,
            identity,
            transport_addr,
            transport_incarnation,
            receipt,
            .executing,
        );
    }

    pub fn preparedRequestForReceipt(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
    ) Error!?prepared_request_authority.Prepared {
        return self.requestForReceipt(
            reservation,
            identity,
            transport_addr,
            transport_incarnation,
            receipt,
            .prepared,
        );
    }

    fn requestForReceipt(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        expected_lifecycle: prepared_request_authority.Lifecycle,
    ) Error!?prepared_request_authority.Prepared {
        const authority = &(try self.exactEntry(reservation, identity)).prepared_request;
        if (!authority.rawLifecycleValid() or authority.lifecycle != expected_lifecycle or
            authority.prepared_present != 1)
            return null;
        const prepared = authority.prepared;
        if (prepared.transport_addr != transport_addr or
            prepared.transport_incarnation != transport_incarnation or
            !prepared.receipt.matches(receipt) or switch (expected_lifecycle) {
            .prepared => !authority.matches(prepared),
            .executing => !authority.matchesExecuting(prepared),
            .idle, .terminal => true,
        })
            return null;
        return prepared;
    }

    pub fn beginPreparedRequestExecute(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        entry.prepared_request.beginExecute(prepared) catch return error.InvalidState;
    }

    pub fn settlePreparedRequest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
        terminal: bool,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        if (terminal)
            entry.prepared_request.settleTerminal(prepared) catch return error.InvalidState
        else
            entry.prepared_request.settleReusable(prepared) catch return error.InvalidState;
    }

    pub fn requestAuthorized(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        family: contract.RequestFamily,
        tag: contract.RuntimeRequestTag,
        bound_stream_id: u64,
    ) Error!bool {
        const entry = try self.exactEntry(reservation, identity);
        if (!contract.requestFamilyRawValid(&family) or
            !contract.runtimeRequestTagRawValid(&tag) or
            !contract.requestFamilyAllowed(tag, family) or
            !controllerAuthorityRawValid(&entry.controller_authority))
            return error.InvalidState;
        return switch (family) {
            .connection_only_denied => false,
            .attach_only => tag == .attach_controller and entry.lifecycle == .reserved and
                entry.stream_id == 0 and bound_stream_id == 0 and identity.role == .controller,
            .bound_observation => entry.lifecycle == .bound and entry.stream_id != 0 and
                entry.stream_id == bound_stream_id,
            .bound_controller_mutation => entry.lifecycle == .bound and entry.stream_id != 0 and
                entry.stream_id == bound_stream_id and identity.role == .controller and
                entry.controller_authority == .live,
            .bound_terminal => entry.lifecycle == .bound and entry.stream_id != 0 and
                entry.stream_id == bound_stream_id and
                (tag == .detach or (tag == .terminate and identity.role == .controller and
                    entry.controller_authority == .live)),
        };
    }

    pub fn preparedRequestSettlementReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!prepared_request_authority.SettlementReadiness {
        const entry = try self.exactEntry(reservation, identity);
        return entry.prepared_request.settlementReadiness();
    }

    pub fn transportTerminalizeReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        require_drop_active: bool,
    ) Error!prepared_request_authority.SettlementReadiness {
        const entry = try self.exactEntry(reservation, identity);
        if (require_drop_active and entry.lifecycle != .drop_active) return .invalid;
        return entry.prepared_request.settlementReadiness();
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
        if (!childAuthoritiesSettled(entry, self.incarnation))
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
            self.live_count == 0 or !dropAuthorityCanBegin(entry, self.incarnation))
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
            !dropAuthoritySettled(entry, self.incarnation) or
            !childAuthoritiesSettled(entry, self.incarnation) or
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
                entry.stream_id != 0 or entry.controller_authority != .unavailable or
                entry.transport_owner.lifecycle != .pristine or
                entry.response_owner.lifecycle != .pristine or
                !entry.rpc_response_authority.pristineExact())
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

fn childAuthoritiesSettled(entry: *const Entry, registry_incarnation: u64) bool {
    const identity = currentEntryBinding(entry, registry_incarnation) orelse return false;
    return entry.transport_owner.settledExact() and entry.response_owner.settledExact() and
        entry.prepared_request.settledExact() and
        entry.rpc_response_authority.settledExactFor(registry_incarnation, identity);
}

fn dropAuthorityCanBegin(entry: *const Entry, registry_incarnation: u64) bool {
    if (!controllerAuthorityRawValid(&entry.controller_authority)) return false;
    const identity = currentEntryBinding(entry, registry_incarnation) orelse return false;
    if (!contract.attachmentRoleRawValid(&identity.role)) return false;
    return switch (identity.role) {
        .controller => entry.controller_authority == .live or
            entry.controller_authority == .revoked,
        .observer => entry.controller_authority == .unavailable,
    };
}

fn dropAuthoritySettled(entry: *const Entry, registry_incarnation: u64) bool {
    if (!controllerAuthorityRawValid(&entry.controller_authority)) return false;
    const identity = currentEntryBinding(entry, registry_incarnation) orelse return false;
    if (!contract.attachmentRoleRawValid(&identity.role)) return false;
    return switch (identity.role) {
        .controller => entry.controller_authority == .revoked,
        .observer => entry.controller_authority == .unavailable,
    };
}

fn currentEntryBinding(
    entry: *const Entry,
    registry_incarnation: u64,
) ?contract.BindingIdentity {
    if (registry_incarnation == 0 or entry.reservation_id == 0) return null;
    const identity = entry.rpc_response_authority.bindingExactForRegistry(
        registry_incarnation,
    ) orelse return null;
    return if (identity.binding_reservation_id == entry.reservation_id) identity else null;
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
    try contract.TransportOwnerSeal.initInPlace(transport_seal, 27, 33, 35, 29, 31);
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
    try contract.ExecutedResponseOwnerSeal.initInPlace(response_seal, 31, 33, 35);
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

test "B3-1 registry owns final-address RPC authority init settle and zero clear" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB301);
    const first = try registry.reserve(fixtureSeed(0xB302, 0xB303));
    const first_entry = &registry.entries[first.reservation.entry_index];
    try std.testing.expectEqual(
        @intFromPtr(&first_entry.rpc_response_authority),
        first_entry.rpc_response_authority.self_addr,
    );
    try std.testing.expect(first_entry.rpc_response_authority.binding.matches(first.identity));
    try std.testing.expectEqual(
        rpc_response_authority.SettlementReadiness.settled,
        first_entry.rpc_response_authority.settlementReadiness(),
    );

    const input: rpc_response_authority.ReserveInput = .{
        .registry_incarnation = registry.incarnation,
        .binding = first.identity,
        .transport_addr = 0xB304,
        .transport_incarnation = 0xB305,
        .family = .bound_observation,
        .tag = .observation,
        .request_id = 0xB306,
        .request_digest = 0xB307,
        .destination_addr = 0xB308,
    };
    const active = try first_entry.rpc_response_authority.reserveExecuting(input);
    const stale_active_authority = first_entry.rpc_response_authority;
    try std.testing.expectError(error.InvalidState, registry.abort(first.reservation, first.identity));
    try std.testing.expect(first_entry.rpc_response_authority.matches(
        active,
        .executing,
        registry.incarnation,
        first.identity,
    ));
    try first_entry.rpc_response_authority.settleExecutingTerminal(
        active,
        registry.incarnation,
        first.identity,
    );
    const stale_terminal_authority = first_entry.rpc_response_authority;
    try registry.abort(first.reservation, first.identity);
    try std.testing.expect(first_entry.rpc_response_authority.pristineExact());

    const second = try registry.reserve(fixtureSeed(0xB309, 0xB30A));
    try std.testing.expectEqual(first.reservation.entry_index, second.reservation.entry_index);
    const second_entry = &registry.entries[second.reservation.entry_index];
    const current_idle_authority = second_entry.rpc_response_authority;
    second_entry.rpc_response_authority = stale_terminal_authority;
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(second.reservation, first.identity),
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(second.reservation, second.identity),
    );
    second_entry.rpc_response_authority = stale_active_authority;
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(second.reservation, first.identity),
    );
    try std.testing.expectError(
        error.InvalidCanonical,
        second_entry.rpc_response_authority.settleExecutingTerminal(
            active,
            registry.incarnation,
            second.identity,
        ),
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(second.reservation, second.identity),
    );
    second_entry.rpc_response_authority = current_idle_authority;
    const second_input: rpc_response_authority.ReserveInput = .{
        .registry_incarnation = registry.incarnation,
        .binding = second.identity,
        .transport_addr = input.transport_addr,
        .transport_incarnation = input.transport_incarnation,
        .family = input.family,
        .tag = input.tag,
        .request_id = input.request_id,
        .request_digest = input.request_digest,
        .destination_addr = input.destination_addr,
    };
    const current = try second_entry.rpc_response_authority.reserveExecuting(second_input);
    try std.testing.expectError(
        error.InvalidCanonical,
        second_entry.rpc_response_authority.settleExecutingTerminal(
            active,
            registry.incarnation,
            second.identity,
        ),
    );
    try std.testing.expect(second_entry.rpc_response_authority.matches(
        current,
        .executing,
        registry.incarnation,
        second.identity,
    ));
    try second_entry.rpc_response_authority.rollbackExecuting(
        current,
        registry.incarnation,
        second.identity,
    );
    try registry.abort(second.reservation, second.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());

    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB30B);
    const reincarnated = try registry.reserve(fixtureSeed(0xB302, 0xB303));
    try std.testing.expect(reincarnated.identity.matches(first.identity));
    const reincarnated_entry = &registry.entries[reincarnated.reservation.entry_index];
    const reincarnated_idle_authority = reincarnated_entry.rpc_response_authority;
    reincarnated_entry.rpc_response_authority = stale_terminal_authority;
    try std.testing.expectError(
        error.InvalidState,
        registry.abort(reincarnated.reservation, first.identity),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.count());
    reincarnated_entry.rpc_response_authority = reincarnated_idle_authority;
    try registry.abort(reincarnated.reservation, reincarnated.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "B3-1 registry footprint drop and empty corruption gates are bounded" {
    const LegacyEntry = struct {
        lifecycle: EntryLifecycle = .empty,
        reservation_id: u64 = 0,
        identity: ?contract.BindingIdentity = null,
        stream_id: u64 = 0,
        controller_authority: ControllerAuthority = .unavailable,
        transport_owner: contract.TransportOwnerSeal = .{},
        response_owner: contract.ExecutedResponseOwnerSeal = .{},
        prepared_request: prepared_request_authority.Authority = .{},
    };
    const per_entry_delta = @sizeOf(Entry) - @sizeOf(LegacyEntry);
    try std.testing.expect(@sizeOf(rpc_response_authority.Authority) <= 256);
    try std.testing.expect(per_entry_delta <= 128);
    try std.testing.expect(per_entry_delta * max_entries <= 512 * 1024);

    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB311);
    const reserved = try registry.reserve(fixtureSeed(0xB312, 0xB313));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB314);
    try registry.beginBoundDrop(reserved.reservation, reserved.identity, 0xB314);
    const entry = &registry.entries[reserved.reservation.entry_index];
    const input: rpc_response_authority.ReserveInput = .{
        .registry_incarnation = registry.incarnation,
        .binding = reserved.identity,
        .transport_addr = 0xB315,
        .transport_incarnation = 0xB316,
        .family = .bound_observation,
        .tag = .observation,
        .request_id = 0xB317,
        .request_digest = 0xB318,
        .destination_addr = 0xB319,
    };
    const active = try entry.rpc_response_authority.reserveExecuting(input);
    try std.testing.expectError(
        error.InvalidState,
        registry.completeActiveDrop(reserved.reservation, reserved.identity, 0xB314),
    );
    try entry.rpc_response_authority.rollbackExecuting(
        active,
        registry.incarnation,
        reserved.identity,
    );
    try registry.completeActiveDrop(reserved.reservation, reserved.identity, 0xB314);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());

    var corrupt: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&corrupt, 0xB31A);
    corrupt.entries[0].rpc_response_authority.next_epoch = 1;
    try std.testing.expectEqual(DeinitOutcome.corrupt, corrupt.preflightDeinit());
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
