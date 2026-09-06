//! Phase-aware, single-owner screen-inbox accounting for external attachments.
//!
//! A slot's tagged semantic is the phase SSOT and its `OwnedPayload` is the only allocator/free
//! authority. Tokens contain no pointer, so stale copies can only be rejected by this ledger.

const std = @import("std");
const external_recovery_types = @import("external_recovery_types.zig");
const builtin = @import("builtin");
const frozen_cleanup_guard = @import("frozen_cleanup_guard.zig");
const owner_cleanup = @import("external_owner_cleanup.zig");
const limits = @import("external_inbox_limits.zig");
const owner_seal = @import("external_owner_seal.zig");
const owner_range = @import("external_owner_range.zig");
const protocol = @import("protocol.zig");
const external_rx_types = @import("external_rx_types.zig");

pub const max_bytes: usize = limits.max_bytes;
pub const max_items: usize = limits.max_items;
pub const max_batch_bytes: usize = protocol.max_viewport_snapshot;
pub const max_batch_chunks: usize = protocol.max_screen_batch_chunks;
pub const max_stored_external_span: usize =
    protocol.max_viewport_snapshot +
    protocol.max_screen_batch_chunks * protocol.header_size;

comptime {
    if (max_items > @as(usize, std.math.maxInt(u16)) + 1)
        @compileError("external inbox token slot cannot represent max_items");
    if (max_stored_external_span > std.math.maxInt(u32))
        @compileError("compact external RX span cannot represent the protocol batch cap");
}

pub const Token = struct {
    slot: u16,
    generation: u64,
};

const SeedRetirementLifecycle = enum {
    empty,
    prepared,
    retired_tombstone,
};

/// Deferred cleanup for the allocation that held a committed seed plan.
///
/// The ledger publishes ownership and tombstones `PreparedSeedPlan` without invoking the
/// allocator. An outer aggregate may then finish its callback-free publication suffix before
/// retiring this stack-bound handle.
pub const PreparedSeedRetirement = struct {
    saved_self_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    entries: []PlannedSeed = &.{},
    lifecycle: SeedRetirementLifecycle = .empty,

    pub fn isEmpty(self: *const PreparedSeedRetirement) bool {
        return self.lifecycle == .empty;
    }

    pub fn retire(self: *PreparedSeedRetirement) void {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self))
            return;
        const allocator = self.allocator;
        const entries = self.entries;
        self.* = .{ .lifecycle = .retired_tombstone };
        if (entries.len != 0) allocator.free(entries);
    }
};

pub const PayloadPhase = enum(u2) {
    frame,
    partial,
    completed,
    lease,
};

pub const RecoveryIntent = external_recovery_types.Intent;

pub const CompactExternalRange = struct {
    start_absolute: u64,
    span: u32,
};

const StoredRxBatchProvenanceTag = enum(u1) {
    untracked,
    external,
};

pub const StoredRxBatchProvenance = union(StoredRxBatchProvenanceTag) {
    untracked,
    external: CompactExternalRange,
};

pub const ObservedRxBatchProvenance = union(enum) {
    untracked,
    external: external_rx_types.RxRange,
};

const LedgerExternalIdentityLifecycle = enum {
    empty,
    bound,
    drained_tombstone,
};

pub const LedgerExternalIdentitySeal = struct {
    ledger_addr: usize = 0,
    identity: ?external_rx_types.RxIdentity = null,
    generation: u64 = 0,
    lifecycle: LedgerExternalIdentityLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

fn writeRecoveryIntent(writer: *owner_seal.Writer, intent: RecoveryIntent) void {
    switch (intent) {
        .none => writer.writeU8(0),
        .host => |epoch| {
            writer.writeU8(1);
            writer.writeU64(epoch);
        },
        .client => |epoch| {
            writer.writeU8(2);
            writer.writeU64(epoch);
        },
    }
}

fn validateRxIdentity(
    identity: external_rx_types.RxIdentity,
) error{InvalidSemantic}!void {
    if (identity.attach_instance_id == 0 or identity.destination_slot_addr == 0)
        return error.InvalidSemantic;
}

fn validateCompactExternalRange(
    range: CompactExternalRange,
) error{InvalidSemantic}!void {
    if (range.span == 0) return error.InvalidSemantic;
    if (@as(usize, range.span) > max_stored_external_span)
        return error.InvalidSemantic;
    _ = std.math.add(u64, range.start_absolute, range.span) catch
        return error.InvalidSemantic;
}

fn writeStoredProvenance(
    writer: *owner_seal.Writer,
    provenance: StoredRxBatchProvenance,
) void {
    switch (provenance) {
        .untracked => writer.writeU8(0),
        .external => |range| {
            writer.writeU8(1);
            writer.writeU64(range.start_absolute);
            writer.writeU64(range.span);
        },
    }
}

fn externalIdentityDigest(
    ledger_addr: usize,
    identity: ?external_rx_types.RxIdentity,
    generation: u64,
    lifecycle: LedgerExternalIdentityLifecycle,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULEI1");
    writer.writeUsize(ledger_addr);
    if (identity) |value| {
        writer.writeBool(true);
        writer.writeU64(value.attach_instance_id);
        writer.writeUsize(value.destination_slot_addr);
    } else {
        writer.writeBool(false);
    }
    writer.writeU64(generation);
    writer.writeU8(@intFromEnum(lifecycle));
    return writer.finish();
}

fn makeExternalIdentitySeal(
    ledger: *const ExternalInboxLedger,
    identity: external_rx_types.RxIdentity,
    generation: u64,
    lifecycle: LedgerExternalIdentityLifecycle,
) LedgerExternalIdentitySeal {
    const ledger_addr = @intFromPtr(ledger);
    return .{
        .ledger_addr = ledger_addr,
        .identity = identity,
        .generation = generation,
        .lifecycle = lifecycle,
        .digest = externalIdentityDigest(ledger_addr, identity, generation, lifecycle),
    };
}

fn isCanonicalEmptyIdentitySeal(seal: LedgerExternalIdentitySeal) bool {
    return seal.ledger_addr == 0 and seal.identity == null and seal.generation == 0 and
        seal.lifecycle == .empty and
        std.mem.allEqual(u8, &seal.digest, 0);
}

pub const BatchSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    recovery_intent: RecoveryIntent = .none,
    provenance: StoredRxBatchProvenance = .untracked,
};

pub const PartialSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    chunk_count: u8,
    recovery_intent: RecoveryIntent = .none,
    provenance: StoredRxBatchProvenance = .untracked,
};

pub const ObservedBatchSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    recovery_intent: RecoveryIntent = .none,
    provenance: ObservedRxBatchProvenance = .untracked,
};

pub const ObservedPartialSemantic = struct {
    stream_id: u64,
    is_snapshot: bool,
    chunk_count: u8,
    recovery_intent: RecoveryIntent = .none,
    provenance: ObservedRxBatchProvenance = .untracked,
};

pub const PayloadSemantic = union(PayloadPhase) {
    frame: protocol.Header,
    partial: PartialSemantic,
    completed: BatchSemantic,
    lease: BatchSemantic,
};

pub const ObservedPayloadSemantic = union(PayloadPhase) {
    frame: protocol.Header,
    partial: ObservedPartialSemantic,
    completed: ObservedBatchSemantic,
    lease: ObservedBatchSemantic,
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

    fn mutableBytes(self: *OwnedPayload) []u8 {
        if (self.allocation_ptr) |ptr| return ptr[0..self.logical_len];
        return @constCast(&.{});
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
    semantic: ObservedPayloadSemantic,
    bytes: []const u8,
};

pub const BatchView = struct {
    is_snapshot: bool,
    stream_id: u64,
    provenance: ObservedRxBatchProvenance,
    recovery_key: ?external_recovery_types.Key,
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
    content_digest: owner_seal.Digest = [_]u8{0} ** 32,
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
    sealed_allocator: std.mem.Allocator = std.heap.page_allocator,
    entries: []PlannedSeed = &.{},
    cleanup_entries: []PlannedSeed = &.{},
    entries_addr: usize = 0,
    entries_len: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
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
        if (ledger.teardown_active) return error.TeardownActive;
        if (ledger.draining_or_drained) return error.Drained;
        if (ledger.invariant_failed or ledger.planning_disabled) return error.PlanningDisabled;
        // Planning is a read-only transaction boundary. Sticky fail-close state belongs to the
        // authority mutator/commit path; changing it here would make a rejected c2 prepare mutate
        // the target ledger before the outer transaction has a verdict.
        if (!ledger.hasValidAccounting()) return error.InvariantFailure;
        if (ledger.mutation_epoch == std.math.maxInt(u64)) return error.EpochExhausted;
        if (specs.len != payloads.len) return error.InvalidPlan;
        if (specs.len > max_items - ledger.residentItems()) return error.ItemCapExceeded;
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
        const next_bytes = std.math.add(usize, ledger.residentBytes(), total_bytes) catch
            return error.ByteCapExceeded;
        if (next_bytes > max_bytes) return error.ByteCapExceeded;

        out.* = .{
            .allocator = allocator,
            .sealed_allocator = allocator,
            .entries = entries,
            .cleanup_entries = entries,
            .entries_addr = if (entries.len == 0) 0 else @intFromPtr(entries.ptr),
            .entries_len = entries.len,
            .allocator_ptr_addr = @intFromPtr(allocator.ptr),
            .allocator_vtable_addr = @intFromPtr(allocator.vtable),
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
        if (self.isCommitted()) return;
        const entries = self.canonicalCleanupEntries() orelse return;
        const allocator = self.canonicalCleanupAllocator() orelse return;
        allocator.free(entries);
        self.entries = &.{};
        self.cleanup_entries = &.{};
        self.entries_addr = 0;
        self.entries_len = 0;
        self.lifecycle = .aborted;
    }

    /// Exact heap backing needed for `count` entries, without exposing `PlannedSeed`.
    pub fn plannedMetadataBytes(count: usize) error{ArithmeticOverflow}!usize {
        return std.math.mul(usize, count, @sizeOf(PlannedSeed)) catch
            return error.ArithmeticOverflow;
    }

    /// True only for the ownership-free default state accepted by an outer discard plan.
    pub fn isCanonicalEmpty(self: *const PreparedSeedPlan) bool {
        return self.entries.len == 0 and
            self.cleanup_entries.len == 0 and
            self.entries_addr == 0 and
            self.entries_len == 0 and
            self.saved_self_addr == 0 and
            self.ledger_addr == 0 and
            self.payload_wrappers_addr == 0 and
            self.expected_mutation_epoch == 0 and
            self.expected_next_generation == 0 and
            !self.expected_generation_exhausted and
            self.expected_next_slot_hint == 0 and
            self.total_bytes == 0 and
            self.lifecycle == .empty;
    }

    pub fn isCommitted(self: *const PreparedSeedPlan) bool {
        return self.lifecycle == .committed and
            self.entries.len == 0 and
            self.cleanup_entries.len == 0 and
            self.entries_addr == 0 and
            self.entries_len == 0;
    }

    /// Read-only validation of the stable ledger and payload-wrapper inventory captured at prepare.
    pub fn validateBinding(
        self: *const PreparedSeedPlan,
        ledger: *const ExternalInboxLedger,
        payload_wrappers: []const OwnedPayload,
        count: usize,
    ) bool {
        if (!self.isStablePrepared() or self.ledger_addr != @intFromPtr(ledger))
            return false;
        if (self.entries.len != count or payload_wrappers.len != count) return false;
        const wrappers_addr = if (payload_wrappers.len == 0)
            0
        else
            @intFromPtr(payload_wrappers.ptr);
        if (self.payload_wrappers_addr != wrappers_addr) return false;
        for (self.entries, payload_wrappers) |entry, payload|
            if (!std.meta.eql(entry.payload, fingerprint(payload))) return false;
        return true;
    }

    fn finishCommitDeferred(
        self: *PreparedSeedPlan,
        retirement: *PreparedSeedRetirement,
    ) void {
        std.debug.assert(self.hasSealedEntries());
        std.debug.assert(retirement.isEmpty());
        const entries = self.canonicalCleanupEntries() orelse unreachable;
        const allocator = self.canonicalCleanupAllocator() orelse unreachable;
        self.entries = &.{};
        self.cleanup_entries = &.{};
        self.entries_addr = 0;
        self.entries_len = 0;
        self.lifecycle = .committed;
        retirement.* = .{
            .saved_self_addr = @intFromPtr(retirement),
            .allocator = allocator,
            .entries = entries,
            .lifecycle = .prepared,
        };
    }

    fn isStablePrepared(self: *const PreparedSeedPlan) bool {
        return self.lifecycle == .prepared and
            self.saved_self_addr == @intFromPtr(self) and
            self.hasSealedEntries();
    }

    fn hasSealedEntries(self: *const PreparedSeedPlan) bool {
        const address = if (self.entries.len == 0) 0 else @intFromPtr(self.entries.ptr);
        return std.meta.eql(self.allocator, self.sealed_allocator) and
            self.entries_addr == address and
            self.entries_len == self.entries.len and
            sameSlice(PlannedSeed, self.entries, self.cleanup_entries) and
            self.canonicalCleanupAllocator() != null;
    }

    fn canonicalCleanupEntries(self: *const PreparedSeedPlan) ?[]PlannedSeed {
        if (sameSlice(PlannedSeed, self.entries, self.cleanup_entries))
            return self.entries;
        if (sliceAddress(PlannedSeed, self.entries) == self.entries_addr and
            self.entries.len == self.entries_len)
            return self.entries;
        if (sliceAddress(PlannedSeed, self.cleanup_entries) == self.entries_addr and
            self.cleanup_entries.len == self.entries_len)
            return self.cleanup_entries;
        return null;
    }

    fn canonicalCleanupAllocator(self: *const PreparedSeedPlan) ?std.mem.Allocator {
        if (std.meta.eql(self.allocator, self.sealed_allocator))
            return self.allocator;
        if (allocatorMatchesSeal(
            self.allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        )) return self.allocator;
        if (allocatorMatchesSeal(
            self.sealed_allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        )) return self.sealed_allocator;
        return null;
    }
};

pub const max_live_mutations: usize = 64;
pub const max_live_cleanup_owners: usize = max_live_mutations * 2;

pub const LiveTokenRef = union(enum) {
    existing: Token,
    planned: u8,
};

const LiveMutationLifecycle = enum {
    empty,
    prepared,
    committed,
    aborted,
};

const PreparedLiveAdmission = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    batch_addr: usize = 0,
    semantic: PayloadSemantic = .{ .lease = .{
        .stream_id = 0,
        .is_snapshot = false,
    } },
    owned_payload: OwnedPayload = .{ .allocator = std.heap.page_allocator },
    payload_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
    reserved_token: ?Token = null,
    lifecycle: LiveMutationLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedLiveMergeSource = union(enum) {
    owned: OwnedPayload,
    existing: LiveTokenRef,
};

pub const PreparedLiveReplacement = union(enum) {
    coalesced,
    prebuilt: OwnedPayload,
};

const PreparedLiveMerge = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    batch_addr: usize = 0,
    destination: LiveTokenRef = .{ .planned = 0 },
    expected_destination_generation: u64 = 0,
    next_semantic: PayloadSemantic = .{ .lease = .{
        .stream_id = 0,
        .is_snapshot = false,
    } },
    source: PreparedLiveMergeSource = .{ .owned = .{
        .allocator = std.heap.page_allocator,
    } },
    source_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
    incoming_range: ?external_rx_types.RxRange = null,
    expected_source_digest: owner_seal.Digest = [_]u8{0} ** 32,
    replacement: PreparedLiveReplacement = .coalesced,
    replacement_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
    coalesced_replacement_index: ?u8 = null,
    expected_accounting_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_destination_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_destination_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
    result_token: ?Token = null,
    lifecycle: LiveMutationLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

const PreparedLiveRelease = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    batch_addr: usize = 0,
    token: LiveTokenRef = .{ .planned = 0 },
    expected_phase: PayloadPhase = .frame,
    expected_token_generation: u64 = 0,
    expected_accounting_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_token_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_token_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
    lifecycle: LiveMutationLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const FinalLiveRoot = struct {
    token: Token,
    phase: enum { partial, completed },
};

pub const LiveCommitDisposition = union(enum) {
    unused,
    final_live: FinalLiveRoot,
    /// The payload receives a real ledger token/generation during the atomic commit, but is
    /// moved directly into the prepared retirement owner instead of becoming externally live.
    /// This is deliberately domain-neutral: recovery policy lives in the pump, while the ledger
    /// remains the sole authority for whether a committed root is publishable or retired.
    cleanup_final: FinalLiveRoot,
    superseded_tombstone,
};

pub const CommittedLiveOutputLifecycle = enum(u8) {
    empty,
    committed,
    claimed,
    consumed_tombstone,
};

pub const CommittedLiveOutputEntry = struct {
    token: Token = .{ .slot = 0, .generation = 0 },
    phase: PayloadPhase = .frame,
    semantic: PayloadSemantic = .{ .lease = .{
        .stream_id = 0,
        .is_snapshot = false,
    } },
    semantic_digest: owner_seal.Digest = [_]u8{0} ** 32,
    cleanup_only: bool = false,
};

/// Immutable evidence initialized only after the corresponding live commit has mutated the ledger.
/// Callers may seal this output into a higher-level transaction but cannot use it to mutate slots.
pub const CommittedLiveOutput = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    permit_addr: usize = 0,
    permit_digest: owner_seal.Digest = [_]u8{0} ** 32,
    mutation_epoch: u64 = 0,
    authority_digest: owner_seal.Digest = [_]u8{0} ** 32,
    count: u8 = 0,
    entries: [max_live_mutations]CommittedLiveOutputEntry =
        [_]CommittedLiveOutputEntry{.{}} ** max_live_mutations,
    lifecycle: CommittedLiveOutputLifecycle = .empty,
    claim_owner_addr: usize = 0,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

const FrozenPayloadCleanup = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    addr: usize = 0,
    len: usize = 0,
    content_digest: owner_seal.Digest = [_]u8{0} ** 32,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

const FrozenPayloadRange = struct {
    addr: usize = 0,
    len: usize = 0,
};

const LiveRetirementLifecycle = enum {
    empty,
    prepared,
    retired,
    quarantined,
};

pub const RetireLiveResult = enum {
    retired,
    already_retired,
    quarantined,
};

pub const PreparedLiveRetirement = struct {
    saved_self_addr: usize = 0,
    cleanup_owners: [max_live_cleanup_owners]OwnedPayload =
        [_]OwnedPayload{.{ .allocator = std.heap.page_allocator }} **
        max_live_cleanup_owners,
    cleanup_plans: [max_live_cleanup_owners]FrozenPayloadCleanup =
        [_]FrozenPayloadCleanup{.{}} ** max_live_cleanup_owners,
    cleanup_count: u8 = 0,
    cleanup_bytes: usize = 0,
    published_replacements: [max_live_mutations]FrozenPayloadRange =
        [_]FrozenPayloadRange{.{}} ** max_live_mutations,
    replacement_count: u8 = 0,
    replacement_bytes: usize = 0,
    lifecycle: LiveRetirementLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,

    pub fn init(allocator: std.mem.Allocator) PreparedLiveRetirement {
        _ = allocator;
        return .{};
    }

    pub fn retire(self: *PreparedLiveRetirement) RetireLiveResult {
        return retireLivePayloads(self);
    }
};

const LiveBatchAbortLifecycle = enum {
    empty,
    prepared,
    committed,
    spent,
};

pub const FrozenLiveBatchAbort = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    batch_addr: usize = 0,
    cleanup: [max_live_cleanup_owners]owner_cleanup.FrozenOwnerCleanupDescriptor =
        [_]owner_cleanup.FrozenOwnerCleanupDescriptor{.{}} **
        max_live_cleanup_owners,
    cleanup_count: u8 = 0,
    cleanup_bytes: usize = 0,
    lifecycle: LiveBatchAbortLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedLiveMutation = union(enum) {
    empty,
    admission: PreparedLiveAdmission,
    merge: PreparedLiveMerge,
    release: PreparedLiveRelease,
    committed,
    aborted,
};

const PreparedLiveBatchLifecycle = enum {
    empty,
    preparing,
    prepared,
    committed,
    aborted,
};

const PreparedLiveCommitLifecycle = enum {
    empty,
    prepared,
    consumed,
    aborted,
};

pub const PreparedLiveBatch = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    sealed_allocator: std.mem.Allocator = std.heap.page_allocator,
    expected_mutation_epoch: u64 = 0,
    expected_accounting_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_external_identity: ?external_rx_types.RxIdentity = null,
    cleanup_only: bool = false,
    mutations: [max_live_mutations]PreparedLiveMutation =
        [_]PreparedLiveMutation{.empty} ** max_live_mutations,
    mutation_count: u8 = 0,
    coalesced_replacements: [max_live_mutations]OwnedPayload =
        [_]OwnedPayload{.{ .allocator = std.heap.page_allocator }} **
        max_live_mutations,
    coalesced_replacement_fingerprints: [max_live_mutations]PayloadFingerprint =
        [_]PayloadFingerprint{.{
            .allocator = std.heap.page_allocator,
            .address = 0,
            .logical_len = 0,
        }} ** max_live_mutations,
    replacement_count: u8 = 0,
    replacement_bytes: usize = 0,
    accepted_source_bytes: usize = 0,
    working_simulation: LiveSimulation = .{},
    working_simulation_digest: owner_seal.Digest = [_]u8{0} ** 32,
    progress_digest: owner_seal.Digest = [_]u8{0} ** 32,
    expected_next_generation: u64 = 0,
    expected_generation_exhausted: bool = false,
    expected_next_slot_hint: usize = 0,
    expected_charged_bytes: usize = 0,
    expected_charged_items: usize = 0,
    lifecycle: PreparedLiveBatchLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedLiveCommit = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    batch_addr: usize = 0,
    retirement_addr: usize = 0,
    dispositions_addr: usize = 0,
    aggregate_addr: usize = 0,
    storage_addr: usize = 0,
    turn_generation: u64 = 0,
    mutation_count: u8 = 0,
    final_partial_count: u8 = 0,
    final_completed_count: u8 = 0,
    cleanup_final_count: u8 = 0,
    cleanup_final_bytes: usize = 0,
    /// Conservative cleanup capacity reserved by the simulation plus direct-final cleanup.
    /// Actual owner accounting remains solely published by `PreparedLiveRetirement`.
    reserved_cleanup_count: usize = 0,
    reserved_cleanup_bytes: usize = 0,
    expected_cleanup_count: usize = 0,
    expected_cleanup_bytes: usize = 0,
    simulation: LiveSimulation = .{},
    simulation_digest: owner_seal.Digest = [_]u8{0} ** 32,
    dispositions_digest: owner_seal.Digest = [_]u8{0} ** 32,
    retirement_digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLiveCommitLifecycle = .empty,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

/// A non-owning value projection for a future final-address live commit.
///
/// The embedded token and payload descriptors are evidence only: planning never moves a
/// payload, reserves a token, or changes the source batch/retirement/permit. The caller may
/// publish these bytes only at the two final addresses sealed into `permit`.
pub const ProjectedLiveCommitCandidate = struct {
    dispositions: [max_live_mutations]LiveCommitDisposition,
    permit: PreparedLiveCommit,
};

/// Stack scratch budgets keep the bounded batch protocol reviewable as its sealed state grows.
pub const max_live_batch_scratch_bytes: usize = 128 * 1024;
pub const max_live_commit_scratch_bytes: usize = 192 * 1024;
pub const max_live_commit_permit_bytes: usize = 64 * 1024;
pub const max_live_aggregate_scratch_bytes: usize = 256 * 1024;
pub const max_live_commit_local_bytes: usize = 64 * 1024;

comptime {
    if (@sizeOf(PreparedLiveBatch) > max_live_batch_scratch_bytes)
        @compileError("prepared live batch exceeded its stack scratch budget");
    if (@sizeOf(PreparedLiveBatch) +
        @sizeOf(PreparedLiveRetirement) +
        @sizeOf([max_live_mutations]LiveCommitDisposition) >
        max_live_commit_scratch_bytes)
        @compileError("aggregate live commit exceeded its stack scratch budget");
    if (@sizeOf(PreparedLiveCommit) > max_live_commit_permit_bytes)
        @compileError("prepared live commit permit exceeded its heap scratch budget");
    if (@sizeOf(PreparedLiveBatch) +
        @sizeOf(PreparedLiveRetirement) +
        @sizeOf([max_live_mutations]LiveCommitDisposition) +
        @sizeOf(PreparedLiveCommit) >
        max_live_aggregate_scratch_bytes)
        @compileError("aggregate live commit state exceeded its heap scratch budget");
    if (@sizeOf(LiveSimulation) > max_live_commit_local_bytes)
        @compileError("live commit simulation exceeded its stack-local budget");
    if (@sizeOf(FrozenLiveBatchAbort) > max_live_commit_local_bytes)
        @compileError("frozen live batch abort exceeded its stack-local budget");
}

pub const PrepareLiveError = std.mem.Allocator.Error || error{
    ArithmeticOverflow,
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidPlan,
    InvalidSemantic,
    InvalidTransition,
    InvariantFailure,
    PlanningDisabled,
    StalePlan,
    Drained,
    TeardownActive,
};

pub const CommitLiveError = error{
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
    EpochExhausted,
    InvalidAlias,
    InvalidPayload,
    InvalidPlan,
    InvalidSemantic,
    InvalidTransition,
    InvariantFailure,
    PlanningDisabled,
    StalePlan,
    Drained,
    TeardownActive,
};

pub const AbortLiveResult = enum {
    aborted,
    ignored_untrusted,
    quarantined,
};

pub const AbortLiveCommitResult = enum {
    aborted,
    ignored_untrusted,
};

fn frozenCleanupDigest(plan: FrozenPayloadCleanup) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULFC1");
    writer.writeUsize(@intFromPtr(plan.allocator.ptr));
    writer.writeUsize(@intFromPtr(plan.allocator.vtable));
    writer.writeUsize(plan.addr);
    writer.writeUsize(plan.len);
    writer.writeBytes(&plan.content_digest);
    return writer.finish();
}

fn liveRetirementDigest(
    retirement: *const PreparedLiveRetirement,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULRT1");
    writer.writeUsize(@intFromPtr(retirement));
    writer.writeU8(retirement.cleanup_count);
    writer.writeUsize(retirement.cleanup_bytes);
    writer.writeU8(retirement.replacement_count);
    writer.writeUsize(retirement.replacement_bytes);
    writer.writeU8(@intFromEnum(retirement.lifecycle));
    for (retirement.cleanup_plans[0..retirement.cleanup_count]) |plan| {
        writer.writeUsize(@intFromPtr(plan.allocator.ptr));
        writer.writeUsize(@intFromPtr(plan.allocator.vtable));
        writer.writeUsize(plan.addr);
        writer.writeUsize(plan.len);
        writer.writeBytes(&plan.digest);
    }
    for (retirement.published_replacements[0..retirement.replacement_count]) |range| {
        writer.writeUsize(range.addr);
        writer.writeUsize(range.len);
    }
    return writer.finish();
}

fn quarantineRetirement(
    retirement: *PreparedLiveRetirement,
) RetireLiveResult {
    retirement.* = .{ .lifecycle = .quarantined };
    return .quarantined;
}

fn isCanonicalEmptyLiveRetirement(
    retirement: *const PreparedLiveRetirement,
) bool {
    if (retirement.saved_self_addr != 0 or
        retirement.cleanup_count != 0 or retirement.cleanup_bytes != 0 or
        retirement.replacement_count != 0 or retirement.replacement_bytes != 0 or
        retirement.lifecycle != .empty or
        !std.mem.eql(
            u8,
            &retirement.digest,
            &([_]u8{0} ** 32),
        ))
        return false;
    for (retirement.cleanup_owners) |owner| {
        if (owner.allocation_ptr != null or owner.logical_len != 0) return false;
    }
    for (retirement.cleanup_plans) |plan| {
        if (plan.addr != 0 or plan.len != 0 or
            !std.mem.eql(u8, &plan.content_digest, &([_]u8{0} ** 32)) or
            !std.mem.eql(u8, &plan.digest, &([_]u8{0} ** 32)))
            return false;
    }
    for (retirement.published_replacements) |range|
        if (range.addr != 0 or range.len != 0) return false;
    return true;
}

fn retireLivePayloads(
    retirement: *PreparedLiveRetirement,
) RetireLiveResult {
    if (retirement.lifecycle == .retired) return .already_retired;
    if (retirement.saved_self_addr != @intFromPtr(retirement) or
        retirement.lifecycle != .prepared or
        retirement.cleanup_count > max_live_cleanup_owners or
        retirement.replacement_count > max_live_mutations)
        return quarantineRetirement(retirement);
    if (!std.mem.eql(
        u8,
        &retirement.digest,
        &liveRetirementDigest(retirement),
    )) return quarantineRetirement(retirement);
    var observed_bytes: usize = 0;
    for (retirement.cleanup_owners[0..retirement.cleanup_count], 0..) |owner, index| {
        const plan = retirement.cleanup_plans[index];
        if (!fingerprintMatches(.{
            .allocator = plan.allocator,
            .address = plan.addr,
            .logical_len = plan.len,
            .content_digest = plan.content_digest,
        }, owner) or !std.mem.eql(
            u8,
            &plan.digest,
            &frozenCleanupDigest(plan),
        )) return quarantineRetirement(retirement);
        observed_bytes = std.math.add(usize, observed_bytes, plan.len) catch
            return quarantineRetirement(retirement);
        const range = rangeOfPayload(&owner);
        for (retirement.cleanup_owners[0..index]) |prior|
            if (rangesOverlap(range, rangeOfPayload(&prior)))
                return quarantineRetirement(retirement);
        for (retirement.published_replacements[0..retirement.replacement_count]) |published| {
            const published_range = ByteRange{
                .start = published.addr,
                .end = std.math.add(usize, published.addr, published.len) catch
                    return quarantineRetirement(retirement),
            };
            if (rangesOverlap(range, published_range))
                return quarantineRetirement(retirement);
        }
    }
    if (observed_bytes != retirement.cleanup_bytes)
        return quarantineRetirement(retirement);
    var local = retirement.cleanup_owners;
    const count = retirement.cleanup_count;
    retirement.* = .{ .lifecycle = .retired };
    for (local[0..count]) |*payload| payload.deinit();
    return .retired;
}

fn sliceAddress(comptime T: type, slice: []const T) usize {
    return if (slice.len == 0) 0 else @intFromPtr(slice.ptr);
}

fn sameSlice(comptime T: type, a: []const T, b: []const T) bool {
    return a.len == b.len and sliceAddress(T, a) == sliceAddress(T, b);
}

fn allocatorMatchesSeal(
    allocator: std.mem.Allocator,
    ptr_addr: usize,
    vtable_addr: usize,
) bool {
    return @intFromPtr(allocator.ptr) == ptr_addr and
        @intFromPtr(allocator.vtable) == vtable_addr;
}

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
    TeardownActive,
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
    TeardownActive,
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
    TeardownActive,
};

pub const InvariantError = error{ InvariantFailure, Drained, TeardownActive };
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
    TeardownActive,
};
pub const FinishError = error{ ActiveCharges, InvariantFailure, TeardownActive };
pub const DrainError = error{TeardownActive};

pub const DrainReport = struct {
    drained_active_count: usize,
    drained_bytes: usize,
    had_sticky_invariant: bool,
};

pub const OwnerTeardownError = error{
    InvalidPermit,
    StalePermit,
    WrongLedger,
    AlreadyFinished,
    InvariantFailure,
};

const OwnerTeardownPermitLifecycle = enum {
    empty,
    prepared,
    consumed,
    finished,
};

pub const OwnerTeardownPermit = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    owner_teardown_generation: u64 = 0,
    lifecycle: OwnerTeardownPermitLifecycle = .empty,

    fn isPreparedFor(
        self: *const OwnerTeardownPermit,
        ledger: *const ExternalInboxLedger,
    ) bool {
        return self.saved_self_addr == @intFromPtr(self) and
            self.ledger_addr == @intFromPtr(ledger) and
            self.owner_teardown_generation != 0 and
            self.lifecycle == .prepared;
    }
};

const ScreenTokenDisposition = enum {
    unused,
    retained,
    released,
};

/// Callback-free, final-address token classification produced by the committed screen owner.
pub const FrozenScreenTokenPlan = struct {
    saved_self_addr: usize = 0,
    tokens: [max_items]Token = [_]Token{.{ .slot = 0, .generation = 0 }} ** max_items,
    dispositions: [max_items]ScreenTokenDisposition =
        [_]ScreenTokenDisposition{.unused} ** max_items,
    len: usize = 0,

    pub fn initInPlace(
        out: *FrozenScreenTokenPlan,
        tokens: []const Token,
        released: std.StaticBitSet(max_items),
    ) OwnerTeardownError!void {
        if (rangesOverlap(rangeOfValue(out), rangeOfSlice(Token, tokens)))
            return error.InvalidPermit;
        if (out.saved_self_addr != 0 or out.len != 0 or tokens.len > max_items)
            return error.InvalidPermit;
        var staged: FrozenScreenTokenPlan = .{
            .saved_self_addr = @intFromPtr(out),
            .len = tokens.len,
        };
        for (tokens, 0..) |token, index| {
            if (@as(usize, token.slot) >= max_items or token.generation == 0)
                return error.InvariantFailure;
            for (tokens[0..index]) |earlier|
                if (earlier.slot == token.slot) return error.InvariantFailure;
            staged.tokens[index] = token;
            staged.dispositions[index] = if (released.isSet(index))
                .released
            else
                .retained;
        }
        for (tokens.len..max_items) |index|
            if (released.isSet(index)) return error.InvariantFailure;
        out.* = staged;
    }

    /// Extends the already validated owner inventory without allocating or touching the ledger.
    /// Teardown aggregates use this to combine committed-screen and live-owner token authorities
    /// before the ledger performs its single all-owner freeze.
    pub fn appendRetainedTokens(
        self: *FrozenScreenTokenPlan,
        tokens: []const Token,
    ) OwnerTeardownError!void {
        if (!self.isValid()) return error.InvalidPermit;
        const next_len = std.math.add(usize, self.len, tokens.len) catch
            return error.InvariantFailure;
        if (next_len > max_items) return error.InvariantFailure;
        for (tokens, 0..) |token, index| {
            if (@as(usize, token.slot) >= max_items or token.generation == 0)
                return error.InvariantFailure;
            for (self.tokens[0..self.len]) |existing|
                if (existing.slot == token.slot) return error.InvariantFailure;
            for (tokens[0..index]) |earlier|
                if (earlier.slot == token.slot) return error.InvariantFailure;
        }
        for (tokens, self.len..) |token, index| {
            self.tokens[index] = token;
            self.dispositions[index] = .retained;
        }
        self.len = next_len;
    }

    fn isValid(self: *const FrozenScreenTokenPlan) bool {
        if (self.saved_self_addr != @intFromPtr(self) or self.len > max_items)
            return false;
        for (0..self.len) |index| {
            const token = self.tokens[index];
            if (@as(usize, token.slot) >= max_items or token.generation == 0 or
                self.dispositions[index] == .unused)
                return false;
            for (self.tokens[0..index]) |earlier|
                if (earlier.slot == token.slot) return false;
        }
        for (self.dispositions[self.len..]) |disposition|
            if (disposition != .unused) return false;
        return true;
    }
};

const PreparedLedgerTeardownLifecycle = enum {
    empty,
    prepared,
    consumed,
};

pub const PreparedLedgerTeardown = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    permit_addr: usize = 0,
    screen_plan_addr: usize = 0,
    cleanup_addr: usize = 0,
    expected_mutation_epoch: u64 = 0,
    expected_charged_items: usize = 0,
    expected_charged_bytes: usize = 0,
    expected_retired_items: usize = 0,
    expected_retired_bytes: usize = 0,
    terminal_external_identity_seal: LedgerExternalIdentitySeal = .{},
    summary: LedgerTeardownSummary = .{},
    lifecycle: PreparedLedgerTeardownLifecycle = .empty,
};

const FrozenLedgerCleanupLifecycle = enum {
    empty,
    frozen,
    cleaned_tombstone,
};

pub const FrozenLedgerCleanupFinishResult = enum {
    cleaned,
    already_cleaned,
    invalid,
};

pub const FrozenLedgerCleanup = struct {
    saved_self_addr: usize = 0,
    payloads: [max_items]OwnedPayload =
        [_]OwnedPayload{.{ .allocator = std.heap.page_allocator }} ** max_items,
    count: usize = 0,
    lifecycle: FrozenLedgerCleanupLifecycle = .empty,

    pub fn finishCallbackHidden(
        self: *FrozenLedgerCleanup,
    ) FrozenLedgerCleanupFinishResult {
        const address = @intFromPtr(self);
        if (self.lifecycle == .cleaned_tombstone) return .already_cleaned;
        if (self.saved_self_addr != address or
            self.lifecycle != .frozen or self.count > max_items)
            return .invalid;
        if (!frozen_cleanup_guard.enter()) return .invalid;
        defer frozen_cleanup_guard.leave();
        defer self.* = .{ .lifecycle = .cleaned_tombstone };
        var local = self.*;
        self.* = .{ .lifecycle = .cleaned_tombstone };
        for (local.payloads[0..local.count]) |*payload| payload.deinit();
        return .cleaned;
    }
};

pub const LedgerTeardownSummary = struct {
    had_invariant: bool = false,
    orphan_count: usize = 0,
};

const PreparedScreenRetirementLifecycle = enum {
    empty,
    prepared,
    consumed,
};

pub const PreparedScreenRetirement = struct {
    saved_self_addr: usize = 0,
    ledger_addr: usize = 0,
    token: Token = .{ .slot = 0, .generation = 0 },
    expected_phase: PayloadPhase = .frame,
    expected_mutation_epoch: u64 = 0,
    expected_charged_bytes: usize = 0,
    expected_retired_bytes: usize = 0,
    lifecycle: PreparedScreenRetirementLifecycle = .empty,
};

pub const ScreenRetirementError = error{
    InvalidRetirement,
    InvariantFailure,
    StaleRetirement,
    TeardownActive,
    Drained,
};

/// Immutable projection for outer transaction seals. Slot storage remains private; callers can
/// prove a fresh target and exact aggregate accounting without gaining a second mutation path.
pub const AccountingView = struct {
    charged_bytes: usize,
    charged_items: usize,
    retired_bytes: usize,
    retired_items: usize,
    mutation_epoch: u64,
    next_generation: u64,
    next_slot_hint: usize,
    generation_exhausted: bool,
    planning_disabled: bool,
    invariant_failed: bool,
    draining_or_drained: bool,
    valid: bool,
    pristine_zero: bool,
};

const Slot = struct {
    active: bool = false,
    retired: bool = false,
    generation: u64 = 0,
    semantic: StoredPayloadSemantic = inactiveSemantic(),
    payload: OwnedPayload = .{ .allocator = std.heap.page_allocator },
};

const StoredRecoveryTag = enum(u2) {
    none,
    host,
    client,
};

const StoredBatchSemantic = struct {
    stream_id: u64,
    provenance_start_absolute: u64,
    recovery_epoch: u64,
    provenance_span: u32,
    chunk_count: u8,
    is_snapshot: bool,
    provenance_external: bool,
    recovery_tag: StoredRecoveryTag,
};

const StoredPayloadSemantic = union(PayloadPhase) {
    frame: protocol.Header,
    partial: StoredBatchSemantic,
    completed: StoredBatchSemantic,
    lease: StoredBatchSemantic,
};

comptime {
    if (@sizeOf(StoredPayloadSemantic) > 64)
        @compileError("stored external inbox semantic exceeded the 64-byte slot budget");
}

fn inactiveSemantic() StoredPayloadSemantic {
    return .{ .lease = .{
        .stream_id = 0,
        .provenance_start_absolute = 0,
        .recovery_epoch = 0,
        .provenance_span = 0,
        .chunk_count = 0,
        .is_snapshot = false,
        .provenance_external = false,
        .recovery_tag = .none,
    } };
}

const LiveVirtualNode = struct {
    live: bool = false,
    token: Token = .{ .slot = 0, .generation = 0 },
    semantic: PayloadSemantic = .{ .lease = .{
        .stream_id = 0,
        .is_snapshot = false,
    } },
    logical_len: usize = 0,
    payload_fingerprint: PayloadFingerprint = .{
        .allocator = std.heap.page_allocator,
        .address = 0,
        .logical_len = 0,
    },
};

const LiveSimulation = struct {
    nodes: [max_live_mutations]LiveVirtualNode =
        [_]LiveVirtualNode{.{}} ** max_live_mutations,
    charged_bytes: usize = 0,
    charged_items: usize = 0,
    next_generation: u64 = 1,
    generation_exhausted: bool = false,
    next_slot_hint: usize = 0,
    accepted_source_bytes: usize = 0,
    cleanup_count: usize = 0,
    cleanup_bytes: usize = 0,
    cleared_slots: std.StaticBitSet(max_items) =
        std.StaticBitSet(max_items).initEmpty(),
    occupied_slots: std.StaticBitSet(max_items) =
        std.StaticBitSet(max_items).initEmpty(),
};

fn pureSlot(
    ledger: *const ExternalInboxLedger,
    token: Token,
) error{InvariantFailure}!struct {
    semantic: PayloadSemantic,
    logical_len: usize,
    payload_fingerprint: PayloadFingerprint,
} {
    if (@as(usize, token.slot) >= max_items) return error.InvariantFailure;
    const slot = &ledger.slots[token.slot];
    if (!slot.active or slot.generation != token.generation)
        return error.InvariantFailure;
    validatePayload(&slot.payload, slot.payload.logical_len) catch
        return error.InvariantFailure;
    const semantic = loadSemantic(slot.semantic);
    validateSemantic(semantic, slot.payload.logical_len) catch
        return error.InvariantFailure;
    return .{
        .semantic = semantic,
        .logical_len = slot.payload.logical_len,
        .payload_fingerprint = fingerprint(slot.payload),
    };
}

fn resolveVirtualRef(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    simulation: *const LiveSimulation,
    before_index: usize,
    ref: LiveTokenRef,
) error{ InvalidPlan, InvariantFailure }!LiveVirtualNode {
    return switch (ref) {
        .planned => |planned| blk: {
            if (@as(usize, planned) >= before_index) return error.InvalidPlan;
            const node = simulation.nodes[planned];
            if (!node.live) return error.InvalidPlan;
            break :blk node;
        },
        .existing => |token| blk: {
            if (@as(usize, token.slot) >= max_items or
                simulation.cleared_slots.isSet(token.slot))
                return error.InvalidPlan;
            for (simulation.nodes[0..before_index]) |node| {
                if (node.token.slot != token.slot) continue;
                // Any earlier mutation of the same slot invalidates the pre-batch token,
                // including a release that left no live result.
                return error.InvalidPlan;
            }
            const inspected = try pureSlot(ledger, token);
            _ = batch;
            break :blk .{
                .live = true,
                .token = token,
                .semantic = inspected.semantic,
                .logical_len = inspected.logical_len,
                .payload_fingerprint = inspected.payload_fingerprint,
            };
        },
    };
}

fn validateVirtualRefDescriptor(
    ledger: *const ExternalInboxLedger,
    simulation: *const LiveSimulation,
    before_index: usize,
    ref: LiveTokenRef,
    expected: PayloadFingerprint,
) error{ InvalidPlan, StalePlan }!void {
    switch (ref) {
        .existing => |token| {
            if (@as(usize, token.slot) >= max_items or
                simulation.cleared_slots.isSet(token.slot))
                return error.InvalidPlan;
            const slot = &ledger.slots[token.slot];
            if (!slot.active or slot.generation != token.generation)
                return error.StalePlan;
            if (!payloadDescriptorMatches(expected, slot.payload))
                return error.StalePlan;
        },
        .planned => |planned| {
            if (@as(usize, planned) >= before_index)
                return error.InvalidPlan;
            const node = simulation.nodes[planned];
            if (!node.live or
                !std.meta.eql(node.payload_fingerprint, expected))
                return error.StalePlan;
        },
    }
}

fn virtualSlotFree(
    ledger: *const ExternalInboxLedger,
    simulation: *const LiveSimulation,
    before_index: usize,
    slot_index: usize,
) bool {
    _ = ledger;
    _ = before_index;
    return !simulation.occupied_slots.isSet(slot_index);
}

fn findVirtualFreeSlot(
    ledger: *const ExternalInboxLedger,
    simulation: *const LiveSimulation,
    before_index: usize,
    hint: usize,
) ?usize {
    for (0..max_items) |offset| {
        const index = (hint + offset) % max_items;
        if (virtualSlotFree(ledger, simulation, before_index, index)) return index;
    }
    return null;
}

fn advanceVirtualGeneration(
    next_generation: *u64,
    exhausted: *bool,
) error{GenerationExhausted}!u64 {
    return takePlannedGeneration(next_generation, exhausted);
}

fn batchSemanticForPhase(
    semantic: PayloadSemantic,
) error{InvalidSemantic}!struct {
    stream_id: u64,
    is_snapshot: bool,
    recovery_intent: RecoveryIntent,
    provenance: StoredRxBatchProvenance,
    chunk_count: u8,
} {
    return switch (semantic) {
        .partial => |value| .{
            .stream_id = value.stream_id,
            .is_snapshot = value.is_snapshot,
            .recovery_intent = value.recovery_intent,
            .provenance = value.provenance,
            .chunk_count = value.chunk_count,
        },
        .completed => |value| .{
            .stream_id = value.stream_id,
            .is_snapshot = value.is_snapshot,
            .recovery_intent = value.recovery_intent,
            .provenance = value.provenance,
            .chunk_count = 0,
        },
        else => error.InvalidSemantic,
    };
}

fn validateExternalSemanticForBatch(
    batch: *const PreparedLiveBatch,
    semantic: PayloadSemantic,
) error{InvalidSemantic}!void {
    const expected_identity = batch.expected_external_identity;
    const value = try batchSemanticForPhase(semantic);
    switch (value.provenance) {
        .untracked => if (expected_identity != null) return error.InvalidSemantic,
        .external => |range| {
            if (expected_identity == null) return error.InvalidSemantic;
            try validateCompactExternalRange(range);
        },
    }
}

fn validateContinuation(
    identity: external_rx_types.RxIdentity,
    previous: StoredRxBatchProvenance,
    next: StoredRxBatchProvenance,
    incoming: external_rx_types.RxRange,
    source_payload_len: usize,
) error{InvalidSemantic}!void {
    if (!std.meta.eql(incoming.identity, identity))
        return error.InvalidSemantic;
    const old = switch (previous) {
        .external => |value| value,
        .untracked => return error.InvalidSemantic,
    };
    const new = switch (next) {
        .external => |value| value,
        .untracked => return error.InvalidSemantic,
    };
    try validateCompactExternalRange(old);
    try validateCompactExternalRange(new);
    const old_end = std.math.add(u64, old.start_absolute, old.span) catch
        return error.InvalidSemantic;
    if (incoming.start_absolute != old_end or
        incoming.end_absolute <= incoming.start_absolute or
        new.start_absolute != old.start_absolute or new.span <= old.span)
        return error.InvalidSemantic;
    const incoming_span = std.math.add(
        usize,
        protocol.header_size,
        source_payload_len,
    ) catch return error.InvalidSemantic;
    const observed_incoming_span = std.math.sub(
        u64,
        incoming.end_absolute,
        incoming.start_absolute,
    ) catch return error.InvalidSemantic;
    if (observed_incoming_span != incoming_span)
        return error.InvalidSemantic;
    const new_span = std.math.sub(
        u64,
        incoming.end_absolute,
        old.start_absolute,
    ) catch return error.InvalidSemantic;
    if (new_span != new.span) return error.InvalidSemantic;
}

fn simulateLiveBatchFrom(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    start: usize,
    count: usize,
    initial: ?LiveSimulation,
) PrepareLiveError!LiveSimulation {
    if (start > count or count > max_live_mutations)
        return error.InvalidPlan;
    var simulation: LiveSimulation = initial orelse .{
        .charged_bytes = ledger.charged_bytes,
        .charged_items = ledger.charged_items,
        .next_generation = ledger.next_generation,
        .generation_exhausted = ledger.generation_exhausted,
        .next_slot_hint = ledger.next_slot_hint,
    };
    if (initial == null)
        for (&ledger.slots, 0..) |slot, slot_index|
            if (slot.active or slot.retired)
                simulation.occupied_slots.set(slot_index);
    for (batch.mutations[start..count], start..) |mutation, index| {
        switch (mutation) {
            .admission => |admission| {
                if (admission.saved_self_addr !=
                    @intFromPtr(&batch.mutations[index]) or
                    admission.ledger_addr != @intFromPtr(ledger) or
                    admission.batch_addr != @intFromPtr(batch) or
                    admission.lifecycle != .prepared)
                    return error.InvalidPlan;
                try validateSemantic(admission.semantic, admission.owned_payload.logical_len);
                try validateExternalSemanticForBatch(batch, admission.semantic);
                if (batch.expected_external_identity != null) {
                    const observed = try batchSemanticForPhase(admission.semantic);
                    const compact = observed.provenance.external;
                    const exact_span = std.math.add(
                        usize,
                        protocol.header_size,
                        admission.owned_payload.logical_len,
                    ) catch return error.InvalidSemantic;
                    if (compact.span != exact_span) return error.InvalidSemantic;
                }
                try validatePayload(
                    &admission.owned_payload,
                    admission.owned_payload.logical_len,
                );
                if (!fingerprintMatches(
                    admission.payload_fingerprint,
                    admission.owned_payload,
                )) return error.StalePlan;
                const slot = findVirtualFreeSlot(
                    ledger,
                    &simulation,
                    index,
                    simulation.next_slot_hint,
                ) orelse return error.ItemCapExceeded;
                const generation = try advanceVirtualGeneration(
                    &simulation.next_generation,
                    &simulation.generation_exhausted,
                );
                const token = Token{ .slot = @intCast(slot), .generation = generation };
                if (admission.reserved_token == null or
                    !std.meta.eql(admission.reserved_token.?, token))
                    return error.InvalidPlan;
                simulation.next_slot_hint = (slot + 1) % max_items;
                simulation.cleared_slots.unset(slot);
                simulation.occupied_slots.set(slot);
                simulation.charged_bytes = std.math.add(
                    usize,
                    simulation.charged_bytes,
                    admission.owned_payload.logical_len,
                ) catch return error.ByteCapExceeded;
                simulation.charged_items = std.math.add(
                    usize,
                    simulation.charged_items,
                    1,
                ) catch return error.ItemCapExceeded;
                simulation.nodes[index] = .{
                    .live = true,
                    .token = token,
                    .semantic = admission.semantic,
                    .logical_len = admission.owned_payload.logical_len,
                    .payload_fingerprint = admission.payload_fingerprint,
                };
            },
            .merge => |merge| {
                if (merge.saved_self_addr !=
                    @intFromPtr(&batch.mutations[index]) or
                    merge.ledger_addr != @intFromPtr(ledger) or
                    merge.batch_addr != @intFromPtr(batch) or
                    merge.lifecycle != .prepared)
                    return error.InvalidPlan;
                try validateVirtualRefDescriptor(
                    ledger,
                    &simulation,
                    index,
                    merge.destination,
                    merge.expected_destination_fingerprint,
                );
                const destination = try resolveVirtualRef(
                    ledger,
                    batch,
                    &simulation,
                    index,
                    merge.destination,
                );
                if (!std.mem.eql(
                    u8,
                    &merge.expected_destination_digest,
                    &liveNodeDigest(destination),
                )) return error.StalePlan;
                if (std.meta.activeTag(destination.semantic) != .partial)
                    return error.InvalidTransition;
                const destination_batch = destination.semantic.partial;
                const source_len: usize = switch (merge.source) {
                    .owned => |source| blk: {
                        try validatePayload(&source, source.logical_len);
                        if (!fingerprintMatches(merge.source_fingerprint, source))
                            return error.StalePlan;
                        simulation.accepted_source_bytes = std.math.add(
                            usize,
                            simulation.accepted_source_bytes,
                            source.logical_len,
                        ) catch return error.ArithmeticOverflow;
                        break :blk source.logical_len;
                    },
                    .existing => |source_ref| blk: {
                        try validateVirtualRefDescriptor(
                            ledger,
                            &simulation,
                            index,
                            source_ref,
                            merge.source_fingerprint,
                        );
                        const source = try resolveVirtualRef(
                            ledger,
                            batch,
                            &simulation,
                            index,
                            source_ref,
                        );
                        if (!std.mem.eql(
                            u8,
                            &merge.expected_source_digest,
                            &liveNodeDigest(source),
                        )) return error.StalePlan;
                        if (source.token.slot == destination.token.slot or
                            std.meta.activeTag(source.semantic) != .frame)
                            return error.InvalidTransition;
                        if (rangesOverlap(
                            rangeOfPayload(&ledger.slots[destination.token.slot].payload),
                            rangeOfPayload(&ledger.slots[source.token.slot].payload),
                        )) return error.InvariantFailure;
                        const header = source.semantic.frame;
                        if (header.stream_id != destination_batch.stream_id or
                            (header.kind == .snapshot_chunk) != destination_batch.is_snapshot)
                            return error.InvalidSemantic;
                        simulation.nodes[index] = source;
                        simulation.nodes[index].live = false;
                        simulation.cleared_slots.set(source.token.slot);
                        simulation.occupied_slots.unset(source.token.slot);
                        break :blk source.logical_len;
                    },
                };
                const next_len = std.math.add(
                    usize,
                    destination.logical_len,
                    source_len,
                ) catch return error.ByteCapExceeded;
                if (next_len > max_batch_bytes) return error.ByteCapExceeded;
                try validateSemantic(merge.next_semantic, next_len);
                try validateExternalSemanticForBatch(batch, merge.next_semantic);
                const next_batch = try batchSemanticForPhase(merge.next_semantic);
                if (next_batch.stream_id != destination_batch.stream_id or
                    next_batch.is_snapshot != destination_batch.is_snapshot or
                    !std.meta.eql(
                        next_batch.recovery_intent,
                        destination_batch.recovery_intent,
                    ))
                    return error.InvalidSemantic;
                if (batch.expected_external_identity) |identity| {
                    try validateContinuation(
                        identity,
                        destination_batch.provenance,
                        next_batch.provenance,
                        merge.incoming_range orelse return error.InvalidSemantic,
                        source_len,
                    );
                } else if (merge.incoming_range != null or
                    destination_batch.provenance != .untracked or
                    next_batch.provenance != .untracked)
                    return error.InvalidSemantic;
                if (std.meta.activeTag(merge.next_semantic) == .partial) {
                    if (next_batch.chunk_count != destination_batch.chunk_count + 1 or
                        next_batch.chunk_count > max_batch_chunks)
                        return error.InvalidSemantic;
                }
                switch (merge.replacement) {
                    .coalesced => {},
                    .prebuilt => |replacement| {
                        try validatePayload(&replacement, next_len);
                        if (!fingerprintMatches(
                            merge.replacement_fingerprint,
                            replacement,
                        )) return error.StalePlan;
                    },
                }
                const generation = try advanceVirtualGeneration(
                    &simulation.next_generation,
                    &simulation.generation_exhausted,
                );
                const result = Token{
                    .slot = destination.token.slot,
                    .generation = generation,
                };
                if (merge.expected_destination_generation !=
                    destination.token.generation or merge.result_token == null or
                    !std.meta.eql(merge.result_token.?, result))
                    return error.InvalidPlan;
                for (simulation.nodes[0..index]) |*prior| {
                    if (prior.live and
                        prior.token.slot == destination.token.slot and
                        prior.token.generation == destination.token.generation)
                        prior.live = false;
                    switch (merge.source) {
                        .existing => |source_ref| {
                            const source_token = switch (source_ref) {
                                .existing => |value| value,
                                .planned => |planned| simulation.nodes[planned].token,
                            };
                            if (prior.live and std.meta.eql(prior.token, source_token))
                                prior.live = false;
                        },
                        .owned => {},
                    }
                }
                simulation.nodes[index] = .{
                    .live = true,
                    .token = result,
                    .semantic = merge.next_semantic,
                    .logical_len = next_len,
                    .payload_fingerprint = switch (merge.replacement) {
                        .prebuilt => merge.replacement_fingerprint,
                        .coalesced => destination.payload_fingerprint,
                    },
                };
                simulation.cleared_slots.unset(result.slot);
                simulation.occupied_slots.set(result.slot);
                simulation.cleanup_count = std.math.add(
                    usize,
                    simulation.cleanup_count,
                    if (merge.source == .owned) 2 else 2,
                ) catch return error.ArithmeticOverflow;
                simulation.cleanup_bytes = std.math.add(
                    usize,
                    simulation.cleanup_bytes,
                    next_len,
                ) catch return error.ArithmeticOverflow;
                switch (merge.source) {
                    .owned => {
                        simulation.charged_bytes = std.math.add(
                            usize,
                            simulation.charged_bytes,
                            source_len,
                        ) catch return error.ByteCapExceeded;
                    },
                    .existing => {
                        if (simulation.charged_items == 0)
                            return error.InvariantFailure;
                        simulation.charged_items -= 1;
                    },
                }
            },
            .release => |release| {
                if (release.saved_self_addr !=
                    @intFromPtr(&batch.mutations[index]) or
                    release.ledger_addr != @intFromPtr(ledger) or
                    release.batch_addr != @intFromPtr(batch) or
                    release.lifecycle != .prepared)
                    return error.InvalidPlan;
                try validateVirtualRefDescriptor(
                    ledger,
                    &simulation,
                    index,
                    release.token,
                    release.expected_token_fingerprint,
                );
                const target = try resolveVirtualRef(
                    ledger,
                    batch,
                    &simulation,
                    index,
                    release.token,
                );
                if (!std.mem.eql(
                    u8,
                    &release.expected_token_digest,
                    &liveNodeDigest(target),
                )) return error.StalePlan;
                if (std.meta.activeTag(target.semantic) != release.expected_phase or
                    target.token.generation != release.expected_token_generation)
                    return error.InvalidTransition;
                if (rangeOverlapsActiveExceptSlot(
                    rangeOfPayload(&ledger.slots[target.token.slot].payload),
                    ledger,
                    target.token.slot,
                )) return error.InvariantFailure;
                for (simulation.nodes[0..index]) |*prior| {
                    if (prior.live and std.meta.eql(prior.token, target.token))
                        prior.live = false;
                }
                simulation.nodes[index] = .{
                    .live = false,
                    .token = target.token,
                    .semantic = target.semantic,
                    .logical_len = target.logical_len,
                };
                if (simulation.charged_items == 0 or
                    simulation.charged_bytes < target.logical_len)
                    return error.InvariantFailure;
                simulation.charged_items -= 1;
                simulation.charged_bytes -= target.logical_len;
                simulation.next_slot_hint = target.token.slot;
                simulation.cleared_slots.set(target.token.slot);
                simulation.occupied_slots.unset(target.token.slot);
                simulation.cleanup_count += 1;
                simulation.cleanup_bytes = std.math.add(
                    usize,
                    simulation.cleanup_bytes,
                    target.logical_len,
                ) catch return error.ArithmeticOverflow;
            },
            else => return error.InvalidPlan,
        }
        if (simulation.charged_items + ledger.retired_items > max_items)
            return error.ItemCapExceeded;
        const resident = std.math.add(
            usize,
            simulation.charged_bytes,
            ledger.retired_bytes,
        ) catch return error.ByteCapExceeded;
        if (resident > max_bytes) return error.ByteCapExceeded;
    }
    if (simulation.accepted_source_bytes >
        protocol.max_binary_chunk + protocol.header_size)
        return error.ByteCapExceeded;
    if (simulation.cleanup_count > max_live_cleanup_owners)
        return error.ItemCapExceeded;
    if (simulation.cleanup_bytes >
        max_bytes + protocol.max_binary_chunk + protocol.header_size)
        return error.ByteCapExceeded;
    return simulation;
}

fn simulateLiveBatch(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    count: usize,
) PrepareLiveError!LiveSimulation {
    return simulateLiveBatchFrom(ledger, batch, 0, count, null);
}

fn writePayloadSemantic(
    writer: *owner_seal.Writer,
    semantic: PayloadSemantic,
) void {
    writer.writeU8(@intFromEnum(std.meta.activeTag(semantic)));
    switch (semantic) {
        .frame => |header| {
            const encoded = header.encode();
            writer.writeBytes(&encoded);
        },
        .partial => |value| {
            writer.writeU64(value.stream_id);
            writer.writeBool(value.is_snapshot);
            writer.writeU8(value.chunk_count);
            writeRecoveryIntent(writer, value.recovery_intent);
            writeStoredProvenance(writer, value.provenance);
        },
        .completed, .lease => |value| {
            writer.writeU64(value.stream_id);
            writer.writeBool(value.is_snapshot);
            writeRecoveryIntent(writer, value.recovery_intent);
            writeStoredProvenance(writer, value.provenance);
        },
    }
}

pub fn payloadSemanticAuthorityDigest(semantic: PayloadSemantic) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULSD1");
    writePayloadSemantic(&writer, semantic);
    return writer.finish();
}

fn committedLiveAuthorityDigest(
    ledger: *const ExternalInboxLedger,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULCA1");
    writer.writeUsize(@intFromPtr(ledger));
    writer.writeU64(ledger.mutation_epoch);
    writer.writeUsize(ledger.charged_bytes);
    writer.writeUsize(ledger.charged_items);
    writer.writeUsize(ledger.retired_bytes);
    writer.writeUsize(ledger.retired_items);
    writer.writeU64(ledger.next_generation);
    writer.writeBool(ledger.generation_exhausted);
    writer.writeUsize(ledger.next_slot_hint);
    writer.writeBytes(&ledger.external_identity_seal.digest);
    return writer.finish();
}

fn committedLiveOutputDigest(
    output: *const CommittedLiveOutput,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULCO1");
    writer.writeUsize(output.saved_self_addr);
    writer.writeUsize(output.ledger_addr);
    writer.writeUsize(output.permit_addr);
    writer.writeBytes(&output.permit_digest);
    writer.writeU64(output.mutation_epoch);
    writer.writeBytes(&output.authority_digest);
    writer.writeU8(output.count);
    for (output.entries[0..output.count]) |entry| {
        writer.writeU16(entry.token.slot);
        writer.writeU64(entry.token.generation);
        writer.writeU8(@intFromEnum(entry.phase));
        writer.writeBytes(&entry.semantic_digest);
        writer.writeBool(entry.cleanup_only);
    }
    writer.writeUsize(output.claim_owner_addr);
    writer.writeU8(@intFromEnum(output.lifecycle));
    return writer.finish();
}

pub fn claimCommittedLiveOutput(
    ledger: *const ExternalInboxLedger,
    output: *CommittedLiveOutput,
    claim_owner_addr: usize,
) bool {
    if (claim_owner_addr == 0 or !committedLiveOutputValid(ledger, output))
        return false;
    claimCommittedLiveOutputUnchecked(output, claim_owner_addr);
    return true;
}

/// No-fail suffix used only after the caller validated the pristine destination and committed
/// this exact final-address output. The subsequent claimed-output validator remains the hostile
/// tamper gate; this leaf performs no lookup or callback between ledger publication and claim.
pub fn claimCommittedLiveOutputUnchecked(
    output: *CommittedLiveOutput,
    claim_owner_addr: usize,
) void {
    output.claim_owner_addr = claim_owner_addr;
    output.lifecycle = .claimed;
    output.digest = committedLiveOutputDigest(output);
}

pub fn claimedCommittedLiveOutputValid(
    ledger: *const ExternalInboxLedger,
    output: *const CommittedLiveOutput,
    claim_owner_addr: usize,
) bool {
    if (output.lifecycle != .claimed or output.claim_owner_addr != claim_owner_addr)
        return false;
    // Validate the stable ledger/token/semantic portion directly because the final-address seal
    // intentionally belongs to `output`, not to the local comparison copy.
    if (output.saved_self_addr != @intFromPtr(output) or
        output.ledger_addr != @intFromPtr(ledger) or
        output.permit_addr == 0 or output.mutation_epoch != ledger.mutation_epoch or
        output.count > max_live_mutations or
        !std.mem.eql(u8, &output.authority_digest, &committedLiveAuthorityDigest(ledger)) or
        !std.mem.eql(u8, &output.digest, &committedLiveOutputDigest(output)))
        return false;
    for (output.entries[0..output.count]) |entry| {
        if (entry.token.generation == 0 or @as(usize, entry.token.slot) >= max_items or
            !std.mem.eql(u8, &entry.semantic_digest, &payloadSemanticAuthorityDigest(entry.semantic)))
            return false;
        const slot = &ledger.slots[entry.token.slot];
        if (slot.generation != entry.token.generation) return false;
        if (entry.cleanup_only) {
            if (slot.active or slot.retired or slot.payload.allocation_ptr != null or
                slot.payload.logical_len != 0)
                return false;
        } else if (!slot.active or slot.retired or
            !std.mem.eql(
                u8,
                &entry.semantic_digest,
                &payloadSemanticAuthorityDigest(loadSemantic(slot.semantic)),
            )) return false;
    }
    for (output.entries[output.count..]) |entry|
        if (!std.meta.eql(entry, CommittedLiveOutputEntry{})) return false;
    return true;
}

pub fn consumeClaimedCommittedLiveOutputUnchecked(output: *CommittedLiveOutput) void {
    output.lifecycle = .consumed_tombstone;
    output.digest = committedLiveOutputDigest(output);
}

pub fn committedLiveOutputValid(
    ledger: *const ExternalInboxLedger,
    output: *const CommittedLiveOutput,
) bool {
    if (output.saved_self_addr != @intFromPtr(output) or
        output.ledger_addr != @intFromPtr(ledger) or
        output.permit_addr == 0 or output.mutation_epoch != ledger.mutation_epoch or
        output.count > max_live_mutations or
        output.lifecycle != .committed or
        !std.mem.eql(u8, &output.authority_digest, &committedLiveAuthorityDigest(ledger)) or
        !std.mem.eql(u8, &output.digest, &committedLiveOutputDigest(output)))
        return false;
    for (output.entries[0..output.count]) |entry| {
        if (entry.token.generation == 0 or
            @as(usize, entry.token.slot) >= max_items or
            !std.mem.eql(u8, &entry.semantic_digest, &payloadSemanticAuthorityDigest(entry.semantic)))
            return false;
        const slot = &ledger.slots[entry.token.slot];
        if (slot.generation != entry.token.generation) return false;
        if (entry.cleanup_only) {
            if (slot.active or slot.retired or slot.payload.allocation_ptr != null or
                slot.payload.logical_len != 0)
                return false;
        } else {
            if (!slot.active or slot.retired or
                !std.mem.eql(
                    u8,
                    &entry.semantic_digest,
                    &payloadSemanticAuthorityDigest(loadSemantic(slot.semantic)),
                )) return false;
        }
    }
    for (output.entries[output.count..]) |entry|
        if (!std.meta.eql(entry, CommittedLiveOutputEntry{})) return false;
    return true;
}

fn writeTokenRef(writer: *owner_seal.Writer, ref: LiveTokenRef) void {
    switch (ref) {
        .existing => |token| {
            writer.writeU8(0);
            writer.writeU64(token.slot);
            writer.writeU64(token.generation);
        },
        .planned => |index| {
            writer.writeU8(1);
            writer.writeU8(index);
        },
    }
}

fn writePayloadFingerprint(
    writer: *owner_seal.Writer,
    value: PayloadFingerprint,
) void {
    writer.writeUsize(@intFromPtr(value.allocator.ptr));
    writer.writeUsize(@intFromPtr(value.allocator.vtable));
    writer.writeUsize(value.address);
    writer.writeUsize(value.logical_len);
    writer.writeBytes(&value.content_digest);
}

fn liveNodeDigest(node: LiveVirtualNode) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULND1");
    writer.writeBool(node.live);
    writer.writeU64(node.token.slot);
    writer.writeU64(node.token.generation);
    writePayloadSemantic(&writer, node.semantic);
    writer.writeUsize(node.logical_len);
    writePayloadFingerprint(&writer, node.payload_fingerprint);
    return writer.finish();
}

fn liveSimulationDigest(
    simulation: *const LiveSimulation,
    node_count: usize,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULSM2");
    writer.writeUsize(simulation.charged_bytes);
    writer.writeUsize(simulation.charged_items);
    writer.writeU64(simulation.next_generation);
    writer.writeBool(simulation.generation_exhausted);
    writer.writeUsize(simulation.next_slot_hint);
    writer.writeUsize(simulation.accepted_source_bytes);
    writer.writeUsize(simulation.cleanup_count);
    writer.writeUsize(simulation.cleanup_bytes);
    writer.writeUsize(node_count);
    for (simulation.nodes[0..node_count]) |node|
        writer.writeBytes(&liveNodeDigest(node));
    // 비트셋은 **뒷받침 워드째** 넣는다. 비트를 하나씩 `writeBool` 하면 Blake3 update 가 8,192번이고,
    // 이 다이제스트는 해제 1건 경로에서 8~9번 다시 계산된다(`requirePreparingLiveBatch` 마다).
    // 같은 정보(모든 비트)를 워드 128개로 넣으면 update 가 64분의 1이다. `max_items` 가 워드
    // 크기의 배수라 패딩 비트가 없다 — 배수가 아니게 바뀌면 아래 단언이 막는다.
    comptime std.debug.assert(max_items % @bitSizeOf(usize) == 0);
    for (simulation.cleared_slots.masks) |mask| writer.writeUsize(mask);
    for (simulation.occupied_slots.masks) |mask| writer.writeUsize(mask);
    return writer.finish();
}

fn liveDispositionsDigest(
    dispositions: *const [max_live_mutations]LiveCommitDisposition,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULDP1");
    for (dispositions) |disposition| {
        writer.writeU8(@intFromEnum(std.meta.activeTag(disposition)));
        switch (disposition) {
            .final_live, .cleanup_final => |root| {
                writer.writeU16(root.token.slot);
                writer.writeU64(root.token.generation);
                writer.writeU8(@intFromEnum(root.phase));
            },
            .unused, .superseded_tombstone => {},
        }
    }
    return writer.finish();
}

fn preparedLiveCommitDigest(
    permit: *const PreparedLiveCommit,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULCP1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.ledger_addr);
    writer.writeUsize(permit.batch_addr);
    writer.writeUsize(permit.retirement_addr);
    writer.writeUsize(permit.dispositions_addr);
    writer.writeUsize(permit.aggregate_addr);
    writer.writeUsize(permit.storage_addr);
    writer.writeU64(permit.turn_generation);
    writer.writeU8(permit.mutation_count);
    writer.writeU8(permit.final_partial_count);
    writer.writeU8(permit.final_completed_count);
    writer.writeU8(permit.cleanup_final_count);
    writer.writeUsize(permit.cleanup_final_bytes);
    writer.writeUsize(permit.reserved_cleanup_count);
    writer.writeUsize(permit.reserved_cleanup_bytes);
    writer.writeUsize(permit.expected_cleanup_count);
    writer.writeUsize(permit.expected_cleanup_bytes);
    writer.writeBytes(&permit.simulation_digest);
    writer.writeBytes(&permit.dispositions_digest);
    writer.writeBytes(&permit.retirement_digest);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn frozenLiveBatchAbortDigest(
    permit: *const FrozenLiveBatchAbort,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULBA1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.ledger_addr);
    writer.writeUsize(permit.batch_addr);
    writer.writeU8(permit.cleanup_count);
    writer.writeUsize(permit.cleanup_bytes);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    for (permit.cleanup[0..permit.cleanup_count]) |descriptor|
        writer.writeBytes(&descriptor.digest);
    return writer.finish();
}

fn liveAccountingDigest(
    ledger: *const ExternalInboxLedger,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULAC1");
    writer.writeUsize(@intFromPtr(ledger));
    writer.writeUsize(ledger.charged_bytes);
    writer.writeUsize(ledger.charged_items);
    writer.writeUsize(ledger.retired_bytes);
    writer.writeUsize(ledger.retired_items);
    writer.writeUsize(ledger.next_slot_hint);
    writer.writeU64(ledger.next_generation);
    writer.writeBool(ledger.generation_exhausted);
    writer.writeU64(ledger.mutation_epoch);
    writer.writeBool(ledger.planning_disabled);
    writer.writeBool(ledger.invariant_failed);
    writer.writeBool(ledger.draining_or_drained);
    writer.writeBool(ledger.teardown_active);
    writer.writeBytes(&ledger.external_identity_seal.digest);
    return writer.finish();
}

fn liveMutationDigest(
    batch: *const PreparedLiveBatch,
    index: usize,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULMU1");
    writer.writeUsize(@intFromPtr(batch));
    writer.writeUsize(index);
    switch (batch.mutations[index]) {
        .admission => |value| {
            writer.writeU8(1);
            writer.writeUsize(value.saved_self_addr);
            writer.writeUsize(value.ledger_addr);
            writer.writeUsize(value.batch_addr);
            writePayloadSemantic(&writer, value.semantic);
            writePayloadFingerprint(&writer, value.payload_fingerprint);
            if (value.reserved_token) |token| {
                writer.writeBool(true);
                writer.writeU64(token.slot);
                writer.writeU64(token.generation);
            } else writer.writeBool(false);
            writer.writeU8(@intFromEnum(value.lifecycle));
        },
        .merge => |value| {
            writer.writeU8(2);
            writer.writeUsize(value.saved_self_addr);
            writer.writeUsize(value.ledger_addr);
            writer.writeUsize(value.batch_addr);
            writeTokenRef(&writer, value.destination);
            writer.writeU64(value.expected_destination_generation);
            writePayloadSemantic(&writer, value.next_semantic);
            switch (value.source) {
                .owned => {
                    writer.writeU8(0);
                    writePayloadFingerprint(&writer, value.source_fingerprint);
                },
                .existing => |ref| {
                    writer.writeU8(1);
                    writeTokenRef(&writer, ref);
                },
            }
            if (value.incoming_range) |range| {
                writer.writeBool(true);
                writer.writeU64(range.identity.attach_instance_id);
                writer.writeUsize(range.identity.destination_slot_addr);
                writer.writeU64(range.start_absolute);
                writer.writeU64(range.end_absolute);
            } else writer.writeBool(false);
            writer.writeBytes(&value.expected_source_digest);
            switch (value.replacement) {
                .coalesced => writer.writeU8(0),
                .prebuilt => {
                    writer.writeU8(1);
                    writePayloadFingerprint(&writer, value.replacement_fingerprint);
                },
            }
            if (value.coalesced_replacement_index) |replacement_index| {
                writer.writeBool(true);
                writer.writeU8(replacement_index);
            } else writer.writeBool(false);
            writer.writeBytes(&value.expected_accounting_digest);
            writer.writeBytes(&value.expected_destination_digest);
            writePayloadFingerprint(
                &writer,
                value.expected_destination_fingerprint,
            );
            if (value.result_token) |token| {
                writer.writeBool(true);
                writer.writeU64(token.slot);
                writer.writeU64(token.generation);
            } else writer.writeBool(false);
            writer.writeU8(@intFromEnum(value.lifecycle));
        },
        .release => |value| {
            writer.writeU8(3);
            writer.writeUsize(value.saved_self_addr);
            writer.writeUsize(value.ledger_addr);
            writer.writeUsize(value.batch_addr);
            writeTokenRef(&writer, value.token);
            writer.writeU8(@intFromEnum(value.expected_phase));
            writer.writeU64(value.expected_token_generation);
            writer.writeBytes(&value.expected_accounting_digest);
            writer.writeBytes(&value.expected_token_digest);
            writePayloadFingerprint(&writer, value.expected_token_fingerprint);
            writer.writeU8(@intFromEnum(value.lifecycle));
        },
        else => writer.writeU8(0),
    }
    return writer.finish();
}

fn appendRefBytes(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    ref: LiveTokenRef,
    before_index: usize,
    output: []u8,
    cursor: *usize,
) error{ InvalidPlan, InvalidPayload, InvariantFailure }!void {
    switch (ref) {
        .existing => |token| {
            const inspected = try pureSlot(ledger, token);
            const slot = &ledger.slots[token.slot];
            const end = std.math.add(usize, cursor.*, inspected.logical_len) catch
                return error.InvalidPayload;
            if (end > output.len) return error.InvalidPayload;
            @memcpy(output[cursor.*..end], slot.payload.bytes());
            cursor.* = end;
        },
        .planned => |planned| {
            const index: usize = planned;
            if (index >= before_index) return error.InvalidPlan;
            switch (batch.mutations[index]) {
                .admission => |admission| {
                    const bytes = admission.owned_payload.bytes();
                    const end = std.math.add(usize, cursor.*, bytes.len) catch
                        return error.InvalidPayload;
                    if (end > output.len) return error.InvalidPayload;
                    @memcpy(output[cursor.*..end], bytes);
                    cursor.* = end;
                },
                .merge => |merge| {
                    try appendRefBytes(
                        ledger,
                        batch,
                        merge.destination,
                        index,
                        output,
                        cursor,
                    );
                    switch (merge.source) {
                        .owned => |source| {
                            const bytes = source.bytes();
                            const end = std.math.add(usize, cursor.*, bytes.len) catch
                                return error.InvalidPayload;
                            if (end > output.len) return error.InvalidPayload;
                            @memcpy(output[cursor.*..end], bytes);
                            cursor.* = end;
                        },
                        .existing => |source_ref| try appendRefBytes(
                            ledger,
                            batch,
                            source_ref,
                            index,
                            output,
                            cursor,
                        ),
                    }
                },
                else => return error.InvalidPlan,
            }
        },
    }
}

fn matchRefBytes(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    ref: LiveTokenRef,
    before_index: usize,
    expected: []const u8,
    cursor: *usize,
) error{ InvalidPlan, InvalidPayload, InvariantFailure }!void {
    switch (ref) {
        .existing => |token| {
            const inspected = try pureSlot(ledger, token);
            const bytes = ledger.slots[token.slot].payload.bytes();
            const end = std.math.add(usize, cursor.*, inspected.logical_len) catch
                return error.InvalidPayload;
            if (end > expected.len or
                !std.mem.eql(u8, expected[cursor.*..end], bytes))
                return error.InvalidPayload;
            cursor.* = end;
        },
        .planned => |planned| {
            const index: usize = planned;
            if (index >= before_index) return error.InvalidPlan;
            switch (batch.mutations[index]) {
                .admission => |admission| {
                    const bytes = admission.owned_payload.bytes();
                    const end = std.math.add(usize, cursor.*, bytes.len) catch
                        return error.InvalidPayload;
                    if (end > expected.len or
                        !std.mem.eql(u8, expected[cursor.*..end], bytes))
                        return error.InvalidPayload;
                    cursor.* = end;
                },
                .merge => |merge| {
                    try matchRefBytes(
                        ledger,
                        batch,
                        merge.destination,
                        index,
                        expected,
                        cursor,
                    );
                    switch (merge.source) {
                        .owned => |source| {
                            const bytes = source.bytes();
                            const end = std.math.add(usize, cursor.*, bytes.len) catch
                                return error.InvalidPayload;
                            if (end > expected.len or
                                !std.mem.eql(u8, expected[cursor.*..end], bytes))
                                return error.InvalidPayload;
                            cursor.* = end;
                        },
                        .existing => |source_ref| try matchRefBytes(
                            ledger,
                            batch,
                            source_ref,
                            index,
                            expected,
                            cursor,
                        ),
                    }
                },
                else => return error.InvalidPlan,
            }
        },
    }
}

fn batchDigest(
    batch: *const PreparedLiveBatch,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULBT1");
    writer.writeUsize(batch.saved_self_addr);
    writer.writeUsize(batch.ledger_addr);
    writer.writeUsize(@intFromPtr(batch.allocator.ptr));
    writer.writeUsize(@intFromPtr(batch.allocator.vtable));
    writer.writeUsize(@intFromPtr(batch.sealed_allocator.ptr));
    writer.writeUsize(@intFromPtr(batch.sealed_allocator.vtable));
    writer.writeU64(batch.expected_mutation_epoch);
    writer.writeBytes(&batch.expected_accounting_digest);
    if (batch.expected_external_identity) |identity| {
        writer.writeBool(true);
        writer.writeU64(identity.attach_instance_id);
        writer.writeUsize(identity.destination_slot_addr);
    } else writer.writeBool(false);
    writer.writeBool(batch.cleanup_only);
    writer.writeU8(batch.mutation_count);
    writer.writeU8(batch.replacement_count);
    writer.writeUsize(batch.replacement_bytes);
    writer.writeBytes(&batch.working_simulation_digest);
    writer.writeUsize(batch.accepted_source_bytes);
    writer.writeU64(batch.expected_next_generation);
    writer.writeBool(batch.expected_generation_exhausted);
    writer.writeUsize(batch.expected_next_slot_hint);
    writer.writeUsize(batch.expected_charged_bytes);
    writer.writeUsize(batch.expected_charged_items);
    writer.writeU8(@intFromEnum(batch.lifecycle));
    for (0..batch.mutation_count) |index|
        writer.writeBytes(&liveMutationDigest(batch, index));
    for (batch.coalesced_replacement_fingerprints[0..batch.replacement_count]) |sealed|
        writePayloadFingerprint(&writer, sealed);
    return writer.finish();
}

fn liveProgressDigest(
    batch: *const PreparedLiveBatch,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("MARULPG1");
    writer.writeUsize(@intFromPtr(batch));
    writer.writeUsize(batch.saved_self_addr);
    writer.writeUsize(batch.ledger_addr);
    writer.writeUsize(@intFromPtr(batch.allocator.ptr));
    writer.writeUsize(@intFromPtr(batch.allocator.vtable));
    writer.writeU8(batch.mutation_count);
    writer.writeU8(batch.replacement_count);
    writer.writeUsize(batch.replacement_bytes);
    writer.writeBytes(&batch.working_simulation_digest);
    for (0..batch.mutation_count) |index|
        writer.writeBytes(&liveMutationDigest(batch, index));
    for (batch.coalesced_replacement_fingerprints[0..batch.replacement_count]) |sealed|
        writePayloadFingerprint(&writer, sealed);
    return writer.finish();
}

fn mapPrepareToCommitLive(err: PrepareLiveError) CommitLiveError {
    return switch (err) {
        error.OutOfMemory => error.InvalidPlan,
        error.ArithmeticOverflow => error.InvalidPayload,
        error.ByteCapExceeded => error.ByteCapExceeded,
        error.ItemCapExceeded => error.ItemCapExceeded,
        error.GenerationExhausted => error.GenerationExhausted,
        error.EpochExhausted => error.EpochExhausted,
        error.InvalidAlias => error.InvalidAlias,
        error.InvalidPayload => error.InvalidPayload,
        error.InvalidPlan => error.InvalidPlan,
        error.InvalidSemantic => error.InvalidSemantic,
        error.InvalidTransition => error.InvalidTransition,
        error.InvariantFailure => error.InvariantFailure,
        error.PlanningDisabled => error.PlanningDisabled,
        error.StalePlan => error.StalePlan,
        error.Drained => error.Drained,
        error.TeardownActive => error.TeardownActive,
    };
}

fn mapPrepareToTransition(err: PrepareLiveError) TransitionError {
    return switch (err) {
        error.OutOfMemory, error.ArithmeticOverflow => error.InvalidPayload,
        error.ByteCapExceeded => error.InvalidPayload,
        error.ItemCapExceeded => error.InvalidTransition,
        error.GenerationExhausted => error.GenerationExhausted,
        error.EpochExhausted => error.EpochExhausted,
        error.InvalidAlias => error.InvalidAlias,
        error.InvalidPayload => error.InvalidPayload,
        error.InvalidPlan, error.StalePlan => error.InvalidTransition,
        error.InvalidSemantic => error.InvalidSemantic,
        error.InvalidTransition => error.InvalidTransition,
        error.InvariantFailure => error.InvariantFailure,
        error.PlanningDisabled => error.PlanningDisabled,
        error.Drained => error.Drained,
        error.TeardownActive => error.TeardownActive,
    };
}

fn mapCommitToTransition(err: CommitLiveError) TransitionError {
    return switch (err) {
        error.ByteCapExceeded => error.InvalidPayload,
        error.ItemCapExceeded => error.InvalidTransition,
        error.GenerationExhausted => error.GenerationExhausted,
        error.EpochExhausted => error.EpochExhausted,
        error.InvalidAlias => error.InvalidAlias,
        error.InvalidPayload => error.InvalidPayload,
        error.InvalidPlan, error.StalePlan => error.InvalidTransition,
        error.InvalidSemantic => error.InvalidSemantic,
        error.InvalidTransition => error.InvalidTransition,
        error.InvariantFailure => error.InvariantFailure,
        error.PlanningDisabled => error.PlanningDisabled,
        error.Drained => error.Drained,
        error.TeardownActive => error.TeardownActive,
    };
}

fn mapPrepareToInvariant(err: PrepareLiveError) InvariantError {
    return switch (err) {
        error.Drained => error.Drained,
        error.TeardownActive => error.TeardownActive,
        else => error.InvariantFailure,
    };
}

fn mapCommitToInvariant(err: CommitLiveError) InvariantError {
    return switch (err) {
        error.Drained => error.Drained,
        error.TeardownActive => error.TeardownActive,
        else => error.InvariantFailure,
    };
}

fn liveTokenAtCommit(
    batch: *const PreparedLiveBatch,
    ref: LiveTokenRef,
) Token {
    return switch (ref) {
        .existing => |token| token,
        .planned => |planned| switch (batch.mutations[planned]) {
            .admission => |value| value.reserved_token.?,
            .merge => |value| value.result_token.?,
            else => unreachable,
        },
    };
}

fn appendLiveRetirementUnchecked(
    retirement: *PreparedLiveRetirement,
    payload: OwnedPayload,
) void {
    const index: usize = retirement.cleanup_count;
    std.debug.assert(index < max_live_cleanup_owners);
    retirement.cleanup_owners[index] = payload;
    retirement.cleanup_plans[index] = .{
        .allocator = payload.allocator,
        .addr = if (payload.allocation_ptr) |ptr| @intFromPtr(ptr) else 0,
        .len = payload.logical_len,
        .content_digest = fingerprint(payload).content_digest,
    };
    retirement.cleanup_plans[index].digest =
        frozenCleanupDigest(retirement.cleanup_plans[index]);
    retirement.cleanup_count += 1;
    retirement.cleanup_bytes += payload.logical_len;
}

fn appendPublishedReplacementUnchecked(
    retirement: *PreparedLiveRetirement,
    payload: *const OwnedPayload,
) void {
    const index: usize = retirement.replacement_count;
    std.debug.assert(index < max_live_mutations);
    retirement.published_replacements[index] = .{
        .addr = if (payload.allocation_ptr) |ptr| @intFromPtr(ptr) else 0,
        .len = payload.logical_len,
    };
    retirement.replacement_count += 1;
    retirement.replacement_bytes += payload.logical_len;
}

fn validateLiveCommitAliases(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    retirement: *const PreparedLiveRetirement,
    dispositions: *const [max_live_mutations]LiveCommitDisposition,
    permit: ?*const PreparedLiveCommit,
) error{InvalidAlias}!void {
    const fixed = [_]ByteRange{
        rangeOfValue(ledger),
        rangeOfValue(batch),
        rangeOfValue(retirement),
        rangeOfValue(dispositions),
        if (permit) |value| rangeOfValue(value) else .{ .start = 0, .end = 0 },
    };
    const fixed_count: usize = if (permit == null) fixed.len - 1 else fixed.len;
    for (fixed[0..fixed_count], 0..) |range, index|
        for (fixed[0..index]) |prior|
            if (rangesOverlap(range, prior)) return error.InvalidAlias;
    for (fixed[1..fixed_count]) |range|
        if (rangeOverlapsActive(range, ledger)) return error.InvalidAlias;
    var owned_ranges: [max_live_mutations * 3]ByteRange =
        [_]ByteRange{.{ .start = 0, .end = 0 }} ** (max_live_mutations * 3);
    var count: usize = 0;
    for (batch.mutations[0..batch.mutation_count]) |*mutation| {
        switch (mutation.*) {
            .admission => |*admission| {
                owned_ranges[count] = rangeOfPayload(&admission.owned_payload);
                count += 1;
            },
            .merge => |*merge| {
                switch (merge.source) {
                    .owned => |*source| {
                        owned_ranges[count] = rangeOfPayload(source);
                        count += 1;
                    },
                    .existing => {},
                }
                switch (merge.replacement) {
                    .prebuilt => |*replacement| {
                        owned_ranges[count] = rangeOfPayload(replacement);
                        count += 1;
                    },
                    .coalesced => {},
                }
            },
            else => {},
        }
    }
    for (batch.coalesced_replacements[0..batch.replacement_count]) |*replacement| {
        owned_ranges[count] = rangeOfPayload(replacement);
        count += 1;
    }
    for (owned_ranges[0..count], 0..) |range, index| {
        for (fixed) |fixed_range|
            if (rangesOverlap(range, fixed_range)) return error.InvalidAlias;
        if (rangeOverlapsActive(range, ledger)) return error.InvalidAlias;
        for (owned_ranges[0..index]) |prior|
            if (rangesOverlap(range, prior)) return error.InvalidAlias;
    }
}

fn validateIncomingLiveOwners(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
    source: *const PreparedLiveMergeSource,
    replacement: *const PreparedLiveReplacement,
) error{InvalidAlias}!void {
    var ranges: [4]ByteRange = [_]ByteRange{.{ .start = 0, .end = 0 }} ** 4;
    var count: usize = 0;
    switch (source.*) {
        .owned => |*payload| {
            ranges[count] = rangeOfValue(payload);
            count += 1;
            ranges[count] = rangeOfPayload(payload);
            count += 1;
        },
        .existing => {},
    }
    switch (replacement.*) {
        .prebuilt => |*payload| {
            ranges[count] = rangeOfValue(payload);
            count += 1;
            ranges[count] = rangeOfPayload(payload);
            count += 1;
        },
        .coalesced => {},
    }
    for (ranges[0..count], 0..) |range, index| {
        if (rangesOverlap(range, rangeOfValue(ledger)) or
            rangesOverlap(range, rangeOfValue(batch)) or
            rangeOverlapsActive(range, ledger))
            return error.InvalidAlias;
        for (ranges[0..index]) |prior|
            if (rangesOverlap(range, prior)) return error.InvalidAlias;
    }
}

fn batchOwnedAbortValid(
    ledger: *const ExternalInboxLedger,
    batch: *const PreparedLiveBatch,
) bool {
    if (batch.mutation_count > max_live_mutations or
        batch.replacement_count > max_live_mutations or
        !hasCanonicalLiveBatchTails(batch))
        return false;
    if (batch.lifecycle == .preparing and
        !std.mem.eql(
            u8,
            &batch.progress_digest,
            &liveProgressDigest(batch),
        ))
        return false;
    if (batch.lifecycle == .prepared and
        !std.mem.eql(u8, &batch.digest, &batchDigest(batch)))
        return false;
    var ranges: [max_live_mutations * 3]ByteRange =
        [_]ByteRange{.{ .start = 0, .end = 0 }} ** (max_live_mutations * 3);
    var count: usize = 0;
    for (batch.mutations[0..batch.mutation_count], 0..) |*mutation, index| {
        const sealed_digest = switch (mutation.*) {
            .admission => |admission| blk: {
                if (!fingerprintMatches(
                    admission.payload_fingerprint,
                    admission.owned_payload,
                )) return false;
                ranges[count] = rangeOfPayload(&admission.owned_payload);
                count += 1;
                break :blk admission.digest;
            },
            .merge => |merge| blk: {
                switch (merge.source) {
                    .owned => |*source| {
                        if (!fingerprintMatches(merge.source_fingerprint, source.*))
                            return false;
                        ranges[count] = rangeOfPayload(source);
                        count += 1;
                    },
                    .existing => {},
                }
                switch (merge.replacement) {
                    .prebuilt => |*replacement| {
                        if (!fingerprintMatches(
                            merge.replacement_fingerprint,
                            replacement.*,
                        )) return false;
                        ranges[count] = rangeOfPayload(replacement);
                        count += 1;
                    },
                    .coalesced => {},
                }
                break :blk merge.digest;
            },
            .release => |release| release.digest,
            else => return false,
        };
        if (!std.mem.eql(
            u8,
            &sealed_digest,
            &liveMutationDigest(batch, index),
        )) return false;
    }
    for (
        batch.coalesced_replacements[0..batch.replacement_count],
        batch.coalesced_replacement_fingerprints[0..batch.replacement_count],
    ) |*replacement, sealed| {
        if (!fingerprintMatches(sealed, replacement.*)) return false;
        ranges[count] = rangeOfPayload(replacement);
        count += 1;
    }
    for (ranges[0..count], 0..) |range, index| {
        if (rangesOverlap(range, rangeOfValue(ledger)) or
            rangesOverlap(range, rangeOfValue(batch)) or
            rangeOverlapsActive(range, ledger))
            return false;
        for (ranges[0..index]) |prior|
            if (rangesOverlap(range, prior)) return false;
    }
    return true;
}

fn hasCanonicalLiveBatchTails(batch: *const PreparedLiveBatch) bool {
    if (batch.mutation_count > max_live_mutations or
        batch.replacement_count > max_live_mutations)
        return false;
    for (batch.mutations[batch.mutation_count..]) |mutation| {
        switch (mutation) {
            .empty => {},
            else => return false,
        }
    }
    for (
        batch.coalesced_replacements[batch.replacement_count..],
        batch.coalesced_replacement_fingerprints[batch.replacement_count..],
    ) |replacement, sealed| {
        if (replacement.allocation_ptr != null or replacement.logical_len != 0 or
            sealed.address != 0 or sealed.logical_len != 0 or
            !std.mem.allEqual(u8, &sealed.content_digest, 0))
            return false;
    }
    return true;
}

pub const ExternalInboxLedger = struct {
    slots: [max_items]Slot = [_]Slot{.{}} ** max_items,
    external_identity_seal: LedgerExternalIdentitySeal = .{},
    charged_bytes: usize = 0,
    charged_items: usize = 0,
    retired_bytes: usize = 0,
    retired_items: usize = 0,
    next_slot_hint: usize = 0,
    next_generation: u64 = 1,
    generation_exhausted: bool = false,
    mutation_epoch: u64 = 0,
    planning_disabled: bool = false,
    invariant_failed: bool = false,
    draining_or_drained: bool = false,
    teardown_active: bool = false,
    owner_teardown_generation: u64 = 0,

    pub fn beginLiveBatch(
        self: *ExternalInboxLedger,
        out: *PreparedLiveBatch,
        allocator: std.mem.Allocator,
        external_identity: ?external_rx_types.RxIdentity,
    ) PrepareLiveError!void {
        if (out.lifecycle != .empty or out.saved_self_addr != 0)
            return error.InvalidPlan;
        if (rangesOverlap(rangeOfValue(out), rangeOfValue(self)) or
            rangeOverlapsActive(rangeOfValue(out), self))
            return error.InvalidAlias;
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (self.invariant_failed or self.planning_disabled)
            return error.PlanningDisabled;
        if (!self.hasValidAccounting()) return error.InvariantFailure;
        if (self.mutation_epoch == std.math.maxInt(u64))
            return error.EpochExhausted;
        if (external_identity) |identity|
            try self.validateExternalIdentityForLivePrepare(identity);
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .allocator = allocator,
            .sealed_allocator = allocator,
            .expected_mutation_epoch = self.mutation_epoch,
            .expected_accounting_digest = liveAccountingDigest(self),
            .expected_external_identity = external_identity,
            .expected_next_generation = self.next_generation,
            .expected_generation_exhausted = self.generation_exhausted,
            .expected_next_slot_hint = self.next_slot_hint,
            .expected_charged_bytes = self.charged_bytes,
            .expected_charged_items = self.charged_items,
            .lifecycle = .preparing,
        };
        out.working_simulation = simulateLiveBatch(self, out, 0) catch
            unreachable;
        out.working_simulation_digest =
            liveSimulationDigest(&out.working_simulation, 0);
        out.progress_digest = liveProgressDigest(out);
    }

    fn beginLiveCleanupBatch(
        self: *ExternalInboxLedger,
        out: *PreparedLiveBatch,
    ) PrepareLiveError!void {
        if (out.lifecycle != .empty or out.saved_self_addr != 0)
            return error.InvalidPlan;
        if (rangesOverlap(rangeOfValue(out), rangeOfValue(self)) or
            rangeOverlapsActive(rangeOfValue(out), self))
            return error.InvalidAlias;
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .allocator = std.heap.page_allocator,
            .sealed_allocator = std.heap.page_allocator,
            .expected_mutation_epoch = self.mutation_epoch,
            .expected_accounting_digest = liveAccountingDigest(self),
            .cleanup_only = true,
            .expected_next_generation = self.next_generation,
            .expected_generation_exhausted = self.generation_exhausted,
            .expected_next_slot_hint = self.next_slot_hint,
            .expected_charged_bytes = self.charged_bytes,
            .expected_charged_items = self.charged_items,
            .lifecycle = .preparing,
        };
        out.working_simulation = simulateLiveBatch(self, out, 0) catch
            unreachable;
        out.working_simulation_digest =
            liveSimulationDigest(&out.working_simulation, 0);
        out.progress_digest = liveProgressDigest(out);
    }

    pub fn prepareLiveAdmission(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        semantic: PayloadSemantic,
        payload: *OwnedPayload,
    ) PrepareLiveError!LiveTokenRef {
        try self.requirePreparingLiveBatch(batch);
        if (batch.mutation_count >= max_live_mutations) return error.ItemCapExceeded;
        try validatePayload(payload, payload.logical_len);
        try validateSemantic(semantic, payload.logical_len);
        try validateExternalSemanticForBatch(batch, semantic);
        if (rangesOverlap(rangeOfValue(payload), rangeOfPayload(payload)) or
            rangeOverlapsLedgerOrActive(rangeOfValue(payload), self) or
            rangeOverlapsLedgerOrActive(rangeOfPayload(payload), self) or
            rangesOverlap(rangeOfValue(payload), rangeOfValue(batch)) or
            rangesOverlap(rangeOfPayload(payload), rangeOfValue(batch)))
            return error.InvalidAlias;
        const prior = batch.working_simulation;
        const slot = findVirtualFreeSlot(
            self,
            &prior,
            batch.mutation_count,
            prior.next_slot_hint,
        ) orelse return error.ItemCapExceeded;
        var next_generation = prior.next_generation;
        var generation_exhausted = prior.generation_exhausted;
        const generation = try advanceVirtualGeneration(
            &next_generation,
            &generation_exhausted,
        );
        const token = Token{ .slot = @intCast(slot), .generation = generation };
        const index: usize = batch.mutation_count;
        batch.mutations[index] = .{ .admission = .{
            .saved_self_addr = @intFromPtr(&batch.mutations[index]),
            .ledger_addr = @intFromPtr(self),
            .batch_addr = @intFromPtr(batch),
            .semantic = semantic,
            .owned_payload = payload.*,
            .payload_fingerprint = fingerprint(payload.*),
            .reserved_token = token,
            .lifecycle = .prepared,
        } };
        const next_simulation = simulateLiveBatchFrom(
            self,
            batch,
            index,
            index + 1,
            prior,
        ) catch |err| {
            batch.mutations[index] = .empty;
            return err;
        };
        switch (batch.mutations[index]) {
            .admission => |*admission| {
                admission.owned_payload = payload.take();
                admission.payload_fingerprint = fingerprint(admission.owned_payload);
                admission.digest = liveMutationDigest(batch, index);
            },
            else => unreachable,
        }
        batch.mutation_count += 1;
        batch.working_simulation = next_simulation;
        batch.working_simulation_digest =
            liveSimulationDigest(&batch.working_simulation, batch.mutation_count);
        batch.progress_digest = liveProgressDigest(batch);
        return .{ .planned = @intCast(index) };
    }

    pub fn validatePreparedLiveAdmissionBinding(
        self: *const ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
        mutation_index: u8,
        semantic: PayloadSemantic,
        payload_digest: owner_seal.Digest,
    ) bool {
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            mutation_index >= batch.mutation_count)
            return false;
        const admission = switch (batch.mutations[mutation_index]) {
            .admission => |*value| value,
            else => return false,
        };
        return admission.saved_self_addr ==
            @intFromPtr(&batch.mutations[mutation_index]) and
            admission.batch_addr == @intFromPtr(batch) and
            admission.ledger_addr == @intFromPtr(self) and
            std.meta.eql(admission.semantic, semantic) and
            std.mem.eql(
                u8,
                &payload_digest,
                &owner_cleanup.contentDigest(admission.owned_payload.bytes()),
            ) and
            std.mem.eql(
                u8,
                &admission.digest,
                &liveMutationDigest(batch, mutation_index),
            );
    }

    pub fn validatePreparedLiveScreenBinding(
        self: *const ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
        mutation_index: u8,
        semantic: PayloadSemantic,
        payload_digest: owner_seal.Digest,
    ) bool {
        if (self.validatePreparedLiveAdmissionBinding(
            batch,
            mutation_index,
            semantic,
            payload_digest,
        )) return true;
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            mutation_index >= batch.mutation_count)
            return false;
        const merge = switch (batch.mutations[mutation_index]) {
            .merge => |*value| value,
            else => return false,
        };
        const source = switch (merge.source) {
            .owned => |*payload_owner| payload_owner,
            .existing => return false,
        };
        return merge.saved_self_addr ==
            @intFromPtr(&batch.mutations[mutation_index]) and
            merge.batch_addr == @intFromPtr(batch) and
            merge.ledger_addr == @intFromPtr(self) and
            std.meta.eql(merge.next_semantic, semantic) and
            std.mem.eql(
                u8,
                &payload_digest,
                &owner_cleanup.contentDigest(source.bytes()),
            ) and
            std.mem.eql(
                u8,
                &merge.digest,
                &liveMutationDigest(batch, mutation_index),
            );
    }

    pub fn prepareLiveMerge(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        destination: LiveTokenRef,
        next_semantic: PayloadSemantic,
        incoming_range: ?external_rx_types.RxRange,
        source: *PreparedLiveMergeSource,
        replacement: *PreparedLiveReplacement,
    ) PrepareLiveError!void {
        try self.requirePreparingLiveBatch(batch);
        if (batch.mutation_count >= max_live_mutations) return error.ItemCapExceeded;
        try validateIncomingLiveOwners(self, batch, source, replacement);
        const index: usize = batch.mutation_count;
        const prior = batch.working_simulation;
        const destination_node = try resolveVirtualRef(
            self,
            batch,
            &prior,
            index,
            destination,
        );
        var next_generation = prior.next_generation;
        var generation_exhausted = prior.generation_exhausted;
        const generation = try advanceVirtualGeneration(
            &next_generation,
            &generation_exhausted,
        );
        const result_token = Token{
            .slot = destination_node.token.slot,
            .generation = generation,
        };
        const source_fingerprint = switch (source.*) {
            .owned => |owned_source| blk: {
                try validatePayload(&owned_source, owned_source.logical_len);
                break :blk fingerprint(owned_source);
            },
            .existing => |source_ref| (try resolveVirtualRef(
                self,
                batch,
                &prior,
                index,
                source_ref,
            )).payload_fingerprint,
        };
        const expected_source_digest = switch (source.*) {
            .owned => [_]u8{0} ** 32,
            .existing => |source_ref| liveNodeDigest(try resolveVirtualRef(
                self,
                batch,
                &prior,
                index,
                source_ref,
            )),
        };
        const replacement_fingerprint = switch (replacement.*) {
            .coalesced => PayloadFingerprint{
                .allocator = std.heap.page_allocator,
                .address = 0,
                .logical_len = 0,
            },
            .prebuilt => |owned_replacement| blk: {
                try validatePayload(&owned_replacement, owned_replacement.logical_len);
                break :blk fingerprint(owned_replacement);
            },
        };
        batch.mutations[index] = .{ .merge = .{
            .saved_self_addr = @intFromPtr(&batch.mutations[index]),
            .ledger_addr = @intFromPtr(self),
            .batch_addr = @intFromPtr(batch),
            .destination = destination,
            .expected_destination_generation = destination_node.token.generation,
            .next_semantic = next_semantic,
            .source = source.*,
            .source_fingerprint = source_fingerprint,
            .incoming_range = incoming_range,
            .expected_source_digest = expected_source_digest,
            .replacement = replacement.*,
            .replacement_fingerprint = replacement_fingerprint,
            .expected_accounting_digest = liveAccountingDigest(self),
            .expected_destination_digest = liveNodeDigest(destination_node),
            .expected_destination_fingerprint = destination_node.payload_fingerprint,
            .result_token = result_token,
            .lifecycle = .prepared,
        } };
        const next_simulation = simulateLiveBatchFrom(
            self,
            batch,
            index,
            index + 1,
            prior,
        ) catch |err| {
            batch.mutations[index] = .empty;
            return err;
        };
        switch (batch.mutations[index]) {
            .merge => |*merge| {
                switch (source.*) {
                    .owned => |*owned_source| {
                        merge.source = .{ .owned = owned_source.take() };
                        merge.source_fingerprint = fingerprint(merge.source.owned);
                    },
                    .existing => {},
                }
                switch (replacement.*) {
                    .coalesced => {},
                    .prebuilt => |*owned_replacement| {
                        merge.replacement = .{ .prebuilt = owned_replacement.take() };
                        merge.replacement_fingerprint =
                            fingerprint(merge.replacement.prebuilt);
                    },
                }
                merge.digest = liveMutationDigest(batch, index);
            },
            else => unreachable,
        }
        batch.mutation_count += 1;
        batch.working_simulation = next_simulation;
        batch.working_simulation_digest =
            liveSimulationDigest(&batch.working_simulation, batch.mutation_count);
        batch.progress_digest = liveProgressDigest(batch);
    }

    pub fn prepareLiveRelease(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        token: LiveTokenRef,
        expected_phase: PayloadPhase,
    ) PrepareLiveError!void {
        try self.requirePreparingLiveBatch(batch);
        if (batch.mutation_count >= max_live_mutations) return error.ItemCapExceeded;
        const index: usize = batch.mutation_count;
        const prior = batch.working_simulation;
        const target = try resolveVirtualRef(self, batch, &prior, index, token);
        batch.mutations[index] = .{ .release = .{
            .saved_self_addr = @intFromPtr(&batch.mutations[index]),
            .ledger_addr = @intFromPtr(self),
            .batch_addr = @intFromPtr(batch),
            .token = token,
            .expected_phase = expected_phase,
            .expected_token_generation = target.token.generation,
            .expected_accounting_digest = liveAccountingDigest(self),
            .expected_token_digest = liveNodeDigest(target),
            .expected_token_fingerprint = target.payload_fingerprint,
            .lifecycle = .prepared,
        } };
        const next_simulation = simulateLiveBatchFrom(
            self,
            batch,
            index,
            index + 1,
            prior,
        ) catch |err| {
            batch.mutations[index] = .empty;
            return err;
        };
        switch (batch.mutations[index]) {
            .release => |*prepared_release| {
                prepared_release.digest = liveMutationDigest(batch, index);
            },
            else => unreachable,
        }
        batch.mutation_count += 1;
        batch.working_simulation = next_simulation;
        batch.working_simulation_digest =
            liveSimulationDigest(&batch.working_simulation, batch.mutation_count);
        batch.progress_digest = liveProgressDigest(batch);
    }

    pub fn finishLiveBatch(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
    ) PrepareLiveError!void {
        try self.requirePreparingLiveBatch(batch);
        if (batch.mutation_count == 0) return error.InvalidPlan;
        if (batch.replacement_count != 0 or batch.replacement_bytes != 0)
            return error.InvalidPlan;
        var simulation = try simulateLiveBatch(self, batch, batch.mutation_count);
        if (!std.mem.eql(
            u8,
            &batch.working_simulation_digest,
            &liveSimulationDigest(&simulation, batch.mutation_count),
        )) return error.StalePlan;
        for (0..batch.mutation_count) |index| {
            const current_digest = liveMutationDigest(batch, index);
            const sealed_digest = switch (batch.mutations[index]) {
                .admission => |value| value.digest,
                .merge => |value| value.digest,
                .release => |value| value.digest,
                else => return error.InvalidPlan,
            };
            if (!std.mem.eql(u8, &current_digest, &sealed_digest))
                return error.StalePlan;
        }
        // **병합이 없는 배치(admission·release만)는 아래에서 외부 코드가 전혀 돌지 않는다** — 교체
        // 할당(콜백)도, 원본 바이트 읽기도, 배치 갱신도 병합 갈래에만 있다. 그래서 할당 뒤와 끝의
        // 재구성은 첫 재구성과 같은 입력의 같은 계산이다. 재구성이 지키는 것은 「할당 콜백이 ledger
        // 뒷받침 바이트를 바꾸는 것」이고 그것은 병합에서만 생기므로, 병합이 있을 때만 다시 짓는다.
        // 슬롯 4096개 fold 두 번을 해제 1건마다 아낀다 — **측정값**은 판정자 주석에 있다.
        var has_merge = false;
        for (batch.mutations[0..batch.mutation_count]) |mutation| {
            if (mutation == .merge) {
                has_merge = true;
                break;
            }
        }
        const allocation_allocator = batch.sealed_allocator;
        const ReplacementAllocationPlan = struct {
            mutation_index: u8,
            logical_len: usize,
        };
        var allocation_plans =
            [_]ReplacementAllocationPlan{.{
                .mutation_index = 0,
                .logical_len = 0,
            }} ** max_live_mutations;
        var allocation_plan_count: u8 = 0;
        var allocation_plan_bytes: usize = 0;
        for (batch.mutations[0..batch.mutation_count], 0..) |mutation, index| {
            switch (mutation) {
                .merge => |merge| {
                    if (!simulation.nodes[index].live) continue;
                    if (merge.replacement != .coalesced) continue;
                    if (allocation_plan_count >= max_live_mutations)
                        return error.ItemCapExceeded;
                    const len = simulation.nodes[index].logical_len;
                    allocation_plan_bytes = std.math.add(
                        usize,
                        allocation_plan_bytes,
                        len,
                    ) catch return error.ByteCapExceeded;
                    if (allocation_plan_bytes > max_bytes)
                        return error.ByteCapExceeded;
                    allocation_plans[allocation_plan_count] = .{
                        .mutation_index = @intCast(index),
                        .logical_len = len,
                    };
                    allocation_plan_count += 1;
                },
                else => {},
            }
        }
        var pending_replacements =
            [_]OwnedPayload{OwnedPayload.empty(allocation_allocator)} **
            max_live_mutations;
        var pending_replacement_count: u8 = 0;
        defer for (pending_replacements[0..pending_replacement_count]) |*pending|
            pending.deinit();
        for (allocation_plans[0..allocation_plan_count]) |plan| {
            var allocation =
                try allocation_allocator.alloc(u8, plan.logical_len);
            errdefer allocation_allocator.free(allocation);
            @memset(allocation, 0);
            pending_replacements[pending_replacement_count] =
                OwnedPayload.takeOwned(allocation_allocator, &allocation);
            pending_replacement_count += 1;
        }
        // Allocation callbacks may mutate ledger-backed source bytes. Defer every source
        // read until all callbacks are complete, then validate the complete virtual batch once.
        if (has_merge) {
            try self.requirePreparingLiveBatch(batch);
            simulation = try simulateLiveBatch(self, batch, batch.mutation_count);
            var pending_replacement_index: u8 = 0;
            for (batch.mutations[0..batch.mutation_count], 0..) |*mutation, index| {
                switch (mutation.*) {
                    .merge => |*merge| {
                        if (!simulation.nodes[index].live) continue;
                        switch (merge.replacement) {
                            .prebuilt => |prebuilt| {
                                var cursor: usize = 0;
                                try matchRefBytes(
                                    self,
                                    batch,
                                    merge.destination,
                                    index,
                                    prebuilt.bytes(),
                                    &cursor,
                                );
                                switch (merge.source) {
                                    .owned => |source| {
                                        const end = std.math.add(
                                            usize,
                                            cursor,
                                            source.logical_len,
                                        ) catch return error.InvalidPayload;
                                        if (end != prebuilt.logical_len or
                                            !std.mem.eql(
                                                u8,
                                                prebuilt.bytes()[cursor..end],
                                                source.bytes(),
                                            ))
                                            return error.InvalidPayload;
                                        cursor = end;
                                    },
                                    .existing => |source_ref| try matchRefBytes(
                                        self,
                                        batch,
                                        source_ref,
                                        index,
                                        prebuilt.bytes(),
                                        &cursor,
                                    ),
                                }
                                if (cursor != prebuilt.logical_len)
                                    return error.InvalidPayload;
                            },
                            .coalesced => {
                                if (pending_replacement_index >= pending_replacement_count or
                                    batch.replacement_count >= max_live_mutations)
                                    return error.InvalidPlan;
                                const pending =
                                    &pending_replacements[pending_replacement_index];
                                if (allocation_plans[pending_replacement_index].mutation_index !=
                                    index)
                                    return error.StalePlan;
                                var cursor: usize = 0;
                                try appendRefBytes(
                                    self,
                                    batch,
                                    merge.destination,
                                    index,
                                    pending.mutableBytes(),
                                    &cursor,
                                );
                                switch (merge.source) {
                                    .owned => |source| {
                                        const end = std.math.add(
                                            usize,
                                            cursor,
                                            source.logical_len,
                                        ) catch return error.InvalidPayload;
                                        if (end != pending.logical_len)
                                            return error.InvalidPayload;
                                        @memcpy(
                                            pending.mutableBytes()[cursor..end],
                                            source.bytes(),
                                        );
                                        cursor = end;
                                    },
                                    .existing => |source_ref| try appendRefBytes(
                                        self,
                                        batch,
                                        source_ref,
                                        index,
                                        pending.mutableBytes(),
                                        &cursor,
                                    ),
                                }
                                if (cursor != pending.logical_len)
                                    return error.InvalidPayload;
                                const replacement_index = batch.replacement_count;
                                batch.coalesced_replacements[replacement_index] =
                                    pending.*;
                                pending.* = OwnedPayload.empty(batch.allocator);
                                batch.coalesced_replacement_fingerprints[replacement_index] =
                                    fingerprint(
                                        batch.coalesced_replacements[replacement_index],
                                    );
                                merge.coalesced_replacement_index = replacement_index;
                                batch.replacement_count += 1;
                                batch.replacement_bytes = std.math.add(
                                    usize,
                                    batch.replacement_bytes,
                                    batch.coalesced_replacements[replacement_index].logical_len,
                                ) catch return error.ByteCapExceeded;
                                pending_replacement_index += 1;
                            },
                        }
                        merge.digest = liveMutationDigest(batch, index);
                        batch.progress_digest = liveProgressDigest(batch);
                    },
                    else => {},
                }
            }
            if (pending_replacement_index != pending_replacement_count)
                return error.InvalidPlan;
            simulation = try simulateLiveBatch(self, batch, batch.mutation_count);
        }
        batch.accepted_source_bytes = simulation.accepted_source_bytes;
        batch.expected_next_generation = simulation.next_generation;
        batch.expected_generation_exhausted = simulation.generation_exhausted;
        batch.expected_next_slot_hint = simulation.next_slot_hint;
        batch.expected_charged_bytes = simulation.charged_bytes;
        batch.expected_charged_items = simulation.charged_items;
        batch.lifecycle = .prepared;
        batch.digest = batchDigest(batch);
    }

    fn validatePreparedLiveCommitInputs(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        require_empty_dispositions: bool,
        permit: ?*const PreparedLiveCommit,
    ) CommitLiveError!LiveSimulation {
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            batch.lifecycle != .prepared)
            return error.InvalidPlan;
        if (batch.mutation_count > max_live_mutations or
            batch.replacement_count > max_live_mutations)
            return error.InvalidPlan;
        if (!hasCanonicalLiveBatchTails(batch))
            return error.InvalidPlan;
        if (!std.meta.eql(batch.allocator, batch.sealed_allocator))
            return error.InvalidPlan;
        if (!std.mem.eql(u8, &batch.digest, &batchDigest(batch)))
            return error.InvalidPlan;
        if (!isCanonicalEmptyLiveRetirement(retirement))
            return error.InvalidPlan;
        if (require_empty_dispositions)
            for (dispositions) |disposition|
                if (disposition != .unused) return error.InvalidPlan;
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (!batch.cleanup_only and
            (self.invariant_failed or self.planning_disabled))
            return error.PlanningDisabled;
        if (self.mutation_epoch != batch.expected_mutation_epoch or
            !std.mem.eql(
                u8,
                &batch.expected_accounting_digest,
                &liveAccountingDigest(self),
            ))
            return error.StalePlan;
        if (batch.expected_external_identity) |identity|
            self.validateExternalIdentityForLivePrepare(identity) catch
                return error.InvalidSemantic;
        for (
            batch.coalesced_replacements[0..batch.replacement_count],
            batch.coalesced_replacement_fingerprints[0..batch.replacement_count],
        ) |replacement, sealed| {
            if (!fingerprintMatches(sealed, replacement))
                return error.StalePlan;
        }
        try validateLiveCommitAliases(
            self,
            batch,
            retirement,
            dispositions,
            permit,
        );
        const simulation = simulateLiveBatch(
            self,
            batch,
            batch.mutation_count,
        ) catch |err| return mapPrepareToCommitLive(err);
        if (simulation.next_generation != batch.expected_next_generation or
            simulation.generation_exhausted != batch.expected_generation_exhausted or
            simulation.next_slot_hint != batch.expected_next_slot_hint or
            simulation.charged_bytes != batch.expected_charged_bytes or
            simulation.charged_items != batch.expected_charged_items or
            simulation.accepted_source_bytes != batch.accepted_source_bytes)
            return error.StalePlan;
        for (0..batch.mutation_count) |index| {
            const sealed = switch (batch.mutations[index]) {
                .admission => |value| value.digest,
                .merge => |value| value.digest,
                .release => |value| value.digest,
                else => return error.InvalidPlan,
            };
            if (!std.mem.eql(
                u8,
                &sealed,
                &liveMutationDigest(batch, index),
            )) return error.StalePlan;
        }
        return simulation;
    }

    const LiveDispositionCounts = struct {
        partial: u8 = 0,
        completed: u8 = 0,
        retired: u8 = 0,
        retired_bytes: usize = 0,

        fn total(self: LiveDispositionCounts) u8 {
            return self.partial + self.completed;
        }
    };

    fn previewLiveDispositions(
        batch: *const PreparedLiveBatch,
        simulation: *const LiveSimulation,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
    ) LiveDispositionCounts {
        var counts: LiveDispositionCounts = .{};
        for (0..batch.mutation_count) |index| {
            if (simulation.nodes[index].live) {
                const root: FinalLiveRoot = switch (std.meta.activeTag(
                    simulation.nodes[index].semantic,
                )) {
                    .partial => blk: {
                        counts.partial += 1;
                        break :blk .{
                            .token = simulation.nodes[index].token,
                            .phase = .partial,
                        };
                    },
                    .completed => blk: {
                        counts.completed += 1;
                        break :blk .{
                            .token = simulation.nodes[index].token,
                            .phase = .completed,
                        };
                    },
                    else => unreachable,
                };
                dispositions[index] = .{ .final_live = root };
            } else {
                dispositions[index] = .superseded_tombstone;
            }
        }
        for (batch.mutation_count..max_live_mutations) |index|
            dispositions[index] = .unused;
        return counts;
    }

    fn countLiveDispositions(
        mutation_count: u8,
        dispositions: *const [max_live_mutations]LiveCommitDisposition,
        simulation: *const LiveSimulation,
    ) CommitLiveError!LiveDispositionCounts {
        var counts: LiveDispositionCounts = .{};
        for (dispositions[0..mutation_count], 0..) |disposition, index| {
            switch (disposition) {
                .final_live => |root| switch (root.phase) {
                    .partial => counts.partial += 1,
                    .completed => counts.completed += 1,
                },
                .cleanup_final => |root| {
                    if (root.phase != .completed) return error.InvalidPlan;
                    counts.retired += 1;
                    const node = simulation.nodes[index];
                    if (!node.live or !std.meta.eql(node.token, root.token))
                        return error.StalePlan;
                    counts.retired_bytes = std.math.add(
                        usize,
                        counts.retired_bytes,
                        node.payload_fingerprint.logical_len,
                    ) catch return error.ByteCapExceeded;
                },
                .superseded_tombstone => {},
                .unused => return error.InvalidPlan,
            }
        }
        for (dispositions[mutation_count..]) |disposition|
            if (disposition != .unused) return error.InvalidPlan;
        return counts;
    }

    fn applyFinalRootCleanupSelection(
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
        selection: *const [max_live_mutations]bool,
    ) CommitLiveError!void {
        var selected_count: u8 = 0;
        var selected_bytes: usize = 0;
        for (selection, 0..) |selected, mutation_index| {
            if (!selected) continue;
            if (mutation_index >= permit.mutation_count) return error.InvalidPlan;
            const root = switch (dispositions[mutation_index]) {
                .final_live => |value| value,
                .unused, .cleanup_final, .superseded_tombstone => return error.InvalidPlan,
            };
            if (root.phase != .completed) return error.InvalidPlan;
            const node = permit.simulation.nodes[mutation_index];
            if (!node.live or !std.meta.eql(node.token, root.token))
                return error.StalePlan;
            selected_count = std.math.add(u8, selected_count, 1) catch
                return error.InvalidPlan;
            selected_bytes = std.math.add(
                usize,
                selected_bytes,
                node.payload_fingerprint.logical_len,
            ) catch return error.ByteCapExceeded;
        }
        if (selected_count > permit.final_completed_count)
            return error.StalePlan;
        const reserved_cleanup_count = std.math.add(
            usize,
            permit.expected_cleanup_count,
            selected_count,
        ) catch return error.InvalidPlan;
        if (reserved_cleanup_count > max_live_cleanup_owners)
            return error.InvalidPlan;
        const reserved_cleanup_bytes = std.math.add(
            usize,
            permit.expected_cleanup_bytes,
            selected_bytes,
        ) catch return error.ByteCapExceeded;
        for (selection[0..permit.mutation_count], 0..) |selected, mutation_index| {
            if (!selected) continue;
            const root = dispositions[mutation_index].final_live;
            dispositions[mutation_index] = .{ .cleanup_final = root };
        }
        permit.final_completed_count -= selected_count;
        permit.cleanup_final_count = selected_count;
        permit.cleanup_final_bytes = selected_bytes;
        permit.reserved_cleanup_count = reserved_cleanup_count;
        permit.reserved_cleanup_bytes = reserved_cleanup_bytes;
        permit.dispositions_digest = liveDispositionsDigest(dispositions);
        permit.digest = preparedLiveCommitDigest(permit);
    }

    /// Builds sealed bytes for a projected final-address commit without publishing authority.
    /// Destination ranges are checked as integers before any pointer is formed, so hostile
    /// addresses cannot wrap or alias the live source graph.
    pub fn planPreparedFinalRootsForCleanup(
        self: *ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
        retirement: *const PreparedLiveRetirement,
        dispositions: *const [max_live_mutations]LiveCommitDisposition,
        permit: *const PreparedLiveCommit,
        selection: *const [max_live_mutations]bool,
        final_dispositions_addr: usize,
        final_permit_addr: usize,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
    ) CommitLiveError!ProjectedLiveCommitCandidate {
        try self.validatePreparedLiveCommitPermit(
            batch,
            retirement,
            dispositions,
            permit,
            aggregate_addr,
            storage_addr,
            turn_generation,
        );
        const final_dispositions = try checkedAddressRange(
            final_dispositions_addr,
            @sizeOf([max_live_mutations]LiveCommitDisposition),
        );
        const final_permit = try checkedAddressRange(
            final_permit_addr,
            @sizeOf(PreparedLiveCommit),
        );
        if (rangesOverlap(final_dispositions, final_permit))
            return error.InvalidAlias;
        const sources = [_]ByteRange{
            rangeOfValue(self),
            rangeOfValue(batch),
            rangeOfValue(retirement),
            rangeOfValue(dispositions),
            rangeOfValue(permit),
        };
        for (sources) |source| {
            if (rangesOverlap(final_dispositions, source) or
                rangesOverlap(final_permit, source))
                return error.InvalidAlias;
        }
        if (rangeOverlapsActive(final_dispositions, self) or
            rangeOverlapsActive(final_permit, self))
            return error.InvalidAlias;

        var candidate: ProjectedLiveCommitCandidate = .{
            .dispositions = dispositions.*,
            .permit = permit.*,
        };
        candidate.permit.saved_self_addr = final_permit_addr;
        candidate.permit.dispositions_addr = final_dispositions_addr;
        candidate.permit.digest = preparedLiveCommitDigest(&candidate.permit);
        try applyFinalRootCleanupSelection(
            &candidate.dispositions,
            &candidate.permit,
            selection,
        );
        return candidate;
    }

    /// Marks a bounded set of completed roots for direct deferred cleanup. This is not the
    /// ledger's retired-slot queue: selected payloads receive actual tokens during commit, then
    /// move straight into `PreparedLiveRetirement` without becoming externally live. The whole
    /// selection is validated before the first disposition changes, preserving retryability.
    pub fn markPreparedFinalRootsForCleanup(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
        selection: *const [max_live_mutations]bool,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
    ) CommitLiveError!void {
        try self.validatePreparedLiveCommitPermit(
            batch,
            retirement,
            dispositions,
            permit,
            aggregate_addr,
            storage_addr,
            turn_generation,
        );
        try applyFinalRootCleanupSelection(dispositions, permit, selection);
    }

    pub fn prepareLiveCommit(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
        permit: *PreparedLiveCommit,
    ) CommitLiveError!void {
        if (aggregate_addr == 0 or storage_addr == 0 or turn_generation == 0)
            return error.InvalidPlan;
        const simulation = try self.validatePreparedLiveCommitInputs(
            batch,
            retirement,
            dispositions,
            true,
            permit,
        );
        if (!std.meta.eql(permit.*, PreparedLiveCommit{}))
            return error.InvalidPlan;
        const counts = previewLiveDispositions(
            batch,
            &simulation,
            dispositions,
        );
        permit.* = .{
            .saved_self_addr = @intFromPtr(permit),
            .ledger_addr = @intFromPtr(self),
            .batch_addr = @intFromPtr(batch),
            .retirement_addr = @intFromPtr(retirement),
            .dispositions_addr = @intFromPtr(dispositions),
            .aggregate_addr = aggregate_addr,
            .storage_addr = storage_addr,
            .turn_generation = turn_generation,
            .mutation_count = batch.mutation_count,
            .final_partial_count = counts.partial,
            .final_completed_count = counts.completed,
            .expected_cleanup_count = simulation.cleanup_count,
            .expected_cleanup_bytes = simulation.cleanup_bytes,
            .reserved_cleanup_count = simulation.cleanup_count,
            .reserved_cleanup_bytes = simulation.cleanup_bytes,
            .simulation = simulation,
            .simulation_digest = liveSimulationDigest(&simulation, batch.mutation_count),
            .dispositions_digest = liveDispositionsDigest(dispositions),
            .retirement_digest = liveRetirementDigest(retirement),
            .lifecycle = .prepared,
        };
        permit.digest = preparedLiveCommitDigest(permit);
    }

    fn validatePreparedLiveCommitPermit(
        self: *ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
        retirement: *const PreparedLiveRetirement,
        dispositions: *const [max_live_mutations]LiveCommitDisposition,
        permit: *const PreparedLiveCommit,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
    ) CommitLiveError!void {
        const current = try self.validatePreparedLiveCommitInputs(
            @constCast(batch),
            @constCast(retirement),
            @constCast(dispositions),
            false,
            permit,
        );
        if (permit.saved_self_addr != @intFromPtr(permit) or
            permit.ledger_addr != @intFromPtr(self) or
            permit.batch_addr != @intFromPtr(batch) or
            permit.retirement_addr != @intFromPtr(retirement) or
            permit.dispositions_addr != @intFromPtr(dispositions) or
            permit.aggregate_addr != aggregate_addr or
            permit.storage_addr != storage_addr or
            permit.turn_generation != turn_generation or
            permit.lifecycle != .prepared)
            return error.InvalidPlan;
        if (!std.mem.eql(
            u8,
            &permit.digest,
            &preparedLiveCommitDigest(permit),
        )) return error.StalePlan;
        if (!std.mem.eql(
            u8,
            &permit.simulation_digest,
            &liveSimulationDigest(&permit.simulation, permit.mutation_count),
        )) return error.StalePlan;
        if (!std.mem.eql(
            u8,
            &permit.dispositions_digest,
            &liveDispositionsDigest(dispositions),
        )) return error.StalePlan;
        if (!std.mem.eql(
            u8,
            &permit.retirement_digest,
            &liveRetirementDigest(retirement),
        )) return error.StalePlan;
        const counts = try countLiveDispositions(
            permit.mutation_count,
            dispositions,
            &permit.simulation,
        );
        const reserved_cleanup_count = std.math.add(
            usize,
            permit.expected_cleanup_count,
            counts.retired,
        ) catch return error.InvalidPlan;
        const reserved_cleanup_bytes = std.math.add(
            usize,
            permit.expected_cleanup_bytes,
            counts.retired_bytes,
        ) catch return error.ByteCapExceeded;
        if (permit.final_partial_count != counts.partial or
            permit.final_completed_count != counts.completed or
            permit.cleanup_final_count != counts.retired or
            permit.cleanup_final_bytes != counts.retired_bytes or
            permit.reserved_cleanup_count != reserved_cleanup_count or
            permit.reserved_cleanup_bytes != reserved_cleanup_bytes)
            return error.StalePlan;
        if (permit.reserved_cleanup_count >
            max_live_cleanup_owners)
            return error.InvalidPlan;
        if (permit.mutation_count != batch.mutation_count or
            permit.expected_cleanup_count != current.cleanup_count or
            permit.expected_cleanup_bytes != current.cleanup_bytes or
            !std.mem.eql(
                u8,
                &permit.simulation_digest,
                &liveSimulationDigest(&current, batch.mutation_count),
            ))
            return error.StalePlan;
    }

    pub fn validatePreparedLiveCommit(
        self: *ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
        retirement: *const PreparedLiveRetirement,
        dispositions: *const [max_live_mutations]LiveCommitDisposition,
        permit: *const PreparedLiveCommit,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
    ) bool {
        self.validatePreparedLiveCommitPermit(
            batch,
            retirement,
            dispositions,
            permit,
            aggregate_addr,
            storage_addr,
            turn_generation,
        ) catch return false;
        return true;
    }

    fn consumePreparedLiveCommitChecked(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
        aggregate_addr: usize,
        storage_addr: usize,
        turn_generation: u64,
    ) CommitLiveError!void {
        try self.validatePreparedLiveCommitPermit(
            batch,
            retirement,
            dispositions,
            permit,
            aggregate_addr,
            storage_addr,
            turn_generation,
        );
        self.consumePreparedLiveCommitUnchecked(
            batch,
            retirement,
            dispositions,
            permit,
        );
    }

    pub fn commitPreparedLiveBatch(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
    ) CommitLiveError!u8 {
        const simulation = try self.validatePreparedLiveCommitInputs(
            batch,
            retirement,
            dispositions,
            true,
            null,
        );
        const counts = previewLiveDispositions(
            batch,
            &simulation,
            dispositions,
        );
        self.commitPreparedLiveBatchUnchecked(
            batch,
            retirement,
            dispositions,
            &simulation,
            0,
            0,
        );
        return counts.total();
    }

    pub fn consumePreparedLiveCommitUnchecked(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
    ) void {
        permit.lifecycle = .consumed;
        permit.digest = preparedLiveCommitDigest(permit);
        self.commitPreparedLiveBatchUnchecked(
            batch,
            retirement,
            dispositions,
            &permit.simulation,
            permit.cleanup_final_count,
            permit.cleanup_final_bytes,
        );
    }

    /// Callback-free commit leaf that additionally initializes caller-owned immutable output.
    /// The checked permit validator and caller destination-pristine proof must run before entry.
    pub fn consumePreparedLiveCommitWithOutputUnchecked(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
        output: *CommittedLiveOutput,
    ) void {
        permit.lifecycle = .consumed;
        permit.digest = preparedLiveCommitDigest(permit);
        self.commitPreparedLiveBatchUnchecked(
            batch,
            retirement,
            dispositions,
            &permit.simulation,
            permit.cleanup_final_count,
            permit.cleanup_final_bytes,
        );
        output.* = .{
            .saved_self_addr = @intFromPtr(output),
            .ledger_addr = @intFromPtr(self),
            .permit_addr = @intFromPtr(permit),
            .permit_digest = permit.digest,
            .mutation_epoch = self.mutation_epoch,
            .authority_digest = committedLiveAuthorityDigest(self),
            .lifecycle = .committed,
        };
        var count: u8 = 0;
        for (dispositions[0..permit.mutation_count], 0..) |disposition, index| {
            const root = switch (disposition) {
                .final_live, .cleanup_final => |value| value,
                .unused, .superseded_tombstone => continue,
            };
            const node = permit.simulation.nodes[index];
            output.entries[count] = .{
                .token = root.token,
                .phase = switch (root.phase) {
                    .partial => .partial,
                    .completed => .completed,
                },
                .semantic = node.semantic,
                .semantic_digest = payloadSemanticAuthorityDigest(node.semantic),
                .cleanup_only = std.meta.activeTag(disposition) == .cleanup_final,
            };
            count += 1;
        }
        output.count = count;
        output.digest = committedLiveOutputDigest(output);
    }

    pub fn abortPreparedLiveCommit(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        permit: *PreparedLiveCommit,
    ) AbortLiveCommitResult {
        self.validatePreparedLiveCommitPermit(
            batch,
            retirement,
            dispositions,
            permit,
            permit.aggregate_addr,
            permit.storage_addr,
            permit.turn_generation,
        ) catch return .ignored_untrusted;
        for (dispositions) |*disposition| disposition.* = .unused;
        permit.lifecycle = .aborted;
        permit.dispositions_digest = liveDispositionsDigest(dispositions);
        permit.digest = preparedLiveCommitDigest(permit);
        return .aborted;
    }

    pub fn resetPreparedLiveCommit(permit: *PreparedLiveCommit) bool {
        if (permit.saved_self_addr != @intFromPtr(permit) or
            (permit.lifecycle != .aborted and permit.lifecycle != .consumed) or
            !std.mem.eql(
                u8,
                &permit.digest,
                &preparedLiveCommitDigest(permit),
            ))
            return false;
        permit.* = .{};
        return true;
    }

    pub fn prepareLiveBatchAbort(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        out: *FrozenLiveBatchAbort,
    ) CommitLiveError!void {
        if (out.saved_self_addr != 0 or out.lifecycle != .empty or
            !std.mem.allEqual(u8, &out.digest, 0))
            return error.InvalidPlan;
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            (batch.lifecycle != .preparing and batch.lifecycle != .prepared))
            return error.InvalidPlan;
        if (!batchOwnedAbortValid(self, batch)) return error.StalePlan;
        if (rangesOverlap(rangeOfValue(out), rangeOfValue(self)) or
            rangesOverlap(rangeOfValue(out), rangeOfValue(batch)) or
            rangeOverlapsActive(rangeOfValue(out), self))
            return error.InvalidAlias;

        var owners =
            [_]?*OwnedPayload{null} ** max_live_cleanup_owners;
        var count: usize = 0;
        var bytes: usize = 0;
        for (batch.mutations[0..batch.mutation_count]) |*mutation| switch (mutation.*) {
            .admission => |*admission| {
                if (admission.owned_payload.logical_len != 0) {
                    if (count == owners.len) return error.InvalidPlan;
                    owners[count] = &admission.owned_payload;
                    count += 1;
                }
            },
            .merge => |*merge| {
                switch (merge.source) {
                    .owned => |*source| if (source.logical_len != 0) {
                        if (count == owners.len) return error.InvalidPlan;
                        owners[count] = source;
                        count += 1;
                    },
                    .existing => {},
                }
                switch (merge.replacement) {
                    .prebuilt => |*replacement| if (replacement.logical_len != 0) {
                        if (count == owners.len) return error.InvalidPlan;
                        owners[count] = replacement;
                        count += 1;
                    },
                    .coalesced => {},
                }
            },
            else => {},
        };
        for (batch.coalesced_replacements[0..batch.replacement_count]) |*replacement| {
            if (replacement.logical_len == 0) continue;
            if (count == owners.len) return error.InvalidPlan;
            owners[count] = replacement;
            count += 1;
        }
        for (owners[0..count], 0..) |owner_optional, index| {
            const owner = owner_optional.?;
            const payload_range = rangeOfPayload(owner);
            if (rangesOverlap(rangeOfValue(out), payload_range))
                return error.InvalidAlias;
            for (owners[0..index]) |prior_optional|
                if (rangesOverlap(payload_range, rangeOfPayload(prior_optional.?)))
                    return error.InvalidAlias;
            bytes = std.math.add(
                usize,
                bytes,
                owner.logical_len,
            ) catch return error.ByteCapExceeded;
        }

        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .batch_addr = @intFromPtr(batch),
            .cleanup_count = @intCast(count),
            .cleanup_bytes = bytes,
            .lifecycle = .prepared,
            .digest = undefined,
        };
        for (owners[0..count], 0..) |owner_optional, index|
            owner_cleanup.freezeOwnedSlice(
                &out.cleanup[index],
                owner_optional.?.allocator,
                @constCast(owner_optional.?.bytes()),
            ) catch unreachable;
        out.digest = frozenLiveBatchAbortDigest(out);
    }

    pub fn validatePreparedLiveBatchAbort(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        permit: *const FrozenLiveBatchAbort,
    ) bool {
        if (permit.saved_self_addr != @intFromPtr(permit) or
            permit.ledger_addr != @intFromPtr(self) or
            permit.batch_addr != @intFromPtr(batch) or
            permit.cleanup_count > max_live_cleanup_owners or
            permit.lifecycle != .prepared or
            !std.mem.eql(
                u8,
                &permit.digest,
                &frozenLiveBatchAbortDigest(permit),
            ) or
            !batchOwnedAbortValid(self, batch))
            return false;
        var bytes: usize = 0;
        for (permit.cleanup[0..permit.cleanup_count]) |*descriptor| {
            if (!owner_cleanup.validate(descriptor)) return false;
            bytes = std.math.add(
                usize,
                bytes,
                descriptor.allocation_len,
            ) catch return false;
        }
        return bytes == permit.cleanup_bytes;
    }

    pub fn commitLiveBatchAbortUnchecked(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        permit: *FrozenLiveBatchAbort,
    ) void {
        _ = self;
        for (batch.mutations[0..batch.mutation_count]) |*mutation| {
            switch (mutation.*) {
                .admission => |*admission| {
                    admission.owned_payload =
                        OwnedPayload.empty(admission.owned_payload.allocator);
                },
                .merge => |*merge| {
                    switch (merge.source) {
                        .owned => |*source| source.* =
                            OwnedPayload.empty(source.allocator),
                        .existing => {},
                    }
                    switch (merge.replacement) {
                        .prebuilt => |*replacement| replacement.* =
                            OwnedPayload.empty(replacement.allocator),
                        .coalesced => {},
                    }
                },
                else => {},
            }
            mutation.* = .aborted;
        }
        for (batch.coalesced_replacements[0..batch.replacement_count]) |*replacement|
            replacement.* = OwnedPayload.empty(replacement.allocator);
        batch.* = .{ .lifecycle = .aborted };
        permit.lifecycle = .committed;
        permit.digest = frozenLiveBatchAbortDigest(permit);
    }

    pub fn finishFrozenLiveBatchAbort(
        permit: *FrozenLiveBatchAbort,
    ) AbortLiveResult {
        if (permit.saved_self_addr != @intFromPtr(permit) or
            permit.lifecycle != .committed or
            permit.cleanup_count > max_live_cleanup_owners or
            !std.mem.eql(
                u8,
                &permit.digest,
                &frozenLiveBatchAbortDigest(permit),
            ))
            return .ignored_untrusted;
        var local =
            [_]owner_cleanup.FrozenOwnerCleanupDescriptor{.{}} **
            max_live_cleanup_owners;
        const count = permit.cleanup_count;
        for (permit.cleanup[0..count], 0..) |*descriptor, index|
            owner_cleanup.moveFrozen(descriptor, &local[index]) catch
                return .quarantined;
        permit.lifecycle = .spent;
        permit.digest = frozenLiveBatchAbortDigest(permit);
        var result: AbortLiveResult = .aborted;
        for (local[0..count]) |*descriptor| {
            if (owner_cleanup.finishCallbackHidden(descriptor) != .cleaned) {
                result = .quarantined;
            }
        }
        return result;
    }

    pub fn validateLiveBatchAbortCleanupMove(
        permit: *const FrozenLiveBatchAbort,
        out: []const owner_cleanup.FrozenOwnerCleanupDescriptor,
    ) bool {
        if (permit.saved_self_addr != @intFromPtr(permit) or
            permit.lifecycle != .prepared or
            out.len != permit.cleanup_count or
            !std.mem.eql(
                u8,
                &permit.digest,
                &frozenLiveBatchAbortDigest(permit),
            ) or rangesOverlap(
            rangeOfSlice(
                owner_cleanup.FrozenOwnerCleanupDescriptor,
                permit.cleanup[0..permit.cleanup_count],
            ),
            rangeOfSlice(
                owner_cleanup.FrozenOwnerCleanupDescriptor,
                out,
            ),
        ))
            return false;
        for (permit.cleanup[0..permit.cleanup_count], out) |*source, *destination|
            owner_cleanup.validateMoveFrozen(source, destination) catch
                return false;
        return true;
    }

    pub fn moveCommittedLiveBatchAbortCleanupUnchecked(
        permit: *FrozenLiveBatchAbort,
        out: []owner_cleanup.FrozenOwnerCleanupDescriptor,
    ) void {
        for (permit.cleanup[0..permit.cleanup_count], out) |*source, *destination|
            owner_cleanup.moveFrozenUnchecked(source, destination);
        permit.lifecycle = .spent;
        permit.digest = frozenLiveBatchAbortDigest(permit);
    }

    /// Callback-free mutation leaf. All hostile validation and every fallible branch end in
    /// either the legacy checked entrypoint or the sealed aggregate permit validator before this
    /// function is entered.
    fn commitPreparedLiveBatchUnchecked(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        dispositions: *[max_live_mutations]LiveCommitDisposition,
        simulation: *const LiveSimulation,
        selected_cleanup_count: usize,
        selected_cleanup_bytes: usize,
    ) void {
        retirement.saved_self_addr = @intFromPtr(retirement);
        for (0..batch.mutation_count) |index| {
            switch (batch.mutations[index]) {
                .admission => |*admission| {
                    const token = admission.reserved_token.?;
                    self.slots[token.slot] = .{
                        .active = true,
                        .generation = token.generation,
                        .semantic = storeSemantic(admission.semantic) catch unreachable,
                        .payload = admission.owned_payload.take(),
                    };
                    admission.lifecycle = .committed;
                },
                .merge => |*merge| {
                    const destination_token = liveTokenAtCommit(batch, merge.destination);
                    const destination = &self.slots[destination_token.slot];
                    switch (merge.source) {
                        .owned => |*source| {
                            appendLiveRetirementUnchecked(retirement, source.take());
                        },
                        .existing => |source_ref| {
                            const source_token = liveTokenAtCommit(batch, source_ref);
                            const source_slot = &self.slots[source_token.slot];
                            appendLiveRetirementUnchecked(
                                retirement,
                                source_slot.payload.take(),
                            );
                            source_slot.* = .{ .generation = source_token.generation };
                        },
                    }
                    const result_token = merge.result_token.?;
                    if (simulation.nodes[index].live) {
                        appendLiveRetirementUnchecked(
                            retirement,
                            destination.payload.take(),
                        );
                        var replacement = switch (merge.replacement) {
                            .prebuilt => |*prebuilt| prebuilt.take(),
                            .coalesced => batch.coalesced_replacements[
                                merge.coalesced_replacement_index.?
                            ].take(),
                        };
                        destination.* = .{
                            .active = true,
                            .generation = result_token.generation,
                            .semantic = storeSemantic(merge.next_semantic) catch unreachable,
                            .payload = replacement.take(),
                        };
                    } else {
                        switch (merge.replacement) {
                            .prebuilt => |*prebuilt| {
                                appendLiveRetirementUnchecked(
                                    retirement,
                                    prebuilt.take(),
                                );
                            },
                            .coalesced => {},
                        }
                        destination.generation = result_token.generation;
                        destination.semantic =
                            storeSemantic(merge.next_semantic) catch unreachable;
                    }
                    merge.lifecycle = .committed;
                },
                .release => |*prepared_release| {
                    const token = liveTokenAtCommit(batch, prepared_release.token);
                    const slot = &self.slots[token.slot];
                    appendLiveRetirementUnchecked(retirement, slot.payload.take());
                    slot.* = .{ .generation = token.generation };
                    prepared_release.lifecycle = .committed;
                },
                else => unreachable,
            }
        }
        self.charged_bytes = simulation.charged_bytes;
        self.charged_items = simulation.charged_items;
        self.next_generation = simulation.next_generation;
        self.generation_exhausted = simulation.generation_exhausted;
        self.next_slot_hint = simulation.next_slot_hint;
        if (self.mutation_epoch < std.math.maxInt(u64))
            self.mutation_epoch += 1;
        if (self.generation_exhausted or
            self.mutation_epoch == std.math.maxInt(u64))
            self.planning_disabled = true;
        if (batch.expected_external_identity) |identity| {
            if (self.external_identity_seal.lifecycle == .empty) {
                self.external_identity_seal = makeExternalIdentitySeal(
                    self,
                    identity,
                    1,
                    .bound,
                );
            }
        }

        const cleanup_count_before_dispositions = retirement.cleanup_count;
        const cleanup_bytes_before_dispositions = retirement.cleanup_bytes;
        for (0..batch.mutation_count) |index| {
            switch (dispositions[index]) {
                .final_live => |root| {
                    const live_slot = &self.slots[root.token.slot];
                    appendPublishedReplacementUnchecked(
                        retirement,
                        &live_slot.payload,
                    );
                },
                .cleanup_final => |root| {
                    const live_slot = &self.slots[root.token.slot];
                    const retired_len = live_slot.payload.logical_len;
                    appendLiveRetirementUnchecked(
                        retirement,
                        live_slot.payload.take(),
                    );
                    live_slot.* = .{ .generation = root.token.generation };
                    self.charged_bytes -= retired_len;
                    self.charged_items -= 1;
                    self.next_slot_hint = @min(
                        self.next_slot_hint,
                        @as(usize, root.token.slot),
                    );
                },
                .superseded_tombstone => {},
                .unused => unreachable,
            }
        }
        // `appendLiveRetirementUnchecked` is the sole publisher of cleanup ownership/accounting.
        // The checked permit sealed the totals before this no-fail suffix; these assertions catch
        // implementation drift without introducing a second writer in ReleaseFast.
        std.debug.assert(retirement.cleanup_count ==
            cleanup_count_before_dispositions + selected_cleanup_count);
        std.debug.assert(retirement.cleanup_bytes ==
            cleanup_bytes_before_dispositions + selected_cleanup_bytes);
        if (retirement.cleanup_count == 0) {
            retirement.* = .{ .lifecycle = .retired };
        } else {
            retirement.lifecycle = .prepared;
            retirement.digest = liveRetirementDigest(retirement);
        }
        batch.* = .{ .lifecycle = .committed };
    }

    pub fn abortPreparedLiveBatch(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
    ) AbortLiveResult {
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            (batch.lifecycle != .preparing and batch.lifecycle != .prepared))
            return .ignored_untrusted;
        if (!batchOwnedAbortValid(self, batch)) {
            batch.* = .{ .lifecycle = .aborted };
            return .quarantined;
        }
        var permit: FrozenLiveBatchAbort = .{};
        self.prepareLiveBatchAbort(batch, &permit) catch {
            batch.* = .{ .lifecycle = .aborted };
            return .quarantined;
        };
        if (!self.validatePreparedLiveBatchAbort(batch, &permit)) {
            batch.* = .{ .lifecycle = .aborted };
            return .quarantined;
        }
        self.commitLiveBatchAbortUnchecked(batch, &permit);
        return finishFrozenLiveBatchAbort(&permit);
    }

    fn requirePreparingLiveBatch(
        self: *const ExternalInboxLedger,
        batch: *const PreparedLiveBatch,
    ) PrepareLiveError!void {
        if (batch.saved_self_addr != @intFromPtr(batch) or
            batch.ledger_addr != @intFromPtr(self) or
            batch.lifecycle != .preparing or
            batch.mutation_count > max_live_mutations or
            batch.replacement_count > max_live_mutations or
            !hasCanonicalLiveBatchTails(batch) or
            !std.mem.eql(
                u8,
                &batch.working_simulation_digest,
                &liveSimulationDigest(
                    &batch.working_simulation,
                    batch.mutation_count,
                ),
            ) or
            !std.mem.eql(
                u8,
                &batch.progress_digest,
                &liveProgressDigest(batch),
            ) or
            !std.meta.eql(batch.allocator, batch.sealed_allocator))
            return error.InvalidPlan;
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (self.mutation_epoch != batch.expected_mutation_epoch or
            !std.mem.eql(
                u8,
                &batch.expected_accounting_digest,
                &liveAccountingDigest(self),
            ))
            return error.StalePlan;
    }

    pub fn beginOwnerTeardown(
        self: *ExternalInboxLedger,
        owner_teardown_generation: u64,
        out: *OwnerTeardownPermit,
    ) OwnerTeardownError!void {
        if (rangesOverlap(rangeOfValue(out), rangeOfValue(self)) or
            rangeOverlapsActive(rangeOfValue(out), self))
            return error.InvalidPermit;
        if (owner_teardown_generation == 0 or
            out.saved_self_addr != 0 or out.lifecycle != .empty)
            return error.InvalidPermit;
        if (self.teardown_active or self.draining_or_drained)
            return error.AlreadyFinished;
        const staged: OwnerTeardownPermit = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .owner_teardown_generation = owner_teardown_generation,
            .lifecycle = .prepared,
        };
        out.* = staged;
    }

    pub fn prepareFreezeAllForOwnerTeardown(
        self: *ExternalInboxLedger,
        permit: *OwnerTeardownPermit,
        screen_tokens: *const FrozenScreenTokenPlan,
        out: *PreparedLedgerTeardown,
        frozen_out: *FrozenLedgerCleanup,
    ) OwnerTeardownError!void {
        const out_range = rangeOfValue(out);
        const frozen_out_range = rangeOfValue(frozen_out);
        const permit_range = rangeOfValue(permit);
        const screen_range = rangeOfValue(screen_tokens);
        const ledger_range = rangeOfValue(self);
        if (rangesOverlap(frozen_out_range, ledger_range) or
            rangesOverlap(frozen_out_range, out_range) or
            rangesOverlap(frozen_out_range, permit_range) or
            rangesOverlap(frozen_out_range, screen_range) or
            rangeOverlapsActive(frozen_out_range, self) or
            rangesOverlap(out_range, ledger_range) or
            rangesOverlap(out_range, permit_range) or
            rangesOverlap(out_range, screen_range) or
            rangesOverlap(permit_range, ledger_range) or
            rangesOverlap(screen_range, ledger_range) or
            rangesOverlap(permit_range, screen_range) or
            rangeOverlapsActive(out_range, self) or
            rangeOverlapsActive(permit_range, self) or
            rangeOverlapsActive(screen_range, self))
            return error.InvalidPermit;
        if (!permit.isPreparedFor(self)) return permitError(self, permit);
        if (!screen_tokens.isValid()) return error.InvalidPermit;
        if (out.saved_self_addr != 0 or out.lifecycle != .empty)
            return error.InvalidPermit;
        if (frozen_out.saved_self_addr != 0 or
            frozen_out.lifecycle != .empty or frozen_out.count != 0)
            return error.InvalidPermit;
        if (self.teardown_active) return error.AlreadyFinished;
        if (!self.hasValidAccounting()) return error.InvariantFailure;
        if (self.external_identity_seal.generation == std.math.maxInt(u64))
            return error.InvariantFailure;
        const terminal_identity_generation =
            self.external_identity_seal.generation + 1;
        const terminal_identity_seal = LedgerExternalIdentitySeal{
            .ledger_addr = @intFromPtr(self),
            .identity = null,
            .generation = terminal_identity_generation,
            .lifecycle = .drained_tombstone,
            .digest = externalIdentityDigest(
                @intFromPtr(self),
                null,
                terminal_identity_generation,
                .drained_tombstone,
            ),
        };

        var summary: LedgerTeardownSummary = .{
            .had_invariant = self.invariant_failed,
        };
        var matched = std.StaticBitSet(max_items).initEmpty();
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.active and !slot.retired) {
                if (slot.payload.allocation_ptr != null or
                    slot.payload.logical_len != 0 or
                    !std.meta.eql(slot.semantic, inactiveSemantic()))
                    return error.InvariantFailure;
                continue;
            }
            validatePayload(&slot.payload, slot.payload.logical_len) catch
                return error.InvariantFailure;
            validateSemantic(loadSemantic(slot.semantic), slot.payload.logical_len) catch
                return error.InvariantFailure;
            const owned_range = rangeOfPayload(&slot.payload);
            for (self.slots[slot_index + 1 ..]) |later|
                if ((later.active or later.retired) and rangesOverlap(
                    owned_range,
                    rangeOfPayload(&later.payload),
                )) return error.InvariantFailure;

            var found = false;
            for (screen_tokens.tokens[0..screen_tokens.len], 0..) |token, token_index| {
                if (token.slot != slot_index or token.generation != slot.generation)
                    continue;
                // Screen adoption retains frame/partial/completed payloads as well as later lease
                // payloads. The exact token identity is the ownership proof; restricting teardown
                // to the lease phase would misclassify every freshly adopted screen seed as an
                // orphan before the live-consume transition has had a chance to relabel it.
                const expected_disposition: ScreenTokenDisposition =
                    if (slot.active) .retained else .released;
                if (screen_tokens.dispositions[token_index] == expected_disposition) {
                    found = true;
                    matched.set(token_index);
                } else {
                    summary.had_invariant = true;
                }
                break;
            }
            if (!found) summary.orphan_count += 1;
        }
        for (screen_tokens.dispositions[0..screen_tokens.len], 0..) |disposition, index| {
            if (disposition != .unused and !matched.isSet(index))
                summary.had_invariant = true;
        }
        var retired_count: usize = 0;
        for (screen_tokens.dispositions[0..screen_tokens.len]) |disposition|
            retired_count += @intFromBool(disposition == .released);
        if (retired_count > max_items - self.charged_items)
            return error.InvariantFailure;

        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .permit_addr = @intFromPtr(permit),
            .screen_plan_addr = @intFromPtr(screen_tokens),
            .cleanup_addr = @intFromPtr(frozen_out),
            .expected_mutation_epoch = self.mutation_epoch,
            .expected_charged_items = self.charged_items,
            .expected_charged_bytes = self.charged_bytes,
            .expected_retired_items = self.retired_items,
            .expected_retired_bytes = self.retired_bytes,
            .terminal_external_identity_seal = terminal_identity_seal,
            .summary = summary,
            .lifecycle = .prepared,
        };
    }

    pub fn appendPreparedOwnerTeardownRanges(
        self: *const ExternalInboxLedger,
        prepared: *const PreparedLedgerTeardown,
        out: *owner_range.Scratch,
    ) owner_range.Error!void {
        if (prepared.saved_self_addr != @intFromPtr(prepared) or
            prepared.ledger_addr != @intFromPtr(self) or
            prepared.lifecycle != .prepared or
            prepared.expected_mutation_epoch != self.mutation_epoch or
            prepared.expected_charged_items != self.charged_items or
            prepared.expected_charged_bytes != self.charged_bytes or
            prepared.expected_retired_items != self.retired_items or
            prepared.expected_retired_bytes != self.retired_bytes)
            return error.InvalidRange;
        for (self.slots) |slot| {
            if (!slot.active and !slot.retired) continue;
            const range = rangeOfPayload(&slot.payload);
            try out.append(range.start, range.end - range.start);
        }
    }

    pub fn appendActiveOwnerRanges(
        self: *const ExternalInboxLedger,
        out: *owner_range.Scratch,
    ) owner_range.Error!void {
        if (self.teardown_active or self.draining_or_drained)
            return error.InvalidRange;
        for (self.slots) |slot| {
            if (!slot.active and !slot.retired) continue;
            const range = rangeOfPayload(&slot.payload);
            if (range.start != range.end)
                try out.append(range.start, range.end - range.start);
        }
    }

    /// Boundary-gated no-error ownership barrier. The caller must consume one freshly prepared
    /// capability exactly once; all hostile validation belongs to the fallible prepare phase.
    pub fn commitFreezeAllForOwnerTeardownUnchecked(
        self: *ExternalInboxLedger,
        permit: *OwnerTeardownPermit,
        prepared: *PreparedLedgerTeardown,
        out: *FrozenLedgerCleanup,
    ) LedgerTeardownSummary {
        std.debug.assert(permit.isPreparedFor(self));
        std.debug.assert(prepared.saved_self_addr == @intFromPtr(prepared));
        std.debug.assert(prepared.ledger_addr == @intFromPtr(self));
        std.debug.assert(prepared.permit_addr == @intFromPtr(permit));
        std.debug.assert(prepared.cleanup_addr == @intFromPtr(out));
        std.debug.assert(prepared.lifecycle == .prepared);
        std.debug.assert(prepared.expected_mutation_epoch == self.mutation_epoch);
        std.debug.assert(prepared.expected_charged_items == self.charged_items);
        std.debug.assert(prepared.expected_charged_bytes == self.charged_bytes);
        std.debug.assert(prepared.expected_retired_items == self.retired_items);
        std.debug.assert(prepared.expected_retired_bytes == self.retired_bytes);
        std.debug.assert(prepared.terminal_external_identity_seal.ledger_addr ==
            @intFromPtr(self));
        std.debug.assert(out.saved_self_addr == 0 and out.lifecycle == .empty);

        out.saved_self_addr = @intFromPtr(out);
        out.lifecycle = .frozen;
        for (&self.slots) |*slot| {
            if (slot.active or slot.retired) {
                out.payloads[out.count] = slot.payload.take();
                out.count += 1;
            }
            slot.* = .{ .generation = slot.generation };
        }
        self.external_identity_seal = prepared.terminal_external_identity_seal;
        self.charged_bytes = 0;
        self.charged_items = 0;
        self.retired_bytes = 0;
        self.retired_items = 0;
        self.next_slot_hint = 0;
        self.next_generation = 1;
        self.generation_exhausted = false;
        self.mutation_epoch = 0;
        self.planning_disabled = true;
        self.invariant_failed = false;
        self.draining_or_drained = true;
        self.teardown_active = true;
        self.owner_teardown_generation = permit.owner_teardown_generation;
        permit.lifecycle = .consumed;
        prepared.lifecycle = .consumed;
        permit.lifecycle = .finished;
        return prepared.summary;
    }

    /// Re-publishes the callback-safe terminal ledger image after every frozen payload has been
    /// retired. Allocator callbacks are allowed to mutate the enclosing aggregate, so the pump
    /// must not reconstruct private ledger fields itself or trust the image left by those
    /// callbacks. This leaf is no-fail because the matching generation was already sealed by
    /// `prepareFreezeAllForOwnerTeardown` and committed before any callback became observable.
    pub fn restoreFinishedOwnerTeardownUnchecked(
        self: *ExternalInboxLedger,
        owner_teardown_generation: u64,
        external_identity_generation: u64,
    ) void {
        std.debug.assert(owner_teardown_generation != 0);
        std.debug.assert(external_identity_generation != 0);
        for (&self.slots) |*slot| slot.* = .{};
        self.external_identity_seal = .{
            .ledger_addr = @intFromPtr(self),
            .identity = null,
            .generation = external_identity_generation,
            .lifecycle = .drained_tombstone,
            .digest = externalIdentityDigest(
                @intFromPtr(self),
                null,
                external_identity_generation,
                .drained_tombstone,
            ),
        };
        self.charged_bytes = 0;
        self.charged_items = 0;
        self.retired_bytes = 0;
        self.retired_items = 0;
        self.next_slot_hint = 0;
        self.next_generation = 1;
        self.generation_exhausted = false;
        self.mutation_epoch = 0;
        self.planning_disabled = true;
        self.invariant_failed = false;
        self.draining_or_drained = true;
        self.teardown_active = true;
        self.owner_teardown_generation = owner_teardown_generation;
    }

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
        const next_resident = std.math.add(usize, self.residentBytes(), payload.logical_len) catch
            return error.ByteCapExceeded;
        if (next_resident > max_bytes) return error.ByteCapExceeded;
        const next_charged = std.math.add(
            usize,
            self.charged_bytes,
            payload.logical_len,
        ) catch return error.ByteCapExceeded;
        if (self.residentItems() >= max_items) return error.ItemCapExceeded;
        const slot_index = self.findFreeSlot() orelse return error.ItemCapExceeded;
        const generation = try self.prepareGeneration();

        self.slots[slot_index] = .{
            .active = true,
            .generation = generation,
            .semantic = try storeSemantic(tagged),
            .payload = payload.take(),
        };
        self.charged_bytes = next_charged;
        self.charged_items += 1;
        self.next_slot_hint = (slot_index + 1) % max_items;
        self.commitAuthorityMutation();
        return .{ .slot = @intCast(slot_index), .generation = generation };
    }

    pub fn prepareScreenRetirement(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
        out: *PreparedScreenRetirement,
    ) ScreenRetirementError!void {
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (out.saved_self_addr != 0 or out.lifecycle != .empty or
            rangesOverlap(rangeOfValue(out), rangeOfValue(self)) or
            rangeOverlapsActive(rangeOfValue(out), self))
            return error.InvalidRetirement;
        if (!self.hasValidAccounting() or self.invariant_failed)
            return error.InvariantFailure;
        if (@as(usize, token.slot) >= max_items) return error.InvariantFailure;
        const slot = &self.slots[token.slot];
        if (!slot.active or slot.generation != token.generation)
            return error.StaleRetirement;
        if (std.meta.activeTag(slot.semantic) != expected_phase)
            return error.InvariantFailure;
        validatePayload(&slot.payload, slot.payload.logical_len) catch
            return error.InvariantFailure;
        if (rangeOverlapsActiveExceptSlot(
            rangeOfPayload(&slot.payload),
            self,
            token.slot,
        )) return error.InvariantFailure;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .ledger_addr = @intFromPtr(self),
            .token = token,
            .expected_phase = expected_phase,
            .expected_mutation_epoch = self.mutation_epoch,
            .expected_charged_bytes = self.charged_bytes,
            .expected_retired_bytes = self.retired_bytes,
            .lifecycle = .prepared,
        };
    }

    pub fn commitScreenRetirementUnchecked(
        self: *ExternalInboxLedger,
        prepared: *PreparedScreenRetirement,
    ) void {
        std.debug.assert(prepared.saved_self_addr == @intFromPtr(prepared));
        std.debug.assert(prepared.ledger_addr == @intFromPtr(self));
        std.debug.assert(prepared.lifecycle == .prepared);
        std.debug.assert(prepared.expected_mutation_epoch == self.mutation_epoch);
        std.debug.assert(prepared.expected_charged_bytes == self.charged_bytes);
        std.debug.assert(prepared.expected_retired_bytes == self.retired_bytes);
        const slot = &self.slots[prepared.token.slot];
        std.debug.assert(slot.active and
            slot.generation == prepared.token.generation and
            std.meta.activeTag(slot.semantic) == prepared.expected_phase);
        const charged = slot.payload.logical_len;
        slot.active = false;
        slot.retired = true;
        self.charged_bytes -= charged;
        self.charged_items -= 1;
        self.retired_bytes += charged;
        self.retired_items += 1;
        self.next_slot_hint = prepared.token.slot;
        self.commitCleanupMutation();
        prepared.lifecycle = .consumed;
    }

    pub fn commitSeeds(
        self: *ExternalInboxLedger,
        plan: *PreparedSeedPlan,
        payloads: []OwnedPayload,
        token_output: []Token,
    ) CommitError!void {
        var retirement: PreparedSeedRetirement = .{};
        try self.commitSeedsDeferredRetirement(
            plan,
            payloads,
            token_output,
            &retirement,
        );
        retirement.retire();
    }

    /// Same ledger transaction as `commitSeeds`, but deliberately performs no allocator callback
    /// on success. The caller must retire `retirement` only after its unchecked publication suffix
    /// has tombstoned every source graph.
    pub fn commitSeedsDeferredRetirement(
        self: *ExternalInboxLedger,
        plan: *PreparedSeedPlan,
        payloads: []OwnedPayload,
        token_output: []Token,
        retirement: *PreparedSeedRetirement,
    ) CommitError!void {
        if (!retirement.isEmpty()) return error.InvalidPlan;
        if (!plan.isStablePrepared() or plan.ledger_addr != @intFromPtr(self))
            return error.InvalidPlan;
        if (plan.entries.len != payloads.len or token_output.len != payloads.len)
            return error.InvalidPlan;
        const payload_wrappers_addr = if (payloads.len == 0) 0 else @intFromPtr(payloads.ptr);
        if (plan.payload_wrappers_addr != payload_wrappers_addr) return error.InvalidPlan;
        if (plan.entries.len == 0) {
            if (self.teardown_active) return error.TeardownActive;
            if (self.draining_or_drained) return error.Drained;
            if (self.invariant_failed or self.planning_disabled)
                return error.PlanningDisabled;
            if (!self.hasValidAccounting()) {
                self.invariant_failed = true;
                self.planning_disabled = true;
                return error.InvariantFailure;
            }
            if (self.mutation_epoch != plan.expected_mutation_epoch) return error.StalePlan;
            plan.finishCommitDeferred(retirement);
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
        const next_resident = std.math.add(usize, self.residentBytes(), total_bytes) catch
            return error.ByteCapExceeded;
        if (next_resident > max_bytes) return error.ByteCapExceeded;
        const next_charged = std.math.add(
            usize,
            self.charged_bytes,
            total_bytes,
        ) catch return error.ByteCapExceeded;
        if (plan.entries.len > max_items - self.residentItems()) return error.ItemCapExceeded;

        for (plan.entries, payloads, token_output) |entry, *payload, *output| {
            self.slots[entry.slot] = .{
                .active = true,
                .generation = entry.generation,
                .semantic = storeSemantic(entry.spec.semantic) catch unreachable,
                .payload = payload.take(),
            };
            output.* = .{ .slot = entry.slot, .generation = entry.generation };
        }
        self.charged_bytes = next_charged;
        self.charged_items += plan.entries.len;
        self.next_generation = next_generation;
        self.generation_exhausted = generation_exhausted;
        self.next_slot_hint = next_hint;
        self.commitSeedMutation();
        plan.finishCommitDeferred(retirement);
    }

    pub fn borrow(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
    ) InvariantError!PayloadView {
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (self.invariant_failed) return error.InvariantFailure;
        const slot = try self.resolveActive(token);
        const stored_semantic = loadSemantic(slot.semantic);
        if (std.meta.activeTag(stored_semantic) != expected_phase) return self.failInvariant();
        const payload = slot.payload;
        return .{
            .phase = std.meta.activeTag(stored_semantic),
            .semantic = self.observeSemantic(stored_semantic) catch
                return self.failInvariant(),
            .bytes = payload.bytes(),
        };
    }

    pub fn borrowLease(
        self: *ExternalInboxLedger,
        token: Token,
    ) InvariantError!BatchView {
        const view = try self.borrow(token, .lease);
        const semantic = view.semantic.lease;
        const recovery_key = switch (semantic.recovery_intent) {
            .none => null,
            .host, .client => blk: {
                const identity = switch (semantic.provenance) {
                    .untracked => return self.failInvariant(),
                    .external => |range| range.identity,
                };
                const key = semantic.recovery_intent.key(
                    identity.attach_instance_id,
                    token.generation,
                ) orelse return self.failInvariant();
                break :blk key;
            },
        };
        return .{
            .is_snapshot = semantic.is_snapshot,
            .stream_id = semantic.stream_id,
            .provenance = semantic.provenance,
            .recovery_key = recovery_key,
            .bytes = view.bytes,
        };
    }

    pub fn partialSnapshot(
        self: *const ExternalInboxLedger,
        token: Token,
    ) InvariantError!ObservedPartialSemantic {
        if (self.teardown_active) return error.TeardownActive;
        if (self.draining_or_drained) return error.Drained;
        if (self.invariant_failed or !self.hasValidAccounting())
            return error.InvariantFailure;
        if (@as(usize, token.slot) >= max_items) return error.InvariantFailure;
        const slot = &self.slots[token.slot];
        if (!slot.active or slot.generation != token.generation or
            std.meta.activeTag(slot.semantic) != .partial)
            return error.InvariantFailure;
        return self.observePartial(loadSemantic(slot.semantic).partial) catch
            return error.InvariantFailure;
    }

    pub fn validateExternalIdentityForLivePrepare(
        self: *const ExternalInboxLedger,
        identity: external_rx_types.RxIdentity,
    ) error{InvalidSemantic}!void {
        try validateRxIdentity(identity);
        switch (self.external_identity_seal.lifecycle) {
            .empty => {
                if (!isCanonicalEmptyIdentitySeal(self.external_identity_seal))
                    return error.InvalidSemantic;
            },
            .bound => {
                if (!self.hasValidExternalIdentitySeal() or
                    !std.meta.eql(self.external_identity_seal.identity.?, identity))
                    return error.InvalidSemantic;
            },
            .drained_tombstone => return error.InvalidSemantic,
        }
    }

    pub fn observeProvenance(
        self: *const ExternalInboxLedger,
        provenance: StoredRxBatchProvenance,
    ) error{InvalidSemantic}!ObservedRxBatchProvenance {
        return switch (provenance) {
            .untracked => .untracked,
            .external => |compact| blk: {
                if (!self.hasValidExternalIdentitySeal() or
                    self.external_identity_seal.lifecycle != .bound)
                    return error.InvalidSemantic;
                try validateCompactExternalRange(compact);
                const end_absolute = std.math.add(
                    u64,
                    compact.start_absolute,
                    compact.span,
                ) catch return error.InvalidSemantic;
                break :blk .{ .external = .{
                    .identity = self.external_identity_seal.identity.?,
                    .start_absolute = compact.start_absolute,
                    .end_absolute = end_absolute,
                } };
            },
        };
    }

    fn observeBatch(
        self: *const ExternalInboxLedger,
        semantic: BatchSemantic,
    ) error{InvalidSemantic}!ObservedBatchSemantic {
        return .{
            .stream_id = semantic.stream_id,
            .is_snapshot = semantic.is_snapshot,
            .recovery_intent = semantic.recovery_intent,
            .provenance = try self.observeProvenance(semantic.provenance),
        };
    }

    fn observePartial(
        self: *const ExternalInboxLedger,
        semantic: PartialSemantic,
    ) error{InvalidSemantic}!ObservedPartialSemantic {
        return .{
            .stream_id = semantic.stream_id,
            .is_snapshot = semantic.is_snapshot,
            .chunk_count = semantic.chunk_count,
            .recovery_intent = semantic.recovery_intent,
            .provenance = try self.observeProvenance(semantic.provenance),
        };
    }

    fn observeSemantic(
        self: *const ExternalInboxLedger,
        semantic: PayloadSemantic,
    ) error{InvalidSemantic}!ObservedPayloadSemantic {
        return switch (semantic) {
            .frame => |header| .{ .frame = header },
            .partial => |partial| .{ .partial = try self.observePartial(partial) },
            .completed => |batch| .{ .completed = try self.observeBatch(batch) },
            .lease => |batch| .{ .lease = try self.observeBatch(batch) },
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
        const current = loadSemantic(slot.semantic);
        if (std.meta.activeTag(current) != expected_phase) return self.failInvariant();
        const next = try relabeledSemantic(current, next_phase, recovery_intent);
        try validateSemantic(next, slot.payload.logical_len);
        const generation = try self.prepareGeneration();
        slot.semantic = try storeSemantic(next);
        slot.generation = generation;
        self.commitAuthorityMutation();
        return .{ .slot = token.slot, .generation = generation };
    }

    fn commitPreparedLegacyMerge(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
        token_out: *Token,
    ) CommitLiveError!void {
        if (batch.mutation_count != 1 or
            std.meta.activeTag(batch.mutations[0]) != .merge)
            return error.InvalidPlan;
        const simulation = simulateLiveBatch(self, batch, 1) catch |err|
            return mapPrepareToCommitLive(err);
        if (!simulation.nodes[0].live) return error.InvalidPlan;
        switch (std.meta.activeTag(simulation.nodes[0].semantic)) {
            .partial, .completed => {},
            else => return error.InvalidPlan,
        }
        var dispositions =
            [_]LiveCommitDisposition{.unused} ** max_live_mutations;
        const final_count = try self.commitPreparedLiveBatch(
            batch,
            retirement,
            &dispositions,
        );
        std.debug.assert(final_count == 1);
        token_out.* = switch (dispositions[0]) {
            .final_live => |root| root.token,
            else => unreachable,
        };
        dispositions[0] = .superseded_tombstone;
    }

    fn commitPreparedLegacyRelease(
        self: *ExternalInboxLedger,
        batch: *PreparedLiveBatch,
        retirement: *PreparedLiveRetirement,
    ) CommitLiveError!void {
        if (batch.mutation_count != 1 or
            std.meta.activeTag(batch.mutations[0]) != .release)
            return error.InvalidPlan;
        const simulation = simulateLiveBatch(self, batch, 1) catch |err|
            return mapPrepareToCommitLive(err);
        if (simulation.nodes[0].live) return error.InvalidPlan;
        var dispositions =
            [_]LiveCommitDisposition{.unused} ** max_live_mutations;
        const final_count = try self.commitPreparedLiveBatch(
            batch,
            retirement,
            &dispositions,
        );
        std.debug.assert(final_count == 0);
        std.debug.assert(dispositions[0] == .superseded_tombstone);
        dispositions[0] = .superseded_tombstone;
    }

    pub fn mergeInto(
        self: *ExternalInboxLedger,
        dst_token: Token,
        src_token: Token,
        replacement: *OwnedPayload,
        next_phase: PayloadPhase,
        expected_recovery_intent: RecoveryIntent,
    ) TransitionError!Token {
        const dst = pureSlot(self, dst_token) catch return self.failInvariant();
        const src = pureSlot(self, src_token) catch return self.failInvariant();
        if (dst_token.slot == src_token.slot) return error.InvalidAlias;
        if (std.meta.activeTag(dst.semantic) != .partial or
            std.meta.activeTag(src.semantic) != .frame)
            return self.failInvariant();
        const dst_semantic = dst.semantic.partial;
        const src_header = src.semantic.frame;
        if (!std.meta.eql(dst_semantic.recovery_intent, expected_recovery_intent))
            return error.InvalidSemantic;
        const end_stream = protocol.Flags.hasEndStream(src_header.flags);
        if ((end_stream and next_phase != .completed) or
            (!end_stream and next_phase != .partial))
            return error.InvalidTransition;
        const next_batch: BatchSemantic = .{
            .stream_id = dst_semantic.stream_id,
            .is_snapshot = dst_semantic.is_snapshot,
            .recovery_intent = dst_semantic.recovery_intent,
            .provenance = dst_semantic.provenance,
        };
        const next_semantic: PayloadSemantic = if (next_phase == .partial)
            .{ .partial = .{
                .stream_id = next_batch.stream_id,
                .is_snapshot = next_batch.is_snapshot,
                .chunk_count = dst_semantic.chunk_count + 1,
                .recovery_intent = next_batch.recovery_intent,
                .provenance = next_batch.provenance,
            } }
        else
            .{ .completed = next_batch };

        var batch: PreparedLiveBatch = .{};
        self.beginLiveBatch(&batch, replacement.allocator, null) catch |err|
            return mapPrepareToTransition(err);
        var source: PreparedLiveMergeSource = .{ .existing = .{
            .existing = src_token,
        } };
        var prepared_replacement: PreparedLiveReplacement =
            .{ .prebuilt = replacement.* };
        self.prepareLiveMerge(
            &batch,
            .{ .existing = dst_token },
            next_semantic,
            null,
            &source,
            &prepared_replacement,
        ) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapPrepareToTransition(err);
        };
        replacement.* = .{ .allocator = replacement.allocator };
        self.finishLiveBatch(&batch) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapPrepareToTransition(err);
        };
        var retirement = PreparedLiveRetirement.init(replacement.allocator);
        var token: Token = undefined;
        self.commitPreparedLegacyMerge(
            &batch,
            &retirement,
            &token,
        ) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapCommitToTransition(err);
        };
        const retire_result = retirement.retire();
        if (retire_result == .quarantined) return error.InvariantFailure;
        return token;
    }

    pub fn release(
        self: *ExternalInboxLedger,
        token: Token,
        expected_phase: PayloadPhase,
    ) InvariantError!void {
        const inspected = pureSlot(self, token) catch return error.InvariantFailure;
        switch (inspected.semantic) {
            .partial => |semantic| if (semantic.provenance != .untracked)
                return error.InvariantFailure,
            .completed, .lease => |semantic| if (semantic.provenance != .untracked)
                return error.InvariantFailure,
            .frame => {},
        }
        var batch: PreparedLiveBatch = .{};
        self.beginLiveCleanupBatch(&batch) catch |err|
            return mapPrepareToInvariant(err);
        self.prepareLiveRelease(
            &batch,
            .{ .existing = token },
            expected_phase,
        ) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapPrepareToInvariant(err);
        };
        self.finishLiveBatch(&batch) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapPrepareToInvariant(err);
        };
        var retirement = PreparedLiveRetirement.init(std.heap.page_allocator);
        self.commitPreparedLegacyRelease(
            &batch,
            &retirement,
        ) catch |err| {
            _ = self.abortPreparedLiveBatch(&batch);
            return mapCommitToInvariant(err);
        };
        if (retirement.retire() == .quarantined)
            return error.InvariantFailure;
    }

    pub fn releaseLease(
        self: *ExternalInboxLedger,
        token: Token,
    ) InvariantError!void {
        return self.release(token, .lease);
    }

    pub fn drainAll(self: *ExternalInboxLedger) DrainError!DrainReport {
        if (self.teardown_active) return error.TeardownActive;
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
        const identity_generation_overflow =
            self.tombstoneExternalIdentityUnchecked();
        var active_count: usize = 0;
        var bytes: usize = 0;
        var anomaly = self.invariant_failed or identity_generation_overflow;
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
                validateSemantic(loadSemantic(slot.semantic), slot.payload.logical_len) catch {
                    anomaly = true;
                };
            } else if (slot.retired) {
                validatePayload(&slot.payload, slot.payload.logical_len) catch {
                    anomaly = true;
                };
                validateSemantic(loadSemantic(slot.semantic), slot.payload.logical_len) catch {
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
        self.retired_items = 0;
        self.retired_bytes = 0;
        self.next_slot_hint = 0;
        self.invariant_failed = anomaly;
        return .{
            .drained_active_count = active_count,
            .drained_bytes = bytes,
            .had_sticky_invariant = anomaly,
        };
    }

    pub fn finish(self: *ExternalInboxLedger) FinishError!void {
        if (self.teardown_active) return error.TeardownActive;
        if (self.invariant_failed) return error.InvariantFailure;
        if (self.charged_bytes != 0 or self.charged_items != 0) return error.ActiveCharges;
        for (self.slots) |slot| {
            if (slot.active or slot.retired or slot.payload.allocation_ptr != null or
                slot.payload.logical_len != 0 or !std.meta.eql(slot.semantic, inactiveSemantic()))
                return error.ActiveCharges;
        }
    }

    pub fn accountingView(self: *const ExternalInboxLedger) AccountingView {
        const valid = self.hasValidAccounting();
        return .{
            .charged_bytes = self.charged_bytes,
            .charged_items = self.charged_items,
            .retired_bytes = self.retired_bytes,
            .retired_items = self.retired_items,
            .mutation_epoch = self.mutation_epoch,
            .next_generation = self.next_generation,
            .next_slot_hint = self.next_slot_hint,
            .generation_exhausted = self.generation_exhausted,
            .planning_disabled = self.planning_disabled,
            .invariant_failed = self.invariant_failed,
            .draining_or_drained = self.draining_or_drained,
            .valid = valid,
            .pristine_zero = valid and self.hasPristineZeroState(),
        };
    }

    /// Read-only alias preflight for an aggregate owner operation. It deliberately exposes only a
    /// boolean so callers cannot recover payload addresses from the ledger.
    pub fn overlapsOwnedRange(self: *const ExternalInboxLedger, addr: usize, len: usize) bool {
        const range = ByteRange{
            .start = addr,
            .end = std.math.add(usize, addr, len) catch return true,
        };
        return rangesOverlap(range, rangeOfValue(self)) or rangeOverlapsActive(range, self);
    }

    /// Allocation-free drift seal for callback-scoped aggregate validation. It hashes descriptors
    /// and allocator authority only; payload bytes remain owned and are never dereferenced.
    pub fn projectionAuthorityDigest(self: *const ExternalInboxLedger) owner_seal.Digest {
        var writer = owner_seal.Writer.init("MARULPA1");
        writer.writeUsize(@intFromPtr(self));
        writer.writeUsize(self.external_identity_seal.ledger_addr);
        if (self.external_identity_seal.identity) |identity| {
            writer.writeBool(true);
            writer.writeU64(identity.attach_instance_id);
            writer.writeUsize(identity.destination_slot_addr);
        } else {
            writer.writeBool(false);
        }
        writer.writeU64(self.external_identity_seal.generation);
        writer.writeU8(@intFromEnum(self.external_identity_seal.lifecycle));
        writer.writeBytes(&self.external_identity_seal.digest);
        writer.writeUsize(self.charged_bytes);
        writer.writeUsize(self.charged_items);
        writer.writeUsize(self.retired_bytes);
        writer.writeUsize(self.retired_items);
        writer.writeUsize(self.next_slot_hint);
        writer.writeU64(self.next_generation);
        writer.writeBool(self.generation_exhausted);
        writer.writeU64(self.mutation_epoch);
        writer.writeBool(self.planning_disabled);
        writer.writeBool(self.invariant_failed);
        writer.writeBool(self.draining_or_drained);
        writer.writeBool(self.teardown_active);
        for (&self.slots) |*slot| {
            writer.writeBool(slot.active);
            writer.writeBool(slot.retired);
            writer.writeU64(slot.generation);
            writer.writeU8(@intFromEnum(std.meta.activeTag(slot.semantic)));
            switch (loadSemantic(slot.semantic)) {
                .frame => |header| {
                    const encoded = header.encode();
                    writer.writeBytes(&encoded);
                },
                .partial => |semantic| {
                    writer.writeU64(semantic.stream_id);
                    writer.writeBool(semantic.is_snapshot);
                    writer.writeU8(semantic.chunk_count);
                    writeRecoveryIntent(&writer, semantic.recovery_intent);
                    writeStoredProvenance(&writer, semantic.provenance);
                },
                .completed, .lease => |semantic| {
                    writer.writeU64(semantic.stream_id);
                    writer.writeBool(semantic.is_snapshot);
                    writeRecoveryIntent(&writer, semantic.recovery_intent);
                    writeStoredProvenance(&writer, semantic.provenance);
                },
            }
            writer.writeUsize(@intFromPtr(slot.payload.allocator.ptr));
            writer.writeUsize(@intFromPtr(slot.payload.allocator.vtable));
            writer.writeUsize(if (slot.payload.allocation_ptr) |ptr|
                @intFromPtr(ptr)
            else
                0);
            writer.writeUsize(slot.payload.logical_len);
        }
        return writer.finish();
    }

    fn ensureAuthorityMutation(self: *ExternalInboxLedger) error{
        EpochExhausted,
        InvariantFailure,
        PlanningDisabled,
        Drained,
        TeardownActive,
    }!void {
        if (self.teardown_active) return error.TeardownActive;
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
            error.TeardownActive => error.TeardownActive,
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
            if (!self.slots[index].active and !self.slots[index].retired) return index;
        }
        return null;
    }

    fn residentBytes(self: *const ExternalInboxLedger) usize {
        return self.charged_bytes +| self.retired_bytes;
    }

    fn residentItems(self: *const ExternalInboxLedger) usize {
        return self.charged_items +| self.retired_items;
    }

    fn hasValidAccounting(self: *const ExternalInboxLedger) bool {
        if (self.residentItems() > max_items or self.residentBytes() > max_bytes or
            self.next_slot_hint >= max_items or !self.hasValidExternalIdentitySeal())
            return false;
        var items: usize = 0;
        var bytes: usize = 0;
        var retired_items: usize = 0;
        var retired_bytes: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) {
                if (slot.retired) return false;
                items = std.math.add(usize, items, 1) catch return false;
                bytes = std.math.add(usize, bytes, slot.payload.logical_len) catch return false;
            } else if (slot.retired) {
                validatePayload(&slot.payload, slot.payload.logical_len) catch return false;
                validateSemantic(loadSemantic(slot.semantic), slot.payload.logical_len) catch return false;
                retired_items = std.math.add(usize, retired_items, 1) catch return false;
                retired_bytes = std.math.add(
                    usize,
                    retired_bytes,
                    slot.payload.logical_len,
                ) catch return false;
            } else if (slot.payload.allocation_ptr != null or slot.payload.logical_len != 0 or
                !std.meta.eql(slot.semantic, inactiveSemantic()))
            {
                return false;
            }
        }
        return items == self.charged_items and bytes == self.charged_bytes and
            retired_items == self.retired_items and retired_bytes == self.retired_bytes;
    }

    fn hasPristineZeroState(self: *const ExternalInboxLedger) bool {
        if (self.charged_bytes != 0 or self.charged_items != 0 or
            self.retired_bytes != 0 or self.retired_items != 0 or
            self.next_slot_hint != 0 or self.next_generation != 1 or
            self.generation_exhausted or self.mutation_epoch != 0 or
            self.planning_disabled or self.invariant_failed or self.draining_or_drained or
            !isCanonicalEmptyIdentitySeal(self.external_identity_seal))
            return false;
        for (self.slots) |slot| {
            if (slot.active or slot.retired or slot.generation != 0 or
                slot.payload.allocation_ptr != null or slot.payload.logical_len != 0 or
                !std.meta.eql(slot.semantic, inactiveSemantic()))
                return false;
        }
        return true;
    }

    fn hasValidExternalIdentitySeal(self: *const ExternalInboxLedger) bool {
        const seal = self.external_identity_seal;
        return switch (seal.lifecycle) {
            .empty => isCanonicalEmptyIdentitySeal(seal),
            .bound => blk: {
                const identity = seal.identity orelse break :blk false;
                validateRxIdentity(identity) catch break :blk false;
                if (seal.ledger_addr != @intFromPtr(self) or seal.generation == 0)
                    break :blk false;
                break :blk std.mem.eql(
                    u8,
                    &seal.digest,
                    &externalIdentityDigest(
                        seal.ledger_addr,
                        identity,
                        seal.generation,
                        seal.lifecycle,
                    ),
                );
            },
            .drained_tombstone => blk: {
                if (seal.ledger_addr != @intFromPtr(self) or
                    seal.identity != null or seal.generation == 0)
                    break :blk false;
                break :blk std.mem.eql(
                    u8,
                    &seal.digest,
                    &externalIdentityDigest(
                        seal.ledger_addr,
                        null,
                        seal.generation,
                        seal.lifecycle,
                    ),
                );
            },
        };
    }

    fn tombstoneExternalIdentityUnchecked(self: *ExternalInboxLedger) bool {
        const current = self.external_identity_seal;
        const overflow = current.generation == std.math.maxInt(u64);
        const generation = if (overflow)
            current.generation
        else
            current.generation + 1;
        self.external_identity_seal = .{
            .ledger_addr = @intFromPtr(self),
            .identity = null,
            .generation = generation,
            .lifecycle = .drained_tombstone,
            .digest = externalIdentityDigest(
                @intFromPtr(self),
                null,
                generation,
                .drained_tombstone,
            ),
        };
        return overflow;
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

pub const projection_test = if (builtin.is_test) struct {
    pub fn bindExternalIdentityForTest(
        ledger: *ExternalInboxLedger,
        identity: external_rx_types.RxIdentity,
    ) void {
        ledger.external_identity_seal = makeExternalIdentitySeal(
            ledger,
            identity,
            1,
            .bound,
        );
    }

    /// Test-only hostile callback seam. Product code cannot name ledger slots directly.
    pub fn driftFirstActiveGeneration(ledger: *ExternalInboxLedger) bool {
        for (&ledger.slots) |*slot| {
            if (!slot.active) continue;
            slot.generation +%= 1;
            return true;
        }
        return false;
    }
} else struct {};

fn permitError(
    ledger: *const ExternalInboxLedger,
    permit: *const OwnerTeardownPermit,
) OwnerTeardownError {
    if (permit.saved_self_addr != @intFromPtr(permit) or
        permit.owner_teardown_generation == 0 or permit.lifecycle == .empty)
        return error.InvalidPermit;
    if (permit.ledger_addr != @intFromPtr(ledger)) return error.WrongLedger;
    return switch (permit.lifecycle) {
        .consumed => error.StalePermit,
        .finished => error.AlreadyFinished,
        .empty => error.InvalidPermit,
        .prepared => error.StalePermit,
    };
}

const ByteRange = struct {
    start: usize,
    end: usize,

    fn empty() ByteRange {
        return .{ .start = 0, .end = 0 };
    }
};

fn checkedAddressRange(start: usize, len: usize) error{ InvalidAlias, InvalidPlan }!ByteRange {
    if (start == 0 or len == 0) return error.InvalidPlan;
    const end = std.math.add(usize, start, len) catch return error.InvalidAlias;
    return .{ .start = start, .end = end };
}

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
    var writer = owner_seal.Writer.init("MARULPF1");
    writer.writeBytes(payload.bytes());
    return .{
        .allocator = payload.allocator,
        .address = if (payload.allocation_ptr) |ptr| @intFromPtr(ptr) else 0,
        .logical_len = payload.logical_len,
        .content_digest = writer.finish(),
    };
}

fn fingerprintMatches(expected: PayloadFingerprint, actual: OwnedPayload) bool {
    if (!payloadDescriptorMatches(expected, actual)) return false;
    var writer = owner_seal.Writer.init("MARULPF1");
    writer.writeBytes(actual.bytes());
    const content_digest = writer.finish();
    return std.mem.eql(
        u8,
        &expected.content_digest,
        &content_digest,
    );
}

fn payloadDescriptorMatches(
    expected: PayloadFingerprint,
    actual: OwnedPayload,
) bool {
    const address = if (actual.allocation_ptr) |ptr| @intFromPtr(ptr) else 0;
    return expected.address == address and
        expected.logical_len == actual.logical_len and
        std.meta.eql(expected.allocator, actual.allocator);
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

fn validateStoredProvenance(
    provenance: StoredRxBatchProvenance,
) error{InvalidSemantic}!void {
    switch (provenance) {
        .untracked => {},
        .external => |range| try validateCompactExternalRange(range),
    }
}

fn storedRecovery(intent: RecoveryIntent) StoredBatchSemantic {
    var result: StoredBatchSemantic = .{
        .stream_id = 0,
        .provenance_start_absolute = 0,
        .recovery_epoch = 0,
        .provenance_span = 0,
        .chunk_count = 0,
        .is_snapshot = false,
        .provenance_external = false,
        .recovery_tag = .none,
    };
    switch (intent) {
        .none => {},
        .host => |epoch| {
            result.recovery_tag = .host;
            result.recovery_epoch = epoch;
        },
        .client => |epoch| {
            result.recovery_tag = .client;
            result.recovery_epoch = epoch;
        },
    }
    return result;
}

fn loadRecovery(stored: StoredBatchSemantic) RecoveryIntent {
    return switch (stored.recovery_tag) {
        .none => .none,
        .host => .{ .host = stored.recovery_epoch },
        .client => .{ .client = stored.recovery_epoch },
    };
}

fn storeBatchSemantic(
    semantic: BatchSemantic,
    chunk_count: u8,
) error{InvalidSemantic}!StoredBatchSemantic {
    try validateRecoveryIntent(semantic.recovery_intent);
    try validateStoredProvenance(semantic.provenance);
    var stored = storedRecovery(semantic.recovery_intent);
    stored.stream_id = semantic.stream_id;
    stored.chunk_count = chunk_count;
    stored.is_snapshot = semantic.is_snapshot;
    switch (semantic.provenance) {
        .untracked => {},
        .external => |range| {
            stored.provenance_external = true;
            stored.provenance_start_absolute = range.start_absolute;
            stored.provenance_span = range.span;
        },
    }
    return stored;
}

fn loadBatchSemantic(stored: StoredBatchSemantic) BatchSemantic {
    return .{
        .stream_id = stored.stream_id,
        .is_snapshot = stored.is_snapshot,
        .recovery_intent = loadRecovery(stored),
        .provenance = if (stored.provenance_external)
            .{ .external = .{
                .start_absolute = stored.provenance_start_absolute,
                .span = stored.provenance_span,
            } }
        else
            .untracked,
    };
}

fn storeSemantic(
    semantic: PayloadSemantic,
) error{InvalidSemantic}!StoredPayloadSemantic {
    return switch (semantic) {
        .frame => |header| .{ .frame = header },
        .partial => |partial| .{ .partial = try storeBatchSemantic(
            .{
                .stream_id = partial.stream_id,
                .is_snapshot = partial.is_snapshot,
                .recovery_intent = partial.recovery_intent,
                .provenance = partial.provenance,
            },
            partial.chunk_count,
        ) },
        .completed => |batch| .{ .completed = try storeBatchSemantic(batch, 0) },
        .lease => |batch| .{ .lease = try storeBatchSemantic(batch, 0) },
    };
}

fn loadSemantic(semantic: StoredPayloadSemantic) PayloadSemantic {
    return switch (semantic) {
        .frame => |header| .{ .frame = header },
        .partial => |stored| blk: {
            const batch = loadBatchSemantic(stored);
            break :blk .{ .partial = .{
                .stream_id = batch.stream_id,
                .is_snapshot = batch.is_snapshot,
                .chunk_count = stored.chunk_count,
                .recovery_intent = batch.recovery_intent,
                .provenance = batch.provenance,
            } };
        },
        .completed => |stored| .{ .completed = loadBatchSemantic(stored) },
        .lease => |stored| .{ .lease = loadBatchSemantic(stored) },
    };
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
            try validateStoredProvenance(batch.provenance);
        },
        .completed, .lease => |batch| {
            if (batch.stream_id == 0 or logical_len > max_batch_bytes)
                return error.InvalidSemantic;
            try validateRecoveryIntent(batch.recovery_intent);
            try validateStoredProvenance(batch.provenance);
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
    for (&ledger.slots) |slot| {
        if (!slot.active and !slot.retired) continue;
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
        if (!slot.active and !slot.retired) continue;
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
        if (index == excluded or (!slot.active and !slot.retired)) continue;
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
        if (ledger.slots[index].active or ledger.slots[index].retired) continue;
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
                .provenance = .untracked,
            };
            if (!end_stream and next_phase == .partial) break :blk .{ .partial = .{
                .stream_id = batch.stream_id,
                .is_snapshot = batch.is_snapshot,
                .chunk_count = 1,
                .recovery_intent = batch.recovery_intent,
                .provenance = batch.provenance,
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

fn seedLegacyMergePairForTest(
    allocator: std.mem.Allocator,
    ledger: *ExternalInboxLedger,
    tokens: *[2]Token,
) !void {
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
    try PreparedSeedPlan.initInPlace(
        &plan,
        allocator,
        ledger,
        &specs,
        &payloads,
    );
    defer plan.deinit();
    try ledger.commitSeeds(&plan, &payloads, tokens);
}

fn releaseExternalLiveForTest(
    ledger: *ExternalInboxLedger,
    allocator: std.mem.Allocator,
    identity: external_rx_types.RxIdentity,
    token: Token,
    phase: PayloadPhase,
) !void {
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    try ledger.prepareLiveRelease(&batch, .{ .existing = token }, phase);
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, 0),
        try ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    try std.testing.expectEqual(
        LiveCommitDisposition.superseded_tombstone,
        dispositions[0],
    );
    try std.testing.expectEqual(
        RetireLiveResult.retired,
        retirement.retire(),
    );
}

fn sealLiveRetirementForTest(retirement: *PreparedLiveRetirement) void {
    retirement.saved_self_addr = @intFromPtr(retirement);
    retirement.lifecycle = .prepared;
    retirement.digest = liveRetirementDigest(retirement);
}

const FrozenCleanupMutationProbe = struct {
    parent: std.mem.Allocator,
    frozen: ?*FrozenLedgerCleanup = null,
    ledger: ?*ExternalInboxLedger = null,
    fired: bool = false,
    free_count: usize = 0,
    resurrect: bool = false,
    saved_frozen: ?FrozenLedgerCleanup = null,
    nested_finish: ?FrozenLedgerCleanupFinishResult = null,

    fn allocator(self: *FrozenCleanupMutationProbe) std.mem.Allocator {
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
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FrozenCleanupMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *FrozenCleanupMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FrozenCleanupMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *FrozenCleanupMutationProbe = @ptrCast(@alignCast(context));
        self.free_count += 1;
        if (!self.fired) {
            self.fired = true;
            if (self.resurrect) {
                self.frozen.?.* = self.saved_frozen.?;
                var moved = self.saved_frozen.?;
                moved.saved_self_addr = @intFromPtr(&moved);
                self.nested_finish = moved.finishCallbackHidden();
            } else {
                self.frozen.?.payloads[1] = .{ .allocator = std.heap.page_allocator };
                self.frozen.?.count = 0;
            }
            self.ledger.?.slots[1].payload = .{ .allocator = std.heap.page_allocator };
            self.ledger.?.charged_items = max_items;
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            ret_addr,
        );
    }
};

const LiveRetirementMutationProbe = struct {
    parent: std.mem.Allocator,
    retirement: ?*PreparedLiveRetirement = null,
    fired: bool = false,
    free_count: usize = 0,
    nested_result: ?RetireLiveResult = null,

    fn allocator(self: *LiveRetirementMutationProbe) std.mem.Allocator {
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
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveRetirementMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *LiveRetirementMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveRetirementMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *LiveRetirementMutationProbe = @ptrCast(@alignCast(context));
        self.free_count += 1;
        if (!self.fired) {
            self.fired = true;
            self.retirement.?.cleanup_count = 0;
            self.retirement.?.cleanup_owners[1] =
                .{ .allocator = std.heap.page_allocator };
            self.nested_result = self.retirement.?.retire();
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            ret_addr,
        );
    }
};

const LiveAllocationMutationProbe = struct {
    parent: std.mem.Allocator,
    target: ?*u8 = null,
    batch: ?*PreparedLiveBatch = null,
    mutate_batch_on_first_allocation: bool = false,
    alloc_count: usize = 0,
    free_count: usize = 0,

    fn allocator(self: *LiveAllocationMutationProbe) std.mem.Allocator {
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
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveAllocationMutationProbe = @ptrCast(@alignCast(context));
        const result = self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            ret_addr,
        );
        self.alloc_count += 1;
        if (self.alloc_count == 1 and self.mutate_batch_on_first_allocation) {
            const batch = self.batch.?;
            batch.allocator = std.heap.page_allocator;
            batch.mutations[max_live_mutations - 1] = .committed;
            batch.coalesced_replacements[max_live_mutations - 1].logical_len = 1;
        }
        if (self.target) |target| target.* = 'z';
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *LiveAllocationMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveAllocationMutationProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *LiveAllocationMutationProbe = @ptrCast(@alignCast(context));
        self.free_count += 1;
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            ret_addr,
        );
    }
};

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

test "screen retirement rejects prepared output inside owned payload backing" {
    const allocator = std.heap.page_allocator;
    var ledger: ExternalInboxLedger = .{};
    var bytes = try allocator.alloc(u8, @sizeOf(PreparedScreenRetirement));
    var payload = OwnedPayload.takeOwned(allocator, &bytes);
    const token = try ledger.reserveLease(leaseSemantic(7, true), &payload);
    const aliased: *PreparedScreenRetirement =
        @ptrCast(@alignCast(ledger.slots[token.slot].payload.allocation_ptr.?));
    try std.testing.expectError(
        error.InvalidRetirement,
        ledger.prepareScreenRetirement(token, .lease, aliased),
    );
    try ledger.releaseLease(token);
    try ledger.finish();
}

test "retired payload remains inside resident byte cap for later admission" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const count = (max_bytes + max_batch_bytes - 1) / max_batch_bytes;
    var tokens: [count]Token = undefined;
    var remaining = max_bytes;
    for (&tokens) |*token| {
        const len = @min(remaining, max_batch_bytes);
        var allocation = try allocator.alloc(u8, len);
        var payload = OwnedPayload.takeOwned(allocator, &allocation);
        token.* = try ledger.reserveLease(leaseSemantic(7, true), &payload);
        remaining -= len;
    }
    var retirement: PreparedScreenRetirement = .{};
    try ledger.prepareScreenRetirement(tokens[0], .lease, &retirement);
    ledger.commitScreenRetirementUnchecked(&retirement);
    try std.testing.expectEqual(max_batch_bytes, ledger.retired_bytes);
    try std.testing.expectEqual(@as(usize, 1), ledger.retired_items);

    var excess = try owned(allocator, "x");
    defer excess.deinit();
    try std.testing.expectError(
        error.ByteCapExceeded,
        ledger.reserveLease(leaseSemantic(7, true), &excess),
    );
    const report = try ledger.drainAll();
    try std.testing.expectEqual(count - 1, report.drained_active_count);
    try ledger.finish();
}

test "admission after retirement keeps active and retired byte accounting disjoint" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var first = try owned(allocator, "retired");
    const first_token = try ledger.reserveLease(leaseSemantic(7, true), &first);
    var retirement: PreparedScreenRetirement = .{};
    try ledger.prepareScreenRetirement(first_token, .lease, &retirement);
    ledger.commitScreenRetirementUnchecked(&retirement);

    var second = try owned(allocator, "active");
    _ = try ledger.reserveLease(leaseSemantic(7, true), &second);
    const view = ledger.accountingView();
    try std.testing.expect(view.valid);
    try std.testing.expectEqual(@as(usize, "active".len), view.charged_bytes);
    try std.testing.expectEqual(@as(usize, "retired".len), view.retired_bytes);
    try std.testing.expectEqual(@as(usize, 1), view.charged_items);
    try std.testing.expectEqual(@as(usize, 1), view.retired_items);
    _ = try ledger.drainAll();
    try ledger.finish();
}

test "seed admission after retirement keeps active and retired accounting disjoint" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var first = try owned(allocator, "retired");
    const first_token = try ledger.reserveLease(leaseSemantic(7, true), &first);
    var retirement: PreparedScreenRetirement = .{};
    try ledger.prepareScreenRetirement(first_token, .lease, &retirement);
    ledger.commitScreenRetirementUnchecked(&retirement);

    var payloads = [_]OwnedPayload{try owned(allocator, "seed")};
    defer for (&payloads) |*payload| payload.deinit();
    const specs = [_]SeedSpec{.{ .semantic = .{ .completed = leaseSemantic(7, true) }, .logical_len = "seed".len }};
    var plan: PreparedSeedPlan = .{};
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);
    defer plan.deinit();
    var tokens: [1]Token = undefined;
    try ledger.commitSeeds(&plan, &payloads, &tokens);
    const view = ledger.accountingView();
    try std.testing.expect(view.valid);
    try std.testing.expectEqual(@as(usize, "seed".len), view.charged_bytes);
    try std.testing.expectEqual(@as(usize, "retired".len), view.retired_bytes);
    try std.testing.expectEqual(@as(usize, 1), view.charged_items);
    try std.testing.expectEqual(@as(usize, 1), view.retired_items);
    _ = try ledger.drainAll();
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
    _ = try ledger.drainAll();
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
    _ = try ledger.drainAll();
}

test "seed planning preflight preserves corrupt accounting byte for byte" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .charged_items = 1 };
    const before = ledger;
    var plan: PreparedSeedPlan = .{};
    defer plan.deinit();

    try std.testing.expectError(
        error.InvariantFailure,
        PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &.{}, &.{}),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&ledger),
    );
    try std.testing.expectEqual(PlanLifecycle.empty, plan.lifecycle);
}

test "seed planning preflight preserves exhausted epoch byte for byte" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{ .mutation_epoch = std.math.maxInt(u64) };
    const before = ledger;
    var plan: PreparedSeedPlan = .{};
    defer plan.deinit();

    try std.testing.expectError(
        error.EpochExhausted,
        PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &.{}, &.{}),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&ledger),
    );
    try std.testing.expectEqual(PlanLifecycle.empty, plan.lifecycle);
}

test "seed plan reports exact private metadata backing bytes" {
    try std.testing.expectEqual(
        2 * @sizeOf(PlannedSeed),
        try PreparedSeedPlan.plannedMetadataBytes(2),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try PreparedSeedPlan.plannedMetadataBytes(0),
    );
    try std.testing.expectError(
        error.ArithmeticOverflow,
        PreparedSeedPlan.plannedMetadataBytes(std.math.maxInt(usize)),
    );
}

test "seed plan public projections preserve empty and binding opacity" {
    const allocator = std.testing.allocator;
    const empty: PreparedSeedPlan = .{};
    try std.testing.expect(empty.isCanonicalEmpty());

    var noncanonical_empty: PreparedSeedPlan = .{ .total_bytes = 1 };
    try std.testing.expect(!noncanonical_empty.isCanonicalEmpty());
    noncanonical_empty = .{ .saved_self_addr = 1 };
    try std.testing.expect(!noncanonical_empty.isCanonicalEmpty());

    var ledger: ExternalInboxLedger = .{};
    var payloads = [_]OwnedPayload{try owned(allocator, "x")};
    defer payloads[0].deinit();
    const specs = [_]SeedSpec{.{
        .semantic = .{ .completed = leaseSemantic(7, false) },
        .logical_len = 1,
    }};
    var plan: PreparedSeedPlan = .{};
    defer plan.deinit();
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &specs, &payloads);

    try std.testing.expect(!plan.isCanonicalEmpty());
    try std.testing.expect(plan.validateBinding(&ledger, &payloads, 1));
    try std.testing.expect(!plan.validateBinding(&ledger, &payloads, 0));
    try std.testing.expect(!plan.validateBinding(&ledger, &.{}, 1));
    var copied_payloads = payloads;
    try std.testing.expect(!plan.validateBinding(&ledger, &copied_payloads, 1));
    var other_ledger: ExternalInboxLedger = .{};
    try std.testing.expect(!plan.validateBinding(&other_ledger, &payloads, 1));
    var copied = plan;
    try std.testing.expect(!copied.validateBinding(&ledger, &payloads, 1));
    const plan_allocator = plan.allocator;
    plan.allocator = std.heap.page_allocator;
    try std.testing.expect(!plan.validateBinding(&ledger, &payloads, 1));
    var token_output: [1]Token = undefined;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitSeeds(&plan, &payloads, &token_output),
    );
    plan.allocator = plan_allocator;
    const entries_addr = plan.entries_addr;
    plan.entries_addr = 0;
    try std.testing.expect(!plan.validateBinding(&ledger, &payloads, 1));
    plan.entries_addr = entries_addr;
    try std.testing.expect(!plan.isCanonicalEmpty());
    try std.testing.expect(plan.validateBinding(&ledger, &payloads, 1));
}

test "zero seed plan binding is stable but not canonical empty" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var plan: PreparedSeedPlan = .{};
    defer plan.deinit();
    try PreparedSeedPlan.initInPlace(&plan, allocator, &ledger, &.{}, &.{});

    try std.testing.expect(!plan.isCanonicalEmpty());
    try std.testing.expect(plan.validateBinding(&ledger, &.{}, 0));
}

test "accounting view is read only and distinguishes pristine from merely empty" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const pristine_before = ledger;
    const pristine = ledger.accountingView();
    try std.testing.expect(pristine.valid);
    try std.testing.expect(pristine.pristine_zero);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&pristine_before),
        std.mem.asBytes(&ledger),
    );

    var payload = OwnedPayload.empty(allocator);
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    try ledger.releaseLease(token);
    const merely_empty = ledger.accountingView();
    try std.testing.expect(merely_empty.valid);
    try std.testing.expect(!merely_empty.pristine_zero);
    try std.testing.expectEqual(@as(usize, 0), merely_empty.charged_items);
    try std.testing.expectEqual(@as(usize, 0), merely_empty.charged_bytes);

    var corrupt: ExternalInboxLedger = .{ .charged_items = 1 };
    const corrupt_before = corrupt;
    const invalid = corrupt.accountingView();
    try std.testing.expect(!invalid.valid);
    try std.testing.expect(!invalid.pristine_zero);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&corrupt_before),
        std.mem.asBytes(&corrupt),
    );
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
    // 뒷정리는 **일부만 개별 해제하고 나머지는 drainAll 로 한 번에** 비운다. `release` 한 번은
    // 변조 감지(다이제스트·별칭·시뮬레이션 재계산)를 위해 슬롯 전체를 여러 번 도는 방어 설계라,
    // 4096 개를 하나씩 풀면 O(n²)다 — **측정값이다**(2026-09-06, Debug, macOS arm64): 예약 0.7 초,
    // 개별 해제 4096 회 15.6 초(begin 2.4 · prepare 4.4 · finish 7.4 · commit 1.4). 이 판정자가
    // 지키는 것은 **정확한 상한**이고 그 부분은 그대로다. 개별 해제 경로는 여기 64 회와 다른
    // 판정자들이 계속 덮고, drainAll 이 돌려준 개수와 `finish` 가 회계가 0 으로 돌아왔음을 본다.
    const individually_released: usize = 64;
    for (tokens[0..individually_released]) |token| try ledger.releaseLease(token);
    const report = try ledger.drainAll();
    try std.testing.expectEqual(max_items - individually_released, report.drained_active_count);
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
    const report = try ledger.drainAll();
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

test "charged recovery lease projects sealed intent incarnation and token generation" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 41,
        .destination_slot_addr = 0x9000,
    };
    projection_test.bindExternalIdentityForTest(&ledger, identity);

    var recovery_payload = try owned(allocator, "snapshot");
    const recovery_token = try ledger.reserveLease(.{
        .stream_id = 7,
        .is_snapshot = true,
        .recovery_intent = .{ .host = 9 },
        .provenance = .{ .external = .{
            .start_absolute = 100,
            .span = 8,
        } },
    }, &recovery_payload);
    const recovery = try ledger.borrowLease(recovery_token);
    try std.testing.expect(std.meta.eql(
        external_recovery_types.Key{
            .owner_incarnation = identity.attach_instance_id,
            .origin = .host,
            .recovery_epoch = 9,
            .expected_token_generation = recovery_token.generation,
        },
        recovery.recovery_key.?,
    ));

    var ordinary_payload = try owned(allocator, "delta");
    const ordinary_token = try ledger.reserveLease(.{
        .stream_id = 7,
        .is_snapshot = false,
        .provenance = .{ .external = .{
            .start_absolute = 108,
            .span = 5,
        } },
    }, &ordinary_payload);
    const ordinary = try ledger.borrowLease(ordinary_token);
    try std.testing.expectEqual(
        @as(?external_recovery_types.Key, null),
        ordinary.recovery_key,
    );

    const drained = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 2), drained.drained_active_count);
}

test "recovery lease without sealed external incarnation fails closed" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "snapshot");
    const token = try ledger.reserveLease(.{
        .stream_id = 7,
        .is_snapshot = true,
        .recovery_intent = .{ .client = 2 },
    }, &payload);
    try std.testing.expectError(error.InvariantFailure, ledger.borrowLease(token));
    try ledger.releaseLease(token);
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

test "legacy merge and release wrappers match direct live batch authority results" {
    const allocator = std.testing.allocator;
    var legacy: ExternalInboxLedger = .{};
    var direct: ExternalInboxLedger = .{};
    var legacy_tokens: [2]Token = undefined;
    var direct_tokens: [2]Token = undefined;
    try seedLegacyMergePairForTest(allocator, &legacy, &legacy_tokens);
    try seedLegacyMergePairForTest(allocator, &direct, &direct_tokens);

    var legacy_replacement = try owned(allocator, "ab");
    defer legacy_replacement.deinit();
    const legacy_result = try legacy.mergeInto(
        legacy_tokens[0],
        legacy_tokens[1],
        &legacy_replacement,
        .completed,
        .none,
    );

    var direct_batch: PreparedLiveBatch = .{};
    try direct.beginLiveBatch(&direct_batch, allocator, null);
    var direct_source: PreparedLiveMergeSource = .{ .existing = .{
        .existing = direct_tokens[1],
    } };
    var direct_replacement_owner = try owned(allocator, "ab");
    var direct_replacement: PreparedLiveReplacement =
        .{ .prebuilt = direct_replacement_owner };
    direct_replacement_owner = OwnedPayload.empty(allocator);
    try direct.prepareLiveMerge(
        &direct_batch,
        .{ .existing = direct_tokens[0] },
        .{ .completed = .{
            .stream_id = 7,
            .is_snapshot = false,
        } },
        null,
        &direct_source,
        &direct_replacement,
    );
    try direct.finishLiveBatch(&direct_batch);
    var direct_retirement = PreparedLiveRetirement.init(allocator);
    var direct_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, 1),
        try direct.commitPreparedLiveBatch(
            &direct_batch,
            &direct_retirement,
            &direct_dispositions,
        ),
    );
    const direct_result = direct_dispositions[0].final_live.token;
    try std.testing.expectEqual(
        RetireLiveResult.retired,
        direct_retirement.retire(),
    );
    try std.testing.expectEqualDeep(legacy_result, direct_result);
    try std.testing.expectEqualDeep(
        legacy.accountingView(),
        direct.accountingView(),
    );
    try std.testing.expectEqualStrings(
        (try legacy.borrow(legacy_result, .completed)).bytes,
        (try direct.borrow(direct_result, .completed)).bytes,
    );

    try legacy.release(legacy_result, .completed);
    var release_batch: PreparedLiveBatch = .{};
    try direct.beginLiveCleanupBatch(&release_batch);
    try direct.prepareLiveRelease(
        &release_batch,
        .{ .existing = direct_result },
        .completed,
    );
    try direct.finishLiveBatch(&release_batch);
    var release_retirement = PreparedLiveRetirement.init(allocator);
    var release_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, 0),
        try direct.commitPreparedLiveBatch(
            &release_batch,
            &release_retirement,
            &release_dispositions,
        ),
    );
    try std.testing.expectEqual(
        LiveCommitDisposition.superseded_tombstone,
        release_dispositions[0],
    );
    for (release_dispositions[1..]) |tail|
        try std.testing.expectEqual(LiveCommitDisposition.unused, tail);
    try std.testing.expectEqual(
        RetireLiveResult.retired,
        release_retirement.retire(),
    );
    try std.testing.expectEqualDeep(
        legacy.accountingView(),
        direct.accountingView(),
    );
    try legacy.finish();
    try direct.finish();
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

test "compact external provenance expands only through the sealed ledger identity" {
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 41,
        .destination_slot_addr = 0x9000,
    };
    projection_test.bindExternalIdentityForTest(&ledger, identity);

    const observed = try ledger.observeProvenance(.{ .external = .{
        .start_absolute = 100,
        .span = 32,
    } });
    try std.testing.expect(std.meta.eql(
        ObservedRxBatchProvenance{ .external = .{
            .identity = identity,
            .start_absolute = 100,
            .end_absolute = 132,
        } },
        observed,
    ));

    try std.testing.expectError(
        error.InvalidSemantic,
        ledger.validateExternalIdentityForLivePrepare(.{
            .attach_instance_id = identity.attach_instance_id + 1,
            .destination_slot_addr = identity.destination_slot_addr,
        }),
    );
}

test "compact external range accepts exact cap and rejects cap plus one and end overflow" {
    try validateCompactExternalRange(.{
        .start_absolute = 0,
        .span = @intCast(max_stored_external_span),
    });
    try std.testing.expectError(
        error.InvalidSemantic,
        validateCompactExternalRange(.{
            .start_absolute = 0,
            .span = @intCast(max_stored_external_span + 1),
        }),
    );
    try std.testing.expectError(
        error.InvalidSemantic,
        validateCompactExternalRange(.{
            .start_absolute = std.math.maxInt(u64),
            .span = 1,
        }),
    );
}

test "legacy seed and relabel preserve untracked observed provenance" {
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
    const completed = try ledger.relabel(tokens[0], .frame, .completed, .none);
    const view = try ledger.borrow(completed, .completed);
    try std.testing.expect(std.meta.eql(
        ObservedRxBatchProvenance.untracked,
        view.semantic.completed.provenance,
    ));
    try ledger.release(completed, .completed);
    try ledger.finish();
}

test "live batch binds external identity and publishes one partial root atomically" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 51,
        .destination_slot_addr = 0x5100,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "a");
    const root_ref = try ledger.prepareLiveAdmission(
        &batch,
        .{ .partial = .{
            .stream_id = 7,
            .is_snapshot = false,
            .chunk_count = 1,
            .provenance = .{ .external = .{
                .start_absolute = 100,
                .span = protocol.header_size + 1,
            } },
        } },
        &payload,
    );
    try std.testing.expectEqual(LiveTokenRef{ .planned = 0 }, root_ref);
    try std.testing.expectEqual(@as(usize, 0), payload.logical_len);
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, 1),
        try ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    const root = dispositions[0].final_live;
    try std.testing.expectEqual(.partial, root.phase);
    const observed = try ledger.partialSnapshot(root.token);
    try std.testing.expect(std.meta.eql(
        ObservedRxBatchProvenance{ .external = .{
            .identity = identity,
            .start_absolute = 100,
            .end_absolute = 100 + protocol.header_size + 1,
        } },
        observed.provenance,
    ));
    try std.testing.expectEqual(
        RetireLiveResult.already_retired,
        retirement.retire(),
    );
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        root.token,
        .partial,
    );
    try ledger.finish();
}

test "live commit permit previews without mutation and consumes exact once" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5101,
        .destination_slot_addr = 0x510100,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "preview");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 71,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 900,
                .span = protocol.header_size + "preview".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    const epoch_before = ledger.mutation_epoch;
    const charged_before = ledger.charged_bytes;
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    const ledger_before = ledger;
    try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA661,
        0x5702,
        41,
        &permit,
    );
    try std.testing.expect(std.meta.eql(ledger_before, ledger));
    try std.testing.expectEqual(@as(u8, 0), permit.final_partial_count);
    try std.testing.expectEqual(@as(u8, 1), permit.final_completed_count);
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);
    try std.testing.expectEqual(charged_before, ledger.charged_bytes);
    try std.testing.expectEqual(.prepared, batch.lifecycle);
    try std.testing.expectEqual(.prepared, permit.lifecycle);
    try std.testing.expectEqual(.completed, dispositions[0].final_live.phase);

    try ledger.consumePreparedLiveCommitChecked(
        &batch,
        &retirement,
        &dispositions,
        &permit,
        0xA661,
        0x5702,
        41,
    );
    try std.testing.expectEqual(.consumed, permit.lifecycle);
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            0xA661,
            0x5702,
            41,
        ),
    );
    const root = dispositions[0].final_live;
    try std.testing.expect(ExternalInboxLedger.resetPreparedLiveCommit(&permit));
    try std.testing.expectEqual(RetireLiveResult.already_retired, retirement.retire());
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        root.token,
        .completed,
    );
    try ledger.finish();
}

test "2b2e integration retired final is never live and remains immutable commit evidence" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5102,
        .destination_slot_addr = 0x510200,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "retire-at-commit");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 72,
            .is_snapshot = true,
            .provenance = .{ .external = .{
                .start_absolute = 1_000,
                .span = protocol.header_size + "retire-at-commit".len,
            } },
            .recovery_intent = .{ .client = 17 },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions = [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA662,
        0x5703,
        42,
        &permit,
    );
    const token = dispositions[0].final_live.token;
    var cleanup_selection = [_]bool{false} ** max_live_mutations;
    cleanup_selection[0] = true;
    cleanup_selection[1] = true;
    const permit_before_invalid = permit;
    const dispositions_before_invalid = dispositions;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.markPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &cleanup_selection,
            0xA662,
            0x5703,
            42,
        ),
    );
    try std.testing.expect(std.meta.eql(permit_before_invalid, permit));
    try std.testing.expect(std.meta.eql(
        dispositions_before_invalid,
        dispositions,
    ));
    cleanup_selection[1] = false;
    try ledger.markPreparedFinalRootsForCleanup(
        &batch,
        &retirement,
        &dispositions,
        &permit,
        &cleanup_selection,
        0xA662,
        0x5703,
        42,
    );
    const permit_after_valid = permit;
    const dispositions_after_valid = dispositions;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.markPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &cleanup_selection,
            0xA662,
            0x5703,
            42,
        ),
    );
    try std.testing.expect(std.meta.eql(permit_after_valid, permit));
    try std.testing.expect(std.meta.eql(dispositions_after_valid, dispositions));
    try std.testing.expect(dispositions[0] == .cleanup_final);
    try std.testing.expectEqual(@as(u8, 0), permit.final_completed_count);
    try std.testing.expectEqual(@as(u8, 1), permit.cleanup_final_count);
    try std.testing.expectEqual(@as(usize, 1), permit.reserved_cleanup_count);
    try std.testing.expectEqual(
        @as(usize, "retire-at-commit".len),
        permit.reserved_cleanup_bytes,
    );
    var output: CommittedLiveOutput = .{};
    ledger.consumePreparedLiveCommitWithOutputUnchecked(
        &batch,
        &retirement,
        &dispositions,
        &permit,
        &output,
    );
    try std.testing.expect(committedLiveOutputValid(&ledger, &output));
    try std.testing.expectEqual(@as(u8, 1), output.count);
    try std.testing.expect(std.meta.eql(token, output.entries[0].token));
    try std.testing.expect(output.entries[0].cleanup_only);
    output.entries[0].cleanup_only = false;
    output.digest = committedLiveOutputDigest(&output);
    try std.testing.expect(!committedLiveOutputValid(&ledger, &output));
    output.entries[0].cleanup_only = true;
    output.digest = committedLiveOutputDigest(&output);
    output.entries[1].cleanup_only = true;
    output.digest = committedLiveOutputDigest(&output);
    try std.testing.expect(!committedLiveOutputValid(&ledger, &output));
    output.entries[1] = .{};
    output.digest = committedLiveOutputDigest(&output);
    try std.testing.expect(committedLiveOutputValid(&ledger, &output));
    try std.testing.expectEqual(@as(usize, 0), ledger.accountingView().charged_items);
    try std.testing.expectEqual(@as(u8, 1), retirement.cleanup_count);
    try std.testing.expectEqual(permit.cleanup_final_bytes, retirement.cleanup_bytes);
    try std.testing.expectEqual(RetireLiveResult.retired, retirement.retire());
    try ledger.finish();
}

test "projected final-root cleanup planner is pure and seals only disjoint final addresses" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, null);
    var payload = try owned(allocator, "projected-cleanup");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 73,
            .is_snapshot = true,
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions = [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA663,
        0x5704,
        43,
        &permit,
    );
    var final_dispositions = [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var final_permit: PreparedLiveCommit = .{};
    var selection = [_]bool{false} ** max_live_mutations;
    selection[0] = true;

    const ledger_before = ledger;
    const batch_before = batch;
    const retirement_before = retirement;
    const dispositions_before = dispositions;
    const permit_before = permit;
    const candidate = try ledger.planPreparedFinalRootsForCleanup(
        &batch,
        &retirement,
        &dispositions,
        &permit,
        &selection,
        @intFromPtr(&final_dispositions),
        @intFromPtr(&final_permit),
        0xA663,
        0x5704,
        43,
    );
    try std.testing.expect(std.meta.eql(ledger_before, ledger));
    try std.testing.expect(std.meta.eql(batch_before, batch));
    try std.testing.expect(std.meta.eql(retirement_before, retirement));
    try std.testing.expect(std.meta.eql(dispositions_before, dispositions));
    try std.testing.expect(std.meta.eql(permit_before, permit));
    try std.testing.expect(std.meta.eql(
        final_dispositions,
        [_]LiveCommitDisposition{.unused} ** max_live_mutations,
    ));
    try std.testing.expect(std.meta.eql(final_permit, PreparedLiveCommit{}));
    try std.testing.expect(candidate.dispositions[0] == .cleanup_final);
    try std.testing.expectEqual(@as(u8, 1), candidate.permit.cleanup_final_count);
    try std.testing.expectEqual(@as(u8, 0), candidate.permit.final_completed_count);
    try std.testing.expectEqual(
        @intFromPtr(&final_dispositions),
        candidate.permit.dispositions_addr,
    );
    try std.testing.expectEqual(
        @intFromPtr(&final_permit),
        candidate.permit.saved_self_addr,
    );

    selection[1] = true;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.planPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &selection,
            @intFromPtr(&final_dispositions),
            @intFromPtr(&final_permit),
            0xA663,
            0x5704,
            43,
        ),
    );
    selection[1] = false;
    try std.testing.expectError(
        error.InvalidAlias,
        ledger.planPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &selection,
            @intFromPtr(&dispositions),
            @intFromPtr(&final_permit),
            0xA663,
            0x5704,
            43,
        ),
    );
    try std.testing.expectError(
        error.InvalidAlias,
        ledger.planPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &selection,
            std.math.maxInt(usize) -
                @sizeOf([max_live_mutations]LiveCommitDisposition) + 2,
            @intFromPtr(&final_permit),
            0xA663,
            0x5704,
            43,
        ),
    );
    try std.testing.expect(std.meta.eql(ledger_before, ledger));
    try std.testing.expect(std.meta.eql(batch_before, batch));
    try std.testing.expect(std.meta.eql(retirement_before, retirement));
    try std.testing.expect(std.meta.eql(dispositions_before, dispositions));
    try std.testing.expect(std.meta.eql(permit_before, permit));

    const original_mutation_count = batch.mutation_count;
    batch.mutation_count = @intCast(max_live_mutations + 1);
    const invalid_batch = batch;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.planPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &selection,
            @intFromPtr(&final_dispositions),
            @intFromPtr(&final_permit),
            0xA663,
            0x5704,
            43,
        ),
    );
    try std.testing.expect(std.meta.eql(invalid_batch, batch));
    batch.mutation_count = original_mutation_count;

    try std.testing.expectEqual(
        AbortLiveCommitResult.aborted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    try std.testing.expect(ExternalInboxLedger.resetPreparedLiveCommit(&permit));
    _ = ledger.abortPreparedLiveBatch(&batch);
    try ledger.finish();
}

test "projected final-root cleanup planner accepts exact mutation cap and rejects cap plus one" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, null);
    for (0..max_live_mutations) |index| {
        var payload = try owned(allocator, "x");
        _ = try ledger.prepareLiveAdmission(
            &batch,
            .{ .completed = .{
                .stream_id = @intCast(1_000 + index),
                .is_snapshot = true,
            } },
            &payload,
        );
    }
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions = [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA664,
        0x5705,
        44,
        &permit,
    );
    var final_dispositions = [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var final_permit: PreparedLiveCommit = .{};
    const selection = [_]bool{true} ** max_live_mutations;
    const candidate = try ledger.planPreparedFinalRootsForCleanup(
        &batch,
        &retirement,
        &dispositions,
        &permit,
        &selection,
        @intFromPtr(&final_dispositions),
        @intFromPtr(&final_permit),
        0xA664,
        0x5705,
        44,
    );
    try std.testing.expectEqual(
        @as(u8, max_live_mutations),
        candidate.permit.cleanup_final_count,
    );
    try std.testing.expectEqual(@as(u8, 0), candidate.permit.final_completed_count);
    for (candidate.dispositions) |disposition|
        try std.testing.expect(disposition == .cleanup_final);

    const source_before = batch;
    batch.mutation_count = @intCast(max_live_mutations + 1);
    const invalid_source = batch;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.planPreparedFinalRootsForCleanup(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            &selection,
            @intFromPtr(&final_dispositions),
            @intFromPtr(&final_permit),
            0xA664,
            0x5705,
            44,
        ),
    );
    try std.testing.expect(std.meta.eql(invalid_source, batch));
    batch = source_before;

    try std.testing.expectEqual(
        AbortLiveCommitResult.aborted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    try std.testing.expect(ExternalInboxLedger.resetPreparedLiveCommit(&permit));
    _ = ledger.abortPreparedLiveBatch(&batch);
    try ledger.finish();
}

test "live commit permit rejects copied moved and authority drift before mutation" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5102,
        .destination_slot_addr = 0x510200,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "drift");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 72,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 1000,
                .span = protocol.header_size + "drift".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    _ = try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA662,
        0x5703,
        42,
        &permit,
    );
    const epoch_before = ledger.mutation_epoch;
    var copied = permit;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &copied,
            0xA662,
            0x5703,
            42,
        ),
    );
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);
    try std.testing.expectEqual(.prepared, batch.lifecycle);

    permit.simulation.charged_bytes += 1;
    try std.testing.expectError(
        error.StalePlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            0xA662,
            0x5703,
            42,
        ),
    );
    permit.simulation.charged_bytes -= 1;
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);
    try std.testing.expectEqual(.prepared, permit.lifecycle);

    dispositions[0].final_live.token.generation += 1;
    try std.testing.expectError(
        error.StalePlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            0xA662,
            0x5703,
            42,
        ),
    );
    dispositions[0].final_live.token.generation -= 1;
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);

    ledger.mutation_epoch += 1;
    try std.testing.expectError(
        error.StalePlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            0xA662,
            0x5703,
            42,
        ),
    );
    ledger.mutation_epoch -= 1;
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);

    try std.testing.expectError(
        error.InvalidPlan,
        ledger.consumePreparedLiveCommitChecked(
            &batch,
            &retirement,
            &dispositions,
            &permit,
            0xA662,
            0x5703,
            43,
        ),
    );
    try std.testing.expectEqual(epoch_before, ledger.mutation_epoch);
    try std.testing.expectEqual(.prepared, batch.lifecycle);
    try std.testing.expectEqual(
        AbortLiveCommitResult.aborted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    for (dispositions) |disposition|
        try std.testing.expectEqual(LiveCommitDisposition.unused, disposition);
    try std.testing.expect(ExternalInboxLedger.resetPreparedLiveCommit(&permit));
    try std.testing.expect(std.meta.eql(permit, PreparedLiveCommit{}));
    _ = ledger.abortPreparedLiveBatch(&batch);
}

test "live commit abort rejects hostile drift without partial mutation" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5103,
        .destination_slot_addr = 0x510300,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "abort-drift");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 73,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 1100,
                .span = protocol.header_size + "abort-drift".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    var permit: PreparedLiveCommit = .{};
    try ledger.prepareLiveCommit(
        &batch,
        &retirement,
        &dispositions,
        0xA663,
        0x5704,
        43,
        &permit,
    );

    const Unchanged = struct {
        fn expect(
            expected_ledger: ExternalInboxLedger,
            expected_batch: PreparedLiveBatch,
            expected_retirement: PreparedLiveRetirement,
            expected_dispositions: [max_live_mutations]LiveCommitDisposition,
            expected_permit: PreparedLiveCommit,
            actual_ledger: *const ExternalInboxLedger,
            actual_batch: *const PreparedLiveBatch,
            actual_retirement: *const PreparedLiveRetirement,
            actual_dispositions: *const [max_live_mutations]LiveCommitDisposition,
            actual_permit: *const PreparedLiveCommit,
        ) !void {
            try std.testing.expect(std.meta.eql(expected_ledger, actual_ledger.*));
            try std.testing.expect(std.meta.eql(expected_batch, actual_batch.*));
            try std.testing.expect(std.meta.eql(expected_retirement, actual_retirement.*));
            try std.testing.expect(std.meta.eql(expected_dispositions, actual_dispositions.*));
            try std.testing.expect(std.meta.eql(expected_permit, actual_permit.*));
        }
    };

    batch.digest[0] ^= 1;
    const drifted_ledger = ledger;
    const drifted_batch = batch;
    const drifted_retirement = retirement;
    const drifted_dispositions = dispositions;
    const drifted_permit = permit;
    try std.testing.expectEqual(
        AbortLiveCommitResult.ignored_untrusted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    try Unchanged.expect(
        drifted_ledger,
        drifted_batch,
        drifted_retirement,
        drifted_dispositions,
        drifted_permit,
        &ledger,
        &batch,
        &retirement,
        &dispositions,
        &permit,
    );
    batch.digest[0] ^= 1;

    retirement.saved_self_addr +%= 1;
    const retirement_drift = retirement;
    try std.testing.expectEqual(
        AbortLiveCommitResult.ignored_untrusted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    try std.testing.expect(std.meta.eql(retirement_drift, retirement));
    try std.testing.expectEqual(.prepared, permit.lifecycle);
    retirement.saved_self_addr -%= 1;

    var copied = permit;
    try std.testing.expectEqual(
        AbortLiveCommitResult.ignored_untrusted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &copied,
        ),
    );
    try std.testing.expect(std.meta.eql(copied, permit));
    try std.testing.expectEqual(.prepared, permit.lifecycle);

    permit.aggregate_addr +%= 1;
    const aggregate_drift = permit;
    try std.testing.expectEqual(
        AbortLiveCommitResult.ignored_untrusted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    try std.testing.expect(std.meta.eql(aggregate_drift, permit));
    permit.aggregate_addr -%= 1;

    try std.testing.expectEqual(
        AbortLiveCommitResult.aborted,
        ledger.abortPreparedLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            &permit,
        ),
    );
    _ = ledger.abortPreparedLiveBatch(&batch);
}

test "live batch abort freezes ownership before callback-free tombstone" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5104,
        .destination_slot_addr = 0x510400,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "frozen-abort");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 74,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 1200,
                .span = protocol.header_size + "frozen-abort".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    const payload_addr =
        batch.mutations[0].admission.owned_payload.allocation_ptr.?;
    var permit: FrozenLiveBatchAbort = .{};
    try ledger.prepareLiveBatchAbort(&batch, &permit);
    try std.testing.expectEqual(LiveBatchAbortLifecycle.prepared, permit.lifecycle);
    try std.testing.expectEqual(@as(u8, 1), permit.cleanup_count);
    try std.testing.expectEqual(
        @intFromPtr(payload_addr),
        permit.cleanup[0].allocation_addr,
    );
    try std.testing.expect(ledger.validatePreparedLiveBatchAbort(
        &batch,
        &permit,
    ));
    try std.testing.expect(batch.mutations[0] == .admission);

    ledger.commitLiveBatchAbortUnchecked(&batch, &permit);
    try std.testing.expectEqual(PreparedLiveBatchLifecycle.aborted, batch.lifecycle);
    try std.testing.expectEqual(LiveBatchAbortLifecycle.committed, permit.lifecycle);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ExternalInboxLedger.finishFrozenLiveBatchAbort(&permit),
    );
    try std.testing.expectEqual(LiveBatchAbortLifecycle.spent, permit.lifecycle);
}

test "live batch abort validation rejects drift without tombstoning owners" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 5105,
        .destination_slot_addr = 0x510500,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "abort-seal");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 75,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 1300,
                .span = protocol.header_size + "abort-seal".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var permit: FrozenLiveBatchAbort = .{};
    try ledger.prepareLiveBatchAbort(&batch, &permit);
    const before_batch = batch;
    const before_permit = permit;
    batch.digest[0] ^= 1;
    try std.testing.expect(!ledger.validatePreparedLiveBatchAbort(
        &batch,
        &permit,
    ));
    try std.testing.expect(std.meta.eql(before_permit, permit));
    batch.digest[0] ^= 1;
    try std.testing.expect(std.meta.eql(before_batch, batch));
    try std.testing.expect(ledger.validatePreparedLiveBatchAbort(
        &batch,
        &permit,
    ));
    ledger.commitLiveBatchAbortUnchecked(&batch, &permit);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ExternalInboxLedger.finishFrozenLiveBatchAbort(&permit),
    );
}

test "live commit permit rejects active payload alias before output write" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var aliased_permit: PreparedLiveCommit align(@alignOf(PreparedLiveCommit)) = .{};
    ledger.slots[0] = .{
        .active = true,
        .generation = 1,
        .semantic = try storeSemantic(.{ .completed = .{
            .stream_id = 700,
            .is_snapshot = false,
        } }),
        .payload = .{
            .allocator = allocator,
            .allocation_ptr = @ptrCast(&aliased_permit),
            .logical_len = @sizeOf(PreparedLiveCommit),
        },
    };
    ledger.charged_bytes = @sizeOf(PreparedLiveCommit);
    ledger.charged_items = 1;
    ledger.next_generation = 2;
    ledger.next_slot_hint = 1;

    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, null);
    var payload = try owned(allocator, "new");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 701,
            .is_snapshot = false,
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectError(
        error.InvalidAlias,
        ledger.prepareLiveCommit(
            &batch,
            &retirement,
            &dispositions,
            0xA663,
            0x5704,
            44,
            &aliased_permit,
        ),
    );
    try std.testing.expect(std.meta.eql(
        aliased_permit,
        PreparedLiveCommit{},
    ));
    for (dispositions) |disposition|
        try std.testing.expectEqual(LiveCommitDisposition.unused, disposition);
    _ = ledger.abortPreparedLiveBatch(&batch);
    ledger.slots[0] = .{ .generation = 1 };
    ledger.charged_bytes = 0;
    ledger.charged_items = 0;
    try ledger.finish();
}

test "legacy release rejects external provenance and preserves live token" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 511,
        .destination_slot_addr = 0x5110,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "external");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 8,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 1,
                .span = protocol.header_size + "external".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    const token = dispositions[0].final_live.token;

    try std.testing.expectError(
        error.InvariantFailure,
        ledger.release(token, .completed),
    );
    const preserved = try ledger.borrow(token, .completed);
    try std.testing.expectEqualStrings("external", preserved.bytes);

    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        token,
        .completed,
    );
    try ledger.finish();
}

test "two-mutation live chain allocates one final replacement and retires sources" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 52,
        .destination_slot_addr = 0x5200,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var first = try owned(allocator, "a");
    const first_ref = try ledger.prepareLiveAdmission(
        &batch,
        .{ .partial = .{
            .stream_id = 9,
            .is_snapshot = true,
            .chunk_count = 1,
            .provenance = .{ .external = .{
                .start_absolute = 200,
                .span = protocol.header_size + 1,
            } },
        } },
        &first,
    );
    var second_payload = try owned(allocator, "b");
    var source: PreparedLiveMergeSource = .{ .owned = second_payload };
    second_payload = OwnedPayload.empty(allocator);
    var replacement: PreparedLiveReplacement = .coalesced;
    try ledger.prepareLiveMerge(
        &batch,
        first_ref,
        .{ .completed = .{
            .stream_id = 9,
            .is_snapshot = true,
            .provenance = .{ .external = .{
                .start_absolute = 200,
                .span = 2 * (protocol.header_size + 1),
            } },
        } },
        .{
            .identity = identity,
            .start_absolute = 200 + protocol.header_size + 1,
            .end_absolute = 200 + 2 * (protocol.header_size + 1),
        },
        &source,
        &replacement,
    );
    try ledger.finishLiveBatch(&batch);
    try std.testing.expectEqual(@as(u8, 1), batch.replacement_count);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    try std.testing.expectEqual(
        LiveCommitDisposition.superseded_tombstone,
        dispositions[0],
    );
    const root = dispositions[1].final_live;
    try std.testing.expectEqual(.completed, root.phase);
    const view = try ledger.borrow(root.token, .completed);
    try std.testing.expectEqualStrings("ab", view.bytes);
    try std.testing.expectEqual(
        RetireLiveResult.retired,
        retirement.retire(),
    );
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        root.token,
        .completed,
    );
    try ledger.finish();
}

test "three-chunk chain allocates no intermediate replacement" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 53,
        .destination_slot_addr = 0x5300,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var first = try owned(allocator, "a");
    const first_ref = try ledger.prepareLiveAdmission(
        &batch,
        .{ .partial = .{
            .stream_id = 10,
            .is_snapshot = false,
            .chunk_count = 1,
            .provenance = .{ .external = .{
                .start_absolute = 300,
                .span = protocol.header_size + 1,
            } },
        } },
        &first,
    );
    var second_owner = try owned(allocator, "b");
    var second_source: PreparedLiveMergeSource = .{ .owned = second_owner };
    second_owner = OwnedPayload.empty(allocator);
    var second_replacement: PreparedLiveReplacement = .coalesced;
    try ledger.prepareLiveMerge(
        &batch,
        first_ref,
        .{ .partial = .{
            .stream_id = 10,
            .is_snapshot = false,
            .chunk_count = 2,
            .provenance = .{ .external = .{
                .start_absolute = 300,
                .span = 2 * (protocol.header_size + 1),
            } },
        } },
        .{
            .identity = identity,
            .start_absolute = 300 + protocol.header_size + 1,
            .end_absolute = 300 + 2 * (protocol.header_size + 1),
        },
        &second_source,
        &second_replacement,
    );
    var third_owner = try owned(allocator, "c");
    var third_source: PreparedLiveMergeSource = .{ .owned = third_owner };
    third_owner = OwnedPayload.empty(allocator);
    var third_replacement: PreparedLiveReplacement = .coalesced;
    try ledger.prepareLiveMerge(
        &batch,
        .{ .planned = 1 },
        .{ .completed = .{
            .stream_id = 10,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 300,
                .span = 3 * (protocol.header_size + 1),
            } },
        } },
        .{
            .identity = identity,
            .start_absolute = 300 + 2 * (protocol.header_size + 1),
            .end_absolute = 300 + 3 * (protocol.header_size + 1),
        },
        &third_source,
        &third_replacement,
    );
    try ledger.finishLiveBatch(&batch);
    try std.testing.expectEqual(@as(u8, 1), batch.replacement_count);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    const root = dispositions[2].final_live;
    const view = try ledger.borrow(root.token, .completed);
    try std.testing.expectEqualStrings("abc", view.bytes);
    try std.testing.expectEqual(RetireLiveResult.retired, retirement.retire());
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        root.token,
        .completed,
    );
    try ledger.finish();
}

test "live continuation rejects foreign gap and overlap incoming ranges before take" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 531,
        .destination_slot_addr = 0x5310,
    };
    const first_start: u64 = 700;
    const first_end = first_start + protocol.header_size + 1;
    const cases = [_]external_rx_types.RxRange{
        .{
            .identity = .{
                .attach_instance_id = identity.attach_instance_id + 1,
                .destination_slot_addr = identity.destination_slot_addr,
            },
            .start_absolute = first_end,
            .end_absolute = first_end + protocol.header_size + 1,
        },
        .{
            .identity = .{
                .attach_instance_id = identity.attach_instance_id,
                .destination_slot_addr = identity.destination_slot_addr + 1,
            },
            .start_absolute = first_end,
            .end_absolute = first_end + protocol.header_size + 1,
        },
        .{
            .identity = identity,
            .start_absolute = first_end + 1,
            .end_absolute = first_end + 1 + protocol.header_size + 1,
        },
        .{
            .identity = identity,
            .start_absolute = first_end - 1,
            .end_absolute = first_end - 1 + protocol.header_size + 1,
        },
    };
    for (cases) |incoming| {
        var ledger: ExternalInboxLedger = .{};
        var batch: PreparedLiveBatch = .{};
        try ledger.beginLiveBatch(&batch, allocator, identity);
        var first = try owned(allocator, "a");
        const first_ref = try ledger.prepareLiveAdmission(
            &batch,
            .{ .partial = .{
                .stream_id = 1,
                .is_snapshot = false,
                .chunk_count = 1,
                .provenance = .{ .external = .{
                    .start_absolute = first_start,
                    .span = protocol.header_size + 1,
                } },
            } },
            &first,
        );
        var source_owner = try owned(allocator, "b");
        var source: PreparedLiveMergeSource = .{ .owned = source_owner };
        source_owner = OwnedPayload.empty(allocator);
        var replacement: PreparedLiveReplacement = .coalesced;
        try std.testing.expectError(
            error.InvalidSemantic,
            ledger.prepareLiveMerge(
                &batch,
                first_ref,
                .{ .completed = .{
                    .stream_id = 1,
                    .is_snapshot = false,
                    .provenance = .{ .external = .{
                        .start_absolute = first_start,
                        .span = 2 * (protocol.header_size + 1),
                    } },
                } },
                incoming,
                &source,
                &replacement,
            ),
        );
        source.owned.deinit();
        try std.testing.expectEqual(
            AbortLiveResult.aborted,
            ledger.abortPreparedLiveBatch(&batch),
        );
        try std.testing.expect(ledger.accountingView().pristine_zero);
        try ledger.finish();
    }
}

test "external identity remains bound at zero live slots and rejects A-B-A reuse" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const first_identity = external_rx_types.RxIdentity{
        .attach_instance_id = 61,
        .destination_slot_addr = 0x6100,
    };
    var first_batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&first_batch, allocator, first_identity);
    var payload = try owned(allocator, "x");
    _ = try ledger.prepareLiveAdmission(
        &first_batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + 1,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&first_batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &first_batch,
        &retirement,
        &dispositions,
    );
    const token = dispositions[0].final_live.token;
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        first_identity,
        token,
        .completed,
    );

    var rejected: PreparedLiveBatch = .{};
    try std.testing.expectError(
        error.InvalidSemantic,
        ledger.beginLiveBatch(&rejected, allocator, .{
            .attach_instance_id = first_identity.attach_instance_id + 1,
            .destination_slot_addr = first_identity.destination_slot_addr,
        }),
    );
    var same: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&same, allocator, first_identity);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&same),
    );
    try ledger.finish();
}

test "drain advances bound external identity to canonical tombstone" {
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 611,
        .destination_slot_addr = 0x6110,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.testing.allocator, identity);
    var payload = OwnedPayload.empty(std.testing.allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(std.testing.allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    const bound_generation = ledger.external_identity_seal.generation;
    const bound_authority = ledger.projectionAuthorityDigest();
    const report = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 1), report.drained_active_count);
    try std.testing.expectEqual(
        LedgerExternalIdentityLifecycle.drained_tombstone,
        ledger.external_identity_seal.lifecycle,
    );
    try std.testing.expectEqual(
        bound_generation + 1,
        ledger.external_identity_seal.generation,
    );
    try std.testing.expectEqual(@as(?external_rx_types.RxIdentity, null), ledger.external_identity_seal.identity);
    try std.testing.expect(ledger.hasValidExternalIdentitySeal());
    try std.testing.expect(!std.mem.eql(
        u8,
        &bound_authority,
        &ledger.projectionAuthorityDigest(),
    ));
    try ledger.finish();
}

test "owner teardown commits and restores canonical external identity tombstone" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 612,
        .destination_slot_addr = 0x6120,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "x");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + 1,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    const token = dispositions[0].final_live.token;
    const bound_generation = ledger.external_identity_seal.generation;

    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(12, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(
        &.{token},
        std.StaticBitSet(max_items).initEmpty(),
    );
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};
    try ledger.prepareFreezeAllForOwnerTeardown(
        &permit,
        &token_plan,
        &prepared,
        &frozen,
    );
    const terminal_generation =
        prepared.terminal_external_identity_seal.generation;
    try std.testing.expectEqual(bound_generation + 1, terminal_generation);
    _ = ledger.commitFreezeAllForOwnerTeardownUnchecked(
        &permit,
        &prepared,
        &frozen,
    );
    try std.testing.expectEqual(
        LedgerExternalIdentityLifecycle.drained_tombstone,
        ledger.external_identity_seal.lifecycle,
    );
    try std.testing.expectEqual(terminal_generation, ledger.external_identity_seal.generation);
    try std.testing.expect(ledger.hasValidExternalIdentitySeal());
    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.cleaned,
        frozen.finishCallbackHidden(),
    );
    ledger.restoreFinishedOwnerTeardownUnchecked(12, terminal_generation);
    try std.testing.expectEqual(
        LedgerExternalIdentityLifecycle.drained_tombstone,
        ledger.external_identity_seal.lifecycle,
    );
    try std.testing.expectEqual(terminal_generation, ledger.external_identity_seal.generation);
    try std.testing.expect(ledger.hasValidExternalIdentitySeal());
}

test "live batch accepts exact 64 mutations and rejects cap plus one before take" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 62,
        .destination_slot_addr = 0x6200,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    for (0..max_live_mutations) |index| {
        var payload = OwnedPayload.empty(allocator);
        _ = try ledger.prepareLiveAdmission(
            &batch,
            .{ .completed = .{
                .stream_id = index + 1,
                .is_snapshot = false,
                .provenance = .{ .external = .{
                    .start_absolute = index * protocol.header_size,
                    .span = protocol.header_size,
                } },
            } },
            &payload,
        );
    }
    var excess = OwnedPayload.empty(allocator);
    try std.testing.expectError(
        error.ItemCapExceeded,
        ledger.prepareLiveAdmission(
            &batch,
            .{ .completed = .{
                .stream_id = 65,
                .is_snapshot = false,
                .provenance = .{ .external = .{
                    .start_absolute = 64 * protocol.header_size,
                    .span = protocol.header_size,
                } },
            } },
            &excess,
        ),
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, max_live_mutations),
        try ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    for (dispositions) |disposition|
        try std.testing.expect(disposition == .final_live);
    const report = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, max_live_mutations), report.drained_active_count);
    try ledger.finish();
}

test "stale checked live commit publishes nothing and canonical abort cleans source" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 63,
        .destination_slot_addr = 0x6300,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "owned");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + "owned".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var sibling_payload = try owned(allocator, "s");
    const sibling = try ledger.reserveLease(
        leaseSemantic(9, false),
        &sibling_payload,
    );
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectError(
        error.StalePlan,
        ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), ledger.charged_items);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try ledger.releaseLease(sibling);
    try ledger.finish();
}

test "checked live merge rejects existing payload content drift" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 633,
        .destination_slot_addr = 0x6330,
    };
    var ledger: ExternalInboxLedger = .{};
    var first_batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&first_batch, allocator, identity);
    var first = try owned(allocator, "a");
    _ = try ledger.prepareLiveAdmission(
        &first_batch,
        .{ .partial = .{
            .stream_id = 1,
            .is_snapshot = false,
            .chunk_count = 1,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + 1,
            } },
        } },
        &first,
    );
    try ledger.finishLiveBatch(&first_batch);
    var first_retirement = PreparedLiveRetirement.init(allocator);
    var first_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &first_batch,
        &first_retirement,
        &first_dispositions,
    );
    const token = first_dispositions[0].final_live.token;

    var merge_batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&merge_batch, allocator, identity);
    var second_owner = try owned(allocator, "b");
    var source: PreparedLiveMergeSource = .{ .owned = second_owner };
    second_owner = OwnedPayload.empty(allocator);
    var replacement: PreparedLiveReplacement = .coalesced;
    try ledger.prepareLiveMerge(
        &merge_batch,
        .{ .existing = token },
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = 2 * (protocol.header_size + 1),
            } },
        } },
        .{
            .identity = identity,
            .start_absolute = protocol.header_size + 1,
            .end_absolute = 2 * (protocol.header_size + 1),
        },
        &source,
        &replacement,
    );
    try ledger.finishLiveBatch(&merge_batch);
    ledger.slots[token.slot].payload.allocation_ptr.?[0] = 'z';
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectError(
        error.StalePlan,
        ledger.commitPreparedLiveBatch(
            &merge_batch,
            &retirement,
            &dispositions,
        ),
    );
    ledger.slots[token.slot].payload.allocation_ptr.?[0] = 'a';
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&merge_batch),
    );
    const preserved = try ledger.borrow(token, .partial);
    try std.testing.expectEqualStrings("a", preserved.bytes);
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        token,
        .partial,
    );
    try ledger.finish();
}

test "live replacement allocation callback cannot rewrite existing payload authority" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 635,
        .destination_slot_addr = 0x6350,
    };
    var ledger: ExternalInboxLedger = .{};
    var admission: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&admission, allocator, identity);
    var first = try owned(allocator, "a");
    _ = try ledger.prepareLiveAdmission(
        &admission,
        .{ .partial = .{
            .stream_id = 1,
            .is_snapshot = false,
            .chunk_count = 1,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + 1,
            } },
        } },
        &first,
    );
    try ledger.finishLiveBatch(&admission);
    var admission_retirement = PreparedLiveRetirement.init(allocator);
    var admission_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &admission,
        &admission_retirement,
        &admission_dispositions,
    );
    const token = admission_dispositions[0].final_live.token;

    var probe = LiveAllocationMutationProbe{
        .parent = allocator,
        .target = &ledger.slots[token.slot].payload.allocation_ptr.?[0],
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, probe.allocator(), identity);
    var second_owner = try owned(allocator, "b");
    var source: PreparedLiveMergeSource = .{ .owned = second_owner };
    second_owner = OwnedPayload.empty(allocator);
    var replacement: PreparedLiveReplacement = .coalesced;
    try ledger.prepareLiveMerge(
        &batch,
        .{ .existing = token },
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = 2 * (protocol.header_size + 1),
            } },
        } },
        .{
            .identity = identity,
            .start_absolute = protocol.header_size + 1,
            .end_absolute = 2 * (protocol.header_size + 1),
        },
        &source,
        &replacement,
    );
    try std.testing.expectError(
        error.StalePlan,
        ledger.finishLiveBatch(&batch),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.alloc_count);
    try std.testing.expectEqual(@as(usize, 1), probe.free_count);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    ledger.slots[token.slot].payload.allocation_ptr.?[0] = 'a';
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        token,
        .partial,
    );
    try ledger.finish();
}

test "live replacement callbacks cannot redirect later allocation or hide batch tails" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 636,
        .destination_slot_addr = 0x6360,
    };
    var ledger: ExternalInboxLedger = .{};
    var probe = LiveAllocationMutationProbe{
        .parent = allocator,
        .mutate_batch_on_first_allocation = true,
    };
    var batch: PreparedLiveBatch = .{};
    probe.batch = &batch;
    const sealed_allocator = probe.allocator();
    try ledger.beginLiveBatch(&batch, sealed_allocator, identity);
    for (0..2) |index| {
        const start = index * 2 * (protocol.header_size + 1);
        var first = try owned(allocator, "a");
        const first_ref = try ledger.prepareLiveAdmission(
            &batch,
            .{ .partial = .{
                .stream_id = index + 1,
                .is_snapshot = false,
                .chunk_count = 1,
                .provenance = .{ .external = .{
                    .start_absolute = start,
                    .span = protocol.header_size + 1,
                } },
            } },
            &first,
        );
        var second_owner = try owned(allocator, "b");
        var source: PreparedLiveMergeSource = .{ .owned = second_owner };
        second_owner = OwnedPayload.empty(allocator);
        var replacement: PreparedLiveReplacement = .coalesced;
        try ledger.prepareLiveMerge(
            &batch,
            first_ref,
            .{ .completed = .{
                .stream_id = index + 1,
                .is_snapshot = false,
                .provenance = .{ .external = .{
                    .start_absolute = start,
                    .span = 2 * (protocol.header_size + 1),
                } },
            } },
            .{
                .identity = identity,
                .start_absolute = start + protocol.header_size + 1,
                .end_absolute = start + 2 * (protocol.header_size + 1),
            },
            &source,
            &replacement,
        );
    }
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.finishLiveBatch(&batch),
    );
    try std.testing.expectEqual(@as(usize, 2), probe.alloc_count);
    try std.testing.expectEqual(@as(usize, 2), probe.free_count);

    // Restore only the injected hostile drift so abort proves all original sources
    // remained recoverable without trusting callback-mutated cleanup authority.
    batch.allocator = sealed_allocator;
    batch.mutations[max_live_mutations - 1] = .empty;
    batch.coalesced_replacements[max_live_mutations - 1].logical_len = 0;
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try ledger.finish();
}

test "live simulation digest covers every occupancy and cleared word — tampering either bitset at the first or last slot is InvalidPlan" {
    // `liveSimulationDigest` 가 비트셋을 **워드째** 넣는다(비트 8,192개 → 워드 128개). 같은 정보인지는
    // 「어느 비트를 바꿔도 다음 준비 호출이 거부하는가」로 잰다 — 첫 워드와 마지막 워드, 점유·비움 두
    // 비트셋 모두. 워드 일부만 넣거나 한 비트셋을 빠뜨리는 뮤턴트가 여기서 죽는다(적대적 검증 2026-09-06:
    // 이 계약을 지키는 판정자가 그전엔 없었다).
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = OwnedPayload.empty(allocator);
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    inline for (.{ @as(usize, 0), max_items - 1 }) |slot| {
        var occupied: PreparedLiveBatch = .{};
        try ledger.beginLiveCleanupBatch(&occupied);
        occupied.working_simulation.occupied_slots.toggle(slot);
        try std.testing.expectError(
            error.InvalidPlan,
            ledger.prepareLiveRelease(&occupied, .{ .existing = token }, .lease),
        );
        var cleared: PreparedLiveBatch = .{};
        try ledger.beginLiveCleanupBatch(&cleared);
        cleared.working_simulation.cleared_slots.toggle(slot);
        try std.testing.expectError(
            error.InvalidPlan,
            ledger.prepareLiveRelease(&cleared, .{ .existing = token }, .lease),
        );
    }
    // 변조 안 한 해제는 그대로 통한다 — 위 거부가 다른 이유가 아니었음을 못박는다.
    try ledger.releaseLease(token);
    try ledger.finish();
}

test "release-only live batch still rejects ledger drift between prepare and finish" {
    // 병합이 없는 배치는 `finishLiveBatch` 가 시뮬레이션을 한 번만 짓는다 — 할당 콜백이 없으니 뒤의
    // 재구성 둘은 같은 입력의 같은 계산이었다. 남은 한 번이 지키는 것, 「준비 뒤 ledger 가 바뀌면 finish
    // 가 거부한다」는 그대로여야 한다. 준비와 finish 사이에 **합법적인** 다른 예약으로 회계를 움직인다.
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = OwnedPayload.empty(allocator);
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveCleanupBatch(&batch);
    try ledger.prepareLiveRelease(&batch, .{ .existing = token }, .lease);
    var other = OwnedPayload.empty(allocator);
    const other_token = try ledger.reserveLease(leaseSemantic(8, false), &other);
    try std.testing.expectError(error.StalePlan, ledger.finishLiveBatch(&batch));
    _ = ledger.abortPreparedLiveBatch(&batch);
    // 낡은 배치를 버린 뒤 ledger 는 멀쩡하다.
    try ledger.releaseLease(other_token);
    try ledger.releaseLease(token);
    try ledger.finish();
}

test "checked live release rejects existing allocator semantic and provenance drift" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 634,
        .destination_slot_addr = 0x6340,
    };
    var ledger: ExternalInboxLedger = .{};
    var admission: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&admission, allocator, identity);
    var payload = try owned(allocator, "x");
    _ = try ledger.prepareLiveAdmission(
        &admission,
        .{ .completed = .{
            .stream_id = 7,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + 1,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&admission);
    var admission_retirement = PreparedLiveRetirement.init(allocator);
    var admission_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &admission,
        &admission_retirement,
        &admission_dispositions,
    );
    const token = admission_dispositions[0].final_live.token;

    const Drift = enum { address, allocator, semantic, provenance };
    for ([_]Drift{ .address, .allocator, .semantic, .provenance }) |drift| {
        var batch: PreparedLiveBatch = .{};
        try ledger.beginLiveBatch(&batch, allocator, identity);
        try ledger.prepareLiveRelease(
            &batch,
            .{ .existing = token },
            .completed,
        );
        try ledger.finishLiveBatch(&batch);
        const original_allocator = ledger.slots[token.slot].payload.allocator;
        const original_ptr = ledger.slots[token.slot].payload.allocation_ptr;
        const original_semantic = ledger.slots[token.slot].semantic;
        switch (drift) {
            .address => ledger.slots[token.slot].payload.allocation_ptr =
                @ptrFromInt(1),
            .allocator => ledger.slots[token.slot].payload.allocator =
                std.heap.page_allocator,
            .semantic => ledger.slots[token.slot].semantic.completed.stream_id += 1,
            .provenance => ledger.slots[token.slot].semantic.completed
                .provenance_span += 1,
        }
        var retirement = PreparedLiveRetirement.init(allocator);
        var dispositions =
            [_]LiveCommitDisposition{.unused} ** max_live_mutations;
        try std.testing.expectError(
            error.StalePlan,
            ledger.commitPreparedLiveBatch(
                &batch,
                &retirement,
                &dispositions,
            ),
        );
        ledger.slots[token.slot].payload.allocation_ptr = original_ptr;
        ledger.slots[token.slot].payload.allocator = original_allocator;
        ledger.slots[token.slot].semantic = original_semantic;
        try std.testing.expectEqual(
            AbortLiveResult.aborted,
            ledger.abortPreparedLiveBatch(&batch),
        );
    }
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        token,
        .completed,
    );
    try ledger.finish();
}

test "copied live batch cannot commit or abort and canonical batch remains usable" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 631,
        .destination_slot_addr = 0x6310,
    };
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, allocator, identity);
    var payload = try owned(allocator, "canonical");
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size + "canonical".len,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);

    var copied = batch;
    var copied_retirement = PreparedLiveRetirement.init(allocator);
    var copied_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitPreparedLiveBatch(
            &copied,
            &copied_retirement,
            &copied_dispositions,
        ),
    );
    try std.testing.expectEqual(
        AbortLiveResult.ignored_untrusted,
        ledger.abortPreparedLiveBatch(&copied),
    );

    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &batch,
        &retirement,
        &dispositions,
    );
    const token = dispositions[0].final_live.token;
    try releaseExternalLiveForTest(
        &ledger,
        allocator,
        identity,
        token,
        .completed,
    );
    try ledger.finish();
}

test "live batch descriptor drift quarantines abort without touching ledger" {
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.heap.page_allocator, .{
        .attach_instance_id = 632,
        .destination_slot_addr = 0x6320,
    });
    var payload = OwnedPayload.empty(std.heap.page_allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
            .provenance = .{ .external = .{
                .start_absolute = 0,
                .span = protocol.header_size,
            } },
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    batch.mutations[0].admission.payload_fingerprint.logical_len = 1;

    try std.testing.expectEqual(
        AbortLiveResult.quarantined,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try ledger.finish();
}

test "zero-mutation live batch cannot become an epoch writer" {
    var ledger: ExternalInboxLedger = .{};
    const before = ledger.accountingView();
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.testing.allocator, null);
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.finishLiveBatch(&batch),
    );
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expectEqualDeep(before, ledger.accountingView());
    try ledger.finish();
}

test "preparing live abort rejects hidden tail after mutation count decrease" {
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.testing.allocator, null);
    var first = OwnedPayload.empty(std.testing.allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
        } },
        &first,
    );
    var second = OwnedPayload.empty(std.testing.allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 2,
            .is_snapshot = false,
        } },
        &second,
    );
    batch.mutation_count = 1;
    try std.testing.expectEqual(
        AbortLiveResult.quarantined,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try ledger.finish();
}

test "checked live commit validates count bounds before digest slices" {
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.testing.allocator, null);
    var payload = OwnedPayload.empty(std.testing.allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(std.testing.allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;

    batch.mutation_count = @intCast(max_live_mutations + 1);
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    batch.mutation_count = 1;
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try ledger.finish();
}

test "checked live commit rejects noncanonical hidden retirement tail" {
    var ledger: ExternalInboxLedger = .{};
    var batch: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&batch, std.testing.allocator, null);
    var payload = OwnedPayload.empty(std.testing.allocator);
    _ = try ledger.prepareLiveAdmission(
        &batch,
        .{ .completed = .{
            .stream_id = 1,
            .is_snapshot = false,
        } },
        &payload,
    );
    try ledger.finishLiveBatch(&batch);
    var retirement = PreparedLiveRetirement.init(std.testing.allocator);
    retirement.cleanup_owners[max_live_cleanup_owners - 1].logical_len = 1;
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectError(
        error.InvalidPlan,
        ledger.commitPreparedLiveBatch(
            &batch,
            &retirement,
            &dispositions,
        ),
    );
    retirement = PreparedLiveRetirement.init(std.testing.allocator);
    try std.testing.expectEqual(
        AbortLiveResult.aborted,
        ledger.abortPreparedLiveBatch(&batch),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try ledger.finish();
}

test "live replacement allocation fail index preserves ledger and aborts both sources exactly" {
    const allocator = std.testing.allocator;
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        var ledger: ExternalInboxLedger = .{};
        const identity = external_rx_types.RxIdentity{
            .attach_instance_id = 64,
            .destination_slot_addr = 0x6400,
        };
        var batch: PreparedLiveBatch = .{};
        try ledger.beginLiveBatch(&batch, failing.allocator(), identity);
        var first = try owned(allocator, "a");
        const first_ref = try ledger.prepareLiveAdmission(
            &batch,
            .{ .partial = .{
                .stream_id = 1,
                .is_snapshot = false,
                .chunk_count = 1,
                .provenance = .{ .external = .{
                    .start_absolute = 0,
                    .span = protocol.header_size + 1,
                } },
            } },
            &first,
        );
        var second_owner = try owned(allocator, "b");
        var source: PreparedLiveMergeSource = .{ .owned = second_owner };
        second_owner = OwnedPayload.empty(allocator);
        var replacement: PreparedLiveReplacement = .coalesced;
        try ledger.prepareLiveMerge(
            &batch,
            first_ref,
            .{ .completed = .{
                .stream_id = 1,
                .is_snapshot = false,
                .provenance = .{ .external = .{
                    .start_absolute = 0,
                    .span = 2 * (protocol.header_size + 1),
                } },
            } },
            .{
                .identity = identity,
                .start_absolute = protocol.header_size + 1,
                .end_absolute = 2 * (protocol.header_size + 1),
            },
            &source,
            &replacement,
        );
        if (fail_index == 0) {
            try std.testing.expectError(
                error.OutOfMemory,
                ledger.finishLiveBatch(&batch),
            );
            try std.testing.expect(ledger.accountingView().pristine_zero);
            try std.testing.expectEqual(
                AbortLiveResult.aborted,
                ledger.abortPreparedLiveBatch(&batch),
            );
        } else {
            try ledger.finishLiveBatch(&batch);
            var retirement = PreparedLiveRetirement.init(allocator);
            var dispositions =
                [_]LiveCommitDisposition{.unused} ** max_live_mutations;
            _ = try ledger.commitPreparedLiveBatch(
                &batch,
                &retirement,
                &dispositions,
            );
            const token = dispositions[1].final_live.token;
            try std.testing.expectEqual(
                RetireLiveResult.retired,
                retirement.retire(),
            );
            try releaseExternalLiveForTest(
                &ledger,
                allocator,
                identity,
                token,
                .completed,
            );
        }
        try ledger.finish();
    }
}

test "64-mutation live batch sweeps every replacement allocation fail index" {
    const allocator = std.testing.allocator;
    const allocation_count = max_live_mutations / 2;
    for (0..allocation_count + 1) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        var ledger: ExternalInboxLedger = .{};
        const identity = external_rx_types.RxIdentity{
            .attach_instance_id = 641,
            .destination_slot_addr = 0x6410,
        };
        var batch: PreparedLiveBatch = .{};
        try ledger.beginLiveBatch(&batch, failing.allocator(), identity);
        errdefer _ = ledger.abortPreparedLiveBatch(&batch);
        for (0..allocation_count) |index| {
            const stream_id = index + 1;
            const start = index * 2 * (protocol.header_size + 1);
            var first = try owned(allocator, "a");
            const current = try ledger.prepareLiveAdmission(
                &batch,
                .{ .partial = .{
                    .stream_id = stream_id,
                    .is_snapshot = false,
                    .chunk_count = 1,
                    .provenance = .{ .external = .{
                        .start_absolute = start,
                        .span = protocol.header_size + 1,
                    } },
                } },
                &first,
            );
            var source_owner = try owned(allocator, "a");
            var source: PreparedLiveMergeSource = .{ .owned = source_owner };
            source_owner = OwnedPayload.empty(allocator);
            var replacement: PreparedLiveReplacement = .coalesced;
            try ledger.prepareLiveMerge(
                &batch,
                current,
                .{ .completed = .{
                    .stream_id = stream_id,
                    .is_snapshot = false,
                    .provenance = .{ .external = .{
                        .start_absolute = start,
                        .span = 2 * (protocol.header_size + 1),
                    } },
                } },
                .{
                    .identity = identity,
                    .start_absolute = start + protocol.header_size + 1,
                    .end_absolute = start + 2 * (protocol.header_size + 1),
                },
                &source,
                &replacement,
            );
        }
        try std.testing.expectEqual(
            @as(u8, max_live_mutations),
            batch.mutation_count,
        );
        if (fail_index < allocation_count) {
            try std.testing.expectError(
                error.OutOfMemory,
                ledger.finishLiveBatch(&batch),
            );
            try std.testing.expect(ledger.accountingView().pristine_zero);
            try std.testing.expectEqual(
                AbortLiveResult.aborted,
                ledger.abortPreparedLiveBatch(&batch),
            );
        } else {
            try ledger.finishLiveBatch(&batch);
            var retirement = PreparedLiveRetirement.init(allocator);
            var dispositions =
                [_]LiveCommitDisposition{.unused} ** max_live_mutations;
            try std.testing.expectEqual(
                @as(u8, allocation_count),
                try ledger.commitPreparedLiveBatch(
                    &batch,
                    &retirement,
                    &dispositions,
                ),
            );
            try std.testing.expectEqual(
                RetireLiveResult.retired,
                retirement.retire(),
            );
            const report = try ledger.drainAll();
            try std.testing.expectEqual(
                @as(usize, allocation_count),
                report.drained_active_count,
            );
        }
        try ledger.finish();
    }
}

test "live batch reaches exact 128 cleanup and 64 replacement retirement caps" {
    const allocator = std.testing.allocator;
    const identity = external_rx_types.RxIdentity{
        .attach_instance_id = 642,
        .destination_slot_addr = 0x6420,
    };
    var ledger: ExternalInboxLedger = .{};
    var admissions: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&admissions, allocator, identity);
    for (0..max_live_mutations) |index| {
        var payload = OwnedPayload.empty(allocator);
        _ = try ledger.prepareLiveAdmission(
            &admissions,
            .{ .partial = .{
                .stream_id = index + 1,
                .is_snapshot = false,
                .chunk_count = 1,
                .provenance = .{ .external = .{
                    .start_absolute = index * 2 * protocol.header_size,
                    .span = protocol.header_size,
                } },
            } },
            &payload,
        );
    }
    try ledger.finishLiveBatch(&admissions);
    var admission_retirement = PreparedLiveRetirement.init(allocator);
    var admission_dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    _ = try ledger.commitPreparedLiveBatch(
        &admissions,
        &admission_retirement,
        &admission_dispositions,
    );

    var merges: PreparedLiveBatch = .{};
    try ledger.beginLiveBatch(&merges, allocator, identity);
    for (0..max_live_mutations) |index| {
        const start = index * 2 * protocol.header_size;
        var source: PreparedLiveMergeSource = .{
            .owned = OwnedPayload.empty(allocator),
        };
        var replacement: PreparedLiveReplacement = .coalesced;
        try ledger.prepareLiveMerge(
            &merges,
            .{ .existing = admission_dispositions[index].final_live.token },
            .{ .completed = .{
                .stream_id = index + 1,
                .is_snapshot = false,
                .provenance = .{ .external = .{
                    .start_absolute = start,
                    .span = 2 * protocol.header_size,
                } },
            } },
            .{
                .identity = identity,
                .start_absolute = start + protocol.header_size,
                .end_absolute = start + 2 * protocol.header_size,
            },
            &source,
            &replacement,
        );
    }
    try ledger.finishLiveBatch(&merges);
    try std.testing.expectEqual(
        @as(u8, max_live_mutations),
        merges.replacement_count,
    );
    var retirement = PreparedLiveRetirement.init(allocator);
    var dispositions =
        [_]LiveCommitDisposition{.unused} ** max_live_mutations;
    try std.testing.expectEqual(
        @as(u8, max_live_mutations),
        try ledger.commitPreparedLiveBatch(
            &merges,
            &retirement,
            &dispositions,
        ),
    );
    try std.testing.expectEqual(
        @as(u8, max_live_cleanup_owners),
        retirement.cleanup_count,
    );
    try std.testing.expectEqual(
        @as(u8, max_live_mutations),
        retirement.replacement_count,
    );
    try std.testing.expectEqual(
        RetireLiveResult.retired,
        retirement.retire(),
    );
    const report = try ledger.drainAll();
    try std.testing.expectEqual(
        @as(usize, max_live_mutations),
        report.drained_active_count,
    );
    try ledger.finish();
}

test "live retirement tombstones before first callback and keeps later targets local" {
    var probe = LiveRetirementMutationProbe{
        .parent = std.testing.allocator,
    };
    const allocator = probe.allocator();
    var retirement = PreparedLiveRetirement.init(allocator);
    appendLiveRetirementUnchecked(
        &retirement,
        try owned(allocator, "first"),
    );
    appendLiveRetirementUnchecked(
        &retirement,
        try owned(allocator, "second"),
    );
    sealLiveRetirementForTest(&retirement);
    probe.retirement = &retirement;

    try std.testing.expectEqual(
        RetireLiveResult.retired,
        retirement.retire(),
    );
    try std.testing.expectEqual(
        RetireLiveResult.already_retired,
        probe.nested_result.?,
    );
    try std.testing.expectEqual(@as(usize, 2), probe.free_count);
    try std.testing.expectEqual(
        LiveRetirementLifecycle.retired,
        retirement.lifecycle,
    );
}

test "live retirement rejects exact and partial cleanup aliases before free" {
    for ([_]bool{ false, true }) |partial| {
        var probe = LiveRetirementMutationProbe{
            .parent = std.testing.allocator,
            .fired = true,
        };
        const allocator = probe.allocator();
        var original = try owned(allocator, "alias");
        var retirement = PreparedLiveRetirement.init(allocator);
        appendLiveRetirementUnchecked(&retirement, original);
        var alias = original;
        if (partial) {
            alias.allocation_ptr = original.allocation_ptr.? + 1;
            alias.logical_len -= 1;
        }
        appendLiveRetirementUnchecked(&retirement, alias);
        sealLiveRetirementForTest(&retirement);

        try std.testing.expectEqual(
            RetireLiveResult.quarantined,
            retirement.retire(),
        );
        try std.testing.expectEqual(@as(usize, 0), probe.free_count);
        original.deinit();
        try std.testing.expectEqual(@as(usize, 1), probe.free_count);
    }
}

test "live retirement rejects cleanup replacement overlap before free" {
    var probe = LiveRetirementMutationProbe{
        .parent = std.testing.allocator,
        .fired = true,
    };
    const allocator = probe.allocator();
    var original = try owned(allocator, "overlap");
    var retirement = PreparedLiveRetirement.init(allocator);
    appendLiveRetirementUnchecked(&retirement, original);
    retirement.published_replacements[0] = .{
        .addr = @intFromPtr(original.allocation_ptr.?) + 1,
        .len = original.logical_len - 1,
    };
    retirement.replacement_count = 1;
    retirement.replacement_bytes = original.logical_len - 1;
    sealLiveRetirementForTest(&retirement);

    try std.testing.expectEqual(
        RetireLiveResult.quarantined,
        retirement.retire(),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.free_count);
    original.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.free_count);
}

test "live retirement descriptor and digest drift quarantines without free or retry" {
    var probe = LiveRetirementMutationProbe{
        .parent = std.testing.allocator,
        .fired = true,
    };
    const allocator = probe.allocator();
    var original = try owned(allocator, "drift");
    var retirement = PreparedLiveRetirement.init(allocator);
    appendLiveRetirementUnchecked(&retirement, original);
    sealLiveRetirementForTest(&retirement);
    retirement.cleanup_plans[0].len += 1;

    try std.testing.expectEqual(
        RetireLiveResult.quarantined,
        retirement.retire(),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.free_count);
    try std.testing.expectEqual(
        RetireLiveResult.quarantined,
        retirement.retire(),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.free_count);
    original.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.free_count);
}

test "live retirement count cap plus one quarantines before slicing" {
    var cleanup_overflow = PreparedLiveRetirement.init(std.testing.allocator);
    cleanup_overflow.saved_self_addr = @intFromPtr(&cleanup_overflow);
    cleanup_overflow.lifecycle = .prepared;
    cleanup_overflow.cleanup_count = @intCast(max_live_cleanup_owners + 1);
    try std.testing.expectEqual(
        RetireLiveResult.quarantined,
        cleanup_overflow.retire(),
    );

    var replacement_overflow =
        PreparedLiveRetirement.init(std.testing.allocator);
    replacement_overflow.saved_self_addr =
        @intFromPtr(&replacement_overflow);
    replacement_overflow.lifecycle = .prepared;
    replacement_overflow.replacement_count =
        @intCast(max_live_mutations + 1);
    try std.testing.expectEqual(
        RetireLiveResult.quarantined,
        replacement_overflow.retire(),
    );
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
    const report = try ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectEqual(@as(usize, 2), report.drained_active_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "drain sweeps lost descriptors and is idempotent" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "lost");
    _ = try ledger.reserveLease(leaseSemantic(7, true), &payload);
    const first = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 1), first.drained_active_count);
    try std.testing.expectEqual(@as(usize, 4), first.drained_bytes);
    const second = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 0), second.drained_active_count);
    try std.testing.expectError(error.Drained, ledger.reserveLease(leaseSemantic(7, true), &payload));
    try ledger.finish();
}

test "drain repairs inactive payload and counter corruption without double free" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    ledger.slots[3].payload = try owned(allocator, "orphan");
    ledger.charged_items = 99;
    const report = try ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
    const second = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 0), second.drained_bytes);
}

test "drain reports active semantic corruption" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "x");
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    ledger.slots[token.slot].semantic.lease.stream_id = 0;
    const report = try ledger.drainAll();
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
    const report = try ledger.drainAll();
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
    const report = try ledger.drainAll();
    try std.testing.expect(report.had_sticky_invariant);
}

test "owner teardown prepare is mutation-free and rejects copied authority" {
    var ledger: ExternalInboxLedger = .{};
    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(1, &permit);
    var copied_permit = permit;
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(&.{}, std.StaticBitSet(max_items).initEmpty());
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};

    const ledger_before = ledger;
    const permit_before = permit;
    try std.testing.expectError(
        error.InvalidPermit,
        ledger.prepareFreezeAllForOwnerTeardown(
            &copied_permit,
            &token_plan,
            &prepared,
            &frozen,
        ),
    );
    try std.testing.expect(std.meta.eql(ledger_before, ledger));
    try std.testing.expect(std.meta.eql(permit_before, permit));
    try std.testing.expectEqual(
        PreparedLedgerTeardownLifecycle.empty,
        prepared.lifecycle,
    );
}

test "owner teardown rejects structural aliases before dereferencing outputs" {
    var ledger: ExternalInboxLedger = .{};
    const before = ledger;
    const aliased_permit: *OwnerTeardownPermit = @ptrCast(@alignCast(&ledger));
    try std.testing.expectError(
        error.InvalidPermit,
        ledger.beginOwnerTeardown(1, aliased_permit),
    );
    try std.testing.expect(std.meta.eql(before, ledger));

    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(1, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(&.{}, std.StaticBitSet(max_items).initEmpty());
    const aliased_prepared: *PreparedLedgerTeardown = @ptrCast(@alignCast(&ledger));
    var frozen: FrozenLedgerCleanup = .{};
    const permit_before = permit;
    try std.testing.expectError(
        error.InvalidPermit,
        ledger.prepareFreezeAllForOwnerTeardown(
            &permit,
            &token_plan,
            aliased_prepared,
            &frozen,
        ),
    );
    try std.testing.expect(std.meta.eql(before, ledger));
    try std.testing.expect(std.meta.eql(permit_before, permit));
}

test "screen teardown token plan rejects tail bits and same-slot ABA" {
    var tail = std.StaticBitSet(max_items).initEmpty();
    tail.set(1);
    var tail_plan: FrozenScreenTokenPlan = .{};
    try std.testing.expectError(
        error.InvariantFailure,
        tail_plan.initInPlace(
            &.{.{ .slot = 0, .generation = 1 }},
            tail,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), tail_plan.saved_self_addr);

    var aba_plan: FrozenScreenTokenPlan = .{};
    try std.testing.expectError(
        error.InvariantFailure,
        aba_plan.initInPlace(
            &.{
                .{ .slot = 0, .generation = 1 },
                .{ .slot = 0, .generation = 2 },
            },
            std.StaticBitSet(max_items).initEmpty(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), aba_plan.saved_self_addr);
}

test "screen teardown token plan appends live owners atomically" {
    var plan: FrozenScreenTokenPlan = .{};
    var released = std.StaticBitSet(max_items).initEmpty();
    released.set(1);
    try plan.initInPlace(
        &.{
            .{ .slot = 1, .generation = 10 },
            .{ .slot = 2, .generation = 20 },
        },
        released,
    );
    try plan.appendRetainedTokens(&.{
        .{ .slot = 3, .generation = 30 },
        .{ .slot = 4, .generation = 40 },
    });
    try std.testing.expectEqual(@as(usize, 4), plan.len);
    try std.testing.expect(plan.isValid());

    const before = plan;
    try std.testing.expectError(
        error.InvariantFailure,
        plan.appendRetainedTokens(&.{
            .{ .slot = 2, .generation = 99 },
        }),
    );
    try std.testing.expectEqualDeep(before, plan);
    try std.testing.expectError(
        error.InvariantFailure,
        plan.appendRetainedTokens(&.{
            .{ .slot = 5, .generation = 1 },
            .{ .slot = 5, .generation = 2 },
        }),
    );
    try std.testing.expectEqualDeep(before, plan);
}

test "owner teardown freezes all payloads before cleanup and closes ordinary APIs" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var first_payload = try owned(allocator, "first");
    var second_payload = try owned(allocator, "second");
    const first = try ledger.reserveLease(leaseSemantic(7, false), &first_payload);
    _ = try ledger.reserveLease(leaseSemantic(8, false), &second_payload);

    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(9, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(
        &.{first},
        std.StaticBitSet(max_items).initEmpty(),
    );
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};
    try ledger.prepareFreezeAllForOwnerTeardown(
        &permit,
        &token_plan,
        &prepared,
        &frozen,
    );
    try std.testing.expectEqual(@as(usize, 1), prepared.summary.orphan_count);
    try std.testing.expect(!prepared.summary.had_invariant);
    try std.testing.expectEqual(@as(usize, 2), ledger.charged_items);

    const summary = ledger.commitFreezeAllForOwnerTeardownUnchecked(
        &permit,
        &prepared,
        &frozen,
    );
    try std.testing.expectEqual(@as(usize, 1), summary.orphan_count);
    try std.testing.expectEqual(@as(usize, 2), frozen.count);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expect(ledger.teardown_active);
    try std.testing.expectEqual(OwnerTeardownPermitLifecycle.finished, permit.lifecycle);
    try std.testing.expectError(error.TeardownActive, ledger.borrowLease(first));
    var empty_payload = OwnedPayload.empty(allocator);
    try std.testing.expectError(
        error.TeardownActive,
        ledger.reserveLease(leaseSemantic(9, false), &empty_payload),
    );
    try std.testing.expectError(error.TeardownActive, ledger.drainAll());
    try std.testing.expectError(error.TeardownActive, ledger.finish());

    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.cleaned,
        frozen.finishCallbackHidden(),
    );
    try std.testing.expectEqual(
        FrozenLedgerCleanupLifecycle.cleaned_tombstone,
        frozen.lifecycle,
    );
    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.already_cleaned,
        frozen.finishCallbackHidden(),
    );
}

test "frozen cleanup never rereads descriptors mutated by the first free callback" {
    var probe: FrozenCleanupMutationProbe = .{ .parent = std.testing.allocator };
    const allocator = probe.allocator();
    var ledger: ExternalInboxLedger = .{};
    probe.ledger = &ledger;
    var first_payload = try owned(allocator, "first");
    var second_payload = try owned(allocator, "second");
    _ = try ledger.reserveLease(leaseSemantic(7, false), &first_payload);
    _ = try ledger.reserveLease(leaseSemantic(8, false), &second_payload);

    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(1, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(&.{}, std.StaticBitSet(max_items).initEmpty());
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};
    try ledger.prepareFreezeAllForOwnerTeardown(
        &permit,
        &token_plan,
        &prepared,
        &frozen,
    );
    _ = ledger.commitFreezeAllForOwnerTeardownUnchecked(
        &permit,
        &prepared,
        &frozen,
    );
    probe.frozen = &frozen;

    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.cleaned,
        frozen.finishCallbackHidden(),
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(@as(usize, 2), probe.free_count);
    try std.testing.expectEqual(
        FrozenLedgerCleanupLifecycle.cleaned_tombstone,
        frozen.lifecycle,
    );
}

test "frozen cleanup rejects callback resurrection and re-tombstones on return" {
    var probe: FrozenCleanupMutationProbe = .{
        .parent = std.testing.allocator,
        .resurrect = true,
    };
    const allocator = probe.allocator();
    var ledger: ExternalInboxLedger = .{};
    probe.ledger = &ledger;
    var first_payload = try owned(allocator, "first");
    var second_payload = try owned(allocator, "second");
    _ = try ledger.reserveLease(leaseSemantic(7, false), &first_payload);
    _ = try ledger.reserveLease(leaseSemantic(8, false), &second_payload);
    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(1, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(&.{}, std.StaticBitSet(max_items).initEmpty());
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};
    try ledger.prepareFreezeAllForOwnerTeardown(
        &permit,
        &token_plan,
        &prepared,
        &frozen,
    );
    _ = ledger.commitFreezeAllForOwnerTeardownUnchecked(
        &permit,
        &prepared,
        &frozen,
    );
    probe.frozen = &frozen;
    probe.saved_frozen = frozen;

    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.cleaned,
        frozen.finishCallbackHidden(),
    );
    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.invalid,
        probe.nested_finish.?,
    );
    try std.testing.expectEqual(@as(usize, 2), probe.free_count);
    try std.testing.expectEqual(
        FrozenLedgerCleanupLifecycle.cleaned_tombstone,
        frozen.lifecycle,
    );
}

test "owner teardown classifies stale retained token without mutating prepare inputs" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    var payload = try owned(allocator, "payload");
    const token = try ledger.reserveLease(leaseSemantic(7, false), &payload);
    var permit: OwnerTeardownPermit = .{};
    try ledger.beginOwnerTeardown(1, &permit);
    var token_plan: FrozenScreenTokenPlan = .{};
    try token_plan.initInPlace(
        &.{.{ .slot = token.slot, .generation = token.generation + 1 }},
        std.StaticBitSet(max_items).initEmpty(),
    );
    var prepared: PreparedLedgerTeardown = .{};
    var frozen: FrozenLedgerCleanup = .{};
    try ledger.prepareFreezeAllForOwnerTeardown(
        &permit,
        &token_plan,
        &prepared,
        &frozen,
    );
    try std.testing.expect(prepared.summary.had_invariant);
    try std.testing.expectEqual(@as(usize, 1), prepared.summary.orphan_count);

    _ = ledger.commitFreezeAllForOwnerTeardownUnchecked(
        &permit,
        &prepared,
        &frozen,
    );
    try std.testing.expectEqual(
        FrozenLedgerCleanupFinishResult.cleaned,
        frozen.finishCallbackHidden(),
    );
}
