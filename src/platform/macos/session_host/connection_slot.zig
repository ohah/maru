//! OS-neutral bounded connection-slot core for the session-host reactor.
//!
//! fd/poll/read/write는 platform adapter가 소유한다. 이 모듈은 stable key, queue memory, turn fairness,
//! partial-frame deadline, upgrade drain 가능 여부만 결정해 serial daemon을 multi-fd로 바꾸기 전에 불변식을 고정한다.

const std = @import("std");

pub const max_connections: usize = 32;
pub const per_slot_bytes: usize = 18 * 1024 * 1024;
/// One subscription may transiently own the old 16 MiB screen/256 KiB metadata base and a
/// worst-case replacement at the same time. Queue limits remain independently bounded below, while
/// this combined ceiling prevents one connection from composing both maxima without a cap.
pub const base_update_max_bytes: usize = 16 * 1024 * 1024 + 256 * 1024;
pub const base_steady_per_slot_bytes: usize = 2 * base_update_max_bytes;
pub const base_per_slot_bytes: usize = base_steady_per_slot_bytes + base_update_max_bytes;
pub const total_per_slot_bytes: usize = base_per_slot_bytes + per_slot_bytes;
pub const screen_soft_bytes: usize = 8 * 1024 * 1024;
/// 16 MiB viewport payload plus at most sixteen charged MRSH frame headers/alignment.
pub const resync_batch_bytes: usize = 17 * 1024 * 1024;
pub const control_reserve_bytes: usize = 512 * 1024;
pub const screen_low_water_bytes: usize = 4 * 1024 * 1024;
pub const global_bytes: usize = 128 * 1024 * 1024;
pub const base_replacement_headroom_bytes: usize = base_update_max_bytes;
pub const shared_hard_bytes: usize = global_bytes - max_connections * control_reserve_bytes;
pub const shared_steady_bytes: usize = shared_hard_bytes - base_replacement_headroom_bytes;
pub const max_chunks_per_slot: usize = 4096;
pub const control_chunk_reserve: usize = 64;
pub const max_screen_trackers_per_slot: usize = 256;
comptime {
    if (max_screen_trackers_per_slot != @import("client_queue_limits.zig").max_recovery_streams)
        @compileError("client recovery and reactor stream caps diverged");
}
pub const turn_bytes: usize = 1024 * 1024;
pub const turn_frames: usize = 64;
pub const partial_deadline_ns: u64 = 10 * std.time.ns_per_s;
pub const partial_absolute_deadline_ns: u64 = 30 * std.time.ns_per_s;

comptime {
    if (screen_soft_bytes + control_reserve_bytes > per_slot_bytes)
        @compileError("screen soft limit and control reserve exceed per-slot cap");
    if (resync_batch_bytes + control_reserve_bytes > per_slot_bytes)
        @compileError("resync batch and control reserve exceed per-slot cap");
    if (per_slot_bytes * max_connections < global_bytes)
        @compileError("global cap cannot exceed the sum of all slot caps");
    if (base_replacement_headroom_bytes >= shared_hard_bytes)
        @compileError("base replacement headroom consumes the shared budget");
}

pub const ConnectionKey = struct {
    monotonic_id: u64,
    slot_generation: u64,

    pub fn valid(self: ConnectionKey) bool {
        return self.monotonic_id != 0 and self.slot_generation != 0;
    }
};

pub const KeyAllocator = struct {
    next_id: u64 = 1,

    pub fn allocate(self: *KeyAllocator, slot_generation: u64) error{Exhausted}!ConnectionKey {
        if (slot_generation == 0 or self.next_id == 0) return error.Exhausted;
        const id = self.next_id;
        self.next_id = std.math.add(u64, id, 1) catch 0;
        return .{ .monotonic_id = id, .slot_generation = slot_generation };
    }
};

const SlotTable = struct {
    const Entry = struct {
        key: ?ConnectionKey = null,
        generation: u64 = 1,
        retired: bool = false,
    };

    entries: [max_connections]Entry = [_]Entry{.{}} ** max_connections,
    keys: KeyAllocator = .{},
    active_count: usize = 0,
    cursor: usize = 0,

    pub const Admission = struct {
        index: usize,
        key: ConnectionKey,
    };

    pub fn admit(self: *SlotTable) error{ Full, Exhausted }!Admission {
        if (self.active_count == max_connections) return error.Full;
        for (self.entries, 0..) |entry, index| {
            if (entry.key != null or entry.retired) continue;
            const key = self.keys.allocate(entry.generation) catch return error.Exhausted;
            self.entries[index].key = key;
            self.active_count += 1;
            return .{ .index = index, .key = key };
        }
        return error.Exhausted;
    }

    pub fn close(self: *SlotTable, admission: Admission) error{Stale}!void {
        if (admission.index >= max_connections or
            self.entries[admission.index].key == null or
            !std.meta.eql(self.entries[admission.index].key.?, admission.key))
            return error.Stale;
        self.entries[admission.index].key = null;
        self.entries[admission.index].generation = std.math.add(
            u64,
            self.entries[admission.index].generation,
            1,
        ) catch blk: {
            self.entries[admission.index].retired = true;
            break :blk self.entries[admission.index].generation;
        };
        self.active_count -= 1;
    }

    /// 한 호출에 ready slot 하나만 선택하고 cursor를 반드시 전진시킨다.
    pub fn nextReady(self: *SlotTable, ready: *const [max_connections]bool) ?Admission {
        if (self.active_count == 0) return null;
        var checked: usize = 0;
        while (checked < max_connections) : (checked += 1) {
            const index = (self.cursor + checked) % max_connections;
            const key = self.entries[index].key orelse continue;
            if (!ready[index]) continue;
            self.cursor = (index + 1) % max_connections;
            return .{ .index = index, .key = key };
        }
        return null;
    }
};

pub const GlobalBudget = struct {
    resident_bytes: usize = 0,
    shared_bytes: usize = 0,
    prepared_base_bytes: usize = 0,
    prepared_reclaim_bytes: usize = 0,
    peak_resident_bytes: usize = 0,
    peak_shared_bytes: usize = 0,
    peak_prepared_base_bytes: usize = 0,
    peak_prepared_reclaim_bytes: usize = 0,
    peak_slot_queue_bytes: usize = 0,
    peak_slot_base_bytes: usize = 0,
    peak_slot_control_bytes: usize = 0,
    peak_slot_total_bytes: usize = 0,

    fn recordPeak(self: *GlobalBudget) void {
        self.peak_resident_bytes = @max(self.peak_resident_bytes, self.resident_bytes);
        self.peak_shared_bytes = @max(self.peak_shared_bytes, self.shared_bytes);
        self.peak_prepared_base_bytes =
            @max(self.peak_prepared_base_bytes, self.prepared_base_bytes);
        self.peak_prepared_reclaim_bytes =
            @max(self.peak_prepared_reclaim_bytes, self.prepared_reclaim_bytes);
    }

    fn recordSlotPeak(
        self: *GlobalBudget,
        queue_bytes: usize,
        base_bytes: usize,
        control_bytes: usize,
    ) void {
        self.peak_slot_queue_bytes = @max(self.peak_slot_queue_bytes, queue_bytes);
        self.peak_slot_base_bytes = @max(self.peak_slot_base_bytes, base_bytes);
        self.peak_slot_control_bytes = @max(self.peak_slot_control_bytes, control_bytes);
        self.peak_slot_total_bytes =
            @max(self.peak_slot_total_bytes, queue_bytes +| base_bytes);
    }

    fn reserveScreen(self: *GlobalBudget, amount: usize) bool {
        const next = std.math.add(usize, self.resident_bytes, amount) catch return false;
        if (next > global_bytes) return false;
        const next_shared = std.math.add(usize, self.shared_bytes, amount) catch return false;
        if (next_shared > shared_hard_bytes) return false;
        if (self.prepared_reclaim_bytes > next_shared) return false;
        if (next_shared - self.prepared_reclaim_bytes > shared_steady_bytes)
            return false;
        self.resident_bytes = next;
        self.shared_bytes = next_shared;
        self.recordPeak();
        return true;
    }

    fn reserveControl(self: *GlobalBudget, old_slot_control: usize, amount: usize) bool {
        const next = std.math.add(usize, self.resident_bytes, amount) catch return false;
        if (next > global_bytes) return false;
        const new_slot_control = std.math.add(usize, old_slot_control, amount) catch return false;
        const old_shared = old_slot_control -| control_reserve_bytes;
        const new_shared = new_slot_control -| control_reserve_bytes;
        const shared_delta = new_shared - old_shared;
        const next_shared = std.math.add(usize, self.shared_bytes, shared_delta) catch return false;
        if (next_shared > shared_hard_bytes) return false;
        if (self.prepared_reclaim_bytes > next_shared) return false;
        if (next_shared - self.prepared_reclaim_bytes > shared_steady_bytes)
            return false;
        self.resident_bytes = next;
        self.shared_bytes = next_shared;
        self.recordPeak();
        return true;
    }

    fn releaseScreen(self: *GlobalBudget, amount: usize) void {
        std.debug.assert(amount <= self.resident_bytes);
        self.resident_bytes -= amount;
        std.debug.assert(amount <= self.shared_bytes);
        self.shared_bytes -= amount;
    }

    fn releaseControl(self: *GlobalBudget, old_slot_control: usize, amount: usize) void {
        std.debug.assert(amount <= old_slot_control and amount <= self.resident_bytes);
        const new_slot_control = old_slot_control - amount;
        const old_shared = old_slot_control -| control_reserve_bytes;
        const new_shared = new_slot_control -| control_reserve_bytes;
        self.resident_bytes -= amount;
        self.shared_bytes -= old_shared - new_shared;
    }

    fn reserveBase(self: *GlobalBudget, old_retained: usize, amount: usize) bool {
        if (amount == 0 or amount > base_update_max_bytes) return false;
        if (old_retained > self.shared_bytes) return false;
        const next = std.math.add(usize, self.resident_bytes, amount) catch return false;
        if (next > global_bytes) return false;
        const next_shared = std.math.add(usize, self.shared_bytes, amount) catch return false;
        if (next_shared > shared_hard_bytes) return false;
        const future_steady = std.math.add(
            usize,
            self.shared_bytes - old_retained,
            amount,
        ) catch return false;
        if (future_steady > shared_steady_bytes) return false;
        const next_prepared = std.math.add(usize, self.prepared_base_bytes, amount) catch
            return false;
        if (next_prepared > base_replacement_headroom_bytes) return false;
        self.resident_bytes = next;
        self.shared_bytes = next_shared;
        self.prepared_base_bytes = next_prepared;
        self.prepared_reclaim_bytes = std.math.add(
            usize,
            self.prepared_reclaim_bytes,
            old_retained,
        ) catch unreachable;
        self.recordPeak();
        return true;
    }

    fn finishBase(
        self: *GlobalBudget,
        reserved: usize,
        old_retained: usize,
        released: usize,
    ) void {
        std.debug.assert(reserved <= self.prepared_base_bytes);
        std.debug.assert(old_retained <= self.prepared_reclaim_bytes);
        self.prepared_base_bytes -= reserved;
        self.prepared_reclaim_bytes -= old_retained;
        if (released != 0) self.releaseScreen(released);
    }
};

pub const QueueClass = enum { screen, control };
pub const EnqueueError = error{ ScreenInvalidated, SlotLimit, GlobalLimit, ChunkLimit, OutOfMemory };
pub const ScreenState = enum { valid, invalidated, resync_pending, resync_draining };

pub const ScreenTracker = struct {
    state: ScreenState = .valid,
    resident_bytes: usize = 0,
    retained_base_bytes: usize = 0,
    prepared_base_bytes: usize = 0,
    base_update_generation: u64 = 1,
    base_update_prepared: bool = false,
    last_resync_attempt_ns: ?u64 = null,
    global_pressure_retry_after_ns: u64 = 0,
};

pub const resync_retry_backoff_ns: u64 = std.time.ns_per_s;

pub const ScreenTrackerKey = struct {
    owner: ConnectionKey,
    index: u16,
    generation: u64,
};

pub const BaseReservation = struct {
    tracker: ScreenTrackerKey,
    generation: u64,
};

const ScreenTrackerEntry = struct {
    tracker: ?*ScreenTracker = null,
    generation: u64 = 1,
    retired: bool = false,
};

const Chunk = struct {
    bytes: []u8,
    offset: usize = 0,
    class: QueueClass,
    screen_tracker_index: ?usize = null,
};

pub const Slot = struct {
    allocator: std.mem.Allocator,
    global: *GlobalBudget,
    key: ConnectionKey,
    generation: u64,
    chunks: []Chunk,
    chunk_head: usize = 0,
    chunk_len: usize = 0,
    pending_bytes: usize = 0,
    resident_bytes: usize = 0,
    base_resident_bytes: usize = 0,
    control_resident_bytes: usize = 0,
    screen_trackers: [max_screen_trackers_per_slot]ScreenTrackerEntry =
        [_]ScreenTrackerEntry{.{}} ** max_screen_trackers_per_slot,
    read_partial_started_ns: ?u64 = null,
    read_partial_progress_ns: ?u64 = null,
    write_partial_started_ns: ?u64 = null,
    write_partial_progress_ns: ?u64 = null,
    write_stall_observed: bool = false,
    in_flight_dispatch: usize = 0,
    attached_streams: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        global: *GlobalBudget,
        key: ConnectionKey,
    ) error{ InvalidKey, OutOfMemory }!Slot {
        if (!key.valid()) return error.InvalidKey;
        const chunks = allocator.alloc(Chunk, max_chunks_per_slot) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .global = global,
            .key = key,
            .generation = key.slot_generation,
            .chunks = chunks,
        };
    }

    fn recordPeak(self: *Slot) void {
        self.global.recordSlotPeak(
            self.resident_bytes,
            self.base_resident_bytes,
            self.control_resident_bytes,
        );
    }

    pub fn deinit(self: *Slot) void {
        for (0..self.chunk_len) |offset| {
            const chunk = self.chunks[(self.chunk_head + offset) % max_chunks_per_slot];
            if (chunk.class == .screen) {
                self.global.releaseScreen(chunk.bytes.len);
                self.screen_trackers[chunk.screen_tracker_index.?].tracker.?.resident_bytes -=
                    chunk.bytes.len;
            } else {
                self.global.releaseControl(self.control_resident_bytes, chunk.bytes.len);
                self.control_resident_bytes -= chunk.bytes.len;
            }
            self.allocator.free(chunk.bytes);
        }
        for (self.screen_trackers) |entry| {
            const tracker = entry.tracker orelse continue;
            const base_charge = tracker.retained_base_bytes + tracker.prepared_base_bytes;
            if (base_charge != 0) {
                if (tracker.base_update_prepared)
                    self.global.finishBase(
                        tracker.prepared_base_bytes,
                        tracker.retained_base_bytes,
                        base_charge,
                    )
                else
                    self.global.releaseScreen(base_charge);
                self.base_resident_bytes -= base_charge;
            }
            std.debug.assert(tracker.resident_bytes == 0);
            self.allocator.destroy(tracker);
        }
        std.debug.assert(self.base_resident_bytes == 0);
        self.allocator.free(self.chunks);
        self.* = undefined;
    }

    pub fn createScreenTracker(self: *Slot) error{ Full, OutOfMemory }!ScreenTrackerKey {
        for (&self.screen_trackers, 0..) |*entry, index| {
            if (entry.tracker != null or entry.retired) continue;
            const tracker = self.allocator.create(ScreenTracker) catch return error.OutOfMemory;
            tracker.* = .{};
            entry.tracker = tracker;
            return .{
                .owner = self.key,
                .index = @intCast(index),
                .generation = entry.generation,
            };
        }
        return error.Full;
    }

    pub fn destroyScreenTracker(
        self: *Slot,
        key: ScreenTrackerKey,
    ) error{ Stale, Busy }!void {
        const entry = try self.trackerEntry(key);
        const tracker = entry.tracker.?;
        if (tracker.resident_bytes != 0 or tracker.retained_base_bytes != 0 or
            tracker.prepared_base_bytes != 0 or tracker.base_update_prepared or
            tracker.state == .resync_pending or tracker.state == .resync_draining)
            return error.Busy;
        entry.tracker = null;
        entry.generation = std.math.add(u64, entry.generation, 1) catch blk: {
            entry.retired = true;
            break :blk entry.generation;
        };
        self.allocator.destroy(tracker);
    }

    /// Detach path: discard only this subscription's queued screen frames, preserving FIFO order
    /// and every control/other-subscription chunk, then retire the tracker generation.
    pub fn purgeAndDestroyScreenTracker(
        self: *Slot,
        key: ScreenTrackerKey,
    ) error{ Stale, PartialFrame }!void {
        try self.purgeScreenTracker(key);
        self.releaseBaseState(key) catch |err| switch (err) {
            error.Stale => return error.Stale,
            error.Busy => unreachable,
        };
        self.destroyScreenTracker(key) catch |err| switch (err) {
            error.Stale => return error.Stale,
            error.Busy => unreachable,
        };
    }

    /// Backpressure invalidation keeps the tracker identity for a later atomic resync.
    pub fn invalidateAndPurgeScreenTracker(
        self: *Slot,
        key: ScreenTrackerKey,
    ) error{ Stale, PartialFrame }!void {
        const entry = try self.trackerEntry(key);
        try self.purgeScreenTracker(key);
        entry.tracker.?.state = .invalidated;
    }

    fn purgeScreenTracker(
        self: *Slot,
        key: ScreenTrackerKey,
    ) error{ Stale, PartialFrame }!void {
        _ = try self.trackerEntry(key);
        const purges_head = if (self.chunk_len == 0) false else blk: {
            const head = self.chunks[self.chunk_head];
            break :blk head.class == .screen and
                head.screen_tracker_index.? == key.index;
        };
        for (0..self.chunk_len) |logical| {
            const index = (self.chunk_head + logical) % max_chunks_per_slot;
            const chunk = self.chunks[index];
            if (chunk.class == .screen and
                chunk.screen_tracker_index.? == key.index and chunk.offset != 0)
                return error.PartialFrame;
        }
        const old_len = self.chunk_len;
        var kept: usize = 0;
        for (0..old_len) |logical| {
            const index = (self.chunk_head + logical) % max_chunks_per_slot;
            const chunk = self.chunks[index];
            if (chunk.class != .screen or chunk.screen_tracker_index.? != key.index) {
                const dst = (self.chunk_head + kept) % max_chunks_per_slot;
                if (dst != index) self.chunks[dst] = chunk;
                kept += 1;
                continue;
            }
            const remaining = chunk.bytes.len - chunk.offset;
            const charge = chargeFor(chunk.bytes.len);
            self.pending_bytes -= remaining;
            self.resident_bytes -= charge;
            self.screen_trackers[key.index].tracker.?.resident_bytes -= charge;
            self.global.releaseScreen(charge);
            self.allocator.free(chunk.bytes);
        }
        self.chunk_len = kept;
        // An offset-zero screen head may have started a write EAGAIN clock without sending bytes.
        // Purging it changes queue-head identity, so the following control notice/sibling frame must
        // receive a fresh absolute/progress deadline on its own first write attempt.
        if (purges_head) self.clearPartial(.write);
        const tracker = self.screen_trackers[key.index].tracker.?;
        if (tracker.resident_bytes == 0 and tracker.state == .resync_draining) {
            tracker.state = .valid;
            tracker.last_resync_attempt_ns = null;
        }
    }

    fn trackerEntry(self: *Slot, key: ScreenTrackerKey) error{Stale}!*ScreenTrackerEntry {
        if (!std.meta.eql(key.owner, self.key)) return error.Stale;
        const index: usize = key.index;
        if (index >= max_screen_trackers_per_slot) return error.Stale;
        const entry = &self.screen_trackers[index];
        if (entry.tracker == null or entry.generation != key.generation) return error.Stale;
        return entry;
    }

    fn trackerEntryConst(
        self: *const Slot,
        key: ScreenTrackerKey,
    ) error{Stale}!*const ScreenTrackerEntry {
        if (!std.meta.eql(key.owner, self.key)) return error.Stale;
        const index: usize = key.index;
        if (index >= max_screen_trackers_per_slot) return error.Stale;
        const entry = &self.screen_trackers[index];
        if (entry.tracker == null or entry.generation != key.generation) return error.Stale;
        return entry;
    }

    pub fn screenState(self: *Slot, key: ScreenTrackerKey) error{Stale}!ScreenState {
        return (try self.trackerEntry(key)).tracker.?.state;
    }

    pub fn screenResidentBytes(self: *Slot, key: ScreenTrackerKey) error{Stale}!usize {
        return (try self.trackerEntry(key)).tracker.?.resident_bytes;
    }

    pub fn retainedBaseBytes(self: *Slot, key: ScreenTrackerKey) error{Stale}!usize {
        return (try self.trackerEntry(key)).tracker.?.retained_base_bytes;
    }

    pub fn preparedBaseBytes(self: *Slot, key: ScreenTrackerKey) error{Stale}!usize {
        return (try self.trackerEntry(key)).tracker.?.prepared_base_bytes;
    }

    pub fn reserveBaseUpdate(
        self: *Slot,
        key: ScreenTrackerKey,
        amount: usize,
    ) error{ Stale, Busy, InvalidAmount, SlotLimit, GlobalLimit, Exhausted }!BaseReservation {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.base_update_prepared) return error.Busy;
        if (amount == 0 or amount > base_update_max_bytes) return error.InvalidAmount;
        const next_base = std.math.add(usize, self.base_resident_bytes, amount) catch
            return error.SlotLimit;
        if (next_base > base_per_slot_bytes) return error.SlotLimit;
        const future_steady = std.math.add(
            usize,
            self.base_resident_bytes - tracker.retained_base_bytes,
            amount,
        ) catch return error.SlotLimit;
        if (future_steady > base_steady_per_slot_bytes) return error.SlotLimit;
        const next_total = std.math.add(usize, self.resident_bytes, next_base) catch
            return error.SlotLimit;
        if (next_total > total_per_slot_bytes) return error.SlotLimit;
        if (!self.global.reserveBase(tracker.retained_base_bytes, amount))
            return error.GlobalLimit;
        if (tracker.base_update_generation == 0) {
            self.global.finishBase(amount, tracker.retained_base_bytes, amount);
            return error.Exhausted;
        }
        self.base_resident_bytes = next_base;
        tracker.prepared_base_bytes = amount;
        tracker.base_update_prepared = true;
        self.recordPeak();
        return .{ .tracker = key, .generation = tracker.base_update_generation };
    }

    pub fn commitBaseUpdate(
        self: *Slot,
        reservation: BaseReservation,
        actual: usize,
    ) error{ Stale, NotPrepared, InvalidAmount, Exhausted }!void {
        const tracker = (try self.trackerEntry(reservation.tracker)).tracker.?;
        if (!tracker.base_update_prepared or
            tracker.base_update_generation != reservation.generation)
            return error.NotPrepared;
        if (actual > tracker.prepared_base_bytes) return error.InvalidAmount;
        const released = tracker.retained_base_bytes +
            (tracker.prepared_base_bytes - actual);
        self.global.finishBase(
            tracker.prepared_base_bytes,
            tracker.retained_base_bytes,
            released,
        );
        self.base_resident_bytes -= released;
        tracker.retained_base_bytes = actual;
        tracker.prepared_base_bytes = 0;
        tracker.base_update_prepared = false;
        tracker.base_update_generation = std.math.add(
            u64,
            tracker.base_update_generation,
            1,
        ) catch 0;
    }

    pub fn rollbackBaseUpdate(
        self: *Slot,
        reservation: BaseReservation,
    ) error{ Stale, NotPrepared, Exhausted }!void {
        const tracker = (try self.trackerEntry(reservation.tracker)).tracker.?;
        if (!tracker.base_update_prepared or
            tracker.base_update_generation != reservation.generation)
            return error.NotPrepared;
        const released = tracker.prepared_base_bytes;
        self.global.finishBase(released, tracker.retained_base_bytes, released);
        self.base_resident_bytes -= released;
        tracker.prepared_base_bytes = 0;
        tracker.base_update_prepared = false;
        tracker.base_update_generation = std.math.add(
            u64,
            tracker.base_update_generation,
            1,
        ) catch 0;
    }

    pub fn releaseBaseState(
        self: *Slot,
        key: ScreenTrackerKey,
    ) error{ Stale, Busy }!void {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.base_update_prepared) return error.Busy;
        const released = tracker.retained_base_bytes;
        if (released != 0) {
            self.global.releaseScreen(released);
            self.base_resident_bytes -= released;
            tracker.retained_base_bytes = 0;
        }
    }

    pub fn beginResyncAttempt(
        self: *Slot,
        key: ScreenTrackerKey,
        now_ns: u64,
    ) error{Stale}!bool {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (!(try self.resyncAttemptReady(key, now_ns))) return false;
        tracker.last_resync_attempt_ns = now_ns;
        return true;
    }

    /// ACK acceptance and a failed recovery both open a fresh one-second quiet period. Keeping
    /// this clock on the tracker makes the owner-provided monotonic time the only authority.
    pub fn deferResyncAttempt(
        self: *Slot,
        key: ScreenTrackerKey,
        now_ns: u64,
    ) error{Stale}!void {
        (try self.trackerEntry(key)).tracker.?.last_resync_attempt_ns = now_ns;
    }

    /// Priority selection must inspect backoff without consuming the attempt. Otherwise it resets
    /// the normal round-robin cursor to the same failed recovery on every tick and can starve
    /// healthy subscriptions that sort before it.
    pub fn resyncAttemptReady(
        self: *Slot,
        key: ScreenTrackerKey,
        now_ns: u64,
    ) error{Stale}!bool {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.last_resync_attempt_ns) |last| {
            if (now_ns >= last and now_ns - last < resync_retry_backoff_ns) return false;
        }
        return true;
    }

    /// Worst-case reservation preflight before RuntimeOps materializes a 16 MiB snapshot. This is
    /// intentionally conservative: actual bytes are charged by enqueue, while this check prevents
    /// many invalidated subscriptions from allocating snapshots that cannot possibly fit.
    pub fn canAttemptResync(self: *Slot, key: ScreenTrackerKey) error{Stale}!bool {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.resident_bytes >= screen_low_water_bytes) return false;
        if (self.resident_bytes +| resync_batch_bytes > per_slot_bytes) return false;
        if (self.base_resident_bytes +| base_update_max_bytes > base_per_slot_bytes)
            return false;
        if (tracker.retained_base_bytes > self.base_resident_bytes or
            self.base_resident_bytes - tracker.retained_base_bytes +|
                base_update_max_bytes > base_steady_per_slot_bytes)
            return false;
        if (self.resident_bytes +| self.base_resident_bytes +|
            resync_batch_bytes +| base_update_max_bytes > total_per_slot_bytes)
            return false;
        const max_snapshot_chunks: usize = 17; // metadata prefix plus at most sixteen 1 MiB chunks.
        if (self.chunk_len +| max_snapshot_chunks >
            max_chunks_per_slot - control_chunk_reserve)
            return false;
        if (self.global.prepared_base_bytes +| base_update_max_bytes >
            base_replacement_headroom_bytes)
            return false;
        const future_resident = self.global.resident_bytes +|
            base_update_max_bytes +| resync_batch_bytes;
        if (future_resident > global_bytes) return false;
        const future_shared = self.global.shared_bytes +|
            base_update_max_bytes +| resync_batch_bytes;
        if (future_shared > shared_hard_bytes or
            self.global.prepared_reclaim_bytes > future_shared or
            future_shared - self.global.prepared_reclaim_bytes > shared_steady_bytes)
            return false;
        return true;
    }

    pub fn invalidateScreen(self: *Slot, key: ScreenTrackerKey) error{Stale}!void {
        (try self.trackerEntry(key)).tracker.?.state = .invalidated;
    }

    pub fn enqueueScreen(
        self: *Slot,
        key: ScreenTrackerKey,
        bytes: []const u8,
    ) (EnqueueError || error{Stale})!void {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.state != .valid) return error.ScreenInvalidated;
        return self.enqueue(.screen, key.index, bytes, screen_soft_bytes) catch |err| {
            if (err != error.GlobalLimit) tracker.state = .invalidated;
            return err;
        };
    }

    pub fn enqueueControl(self: *Slot, bytes: []const u8) EnqueueError!void {
        return self.enqueue(.control, null, bytes, null);
    }

    /// Ownership-transfer variants used by the readiness adapter. On success the slot owns `bytes`;
    /// on error the caller still owns it. This avoids a second full-frame allocation outside the
    /// charged resident queue.
    pub fn enqueueOwnedControl(self: *Slot, bytes: []u8) EnqueueError!void {
        return self.enqueueOwned(.control, null, bytes, null);
    }

    pub fn enqueueOwnedScreen(
        self: *Slot,
        key: ScreenTrackerKey,
        bytes: []u8,
    ) (EnqueueError || error{Stale})!void {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.state != .valid) return error.ScreenInvalidated;
        return self.enqueueOwned(.screen, key.index, bytes, screen_soft_bytes) catch |err| {
            if (err != error.GlobalLimit) tracker.state = .invalidated;
            return err;
        };
    }

    /// Ordinary producer batches are admitted atomically so a global-pressure retry never leaves
    /// a requester prefix queued or changes its valid tracker state.
    pub fn enqueueOwnedScreenBatch(
        self: *Slot,
        key: ScreenTrackerKey,
        chunks: []const []u8,
    ) (EnqueueError || error{Stale})!void {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.state != .valid) return error.ScreenInvalidated;
        if (chunks.len == 0) return;
        if (self.chunk_len +| chunks.len > max_chunks_per_slot - control_chunk_reserve)
            return error.ChunkLimit;
        var total: usize = 0;
        for (chunks) |bytes| {
            if (bytes.len == 0) return error.ScreenInvalidated;
            total = std.math.add(usize, total, chargeFor(bytes.len)) catch
                return error.SlotLimit;
        }
        if (self.resident_bytes +| total > per_slot_bytes) return error.SlotLimit;
        if (tracker.resident_bytes +| total > screen_soft_bytes) {
            tracker.state = .invalidated;
            return error.ScreenInvalidated;
        }
        if (!self.global.reserveScreen(total)) return error.GlobalLimit;
        errdefer self.global.releaseScreen(total);
        for (chunks) |bytes| {
            const tail = (self.chunk_head + self.chunk_len) % max_chunks_per_slot;
            self.chunks[tail] = .{
                .bytes = bytes,
                .class = .screen,
                .screen_tracker_index = key.index,
            };
            self.chunk_len += 1;
            self.pending_bytes += bytes.len;
        }
        self.resident_bytes += total;
        tracker.resident_bytes += total;
        self.recordPeak();
    }

    fn enqueue(
        self: *Slot,
        class: QueueClass,
        tracker_index: ?usize,
        bytes: []const u8,
        screen_limit: ?usize,
    ) EnqueueError!void {
        if (bytes.len == 0) return;
        if (self.chunk_len == max_chunks_per_slot) return error.ChunkLimit;
        if (class == .screen and self.chunk_len >= max_chunks_per_slot - control_chunk_reserve)
            return error.ChunkLimit;
        const charge = chargeFor(bytes.len);
        const next_slot = std.math.add(usize, self.resident_bytes, charge) catch return error.SlotLimit;
        if (next_slot > per_slot_bytes) return error.SlotLimit;
        if (class == .screen) {
            const tracker = self.screen_trackers[tracker_index.?].tracker.?;
            const next_screen = std.math.add(usize, tracker.resident_bytes, charge) catch
                return error.ScreenInvalidated;
            if (next_screen > screen_limit.?) {
                tracker.state = .invalidated;
                return error.ScreenInvalidated;
            }
        }
        const reserved = if (class == .screen)
            self.global.reserveScreen(charge)
        else
            self.global.reserveControl(self.control_resident_bytes, charge);
        if (!reserved) return error.GlobalLimit;
        errdefer if (class == .screen)
            self.global.releaseScreen(charge)
        else
            self.global.releaseControl(self.control_resident_bytes + charge, charge);
        const owned = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const tail = (self.chunk_head + self.chunk_len) % max_chunks_per_slot;
        self.chunks[tail] = .{
            .bytes = owned,
            .class = class,
            .screen_tracker_index = tracker_index,
        };
        self.chunk_len += 1;
        self.resident_bytes = next_slot;
        self.pending_bytes += bytes.len;
        if (class == .screen)
            self.screen_trackers[tracker_index.?].tracker.?.resident_bytes += charge;
        if (class == .control) self.control_resident_bytes += charge;
        self.recordPeak();
    }

    fn enqueueOwned(
        self: *Slot,
        class: QueueClass,
        tracker_index: ?usize,
        bytes: []u8,
        screen_limit: ?usize,
    ) EnqueueError!void {
        if (bytes.len == 0) {
            self.allocator.free(bytes);
            return;
        }
        if (self.chunk_len == max_chunks_per_slot) return error.ChunkLimit;
        if (class == .screen and self.chunk_len >= max_chunks_per_slot - control_chunk_reserve)
            return error.ChunkLimit;
        const charge = chargeFor(bytes.len);
        const next_slot = std.math.add(usize, self.resident_bytes, charge) catch
            return error.SlotLimit;
        if (next_slot > per_slot_bytes) return error.SlotLimit;
        if (class == .screen) {
            const tracker = self.screen_trackers[tracker_index.?].tracker.?;
            const next_screen = std.math.add(usize, tracker.resident_bytes, charge) catch
                return error.ScreenInvalidated;
            if (next_screen > screen_limit.?) {
                tracker.state = .invalidated;
                return error.ScreenInvalidated;
            }
        }
        const reserved = if (class == .screen)
            self.global.reserveScreen(charge)
        else
            self.global.reserveControl(self.control_resident_bytes, charge);
        if (!reserved) return error.GlobalLimit;
        const tail = (self.chunk_head + self.chunk_len) % max_chunks_per_slot;
        self.chunks[tail] = .{
            .bytes = bytes,
            .class = class,
            .screen_tracker_index = tracker_index,
        };
        self.chunk_len += 1;
        self.resident_bytes = next_slot;
        self.pending_bytes += bytes.len;
        if (class == .screen)
            self.screen_trackers[tracker_index.?].tracker.?.resident_bytes += charge;
        if (class == .control) self.control_resident_bytes += charge;
        self.recordPeak();
    }

    /// Adapter가 실제 write한 만큼만 queue/global accounting을 해제한다.
    pub fn consumeWritten(self: *Slot, amount: usize) error{OverConsume}!void {
        if (amount > self.pending_bytes) return error.OverConsume;
        var remaining = amount;
        while (remaining != 0) {
            var first = &self.chunks[self.chunk_head];
            const available = first.bytes.len - first.offset;
            const take = @min(available, remaining);
            first.offset += take;
            remaining -= take;
            self.pending_bytes -= take;
            if (first.offset == first.bytes.len) {
                const owned = first.bytes;
                const class = first.class;
                const charge = chargeFor(first.bytes.len);
                self.allocator.free(owned);
                self.chunk_head = (self.chunk_head + 1) % max_chunks_per_slot;
                self.chunk_len -= 1;
                self.resident_bytes -= charge;
                if (class == .screen) {
                    const tracker = self.screen_trackers[first.screen_tracker_index.?].tracker.?;
                    tracker.resident_bytes -= charge;
                    if (tracker.resident_bytes == 0 and tracker.state == .resync_draining) {
                        tracker.state = .valid;
                        tracker.last_resync_attempt_ns = null;
                    }
                    self.global.releaseScreen(charge);
                } else {
                    self.global.releaseControl(self.control_resident_bytes, charge);
                    self.control_resident_bytes -= charge;
                }
            }
        }
    }

    /// 모든 snapshot chunk를 하나의 원자 batch로 enqueue한다. 실패하면 이 호출의 prefix만 역순 rollback한다.
    pub fn enqueueResyncSnapshot(
        self: *Slot,
        key: ScreenTrackerKey,
        chunks: []const []const u8,
    ) (EnqueueError || error{Stale})!void {
        const tracker = (try self.trackerEntry(key)).tracker.?;
        if (tracker.state != .invalidated or
            tracker.resident_bytes >= screen_low_water_bytes or
            chunks.len == 0)
            return error.ScreenInvalidated;
        tracker.state = .resync_pending;
        var added: usize = 0;
        errdefer {
            self.rollbackTail(added);
            tracker.state = .invalidated;
        }
        for (chunks) |bytes| {
            if (bytes.len == 0) return error.ScreenInvalidated;
            try self.enqueue(.screen, key.index, bytes, resync_batch_bytes);
            added += 1;
        }
        tracker.state = .resync_draining;
    }

    /// Ownership-consuming resync batch. Every inner buffer is consumed on both success and error;
    /// accepted prefixes are rolled back and freed atomically.
    pub fn enqueueOwnedResyncSnapshot(
        self: *Slot,
        key: ScreenTrackerKey,
        chunks: []const []u8,
    ) (EnqueueError || error{Stale})!void {
        const entry = self.trackerEntry(key) catch |err| {
            for (chunks) |bytes| self.allocator.free(bytes);
            return err;
        };
        const tracker = entry.tracker.?;
        if (tracker.state != .invalidated or
            tracker.resident_bytes >= screen_low_water_bytes or
            chunks.len == 0)
        {
            for (chunks) |bytes| self.allocator.free(bytes);
            return error.ScreenInvalidated;
        }
        tracker.state = .resync_pending;
        var added: usize = 0;
        errdefer {
            self.rollbackTail(added);
            for (chunks[added..]) |bytes| self.allocator.free(bytes);
            tracker.state = .invalidated;
        }
        for (chunks) |bytes| {
            if (bytes.len == 0) return error.ScreenInvalidated;
            try self.enqueueOwned(.screen, key.index, bytes, resync_batch_bytes);
            added += 1;
        }
        tracker.state = .resync_draining;
    }

    fn rollbackTail(self: *Slot, count: usize) void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const index = (self.chunk_head + self.chunk_len - 1) % max_chunks_per_slot;
            const chunk = self.chunks[index];
            std.debug.assert(chunk.class == .screen and chunk.offset == 0);
            const charge = chargeFor(chunk.bytes.len);
            self.screen_trackers[chunk.screen_tracker_index.?].tracker.?.resident_bytes -= charge;
            self.global.releaseScreen(charge);
            self.resident_bytes -= charge;
            self.pending_bytes -= chunk.bytes.len;
            self.allocator.free(chunk.bytes);
            self.chunk_len -= 1;
        }
    }

    pub const PendingView = struct {
        bytes: []const u8,
        class: QueueClass,
    };

    pub fn firstPending(self: *const Slot) ?PendingView {
        if (self.chunk_len == 0) return null;
        const first = self.chunks[self.chunk_head];
        return .{ .bytes = first.bytes[first.offset..], .class = first.class };
    }

    pub fn writeBackpressured(self: *const Slot) bool {
        return self.write_partial_started_ns != null;
    }

    pub fn writeStallObserved(self: *const Slot) bool {
        return self.write_stall_observed;
    }

    pub fn noteWriteReady(self: *Slot) void {
        self.write_stall_observed = false;
    }

    pub fn trackerHasWrittenPrefix(
        self: *const Slot,
        key: ScreenTrackerKey,
    ) error{Stale}!bool {
        _ = try self.trackerEntryConst(key);
        if (self.chunk_len == 0) return false;
        const head = self.chunks[self.chunk_head];
        return head.class == .screen and
            head.screen_tracker_index.? == key.index and head.offset != 0;
    }

    pub fn globalPressureReady(
        self: *const Slot,
        key: ScreenTrackerKey,
        now_ns: u64,
    ) error{Stale}!bool {
        return now_ns >= (try self.trackerEntryConst(key)).tracker.?.global_pressure_retry_after_ns;
    }

    pub fn globalPressureRetryAfter(
        self: *const Slot,
        key: ScreenTrackerKey,
    ) error{Stale}!u64 {
        return (try self.trackerEntryConst(key)).tracker.?.global_pressure_retry_after_ns;
    }

    pub fn deferGlobalPressure(
        self: *Slot,
        key: ScreenTrackerKey,
        now_ns: u64,
    ) error{Stale}!void {
        (try self.trackerEntry(key)).tracker.?.global_pressure_retry_after_ns =
            now_ns +| resync_retry_backoff_ns;
    }

    pub const PartialDirection = enum { read, write };

    pub fn notePartial(self: *Slot, direction: PartialDirection, now_ns: u64, progressed: bool) void {
        const started = switch (direction) {
            .read => &self.read_partial_started_ns,
            .write => &self.write_partial_started_ns,
        };
        const progress = switch (direction) {
            .read => &self.read_partial_progress_ns,
            .write => &self.write_partial_progress_ns,
        };
        if (started.* == null) started.* = now_ns;
        if (progressed or progress.* == null) progress.* = now_ns;
        if (direction == .write) self.write_stall_observed = !progressed;
    }

    pub fn clearPartial(self: *Slot, direction: PartialDirection) void {
        switch (direction) {
            .read => {
                self.read_partial_started_ns = null;
                self.read_partial_progress_ns = null;
            },
            .write => {
                self.write_partial_started_ns = null;
                self.write_partial_progress_ns = null;
                self.write_stall_observed = false;
            },
        }
    }

    pub fn partialExpired(self: *const Slot, direction: PartialDirection, now_ns: u64) bool {
        const last = switch (direction) {
            .read => self.read_partial_progress_ns,
            .write => self.write_partial_progress_ns,
        } orelse return false;
        const started = (switch (direction) {
            .read => self.read_partial_started_ns,
            .write => self.write_partial_started_ns,
        }).?;
        return (now_ns >= last and now_ns - last >= partial_deadline_ns) or
            (now_ns >= started and now_ns - started >= partial_absolute_deadline_ns);
    }

    pub fn beginDispatch(self: *Slot) error{CounterExhausted}!void {
        self.in_flight_dispatch = std.math.add(usize, self.in_flight_dispatch, 1) catch
            return error.CounterExhausted;
    }

    pub fn endDispatch(self: *Slot) error{CounterUnderflow}!void {
        if (self.in_flight_dispatch == 0) return error.CounterUnderflow;
        self.in_flight_dispatch -= 1;
    }

    pub fn attachStream(self: *Slot) error{CounterExhausted}!void {
        self.attached_streams = std.math.add(usize, self.attached_streams, 1) catch
            return error.CounterExhausted;
    }

    pub fn detachStream(self: *Slot) error{CounterUnderflow}!void {
        if (self.attached_streams == 0) return error.CounterUnderflow;
        self.attached_streams -= 1;
    }

    pub fn idleForUpgrade(self: *const Slot) bool {
        return self.upgradeReady(0);
    }

    pub fn requesterReadyForUpgrade(self: *const Slot) bool {
        return self.upgradeReady(1);
    }

    fn upgradeReady(self: *const Slot, expected_in_flight: usize) bool {
        return self.read_partial_started_ns == null and
            self.write_partial_started_ns == null and self.pending_bytes == 0 and
            self.in_flight_dispatch == expected_in_flight and self.attached_streams == 0;
    }
};

fn chargeFor(payload_len: usize) usize {
    return payload_len;
}

fn appendOwnedBatchChunk(
    slot: *Slot,
    class: QueueClass,
    tracker_index: ?usize,
    bytes: []u8,
) void {
    const tail = (slot.chunk_head + slot.chunk_len) % max_chunks_per_slot;
    slot.chunks[tail] = .{
        .bytes = bytes,
        .class = class,
        .screen_tracker_index = tracker_index,
    };
    slot.chunk_len += 1;
    slot.pending_bytes += bytes.len;
    slot.resident_bytes += chargeFor(bytes.len);
}

pub const TurnBudget = struct {
    read_bytes: usize = 0,
    write_bytes: usize = 0,
    read_frames: usize = 0,
    write_frames: usize = 0,

    pub fn allowRead(self: *TurnBudget, bytes: usize, frames: usize) bool {
        return reserveTurn(&self.read_bytes, &self.read_frames, bytes, frames);
    }

    pub fn allowWrite(self: *TurnBudget, bytes: usize, frames: usize) bool {
        return reserveTurn(&self.write_bytes, &self.write_frames, bytes, frames);
    }
};

fn reserveTurn(byte_count: *usize, frame_count: *usize, bytes: usize, frames: usize) bool {
    const next_bytes = std.math.add(usize, byte_count.*, bytes) catch return false;
    const next_frames = std.math.add(usize, frame_count.*, frames) catch return false;
    if (next_bytes > turn_bytes or next_frames > turn_frames) return false;
    byte_count.* = next_bytes;
    frame_count.* = next_frames;
    return true;
}

/// Table, budget, Slot 주소를 한 heap owner에 고정해 upgrade drain이 caller-provided clone을 검사하지 않게 한다.
pub const ReactorCore = struct {
    allocator: std.mem.Allocator,
    table: SlotTable = .{},
    budget: GlobalBudget = .{},
    slots: [max_connections]?*Slot = [_]?*Slot{null} ** max_connections,
    next_mixed_batch_reservation_id: u64 = 1,
    active_mixed_batch_reservation_id: ?u64 = null,

    pub const Admission = SlotTable.Admission;
    pub const OwnedControlItem = struct {
        admission: Admission,
        bytes: []u8,
    };
    pub const OwnedScreenItem = struct {
        admission: Admission,
        tracker: ScreenTrackerKey,
        bytes: []u8,
    };
    pub const PreparedControlAndScreenBatch = struct {
        control: OwnedControlItem,
        screens: []const OwnedScreenItem,
        future_resident: usize,
        future_shared: usize,
        reservation_id: u64,
        consumed: bool = false,
    };
    pub const AccountingSnapshot = struct {
        resident_bytes: usize,
        shared_bytes: usize,
        prepared_base_bytes: usize,
        prepared_reclaim_bytes: usize,
        peak_resident_bytes: usize,
        peak_shared_bytes: usize,
        peak_prepared_base_bytes: usize,
        peak_prepared_reclaim_bytes: usize,
        peak_slot_queue_bytes: usize,
        peak_slot_base_bytes: usize,
        peak_slot_control_bytes: usize,
        peak_slot_total_bytes: usize,
    };

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*ReactorCore {
        const self = allocator.create(ReactorCore) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *ReactorCore) void {
        for (&self.slots) |*maybe_slot| {
            const slot = maybe_slot.* orelse continue;
            slot.deinit();
            self.allocator.destroy(slot);
            maybe_slot.* = null;
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn admit(self: *ReactorCore) error{ Full, Exhausted, OutOfMemory }!Admission {
        const admission = try self.table.admit();
        errdefer self.table.close(admission) catch unreachable;
        const slot = self.allocator.create(Slot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        slot.* = Slot.init(self.allocator, &self.budget, admission.key) catch
            return error.OutOfMemory;
        self.slots[admission.index] = slot;
        return admission;
    }

    pub fn get(self: *ReactorCore, admission: Admission) error{Stale}!*Slot {
        if (admission.index >= max_connections) return error.Stale;
        const slot = self.slots[admission.index] orelse return error.Stale;
        if (!std.meta.eql(slot.key, admission.key)) return error.Stale;
        return slot;
    }

    /// Atomically admits one authority-critical control frame per item (currently at most old
    /// revocation + requester success). The fixed chunk tables need no allocation; a complete
    /// cross-slot/global preflight makes the subsequent owned enqueues infallible in this
    /// single-owner turn. On error the caller retains every buffer.
    pub fn enqueueOwnedControlBatch(
        self: *ReactorCore,
        items: []const OwnedControlItem,
    ) (EnqueueError || error{ Stale, InvalidBatch })!void {
        if (items.len == 0 or items.len > 2) return error.InvalidBatch;

        var slots: [2]*Slot = undefined;
        var charges: [2]usize = undefined;
        var total_charge: usize = 0;
        for (items, 0..) |item, index| {
            if (item.bytes.len == 0) return error.InvalidBatch;
            slots[index] = try self.get(item.admission);
            charges[index] = chargeFor(item.bytes.len);
            total_charge = std.math.add(
                usize,
                total_charge,
                charges[index],
            ) catch return error.GlobalLimit;
        }

        var unique_slots: [2]*Slot = undefined;
        var unique_charge: [2]usize = .{ 0, 0 };
        var unique_chunks: [2]usize = .{ 0, 0 };
        var unique_len: usize = 0;
        for (slots[0..items.len], charges[0..items.len]) |slot, charge| {
            var found: ?usize = null;
            for (unique_slots[0..unique_len], 0..) |candidate, index|
                if (candidate == slot) {
                    found = index;
                    break;
                };
            const index = found orelse blk: {
                unique_slots[unique_len] = slot;
                unique_len += 1;
                break :blk unique_len - 1;
            };
            unique_charge[index] = std.math.add(
                usize,
                unique_charge[index],
                charge,
            ) catch return error.SlotLimit;
            unique_chunks[index] += 1;
        }

        var shared_delta: usize = 0;
        for (
            unique_slots[0..unique_len],
            unique_charge[0..unique_len],
            unique_chunks[0..unique_len],
        ) |slot, added_charge, added_chunks| {
            if (slot.chunk_len +| added_chunks > max_chunks_per_slot)
                return error.ChunkLimit;
            if (slot.resident_bytes +| added_charge > per_slot_bytes)
                return error.SlotLimit;
            const old_shared = slot.control_resident_bytes -| control_reserve_bytes;
            const new_control = std.math.add(
                usize,
                slot.control_resident_bytes,
                added_charge,
            ) catch return error.SlotLimit;
            const new_shared = new_control -| control_reserve_bytes;
            shared_delta = std.math.add(
                usize,
                shared_delta,
                new_shared - old_shared,
            ) catch return error.GlobalLimit;
        }
        const future_resident = std.math.add(
            usize,
            self.budget.resident_bytes,
            total_charge,
        ) catch return error.GlobalLimit;
        if (future_resident > global_bytes) return error.GlobalLimit;
        const future_shared = std.math.add(
            usize,
            self.budget.shared_bytes,
            shared_delta,
        ) catch return error.GlobalLimit;
        if (future_shared > shared_hard_bytes or
            self.budget.prepared_reclaim_bytes > future_shared or
            future_shared - self.budget.prepared_reclaim_bytes >
                shared_steady_bytes)
            return error.GlobalLimit;

        for (items, slots[0..items.len]) |item, slot|
            slot.enqueueOwnedControl(item.bytes) catch unreachable;
    }

    /// One requester response plus a runtime-wide set of stream events is a single publication.
    /// This preflights every slot/tracker/global charge before taking ownership of any buffer.
    pub fn preflightOwnedControlAndScreenBatch(
        self: *ReactorCore,
        control: OwnedControlItem,
        screens: []const OwnedScreenItem,
    ) (EnqueueError || error{ Stale, InvalidBatch })!void {
        _ = try self.analyzeControlAndScreenBatch(control, screens);
    }

    /// Returns the first non-requester connection whose cumulative screen publication cannot fit
    /// its current local tracker/slot limits. Multiple streams on one connection are accumulated.
    pub fn firstLocallyUnadmissibleScreenConnection(
        self: *ReactorCore,
        items: []const OwnedScreenItem,
        requester: Admission,
    ) ?Admission {
        const Delta = struct {
            admission: Admission,
            slot: *Slot,
            charge: usize = 0,
            chunks: usize = 0,
        };
        var deltas: [max_connections]Delta = undefined;
        var delta_len: usize = 0;
        for (items) |item| {
            const slot = self.get(item.admission) catch
                return if (std.meta.eql(item.admission, requester)) null else item.admission;
            const tracker_entry = slot.trackerEntry(item.tracker) catch
                return if (std.meta.eql(item.admission, requester)) null else item.admission;
            const tracker = tracker_entry.tracker.?;
            if (tracker.state != .valid or
                tracker.resident_bytes +| chargeFor(item.bytes.len) > screen_soft_bytes)
                return if (std.meta.eql(item.admission, requester)) null else item.admission;

            var delta: ?*Delta = null;
            for (deltas[0..delta_len]) |*candidate|
                if (candidate.slot == slot) {
                    delta = candidate;
                    break;
                };
            if (delta == null) {
                deltas[delta_len] = .{ .admission = item.admission, .slot = slot };
                delta = &deltas[delta_len];
                delta_len += 1;
            }
            delta.?.charge +|= chargeFor(item.bytes.len);
            delta.?.chunks +|= 1;
            if (slot.resident_bytes +| delta.?.charge > per_slot_bytes or
                slot.chunk_len +| delta.?.chunks >
                    max_chunks_per_slot - control_chunk_reserve)
                return if (std.meta.eql(item.admission, requester))
                    null
                else
                    delta.?.admission;
        }
        return null;
    }

    pub fn enqueueOwnedControlAndScreenBatch(
        self: *ReactorCore,
        control: OwnedControlItem,
        screens: []const OwnedScreenItem,
    ) (EnqueueError || error{
        Stale,
        InvalidBatch,
        ReservationBusy,
        ReservationExhausted,
        StaleReservation,
    })!void {
        var prepared = try self.prepareOwnedControlAndScreenBatch(control, screens);
        try self.commitPreparedControlAndScreenBatch(&prepared);
    }

    /// Reserves the single-owner publication lane. Between prepare and commit/cancel no owner
    /// callback may mutate this reactor; the PTY resize backend is deliberately non-reentrant.
    pub fn prepareOwnedControlAndScreenBatch(
        self: *ReactorCore,
        control: OwnedControlItem,
        screens: []const OwnedScreenItem,
    ) (EnqueueError || error{
        Stale,
        InvalidBatch,
        ReservationBusy,
        ReservationExhausted,
    })!PreparedControlAndScreenBatch {
        if (self.active_mixed_batch_reservation_id != null)
            return error.ReservationBusy;
        if (self.next_mixed_batch_reservation_id == std.math.maxInt(u64))
            return error.ReservationExhausted;
        const totals = try self.analyzeControlAndScreenBatch(control, screens);
        const reservation_id = self.next_mixed_batch_reservation_id;
        self.next_mixed_batch_reservation_id += 1;
        self.active_mixed_batch_reservation_id = reservation_id;
        return .{
            .control = control,
            .screens = screens,
            .future_resident = totals.future_resident,
            .future_shared = totals.future_shared,
            .reservation_id = reservation_id,
        };
    }

    pub fn validatePreparedControlAndScreenBatch(
        self: *const ReactorCore,
        prepared: *const PreparedControlAndScreenBatch,
    ) error{StaleReservation}!void {
        if (prepared.consumed or
            self.active_mixed_batch_reservation_id != prepared.reservation_id)
            return error.StaleReservation;
    }

    pub fn cancelPreparedControlAndScreenBatch(
        self: *ReactorCore,
        prepared: *PreparedControlAndScreenBatch,
    ) error{StaleReservation}!void {
        try self.validatePreparedControlAndScreenBatch(prepared);
        prepared.consumed = true;
        self.active_mixed_batch_reservation_id = null;
    }

    pub fn commitPreparedControlAndScreenBatch(
        self: *ReactorCore,
        prepared: *PreparedControlAndScreenBatch,
    ) error{StaleReservation}!void {
        try self.validatePreparedControlAndScreenBatch(prepared);
        prepared.consumed = true;
        self.budget.resident_bytes = prepared.future_resident;
        self.budget.shared_bytes = prepared.future_shared;
        self.budget.recordPeak();
        const control_slot = self.get(prepared.control.admission) catch unreachable;
        appendOwnedBatchChunk(control_slot, .control, null, prepared.control.bytes);
        control_slot.control_resident_bytes += chargeFor(prepared.control.bytes.len);
        control_slot.recordPeak();
        for (prepared.screens) |item| {
            const slot = self.get(item.admission) catch unreachable;
            appendOwnedBatchChunk(slot, .screen, item.tracker.index, item.bytes);
            slot.screen_trackers[item.tracker.index].tracker.?.resident_bytes +=
                chargeFor(item.bytes.len);
            slot.recordPeak();
        }
        self.active_mixed_batch_reservation_id = null;
    }

    const MixedBatchTotals = struct {
        future_resident: usize,
        future_shared: usize,
    };

    fn analyzeControlAndScreenBatch(
        self: *ReactorCore,
        control: OwnedControlItem,
        screens: []const OwnedScreenItem,
    ) (EnqueueError || error{ Stale, InvalidBatch })!MixedBatchTotals {
        if (control.bytes.len == 0) return error.InvalidBatch;
        const control_slot = try self.get(control.admission);
        const control_charge = chargeFor(control.bytes.len);

        const SlotDelta = struct {
            slot: *Slot,
            screen_charge: usize = 0,
            screen_chunks: usize = 0,
            control_charge: usize = 0,
            control_chunks: usize = 0,
            seen_trackers: [4]u64 = .{0} ** 4,
        };
        var deltas: [max_connections]SlotDelta = undefined;
        var delta_len: usize = 0;
        const control_delta = blk: {
            deltas[0] = .{ .slot = control_slot };
            delta_len = 1;
            break :blk &deltas[0];
        };
        control_delta.control_charge = control_charge;
        control_delta.control_chunks = 1;

        var total_screen_charge: usize = 0;
        for (screens) |item| {
            if (item.bytes.len == 0) return error.InvalidBatch;
            const slot = try self.get(item.admission);
            const tracker = (try slot.trackerEntry(item.tracker)).tracker.?;
            if (tracker.state != .valid) return error.ScreenInvalidated;
            const charge = chargeFor(item.bytes.len);
            if (tracker.resident_bytes +| charge > screen_soft_bytes)
                return error.ScreenInvalidated;
            total_screen_charge = std.math.add(
                usize,
                total_screen_charge,
                charge,
            ) catch return error.GlobalLimit;

            var delta: ?*SlotDelta = null;
            for (deltas[0..delta_len]) |*candidate|
                if (candidate.slot == slot) {
                    delta = candidate;
                    break;
                };
            if (delta == null) {
                std.debug.assert(delta_len < deltas.len);
                deltas[delta_len] = .{ .slot = slot };
                delta = &deltas[delta_len];
                delta_len += 1;
            }
            const tracker_word = item.tracker.index / 64;
            const tracker_bit = @as(u64, 1) << @intCast(item.tracker.index % 64);
            if (delta.?.seen_trackers[tracker_word] & tracker_bit != 0)
                return error.InvalidBatch;
            delta.?.seen_trackers[tracker_word] |= tracker_bit;
            delta.?.screen_charge = std.math.add(
                usize,
                delta.?.screen_charge,
                charge,
            ) catch return error.SlotLimit;
            delta.?.screen_chunks += 1;
        }

        var control_shared_delta: usize = 0;
        for (deltas[0..delta_len]) |delta| {
            const added_chunks = delta.screen_chunks + delta.control_chunks;
            if (delta.slot.chunk_len +| added_chunks > max_chunks_per_slot)
                return error.ChunkLimit;
            if (delta.slot.chunk_len +| delta.screen_chunks >
                max_chunks_per_slot - control_chunk_reserve)
                return error.ChunkLimit;
            const added_charge = std.math.add(
                usize,
                delta.screen_charge,
                delta.control_charge,
            ) catch return error.SlotLimit;
            if (delta.slot.resident_bytes +| added_charge > per_slot_bytes)
                return error.SlotLimit;
            if (delta.control_charge != 0) {
                const old_shared =
                    delta.slot.control_resident_bytes -| control_reserve_bytes;
                const new_control = std.math.add(
                    usize,
                    delta.slot.control_resident_bytes,
                    delta.control_charge,
                ) catch return error.SlotLimit;
                control_shared_delta = std.math.add(
                    usize,
                    control_shared_delta,
                    (new_control -| control_reserve_bytes) - old_shared,
                ) catch return error.GlobalLimit;
            }
        }
        const total_charge = std.math.add(
            usize,
            total_screen_charge,
            control_charge,
        ) catch return error.GlobalLimit;
        const future_resident = std.math.add(
            usize,
            self.budget.resident_bytes,
            total_charge,
        ) catch return error.GlobalLimit;
        if (future_resident > global_bytes) return error.GlobalLimit;
        const shared_delta = std.math.add(
            usize,
            total_screen_charge,
            control_shared_delta,
        ) catch return error.GlobalLimit;
        const future_shared = std.math.add(
            usize,
            self.budget.shared_bytes,
            shared_delta,
        ) catch return error.GlobalLimit;
        if (future_shared > shared_hard_bytes or
            self.budget.prepared_reclaim_bytes > future_shared or
            future_shared - self.budget.prepared_reclaim_bytes >
                shared_steady_bytes)
            return error.GlobalLimit;

        return .{
            .future_resident = future_resident,
            .future_shared = future_shared,
        };
    }

    pub fn closeIdleForUpgrade(self: *ReactorCore, admission: Admission) error{ Stale, Busy }!void {
        const slot = try self.get(admission);
        if (!slot.idleForUpgrade()) return error.Busy;
        try self.table.close(admission);
        self.slots[admission.index] = null;
        slot.deinit();
        self.allocator.destroy(slot);
    }

    pub fn activeCount(self: *const ReactorCore) usize {
        return self.table.active_count;
    }

    pub fn accountingSnapshot(self: *const ReactorCore) AccountingSnapshot {
        return .{
            .resident_bytes = self.budget.resident_bytes,
            .shared_bytes = self.budget.shared_bytes,
            .prepared_base_bytes = self.budget.prepared_base_bytes,
            .prepared_reclaim_bytes = self.budget.prepared_reclaim_bytes,
            .peak_resident_bytes = self.budget.peak_resident_bytes,
            .peak_shared_bytes = self.budget.peak_shared_bytes,
            .peak_prepared_base_bytes = self.budget.peak_prepared_base_bytes,
            .peak_prepared_reclaim_bytes = self.budget.peak_prepared_reclaim_bytes,
            .peak_slot_queue_bytes = self.budget.peak_slot_queue_bytes,
            .peak_slot_base_bytes = self.budget.peak_slot_base_bytes,
            .peak_slot_control_bytes = self.budget.peak_slot_control_bytes,
            .peak_slot_total_bytes = self.budget.peak_slot_total_bytes,
        };
    }

    /// ReleaseFast fixture phase barrier: lifetime high-water를 pressure phase에 잘못
    /// 귀속하지 않도록 peak만 현재 canonical accounting에서 다시 시작한다.
    /// admission/current charge와 authority는 바꾸지 않는다.
    pub fn resetFixturePeaksToCurrent(self: *ReactorCore) void {
        self.budget.peak_resident_bytes = self.budget.resident_bytes;
        self.budget.peak_shared_bytes = self.budget.shared_bytes;
        self.budget.peak_prepared_base_bytes = self.budget.prepared_base_bytes;
        self.budget.peak_prepared_reclaim_bytes = self.budget.prepared_reclaim_bytes;
        self.budget.peak_slot_queue_bytes = 0;
        self.budget.peak_slot_base_bytes = 0;
        self.budget.peak_slot_control_bytes = 0;
        self.budget.peak_slot_total_bytes = 0;
        for (self.slots) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            self.budget.recordSlotPeak(
                slot.resident_bytes,
                slot.base_resident_bytes,
                slot.control_resident_bytes,
            );
        }
    }

    pub fn drainedForUpgrade(self: *const ReactorCore) bool {
        return self.active_mixed_batch_reservation_id == null and
            self.table.active_count == 0 and
            self.budget.resident_bytes == 0 and self.budget.shared_bytes == 0 and
            self.budget.prepared_base_bytes == 0 and
            self.budget.prepared_reclaim_bytes == 0;
    }

    /// Canonical slot teardown 뒤 aggregate counters만 drift한 경우의 upgrade rollback repair.
    /// SlotTable/ConnectionKey allocator를 보존해 stale key가 다음 admission과 ABA alias하지 않게 한다.
    pub fn repairEmptyBudget(self: *ReactorCore) bool {
        if (self.active_mixed_batch_reservation_id != null or
            self.table.active_count != 0) return false;
        for (self.table.entries) |entry| if (entry.key != null) return false;
        for (self.slots) |maybe_slot| if (maybe_slot != null) return false;
        self.budget = .{};
        return true;
    }

    /// EOF/protocol error/timeout teardown. Unsent queue and tracker accounting are purged by Slot.deinit.
    pub fn closeConnection(self: *ReactorCore, admission: Admission) error{Stale}!void {
        const slot = try self.get(admission);
        try self.table.close(admission);
        self.slots[admission.index] = null;
        slot.deinit();
        self.allocator.destroy(slot);
    }

    pub fn nextReady(
        self: *ReactorCore,
        ready: *const [max_connections]bool,
    ) ?Admission {
        return self.table.nextReady(ready);
    }
};

/// Pure T0a drain oracle used only by OS-neutral invariant tests. Product frame admission authority
/// is `upgrade_coordinator.AdmissionGate`; this type must never be wired beside it.
pub const DrainModel = struct {
    open: bool = true,
    in_flight: usize = 0,

    pub fn tryBegin(self: *DrainModel) error{ Closed, CounterExhausted }!void {
        if (!self.open) return error.Closed;
        self.in_flight = std.math.add(usize, self.in_flight, 1) catch
            return error.CounterExhausted;
    }

    pub fn end(self: *DrainModel) error{CounterUnderflow}!void {
        if (self.in_flight == 0) return error.CounterUnderflow;
        self.in_flight -= 1;
    }

    pub fn close(self: *DrainModel) void {
        self.open = false;
    }

    pub fn reopen(self: *DrainModel) void {
        self.open = true;
    }

    pub fn drained(self: *const DrainModel, reactor: *const ReactorCore) bool {
        return !self.open and self.in_flight == 0 and reactor.activeCount() == 0;
    }
};

test "connection slot queue accepts exact caps and rolls back rejected allocation" {
    const testing = std.testing;
    var global: GlobalBudget = .{};
    var slot = try Slot.init(testing.allocator, &global, .{ .monotonic_id = 1, .slot_generation = 1 });
    defer slot.deinit();
    const screen_tracker = try slot.createScreenTracker();
    const screen = try testing.allocator.alloc(u8, screen_soft_bytes);
    defer testing.allocator.free(screen);
    @memset(screen, 1);
    try slot.enqueueScreen(screen_tracker, screen);
    try testing.expectError(error.ScreenInvalidated, slot.enqueueScreen(screen_tracker, "x"));
    try testing.expectEqual(ScreenState.invalidated, try slot.screenState(screen_tracker));
    try testing.expectEqual(screen_soft_bytes, global.resident_bytes);
    try slot.enqueueControl("reply");
    // Partial consume does not release resident allocation/accounting.
    try slot.consumeWritten(screen.len - 1);
    try testing.expectEqual(screen_soft_bytes + chargeFor("reply".len), global.resident_bytes);
    try slot.consumeWritten(1 + "reply".len);
    try testing.expectEqual(@as(usize, 0), global.resident_bytes);
    global.resident_bytes = global_bytes;
    global.shared_bytes = global_bytes - max_connections * control_reserve_bytes;
    try testing.expectError(
        error.GlobalLimit,
        slot.enqueueResyncSnapshot(screen_tracker, &.{"snapshot"}),
    );
    try testing.expectEqual(ScreenState.invalidated, try slot.screenState(screen_tracker));
    global = .{};
    try slot.enqueueResyncSnapshot(screen_tracker, &.{ "snap", "shot" });
    try testing.expectEqual(ScreenState.resync_draining, try slot.screenState(screen_tracker));
    try slot.consumeWritten("snapshot".len);
    try testing.expectEqual(ScreenState.valid, try slot.screenState(screen_tracker));
}

test "connection slot resync rejects empty chunk fail closed" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(tracker);
    try std.testing.expectError(
        error.ScreenInvalidated,
        slot.enqueueResyncSnapshot(tracker, &.{ "prefix", "" }),
    );
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(tracker));
    try std.testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), try slot.screenResidentBytes(tracker));
}

test "connection slot enqueue OOM rolls back slot and global accounting" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        failing.allocator(),
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    try std.testing.expectError(error.OutOfMemory, slot.enqueueControl("reply"));
    try std.testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), slot.chunk_len);
    try std.testing.expectEqual(@as(usize, 0), global.resident_bytes);
}

test "multi chunk resync limit rolls back the accepted prefix" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    for (0..max_chunks_per_slot - control_chunk_reserve - 1) |_| try slot.enqueueControl("c");
    const tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(tracker);
    const pending_before = slot.pending_bytes;
    try std.testing.expectError(
        error.ChunkLimit,
        slot.enqueueResyncSnapshot(tracker, &.{ "prefix", "final" }),
    );
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(tracker));
    try std.testing.expectEqual(max_chunks_per_slot - control_chunk_reserve - 1, slot.chunk_len);
    try std.testing.expectEqual(pending_before, slot.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), try slot.screenResidentBytes(tracker));
}

test "owned resync consumes every buffer and atomically restores a tracker" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(tracker);
    const chunks = [_][]u8{
        try std.testing.allocator.dupe(u8, "fresh-a"),
        try std.testing.allocator.dupe(u8, "fresh-b"),
    };
    try slot.enqueueOwnedResyncSnapshot(tracker, &chunks);
    try std.testing.expectEqual(ScreenState.resync_draining, try slot.screenState(tracker));
    try std.testing.expectEqual(@as(usize, 2), slot.chunk_len);
    try slot.consumeWritten("fresh-a".len + "fresh-b".len);
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(tracker));
    try std.testing.expectEqual(@as(usize, 0), global.resident_bytes);
}

test "owned resync admits exact recovery ceiling rejects plus one and detaches while draining" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(tracker);
    const exact = [_][]u8{try std.testing.allocator.alloc(u8, resync_batch_bytes)};
    try slot.enqueueOwnedResyncSnapshot(tracker, &exact);
    try std.testing.expectEqual(ScreenState.resync_draining, try slot.screenState(tracker));
    try slot.purgeAndDestroyScreenTracker(tracker);
    try std.testing.expectEqual(@as(usize, 0), slot.pending_bytes);

    const rejected_tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(rejected_tracker);
    const over = [_][]u8{try std.testing.allocator.alloc(u8, resync_batch_bytes + 1)};
    try std.testing.expectError(
        error.ScreenInvalidated,
        slot.enqueueOwnedResyncSnapshot(rejected_tracker, &over),
    );
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(rejected_tracker));
}

test "owned resync consumes all buffers when tracker provenance is stale" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    var stale = try slot.createScreenTracker();
    stale.generation +%= 1;
    const chunks = [_][]u8{
        try std.testing.allocator.dupe(u8, "a"),
        try std.testing.allocator.dupe(u8, "b"),
    };
    try std.testing.expectError(
        error.Stale,
        slot.enqueueOwnedResyncSnapshot(stale, &chunks),
    );
    try std.testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), global.resident_bytes);
}

test "multi chunk resync middle OOM rolls back allocation and accounting" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 3 },
    );
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        failing.allocator(),
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try slot.invalidateScreen(tracker);
    try std.testing.expectError(
        error.OutOfMemory,
        slot.enqueueResyncSnapshot(tracker, &.{ "prefix", "final" }),
    );
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(tracker));
    try std.testing.expectEqual(@as(usize, 0), try slot.screenResidentBytes(tracker));
    try std.testing.expectEqual(@as(usize, 0), slot.chunk_len);
    try std.testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), slot.resident_bytes);
    try std.testing.expectEqual(@as(usize, 0), global.resident_bytes);
    try std.testing.expectEqual(@as(usize, 0), global.shared_bytes);
}

test "connection slot turn fairness has independent exact read and write ceilings" {
    var turn: TurnBudget = .{};
    try std.testing.expect(turn.allowRead(turn_bytes, turn_frames));
    try std.testing.expect(!turn.allowRead(1, 0));
    try std.testing.expect(turn.allowWrite(turn_bytes, turn_frames));
    try std.testing.expect(!turn.allowWrite(0, 1));
}

test "connection slot table enforces 32 cap, generation ABA, and round-robin fairness" {
    var table: SlotTable = .{};
    var admissions: [max_connections]SlotTable.Admission = undefined;
    for (&admissions) |*item| item.* = try table.admit();
    try std.testing.expectError(error.Full, table.admit());

    var ready = [_]bool{true} ** max_connections;
    for (admissions) |expected| {
        const selected = table.nextReady(&ready).?;
        try std.testing.expectEqual(expected.index, selected.index);
    }
    const first = admissions[0];
    try table.close(first);
    try std.testing.expectError(error.Stale, table.close(first));
    const replacement = try table.admit();
    try std.testing.expectEqual(first.index, replacement.index);
    try std.testing.expect(replacement.key.monotonic_id > first.key.monotonic_id);
    try std.testing.expect(replacement.key.slot_generation > first.key.slot_generation);

    // Only one ready slot still advances from the current cursor without starving.
    @memset(&ready, false);
    ready[replacement.index] = true;
    try std.testing.expectEqual(replacement.index, table.nextReady(&ready).?.index);

    table.entries[replacement.index].generation = std.math.maxInt(u64);
    table.entries[replacement.index].key.?.slot_generation = std.math.maxInt(u64);
    const terminal = SlotTable.Admission{
        .index = replacement.index,
        .key = table.entries[replacement.index].key.?,
    };
    try table.close(terminal);
    try std.testing.expect(table.entries[replacement.index].retired);
    try std.testing.expect(table.entries[replacement.index].key == null);
}

test "global screen ceiling preserves every connection control reserve" {
    var budget: GlobalBudget = .{};
    const max_screen_global = shared_steady_bytes;
    try std.testing.expect(budget.reserveScreen(max_screen_global));
    try std.testing.expect(!budget.reserveScreen(1));
    for (0..max_connections) |_| try std.testing.expect(budget.reserveControl(0, control_reserve_bytes));
    try std.testing.expectEqual(
        global_bytes - base_replacement_headroom_bytes,
        budget.resident_bytes,
    );
    for (0..max_connections) |_| budget.releaseControl(control_reserve_bytes, control_reserve_bytes);
    budget.releaseScreen(max_screen_global);
}

test "reactor atomically admits authority control across two stable slots" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const old = try reactor.admit();
    const requester = try reactor.admit();
    const revoked = try std.testing.allocator.dupe(u8, "controller.revoked");
    const success = try std.testing.allocator.dupe(u8, "takeover.success");
    var owned = false;
    defer if (!owned) {
        std.testing.allocator.free(revoked);
        std.testing.allocator.free(success);
    };

    try reactor.enqueueOwnedControlBatch(&.{
        .{ .admission = old, .bytes = revoked },
        .{ .admission = requester, .bytes = success },
    });
    owned = true;
    try std.testing.expectEqualStrings(
        "controller.revoked",
        (try reactor.get(old)).firstPending().?.bytes,
    );
    try std.testing.expectEqualStrings(
        "takeover.success",
        (try reactor.get(requester)).firstPending().?.bytes,
    );
}

test "reactor atomically admits resize response and subscription events" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const requester = try reactor.admit();
    const observer = try reactor.admit();
    const requester_tracker = try (try reactor.get(requester)).createScreenTracker();
    const observer_tracker = try (try reactor.get(observer)).createScreenTracker();
    const response = try std.testing.allocator.dupe(u8, "resize.response");
    const requester_event = try std.testing.allocator.dupe(u8, "resize.requester.event");
    const observer_event = try std.testing.allocator.dupe(u8, "resize.observer.event");
    var owned = false;
    defer if (!owned) {
        std.testing.allocator.free(response);
        std.testing.allocator.free(requester_event);
        std.testing.allocator.free(observer_event);
    };

    const control = ReactorCore.OwnedControlItem{
        .admission = requester,
        .bytes = response,
    };
    const events = [_]ReactorCore.OwnedScreenItem{
        .{
            .admission = requester,
            .tracker = requester_tracker,
            .bytes = requester_event,
        },
        .{
            .admission = observer,
            .tracker = observer_tracker,
            .bytes = observer_event,
        },
    };
    const before = reactor.accountingSnapshot();
    try reactor.preflightOwnedControlAndScreenBatch(control, &events);
    try std.testing.expectEqual(
        before.resident_bytes,
        reactor.accountingSnapshot().resident_bytes,
    );
    try reactor.enqueueOwnedControlAndScreenBatch(control, &events);
    owned = true;
    try std.testing.expectEqualStrings(
        "resize.response",
        (try reactor.get(requester)).firstPending().?.bytes,
    );
    try std.testing.expectEqualStrings(
        "resize.observer.event",
        (try reactor.get(observer)).firstPending().?.bytes,
    );
}

test "resize local observer preflight accumulates multiple streams on one connection" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const requester = try reactor.admit();
    const observer = try reactor.admit();
    const observer_slot = try reactor.get(observer);
    const first = try observer_slot.createScreenTracker();
    const second = try observer_slot.createScreenTracker();
    observer_slot.chunk_len = max_chunks_per_slot - control_chunk_reserve - 1;
    defer observer_slot.chunk_len = 0;
    var first_byte = [_]u8{'a'};
    var second_byte = [_]u8{'b'};

    const offender = reactor.firstLocallyUnadmissibleScreenConnection(&.{
        .{ .admission = observer, .tracker = first, .bytes = &first_byte },
        .{ .admission = observer, .tracker = second, .bytes = &second_byte },
    }, requester).?;
    try std.testing.expectEqualDeep(observer, offender);
}

test "mixed publication reservation rejects a cancelled token after lane reuse" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const requester = try reactor.admit();
    const tracker = try (try reactor.get(requester)).createScreenTracker();
    var response_a = [_]u8{'a'};
    var event_a = [_]u8{'b'};
    var prepared_a = try reactor.prepareOwnedControlAndScreenBatch(
        .{ .admission = requester, .bytes = &response_a },
        &.{.{ .admission = requester, .tracker = tracker, .bytes = &event_a }},
    );
    var stale_a = prepared_a;
    try reactor.cancelPreparedControlAndScreenBatch(&prepared_a);

    var response_b = [_]u8{'c'};
    var event_b = [_]u8{'d'};
    var prepared_b = try reactor.prepareOwnedControlAndScreenBatch(
        .{ .admission = requester, .bytes = &response_b },
        &.{.{ .admission = requester, .tracker = tracker, .bytes = &event_b }},
    );
    try std.testing.expectError(
        error.StaleReservation,
        reactor.validatePreparedControlAndScreenBatch(&stale_a),
    );
    try std.testing.expectError(
        error.StaleReservation,
        reactor.commitPreparedControlAndScreenBatch(&stale_a),
    );
    try reactor.cancelPreparedControlAndScreenBatch(&prepared_b);
}

test "resize batch cap plus one leaves every destination and accounting unchanged" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const requester = try reactor.admit();
    const observer = try reactor.admit();
    const requester_tracker = try (try reactor.get(requester)).createScreenTracker();
    const observer_slot = try reactor.get(observer);
    const observer_tracker = try observer_slot.createScreenTracker();
    const full = try std.testing.allocator.alloc(u8, screen_soft_bytes);
    @memset(full, 'x');
    try observer_slot.enqueueOwnedScreen(observer_tracker, full);

    const response = try std.testing.allocator.dupe(u8, "resize.response");
    defer std.testing.allocator.free(response);
    const requester_event = try std.testing.allocator.dupe(u8, "requester.event");
    defer std.testing.allocator.free(requester_event);
    const observer_event = try std.testing.allocator.dupe(u8, "observer.event");
    defer std.testing.allocator.free(observer_event);
    const control = ReactorCore.OwnedControlItem{
        .admission = requester,
        .bytes = response,
    };
    const events = [_]ReactorCore.OwnedScreenItem{
        .{
            .admission = requester,
            .tracker = requester_tracker,
            .bytes = requester_event,
        },
        .{
            .admission = observer,
            .tracker = observer_tracker,
            .bytes = observer_event,
        },
    };
    const before = reactor.accountingSnapshot();
    try std.testing.expectError(
        error.ScreenInvalidated,
        reactor.preflightOwnedControlAndScreenBatch(control, &events),
    );
    try std.testing.expect((try reactor.get(requester)).firstPending() == null);
    try std.testing.expectEqual(ScreenState.valid, try observer_slot.screenState(observer_tracker));
    try std.testing.expectEqualDeep(before, reactor.accountingSnapshot());
}

test "authority control batch rejects stale peer without a requester prefix" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const stale = try reactor.admit();
    try reactor.closeConnection(stale);
    const requester = try reactor.admit();
    const revoked = try std.testing.allocator.dupe(u8, "controller.revoked");
    defer std.testing.allocator.free(revoked);
    const success = try std.testing.allocator.dupe(u8, "takeover.success");
    defer std.testing.allocator.free(success);
    const before = reactor.accountingSnapshot();

    try std.testing.expectError(
        error.Stale,
        reactor.enqueueOwnedControlBatch(&.{
            .{ .admission = stale, .bytes = revoked },
            .{ .admission = requester, .bytes = success },
        }),
    );
    try std.testing.expect((try reactor.get(requester)).firstPending() == null);
    try std.testing.expectEqual(before.resident_bytes, reactor.accountingSnapshot().resident_bytes);
    try std.testing.expectEqual(before.shared_bytes, reactor.accountingSnapshot().shared_bytes);
}

test "authority control batch preserves FIFO when old and requester share one slot" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const shared = try reactor.admit();
    const revoked = try std.testing.allocator.dupe(u8, "controller.revoked");
    const success = try std.testing.allocator.dupe(u8, "takeover.success");
    var owned = false;
    defer if (!owned) {
        std.testing.allocator.free(revoked);
        std.testing.allocator.free(success);
    };

    try reactor.enqueueOwnedControlBatch(&.{
        .{ .admission = shared, .bytes = revoked },
        .{ .admission = shared, .bytes = success },
    });
    owned = true;
    const slot = try reactor.get(shared);
    try std.testing.expectEqualStrings("controller.revoked", slot.firstPending().?.bytes);
    try slot.consumeWritten("controller.revoked".len);
    try std.testing.expectEqualStrings("takeover.success", slot.firstPending().?.bytes);
}

test "authority control batch exact chunk cap rejects both frames without prefix" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const shared = try reactor.admit();
    const slot = try reactor.get(shared);
    for (0..max_chunks_per_slot - 1) |_|
        try slot.enqueueControl("x");
    const before = reactor.accountingSnapshot();
    const before_chunks = slot.chunk_len;
    const revoked = try std.testing.allocator.dupe(u8, "controller.revoked");
    defer std.testing.allocator.free(revoked);
    const success = try std.testing.allocator.dupe(u8, "takeover.success");
    defer std.testing.allocator.free(success);
    try std.testing.expectError(
        error.ChunkLimit,
        reactor.enqueueOwnedControlBatch(&.{
            .{ .admission = shared, .bytes = revoked },
            .{ .admission = shared, .bytes = success },
        }),
    );
    try std.testing.expectEqual(before_chunks, slot.chunk_len);
    try std.testing.expectEqual(before.resident_bytes, reactor.accountingSnapshot().resident_bytes);
    try std.testing.expectEqual(before.shared_bytes, reactor.accountingSnapshot().shared_bytes);
}

test "authority control batch admits exact byte cap and rejects cap plus one without prefix" {
    const testing = std.testing;
    inline for (.{ false, true }) |plus_one| {
        const reactor = try ReactorCore.create(testing.allocator);
        defer reactor.destroy();
        const shared = try reactor.admit();
        const slot = try reactor.get(shared);
        const revoked = try testing.allocator.dupe(u8, "controller.revoked");
        var revoked_owned = true;
        defer if (revoked_owned) testing.allocator.free(revoked);
        const success = try testing.allocator.dupe(u8, "takeover.success");
        var success_owned = true;
        defer if (success_owned) testing.allocator.free(success);
        const prefix_len = per_slot_bytes - revoked.len - success.len +
            @intFromBool(plus_one);
        const prefix = try testing.allocator.alloc(u8, prefix_len);
        @memset(prefix, 'p');
        try slot.enqueueOwnedControl(prefix);
        const before = reactor.accountingSnapshot();
        const before_chunks = slot.chunk_len;
        const result = reactor.enqueueOwnedControlBatch(&.{
            .{ .admission = shared, .bytes = revoked },
            .{ .admission = shared, .bytes = success },
        });
        if (plus_one) {
            try testing.expectError(error.SlotLimit, result);
            try testing.expectEqual(before_chunks, slot.chunk_len);
            try testing.expectEqual(
                before.resident_bytes,
                reactor.accountingSnapshot().resident_bytes,
            );
            try testing.expectEqual(
                before.shared_bytes,
                reactor.accountingSnapshot().shared_bytes,
            );
        } else {
            try result;
            revoked_owned = false;
            success_owned = false;
            try testing.expectEqual(per_slot_bytes, slot.pending_bytes);
        }
    }
}

test "authority control batch honors cross-slot shared exact cap without either prefix" {
    const testing = std.testing;
    inline for (.{ false, true }) |plus_one| {
        const reactor = try ReactorCore.create(testing.allocator);
        defer reactor.destroy();
        const old = try reactor.admit();
        const requester = try reactor.admit();
        const old_slot = try reactor.get(old);
        const requester_slot = try reactor.get(requester);
        const old_reserve = try testing.allocator.alloc(u8, control_reserve_bytes);
        defer testing.allocator.free(old_reserve);
        @memset(old_reserve, 'o');
        const requester_reserve = try testing.allocator.alloc(u8, control_reserve_bytes);
        defer testing.allocator.free(requester_reserve);
        @memset(requester_reserve, 'r');
        try old_slot.enqueueControl(old_reserve);
        try requester_slot.enqueueControl(requester_reserve);

        const revoked = try testing.allocator.dupe(u8, "controller.revoked");
        var revoked_owned = true;
        defer if (revoked_owned) testing.allocator.free(revoked);
        const success = try testing.allocator.dupe(u8, "takeover.success");
        var success_owned = true;
        defer if (success_owned) testing.allocator.free(success);
        const authority_bytes = revoked.len + success.len;
        const seeded_shared = shared_steady_bytes - authority_bytes +
            @intFromBool(plus_one);
        try testing.expect(reactor.budget.reserveScreen(seeded_shared));
        defer reactor.budget.releaseScreen(seeded_shared);
        const before = reactor.accountingSnapshot();
        const old_chunks = old_slot.chunk_len;
        const requester_chunks = requester_slot.chunk_len;

        const result = reactor.enqueueOwnedControlBatch(&.{
            .{ .admission = old, .bytes = revoked },
            .{ .admission = requester, .bytes = success },
        });
        if (plus_one) {
            try testing.expectError(error.GlobalLimit, result);
            try testing.expectEqual(old_chunks, old_slot.chunk_len);
            try testing.expectEqual(requester_chunks, requester_slot.chunk_len);
            try testing.expectEqual(
                before.resident_bytes,
                reactor.accountingSnapshot().resident_bytes,
            );
            try testing.expectEqual(
                before.shared_bytes,
                reactor.accountingSnapshot().shared_bytes,
            );
        } else {
            try result;
            revoked_owned = false;
            success_owned = false;
            try testing.expectEqual(shared_steady_bytes, reactor.budget.shared_bytes);
            try testing.expectEqual(old_chunks + 1, old_slot.chunk_len);
            try testing.expectEqual(requester_chunks + 1, requester_slot.chunk_len);
        }
        try old_slot.consumeWritten(old_slot.pending_bytes);
        try requester_slot.consumeWritten(requester_slot.pending_bytes);
    }
}

test "authority control batch reaches global and shared hard caps atomically" {
    const testing = std.testing;
    inline for (.{ false, true }) |plus_one| {
        const reactor = try ReactorCore.create(testing.allocator);
        defer reactor.destroy();
        var admissions: [max_connections]SlotTable.Admission = undefined;
        for (&admissions) |*admission| admission.* = try reactor.admit();
        const reserve = try testing.allocator.alloc(u8, control_reserve_bytes);
        defer testing.allocator.free(reserve);
        @memset(reserve, 'c');
        for (admissions) |admission|
            try (try reactor.get(admission)).enqueueControl(reserve);
        const old = admissions[max_connections - 2];
        const requester = admissions[max_connections - 1];
        const old_slot = try reactor.get(old);
        const requester_slot = try reactor.get(requester);
        const tracker = try old_slot.createScreenTracker();
        const retained = try old_slot.reserveBaseUpdate(tracker, base_update_max_bytes);
        try old_slot.commitBaseUpdate(retained, base_update_max_bytes);
        const authority_bytes: usize = 1024 * 1024;
        const steady_screen = shared_steady_bytes - base_update_max_bytes -
            authority_bytes;
        try testing.expect(reactor.budget.reserveScreen(steady_screen));
        const replacement = try old_slot.reserveBaseUpdate(tracker, base_update_max_bytes);
        var seeded = true;
        defer {
            if (seeded) {
                old_slot.rollbackBaseUpdate(replacement) catch unreachable;
                old_slot.releaseBaseState(tracker) catch unreachable;
                reactor.budget.releaseScreen(steady_screen);
            }
        }

        const target_bytes = authority_bytes + @intFromBool(plus_one);
        const revoked = try testing.allocator.alloc(u8, target_bytes / 2);
        var revoked_owned = true;
        defer if (revoked_owned) testing.allocator.free(revoked);
        @memset(revoked, 'v');
        const success = try testing.allocator.alloc(u8, target_bytes - revoked.len);
        var success_owned = true;
        defer if (success_owned) testing.allocator.free(success);
        @memset(success, 's');
        const before = reactor.accountingSnapshot();
        const old_chunks = old_slot.chunk_len;
        const requester_chunks = requester_slot.chunk_len;

        const result = reactor.enqueueOwnedControlBatch(&.{
            .{ .admission = old, .bytes = revoked },
            .{ .admission = requester, .bytes = success },
        });
        if (plus_one) {
            try testing.expectError(error.GlobalLimit, result);
            try testing.expectEqual(old_chunks, old_slot.chunk_len);
            try testing.expectEqual(requester_chunks, requester_slot.chunk_len);
            try testing.expectEqual(
                before.resident_bytes,
                reactor.accountingSnapshot().resident_bytes,
            );
            try testing.expectEqual(
                before.shared_bytes,
                reactor.accountingSnapshot().shared_bytes,
            );
        } else {
            try result;
            revoked_owned = false;
            success_owned = false;
            try testing.expectEqual(global_bytes, reactor.budget.resident_bytes);
            try testing.expectEqual(shared_hard_bytes, reactor.budget.shared_bytes);
        }
        for (admissions) |admission| {
            const slot = try reactor.get(admission);
            try slot.consumeWritten(slot.pending_bytes);
        }
        try old_slot.rollbackBaseUpdate(replacement);
        try old_slot.releaseBaseState(tracker);
        reactor.budget.releaseScreen(steady_screen);
        seeded = false;
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.shared_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
    }
}

test "connection slot control resident cap and chunk cap reject cap plus one" {
    const testing = std.testing;
    var global: GlobalBudget = .{};
    var slot = try Slot.init(testing.allocator, &global, .{ .monotonic_id = 1, .slot_generation = 1 });
    defer slot.deinit();
    const exact = try testing.allocator.alloc(u8, per_slot_bytes);
    defer testing.allocator.free(exact);
    @memset(exact, 1);
    try slot.enqueueControl(exact);
    try testing.expectError(error.SlotLimit, slot.enqueueControl("x"));
    try slot.consumeWritten(exact.len);

    for (0..max_chunks_per_slot) |_| try slot.enqueueControl("x");
    try testing.expectError(error.ChunkLimit, slot.enqueueControl("x"));
    try slot.consumeWritten(max_chunks_per_slot);
}

test "screen chunk pressure preserves control chunk reserve and pending view" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();

    for (0..max_chunks_per_slot - control_chunk_reserve) |_| try slot.enqueueScreen(tracker, "s");
    try std.testing.expectError(error.ChunkLimit, slot.enqueueScreen(tracker, "s"));
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(tracker));
    for (0..control_chunk_reserve) |_| try slot.enqueueControl("control");
    try std.testing.expectError(error.ChunkLimit, slot.enqueueControl("x"));

    const first = slot.firstPending().?;
    try std.testing.expectEqual(QueueClass.screen, first.class);
    try std.testing.expectEqualStrings("s", first.bytes);
    try slot.consumeWritten(1);
    try std.testing.expectEqual(max_chunks_per_slot - 1, slot.chunk_len);
}

test "screen invalidation and resync are isolated per subscription" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const noisy = try slot.createScreenTracker();
    const healthy = try slot.createScreenTracker();

    const exact = try std.testing.allocator.alloc(u8, screen_soft_bytes);
    defer std.testing.allocator.free(exact);
    @memset(exact, 1);
    try slot.enqueueScreen(noisy, exact);
    try std.testing.expectError(error.ScreenInvalidated, slot.enqueueScreen(noisy, "x"));
    try slot.enqueueScreen(healthy, "independent");
    try std.testing.expectEqual(ScreenState.invalidated, try slot.screenState(noisy));
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(healthy));

    try slot.consumeWritten(exact.len + "independent".len);
    try slot.enqueueResyncSnapshot(noisy, &.{"fresh"});
    try std.testing.expectEqual(ScreenState.resync_draining, try slot.screenState(noisy));
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(healthy));
    try slot.consumeWritten("fresh".len);
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(noisy));
}

test "atomic screen batch preserves requester state and ownership on global pressure" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try std.testing.expect(global.reserveScreen(shared_steady_bytes - 4));
    defer global.releaseScreen(shared_steady_bytes - 4);
    const frames = [_][]u8{
        try std.testing.allocator.dupe(u8, "abc"),
        try std.testing.allocator.dupe(u8, "def"),
    };
    defer for (frames) |bytes| std.testing.allocator.free(bytes);

    try std.testing.expectError(
        error.GlobalLimit,
        slot.enqueueOwnedScreenBatch(tracker, &frames),
    );
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(tracker));
    try std.testing.expectEqual(@as(usize, 0), slot.chunk_len);
    try std.testing.expectEqual(@as(usize, 0), slot.resident_bytes);
}

test "accounting snapshot retains intra-turn prepared and slot high water" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const tracker = try slot.createScreenTracker();
    try slot.enqueueScreen(tracker, "queued");
    try slot.enqueueControl("control");
    const reservation = try slot.reserveBaseUpdate(tracker, 16);
    try slot.rollbackBaseUpdate(reservation);
    const peak = reactor.accountingSnapshot();
    try std.testing.expect(peak.peak_resident_bytes >= "queued".len + "control".len + 16);
    try std.testing.expect(peak.peak_prepared_base_bytes >= 16);
    try std.testing.expect(peak.peak_slot_queue_bytes >= "queued".len + "control".len);
    try std.testing.expect(peak.peak_slot_base_bytes >= 16);
    try std.testing.expect(peak.peak_slot_control_bytes >= "control".len);
    try std.testing.expect(peak.peak_slot_total_bytes >= "queued".len + "control".len + 16);
    try std.testing.expect(peak.peak_resident_bytes <= global_bytes);
    try std.testing.expect(peak.peak_slot_queue_bytes <= per_slot_bytes);
    try std.testing.expect(peak.peak_slot_base_bytes <= base_per_slot_bytes);
    try std.testing.expect(peak.peak_slot_total_bytes <= total_per_slot_bytes);
}

test "fixture peak reset starts at exact current charged accounting" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const tracker = try slot.createScreenTracker();
    try slot.enqueueScreen(tracker, "screen");
    try slot.enqueueControl("control");
    const reservation = try slot.reserveBaseUpdate(tracker, 16);
    defer slot.rollbackBaseUpdate(reservation) catch unreachable;

    reactor.resetFixturePeaksToCurrent();
    const reset = reactor.accountingSnapshot();
    try std.testing.expectEqual(reset.resident_bytes, reset.peak_resident_bytes);
    try std.testing.expectEqual(reset.shared_bytes, reset.peak_shared_bytes);
    try std.testing.expectEqual(
        reset.prepared_base_bytes,
        reset.peak_prepared_base_bytes,
    );
    try std.testing.expectEqual(
        reset.prepared_reclaim_bytes,
        reset.peak_prepared_reclaim_bytes,
    );
    try std.testing.expectEqual(slot.resident_bytes, reset.peak_slot_queue_bytes);
    try std.testing.expectEqual(slot.base_resident_bytes, reset.peak_slot_base_bytes);
    try std.testing.expectEqual(
        slot.control_resident_bytes,
        reset.peak_slot_control_bytes,
    );
    try std.testing.expectEqual(
        slot.resident_bytes + slot.base_resident_bytes,
        reset.peak_slot_total_bytes,
    );
}

test "connection slot fixed ring stays bounded while a tail remains across long churn" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(std.testing.allocator, &global, .{ .monotonic_id = 1, .slot_generation = 1 });
    defer slot.deinit();
    try slot.enqueueControl("x");
    for (0..max_chunks_per_slot * 2 + 7) |_| {
        try slot.enqueueControl("y");
        try slot.consumeWritten(1);
        try std.testing.expectEqual(@as(usize, 1), slot.chunk_len);
    }
    try std.testing.expectEqual(@as(usize, 1), slot.resident_bytes);
    try std.testing.expectEqual(@as(usize, 1), global.resident_bytes);
}

test "connection slot partial deadline advances only on progress" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(std.testing.allocator, &global, .{ .monotonic_id = 1, .slot_generation = 1 });
    defer slot.deinit();
    slot.notePartial(.read, 100, true);
    slot.notePartial(.read, 100 + partial_deadline_ns - 1, false);
    try std.testing.expect(!slot.partialExpired(.read, 100 + partial_deadline_ns - 1));
    try std.testing.expect(slot.partialExpired(.read, 100 + partial_deadline_ns));
    slot.notePartial(.read, 100 + partial_deadline_ns, true);
    try std.testing.expect(!slot.partialExpired(.read, 100 + partial_deadline_ns));
    try std.testing.expect(slot.partialExpired(.read, 100 + partial_absolute_deadline_ns));

    // Outbound progress cannot keep an inbound slowloris alive, or vice versa.
    slot.notePartial(.write, 100 + partial_deadline_ns, true);
    try std.testing.expect(slot.partialExpired(.read, 100 + partial_absolute_deadline_ns));
    try std.testing.expect(!slot.partialExpired(.write, 100 + partial_deadline_ns));
}

test "purging an unsent screen head resets its inherited write deadline" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const slow = try slot.createScreenTracker();
    const sibling = try slot.createScreenTracker();

    try slot.enqueueScreen(slow, "slow");
    try slot.enqueueScreen(sibling, "sibling");
    slot.notePartial(.write, 100, false);
    try std.testing.expect(slot.partialExpired(.write, 100 + partial_deadline_ns));

    try slot.invalidateAndPurgeScreenTracker(slow);
    try std.testing.expect(!slot.partialExpired(.write, 100 + partial_absolute_deadline_ns));
    const head = slot.firstPending().?;
    try std.testing.expectEqual(QueueClass.screen, head.class);
    try std.testing.expectEqualStrings("sibling", head.bytes);

    const next_attempt_ns = 100 + partial_absolute_deadline_ns;
    slot.notePartial(.write, next_attempt_ns, false);
    try std.testing.expect(!slot.partialExpired(
        .write,
        next_attempt_ns + partial_deadline_ns - 1,
    ));
    try std.testing.expect(slot.partialExpired(
        .write,
        next_attempt_ns + partial_deadline_ns,
    ));
}

test "purging a partially sent screen head remains fail-close only" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const slow = try slot.createScreenTracker();

    try slot.enqueueScreen(slow, "slow");
    try slot.consumeWritten(1);
    try std.testing.expectError(
        error.PartialFrame,
        slot.invalidateAndPurgeScreenTracker(slow),
    );
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(slow));
    try std.testing.expectEqualStrings("low", slot.firstPending().?.bytes);
}

test "write stall evidence requires no progress and clears on readiness or progress" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();

    slot.notePartial(.write, 10, true);
    try std.testing.expect(!slot.writeStallObserved());
    slot.notePartial(.write, 11, false);
    try std.testing.expect(slot.writeStallObserved());
    slot.noteWriteReady();
    try std.testing.expect(!slot.writeStallObserved());
    slot.notePartial(.write, 12, false);
    try std.testing.expect(slot.writeStallObserved());
    slot.notePartial(.write, 13, true);
    try std.testing.expect(!slot.writeStallObserved());
    slot.notePartial(.write, 14, false);
    slot.clearPartial(.write);
    try std.testing.expect(!slot.writeStallObserved());
}

test "resync retry backoff is closed before one second and opens at the exact boundary" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();

    try std.testing.expect(try slot.beginResyncAttempt(tracker, 100));
    try std.testing.expect(!try slot.resyncAttemptReady(
        tracker,
        100 + resync_retry_backoff_ns - 1,
    ));
    try std.testing.expect(!try slot.beginResyncAttempt(
        tracker,
        100 + resync_retry_backoff_ns - 1,
    ));
    try std.testing.expect(try slot.resyncAttemptReady(
        tracker,
        100 + resync_retry_backoff_ns,
    ));
    try std.testing.expect(try slot.beginResyncAttempt(
        tracker,
        100 + resync_retry_backoff_ns,
    ));
}

test "resync preflight includes prepared base and encoded batch global headroom" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    const exact_existing = shared_steady_bytes -
        base_update_max_bytes -
        resync_batch_bytes;
    try std.testing.expect(global.reserveScreen(exact_existing));
    try std.testing.expect(try slot.canAttemptResync(tracker));
    try std.testing.expect(global.reserveScreen(1));
    try std.testing.expect(!try slot.canAttemptResync(tracker));
    global.releaseScreen(exact_existing + 1);

    slot.base_resident_bytes = base_steady_per_slot_bytes - base_update_max_bytes;
    try std.testing.expect(try slot.canAttemptResync(tracker));
    slot.base_resident_bytes += 1;
    try std.testing.expect(!try slot.canAttemptResync(tracker));
    slot.base_resident_bytes = 0;
}

test "global pressure retry is closed before one second and opens at the exact boundary" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    try slot.deferGlobalPressure(tracker, 100);
    try std.testing.expect(!try slot.globalPressureReady(
        tracker,
        100 + resync_retry_backoff_ns - 1,
    ));
    try std.testing.expect(try slot.globalPressureReady(
        tracker,
        100 + resync_retry_backoff_ns,
    ));
}

test "connection slot upgrade drain rejects queued partial attached and dispatch state" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    try std.testing.expect(!reactor.drainedForUpgrade());
    const slot = try reactor.get(admission);
    try std.testing.expect(slot.idleForUpgrade());
    slot.notePartial(.read, 1, true);
    try std.testing.expect(!slot.idleForUpgrade());
    slot.clearPartial(.read);
    try slot.enqueueControl("x");
    try std.testing.expect(!slot.idleForUpgrade());
    try slot.consumeWritten(1);
    try slot.beginDispatch();
    try std.testing.expect(!slot.idleForUpgrade());
    try slot.endDispatch();
    try std.testing.expectError(error.CounterUnderflow, slot.endDispatch());
    try slot.attachStream();
    try std.testing.expect(!slot.idleForUpgrade());
    try slot.detachStream();
    try std.testing.expectError(error.CounterUnderflow, slot.detachStream());

    var gate: DrainModel = .{};
    try gate.tryBegin();
    gate.close();
    try std.testing.expectError(error.Closed, gate.tryBegin());
    try std.testing.expect(!gate.drained(reactor));
    try gate.end();
    try std.testing.expectError(error.CounterUnderflow, gate.end());
    try std.testing.expect(!gate.drained(reactor));
    try slot.enqueueControl("queued");
    try std.testing.expectError(error.Busy, reactor.closeIdleForUpgrade(admission));
    try std.testing.expect(!gate.drained(reactor));
    try slot.consumeWritten("queued".len);
    try reactor.closeIdleForUpgrade(admission);
    try std.testing.expect(gate.drained(reactor));
}

test "reactor empty budget repair preserves stale connection key ABA" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const stale = try reactor.admit();
    try reactor.closeConnection(stale);
    for (0..4) |counter| {
        switch (counter) {
            0 => reactor.budget.resident_bytes = 1,
            1 => reactor.budget.shared_bytes = 1,
            2 => reactor.budget.prepared_base_bytes = 1,
            3 => reactor.budget.prepared_reclaim_bytes = 1,
            else => unreachable,
        }
        try std.testing.expect(reactor.repairEmptyBudget());
        try std.testing.expect(reactor.drainedForUpgrade());
    }

    reactor.table.entries[0].key = .{ .monotonic_id = 999, .slot_generation = 999 };
    try std.testing.expect(!reactor.repairEmptyBudget());
    reactor.table.entries[0].key = null;

    const current = try reactor.admit();
    defer reactor.closeConnection(current) catch unreachable;
    try std.testing.expectError(error.Stale, reactor.get(stale));
    try std.testing.expect(!std.meta.eql(stale.key, current.key));
    try std.testing.expect(!reactor.repairEmptyBudget());
}

test "reactor upgrade close cannot be fooled by an idle slot clone" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const canonical = try reactor.get(admission);
    try canonical.enqueueControl("busy");

    var unrelated_budget: GlobalBudget = .{};
    var clone = try Slot.init(std.testing.allocator, &unrelated_budget, admission.key);
    defer clone.deinit();
    try std.testing.expect(clone.idleForUpgrade());
    try std.testing.expectError(error.Busy, reactor.closeIdleForUpgrade(admission));
    try std.testing.expectEqual(@as(usize, 1), reactor.activeCount());
}

test "reactor normal close purges queued accounting and stale admission" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const tracker = try slot.createScreenTracker();
    try slot.enqueueScreen(tracker, "screen");
    try slot.enqueueControl("control");
    try std.testing.expectError(error.Busy, slot.destroyScreenTracker(tracker));

    var ready = [_]bool{false} ** max_connections;
    ready[admission.index] = true;
    try std.testing.expectEqual(admission.index, reactor.nextReady(&ready).?.index);
    try reactor.closeConnection(admission);
    try std.testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
    try std.testing.expectEqual(@as(usize, 0), reactor.activeCount());
    try std.testing.expect(reactor.drainedForUpgrade());
    try std.testing.expectError(error.Stale, reactor.get(admission));
    try std.testing.expectError(error.Stale, reactor.closeConnection(admission));
}

test "screen tracker storage has an exact stable owner cap" {
    var global: GlobalBudget = .{};
    var slot = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer slot.deinit();
    var trackers: [max_screen_trackers_per_slot]ScreenTrackerKey = undefined;
    for (&trackers) |*tracker| tracker.* = try slot.createScreenTracker();
    try std.testing.expectError(error.Full, slot.createScreenTracker());
    try slot.destroyScreenTracker(trackers[0]);
    const replacement = try slot.createScreenTracker();
    try std.testing.expectEqual(trackers[0].index, replacement.index);
    try std.testing.expect(replacement.generation > trackers[0].generation);
    try std.testing.expectError(error.Stale, slot.enqueueScreen(trackers[0], "stale"));
    try std.testing.expectError(error.Stale, slot.destroyScreenTracker(trackers[0]));
}

test "screen tracker key rejects cross slot provenance" {
    var global: GlobalBudget = .{};
    var first = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 1, .slot_generation = 1 },
    );
    defer first.deinit();
    var second = try Slot.init(
        std.testing.allocator,
        &global,
        .{ .monotonic_id = 2, .slot_generation = 1 },
    );
    defer second.deinit();
    const foreign = try first.createScreenTracker();
    try std.testing.expectError(error.Stale, second.enqueueScreen(foreign, "cross-slot"));
    try first.invalidateScreen(foreign);
    try std.testing.expectError(
        error.Stale,
        second.enqueueResyncSnapshot(foreign, &.{"cross-slot"}),
    );
    try std.testing.expectError(error.Stale, second.destroyScreenTracker(foreign));
}

test "detach purge removes only one subscription screen queue and preserves FIFO control" {
    const allocator = std.testing.allocator;
    const reactor = try ReactorCore.create(allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const noisy = try slot.createScreenTracker();
    const healthy = try slot.createScreenTracker();
    try slot.enqueueScreen(noisy, "n1");
    try slot.enqueueControl("control");
    try slot.enqueueScreen(healthy, "h1");
    try slot.enqueueScreen(noisy, "n2");

    try slot.purgeAndDestroyScreenTracker(noisy);
    try std.testing.expectError(error.Stale, slot.screenState(noisy));
    try std.testing.expectEqualStrings("control", slot.firstPending().?.bytes);
    try slot.consumeWritten("control".len);
    try std.testing.expectEqualStrings("h1", slot.firstPending().?.bytes);
    try std.testing.expectEqual(@as(usize, 1), slot.chunk_len);
}

test "detach purge refuses to truncate a screen frame whose prefix reached the peer" {
    const allocator = std.testing.allocator;
    const reactor = try ReactorCore.create(allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const tracker = try slot.createScreenTracker();
    try slot.enqueueScreen(tracker, "frame");
    try slot.consumeWritten(1);
    try std.testing.expectError(
        error.PartialFrame,
        slot.purgeAndDestroyScreenTracker(tracker),
    );
    try std.testing.expectEqualStrings("rame", slot.firstPending().?.bytes);
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(tracker));
}

test "retained base reservation charges old and prepared then reconciles actual commit" {
    var global: GlobalBudget = .{};
    const key: ConnectionKey = .{ .monotonic_id = 1, .slot_generation = 1 };
    var slot = try Slot.init(std.testing.allocator, &global, key);
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();

    const first = try slot.reserveBaseUpdate(tracker, 10);
    try std.testing.expectEqual(@as(usize, 10), global.resident_bytes);
    try std.testing.expectEqual(@as(usize, 10), try slot.preparedBaseBytes(tracker));
    try slot.commitBaseUpdate(first, 6);
    try std.testing.expectEqual(@as(usize, 6), global.resident_bytes);
    try std.testing.expectEqual(@as(usize, 6), try slot.retainedBaseBytes(tracker));

    const second = try slot.reserveBaseUpdate(tracker, 9);
    try std.testing.expectEqual(@as(usize, 15), global.resident_bytes);
    try slot.commitBaseUpdate(second, 7);
    try std.testing.expectEqual(@as(usize, 7), global.resident_bytes);
    try std.testing.expectEqual(@as(usize, 7), try slot.retainedBaseBytes(tracker));
}

test "retained base rollback and detach release exactly without harming sibling" {
    var global: GlobalBudget = .{};
    const key: ConnectionKey = .{ .monotonic_id = 1, .slot_generation = 1 };
    var slot = try Slot.init(std.testing.allocator, &global, key);
    defer slot.deinit();
    const first = try slot.createScreenTracker();
    const sibling = try slot.createScreenTracker();

    const first_initial = try slot.reserveBaseUpdate(first, 10);
    try slot.commitBaseUpdate(first_initial, 8);
    const sibling_initial = try slot.reserveBaseUpdate(sibling, 6);
    try slot.commitBaseUpdate(sibling_initial, 5);
    const rejected = try slot.reserveBaseUpdate(first, 7);
    try slot.rollbackBaseUpdate(rejected);
    try std.testing.expectEqual(@as(usize, 13), global.resident_bytes);

    try slot.purgeAndDestroyScreenTracker(first);
    try std.testing.expectEqual(@as(usize, 5), global.resident_bytes);
    try std.testing.expectEqual(@as(usize, 5), try slot.retainedBaseBytes(sibling));
}

test "retained base exact cap rejects plus one and stale key changes no accounting" {
    var global: GlobalBudget = .{};
    const key: ConnectionKey = .{ .monotonic_id = 1, .slot_generation = 1 };
    var slot = try Slot.init(std.testing.allocator, &global, key);
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();

    try std.testing.expectError(
        error.InvalidAmount,
        slot.reserveBaseUpdate(tracker, base_update_max_bytes + 1),
    );
    try std.testing.expectEqual(@as(usize, 0), global.resident_bytes);
    const initial = try slot.reserveBaseUpdate(tracker, base_update_max_bytes);
    try std.testing.expectError(error.Busy, slot.reserveBaseUpdate(tracker, 1));
    try slot.commitBaseUpdate(initial, base_update_max_bytes);
    const replacement = try slot.reserveBaseUpdate(tracker, base_update_max_bytes);
    try std.testing.expectEqual(
        2 * base_update_max_bytes,
        global.resident_bytes,
    );
    try slot.rollbackBaseUpdate(replacement);
    try std.testing.expectEqual(base_update_max_bytes, global.resident_bytes);

    var stale = tracker;
    stale.generation +%= 1;
    try std.testing.expectError(error.Stale, slot.releaseBaseState(stale));
    try std.testing.expectEqual(base_update_max_bytes, global.resident_bytes);
}

test "retained base keeps one global replacement headroom and reuses it after rollback" {
    var global: GlobalBudget = .{};
    const first_key: ConnectionKey = .{ .monotonic_id = 1, .slot_generation = 1 };
    const second_key: ConnectionKey = .{ .monotonic_id = 2, .slot_generation = 1 };
    var first = try Slot.init(std.testing.allocator, &global, first_key);
    defer first.deinit();
    var second = try Slot.init(std.testing.allocator, &global, second_key);
    defer second.deinit();
    const first_tracker = try first.createScreenTracker();
    const second_tracker = try second.createScreenTracker();

    const first_initial = try first.reserveBaseUpdate(first_tracker, base_update_max_bytes);
    try first.commitBaseUpdate(first_initial, base_update_max_bytes);
    const second_initial = try second.reserveBaseUpdate(second_tracker, base_update_max_bytes);
    try second.commitBaseUpdate(second_initial, base_update_max_bytes);

    const replacement = try first.reserveBaseUpdate(first_tracker, base_update_max_bytes);
    try std.testing.expectError(
        error.GlobalLimit,
        second.reserveBaseUpdate(second_tracker, 1),
    );
    try first.rollbackBaseUpdate(replacement);
    const reused = try second.reserveBaseUpdate(second_tracker, 1);
    try second.rollbackBaseUpdate(reused);
    try std.testing.expectEqual(@as(usize, 0), global.prepared_base_bytes);
    try std.testing.expectEqual(@as(usize, 0), global.prepared_reclaim_bytes);
}

test "prepared reclaim admits eventual screen and control queue state under the hard cap" {
    var global: GlobalBudget = .{};
    const key: ConnectionKey = .{ .monotonic_id = 1, .slot_generation = 1 };
    var slot = try Slot.init(std.testing.allocator, &global, key);
    defer slot.deinit();
    const tracker = try slot.createScreenTracker();
    const initial = try slot.reserveBaseUpdate(tracker, base_update_max_bytes);
    try slot.commitBaseUpdate(initial, base_update_max_bytes);

    const replacement = try slot.reserveBaseUpdate(tracker, base_update_max_bytes);
    try slot.enqueueScreen(tracker, "screen");
    try slot.enqueueControl("control");
    try std.testing.expectEqual(
        base_update_max_bytes,
        global.prepared_reclaim_bytes,
    );
    try std.testing.expect(
        global.shared_bytes > base_update_max_bytes * 2,
    );
    try slot.commitBaseUpdate(replacement, base_update_max_bytes);
    try std.testing.expect(global.shared_bytes <= shared_steady_bytes);
    try std.testing.expectEqual(@as(usize, 0), global.prepared_reclaim_bytes);
}

test "stale active base reservation cannot mutate a reused reactor slot" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const old_admission = try reactor.admit();
    const old_slot = try reactor.get(old_admission);
    const old_tracker = try old_slot.createScreenTracker();
    const stale = try old_slot.reserveBaseUpdate(old_tracker, 8);
    try reactor.closeConnection(old_admission);
    try std.testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);

    const new_admission = try reactor.admit();
    const new_slot = try reactor.get(new_admission);
    const new_tracker = try new_slot.createScreenTracker();
    const current = try new_slot.reserveBaseUpdate(new_tracker, 7);
    const before = reactor.budget.resident_bytes;
    try std.testing.expectError(error.Stale, new_slot.commitBaseUpdate(stale, 1));
    try std.testing.expectEqual(before, reactor.budget.resident_bytes);
    try new_slot.rollbackBaseUpdate(current);
    try new_slot.purgeAndDestroyScreenTracker(new_tracker);
    try reactor.closeConnection(new_admission);
}

test "reactor upgrade drain includes retained and prepared base authority" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    const tracker = try slot.createScreenTracker();

    const committed = try slot.reserveBaseUpdate(tracker, 8);
    try slot.commitBaseUpdate(committed, 6);
    try std.testing.expect(!reactor.drainedForUpgrade());
    const prepared = try slot.reserveBaseUpdate(tracker, 7);
    try std.testing.expect(!reactor.drainedForUpgrade());
    try slot.rollbackBaseUpdate(prepared);
    try slot.purgeAndDestroyScreenTracker(tracker);
    try reactor.closeConnection(admission);
    try std.testing.expect(reactor.drainedForUpgrade());
    try std.testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try std.testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
}

test "connection key allocator never emits zero or reuses after overflow" {
    var allocator: KeyAllocator = .{};
    const first = try allocator.allocate(1);
    try std.testing.expectEqual(@as(u64, 1), first.monotonic_id);
    allocator.next_id = std.math.maxInt(u64);
    _ = try allocator.allocate(1);
    try std.testing.expectError(error.Exhausted, allocator.allocate(1));
    try std.testing.expectError(error.Exhausted, allocator.allocate(0));
}
