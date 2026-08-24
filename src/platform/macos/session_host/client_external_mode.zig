//! One-way blocking-to-external fd mode transaction.
//!
//! This leaf owns only the external-mode storage inventory and exact fd-flag rollback policy.
//! `Client` remains the fd/parser owner and decides when an indeterminate transition poisons and
//! closes the connection.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const owner_seal = @import("external_owner_seal.zig");
const checked_event_counter = @import("checked_event_counter.zig");
const external_rx_types = @import("external_rx_types.zig");

pub const max_tx_frames: usize = 64;

var tx_quarantine_events: std.atomic.Value(u64) = .init(0);
var tx_quarantine_bytes: std.atomic.Value(usize) = .init(0);
var tx_quarantine_lock: std.atomic.Mutex = .unlocked;
threadlocal var active_tx_cleanup: ?*State = null;
threadlocal var active_tx_operation: ?*State = null;
threadlocal var tx_cleanup_reentry_events: u64 = 0;
threadlocal var active_tx_cleanup_id: u64 = 0;
var next_tx_cleanup_id: std.atomic.Value(u64) = .init(1);

const TxDeinitTestReceipt = struct {
    observed: bool = false,
    items: usize = std.math.maxInt(usize),
    capacity: usize = std.math.maxInt(usize),
    bytes: usize = std.math.maxInt(usize),
    retiring_bytes: usize = std.math.maxInt(usize),
    lifecycle: TxLifecycle = .live,
    claim_dead: bool = false,
};
threadlocal var tx_deinit_test_receipt: if (builtin.is_test)
    ?*TxDeinitTestReceipt
else
    u8 = if (builtin.is_test) null else 0;

pub fn chargeTxQuarantine(state: *State, bytes: usize) void {
    if (bytes == 0) return;
    while (!tx_quarantine_lock.tryLock()) std.atomic.spinLoopHint();
    defer tx_quarantine_lock.unlock();
    const next_events = std.math.add(
        u64,
        tx_quarantine_events.load(.acquire),
        1,
    ) catch @panic("external TX quarantine event counter exhausted");
    const next_bytes = std.math.add(
        usize,
        tx_quarantine_bytes.load(.acquire),
        bytes,
    ) catch @panic("external TX quarantine byte counter exhausted");
    tx_quarantine_events.store(next_events, .release);
    tx_quarantine_bytes.store(next_bytes, .release);
    state.external_tx_quarantined_bytes = std.math.add(
        usize,
        state.external_tx_quarantined_bytes,
        bytes,
    ) catch @panic("external TX storage quarantine counter exhausted");
}

pub fn resetTxQuarantineForTest() void {
    if (!builtin.is_test) @panic("test-only TX quarantine reset");
    tx_quarantine_events.store(0, .release);
    tx_quarantine_bytes.store(0, .release);
}

pub fn txQuarantineEventsForTest() u64 {
    if (!builtin.is_test) @panic("test-only TX quarantine observation");
    return tx_quarantine_events.load(.acquire);
}

pub fn txQuarantineBytesForTest() usize {
    if (!builtin.is_test) @panic("test-only TX quarantine observation");
    return tx_quarantine_bytes.load(.acquire);
}

var trusted_tx_allocator_context: u8 = 0;

fn trustedTxAlloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    return std.heap.c_allocator.rawAlloc(len, alignment, ret_addr);
}

fn trustedTxResize(
    _: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    return std.heap.c_allocator.rawResize(
        memory,
        alignment,
        new_len,
        ret_addr,
    );
}

fn trustedTxRemap(
    _: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    return std.heap.c_allocator.rawRemap(
        memory,
        alignment,
        new_len,
        ret_addr,
    );
}

fn trustedTxFree(
    _: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
}

pub const trusted_tx_allocator: std.mem.Allocator = .{
    .ptr = &trusted_tx_allocator_context,
    .vtable = &.{
        .alloc = trustedTxAlloc,
        .resize = trustedTxResize,
        .remap = trustedTxRemap,
        .free = trustedTxFree,
    },
};

pub const TxLifecycle = enum {
    live,
    completion_callback,
    terminal_tombstone,
    tearing_down,
    dead,
};

pub const DeinitResult = enum {
    cleaned,
    busy,
    already_dead,
};

pub const DeinitReservationResult = enum {
    reserved,
    busy,
    already_dead,
};

const TxClaim = enum(u8) {
    idle,
    operation,
    operation_close,
    idle_close,
    reserving,
    cleanup,
    dead,
};

pub const ExternalTxFrame = struct {
    bytes: []u8,
    offset: usize = 0,
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    activated_at_ns: i128,
    wire_digest: owner_seal.Digest,
    descriptor_digest: owner_seal.Digest,
};

pub fn txFrameDescriptorDigest(frame: ExternalTxFrame) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARUTXF1");
    writer.writeUsize(@intFromPtr(frame.bytes.ptr));
    writer.writeUsize(frame.bytes.len);
    writer.writeUsize(frame.offset);
    writer.writeU16(@intFromEnum(frame.kind));
    writer.writeU64(frame.stream_id);
    writer.writeU64(frame.request_id);
    writer.writeU128(@bitCast(frame.activated_at_ns));
    writer.writeBytes(&frame.wire_digest);
    return writer.finish();
}

pub const RxProvenanceLifecycle = enum { unbound, bound, terminal };

pub const RxIdentity = external_rx_types.RxIdentity;

pub const ParserAuthoritySeal = struct {
    domain: [8]u8 = [_]u8{0} ** 8,
    version: u16 = 0,
    seal_addr: usize = 0,
    parser_addr: usize = 0,
    identity: RxIdentity = .{},
    destination_slot_len: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    expected_major: u16 = 0,
    backing_addr: usize = 0,
    items_len: usize = 0,
    capacity: usize = 0,
    head: usize = 0,
    buffer_start_absolute: u64 = 0,
    rx_absolute_next: u64 = 0,
    resident_cap: usize = 0,
    generation: u64 = 0,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const RxProvenance = struct {
    identity: ?RxIdentity = null,
    destination_slot_len: usize = 0,
    rx_absolute_next: u64 = 0,
    buffer_start_absolute: u64 = 0,
    resident_cap: usize = 0,
    parser_seal: ParserAuthoritySeal = .{},
    lifecycle: RxProvenanceLifecycle = .unbound,
};

pub const RxRange = external_rx_types.RxRange;
pub const RxWatermark = external_rx_types.RxWatermark;
pub const ExternalRxFrameSeal = owner_seal.Digest;

pub const ExternalRxFrame = struct {
    frame: framing.Frame,
    range: RxRange,
    pair_seal: ExternalRxFrameSeal,
};

pub const ReadableAllowance = struct {
    bytes: usize,
    resident_limited: bool,
    turn_limited: bool,
    counter_limited: bool,
};

pub const MaxReadableResult = union(enum) {
    bytes: ReadableAllowance,
    turn_exhausted,
    resident_exhausted,
    counter_exhausted,
    invalid,
};

fn positiveReadableAllowance(
    resident_remaining: usize,
    turn_rx_remaining: usize,
    counter_remaining: usize,
) ReadableAllowance {
    const bytes = @min(
        resident_remaining,
        turn_rx_remaining,
        counter_remaining,
    );
    std.debug.assert(bytes != 0);
    return .{
        .bytes = bytes,
        .resident_limited = bytes == resident_remaining,
        .turn_limited = bytes == turn_rx_remaining,
        .counter_limited = bytes == counter_remaining,
    };
}

pub const Freshness = enum { fresh, stale, invalid };

pub const ExternalRxOutcome = union(enum) {
    incomplete,
    skipped: RxRange,
    frame: ExternalRxFrame,
};

pub const State = struct {
    saved_flags: c_int,
    external_tx: std.ArrayListUnmanaged(ExternalTxFrame) = .empty,
    tx_queue_backing_addr: usize = 0,
    tx_queue_backing_capacity: usize = 0,
    tx_allocator: std.mem.Allocator = trusted_tx_allocator,
    tx_allocator_context_len: usize = 1,
    external_tx_bytes: usize = 0,
    external_tx_retiring_bytes: usize = 0,
    external_tx_quarantined_bytes: usize = 0,
    tx_lifecycle: TxLifecycle = .live,
    tx_queue_generation: u64 = 1,
    tx_head_progress_baseline_ns: ?i128 = null,
    tx_last_observed_now_ns: ?i128 = null,
    tx_immediate_pending: bool = false,
    tx_claim: std.atomic.Value(u8) = .init(@intFromEnum(TxClaim.idle)),
    tx_cleanup_id: u64 = 0,
    tx_cleanup_owner_addr: usize = 0,
    rx_provenance: RxProvenance = .{},
    rx_operation_busy: bool = false,
    fn stage(allocator: std.mem.Allocator) error{OutOfMemory}!State {
        var result = State{ .saved_flags = 0 };
        result.external_tx.ensureTotalCapacityPrecise(allocator, max_tx_frames) catch
            return error.OutOfMemory;
        result.tx_queue_backing_addr = @intFromPtr(result.external_tx.items.ptr);
        result.tx_queue_backing_capacity = result.external_tx.capacity;
        return result;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.requestTxClose();
        switch (self.tryDeinit(allocator)) {
            .cleaned, .already_dead => {},
            .busy => {},
        }
    }

    /// Acquires the per-State operation/cleanup exclusion for one complete external-pump turn.
    /// The claim must remain held until the caller's last access to the owning Client.
    pub fn acquireTxOperation(self: *State) bool {
        if (active_tx_operation != null or active_tx_cleanup != null)
            return false;
        if (self.tx_claim.cmpxchgStrong(
            @intFromEnum(TxClaim.idle),
            @intFromEnum(TxClaim.operation),
            .acq_rel,
            .acquire,
        ) != null)
            return false;
        if (self.tx_cleanup_id != 0 or self.tx_cleanup_owner_addr != 0) {
            self.tx_claim.store(@intFromEnum(TxClaim.idle_close), .release);
            return false;
        }
        active_tx_operation = self;
        return true;
    }

    pub fn requestTxClose(self: *State) void {
        while (true) {
            const observed = self.tx_claim.load(.acquire);
            const desired = if (observed == @intFromEnum(TxClaim.idle))
                @intFromEnum(TxClaim.idle_close)
            else if (observed == @intFromEnum(TxClaim.operation))
                @intFromEnum(TxClaim.operation_close)
            else
                return;
            if (self.tx_claim.cmpxchgWeak(
                observed,
                desired,
                .acq_rel,
                .acquire,
            ) == null) return;
        }
    }

    pub fn txCloseRequested(self: *const State) bool {
        const claim = self.tx_claim.load(.acquire);
        return claim == @intFromEnum(TxClaim.operation_close) or
            claim == @intFromEnum(TxClaim.idle_close) or
            claim == @intFromEnum(TxClaim.reserving) or
            claim == @intFromEnum(TxClaim.cleanup);
    }

    pub fn txOperationHeldByCurrentThread(self: *const State) bool {
        if (active_tx_operation != self) return false;
        const claim = self.tx_claim.load(.acquire);
        return claim == @intFromEnum(TxClaim.operation) or
            claim == @intFromEnum(TxClaim.operation_close);
    }

    /// Releases a successfully acquired operation. The release store is the final access to
    /// `self`, allowing a waiting cross-thread Client teardown to proceed immediately afterwards.
    pub fn releaseTxOperation(self: *State) bool {
        return self.releaseTxOperationAndObserveClose() != null;
    }

    pub fn releaseTxOperationAndObserveClose(self: *State) ?bool {
        return self.releaseTxOperationAndObserveCloseWithHook(null, undefined);
    }

    fn releaseTxOperationAndObserveCloseWithHook(
        self: *State,
        hook: ?*const fn (*anyopaque) void,
        hook_context: *anyopaque,
    ) ?bool {
        if (active_tx_operation != self) return null;
        var close_requested = false;
        var hook_called = false;
        while (true) {
            const observed = self.tx_claim.load(.acquire);
            const desired = if (observed == @intFromEnum(TxClaim.operation))
                @intFromEnum(TxClaim.idle)
            else if (observed == @intFromEnum(TxClaim.operation_close)) blk: {
                close_requested = true;
                break :blk @intFromEnum(TxClaim.idle_close);
            } else return null;
            if (!hook_called) {
                hook_called = true;
                if (hook) |callback| callback(hook_context);
            }
            if (self.tx_claim.cmpxchgWeak(
                observed,
                desired,
                .acq_rel,
                .acquire,
            ) == null) break;
        }
        active_tx_operation = null;
        return close_requested;
    }

    pub fn tryDeinit(
        self: *State,
        allocator: std.mem.Allocator,
    ) DeinitResult {
        return switch (self.reserveDeinit()) {
            .reserved => self.finishReservedDeinit(allocator),
            .busy => .busy,
            .already_dead => .already_dead,
        };
    }

    /// Reserves cleanup across callback-bearing outer-owner teardown. Public cleanup remains busy
    /// until the reserving owner consumes the claim with `finishReservedDeinit`.
    pub fn reserveDeinit(self: *State) DeinitReservationResult {
        return self.reserveDeinitWithHook(null, undefined);
    }

    fn reserveDeinitWithHook(
        self: *State,
        hook: ?*const fn (*anyopaque) void,
        hook_context: *anyopaque,
    ) DeinitReservationResult {
        while (true) {
            const observed = self.tx_claim.load(.acquire);
            if (observed == @intFromEnum(TxClaim.dead))
                return .already_dead;
            if (observed != @intFromEnum(TxClaim.idle) and
                observed != @intFromEnum(TxClaim.idle_close))
            {
                if (active_tx_cleanup != null)
                    tx_cleanup_reentry_events = std.math.add(
                        u64,
                        tx_cleanup_reentry_events,
                        1,
                    ) catch @panic(
                        "external TX cleanup reentry counter exhausted",
                    );
                return .busy;
            }
            if (self.tx_claim.cmpxchgWeak(
                observed,
                @intFromEnum(TxClaim.reserving),
                .acq_rel,
                .acquire,
            ) == null) break;
        }
        if (hook) |callback| callback(hook_context);
        if (self.tx_cleanup_id != 0 or self.tx_cleanup_owner_addr != 0) {
            self.tx_claim.store(@intFromEnum(TxClaim.idle_close), .release);
            return .busy;
        }
        if (self.tx_lifecycle == .completion_callback or
            self.tx_lifecycle == .tearing_down)
        {
            self.tx_claim.store(@intFromEnum(TxClaim.idle_close), .release);
            return .busy;
        }
        if (self.tx_lifecycle == .dead) {
            self.tx_claim.store(@intFromEnum(TxClaim.dead), .release);
            return .already_dead;
        }
        if (active_tx_cleanup != null) {
            tx_cleanup_reentry_events = std.math.add(
                u64,
                tx_cleanup_reentry_events,
                1,
            ) catch @panic("external TX cleanup reentry counter exhausted");
            self.tx_claim.store(@intFromEnum(TxClaim.idle_close), .release);
            return .busy;
        }
        active_tx_cleanup = self;
        const reservation_id = next_tx_cleanup_id.fetchAdd(1, .acq_rel);
        if (reservation_id == 0 or reservation_id == std.math.maxInt(u64))
            @panic("external TX cleanup reservation ID exhausted");
        self.tx_cleanup_id = reservation_id;
        self.tx_cleanup_owner_addr = @intFromPtr(self);
        active_tx_cleanup_id = reservation_id;
        self.tx_claim.store(@intFromEnum(TxClaim.cleanup), .release);
        return .reserved;
    }

    pub fn transferReservedDeinit(self: *State, destination: *State) bool {
        if (self == destination or
            active_tx_cleanup != self or
            active_tx_cleanup_id == 0 or
            self.tx_cleanup_id != active_tx_cleanup_id or
            self.tx_cleanup_owner_addr != @intFromPtr(self) or
            self.tx_claim.load(.acquire) !=
                @intFromEnum(TxClaim.cleanup) or
            destination.tx_claim.load(.acquire) !=
                @intFromEnum(TxClaim.cleanup) or
            destination.tx_cleanup_id != self.tx_cleanup_id or
            destination.tx_cleanup_owner_addr != @intFromPtr(self) or
            destination.tx_cleanup_id == 0)
            return false;
        destination.tx_cleanup_owner_addr = @intFromPtr(destination);
        active_tx_cleanup = destination;
        return true;
    }

    pub fn cancelReservedDeinit(self: *State) bool {
        if (active_tx_cleanup != self or
            active_tx_cleanup_id == 0 or
            self.tx_cleanup_id != active_tx_cleanup_id or
            self.tx_cleanup_owner_addr != @intFromPtr(self) or
            self.tx_claim.load(.acquire) !=
                @intFromEnum(TxClaim.cleanup))
            return false;
        active_tx_cleanup = null;
        active_tx_cleanup_id = 0;
        self.tx_cleanup_id = 0;
        self.tx_cleanup_owner_addr = 0;
        self.tx_claim.store(@intFromEnum(TxClaim.idle_close), .release);
        return true;
    }

    pub fn finishReservedDeinit(
        self: *State,
        allocator: std.mem.Allocator,
    ) DeinitResult {
        if (active_tx_cleanup == null and
            self.tx_claim.load(.acquire) == @intFromEnum(TxClaim.dead))
            return .already_dead;
        if (active_tx_cleanup != self or
            active_tx_cleanup_id == 0 or
            self.tx_cleanup_id != active_tx_cleanup_id or
            self.tx_cleanup_owner_addr != @intFromPtr(self) or
            self.tx_claim.load(.acquire) !=
                @intFromEnum(TxClaim.cleanup))
            return .busy;
        const cleanup_id = active_tx_cleanup_id;
        const cleanup_owner_addr = @intFromPtr(self);
        defer {
            active_tx_cleanup = null;
            active_tx_cleanup_id = 0;
        }
        var frozen: [max_tx_frames]ExternalTxFrame = undefined;
        const entry_lifecycle = self.tx_lifecycle;
        const backing_valid =
            self.tx_queue_backing_addr != 0 and
            self.tx_queue_backing_capacity == max_tx_frames and
            self.external_tx.capacity == self.tx_queue_backing_capacity and
            @intFromPtr(self.external_tx.items.ptr) ==
                self.tx_queue_backing_addr;
        const list_valid = self.tx_lifecycle == .live and backing_valid and
            self.external_tx.items.len <= max_tx_frames and
            self.external_tx.items.len <= self.external_tx.capacity and
            self.external_tx_retiring_bytes == 0;
        var count = if (list_valid)
            self.external_tx.items.len
        else
            0;
        if (count != 0)
            @memcpy(frozen[0..count], self.external_tx.items[0..count]);
        const frozen_backing = if (backing_valid)
            self.external_tx.allocatedSlice()
        else
            @as([]ExternalTxFrame, &.{});
        // Validate the complete frozen cleanup graph before the first allocator callback. This
        // prevents a recomputed public descriptor digest from turning duplicate or protected
        // ranges into a wrong-free/double-free sequence during terminal teardown.
        var frozen_total: usize = 0;
        var frozen_valid = count != 0 or
            (list_valid and self.external_tx_bytes == 0);
        for (frozen[0..count], 0..) |frame, index| {
            const address = @intFromPtr(frame.bytes.ptr);
            const end = std.math.add(usize, address, frame.bytes.len) catch {
                frozen_valid = false;
                break;
            };
            if (address == 0 or frame.bytes.len < protocol.header_size or
                frame.bytes.len > protocol.max_binary_chunk + protocol.header_size or
                frame.offset > frame.bytes.len or
                !std.mem.eql(
                    u8,
                    &frame.descriptor_digest,
                    &txFrameDescriptorDigest(frame),
                ))
            {
                frozen_valid = false;
                break;
            }
            const protected = [_]struct { address: usize, len: usize }{
                .{ .address = @intFromPtr(self), .len = @sizeOf(State) },
                .{
                    .address = self.tx_queue_backing_addr,
                    .len = self.tx_queue_backing_capacity *
                        @sizeOf(ExternalTxFrame),
                },
                .{
                    .address = @intFromPtr(self.tx_allocator.ptr),
                    .len = self.tx_allocator_context_len,
                },
                .{
                    .address = @intFromPtr(self.tx_allocator.vtable),
                    .len = @sizeOf(std.mem.Allocator.VTable),
                },
            };
            for (protected) |range| {
                const range_end = std.math.add(
                    usize,
                    range.address,
                    range.len,
                ) catch {
                    frozen_valid = false;
                    break;
                };
                if (address < range_end and range.address < end) {
                    frozen_valid = false;
                    break;
                }
            }
            if (!frozen_valid) break;
            for (frozen[0..index]) |prior| {
                const prior_address = @intFromPtr(prior.bytes.ptr);
                const prior_end = std.math.add(
                    usize,
                    prior_address,
                    prior.bytes.len,
                ) catch {
                    frozen_valid = false;
                    break;
                };
                if (address < prior_end and prior_address < end) {
                    frozen_valid = false;
                    break;
                }
            }
            if (!frozen_valid) break;
            frozen_total = std.math.add(
                usize,
                frozen_total,
                frame.bytes.len,
            ) catch {
                frozen_valid = false;
                break;
            };
        }
        const graph_invalid =
            !frozen_valid or frozen_total != self.external_tx_bytes;
        if (graph_invalid) {
            if (entry_lifecycle == .live and
                self.external_tx_bytes != 0 and
                self.external_tx_quarantined_bytes == 0)
                chargeTxQuarantine(self, self.external_tx_bytes);
            count = 0;
        }
        const frame_allocator = self.tx_allocator;
        const frozen_allocator_ptr = @intFromPtr(self.tx_allocator.ptr);
        const frozen_allocator_vtable = @intFromPtr(self.tx_allocator.vtable);
        const frozen_allocator_context_len = self.tx_allocator_context_len;
        const frozen_backing_addr = self.tx_queue_backing_addr;
        const frozen_backing_capacity = self.tx_queue_backing_capacity;
        const frozen_queue_generation = self.tx_queue_generation;
        const frozen_quarantined_bytes = self.external_tx_quarantined_bytes;
        const cleanup_total = frozen_total;
        var cleanup_drift_charged = graph_invalid;
        var cleanup_drifted = false;
        self.tx_lifecycle = .tearing_down;
        self.external_tx = .empty;
        self.external_tx_bytes = 0;
        self.external_tx_retiring_bytes = if (count == 0) 0 else frozen_total;
        self.tx_head_progress_baseline_ns = null;
        self.tx_immediate_pending = false;
        for (frozen[0..count], 0..) |frame, index| {
            const reentry_before = tx_cleanup_reentry_events;
            if (frame.bytes.len != 0 and
                frame.offset <= frame.bytes.len and
                std.mem.eql(
                    u8,
                    &frame.descriptor_digest,
                    &txFrameDescriptorDigest(frame),
                ))
                frame_allocator.rawFree(
                    frame.bytes,
                    .@"1",
                    @returnAddress(),
                );
            var remaining_descriptors_valid = true;
            for (
                frozen[index + 1 .. count],
                frozen_backing[index + 1 .. count],
            ) |expected, current| {
                if (@intFromPtr(expected.bytes.ptr) !=
                    @intFromPtr(current.bytes.ptr) or
                    expected.bytes.len != current.bytes.len or
                    expected.offset != current.offset or
                    expected.kind != current.kind or
                    expected.stream_id != current.stream_id or
                    expected.request_id != current.request_id or
                    expected.activated_at_ns != current.activated_at_ns or
                    !std.mem.eql(
                        u8,
                        &expected.wire_digest,
                        &current.wire_digest,
                    ) or
                    !std.mem.eql(
                        u8,
                        &expected.descriptor_digest,
                        &current.descriptor_digest,
                    ))
                {
                    remaining_descriptors_valid = false;
                    break;
                }
            }
            if (!remaining_descriptors_valid or
                tx_cleanup_reentry_events != reentry_before or
                self.tx_lifecycle != .tearing_down or
                self.external_tx.items.len != 0 or
                self.external_tx.capacity != 0 or
                self.external_tx_bytes != 0 or
                self.external_tx_retiring_bytes < frame.bytes.len or
                self.external_tx_quarantined_bytes !=
                    frozen_quarantined_bytes or
                self.tx_queue_backing_addr != frozen_backing_addr or
                self.tx_queue_backing_capacity != frozen_backing_capacity or
                self.tx_queue_generation != frozen_queue_generation or
                self.tx_cleanup_id != cleanup_id or
                self.tx_cleanup_owner_addr != cleanup_owner_addr or
                @intFromPtr(self.tx_allocator.ptr) != frozen_allocator_ptr or
                @intFromPtr(self.tx_allocator.vtable) !=
                    frozen_allocator_vtable or
                self.tx_allocator_context_len !=
                    frozen_allocator_context_len)
            {
                if (!cleanup_drift_charged and cleanup_total != 0) {
                    chargeTxQuarantine(self, cleanup_total);
                    cleanup_drift_charged = true;
                }
                cleanup_drifted = true;
                break;
            }
            self.external_tx_retiring_bytes -= frame.bytes.len;
        }
        if (!cleanup_drifted and frozen_backing.len != 0)
            allocator.rawFree(
                std.mem.sliceAsBytes(frozen_backing),
                .of(ExternalTxFrame),
                @returnAddress(),
            );
        if ((self.tx_lifecycle != .tearing_down or
            self.external_tx.items.len != 0 or
            self.external_tx.capacity != 0 or
            self.external_tx_bytes != 0 or
            self.external_tx_retiring_bytes != 0 or
            self.tx_queue_backing_addr != frozen_backing_addr or
            self.tx_queue_backing_capacity != frozen_backing_capacity or
            self.tx_queue_generation != frozen_queue_generation or
            self.tx_cleanup_id != cleanup_id or
            self.tx_cleanup_owner_addr != cleanup_owner_addr or
            @intFromPtr(self.tx_allocator.ptr) != frozen_allocator_ptr or
            @intFromPtr(self.tx_allocator.vtable) !=
                frozen_allocator_vtable or
            self.tx_allocator_context_len != frozen_allocator_context_len) and
            !cleanup_drift_charged and cleanup_total != 0)
            chargeTxQuarantine(self, cleanup_total);
        self.tx_lifecycle = .dead;
        self.external_tx = .empty;
        self.tx_queue_backing_addr = 0;
        self.tx_queue_backing_capacity = 0;
        self.external_tx_bytes = 0;
        self.external_tx_retiring_bytes = 0;
        self.tx_head_progress_baseline_ns = null;
        self.tx_immediate_pending = false;
        self.tx_cleanup_id = 0;
        self.tx_cleanup_owner_addr = 0;
        self.tx_claim.store(@intFromEnum(TxClaim.dead), .release);
        if (builtin.is_test) if (tx_deinit_test_receipt) |receipt| {
            receipt.* = .{
                .observed = true,
                .items = self.external_tx.items.len,
                .capacity = self.external_tx.capacity,
                .bytes = self.external_tx_bytes,
                .retiring_bytes = self.external_tx_retiring_bytes,
                .lifecycle = self.tx_lifecycle,
                .claim_dead = self.tx_claim.load(.acquire) ==
                    @intFromEnum(TxClaim.dead),
            };
        };
        return .cleaned;
    }
};

var pristine_rx_append_allocator_context: u8 = 0;

fn pristineRxAppendAlloc(
    _: *anyopaque,
    _: usize,
    _: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    return null;
}

fn pristineRxAppendResize(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) bool {
    return false;
}

fn pristineRxAppendRemap(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null;
}

fn pristineRxAppendFree(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {}

const pristine_rx_append_allocator: std.mem.Allocator = .{
    .ptr = &pristine_rx_append_allocator_context,
    .vtable = &.{
        .alloc = pristineRxAppendAlloc,
        .resize = pristineRxAppendResize,
        .remap = pristineRxAppendRemap,
        .free = pristineRxAppendFree,
    },
};

const PreparedLifecycle = enum { empty, prepared, committed, aborted };
const PreparedAppendLifecycle = enum { empty, prepared, committed, aborted, quarantined };

pub const PreparedAdmitCompletion = enum {
    pristine,
    active,
    ordinary_finished,
    quarantine_pending,
    quarantine_accounted,
};

pub const GuardedAdmitQuarantinePhase = enum {
    allocation,
    abort_cleanup,
    commit_cleanup,
};

pub const GuardedAdmitQuarantine = struct {
    phase: GuardedAdmitQuarantinePhase,
    quarantined_bytes_upper_bound: usize,
};

pub const GuardedQuarantineOutcomeTag = enum {
    allocation_quarantined,
    post_commit_quarantined,
};

pub const PreparedRxBind = struct {
    saved_self_addr: usize = 0,
    source_state_addr: usize = 0,
    destination_slot_addr: usize = 0,
    destination_slot_len: usize = 0,
    normalized_addr: usize = 0,
    identity: ?RxIdentity = null,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    expected_major: u16 = 0,
    resident_cap: usize = 0,
    unread_len: u64 = 0,
    unread_digest: owner_seal.Digest = [_]u8{0} ** 32,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLifecycle = .empty,

    pub fn deinit(self: *PreparedRxBind) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        self.* = .{ .lifecycle = .aborted };
    }

    pub fn validate(
        self: *const PreparedRxBind,
        source_state: *const State,
        attach_instance_id: u64,
        normalized: *const framing.PreparedNormalizeExact,
        destination_slot_addr: usize,
        destination_slot_len: usize,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_state_addr != @intFromPtr(source_state) or
            self.normalized_addr != @intFromPtr(normalized) or
            self.destination_slot_addr != destination_slot_addr or
            self.destination_slot_len != destination_slot_len or
            self.identity == null or
            self.identity.?.attach_instance_id != attach_instance_id or
            self.identity.?.destination_slot_addr != destination_slot_addr or
            self.allocator_ptr_addr != normalized.allocator_ptr_addr or
            self.allocator_vtable_addr != normalized.allocator_vtable_addr or
            self.expected_major != normalized.expected_major or
            self.resident_cap == 0 or
            self.unread_len > self.resident_cap or
            !std.meta.eql(source_state.rx_provenance, RxProvenance{}) or
            self.unread_len != normalized.replacement_len)
            return false;
        const unread = normalized.replacement orelse {
            if (self.unread_len != 0) return false;
            return std.mem.eql(u8, &self.digest, &rxBindDigest(self));
        };
        if (unread.len != self.unread_len or
            !std.mem.eql(u8, &self.unread_digest, &bytesDigest(unread)))
            return false;
        return std.mem.eql(u8, &self.digest, &rxBindDigest(self));
    }
};

pub const PreparedRxAppend = struct {
    saved_self_addr: usize = 0,
    state_addr: usize = 0,
    parser_addr: usize = 0,
    expected_start: u64 = 0,
    bytes_addr: usize = 0,
    bytes_len: usize = 0,
    bytes_digest: owner_seal.Digest = [_]u8{0} ** 32,
    source_seal: ParserAuthoritySeal = .{},
    unread_digest: owner_seal.Digest = [_]u8{0} ** 32,
    allocator: std.mem.Allocator = pristine_rx_append_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    replacement_addr: usize = 0,
    replacement_len: usize = 0,
    final_items_len: usize = 0,
    resident_cap: usize = 0,
    replacement: ?[]u8 = null,
    cleanup_replacement: ?[]u8 = null,
    replacement_guard: ?ReplacementAllocationGuard = null,
    replacement_authority_seal: ReplacementAuthoritySeal = .{},
    cleanup_digest: owner_seal.Digest = [_]u8{0} ** 32,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedAppendLifecycle = .empty,
    completion: PreparedAdmitCompletion = .pristine,
    quarantine_outcome_tag: GuardedQuarantineOutcomeTag =
        .allocation_quarantined,
    quarantine_phase: GuardedAdmitQuarantinePhase = .allocation,
    quarantine_upper_bound: usize = 0,

    fn deinitInternal(self: *PreparedRxAppend) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            // A guarded replacement may only be freed through abort/commit, where the opaque
            // owner-range authority can be revalidated. Generic teardown deliberately drops the
            // capability instead of calling an allocator with an unproven descriptor.
            if (self.replacement_guard != null) {
                self.* = .{ .lifecycle = .quarantined };
                return;
            }
            const replacement = canonicalAppendReplacement(self);
            const allocator = self.allocator;
            self.replacement = null;
            self.cleanup_replacement = null;
            self.lifecycle = .aborted;
            if (replacement) |bytes| {
                allocator.free(bytes);
            }
            return;
        }
        self.replacement = null;
        self.cleanup_replacement = null;
        self.lifecycle = .aborted;
    }
};

pub const RxParseScratch = struct {
    saved_self_addr: usize = 0,
    parser_addr: usize = 0,
    source_seal: ParserAuthoritySeal = .{},
    frame_start_absolute: u64 = 0,
    frame_end_absolute: u64 = 0,
    header: ?protocol.Header = null,
    frame_digest: owner_seal.Digest = [_]u8{0} ** 32,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    payload_addr: usize = 0,
    payload_len: usize = 0,
    payload: ?[]u8 = null,
    cleanup_payload: ?[]u8 = null,
    cleanup_digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLifecycle = .empty,

    pub fn deinit(self: *RxParseScratch) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            const payload = canonicalParsePayload(self);
            const allocator = self.allocator;
            self.payload = null;
            self.cleanup_payload = null;
            self.lifecycle = .aborted;
            if (payload) |owned| allocator.free(owned);
            return;
        }
        self.payload = null;
        self.cleanup_payload = null;
        self.lifecycle = .aborted;
    }
};

pub const RxPrepareError = error{
    InvalidState,
    InvalidDescriptor,
    InvalidSeal,
    InvalidIdentity,
    ArithmeticOverflow,
    ResidentCap,
    OutOfMemory,
};

pub const RxParseError = error{
    InvalidState,
    InvalidDescriptor,
    InvalidSeal,
    AllocationQuarantined,
    ArithmeticOverflow,
    Protocol,
    OutOfMemory,
};

pub const PayloadAllocationVerdict = enum {
    accepted,
    reject_no_free,
};

/// Optional product guard for allocator output that must be checked against owner ranges which
/// this parser leaf does not own. It runs immediately after `rawAlloc`, before typed conversion,
/// payload copy, parser consume, or cleanup. A rejection deliberately leaves the untrusted address
/// unfreed because allocator ownership has not been proven.
pub const PayloadAllocationGuard = struct {
    context: *anyopaque,
    check: *const fn (
        context: *anyopaque,
        allocation_addr: usize,
        allocation_len: usize,
    ) PayloadAllocationVerdict,
};

pub const ReplacementAuthoritySeal = struct {
    generation: u64 = 0,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const ReplacementGuardPhase = enum {
    capture_before_allocate,
    capture_after_allocate,
    validate_allocated,
    capture_after_validate,
    capture_before_cleanup,
    validate_after_cleanup,
    capture_after_cleanup_validate,
};

pub const ReplacementCandidate = struct {
    addr: usize,
    len: usize,
};

pub const ReplacementGuardResult = union(enum) {
    seal: ReplacementAuthoritySeal,
    accepted: ReplacementAuthoritySeal,
    quarantined,
};

/// Opaque owner-range authority supplied by the pump layer. This leaf freezes the descriptor and
/// compares value-only seals; it never imports or reconstructs pump/storage/ledger ownership.
pub const ReplacementAllocationGuard = struct {
    context: *anyopaque,
    check: *const fn (
        context: *anyopaque,
        phase: ReplacementGuardPhase,
        expected: ?ReplacementAuthoritySeal,
        candidate: ?ReplacementCandidate,
    ) ReplacementGuardResult,
};

pub const GuardedAdmitFailure = struct {
    reason: RxPrepareError,
};

pub const GuardedAdmitPrepareOutcome = union(enum) {
    prepared,
    ordinary_failure: GuardedAdmitFailure,
    allocation_quarantined: GuardedAdmitQuarantine,
};

pub const GuardedAdmitCommitOutcome = union(enum) {
    committed,
    ordinary_failure: GuardedAdmitFailure,
    allocation_quarantined: GuardedAdmitQuarantine,
    post_commit_quarantined: GuardedAdmitQuarantine,
};

pub const GuardedAdmitAbortOutcome = union(enum) {
    aborted,
    ordinary_failure: GuardedAdmitFailure,
    allocation_quarantined: GuardedAdmitQuarantine,
};

const parser_seal_domain = "MARURXP2";
const parser_seal_version: u16 = 2;

fn bytesDigest(bytes: []const u8) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-bytes.v1");
    writer.writeBytes(bytes);
    return writer.finish();
}

fn externalRxFrameDigest(frame: *const ExternalRxFrame) owner_seal.Digest {
    var writer = owner_seal.Writer.init("external-rx-frame.v1");
    writer.writeU64(frame.range.identity.attach_instance_id);
    writer.writeUsize(frame.range.identity.destination_slot_addr);
    writer.writeU64(frame.range.start_absolute);
    writer.writeU64(frame.range.end_absolute);
    const header_bytes = frame.frame.header.encode();
    writer.writeBytes(&header_bytes);
    writer.writeBytes(frame.frame.payload);
    return writer.finish();
}

pub fn validateExternalRxFrame(frame: *const ExternalRxFrame) bool {
    if (frame.range.identity.attach_instance_id == 0 or
        frame.range.identity.destination_slot_addr == 0 or
        frame.range.start_absolute >= frame.range.end_absolute or
        frame.frame.payload.len > std.math.maxInt(u32) or
        frame.frame.header.payload_len != @as(u32, @intCast(frame.frame.payload.len)))
        return false;
    const total = std.math.add(
        usize,
        protocol.header_size,
        frame.frame.payload.len,
    ) catch return false;
    const observed = std.math.sub(
        u64,
        frame.range.end_absolute,
        frame.range.start_absolute,
    ) catch return false;
    return observed == @as(u64, @intCast(total)) and
        std.mem.eql(u8, &frame.pair_seal, &externalRxFrameDigest(frame));
}

pub const testing = if (builtin.is_test) struct {
    pub const TxDeinitReceipt = TxDeinitTestReceipt;

    pub fn beginTxDeinitReceipt(receipt: *TxDeinitReceipt) bool {
        if (tx_deinit_test_receipt != null) return false;
        receipt.* = .{};
        tx_deinit_test_receipt = receipt;
        return true;
    }

    pub fn endTxDeinitReceipt(receipt: *TxDeinitReceipt) bool {
        if (tx_deinit_test_receipt != receipt) return false;
        tx_deinit_test_receipt = null;
        return true;
    }

    pub fn sealExternalRxFrame(frame: *ExternalRxFrame) void {
        frame.pair_seal = externalRxFrameDigest(frame);
    }

    pub fn forgeResealedResidentCap(
        state: *State,
        parser: *const framing.FrameParser,
        resident_cap: usize,
    ) bool {
        if (state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
            return false;
        state.rx_provenance.resident_cap = resident_cap;
        state.rx_provenance.parser_seal = makeParserSeal(
            parser,
            &state.rx_provenance,
            state.rx_provenance.parser_seal.generation + 1,
        ) orelse return false;
        return parserSealValid(state, parser);
    }

    pub fn forgeResealedNoProgress(
        state: *State,
        parser: *const framing.FrameParser,
    ) bool {
        if (state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
            return false;
        state.rx_provenance.parser_seal = makeParserSeal(
            parser,
            &state.rx_provenance,
            state.rx_provenance.parser_seal.generation + 1,
        ) orelse return false;
        return parserSealValid(state, parser);
    }

    /// Test-only injection for already-buffered product fixtures. C2 keeps the real pump and
    /// collector callsite closed; tests reach the guarded leaf through this synthetic authority.
    pub fn admitBuffered(
        state: *State,
        parser: *framing.FrameParser,
        bytes: []const u8,
        resident_cap: usize,
    ) !void {
        const SyntheticGuard = struct {
            seal: ReplacementAuthoritySeal = .{
                .generation = 1,
                .digest = [_]u8{0x39} ** 32,
            },

            fn check(
                raw: *anyopaque,
                phase: ReplacementGuardPhase,
                expected: ?ReplacementAuthoritySeal,
                candidate: ?ReplacementCandidate,
            ) ReplacementGuardResult {
                const self: *@This() = @ptrCast(@alignCast(raw));
                return switch (phase) {
                    .capture_before_allocate,
                    .capture_after_allocate,
                    .capture_after_validate,
                    .capture_before_cleanup,
                    .capture_after_cleanup_validate,
                    => .{ .seal = self.seal },
                    .validate_allocated, .validate_after_cleanup => if (expected != null and
                        std.meta.eql(expected.?, self.seal) and candidate != null)
                        .{ .accepted = self.seal }
                    else
                        .quarantined,
                };
            }
        };
        var context = SyntheticGuard{};
        const guard = ReplacementAllocationGuard{
            .context = &context,
            .check = SyntheticGuard.check,
        };
        var prepared: PreparedRxAppend = .{};
        switch (prepareAdmitGuarded(
            state,
            parser,
            bytes,
            state.rx_provenance.rx_absolute_next,
            resident_cap,
            &guard,
            &prepared,
        )) {
            .prepared => {},
            .ordinary_failure => |failure| return failure.reason,
            .allocation_quarantined => return error.TestUnexpectedResult,
        }
        switch (commitPreparedAdmitGuarded(state, parser, bytes, &prepared)) {
            .committed => {},
            .ordinary_failure => |failure| return failure.reason,
            .allocation_quarantined,
            .post_commit_quarantined,
            => return error.TestUnexpectedResult,
        }
    }

    pub fn seedOrdinaryFinishedPreparedAdmit(
        prepared: *PreparedRxAppend,
        committed: bool,
    ) bool {
        if (!preparedRxAppendPristine(prepared)) return false;
        markOrdinaryPreparedAdmitFinished(
            prepared,
            if (committed) .committed else .aborted,
        );
        return true;
    }

    pub fn seedQuarantinePendingPreparedAdmit(
        prepared: *PreparedRxAppend,
        outcome_tag: GuardedQuarantineOutcomeTag,
        quarantine: GuardedAdmitQuarantine,
    ) bool {
        if (!preparedRxAppendPristine(prepared)) return false;
        markQuarantinedPreparedAdmitPending(
            prepared,
            if (outcome_tag == .post_commit_quarantined)
                .committed
            else
                .quarantined,
            outcome_tag,
            quarantine,
        );
        return true;
    }

    /// Produces an ordinary completion through the guarded product branch so collector completion
    /// tests cannot stay green if commit stops publishing its tombstone.
    pub fn finishOrdinaryGuardedCommitForTest(
        prepared: *PreparedRxAppend,
    ) !bool {
        if (!preparedRxAppendPristine(prepared)) return false;
        var state = State{ .saved_flags = 7 };
        defer state.deinit(std.testing.allocator);
        var parser = framing.FrameParser.init(std.testing.allocator);
        defer parser.deinit();
        var destination_slot: usize = 0;
        try bindParserForTest(&state, &parser, 901, &destination_slot);
        try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
        if (!resealParserAuthority(&state, &parser)) return false;
        try setResidentCapForTest(&state, &parser, 8);
        var guard_context = TestReplacementGuard{};
        const guard = guard_context.guard();
        if (prepareAdmitGuarded(
            &state,
            &parser,
            "x",
            0,
            8,
            &guard,
            prepared,
        ) != .prepared) return false;
        if (commitPreparedAdmitGuarded(
            &state,
            &parser,
            "x",
            prepared,
        ) != .committed) return false;
        return prepared.completion == .ordinary_finished;
    }

    /// Produces quarantine through the authenticated guarded commit failure branch. The returned
    /// token is consumed by the pump accounting/finalizer fixture at its original address.
    pub fn finishQuarantinedGuardedCommitForTest(
        prepared: *PreparedRxAppend,
    ) !?GuardedAdmitQuarantine {
        if (!preparedRxAppendPristine(prepared)) return null;
        var state = State{ .saved_flags = 7 };
        defer state.deinit(std.testing.allocator);
        var parser = framing.FrameParser.init(std.testing.allocator);
        defer parser.deinit();
        var destination_slot: usize = 0;
        try bindParserForTest(&state, &parser, 902, &destination_slot);
        try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
        if (!resealParserAuthority(&state, &parser)) return null;
        try setResidentCapForTest(&state, &parser, 8);
        var guard_context = TestReplacementGuard{};
        const guard = guard_context.guard();
        if (prepareAdmitGuarded(
            &state,
            &parser,
            "x",
            0,
            8,
            &guard,
            prepared,
        ) != .prepared) return null;
        prepared.digest[0] +%= 1;
        return switch (commitPreparedAdmitGuarded(
            &state,
            &parser,
            "x",
            prepared,
        )) {
            .allocation_quarantined => |quarantine| quarantine,
            else => null,
        };
    }

    pub fn sealParserAuthorityProjection(
        seal: *ParserAuthoritySeal,
    ) void {
        seal.domain = parser_seal_domain.*;
        seal.version = parser_seal_version;
        seal.digest = parserSealDigest(seal);
    }
} else struct {};

fn rxBindDigest(prepared: *const PreparedRxBind) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-bind.v2");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.source_state_addr);
    writer.writeUsize(prepared.destination_slot_addr);
    writer.writeUsize(prepared.destination_slot_len);
    writer.writeUsize(prepared.normalized_addr);
    const identity = prepared.identity orelse RxIdentity{};
    writer.writeU64(identity.attach_instance_id);
    writer.writeUsize(identity.destination_slot_addr);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeU16(prepared.expected_major);
    writer.writeUsize(prepared.resident_cap);
    writer.writeU64(prepared.unread_len);
    writer.writeBytes(&prepared.unread_digest);
    return writer.finish();
}

fn appendDigest(prepared: *const PreparedRxAppend) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-append.v1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.state_addr);
    writer.writeUsize(prepared.parser_addr);
    writer.writeU64(prepared.expected_start);
    writer.writeUsize(prepared.bytes_addr);
    writer.writeUsize(prepared.bytes_len);
    writer.writeBytes(&prepared.bytes_digest);
    writer.writeBytes(&prepared.source_seal.digest);
    writer.writeBytes(&prepared.unread_digest);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeUsize(prepared.replacement_addr);
    writer.writeUsize(prepared.replacement_len);
    writer.writeUsize(prepared.final_items_len);
    writer.writeUsize(prepared.resident_cap);
    if (prepared.replacement_guard) |guard| {
        writer.writeUsize(@intFromPtr(guard.context));
        writer.writeUsize(@intFromPtr(guard.check));
    } else {
        writer.writeUsize(0);
        writer.writeUsize(0);
    }
    writer.writeU64(prepared.replacement_authority_seal.generation);
    writer.writeBytes(&prepared.replacement_authority_seal.digest);
    writer.writeBytes(&prepared.cleanup_digest);
    writer.writeU8(@intFromEnum(prepared.lifecycle));
    writer.writeU8(@intFromEnum(prepared.completion));
    writer.writeU8(@intFromEnum(prepared.quarantine_outcome_tag));
    writer.writeU8(@intFromEnum(prepared.quarantine_phase));
    writer.writeUsize(prepared.quarantine_upper_bound);
    return writer.finish();
}

fn appendCleanupDigest(prepared: *const PreparedRxAppend) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-append-cleanup.v1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeUsize(prepared.replacement_addr);
    writer.writeUsize(prepared.replacement_len);
    writer.writeUsize(prepared.resident_cap);
    if (prepared.replacement_guard) |guard| {
        writer.writeUsize(@intFromPtr(guard.context));
        writer.writeUsize(@intFromPtr(guard.check));
    } else {
        writer.writeUsize(0);
        writer.writeUsize(0);
    }
    writer.writeU64(prepared.replacement_authority_seal.generation);
    writer.writeBytes(&prepared.replacement_authority_seal.digest);
    return writer.finish();
}

fn sameSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return @intFromPtr(a.?.ptr) == @intFromPtr(b.?.ptr) and a.?.len == b.?.len;
}

fn canonicalAppendReplacement(prepared: *const PreparedRxAppend) ?[]u8 {
    if (@intFromPtr(prepared.allocator.ptr) != prepared.allocator_ptr_addr or
        @intFromPtr(prepared.allocator.vtable) != prepared.allocator_vtable_addr)
        return null;
    if (!std.mem.eql(u8, &prepared.cleanup_digest, &appendCleanupDigest(prepared)))
        return null;
    if (sameSlice(prepared.replacement, prepared.cleanup_replacement)) {
        const replacement = prepared.replacement orelse return if (prepared.replacement_len == 0)
            null
        else
            null;
        if (@intFromPtr(replacement.ptr) == prepared.replacement_addr and
            replacement.len == prepared.replacement_len)
            return replacement;
    }
    return null;
}

fn appendOutputPristine(out: *const PreparedRxAppend) bool {
    return out.saved_self_addr == 0 and out.state_addr == 0 and out.parser_addr == 0 and
        out.replacement == null and out.cleanup_replacement == null and
        out.replacement_addr == 0 and out.replacement_len == 0 and
        out.lifecycle == .empty and out.completion == .pristine;
}

pub fn preparedRxAppendPristine(out: *const PreparedRxAppend) bool {
    return appendOutputPristine(out) and
        out.expected_start == 0 and
        out.bytes_addr == 0 and
        out.bytes_len == 0 and
        std.mem.allEqual(u8, &out.bytes_digest, 0) and
        std.meta.eql(out.source_seal, ParserAuthoritySeal{}) and
        std.mem.allEqual(u8, &out.unread_digest, 0) and
        out.allocator_ptr_addr == 0 and
        out.allocator_vtable_addr == 0 and
        out.allocator.ptr == pristine_rx_append_allocator.ptr and
        out.allocator.vtable == pristine_rx_append_allocator.vtable and
        out.final_items_len == 0 and
        out.resident_cap == 0 and
        out.replacement_guard == null and
        std.meta.eql(out.replacement_authority_seal, ReplacementAuthoritySeal{}) and
        std.mem.allEqual(u8, &out.cleanup_digest, 0) and
        out.quarantine_outcome_tag == .allocation_quarantined and
        out.quarantine_phase == .allocation and
        out.quarantine_upper_bound == 0 and
        std.mem.allEqual(u8, &out.digest, 0);
}

fn markOrdinaryPreparedAdmitFinished(
    prepared: *PreparedRxAppend,
    lifecycle: PreparedAppendLifecycle,
) void {
    std.debug.assert(lifecycle == .committed or lifecycle == .aborted);
    prepared.* = .{
        .saved_self_addr = @intFromPtr(prepared),
        .lifecycle = lifecycle,
        .completion = .ordinary_finished,
    };
    prepared.digest = appendDigest(prepared);
}

fn markPreparedAdmitTransient(
    prepared: *PreparedRxAppend,
    lifecycle: PreparedAppendLifecycle,
) void {
    prepared.* = .{
        .saved_self_addr = @intFromPtr(prepared),
        .lifecycle = lifecycle,
        .completion = .active,
    };
    prepared.digest = appendDigest(prepared);
}

fn markQuarantinedPreparedAdmitPending(
    prepared: *PreparedRxAppend,
    lifecycle: PreparedAppendLifecycle,
    outcome_tag: GuardedQuarantineOutcomeTag,
    quarantine: GuardedAdmitQuarantine,
) void {
    std.debug.assert(
        lifecycle == .aborted or lifecycle == .committed or
            lifecycle == .quarantined,
    );
    prepared.* = .{
        .saved_self_addr = @intFromPtr(prepared),
        .lifecycle = lifecycle,
        .completion = .quarantine_pending,
        .quarantine_outcome_tag = outcome_tag,
        .quarantine_phase = quarantine.phase,
        .quarantine_upper_bound = quarantine.quarantined_bytes_upper_bound,
    };
    prepared.digest = appendDigest(prepared);
}

fn completionTombstoneValid(
    prepared: *const PreparedRxAppend,
    completion: PreparedAdmitCompletion,
) bool {
    if (prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.completion != completion or
        prepared.state_addr != 0 or prepared.parser_addr != 0 or
        prepared.expected_start != 0 or prepared.bytes_addr != 0 or
        prepared.bytes_len != 0 or
        !std.mem.allEqual(u8, &prepared.bytes_digest, 0) or
        !std.meta.eql(prepared.source_seal, ParserAuthoritySeal{}) or
        !std.mem.allEqual(u8, &prepared.unread_digest, 0) or
        prepared.allocator.ptr != pristine_rx_append_allocator.ptr or
        prepared.allocator.vtable != pristine_rx_append_allocator.vtable or
        prepared.allocator_ptr_addr != 0 or
        prepared.allocator_vtable_addr != 0 or
        prepared.replacement_addr != 0 or prepared.replacement_len != 0 or
        prepared.final_items_len != 0 or prepared.resident_cap != 0 or
        prepared.replacement != null or prepared.cleanup_replacement != null or
        prepared.replacement_guard != null or
        !std.meta.eql(
            prepared.replacement_authority_seal,
            ReplacementAuthoritySeal{},
        ) or
        !std.mem.allEqual(u8, &prepared.cleanup_digest, 0))
        return false;
    return std.mem.eql(u8, &prepared.digest, &appendDigest(prepared));
}

pub fn resetFinishedPreparedAdmit(prepared: *PreparedRxAppend) bool {
    if (!completionTombstoneValid(prepared, .ordinary_finished) or
        (prepared.lifecycle != .committed and prepared.lifecycle != .aborted) or
        prepared.quarantine_outcome_tag != .allocation_quarantined or
        prepared.quarantine_phase != .allocation or
        prepared.quarantine_upper_bound != 0)
        return false;
    prepared.* = .{};
    return true;
}

pub const TerminalizedPreparedAdmit = struct {
    outcome_tag: GuardedQuarantineOutcomeTag,
    quarantine: GuardedAdmitQuarantine,
};

pub const TerminalizePreparedAdmitResult = union(enum) {
    pristine,
    ordinary_finished,
    quarantine_pending: TerminalizedPreparedAdmit,
    quarantine_accounted: TerminalizedPreparedAdmit,
    terminalized: TerminalizedPreparedAdmit,
    unrecoverable,
};

fn terminalizedPreparedAdmit(
    prepared: *const PreparedRxAppend,
) TerminalizedPreparedAdmit {
    return .{
        .outcome_tag = prepared.quarantine_outcome_tag,
        .quarantine = .{
            .phase = prepared.quarantine_phase,
            .quarantined_bytes_upper_bound = prepared.quarantine_upper_bound,
        },
    };
}

/// Closes a guarded prepared-admit token without invoking allocator or guard callbacks.
/// Replacement ownership is deliberately quarantined rather than freed.
pub fn terminalizePreparedAdmitNoCallback(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
) TerminalizePreparedAdmitResult {
    const state_addr = @intFromPtr(state);
    const parser_addr = @intFromPtr(parser);
    const prepared_addr = @intFromPtr(prepared);
    if (rangesOverlap(state_addr, @sizeOf(State), parser_addr, @sizeOf(framing.FrameParser)) or
        rangesOverlap(state_addr, @sizeOf(State), prepared_addr, @sizeOf(PreparedRxAppend)) or
        rangesOverlap(
            parser_addr,
            @sizeOf(framing.FrameParser),
            prepared_addr,
            @sizeOf(PreparedRxAppend),
        ))
        return .unrecoverable;

    if (preparedRxAppendPristine(prepared)) return .pristine;
    if (completionTombstoneValid(prepared, .ordinary_finished) and
        (prepared.lifecycle == .committed or prepared.lifecycle == .aborted) and
        prepared.quarantine_outcome_tag == .allocation_quarantined and
        prepared.quarantine_phase == .allocation and
        prepared.quarantine_upper_bound == 0)
        return .ordinary_finished;
    if (completionTombstoneValid(prepared, .quarantine_pending) and
        (prepared.lifecycle == .aborted or
            prepared.lifecycle == .committed or
            prepared.lifecycle == .quarantined) and
        prepared.quarantine_upper_bound <= max_guarded_admit_quarantine_bytes)
        return .{ .quarantine_pending = terminalizedPreparedAdmit(prepared) };
    if (completionTombstoneValid(prepared, .quarantine_accounted) and
        (prepared.lifecycle == .aborted or
            prepared.lifecycle == .committed or
            prepared.lifecycle == .quarantined) and
        prepared.quarantine_upper_bound <= max_guarded_admit_quarantine_bytes)
        return .{ .quarantine_accounted = terminalizedPreparedAdmit(prepared) };

    if (!appendPreparedTokenAuthenticated(state, parser, prepared))
        return .unrecoverable;
    const hard_cap = protocol.max_binary_chunk + protocol.header_size;
    if (prepared.resident_cap == 0 or prepared.resident_cap > hard_cap)
        return .unrecoverable;
    const has_replacement_evidence = prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_addr != 0 or
        prepared.replacement_len != 0 or
        prepared.final_items_len != 0 or
        prepared.replacement_guard != null or
        !std.meta.eql(
            prepared.replacement_authority_seal,
            ReplacementAuthoritySeal{},
        );
    const upper_bound: usize = if (has_replacement_evidence) blk: {
        if (!guardedPreparedCleanupAuthority(prepared))
            return .unrecoverable;
        break :blk guardedQuarantineUpperBound(prepared);
    } else blk: {
        if (prepared.replacement != null or
            prepared.cleanup_replacement != null or
            prepared.replacement_addr != 0 or prepared.replacement_len != 0 or
            prepared.final_items_len != 0 or
            prepared.replacement_guard != null or
            !std.meta.eql(
                prepared.replacement_authority_seal,
                ReplacementAuthoritySeal{},
            ) or
            @intFromPtr(prepared.allocator.ptr) !=
                prepared.allocator_ptr_addr or
            @intFromPtr(prepared.allocator.vtable) !=
                prepared.allocator_vtable_addr or
            !std.mem.eql(
                u8,
                &prepared.cleanup_digest,
                &appendCleanupDigest(prepared),
            ))
            return .unrecoverable;
        break :blk 0;
    };
    const closed = TerminalizedPreparedAdmit{
        .outcome_tag = .allocation_quarantined,
        .quarantine = .{
            .phase = .abort_cleanup,
            .quarantined_bytes_upper_bound = upper_bound,
        },
    };
    markQuarantinedPreparedAdmitPending(
        prepared,
        .quarantined,
        closed.outcome_tag,
        closed.quarantine,
    );
    state.rx_provenance = .{ .lifecycle = .terminal };
    state.rx_operation_busy = false;
    return .{ .terminalized = closed };
}

pub const GuardedQuarantineReceiptLifecycle = enum {
    empty,
    accounted,
    consumed,
};

pub const GuardedQuarantineAccountingReceipt = struct {
    saved_self_addr: usize = 0,
    prepared_addr: usize = 0,
    outcome_tag: GuardedQuarantineOutcomeTag = .allocation_quarantined,
    phase: GuardedAdmitQuarantinePhase = .allocation,
    quarantined_bytes_upper_bound: usize = 0,
    latch_generation: u64 = 0,
    lifecycle: GuardedQuarantineReceiptLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub fn guardedQuarantineReceiptPristine(
    receipt: *const GuardedQuarantineAccountingReceipt,
) bool {
    return receipt.saved_self_addr == 0 and receipt.prepared_addr == 0 and
        receipt.outcome_tag == .allocation_quarantined and
        receipt.phase == .allocation and
        receipt.quarantined_bytes_upper_bound == 0 and
        receipt.latch_generation == 0 and receipt.lifecycle == .empty and
        std.mem.allEqual(u8, &receipt.digest, 0);
}

fn guardedQuarantineReceiptDigest(
    receipt: *const GuardedQuarantineAccountingReceipt,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARUGQR1");
    writer.writeUsize(receipt.saved_self_addr);
    writer.writeUsize(receipt.prepared_addr);
    writer.writeU8(@intFromEnum(receipt.outcome_tag));
    writer.writeU8(@intFromEnum(receipt.phase));
    writer.writeUsize(receipt.quarantined_bytes_upper_bound);
    writer.writeU64(receipt.latch_generation);
    writer.writeU8(@intFromEnum(receipt.lifecycle));
    return writer.finish();
}

fn quarantineTombstoneMatches(
    prepared: *const PreparedRxAppend,
    completion: PreparedAdmitCompletion,
    outcome_tag: GuardedQuarantineOutcomeTag,
    quarantine: GuardedAdmitQuarantine,
) bool {
    return completionTombstoneValid(prepared, completion) and
        (prepared.lifecycle == .aborted or
            prepared.lifecycle == .committed or
            prepared.lifecycle == .quarantined) and
        prepared.quarantine_outcome_tag == outcome_tag and
        prepared.quarantine_phase == quarantine.phase and
        prepared.quarantine_upper_bound ==
            quarantine.quarantined_bytes_upper_bound;
}

/// Validates the pending token, commits the shared event generation, then publishes its receipt.
pub fn markQuarantinedPreparedAdmitAccounted(
    prepared: *PreparedRxAppend,
    outcome_tag: GuardedQuarantineOutcomeTag,
    quarantine: GuardedAdmitQuarantine,
    event_count: *std.atomic.Value(u64),
    out: *GuardedQuarantineAccountingReceipt,
) bool {
    if (!quarantineTombstoneMatches(
        prepared,
        .quarantine_pending,
        outcome_tag,
        quarantine,
    ) or out.saved_self_addr != 0 or out.prepared_addr != 0 or
        out.lifecycle != .empty or !std.mem.allEqual(u8, &out.digest, 0) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(GuardedQuarantineAccountingReceipt),
            @intFromPtr(prepared),
            @sizeOf(PreparedRxAppend),
        ))
        return false;
    const latch_generation =
        checked_event_counter.increment(event_count) orelse return false;
    prepared.completion = .quarantine_accounted;
    prepared.digest = appendDigest(prepared);
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .prepared_addr = @intFromPtr(prepared),
        .outcome_tag = outcome_tag,
        .phase = quarantine.phase,
        .quarantined_bytes_upper_bound = quarantine.quarantined_bytes_upper_bound,
        .latch_generation = latch_generation,
        .lifecycle = .accounted,
    };
    out.digest = guardedQuarantineReceiptDigest(out);
    return true;
}

pub fn finalizeQuarantinedPreparedAdmit(
    prepared: *PreparedRxAppend,
    outcome_tag: GuardedQuarantineOutcomeTag,
    quarantine: GuardedAdmitQuarantine,
    receipt: *GuardedQuarantineAccountingReceipt,
) bool {
    if (!quarantineTombstoneMatches(
        prepared,
        .quarantine_accounted,
        outcome_tag,
        quarantine,
    ) or receipt.saved_self_addr != @intFromPtr(receipt) or
        receipt.prepared_addr != @intFromPtr(prepared) or
        receipt.outcome_tag != outcome_tag or
        receipt.phase != quarantine.phase or
        receipt.quarantined_bytes_upper_bound !=
            quarantine.quarantined_bytes_upper_bound or
        receipt.latch_generation == 0 or receipt.lifecycle != .accounted or
        !std.mem.eql(
            u8,
            &receipt.digest,
            &guardedQuarantineReceiptDigest(receipt),
        ) or rangesOverlap(
        @intFromPtr(receipt),
        @sizeOf(GuardedQuarantineAccountingReceipt),
        @intFromPtr(prepared),
        @sizeOf(PreparedRxAppend),
    ))
        return false;
    receipt.lifecycle = .consumed;
    receipt.digest = guardedQuarantineReceiptDigest(receipt);
    prepared.* = .{};
    return true;
}

fn parseCleanupDigest(scratch: *const RxParseScratch) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-parse-cleanup.v1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeUsize(scratch.allocator_ptr_addr);
    writer.writeUsize(scratch.allocator_vtable_addr);
    writer.writeUsize(scratch.payload_addr);
    writer.writeUsize(scratch.payload_len);
    return writer.finish();
}

fn parseCleanupValid(scratch: *const RxParseScratch) bool {
    return @intFromPtr(scratch.allocator.ptr) == scratch.allocator_ptr_addr and
        @intFromPtr(scratch.allocator.vtable) == scratch.allocator_vtable_addr and
        std.mem.eql(u8, &scratch.cleanup_digest, &parseCleanupDigest(scratch));
}

fn canonicalParsePayload(scratch: *const RxParseScratch) ?[]u8 {
    if (!parseCleanupValid(scratch) or
        !sameSlice(scratch.payload, scratch.cleanup_payload))
        return null;
    const payload = scratch.payload orelse return null;
    if (@intFromPtr(payload.ptr) != scratch.payload_addr or payload.len != scratch.payload_len)
        return null;
    return payload;
}

fn parseScratchPristine(scratch: *const RxParseScratch) bool {
    return scratch.saved_self_addr == 0 and scratch.parser_addr == 0 and
        scratch.payload == null and scratch.cleanup_payload == null and
        scratch.payload_addr == 0 and scratch.payload_len == 0 and
        scratch.lifecycle == .empty;
}

pub fn rxParseScratchPristine(scratch: *const RxParseScratch) bool {
    return parseScratchPristine(scratch);
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn parserSealDigest(seal: *const ParserAuthoritySeal) owner_seal.Digest {
    var writer = owner_seal.Writer.init(parser_seal_domain);
    writer.writeU16(parser_seal_version);
    writer.writeUsize(seal.seal_addr);
    writer.writeUsize(seal.parser_addr);
    writer.writeU64(seal.identity.attach_instance_id);
    writer.writeUsize(seal.identity.destination_slot_addr);
    writer.writeUsize(seal.destination_slot_len);
    writer.writeUsize(seal.allocator_ptr_addr);
    writer.writeUsize(seal.allocator_vtable_addr);
    writer.writeU16(seal.expected_major);
    writer.writeUsize(seal.backing_addr);
    writer.writeUsize(seal.items_len);
    writer.writeUsize(seal.capacity);
    writer.writeUsize(seal.head);
    writer.writeU64(seal.buffer_start_absolute);
    writer.writeU64(seal.rx_absolute_next);
    writer.writeUsize(seal.resident_cap);
    writer.writeU64(seal.generation);
    return writer.finish();
}

fn parserDescriptorValid(
    parser: *const framing.FrameParser,
    seal_addr: usize,
) bool {
    if (parser.head > parser.buf.items.len or parser.buf.items.len > parser.buf.capacity)
        return false;
    const backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (parser.buf.capacity == 0 and parser.buf.items.len != 0) return false;
    _ = std.math.add(usize, backing_addr, parser.buf.capacity) catch return false;
    const parser_addr = @intFromPtr(parser);
    const parser_end = std.math.add(usize, parser_addr, @sizeOf(framing.FrameParser)) catch
        return false;
    const seal_end = std.math.add(usize, seal_addr, @sizeOf(ParserAuthoritySeal)) catch
        return false;
    const backing_end = std.math.add(usize, backing_addr, parser.buf.capacity) catch return false;
    if (parser.buf.capacity != 0 and
        (parser_addr < backing_end and backing_addr < parser_end or
            seal_addr < backing_end and backing_addr < seal_end))
        return false;
    return true;
}

pub fn parserAuthoritySealStructurallyValid(
    seal: *const ParserAuthoritySeal,
) bool {
    if (!std.mem.eql(u8, &seal.domain, parser_seal_domain) or
        seal.version != parser_seal_version or seal.seal_addr == 0 or
        seal.parser_addr == 0 or seal.identity.attach_instance_id == 0 or
        seal.identity.destination_slot_addr == 0 or
        seal.destination_slot_len == 0 or
        // `Allocator.ptr` is opaque and may legitimately be address zero when the vtable needs
        // no context (the process GPA does this in optimized builds). Its exact value is still
        // sealed and compared with the live parser; only the callable vtable must be non-null.
        seal.allocator_vtable_addr == 0 or seal.expected_major == 0 or
        seal.items_len > seal.capacity or seal.head > seal.items_len or
        seal.buffer_start_absolute > seal.rx_absolute_next or
        seal.resident_cap == 0 or seal.generation == 0)
        return false;
    if (seal.capacity == 0) {
        if (seal.backing_addr != 0 or seal.items_len != 0 or seal.head != 0)
            return false;
    } else {
        if (seal.backing_addr == 0) return false;
        _ = std.math.add(
            usize,
            seal.backing_addr,
            seal.capacity,
        ) catch return false;
    }
    return std.mem.eql(u8, &seal.digest, &parserSealDigest(seal));
}

fn makeParserSeal(
    parser: *const framing.FrameParser,
    provenance: *const RxProvenance,
    generation: u64,
) ?ParserAuthoritySeal {
    const identity = provenance.identity orelse return null;
    const seal_addr = @intFromPtr(&provenance.parser_seal);
    if (!parserDescriptorValid(parser, seal_addr)) return null;
    const backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(
        backing_addr,
        parser.buf.capacity,
        @intFromPtr(provenance),
        @sizeOf(RxProvenance),
    ) or rangesOverlap(
        backing_addr,
        parser.buf.capacity,
        identity.destination_slot_addr,
        provenance.destination_slot_len,
    )) return null;
    var seal: ParserAuthoritySeal = .{
        .domain = parser_seal_domain.*,
        .version = parser_seal_version,
        .seal_addr = seal_addr,
        .parser_addr = @intFromPtr(parser),
        .identity = identity,
        .destination_slot_len = provenance.destination_slot_len,
        .allocator_ptr_addr = @intFromPtr(parser.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(parser.allocator.vtable),
        .expected_major = parser.expected_major,
        .backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
        .items_len = parser.buf.items.len,
        .capacity = parser.buf.capacity,
        .head = parser.head,
        .buffer_start_absolute = provenance.buffer_start_absolute,
        .rx_absolute_next = provenance.rx_absolute_next,
        .resident_cap = provenance.resident_cap,
        .generation = generation,
    };
    seal.digest = parserSealDigest(&seal);
    return seal;
}

pub fn parserSealValid(
    state: *const State,
    parser: *const framing.FrameParser,
) bool {
    const provenance = &state.rx_provenance;
    if (provenance.lifecycle != .bound or provenance.identity == null) return false;
    const seal = &provenance.parser_seal;
    if (!std.mem.eql(u8, &seal.domain, parser_seal_domain) or
        seal.version != parser_seal_version or
        seal.seal_addr != @intFromPtr(seal) or
        seal.parser_addr != @intFromPtr(parser) or
        !std.meta.eql(seal.identity, provenance.identity.?) or
        seal.destination_slot_len != provenance.destination_slot_len or
        seal.allocator_ptr_addr != @intFromPtr(parser.allocator.ptr) or
        seal.allocator_vtable_addr != @intFromPtr(parser.allocator.vtable) or
        seal.expected_major != parser.expected_major or
        seal.items_len != parser.buf.items.len or
        seal.capacity != parser.buf.capacity or
        seal.head != parser.head or
        seal.backing_addr !=
            (if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr)) or
        seal.buffer_start_absolute != provenance.buffer_start_absolute or
        seal.rx_absolute_next != provenance.rx_absolute_next or
        seal.resident_cap != provenance.resident_cap or
        seal.resident_cap == 0 or
        seal.generation == 0 or
        !parserDescriptorValid(parser, @intFromPtr(seal)) or
        rangesOverlap(
            seal.backing_addr,
            seal.capacity,
            @intFromPtr(state),
            @sizeOf(State),
        ) or
        rangesOverlap(
            seal.backing_addr,
            seal.capacity,
            seal.identity.destination_slot_addr,
            seal.destination_slot_len,
        ))
        return false;
    return std.mem.eql(u8, &seal.digest, &parserSealDigest(seal));
}

fn resealParserAuthority(state: *State, parser: *const framing.FrameParser) bool {
    const generation = std.math.add(
        u64,
        state.rx_provenance.parser_seal.generation,
        1,
    ) catch return false;
    state.rx_provenance.parser_seal =
        makeParserSeal(parser, &state.rx_provenance, generation) orelse return false;
    return parserSealValid(state, parser);
}

pub fn maxReadable(
    state: *const State,
    parser: *const framing.FrameParser,
    resident_cap: usize,
    turn_rx_remaining: usize,
) MaxReadableResult {
    if (state.rx_operation_busy or !parserSealValid(state, parser)) return .invalid;
    const provenance = state.rx_provenance;
    if (resident_cap != provenance.resident_cap) return .invalid;
    if (provenance.buffer_start_absolute > provenance.rx_absolute_next)
        return .invalid;
    const buffered = std.math.sub(
        usize,
        parser.buf.items.len,
        parser.head,
    ) catch return .invalid;
    const absolute_buffered = std.math.sub(
        u64,
        provenance.rx_absolute_next,
        provenance.buffer_start_absolute,
    ) catch return .invalid;
    if (absolute_buffered != buffered) return .invalid;
    if (provenance.rx_absolute_next == std.math.maxInt(u64))
        return .counter_exhausted;
    const resident_remaining = std.math.sub(usize, resident_cap, buffered) catch
        return .resident_exhausted;
    if (resident_remaining == 0) return .resident_exhausted;
    if (turn_rx_remaining == 0) return .turn_exhausted;
    const counter_remaining_u64 = std.math.maxInt(u64) - provenance.rx_absolute_next;
    const counter_remaining: usize = if (counter_remaining_u64 > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(counter_remaining_u64);
    return .{ .bytes = positiveReadableAllowance(
        resident_remaining,
        turn_rx_remaining,
        counter_remaining,
    ) };
}

pub fn isFresh(
    range: RxRange,
    barrier: RxWatermark,
    current_identity: RxIdentity,
    rx_absolute_next: u64,
) Freshness {
    if (!std.meta.eql(range.identity, current_identity) or
        !std.meta.eql(barrier.identity, current_identity) or
        range.start_absolute >= range.end_absolute or
        range.end_absolute > rx_absolute_next or
        barrier.absolute > rx_absolute_next)
        return .invalid;
    return if (range.start_absolute >= barrier.absolute) .fresh else .stale;
}

pub const RxParserReadiness = enum {
    empty,
    incomplete,
    complete_or_error,
};

/// Classify whether the sealed parser can make progress without consuming bytes or allocating.
///
/// Protocol-invalid complete headers are ready because the next parser outcome can terminate the
/// connection immediately; invariant drift remains a typed error instead of scheduler readiness.
pub fn parserReadiness(
    state: *const State,
    parser: *const framing.FrameParser,
) RxParseError!RxParserReadiness {
    if (state.rx_operation_busy) return error.InvalidState;
    if (!parserSealValid(state, parser)) return error.InvalidSeal;
    const provenance = state.rx_provenance;
    const buffered = std.math.sub(
        usize,
        parser.buf.items.len,
        parser.head,
    ) catch return error.InvalidDescriptor;
    const absolute_buffered = std.math.sub(
        u64,
        provenance.rx_absolute_next,
        provenance.buffer_start_absolute,
    ) catch return error.ArithmeticOverflow;
    if (absolute_buffered != buffered) return error.InvalidDescriptor;
    if (buffered == 0) return .empty;
    if (buffered < protocol.header_size) return .incomplete;
    const pending = parser.buf.items[parser.head..];
    const header_bytes: *const [protocol.header_size]u8 = @ptrCast(pending.ptr);
    const header = protocol.Header.decode(header_bytes) catch
        return .complete_or_error;
    if (header.major != parser.expected_major or
        header.payload_len > protocol.maxPayloadForKind(header.kind))
        return .complete_or_error;
    const total = std.math.add(
        usize,
        protocol.header_size,
        @as(usize, header.payload_len),
    ) catch return .complete_or_error;
    return if (pending.len < total) .incomplete else .complete_or_error;
}

fn consumeValidated(
    state: *State,
    parser: *framing.FrameParser,
    count: usize,
    end_absolute: u64,
) void {
    if (!parserSealValid(state, parser) or
        state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
        @panic("RX consume entered without reseal capacity");
    const buffered = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        @panic("preflighted RX consume descriptor drifted");
    if (count > buffered) @panic("RX consume exceeds buffered bytes");
    parser.head += count;
    if (parser.head == parser.buf.items.len) {
        parser.buf.clearRetainingCapacity();
        parser.head = 0;
    }
    state.rx_provenance.buffer_start_absolute = end_absolute;
    if (!resealParserAuthority(state, parser)) @panic("preflighted RX consume reseal failed");
}

pub fn nextOutcomeWithRange(
    state: *State,
    parser: *framing.FrameParser,
    scratch: *RxParseScratch,
) RxParseError!ExternalRxOutcome {
    return nextOutcomeWithRangeGuarded(state, parser, scratch, null);
}

pub fn nextOutcomeWithRangeGuarded(
    state: *State,
    parser: *framing.FrameParser,
    scratch: *RxParseScratch,
    allocation_guard: ?*const PayloadAllocationGuard,
) RxParseError!ExternalRxOutcome {
    if (state.rx_operation_busy) return error.InvalidState;
    if (!parserSealValid(state, parser)) return error.InvalidSeal;
    state.rx_operation_busy = true;
    defer state.rx_operation_busy = false;
    const backing_addr =
        if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(@intFromPtr(scratch), @sizeOf(RxParseScratch), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            @intFromPtr(scratch),
            @sizeOf(RxParseScratch),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            @intFromPtr(scratch),
            @sizeOf(RxParseScratch),
            backing_addr,
            parser.buf.capacity,
        ))
        return error.InvalidDescriptor;
    if (!parseScratchPristine(scratch))
        return error.InvalidState;
    const provenance = state.rx_provenance;
    const identity = provenance.identity orelse return error.InvalidState;
    const buffered = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        return error.InvalidDescriptor;
    const absolute_buffered = std.math.sub(
        u64,
        provenance.rx_absolute_next,
        provenance.buffer_start_absolute,
    ) catch return error.ArithmeticOverflow;
    if (absolute_buffered != buffered) return error.InvalidDescriptor;
    if (buffered < protocol.header_size) return .incomplete;
    const pending = parser.buf.items[parser.head..];
    const header_bytes: *const [protocol.header_size]u8 = @ptrCast(pending.ptr);
    const header = protocol.Header.decode(header_bytes) catch return error.Protocol;
    if (header.major != parser.expected_major) return error.Protocol;
    if (header.payload_len > protocol.maxPayloadForKind(header.kind))
        return error.Protocol;
    const total = std.math.add(
        usize,
        protocol.header_size,
        @as(usize, header.payload_len),
    ) catch return error.ArithmeticOverflow;
    if (pending.len < total) return .incomplete;
    const frame_end = std.math.add(
        u64,
        provenance.buffer_start_absolute,
        @as(u64, @intCast(total)),
    ) catch return error.ArithmeticOverflow;
    if (frame_end > provenance.rx_absolute_next) return error.InvalidDescriptor;
    if (state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
        return error.ArithmeticOverflow;
    const range = RxRange{
        .identity = identity,
        .start_absolute = provenance.buffer_start_absolute,
        .end_absolute = frame_end,
    };
    const understood = header.kind.isKnown() and
        !protocol.Flags.hasUnknownBits(header.flags);
    if (!understood) {
        if (!protocol.Flags.isOptional(header.flags)) return error.Protocol;
        consumeValidated(state, parser, total, frame_end);
        return .{ .skipped = range };
    }

    const source_seal = state.rx_provenance.parser_seal;
    const frame_digest = bytesDigest(pending[0..total]);
    const allocation_owner = parser.allocator;
    const payload_len: usize = @intCast(header.payload_len);
    const raw_payload = if (payload_len == 0)
        null
    else
        allocation_owner.rawAlloc(
            payload_len,
            .of(u8),
            @returnAddress(),
        ) orelse return error.OutOfMemory;
    const payload_addr = if (raw_payload) |bytes| @intFromPtr(bytes) else 0;
    _ = std.math.add(usize, payload_addr, payload_len) catch
        return error.AllocationQuarantined;
    if (payload_len != 0 and
        (rangesOverlap(payload_addr, payload_len, @intFromPtr(state), @sizeOf(State)) or
            rangesOverlap(
                payload_addr,
                payload_len,
                @intFromPtr(parser),
                @sizeOf(framing.FrameParser),
            ) or
            rangesOverlap(
                payload_addr,
                payload_len,
                @intFromPtr(scratch),
                @sizeOf(RxParseScratch),
            ) or
            rangesOverlap(payload_addr, payload_len, backing_addr, parser.buf.capacity)))
        return error.AllocationQuarantined;
    if (payload_len != 0) {
        if (allocation_guard) |guard| {
            if (guard.check(
                guard.context,
                payload_addr,
                payload_len,
            ) != .accepted)
                return error.AllocationQuarantined;
        }
    }
    const payload: []u8 = if (raw_payload) |bytes|
        bytes[0..payload_len]
    else
        &.{};
    errdefer if (raw_payload) |bytes| allocation_owner.rawFree(
        bytes[0..payload_len],
        .of(u8),
        @returnAddress(),
    );
    if (!parserSealValid(state, parser) or
        !std.meta.eql(source_seal, state.rx_provenance.parser_seal) or
        !parseScratchPristine(scratch))
        return error.InvalidSeal;
    const current_pending = parser.buf.items[parser.head..];
    if (current_pending.len < total or
        !std.mem.eql(u8, &frame_digest, &bytesDigest(current_pending[0..total])))
        return error.InvalidSeal;
    if (payload.len != payload_len or
        (payload.len != 0 and payload_addr == 0))
        return error.InvalidDescriptor;
    scratch.* = .{
        .saved_self_addr = @intFromPtr(scratch),
        .parser_addr = @intFromPtr(parser),
        .source_seal = source_seal,
        .frame_start_absolute = range.start_absolute,
        .frame_end_absolute = range.end_absolute,
        .header = header,
        .frame_digest = frame_digest,
        .allocator = allocation_owner,
        .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
        .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
        .payload_addr = payload_addr,
        .payload_len = payload.len,
        .payload = payload,
        .cleanup_payload = payload,
        .lifecycle = .prepared,
    };
    scratch.cleanup_digest = parseCleanupDigest(scratch);
    @memcpy(payload, current_pending[protocol.header_size..total]);
    consumeValidated(state, parser, total, frame_end);
    scratch.payload = null;
    scratch.cleanup_payload = null;
    scratch.lifecycle = .committed;
    var result = ExternalRxFrame{
        .frame = .{ .header = header, .payload = payload },
        .range = range,
        .pair_seal = undefined,
    };
    result.pair_seal = externalRxFrameDigest(&result);
    return .{ .frame = result };
}

fn appendPreparedValid(
    state: *const State,
    parser: *const framing.FrameParser,
    bytes: []const u8,
    prepared: *const PreparedRxAppend,
) bool {
    if (prepared.lifecycle != .prepared or
        prepared.completion != .active or
        !state.rx_operation_busy or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state) or
        prepared.parser_addr != @intFromPtr(parser) or
        prepared.expected_start != state.rx_provenance.rx_absolute_next or
        prepared.bytes_addr != (if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr)) or
        prepared.bytes_len != bytes.len or
        state.rx_provenance.parser_seal.generation == std.math.maxInt(u64) or
        !std.meta.eql(prepared.source_seal, state.rx_provenance.parser_seal) or
        !parserSealValid(state, parser) or
        !std.mem.eql(u8, &prepared.digest, &appendDigest(prepared)))
        return false;
    if (prepared.replacement != null) {
        if (!std.mem.eql(u8, &prepared.bytes_digest, &bytesDigest(bytes))) return false;
        const unread = parser.buf.items[parser.head..];
        if (!std.mem.eql(u8, &prepared.unread_digest, &bytesDigest(unread))) return false;
        const expected_len = std.math.add(usize, unread.len, bytes.len) catch return false;
        const replacement = canonicalAppendReplacement(prepared) orelse return false;
        return prepared.final_items_len == expected_len and
            replacement.len >= expected_len;
    }
    const next_items_len = std.math.add(usize, parser.buf.items.len, bytes.len) catch
        return false;
    return prepared.cleanup_replacement == null and
        prepared.replacement_addr == 0 and prepared.replacement_len == 0 and
        std.mem.eql(u8, &prepared.bytes_digest, &([_]u8{0} ** 32)) and
        std.mem.eql(u8, &prepared.unread_digest, &([_]u8{0} ** 32)) and
        next_items_len <= parser.buf.capacity;
}

fn appendPreparedTokenAuthenticated(
    state: *const State,
    parser: *const framing.FrameParser,
    prepared: *const PreparedRxAppend,
) bool {
    return state.rx_operation_busy and
        prepared.lifecycle == .prepared and
        prepared.completion == .active and
        prepared.saved_self_addr == @intFromPtr(prepared) and
        prepared.state_addr == @intFromPtr(state) and
        prepared.parser_addr == @intFromPtr(parser) and
        prepared.source_seal.generation != std.math.maxInt(u64) and
        std.mem.eql(u8, &prepared.digest, &appendDigest(prepared));
}

fn replacementSealValid(seal: ReplacementAuthoritySeal) bool {
    return seal.generation != 0 and !std.mem.allEqual(u8, &seal.digest, 0);
}

fn sameReplacementSeal(
    a: ReplacementAuthoritySeal,
    b: ReplacementAuthoritySeal,
) bool {
    return a.generation == b.generation and
        std.mem.eql(u8, &a.digest, &b.digest);
}

fn captureReplacementAuthority(
    guard: ReplacementAllocationGuard,
    phase: ReplacementGuardPhase,
    expected: ?ReplacementAuthoritySeal,
    candidate: ?ReplacementCandidate,
) ?ReplacementAuthoritySeal {
    const result = guard.check(guard.context, phase, expected, candidate);
    const seal = switch (result) {
        .seal => |seal| seal,
        else => return null,
    };
    if (!replacementSealValid(seal)) return null;
    if (expected) |prior| {
        if (!sameReplacementSeal(prior, seal)) return null;
    }
    return seal;
}

fn validateReplacementCandidate(
    guard: ReplacementAllocationGuard,
    phase: ReplacementGuardPhase,
    expected: ReplacementAuthoritySeal,
    candidate: ReplacementCandidate,
) bool {
    const result = guard.check(guard.context, phase, expected, candidate);
    const seal = switch (result) {
        .accepted => |seal| seal,
        else => return false,
    };
    return replacementSealValid(seal) and sameReplacementSeal(expected, seal);
}

fn replacementLocalAuthorityDigest(
    state: *const State,
    parser: *const framing.FrameParser,
    bytes: []const u8,
    resident_cap: usize,
    out: *const PreparedRxAppend,
    guard: ReplacementAllocationGuard,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-replacement-local.v1");
    writer.writeUsize(@intFromPtr(state));
    writer.writeUsize(@intFromPtr(parser));
    writer.writeUsize(@intFromPtr(out));
    writer.writeUsize(@intFromPtr(guard.context));
    writer.writeUsize(@intFromPtr(guard.check));
    GuardedSourceSnapshot.capture(state, parser).writeDigest(&writer);
    writer.writeUsize(resident_cap);
    writer.writeUsize(if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr));
    writer.writeUsize(bytes.len);
    writer.writeBytes(bytes);
    writer.writeUsize(@intFromBool(appendOutputPristine(out)));
    writer.writeUsize(@intFromBool(state.rx_operation_busy));
    return writer.finish();
}

fn replacementLocalAuthorityStillAddressable(
    state: *const State,
    parser: *const framing.FrameParser,
    bytes: []const u8,
    resident_cap: usize,
    out: *const PreparedRxAppend,
    guard: ReplacementAllocationGuard,
    source_seal: ParserAuthoritySeal,
    allocation_owner: std.mem.Allocator,
) bool {
    return state.rx_operation_busy and
        appendOutputPristine(out) and
        parserSealValid(state, parser) and
        std.meta.eql(source_seal, state.rx_provenance.parser_seal) and
        state.rx_provenance.resident_cap == resident_cap and
        @intFromPtr(parser.allocator.ptr) == @intFromPtr(allocation_owner.ptr) and
        @intFromPtr(parser.allocator.vtable) == @intFromPtr(allocation_owner.vtable) and
        (bytes.len == 0 or @intFromPtr(bytes.ptr) != 0) and
        @intFromPtr(guard.context) != 0 and
        @intFromPtr(guard.check) != 0;
}

fn quarantinePreparedAllocation(
    state: *State,
    out: *PreparedRxAppend,
    phase: GuardedAdmitQuarantinePhase,
    upper_bound: usize,
) GuardedAdmitQuarantine {
    const quarantine = GuardedAdmitQuarantine{
        .phase = phase,
        .quarantined_bytes_upper_bound = upper_bound,
    };
    markQuarantinedPreparedAdmitPending(
        out,
        .quarantined,
        .allocation_quarantined,
        quarantine,
    );
    state.rx_provenance = .{ .lifecycle = .terminal };
    state.rx_operation_busy = false;
    return quarantine;
}

pub fn prepareAdmitGuarded(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    expected_start: u64,
    resident_cap: usize,
    guard_ptr: *const ReplacementAllocationGuard,
    out: *PreparedRxAppend,
) GuardedAdmitPrepareOutcome {
    const fail = struct {
        fn result(reason: RxPrepareError) GuardedAdmitPrepareOutcome {
            return .{ .ordinary_failure = .{ .reason = reason } };
        }
    }.result;
    if (state.rx_operation_busy) return fail(error.InvalidState);
    if (!parserSealValid(state, parser)) return fail(error.InvalidSeal);
    if (resident_cap == 0 or
        resident_cap > protocol.max_binary_chunk + protocol.header_size)
        return fail(error.ResidentCap);
    if (state.rx_provenance.resident_cap != resident_cap)
        return fail(error.InvalidState);
    const parser_backing_addr =
        if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(@intFromPtr(out), @sizeOf(PreparedRxAppend), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            parser_backing_addr,
            parser.buf.capacity,
        ))
        return fail(error.InvalidDescriptor);
    if (expected_start != state.rx_provenance.rx_absolute_next)
        return fail(error.InvalidState);
    if (!appendOutputPristine(out)) return fail(error.InvalidState);
    const guard_ptr_addr = @intFromPtr(guard_ptr);
    if (rangesOverlap(guard_ptr_addr, @sizeOf(ReplacementAllocationGuard), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            guard_ptr_addr,
            @sizeOf(ReplacementAllocationGuard),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            guard_ptr_addr,
            @sizeOf(ReplacementAllocationGuard),
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
        ) or
        rangesOverlap(
            guard_ptr_addr,
            @sizeOf(ReplacementAllocationGuard),
            parser_backing_addr,
            parser.buf.capacity,
        ))
        return fail(error.InvalidDescriptor);
    const unread_len = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        return fail(error.InvalidDescriptor);
    const next_unread_len = std.math.add(usize, unread_len, bytes.len) catch
        return fail(error.ArithmeticOverflow);
    if (next_unread_len > resident_cap) return fail(error.ResidentCap);
    _ = std.math.add(u64, expected_start, @as(u64, @intCast(bytes.len))) catch
        return fail(error.ArithmeticOverflow);
    const bytes_addr = if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
    if (rangesOverlap(guard_ptr_addr, @sizeOf(ReplacementAllocationGuard), bytes_addr, bytes.len) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(parser), @sizeOf(framing.FrameParser)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(out), @sizeOf(PreparedRxAppend)) or
        rangesOverlap(bytes_addr, bytes.len, parser_backing_addr, parser.buf.capacity))
        return fail(error.InvalidDescriptor);
    const next_items_len = std.math.add(usize, parser.buf.items.len, bytes.len) catch
        return fail(error.ArithmeticOverflow);
    const source_seal = state.rx_provenance.parser_seal;
    const allocation_owner = parser.allocator;
    if (next_items_len <= parser.buf.capacity) {
        state.rx_operation_busy = true;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .state_addr = @intFromPtr(state),
            .parser_addr = @intFromPtr(parser),
            .expected_start = expected_start,
            .bytes_addr = bytes_addr,
            .bytes_len = bytes.len,
            .source_seal = source_seal,
            .allocator = allocation_owner,
            .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
            .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
            .resident_cap = resident_cap,
            .lifecycle = .prepared,
            .completion = .active,
        };
        out.cleanup_digest = appendCleanupDigest(out);
        out.digest = appendDigest(out);
        return .prepared;
    }

    const unread = parser.buf.items[parser.head..];
    const unread_digest = bytesDigest(unread);
    const read_digest = bytesDigest(bytes);
    const doubled_capacity = std.math.mul(
        usize,
        @max(parser.buf.capacity, 8),
        2,
    ) catch resident_cap;
    const target_capacity = @min(
        resident_cap,
        @max(next_unread_len, doubled_capacity),
    );
    const guard = guard_ptr.*;
    const guard_context_addr = @intFromPtr(guard.context);
    if (rangesOverlap(guard_context_addr, 1, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(guard_context_addr, 1, @intFromPtr(parser), @sizeOf(framing.FrameParser)) or
        rangesOverlap(guard_context_addr, 1, @intFromPtr(out), @sizeOf(PreparedRxAppend)) or
        rangesOverlap(guard_context_addr, 1, bytes_addr, bytes.len) or
        rangesOverlap(guard_context_addr, 1, parser_backing_addr, parser.buf.capacity))
        return fail(error.InvalidDescriptor);
    state.rx_operation_busy = true;
    const local_before = replacementLocalAuthorityDigest(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
    );
    const authority_before = captureReplacementAuthority(
        guard,
        .capture_before_allocate,
        null,
        null,
    ) orelse {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            0,
        ) };
    };
    if (!replacementLocalAuthorityStillAddressable(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
        source_seal,
        allocation_owner,
    )) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            0,
        ) };
    }
    const local_after_capture = replacementLocalAuthorityDigest(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
    );
    if (!std.mem.eql(u8, &local_before, &local_after_capture)) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            0,
        ) };
    }
    const raw_replacement = allocation_owner.rawAlloc(
        target_capacity,
        .of(u8),
        @returnAddress(),
    );
    const candidate = if (raw_replacement) |raw| ReplacementCandidate{
        .addr = @intFromPtr(raw),
        .len = target_capacity,
    } else null;
    const authority_after_allocate = captureReplacementAuthority(
        guard,
        .capture_after_allocate,
        authority_before,
        candidate,
    );
    if (!replacementLocalAuthorityStillAddressable(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
        source_seal,
        allocation_owner,
    )) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            if (candidate) |value| value.len else 0,
        ) };
    }
    const local_after_allocate = replacementLocalAuthorityDigest(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
    );
    if (authority_after_allocate == null or
        !std.mem.eql(u8, &local_before, &local_after_allocate))
    {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            if (candidate) |value| value.len else 0,
        ) };
    }
    if (raw_replacement == null) {
        state.rx_operation_busy = false;
        return fail(error.OutOfMemory);
    }
    const accepted_seal = authority_after_allocate.?;
    const replacement_addr = candidate.?.addr;
    _ = std.math.add(usize, replacement_addr, target_capacity) catch {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            target_capacity,
        ) };
    };
    if (rangesOverlap(replacement_addr, target_capacity, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            replacement_addr,
            target_capacity,
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            replacement_addr,
            target_capacity,
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
        ) or
        rangesOverlap(replacement_addr, target_capacity, bytes_addr, bytes.len) or
        rangesOverlap(
            replacement_addr,
            target_capacity,
            parser_backing_addr,
            parser.buf.capacity,
        ) or
        replacement_addr == @intFromPtr(guard.context) or
        !validateReplacementCandidate(
            guard,
            .validate_allocated,
            accepted_seal,
            candidate.?,
        ))
    {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            target_capacity,
        ) };
    }
    const final_seal = captureReplacementAuthority(
        guard,
        .capture_after_validate,
        accepted_seal,
        candidate,
    ) orelse {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            target_capacity,
        ) };
    };
    if (!replacementLocalAuthorityStillAddressable(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
        source_seal,
        allocation_owner,
    )) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            target_capacity,
        ) };
    }
    const local_after_validate = replacementLocalAuthorityDigest(
        state,
        parser,
        bytes,
        resident_cap,
        out,
        guard,
    );
    if (!std.mem.eql(u8, &local_before, &local_after_validate)) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            out,
            .allocation,
            target_capacity,
        ) };
    }
    const replacement = raw_replacement.?[0..target_capacity];
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .state_addr = @intFromPtr(state),
        .parser_addr = @intFromPtr(parser),
        .expected_start = expected_start,
        .bytes_addr = bytes_addr,
        .bytes_len = bytes.len,
        .bytes_digest = read_digest,
        .source_seal = source_seal,
        .unread_digest = unread_digest,
        .allocator = allocation_owner,
        .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
        .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
        .replacement_addr = replacement_addr,
        .replacement_len = replacement.len,
        .final_items_len = next_unread_len,
        .resident_cap = resident_cap,
        .replacement = replacement,
        .cleanup_replacement = replacement,
        .replacement_guard = guard,
        .replacement_authority_seal = final_seal,
        .lifecycle = .prepared,
        .completion = .active,
    };
    out.cleanup_digest = appendCleanupDigest(out);
    out.digest = appendDigest(out);
    return .prepared;
}

pub fn prepareAdmit(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    expected_start: u64,
    resident_cap: usize,
    out: *PreparedRxAppend,
) RxPrepareError!void {
    if (state.rx_operation_busy) return error.InvalidState;
    if (!parserSealValid(state, parser)) return error.InvalidSeal;
    const parser_backing_addr =
        if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(@intFromPtr(out), @sizeOf(PreparedRxAppend), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            parser_backing_addr,
            parser.buf.capacity,
        ))
        return error.InvalidDescriptor;
    if (expected_start != state.rx_provenance.rx_absolute_next)
        return error.InvalidState;
    if (!appendOutputPristine(out))
        return error.InvalidState;
    const unread_len = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        return error.InvalidDescriptor;
    const next_unread_len = std.math.add(usize, unread_len, bytes.len) catch
        return error.ArithmeticOverflow;
    if (next_unread_len > resident_cap) return error.ResidentCap;
    _ = std.math.add(u64, expected_start, @as(u64, @intCast(bytes.len))) catch
        return error.ArithmeticOverflow;
    const bytes_addr = if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
    if (rangesOverlap(bytes_addr, bytes.len, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(parser), @sizeOf(framing.FrameParser)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(out), @sizeOf(PreparedRxAppend)) or
        rangesOverlap(bytes_addr, bytes.len, parser_backing_addr, parser.buf.capacity))
        return error.InvalidDescriptor;
    const next_items_len = std.math.add(usize, parser.buf.items.len, bytes.len) catch
        return error.ArithmeticOverflow;
    if (next_items_len > parser.buf.capacity) return error.InvalidState;
    const source_seal = state.rx_provenance.parser_seal;
    const allocation_owner = parser.allocator;
    state.rx_operation_busy = true;
    errdefer state.rx_operation_busy = false;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .state_addr = @intFromPtr(state),
        .parser_addr = @intFromPtr(parser),
        .expected_start = expected_start,
        .bytes_addr = bytes_addr,
        .bytes_len = bytes.len,
        .source_seal = source_seal,
        .allocator = allocation_owner,
        .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
        .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
        .resident_cap = resident_cap,
        .lifecycle = .prepared,
        .completion = .active,
    };
    out.cleanup_digest = appendCleanupDigest(out);
    out.digest = appendDigest(out);
}

fn commitAdmitUnchecked(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    prepared: *PreparedRxAppend,
) void {
    if (!appendPreparedValid(state, parser, bytes, prepared))
        @panic("invalid prepared RX append");
    if (prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_len != 0 or
        prepared.replacement_guard != null)
        @panic("guarded RX append entered callback-free commit");
    const next_absolute = std.math.add(
        u64,
        state.rx_provenance.rx_absolute_next,
        @as(u64, @intCast(bytes.len)),
    ) catch @panic("RX append counter overflow");
    parser.buf.appendSliceAssumeCapacity(bytes);
    state.rx_provenance.rx_absolute_next = next_absolute;
    if (!resealParserAuthority(state, parser)) @panic("RX append reseal failed");
    prepared.lifecycle = .committed;
}

const GuardedSourceSnapshot = struct {
    provenance: RxProvenance,
    saved_flags: c_int,
    tx_items_addr: usize,
    tx_items_len: usize,
    tx_capacity: usize,
    tx_bytes: usize,
    allocator: std.mem.Allocator,
    expected_major: u16,
    items_addr: usize,
    items_len: usize,
    capacity: usize,
    head: usize,
    content_digest: owner_seal.Digest,

    fn capture(
        state: *const State,
        parser: *const framing.FrameParser,
    ) GuardedSourceSnapshot {
        return .{
            .provenance = state.rx_provenance,
            .saved_flags = state.saved_flags,
            .tx_items_addr = if (state.external_tx.capacity == 0) 0 else @intFromPtr(state.external_tx.items.ptr),
            .tx_items_len = state.external_tx.items.len,
            .tx_capacity = state.external_tx.capacity,
            .tx_bytes = state.external_tx_bytes,
            .allocator = parser.allocator,
            .expected_major = parser.expected_major,
            .items_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            .items_len = parser.buf.items.len,
            .capacity = parser.buf.capacity,
            .head = parser.head,
            .content_digest = bytesDigest(parser.buf.items),
        };
    }

    fn writeDigest(
        self: GuardedSourceSnapshot,
        writer: *owner_seal.Writer,
    ) void {
        writer.writeUsize(@as(usize, @as(u32, @bitCast(self.saved_flags))));
        writer.writeUsize(self.tx_items_addr);
        writer.writeUsize(self.tx_items_len);
        writer.writeUsize(self.tx_capacity);
        writer.writeUsize(self.tx_bytes);
        if (self.provenance.identity) |identity| {
            writer.writeUsize(1);
            writer.writeU64(identity.attach_instance_id);
            writer.writeUsize(identity.destination_slot_addr);
        } else {
            writer.writeUsize(0);
            writer.writeU64(0);
            writer.writeUsize(0);
        }
        writer.writeUsize(self.provenance.destination_slot_len);
        writer.writeU64(self.provenance.rx_absolute_next);
        writer.writeU64(self.provenance.buffer_start_absolute);
        writer.writeUsize(self.provenance.resident_cap);
        writer.writeUsize(@intFromEnum(self.provenance.lifecycle));
        writer.writeBytes(&self.provenance.parser_seal.digest);
        writer.writeUsize(@intFromPtr(self.allocator.ptr));
        writer.writeUsize(@intFromPtr(self.allocator.vtable));
        writer.writeU16(self.expected_major);
        writer.writeUsize(self.items_addr);
        writer.writeUsize(self.items_len);
        writer.writeUsize(self.capacity);
        writer.writeUsize(self.head);
        writer.writeBytes(&self.content_digest);
    }

    fn matches(
        self: GuardedSourceSnapshot,
        state: *const State,
        parser: *const framing.FrameParser,
        expect_terminal: bool,
    ) bool {
        const provenance_matches = if (expect_terminal)
            std.meta.eql(
                state.rx_provenance,
                RxProvenance{ .lifecycle = .terminal },
            )
        else
            std.meta.eql(state.rx_provenance, self.provenance);
        return provenance_matches and
            state.saved_flags == self.saved_flags and
            state.external_tx.items.len == self.tx_items_len and
            state.external_tx.capacity == self.tx_capacity and
            state.external_tx_bytes == self.tx_bytes and
            (self.tx_capacity == 0 or
                @intFromPtr(state.external_tx.items.ptr) == self.tx_items_addr) and
            @intFromPtr(parser.allocator.ptr) == @intFromPtr(self.allocator.ptr) and
            @intFromPtr(parser.allocator.vtable) == @intFromPtr(self.allocator.vtable) and
            parser.expected_major == self.expected_major and
            parser.buf.items.len == self.items_len and
            parser.buf.capacity == self.capacity and
            parser.head == self.head and
            (self.capacity == 0 or @intFromPtr(parser.buf.items.ptr) == self.items_addr) and
            std.mem.eql(u8, &self.content_digest, &bytesDigest(parser.buf.items));
    }
};

const GuardedCleanupResult = union(enum) {
    freed_clean,
    quarantined_without_free: usize,
    freed_with_drift: usize,
};

pub const max_guarded_admit_quarantine_bytes: usize =
    2 * (protocol.max_binary_chunk + protocol.header_size);

fn guardedQuarantineUpperBound(prepared: *const PreparedRxAppend) usize {
    const hard_cap = protocol.max_binary_chunk + protocol.header_size;
    if (!guardedPreparedCleanupAuthority(prepared) or
        prepared.resident_cap == 0 or prepared.resident_cap > hard_cap)
        return hard_cap;
    return @min(prepared.replacement_len, prepared.resident_cap);
}

fn guardedCleanupQuarantineUpperBound(
    replacement_upper_bound: usize,
    source_upper_bound: usize,
) usize {
    return @min(
        std.math.add(
            usize,
            replacement_upper_bound,
            source_upper_bound,
        ) catch max_guarded_admit_quarantine_bytes,
        max_guarded_admit_quarantine_bytes,
    );
}

fn guardedPreparedCleanupAuthority(
    prepared: *const PreparedRxAppend,
) bool {
    if (prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.replacement == null or
        prepared.replacement_guard == null or
        !replacementSealValid(prepared.replacement_authority_seal) or
        prepared.resident_cap == 0 or
        prepared.replacement_len == 0 or
        prepared.replacement_len > prepared.resident_cap or
        !std.mem.eql(u8, &prepared.digest, &appendDigest(prepared)))
        return false;
    return canonicalAppendReplacement(prepared) != null;
}

const FrozenReplacementCleanup = struct {
    replacement: []u8,
    allocator: std.mem.Allocator,
    guard: ReplacementAllocationGuard,
    candidate: ReplacementCandidate,
    authority_seal: ReplacementAuthoritySeal,
    source: GuardedSourceSnapshot,

    fn capture(
        state: *const State,
        parser: *const framing.FrameParser,
        prepared: *const PreparedRxAppend,
        frozen_source: ?GuardedSourceSnapshot,
    ) ?FrozenReplacementCleanup {
        if (!guardedPreparedCleanupAuthority(prepared)) return null;
        return .{
            .replacement = canonicalAppendReplacement(prepared) orelse return null,
            .allocator = prepared.allocator,
            .guard = prepared.replacement_guard.?,
            .candidate = .{
                .addr = prepared.replacement_addr,
                .len = prepared.replacement_len,
            },
            .authority_seal = prepared.replacement_authority_seal,
            .source = frozen_source orelse GuardedSourceSnapshot.capture(state, parser),
        };
    }

    fn sourceQuarantineUpperBound(self: FrozenReplacementCleanup) usize {
        return @min(
            self.source.capacity,
            protocol.max_binary_chunk + protocol.header_size,
        );
    }
};

fn executeFrozenReplacementCleanup(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
    frozen: FrozenReplacementCleanup,
) GuardedCleanupResult {
    // From this point every callback observes only a tombstone and terminal-busy source. The
    // suffix never reads `prepared` again; all allocator and guard authority lives in `frozen`.
    markPreparedAdmitTransient(prepared, .aborted);
    state.rx_provenance = .{ .lifecycle = .terminal };
    const cleanup_seal = captureReplacementAuthority(
        frozen.guard,
        .capture_before_cleanup,
        frozen.authority_seal,
        frozen.candidate,
    ) orelse {
        const source_upper_bound = if (frozen.source.matches(state, parser, true))
            0
        else
            frozen.sourceQuarantineUpperBound();
        markPreparedAdmitTransient(prepared, .aborted);
        state.rx_operation_busy = false;
        return .{ .quarantined_without_free = guardedCleanupQuarantineUpperBound(
            @min(
                frozen.replacement.len,
                protocol.max_binary_chunk + protocol.header_size,
            ),
            source_upper_bound,
        ) };
    };
    const source_clean_before_free = frozen.source.matches(state, parser, true);
    frozen.allocator.rawFree(
        frozen.replacement,
        .of(u8),
        @returnAddress(),
    );
    const accepted_after = validateReplacementCandidate(
        frozen.guard,
        .validate_after_cleanup,
        cleanup_seal,
        frozen.candidate,
    );
    const final_seal = if (accepted_after)
        captureReplacementAuthority(
            frozen.guard,
            .capture_after_cleanup_validate,
            cleanup_seal,
            frozen.candidate,
        )
    else
        null;
    const source_matches =
        source_clean_before_free and frozen.source.matches(state, parser, true);
    if (!accepted_after or final_seal == null or !source_matches) {
        markPreparedAdmitTransient(prepared, .aborted);
        parser.allocator = frozen.source.allocator;
        parser.expected_major = frozen.source.expected_major;
        parser.buf = .empty;
        parser.head = 0;
        state.rx_provenance = .{ .lifecycle = .terminal };
        state.rx_operation_busy = false;
        return .{ .freed_with_drift = frozen.sourceQuarantineUpperBound() };
    }
    markPreparedAdmitTransient(prepared, .aborted);
    state.rx_provenance = frozen.source.provenance;
    state.rx_operation_busy = false;
    return .freed_clean;
}

fn cleanupGuardedPreparedReplacement(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
    frozen_source: ?GuardedSourceSnapshot,
) GuardedCleanupResult {
    if (!state.rx_operation_busy) {
        const upper_bound = guardedQuarantineUpperBound(prepared);
        markPreparedAdmitTransient(prepared, .quarantined);
        state.rx_provenance = .{ .lifecycle = .terminal };
        state.rx_operation_busy = false;
        return .{ .quarantined_without_free = upper_bound };
    }
    const frozen = FrozenReplacementCleanup.capture(
        state,
        parser,
        prepared,
        frozen_source,
    ) orelse {
        const upper_bound = guardedQuarantineUpperBound(prepared);
        markPreparedAdmitTransient(prepared, .quarantined);
        state.rx_provenance = .{ .lifecycle = .terminal };
        state.rx_operation_busy = false;
        return .{ .quarantined_without_free = upper_bound };
    };
    return executeFrozenReplacementCleanup(state, parser, prepared, frozen);
}

fn quarantineCommitBeforePublication(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
    replacement_upper_bound: usize,
    frozen_source: ?GuardedSourceSnapshot,
) GuardedAdmitCommitOutcome {
    const frozen = FrozenReplacementCleanup.capture(
        state,
        parser,
        prepared,
        frozen_source,
    ) orelse {
        const quarantine = GuardedAdmitQuarantine{
            .phase = .commit_cleanup,
            .quarantined_bytes_upper_bound = replacement_upper_bound,
        };
        markQuarantinedPreparedAdmitPending(
            prepared,
            .quarantined,
            .allocation_quarantined,
            quarantine,
        );
        state.rx_provenance = .{ .lifecycle = .terminal };
        state.rx_operation_busy = false;
        return .{ .allocation_quarantined = quarantine };
    };
    return quarantineFrozenCommitBeforePublication(
        state,
        parser,
        prepared,
        frozen,
    );
}

fn quarantineFrozenCommitBeforePublication(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
    frozen: FrozenReplacementCleanup,
) GuardedAdmitCommitOutcome {
    const cleanup = executeFrozenReplacementCleanup(state, parser, prepared, frozen);
    state.rx_provenance = .{ .lifecycle = .terminal };
    state.rx_operation_busy = false;
    const quarantine = switch (cleanup) {
        .freed_clean => GuardedAdmitQuarantine{
            .phase = .commit_cleanup,
            .quarantined_bytes_upper_bound = 0,
        },
        .freed_with_drift => |upper_bound| GuardedAdmitQuarantine{
            .phase = .commit_cleanup,
            .quarantined_bytes_upper_bound = upper_bound,
        },
        .quarantined_without_free => |upper_bound| GuardedAdmitQuarantine{
            .phase = .commit_cleanup,
            .quarantined_bytes_upper_bound = upper_bound,
        },
    };
    const lifecycle: PreparedAppendLifecycle = switch (cleanup) {
        .freed_clean, .freed_with_drift => .aborted,
        .quarantined_without_free => .quarantined,
    };
    markQuarantinedPreparedAdmitPending(
        prepared,
        lifecycle,
        .allocation_quarantined,
        quarantine,
    );
    return .{ .allocation_quarantined = quarantine };
}

pub fn abortPreparedAdmitGuarded(
    state: *State,
    parser: *framing.FrameParser,
    prepared: *PreparedRxAppend,
) GuardedAdmitAbortOutcome {
    if (!state.rx_operation_busy or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state) or
        prepared.parser_addr != @intFromPtr(parser))
        return .{ .ordinary_failure = .{ .reason = error.InvalidState } };
    if (!appendPreparedTokenAuthenticated(state, parser, prepared)) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            prepared,
            .abort_cleanup,
            protocol.max_binary_chunk + protocol.header_size,
        ) };
    }
    const has_replacement_evidence = prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_len != 0 or
        prepared.replacement_guard != null;
    if (!has_replacement_evidence) {
        if (prepared.expected_start != state.rx_provenance.rx_absolute_next or
            !std.meta.eql(prepared.source_seal, state.rx_provenance.parser_seal) or
            !parserSealValid(state, parser))
        {
            return .{ .allocation_quarantined = quarantinePreparedAllocation(
                state,
                prepared,
                .abort_cleanup,
                0,
            ) };
        }
        markOrdinaryPreparedAdmitFinished(prepared, .aborted);
        state.rx_operation_busy = false;
        return .aborted;
    }
    const cleanup = cleanupGuardedPreparedReplacement(state, parser, prepared, null);
    return switch (cleanup) {
        .freed_clean => blk: {
            markOrdinaryPreparedAdmitFinished(prepared, .aborted);
            break :blk .aborted;
        },
        .quarantined_without_free => |cleanup_upper_bound| blk: {
            const quarantine = GuardedAdmitQuarantine{
                .phase = .abort_cleanup,
                .quarantined_bytes_upper_bound = cleanup_upper_bound,
            };
            markQuarantinedPreparedAdmitPending(
                prepared,
                .quarantined,
                .allocation_quarantined,
                quarantine,
            );
            break :blk .{ .allocation_quarantined = quarantine };
        },
        .freed_with_drift => |source_upper_bound| blk: {
            const quarantine = GuardedAdmitQuarantine{
                .phase = .abort_cleanup,
                .quarantined_bytes_upper_bound = source_upper_bound,
            };
            markQuarantinedPreparedAdmitPending(
                prepared,
                .aborted,
                .allocation_quarantined,
                quarantine,
            );
            break :blk .{ .allocation_quarantined = quarantine };
        },
    };
}

pub fn commitPreparedAdmitGuarded(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    prepared: *PreparedRxAppend,
) GuardedAdmitCommitOutcome {
    if (!state.rx_operation_busy or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state) or
        prepared.parser_addr != @intFromPtr(parser))
        return .{ .ordinary_failure = .{ .reason = error.InvalidState } };
    if (!appendPreparedTokenAuthenticated(state, parser, prepared)) {
        return .{ .allocation_quarantined = quarantinePreparedAllocation(
            state,
            prepared,
            .commit_cleanup,
            protocol.max_binary_chunk + protocol.header_size,
        ) };
    }
    const has_replacement_evidence = prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_len != 0 or
        prepared.replacement_guard != null;
    if (!has_replacement_evidence) {
        if (!appendPreparedValid(state, parser, bytes, prepared)) {
            const quarantine = GuardedAdmitQuarantine{
                .phase = .commit_cleanup,
                .quarantined_bytes_upper_bound = 0,
            };
            markQuarantinedPreparedAdmitPending(
                prepared,
                .quarantined,
                .allocation_quarantined,
                quarantine,
            );
            state.rx_provenance = .{ .lifecycle = .terminal };
            state.rx_operation_busy = false;
            return .{ .allocation_quarantined = quarantine };
        }
        commitPreparedAdmit(state, parser, bytes, prepared) catch
            @panic("validated callback-free RX append commit failed");
        markOrdinaryPreparedAdmitFinished(prepared, .committed);
        return .committed;
    }
    const replacement_upper_bound = guardedQuarantineUpperBound(prepared);
    if (!appendPreparedValid(state, parser, bytes, prepared)) {
        return quarantineCommitBeforePublication(
            state,
            parser,
            prepared,
            replacement_upper_bound,
            null,
        );
    }

    const frozen = FrozenReplacementCleanup.capture(
        state,
        parser,
        prepared,
        null,
    ) orelse {
        const quarantine = quarantinePreparedAllocation(
            state,
            prepared,
            .commit_cleanup,
            replacement_upper_bound,
        );
        return .{ .allocation_quarantined = quarantine };
    };
    const next_absolute = std.math.add(
        u64,
        state.rx_provenance.rx_absolute_next,
        @as(u64, @intCast(bytes.len)),
    ) catch return quarantineCommitBeforePublication(
        state,
        parser,
        prepared,
        replacement_upper_bound,
        null,
    );
    const final_items_len = prepared.final_items_len;
    const input_digest = bytesDigest(bytes);
    const old_candidate = if (frozen.source.capacity == 0) null else ReplacementCandidate{
        .addr = frozen.source.items_addr,
        .len = frozen.source.capacity,
    };
    // Consume every prepared authority before the first cleanup callback. The entire commit and
    // replacement-abort plans now live in stack-local `frozen` values.
    markPreparedAdmitTransient(prepared, .committed);
    state.rx_provenance = .{ .lifecycle = .terminal };
    const cleanup_seal = captureReplacementAuthority(
        frozen.guard,
        .capture_before_cleanup,
        frozen.authority_seal,
        old_candidate,
    ) orelse return quarantineFrozenCommitBeforePublication(
        state,
        parser,
        prepared,
        frozen,
    );
    if (!frozen.source.matches(state, parser, true) or
        !std.mem.eql(u8, &input_digest, &bytesDigest(bytes)))
        return quarantineFrozenCommitBeforePublication(
            state,
            parser,
            prepared,
            frozen,
        );
    state.rx_provenance = frozen.source.provenance;
    const unread = parser.buf.items[parser.head..];
    @memcpy(frozen.replacement[0..unread.len], unread);
    @memcpy(frozen.replacement[unread.len..final_items_len], bytes);
    var old = parser.buf;
    parser.buf = .{
        .items = frozen.replacement[0..final_items_len],
        .capacity = frozen.replacement.len,
    };
    parser.head = 0;
    state.rx_provenance.rx_absolute_next = next_absolute;
    if (!resealParserAuthority(state, parser))
        @panic("guarded RX append no-callback reseal failed");
    const published = GuardedSourceSnapshot.capture(state, parser);
    state.rx_provenance = .{ .lifecycle = .terminal };
    old.deinit(frozen.allocator);
    const cleanup_ok = if (old_candidate) |candidate|
        validateReplacementCandidate(
            frozen.guard,
            .validate_after_cleanup,
            cleanup_seal,
            candidate,
        )
    else
        true;
    const final_seal = if (cleanup_ok)
        captureReplacementAuthority(
            frozen.guard,
            .capture_after_cleanup_validate,
            cleanup_seal,
            old_candidate,
        )
    else
        null;
    if (!cleanup_ok or final_seal == null or !published.matches(state, parser, true)) {
        const quarantine = GuardedAdmitQuarantine{
            .phase = .commit_cleanup,
            .quarantined_bytes_upper_bound = replacement_upper_bound,
        };
        markQuarantinedPreparedAdmitPending(
            prepared,
            .committed,
            .post_commit_quarantined,
            quarantine,
        );
        parser.allocator = published.allocator;
        parser.expected_major = published.expected_major;
        parser.buf = .empty;
        parser.head = 0;
        state.rx_provenance = .{ .lifecycle = .terminal };
        state.rx_operation_busy = false;
        return .{ .post_commit_quarantined = quarantine };
    }
    markOrdinaryPreparedAdmitFinished(prepared, .committed);
    state.rx_provenance = published.provenance;
    state.rx_operation_busy = false;
    return .committed;
}

pub fn commitPreparedAdmit(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    prepared: *PreparedRxAppend,
) RxPrepareError!void {
    if (prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_len != 0 or
        prepared.replacement_guard != null)
        return error.InvalidState;
    if (!appendPreparedValid(state, parser, bytes, prepared))
        return error.InvalidSeal;
    // No allocation, callback or outer action is permitted below this ReleaseFast validation.
    commitAdmitUnchecked(state, parser, bytes, prepared);
    state.rx_operation_busy = false;
    markOrdinaryPreparedAdmitFinished(prepared, .committed);
}

pub fn abortPreparedAdmit(
    state: *State,
    prepared: *PreparedRxAppend,
) RxPrepareError!void {
    if (!state.rx_operation_busy or
        prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state) or
        prepared.replacement != null or
        prepared.cleanup_replacement != null or
        prepared.replacement_len != 0 or
        prepared.replacement_guard != null)
        return error.InvalidState;
    prepared.deinitInternal();
    state.rx_operation_busy = false;
    markOrdinaryPreparedAdmitFinished(prepared, .aborted);
}

pub fn prepareRxBind(
    source_state: *const State,
    attach_instance_id: u64,
    normalized: *const framing.PreparedNormalizeExact,
    resident_cap: usize,
    destination_slot_addr: usize,
    destination_slot_len: usize,
    out: *PreparedRxBind,
) RxPrepareError!void {
    if (!std.meta.eql(source_state.rx_provenance, RxProvenance{}))
        return error.InvalidState;
    if (source_state.rx_operation_busy) return error.InvalidState;
    if (attach_instance_id == 0 or resident_cap == 0 or
        destination_slot_addr == 0 or destination_slot_len == 0)
        return error.InvalidIdentity;
    _ = std.math.add(usize, destination_slot_addr, destination_slot_len) catch
        return error.ArithmeticOverflow;
    if (normalized.saved_self_addr != @intFromPtr(normalized) or
        normalized.replacement_len > resident_cap or
        normalized.replacement_len > std.math.maxInt(u64))
        return error.InvalidDescriptor;
    const out_addr = @intFromPtr(out);
    const normalized_addr = @intFromPtr(normalized);
    const replacement_addr = if (normalized.replacement) |bytes|
        @intFromPtr(bytes.ptr)
    else
        0;
    if (rangesOverlap(out_addr, @sizeOf(PreparedRxBind), @intFromPtr(source_state), @sizeOf(State)) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            normalized_addr,
            @sizeOf(framing.PreparedNormalizeExact),
        ) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            replacement_addr,
            normalized.replacement_len,
        ) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            destination_slot_addr,
            destination_slot_len,
        ))
        return error.InvalidDescriptor;
    if (!std.meta.eql(out.*, PreparedRxBind{}))
        return error.InvalidState;
    const unread = normalized.replacement orelse {
        if (normalized.replacement_len != 0) return error.InvalidDescriptor;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .source_state_addr = @intFromPtr(source_state),
            .destination_slot_addr = destination_slot_addr,
            .destination_slot_len = destination_slot_len,
            .normalized_addr = @intFromPtr(normalized),
            .identity = .{
                .attach_instance_id = attach_instance_id,
                .destination_slot_addr = destination_slot_addr,
            },
            .allocator_ptr_addr = normalized.allocator_ptr_addr,
            .allocator_vtable_addr = normalized.allocator_vtable_addr,
            .expected_major = normalized.expected_major,
            .resident_cap = resident_cap,
            .unread_len = 0,
            .unread_digest = bytesDigest(""),
            .lifecycle = .prepared,
        };
        out.digest = rxBindDigest(out);
        return;
    };
    if (unread.len != normalized.replacement_len) return error.InvalidDescriptor;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .source_state_addr = @intFromPtr(source_state),
        .destination_slot_addr = destination_slot_addr,
        .destination_slot_len = destination_slot_len,
        .normalized_addr = @intFromPtr(normalized),
        .identity = .{
            .attach_instance_id = attach_instance_id,
            .destination_slot_addr = destination_slot_addr,
        },
        .allocator_ptr_addr = normalized.allocator_ptr_addr,
        .allocator_vtable_addr = normalized.allocator_vtable_addr,
        .expected_major = normalized.expected_major,
        .resident_cap = resident_cap,
        .unread_len = @intCast(unread.len),
        .unread_digest = bytesDigest(unread),
        .lifecycle = .prepared,
    };
    out.digest = rxBindDigest(out);
}

pub fn commitPreparedRxBind(
    state: *State,
    parser: *const framing.FrameParser,
    prepared: *PreparedRxBind,
    destination_slot_addr: usize,
    destination_slot_len: usize,
) void {
    if (prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.destination_slot_addr != destination_slot_addr or
        prepared.destination_slot_len != destination_slot_len or
        prepared.resident_cap == 0 or
        !std.meta.eql(state.rx_provenance, RxProvenance{}) or
        !std.mem.eql(u8, &prepared.digest, &rxBindDigest(prepared)) or
        parser.head != 0 or parser.buf.items.len != prepared.unread_len or
        @intFromPtr(parser.allocator.ptr) != prepared.allocator_ptr_addr or
        @intFromPtr(parser.allocator.vtable) != prepared.allocator_vtable_addr or
        parser.expected_major != prepared.expected_major or
        !parserDescriptorValid(
            parser,
            @intFromPtr(&state.rx_provenance.parser_seal),
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            @intFromPtr(state),
            @sizeOf(State),
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            destination_slot_addr,
            destination_slot_len,
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            @intFromPtr(prepared),
            @sizeOf(PreparedRxBind),
        ) or
        !std.mem.eql(u8, &prepared.unread_digest, &bytesDigest(parser.buf.items)))
        @panic("invalid prepared RX bind");
    const identity = prepared.identity orelse @panic("missing RX identity");
    state.rx_provenance = .{
        .identity = identity,
        .destination_slot_len = destination_slot_len,
        .rx_absolute_next = prepared.unread_len,
        .buffer_start_absolute = 0,
        .resident_cap = prepared.resident_cap,
        .lifecycle = .bound,
    };
    state.rx_provenance.parser_seal =
        makeParserSeal(parser, &state.rx_provenance, 1) orelse
        @panic("invalid parser descriptor at RX bind");
    if (!parserSealValid(state, parser)) @panic("RX bind seal mismatch");
    state.rx_operation_busy = false;
    prepared.lifecycle = .committed;
}

pub const Mode = union(enum) {
    blocking,
    external: State,
};

pub const FlagOps = struct {
    context: *anyopaque,
    get_flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    set_flags: *const fn (context: *anyopaque, fd: c.fd_t, flags: c_int) bool,
};

pub const Outcome = union(enum) {
    external: State,
    flag_failed,
    invalid_blocking_flags,
    indeterminate,
};

/// Stage every 2a-owned allocation before observing or mutating fd flags. A successful target
/// verification returns owned state; every other outcome has already reclaimed staged storage.
pub fn transition(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    ops: FlagOps,
) error{OutOfMemory}!Outcome {
    var staged = try State.stage(allocator);
    errdefer staged.deinit(allocator);

    const saved_flags = ops.get_flags(ops.context, fd) orelse {
        staged.deinit(allocator);
        return .flag_failed;
    };
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (saved_flags & nonblocking != 0) {
        staged.deinit(allocator);
        return .invalid_blocking_flags;
    }
    staged.saved_flags = saved_flags;
    const target_flags = saved_flags | nonblocking;
    const set_ok = ops.set_flags(ops.context, fd, target_flags);
    const observed = ops.get_flags(ops.context, fd);
    if (set_ok and observed != null and observed.? == target_flags)
        return .{ .external = staged };

    // A failing adapter may still have changed the open-file-description. Only an exact observed
    // original value, or an explicitly successful and verified rollback, is reusable.
    if (!set_ok and observed != null and observed.? == saved_flags) {
        staged.deinit(allocator);
        return .flag_failed;
    }
    if (!ops.set_flags(ops.context, fd, saved_flags)) {
        staged.deinit(allocator);
        return .indeterminate;
    }
    const restored = ops.get_flags(ops.context, fd);
    staged.deinit(allocator);
    return if (restored != null and restored.? == saved_flags)
        .flag_failed
    else
        .indeterminate;
}

const FakeFlags = struct {
    flags: c_int = 0x20,
    get_results: []const ?c_int = &.{},
    get_index: usize = 0,
    set_results: []const bool = &.{true},
    set_index: usize = 0,
    mutate_on_set: bool = true,

    fn ops(self: *FakeFlags) FlagOps {
        return .{
            .context = self,
            .get_flags = getFlags,
            .set_flags = setFlags,
        };
    }

    fn cast(context: *anyopaque) *FakeFlags {
        return @ptrCast(@alignCast(context));
    }

    fn getFlags(context: *anyopaque, _: c.fd_t) ?c_int {
        const self = cast(context);
        if (self.get_index < self.get_results.len) {
            const result = self.get_results[self.get_index];
            self.get_index += 1;
            return result;
        }
        self.get_index += 1;
        return self.flags;
    }

    fn setFlags(context: *anyopaque, _: c.fd_t, flags: c_int) bool {
        const self = cast(context);
        const result = if (self.set_index < self.set_results.len)
            self.set_results[self.set_index]
        else
            true;
        self.set_index += 1;
        if (self.mutate_on_set) self.flags = flags;
        return result;
    }
};

test "external mode transition preserves unrelated flags and stages exact descriptor capacity" {
    var fake = FakeFlags{ .flags = 0x20 };
    const outcome = try transition(std.testing.allocator, 7, fake.ops());
    var state = outcome.external;
    defer state.deinit(std.testing.allocator);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(@as(c_int, 0x20), state.saved_flags);
    try std.testing.expectEqual(@as(c_int, 0x20) | nonblocking, fake.flags);
    try std.testing.expectEqual(max_tx_frames, state.external_tx.capacity);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.set_index);
    try std.testing.expectEqual(@as(usize, 2), fake.get_index);
}

test "external mode transition classifies initial and unexpected blocking flag failures" {
    var get_failed = FakeFlags{ .get_results = &.{null} };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, get_failed.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 0), get_failed.set_index);

    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    var already_nonblocking = FakeFlags{ .flags = 0x20 | nonblocking };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, already_nonblocking.ops())) ==
            .invalid_blocking_flags,
    );
    try std.testing.expectEqual(@as(usize, 0), already_nonblocking.set_index);
}

test "external mode transition verifies mutate-then-fail rollback and poisons ambiguity" {
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    const original: c_int = 0x20;
    const target = original | nonblocking;

    var restored = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target, original },
        .set_results = &.{ false, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, restored.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(original, restored.flags);

    var successful_set_not_observed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, original, original },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(
            std.testing.allocator,
            7,
            successful_set_not_observed.ops(),
        )) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 2), successful_set_not_observed.set_index);

    var rollback_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target },
        .set_results = &.{ false, false },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, rollback_failed.ops())) == .indeterminate,
    );

    var verify_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, null, null },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, verify_failed.ops())) == .indeterminate,
    );
}

fn checkTransitionAllocation(allocator: std.mem.Allocator) !void {
    var fake = FakeFlags{};
    const outcome = transition(allocator, 7, fake.ops()) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), fake.get_index);
        try std.testing.expectEqual(@as(usize, 0), fake.set_index);
        return err;
    };
    var state = outcome.external;
    state.deinit(allocator);
}

test "external mode transition is leak free at every allocation fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTransitionAllocation,
        .{},
    );
}

test "prepared RX bind opens a bind-local epoch on normalized unread bytes" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("deadpending");
    parser.head = 4;
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        77,
        &normalized,
        8,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expect(prepared.validate(
        &state,
        77,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );
    try std.testing.expectEqual(RxProvenanceLifecycle.bound, state.rx_provenance.lifecycle);
    try std.testing.expectEqual(@as(u64, 7), state.rx_provenance.rx_absolute_next);
    try std.testing.expectEqual(@as(u64, 0), state.rx_provenance.buffer_start_absolute);
    try std.testing.expectEqual(@as(u64, 77), state.rx_provenance.identity.?.attach_instance_id);
    try std.testing.expect(parserSealValid(&state, &parser));
}

test "prepared RX bind rejects zero identity and stale or copied authority" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, 0);
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    try std.testing.expectError(
        error.InvalidIdentity,
        prepareRxBind(
            &state,
            0,
            &normalized,
            1,
            @intFromPtr(&destination_slot),
            @sizeOf(usize),
            &prepared,
        ),
    );
    try prepareRxBind(
        &state,
        9,
        &normalized,
        1,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    var copied = prepared;
    defer copied.deinit();
    try std.testing.expect(!copied.validate(
        &state,
        9,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    prepared.unread_len += 1;
    try std.testing.expect(!prepared.validate(
        &state,
        9,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    prepared.deinit();
}

test "C1 readable allowance preserves every positive last-byte limit tie" {
    const Case = struct {
        resident: usize,
        turn: usize,
        counter: usize,
        expected: ReadableAllowance,
    };
    const cases = [_]Case{
        .{ .resident = 1, .turn = 2, .counter = 3, .expected = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = false,
        } },
        .{ .resident = 2, .turn = 1, .counter = 3, .expected = .{
            .bytes = 1,
            .resident_limited = false,
            .turn_limited = true,
            .counter_limited = false,
        } },
        .{ .resident = 3, .turn = 2, .counter = 1, .expected = .{
            .bytes = 1,
            .resident_limited = false,
            .turn_limited = false,
            .counter_limited = true,
        } },
        .{ .resident = 1, .turn = 1, .counter = 2, .expected = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = true,
            .counter_limited = false,
        } },
        .{ .resident = 1, .turn = 2, .counter = 1, .expected = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = true,
        } },
        .{ .resident = 2, .turn = 1, .counter = 1, .expected = .{
            .bytes = 1,
            .resident_limited = false,
            .turn_limited = true,
            .counter_limited = true,
        } },
        .{ .resident = 1, .turn = 1, .counter = 1, .expected = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = true,
            .counter_limited = true,
        } },
    };
    for (cases) |case|
        try std.testing.expectEqual(
            case.expected,
            positiveReadableAllowance(
                case.resident,
                case.turn,
                case.counter,
            ),
        );
}

test "max readable uses tagged precedence and checked RX ceilings" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        11,
        &normalized,
        8,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );

    const resident_limited = maxReadable(&state, &parser, 8, 9).bytes;
    try std.testing.expectEqual(@as(usize, 5), resident_limited.bytes);
    try std.testing.expect(resident_limited.resident_limited);
    try std.testing.expect(!resident_limited.turn_limited);
    try std.testing.expect(!resident_limited.counter_limited);
    const turn_limited = maxReadable(&state, &parser, 8, 2).bytes;
    try std.testing.expectEqual(@as(usize, 2), turn_limited.bytes);
    try std.testing.expect(!turn_limited.resident_limited);
    try std.testing.expect(turn_limited.turn_limited);
    try std.testing.expect(!turn_limited.counter_limited);
    const tied = maxReadable(&state, &parser, 8, 5).bytes;
    try std.testing.expect(tied.resident_limited);
    try std.testing.expect(tied.turn_limited);
    try std.testing.expect(!tied.counter_limited);
    try std.testing.expect(maxReadable(&state, &parser, 3, 9) == .invalid);
    try std.testing.expect(maxReadable(&state, &parser, 8, 0) == .turn_exhausted);

    state.rx_provenance.rx_absolute_next = std.math.maxInt(u64) - 2;
    state.rx_provenance.buffer_start_absolute = std.math.maxInt(u64) - 5;
    try std.testing.expect(resealParserAuthority(&state, &parser));
    const counter_limited = maxReadable(&state, &parser, 8, 9).bytes;
    try std.testing.expectEqual(@as(usize, 2), counter_limited.bytes);
    try std.testing.expect(!counter_limited.resident_limited);
    try std.testing.expect(!counter_limited.turn_limited);
    try std.testing.expect(counter_limited.counter_limited);

    state.rx_provenance.rx_absolute_next = std.math.maxInt(u64);
    state.rx_provenance.buffer_start_absolute = std.math.maxInt(u64) - 3;
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try std.testing.expect(maxReadable(&state, &parser, 8, 9) == .counter_exhausted);

    parser.head = parser.buf.items.len + 1;
    try std.testing.expect(maxReadable(&state, &parser, 8, 9) == .invalid);
}

test "max readable rejects a parser that already fills its sealed resident cap" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    const resident_cap = parser.buf.capacity;
    const filler = try std.testing.allocator.alloc(
        u8,
        resident_cap - parser.buf.items.len,
    );
    defer std.testing.allocator.free(filler);
    @memset(filler, 'x');
    try parser.push(filler);
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, resident_cap);
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        12,
        &normalized,
        resident_cap,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );
    try std.testing.expect(
        maxReadable(&state, &parser, resident_cap, 9) == .resident_exhausted,
    );
    try std.testing.expect(
        maxReadable(&state, &parser, resident_cap, 0) == .resident_exhausted,
    );
    state.rx_provenance.rx_absolute_next = std.math.maxInt(u64);
    state.rx_provenance.buffer_start_absolute =
        std.math.maxInt(u64) - @as(u64, @intCast(resident_cap));
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try std.testing.expect(
        maxReadable(&state, &parser, resident_cap, 0) == .counter_exhausted,
    );
}

test "parser authority seal permits a context-free allocator" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, 8);
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        13,
        &normalized,
        8,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );

    var context_free = state.rx_provenance.parser_seal;
    context_free.allocator_ptr_addr = 0;
    context_free.digest = parserSealDigest(&context_free);
    try std.testing.expect(parserAuthoritySealStructurallyValid(&context_free));

    context_free.allocator_vtable_addr = 0;
    context_free.digest = parserSealDigest(&context_free);
    try std.testing.expect(!parserAuthoritySealStructurallyValid(&context_free));
}

fn bindParserForTest(
    state: *State,
    parser: *framing.FrameParser,
    attach_instance_id: u64,
    destination_slot: *usize,
) !void {
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        state,
        attach_instance_id,
        &normalized,
        protocol.max_binary_chunk + protocol.header_size,
        @intFromPtr(destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        state,
        parser,
        &prepared,
        @intFromPtr(destination_slot),
        @sizeOf(usize),
    );
}

fn setResidentCapForTest(
    state: *State,
    parser: *const framing.FrameParser,
    resident_cap: usize,
) !void {
    if (state.rx_provenance.resident_cap == resident_cap) return;
    try std.testing.expect(testing.forgeResealedResidentCap(
        state,
        parser,
        resident_cap,
    ));
}

fn admitForTest(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    resident_cap: usize,
) !void {
    try setResidentCapForTest(state, parser, resident_cap);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    if (prepareAdmitGuarded(
        state,
        parser,
        bytes,
        state.rx_provenance.rx_absolute_next,
        resident_cap,
        &guard,
        &prepared,
    ) != .prepared) return error.TestUnexpectedResult;
    if (commitPreparedAdmitGuarded(state, parser, bytes, &prepared) != .committed)
        return error.TestUnexpectedResult;
}

const TestReplacementGuard = struct {
    const Fault = enum {
        none,
        wrong_capture_tag,
        zero_after_allocate,
        drift_after_allocate,
    };

    calls: usize = 0,
    reject_phase: ?ReplacementGuardPhase = null,
    state: ?*State = null,
    parser: ?*framing.FrameParser = null,
    prepared: ?*PreparedRxAppend = null,
    reenter: bool = false,
    blocked_reentries: usize = 0,
    mutate_parser_phase: ?ReplacementGuardPhase = null,
    mutate_prepared_phase: ?ReplacementGuardPhase = null,
    fault: Fault = .none,
    seal: ReplacementAuthoritySeal = .{
        .generation = 1,
        .digest = [_]u8{0x5a} ** 32,
    },

    fn check(
        raw: *anyopaque,
        phase: ReplacementGuardPhase,
        expected: ?ReplacementAuthoritySeal,
        candidate: ?ReplacementCandidate,
    ) ReplacementGuardResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.reenter) {
            if (maxReadable(self.state.?, self.parser.?, 1, 1) == .invalid)
                self.blocked_reentries += 1;
        }
        if (self.mutate_parser_phase == phase) self.parser.?.head +%= 1;
        if (self.mutate_prepared_phase == phase) {
            self.prepared.?.replacement = null;
            self.prepared.?.cleanup_replacement = null;
            self.prepared.?.allocator = pristine_rx_append_allocator;
            self.prepared.?.digest = [_]u8{0} ** 32;
        }
        if (self.reject_phase == phase) return .quarantined;
        if (self.fault == .wrong_capture_tag and
            phase == .capture_before_allocate)
            return .{ .accepted = self.seal };
        if (self.fault == .zero_after_allocate and
            phase == .capture_after_allocate)
            return .{ .seal = .{} };
        if (self.fault == .drift_after_allocate and
            phase == .capture_after_allocate)
        {
            var drifted = self.seal;
            drifted.generation += 1;
            return .{ .seal = drifted };
        }
        return switch (phase) {
            .capture_before_allocate,
            .capture_after_allocate,
            .capture_after_validate,
            .capture_before_cleanup,
            .capture_after_cleanup_validate,
            => .{ .seal = self.seal },
            .validate_allocated, .validate_after_cleanup => if (expected != null and
                std.meta.eql(expected.?, self.seal) and candidate != null)
                .{ .accepted = self.seal }
            else
                .quarantined,
        };
    }

    fn guard(self: *@This()) ReplacementAllocationGuard {
        return .{ .context = self, .check = check };
    }
};

const GuardedAdmitTestAllocator = struct {
    child: std.mem.Allocator,
    mode: enum {
        normal,
        oom,
        oom_mutate_state,
        alias,
        overflow_address,
        mutate_parser_after_free,
    } = .normal,
    state: ?*State = null,
    parser: ?*framing.FrameParser = null,
    alias_addr: usize = 0,
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    reenter: bool = false,
    blocked_reentries: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.alloc_calls += 1;
        if (self.reenter and
            maxReadable(self.state.?, self.parser.?, 1, 1) == .invalid)
            self.blocked_reentries += 1;
        return switch (self.mode) {
            .oom => null,
            .oom_mutate_state => blk: {
                self.state.?.saved_flags +%= 1;
                break :blk null;
            },
            .alias => @ptrFromInt(self.alias_addr),
            .overflow_address => @ptrFromInt(std.math.maxInt(usize) - 1),
            else => self.child.rawAlloc(len, alignment, return_address),
        };
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.free_calls += 1;
        if (self.reenter and
            maxReadable(self.state.?, self.parser.?, 1, 1) == .invalid)
            self.blocked_reentries += 1;
        self.child.rawFree(memory, alignment, return_address);
        if (self.mode == .mutate_parser_after_free) {
            self.parser.?.head +%= 1;
        }
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

fn exactParserForGuardedAdmitTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !framing.FrameParser {
    var parser = framing.FrameParser.init(allocator);
    if (bytes.len == 0) return parser;
    const backing = try allocator.alloc(u8, bytes.len);
    @memcpy(backing, bytes);
    parser.buf = .{ .items = backing, .capacity = backing.len };
    return parser;
}

test "guarded RX admit accepts a sealed disjoint replacement and returns typed commit" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 301, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expectEqual(
        GuardedAdmitPrepareOutcome.prepared,
        prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            6,
            &guard,
            &prepared,
        ),
    );
    try std.testing.expectEqual(
        GuardedAdmitCommitOutcome.committed,
        commitPreparedAdmitGuarded(&state, &parser, "def", &prepared),
    );
    try std.testing.expectEqualStrings("abcdef", parser.buf.items);
    try std.testing.expectEqual(@as(u64, 6), state.rx_provenance.rx_absolute_next);
    try std.testing.expect(parserSealValid(&state, &parser));
    try std.testing.expect(!state.rx_operation_busy);
    try std.testing.expectEqual(
        PreparedAdmitCompletion.ordinary_finished,
        prepared.completion,
    );
    try std.testing.expect(resetFinishedPreparedAdmit(&prepared));
    try std.testing.expect(preparedRxAppendPristine(&prepared));
}

test "guarded RX admit spare-capacity path invokes no guard callback" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 302, &destination_slot);
    try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try setResidentCapForTest(&state, &parser, 8);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "xy", 0, 8, &guard, &prepared) ==
            .prepared,
    );
    try std.testing.expectEqual(@as(usize, 0), guard_context.calls);
    try std.testing.expect(
        commitPreparedAdmitGuarded(&state, &parser, "xy", &prepared) ==
            .committed,
    );
    try std.testing.expectEqual(@as(usize, 0), guard_context.calls);
    try std.testing.expectEqualStrings("xy", parser.buf.items);
}

test "terminal prepared admit no-callback classifies pristine ordinary and quarantine replay" {
    var state = State{ .saved_flags = 0 };
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();

    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .pristine,
    );
    try std.testing.expect(testing.seedOrdinaryFinishedPreparedAdmit(
        &prepared,
        true,
    ));
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .ordinary_finished,
    );
    try std.testing.expect(resetFinishedPreparedAdmit(&prepared));

    const quarantine = GuardedAdmitQuarantine{
        .phase = .commit_cleanup,
        .quarantined_bytes_upper_bound = max_guarded_admit_quarantine_bytes,
    };
    try std.testing.expect(testing.seedQuarantinePendingPreparedAdmit(
        &prepared,
        .post_commit_quarantined,
        quarantine,
    ));
    const pending = terminalizePreparedAdmitNoCallback(
        &state,
        &parser,
        &prepared,
    );
    try std.testing.expect(pending == .quarantine_pending);
    try std.testing.expectEqual(
        quarantine,
        pending.quarantine_pending.quarantine,
    );
    try std.testing.expectEqual(
        GuardedQuarantineOutcomeTag.post_commit_quarantined,
        pending.quarantine_pending.outcome_tag,
    );
    var event_count = std.atomic.Value(u64).init(0);
    var receipt: GuardedQuarantineAccountingReceipt = .{};
    try std.testing.expect(markQuarantinedPreparedAdmitAccounted(
        &prepared,
        .post_commit_quarantined,
        quarantine,
        &event_count,
        &receipt,
    ));
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .quarantine_accounted,
    );

    const alias: *PreparedRxAppend = @ptrCast(@alignCast(&state));
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            alias,
        ) == .unrecoverable,
    );
    const overflow_addr = (std.math.maxInt(usize) -
        @sizeOf(PreparedRxAppend) / 2) &
        ~(@as(usize, @alignOf(PreparedRxAppend)) - 1);
    const overflow: *PreparedRxAppend = @ptrFromInt(overflow_addr);
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            overflow,
        ) == .unrecoverable,
    );
}

test "terminal prepared admit no-callback closes active spare capacity at zero bound" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 700, &destination_slot);
    try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try setResidentCapForTest(&state, &parser, 8);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "xy", 0, 8, &guard, &prepared) ==
            .prepared,
    );
    const closed = terminalizePreparedAdmitNoCallback(
        &state,
        &parser,
        &prepared,
    );
    try std.testing.expect(closed == .terminalized);
    try std.testing.expectEqual(
        @as(usize, 0),
        closed.terminalized.quarantine.quarantined_bytes_upper_bound,
    );
    try std.testing.expectEqual(@as(usize, 0), guard_context.calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expect(!state.rx_operation_busy);
}

test "terminal prepared admit no-callback quarantines replacement without callbacks" {
    var fixed_bytes: [4096]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    const allocator = fixed.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 701, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            6,
            &guard,
            &prepared,
        ) == .prepared,
    );
    const calls_before = guard_context.calls;
    const replacement_len = prepared.replacement_len;
    const closed = terminalizePreparedAdmitNoCallback(
        &state,
        &parser,
        &prepared,
    );
    try std.testing.expect(closed == .terminalized);
    try std.testing.expectEqual(
        replacement_len,
        closed.terminalized.quarantine.quarantined_bytes_upper_bound,
    );
    try std.testing.expectEqual(calls_before, guard_context.calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expect(!state.rx_operation_busy);
    try std.testing.expect(prepared.completion == .quarantine_pending);
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .quarantine_pending,
    );
}

test "terminal prepared admit no-callback rejects copy mirror cap and digest drift without mutation" {
    var fixed_bytes: [4096]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    const allocator = fixed.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 702, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            6,
            &guard,
            &prepared,
        ) == .prepared,
    );
    const state_before = state;
    const canonical = prepared;

    var copied = prepared;
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &copied,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));

    prepared.cleanup_replacement = null;
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));
    prepared = canonical;

    prepared.replacement = null;
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));
    prepared = canonical;

    prepared.replacement_len = prepared.resident_cap + 1;
    prepared.cleanup_digest = appendCleanupDigest(&prepared);
    prepared.digest = appendDigest(&prepared);
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));
    prepared = canonical;

    prepared.resident_cap = std.math.maxInt(usize);
    prepared.cleanup_digest = appendCleanupDigest(&prepared);
    prepared.digest = appendDigest(&prepared);
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));
    prepared = canonical;

    prepared.digest[0] +%= 1;
    try std.testing.expect(
        terminalizePreparedAdmitNoCallback(
            &state,
            &parser,
            &prepared,
        ) == .unrecoverable,
    );
    try std.testing.expect(std.meta.eql(state_before, state));
}

test "guarded RX admit rejects invalid or unsealed resident caps before callbacks" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 312, &destination_slot);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    inline for (.{ @as(usize, 0), protocol.max_binary_chunk + protocol.header_size + 1, 7 }) |cap| {
        var prepared: PreparedRxAppend = .{};
        const outcome = prepareAdmitGuarded(
            &state,
            &parser,
            "",
            0,
            cap,
            &guard,
            &prepared,
        );
        switch (outcome) {
            .ordinary_failure => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect(preparedRxAppendPristine(&prepared));
    }
    try std.testing.expectEqual(@as(usize, 0), guard_context.calls);
    try std.testing.expect(parserSealValid(&state, &parser));
}

test "guarded RX admit never frees an allocator alias and reports it once" {
    var backing: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    allocation_context.state = &state;
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 303, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    allocation_context.alias_addr = @intFromPtr(&state);
    allocation_context.mode = .alias;
    const frees_before = allocation_context.free_calls;
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    const outcome = prepareAdmitGuarded(
        &state,
        &parser,
        "def",
        3,
        6,
        &guard,
        &prepared,
    );
    switch (outcome) {
        .allocation_quarantined => |quarantine| {
            try std.testing.expectEqual(
                GuardedAdmitQuarantinePhase.allocation,
                quarantine.phase,
            );
            try std.testing.expectEqual(@as(usize, 6), quarantine.quarantined_bytes_upper_bound);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(frees_before, allocation_context.free_calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expect(prepared.lifecycle == .quarantined);
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) ==
            .ordinary_failure,
    );
    try std.testing.expectEqual(frees_before, allocation_context.free_calls);
}

test "guarded RX admit rejects every local owner alias before typed conversion" {
    const AliasTarget = enum {
        parser,
        prepared,
        input,
        old_backing,
        guard_context,
        partial_state,
    };
    inline for (std.meta.tags(AliasTarget)) |target| {
        var backing: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            @as(u64, 321) + @as(u64, @intFromEnum(target)),
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var guard_context = TestReplacementGuard{};
        const guard = guard_context.guard();
        var prepared: PreparedRxAppend = .{};
        var input = [_]u8{ 'd', 'e', 'f' };
        allocation_context.alias_addr = switch (target) {
            .parser => @intFromPtr(&parser),
            .prepared => @intFromPtr(&prepared),
            .input => @intFromPtr(&input),
            .old_backing => @intFromPtr(parser.buf.items.ptr),
            .guard_context => @intFromPtr(&guard_context),
            .partial_state => @intFromPtr(&state) + 1,
        };
        allocation_context.mode = .alias;
        const frees_before = allocation_context.free_calls;
        const outcome = prepareAdmitGuarded(
            &state,
            &parser,
            &input,
            3,
            6,
            &guard,
            &prepared,
        );
        switch (outcome) {
            .allocation_quarantined => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(frees_before, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    }
}

test "guarded RX admit rejects overflow and external guard denial before pointer use" {
    inline for (.{ false, true }) |guard_rejects| {
        var backing: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            if (guard_rejects) 309 else 308,
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        allocation_context.mode = if (guard_rejects) .normal else .overflow_address;
        var guard_context = TestReplacementGuard{
            .reject_phase = if (guard_rejects) .validate_allocated else null,
        };
        const guard = guard_context.guard();
        const frees_before = allocation_context.free_calls;
        var prepared: PreparedRxAppend = .{};
        const outcome = prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            3,
            6,
            &guard,
            &prepared,
        );
        switch (outcome) {
            .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                @as(usize, 6),
                quarantine.quarantined_bytes_upper_bound,
            ),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(frees_before, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    }
}

test "guarded RX admit rejects wrong guard tags and invalid authority seals" {
    inline for (.{
        TestReplacementGuard.Fault.wrong_capture_tag,
        TestReplacementGuard.Fault.zero_after_allocate,
        TestReplacementGuard.Fault.drift_after_allocate,
    }) |fault| {
        var backing: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            @as(u64, 317) + @as(u64, @intFromEnum(fault)),
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var guard_context = TestReplacementGuard{ .fault = fault };
        const guard = guard_context.guard();
        const frees_before = allocation_context.free_calls;
        var prepared: PreparedRxAppend = .{};
        const outcome = prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            3,
            6,
            &guard,
            &prepared,
        );
        switch (outcome) {
            .allocation_quarantined => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(frees_before, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    }
}

test "guarded RX admit distinguishes seal-preserving OOM from OOM callback drift" {
    inline for (.{ false, true }) |mutates| {
        var backing: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        allocation_context.state = &state;
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            if (mutates) 305 else 304,
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        allocation_context.mode = if (mutates) .oom_mutate_state else .oom;
        var guard_context = TestReplacementGuard{};
        const guard = guard_context.guard();
        var prepared: PreparedRxAppend = .{};
        const outcome = prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            3,
            6,
            &guard,
            &prepared,
        );
        if (mutates) {
            switch (outcome) {
                .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                    @as(usize, 0),
                    quarantine.quarantined_bytes_upper_bound,
                ),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
        } else {
            switch (outcome) {
                .ordinary_failure => |failure| try std.testing.expectEqual(
                    error.OutOfMemory,
                    failure.reason,
                ),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(parserSealValid(&state, &parser));
            try std.testing.expect(preparedRxAppendPristine(&prepared));
        }
        try std.testing.expect(!state.rx_operation_busy);
    }
}

test "guarded RX admit abort tombstones before exact-one replacement free" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 306, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    const frees_before = allocation_context.free_calls;
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
    );
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expect(prepared.lifecycle == .aborted);
    try std.testing.expect(parserSealValid(&state, &parser));
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) ==
            .ordinary_failure,
    );
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expectEqual(
        PreparedAdmitCompletion.ordinary_finished,
        prepared.completion,
    );
    try std.testing.expect(resetFinishedPreparedAdmit(&prepared));
    try std.testing.expect(preparedRxAppendPristine(&prepared));
}

test "guarded RX admit abort free callback drift cannot restore authority" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 328, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    allocation_context.mode = .mutate_parser_after_free;
    const frees_before = allocation_context.free_calls;
    const outcome = abortPreparedAdmitGuarded(&state, &parser, &prepared);
    switch (outcome) {
        .allocation_quarantined => |quarantine| try std.testing.expectEqual(
            @as(usize, 3),
            quarantine.quarantined_bytes_upper_bound,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expectEqual(@as(usize, 0), parser.buf.capacity);
    try std.testing.expectEqual(
        PreparedAdmitCompletion.quarantine_pending,
        prepared.completion,
    );
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) ==
            .ordinary_failure,
    );
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
}

test "legacy RX admit APIs reject guarded replacement tokens in ReleaseFast" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 316, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    try std.testing.expectError(
        error.InvalidState,
        commitPreparedAdmit(&state, &parser, "def", &prepared),
    );
    try std.testing.expectError(
        error.InvalidState,
        abortPreparedAdmit(&state, &prepared),
    );
    try std.testing.expect(state.rx_operation_busy);
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
    );
}

test "guarded RX admit rejects moved and stale tokens without duplicate cleanup" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 327, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    var moved = prepared;
    const frees_before = allocation_context.free_calls;
    try std.testing.expect(
        commitPreparedAdmitGuarded(&state, &parser, "def", &moved) ==
            .ordinary_failure,
    );
    try std.testing.expectEqual(frees_before, allocation_context.free_calls);
    try std.testing.expect(state.rx_operation_busy);
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
    );
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expect(
        commitPreparedAdmitGuarded(&state, &parser, "def", &prepared) ==
            .ordinary_failure,
    );
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
}

test "guard and allocator callbacks observe the RX operation as busy" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 310, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    const allocator_callbacks_before =
        allocation_context.alloc_calls + allocation_context.free_calls;
    allocation_context.reenter = true;
    var guard_context = TestReplacementGuard{
        .state = &state,
        .parser = &parser,
        .reenter = true,
    };
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
    );
    try std.testing.expectEqual(guard_context.calls, guard_context.blocked_reentries);
    try std.testing.expect(guard_context.blocked_reentries >= 6);
    try std.testing.expectEqual(
        allocation_context.alloc_calls + allocation_context.free_calls -
            allocator_callbacks_before,
        allocation_context.blocked_reentries,
    );
    try std.testing.expect(!state.rx_operation_busy);
}

test "cleanup guard source mutation is never adopted or published" {
    inline for (.{ false, true }) |commits| {
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            if (commits) 315 else 314,
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var guard_context = TestReplacementGuard{
            .state = &state,
            .parser = &parser,
            .mutate_parser_phase = .capture_before_cleanup,
        };
        const guard = guard_context.guard();
        var prepared: PreparedRxAppend = .{};
        try std.testing.expect(
            prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
                .prepared,
        );
        const frees_before = allocation_context.free_calls;
        if (commits) {
            const outcome =
                commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
            switch (outcome) {
                .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                    @as(usize, 3),
                    quarantine.quarantined_bytes_upper_bound,
                ),
                else => return error.TestUnexpectedResult,
            }
        } else {
            const outcome =
                abortPreparedAdmitGuarded(&state, &parser, &prepared);
            switch (outcome) {
                .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                    @as(usize, 3),
                    quarantine.quarantined_bytes_upper_bound,
                ),
                else => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
        try std.testing.expectEqual(@as(usize, 0), parser.buf.capacity);
        try std.testing.expect(!state.rx_operation_busy);
    }
}

test "corrupted replacement classification charges the hard cap exactly once" {
    const Corruption = enum { erase_all, lower_length };
    inline for (.{ false, true }) |commits| {
        inline for (.{ Corruption.erase_all, Corruption.lower_length }) |corruption| {
            var backing: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&backing);
            var allocation_context = GuardedAdmitTestAllocator{
                .child = fba.allocator(),
            };
            const allocator = allocation_context.allocator();
            var state = State{ .saved_flags = 7 };
            defer state.deinit(allocator);
            var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
            defer parser.deinit();
            allocation_context.state = &state;
            allocation_context.parser = &parser;
            var destination_slot: usize = 0;
            try bindParserForTest(
                &state,
                &parser,
                338 +
                    @as(usize, @intFromBool(commits)) * 2 +
                    @as(usize, @intFromEnum(corruption)),
                &destination_slot,
            );
            try setResidentCapForTest(&state, &parser, 6);
            var guard_context = TestReplacementGuard{};
            const guard = guard_context.guard();
            var prepared: PreparedRxAppend = .{};
            try std.testing.expect(
                prepareAdmitGuarded(
                    &state,
                    &parser,
                    "def",
                    3,
                    6,
                    &guard,
                    &prepared,
                ) == .prepared,
            );
            switch (corruption) {
                .erase_all => {
                    prepared.replacement = null;
                    prepared.cleanup_replacement = null;
                    prepared.replacement_addr = 0;
                    prepared.replacement_len = 0;
                    prepared.replacement_guard = null;
                    prepared.replacement_authority_seal = .{};
                },
                .lower_length => prepared.replacement_len = 1,
            }
            const frees_before = allocation_context.free_calls;
            if (commits) {
                const outcome =
                    commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
                switch (outcome) {
                    .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                        protocol.max_binary_chunk + protocol.header_size,
                        quarantine.quarantined_bytes_upper_bound,
                    ),
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expect(
                    commitPreparedAdmitGuarded(&state, &parser, "def", &prepared) ==
                        .ordinary_failure,
                );
            } else {
                const outcome =
                    abortPreparedAdmitGuarded(&state, &parser, &prepared);
                switch (outcome) {
                    .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                        protocol.max_binary_chunk + protocol.header_size,
                        quarantine.quarantined_bytes_upper_bound,
                    ),
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expect(
                    abortPreparedAdmitGuarded(&state, &parser, &prepared) ==
                        .ordinary_failure,
                );
            }
            try std.testing.expectEqual(frees_before, allocation_context.free_calls);
            try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
            try std.testing.expect(!state.rx_operation_busy);
        }
    }
}

test "cleanup rejection charges replacement and drifted source exactly once" {
    inline for (.{ false, true }) |commits| {
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            if (commits) 337 else 336,
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var guard_context = TestReplacementGuard{
            .state = &state,
            .parser = &parser,
            .reject_phase = .capture_before_cleanup,
            .mutate_parser_phase = .capture_before_cleanup,
        };
        const guard = guard_context.guard();
        var prepared: PreparedRxAppend = .{};
        try std.testing.expect(
            prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
                .prepared,
        );
        const frees_before = allocation_context.free_calls;
        if (commits) {
            const outcome =
                commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
            switch (outcome) {
                .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                    @as(usize, 9),
                    quarantine.quarantined_bytes_upper_bound,
                ),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(
                commitPreparedAdmitGuarded(&state, &parser, "def", &prepared) ==
                    .ordinary_failure,
            );
        } else {
            const outcome =
                abortPreparedAdmitGuarded(&state, &parser, &prepared);
            switch (outcome) {
                .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                    @as(usize, 9),
                    quarantine.quarantined_bytes_upper_bound,
                ),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(
                abortPreparedAdmitGuarded(&state, &parser, &prepared) ==
                    .ordinary_failure,
            );
        }
        try std.testing.expectEqual(frees_before, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
        try std.testing.expect(!state.rx_operation_busy);
    }
}

test "cleanup callbacks see only a tombstone and cannot rewrite frozen authority" {
    inline for (.{ false, true }) |commits| {
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            if (commits) 334 else 333,
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var prepared: PreparedRxAppend = .{};
        var guard_context = TestReplacementGuard{
            .prepared = &prepared,
            .mutate_prepared_phase = .capture_before_cleanup,
        };
        const guard = guard_context.guard();
        try std.testing.expect(
            prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
                .prepared,
        );
        const frees_before = allocation_context.free_calls;
        if (commits) {
            try std.testing.expect(
                commitPreparedAdmitGuarded(&state, &parser, "def", &prepared) ==
                    .committed,
            );
            try std.testing.expect(prepared.lifecycle == .committed);
            try std.testing.expectEqualStrings("abcdef", parser.buf.items);
        } else {
            try std.testing.expect(
                abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
            );
            try std.testing.expect(prepared.lifecycle == .aborted);
            try std.testing.expectEqualStrings("abc", parser.buf.items);
        }
        try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
        try std.testing.expect(!state.rx_operation_busy);
    }
}

test "guarded RX admit never frees a corrupted cleanup mirror" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 311, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    const frees_before = allocation_context.free_calls;
    prepared.cleanup_replacement = null;
    const outcome = commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
    switch (outcome) {
        .allocation_quarantined => |quarantine| try std.testing.expectEqual(
            protocol.max_binary_chunk + protocol.header_size,
            quarantine.quarantined_bytes_upper_bound,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(frees_before, allocation_context.free_calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expect(prepared.lifecycle == .quarantined);
}

test "guarded RX admit rejects independently corrupted cleanup authorities" {
    const Mutation = enum { primary, allocator, authority_seal };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        var allocation_context = GuardedAdmitTestAllocator{
            .child = fba.allocator(),
        };
        const allocator = allocation_context.allocator();
        var state = State{ .saved_flags = 7 };
        defer state.deinit(allocator);
        var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
        defer parser.deinit();
        allocation_context.state = &state;
        allocation_context.parser = &parser;
        var destination_slot: usize = 0;
        try bindParserForTest(
            &state,
            &parser,
            @as(u64, 329) + @as(u64, @intFromEnum(mutation)),
            &destination_slot,
        );
        try setResidentCapForTest(&state, &parser, 6);
        var guard_context = TestReplacementGuard{};
        const guard = guard_context.guard();
        var prepared: PreparedRxAppend = .{};
        try std.testing.expect(
            prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
                .prepared,
        );
        switch (mutation) {
            .primary => prepared.replacement = null,
            .allocator => prepared.allocator = pristine_rx_append_allocator,
            .authority_seal => prepared.replacement_authority_seal.generation += 1,
        }
        const frees_before = allocation_context.free_calls;
        const outcome =
            commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
        switch (outcome) {
            .allocation_quarantined => |quarantine| try std.testing.expectEqual(
                protocol.max_binary_chunk + protocol.header_size,
                quarantine.quarantined_bytes_upper_bound,
            ),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(frees_before, allocation_context.free_calls);
        try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    }
}

test "guarded RX admit safe-frees replacement but terminalizes source drift" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 313, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var read_buffer = [_]u8{ 'd', 'e', 'f' };
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(
            &state,
            &parser,
            &read_buffer,
            3,
            6,
            &guard,
            &prepared,
        ) == .prepared,
    );
    read_buffer[0] = 'x';
    const frees_before = allocation_context.free_calls;
    const outcome = commitPreparedAdmitGuarded(
        &state,
        &parser,
        &read_buffer,
        &prepared,
    );
    switch (outcome) {
        .allocation_quarantined => |quarantine| try std.testing.expectEqual(
            @as(usize, 0),
            quarantine.quarantined_bytes_upper_bound,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expect(prepared.lifecycle == .aborted);
}

test "guarded RX admit commit reports post-publication cleanup drift" {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var allocation_context = GuardedAdmitTestAllocator{
        .child = fba.allocator(),
    };
    const allocator = allocation_context.allocator();
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = try exactParserForGuardedAdmitTest(allocator, "abc");
    defer parser.deinit();
    allocation_context.state = &state;
    allocation_context.parser = &parser;
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 307, &destination_slot);
    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "def", 3, 6, &guard, &prepared) ==
            .prepared,
    );
    allocation_context.mode = .mutate_parser_after_free;
    const frees_before = allocation_context.free_calls;
    const outcome = commitPreparedAdmitGuarded(&state, &parser, "def", &prepared);
    switch (outcome) {
        .post_commit_quarantined => |quarantine| try std.testing.expectEqual(
            @as(usize, 6),
            quarantine.quarantined_bytes_upper_bound,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(frees_before + 1, allocation_context.free_calls);
    try std.testing.expect(state.rx_provenance.lifecycle == .terminal);
    try std.testing.expectEqual(@as(usize, 0), parser.buf.capacity);
    try std.testing.expect(prepared.lifecycle == .committed);
    try std.testing.expectEqual(
        PreparedAdmitCompletion.quarantine_pending,
        prepared.completion,
    );
}

test "prepared RX append preserves source on prepare failure and commits replacement exactly" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 31, &destination_slot);
    const source_ptr = parser.buf.items.ptr;
    const source_len = parser.buf.items.len;
    var rejected: PreparedRxAppend = .{};
    try std.testing.expectError(
        error.ResidentCap,
        prepareAdmit(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            5,
            &rejected,
        ),
    );
    try std.testing.expectEqual(source_ptr, parser.buf.items.ptr);
    try std.testing.expectEqual(source_len, parser.buf.items.len);
    try std.testing.expectEqual(@as(u64, 3), state.rx_provenance.rx_absolute_next);

    try setResidentCapForTest(&state, &parser, 6);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            6,
            &guard,
            &prepared,
        ) == .prepared,
    );
    try std.testing.expect(
        commitPreparedAdmitGuarded(&state, &parser, "def", &prepared) ==
            .committed,
    );
    try std.testing.expectEqualStrings("abcdef", parser.buf.items);
    try std.testing.expectEqual(@as(u64, 6), state.rx_provenance.rx_absolute_next);
    try std.testing.expect(parserSealValid(&state, &parser));
}

test "prepared RX append uses callback-free spare capacity commit without content hashing" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 32, &destination_slot);
    try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
    try std.testing.expect(resealParserAuthority(&state, &parser));
    const backing = parser.buf.items.ptr;
    var prepared: PreparedRxAppend = .{};
    defer prepared.deinitInternal();
    var read_buffer = [_]u8{ 'x', 'y' };
    try prepareAdmit(
        &state,
        &parser,
        &read_buffer,
        0,
        8,
        &prepared,
    );
    try std.testing.expect(prepared.replacement == null);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &prepared.bytes_digest);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &prepared.unread_digest);
    try commitPreparedAdmit(&state, &parser, &read_buffer, &prepared);
    try std.testing.expectEqual(backing, parser.buf.items.ptr);
    try std.testing.expectEqualStrings("xy", parser.buf.items);
    try std.testing.expectEqual(@as(u64, 2), state.rx_provenance.rx_absolute_next);
}

test "prepared RX append lease rejects reentry and abort clears authority before cleanup" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 33, &destination_slot);
    try setResidentCapForTest(&state, &parser, 1);
    var guard_context = TestReplacementGuard{};
    const guard = guard_context.guard();
    var prepared: PreparedRxAppend = .{};
    try std.testing.expect(
        prepareAdmitGuarded(&state, &parser, "x", 0, 1, &guard, &prepared) ==
            .prepared,
    );
    try std.testing.expect(state.rx_operation_busy);
    try std.testing.expect(maxReadable(&state, &parser, 1, 1) == .invalid);
    var scratch: RxParseScratch = .{};
    try std.testing.expectError(
        error.InvalidState,
        nextOutcomeWithRange(&state, &parser, &scratch),
    );
    try std.testing.expect(
        abortPreparedAdmitGuarded(&state, &parser, &prepared) == .aborted,
    );
    try std.testing.expect(!state.rx_operation_busy);
    try std.testing.expect(prepared.lifecycle == .aborted);
}

test "one-byte RX drip grows replacement capacity geometrically within resident cap" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 34, &destination_slot);
    var backing_changes: usize = 0;
    var previous_capacity = parser.buf.capacity;
    for (0..1024) |_| {
        try admitForTest(&state, &parser, "x", 1024);
        if (parser.buf.capacity != previous_capacity) {
            backing_changes += 1;
            previous_capacity = parser.buf.capacity;
        }
        try std.testing.expect(parser.buf.capacity <= 1024);
    }
    try std.testing.expect(backing_changes <= 8);
    try std.testing.expectEqual(@as(usize, 1024), parser.buf.items.len);
}

test "RX freshness compares identity before half-open offsets" {
    const identity = RxIdentity{
        .attach_instance_id = 5,
        .destination_slot_addr = 9,
    };
    try std.testing.expectEqual(
        Freshness.stale,
        isFresh(
            .{ .identity = identity, .start_absolute = 3, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
    try std.testing.expectEqual(
        Freshness.fresh,
        isFresh(
            .{ .identity = identity, .start_absolute = 5, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
    var other = identity;
    other.attach_instance_id += 1;
    try std.testing.expectEqual(
        Freshness.invalid,
        isFresh(
            .{ .identity = other, .start_absolute = 5, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
}

test "range-aware RX parser preserves partial start and emits contiguous frames" {
    const allocator = std.testing.allocator;
    const first = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "one",
    );
    defer allocator.free(first);
    const second = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .request_id = 2 },
        "two",
    );
    defer allocator.free(second);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 41, &destination_slot);

    try admitForTest(&state, &parser, first[0..1], first.len + second.len);
    var incomplete_scratch: RxParseScratch = .{};
    defer incomplete_scratch.deinit();
    try std.testing.expect(
        (try nextOutcomeWithRange(&state, &parser, &incomplete_scratch)) == .incomplete,
    );
    try std.testing.expectEqual(@as(u64, 0), state.rx_provenance.buffer_start_absolute);
    try admitForTest(&state, &parser, first[1..], first.len + second.len);
    try admitForTest(&state, &parser, second, first.len + second.len);

    var first_scratch: RxParseScratch = .{};
    defer first_scratch.deinit();
    const first_outcome = try nextOutcomeWithRange(&state, &parser, &first_scratch);
    const first_frame = first_outcome.frame;
    defer first_frame.frame.deinit(allocator);
    try std.testing.expect(validateExternalRxFrame(&first_frame));
    try std.testing.expectEqual(@as(u64, 0), first_frame.range.start_absolute);
    try std.testing.expectEqual(@as(u64, @intCast(first.len)), first_frame.range.end_absolute);
    try std.testing.expectEqualStrings("one", first_frame.frame.payload);

    var second_scratch: RxParseScratch = .{};
    defer second_scratch.deinit();
    const second_outcome = try nextOutcomeWithRange(&state, &parser, &second_scratch);
    const second_frame = second_outcome.frame;
    defer second_frame.frame.deinit(allocator);
    try std.testing.expect(validateExternalRxFrame(&second_frame));
    try std.testing.expectEqual(first_frame.range.end_absolute, second_frame.range.start_absolute);
    try std.testing.expectEqual(
        @as(u64, @intCast(first.len + second.len)),
        second_frame.range.end_absolute,
    );
    try std.testing.expectEqualStrings("two", second_frame.frame.payload);
    try std.testing.expectEqual(
        state.rx_provenance.rx_absolute_next,
        state.rx_provenance.buffer_start_absolute,
    );
    try std.testing.expect(parserSealValid(&state, &parser));

    var shifted = second_frame;
    shifted.range.start_absolute += 1;
    shifted.range.end_absolute += 1;
    try std.testing.expect(!validateExternalRxFrame(&shifted));
    var changed_header = second_frame;
    changed_header.frame.header.request_id += 1;
    try std.testing.expect(!validateExternalRxFrame(&changed_header));
    var changed_payload = second_frame;
    changed_payload.frame.payload[0] ^= 1;
    try std.testing.expect(!validateExternalRxFrame(&changed_payload));
    changed_payload.frame.payload[0] ^= 1;
}

test "range-aware RX parser charges optional skipped frame one exact range" {
    const allocator = std.testing.allocator;
    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = @enumFromInt(55001), .flags = protocol.Flags.optional },
        "ignored",
    );
    defer allocator.free(wire);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 42, &destination_slot);
    var scratch: RxParseScratch = .{};
    defer scratch.deinit();
    const outcome = try nextOutcomeWithRange(&state, &parser, &scratch);
    try std.testing.expectEqual(@as(u64, 0), outcome.skipped.start_absolute);
    try std.testing.expectEqual(@as(u64, @intCast(wire.len)), outcome.skipped.end_absolute);
    try std.testing.expectEqual(
        state.rx_provenance.rx_absolute_next,
        state.rx_provenance.buffer_start_absolute,
    );
}

test "range-aware RX parser preflights generation exhaustion before consume" {
    const allocator = std.testing.allocator;
    const wire = try framing.encodeFrame(allocator, .{ .kind = .ping }, "");
    defer allocator.free(wire);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 43, &destination_slot);
    state.rx_provenance.parser_seal.generation = std.math.maxInt(u64);
    state.rx_provenance.parser_seal.digest =
        parserSealDigest(&state.rx_provenance.parser_seal);
    const before_head = parser.head;
    const before_start = state.rx_provenance.buffer_start_absolute;
    var scratch: RxParseScratch = .{};
    try std.testing.expectError(
        error.ArithmeticOverflow,
        nextOutcomeWithRange(&state, &parser, &scratch),
    );
    try std.testing.expectEqual(before_head, parser.head);
    try std.testing.expectEqual(before_start, state.rx_provenance.buffer_start_absolute);
}

test "RX parser readiness is mutation free at empty partial complete and protocol error boundaries" {
    const allocator = std.testing.allocator;
    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 7 },
        "payload",
    );
    defer allocator.free(wire);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 44, &destination_slot);

    try std.testing.expectEqual(
        RxParserReadiness.empty,
        try parserReadiness(&state, &parser),
    );
    try admitForTest(&state, &parser, wire[0..1], wire.len);
    try std.testing.expectEqual(
        RxParserReadiness.incomplete,
        try parserReadiness(&state, &parser),
    );
    try admitForTest(&state, &parser, wire[1..31], wire.len);
    try std.testing.expectEqual(
        RxParserReadiness.incomplete,
        try parserReadiness(&state, &parser),
    );
    try admitForTest(&state, &parser, wire[31..protocol.header_size], wire.len);
    try std.testing.expectEqual(
        RxParserReadiness.incomplete,
        try parserReadiness(&state, &parser),
    );
    try admitForTest(
        &state,
        &parser,
        wire[protocol.header_size..],
        wire.len,
    );
    const before_state = state;
    const before_head = parser.head;
    const before_len = parser.buf.items.len;
    try std.testing.expectEqual(
        RxParserReadiness.complete_or_error,
        try parserReadiness(&state, &parser),
    );
    try std.testing.expect(std.meta.eql(before_state, state));
    try std.testing.expectEqual(before_head, parser.head);
    try std.testing.expectEqual(before_len, parser.buf.items.len);

    parser.buf.items[0] = 0;
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try std.testing.expectEqual(
        RxParserReadiness.complete_or_error,
        try parserReadiness(&state, &parser),
    );
}

test "RX parser readiness rejects busy stale and inconsistent provenance without mutation" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 45, &destination_slot);

    state.rx_operation_busy = true;
    try std.testing.expectError(
        error.InvalidState,
        parserReadiness(&state, &parser),
    );
    state.rx_operation_busy = false;
    state.rx_provenance.rx_absolute_next = 1;
    try std.testing.expect(resealParserAuthority(&state, &parser));
    const before = state;
    try std.testing.expectError(
        error.InvalidDescriptor,
        parserReadiness(&state, &parser),
    );
    try std.testing.expect(std.meta.eql(before, state));
}

test "RX parser readiness treats exact 32-byte terminal outcomes as ready" {
    inline for (.{ "complete", "wrong-major", "oversized", "required-unknown" }) |scenario| {
        var state = State{ .saved_flags = 7 };
        defer state.deinit(std.testing.allocator);
        var parser = framing.FrameParser.init(std.testing.allocator);
        defer parser.deinit();
        var destination_slot: usize = 0;
        try bindParserForTest(&state, &parser, 46, &destination_slot);
        const header = if (std.mem.eql(u8, scenario, "complete"))
            protocol.Header{ .kind = .ping }
        else if (std.mem.eql(u8, scenario, "wrong-major"))
            protocol.Header{ .kind = .ping, .major = protocol.version_major + 1 }
        else if (std.mem.eql(u8, scenario, "required-unknown"))
            protocol.Header{ .kind = @enumFromInt(55002) }
        else
            protocol.Header{
                .kind = .response,
                .payload_len = protocol.max_control_json + 1,
            };
        const bytes = header.encode();
        try admitForTest(&state, &parser, &bytes, bytes.len);
        const before = state;
        try std.testing.expectEqual(
            RxParserReadiness.complete_or_error,
            try parserReadiness(&state, &parser),
        );
        try std.testing.expect(std.meta.eql(before, state));
        try std.testing.expectEqual(@as(usize, 0), parser.head);
    }
}

test "TX teardown callback drift stops remaining frees and charges one sealed transaction" {
    const DriftFree = struct {
        state: *State,
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.tx_queue_generation += 1;
            std.debug.assert(
                self.state.tryDeinit(std.testing.allocator) == .busy,
            );
        }
    };

    resetTxQuarantineForTest();
    var state = State{ .saved_flags = 0 };
    try state.external_tx.ensureTotalCapacityPrecise(
        std.testing.allocator,
        max_tx_frames,
    );
    state.tx_queue_backing_addr = @intFromPtr(state.external_tx.items.ptr);
    state.tx_queue_backing_capacity = state.external_tx.capacity;
    var drift = DriftFree{ .state = &state };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftFree);
    var buffers: [2][protocol.header_size]u8 = undefined;
    for (&buffers, 0..) |*buffer, index| {
        @memset(buffer, @intCast(index + 1));
        var frame = ExternalTxFrame{
            .bytes = buffer,
            .kind = .input_bytes,
            .stream_id = @intCast(index + 1),
            .request_id = 0,
            .activated_at_ns = 10,
            .wire_digest = [_]u8{0} ** 32,
            .descriptor_digest = undefined,
        };
        frame.descriptor_digest = txFrameDescriptorDigest(frame);
        state.external_tx.appendAssumeCapacity(frame);
        state.external_tx_bytes += frame.bytes.len;
    }

    const quarantined_backing = state.external_tx.allocatedSlice();
    state.deinit(std.testing.allocator);
    defer std.testing.allocator.rawFree(
        std.mem.sliceAsBytes(quarantined_backing),
        .of(ExternalTxFrame),
        @returnAddress(),
    );
    try std.testing.expectEqual(@as(usize, 1), drift.calls);
    try std.testing.expectEqual(TxLifecycle.dead, state.tx_lifecycle);
    try std.testing.expectEqual(@as(u64, 1), txQuarantineEventsForTest());
    try std.testing.expectEqual(
        2 * protocol.header_size,
        txQuarantineBytesForTest(),
    );
    state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), drift.calls);
    try std.testing.expectEqual(@as(u64, 1), txQuarantineEventsForTest());
}

test "TX teardown matrix stops at first or last scalar descriptor allocator and reentry drift" {
    const DriftMode = enum {
        state_scalar,
        next_descriptor,
        allocator_identity,
        same_and_cross_reentry,
    };
    const MatrixFree = struct {
        state: *State,
        cross: *State,
        queue_backing: [*]ExternalTxFrame,
        frame_count: usize,
        drift_index: usize,
        mode: DriftMode,
        calls: usize = 0,
        same_result: ?DeinitResult = null,
        cross_result: ?DeinitResult = null,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const index = self.calls;
            self.calls += 1;
            if (index != self.drift_index) return;
            switch (self.mode) {
                .state_scalar => self.state.tx_queue_generation += 1,
                .next_descriptor => {
                    if (index + 1 < self.frame_count) {
                        self.queue_backing[index + 1].bytes.ptr =
                            @ptrFromInt(@alignOf(u8));
                    } else {
                        self.state.tx_queue_generation += 1;
                    }
                },
                .allocator_identity => self.state.tx_allocator_context_len += 1,
                .same_and_cross_reentry => {
                    self.same_result =
                        self.state.tryDeinit(std.testing.allocator);
                    self.cross_result =
                        self.cross.tryDeinit(std.testing.allocator);
                },
            }
        }
    };

    inline for (.{ @as(usize, 1), @as(usize, 64) }) |frame_count| {
        inline for (.{ @as(usize, 0), frame_count - 1 }) |drift_index| {
            inline for (std.meta.tags(DriftMode)) |mode| {
                resetTxQuarantineForTest();
                var state = State{ .saved_flags = 0 };
                try state.external_tx.ensureTotalCapacityPrecise(
                    std.testing.allocator,
                    max_tx_frames,
                );
                state.tx_queue_backing_addr =
                    @intFromPtr(state.external_tx.items.ptr);
                state.tx_queue_backing_capacity =
                    state.external_tx.capacity;
                const quarantined_backing =
                    state.external_tx.allocatedSlice();
                var cross = State{ .saved_flags = 0 };
                var probe = MatrixFree{
                    .state = &state,
                    .cross = &cross,
                    .queue_backing = state.external_tx.items.ptr,
                    .frame_count = frame_count,
                    .drift_index = drift_index,
                    .mode = mode,
                };
                const allocator = probe.allocator();
                state.tx_allocator = allocator;
                state.tx_allocator_context_len = @sizeOf(MatrixFree);
                var buffers: [max_tx_frames][protocol.header_size]u8 = undefined;
                for (buffers[0..frame_count], 0..) |*buffer, index| {
                    @memset(buffer, @intCast(index + 1));
                    var frame = ExternalTxFrame{
                        .bytes = buffer,
                        .kind = .input_bytes,
                        .stream_id = @intCast(index + 1),
                        .request_id = 0,
                        .activated_at_ns = 10,
                        .wire_digest = [_]u8{0} ** 32,
                        .descriptor_digest = undefined,
                    };
                    frame.descriptor_digest =
                        txFrameDescriptorDigest(frame);
                    state.external_tx.appendAssumeCapacity(frame);
                    state.external_tx_bytes += frame.bytes.len;
                }

                try std.testing.expectEqual(
                    DeinitResult.cleaned,
                    state.tryDeinit(std.testing.allocator),
                );
                try std.testing.expectEqual(
                    drift_index + 1,
                    probe.calls,
                );
                try std.testing.expectEqual(
                    TxLifecycle.dead,
                    state.tx_lifecycle,
                );
                try std.testing.expectEqual(
                    @as(u64, 1),
                    txQuarantineEventsForTest(),
                );
                try std.testing.expectEqual(
                    frame_count * protocol.header_size,
                    txQuarantineBytesForTest(),
                );
                if (mode == .same_and_cross_reentry) {
                    try std.testing.expectEqual(
                        DeinitResult.busy,
                        probe.same_result.?,
                    );
                    try std.testing.expectEqual(
                        DeinitResult.busy,
                        probe.cross_result.?,
                    );
                }
                try std.testing.expectEqual(
                    DeinitResult.already_dead,
                    state.tryDeinit(std.testing.allocator),
                );
                try std.testing.expectEqual(
                    drift_index + 1,
                    probe.calls,
                );
                try std.testing.expectEqual(
                    DeinitResult.cleaned,
                    cross.tryDeinit(std.testing.allocator),
                );
                std.testing.allocator.rawFree(
                    std.mem.sliceAsBytes(quarantined_backing),
                    .of(ExternalTxFrame),
                    @returnAddress(),
                );
            }
        }
    }
}

test "TX teardown permits unrelated states to clean concurrently without quarantine" {
    const BarrierFree = struct {
        entered: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),
        block: bool,
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (!self.block) return;
            self.entered.store(true, .release);
            while (!self.release.load(.acquire))
                std.atomic.spinLoopHint();
        }
    };
    const Runner = struct {
        const Context = struct {
            state: *State,
            result: ?DeinitResult = null,
        };

        fn run(context: *Context) void {
            context.result =
                context.state.tryDeinit(std.testing.allocator);
        }
    };

    resetTxQuarantineForTest();
    var entered: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    var states = [2]State{
        .{ .saved_flags = 0 },
        .{ .saved_flags = 0 },
    };
    var probes = [2]BarrierFree{
        .{
            .entered = &entered,
            .release = &release,
            .block = true,
        },
        .{
            .entered = &entered,
            .release = &release,
            .block = false,
        },
    };
    var buffers: [2][protocol.header_size]u8 = undefined;
    for (&states, &probes, &buffers, 0..) |*state, *probe, *buffer, index| {
        try state.external_tx.ensureTotalCapacityPrecise(
            std.testing.allocator,
            max_tx_frames,
        );
        state.tx_queue_backing_addr =
            @intFromPtr(state.external_tx.items.ptr);
        state.tx_queue_backing_capacity = state.external_tx.capacity;
        state.tx_allocator = probe.allocator();
        state.tx_allocator_context_len = @sizeOf(BarrierFree);
        @memset(buffer, @intCast(index + 1));
        var frame = ExternalTxFrame{
            .bytes = buffer,
            .kind = .input_bytes,
            .stream_id = @intCast(index + 1),
            .request_id = 0,
            .activated_at_ns = 10,
            .wire_digest = [_]u8{0} ** 32,
            .descriptor_digest = undefined,
        };
        frame.descriptor_digest = txFrameDescriptorDigest(frame);
        state.external_tx.appendAssumeCapacity(frame);
        state.external_tx_bytes = frame.bytes.len;
    }
    var context = Runner.Context{ .state = &states[0] };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&context});
    errdefer {
        release.store(true, .release);
        thread.join();
    }
    while (!entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        states[1].tryDeinit(std.testing.allocator),
    );
    release.store(true, .release);
    thread.join();
    try std.testing.expectEqual(DeinitResult.cleaned, context.result.?);
    try std.testing.expectEqual(@as(usize, 1), probes[0].calls);
    try std.testing.expectEqual(@as(usize, 1), probes[1].calls);
    try std.testing.expectEqual(@as(u64, 0), txQuarantineEventsForTest());
}

test "TX teardown serializes the same state across threads without double free" {
    const BarrierFree = struct {
        entered: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),
        calls: std.atomic.Value(usize) = .init(0),

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.calls.fetchAdd(1, .acq_rel);
            self.entered.store(true, .release);
            while (!self.release.load(.acquire))
                std.atomic.spinLoopHint();
        }
    };
    const Runner = struct {
        const Context = struct {
            state: *State,
            result: ?DeinitResult = null,
        };

        fn run(context: *Context) void {
            context.result =
                context.state.tryDeinit(std.testing.allocator);
        }
    };

    resetTxQuarantineForTest();
    var entered: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    var state = State{ .saved_flags = 0 };
    try state.external_tx.ensureTotalCapacityPrecise(
        std.testing.allocator,
        max_tx_frames,
    );
    state.tx_queue_backing_addr =
        @intFromPtr(state.external_tx.items.ptr);
    state.tx_queue_backing_capacity = state.external_tx.capacity;
    var probe = BarrierFree{
        .entered = &entered,
        .release = &release,
    };
    state.tx_allocator = probe.allocator();
    state.tx_allocator_context_len = @sizeOf(BarrierFree);
    var buffer: [protocol.header_size]u8 = undefined;
    @memset(&buffer, 0x5a);
    var frame = ExternalTxFrame{
        .bytes = &buffer,
        .kind = .input_bytes,
        .stream_id = 1,
        .request_id = 0,
        .activated_at_ns = 10,
        .wire_digest = [_]u8{0} ** 32,
        .descriptor_digest = undefined,
    };
    frame.descriptor_digest = txFrameDescriptorDigest(frame);
    state.external_tx.appendAssumeCapacity(frame);
    state.external_tx_bytes = frame.bytes.len;

    var context = Runner.Context{ .state = &state };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&context});
    errdefer {
        release.store(true, .release);
        thread.join();
    }
    while (!entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(
        DeinitResult.busy,
        state.tryDeinit(std.testing.allocator),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls.load(.acquire));
    release.store(true, .release);
    thread.join();
    try std.testing.expectEqual(DeinitResult.cleaned, context.result.?);
    try std.testing.expectEqual(@as(usize, 1), probe.calls.load(.acquire));
    try std.testing.expectEqual(
        DeinitResult.already_dead,
        state.tryDeinit(std.testing.allocator),
    );
    try std.testing.expectEqual(@as(u64, 0), txQuarantineEventsForTest());
}

test "TX operation claim makes void teardown a bounded no-op and typed teardown busy" {
    const Runner = struct {
        const Context = struct {
            state: *State,
            started: *std.atomic.Value(bool),
            finished: *std.atomic.Value(bool),
        };

        fn run(context: *Context) void {
            context.started.store(true, .release);
            context.state.deinit(std.testing.allocator);
            context.finished.store(true, .release);
        }
    };

    var state = State{ .saved_flags = 0 };
    try std.testing.expect(state.acquireTxOperation());
    try std.testing.expect(state.txOperationHeldByCurrentThread());
    try std.testing.expectEqual(
        DeinitResult.busy,
        state.tryDeinit(std.testing.allocator),
    );
    var started: std.atomic.Value(bool) = .init(false);
    var finished: std.atomic.Value(bool) = .init(false);
    var context = Runner.Context{
        .state = &state,
        .started = &started,
        .finished = &finished,
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&context});
    errdefer {
        _ = state.releaseTxOperation();
        thread.join();
    }
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    while (!finished.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(state.txOperationHeldByCurrentThread());
    try std.testing.expect(state.releaseTxOperation());
    thread.join();
    try std.testing.expect(finished.load(.acquire));
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        state.tryDeinit(std.testing.allocator),
    );
    try std.testing.expectEqual(
        DeinitResult.already_dead,
        state.tryDeinit(std.testing.allocator),
    );
}

test "TX close request between release load and CAS is observed atomically" {
    const Hook = struct {
        fn run(raw: *anyopaque) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.requestTxClose();
        }
    };

    var state = State{ .saved_flags = 0 };
    try std.testing.expect(state.acquireTxOperation());
    try std.testing.expectEqual(
        true,
        state.releaseTxOperationAndObserveCloseWithHook(
            Hook.run,
            @ptrCast(&state),
        ).?,
    );
    try std.testing.expect(state.txCloseRequested());
    try std.testing.expect(!state.acquireTxOperation());
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        state.tryDeinit(std.testing.allocator),
    );
}

test "TX cleanup transfer rejects an independently reserved destination" {
    const Runner = struct {
        const Context = struct {
            state: *State,
            ready: *std.atomic.Value(bool),
            release: *std.atomic.Value(bool),
            reserve_result: ?DeinitReservationResult = null,
            finish_result: ?DeinitResult = null,
        };

        fn run(context: *Context) void {
            context.reserve_result = context.state.reserveDeinit();
            context.ready.store(true, .release);
            while (!context.release.load(.acquire))
                std.atomic.spinLoopHint();
            context.finish_result =
                context.state.finishReservedDeinit(std.testing.allocator);
        }
    };

    var source = State{ .saved_flags = 0 };
    var destination = State{ .saved_flags = 0 };
    var ready: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    var context = Runner.Context{
        .state = &destination,
        .ready = &ready,
        .release = &release,
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&context});
    errdefer {
        release.store(true, .release);
        thread.join();
    }
    while (!ready.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(
        DeinitReservationResult.reserved,
        context.reserve_result.?,
    );
    try std.testing.expectEqual(
        DeinitReservationResult.reserved,
        source.reserveDeinit(),
    );
    try std.testing.expect(!source.transferReservedDeinit(&destination));
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        source.finishReservedDeinit(std.testing.allocator),
    );
    release.store(true, .release);
    thread.join();
    try std.testing.expectEqual(DeinitResult.cleaned, context.finish_result.?);
}

test "TX cleanup transfer rejects destination during reservation publication" {
    const Runner = struct {
        const Context = struct {
            state: *State,
            entered: *std.atomic.Value(bool),
            release: *std.atomic.Value(bool),
            reserve_result: ?DeinitReservationResult = null,
            finish_result: ?DeinitResult = null,
        };

        fn hook(raw: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.entered.store(true, .release);
            while (!context.release.load(.acquire))
                std.atomic.spinLoopHint();
        }

        fn run(context: *Context) void {
            context.reserve_result = context.state.reserveDeinitWithHook(
                hook,
                @ptrCast(context),
            );
            context.finish_result =
                context.state.finishReservedDeinit(std.testing.allocator);
        }
    };

    var source = State{ .saved_flags = 0 };
    var destination = State{ .saved_flags = 0 };
    var entered: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    var context = Runner.Context{
        .state = &destination,
        .entered = &entered,
        .release = &release,
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&context});
    errdefer {
        release.store(true, .release);
        thread.join();
    }
    while (!entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(
        DeinitReservationResult.reserved,
        source.reserveDeinit(),
    );
    try std.testing.expect(!source.transferReservedDeinit(&destination));
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        source.finishReservedDeinit(std.testing.allocator),
    );
    release.store(true, .release);
    thread.join();
    try std.testing.expectEqual(
        DeinitReservationResult.reserved,
        context.reserve_result.?,
    );
    try std.testing.expectEqual(DeinitResult.cleaned, context.finish_result.?);
}

test "TX cleanup reservation cancel restores close-only state" {
    var state = State{ .saved_flags = 0 };
    state.requestTxClose();
    try std.testing.expectEqual(
        DeinitReservationResult.reserved,
        state.reserveDeinit(),
    );
    try std.testing.expect(state.cancelReservedDeinit());
    try std.testing.expect(state.txCloseRequested());
    try std.testing.expect(!state.acquireTxOperation());
    try std.testing.expectEqual(
        DeinitResult.cleaned,
        state.tryDeinit(std.testing.allocator),
    );
}

test "TX teardown detects queue-backing free callback drift after exact cleanup" {
    const FrameFree = struct {
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const BackingDrift = struct {
        parent: std.mem.Allocator,
        state: *State,
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
            raw: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.parent.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.free_calls += 1;
            self.parent.rawFree(memory, alignment, ret_addr);
            self.state.tx_queue_generation += 1;
        }
    };

    resetTxQuarantineForTest();
    var state = State{ .saved_flags = 0 };
    var backing = BackingDrift{
        .parent = std.testing.allocator,
        .state = &state,
    };
    const backing_allocator = backing.allocator();
    try state.external_tx.ensureTotalCapacityPrecise(
        backing_allocator,
        max_tx_frames,
    );
    state.tx_queue_backing_addr = @intFromPtr(state.external_tx.items.ptr);
    state.tx_queue_backing_capacity = state.external_tx.capacity;
    var frame_free = FrameFree{};
    state.tx_allocator = frame_free.allocator();
    state.tx_allocator_context_len = @sizeOf(FrameFree);
    var buffer: [protocol.header_size]u8 = undefined;
    @memset(&buffer, 0x5a);
    var frame = ExternalTxFrame{
        .bytes = &buffer,
        .kind = .input_bytes,
        .stream_id = 1,
        .request_id = 0,
        .activated_at_ns = 10,
        .wire_digest = [_]u8{0} ** 32,
        .descriptor_digest = undefined,
    };
    frame.descriptor_digest = txFrameDescriptorDigest(frame);
    state.external_tx.appendAssumeCapacity(frame);
    state.external_tx_bytes = frame.bytes.len;

    try std.testing.expectEqual(
        DeinitResult.cleaned,
        state.tryDeinit(backing_allocator),
    );
    try std.testing.expectEqual(@as(usize, 1), frame_free.calls);
    try std.testing.expectEqual(@as(usize, 1), backing.free_calls);
    try std.testing.expectEqual(@as(u64, 1), txQuarantineEventsForTest());
    try std.testing.expectEqual(
        protocol.header_size,
        txQuarantineBytesForTest(),
    );
    try std.testing.expectEqual(
        DeinitResult.already_dead,
        state.tryDeinit(backing_allocator),
    );
    try std.testing.expectEqual(@as(usize, 1), backing.free_calls);
}

test "TX teardown rejects exact and partial-overlap frozen graphs without a frame free" {
    const FrameFree = struct {
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    inline for (.{ false, true }) |partial_overlap| {
        resetTxQuarantineForTest();
        var state = State{ .saved_flags = 0 };
        try state.external_tx.ensureTotalCapacityPrecise(
            std.testing.allocator,
            max_tx_frames,
        );
        state.tx_queue_backing_addr = @intFromPtr(state.external_tx.items.ptr);
        state.tx_queue_backing_capacity = state.external_tx.capacity;
        var frame_free = FrameFree{};
        state.tx_allocator = frame_free.allocator();
        state.tx_allocator_context_len = @sizeOf(FrameFree);
        var buffer: [protocol.header_size + 16]u8 = undefined;
        @memset(&buffer, 0x5a);
        const slices = if (partial_overlap)
            [2][]u8{
                buffer[0..protocol.header_size],
                buffer[16 .. 16 + protocol.header_size],
            }
        else
            [2][]u8{
                buffer[0..protocol.header_size],
                buffer[0..protocol.header_size],
            };
        for (slices, 0..) |bytes, index| {
            var frame = ExternalTxFrame{
                .bytes = bytes,
                .kind = .input_bytes,
                .stream_id = @intCast(index + 1),
                .request_id = 0,
                .activated_at_ns = 10,
                .wire_digest = [_]u8{0} ** 32,
                .descriptor_digest = undefined,
            };
            frame.descriptor_digest = txFrameDescriptorDigest(frame);
            state.external_tx.appendAssumeCapacity(frame);
            state.external_tx_bytes += frame.bytes.len;
        }

        try std.testing.expectEqual(
            DeinitResult.cleaned,
            state.tryDeinit(std.testing.allocator),
        );
        try std.testing.expectEqual(@as(usize, 0), frame_free.calls);
        try std.testing.expectEqual(@as(u64, 1), txQuarantineEventsForTest());
        try std.testing.expectEqual(
            2 * protocol.header_size,
            txQuarantineBytesForTest(),
        );
        try std.testing.expectEqual(
            DeinitResult.already_dead,
            state.tryDeinit(std.testing.allocator),
        );
        try std.testing.expectEqual(@as(usize, 0), frame_free.calls);
    }
}

test "TX teardown at exhausted generation frees one and sixty-four frames exactly once" {
    const FrameFree = struct {
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            _: *anyopaque,
            _: usize,
            _: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn resize(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }

        fn free(
            raw: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    inline for (.{ @as(usize, 1), @as(usize, 64) }) |frame_count| {
        resetTxQuarantineForTest();
        var state = State{ .saved_flags = 0 };
        try state.external_tx.ensureTotalCapacityPrecise(
            std.testing.allocator,
            max_tx_frames,
        );
        state.tx_queue_backing_addr = @intFromPtr(state.external_tx.items.ptr);
        state.tx_queue_backing_capacity = state.external_tx.capacity;
        state.tx_queue_generation = std.math.maxInt(u64);
        var frame_free = FrameFree{};
        state.tx_allocator = frame_free.allocator();
        state.tx_allocator_context_len = @sizeOf(FrameFree);
        var buffers: [max_tx_frames][protocol.header_size]u8 = undefined;
        for (buffers[0..frame_count], 0..) |*buffer, index| {
            @memset(buffer, @intCast(index + 1));
            var frame = ExternalTxFrame{
                .bytes = buffer,
                .kind = .input_bytes,
                .stream_id = @intCast(index + 1),
                .request_id = 0,
                .activated_at_ns = 10,
                .wire_digest = [_]u8{0} ** 32,
                .descriptor_digest = undefined,
            };
            frame.descriptor_digest = txFrameDescriptorDigest(frame);
            state.external_tx.appendAssumeCapacity(frame);
            state.external_tx_bytes += frame.bytes.len;
        }

        try std.testing.expectEqual(
            DeinitResult.cleaned,
            state.tryDeinit(std.testing.allocator),
        );
        try std.testing.expectEqual(frame_count, frame_free.calls);
        try std.testing.expectEqual(@as(u64, 0), txQuarantineEventsForTest());
        try std.testing.expectEqual(
            DeinitResult.already_dead,
            state.tryDeinit(std.testing.allocator),
        );
        try std.testing.expectEqual(frame_count, frame_free.calls);
    }
}
