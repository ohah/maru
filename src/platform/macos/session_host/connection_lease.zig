//! CR3a cleanup-only connection lifetime capabilities.
//!
//! This leaf deliberately has no knowledge of `Client`, sockets, RPC, or screen transport.  A
//! product owner embeds `PinOwner` beside its final-address transport node and may then mint a
//! `ConnectionLease`.  The lease can only pin that exact node and authorize one cleanup permit;
//! it cannot admit I/O.  Keeping this type neutral makes an accidental live-transport escape a
//! compile-time dependency violation rather than a convention.

const std = @import("std");
const builtin = @import("builtin");
const settlement = @import("pending_event_settlement_contract.zig");
const process_seal = @import("process_seal_service.zig");

var cleanup_quarantine_events: std.atomic.Value(u64) = .init(0);

fn recordCleanupQuarantine() bool {
    var observed = cleanup_quarantine_events.load(.acquire);
    while (true) {
        if (observed == std.math.maxInt(u64)) return false;
        if (cleanup_quarantine_events.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        return true;
    }
}

pub const IdentityKind = enum(u1) {
    slot = 0,
    node = 1,
};

pub const Identity = struct {
    tagged: u64,

    pub fn kind(self: Identity) IdentityKind {
        return @enumFromInt(self.tagged & 1);
    }
};

/// One checked counter issues both slot and node identities.  Reservation happens before any
/// allocation so allocator failure and allocator callback reentry burn, but never reuse, an ID.
pub const IdentityIssuer = struct {
    next_ordinal: std.atomic.Value(u64) = .init(1),
    exhausted: std.atomic.Value(bool) = .init(false),
    pid: u32,
    process_nonce: u64,

    pub fn init(pid: u32, process_nonce: u64) IdentityIssuer {
        return .{ .pid = pid, .process_nonce = process_nonce };
    }

    pub fn reserve(self: *IdentityIssuer, kind_value: IdentityKind, current_pid: u32) error{
        IdentityExhausted,
        ProcessDomainMismatch,
    }!Identity {
        if (current_pid != self.pid) return error.ProcessDomainMismatch;
        if (self.exhausted.load(.acquire)) return error.IdentityExhausted;
        const max_ordinal = std.math.maxInt(u64) >> 1;
        var observed = self.next_ordinal.load(.acquire);
        while (true) {
            if (observed == 0 or observed > max_ordinal) {
                self.exhausted.store(true, .release);
                return error.IdentityExhausted;
            }
            const next = if (observed == max_ordinal) max_ordinal + 1 else observed + 1;
            if (self.next_ordinal.cmpxchgWeak(observed, next, .acq_rel, .acquire)) |actual| {
                observed = actual;
                continue;
            }
            if (observed == max_ordinal) self.exhausted.store(true, .release);
            return .{ .tagged = (observed << 1) | @intFromEnum(kind_value) };
        }
    }
};

pub const OwnerState = enum {
    live,
    terminal,
};

/// Embedded in the final heap node.  The address seal and incarnation prevent a copied lease from
/// pinning a same-address reincarnation after destroy/re-init.
pub const PinOwner = struct {
    self_addr: usize = 0,
    slot_addr: usize = 0,
    node_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    host_id: u128 = 0,
    connection_generation: u64 = 1,
    cleanup_pin_count: usize = 0,
    active_cleanup: u1 = 0,
    state: OwnerState = .live,
    pid: u32 = 0,
    process_nonce: u64 = 0,

    pub fn initInPlace(
        out: *PinOwner,
        slot_addr: usize,
        node_addr: usize,
        slot_incarnation: Identity,
        node_incarnation: Identity,
        host_id: u128,
        pid: u32,
        process_nonce: u64,
    ) void {
        initInPlaceForGeneration(
            out,
            slot_addr,
            node_addr,
            slot_incarnation,
            node_incarnation,
            host_id,
            1,
            pid,
            process_nonce,
        );
    }

    pub fn initInPlaceForGeneration(
        out: *PinOwner,
        slot_addr: usize,
        node_addr: usize,
        slot_incarnation: Identity,
        node_incarnation: Identity,
        host_id: u128,
        connection_generation: u64,
        pid: u32,
        process_nonce: u64,
    ) void {
        std.debug.assert(connection_generation != 0);
        out.* = .{
            .self_addr = @intFromPtr(out),
            .slot_addr = slot_addr,
            .node_addr = node_addr,
            .slot_incarnation = slot_incarnation.tagged,
            .node_incarnation = node_incarnation.tagged,
            .host_id = host_id,
            .connection_generation = connection_generation,
            .pid = pid,
            .process_nonce = process_nonce,
        };
    }

    pub fn valid(self: *const PinOwner, current_pid: u32) bool {
        return self.self_addr == @intFromPtr(self) and
            self.slot_addr != 0 and
            self.node_addr != 0 and
            self.slot_incarnation != 0 and
            self.node_incarnation != 0 and
            (Identity{ .tagged = self.slot_incarnation }).kind() == .slot and
            (Identity{ .tagged = self.node_incarnation }).kind() == .node and
            self.host_id != 0 and
            self.connection_generation != 0 and
            self.pid == current_pid and
            self.process_nonce != 0;
    }
};

pub const LeaseLifecycle = enum {
    empty,
    live,
    release_reserved,
    released,
    terminal,
};

pub const ReleaseOutcome = enum {
    released,
    busy,
    terminal,
    corrupt,
};

pub const CanonicalPinProjection = struct {
    pin_owner_addr: usize,
    lease_addr: usize,
    slot_addr: usize,
    node_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    stream_id: u64,
    pid: u32,
    process_nonce: u64,
};

pub const PreparedPinRelease = struct {
    self_addr: usize = 0,
    projection: CanonicalPinProjection = undefined,
    consumed: bool = false,
};

pub fn reserveCanonicalPin(
    pin_owner: *PinOwner,
    lease_addr: usize,
    stream_id: u64,
    current_pid: u32,
) error{ InvalidOwner, InvalidStream, PinOverflow }!CanonicalPinProjection {
    if (lease_addr == 0 or stream_id == 0) return error.InvalidStream;
    if (!pin_owner.valid(current_pid) or pin_owner.state != .live) return error.InvalidOwner;
    if (pin_owner.cleanup_pin_count == std.math.maxInt(usize)) return error.PinOverflow;
    pin_owner.cleanup_pin_count += 1;
    return projectionFor(pin_owner, lease_addr, stream_id);
}

pub fn rollbackCanonicalPinUnchecked(
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    current_pid: u32,
) void {
    if (!projectionMatches(projection, pin_owner, current_pid) or
        pin_owner.active_cleanup != 0 or pin_owner.cleanup_pin_count == 0)
        @panic("canonical event pin rollback drifted");
    pin_owner.cleanup_pin_count -= 1;
}

pub fn prepareCanonicalPinRelease(
    lease: *ConnectionLease,
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    out: *PreparedPinRelease,
    current_pid: u32,
) bool {
    if (out.self_addr != 0 or out.consumed or !projectionMatches(projection, pin_owner, current_pid) or
        projection.lease_addr != @intFromPtr(lease) or !lease.canRelease(current_pid) or
        pin_owner.active_cleanup != 0)
        return false;
    pin_owner.active_cleanup = 1;
    out.* = .{ .self_addr = @intFromPtr(out), .projection = projection };
    return true;
}

pub fn commitPreparedPinReleaseUnchecked(
    prepared: *PreparedPinRelease,
    pin_owner: *PinOwner,
    current_pid: u32,
) void {
    if (prepared.self_addr != @intFromPtr(prepared) or prepared.consumed or
        !projectionMatches(prepared.projection, pin_owner, current_pid) or
        pin_owner.active_cleanup != 1 or pin_owner.cleanup_pin_count == 0)
        @panic("prepared canonical event pin release drifted");
    pin_owner.cleanup_pin_count -= 1;
    pin_owner.active_cleanup = 0;
    prepared.consumed = true;
}

pub fn abortPreparedPinReleaseUnchecked(
    prepared: *PreparedPinRelease,
    pin_owner: *PinOwner,
    current_pid: u32,
) void {
    if (prepared.self_addr != @intFromPtr(prepared) or prepared.consumed or
        !projectionMatches(prepared.projection, pin_owner, current_pid) or
        pin_owner.active_cleanup != 1)
        @panic("prepared canonical event pin abort drifted");
    pin_owner.active_cleanup = 0;
    prepared.* = .{};
}

pub fn consumeCanonicalPinUnchecked(
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    current_pid: u32,
) void {
    if (!projectionMatches(projection, pin_owner, current_pid) or
        pin_owner.active_cleanup != 0 or pin_owner.cleanup_pin_count == 0)
        @panic("canonical event pin recovery drifted");
    pin_owner.cleanup_pin_count -= 1;
}

/// 자체 registered operation으로 node를 이미 직렬화한 composite owner의 read-only 최종 조건이다.
/// `active_cleanup`을 reserve하지 않으며 caller는 바로 이어지는 no-fail suffix에서
/// `consumeCanonicalPinUnchecked`로 소비해야 한다.
pub fn canonicalPinReleaseReady(
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    current_pid: u32,
) bool {
    if (!projectionMatches(projection, pin_owner, current_pid) or
        pin_owner.active_cleanup != 0 or pin_owner.cleanup_pin_count == 0)
        return false;
    const lease: *const ConnectionLease = @ptrFromInt(projection.lease_addr);
    return lease.canRelease(current_pid);
}

pub fn canonicalPinConsumed(
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    count_before: usize,
    current_pid: u32,
) bool {
    if (!projectionMatches(projection, pin_owner, current_pid) or count_before == 0 or
        pin_owner.active_cleanup != 0) return false;
    return pin_owner.cleanup_pin_count == count_before - 1;
}

pub fn consumeCanonicalPinWithReceiptUnchecked(
    projection: CanonicalPinProjection,
    pin_owner: *PinOwner,
    current_pid: u32,
) settlement.EventReleaseLeafReceipt {
    const count_before = pin_owner.cleanup_pin_count;
    consumeCanonicalPinUnchecked(projection, pin_owner, current_pid);
    const ready = process_seal.currentReadyIdentity() catch process_seal.fatalIntegrity(.proof_loss);
    var receipt: settlement.EventReleaseLeafReceipt = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .role_raw = @intFromEnum(settlement.EventReleaseLeafRole.pin),
        .identity_a = projection.pin_owner_addr,
        .identity_b = projection.lease_addr,
        .identity_c = projection.node_incarnation,
        .identity_d = projection.stream_id,
        .identity_e = projection.slot_addr,
        .identity_f = projection.connection_generation,
        .before_a = count_before,
        .after_a = pin_owner.cleanup_pin_count,
    };
    receipt.seal = settlement.sealEventReleaseLeafReceipt(receipt) catch
        process_seal.fatalIntegrity(.proof_loss);
    return receipt;
}

fn projectionFor(
    pin_owner: *const PinOwner,
    lease_addr: usize,
    stream_id: u64,
) CanonicalPinProjection {
    return .{
        .pin_owner_addr = @intFromPtr(pin_owner),
        .lease_addr = lease_addr,
        .slot_addr = pin_owner.slot_addr,
        .node_addr = pin_owner.node_addr,
        .slot_incarnation = pin_owner.slot_incarnation,
        .node_incarnation = pin_owner.node_incarnation,
        .host_id = pin_owner.host_id,
        .connection_generation = pin_owner.connection_generation,
        .stream_id = stream_id,
        .pid = pin_owner.pid,
        .process_nonce = pin_owner.process_nonce,
    };
}

fn projectionMatches(
    projection: CanonicalPinProjection,
    pin_owner: *const PinOwner,
    current_pid: u32,
) bool {
    return pin_owner.valid(current_pid) and pin_owner.state == .live and
        projection.pin_owner_addr == @intFromPtr(pin_owner) and projection.lease_addr != 0 and
        projection.slot_addr == pin_owner.slot_addr and projection.node_addr == pin_owner.node_addr and
        projection.slot_incarnation == pin_owner.slot_incarnation and
        projection.node_incarnation == pin_owner.node_incarnation and
        projection.host_id == pin_owner.host_id and
        projection.connection_generation == pin_owner.connection_generation and
        projection.stream_id != 0 and projection.pid == current_pid and
        projection.pid == pin_owner.pid and projection.process_nonce == pin_owner.process_nonce;
}

pub const ConnectionLease = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    canonical_owner_addr: usize = 0,
    slot_addr: usize = 0,
    node_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    host_id: u128 = 0,
    connection_generation: u64 = 0,
    stream_id: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    lifecycle: LeaseLifecycle = .empty,
    active_cleanup: ActiveCleanupReceipt = .{},

    const ActiveCleanupReceipt = struct {
        permit_addr: usize = 0,
        token_digest: u64 = 0,
        reservation_id: u64 = 0,
        stream_id: u64 = 0,
        kind: CleanupKind = .release,

        fn clear(self: *ActiveCleanupReceipt) void {
            self.* = .{};
        }
    };

    /// Reads only the embedded lease's scalar bytes. It deliberately does not follow owner_addr or
    /// canonical_owner_addr: callers must compare the result with a separately authenticated
    /// PinOwner projection before treating the lease as valid cleanup input.
    pub fn scalarProjectionForValidation(
        self: *const ConnectionLease,
        current_pid: u32,
    ) ?CanonicalPinProjection {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        if (lifecycle_raw > @intFromEnum(LeaseLifecycle.terminal) or
            self.lifecycle != .live or self.self_addr != @intFromPtr(self) or
            self.owner_addr == 0 or self.owner_addr != self.canonical_owner_addr or
            self.slot_addr == 0 or self.node_addr == 0 or
            self.slot_incarnation == 0 or self.node_incarnation == 0 or
            self.host_id == 0 or self.connection_generation == 0 or self.stream_id == 0 or
            self.pid != current_pid or self.process_nonce == 0 or
            !std.mem.allEqual(u8, std.mem.asBytes(&self.active_cleanup), 0))
            return null;
        return .{
            .pin_owner_addr = self.canonical_owner_addr,
            .lease_addr = @intFromPtr(self),
            .slot_addr = self.slot_addr,
            .node_addr = self.node_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .connection_generation = self.connection_generation,
            .stream_id = self.stream_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        };
    }

    pub fn initInPlace(
        out: *ConnectionLease,
        pin_owner: *PinOwner,
        stream_id: u64,
        current_pid: u32,
    ) error{ InvalidOwner, InvalidStream, PinOverflow, DestinationOccupied }!void {
        if (out.lifecycle != .empty or out.self_addr != 0) return error.DestinationOccupied;
        if (stream_id == 0) return error.InvalidStream;
        if (!pin_owner.valid(current_pid) or pin_owner.state != .live) return error.InvalidOwner;
        if (pin_owner.cleanup_pin_count == std.math.maxInt(usize)) return error.PinOverflow;
        pin_owner.cleanup_pin_count += 1;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_addr = @intFromPtr(pin_owner),
            .canonical_owner_addr = @intFromPtr(pin_owner),
            .slot_addr = pin_owner.slot_addr,
            .node_addr = pin_owner.node_addr,
            .slot_incarnation = pin_owner.slot_incarnation,
            .node_incarnation = pin_owner.node_incarnation,
            .host_id = pin_owner.host_id,
            .connection_generation = pin_owner.connection_generation,
            .stream_id = stream_id,
            .pid = pin_owner.pid,
            .process_nonce = pin_owner.process_nonce,
            .lifecycle = .live,
        };
    }

    /// Publishes a lease for a pin that ClientSlot already reserved before the attach RPC. The
    /// caller must run `canInitFromReservedPin` before mutating its registry entry; the unchecked
    /// suffix neither allocates nor changes `cleanup_pin_count`.
    pub fn canInitFromReservedPin(
        out: *const ConnectionLease,
        pin_owner: *const PinOwner,
        stream_id: u64,
        current_pid: u32,
    ) bool {
        return out.lifecycle == .empty and out.self_addr == 0 and
            stream_id != 0 and pin_owner.valid(current_pid) and
            pin_owner.state == .live and pin_owner.cleanup_pin_count != 0;
    }

    pub fn initFromReservedPinUnchecked(
        out: *ConnectionLease,
        pin_owner: *PinOwner,
        stream_id: u64,
        current_pid: u32,
    ) void {
        if (!canInitFromReservedPin(out, pin_owner, stream_id, current_pid))
            @panic("invalid pre-reserved connection lease publication");
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_addr = @intFromPtr(pin_owner),
            .canonical_owner_addr = @intFromPtr(pin_owner),
            .slot_addr = pin_owner.slot_addr,
            .node_addr = pin_owner.node_addr,
            .slot_incarnation = pin_owner.slot_incarnation,
            .node_incarnation = pin_owner.node_incarnation,
            .host_id = pin_owner.host_id,
            .connection_generation = pin_owner.connection_generation,
            .stream_id = stream_id,
            .pid = pin_owner.pid,
            .process_nonce = pin_owner.process_nonce,
            .lifecycle = .live,
        };
    }

    fn owner(self: *const ConnectionLease, current_pid: u32) ?*PinOwner {
        if (self.self_addr != @intFromPtr(self) or self.owner_addr == 0 or
            self.owner_addr != self.canonical_owner_addr or
            self.pid != current_pid or self.process_nonce == 0)
            return null;
        const value: *PinOwner = @ptrFromInt(self.canonical_owner_addr);
        if (!value.valid(current_pid) or value.slot_addr != self.slot_addr or
            value.slot_incarnation != self.slot_incarnation or
            value.node_addr != self.node_addr or
            value.node_incarnation != self.node_incarnation or
            value.host_id != self.host_id or
            value.connection_generation != self.connection_generation or
            value.process_nonce != self.process_nonce)
            return null;
        return value;
    }

    pub fn release(self: *ConnectionLease, current_pid: u32) ReleaseOutcome {
        // A copied lease is not registered at this address and must not consume the original pin.
        if (self.self_addr != @intFromPtr(self) or self.pid != current_pid) return .corrupt;
        if (self.lifecycle == .released) return .terminal;
        if (self.lifecycle != .live) return if (self.lifecycle == .terminal) .terminal else .corrupt;
        const pin_owner = self.owner(current_pid) orelse {
            self.lifecycle = .terminal;
            return .corrupt;
        };
        if (pin_owner.active_cleanup != 0 or self.active_cleanup.permit_addr != 0) return .busy;
        if (pin_owner.cleanup_pin_count == 0) {
            self.lifecycle = .terminal;
            return .corrupt;
        }
        self.lifecycle = .release_reserved;
        pin_owner.cleanup_pin_count -= 1;
        self.lifecycle = .released;
        return .released;
    }

    pub fn canRelease(self: *const ConnectionLease, current_pid: u32) bool {
        if (self.self_addr != @intFromPtr(self) or self.pid != current_pid or
            self.lifecycle != .live or self.active_cleanup.permit_addr != 0)
            return false;
        const pin_owner = self.owner(current_pid) orelse return false;
        return pin_owner.active_cleanup == 0 and pin_owner.cleanup_pin_count != 0;
    }

    /// Owner-specific no-fail suffix after ClientSlot has already preflighted this exact lease and
    /// published `PinOwner.active_cleanup=1`. General callers must use `release` instead.
    pub fn releaseDuringActiveCleanupUnchecked(
        self: *ConnectionLease,
        expected_owner: *PinOwner,
        current_pid: u32,
    ) void {
        const pin_owner = self.owner(current_pid) orelse
            @panic("active cleanup lease lost its owner");
        if (pin_owner != expected_owner or pin_owner.active_cleanup != 1 or
            self.lifecycle != .live or self.active_cleanup.permit_addr != 0 or
            pin_owner.cleanup_pin_count == 0)
            @panic("invalid active cleanup lease release");
        self.lifecycle = .release_reserved;
        pin_owner.cleanup_pin_count -= 1;
        self.lifecycle = .released;
    }

    /// Parent-owned recovery for a permit whose public bytes were moved, spliced, or corrupted.
    /// It trusts only the receipt sealed before publication and therefore never reads the damaged
    /// permit or token.  The owner-specific adapter uses the same receipt identity to roll its
    /// canonical reservation back before calling this neutral suffix.
    fn canRecoverInvalidPermit(self: *ConnectionLease, permit_addr: usize, current_pid: u32) bool {
        const pin_owner = self.owner(current_pid) orelse return false;
        return self.lifecycle == .live and self.active_cleanup.permit_addr != 0 and
            self.active_cleanup.permit_addr == permit_addr and pin_owner.active_cleanup == 1;
    }

    fn commitInvalidPermitRecovery(self: *ConnectionLease, permit_addr: usize, current_pid: u32) void {
        if (!self.canRecoverInvalidPermit(permit_addr, current_pid))
            @panic("invalid cleanup receipt recovery commit");
        const pin_owner = self.owner(current_pid).?;
        pin_owner.active_cleanup = 0;
        self.active_cleanup.clear();
    }
};

pub const CleanupKind = enum {
    release,
    drop,
    cancel,
};

pub const CleanupVerdict = enum {
    completed,
    retryable_preserved,
    indeterminate_or_partial,
};

pub const PermitLifecycle = enum {
    empty,
    prepared,
    consumed,
    aborted,
    terminal,
};

/// A final-address one-shot permit.  `opaque_token_digest` is deliberately only a scalar digest;
/// the transport-specific owner remains outside this neutral module.
pub const CleanupPermit = struct {
    self_addr: usize = 0,
    lease_addr: usize = 0,
    owner_addr: usize = 0,
    lease_self_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    stream_id: u64 = 0,
    kind: CleanupKind = .release,
    opaque_token_digest: u64 = 0,
    reservation_id: u64 = 0,
    lifecycle: PermitLifecycle = .empty,

    fn prepareInPlace(
        out: *CleanupPermit,
        lease: *ConnectionLease,
        kind_value: CleanupKind,
        opaque_token_digest: u64,
        reservation_id: u64,
        current_pid: u32,
    ) error{ DestinationOccupied, InvalidLease, InvalidToken, Busy }!void {
        if (out.lifecycle != .empty or out.self_addr != 0) return error.DestinationOccupied;
        if (opaque_token_digest == 0 or reservation_id == 0) return error.InvalidToken;
        const pin_owner = lease.owner(current_pid) orelse return error.InvalidLease;
        if (lease.lifecycle != .live) return error.InvalidLease;
        if (pin_owner.active_cleanup != 0 or lease.active_cleanup.permit_addr != 0) return error.Busy;
        pin_owner.active_cleanup = 1;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lease_addr = @intFromPtr(lease),
            .owner_addr = @intFromPtr(pin_owner),
            .lease_self_addr = lease.self_addr,
            .slot_incarnation = lease.slot_incarnation,
            .node_incarnation = lease.node_incarnation,
            .stream_id = lease.stream_id,
            .kind = kind_value,
            .opaque_token_digest = opaque_token_digest,
            .reservation_id = reservation_id,
            .lifecycle = .prepared,
        };
        lease.active_cleanup = .{
            .permit_addr = @intFromPtr(out),
            .token_digest = opaque_token_digest,
            .reservation_id = reservation_id,
            .stream_id = lease.stream_id,
            .kind = kind_value,
        };
    }

    fn validate(self: *const CleanupPermit, current_pid: u32) ?*PinOwner {
        if (self.lifecycle != .prepared or self.self_addr != @intFromPtr(self) or
            self.lease_addr == 0 or self.owner_addr == 0)
            return null;
        const lease: *ConnectionLease = @ptrFromInt(self.lease_addr);
        if (lease.self_addr != self.lease_self_addr or lease.self_addr != @intFromPtr(lease) or
            lease.slot_incarnation != self.slot_incarnation or
            lease.node_incarnation != self.node_incarnation or
            lease.stream_id != self.stream_id or lease.lifecycle != .live)
            return null;
        if (lease.active_cleanup.permit_addr != @intFromPtr(self) or
            lease.active_cleanup.token_digest != self.opaque_token_digest or
            lease.active_cleanup.reservation_id != self.reservation_id or
            lease.active_cleanup.stream_id != self.stream_id or
            lease.active_cleanup.kind != self.kind)
            return null;
        const pin_owner = lease.owner(current_pid) orelse return null;
        if (@intFromPtr(pin_owner) != self.owner_addr or pin_owner.active_cleanup != 1) return null;
        return pin_owner;
    }

    fn finish(self: *CleanupPermit, verdict: CleanupVerdict, current_pid: u32) bool {
        const pin_owner = self.validate(current_pid) orelse {
            self.lifecycle = .terminal;
            return false;
        };
        pin_owner.active_cleanup = 0;
        const lease: *ConnectionLease = @ptrFromInt(self.lease_addr);
        lease.active_cleanup.clear();
        switch (verdict) {
            .completed => self.lifecycle = .consumed,
            .retryable_preserved => self.lifecycle = .terminal,
            .indeterminate_or_partial => {
                pin_owner.state = .terminal;
                self.lifecycle = .terminal;
            },
        }
        return true;
    }

    fn abort(self: *CleanupPermit, current_pid: u32) bool {
        const pin_owner = self.validate(current_pid) orelse {
            self.lifecycle = .terminal;
            return false;
        };
        pin_owner.active_cleanup = 0;
        const lease: *ConnectionLease = @ptrFromInt(self.lease_addr);
        lease.active_cleanup.clear();
        self.lifecycle = .aborted;
        return true;
    }
};

const cleanup_owner_capacity: usize = 4;

const CleanupEntryState = enum {
    empty,
    available,
    reserved,
    consumed,
    terminal,
};

const CleanupEntry = struct {
    token_digest: u64 = 0,
    stream_id: u64 = 0,
    kind: CleanupKind = .release,
    state: CleanupEntryState = .empty,
    reservation_id: u64 = 0,
};

const PrepareResult = enum {
    prepared,
    busy,
    terminal,
    capacity_exhausted,
};

const FinishResult = enum {
    completed,
    retryable_preserved,
    terminal,
    corrupt,
};

/// CR3a-1 component oracle for the closed canonical-owner contract.  Product code cannot name this
/// type; CR3a-2's owner-specific adapter must project an existing bounded ledger into the same
/// transitions rather than instantiate a second cleanup ledger.
const CleanupOwner = struct {
    self_addr: usize = 0,
    entries: [cleanup_owner_capacity]CleanupEntry = [_]CleanupEntry{.{}} ** cleanup_owner_capacity,
    next_reservation_id: u64 = 1,
    reservation_exhausted: bool = false,
    quarantined: bool = false,
    quarantined_owner_addr: usize = 0,
    quarantined_reservation_id: u64 = 0,

    fn initInPlace(out: *CleanupOwner) void {
        out.* = .{ .self_addr = @intFromPtr(out) };
    }

    fn addAvailable(
        self: *CleanupOwner,
        token_digest: u64,
        stream_id: u64,
        kind: CleanupKind,
    ) PrepareResult {
        if (self.quarantined or self.self_addr != @intFromPtr(self) or token_digest == 0 or stream_id == 0)
            return .terminal;
        for (&self.entries) |*entry| {
            if (entry.state != .empty) {
                if (entry.token_digest == token_digest) return .terminal;
                continue;
            }
            entry.* = .{
                .token_digest = token_digest,
                .stream_id = stream_id,
                .kind = kind,
                .state = .available,
            };
            return .prepared;
        }
        return .capacity_exhausted;
    }

    fn preparePermit(
        self: *CleanupOwner,
        out: *CleanupPermit,
        lease: *ConnectionLease,
        token_digest: u64,
        kind: CleanupKind,
        current_pid: u32,
    ) PrepareResult {
        if (self.quarantined or self.self_addr != @intFromPtr(self)) return .terminal;
        const entry = self.find(token_digest) orelse return .terminal;
        if (entry.stream_id != lease.stream_id or entry.kind != kind) return .terminal;
        switch (entry.state) {
            .reserved => return .busy,
            .consumed, .terminal, .empty => return .terminal,
            .available => {},
        }
        const reservation_id = self.reserveReservationId() orelse return .capacity_exhausted;
        entry.state = .reserved;
        entry.reservation_id = reservation_id;
        CleanupPermit.prepareInPlace(
            out,
            lease,
            kind,
            token_digest,
            reservation_id,
            current_pid,
        ) catch |err| {
            entry.state = .available;
            entry.reservation_id = 0;
            return switch (err) {
                error.Busy => .busy,
                else => .terminal,
            };
        };
        return .prepared;
    }

    fn finishPermit(
        self: *CleanupOwner,
        lease: *ConnectionLease,
        permit: *CleanupPermit,
        verdict: CleanupVerdict,
        current_pid: u32,
    ) FinishResult {
        if (self.quarantined or self.self_addr != @intFromPtr(self)) return .corrupt;
        const receipt = lease.active_cleanup;
        const entry = self.find(receipt.token_digest) orelse return self.quarantine(receipt.reservation_id);
        if (entry.state != .reserved or receipt.permit_addr != @intFromPtr(permit) or
            receipt.stream_id != entry.stream_id or receipt.kind != entry.kind or
            receipt.reservation_id == 0 or receipt.reservation_id != entry.reservation_id)
            return self.quarantine(receipt.reservation_id);
        if (!permitMatchesLease(permit, lease)) {
            if (!lease.canRecoverInvalidPermit(@intFromPtr(permit), current_pid))
                return self.quarantine(receipt.reservation_id);
            lease.commitInvalidPermitRecovery(@intFromPtr(permit), current_pid);
            entry.state = .available;
            entry.reservation_id = 0;
            permit.lifecycle = .terminal;
            return .corrupt;
        }
        if (!permit.finish(verdict, current_pid)) return self.quarantine(receipt.reservation_id);
        return switch (verdict) {
            .completed => blk: {
                entry.state = .consumed;
                entry.reservation_id = 0;
                break :blk .completed;
            },
            .retryable_preserved => blk: {
                entry.state = .available;
                entry.reservation_id = 0;
                break :blk .retryable_preserved;
            },
            .indeterminate_or_partial => blk: {
                entry.state = .terminal;
                entry.reservation_id = 0;
                break :blk .terminal;
            },
        };
    }

    fn abortPermit(
        self: *CleanupOwner,
        lease: *ConnectionLease,
        permit: *CleanupPermit,
        current_pid: u32,
    ) bool {
        if (self.quarantined or self.self_addr != @intFromPtr(self)) return false;
        const receipt = lease.active_cleanup;
        const entry = self.find(receipt.token_digest) orelse {
            _ = self.quarantine(receipt.reservation_id);
            return false;
        };
        if (entry.state != .reserved or receipt.permit_addr != @intFromPtr(permit) or
            receipt.reservation_id == 0 or receipt.reservation_id != entry.reservation_id)
        {
            _ = self.quarantine(receipt.reservation_id);
            return false;
        }
        if (!permitMatchesLease(permit, lease)) {
            if (!lease.canRecoverInvalidPermit(@intFromPtr(permit), current_pid)) {
                _ = self.quarantine(receipt.reservation_id);
                return false;
            }
            lease.commitInvalidPermitRecovery(@intFromPtr(permit), current_pid);
            entry.state = .available;
            entry.reservation_id = 0;
            permit.lifecycle = .terminal;
            return false;
        }
        if (!permit.abort(current_pid)) {
            _ = self.quarantine(receipt.reservation_id);
            return false;
        }
        entry.state = .available;
        entry.reservation_id = 0;
        return true;
    }

    fn find(self: *CleanupOwner, token_digest: u64) ?*CleanupEntry {
        for (&self.entries) |*entry|
            if (entry.state != .empty and entry.token_digest == token_digest) return entry;
        return null;
    }

    fn permitMatchesLease(permit: *const CleanupPermit, lease: *const ConnectionLease) bool {
        return permit.self_addr == @intFromPtr(permit) and
            permit.lease_addr == @intFromPtr(lease) and
            permit.owner_addr == lease.canonical_owner_addr and
            permit.lease_self_addr == lease.self_addr and
            permit.slot_incarnation == lease.slot_incarnation and
            permit.node_incarnation == lease.node_incarnation and
            permit.stream_id == lease.stream_id and
            permit.opaque_token_digest == lease.active_cleanup.token_digest and
            permit.reservation_id == lease.active_cleanup.reservation_id and
            permit.kind == lease.active_cleanup.kind and
            permit.lifecycle == .prepared;
    }

    fn reserveReservationId(self: *CleanupOwner) ?u64 {
        if (self.reservation_exhausted or self.next_reservation_id == 0) return null;
        const value = self.next_reservation_id;
        if (value == std.math.maxInt(u64)) {
            self.reservation_exhausted = true;
        } else {
            self.next_reservation_id = value + 1;
        }
        return value;
    }

    fn quarantine(self: *CleanupOwner, reservation_id: u64) FinishResult {
        if (!self.quarantined) {
            self.quarantined = true;
            self.quarantined_owner_addr = @intFromPtr(self);
            self.quarantined_reservation_id = reservation_id;
            if (!recordCleanupQuarantine())
                @panic("cleanup quarantine counter exhausted");
        }
        return .terminal;
    }
};

test "identity issuer uses one tagged burn-on-reserve counter and sticks at exhaustion" {
    var issuer = IdentityIssuer.init(7, 9);
    const slot = try issuer.reserve(.slot, 7);
    const node = try issuer.reserve(.node, 7);
    try std.testing.expect(slot.tagged != 0 and node.tagged != 0);
    try std.testing.expectEqual(IdentityKind.slot, slot.kind());
    try std.testing.expectEqual(IdentityKind.node, node.kind());
    try std.testing.expect(node.tagged > slot.tagged);
    try std.testing.expectError(error.ProcessDomainMismatch, issuer.reserve(.slot, 8));

    issuer.next_ordinal.store(std.math.maxInt(u64) >> 1, .release);
    _ = try issuer.reserve(.slot, 7);
    try std.testing.expectError(error.IdentityExhausted, issuer.reserve(.node, 7));
    try std.testing.expectError(error.IdentityExhausted, issuer.reserve(.slot, 7));
}

test "lease and cleanup permit reject copies replay and active-cleanup release" {
    const pid: u32 = 11;
    var owner: PinOwner = .{};
    PinOwner.initInPlace(
        &owner,
        0x1000,
        0x2000,
        .{ .tagged = 2 },
        .{ .tagged = 5 },
        0xCAFE,
        pid,
        99,
    );
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &owner, 41, pid);
    try std.testing.expectEqual(@as(usize, 1), owner.cleanup_pin_count);

    var permit: CleanupPermit = .{};
    try CleanupPermit.prepareInPlace(&permit, &lease, .release, 0xDEAD, 1, pid);
    try std.testing.expectEqual(ReleaseOutcome.busy, lease.release(pid));
    var copied = permit;
    try std.testing.expect(!copied.finish(.completed, pid));
    try std.testing.expectEqual(@as(u1, 1), owner.active_cleanup);
    try std.testing.expect(permit.finish(.retryable_preserved, pid));
    try std.testing.expectEqual(@as(u1, 0), owner.active_cleanup);
    try std.testing.expect(!permit.finish(.completed, pid));
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
    try std.testing.expectEqual(@as(usize, 0), owner.cleanup_pin_count);
    try std.testing.expectEqual(ReleaseOutcome.terminal, lease.release(pid));
}

test "lease rejects same-address reincarnation and pin overflow without mutation" {
    const pid: u32 = 3;
    var owner: PinOwner = .{};
    PinOwner.initInPlace(&owner, 9, 10, .{ .tagged = 2 }, .{ .tagged = 3 }, 4, pid, 5);
    owner.cleanup_pin_count = std.math.maxInt(usize);
    var overflow: ConnectionLease = .{};
    try std.testing.expectError(error.PinOverflow, ConnectionLease.initInPlace(&overflow, &owner, 1, pid));
    try std.testing.expectEqual(std.math.maxInt(usize), owner.cleanup_pin_count);
    try std.testing.expectEqual(LeaseLifecycle.empty, overflow.lifecycle);

    owner.cleanup_pin_count = 0;
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &owner, 1, pid);
    owner.node_incarnation = 7;
    try std.testing.expectEqual(ReleaseOutcome.corrupt, lease.release(pid));
    try std.testing.expectEqual(@as(usize, 1), owner.cleanup_pin_count);
    try std.testing.expectEqual(OwnerState.live, owner.state);
}

test "CR3a-2a pre-reserved pin transfers into lease without a second increment" {
    const pid: u32 = 149;
    var owner: PinOwner = undefined;
    PinOwner.initInPlace(&owner, 150, 151, .{ .tagged = 2 }, .{ .tagged = 3 }, 152, pid, 153);
    owner.cleanup_pin_count = 1;
    var lease: ConnectionLease = .{};
    try std.testing.expect(ConnectionLease.canInitFromReservedPin(&lease, &owner, 154, pid));
    ConnectionLease.initFromReservedPinUnchecked(&lease, &owner, 154, pid);
    try std.testing.expectEqual(@as(usize, 1), owner.cleanup_pin_count);
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
    try std.testing.expectEqual(@as(usize, 0), owner.cleanup_pin_count);
}

test "closed cleanup owner rejects sequential replay and exposes bounded capacity" {
    const pid: u32 = 13;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(
        &pin_owner,
        20,
        21,
        .{ .tagged = 2 },
        .{ .tagged = 3 },
        22,
        pid,
        23,
    );
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 24, pid);
    defer _ = lease.release(pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(1, 24, .drop));
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(2, 24, .release));
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(3, 24, .cancel));
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(4, 24, .drop));
    try std.testing.expectEqual(PrepareResult.capacity_exhausted, owner.addAvailable(5, 24, .drop));

    var first: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&first, &lease, 1, .drop, pid));
    var simultaneous: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.busy, owner.preparePermit(&simultaneous, &lease, 1, .drop, pid));
    try std.testing.expectEqual(FinishResult.completed, owner.finishPermit(&lease, &first, .completed, pid));
    var replay: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.terminal, owner.preparePermit(&replay, &lease, 1, .drop, pid));
}

test "closed cleanup owner rolls malformed permit back from the trusted parent receipt" {
    const pid: u32 = 14;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(
        &pin_owner,
        30,
        31,
        .{ .tagged = 2 },
        .{ .tagged = 3 },
        32,
        pid,
        33,
    );
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 34, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(6, 34, .release));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 6, .release, pid));
    permit.node_incarnation +%= 2;
    try std.testing.expectEqual(FinishResult.corrupt, owner.finishPermit(&lease, &permit, .completed, pid));
    try std.testing.expectEqual(@as(u1, 0), pin_owner.active_cleanup);
    try std.testing.expectEqual(@as(usize, 0), lease.active_cleanup.permit_addr);
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(6).?.state);
    var retry: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&retry, &lease, 6, .release, pid));
    try std.testing.expect(owner.abortPermit(&lease, &retry, pid));
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(6).?.state);
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "lease foreign-owner splice rejects without consuming either lifetime pin" {
    const pid: u32 = 15;
    var first_owner: PinOwner = .{};
    var second_owner: PinOwner = .{};
    PinOwner.initInPlace(&first_owner, 40, 41, .{ .tagged = 2 }, .{ .tagged = 3 }, 42, pid, 43);
    PinOwner.initInPlace(&second_owner, 50, 51, .{ .tagged = 4 }, .{ .tagged = 5 }, 52, pid, 53);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &first_owner, 44, pid);
    lease.owner_addr = @intFromPtr(&second_owner);
    try std.testing.expectEqual(ReleaseOutcome.corrupt, lease.release(pid));
    try std.testing.expectEqual(@as(usize, 1), first_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), second_owner.cleanup_pin_count);
    try std.testing.expectEqual(OwnerState.live, first_owner.state);

    // Even a coordinated splice to a different valid owner must not infer cleanup authority from
    // an address.  A strict product wrapper fail-stops; this low-level oracle proves mutation 0.
    var foreign_lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&foreign_lease, &first_owner, 45, pid);
    foreign_lease.owner_addr = @intFromPtr(&second_owner);
    foreign_lease.canonical_owner_addr = @intFromPtr(&second_owner);
    try std.testing.expectEqual(ReleaseOutcome.corrupt, foreign_lease.release(pid));
    try std.testing.expectEqual(@as(usize, 2), first_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), second_owner.cleanup_pin_count);
}

test "canonical owner rejects a permit spliced to another valid lease before dereference" {
    const pid: u32 = 16;
    var first_owner: PinOwner = .{};
    var second_owner: PinOwner = .{};
    PinOwner.initInPlace(&first_owner, 60, 61, .{ .tagged = 2 }, .{ .tagged = 3 }, 62, pid, 63);
    PinOwner.initInPlace(&second_owner, 70, 71, .{ .tagged = 4 }, .{ .tagged = 5 }, 72, pid, 73);
    var first_lease: ConnectionLease = .{};
    var second_lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&first_lease, &first_owner, 64, pid);
    try ConnectionLease.initInPlace(&second_lease, &second_owner, 74, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(8, 64, .cancel));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &first_lease, 8, .cancel, pid));
    permit.lease_addr = @intFromPtr(&second_lease);
    try std.testing.expectEqual(FinishResult.corrupt, owner.finishPermit(&first_lease, &permit, .completed, pid));
    try std.testing.expectEqual(@as(u1, 0), first_owner.active_cleanup);
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(8).?.state);
    try std.testing.expectEqual(ReleaseOutcome.released, first_lease.release(pid));
    try std.testing.expectEqual(ReleaseOutcome.released, second_lease.release(pid));
}

test "valid foreign permit owner splice rolls back the trusted reservation" {
    const pid: u32 = 17;
    var first_owner: PinOwner = .{};
    var second_owner: PinOwner = .{};
    PinOwner.initInPlace(&first_owner, 80, 81, .{ .tagged = 2 }, .{ .tagged = 3 }, 82, pid, 83);
    PinOwner.initInPlace(&second_owner, 90, 91, .{ .tagged = 4 }, .{ .tagged = 5 }, 92, pid, 93);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &first_owner, 84, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(9, 84, .drop));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 9, .drop, pid));
    permit.owner_addr = @intFromPtr(&second_owner);
    try std.testing.expectEqual(FinishResult.corrupt, owner.finishPermit(&lease, &permit, .completed, pid));
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(9).?.state);
    try std.testing.expectEqual(@as(u1, 0), first_owner.active_cleanup);

    var abort_permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&abort_permit, &lease, 9, .drop, pid));
    abort_permit.owner_addr = @intFromPtr(&second_owner);
    try std.testing.expect(!owner.abortPermit(&lease, &abort_permit, pid));
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(9).?.state);
    try std.testing.expectEqual(@as(u1, 0), first_owner.active_cleanup);
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "cleanup reservation incarnation rejects same-address stale permit bytes" {
    const pid: u32 = 18;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(&pin_owner, 100, 101, .{ .tagged = 2 }, .{ .tagged = 3 }, 102, pid, 103);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 104, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(10, 104, .release));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 10, .release, pid));
    const stale_bytes = permit;
    const stale_reservation = permit.reservation_id;
    try std.testing.expectEqual(
        FinishResult.retryable_preserved,
        owner.finishPermit(&lease, &permit, .retryable_preserved, pid),
    );
    permit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 10, .release, pid));
    try std.testing.expect(permit.reservation_id != stale_reservation);
    permit = stale_bytes;
    try std.testing.expectEqual(FinishResult.corrupt, owner.finishPermit(&lease, &permit, .completed, pid));
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(10).?.state);
    try std.testing.expectEqual(@as(u1, 0), pin_owner.active_cleanup);
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "cleanup receipt corruption quarantines without reopening canonical token" {
    const pid: u32 = 19;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(&pin_owner, 110, 111, .{ .tagged = 2 }, .{ .tagged = 3 }, 112, pid, 113);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 114, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(11, 114, .cancel));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 11, .cancel, pid));
    const canonical_reservation = lease.active_cleanup.reservation_id;
    lease.active_cleanup.reservation_id +%= 1;
    const before = cleanup_quarantine_events.load(.acquire);
    try std.testing.expectEqual(FinishResult.terminal, owner.finishPermit(&lease, &permit, .completed, pid));
    try std.testing.expect(owner.quarantined);
    try std.testing.expectEqual(@intFromPtr(&owner), owner.quarantined_owner_addr);
    try std.testing.expectEqual(canonical_reservation + 1, owner.quarantined_reservation_id);
    try std.testing.expectEqual(before + 1, cleanup_quarantine_events.load(.acquire));
    try std.testing.expectEqual(CleanupEntryState.reserved, owner.find(11).?.state);
    try std.testing.expectEqual(@as(u1, 1), pin_owner.active_cleanup);
    try std.testing.expectEqual(PrepareResult.terminal, owner.addAvailable(99, 114, .cancel));
    var rejected: CleanupPermit = .{};
    try std.testing.expectEqual(
        PrepareResult.terminal,
        owner.preparePermit(&rejected, &lease, 11, .cancel, pid),
    );
    try std.testing.expect(!owner.abortPermit(&lease, &permit, pid));
    try std.testing.expectEqual(before + 1, cleanup_quarantine_events.load(.acquire));
    // Test-only unlatch releases stack fixtures; CR3a-2's strict product adapter fail-stops on the
    // first corrupt result and never resumes a quarantined owner.
    owner.quarantined = false;
    lease.active_cleanup.reservation_id = canonical_reservation;
    try std.testing.expect(owner.abortPermit(&lease, &permit, pid));
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "abort owner drift quarantines and preserves the canonical reservation" {
    const pid: u32 = 21;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(&pin_owner, 130, 131, .{ .tagged = 2 }, .{ .tagged = 3 }, 132, pid, 133);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 134, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(13, 134, .drop));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 13, .drop, pid));
    const canonical_incarnation = pin_owner.node_incarnation;
    const before = cleanup_quarantine_events.load(.acquire);
    pin_owner.node_incarnation +%= 2;
    try std.testing.expect(!owner.abortPermit(&lease, &permit, pid));
    try std.testing.expect(owner.quarantined);
    try std.testing.expectEqual(@intFromPtr(&owner), owner.quarantined_owner_addr);
    try std.testing.expectEqual(permit.reservation_id, owner.quarantined_reservation_id);
    try std.testing.expectEqual(before + 1, cleanup_quarantine_events.load(.acquire));
    try std.testing.expectEqual(CleanupEntryState.reserved, owner.find(13).?.state);
    try std.testing.expectEqual(@as(u1, 1), pin_owner.active_cleanup);
    try std.testing.expectEqual(@as(usize, 1), pin_owner.cleanup_pin_count);

    // Test-only repair releases stack fixtures after proving the production owner is latched.
    pin_owner.node_incarnation = canonical_incarnation;
    owner.quarantined = false;
    permit.lifecycle = .prepared;
    try std.testing.expect(owner.abortPermit(&lease, &permit, pid));
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "cleanup reservation identity burns max and rejects the next prepare without mutation" {
    const pid: u32 = 20;
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(&pin_owner, 120, 121, .{ .tagged = 2 }, .{ .tagged = 3 }, 122, pid, 123);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 124, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    owner.next_reservation_id = std.math.maxInt(u64);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(12, 124, .release));
    var last: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&last, &lease, 12, .release, pid));
    try std.testing.expectEqual(std.math.maxInt(u64), last.reservation_id);
    try std.testing.expectEqual(
        FinishResult.retryable_preserved,
        owner.finishPermit(&lease, &last, .retryable_preserved, pid),
    );
    var rejected: CleanupPermit = .{};
    try std.testing.expectEqual(
        PrepareResult.capacity_exhausted,
        owner.preparePermit(&rejected, &lease, 12, .release, pid),
    );
    try std.testing.expectEqual(CleanupEntryState.available, owner.find(12).?.state);
    try std.testing.expectEqual(@as(u1, 0), pin_owner.active_cleanup);
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}

test "fork child cannot finish or abort an inherited cleanup permit" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pid: u32 = @intCast(std.c.getpid());
    var pin_owner: PinOwner = .{};
    PinOwner.initInPlace(&pin_owner, 140, 141, .{ .tagged = 2 }, .{ .tagged = 3 }, 142, pid, 143);
    var lease: ConnectionLease = .{};
    try ConnectionLease.initInPlace(&lease, &pin_owner, 144, pid);
    var owner: CleanupOwner = undefined;
    CleanupOwner.initInPlace(&owner);
    try std.testing.expectEqual(PrepareResult.prepared, owner.addAvailable(14, 144, .cancel));
    var permit: CleanupPermit = .{};
    try std.testing.expectEqual(PrepareResult.prepared, owner.preparePermit(&permit, &lease, 14, .cancel, pid));

    const Action = enum { finish, abort };
    for (std.enums.values(Action)) |action| {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            const child_pid: u32 = @intCast(std.c.getpid());
            const rejected = switch (action) {
                .finish => owner.finishPermit(&lease, &permit, .completed, child_pid) == .terminal,
                .abort => !owner.abortPermit(&lease, &permit, child_pid),
            };
            const mutation_zero = owner.find(14).?.state == .reserved and
                pin_owner.active_cleanup == 1 and
                pin_owner.cleanup_pin_count == 1 and
                lease.lifecycle == .live;
            std.c._exit(if (rejected and owner.quarantined and mutation_zero) 0 else 1);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
        try std.testing.expect(!owner.quarantined);
        try std.testing.expectEqual(CleanupEntryState.reserved, owner.find(14).?.state);
        try std.testing.expectEqual(@as(u1, 1), pin_owner.active_cleanup);
    }
    try std.testing.expect(owner.abortPermit(&lease, &permit, pid));
    try std.testing.expectEqual(ReleaseOutcome.released, lease.release(pid));
}
