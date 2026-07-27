//! Phase-aware, single-owner screen-inbox accounting for external attachments.
//!
//! A slot's tagged semantic is the phase SSOT and its `OwnedPayload` is the only allocator/free
//! authority. Tokens contain no pointer, so stale copies can only be rejected by this ledger.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const max_bytes: usize = protocol.max_client_screen_inbox;
pub const max_items: usize = protocol.max_client_screen_items;
pub const max_batch_bytes: usize = protocol.max_viewport_snapshot;
pub const max_batch_chunks: usize =
    protocol.max_viewport_snapshot / protocol.max_binary_chunk;

comptime {
    if (max_items > @as(usize, std.math.maxInt(u16)) + 1)
        @compileError("external inbox token slot cannot represent max_items");
}

pub const Token = struct {
    slot: u16,
    generation: u64,
};

pub const PayloadPhase = enum {
    frame,
    partial,
    completed,
    lease,
};

pub const RecoveryIntent = union(enum) {
    none,
    host: u64,
    client: u64,
};

pub const BatchSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    recovery_intent: RecoveryIntent = .none,
};

pub const PartialSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    chunk_count: u8,
    recovery_intent: RecoveryIntent = .none,
};

pub const PayloadSemantic = union(PayloadPhase) {
    frame: protocol.Header,
    partial: PartialSemantic,
    completed: BatchSemantic,
    lease: BatchSemantic,
};

pub const OwnedPayload = struct {
    allocator: std.mem.Allocator,
    allocation_ptr: ?[*]u8 = null,
    logical_len: usize = 0,

    pub fn takeOwned(allocator: std.mem.Allocator, allocation: *[]u8) OwnedPayload {
        if (allocation.len == 0) {
            allocation.* = &.{};
            return .{ .allocator = allocator };
        }
        const result: OwnedPayload = .{
            .allocator = allocator,
            .allocation_ptr = allocation.ptr,
            .logical_len = allocation.len,
        };
        allocation.* = &.{};
        return result;
    }

    pub fn empty(allocator: std.mem.Allocator) OwnedPayload {
        return .{ .allocator = allocator };
    }

    pub fn bytes(self: *const OwnedPayload) []const u8 {
        if (self.allocation_ptr) |ptr| return ptr[0..self.logical_len];
        return &.{};
    }

    pub fn deinit(self: *OwnedPayload) void {
        if (self.allocation_ptr) |ptr| self.allocator.free(ptr[0..self.logical_len]);
        self.* = .{ .allocator = self.allocator };
    }

    fn take(self: *OwnedPayload) OwnedPayload {
        const transferred = self.*;
        self.* = .{ .allocator = self.allocator };
        return transferred;
    }
};

pub const PayloadView = struct {
    phase: PayloadPhase,
    semantic: PayloadSemantic,
    bytes: []const u8,
};

pub const BatchView = struct {
    is_snapshot: bool,
    stream_id: u64,
    bytes: []const u8,
};

pub const SeedSpec = struct {
    semantic: PayloadSemantic,
    logical_len: usize,
};

const PayloadFingerprint = struct {
    allocator: std.mem.Allocator,
    address: usize,
    logical_len: usize,
};

const PlannedSeed = struct {
    slot: u16,
    generation: u64,
    spec: SeedSpec,
    payload: PayloadFingerprint,
};

const PlanLifecycle = enum {
    empty,
    prepared,
    committed,
    aborted,
};

pub const PreparedSeedPlan = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    entries: []PlannedSeed = &.{},
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    payload_wrappers_addr: usize = 0,
    expected_mutation_epoch: u64 = 0,
    expected_next_generation: u64 = 0,
    expected_generation_exhausted: bool = false,
    expected_next_slot_hint: usize = 0,
    total_bytes: usize = 0,
    lifecycle: PlanLifecycle = .empty,

    pub fn initInPlace(
        out: *PreparedSeedPlan,
        allocator: std.mem.Allocator,
        ledger: *ExternalInboxLedger,
        specs: []const SeedSpec,
        payloads: []const OwnedPayload,
    ) PlanError!void {
        if (out.lifecycle != .empty) return error.InvalidPlan;
        if (ledger.draining_or_drained) return error.Drained;
        if (ledger.invariant_failed or ledger.planning_disabled) return error.PlanningDisabled;
        if (!ledger.hasValidAccounting()) {
            ledger.invariant_failed = true;
            ledger.planning_disabled = true;
            return error.InvariantFailure;
        }
        if (ledger.mutation_epoch == std.math.maxInt(u64)) {
            ledger.planning_disabled = true;
            return error.EpochExhausted;
        }
        if (specs.len != payloads.len) return error.InvalidPlan;
        if (specs.len > max_items - ledger.charged_items) return error.ItemCapExceeded;
        try validateInitAliases(ledger, specs, payloads);
        const out_range = rangeOfValue(out);
        if (rangesOverlap(out_range, rangeOfValue(ledger)) or
            rangesOverlap(out_range, rangeOfSlice(SeedSpec, specs)) or
            rangesOverlap(out_range, rangeOfSlice(OwnedPayload, payloads)) or
            rangeOverlapsPayloads(out_range, payloads) or
            rangeOverlapsActive(out_range, ledger))
            return error.InvalidAlias;

        var entries = try allocator.alloc(PlannedSeed, specs.len);
        errdefer allocator.free(entries);
        if (rangesOverlap(rangeOfSlice(PlannedSeed, entries), rangeOfValue(ledger)) or
            rangesOverlap(rangeOfSlice(PlannedSeed, entries), out_range))
            return error.InvalidAlias;
        if (rangesOverlap(
            rangeOfSlice(PlannedSeed, entries),
            rangeOfSlice(SeedSpec, specs),
        ) or
            rangeOverlapsPayloads(rangeOfSlice(PlannedSeed, entries), payloads) or
            rangeOverlapsActive(rangeOfSlice(PlannedSeed, entries), ledger))
            return error.InvalidAlias;

        var total_bytes: usize = 0;
        var next_generation = ledger.next_generation;
        var generation_exhausted = ledger.generation_exhausted;
        var next_hint = ledger.next_slot_hint;

        for (specs, payloads, 0..) |spec, payload, index| {
            try validatePayload(&payload, spec.logical_len);
            try validateSemantic(spec.semantic, spec.logical_len);
            total_bytes = std.math.add(usize, total_bytes, spec.logical_len) catch
                return error.ArithmeticOverflow;
            const generation = try takePlannedGeneration(
                &next_generation,
                &generation_exhausted,
            );
            const slot = findFreeSlotPlanned(ledger, entries[0..index], next_hint) orelse
                return error.ItemCapExceeded;
            next_hint = (slot + 1) % max_items;
            entries[index] = .{
                .slot = @intCast(slot),
                .generation = generation,
                .spec = spec,
                .payload = fingerprint(payload),
            };
        }
        const next_bytes = std.math.add(usize, ledger.charged_bytes, total_bytes) catch
            return error.ByteCapExceeded;
        if (next_bytes > max_bytes) return error.ByteCapExceeded;

        out.* = .{
            .allocator = allocator,
            .entries = entries,
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(ledger),
            .payload_wrappers_addr = if (payloads.len == 0) 0 else @intFromPtr(payloads.ptr),
            .expected_mutation_epoch = ledger.mutation_epoch,
            .expected_next_generation = next_generation,
            .expected_generation_exhausted = generation_exhausted,
            .expected_next_slot_hint = next_hint,
            .total_bytes = total_bytes,
            .lifecycle = .prepared,
        };
    }

    pub fn deinit(self: *PreparedSeedPlan) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            self.allocator.free(self.entries);
            self.entries = &.{};
            self.lifecycle = .aborted;
        }
    }

    fn finishCommit(self: *PreparedSeedPlan) void {
        self.allocator.free(self.entries);
        self.entries = &.{};
        self.lifecycle = .committed;
    }

    fn isStablePrepared(self: *const PreparedSeedPlan) bool {
        return self.lifecycle == .prepared and
            self.saved_self_addr == @intFromPtr(self);
    }
};

pub const PlanError = std.mem.Allocator.Error || error{
    ArithmeticOverflow,
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidPlan,
    InvalidSemantic,
    InvariantFailure,
    PlanningDisabled,
    Drained,
};

pub const CommitError = error{
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidPlan,
    InvalidSemantic,
    InvariantFailure,
    PlanningDisabled,
    StalePlan,
    Drained,
};

pub const ReserveError = error{
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidSemantic,
    InvariantFailure,
    PlanningDisabled,
    Drained,
};

pub const InvariantError = error{ InvariantFailure, Drained };
pub const TransitionError = error{
    InvariantFailure,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidSemantic,
    InvalidTransition,
    PlanningDisabled,
    Drained,
};
pub const FinishError = error{ ActiveCharges, InvariantFailure };

pub const DrainReport = struct {
    drained_active_count: usize,
    drained_bytes: usize,
    had_sticky_invariant: bool,
};

const Slot = struct {
    active: bool = false,
    generation: u64 = 0,
    semantic: PayloadSemantic = inactiveSemantic(),
    payload: OwnedPayload = .{ .allocator = std.heap.page_allocator },
};

fn inactiveSemantic() PayloadSemantic {
    return .{ .lease = .{
        .stream_id = 0,
        .is_snapshot = false,
    } };
}

pub const ExternalInboxLedger = struct {
    slots: [max_items]Slot = [_]Slot{.{}} ** max_items,
    charged_bytes: usize = 0,
    charged_items: usize = 0,
    next_slot_hint: usize = 0,
    next_generation: u64 = 1,
    generation_exhausted: bool = false,
    mutation_epoch: u64 = 0,
    planning_disabled: bool = false,
    invariant_failed: bool = false,
    draining_or_drained: bool = false,

    pub fn reserveLease(
        self: *ExternalInboxLedger,
        semantic: BatchSemantic,
        payload: *OwnedPayload,
    ) ReserveError!Token {
        try self.ensureAuthorityMutation();
        const tagged: PayloadSemantic = .{ .lease = semantic };
        try validatePayload(payload, payload.logical_len);
        try validateSemantic(tagged, payload.logical_len);
        if (rangesOverlap(rangeOfValue(payload), rangeOfPayload(payload)) or
            rangeOverlapsLedgerOrActive(rangeOfValue(payload), self) or
            rangeOverlapsLedgerOrActive(rangeOfPayload(payload), self))
            return error.InvalidAlias;
        const next_bytes = std.math.add(usize, self.charged_bytes, payload.logical_len) catch
            return error.ByteCapExceeded;
        if (next_bytes > max_bytes) return error.ByteCapExceeded;
        if (self.charged_items >= max_items) return error.ItemCapExceeded;
        const slot_index = self.findFreeSlot() orelse return error.ItemCapExceeded;
        const generation = try self.prepareGeneration();

        self.slots[slot_index] = .{
            .active = true,
            .generation = generation,
            .semantic = tagged,
            .payload = payload.take(),
        };
        self.charged_bytes = next_bytes;
        self.charged_items += 1;
        self.next_slot_hint = (slot_index + 1) % max_items;
        self.commitAuthorityMutation();
        return .{ .slot = @intCast(slot_index), .generation = generation };
    }

    pub fn commitSeeds(
        self: *ExternalInboxLedger,
        plan: *PreparedSeedPlan,
        payloads: []OwnedPayload,
        token_output: []Token,
    ) CommitError!void {
        if (!plan.isStablePrepared() or plan.ledger_addr != @intFromPtr(self))
            return error.InvalidPlan;
        if (plan.entries.len != payloads.len or token_output.len != payloads.len)
            return error.InvalidPlan;
        const payload_wrappers_addr = if (payloads.len == 0) 0 else @intFromPtr(payloads.ptr);
        if (plan.payload_wrappers_addr != payload_wrappers_addr) return error.InvalidPlan;
        if (plan.entries.len == 0) {
            if (self.draining_or_drained) return error.Drained;
            if (self.invariant_failed or self.planning_disabled)
                return error.PlanningDisabled;
            if (!self.hasValidAccounting()) {
                self.invariant_failed = true;
                self.planning_disabled = true;
                return error.InvariantFailure;
            }
            if (self.mutation_epoch != plan.expected_mutation_epoch) return error.StalePlan;
            plan.finishCommit();
            return;
        }
        try self.ensureAuthorityMutation();
        if (self.mutation_epoch != plan.expected_mutation_epoch) return error.StalePlan;
        try validateCommitAliases(self, plan, payloads, token_output);

        var total_bytes: usize = 0;
        var next_generation = self.next_generation;
        var generation_exhausted = self.generation_exhausted;
        var next_hint = self.next_slot_hint;
        for (plan.entries, payloads, 0..) |entry, payload, index| {
            try validatePayload(&payload, entry.spec.logical_len);
            try validateSemantic(entry.spec.semantic, entry.spec.logical_len);
            if (!fingerprintMatches(entry.payload, payload)) return error.StalePlan;
            const generation = try takePlannedGeneration(
                &next_generation,
                &generation_exhausted,
            );
            const slot = findFreeSlotPlanned(self, plan.entries[0..index], next_hint) orelse
                return error.ItemCapExceeded;
            if (entry.slot != slot or entry.generation != generation) return error.InvalidPlan;
            next_hint = (slot + 1) % max_items;
            total_bytes = std.math.add(usize, total_bytes, entry.spec.logical_len) catch
                return error.ByteCapExceeded;
        }
        if (total_bytes != plan.total_bytes or
            next_generation != plan.expected_next_generation or
            generation_exhausted != plan.expected_generation_exhausted or
            next_hint != plan.expected_next_slot_hint)
            return error.InvalidPlan;
        const next_bytes = std.math.add(usize, self.charged_bytes, total_bytes) catch
            return error.ByteCapExceeded;
        if (next_bytes > max_bytes) return error.ByteCapExceeded;
        if (plan.entries.len > max_items - self.charged_items) return error.ItemCapExceeded;

        for (plan.entries, payloads, token_output) |entry, *payload, *output| {
            self.slots[entry.slot] = .{
                .active = true,
                .generation = entry.generation,
                .semantic = entry.spec.semantic,
                .payload = payload.take(),
            };
            output.* = .{ .slot = entry.slot, .generation = entry.generation };
        }
        self.charged_bytes = next_bytes;
        self.charged_items += plan.entries.len;
        self.next_generation = next_generation;
        self.generation_exhausted = generation_exhausted;
        self.next_slot_hint = next_hint;
        self.commitSeedMutation();
        plan.finishCommit();
    }

    pub fn borrow(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
    ) InvariantError!PayloadView {
        if (self.draining_or_drained) return error.Drained;
        if (self.invariant_failed) return error.InvariantFailure;
        const slot = try self.resolveActive(token);
        const semantic = slot.semantic;
        if (std.meta.activeTag(semantic) != expected_phase) return self.failInvariant();
        const payload = slot.payload;
        return .{
            .phase = std.meta.activeTag(semantic),
            .semantic = semantic,
            .bytes = payload.bytes(),
        };
    }

    pub fn borrowLease(
        self: *ExternalInboxLedger,
        token: Token,
    ) InvariantError!BatchView {
        const view = try self.borrow(token, .lease);
        const semantic = view.semantic.lease;
        return .{
            .is_snapshot = semantic.is_snapshot,
            .stream_id = semantic.stream_id,
            .bytes = view.bytes,
        };
    }

    pub fn relabel(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
        next_phase: PayloadPhase,
        recovery_intent: RecoveryIntent,
    ) TransitionError!Token {
        try self.ensureTransitionMutation();
        const slot = try self.resolveActive(token);
        const current = slot.semantic;
        if (std.meta.activeTag(current) != expected_phase) return self.failInvariant();
        const next = try relabeledSemantic(current, next_phase, recovery_intent);
        try validateSemantic(next, slot.payload.logical_len);
        const generation = try self.prepareGeneration();
        slot.semantic = next;
        slot.generation = generation;
        self.commitAuthorityMutation();
        return .{ .slot = token.slot, .generation = generation };
    }

    pub fn mergeInto(
        self: *ExternalInboxLedger,
        dst_token: Token,
        src_token: Token,
        replacement: *OwnedPayload,
        next_phase: PayloadPhase,
        expected_recovery_intent: RecoveryIntent,
    ) TransitionError!Token {
        try self.ensureTransitionMutation();
        if (dst_token.slot == src_token.slot) return error.InvalidAlias;
        const dst = try self.resolveActive(dst_token);
        const src = try self.resolveActive(src_token);
        if (std.meta.activeTag(dst.semantic) != .partial or
            std.meta.activeTag(src.semantic) != .frame)
            return self.failInvariant();
        const dst_semantic = dst.semantic.partial;
        const src_header = src.semantic.frame;
        if (!std.meta.eql(dst_semantic.recovery_intent, expected_recovery_intent))
            return error.InvalidSemantic;
        if (rangeOverlapsLedgerOrActiveExcept(
            rangeOfValue(replacement),
            self,
            dst_token.slot,
            src_token.slot,
        ) or rangeOverlapsLedgerOrActiveExcept(
            rangeOfPayload(replacement),
            self,
            dst_token.slot,
            src_token.slot,
        )) return error.InvalidAlias;
        const dst_payload = dst.payload;
        const src_payload = src.payload;
        if (rangesOverlap(rangeOfValue(replacement), rangeOfPayload(replacement)))
            return error.InvalidAlias;
        if (rangesOverlap(rangeOfPayload(&dst_payload), rangeOfPayload(&src_payload)))
            return self.failInvariant();
        if (rangesOverlap(rangeOfPayload(replacement), rangeOfPayload(&dst_payload)) or
            rangesOverlap(rangeOfPayload(replacement), rangeOfPayload(&src_payload)) or
            rangesOverlap(rangeOfValue(replacement), rangeOfPayload(&dst_payload)) or
            rangesOverlap(rangeOfValue(replacement), rangeOfPayload(&src_payload)))
            return error.InvalidAlias;
        const next_len = std.math.add(
            usize,
            dst_payload.logical_len,
            src_payload.logical_len,
        ) catch return error.InvalidPayload;
        try validatePayload(replacement, next_len);
        if (next_len > max_batch_bytes or
            dst_semantic.chunk_count >= max_batch_chunks or
            src_header.stream_id != dst_semantic.stream_id or
            (src_header.kind == .snapshot_chunk) != dst_semantic.is_snapshot)
            return error.InvalidSemantic;
        const end_stream = protocol.Flags.hasEndStream(src_header.flags);
        if ((end_stream and next_phase != .completed) or
            (!end_stream and next_phase != .partial))
            return error.InvalidTransition;
        if (!replacementMatches(dst_payload.bytes(), src_payload.bytes(), replacement.bytes()))
            return error.InvalidPayload;
        const source_bytes = std.math.add(
            usize,
            dst_payload.logical_len,
            src_payload.logical_len,
        ) catch return self.failInvariant();
        if (self.charged_items < 2 or self.charged_bytes < source_bytes)
            return self.failInvariant();
        const generation = try self.prepareGeneration();
        const next_batch = BatchSemantic{
            .stream_id = dst_semantic.stream_id,
            .is_snapshot = dst_semantic.is_snapshot,
            .recovery_intent = dst_semantic.recovery_intent,
        };
        const next_semantic: PayloadSemantic = if (next_phase == .partial)
            .{ .partial = .{
                .stream_id = next_batch.stream_id,
                .is_snapshot = next_batch.is_snapshot,
                .chunk_count = dst_semantic.chunk_count + 1,
                .recovery_intent = next_batch.recovery_intent,
            } }
        else
            .{ .completed = next_batch };

        var old_dst = dst.payload.take();
        var old_src = src.payload.take();
        dst.payload = replacement.take();
        dst.semantic = next_semantic;
        dst.generation = generation;
        src.* = .{ .generation = src_token.generation };
        self.charged_items -= 1;
        self.next_slot_hint = src_token.slot;
        self.commitAuthorityMutation();
        old_dst.deinit();
        old_src.deinit();
        return .{ .slot = dst_token.slot, .generation = generation };
    }

    pub fn release(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
    ) InvariantError!void {
        if (self.draining_or_drained) return error.Drained;
        const slot = try self.resolveActive(token);
        const semantic = slot.semantic;
        if (std.meta.activeTag(semantic) != expected_phase) return self.failInvariant();
        var payload = slot.payload;
        const charged = slot.payload.logical_len;
        if (rangeOverlapsActiveExceptSlot(
            rangeOfPayload(&payload),
            self,
            token.slot,
        )) return self.failInvariant();
        if (self.charged_items == 0 or self.charged_bytes < charged)
            return self.failInvariant();
        slot.* = .{ .generation = token.generation };
        self.charged_bytes -= charged;
        self.charged_items -= 1;
        self.next_slot_hint = token.slot;
        self.commitCleanupMutation();
        payload.deinit();
    }

    pub fn releaseLease(
        self: *ExternalInboxLedger,
        token: Token,
    ) InvariantError!void {
        return self.release(token, .lease);
    }

    pub fn drainAll(self: *ExternalInboxLedger) DrainReport {
        if (self.draining_or_drained) {
            return .{
                .drained_active_count = 0,
                .drained_bytes = 0,
                .had_sticky_invariant = self.invariant_failed,
            };
        }
        self.draining_or_drained = true;
        self.planning_disabled = true;
        self.commitCleanupMutation();
        var active_count: usize = 0;
        var bytes: usize = 0;
        var anomaly = self.invariant_failed;
        var observed_active: usize = 0;
        var observed_charge: usize = 0;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.active) {
                active_count += 1;
                observed_active += 1;
                const next_observed = std.math.add(
                    usize,
                    observed_charge,
                    slot.payload.logical_len,
                ) catch blk: {
                    anomaly = true;
                    break :blk std.math.maxInt(usize);
                };
                observed_charge = next_observed;
                validatePayload(&slot.payload, slot.payload.logical_len) catch {
                    anomaly = true;
                };
                validateSemantic(slot.semantic, slot.payload.logical_len) catch {
                    anomaly = true;
                };
            } else if (slot.payload.allocation_ptr != null or
                slot.payload.logical_len != 0 or !std.meta.eql(slot.semantic, inactiveSemantic()))
            {
                anomaly = true;
            }
            const owned_range = rangeOfPayload(&slot.payload);
            if (owned_range.start != owned_range.end) {
                for (self.slots[index + 1 ..]) |*later| {
                    if (rangesOverlap(owned_range, rangeOfPayload(&later.payload))) {
                        anomaly = true;
                        later.payload = .{ .allocator = later.payload.allocator };
                    }
                }
            }
            bytes +|= slot.payload.logical_len;
            slot.payload.deinit();
            slot.* = .{ .generation = slot.generation };
        }
        if (observed_active != self.charged_items or observed_charge != self.charged_bytes)
            anomaly = true;
        self.charged_items = 0;
        self.charged_bytes = 0;
        self.next_slot_hint = 0;
        self.invariant_failed = anomaly;
        return .{
            .drained_active_count = active_count,
            .drained_bytes = bytes,
            .had_sticky_invariant = anomaly,
        };
    }

    pub fn finish(self: *ExternalInboxLedger) FinishError!void {
        if (self.invariant_failed) return error.InvariantFailure;
        if (self.charged_bytes != 0 or self.charged_items != 0) return error.ActiveCharges;
        for (self.slots) |slot| {
            if (slot.active or slot.payload.allocation_ptr != null or
                slot.payload.logical_len != 0 or !std.meta.eql(slot.semantic, inactiveSemantic()))
                return error.ActiveCharges;
        }
    }

    fn ensureAuthorityMutation(self: *ExternalInboxLedger) error{
        EpochExhausted,
        InvariantFailure,
        PlanningDisabled,
        Drained,
    }!void {
        if (self.draining_or_drained) return error.Drained;
        if (self.invariant_failed or self.planning_disabled) return error.PlanningDisabled;
        if (!self.hasValidAccounting()) {
            self.invariant_failed = true;
            self.planning_disabled = true;
            return error.InvariantFailure;
        }
        if (self.mutation_epoch == std.math.maxInt(u64)) {
            self.planning_disabled = true;
            return error.EpochExhausted;
        }
    }

    fn ensureTransitionMutation(self: *ExternalInboxLedger) TransitionError!void {
        self.ensureAuthorityMutation() catch |err| return switch (err) {
            error.EpochExhausted => error.EpochExhausted,
            error.InvariantFailure => error.InvariantFailure,
            error.PlanningDisabled => error.PlanningDisabled,
            error.Drained => error.Drained,
        };
    }

    fn prepareGeneration(self: *ExternalInboxLedger) error{GenerationExhausted}!u64 {
        if (self.generation_exhausted) return error.GenerationExhausted;
        return self.next_generation;
    }

    fn commitAuthorityMutation(self: *ExternalInboxLedger) void {
        if (self.next_generation == std.math.maxInt(u64)) {
            self.generation_exhausted = true;
            self.planning_disabled = true;
        } else {
            self.next_generation += 1;
        }
        self.mutation_epoch += 1;
        if (self.mutation_epoch == std.math.maxInt(u64)) self.planning_disabled = true;
    }

    fn commitSeedMutation(self: *ExternalInboxLedger) void {
        if (self.generation_exhausted) self.planning_disabled = true;
        self.mutation_epoch += 1;
        if (self.mutation_epoch == std.math.maxInt(u64)) self.planning_disabled = true;
    }

    fn commitCleanupMutation(self: *ExternalInboxLedger) void {
        if (self.mutation_epoch < std.math.maxInt(u64)) self.mutation_epoch += 1;
        if (self.mutation_epoch == std.math.maxInt(u64)) self.planning_disabled = true;
    }

    fn findFreeSlot(self: *const ExternalInboxLedger) ?usize {
        for (0..max_items) |offset| {
            const index = (self.next_slot_hint + offset) % max_items;
            if (!self.slots[index].active) return index;
        }
        return null;
    }

    fn hasValidAccounting(self: *const ExternalInboxLedger) bool {
        if (self.charged_items > max_items or self.charged_bytes > max_bytes or
            self.next_slot_hint >= max_items)
            return false;
        var items: usize = 0;
        var bytes: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) {
                items = std.math.add(usize, items, 1) catch return false;
                bytes = std.math.add(usize, bytes, slot.payload.logical_len) catch return false;
            } else if (slot.payload.allocation_ptr != null or slot.payload.logical_len != 0) {
                return false;
            }
        }
        return items == self.charged_items and bytes == self.charged_bytes;
    }

    fn resolveActive(self: *ExternalInboxLedger, token: Token) InvariantError!*Slot {
        if (@as(usize, token.slot) >= max_items) return self.failInvariant();
        const slot = &self.slots[token.slot];
        if (!slot.active or slot.generation != token.generation) return self.failInvariant();
        return slot;
    }

    fn failInvariant(self: *ExternalInboxLedger) InvariantError {
        self.invariant_failed = true;
        self.planning_disabled = true;
        return error.InvariantFailure;
    }
};

const ByteRange = struct {
    start: usize,
    end: usize,

    fn empty() ByteRange {
        return .{ .start = 0, .end = 0 };
    }
};

fn rangeOfValue(value: anytype) ByteRange {
    return rangeOfSlice(u8, std.mem.asBytes(value));
}

fn rangeOfSlice(comptime T: type, slice: []const T) ByteRange {
    if (slice.len == 0) return ByteRange.empty();
    const start = @intFromPtr(slice.ptr);
    const byte_len = std.math.mul(usize, slice.len, @sizeOf(T)) catch
        return .{ .start = start, .end = std.math.maxInt(usize) };
    const end = std.math.add(usize, start, byte_len) catch std.math.maxInt(usize);
    return .{ .start = start, .end = end };
}

fn rangeOfPayload(payload: *const OwnedPayload) ByteRange {
    const ptr = payload.allocation_ptr orelse return ByteRange.empty();
    return rangeOfSlice(u8, ptr[0..payload.logical_len]);
}

fn rangesOverlap(a: ByteRange, b: ByteRange) bool {
    if (a.start == a.end or b.start == b.end) return false;
    return a.start < b.end and b.start < a.end;
}

fn fingerprint(payload: OwnedPayload) PayloadFingerprint {
    return .{
        .allocator = payload.allocator,
        .address = if (payload.allocation_ptr) |ptr| @intFromPtr(ptr) else 0,
        .logical_len = payload.logical_len,
    };
}

fn fingerprintMatches(expected: PayloadFingerprint, actual: OwnedPayload) bool {
    const current = fingerprint(actual);
    return expected.address == current.address and
        expected.logical_len == current.logical_len and
        std.meta.eql(expected.allocator, current.allocator);
}

fn validatePayload(payload: *const OwnedPayload, expected_len: usize) error{InvalidPayload}!void {
    if (payload.logical_len != expected_len) return error.InvalidPayload;
    if (payload.allocation_ptr != null) {
        if (payload.logical_len == 0) return error.InvalidPayload;
    } else if (payload.logical_len != 0) {
        return error.InvalidPayload;
    }
}

fn validateRecoveryIntent(intent: RecoveryIntent) error{InvalidSemantic}!void {
    switch (intent) {
        .none => {},
        .host, .client => |epoch| if (epoch == 0) return error.InvalidSemantic,
    }
}

fn validateSemantic(
    semantic: PayloadSemantic,
    logical_len: usize,
) error{InvalidSemantic}!void {
    switch (semantic) {
        .frame => |header| {
            if (header.major == 0 or
                (header.kind != .snapshot_chunk and header.kind != .delta_chunk) or
                header.request_id != 0 or header.stream_id == 0 or
                (header.flags != 0 and header.flags != protocol.Flags.end_stream) or
                header.payload_len != logical_len or logical_len > protocol.max_binary_chunk)
                return error.InvalidSemantic;
        },
        .partial => |batch| {
            if (batch.stream_id == 0 or batch.chunk_count == 0 or
                batch.chunk_count > max_batch_chunks or logical_len > max_batch_bytes)
                return error.InvalidSemantic;
            try validateRecoveryIntent(batch.recovery_intent);
        },
        .completed, .lease => |batch| {
            if (batch.stream_id == 0 or logical_len > max_batch_bytes)
                return error.InvalidSemantic;
            try validateRecoveryIntent(batch.recovery_intent);
        },
    }
}

fn validateInitAliases(
    ledger: *const ExternalInboxLedger,
    specs: []const SeedSpec,
    payloads: []const OwnedPayload,
) error{InvalidAlias}!void {
    const ledger_range = rangeOfValue(ledger);
    const specs_range = rangeOfSlice(SeedSpec, specs);
    const wrappers_range = rangeOfSlice(OwnedPayload, payloads);
    if (rangesOverlap(ledger_range, specs_range) or
        rangesOverlap(ledger_range, wrappers_range) or
        rangesOverlap(specs_range, wrappers_range) or
        rangeOverlapsActive(specs_range, ledger) or
        rangeOverlapsActive(wrappers_range, ledger))
        return error.InvalidAlias;
    for (payloads, 0..) |*payload, index| {
        const allocation = rangeOfPayload(payload);
        if (rangesOverlap(allocation, ledger_range) or
            rangesOverlap(allocation, specs_range) or
            rangesOverlap(allocation, wrappers_range) or
            rangeOverlapsActive(allocation, ledger))
            return error.InvalidAlias;
        for (payloads[0..index]) |*prior| {
            if (rangesOverlap(allocation, rangeOfPayload(prior))) return error.InvalidAlias;
        }
    }
}

fn validateCommitAliases(
    ledger: *const ExternalInboxLedger,
    plan: *const PreparedSeedPlan,
    payloads: []const OwnedPayload,
    outputs: []const Token,
) error{InvalidAlias}!void {
    const ledger_range = rangeOfValue(ledger);
    const plan_range = rangeOfValue(plan);
    const scratch_range = rangeOfSlice(PlannedSeed, plan.entries);
    const wrappers_range = rangeOfSlice(OwnedPayload, payloads);
    const output_range = rangeOfSlice(Token, outputs);
    const ranges = [_]ByteRange{
        ledger_range,
        plan_range,
        scratch_range,
        wrappers_range,
        output_range,
    };
    for (ranges, 0..) |range, index| {
        for (ranges[0..index]) |prior| {
            if (rangesOverlap(range, prior)) return error.InvalidAlias;
        }
        if (rangeOverlapsActive(range, ledger)) return error.InvalidAlias;
    }
    for (payloads, 0..) |*payload, index| {
        const allocation = rangeOfPayload(payload);
        for (ranges) |range| {
            if (rangesOverlap(allocation, range)) return error.InvalidAlias;
        }
        if (rangeOverlapsActive(allocation, ledger)) return error.InvalidAlias;
        for (payloads[0..index]) |*prior| {
            if (rangesOverlap(allocation, rangeOfPayload(prior))) return error.InvalidAlias;
        }
    }
}

fn rangeOverlapsPayloads(range: ByteRange, payloads: []const OwnedPayload) bool {
    if (rangesOverlap(range, rangeOfSlice(OwnedPayload, payloads))) return true;
    for (payloads) |*payload| if (rangesOverlap(range, rangeOfPayload(payload))) return true;
    return false;
}

fn rangeOverlapsActive(range: ByteRange, ledger: *const ExternalInboxLedger) bool {
    for (ledger.slots) |slot| {
        if (rangesOverlap(range, rangeOfPayload(&slot.payload))) return true;
    }
    return false;
}

fn rangeOverlapsLedgerOrActive(range: ByteRange, ledger: *const ExternalInboxLedger) bool {
    return rangesOverlap(range, rangeOfValue(ledger)) or rangeOverlapsActive(range, ledger);
}

fn rangeOverlapsLedgerOrActiveExcept(
    range: ByteRange,
    ledger: *const ExternalInboxLedger,
    first: u16,
    second: u16,
) bool {
    if (rangesOverlap(range, rangeOfValue(ledger))) return true;
    for (ledger.slots, 0..) |slot, index| {
        if (index == first or index == second) continue;
        if (rangesOverlap(range, rangeOfPayload(&slot.payload))) return true;
    }
    return false;
}

fn rangeOverlapsActiveExceptSlot(
    range: ByteRange,
    ledger: *const ExternalInboxLedger,
    excluded: u16,
) bool {
    for (ledger.slots, 0..) |slot, index| {
        if (index == excluded or !slot.active) continue;
        if (rangesOverlap(range, rangeOfPayload(&slot.payload))) return true;
    }
    return false;
}

fn takePlannedGeneration(
    next_generation: *u64,
    exhausted: *bool,
) error{GenerationExhausted}!u64 {
    if (exhausted.*) return error.GenerationExhausted;
    const generation = next_generation.*;
    if (generation == std.math.maxInt(u64)) {
        exhausted.* = true;
    } else {
        next_generation.* = generation + 1;
    }
    return generation;
}

fn findFreeSlotPlanned(
    ledger: *const ExternalInboxLedger,
    prior: []const PlannedSeed,
    hint: usize,
) ?usize {
    for (0..max_items) |offset| {
        const index = (hint + offset) % max_items;
        if (ledger.slots[index].active) continue;
        var claimed = false;
        for (prior) |entry| {
            if (entry.slot == index) {
                claimed = true;
                break;
            }
        }
        if (!claimed) return index;
    }
    return null;
}

fn relabeledSemantic(
    current: PayloadSemantic,
    next_phase: PayloadPhase,
    recovery_intent: RecoveryIntent,
) error{InvalidTransition}!PayloadSemantic {
    return switch (current) {
        .frame => |header| blk: {
            const end_stream = protocol.Flags.hasEndStream(header.flags);
            const batch = BatchSemantic{
                .stream_id = header.stream_id,
                .is_snapshot = header.kind == .snapshot_chunk,
                .recovery_intent = recovery_intent,
            };
            if (!end_stream and next_phase == .partial) break :blk .{ .partial = .{
                .stream_id = batch.stream_id,
                .is_snapshot = batch.is_snapshot,
                .chunk_count = 1,
                .recovery_intent = batch.recovery_intent,
            } };
            if (end_stream and next_phase == .completed) break :blk .{ .completed = batch };
            return error.InvalidTransition;
        },
        .completed => |batch| {
            if (next_phase != .lease or
                !std.meta.eql(batch.recovery_intent, recovery_intent))
                return error.InvalidTransition;
            return .{ .lease = batch };
        },
        else => error.InvalidTransition,
    };
}

fn replacementMatches(dst: []const u8, src: []const u8, replacement: []const u8) bool {
    return replacement.len == dst.len + src.len and
        std.mem.eql(u8, replacement[0..dst.len], dst) and
        std.mem.eql(u8, replacement[dst.len..], src);
}

fn leaseSemantic(stream_id: u64, is_snapshot: bool) BatchSemantic {
    return .{ .stream_id = stream_id, .is_snapshot = is_snapshot };
}

fn owned(allocator: std.mem.Allocator, text: []const u8) !OwnedPayload {
    var allocation = try allocator.dupe(u8, text);
    return OwnedPayload.takeOwned(allocator, &allocation);
}

test "reserveLease is atomic and enforces exact caps" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload_allocation = try allocator.alloc(u8, max_batch_bytes);
    var payload = OwnedPayload.takeOwned(allocator, &payload_allocation);
    const token = try ledger.reserveLease(leaseSemantic(7, true), &payload);
    try std.testing.expectEqual(@as(usize, 0), payload.logical_len);
    var exact_allocation = try allocator.alloc(u8, max_bytes - max_batch_bytes);
    var exact = OwnedPayload.takeOwned(allocator, &exact_allocation);
    const exact_token = try ledger.reserveLease(leaseSemantic(7, false), &exact);
    try std.testing.expectEqual(max_bytes, ledger.charged_bytes);
    var excess = try owned(allocator, "x");
    defer excess.deinit();
    try std.testing.expectError(
        error.ByteCapExceeded,
        ledger.reserveLease(leaseSemantic(7, true), &excess),
    );
    try ledger.releaseLease(token);
    try ledger.releaseLease(exact_token);
    try ledger.finish();
}

test "seed commit is all-or-none and fills every token" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{
        try owned(allocator, "a"),
        try owned(allocator, "bc"),
    };
    defer for (&payloads) |*payload| payload.deinit();
    const specs = [_]SeedSpec{
        .{ .semantic = .{ .frame = .{
            .major = protocol.version_major,
            .kind = .delta_chunk,
            .stream_id = 7,
            .payload_len = 1,
        } }, .logical_len = 1 },
        .{ .semantic = .{ .completed = leaseSemantic(7, true) }, .logical_len = 2 },
    };
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [2]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    try std.testing.expectEqual(@as(usize, 2), ledger.charged_items);
    try std.testing.expect(tokens[0].generation != tokens[1].generation);
    try ledger.release(tokens[0], .frame);
    try ledger.release(tokens[1], .completed);
    try ledger.finish();
}

test "zero seed transaction is an epoch-neutral committed tombstone" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const specs: []const SeedSpec = &.{};
    const payloads: []const OwnedPayload = &.{};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, specs, payloads);
    defer plan.deinit();
    const before = ledger.mutation_epoch;
    try ledger.commitSeeds(&plan, &.{}, &.{});
    try std.testing.expectEqual(before, ledger.mutation_epoch);
    try std.testing.expectEqual(PlanLifecycle.committed, plan.lifecycle);
}

test "zero seed transaction still rejects stale and drained ledgers" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var stale: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&stale, allocator, &ledger, &.{}, &.{});
    defer stale.deinit();
    var payload = OwnedPayload.empty(allocator);
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    try std.testing.expectError(error.StalePlan, ledger.commitSeeds(&stale, &.{}, &.{}));
    try ledger.releaseLease(token);

    var drained_plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&drained_plan, allocator, &ledger, &.{}, &.{});
    defer drained_plan.deinit();
    _ = ledger.drainAll();
    try std.testing.expectError(
        error.Drained,
        ledger.commitSeeds(&drained_plan, &.{}, &.{}),
    );
}

test "zero seed transaction rejects accounting corruption" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &.{}, &.{});
    defer plan.deinit();
    ledger.charged_items = 1;
    try std.testing.expectError(
        error.InvariantFailure,
        ledger.commitSeeds(&plan, &.{}, &.{}),
    );
    try std.testing.expect(ledger.invariant_failed);
    _ = ledger.drainAll();
}

test "seed output alias and wrong count preserve every owner" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitSeeds(&plan, &payloads, &.{}),
    );
    const aliased_output: []Token = @as([*]Token, @ptrCast(@alignCast(&payloads)))[0..1];
    try std.testing.expectError(
        error.InvalidAlias,
        ledger.commitSeeds(&plan, &payloads, aliased_output),
    );
    try std.testing.expectEqualStrings("x", payloads[0].bytes());
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "seed plan allocation failure preserves payload and ledger" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var plan: PreparedSeedPlan = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        PreparedSeedPlan.initInPlace(
            &plan,
            failing.allocator(),
            &ledger,
            &specs,
            &payloads,
        ),
    );
    try std.testing.expectEqualStrings("x", payloads[0].bytes());
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "seed rejects noncanonical header length and chunk boundary" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const bad_header = [_]SeedSpec{.{
        .semantic = .{ .frame = .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .payload_len = 2,
        } },
        .logical_len = 1,
    }};
    var header_plan: PreparedSeedPlan = .{};
    try std.testing.expectError(
        error.InvalidSemantic,
        PreparedSeedPlan.initInPlace(
            &header_plan,
            allocator,
            &ledger,
            &bad_header,
            &payloads,
        ),
    );
    const bad_chunks = [_]SeedSpec{.{
        .semantic = .{ .partial = .{
            .stream_id = 7,
            .is_snapshot = false,
            .chunk_count = max_batch_chunks + 1,
        } },
        .logical_len = 1,
    }};
    var chunk_plan: PreparedSeedPlan = .{};
    try std.testing.expectError(
        error.InvalidSemantic,
        PreparedSeedPlan.initInPlace(
            &chunk_plan,
            allocator,
            &ledger,
            &bad_chunks,
            &payloads,
        ),
    );
}

test "copied prepared plan cannot free or commit original scratch" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var original: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&original, allocator, &ledger, &specs, &payloads);
    defer original.deinit();
    var copied = original;
    copied.deinit();
    var output: [1]Token = undefined;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitSeeds(&copied, &payloads, &output),
    );
    try ledger.commitSeeds(&original, &payloads, &output);
    try ledger.release(output[0], .completed);
}

test "prepared plan is bound to the exact ledger address" {
    const allocator = std.testing.allocator;
    var first: ExternalInboxLedger = .{};
    var second: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &first, &specs, &payloads);
    defer plan.deinit();
    var output: [1]Token = undefined;
    try std.testing.expectError(
        error.InvalidPlan,
        second.commitSeeds(&plan, &payloads, &output),
    );
    try std.testing.expectEqual(@as(usize, 0), first.charged_items);
    try std.testing.expectEqual(@as(usize, 0), second.charged_items);
}

test "prepared plan rejects a copied payload wrapper inventory" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var original = [_]OwnedPayload{try owned(allocator, "x")};
    defer original[0].deinit();
    var copied = original;
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &original);
    defer plan.deinit();
    var output: [1]Token = undefined;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitSeeds(&plan, &copied, &output),
    );
    // `copied` is a deliberately invalid non-owner alias; only the original is deinitialized.
    copied[0] = OwnedPayload.empty(allocator);
}

test "ledger enforces exact item cap with canonical empty leases" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var tokens: [max_items]Token = undefined;
    for (&tokens) |*token| {
        var payload = OwnedPayload.empty(allocator);
        token.* = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    }
    var rejected = OwnedPayload.empty(allocator);
    try std.testing.expectError(
        error.ItemCapExceeded,
        ledger.reserveLease(leaseSemantic(7, false), &rejected),
    );
    for (tokens) |token| try ledger.releaseLease(token);
    try ledger.finish();
}

test "stale seed plan preserves source output and ledger" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "a")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{ .semantic = .{ .completed = leaseSemantic(7, false) }, .logical_len = 1 }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var other = try owned(allocator, "b");
    const other_token = try ledger.reserveLease(leaseSemantic(8, false), &other);
    var output = [_]Token{.{ .slot = 99, .generation = 99 }};
    try std.testing.expectError(error.StalePlan, ledger.commitSeeds(&plan, &payloads, &output));
    try std.testing.expectEqualStrings("a", payloads[0].bytes());
    try std.testing.expectEqual(@as(u16, 99), output[0].slot);
    try ledger.releaseLease(other_token);
}

test "relabel invalidates stale token and obeys end_stream" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "a")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{ .semantic = .{ .frame = .{
        .major = protocol.version_major,
        .kind = .delta_chunk,
        .stream_id = 7,
        .payload_len = 1,
    } }, .logical_len = 1 }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [1]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    const partial = try ledger.relabel(tokens[0], .frame, .partial, .none);
    try std.testing.expectError(error.InvariantFailure, ledger.borrow(tokens[0], .frame));
    const report = ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 1), report.drained_active_count);
    try std.testing.expectError(error.Drained, ledger.borrow(partial, .partial));
}

test "end-stream frame becomes completed then lease with exact recovery intent" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .frame = .{
            .kind = .snapshot_chunk,
            .flags = protocol.Flags.end_stream,
            .stream_id = 7,
            .payload_len = 1,
        } },
        .logical_len = 1,
    }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [1]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    const intent: RecoveryIntent = .{ .host = 9 };
    const completed = try ledger.relabel(tokens[0], .frame, .completed, intent);
    try std.testing.expectError(
        error.InvalidTransition,
        ledger.relabel(completed, .completed, .lease, .{ .host = 10 }),
    );
    const lease = try ledger.relabel(completed, .completed, .lease, intent);
    const view = try ledger.borrow(lease, .lease);
    try std.testing.expect(std.meta.eql(intent, view.semantic.lease.recovery_intent));
    try ledger.releaseLease(lease);
}

test "sticky invariant blocks sibling borrow but not exact cleanup" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var first_payload = try owned(allocator, "a");
    var second_payload = try owned(allocator, "b");
    const first = try ledger.reserveLease(leaseSemantic(7, false), &first_payload);
    const second = try ledger.reserveLease(leaseSemantic(8, false), &second_payload);
    try std.testing.expectError(
        error.InvariantFailure,
        ledger.borrow(.{ .slot = first.slot, .generation = first.generation + 1 }, .lease),
    );
    try std.testing.expectError(error.InvariantFailure, ledger.borrowLease(second));
    try ledger.releaseLease(first);
    try ledger.releaseLease(second);
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
}

test "last generation commits once and cleanup remains available" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .next_generation = std.math.maxInt(u64) };
    var payload = try owned(allocator, "last");
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    try std.testing.expectEqual(std.math.maxInt(u64), token.generation);
    try std.testing.expect(ledger.generation_exhausted);
    var rejected = try owned(allocator, "next");
    defer rejected.deinit();
    try std.testing.expectError(
        error.PlanningDisabled,
        ledger.reserveLease(leaseSemantic(7, false), &rejected),
    );
    try ledger.releaseLease(token);
    try ledger.finish();
}

test "merge takes exact replacement and frees both source payloads" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{
        try owned(allocator, "a"),
        try owned(allocator, "b"),
    };
    defer for (&payloads) |*payload| payload.deinit();
    const specs = [_]SeedSpec{
        .{ .semantic = .{ .partial = .{
            .stream_id = 7,
            .is_snapshot = false,
            .chunk_count = 1,
        } }, .logical_len = 1 },
        .{ .semantic = .{ .frame = .{
            .major = protocol.version_major,
            .kind = .delta_chunk,
            .flags = protocol.Flags.end_stream,
            .stream_id = 7,
            .payload_len = 1,
        } }, .logical_len = 1 },
    };
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [2]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    var replacement = try owned(allocator, "ab");
    defer replacement.deinit();
    const completed = try ledger.mergeInto(
        tokens[0],
        tokens[1],
        &replacement,
        .completed,
        .none,
    );
    try std.testing.expectEqual(@as(usize, 0), replacement.logical_len);
    const view = try ledger.borrow(completed, .completed);
    try std.testing.expectEqualStrings("ab", view.bytes);
    try ledger.release(completed, .completed);
    try ledger.finish();
}

test "merge wrong bytes is mutation-free" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{
        try owned(allocator, "a"),
        try owned(allocator, "b"),
    };
    defer for (&payloads) |*payload| payload.deinit();
    const specs = [_]SeedSpec{
        .{ .semantic = .{ .partial = .{
            .stream_id = 7,
            .is_snapshot = false,
            .chunk_count = 1,
        } }, .logical_len = 1 },
        .{ .semantic = .{ .frame = .{
            .major = protocol.version_major,
            .kind = .delta_chunk,
            .flags = protocol.Flags.end_stream,
            .stream_id = 7,
            .payload_len = 1,
        } }, .logical_len = 1 },
    };
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [2]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    const epoch = ledger.mutation_epoch;
    var replacement = try owned(allocator, "zz");
    defer replacement.deinit();
    try std.testing.expectError(
        error.InvalidPayload,
        ledger.mergeInto(tokens[0], tokens[1], &replacement, .completed, .none),
    );
    try std.testing.expectEqual(epoch, ledger.mutation_epoch);
    try std.testing.expectEqualStrings("a", (try ledger.borrow(tokens[0], .partial)).bytes);
    try std.testing.expectEqualStrings("b", (try ledger.borrow(tokens[1], .frame)).bytes);
    try ledger.release(tokens[0], .partial);
    try ledger.release(tokens[1], .frame);
}

test "merge rejects aliased source owners before any free" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{
        try owned(allocator, "a"),
        try owned(allocator, "b"),
    };
    defer for (&payloads) |*payload| payload.deinit();
    const specs = [_]SeedSpec{
        .{ .semantic = .{ .partial = .{
            .stream_id = 7,
            .is_snapshot = false,
            .chunk_count = 1,
        } }, .logical_len = 1 },
        .{ .semantic = .{ .frame = .{
            .kind = .delta_chunk,
            .flags = protocol.Flags.end_stream,
            .stream_id = 7,
            .payload_len = 1,
        } }, .logical_len = 1 },
    };
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [2]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    var original_src = ledger.slots[tokens[1].slot].payload.take();
    ledger.slots[tokens[1].slot].payload = ledger.slots[tokens[0].slot].payload;
    var replacement = try owned(allocator, "ab");
    defer replacement.deinit();
    try std.testing.expectError(
        error.InvariantFailure,
        ledger.mergeInto(tokens[0], tokens[1], &replacement, .completed, .none),
    );
    ledger.slots[tokens[1].slot].payload = original_src.take();
    try ledger.release(tokens[0], .partial);
    try ledger.release(tokens[1], .frame);
}

test "release defers duplicate-owner corruption to authoritative drain" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var first_payload = try owned(allocator, "a");
    var second_payload = try owned(allocator, "b");
    const first = try ledger.reserveLease(leaseSemantic(7, false), &first_payload);
    const second = try ledger.reserveLease(leaseSemantic(8, false), &second_payload);
    var displaced = ledger.slots[second.slot].payload.take();
    defer displaced.deinit();
    ledger.slots[second.slot].payload = ledger.slots[first.slot].payload;
    try std.testing.expectError(error.InvariantFailure, ledger.releaseLease(first));
    const report = ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectEqual(@as(usize, 2), report.drained_active_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "drain sweeps lost descriptors and is idempotent" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "lost");
    _ = try ledger.reserveLease(leaseSemantic(7, true), &payload);
    const first = ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 1), first.drained_active_count);
    try std.testing.expectEqual(@as(usize, 4), first.drained_bytes);
    const second = ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 0), second.drained_active_count);
    try std.testing.expectError(error.Drained, ledger.reserveLease(leaseSemantic(7, true), &payload));
    try ledger.finish();
}

test "drain repairs inactive payload and counter corruption without double free" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    ledger.slots[3].payload = try owned(allocator, "orphan");
    ledger.charged_items = 99;
    const report = ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
    const second = ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 0), second.drained_bytes);
}

test "drain reports active semantic corruption" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "x");
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    ledger.slots[token.slot].semantic.lease.stream_id = 0;
    const report = ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
}

test "epoch exhaustion never blocks cleanup" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .mutation_epoch = std.math.maxInt(u64) - 1 };
    var payload = try owned(allocator, "last");
    const token = try ledger.reserveLease(leaseSemantic(7, true), &payload);
    try std.testing.expect(ledger.planning_disabled);
    try ledger.releaseLease(token);
    try std.testing.expectEqual(std.math.maxInt(u64), ledger.mutation_epoch);
    try ledger.finish();
}

test "exact max epoch rejects authority and latches planning disabled" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .mutation_epoch = std.math.maxInt(u64) };
    var payload = try owned(allocator, "x");
    defer payload.deinit();
    try std.testing.expectError(
        error.EpochExhausted,
        ledger.reserveLease(leaseSemantic(7, false), &payload),
    );
    try std.testing.expect(ledger.planning_disabled);
    try std.testing.expectEqualStrings("x", payload.bytes());
}

test "counter corruption cannot underflow release before authoritative drain" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "x");
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    ledger.charged_items = 0;
    try std.testing.expectError(error.InvariantFailure, ledger.releaseLease(token));
    const report = ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectEqual(@as(usize, 1), report.drained_active_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "oversized aggregate item counter latches before cap subtraction" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .charged_items = max_items + 1 };
    var payload = OwnedPayload.empty(allocator);
    try std.testing.expectError(
        error.InvariantFailure,
        ledger.reserveLease(leaseSemantic(7, false), &payload),
    );
    try std.testing.expect(ledger.invariant_failed);
    const report = ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
}
