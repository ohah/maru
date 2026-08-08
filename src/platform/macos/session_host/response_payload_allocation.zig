//! B3-0a pointer-free authority for response-frame payload allocation provenance.
//!
//! The ledger observes only completed-frame payload allocations. Parser backing and Client queue
//! backing keep their existing owners. A response may be freed or published only after its exact
//! live entry is promoted; copied tokens cannot replay a consumed entry.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");
const executed_response = @import("executed_response.zig");
const rpc_executed_response = @import("rpc_executed_response.zig");
const client_queue_limits = @import("client_queue_limits.zig");

pub const max_entries: usize = client_queue_limits.max_observed_response_payloads;

comptime {
    if (max_entries > std.math.maxInt(u16)) @compileError("response payload ledger index overflow");
}

pub const Error = error{
    Busy,
    ObservationBusy,
    InvalidOwner,
    InvalidReceipt,
    IdentityExhausted,
};

pub const Authority = struct {
    guard_addr: usize,
    node_addr: usize,
    operation_incarnation: u64,

    pub fn valid(self: Authority) bool {
        return self.guard_addr != 0 and self.node_addr != 0 and
            self.operation_incarnation != 0;
    }
};

pub const AllocatorIdentity = struct {
    ptr_addr: usize,
    vtable_addr: usize,

    pub fn from(allocator: std.mem.Allocator) AllocatorIdentity {
        return .{
            .ptr_addr = @intFromPtr(allocator.ptr),
            .vtable_addr = @intFromPtr(allocator.vtable),
        };
    }

    fn valid(self: AllocatorIdentity) bool {
        return self.ptr_addr != 0 and self.vtable_addr != 0;
    }
};

const Lifecycle = enum(u8) {
    reserved,
    live,
    promoted_response,
    transferred_response,
    retired,
    terminal_no_free,
};

pub const PayloadFailStopReason = enum {
    allocator_drift,
    range_overflow,
    owner_alias,
    ledger_drift,
};

pub const TransferOutcome = union(enum) {
    transferred,
    rejected_safe_released: executed_response.ExecutedResponse.InitError,
    fail_stop_required: PayloadFailStopReason,
};

pub const RpcTransferOutcome = union(enum) {
    transferred,
    rejected_safe_released: rpc_executed_response.RpcExecutedResponse.Error,
    fail_stop_required: PayloadFailStopReason,
};

const Entry = struct {
    generation: u64,
    allocator: AllocatorIdentity,
    addr: usize,
    len: usize,
    lifecycle: Lifecycle,
    terminal_reason: ?PayloadFailStopReason = null,
};

pub const ForbiddenRange = struct { start: usize, len: usize };
const max_forbidden_ranges: usize = 16;

pub const PayloadProvenanceOutcome = union(enum) {
    promoted: Receipt,
    fail_stop_required: PayloadFailStopReason,
};

pub const Receipt = struct {
    ledger_addr: usize,
    authority: Authority,
    index: u16,
    generation: u64,
    allocator: AllocatorIdentity,
    addr: usize,
    len: usize,
    zero_length: bool,

    pub fn validForTransfer(
        self: Receipt,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) bool {
        return self.ledger_addr != 0 and self.authority.valid() and self.generation != 0 and
            self.allocator.valid() and std.meta.eql(self.allocator, AllocatorIdentity.from(allocator)) and
            self.addr == (if (payload.len == 0) 0 else @intFromPtr(payload.ptr)) and
            self.len == payload.len and self.zero_length == (payload.len == 0);
    }
};

pub const Ledger = struct {
    self_addr: usize = 0,
    authority: Authority = .{ .guard_addr = 0, .node_addr = 0, .operation_incarnation = 0 },
    authority_seal: Authority = .{ .guard_addr = 0, .node_addr = 0, .operation_incarnation = 0 },
    allocator: std.mem.Allocator = undefined,
    allocator_seal: AllocatorIdentity = .{ .ptr_addr = 0, .vtable_addr = 0 },
    entry_storage: [max_entries]Entry = undefined,
    entries: []Entry = &.{},
    entry_count: usize = 0,
    next_generation: u64 = 1,
    active: bool = false,
    ledger_terminal_no_free: bool = false,
    ledger_terminal_reason: ?PayloadFailStopReason = null,
    forbidden_ranges: [max_forbidden_ranges]ForbiddenRange = @splat(.{ .start = 0, .len = 0 }),
    forbidden_count: usize = 0,
    forbidden_bound: bool = false,
    forbidden_seal: u64 = 0,

    pub fn initInPlace(
        out: *Ledger,
        allocator: std.mem.Allocator,
        authority: Authority,
        first_generation: u64,
    ) Error!void {
        if (out.self_addr != 0 or out.entries.len != 0 or
            out.entry_count != 0 or out.active or !authority.valid())
            return error.InvalidOwner;
        if (first_generation == 0 or first_generation == std.math.maxInt(u64))
            return error.IdentityExhausted;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .authority = authority,
            .authority_seal = authority,
            .allocator = allocator,
            .allocator_seal = AllocatorIdentity.from(allocator),
            .next_generation = first_generation,
            .active = true,
        };
        out.entries = out.entry_storage[0..];
    }

    pub fn reserveObserved(
        self: *Ledger,
        len: usize,
        allocator: std.mem.Allocator,
    ) Error!u64 {
        try self.validateActive();
        const generation = self.next_generation;
        if (generation == 0 or generation == std.math.maxInt(u64))
            return error.IdentityExhausted;
        self.next_generation = generation + 1;
        const identity = AllocatorIdentity.from(allocator);
        if (!identity.valid()) return error.InvalidOwner;
        var slot_index: ?usize = null;
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            if (entry.lifecycle == .retired) {
                slot_index = index;
                break;
            }
        }
        const index = slot_index orelse blk: {
            if (self.entry_count >= max_entries) return error.ObservationBusy;
            try self.ensureEntryCapacity();
            const fresh = self.entry_count;
            self.entry_count += 1;
            break :blk fresh;
        };
        self.entries[index] = .{
            .generation = generation,
            .allocator = identity,
            .addr = 0,
            .len = len,
            .lifecycle = .reserved,
        };
        return generation;
    }

    pub fn bindForbiddenRanges(self: *Ledger, ranges: []const ForbiddenRange) Error!void {
        try self.validateActive();
        if (self.entry_count != 0 or self.forbidden_bound or self.forbidden_count != 0 or
            ranges.len == 0 or ranges.len > max_forbidden_ranges)
            return error.InvalidOwner;
        for (ranges, 0..) |range, index| {
            if (range.len == 0) return error.InvalidOwner;
            _ = std.math.add(usize, range.start, range.len) catch return error.InvalidOwner;
            self.forbidden_ranges[index] = range;
        }
        self.forbidden_count = ranges.len;
        self.forbidden_seal = forbiddenRangesDigest(self.forbidden_ranges[0..self.forbidden_count]);
        self.forbidden_bound = true;
    }

    /// Replaces the lexical alias set before the first payload observation. This is used
    /// after request write settles its backing frame, whose address may validly be reused
    /// by the response allocator.
    pub fn rebindForbiddenRangesBeforeObservation(
        self: *Ledger,
        ranges: []const ForbiddenRange,
    ) Error!void {
        try self.validateActive();
        if (self.entry_count != 0 or !self.forbidden_bound or
            ranges.len == 0 or ranges.len > max_forbidden_ranges)
            return error.InvalidOwner;
        var replacement: [max_forbidden_ranges]ForbiddenRange =
            @splat(.{ .start = 0, .len = 0 });
        for (ranges, 0..) |range, index| {
            if (range.len == 0) return error.InvalidOwner;
            _ = std.math.add(usize, range.start, range.len) catch return error.InvalidOwner;
            replacement[index] = range;
        }
        self.forbidden_ranges = replacement;
        self.forbidden_count = ranges.len;
        self.forbidden_seal = forbiddenRangesDigest(
            self.forbidden_ranges[0..self.forbidden_count],
        );
    }

    pub fn abortObserved(self: *Ledger, generation: u64) Error!void {
        const entry = try self.entryForGeneration(generation, .reserved);
        entry.lifecycle = .retired;
    }

    pub fn discardObserved(self: *Ledger, generation: u64) Error!void {
        const entry = try self.entryForGeneration(generation, .live);
        entry.lifecycle = .retired;
    }

    pub fn commitObserved(
        self: *Ledger,
        generation: u64,
        payload: []u8,
        allocator: std.mem.Allocator,
    ) Error!void {
        const entry = try self.entryForGeneration(generation, .reserved);
        if (!std.meta.eql(entry.allocator, AllocatorIdentity.from(allocator)) or
            payload.len != entry.len or (payload.len != 0 and @intFromPtr(payload.ptr) == 0))
            return error.InvalidReceipt;
        entry.addr = if (payload.len == 0) 0 else @intFromPtr(payload.ptr);
        entry.lifecycle = .live;
    }

    pub fn classifyResponsePayloadProvenance(
        self: *Ledger,
        generation: u64,
        payload: []const u8,
        allocator: std.mem.Allocator,
        expected_allocator: std.mem.Allocator,
    ) PayloadProvenanceOutcome {
        const entry = self.entryForGeneration(generation, .live) catch {
            self.sealLedgerTerminalNoFree(.ledger_drift);
            return .{ .fail_stop_required = .ledger_drift };
        };
        const reason: ?PayloadFailStopReason = blk: {
            if (!std.meta.eql(AllocatorIdentity.from(allocator), AllocatorIdentity.from(expected_allocator)))
                break :blk .allocator_drift;
            const payload_range = byteRange(payload) orelse break :blk .range_overflow;
            const ledger_range = byteRange(std.mem.asBytes(self)) orelse break :blk .range_overflow;
            if (rangesOverlap(payload_range, ledger_range)) break :blk .owner_alias;
            if (self.entries.len != 0) {
                const backing_range = byteRange(std.mem.sliceAsBytes(self.entries)) orelse
                    break :blk .range_overflow;
                if (rangesOverlap(payload_range, backing_range)) break :blk .owner_alias;
            }
            for (self.forbidden_ranges[0..self.forbidden_count]) |candidate| {
                const end = std.math.add(usize, candidate.start, candidate.len) catch
                    break :blk .range_overflow;
                if (candidate.len != 0 and rangesOverlap(payload_range, .{
                    .start = candidate.start,
                    .end = end,
                })) break :blk .owner_alias;
            }
            break :blk null;
        };
        if (reason) |terminal_reason| {
            entry.lifecycle = .terminal_no_free;
            entry.terminal_reason = terminal_reason;
            return .{ .fail_stop_required = terminal_reason };
        }
        if (!entryMatchesPayload(entry.*, payload, allocator)) {
            entry.lifecycle = .terminal_no_free;
            entry.terminal_reason = .ledger_drift;
            return .{ .fail_stop_required = .ledger_drift };
        }
        entry.lifecycle = .promoted_response;
        return .{ .promoted = self.receiptFor(
            @intCast((@intFromPtr(entry) - @intFromPtr(self.entries.ptr)) / @sizeOf(Entry)),
            entry.*,
        ) };
    }

    pub fn releasePromotedResponse(self: *Ledger, receipt: Receipt) Error!void {
        const entry = try self.entryForReceipt(receipt, .promoted_response);
        entry.lifecycle = .retired;
        const backing = try self.captureBackingSnapshot();
        if (entry.len != 0)
            allocatorFromIdentity(entry.allocator).free(payloadFromEntry(entry.*));
        if (!self.backingSnapshotStillExact(backing)) {
            self.sealLedgerTerminalNoFree(.ledger_drift);
            return error.InvalidOwner;
        }
        _ = self.entryForReceipt(receipt, .retired) catch {
            self.sealLedgerTerminalNoFree(.ledger_drift);
            return error.InvalidOwner;
        };
    }

    pub fn transferPromotedResponse(
        self: *Ledger,
        receipt: Receipt,
        out: *executed_response.ExecutedResponse,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
        incarnation: u64,
        correlated: contract.CorrelatedExecutedCall,
    ) TransferOutcome {
        const entry = self.entryForReceipt(receipt, .promoted_response) catch {
            self.sealLedgerTerminalNoFree(.ledger_drift);
            return .{ .fail_stop_required = .ledger_drift };
        };
        const allocator = allocatorFromIdentity(entry.allocator);
        const payload = payloadFromEntry(entry.*);
        executed_response.ExecutedResponse.initAcceptedFromPromotedInPlace(
            out,
            allocator,
            owner_seal,
            incarnation,
            correlated,
            payload,
            .{
                .guard_addr = receipt.authority.guard_addr,
                .node_addr = receipt.authority.node_addr,
                .operation_incarnation = receipt.authority.operation_incarnation,
                .generation = receipt.generation,
            },
        ) catch |err| {
            if (!out.pristine() or !std.meta.eql(contract.ExecutedResponseOwnerSeal{}, owner_seal.*)) {
                entry.lifecycle = .terminal_no_free;
                entry.terminal_reason = .ledger_drift;
                return .{ .fail_stop_required = .ledger_drift };
            }
            entry.lifecycle = .retired;
            const backing = self.captureBackingSnapshot() catch {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            };
            if (payload.len != 0) allocator.free(payload);
            if (!self.backingSnapshotStillExact(backing)) {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            }
            _ = self.entryForReceipt(receipt, .retired) catch {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            };
            return .{ .rejected_safe_released = err };
        };
        entry.lifecycle = .transferred_response;
        return .transferred;
    }

    /// Atomically consumes one promoted ledger entry into the repeating-RPC byte owner. The owner
    /// receives neutral scalar provenance only and never gains a reverse dependency on this ledger.
    pub fn transferPromotedRpcResponse(
        self: *Ledger,
        receipt: Receipt,
        out: *rpc_executed_response.RpcExecutedResponse,
        identity: rpc_executed_response.Identity,
    ) RpcTransferOutcome {
        const entry = self.entryForReceipt(receipt, .promoted_response) catch {
            self.sealLedgerTerminalNoFree(.ledger_drift);
            return .{ .fail_stop_required = .ledger_drift };
        };
        const allocator = allocatorFromIdentity(entry.allocator);
        const payload = payloadFromEntry(entry.*);
        rpc_executed_response.RpcExecutedResponse.initLiveInPlace(
            out,
            identity,
            allocator,
            payload,
            .{
                .ledger_addr = @intFromPtr(self),
                .guard_addr = receipt.authority.guard_addr,
                .node_addr = receipt.authority.node_addr,
                .operation_incarnation = receipt.authority.operation_incarnation,
                .index = receipt.index,
                .generation = receipt.generation,
            },
        ) catch |err| {
            if (!out.pristineExact() or err == error.AliasedStorage) {
                entry.lifecycle = .terminal_no_free;
                entry.terminal_reason = if (err == error.AliasedStorage) .owner_alias else .ledger_drift;
                return .{ .fail_stop_required = entry.terminal_reason.? };
            }
            entry.lifecycle = .retired;
            const backing = self.captureBackingSnapshot() catch {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            };
            if (payload.len != 0) allocator.free(payload);
            if (!self.backingSnapshotStillExact(backing)) {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            }
            _ = self.entryForReceipt(receipt, .retired) catch {
                self.sealLedgerTerminalNoFree(.ledger_drift);
                return .{ .fail_stop_required = .ledger_drift };
            };
            return .{ .fail_stop_required = .ledger_drift };
        };
        entry.lifecycle = .transferred_response;
        return .transferred;
    }

    pub fn endOperation(self: *Ledger) Error!void {
        try self.validateActive();
        for (self.entries[0..self.entry_count]) |entry| {
            if (!entryLifecycleReasonValid(entry)) return error.InvalidOwner;
            switch (entry.lifecycle) {
                .reserved, .promoted_response => return error.Busy,
                .live, .transferred_response, .retired => {},
                .terminal_no_free => return error.InvalidOwner,
            }
        }
        self.* = .{};
    }

    /// Consumes only a failed RPC-transfer residue after its byte disposition is already fixed.
    /// Retired entries were safe-freed by the transfer attempt; terminal-no-free entries retain
    /// no callable cleanup capability. Any live/promoted/transferred entry is a caller bug.
    pub fn endFailedRpcTransfer(
        self: *Ledger,
        reason: PayloadFailStopReason,
    ) Error!void {
        if (!self.active or self.self_addr != @intFromPtr(self) or !self.authority.valid() or
            !std.meta.eql(self.authority, self.authority_seal) or
            !std.meta.eql(AllocatorIdentity.from(self.allocator), self.allocator_seal) or
            self.entries.len != max_entries or
            @intFromPtr(self.entries.ptr) != @intFromPtr(&self.entry_storage[0]) or
            self.entry_count > max_entries)
            return error.InvalidOwner;
        if (self.ledger_terminal_no_free) {
            if (self.ledger_terminal_reason != reason) return error.InvalidOwner;
        } else for (self.entries[0..self.entry_count]) |entry| switch (entry.lifecycle) {
            .retired => {},
            .terminal_no_free => if (entry.terminal_reason != reason)
                return error.InvalidOwner,
            .reserved, .live, .promoted_response, .transferred_response => return error.Busy,
        };
        self.* = .{};
    }

    fn ensureEntryCapacity(self: *Ledger) Error!void {
        try self.validateActive();
        if (self.entry_count < self.entries.len) return;
        return error.ObservationBusy;
    }

    fn validateActive(self: *const Ledger) Error!void {
        if (!self.active or self.self_addr != @intFromPtr(self) or !self.authority.valid() or
            !std.meta.eql(self.authority, self.authority_seal) or
            !std.meta.eql(AllocatorIdentity.from(self.allocator), self.allocator_seal) or
            self.entries.len != max_entries or
            @intFromPtr(self.entries.ptr) != @intFromPtr(&self.entry_storage[0]) or
            self.entry_count > max_entries or self.forbidden_count > max_forbidden_ranges or
            (self.forbidden_bound != (self.forbidden_count != 0)) or
            (self.forbidden_bound and self.forbidden_seal !=
                forbiddenRangesDigest(self.forbidden_ranges[0..self.forbidden_count])))
            return error.InvalidOwner;
        if (self.ledger_terminal_no_free or self.ledger_terminal_reason != null)
            return error.InvalidOwner;
    }

    const BackingSnapshot = struct {
        ptr_addr: usize,
        len: usize,
        entry_count: usize,
        authority: Authority,
        authority_seal: Authority,
        allocator: AllocatorIdentity,
        allocator_seal: AllocatorIdentity,
        next_generation: u64,
        self_addr: usize,
        active: bool,
        semantic_digest: u64,
        forbidden_digest: u64,
        forbidden_count: usize,
        forbidden_bound: bool,
        forbidden_seal: u64,
        ledger_terminal_no_free: bool,
        ledger_terminal_reason: ?PayloadFailStopReason,
    };

    fn captureBackingSnapshot(self: *const Ledger) Error!BackingSnapshot {
        try self.validateActive();
        if (!ledgerTerminalReasonValid(self.ledger_terminal_no_free, self.ledger_terminal_reason))
            return error.InvalidOwner;
        for (self.entries[0..self.entry_count]) |entry|
            if (!entryLifecycleReasonValid(entry)) return error.InvalidOwner;
        return .{
            .ptr_addr = if (self.entries.len == 0) 0 else @intFromPtr(self.entries.ptr),
            .len = self.entries.len,
            .entry_count = self.entry_count,
            .authority = self.authority,
            .authority_seal = self.authority_seal,
            .allocator = AllocatorIdentity.from(self.allocator),
            .allocator_seal = self.allocator_seal,
            .next_generation = self.next_generation,
            .self_addr = self.self_addr,
            .active = self.active,
            .semantic_digest = entriesSemanticDigest(self.entries[0..self.entry_count]),
            .forbidden_digest = forbiddenRangesDigest(self.forbidden_ranges[0..self.forbidden_count]),
            .forbidden_count = self.forbidden_count,
            .forbidden_bound = self.forbidden_bound,
            .forbidden_seal = self.forbidden_seal,
            .ledger_terminal_no_free = self.ledger_terminal_no_free,
            .ledger_terminal_reason = self.ledger_terminal_reason,
        };
    }

    fn backingSnapshotStillExact(self: *const Ledger, snapshot: BackingSnapshot) bool {
        const ptr_addr = if (self.entries.len == 0) 0 else @intFromPtr(self.entries.ptr);
        if (ptr_addr != snapshot.ptr_addr or self.entries.len != snapshot.len or
            self.entry_count != snapshot.entry_count or
            !std.meta.eql(self.authority, snapshot.authority) or
            !std.meta.eql(self.authority_seal, snapshot.authority_seal) or
            !std.meta.eql(AllocatorIdentity.from(self.allocator), snapshot.allocator) or
            !std.meta.eql(self.allocator_seal, snapshot.allocator_seal) or
            self.next_generation != snapshot.next_generation or
            self.self_addr != snapshot.self_addr or self.active != snapshot.active or
            self.forbidden_count != snapshot.forbidden_count or
            self.forbidden_count > max_forbidden_ranges or
            self.forbidden_bound != snapshot.forbidden_bound or
            self.forbidden_seal != snapshot.forbidden_seal or
            self.ledger_terminal_no_free != snapshot.ledger_terminal_no_free or
            self.ledger_terminal_reason != snapshot.ledger_terminal_reason or
            !ledgerTerminalReasonValid(self.ledger_terminal_no_free, self.ledger_terminal_reason))
            return false;
        if (self.entry_count > self.entries.len or self.entries.len > max_entries) return false;
        return entriesSemanticDigest(self.entries[0..self.entry_count]) == snapshot.semantic_digest and
            forbiddenRangesDigest(self.forbidden_ranges[0..self.forbidden_count]) == snapshot.forbidden_digest;
    }

    fn sealLedgerTerminalNoFree(self: *Ledger, reason: PayloadFailStopReason) void {
        if (!self.ledger_terminal_no_free and self.ledger_terminal_reason == null) {
            self.ledger_terminal_no_free = true;
            self.ledger_terminal_reason = reason;
        }
    }

    fn entryForReceipt(
        self: *Ledger,
        receipt: Receipt,
        lifecycle: Lifecycle,
    ) Error!*Entry {
        try self.validateActive();
        if (receipt.ledger_addr != @intFromPtr(self) or
            !std.meta.eql(receipt.authority, self.authority) or
            receipt.index >= self.entry_count)
            return error.InvalidOwner;
        const entry = &self.entries[receipt.index];
        if (!entryLifecycleReasonValid(entry.*) or entry.lifecycle != lifecycle or
            entry.generation != receipt.generation or
            entry.addr != receipt.addr or entry.len != receipt.len or
            !std.meta.eql(entry.allocator, receipt.allocator) or
            receipt.zero_length != (receipt.len == 0))
            return error.InvalidReceipt;
        return entry;
    }

    fn entryForGeneration(
        self: *Ledger,
        generation: u64,
        lifecycle: Lifecycle,
    ) Error!*Entry {
        try self.validateActive();
        if (generation == 0) return error.InvalidReceipt;
        var match: ?*Entry = null;
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.generation != generation) continue;
            if (match != null or !entryLifecycleReasonValid(entry.*) or
                entry.lifecycle != lifecycle) return error.InvalidReceipt;
            match = entry;
        }
        return match orelse error.InvalidReceipt;
    }

    fn receiptFor(self: *Ledger, index: u16, entry: Entry) Receipt {
        return .{
            .ledger_addr = @intFromPtr(self),
            .authority = self.authority,
            .index = index,
            .generation = entry.generation,
            .allocator = entry.allocator,
            .addr = entry.addr,
            .len = entry.len,
            .zero_length = entry.len == 0,
        };
    }
};

const ByteRange = struct { start: usize, end: usize };

fn byteRange(bytes: []const u8) ?ByteRange {
    if (bytes.len == 0) return .{ .start = 0, .end = 0 };
    const start = @intFromPtr(bytes.ptr);
    return .{ .start = start, .end = std.math.add(usize, start, bytes.len) catch return null };
}

fn rangesOverlap(a: ByteRange, b: ByteRange) bool {
    return a.start < b.end and b.start < a.end;
}

fn entriesSemanticDigest(entries: []const Entry) u64 {
    var hasher = std.hash.Wyhash.init(0x4d_52_53_48_52_50_41_4c);
    for (entries) |entry| {
        hasher.update(std.mem.asBytes(&entry.generation));
        hasher.update(std.mem.asBytes(&entry.addr));
        hasher.update(std.mem.asBytes(&entry.len));
        hasher.update(std.mem.asBytes(&entry.allocator.ptr_addr));
        hasher.update(std.mem.asBytes(&entry.allocator.vtable_addr));
        const lifecycle: u8 = @intFromEnum(entry.lifecycle);
        hasher.update(std.mem.asBytes(&lifecycle));
        const reason: u8 = if (entry.terminal_reason) |value| @intFromEnum(value) + 1 else 0;
        hasher.update(std.mem.asBytes(&reason));
    }
    return hasher.final();
}

fn forbiddenRangesDigest(ranges: []const ForbiddenRange) u64 {
    var hasher = std.hash.Wyhash.init(0x4d_52_53_48_46_4f_52_42);
    for (ranges) |range| {
        hasher.update(std.mem.asBytes(&range.start));
        hasher.update(std.mem.asBytes(&range.len));
    }
    return hasher.final();
}

fn entryMatchesPayload(
    entry: Entry,
    payload: []const u8,
    allocator: std.mem.Allocator,
) bool {
    return entry.len == payload.len and
        entry.addr == (if (payload.len == 0) 0 else @intFromPtr(payload.ptr)) and
        std.meta.eql(entry.allocator, AllocatorIdentity.from(allocator));
}

fn entryLifecycleReasonValid(entry: Entry) bool {
    return (entry.lifecycle == .terminal_no_free) == (entry.terminal_reason != null);
}

fn ledgerTerminalReasonValid(
    terminal_no_free: bool,
    terminal_reason: ?PayloadFailStopReason,
) bool {
    return terminal_no_free == (terminal_reason != null);
}

fn allocatorFromIdentity(identity: AllocatorIdentity) std.mem.Allocator {
    return .{
        .ptr = @ptrFromInt(identity.ptr_addr),
        .vtable = @ptrFromInt(identity.vtable_addr),
    };
}

fn payloadFromEntry(entry: Entry) []u8 {
    if (entry.len == 0) return @constCast(&[_]u8{});
    return @as([*]u8, @ptrFromInt(entry.addr))[0..entry.len];
}

fn transferPromotedForTest(ledger: *Ledger, receipt: Receipt) Error!void {
    const entry = try ledger.entryForReceipt(receipt, .promoted_response);
    entry.lifecycle = .transferred_response;
}

test "B3-0a payload ledger promotes only the exact live allocation" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0x11,
        .node_addr = 0x22,
        .operation_incarnation = 0x33,
    }, 1);
    var payload = [_]u8{ 1, 2, 3 };
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, &payload, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        &payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    try transferPromotedForTest(&ledger, receipt);
    try std.testing.expectError(error.InvalidReceipt, transferPromotedForTest(&ledger, receipt));
    try ledger.endOperation();
}

test "B3-0a copied stale and cross-ledger receipts mutate nothing" {
    const allocator = std.testing.allocator;
    var first: Ledger = .{};
    var second: Ledger = .{};
    try Ledger.initInPlace(&first, allocator, .{
        .guard_addr = 1,
        .node_addr = 2,
        .operation_incarnation = 3,
    }, 7);
    try Ledger.initInPlace(&second, allocator, .{
        .guard_addr = 4,
        .node_addr = 5,
        .operation_incarnation = 6,
    }, 7);
    const payload = try allocator.dupe(u8, &.{0xAA});
    const generation = try first.reserveObserved(1, allocator);
    try first.commitObserved(generation, payload, allocator);
    const receipt = switch (first.classifyResponsePayloadProvenance(
        generation,
        payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    try std.testing.expectError(error.InvalidOwner, second.releasePromotedResponse(receipt));
    try first.releasePromotedResponse(receipt);
    try std.testing.expectError(error.InvalidReceipt, first.releasePromotedResponse(receipt));
    try first.endOperation();
    try second.endOperation();
}

test "B3-0a zero length and sixty four OOB payloads preserve one target promotion" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 9,
        .node_addr = 10,
        .operation_incarnation = 11,
    }, 1);
    const empty: []u8 = @constCast(&[_]u8{});
    const zero = try ledger.reserveObserved(0, allocator);
    try ledger.commitObserved(zero, empty, allocator);
    const zero_receipt = switch (ledger.classifyResponsePayloadProvenance(
        zero,
        empty,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    try std.testing.expect(zero_receipt.zero_length);
    try ledger.releasePromotedResponse(zero_receipt);

    var payloads: [65]u8 = undefined;
    for (payloads[0..64], 0..) |*payload, index| {
        payload.* = @intCast(index);
        const generation = try ledger.reserveObserved(1, allocator);
        try ledger.commitObserved(generation, @as(*[1]u8, payload)[0..], allocator);
        try ledger.discardObserved(generation);
    }
    payloads[64] = 64;
    const target_generation = try ledger.reserveObserved(1, allocator);
    try ledger.commitObserved(target_generation, @as(*[1]u8, &payloads[64])[0..], allocator);
    const target = switch (ledger.classifyResponsePayloadProvenance(
        target_generation,
        @as(*[1]u8, &payloads[64])[0..],
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    try transferPromotedForTest(&ledger, target);
    try ledger.endOperation();
}

test "B3-0a discarded OOB generations reuse the bounded ledger slot before target" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0x91,
        .node_addr = 0x92,
        .operation_incarnation = 0x93,
    }, 1);
    var oob = [_]u8{0xA5};
    for (0..max_entries + 64) |_| {
        const generation = try ledger.reserveObserved(1, allocator);
        try ledger.commitObserved(generation, &oob, allocator);
        try ledger.discardObserved(generation);
    }
    try std.testing.expectEqual(@as(usize, 1), ledger.entry_count);
    var target = [_]u8{0x5A};
    const generation = try ledger.reserveObserved(1, allocator);
    try ledger.commitObserved(generation, &target, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        &target,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    try transferPromotedForTest(&ledger, receipt);
    try ledger.endOperation();
}

test "B3-0a generation exhaustion rejects before ledger entry publication" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 12,
        .node_addr = 13,
        .operation_incarnation = 14,
    }, std.math.maxInt(u64) - 1);
    const generation = try ledger.reserveObserved(1, allocator);
    try std.testing.expectError(error.IdentityExhausted, ledger.reserveObserved(1, allocator));
    try ledger.abortObserved(generation);
    try ledger.endOperation();
}

test "B3-0a ledger admits one outstanding observation and fail-closes the second" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 15,
        .node_addr = 16,
        .operation_incarnation = 17,
    }, 1);
    var generations: [max_entries]u64 = undefined;
    for (&generations) |*generation| {
        generation.* = try ledger.reserveObserved(0, allocator);
    }
    try std.testing.expectError(error.ObservationBusy, ledger.reserveObserved(0, allocator));
    for (generations) |generation| try ledger.abortObserved(generation);
    try ledger.endOperation();
}

test "B3-0a concurrent reserve rejection publishes no entry and burns the attempted identity" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 18,
        .node_addr = 19,
        .operation_incarnation = 20,
    }, 1);
    const first = try ledger.reserveObserved(1, allocator);
    try std.testing.expectError(error.ObservationBusy, ledger.reserveObserved(1, allocator));
    try std.testing.expectEqual(@as(usize, 1), ledger.entry_count);
    try ledger.abortObserved(first);
    const generation = try ledger.reserveObserved(1, allocator);
    try std.testing.expectEqual(@as(u64, 3), generation);
    try ledger.abortObserved(generation);
    try ledger.endOperation();
}

test "B3-0a canonical transfer atomically publishes response and consumes promoted entry" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 21,
        .node_addr = 22,
        .operation_incarnation = 23,
    }, 1);
    const payload = try allocator.dupe(u8, "accepted");
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, payload, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 31,
        .request_id = 32,
        .request_digest = 33,
    }).?;
    const correlated = contract.CorrelatedExecutedCall.init(
        contract.ExecutedCallReceipt.fromPrepared(prepared).?,
        32,
    ).?;
    var response: executed_response.ExecutedResponse = .{};
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    try std.testing.expect(ledger.transferPromotedResponse(
        receipt,
        &response,
        &owner,
        34,
        correlated,
    ) == .transferred);
    try std.testing.expectEqualStrings("accepted", try response.borrowAccepted(&owner));
    try std.testing.expectEqual(executed_response.DeinitOutcome.cleaned, response.deinit(&owner));
    try ledger.endOperation();
}

fn rpcFixtureBinding(destination_addr: usize) contract.BindingIdentity {
    return contract.BindingIdentity.init(.{
        .binding_incarnation = 51,
        .binding_storage_addr = 0x7100,
        .destination_addr = destination_addr,
        .binding_reservation_id = 53,
        .slot_incarnation = 59,
        .node_incarnation = 61,
        .host_id = 67,
        .connection_generation = 1,
        .runtime_id = 71,
        .role = .controller,
        .pid = 73,
        .process_nonce = 79,
    }).?;
}

fn rpcFixtureIdentity(destination_addr: usize) rpc_executed_response.Identity {
    return .{
        .authority_addr = 0x7180,
        .registry_incarnation = 83,
        .binding = rpcFixtureBinding(destination_addr),
        .transport_addr = 0x7200,
        .transport_incarnation = 89,
        .family = .bound_observation,
        .tag = .observation,
        .request_id = 97,
        .request_digest = 101,
        .response_epoch = 1,
        .destination_addr = destination_addr,
    };
}

test "B3-4/5 RPC ledger transfer publishes owner and consumes promoted entry" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0x7300,
        .node_addr = 0x7400,
        .operation_incarnation = 103,
    }, 1);
    const payload = try allocator.dupe(u8, "rpc-response");
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, payload, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    var response: rpc_executed_response.RpcExecutedResponse = .{};
    const identity = rpcFixtureIdentity(@intFromPtr(&response));
    try std.testing.expect(ledger.transferPromotedRpcResponse(receipt, &response, identity) == .transferred);
    var borrow: rpc_executed_response.RpcResponseBorrow = .{};
    var borrow_init: rpc_executed_response.PreparedBorrowInit = .{};
    try response.prepareBorrowInit(identity, &borrow, &borrow_init);
    response.commitBorrowReceiptNoFail(identity, &borrow, &borrow_init);
    var finish: rpc_executed_response.RpcResponseFinishTxn = .{};
    try response.prepareFinish(identity, &borrow, &finish);
    response.commitFreeNoFail(identity, &borrow, &finish);
    try std.testing.expect(finish.freeCaptured());
    response.finishCleanNoFail(&finish);
    try ledger.endOperation();
}

test "B3-4/5 RPC ledger transfer safe-frees empty payload and requires fail-stop" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0x7500,
        .node_addr = 0x7600,
        .operation_incarnation = 107,
    }, 1);
    const empty: []u8 = @constCast(&[_]u8{});
    const generation = try ledger.reserveObserved(0, allocator);
    try ledger.commitObserved(generation, empty, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        empty,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    var response: rpc_executed_response.RpcExecutedResponse = .{};
    const outcome = ledger.transferPromotedRpcResponse(
        receipt,
        &response,
        rpcFixtureIdentity(@intFromPtr(&response)),
    );
    try std.testing.expectEqual(PayloadFailStopReason.ledger_drift, outcome.fail_stop_required);
    try std.testing.expect(response.pristineExact());
    try ledger.endFailedRpcTransfer(.ledger_drift);
}

test "B3-4/5 RPC ledger transfer rejects copied receipt without owner mutation" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0x7700,
        .node_addr = 0x7800,
        .operation_incarnation = 109,
    }, 1);
    const payload = try allocator.dupe(u8, "rpc-response");
    defer allocator.free(payload);
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, payload, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    var copied = receipt;
    copied.generation += 1;
    var response: rpc_executed_response.RpcExecutedResponse = .{};
    try std.testing.expect(ledger.transferPromotedRpcResponse(
        copied,
        &response,
        rpcFixtureIdentity(@intFromPtr(&response)),
    ) == .fail_stop_required);
    try std.testing.expect(response.pristineExact());
    try ledger.endFailedRpcTransfer(.ledger_drift);
}

test "B3-0a provenance classification uses exact generation and seals no-free reason" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 41,
        .node_addr = 42,
        .operation_incarnation = 43,
    }, 1);
    var payload = [_]u8{ 1, 2 };
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, &payload, allocator);
    try std.testing.expect(ledger.classifyResponsePayloadProvenance(
        generation + 1,
        &payload,
        allocator,
        allocator,
    ) == .fail_stop_required);
    try std.testing.expect(ledger.ledger_terminal_no_free);
    try std.testing.expectEqual(PayloadFailStopReason.ledger_drift, ledger.ledger_terminal_reason.?);
    try std.testing.expectError(error.InvalidOwner, ledger.endOperation());

    var alias_ledger: Ledger = .{};
    try Ledger.initInPlace(&alias_ledger, allocator, .{
        .guard_addr = 44,
        .node_addr = 45,
        .operation_incarnation = 46,
    }, 1);
    try alias_ledger.bindForbiddenRanges(&.{.{
        .start = @intFromPtr(&payload),
        .len = payload.len,
    }});
    const alias_generation = try alias_ledger.reserveObserved(payload.len, allocator);
    try alias_ledger.commitObserved(alias_generation, &payload, allocator);
    const outcome = alias_ledger.classifyResponsePayloadProvenance(
        alias_generation,
        &payload,
        allocator,
        allocator,
    );
    try std.testing.expectEqual(PayloadFailStopReason.owner_alias, outcome.fail_stop_required);
    try std.testing.expectEqual(PayloadFailStopReason.owner_alias, alias_ledger.entries[0].terminal_reason.?);
    try std.testing.expectError(error.InvalidOwner, alias_ledger.endOperation());
}

test "B3-0a classifier uses the sealed forbidden inventory after caller scratch drift" {
    const allocator = std.testing.allocator;
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 47,
        .node_addr = 48,
        .operation_incarnation = 49,
    }, 1);
    var payload = [_]u8{ 7, 8, 9 };
    var caller_ranges = [_]ForbiddenRange{.{
        .start = @intFromPtr(&payload),
        .len = payload.len,
    }};
    try ledger.bindForbiddenRanges(&caller_ranges);
    caller_ranges[0] = .{ .start = 1, .len = 1 };
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, &payload, allocator);
    const outcome = ledger.classifyResponsePayloadProvenance(
        generation,
        &payload,
        allocator,
        allocator,
    );
    try std.testing.expectEqual(PayloadFailStopReason.owner_alias, outcome.fail_stop_required);
    try std.testing.expectEqual(PayloadFailStopReason.owner_alias, ledger.entries[0].terminal_reason.?);
    try std.testing.expectError(error.InvalidOwner, ledger.endOperation());
}

test "B3-0a payload allocation callback cannot forge the in-place descriptor before commit" {
    const DescriptorProbe = struct {
        parent: std.mem.Allocator,
        ledger: ?*Ledger = null,
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
            const result = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse
                return null;
            if (self.armed) {
                self.ledger.?.entries = @as([*]Entry, @ptrFromInt(0x1000))[0..1];
                self.drifted = true;
            }
            return result;
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
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        }
    };

    var probe = DescriptorProbe{ .parent = std.testing.allocator };
    const allocator = probe.allocator();
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 50,
        .node_addr = 51,
        .operation_incarnation = 52,
    }, 1);
    const generation = try ledger.reserveObserved(4, allocator);
    const canonical_entries = ledger.entries;
    probe.ledger = &ledger;
    probe.armed = true;
    const payload = try allocator.dupe(u8, "seal");
    probe.armed = false;
    defer allocator.free(payload);
    try std.testing.expect(probe.drifted);
    try std.testing.expectError(
        error.InvalidOwner,
        ledger.commitObserved(generation, payload, allocator),
    );
    ledger.entries = canonical_entries;
    try ledger.abortObserved(generation);
    try ledger.endOperation();
}

test "B3-0a in-place ledger performs no backing allocation grow or free" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, failing.allocator(), .{
        .guard_addr = 51,
        .node_addr = 52,
        .operation_incarnation = 53,
    }, 1);
    const generation = try ledger.reserveObserved(0, failing.allocator());
    try ledger.abortObserved(generation);
    try ledger.endOperation();
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "B3-0a payload free callback descriptor drift is scalar-first fail-stop" {
    const DriftAllocator = struct {
        parent: std.mem.Allocator,
        ledger: ?*Ledger = null,
        target_addr: usize = 0,
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
            const addr = if (memory.len == 0) 0 else @intFromPtr(memory.ptr);
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
            if (addr == self.target_addr and self.ledger != null) {
                const ledger = self.ledger.?;
                ledger.entries = @as([*]Entry, @ptrFromInt(0x1000))[0..8];
                ledger.entry_count = 1;
                self.drifted = true;
            }
        }
    };

    var probe = DriftAllocator{ .parent = std.testing.allocator };
    const allocator = probe.allocator();
    var ledger: Ledger = .{};
    try Ledger.initInPlace(&ledger, allocator, .{
        .guard_addr = 0xA1,
        .node_addr = 0xA2,
        .operation_incarnation = 0xA3,
    }, 1);
    const payload = try allocator.dupe(u8, "release");
    const generation = try ledger.reserveObserved(payload.len, allocator);
    try ledger.commitObserved(generation, payload, allocator);
    const receipt = switch (ledger.classifyResponsePayloadProvenance(
        generation,
        payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    const saved_entries = ledger.entries;
    const saved_count = ledger.entry_count;
    probe.ledger = &ledger;
    probe.target_addr = @intFromPtr(payload.ptr);
    try std.testing.expectError(error.InvalidOwner, ledger.releasePromotedResponse(receipt));
    try std.testing.expect(probe.drifted);
    try std.testing.expect(ledger.ledger_terminal_no_free);
    ledger.entries = saved_entries;
    ledger.entry_count = saved_count;
    ledger.ledger_terminal_no_free = false;
    ledger.ledger_terminal_reason = null;
    try ledger.endOperation();

    var second: Ledger = .{};
    try Ledger.initInPlace(&second, allocator, .{
        .guard_addr = 0xB1,
        .node_addr = 0xB2,
        .operation_incarnation = 0xB3,
    }, 1);
    const rejected_payload = try allocator.dupe(u8, "reject");
    const rejected_generation = try second.reserveObserved(rejected_payload.len, allocator);
    try second.commitObserved(rejected_generation, rejected_payload, allocator);
    const rejected_receipt = switch (second.classifyResponsePayloadProvenance(
        rejected_generation,
        rejected_payload,
        allocator,
        allocator,
    )) {
        .promoted => |value| value,
        .fail_stop_required => return error.TestUnexpectedResult,
    };
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 0xC1,
        .request_id = 0xC2,
        .request_digest = 0xC3,
    }).?;
    const correlated = contract.CorrelatedExecutedCall.init(
        contract.ExecutedCallReceipt.fromPrepared(prepared).?,
        0xC2,
    ).?;
    var response: executed_response.ExecutedResponse = .{};
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    const second_entries = second.entries;
    const second_count = second.entry_count;
    probe.drifted = false;
    probe.ledger = &second;
    probe.target_addr = @intFromPtr(rejected_payload.ptr);
    const outcome = second.transferPromotedResponse(
        rejected_receipt,
        &response,
        &owner,
        0,
        correlated,
    );
    try std.testing.expectEqual(PayloadFailStopReason.ledger_drift, outcome.fail_stop_required);
    try std.testing.expect(probe.drifted);
    second.entries = second_entries;
    second.entry_count = second_count;
    second.ledger_terminal_no_free = false;
    second.ledger_terminal_reason = null;
    try second.endOperation();
}
