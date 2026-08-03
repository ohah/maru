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
const batch_registry_mod = @import("generation_batch_registry.zig");
const owner_seal = @import("external_owner_seal.zig");
const contract = @import("generation_attachment_contract.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const compatibility = @import("compatibility.zig");
const socket_server = @import("socket_server.zig");
const ended_purge_quarantine = @import("ended_purge_quarantine.zig");

const c = std.c;
var ended_purge_quarantine_registry: ?ended_purge_quarantine.Registry = null;
var process_runtime_pid: std.atomic.Value(u32) = .init(0);

test "CR3a-2c2b3b quarantine leaf participates in the session-host gate" {
    _ = ended_purge_quarantine;
}

test "CR3a-2c2b3b process runtime bootstrap is explicit and same-process idempotent" {
    try ClientSlot.initializeProcessRuntime();
    try ClientSlot.initializeProcessRuntime();
}

test "CR3a-2c2b3b fork child rejects bootstrap before inherited issuer mutex" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const ChildCleanup = struct {
        fn terminateAndReap(child_pid: std.c.pid_t) void {
            _ = std.c.kill(child_pid, std.c.SIG.KILL);
            var child_status: c_int = 0;
            while (true) {
                const waited = std.c.waitpid(child_pid, &child_status, 0);
                if (waited == child_pid or
                    (waited < 0 and std.posix.errno(waited) == .CHILD)) return;
                if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
                return;
            }
        }
    };
    try ClientSlot.initializeProcessRuntime();
    while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
    const child = std.c.fork();
    if (child < 0) {
        issuer_mutex.unlock();
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        ClientSlot.initializeProcessRuntime() catch |err|
            std.c._exit(if (err == error.ProcessDomainMismatch) 0 else 2);
        std.c._exit(3);
    }
    defer issuer_mutex.unlock();

    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) {
            const wait_status: u32 = @bitCast(status);
            try std.testing.expect(std.c.W.IFEXITED(wait_status));
            try std.testing.expectEqual(@as(u8, 0), std.c.W.EXITSTATUS(wait_status));
            return;
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            ChildCleanup.terminateAndReap(child);
            return error.TestUnexpectedResult;
        }
        var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    ChildCleanup.terminateAndReap(child);
    return error.TestUnexpectedResult;
}

fn rawRangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
    return a_start < b_end and b_start < a_end;
}

pub const Lifecycle = enum {
    live,
    deinit_reserved,
    dead,
};

const GenerationGuardedAllocator = struct {
    parent: std.mem.Allocator,
    client: ?*client_mod.Client = null,
    node_start: usize,
    node_end: usize,
    slot_start: usize,
    slot_end: usize,
    source_start: usize,
    source_end: usize,
    snapshot_owner_start: usize = 0,
    snapshot_owner_end: usize = 0,
    snapshot_out_start: usize = 0,
    snapshot_out_end: usize = 0,
    snapshot_guard_active: bool = false,
    snapshot_alias_rejected: bool = false,

    fn allocator(self: *GenerationGuardedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn rejects(self: *const GenerationGuardedAllocator, ptr: [*]u8, len: usize) bool {
        const start = @intFromPtr(ptr);
        const end = std.math.add(usize, start, len) catch return true;
        return rawRangesOverlap(start, end, self.node_start, self.node_end) or
            rawRangesOverlap(start, end, self.slot_start, self.slot_end) or
            rawRangesOverlap(start, end, self.source_start, self.source_end) or
            (self.snapshot_guard_active and
                (rawRangesOverlap(start, end, self.snapshot_owner_start, self.snapshot_owner_end) or
                    rawRangesOverlap(start, end, self.snapshot_out_start, self.snapshot_out_end) or
                    client_mod.generationAllocationAliasesOwnedBacking(self.client.?, ptr, len)));
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (!self.client.?.enterGenerationAllocatorCallback()) return null;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        const result = self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        ) orelse return null;
        if (self.rejects(result, len)) {
            if (!self.snapshot_guard_active)
                @panic("generation allocator returned canonical owner alias");
            self.snapshot_alias_rejected = true;
            return null;
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (self.rejects(memory.ptr, new_len)) {
            if (!self.snapshot_guard_active)
                @panic("generation allocator resized into canonical owner");
            self.snapshot_alias_rejected = true;
            return false;
        }
        if (!self.client.?.enterGenerationAllocatorCallback()) return false;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
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
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (!self.client.?.enterGenerationAllocatorCallback()) return null;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        const result = self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        if (self.rejects(result, new_len)) {
            if (!self.snapshot_guard_active)
                @panic("generation allocator remapped into canonical owner");
            self.snapshot_alias_rejected = true;
            return null;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (!self.client.?.enterGenerationAllocatorCallback())
            @panic("nested generation allocator free");
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

pub const ClientNode = struct {
    client: client_mod.Client,
    operation_fence: client_mod.ClientOperationFence,
    pin_owner: lease_mod.PinOwner,
    cleanup_registry: cleanup_registry_mod.AttachmentCleanupRegistry,
    batch_registry: batch_registry_mod.Registry,
    accounting_ledger: batch_registry_mod.AccountingLedger,
    guarded_allocator: GenerationGuardedAllocator,
    incarnation: lease_mod.Identity,
    next_operation_generation: u64,
    active_operation_generation: u64,
    active_operation_kind: StreamOperationKind,
    active_operation_owner_thread_incarnation: u64,
    active_operation_owner_addr: usize,
    active_operation_transport_incarnation: u64,
    active_operation_binding: contract.BindingIdentity,
};

pub const StreamOperationKind = enum(u8) {
    none,
    initial_snapshot,
    controller_revoke,
    ended_purge,
};

pub const StreamOperationPermit = struct {
    slot: *ClientSlot,
    registry_index: u16,
    registry_id: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    generation: u64,
    kind: StreamOperationKind,
    owner_thread_incarnation: u64,
    owner_addr: usize,
    transport_incarnation: u64,
    binding: contract.BindingIdentity,
};

pub const InitialSnapshotPermit = StreamOperationPermit;

const EndedPurgePreparationLifecycle = enum(u8) {
    empty,
    prepared,
    committing,
    consumed,
    aborted,
};

pub const EndedPurgePreparation = struct {
    self_addr: usize = 0,
    target_stream: u64 = 0,
    permit: StreamOperationPermit = undefined,
    inventory: client_mod.PreparedEndedPurgeInventory = .{},
    authority_seal: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: EndedPurgePreparationLifecycle = .empty,

    fn rawTagsValid(self: *const EndedPurgePreparation) bool {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return lifecycle_raw <= @intFromEnum(EndedPurgePreparationLifecycle.aborted) and
            ClientSlot.streamOperationPermitRawTagsValid(&self.permit) and
            self.inventory.validPreparedAtFinalAddress();
    }

    pub fn abort(self: *EndedPurgePreparation, slot: *ClientSlot) bool {
        if (!self.rawTagsValid() or self.lifecycle != .prepared or
            self.self_addr != @intFromPtr(self) or
            !slot.streamOperationPermitLive(self.permit) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)))
            return false;
        slot.abortStreamOperationPermit(self.permit) catch return false;
        if (!self.inventory.abort()) @panic("validated ended purge inventory abort failed");
        self.lifecycle = .aborted;
        return true;
    }

    fn sealForCommit(self: *EndedPurgePreparation, slot: *ClientSlot) bool {
        if (slot.pid != currentPid() or
            !operationThreadMatches(slot.operation_owner_thread_incarnation))
            return false;
        const index: usize = self.permit.registry_index;
        if (index >= stream_operation_registry.len) return false;
        const entry = &stream_operation_registry[index];
        if (!self.rawTagsValid() or self.lifecycle != .prepared or
            self.self_addr != @intFromPtr(self) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)) or
            entry.state.load(.acquire) !=
                @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved) or
            entry.id != self.permit.registry_id or
            !std.meta.eql(entry.permit, self.permit) or
            self.permit.slot != slot or
            self.permit.generation != slot.current.active_operation_generation or
            self.permit.kind != slot.current.active_operation_kind or
            self.permit.owner_thread_incarnation !=
                slot.current.active_operation_owner_thread_incarnation or
            self.permit.owner_addr != slot.current.active_operation_owner_addr or
            self.permit.transport_incarnation !=
                slot.current.active_operation_transport_incarnation or
            !std.meta.eql(self.permit.binding, slot.current.active_operation_binding))
            return false;
        self.lifecycle = .committing;
        self.authority_seal = endedPurgePreparationSeal(self);
        return true;
    }

    fn consumeAfterPermit(self: *EndedPurgePreparation, slot: *ClientSlot) void {
        if (slot.pid != currentPid() or
            !operationThreadMatches(slot.operation_owner_thread_incarnation))
            @panic("ended purge transport receipt crossed its operation thread");
        const index: usize = self.permit.registry_index;
        if (index >= stream_operation_registry.len)
            @panic("ended purge transport receipt registry index drifted");
        const entry = &stream_operation_registry[index];
        if (!self.rawTagsValid() or self.lifecycle != .committing or
            self.self_addr != @intFromPtr(self) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)) or
            entry.state.load(.acquire) !=
                @intFromEnum(StreamOperationRegistryEntry.State.consumed) or
            entry.id != self.permit.registry_id or
            !std.meta.eql(entry.permit, self.permit) or
            slot.current.active_operation_generation != 0 or
            slot.current.active_operation_kind != .none or
            slot.current.active_operation_owner_thread_incarnation != 0 or
            slot.current.active_operation_owner_addr != 0 or
            slot.current.active_operation_transport_incarnation != 0)
            @panic("ended purge transport receipt authority drifted");
        self.lifecycle = .consumed;
        self.authority_seal = endedPurgePreparationSeal(self);
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.consumed),
            @intFromEnum(StreamOperationRegistryEntry.State.empty),
            .acq_rel,
            .acquire,
        ) != null) @panic("ended purge transport receipt reclaim drifted");
    }
};

fn endedPurgePreparationSeal(prepared: *const EndedPurgePreparation) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.ended-purge.preparation.v1");
    writer.writeUsize(prepared.self_addr);
    writer.writeU64(prepared.target_stream);
    writer.writeUsize(@intFromPtr(prepared.permit.slot));
    writer.writeU16(prepared.permit.registry_index);
    writer.writeU64(prepared.permit.registry_id);
    writer.writeU64(prepared.permit.slot_incarnation);
    writer.writeU64(prepared.permit.node_incarnation);
    writer.writeU64(prepared.permit.generation);
    writer.writeU8(@intFromEnum(prepared.permit.kind));
    writer.writeU64(prepared.permit.owner_thread_incarnation);
    writer.writeUsize(prepared.permit.owner_addr);
    writer.writeU64(prepared.permit.transport_incarnation);
    writer.writeU64(prepared.permit.binding.binding_incarnation);
    writer.writeUsize(prepared.permit.binding.binding_storage_addr);
    writer.writeUsize(prepared.permit.binding.destination_addr);
    writer.writeU64(prepared.permit.binding.binding_reservation_id);
    writer.writeU64(prepared.permit.binding.slot_incarnation);
    writer.writeU64(prepared.permit.binding.node_incarnation);
    writer.writeU128(prepared.permit.binding.host_id);
    writer.writeU64(prepared.permit.binding.connection_generation);
    writer.writeU128(prepared.permit.binding.runtime_id);
    writer.writeU8(@intFromEnum(prepared.permit.binding.role));
    writer.writeU64(prepared.permit.binding.pid);
    writer.writeU64(prepared.permit.binding.process_nonce);
    writer.writeUsize(prepared.inventory.self_addr);
    writer.writeUsize(prepared.inventory.client_addr);
    writer.writeUsize(prepared.inventory.scratch_addr);
    writer.writeU64(prepared.inventory.target_stream);
    writer.writeU64(prepared.inventory.hint_index);
    writeArrayDescriptor(&writer, prepared.inventory.batches);
    writeArrayDescriptor(&writer, prepared.inventory.stream);
    writeArrayDescriptor(&writer, prepared.inventory.events);
    if (prepared.inventory.partial) |partial| {
        writer.writeBool(true);
        writer.writeU64(partial.stream_id);
        writer.writeBool(partial.is_snapshot);
        writeArrayDescriptor(&writer, partial.bytes);
        writer.writeUsize(partial.chunk_count);
    } else writer.writeBool(false);
    writer.writeUsize(prepared.inventory.batch_payload_bytes);
    writer.writeUsize(prepared.inventory.stream_payload_bytes);
    writer.writeUsize(prepared.inventory.event_payload_bytes);
    writer.writeUsize(prepared.inventory.target_batch_count);
    writer.writeUsize(prepared.inventory.target_stream_count);
    writer.writeUsize(prepared.inventory.target_event_count);
    writer.writeUsize(prepared.inventory.target_payload_bytes);
    writer.writeUsize(prepared.inventory.demux_owned_extent_bytes);
    writer.writeBytes(&prepared.inventory.batch_seal);
    writer.writeBytes(&prepared.inventory.stream_seal);
    writer.writeBytes(&prepared.inventory.event_seal);
    writer.writeBytes(&prepared.inventory.partial_seal);
    writer.writeBytes(&prepared.inventory.target_map_seal);
    writer.writeU8(@intFromEnum(prepared.inventory.lifecycle));
    writer.writeU8(@intFromEnum(prepared.lifecycle));
    return writer.finish();
}

fn writeArrayDescriptor(writer: *owner_seal.Writer, descriptor: anytype) void {
    writer.writeUsize(descriptor.address);
    writer.writeUsize(descriptor.len);
    writer.writeUsize(descriptor.capacity);
}

pub const EndedPurgePreparationError = error{
    InvalidOwner,
    Busy,
    Corrupt,
    IdentityExhausted,
    DestinationOccupied,
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
    AdminBusy,
    PinOverflow,
    InvalidLease,
};

pub const CapabilityProjectionError = error{ InvalidOwner, Busy };

pub const CapabilityProjectionRequest = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    pid: u32,
    process_nonce: u64,
    transport_incarnation: u64,
    owner_seal_addr: usize,
    reservation: AttachmentBindingReservation,
};

var issuer_mutex: std.atomic.Mutex = .unlocked;
var process_issuer: ?lease_mod.IdentityIssuer = null;
threadlocal var init_active: bool = false;
threadlocal var batch_release_callback_active: bool = false;
threadlocal var operation_thread_incarnation: u64 = 0;
var next_operation_thread_incarnation: std.atomic.Value(u64) = .init(1);
var alias_quarantine_events: std.atomic.Value(u64) = .init(0);

const max_live_client_slots = 4096;
const ClientSlotRegistryEntry = struct {
    live: bool = false,
    ready: bool = false,
    slot_addr: usize = 0,
    node_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    owner_thread_incarnation: u64 = 0,
};
var client_slot_registry_mutex: std.atomic.Mutex = .unlocked;
var client_slot_registry: [max_live_client_slots]ClientSlotRegistryEntry =
    [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;

fn registerClientSlot(entry: ClientSlotRegistryEntry) error{IdentityExhausted}!void {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    var free_index: ?usize = null;
    for (&client_slot_registry, 0..) |*candidate, index| {
        if (candidate.live and candidate.slot_addr == entry.slot_addr)
            return error.IdentityExhausted;
        if (!candidate.live and free_index == null) free_index = index;
    }
    const index = free_index orelse return error.IdentityExhausted;
    client_slot_registry[index] = entry;
}

fn clientSlotRegistryEntry(slot_addr: usize) ?ClientSlotRegistryEntry {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (client_slot_registry) |entry| {
        if (entry.live and entry.ready and entry.slot_addr == slot_addr) return entry;
    }
    return null;
}

fn publishClientSlot(expected: ClientSlotRegistryEntry) void {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (&client_slot_registry) |*entry| {
        if (entry.live and entry.slot_addr == expected.slot_addr and
            std.meta.eql(entry.*, expected))
        {
            entry.ready = true;
            return;
        }
    }
    @panic("reserved ClientSlot registry publication drifted");
}

fn unregisterClientSlot(expected: ClientSlotRegistryEntry) bool {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (&client_slot_registry) |*entry| {
        if (entry.live and entry.slot_addr == expected.slot_addr) {
            if (!std.meta.eql(entry.*, expected)) return false;
            entry.* = .{};
            return true;
        }
    }
    return false;
}

fn acquireOperationThreadIncarnation() error{IdentityExhausted}!u64 {
    if (operation_thread_incarnation != 0) return operation_thread_incarnation;
    var observed = next_operation_thread_incarnation.load(.acquire);
    while (true) {
        if (observed == 0 or observed == std.math.maxInt(u64))
            return error.IdentityExhausted;
        if (next_operation_thread_incarnation.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        operation_thread_incarnation = observed;
        return observed;
    }
}

fn operationThreadMatches(incarnation: u64) bool {
    return incarnation != 0 and operation_thread_incarnation == incarnation;
}

const max_stream_operation_permits = 4096;
const StreamOperationRegistryEntry = struct {
    const State = enum(u8) { empty, live, consume_reserved, consumed };

    state: std.atomic.Value(u8) = .init(@intFromEnum(State.empty)),
    id: u64 = 0,
    permit: StreamOperationPermit = undefined,
};
var stream_operation_registry_mutex: std.atomic.Mutex = .unlocked;
var stream_operation_registry: [max_stream_operation_permits]StreamOperationRegistryEntry =
    [_]StreamOperationRegistryEntry{.{}} ** max_stream_operation_permits;
var next_stream_operation_registry_id: u64 = 1;

fn registerStreamOperationPermit(fields: StreamOperationPermit) error{ AdminBusy, IdentityExhausted }!StreamOperationPermit {
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    var index: usize = 0;
    while (index < stream_operation_registry.len and
        stream_operation_registry[index].state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.empty)) : (index += 1)
    {}
    if (index == stream_operation_registry.len) return error.AdminBusy;
    const id = next_stream_operation_registry_id;
    next_stream_operation_registry_id = std.math.add(u64, id, 1) catch
        return error.IdentityExhausted;
    var permit = fields;
    permit.registry_index = @intCast(index);
    permit.registry_id = id;
    const entry = &stream_operation_registry[index];
    entry.id = id;
    entry.permit = permit;
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.live), .release);
    return permit;
}

fn streamOperationPermitRegistryLive(permit: StreamOperationPermit) bool {
    const index: usize = permit.registry_index;
    if (index >= stream_operation_registry.len or permit.registry_id == 0) return false;
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    const entry = &stream_operation_registry[index];
    return entry.state.load(.acquire) == @intFromEnum(StreamOperationRegistryEntry.State.live) and
        entry.id == permit.registry_id and std.meta.eql(entry.permit, permit);
}

fn unregisterStreamOperationPermit(permit: StreamOperationPermit) error{InvalidStreamOperationPermit}!void {
    const index: usize = permit.registry_index;
    if (index >= stream_operation_registry.len or permit.registry_id == 0)
        return error.InvalidStreamOperationPermit;
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    const entry = &stream_operation_registry[index];
    if (entry.state.load(.acquire) != @intFromEnum(StreamOperationRegistryEntry.State.live) or
        entry.id != permit.registry_id or !std.meta.eql(entry.permit, permit))
        return error.InvalidStreamOperationPermit;
    if (entry.state.cmpxchgStrong(
        @intFromEnum(StreamOperationRegistryEntry.State.live),
        @intFromEnum(StreamOperationRegistryEntry.State.empty),
        .acq_rel,
        .acquire,
    ) != null) return error.InvalidStreamOperationPermit;
}

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

fn streamOperationNodeIdle(node: *const ClientNode) bool {
    const kind_raw = @as(*const u8, @ptrCast(&node.active_operation_kind)).*;
    return kind_raw <= @intFromEnum(StreamOperationKind.ended_purge) and
        node.active_operation_generation == 0 and node.active_operation_kind == .none and
        node.active_operation_owner_thread_incarnation == 0 and
        node.active_operation_owner_addr == 0 and
        node.active_operation_transport_incarnation == 0;
}

const RegisteredNodeLookup = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node: union(enum) {
        incarnation: u64,
        address: usize,
    },
    owner_thread_incarnation: ?u64 = null,
};

const RegisteredNodeOperation = struct {
    node: *ClientNode,
};

fn beginRegisteredNodeOperation(
    lookup: RegisteredNodeLookup,
) error{ InvalidOwner, Busy }!RegisteredNodeOperation {
    if (lookup.slot_addr == 0 or lookup.slot_incarnation == 0 or switch (lookup.node) {
        .incarnation => |value| value == 0,
        .address => |value| value == 0,
    })
        return error.InvalidOwner;
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (client_slot_registry) |entry| {
        if (!entry.live or !entry.ready or entry.slot_addr != lookup.slot_addr or
            entry.slot_incarnation != lookup.slot_incarnation or
            entry.node_addr == 0 or entry.node_incarnation == 0 or
            switch (lookup.node) {
                .incarnation => |value| entry.node_incarnation != value,
                .address => |value| entry.node_addr != value,
            } or
            (lookup.owner_thread_incarnation != null and
                entry.owner_thread_incarnation != lookup.owner_thread_incarnation.?) or
            !operationThreadMatches(entry.owner_thread_incarnation))
            continue;
        const node: *ClientNode = @ptrFromInt(entry.node_addr);
        node.client.beginClientSlotOperation() catch |err| return switch (err) {
            error.AdminBusy => error.Busy,
            else => error.InvalidOwner,
        };
        return .{ .node = node };
    }
    return error.InvalidOwner;
}

fn endRegisteredNodeOperation(operation: RegisteredNodeOperation) void {
    if (!operation.node.client.endClientSlotOperation())
        @panic("ClientSlot registered node operation fence release failed");
}

/// Resolves an untrusted transport's scalar slot identity through the canonical registry before
/// converting any supplied address to a pointer. The registry lock pins the exact node operation,
/// so teardown cannot create an address ABA between resolution and capability projection.
pub fn projectGenerationCapabilities(
    request: CapabilityProjectionRequest,
) CapabilityProjectionError!contract.GenerationCapabilities {
    if (client_mod.generationAllocatorCallbackActive() or batch_release_callback_active)
        return error.Busy;
    if (request.slot_addr == 0 or request.slot_incarnation == 0 or
        request.node_incarnation == 0 or request.host_id == 0 or request.pid != currentPid() or
        request.process_nonce == 0 or request.transport_incarnation == 0 or
        request.owner_seal_addr == 0)
        return error.InvalidOwner;

    const operation = beginRegisteredNodeOperation(.{
        .slot_addr = request.slot_addr,
        .slot_incarnation = request.slot_incarnation,
        .node = .{ .incarnation = request.node_incarnation },
    }) catch |err| return switch (err) {
        error.Busy => error.Busy,
        error.InvalidOwner => error.InvalidOwner,
    };
    defer endRegisteredNodeOperation(operation);
    const node = operation.node;

    if (!streamOperationNodeIdle(node) or node.pin_owner.active_cleanup != 0)
        return error.Busy;
    const identity = request.reservation.identity;
    if (identity.slot_incarnation != request.slot_incarnation or
        identity.node_incarnation != request.node_incarnation or
        identity.host_id != request.host_id or identity.connection_generation != 1 or
        identity.pid != request.pid or identity.process_nonce != request.process_nonce)
        return error.InvalidOwner;
    const binding_owner_seal = node.cleanup_registry.transportOwnerSeal(
        request.reservation.cleanup,
        identity,
    ) catch return error.InvalidOwner;
    if (@intFromPtr(binding_owner_seal) != request.owner_seal_addr or
        !binding_owner_seal.valid(request.transport_incarnation))
        return error.InvalidOwner;
    if (node.client.host_id != request.host_id) return error.InvalidOwner;

    const profile = node.client.compatibility_profile orelse return error.InvalidOwner;
    const attach_schema_raw = @as(*const u8, @ptrCast(&profile.attach_schema)).*;
    const metadata_support_raw = @as(*const u8, @ptrCast(&node.client.metadata_support)).*;
    if (attach_schema_raw > @intFromEnum(compatibility.AttachSchema.granted_roles) or
        metadata_support_raw > @intFromEnum(contract.MetadataSupport.supported))
        return error.InvalidOwner;
    return .{
        .wire_major = node.client.wire_major,
        .screen_codec_version = node.client.screen_codec_version,
        .attach_schema = switch (profile.attach_schema) {
            .frozen_controller_only => .frozen_controller_only,
            .granted_roles => .granted_roles,
        },
        .metadata_support = switch (node.client.metadata_support) {
            .unsupported => .unsupported,
            .supported => .supported,
        },
        .peer_attach_generation = node.client.attachment_capabilities.peer_attach_generation,
        .screen_viewport_scrolled = node.client.screen_viewport_scrolled_v1,
        .async_scroll_to_bottom = node.client.async_scroll_to_bottom_v1,
        .notification_stream_auth = node.client.notification_stream_auth_v1,
        .runtime_clipboard = node.client.runtime_clipboard_v1,
        .runtime_core_command = node.client.runtime_core_command_v1,
        .runtime_link_at = node.client.runtime_link_at_v1,
        .runtime_selected_text = node.client.runtime_selected_text_v1,
    };
}

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn sliceOverlapsObject(bytes: []const u8, object: anytype) bool {
    if (bytes.len == 0) return false;
    const bytes_start = @intFromPtr(bytes.ptr);
    const bytes_end = std.math.add(usize, bytes_start, bytes.len) catch return true;
    const object_start = @intFromPtr(object);
    const object_end = std.math.add(usize, object_start, @sizeOf(@TypeOf(object.*))) catch
        return true;
    return bytes_start < object_end and object_start < bytes_end;
}

fn generationBatchOwnerAliases(
    slot: *ClientSlot,
    owned: *const batch_registry_mod.OwnedBatch,
) bool {
    return sliceOverlapsObject(owned.bytes, slot) or
        sliceOverlapsObject(owned.bytes, slot.current) or
        sliceOverlapsObject(owned.bytes, owned);
}

fn checkedObjectRange(address: usize, comptime T: type) ?struct { start: usize, end: usize } {
    if (address == 0) return null;
    return .{
        .start = address,
        .end = std.math.add(usize, address, @sizeOf(T)) catch return null,
    };
}

fn endedPurgeOwnersAlias(
    entry: ClientSlotRegistryEntry,
    reservation: AttachmentBindingReservation,
    scratch: *client_mod.EndedPurgeScratch,
    out: *EndedPurgePreparation,
) bool {
    const scratch_range = checkedObjectRange(@intFromPtr(scratch), client_mod.EndedPurgeScratch) orelse
        return true;
    const out_range = checkedObjectRange(@intFromPtr(out), EndedPurgePreparation) orelse return true;
    const slot_range = checkedObjectRange(entry.slot_addr, ClientSlot) orelse return true;
    const node_range = checkedObjectRange(entry.node_addr, ClientNode) orelse return true;
    const binding_range = checkedObjectRange(
        reservation.identity.binding_storage_addr,
        contract.PreparedAttachmentBinding,
    ) orelse return true;
    const destination_range = checkedObjectRange(
        reservation.identity.destination_addr,
        lease_mod.ConnectionLease,
    ) orelse return true;
    const owners = [_]@TypeOf(slot_range){ slot_range, node_range, binding_range, destination_range };
    if (rawRangesOverlap(scratch_range.start, scratch_range.end, out_range.start, out_range.end))
        return true;
    for (owners) |owner| {
        if (rawRangesOverlap(scratch_range.start, scratch_range.end, owner.start, owner.end) or
            rawRangesOverlap(out_range.start, out_range.end, owner.start, owner.end))
            return true;
    }
    return false;
}

fn endedPurgeAliasesClientOwnedBacking(
    client: *const client_mod.Client,
    scratch: *client_mod.EndedPurgeScratch,
    out: *EndedPurgePreparation,
) bool {
    const scratch_bytes: [*]u8 = @ptrCast(scratch);
    const out_bytes: [*]u8 = @ptrCast(out);
    return client_mod.generationAllocationAliasesOwnedBacking(
        client,
        scratch_bytes,
        @sizeOf(client_mod.EndedPurgeScratch),
    ) or client_mod.generationAllocationAliasesOwnedBacking(
        client,
        out_bytes,
        @sizeOf(EndedPurgePreparation),
    );
}

fn poisonEndedPurgeCorrupt(slot: *ClientSlot) EndedPurgePreparationError {
    if (slot.current.client.firstPoisonReason() == null)
        slot.current.client.poison(.local_invariant_violation);
    return error.Corrupt;
}

fn productionIssuer() InitError!*lease_mod.IdentityIssuer {
    const pid = currentPid();
    // Fork children must fail before touching a mutex that a vanished parent thread may have held.
    if (pid == 0 or process_runtime_pid.load(.acquire) != pid)
        return error.ProcessDomainMismatch;
    while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
    defer issuer_mutex.unlock();
    if ((process_issuer == null) != (ended_purge_quarantine_registry == null))
        @panic("process issuer and ended purge quarantine registry initialization diverged");
    return &(process_issuer orelse return error.ProcessDomainMismatch);
}

pub const ClientSlot = struct {
    const RegisteredClientOperation = struct {
        node: *ClientNode,
    };

    const ExclusiveTeardownReservation = struct {
        registry_entry: ClientSlotRegistryEntry,
        node: *ClientNode,
    };

    const PreparedStreamOperationPermitConsume = struct {
        const Lifecycle = enum(u8) { pristine, prepared, consumed };

        self_addr: usize = 0,
        registry_index: u16 = 0,
        registry_id: u64 = 0,
        slot_addr: usize = 0,
        slot_incarnation: u64 = 0,
        node_incarnation: u64 = 0,
        operation_generation: u64 = 0,
        permit_seal: owner_seal.Digest = [_]u8{0} ** 32,
        lifecycle: PreparedStreamOperationPermitConsume.Lifecycle = .pristine,
    };

    self_addr: usize,
    current: *ClientNode,
    node_allocator: std.mem.Allocator,
    incarnation: lease_mod.Identity,
    pid: u32,
    process_nonce: u64,
    operation_owner_thread_incarnation: u64,
    next_binding_incarnation: u64,
    lifecycle: Lifecycle,

    pub const ProcessRuntimeInitError = error{ProcessDomainMismatch};
    pub const EndedPurgeCommitError = error{
        InvalidOwner,
        InvalidState,
        Busy,
        Corrupt,
        ArithmeticOverflow,
        DestinationOccupied,
        QuarantineUnavailable,
    };
    pub const EndedPurgeResult = enum { purged };

    fn streamOperationPermitRawTagsValid(permit: *const StreamOperationPermit) bool {
        const kind_raw = @as(*const u8, @ptrCast(&permit.kind)).*;
        const role_raw = @as(*const u8, @ptrCast(&permit.binding.role)).*;
        return kind_raw <= @intFromEnum(StreamOperationKind.ended_purge) and
            role_raw <= @intFromEnum(contract.AttachmentRole.observer);
    }

    fn streamOperationPermitSeal(permit: StreamOperationPermit) owner_seal.Digest {
        var writer = owner_seal.Writer.init("maru.stream-operation-permit.v1");
        writer.writeUsize(@intFromPtr(permit.slot));
        writer.writeU16(permit.registry_index);
        writer.writeU64(permit.registry_id);
        writer.writeU64(permit.slot_incarnation);
        writer.writeU64(permit.node_incarnation);
        writer.writeU64(permit.generation);
        writer.writeU8(@intFromEnum(permit.kind));
        writer.writeU64(permit.owner_thread_incarnation);
        writer.writeUsize(permit.owner_addr);
        writer.writeU64(permit.transport_incarnation);
        writer.writeU64(permit.binding.binding_incarnation);
        writer.writeUsize(permit.binding.binding_storage_addr);
        writer.writeUsize(permit.binding.destination_addr);
        writer.writeU64(permit.binding.binding_reservation_id);
        writer.writeU64(permit.binding.slot_incarnation);
        writer.writeU64(permit.binding.node_incarnation);
        writer.writeU128(permit.binding.host_id);
        writer.writeU64(permit.binding.connection_generation);
        writer.writeU128(permit.binding.runtime_id);
        writer.writeU8(@intFromEnum(permit.binding.role));
        writer.writeU64(permit.binding.pid);
        writer.writeU64(permit.binding.process_nonce);
        return writer.finish();
    }

    pub fn initializeProcessRuntime() ProcessRuntimeInitError!void {
        const pid = currentPid();
        if (pid == 0) return error.ProcessDomainMismatch;
        const observed = process_runtime_pid.load(.acquire);
        if (observed != 0 and observed != pid) return error.ProcessDomainMismatch;
        if (observed == 0) {
            if (process_runtime_pid.cmpxchgStrong(0, pid, .acq_rel, .acquire)) |winner|
                if (winner != pid) return error.ProcessDomainMismatch;
        }

        while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
        defer issuer_mutex.unlock();
        if (process_runtime_pid.load(.acquire) != pid) return error.ProcessDomainMismatch;
        if ((process_issuer == null) != (ended_purge_quarantine_registry == null))
            @panic("process issuer and ended purge quarantine registry initialization diverged");
        if (process_issuer == null) {
            var nonce: u64 = 0;
            if (builtin.os.tag == .macos) {
                std.c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
            } else {
                // The product owner is macOS-only.  This non-secret fallback exists solely so
                // cross-target compile tests can instantiate the type without a Darwin syscall.
                nonce = @as(u64, pid) ^ @as(u64, @intFromPtr(&process_issuer));
            }
            if (nonce == 0) nonce = 1;
            ended_purge_quarantine_registry = ended_purge_quarantine.Registry.init();
            process_issuer = lease_mod.IdentityIssuer.init(pid, nonce);
        }
    }

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
            try productionIssuer(),
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
        const operation_owner_thread_incarnation = try acquireOperationThreadIncarnation();

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
        node.batch_registry = .{};
        batch_registry_mod.Registry.initInPlace(
            &node.batch_registry,
            node_identity.tagged,
        ) catch unreachable;
        node.accounting_ledger = .{};
        batch_registry_mod.AccountingLedger.initInPlace(&node.accounting_ledger) catch unreachable;
        node.next_operation_generation = 1;
        node.active_operation_generation = 0;
        node.active_operation_kind = .none;
        node.active_operation_owner_thread_incarnation = 0;
        node.active_operation_owner_addr = 0;
        node.active_operation_transport_incarnation = 0;
        node.active_operation_binding = undefined;
        node.guarded_allocator = .{
            .parent = source.allocator,
            .node_start = node_start,
            .node_end = node_end,
            .slot_start = out_start,
            .slot_end = out_end,
            .source_start = source_start,
            .source_end = source_end,
        };
        const registry_reservation: ClientSlotRegistryEntry = .{
            .live = true,
            .slot_addr = out_start,
            .node_addr = node_start,
            .slot_incarnation = slot_identity.tagged,
            .node_incarnation = node_identity.tagged,
            .owner_thread_incarnation = operation_owner_thread_incarnation,
        };
        try registerClientSlot(registry_reservation);
        source.moveToGenerationNode(&node.client);
        client_mod.ClientOperationFence.initInPlace(
            &node.operation_fence,
            @intFromPtr(&node.client),
            pid,
            slot_identity.tagged,
            node_identity.tagged,
            node_identity.tagged,
        );
        if (!node.client.bindOperationFence(&node.operation_fence, node_identity.tagged))
            @panic("Client operation fence binding failed");
        node.guarded_allocator.client = &node.client;
        node.client.bindGenerationAccountingLedger(&node.accounting_ledger) catch unreachable;
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
            .operation_owner_thread_incarnation = operation_owner_thread_incarnation,
            .next_binding_incarnation = 1,
            .lifecycle = .live,
        };
        publishClientSlot(registry_reservation);
    }

    fn rangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
        return a_start < b_end and b_start < a_end;
    }

    fn beginRegisteredClientOperation(
        self: *ClientSlot,
    ) error{ MovedOrCopied, AdminBusy }!RegisteredClientOperation {
        // Reject a fork child before touching a mutex inherited from another thread. Holding the
        // registry mutex through the shared-fence CAS closes node destroy vs operation-entry ABA:
        // teardown cannot unregister/destroy between registry validation and the Client pin.
        if (self.pid != currentPid()) return error.MovedOrCopied;
        const operation = beginRegisteredNodeOperation(.{
            .slot_addr = @intFromPtr(self),
            .slot_incarnation = self.incarnation.tagged,
            .node = .{ .address = @intFromPtr(self.current) },
            .owner_thread_incarnation = self.operation_owner_thread_incarnation,
        }) catch |err| return switch (err) {
            error.Busy => error.AdminBusy,
            error.InvalidOwner => error.MovedOrCopied,
        };
        return .{ .node = operation.node };
    }

    fn endRegisteredClientOperation(_: *ClientSlot, operation: RegisteredClientOperation) void {
        // The shared count itself keeps the node alive until this exact decrement.
        endRegisteredNodeOperation(.{ .node = operation.node });
    }

    fn beginRegisteredExclusiveTeardown(
        self: *ClientSlot,
    ) error{ MovedOrCopied, AdminBusy }!ExclusiveTeardownReservation {
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return error.MovedOrCopied;
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        for (&client_slot_registry) |*entry| {
            if (!entry.live or entry.slot_addr != @intFromPtr(self)) continue;
            if (entry.node_addr == 0 or entry.node_addr != @intFromPtr(self.current) or
                entry.slot_incarnation != self.incarnation.tagged or
                entry.node_incarnation == 0 or
                entry.owner_thread_incarnation != self.operation_owner_thread_incarnation)
                return error.MovedOrCopied;
            if (!entry.ready) return error.AdminBusy;
            const node: *ClientNode = @ptrFromInt(entry.node_addr);
            // Close registry admission while exclusive is held. New operations fail at the
            // registry instead of setting fence intrusion. Direct Client calls can still record
            // intrusion, so pre-callback rollback uses abortExclusive to clear both bits.
            entry.ready = false;
            node.client.tryAcquireClientSlotTeardownExclusive() catch |err| {
                entry.ready = true;
                return switch (err) {
                    error.AdminBusy => error.AdminBusy,
                    error.InvalidOwner, error.InvalidState => error.MovedOrCopied,
                };
            };
            return .{ .registry_entry = entry.*, .node = node };
        }
        return error.MovedOrCopied;
    }

    fn abortRegisteredExclusiveTeardown(
        _: *ClientSlot,
        reserved: ExclusiveTeardownReservation,
    ) void {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        for (&client_slot_registry) |*entry| {
            if (!std.meta.eql(entry.*, reserved.registry_entry)) continue;
            if (!reserved.node.client.abortClientSlotTeardownExclusive())
                @panic("ClientSlot teardown exclusive abort failed");
            entry.ready = true;
            return;
        }
        @panic("ClientSlot teardown registry reservation drifted");
    }

    pub fn valid(self: *const ClientSlot) bool {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != .live or
            self.pid != currentPid() or self.process_nonce == 0 or
            self.operation_owner_thread_incarnation == 0 or
            self.incarnation.kind() != .slot)
            return false;
        _ = self.current.cleanup_registry.count() catch return false;
        _ = self.current.batch_registry.count() catch return false;
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
            self.current.cleanup_registry.incarnation == self.current.incarnation.tagged and
            self.current.batch_registry.self_addr == @intFromPtr(&self.current.batch_registry) and
            self.current.batch_registry.incarnation == self.current.incarnation.tagged and
            self.current.accounting_ledger.matchesClient(@intFromPtr(&self.current.client));
    }

    pub fn reserveAttachmentBinding(
        self: *ClientSlot,
        binding_out: *contract.PreparedAttachmentBinding,
        lease_out: *lease_mod.ConnectionLease,
        runtime_id: u128,
        role: contract.AttachmentRole,
    ) BindingError!AttachmentBindingReservation {
        const operation = try self.beginRegisteredClientOperation();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
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
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
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
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
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
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
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
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        if (operation.node.active_operation_generation != 0) return error.AdminBusy;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        if (!contract.attachmentRoleRawValid(&reservation.identity.role))
            return error.InvalidIdentity;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .committed or
            lease.stream_id == 0 or !lease.canRelease(self.pid))
            return error.InvalidLease;
        try operation.node.cleanup_registry.preflightBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        );

        operation.node.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        ) catch unreachable;
        operation.node.pin_owner.active_cleanup = 1;
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

    fn beginCanonicalAuthorityAccess(
        self: *ClientSlot,
    ) BindingError!RegisteredClientOperation {
        // These methods protect the canonical input authority itself, so they cannot rely on the
        // caller having reached them through GenerationTransport. Reject fork/thread aliases
        // before node dereference, then pin the exact registered node against concurrent teardown.
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return error.MovedOrCopied;
        return self.beginRegisteredClientOperation() catch |err| switch (err) {
            error.MovedOrCopied => error.MovedOrCopied,
            error.AdminBusy => error.AdminBusy,
        };
    }

    pub fn controllerAuthorityLive(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!bool {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        return operation.node.cleanup_registry.controllerAuthorityLive(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn controllerRevokePending(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!bool {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        return operation.node.cleanup_registry.controllerRevokePending(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn beginControllerRevoke(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!void {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        try operation.node.cleanup_registry.beginControllerRevoke(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn finishControllerRevoke(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!void {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        try operation.node.cleanup_registry.finishControllerRevoke(
            reservation.cleanup,
            reservation.identity,
            stream_id,
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

    pub const AttachmentBatchRead = union(enum) {
        committed: batch_registry_mod.Token,
        idle,
        terminal,
    };

    pub const BatchError = client_mod.ClientError || batch_registry_mod.Error;

    pub const GenerationBatchAdapterIdentity = struct {
        slot_incarnation: u64,
        node_incarnation: u64,
        pid: u32,
        process_nonce: u64,
    };

    /// Final-address GUI batch adapter가 raw node/Client 포인터를 보관하지 않고도 exact slot을
    /// 매 호출 재검증할 수 있는 pointer-free identity다.
    pub fn generationBatchAdapterIdentity(
        self: *ClientSlot,
    ) error{MovedOrCopied}!GenerationBatchAdapterIdentity {
        if (!self.valid()) return error.MovedOrCopied;
        return .{
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        };
    }

    pub fn matchesGenerationBatchAdapterIdentity(
        self: *ClientSlot,
        identity: GenerationBatchAdapterIdentity,
    ) bool {
        return self.valid() and self.incarnation.tagged == identity.slot_incarnation and
            self.current.incarnation.tagged == identity.node_incarnation and
            self.pid == identity.pid and self.process_nonce == identity.process_nonce;
    }

    pub fn poisonAttachmentConnection(
        self: *ClientSlot,
        reason: @import("client_poison.zig").ConnectionReason,
    ) error{MovedOrCopied}!void {
        if (!self.valid()) return error.MovedOrCopied;
        self.current.client.poison(reason);
    }

    /// Client의 allocator callback TLS는 node-local mutation 진입점들이 같은 방식으로 읽는다.
    fn generationAllocatorCallbackActive(self: *const ClientSlot) bool {
        self.current.client.rejectGenerationAllocatorCallbackReentry() catch return true;
        return false;
    }

    pub const InitialSnapshotRead = struct {
        bytes: []u8,
        allocator: std.mem.Allocator,
    };

    pub fn prepareInitialSnapshotPermit(
        self: *ClientSlot,
        owner_addr: usize,
        transport_incarnation: u64,
        binding: contract.BindingIdentity,
    ) error{ InvalidSnapshotPermit, AdminBusy, IdentityExhausted }!InitialSnapshotPermit {
        return self.prepareStreamOperationPermit(
            .initial_snapshot,
            owner_addr,
            transport_incarnation,
            binding,
        ) catch |err| switch (err) {
            error.InvalidStreamOperationPermit => error.InvalidSnapshotPermit,
            error.AdminBusy => error.AdminBusy,
            error.IdentityExhausted => error.IdentityExhausted,
        };
    }

    pub fn prepareStreamOperationPermit(
        self: *ClientSlot,
        kind: StreamOperationKind,
        owner_addr: usize,
        transport_incarnation: u64,
        binding: contract.BindingIdentity,
    ) error{ InvalidStreamOperationPermit, AdminBusy, IdentityExhausted }!StreamOperationPermit {
        if (client_mod.generationAllocatorCallbackActive()) return error.AdminBusy;
        const operation = self.beginRegisteredClientOperation() catch |err| return switch (err) {
            error.AdminBusy => error.AdminBusy,
            error.MovedOrCopied => error.InvalidStreamOperationPermit,
        };
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation) or
            kind == .none or owner_addr == 0 or transport_incarnation == 0 or
            binding.slot_incarnation != self.incarnation.tagged or
            binding.node_incarnation != self.current.incarnation.tagged or
            binding.host_id != self.current.client.host_id or
            binding.connection_generation != 1 or binding.pid != self.pid or
            binding.process_nonce != self.process_nonce)
            return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.active_operation_generation != 0 or
            self.current.pin_owner.active_cleanup != 0)
            return error.AdminBusy;
        const generation = self.current.next_operation_generation;
        const next_generation = std.math.add(u64, generation, 1) catch
            return error.IdentityExhausted;
        const owner_thread_incarnation = self.operation_owner_thread_incarnation;
        const permit = try registerStreamOperationPermit(.{
            .slot = self,
            .registry_index = 0,
            .registry_id = 0,
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .generation = generation,
            .kind = kind,
            .owner_thread_incarnation = owner_thread_incarnation,
            .owner_addr = owner_addr,
            .transport_incarnation = transport_incarnation,
            .binding = binding,
        });
        self.current.next_operation_generation = next_generation;
        self.current.active_operation_generation = generation;
        self.current.active_operation_kind = kind;
        self.current.active_operation_owner_thread_incarnation = owner_thread_incarnation;
        self.current.active_operation_owner_addr = owner_addr;
        self.current.active_operation_transport_incarnation = transport_incarnation;
        self.current.active_operation_binding = binding;
        return permit;
    }

    pub fn initialSnapshotPermitLive(
        self: *const ClientSlot,
        permit: InitialSnapshotPermit,
    ) bool {
        return streamOperationPermitRawTagsValid(&permit) and
            permit.kind == .initial_snapshot and self.streamOperationPermitLive(permit);
    }

    pub fn streamOperationPermitLive(
        self: *const ClientSlot,
        permit: StreamOperationPermit,
    ) bool {
        if (!streamOperationPermitRawTagsValid(&permit)) return false;
        if (!operationThreadMatches(permit.owner_thread_incarnation)) return false;
        if (!streamOperationPermitRegistryLive(permit)) return false;
        return self.valid() and permit.slot == self and
            permit.slot_incarnation == self.incarnation.tagged and
            permit.node_incarnation == self.current.incarnation.tagged and
            permit.generation != 0 and
            permit.generation == self.current.active_operation_generation and
            permit.kind != .none and permit.kind == self.current.active_operation_kind and
            permit.owner_thread_incarnation == self.operation_owner_thread_incarnation and
            permit.owner_thread_incarnation == self.current.active_operation_owner_thread_incarnation and
            permit.owner_addr == self.current.active_operation_owner_addr and
            permit.transport_incarnation == self.current.active_operation_transport_incarnation and
            std.meta.eql(permit.binding, self.current.active_operation_binding);
    }

    pub fn abortInitialSnapshotPermit(
        self: *ClientSlot,
        permit: InitialSnapshotPermit,
    ) error{InvalidSnapshotPermit}!void {
        if (!self.initialSnapshotPermitLive(permit)) return error.InvalidSnapshotPermit;
        self.abortStreamOperationPermit(permit) catch return error.InvalidSnapshotPermit;
    }

    pub fn consumeInitialSnapshotPermit(
        self: *ClientSlot,
        permit: InitialSnapshotPermit,
    ) error{InvalidSnapshotPermit}!void {
        if (!self.initialSnapshotPermitLive(permit)) return error.InvalidSnapshotPermit;
        self.consumeStreamOperationPermit(permit) catch return error.InvalidSnapshotPermit;
    }

    pub fn initialSnapshotPermitIdle(self: *const ClientSlot) bool {
        return self.streamOperationPermitIdle();
    }

    pub fn abortStreamOperationPermit(
        self: *ClientSlot,
        permit: StreamOperationPermit,
    ) error{InvalidStreamOperationPermit}!void {
        if (!self.streamOperationPermitLive(permit)) return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.pin_owner.active_cleanup != 0)
            return error.InvalidStreamOperationPermit;
        if (self.generationAllocatorCallbackActive())
            return error.InvalidStreamOperationPermit;
        try unregisterStreamOperationPermit(permit);
        self.clearStreamOperationPermit();
    }

    pub fn consumeStreamOperationPermit(
        self: *ClientSlot,
        permit: StreamOperationPermit,
    ) error{InvalidStreamOperationPermit}!void {
        if (!self.streamOperationPermitLive(permit)) return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.pin_owner.active_cleanup != 0)
            return error.InvalidStreamOperationPermit;
        if (self.generationAllocatorCallbackActive())
            return error.InvalidStreamOperationPermit;
        try unregisterStreamOperationPermit(permit);
        self.clearStreamOperationPermit();
    }

    fn prepareStreamOperationPermitConsume(
        self: *ClientSlot,
        permit: StreamOperationPermit,
        out: *PreparedStreamOperationPermitConsume,
    ) error{ InvalidStreamOperationPermit, DestinationOccupied }!void {
        if (!streamOperationPermitRawTagsValid(&permit) or self.pid != currentPid() or
            !operationThreadMatches(permit.owner_thread_incarnation))
            return error.InvalidStreamOperationPermit;
        if (!std.meta.eql(out.*, PreparedStreamOperationPermitConsume{}))
            return error.DestinationOccupied;
        const index: usize = permit.registry_index;
        if (index >= stream_operation_registry.len or permit.registry_id == 0 or
            !self.valid() or permit.slot != self or
            permit.slot_incarnation != self.incarnation.tagged or
            permit.node_incarnation != self.current.incarnation.tagged or
            permit.generation == 0 or
            permit.generation != self.current.active_operation_generation or
            permit.kind == .none or permit.kind != self.current.active_operation_kind or
            permit.owner_thread_incarnation != self.operation_owner_thread_incarnation or
            permit.owner_thread_incarnation !=
                self.current.active_operation_owner_thread_incarnation or
            permit.owner_addr != self.current.active_operation_owner_addr or
            permit.transport_incarnation != self.current.active_operation_transport_incarnation or
            !std.meta.eql(permit.binding, self.current.active_operation_binding))
            return error.InvalidStreamOperationPermit;

        while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer stream_operation_registry_mutex.unlock();
        const entry = &stream_operation_registry[index];
        if (entry.state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.live) or
            entry.id != permit.registry_id or !std.meta.eql(entry.permit, permit))
            return error.InvalidStreamOperationPermit;
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.live),
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
            .acq_rel,
            .acquire,
        ) != null) return error.InvalidStreamOperationPermit;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .registry_index = permit.registry_index,
            .registry_id = permit.registry_id,
            .slot_addr = @intFromPtr(self),
            .slot_incarnation = permit.slot_incarnation,
            .node_incarnation = permit.node_incarnation,
            .operation_generation = permit.generation,
            .permit_seal = streamOperationPermitSeal(permit),
            .lifecycle = .prepared,
        };
    }

    fn consumeStreamOperationPermitUnchecked(
        self: *ClientSlot,
        prepared: *PreparedStreamOperationPermitConsume,
    ) bool {
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return false;
        const index: usize = prepared.registry_index;
        const lifecycle_raw = @as(*const u8, @ptrCast(&prepared.lifecycle)).*;
        if (index >= stream_operation_registry.len or
            lifecycle_raw != @intFromEnum(PreparedStreamOperationPermitConsume.Lifecycle.prepared) or
            prepared.self_addr != @intFromPtr(prepared) or
            prepared.registry_id == 0 or prepared.slot_addr != @intFromPtr(self) or
            prepared.slot_incarnation != self.incarnation.tagged or
            prepared.node_incarnation != self.current.incarnation.tagged or
            prepared.operation_generation == 0 or
            prepared.operation_generation != self.current.active_operation_generation)
            return false;
        const entry = &stream_operation_registry[index];
        if (entry.state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved) or
            entry.id != prepared.registry_id or
            !streamOperationPermitRawTagsValid(&entry.permit) or
            !std.mem.eql(
                u8,
                &prepared.permit_seal,
                &streamOperationPermitSeal(entry.permit),
            ) or
            entry.permit.slot != self or
            entry.permit.slot_incarnation != prepared.slot_incarnation or
            entry.permit.node_incarnation != prepared.node_incarnation or
            entry.permit.generation != prepared.operation_generation or
            entry.permit.kind != self.current.active_operation_kind or
            entry.permit.owner_thread_incarnation !=
                self.current.active_operation_owner_thread_incarnation or
            entry.permit.owner_addr != self.current.active_operation_owner_addr or
            entry.permit.transport_incarnation !=
                self.current.active_operation_transport_incarnation or
            !std.meta.eql(entry.permit.binding, self.current.active_operation_binding))
            return false;
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
            @intFromEnum(StreamOperationRegistryEntry.State.consumed),
            .acq_rel,
            .acquire,
        ) != null) return false;
        self.clearStreamOperationPermit();
        prepared.lifecycle = .consumed;
        return true;
    }

    pub fn streamOperationPermitIdle(self: *const ClientSlot) bool {
        return self.valid() and streamOperationNodeIdle(self.current);
    }

    pub fn prepareEndedPurge(
        self: *ClientSlot,
        transport_incarnation: u64,
        reservation: AttachmentBindingReservation,
        target_stream: u64,
        hint: client_mod.EndedEventHint,
        scratch: *client_mod.EndedPurgeScratch,
        out: *EndedPurgePreparation,
    ) EndedPurgePreparationError!void {
        // A fork child must reject from caller-owned slot storage before touching a process-global
        // mutex that may have been inherited locked by a vanished sibling thread.
        if (self.pid != currentPid()) return error.InvalidOwner;
        const registry_entry = clientSlotRegistryEntry(@intFromPtr(self)) orelse
            return error.InvalidOwner;
        if (!operationThreadMatches(registry_entry.owner_thread_incarnation))
            return error.InvalidOwner;
        if (!self.valid() or registry_entry.node_addr != @intFromPtr(self.current) or
            registry_entry.slot_incarnation != self.incarnation.tagged or
            registry_entry.node_incarnation != self.current.incarnation.tagged or
            registry_entry.owner_thread_incarnation != self.operation_owner_thread_incarnation)
            return error.InvalidOwner;
        if (endedPurgeOwnersAlias(registry_entry, reservation, scratch, out))
            return error.InvalidOwner;
        if (endedPurgeAliasesClientOwnedBacking(&self.current.client, scratch, out))
            return error.InvalidOwner;
        if (out.lifecycle != .empty or out.self_addr != 0 or out.target_stream != 0 or
            !std.mem.allEqual(u8, &out.authority_seal, 0) or
            !std.meta.eql(out.inventory, client_mod.PreparedEndedPurgeInventory{}))
            return error.DestinationOccupied;
        self.current.cleanup_registry.preflightBoundDrop(
            reservation.cleanup,
            reservation.identity,
            target_stream,
        ) catch return error.InvalidOwner;
        const idle_before = self.current.batch_registry.streamIdle(target_stream) catch {
            return poisonEndedPurgeCorrupt(self);
        };
        if (!idle_before) return error.Busy;
        const permit = self.prepareStreamOperationPermit(
            .ended_purge,
            @intFromPtr(out),
            transport_incarnation,
            reservation.identity,
        ) catch |err| return switch (err) {
            error.InvalidStreamOperationPermit => error.InvalidOwner,
            error.AdminBusy => error.Busy,
            error.IdentityExhausted => error.IdentityExhausted,
        };
        errdefer self.abortStreamOperationPermit(permit) catch
            @panic("ended purge preparation permit rollback failed");
        const idle = self.current.batch_registry.streamIdle(target_stream) catch {
            return poisonEndedPurgeCorrupt(self);
        };
        if (!idle) return error.Busy;
        self.current.client.prepareEndedPurgeInventory(
            target_stream,
            hint,
            scratch,
            &out.inventory,
        ) catch |err| switch (err) {
            error.DestinationOccupied => return error.DestinationOccupied,
            error.InvalidHint,
            error.InvalidSource,
            error.InvalidAlias,
            error.ArithmeticOverflow,
            => return poisonEndedPurgeCorrupt(self),
        };
        out.self_addr = @intFromPtr(out);
        out.target_stream = target_stream;
        out.permit = permit;
        out.lifecycle = .prepared;
        out.authority_seal = endedPurgePreparationSeal(out);
    }

    pub fn commitEndedPurge(
        self: *ClientSlot,
        scratch: *client_mod.EndedPurgeScratch,
        preparation: *EndedPurgePreparation,
    ) EndedPurgeCommitError!EndedPurgeResult {
        // Fork children must reject before touching either inherited process-global registry.
        const pid = currentPid();
        if (pid == 0 or self.pid != pid or process_runtime_pid.load(.acquire) != pid)
            return error.InvalidOwner;
        const registry_entry = clientSlotRegistryEntry(@intFromPtr(self)) orelse
            return error.InvalidOwner;
        if (!operationThreadMatches(registry_entry.owner_thread_incarnation) or
            !self.valid() or registry_entry.node_addr != @intFromPtr(self.current) or
            registry_entry.slot_incarnation != self.incarnation.tagged or
            registry_entry.node_incarnation != self.current.incarnation.tagged or
            !preparation.rawTagsValid() or preparation.lifecycle != .prepared or
            preparation.self_addr != @intFromPtr(preparation) or
            preparation.target_stream == 0 or
            preparation.permit.owner_addr != @intFromPtr(preparation) or
            preparation.inventory.scratch_addr != @intFromPtr(scratch) or
            !std.mem.eql(
                u8,
                &preparation.authority_seal,
                &endedPurgePreparationSeal(preparation),
            ) or
            !self.streamOperationPermitLive(preparation.permit))
            return error.InvalidOwner;

        self.current.client.tryAcquireEndedPurgeExclusive() catch |err| return switch (err) {
            error.AdminBusy => error.Busy,
            error.InvalidOwner => error.InvalidOwner,
            error.InvalidState => error.InvalidState,
        };
        var release_exclusive = true;
        defer if (release_exclusive and
            !self.current.client.releaseEndedPurgeExclusiveClean())
            @panic("ended purge precommit exclusive rollback failed");

        var client_prepared: client_mod.PreparedEndedPurgeCommit = .{};
        self.current.client.prepareEndedPurgeCommit(
            preparation.target_stream,
            preparation.permit.generation,
            scratch,
            &preparation.inventory,
            &client_prepared,
        ) catch |err| return switch (err) {
            error.InvalidOwner => error.InvalidOwner,
            error.InvalidState => error.Busy,
            error.Corrupt => error.Corrupt,
            error.ArithmeticOverflow => error.ArithmeticOverflow,
            error.DestinationOccupied => error.DestinationOccupied,
        };

        const quarantine_registry = &(ended_purge_quarantine_registry orelse
            @panic("ended purge quarantine registry missing after process bootstrap"));
        var quarantine_reservation: ended_purge_quarantine.Reservation = .{};
        quarantine_registry.reserve(
            self.current.incarnation.tagged,
            preparation.permit.generation,
            client_prepared.complete_owned_extent_bytes,
            &quarantine_reservation,
        ) catch |err| {
            scratch.lifecycle = .inventory_prepared;
            client_prepared = .{};
            return switch (err) {
                error.InvalidOwner => error.InvalidOwner,
                error.ArithmeticOverflow => error.ArithmeticOverflow,
                error.InvalidState, error.CapacityExceeded => error.QuarantineUnavailable,
            };
        };

        var permit_consume: PreparedStreamOperationPermitConsume = .{};
        self.prepareStreamOperationPermitConsume(
            preparation.permit,
            &permit_consume,
        ) catch |err| {
            if (!quarantine_registry.release(&quarantine_reservation))
                @panic("ended purge quarantine rollback failed");
            scratch.lifecycle = .inventory_prepared;
            client_prepared = .{};
            return switch (err) {
                error.InvalidStreamOperationPermit => error.InvalidOwner,
                error.DestinationOccupied => error.DestinationOccupied,
            };
        };
        if (!preparation.sealForCommit(self))
            @panic("ended purge transport receipt seal failed after permit consume reservation");

        const outcome = self.current.client.commitEndedPurgePrepared(
            preparation.permit.generation,
            scratch,
            &preparation.inventory,
            &client_prepared,
        );
        switch (outcome) {
            .clean => {
                if (!quarantine_registry.release(&quarantine_reservation))
                    @panic("ended purge clean quarantine release failed");
            },
            .drift_pending_finalize => {
                var commit_receipt: ended_purge_quarantine.CommitReceipt = .{};
                if (!quarantine_registry.commit(&quarantine_reservation, &commit_receipt))
                    @panic("ended purge quarantine commit failed");
                var proof: ended_purge_quarantine.ConsumedCommitProof = .{};
                if (!quarantine_registry.consumeCommitted(&commit_receipt, &proof))
                    @panic("ended purge quarantine proof consume failed");
                self.current.client.finalizeEndedPurgeNoFreePoison(
                    preparation.permit.generation,
                    &client_prepared,
                    proof,
                );
                release_exclusive = false;
            },
        }
        if (!self.consumeStreamOperationPermitUnchecked(&permit_consume))
            @panic("ended purge node permit consume failed");
        preparation.consumeAfterPermit(self);
        return .purged;
    }

    fn clearStreamOperationPermit(self: *ClientSlot) void {
        self.current.active_operation_generation = 0;
        self.current.active_operation_kind = .none;
        self.current.active_operation_owner_thread_incarnation = 0;
        self.current.active_operation_owner_addr = 0;
        self.current.active_operation_transport_incarnation = 0;
        self.current.active_operation_binding = undefined;
    }

    pub fn readInitialSnapshotGuarded(
        self: *ClientSlot,
        stream_id: u64,
        owner_addr: usize,
        owner_size: usize,
        out_addr: usize,
        out_size: usize,
    ) (client_mod.ClientError || batch_registry_mod.Error || error{
        AliasedAllocation,
        InvalidDestination,
    })!InitialSnapshotRead {
        if (!self.valid()) return error.MovedOrCopied;
        if (stream_id == 0 or owner_addr == 0 or owner_size == 0 or out_addr == 0 or out_size == 0)
            return error.InvalidDestination;
        const owner_end = std.math.add(usize, owner_addr, owner_size) catch
            return error.InvalidDestination;
        const out_end = std.math.add(usize, out_addr, out_size) catch
            return error.InvalidDestination;
        const guard = &self.current.guarded_allocator;
        if (guard.snapshot_guard_active) return error.AdminBusy;
        guard.snapshot_owner_start = owner_addr;
        guard.snapshot_owner_end = owner_end;
        guard.snapshot_out_start = out_addr;
        guard.snapshot_out_end = out_end;
        guard.snapshot_alias_rejected = false;
        guard.snapshot_guard_active = true;
        defer {
            guard.snapshot_guard_active = false;
            guard.snapshot_owner_start = 0;
            guard.snapshot_owner_end = 0;
            guard.snapshot_out_start = 0;
            guard.snapshot_out_end = 0;
        }
        const allocator = guard.allocator();
        const previous_allocator = try self.current.client.beginGenerationBatchAllocator(allocator);
        defer self.current.client.restoreGenerationBatchAllocatorUnchecked(previous_allocator);
        const bytes = self.current.client.readSnapshot(stream_id) catch |err| {
            if (guard.snapshot_alias_rejected) {
                self.current.client.poison(.local_invariant_violation);
                return error.AliasedAllocation;
            }
            return err;
        };
        if (guard.snapshot_alias_rejected) {
            self.current.client.poison(.local_invariant_violation);
            return error.AliasedAllocation;
        }
        return .{ .bytes = bytes, .allocator = allocator };
    }

    /// Registry entry를 먼저 ingress로 고정한 뒤 Client queue/parser owner를 옮긴다.
    pub fn readAttachmentBatch(
        self: *ClientSlot,
        stream_id: u64,
    ) BatchError!AttachmentBatchRead {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        // buffered payload의 free callback에서는 allocation 없는 exact pending sibling만 허용한다.
        // miss를 parser/socket으로 내리면 parent allocator callback 안에서 wire와 allocator를 재진입한다.
        if (batch_release_callback_active)
            try self.current.client.requireBufferedGenerationBatch(stream_id);
        // allocator callback 재진입은 registry generation을 예약하기 전에 막는다. 이 순서가 뒤집히면
        // 최종 entry를 abort해도 재진입만으로 checked-monotonic generation이 소모된다.
        const previous_allocator = try self.current.client.beginGenerationBatchAllocator(
            self.current.guarded_allocator.allocator(),
        );
        defer self.current.client.restoreGenerationBatchAllocatorUnchecked(previous_allocator);
        const reservation = try self.current.batch_registry.reserve(stream_id);
        var reservation_live = true;
        defer if (reservation_live)
            self.current.batch_registry.abort(reservation) catch
                @panic("generation batch reservation rollback drifted");
        try self.current.batch_registry.prepareIngress(reservation);
        var owned: batch_registry_mod.OwnedBatch = .{};
        switch (try self.current.client.readGenerationBatch(
            &owned,
            stream_id,
            reservation.entry_generation,
        )) {
            .idle => return .idle,
            .terminal => return .terminal,
            .committed => {
                // allocator가 payload를 slot/node/stack owner와 alias하면 어느 descriptor도 안전한
                // free 권위를 증명할 수 없다. strict GUI adapter는 registry publication 전에 fail-stop한다.
                if (generationBatchOwnerAliases(self, &owned))
                    @panic("generation batch payload aliases canonical owner");
                const token = self.current.batch_registry.commitIngressUnchecked(
                    reservation,
                    &owned,
                );
                reservation_live = false;
                return .{ .committed = token };
            },
        }
    }

    pub fn borrowAttachmentBatch(
        self: *ClientSlot,
        token: batch_registry_mod.Token,
    ) batch_registry_mod.Error!batch_registry_mod.BatchView {
        if (!self.valid()) return error.MovedOrCopied;
        return self.current.batch_registry.borrow(token);
    }

    /// Accounting consume까지 callback 전에 검증한 뒤 free→consume→entry settle을 무실패로 끝낸다.
    pub fn releaseAttachmentBatch(
        self: *ClientSlot,
        token: batch_registry_mod.Token,
    ) BatchError!void {
        const operation = try self.beginRegisteredClientOperation();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        if (batch_release_callback_active) return error.AdminBusy;
        if (self.generationAllocatorCallbackActive()) return error.AdminBusy;
        var cleanup: batch_registry_mod.OwnedBatch = .{};
        const receipt = try self.current.batch_registry.preflightRelease(token, &cleanup);
        const accounting = try self.current.client.prepareGenerationAccountingConsume(receipt);
        self.current.batch_registry.beginReleaseUnchecked(token, &cleanup);
        {
            batch_release_callback_active = true;
            defer batch_release_callback_active = false;
            cleanup.allocator.?.free(cleanup.bytes);
        }
        self.current.client.consumeGenerationAccountingUnchecked(accounting);
        cleanup.bytes = &.{};
        cleanup.allocator = null;
        cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
        cleanup.completeCleanupUnchecked();
        self.current.batch_registry.finishReleaseUnchecked(token, &cleanup);
    }

    pub fn tryDeinit(self: *ClientSlot) DeinitOutcome {
        if (self.lifecycle == .dead) return .already_dead;
        if (self.lifecycle == .deinit_reserved) return .busy;
        // Teardown shares the canonical operation thread with admission. This closes the gap
        // between a registry liveness snapshot and the first node dereference without adding a
        // second cross-thread lifetime protocol. PID is checked before the process-global mutex so
        // a fork child cannot spin on a lock inherited from a vanished sibling thread.
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation)) return .corrupt;
        const reserved_registry_entry = self.beginRegisteredExclusiveTeardown() catch |err|
            return switch (err) {
                error.AdminBusy => .busy,
                error.MovedOrCopied => .corrupt,
            };
        var exclusive_reserved = true;
        defer if (exclusive_reserved)
            self.abortRegisteredExclusiveTeardown(reserved_registry_entry);
        const node = reserved_registry_entry.node;
        if (!self.valid()) return if (self.lifecycle == .deinit_reserved) .busy else .corrupt;
        if (batch_release_callback_active) return .busy;
        if (self.generationAllocatorCallbackActive()) return .busy;
        if (node.active_operation_generation != 0) return .busy;
        if (node.pin_owner.cleanup_pin_count != 0 or
            node.pin_owner.active_cleanup != 0)
            return .busy;
        // 두 registry 중 하나를 먼저 dead로 만든 뒤 다른 쪽 busy/corrupt를 발견하면 재시도할 수 없다.
        // 둘의 전체 entry를 먼저 검증한 뒤에만 mutation suffix에 들어간다.
        const cleanup_ready = node.cleanup_registry.preflightDeinit();
        const batch_ready = node.batch_registry.preflightDeinit();
        const accounting_ready = node.accounting_ledger.preflightDeinit();
        if (cleanup_ready == .busy or batch_ready == .busy or accounting_ready == .busy)
            return .busy;
        if (cleanup_ready != .cleaned or batch_ready != .cleaned or accounting_ready != .cleaned)
            return .corrupt;
        // Client teardown owns the cross-thread operation fence. It must succeed before any slot
        // registry becomes terminal; otherwise a concurrent shared Client operation would make
        // tryDeinit return false and freeing the node would turn that retry signal into a UAF.
        if (!node.client.tryDeinitClientSlotExclusiveHeld()) return .busy;
        exclusive_reserved = false;
        switch (node.cleanup_registry.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("fenced ClientSlot cleanup registry teardown drifted"),
        }
        switch (node.batch_registry.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("fenced ClientSlot batch registry teardown drifted"),
        }
        self.lifecycle = .deinit_reserved;
        if (!unregisterClientSlot(reserved_registry_entry.registry_entry))
            @panic("preflighted ClientSlot registry teardown drifted");
        node.pin_owner.state = .terminal;
        switch (node.accounting_ledger.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("preflighted generation accounting teardown drifted"),
        }
        self.node_allocator.destroy(node);
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

test "CR3a B3b-F ClientSlot preserves its node when Client teardown is busy" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Runner = struct {
        fn run(client: *client_mod.Client) void {
            if (client.call("host.info", null)) |response|
                client.allocator.free(response)
            else |_| {}
        }
    };

    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    var peer_live = true;
    defer {
        if (peer_live) _ = c.close(fds[1]);
    }
    var source = fixtureClient(allocator, 0xAD);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAD);

    const thread = try std.Thread.spawn(.{}, Runner.run, .{&slot.current.client});
    var ready = c.pollfd{ .fd = fds[1], .events = c.POLL.IN, .revents = 0 };
    try std.testing.expect(c.poll(@ptrCast(&ready), 1, 1_000) > 0);
    try std.testing.expect(ready.revents & c.POLL.IN != 0);
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try std.testing.expect(slot.valid());
    try std.testing.expect(clientSlotRegistryEntry(@intFromPtr(&slot)) != null);

    _ = c.close(fds[1]);
    peer_live = false;
    thread.join();
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a B3b-F allocator callback permit rejection does not intrude on exclusive teardown" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xAE);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAE);

    try slot.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(slot.current.client.enterGenerationAllocatorCallback());
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(.initial_snapshot, 1, 1, std.mem.zeroes(contract.BindingIdentity)),
    );
    slot.current.client.leaveGenerationAllocatorCallbackUnchecked();
    try std.testing.expect(!slot.current.client.endedPurgeFenceIntruded());
    try std.testing.expect(slot.current.client.releaseEndedPurgeExclusiveClean());
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot은 buffered batch owner와 accounting을 exact release한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB201);
    const bytes = try allocator.dupe(u8, "generation-batch");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 7,
        .bytes = bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = bytes.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB201);
    const read = try slot.readAttachmentBatch(7);
    const token = switch (read) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    const view = try slot.borrowAttachmentBatch(token);
    try std.testing.expect(view.is_snapshot);
    try std.testing.expectEqualStrings("generation-batch", view.bytes);
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(bytes.len, slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());

    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(@as(usize, 0), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(@as(usize, 0), slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());
    try std.testing.expectError(error.InvalidReservation, slot.borrowAttachmentBatch(token));
    try std.testing.expectError(error.InvalidReservation, slot.releaseAttachmentBatch(token));
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot batch token은 stream splice를 free 전에 거부한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB202);
    const bytes = try allocator.dupe(u8, "owned");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 11,
        .bytes = bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = bytes.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB202);
    const token = switch (try slot.readAttachmentBatch(11)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    var spliced = token;
    spliced.stream_id = 12;
    try std.testing.expectError(error.InvalidReservation, slot.releaseAttachmentBatch(spliced));
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(bytes.len, slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqualStrings("owned", (try slot.borrowAttachmentBatch(token)).bytes);

    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot polling idle은 4096회 뒤에도 registry cap을 소비하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xB204);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB204);

    try std.testing.expectEqual(ClientSlot.AttachmentBatchRead.idle, try slot.readAttachmentBatch(17));
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());
    for (1..4096) |_| {
        try std.testing.expectEqual(ClientSlot.AttachmentBatchRead.idle, try slot.readAttachmentBatch(17));
    }
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());

    const bytes = try allocator.dupe(u8, "after-idle");
    try slot.current.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 17,
        .bytes = bytes,
        .allocator = allocator,
    });
    slot.current.client.pending_batch_bytes = bytes.len;
    const token = switch (try slot.readAttachmentBatch(17)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 batch와 stream-drop registry는 동시에 각각 4096 entry를 소유한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB205);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB205);
    var batch_reservations: [batch_registry_mod.max_entries]batch_registry_mod.Reservation = undefined;
    var drop_reservations: [cleanup_registry_mod.max_entries]cleanup_registry_mod.Reserved = undefined;
    for (&batch_reservations, &drop_reservations, 0..) |*batch, *drop, index| {
        batch.* = try slot.current.batch_registry.reserve(index + 1);
        drop.* = try slot.current.cleanup_registry.reserve(.{
            .binding_incarnation = index + 1,
            .binding_storage_addr = index + 1,
            .destination_addr = index + 1,
            .slot_incarnation = slot.incarnation.tagged,
            .node_incarnation = slot.current.incarnation.tagged,
            .host_id = 0xB205,
            .connection_generation = 1,
            .runtime_id = index + 1,
            .role = .controller,
            .pid = slot.pid,
            .process_nonce = slot.process_nonce,
        });
    }
    try std.testing.expectEqual(batch_registry_mod.max_entries, try slot.current.batch_registry.count());
    try std.testing.expectEqual(cleanup_registry_mod.max_entries, try slot.current.cleanup_registry.count());
    try std.testing.expectError(error.CapacityExhausted, slot.current.batch_registry.reserve(5000));
    try std.testing.expectError(error.CapacityExhausted, slot.current.cleanup_registry.reserve(.{
        .binding_incarnation = 5000,
        .binding_storage_addr = 5000,
        .destination_addr = 5000,
        .slot_incarnation = slot.incarnation.tagged,
        .node_incarnation = slot.current.incarnation.tagged,
        .host_id = 0xB205,
        .connection_generation = 1,
        .runtime_id = 5000,
        .role = .controller,
        .pid = slot.pid,
        .process_nonce = slot.process_nonce,
    }));
    for (batch_reservations, drop_reservations) |batch, drop| {
        try slot.current.batch_registry.abort(batch);
        try slot.current.cleanup_registry.abort(drop.reservation, drop.identity);
    }
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 payload alias preflight는 slot node와 callback-local owner range를 닫는다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB206);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB206);
    defer slot.deinit();
    var owned: batch_registry_mod.OwnedBatch = .{};
    owned.bytes = std.mem.asBytes(&slot)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    owned.bytes = std.mem.asBytes(slot.current)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    owned.bytes = std.mem.asBytes(&owned)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    const separate = "separate";
    owned.bytes = @constCast(separate);
    try std.testing.expect(!generationBatchOwnerAliases(&slot, &owned));
}

test "CR3a-2b1 ClientNode move는 overlapping pending payload owner를 거부한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB207);
    const bytes = try allocator.dupe(u8, "aliased");
    for ([_]u64{ 7, 8 }) |stream_id|
        try source.pending_batches.append(allocator, .{
            .is_snapshot = false,
            .stream_id = stream_id,
            .bytes = bytes,
            .allocator = allocator,
        });
    source.pending_batch_bytes = bytes.len * 2;
    var slot: ClientSlot = undefined;
    try std.testing.expectError(
        error.InvalidSource,
        ClientSlot.initInPlace(&slot, allocator, &source, 0xB207),
    );
    const alias = source.pending_batches.orderedRemove(1);
    _ = alias;
    source.pending_batch_bytes -= bytes.len;
    source.deinit();
}

const BatchFreeProbe = struct {
    parent: std.mem.Allocator,
    slot: ?*ClientSlot = null,
    observed_items_before_reentry: usize = 0,
    deinit_outcome: ?DeinitOutcome = null,
    sibling_token: ?batch_registry_mod.Token = null,
    reentry_error: ?anyerror = null,

    fn allocator(self: *BatchFreeProbe) std.mem.Allocator {
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
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
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
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
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
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        if (self.slot) |slot| {
            self.observed_items_before_reentry = slot.current.accounting_ledger.item_count;
            self.deinit_outcome = slot.tryDeinit();
            const result = slot.readAttachmentBatch(12) catch |err| {
                self.reentry_error = err;
                self.parent.vtable.free(
                    self.parent.ptr,
                    memory,
                    alignment,
                    return_address,
                );
                return;
            };
            switch (result) {
                .committed => |token| self.sibling_token = token,
                else => self.reentry_error = error.TestUnexpectedResult,
            }
            self.slot = null;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

test "CR3a-2b1 release allocator callback 동안 charge를 유지하고 sibling admission을 허용한다" {
    const allocator = std.testing.allocator;
    var probe: BatchFreeProbe = .{ .parent = allocator };
    var source = fixtureClient(allocator, 0xB203);
    const first = try probe.allocator().dupe(u8, "first");
    const sibling = try allocator.dupe(u8, "sibling");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 11,
        .bytes = first,
        .allocator = probe.allocator(),
    });
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 12,
        .bytes = sibling,
        .allocator = allocator,
    });
    source.pending_batch_bytes = first.len + sibling.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB203);
    const first_token = switch (try slot.readAttachmentBatch(11)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.slot = &slot;
    try slot.releaseAttachmentBatch(first_token);
    try std.testing.expectEqual(@as(usize, 1), probe.observed_items_before_reentry);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expect(probe.reentry_error == null);
    const sibling_token = probe.sibling_token orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqualStrings("sibling", (try slot.borrowAttachmentBatch(sibling_token)).bytes);
    try slot.releaseAttachmentBatch(sibling_token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

const GenerationAllocatorReentryProbe = struct {
    parent: std.mem.Allocator,
    same: ?*ClientSlot = null,
    foreign: ?*ClientSlot = null,
    same_token: ?batch_registry_mod.Token = null,
    foreign_token: ?batch_registry_mod.Token = null,
    deinit_target: ?*ClientSlot = null,
    release_mode: bool = false,
    armed: bool = false,
    fired: bool = false,
    same_error: ?anyerror = null,
    foreign_error: ?anyerror = null,
    same_direct_read_error: ?anyerror = null,
    foreign_direct_read_error: ?anyerror = null,
    deinit_outcome: ?DeinitOutcome = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn attemptReentry(self: *@This()) void {
        if (!self.armed or self.fired) return;
        self.fired = true;
        if (self.release_mode) {
            self.same.?.releaseAttachmentBatch(self.same_token.?) catch |err| {
                self.same_error = err;
            };
            self.foreign.?.releaseAttachmentBatch(self.foreign_token.?) catch |err| {
                self.foreign_error = err;
            };
            _ = self.same.?.readAttachmentBatch(91) catch |err| {
                self.same_direct_read_error = err;
            };
            _ = self.foreign.?.readAttachmentBatch(92) catch |err| {
                self.foreign_direct_read_error = err;
            };
            self.deinit_outcome = self.deinit_target.?.tryDeinit();
            return;
        }
        _ = self.same.?.readAttachmentBatch(91) catch |err| {
            self.same_error = err;
        };
        _ = self.foreign.?.readAttachmentBatch(92) catch |err| {
            self.foreign_error = err;
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
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
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
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
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

const SnapshotOwnerAliasAllocator = struct {
    target: []align(16) u8,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
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
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.alloc_calls += 1;
        if (len > self.target.len or !alignment.check(@intFromPtr(self.target.ptr))) return null;
        return self.target.ptr;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = memory;
        _ = alignment;
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_calls += 1;
    }
};

test "CR3a-2c1 snapshot allocation rejects owner alias before the first payload write" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB20B);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB20B);
    defer slot.deinit();

    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        "snapshot-payload",
    );
    defer allocator.free(wire);
    try slot.current.client.parser.push(wire);

    var owner_storage: [256]u8 align(16) = [_]u8{0xA5} ** 256;
    var hostile = SnapshotOwnerAliasAllocator{ .target = owner_storage[0..] };
    slot.current.guarded_allocator.parent = hostile.allocator();
    try std.testing.expectError(
        error.AliasedAllocation,
        slot.readInitialSnapshotGuarded(
            7,
            @intFromPtr(&owner_storage),
            owner_storage.len,
            @intFromPtr(&owner_storage),
            owner_storage.len,
        ),
    );
    try std.testing.expect(hostile.alloc_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), hostile.free_calls);
    for (owner_storage) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
    try std.testing.expect(slot.current.client.unusable);
}

test "CR3a-2b1 parser allocator callback은 same과 foreign ClientSlot mutation을 wire 전에 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var probe: GenerationAllocatorReentryProbe = .{ .parent = allocator };
    const checked_allocator = probe.allocator();
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);

    var source = fixtureClient(checked_allocator, 0xB208);
    source.fd = fds[0];
    const same_sibling_bytes = try allocator.dupe(u8, "same-sibling");
    try source.pending_batches.append(checked_allocator, .{
        .is_snapshot = false,
        .stream_id = 8,
        .bytes = same_sibling_bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = same_sibling_bytes.len;
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, checked_allocator, &source, 0xB208);
    var foreign_source = fixtureClient(allocator, 0xB209);
    const foreign_sibling_bytes = try allocator.dupe(u8, "foreign-sibling");
    try foreign_source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 9,
        .bytes = foreign_sibling_bytes,
        .allocator = allocator,
    });
    foreign_source.pending_batch_bytes = foreign_sibling_bytes.len;
    var foreign: ClientSlot = undefined;
    try ClientSlot.initInPlace(&foreign, allocator, &foreign_source, 0xB209);
    defer foreign.deinit();
    var deinit_source = fixtureClient(allocator, 0xB20A);
    var deinit_target: ClientSlot = undefined;
    try ClientSlot.initInPlace(&deinit_target, allocator, &deinit_source, 0xB20A);
    probe.same = &slot;
    probe.foreign = &foreign;
    probe.deinit_target = &deinit_target;
    probe.same_token = switch (try slot.readAttachmentBatch(8)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.foreign_token = switch (try foreign.readAttachmentBatch(9)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };

    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .delta_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        "guarded-direct",
    );
    defer allocator.free(wire);
    try socket_server.writeAll(fds[1], wire);
    probe.armed = true;
    const token = switch (try slot.readAttachmentBatch(7)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.armed = false;

    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(@as(u64, 2), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 2), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 0), foreign.current.client.pending_batches.items.len);
    try std.testing.expect(std.meta.eql(checked_allocator, slot.current.client.allocator));
    try std.testing.expect(slot.current.client.parser.usesAllocator(checked_allocator));
    try std.testing.expectEqualStrings("guarded-direct", (try slot.borrowAttachmentBatch(token)).bytes);
    var restored_rpc: client_mod.PreparedBlockingRpcStorage = .{};
    _ = try slot.current.client.prepareBlockingRpcStorage(&restored_rpc, "host.info", null);
    try slot.current.client.abortPreparedBlockingRpcStorage(&restored_rpc);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&restored_rpc));

    probe.fired = false;
    probe.same_error = null;
    probe.foreign_error = null;
    probe.release_mode = true;
    probe.armed = true;
    try slot.releaseAttachmentBatch(token);
    probe.armed = false;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.same_direct_read_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_direct_read_error.?);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expectEqual(@as(u64, 2), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqualStrings(
        "same-sibling",
        (try slot.borrowAttachmentBatch(probe.same_token.?)).bytes,
    );
    try std.testing.expectEqualStrings(
        "foreign-sibling",
        (try foreign.borrowAttachmentBatch(probe.foreign_token.?)).bytes,
    );

    const buffered_outer_bytes = try probe.allocator().dupe(u8, "buffered-outer");
    try slot.current.client.pending_batches.append(checked_allocator, .{
        .is_snapshot = false,
        .stream_id = 10,
        .bytes = buffered_outer_bytes,
        .allocator = probe.allocator(),
    });
    slot.current.client.pending_batch_bytes += buffered_outer_bytes.len;
    const buffered_token = switch (try slot.readAttachmentBatch(10)) {
        .committed => |buffered| buffered,
        else => return error.TestUnexpectedResult,
    };
    probe.fired = false;
    probe.same_error = null;
    probe.foreign_error = null;
    probe.same_direct_read_error = null;
    probe.foreign_direct_read_error = null;
    probe.deinit_outcome = null;
    const buffered_followup_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .delta_chunk, .stream_id = 91, .flags = protocol.Flags.end_stream },
        "after-buffered-callback",
    );
    defer allocator.free(buffered_followup_wire);
    try socket_server.writeAll(fds[1], buffered_followup_wire);
    probe.armed = true;
    try slot.releaseAttachmentBatch(buffered_token);
    probe.armed = false;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.same_direct_read_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_direct_read_error.?);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expectEqual(@as(u64, 3), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqualStrings(
        "same-sibling",
        (try slot.borrowAttachmentBatch(probe.same_token.?)).bytes,
    );
    try std.testing.expectEqualStrings(
        "foreign-sibling",
        (try foreign.borrowAttachmentBatch(probe.foreign_token.?)).bytes,
    );
    const followup_token = switch (try slot.readAttachmentBatch(91)) {
        .committed => |followup| followup,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        "after-buffered-callback",
        (try slot.borrowAttachmentBatch(followup_token)).bytes,
    );
    try slot.releaseAttachmentBatch(followup_token);
    try slot.releaseAttachmentBatch(probe.same_token.?);
    try foreign.releaseAttachmentBatch(probe.foreign_token.?);
    try std.testing.expectEqual(DeinitOutcome.cleaned, deinit_target.tryDeinit());
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
    try std.testing.expectEqual(DeinitOutcome.corrupt, first.tryDeinit());
    try first.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(first.current.client.releaseEndedPurgeExclusiveClean());
    first.current = @ptrFromInt(@alignOf(ClientNode));
    try std.testing.expectEqual(DeinitOutcome.corrupt, first.tryDeinit());
    first.current = canonical_first;
    const shared = try first.beginRegisteredClientOperation();
    first.current = second.current;
    first.endRegisteredClientOperation(shared);
    first.current = canonical_first;
    try first.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(first.current.client.releaseEndedPurgeExclusiveClean());
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

test "CR3a B3b-F direct Client intrusion aborts a reserved slot teardown without panic" {
    const Runner = struct {
        fn run(client: *client_mod.Client, rejected: *std.atomic.Value(bool)) void {
            if (!client.tryDeinit()) rejected.store(true, .release);
        }
    };
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF4);

    const reserved = try slot.beginRegisteredExclusiveTeardown();
    var rejected: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ &reserved.node.client, &rejected });
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expect(reserved.node.client.endedPurgeFenceIntruded());
    slot.abortRegisteredExclusiveTeardown(reserved);
    try std.testing.expect(clientSlotRegistryEntry(@intFromPtr(&slot)) != null);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
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

test "CR3a-2c1 node canonical snapshot permit rejects stale authority replay and binding splice" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF4);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x44);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("snapshot permit test binding cleanup drifted");

    const first = try slot.prepareInitialSnapshotPermit(0x1000, 9, reservation.identity);
    try std.testing.expect(slot.initialSnapshotPermitLive(first));
    try slot.consumeInitialSnapshotPermit(first);
    try std.testing.expect(!slot.initialSnapshotPermitLive(first));
    try std.testing.expectError(error.InvalidSnapshotPermit, slot.consumeInitialSnapshotPermit(first));

    const second = try slot.prepareInitialSnapshotPermit(0x1000, 9, reservation.identity);
    try std.testing.expect(second.generation != first.generation);
    var spliced = second;
    spliced.binding.runtime_id += 1;
    try std.testing.expect(!slot.initialSnapshotPermitLive(spliced));
    try std.testing.expectError(error.InvalidSnapshotPermit, slot.abortInitialSnapshotPermit(spliced));
    try slot.abortInitialSnapshotPermit(second);
    try std.testing.expect(slot.initialSnapshotPermitIdle());
}

test "CR3a-2c2 node stream operation permit serializes snapshot and ended purge" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF5);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF5);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x45);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("stream operation permit test binding cleanup drifted");

    var foreign_prepare_rejected: std.atomic.Value(bool) = .init(false);
    const ForeignPrepare = struct {
        fn run(
            target: *ClientSlot,
            identity: contract.BindingIdentity,
            rejected: *std.atomic.Value(bool),
        ) void {
            if (target.prepareStreamOperationPermit(
                .ended_purge,
                0x3000,
                10,
                identity,
            )) |_| {
                return;
            } else |err| {
                if (err == error.InvalidStreamOperationPermit)
                    rejected.store(true, .release);
            }
        }
    };
    const foreign_prepare = try std.Thread.spawn(
        .{},
        ForeignPrepare.run,
        .{ &slot, reservation.identity, &foreign_prepare_rejected },
    );
    foreign_prepare.join();
    try std.testing.expect(foreign_prepare_rejected.load(.acquire));
    try std.testing.expect(slot.streamOperationPermitIdle());

    const snapshot = try slot.prepareStreamOperationPermit(
        .initial_snapshot,
        0x2000,
        10,
        reservation.identity,
    );
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    var wrong_thread_rejected: std.atomic.Value(bool) = .init(false);
    const WrongThread = struct {
        fn run(
            target: *ClientSlot,
            captured: StreamOperationPermit,
            rejected: *std.atomic.Value(bool),
        ) void {
            target.abortStreamOperationPermit(captured) catch |abort_err| {
                if (abort_err != error.InvalidStreamOperationPermit) return;
                target.consumeStreamOperationPermit(captured) catch |consume_err| {
                    if (consume_err != error.InvalidStreamOperationPermit) return;
                    if (target.streamOperationPermitLive(captured)) return;
                    rejected.store(true, .release);
                };
            };
        }
    };
    const wrong_thread = try std.Thread.spawn(
        .{},
        WrongThread.run,
        .{ &slot, snapshot, &wrong_thread_rejected },
    );
    wrong_thread.join();
    try std.testing.expect(wrong_thread_rejected.load(.acquire));
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    try std.testing.expectError(
        error.AdminBusy,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectError(error.AdminBusy, slot.readAttachmentBatch(7));
    try std.testing.expectError(
        error.AdminBusy,
        slot.releaseAttachmentBatch(std.mem.zeroes(batch_registry_mod.Token)),
    );
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(
            .ended_purge,
            0x3000,
            10,
            reservation.identity,
        ),
    );
    batch_release_callback_active = true;
    defer batch_release_callback_active = false;
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.abortStreamOperationPermit(snapshot),
    );
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(snapshot),
    );
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    try std.testing.expectError(
        error.AdminBusy,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(
            .ended_purge,
            0x3000,
            10,
            reservation.identity,
        ),
    );
    batch_release_callback_active = false;
    try slot.consumeStreamOperationPermit(snapshot);

    const purge = try slot.prepareStreamOperationPermit(
        .ended_purge,
        0x3000,
        10,
        reservation.identity,
    );
    try std.testing.expectEqual(StreamOperationKind.ended_purge, purge.kind);
    try std.testing.expect(slot.streamOperationPermitLive(purge));
    try std.testing.expectError(error.AdminBusy, slot.readAttachmentBatch(7));
    try std.testing.expectError(
        error.AdminBusy,
        slot.releaseAttachmentBatch(std.mem.zeroes(batch_registry_mod.Token)),
    );
    var wrong_kind = purge;
    wrong_kind.kind = .initial_snapshot;
    try std.testing.expect(!slot.streamOperationPermitLive(wrong_kind));
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(wrong_kind),
    );
    try slot.abortStreamOperationPermit(purge);
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c3a canonical authority entrypoints reject foreign thread and fork child" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0x2C3A);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3A);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3B);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        53,
    );

    const Foreign = struct {
        fn run(
            target: *ClientSlot,
            captured: AttachmentBindingReservation,
            binding_owner: *contract.PreparedAttachmentBinding,
            lease_owner: *lease_mod.ConnectionLease,
            rejected: *std.atomic.Value(bool),
        ) void {
            const live_rejected = if (target.controllerAuthorityLive(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const pending_rejected = if (target.controllerRevokePending(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const begin_rejected = if (target.beginControllerRevoke(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const finish_rejected = if (target.finishControllerRevoke(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const drop_rejected = if (target.beginAttachmentDrop(
                binding_owner,
                captured,
                lease_owner,
            )) |_| false else |err| err == error.MovedOrCopied;
            rejected.store(
                live_rejected and pending_rejected and begin_rejected and finish_rejected and
                    drop_rejected,
                .release,
            );
        }
    };
    var rejected: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(
        .{},
        Foreign.run,
        .{ &slot, reservation, &binding, &lease, &rejected },
    );
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expect(try slot.controllerAuthorityLive(reservation, 53));

    var corrupt_reservation = reservation;
    const role_raw: *u8 = @ptrCast(&corrupt_reservation.identity.role);
    var raw: u16 = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.controllerAuthorityLive(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.controllerRevokePending(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.beginControllerRevoke(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.finishControllerRevoke(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.beginAttachmentDrop(&binding, corrupt_reservation, &lease),
        );
    }
    try std.testing.expect(try slot.controllerAuthorityLive(reservation, 53));

    if (builtin.os.tag == .macos) {
        const child = c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            var child_rejected: std.atomic.Value(bool) = .init(false);
            Foreign.run(&slot, reservation, &binding, &lease, &child_rejected);
            const mutation_zero = slot.current.cleanup_registry.controllerAuthorityLive(
                reservation.cleanup,
                reservation.identity,
                53,
            ) catch false;
            std.c._exit(if (child_rejected.load(.acquire) and mutation_zero) 0 else 1);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }

    try slot.beginControllerRevoke(reservation, 53);
    try slot.finishControllerRevoke(reservation, 53);
    try slot.current.cleanup_registry.beginBoundDrop(
        reservation.cleanup,
        reservation.identity,
        53,
    );
    try slot.current.cleanup_registry.completeActiveDrop(
        reservation.cleanup,
        reservation.identity,
        53,
    );
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2c2b3b B3b-O atomic permit receipt is exact once and delays index reuse" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF501);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF501);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4501);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("atomic permit receipt binding cleanup drifted");

    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&preparation),
        17,
        reservation.identity,
    );
    preparation = .{
        .self_addr = @intFromPtr(&preparation),
        .target_stream = 9,
        .permit = permit,
        .inventory = .{
            .self_addr = @intFromPtr(&preparation.inventory),
            .client_addr = @intFromPtr(&slot.current.client),
            .scratch_addr = @intFromPtr(&scratch),
            .target_stream = 9,
            .target_event_count = 1,
            .lifecycle = .prepared,
        },
        .lifecycle = .prepared,
    };
    preparation.authority_seal = endedPurgePreparationSeal(&preparation);

    var receipt: ClientSlot.PreparedStreamOperationPermitConsume = .{};
    try slot.prepareStreamOperationPermitConsume(permit, &receipt);
    const entry = &stream_operation_registry[permit.registry_index];
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
        entry.state.load(.acquire),
    );
    try std.testing.expect(!slot.streamOperationPermitLive(permit));

    const ForeignThreadProbe = struct {
        fn run(
            target_slot: *ClientSlot,
            target_preparation: *EndedPurgePreparation,
            target_receipt: *ClientSlot.PreparedStreamOperationPermitConsume,
            seal_result: *bool,
            consume_result: *bool,
        ) void {
            seal_result.* = target_preparation.sealForCommit(target_slot);
            consume_result.* = target_slot.consumeStreamOperationPermitUnchecked(target_receipt);
        }
    };
    var foreign_seal_result = true;
    var foreign_consume_result = true;
    const foreign_thread = try std.Thread.spawn(.{}, ForeignThreadProbe.run, .{
        &slot,
        &preparation,
        &receipt,
        &foreign_seal_result,
        &foreign_consume_result,
    });
    foreign_thread.join();
    try std.testing.expect(!foreign_seal_result);
    try std.testing.expect(!foreign_consume_result);
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
        entry.state.load(.acquire),
    );

    var sibling_source = fixtureClient(allocator, 0xF505);
    var sibling_slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&sibling_slot, allocator, &sibling_source, 0xF505);
    defer sibling_slot.deinit();
    var sibling_binding: contract.PreparedAttachmentBinding = .{};
    var sibling_lease: lease_mod.ConnectionLease = .{};
    const sibling_reservation = try sibling_slot.reserveAttachmentBindingForTest(
        &sibling_binding,
        &sibling_lease,
        0x4505,
    );
    defer sibling_slot.abortAttachmentBinding(&sibling_binding, sibling_reservation) catch
        @panic("atomic permit sibling binding cleanup drifted");
    const sibling_permit = try sibling_slot.prepareStreamOperationPermit(
        .initial_snapshot,
        41,
        43,
        sibling_reservation.identity,
    );
    try std.testing.expect(sibling_permit.registry_index != permit.registry_index);
    try sibling_slot.consumeStreamOperationPermit(sibling_permit);
    try std.testing.expect(sibling_slot.streamOperationPermitIdle());

    const preparation_lifecycle_raw: *u8 = @ptrCast(&preparation.lifecycle);
    var raw_tag: u16 = @intFromEnum(EndedPurgePreparationLifecycle.aborted) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        preparation_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    preparation_lifecycle_raw.* = @intFromEnum(EndedPurgePreparationLifecycle.prepared);

    const permit_kind_raw: *u8 = @ptrCast(&preparation.permit.kind);
    raw_tag = @intFromEnum(StreamOperationKind.ended_purge) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        permit_kind_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    permit_kind_raw.* = @intFromEnum(StreamOperationKind.ended_purge);

    const binding_role_raw: *u8 = @ptrCast(&preparation.permit.binding.role);
    raw_tag = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        binding_role_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    binding_role_raw.* = @intFromEnum(permit.binding.role);

    const inventory_lifecycle_raw: *u8 = @ptrCast(&preparation.inventory.lifecycle);
    raw_tag = 3;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        inventory_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    inventory_lifecycle_raw.* = 1;

    try std.testing.expect(preparation.sealForCommit(&slot));

    var copied = receipt;
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&copied));
    const receipt_lifecycle_raw: *u8 = @ptrCast(&receipt.lifecycle);
    raw_tag = @intFromEnum(ClientSlot.PreparedStreamOperationPermitConsume.Lifecycle.consumed) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        receipt_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    }
    receipt_lifecycle_raw.* =
        @intFromEnum(ClientSlot.PreparedStreamOperationPermitConsume.Lifecycle.prepared);
    try std.testing.expect(slot.consumeStreamOperationPermitUnchecked(&receipt));
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consumed),
        entry.state.load(.acquire),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    preparation.consumeAfterPermit(&slot);
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.empty),
        entry.state.load(.acquire),
    );

    const reused = try slot.prepareStreamOperationPermit(
        .initial_snapshot,
        19,
        23,
        reservation.identity,
    );
    try std.testing.expectEqual(permit.registry_index, reused.registry_index);
    try std.testing.expect(reused.registry_id != permit.registry_id);
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    try slot.abortStreamOperationPermit(reused);

    var raw_state: u16 = 0;
    while (raw_state <= std.math.maxInt(u8)) : (raw_state += 1) {
        entry.state.store(@intCast(raw_state), .release);
        try std.testing.expect(!slot.streamOperationPermitLive(permit));
        try std.testing.expect(!slot.streamOperationPermitLive(reused));
        try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    }
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.empty), .release);
}

test "CR3a-2c2b3b B3b-O validated suffix mismatch fail-stops in a subprocess" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF503);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF503);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4503);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("suffix mismatch fixture binding cleanup drifted");

    var preparation: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&preparation),
        31,
        reservation.identity,
    );
    defer if (slot.streamOperationPermitLive(permit))
        slot.abortStreamOperationPermit(permit) catch
            @panic("suffix mismatch fixture permit cleanup drifted");
    var receipt: ClientSlot.PreparedStreamOperationPermitConsume = .{};
    try slot.prepareStreamOperationPermitConsume(permit, &receipt);

    var panic_pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&panic_pipe));
    defer _ = c.close(panic_pipe[0]);
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(panic_pipe[0]);
        if (c.dup2(panic_pipe[1], 2) < 0) c._exit(126);
        _ = c.close(panic_pipe[1]);
        slot.pid = currentPid();
        if (!operationThreadMatches(slot.operation_owner_thread_incarnation))
            std.c._exit(4);
        receipt.registry_id +%= 1;
        if (!slot.consumeStreamOperationPermitUnchecked(&receipt))
            @panic("validated ended purge suffix mismatch");
        _ = c.write(2, "suffix mismatch returned\n", "suffix mismatch returned\n".len);
        std.c._exit(0);
    }
    _ = c.close(panic_pipe[1]);

    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0 and std.posix.errno(waited) != .INTR)
            return error.TestUnexpectedResult;
        var delay_fd = c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    if (attempts == 2_000) {
        _ = c.kill(child, c.SIG.KILL);
        _ = c.waitpid(child, &status, 0);
        return error.TestUnexpectedResult;
    }
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(!c.W.IFEXITED(wait_status) or c.W.EXITSTATUS(wait_status) != 0);
    var panic_output: [4096]u8 = undefined;
    const panic_len = c.read(panic_pipe[0], &panic_output, panic_output.len);
    try std.testing.expect(panic_len > 0);
    const panic_bytes = panic_output[0..@intCast(panic_len)];
    try std.testing.expect(std.mem.indexOf(
        u8,
        panic_bytes,
        "validated ended purge suffix mismatch",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, panic_bytes, "suffix mismatch returned") == null);

    try std.testing.expect(slot.consumeStreamOperationPermitUnchecked(&receipt));
    const entry = &stream_operation_registry[permit.registry_index];
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consumed),
        entry.state.load(.acquire),
    );
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.empty), .release);
}

test "CR3a-2c2b3b B3b-O drift subprocess finalizes quarantine and paired receipts" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const marker_ptr = c.getenv("MARU_SESSION_HOST_B3BO_DRIFT_SUBPROCESS") orelse
        return error.MissingDriftSubprocessMode;
    const marker = std.mem.span(marker_ptr);
    if (std.mem.eql(u8, marker, "skip-in-aggregate-v1")) return error.SkipZigTest;
    if (!std.mem.eql(u8, marker, "run-isolated-v1"))
        return error.InvalidDriftSubprocessMode;
    const DriftAllocator = struct {
        parent: std.mem.Allocator,
        replacement: std.mem.Allocator,
        client: ?*client_mod.Client = null,
        armed: bool = false,
        drifted: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
        }
        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
        }
        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.armed and !self.drifted) {
                self.drifted = true;
                self.client.?.allocator = self.replacement;
            }
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        }
    };
    try ClientSlot.initializeProcessRuntime();
    var probe = DriftAllocator{
        .parent = std.heap.page_allocator,
        .replacement = std.heap.c_allocator,
    };
    const allocator = probe.allocator();
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xF504);
    source.fd = fds[0];
    source.build_id = try allocator.dupe(u8, "build");
    source.lifecycle = try allocator.dupe(u8, "running");
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, source.host_id);
    probe.client = &slot.current.client;
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &binding,
        &lease,
        0x4504,
    );
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    const ended_payload = "{\"event\":\"runtime.ended\"}";
    const event_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 9 },
        ended_payload,
    );
    const snapshot_wire = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 99,
            .flags = protocol.Flags.end_stream,
        },
        "snapshot",
    );
    try socket_server.writeAll(fds[1], event_wire);
    try socket_server.writeAll(fds[1], snapshot_wire);
    _ = try slot.current.client.readSnapshot(99);
    const hint = (try slot.current.client.peekEndedEventForStream(9)).candidate;
    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    try slot.prepareEndedPurge(37, reservation, 9, hint, &scratch, &preparation);
    probe.armed = true;
    try std.testing.expectEqual(
        ClientSlot.EndedPurgeResult.purged,
        try slot.commitEndedPurge(&scratch, &preparation),
    );
    try std.testing.expect(probe.drifted);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        @intFromEnum(EndedPurgePreparationLifecycle.consumed),
        @as(*const u8, @ptrCast(&preparation.lifecycle)).*,
    );
    try std.testing.expectEqual(@as(c.fd_t, -1), slot.current.client.fd);
}

test "CR3a-2c2b3b B3b-O product clean commit purges ended event and consumes paired authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xF502);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF502);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4502);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("B3b-O clean product binding cleanup drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("B3b-O clean product binding cleanup completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    const ended_payload = "{\"event\":\"runtime.ended\"}";
    const event_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 9 },
        ended_payload,
    );
    defer allocator.free(event_wire);
    const snapshot_wire = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 99,
            .flags = protocol.Flags.end_stream,
        },
        "snapshot",
    );
    defer allocator.free(snapshot_wire);
    try socket_server.writeAll(fds[1], event_wire);
    try socket_server.writeAll(fds[1], snapshot_wire);
    const snapshot = try slot.current.client.readSnapshot(99);
    defer allocator.free(snapshot);
    try std.testing.expectEqualStrings("snapshot", snapshot);

    const hint = (try slot.current.client.peekEndedEventForStream(9)).candidate;
    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    try slot.prepareEndedPurge(
        29,
        reservation,
        9,
        hint,
        &scratch,
        &preparation,
    );
    try std.testing.expectEqual(
        ClientSlot.EndedPurgeResult.purged,
        try slot.commitEndedPurge(&scratch, &preparation),
    );
    try std.testing.expectEqual(EndedPurgePreparationLifecycle.consumed, preparation.lifecycle);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        client_mod.EndedEventPeek.not_ended,
        try slot.current.client.peekEndedEventForStream(9),
    );
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 corrupt ended preparation poisons once and rolls back permit" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF7);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF7);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x47);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation test cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation test cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};

    try std.testing.expectError(
        error.Corrupt,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(EndedPurgePreparationLifecycle.empty, prepared.lifecycle);
    try std.testing.expect(slot.current.client.firstPoisonReason().? == .local_invariant_violation);
    try std.testing.expectError(
        error.Corrupt,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.current.client.firstPoisonReason().? == .local_invariant_violation);
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c2b2 busy ended preparation does not burn operation generation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF8);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF8);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x48);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("busy ended preparation cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("busy ended preparation cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};

    const batch = try slot.current.batch_registry.reserve(9);
    defer slot.current.batch_registry.abort(batch) catch
        @panic("ended preparation test batch cleanup drifted");
    const generation_before_busy = slot.current.next_operation_generation;
    try std.testing.expectError(
        error.Busy,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        generation_before_busy,
        slot.current.next_operation_generation,
    );
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ended preparation rejects wrong stream foreign binding and owner aliases before mutation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF9);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF9);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x49);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 9);
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation owner preflight cleanup drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation owner preflight cleanup completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    const generation_before = slot.current.next_operation_generation;

    var foreign_thread_rejected: std.atomic.Value(bool) = .init(false);
    const ForeignPrepare = struct {
        fn run(
            target: *ClientSlot,
            captured: AttachmentBindingReservation,
            local_scratch: *client_mod.EndedPurgeScratch,
            local_out: *EndedPurgePreparation,
            rejected: *std.atomic.Value(bool),
        ) void {
            target.prepareEndedPurge(
                11,
                captured,
                9,
                .{ .event_index = 0 },
                local_scratch,
                local_out,
            ) catch |err| {
                if (err == error.InvalidOwner) rejected.store(true, .release);
            };
        }
    };
    const foreign_thread = try std.Thread.spawn(
        .{},
        ForeignPrepare.run,
        .{ &slot, reservation, &scratch, &prepared, &foreign_thread_rejected },
    );
    foreign_thread.join();
    try std.testing.expect(foreign_thread_rejected.load(.acquire));

    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        10,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
    var foreign = reservation;
    foreign.identity.runtime_id += 1;
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        foreign,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));

    const node_scratch_addr = std.mem.alignForward(
        usize,
        @intFromPtr(slot.current),
        @alignOf(client_mod.EndedPurgeScratch),
    );
    const node_scratch: *client_mod.EndedPurgeScratch = @ptrFromInt(node_scratch_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        node_scratch,
        &prepared,
    ));
    const slot_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&slot),
        @alignOf(EndedPurgePreparation),
    );
    const slot_out: *EndedPurgePreparation = @ptrFromInt(slot_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        slot_out,
    ));
    const scratch_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&scratch),
        @alignOf(EndedPurgePreparation),
    );
    const scratch_out: *EndedPurgePreparation = @ptrFromInt(scratch_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        scratch_out,
    ));
    const binding_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&binding),
        @alignOf(EndedPurgePreparation),
    );
    const binding_out: *EndedPurgePreparation = @ptrFromInt(binding_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        binding_out,
    ));

    prepared.inventory.self_addr = 1;
    try std.testing.expectError(error.DestinationOccupied, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
    prepared.inventory = .{};
    try std.testing.expectEqual(generation_before, slot.current.next_operation_generation);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ended preparation seal rejects copy field splice and preserves all or none abort" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFA);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4A);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("ended preparation seal binding cleanup drifted");
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&prepared),
        11,
        reservation.identity,
    );
    prepared = .{
        .self_addr = @intFromPtr(&prepared),
        .target_stream = 9,
        .permit = permit,
        .inventory = .{
            .self_addr = @intFromPtr(&prepared.inventory),
            .client_addr = @intFromPtr(&slot.current.client),
            .scratch_addr = @intFromPtr(&scratch),
            .target_stream = 9,
            .target_event_count = 1,
            .lifecycle = .prepared,
        },
        .lifecycle = .prepared,
    };
    prepared.authority_seal = endedPurgePreparationSeal(&prepared);

    var copied = prepared;
    try std.testing.expect(!copied.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    try std.testing.expect(prepared.inventory.validPreparedAtFinalAddress());

    prepared.inventory.events.address = 8;
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    prepared.inventory.events.address = 0;
    prepared.permit.binding.runtime_id += 1;
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    prepared.permit.binding.runtime_id -= 1;

    try std.testing.expect(prepared.abort(&slot));
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c2b2 stale ClientSlot prepare rejects before freed node dereference" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFB);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFB);
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4B);
    try slot.abortAttachmentBinding(&binding, reservation);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());

    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
}

test "CR3a-2c2b2 foreign thread teardown cannot race owner preparation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFC);
    defer slot.deinit();
    var outcome: ?DeinitOutcome = null;
    const ForeignTeardown = struct {
        fn run(target: *ClientSlot, result: *?DeinitOutcome) void {
            result.* = target.tryDeinit();
        }
    };
    const thread = try std.Thread.spawn(.{}, ForeignTeardown.run, .{ &slot, &outcome });
    thread.join();
    try std.testing.expectEqual(DeinitOutcome.corrupt, outcome.?);
    try std.testing.expect(slot.valid());
}

test "CR3a-2c2b2 Client owned backing aliases reject before permit generation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFD);
    try source.parser.buf.appendSlice(allocator, &([_]u8{0} ** 64));
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFD);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4D);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 9);
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("owned backing alias cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("owned backing alias cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    const scratch_addr = std.mem.alignForward(
        usize,
        @intFromPtr(slot.current.client.parser.buf.items.ptr),
        @alignOf(client_mod.EndedPurgeScratch),
    );
    const aliased_scratch: *client_mod.EndedPurgeScratch = @ptrFromInt(scratch_addr);
    var prepared: EndedPurgePreparation = .{};
    const generation_before = slot.current.next_operation_generation;
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        aliased_scratch,
        &prepared,
    ));
    try std.testing.expectEqual(generation_before, slot.current.next_operation_generation);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ClientSlot registry enforces exact cap and address ABA reuse" {
    comptime {
        if (@typeInfo(@TypeOf(client_slot_registry)).array.len != max_live_client_slots)
            @compileError("ClientSlot registry storage drifted from max_live_client_slots");
    }
    defer {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        client_slot_registry = [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;
    }

    for (0..max_live_client_slots) |index| try registerClientSlot(.{
        .live = true,
        .slot_addr = index + 1,
        .node_addr = max_live_client_slots + index + 1,
        .slot_incarnation = index + 1,
        .node_incarnation = index + 1,
        .owner_thread_incarnation = 1,
    });
    try std.testing.expectError(error.IdentityExhausted, registerClientSlot(.{
        .live = true,
        .slot_addr = max_live_client_slots + 1,
        .node_addr = max_live_client_slots * 2 + 1,
        .slot_incarnation = max_live_client_slots + 1,
        .node_incarnation = max_live_client_slots + 1,
        .owner_thread_incarnation = 1,
    }));

    const old = ClientSlotRegistryEntry{
        .live = true,
        .slot_addr = 1,
        .node_addr = max_live_client_slots + 1,
        .slot_incarnation = 1,
        .node_incarnation = 1,
        .owner_thread_incarnation = 1,
    };
    try std.testing.expect(unregisterClientSlot(old));
    const replacement = ClientSlotRegistryEntry{
        .live = true,
        .slot_addr = old.slot_addr,
        .node_addr = old.node_addr + max_live_client_slots,
        .slot_incarnation = old.slot_incarnation + max_live_client_slots,
        .node_incarnation = old.node_incarnation + max_live_client_slots,
        .owner_thread_incarnation = 2,
    };
    try registerClientSlot(replacement);
    try std.testing.expect(!unregisterClientSlot(old));
    try std.testing.expect(clientSlotRegistryEntry(replacement.slot_addr) == null);
    publishClientSlot(replacement);
    var published = replacement;
    published.ready = true;
    try std.testing.expect(std.meta.eql(
        published,
        clientSlotRegistryEntry(replacement.slot_addr).?,
    ));
    try std.testing.expect(unregisterClientSlot(published));
}

test "CR3a-2c2b2 ClientSlot registry serializes bounded concurrent reuse" {
    defer {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        client_slot_registry = [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;
    }
    var failed: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(worker: usize, failure: *std.atomic.Value(bool)) void {
            for (0..64) |generation| {
                const incarnation = generation + 1;
                const reserved = ClientSlotRegistryEntry{
                    .live = true,
                    .slot_addr = worker + 1,
                    .node_addr = 1024 + worker,
                    .slot_incarnation = incarnation,
                    .node_incarnation = incarnation,
                    .owner_thread_incarnation = worker + 1,
                };
                registerClientSlot(reserved) catch {
                    failure.store(true, .release);
                    return;
                };
                publishClientSlot(reserved);
                var published = reserved;
                published.ready = true;
                const observed = clientSlotRegistryEntry(reserved.slot_addr) orelse {
                    failure.store(true, .release);
                    return;
                };
                if (!std.meta.eql(observed, published) or !unregisterClientSlot(published)) {
                    failure.store(true, .release);
                    return;
                }
                if (clientSlotRegistryEntry(reserved.slot_addr) != null) {
                    failure.store(true, .release);
                    return;
                }
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ index, &failed });
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "CR3a-2c2 stale stream operation permit rejects before deinitialized node access" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF6);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF6);
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x46);
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        0x4000,
        11,
        reservation.identity,
    );
    try slot.consumeStreamOperationPermit(permit);
    try slot.abortAttachmentBinding(&binding, reservation);
    slot.deinit();

    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.abortStreamOperationPermit(permit),
    );
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(permit),
    );
}
