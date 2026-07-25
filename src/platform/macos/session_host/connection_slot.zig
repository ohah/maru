//! OS-neutral bounded connection-slot core for the session-host reactor.
//!
//! fd/poll/read/write는 platform adapter가 소유한다. 이 모듈은 stable key, queue memory, turn fairness,
//! partial-frame deadline, upgrade drain 가능 여부만 결정해 serial daemon을 multi-fd로 바꾸기 전에 불변식을 고정한다.

const std = @import("std");

pub const max_connections: usize = 32;
pub const per_slot_bytes: usize = 16 * 1024 * 1024;
pub const screen_soft_bytes: usize = 8 * 1024 * 1024;
pub const control_reserve_bytes: usize = 512 * 1024;
pub const screen_low_water_bytes: usize = 4 * 1024 * 1024;
pub const global_bytes: usize = 128 * 1024 * 1024;
pub const max_chunks_per_slot: usize = 4096;
pub const control_chunk_reserve: usize = 64;
pub const max_screen_trackers_per_slot: usize = 256;
pub const turn_bytes: usize = 1024 * 1024;
pub const turn_frames: usize = 64;
pub const partial_deadline_ns: u64 = 10 * std.time.ns_per_s;
pub const partial_absolute_deadline_ns: u64 = 30 * std.time.ns_per_s;

comptime {
    if (screen_soft_bytes + control_reserve_bytes > per_slot_bytes)
        @compileError("screen soft limit and control reserve exceed per-slot cap");
    if (per_slot_bytes * max_connections < global_bytes)
        @compileError("global cap cannot exceed the sum of all slot caps");
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

    fn reserveScreen(self: *GlobalBudget, amount: usize) bool {
        const next = std.math.add(usize, self.resident_bytes, amount) catch return false;
        if (next > global_bytes) return false;
        const next_shared = std.math.add(usize, self.shared_bytes, amount) catch return false;
        if (next_shared > global_bytes - max_connections * control_reserve_bytes) return false;
        self.resident_bytes = next;
        self.shared_bytes = next_shared;
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
        if (next_shared > global_bytes - max_connections * control_reserve_bytes) return false;
        self.resident_bytes = next;
        self.shared_bytes = next_shared;
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
};

pub const QueueClass = enum { screen, control };
pub const EnqueueError = error{ ScreenInvalidated, SlotLimit, GlobalLimit, ChunkLimit, OutOfMemory };
pub const ScreenState = enum { valid, invalidated, resync_pending };

pub const ScreenTracker = struct {
    state: ScreenState = .valid,
    resident_bytes: usize = 0,
};

pub const ScreenTrackerKey = struct {
    owner: ConnectionKey,
    index: u16,
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
    control_resident_bytes: usize = 0,
    screen_trackers: [max_screen_trackers_per_slot]ScreenTrackerEntry =
        [_]ScreenTrackerEntry{.{}} ** max_screen_trackers_per_slot,
    partial_started_ns: ?u64 = null,
    partial_progress_ns: ?u64 = null,
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
            std.debug.assert(tracker.resident_bytes == 0);
            self.allocator.destroy(tracker);
        }
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
        if (tracker.resident_bytes != 0 or tracker.state == .resync_pending) return error.Busy;
        entry.tracker = null;
        entry.generation = std.math.add(u64, entry.generation, 1) catch blk: {
            entry.retired = true;
            break :blk entry.generation;
        };
        self.allocator.destroy(tracker);
    }

    fn trackerEntry(self: *Slot, key: ScreenTrackerKey) error{Stale}!*ScreenTrackerEntry {
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
        return self.enqueue(.screen, key.index, bytes) catch |err| {
            tracker.state = .invalidated;
            return err;
        };
    }

    pub fn enqueueControl(self: *Slot, bytes: []const u8) EnqueueError!void {
        return self.enqueue(.control, null, bytes);
    }

    fn enqueue(
        self: *Slot,
        class: QueueClass,
        tracker_index: ?usize,
        bytes: []const u8,
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
            if (next_screen > screen_soft_bytes) {
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
                    self.screen_trackers[first.screen_tracker_index.?].tracker.?.resident_bytes -= charge;
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
            try self.enqueue(.screen, key.index, bytes);
            added += 1;
        }
        tracker.state = .valid;
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

    pub fn notePartial(self: *Slot, now_ns: u64, progressed: bool) void {
        if (self.partial_started_ns == null) self.partial_started_ns = now_ns;
        if (progressed or self.partial_progress_ns == null) self.partial_progress_ns = now_ns;
    }

    pub fn clearPartial(self: *Slot) void {
        self.partial_started_ns = null;
        self.partial_progress_ns = null;
    }

    pub fn partialExpired(self: *const Slot, now_ns: u64) bool {
        const last = self.partial_progress_ns orelse return false;
        const started = self.partial_started_ns.?;
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
        return self.partial_started_ns == null and self.pending_bytes == 0 and
            self.in_flight_dispatch == 0 and self.attached_streams == 0;
    }
};

fn chargeFor(payload_len: usize) usize {
    return payload_len;
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

    pub const Admission = SlotTable.Admission;

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

pub const AdmissionGate = struct {
    open: bool = true,
    in_flight: usize = 0,

    pub fn tryBegin(self: *AdmissionGate) error{ Closed, CounterExhausted }!void {
        if (!self.open) return error.Closed;
        self.in_flight = std.math.add(usize, self.in_flight, 1) catch
            return error.CounterExhausted;
    }

    pub fn end(self: *AdmissionGate) error{CounterUnderflow}!void {
        if (self.in_flight == 0) return error.CounterUnderflow;
        self.in_flight -= 1;
    }

    pub fn close(self: *AdmissionGate) void {
        self.open = false;
    }

    pub fn reopen(self: *AdmissionGate) void {
        self.open = true;
    }

    pub fn drained(self: *const AdmissionGate, reactor: *const ReactorCore) bool {
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
    try testing.expectEqual(ScreenState.valid, try slot.screenState(screen_tracker));
    try slot.consumeWritten("snapshot".len);
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
    const max_screen_global = global_bytes - max_connections * control_reserve_bytes;
    try std.testing.expect(budget.reserveScreen(max_screen_global));
    try std.testing.expect(!budget.reserveScreen(1));
    for (0..max_connections) |_| try std.testing.expect(budget.reserveControl(0, control_reserve_bytes));
    try std.testing.expectEqual(global_bytes, budget.resident_bytes);
    for (0..max_connections) |_| budget.releaseControl(control_reserve_bytes, control_reserve_bytes);
    budget.releaseScreen(max_screen_global);
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
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(noisy));
    try std.testing.expectEqual(ScreenState.valid, try slot.screenState(healthy));
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
    slot.notePartial(100, true);
    slot.notePartial(100 + partial_deadline_ns - 1, false);
    try std.testing.expect(!slot.partialExpired(100 + partial_deadline_ns - 1));
    try std.testing.expect(slot.partialExpired(100 + partial_deadline_ns));
    slot.notePartial(100 + partial_deadline_ns, true);
    try std.testing.expect(!slot.partialExpired(100 + partial_deadline_ns));
    try std.testing.expect(slot.partialExpired(100 + partial_absolute_deadline_ns));
}

test "connection slot upgrade drain rejects queued partial attached and dispatch state" {
    const reactor = try ReactorCore.create(std.testing.allocator);
    defer reactor.destroy();
    const admission = try reactor.admit();
    const slot = try reactor.get(admission);
    try std.testing.expect(slot.idleForUpgrade());
    slot.notePartial(1, true);
    try std.testing.expect(!slot.idleForUpgrade());
    slot.clearPartial();
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

    var gate: AdmissionGate = .{};
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

test "connection key allocator never emits zero or reuses after overflow" {
    var allocator: KeyAllocator = .{};
    const first = try allocator.allocate(1);
    try std.testing.expectEqual(@as(u64, 1), first.monotonic_id);
    allocator.next_id = std.math.maxInt(u64);
    _ = try allocator.allocate(1);
    try std.testing.expectError(error.Exhausted, allocator.allocate(1));
    try std.testing.expectError(error.Exhausted, allocator.allocate(0));
}
