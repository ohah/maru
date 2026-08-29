//! Prepared, mutation-free Client screen adoption.
//!
//! This layer knows the Client inventory and the neutral inbox ledger, but not the pump storage
//! lifecycle. The c2 pump storage embeds this plan at its final address; c3 consumes it without
//! moving or reconstructing its ownership records.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const external_adoption_limits = @import("external_adoption_limits.zig");
const ledger_mod = @import("external_inbox_ledger.zig");
const owner_range = @import("external_owner_range.zig");
const owner_seal = @import("external_owner_seal.zig");
const framing = @import("framing.zig");
const frozen_cleanup_guard = @import("frozen_cleanup_guard.zig");
const protocol = @import("protocol.zig");
const request_id_state = @import("request_id_state.zig");

pub const max_adoption_metadata_bytes: usize =
    external_adoption_limits.max_metadata_bytes;

pub const Lifecycle = enum { empty, prepared, committed, aborted };

pub const PreparedTransfer = struct {
    copies: []client_mod.ExternalScreenCopy = &.{},
    wrappers: []ledger_mod.OwnedPayload = &.{},
    tokens: []ledger_mod.Token = &.{},
    copies_addr: usize = 0,
    copies_len: usize = 0,
    wrappers_addr: usize = 0,
    wrappers_len: usize = 0,
    tokens_addr: usize = 0,
    tokens_len: usize = 0,
    cleanup_copies: []client_mod.ExternalScreenCopy = &.{},
    cleanup_wrappers: []ledger_mod.OwnedPayload = &.{},
    cleanup_tokens: []ledger_mod.Token = &.{},
    cleanup_transferred_count: usize = 0,
};

const AggregateCleanupLifecycle = enum {
    empty,
    prepared,
    consumed,
};

/// Callback-free, fixed-capacity snapshot of every descriptor later used by aggregate screen
/// cleanup. Preparing this value is the last point at which cleanup may inspect shared heap
/// descriptor elements; finishing it uses only these stack-owned headers.
pub const PreparedAggregateScreenCleanup = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    copies: []client_mod.ExternalScreenCopy = &.{},
    wrappers: []ledger_mod.OwnedPayload = &.{},
    tokens: []ledger_mod.Token = &.{},
    payloads: [ledger_mod.max_items][]u8 = [_][]u8{&.{}} ** ledger_mod.max_items,
    payload_count: usize = 0,
    has_transfer: bool = false,
    committed_cleanup: bool = false,
    lifecycle: AggregateCleanupLifecycle = .empty,

    fn isEmpty(self: *const PreparedAggregateScreenCleanup) bool {
        return self.lifecycle == .empty;
    }
};

fn preparedTransfersEqual(a: PreparedTransfer, b: PreparedTransfer) bool {
    return std.meta.eql(a, b);
}

const CommittedTakeLifecycle = enum {
    empty,
    prepared,
    committed_tombstone,
    aborted_tombstone,
};

const CommittedScreenLifecycle = enum {
    empty,
    committed,
    cleaned_tombstone,
};

const ScreenBackingAuthority = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    transfer: PreparedTransfer = .{},
};

const ScreenCleanupAuthority = struct {
    allocator: std.mem.Allocator,
    transfer: PreparedTransfer,
};

const ScreenBackingSeal = struct {
    authority_addr: usize,
    storage_addr: usize,
    allocator_ptr_addr: usize,
    allocator_vtable_addr: usize,
    copies_addr: usize,
    copies_len: usize,
    cleanup_copies_addr: usize,
    cleanup_copies_len: usize,
    wrappers_addr: usize,
    wrappers_len: usize,
    cleanup_wrappers_addr: usize,
    cleanup_wrappers_len: usize,
    tokens_addr: usize,
    tokens_len: usize,
    cleanup_tokens_addr: usize,
    cleanup_tokens_len: usize,
    digest: owner_seal.Digest,
};

const ScreenCanonicalAuthority = struct {
    owner_addr: usize = 0,
    storage_addr: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    copies_addr: usize = 0,
    copies_len: usize = 0,
    cleanup_copies_addr: usize = 0,
    cleanup_copies_len: usize = 0,
    wrappers_addr: usize = 0,
    wrappers_len: usize = 0,
    cleanup_wrappers_addr: usize = 0,
    cleanup_wrappers_len: usize = 0,
    tokens_addr: usize = 0,
    tokens_len: usize = 0,
    cleanup_tokens_addr: usize = 0,
    cleanup_tokens_len: usize = 0,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

const LedgerFinishedPermit = struct {
    ledger_addr: usize,
};

/// Address-bound permission to retag one committed seed plan into its persistent destination.
/// Preparation is fallible and runs before the ledger barrier; `commitIntoUnchecked` only moves
/// already-sealed headers after `commitSeeds` succeeds.
pub const PreparedCommittedScreenTake = struct {
    saved_self_addr: usize = 0,
    source_addr: usize = 0,
    destination_addr: usize = 0,
    client_addr: usize = 0,
    ledger_addr: usize = 0,
    storage_addr: usize = 0,
    target_stream: u64 = 0,
    tokens_addr: usize = 0,
    tokens_len: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    commit_transfer: PreparedTransfer = .{},
    lifecycle: CommittedTakeLifecycle = .empty,

    pub fn isEmpty(self: *const PreparedCommittedScreenTake) bool {
        return self.lifecycle == .empty;
    }

    pub fn validate(
        self: *const PreparedCommittedScreenTake,
        source: *const PreparedScreenBacklog,
        destination: *const CommittedScreenBacklog,
        client: *const client_mod.Client,
        ledger: *const ledger_mod.ExternalInboxLedger,
        stable_parent: *const anyopaque,
    ) bool {
        const self_addr = @intFromPtr(self);
        const destination_addr = @intFromPtr(destination);
        if (rangesOverlap(
            self_addr,
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(source),
            @sizeOf(PreparedScreenBacklog),
        ) or rangesOverlap(
            self_addr,
            @sizeOf(PreparedCommittedScreenTake),
            destination_addr,
            @sizeOf(CommittedScreenBacklog),
        ) or rangesOverlap(
            self_addr,
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(client),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            self_addr,
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(ledger),
            @sizeOf(ledger_mod.ExternalInboxLedger),
        ) or rangesOverlap(
            destination_addr,
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(source),
            @sizeOf(PreparedScreenBacklog),
        ) or rangesOverlap(
            destination_addr,
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(client),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            destination_addr,
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(ledger),
            @sizeOf(ledger_mod.ExternalInboxLedger),
        ) or rangeOverlapsPreparedBacking(
            self_addr,
            @sizeOf(PreparedCommittedScreenTake),
            source,
        ) or rangeOverlapsPreparedBacking(
            destination_addr,
            @sizeOf(CommittedScreenBacklog),
            source,
        ))
            return false;
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_addr != @intFromPtr(source) or
            self.destination_addr != @intFromPtr(destination) or
            self.client_addr != @intFromPtr(client) or
            self.ledger_addr != @intFromPtr(ledger) or
            self.storage_addr != @intFromPtr(stable_parent) or
            !destination.isEmpty() or
            !source.validate(client, ledger) or
            source.targetStream() != self.target_stream)
            return false;
        const transfer = source.transfer orelse return false;
        return self.tokens_addr == sliceAddress(ledger_mod.Token, transfer.tokens) and
            self.tokens_len == transfer.tokens.len and
            std.meta.eql(self.allocator, source.allocator) and
            preparedTransfersEqual(self.commit_transfer, transfer);
    }

    /// Proves only the outer allocation descriptors captured by the independent take.
    ///
    /// This check intentionally does not iterate `transfer.copies`: the caller uses it as the
    /// memory-safety gate before any aggregate cross-owner proof may dereference that slice.
    /// Full semantic validation still happens later when minting the commit permit.
    pub fn validateOuterTransferDescriptors(
        self: *const PreparedCommittedScreenTake,
        source: *const PreparedScreenBacklog,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_addr != @intFromPtr(source) or
            source.lifecycle != .prepared or
            source.saved_self_address != @intFromPtr(source) or
            !std.meta.eql(self.allocator, source.allocator) or
            !std.meta.eql(self.allocator, source.cleanup_allocator) or
            source.allocator_ptr_addr != @intFromPtr(self.allocator.ptr) or
            source.allocator_vtable_addr != @intFromPtr(self.allocator.vtable))
            return false;
        const transfer = source.transfer orelse return false;
        const cleanup_transfer = source.cleanup_transfer orelse return false;
        if (!preparedTransfersEqual(self.commit_transfer, transfer) or
            !preparedTransfersEqual(self.commit_transfer, cleanup_transfer) or
            transfer.copies.len > ledger_mod.max_items or
            transfer.wrappers.len != transfer.copies.len or
            transfer.tokens.len != transfer.copies.len or
            transfer.copies_addr !=
                sliceAddress(client_mod.ExternalScreenCopy, transfer.copies) or
            transfer.copies_len != transfer.copies.len or
            transfer.wrappers_addr !=
                sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers) or
            transfer.wrappers_len != transfer.wrappers.len or
            transfer.tokens_addr != sliceAddress(ledger_mod.Token, transfer.tokens) or
            transfer.tokens_len != transfer.tokens.len or
            !sameSlice(
                client_mod.ExternalScreenCopy,
                transfer.copies,
                transfer.cleanup_copies,
            ) or
            !sameSlice(
                ledger_mod.OwnedPayload,
                transfer.wrappers,
                transfer.cleanup_wrappers,
            ) or
            !sameSlice(
                ledger_mod.Token,
                transfer.tokens,
                transfer.cleanup_tokens,
            ) or
            transfer.cleanup_transferred_count != transfer.copies.len)
            return false;
        const copies_bytes = std.math.mul(
            usize,
            transfer.copies.len,
            @sizeOf(client_mod.ExternalScreenCopy),
        ) catch return false;
        const wrappers_bytes = std.math.mul(
            usize,
            transfer.wrappers.len,
            @sizeOf(ledger_mod.OwnedPayload),
        ) catch return false;
        const tokens_bytes = std.math.mul(
            usize,
            transfer.tokens.len,
            @sizeOf(ledger_mod.Token),
        ) catch return false;
        return !rangesOverlap(
            transfer.copies_addr,
            copies_bytes,
            transfer.wrappers_addr,
            wrappers_bytes,
        ) and !rangesOverlap(
            transfer.copies_addr,
            copies_bytes,
            transfer.tokens_addr,
            tokens_bytes,
        ) and !rangesOverlap(
            transfer.wrappers_addr,
            wrappers_bytes,
            transfer.tokens_addr,
            tokens_bytes,
        );
    }

    /// Returns the third, independently captured cleanup authority without inspecting any nested
    /// screen element. Aggregate teardown uses this copy to avoid treating two fields inside one
    /// corrupted transfer as independent votes.
    fn cleanupAuthority(
        self: *const PreparedCommittedScreenTake,
        source: *const PreparedScreenBacklog,
    ) ?ScreenCleanupAuthority {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_addr != @intFromPtr(source))
            return null;
        return .{
            .allocator = self.allocator,
            .transfer = self.commit_transfer,
        };
    }

    pub fn abort(self: *PreparedCommittedScreenTake) void {
        if (self.saved_self_addr != 0 and
            self.saved_self_addr != @intFromPtr(self))
            return;
        self.* = .{ .lifecycle = .aborted_tombstone };
    }

    pub fn lifecycleCode(self: *const PreparedCommittedScreenTake) u8 {
        return @intFromEnum(self.lifecycle);
    }
};

const PreparedCommittedScreenCleanupLifecycle = enum {
    empty,
    prepared,
    consumed,
};

const ScreenCleanupSelection = enum {
    primary,
    cleanup,
};

pub const PreparedCommittedScreenCleanup = struct {
    saved_self_addr: usize = 0,
    owner_addr: usize = 0,
    storage_addr: usize = 0,
    frozen_out_addr: usize = 0,
    selection: ScreenCleanupSelection = .cleanup,
    lifecycle: PreparedCommittedScreenCleanupLifecycle = .empty,
};

const FrozenCommittedScreenCleanupLifecycle = enum {
    empty,
    frozen,
    cleaned_tombstone,
};

pub const FrozenCleanupFinishResult = enum {
    cleaned,
    already_cleaned,
    invalid,
};

pub const FrozenCommittedScreenCleanup = struct {
    saved_self_addr: usize = 0,
    authority: ScreenBackingAuthority = .{},
    lifecycle: FrozenCommittedScreenCleanupLifecycle = .empty,
};

/// Persistent owner of the exact token/backing headers produced by `PreparedScreenBacklog`.
/// Ledger lease release is deliberately deferred to c3c-3; this b1 type only proves the
/// final-address take and exact post-ledger backing cleanup.
pub const CommittedScreenBacklog = struct {
    saved_self_addr: usize = 0,
    source_addr: usize = 0,
    ledger_addr: usize = 0,
    storage_addr: usize = 0,
    target_stream: u64 = 0,
    tokens_addr: usize = 0,
    tokens_len: usize = 0,
    retained_count: usize = 0,
    released: std.StaticBitSet(ledger_mod.max_items) =
        std.StaticBitSet(ledger_mod.max_items).initEmpty(),
    primary: ScreenBackingAuthority = .{},
    cleanup: ScreenBackingAuthority = .{},
    primary_seal: ?ScreenBackingSeal = null,
    cleanup_seal: ?ScreenBackingSeal = null,
    canonical: ScreenCanonicalAuthority = .{},
    lifecycle: CommittedScreenLifecycle = .empty,

    pub fn isEmpty(self: *const CommittedScreenBacklog) bool {
        return std.meta.eql(self.*, CommittedScreenBacklog{});
    }

    /// Generic storage teardown must not interpret or skip a corrupted committed owner.
    /// The typed cleanup path owns validation/fallback and is the only transition out of this tag.
    pub fn requiresTypedCleanup(self: *const CommittedScreenBacklog) bool {
        return !self.isEmpty() and
            !std.meta.eql(
                self.*,
                CommittedScreenBacklog{ .lifecycle = .cleaned_tombstone },
            );
    }

    pub fn isCommitted(
        self: *const CommittedScreenBacklog,
        stable_parent: *const anyopaque,
    ) bool {
        if (self.lifecycle != .committed) return false;
        const transfer = self.primary.transfer;
        return self.saved_self_addr == @intFromPtr(self) and
            self.ledger_addr != 0 and self.target_stream != 0 and
            self.storage_addr == @intFromPtr(stable_parent) and
            self.tokens_addr == sliceAddress(ledger_mod.Token, transfer.tokens) and
            self.tokens_len == transfer.tokens.len and
            self.retained_count + self.released.count() == self.tokens_len and
            self.retained_count <= ledger_mod.max_items and
            self.tokens_len <= ledger_mod.max_items and
            screenCanonicalAuthorityValid(self, &self.canonical) and
            screenBackingSealMatches(
                self.primary_seal orelse return false,
                &self.primary,
                self.storage_addr,
            ) and screenBackingMatchesCanonical(
            &self.primary,
            &self.canonical,
        ) and
            screenBackingSealMatches(
                self.cleanup_seal orelse return false,
                &self.cleanup,
                self.storage_addr,
            ) and screenBackingMatchesCanonical(
            &self.cleanup,
            &self.canonical,
        );
    }

    /// O(1) descriptor-only pending authority for the pump scheduler. This validates fixed owner
    /// headers and slice descriptors but never reads token/copy/wrapper elements or payload bytes.
    pub fn pendingCountSummary(
        self: *const CommittedScreenBacklog,
        stable_parent: *const anyopaque,
    ) ?usize {
        if (!self.isCommitted(stable_parent)) return null;
        return self.retained_count;
    }

    /// Reject caller scratch that aliases any container allocation owned by this committed graph.
    pub fn overlapsOwnedBacking(
        self: *const CommittedScreenBacklog,
        address: usize,
        len: usize,
    ) bool {
        return rangeOverlapsScreenBacking(address, len, &self.primary) or
            rangeOverlapsScreenBacking(address, len, &self.cleanup);
    }

    /// Deep, process-local snapshot of every backing descriptor element that typed teardown may
    /// consume. Payload bytes remain ledger-owned and are deliberately represented by address and
    /// length only; projection must detect authority drift without reading terminal output again.
    pub fn projectionAuthorityDigest(
        self: *const CommittedScreenBacklog,
        stable_parent: *const anyopaque,
    ) ?owner_seal.Digest {
        if (!self.isCommitted(stable_parent)) return null;
        var writer = owner_seal.Writer.init("maru.screen-owner.projection.v1");
        writer.writeUsize(self.saved_self_addr);
        writer.writeUsize(self.source_addr);
        writer.writeUsize(self.ledger_addr);
        writer.writeUsize(self.storage_addr);
        writer.writeU64(self.target_stream);
        writer.writeUsize(self.tokens_addr);
        writer.writeUsize(self.tokens_len);
        writer.writeUsize(self.retained_count);
        for (self.released.masks) |mask| writer.writeUsize(mask);
        writeProjectionTransfer(&writer, self.primary.transfer);
        writeProjectionTransfer(&writer, self.cleanup.transfer);
        return writer.finish();
    }

    pub fn prepareFrozenCleanup(
        self: *const CommittedScreenBacklog,
        stable_parent: *const anyopaque,
        out_plan: *ledger_mod.FrozenScreenTokenPlan,
        out: *PreparedCommittedScreenCleanup,
        frozen_out: *const FrozenCommittedScreenCleanup,
    ) bool {
        const owner_addr = @intFromPtr(self);
        const plan_addr = @intFromPtr(out_plan);
        const out_addr = @intFromPtr(out);
        const frozen_addr = @intFromPtr(frozen_out);
        inline for (.{ plan_addr, out_addr, frozen_addr }) |destination|
            if (rangesOverlap(
                owner_addr,
                @sizeOf(CommittedScreenBacklog),
                destination,
                if (destination == plan_addr)
                    @sizeOf(ledger_mod.FrozenScreenTokenPlan)
                else if (destination == out_addr)
                    @sizeOf(PreparedCommittedScreenCleanup)
                else
                    @sizeOf(FrozenCommittedScreenCleanup),
            )) return false;
        if (rangesOverlap(plan_addr, @sizeOf(ledger_mod.FrozenScreenTokenPlan), out_addr, @sizeOf(PreparedCommittedScreenCleanup)) or
            rangesOverlap(plan_addr, @sizeOf(ledger_mod.FrozenScreenTokenPlan), frozen_addr, @sizeOf(FrozenCommittedScreenCleanup)) or
            rangesOverlap(out_addr, @sizeOf(PreparedCommittedScreenCleanup), frozen_addr, @sizeOf(FrozenCommittedScreenCleanup)))
            return false;
        if (self.lifecycle != .committed or
            self.saved_self_addr != owner_addr or
            self.storage_addr != @intFromPtr(stable_parent) or
            out_plan.saved_self_addr != 0 or out_plan.len != 0 or
            out.saved_self_addr != 0 or out.lifecycle != .empty or
            frozen_out.saved_self_addr != 0 or frozen_out.lifecycle != .empty)
            return false;
        const canonical_valid =
            screenCanonicalAuthorityValid(self, &self.canonical);
        const cleanup_valid = canonical_valid and if (self.cleanup_seal) |seal|
            screenBackingSealMatches(seal, &self.cleanup, self.storage_addr) and
                screenBackingMatchesCanonical(&self.cleanup, &self.canonical)
        else
            false;
        const primary_valid = canonical_valid and if (self.primary_seal) |seal|
            screenBackingSealMatches(seal, &self.primary, self.storage_addr) and
                screenBackingMatchesCanonical(&self.primary, &self.canonical)
        else
            false;
        if (!cleanup_valid and !primary_valid) return false;
        const selection: ScreenCleanupSelection = if (cleanup_valid)
            .cleanup
        else
            .primary;
        const selected = if (selection == .cleanup)
            &self.cleanup
        else
            &self.primary;
        if (rangeOverlapsScreenBacking(
            plan_addr,
            @sizeOf(ledger_mod.FrozenScreenTokenPlan),
            selected,
        ) or rangeOverlapsScreenBacking(
            out_addr,
            @sizeOf(PreparedCommittedScreenCleanup),
            selected,
        ) or rangeOverlapsScreenBacking(
            frozen_addr,
            @sizeOf(FrozenCommittedScreenCleanup),
            selected,
        )) return false;

        out_plan.initInPlace(
            selected.transfer.tokens,
            self.released,
        ) catch return false;
        out.* = .{
            .saved_self_addr = out_addr,
            .owner_addr = owner_addr,
            .storage_addr = self.storage_addr,
            .frozen_out_addr = frozen_addr,
            .selection = selection,
            .lifecycle = .prepared,
        };
        return true;
    }

    pub fn commitFrozenCleanupUnchecked(
        self: *CommittedScreenBacklog,
        prepared: *PreparedCommittedScreenCleanup,
        out: *FrozenCommittedScreenCleanup,
    ) void {
        std.debug.assert(prepared.saved_self_addr == @intFromPtr(prepared));
        std.debug.assert(prepared.owner_addr == @intFromPtr(self));
        std.debug.assert(prepared.storage_addr == self.storage_addr);
        std.debug.assert(prepared.frozen_out_addr == @intFromPtr(out));
        std.debug.assert(prepared.lifecycle == .prepared);
        std.debug.assert(out.saved_self_addr == 0 and out.lifecycle == .empty);
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .authority = if (prepared.selection == .cleanup)
                self.cleanup
            else
                self.primary,
            .lifecycle = .frozen,
        };
        self.* = .{ .lifecycle = .cleaned_tombstone };
        prepared.lifecycle = .consumed;
    }

    pub fn appendPreparedFrozenCleanupRanges(
        self: *const CommittedScreenBacklog,
        prepared: *const PreparedCommittedScreenCleanup,
        out: *owner_range.Scratch,
    ) owner_range.Error!void {
        if (prepared.saved_self_addr != @intFromPtr(prepared) or
            prepared.owner_addr != @intFromPtr(self) or
            prepared.storage_addr != self.storage_addr or
            prepared.lifecycle != .prepared)
            return error.InvalidRange;
        const authority = if (prepared.selection == .cleanup)
            &self.cleanup
        else
            &self.primary;
        const transfer = authority.transfer;
        inline for (.{
            .{ @sizeOf(client_mod.ExternalScreenCopy), transfer.copies.ptr, transfer.copies.len },
            .{ @sizeOf(ledger_mod.OwnedPayload), transfer.wrappers.ptr, transfer.wrappers.len },
            .{ @sizeOf(ledger_mod.Token), transfer.tokens.ptr, transfer.tokens.len },
        }) |entry| {
            const bytes = std.math.mul(usize, entry[0], entry[2]) catch
                return error.ArithmeticOverflow;
            try out.append(if (entry[2] == 0) 0 else @intFromPtr(entry[1]), bytes);
        }
    }

    /// Private b1 cleanup seam. The permit can only be minted by this file's fixture after it has
    /// drained and finished the ledger; c3c-3 replaces it with the aggregate teardown permit.
    fn deinitAfterLedgerFinished(
        self: *CommittedScreenBacklog,
        permit: LedgerFinishedPermit,
    ) void {
        if (self.lifecycle == .empty or self.lifecycle == .cleaned_tombstone) return;
        if (self.saved_self_addr != @intFromPtr(self)) return;
        if (permit.ledger_addr != self.ledger_addr) return;
        const stable_parent: *const anyopaque = @ptrFromInt(self.storage_addr);
        var plan: ledger_mod.FrozenScreenTokenPlan = .{};
        var prepared: PreparedCommittedScreenCleanup = .{};
        var frozen: FrozenCommittedScreenCleanup = .{};
        if (!self.prepareFrozenCleanup(
            stable_parent,
            &plan,
            &prepared,
            &frozen,
        )) {
            self.* = .{ .lifecycle = .cleaned_tombstone };
            return;
        }
        self.commitFrozenCleanupUnchecked(&prepared, &frozen);
        _ = finishFrozenCleanup(&frozen);
    }
};

fn writeProjectionTransfer(
    writer: *owner_seal.Writer,
    transfer: PreparedTransfer,
) void {
    inline for (.{ transfer.copies, transfer.cleanup_copies }) |copies| {
        writer.writeUsize(sliceAddress(client_mod.ExternalScreenCopy, copies));
        writer.writeUsize(copies.len);
        for (copies) |copy| {
            writer.writeUsize(@intFromPtr(copy.allocator.ptr));
            writer.writeUsize(@intFromPtr(copy.allocator.vtable));
            writer.writeU8(@intFromEnum(copy.semantic));
            switch (copy.semantic) {
                .completed => |value| {
                    writer.writeU64(value.stream_id);
                    writer.writeBool(value.is_snapshot);
                },
                .partial => |value| {
                    writer.writeU64(value.stream_id);
                    writer.writeBool(value.is_snapshot);
                    writer.writeU8(value.chunk_count);
                },
                .frame => |header| writer.writeBytes(&header.encode()),
            }
            writer.writeUsize(if (copy.bytes.len == 0) 0 else @intFromPtr(copy.bytes.ptr));
            writer.writeUsize(copy.bytes.len);
            writer.writeUsize(if (copy.view.len == 0) 0 else @intFromPtr(copy.view.ptr));
            writer.writeUsize(copy.view.len);
        }
    }
    inline for (.{ transfer.wrappers, transfer.cleanup_wrappers }) |wrappers| {
        writer.writeUsize(sliceAddress(ledger_mod.OwnedPayload, wrappers));
        writer.writeUsize(wrappers.len);
        for (wrappers) |wrapper| {
            writer.writeUsize(@intFromPtr(wrapper.allocator.ptr));
            writer.writeUsize(@intFromPtr(wrapper.allocator.vtable));
            writer.writeUsize(if (wrapper.allocation_ptr) |ptr| @intFromPtr(ptr) else 0);
            writer.writeUsize(wrapper.logical_len);
        }
    }
    inline for (.{ transfer.tokens, transfer.cleanup_tokens }) |tokens| {
        writer.writeUsize(sliceAddress(ledger_mod.Token, tokens));
        writer.writeUsize(tokens.len);
        for (tokens) |token| {
            writer.writeU16(token.slot);
            writer.writeU64(token.generation);
        }
    }
}

pub fn finishFrozenCleanup(
    frozen: *FrozenCommittedScreenCleanup,
) FrozenCleanupFinishResult {
    const address = @intFromPtr(frozen);
    if (frozen.lifecycle == .cleaned_tombstone) return .already_cleaned;
    if (frozen.saved_self_addr != address or frozen.lifecycle != .frozen)
        return .invalid;
    if (!frozen_cleanup_guard.enter()) return .invalid;
    defer frozen_cleanup_guard.leave();
    defer frozen.* = .{ .lifecycle = .cleaned_tombstone };
    var local = frozen.*;
    frozen.* = .{ .lifecycle = .cleaned_tombstone };
    deinitScreenBackingAuthority(&local.authority);
    return .cleaned;
}

pub const PrepareError = client_mod.ExternalAdoptionInspectError ||
    client_mod.ExternalAdoptionPreflightError || ledger_mod.PlanError || error{
    MetadataTooLarge,
    InvalidAddress,
};

pub const MetadataPreflight = struct {
    pointer_bits: u16,
    preview: client_mod.ExternalAdoptionPreview,
    over_screen_cap: bool,
    footprint: MetadataFootprint,
};

pub fn preflightMetadata(
    client: *const client_mod.Client,
    target_stream: u64,
) PrepareError!MetadataPreflight {
    const preview = try client.previewExternalAdoption(target_stream);
    const client_metadata = std.math.mul(
        usize,
        preview.inventory_metadata_bytes,
        2,
    ) catch return error.MetadataTooLarge;
    const over_cap = preview.screen_source_count > ledger_mod.max_items or
        preview.screen_payload_bytes > ledger_mod.max_bytes;
    return .{
        .pointer_bits = @bitSizeOf(usize),
        .preview = preview,
        .over_screen_cap = over_cap,
        .footprint = try metadataFootprint(
            if (over_cap) 0 else preview.screen_source_count,
            client_metadata,
            preview.inventory_metadata_bytes,
            preview.validation_scratch_peak_bytes,
        ),
    };
}

pub const PreparedScreenBacklog = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    cleanup_allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    saved_self_address: usize = 0,
    client_address: usize = 0,
    ledger_address: usize = 0,
    pointer_bits: u16 = 0,
    lifecycle: Lifecycle = .empty,
    inventory: ?client_mod.ExternalAdoptionInventory = null,
    cleanup_inventory: ?client_mod.ExternalAdoptionInventory = null,
    client_disarm: client_mod.PreparedClientDisarm = .{},
    transfer: ?PreparedTransfer = null,
    cleanup_transfer: ?PreparedTransfer = null,
    seed_plan: ledger_mod.PreparedSeedPlan = .{},
    request_ids: request_id_state.State = .{ .available = 1 },
    adoption_metadata_resident_bytes: usize = 0,
    adoption_metadata_prepare_peak_bytes: usize = 0,

    pub fn initInPlace(
        out: *PreparedScreenBacklog,
        allocator: std.mem.Allocator,
        client: *const client_mod.Client,
        ledger: *ledger_mod.ExternalInboxLedger,
        target_stream: u64,
    ) PrepareError!void {
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedScreenBacklog),
            @intFromPtr(client),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedScreenBacklog),
            @intFromPtr(ledger),
            @sizeOf(ledger_mod.ExternalInboxLedger),
        )) return error.InvalidAddress;
        if (!std.meta.eql(allocator, client.allocator)) return error.InvalidAllocator;
        const metadata_preflight = try preflightMetadata(client, target_stream);
        const preview = metadata_preflight.preview;
        const predicted_client_metadata = std.math.mul(
            usize,
            preview.inventory_metadata_bytes,
            2,
        ) catch return error.MetadataTooLarge;
        const over_cap = metadata_preflight.over_screen_cap;
        try client.preflightExternalAdoptionDestination(
            out,
            @sizeOf(PreparedScreenBacklog),
        );
        if (out.lifecycle != .empty) return error.InvalidAddress;

        out.* = .{
            .allocator = allocator,
            .cleanup_allocator = allocator,
            .allocator_ptr_addr = @intFromPtr(allocator.ptr),
            .allocator_vtable_addr = @intFromPtr(allocator.vtable),
            .saved_self_address = @intFromPtr(out),
            .client_address = @intFromPtr(client),
            .ledger_address = @intFromPtr(ledger),
            .pointer_bits = metadata_preflight.pointer_bits,
            .lifecycle = .empty,
        };
        errdefer {
            out.deinit();
            out.* = .{};
        }

        out.inventory = try client.inspectExternalAdoption(target_stream);
        out.cleanup_inventory = out.inventory;
        const inventory = &out.inventory.?;
        out.request_ids = request_id_state.State.fromNext(inventory.next_request_id) catch
            return error.InvalidClientState;
        try client.preflightExternalAdoption(inventory, &out.client_disarm);
        const inventory_metadata = inventory.metadataBytes() catch
            return error.MetadataTooLarge;
        const disarm_metadata = client.externalAdoptionDisarmMetadataBytes(
            &out.client_disarm,
        ) catch return error.MetadataTooLarge;
        const client_metadata = std.math.add(
            usize,
            inventory_metadata,
            disarm_metadata,
        ) catch return error.MetadataTooLarge;
        const scratch_peak = inventory.validation_scratch_peak_bytes;
        if (client_metadata != predicted_client_metadata or
            scratch_peak != preview.validation_scratch_peak_bytes or
            inventory.screen_source_count != preview.screen_source_count or
            inventory.screen_payload_bytes != preview.screen_payload_bytes)
            return error.StaleInventory;
        out.adoption_metadata_resident_bytes = metadata_preflight.footprint.resident;
        out.adoption_metadata_prepare_peak_bytes = metadata_preflight.footprint.prepare_peak;
        if (over_cap) {
            out.lifecycle = .prepared;
            return;
        }

        out.transfer = .{};
        const transfer = &out.transfer.?;
        transfer.copies = try allocator.alloc(
            client_mod.ExternalScreenCopy,
            inventory.screen_source_count,
        );
        transfer.copies_addr = sliceAddress(client_mod.ExternalScreenCopy, transfer.copies);
        transfer.copies_len = transfer.copies.len;
        transfer.cleanup_copies = transfer.copies;
        client.stageExternalScreenCopies(allocator, inventory, transfer.copies) catch |err| {
            allocator.free(transfer.copies);
            transfer.copies = &.{};
            transfer.cleanup_copies = &.{};
            return err;
        };

        transfer.wrappers = try allocator.alloc(
            ledger_mod.OwnedPayload,
            inventory.screen_source_count,
        );
        transfer.wrappers_addr = sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers);
        transfer.wrappers_len = transfer.wrappers.len;
        transfer.cleanup_wrappers = transfer.wrappers;
        for (transfer.wrappers) |*wrapper|
            wrapper.* = ledger_mod.OwnedPayload.empty(allocator);
        const specs = try allocator.alloc(
            ledger_mod.SeedSpec,
            inventory.screen_source_count,
        );
        defer allocator.free(specs);
        transfer.tokens = try allocator.alloc(
            ledger_mod.Token,
            inventory.screen_source_count,
        );
        transfer.tokens_addr = sliceAddress(ledger_mod.Token, transfer.tokens);
        transfer.tokens_len = transfer.tokens.len;
        transfer.cleanup_tokens = transfer.tokens;

        for (transfer.copies, transfer.wrappers, specs) |*copy, *wrapper, *spec| {
            wrapper.* = ledger_mod.OwnedPayload.takeOwned(copy.allocator, &copy.bytes);
            // Keep two non-owning descriptors beside the wrapper-owned descriptor. Abort cleanup
            // uses the three-way address/length majority and never trusts wrapper.allocator.
            copy.bytes = @constCast(copy.view);
            transfer.cleanup_transferred_count += 1;
            spec.* = .{
                .semantic = ledgerSemantic(copy.semantic),
                .logical_len = wrapper.bytes().len,
            };
        }
        try ledger_mod.PreparedSeedPlan.initInPlace(
            &out.seed_plan,
            allocator,
            ledger,
            specs,
            transfer.wrappers,
        );
        out.cleanup_transfer = transfer.*;
        out.lifecycle = .prepared;
    }

    pub fn validate(
        self: *const PreparedScreenBacklog,
        client: *const client_mod.Client,
        ledger: *const ledger_mod.ExternalInboxLedger,
    ) bool {
        if (self.lifecycle != .prepared or self.saved_self_address != @intFromPtr(self) or
            self.client_address != @intFromPtr(client) or
            self.ledger_address != @intFromPtr(ledger) or
            self.pointer_bits != @bitSizeOf(usize) or
            !std.meta.eql(self.allocator, client.allocator) or
            !std.meta.eql(self.cleanup_allocator, client.allocator) or
            !client.validateExternalAdoptionPlan(&self.client_disarm))
            return false;
        const inventory = &(self.inventory orelse return false);
        if (!client.externalAdoptionDisarmMatchesInventory(
            &self.client_disarm,
            inventory,
        )) return false;
        const inventory_metadata = inventory.metadataBytes() catch return false;
        const disarm_metadata = client.externalAdoptionDisarmMetadataBytes(
            &self.client_disarm,
        ) catch return false;
        const client_metadata = std.math.add(
            usize,
            inventory_metadata,
            disarm_metadata,
        ) catch return false;
        const should_transfer = inventory.screen_source_count <= ledger_mod.max_items and
            inventory.screen_payload_bytes <= ledger_mod.max_bytes;
        if ((self.transfer != null) != should_transfer) return false;
        const transfer_count = if (should_transfer) inventory.screen_source_count else 0;
        const metadata = metadataFootprint(
            transfer_count,
            client_metadata,
            inventory_metadata,
            inventory.validation_scratch_peak_bytes,
        ) catch return false;
        if (self.adoption_metadata_resident_bytes != metadata.resident or
            self.adoption_metadata_prepare_peak_bytes != metadata.prepare_peak)
            return false;
        const expected_request_ids = request_id_state.State.fromNext(
            inventory.next_request_id,
        ) catch return false;
        if (!std.meta.eql(self.request_ids, expected_request_ids)) return false;
        const transfer = if (self.transfer) |*value| value else return true;
        if (transfer.copies.len != inventory.screen_source_count or
            transfer.wrappers.len != inventory.screen_source_count or
            transfer.tokens.len != inventory.screen_source_count or
            transfer.copies_addr !=
                sliceAddress(client_mod.ExternalScreenCopy, transfer.copies) or
            transfer.copies_len != transfer.copies.len or
            transfer.wrappers_addr !=
                sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers) or
            transfer.wrappers_len != transfer.wrappers.len or
            transfer.tokens_addr != sliceAddress(ledger_mod.Token, transfer.tokens) or
            transfer.tokens_len != transfer.tokens.len or
            !sameSlice(client_mod.ExternalScreenCopy, transfer.copies, transfer.cleanup_copies) or
            !sameSlice(ledger_mod.OwnedPayload, transfer.wrappers, transfer.cleanup_wrappers) or
            !sameSlice(ledger_mod.Token, transfer.tokens, transfer.cleanup_tokens) or
            transfer.cleanup_transferred_count != transfer.copies.len or
            !self.seed_plan.validateBinding(
                ledger,
                transfer.wrappers,
                inventory.screen_source_count,
            ))
            return false;
        for (transfer.copies, transfer.wrappers, 0..) |
            copy,
            wrapper,
            ordinal,
        | {
            if (!sameSlice(u8, copy.bytes, copy.view) or
                !sameSlice(u8, copy.view, wrapper.bytes()) or
                ordinal >= inventory.screen_source_count)
                return false;
        }
        return client.externalScreenCopiesMatch(inventory, transfer.copies);
    }

    pub fn targetStream(self: *const PreparedScreenBacklog) ?u64 {
        return if (self.inventory) |inventory| inventory.target_stream else null;
    }

    pub fn overlapsOwnedBacking(
        self: *const PreparedScreenBacklog,
        address: usize,
        len: usize,
    ) bool {
        return rangeOverlapsPreparedBacking(address, len, self);
    }

    pub fn prepareCommittedTake(
        self: *PreparedScreenBacklog,
        out: *PreparedCommittedScreenTake,
        destination: *CommittedScreenBacklog,
        client: *const client_mod.Client,
        ledger: *const ledger_mod.ExternalInboxLedger,
        stable_parent: *const anyopaque,
    ) error{InvalidAddress}!void {
        // Prove all structural and nested-backing ranges before reading either caller-provided
        // destination. A forged `out` may itself point at the final byte of a token allocation.
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(self),
            @sizeOf(PreparedScreenBacklog),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(destination),
            @sizeOf(CommittedScreenBacklog),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(client),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedCommittedScreenTake),
            @intFromPtr(ledger),
            @sizeOf(ledger_mod.ExternalInboxLedger),
        ) or rangeOverlapsPreparedBacking(
            @intFromPtr(out),
            @sizeOf(PreparedCommittedScreenTake),
            self,
        ) or rangesOverlap(
            @intFromPtr(destination),
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(self),
            @sizeOf(PreparedScreenBacklog),
        ) or rangeOverlapsPreparedBacking(
            @intFromPtr(destination),
            @sizeOf(CommittedScreenBacklog),
            self,
        ) or rangesOverlap(
            @intFromPtr(destination),
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(client),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            @intFromPtr(destination),
            @sizeOf(CommittedScreenBacklog),
            @intFromPtr(ledger),
            @sizeOf(ledger_mod.ExternalInboxLedger),
        ))
            return error.InvalidAddress;
        if (!out.isEmpty() or
            !self.validate(client, ledger) or
            !destination.isEmpty())
            return error.InvalidAddress;
        const transfer = self.transfer orelse return error.InvalidAddress;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .source_addr = @intFromPtr(self),
            .destination_addr = @intFromPtr(destination),
            .client_addr = @intFromPtr(client),
            .ledger_addr = @intFromPtr(ledger),
            .storage_addr = @intFromPtr(stable_parent),
            .target_stream = self.targetStream() orelse return error.InvalidAddress,
            .tokens_addr = sliceAddress(ledger_mod.Token, transfer.tokens),
            .tokens_len = transfer.tokens.len,
            .allocator = self.allocator,
            .commit_transfer = transfer,
            .lifecycle = .prepared,
        };
        if (!out.validate(self, destination, client, ledger, stable_parent)) {
            out.* = .{ .lifecycle = .aborted_tombstone };
            return error.InvalidAddress;
        }
    }

    /// No allocation, callback, validation or error return is permitted here. The outer final
    /// seal revalidates `take` immediately before the ledger barrier. The public visibility exists
    /// only for the permit-consuming pump aggregate; it is not an independently safe commit API.
    pub fn commitIntoUnchecked(
        self: *PreparedScreenBacklog,
        take: *PreparedCommittedScreenTake,
        destination: *CommittedScreenBacklog,
    ) void {
        const target_stream = take.target_stream;
        const retained_count = take.tokens_len;
        const primary = ScreenBackingAuthority{
            .allocator = take.allocator,
            .transfer = take.commit_transfer,
        };
        const cleanup = primary;
        destination.* = .{
            .saved_self_addr = @intFromPtr(destination),
            .source_addr = @intFromPtr(self),
            .ledger_addr = take.ledger_addr,
            .storage_addr = take.storage_addr,
            .target_stream = target_stream,
            .tokens_addr = take.tokens_addr,
            .tokens_len = take.tokens_len,
            .retained_count = retained_count,
            .primary = primary,
            .cleanup = cleanup,
            .lifecycle = .committed,
        };
        destination.primary_seal = sealScreenBackingAuthority(
            &destination.primary,
            take.storage_addr,
        );
        destination.cleanup_seal = sealScreenBackingAuthority(
            &destination.cleanup,
            take.storage_addr,
        );
        destination.canonical = screenCanonicalAuthority(
            destination,
            &destination.primary,
        );
        self.transfer = null;
        self.cleanup_transfer = null;
        take.* = .{ .lifecycle = .committed_tombstone };
    }

    /// Linearizes c1 seed ownership into the ledger and immediately tombstones every local payload
    /// descriptor. After success, abort cleanup owns metadata only; payload bytes belong solely to
    /// the ledger. Errors preserve the source Client and prepared plan; the ledger retains c1's
    /// documented sticky invariant semantics if its supposedly pristine accounting is corrupted.
    /// Returned token ownership is deliberately not exposed: c3 must either keep this backlog live
    /// as the borrowed token-backing owner or add a typed in-place take transition.
    pub fn commitScreenSeeds(
        self: *PreparedScreenBacklog,
        client: *const client_mod.Client,
        ledger: *ledger_mod.ExternalInboxLedger,
        retirement: *ledger_mod.PreparedSeedRetirement,
    ) ledger_mod.CommitError!void {
        if (!self.validate(client, ledger) or
            !client.validateSealedExternalAdoptionPlan(&self.client_disarm))
            return error.InvalidPlan;
        const transfer = if (self.transfer) |*value| value else return error.InvalidPlan;
        try ledger.commitSeedsDeferredRetirement(
            &self.seed_plan,
            transfer.wrappers,
            transfer.tokens,
            retirement,
        );
        for (transfer.copies) |*copy| {
            copy.bytes = &.{};
            copy.view = &.{};
        }
        transfer.cleanup_transferred_count = 0;
        if (self.cleanup_transfer) |*cleanup|
            cleanup.cleanup_transferred_count = 0;
        self.lifecycle = .committed;
    }

    pub fn deinit(self: *PreparedScreenBacklog) void {
        var cleanup: PreparedAggregateScreenCleanup = .{};
        if (self.prepareCleanupPlan(null, null, &cleanup))
            self.finishCleanupPlan(&cleanup)
        else
            self.abandonPreparedCleanup();
    }

    /// Owner-local fixture helper. Product aggregate cleanup must use the gated snapshot,
    /// prepare, and finish seams so sibling callbacks cannot precede descriptor freezing.
    fn deinitForAggregate(
        self: *PreparedScreenBacklog,
        take: *const PreparedCommittedScreenTake,
        client_allocator: std.mem.Allocator,
    ) void {
        var cleanup: PreparedAggregateScreenCleanup = .{};
        if (self.prepareCleanupPlan(
            take.cleanupAuthority(self),
            client_allocator,
            &cleanup,
        ))
            self.finishCleanupPlan(&cleanup)
        else
            self.abandonPreparedCleanup();
    }

    /// Freezes all nested payload and container descriptors without allocation or callback. The
    /// aggregate must call this before cleaning any sibling owner that can invoke an allocator.
    pub fn prepareAggregateCleanup(
        self: *PreparedScreenBacklog,
        take: *const PreparedCommittedScreenTake,
        client_allocator: std.mem.Allocator,
        out: *PreparedAggregateScreenCleanup,
    ) bool {
        return self.prepareCleanupPlan(
            take.cleanupAuthority(self),
            client_allocator,
            out,
        );
    }

    /// Consumes a previously frozen cleanup plan. No descriptor inside the shared copy/wrapper
    /// allocations is read after this function begins.
    pub fn finishAggregateCleanup(
        self: *PreparedScreenBacklog,
        cleanup: *PreparedAggregateScreenCleanup,
    ) void {
        self.finishCleanupPlan(cleanup);
    }

    /// Moves every screen cleanup authority into stack-owned snapshots before the aggregate runs
    /// its first allocator callback. The original fields are tombstoned first, so callbacks that
    /// retain the pump address cannot rewrite the evidence later consumed by cleanup.
    pub fn moveIntoAggregateCleanupSnapshot(
        self: *PreparedScreenBacklog,
        take: *PreparedCommittedScreenTake,
        out_backlog: *PreparedScreenBacklog,
        out_take: *PreparedCommittedScreenTake,
    ) bool {
        if (self.saved_self_address != @intFromPtr(self) or
            out_backlog.saved_self_address != 0 or
            out_backlog.lifecycle != .empty or
            out_backlog.inventory != null or
            out_backlog.cleanup_inventory != null or
            out_backlog.transfer != null or
            out_backlog.cleanup_transfer != null or
            out_backlog.client_disarm.saved_self_address != 0 or
            out_backlog.client_disarm.inventory != null or
            out_backlog.client_disarm.cleanup_inventory != null or
            out_backlog.seed_plan.saved_self_addr != 0 or
            out_backlog.seed_plan.entries.len != 0 or
            out_backlog.seed_plan.cleanup_entries.len != 0 or
            !out_take.isEmpty())
            return false;
        const source_addr = @intFromPtr(self);
        const seed_addr = @intFromPtr(&self.seed_plan);
        const disarm_addr = @intFromPtr(&self.client_disarm);
        out_backlog.* = self.*;
        out_take.* = take.*;
        self.* = .{ .lifecycle = .aborted };
        take.* = .{ .lifecycle = .aborted_tombstone };

        out_backlog.saved_self_address = @intFromPtr(out_backlog);
        if (out_backlog.seed_plan.saved_self_addr == seed_addr)
            out_backlog.seed_plan.saved_self_addr =
                @intFromPtr(&out_backlog.seed_plan);
        if (out_backlog.client_disarm.saved_self_address == disarm_addr)
            out_backlog.client_disarm.saved_self_address =
                @intFromPtr(&out_backlog.client_disarm);
        if (out_take.saved_self_addr != 0)
            out_take.saved_self_addr = @intFromPtr(out_take);
        if (out_take.source_addr == source_addr)
            out_take.source_addr = @intFromPtr(out_backlog);
        return true;
    }

    /// Corruption-only fallback when an address-bound snapshot cannot be formed. No allocator is
    /// called and the untrusted graph is deliberately abandoned before another owner can callback.
    pub fn abandonAggregateCleanup(
        self: *PreparedScreenBacklog,
        take: *PreparedCommittedScreenTake,
    ) void {
        self.* = .{ .lifecycle = .aborted };
        take.* = .{ .lifecycle = .aborted_tombstone };
    }

    fn prepareCleanupPlan(
        self: *PreparedScreenBacklog,
        maybe_authority: ?ScreenCleanupAuthority,
        client_allocator: ?std.mem.Allocator,
        out: *PreparedAggregateScreenCleanup,
    ) bool {
        if (!out.isEmpty() or
            (self.saved_self_address != 0 and
                self.saved_self_address != @intFromPtr(self)))
            return false;
        var prepared: PreparedAggregateScreenCleanup = .{
            .committed_cleanup = self.seed_plan.isCommitted(),
            .lifecycle = .prepared,
        };
        if (self.transfer != null or self.cleanup_transfer != null) {
            const authority_transfer = if (maybe_authority) |authority|
                authority.transfer
            else
                null;
            const allow_single_incomplete = self.lifecycle != .prepared and
                self.cleanup_transfer == null and maybe_authority == null;
            prepared.allocator = self.canonicalCleanupAllocator(
                maybe_authority,
                client_allocator,
            ) orelse {
                if (allow_single_incomplete) {
                    out.* = prepared;
                    return true;
                }
                return false;
            };
            prepared.copies = canonicalTransferSlice(
                client_mod.ExternalScreenCopy,
                "copies",
                "cleanup_copies",
                "copies_addr",
                "copies_len",
                self.transfer,
                self.cleanup_transfer,
                authority_transfer,
                allow_single_incomplete,
            ) orelse {
                if (allow_single_incomplete) {
                    out.* = prepared;
                    return true;
                }
                return false;
            };
            prepared.wrappers = canonicalTransferSlice(
                ledger_mod.OwnedPayload,
                "wrappers",
                "cleanup_wrappers",
                "wrappers_addr",
                "wrappers_len",
                self.transfer,
                self.cleanup_transfer,
                authority_transfer,
                allow_single_incomplete,
            ) orelse {
                if (allow_single_incomplete) {
                    out.* = prepared;
                    return true;
                }
                return false;
            };
            prepared.tokens = canonicalTransferSlice(
                ledger_mod.Token,
                "tokens",
                "cleanup_tokens",
                "tokens_addr",
                "tokens_len",
                self.transfer,
                self.cleanup_transfer,
                authority_transfer,
                allow_single_incomplete,
            ) orelse {
                if (allow_single_incomplete) {
                    out.* = prepared;
                    return true;
                }
                return false;
            };
            if (prepared.copies.len > prepared.payloads.len) return false;
            for (prepared.copies, 0..) |copy, index| {
                prepared.payloads[index] = cleanupPayload(
                    copy,
                    if (index < prepared.wrappers.len)
                        prepared.wrappers[index]
                    else
                        null,
                ) orelse return false;
            }
            prepared.payload_count = prepared.copies.len;
            prepared.has_transfer = true;
        }
        out.* = prepared;
        return true;
    }

    fn finishCleanupPlan(
        self: *PreparedScreenBacklog,
        cleanup: *PreparedAggregateScreenCleanup,
    ) void {
        if (cleanup.lifecycle != .prepared) return;
        const committed_cleanup = cleanup.committed_cleanup;
        if (cleanup.has_transfer) {
            // From this callback onward cleanup must not inspect copies/wrappers elements again.
            self.seed_plan.deinit();
            for (cleanup.payloads[0..cleanup.payload_count]) |payload|
                cleanup.allocator.free(payload);
            cleanup.allocator.free(cleanup.tokens);
            cleanup.allocator.free(cleanup.wrappers);
            cleanup.allocator.free(cleanup.copies);
        }
        self.client_disarm.deinit();
        if (self.inventory orelse self.cleanup_inventory) |inventory_value| {
            var inventory = inventory_value;
            inventory.deinit();
        }
        self.inventory = null;
        self.cleanup_inventory = null;
        self.transfer = null;
        self.cleanup_transfer = null;
        self.lifecycle = if (committed_cleanup) .committed else .aborted;
        self.adoption_metadata_resident_bytes = 0;
        self.adoption_metadata_prepare_peak_bytes = 0;
        cleanup.* = .{ .lifecycle = .consumed };
    }

    fn abandonPreparedCleanup(self: *PreparedScreenBacklog) void {
        self.inventory = null;
        self.cleanup_inventory = null;
        self.transfer = null;
        self.cleanup_transfer = null;
        self.lifecycle = .aborted;
        self.adoption_metadata_resident_bytes = 0;
        self.adoption_metadata_prepare_peak_bytes = 0;
    }

    fn canonicalCleanupAllocator(
        self: *const PreparedScreenBacklog,
        maybe_authority: ?ScreenCleanupAuthority,
        client_allocator: ?std.mem.Allocator,
    ) ?std.mem.Allocator {
        const backlog_candidate = if (allocatorMatchesSeal(
            self.allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        ))
            self.allocator
        else if (allocatorMatchesSeal(
            self.cleanup_allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        ))
            self.cleanup_allocator
        else
            null;
        const take_candidate = if (maybe_authority) |authority|
            authority.allocator
        else
            null;
        if (majorityAllocator(
            backlog_candidate,
            take_candidate,
            client_allocator,
        )) |allocator| return allocator;
        // During fallible standalone construction no aggregate/take exists yet. The address-bound
        // allocator seal is then the only available authority and is sufficient for rollback.
        if (maybe_authority == null and client_allocator == null)
            return backlog_candidate;
        return null;
    }
};

fn screenBackingAuthorityFromPrepared(
    source: *const PreparedScreenBacklog,
) ScreenBackingAuthority {
    return .{
        .allocator = source.allocator,
        .transfer = source.transfer.?,
    };
}

fn sealScreenBackingAuthority(
    authority: *const ScreenBackingAuthority,
    storage_addr: usize,
) ScreenBackingSeal {
    const transfer = authority.transfer;
    var transcript = owner_seal.Writer.init("maru.screen-owner.backing.v1");
    transcript.writeUsize(storage_addr);
    transcript.writeUsize(@intFromPtr(authority.allocator.ptr));
    transcript.writeUsize(@intFromPtr(authority.allocator.vtable));
    transcript.writeUsize(sliceAddress(client_mod.ExternalScreenCopy, transfer.copies));
    transcript.writeUsize(transfer.copies.len);
    transcript.writeUsize(sliceAddress(
        client_mod.ExternalScreenCopy,
        transfer.cleanup_copies,
    ));
    transcript.writeUsize(transfer.cleanup_copies.len);
    transcript.writeUsize(sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers));
    transcript.writeUsize(transfer.wrappers.len);
    transcript.writeUsize(sliceAddress(
        ledger_mod.OwnedPayload,
        transfer.cleanup_wrappers,
    ));
    transcript.writeUsize(transfer.cleanup_wrappers.len);
    transcript.writeUsize(sliceAddress(ledger_mod.Token, transfer.tokens));
    transcript.writeUsize(transfer.tokens.len);
    transcript.writeUsize(sliceAddress(ledger_mod.Token, transfer.cleanup_tokens));
    transcript.writeUsize(transfer.cleanup_tokens.len);
    return .{
        .authority_addr = @intFromPtr(authority),
        .storage_addr = storage_addr,
        .allocator_ptr_addr = @intFromPtr(authority.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(authority.allocator.vtable),
        .copies_addr = sliceAddress(client_mod.ExternalScreenCopy, transfer.copies),
        .copies_len = transfer.copies.len,
        .cleanup_copies_addr = sliceAddress(
            client_mod.ExternalScreenCopy,
            transfer.cleanup_copies,
        ),
        .cleanup_copies_len = transfer.cleanup_copies.len,
        .wrappers_addr = sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers),
        .wrappers_len = transfer.wrappers.len,
        .cleanup_wrappers_addr = sliceAddress(
            ledger_mod.OwnedPayload,
            transfer.cleanup_wrappers,
        ),
        .cleanup_wrappers_len = transfer.cleanup_wrappers.len,
        .tokens_addr = sliceAddress(ledger_mod.Token, transfer.tokens),
        .tokens_len = transfer.tokens.len,
        .cleanup_tokens_addr = sliceAddress(ledger_mod.Token, transfer.cleanup_tokens),
        .cleanup_tokens_len = transfer.cleanup_tokens.len,
        .digest = transcript.finish(),
    };
}

fn screenBackingSealMatches(
    seal: ScreenBackingSeal,
    authority: *const ScreenBackingAuthority,
    storage_addr: usize,
) bool {
    if (seal.authority_addr != @intFromPtr(authority) or
        seal.storage_addr != storage_addr) return false;
    const actual = sealScreenBackingAuthority(authority, storage_addr);
    return std.meta.eql(seal, actual);
}

fn screenCanonicalAuthority(
    owner: *const CommittedScreenBacklog,
    authority: *const ScreenBackingAuthority,
) ScreenCanonicalAuthority {
    const transfer = authority.transfer;
    var result = ScreenCanonicalAuthority{
        .owner_addr = @intFromPtr(owner),
        .storage_addr = owner.storage_addr,
        .allocator_ptr_addr = @intFromPtr(authority.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(authority.allocator.vtable),
        .copies_addr = sliceAddress(client_mod.ExternalScreenCopy, transfer.copies),
        .copies_len = transfer.copies.len,
        .cleanup_copies_addr = sliceAddress(
            client_mod.ExternalScreenCopy,
            transfer.cleanup_copies,
        ),
        .cleanup_copies_len = transfer.cleanup_copies.len,
        .wrappers_addr = sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers),
        .wrappers_len = transfer.wrappers.len,
        .cleanup_wrappers_addr = sliceAddress(
            ledger_mod.OwnedPayload,
            transfer.cleanup_wrappers,
        ),
        .cleanup_wrappers_len = transfer.cleanup_wrappers.len,
        .tokens_addr = sliceAddress(ledger_mod.Token, transfer.tokens),
        .tokens_len = transfer.tokens.len,
        .cleanup_tokens_addr = sliceAddress(
            ledger_mod.Token,
            transfer.cleanup_tokens,
        ),
        .cleanup_tokens_len = transfer.cleanup_tokens.len,
    };
    result.digest = screenCanonicalAuthorityDigest(result);
    return result;
}

fn screenCanonicalAuthorityDigest(
    authority: ScreenCanonicalAuthority,
) owner_seal.Digest {
    var transcript = owner_seal.Writer.init("maru.screen-owner.canonical.v1");
    transcript.writeUsize(authority.owner_addr);
    transcript.writeUsize(authority.storage_addr);
    transcript.writeUsize(authority.allocator_ptr_addr);
    transcript.writeUsize(authority.allocator_vtable_addr);
    transcript.writeUsize(authority.copies_addr);
    transcript.writeUsize(authority.copies_len);
    transcript.writeUsize(authority.cleanup_copies_addr);
    transcript.writeUsize(authority.cleanup_copies_len);
    transcript.writeUsize(authority.wrappers_addr);
    transcript.writeUsize(authority.wrappers_len);
    transcript.writeUsize(authority.cleanup_wrappers_addr);
    transcript.writeUsize(authority.cleanup_wrappers_len);
    transcript.writeUsize(authority.tokens_addr);
    transcript.writeUsize(authority.tokens_len);
    transcript.writeUsize(authority.cleanup_tokens_addr);
    transcript.writeUsize(authority.cleanup_tokens_len);
    return transcript.finish();
}

fn screenCanonicalAuthorityValid(
    owner: *const CommittedScreenBacklog,
    authority: *const ScreenCanonicalAuthority,
) bool {
    return authority.owner_addr == @intFromPtr(owner) and
        authority.storage_addr == owner.storage_addr and
        authority.storage_addr != 0 and
        std.mem.eql(
            u8,
            &authority.digest,
            &screenCanonicalAuthorityDigest(authority.*),
        );
}

fn screenBackingMatchesCanonical(
    authority: *const ScreenBackingAuthority,
    canonical: *const ScreenCanonicalAuthority,
) bool {
    const transfer = authority.transfer;
    return canonical.allocator_ptr_addr == @intFromPtr(authority.allocator.ptr) and
        canonical.allocator_vtable_addr == @intFromPtr(authority.allocator.vtable) and
        canonical.copies_addr ==
            sliceAddress(client_mod.ExternalScreenCopy, transfer.copies) and
        canonical.copies_len == transfer.copies.len and
        canonical.cleanup_copies_addr ==
            sliceAddress(client_mod.ExternalScreenCopy, transfer.cleanup_copies) and
        canonical.cleanup_copies_len == transfer.cleanup_copies.len and
        canonical.wrappers_addr ==
            sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers) and
        canonical.wrappers_len == transfer.wrappers.len and
        canonical.cleanup_wrappers_addr ==
            sliceAddress(ledger_mod.OwnedPayload, transfer.cleanup_wrappers) and
        canonical.cleanup_wrappers_len == transfer.cleanup_wrappers.len and
        canonical.tokens_addr == sliceAddress(ledger_mod.Token, transfer.tokens) and
        canonical.tokens_len == transfer.tokens.len and
        canonical.cleanup_tokens_addr ==
            sliceAddress(ledger_mod.Token, transfer.cleanup_tokens) and
        canonical.cleanup_tokens_len == transfer.cleanup_tokens.len;
}

fn deinitScreenBackingAuthority(authority: *ScreenBackingAuthority) void {
    const transfer = authority.transfer;
    const copies = canonicalSlice(
        client_mod.ExternalScreenCopy,
        transfer.copies,
        transfer.cleanup_copies,
        transfer.copies_addr,
        transfer.copies_len,
    ) orelse return;
    const wrappers = canonicalSlice(
        ledger_mod.OwnedPayload,
        transfer.wrappers,
        transfer.cleanup_wrappers,
        transfer.wrappers_addr,
        transfer.wrappers_len,
    ) orelse return;
    const tokens = canonicalSlice(
        ledger_mod.Token,
        transfer.tokens,
        transfer.cleanup_tokens,
        transfer.tokens_addr,
        transfer.tokens_len,
    ) orelse return;
    const allocator = authority.allocator;
    authority.* = .{};
    // Payload bytes are ledger-owned after commitSeeds. Only the three container allocations move.
    allocator.free(tokens);
    allocator.free(wrappers);
    allocator.free(copies);
}

fn rangeOverlapsScreenBacking(
    destination_addr: usize,
    destination_len: usize,
    authority: *const ScreenBackingAuthority,
) bool {
    const transfer = authority.transfer;
    inline for (.{ .{
        @sizeOf(client_mod.ExternalScreenCopy),
        sliceAddress(client_mod.ExternalScreenCopy, transfer.copies),
        transfer.copies.len,
    }, .{
        @sizeOf(ledger_mod.OwnedPayload),
        sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers),
        transfer.wrappers.len,
    }, .{
        @sizeOf(ledger_mod.Token),
        sliceAddress(ledger_mod.Token, transfer.tokens),
        transfer.tokens.len,
    } }) |entry| {
        const bytes = std.math.mul(usize, entry[0], entry[2]) catch return true;
        if (rangesOverlap(
            destination_addr,
            destination_len,
            entry[1],
            bytes,
        )) return true;
    }
    return false;
}

fn rangeOverlapsPreparedBacking(
    destination_addr: usize,
    destination_len: usize,
    source: *const PreparedScreenBacklog,
) bool {
    const transfer = source.transfer orelse return false;
    const copies_bytes = std.math.mul(
        usize,
        transfer.copies.len,
        @sizeOf(client_mod.ExternalScreenCopy),
    ) catch return true;
    const wrappers_bytes = std.math.mul(
        usize,
        transfer.wrappers.len,
        @sizeOf(ledger_mod.OwnedPayload),
    ) catch return true;
    const tokens_bytes = std.math.mul(
        usize,
        transfer.tokens.len,
        @sizeOf(ledger_mod.Token),
    ) catch return true;
    if (rangesOverlap(
        destination_addr,
        destination_len,
        sliceAddress(client_mod.ExternalScreenCopy, transfer.copies),
        copies_bytes,
    ) or rangesOverlap(
        destination_addr,
        destination_len,
        sliceAddress(ledger_mod.OwnedPayload, transfer.wrappers),
        wrappers_bytes,
    ) or rangesOverlap(
        destination_addr,
        destination_len,
        sliceAddress(ledger_mod.Token, transfer.tokens),
        tokens_bytes,
    )) return true;
    for (transfer.copies) |copy| {
        if (rangesOverlap(
            destination_addr,
            destination_len,
            sliceAddress(u8, copy.view),
            copy.view.len,
        )) return true;
    }
    if (source.inventory) |*inventory|
        if (destinationOverlapsInventory(
            destination_addr,
            destination_len,
            inventory,
        )) return true;
    if (source.cleanup_inventory) |*inventory|
        if (destinationOverlapsInventory(
            destination_addr,
            destination_len,
            inventory,
        )) return true;
    if (source.client_disarm.inventory) |*inventory|
        if (destinationOverlapsInventory(
            destination_addr,
            destination_len,
            inventory,
        )) return true;
    if (source.client_disarm.cleanup_inventory) |*inventory|
        if (destinationOverlapsInventory(
            destination_addr,
            destination_len,
            inventory,
        )) return true;
    return false;
}

fn destinationOverlapsInventory(
    destination_addr: usize,
    destination_len: usize,
    inventory: *const client_mod.ExternalAdoptionInventory,
) bool {
    return sliceOverlaps(destination_addr, destination_len, inventory.batch_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.cleanup_batch_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.stream_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.cleanup_stream_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.event_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.cleanup_event_descriptors) or
        sliceOverlaps(destination_addr, destination_len, inventory.build_id_copy) or
        sliceOverlaps(destination_addr, destination_len, inventory.cleanup_build_id_copy) or
        sliceOverlaps(destination_addr, destination_len, inventory.lifecycle_copy) or
        sliceOverlaps(destination_addr, destination_len, inventory.cleanup_lifecycle_copy);
}

fn sliceOverlaps(destination_addr: usize, destination_len: usize, slice: anytype) bool {
    const Slice = @TypeOf(slice);
    const T = std.meta.Child(Slice);
    const byte_len = std.math.mul(usize, slice.len, @sizeOf(T)) catch return true;
    return rangesOverlap(
        destination_addr,
        destination_len,
        sliceAddress(T, slice),
        byte_len,
    );
}

fn canonicalSlice(
    comptime T: type,
    primary: []T,
    cleanup: []T,
    sealed_addr: usize,
    sealed_len: usize,
) ?[]T {
    if (sliceAddress(T, primary) == sealed_addr and primary.len == sealed_len)
        return primary;
    if (sliceAddress(T, cleanup) == sealed_addr and cleanup.len == sealed_len)
        return cleanup;
    return null;
}

fn SliceAuthority(comptime T: type) type {
    return struct {
        primary: []T,
        cleanup: []T,
        sealed_addr: usize,
        sealed_len: usize,
    };
}

const SliceDescriptor = struct {
    addr: usize,
    len: usize,
};

fn canonicalTransferSlice(
    comptime T: type,
    comptime primary_field: []const u8,
    comptime cleanup_field: []const u8,
    comptime addr_field: []const u8,
    comptime len_field: []const u8,
    primary_transfer: ?PreparedTransfer,
    cleanup_transfer: ?PreparedTransfer,
    take_transfer: ?PreparedTransfer,
    allow_single_incomplete: bool,
) ?[]T {
    const authorities = [3]?SliceAuthority(T){
        transferSliceAuthority(
            T,
            primary_transfer,
            primary_field,
            cleanup_field,
            addr_field,
            len_field,
        ),
        transferSliceAuthority(
            T,
            cleanup_transfer,
            primary_field,
            cleanup_field,
            addr_field,
            len_field,
        ),
        transferSliceAuthority(
            T,
            take_transfer,
            primary_field,
            cleanup_field,
            addr_field,
            len_field,
        ),
    };
    if (allow_single_incomplete) {
        const authority = authorities[0] orelse return null;
        const descriptor = sliceAuthorityVote(T, authority) orelse return null;
        return sliceMatchingDescriptor(T, authority, descriptor);
    }
    const descriptor = majoritySliceDescriptor(T, authorities) orelse return null;
    for (authorities) |maybe_authority| {
        const authority = maybe_authority orelse continue;
        if (sliceMatchingDescriptor(T, authority, descriptor)) |slice|
            return slice;
    }
    return null;
}

fn transferSliceAuthority(
    comptime T: type,
    transfer: ?PreparedTransfer,
    comptime primary_field: []const u8,
    comptime cleanup_field: []const u8,
    comptime addr_field: []const u8,
    comptime len_field: []const u8,
) ?SliceAuthority(T) {
    const value = transfer orelse return null;
    return .{
        .primary = @field(value, primary_field),
        .cleanup = @field(value, cleanup_field),
        .sealed_addr = @field(value, addr_field),
        .sealed_len = @field(value, len_field),
    };
}

fn sliceAuthorityVote(
    comptime T: type,
    authority: SliceAuthority(T),
) ?SliceDescriptor {
    const descriptor = SliceDescriptor{
        .addr = if (authority.sealed_len == 0) 0 else authority.sealed_addr,
        .len = authority.sealed_len,
    };
    if (sliceMatchingDescriptor(T, authority, descriptor) == null) return null;
    return descriptor;
}

fn majoritySliceDescriptor(
    comptime T: type,
    authorities: [3]?SliceAuthority(T),
) ?SliceDescriptor {
    const first = if (authorities[0]) |authority|
        sliceAuthorityVote(T, authority)
    else
        null;
    const second = if (authorities[1]) |authority|
        sliceAuthorityVote(T, authority)
    else
        null;
    const third = if (authorities[2]) |authority|
        sliceAuthorityVote(T, authority)
    else
        null;
    if (first != null and second != null and
        std.meta.eql(first.?, second.?))
        return first;
    if (first != null and third != null and
        std.meta.eql(first.?, third.?))
        return first;
    if (second != null and third != null and
        std.meta.eql(second.?, third.?))
        return second;
    return null;
}

fn sliceMatchingDescriptor(
    comptime T: type,
    authority: SliceAuthority(T),
    descriptor: SliceDescriptor,
) ?[]T {
    if (descriptor.len == 0) {
        if (authority.primary.len == 0) return authority.primary;
        if (authority.cleanup.len == 0) return authority.cleanup;
        return null;
    }
    if (sliceAddress(T, authority.primary) == descriptor.addr and
        authority.primary.len == descriptor.len)
        return authority.primary;
    if (sliceAddress(T, authority.cleanup) == descriptor.addr and
        authority.cleanup.len == descriptor.len)
        return authority.cleanup;
    return null;
}

fn majoritySlice(a: []u8, b: []const u8, c_bytes: []const u8) ?[]u8 {
    if (sameSlice(u8, a, b) or sameSlice(u8, a, c_bytes)) return a;
    if (sameSlice(u8, b, c_bytes)) return @constCast(b);
    return null;
}

fn cleanupPayload(
    copy: client_mod.ExternalScreenCopy,
    wrapper: ?ledger_mod.OwnedPayload,
) ?[]u8 {
    if (wrapper) |owned|
        return majoritySlice(copy.bytes, copy.view, owned.bytes());
    if (!sameSlice(u8, copy.bytes, copy.view)) return null;
    return copy.bytes;
}

fn allocatorMatchesSeal(
    allocator: std.mem.Allocator,
    ptr_addr: usize,
    vtable_addr: usize,
) bool {
    return @intFromPtr(allocator.ptr) == ptr_addr and
        @intFromPtr(allocator.vtable) == vtable_addr;
}

fn majorityAllocator(
    first: ?std.mem.Allocator,
    second: ?std.mem.Allocator,
    third: ?std.mem.Allocator,
) ?std.mem.Allocator {
    if (first != null and second != null and
        std.meta.eql(first.?, second.?))
        return first;
    if (first != null and third != null and
        std.meta.eql(first.?, third.?))
        return first;
    if (second != null and third != null and
        std.meta.eql(second.?, third.?))
        return second;
    return null;
}

fn ledgerSemantic(source: client_mod.ExternalScreenSemantic) ledger_mod.PayloadSemantic {
    return switch (source) {
        .completed => |value| .{ .completed = .{
            .stream_id = value.stream_id,
            .is_snapshot = value.is_snapshot,
        } },
        .partial => |value| .{ .partial = .{
            .stream_id = value.stream_id,
            .is_snapshot = value.is_snapshot,
            .chunk_count = value.chunk_count,
        } },
        .frame => |header| .{ .frame = header },
    };
}

pub const MetadataFootprint = struct { resident: usize, prepare_peak: usize };

fn metadataFootprint(
    count: usize,
    client_metadata: usize,
    inventory_metadata: usize,
    validation_scratch_peak: usize,
) error{MetadataTooLarge}!MetadataFootprint {
    var resident: usize = client_metadata;
    inline for (.{
        @sizeOf(client_mod.ExternalScreenCopy),
        @sizeOf(ledger_mod.OwnedPayload),
        @sizeOf(ledger_mod.Token),
    }) |size| {
        const bytes = std.math.mul(usize, count, size) catch return error.MetadataTooLarge;
        resident = std.math.add(usize, resident, bytes) catch return error.MetadataTooLarge;
    }
    const planned = ledger_mod.PreparedSeedPlan.plannedMetadataBytes(count) catch
        return error.MetadataTooLarge;
    resident = std.math.add(usize, resident, planned) catch return error.MetadataTooLarge;
    const transient_specs = std.math.mul(
        usize,
        count,
        @sizeOf(ledger_mod.SeedSpec),
    ) catch return error.MetadataTooLarge;
    const seed_prepare_peak = std.math.add(
        usize,
        resident,
        transient_specs,
    ) catch return error.MetadataTooLarge;
    const validation_peak = std.math.add(
        usize,
        inventory_metadata,
        validation_scratch_peak,
    ) catch return error.MetadataTooLarge;
    const peak = @max(seed_prepare_peak, validation_peak);
    if (resident > max_adoption_metadata_bytes or peak > max_adoption_metadata_bytes)
        return error.MetadataTooLarge;
    return .{ .resident = resident, .prepare_peak = peak };
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn sliceAddress(comptime T: type, slice: []const T) usize {
    return if (slice.len == 0) 0 else @intFromPtr(slice.ptr);
}

fn sameSlice(comptime T: type, left: []const T, right: []const T) bool {
    return left.len == right.len and sliceAddress(T, left) == sliceAddress(T, right);
}

fn makePreparedClient(allocator: std.mem.Allocator) !struct {
    client: client_mod.Client,
    peer_fd: c.fd_t,
} {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .connection_profile = .cli_attach,
        .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
    };
    errdefer {
        source.deinit();
        _ = c.close(fds[1]);
    }
    try source.enterExternalMode();
    source.ownership = .external_pump;
    return .{ .client = source, .peer_fd = fds[1] };
}

const ReentrantScreenCleanupAllocator = struct {
    parent: std.mem.Allocator,
    owner: ?*CommittedScreenBacklog = null,
    permit: LedgerFinishedPermit = .{ .ledger_addr = 0 },
    free_calls: usize = 0,
    observed_tombstone: bool = true,

    fn allocator(self: *ReentrantScreenCleanupAllocator) std.mem.Allocator {
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
        const self: *ReentrantScreenCleanupAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *ReentrantScreenCleanupAllocator = @ptrCast(@alignCast(context));
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
        const self: *ReentrantScreenCleanupAllocator = @ptrCast(@alignCast(context));
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
        const self: *ReentrantScreenCleanupAllocator = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        if (self.owner) |owner| {
            self.observed_tombstone =
                self.observed_tombstone and owner.lifecycle == .cleaned_tombstone;
            owner.deinitAfterLedgerFinished(self.permit);
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "prepared external adoption binds final address and exact screen seed" {
    var fixture = try makePreparedClient(std.testing.allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try std.testing.allocator.dupe(u8, "screen");
    var client_owns_payload = false;
    errdefer if (!client_owns_payload) std.testing.allocator.free(payload);
    try fixture.client.screen_inbox.pending_batches.append(std.testing.allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = std.testing.allocator,
    });
    client_owns_payload = true;
    fixture.client.screen_inbox.pending_batch_bytes = payload.len;
    var prepared_ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    defer prepared.deinit();
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        std.testing.allocator,
        &fixture.client,
        &prepared_ledger,
        7,
    );
    var committed_destination: CommittedScreenBacklog = .{};
    var cleanup_take: PreparedCommittedScreenTake = .{};
    var stable_parent: u8 = 0;
    try prepared.prepareCommittedTake(
        &cleanup_take,
        &committed_destination,
        &fixture.client,
        &prepared_ledger,
        &stable_parent,
    );
    try std.testing.expectEqual(Lifecycle.prepared, prepared.lifecycle);
    try std.testing.expect(prepared.transfer != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.transfer.?.wrappers.len);
    try std.testing.expectEqualStrings("screen", prepared.transfer.?.wrappers[0].bytes());
    try std.testing.expect(prepared.validate(&fixture.client, &prepared_ledger));
    const wrapper_allocator = prepared.transfer.?.wrappers[0].allocator;
    prepared.transfer.?.wrappers[0].allocator = std.heap.page_allocator;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.transfer.?.wrappers[0].allocator = wrapper_allocator;
    const wrapper_ptr = prepared.transfer.?.wrappers[0].allocation_ptr;
    prepared.transfer.?.wrappers[0].allocation_ptr = null;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.transfer.?.wrappers[0].allocation_ptr = wrapper_ptr;
    const wrapper_len = prepared.transfer.?.wrappers[0].logical_len;
    prepared.transfer.?.wrappers[0].logical_len += 1;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.transfer.?.wrappers[0].logical_len = wrapper_len;
    try std.testing.expect(prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.screen_inbox.pending_batches.items[0].bytes[0] = 'X';
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.screen_inbox.pending_batches.items[0].bytes[0] = 's';
    try std.testing.expect(prepared.validate(&fixture.client, &prepared_ledger));
    const copies = prepared.transfer.?.copies;
    prepared.transfer.?.copies = prepared.transfer.?.copies[0..0];
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.transfer.?.copies = copies;
    const plan_allocator = prepared.seed_plan.allocator;
    prepared.seed_plan.allocator = std.heap.page_allocator;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.seed_plan.allocator = plan_allocator;
    const request_ids = prepared.request_ids;
    prepared.request_ids = .max_consumed;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.request_ids = request_ids;
    const inventory_allocator = prepared.inventory.?.allocator;
    prepared.inventory.?.allocator = std.heap.page_allocator;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.inventory.?.allocator = inventory_allocator;
    const resident = prepared.adoption_metadata_resident_bytes;
    prepared.adoption_metadata_resident_bytes += 1;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.adoption_metadata_resident_bytes = resident;
    const pointer_bits = prepared.pointer_bits;
    prepared.pointer_bits = 0;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.pointer_bits = pointer_bits;
    const transfer = prepared.transfer.?;
    prepared.transfer = null;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.transfer = transfer;
    var copied = prepared;
    try std.testing.expect(!copied.validate(&fixture.client, &prepared_ledger));
    prepared.cleanup_transfer.?.cleanup_copies = &.{};
    prepared.cleanup_transfer.?.copies_addr = 0;
    prepared.cleanup_transfer.?.copies_len = 0;
    prepared.cleanup_transfer.?.cleanup_wrappers = &.{};
    prepared.cleanup_transfer.?.wrappers_addr = 0;
    prepared.cleanup_transfer.?.wrappers_len = 0;
    prepared.deinitForAggregate(&cleanup_take, std.testing.allocator);
    prepared.deinit();
    try std.testing.expectEqual(Lifecycle.aborted, prepared.lifecycle);
}

test "prepared external adoption cleanup uses sealed owners after persistent field drift" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try allocator.dupe(u8, "screen");
    try fixture.client.screen_inbox.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.screen_inbox.pending_batch_bytes = payload.len;
    var prepared_ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &prepared_ledger,
        7,
    );
    var committed_destination: CommittedScreenBacklog = .{};
    var cleanup_take: PreparedCommittedScreenTake = .{};
    var stable_parent: u8 = 0;
    try prepared.prepareCommittedTake(
        &cleanup_take,
        &committed_destination,
        &fixture.client,
        &prepared_ledger,
        &stable_parent,
    );

    prepared.transfer.?.copies = &.{};
    prepared.transfer.?.wrappers = &.{};
    prepared.transfer.?.tokens = &.{};
    prepared.transfer.?.cleanup_wrappers[0].allocator = std.heap.page_allocator;
    prepared.transfer.?.cleanup_wrappers[0].allocation_ptr = null;
    prepared.transfer.?.cleanup_wrappers[0].logical_len = std.math.maxInt(usize);
    prepared.seed_plan.allocator = std.heap.page_allocator;
    prepared.inventory.?.batch_descriptors = &.{};
    prepared.inventory.?.sealed_allocator = std.heap.page_allocator;
    prepared.client_disarm.lifecycle = @enumFromInt(3);
    prepared.lifecycle = .committed;
    prepared.allocator_ptr_addr += 1;
    prepared.transfer = null;
    prepared.inventory = null;
    prepared.client_disarm.inventory = null;
    prepared.cleanup_transfer.?.cleanup_transferred_count = std.math.maxInt(usize);
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    prepared.deinitForAggregate(&cleanup_take, allocator);
    prepared.deinit();
    try std.testing.expectEqual(Lifecycle.aborted, prepared.lifecycle);
}

test "prepared external adoption transfers payload cleanup authority to the ledger exactly once" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try allocator.dupe(u8, "screen");
    try fixture.client.screen_inbox.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.screen_inbox.pending_batch_bytes = payload.len;
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );

    var seed_retirement: ledger_mod.PreparedSeedRetirement = .{};
    try std.testing.expectError(
        error.InvalidPlan,
        prepared.commitScreenSeeds(
            &fixture.client,
            &ledger,
            &seed_retirement,
        ),
    );
    try std.testing.expect(seed_retirement.isEmpty());
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try fixture.client.sealExternalAdoption(&prepared.client_disarm);
    try prepared.commitScreenSeeds(
        &fixture.client,
        &ledger,
        &seed_retirement,
    );
    seed_retirement.retire();
    const token = prepared.transfer.?.tokens[0];
    fixture.client.commitExternalAdoption(&prepared.client_disarm);
    const borrowed = try ledger.borrow(token, .completed);
    try std.testing.expectEqualStrings("screen", borrowed.bytes);
    prepared.deinit();
    prepared.deinit();
    try std.testing.expectEqualStrings(
        "screen",
        (try ledger.borrow(token, .completed)).bytes,
    );
    const report = try ledger.drainAll();
    try std.testing.expectEqual(@as(usize, 1), report.drained_active_count);
    try ledger.finish();
}

test "c3c-2b1 committed screen destination is final-address bound and moves without callbacks" {
    var counting = ReentrantScreenCleanupAllocator{ .parent = std.testing.allocator };
    const allocator = counting.allocator();
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try allocator.dupe(u8, "screen");
    try fixture.client.screen_inbox.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.screen_inbox.pending_batch_bytes = payload.len;
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    var committed: CommittedScreenBacklog = .{};
    var take: PreparedCommittedScreenTake = .{};
    var stable_parent: u8 = 0;
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );
    committed.storage_addr = @intFromPtr(&stable_parent);
    try std.testing.expectError(
        error.InvalidAddress,
        prepared.prepareCommittedTake(
            &take,
            &committed,
            &fixture.client,
            &ledger,
            &stable_parent,
        ),
    );
    try std.testing.expectEqual(
        @intFromPtr(&stable_parent),
        committed.storage_addr,
    );
    committed = .{};
    const transfer = prepared.transfer.?;
    const aliased_out: *PreparedCommittedScreenTake =
        @ptrCast(@alignCast(transfer.tokens.ptr));
    try std.testing.expectError(
        error.InvalidAddress,
        prepared.prepareCommittedTake(
            aliased_out,
            &committed,
            &fixture.client,
            &ledger,
            &stable_parent,
        ),
    );
    var aborted_take: PreparedCommittedScreenTake = .{};
    try prepared.prepareCommittedTake(
        &aborted_take,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    );
    aborted_take.abort();
    try std.testing.expect(!aborted_take.validate(
        &prepared,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    ));
    try std.testing.expect(committed.isEmpty());
    try prepared.prepareCommittedTake(
        &take,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    );
    const aliased_destination: *CommittedScreenBacklog =
        @ptrCast(@alignCast(payload.ptr));
    var alias_take: PreparedCommittedScreenTake = .{};
    try std.testing.expectError(
        error.InvalidAddress,
        prepared.prepareCommittedTake(
            &alias_take,
            aliased_destination,
            &fixture.client,
            &ledger,
            &stable_parent,
        ),
    );
    var moved_destination = committed;
    try std.testing.expect(!take.validate(
        &prepared,
        &moved_destination,
        &fixture.client,
        &ledger,
        &stable_parent,
    ));
    try std.testing.expect(take.validate(
        &prepared,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    ));
    inline for (.{
        @intFromPtr(&prepared),
        @intFromPtr(&fixture.client),
        @intFromPtr(&ledger),
    }) |alias_addr| {
        var forged_take = take;
        forged_take.saved_self_addr = @intFromPtr(&forged_take);
        forged_take.destination_addr = alias_addr;
        const structural_alias: *const CommittedScreenBacklog =
            @ptrFromInt(alias_addr);
        try std.testing.expect(!forged_take.validate(
            &prepared,
            structural_alias,
            &fixture.client,
            &ledger,
            &stable_parent,
        ));
    }
    take.target_stream += 1;
    try std.testing.expect(!take.validate(
        &prepared,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    ));
    take.target_stream -= 1;

    try fixture.client.sealExternalAdoption(&prepared.client_disarm);
    const inventory_addr = @intFromPtr(&prepared.inventory.?);
    const disarm_addr = @intFromPtr(&prepared.client_disarm);
    const request_ids_before = prepared.request_ids;
    const resident_before = prepared.adoption_metadata_resident_bytes;
    const peak_before = prepared.adoption_metadata_prepare_peak_bytes;
    const target_before = prepared.targetStream();
    var seed_retirement: ledger_mod.PreparedSeedRetirement = .{};
    try prepared.commitScreenSeeds(
        &fixture.client,
        &ledger,
        &seed_retirement,
    );
    const ledger_token = prepared.transfer.?.tokens[0];
    const deallocations_before_take = counting.free_calls;
    prepared.commitIntoUnchecked(&take, &committed);
    try std.testing.expectEqual(deallocations_before_take, counting.free_calls);
    seed_retirement.retire();
    try std.testing.expectEqual(@as(usize, 1), committed.retained_count);
    try std.testing.expectEqual(@as(u64, 7), committed.target_stream);
    try std.testing.expectEqual(Lifecycle.committed, prepared.lifecycle);
    try std.testing.expect(prepared.transfer == null);
    try std.testing.expect(prepared.cleanup_transfer == null);
    try std.testing.expectEqual(inventory_addr, @intFromPtr(&prepared.inventory.?));
    try std.testing.expectEqual(disarm_addr, @intFromPtr(&prepared.client_disarm));
    try std.testing.expect(std.meta.eql(request_ids_before, prepared.request_ids));
    try std.testing.expectEqual(
        resident_before,
        prepared.adoption_metadata_resident_bytes,
    );
    try std.testing.expectEqual(
        peak_before,
        prepared.adoption_metadata_prepare_peak_bytes,
    );
    try std.testing.expectEqual(target_before, prepared.targetStream());
    try std.testing.expect(fixture.client.validateSealedExternalAdoptionPlan(
        &prepared.client_disarm,
    ));
    var client_take: client_mod.ExternalAdoptionTake = .{};
    defer client_take.deinit();
    try fixture.client.prepareExternalAdoptionTake(
        &prepared.client_disarm,
        &prepared.inventory,
        &prepared.cleanup_inventory,
        &client_take,
    );
    try std.testing.expect(client_take.validate(
        &fixture.client,
        &prepared.client_disarm,
        &prepared.inventory,
        &prepared.cleanup_inventory,
    ));
    try std.testing.expectEqualStrings(
        "screen",
        (try ledger.borrow(ledger_token, .completed)).bytes,
    );
    try std.testing.expect(committed.isCommitted(&stable_parent));
    var wrong_parent: u8 = 0;
    try std.testing.expect(!committed.isCommitted(&wrong_parent));
    try std.testing.expect(!take.validate(
        &prepared,
        &committed,
        &fixture.client,
        &ledger,
        &stable_parent,
    ));
    var moved_committed = committed;
    try std.testing.expect(!moved_committed.isCommitted(&stable_parent));

    _ = try ledger.drainAll();
    try ledger.finish();
    const permit = LedgerFinishedPermit{ .ledger_addr = @intFromPtr(&ledger) };
    counting.owner = &committed;
    counting.permit = permit;
    const frees_before_owner_cleanup = counting.free_calls;
    committed.deinitAfterLedgerFinished(.{ .ledger_addr = @intFromPtr(&ledger) + 1 });
    try std.testing.expect(committed.isCommitted(&stable_parent));
    try std.testing.expectEqual(frees_before_owner_cleanup, counting.free_calls);
    // Poison the preferred mirror. Cleanup must select the independently sealed primary.
    committed.cleanup.transfer.tokens = &.{};
    committed.deinitAfterLedgerFinished(permit);
    committed.deinitAfterLedgerFinished(permit);
    try std.testing.expect(counting.free_calls > deallocations_before_take);
    try std.testing.expect(counting.observed_tombstone);
    try std.testing.expect(!committed.isCommitted(&stable_parent));
    prepared.deinit();
}

test "c3c-2b1 screen cleanup rejects forged mirror and injected digest collision" {
    const Scenario = enum {
        forged_cleanup,
        forged_cleanup_primary_poison,
        forged_primary_cleanup_poison,
        digest_collision,
    };
    inline for ([_]Scenario{
        .forged_cleanup,
        .forged_cleanup_primary_poison,
        .forged_primary_cleanup_poison,
        .digest_collision,
    }) |scenario| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = counting.allocator();
        const copies = try allocator.alloc(client_mod.ExternalScreenCopy, 1);
        const wrappers = try allocator.alloc(ledger_mod.OwnedPayload, 1);
        const tokens = try allocator.alloc(ledger_mod.Token, 1);
        copies[0] = .{
            .allocator = allocator,
            .semantic = .{ .completed = .{ .stream_id = 7, .is_snapshot = false } },
            .bytes = &.{},
            .view = &.{},
        };
        wrappers[0] = ledger_mod.OwnedPayload.empty(allocator);
        tokens[0] = .{ .slot = 0, .generation = 1 };
        const transfer = PreparedTransfer{
            .copies = copies,
            .wrappers = wrappers,
            .tokens = tokens,
            .copies_addr = @intFromPtr(copies.ptr),
            .copies_len = copies.len,
            .wrappers_addr = @intFromPtr(wrappers.ptr),
            .wrappers_len = wrappers.len,
            .tokens_addr = @intFromPtr(tokens.ptr),
            .tokens_len = tokens.len,
            .cleanup_copies = copies,
            .cleanup_wrappers = wrappers,
            .cleanup_tokens = tokens,
        };
        var stable_parent: u8 = 0;
        var owner = CommittedScreenBacklog{
            .ledger_addr = 1,
            .storage_addr = @intFromPtr(&stable_parent),
            .primary = .{ .allocator = allocator, .transfer = transfer },
            .cleanup = .{ .allocator = allocator, .transfer = transfer },
            .lifecycle = .committed,
        };
        owner.saved_self_addr = @intFromPtr(&owner);
        owner.primary_seal = sealScreenBackingAuthority(
            &owner.primary,
            owner.storage_addr,
        );
        owner.cleanup_seal = sealScreenBackingAuthority(
            &owner.cleanup,
            owner.storage_addr,
        );
        owner.canonical = screenCanonicalAuthority(&owner, &owner.primary);
        switch (scenario) {
            .forged_cleanup, .forged_cleanup_primary_poison => {
                owner.cleanup.transfer.tokens = &.{};
                owner.cleanup.transfer.cleanup_tokens = &.{};
                owner.cleanup_seal = sealScreenBackingAuthority(
                    &owner.cleanup,
                    owner.storage_addr,
                );
                if (scenario == .forged_cleanup_primary_poison)
                    owner.primary_seal.?.tokens_len += 1;
            },
            .forged_primary_cleanup_poison => {
                owner.primary.transfer.tokens = &.{};
                owner.primary.transfer.cleanup_tokens = &.{};
                owner.primary_seal = sealScreenBackingAuthority(
                    &owner.primary,
                    owner.storage_addr,
                );
                owner.cleanup_seal.?.tokens_len += 1;
            },
            .digest_collision => {
                // Model an injected digest collision by forcing digest equality after changing
                // the canonical scalar. Candidate-vs-canonical scalar equality must still reject
                // both frees even when the digest gate is assumed to have accepted the forgery.
                owner.canonical.tokens_len += 1;
                owner.canonical.digest =
                    screenCanonicalAuthorityDigest(owner.canonical);
            },
        }
        const frees_before = counting.deallocations;
        owner.deinitAfterLedgerFinished(.{ .ledger_addr = 1 });
        const expected_frees: usize = if (scenario == .forged_cleanup) 3 else 0;
        try std.testing.expectEqual(
            frees_before + expected_frees,
            counting.deallocations,
        );
        try std.testing.expect(!owner.requiresTypedCleanup());
        if (expected_frees == 0) {
            allocator.free(tokens);
            allocator.free(wrappers);
            allocator.free(copies);
        }
    }
}

test "prepared external adoption uses a typed transfer-null recovery above item cap" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    try fixture.client.screen_inbox.pending_batches.ensureTotalCapacityPrecise(
        allocator,
        ledger_mod.max_items,
    );
    for (0..ledger_mod.max_items) |_| {
        fixture.client.screen_inbox.pending_batches.appendAssumeCapacity(.{
            .is_snapshot = false,
            .stream_id = 7,
            .bytes = &.{},
            .allocator = allocator,
        });
    }
    var exact_ledger: ledger_mod.ExternalInboxLedger = .{};
    var exact: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &exact,
        allocator,
        &fixture.client,
        &exact_ledger,
        7,
    );
    try std.testing.expect(exact.transfer != null);
    try std.testing.expectEqual(ledger_mod.max_items, exact.transfer.?.wrappers.len);
    exact.deinit();

    fixture.client.screen_inbox.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = .empty,
        .chunk_count = 1,
    };
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    defer prepared.deinit();
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );
    try std.testing.expect(prepared.transfer == null);
    try std.testing.expect(prepared.validate(&fixture.client, &ledger));
    try std.testing.expect(prepared.adoption_metadata_resident_bytes > 0);
}

test "prepared external adoption distinguishes exact screen byte cap from cap plus one" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const completed = try allocator.alloc(u8, ledger_mod.max_batch_bytes);
    @memset(completed, 'b');
    try fixture.client.screen_inbox.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = completed,
        .allocator = allocator,
    });
    fixture.client.screen_inbox.pending_batch_bytes = completed.len;
    const partial_len = ledger_mod.max_bytes - ledger_mod.max_batch_bytes;
    const partial_backing = try allocator.alloc(u8, partial_len + 1);
    @memset(partial_backing, 'p');
    fixture.client.screen_inbox.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = .{
            .items = partial_backing[0..partial_len],
            .capacity = partial_backing.len,
        },
        .chunk_count = 2,
    };

    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var exact: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &exact,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );
    try std.testing.expect(exact.transfer != null);
    exact.deinit();

    fixture.client.screen_inbox.partial_batch.?.bytes.items = partial_backing;
    fixture.client.screen_inbox.partial_batch.?.chunk_count = 3;
    var over: PreparedScreenBacklog = .{};
    defer over.deinit();
    try PreparedScreenBacklog.initInPlace(
        &over,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );
    try std.testing.expect(over.transfer == null);
    try std.testing.expect(over.validate(&fixture.client, &ledger));
}

fn checkPreparedScreenBacklogAllocation(allocator: std.mem.Allocator) !void {
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    try fixture.client.parser.push("parser");
    const payload = try allocator.dupe(u8, "batch");
    var client_owns_payload = false;
    errdefer if (!client_owns_payload) allocator.free(payload);
    try fixture.client.screen_inbox.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    client_owns_payload = true;
    fixture.client.screen_inbox.pending_batch_bytes = payload.len;
    var partial_bytes: std.ArrayListUnmanaged(u8) = .empty;
    try partial_bytes.appendSlice(allocator, "partial");
    fixture.client.screen_inbox.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = partial_bytes,
        .chunk_count = 1,
    };
    const stream_payload = try allocator.dupe(u8, "stream");
    errdefer if (fixture.client.screen_inbox.pending_stream.items.len == 0)
        allocator.free(stream_payload);
    try fixture.client.screen_inbox.pending_stream.append(allocator, .{
        .header = .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .payload_len = @intCast(stream_payload.len),
        },
        .payload = stream_payload,
    });
    fixture.client.screen_inbox.pending_stream_bytes = stream_payload.len;
    const event_payload = try allocator.dupe(u8, "event");
    errdefer if (fixture.client.pending_events.items.len == 0)
        allocator.free(event_payload);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = 7,
            .payload_len = @intCast(event_payload.len),
        },
        .payload = event_payload,
    });
    fixture.client.pending_event_bytes = event_payload.len;
    const payload_ptr = payload.ptr;
    const batch_items_ptr = fixture.client.screen_inbox.pending_batches.items.ptr;
    const batch_capacity = fixture.client.screen_inbox.pending_batches.capacity;
    const batch_len = fixture.client.screen_inbox.pending_batches.items.len;
    const batch_counter = fixture.client.screen_inbox.pending_batch_bytes;
    const batch_before = fixture.client.screen_inbox.pending_batches.items[0];
    const partial_ptr = fixture.client.screen_inbox.partial_batch.?.bytes.items.ptr;
    const partial_capacity = fixture.client.screen_inbox.partial_batch.?.bytes.capacity;
    const partial_before = fixture.client.screen_inbox.partial_batch.?;
    const stream_items_ptr = fixture.client.screen_inbox.pending_stream.items.ptr;
    const stream_capacity = fixture.client.screen_inbox.pending_stream.capacity;
    const stream_len = fixture.client.screen_inbox.pending_stream.items.len;
    const stream_counter = fixture.client.screen_inbox.pending_stream_bytes;
    const stream_before = fixture.client.screen_inbox.pending_stream.items[0];
    const event_items_ptr = fixture.client.pending_events.items.ptr;
    const event_capacity = fixture.client.pending_events.capacity;
    const event_len = fixture.client.pending_events.items.len;
    const event_counter = fixture.client.pending_event_bytes;
    const event_before = fixture.client.pending_events.items[0];
    const parser_ptr = fixture.client.parser.buf.items.ptr;
    const parser_capacity = fixture.client.parser.buf.capacity;
    const parser_len = fixture.client.parser.buf.items.len;
    const parser_head = fixture.client.parser.head;
    const parser_major = fixture.client.parser.expected_major;
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    const ledger_before = ledger.accountingView();
    var prepared: PreparedScreenBacklog = .{};
    defer prepared.deinit();
    PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &ledger,
        7,
    ) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(payload_ptr, fixture.client.screen_inbox.pending_batches.items[0].bytes.ptr);
            try std.testing.expectEqualStrings("batch", fixture.client.screen_inbox.pending_batches.items[0].bytes);
            try std.testing.expectEqual(batch_items_ptr, fixture.client.screen_inbox.pending_batches.items.ptr);
            try std.testing.expectEqual(batch_capacity, fixture.client.screen_inbox.pending_batches.capacity);
            try std.testing.expectEqual(batch_len, fixture.client.screen_inbox.pending_batches.items.len);
            try std.testing.expectEqual(batch_counter, fixture.client.screen_inbox.pending_batch_bytes);
            try std.testing.expect(std.meta.eql(batch_before, fixture.client.screen_inbox.pending_batches.items[0]));
            try std.testing.expectEqual(partial_ptr, fixture.client.screen_inbox.partial_batch.?.bytes.items.ptr);
            try std.testing.expectEqual(partial_capacity, fixture.client.screen_inbox.partial_batch.?.bytes.capacity);
            try std.testing.expect(std.meta.eql(partial_before, fixture.client.screen_inbox.partial_batch.?));
            try std.testing.expectEqualStrings("partial", fixture.client.screen_inbox.partial_batch.?.bytes.items);
            try std.testing.expectEqual(stream_items_ptr, fixture.client.screen_inbox.pending_stream.items.ptr);
            try std.testing.expectEqual(stream_capacity, fixture.client.screen_inbox.pending_stream.capacity);
            try std.testing.expectEqual(stream_len, fixture.client.screen_inbox.pending_stream.items.len);
            try std.testing.expectEqual(stream_counter, fixture.client.screen_inbox.pending_stream_bytes);
            try std.testing.expect(std.meta.eql(stream_before, fixture.client.screen_inbox.pending_stream.items[0]));
            try std.testing.expectEqualStrings("stream", fixture.client.screen_inbox.pending_stream.items[0].payload);
            try std.testing.expectEqual(event_items_ptr, fixture.client.pending_events.items.ptr);
            try std.testing.expectEqual(event_capacity, fixture.client.pending_events.capacity);
            try std.testing.expectEqual(event_len, fixture.client.pending_events.items.len);
            try std.testing.expectEqual(event_counter, fixture.client.pending_event_bytes);
            try std.testing.expect(std.meta.eql(event_before, fixture.client.pending_events.items[0]));
            try std.testing.expectEqualStrings("event", fixture.client.pending_events.items[0].payload);
            try std.testing.expectEqual(parser_ptr, fixture.client.parser.buf.items.ptr);
            try std.testing.expectEqual(parser_capacity, fixture.client.parser.buf.capacity);
            try std.testing.expectEqual(parser_len, fixture.client.parser.buf.items.len);
            try std.testing.expectEqual(parser_head, fixture.client.parser.head);
            try std.testing.expectEqual(parser_major, fixture.client.parser.expected_major);
            try std.testing.expectEqualStrings("parser", fixture.client.parser.buf.items);
            _ = try preflightMetadata(&fixture.client, 7);
            try std.testing.expect(std.meta.eql(ledger_before, ledger.accountingView()));
            try std.testing.expectEqual(Lifecycle.empty, prepared.lifecycle);
        }
        return err;
    };
}

test "prepared external adoption cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPreparedScreenBacklogAllocation,
        .{},
    );
}

test "adoption metadata has exact resident and prepare peak cap" {
    const resident_cap = try metadataFootprint(
        0,
        max_adoption_metadata_bytes,
        0,
        0,
    );
    try std.testing.expectEqual(
        max_adoption_metadata_bytes,
        resident_cap.resident,
    );
    try std.testing.expectError(
        error.MetadataTooLarge,
        metadataFootprint(0, max_adoption_metadata_bytes + 1, 0, 0),
    );
    const prepare_cap = try metadataFootprint(
        0,
        0,
        0,
        max_adoption_metadata_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), prepare_cap.resident);
    try std.testing.expectEqual(
        max_adoption_metadata_bytes,
        prepare_cap.prepare_peak,
    );
    try std.testing.expectError(
        error.MetadataTooLarge,
        metadataFootprint(0, 0, 0, max_adoption_metadata_bytes + 1),
    );

    const per_item_peak = @sizeOf(ledger_mod.OwnedPayload) +
        @sizeOf(ledger_mod.Token) +
        @sizeOf(client_mod.ExternalScreenCopy) +
        @sizeOf(ledger_mod.SeedSpec) +
        (try ledger_mod.PreparedSeedPlan.plannedMetadataBytes(1));
    const exact_count = max_adoption_metadata_bytes / per_item_peak;
    const exact = try metadataFootprint(exact_count, 0, 0, 0);
    try std.testing.expect(exact.prepare_peak <= max_adoption_metadata_bytes);
    try std.testing.expectError(
        error.MetadataTooLarge,
        metadataFootprint(exact_count + 1, 0, 0, 0),
    );
    try std.testing.expectError(
        error.MetadataTooLarge,
        metadataFootprint(std.math.maxInt(usize), 0, 0, 0),
    );
}

test "adoption metadata hard cap rejects before the next allocator call" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    fixture.client.build_id = try allocator.alloc(
        u8,
        max_adoption_metadata_bytes / 2 + 1,
    );
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(
        error.MetadataTooLarge,
        preflightMetadata(&fixture.client, 7),
    );
    try std.testing.expect(!failing.has_induced_failure);
}

test "adoption preflight closes request partial stream counter tx and parser edges" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();

    fixture.client.next_request_id = 0;
    try std.testing.expectError(
        error.InvalidRequestId,
        preflightMetadata(&fixture.client, 7),
    );
    fixture.client.next_request_id = std.math.maxInt(u64);
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var max_request: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &max_request,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );
    try std.testing.expect(max_request.request_ids == .last_available);
    max_request.deinit();
    fixture.client.next_request_id = 1;

    fixture.client.screen_inbox.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = .empty,
        .chunk_count = 0,
    };
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.screen_inbox.partial_batch.?.chunk_count = ledger_mod.max_batch_chunks;
    _ = try preflightMetadata(&fixture.client, 7);
    fixture.client.screen_inbox.partial_batch.?.chunk_count = ledger_mod.max_batch_chunks + 1;
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.screen_inbox.partial_batch.?.chunk_count = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.screen_inbox.partial_batch.?.chunk_count = 1;
    fixture.client.screen_inbox.partial_batch.?.stream_id = 8;
    try std.testing.expectError(error.InvalidStream, preflightMetadata(&fixture.client, 7));
    fixture.client.screen_inbox.partial_batch = null;

    fixture.client.screen_inbox.pending_stream_bytes = 1;
    try std.testing.expectError(error.InvalidCounter, preflightMetadata(&fixture.client, 7));
    fixture.client.screen_inbox.pending_stream_bytes = 0;
    fixture.client.parser.expected_major += 1;
    try std.testing.expectError(error.InvalidClientState, preflightMetadata(&fixture.client, 7));
    fixture.client.parser.expected_major -= 1;
    switch (fixture.client.io_mode) {
        .blocking => return error.TestUnexpectedResult,
        .external => |*state| {
            const capacity = state.external_tx.capacity;
            state.external_tx.capacity -= 1;
            try std.testing.expectError(
                error.InvalidClientState,
                preflightMetadata(&fixture.client, 7),
            );
            state.external_tx.capacity = capacity;
        },
    }
    _ = try preflightMetadata(&fixture.client, 7);

    try fixture.client.parser.buf.ensureTotalCapacityPrecise(allocator, 4);
    var prepared_ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    defer prepared.deinit();
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &prepared_ledger,
        7,
    );
    switch (fixture.client.io_mode) {
        .blocking => return error.TestUnexpectedResult,
        .external => |*state| {
            const items = state.external_tx.items;
            state.external_tx.items = state.external_tx.allocatedSlice()[0..1];
            try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
            state.external_tx.items = items;
            state.external_tx_bytes = 1;
            try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
            state.external_tx_bytes = 0;
        },
    }
    fixture.client.parser.expected_major += 1;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.parser.expected_major -= 1;
    const parser_items = fixture.client.parser.buf.items;
    fixture.client.parser.buf.items = fixture.client.parser.buf.allocatedSlice()[0..1];
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.parser.buf.items = parser_items;
    fixture.client.parser.head = 1;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.parser.head = 0;
    const parser_capacity = fixture.client.parser.buf.capacity;
    fixture.client.parser.buf.capacity -= 1;
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.parser.buf.capacity = parser_capacity;
}
