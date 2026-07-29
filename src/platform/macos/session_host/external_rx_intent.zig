//! Address-bound ownership mechanics for classified external RX frames.
//!
//! This module deliberately knows neither `ExternalPumpStorage` nor the inbox ledger. The pump
//! facade owns storage reservation and terminal policy; this leaf owns the one heap allocation,
//! the exact-once frame payload transfer, replay watermarks, and callback-hidden abort cleanup.

const std = @import("std");
const client_external_mode = @import("client_external_mode.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const external_owner_range = @import("external_owner_range.zig");
const external_rx_demux = @import("external_rx_demux.zig");
const external_rx_types = @import("external_rx_types.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");

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

const PreparedRxIntent = union(enum) {
    empty,
    classified: ClassifiedIntentOwner,
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
    const scratch = allocator.create(ExternalRxIntentScratch) catch
        return .out_of_memory;
    const allocation_addr = @intFromPtr(scratch);
    if (scratchRangeAliasesAuthority(allocation_addr, handle, before)) {
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
        allocator.destroy(scratch);
        // The disjoint current inventory proved the allocation can be freed. Publish the caller's
        // canonical failure value only after the free callback, overwriting callback mutation.
        handle.* = .{};
        return .authority_drift;
    }
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
        null,
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
        null,
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

pub fn abortAll(handle: *ExternalRxIntentHandle) AbortResult {
    const scratch = validateHandleAndScratch(handle, .ready, .ready) orelse
        return .poisoned;
    if (scratch.intent_count == 0) {
        scratch.lifecycle = .spent;
        scratch.digest = scratchDigest(scratch);
        return .cleaned;
    }
    var cleanup = [_]FrozenPayloadCleanup{.{}} ** max_intents;
    if (!freezeClassifiedCleanup(scratch, &cleanup))
        return poison(scratch, handle);
    const count = scratch.intent_count;
    for (0..count) |index| scratch.intents[index] = .aborted;
    scratch.intent_count = 0;
    scratch.lifecycle = .spent;
    scratch.digest = scratchDigest(scratch);
    for (cleanup[0..count]) |item| item.allocator.free(item.payload);
    return .cleaned;
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

pub fn prepareDestroy(
    handle: *ExternalRxIntentHandle,
    storage_addr: usize,
    reservation_generation: u64,
    prepared: *PreparedDestroy,
) bool {
    if (prepared.saved_self_addr != 0 or prepared.lifecycle != .empty)
        return false;
    const scratch = validateHandleAnyReadyState(handle) orelse
        return false;
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

pub fn commitPreparedDestroy(
    handle: *ExternalRxIntentHandle,
    prepared: *PreparedDestroy,
) FrozenDestroy {
    std.debug.assert(validatePreparedDestroy(handle, prepared));
    const scratch: *ExternalRxIntentScratch =
        @ptrFromInt(prepared.scratch_addr);
    const cleanup_count = prepared.cleanup_count;
    for (0..cleanup_count) |index| scratch.intents[index] = .aborted;
    scratch.intent_count = 0;
    scratch.lifecycle = .destroying;
    scratch.digest = scratchDigest(scratch);
    handle.lifecycle = .destroying;
    handle.digest = handleDigest(handle);
    const frozen = FrozenDestroy{
        .scratch = scratch,
        .handle = handle,
        .allocator = prepared.allocator,
        .cleanup = prepared.cleanup,
        .cleanup_count = cleanup_count,
        .storage_addr = prepared.storage_addr,
        .reservation_generation = prepared.reservation_generation,
    };
    prepared.lifecycle = .consumed;
    return frozen;
}

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
    var writer = external_owner_seal.Writer.init("MARUXPD1");
    writer.writeBytes(bytes);
    return writer.finish();
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
        .committed => writer.writeU8(2),
        .aborted => writer.writeU8(3),
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

fn testIdentity() external_rx_types.RxIdentity {
    return .{ .attach_instance_id = 9, .destination_slot_addr = 0x9000 };
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
        ),
    );
    try std.testing.expect(source == .incomplete);
    try std.testing.expectEqual(
        MoveResult.replay,
        moveFrame(
            &handle,
            &copied,
            authority.ops(),
            7,
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
        moveFrame(&handle, &source, authority.ops(), 7),
    );
    try std.testing.expect(source == .frame);
    drifted = authority.view;
    drifted.storage_addr = @intFromPtr(&handle);
    authority.call_count = 0;
    authority.next_view = null;
    authority.view = drifted;
    try std.testing.expectEqual(
        MoveResult.authority_drift,
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &accepted, authority.ops(), 7),
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
        moveFrame(&handle, &terminal, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
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
        moveFrame(&handle, &source, authority.ops(), 7),
    );
    try std.testing.expect(source == .frame);
    authority.view.forbidden_ranges = &.{};
    authority.view.forbidden_ranges_digest =
        sealAuthorityRanges(&.{}, 1).?;
    try std.testing.expectEqual(
        MoveResult.classified,
        moveFrame(&handle, &source, authority.ops(), 7),
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
