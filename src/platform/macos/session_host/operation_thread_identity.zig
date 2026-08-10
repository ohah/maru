const builtin = @import("builtin");
const std = @import("std");
const process_seal_service = @import("process_seal_service.zig");

threadlocal var incarnation: u64 = 0;
var next_incarnation: std.atomic.Value(u64) = .init(1);

pub fn currentProcessId() u32 {
    return process_seal_service.currentProcessId();
}

pub const MintReceipt = struct {
    self_addr: usize = 0,
    slot_index: u16 = 0,
    slot_generation: u64 = 0,
    registry_key: u64 = 0,
    client_addr: usize = 0,
    operation_identity: u64 = 0,
    owner_process_id: u32 = 0,
    owner_process_nonce: u64 = 0,
    owner_thread_id: u64 = 0,
    owner_thread_incarnation: u64 = 0,
    live: bool = false,
    registry_token: std.atomic.Value(u64) = .init(0),

    pub fn pristineExact(self: *const @This()) bool {
        return self.self_addr == 0 and self.slot_index == 0 and self.slot_generation == 0 and
            self.registry_key == 0 and self.client_addr == 0 and self.operation_identity == 0 and
            self.owner_process_id == 0 and self.owner_process_nonce == 0 and
            self.owner_thread_id == 0 and self.owner_thread_incarnation == 0 and !self.live and
            self.registry_token.load(.acquire) == 0;
    }
};

const max_receipts = 4096;
const ReceiptEntry = struct {
    live: bool = false,
    generation: u64 = 1,
    key: u64 = 0,
    receipt_addr: usize = 0,
    client_addr: usize = 0,
    operation_identity: u64 = 0,
    owner_process_id: u32 = 0,
    owner_process_nonce: u64 = 0,
    owner_thread_id: u64 = 0,
    owner_thread_incarnation: u64 = 0,
};

fn initialFreeSlots() [max_receipts]u16 {
    @setEvalBranchQuota(max_receipts * 2);
    var result: [max_receipts]u16 = undefined;
    for (&result, 0..) |*slot, index| slot.* = @intCast(index);
    return result;
}

var receipt_mutex: std.atomic.Mutex = .unlocked;
var receipts: [max_receipts]ReceiptEntry = [_]ReceiptEntry{.{}} ** max_receipts;
var free_slots: [max_receipts]u16 = initialFreeSlots();
var free_count: usize = max_receipts;
var next_receipt_key: u64 = 1;
var registry_process_id: std.atomic.Value(u32) = .init(0);
var registry_process_nonce: std.atomic.Value(u64) = .init(0);

pub const ReceiptReadTestHook = struct {
    armed: std.atomic.Value(bool) = .init(false),
    reached: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
};
pub var receipt_read_test_hook: if (builtin.is_test) ReceiptReadTestHook else void =
    if (builtin.is_test) .{} else {};

fn waitForTestProceed() void {
    if (!builtin.is_test or !receipt_read_test_hook.armed.swap(false, .acq_rel)) return;
    receipt_read_test_hook.reached.store(true, .release);
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds +
        10 * std.time.ns_per_s;
    while (!receipt_read_test_hook.proceed.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) {
            // Publish the terminal test state before failing so a coordinator that is still
            // observing this hook cannot remain blocked behind the timed-out reader.
            receipt_read_test_hook.proceed.store(true, .release);
            @panic("mint receipt reader test hook timed out");
        }
        std.Thread.yield() catch {};
    }
}

fn registryProcessMatches(owner_process_id: u32, owner_process_nonce: u64) bool {
    return owner_process_id != 0 and owner_process_nonce != 0 and
        currentProcessId() == owner_process_id and
        registry_process_id.load(.acquire) == owner_process_id and
        registry_process_nonce.load(.acquire) == owner_process_nonce;
}

pub fn acquire() error{IdentityExhausted}!u64 {
    if (incarnation != 0) return incarnation;
    var observed = next_incarnation.load(.acquire);
    while (true) {
        if (observed == 0 or observed == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (next_incarnation.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual| {
            observed = actual;
            continue;
        }
        incarnation = observed;
        return observed;
    }
}

pub fn current() u64 {
    return incarnation;
}

pub fn matches(expected: u64) bool {
    return expected != 0 and incarnation == expected;
}

pub fn issueMintReceipt(
    out: *MintReceipt,
    client_addr: usize,
    operation_identity: u64,
    owner_process_id: u32,
    owner_process_nonce: u64,
    owner_thread_incarnation: u64,
) error{ InvalidOwner, IdentityExhausted, ResourceExhausted }!void {
    const current_pid = currentProcessId();
    const owner_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    if (!out.pristineExact() or client_addr == 0 or operation_identity == 0 or
        current_pid == 0 or owner_process_id != current_pid or owner_process_nonce == 0 or
        owner_thread_id == 0 or !matches(owner_thread_incarnation)) return error.InvalidOwner;
    if (registry_process_id.cmpxchgStrong(0, owner_process_id, .acq_rel, .acquire)) |observed|
        if (observed != owner_process_id) return error.InvalidOwner;
    if (registry_process_nonce.cmpxchgStrong(0, owner_process_nonce, .acq_rel, .acquire)) |observed|
        if (observed != owner_process_nonce) return error.InvalidOwner;
    if (!registryProcessMatches(owner_process_id, owner_process_nonce)) return error.InvalidOwner;
    while (!receipt_mutex.tryLock()) std.atomic.spinLoopHint();
    defer receipt_mutex.unlock();
    if (currentProcessId() != owner_process_id) return error.InvalidOwner;
    const key = next_receipt_key;
    if (key == 0 or key == std.math.maxInt(u64)) return error.IdentityExhausted;
    if (free_count == 0) return error.ResourceExhausted;
    free_count -= 1;
    const index: usize = free_slots[free_count];
    const entry = &receipts[index];
    if (entry.live or entry.generation == 0 or entry.generation == std.math.maxInt(u64)) {
        free_count += 1;
        return error.IdentityExhausted;
    }
    next_receipt_key = key + 1;
    entry.* = .{
        .live = true,
        .generation = entry.generation,
        .key = key,
        .receipt_addr = @intFromPtr(out),
        .client_addr = client_addr,
        .operation_identity = operation_identity,
        .owner_process_id = owner_process_id,
        .owner_process_nonce = owner_process_nonce,
        .owner_thread_id = owner_thread_id,
        .owner_thread_incarnation = owner_thread_incarnation,
    };
    out.self_addr = @intFromPtr(out);
    out.slot_index = @intCast(index);
    out.slot_generation = entry.generation;
    out.registry_key = key;
    out.client_addr = client_addr;
    out.operation_identity = operation_identity;
    out.owner_process_id = owner_process_id;
    out.owner_process_nonce = owner_process_nonce;
    out.owner_thread_id = owner_thread_id;
    out.owner_thread_incarnation = owner_thread_incarnation;
    out.live = true;
    out.registry_token.store(@as(u64, @intCast(index)) + 1, .release);
}

pub const MintAuthorization = struct {
    operation_identity: u64,
    owner_process_id: u32,
    owner_process_nonce: u64,
    owner_thread_incarnation: u64,
};

fn receiptEntryExact(receipt: *const MintReceipt, entry: *const ReceiptEntry) bool {
    return entry.live and entry.generation == receipt.slot_generation and
        entry.key == receipt.registry_key and entry.receipt_addr == @intFromPtr(receipt) and
        entry.client_addr == receipt.client_addr and
        entry.operation_identity == receipt.operation_identity and
        entry.owner_process_id == receipt.owner_process_id and
        entry.owner_process_nonce == receipt.owner_process_nonce and
        entry.owner_thread_id == receipt.owner_thread_id and
        entry.owner_thread_incarnation == receipt.owner_thread_incarnation;
}

fn releaseEntry(index: usize, entry: *ReceiptEntry) void {
    const next_generation = entry.generation + 1;
    entry.* = .{ .generation = next_generation };
    if (free_count >= free_slots.len) @panic("mint receipt free stack overflow");
    free_slots[free_count] = @intCast(index);
    free_count += 1;
}

pub fn consumeMintReceipt(receipt: *MintReceipt, client_addr: usize) ?MintAuthorization {
    const current_pid = currentProcessId();
    const owner_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    const owner_pid = registry_process_id.load(.acquire);
    const owner_nonce = registry_process_nonce.load(.acquire);
    if (current_pid == 0 or owner_thread_id == 0 or
        !registryProcessMatches(owner_pid, owner_nonce)) return null;
    const token = receipt.registry_token.load(.acquire);
    if (token == 0 or token > max_receipts) return null;
    waitForTestProceed();
    while (!receipt_mutex.tryLock()) std.atomic.spinLoopHint();
    defer receipt_mutex.unlock();
    if (currentProcessId() != current_pid) return null;
    const index: usize = @intCast(token - 1);
    const entry = &receipts[index];
    if (!receiptEntryExact(receipt, entry) or entry.client_addr != client_addr or
        entry.owner_process_id != current_pid or entry.owner_process_nonce != owner_nonce or
        entry.owner_thread_id != owner_thread_id or !matches(entry.owner_thread_incarnation)) return null;
    const result: MintAuthorization = .{
        .operation_identity = entry.operation_identity,
        .owner_process_id = entry.owner_process_id,
        .owner_process_nonce = entry.owner_process_nonce,
        .owner_thread_incarnation = entry.owner_thread_incarnation,
    };
    releaseEntry(index, entry);
    receipt.live = false;
    receipt.registry_token.store(0, .release);
    return result;
}

pub fn abortMintReceipt(receipt: *MintReceipt) bool {
    const current_pid = currentProcessId();
    const owner_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    const owner_pid = registry_process_id.load(.acquire);
    const owner_nonce = registry_process_nonce.load(.acquire);
    if (current_pid == 0 or owner_thread_id == 0 or
        !registryProcessMatches(owner_pid, owner_nonce)) return false;
    const token = receipt.registry_token.load(.acquire);
    if (token == 0 or token > max_receipts) return false;
    waitForTestProceed();
    while (!receipt_mutex.tryLock()) std.atomic.spinLoopHint();
    defer receipt_mutex.unlock();
    if (currentProcessId() != current_pid) return false;
    const index: usize = @intCast(token - 1);
    const entry = &receipts[index];
    if (!receiptEntryExact(receipt, entry) or entry.owner_process_id != current_pid or
        entry.owner_process_nonce != owner_nonce or entry.owner_thread_id != owner_thread_id or
        !matches(entry.owner_thread_incarnation)) return false;
    releaseEntry(index, entry);
    receipt.live = false;
    receipt.registry_token.store(0, .release);
    return true;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn lockRegistry() void {
        while (!receipt_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlockRegistry() void {
        receipt_mutex.unlock();
    }

    pub fn freeCount() usize {
        while (!receipt_mutex.tryLock()) std.atomic.spinLoopHint();
        defer receipt_mutex.unlock();
        return free_count;
    }

    pub fn pinCapabilityIgnoringThread(handle: CapabilityHandle, out: *CapabilityPin) bool {
        return pinCapabilityExact(handle, out, false);
    }

    pub fn armCapabilityPublishExhaustion() void {
        capability_publish_exhaustion_test_hook.store(true, .release);
    }

    pub fn armCapabilityClosing() void {
        capability_closing_test_hook_reached.store(false, .release);
        capability_closing_test_hook_armed.store(true, .release);
    }

    pub fn capabilityClosingReached() *const std.atomic.Value(bool) {
        return &capability_closing_test_hook_reached;
    }

    pub fn armReaderPinExhaustion() void {
        reader_pin_exhaustion_test_hook.store(true, .release);
    }

    pub fn unpinCapabilityIgnoringOwner(pin: *CapabilityPin) bool {
        return unpinCapabilityExact(pin, false);
    }

    pub fn closeCapabilityIgnoringOwner(pin: *CapabilityPin) bool {
        return closeCapabilityExact(pin, false);
    }

    pub fn lockCapabilityRegistry() void {
        while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlockCapabilityRegistry() void {
        capability_mutex.unlock();
    }
} else struct {};

const max_capabilities = 4096;
const CapabilityState = enum(u8) { empty, active, closing };
const CapabilityEntry = struct {
    state: CapabilityState = .empty,
    generation: u64 = 1,
    key: u64 = 0,
    capability_addr: usize = 0,
    publication_identity: u64 = 0,
    operation_identity: u64 = 0,
    client_addr: usize = 0,
    fence_generation: u64 = 0,
    fence_incarnation: u64 = 0,
    owner_process_id: u32 = 0,
    owner_process_nonce: u64 = 0,
    owner_thread_id: u64 = 0,
    owner_thread_incarnation: u64 = 0,
    readers: u32 = 0,
};

pub const CapabilityHandle = struct {
    slot_index: u16,
    slot_generation: u64,
    registry_key: u64,
    publication_identity: u64,
    operation_identity: u64,
};

pub const CapabilityFields = struct {
    capability_addr: usize = 0,
    publication_identity: u64 = 0,
    operation_identity: u64 = 0,
    client_addr: usize = 0,
    fence_generation: u64 = 0,
    fence_incarnation: u64 = 0,
    owner_process_id: u32 = 0,
    owner_process_nonce: u64 = 0,
    owner_thread_id: u64 = 0,
    owner_thread_incarnation: u64 = 0,
};

pub const CapabilityPin = struct {
    self_addr: usize = 0,
    reader_slot: u16 = 0,
    reader_generation: u64 = 0,
    reader_key: u64 = 0,
    slot_index: u16 = 0,
    slot_generation: u64 = 0,
    registry_key: u64 = 0,
    fields: CapabilityFields = .{},
    live: bool = false,

    pub fn pristineExact(self: *const @This()) bool {
        return self.self_addr == 0 and self.reader_slot == 0 and self.reader_generation == 0 and
            self.reader_key == 0 and self.slot_index == 0 and self.slot_generation == 0 and
            self.registry_key == 0 and !self.live;
    }
};

const ReaderPinEntry = struct {
    live: bool = false,
    generation: u64 = 1,
    key: u64 = 0,
    pin_addr: usize = 0,
    capability_slot: u16 = 0,
    capability_generation: u64 = 0,
    capability_key: u64 = 0,
};

var capability_mutex: std.atomic.Mutex = .unlocked;
var capabilities: [max_capabilities]CapabilityEntry = [_]CapabilityEntry{.{}} ** max_capabilities;
var capability_free_slots: [max_capabilities]u16 = initialFreeSlots();
var capability_free_count: usize = max_capabilities;
var next_capability_key: u64 = 1;
const max_reader_pins = 4096;
var reader_pins: [max_reader_pins]ReaderPinEntry = [_]ReaderPinEntry{.{}} ** max_reader_pins;
var reader_free_slots: [max_reader_pins]u16 = initialFreeSlots();
var reader_free_count: usize = max_reader_pins;
var next_reader_key: u64 = 1;
var capability_publish_exhaustion_test_hook: if (builtin.is_test) std.atomic.Value(bool) else void =
    if (builtin.is_test) .init(false) else {};
var capability_closing_test_hook_armed: if (builtin.is_test) std.atomic.Value(bool) else void =
    if (builtin.is_test) .init(false) else {};
var capability_closing_test_hook_reached: if (builtin.is_test) std.atomic.Value(bool) else void =
    if (builtin.is_test) .init(false) else {};
var reader_pin_exhaustion_test_hook: if (builtin.is_test) std.atomic.Value(bool) else void =
    if (builtin.is_test) .init(false) else {};

fn capabilityHandleExact(handle: CapabilityHandle, entry: *const CapabilityEntry) bool {
    return entry.generation == handle.slot_generation and entry.key == handle.registry_key and
        entry.publication_identity == handle.publication_identity and
        entry.operation_identity == handle.operation_identity;
}

fn processSealReadyForCapabilityRegistry() bool {
    const pid = currentProcessId();
    const nonce = registry_process_nonce.load(.acquire);
    process_seal_service.validateReady(pid, nonce) catch return false;
    return true;
}

pub fn publishCapability(fields: CapabilityFields) error{ InvalidOwner, IdentityExhausted, ResourceExhausted }!CapabilityHandle {
    const current_pid = currentProcessId();
    const thread_id: u64 = @intCast(std.Thread.getCurrentId());
    if (fields.capability_addr == 0 or fields.publication_identity == 0 or
        fields.operation_identity == 0 or fields.client_addr == 0 or fields.fence_generation == 0 or
        fields.fence_incarnation == 0 or fields.owner_process_id != current_pid or
        fields.owner_process_nonce == 0 or fields.owner_thread_id != thread_id or
        !matches(fields.owner_thread_incarnation) or
        !registryProcessMatches(fields.owner_process_id, fields.owner_process_nonce))
        return error.InvalidOwner;
    if (builtin.is_test and capability_publish_exhaustion_test_hook.swap(false, .acq_rel))
        return error.ResourceExhausted;
    if (!processSealReadyForCapabilityRegistry()) return error.InvalidOwner;
    while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
    defer capability_mutex.unlock();
    if (currentProcessId() != current_pid) return error.InvalidOwner;
    const key_counter = next_capability_key;
    if (key_counter == 0 or key_counter == std.math.maxInt(u64)) return error.IdentityExhausted;
    if (capability_free_count == 0) return error.ResourceExhausted;
    capability_free_count -= 1;
    const index: usize = capability_free_slots[capability_free_count];
    const entry = &capabilities[index];
    if (entry.state != .empty or entry.generation == 0 or entry.generation == std.math.maxInt(u64)) {
        capability_free_count += 1;
        return error.IdentityExhausted;
    }
    const key = process_seal_service.capabilityRegistryKey(
        fields.owner_process_id,
        fields.owner_process_nonce,
        .{
            .counter = key_counter,
            .slot_index = @intCast(index),
            .slot_generation = entry.generation,
        },
    ) catch |err| switch (err) {
        error.ProcessDomainMismatch, error.NotReady, error.Terminal => {
            capability_free_count += 1;
            return error.InvalidOwner;
        },
    };
    next_capability_key = key_counter + 1;
    entry.* = .{
        .state = .active,
        .generation = entry.generation,
        .key = key,
        .capability_addr = fields.capability_addr,
        .publication_identity = fields.publication_identity,
        .operation_identity = fields.operation_identity,
        .client_addr = fields.client_addr,
        .fence_generation = fields.fence_generation,
        .fence_incarnation = fields.fence_incarnation,
        .owner_process_id = fields.owner_process_id,
        .owner_process_nonce = fields.owner_process_nonce,
        .owner_thread_id = fields.owner_thread_id,
        .owner_thread_incarnation = fields.owner_thread_incarnation,
    };
    return .{
        .slot_index = @intCast(index),
        .slot_generation = entry.generation,
        .registry_key = key,
        .publication_identity = fields.publication_identity,
        .operation_identity = fields.operation_identity,
    };
}

fn pinCapabilityExact(handle: CapabilityHandle, out: *CapabilityPin, require_owner_thread: bool) bool {
    const current_pid = currentProcessId();
    const thread_id: u64 = @intCast(std.Thread.getCurrentId());
    if (current_pid == 0 or thread_id == 0 or handle.slot_index >= max_capabilities or
        handle.slot_generation == 0 or handle.registry_key == 0 or
        handle.publication_identity == 0 or handle.operation_identity == 0 or
        registry_process_id.load(.acquire) != current_pid or !out.pristineExact() or
        !processSealReadyForCapabilityRegistry()) return false;
    while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
    defer capability_mutex.unlock();
    const entry = &capabilities[handle.slot_index];
    if (entry.state != .active or !capabilityHandleExact(handle, entry) or
        entry.owner_process_id != current_pid or
        entry.owner_process_nonce != registry_process_nonce.load(.acquire) or
        (require_owner_thread and entry.owner_thread_id != thread_id) or
        (require_owner_thread and !matches(entry.owner_thread_incarnation)) or
        entry.readers == std.math.maxInt(u32) or reader_free_count == 0 or
        (builtin.is_test and reader_pin_exhaustion_test_hook.swap(false, .acq_rel))) return false;
    const reader_key = next_reader_key;
    if (reader_key == 0 or reader_key == std.math.maxInt(u64)) return false;
    reader_free_count -= 1;
    const reader_index: usize = reader_free_slots[reader_free_count];
    const reader = &reader_pins[reader_index];
    if (reader.live or reader.generation == 0 or reader.generation == std.math.maxInt(u64)) {
        reader_free_count += 1;
        return false;
    }
    next_reader_key = reader_key + 1;
    entry.readers += 1;
    reader.* = .{
        .live = true,
        .generation = reader.generation,
        .key = reader_key,
        .pin_addr = @intFromPtr(out),
        .capability_slot = handle.slot_index,
        .capability_generation = handle.slot_generation,
        .capability_key = handle.registry_key,
    };
    out.* = .{
        .self_addr = @intFromPtr(out),
        .reader_slot = @intCast(reader_index),
        .reader_generation = reader.generation,
        .reader_key = reader_key,
        .slot_index = handle.slot_index,
        .slot_generation = handle.slot_generation,
        .registry_key = handle.registry_key,
        .fields = .{
            .capability_addr = entry.capability_addr,
            .publication_identity = entry.publication_identity,
            .operation_identity = entry.operation_identity,
            .client_addr = entry.client_addr,
            .fence_generation = entry.fence_generation,
            .fence_incarnation = entry.fence_incarnation,
            .owner_process_id = entry.owner_process_id,
            .owner_process_nonce = entry.owner_process_nonce,
            .owner_thread_id = entry.owner_thread_id,
            .owner_thread_incarnation = entry.owner_thread_incarnation,
        },
        .live = true,
    };
    return true;
}

pub fn pinCapability(handle: CapabilityHandle, out: *CapabilityPin) bool {
    return pinCapabilityExact(handle, out, true);
}

const MaterializedReaderPin = struct {
    reader: *ReaderPinEntry,
    entry: *CapabilityEntry,
};

fn materializeReaderPin(pin: *CapabilityPin, require_owner_thread: bool) ?MaterializedReaderPin {
    if (!pin.live or pin.self_addr != @intFromPtr(pin) or pin.reader_slot >= max_reader_pins)
        return null;
    const reader = &reader_pins[pin.reader_slot];
    if (!reader.live or reader.generation != pin.reader_generation or reader.key != pin.reader_key or
        reader.pin_addr != @intFromPtr(pin) or reader.capability_slot != pin.slot_index or
        reader.capability_generation != pin.slot_generation or reader.capability_key != pin.registry_key)
        return null;
    if (reader.capability_slot >= max_capabilities) return null;
    const entry = &capabilities[reader.capability_slot];
    if ((entry.state != .active and entry.state != .closing) or
        entry.generation != reader.capability_generation or entry.key != reader.capability_key or
        entry.owner_process_id != currentProcessId() or
        (require_owner_thread and entry.owner_thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) or
        (require_owner_thread and !matches(entry.owner_thread_incarnation)) or entry.readers == 0)
        return null;
    return .{ .reader = reader, .entry = entry };
}

fn consumeMaterializedReaderPin(pin: *CapabilityPin, materialized: MaterializedReaderPin) void {
    const next_generation = materialized.reader.generation + 1;
    materialized.reader.* = .{ .generation = next_generation };
    reader_free_slots[reader_free_count] = pin.reader_slot;
    reader_free_count += 1;
    pin.live = false;
}

fn registryProcessCurrent() bool {
    const current_pid = currentProcessId();
    return current_pid != 0 and registry_process_id.load(.acquire) == current_pid and
        registry_process_nonce.load(.acquire) != 0;
}

fn unpinCapabilityExact(pin: *CapabilityPin, require_owner_thread: bool) bool {
    if (!registryProcessCurrent() or !processSealReadyForCapabilityRegistry() or
        pin.reader_slot >= max_reader_pins) return false;
    while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
    defer capability_mutex.unlock();
    if (!registryProcessCurrent()) return false;
    const materialized = materializeReaderPin(pin, require_owner_thread) orelse return false;
    consumeMaterializedReaderPin(pin, materialized);
    const entry = materialized.entry;
    entry.readers -= 1;
    return true;
}

pub fn unpinCapability(pin: *CapabilityPin) bool {
    return unpinCapabilityExact(pin, true);
}

fn closeCapabilityExact(pin: *CapabilityPin, require_owner_thread: bool) bool {
    if (!registryProcessCurrent() or !processSealReadyForCapabilityRegistry() or
        pin.reader_slot >= max_reader_pins) return false;
    while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
    if (!registryProcessCurrent()) {
        capability_mutex.unlock();
        return false;
    }
    const materialized = materializeReaderPin(pin, require_owner_thread) orelse {
        capability_mutex.unlock();
        return false;
    };
    var entry = materialized.entry;
    if (entry.state != .active) {
        capability_mutex.unlock();
        return false;
    }
    const capability_slot: u16 = @intCast(
        (@intFromPtr(entry) - @intFromPtr(&capabilities[0])) / @sizeOf(CapabilityEntry),
    );
    const capability_generation = entry.generation;
    const capability_key = entry.key;
    consumeMaterializedReaderPin(pin, materialized);
    entry.state = .closing;
    if (builtin.is_test and capability_closing_test_hook_armed.swap(false, .acq_rel))
        capability_closing_test_hook_reached.store(true, .release);
    entry.readers -= 1;
    capability_mutex.unlock();
    while (true) {
        while (!capability_mutex.tryLock()) std.atomic.spinLoopHint();
        entry = &capabilities[capability_slot];
        if (entry.state != .closing or entry.generation != capability_generation or
            entry.key != capability_key)
        {
            capability_mutex.unlock();
            return false;
        }
        if (entry.readers != 0) {
            capability_mutex.unlock();
            std.atomic.spinLoopHint();
            continue;
        }
        const next_generation = entry.generation + 1;
        entry.* = .{ .generation = next_generation };
        if (capability_free_count >= capability_free_slots.len)
            @panic("capability registry free stack overflow");
        capability_free_slots[capability_free_count] = capability_slot;
        capability_free_count += 1;
        capability_mutex.unlock();
        return true;
    }
}

pub fn closeCapability(pin: *CapabilityPin) bool {
    return closeCapabilityExact(pin, true);
}
