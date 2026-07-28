//! Stable, address-bound storage for the public attach external pump.
//!
//! The storage is initialized only in its caller-owned final address. It keeps the raw Client and
//! inbox ledger behind one lifecycle boundary so later token-bearing slices never need to recover
//! from a moved owner.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const client_external_mode = @import("client_external_mode.zig");
const client_external_adoption = @import("client_external_adoption.zig");
const client_pump = @import("client_pump.zig");
const compatibility = @import("compatibility.zig");
const external_adoption_limits = @import("external_adoption_limits.zig");
const external_event_materialization = @import("external_event_materialization.zig");
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const external_source_decision = @import("external_source_decision.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

pub const AttachmentRole = enum {
    observer,
    controller,
};

/// Immutable evidence captured at attach publication. Live authority is adopted in 2b2c and must
/// not be inferred by mutating this snapshot.
pub const AttachmentEvidence = struct {
    runtime_id: u128,
    stream_id: u64,
    initial_role: AttachmentRole,
    initial_controller_generation: u64,
};

const EvidenceLifecycle = enum { empty, prepared, committed_tombstone, aborted_tombstone };

/// Address-bound owner of one attach's metadata seed, paired with the Client it belongs to.
///
/// `seed` and `cleanup_seed` deliberately describe the **same** allocation. `seed` is the logical
/// value callers read; `cleanup_seed` is the private mirror `deinit` frees from. Keeping both lets a
/// poisoned logical descriptor be rejected without ever dereferencing or freeing it, while the
/// canonical backing is still reclaimed exactly once. They are not redundant — deleting either one
/// breaks the poisoned-descriptor recovery this type exists to provide. Zig has no private fields,
/// so `tests/boundary/imports.zig` is what keeps the mirror out of non-mechanics code.
pub const PreparedAdoptionEvidence = struct {
    saved_self_addr: usize = 0,
    attach_instance_id: u64 = 0,
    sealed_attach_instance_id: u64 = 0,
    source_client_addr: usize = 0,
    attachment: AttachmentEvidence = .{
        .runtime_id = 0,
        .stream_id = 0,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    },
    sealed_attachment: AttachmentEvidence = .{
        .runtime_id = 0,
        .stream_id = 0,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    },
    client_profile: ?client_mod.ExternalTransferProfile = null,
    seed: runtime_metadata_wire.InitialMetadataSeed = .unavailable,
    cleanup_seed: runtime_metadata_wire.InitialMetadataSeed = .unavailable,
    seed_seal: ?runtime_metadata_wire.MetadataSeedSeal = null,
    cleanup_seed_seal: ?runtime_metadata_wire.MetadataSeedSeal = null,
    lifecycle: EvidenceLifecycle = .empty,

    pub fn initFromAttachPartsInPlace(
        out: *PreparedAdoptionEvidence,
        attach_instance_id: u64,
        source: *client_mod.Client,
        attachment: AttachmentEvidence,
        seed: *runtime_metadata_wire.InitialMetadataSeed,
    ) error{ InvalidAlias, InvalidEvidence, OutOfMemory }!void {
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedAdoptionEvidence),
            @intFromPtr(source),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedAdoptionEvidence),
            @intFromPtr(seed),
            @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
        ) or rangesOverlap(
            @intFromPtr(seed),
            @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
            @intFromPtr(source),
            @sizeOf(client_mod.Client),
        )) return error.InvalidAlias;
        source.preflightExternalAdoptionDestination(
            out,
            @sizeOf(PreparedAdoptionEvidence),
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidAlias,
        };
        source.preflightExternalAdoptionDestination(
            seed,
            @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidAlias,
        };
        const source_seal = runtime_metadata_wire.sealMetadataSeed(seed) catch
            return error.InvalidEvidence;
        if (source_seal.backing_len != 0 and rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedAdoptionEvidence),
            source_seal.backing_addr,
            source_seal.backing_len,
        )) return error.InvalidAlias;
        if (source_seal.backing_len != 0 and rangesOverlap(
            @intFromPtr(seed),
            @sizeOf(runtime_metadata_wire.InitialMetadataSeed),
            source_seal.backing_addr,
            source_seal.backing_len,
        )) return error.InvalidAlias;
        if (source_seal.tag == .current and source_seal.backing_len != 0) {
            source.preflightExternalAdoptionDestination(
                @ptrFromInt(source_seal.backing_addr),
                source_seal.backing_len,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidAlias,
            };
        }
        if (!std.meta.eql(out.*, PreparedAdoptionEvidence{}) or
            attach_instance_id == 0 or attachment.runtime_id == 0 or
            attachment.stream_id == 0 or
            attach_instance_id != source.attach_instance_id)
            return error.InvalidEvidence;
        const profile = source.externalTransferProfile() orelse
            return error.InvalidEvidence;
        _ = prepareAuthority(source, attachment) catch return error.InvalidEvidence;
        if (!metadataTagMatches(profile.metadata_support, source_seal.tag))
            return error.InvalidEvidence;

        const taken = seed.take();
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .attach_instance_id = attach_instance_id,
            .sealed_attach_instance_id = attach_instance_id,
            .source_client_addr = @intFromPtr(source),
            .attachment = attachment,
            .sealed_attachment = attachment,
            .client_profile = profile,
            .seed = taken,
            .cleanup_seed = taken,
            .lifecycle = .prepared,
        };
        out.seed_seal = runtime_metadata_wire.sealMetadataSeed(&out.seed) catch
            @panic("prevalidated metadata seed became malformed during no-fail take");
        out.cleanup_seed_seal = runtime_metadata_wire.sealMetadataSeed(&out.cleanup_seed) catch
            @panic("prevalidated cleanup seed became malformed during no-fail take");
    }

    pub fn validate(
        self: *const PreparedAdoptionEvidence,
        source: *const client_mod.Client,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.attach_instance_id == 0 or
            self.attach_instance_id != self.sealed_attach_instance_id or
            self.attach_instance_id != source.attach_instance_id or
            self.source_client_addr != @intFromPtr(source) or
            self.attachment.runtime_id == 0 or
            self.attachment.stream_id == 0 or
            !std.meta.eql(self.attachment, self.sealed_attachment) or
            !std.meta.eql(
                self.client_profile orelse return false,
                source.externalTransferProfile() orelse return false,
            ) or
            !runtime_metadata_wire.validateMetadataSeedSeal(
                self.seed_seal orelse return false,
                &self.seed,
            ) or
            !runtime_metadata_wire.validateMetadataSeedSeal(
                self.cleanup_seed_seal orelse return false,
                &self.cleanup_seed,
            ) or
            !metadataTagMatches(
                (self.client_profile orelse return false).metadata_support,
                (self.seed_seal orelse return false).tag,
            ))
            return false;
        _ = prepareAuthority(source, self.attachment) catch return false;
        return true;
    }

    pub fn deinit(self: *PreparedAdoptionEvidence) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            if (seedMatchesSeal(self.cleanup_seed_seal, &self.cleanup_seed)) {
                self.cleanup_seed.deinit();
            } else if (seedMatchesSeal(self.seed_seal, &self.seed)) {
                self.seed.deinit();
            }
        }
        self.seed = .unavailable;
        self.cleanup_seed = .unavailable;
        self.seed_seal = null;
        self.cleanup_seed_seal = null;
        self.lifecycle = .aborted_tombstone;
    }

    fn moveInto(
        self: *PreparedAdoptionEvidence,
        destination: *PreparedAdoptionEvidence,
        new_source: *const client_mod.Client,
    ) void {
        if (destination.lifecycle != .empty or self.lifecycle != .prepared)
            @panic("invalid prepared adoption evidence move");
        destination.* = self.*;
        destination.saved_self_addr = @intFromPtr(destination);
        destination.source_client_addr = @intFromPtr(new_source);
        destination.seed_seal = runtime_metadata_wire.sealMetadataSeed(&destination.seed) catch
            @panic("validated metadata seed became malformed during no-fail move");
        destination.cleanup_seed_seal = runtime_metadata_wire.sealMetadataSeed(
            &destination.cleanup_seed,
        ) catch @panic("validated cleanup seed became malformed during no-fail move");
        self.seed = .unavailable;
        self.cleanup_seed = .unavailable;
        self.seed_seal = null;
        self.cleanup_seed_seal = null;
        self.lifecycle = .committed_tombstone;
    }
};

fn seedMatchesSeal(
    seal: ?runtime_metadata_wire.MetadataSeedSeal,
    seed: *const runtime_metadata_wire.InitialMetadataSeed,
) bool {
    return if (seal) |value|
        runtime_metadata_wire.validateMetadataSeedDescriptor(value, seed)
    else
        false;
}

fn metadataTagMatches(
    support: runtime_metadata_wire.MetadataSupport,
    tag: runtime_metadata_wire.MetadataSeedTag,
) bool {
    return switch (support) {
        .unsupported => tag == .unsupported,
        .supported => tag == .unavailable or tag == .current,
    };
}

pub const AuthorityGeneration = union(enum) {
    untracked,
    tracked: u64,
};

pub const PreparedAttachmentAuthority = struct {
    role: AttachmentRole,
    generation: AuthorityGeneration,
};

pub const RetryablePrepareReason = enum { out_of_memory };
pub const TerminalPrepareReason = enum {
    protocol,
    resource,
    internal_invariant,
};

pub const PrepareStatus = union(enum) {
    prepared,
    deferred_non_adopted,
    busy,
    retryable_preserved: RetryablePrepareReason,
    terminal: TerminalPrepareReason,
};

const AdoptionLifecycle = EvidenceLifecycle;
const PreparedAdoptionBranch = enum {
    none,
    adopted,
    non_adopted,
};

/// Pump-owned, final-address seal. The neutral module owns only the screen backlog sub-plan; this
/// object binds it to the exact storage, evidence, sealed source decision, and pristine ledger
/// that may publish it in c3.
pub const PreparedExternalAdoption = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    client_addr: usize = 0,
    ledger_addr: usize = 0,
    evidence: AttachmentEvidence = .{
        .runtime_id = 0,
        .stream_id = 0,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    },
    source_decision: ?external_source_decision.PreparedSourceDecision = null,
    metadata: external_event_materialization.Prepared = .{},
    client_take: client_mod.ExternalAdoptionTake = .{},
    aggregate_resident_bytes: usize = 0,
    aggregate_prepare_peak_bytes: usize = 0,
    backlog: client_external_adoption.PreparedScreenBacklog = .{},
    branch: PreparedAdoptionBranch = .none,
    lifecycle: AdoptionLifecycle = .empty,

    fn deinit(self: *PreparedExternalAdoption) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        self.metadata.deinit();
        self.client_take.deinit();
        self.backlog.deinit();
        self.source_decision = null;
        self.aggregate_resident_bytes = 0;
        self.aggregate_prepare_peak_bytes = 0;
        self.branch = .none;
        self.lifecycle = .aborted_tombstone;
    }

    pub fn validate(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
    ) bool {
        return self.validateForStorageLifecycle(storage, .adopting, true);
    }

    fn validateWhilePreparing(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
    ) bool {
        return self.validateForStorageLifecycle(storage, .adoption_preparing, true);
    }

    fn validateWhilePreparingBeforeTake(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
    ) bool {
        return self.validateForStorageLifecycle(storage, .adoption_preparing, false);
    }

    fn validateForStorageLifecycle(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
        expected_storage_lifecycle: StorageLifecycle,
        require_take: bool,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.storage_addr != @intFromPtr(storage) or
            storage.saved_self_addr != @intFromPtr(storage) or
            storage.lifecycle != expected_storage_lifecycle or
            storage.semantic_state != .adopting or
            storage.evidence_snapshot.runtime_id == 0 or
            storage.evidence_snapshot.stream_id == 0 or
            self.ledger_addr != @intFromPtr(&storage.inbox_ledger) or
            !std.meta.eql(self.evidence, storage.evidence_snapshot))
            return false;
        const client = if (storage.owned_client) |*owned| owned else return false;
        const owned_evidence = if (storage.owned_evidence) |*owned| owned else return false;
        if (!owned_evidence.validate(client) or
            !std.meta.eql(owned_evidence.attachment, storage.evidence_snapshot))
            return false;
        if (self.client_addr != @intFromPtr(client)) return false;
        const view = storage.inbox_ledger.accountingView();
        if (!view.valid or !view.pristine_zero) return false;
        const expected_authority = prepareAuthority(client, storage.evidence_snapshot) catch
            return false;
        const input = adoptionFoldInput(owned_evidence, expected_authority) orelse
            return false;
        const decision = self.source_decision orelse return false;
        var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
        if (!external_source_decision.decisionMatches(
            client,
            input,
            decision,
            &scratch,
        )) return false;
        if (decision.verdict != .adopted)
            return self.branch == .non_adopted and
                std.meta.eql(
                    self.metadata,
                    external_event_materialization.Prepared{},
                ) and
                std.meta.eql(
                    self.backlog,
                    client_external_adoption.PreparedScreenBacklog{},
                ) and
                std.meta.eql(self.client_take, client_mod.ExternalAdoptionTake{}) and
                self.aggregate_resident_bytes == 0 and
                self.aggregate_prepare_peak_bytes == 0;
        if (self.branch != .adopted) return false;
        const metadata_footprint = self.metadata.footprint(
            client,
            input,
            decision,
            &scratch,
        ) orelse return false;
        if (self.backlog.targetStream() != self.evidence.stream_id) return false;
        if (!self.backlog.validate(client, &storage.inbox_ledger)) return false;
        if (require_take) {
            if (!self.client_take.validate(
                client,
                &self.backlog.client_disarm,
                &self.backlog.inventory,
                &self.backlog.cleanup_inventory,
            ))
                return false;
        } else if (!std.meta.eql(
            self.client_take,
            client_mod.ExternalAdoptionTake{},
        )) return false;
        const aggregate = aggregateAdoptionFootprint(
            .{
                .resident = self.backlog.adoption_metadata_resident_bytes,
                .prepare_peak = self.backlog.adoption_metadata_prepare_peak_bytes,
            },
            metadata_footprint,
        ) catch return false;
        return self.aggregate_resident_bytes == aggregate.resident and
            self.aggregate_prepare_peak_bytes == aggregate.prepare_peak;
    }
};

const AggregateAdoptionFootprint = struct {
    resident: usize,
    prepare_peak: usize,
};

fn aggregateAdoptionFootprint(
    screen: client_external_adoption.MetadataFootprint,
    metadata: external_event_materialization.PreparedMetadataFootprint,
) error{ResourceExhausted}!AggregateAdoptionFootprint {
    const resident = std.math.add(
        usize,
        screen.resident,
        metadata.resident_delta,
    ) catch return error.ResourceExhausted;
    const prepare_peak = std.math.add(
        usize,
        screen.prepare_peak,
        metadata.prepare_peak_delta,
    ) catch return error.ResourceExhausted;
    if (resident > external_adoption_limits.max_metadata_bytes or
        prepare_peak > external_adoption_limits.max_metadata_bytes)
        return error.ResourceExhausted;
    return .{ .resident = resident, .prepare_peak = prepare_peak };
}

pub const SourceDisposition = enum {
    preserved,
    consumed_and_closed,
};

pub const InitFailureReason = enum {
    destination_not_empty,
    overlapping_storage,
    invalid_evidence,
    connection_closed,
    source_not_external,
    source_already_bound,
    resident_too_large,
    malformed_parser,
    out_of_memory,
    invariant_failure,
};

pub const InitFailure = struct {
    reason: InitFailureReason,
    source_disposition: SourceDisposition,
};

pub const InitResult = union(enum) {
    initialized,
    failed: InitFailure,
};

pub const StorageLifecycle = enum {
    empty,
    constructing,
    normalizing,
    adopting,
    adoption_preparing,
    live,
    tearing_down,
    dead,
};

pub const TeardownResult = enum {
    cleaned,
    already_dead,
    moved_storage,
    busy,
    ledger_not_zero,
};

pub const AccessError = error{
    Empty,
    NotActive,
    Terminal,
    MovedStorage,
};

const InitOptions = struct {
    failpoint: enum {
        none,
        after_paired_take,
    } = .none,
    resident_cap: usize = protocol.max_binary_chunk + protocol.header_size,
};

pub const max_fixed_inline_storage_bytes: usize = 512 * 1024;

// `initInPlace` is thread-confined, but an allocator callback may synchronously re-enter it on the
// same thread before destination alias proof is allowed to read `out`. Keep that earliest latch
// out-of-band so hostile `out` aliases are not dereferenced or mutated before the proof.
threadlocal var initializing_storage_addr: usize = 0;
// Allocation callbacks are arbitrary user code. One prepare transaction therefore excludes
// adoption/teardown on every storage on the same thread, not only recursive calls on itself.
threadlocal var preparing_adoption_addr: usize = 0;

pub const ExternalPumpStorage = struct {
    lifecycle: StorageLifecycle = .empty,
    saved_self_addr: usize = 0,
    semantic_state: client_pump.ExternalPumpState = .constructing,
    evidence_snapshot: AttachmentEvidence = .{
        .runtime_id = 0,
        .stream_id = 0,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    },
    owned_client: ?client_mod.Client = null,
    /// Temporary seed owner. c3c replaces this with the final `OwnerMetadataState`; until then it is
    /// the only thing that owns the metadata seed after the paired take, so teardown must free it.
    owned_evidence: ?PreparedAdoptionEvidence = null,
    /// Staging token for the Client move. It is meaningful only inside `initInPlace`: after
    /// `finishExternalPumpTransfer` it is a spent `.committed` record whose source address has been
    /// cleared, and nothing may read it as a description of live state.
    client_transfer: client_mod.PreparedExternalPumpTransfer = .{},
    inbox_ledger: external_inbox_ledger.ExternalInboxLedger = .{},
    prepared_adoption: PreparedExternalAdoption = .{},

    pub fn initInPlace(
        out: *ExternalPumpStorage,
        source: *client_mod.Client,
        evidence: *PreparedAdoptionEvidence,
    ) InitResult {
        return initInPlaceWithOptions(out, source, evidence, .{});
    }

    fn initInPlaceWithOptions(
        out: *ExternalPumpStorage,
        source: *client_mod.Client,
        evidence: *PreparedAdoptionEvidence,
        options: InitOptions,
    ) InitResult {
        // Pointer arithmetic and overlap rejection happen before interpreting destination fields:
        // a malicious alias must not let an `out.* = ...` overwrite the source Client.
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(ExternalPumpStorage),
            @intFromPtr(source),
            @sizeOf(client_mod.Client),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(ExternalPumpStorage),
            @intFromPtr(evidence),
            @sizeOf(PreparedAdoptionEvidence),
        )) {
            return failed(.overlapping_storage, .preserved);
        }
        const out_addr = @intFromPtr(out);
        if (initializing_storage_addr != 0)
            return failed(.destination_not_empty, .preserved);
        initializing_storage_addr = out_addr;
        defer initializing_storage_addr = 0;
        source.preflightExternalAdoptionDestination(
            evidence,
            @sizeOf(PreparedAdoptionEvidence),
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => failed(.out_of_memory, .preserved),
                else => failed(.overlapping_storage, .preserved),
            };
        };
        const evidence_seed_seal = evidence.seed_seal orelse {
            return failed(.invalid_evidence, .preserved);
        };
        if (evidence_seed_seal.backing_len != 0 and rangesOverlap(
            @intFromPtr(out),
            @sizeOf(ExternalPumpStorage),
            evidence_seed_seal.backing_addr,
            evidence_seed_seal.backing_len,
        )) {
            return failed(.overlapping_storage, .preserved);
        }
        source.preflightExternalAdoptionDestination(
            out,
            @sizeOf(ExternalPumpStorage),
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => failed(.out_of_memory, .preserved),
                error.InvalidAlias => failed(.overlapping_storage, .preserved),
                else => failed(.invariant_failure, .preserved),
            };
        };
        if (out.lifecycle != .empty)
            return failed(.destination_not_empty, .preserved);
        if (!evidence.validate(source)) {
            return failed(.invalid_evidence, .preserved);
        }

        out.* = .{
            .lifecycle = .constructing,
            .saved_self_addr = @intFromPtr(out),
            .semantic_state = .constructing,
            .evidence_snapshot = evidence.attachment,
        };

        source.prepareExternalPumpTransfer(
            &out.client_transfer,
            &out.owned_client,
            options.resident_cap,
        ) catch |err| {
            out.client_transfer.deinit();
            out.* = .{};
            return switch (err) {
                error.ConnectionClosed => failed(.connection_closed, .preserved),
                error.NotExternal => failed(.source_not_external, .preserved),
                error.DestinationOccupied => failed(.destination_not_empty, .preserved),
                error.AlreadyBound => failed(.source_already_bound, .preserved),
                error.ResidentTooLarge => failed(.resident_too_large, .preserved),
                error.MalformedParser => failed(.malformed_parser, .preserved),
                error.OutOfMemory => failed(.out_of_memory, .preserved),
            };
        };
        // The allocations above run arbitrary allocator code. Re-prove that this transaction still
        // owns the destination before trusting any field it published.
        if (out.lifecycle != .constructing or out.saved_self_addr != @intFromPtr(out)) {
            out.client_transfer.deinit();
            return failed(.invariant_failure, .preserved);
        }
        if (!out.client_transfer.validate(source, &out.owned_client) or
            !evidence.validate(source))
        {
            out.client_transfer.deinit();
            out.* = .{};
            return failed(.invalid_evidence, .preserved);
        }
        var owner_proof: client_mod.PreparedExternalOwnerRangeProof = .{};
        var owner_proof_live = false;
        defer if (owner_proof_live) owner_proof.deinit();
        source.prepareExternalOwnerRangeProof(
            &owner_proof,
            out,
            @sizeOf(ExternalPumpStorage),
            evidence,
            @sizeOf(PreparedAdoptionEvidence),
        ) catch |err| {
            out.client_transfer.deinit();
            out.* = .{};
            return switch (err) {
                error.OutOfMemory => failed(.out_of_memory, .preserved),
                else => failed(.invariant_failure, .preserved),
            };
        };
        owner_proof_live = true;
        if (out.lifecycle != .constructing or out.saved_self_addr != @intFromPtr(out)) {
            out.client_transfer.deinit();
            out.* = .{};
            return failed(.invariant_failure, .preserved);
        }
        if (!owner_proof.validate(
            source,
            out,
            @sizeOf(ExternalPumpStorage),
            evidence,
            @sizeOf(PreparedAdoptionEvidence),
        ) or
            !out.client_transfer.validate(source, &out.owned_client) or
            !evidence.validate(source))
        {
            out.client_transfer.deinit();
            out.* = .{};
            return failed(.invalid_evidence, .preserved);
        }

        // No allocation, callback or error is permitted between these two ownership takes.
        source.commitExternalPumpTransfer(
            &out.client_transfer,
            &out.owned_client,
        ) catch {
            out.client_transfer.deinit();
            out.* = .{};
            return failed(.invalid_evidence, .preserved);
        };
        out.owned_evidence = .{};
        evidence.moveInto(&out.owned_evidence.?, &out.owned_client.?);
        out.lifecycle = .normalizing;
        out.semantic_state = .constructing;
        // The final owner-range proof deliberately frees only after both owners moved and the
        // source became a tombstone. Its allocator callback therefore cannot mutate a live source
        // descriptor between validation and the paired take. Public re-entry sees `.normalizing`.
        owner_proof.deinit();
        owner_proof_live = false;
        if (out.lifecycle != .normalizing or out.saved_self_addr != @intFromPtr(out)) {
            _ = out.closeOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        if (options.failpoint == .after_paired_take) {
            _ = out.closeOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        client_mod.Client.finishExternalPumpTransfer(
            &out.client_transfer,
            &out.owned_client,
        );
        out.lifecycle = .adopting;
        out.semantic_state = .adopting;
        return .initialized;
    }

    /// 2b2b never reaches active; this gate prevents a caller from treating successful storage
    /// construction as authority adoption.
    pub fn requireActive(self: *ExternalPumpStorage) AccessError!void {
        try self.requireAddress();
        return switch (self.lifecycle) {
            .empty => error.Empty,
            .adopting, .adoption_preparing, .constructing, .normalizing => error.NotActive,
            .live => switch (self.semantic_state) {
                .active => {},
                .terminal => error.Terminal,
                else => error.NotActive,
            },
            .tearing_down, .dead => error.Terminal,
        };
    }

    pub fn prepareAdoption(self: *ExternalPumpStorage) PrepareStatus {
        if (self.saved_self_addr != @intFromPtr(self))
            return .{ .terminal = .internal_invariant };
        if (preparing_adoption_addr != 0) return .busy;
        if (self.lifecycle != .adopting or self.semantic_state != .adopting or
            self.prepared_adoption.lifecycle != .empty)
            return .{ .terminal = .internal_invariant };
        const client = if (self.owned_client) |*owned| owned else return .{ .terminal = .internal_invariant };
        const owned_evidence = if (self.owned_evidence) |*owned| owned else return .{ .terminal = .internal_invariant };
        if (!owned_evidence.validate(client) or
            !std.meta.eql(owned_evidence.attachment, self.evidence_snapshot))
            return .{ .terminal = .internal_invariant };
        if (self.evidence_snapshot.runtime_id == 0 or
            self.evidence_snapshot.stream_id == 0)
            return .{ .terminal = .protocol };
        const ledger_view = self.inbox_ledger.accountingView();
        if (!ledger_view.valid or !ledger_view.pristine_zero)
            return .{ .terminal = .internal_invariant };
        // The aggregate proof may allocate while walking Client owner ranges. Publish an explicit
        // busy state first so allocator callbacks cannot recursively prepare or tear down the
        // source owner that this transaction is validating.
        self.lifecycle = .adoption_preparing;
        preparing_adoption_addr = @intFromPtr(self);
        defer {
            preparing_adoption_addr = 0;
            if (self.lifecycle == .adoption_preparing)
                self.lifecycle = .adopting;
        }
        client.preflightExternalAdoptionDestination(
            &self.prepared_adoption,
            @sizeOf(PreparedExternalAdoption),
        ) catch |err| return mapPrepareError(err);
        const authority = prepareAuthority(client, self.evidence_snapshot) catch |err|
            return mapAuthorityError(err);
        const input = adoptionFoldInput(owned_evidence, authority) orelse
            return .{ .terminal = .internal_invariant };
        var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
        const fold = client.foldExternalAdoptionSource(
            input,
            &scratch,
        ) catch return .{ .terminal = .internal_invariant };
        const decision = external_source_decision.decide(
            client,
            input,
            fold,
            &scratch,
        );
        self.prepared_adoption = .{
            .saved_self_addr = @intFromPtr(&self.prepared_adoption),
            .storage_addr = @intFromPtr(self),
            .client_addr = @intFromPtr(client),
            .ledger_addr = @intFromPtr(&self.inbox_ledger),
            .evidence = self.evidence_snapshot,
            .source_decision = decision,
        };
        switch (decision.verdict) {
            .adopted => self.prepared_adoption.branch = .adopted,
            else => {
                self.prepared_adoption.branch = .non_adopted;
                self.prepared_adoption.lifecycle = .prepared;
                if (!self.prepared_adoption.validateWhilePreparing(self)) {
                    self.resetPreparedAdoption();
                    return .{ .terminal = .internal_invariant };
                }
                self.lifecycle = .adopting;
                return .deferred_non_adopted;
            },
        }
        const metadata_status = external_event_materialization.prepareInPlace(
            &self.prepared_adoption.metadata,
            client.allocator,
            client,
            input,
            decision,
            &scratch,
        );
        const metadata_footprint = switch (metadata_status) {
            .prepared => |footprint| footprint,
            .retryable_preserved => {
                self.resetPreparedAdoption();
                return .{ .retryable_preserved = .out_of_memory };
            },
            .terminal => |reason| {
                self.resetPreparedAdoption();
                return .{ .terminal = switch (reason) {
                    .resource_exhausted => .resource,
                    .inconsistent_source => .protocol,
                    .internal_invariant => .internal_invariant,
                } };
            },
        };
        client_external_adoption.PreparedScreenBacklog.initInPlace(
            &self.prepared_adoption.backlog,
            client.allocator,
            client,
            &self.inbox_ledger,
            self.evidence_snapshot.stream_id,
        ) catch |err| {
            self.resetPreparedAdoption();
            return mapPrepareError(err);
        };
        const aggregate = aggregateAdoptionFootprint(
            .{
                .resident = self.prepared_adoption.backlog.adoption_metadata_resident_bytes,
                .prepare_peak = self.prepared_adoption.backlog.adoption_metadata_prepare_peak_bytes,
            },
            metadata_footprint,
        ) catch {
            self.resetPreparedAdoption();
            return .{ .terminal = .resource };
        };
        client.sealExternalAdoption(
            &self.prepared_adoption.backlog.client_disarm,
        ) catch {
            self.resetPreparedAdoption();
            return .{ .terminal = .internal_invariant };
        };
        self.prepared_adoption.aggregate_resident_bytes = aggregate.resident;
        self.prepared_adoption.aggregate_prepare_peak_bytes =
            aggregate.prepare_peak;
        self.prepared_adoption.lifecycle = .prepared;
        client.prepareExternalAdoptionTake(
            &self.prepared_adoption.backlog.client_disarm,
            &self.prepared_adoption.backlog.inventory,
            &self.prepared_adoption.backlog.cleanup_inventory,
            &self.prepared_adoption.client_take,
        ) catch |err| {
            const source_unchanged =
                self.prepared_adoption.validateWhilePreparingBeforeTake(self);
            self.resetPreparedAdoption();
            return switch (err) {
                error.OutOfMemory => if (source_unchanged)
                    .{ .retryable_preserved = .out_of_memory }
                else
                    .{ .terminal = .internal_invariant },
                error.InvalidPlan, error.StaleClient => .{
                    .terminal = .internal_invariant,
                },
            };
        };
        if (!self.prepared_adoption.validateWhilePreparing(self)) {
            self.resetPreparedAdoption();
            return .{ .terminal = .internal_invariant };
        }
        self.lifecycle = .adopting;
        return .prepared;
    }

    fn resetPreparedAdoption(self: *ExternalPumpStorage) void {
        self.prepared_adoption.deinit();
        self.prepared_adoption = .{};
    }

    pub fn teardown(self: *ExternalPumpStorage) TeardownResult {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return .moved_storage;
        if (preparing_adoption_addr != 0) return .busy;
        return switch (self.lifecycle) {
            .empty, .dead => .already_dead,
            // Both windows are only observable from inside an in-flight `initInPlace`: every init
            // failure path restores `.empty` and success moves past them. Tearing down here would
            // hand the re-entrant caller a `cleaned` result that the still-running transaction then
            // overwrites, so the transaction stays the sole owner and the caller retries.
            .constructing, .normalizing, .adoption_preparing, .tearing_down => .busy,
            .adopting, .live => self.closeOwned(.invariant_failure),
        };
    }

    fn requireAddress(self: *const ExternalPumpStorage) AccessError!void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return error.MovedStorage;
    }

    fn closeOwned(
        self: *ExternalPumpStorage,
        reason: client_pump.TerminalReason,
    ) TeardownResult {
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        self.prepared_adoption.deinit();
        if (self.owned_client) |*owned| owned.deinit();
        self.owned_client = null;
        if (self.owned_evidence) |*owned| owned.deinit();
        self.owned_evidence = null;
        self.client_transfer.deinit();
        const drain_report = self.inbox_ledger.drainAll();
        const ledger_result = self.inbox_ledger.finish();
        self.lifecycle = .dead;
        if (drain_report.drained_active_count != 0 or
            drain_report.had_sticky_invariant)
            return .ledger_not_zero;
        return if (ledger_result) |_| .cleaned else |_| .ledger_not_zero;
    }
};

const PrepareAuthorityError = error{ ProtocolAuthority, InvariantAuthority };

fn prepareAuthority(
    client: *const client_mod.Client,
    evidence: AttachmentEvidence,
) PrepareAuthorityError!PreparedAttachmentAuthority {
    const selected = client.compatibility_profile orelse return error.InvariantAuthority;
    return switch (selected.attach_schema) {
        .frozen_controller_only => {
            if (selected.kind != compatibility.Kind.previous or
                evidence.initial_role != .controller or
                evidence.initial_controller_generation != 0 or
                client.attachment_capabilities.peer_attach_generation or
                client.attachment_capabilities.negotiated_controller_transfer)
                return error.ProtocolAuthority;
            return .{ .role = .controller, .generation = .untracked };
        },
        .granted_roles => {
            if (client.attachment_capabilities.peer_attach_generation !=
                client.attachment_capabilities.negotiated_controller_transfer)
                return error.InvariantAuthority;
            if (!client.attachment_capabilities.peer_attach_generation) {
                if (evidence.initial_role != .observer or
                    evidence.initial_controller_generation != 0)
                    return error.ProtocolAuthority;
                return .{ .role = .observer, .generation = .untracked };
            }
            if (evidence.initial_role == .controller and
                evidence.initial_controller_generation == 0)
                return error.ProtocolAuthority;
            return .{
                .role = evidence.initial_role,
                .generation = .{ .tracked = evidence.initial_controller_generation },
            };
        },
    };
}

fn adoptionFoldInput(
    evidence: *const PreparedAdoptionEvidence,
    authority: PreparedAttachmentAuthority,
) ?client_mod.ExternalAdoptionFoldInput {
    const seed_seal = evidence.seed_seal orelse return null;
    return .{
        .identity = .{
            .runtime_id = evidence.attachment.runtime_id,
            .stream_id = evidence.attachment.stream_id,
        },
        .authority = .{
            .role = switch (authority.role) {
                .observer => .observer,
                .controller => .controller,
            },
            .generation = switch (authority.generation) {
                .untracked => .untracked,
                .tracked => |generation| .{ .tracked = generation },
            },
        },
        .initial_metadata = switch (seed_seal.tag) {
            .unsupported => .unsupported,
            .unavailable => .unavailable,
            .current => .{ .current = .{
                .seed = &evidence.seed,
                .seal = seed_seal,
            } },
        },
    };
}

fn mapPrepareError(err: client_external_adoption.PrepareError) PrepareStatus {
    return switch (err) {
        error.OutOfMemory => .{ .retryable_preserved = .out_of_memory },
        error.MetadataTooLarge => .{ .terminal = .resource },
        error.InvalidStream,
        error.InvalidHeader,
        error.InvalidPartial,
        error.InvalidRequestId,
        error.InvalidScreenSemantic,
        error.IneligibleProfile,
        error.InvalidCompatibilityProvenance,
        => .{ .terminal = .protocol },
        error.InvalidClientState,
        error.InvalidCounter,
        error.InvalidAllocator,
        error.InvalidAlias,
        error.ArithmeticOverflow,
        error.InvalidPlan,
        error.StaleInventory,
        error.ByteCapExceeded,
        error.ItemCapExceeded,
        error.GenerationExhausted,
        error.EpochExhausted,
        error.InvalidPayload,
        error.InvalidSemantic,
        error.InvariantFailure,
        error.PlanningDisabled,
        error.Drained,
        error.InvalidAddress,
        => .{ .terminal = .internal_invariant },
    };
}

fn mapAuthorityError(err: PrepareAuthorityError) PrepareStatus {
    return switch (err) {
        error.ProtocolAuthority => .{ .terminal = .protocol },
        error.InvariantAuthority => .{ .terminal = .internal_invariant },
    };
}

pub const StorageFootprint = struct {
    pointer_bits: usize,
    fixed_inline_storage_bytes: usize,
    ledger_inline_bytes: usize,
    preallocated_transport_descriptor_bytes: usize,
};

pub const storage_footprint: StorageFootprint = .{
    .pointer_bits = @bitSizeOf(usize),
    .fixed_inline_storage_bytes = @sizeOf(ExternalPumpStorage),
    .ledger_inline_bytes = @sizeOf(external_inbox_ledger.ExternalInboxLedger),
    .preallocated_transport_descriptor_bytes = client_external_mode.max_tx_frames * @sizeOf(client_external_mode.ExternalTxFrame),
};

comptime {
    if (@bitSizeOf(usize) == 64 and
        storage_footprint.fixed_inline_storage_bytes > max_fixed_inline_storage_bytes)
        @compileError("ExternalPumpStorage exceeds the 64-bit fixed inline storage budget");
}

fn failed(reason: InitFailureReason, disposition: SourceDisposition) InitResult {
    return .{ .failed = .{
        .reason = reason,
        .source_disposition = disposition,
    } };
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

const TestClient = struct {
    client: client_mod.Client,
    peer_fd: c.fd_t,

    fn init() !TestClient {
        return initWithAllocator(std.testing.allocator);
    }

    fn initWithAllocator(allocator: std.mem.Allocator) !TestClient {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
            .connection_profile = .cli_attach,
            .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
            .attachment_capabilities = .{
                .peer_attach_generation = true,
                .negotiated_controller_transfer = true,
            },
        };
        errdefer {
            client.deinit();
            _ = c.close(fds[1]);
        }
        try client.enterExternalMode();
        return .{ .client = client, .peer_fd = fds[1] };
    }

    fn deinitPeer(self: *TestClient) void {
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

const AllocatorCallbackProbe = struct {
    const Mode = enum {
        idle,
        init_reentry,
        different_init_reentry,
        proof_alloc_mode_drift,
        proof_alloc_profile_drift,
        proof_free_mutation,
        prepare_reentry,
        prepare_teardown,
        cross_prepare_reentry,
        prepare_cleanup_teardown,
        take_alloc_oom_drift,
        teardown_reentry,
    };

    parent: std.mem.Allocator,
    mode: Mode = .idle,
    fired: bool = false,
    storage: ?*ExternalPumpStorage = null,
    source: ?*client_mod.Client = null,
    evidence: ?*PreparedAdoptionEvidence = null,
    nested_storage: ?*ExternalPumpStorage = null,
    nested_source: ?*client_mod.Client = null,
    nested_evidence: ?*PreparedAdoptionEvidence = null,
    nested_init_reason: ?InitFailureReason = null,
    nested_teardown: ?TeardownResult = null,
    nested_prepare_tag: ?std.meta.Tag(PrepareStatus) = null,
    saved_event_byte: ?u8 = null,
    source_was_tombstoned_at_proof_free: bool = false,
    saved_io_mode: ?client_external_mode.Mode = null,
    saved_connection_profile: ?client_mod.ConnectionProfile = null,
    saved_compatibility_profile: ?compatibility.Profile = null,

    fn allocator(self: *AllocatorCallbackProbe) std.mem.Allocator {
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
        const self: *AllocatorCallbackProbe = @ptrCast(@alignCast(context));
        if ((self.mode == .init_reentry or self.mode == .different_init_reentry) and
            !self.fired)
        {
            self.fired = true;
            const result = ExternalPumpStorage.initInPlace(
                if (self.mode == .init_reentry) self.storage.? else self.nested_storage.?,
                if (self.mode == .init_reentry) self.source.? else self.nested_source.?,
                if (self.mode == .init_reentry) self.evidence.? else self.nested_evidence.?,
            );
            self.nested_init_reason = switch (result) {
                .initialized => null,
                .failed => |failure| failure.reason,
            };
        } else if (!self.fired and
            (self.mode == .prepare_reentry or
                self.mode == .prepare_teardown or
                self.mode == .cross_prepare_reentry) and
            self.storage.?.lifecycle == .adoption_preparing)
        {
            self.fired = true;
            if (self.mode == .prepare_reentry or
                self.mode == .cross_prepare_reentry)
            {
                self.nested_prepare_tag = std.meta.activeTag(
                    if (self.mode == .prepare_reentry)
                        self.storage.?.prepareAdoption()
                    else
                        self.nested_storage.?.prepareAdoption(),
                );
                if (self.mode == .cross_prepare_reentry)
                    self.nested_teardown = self.nested_storage.?.teardown();
            } else {
                self.nested_teardown = self.storage.?.teardown();
            }
        } else if (!self.fired and self.mode == .prepare_cleanup_teardown and
            self.storage.?.lifecycle == .adoption_preparing and
            self.storage.?.prepared_adoption.metadata.saved_self_addr != 0)
        {
            self.fired = true;
            const payload = self.source.?.pending_events.items[0].payload;
            self.saved_event_byte = payload[0];
            payload[0] ^= 1;
        } else if (!self.fired and self.mode == .take_alloc_oom_drift and
            self.storage.?.lifecycle == .adoption_preparing and
            self.storage.?.prepared_adoption.backlog.lifecycle == .prepared and
            self.storage.?.prepared_adoption.client_take.saved_self_address == 0)
        {
            self.fired = true;
            self.source.?.pending_event_bytes +%= 1;
            return null;
        } else if (self.mode == .proof_alloc_mode_drift and !self.fired and
            self.storage.?.client_transfer.lifecycle == .prepared)
        {
            self.fired = true;
            self.saved_io_mode = self.source.?.io_mode;
            self.source.?.io_mode = .blocking;
        } else if (self.mode == .proof_alloc_profile_drift and !self.fired and
            self.storage.?.client_transfer.lifecycle == .prepared)
        {
            self.fired = true;
            self.saved_connection_profile = self.source.?.connection_profile;
            self.saved_compatibility_profile = self.source.?.compatibility_profile;
            self.source.?.connection_profile = null;
            self.source.?.compatibility_profile = null;
        }
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            ret_addr,
        );
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *AllocatorCallbackProbe = @ptrCast(@alignCast(context));
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
        const self: *AllocatorCallbackProbe = @ptrCast(@alignCast(context));
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
        const self: *AllocatorCallbackProbe = @ptrCast(@alignCast(context));
        if (self.mode == .prepare_cleanup_teardown and
            self.fired and self.nested_teardown == null and
            self.storage.?.lifecycle == .adoption_preparing)
        {
            self.nested_teardown = self.storage.?.teardown();
        } else if (!self.fired and self.mode == .proof_free_mutation and
            self.storage.?.lifecycle == .normalizing)
        {
            self.fired = true;
            self.source_was_tombstoned_at_proof_free = self.source.?.fd == -1;
            // This is the mutation that used to fit between final proof and Client move. It now
            // touches only the moved-from tombstone; the destination owner is already independent.
            self.source.?.pending_event_bytes = std.math.maxInt(usize);
        } else if (!self.fired and self.mode == .teardown_reentry and
            self.storage.?.lifecycle == .tearing_down)
        {
            self.fired = true;
            self.nested_teardown = self.storage.?.teardown();
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            ret_addr,
        );
    }
};

const valid_evidence: AttachmentEvidence = .{
    .runtime_id = 0xaa,
    .stream_id = 7,
    .initial_role = .controller,
    .initial_controller_generation = 3,
};

/// Test-only bridge: production evidence always comes from a `Prepared` whose Client already
/// carries the same `attach_instance_id`, so fixtures must seal both halves too.
fn sealAttachEvidence(
    out: *PreparedAdoptionEvidence,
    attach_instance_id: u64,
    source: *client_mod.Client,
    attachment: AttachmentEvidence,
    seed: *runtime_metadata_wire.InitialMetadataSeed,
) error{ InvalidAlias, InvalidEvidence, OutOfMemory }!void {
    source.attach_instance_id = attach_instance_id;
    return PreparedAdoptionEvidence.initFromAttachPartsInPlace(
        out,
        attach_instance_id,
        source,
        attachment,
        seed,
    );
}

fn initTestStorage(
    out: *ExternalPumpStorage,
    source: *client_mod.Client,
    attachment: AttachmentEvidence,
) InitResult {
    return initTestStorageWithOptions(out, source, attachment, .{});
}

fn initTestStorageWithOptions(
    out: *ExternalPumpStorage,
    source: *client_mod.Client,
    attachment: AttachmentEvidence,
    options: InitOptions,
) InitResult {
    var seed: runtime_metadata_wire.InitialMetadataSeed = switch (source.metadata_support) {
        .unsupported => .unsupported,
        .supported => .unavailable,
    };
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    sealAttachEvidence(
        &evidence,
        1,
        source,
        attachment,
        &seed,
    ) catch |err| return failed(
        if (err == error.OutOfMemory) .out_of_memory else .invalid_evidence,
        .preserved,
    );
    return ExternalPumpStorage.initInPlaceWithOptions(
        out,
        source,
        &evidence,
        options,
    );
}

fn appendTestEvent(client: *client_mod.Client, payload_text: []const u8) !void {
    const payload = try client.allocator.dupe(u8, payload_text);
    errdefer client.allocator.free(payload);
    try client.pending_events.append(client.allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = valid_evidence.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    client.pending_event_bytes = try std.math.add(
        usize,
        client.pending_event_bytes,
        payload.len,
    );
}

fn currentMetadataSeed(
    allocator: std.mem.Allocator,
) !runtime_metadata_wire.InitialMetadataSeed {
    return runtime_metadata_wire.testingCurrentSeed(allocator);
}

test "prepared adoption evidence enforces metadata support tag matrix before ownership mutation" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();

    var unsupported: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var first: PreparedAdoptionEvidence = .{};
    defer first.deinit();
    try sealAttachEvidence(
        &first,
        1,
        &fixture.client,
        valid_evidence,
        &unsupported,
    );
    try std.testing.expect(unsupported == .unavailable);
    try std.testing.expect(first.validate(&fixture.client));
    first.attach_instance_id = 99;
    try std.testing.expect(!first.validate(&fixture.client));
    first.attach_instance_id = first.sealed_attach_instance_id;
    first.attachment.runtime_id += 1;
    try std.testing.expect(!first.validate(&fixture.client));
    first.attachment = first.sealed_attachment;
    try std.testing.expect(first.validate(&fixture.client));
    first.deinit();

    fixture.client.connection_profile = .gui;
    var gui_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var gui_evidence: PreparedAdoptionEvidence = .{};
    try std.testing.expectError(
        error.InvalidEvidence,
        sealAttachEvidence(
            &gui_evidence,
            2,
            &fixture.client,
            valid_evidence,
            &gui_seed,
        ),
    );
    fixture.client.connection_profile = .cli_attach;

    var unavailable: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var invalid_unsupported: PreparedAdoptionEvidence = .{};
    try std.testing.expectError(
        error.InvalidEvidence,
        sealAttachEvidence(
            &invalid_unsupported,
            2,
            &fixture.client,
            valid_evidence,
            &unavailable,
        ),
    );
    try std.testing.expect(unavailable == .unavailable);

    fixture.client.metadata_support = .supported;
    var invalid_supported_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var invalid_supported: PreparedAdoptionEvidence = .{};
    try std.testing.expectError(
        error.InvalidEvidence,
        sealAttachEvidence(
            &invalid_supported,
            3,
            &fixture.client,
            valid_evidence,
            &invalid_supported_seed,
        ),
    );
    try std.testing.expect(invalid_supported_seed == .unsupported);

    var supported_unavailable: runtime_metadata_wire.InitialMetadataSeed = .unavailable;
    var second: PreparedAdoptionEvidence = .{};
    defer second.deinit();
    try sealAttachEvidence(
        &second,
        4,
        &fixture.client,
        valid_evidence,
        &supported_unavailable,
    );
    try std.testing.expect(second.validate(&fixture.client));
}

test "paired transfer rejects current seed drift and canonical cleanup survives pointer poison" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.metadata_support = .supported;

    var seed = try currentMetadataSeed(allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        9,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    const canonical_backing = evidence.cleanup_seed.current.backing.?;
    const poisoned = try allocator.dupe(u8, canonical_backing);
    evidence.seed.current.backing = poisoned;
    var storage: ExternalPumpStorage = .{};
    const failure = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invalid_evidence, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    try std.testing.expect(fixture.client.fd >= 0);
    evidence.deinit(); // frees canonical backing, never the poisoned descriptor.
    allocator.free(poisoned);
}

test "prepared evidence content drift rejects commit but descriptor cleanup remains exact" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.metadata_support = .supported;
    var seed = try currentMetadataSeed(std.testing.allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        13,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    evidence.seed.current.backing.?[0] = 'X'; // cleanup mirror shares the canonical owner bytes.
    try std.testing.expect(!evidence.validate(&fixture.client));
    var storage: ExternalPumpStorage = .{};
    const failure = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invalid_evidence, failure.reason);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    evidence.deinit(); // descriptor-only cleanup still frees the mutated canonical allocation.
}

test "prepared evidence rejects unmapped logical backing before content dereference" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.metadata_support = .supported;
    var seed = try currentMetadataSeed(std.testing.allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        14,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    const len = evidence.seed.current.backing.?.len;
    const poison: [*]u8 = @ptrFromInt(0x1000);
    evidence.seed.current.backing = poison[0..len];
    try std.testing.expect(!evidence.validate(&fixture.client));
    evidence.deinit(); // cleanup mirror still owns and frees the canonical mapped backing.
}

test "prepared evidence rejects metadata backing that aliases the source seed owner" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.metadata_support = .supported;
    var seed = try currentMetadataSeed(std.testing.allocator);
    defer seed.deinit();
    const original = seed.current.backing.?;
    const seed_bytes: [*]u8 = @ptrCast(&seed);
    seed.current.backing = seed_bytes[0..original.len];
    var evidence: PreparedAdoptionEvidence = .{};
    try std.testing.expectError(
        error.InvalidAlias,
        sealAttachEvidence(
            &evidence,
            15,
            &fixture.client,
            valid_evidence,
            &seed,
        ),
    );
    seed.current.backing = original;
}

test "paired transfer rejects storage overlap with evidence before destination dereference" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        10,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    const overlapping: *ExternalPumpStorage = @ptrCast(@alignCast(&evidence));
    const failure = ExternalPumpStorage.initInPlace(
        overlapping,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.overlapping_storage, failure.reason);
    try std.testing.expect(evidence.validate(&fixture.client));
    try std.testing.expect(fixture.client.fd >= 0);
}

test "paired transfer owns current seed with Client and post-pair failure cleans both" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    const owned_fd = fixture.client.fd;
    var seed = try currentMetadataSeed(allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        11,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    var storage: ExternalPumpStorage = .{};
    const result = ExternalPumpStorage.initInPlaceWithOptions(
        &storage,
        &fixture.client,
        &evidence,
        .{ .failpoint = .after_paired_take },
    ).failed;
    try std.testing.expectEqual(SourceDisposition.consumed_and_closed, result.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    try std.testing.expect(evidence.lifecycle == .committed_tombstone);
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    fixture.client.deinit();
    evidence.deinit();
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "paired transfer publishes current seed only inside stable storage" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    var seed = try currentMetadataSeed(std.testing.allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        12,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(
            &storage,
            &fixture.client,
            &evidence,
        ) == .initialized,
    );
    defer _ = storage.teardown();
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    try std.testing.expect(evidence.lifecycle == .committed_tombstone);
    const owned = &storage.owned_evidence.?.seed.current;
    try std.testing.expectEqualStrings("/repo", owned.cwd());
    try std.testing.expectEqualStrings("zsh", owned.foregroundProcesses()[0].slice());
    try std.testing.expect(storage.owned_evidence.?.validate(&storage.owned_client.?));
}

test "prepared Client transfer binds token destination profile and parser content" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    try fixture.client.parser.push("pending");
    const fd = fixture.client.fd;
    const parser_ptr = fixture.client.parser.buf.items.ptr;
    var slot: ?client_mod.Client = null;
    var other_slot: ?client_mod.Client = null;
    var transfer: client_mod.PreparedExternalPumpTransfer = .{};
    defer transfer.deinit();
    try fixture.client.prepareExternalPumpTransfer(
        &transfer,
        &slot,
        fixture.client.parser.residentBytes(),
    );
    try std.testing.expect(transfer.validate(&fixture.client, &slot));
    try std.testing.expect(!transfer.validate(&fixture.client, &other_slot));
    var copied = transfer;
    defer copied.deinit();
    try std.testing.expect(!copied.validate(&fixture.client, &slot));

    fixture.client.metadata_support = .supported;
    try std.testing.expect(!transfer.validate(&fixture.client, &slot));
    try std.testing.expectError(
        error.StaleTransfer,
        fixture.client.commitExternalPumpTransfer(&transfer, &slot),
    );
    try std.testing.expect(slot == null);
    try std.testing.expectEqual(fd, fixture.client.fd);
    fixture.client.metadata_support = .unsupported;
    fixture.client.parser.buf.items[0] = 'P';
    try std.testing.expect(!transfer.validate(&fixture.client, &slot));
    fixture.client.parser.buf.items[0] = 'p';
    try std.testing.expect(transfer.validate(&fixture.client, &slot));

    slot = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = -1,
        .host_id = 0,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    try std.testing.expect(!transfer.validate(&fixture.client, &slot));
    slot.?.deinit();
    slot = null;
    try std.testing.expectEqual(fd, fixture.client.fd);
    try std.testing.expectEqual(parser_ptr, fixture.client.parser.buf.items.ptr);
}

fn checkPairedTransferAllocationFailure(allocator: std.mem.Allocator) !void {
    var fixture = try TestClient.initWithAllocator(allocator);
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.metadata_support = .supported;
    try fixture.client.parser.push("pending");
    const fd = fixture.client.fd;
    var seed = try currentMetadataSeed(allocator);
    defer seed.deinit();
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    sealAttachEvidence(
        &evidence,
        21,
        &fixture.client,
        valid_evidence,
        &seed,
    ) catch |err| {
        try std.testing.expectEqual(@as(c.fd_t, fd), fixture.client.fd);
        try std.testing.expect(std.meta.eql(evidence, PreparedAdoptionEvidence{}));
        return err;
    };
    var storage: ExternalPumpStorage = .{};
    const result = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        &evidence,
    );
    switch (result) {
        .initialized => {
            try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
            try std.testing.expect(evidence.lifecycle == .committed_tombstone);
            try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
        },
        .failed => |failure| {
            try std.testing.expectEqual(InitFailureReason.out_of_memory, failure.reason);
            try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
            try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
            try std.testing.expectEqual(fd, fixture.client.fd);
            try std.testing.expect(evidence.validate(&fixture.client));
            return error.OutOfMemory;
        },
    }
}

test "paired transfer preserves both owners at every allocation fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPairedTransferAllocationFailure,
        .{},
    );
}

test "owner-range OOM precedes occupied destination dereference" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try TestClient.initWithAllocator(failing.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(
        &evidence,
        22,
        &fixture.client,
        valid_evidence,
        &seed,
    );
    var occupied: ExternalPumpStorage = .{ .lifecycle = .dead };
    failing.fail_index = failing.alloc_index;
    const failure = ExternalPumpStorage.initInPlace(
        &occupied,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.out_of_memory, failure.reason);
    try std.testing.expectEqual(StorageLifecycle.dead, occupied.lifecycle);
    try std.testing.expect(evidence.validate(&fixture.client));
    try std.testing.expect(fixture.client.fd >= 0);
}

test "external pump storage initializes only at its stable address and remains inactive" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectError(error.NotActive, storage.requireActive());
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    fixture.client.deinit(); // moved-from cleanup must not close/free the destination owner.
    fixture.client.deinit(); // the tombstone itself is an idempotent no-op.
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump refuses re-entrant teardown while a transaction owns the storage" {
    // Both in-flight windows must answer `busy`. Tearing down here would report `cleaned` to the
    // re-entrant caller while the still-running `initInPlace` goes on to publish `.adopting` over
    // the `.dead` it just wrote — a storage that two owners each believe they hold.
    var storage: ExternalPumpStorage = .{};
    storage.saved_self_addr = @intFromPtr(&storage);

    storage.lifecycle = .constructing;
    try std.testing.expectEqual(TeardownResult.busy, storage.teardown());
    try std.testing.expectEqual(StorageLifecycle.constructing, storage.lifecycle);

    storage.lifecycle = .normalizing;
    try std.testing.expectEqual(TeardownResult.busy, storage.teardown());
    try std.testing.expectEqual(StorageLifecycle.normalizing, storage.lifecycle);

    // A refusal is not a tombstone: the transaction still reaches its own terminal states.
    storage.lifecycle = .empty;
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump init allocator callback sees the in-flight latch before allocating again" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(&evidence, 91, &fixture.client, valid_evidence, &seed);
    var storage: ExternalPumpStorage = .{};
    probe.storage = &storage;
    probe.source = &fixture.client;
    probe.evidence = &evidence;
    probe.mode = .init_reentry;

    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, &evidence) ==
            .initialized,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(
        InitFailureReason.destination_not_empty,
        probe.nested_init_reason.?,
    );
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump init latch rejects a different nested destination too" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var outer_fixture = try TestClient.initWithAllocator(probe.allocator());
    defer outer_fixture.deinitPeer();
    defer outer_fixture.client.deinit();
    var nested_fixture = try TestClient.initWithAllocator(probe.allocator());
    defer nested_fixture.deinitPeer();
    defer nested_fixture.client.deinit();
    var outer_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var nested_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var outer_evidence: PreparedAdoptionEvidence = .{};
    defer outer_evidence.deinit();
    var nested_evidence: PreparedAdoptionEvidence = .{};
    defer nested_evidence.deinit();
    try sealAttachEvidence(
        &outer_evidence,
        94,
        &outer_fixture.client,
        valid_evidence,
        &outer_seed,
    );
    try sealAttachEvidence(
        &nested_evidence,
        95,
        &nested_fixture.client,
        valid_evidence,
        &nested_seed,
    );
    var outer_storage: ExternalPumpStorage = .{};
    var nested_storage: ExternalPumpStorage = .{};
    probe.storage = &outer_storage;
    probe.source = &outer_fixture.client;
    probe.evidence = &outer_evidence;
    probe.nested_storage = &nested_storage;
    probe.nested_source = &nested_fixture.client;
    probe.nested_evidence = &nested_evidence;
    probe.mode = .different_init_reentry;

    try std.testing.expect(
        ExternalPumpStorage.initInPlace(
            &outer_storage,
            &outer_fixture.client,
            &outer_evidence,
        ) == .initialized,
    );
    try std.testing.expectEqual(
        InitFailureReason.destination_not_empty,
        probe.nested_init_reason.?,
    );
    try std.testing.expectEqual(StorageLifecycle.empty, nested_storage.lifecycle);
    try std.testing.expect(nested_evidence.validate(&nested_fixture.client));
    try std.testing.expect(nested_fixture.client.fd >= 0);
    try std.testing.expectEqual(TeardownResult.cleaned, outer_storage.teardown());
}

test "external pump proof allocation mode drift is a preserved typed failure" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const source_fd = fixture.client.fd;
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(&evidence, 96, &fixture.client, valid_evidence, &seed);
    var storage: ExternalPumpStorage = .{};
    probe.storage = &storage;
    probe.source = &fixture.client;
    probe.evidence = &evidence;
    probe.mode = .proof_alloc_mode_drift;

    const result = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(InitFailureReason.invariant_failure, result.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, result.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    try std.testing.expectEqual(source_fd, fixture.client.fd);
    fixture.client.io_mode = probe.saved_io_mode.?;
    probe.saved_io_mode = null;
}

test "external pump proof allocation profile drift is a preserved typed failure" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const source_fd = fixture.client.fd;
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(&evidence, 97, &fixture.client, valid_evidence, &seed);
    var storage: ExternalPumpStorage = .{};
    probe.storage = &storage;
    probe.source = &fixture.client;
    probe.evidence = &evidence;
    probe.mode = .proof_alloc_profile_drift;

    const result = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        &evidence,
    ).failed;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(InitFailureReason.invariant_failure, result.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, result.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    try std.testing.expectEqual(source_fd, fixture.client.fd);
    fixture.client.connection_profile = probe.saved_connection_profile;
    fixture.client.compatibility_profile = probe.saved_compatibility_profile;
    probe.saved_connection_profile = null;
    probe.saved_compatibility_profile = null;
}

test "external pump retains final owner proof until the source is a tombstone" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(&evidence, 92, &fixture.client, valid_evidence, &seed);
    var storage: ExternalPumpStorage = .{};
    probe.storage = &storage;
    probe.source = &fixture.client;
    probe.evidence = &evidence;
    probe.mode = .proof_free_mutation;

    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, &evidence) ==
            .initialized,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expect(probe.source_was_tombstoned_at_proof_free);
    try std.testing.expectEqual(std.math.maxInt(usize), fixture.client.pending_event_bytes);
    try std.testing.expectEqual(@as(usize, 0), storage.owned_client.?.pending_event_bytes);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump teardown allocator callback observes busy until cleanup completes" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var evidence: PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try sealAttachEvidence(&evidence, 93, &fixture.client, valid_evidence, &seed);
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, &evidence) ==
            .initialized,
    );
    probe.storage = &storage;
    probe.source = &fixture.client;
    probe.evidence = &evidence;
    probe.mode = .teardown_reentry;
    probe.fired = false;

    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(TeardownResult.busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump prepares tracked authority and client ledger adoption without publishing live" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();
    try std.testing.expect(storage.prepareAdoption() == .prepared);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .adopting);
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
    const authority = storage.prepared_adoption.source_decision.?.verdict.adopted.authority;
    try std.testing.expect(authority.role == .controller);
    try std.testing.expectEqual(
        @as(u64, 3),
        authority.generation.tracked,
    );
    storage.prepared_adoption.backlog.inventory.?.target_stream = 8;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.backlog.inventory.?.target_stream = 7;
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
    storage.evidence_snapshot.runtime_id = 0;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.evidence_snapshot.runtime_id = valid_evidence.runtime_id;
    var wrong_storage: ExternalPumpStorage = .{};
    try std.testing.expect(!storage.prepared_adoption.validate(&wrong_storage));
    var copied_outer = storage.prepared_adoption;
    try std.testing.expect(!copied_outer.validate(&storage));
    copied_outer.deinit();
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
    var wrong_client = try TestClient.init();
    defer wrong_client.deinitPeer();
    defer wrong_client.client.deinit();
    const client_addr = storage.prepared_adoption.client_addr;
    storage.prepared_adoption.client_addr = @intFromPtr(&wrong_client.client);
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.client_addr = client_addr;
    std.mem.swap(client_mod.Client, &storage.owned_client.?, &wrong_client.client);
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    std.mem.swap(client_mod.Client, &storage.owned_client.?, &wrong_client.client);
    const ledger_addr = storage.prepared_adoption.ledger_addr;
    storage.prepared_adoption.ledger_addr = 0;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.ledger_addr = ledger_addr;
    const wrappers_addr = storage.prepared_adoption.backlog.transfer.?.wrappers_addr;
    storage.prepared_adoption.backlog.transfer.?.wrappers_addr +=
        @sizeOf(external_inbox_ledger.OwnedPayload);
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.backlog.transfer.?.wrappers_addr = wrappers_addr;
    const original_wrappers = storage.prepared_adoption.backlog.transfer.?.wrappers;
    const alternate_wrappers = try storage.owned_client.?.allocator.alloc(
        external_inbox_ledger.OwnedPayload,
        original_wrappers.len,
    );
    defer storage.owned_client.?.allocator.free(alternate_wrappers);
    for (alternate_wrappers) |*wrapper|
        wrapper.* = external_inbox_ledger.OwnedPayload.empty(storage.owned_client.?.allocator);
    storage.prepared_adoption.backlog.transfer.?.wrappers = alternate_wrappers;
    storage.prepared_adoption.backlog.transfer.?.wrappers_addr =
        @intFromPtr(alternate_wrappers.ptr);
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.backlog.transfer.?.wrappers = original_wrappers;
    storage.prepared_adoption.backlog.transfer.?.wrappers_addr = wrappers_addr;
    storage.inbox_ledger.charged_items = 1;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.inbox_ledger.charged_items = 0;
    storage.lifecycle = .live;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.lifecycle = .adopting;
    const semantic_state = storage.semantic_state;
    storage.semantic_state = .constructing;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.semantic_state = semantic_state;
    const owned_client = storage.owned_client;
    storage.owned_client = null;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.owned_client = owned_client;
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
    const aggregate_resident = storage.prepared_adoption.aggregate_resident_bytes;
    storage.prepared_adoption.aggregate_resident_bytes +%= 1;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.aggregate_resident_bytes = aggregate_resident;
    const decision = storage.prepared_adoption.source_decision.?;
    storage.prepared_adoption.source_decision = null;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.source_decision = decision;
    const metadata_addr = storage.prepared_adoption.metadata.saved_self_addr;
    storage.prepared_adoption.metadata.saved_self_addr = 0;
    try std.testing.expect(!storage.prepared_adoption.validate(&storage));
    storage.prepared_adoption.metadata.saved_self_addr = metadata_addr;
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
}

test "external adoption preparation rejects reentry and teardown from allocator callbacks" {
    inline for (.{ AllocatorCallbackProbe.Mode.prepare_reentry, .prepare_teardown }) |mode| {
        var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
        var fixture = try TestClient.initWithAllocator(probe.allocator());
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        defer _ = storage.teardown();
        probe.storage = &storage;
        probe.mode = mode;

        try std.testing.expect(storage.prepareAdoption() == .prepared);
        try std.testing.expect(probe.fired);
        switch (mode) {
            .prepare_reentry => try std.testing.expectEqual(
                std.meta.Tag(PrepareStatus).busy,
                probe.nested_prepare_tag.?,
            ),
            .prepare_teardown => try std.testing.expectEqual(
                TeardownResult.busy,
                probe.nested_teardown.?,
            ),
            else => unreachable,
        }
        try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
        try std.testing.expect(storage.prepared_adoption.validate(&storage));
    }
}

test "external adoption latch rejects cross-storage prepare and teardown" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var outer_fixture = try TestClient.initWithAllocator(probe.allocator());
    defer outer_fixture.deinitPeer();
    var nested_fixture = try TestClient.initWithAllocator(probe.allocator());
    defer nested_fixture.deinitPeer();
    var outer_storage: ExternalPumpStorage = .{};
    var nested_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&outer_storage, &outer_fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = outer_storage.teardown();
    try std.testing.expect(
        initTestStorage(&nested_storage, &nested_fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = nested_storage.teardown();
    probe.storage = &outer_storage;
    probe.nested_storage = &nested_storage;
    probe.mode = .cross_prepare_reentry;

    try std.testing.expect(outer_storage.prepareAdoption() == .prepared);
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(
        std.meta.Tag(PrepareStatus).busy,
        probe.nested_prepare_tag.?,
    );
    try std.testing.expectEqual(TeardownResult.busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.adopting, nested_storage.lifecycle);
    try std.testing.expectEqual(
        AdoptionLifecycle.empty,
        nested_storage.prepared_adoption.lifecycle,
    );
    try std.testing.expect(nested_storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expect(nested_storage.prepareAdoption() == .prepared);
    try std.testing.expect(nested_storage.prepared_adoption.validate(&nested_storage));
}

test "external adoption cleanup keeps teardown busy through allocator free callbacks" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client, event_json);
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .prepare_cleanup_teardown;

    const result = storage.prepareAdoption();
    try std.testing.expect(result == .terminal);
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(TeardownResult.busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(AdoptionLifecycle.empty, storage.prepared_adoption.lifecycle);
    storage.owned_client.?.pending_events.items[0].payload[0] =
        probe.saved_event_byte.?;
}

test "external adoption proves the whole aggregate destination before writing it" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const original_payload = try fixture.client.allocator.dupe(u8, "event");
    try fixture.client.pending_events.append(fixture.client.allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = valid_evidence.stream_id,
            .payload_len = @intCast(original_payload.len),
        },
        .payload = original_payload,
    });
    fixture.client.pending_event_bytes = original_payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();

    const outer_before = storage.prepared_adoption;
    storage.owned_client.?.pending_events.items[0].payload =
        std.mem.asBytes(&storage.prepared_adoption)[0..original_payload.len];
    const result = storage.prepareAdoption();
    try std.testing.expect(result == .terminal);
    try std.testing.expectEqual(
        TerminalPrepareReason.internal_invariant,
        result.terminal,
    );
    try std.testing.expect(std.meta.eql(outer_before, storage.prepared_adoption));
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);

    storage.owned_client.?.pending_events.items[0].payload = original_payload;
}

test "external adoption preserves non-adopted decisions without false terminal mapping" {
    const Case = struct {
        payload: []const u8,
        verdict: std.meta.Tag(external_source_decision.Verdict),
    };
    const cases = [_]Case{
        .{
            .payload = "{\"event\":\"snapshot.invalidated\"}",
            .verdict = .host_recovery,
        },
        .{
            .payload = "{\"event\":\"runtime.ended\"}",
            .verdict = .ended,
        },
        .{
            .payload = "event",
            .verdict = .terminal,
        },
    };
    for (cases) |case| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        const payload = try fixture.client.allocator.dupe(u8, case.payload);
        try fixture.client.pending_events.append(fixture.client.allocator, .{
            .header = .{
                .kind = .event,
                .stream_id = valid_evidence.stream_id,
                .payload_len = @intCast(payload.len),
            },
            .payload = payload,
        });
        fixture.client.pending_event_bytes = payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        defer _ = storage.teardown();

        try std.testing.expect(storage.prepareAdoption() == .deferred_non_adopted);
        try std.testing.expect(storage.prepared_adoption.validate(&storage));
        try std.testing.expectEqual(
            case.verdict,
            std.meta.activeTag(
                storage.prepared_adoption.source_decision.?.verdict,
            ),
        );
        try std.testing.expectEqual(
            PreparedAdoptionBranch.non_adopted,
            storage.prepared_adoption.branch,
        );
    }
}

test "external pump composes an event metadata winner with the screen footprint" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    const event_payload = try fixture.client.allocator.dupe(u8, event_json);
    try fixture.client.pending_events.append(fixture.client.allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = valid_evidence.stream_id,
            .payload_len = @intCast(event_payload.len),
        },
        .payload = event_payload,
    });
    fixture.client.pending_event_bytes = event_payload.len;
    const screen_payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = screen_payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = screen_payload.len;

    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();
    try std.testing.expect(storage.prepareAdoption() == .prepared);
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
    const metadata_footprint = switch (storage.prepared_adoption.metadata.metadata) {
        .event => |*owned| owned.footprint,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(metadata_footprint.resident_delta > 0);
    try std.testing.expectEqual(
        storage.prepared_adoption.backlog.adoption_metadata_resident_bytes +
            metadata_footprint.resident_delta,
        storage.prepared_adoption.aggregate_resident_bytes,
    );
    try std.testing.expectEqual(
        storage.prepared_adoption.backlog.adoption_metadata_prepare_peak_bytes +
            metadata_footprint.prepare_peak_delta,
        storage.prepared_adoption.aggregate_prepare_peak_bytes,
    );
}

test "external adoption enforces the aggregate cap across metadata and screen owners" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var baseline = try TestClient.init();
    defer baseline.deinitPeer();
    baseline.client.metadata_support = .supported;
    try appendTestEvent(&baseline.client, event_json);
    var baseline_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&baseline_storage, &baseline.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(baseline_storage.prepareAdoption() == .prepared);
    const metadata_peak = switch (baseline_storage.prepared_adoption.metadata.metadata) {
        .event => |*owned| owned.footprint.prepare_peak_delta,
        else => return error.TestUnexpectedResult,
    };
    const large_padding_base = @max(
        baseline_storage.prepared_adoption.aggregate_resident_bytes,
        baseline_storage.prepared_adoption.backlog.adoption_metadata_resident_bytes +
            metadata_peak,
    );
    try std.testing.expect(
        large_padding_base < external_adoption_limits.max_metadata_bytes,
    );
    // Client inventory metadata is retained in both the live Client and the prepared inventory,
    // so one build-id byte contributes two bytes to the screen sub-plan footprint.
    const exact_padding =
        (external_adoption_limits.max_metadata_bytes - large_padding_base) / 2;
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        baseline_storage.teardown(),
    );

    var exact = try TestClient.init();
    defer exact.deinitPeer();
    exact.client.metadata_support = .supported;
    exact.client.build_id = try exact.client.allocator.alloc(u8, exact_padding);
    @memset(exact.client.build_id.?, 'x');
    try appendTestEvent(&exact.client, event_json);
    var exact_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&exact_storage, &exact.client, valid_evidence) ==
            .initialized,
    );
    defer _ = exact_storage.teardown();
    try std.testing.expect(exact_storage.prepareAdoption() == .prepared);
    const exact_max = @max(
        exact_storage.prepared_adoption.aggregate_resident_bytes,
        exact_storage.prepared_adoption.aggregate_prepare_peak_bytes,
    );
    try std.testing.expect(exact_max <= external_adoption_limits.max_metadata_bytes);
    try std.testing.expect(
        external_adoption_limits.max_metadata_bytes - exact_max < 2,
    );

    var over = try TestClient.init();
    defer over.deinitPeer();
    over.client.metadata_support = .supported;
    over.client.build_id = try over.client.allocator.alloc(u8, exact_padding + 1);
    @memset(over.client.build_id.?, 'x');
    try appendTestEvent(&over.client, event_json);
    var over_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&over_storage, &over.client, valid_evidence) ==
            .initialized,
    );
    defer _ = over_storage.teardown();
    const over_result = over_storage.prepareAdoption();
    try std.testing.expect(over_result == .terminal);
    try std.testing.expectEqual(TerminalPrepareReason.resource, over_result.terminal);
    try std.testing.expectEqual(AdoptionLifecycle.empty, over_storage.prepared_adoption.lifecycle);
    try std.testing.expect(over_storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expectEqual(
        exact_padding + 1,
        over_storage.owned_client.?.build_id.?.len,
    );
    try std.testing.expectEqualStrings(
        event_json,
        over_storage.owned_client.?.pending_events.items[0].payload,
    );
}

test "external pump retryable allocation failure preserves the same storage for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try TestClient.initWithAllocator(failing.allocator());
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();

    failing.fail_index = failing.alloc_index;
    try std.testing.expect(storage.prepareAdoption() == .retryable_preserved);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(AdoptionLifecycle.empty, storage.prepared_adoption.lifecycle);
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(storage.prepareAdoption() == .prepared);
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
}

test "external take proof OOM with allocator callback drift is terminal" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = storage.teardown();
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .take_alloc_oom_drift;

    const result = storage.prepareAdoption();
    try std.testing.expect(result == .terminal);
    try std.testing.expectEqual(
        TerminalPrepareReason.internal_invariant,
        result.terminal,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(
        AdoptionLifecycle.empty,
        storage.prepared_adoption.lifecycle,
    );
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
}

test "external pump teardown ignores forged prepared lifecycle tombstones" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(storage.prepareAdoption() == .prepared);
    storage.prepared_adoption.lifecycle = .committed_tombstone;
    storage.prepared_adoption.backlog.client_disarm.lifecycle = @enumFromInt(3);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump retries the same storage at every adoption allocation index" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var fail_offset: usize = 0;
    while (true) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var fixture = try TestClient.initWithAllocator(allocator);
        defer fixture.deinitPeer();
        fixture.client.metadata_support = .supported;
        try fixture.client.parser.push("parser");
        const payload = try allocator.dupe(u8, "batch");
        try fixture.client.pending_batches.append(allocator, .{
            .is_snapshot = false,
            .stream_id = 7,
            .bytes = payload,
            .allocator = allocator,
        });
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
        try fixture.client.pending_stream.append(allocator, .{
            .header = .{
                .kind = .delta_chunk,
                .stream_id = 7,
                .payload_len = @intCast(stream_payload.len),
            },
            .payload = stream_payload,
        });
        fixture.client.pending_stream_bytes = stream_payload.len;
        const event_payload = try allocator.dupe(u8, event_json);
        try fixture.client.pending_events.append(allocator, .{
            .header = .{
                .kind = .event,
                .stream_id = 7,
                .payload_len = @intCast(event_payload.len),
            },
            .payload = event_payload,
        });
        fixture.client.pending_event_bytes = event_payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        defer _ = storage.teardown();
        const batch_before = storage.owned_client.?.pending_batches.items[0];
        const batch_list_ptr = storage.owned_client.?.pending_batches.items.ptr;
        const batch_list_len = storage.owned_client.?.pending_batches.items.len;
        const batch_list_cap = storage.owned_client.?.pending_batches.capacity;
        const batch_counter = storage.owned_client.?.pending_batch_bytes;
        const partial_before = storage.owned_client.?.partial_batch.?;
        const stream_before = storage.owned_client.?.pending_stream.items[0];
        const stream_list_ptr = storage.owned_client.?.pending_stream.items.ptr;
        const stream_list_len = storage.owned_client.?.pending_stream.items.len;
        const stream_list_cap = storage.owned_client.?.pending_stream.capacity;
        const stream_counter = storage.owned_client.?.pending_stream_bytes;
        const event_before = storage.owned_client.?.pending_events.items[0];
        const event_list_ptr = storage.owned_client.?.pending_events.items.ptr;
        const event_list_len = storage.owned_client.?.pending_events.items.len;
        const event_list_cap = storage.owned_client.?.pending_events.capacity;
        const event_counter = storage.owned_client.?.pending_event_bytes;
        const parser_items = storage.owned_client.?.parser.buf.items;
        const parser_cap = storage.owned_client.?.parser.buf.capacity;
        const parser_head = storage.owned_client.?.parser.head;
        const parser_major = storage.owned_client.?.parser.expected_major;

        failing.fail_index = failing.alloc_index + fail_offset;
        const first = storage.prepareAdoption();
        if (!failing.has_induced_failure) {
            try std.testing.expect(first == .prepared);
            try std.testing.expect(storage.prepared_adoption.validate(&storage));
            break;
        }
        try std.testing.expect(first == .retryable_preserved);
        try std.testing.expectEqual(AdoptionLifecycle.empty, storage.prepared_adoption.lifecycle);
        try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
        try std.testing.expectEqual(@as(usize, 1), storage.owned_client.?.pending_batches.items.len);
        try std.testing.expectEqualStrings(
            "batch",
            storage.owned_client.?.pending_batches.items[0].bytes,
        );
        try std.testing.expect(std.meta.eql(
            batch_before,
            storage.owned_client.?.pending_batches.items[0],
        ));
        try std.testing.expectEqual(batch_list_ptr, storage.owned_client.?.pending_batches.items.ptr);
        try std.testing.expectEqual(batch_list_len, storage.owned_client.?.pending_batches.items.len);
        try std.testing.expectEqual(batch_list_cap, storage.owned_client.?.pending_batches.capacity);
        try std.testing.expectEqual(batch_counter, storage.owned_client.?.pending_batch_bytes);
        try std.testing.expectEqualStrings(
            "partial",
            storage.owned_client.?.partial_batch.?.bytes.items,
        );
        try std.testing.expect(std.meta.eql(partial_before, storage.owned_client.?.partial_batch.?));
        try std.testing.expectEqualStrings(
            "stream",
            storage.owned_client.?.pending_stream.items[0].payload,
        );
        try std.testing.expect(std.meta.eql(stream_before, storage.owned_client.?.pending_stream.items[0]));
        try std.testing.expectEqual(stream_list_ptr, storage.owned_client.?.pending_stream.items.ptr);
        try std.testing.expectEqual(stream_list_len, storage.owned_client.?.pending_stream.items.len);
        try std.testing.expectEqual(stream_list_cap, storage.owned_client.?.pending_stream.capacity);
        try std.testing.expectEqual(stream_counter, storage.owned_client.?.pending_stream_bytes);
        try std.testing.expectEqualStrings(
            event_json,
            storage.owned_client.?.pending_events.items[0].payload,
        );
        try std.testing.expect(std.meta.eql(event_before, storage.owned_client.?.pending_events.items[0]));
        try std.testing.expectEqual(event_list_ptr, storage.owned_client.?.pending_events.items.ptr);
        try std.testing.expectEqual(event_list_len, storage.owned_client.?.pending_events.items.len);
        try std.testing.expectEqual(event_list_cap, storage.owned_client.?.pending_events.capacity);
        try std.testing.expectEqual(event_counter, storage.owned_client.?.pending_event_bytes);
        try std.testing.expectEqualStrings("parser", storage.owned_client.?.parser.buf.items);
        try std.testing.expectEqual(parser_items.ptr, storage.owned_client.?.parser.buf.items.ptr);
        try std.testing.expectEqual(parser_items.len, storage.owned_client.?.parser.buf.items.len);
        try std.testing.expectEqual(parser_cap, storage.owned_client.?.parser.buf.capacity);
        try std.testing.expectEqual(parser_head, storage.owned_client.?.parser.head);
        try std.testing.expectEqual(parser_major, storage.owned_client.?.parser.expected_major);
        _ = try client_external_adoption.preflightMetadata(&storage.owned_client.?, 7);

        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(storage.prepareAdoption() == .prepared);
        try std.testing.expect(storage.prepared_adoption.validate(&storage));
        if (fail_offset > 128) return error.TestUnexpectedResult;
    }
}

test "external pump authority seed permits only verified frozen untracked controller" {
    var frozen = try TestClient.init();
    defer frozen.deinitPeer();
    frozen.client.wire_major = 1;
    frozen.client.screen_codec_version = 1;
    frozen.client.parser.expected_major = 1;
    frozen.client.compatibility_profile = compatibility.profileForMajor(1).?;
    frozen.client.attachment_capabilities = .{};
    var frozen_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(
            &frozen_storage,
            &frozen.client,
            .{
                .runtime_id = 0xaa,
                .stream_id = 7,
                .initial_role = .controller,
                .initial_controller_generation = 0,
            },
        ) == .initialized,
    );
    defer _ = frozen_storage.teardown();
    try std.testing.expect(frozen_storage.prepareAdoption() == .prepared);
    try std.testing.expect(
        frozen_storage.prepared_adoption.source_decision.?.verdict.adopted
            .authority.generation == .untracked,
    );

    var wrong_fingerprint = try TestClient.init();
    defer wrong_fingerprint.deinitPeer();
    defer wrong_fingerprint.client.deinit();
    wrong_fingerprint.client.wire_major = 1;
    wrong_fingerprint.client.screen_codec_version = 1;
    wrong_fingerprint.client.parser.expected_major = 1;
    wrong_fingerprint.client.compatibility_profile = compatibility.profileForMajor(1).?;
    wrong_fingerprint.client.compatibility_profile.?.required_fingerprint = "wrong";
    wrong_fingerprint.client.attachment_capabilities = .{};
    var wrong_fingerprint_storage: ExternalPumpStorage = .{};
    const wrong_fingerprint_failure = initTestStorage(
        &wrong_fingerprint_storage,
        &wrong_fingerprint.client,
        .{
            .runtime_id = 0xaa,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 0,
        },
    ).failed;
    try std.testing.expectEqual(
        InitFailureReason.invalid_evidence,
        wrong_fingerprint_failure.reason,
    );

    var current = try TestClient.init();
    defer current.deinitPeer();
    defer current.client.deinit();
    current.client.attachment_capabilities = .{};
    var current_storage: ExternalPumpStorage = .{};
    const current_failure = initTestStorage(
        &current_storage,
        &current.client,
        .{
            .runtime_id = 0xaa,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 0,
        },
    ).failed;
    try std.testing.expectEqual(
        InitFailureReason.invalid_evidence,
        current_failure.reason,
    );
}

test "external pump authority seed table preserves protocol and invariant classes" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const client = &fixture.client;
    try std.testing.expectEqual(
        TerminalPrepareReason.protocol,
        mapAuthorityError(error.ProtocolAuthority).terminal,
    );
    try std.testing.expectEqual(
        TerminalPrepareReason.internal_invariant,
        mapAuthorityError(error.InvariantAuthority).terminal,
    );

    const current_profile = client.compatibility_profile.?;
    client.compatibility_profile = compatibility.profileForMajor(1).?;
    client.attachment_capabilities = .{};
    var authority = try prepareAuthority(client, .{
        .runtime_id = 1,
        .stream_id = 7,
        .initial_role = .controller,
        .initial_controller_generation = 0,
    });
    try std.testing.expect(authority.generation == .untracked);
    try std.testing.expectError(
        error.ProtocolAuthority,
        prepareAuthority(client, .{
            .runtime_id = 1,
            .stream_id = 7,
            .initial_role = .observer,
            .initial_controller_generation = 0,
        }),
    );
    try std.testing.expectError(
        error.ProtocolAuthority,
        prepareAuthority(client, .{
            .runtime_id = 1,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 1,
        }),
    );
    client.attachment_capabilities.peer_attach_generation = true;
    try std.testing.expectError(
        error.ProtocolAuthority,
        prepareAuthority(client, .{
            .runtime_id = 1,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 0,
        }),
    );

    client.compatibility_profile = current_profile;
    client.attachment_capabilities = .{};
    authority = try prepareAuthority(client, .{
        .runtime_id = 1,
        .stream_id = 7,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    });
    try std.testing.expect(authority.generation == .untracked);
    try std.testing.expectError(
        error.ProtocolAuthority,
        prepareAuthority(client, .{
            .runtime_id = 1,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 0,
        }),
    );

    client.attachment_capabilities = .{
        .peer_attach_generation = true,
        .negotiated_controller_transfer = false,
    };
    try std.testing.expectError(
        error.InvariantAuthority,
        prepareAuthority(client, valid_evidence),
    );
    client.attachment_capabilities = .{
        .peer_attach_generation = false,
        .negotiated_controller_transfer = true,
    };
    try std.testing.expectError(
        error.InvariantAuthority,
        prepareAuthority(client, valid_evidence),
    );

    client.attachment_capabilities = .{
        .peer_attach_generation = true,
        .negotiated_controller_transfer = true,
    };
    try std.testing.expectError(
        error.ProtocolAuthority,
        prepareAuthority(client, .{
            .runtime_id = 1,
            .stream_id = 7,
            .initial_role = .controller,
            .initial_controller_generation = 0,
        }),
    );
    authority = try prepareAuthority(client, .{
        .runtime_id = 1,
        .stream_id = 7,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    });
    try std.testing.expectEqual(@as(u64, 0), authority.generation.tracked);
    authority = try prepareAuthority(client, .{
        .runtime_id = 1,
        .stream_id = 7,
        .initial_role = .observer,
        .initial_controller_generation = 9,
    });
    try std.testing.expectEqual(@as(u64, 9), authority.generation.tracked);
    authority = try prepareAuthority(client, valid_evidence);
    try std.testing.expectEqual(@as(u64, 3), authority.generation.tracked);
}

test "external pump storage rejects transfer of its already-bound Client" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    const owned_fd = storage.owned_client.?.fd;
    var second_slot: ?client_mod.Client = null;
    var second_transfer: client_mod.PreparedExternalPumpTransfer = .{};
    defer second_transfer.deinit();
    try std.testing.expectError(
        error.AlreadyBound,
        storage.owned_client.?.prepareExternalPumpTransfer(
            &second_transfer,
            &second_slot,
            protocol.max_binary_chunk + protocol.header_size,
        ),
    );
    try std.testing.expect(second_slot == null);
    try std.testing.expectEqual(owned_fd, storage.owned_client.?.fd);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);

    var second_storage: ExternalPumpStorage = .{};
    const failure = initTestStorage(
        &second_storage,
        &storage.owned_client.?,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.source_already_bound, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, second_storage.lifecycle);
    try std.testing.expectEqual(owned_fd, storage.owned_client.?.fd);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage preflight failures preserve source and leave destination empty" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    const invalid = initTestStorage(
        &storage,
        &fixture.client,
        .{
            .runtime_id = 0,
            .stream_id = 7,
            .initial_role = .observer,
            .initial_controller_generation = 0,
        },
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invalid_evidence, invalid.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, invalid.source_disposition);
    try std.testing.expectEqual(fd, fixture.client.fd);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);

    storage.lifecycle = .adopting;
    const occupied = initTestStorage(
        &storage,
        &fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.destination_not_empty, occupied.reason);
    try std.testing.expectEqual(fd, fixture.client.fd);
    storage = .{};
}

test "external pump storage rejects blocking and closed sources without ownership mutation" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var blocking: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .connection_profile = .cli_attach,
        .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    defer blocking.deinit();
    var storage: ExternalPumpStorage = .{};
    const blocking_failure = initTestStorage(
        &storage,
        &blocking,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.source_not_external, blocking_failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, blocking_failure.source_disposition);
    try std.testing.expectEqual(fds[0], blocking.fd);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);

    var closed = try TestClient.init();
    defer closed.deinitPeer();
    defer closed.client.deinit();
    closed.client.failClosed();
    const closed_failure = initTestStorage(
        &storage,
        &closed.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.connection_closed, closed_failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, closed_failure.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
}

test "external pump storage live reinit preserves both existing and candidate owners" {
    var first = try TestClient.init();
    defer first.deinitPeer();
    var second = try TestClient.init();
    defer second.deinitPeer();
    defer second.client.deinit();
    const second_fd = second.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &first.client, valid_evidence) ==
            .initialized,
    );

    const failure = initTestStorage(
        &storage,
        &second.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.destination_not_empty, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(second_fd, second.client.fd);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage normalize failures preserve every observable source owner" {
    const Scenario = enum { cap, oom, malformed };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture = try TestClient.initWithAllocator(failing.allocator());
        defer fixture.deinitPeer();
        defer {
            if (scenario == .malformed) fixture.client.parser.head = 0;
            fixture.client.deinit();
        }
        try fixture.client.parser.push("unread");
        if (scenario == .malformed)
            fixture.client.parser.head = fixture.client.parser.buf.items.len + 1;

        const fd = fixture.client.fd;
        const ptr = fixture.client.parser.buf.items.ptr;
        const len = fixture.client.parser.buf.items.len;
        const cap = fixture.client.parser.buf.capacity;
        const head = fixture.client.parser.head;
        const request_id = fixture.client.next_request_id;
        const stream_ptr = fixture.client.pending_stream.items.ptr;
        var storage: ExternalPumpStorage = .{};
        if (scenario == .oom) failing.fail_index = failing.alloc_index;
        const resident_cap = if (scenario == .cap) cap - 1 else cap;
        const failure = initTestStorageWithOptions(
            &storage,
            &fixture.client,
            valid_evidence,
            .{ .resident_cap = resident_cap },
        ).failed;

        try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
        try std.testing.expectEqual(
            switch (scenario) {
                .cap => InitFailureReason.resident_too_large,
                .oom => InitFailureReason.out_of_memory,
                .malformed => InitFailureReason.malformed_parser,
            },
            failure.reason,
        );
        try std.testing.expectEqual(fd, fixture.client.fd);
        try std.testing.expectEqual(ptr, fixture.client.parser.buf.items.ptr);
        try std.testing.expectEqual(len, fixture.client.parser.buf.items.len);
        try std.testing.expectEqual(cap, fixture.client.parser.buf.capacity);
        try std.testing.expectEqual(head, fixture.client.parser.head);
        try std.testing.expectEqual(request_id, fixture.client.next_request_id);
        try std.testing.expectEqual(stream_ptr, fixture.client.pending_stream.items.ptr);
        try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    }
}

test "external pump storage rejects source overlap before reading destination state" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const fd = fixture.client.fd;
    const overlapping: *ExternalPumpStorage = @ptrCast(@alignCast(&fixture.client));
    const failure = initTestStorage(
        overlapping,
        &fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.overlapping_storage, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(fd, fixture.client.fd);
}

test "external pump storage rejects overlap with every source-owned backing before first write" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    var storage: ExternalPumpStorage = .{};
    const original = try allocator.dupe(u8, "x");
    try fixture.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 7,
        .bytes = original,
        .allocator = allocator,
    });
    fixture.client.pending_batch_bytes = 1;
    const storage_bytes = std.mem.asBytes(&storage);
    fixture.client.pending_batches.items[0].bytes = storage_bytes[0..1];
    const byte_before = storage_bytes[0];

    const failure = initTestStorage(
        &storage,
        &fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.overlapping_storage, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(byte_before, storage_bytes[0]);
    fixture.client.pending_batches.items[0].bytes = original;
}

test "external pump storage post-move failure closes destination and tombstones source" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    const result = initTestStorageWithOptions(
        &storage,
        &fixture.client,
        valid_evidence,
        .{ .failpoint = .after_paired_take },
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invariant_failure, result.reason);
    try std.testing.expectEqual(SourceDisposition.consumed_and_closed, result.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    fixture.client.deinit();
    fixture.client.deinit();
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump storage teardown reports impossible 2b2b ledger charge after client cleanup" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    var allocation = try std.testing.allocator.dupe(u8, "x");
    var payload = external_inbox_ledger.OwnedPayload.takeOwned(
        std.testing.allocator,
        &allocation,
    );
    _ = try storage.inbox_ledger.reserveLease(.{
        .stream_id = 1,
        .is_snapshot = false,
    }, &payload);
    try std.testing.expectEqual(TeardownResult.ledger_not_zero, storage.teardown());
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump storage teardown reentry cannot close a reused descriptor number" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const old_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expect(c.fcntl(old_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(old_fd, c.dup2(fixture.peer_fd, old_fd));
    defer _ = c.close(old_fd);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
    try std.testing.expect(c.fcntl(old_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
}

test "external pump storage forged value copy cannot clean the original owner" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    var forged = storage;
    try std.testing.expectError(error.MovedStorage, forged.requireActive());
    try std.testing.expectEqual(TeardownResult.moved_storage, forged.teardown());
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage footprint is exact and bounded on 64-bit targets" {
    try std.testing.expectEqual(
        @sizeOf(ExternalPumpStorage),
        storage_footprint.fixed_inline_storage_bytes,
    );
    try std.testing.expectEqual(
        @sizeOf(external_inbox_ledger.ExternalInboxLedger),
        storage_footprint.ledger_inline_bytes,
    );
    if (@bitSizeOf(usize) == 64)
        try std.testing.expect(
            storage_footprint.fixed_inline_storage_bytes <= max_fixed_inline_storage_bytes,
        );
}

test "external adoption aggregate footprint enforces exact cap and overflow" {
    const limit = external_adoption_limits.max_metadata_bytes;
    const exact = try aggregateAdoptionFootprint(
        .{
            .resident = limit - 1,
            .prepare_peak = limit - 2,
        },
        .{
            .resident_delta = 1,
            .prepare_peak_delta = 2,
        },
    );
    try std.testing.expectEqual(limit, exact.resident);
    try std.testing.expectEqual(limit, exact.prepare_peak);

    try std.testing.expectError(
        error.ResourceExhausted,
        aggregateAdoptionFootprint(
            .{ .resident = limit, .prepare_peak = 0 },
            .{ .resident_delta = 1, .prepare_peak_delta = 0 },
        ),
    );
    try std.testing.expectError(
        error.ResourceExhausted,
        aggregateAdoptionFootprint(
            .{ .resident = std.math.maxInt(usize), .prepare_peak = 0 },
            .{ .resident_delta = 1, .prepare_peak_delta = 0 },
        ),
    );
}

test "external pump storage overlap arithmetic covers partial and adjacent ranges" {
    try std.testing.expect(rangesOverlap(100, 20, 90, 11));
    try std.testing.expect(rangesOverlap(100, 20, 119, 20));
    try std.testing.expect(!rangesOverlap(100, 20, 80, 20));
    try std.testing.expect(!rangesOverlap(100, 20, 120, 20));
    try std.testing.expect(rangesOverlap(std.math.maxInt(usize) - 1, 4, 0, 1));
}
