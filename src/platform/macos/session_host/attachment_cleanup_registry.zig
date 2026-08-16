//! Node-local CR3a-2a stream-drop reservation substrate.
//!
//! This module owns only bounded metadata. It never imports or calls Client, GUI, socket, payload,
//! allocator, cleanup-permit, or callback code. A higher owner reserves an empty drop entry before
//! attach, binds the returned stream without allocation, and may destroy the registry only after
//! every entry has been settled by a later cleanup owner.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("generation_attachment_contract.zig");
const prepared_request_authority = @import("prepared_request_authority.zig");
const rpc_response_authority = @import("rpc_response_authority.zig");
const settlement = @import("pending_event_settlement_contract.zig");
const process_seal = @import("process_seal_service.zig");

extern "c" fn alarm(seconds: c_uint) c_uint;

pub const max_entries: usize = 4096;

fn ensureSettlementSealReadyForTest() !process_seal.ReadyIdentity {
    if (!builtin.is_test) unreachable;
    return process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => blk: {
            const focused_z = std.c.getenv("MARU_SESSION_HOST_C3B3_REGISTRY_FIXTURE") orelse
                return error.SkipZigTest;
            if (!std.mem.eql(u8, std.mem.span(focused_z), "prepared-release-v1"))
                return error.SkipZigTest;
            const pid = process_seal.currentProcessId();
            const prepared = try process_seal.prepare(pid, 0x3B33_0001);
            process_seal.commitReady(prepared);
            break :blk try process_seal.currentReadyIdentity();
        },
        else => err,
    };
}

fn fixturePendingRegistryReceipt(
    ready: process_seal.ReadyIdentity,
    event: EventGenerationReceipt,
    pending_owner_addr: u64,
    pending_owner_incarnation: u64,
    source_lease_incarnation: u64,
    attempt: u64,
) !settlement.PendingRegistryReleaseReceipt {
    if (!builtin.is_test) unreachable;
    var event_identity = std.mem.zeroes(@TypeOf((settlement.PendingRegistryReleaseReceipt{}).event_identity));
    event_identity.registry_incarnation = event.registry_incarnation;
    event_identity.binding_reservation_id = event.binding_reservation_id;
    event_identity.event_node_incarnation = event.node_incarnation;
    event_identity.stream_id = event.stream_id;
    event_identity.event_generation = event.event_generation;
    event_identity.event_owner_addr = event.owner_addr;
    event_identity.pid = ready.pid;
    event_identity.process_nonce = ready.process_nonce;
    var receipt: settlement.PendingRegistryReleaseReceipt = .{
        .event_identity = event_identity,
        .pending_owner_addr = pending_owner_addr,
        .pending_owner_incarnation = pending_owner_incarnation,
        .source_lease_incarnation = source_lease_incarnation,
        .attempt = attempt,
        .state_raw = 1,
    };
    receipt.release_seal = try process_seal.pendingReleaseSeal(ready.pid, ready.process_nonce, .{
        .event_identity = receipt.event_identity,
        .pending_owner_addr = receipt.pending_owner_addr,
        .pending_owner_incarnation = receipt.pending_owner_incarnation,
        .source_lease_incarnation = receipt.source_lease_incarnation,
        .attempt = receipt.attempt,
        .state_raw = receipt.state_raw,
        .reserved = receipt.reserved,
    });
    return receipt;
}

fn fixtureRegistrySettlementBinding(
    ready: process_seal.ReadyIdentity,
    pending_owner_addr: u64,
) !settlement.RuntimeSettlementLeaseBinding {
    if (!builtin.is_test) unreachable;
    var binding: settlement.RuntimeSettlementLeaseBinding = .{
        .lease_addr = 0x3B33_1000,
        .lifetime_owner_addr = 0x3B33_2000,
        .operation_identity = .{
            .lifetime_owner_addr = 0x3B33_2000,
            .runtime_addr = 0x3B33_3000,
            .pending_owner_addr = pending_owner_addr,
            .pid = ready.pid,
            .reserved_pid = 0,
            .process_nonce = ready.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .owner_incarnation = 3,
            .operation_incarnation = 5,
            .operation_kind_raw = 3,
            .operation_seal = [_]u8{0x31} ** 32,
        },
        .ranges_digest = [_]u8{0x32} ** 32,
        .pristine_digest = [_]u8{0x33} ** 32,
        .preflight_proof_seal_digest = [_]u8{0x34} ** 32,
        .lease_seal_digest = [_]u8{0x35} ** 32,
    };
    binding.binding_seal = try settlement.sealRuntimeSettlementBinding(binding);
    return binding;
}

pub const testing = if (builtin.is_test) struct {
    pub fn rollbackEventPreparationPending(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) Error!void {
        return self.rollbackEventPreparationPendingForTest(reservation, identity, receipt);
    }
} else struct {};

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

const EventAuthorityLifecycle = enum(u8) {
    idle,
    reserved,
    live,
    preparation_pending,
    releasing,
    terminal,
};

pub const EventOrderingClass = enum(u8) {
    none,
    non_revoke_effect,
    controller_revoke,
};

/// `preparation_pending -> releasing -> idle` 행의 registry-local continuation이다.
///
/// payload/allocator/pin/quarantine 권위와 public `EventReleaseCompletion` 목적지는 의도적으로
/// 포함하지 않는다. `ClientSlot`만 이 projection을 sealed composite
/// `PreparedEventReleasePermit`에 합치며, 모든 외부 owner가 실제 settle된 뒤 source-zero
/// completion을 게시한다.
pub const PreparedRegistryEventRelease = struct {
    registry_addr: usize = 0,
    registry_incarnation: u64 = 0,
    binding_reservation_id: u64 = 0,
    entry_index: u16 = 0,
    event_node_incarnation: u64 = 0,
    stream_id: u64 = 0,
    event_generation: u64 = 0,
    event_owner_addr: usize = 0,
    ordering_class_raw: u8 = 0,
    expected_blocker_count: usize = 0,
};

const AdmissionContext = enum(u8) {
    prepare,
    execute_attach,
    execute_rpc,
};

pub const AdmissionDecision = enum {
    allowed,
    unauthorized,
    busy,
};

pub const AdmissionError = error{
    InvalidOwner,
    InvalidReceipt,
    InvalidResponseDestination,
};

pub const PreparedAdmission = struct {
    canonical: prepared_request_authority.Prepared,
    decision: AdmissionDecision,
};

const PolicyResult = enum {
    allowed,
    unauthorized,
    busy,
    invalid_owner,
    invalid_receipt,
    invalid_destination,
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

fn eventAuthorityLifecycleRawValid(value: *const EventAuthorityLifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(EventAuthorityLifecycle.terminal);
}

fn eventOrderingClassRawValid(value: *const EventOrderingClass) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(EventOrderingClass.controller_revoke);
}

fn rangesOverlap(a_addr: usize, a_len: usize, b_addr: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_addr, a_len) catch return true;
    const b_end = std.math.add(usize, b_addr, b_len) catch return true;
    return a_addr < b_end and b_addr < a_end;
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

/// Pointer-free projection of the binding entry's canonical event incarnation. It is evidence to
/// revalidate against the registry, never an independently mutable receipt authority.
pub const EventGenerationReceipt = struct {
    registry_incarnation: u64,
    binding_reservation_id: u64,
    node_incarnation: u64,
    stream_id: u64,
    event_generation: u64,
    owner_addr: usize,
};

pub const EventReleaseContinuation = struct {
    event: EventGenerationReceipt,
    completion_addr: usize,
    registered_operation_id: u64,
};

pub const EventReleaseReadiness = enum(u8) { live, busy, terminal };
pub const EventAttachmentReadiness = enum(u8) { ready, busy, invalid };

pub const EventPinRecoveryPermit = struct {
    event: EventGenerationReceipt,
    permit_generation: u64,
    completion_addr: usize,
    registered_operation_id: u64,
};

pub const EventTrustedCleanup = struct {
    pub const State = enum(u8) { live, releasing };

    event: EventGenerationReceipt,
    quarantine_slot_index: u16,
    quarantine_reservation_generation: u64,
    ordering_class: EventOrderingClass,
    state: State,
};

/// Pointer-free evidence for immutable event preparation.  Keeping this projection separate from
/// EventTrustedCleanup prevents ordinary release and recovery callers from treating a pending
/// preparation as callback-free live authority.
pub const EventTrustedPreparation = struct {
    event: EventGenerationReceipt,
    quarantine_slot_index: u16,
    quarantine_reservation_generation: u64,
    ordering_class: EventOrderingClass,
};

const EventAuthority = struct {
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    active_owner_addr: usize = 0,
    completion_addr: usize = 0,
    registered_operation_id: u64 = 0,
    quarantine_slot_index: u16 = 0,
    quarantine_reservation_generation: u64 = 0,
    ordering_class: EventOrderingClass = .none,
    lifecycle: EventAuthorityLifecycle = .idle,

    fn pristineExact(self: *const EventAuthority) bool {
        return eventAuthorityLifecycleRawValid(&self.lifecycle) and
            eventOrderingClassRawValid(&self.ordering_class) and
            self.lifecycle == .idle and self.next_generation == 1 and
            self.active_generation == 0 and self.active_owner_addr == 0 and
            self.completion_addr == 0 and self.registered_operation_id == 0 and
            self.quarantine_slot_index == 0 and self.quarantine_reservation_generation == 0 and
            self.ordering_class == .none;
    }

    fn idleExact(self: *const EventAuthority) bool {
        return eventAuthorityLifecycleRawValid(&self.lifecycle) and
            eventOrderingClassRawValid(&self.ordering_class) and
            self.lifecycle == .idle and self.next_generation != 0 and
            self.active_generation == 0 and self.active_owner_addr == 0 and
            self.completion_addr == 0 and self.registered_operation_id == 0 and
            self.quarantine_slot_index == 0 and self.quarantine_reservation_generation == 0 and
            self.ordering_class == .none;
    }

    fn settledExact(self: *const EventAuthority) bool {
        if (!eventAuthorityLifecycleRawValid(&self.lifecycle) or
            !eventOrderingClassRawValid(&self.ordering_class) or
            self.active_generation != 0 or self.active_owner_addr != 0 or
            self.completion_addr != 0 or self.registered_operation_id != 0 or
            self.quarantine_slot_index != 0 or self.quarantine_reservation_generation != 0 or
            self.ordering_class != .none)
            return false;
        return switch (self.lifecycle) {
            .idle => self.next_generation != 0,
            .terminal => self.next_generation == std.math.maxInt(u64),
            .reserved, .live, .preparation_pending, .releasing => false,
        };
    }
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
    rpc_execution_recovery: RpcExecutionRecovery = .{},
    event_authority: EventAuthority = .{},

    fn clear(self: *Entry) void {
        self.* = .{};
    }
};

const RpcExecutionRecovery = struct {
    response_epoch: u64 = 0,

    fn emptyExact(self: *const @This()) bool {
        return self.response_epoch == 0;
    }

    fn exactFor(
        self: *const @This(),
        prepared: prepared_request_authority.Prepared,
        response: rpc_response_authority.Canonical,
    ) bool {
        return self.response_epoch != 0 and self.response_epoch == response.response_epoch and
            prepared.receipt.request_id == response.request_id and
            prepared.receipt.request_digest == response.request_digest;
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
    connection_ordering_blocker_count: usize = 0,
    active_rpc_recovery_entry_plus_one: u16 = 0,
    lifecycle: RegistryLifecycle = .pristine,
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    pub fn initInPlace(out: *AttachmentCleanupRegistry, incarnation: u64) Error!void {
        if (incarnation == 0) return error.InvalidIdentity;
        if (!registryLifecycleRawValid(&out.lifecycle)) return error.InvalidState;
        switch (out.lifecycle) {
            .pristine => {
                if (out.self_addr != 0 or out.incarnation != 0 or out.live_count != 0 or
                    out.connection_ordering_blocker_count != 0)
                    return error.InvalidState;
            },
            .dead => {
                if (out.self_addr != @intFromPtr(out) or out.live_count != 0 or
                    out.connection_ordering_blocker_count != 0)
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
            self.connection_ordering_blocker_count <= self.live_count and
            self.active_rpc_recovery_entry_plus_one <= max_entries and
            self.lifecycle == .live;
    }

    pub fn count(self: *const AttachmentCleanupRegistry) Error!usize {
        if (!self.valid()) return error.MovedOrCopied;
        return self.live_count;
    }

    pub fn connectionOrderingBlockerCount(self: *const AttachmentCleanupRegistry) Error!usize {
        if (!self.valid()) return error.MovedOrCopied;
        return self.connection_ordering_blocker_count;
    }

    pub fn validateConnectionOrderingBlockerCacheForTest(
        self: *const AttachmentCleanupRegistry,
    ) Error!bool {
        if (!builtin.is_test) unreachable;
        if (!self.valid()) return error.MovedOrCopied;
        var scanned: usize = 0;
        for (&self.entries) |*entry| {
            const authority = &entry.event_authority;
            if (!entryLifecycleRawValid(&entry.lifecycle) or
                !eventAuthorityLifecycleRawValid(&authority.lifecycle) or
                !eventOrderingClassRawValid(&authority.ordering_class))
                return error.InvalidState;
            const blocks = switch (authority.lifecycle) {
                .reserved, .live, .preparation_pending, .releasing => true,
                .terminal => authority.completion_addr != 0 and
                    authority.registered_operation_id != 0,
                .idle => false,
            };
            if (blocks) {
                if (authority.ordering_class == .none) return error.InvalidState;
                scanned = std.math.add(usize, scanned, 1) catch
                    return error.InvalidState;
            } else if (authority.ordering_class != .none) return error.InvalidState;
        }
        return scanned == self.connection_ordering_blocker_count;
    }

    fn finishEventOrderingNoFail(
        self: *AttachmentCleanupRegistry,
        authority: *EventAuthority,
    ) void {
        if (!eventOrderingClassRawValid(&authority.ordering_class))
            @panic("event ordering class drifted");
        if (authority.ordering_class == .none)
            @panic("active event lost ordering class");
        if (self.connection_ordering_blocker_count == 0)
            @panic("event connection ordering blocker cache underflow");
        self.connection_ordering_blocker_count -= 1;
        authority.ordering_class = .none;
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
        const entry = try self.exactEntry(reservation, identity);
        return requestForReceiptInEntry(
            entry,
            transport_addr,
            transport_incarnation,
            receipt,
            expected_lifecycle,
        );
    }

    fn requestForReceiptInEntry(
        entry: *const Entry,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        expected_lifecycle: prepared_request_authority.Lifecycle,
    ) ?prepared_request_authority.Prepared {
        const authority = &entry.prepared_request;
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

    pub fn requestDecision(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        family: contract.RequestFamily,
        tag: contract.RuntimeRequestTag,
        bound_stream_id: u64,
    ) Error!AdmissionDecision {
        const entry = try self.exactEntry(reservation, identity);
        return switch (classifyEntryPolicy(
            entry,
            identity,
            family,
            tag,
            bound_stream_id,
            .prepare,
        )) {
            .allowed => .allowed,
            .unauthorized => .unauthorized,
            .busy => .busy,
            .invalid_owner, .invalid_receipt, .invalid_destination => error.InvalidState,
        };
    }

    pub fn preparedAttachAdmission(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        bound_stream_id: u64,
    ) AdmissionError!PreparedAdmission {
        return self.classifyRequestAdmission(
            reservation,
            identity,
            transport_addr,
            transport_incarnation,
            receipt,
            bound_stream_id,
            .prepared,
            .execute_attach,
        );
    }

    pub fn preparedRpcAdmission(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        bound_stream_id: u64,
    ) AdmissionError!PreparedAdmission {
        return self.classifyRequestAdmission(
            reservation,
            identity,
            transport_addr,
            transport_incarnation,
            receipt,
            bound_stream_id,
            .prepared,
            .execute_rpc,
        );
    }

    pub fn executingRpcAdmission(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        bound_stream_id: u64,
    ) AdmissionError!PreparedAdmission {
        return self.classifyRequestAdmission(
            reservation,
            identity,
            transport_addr,
            transport_incarnation,
            receipt,
            bound_stream_id,
            .executing,
            .execute_rpc,
        );
    }

    pub fn reserveRpcResponseExecution(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
        destination_addr: usize,
    ) (Error || rpc_response_authority.Authority.Error)!rpc_response_authority.Canonical {
        const entry = try self.exactEntry(reservation, identity);
        const canonical = requestForReceiptInEntry(
            entry,
            prepared.transport_addr,
            prepared.transport_incarnation,
            prepared.receipt,
            .prepared,
        ) orelse return error.InvalidState;
        if (!std.meta.eql(canonical, prepared)) return error.InvalidState;
        return entry.rpc_response_authority.reserveExecuting(.{
            .registry_incarnation = self.incarnation,
            .binding = identity,
            .transport_addr = prepared.transport_addr,
            .transport_incarnation = prepared.transport_incarnation,
            .family = prepared.family,
            .tag = prepared.tag,
            .request_id = prepared.receipt.request_id,
            .request_digest = prepared.receipt.request_digest,
            .destination_addr = destination_addr,
        });
    }

    pub fn exhaustRpcResponseEpochForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.exhaustNextEpochForTest();
    }

    pub fn rpcExecutionAuthoritiesTerminalForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!bool {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        return entry.prepared_request.terminalExact() and
            entry.rpc_response_authority.terminalExactFor(self.incarnation, identity);
    }

    pub const RpcExecutionRecoveryEvidence = struct {
        request_terminal: bool,
        response_terminal: bool,
        recovery_empty: bool,
    };

    pub const RpcExecutionRecoveryCanonical = struct {
        reservation: Reservation,
        binding: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
        response: rpc_response_authority.Canonical,
    };

    fn armedRpcExecutionRecovery(
        self: *AttachmentCleanupRegistry,
        expected_response_lifecycle: rpc_response_authority.Lifecycle,
    ) Error!RpcExecutionRecoveryCanonical {
        if (!self.valid() or self.active_rpc_recovery_entry_plus_one == 0)
            return error.InvalidState;
        const index = self.active_rpc_recovery_entry_plus_one - 1;
        if (index >= max_entries) return error.InvalidState;
        const entry = &self.entries[index];
        const binding = currentEntryBinding(entry, self.incarnation) orelse
            return error.InvalidState;
        if (!entry.prepared_request.rawLifecycleValid() or
            entry.prepared_request.lifecycle != .executing or
            entry.prepared_request.prepared_present != 1)
            return error.InvalidState;
        const prepared = entry.prepared_request.prepared;
        if (!entry.prepared_request.matchesExecuting(prepared)) return error.InvalidState;
        const response = entry.rpc_response_authority.canonicalForRecovery(
            expected_response_lifecycle,
            self.incarnation,
            binding,
        ) orelse return error.InvalidState;
        if (!entry.rpc_execution_recovery.exactFor(prepared, response))
            return error.InvalidState;
        return .{
            .reservation = .{
                .registry_incarnation = self.incarnation,
                .reservation_id = entry.reservation_id,
                .entry_index = index,
            },
            .binding = binding,
            .prepared = prepared,
            .response = response,
        };
    }

    pub fn rpcExecutionRecoveryCanonical(
        self: *AttachmentCleanupRegistry,
    ) Error!RpcExecutionRecoveryCanonical {
        return self.armedRpcExecutionRecovery(.executing);
    }

    pub fn rpcExecutionRecoveryEvidenceForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!RpcExecutionRecoveryEvidence {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        return .{
            .request_terminal = entry.prepared_request.terminalExact(),
            .response_terminal = entry.rpc_response_authority.terminalExactFor(self.incarnation, identity),
            .recovery_empty = entry.rpc_execution_recovery.emptyExact(),
        };
    }

    /// Arms the canonical, pointer-free recovery correlation before response allocation can call
    /// an allocator callback. It does not own payload bytes or caller scratch storage.
    pub fn armRpcExecutionRecovery(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        prepared: prepared_request_authority.Prepared,
        response: rpc_response_authority.Canonical,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        if (self.active_rpc_recovery_entry_plus_one != 0 or
            !entry.rpc_execution_recovery.emptyExact() or
            !entry.prepared_request.matchesExecuting(prepared) or
            !entry.rpc_response_authority.matches(response, .executing, self.incarnation, identity))
            return error.InvalidState;
        entry.rpc_execution_recovery = .{
            .response_epoch = response.response_epoch,
        };
        self.active_rpc_recovery_entry_plus_one = reservation.entry_index + 1;
    }

    pub fn commitRpcExecutionRecoveryDisarmNoFail(self: *AttachmentCleanupRegistry) void {
        const canonical = self.armedRpcExecutionRecovery(.published) catch
            @panic("RPC execution recovery disarm drifted");
        const entry = self.exactEntry(canonical.reservation, canonical.binding) catch
            @panic("RPC execution recovery disarm registry drifted");
        entry.rpc_execution_recovery = .{};
        self.active_rpc_recovery_entry_plus_one = 0;
    }

    /// The caller has already fixed the byte disposition. Validate both canonical authorities
    /// before mutating either, then consume the recovery reservation and terminalize both without
    /// allocation, callbacks, or caller-owned transaction state.
    pub fn commitRpcExecutionRecoveryTerminalNoFail(self: *AttachmentCleanupRegistry) void {
        const canonical = self.armedRpcExecutionRecovery(.executing) catch
            @panic("RPC execution recovery authority drifted");
        const entry = self.exactEntry(canonical.reservation, canonical.binding) catch
            @panic("RPC execution recovery registry drifted");
        entry.prepared_request.commitExecutingTerminalNoFail(canonical.prepared);
        entry.rpc_response_authority.commitExecutingTerminalNoFail(
            canonical.response,
            self.incarnation,
            canonical.binding,
        );
        entry.rpc_execution_recovery = .{};
        self.active_rpc_recovery_entry_plus_one = 0;
    }

    /// Verifies the allocation-free terminal state published by the recovery commit. This lets the
    /// outer transaction mirror canonical settlement without attempting a second authority write.
    pub fn rpcExecutionRecoveryTerminalExact(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) bool {
        const entry = self.exactEntry(reservation, identity) catch return false;
        return self.active_rpc_recovery_entry_plus_one == 0 and
            entry.rpc_execution_recovery.emptyExact() and
            entry.prepared_request.terminalExact() and
            entry.rpc_response_authority.terminalExactFor(self.incarnation, identity);
    }

    pub fn rollbackRpcResponseExecution(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        return entry.rpc_response_authority.rollbackExecuting(
            canonical,
            self.incarnation,
            identity,
        );
    }

    pub fn settleRpcResponseExecutionTerminal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        return entry.rpc_response_authority.settleExecutingTerminal(
            canonical,
            self.incarnation,
            identity,
        );
    }

    pub fn prepareRpcResponsePublished(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.preparePublish(canonical, self.incarnation, identity, out);
    }

    pub fn commitRpcResponsePublished(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared RPC publish registry drifted");
        entry.rpc_response_authority.commitPublishedNoFail(canonical, permit);
    }

    pub fn prepareRpcResponseBorrowed(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.prepareBorrow(canonical, self.incarnation, identity, out);
    }

    pub fn commitRpcResponseBorrowed(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared RPC borrow registry drifted");
        entry.rpc_response_authority.commitBorrowedNoFail(canonical, permit);
    }

    pub fn prepareRpcResponseReleasing(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.prepareBeginRelease(canonical, self.incarnation, identity, out);
    }

    pub fn commitRpcResponseReleasing(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared RPC release registry drifted");
        entry.rpc_response_authority.commitReleasingNoFail(canonical, permit);
    }

    pub fn prepareRpcResponseReusable(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.prepareFinishReusable(canonical, self.incarnation, identity, out);
    }

    pub fn commitRpcResponseReusable(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared RPC reusable registry drifted");
        entry.rpc_response_authority.commitReusableNoFail(canonical, permit);
    }

    pub fn prepareRpcResponseTerminal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.prepareFinishTerminal(canonical, self.incarnation, identity, out);
    }

    pub fn commitRpcResponseTerminal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared RPC terminal registry drifted");
        entry.rpc_response_authority.commitTerminalNoFail(canonical, permit);
    }

    pub fn preparePublishedRpcResponseTerminal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        out: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) (Error || rpc_response_authority.Authority.Error)!void {
        const entry = try self.exactEntry(reservation, identity);
        try entry.rpc_response_authority.preparePublishedTerminal(canonical, self.incarnation, identity, out);
    }

    pub fn commitPublishedRpcResponseTerminal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        canonical: rpc_response_authority.Canonical,
        permit: *rpc_response_authority.PreparedRpcTransitionPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("prepared published RPC terminal registry drifted");
        entry.rpc_response_authority.commitPublishedTerminalNoFail(canonical, permit);
    }

    fn classifyRequestAdmission(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        transport_addr: usize,
        transport_incarnation: u64,
        receipt: contract.PreparedCallReceipt,
        bound_stream_id: u64,
        expected_lifecycle: prepared_request_authority.Lifecycle,
        context: AdmissionContext,
    ) AdmissionError!PreparedAdmission {
        if (!admissionContextRawValid(&context)) return error.InvalidResponseDestination;
        const entry = self.exactEntry(reservation, identity) catch return error.InvalidOwner;
        const maybe_canonical = requestForReceiptInEntry(
            entry,
            transport_addr,
            transport_incarnation,
            receipt,
            expected_lifecycle,
        );
        const canonical = maybe_canonical orelse return error.InvalidReceipt;
        return .{
            .canonical = canonical,
            .decision = try policyDecision(classifyEntryPolicy(
                entry,
                identity,
                canonical.family,
                canonical.tag,
                bound_stream_id,
                context,
            )),
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

    pub fn rpcResponseSettlementReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!rpc_response_authority.SettlementReadiness {
        const entry = try self.exactEntry(reservation, identity);
        return entry.rpc_response_authority.settlementReadiness();
    }

    pub fn transportTerminalizeReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        require_drop_active: bool,
    ) Error!prepared_request_authority.SettlementReadiness {
        const entry = try self.exactEntry(reservation, identity);
        if (require_drop_active and entry.lifecycle != .drop_active) return .invalid;
        if (!eventAuthorityLifecycleRawValid(&entry.event_authority.lifecycle)) return .invalid;
        if (!entry.event_authority.settledExact()) {
            return switch (entry.event_authority.lifecycle) {
                .reserved, .live, .preparation_pending, .releasing => .busy,
                .idle, .terminal => .invalid,
            };
        }
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

    pub fn reserveEventGeneration(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
        owner_addr: usize,
    ) Error!EventGenerationReceipt {
        return self.reserveEventGenerationInternal(
            reservation,
            identity,
            stream_id,
            owner_addr,
            .non_revoke_effect,
        );
    }

    pub fn reserveEventGenerationWithOrdering(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
        owner_addr: usize,
        ordering_class: EventOrderingClass,
    ) Error!EventGenerationReceipt {
        return self.reserveEventGenerationInternal(
            reservation,
            identity,
            stream_id,
            owner_addr,
            ordering_class,
        );
    }

    fn reserveEventGenerationInternal(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        stream_id: u64,
        owner_addr: usize,
        ordering_class: EventOrderingClass,
    ) Error!EventGenerationReceipt {
        if (stream_id == 0) return error.InvalidStream;
        if (owner_addr == 0 or !eventOrderingClassRawValid(&ordering_class) or
            ordering_class == .none)
            return error.InvalidIdentity;
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            entry.lifecycle != .bound or entry.stream_id != stream_id)
            return error.InvalidState;
        if (authority.lifecycle == .terminal) return error.IdentityExhausted;
        if (!authority.idleExact()) return error.InvalidState;
        const generation = authority.next_generation;
        if (generation == 0 or generation == std.math.maxInt(u64)) {
            authority.lifecycle = .terminal;
            return error.IdentityExhausted;
        }
        if (self.connection_ordering_blocker_count == max_entries)
            return error.CapacityExhausted;

        authority.next_generation = generation + 1;
        authority.active_generation = generation;
        authority.active_owner_addr = owner_addr;
        authority.ordering_class = ordering_class;
        authority.lifecycle = .reserved;
        self.connection_ordering_blocker_count += 1;
        return .{
            .registry_incarnation = self.incarnation,
            .binding_reservation_id = identity.binding_reservation_id,
            .node_incarnation = identity.node_incarnation,
            .stream_id = stream_id,
            .event_generation = generation,
            .owner_addr = owner_addr,
        };
    }

    pub fn eventGenerationCurrent(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) Error!bool {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle)) return error.InvalidState;
        return authority.lifecycle == .live and
            receipt.registry_incarnation == self.incarnation and
            receipt.binding_reservation_id == identity.binding_reservation_id and
            receipt.node_incarnation == identity.node_incarnation and
            receipt.stream_id == entry.stream_id and receipt.stream_id != 0 and
            receipt.event_generation == authority.active_generation and
            receipt.owner_addr == authority.active_owner_addr and receipt.owner_addr != 0;
    }

    pub fn eventReleaseReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!EventReleaseReadiness {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle)) return error.InvalidState;
        return switch (authority.lifecycle) {
            .live => .live,
            .reserved, .preparation_pending => .busy,
            .idle, .releasing, .terminal => .terminal,
        };
    }

    /// Canonical teardown projection for the inline attachment owner. The caller's generation is
    /// only compared with registry state; it never authorizes cleanup or a lifecycle transition.
    pub fn eventAttachmentReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        owner_addr: usize,
        generation_mirror: u64,
    ) Error!EventAttachmentReadiness {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle)) return error.InvalidState;
        return switch (authority.lifecycle) {
            .idle, .terminal => if (generation_mirror == 0) .ready else .invalid,
            .reserved => .busy,
            .live, .preparation_pending, .releasing => if (generation_mirror != 0 and
                generation_mirror == authority.active_generation and
                owner_addr != 0 and owner_addr == authority.active_owner_addr)
                .busy
            else
                .invalid,
        };
    }

    /// Ended purge may start only while the reserved final-address event slot has no live owner.
    /// Unlike attachment teardown this query does not accept a caller mirror as authority.
    pub fn eventPurgeReadiness(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        owner_addr: usize,
    ) Error!EventAttachmentReadiness {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or owner_addr == 0)
            return error.InvalidState;
        return switch (authority.lifecycle) {
            .idle, .terminal => .ready,
            .reserved => .busy,
            .live, .preparation_pending, .releasing => if (authority.active_owner_addr == owner_addr)
                .busy
            else
                error.InvalidState,
        };
    }

    /// Linearizes immutable preparation against release, teardown, and ended purge.  Every
    /// rejection happens before the sole lifecycle mutation; the existing event identity and
    /// ordering blocker remain canonical throughout the pending interval.
    pub fn beginEventPreparationPending(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) Error!void {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            authority.lifecycle != .live or
            !eventReceiptMatches(self, entry, authority, identity, receipt) or
            authority.completion_addr != 0 or authority.registered_operation_id != 0)
            return error.InvalidState;
        authority.lifecycle = .preparation_pending;
    }

    /// Focused fixtures must restore ordinary live authority before using the existing release
    /// path.  Product settlement remains owned exclusively by the later b3 transaction.
    fn rollbackEventPreparationPendingForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) Error!void {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            authority.lifecycle != .preparation_pending or
            !eventReceiptMatches(self, entry, authority, identity, receipt) or
            authority.completion_addr != 0 or authority.registered_operation_id != 0)
            return error.InvalidState;
        authority.lifecycle = .live;
    }

    pub fn beginEventReleaseNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
        completion_addr: usize,
        registered_operation_id: u64,
    ) EventReleaseContinuation {
        if (completion_addr == 0 or registered_operation_id == 0)
            @panic("event release continuation identity is empty");
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event release lost binding authority");
        const authority = &entry.event_authority;
        if (!eventReceiptMatches(self, entry, authority, identity, receipt) or authority.lifecycle != .live or
            authority.completion_addr != 0 or authority.registered_operation_id != 0)
            @panic("event release lost live authority");
        authority.completion_addr = completion_addr;
        authority.registered_operation_id = registered_operation_id;
        authority.lifecycle = .releasing;
        return .{
            .event = receipt,
            .completion_addr = completion_addr,
            .registered_operation_id = registered_operation_id,
        };
    }

    /// immutable preparation에서 나오는 유일한 제품 전이를 준비한다. ordinary live-release
    /// continuation을 공유하거나 넓히지 않는다.
    pub fn preflightPreparedEventRelease(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
        pending: settlement.PendingRegistryReleaseReceipt,
        binding: settlement.RuntimeSettlementLeaseBinding,
        out: *PreparedRegistryEventRelease,
    ) Error!void {
        const out_addr = @intFromPtr(out);
        if (out_addr == 0 or out_addr % @alignOf(PreparedRegistryEventRelease) != 0 or
            rangesOverlap(out_addr, @sizeOf(PreparedRegistryEventRelease), @intFromPtr(self), @sizeOf(AttachmentCleanupRegistry)) or
            !std.meta.eql(out.*, PreparedRegistryEventRelease{}))
            return error.InvalidState;
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventReceiptMatches(self, entry, authority, identity, receipt) or
            authority.lifecycle != .preparation_pending or authority.completion_addr != 0 or
            authority.registered_operation_id != 0 or authority.ordering_class == .none or
            self.connection_ordering_blocker_count == 0 or
            !settlement.validRuntimeSettlementBinding(binding) or
            !settlement.validPendingRegistryReleaseReceipt(pending) or
            pending.event_identity.registry_incarnation != receipt.registry_incarnation or
            pending.event_identity.binding_reservation_id != receipt.binding_reservation_id or
            pending.event_identity.event_node_incarnation != receipt.node_incarnation or
            pending.event_identity.stream_id != receipt.stream_id or
            pending.event_identity.event_generation != receipt.event_generation or
            pending.event_identity.event_owner_addr != receipt.owner_addr or
            binding.operation_identity.pending_owner_addr != pending.pending_owner_addr or
            binding.operation_identity.pid != pending.event_identity.pid or
            binding.operation_identity.process_nonce != pending.event_identity.process_nonce)
            return error.InvalidState;

        const ready = process_seal.currentReadyIdentity() catch return error.InvalidState;
        if (pending.event_identity.pid != ready.pid or
            pending.event_identity.process_nonce != ready.process_nonce)
            return error.InvalidState;
        out.* = .{
            .registry_addr = @intFromPtr(self),
            .registry_incarnation = self.incarnation,
            .binding_reservation_id = identity.binding_reservation_id,
            .entry_index = reservation.entry_index,
            .event_node_incarnation = identity.node_incarnation,
            .stream_id = entry.stream_id,
            .event_generation = receipt.event_generation,
            .event_owner_addr = receipt.owner_addr,
            .ordering_class_raw = @intFromEnum(authority.ordering_class),
            .expected_blocker_count = self.connection_ordering_blocker_count,
        };
    }

    pub fn beginPreparedEventReleaseNoFail(
        self: *AttachmentCleanupRegistry,
        permit: PreparedRegistryEventRelease,
    ) void {
        if (permit.registry_addr != @intFromPtr(self) or permit.registry_incarnation != self.incarnation or
            permit.entry_index >= max_entries)
            process_seal.fatalIntegrity(.proof_loss);

        if (!self.valid()) process_seal.fatalIntegrity(.proof_loss);
        const entry = &self.entries[permit.entry_index];
        const authority = &entry.event_authority;
        if (!entryLifecycleRawValid(&entry.lifecycle) or
            !controllerAuthorityRawValid(&entry.controller_authority) or
            !entry.rpc_response_authority.rawLifecycleValid() or
            !eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            !eventOrderingClassRawValid(&authority.ordering_class))
            process_seal.fatalIntegrity(.proof_loss);
        const canonical = currentEntryBinding(entry, self.incarnation) orelse
            process_seal.fatalIntegrity(.proof_loss);
        if (entry.lifecycle != .bound or
            entry.reservation_id != permit.binding_reservation_id or
            entry.stream_id != permit.stream_id or authority.lifecycle != .preparation_pending or
            canonical.binding_reservation_id != permit.binding_reservation_id or
            canonical.node_incarnation != permit.event_node_incarnation or
            authority.active_generation != permit.event_generation or
            authority.active_owner_addr != permit.event_owner_addr or
            @intFromEnum(authority.ordering_class) != permit.ordering_class_raw or
            self.connection_ordering_blocker_count != permit.expected_blocker_count or
            authority.completion_addr != 0 or authority.registered_operation_id != 0)
            process_seal.fatalIntegrity(.proof_loss);

        authority.lifecycle = .releasing;
    }

    /// effect callback 뒤 첫 payload-source 변경 직전에 수행하는 최종 read-only 검사다.
    /// composite owner가 모든 non-registry 자원을 계속 책임지며, 이 exact lower continuation이
    /// 여전히 시작 가능한지만 증명한다.
    pub fn preparedEventReleaseCurrent(
        self: *AttachmentCleanupRegistry,
        permit: PreparedRegistryEventRelease,
    ) bool {
        if (permit.registry_addr != @intFromPtr(self) or permit.registry_incarnation != self.incarnation or
            permit.entry_index >= max_entries or !self.valid()) return false;
        const entry = &self.entries[permit.entry_index];
        const authority = &entry.event_authority;
        if (!entryLifecycleRawValid(&entry.lifecycle) or
            !eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            !eventOrderingClassRawValid(&authority.ordering_class)) return false;
        const canonical = currentEntryBinding(entry, self.incarnation) orelse return false;
        return entry.lifecycle == .bound and
            entry.reservation_id == permit.binding_reservation_id and
            entry.stream_id == permit.stream_id and
            authority.lifecycle == .preparation_pending and
            canonical.binding_reservation_id == permit.binding_reservation_id and
            canonical.node_incarnation == permit.event_node_incarnation and
            authority.active_generation == permit.event_generation and
            authority.active_owner_addr == permit.event_owner_addr and
            @intFromEnum(authority.ordering_class) == permit.ordering_class_raw and
            self.connection_ordering_blocker_count == permit.expected_blocker_count and
            authority.completion_addr == 0 and authority.registered_operation_id == 0;
    }

    pub fn finishPreparedEventReleaseNoFail(
        self: *AttachmentCleanupRegistry,
        permit: PreparedRegistryEventRelease,
    ) settlement.EventReleaseLeafReceipt {
        if (permit.registry_addr != @intFromPtr(self) or permit.registry_incarnation != self.incarnation or
            permit.entry_index >= max_entries)
            process_seal.fatalIntegrity(.proof_loss);
        if (!self.valid()) process_seal.fatalIntegrity(.proof_loss);
        const entry = &self.entries[permit.entry_index];
        const authority = &entry.event_authority;
        if (entry.lifecycle != .bound or authority.lifecycle != .releasing or
            entry.reservation_id != permit.binding_reservation_id or entry.stream_id != permit.stream_id or
            authority.active_generation != permit.event_generation or authority.active_owner_addr != permit.event_owner_addr or
            self.connection_ordering_blocker_count != permit.expected_blocker_count)
            process_seal.fatalIntegrity(.proof_loss);
        const blocker_before = self.connection_ordering_blocker_count;
        self.finishEventOrderingNoFail(authority);
        authority.active_generation = 0;
        authority.active_owner_addr = 0;
        authority.completion_addr = 0;
        authority.registered_operation_id = 0;
        authority.quarantine_slot_index = 0;
        authority.quarantine_reservation_generation = 0;
        authority.lifecycle = .idle;
        const ready = process_seal.currentReadyIdentity() catch process_seal.fatalIntegrity(.proof_loss);
        var receipt: settlement.EventReleaseLeafReceipt = .{
            .pid = ready.pid,
            .process_nonce = ready.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .role_raw = @intFromEnum(settlement.EventReleaseLeafRole.registry),
            .identity_a = permit.registry_incarnation,
            .identity_b = permit.binding_reservation_id,
            .identity_c = permit.event_node_incarnation,
            .identity_d = permit.event_generation,
            .before_a = blocker_before,
            .before_b = @intFromEnum(EventAuthorityLifecycle.releasing),
            .after_a = self.connection_ordering_blocker_count,
            .after_b = @intFromEnum(EventAuthorityLifecycle.idle),
        };
        receipt.seal = settlement.sealEventReleaseLeafReceipt(receipt) catch
            process_seal.fatalIntegrity(.proof_loss);
        return receipt;
    }

    pub fn preparedEventReleaseSettled(
        self: *AttachmentCleanupRegistry,
        permit: PreparedRegistryEventRelease,
    ) bool {
        if (permit.registry_addr != @intFromPtr(self) or permit.registry_incarnation != self.incarnation or
            permit.entry_index >= max_entries or !self.valid() or permit.expected_blocker_count == 0)
            return false;
        const entry = &self.entries[permit.entry_index];
        const authority = &entry.event_authority;
        return entry.lifecycle == .bound and entry.reservation_id == permit.binding_reservation_id and
            entry.stream_id == permit.stream_id and authority.lifecycle == .idle and
            authority.active_generation == 0 and authority.active_owner_addr == 0 and
            authority.completion_addr == 0 and authority.registered_operation_id == 0 and
            authority.quarantine_slot_index == 0 and authority.quarantine_reservation_generation == 0 and
            self.connection_ordering_blocker_count == permit.expected_blocker_count - 1;
    }

    pub fn finishEventReleaseNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        continuation: EventReleaseContinuation,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event release completion lost binding authority");
        const authority = &entry.event_authority;
        if (!eventReceiptMatches(self, entry, authority, identity, continuation.event) or
            authority.lifecycle != .releasing or
            authority.completion_addr != 0 or authority.registered_operation_id != 0 or
            continuation.completion_addr == 0 or continuation.registered_operation_id == 0)
            @panic("event release completion receipt drifted");
        self.finishEventOrderingNoFail(authority);
        authority.active_generation = 0;
        authority.active_owner_addr = 0;
        authority.completion_addr = 0;
        authority.registered_operation_id = 0;
        authority.quarantine_slot_index = 0;
        authority.quarantine_reservation_generation = 0;
        authority.lifecycle = .idle;
    }

    pub fn consumeEventReleaseContinuationNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        continuation: EventReleaseContinuation,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event release continuation lost binding authority");
        const authority = &entry.event_authority;
        if (!eventReceiptMatches(self, entry, authority, identity, continuation.event) or
            authority.lifecycle != .releasing or
            authority.completion_addr != continuation.completion_addr or
            authority.registered_operation_id != continuation.registered_operation_id or
            continuation.completion_addr == 0 or continuation.registered_operation_id == 0)
            @panic("event release continuation replayed or drifted");
        authority.completion_addr = 0;
        authority.registered_operation_id = 0;
    }

    pub fn terminalizeLiveEventForRecoveryNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
        completion_addr: usize,
        registered_operation_id: u64,
    ) EventPinRecoveryPermit {
        if (completion_addr == 0 or registered_operation_id == 0)
            @panic("event recovery continuation identity is empty");
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event recovery lost binding authority");
        const authority = &entry.event_authority;
        if (!eventReceiptMatches(self, entry, authority, identity, receipt) or authority.lifecycle != .live or
            authority.completion_addr != 0 or authority.registered_operation_id != 0)
            @panic("event recovery requires callback-free live authority");
        const permit_generation = authority.active_generation;
        authority.active_generation = 0;
        authority.active_owner_addr = 0;
        authority.completion_addr = completion_addr;
        authority.registered_operation_id = registered_operation_id;
        authority.quarantine_slot_index = 0;
        authority.quarantine_reservation_generation = 0;
        authority.next_generation = std.math.maxInt(u64);
        authority.lifecycle = .terminal;
        return .{
            .event = receipt,
            .permit_generation = permit_generation,
            .completion_addr = completion_addr,
            .registered_operation_id = registered_operation_id,
        };
    }

    pub fn consumeEventPinRecoveryPermitNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        permit: EventPinRecoveryPermit,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event recovery permit lost binding authority");
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or authority.lifecycle != .terminal or
            authority.active_generation != 0 or authority.active_owner_addr != 0 or
            authority.next_generation != std.math.maxInt(u64) or
            authority.completion_addr != permit.completion_addr or
            authority.registered_operation_id != permit.registered_operation_id or
            permit.permit_generation == 0 or permit.permit_generation != permit.event.event_generation or
            permit.completion_addr == 0 or permit.registered_operation_id == 0)
            @panic("event recovery permit replayed or drifted");
        self.finishEventOrderingNoFail(authority);
        authority.completion_addr = 0;
        authority.registered_operation_id = 0;
    }

    pub fn rollbackEventGenerationBeforePublishNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event generation rollback lost binding authority");
        const authority = &entry.event_authority;
        if (authority.lifecycle != .reserved or
            receipt.registry_incarnation != self.incarnation or
            receipt.binding_reservation_id != identity.binding_reservation_id or
            receipt.node_incarnation != identity.node_incarnation or
            receipt.stream_id != entry.stream_id or receipt.stream_id == 0 or
            receipt.event_generation != authority.active_generation or
            receipt.owner_addr != authority.active_owner_addr or receipt.owner_addr == 0)
            @panic("event generation rollback lost reserved authority");
        self.finishEventOrderingNoFail(authority);
        entry.event_authority.active_generation = 0;
        entry.event_authority.active_owner_addr = 0;
        entry.event_authority.quarantine_slot_index = 0;
        entry.event_authority.quarantine_reservation_generation = 0;
        entry.event_authority.lifecycle = .idle;
    }

    pub fn commitEventGenerationPublicationNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event generation publication lost binding authority");
        const authority = &entry.event_authority;
        if (authority.lifecycle != .reserved or
            receipt.registry_incarnation != self.incarnation or
            receipt.binding_reservation_id != identity.binding_reservation_id or
            receipt.node_incarnation != identity.node_incarnation or
            receipt.stream_id != entry.stream_id or receipt.stream_id == 0 or
            receipt.event_generation != authority.active_generation or
            receipt.owner_addr != authority.active_owner_addr or receipt.owner_addr == 0)
            @panic("event generation publication lost reserved authority");
        authority.lifecycle = .live;
    }

    pub fn bindEventCleanupNoFail(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
        quarantine_slot_index: u16,
        quarantine_reservation_generation: u64,
    ) void {
        const entry = self.exactEntry(reservation, identity) catch
            @panic("event cleanup bind lost binding authority");
        const authority = &entry.event_authority;
        if (authority.lifecycle != .reserved or quarantine_reservation_generation == 0 or
            !eventReceiptMatches(self, entry, authority, identity, receipt) or
            authority.quarantine_slot_index != 0 or authority.quarantine_reservation_generation != 0)
            @panic("event cleanup bind drifted");
        authority.quarantine_slot_index = quarantine_slot_index;
        authority.quarantine_reservation_generation = quarantine_reservation_generation;
    }

    pub fn trustedEventCleanup(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        owner_addr: usize,
    ) Error!EventTrustedCleanup {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            (authority.lifecycle != .live and authority.lifecycle != .releasing) or
            authority.active_generation == 0 or authority.active_owner_addr != owner_addr or
            owner_addr == 0 or authority.quarantine_reservation_generation == 0)
            return error.InvalidState;
        return .{
            .event = .{
                .registry_incarnation = self.incarnation,
                .binding_reservation_id = identity.binding_reservation_id,
                .node_incarnation = identity.node_incarnation,
                .stream_id = entry.stream_id,
                .event_generation = authority.active_generation,
                .owner_addr = owner_addr,
            },
            .quarantine_slot_index = authority.quarantine_slot_index,
            .quarantine_reservation_generation = authority.quarantine_reservation_generation,
            .ordering_class = authority.ordering_class,
            .state = if (authority.lifecycle == .live) .live else .releasing,
        };
    }

    pub fn trustedEventPreparation(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        owner_addr: usize,
    ) Error!EventTrustedPreparation {
        const entry = try self.exactEntry(reservation, identity);
        const authority = &entry.event_authority;
        if (!eventAuthorityLifecycleRawValid(&authority.lifecycle) or
            (authority.lifecycle != .live and authority.lifecycle != .preparation_pending) or
            authority.active_generation == 0 or authority.active_owner_addr != owner_addr or
            owner_addr == 0 or authority.quarantine_reservation_generation == 0)
            return error.InvalidState;
        return .{
            .event = .{
                .registry_incarnation = self.incarnation,
                .binding_reservation_id = identity.binding_reservation_id,
                .node_incarnation = identity.node_incarnation,
                .stream_id = entry.stream_id,
                .event_generation = authority.active_generation,
                .owner_addr = owner_addr,
            },
            .quarantine_slot_index = authority.quarantine_slot_index,
            .quarantine_reservation_generation = authority.quarantine_reservation_generation,
            .ordering_class = authority.ordering_class,
        };
    }

    pub fn settleEventGenerationForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) Error!void {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        if (!(try self.eventGenerationCurrent(reservation, identity, receipt)))
            return error.InvalidState;
        self.finishEventOrderingNoFail(&entry.event_authority);
        entry.event_authority.active_generation = 0;
        entry.event_authority.active_owner_addr = 0;
        entry.event_authority.quarantine_slot_index = 0;
        entry.event_authority.quarantine_reservation_generation = 0;
        entry.event_authority.lifecycle = .idle;
    }

    fn eventReceiptMatches(
        self: *const AttachmentCleanupRegistry,
        entry: *const Entry,
        authority: *const EventAuthority,
        identity: contract.BindingIdentity,
        receipt: EventGenerationReceipt,
    ) bool {
        return eventAuthorityLifecycleRawValid(&authority.lifecycle) and
            eventOrderingClassRawValid(&authority.ordering_class) and
            receipt.registry_incarnation == self.incarnation and
            receipt.binding_reservation_id == identity.binding_reservation_id and
            receipt.node_incarnation == identity.node_incarnation and
            receipt.stream_id == entry.stream_id and receipt.stream_id != 0 and
            receipt.event_generation == authority.active_generation and
            receipt.owner_addr == authority.active_owner_addr and receipt.owner_addr != 0;
    }

    pub fn exhaustEventGenerationForTest(
        self: *AttachmentCleanupRegistry,
        reservation: Reservation,
        identity: contract.BindingIdentity,
    ) Error!void {
        if (!builtin.is_test) unreachable;
        const entry = try self.exactEntry(reservation, identity);
        if (!entry.event_authority.idleExact()) return error.InvalidState;
        entry.event_authority.next_generation = std.math.maxInt(u64);
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
            !entry.event_authority.settledExact() or
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
        if (self.live_count != 0 or self.connection_ordering_blocker_count != 0 or
            self.active_rpc_recovery_entry_plus_one != 0) return .busy;
        for (&self.entries) |*entry| {
            if (!entryLifecycleRawValid(&entry.lifecycle) or
                !controllerAuthorityRawValid(&entry.controller_authority) or
                entry.lifecycle != .empty or entry.reservation_id != 0 or
                entry.stream_id != 0 or entry.controller_authority != .unavailable or
                entry.transport_owner.lifecycle != .pristine or
                entry.response_owner.lifecycle != .pristine or
                !entry.event_authority.pristineExact() or
                !entry.rpc_execution_recovery.emptyExact() or
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

fn admissionContextRawValid(value: *const AdmissionContext) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(AdmissionContext.execute_rpc);
}

fn policyDecision(result: PolicyResult) AdmissionError!AdmissionDecision {
    return switch (result) {
        .allowed => .allowed,
        .unauthorized => .unauthorized,
        .busy => .busy,
        .invalid_owner => error.InvalidOwner,
        .invalid_receipt => error.InvalidReceipt,
        .invalid_destination => error.InvalidResponseDestination,
    };
}

fn classifyEntryPolicy(
    entry: *const Entry,
    identity: contract.BindingIdentity,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    bound_stream_id: u64,
    context: AdmissionContext,
) PolicyResult {
    if (!admissionContextRawValid(&context)) return .invalid_destination;
    if (!entryLifecycleRawValid(&entry.lifecycle) or
        !controllerAuthorityRawValid(&entry.controller_authority) or
        !contract.attachmentRoleRawValid(&identity.role))
        return .invalid_owner;
    if (!contract.requestFamilyRawValid(&family) or
        !contract.runtimeRequestTagRawValid(&tag) or
        !contract.requestFamilyAllowed(tag, family))
        return .invalid_receipt;
    if (family == .connection_only_denied) return .unauthorized;

    const destination_matches = switch (context) {
        .prepare => true,
        .execute_attach => family == .attach_only,
        .execute_rpc => family != .attach_only,
    };
    if (!destination_matches) return .invalid_destination;

    return switch (family) {
        .connection_only_denied => .unauthorized,
        .attach_only => if (((tag == .attach_controller and identity.role == .controller) or
            (tag == .attach_observer and identity.role == .observer)) and
            entry.lifecycle == .reserved and entry.stream_id == 0 and bound_stream_id == 0 and
            entry.controller_authority == .unavailable)
            .allowed
        else
            .unauthorized,
        .bound_observation => if (entry.lifecycle == .bound and entry.stream_id != 0 and
            entry.stream_id == bound_stream_id and
            ((identity.role == .observer and entry.controller_authority == .unavailable) or
                (identity.role == .controller and entry.controller_authority != .unavailable)))
            .allowed
        else
            .unauthorized,
        .bound_controller_mutation => if (entry.lifecycle == .bound and entry.stream_id != 0 and
            entry.stream_id == bound_stream_id and identity.role == .controller and
            entry.controller_authority == .live)
            .allowed
        else
            .unauthorized,
        .bound_terminal => if (tag == .detach and entry.lifecycle == .bound and
            entry.stream_id != 0 and entry.stream_id == bound_stream_id and
            identity.role == .controller and entry.controller_authority == .revoke_pending)
            .busy
        else if (entry.lifecycle == .bound and entry.stream_id != 0 and
            entry.stream_id == bound_stream_id and
            ((tag == .detach and identity.role == .observer and
                entry.controller_authority == .unavailable) or
                (identity.role == .controller and entry.controller_authority == .live) or
                (tag == .detach and identity.role == .controller and
                    entry.controller_authority == .revoked)))
            .allowed
        else
            .unauthorized,
    };
}

fn childAuthoritiesSettled(entry: *const Entry, registry_incarnation: u64) bool {
    const identity = currentEntryBinding(entry, registry_incarnation) orelse return false;
    return entry.transport_owner.settledExact() and entry.response_owner.settledExact() and
        entry.prepared_request.settledExact() and
        entry.rpc_response_authority.settledExactFor(registry_incarnation, identity) and
        entry.rpc_execution_recovery.emptyExact();
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

fn fixturePrepared(
    binding: contract.BindingIdentity,
    tag: contract.RuntimeRequestTag,
    family: contract.RequestFamily,
    transport_addr: usize,
    transport_incarnation: u64,
    request_id: u64,
) prepared_request_authority.Prepared {
    const receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = transport_incarnation,
        .request_id = request_id,
        .request_digest = request_id + 1,
    }).?;
    return .{
        .transport_addr = transport_addr,
        .transport_incarnation = transport_incarnation,
        .binding = binding,
        .tag = tag,
        .family = family,
        .receipt = receipt,
        .descriptor = .{
            .storage_addr = request_id + 2,
            .prepared_incarnation = request_id + 3,
            .client_addr = request_id + 4,
            .request_id = request_id,
            .request_digest = request_id + 1,
            .frame_addr = request_id + 5,
            .frame_len = 1,
            .allocator_ptr = request_id + 6,
            .allocator_vtable = request_id + 7,
        },
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

test "CR3a-2c3d C2 B3-1 registry footprint drop and empty corruption gates are bounded" {
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
    // C2 keeps the final-address completion and registered-operation identities in the canonical
    // row so replay is rejected before allocator.free or pin decrement. With the pre-existing
    // quarantine identity this is seven machine words plus compact tags, rounded to 64 bytes.
    try std.testing.expect(@sizeOf(EventAuthority) <= 64);
    try std.testing.expect(@sizeOf(EventAuthority) * max_entries <= 256 * 1024);
    // 2c3d adds three checked event-generation scalars to the binding SSOT. Keep the resulting
    // fixed table growth explicit instead of silently inheriting the pre-event 512 KiB budget.
    try std.testing.expect(per_entry_delta <= 192);
    try std.testing.expect(per_entry_delta * max_entries <= 768 * 1024);

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

test "B3-2 private destination admission resolves canonical receipt and never mutates authority" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB320);
    const reserved = try registry.reserve(fixtureSeed(0xB321, 0xB322));
    const attach = fixturePrepared(
        reserved.identity,
        .attach_controller,
        .attach_only,
        0xB323,
        0xB324,
        0xB325,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, attach);
    const before_attach = registry;
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        attach.transport_addr,
        attach.transport_incarnation,
        attach.receipt,
        0,
    )).decision);
    try std.testing.expectError(error.InvalidResponseDestination, registry.classifyRequestAdmission(
        reserved.reservation,
        reserved.identity,
        attach.transport_addr,
        attach.transport_incarnation,
        attach.receipt,
        0,
        .prepared,
        .execute_rpc,
    ));
    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&before_attach),
        std.mem.asBytes(&registry),
    ));
    try registry.beginPreparedRequestExecute(reserved.reservation, reserved.identity, attach);
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.classifyRequestAdmission(
        reserved.reservation,
        reserved.identity,
        attach.transport_addr,
        attach.transport_incarnation,
        attach.receipt,
        0,
        .executing,
        .execute_attach,
    )).decision);
    try registry.settlePreparedRequest(reserved.reservation, reserved.identity, attach, false);
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB326);

    const observation = fixturePrepared(
        reserved.identity,
        .observation,
        .bound_observation,
        attach.transport_addr,
        attach.transport_incarnation,
        0xB327,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, observation);
    const before_observation = registry;
    try std.testing.expectError(error.InvalidResponseDestination, registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        observation.transport_addr,
        observation.transport_incarnation,
        observation.receipt,
        0xB326,
    ));
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.classifyRequestAdmission(
        reserved.reservation,
        reserved.identity,
        observation.transport_addr,
        observation.transport_incarnation,
        observation.receipt,
        0xB326,
        .prepared,
        .execute_rpc,
    )).decision);
    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&before_observation),
        std.mem.asBytes(&registry),
    ));
    try registry.settlePreparedRequest(reserved.reservation, reserved.identity, observation, false);

    const detach = fixturePrepared(
        reserved.identity,
        .detach,
        .bound_terminal,
        attach.transport_addr,
        attach.transport_incarnation,
        0xB328,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, detach);
    try registry.beginControllerRevoke(reserved.reservation, reserved.identity, 0xB326);
    try std.testing.expectEqual(AdmissionDecision.busy, try registry.requestDecision(
        reserved.reservation,
        reserved.identity,
        .bound_terminal,
        .detach,
        0xB326,
    ));
    try std.testing.expectEqual(AdmissionDecision.busy, (try registry.classifyRequestAdmission(
        reserved.reservation,
        reserved.identity,
        detach.transport_addr,
        detach.transport_incarnation,
        detach.receipt,
        0xB326,
        .prepared,
        .execute_rpc,
    )).decision);
    try registry.finishControllerRevoke(reserved.reservation, reserved.identity, 0xB326);
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.classifyRequestAdmission(
        reserved.reservation,
        reserved.identity,
        detach.transport_addr,
        detach.transport_incarnation,
        detach.receipt,
        0xB326,
        .prepared,
        .execute_rpc,
    )).decision);
    try registry.settlePreparedRequest(reserved.reservation, reserved.identity, detach, false);
    try registry.beginBoundDrop(reserved.reservation, reserved.identity, 0xB326);
    try registry.completeActiveDrop(reserved.reservation, reserved.identity, 0xB326);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "B3-3 registry composes RPC admission response reserve and reusable rollback" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB330);
    const reserved = try registry.reserve(fixtureSeed(0xB331, 0xB332));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB333);
    const prepared = fixturePrepared(
        reserved.identity,
        .observation,
        .bound_observation,
        0xB334,
        0xB335,
        0xB336,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.preparedRpcAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr,
        prepared.transport_incarnation,
        prepared.receipt,
        0xB333,
    )).decision);
    const response = try registry.reserveRpcResponseExecution(
        reserved.reservation,
        reserved.identity,
        prepared,
        0xB337,
    );
    try registry.beginPreparedRequestExecute(reserved.reservation, reserved.identity, prepared);
    try std.testing.expectEqual(AdmissionDecision.allowed, (try registry.executingRpcAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr,
        prepared.transport_incarnation,
        prepared.receipt,
        0xB333,
    )).decision);
    try registry.settlePreparedRequest(reserved.reservation, reserved.identity, prepared, false);
    try registry.rollbackRpcResponseExecution(
        reserved.reservation,
        reserved.identity,
        response,
    );
    try std.testing.expectEqual(
        rpc_response_authority.SettlementReadiness.settled,
        registry.entries[reserved.reservation.entry_index].rpc_response_authority.settlementReadiness(),
    );
}

test "B3-3 registry terminal settlement rejects copied response canonical" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB338);
    const reserved = try registry.reserve(fixtureSeed(0xB339, 0xB33A));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB33B);
    const prepared = fixturePrepared(
        reserved.identity,
        .observation,
        .bound_observation,
        0xB33C,
        0xB33D,
        0xB33E,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    const response = try registry.reserveRpcResponseExecution(
        reserved.reservation,
        reserved.identity,
        prepared,
        0xB33F,
    );
    var forged = response;
    forged.destination_addr += 1;
    try std.testing.expectError(
        error.InvalidCanonical,
        registry.settleRpcResponseExecutionTerminal(
            reserved.reservation,
            reserved.identity,
            forged,
        ),
    );
    try registry.settleRpcResponseExecutionTerminal(
        reserved.reservation,
        reserved.identity,
        response,
    );
}

test "B3-4/5 registry transition recovery terminalizes both executing authorities exact once" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB345);
    const reserved = try registry.reserve(fixtureSeed(0xB346, 0xB347));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB348);
    const prepared = fixturePrepared(
        reserved.identity,
        .observation,
        .bound_observation,
        0xB349,
        0xB34A,
        0xB34B,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    const response = try registry.reserveRpcResponseExecution(
        reserved.reservation,
        reserved.identity,
        prepared,
        0xB34C,
    );
    try registry.beginPreparedRequestExecute(reserved.reservation, reserved.identity, prepared);
    try registry.armRpcExecutionRecovery(
        reserved.reservation,
        reserved.identity,
        prepared,
        response,
    );
    try std.testing.expectError(error.InvalidState, registry.armRpcExecutionRecovery(
        reserved.reservation,
        reserved.identity,
        prepared,
        response,
    ));
    registry.commitRpcExecutionRecoveryTerminalNoFail();
    try std.testing.expect(try registry.rpcExecutionAuthoritiesTerminalForTest(
        reserved.reservation,
        reserved.identity,
    ));
    try std.testing.expect(registry.entries[reserved.reservation.entry_index]
        .rpc_execution_recovery.emptyExact());
}

test "B3-4/5 registry transition facade closes reusable response lifecycle" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB340);
    const reserved = try registry.reserve(fixtureSeed(0xB341, 0xB342));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB343);
    const prepared = fixturePrepared(reserved.identity, .observation, .bound_observation, 0xB344, 0xB345, 0xB346);
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    const response = try registry.reserveRpcResponseExecution(reserved.reservation, reserved.identity, prepared, 0xB347);

    var publish: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.prepareRpcResponsePublished(reserved.reservation, reserved.identity, response, &publish);
    registry.commitRpcResponsePublished(reserved.reservation, reserved.identity, response, &publish);
    var borrow: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.prepareRpcResponseBorrowed(reserved.reservation, reserved.identity, response, &borrow);
    registry.commitRpcResponseBorrowed(reserved.reservation, reserved.identity, response, &borrow);
    var releasing: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.prepareRpcResponseReleasing(reserved.reservation, reserved.identity, response, &releasing);
    registry.commitRpcResponseReleasing(reserved.reservation, reserved.identity, response, &releasing);
    var reusable: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.prepareRpcResponseReusable(reserved.reservation, reserved.identity, response, &reusable);
    registry.commitRpcResponseReusable(reserved.reservation, reserved.identity, response, &reusable);
    try std.testing.expectEqual(
        rpc_response_authority.SettlementReadiness.settled,
        registry.entries[reserved.reservation.entry_index].rpc_response_authority.settlementReadiness(),
    );
}

test "B3-4/5 registry transition facade closes published and releasing terminal paths" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB348);
    const reserved = try registry.reserve(fixtureSeed(0xB349, 0xB34A));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB34B);
    const prepared = fixturePrepared(reserved.identity, .observation, .bound_observation, 0xB34C, 0xB34D, 0xB34E);
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    const response = try registry.reserveRpcResponseExecution(reserved.reservation, reserved.identity, prepared, 0xB34F);
    var publish: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.prepareRpcResponsePublished(reserved.reservation, reserved.identity, response, &publish);
    registry.commitRpcResponsePublished(reserved.reservation, reserved.identity, response, &publish);
    var terminal: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try registry.preparePublishedRpcResponseTerminal(reserved.reservation, reserved.identity, response, &terminal);
    registry.commitPublishedRpcResponseTerminal(reserved.reservation, reserved.identity, response, &terminal);
    try std.testing.expect(try registry.rpcExecutionAuthoritiesTerminalForTest(reserved.reservation, reserved.identity) == false);
    try std.testing.expect(
        registry.entries[reserved.reservation.entry_index].rpc_response_authority.terminalExactFor(registry.incarnation, reserved.identity),
    );
}

test "B3-4/5 registry transition prepare rejects stale phase without permit mutation" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB350);
    const reserved = try registry.reserve(fixtureSeed(0xB351, 0xB352));
    try registry.bindStream(reserved.reservation, reserved.identity, 0xB353);
    const prepared = fixturePrepared(reserved.identity, .observation, .bound_observation, 0xB354, 0xB355, 0xB356);
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);
    const response = try registry.reserveRpcResponseExecution(reserved.reservation, reserved.identity, prepared, 0xB357);
    var permit: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    try std.testing.expectError(
        error.InvalidState,
        registry.prepareRpcResponseBorrowed(reserved.reservation, reserved.identity, response, &permit),
    );
    try std.testing.expect(permit.pristineExact());
    try registry.settleRpcResponseExecutionTerminal(reserved.reservation, reserved.identity, response);
}

test "B3-2 private destination admission exhausts context policy and raw discriminants" {
    const tags = std.enums.values(contract.RuntimeRequestTag);
    const families = std.enums.values(contract.RequestFamily);
    const contexts = std.enums.values(AdmissionContext);
    const lifecycles = std.enums.values(EntryLifecycle);
    const roles = std.enums.values(contract.AttachmentRole);
    const authorities = std.enums.values(ControllerAuthority);
    const streams = [_]u64{ 0, 0xA, 0xB };

    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB330);
    const reserved = try registry.reserve(fixtureSeed(0xB331, 0xB332));
    const entry = &registry.entries[reserved.reservation.entry_index];
    for (tags) |tag| for (families) |family| for (contexts) |context| for (lifecycles) |lifecycle| for (roles) |role| for (authorities) |authority| for (streams) |entry_stream| for (streams) |current_stream| {
        var identity = reserved.identity;
        identity.role = role;
        entry.lifecycle = lifecycle;
        entry.stream_id = entry_stream;
        entry.controller_authority = authority;
        const before = entry.*;
        const actual = classifyEntryPolicy(entry, identity, family, tag, current_stream, context);
        const expected = expectedAdmission(lifecycle, role, authority, family, tag, entry_stream, current_stream, context);
        try std.testing.expectEqual(expected, actual);
        try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(entry)));
    };

    var context: AdmissionContext = .prepare;
    const context_raw: *u8 = @ptrCast(&context);
    var raw: u16 = @intFromEnum(AdmissionContext.execute_rpc) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        context_raw.* = @intCast(raw);
        try std.testing.expectEqual(PolicyResult.invalid_destination, classifyEntryPolicy(
            entry,
            reserved.identity,
            .attach_only,
            .attach_controller,
            0,
            context,
        ));
    }

    entry.lifecycle = .reserved;
    entry.stream_id = 0;
    entry.controller_authority = .unavailable;
    var invalid_lifecycle: EntryLifecycle = .reserved;
    raw = @intFromEnum(EntryLifecycle.drop_active) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        @as(*u8, @ptrCast(&invalid_lifecycle)).* = @intCast(raw);
        entry.lifecycle = invalid_lifecycle;
        try std.testing.expectEqual(PolicyResult.invalid_owner, classifyEntryPolicy(
            entry,
            reserved.identity,
            .attach_only,
            .attach_controller,
            0,
            .prepare,
        ));
    }

    entry.lifecycle = .reserved;
    var invalid_authority: ControllerAuthority = .unavailable;
    raw = @intFromEnum(ControllerAuthority.revoked) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        @as(*u8, @ptrCast(&invalid_authority)).* = @intCast(raw);
        entry.controller_authority = invalid_authority;
        try std.testing.expectEqual(PolicyResult.invalid_owner, classifyEntryPolicy(
            entry,
            reserved.identity,
            .attach_only,
            .attach_controller,
            0,
            .prepare,
        ));
    }

    entry.controller_authority = .unavailable;
    var invalid_role: contract.AttachmentRole = .controller;
    raw = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        @as(*u8, @ptrCast(&invalid_role)).* = @intCast(raw);
        var identity = reserved.identity;
        identity.role = invalid_role;
        try std.testing.expectEqual(PolicyResult.invalid_owner, classifyEntryPolicy(
            entry,
            identity,
            .attach_only,
            .attach_controller,
            0,
            .prepare,
        ));
    }

    var invalid_tag: contract.RuntimeRequestTag = .attach_controller;
    raw = @intFromEnum(contract.RuntimeRequestTag.attach_observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        @as(*u8, @ptrCast(&invalid_tag)).* = @intCast(raw);
        try std.testing.expectEqual(PolicyResult.invalid_receipt, classifyEntryPolicy(
            entry,
            reserved.identity,
            .attach_only,
            invalid_tag,
            0,
            .prepare,
        ));
    }

    var invalid_family: contract.RequestFamily = .attach_only;
    raw = @intFromEnum(contract.RequestFamily.bound_terminal) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        @as(*u8, @ptrCast(&invalid_family)).* = @intCast(raw);
        try std.testing.expectEqual(PolicyResult.invalid_receipt, classifyEntryPolicy(
            entry,
            reserved.identity,
            invalid_family,
            .attach_controller,
            0,
            .prepare,
        ));
    }

    entry.lifecycle = .reserved;
    entry.stream_id = 0;
    entry.controller_authority = .unavailable;
    try registry.abort(reserved.reservation, reserved.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "B3-2 private destination admission rejects canonical splice and same-address ABA without mutation" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB340);
    const reserved = try registry.reserve(fixtureSeed(0xB341, 0xB342));
    const prepared = fixturePrepared(
        reserved.identity,
        .attach_controller,
        .attach_only,
        0xB343,
        0xB344,
        0xB345,
    );
    try registry.publishPreparedRequest(reserved.reservation, reserved.identity, prepared);

    const before = registry;
    inline for (std.meta.fields(contract.BindingIdentity)) |field| {
        var foreign_identity = reserved.identity;
        if (field.type == contract.AttachmentRole)
            @field(foreign_identity, field.name) = .observer
        else
            @field(foreign_identity, field.name) +%= 1;
        try std.testing.expectError(error.InvalidOwner, registry.preparedAttachAdmission(
            reserved.reservation,
            foreign_identity,
            prepared.transport_addr,
            prepared.transport_incarnation,
            prepared.receipt,
            0,
        ));
    }
    inline for (std.meta.fields(Reservation)) |field| {
        var foreign_reservation = reserved.reservation;
        @field(foreign_reservation, field.name) +%= 1;
        try std.testing.expectError(error.InvalidOwner, registry.preparedAttachAdmission(
            foreign_reservation,
            reserved.identity,
            prepared.transport_addr,
            prepared.transport_incarnation,
            prepared.receipt,
            0,
        ));
    }
    try std.testing.expectError(error.InvalidReceipt, registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr + 1,
        prepared.transport_incarnation,
        prepared.receipt,
        0,
    ));
    try std.testing.expectError(error.InvalidReceipt, registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr,
        prepared.transport_incarnation + 1,
        prepared.receipt,
        0,
    ));
    inline for (std.meta.fields(contract.PreparedCallReceipt)) |field| {
        var foreign_receipt = prepared.receipt;
        @field(foreign_receipt, field.name) +%= 1;
        try std.testing.expectError(error.InvalidReceipt, registry.preparedAttachAdmission(
            reserved.reservation,
            reserved.identity,
            prepared.transport_addr,
            prepared.transport_incarnation,
            foreign_receipt,
            0,
        ));
    }
    try std.testing.expectEqual(AdmissionDecision.unauthorized, (try registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr,
        prepared.transport_incarnation,
        prepared.receipt,
        0xB34C,
    )).decision);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&registry)));

    try registry.settlePreparedRequest(reserved.reservation, reserved.identity, prepared, false);
    try registry.abort(reserved.reservation, reserved.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());

    try AttachmentCleanupRegistry.initInPlace(&registry, 0xB346);
    const current = try registry.reserve(fixtureSeed(0xB347, 0xB348));
    const current_prepared = fixturePrepared(
        current.identity,
        .attach_controller,
        .attach_only,
        0xB349,
        0xB34A,
        0xB34B,
    );
    try registry.publishPreparedRequest(current.reservation, current.identity, current_prepared);
    const before_aba = registry;
    try std.testing.expectError(error.InvalidOwner, registry.preparedAttachAdmission(
        reserved.reservation,
        reserved.identity,
        prepared.transport_addr,
        prepared.transport_incarnation,
        prepared.receipt,
        0,
    ));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&before_aba), std.mem.asBytes(&registry)));
    try registry.settlePreparedRequest(current.reservation, current.identity, current_prepared, false);
    try registry.abort(current.reservation, current.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

fn expectedAdmission(
    lifecycle: EntryLifecycle,
    role: contract.AttachmentRole,
    authority: ControllerAuthority,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    entry_stream: u64,
    current_stream: u64,
    context: AdmissionContext,
) PolicyResult {
    if (!contract.requestFamilyAllowed(tag, family)) return .invalid_receipt;
    if (family == .connection_only_denied) return .unauthorized;
    const destination_matches = if (family == .attach_only)
        context == .prepare or context == .execute_attach
    else
        context == .prepare or context == .execute_rpc;
    if (!destination_matches) return .invalid_destination;

    for (policy_expectations) |row| {
        if (row.family != family or (row.tag != null and row.tag.? != tag) or
            row.lifecycle != lifecycle or row.role != role or row.authority != authority)
            continue;
        const stream_matches = switch (row.stream) {
            .zero => entry_stream == 0 and current_stream == 0,
            .exact_nonzero => entry_stream != 0 and entry_stream == current_stream,
        };
        if (stream_matches) return row.result;
    }
    return .unauthorized;
}

const PolicyExpectation = struct {
    family: contract.RequestFamily,
    tag: ?contract.RuntimeRequestTag = null,
    lifecycle: EntryLifecycle,
    role: contract.AttachmentRole,
    authority: ControllerAuthority,
    stream: enum { zero, exact_nonzero },
    result: PolicyResult = .allowed,
};

// This declarative oracle is intentionally shaped unlike classifyEntryPolicy. A policy change
// must update either a reviewed row or the production control flow, so copying one switch cannot
// make the Cartesian test pass by construction.
const policy_expectations = [_]PolicyExpectation{
    .{ .family = .attach_only, .tag = .attach_controller, .lifecycle = .reserved, .role = .controller, .authority = .unavailable, .stream = .zero },
    .{ .family = .attach_only, .tag = .attach_observer, .lifecycle = .reserved, .role = .observer, .authority = .unavailable, .stream = .zero },
    .{ .family = .bound_observation, .lifecycle = .bound, .role = .observer, .authority = .unavailable, .stream = .exact_nonzero },
    .{ .family = .bound_observation, .lifecycle = .bound, .role = .controller, .authority = .live, .stream = .exact_nonzero },
    .{ .family = .bound_observation, .lifecycle = .bound, .role = .controller, .authority = .revoke_pending, .stream = .exact_nonzero },
    .{ .family = .bound_observation, .lifecycle = .bound, .role = .controller, .authority = .revoked, .stream = .exact_nonzero },
    .{ .family = .bound_controller_mutation, .lifecycle = .bound, .role = .controller, .authority = .live, .stream = .exact_nonzero },
    .{ .family = .bound_terminal, .tag = .detach, .lifecycle = .bound, .role = .observer, .authority = .unavailable, .stream = .exact_nonzero },
    .{ .family = .bound_terminal, .tag = .detach, .lifecycle = .bound, .role = .controller, .authority = .live, .stream = .exact_nonzero },
    .{ .family = .bound_terminal, .tag = .detach, .lifecycle = .bound, .role = .controller, .authority = .revoked, .stream = .exact_nonzero },
    .{ .family = .bound_terminal, .tag = .detach, .lifecycle = .bound, .role = .controller, .authority = .revoke_pending, .stream = .exact_nonzero, .result = .busy },
    .{ .family = .bound_terminal, .tag = .terminate, .lifecycle = .bound, .role = .controller, .authority = .live, .stream = .exact_nonzero },
};

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

test "CR3a-2c3d C1 event generation is binding-canonical and burns same-address ABA" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_C101);
    const bound = try registry.reserve(fixtureSeed(0xD000, 0xD001));
    try registry.bindStream(bound.reservation, bound.identity, 83);

    const first = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        83,
        0xD100,
    );
    try std.testing.expectEqual(@as(u64, 1), first.event_generation);
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, first);
    try std.testing.expect(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        first,
    ));
    try registry.settleEventGenerationForTest(bound.reservation, bound.identity, first);

    const second = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        83,
        0xD100,
    );
    try std.testing.expectEqual(@as(u64, 2), second.event_generation);
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, second);
    try std.testing.expect(!(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        first,
    )));
    try std.testing.expect(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        second,
    ));
    try registry.settleEventGenerationForTest(bound.reservation, bound.identity, second);
    try registry.beginBoundDrop(bound.reservation, bound.identity, 83);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 83);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3d C1 active event generation blocks siblings and bound drop" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_C102);
    const bound = try registry.reserve(fixtureSeed(0xD200, 0xD201));
    try registry.bindStream(bound.reservation, bound.identity, 89);

    const live = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        89,
        0xD300,
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.reserveEventGeneration(bound.reservation, bound.identity, 89, 0xD301),
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.beginBoundDrop(bound.reservation, bound.identity, 89),
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, live);
    try registry.settleEventGenerationForTest(bound.reservation, bound.identity, live);
    try registry.beginBoundDrop(bound.reservation, bound.identity, 89);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 89);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3d C1 event generation exhaustion is sticky and mutation free" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_C103);
    const bound = try registry.reserve(fixtureSeed(0xD400, 0xD401));
    try registry.bindStream(bound.reservation, bound.identity, 97);
    registry.exhaustEventGenerationForTest(bound.reservation, bound.identity) catch unreachable;

    try std.testing.expectError(
        error.IdentityExhausted,
        registry.reserveEventGeneration(bound.reservation, bound.identity, 97, 0xD500),
    );
    try std.testing.expectError(
        error.IdentityExhausted,
        registry.reserveEventGeneration(bound.reservation, bound.identity, 97, 0xD500),
    );
    try registry.beginBoundDrop(bound.reservation, bound.identity, 97);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 97);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2c3d C2 event authority lifecycle and rollback burn are canonical" {
    const expected_tags = [_][]const u8{
        "idle",
        "reserved",
        "live",
        "preparation_pending",
        "releasing",
        "terminal",
    };
    const actual_tags = std.meta.fields(EventAuthorityLifecycle);
    try std.testing.expectEqual(expected_tags.len, actual_tags.len);
    inline for (actual_tags, 0..) |actual, index|
        try std.testing.expectEqualStrings(expected_tags[index], actual.name);
    for (0..256) |raw| {
        var authority: EventAuthority = .{};
        @as(*u8, @ptrCast(&authority.lifecycle)).* = @intCast(raw);
        try std.testing.expectEqual(raw <= @intFromEnum(EventAuthorityLifecycle.terminal), eventAuthorityLifecycleRawValid(&authority.lifecycle));
    }

    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_C201);
    const bound = try registry.reserve(fixtureSeed(0xD600, 0xD601));
    try registry.bindStream(bound.reservation, bound.identity, 101);
    const burned = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        101,
        0xD700,
    );
    registry.rollbackEventGenerationBeforePublishNoFail(
        bound.reservation,
        bound.identity,
        burned,
    );
    const next = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        101,
        0xD700,
    );
    try std.testing.expectEqual(burned.event_generation + 1, next.event_generation);
    registry.rollbackEventGenerationBeforePublishNoFail(
        bound.reservation,
        bound.identity,
        next,
    );
    const live = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        101,
        0xD700,
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, live);

    // A copied or stale receipt cannot enter pending preparation and must leave both the
    // canonical lifecycle and the cached connection-ordering blocker unchanged.
    var stale = live;
    stale.event_generation += 1;
    try std.testing.expectError(
        error.InvalidState,
        registry.beginEventPreparationPending(
            bound.reservation,
            bound.identity,
            stale,
        ),
    );
    try std.testing.expect(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        live,
    ));
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());

    try registry.beginEventPreparationPending(
        bound.reservation,
        bound.identity,
        live,
    );
    try std.testing.expectEqual(
        EventReleaseReadiness.busy,
        try registry.eventReleaseReadiness(bound.reservation, bound.identity),
    );
    try std.testing.expectEqual(
        EventAttachmentReadiness.busy,
        try registry.eventAttachmentReadiness(
            bound.reservation,
            bound.identity,
            live.owner_addr,
            live.event_generation,
        ),
    );
    try std.testing.expectEqual(
        EventAttachmentReadiness.busy,
        try registry.eventPurgeReadiness(
            bound.reservation,
            bound.identity,
            live.owner_addr,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(!(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        live,
    )));

    try testing.rollbackEventPreparationPending(
        &registry,
        bound.reservation,
        bound.identity,
        live,
    );
    try std.testing.expect(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        live,
    ));
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());

    const continuation = registry.beginEventReleaseNoFail(
        bound.reservation,
        bound.identity,
        live,
        0xD710,
        0xD711,
    );
    try std.testing.expect(!(try registry.eventGenerationCurrent(
        bound.reservation,
        bound.identity,
        live,
    )));
    registry.consumeEventReleaseContinuationNoFail(bound.reservation, bound.identity, continuation);
    const releasing_entry = try registry.exactEntry(bound.reservation, bound.identity);
    try std.testing.expectEqual(@as(usize, 0), releasing_entry.event_authority.completion_addr);
    try std.testing.expectEqual(@as(u64, 0), releasing_entry.event_authority.registered_operation_id);
    if (builtin.os.tag == .macos) {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            _ = alarm(5);
            registry.consumeEventReleaseContinuationNoFail(
                bound.reservation,
                bound.identity,
                continuation,
            );
            std.c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFSIGNALED(unsigned_status) or std.c.W.EXITSTATUS(unsigned_status) != 0);
        try std.testing.expect(!(std.c.W.IFSIGNALED(unsigned_status) and std.c.W.TERMSIG(unsigned_status) == std.c.SIG.ALRM));
    }
    registry.finishEventReleaseNoFail(bound.reservation, bound.identity, continuation);

    const corrupt = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        101,
        0xD700,
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, corrupt);
    const recovery = registry.terminalizeLiveEventForRecoveryNoFail(
        bound.reservation,
        bound.identity,
        corrupt,
        0xD720,
        0xD721,
    );
    try std.testing.expectEqual(corrupt.event_generation, recovery.permit_generation);
    registry.consumeEventPinRecoveryPermitNoFail(bound.reservation, bound.identity, recovery);
    const terminal_entry = try registry.exactEntry(bound.reservation, bound.identity);
    try std.testing.expectEqual(@as(usize, 0), terminal_entry.event_authority.completion_addr);
    try std.testing.expectEqual(@as(u64, 0), terminal_entry.event_authority.registered_operation_id);
    if (builtin.os.tag == .macos) {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            _ = alarm(5);
            registry.consumeEventPinRecoveryPermitNoFail(
                bound.reservation,
                bound.identity,
                recovery,
            );
            std.c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFSIGNALED(unsigned_status) or std.c.W.EXITSTATUS(unsigned_status) != 0);
        try std.testing.expect(!(std.c.W.IFSIGNALED(unsigned_status) and std.c.W.TERMSIG(unsigned_status) == std.c.SIG.ALRM));
    }
    try registry.beginBoundDrop(bound.reservation, bound.identity, 101);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 101);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 ordering class remains closed and ordinary events join the all-event blocker" {
    const expected = [_][]const u8{ "none", "non_revoke_effect", "controller_revoke" };
    const actual = std.meta.fields(EventOrderingClass);
    try std.testing.expectEqual(expected.len, actual.len);
    inline for (actual, 0..) |field, index|
        try std.testing.expectEqualStrings(expected[index], field.name);
    for (0..256) |raw| {
        var ordering: EventOrderingClass = .none;
        @as(*u8, @ptrCast(&ordering)).* = @intCast(raw);
        try std.testing.expectEqual(
            raw <= @intFromEnum(EventOrderingClass.controller_revoke),
            eventOrderingClassRawValid(&ordering),
        );
    }

    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A11);
    const bound = try registry.reserve(fixtureSeed(0x3A1100, 0x3A1101));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A11);
    try std.testing.expectError(
        error.InvalidStream,
        registry.reserveEventGenerationWithOrdering(
            bound.reservation,
            bound.identity,
            0,
            0x3A1110,
            .controller_revoke,
        ),
    );
    var invalid_ordering: EventOrderingClass = .none;
    @as(*u8, @ptrCast(&invalid_ordering)).* = 0xFF;
    try std.testing.expectError(
        error.InvalidIdentity,
        registry.reserveEventGenerationWithOrdering(
            bound.reservation,
            bound.identity,
            0x3A11,
            0x3A1110,
            invalid_ordering,
        ),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        registry.reserveEventGenerationWithOrdering(
            bound.reservation,
            bound.identity,
            0x3A11,
            0x3A1110,
            .none,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    const ordinary = try registry.reserveEventGeneration(
        bound.reservation,
        bound.identity,
        0x3A11,
        0x3A1110,
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    registry.rollbackEventGenerationBeforePublishNoFail(bound.reservation, bound.identity, ordinary);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A11);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A11);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 revoke reserve and rollback are exact cached transitions" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A12);
    const bound = try registry.reserve(fixtureSeed(0x3A1200, 0x3A1201));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A12);
    const revoke = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A12,
        0x3A1210,
        .controller_revoke,
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightBoundDrop(bound.reservation, bound.identity, 0x3A12),
    );
    var copied = registry;
    try std.testing.expectError(error.MovedOrCopied, copied.connectionOrderingBlockerCount());
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    registry.rollbackEventGenerationBeforePublishNoFail(bound.reservation, bound.identity, revoke);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A12);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A12);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 clean release blocks through releasing and decrements at finish" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A13);
    const bound = try registry.reserve(fixtureSeed(0x3A1300, 0x3A1301));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A13);
    const revoke = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A13,
        0x3A1310,
        .controller_revoke,
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, revoke);
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightBoundDrop(bound.reservation, bound.identity, 0x3A13),
    );
    const continuation = registry.beginEventReleaseNoFail(
        bound.reservation,
        bound.identity,
        revoke,
        0x3A1320,
        0x3A1321,
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightBoundDrop(bound.reservation, bound.identity, 0x3A13),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    registry.consumeEventReleaseContinuationNoFail(bound.reservation, bound.identity, continuation);
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    registry.finishEventReleaseNoFail(bound.reservation, bound.identity, continuation);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A13);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A13);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 corrupt recovery keeps blocker until permit consume" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A14);
    const bound = try registry.reserve(fixtureSeed(0x3A1400, 0x3A1401));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A14);
    const revoke = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A14,
        0x3A1410,
        .controller_revoke,
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, revoke);
    const recovery = registry.terminalizeLiveEventForRecoveryNoFail(
        bound.reservation,
        bound.identity,
        revoke,
        0x3A1420,
        0x3A1421,
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightBoundDrop(bound.reservation, bound.identity, 0x3A14),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    registry.consumeEventPinRecoveryPermitNoFail(bound.reservation, bound.identity, recovery);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A14);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A14);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 sibling revoke authorities aggregate independently" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A15);
    const first = try registry.reserve(fixtureSeed(0x3A1500, 0x3A1501));
    const second = try registry.reserve(fixtureSeed(0x3A1510, 0x3A1511));
    try registry.bindStream(first.reservation, first.identity, 0x3A15);
    try registry.bindStream(second.reservation, second.identity, 0x3A16);
    const first_revoke = try registry.reserveEventGenerationWithOrdering(
        first.reservation,
        first.identity,
        0x3A15,
        0x3A1520,
        .controller_revoke,
    );
    const second_revoke = try registry.reserveEventGenerationWithOrdering(
        second.reservation,
        second.identity,
        0x3A16,
        0x3A1530,
        .controller_revoke,
    );
    try std.testing.expectEqual(@as(usize, 2), try registry.connectionOrderingBlockerCount());
    registry.rollbackEventGenerationBeforePublishNoFail(first.reservation, first.identity, first_revoke);
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    registry.rollbackEventGenerationBeforePublishNoFail(second.reservation, second.identity, second_revoke);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    try registry.beginBoundDrop(first.reservation, first.identity, 0x3A15);
    try registry.completeActiveDrop(first.reservation, first.identity, 0x3A15);
    try registry.beginBoundDrop(second.reservation, second.identity, 0x3A16);
    try registry.completeActiveDrop(second.reservation, second.identity, 0x3A16);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3b3 prepared registry release는 target만 settle하고 sibling을 exact 보존한다" {
    const ready = try ensureSettlementSealReadyForTest();
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3B31);
    const target = try registry.reserve(fixtureSeed(0x3B3100, 0x3B3101));
    const sibling = try registry.reserve(fixtureSeed(0x3B3110, 0x3B3111));
    try registry.bindStream(target.reservation, target.identity, 0x3B31);
    try registry.bindStream(sibling.reservation, sibling.identity, 0x3B32);
    const target_event = try registry.reserveEventGeneration(target.reservation, target.identity, 0x3B31, 0x3B3120);
    const sibling_event = try registry.reserveEventGenerationWithOrdering(
        sibling.reservation,
        sibling.identity,
        0x3B32,
        0x3B3130,
        .controller_revoke,
    );
    registry.commitEventGenerationPublicationNoFail(target.reservation, target.identity, target_event);
    registry.commitEventGenerationPublicationNoFail(sibling.reservation, sibling.identity, sibling_event);
    try registry.beginEventPreparationPending(target.reservation, target.identity, target_event);
    try std.testing.expectEqual(
        EventReleaseReadiness.busy,
        try registry.eventReleaseReadiness(target.reservation, target.identity),
    );

    const sibling_before = (try registry.exactEntry(sibling.reservation, sibling.identity)).*;
    var permit: PreparedRegistryEventRelease = .{};
    const pending = try fixturePendingRegistryReceipt(ready, target_event, 0x3B3140, 7, 9, 11);
    const binding = try fixtureRegistrySettlementBinding(ready, pending.pending_owner_addr);
    try registry.preflightPreparedEventRelease(
        target.reservation,
        target.identity,
        target_event,
        pending,
        binding,
        &permit,
    );
    try std.testing.expectEqual(@intFromPtr(&registry), permit.registry_addr);
    try std.testing.expectEqual(@as(usize, 2), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(std.meta.eql(sibling_before, (try registry.exactEntry(sibling.reservation, sibling.identity)).*));

    registry.beginPreparedEventReleaseNoFail(permit);
    _ = registry.finishPreparedEventReleaseNoFail(permit);
    try std.testing.expectEqual(EventReleaseReadiness.terminal, try registry.eventReleaseReadiness(target.reservation, target.identity));
    try std.testing.expect(try registry.eventGenerationCurrent(sibling.reservation, sibling.identity, sibling_event));
    try std.testing.expect(std.meta.eql(sibling_before, (try registry.exactEntry(sibling.reservation, sibling.identity)).*));
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());

    try registry.settleEventGenerationForTest(sibling.reservation, sibling.identity, sibling_event);
    try registry.beginBoundDrop(target.reservation, target.identity, 0x3B31);
    try registry.completeActiveDrop(target.reservation, target.identity, 0x3B31);
    try registry.beginBoundDrop(sibling.reservation, sibling.identity, 0x3B32);
    try registry.completeActiveDrop(sibling.reservation, sibling.identity, 0x3B32);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3b3 prepared registry release preflight는 receipt drift를 거부한다" {
    const ready = try ensureSettlementSealReadyForTest();
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3B32);
    const bound = try registry.reserve(fixtureSeed(0x3B3200, 0x3B3201));
    try registry.bindStream(bound.reservation, bound.identity, 0x3B33);
    const event = try registry.reserveEventGeneration(bound.reservation, bound.identity, 0x3B33, 0x3B3210);
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, event);
    try registry.beginEventPreparationPending(bound.reservation, bound.identity, event);
    const pending = try fixturePendingRegistryReceipt(ready, event, 0x3B3220, 13, 15, 17);
    const binding = try fixtureRegistrySettlementBinding(ready, pending.pending_owner_addr);
    var drift = pending;
    drift.event_identity.stream_id += 1;
    var permit: PreparedRegistryEventRelease = .{};
    var lease_drift = binding;
    lease_drift.ranges_digest[0] ^= 1;
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightPreparedEventRelease(
            bound.reservation,
            bound.identity,
            event,
            pending,
            lease_drift,
            &permit,
        ),
    );
    try std.testing.expect(std.meta.eql(permit, PreparedRegistryEventRelease{}));
    const aliased_permit: *PreparedRegistryEventRelease = @ptrFromInt(@intFromPtr(&registry));
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightPreparedEventRelease(
            bound.reservation,
            bound.identity,
            event,
            pending,
            binding,
            aliased_permit,
        ),
    );
    try std.testing.expect(std.meta.eql(permit, PreparedRegistryEventRelease{}));
    try std.testing.expectError(
        error.InvalidState,
        registry.preflightPreparedEventRelease(
            bound.reservation,
            bound.identity,
            event,
            drift,
            binding,
            &permit,
        ),
    );
    try std.testing.expect(std.meta.eql(permit, PreparedRegistryEventRelease{}));
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());

    try registry.preflightPreparedEventRelease(
        bound.reservation,
        bound.identity,
        event,
        pending,
        binding,
        &permit,
    );
    if (builtin.os.tag == .macos) {
        const proof_loss_child = std.c.fork();
        try std.testing.expect(proof_loss_child >= 0);
        if (proof_loss_child == 0) {
            _ = alarm(5);
            const raw_lifecycle: *u8 = @ptrCast(&registry.entries[bound.reservation.entry_index].event_authority.lifecycle);
            raw_lifecycle.* = 0xff;
            registry.beginPreparedEventReleaseNoFail(permit);
            std.c._exit(0);
        }
        var proof_loss_status: c_int = 0;
        try std.testing.expectEqual(proof_loss_child, std.c.waitpid(proof_loss_child, &proof_loss_status, 0));
        const proof_loss_raw: u32 = @bitCast(proof_loss_status);
        try std.testing.expect(std.c.W.IFEXITED(proof_loss_raw));
        try std.testing.expectEqual(@as(u8, 86), std.c.W.EXITSTATUS(proof_loss_raw));
    }
    registry.beginPreparedEventReleaseNoFail(permit);
    _ = registry.finishPreparedEventReleaseNoFail(permit);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    if (builtin.os.tag == .macos) {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            _ = alarm(5);
            registry.beginPreparedEventReleaseNoFail(permit);
            std.c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const raw_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFSIGNALED(raw_status) or std.c.W.EXITSTATUS(raw_status) != 0);
        try std.testing.expect(!(std.c.W.IFSIGNALED(raw_status) and std.c.W.TERMSIG(raw_status) == std.c.SIG.ALRM));
    }
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3B33);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3B33);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 stale and double settlement cannot change blocker cache" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A16);
    const bound = try registry.reserve(fixtureSeed(0x3A1600, 0x3A1601));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A16);
    const revoke = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A16,
        0x3A1610,
        .controller_revoke,
    );
    registry.commitEventGenerationPublicationNoFail(bound.reservation, bound.identity, revoke);
    var stale = revoke;
    stale.event_generation +%= 1;
    try std.testing.expect(!(try registry.eventGenerationCurrent(bound.reservation, bound.identity, stale)));
    try std.testing.expectError(
        error.InvalidState,
        registry.settleEventGenerationForTest(bound.reservation, bound.identity, stale),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try registry.settleEventGenerationForTest(bound.reservation, bound.identity, revoke);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try std.testing.expectError(
        error.InvalidState,
        registry.settleEventGenerationForTest(bound.reservation, bound.identity, revoke),
    );
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    const reincarnated = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A16,
        0x3A1610,
        .controller_revoke,
    );
    registry.commitEventGenerationPublicationNoFail(
        bound.reservation,
        bound.identity,
        reincarnated,
    );
    try std.testing.expectError(
        error.InvalidState,
        registry.settleEventGenerationForTest(bound.reservation, bound.identity, revoke),
    );
    try std.testing.expectEqual(@as(usize, 1), try registry.connectionOrderingBlockerCount());
    try registry.settleEventGenerationForTest(bound.reservation, bound.identity, reincarnated);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectionOrderingBlockerCount());
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A16);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A16);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "C3-3a1 cache bounds fail closed and test scan detects drift" {
    var registry: AttachmentCleanupRegistry = .{};
    try AttachmentCleanupRegistry.initInPlace(&registry, 0x2C3D_3A17);
    const bound = try registry.reserve(fixtureSeed(0x3A1700, 0x3A1701));
    try registry.bindStream(bound.reservation, bound.identity, 0x3A17);
    const revoke = try registry.reserveEventGenerationWithOrdering(
        bound.reservation,
        bound.identity,
        0x3A17,
        0x3A1710,
        .controller_revoke,
    );
    try std.testing.expect(try registry.validateConnectionOrderingBlockerCacheForTest());
    registry.connection_ordering_blocker_count = 0;
    try std.testing.expect(!(try registry.validateConnectionOrderingBlockerCacheForTest()));
    registry.connection_ordering_blocker_count = 1;
    registry.connection_ordering_blocker_count = max_entries + 1;
    try std.testing.expectError(error.MovedOrCopied, registry.connectionOrderingBlockerCount());
    registry.connection_ordering_blocker_count = 1;
    registry.rollbackEventGenerationBeforePublishNoFail(bound.reservation, bound.identity, revoke);
    try registry.beginBoundDrop(bound.reservation, bound.identity, 0x3A17);
    try registry.completeActiveDrop(bound.reservation, bound.identity, 0x3A17);
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}
