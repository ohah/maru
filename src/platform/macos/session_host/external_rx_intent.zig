//! Address-bound ownership mechanics for classified external RX frames.
//!
//! This module deliberately knows neither `ExternalPumpStorage` nor the inbox ledger. The pump
//! facade owns storage reservation and terminal policy; this leaf owns the one heap allocation,
//! the exact-once frame payload transfer, replay watermarks, and callback-hidden abort cleanup.

const std = @import("std");
const builtin = @import("builtin");
const client_external_mode = @import("client_external_mode.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const external_owner_range = @import("external_owner_range.zig");
const external_owner_cleanup = @import("external_owner_cleanup.zig");
const external_rx_demux = @import("external_rx_demux.zig");
const external_rx_types = @import("external_rx_types.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");

pub const max_intents: usize = 64;
pub const max_authority_ranges: usize = external_owner_range.max_ranges;
pub const max_scratch_bytes: usize = 384 * 1024;
pub const max_intent_quarantine_bytes: usize = max_scratch_bytes + 1024 * 1024;

comptime {
    if (max_intent_quarantine_bytes != 1_441_792)
        @compileError("intent quarantine accounting drifted");
}

pub const AuthorityView = struct {
    storage_addr: usize,
    storage_len: usize,
    operation_generation: u64,
    parser_generation: u64,
    buffer_start_absolute: u64,
    identity: external_rx_types.RxIdentity,
    allocator: std.mem.Allocator,
    forbidden_ranges: []const external_owner_range.Range = &.{},
    forbidden_ranges_generation: u64 = 1,
    forbidden_ranges_digest: external_owner_seal.Digest = blk: {
        @setEvalBranchQuota(10_000);
        break :blk authorityRangesDigest(&.{}, 1);
    },
    /// Product-owned operation scratch which must never become allocator-owned intent state.
    /// This is carried as a sealed authority scalar instead of being appended to
    /// `forbidden_ranges`: that range array is itself stored inside the operation scratch.
    operation_scratch_addr: usize = 0,
    operation_scratch_len: usize = 0,
    operation_lease_addr: usize = 0,
    operation_lease_len: usize = 0,
    reservation_handle_addr: usize,
    reservation_generation: u64,
};

pub const AuthorityOps = struct {
    context: *anyopaque,
    current: *const fn (context: *anyopaque) ?AuthorityView,
};

const ScratchLifecycle = enum {
    allocated,
    ready,
    busy,
    spent,
    poisoned,
    destroying,
};

const IntentLifecycle = enum {
    empty,
    classified,
    aborted,
    committed,
};

const MovedIntentPayloadLifecycle = enum {
    empty,
    owned,
    moved,
    aborted,
    poisoned,
};

pub const HandleLifecycle = enum {
    empty,
    allocated,
    ready,
    destroying,
    destroyed,
    poisoned,
};

const ClassifiedIntentOwner = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    turn_generation: u64 = 0,
    parser_generation: u64 = 0,
    frame: framing.Frame = .{
        .header = .{
            .major = 0,
            .kind = @enumFromInt(0),
            .stream_id = 0,
            .request_id = 0,
            .flags = 0,
            .payload_len = 0,
        },
        .payload = &.{},
    },
    range: external_rx_types.RxRange = .{
        .identity = .{},
        .start_absolute = 0,
        .end_absolute = 0,
    },
    pair_seal: client_external_mode.ExternalRxFrameSeal = [_]u8{0} ** 32,
    payload_addr: usize = 0,
    payload_len: usize = 0,
    payload_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    classification: external_rx_demux.ExternalWireClass = .protocol_terminal,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    cleanup_payload: ?[]u8 = null,
    cleanup_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: IntentLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const MovedIntentPayload = struct {
    saved_self_addr: usize = 0,
    source_intent_addr: usize = 0,
    aggregate_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    allocation_addr: usize = 0,
    allocation_len: usize = 0,
    content_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: MovedIntentPayloadLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const BorrowedMovedPayloadView = struct {
    allocator: std.mem.Allocator,
    allocation_addr: usize,
    allocation_len: usize,
    content_digest: external_owner_seal.Digest,
};

pub const BorrowedMovedScreenView = struct {
    payload: BorrowedMovedPayloadView,
    candidate: external_rx_demux.ScreenCandidate,
};

pub const BorrowedClassifiedEventView = struct {
    payload: []const u8,
    allocator: std.mem.Allocator,
    payload_digest: external_owner_seal.Digest,
    candidate: external_rx_demux.EventCandidate,
};

const ScreenMutationProofLifecycle = enum {
    empty,
    prepared,
    consumed,
};

pub const StagedScreenMutationProof = struct {
    saved_self_addr: usize = 0,
    source_intent_addr: usize = 0,
    aggregate_addr: usize = 0,
    batch_addr: usize = 0,
    intent_index: u8 = 0,
    mutation_index: u8 = 0,
    payload_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: ScreenMutationProofLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const IntentCommitLifecycle = enum {
    empty,
    prepared,
    consumed,
    aborted,
};

pub const IntentCommitSlotKind = enum {
    unused,
    screen,
    event,
    response,
};

pub const PreparedIntentCommit = struct {
    saved_self_addr: usize = 0,
    handle_addr: usize = 0,
    scratch_addr: usize = 0,
    aggregate_addr: usize = 0,
    aggregate_len: usize = 0,
    proofs_addr: usize = 0,
    neutral_outputs_addr: usize = 0,
    proof_count: u8 = 0,
    intent_count: u8 = 0,
    final_parser_generation: u64 = 0,
    final_end_absolute: u64 = 0,
    slot_kinds: [max_intents]IntentCommitSlotKind =
        [_]IntentCommitSlotKind{.unused} ** max_intents,
    response_request_ids: [max_intents]u64 = [_]u64{0} ** max_intents,
    source_parser_generations: [max_intents]u64 = [_]u64{0} ** max_intents,
    source_start_absolutes: [max_intents]u64 = [_]u64{0} ** max_intents,
    source_end_absolutes: [max_intents]u64 = [_]u64{0} ** max_intents,
    source_owner_digests: [max_intents]external_owner_seal.Digest =
        [_]external_owner_seal.Digest{[_]u8{0} ** 32} ** max_intents,
    payload_digests: [max_intents]external_owner_seal.Digest =
        [_]external_owner_seal.Digest{[_]u8{0} ** 32} ** max_intents,
    destination_plan_addr: usize = 0,
    destination_plan_len: usize = 0,
    destination_plan_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: IntentCommitLifecycle = .empty,
    proofs_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    neutral_outputs_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const NeutralRetirementLifecycle = enum {
    empty,
    prepared,
    consumed,
};

/// Non-owning, final-address proof that one classified event owner will become the exact
/// aggregate neutral slot named here. Cleanup authority is deliberately absent until the
/// enclosing intent commit has tombstoned the classified source.
pub const PreparedNeutralRetirement = struct {
    saved_self_addr: usize = 0,
    handle_addr: usize = 0,
    scratch_addr: usize = 0,
    intent_commit_addr: usize = 0,
    aggregate_addr: usize = 0,
    aggregate_len: usize = 0,
    neutral_addr: usize = 0,
    cleanup_output_addr: usize = 0,
    source_intent_addr: usize = 0,
    intent_index: u8 = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    allocation_addr: usize = 0,
    allocation_len: usize = 0,
    content_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    source_owner_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: NeutralRetirementLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const StagedScreenIntent = struct {
    saved_self_addr: usize,
    storage_addr: usize,
    turn_generation: u64,
    parser_generation: u64,
    source_start_absolute: u64,
    source_end_absolute: u64,
    aggregate_addr: usize,
    neutral_addr: usize,
    classification: external_rx_demux.ScreenCandidate,
    payload_addr: usize,
    payload_len: usize,
    payload_digest: external_owner_seal.Digest,
    digest: external_owner_seal.Digest,
};

const PreparedRxIntent = union(enum) {
    empty,
    classified: ClassifiedIntentOwner,
    screen_staging: StagedScreenIntent,
    committed,
    aborted,
};

const ExternalRxIntentScratch = struct {
    saved_self_addr: usize,
    handle_addr: usize,
    allocation_addr: usize,
    allocation_len: usize,
    storage_addr: usize,
    storage_len: usize,
    turn_generation: u64,
    parser_generation_at_start: u64,
    last_parser_generation: u64,
    last_moved_end_absolute: u64,
    intents: [max_intents]PreparedRxIntent,
    intent_count: u8,
    lifecycle: ScratchLifecycle,
    digest: external_owner_seal.Digest,
};

pub const testing = if (builtin.is_test) struct {
    pub const scratch_allocation_bytes = @sizeOf(ExternalRxIntentScratch);
} else struct {};

pub const ExternalRxIntentHandle = struct {
    saved_self_addr: usize = 0,
    scratch_addr: usize = 0,
    allocation_addr: usize = 0,
    allocation_len: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    cleanup_allocator: ?std.mem.Allocator = null,
    storage_addr: usize = 0,
    reservation_generation: u64 = 0,
    lifecycle: HandleLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const CreateResult = enum {
    allocated,
    out_of_memory,
    invalid_handle,
    authority_drift,
    quarantined,
};

pub const BindResult = enum {
    bound,
    invalid_handle,
    authority_drift,
};

pub const MoveResult = enum {
    classified,
    protocol_terminal,
    capacity,
    invalid_source,
    authority_drift,
    replay,
    alias,
    poisoned,
};

pub const PartialAfterMoveResult = union(enum) {
    unchanged,
    advanced: ?external_rx_demux.ValidatedPartialView,
    invalid_state,
};

pub const MoveScreenResult = enum {
    moved,
    invalid_state,
    invalid_index,
    wrong_class,
    authority_drift,
    alias,
};

pub fn sealAuthorityRanges(
    ranges: []const external_owner_range.Range,
    generation: u64,
) ?external_owner_seal.Digest {
    if (generation == 0 or !authorityRangesStructurallyValid(ranges))
        return null;
    return authorityRangesDigest(ranges, generation);
}

pub const AbortResult = enum {
    cleaned,
    already_spent,
    poisoned,
};

pub const ResetResult = enum {
    ready,
    invalid_state,
};

const IntentAbortLifecycle = enum {
    empty,
    prepared,
    committed,
    spent,
};

pub const FrozenIntentAbort = struct {
    saved_self_addr: usize = 0,
    handle_addr: usize = 0,
    scratch_addr: usize = 0,
    aggregate_addr: usize = 0,
    cleanup: [max_intents]external_owner_cleanup.FrozenOwnerCleanupDescriptor =
        [_]external_owner_cleanup.FrozenOwnerCleanupDescriptor{.{}} **
        max_intents,
    cleanup_count: u8 = 0,
    intent_count: u8 = 0,
    lifecycle: IntentAbortLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const DestroyLifecycle = enum { empty, prepared, consumed };

pub const PreparedDestroy = struct {
    saved_self_addr: usize = 0,
    handle_addr: usize = 0,
    scratch_addr: usize = 0,
    storage_addr: usize = 0,
    reservation_generation: u64 = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    cleanup: [max_intents]FrozenPayloadCleanup =
        [_]FrozenPayloadCleanup{.{}} ** max_intents,
    cleanup_count: u8 = 0,
    lifecycle: DestroyLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const FrozenDestroy = struct {
    scratch: *ExternalRxIntentScratch,
    handle: *ExternalRxIntentHandle,
    allocator: std.mem.Allocator,
    cleanup: [max_intents]FrozenPayloadCleanup,
    cleanup_count: u8,
    storage_addr: usize,
    reservation_generation: u64,
};

const FrozenPayloadCleanup = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    payload: []u8 = &.{},
};

comptime {
    if (@sizeOf(ExternalRxIntentScratch) > max_scratch_bytes)
        @compileError("ExternalRxIntentScratch exceeds 384 KiB");
    if (@sizeOf(FrozenIntentAbort) > 64 * 1024)
        @compileError("FrozenIntentAbort exceeds 64 KiB");
}

pub fn allocate(
    handle: *ExternalRxIntentHandle,
    allocator: std.mem.Allocator,
    authority_ops: AuthorityOps,
) CreateResult {
    if (!handlePristine(handle)) return .invalid_handle;
    const before = authority_ops.current(authority_ops.context) orelse
        return .authority_drift;
    if (!authorityViewValid(before) or before.reservation_handle_addr != 0)
        return .authority_drift;
    const allocation_len = @sizeOf(ExternalRxIntentScratch);
    const allocation_bytes = allocator.rawAlloc(
        allocation_len,
        .of(ExternalRxIntentScratch),
        @returnAddress(),
    ) orelse return .out_of_memory;
    const allocation_addr = @intFromPtr(allocation_bytes);
    if (allocation_addr % @alignOf(ExternalRxIntentScratch) != 0 or
        scratchRangeAliasesAuthority(allocation_addr, handle, before))
    {
        // The callback returned memory already claimed by another sealed owner. Its allocator
        // descriptor is therefore not trusted cleanup authority; freeing it could destroy that
        // owner. Leave the bounded allocation quarantined and publish no handle.
        handle.* = .{};
        return .quarantined;
    }
    const after = authority_ops.current(authority_ops.context) orelse {
        // Without a current disjoint inventory, cleanup authority is unprovable.
        handle.* = .{};
        return .quarantined;
    };
    if (!authorityViewValid(before) or !authorityViewValid(after) or
        scratchRangeAliasesAuthority(allocation_addr, handle, after))
    {
        handle.* = .{};
        return .quarantined;
    }
    if (!std.meta.eql(before, after) or !handlePristine(handle)) {
        allocator.rawFree(
            allocation_bytes[0..allocation_len],
            .of(ExternalRxIntentScratch),
            @returnAddress(),
        );
        // The disjoint current inventory proved the allocation can be freed. Publish the caller's
        // canonical failure value only after the free callback, overwriting callback mutation.
        handle.* = .{};
        return .authority_drift;
    }
    const scratch: *ExternalRxIntentScratch = @ptrFromInt(allocation_addr);
    scratch.* = .{
        .saved_self_addr = allocation_addr,
        .handle_addr = @intFromPtr(handle),
        .allocation_addr = allocation_addr,
        .allocation_len = @sizeOf(ExternalRxIntentScratch),
        .storage_addr = before.storage_addr,
        .storage_len = before.storage_len,
        .turn_generation = before.operation_generation,
        .parser_generation_at_start = before.parser_generation,
        .last_parser_generation = before.parser_generation,
        .last_moved_end_absolute = before.buffer_start_absolute,
        .intents = [_]PreparedRxIntent{.empty} ** max_intents,
        .intent_count = 0,
        .lifecycle = .allocated,
        .digest = undefined,
    };
    scratch.digest = scratchDigest(scratch);
    handle.* = .{
        .saved_self_addr = @intFromPtr(handle),
        .scratch_addr = allocation_addr,
        .allocation_addr = allocation_addr,
        .allocation_len = @sizeOf(ExternalRxIntentScratch),
        .allocator_ptr_addr = @intFromPtr(allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(allocator.vtable),
        .allocator = allocator,
        .cleanup_allocator = allocator,
        .storage_addr = before.storage_addr,
        .lifecycle = .allocated,
        .digest = undefined,
    };
    handle.digest = handleDigest(handle);
    return .allocated;
}

pub fn bindReservation(
    handle: *ExternalRxIntentHandle,
    authority: AuthorityView,
) BindResult {
    const scratch = validateHandleAndScratch(handle, .allocated, .allocated) orelse
        return .invalid_handle;
    if (!authorityViewValid(authority) or
        authority.storage_addr != handle.storage_addr or
        authority.reservation_handle_addr != @intFromPtr(handle) or
        authority.reservation_generation == 0 or
        authority.operation_generation != scratch.turn_generation or
        authority.parser_generation != scratch.last_parser_generation or
        authority.buffer_start_absolute != scratch.last_moved_end_absolute or
        scratchRangeAliasesAuthority(
            scratch.allocation_addr,
            handle,
            authority,
        ) or
        !allocatorMatches(authority.allocator, handle.allocator_ptr_addr, handle.allocator_vtable_addr))
        return .authority_drift;
    handle.reservation_generation = authority.reservation_generation;
    handle.lifecycle = .ready;
    handle.digest = handleDigest(handle);
    scratch.lifecycle = .ready;
    scratch.digest = scratchDigest(scratch);
    return .bound;
}

pub fn discardAllocated(handle: *ExternalRxIntentHandle) bool {
    const scratch = validateHandleAndScratch(handle, .allocated, .allocated) orelse
        return false;
    const allocator = handle.cleanup_allocator orelse return false;
    if (!allocatorMatches(
        handle.allocator,
        handle.allocator_ptr_addr,
        handle.allocator_vtable_addr,
    ) or !allocatorMatches(
        allocator,
        handle.allocator_ptr_addr,
        handle.allocator_vtable_addr,
    )) return false;
    handle.* = .{};
    allocator.destroy(scratch);
    return true;
}

pub fn moveFrame(
    handle: *ExternalRxIntentHandle,
    source: *client_external_mode.ExternalRxOutcome,
    authority_ops: AuthorityOps,
    target_stream_id: u64,
    partial: ?external_rx_demux.ValidatedPartialView,
) MoveResult {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return .poisoned;
    const before = authority_ops.current(authority_ops.context) orelse
        return .authority_drift;
    const after_before_callback =
        validateHandleAndScratch(handle, .ready, .ready) orelse
        return .poisoned;
    if (after_before_callback != scratch or
        !authorityMatchesBound(handle, scratch, before))
        return .authority_drift;
    if (rangeAliasesAuthorityOwners(
        @intFromPtr(source),
        @sizeOf(client_external_mode.ExternalRxOutcome),
        handle,
        scratch,
        before,
    ))
        return .alias;
    const paired = switch (source.*) {
        .frame => |*frame| frame,
        else => return .invalid_source,
    };
    if (!frameDescriptorValid(paired, before)) return .authority_drift;
    if (before.parser_generation <= scratch.last_parser_generation or
        paired.range.end_absolute != before.buffer_start_absolute or
        paired.range.end_absolute <= scratch.last_moved_end_absolute)
        return .replay;
    const payload_addr = if (paired.frame.payload.len == 0)
        0
    else
        @intFromPtr(paired.frame.payload.ptr);
    if (framePayloadAliasesAuthority(
        handle,
        scratch,
        paired.frame.payload,
        before,
    ))
        return .alias;
    if (!client_external_mode.validateExternalRxFrame(paired))
        return .authority_drift;
    const classification = external_rx_demux.classifyExternalRx(
        paired,
        before.identity,
        target_stream_id,
        partial,
    );
    const frozen_pair = paired.*;
    const commit = authority_ops.current(authority_ops.context) orelse {
        source.* = .{ .frame = frozen_pair };
        return .authority_drift;
    };
    const after_commit_callback =
        validateHandleAndScratch(handle, .ready, .ready) orelse
        {
            source.* = .{ .frame = frozen_pair };
            return .poisoned;
        };
    if (after_commit_callback != scratch or
        !authorityViewValid(before) or !authorityViewValid(commit) or
        !std.meta.eql(before, commit) or
        !authorityMatchesBound(handle, scratch, commit))
    {
        source.* = .{ .frame = frozen_pair };
        return .authority_drift;
    }
    const commit_paired = switch (source.*) {
        .frame => |*frame| frame,
        else => {
            source.* = .{ .frame = frozen_pair };
            return .authority_drift;
        },
    };
    const commit_payload_addr = if (commit_paired.frame.payload.len == 0)
        0
    else
        @intFromPtr(commit_paired.frame.payload.ptr);
    if (commit_payload_addr != payload_addr or
        commit_paired.frame.payload.len != frozen_pair.frame.payload.len or
        !std.meta.eql(commit_paired.frame.header, frozen_pair.frame.header) or
        !std.meta.eql(commit_paired.range, frozen_pair.range) or
        !std.mem.eql(u8, &commit_paired.pair_seal, &frozen_pair.pair_seal) or
        !frameDescriptorValid(commit_paired, commit) or
        !client_external_mode.validateExternalRxFrame(commit_paired) or
        framePayloadAliasesAuthority(
            handle,
            scratch,
            commit_paired.frame.payload,
            commit,
        ))
    {
        source.* = .{ .frame = frozen_pair };
        return .authority_drift;
    }
    const commit_classification = external_rx_demux.classifyExternalRx(
        commit_paired,
        commit.identity,
        target_stream_id,
        partial,
    );
    if (!std.meta.eql(classification, commit_classification))
        return .authority_drift;
    if (classification == .protocol_terminal) {
        var cleanup =
            [_]FrozenPayloadCleanup{.{}} ** (max_intents + 1);
        if (!freezeClassifiedCleanup(scratch, cleanup[0..max_intents])) {
            _ = poison(scratch, handle);
            return .poisoned;
        }
        const count: usize = scratch.intent_count;
        const payload = commit_paired.frame.payload;
        for (cleanup[0..count]) |existing|
            if (rangesOverlap(
                payload_addr,
                payload.len,
                if (existing.payload.len == 0)
                    0
                else
                    @intFromPtr(existing.payload.ptr),
                existing.payload.len,
            ))
                return .alias;
        cleanup[count] = .{
            .allocator = before.allocator,
            .payload = payload,
        };
        source.* = .incomplete;
        for (0..count) |index| scratch.intents[index] = .aborted;
        scratch.intent_count = 0;
        scratch.last_parser_generation = before.parser_generation;
        scratch.last_moved_end_absolute = before.buffer_start_absolute;
        scratch.lifecycle = .spent;
        scratch.digest = scratchDigest(scratch);
        for (cleanup[0 .. count + 1]) |item|
            item.allocator.free(item.payload);
        return .protocol_terminal;
    }
    if (scratch.intent_count == max_intents) return .capacity;
    const index: usize = scratch.intent_count;
    const owner_addr = @intFromPtr(&scratch.intents[index]);
    const payload = commit_paired.frame.payload;
    var owner = ClassifiedIntentOwner{
        .saved_self_addr = owner_addr,
        .storage_addr = scratch.storage_addr,
        .turn_generation = scratch.turn_generation,
        .parser_generation = before.parser_generation,
        .frame = commit_paired.frame,
        .range = commit_paired.range,
        .pair_seal = commit_paired.pair_seal,
        .payload_addr = payload_addr,
        .payload_len = payload.len,
        .payload_digest = payloadDigest(payload),
        .classification = classification,
        .allocator = before.allocator,
        .allocator_ptr_addr = @intFromPtr(before.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(before.allocator.vtable),
        .cleanup_payload = payload,
        .lifecycle = .classified,
        .digest = undefined,
    };
    owner.cleanup_digest = cleanupDigest(&owner);
    owner.digest = ownerDigest(&owner);
    source.* = .incomplete;
    scratch.intents[index] = .{ .classified = owner };
    scratch.intent_count += 1;
    scratch.last_parser_generation = before.parser_generation;
    scratch.last_moved_end_absolute = before.buffer_start_absolute;
    scratch.digest = scratchDigest(scratch);
    return .classified;
}

pub fn moveScreenToNeutral(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    authority_ops: AuthorityOps,
    aggregate_addr: usize,
    aggregate_len: usize,
    out: *MovedIntentPayload,
) MoveScreenResult {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return .invalid_state;
    if (intent_index >= scratch.intent_count)
        return .invalid_index;
    if (!movedIntentPayloadPristine(out))
        return .invalid_state;
    const aggregate_end = std.math.add(
        usize,
        aggregate_addr,
        aggregate_len,
    ) catch return .alias;
    const out_end = std.math.add(
        usize,
        @intFromPtr(out),
        @sizeOf(MovedIntentPayload),
    ) catch return .alias;
    if (aggregate_addr == 0 or aggregate_len == 0 or
        @intFromPtr(out) < aggregate_addr or out_end > aggregate_end)
        return .alias;
    const before = authority_ops.current(authority_ops.context) orelse
        return .authority_drift;
    if (!authorityMatchesBound(handle, scratch, before) or
        aggregateRangeAliasesIntentAuthority(
            handle,
            scratch,
            before,
            aggregate_addr,
            aggregate_len,
        ))
        return .alias;
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*classified| classified,
        else => return .invalid_state,
    };
    const candidate = switch (owner.classification) {
        .screen_candidate => |screen| screen,
        else => return .wrong_class,
    };
    if (!ownerValid(owner, scratch)) return .invalid_state;
    const owner_digest = owner.digest;
    const owner_payload = owner.cleanup_payload orelse return .invalid_state;
    const after = authority_ops.current(authority_ops.context) orelse
        return .authority_drift;
    const current_scratch =
        validateHandleAndScratch(handle, .ready, .ready) orelse
        return .authority_drift;
    if (current_scratch != scratch or
        !std.meta.eql(before, after) or
        !authorityMatchesBound(handle, scratch, after) or
        aggregateRangeAliasesIntentAuthority(
            handle,
            scratch,
            after,
            aggregate_addr,
            aggregate_len,
        ))
        return .authority_drift;
    const current_owner = switch (scratch.intents[intent_index]) {
        .classified => |*classified| classified,
        else => return .authority_drift,
    };
    if (!ownerValid(current_owner, scratch) or
        !std.mem.eql(u8, &current_owner.digest, &owner_digest) or
        !std.meta.eql(current_owner.classification, owner.classification))
        return .authority_drift;

    const intent_addr = @intFromPtr(&scratch.intents[intent_index]);
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .source_intent_addr = intent_addr,
        .aggregate_addr = aggregate_addr,
        .allocator = current_owner.allocator,
        .allocator_ptr_addr = current_owner.allocator_ptr_addr,
        .allocator_vtable_addr = current_owner.allocator_vtable_addr,
        .allocation_addr = current_owner.payload_addr,
        .allocation_len = current_owner.payload_len,
        .content_digest = current_owner.payload_digest,
        .lifecycle = .owned,
        .digest = undefined,
    };
    out.digest = movedIntentPayloadDigest(out);
    var staged = StagedScreenIntent{
        .saved_self_addr = intent_addr,
        .storage_addr = scratch.storage_addr,
        .turn_generation = scratch.turn_generation,
        .parser_generation = current_owner.parser_generation,
        .source_start_absolute = current_owner.range.start_absolute,
        .source_end_absolute = current_owner.range.end_absolute,
        .aggregate_addr = aggregate_addr,
        .neutral_addr = @intFromPtr(out),
        .classification = candidate,
        .payload_addr = current_owner.payload_addr,
        .payload_len = current_owner.payload_len,
        .payload_digest = current_owner.payload_digest,
        .digest = undefined,
    };
    staged.digest = stagedScreenIntentDigest(&staged);
    scratch.intents[intent_index] = .{ .screen_staging = staged };
    scratch.digest = scratchDigest(scratch);
    _ = owner_payload;
    return .moved;
}

pub fn borrowMovedIntentPayload(
    payload: *const MovedIntentPayload,
    aggregate_addr: usize,
) ?BorrowedMovedPayloadView {
    if (!movedIntentPayloadValid(payload, aggregate_addr)) return null;
    return .{
        .allocator = payload.allocator,
        .allocation_addr = payload.allocation_addr,
        .allocation_len = payload.allocation_len,
        .content_digest = payload.content_digest,
    };
}

pub fn borrowMovedScreen(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    payload: *const MovedIntentPayload,
    aggregate_addr: usize,
) ?BorrowedMovedScreenView {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return null;
    if (intent_index >= scratch.intent_count) return null;
    const staged = switch (scratch.intents[intent_index]) {
        .screen_staging => |*value| value,
        else => return null,
    };
    if (!stagedScreenIntentValid(
        staged,
        scratch,
        @intFromPtr(&scratch.intents[intent_index]),
        aggregate_addr,
    ) or
        staged.neutral_addr != @intFromPtr(payload) or
        staged.payload_addr != payload.allocation_addr or
        staged.payload_len != payload.allocation_len or
        !std.mem.eql(
            u8,
            &staged.payload_digest,
            &payload.content_digest,
        ))
        return null;
    return .{
        .payload = borrowMovedIntentPayload(payload, aggregate_addr) orelse
            return null,
        .candidate = staged.classification,
    };
}

pub fn classifyBoundEvent(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    identity: runtime_event_types.EventIdentity,
    authority: runtime_event_types.EventAuthorityView,
    expected_major: u16,
    metadata_support: runtime_event_types.MetadataSupport,
    observer: ?runtime_event_wire.ParseObserver,
) external_rx_demux.ExternalEventClass {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return .protocol_terminal;
    if (intent_index >= scratch.intent_count)
        return .protocol_terminal;
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*value| value,
        else => return .protocol_terminal,
    };
    if (!ownerValid(owner, scratch))
        return .protocol_terminal;
    const candidate = switch (owner.classification) {
        .event_candidate => |value| value,
        else => return .protocol_terminal,
    };
    const paired = client_external_mode.ExternalRxFrame{
        .frame = owner.frame,
        .range = owner.range,
        .pair_seal = owner.pair_seal,
    };
    return external_rx_demux.classifyEventCandidate(
        identity,
        authority,
        expected_major,
        metadata_support,
        &paired,
        candidate,
        observer,
    );
}

pub fn borrowClassifiedEvent(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
) ?BorrowedClassifiedEventView {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return null;
    if (intent_index >= scratch.intent_count) return null;
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*value| value,
        else => return null,
    };
    if (!ownerValid(owner, scratch)) return null;
    const candidate = switch (owner.classification) {
        .event_candidate => |value| value,
        else => return null,
    };
    return .{
        .payload = owner.frame.payload,
        .allocator = owner.allocator,
        .payload_digest = owner.payload_digest,
        .candidate = candidate,
    };
}

/// Returns the partial cursor already decided by the classifier and sealed into the moved owner.
/// Traversal must consume this value instead of independently replaying the transition policy.
pub fn partialAfterMove(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
) PartialAfterMoveResult {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return .invalid_state;
    if (intent_index >= scratch.intent_count) return .invalid_state;
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*value| value,
        else => return .invalid_state,
    };
    if (!ownerValid(owner, scratch)) return .invalid_state;
    return switch (owner.classification) {
        .screen_candidate => |candidate| .{
            .advanced = candidate.partial_after,
        },
        .event_candidate, .response_candidate => .unchanged,
        .protocol_terminal => .invalid_state,
    };
}

pub fn validateStagedScreenBinding(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    aggregate_addr: usize,
    neutral_addr: usize,
    header: protocol.Header,
    range: external_rx_types.RxRange,
    payload_digest: external_owner_seal.Digest,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return false;
    if (intent_index >= scratch.intent_count) return false;
    const staged = switch (scratch.intents[intent_index]) {
        .screen_staging => |*value| value,
        else => return false,
    };
    return stagedScreenIntentValid(
        staged,
        scratch,
        @intFromPtr(&scratch.intents[intent_index]),
        aggregate_addr,
    ) and staged.neutral_addr == neutral_addr and
        std.meta.eql(staged.classification.header, header) and
        std.meta.eql(staged.classification.range, range) and
        std.mem.eql(u8, &staged.payload_digest, &payload_digest);
}

pub fn validateMovedIntentPayloadTombstone(
    payload: *const MovedIntentPayload,
    aggregate_addr: usize,
) bool {
    return payload.saved_self_addr == @intFromPtr(payload) and
        payload.source_intent_addr != 0 and
        payload.aggregate_addr == aggregate_addr and
        payload.allocator_ptr_addr == 0 and
        payload.allocator_vtable_addr == 0 and
        payload.allocation_addr == 0 and
        payload.allocation_len == 0 and
        std.mem.allEqual(u8, &payload.content_digest, 0) and
        payload.lifecycle == .moved and
        std.mem.eql(
            u8,
            &payload.digest,
            &movedIntentPayloadDigest(payload),
        );
}

pub fn validateScreenMutationScalar(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    aggregate_addr: usize,
    proof: *const StagedScreenMutationProof,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return false;
    if (intent_index >= scratch.intent_count) return false;
    const staged = switch (scratch.intents[intent_index]) {
        .screen_staging => |*value| value,
        else => return false,
    };
    return stagedScreenIntentValid(
        staged,
        scratch,
        @intFromPtr(&scratch.intents[intent_index]),
        aggregate_addr,
    ) and screenMutationProofValid(
        proof,
        staged,
        aggregate_addr,
        intent_index,
    );
}

pub fn commitMovedIntentPayloadTransferUnchecked(
    payload: *MovedIntentPayload,
) void {
    payload.allocator_ptr_addr = 0;
    payload.allocator_vtable_addr = 0;
    payload.allocation_addr = 0;
    payload.allocation_len = 0;
    payload.content_digest = [_]u8{0} ** 32;
    payload.lifecycle = .moved;
    payload.digest = movedIntentPayloadDigest(payload);
}

pub fn bindScreenMutationScalar(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    aggregate_addr: usize,
    aggregate_len: usize,
    batch_addr: usize,
    mutation_index: u8,
    payload_digest: external_owner_seal.Digest,
    out: *StagedScreenMutationProof,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return false;
    if (intent_index >= scratch.intent_count or batch_addr == 0 or
        out.saved_self_addr != 0 or out.lifecycle != .empty or
        !std.mem.allEqual(u8, &out.digest, 0))
        return false;
    const aggregate_end = std.math.add(
        usize,
        aggregate_addr,
        aggregate_len,
    ) catch return false;
    const out_end = std.math.add(
        usize,
        @intFromPtr(out),
        @sizeOf(StagedScreenMutationProof),
    ) catch return false;
    if (aggregate_addr == 0 or aggregate_len == 0 or
        @intFromPtr(out) < aggregate_addr or out_end > aggregate_end)
        return false;
    const staged = switch (scratch.intents[intent_index]) {
        .screen_staging => |*value| value,
        else => return false,
    };
    if (!stagedScreenIntentValid(
        staged,
        scratch,
        @intFromPtr(&scratch.intents[intent_index]),
        aggregate_addr,
    ) or
        !std.mem.eql(u8, &staged.payload_digest, &payload_digest))
        return false;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .source_intent_addr = @intFromPtr(&scratch.intents[intent_index]),
        .aggregate_addr = aggregate_addr,
        .batch_addr = batch_addr,
        .intent_index = intent_index,
        .mutation_index = mutation_index,
        .payload_digest = payload_digest,
        .lifecycle = .prepared,
        .digest = undefined,
    };
    out.digest = screenMutationProofDigest(out);
    return true;
}

pub fn prepareIntentCommit(
    handle: *ExternalRxIntentHandle,
    aggregate_addr: usize,
    aggregate_len: usize,
    proofs: *[max_intents]StagedScreenMutationProof,
    neutral_outputs: *[max_intents]MovedIntentPayload,
    permit: *PreparedIntentCommit,
) error{ InvalidPlan, InvalidAlias }!void {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return error.InvalidPlan;
    if (aggregate_addr == 0 or aggregate_len == 0 or scratch.intent_count == 0 or
        permit.saved_self_addr != 0 or
        permit.lifecycle != .empty)
        return error.InvalidPlan;
    const aggregate_end = std.math.add(
        usize,
        aggregate_addr,
        aggregate_len,
    ) catch return error.InvalidPlan;
    const permit_end = std.math.add(
        usize,
        @intFromPtr(permit),
        @sizeOf(PreparedIntentCommit),
    ) catch return error.InvalidPlan;
    const proofs_end = std.math.add(
        usize,
        @intFromPtr(proofs),
        @sizeOf(@TypeOf(proofs.*)),
    ) catch return error.InvalidPlan;
    const neutral_end = std.math.add(
        usize,
        @intFromPtr(neutral_outputs),
        @sizeOf(@TypeOf(neutral_outputs.*)),
    ) catch return error.InvalidPlan;
    if (@intFromPtr(permit) < aggregate_addr or permit_end > aggregate_end or
        @intFromPtr(proofs) < aggregate_addr or proofs_end > aggregate_end or
        @intFromPtr(neutral_outputs) < aggregate_addr or
        neutral_end > aggregate_end)
        return error.InvalidAlias;
    if (rangesOverlap(
        @intFromPtr(permit),
        @sizeOf(PreparedIntentCommit),
        @intFromPtr(proofs),
        @sizeOf(@TypeOf(proofs.*)),
    ) or rangesOverlap(
        @intFromPtr(permit),
        @sizeOf(PreparedIntentCommit),
        @intFromPtr(neutral_outputs),
        @sizeOf(@TypeOf(neutral_outputs.*)),
    ) or rangesOverlap(
        @intFromPtr(proofs),
        @sizeOf(@TypeOf(proofs.*)),
        @intFromPtr(neutral_outputs),
        @sizeOf(@TypeOf(neutral_outputs.*)),
    ))
        return error.InvalidAlias;
    var slot_kinds = [_]IntentCommitSlotKind{.unused} ** max_intents;
    var response_request_ids = [_]u64{0} ** max_intents;
    var source_parser_generations = [_]u64{0} ** max_intents;
    var source_start_absolutes = [_]u64{0} ** max_intents;
    var source_end_absolutes = [_]u64{0} ** max_intents;
    var source_owner_digests =
        [_]external_owner_seal.Digest{[_]u8{0} ** 32} ** max_intents;
    var payload_digests =
        [_]external_owner_seal.Digest{[_]u8{0} ** 32} ** max_intents;
    var proof_count: usize = 0;
    for (&scratch.intents, 0..) |*intent, index| {
        if (!movedIntentPayloadPristine(&neutral_outputs[index]))
            return error.InvalidPlan;
        if (index >= scratch.intent_count) {
            if (!screenMutationProofPristine(&proofs[index]) or
                intent.* != .empty)
                return error.InvalidPlan;
            continue;
        }
        switch (intent.*) {
            .screen_staging => |*staged| {
                if (!stagedScreenIntentValid(
                    staged,
                    scratch,
                    @intFromPtr(intent),
                    aggregate_addr,
                ) or !screenMutationProofValid(
                    &proofs[index],
                    staged,
                    aggregate_addr,
                    @intCast(index),
                ))
                    return error.InvalidPlan;
                slot_kinds[index] = .screen;
                source_parser_generations[index] = staged.parser_generation;
                source_start_absolutes[index] = staged.source_start_absolute;
                source_end_absolutes[index] = staged.source_end_absolute;
                source_owner_digests[index] = staged.digest;
                payload_digests[index] = staged.payload_digest;
                proof_count += 1;
            },
            .classified => |*owner| {
                if (!ownerValid(owner, scratch) or
                    !screenMutationProofPristine(&proofs[index]))
                    return error.InvalidPlan;
                payload_digests[index] = owner.payload_digest;
                source_parser_generations[index] = owner.parser_generation;
                source_start_absolutes[index] = owner.range.start_absolute;
                source_end_absolutes[index] = owner.range.end_absolute;
                source_owner_digests[index] = owner.digest;
                switch (owner.classification) {
                    .event_candidate => slot_kinds[index] = .event,
                    .response_candidate => |candidate| {
                        slot_kinds[index] = .response;
                        response_request_ids[index] = candidate.request_id;
                    },
                    .screen_candidate, .protocol_terminal => return error.InvalidPlan,
                }
            },
            else => return error.InvalidPlan,
        }
    }
    permit.* = .{
        .saved_self_addr = @intFromPtr(permit),
        .handle_addr = @intFromPtr(handle),
        .scratch_addr = @intFromPtr(scratch),
        .aggregate_addr = aggregate_addr,
        .aggregate_len = aggregate_len,
        .proofs_addr = @intFromPtr(proofs),
        .neutral_outputs_addr = @intFromPtr(neutral_outputs),
        .proof_count = @intCast(proof_count),
        .intent_count = scratch.intent_count,
        .final_parser_generation = scratch.last_parser_generation,
        .final_end_absolute = scratch.last_moved_end_absolute,
        .slot_kinds = slot_kinds,
        .response_request_ids = response_request_ids,
        .source_parser_generations = source_parser_generations,
        .source_start_absolutes = source_start_absolutes,
        .source_end_absolutes = source_end_absolutes,
        .source_owner_digests = source_owner_digests,
        .payload_digests = payload_digests,
        .lifecycle = .prepared,
        .proofs_digest = screenMutationProofsDigest(proofs),
        .neutral_outputs_digest = neutralOutputsDigest(neutral_outputs),
        .digest = undefined,
    };
    permit.digest = preparedIntentCommitDigest(permit);
}

pub fn validatePreparedIntentCommit(
    handle: *ExternalRxIntentHandle,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    permit: *const PreparedIntentCommit,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return false;
    const aggregate_end = std.math.add(
        usize,
        permit.aggregate_addr,
        permit.aggregate_len,
    ) catch return false;
    const permit_end = std.math.add(
        usize,
        @intFromPtr(permit),
        @sizeOf(PreparedIntentCommit),
    ) catch return false;
    const proofs_end = std.math.add(
        usize,
        @intFromPtr(proofs),
        @sizeOf(@TypeOf(proofs.*)),
    ) catch return false;
    const neutral_end = std.math.add(
        usize,
        @intFromPtr(neutral_outputs),
        @sizeOf(@TypeOf(neutral_outputs.*)),
    ) catch return false;
    if (permit.saved_self_addr != @intFromPtr(permit) or
        permit.handle_addr != @intFromPtr(handle) or
        permit.scratch_addr != @intFromPtr(scratch) or
        permit.aggregate_addr == 0 or
        permit.aggregate_len == 0 or
        permit.proofs_addr != @intFromPtr(proofs) or
        permit.neutral_outputs_addr != @intFromPtr(neutral_outputs) or
        permit.proof_count > permit.intent_count or
        permit.intent_count != scratch.intent_count or
        permit.final_parser_generation != scratch.last_parser_generation or
        permit.final_end_absolute != scratch.last_moved_end_absolute or
        @intFromPtr(permit) < permit.aggregate_addr or
        permit_end > aggregate_end or
        @intFromPtr(proofs) < permit.aggregate_addr or
        proofs_end > aggregate_end or
        @intFromPtr(neutral_outputs) < permit.aggregate_addr or
        neutral_end > aggregate_end or
        permit.lifecycle != .prepared or
        !std.mem.eql(
            u8,
            &permit.proofs_digest,
            &screenMutationProofsDigest(proofs),
        ) or
        !std.mem.eql(
            u8,
            &permit.neutral_outputs_digest,
            &neutralOutputsDigest(neutral_outputs),
        ) or
        !std.mem.eql(
            u8,
            &permit.digest,
            &preparedIntentCommitDigest(permit),
        ))
        return false;
    var proof_count: usize = 0;
    for (&scratch.intents, 0..) |*intent, index| {
        if (!movedIntentPayloadPristine(&neutral_outputs[index]))
            return false;
        if (index >= scratch.intent_count) {
            if (permit.slot_kinds[index] != .unused or
                permit.response_request_ids[index] != 0 or
                permit.source_parser_generations[index] != 0 or
                permit.source_start_absolutes[index] != 0 or
                permit.source_end_absolutes[index] != 0 or
                !std.mem.allEqual(
                    u8,
                    &permit.source_owner_digests[index],
                    0,
                ) or
                !std.mem.allEqual(u8, &permit.payload_digests[index], 0) or
                !screenMutationProofPristine(&proofs[index]) or
                intent.* != .empty)
                return false;
            continue;
        }
        switch (intent.*) {
            .screen_staging => |*staged| {
                if (permit.slot_kinds[index] != .screen or
                    permit.response_request_ids[index] != 0 or
                    permit.source_parser_generations[index] !=
                        staged.parser_generation or
                    permit.source_start_absolutes[index] !=
                        staged.source_start_absolute or
                    permit.source_end_absolutes[index] !=
                        staged.source_end_absolute or
                    !std.mem.eql(
                        u8,
                        &permit.source_owner_digests[index],
                        &staged.digest,
                    ) or
                    !std.mem.eql(
                        u8,
                        &permit.payload_digests[index],
                        &staged.payload_digest,
                    ) or !stagedScreenIntentValid(
                    staged,
                    scratch,
                    @intFromPtr(intent),
                    permit.aggregate_addr,
                ) or !screenMutationProofValid(
                    &proofs[index],
                    staged,
                    permit.aggregate_addr,
                    @intCast(index),
                ))
                    return false;
                proof_count += 1;
            },
            .classified => |*owner| {
                if (!ownerValid(owner, scratch) or
                    !screenMutationProofPristine(&proofs[index]) or
                    permit.source_parser_generations[index] !=
                        owner.parser_generation or
                    permit.source_start_absolutes[index] !=
                        owner.range.start_absolute or
                    permit.source_end_absolutes[index] !=
                        owner.range.end_absolute or
                    !std.mem.eql(
                        u8,
                        &permit.source_owner_digests[index],
                        &owner.digest,
                    ) or
                    !std.mem.eql(
                        u8,
                        &permit.payload_digests[index],
                        &owner.payload_digest,
                    ))
                    return false;
                switch (owner.classification) {
                    .event_candidate => if (permit.slot_kinds[index] != .event or
                        permit.response_request_ids[index] != 0)
                        return false,
                    .response_candidate => |candidate| if (permit.slot_kinds[index] != .response or
                        permit.response_request_ids[index] != candidate.request_id) return false,
                    .screen_candidate, .protocol_terminal => return false,
                }
            },
            else => return false,
        }
    }
    return proof_count == permit.proof_count;
}

/// Returns the exact payload descriptor that a validated classified slot will move into its
/// neutral destination at commit. The returned view is pre-barrier evidence only; the unchecked
/// suffix must use sealed scalars from its destination plan instead of borrowing the source again.
pub fn borrowPreparedClassifiedPayload(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    permit: *const PreparedIntentCommit,
) ?BorrowedMovedPayloadView {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        permit,
    ) or intent_index >= permit.intent_count or
        permit.slot_kinds[intent_index] == .screen)
        return null;
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return null;
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*value| value,
        else => return null,
    };
    return .{
        .allocator = owner.allocator,
        .allocation_addr = owner.payload_addr,
        .allocation_len = owner.payload_len,
        .content_digest = owner.payload_digest,
    };
}

fn destinationPlanContentDigest(bytes: []const u8) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXDP1");
    writer.writeBytes(bytes);
    return writer.finish();
}

pub fn bindIntentDestinationPlan(
    handle: *ExternalRxIntentHandle,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    permit: *PreparedIntentCommit,
    destination_plan: []const u8,
) error{ InvalidPlan, InvalidAlias }!void {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        permit,
    ) or permit.destination_plan_addr != 0 or
        permit.destination_plan_len != 0 or
        !std.mem.allEqual(u8, &permit.destination_plan_digest, 0) or
        destination_plan.len == 0)
        return error.InvalidPlan;
    const plan_addr = @intFromPtr(destination_plan.ptr);
    const aggregate_end = std.math.add(
        usize,
        permit.aggregate_addr,
        permit.aggregate_len,
    ) catch return error.InvalidPlan;
    const plan_end = std.math.add(
        usize,
        plan_addr,
        destination_plan.len,
    ) catch return error.InvalidPlan;
    if (plan_addr < permit.aggregate_addr or plan_end > aggregate_end or
        rangesOverlap(
            plan_addr,
            destination_plan.len,
            @intFromPtr(permit),
            @sizeOf(PreparedIntentCommit),
        ) or rangesOverlap(
        plan_addr,
        destination_plan.len,
        permit.proofs_addr,
        @sizeOf([max_intents]StagedScreenMutationProof),
    ) or rangesOverlap(
        plan_addr,
        destination_plan.len,
        permit.neutral_outputs_addr,
        @sizeOf([max_intents]MovedIntentPayload),
    ))
        return error.InvalidAlias;
    permit.destination_plan_addr = plan_addr;
    permit.destination_plan_len = destination_plan.len;
    permit.destination_plan_digest =
        destinationPlanContentDigest(destination_plan);
    permit.digest = preparedIntentCommitDigest(permit);
}

pub fn validateIntentDestinationPlan(
    handle: *ExternalRxIntentHandle,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    permit: *const PreparedIntentCommit,
    destination_plan: []const u8,
) bool {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        permit,
    ) or destination_plan.len == 0 or
        permit.destination_plan_addr != @intFromPtr(destination_plan.ptr) or
        permit.destination_plan_len != destination_plan.len)
        return false;
    return std.mem.eql(
        u8,
        &permit.destination_plan_digest,
        &destinationPlanContentDigest(destination_plan),
    );
}

pub fn prepareNeutralRetirement(
    handle: *ExternalRxIntentHandle,
    intent_index: u8,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    intent_commit: *const PreparedIntentCommit,
    cleanup_output: *external_owner_cleanup.FrozenOwnerCleanupDescriptor,
    out: *PreparedNeutralRetirement,
) error{ InvalidPlan, InvalidAlias }!void {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        intent_commit,
    ) or intent_index >= intent_commit.intent_count or
        intent_commit.slot_kinds[intent_index] != .event or
        !preparedNeutralRetirementPristine(out) or
        !external_owner_cleanup.isPristine(cleanup_output))
        return error.InvalidPlan;
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(intent_commit.scratch_addr);
    const owner = switch (scratch.intents[intent_index]) {
        .classified => |*value| value,
        else => return error.InvalidPlan,
    };
    if (!ownerValid(owner, scratch) or owner.payload_len == 0 or
        std.meta.activeTag(owner.classification) != .event_candidate)
        return error.InvalidPlan;
    const expected_neutral_addr =
        @intFromPtr(neutral_outputs) +
        @as(usize, intent_index) * @sizeOf(MovedIntentPayload);
    const aggregate_end = std.math.add(
        usize,
        intent_commit.aggregate_addr,
        intent_commit.aggregate_len,
    ) catch return error.InvalidPlan;
    const out_end = std.math.add(
        usize,
        @intFromPtr(out),
        @sizeOf(PreparedNeutralRetirement),
    ) catch return error.InvalidPlan;
    const cleanup_end = std.math.add(
        usize,
        @intFromPtr(cleanup_output),
        @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
    ) catch return error.InvalidPlan;
    if (@intFromPtr(&neutral_outputs[intent_index]) != expected_neutral_addr or
        @intFromPtr(out) < intent_commit.aggregate_addr or
        out_end > aggregate_end or
        @intFromPtr(cleanup_output) < intent_commit.aggregate_addr or
        cleanup_end > aggregate_end or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedNeutralRetirement),
            @intFromPtr(cleanup_output),
            @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
        ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(PreparedNeutralRetirement),
        expected_neutral_addr,
        @sizeOf(MovedIntentPayload),
    ) or rangesOverlap(
        @intFromPtr(cleanup_output),
        @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
        expected_neutral_addr,
        @sizeOf(MovedIntentPayload),
    ))
        return error.InvalidAlias;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .handle_addr = @intFromPtr(handle),
        .scratch_addr = @intFromPtr(scratch),
        .intent_commit_addr = @intFromPtr(intent_commit),
        .aggregate_addr = intent_commit.aggregate_addr,
        .aggregate_len = intent_commit.aggregate_len,
        .neutral_addr = expected_neutral_addr,
        .cleanup_output_addr = @intFromPtr(cleanup_output),
        .source_intent_addr = @intFromPtr(&scratch.intents[intent_index]),
        .intent_index = intent_index,
        .allocator_ptr_addr = owner.allocator_ptr_addr,
        .allocator_vtable_addr = owner.allocator_vtable_addr,
        .allocation_addr = owner.payload_addr,
        .allocation_len = owner.payload_len,
        .content_digest = owner.payload_digest,
        .source_owner_digest = owner.digest,
        .lifecycle = .prepared,
        .digest = undefined,
    };
    out.digest = preparedNeutralRetirementDigest(out);
}

pub fn validatePreparedNeutralRetirement(
    handle: *ExternalRxIntentHandle,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    intent_commit: *const PreparedIntentCommit,
    cleanup_output: *const external_owner_cleanup.FrozenOwnerCleanupDescriptor,
    permit: *const PreparedNeutralRetirement,
) bool {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        intent_commit,
    ) or !preparedNeutralRetirementHeaderValid(
        handle,
        neutral_outputs,
        intent_commit,
        cleanup_output,
        permit,
        .prepared,
    ))
        return false;
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(intent_commit.scratch_addr);
    const owner = switch (scratch.intents[permit.intent_index]) {
        .classified => |*value| value,
        else => return false,
    };
    return ownerValid(owner, scratch) and
        std.meta.activeTag(owner.classification) == .event_candidate and
        owner.payload_len != 0 and
        permit.source_intent_addr == @intFromPtr(
            &scratch.intents[permit.intent_index],
        ) and
        permit.allocator_ptr_addr == owner.allocator_ptr_addr and
        permit.allocator_vtable_addr == owner.allocator_vtable_addr and
        permit.allocation_addr == owner.payload_addr and
        permit.allocation_len == owner.payload_len and
        std.mem.eql(u8, &permit.content_digest, &owner.payload_digest) and
        std.mem.eql(u8, &permit.source_owner_digest, &owner.digest);
}

/// This is the fallible-prefix gate for `commitNeutralRetirementUnchecked`. It deliberately
/// remains false until the enclosing intent commit has made the aggregate neutral slot the sole
/// owner and tombstoned the classified source.
pub fn neutralRetirementReadyToCommit(
    handle: *ExternalRxIntentHandle,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    intent_commit: *const PreparedIntentCommit,
    cleanup_output: *const external_owner_cleanup.FrozenOwnerCleanupDescriptor,
    permit: *const PreparedNeutralRetirement,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .spent) orelse
        return false;
    if (intent_commit.lifecycle != .consumed or
        intent_commit.scratch_addr != @intFromPtr(scratch) or
        !std.mem.eql(
            u8,
            &intent_commit.digest,
            &preparedIntentCommitDigest(intent_commit),
        ) or !preparedNeutralRetirementHeaderValid(
        handle,
        neutral_outputs,
        intent_commit,
        cleanup_output,
        permit,
        .prepared,
    ))
        return false;
    const neutral = &neutral_outputs[permit.intent_index];
    return movedIntentPayloadValid(neutral, permit.aggregate_addr) and
        neutral.source_intent_addr == permit.source_intent_addr and
        neutral.allocator_ptr_addr == permit.allocator_ptr_addr and
        neutral.allocator_vtable_addr == permit.allocator_vtable_addr and
        neutral.allocation_addr == permit.allocation_addr and
        neutral.allocation_len == permit.allocation_len and
        std.mem.eql(
            u8,
            &neutral.content_digest,
            &permit.content_digest,
        );
}

pub fn commitNeutralRetirementUnchecked(
    neutral: *MovedIntentPayload,
    permit: *PreparedNeutralRetirement,
    cleanup_output: *external_owner_cleanup.FrozenOwnerCleanupDescriptor,
) void {
    const allocator = neutral.allocator;
    const allocation = @as(
        [*]u8,
        @ptrFromInt(neutral.allocation_addr),
    )[0..neutral.allocation_len];
    commitMovedIntentPayloadTransferUnchecked(neutral);
    external_owner_cleanup.freezeOwnedSliceFromSealUnchecked(
        cleanup_output,
        allocator,
        allocation,
        permit.content_digest,
    );
    permit.lifecycle = .consumed;
    permit.digest = preparedNeutralRetirementDigest(permit);
}

pub fn consumePreparedIntentCommitUnchecked(
    handle: *ExternalRxIntentHandle,
    proofs: *[max_intents]StagedScreenMutationProof,
    neutral_outputs: *[max_intents]MovedIntentPayload,
    permit: *PreparedIntentCommit,
) void {
    const scratch: *ExternalRxIntentScratch = @ptrFromInt(permit.scratch_addr);
    for (scratch.intents[0..permit.intent_count], 0..) |*intent, index| {
        switch (permit.slot_kinds[index]) {
            .screen => {
                intent.* = .committed;
                proofs[index].lifecycle = .consumed;
                proofs[index].digest = screenMutationProofDigest(&proofs[index]);
            },
            .event, .response => {
                const owner = switch (intent.*) {
                    .classified => |*value| value,
                    else => unreachable,
                };
                neutral_outputs[index] = .{
                    .saved_self_addr = @intFromPtr(&neutral_outputs[index]),
                    .source_intent_addr = @intFromPtr(intent),
                    .aggregate_addr = permit.aggregate_addr,
                    .allocator = owner.allocator,
                    .allocator_ptr_addr = owner.allocator_ptr_addr,
                    .allocator_vtable_addr = owner.allocator_vtable_addr,
                    .allocation_addr = owner.payload_addr,
                    .allocation_len = owner.payload_len,
                    .content_digest = owner.payload_digest,
                    .lifecycle = .owned,
                    .digest = undefined,
                };
                neutral_outputs[index].digest =
                    movedIntentPayloadDigest(&neutral_outputs[index]);
                intent.* = .committed;
            },
            .unused => unreachable,
        }
    }
    scratch.intent_count = 0;
    scratch.lifecycle = .spent;
    scratch.digest = scratchDigest(scratch);
    permit.lifecycle = .consumed;
    permit.proofs_digest = screenMutationProofsDigest(proofs);
    permit.neutral_outputs_digest = neutralOutputsDigest(neutral_outputs);
    permit.digest = preparedIntentCommitDigest(permit);
    handle.digest = handleDigest(handle);
}

pub fn abortPreparedIntentCommit(
    handle: *ExternalRxIntentHandle,
    proofs: *const [max_intents]StagedScreenMutationProof,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    permit: *PreparedIntentCommit,
) bool {
    if (!validatePreparedIntentCommit(
        handle,
        proofs,
        neutral_outputs,
        permit,
    ))
        return false;
    permit.lifecycle = .aborted;
    permit.digest = preparedIntentCommitDigest(permit);
    return true;
}

pub fn prepareIntentAbort(
    handle: *ExternalRxIntentHandle,
    aggregate_addr: usize,
    out: *FrozenIntentAbort,
) error{ InvalidPlan, InvalidAlias }!void {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return error.InvalidPlan;
    if (out.saved_self_addr != 0 or out.lifecycle != .empty or
        !std.mem.allEqual(u8, &out.digest, 0))
        return error.InvalidPlan;
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(FrozenIntentAbort),
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(FrozenIntentAbort),
        scratch.allocation_addr,
        scratch.allocation_len,
    ))
        return error.InvalidAlias;

    var owners = [_]?*ClassifiedIntentOwner{null} ** max_intents;
    var cleanup_count: usize = 0;
    for (scratch.intents[0..scratch.intent_count], 0..) |*intent, index| {
        switch (intent.*) {
            .classified => |*owner| {
                if (!ownerValid(owner, scratch)) return error.InvalidPlan;
                if (rangesOverlap(
                    @intFromPtr(out),
                    @sizeOf(FrozenIntentAbort),
                    owner.payload_addr,
                    owner.payload_len,
                ))
                    return error.InvalidAlias;
                for (owners[0..cleanup_count]) |prior_optional| {
                    const prior = prior_optional.?;
                    if (rangesOverlap(
                        owner.payload_addr,
                        owner.payload_len,
                        prior.payload_addr,
                        prior.payload_len,
                    ))
                        return error.InvalidAlias;
                }
                if (owner.payload_len != 0) {
                    owners[cleanup_count] = owner;
                    cleanup_count += 1;
                }
            },
            .screen_staging => |*staged| {
                if (!stagedScreenIntentValid(
                    staged,
                    scratch,
                    @intFromPtr(&scratch.intents[index]),
                    aggregate_addr,
                ))
                    return error.InvalidPlan;
            },
            else => return error.InvalidPlan,
        }
    }

    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .handle_addr = @intFromPtr(handle),
        .scratch_addr = @intFromPtr(scratch),
        .aggregate_addr = aggregate_addr,
        .cleanup_count = @intCast(cleanup_count),
        .intent_count = scratch.intent_count,
        .lifecycle = .prepared,
        .digest = undefined,
    };
    for (owners[0..cleanup_count], 0..) |owner_optional, index|
        external_owner_cleanup.freezeOwnedSlice(
            &out.cleanup[index],
            owner_optional.?.allocator,
            owner_optional.?.cleanup_payload.?,
        ) catch unreachable;
    out.digest = frozenIntentAbortDigest(out);
}

pub fn validatePreparedIntentAbort(
    handle: *ExternalRxIntentHandle,
    permit: *const FrozenIntentAbort,
) bool {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return false;
    if (permit.saved_self_addr != @intFromPtr(permit) or
        permit.handle_addr != @intFromPtr(handle) or
        permit.scratch_addr != @intFromPtr(scratch) or
        permit.cleanup_count > max_intents or
        permit.intent_count != scratch.intent_count or
        permit.lifecycle != .prepared or
        !std.mem.eql(
            u8,
            &permit.digest,
            &frozenIntentAbortDigest(permit),
        ))
        return false;
    var cleanup_index: usize = 0;
    for (scratch.intents[0..scratch.intent_count], 0..) |*intent, index| {
        switch (intent.*) {
            .classified => |*owner| {
                if (!ownerValid(owner, scratch)) return false;
                if (owner.payload_len == 0) continue;
                if (cleanup_index >= permit.cleanup_count)
                    return false;
                const descriptor = &permit.cleanup[cleanup_index];
                if (!external_owner_cleanup.validate(descriptor) or
                    descriptor.allocation_addr != owner.payload_addr or
                    descriptor.allocation_len != owner.payload_len or
                    @intFromPtr(descriptor.allocator.ptr) != owner.allocator_ptr_addr or
                    @intFromPtr(descriptor.allocator.vtable) !=
                        owner.allocator_vtable_addr)
                    return false;
                cleanup_index += 1;
            },
            .screen_staging => |*staged| if (!stagedScreenIntentValid(
                staged,
                scratch,
                @intFromPtr(&scratch.intents[index]),
                permit.aggregate_addr,
            ))
                return false,
            else => return false,
        }
    }
    return cleanup_index == permit.cleanup_count;
}

pub fn commitIntentAbortUnchecked(
    handle: *ExternalRxIntentHandle,
    permit: *FrozenIntentAbort,
) void {
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(permit.scratch_addr);
    for (scratch.intents[0..permit.intent_count]) |*intent|
        intent.* = .aborted;
    scratch.intent_count = 0;
    scratch.lifecycle = .spent;
    scratch.digest = scratchDigest(scratch);
    permit.lifecycle = .committed;
    permit.digest = frozenIntentAbortDigest(permit);
    handle.digest = handleDigest(handle);
}

pub fn finishFrozenIntentAbort(
    permit: *FrozenIntentAbort,
) AbortResult {
    if (permit.saved_self_addr != @intFromPtr(permit) or
        permit.cleanup_count > max_intents or
        permit.lifecycle != .committed or
        !std.mem.eql(
            u8,
            &permit.digest,
            &frozenIntentAbortDigest(permit),
        ))
        return .poisoned;
    var local =
        [_]external_owner_cleanup.FrozenOwnerCleanupDescriptor{.{}} **
        max_intents;
    const count = permit.cleanup_count;
    for (permit.cleanup[0..count], 0..) |*descriptor, index|
        external_owner_cleanup.moveFrozen(
            descriptor,
            &local[index],
        ) catch return .poisoned;
    permit.lifecycle = .spent;
    permit.digest = frozenIntentAbortDigest(permit);
    for (local[0..count]) |*descriptor| {
        if (external_owner_cleanup.finishCallbackHidden(descriptor) != .cleaned)
            return .poisoned;
    }
    return .cleaned;
}

pub fn validateIntentAbortCleanupMove(
    permit: *const FrozenIntentAbort,
    out: []const external_owner_cleanup.FrozenOwnerCleanupDescriptor,
) bool {
    if (permit.saved_self_addr != @intFromPtr(permit) or
        permit.cleanup_count > max_intents or
        permit.lifecycle != .prepared or
        out.len != permit.cleanup_count or
        !std.mem.eql(
            u8,
            &permit.digest,
            &frozenIntentAbortDigest(permit),
        ) or rangesOverlap(
        @intFromPtr(&permit.cleanup),
        @as(usize, permit.cleanup_count) *
            @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
        @intFromPtr(out.ptr),
        out.len *
            @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
    ))
        return false;
    for (permit.cleanup[0..permit.cleanup_count], out) |*source, *destination|
        external_owner_cleanup.validateMoveFrozen(source, destination) catch
            return false;
    return true;
}

pub fn moveCommittedIntentAbortCleanupUnchecked(
    permit: *FrozenIntentAbort,
    out: []external_owner_cleanup.FrozenOwnerCleanupDescriptor,
) void {
    for (permit.cleanup[0..permit.cleanup_count], out) |*source, *destination|
        external_owner_cleanup.moveFrozenUnchecked(source, destination);
    permit.lifecycle = .spent;
    permit.digest = frozenIntentAbortDigest(permit);
}

pub fn abortAll(handle: *ExternalRxIntentHandle) AbortResult {
    var permit: FrozenIntentAbort = .{};
    prepareIntentAbort(handle, 0, &permit) catch {
        const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
            return .poisoned;
        return poison(scratch, handle);
    };
    if (!validatePreparedIntentAbort(handle, &permit)) {
        const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
            return .poisoned;
        return poison(scratch, handle);
    }
    commitIntentAbortUnchecked(handle, &permit);
    return finishFrozenIntentAbort(&permit);
}

pub fn resetForNextTurn(
    handle: *ExternalRxIntentHandle,
    authority_ops: AuthorityOps,
) ResetResult {
    const scratch = validateHandleAndScratch(handle, .ready, .spent) orelse
        return .invalid_state;
    const authority = authority_ops.current(authority_ops.context) orelse
        return .invalid_state;
    const after_callback =
        validateHandleAndScratch(handle, .ready, .spent) orelse
        return .invalid_state;
    if (after_callback != scratch or
        !authorityMatchesReservation(handle, scratch, authority) or
        authority.operation_generation <= scratch.turn_generation or
        authority.parser_generation < scratch.last_parser_generation or
        authority.buffer_start_absolute < scratch.last_moved_end_absolute)
        return .invalid_state;
    for (scratch.intents) |intent|
        if (intent != .empty and intent != .aborted and intent != .committed)
            return .invalid_state;
    scratch.intents = [_]PreparedRxIntent{.empty} ** max_intents;
    scratch.intent_count = 0;
    scratch.turn_generation = authority.operation_generation;
    scratch.lifecycle = .ready;
    scratch.digest = scratchDigest(scratch);
    return .ready;
}

/// Read-only closure check used by the outer turn epilogue before it marks caller-owned scratch
/// reusable. An empty handle has never allocated; a live handle must point to an authenticated
/// spent scratch whose intents are all terminal scalar states.
pub fn closedForOuterTurn(
    handle: *const ExternalRxIntentHandle,
) bool {
    if (handle.lifecycle == .empty)
        return handle.saved_self_addr == 0 and handle.scratch_addr == 0 and
            handle.allocation_addr == 0 and handle.allocation_len == 0 and
            handle.allocator_ptr_addr == 0 and
            handle.allocator_vtable_addr == 0 and
            handle.cleanup_allocator == null and handle.storage_addr == 0 and
            handle.reservation_generation == 0 and
            std.mem.allEqual(u8, &handle.digest, 0);
    const mutable: *ExternalRxIntentHandle = @constCast(handle);
    const scratch = validateHandleAndScratch(
        mutable,
        .ready,
        .spent,
    ) orelse return false;
    for (scratch.intents) |intent|
        if (intent != .empty and intent != .aborted and intent != .committed)
            return false;
    return true;
}

pub fn prepareDestroy(
    handle: *ExternalRxIntentHandle,
    storage_addr: usize,
    reservation_generation: u64,
    prepared: *PreparedDestroy,
) bool {
    if (prepared.saved_self_addr != 0 or prepared.lifecycle != .empty)
        return false;
    const scratch = validateHandleAnyReadyState(handle) orelse return false;
    if (handle.storage_addr != storage_addr or
        handle.reservation_generation != reservation_generation or
        reservation_generation == 0 or
        !allocatorMatches(
            handle.allocator,
            handle.allocator_ptr_addr,
            handle.allocator_vtable_addr,
        ) or
        !optionalAllocatorMatches(
            handle.cleanup_allocator,
            handle.allocator_ptr_addr,
            handle.allocator_vtable_addr,
        ))
        return false;
    var cleanup = [_]FrozenPayloadCleanup{.{}} ** max_intents;
    switch (scratch.lifecycle) {
        .ready => if (!freezeClassifiedCleanup(scratch, &cleanup))
            return false,
        .spent => if (scratch.intent_count != 0) return false,
        else => return false,
    }
    prepared.* = .{
        .saved_self_addr = @intFromPtr(prepared),
        .handle_addr = @intFromPtr(handle),
        .scratch_addr = @intFromPtr(scratch),
        .storage_addr = storage_addr,
        .reservation_generation = reservation_generation,
        .allocator = handle.cleanup_allocator.?,
        .cleanup = cleanup,
        .cleanup_count = scratch.intent_count,
        .lifecycle = .prepared,
        .digest = undefined,
    };
    prepared.digest = preparedDestroyDigest(prepared);
    return true;
}

pub fn validatePreparedDestroy(
    handle: *ExternalRxIntentHandle,
    prepared: *const PreparedDestroy,
) bool {
    const scratch = validateHandleAnyReadyState(handle) orelse return false;
    if (prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.cleanup_count > max_intents or
        prepared.handle_addr != @intFromPtr(handle) or
        prepared.scratch_addr != @intFromPtr(scratch) or
        prepared.storage_addr != handle.storage_addr or
        prepared.reservation_generation != handle.reservation_generation or
        prepared.lifecycle != .prepared or
        !allocatorMatches(
            prepared.allocator,
            handle.allocator_ptr_addr,
            handle.allocator_vtable_addr,
        ) or
        !std.mem.eql(
            u8,
            &prepared.digest,
            &preparedDestroyDigest(prepared),
        ))
        return false;
    if (prepared.cleanup_count != scratch.intent_count)
        return false;
    switch (scratch.lifecycle) {
        .ready => {
            var expected = [_]FrozenPayloadCleanup{.{}} ** max_intents;
            if (!freezeClassifiedCleanup(scratch, &expected)) return false;
            for (expected[0..scratch.intent_count], prepared.cleanup[0..prepared.cleanup_count]) |a, b|
                if (!std.meta.eql(a, b)) return false;
        },
        .spent => if (scratch.intent_count != 0) return false,
        else => return false,
    }
    return true;
}

pub fn appendPreparedDestroyRange(
    prepared: *const PreparedDestroy,
    ranges: *external_owner_range.Scratch,
) external_owner_range.Error!void {
    if (prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.cleanup_count > max_intents or
        prepared.scratch_addr == 0 or
        prepared.lifecycle != .prepared or
        !std.mem.eql(
            u8,
            &prepared.digest,
            &preparedDestroyDigest(prepared),
        ))
        return error.InvalidRange;
    try ranges.append(
        prepared.scratch_addr,
        @sizeOf(ExternalRxIntentScratch),
    );
    for (prepared.cleanup[0..prepared.cleanup_count]) |item|
        try ranges.append(
            if (item.payload.len == 0)
                0
            else
                @intFromPtr(item.payload.ptr),
            item.payload.len,
        );
}

pub fn appendBoundOwnerRanges(
    handle: *ExternalRxIntentHandle,
    ranges: *external_owner_range.Scratch,
) external_owner_range.Error!void {
    return appendBoundOwnerRangesInternal(handle, null, ranges);
}

/// Exports the intent-owned ranges after screen payloads have moved into one prepared aggregate.
/// A staged screen remains a sealed source receipt, but its allocation is now owned by the
/// aggregate/live ledger and is therefore exported by that owner rather than duplicated here.
/// The aggregate address is mandatory authority: accepting a staging receipt without it would
/// turn an arbitrary union tag into permission to omit a live allocation from alias validation.
pub fn appendBoundOwnerRangesForAggregate(
    handle: *ExternalRxIntentHandle,
    aggregate_addr: usize,
    ranges: *external_owner_range.Scratch,
) external_owner_range.Error!void {
    if (aggregate_addr == 0) return error.InvalidRange;
    return appendBoundOwnerRangesInternal(handle, aggregate_addr, ranges);
}

fn appendBoundOwnerRangesInternal(
    handle: *ExternalRxIntentHandle,
    aggregate_addr: ?usize,
    ranges: *external_owner_range.Scratch,
) external_owner_range.Error!void {
    const scratch = validateHandleAnyReadyState(handle) orelse
        return error.InvalidRange;
    try ranges.append(
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    );
    try ranges.append(
        scratch.allocation_addr,
        scratch.allocation_len,
    );
    if (scratch.lifecycle == .spent) {
        if (scratch.intent_count != 0) return error.InvalidRange;
        return;
    }
    if (scratch.lifecycle != .ready) return error.InvalidRange;
    for (scratch.intents[0..scratch.intent_count], 0..) |*intent, index| {
        switch (intent.*) {
            .classified => |*owner| {
                if (!ownerValid(owner, scratch)) return error.InvalidRange;
                if (owner.payload_len != 0)
                    try ranges.append(owner.payload_addr, owner.payload_len);
            },
            .screen_staging => |*staged| {
                const destination = aggregate_addr orelse return error.InvalidRange;
                if (!stagedScreenIntentValid(
                    staged,
                    scratch,
                    @intFromPtr(&scratch.intents[index]),
                    destination,
                )) return error.InvalidRange;
                continue;
            },
            else => return error.InvalidRange,
        }
    }
}

pub fn commitPreparedDestroy(
    handle: *ExternalRxIntentHandle,
    prepared: *PreparedDestroy,
) FrozenDestroy {
    std.debug.assert(validatePreparedDestroy(handle, prepared));
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(prepared.scratch_addr);
    var frozen: FrozenDestroy = undefined;
    commitPreparedDestroyUnchecked(handle, scratch, prepared, &frozen);
    return frozen;
}

/// No-fail publication leaf for callers that completed `validatePreparedDestroy` before their
/// first semantic write. `scratch_opaque` is captured from the sealed prepared address during
/// that preflight; this function deliberately performs no raw-address lookup or validation.
// MARU_F3C2_INTENT_DESTROY_UNCHECKED_BEGIN
pub fn commitPreparedDestroyUnchecked(
    handle: *ExternalRxIntentHandle,
    scratch_opaque: *anyopaque,
    prepared: *PreparedDestroy,
    frozen_out: *FrozenDestroy,
) void {
    const scratch: *ExternalRxIntentScratch = @ptrCast(@alignCast(scratch_opaque));
    const cleanup_count = prepared.cleanup_count;
    for (0..cleanup_count) |index| scratch.intents[index] = .aborted;
    scratch.intent_count = 0;
    scratch.lifecycle = .destroying;
    scratch.digest = scratchDigest(scratch);
    handle.lifecycle = .destroying;
    handle.digest = handleDigest(handle);
    frozen_out.* = .{
        .scratch = scratch,
        .handle = handle,
        .allocator = prepared.allocator,
        .cleanup = prepared.cleanup,
        .cleanup_count = cleanup_count,
        .storage_addr = prepared.storage_addr,
        .reservation_generation = prepared.reservation_generation,
    };
    prepared.lifecycle = .consumed;
}
// MARU_F3C2_INTENT_DESTROY_UNCHECKED_END

pub fn finishFrozenDestroy(frozen: FrozenDestroy) void {
    for (frozen.cleanup[0..frozen.cleanup_count]) |item|
        item.allocator.free(item.payload);
    frozen.allocator.destroy(frozen.scratch);
    frozen.handle.* = .{
        .saved_self_addr = @intFromPtr(frozen.handle),
        .lifecycle = .destroyed,
        .digest = undefined,
    };
    frozen.handle.digest = handleDigest(frozen.handle);
}

/// The destroy callback has already freed the backing scratch. The final stack owner may now
/// return only the authenticated scalar tombstone to the canonical empty state.
pub fn resetDestroyedForOuterTurn(handle: *ExternalRxIntentHandle) bool {
    if (handle.saved_self_addr != @intFromPtr(handle) or
        handle.scratch_addr != 0 or handle.allocation_addr != 0 or
        handle.allocation_len != 0 or handle.allocator_ptr_addr != 0 or
        handle.allocator_vtable_addr != 0 or handle.cleanup_allocator != null or
        handle.storage_addr != 0 or handle.reservation_generation != 0 or
        handle.lifecycle != .destroyed or
        !std.mem.eql(u8, &handle.digest, &handleDigest(handle)))
        return false;
    handle.* = .{};
    return true;
}

test "f3d destroyed intent tombstone resets only from exact authenticated state" {
    var handle: ExternalRxIntentHandle = .{
        .saved_self_addr = undefined,
        .lifecycle = .destroyed,
        .digest = undefined,
    };
    handle.saved_self_addr = @intFromPtr(&handle);
    handle.digest = handleDigest(&handle);

    try std.testing.expect(resetDestroyedForOuterTurn(&handle));
    try std.testing.expect(handlePristine(&handle));
}

test "f3d destroyed intent tombstone rejects forged fields and digest" {
    var handle: ExternalRxIntentHandle = .{
        .saved_self_addr = undefined,
        .lifecycle = .destroyed,
        .digest = undefined,
    };
    handle.saved_self_addr = @intFromPtr(&handle);
    handle.digest = handleDigest(&handle);

    handle.storage_addr = 1;
    handle.digest = handleDigest(&handle);
    try std.testing.expect(!resetDestroyedForOuterTurn(&handle));
    handle.storage_addr = 0;
    handle.digest = handleDigest(&handle);
    handle.digest[0] ^= 0xff;
    try std.testing.expect(!resetDestroyedForOuterTurn(&handle));
    handle.digest = handleDigest(&handle);
    handle.saved_self_addr +%= 1;
    try std.testing.expect(!resetDestroyedForOuterTurn(&handle));
}

fn handlePristine(handle: *const ExternalRxIntentHandle) bool {
    return handle.saved_self_addr == 0 and handle.scratch_addr == 0 and
        handle.allocation_addr == 0 and handle.allocation_len == 0 and
        handle.lifecycle == .empty and
        std.mem.allEqual(u8, &handle.digest, 0);
}

fn authorityViewValid(view: AuthorityView) bool {
    return view.storage_addr != 0 and view.storage_len != 0 and
        view.operation_generation != 0 and view.parser_generation != 0 and
        view.identity.attach_instance_id != 0 and
        view.identity.destination_slot_addr != 0 and
        ((view.operation_scratch_addr == 0 and
            view.operation_scratch_len == 0) or
            (view.operation_scratch_addr != 0 and
                view.operation_scratch_len != 0)) and
        ((view.operation_lease_addr == 0 and
            view.operation_lease_len == 0) or
            (view.operation_lease_addr != 0 and
                view.operation_lease_len != 0)) and
        view.forbidden_ranges_generation != 0 and
        authorityRangesStructurallyValid(view.forbidden_ranges) and
        std.mem.eql(
            u8,
            &view.forbidden_ranges_digest,
            &authorityRangesDigest(
                view.forbidden_ranges,
                view.forbidden_ranges_generation,
            ),
        );
}

fn rangeAliasesOperationAuthority(
    addr: usize,
    len: usize,
    view: AuthorityView,
) bool {
    return rangesOverlap(
        addr,
        len,
        view.operation_scratch_addr,
        view.operation_scratch_len,
    ) or rangesOverlap(
        addr,
        len,
        view.operation_lease_addr,
        view.operation_lease_len,
    );
}

/// Validates an allocator result against the sealed product authority without dereferencing it.
/// Callers must use this before typed conversion, writes, or cleanup of a pointer returned by an
/// allocator callback. `false` means ownership is unprovable and therefore also forbids free.
pub fn allocationDisjointFromAuthority(
    view: AuthorityView,
    addr: usize,
    len: usize,
) bool {
    if (!authorityViewValid(view) or addr == 0 or len == 0)
        return false;
    _ = std.math.add(usize, addr, len) catch return false;
    return !rangesOverlap(
        addr,
        len,
        view.storage_addr,
        view.storage_len,
    ) and
        !rangeAliasesOperationAuthority(addr, len, view) and
        !rangeAliasesInventory(addr, len, view.forbidden_ranges) and
        !rangesOverlap(
            addr,
            len,
            if (view.forbidden_ranges.len == 0)
                0
            else
                @intFromPtr(view.forbidden_ranges.ptr),
            view.forbidden_ranges.len * @sizeOf(external_owner_range.Range),
        ) and
        !rangesOverlap(
            addr,
            len,
            view.reservation_handle_addr,
            if (view.reservation_handle_addr == 0)
                0
            else
                @sizeOf(ExternalRxIntentHandle),
        );
}

fn authorityMatchesBound(
    handle: *const ExternalRxIntentHandle,
    scratch: *const ExternalRxIntentScratch,
    view: AuthorityView,
) bool {
    return authorityMatchesReservation(handle, scratch, view) and
        view.operation_generation == scratch.turn_generation;
}

fn authorityMatchesReservation(
    handle: *const ExternalRxIntentHandle,
    scratch: *const ExternalRxIntentScratch,
    view: AuthorityView,
) bool {
    return authorityViewValid(view) and
        view.storage_addr == scratch.storage_addr and
        view.storage_len == scratch.storage_len and
        view.reservation_handle_addr == @intFromPtr(handle) and
        view.reservation_generation == handle.reservation_generation and
        !scratchRangeAliasesAuthority(scratch.allocation_addr, handle, view) and
        allocatorMatches(
            view.allocator,
            handle.allocator_ptr_addr,
            handle.allocator_vtable_addr,
        );
}

fn validateHandleAndScratch(
    handle: *ExternalRxIntentHandle,
    expected_handle: HandleLifecycle,
    expected_scratch: ScratchLifecycle,
) ?*ExternalRxIntentScratch {
    if (handle.saved_self_addr != @intFromPtr(handle) or
        handle.lifecycle != expected_handle or
        !std.mem.eql(u8, &handle.digest, &handleDigest(handle)) or
        handle.scratch_addr == 0 or
        handle.scratch_addr != handle.allocation_addr or
        handle.allocation_len != @sizeOf(ExternalRxIntentScratch))
        return null;
    const scratch: *ExternalRxIntentScratch = @ptrFromInt(handle.scratch_addr);
    if (scratch.saved_self_addr != @intFromPtr(scratch) or
        scratch.handle_addr != @intFromPtr(handle) or
        scratch.allocation_addr != @intFromPtr(scratch) or
        scratch.allocation_len != @sizeOf(ExternalRxIntentScratch) or
        scratch.storage_addr != handle.storage_addr or
        scratch.intent_count > max_intents or
        scratch.lifecycle != expected_scratch or
        !std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch)))
        return null;
    return scratch;
}

fn validateHandleAnyReadyState(
    handle: *ExternalRxIntentHandle,
) ?*ExternalRxIntentScratch {
    return validateHandleAndScratch(handle, .ready, .ready) orelse
        validateHandleAndScratch(handle, .ready, .spent);
}

fn frameDescriptorValid(
    paired: *const client_external_mode.ExternalRxFrame,
    view: AuthorityView,
) bool {
    if (!std.meta.eql(paired.range.identity, view.identity) or
        paired.range.start_absolute >= paired.range.end_absolute or
        paired.frame.payload.len != paired.frame.header.payload_len)
        return false;
    const payload_addr = if (paired.frame.payload.len == 0)
        0
    else
        @intFromPtr(paired.frame.payload.ptr);
    if (payload_addr == 0 and paired.frame.payload.len != 0) return false;
    _ = std.math.add(usize, payload_addr, paired.frame.payload.len) catch
        return false;
    return true;
}

fn payloadAliasesLiveIntent(
    scratch: *const ExternalRxIntentScratch,
    addr: usize,
    len: usize,
) bool {
    for (scratch.intents[0..scratch.intent_count]) |intent| switch (intent) {
        .classified => |owner| if (rangesOverlap(
            addr,
            len,
            owner.payload_addr,
            owner.payload_len,
        )) return true,
        else => {},
    };
    return false;
}

fn framePayloadAliasesAuthority(
    handle: *const ExternalRxIntentHandle,
    scratch: *const ExternalRxIntentScratch,
    payload: []const u8,
    view: AuthorityView,
) bool {
    if (payload.len == 0) return false;
    const addr = @intFromPtr(payload.ptr);
    return rangesOverlap(
        addr,
        payload.len,
        scratch.allocation_addr,
        scratch.allocation_len,
    ) or rangesOverlap(
        addr,
        payload.len,
        view.storage_addr,
        view.storage_len,
    ) or rangesOverlap(
        addr,
        payload.len,
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    ) or rangeAliasesOperationAuthority(
        addr,
        payload.len,
        view,
    ) or rangeAliasesInventory(
        addr,
        payload.len,
        view.forbidden_ranges,
    ) or rangesOverlap(
        addr,
        payload.len,
        if (view.forbidden_ranges.len == 0)
            0
        else
            @intFromPtr(view.forbidden_ranges.ptr),
        view.forbidden_ranges.len * @sizeOf(external_owner_range.Range),
    ) or payloadAliasesLiveIntent(scratch, addr, payload.len);
}

fn rangeAliasesAuthorityOwners(
    addr: usize,
    len: usize,
    handle: *const ExternalRxIntentHandle,
    scratch: *const ExternalRxIntentScratch,
    view: AuthorityView,
) bool {
    return rangesOverlap(
        addr,
        len,
        scratch.allocation_addr,
        scratch.allocation_len,
    ) or rangesOverlap(
        addr,
        len,
        view.storage_addr,
        view.storage_len,
    ) or rangesOverlap(
        addr,
        len,
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    ) or rangeAliasesOperationAuthority(
        addr,
        len,
        view,
    ) or rangeAliasesInventory(
        addr,
        len,
        view.forbidden_ranges,
    ) or rangesOverlap(
        addr,
        len,
        if (view.forbidden_ranges.len == 0)
            0
        else
            @intFromPtr(view.forbidden_ranges.ptr),
        view.forbidden_ranges.len * @sizeOf(external_owner_range.Range),
    );
}

fn freezeClassifiedCleanup(
    scratch: *const ExternalRxIntentScratch,
    cleanup: []FrozenPayloadCleanup,
) bool {
    if (scratch.intent_count > cleanup.len) return false;
    for (0..scratch.intent_count) |index| {
        const owner = switch (scratch.intents[index]) {
            .classified => |*classified| classified,
            else => return false,
        };
        if (!ownerValid(owner, scratch)) return false;
        for (0..index) |prior_index| {
            const prior = switch (scratch.intents[prior_index]) {
                .classified => |*classified| classified,
                else => return false,
            };
            if (rangesOverlap(
                owner.payload_addr,
                owner.payload_len,
                prior.payload_addr,
                prior.payload_len,
            )) return false;
        }
        cleanup[index] = .{
            .allocator = owner.allocator,
            .payload = owner.cleanup_payload.?,
        };
    }
    return true;
}

fn ownerValid(
    owner: *const ClassifiedIntentOwner,
    scratch: *const ExternalRxIntentScratch,
) bool {
    if (owner.saved_self_addr != @intFromPtr(owner) or
        owner.storage_addr != scratch.storage_addr or
        owner.turn_generation != scratch.turn_generation or
        owner.lifecycle != .classified or
        owner.classification == .protocol_terminal or
        owner.frame.payload.len != owner.payload_len or
        (if (owner.payload_len == 0)
            owner.payload_addr != 0
        else
            owner.payload_addr == 0 or
                @intFromPtr(owner.frame.payload.ptr) != owner.payload_addr) or
        !optionalSliceMatches(owner.cleanup_payload, owner.payload_addr, owner.payload_len) or
        !allocatorMatches(owner.allocator, owner.allocator_ptr_addr, owner.allocator_vtable_addr) or
        !std.mem.eql(u8, &owner.cleanup_digest, &cleanupDigest(owner)) or
        !std.mem.eql(u8, &owner.digest, &ownerDigest(owner)))
        return false;
    return std.mem.eql(
        u8,
        &owner.payload_digest,
        &payloadDigest(owner.frame.payload),
    );
}

fn poison(
    scratch: *ExternalRxIntentScratch,
    handle: *ExternalRxIntentHandle,
) AbortResult {
    scratch.lifecycle = .poisoned;
    scratch.digest = scratchDigest(scratch);
    handle.lifecycle = .poisoned;
    handle.digest = handleDigest(handle);
    return .poisoned;
}

fn payloadDigest(bytes: []const u8) external_owner_seal.Digest {
    // Cross-owner moves must carry the content seal shared by ledger admission and frozen
    // cleanup. A private intent-domain hash would make the same bytes unverifiable after move.
    return external_owner_cleanup.contentDigest(bytes);
}

fn authorityRangesStructurallyValid(
    ranges: []const external_owner_range.Range,
) bool {
    if (ranges.len > max_authority_ranges) return false;
    for (ranges, 0..) |range, index| {
        if (range.start == 0 or range.len == 0) return false;
        _ = std.math.add(usize, range.start, range.len) catch return false;
        if (index != 0) {
            const prior = ranges[index - 1];
            if (range.start < prior.start + prior.len) return false;
        }
    }
    return true;
}

fn authorityRangesDigest(
    ranges: []const external_owner_range.Range,
    generation: u64,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXAR1");
    writer.writeU64(generation);
    writer.writeUsize(ranges.len);
    for (ranges) |range| {
        writer.writeUsize(range.start);
        writer.writeUsize(range.len);
    }
    return writer.finish();
}

fn rangeAliasesInventory(
    start: usize,
    len: usize,
    ranges: []const external_owner_range.Range,
) bool {
    for (ranges) |range|
        if (rangesOverlap(start, len, range.start, range.len))
            return true;
    return false;
}

fn scratchRangeAliasesAuthority(
    scratch_addr: usize,
    handle: *const ExternalRxIntentHandle,
    view: AuthorityView,
) bool {
    const scratch_len = @sizeOf(ExternalRxIntentScratch);
    return rangesOverlap(
        scratch_addr,
        scratch_len,
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    ) or rangesOverlap(
        scratch_addr,
        scratch_len,
        view.storage_addr,
        view.storage_len,
    ) or rangeAliasesOperationAuthority(
        scratch_addr,
        scratch_len,
        view,
    ) or rangeAliasesInventory(
        scratch_addr,
        scratch_len,
        view.forbidden_ranges,
    ) or rangesOverlap(
        scratch_addr,
        scratch_len,
        if (view.forbidden_ranges.len == 0)
            0
        else
            @intFromPtr(view.forbidden_ranges.ptr),
        view.forbidden_ranges.len * @sizeOf(external_owner_range.Range),
    );
}

fn cleanupDigest(owner: *const ClassifiedIntentOwner) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXCL1");
    writer.writeUsize(owner.payload_addr);
    writer.writeUsize(owner.payload_len);
    writer.writeUsize(owner.allocator_ptr_addr);
    writer.writeUsize(owner.allocator_vtable_addr);
    writer.writeUsize(if (owner.cleanup_payload) |payload|
        @intFromPtr(payload.ptr)
    else
        0);
    writer.writeUsize(if (owner.cleanup_payload) |payload| payload.len else 0);
    return writer.finish();
}

fn ownerDigest(owner: *const ClassifiedIntentOwner) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXIN1");
    writer.writeUsize(owner.saved_self_addr);
    writer.writeUsize(owner.storage_addr);
    writer.writeU64(owner.turn_generation);
    writer.writeU64(owner.parser_generation);
    writeHeader(&writer, owner.frame.header);
    writeRange(&writer, owner.range);
    writer.writeBytes(&owner.pair_seal);
    writer.writeUsize(owner.payload_addr);
    writer.writeUsize(owner.payload_len);
    writer.writeBytes(&owner.payload_digest);
    writeClassification(&writer, owner.classification);
    writer.writeUsize(owner.allocator_ptr_addr);
    writer.writeUsize(owner.allocator_vtable_addr);
    writer.writeBytes(&owner.cleanup_digest);
    writer.writeU8(@intFromEnum(owner.lifecycle));
    return writer.finish();
}

fn movedIntentPayloadDigest(
    payload: *const MovedIntentPayload,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXMP1");
    writer.writeUsize(payload.saved_self_addr);
    writer.writeUsize(payload.source_intent_addr);
    writer.writeUsize(payload.aggregate_addr);
    writer.writeUsize(payload.allocator_ptr_addr);
    writer.writeUsize(payload.allocator_vtable_addr);
    writer.writeUsize(payload.allocation_addr);
    writer.writeUsize(payload.allocation_len);
    writer.writeBytes(&payload.content_digest);
    writer.writeU8(@intFromEnum(payload.lifecycle));
    return writer.finish();
}

fn movedIntentPayloadPristine(
    payload: *const MovedIntentPayload,
) bool {
    return payload.saved_self_addr == 0 and
        payload.source_intent_addr == 0 and
        payload.aggregate_addr == 0 and
        payload.allocator_ptr_addr == 0 and
        payload.allocator_vtable_addr == 0 and
        payload.allocation_addr == 0 and
        payload.allocation_len == 0 and
        payload.lifecycle == .empty and
        std.mem.allEqual(u8, &payload.content_digest, 0) and
        std.mem.allEqual(u8, &payload.digest, 0);
}

fn movedIntentPayloadValid(
    payload: *const MovedIntentPayload,
    aggregate_addr: usize,
) bool {
    if (payload.saved_self_addr != @intFromPtr(payload) or
        payload.source_intent_addr == 0 or
        payload.aggregate_addr != aggregate_addr or
        aggregate_addr == 0 or
        payload.lifecycle != .owned or
        @intFromPtr(payload.allocator.ptr) != payload.allocator_ptr_addr or
        @intFromPtr(payload.allocator.vtable) != payload.allocator_vtable_addr or
        (if (payload.allocation_len == 0)
            payload.allocation_addr != 0
        else
            payload.allocation_addr == 0) or
        !std.mem.eql(
            u8,
            &payload.digest,
            &movedIntentPayloadDigest(payload),
        ))
        return false;
    const bytes: []const u8 = if (payload.allocation_len == 0)
        &.{}
    else
        @as([*]const u8, @ptrFromInt(payload.allocation_addr))[0..payload.allocation_len];
    return std.mem.eql(
        u8,
        &payload.content_digest,
        &payloadDigest(bytes),
    );
}

fn stagedScreenIntentDigest(
    staged: *const StagedScreenIntent,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXSS1");
    writer.writeUsize(staged.saved_self_addr);
    writer.writeUsize(staged.storage_addr);
    writer.writeU64(staged.turn_generation);
    writer.writeU64(staged.parser_generation);
    writer.writeU64(staged.source_start_absolute);
    writer.writeU64(staged.source_end_absolute);
    writer.writeUsize(staged.aggregate_addr);
    writer.writeUsize(staged.neutral_addr);
    writeClassification(
        &writer,
        .{ .screen_candidate = staged.classification },
    );
    writer.writeUsize(staged.payload_addr);
    writer.writeUsize(staged.payload_len);
    writer.writeBytes(&staged.payload_digest);
    return writer.finish();
}

fn stagedScreenIntentValid(
    staged: *const StagedScreenIntent,
    scratch: *const ExternalRxIntentScratch,
    expected_addr: usize,
    aggregate_addr: usize,
) bool {
    return staged.saved_self_addr == expected_addr and
        staged.storage_addr == scratch.storage_addr and
        staged.turn_generation == scratch.turn_generation and
        staged.parser_generation > scratch.parser_generation_at_start and
        staged.source_end_absolute > staged.source_start_absolute and
        staged.source_end_absolute <= scratch.last_moved_end_absolute and
        staged.aggregate_addr == aggregate_addr and
        aggregate_addr != 0 and
        staged.neutral_addr != 0 and
        (if (staged.payload_len == 0)
            staged.payload_addr == 0
        else
            staged.payload_addr != 0) and
        std.mem.eql(
            u8,
            &staged.digest,
            &stagedScreenIntentDigest(staged),
        );
}

fn screenMutationProofDigest(
    proof: *const StagedScreenMutationProof,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXSP1");
    writer.writeUsize(proof.saved_self_addr);
    writer.writeUsize(proof.source_intent_addr);
    writer.writeUsize(proof.aggregate_addr);
    writer.writeUsize(proof.batch_addr);
    writer.writeU8(proof.intent_index);
    writer.writeU8(proof.mutation_index);
    writer.writeBytes(&proof.payload_digest);
    writer.writeU8(@intFromEnum(proof.lifecycle));
    return writer.finish();
}

fn screenMutationProofValid(
    proof: *const StagedScreenMutationProof,
    staged: *const StagedScreenIntent,
    aggregate_addr: usize,
    intent_index: u8,
) bool {
    return proof.saved_self_addr == @intFromPtr(proof) and
        proof.source_intent_addr == @intFromPtr(staged) and
        proof.aggregate_addr == aggregate_addr and
        proof.batch_addr != 0 and
        proof.intent_index == intent_index and
        proof.lifecycle == .prepared and
        std.mem.eql(
            u8,
            &proof.payload_digest,
            &staged.payload_digest,
        ) and
        std.mem.eql(
            u8,
            &proof.digest,
            &screenMutationProofDigest(proof),
        );
}

fn screenMutationProofsDigest(
    proofs: []const StagedScreenMutationProof,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXPS1");
    writer.writeUsize(@intFromPtr(proofs.ptr));
    writer.writeUsize(proofs.len);
    for (proofs) |*proof| writer.writeBytes(&proof.digest);
    return writer.finish();
}

fn screenMutationProofPristine(
    proof: *const StagedScreenMutationProof,
) bool {
    return proof.saved_self_addr == 0 and
        proof.source_intent_addr == 0 and proof.aggregate_addr == 0 and
        proof.batch_addr == 0 and proof.intent_index == 0 and
        proof.mutation_index == 0 and proof.lifecycle == .empty and
        std.mem.allEqual(u8, &proof.payload_digest, 0) and
        std.mem.allEqual(u8, &proof.digest, 0);
}

fn neutralOutputsDigest(
    outputs: *const [max_intents]MovedIntentPayload,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXNO1");
    writer.writeUsize(@intFromPtr(outputs));
    writer.writeUsize(outputs.len);
    for (outputs) |*output| writer.writeBytes(&output.digest);
    return writer.finish();
}

pub fn preparedNeutralRetirementPristine(
    permit: *const PreparedNeutralRetirement,
) bool {
    const pristine = PreparedNeutralRetirement{};
    return std.mem.eql(
        u8,
        &preparedNeutralRetirementDigest(permit),
        &preparedNeutralRetirementDigest(&pristine),
    );
}

fn preparedNeutralRetirementDigest(
    permit: *const PreparedNeutralRetirement,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXNR1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.handle_addr);
    writer.writeUsize(permit.scratch_addr);
    writer.writeUsize(permit.intent_commit_addr);
    writer.writeUsize(permit.aggregate_addr);
    writer.writeUsize(permit.aggregate_len);
    writer.writeUsize(permit.neutral_addr);
    writer.writeUsize(permit.cleanup_output_addr);
    writer.writeUsize(permit.source_intent_addr);
    writer.writeU8(permit.intent_index);
    writer.writeUsize(permit.allocator_ptr_addr);
    writer.writeUsize(permit.allocator_vtable_addr);
    writer.writeUsize(permit.allocation_addr);
    writer.writeUsize(permit.allocation_len);
    writer.writeBytes(&permit.content_digest);
    writer.writeBytes(&permit.source_owner_digest);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn preparedNeutralRetirementHeaderValid(
    handle: *const ExternalRxIntentHandle,
    neutral_outputs: *const [max_intents]MovedIntentPayload,
    intent_commit: *const PreparedIntentCommit,
    cleanup_output: *const external_owner_cleanup.FrozenOwnerCleanupDescriptor,
    permit: *const PreparedNeutralRetirement,
    expected_lifecycle: NeutralRetirementLifecycle,
) bool {
    if (permit.intent_index >= intent_commit.intent_count) return false;
    const aggregate_end = std.math.add(
        usize,
        permit.aggregate_addr,
        permit.aggregate_len,
    ) catch return false;
    const permit_end = std.math.add(
        usize,
        @intFromPtr(permit),
        @sizeOf(PreparedNeutralRetirement),
    ) catch return false;
    const cleanup_end = std.math.add(
        usize,
        @intFromPtr(cleanup_output),
        @sizeOf(external_owner_cleanup.FrozenOwnerCleanupDescriptor),
    ) catch return false;
    const expected_neutral_addr =
        @intFromPtr(neutral_outputs) +
        @as(usize, permit.intent_index) * @sizeOf(MovedIntentPayload);
    return permit.saved_self_addr == @intFromPtr(permit) and
        permit.handle_addr == @intFromPtr(handle) and
        permit.scratch_addr == intent_commit.scratch_addr and
        permit.intent_commit_addr == @intFromPtr(intent_commit) and
        permit.aggregate_addr == intent_commit.aggregate_addr and
        permit.aggregate_len == intent_commit.aggregate_len and
        permit.neutral_addr == expected_neutral_addr and
        permit.cleanup_output_addr == @intFromPtr(cleanup_output) and
        permit.allocation_addr != 0 and permit.allocation_len != 0 and
        permit.lifecycle == expected_lifecycle and
        intent_commit.slot_kinds[permit.intent_index] == .event and
        @intFromPtr(permit) >= permit.aggregate_addr and
        permit_end <= aggregate_end and
        @intFromPtr(cleanup_output) >= permit.aggregate_addr and
        cleanup_end <= aggregate_end and
        external_owner_cleanup.isPristine(cleanup_output) and
        std.mem.eql(
            u8,
            &permit.digest,
            &preparedNeutralRetirementDigest(permit),
        );
}

fn preparedIntentCommitDigest(
    permit: *const PreparedIntentCommit,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXIC1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.handle_addr);
    writer.writeUsize(permit.scratch_addr);
    writer.writeUsize(permit.aggregate_addr);
    writer.writeUsize(permit.aggregate_len);
    writer.writeUsize(permit.proofs_addr);
    writer.writeUsize(permit.neutral_outputs_addr);
    writer.writeU8(permit.proof_count);
    writer.writeU8(permit.intent_count);
    writer.writeU64(permit.final_parser_generation);
    writer.writeU64(permit.final_end_absolute);
    for (permit.slot_kinds) |kind| writer.writeU8(@intFromEnum(kind));
    for (permit.response_request_ids) |request_id|
        writer.writeU64(request_id);
    for (permit.source_parser_generations) |generation|
        writer.writeU64(generation);
    for (permit.source_start_absolutes) |start_absolute|
        writer.writeU64(start_absolute);
    for (permit.source_end_absolutes) |end_absolute|
        writer.writeU64(end_absolute);
    for (permit.source_owner_digests) |digest| writer.writeBytes(&digest);
    for (permit.payload_digests) |digest| writer.writeBytes(&digest);
    writer.writeUsize(permit.destination_plan_addr);
    writer.writeUsize(permit.destination_plan_len);
    writer.writeBytes(&permit.destination_plan_digest);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    writer.writeBytes(&permit.proofs_digest);
    writer.writeBytes(&permit.neutral_outputs_digest);
    return writer.finish();
}

fn aggregateRangeAliasesIntentAuthority(
    handle: *const ExternalRxIntentHandle,
    scratch: *const ExternalRxIntentScratch,
    view: AuthorityView,
    aggregate_addr: usize,
    aggregate_len: usize,
) bool {
    return rangesOverlap(
        aggregate_addr,
        aggregate_len,
        @intFromPtr(handle),
        @sizeOf(ExternalRxIntentHandle),
    ) or rangesOverlap(
        aggregate_addr,
        aggregate_len,
        scratch.allocation_addr,
        scratch.allocation_len,
    ) or rangesOverlap(
        aggregate_addr,
        aggregate_len,
        view.storage_addr,
        view.storage_len,
    ) or rangeAliasesInventory(
        aggregate_addr,
        aggregate_len,
        view.forbidden_ranges,
    ) or rangesOverlap(
        aggregate_addr,
        aggregate_len,
        if (view.forbidden_ranges.len == 0)
            0
        else
            @intFromPtr(view.forbidden_ranges.ptr),
        view.forbidden_ranges.len * @sizeOf(external_owner_range.Range),
    ) or payloadAliasesLiveIntent(
        scratch,
        aggregate_addr,
        aggregate_len,
    );
}

fn scratchDigest(
    scratch: *const ExternalRxIntentScratch,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXSC1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeUsize(scratch.handle_addr);
    writer.writeUsize(scratch.allocation_addr);
    writer.writeUsize(scratch.allocation_len);
    writer.writeUsize(scratch.storage_addr);
    writer.writeUsize(scratch.storage_len);
    writer.writeU64(scratch.turn_generation);
    writer.writeU64(scratch.parser_generation_at_start);
    writer.writeU64(scratch.last_parser_generation);
    writer.writeU64(scratch.last_moved_end_absolute);
    writer.writeU8(scratch.intent_count);
    for (scratch.intents) |intent| switch (intent) {
        .empty => writer.writeU8(0),
        .classified => |owner| {
            writer.writeU8(1);
            writer.writeBytes(&owner.digest);
        },
        .screen_staging => |staged| {
            writer.writeU8(2);
            writer.writeBytes(&staged.digest);
        },
        .committed => writer.writeU8(3),
        .aborted => writer.writeU8(4),
    };
    writer.writeU8(@intFromEnum(scratch.lifecycle));
    return writer.finish();
}

fn handleDigest(handle: *const ExternalRxIntentHandle) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXHD1");
    writer.writeUsize(handle.saved_self_addr);
    writer.writeUsize(handle.scratch_addr);
    writer.writeUsize(handle.allocation_addr);
    writer.writeUsize(handle.allocation_len);
    writer.writeUsize(handle.allocator_ptr_addr);
    writer.writeUsize(handle.allocator_vtable_addr);
    writer.writeUsize(@intFromPtr(handle.allocator.ptr));
    writer.writeUsize(@intFromPtr(handle.allocator.vtable));
    if (handle.cleanup_allocator) |allocator| {
        writer.writeBool(true);
        writer.writeUsize(@intFromPtr(allocator.ptr));
        writer.writeUsize(@intFromPtr(allocator.vtable));
    } else {
        writer.writeBool(false);
    }
    writer.writeUsize(handle.storage_addr);
    writer.writeU64(handle.reservation_generation);
    writer.writeU8(@intFromEnum(handle.lifecycle));
    return writer.finish();
}

fn preparedDestroyDigest(
    prepared: *const PreparedDestroy,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXDT1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.handle_addr);
    writer.writeUsize(prepared.scratch_addr);
    writer.writeUsize(prepared.storage_addr);
    writer.writeU64(prepared.reservation_generation);
    writer.writeUsize(@intFromPtr(prepared.allocator.ptr));
    writer.writeUsize(@intFromPtr(prepared.allocator.vtable));
    writer.writeU8(prepared.cleanup_count);
    for (prepared.cleanup[0..prepared.cleanup_count]) |item| {
        writer.writeUsize(@intFromPtr(item.allocator.ptr));
        writer.writeUsize(@intFromPtr(item.allocator.vtable));
        writer.writeUsize(if (item.payload.len == 0)
            0
        else
            @intFromPtr(item.payload.ptr));
        writer.writeUsize(item.payload.len);
    }
    writer.writeU8(@intFromEnum(prepared.lifecycle));
    return writer.finish();
}

fn frozenIntentAbortDigest(
    permit: *const FrozenIntentAbort,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUXAB1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.handle_addr);
    writer.writeUsize(permit.scratch_addr);
    writer.writeUsize(permit.aggregate_addr);
    writer.writeU8(permit.cleanup_count);
    writer.writeU8(permit.intent_count);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    for (permit.cleanup[0..permit.cleanup_count]) |descriptor|
        writer.writeBytes(&descriptor.digest);
    return writer.finish();
}

fn writeHeader(
    writer: *external_owner_seal.Writer,
    header: protocol.Header,
) void {
    writer.writeU16(header.major);
    writer.writeU16(@intFromEnum(header.kind));
    writer.writeU64(header.stream_id);
    writer.writeU64(header.request_id);
    writer.writeU64(header.flags);
    writer.writeU64(header.payload_len);
}

fn writeRange(
    writer: *external_owner_seal.Writer,
    range: external_rx_types.RxRange,
) void {
    writer.writeU64(range.identity.attach_instance_id);
    writer.writeUsize(range.identity.destination_slot_addr);
    writer.writeU64(range.start_absolute);
    writer.writeU64(range.end_absolute);
}

fn writeClassification(
    writer: *external_owner_seal.Writer,
    classification: external_rx_demux.ExternalWireClass,
) void {
    switch (classification) {
        .screen_candidate => |candidate| {
            writer.writeU8(1);
            writeHeader(writer, candidate.header);
            writeRange(writer, candidate.range);
            writer.writeBytes(&candidate.pair_seal);
            writeOptionalPartial(writer, candidate.partial_before);
            writeOptionalPartial(writer, candidate.partial_after);
        },
        .event_candidate => |candidate| {
            writer.writeU8(2);
            writeHeader(writer, candidate.header);
            writeRange(writer, candidate.range);
            writer.writeBytes(&candidate.pair_seal);
        },
        .response_candidate => |candidate| {
            writer.writeU8(3);
            writer.writeU64(candidate.request_id);
            writeHeader(writer, candidate.header);
            writeRange(writer, candidate.range);
            writer.writeBytes(&candidate.pair_seal);
        },
        .protocol_terminal => writer.writeU8(4),
    }
}

fn writeOptionalPartial(
    writer: *external_owner_seal.Writer,
    partial: ?external_rx_demux.ValidatedPartialView,
) void {
    if (partial) |value| {
        writer.writeBool(true);
        writer.writeU64(value.stream_id);
        writer.writeBool(value.is_snapshot);
        writer.writeU64(value.identity.attach_instance_id);
        writer.writeUsize(value.identity.destination_slot_addr);
        writer.writeU64(value.start_absolute);
        writer.writeU64(value.end_absolute);
        writer.writeU8(value.chunk_count);
    } else writer.writeBool(false);
}

fn allocatorMatches(
    allocator: std.mem.Allocator,
    ptr_addr: usize,
    vtable_addr: usize,
) bool {
    return @intFromPtr(allocator.ptr) == ptr_addr and
        @intFromPtr(allocator.vtable) == vtable_addr;
}

fn optionalAllocatorMatches(
    allocator: ?std.mem.Allocator,
    ptr_addr: usize,
    vtable_addr: usize,
) bool {
    return if (allocator) |value|
        allocatorMatches(value, ptr_addr, vtable_addr)
    else
        false;
}

fn optionalSliceMatches(
    slice: ?[]u8,
    addr: usize,
    len: usize,
) bool {
    return if (slice) |value|
        value.len == len and (len == 0 or @intFromPtr(value.ptr) == addr)
    else
        false;
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

const TestAuthority = struct {
    view: AuthorityView,
    next_view: ?AuthorityView = null,
    call_count: usize = 0,
    mutate_source: ?*client_external_mode.ExternalRxOutcome = null,
    mutate_source_on_call: usize = std.math.maxInt(usize),
    substitute_payload: ?[]u8 = null,

    fn current(context: *anyopaque) ?AuthorityView {
        const self: *TestAuthority = @ptrCast(@alignCast(context));
        if (self.call_count == self.mutate_source_on_call) {
            const frame = switch (self.mutate_source.?.*) {
                .frame => |*paired| paired,
                else => unreachable,
            };
            if (self.substitute_payload) |payload|
                frame.frame.payload = payload
            else
                frame.frame.payload[0] ^= 1;
        }
        defer self.call_count += 1;
        return if (self.call_count != 0)
            self.next_view orelse self.view
        else
            self.view;
    }

    fn ops(self: *TestAuthority) AuthorityOps {
        return .{ .context = self, .current = current };
    }
};

const FreeCountingAllocator = struct {
    parent: std.mem.Allocator,
    free_count: usize = 0,
    mutate_handle: ?*ExternalRxIntentHandle = null,

    fn allocator(self: *FreeCountingAllocator) std.mem.Allocator {
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
        return_address: usize,
    ) ?[*]u8 {
        const self: *FreeCountingAllocator = @ptrCast(@alignCast(raw));
        if (self.mutate_handle) |handle|
            handle.lifecycle = .poisoned;
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FreeCountingAllocator = @ptrCast(@alignCast(raw));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FreeCountingAllocator = @ptrCast(@alignCast(raw));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FreeCountingAllocator = @ptrCast(@alignCast(raw));
        self.free_count += 1;
        if (self.mutate_handle) |handle| {
            handle.saved_self_addr = 1;
            handle.lifecycle = .poisoned;
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

const HostileAddressAllocator = struct {
    target: [*]u8,
    free_count: usize = 0,

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
        _: usize,
        _: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.target;
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
        self.free_count += 1;
    }
};

fn testIdentity() external_rx_types.RxIdentity {
    return .{ .attach_instance_id = 9, .destination_slot_addr = 0x9000 };
}

test "d2b3d intent allocation rejects misaligned operation scratch before write or free" {
    var storage_marker: u8 = 0;
    var caller_scratch =
        [_]u8{0x5a} ** (@sizeOf(ExternalRxIntentScratch) + 2);
    const before = caller_scratch;
    var allocator = HostileAddressAllocator{
        .target = @ptrCast(&caller_scratch[1]),
    };
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = allocator.allocator(),
        .operation_scratch_addr = @intFromPtr(&caller_scratch),
        .operation_scratch_len = caller_scratch.len,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.quarantined,
        allocate(&handle, allocator.allocator(), authority.ops()),
    );
    try std.testing.expect(handlePristine(&handle));
    try std.testing.expectEqual(@as(usize, 0), allocator.free_count);
    try std.testing.expectEqualSlices(u8, &before, &caller_scratch);
}

fn makeTestOutcome(
    allocator: std.mem.Allocator,
    identity: external_rx_types.RxIdentity,
    start_absolute: u64,
) !client_external_mode.ExternalRxOutcome {
    return makeTestOutcomeWithHeader(
        allocator,
        identity,
        start_absolute,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
        },
    );
}

fn makeTestOutcomeWithHeader(
    allocator: std.mem.Allocator,
    identity: external_rx_types.RxIdentity,
    start_absolute: u64,
    header: protocol.Header,
) !client_external_mode.ExternalRxOutcome {
    const payload = try allocator.dupe(u8, "x");
    var normalized = header;
    normalized.payload_len = @intCast(payload.len);
    var frame = client_external_mode.ExternalRxFrame{
        .frame = .{
            .header = normalized,
            .payload = payload,
        },
        .range = .{
            .identity = identity,
            .start_absolute = start_absolute,
            .end_absolute = start_absolute + protocol.header_size + payload.len,
        },
        .pair_seal = undefined,
    };
    client_external_mode.testing.sealExternalRxFrame(&frame);
    return .{ .frame = frame };
}

test "d2b3b first copied outcome move wins and abort frees once" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );

    var source = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    var copied = source;
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        source.frame.range.end_absolute;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(
            &handle,
            &source,
            authority.ops(),
            7,
            null,
        ),
    );
    try std.testing.expect(source == .incomplete);
    const partial = switch (partialAfterMove(&handle, 0)) {
        .advanced => |after| after orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), partial.chunk_count);
    const scratch: *ExternalRxIntentScratch = @ptrFromInt(handle.scratch_addr);
    const expected_owner = scratch.intents[0];
    scratch.intents[0].classified.classification
        .screen_candidate.partial_after.?.chunk_count = 2;
    try std.testing.expect(
        partialAfterMove(&handle, 0) == .invalid_state,
    );
    scratch.intents[0] = expected_owner;
    try std.testing.expect(
        partialAfterMove(&handle, 1) == .invalid_state,
    );
    try std.testing.expectEqual(
        MoveResult.replay,
        moveFrame(
            &handle,
            &copied,
            authority.ops(),
            7,
            null,
        ),
    );
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    authority.view.operation_generation = 2;
    try std.testing.expectEqual(
        ResetResult.ready,
        resetForNextTurn(&handle, authority.ops()),
    );
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    const frozen = commitPreparedDestroy(&handle, &prepared);
    authority.view.reservation_handle_addr = 0;
    authority.view.reservation_generation = 0;
    finishFrozenDestroy(frozen);
    try std.testing.expect(handle.lifecycle == .destroyed);
}

test "d2b3b owner preserves every accepted demux candidate without reclassification" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );

    const headers = [_]protocol.Header{
        .{ .kind = .snapshot_chunk, .stream_id = 7 },
        .{ .kind = .event, .stream_id = 7 },
        .{ .kind = .response, .request_id = 9 },
    };
    const expected = [_]std.meta.Tag(external_rx_demux.ExternalWireClass){
        .screen_candidate,
        .event_candidate,
        .response_candidate,
    };
    var next_absolute: u64 = 0;
    for (headers, expected, 0..) |header, expected_tag, index| {
        var source = try makeTestOutcomeWithHeader(
            std.testing.allocator,
            authority.view.identity,
            next_absolute,
            header,
        );
        authority.view.parser_generation += 1;
        authority.view.buffer_start_absolute =
            source.frame.range.end_absolute;
        next_absolute = authority.view.buffer_start_absolute;
        try std.testing.expectEqual(
            MoveResult.classified,
            moveFrame(
                &handle,
                &source,
                authority.ops(),
                7,
                null,
            ),
        );
        try std.testing.expect(source == .incomplete);
        const scratch: *ExternalRxIntentScratch =
            @ptrFromInt(handle.scratch_addr);
        const owner = &scratch.intents[index].classified;
        try std.testing.expectEqual(
            expected_tag,
            std.meta.activeTag(owner.classification),
        );
        try std.testing.expect(std.meta.eql(
            header.kind,
            owner.frame.header.kind,
        ));
    }
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3c mixed event and response intents move into sealed neutral slots once" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );

    const headers = [_]protocol.Header{
        .{ .kind = .event, .stream_id = 7 },
        .{ .kind = .response, .request_id = 91 },
    };
    var next_absolute: u64 = 0;
    for (headers) |header| {
        var source = try makeTestOutcomeWithHeader(
            std.testing.allocator,
            authority.view.identity,
            next_absolute,
            header,
        );
        authority.view.parser_generation += 1;
        authority.view.buffer_start_absolute =
            source.frame.range.end_absolute;
        next_absolute = authority.view.buffer_start_absolute;
        try std.testing.expectEqual(
            MoveResult.classified,
            moveFrame(&handle, &source, authority.ops(), 7, null),
        );
    }

    const CommitAggregate = struct {
        proofs: [max_intents]StagedScreenMutationProof =
            [_]StagedScreenMutationProof{.{}} ** max_intents,
        neutral: [max_intents]MovedIntentPayload =
            [_]MovedIntentPayload{.{}} ** max_intents,
        permit: PreparedIntentCommit = .{},
        event_retirement: PreparedNeutralRetirement = .{},
        event_cleanup: external_owner_cleanup.FrozenOwnerCleanupDescriptor = .{},
    };
    var aggregate: CommitAggregate = .{};
    try prepareIntentCommit(
        &handle,
        @intFromPtr(&aggregate),
        @sizeOf(CommitAggregate),
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
    );
    try std.testing.expect(validatePreparedIntentCommit(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
    ));
    try std.testing.expectEqual(@as(u8, 0), aggregate.permit.proof_count);
    try std.testing.expectEqual(
        IntentCommitSlotKind.event,
        aggregate.permit.slot_kinds[0],
    );
    try std.testing.expectEqual(
        IntentCommitSlotKind.response,
        aggregate.permit.slot_kinds[1],
    );
    try std.testing.expectEqual(
        @as(u64, 91),
        aggregate.permit.response_request_ids[1],
    );
    try std.testing.expectEqual(@as(u64, 0), aggregate.permit.source_start_absolutes[0]);
    try std.testing.expectEqual(
        aggregate.permit.source_end_absolutes[0],
        aggregate.permit.source_start_absolutes[1],
    );
    try std.testing.expect(
        aggregate.permit.source_end_absolutes[1] >
            aggregate.permit.source_start_absolutes[1],
    );
    const saved_response_end = aggregate.permit.source_end_absolutes[1];
    aggregate.permit.source_end_absolutes[1] -= 1;
    try std.testing.expect(!validatePreparedIntentCommit(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
    ));
    aggregate.permit.source_end_absolutes[1] = saved_response_end;
    try std.testing.expect(validatePreparedIntentCommit(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
    ));
    try prepareNeutralRetirement(
        &handle,
        0,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    );
    try std.testing.expect(validatePreparedNeutralRetirement(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    ));
    try std.testing.expect(!neutralRetirementReadyToCommit(
        &handle,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    ));
    try std.testing.expect(
        external_owner_cleanup.isPristine(&aggregate.event_cleanup),
    );

    const scratch_before: *ExternalRxIntentScratch =
        @ptrFromInt(handle.scratch_addr);
    const event_owner = &scratch_before.intents[0].classified;
    const saved_first_byte = event_owner.cleanup_payload.?[0];
    event_owner.cleanup_payload.?[0] ^= 0xff;
    try std.testing.expect(!validatePreparedNeutralRetirement(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    ));
    event_owner.cleanup_payload.?[0] = saved_first_byte;
    try std.testing.expect(validatePreparedNeutralRetirement(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    ));

    consumePreparedIntentCommitUnchecked(
        &handle,
        &aggregate.proofs,
        &aggregate.neutral,
        &aggregate.permit,
    );
    try std.testing.expect(neutralRetirementReadyToCommit(
        &handle,
        &aggregate.neutral,
        &aggregate.permit,
        &aggregate.event_cleanup,
        &aggregate.event_retirement,
    ));
    commitNeutralRetirementUnchecked(
        &aggregate.neutral[0],
        &aggregate.event_retirement,
        &aggregate.event_cleanup,
    );
    try std.testing.expect(validateMovedIntentPayloadTombstone(
        &aggregate.neutral[0],
        @intFromPtr(&aggregate),
    ));
    try std.testing.expectEqual(
        external_owner_cleanup.FinishResult.cleaned,
        external_owner_cleanup.finishCallbackHidden(&aggregate.event_cleanup),
    );
    try std.testing.expectEqual(
        external_owner_cleanup.FinishResult.already_spent,
        external_owner_cleanup.finishCallbackHidden(&aggregate.event_cleanup),
    );

    for (aggregate.neutral[1..2]) |*payload| {
        const borrowed = borrowMovedIntentPayload(
            payload,
            @intFromPtr(&aggregate),
        ) orelse return error.TestUnexpectedResult;
        const allocation = @as(
            [*]u8,
            @ptrFromInt(borrowed.allocation_addr),
        )[0..borrowed.allocation_len];
        var cleanup: external_owner_cleanup.FrozenOwnerCleanupDescriptor = .{};
        try external_owner_cleanup.freezeOwnedSlice(
            &cleanup,
            borrowed.allocator,
            allocation,
        );
        commitMovedIntentPayloadTransferUnchecked(payload);
        try std.testing.expectEqual(
            external_owner_cleanup.FinishResult.cleaned,
            external_owner_cleanup.finishCallbackHidden(&cleanup),
        );
    }

    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b authority and generation drift preserve source before exact move" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 2,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );
    var source = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        source.frame.range.end_absolute;

    var drifted = authority.view;
    drifted.operation_generation += 1;
    authority.call_count = 0;
    authority.next_view = drifted;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);
    drifted = authority.view;
    drifted.storage_addr = @intFromPtr(&handle);
    authority.call_count = 0;
    authority.next_view = null;
    authority.view = drifted;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);

    authority.view.storage_addr = @intFromPtr(&storage_marker);
    authority.call_count = 0;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(
            &handle,
            &source,
            authority.ops(),
            7,
            null,
        ),
    );
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    authority.view.operation_generation = 1;
    try std.testing.expectEqual(
        ResetResult.invalid_state,
        resetForNextTurn(&handle, authority.ops()),
    );
    authority.view.operation_generation = 3;
    try std.testing.expectEqual(
        ResetResult.ready,
        resetForNextTurn(&handle, authority.ops()),
    );
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b second current callback source mutation is rejected before tombstone" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );
    var source = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        source.frame.range.end_absolute;
    authority.mutate_source = &source;
    authority.mutate_source_on_call = authority.call_count + 1;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);

    source.frame.frame.payload[0] ^= 1;
    const original_payload_addr = @intFromPtr(source.frame.frame.payload.ptr);
    const substitute = try std.testing.allocator.dupe(
        u8,
        source.frame.frame.payload,
    );
    defer std.testing.allocator.free(substitute);
    authority.substitute_payload = substitute;
    authority.mutate_source_on_call = authority.call_count + 1;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);
    try std.testing.expectEqual(
        original_payload_addr,
        @intFromPtr(source.frame.frame.payload.ptr),
    );

    authority.mutate_source = null;
    authority.substitute_payload = null;
    authority.mutate_source_on_call = std.math.maxInt(usize);
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b terminal after accepted intent tombstones all owners before cleanup" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );

    var accepted = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        accepted.frame.range.end_absolute;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(&handle, &accepted, authority.ops(), 7, null),
    );
    var terminal = try makeTestOutcomeWithHeader(
        std.testing.allocator,
        authority.view.identity,
        authority.view.buffer_start_absolute,
        .{ .kind = .request, .request_id = 1 },
    );
    authority.view.parser_generation = 3;
    authority.view.buffer_start_absolute =
        terminal.frame.range.end_absolute;
    try std.testing.expectEqual(
        MoveResult.protocol_terminal,
        moveFrame(&handle, &terminal, authority.ops(), 7, null),
    );
    try std.testing.expect(terminal == .incomplete);
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(handle.scratch_addr);
    try std.testing.expectEqual(@as(u8, 0), scratch.intent_count);
    try std.testing.expectEqual(ScratchLifecycle.spent, scratch.lifecycle);
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b zero-length accepted owner aborts without poison" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );
    const payload = try std.testing.allocator.dupe(u8, "");
    var paired = client_external_mode.ExternalRxFrame{
        .frame = .{
            .header = .{
                .kind = .event,
                .stream_id = 7,
                .payload_len = 0,
            },
            .payload = payload,
        },
        .range = .{
            .identity = authority.view.identity,
            .start_absolute = 0,
            .end_absolute = protocol.header_size,
        },
        .pair_seal = undefined,
    };
    client_external_mode.testing.sealExternalRxFrame(&paired);
    var source: client_external_mode.ExternalRxOutcome = .{ .frame = paired };
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute = protocol.header_size;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b hostile allocator cannot place scratch in sealed owner range" {
    var storage_marker: u8 = 0;
    var backing: [
        @sizeOf(ExternalRxIntentScratch) +
            @alignOf(ExternalRxIntentScratch)
    ]u8 align(@alignOf(ExternalRxIntentScratch)) =
        [_]u8{0xa5} ** (@sizeOf(ExternalRxIntentScratch) +
            @alignOf(ExternalRxIntentScratch));
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var counting = FreeCountingAllocator{ .parent = fixed.allocator() };
    const ranges = [_]external_owner_range.Range{.{
        .start = @intFromPtr(&backing),
        .len = backing.len,
    }};
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = counting.allocator(),
        .forbidden_ranges = &ranges,
        .forbidden_ranges_generation = 1,
        .forbidden_ranges_digest = sealAuthorityRanges(&ranges, 1).?,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.quarantined,
        allocate(&handle, counting.allocator(), authority.ops()),
    );
    try std.testing.expect(handlePristine(&handle));
    try std.testing.expectEqual(@as(usize, 0), counting.free_count);
}

test "d2b3d hostile allocator cannot place intent scratch in whole-turn scratch" {
    var storage_marker: u8 = 0;
    var operation_scratch: [
        @sizeOf(ExternalRxIntentScratch) +
            @alignOf(ExternalRxIntentScratch)
    ]u8 align(@alignOf(ExternalRxIntentScratch)) =
        [_]u8{0xa5} ** (@sizeOf(ExternalRxIntentScratch) +
            @alignOf(ExternalRxIntentScratch));
    var fixed = std.heap.FixedBufferAllocator.init(&operation_scratch);
    var counting = FreeCountingAllocator{ .parent = fixed.allocator() };
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = counting.allocator(),
        .operation_scratch_addr = @intFromPtr(&operation_scratch),
        .operation_scratch_len = operation_scratch.len,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.quarantined,
        allocate(&handle, counting.allocator(), authority.ops()),
    );
    try std.testing.expect(handlePristine(&handle));
    // The hostile pointer is caller-owned scratch, so quarantine must never free it.
    try std.testing.expectEqual(@as(usize, 0), counting.free_count);
}

test "d2b3b authority inventory admits the canonical full owner range capacity" {
    const ranges = try std.testing.allocator.alloc(
        external_owner_range.Range,
        max_authority_ranges + 1,
    );
    defer std.testing.allocator.free(ranges);
    for (ranges, 0..) |*range, index| {
        range.* = .{
            .start = 0x1000 + index * 2,
            .len = 1,
        };
    }
    try std.testing.expect(
        sealAuthorityRanges(ranges[0..max_authority_ranges], 1) != null,
    );
    try std.testing.expect(
        sealAuthorityRanges(ranges, 1) == null,
    );
}

test "d2b3b payload cannot alias a sealed parser or live owner range" {
    var storage_marker: u8 = 0;
    const payload = try std.testing.allocator.dupe(u8, "x");
    defer std.testing.allocator.free(payload);
    const ranges = [_]external_owner_range.Range{.{
        .start = @intFromPtr(payload.ptr),
        .len = payload.len,
    }};
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .forbidden_ranges = &ranges,
        .forbidden_ranges_generation = 1,
        .forbidden_ranges_digest = sealAuthorityRanges(&ranges, 1).?,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );
    var paired = client_external_mode.ExternalRxFrame{
        .frame = .{
            .header = .{
                .kind = .snapshot_chunk,
                .stream_id = 7,
                .payload_len = @intCast(payload.len),
            },
            .payload = payload,
        },
        .range = .{
            .identity = authority.view.identity,
            .start_absolute = 0,
            .end_absolute = protocol.header_size + payload.len,
        },
        .pair_seal = undefined,
    };
    client_external_mode.testing.sealExternalRxFrame(&paired);
    var source: client_external_mode.ExternalRxOutcome = .{ .frame = paired };
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute = paired.range.end_absolute;
    try std.testing.expectEqual(
        MoveResult.alias,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b bind move and reset reject a newly conflicting owner inventory" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    const conflicting = [_]external_owner_range.Range{.{
        .start = handle.scratch_addr,
        .len = @sizeOf(ExternalRxIntentScratch),
    }};
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    authority.view.forbidden_ranges = &conflicting;
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&conflicting, 1).?;
    try std.testing.expectEqual(
        BindResult.authority_drift,
        bindReservation(&handle, authority.view),
    );
    authority.view.forbidden_ranges = &.{};
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&.{}, 1).?;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );

    var source = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        source.frame.range.end_absolute;
    authority.view.forbidden_ranges = &conflicting;
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&conflicting, 1).?;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expect(source == .frame);
    authority.view.forbidden_ranges = &.{};
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&.{}, 1).?;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(&handle, &source, authority.ops(), 7, null),
    );
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));

    authority.view.operation_generation = 2;
    authority.view.forbidden_ranges = &conflicting;
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&conflicting, 1).?;
    try std.testing.expectEqual(
        ResetResult.invalid_state,
        resetForNextTurn(&handle, authority.ops()),
    );
    authority.view.forbidden_ranges = &.{};
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&.{}, 1).?;
    try std.testing.expectEqual(
        ResetResult.ready,
        resetForNextTurn(&handle, authority.ops()),
    );
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    finishFrozenDestroy(commitPreparedDestroy(&handle, &prepared));
}

test "d2b3b scratch allocation OOM and disjoint callback drift unwind exactly" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    authority.view.allocator = failing.allocator();
    try std.testing.expectEqual(
        CreateResult.out_of_memory,
        allocate(&handle, failing.allocator(), authority.ops()),
    );
    try std.testing.expect(handlePristine(&handle));

    authority.view.allocator = std.testing.allocator;
    authority.call_count = 0;
    var after = authority.view;
    after.operation_generation += 1;
    authority.next_view = after;
    try std.testing.expectEqual(
        CreateResult.authority_drift,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    try std.testing.expect(handlePristine(&handle));
}

test "d2b3b safe create unwind republishes canonical handle after free callback" {
    var storage_marker: u8 = 0;
    var handle: ExternalRxIntentHandle = .{};
    var counting = FreeCountingAllocator{
        .parent = std.testing.allocator,
        .mutate_handle = &handle,
    };
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = counting.allocator(),
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    try std.testing.expectEqual(
        CreateResult.authority_drift,
        allocate(&handle, counting.allocator(), authority.ops()),
    );
    try std.testing.expectEqual(@as(usize, 1), counting.free_count);
    try std.testing.expect(handlePristine(&handle));
}

test "d2b3b frozen response-style cleanup rejects owner content drift without free" {
    var storage_marker: u8 = 0;
    var authority = TestAuthority{ .view = .{
        .storage_addr = @intFromPtr(&storage_marker),
        .storage_len = 1,
        .operation_generation = 1,
        .parser_generation = 1,
        .buffer_start_absolute = 0,
        .identity = testIdentity(),
        .allocator = std.testing.allocator,
        .reservation_handle_addr = 0,
        .reservation_generation = 0,
    } };
    var handle: ExternalRxIntentHandle = .{};
    try std.testing.expectEqual(
        CreateResult.allocated,
        allocate(&handle, std.testing.allocator, authority.ops()),
    );
    authority.view.reservation_handle_addr = @intFromPtr(&handle);
    authority.view.reservation_generation = 1;
    try std.testing.expectEqual(
        BindResult.bound,
        bindReservation(&handle, authority.view),
    );
    var source = try makeTestOutcome(
        std.testing.allocator,
        authority.view.identity,
        0,
    );
    authority.view.parser_generation = 2;
    authority.view.buffer_start_absolute =
        source.frame.range.end_absolute;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(
            &handle,
            &source,
            authority.ops(),
            7,
            null,
        ),
    );
    const scratch: *ExternalRxIntentScratch = @ptrFromInt(handle.scratch_addr);
    const byte = &scratch.intents[0].classified.frame.payload[0];
    byte.* ^= 1;
    try std.testing.expectEqual(AbortResult.poisoned, abortAll(&handle));
    byte.* ^= 1;
    // The hostile poison policy intentionally leaks this one payload and scratch; recover only in
    // the fixture after proving the product path did not free an untrusted descriptor.
    scratch.lifecycle = .ready;
    scratch.intents[0].classified.payload_digest =
        payloadDigest(scratch.intents[0].classified.frame.payload);
    scratch.intents[0].classified.digest =
        ownerDigest(&scratch.intents[0].classified);
    scratch.digest = scratchDigest(scratch);
    handle.lifecycle = .ready;
    handle.digest = handleDigest(&handle);
    try std.testing.expectEqual(AbortResult.cleaned, abortAll(&handle));
    var prepared: PreparedDestroy = .{};
    try std.testing.expect(prepareDestroy(
        &handle,
        authority.view.storage_addr,
        1,
        &prepared,
    ));
    const frozen = commitPreparedDestroy(&handle, &prepared);
    finishFrozenDestroy(frozen);
}

test "d2b3c intent abort cleanup move rejects count above fixed owner cap" {
    var permit: FrozenIntentAbort = .{
        .cleanup_count = max_intents + 1,
        .lifecycle = .prepared,
    };
    permit.saved_self_addr = @intFromPtr(&permit);
    try std.testing.expect(!validateIntentAbortCleanupMove(&permit, &.{}));
}
