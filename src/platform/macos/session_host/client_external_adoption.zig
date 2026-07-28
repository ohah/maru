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
const owner_seal = @import("external_owner_seal.zig");
const framing = @import("framing.zig");
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
/// Preparation is fallible and runs before the ledger barrier; `commitIntoNoFail` only moves
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
    lifecycle: CommittedTakeLifecycle = .empty,

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
            self.tokens_len == transfer.tokens.len;
    }

    pub fn abort(self: *PreparedCommittedScreenTake) void {
        if (self.saved_self_addr != 0 and
            self.saved_self_addr != @intFromPtr(self))
            return;
        self.* = .{ .lifecycle = .aborted_tombstone };
    }
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
            self.retained_count == self.tokens_len and
            self.retained_count <= ledger_mod.max_items and
            self.released.count() == 0 and
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

    /// Private b1 cleanup seam. The permit can only be minted by this file's fixture after it has
    /// drained and finished the ledger; c3c-3 replaces it with the aggregate teardown permit.
    fn deinitAfterLedgerFinished(
        self: *CommittedScreenBacklog,
        permit: LedgerFinishedPermit,
    ) void {
        if (self.lifecycle == .empty or self.lifecycle == .cleaned_tombstone) return;
        if (self.saved_self_addr != @intFromPtr(self)) return;
        if (permit.ledger_addr != self.ledger_addr) return;
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
        const authority: ?ScreenBackingAuthority = if (cleanup_valid)
            self.cleanup
        else if (primary_valid)
            self.primary
        else
            null;
        // Re-entrant allocator callbacks must observe a spent owner before the first free.
        self.* = .{ .lifecycle = .cleaned_tombstone };
        var owned = authority orelse return;
        deinitScreenBackingAuthority(&owned);
    }
};

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
        if (!std.meta.eql(out.*, PreparedCommittedScreenTake{}) or
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
            .lifecycle = .prepared,
        };
        if (!out.validate(self, destination, client, ledger, stable_parent)) {
            out.* = .{ .lifecycle = .aborted_tombstone };
            return error.InvalidAddress;
        }
    }

    /// No allocation, callback, validation or error return is permitted here. The outer final
    /// seal revalidates `take` immediately before the ledger barrier.
    pub fn commitIntoNoFail(
        self: *PreparedScreenBacklog,
        take: *PreparedCommittedScreenTake,
        destination: *CommittedScreenBacklog,
    ) void {
        const target_stream = take.target_stream;
        const retained_count = take.tokens_len;
        const primary = screenBackingAuthorityFromPrepared(self);
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
    ) ledger_mod.CommitError!void {
        if (!self.validate(client, ledger) or
            !client.validateSealedExternalAdoptionPlan(&self.client_disarm))
            return error.InvalidPlan;
        const transfer = if (self.transfer) |*value| value else return error.InvalidPlan;
        try ledger.commitSeeds(
            &self.seed_plan,
            transfer.wrappers,
            transfer.tokens,
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
        if (self.saved_self_address != 0 and self.saved_self_address != @intFromPtr(self)) return;
        const committed_cleanup = self.seed_plan.isCommitted();
        if (self.transfer orelse self.cleanup_transfer) |transfer_value| {
            const transfer = transfer_value;
            const cleanup = transfer;
            self.seed_plan.deinit();
            const allocator = self.canonicalCleanupAllocator() orelse return;
            const copies = canonicalSlice(
                client_mod.ExternalScreenCopy,
                transfer.copies,
                cleanup.cleanup_copies,
                cleanup.copies_addr,
                cleanup.copies_len,
            ) orelse return;
            const wrappers = canonicalSlice(
                ledger_mod.OwnedPayload,
                transfer.wrappers,
                cleanup.cleanup_wrappers,
                cleanup.wrappers_addr,
                cleanup.wrappers_len,
            ) orelse return;
            const tokens = canonicalSlice(
                ledger_mod.Token,
                transfer.tokens,
                cleanup.cleanup_tokens,
                cleanup.tokens_addr,
                cleanup.tokens_len,
            ) orelse return;
            for (copies, 0..) |copy, index| {
                _ = cleanupPayload(
                    copy,
                    if (index < wrappers.len) wrappers[index] else null,
                ) orelse return;
            }
            for (copies, 0..) |copy, index| {
                allocator.free(cleanupPayload(
                    copy,
                    if (index < wrappers.len) wrappers[index] else null,
                ) orelse unreachable);
            }
            allocator.free(tokens);
            allocator.free(wrappers);
            allocator.free(copies);
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
    }

    fn canonicalCleanupAllocator(self: *const PreparedScreenBacklog) ?std.mem.Allocator {
        if (std.meta.eql(self.allocator, self.cleanup_allocator))
            return self.allocator;
        if (allocatorMatchesSeal(
            self.allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        )) return self.allocator;
        if (allocatorMatchesSeal(
            self.cleanup_allocator,
            self.allocator_ptr_addr,
            self.allocator_vtable_addr,
        )) return self.cleanup_allocator;
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
    if (sameSlice(T, primary, cleanup)) return primary;
    if (sliceAddress(T, primary) == sealed_addr and primary.len == sealed_len)
        return primary;
    if (sliceAddress(T, cleanup) == sealed_addr and cleanup.len == sealed_len)
        return cleanup;
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
    try fixture.client.pending_batches.append(std.testing.allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = std.testing.allocator,
    });
    client_owns_payload = true;
    fixture.client.pending_batch_bytes = payload.len;
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
    fixture.client.pending_batches.items[0].bytes[0] = 'X';
    try std.testing.expect(!prepared.validate(&fixture.client, &prepared_ledger));
    fixture.client.pending_batches.items[0].bytes[0] = 's';
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
    prepared.deinit();
    prepared.deinit();
    try std.testing.expectEqual(Lifecycle.aborted, prepared.lifecycle);
}

test "prepared external adoption cleanup uses sealed owners after persistent field drift" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var prepared_ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &prepared_ledger,
        7,
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
    prepared.deinit();
    prepared.deinit();
    try std.testing.expectEqual(Lifecycle.aborted, prepared.lifecycle);
}

test "prepared external adoption transfers payload cleanup authority to the ledger exactly once" {
    const allocator = std.testing.allocator;
    var fixture = try makePreparedClient(allocator);
    defer _ = c.close(fixture.peer_fd);
    defer fixture.client.deinit();
    const payload = try allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var ledger: ledger_mod.ExternalInboxLedger = .{};
    var prepared: PreparedScreenBacklog = .{};
    try PreparedScreenBacklog.initInPlace(
        &prepared,
        allocator,
        &fixture.client,
        &ledger,
        7,
    );

    try std.testing.expectError(
        error.InvalidPlan,
        prepared.commitScreenSeeds(&fixture.client, &ledger),
    );
    try std.testing.expect(ledger.accountingView().pristine_zero);
    try fixture.client.sealExternalAdoption(&prepared.client_disarm);
    try prepared.commitScreenSeeds(&fixture.client, &ledger);
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
    const report = ledger.drainAll();
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
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
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
    try prepared.commitScreenSeeds(&fixture.client, &ledger);
    const ledger_token = prepared.transfer.?.tokens[0];
    const deallocations_before_take = counting.free_calls;
    prepared.commitIntoNoFail(&take, &committed);
    try std.testing.expectEqual(deallocations_before_take, counting.free_calls);
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

    _ = ledger.drainAll();
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
    try fixture.client.pending_batches.ensureTotalCapacityPrecise(
        allocator,
        ledger_mod.max_items,
    );
    for (0..ledger_mod.max_items) |_| {
        fixture.client.pending_batches.appendAssumeCapacity(.{
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

    fixture.client.partial_batch = .{
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
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = completed,
        .allocator = allocator,
    });
    fixture.client.pending_batch_bytes = completed.len;
    const partial_len = ledger_mod.max_bytes - ledger_mod.max_batch_bytes;
    const partial_backing = try allocator.alloc(u8, partial_len + 1);
    @memset(partial_backing, 'p');
    fixture.client.partial_batch = .{
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

    fixture.client.partial_batch.?.bytes.items = partial_backing;
    fixture.client.partial_batch.?.chunk_count = 3;
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
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = allocator,
    });
    client_owns_payload = true;
    fixture.client.pending_batch_bytes = payload.len;
    var partial_bytes: std.ArrayListUnmanaged(u8) = .empty;
    try partial_bytes.appendSlice(allocator, "partial");
    fixture.client.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = partial_bytes,
        .chunk_count = 1,
    };
    const stream_payload = try allocator.dupe(u8, "stream");
    errdefer if (fixture.client.pending_stream.items.len == 0)
        allocator.free(stream_payload);
    try fixture.client.pending_stream.append(allocator, .{
        .header = .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .payload_len = @intCast(stream_payload.len),
        },
        .payload = stream_payload,
    });
    fixture.client.pending_stream_bytes = stream_payload.len;
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
    const batch_items_ptr = fixture.client.pending_batches.items.ptr;
    const batch_capacity = fixture.client.pending_batches.capacity;
    const batch_len = fixture.client.pending_batches.items.len;
    const batch_counter = fixture.client.pending_batch_bytes;
    const batch_before = fixture.client.pending_batches.items[0];
    const partial_ptr = fixture.client.partial_batch.?.bytes.items.ptr;
    const partial_capacity = fixture.client.partial_batch.?.bytes.capacity;
    const partial_before = fixture.client.partial_batch.?;
    const stream_items_ptr = fixture.client.pending_stream.items.ptr;
    const stream_capacity = fixture.client.pending_stream.capacity;
    const stream_len = fixture.client.pending_stream.items.len;
    const stream_counter = fixture.client.pending_stream_bytes;
    const stream_before = fixture.client.pending_stream.items[0];
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
            try std.testing.expectEqual(payload_ptr, fixture.client.pending_batches.items[0].bytes.ptr);
            try std.testing.expectEqualStrings("batch", fixture.client.pending_batches.items[0].bytes);
            try std.testing.expectEqual(batch_items_ptr, fixture.client.pending_batches.items.ptr);
            try std.testing.expectEqual(batch_capacity, fixture.client.pending_batches.capacity);
            try std.testing.expectEqual(batch_len, fixture.client.pending_batches.items.len);
            try std.testing.expectEqual(batch_counter, fixture.client.pending_batch_bytes);
            try std.testing.expect(std.meta.eql(batch_before, fixture.client.pending_batches.items[0]));
            try std.testing.expectEqual(partial_ptr, fixture.client.partial_batch.?.bytes.items.ptr);
            try std.testing.expectEqual(partial_capacity, fixture.client.partial_batch.?.bytes.capacity);
            try std.testing.expect(std.meta.eql(partial_before, fixture.client.partial_batch.?));
            try std.testing.expectEqualStrings("partial", fixture.client.partial_batch.?.bytes.items);
            try std.testing.expectEqual(stream_items_ptr, fixture.client.pending_stream.items.ptr);
            try std.testing.expectEqual(stream_capacity, fixture.client.pending_stream.capacity);
            try std.testing.expectEqual(stream_len, fixture.client.pending_stream.items.len);
            try std.testing.expectEqual(stream_counter, fixture.client.pending_stream_bytes);
            try std.testing.expect(std.meta.eql(stream_before, fixture.client.pending_stream.items[0]));
            try std.testing.expectEqualStrings("stream", fixture.client.pending_stream.items[0].payload);
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

    fixture.client.partial_batch = .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = .empty,
        .chunk_count = 0,
    };
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.partial_batch.?.chunk_count = ledger_mod.max_batch_chunks;
    _ = try preflightMetadata(&fixture.client, 7);
    fixture.client.partial_batch.?.chunk_count = ledger_mod.max_batch_chunks + 1;
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.partial_batch.?.chunk_count = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidPartial, preflightMetadata(&fixture.client, 7));
    fixture.client.partial_batch.?.chunk_count = 1;
    fixture.client.partial_batch.?.stream_id = 8;
    try std.testing.expectError(error.InvalidStream, preflightMetadata(&fixture.client, 7));
    fixture.client.partial_batch = null;

    fixture.client.pending_stream_bytes = 1;
    try std.testing.expectError(error.InvalidCounter, preflightMetadata(&fixture.client, 7));
    fixture.client.pending_stream_bytes = 0;
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
