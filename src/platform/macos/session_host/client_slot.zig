//! Heap-pinned generation-1 Client owner used by CR3a-1 HostAdapter migration.
//!
//! This module is the only adapter between the transport-neutral cleanup pin and `Client`.  CR3a-1
//! does not mint product leases or switch generations; it establishes the final-address owner that
//! CR3a-2/CR3b can safely target later.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const lease_mod = @import("connection_lease.zig");
const cleanup_registry_mod = @import("attachment_cleanup_registry.zig");
const contract = @import("generation_attachment_contract.zig");

const c = std.c;

pub const Lifecycle = enum {
    live,
    deinit_reserved,
    dead,
};

pub const ClientNode = struct {
    client: client_mod.Client,
    pin_owner: lease_mod.PinOwner,
    cleanup_registry: cleanup_registry_mod.AttachmentCleanupRegistry,
    incarnation: lease_mod.Identity,
};

pub const InitError = error{
    InvalidSource,
    InvalidDestination,
    AliasedAllocation,
    ReentrantInit,
    ProcessDomainMismatch,
    IdentityExhausted,
    OutOfMemory,
};

pub const DeinitOutcome = enum {
    cleaned,
    busy,
    corrupt,
    already_dead,
};

pub const AttachmentBindingReservation = struct {
    cleanup: cleanup_registry_mod.Reservation,
    identity: contract.BindingIdentity,
};

pub const BindingError = cleanup_registry_mod.Error ||
    contract.PreparedAttachmentBinding.TransitionError || error{
    PinOverflow,
    InvalidLease,
};

var issuer_mutex: std.atomic.Mutex = .unlocked;
var process_issuer: ?lease_mod.IdentityIssuer = null;
threadlocal var init_active: bool = false;
var alias_quarantine_events: std.atomic.Value(u64) = .init(0);

fn recordAliasQuarantine() bool {
    var observed = alias_quarantine_events.load(.acquire);
    while (true) {
        if (observed == std.math.maxInt(u64)) return false;
        if (alias_quarantine_events.cmpxchgWeak(
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

fn currentPid() u32 {
    return if (builtin.os.tag == .macos) @intCast(c.getpid()) else 1;
}

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn productionIssuer() *lease_mod.IdentityIssuer {
    while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
    defer issuer_mutex.unlock();
    if (process_issuer == null) {
        var nonce: u64 = 0;
        if (builtin.os.tag == .macos) {
            std.c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
        } else {
            // The product owner is macOS-only.  This non-secret fallback exists solely so
            // cross-target compile tests can instantiate the type without a Darwin syscall.
            nonce = @as(u64, currentPid()) ^ @as(u64, @intFromPtr(&process_issuer));
        }
        if (nonce == 0) nonce = 1;
        process_issuer = lease_mod.IdentityIssuer.init(currentPid(), nonce);
    }
    return &process_issuer.?;
}

pub const ClientSlot = struct {
    self_addr: usize,
    current: *ClientNode,
    node_allocator: std.mem.Allocator,
    incarnation: lease_mod.Identity,
    pid: u32,
    process_nonce: u64,
    next_binding_incarnation: u64,
    lifecycle: Lifecycle,

    pub fn initInPlace(
        out: *ClientSlot,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
        host_id: u128,
    ) InitError!void {
        return initInPlaceWithIssuer(
            out,
            node_allocator,
            source,
            host_id,
            productionIssuer(),
            currentPid(),
        );
    }

    fn initInPlaceWithIssuer(
        out: *ClientSlot,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
        host_id: u128,
        issuer: *lease_mod.IdentityIssuer,
        pid: u32,
    ) InitError!void {
        if (@intFromPtr(out) == @intFromPtr(source)) return error.InvalidDestination;
        if (host_id == 0 or source.host_id != host_id or !source.canMoveToGenerationNode())
            return error.InvalidSource;

        const slot_identity = issuer.reserve(.slot, pid) catch |err| return switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            error.ProcessDomainMismatch => error.ProcessDomainMismatch,
        };
        const node_identity = issuer.reserve(.node, pid) catch |err| return switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            error.ProcessDomainMismatch => error.ProcessDomainMismatch,
        };

        if (init_active) return error.ReentrantInit;
        init_active = true;
        defer init_active = false;

        const node = node_allocator.create(ClientNode) catch return error.OutOfMemory;
        // Until the returned address has passed checked range and alias validation it is hostile
        // allocator output, not a destroyable allocation authority.
        var destroy_node_on_error = false;
        errdefer if (destroy_node_on_error) node_allocator.destroy(node);
        const node_start = @intFromPtr(node);
        const node_end = std.math.add(usize, node_start, @sizeOf(ClientNode)) catch {
            if (!recordAliasQuarantine()) @panic("ClientSlot alias quarantine exhausted");
            return error.AliasedAllocation;
        };
        const out_start = @intFromPtr(out);
        const out_end = std.math.add(usize, out_start, @sizeOf(ClientSlot)) catch
            return error.AliasedAllocation;
        const source_start = @intFromPtr(source);
        const source_end = std.math.add(usize, source_start, @sizeOf(client_mod.Client)) catch
            return error.AliasedAllocation;
        if (rangesOverlap(node_start, node_end, out_start, out_end) or
            rangesOverlap(node_start, node_end, source_start, source_end))
        {
            // An allocator that aliases caller-owned storage cannot be trusted to destroy that
            // pointer either.  Quarantine the backing and let the product invariant wrapper
            // fail-stop; freeing here could corrupt the still-authoritative source Client.
            destroy_node_on_error = false;
            if (!recordAliasQuarantine()) @panic("ClientSlot alias quarantine exhausted");
            return error.AliasedAllocation;
        }
        destroy_node_on_error = true;

        // All failure points are above.  From here the source move and publication are one no-fail
        // suffix, leaving exactly one Client owner in the heap node.
        node.cleanup_registry = .{};
        cleanup_registry_mod.AttachmentCleanupRegistry.initInPlace(
            &node.cleanup_registry,
            node_identity.tagged,
        ) catch unreachable;
        source.moveToGenerationNode(&node.client);
        node.incarnation = node_identity;
        lease_mod.PinOwner.initInPlace(
            &node.pin_owner,
            @intFromPtr(out),
            @intFromPtr(node),
            slot_identity,
            node_identity,
            host_id,
            pid,
            issuer.process_nonce,
        );
        out.* = .{
            .self_addr = @intFromPtr(out),
            .current = node,
            .node_allocator = node_allocator,
            .incarnation = slot_identity,
            .pid = pid,
            .process_nonce = issuer.process_nonce,
            .next_binding_incarnation = 1,
            .lifecycle = .live,
        };
    }

    fn rangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
        return a_start < b_end and b_start < a_end;
    }

    pub fn valid(self: *const ClientSlot) bool {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != .live or
            self.pid != currentPid() or self.process_nonce == 0 or
            self.incarnation.kind() != .slot)
            return false;
        _ = self.current.cleanup_registry.count() catch return false;
        return self.current.incarnation.kind() == .node and
            self.current.pin_owner.self_addr == @intFromPtr(&self.current.pin_owner) and
            self.current.pin_owner.slot_addr == @intFromPtr(self) and
            self.current.pin_owner.node_addr == @intFromPtr(self.current) and
            self.current.pin_owner.slot_incarnation == self.incarnation.tagged and
            self.current.pin_owner.node_incarnation == self.current.incarnation.tagged and
            self.current.pin_owner.host_id == self.current.client.host_id and
            self.current.pin_owner.connection_generation == 1 and
            self.current.pin_owner.pid == self.pid and
            self.current.pin_owner.process_nonce == self.process_nonce and
            self.current.cleanup_registry.self_addr == @intFromPtr(&self.current.cleanup_registry) and
            self.current.cleanup_registry.incarnation == self.current.incarnation.tagged;
    }

    pub fn reserveAttachmentBinding(
        self: *ClientSlot,
        binding_out: *contract.PreparedAttachmentBinding,
        lease_out: *lease_mod.ConnectionLease,
        runtime_id: u128,
        role: contract.AttachmentRole,
    ) BindingError!AttachmentBindingReservation {
        if (!self.valid()) return error.MovedOrCopied;
        const protected = .{
            self,
            self.current,
            &self.current.client,
            &self.current.pin_owner,
            &self.current.cleanup_registry,
        };
        if (runtime_id == 0 or rangesOverlapTyped(binding_out, lease_out))
            return error.InvalidIdentity;
        inline for (protected) |owner| {
            if (rangesOverlapTyped(binding_out, owner) or rangesOverlapTyped(lease_out, owner))
                return error.InvalidIdentity;
        }
        if (self.next_binding_incarnation == 0 or
            self.next_binding_incarnation == std.math.maxInt(u64))
            return error.IdentityExhausted;
        if (self.current.pin_owner.cleanup_pin_count == std.math.maxInt(usize))
            return error.PinOverflow;

        const binding_incarnation = self.next_binding_incarnation;
        const reserved = try self.current.cleanup_registry.reserve(.{
            .binding_incarnation = binding_incarnation,
            .binding_storage_addr = @intFromPtr(binding_out),
            .destination_addr = @intFromPtr(lease_out),
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .host_id = self.current.client.host_id,
            .connection_generation = 1,
            .runtime_id = runtime_id,
            .role = role,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        });
        errdefer self.current.cleanup_registry.abort(
            reserved.reservation,
            reserved.identity,
        ) catch @panic("attachment binding reservation rollback failed");

        try contract.PreparedAttachmentBinding.initReservedInPlace(binding_out, reserved.identity);
        self.current.pin_owner.cleanup_pin_count += 1;
        self.next_binding_incarnation = binding_incarnation + 1;
        return .{ .cleanup = reserved.reservation, .identity = reserved.identity };
    }

    pub fn abortAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            (binding.lifecycle != .reserved and binding.lifecycle != .request_paired))
            return error.InvalidState;
        if (self.current.pin_owner.cleanup_pin_count == 0) return error.InvalidState;

        try self.current.cleanup_registry.abort(reservation.cleanup, canonical);
        self.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    pub fn abortExecutedAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        executed: contract.ExecutedCallReceipt,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        const prepared = binding.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .executing or
            !executed.matchesPrepared(prepared) or
            self.current.pin_owner.cleanup_pin_count == 0)
            return error.InvalidState;
        try self.current.cleanup_registry.abort(reservation.cleanup, canonical);
        self.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    pub fn commitAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        accepted: contract.CorrelatedExecutedCall,
        stream_id: u64,
        lease_out: *lease_mod.ConnectionLease,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        const prepared = binding.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .executing or
            !accepted.executed_call.matchesPrepared(prepared) or
            !accepted.responseMatchesPrepared() or
            canonical.destination_addr != @intFromPtr(lease_out))
            return error.InvalidState;
        if (!lease_mod.ConnectionLease.canInitFromReservedPin(
            lease_out,
            &self.current.pin_owner,
            stream_id,
            self.pid,
        )) return error.InvalidLease;

        self.current.cleanup_registry.bindStream(
            reservation.cleanup,
            canonical,
            stream_id,
        ) catch |err| return err;
        lease_mod.ConnectionLease.initFromReservedPinUnchecked(
            lease_out,
            &self.current.pin_owner,
            stream_id,
            self.pid,
        );
        binding.lifecycle = .committed;
    }

    /// Validate the complete drop transaction and publish callback activity before any attachment
    /// payload is destroyed. A successful begin creates a no-fail suffix owned by
    /// `finishActiveAttachmentDrop`; CR3a-2d later replaces this local pair with the full typed
    /// permit/retry/quarantine owner.
    pub fn beginAttachmentDrop(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        lease: *lease_mod.ConnectionLease,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .committed or
            lease.stream_id == 0 or !lease.canRelease(self.pid))
            return error.InvalidLease;
        try self.current.cleanup_registry.preflightBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        );

        self.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        ) catch unreachable;
        self.current.pin_owner.active_cleanup = 1;
    }

    /// No-fail suffix for a successfully begun attachment drop. The owner must call this exactly
    /// once after destroying the payload; every invariant was sealed by `beginAttachmentDrop`.
    pub fn finishActiveAttachmentDrop(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        lease: *lease_mod.ConnectionLease,
    ) void {
        const canonical = binding.identity orelse unreachable;
        if (!self.valid() or !binding.validAtFinalAddress() or
            !canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .committed or self.current.pin_owner.active_cleanup != 1 or
            lease.stream_id == 0)
            unreachable;
        self.current.client.dropBufferedStream(lease.stream_id);
        self.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        ) catch unreachable;
        lease.releaseDuringActiveCleanupUnchecked(&self.current.pin_owner, self.pid);
        self.current.pin_owner.active_cleanup = 0;
        binding.lifecycle = .terminal;
    }

    pub fn logicalClient(self: *ClientSlot) *client_mod.Client {
        if (!self.valid()) @panic("invalid session-host ClientSlot");
        return &self.current.client;
    }

    pub fn logicalClientConst(self: *const ClientSlot) *const client_mod.Client {
        if (!self.valid()) @panic("invalid session-host ClientSlot");
        return &self.current.client;
    }

    pub fn transportOwnerSeal(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
    ) BindingError!*contract.TransportOwnerSeal {
        if (!self.valid()) return error.MovedOrCopied;
        return self.current.cleanup_registry.transportOwnerSeal(
            reservation.cleanup,
            reservation.identity,
        );
    }

    pub fn responseOwnerSeal(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
    ) BindingError!*contract.ExecutedResponseOwnerSeal {
        if (!self.valid()) return error.MovedOrCopied;
        return self.current.cleanup_registry.responseOwnerSeal(
            reservation.cleanup,
            reservation.identity,
        );
    }

    pub fn reserveAttachmentBindingForTest(
        self: *ClientSlot,
        binding_out: *contract.PreparedAttachmentBinding,
        lease_out: *lease_mod.ConnectionLease,
        runtime_id: u128,
    ) BindingError!AttachmentBindingReservation {
        if (!builtin.is_test) unreachable;
        return self.reserveAttachmentBinding(
            binding_out,
            lease_out,
            runtime_id,
            .controller,
        );
    }

    pub fn tryDeinit(self: *ClientSlot) DeinitOutcome {
        if (self.lifecycle == .dead) return .already_dead;
        if (!self.valid()) return if (self.lifecycle == .deinit_reserved) .busy else .corrupt;
        if (self.current.pin_owner.cleanup_pin_count != 0 or
            self.current.pin_owner.active_cleanup != 0)
            return .busy;
        switch (self.current.cleanup_registry.tryDeinit()) {
            .cleaned => {},
            .busy => return .busy,
            .corrupt, .already_dead => return .corrupt,
        }
        self.lifecycle = .deinit_reserved;
        self.current.pin_owner.state = .terminal;
        self.current.client.deinit();
        self.node_allocator.destroy(self.current);
        self.lifecycle = .dead;
        return .cleaned;
    }

    pub fn deinit(self: *ClientSlot) void {
        if (self.tryDeinit() != .cleaned)
            @panic("session-host ClientSlot teardown invariant violated");
    }
};

test "CR3a-2a ClientSlot teardown waits for node-local attachment reservations" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xAC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAC);

    const reserved = try slot.current.cleanup_registry.reserve(.{
        .binding_incarnation = 101,
        .binding_storage_addr = @intFromPtr(&slot),
        .destination_addr = @intFromPtr(&slot),
        .slot_incarnation = slot.incarnation.tagged,
        .node_incarnation = slot.current.incarnation.tagged,
        .host_id = 0xAC,
        .connection_generation = 1,
        .runtime_id = 0xBD,
        .role = .controller,
        .pid = slot.pid,
        .process_nonce = slot.process_nonce,
    });
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try slot.current.cleanup_registry.abort(reserved.reservation, reserved.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a ClientSlot transfers pre-reserved pin through attach drop and lease release" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xCA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xCA);

    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBinding(
        &binding,
        &lease,
        0xDB,
        .controller,
    );
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 211,
        .request_id = 223,
        .request_digest = 227,
    }).?;
    try binding.pairRequest(prepared);
    try binding.beginExecute(prepared);
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, prepared.request_id).?;
    try slot.commitAttachmentBinding(&binding, reservation, accepted, 229, &lease);
    try std.testing.expectEqual(contract.BindingLifecycle.committed, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.cleanup_registry.count());

    var foreign = reservation;
    foreign.cleanup.reservation_id += 1;
    try std.testing.expectError(
        error.InvalidReservation,
        slot.beginAttachmentDrop(&binding, foreign, &lease),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.committed, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.active_cleanup);
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expect(lease.canRelease(slot.pid));

    try slot.beginAttachmentDrop(&binding, reservation, &lease);
    slot.finishActiveAttachmentDrop(&binding, reservation, &lease);
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a rejected attach aborts pre-reserved pin and drop entry exactly once" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xEA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xEA);

    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBinding(&binding, &lease, 0xFB, .controller);
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 233,
        .request_id = 239,
        .request_digest = 241,
    }).?;
    try binding.pairRequest(prepared);
    try slot.abortAttachmentBinding(&binding, reservation);
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
    try std.testing.expectError(
        error.InvalidState,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a binding reservation rejects lease and canonical owner aliases without mutation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFC);
    defer slot.deinit();

    const Shared = union {
        binding: contract.PreparedAttachmentBinding,
        lease: lease_mod.ConnectionLease,
    };
    var shared: Shared = .{ .binding = .{} };
    const binding: *contract.PreparedAttachmentBinding = @ptrCast(&shared);
    const lease: *lease_mod.ConnectionLease = @ptrCast(&shared);
    try std.testing.expectError(
        error.InvalidIdentity,
        slot.reserveAttachmentBinding(binding, lease, 0xFD, .controller),
    );
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());

    var clean_binding: contract.PreparedAttachmentBinding = .{};
    const owner_lease: *lease_mod.ConnectionLease = @ptrCast(@alignCast(&slot.current.pin_owner));
    try std.testing.expectError(
        error.InvalidIdentity,
        slot.reserveAttachmentBinding(&clean_binding, owner_lease, 0xFE, .controller),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.pristine, clean_binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
}

fn fixtureClient(allocator: std.mem.Allocator, host_id: u128) client_mod.Client {
    return .{
        .allocator = allocator,
        .fd = -1,
        .host_id = host_id,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
}

const ReentrantNodeAllocator = struct {
    parent: std.mem.Allocator,
    issuer: ?*lease_mod.IdentityIssuer = null,
    nested_source: ?*client_mod.Client = null,
    nested_slot: ?*ClientSlot = null,
    outer_slot: ?*ClientSlot = null,
    alloc_reentry_fired: bool = false,
    alloc_reentry_rejected: bool = false,
    free_reentry_fired: bool = false,
    free_reentry_outcome: ?DeinitOutcome = null,

    fn allocator(self: *ReentrantNodeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        if (!self.alloc_reentry_fired and self.issuer != null and
            self.nested_source != null and self.nested_slot != null)
        {
            self.alloc_reentry_fired = true;
            ClientSlot.initInPlaceWithIssuer(
                self.nested_slot.?,
                self.allocator(),
                self.nested_source.?,
                self.nested_source.?.host_id,
                self.issuer.?,
                currentPid(),
            ) catch |err| {
                self.alloc_reentry_rejected = err == error.ReentrantInit;
            };
        }
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        if (!self.free_reentry_fired) {
            self.free_reentry_fired = true;
            if (self.outer_slot) |slot| self.free_reentry_outcome = slot.tryDeinit();
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

test "client slot moves production Client into a heap-pinned generation-1 node" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 77);
    var source = fixtureClient(std.testing.allocator, 0xAA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xAA,
        &issuer,
        currentPid(),
    );
    defer slot.deinit();
    try std.testing.expect(slot.valid());
    try std.testing.expectEqual(@as(u128, 0xAA), slot.logicalClient().host_id);
    try std.testing.expect(source.tryDeinit());
    try std.testing.expectEqual(lease_mod.IdentityKind.slot, slot.incarnation.kind());
    try std.testing.expectEqual(lease_mod.IdentityKind.node, slot.current.incarnation.kind());
}

test "client slot failure preserves source and burns identities" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 88);
    var source = fixtureClient(std.testing.allocator, 0xBB);
    defer source.deinit();
    var slot: ClientSlot = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        ClientSlot.initInPlaceWithIssuer(
            &slot,
            failing.allocator(),
            &source,
            0xBB,
            &issuer,
            currentPid(),
        ),
    );
    try std.testing.expectEqual(@as(u128, 0xBB), source.host_id);
    try std.testing.expect(source.canMoveToGenerationNode());
    try std.testing.expectEqual(@as(u64, 3), issuer.next_ordinal.load(.acquire));
}

test "client slot rejects cross-process domain before allocation or source move" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid() + 1, 99);
    var source = fixtureClient(std.testing.allocator, 0xCC);
    defer source.deinit();
    var slot: ClientSlot = undefined;
    try std.testing.expectError(
        error.ProcessDomainMismatch,
        ClientSlot.initInPlaceWithIssuer(
            &slot,
            std.testing.allocator,
            &source,
            0xCC,
            &issuer,
            currentPid(),
        ),
    );
    try std.testing.expect(source.canMoveToGenerationNode());
}

test "client slot same-address reincarnation changes both slot and node identity" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 101);
    var node_bytes: [@sizeOf(ClientNode) + @alignOf(ClientNode)]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&node_bytes);
    var slot: ClientSlot = undefined;

    var first_source = fixtureClient(std.testing.allocator, 0xD1);
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        fixed.allocator(),
        &first_source,
        0xD1,
        &issuer,
        currentPid(),
    );
    const first_slot_identity = slot.incarnation.tagged;
    const first_node_identity = slot.current.incarnation.tagged;
    const first_node_addr = @intFromPtr(slot.current);
    slot.deinit();
    fixed.reset();

    var second_source = fixtureClient(std.testing.allocator, 0xD2);
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        fixed.allocator(),
        &second_source,
        0xD2,
        &issuer,
        currentPid(),
    );
    defer slot.deinit();
    try std.testing.expectEqual(first_node_addr, @intFromPtr(slot.current));
    try std.testing.expect(slot.incarnation.tagged != first_slot_identity);
    try std.testing.expect(slot.current.incarnation.tagged != first_node_identity);
}

test "client slot teardown is busy while an exact cleanup lease pins its node" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 102);
    var source = fixtureClient(std.testing.allocator, 0xD3);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xD3,
        &issuer,
        currentPid(),
    );
    var lease: lease_mod.ConnectionLease = .{};
    try lease_mod.ConnectionLease.initInPlace(
        &lease,
        &slot.current.pin_owner,
        9,
        currentPid(),
    );
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try std.testing.expectEqual(lease_mod.ReleaseOutcome.released, lease.release(currentPid()));
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "fork child cannot consume or deinit an inherited generation slot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 103);
    var source = fixtureClient(std.testing.allocator, 0xD4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xD4,
        &issuer,
        currentPid(),
    );
    var inherited_lease: lease_mod.ConnectionLease = .{};
    try lease_mod.ConnectionLease.initInPlace(
        &inherited_lease,
        &slot.current.pin_owner,
        19,
        currentPid(),
    );
    defer slot.deinit();
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        const child_pid = currentPid();
        var minted: lease_mod.ConnectionLease = .{};
        const mint_rejected = if (lease_mod.ConnectionLease.initInPlace(
            &minted,
            &slot.current.pin_owner,
            20,
            child_pid,
        )) |_| false else |err| err == error.InvalidOwner;
        const release_outcome = inherited_lease.release(child_pid);
        const deinit_outcome = slot.tryDeinit();
        const mutation_zero = slot.lifecycle == .live and
            slot.current.pin_owner.cleanup_pin_count == 1 and
            inherited_lease.lifecycle == .live;
        std.c._exit(if (mint_rejected and
            release_outcome == .corrupt and
            deinit_outcome == .corrupt and
            mutation_zero) 0 else 1);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expect(slot.valid());
    try std.testing.expectEqual(
        lease_mod.ReleaseOutcome.released,
        inherited_lease.release(currentPid()),
    );
}

test "client slot rejects a valid foreign generation node splice" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 104);
    var first_source = fixtureClient(std.testing.allocator, 0xE1);
    var second_source = fixtureClient(std.testing.allocator, 0xE2);
    var first: ClientSlot = undefined;
    var second: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &first,
        std.testing.allocator,
        &first_source,
        0xE1,
        &issuer,
        currentPid(),
    );
    try ClientSlot.initInPlaceWithIssuer(
        &second,
        std.testing.allocator,
        &second_source,
        0xE2,
        &issuer,
        currentPid(),
    );
    const canonical_first = first.current;
    first.current = second.current;
    try std.testing.expect(!first.valid());
    first.current = canonical_first;
    first.deinit();
    second.deinit();
}

test "client slot burns identities and rejects allocator allocation callback reentry" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 105);
    var nested_source = fixtureClient(std.testing.allocator, 0xF1);
    defer nested_source.deinit();
    var nested_slot: ClientSlot = undefined;
    var allocator = ReentrantNodeAllocator{
        .parent = std.testing.allocator,
        .issuer = &issuer,
        .nested_source = &nested_source,
        .nested_slot = &nested_slot,
    };
    var source = fixtureClient(std.testing.allocator, 0xF2);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        allocator.allocator(),
        &source,
        0xF2,
        &issuer,
        currentPid(),
    );
    allocator.outer_slot = &slot;
    slot.deinit();
    try std.testing.expect(allocator.alloc_reentry_fired);
    try std.testing.expect(allocator.alloc_reentry_rejected);
    try std.testing.expect(nested_source.canMoveToGenerationNode());
    try std.testing.expectEqual(@as(u64, 5), issuer.next_ordinal.load(.acquire));
}

test "client slot publishes deinit reservation before allocator free callback reentry" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 106);
    var allocator = ReentrantNodeAllocator{ .parent = std.testing.allocator };
    var source = fixtureClient(std.testing.allocator, 0xF3);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        allocator.allocator(),
        &source,
        0xF3,
        &issuer,
        currentPid(),
    );
    allocator.outer_slot = &slot;
    slot.deinit();
    try std.testing.expect(allocator.free_reentry_fired);
    try std.testing.expectEqual(DeinitOutcome.busy, allocator.free_reentry_outcome.?);
    try std.testing.expectEqual(Lifecycle.dead, slot.lifecycle);
}

test "client slot alias quarantine counter rejects overflow without wrapping" {
    const before = alias_quarantine_events.load(.acquire);
    defer alias_quarantine_events.store(before, .release);
    alias_quarantine_events.store(std.math.maxInt(u64), .release);
    try std.testing.expect(!recordAliasQuarantine());
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        alias_quarantine_events.load(.acquire),
    );
}
