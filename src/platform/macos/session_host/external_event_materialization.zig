//! Final-address owner for the single metadata winner chosen by an external Client source fold.
//!
//! The fold and outer decision remain the semantic SSOT. This module only turns an adopted
//! metadata winner into prepared ownership: scalar/initial winners allocate nothing, while an
//! event winner owns exactly one DTO until the later c3c paired commit consumes it.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const decision_mod = @import("external_source_decision.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const runtime_event_reducer = @import("runtime_event_reducer.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

const Lifecycle = enum {
    empty,
    prepared,
    committed_tombstone,
    aborted_tombstone,
};

pub const PreparedMetadataFootprint = struct {
    resident_delta: usize,
    prepare_peak_delta: usize,
};

pub const PreparedOwnedMetadata = struct {
    saved_self_addr: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    backing_present: bool = false,
    backing_addr: usize = 0,
    backing_len: usize = 0,
    candidate: ?runtime_event_reducer.MetadataCandidate = null,
    logical: ?runtime_metadata_wire.OwnedMetadataDto = null,
    cleanup: ?runtime_metadata_wire.OwnedMetadataDto = null,
    logical_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    cleanup_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    footprint: PreparedMetadataFootprint = .{
        .resident_delta = 0,
        .prepare_peak_delta = 0,
    },
    lifecycle: Lifecycle = .empty,

    fn initInPlace(
        out: *PreparedOwnedMetadata,
        dto: *runtime_metadata_wire.OwnedMetadataDto,
        candidate: runtime_event_reducer.MetadataCandidate,
        footprint: PreparedMetadataFootprint,
    ) bool {
        if (!std.meta.eql(out.*, PreparedOwnedMetadata{}) or
            footprint.resident_delta == 0 or
            footprint.prepare_peak_delta < footprint.resident_delta)
            return false;
        const taken = dto.take();
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .allocator_ptr_addr = @intFromPtr(taken.allocator.ptr),
            .allocator_vtable_addr = @intFromPtr(taken.allocator.vtable),
            .backing_present = taken.backing != null,
            .backing_addr = if (taken.backing) |bytes| @intFromPtr(bytes.ptr) else 0,
            .backing_len = if (taken.backing) |bytes| bytes.len else 0,
            .candidate = candidate,
            .logical = taken,
            .cleanup = taken,
            .footprint = footprint,
            .lifecycle = .prepared,
        };
        out.logical_seal = runtime_metadata_wire.sealOwnedMetadataDto(
            &out.logical.?,
        ) catch {
            out.deinit();
            return false;
        };
        out.cleanup_seal = runtime_metadata_wire.sealOwnedMetadataDto(
            &out.cleanup.?,
        ) catch {
            out.deinit();
            return false;
        };
        return true;
    }

    fn validate(self: *const PreparedOwnedMetadata) bool {
        return self.lifecycle == .prepared and
            self.saved_self_addr == @intFromPtr(self) and
            self.logical != null and self.cleanup != null and
            self.candidate != null and
            self.allocator_ptr_addr == @intFromPtr(self.logical.?.allocator.ptr) and
            self.allocator_vtable_addr == @intFromPtr(self.logical.?.allocator.vtable) and
            canonicalDescriptorMatches(
                self,
                self.logical_seal,
                &self.logical.?,
            ) and
            canonicalDescriptorMatches(
                self,
                self.cleanup_seal,
                &self.cleanup.?,
            ) and
            runtime_metadata_wire.validateOwnedMetadataSeal(
                self.logical_seal orelse return false,
                &self.logical.?,
            ) and
            runtime_metadata_wire.validateOwnedMetadataSeal(
                self.cleanup_seal orelse return false,
                &self.cleanup.?,
            ) and
            self.footprint.resident_delta ==
                eventResidentBytes(&self.logical.?) and
            self.footprint.prepare_peak_delta >= self.footprint.resident_delta;
    }

    fn deinit(self: *PreparedOwnedMetadata) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return;
        if (self.lifecycle == .prepared) {
            if (self.cleanup) |*cleanup| {
                if (canonicalDescriptorMatches(self, self.cleanup_seal, cleanup)) {
                    cleanup.deinit();
                } else if (self.logical) |*logical| {
                    if (canonicalDescriptorMatches(self, self.logical_seal, logical))
                        logical.deinit();
                }
            } else if (self.logical) |*logical| {
                if (canonicalDescriptorMatches(self, self.logical_seal, logical))
                    logical.deinit();
            }
        }
        self.logical = null;
        self.cleanup = null;
        self.logical_seal = null;
        self.cleanup_seal = null;
        self.candidate = null;
        self.lifecycle = .aborted_tombstone;
    }
};

pub const PreparedMetadata = union(enum) {
    unsupported,
    unavailable,
    initial: client_mod.InitialMetadataBindingSeal,
    event: PreparedOwnedMetadata,
};

/// The wrapper, rather than the union payload alone, is the final-address capability. This keeps
/// copying a prepared union from silently rebinding its nested event owner.
pub const Prepared = struct {
    saved_self_addr: usize = 0,
    metadata: PreparedMetadata = .unavailable,
    prepared_footprint: PreparedMetadataFootprint = .{
        .resident_delta = 0,
        .prepare_peak_delta = 0,
    },
    lifecycle: Lifecycle = .empty,

    pub fn validate(
        self: *const Prepared,
        client: *const client_mod.Client,
        input: client_mod.ExternalAdoptionFoldInput,
        decision: decision_mod.PreparedSourceDecision,
        scratch: *client_mod.ExternalSourceOwnerRangeScratch,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            !decision_mod.decisionMatches(client, input, decision, scratch))
            return false;
        const live = switch (decision.verdict) {
            .adopted => |live| live,
            else => return false,
        };
        return switch (live.metadata) {
            .unsupported => self.metadata == .unsupported and
                footprintIsZero(self.prepared_footprint),
            .unavailable => self.metadata == .unavailable and
                footprintIsZero(self.prepared_footprint),
            .initial => switch (self.metadata) {
                .initial => |binding| std.meta.eql(
                    binding,
                    decision.fold.binding_seal.initial_metadata,
                ) and std.meta.eql(
                    self.prepared_footprint,
                    initialResidentFootprint(binding) orelse return false,
                ),
                else => false,
            },
            .event => switch (self.metadata) {
                .event => |*owned| owned.validate() and
                    runtime_event_reducer.metadataCandidateEql(
                        owned.candidate orelse return false,
                        live.metadata.event,
                    ) and
                    client.externalMetadataDtoMatchesEventCandidate(
                        input,
                        decision.fold,
                        live.metadata.event,
                        &owned.logical.?,
                        scratch,
                    ) and std.meta.eql(
                    self.prepared_footprint,
                    eventFootprint(
                        decision.fold.binding_seal.initial_metadata,
                        &owned.logical.?,
                    ) orelse return false,
                ) and std.meta.eql(
                    owned.footprint,
                    self.prepared_footprint,
                ),
                else => false,
            },
        };
    }

    pub fn footprint(
        self: *const Prepared,
        client: *const client_mod.Client,
        input: client_mod.ExternalAdoptionFoldInput,
        decision: decision_mod.PreparedSourceDecision,
        scratch: *client_mod.ExternalSourceOwnerRangeScratch,
    ) ?PreparedMetadataFootprint {
        if (!self.validate(client, input, decision, scratch)) return null;
        return self.prepared_footprint;
    }

    pub fn deinit(self: *Prepared) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return;
        if (self.lifecycle == .prepared) switch (self.metadata) {
            .event => |*owned| owned.deinit(),
            .unsupported, .unavailable, .initial => {},
        };
        self.metadata = .unavailable;
        self.prepared_footprint = .{
            .resident_delta = 0,
            .prepare_peak_delta = 0,
        };
        self.lifecycle = .aborted_tombstone;
    }
};

const OwnerLifecycle = enum {
    empty,
    committed,
    cleaned_tombstone,
};

pub const OwnerMetadataCurrent = struct {
    logical: runtime_metadata_wire.OwnedMetadataDto,
    cleanup: runtime_metadata_wire.OwnedMetadataDto,
    logical_seal: runtime_metadata_wire.OwnedMetadataSeal,
    cleanup_seal: runtime_metadata_wire.OwnedMetadataSeal,
    owner_seal: OwnerMetadataAuthoritySeal,
    cleanup_owner_seal: OwnerMetadataAuthoritySeal,
    pending: bool,
};

const owner_metadata_seal_domain: u64 = 0x4d_41_52_55_4d_44_4f_31; // MARUMDO1
const owner_metadata_seal_version: u16 = 1;

const OwnerMetadataAuthoritySeal = struct {
    domain: u64,
    version: u16,
    owner_addr: usize,
    storage_addr: usize,
    logical_addr: usize,
    cleanup_addr: usize,
    allocator_ptr_addr: usize,
    allocator_vtable_addr: usize,
    backing_present: bool,
    backing_addr: usize,
    backing_len: usize,
    revision: u64,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: runtime_event_wire.Digest,
    authority_digest: external_owner_seal.Digest,
};

pub const OwnerMetadata = union(enum) {
    unsupported,
    unavailable,
    current: OwnerMetadataCurrent,
};

/// Persistent metadata baseline. Delivery borrows arrive in c3c-3; b1 only owns the exact DTO and
/// keeps initial/event origins indistinguishable after their no-callback take.
pub const OwnerMetadataState = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    source_addr: usize = 0,
    metadata: OwnerMetadata = .unavailable,
    lifecycle: OwnerLifecycle = .empty,

    pub fn isEmpty(self: *const OwnerMetadataState) bool {
        return std.meta.eql(self.*, OwnerMetadataState{});
    }

    /// A corrupted committed descriptor still owns—or may own—backing. Generic teardown must
    /// fail closed and leave validation/fallback to `deinitCommitted`.
    pub fn requiresTypedCleanup(self: *const OwnerMetadataState) bool {
        return !self.isEmpty() and
            !std.meta.eql(
                self.*,
                OwnerMetadataState{ .lifecycle = .cleaned_tombstone },
            );
    }

    pub fn isCommitted(self: *const OwnerMetadataState) bool {
        if (self.lifecycle != .committed or
            self.saved_self_addr != @intFromPtr(self) or
            self.storage_addr == 0 or
            self.source_addr == 0)
            return false;
        return switch (self.metadata) {
            .unsupported, .unavailable => true,
            .current => |*current| current.pending and
                ownerMetadataAuthorityPairValid(self, current) and
                ownerMetadataCandidateValid(
                    self,
                    current,
                    current.owner_seal,
                    current.logical_seal,
                    &current.logical,
                ) and
                ownerMetadataCandidateValid(
                    self,
                    current,
                    current.cleanup_owner_seal,
                    current.cleanup_seal,
                    &current.cleanup,
                ),
        };
    }

    pub fn deinitCommitted(self: *OwnerMetadataState) void {
        if (self.lifecycle == .empty or self.lifecycle == .cleaned_tombstone) return;
        if (self.saved_self_addr != @intFromPtr(self)) return;
        var selected: ?runtime_metadata_wire.OwnedMetadataDto = null;
        if (self.metadata == .current) {
            const current = &self.metadata.current;
            if (ownerMetadataAuthorityPairValid(self, current)) {
                if (ownerMetadataCandidateValid(
                    self,
                    current,
                    current.owner_seal,
                    current.logical_seal,
                    &current.logical,
                )) {
                    selected = current.logical;
                } else if (ownerMetadataCandidateValid(
                    self,
                    current,
                    current.cleanup_owner_seal,
                    current.cleanup_seal,
                    &current.cleanup,
                )) {
                    selected = current.cleanup;
                }
            }
        }
        // No allocator callback may observe an owning state. The selected descriptor is a
        // stack-local frozen copy and every owner/mirror field is tombstoned first.
        self.* = .{ .lifecycle = .cleaned_tombstone };
        if (selected) |*dto| dto.deinit();
    }
};

const OwnerMetadataTakeKind = enum {
    unsupported,
    unavailable,
    initial,
    event,
};

pub const PreparedOwnerMetadataTake = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    prepared_addr: usize = 0,
    initial_addr: usize = 0,
    cleanup_addr: usize = 0,
    destination_addr: usize = 0,
    kind: OwnerMetadataTakeKind = .unavailable,
    primary_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    cleanup_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    lifecycle: Lifecycle = .empty,

    pub fn validate(
        self: *const PreparedOwnerMetadataTake,
        prepared: *const Prepared,
        initial: *const runtime_metadata_wire.InitialMetadataSeed,
        cleanup: *const runtime_metadata_wire.InitialMetadataSeed,
        destination: *const OwnerMetadataState,
        storage_addr: usize,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.storage_addr != storage_addr or
            storage_addr == 0 or
            self.prepared_addr != @intFromPtr(prepared) or
            self.initial_addr != @intFromPtr(initial) or
            self.cleanup_addr != @intFromPtr(cleanup) or
            self.destination_addr != @intFromPtr(destination) or
            !destination.isEmpty() or
            prepared.lifecycle != .prepared or
            prepared.saved_self_addr != @intFromPtr(prepared))
            return false;
        return switch (self.kind) {
            .unsupported => prepared.metadata == .unsupported and
                initial.* == .unsupported and cleanup.* == .unsupported,
            .unavailable => prepared.metadata == .unavailable and
                initial.* == .unavailable and cleanup.* == .unavailable,
            .initial => switch (prepared.metadata) {
                .initial => |binding| switch (binding) {
                    .current => |current| current.seed_address == @intFromPtr(initial) and
                        runtime_metadata_wire.validateMetadataSeedSeal(
                            current.seal,
                            initial,
                        ) and initialMetadataSourcesMatch(
                        self,
                        initial,
                        cleanup,
                    ),
                    .unsupported, .unavailable => false,
                },
                else => false,
            },
            .event => switch (prepared.metadata) {
                .event => |*event| event.validate() and
                    self.primary_seal != null and
                    self.cleanup_seal != null and
                    std.meta.eql(self.primary_seal.?, event.logical_seal.?) and
                    std.meta.eql(self.cleanup_seal.?, event.cleanup_seal.?),
                else => false,
            },
        };
    }

    pub fn abort(self: *PreparedOwnerMetadataTake) void {
        if (self.saved_self_addr != 0 and
            self.saved_self_addr != @intFromPtr(self))
            return;
        self.* = .{ .lifecycle = .aborted_tombstone };
    }
};

pub fn prepareOwnerMetadataTake(
    out: *PreparedOwnerMetadataTake,
    prepared: *const Prepared,
    initial: *const runtime_metadata_wire.InitialMetadataSeed,
    cleanup: *const runtime_metadata_wire.InitialMetadataSeed,
    destination: *const OwnerMetadataState,
    storage_addr: usize,
) error{InvalidOwnerTake}!void {
    // Alias proof is descriptor-only and must precede reading either caller-provided destination.
    // In particular a forged destination may point into a small DTO backing.
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(PreparedOwnerMetadataTake),
        @intFromPtr(prepared),
        @sizeOf(Prepared),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(PreparedOwnerMetadataTake),
        @intFromPtr(initial),
        @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(PreparedOwnerMetadataTake),
        @intFromPtr(cleanup),
        @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(PreparedOwnerMetadataTake),
        @intFromPtr(destination),
        @sizeOf(OwnerMetadataState),
    ) or rangesOverlap(
        @intFromPtr(destination),
        @sizeOf(OwnerMetadataState),
        @intFromPtr(prepared),
        @sizeOf(Prepared),
    ) or rangesOverlap(
        @intFromPtr(destination),
        @sizeOf(OwnerMetadataState),
        @intFromPtr(initial),
        @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
    ) or rangesOverlap(
        @intFromPtr(destination),
        @sizeOf(OwnerMetadataState),
        @intFromPtr(cleanup),
        @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
    ) or rangeOverlapsMetadataBacking(
        @intFromPtr(out),
        @sizeOf(PreparedOwnerMetadataTake),
        prepared,
        initial,
        cleanup,
    ) or rangeOverlapsMetadataBacking(
        @intFromPtr(destination),
        @sizeOf(OwnerMetadataState),
        prepared,
        initial,
        cleanup,
    ))
        return error.InvalidOwnerTake;
    if (!std.meta.eql(out.*, PreparedOwnerMetadataTake{}) or
        !destination.isEmpty() or
        storage_addr == 0 or
        prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared))
        return error.InvalidOwnerTake;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .storage_addr = storage_addr,
        .prepared_addr = @intFromPtr(prepared),
        .initial_addr = @intFromPtr(initial),
        .cleanup_addr = @intFromPtr(cleanup),
        .destination_addr = @intFromPtr(destination),
        .kind = switch (prepared.metadata) {
            .unsupported => .unsupported,
            .unavailable => .unavailable,
            .initial => .initial,
            .event => .event,
        },
        .lifecycle = .prepared,
    };
    switch (prepared.metadata) {
        .initial => {
            const primary = switch (initial.*) {
                .current => |*dto| runtime_metadata_wire.sealOwnedMetadataDto(dto) catch
                    return error.InvalidOwnerTake,
                else => return error.InvalidOwnerTake,
            };
            const mirror = switch (cleanup.*) {
                .current => |*dto| runtime_metadata_wire.sealOwnedMetadataDto(dto) catch
                    return error.InvalidOwnerTake,
                else => return error.InvalidOwnerTake,
            };
            out.primary_seal = primary;
            out.cleanup_seal = mirror;
        },
        .event => |*event| {
            if (!event.validate()) return error.InvalidOwnerTake;
            out.primary_seal = event.logical_seal;
            out.cleanup_seal = event.cleanup_seal;
        },
        .unsupported, .unavailable => {},
    }
    if (!out.validate(prepared, initial, cleanup, destination, storage_addr)) {
        out.* = .{ .lifecycle = .aborted_tombstone };
        return error.InvalidOwnerTake;
    }
}

/// The outer aggregate seal revalidates the plan before the ledger barrier. This suffix only moves
/// sealed descriptors and rewrites their address-bound DTO seals for the final destination.
pub fn commitOwnerMetadataTakeNoFail(
    take: *PreparedOwnerMetadataTake,
    prepared: *Prepared,
    initial: *runtime_metadata_wire.InitialMetadataSeed,
    cleanup: *runtime_metadata_wire.InitialMetadataSeed,
    destination: *OwnerMetadataState,
) void {
    destination.saved_self_addr = @intFromPtr(destination);
    destination.storage_addr = take.storage_addr;
    destination.source_addr = @intFromPtr(prepared);
    destination.lifecycle = .committed;
    switch (take.kind) {
        .unsupported => destination.metadata = .unsupported,
        .unavailable => destination.metadata = .unavailable,
        .initial => {
            const moved = initial.take().current;
            cleanup.* = .unavailable;
            destination.metadata = .{ .current = .{
                .logical = moved,
                .cleanup = moved,
                .logical_seal = take.primary_seal.?,
                .cleanup_seal = take.cleanup_seal.?,
                .owner_seal = undefined,
                .cleanup_owner_seal = undefined,
                .pending = true,
            } };
            destination.metadata.current.logical_seal = rebindOwnedSeal(
                take.primary_seal.?,
                &destination.metadata.current.logical,
            );
            destination.metadata.current.cleanup_seal = rebindOwnedSeal(
                take.cleanup_seal.?,
                &destination.metadata.current.cleanup,
            );
            bindOwnerMetadataAuthority(destination);
        },
        .event => {
            const event = &prepared.metadata.event;
            const moved = event.logical.?.take();
            event.cleanup = null;
            event.logical = null;
            event.logical_seal = null;
            event.cleanup_seal = null;
            event.candidate = null;
            event.lifecycle = .committed_tombstone;
            destination.metadata = .{ .current = .{
                .logical = moved,
                .cleanup = moved,
                .logical_seal = take.primary_seal.?,
                .cleanup_seal = take.cleanup_seal.?,
                .owner_seal = undefined,
                .cleanup_owner_seal = undefined,
                .pending = true,
            } };
            destination.metadata.current.logical_seal = rebindOwnedSeal(
                take.primary_seal.?,
                &destination.metadata.current.logical,
            );
            destination.metadata.current.cleanup_seal = rebindOwnedSeal(
                take.cleanup_seal.?,
                &destination.metadata.current.cleanup,
            );
            bindOwnerMetadataAuthority(destination);
        },
    }
    prepared.metadata = .unavailable;
    prepared.prepared_footprint = .{
        .resident_delta = 0,
        .prepare_peak_delta = 0,
    };
    prepared.lifecycle = .committed_tombstone;
    take.* = .{ .lifecycle = .committed_tombstone };
}

fn initialMetadataSourcesMatch(
    take: *const PreparedOwnerMetadataTake,
    initial: *const runtime_metadata_wire.InitialMetadataSeed,
    cleanup: *const runtime_metadata_wire.InitialMetadataSeed,
) bool {
    const primary = switch (initial.*) {
        .current => |*dto| dto,
        else => return false,
    };
    const mirror = switch (cleanup.*) {
        .current => |*dto| dto,
        else => return false,
    };
    return take.primary_seal != null and take.cleanup_seal != null and
        sameOwnedMetadataBacking(primary, mirror) and
        runtime_metadata_wire.validateOwnedMetadataSeal(
            take.primary_seal.?,
            primary,
        ) and
        runtime_metadata_wire.validateOwnedMetadataSeal(
            take.cleanup_seal.?,
            mirror,
        ) and runtime_metadata_wire.OwnedMetadataDto.semanticEql(primary, mirror);
}

fn rebindOwnedSeal(
    source: runtime_metadata_wire.OwnedMetadataSeal,
    destination: *const runtime_metadata_wire.OwnedMetadataDto,
) runtime_metadata_wire.OwnedMetadataSeal {
    var rebound = source;
    rebound.dto_addr = @intFromPtr(destination);
    return rebound;
}

fn bindOwnerMetadataAuthority(owner: *OwnerMetadataState) void {
    const current = &owner.metadata.current;
    const seal = OwnerMetadataAuthoritySeal{
        .domain = owner_metadata_seal_domain,
        .version = owner_metadata_seal_version,
        .owner_addr = @intFromPtr(owner),
        .storage_addr = owner.storage_addr,
        .logical_addr = @intFromPtr(&current.logical),
        .cleanup_addr = @intFromPtr(&current.cleanup),
        .allocator_ptr_addr = current.logical_seal.allocator_ptr_addr,
        .allocator_vtable_addr = current.logical_seal.allocator_vtable_addr,
        .backing_present = current.logical_seal.backing_present,
        .backing_addr = current.logical_seal.backing_addr,
        .backing_len = current.logical_seal.backing_len,
        .revision = current.logical_seal.revision,
        .raw_digest = current.logical_seal.raw_digest,
        .semantic_digest = current.logical_seal.semantic_digest,
        .authority_digest = undefined,
    };
    var sealed = seal;
    sealed.authority_digest = ownerMetadataAuthorityDigest(sealed);
    current.owner_seal = sealed;
    current.cleanup_owner_seal = sealed;
}

fn ownerMetadataAuthorityPairValid(
    owner: *const OwnerMetadataState,
    current: *const OwnerMetadataCurrent,
) bool {
    const primary_valid = ownerMetadataAuthorityValid(
        owner,
        current,
        current.owner_seal,
    );
    const cleanup_valid = ownerMetadataAuthorityValid(
        owner,
        current,
        current.cleanup_owner_seal,
    );
    if (primary_valid and cleanup_valid)
        return std.meta.eql(current.owner_seal, current.cleanup_owner_seal);
    return primary_valid or cleanup_valid;
}

fn ownerMetadataAuthorityValid(
    owner: *const OwnerMetadataState,
    current: *const OwnerMetadataCurrent,
    authority: OwnerMetadataAuthoritySeal,
) bool {
    // Explicit scalar equality is the authority. The digest is only a domain-separated drift
    // detector, so an injected digest collision cannot bypass any address/backing comparison.
    return authority.domain == owner_metadata_seal_domain and
        authority.version == owner_metadata_seal_version and
        authority.owner_addr == @intFromPtr(owner) and
        authority.storage_addr == owner.storage_addr and
        authority.storage_addr != 0 and
        authority.logical_addr == @intFromPtr(&current.logical) and
        authority.cleanup_addr == @intFromPtr(&current.cleanup) and
        std.mem.eql(
            u8,
            &authority.authority_digest,
            &ownerMetadataAuthorityDigest(authority),
        );
}

fn ownerMetadataCandidateValid(
    owner: *const OwnerMetadataState,
    current: *const OwnerMetadataCurrent,
    authority: OwnerMetadataAuthoritySeal,
    seal: runtime_metadata_wire.OwnedMetadataSeal,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) bool {
    // This comparison is descriptor-only. In particular, it does not hash or slice backing
    // bytes. Content validation is reached only for the independently sealed expected backing.
    if (!ownerMetadataAuthorityValid(owner, current, authority) or
        authority.allocator_ptr_addr != seal.allocator_ptr_addr or
        authority.allocator_vtable_addr != seal.allocator_vtable_addr or
        authority.backing_present != seal.backing_present or
        authority.backing_addr != seal.backing_addr or
        authority.backing_len != seal.backing_len or
        authority.revision != seal.revision or
        !std.mem.eql(u8, &authority.raw_digest, &seal.raw_digest) or
        !std.mem.eql(u8, &authority.semantic_digest, &seal.semantic_digest) or
        !runtime_metadata_wire.validateOwnedMetadataDescriptor(seal, dto))
        return false;
    return runtime_metadata_wire.validateOwnedMetadataSeal(seal, dto);
}

fn ownerMetadataAuthorityDigest(
    authority: OwnerMetadataAuthoritySeal,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("maru.owner-metadata.v1");
    writer.writeU64(authority.domain);
    writer.writeU16(authority.version);
    writer.writeUsize(authority.owner_addr);
    writer.writeUsize(authority.storage_addr);
    writer.writeUsize(authority.logical_addr);
    writer.writeUsize(authority.cleanup_addr);
    writer.writeUsize(authority.allocator_ptr_addr);
    writer.writeUsize(authority.allocator_vtable_addr);
    writer.writeBool(authority.backing_present);
    writer.writeUsize(authority.backing_addr);
    writer.writeUsize(authority.backing_len);
    writer.writeU64(authority.revision);
    for (authority.raw_digest) |byte| writer.writeU8(byte);
    for (authority.semantic_digest) |byte| writer.writeU8(byte);
    return writer.finish();
}

fn sameOwnedMetadataBacking(
    primary: *const runtime_metadata_wire.OwnedMetadataDto,
    mirror: *const runtime_metadata_wire.OwnedMetadataDto,
) bool {
    return std.meta.eql(primary.allocator, mirror.allocator) and
        (primary.backing != null) == (mirror.backing != null) and
        (if (primary.backing) |bytes| @intFromPtr(bytes.ptr) else 0) ==
            (if (mirror.backing) |bytes| @intFromPtr(bytes.ptr) else 0) and
        (if (primary.backing) |bytes| bytes.len else 0) ==
            (if (mirror.backing) |bytes| bytes.len else 0);
}

fn rangeOverlapsMetadataBacking(
    start: usize,
    len: usize,
    prepared: *const Prepared,
    initial: *const runtime_metadata_wire.InitialMetadataSeed,
    cleanup: *const runtime_metadata_wire.InitialMetadataSeed,
) bool {
    if (seedBackingOverlaps(start, len, initial) or
        seedBackingOverlaps(start, len, cleanup))
        return true;
    return switch (prepared.metadata) {
        .event => |*event| (if (event.logical) |*dto|
            dtoBackingOverlaps(start, len, dto)
        else
            false) or (if (event.cleanup) |*dto|
            dtoBackingOverlaps(start, len, dto)
        else
            false),
        else => false,
    };
}

fn seedBackingOverlaps(
    start: usize,
    len: usize,
    seed: *const runtime_metadata_wire.InitialMetadataSeed,
) bool {
    return switch (seed.*) {
        .current => |*dto| dtoBackingOverlaps(start, len, dto),
        else => false,
    };
}

fn dtoBackingOverlaps(
    start: usize,
    len: usize,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) bool {
    const backing = dto.backing orelse return false;
    return rangesOverlap(start, len, @intFromPtr(backing.ptr), backing.len);
}

pub const RetryableReason = enum { out_of_memory };
pub const TerminalReason = enum {
    inconsistent_source,
    resource_exhausted,
    internal_invariant,
};

pub const PrepareResult = union(enum) {
    prepared: PreparedMetadataFootprint,
    retryable_preserved: RetryableReason,
    terminal: TerminalReason,
};

pub fn prepareInPlace(
    out: *Prepared,
    allocator: std.mem.Allocator,
    client: *const client_mod.Client,
    input: client_mod.ExternalAdoptionFoldInput,
    decision: decision_mod.PreparedSourceDecision,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) PrepareResult {
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(Prepared),
        @intFromPtr(client),
        @sizeOf(client_mod.Client),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(Prepared),
        @intFromPtr(scratch),
        @sizeOf(client_mod.ExternalSourceOwnerRangeScratch),
    ))
        return .{ .terminal = .internal_invariant };
    client.preflightExternalAdoptionDestinationWithScratch(
        out,
        @sizeOf(Prepared),
        scratch,
    ) catch return .{ .terminal = .internal_invariant };
    if (!std.meta.eql(out.*, Prepared{}) or
        !std.meta.eql(allocator, client.allocator))
        return .{ .terminal = .internal_invariant };
    if (!decision_mod.decisionMatches(client, input, decision, scratch))
        return .{ .terminal = .inconsistent_source };
    const live = switch (decision.verdict) {
        .adopted => |live| live,
        else => return .{ .terminal = .inconsistent_source },
    };

    out.saved_self_addr = @intFromPtr(out);
    out.lifecycle = .prepared;
    switch (live.metadata) {
        .unsupported => {
            out.metadata = .unsupported;
            out.prepared_footprint = .{
                .resident_delta = 0,
                .prepare_peak_delta = 0,
            };
        },
        .unavailable => {
            out.metadata = .unavailable;
            out.prepared_footprint = .{
                .resident_delta = 0,
                .prepare_peak_delta = 0,
            };
        },
        .initial => {
            const binding = decision.fold.binding_seal.initial_metadata;
            const footprint = initialResidentFootprint(binding) orelse {
                out.deinit();
                return .{ .terminal = .inconsistent_source };
            };
            out.metadata = .{ .initial = binding };
            out.prepared_footprint = footprint;
        },
        .event => |candidate| {
            var dto = client.materializeExternalMetadataEvent(
                allocator,
                input,
                decision.fold,
                candidate,
                scratch,
            ) catch |err| {
                out.deinit();
                return switch (err) {
                    error.OutOfMemory => if (decision_mod.decisionMatches(
                        client,
                        input,
                        decision,
                        scratch,
                    ))
                        .{ .retryable_preserved = .out_of_memory }
                    else
                        .{ .terminal = .inconsistent_source },
                    error.ResourceExhausted => .{ .terminal = .resource_exhausted },
                    else => .{ .terminal = .inconsistent_source },
                };
            };
            defer dto.deinit();
            const footprint = eventFootprint(
                decision.fold.binding_seal.initial_metadata,
                &dto,
            ) orelse {
                out.deinit();
                return .{ .terminal = .resource_exhausted };
            };
            out.metadata = .{ .event = .{} };
            if (!out.metadata.event.initInPlace(&dto, candidate, footprint)) {
                out.deinit();
                return .{ .terminal = .internal_invariant };
            }
            out.prepared_footprint = footprint;
        },
    }
    if (!decision_mod.decisionMatches(client, input, decision, scratch) or
        !out.validate(client, input, decision, scratch))
    {
        out.deinit();
        return .{ .terminal = .inconsistent_source };
    }
    return .{ .prepared = out.footprint(
        client,
        input,
        decision,
        scratch,
    ) orelse {
        out.deinit();
        return .{ .terminal = .internal_invariant };
    } };
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @addWithOverflow(a_start, a_len);
    const b_end = @addWithOverflow(b_start, b_len);
    if (a_end[1] != 0 or b_end[1] != 0) return true;
    return a_start < b_end[0] and b_start < a_end[0];
}

fn canonicalDescriptorMatches(
    owner: *const PreparedOwnedMetadata,
    seal: ?runtime_metadata_wire.OwnedMetadataSeal,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) bool {
    const value = seal orelse return false;
    return owner.allocator_ptr_addr == value.allocator_ptr_addr and
        owner.allocator_vtable_addr == value.allocator_vtable_addr and
        owner.backing_present == value.backing_present and
        owner.backing_addr == value.backing_addr and
        owner.backing_len == value.backing_len and
        runtime_metadata_wire.validateOwnedMetadataDescriptor(value, dto);
}

fn eventResidentBytes(
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) usize {
    return std.math.add(
        usize,
        @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
        if (dto.backing) |bytes| bytes.len else 0,
    ) catch std.math.maxInt(usize);
}

fn footprintIsZero(footprint: PreparedMetadataFootprint) bool {
    return footprint.resident_delta == 0 and
        footprint.prepare_peak_delta == 0;
}

fn initialResidentFootprint(
    binding: client_mod.InitialMetadataBindingSeal,
) ?PreparedMetadataFootprint {
    return switch (binding) {
        .current => |current| blk: {
            if (current.seal.tag != .current or
                current.seed_address != current.seal.seed_addr)
                return null;
            const resident = std.math.add(
                usize,
                @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
                current.seal.backing_len,
            ) catch return null;
            break :blk .{
                .resident_delta = resident,
                .prepare_peak_delta = resident,
            };
        },
        .unsupported, .unavailable => null,
    };
}

fn eventFootprint(
    binding: client_mod.InitialMetadataBindingSeal,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) ?PreparedMetadataFootprint {
    const event_resident = eventResidentBytes(dto);
    if (event_resident == std.math.maxInt(usize)) return null;
    const initial_resident = switch (binding) {
        .unsupported, .unavailable => 0,
        .current => |current| blk: {
            if (current.seal.tag != .current or
                current.seed_address != current.seal.seed_addr)
                return null;
            break :blk std.math.add(
                usize,
                @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
                current.seal.backing_len,
            ) catch return null;
        },
    };
    return .{
        .resident_delta = event_resident,
        .prepare_peak_delta = std.math.add(
            usize,
            initial_resident,
            event_resident,
        ) catch return null,
    };
}

const TestClient = struct {
    client: client_mod.Client,
    peer_fd: c.fd_t,

    fn init(allocator: std.mem.Allocator) !TestClient {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .wire_major = protocol.version_major,
            .parser = framing.FrameParser.init(allocator),
        };
        errdefer {
            client.deinit();
            _ = c.close(fds[1]);
        }
        try client.enterExternalMode();
        client.ownership = .external_pump;
        client.connection_profile = .cli_attach;
        client.compatibility_profile =
            compatibility.profileForMajor(protocol.version_major).?;
        client.attach_instance_id = 77;
        return .{ .client = client, .peer_fd = fds[1] };
    }

    fn deinit(self: *TestClient) void {
        self.client.deinit();
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

const MutatingFailAllocator = struct {
    parent: std.mem.Allocator,
    source: *client_mod.Client,
    fired: bool = false,

    fn allocator(self: *MutatingFailAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        _: usize,
        _: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const self: *MutatingFailAllocator = @ptrCast(@alignCast(context));
        if (!self.fired) {
            self.fired = true;
            self.source.pending_events.items[0].payload[0] ^= 1;
        }
        return null;
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
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *MutatingFailAllocator = @ptrCast(@alignCast(context));
        self.parent.vtable.free(
            self.parent.ptr,
            bytes,
            alignment,
            return_address,
        );
    }
};

const ReentrantOwnerAllocator = struct {
    parent: std.mem.Allocator,
    owner: ?*OwnerMetadataState = null,
    free_calls: usize = 0,
    fired: bool = false,

    fn allocator(self: *ReentrantOwnerAllocator) std.mem.Allocator {
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
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantOwnerAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ReentrantOwnerAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            bytes,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantOwnerAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            bytes,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ReentrantOwnerAllocator = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        if (!self.fired) {
            self.fired = true;
            if (self.owner) |owner| owner.deinitCommitted();
        }
        self.parent.vtable.free(
            self.parent.ptr,
            bytes,
            alignment,
            return_address,
        );
    }
};

test "prepared metadata scalar winners allocate nothing and stay address bound" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try TestClient.init(counting.allocator());
    defer fixture.deinit();
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unsupported,
    };
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    const allocations_before = counting.allocations;
    var prepared: Prepared = .{};
    defer prepared.deinit();
    const result = prepareInPlace(
        &prepared,
        counting.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.resident_delta);
    try std.testing.expectEqual(allocations_before, counting.allocations);
    try std.testing.expect(prepared.metadata == .unsupported);

    var moved = prepared;
    moved.deinit();
    try std.testing.expect(prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
}

test "prepare rejects a destination nested inside Client-owned payload before writing it" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unsupported,
    };
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    const allocation = try allocator.alloc(
        u8,
        @sizeOf(Prepared) + @alignOf(Prepared),
    );
    const aligned_addr = std.mem.alignForward(
        usize,
        @intFromPtr(allocation.ptr),
        @alignOf(Prepared),
    );
    const out: *Prepared = @ptrFromInt(aligned_addr);
    out.* = .{};
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(allocation.len),
        },
        .payload = allocation,
    });
    fixture.client.pending_event_bytes = allocation.len;
    const before = try allocator.dupe(u8, allocation);
    defer allocator.free(before);
    const result = prepareInPlace(
        out,
        allocator,
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .terminal);
    try std.testing.expect(result.terminal == .internal_invariant);
    try std.testing.expectEqualSlices(u8, before, allocation);
}

test "prepared metadata owns only the exact event winner and rejects stale decisions" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":\"host\",\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    try std.testing.expect(decision.verdict == .adopted);
    try std.testing.expect(decision.verdict.adopted.metadata == .event);

    var prepared: Prepared = .{};
    defer prepared.deinit();
    const result = prepareInPlace(
        &prepared,
        allocator,
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .prepared);
    try std.testing.expect(result.prepared.resident_delta >=
        @sizeOf(runtime_metadata_wire.OwnedMetadataDto));
    try std.testing.expectEqual(
        result.prepared.resident_delta,
        result.prepared.prepare_peak_delta,
    );
    try std.testing.expectEqualStrings(
        "/repo",
        prepared.metadata.event.logical.?.cwd(),
    );
    try std.testing.expect(prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
    prepared.prepared_footprint.resident_delta -= 1;
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
    try std.testing.expect(prepared.footprint(
        &fixture.client,
        input,
        decision,
        &scratch,
    ) == null);
    prepared.prepared_footprint.resident_delta += 1;

    // A self-consistent replacement DTO and matching mutable mirror seals are still rejected
    // because validation rebinds the owner to the exact live decision candidate.
    prepared.metadata.event.cleanup.?.deinit();
    var alternate_seed = try runtime_metadata_wire.testingCurrentSeed(allocator);
    alternate_seed.current.backing.?[0] = 'X';
    var alternate = alternate_seed.current.take();
    alternate_seed.deinit();
    defer alternate.deinit();
    const replacement = alternate.take();
    prepared.metadata.event.logical = replacement;
    prepared.metadata.event.cleanup = replacement;
    prepared.metadata.event.allocator_ptr_addr =
        @intFromPtr(replacement.allocator.ptr);
    prepared.metadata.event.allocator_vtable_addr =
        @intFromPtr(replacement.allocator.vtable);
    prepared.metadata.event.backing_present = replacement.backing != null;
    prepared.metadata.event.backing_addr =
        if (replacement.backing) |bytes| @intFromPtr(bytes.ptr) else 0;
    prepared.metadata.event.backing_len =
        if (replacement.backing) |bytes| bytes.len else 0;
    prepared.metadata.event.logical_seal =
        try runtime_metadata_wire.sealOwnedMetadataDto(
            &prepared.metadata.event.logical.?,
        );
    prepared.metadata.event.cleanup_seal =
        try runtime_metadata_wire.sealOwnedMetadataDto(
            &prepared.metadata.event.cleanup.?,
        );
    const replacement_footprint = eventFootprint(
        decision.fold.binding_seal.initial_metadata,
        &prepared.metadata.event.logical.?,
    ).?;
    prepared.metadata.event.footprint = replacement_footprint;
    prepared.prepared_footprint = replacement_footprint;
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));

    fixture.client.pending_events.items[0].payload[
        std.mem.indexOf(u8, payload, "/repo").? + 1
    ] = 'R';
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
}

test "event materialization reports unchanged allocation failure as retryable" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    const saved_allocator = fixture.client.allocator;
    const saved_parser_allocator = fixture.client.parser.allocator;
    fixture.client.allocator = failing.allocator();
    fixture.client.parser.allocator = failing.allocator();
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    var prepared: Prepared = .{};
    const result = prepareInPlace(
        &prepared,
        failing.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    fixture.client.allocator = saved_allocator;
    fixture.client.parser.allocator = saved_parser_allocator;
    try std.testing.expect(result == .retryable_preserved);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(prepared.lifecycle == .aborted_tombstone);
    try std.testing.expect(prepared.metadata == .unavailable);
}

test "allocation failure after source mutation is terminal rather than retryable" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var probe = MutatingFailAllocator{
        .parent = allocator,
        .source = &fixture.client,
    };
    const saved_allocator = fixture.client.allocator;
    const saved_parser_allocator = fixture.client.parser.allocator;
    fixture.client.allocator = probe.allocator();
    fixture.client.parser.allocator = probe.allocator();
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    var prepared: Prepared = .{};
    const result = prepareInPlace(
        &prepared,
        probe.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    fixture.client.allocator = saved_allocator;
    fixture.client.parser.allocator = saved_parser_allocator;
    try std.testing.expect(probe.fired);
    try std.testing.expect(result == .terminal);
    try std.testing.expect(result.terminal == .inconsistent_source);
    try std.testing.expect(prepared.lifecycle == .aborted_tombstone);
}

test "prepared event cleanup falls back to the sealed mirror exactly once" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var seed = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var dto = seed.current.take();
    seed.deinit();
    defer dto.deinit();
    const resident = @sizeOf(runtime_metadata_wire.OwnedMetadataDto) +
        (if (dto.backing) |bytes| bytes.len else 0);
    var owned: PreparedOwnedMetadata = .{};
    try std.testing.expect(owned.initInPlace(
        &dto,
        try testMetadataCandidate(),
        .{
            .resident_delta = resident,
            .prepare_peak_delta = resident,
        },
    ));
    owned.logical.?.revision += 1;
    const frees_before = counting.deallocations;
    owned.deinit();
    owned.deinit();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
    try std.testing.expect(owned.lifecycle == .aborted_tombstone);
    try std.testing.expect(owned.logical == null);
    try std.testing.expect(owned.cleanup == null);
}

test "prepared event cleanup never follows a poisoned canonical allocator seal" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var seed = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var dto = seed.current.take();
    seed.deinit();
    defer dto.deinit();
    const resident = eventResidentBytes(&dto);
    var owned: PreparedOwnedMetadata = .{};
    try std.testing.expect(owned.initInPlace(
        &dto,
        try testMetadataCandidate(),
        .{
            .resident_delta = resident,
            .prepare_peak_delta = resident,
        },
    ));
    var recovery = owned.logical.?;
    owned.allocator_ptr_addr +%= 1;
    const frees_before = counting.deallocations;
    owned.deinit();
    try std.testing.expectEqual(frees_before, counting.deallocations);
    recovery.deinit();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
}

test "event prepare peak is exact initial baseline plus staged winner" {
    const allocator = std.testing.allocator;
    var initial = try runtime_metadata_wire.testingCurrentSeed(allocator);
    defer initial.deinit();
    var initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    initial_seal.backing_len = 4096;
    const binding = client_mod.InitialMetadataBindingSeal{ .current = .{
        .seed_address = @intFromPtr(&initial),
        .seal = initial_seal,
    } };

    var event = try runtime_metadata_wire.testingCurrentSeed(allocator);
    defer event.deinit();
    const event_resident = eventResidentBytes(&event.current);
    const initial_resident = @sizeOf(runtime_metadata_wire.OwnedMetadataDto) +
        initial_seal.backing_len;
    const footprint = eventFootprint(binding, &event.current).?;
    try std.testing.expectEqual(event_resident, footprint.resident_delta);
    try std.testing.expectEqual(
        initial_resident + event_resident,
        footprint.prepare_peak_delta,
    );
    try std.testing.expect(footprint.prepare_peak_delta >
        footprint.resident_delta * 2);
}

test "c3c-2b1 metadata destination takes unsupported without allocation" {
    var prepared: Prepared = .{
        .metadata = .unsupported,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var initial: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var cleanup: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var owner: OwnerMetadataState = .{};
    owner.storage_addr = @intFromPtr(&prepared);
    var rejected_take: PreparedOwnerMetadataTake = .{};
    try std.testing.expectError(
        error.InvalidOwnerTake,
        prepareOwnerMetadataTake(
            &rejected_take,
            &prepared,
            &initial,
            &cleanup,
            &owner,
            @intFromPtr(&prepared),
        ),
    );
    try std.testing.expectEqual(@intFromPtr(&prepared), owner.storage_addr);
    owner = .{};
    var aborted_take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &aborted_take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    aborted_take.abort();
    try std.testing.expect(!aborted_take.validate(
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    ));
    try std.testing.expect(owner.isEmpty());
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    try std.testing.expect(take.validate(
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    ));
    commitOwnerMetadataTakeNoFail(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
    );
    try std.testing.expect(owner.metadata == .unsupported);
    try std.testing.expect(owner.isCommitted());
    try std.testing.expect(prepared.lifecycle == .committed_tombstone);
    owner.deinitCommitted();
}

test "c3c-2b1 metadata destination preserves unavailable as a committed tag" {
    var prepared: Prepared = .{
        .metadata = .unavailable,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var initial: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var cleanup: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    commitOwnerMetadataTakeNoFail(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
    );
    try std.testing.expect(owner.metadata == .unavailable);
    try std.testing.expect(owner.isCommitted());
    owner.deinitCommitted();
}

test "c3c-2b1 metadata destination takes initial DTO and frees its mirror exactly once" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var initial = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var cleanup = initial;
    const initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    var prepared: Prepared = .{
        .metadata = .{ .initial = .{ .current = .{
            .seed_address = @intFromPtr(&initial),
            .seal = initial_seal,
        } } },
        .prepared_footprint = initialResidentFootprint(
            .{ .current = .{
                .seed_address = @intFromPtr(&initial),
                .seal = initial_seal,
            } },
        ).?,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    var moved_owner = owner;
    try std.testing.expect(!take.validate(
        &prepared,
        &initial,
        &cleanup,
        &moved_owner,
        @intFromPtr(&prepared),
    ));
    // The prepared suffix remains valid with the very next allocation forced to fail.
    counting.fail_index = counting.alloc_index;
    commitOwnerMetadataTakeNoFail(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
    );
    try std.testing.expect(initial == .unavailable);
    try std.testing.expect(cleanup == .unavailable);
    try std.testing.expect(owner.metadata == .current);
    try std.testing.expect(owner.metadata.current.pending);
    owner.metadata.current.logical.revision += 1;
    const frees_before = counting.deallocations;
    owner.deinitCommitted();
    owner.deinitCommitted();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
}

test "c3c-2b1 metadata cleanup uses backing authority before forged pointer content" {
    const Scenario = enum {
        primary_invalid,
        cleanup_invalid,
        primary_seal_poison,
        primary_authority_poison,
        digest_collision,
        both_invalid,
    };
    inline for ([_]Scenario{
        .primary_invalid,
        .cleanup_invalid,
        .primary_seal_poison,
        .primary_authority_poison,
        .digest_collision,
        .both_invalid,
    }) |scenario| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var initial = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
        var cleanup = initial;
        const initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
        var prepared: Prepared = .{
            .metadata = .{ .initial = .{ .current = .{
                .seed_address = @intFromPtr(&initial),
                .seal = initial_seal,
            } } },
            .prepared_footprint = initialResidentFootprint(
                .{ .current = .{
                    .seed_address = @intFromPtr(&initial),
                    .seal = initial_seal,
                } },
            ).?,
            .lifecycle = .prepared,
        };
        prepared.saved_self_addr = @intFromPtr(&prepared);
        var owner: OwnerMetadataState = .{};
        var take: PreparedOwnerMetadataTake = .{};
        try prepareOwnerMetadataTake(
            &take,
            &prepared,
            &initial,
            &cleanup,
            &owner,
            @intFromPtr(&prepared),
        );
        commitOwnerMetadataTakeNoFail(
            &take,
            &prepared,
            &initial,
            &cleanup,
            &owner,
        );
        const original = owner.metadata.current.logical;
        const invalid: []u8 = @as([*]u8, @ptrFromInt(0x9000))[0..original.backing.?.len];
        switch (scenario) {
            .primary_invalid, .both_invalid => {
                owner.metadata.current.logical.backing = invalid;
                owner.metadata.current.logical_seal.backing_addr = 0x9000;
                owner.metadata.current.logical_seal.backing_len = invalid.len;
            },
            else => {},
        }
        if (scenario == .primary_seal_poison) {
            owner.metadata.current.logical.revision += 1;
            owner.metadata.current.logical_seal.revision =
                owner.metadata.current.logical.revision;
        }
        if (scenario == .primary_authority_poison)
            owner.metadata.current.owner_seal.version +%= 1;
        if (scenario == .digest_collision) {
            // Preserve both old digests while changing an explicit semantic scalar. A forced
            // digest collision must still leave no allocator authority.
            owner.metadata.current.owner_seal.backing_len +%= 1;
            owner.metadata.current.cleanup_owner_seal.backing_len +%= 1;
        }
        switch (scenario) {
            .cleanup_invalid, .both_invalid => {
                owner.metadata.current.cleanup.backing = invalid;
                owner.metadata.current.cleanup_seal.backing_addr = 0x9000;
                owner.metadata.current.cleanup_seal.backing_len = invalid.len;
            },
            else => {},
        }
        const frees_before = counting.deallocations;
        owner.deinitCommitted();
        const expected: usize =
            if (scenario == .both_invalid or scenario == .digest_collision) 0 else 1;
        try std.testing.expectEqual(frees_before + expected, counting.deallocations);
        if (scenario == .both_invalid or scenario == .digest_collision) {
            var recovery = original;
            recovery.deinit();
        }
    }
}

test "c3c-2b1 metadata cleanup tombstones before allocator reentry" {
    var reentrant = ReentrantOwnerAllocator{ .parent = std.testing.allocator };
    var initial = try runtime_metadata_wire.testingCurrentSeed(reentrant.allocator());
    var cleanup = initial;
    const initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    var prepared: Prepared = .{
        .metadata = .{ .initial = .{ .current = .{
            .seed_address = @intFromPtr(&initial),
            .seal = initial_seal,
        } } },
        .prepared_footprint = initialResidentFootprint(
            .{ .current = .{
                .seed_address = @intFromPtr(&initial),
                .seal = initial_seal,
            } },
        ).?,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    commitOwnerMetadataTakeNoFail(&take, &prepared, &initial, &cleanup, &owner);
    reentrant.owner = &owner;
    owner.deinitCommitted();
    try std.testing.expectEqual(@as(usize, 1), reentrant.free_calls);
    try std.testing.expect(owner.lifecycle == .cleaned_tombstone);
}

test "c3c-2b1 metadata initial cleanup mirror must be the exact same backing" {
    var primary = try runtime_metadata_wire.testingCurrentSeed(std.testing.allocator);
    defer primary.deinit();
    var independent = try runtime_metadata_wire.testingCurrentSeed(std.testing.allocator);
    defer independent.deinit();
    const primary_seal = try runtime_metadata_wire.sealMetadataSeed(&primary);
    var prepared: Prepared = .{
        .metadata = .{ .initial = .{ .current = .{
            .seed_address = @intFromPtr(&primary),
            .seal = primary_seal,
        } } },
        .prepared_footprint = initialResidentFootprint(
            .{ .current = .{
                .seed_address = @intFromPtr(&primary),
                .seal = primary_seal,
            } },
        ).?,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try std.testing.expectError(
        error.InvalidOwnerTake,
        prepareOwnerMetadataTake(
            &take,
            &prepared,
            &primary,
            &independent,
            &owner,
            @intFromPtr(&prepared),
        ),
    );
}

test "c3c-2b1 metadata take rejects stale source and destination backing overlap" {
    var initial = try runtime_metadata_wire.testingCurrentSeed(std.testing.allocator);
    defer initial.deinit();
    var cleanup = initial;
    const initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    var prepared: Prepared = .{
        .metadata = .{ .initial = .{ .current = .{
            .seed_address = @intFromPtr(&initial),
            .seal = initial_seal,
        } } },
        .prepared_footprint = initialResidentFootprint(
            .{ .current = .{
                .seed_address = @intFromPtr(&initial),
                .seal = initial_seal,
            } },
        ).?,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    prepared.saved_self_addr +%= 1;
    try std.testing.expect(!take.validate(
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    ));
    prepared.saved_self_addr = @intFromPtr(&prepared);

    const backing = initial.current.backing.?;
    const overlap_addr = std.mem.alignBackward(
        usize,
        @intFromPtr(backing.ptr) + backing.len - 1,
        @alignOf(OwnerMetadataState),
    );
    const overlap_owner: *OwnerMetadataState = @ptrFromInt(overlap_addr);
    var overlap_take: PreparedOwnerMetadataTake = .{};
    try std.testing.expectError(
        error.InvalidOwnerTake,
        prepareOwnerMetadataTake(
            &overlap_take,
            &prepared,
            &initial,
            &cleanup,
            overlap_owner,
            @intFromPtr(&prepared),
        ),
    );
    // Exact-end adjacency is accepted while moving the destination back by one byte is rejected.
    try std.testing.expect(!rangesOverlap(
        @intFromPtr(backing.ptr) + backing.len,
        @sizeOf(OwnerMetadataState),
        @intFromPtr(backing.ptr),
        backing.len,
    ));
    try std.testing.expect(rangesOverlap(
        @intFromPtr(backing.ptr) + backing.len - 1,
        @sizeOf(OwnerMetadataState),
        @intFromPtr(backing.ptr),
        backing.len,
    ));
}

test "c3c-2b1 metadata owner binds the storage parent address" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var initial = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var cleanup = initial;
    const initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    var prepared: Prepared = .{
        .metadata = .{ .initial = .{ .current = .{
            .seed_address = @intFromPtr(&initial),
            .seal = initial_seal,
        } } },
        .prepared_footprint = initialResidentFootprint(
            .{ .current = .{
                .seed_address = @intFromPtr(&initial),
                .seal = initial_seal,
            } },
        ).?,
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    var parent_a: u8 = 0;
    var parent_b: u8 = 0;
    var owner: OwnerMetadataState = .{};
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&parent_a),
    );
    try std.testing.expect(!take.validate(
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&parent_b),
    ));
    commitOwnerMetadataTakeNoFail(&take, &prepared, &initial, &cleanup, &owner);
    const original = owner.metadata.current.logical;
    owner.storage_addr = @intFromPtr(&parent_b);
    const frees_before = counting.deallocations;
    owner.deinitCommitted();
    try std.testing.expectEqual(frees_before, counting.deallocations);
    var recovery = original;
    recovery.deinit();
}

test "c3c-2b1 metadata destination takes materialized event into the same persistent shape" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var seed = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var dto = seed.current.take();
    seed.deinit();
    defer dto.deinit();
    const resident = eventResidentBytes(&dto);
    var prepared: Prepared = .{
        .metadata = .{ .event = .{} },
        .prepared_footprint = .{
            .resident_delta = resident,
            .prepare_peak_delta = resident,
        },
        .lifecycle = .prepared,
    };
    prepared.saved_self_addr = @intFromPtr(&prepared);
    try std.testing.expect(prepared.metadata.event.initInPlace(
        &dto,
        try testMetadataCandidate(),
        prepared.prepared_footprint,
    ));
    var initial: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var cleanup: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var owner: OwnerMetadataState = .{};
    defer owner.deinitCommitted();
    var take: PreparedOwnerMetadataTake = .{};
    try prepareOwnerMetadataTake(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    );
    try std.testing.expect(take.validate(
        &prepared,
        &initial,
        &cleanup,
        &owner,
        @intFromPtr(&prepared),
    ));
    commitOwnerMetadataTakeNoFail(
        &take,
        &prepared,
        &initial,
        &cleanup,
        &owner,
    );
    try std.testing.expect(owner.metadata == .current);
    try std.testing.expect(owner.metadata.current.pending);
    try std.testing.expectEqual(@as(u64, 2), owner.metadata.current.logical.revision);
    const frees_before = counting.deallocations;
    owner.deinitCommitted();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
}

fn testMetadataCandidate() !runtime_event_reducer.MetadataCandidate {
    const payload =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const accepted = switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    const metadata = switch (accepted.event) {
        .metadata => |metadata| metadata,
        else => return error.TestUnexpectedResult,
    };
    return .{
        .origin = .{ .event = 0 },
        .raw_digest = accepted.raw_digest,
        .semantic_digest = .{ .event = metadata.semantic_digest },
        .proof = .{ .event = accepted },
    };
}
