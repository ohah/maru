//! Stable, address-bound storage for the public attach external pump.
//!
//! The storage is initialized only in its caller-owned final address. It keeps the raw Client and
//! inbox ledger behind one lifecycle boundary so later token-bearing slices never need to recover
//! from a moved owner.

const std = @import("std");
const builtin = @import("builtin");
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
const external_inbox_limits = @import("external_inbox_limits.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const external_owner_range = @import("external_owner_range.zig");
const external_source_decision = @import("external_source_decision.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const resize_wire = @import("resize_wire.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
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

    fn appendCleanupRange(
        self: *const PreparedAdoptionEvidence,
        out: *external_owner_range.Scratch,
    ) external_owner_range.Error!void {
        const seal = if (seedMatchesSeal(self.cleanup_seed_seal, &self.cleanup_seed))
            self.cleanup_seed_seal.?
        else if (seedMatchesSeal(self.seed_seal, &self.seed))
            self.seed_seal.?
        else
            return;
        if (seal.backing_present) try out.append(seal.backing_addr, seal.backing_len);
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

const owner_resize_seal_domain: u64 = 0x4d_41_52_55_4f_52_53_31;
const owner_resize_seal_version: u16 = 1;

const OwnerResizeSeal = struct {
    domain: u64,
    version: u16,
    current_addr: usize,
    storage_addr: usize,
    runtime_id: u128,
    generation: u64,
    cols: u16,
    rows: u16,
    pending: bool,
    digest: external_owner_seal.Digest,
};

const OwnerResizeCurrent = struct {
    event: resize_wire.Event,
    pending: bool,
    seal: OwnerResizeSeal,
};

pub const OwnerResizeState = union(enum) {
    none,
    current: OwnerResizeCurrent,
};

fn ownerResizeDigest(seal: OwnerResizeSeal) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUORS1");
    writer.writeU64(seal.domain);
    writer.writeU16(seal.version);
    writer.writeUsize(seal.current_addr);
    writer.writeUsize(seal.storage_addr);
    writer.writeU128(seal.runtime_id);
    writer.writeU64(seal.generation);
    writer.writeU16(seal.cols);
    writer.writeU16(seal.rows);
    writer.writeBool(seal.pending);
    return writer.finish();
}

fn bindOwnerResize(storage: *ExternalPumpStorage, event: resize_wire.Event) void {
    storage.owner_resize = .{ .current = .{
        .event = event,
        .pending = true,
        .seal = undefined,
    } };
    const current = &storage.owner_resize.current;
    current.seal = .{
        .domain = owner_resize_seal_domain,
        .version = owner_resize_seal_version,
        .current_addr = @intFromPtr(&storage.owner_resize.current),
        .storage_addr = @intFromPtr(storage),
        .runtime_id = event.runtime_id,
        .generation = event.resize_generation,
        .cols = event.cols,
        .rows = event.rows,
        .pending = true,
        .digest = undefined,
    };
    current.seal.digest = ownerResizeDigest(current.seal);
}

fn ownerResizeValid(storage: *const ExternalPumpStorage) bool {
    return switch (storage.owner_resize) {
        .none => true,
        .current => |*current| blk: {
            const seal = current.seal;
            break :blk seal.domain == owner_resize_seal_domain and
                seal.version == owner_resize_seal_version and
                seal.current_addr == @intFromPtr(current) and
                seal.storage_addr == @intFromPtr(storage) and
                seal.runtime_id == current.event.runtime_id and
                seal.generation == current.event.resize_generation and
                seal.cols == current.event.cols and seal.rows == current.event.rows and
                seal.pending == current.pending and
                std.mem.eql(u8, &seal.digest, &ownerResizeDigest(seal));
        },
    };
}

const owner_incarnation_seal_domain: u64 = 0x4d_41_52_55_4f_49_4e_31;
const owner_incarnation_seal_version: u16 = 1;

const OwnerIncarnationSeal = struct {
    domain: u64 = 0,
    version: u16 = 0,
    storage_addr: usize = 0,
    owner_incarnation: u64 = 0,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

fn ownerIncarnationDigest(seal: OwnerIncarnationSeal) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUOIN1");
    writer.writeU64(seal.domain);
    writer.writeU16(seal.version);
    writer.writeUsize(seal.storage_addr);
    writer.writeU64(seal.owner_incarnation);
    return writer.finish();
}

fn bindOwnerIncarnation(storage: *ExternalPumpStorage, incarnation: u64) void {
    std.debug.assert(incarnation != 0);
    storage.owner_incarnation = incarnation;
    storage.owner_incarnation_seal = .{
        .domain = owner_incarnation_seal_domain,
        .version = owner_incarnation_seal_version,
        .storage_addr = @intFromPtr(storage),
        .owner_incarnation = incarnation,
    };
    storage.owner_incarnation_seal.digest =
        ownerIncarnationDigest(storage.owner_incarnation_seal);
}

fn ownerIncarnationValid(storage: *const ExternalPumpStorage) bool {
    const seal = storage.owner_incarnation_seal;
    return storage.owner_incarnation != 0 and
        seal.domain == owner_incarnation_seal_domain and
        seal.version == owner_incarnation_seal_version and
        seal.storage_addr == @intFromPtr(storage) and
        seal.owner_incarnation == storage.owner_incarnation and
        std.mem.eql(u8, &seal.digest, &ownerIncarnationDigest(seal));
}

pub const OwnerAuthorityFlow = enum {
    initial_fence,
    clear,
};

pub const OwnerAuthorityState = union(enum) {
    empty,
    current: struct {
        role: AttachmentRole,
        generation: AuthorityGeneration,
        flow: OwnerAuthorityFlow,
    },
};

const OwnerAuthoritySeal = struct {
    storage_addr: usize = 0,
    owner_incarnation: u64 = 0,
    role: AttachmentRole = .observer,
    generation_tracked: bool = false,
    generation: u64 = 0,
    flow: OwnerAuthorityFlow = .initial_fence,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

fn ownerAuthoritySealDigest(seal: OwnerAuthoritySeal) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUOAS1");
    writer.writeUsize(seal.storage_addr);
    writer.writeU64(seal.owner_incarnation);
    writer.writeU8(@intFromEnum(seal.role));
    writer.writeBool(seal.generation_tracked);
    writer.writeU64(seal.generation);
    writer.writeU8(@intFromEnum(seal.flow));
    return writer.finish();
}

fn bindOwnerAuthority(storage: *ExternalPumpStorage) void {
    const authority = storage.owner_authority.current;
    const tracked = authority.generation == .tracked;
    const generation = switch (authority.generation) {
        .untracked => 0,
        .tracked => |value| value,
    };
    storage.owner_authority_seal = .{
        .storage_addr = @intFromPtr(storage),
        .owner_incarnation = storage.owner_incarnation,
        .role = authority.role,
        .generation_tracked = tracked,
        .generation = generation,
        .flow = authority.flow,
    };
    storage.owner_authority_seal.digest =
        ownerAuthoritySealDigest(storage.owner_authority_seal);
}

fn ownerAuthorityValid(storage: *const ExternalPumpStorage) bool {
    const authority = switch (storage.owner_authority) {
        .current => |authority| authority,
        .empty => return false,
    };
    const seal = storage.owner_authority_seal;
    const generation = switch (authority.generation) {
        .untracked => 0,
        .tracked => |value| value,
    };
    return seal.storage_addr == @intFromPtr(storage) and
        seal.owner_incarnation == storage.owner_incarnation and
        seal.role == authority.role and
        seal.generation_tracked == (authority.generation == .tracked) and
        seal.generation == generation and seal.flow == authority.flow and
        std.mem.eql(u8, &seal.digest, &ownerAuthoritySealDigest(seal));
}

const OwnerScalarTakeLifecycle = enum {
    empty,
    prepared,
    committed_tombstone,
    aborted_tombstone,
};

pub const PreparedOwnerScalarTake = struct {
    saved_self_addr: usize = 0,
    prepared_addr: usize = 0,
    storage_addr: usize = 0,
    resize_addr: usize = 0,
    authority_addr: usize = 0,
    request_addr: usize = 0,
    resize: ?resize_wire.Event = null,
    authority: OwnerAuthorityState = .empty,
    request_ids: client_pump.RequestIdState = .{ .available = 1 },
    lifecycle: OwnerScalarTakeLifecycle = .empty,

    pub fn validate(
        self: *const PreparedOwnerScalarTake,
        storage: *const ExternalPumpStorage,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.prepared_addr != @intFromPtr(&storage.prepared_adoption) or
            self.storage_addr != @intFromPtr(storage) or
            self.resize_addr != @intFromPtr(&storage.owner_resize) or
            self.authority_addr != @intFromPtr(&storage.owner_authority) or
            self.request_addr != @intFromPtr(&storage.owner_request_ids) or
            storage.owner_authority != .empty or
            storage.owner_request_ids != null or
            !storage.validatePreparedSources(storage.lifecycle))
            return false;
        const decision = storage.prepared_adoption.source_decision orelse return false;
        const live = switch (decision.verdict) {
            .adopted => |adopted| adopted,
            else => return false,
        };
        const expected_resize = if (live.resize) |candidate| candidate.event else null;
        const expected_authority = OwnerAuthorityState{ .current = .{
            .role = switch (live.authority.role) {
                .observer => .observer,
                .controller => .controller,
            },
            .generation = switch (live.authority.generation) {
                .untracked => .untracked,
                .tracked => |generation| .{ .tracked = generation },
            },
            .flow = .initial_fence,
        } };
        return std.meta.eql(self.resize, expected_resize) and
            std.meta.eql(self.authority, expected_authority) and
            std.meta.eql(
                self.request_ids,
                decision.request_state orelse return false,
            );
    }

    pub fn abort(self: *PreparedOwnerScalarTake) void {
        if (self.saved_self_addr != 0 and
            self.saved_self_addr != @intFromPtr(self))
            return;
        self.* = .{ .lifecycle = .aborted_tombstone };
    }
};

pub const RetryablePrepareReason = enum {
    out_of_memory,
    transaction_busy,
};

pub const AdoptionPrepareStatus = union(enum) {
    prepared_adopted,
    recovery_committed,
    terminal_latched,
    retryable_preserved: RetryablePrepareReason,
};

pub const CommitAdoptionResult = enum {
    adopted,
    terminal_latched,
    transaction_busy,
    dead,
};

const CommitPhase = enum {
    ledger_seed,
    screen_destination,
    metadata_destination,
    scalar_destination,
    client_cleanup_take,
    prepared_tombstone,
    semantic_active,
    lifecycle_live,
};

const NoopCommitRecorder = struct {
    inline fn beforePermit(
        _: *NoopCommitRecorder,
        backlog: *client_external_adoption.PreparedScreenBacklog,
        ledger: *external_inbox_ledger.ExternalInboxLedger,
    ) void {
        _ = backlog;
        _ = ledger;
    }
    inline fn record(_: *NoopCommitRecorder, _: CommitPhase) void {}
};

threadlocal var test_cleanup_scratch: if (builtin.is_test)
    ExternalPumpCleanupScratch
else
    u8 = if (builtin.is_test) .{} else 0;

fn prepareAdoptionForTest(storage: *ExternalPumpStorage) AdoptionPrepareStatus {
    if (comptime !builtin.is_test) unreachable;
    if (test_cleanup_scratch.lifecycle == .empty and
        !test_cleanup_scratch.initInPlace())
        @panic("test cleanup scratch initialization failed");
    return storage.prepareAdoption(1, &test_cleanup_scratch);
}

const AdoptionLifecycle = EvidenceLifecycle;
const PreparedAdoptionBranch = enum {
    none,
    adopted,
};

const FinalSealLifecycle = enum {
    empty,
    prepared,
    consumed_tombstone,
    aborted_tombstone,
};

const PreparedAdoptionFinalSeal = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    plan_addr: usize = 0,
    client_addr: usize = 0,
    ledger_addr: usize = 0,
    evidence_addr: usize = 0,
    client_cleanup_take_addr: usize = 0,
    screen_take_addr: usize = 0,
    metadata_take_addr: usize = 0,
    scalar_take_addr: usize = 0,
    committed_screen_addr: usize = 0,
    screen_pending_summary_addr: usize = 0,
    owner_metadata_addr: usize = 0,
    metadata_pending_summary_addr: usize = 0,
    owner_resize_addr: usize = 0,
    owner_authority_addr: usize = 0,
    owner_request_ids_addr: usize = 0,
    operation_generation: u64 = 0,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: FinalSealLifecycle = .empty,

    fn abort(self: *PreparedAdoptionFinalSeal) void {
        if (self.saved_self_addr != 0 and
            self.saved_self_addr != @intFromPtr(self))
            return;
        self.* = .{ .lifecycle = .aborted_tombstone };
    }
};

const AdoptedCommitPermit = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    operation_generation: u64 = 0,
    final_seal_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    consumed: bool = false,

    fn validate(
        self: *const AdoptedCommitPermit,
        storage: *const ExternalPumpStorage,
    ) bool {
        return !self.consumed and
            self.saved_self_addr == @intFromPtr(self) and
            self.storage_addr == @intFromPtr(storage) and
            self.operation_generation == storage.operation_generation and
            std.mem.eql(
                u8,
                &self.final_seal_digest,
                &storage.prepared_adoption.final_seal.digest,
            ) and storage.validateFinalSeal();
    }
};

const AdoptionValidationPhase = enum {
    before_takes,
    prepared_for_commit,
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
    screen_take: client_external_adoption.PreparedCommittedScreenTake = .{},
    metadata_take: external_event_materialization.PreparedOwnerMetadataTake = .{},
    scalar_take: PreparedOwnerScalarTake = .{},
    final_seal: PreparedAdoptionFinalSeal = .{},
    aggregate_resident_bytes: usize = 0,
    aggregate_prepare_peak_bytes: usize = 0,
    backlog: client_external_adoption.PreparedScreenBacklog = .{},
    branch: PreparedAdoptionBranch = .none,
    lifecycle: AdoptionLifecycle = .empty,

    fn deinit(
        self: *PreparedExternalAdoption,
        client_allocator: ?std.mem.Allocator,
    ) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        var screen_backlog_snapshot: client_external_adoption.PreparedScreenBacklog = .{};
        var screen_take_snapshot: client_external_adoption.PreparedCommittedScreenTake = .{};
        var screen_cleanup: client_external_adoption.PreparedAggregateScreenCleanup = .{};
        const screen_cleanup_frozen =
            self.backlog.moveIntoAggregateCleanupSnapshot(
                &self.screen_take,
                &screen_backlog_snapshot,
                &screen_take_snapshot,
            ) and if (client_allocator) |allocator|
                screen_backlog_snapshot.prepareAggregateCleanup(
                    &screen_take_snapshot,
                    allocator,
                    &screen_cleanup,
                )
            else
                false;
        if (!screen_cleanup_frozen)
            self.backlog.abandonAggregateCleanup(&self.screen_take);
        self.final_seal.abort();
        self.scalar_take.abort();
        self.metadata_take.abort();
        self.metadata.deinit();
        if (screen_cleanup_frozen) {
            screen_backlog_snapshot.finishAggregateCleanup(&screen_cleanup);
            screen_take_snapshot.abort();
        }
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
        return self.validateForStorageLifecycle(
            storage,
            .adopting,
            .prepared_for_commit,
        );
    }

    fn validateWhilePreparing(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
    ) bool {
        return self.validateForStorageLifecycle(
            storage,
            .adoption_preparing,
            .prepared_for_commit,
        );
    }

    fn validateWhilePreparingBeforeTake(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
    ) bool {
        return self.validateForStorageLifecycle(
            storage,
            .adoption_preparing,
            .before_takes,
        );
    }

    fn validateForStorageLifecycle(
        self: *const PreparedExternalAdoption,
        storage: *const ExternalPumpStorage,
        expected_storage_lifecycle: StorageLifecycle,
        phase: AdoptionValidationPhase,
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
        {
            return false;
        }
        const client = if (storage.owned_client) |*owned| owned else return false;
        const owned_evidence = if (storage.owned_evidence) |*owned| owned else return false;
        if (!owned_evidence.validate(client) or
            !std.meta.eql(owned_evidence.attachment, storage.evidence_snapshot))
        {
            return false;
        }
        if (self.client_addr != @intFromPtr(client)) {
            return false;
        }
        const view = storage.inbox_ledger.accountingView();
        if (!view.valid or !view.pristine_zero) {
            return false;
        }
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
        )) {
            return false;
        }
        if (decision.verdict != .adopted)
            return false;
        if (self.branch != .adopted) {
            return false;
        }
        const metadata_footprint = self.metadata.footprint(
            client,
            input,
            decision,
            &scratch,
        ) orelse {
            return false;
        };
        if (self.backlog.targetStream() != self.evidence.stream_id) {
            return false;
        }
        if (!self.backlog.validate(client, &storage.inbox_ledger)) {
            return false;
        }
        switch (phase) {
            .before_takes => {
                if (!self.screen_take.isEmpty() or !std.meta.eql(
                    self.metadata_take,
                    external_event_materialization.PreparedOwnerMetadataTake{},
                ) or !std.meta.eql(
                    self.scalar_take,
                    PreparedOwnerScalarTake{},
                ) or !std.meta.eql(
                    self.final_seal,
                    PreparedAdoptionFinalSeal{},
                ) or !storage.client_cleanup_take.isEmpty()) {
                    return false;
                }
            },
            .prepared_for_commit => {
                if (!self.screen_take.validate(
                    &self.backlog,
                    &storage.committed_screen,
                    client,
                    &storage.inbox_ledger,
                    storage,
                ) or !self.metadata_take.validate(
                    &self.metadata,
                    &owned_evidence.seed,
                    &owned_evidence.cleanup_seed,
                    &storage.owner_metadata,
                    @intFromPtr(storage),
                ) or !self.scalar_take.validate(storage) or
                    !storage.client_cleanup_take.validate(
                        client,
                        &self.backlog.client_disarm,
                        &self.backlog.inventory,
                        &self.backlog.cleanup_inventory,
                    )) return false;
            },
        }
        const aggregate = aggregateAdoptionFootprint(
            .{
                .resident = self.backlog.adoption_metadata_resident_bytes,
                .prepare_peak = self.backlog.adoption_metadata_prepare_peak_bytes,
            },
            metadata_footprint,
        ) catch return false;
        if (self.aggregate_resident_bytes != aggregate.resident or
            self.aggregate_prepare_peak_bytes != aggregate.prepare_peak)
        {
            return false;
        }
        return switch (phase) {
            .before_takes => true,
            .prepared_for_commit => storage.validateFinalSeal(),
        };
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
    process_owner_busy,
    process_quarantined,
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
    cleaned_with_invariant,
    already_dead,
    moved_storage,
    transaction_busy,
    quarantined,
};

pub const MetadataStateResult = union(enum) {
    state: external_event_materialization.MetadataStateSummary,
    transaction_busy,
    moved,
    not_active,
    dead,
    invalid_owner,
};

const BorrowedMetadataView = struct {
    revision: u64,
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    semantic_state: runtime_metadata_wire.SemanticPrompt,
    alt_active: bool,
    app_cursor_keys: bool,
    app_keypad: bool,
    kitty_flags: u5,
    alternate_scroll: bool,
    mouse_tracking: bool,
    mouse_tracking_mode: u8,
    bracketed_paste: bool,
    bell_count: u64,
    clipboard_write_seq: u64,
    clipboard_read_seq: u64,
    foreground_available: bool,
    foreground_pgid: ?i32,
    cwd: []const u8,
    window_title: []const u8,
    ssh_remote_dest: ?[]const u8,
    clipboard_read_target: []const u8,
    processes: []const runtime_metadata_wire.Process,
};

const OwnerEventView = union(enum) {
    resized: resize_wire.Event,
    metadata: BorrowedMetadataView,
};

const ProjectionDecision = enum { applied, retry_preserved };

const OwnerEventProjector = struct {
    context: *anyopaque,
    context_len: usize,
    project: *const fn (*anyopaque, OwnerEventView) ProjectionDecision,
};

const ProjectOwnerEventResult = enum {
    applied,
    retry_preserved,
    none,
    fenced,
    transaction_busy,
    moved,
    not_active,
    dead,
    terminal_latched,
};

const OwnerEventKind = enum { resized, metadata };

const OwnerEventKey = union(OwnerEventKind) {
    resized: struct {
        generation: u64,
        cols: u16,
        rows: u16,
    },
    metadata: struct {
        revision: u64,
        raw_digest: runtime_event_wire.Digest,
        semantic_digest: runtime_event_wire.Digest,
    },
};

const OwnerEventPermitLifecycle = enum { empty, prepared, consumed_tombstone };

const OwnerEventPermit = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    owner_incarnation: u64 = 0,
    projection_generation: u64 = 0,
    key: OwnerEventKey = .{ .resized = .{ .generation = 0, .cols = 0, .rows = 0 } },
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: OwnerEventPermitLifecycle = .empty,
};

fn ownerEventPermitDigest(permit: OwnerEventPermit) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUOEP1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.storage_addr);
    writer.writeU64(permit.owner_incarnation);
    writer.writeU64(permit.projection_generation);
    switch (permit.key) {
        .resized => |key| {
            writer.writeU8(0);
            writer.writeU64(key.generation);
            writer.writeU16(key.cols);
            writer.writeU16(key.rows);
        },
        .metadata => |key| {
            writer.writeU8(1);
            writer.writeU64(key.revision);
            writer.writeBytes(&key.raw_digest);
            writer.writeBytes(&key.semantic_digest);
        },
    }
    return writer.finish();
}

fn prepareOwnerEventPermit(
    storage: *const ExternalPumpStorage,
    key: OwnerEventKey,
    next_generation: u64,
    out: *OwnerEventPermit,
) bool {
    if (!std.meta.eql(out.*, OwnerEventPermit{}) or next_generation == 0)
        return false;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .storage_addr = @intFromPtr(storage),
        .owner_incarnation = storage.owner_incarnation,
        .projection_generation = next_generation,
        .key = key,
        .lifecycle = .prepared,
    };
    out.digest = ownerEventPermitDigest(out.*);
    return true;
}

fn ownerEventPermitValid(
    storage: *const ExternalPumpStorage,
    key: OwnerEventKey,
    permit: *const OwnerEventPermit,
) bool {
    return permit.lifecycle == .prepared and
        permit.saved_self_addr == @intFromPtr(permit) and
        permit.storage_addr == @intFromPtr(storage) and
        permit.owner_incarnation == storage.owner_incarnation and
        permit.projection_generation == storage.owner_event_projection_generation and
        std.meta.eql(permit.key, key) and
        std.mem.eql(u8, &permit.digest, &ownerEventPermitDigest(permit.*));
}

fn consumeOwnerEventPermit(permit: *OwnerEventPermit) void {
    permit.* = .{ .lifecycle = .consumed_tombstone };
}

const SelectedOwnerEvent = struct {
    key: OwnerEventKey,
    view: OwnerEventView,
};

const projection_test = if (builtin.is_test) struct {
    const Lifecycle = enum { empty, prepared, consumed_tombstone };
    const InitialFenceClearResult = enum { cleared, invalid };
    const PreparedInitialFenceClear = struct {
        storage_addr: usize = 0,
        owner_incarnation: u64 = 0,
        authority_generation: u64 = 0,
        final_addr: usize = 0,
        digest: external_owner_seal.Digest = [_]u8{0} ** 32,
        lifecycle: Lifecycle = .empty,
    };

    fn digest(permit: PreparedInitialFenceClear) external_owner_seal.Digest {
        var writer = external_owner_seal.Writer.init("MARUIFC1");
        writer.writeUsize(permit.storage_addr);
        writer.writeU64(permit.owner_incarnation);
        writer.writeU64(permit.authority_generation);
        writer.writeUsize(permit.final_addr);
        return writer.finish();
    }

    fn prepare(
        storage: *const ExternalPumpStorage,
        out: *PreparedInitialFenceClear,
    ) bool {
        if (!ownerIncarnationValid(storage) or !ownerAuthorityValid(storage))
            return false;
        const authority = switch (storage.owner_authority) {
            .current => |authority| authority,
            .empty => return false,
        };
        if (!std.meta.eql(out.*, PreparedInitialFenceClear{}) or
            authority.flow != .initial_fence)
            return false;
        const generation = switch (authority.generation) {
            .untracked => 0,
            .tracked => |generation| generation,
        };
        out.* = .{
            .storage_addr = @intFromPtr(storage),
            .owner_incarnation = storage.owner_incarnation,
            .authority_generation = generation,
            .final_addr = @intFromPtr(out),
            .lifecycle = .prepared,
        };
        out.digest = digest(out.*);
        return true;
    }

    fn commit(
        storage: *ExternalPumpStorage,
        permit: *PreparedInitialFenceClear,
    ) InitialFenceClearResult {
        if (active_external_operation_addr != 0) return .invalid;
        active_external_operation_addr = @intFromPtr(storage);
        defer active_external_operation_addr = 0;
        if (!ownerIncarnationValid(storage) or !ownerAuthorityValid(storage))
            return .invalid;
        const authority = switch (storage.owner_authority) {
            .current => |*authority| authority,
            .empty => return .invalid,
        };
        const generation = switch (authority.generation) {
            .untracked => 0,
            .tracked => |generation| generation,
        };
        if (permit.lifecycle != .prepared or
            permit.final_addr != @intFromPtr(permit) or
            permit.storage_addr != @intFromPtr(storage) or
            permit.owner_incarnation != storage.owner_incarnation or
            permit.authority_generation != generation or
            !std.mem.eql(u8, &permit.digest, &digest(permit.*)) or
            authority.flow != .initial_fence)
            return .invalid;
        authority.flow = .clear;
        bindOwnerAuthority(storage);
        permit.* = .{ .lifecycle = .consumed_tombstone };
        return .cleared;
    }
} else struct {};

const UncommittedCloseResult = enum {
    cleaned,
    cleaned_with_invariant,
    invalid_committed_owner,
};

pub const AccessError = error{
    Empty,
    NotActive,
    Terminal,
    MovedStorage,
    TransactionBusy,
    InvalidDescriptor,
    GenerationExhausted,
    InvalidSnapshot,
};

pub const ScreenConsumeError =
    AccessError || external_inbox_ledger.ScreenRetirementError || error{TransactionBusy};

const InitOptions = struct {
    failpoint: enum {
        none,
        after_paired_take,
    } = .none,
    resident_cap: usize = protocol.max_binary_chunk + protocol.header_size,
    /// Unit fixtures may construct independent owners in one test process to exercise re-entry
    /// and failure precedence. Product builds can never bypass the process reservation.
    test_skip_process_owner_reservation: bool = false,
};

pub const max_fixed_inline_storage_bytes: usize = 512 * 1024;
pub const max_cross_owner_quarantine_bytes: usize =
    max_fixed_inline_storage_bytes +
    external_inbox_ledger.max_bytes +
    external_adoption_limits.max_metadata_bytes +
    (2 * protocol.max_viewport_snapshot) +
    (4 * protocol.max_client_queue) +
    (4 * protocol.max_control_json);

pub const CrossOwnerQuarantineStatus = struct {
    latched: bool,
    event_count: u64,
    leaked_bytes_upper_bound: usize,
};

// `initInPlace` is thread-confined, but an allocator callback may synchronously re-enter it on the
// same thread before destination alias proof is allowed to read `out`. Keep that earliest latch
// out-of-band so hostile `out` aliases are not dereferenced or mutated before the proof.
threadlocal var initializing_storage_addr: usize = 0;
// Allocation callbacks are arbitrary user code. Prepare, commit, and teardown share one
// process-thread lease so re-entrant public operations cannot create a second state machine.
threadlocal var active_external_operation_addr: usize = 0;
threadlocal var active_external_lease_addr: usize = 0;
threadlocal var active_external_lease_generation: u64 = 0;
var cross_owner_quarantine_latched: std.atomic.Value(bool) = .init(false);
var cross_owner_quarantine_events: std.atomic.Value(u64) = .init(0);
var active_storage_addr: std.atomic.Value(usize) = .init(0);

const WholeTurnLeaseLifecycle = enum {
    empty,
    acquired,
    released,
    aborted,
};

pub const ExternalWholeTurnLease = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    scratch_addr: usize = 0,
    scratch_len: usize = 0,
    operation_generation: u64 = 0,
    lifecycle: WholeTurnLeaseLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const WholeTurnReleaseResult = enum {
    released,
    aborted_terminal,
    ignored_untrusted,
};

const PendingSummaryLifecycle = enum {
    empty,
    bound,
    tombstone,
};

const ScreenPendingSummarySeal = struct {
    screen_owner_addr: usize = 0,
    storage_addr: usize = 0,
    owner_incarnation: u64 = 0,
    retained_count: usize = 0,
    committed: bool = false,
    generation: u64 = 0,
    lifecycle: PendingSummaryLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const MetadataPendingSummarySeal = struct {
    metadata_owner_addr: usize = 0,
    storage_addr: usize = 0,
    owner_incarnation: u64 = 0,
    revision: u64 = 0,
    pending: bool = false,
    supported: bool = false,
    generation: u64 = 0,
    lifecycle: PendingSummaryLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const InheritedSnapshotLifecycle = enum {
    empty,
    prepared,
    consumed,
    aborted,
};

pub const InheritedRxBlockerSnapshot = struct {
    saved_self_addr: usize = 0,
    storage_addr: usize = 0,
    lease_addr: usize = 0,
    operation_generation: u64 = 0,
    committed_screen_pending: bool = false,
    live_screen_pending: bool = false,
    metadata_projection_pending: bool = false,
    resize_projection_pending: bool = false,
    response_correlation_pending: bool = false,
    authority_generation: AuthorityGeneration = .untracked,
    generation: u64 = 0,
    lifecycle: InheritedSnapshotLifecycle = .empty,
    owner_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,

    pub fn hasBlocker(self: *const InheritedRxBlockerSnapshot) bool {
        return self.lifecycle == .prepared and
            (self.committed_screen_pending or self.live_screen_pending or
                self.metadata_projection_pending or self.resize_projection_pending or
                self.response_correlation_pending);
    }
};

fn wholeTurnLeaseDigest(lease: ExternalWholeTurnLease) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUWTL1");
    writer.writeUsize(lease.saved_self_addr);
    writer.writeUsize(lease.storage_addr);
    writer.writeUsize(lease.scratch_addr);
    writer.writeUsize(lease.scratch_len);
    writer.writeU64(lease.operation_generation);
    writer.writeU8(@intFromEnum(lease.lifecycle));
    return writer.finish();
}

fn screenPendingSummaryDigest(
    seal: ScreenPendingSummarySeal,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUSPS1");
    writer.writeUsize(seal.screen_owner_addr);
    writer.writeUsize(seal.storage_addr);
    writer.writeU64(seal.owner_incarnation);
    writer.writeUsize(seal.retained_count);
    writer.writeBool(seal.committed);
    writer.writeU64(seal.generation);
    writer.writeU8(@intFromEnum(seal.lifecycle));
    return writer.finish();
}

fn metadataPendingSummaryDigest(
    seal: MetadataPendingSummarySeal,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUMPS1");
    writer.writeUsize(seal.metadata_owner_addr);
    writer.writeUsize(seal.storage_addr);
    writer.writeU64(seal.owner_incarnation);
    writer.writeU64(seal.revision);
    writer.writeBool(seal.pending);
    writer.writeBool(seal.supported);
    writer.writeU64(seal.generation);
    writer.writeU8(@intFromEnum(seal.lifecycle));
    return writer.finish();
}

fn metadataPendingSealFromSummary(
    storage: *const ExternalPumpStorage,
    summary: external_event_materialization.MetadataStateSummary,
    generation: u64,
) MetadataPendingSummarySeal {
    var seal = MetadataPendingSummarySeal{
        .metadata_owner_addr = @intFromPtr(&storage.owner_metadata),
        .storage_addr = @intFromPtr(storage),
        .owner_incarnation = storage.owner_incarnation,
        .generation = generation,
        .lifecycle = .bound,
    };
    switch (summary) {
        .unsupported => {},
        .unavailable => seal.supported = true,
        .current => |current| {
            seal.supported = true;
            seal.revision = current.revision;
            seal.pending = current.pending;
        },
    }
    seal.digest = metadataPendingSummaryDigest(seal);
    return seal;
}

fn inheritedSnapshotDigest(
    snapshot: InheritedRxBlockerSnapshot,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUIRS1");
    writer.writeUsize(snapshot.saved_self_addr);
    writer.writeUsize(snapshot.storage_addr);
    writer.writeUsize(snapshot.lease_addr);
    writer.writeU64(snapshot.operation_generation);
    writer.writeBool(snapshot.committed_screen_pending);
    writer.writeBool(snapshot.live_screen_pending);
    writer.writeBool(snapshot.metadata_projection_pending);
    writer.writeBool(snapshot.resize_projection_pending);
    writer.writeBool(snapshot.response_correlation_pending);
    switch (snapshot.authority_generation) {
        .untracked => writer.writeBool(false),
        .tracked => |generation| {
            writer.writeBool(true);
            writer.writeU64(generation);
        },
    }
    writer.writeU64(snapshot.generation);
    writer.writeU8(@intFromEnum(snapshot.lifecycle));
    writer.writeBytes(&snapshot.owner_digest);
    return writer.finish();
}

pub fn crossOwnerQuarantineStatus() CrossOwnerQuarantineStatus {
    const latched = cross_owner_quarantine_latched.load(.acquire);
    const events = cross_owner_quarantine_events.load(.acquire);
    return .{
        .latched = latched,
        .event_count = events,
        .leaked_bytes_upper_bound = if (latched)
            max_cross_owner_quarantine_bytes
        else
            0,
    };
}

const ExternalPumpCleanupScratchLifecycle = enum {
    empty,
    ready,
    frozen,
    poisoned,
};
const ExternalPumpRangeScratchKind = enum { source, teardown };

/// Persistent caller-owned cleanup authority shared by prepare and its immediate suffix.
///
/// The aggregate is initialized only at its final address. A successful recovery or terminal
/// suffix freezes its descriptors before the first allocator callback and restores `.ready` only
/// after every descriptor has been consumed.
pub const ExternalPumpCleanupScratch = struct {
    saved_self_addr: usize = 0,
    lifecycle: ExternalPumpCleanupScratchLifecycle = .empty,
    client: client_mod.ExternalAdoptionCleanupScratch = undefined,
    range_scratch_kind: ExternalPumpRangeScratchKind = .source,
    range_scratch: union {
        source: client_mod.ExternalSourceOwnerRangeScratch,
        teardown: external_owner_range.Scratch,
    } = .{ .source = .{} },
    recovery_discard: client_mod.ExternalRecoveryDiscardSeal = .{},
    ledger_permit: external_inbox_ledger.OwnerTeardownPermit = .{},
    ledger_prepared: external_inbox_ledger.PreparedLedgerTeardown = .{},
    ledger_frozen: external_inbox_ledger.FrozenLedgerCleanup = .{},
    screen_plan: external_inbox_ledger.FrozenScreenTokenPlan = .{},
    screen_prepared: client_external_adoption.PreparedCommittedScreenCleanup = .{},
    screen_frozen: client_external_adoption.FrozenCommittedScreenCleanup = .{},
    metadata_prepared: external_event_materialization.PreparedOwnerMetadataCleanup = .{},
    metadata_frozen: external_event_materialization.FrozenOwnerMetadataCleanup = .{},
    take_prepared: client_mod.PreparedExternalAdoptionTakeCleanup = .{},
    take_frozen: client_mod.FrozenExternalAdoptionTakeCleanup = .{},
    moved_client: ?client_mod.Client = null,
    moved_evidence: ?PreparedAdoptionEvidence = null,

    pub fn initInPlace(out: *ExternalPumpCleanupScratch) bool {
        if (out.lifecycle != .empty or out.saved_self_addr != 0) return false;
        out.saved_self_addr = @intFromPtr(out);
        out.lifecycle = .ready;
        out.range_scratch_kind = .source;
        out.range_scratch.source = .{};
        out.recovery_discard = .{};
        out.ledger_permit = .{};
        out.ledger_prepared = .{};
        out.ledger_frozen = .{};
        out.screen_plan = .{};
        out.screen_prepared = .{};
        out.screen_frozen = .{};
        out.metadata_prepared = .{};
        out.metadata_frozen = .{};
        out.take_prepared = .{};
        out.take_frozen = .{};
        out.moved_client = null;
        out.moved_evidence = null;
        return true;
    }

    fn isReady(self: *const ExternalPumpCleanupScratch) bool {
        return self.saved_self_addr == @intFromPtr(self) and
            self.lifecycle == .ready and
            self.range_scratch_kind == .source and
            self.recovery_discard.isEmpty() and
            self.ledger_permit.saved_self_addr == 0 and
            self.ledger_prepared.saved_self_addr == 0 and
            self.ledger_frozen.saved_self_addr == 0 and
            self.screen_plan.saved_self_addr == 0 and
            self.screen_prepared.saved_self_addr == 0 and
            self.screen_frozen.saved_self_addr == 0 and
            self.metadata_prepared.saved_self_addr == 0 and
            self.metadata_frozen.saved_self_addr == 0 and
            self.take_prepared.saved_self_addr == 0 and
            self.take_frozen.saved_self_addr == 0 and
            self.moved_client == null and self.moved_evidence == null;
    }

    fn resetReady(self: *ExternalPumpCleanupScratch) void {
        self.saved_self_addr = @intFromPtr(self);
        self.range_scratch_kind = .source;
        self.range_scratch.source = .{};
        self.recovery_discard = .{};
        self.ledger_permit = .{};
        self.ledger_prepared = .{};
        self.ledger_frozen = .{};
        self.screen_plan = .{};
        self.screen_prepared = .{};
        self.screen_frozen = .{};
        self.metadata_prepared = .{};
        self.metadata_frozen = .{};
        self.take_prepared = .{};
        self.take_frozen = .{};
        self.moved_client = null;
        self.moved_evidence = null;
        self.lifecycle = .ready;
    }
};

pub const max_external_pump_cleanup_scratch_bytes: usize = 1024 * 1024;
pub const max_external_pump_callback_local_bytes: usize = 768 * 1024;

comptime {
    if (@sizeOf(ExternalPumpCleanupScratch) >
        max_external_pump_cleanup_scratch_bytes)
        @compileError("external pump cleanup scratch exceeds 1 MiB");
    const callback_local_bytes =
        @sizeOf(external_inbox_ledger.FrozenLedgerCleanup) +
        @sizeOf(external_event_materialization.FrozenOwnerMetadataCleanup) +
        @sizeOf(client_mod.FrozenExternalAdoptionTakeCleanup) +
        @sizeOf(client_mod.ExternalAdoptionCleanupScratch) +
        @sizeOf(client_external_adoption.FrozenCommittedScreenCleanup) +
        @sizeOf(client_mod.Client) +
        @sizeOf(PreparedAdoptionEvidence);
    if (callback_local_bytes > max_external_pump_callback_local_bytes)
        @compileError("external pump callback-hidden locals exceed 768 KiB");
}

fn resetCrossOwnerQuarantineForTest() void {
    cross_owner_quarantine_events.store(0, .release);
    cross_owner_quarantine_latched.store(false, .release);
}

fn releaseActiveStorage(address: usize) void {
    _ = active_storage_addr.cmpxchgStrong(
        address,
        0,
        .acq_rel,
        .acquire,
    );
}

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
    client_cleanup_take: client_mod.ExternalAdoptionTake = .{},
    committed_screen: client_external_adoption.CommittedScreenBacklog = .{},
    screen_pending_summary: ScreenPendingSummarySeal = .{},
    owner_metadata: external_event_materialization.OwnerMetadataState = .{},
    metadata_pending_summary: MetadataPendingSummarySeal = .{},
    owner_resize: OwnerResizeState = .none,
    owner_authority: OwnerAuthorityState = .empty,
    owner_authority_seal: OwnerAuthoritySeal = .{},
    owner_request_ids: ?client_pump.RequestIdState = null,
    owner_incarnation: u64 = 0,
    owner_incarnation_seal: OwnerIncarnationSeal = .{},
    owner_event_projection_generation: u64 = 0,
    operation_generation: u64 = 0,
    owner_teardown_generation: u64 = 0,

    fn bindPendingSummaries(self: *ExternalPumpStorage) void {
        self.screen_pending_summary = .{
            .screen_owner_addr = @intFromPtr(&self.committed_screen),
            .storage_addr = @intFromPtr(self),
            .owner_incarnation = self.owner_incarnation,
            .retained_count = self.committed_screen.retained_count,
            // The final permit proved the destination was pristine and the preceding no-fail take
            // published the committed owner. Revalidation belongs to readers, not this suffix.
            .committed = true,
            .generation = 1,
            .lifecycle = .bound,
        };
        self.screen_pending_summary.digest =
            screenPendingSummaryDigest(self.screen_pending_summary);
        const summary = switch (self.owner_metadata.metadata) {
            .unsupported => external_event_materialization.MetadataStateSummary.unsupported,
            .unavailable => external_event_materialization.MetadataStateSummary.unavailable,
            .current => |current| external_event_materialization.MetadataStateSummary{
                .current = .{
                    .revision = current.logical.revision,
                    .pending = current.pending,
                },
            },
        };
        self.metadata_pending_summary = metadataPendingSealFromSummary(
            self,
            summary,
            1,
        );
    }

    fn screenPendingSummaryValid(self: *const ExternalPumpStorage) bool {
        const seal = self.screen_pending_summary;
        const retained_count =
            self.committed_screen.pendingCountSummary(self) orelse return false;
        return seal.lifecycle == .bound and
            seal.screen_owner_addr == @intFromPtr(&self.committed_screen) and
            seal.storage_addr == @intFromPtr(self) and
            seal.owner_incarnation == self.owner_incarnation and
            seal.retained_count == retained_count and seal.committed and
            std.mem.eql(u8, &seal.digest, &screenPendingSummaryDigest(seal));
    }

    fn metadataPendingSummaryValid(self: *const ExternalPumpStorage) bool {
        const seal = self.metadata_pending_summary;
        if (seal.lifecycle != .bound or
            seal.metadata_owner_addr != @intFromPtr(&self.owner_metadata) or
            seal.storage_addr != @intFromPtr(self) or
            seal.owner_incarnation != self.owner_incarnation or
            !std.mem.eql(u8, &seal.digest, &metadataPendingSummaryDigest(seal)))
            return false;
        const summary = self.owner_metadata.pendingStateSummary(self) orelse return false;
        return switch (summary) {
            .unsupported => !seal.supported and seal.revision == 0 and !seal.pending,
            .unavailable => seal.supported and seal.revision == 0 and !seal.pending,
            .current => |current| seal.supported and
                seal.revision == current.revision and
                seal.pending == current.pending,
        };
    }

    fn tombstonePendingSummaries(self: *ExternalPumpStorage) void {
        self.screen_pending_summary = .{ .lifecycle = .tombstone };
        self.metadata_pending_summary = .{ .lifecycle = .tombstone };
    }

    fn wholeTurnScratchDisjoint(
        self: *const ExternalPumpStorage,
        scratch_addr: usize,
        scratch_len: usize,
    ) bool {
        if (scratch_addr == 0 or scratch_len == 0) return false;
        _ = std.math.add(usize, scratch_addr, scratch_len) catch return false;
        if (self.inbox_ledger.overlapsOwnedRange(scratch_addr, scratch_len) or
            self.committed_screen.overlapsOwnedBacking(scratch_addr, scratch_len))
            return false;
        if (self.owner_metadata.metadata == .current) {
            const current = &self.owner_metadata.metadata.current;
            if (current.logical.backing) |backing|
                if (rangesOverlap(
                    scratch_addr,
                    scratch_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
            if (current.cleanup.backing) |backing|
                if (rangesOverlap(
                    scratch_addr,
                    scratch_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
        }
        const take_overlap = self.client_cleanup_take.overlapsCommittedOwnedRange(
            scratch_addr,
            scratch_len,
        ) orelse return false;
        if (take_overlap) return false;
        if (self.owned_client) |*owned| {
            var source_ranges: client_mod.ExternalSourceOwnerRangeScratch = .{};
            owned.preflightExternalAdoptionDestinationWithScratch(
                @ptrFromInt(scratch_addr),
                scratch_len,
                &source_ranges,
            ) catch return false;
        }
        return true;
    }

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
        if (options.test_skip_process_owner_reservation and !builtin.is_test)
            unreachable;
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
        if (cross_owner_quarantine_latched.load(.acquire))
            return failed(.process_quarantined, .preserved);
        const out_addr = @intFromPtr(out);
        if (initializing_storage_addr != 0)
            return failed(.destination_not_empty, .preserved);
        initializing_storage_addr = out_addr;
        defer initializing_storage_addr = 0;
        const reserve_process_owner = !options.test_skip_process_owner_reservation;
        if (reserve_process_owner) {
            if (active_storage_addr.cmpxchgStrong(
                0,
                out_addr,
                .acq_rel,
                .acquire,
            ) != null)
                return failed(.process_owner_busy, .preserved);
        }
        var retain_active_reservation = false;
        defer if (reserve_process_owner and !retain_active_reservation)
            releaseActiveStorage(out_addr);
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
            .operation_generation = 0,
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
            _ = out.closeUncommittedOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        if (options.failpoint == .after_paired_take) {
            _ = out.closeUncommittedOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        const finish_outcome = client_mod.Client.finishExternalPumpTransfer(
            &out.client_transfer,
            &out.owned_client,
        );
        if (finish_outcome == .quarantined) {
            _ = out.closeUncommittedOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        out.lifecycle = .adopting;
        out.semantic_state = .adopting;
        retain_active_reservation = reserve_process_owner;
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

    /// Hold the process-thread operation reservation across the complete RX policy turn.
    pub fn acquireWholeTurnLease(
        self: *ExternalPumpStorage,
        out: *ExternalWholeTurnLease,
        scratch_addr: usize,
        scratch_len: usize,
    ) AccessError!void {
        if (active_external_operation_addr != 0) return error.TransactionBusy;
        try self.requireActive();
        if (!std.meta.eql(out.*, ExternalWholeTurnLease{}))
            return error.InvalidDescriptor;
        const out_addr = @intFromPtr(out);
        _ = std.math.add(usize, out_addr, @sizeOf(ExternalWholeTurnLease)) catch
            return error.InvalidDescriptor;
        _ = std.math.add(usize, scratch_addr, scratch_len) catch
            return error.InvalidDescriptor;
        if (rangesOverlap(
            out_addr,
            @sizeOf(ExternalWholeTurnLease),
            @intFromPtr(self),
            @sizeOf(ExternalPumpStorage),
        ) or rangesOverlap(
            out_addr,
            @sizeOf(ExternalWholeTurnLease),
            scratch_addr,
            scratch_len,
        ) or rangesOverlap(
            scratch_addr,
            scratch_len,
            @intFromPtr(self),
            @sizeOf(ExternalPumpStorage),
        ))
            return error.InvalidDescriptor;
        if (!self.wholeTurnScratchDisjoint(scratch_addr, scratch_len))
            return error.InvalidDescriptor;
        if (self.operation_generation == std.math.maxInt(u64))
            return error.GenerationExhausted;
        active_external_operation_addr = @intFromPtr(self);
        self.operation_generation += 1;
        out.* = .{
            .saved_self_addr = out_addr,
            .storage_addr = @intFromPtr(self),
            .scratch_addr = scratch_addr,
            .scratch_len = scratch_len,
            .operation_generation = self.operation_generation,
            .lifecycle = .acquired,
        };
        out.digest = wholeTurnLeaseDigest(out.*);
        active_external_lease_addr = out_addr;
        active_external_lease_generation = self.operation_generation;
    }

    pub fn validateWholeTurnLease(
        self: *const ExternalPumpStorage,
        lease: *const ExternalWholeTurnLease,
    ) bool {
        return self.wholeTurnLeaseIdentityValid(lease) and
            self.lifecycle == .live and
            self.semantic_state == .active;
    }

    fn wholeTurnLeaseIdentityValid(
        self: *const ExternalPumpStorage,
        lease: *const ExternalWholeTurnLease,
    ) bool {
        return active_external_operation_addr == @intFromPtr(self) and
            self.saved_self_addr == @intFromPtr(self) and
            active_external_lease_addr == @intFromPtr(lease) and
            active_external_lease_generation == self.operation_generation and
            lease.saved_self_addr == @intFromPtr(lease) and
            lease.storage_addr == @intFromPtr(self) and
            lease.operation_generation == self.operation_generation and
            lease.lifecycle == .acquired and
            std.mem.eql(u8, &lease.digest, &wholeTurnLeaseDigest(lease.*));
    }

    pub fn releaseWholeTurnLease(
        self: *ExternalPumpStorage,
        lease: *ExternalWholeTurnLease,
    ) WholeTurnReleaseResult {
        if (active_external_operation_addr != @intFromPtr(self) or
            active_external_lease_addr != @intFromPtr(lease) or
            active_external_lease_generation == 0)
            return .ignored_untrusted;
        const intact_identity = self.wholeTurnLeaseIdentityValid(lease);
        if (intact_identity and
            self.lifecycle == .live and
            (self.semantic_state == .active or self.semantic_state == .terminal))
        {
            lease.* = .{ .lifecycle = .released };
            active_external_lease_addr = 0;
            active_external_lease_generation = 0;
            active_external_operation_addr = 0;
            return .released;
        }
        if (intact_identity)
            lease.* = .{ .lifecycle = .aborted };
        // The thread-local final address is the private outer-owner authority. A copied or foreign
        // lease cannot reach this branch. Restore the lifecycle proven at acquire so a hostile
        // storage-header drift cannot forge moved/dead and bypass cleanup. If the lease descriptor
        // drifted, do not dereference it again after the identity verdict.
        self.saved_self_addr = @intFromPtr(self);
        self.lifecycle = .live;
        self.semantic_state = .{ .terminal = .{
            .reason = .invariant_failure,
            .fd_disposition = .owner_cleanup,
        } };
        active_external_lease_addr = 0;
        active_external_lease_generation = 0;
        active_external_operation_addr = 0;
        return .aborted_terminal;
    }

    pub fn snapshotInheritedRxBlockersUnderHeldLease(
        self: *const ExternalPumpStorage,
        lease: *const ExternalWholeTurnLease,
        out: *InheritedRxBlockerSnapshot,
    ) AccessError!void {
        if (!self.validateWholeTurnLease(lease))
            return error.TransactionBusy;
        if (!std.meta.eql(out.*, InheritedRxBlockerSnapshot{}))
            return error.InvalidSnapshot;
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(InheritedRxBlockerSnapshot),
            @intFromPtr(self),
            @sizeOf(ExternalPumpStorage),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(InheritedRxBlockerSnapshot),
            @intFromPtr(lease),
            @sizeOf(ExternalWholeTurnLease),
        ))
            return error.InvalidDescriptor;
        if (!rangeContains(
            lease.scratch_addr,
            lease.scratch_len,
            @intFromPtr(out),
            @sizeOf(InheritedRxBlockerSnapshot),
        ))
            return error.InvalidDescriptor;
        const snapshot = try self.expectedInheritedSnapshot(lease, out);
        out.* = snapshot;
    }

    pub fn validateAndConsumeInheritedSnapshot(
        self: *const ExternalPumpStorage,
        lease: *const ExternalWholeTurnLease,
        snapshot: *InheritedRxBlockerSnapshot,
    ) AccessError!bool {
        if (!self.validateWholeTurnLease(lease))
            return error.TransactionBusy;
        if (snapshot.lifecycle != .prepared or
            snapshot.saved_self_addr != @intFromPtr(snapshot))
            return error.InvalidSnapshot;
        const expected = try self.expectedInheritedSnapshot(lease, snapshot);
        if (!std.meta.eql(snapshot.*, expected))
            return error.InvalidSnapshot;
        const blocked = snapshot.hasBlocker();
        snapshot.* = .{ .lifecycle = .consumed };
        return blocked;
    }

    fn expectedInheritedSnapshot(
        self: *const ExternalPumpStorage,
        lease: *const ExternalWholeTurnLease,
        out: *const InheritedRxBlockerSnapshot,
    ) AccessError!InheritedRxBlockerSnapshot {
        if (!ownerIncarnationValid(self) or !ownerAuthorityValid(self) or
            !ownerResizeValid(self) or !self.screenPendingSummaryValid() or
            !self.metadataPendingSummaryValid())
            return error.InvalidSnapshot;
        const authority_generation = self.owner_authority.current.generation;
        var result = InheritedRxBlockerSnapshot{
            .saved_self_addr = @intFromPtr(out),
            .storage_addr = @intFromPtr(self),
            .lease_addr = @intFromPtr(lease),
            .operation_generation = self.operation_generation,
            .committed_screen_pending = self.screen_pending_summary.retained_count != 0,
            // d2b3 binds these two persistent owners; d2b1 seals their canonical absence.
            .live_screen_pending = false,
            .metadata_projection_pending = self.metadata_pending_summary.pending,
            .resize_projection_pending = switch (self.owner_resize) {
                .none => false,
                .current => |current| current.pending,
            },
            .response_correlation_pending = false,
            .authority_generation = authority_generation,
            .generation = self.operation_generation,
            .lifecycle = .prepared,
            .owner_digest = self.inheritedOwnerDigest(),
        };
        result.digest = inheritedSnapshotDigest(result);
        return result;
    }

    fn inheritedOwnerDigest(
        self: *const ExternalPumpStorage,
    ) external_owner_seal.Digest {
        var writer = external_owner_seal.Writer.init("MARUIRX1");
        writer.writeBytes(&self.owner_incarnation_seal.digest);
        writer.writeBytes(&self.screen_pending_summary.digest);
        writer.writeBytes(&self.metadata_pending_summary.digest);
        switch (self.owner_resize) {
            .none => writer.writeBool(false),
            .current => |current| {
                writer.writeBool(true);
                writer.writeBytes(&current.seal.digest);
            },
        }
        writer.writeBytes(&self.owner_authority_seal.digest);
        writer.writeU64(self.operation_generation);
        return writer.finish();
    }

    /// Pointer-free metadata query. Invalid committed authority stays distinguishable from ordinary
    /// lifecycle states; this read-only operation never attempts cleanup without caller scratch.
    pub fn metadataState(self: *const ExternalPumpStorage) MetadataStateResult {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return .moved;
        if (active_external_operation_addr != 0)
            return .transaction_busy;
        active_external_operation_addr = @intFromPtr(self);
        defer active_external_operation_addr = 0;
        switch (self.lifecycle) {
            .empty, .constructing, .normalizing, .adopting, .adoption_preparing => return .not_active,
            .tearing_down, .dead => return .dead,
            .live => {},
        }
        switch (self.semantic_state) {
            .active => {},
            .terminal => return .dead,
            else => return .not_active,
        }
        const summary = self.owner_metadata.metadataStateSummary(self) orelse
            return .invalid_owner;
        return .{ .state = summary };
    }

    fn projectOwnerEventInternal(
        self: *ExternalPumpStorage,
        projector: OwnerEventProjector,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) ProjectOwnerEventResult {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return .moved;
        if (active_external_operation_addr != 0)
            return .transaction_busy;
        switch (self.lifecycle) {
            .empty, .constructing, .normalizing, .adopting, .adoption_preparing => return .not_active,
            .tearing_down, .dead => return .dead,
            .live => {},
        }
        switch (self.semantic_state) {
            .active => {},
            .terminal => return .dead,
            else => return .not_active,
        }
        active_external_operation_addr = @intFromPtr(self);
        defer active_external_operation_addr = 0;
        if (!ownerIncarnationValid(self) or !ownerAuthorityValid(self))
            return self.quarantineProjection(cleanup_scratch, false);
        const authority = self.owner_authority.current;
        if (authority.flow == .initial_fence) return .fenced;
        if (cleanupScratchOverlapsStorage(self, cleanup_scratch) or
            !cleanup_scratch.isReady())
            return self.quarantineProjection(cleanup_scratch, false);

        const metadata_summary = self.owner_metadata.metadataStateSummary(self) orelse
            return self.quarantineProjection(cleanup_scratch, true);
        if (!ownerResizeValid(self) or !self.inbox_ledger.accountingView().valid)
            return self.quarantineProjection(cleanup_scratch, true);
        if (!self.projectionScratchDisjoint(cleanup_scratch))
            return self.quarantineProjection(cleanup_scratch, false);
        if (self.owner_event_projection_generation == std.math.maxInt(u64)) {
            switch (self.teardownUnderHeldOperationLease(cleanup_scratch)) {
                .cleaned, .cleaned_with_invariant, .already_dead, .quarantined => {},
                .moved_storage, .transaction_busy => {
                    _ = self.quarantineOwnerTeardown(cleanup_scratch, true);
                },
            }
            return .terminal_latched;
        }
        const next_generation = self.owner_event_projection_generation + 1;

        const selected: SelectedOwnerEvent = switch (self.owner_resize) {
            .current => |current| if (current.pending)
                .{
                    .key = .{ .resized = .{
                        .generation = current.event.resize_generation,
                        .cols = current.event.cols,
                        .rows = current.event.rows,
                    } },
                    .view = .{ .resized = current.event },
                }
            else
                self.selectMetadataEvent(metadata_summary) orelse return .none,
            .none => self.selectMetadataEvent(metadata_summary) orelse return .none,
        };

        var permit: OwnerEventPermit = .{};
        if (!prepareOwnerEventPermit(self, selected.key, next_generation, &permit))
            return self.quarantineProjection(cleanup_scratch, true);
        defer if (permit.lifecycle == .prepared) consumeOwnerEventPermit(&permit);
        if (!self.projectorContextDisjoint(projector, cleanup_scratch, &permit))
            return self.finishProjectionWithTrustedTeardown(cleanup_scratch, &permit);

        const ledger_authority = self.inbox_ledger.projectionAuthorityDigest();
        const screen_authority =
            self.committed_screen.projectionAuthorityDigest(self) orelse
            return self.quarantineProjection(cleanup_scratch, true);
        const take_authority =
            self.client_cleanup_take.projectionAuthorityDigest() orelse
            return self.quarantineProjection(cleanup_scratch, true);
        const operation_generation = self.operation_generation;
        const teardown_generation = self.owner_teardown_generation;
        // Exact-copy the complete outer Client before traversing any owned backing. The post
        // callback path must compare this descriptor-only snapshot first; otherwise a forged list
        // pointer could be dereferenced while trying to compute the deep digest that detects it.
        const client_outer_authority = self.owned_client;
        const client_authority = if (self.owned_client) |*client|
            client.projectionAuthorityDigest()
        else
            null;
        const evidence_authority = self.owned_evidence;
        self.owner_event_projection_generation = next_generation;
        const decision = projector.project(projector.context, selected.view);

        if (!cleanup_scratch.isReady())
            return self.quarantineProjection(cleanup_scratch, false);
        const semantic_active = switch (self.semantic_state) {
            .active => true,
            else => false,
        };
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live or
            !semantic_active or !ownerIncarnationValid(self) or
            !ownerAuthorityValid(self) or
            self.operation_generation != operation_generation or
            self.owner_teardown_generation != teardown_generation)
            return self.quarantineProjection(cleanup_scratch, true);
        const post_ledger_authority = self.inbox_ledger.projectionAuthorityDigest();
        const post_screen_authority =
            self.committed_screen.projectionAuthorityDigest(self) orelse
            return self.quarantineProjection(cleanup_scratch, true);
        const post_take_authority =
            self.client_cleanup_take.projectionAuthorityDigest() orelse
            return self.quarantineProjection(cleanup_scratch, true);
        if (!std.mem.eql(
            u8,
            &ledger_authority,
            &post_ledger_authority,
        ) or !std.mem.eql(u8, &screen_authority, &post_screen_authority) or
            !std.mem.eql(u8, &take_authority, &post_take_authority) or
            !std.meta.eql(client_outer_authority, self.owned_client) or
            !std.meta.eql(evidence_authority, self.owned_evidence))
            return self.quarantineProjection(cleanup_scratch, true);
        // The shallow equality above is the descriptor-first memory-safety gate. Only now may the
        // deep transcript traverse list elements through those exact pre-callback pointers.
        const post_client_authority = if (self.owned_client) |*client|
            client.projectionAuthorityDigest()
        else
            null;
        if (!std.meta.eql(client_authority, post_client_authority))
            return self.quarantineProjection(cleanup_scratch, true);
        const post_summary = self.owner_metadata.metadataStateSummary(self) orelse
            return self.quarantineProjection(cleanup_scratch, true);
        if (!ownerResizeValid(self) or !self.selectedEventStillMatches(selected, post_summary))
            return self.quarantineProjection(cleanup_scratch, true);
        if (!ownerEventPermitValid(self, selected.key, &permit))
            return self.finishProjectionWithTrustedTeardown(cleanup_scratch, &permit);

        consumeOwnerEventPermit(&permit);
        switch (decision) {
            .retry_preserved => return .retry_preserved,
            .applied => {
                switch (selected.key) {
                    .resized => {
                        self.owner_resize.current.pending = false;
                        self.resealOwnerResize();
                    },
                    .metadata => {
                        if (!self.metadataPendingSummaryValid() or
                            self.metadata_pending_summary.generation ==
                                std.math.maxInt(u64))
                            return self.quarantineProjection(
                                cleanup_scratch,
                                true,
                            );
                        self.owner_metadata.metadata.current.pending = false;
                        self.metadata_pending_summary.pending = false;
                        self.metadata_pending_summary.generation += 1;
                        self.metadata_pending_summary.digest =
                            metadataPendingSummaryDigest(
                                self.metadata_pending_summary,
                            );
                    },
                }
                return .applied;
            },
        }
    }

    fn selectMetadataEvent(
        self: *ExternalPumpStorage,
        summary: external_event_materialization.MetadataStateSummary,
    ) ?SelectedOwnerEvent {
        const scalar = switch (summary) {
            .unsupported, .unavailable => return null,
            .current => |current| current,
        };
        if (!scalar.pending) return null;
        const current = &self.owner_metadata.metadata.current;
        const dto = &current.logical;
        return .{
            .key = .{ .metadata = .{
                .revision = scalar.revision,
                .raw_digest = current.logical_seal.raw_digest,
                .semantic_digest = current.logical_seal.semantic_digest,
            } },
            .view = .{ .metadata = .{
                .revision = dto.revision,
                .observer_generation = dto.observer_generation,
                .title_generation = dto.title_generation,
                .cols = dto.cols,
                .rows = dto.rows,
                .semantic_state = dto.semantic_state,
                .alt_active = dto.alt_active,
                .app_cursor_keys = dto.app_cursor_keys,
                .app_keypad = dto.app_keypad,
                .kitty_flags = dto.kitty_flags,
                .alternate_scroll = dto.alternate_scroll,
                .mouse_tracking = dto.mouse_tracking,
                .mouse_tracking_mode = dto.mouse_tracking_mode,
                .bracketed_paste = dto.bracketed_paste,
                .bell_count = dto.bell_count,
                .clipboard_write_seq = dto.clipboard_write_seq,
                .clipboard_read_seq = dto.clipboard_read_seq,
                .foreground_available = dto.foreground_available,
                .foreground_pgid = dto.foreground_pgid,
                .cwd = dto.cwd(),
                .window_title = dto.windowTitle(),
                .ssh_remote_dest = dto.sshRemoteDest(),
                .clipboard_read_target = dto.clipboardReadTarget(),
                .processes = dto.foregroundProcesses(),
            } },
        };
    }

    fn projectorContextDisjoint(
        self: *const ExternalPumpStorage,
        projector: OwnerEventProjector,
        cleanup_scratch: *const ExternalPumpCleanupScratch,
        permit: *const OwnerEventPermit,
    ) bool {
        const context_addr = @intFromPtr(projector.context);
        if (context_addr == 0 or projector.context_len == 0)
            return false;
        _ = std.math.add(usize, context_addr, projector.context_len) catch return false;
        if (rangesOverlap(context_addr, projector.context_len, @intFromPtr(self), @sizeOf(ExternalPumpStorage)) or
            rangesOverlap(context_addr, projector.context_len, @intFromPtr(cleanup_scratch), @sizeOf(ExternalPumpCleanupScratch)) or
            rangesOverlap(context_addr, projector.context_len, @intFromPtr(permit), @sizeOf(OwnerEventPermit)))
            return false;
        if (self.owner_metadata.metadata == .current) {
            const current = &self.owner_metadata.metadata.current;
            if (current.logical.backing) |backing|
                if (rangesOverlap(
                    context_addr,
                    projector.context_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
            if (current.cleanup.backing) |backing|
                if (rangesOverlap(
                    context_addr,
                    projector.context_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
        }
        return true;
    }

    fn projectionScratchDisjoint(
        self: *const ExternalPumpStorage,
        cleanup_scratch: *const ExternalPumpCleanupScratch,
    ) bool {
        const scratch_addr = @intFromPtr(cleanup_scratch);
        const scratch_len = @sizeOf(ExternalPumpCleanupScratch);
        if (self.inbox_ledger.overlapsOwnedRange(scratch_addr, scratch_len))
            return false;
        if (self.owner_metadata.metadata == .current) {
            const current = &self.owner_metadata.metadata.current;
            if (current.logical.backing) |backing|
                if (rangesOverlap(
                    scratch_addr,
                    scratch_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
            if (current.cleanup.backing) |backing|
                if (rangesOverlap(
                    scratch_addr,
                    scratch_len,
                    @intFromPtr(backing.ptr),
                    backing.len,
                )) return false;
        }
        if (self.owned_client) |*owned| {
            var source_ranges: client_mod.ExternalSourceOwnerRangeScratch = .{};
            owned.preflightExternalAdoptionDestinationWithScratch(
                @constCast(cleanup_scratch),
                scratch_len,
                &source_ranges,
            ) catch return false;
        }
        return true;
    }

    fn selectedEventStillMatches(
        self: *const ExternalPumpStorage,
        selected: SelectedOwnerEvent,
        metadata_summary: external_event_materialization.MetadataStateSummary,
    ) bool {
        return switch (selected.key) {
            .resized => |key| self.owner_resize == .current and
                self.owner_resize.current.pending and
                self.owner_resize.current.event.resize_generation == key.generation and
                self.owner_resize.current.event.cols == key.cols and
                self.owner_resize.current.event.rows == key.rows,
            .metadata => |key| metadata_summary == .current and
                metadata_summary.current.pending and
                metadata_summary.current.revision == key.revision and
                std.mem.eql(
                    u8,
                    &self.owner_metadata.metadata.current.logical_seal.raw_digest,
                    &key.raw_digest,
                ) and std.mem.eql(
                u8,
                &self.owner_metadata.metadata.current.logical_seal.semantic_digest,
                &key.semantic_digest,
            ),
        };
    }

    fn resealOwnerResize(self: *ExternalPumpStorage) void {
        const current = &self.owner_resize.current;
        current.seal.pending = current.pending;
        current.seal.digest = ownerResizeDigest(current.seal);
    }

    fn finishProjectionWithTrustedTeardown(
        self: *ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
        permit: *OwnerEventPermit,
    ) ProjectOwnerEventResult {
        consumeOwnerEventPermit(permit);
        switch (self.teardownUnderHeldOperationLease(cleanup_scratch)) {
            .cleaned, .cleaned_with_invariant, .already_dead, .quarantined => {},
            .moved_storage, .transaction_busy => {
                _ = self.quarantineOwnerTeardown(cleanup_scratch, true);
            },
        }
        return .terminal_latched;
    }

    fn quarantineProjection(
        self: *ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
        scratch_trusted: bool,
    ) ProjectOwnerEventResult {
        _ = self.quarantineOwnerTeardown(cleanup_scratch, scratch_trusted);
        return .terminal_latched;
    }

    /// The sole product entry point for partial screen consumption. The process-thread lease
    /// prevents this no-callback two-owner commit from crossing adoption or teardown prepare.
    pub fn consumeScreenRetained(
        self: *ExternalPumpStorage,
        ordinal: usize,
    ) ScreenConsumeError!void {
        if (active_external_operation_addr != 0) return error.TransactionBusy;
        active_external_operation_addr = @intFromPtr(self);
        defer active_external_operation_addr = 0;
        try self.requireActive();
        const screen = &self.committed_screen;
        const ledger = &self.inbox_ledger;
        if (!screen.isCommitted(self) or
            screen.ledger_addr != @intFromPtr(ledger) or
            ordinal >= screen.tokens_len or screen.released.isSet(ordinal) or
            screen.retained_count == 0 or
            !self.screenPendingSummaryValid() or
            self.screen_pending_summary.generation == std.math.maxInt(u64))
            return error.InvalidRetirement;
        const transfer = screen.primary.transfer;
        const phase: external_inbox_ledger.PayloadPhase =
            switch (transfer.copies[ordinal].semantic) {
                .frame => .frame,
                .partial => .partial,
                .completed => .completed,
            };
        var prepared: external_inbox_ledger.PreparedScreenRetirement = .{};
        try ledger.prepareScreenRetirement(
            transfer.tokens[ordinal],
            phase,
            &prepared,
        );
        ledger.commitScreenRetirementUnchecked(&prepared);
        screen.released.set(ordinal);
        screen.retained_count -= 1;
        self.screen_pending_summary.retained_count = screen.retained_count;
        self.screen_pending_summary.generation += 1;
        self.screen_pending_summary.digest =
            screenPendingSummaryDigest(self.screen_pending_summary);
    }

    pub fn prepareAdoption(
        self: *ExternalPumpStorage,
        now_ns: i128,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) AdoptionPrepareStatus {
        if (cross_owner_quarantine_latched.load(.acquire))
            return .terminal_latched;
        if (self.saved_self_addr != @intFromPtr(self))
            return .terminal_latched;
        if (active_external_operation_addr != 0)
            return .{ .retryable_preserved = .transaction_busy };
        if (cleanupScratchOverlapsStorage(self, cleanup_scratch))
            return self.quarantineImmediateTerminal();
        if (!cleanup_scratch.isReady())
            return self.quarantineImmediateTerminal();
        if (self.lifecycle != .adopting or self.semantic_state != .adopting or
            self.prepared_adoption.lifecycle != .empty)
            return self.quarantineImmediateTerminal();
        self.lifecycle = .adoption_preparing;
        active_external_operation_addr = @intFromPtr(self);
        defer {
            active_external_operation_addr = 0;
            if (self.lifecycle == .adoption_preparing)
                self.lifecycle = .adopting;
        }
        const client = if (self.owned_client) |*owned| owned else return self.finishImmediateTerminal(
            .invariant_failure,
            cleanup_scratch,
        );
        const owned_evidence = if (self.owned_evidence) |*owned| owned else return self.finishImmediateTerminal(
            .invariant_failure,
            cleanup_scratch,
        );
        if (!owned_evidence.validate(client) or
            !std.meta.eql(owned_evidence.attachment, self.evidence_snapshot))
            return self.quarantineImmediateTerminal();
        const seed_seal = owned_evidence.seed_seal orelse
            return self.quarantineImmediateTerminal();
        const cleanup_seed_seal = owned_evidence.cleanup_seed_seal orelse
            return self.quarantineImmediateTerminal();
        if ((seed_seal.backing_len != 0 and rangesOverlap(
            @intFromPtr(cleanup_scratch),
            @sizeOf(ExternalPumpCleanupScratch),
            seed_seal.backing_addr,
            seed_seal.backing_len,
        )) or (cleanup_seed_seal.backing_len != 0 and rangesOverlap(
            @intFromPtr(cleanup_scratch),
            @sizeOf(ExternalPumpCleanupScratch),
            cleanup_seed_seal.backing_addr,
            cleanup_seed_seal.backing_len,
        )))
            return self.quarantineImmediateTerminal();
        if (self.evidence_snapshot.runtime_id == 0 or
            self.evidence_snapshot.stream_id == 0)
            return self.finishImmediateTerminal(
                .protocol_error,
                cleanup_scratch,
            );
        const ledger_view = self.inbox_ledger.accountingView();
        if (!ledger_view.valid or !ledger_view.pristine_zero)
            return self.quarantineImmediateTerminal();
        const authority = prepareAuthority(client, self.evidence_snapshot) catch |err|
            return self.finishImmediateTerminal(
                terminalReasonForAuthorityError(err),
                cleanup_scratch,
            );
        const input = adoptionFoldInput(owned_evidence, authority) orelse
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
        const fold = client.foldExternalAdoptionSource(
            input,
            &scratch,
        ) catch return self.finishImmediateTerminal(
            .invariant_failure,
            cleanup_scratch,
        );
        const decision = external_source_decision.decide(
            client,
            input,
            fold,
            &scratch,
        );
        var aggregate_source_ranges: client_mod.ExternalSourceOwnerRangeScratch = .{};
        client.preflightExternalAdoptionDestinationWithScratch(
            cleanup_scratch,
            @sizeOf(ExternalPumpCleanupScratch),
            &aggregate_source_ranges,
        ) catch |err| return switch (err) {
            error.InvalidAlias => self.quarantineImmediateTerminal(),
            else => self.finishImmediateTerminal(
                terminalReasonForDecision(decision),
                cleanup_scratch,
            ),
        };
        aggregate_source_ranges = .{};
        client.preflightExternalAdoptionDestinationWithScratch(
            &self.prepared_adoption,
            @sizeOf(PreparedExternalAdoption),
            &aggregate_source_ranges,
        ) catch |err| return switch (err) {
            error.InvalidAlias => self.quarantineImmediateTerminal(),
            else => self.finishImmediateTerminal(
                terminalReasonForDecision(decision),
                cleanup_scratch,
            ),
        };
        switch (decision.verdict) {
            .adopted => {},
            else => return self.finishNonAdopted(
                now_ns,
                input,
                decision,
                cleanup_scratch,
            ),
        }
        if (self.operation_generation == std.math.maxInt(u64))
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        self.operation_generation += 1;
        // Only adopted owns this destination. Capture the source decision before the allocating
        // proof: an OOM callback may execute arbitrary code, and retry is permitted only if the
        // exact decision/evidence still match.
        client.preflightExternalAdoptionDestination(
            &self.prepared_adoption,
            @sizeOf(PreparedExternalAdoption),
        ) catch |err| return switch (err) {
            error.OutOfMemory => blk: {
                var retry_scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
                if (owned_evidence.validate(client) and
                    std.meta.eql(
                        owned_evidence.attachment,
                        self.evidence_snapshot,
                    ) and external_source_decision.decisionMatches(
                    client,
                    input,
                    decision,
                    &retry_scratch,
                ))
                    break :blk .{
                        .retryable_preserved = .out_of_memory,
                    };
                break :blk self.quarantineImmediateTerminal();
            },
            else => self.quarantineImmediateTerminal(),
        };
        self.prepared_adoption = .{
            .saved_self_addr = @intFromPtr(&self.prepared_adoption),
            .storage_addr = @intFromPtr(self),
            .client_addr = @intFromPtr(client),
            .ledger_addr = @intFromPtr(&self.inbox_ledger),
            .evidence = self.evidence_snapshot,
            .source_decision = decision,
            .branch = .adopted,
        };
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
                return self.finishImmediateTerminal(
                    switch (reason) {
                        .resource_exhausted => .resource_exhausted,
                        .inconsistent_source => .protocol_error,
                        .internal_invariant => .invariant_failure,
                    },
                    cleanup_scratch,
                );
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
            return switch (err) {
                error.OutOfMemory => .{
                    .retryable_preserved = .out_of_memory,
                },
                else => self.finishImmediateTerminal(
                    terminalReasonForPrepareError(err),
                    cleanup_scratch,
                ),
            };
        };
        const aggregate = aggregateAdoptionFootprint(
            .{
                .resident = self.prepared_adoption.backlog.adoption_metadata_resident_bytes,
                .prepare_peak = self.prepared_adoption.backlog.adoption_metadata_prepare_peak_bytes,
            },
            metadata_footprint,
        ) catch {
            self.resetPreparedAdoption();
            return self.finishImmediateTerminal(
                .resource_exhausted,
                cleanup_scratch,
            );
        };
        client.sealExternalAdoption(
            &self.prepared_adoption.backlog.client_disarm,
        ) catch {
            self.resetPreparedAdoption();
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        };
        self.prepared_adoption.aggregate_resident_bytes = aggregate.resident;
        self.prepared_adoption.aggregate_prepare_peak_bytes =
            aggregate.prepare_peak;
        self.prepared_adoption.lifecycle = .prepared;
        self.prepareOwnerScalarTakeAt(
            &self.prepared_adoption.scalar_take,
            .adoption_preparing,
            true,
        ) catch {
            self.resetPreparedAdoption();
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        };
        self.prepared_adoption.backlog.prepareCommittedTake(
            &self.prepared_adoption.screen_take,
            &self.committed_screen,
            client,
            &self.inbox_ledger,
            self,
        ) catch {
            self.resetPreparedAdoption();
            return .terminal_latched;
        };
        external_event_materialization.prepareOwnerMetadataTake(
            &self.prepared_adoption.metadata_take,
            &self.prepared_adoption.metadata,
            &owned_evidence.seed,
            &owned_evidence.cleanup_seed,
            &self.owner_metadata,
            @intFromPtr(self),
        ) catch {
            self.resetPreparedAdoption();
            return .terminal_latched;
        };
        client.prepareExternalAdoptionTake(
            &self.prepared_adoption.backlog.client_disarm,
            &self.prepared_adoption.backlog.inventory,
            &self.prepared_adoption.backlog.cleanup_inventory,
            &self.client_cleanup_take,
        ) catch |err| {
            const source_unchanged =
                self.validatePreparedSources(.adoption_preparing);
            self.resetPreparedAdoption();
            return switch (err) {
                error.OutOfMemory => if (source_unchanged)
                    .{ .retryable_preserved = .out_of_memory }
                else
                    self.finishImmediateTerminal(
                        .invariant_failure,
                        cleanup_scratch,
                    ),
                error.InvalidPlan, error.StaleClient => self.finishImmediateTerminal(
                    .invariant_failure,
                    cleanup_scratch,
                ),
            };
        };
        self.prepareFinalSeal() catch {
            self.resetPreparedAdoption();
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        };
        if (!self.prepared_adoption.validateWhilePreparing(self)) {
            self.resetPreparedAdoption();
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        }
        self.lifecycle = .adopting;
        return .prepared_adopted;
    }

    fn finishNonAdopted(
        self: *ExternalPumpStorage,
        now_ns: i128,
        input: client_mod.ExternalAdoptionFoldInput,
        decision: external_source_decision.PreparedSourceDecision,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) AdoptionPrepareStatus {
        const client = if (self.owned_client) |*owned| owned else return self.finishImmediateTerminal(.invariant_failure, cleanup_scratch);
        cleanup_scratch.range_scratch.source = .{};
        client.prepareExternalRecoveryDiscard(
            self.evidence_snapshot.stream_id,
            &cleanup_scratch.client,
            &cleanup_scratch.range_scratch.source,
            &cleanup_scratch.recovery_discard,
        ) catch {
            return self.finishImmediateTerminal(
                terminalReasonForDecision(decision),
                cleanup_scratch,
            );
        };
        cleanup_scratch.range_scratch.source = .{};
        if (!external_source_decision.decisionMatches(
            client,
            input,
            decision,
            &cleanup_scratch.range_scratch.source,
        ) or !client.validateExternalRecoveryDiscard(
            &cleanup_scratch.recovery_discard,
            &cleanup_scratch.client,
        )) {
            cleanup_scratch.resetReady();
            return self.quarantineImmediateTerminal();
        }

        return switch (decision.verdict) {
            .host_recovery => self.commitImmediateRecovery(
                now_ns,
                input.authority,
                decision,
                .host,
                cleanup_scratch,
            ),
            .client_recovery => self.commitImmediateRecovery(
                now_ns,
                input.authority,
                decision,
                .client,
                cleanup_scratch,
            ),
            .terminal, .ended, .revoked => self.finishImmediateTerminal(
                terminalReasonForDecision(decision),
                cleanup_scratch,
            ),
            .adopted => self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            ),
        };
    }

    fn commitImmediateRecovery(
        self: *ExternalPumpStorage,
        now_ns: i128,
        authority: client_mod.FoldAuthority,
        decision: external_source_decision.PreparedSourceDecision,
        origin: client_pump.RecoveryOrigin,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) AdoptionPrepareStatus {
        const deadline_ns = std.math.add(
            i128,
            now_ns,
            30 * @as(i128, std.time.ns_per_s),
        ) catch {
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        };
        const request_state = decision.request_state orelse {
            return self.finishImmediateTerminal(
                .request_id_exhausted,
                cleanup_scratch,
            );
        };
        const client = if (self.owned_client) |*owned| owned else {
            return self.finishImmediateTerminal(
                .invariant_failure,
                cleanup_scratch,
            );
        };
        const metadata_support = client.metadata_support;
        const storage_addr = @intFromPtr(self);
        const evidence_snapshot = self.evidence_snapshot;
        const ledger_snapshot = self.inbox_ledger;
        var evidence: PreparedAdoptionEvidence = .{};
        const owned_evidence = if (self.owned_evidence) |*owned| owned else return self.finishImmediateTerminal(.invariant_failure, cleanup_scratch);
        const owner_incarnation = owned_evidence.attach_instance_id;
        owned_evidence.moveInto(&evidence, client);
        self.owned_evidence = null;
        var frozen_client = client.*;
        self.owned_client = null;
        var frozen_transfer = self.client_transfer;
        self.client_transfer = .{};
        cleanup_scratch.lifecycle = .frozen;
        self.semantic_state = .{ .active = switch (origin) {
            .host => .{ .host_recovery = .{ .ack_unadmitted = .{
                .epoch = 1,
                .deadline_ns = deadline_ns,
            } } },
            .client => .{ .client_recovery = .{ .control_wait = .{
                .epoch = 1,
                .deadline_ns = deadline_ns,
            } } },
        } };
        self.owner_resize = .none;
        self.owner_authority = .{ .current = .{
            .role = switch (authority.role) {
                .observer => .observer,
                .controller => .controller,
            },
            .generation = switch (authority.generation) {
                .untracked => .untracked,
                .tracked => |generation| .{ .tracked = generation },
            },
            .flow = .initial_fence,
        } };
        self.owner_request_ids = request_state;
        self.prepared_adoption = .{ .lifecycle = .committed_tombstone };

        consumeFrozenClientQueues(&frozen_client, cleanup_scratch);
        evidence.deinit();
        frozen_transfer.deinit();
        // Allocator callbacks may mutate the published storage directly. Restore every scalar and
        // owner header from callback-hidden locals before making the recovered transport live.
        self.saved_self_addr = storage_addr;
        self.evidence_snapshot = evidence_snapshot;
        self.inbox_ledger = ledger_snapshot;
        self.owned_client = frozen_client;
        self.owned_evidence = null;
        self.client_transfer = .{};
        self.prepared_adoption = .{ .lifecycle = .committed_tombstone };
        self.client_cleanup_take = .{};
        self.committed_screen = .{};
        self.owner_metadata = .{};
        if (!external_event_materialization.commitRecoveryBaseline(
            &self.owner_metadata,
            storage_addr,
            @intFromPtr(&self.evidence_snapshot),
            metadata_support,
        ))
            return self.quarantineImmediateTerminal();
        self.semantic_state = .{ .active = switch (origin) {
            .host => .{ .host_recovery = .{ .ack_unadmitted = .{
                .epoch = 1,
                .deadline_ns = deadline_ns,
            } } },
            .client => .{ .client_recovery = .{ .control_wait = .{
                .epoch = 1,
                .deadline_ns = deadline_ns,
            } } },
        } };
        self.owner_resize = .none;
        self.owner_authority = .{ .current = .{
            .role = switch (authority.role) {
                .observer => .observer,
                .controller => .controller,
            },
            .generation = switch (authority.generation) {
                .untracked => .untracked,
                .tracked => |generation| .{ .tracked = generation },
            },
            .flow = .initial_fence,
        } };
        self.owner_request_ids = request_state;
        bindOwnerIncarnation(self, owner_incarnation);
        bindOwnerAuthority(self);
        self.owner_event_projection_generation = 0;
        self.lifecycle = .live;
        cleanup_scratch.resetReady();
        return .recovery_committed;
    }

    fn finishImmediateTerminal(
        self: *ExternalPumpStorage,
        reason: client_pump.TerminalReason,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) AdoptionPrepareStatus {
        if (cleanup_scratch.recovery_discard.isEmpty()) {
            const client = if (self.owned_client) |*owned| owned else return self.quarantineImmediateTerminal();
            cleanup_scratch.range_scratch.source = .{};
            client.prepareExternalRecoveryDiscard(
                self.evidence_snapshot.stream_id,
                &cleanup_scratch.client,
                &cleanup_scratch.range_scratch.source,
                &cleanup_scratch.recovery_discard,
            ) catch return self.quarantineImmediateTerminal();
        }
        const terminal_client = if (self.owned_client) |*client| client else return self.quarantineImmediateTerminalReason(reason);
        if (cleanup_scratch.recovery_discard.lifecycle != .prepared or
            !terminal_client.validateExternalRecoveryDiscard(
                &cleanup_scratch.recovery_discard,
                &cleanup_scratch.client,
            ))
            return self.quarantineImmediateTerminalReason(reason);
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        const storage_addr = @intFromPtr(self);
        const evidence_snapshot = self.evidence_snapshot;
        const ledger_snapshot = self.inbox_ledger;
        var evidence: PreparedAdoptionEvidence = .{};
        const owned_evidence = if (self.owned_evidence) |*owned| owned else return self.quarantineImmediateTerminalReason(reason);
        owned_evidence.moveInto(&evidence, terminal_client);
        self.owned_evidence = null;
        var frozen_client = terminal_client.*;
        self.owned_client = null;
        var frozen_transfer = self.client_transfer;
        self.client_transfer = .{};
        self.prepared_adoption = .{};
        self.client_cleanup_take = .{ .lifecycle = .aborted };
        cleanup_scratch.lifecycle = .frozen;
        consumeFrozenClientQueues(&frozen_client, cleanup_scratch);
        frozen_client.deinit();
        evidence.deinit();
        frozen_transfer.deinit();
        // Nothing below invokes an allocator callback. Overwrite any direct callback mutation
        // before publishing the terminal lifecycle.
        self.saved_self_addr = storage_addr;
        self.evidence_snapshot = evidence_snapshot;
        self.inbox_ledger = ledger_snapshot;
        self.owned_client = null;
        self.owned_evidence = null;
        self.client_transfer = .{};
        self.prepared_adoption = .{};
        self.client_cleanup_take = .{ .lifecycle = .aborted };
        self.committed_screen = .{};
        self.owner_metadata = .{};
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_request_ids = null;
        self.owner_incarnation = 0;
        self.owner_incarnation_seal = .{};
        self.owner_event_projection_generation = 0;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        _ = self.inbox_ledger.finish() catch {};
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        cleanup_scratch.resetReady();
        return .terminal_latched;
    }

    fn quarantineImmediateTerminal(
        self: *ExternalPumpStorage,
    ) AdoptionPrepareStatus {
        return self.quarantineImmediateTerminalReason(.invariant_failure);
    }

    fn quarantineImmediateTerminalReason(
        self: *ExternalPumpStorage,
        reason: client_pump.TerminalReason,
    ) AdoptionPrepareStatus {
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        _ = cross_owner_quarantine_latched.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        );
        _ = cross_owner_quarantine_events.fetchAdd(1, .acq_rel);
        self.prepared_adoption = .{ .lifecycle = .aborted_tombstone };
        self.client_cleanup_take = .{ .lifecycle = .aborted };
        self.owned_client = null;
        self.owned_evidence = null;
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_request_ids = null;
        self.owner_incarnation = 0;
        self.owner_incarnation_seal = .{};
        self.owner_event_projection_generation = 0;
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        return .terminal_latched;
    }

    pub fn prepareOwnerScalarTake(
        self: *ExternalPumpStorage,
        out: *PreparedOwnerScalarTake,
    ) error{InvalidOwnerTake}!void {
        return self.prepareOwnerScalarTakeAt(out, .adopting, false);
    }

    fn prepareOwnerScalarTakeAt(
        self: *ExternalPumpStorage,
        out: *PreparedOwnerScalarTake,
        expected_lifecycle: StorageLifecycle,
        embedded: bool,
    ) error{InvalidOwnerTake}!void {
        const pre_take_valid = self.prepared_adoption.validateForStorageLifecycle(
            self,
            expected_lifecycle,
            .before_takes,
        );
        if (!std.meta.eql(out.*, PreparedOwnerScalarTake{}) or
            (!embedded and rangesOverlap(
                @intFromPtr(out),
                @sizeOf(PreparedOwnerScalarTake),
                @intFromPtr(self),
                @sizeOf(ExternalPumpStorage),
            )) or
            (embedded and
                @intFromPtr(out) !=
                    @intFromPtr(&self.prepared_adoption.scalar_take)) or
            self.owner_authority != .empty or self.owner_request_ids != null or
            !pre_take_valid)
            return error.InvalidOwnerTake;
        const decision = self.prepared_adoption.source_decision orelse
            return error.InvalidOwnerTake;
        const live = switch (decision.verdict) {
            .adopted => |adopted| adopted,
            else => return error.InvalidOwnerTake,
        };
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .prepared_addr = @intFromPtr(&self.prepared_adoption),
            .storage_addr = @intFromPtr(self),
            .resize_addr = @intFromPtr(&self.owner_resize),
            .authority_addr = @intFromPtr(&self.owner_authority),
            .request_addr = @intFromPtr(&self.owner_request_ids),
            .resize = if (live.resize) |candidate| candidate.event else null,
            .authority = .{ .current = .{
                .role = switch (live.authority.role) {
                    .observer => .observer,
                    .controller => .controller,
                },
                .generation = switch (live.authority.generation) {
                    .untracked => .untracked,
                    .tracked => |generation| .{ .tracked = generation },
                },
                .flow = .initial_fence,
            } },
            .request_ids = decision.request_state orelse return error.InvalidOwnerTake,
            .lifecycle = .prepared,
        };
        if (!out.validate(self)) {
            out.* = .{ .lifecycle = .aborted_tombstone };
            return error.InvalidOwnerTake;
        }
    }

    fn validatePreparedSources(
        self: *const ExternalPumpStorage,
        expected_lifecycle: StorageLifecycle,
    ) bool {
        const plan = &self.prepared_adoption;
        if (self.saved_self_addr != @intFromPtr(self) or
            self.lifecycle != expected_lifecycle or
            self.semantic_state != .adopting or
            plan.lifecycle != .prepared or
            plan.saved_self_addr != @intFromPtr(plan) or
            plan.storage_addr != @intFromPtr(self) or
            plan.ledger_addr != @intFromPtr(&self.inbox_ledger) or
            plan.branch != .adopted)
            return false;
        const client = if (self.owned_client) |*owned| owned else return false;
        const evidence = if (self.owned_evidence) |*owned| owned else return false;
        if (plan.client_addr != @intFromPtr(client) or
            !evidence.validate(client) or
            !std.meta.eql(plan.evidence, self.evidence_snapshot))
            return false;
        const authority = prepareAuthority(client, self.evidence_snapshot) catch
            return false;
        const input = adoptionFoldInput(evidence, authority) orelse return false;
        const decision = plan.source_decision orelse return false;
        var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
        if (!external_source_decision.decisionMatches(
            client,
            input,
            decision,
            &scratch,
        ) or decision.verdict != .adopted or
            !plan.backlog.validate(client, &self.inbox_ledger))
            return false;
        const metadata_footprint = plan.metadata.footprint(
            client,
            input,
            decision,
            &scratch,
        ) orelse return false;
        const aggregate = aggregateAdoptionFootprint(
            .{
                .resident = plan.backlog.adoption_metadata_resident_bytes,
                .prepare_peak = plan.backlog.adoption_metadata_prepare_peak_bytes,
            },
            metadata_footprint,
        ) catch return false;
        return plan.aggregate_resident_bytes == aggregate.resident and
            plan.aggregate_prepare_peak_bytes == aggregate.prepare_peak;
    }

    fn prepareFinalSeal(
        self: *ExternalPumpStorage,
    ) error{InvalidCommitPermit}!void {
        const final_seal = &self.prepared_adoption.final_seal;
        if (!std.meta.eql(final_seal.*, PreparedAdoptionFinalSeal{}))
            return error.InvalidCommitPermit;
        final_seal.* = self.expectedFinalSeal();
        if (!self.validateFinalSeal()) {
            final_seal.abort();
            return error.InvalidCommitPermit;
        }
    }

    fn expectedFinalSeal(
        self: *const ExternalPumpStorage,
    ) PreparedAdoptionFinalSeal {
        const plan = &self.prepared_adoption;
        var result = PreparedAdoptionFinalSeal{
            .saved_self_addr = @intFromPtr(&plan.final_seal),
            .storage_addr = @intFromPtr(self),
            .plan_addr = @intFromPtr(plan),
            .client_addr = if (self.owned_client) |*client|
                @intFromPtr(client)
            else
                0,
            .ledger_addr = @intFromPtr(&self.inbox_ledger),
            .evidence_addr = if (self.owned_evidence) |*evidence|
                @intFromPtr(evidence)
            else
                0,
            .client_cleanup_take_addr = @intFromPtr(&self.client_cleanup_take),
            .screen_take_addr = @intFromPtr(&plan.screen_take),
            .metadata_take_addr = @intFromPtr(&plan.metadata_take),
            .scalar_take_addr = @intFromPtr(&plan.scalar_take),
            .committed_screen_addr = @intFromPtr(&self.committed_screen),
            .screen_pending_summary_addr = @intFromPtr(&self.screen_pending_summary),
            .owner_metadata_addr = @intFromPtr(&self.owner_metadata),
            .metadata_pending_summary_addr = @intFromPtr(&self.metadata_pending_summary),
            .owner_resize_addr = @intFromPtr(&self.owner_resize),
            .owner_authority_addr = @intFromPtr(&self.owner_authority),
            .owner_request_ids_addr = @intFromPtr(&self.owner_request_ids),
            .operation_generation = self.operation_generation,
            .lifecycle = .prepared,
        };
        result.digest = adoptionFinalSealDigest(self, &result);
        return result;
    }

    fn validateFinalSeal(self: *const ExternalPumpStorage) bool {
        const plan = &self.prepared_adoption;
        const final_seal = &plan.final_seal;
        if (!self.validatePreparedSources(self.lifecycle)) {
            return false;
        }
        const expected_final_seal = self.expectedFinalSeal();
        if (!std.meta.eql(final_seal.*, expected_final_seal)) {
            return false;
        }
        if (self.operation_generation == 0 or
            !self.committed_screen.isEmpty() or
            !std.meta.eql(self.screen_pending_summary, ScreenPendingSummarySeal{}) or
            !self.owner_metadata.isEmpty() or
            !std.meta.eql(self.metadata_pending_summary, MetadataPendingSummarySeal{}) or
            self.owner_resize != .none or
            self.owner_authority != .empty or
            !std.meta.eql(self.owner_authority_seal, OwnerAuthoritySeal{}) or
            self.owner_request_ids != null or
            self.owner_incarnation != 0 or
            !std.meta.eql(self.owner_incarnation_seal, OwnerIncarnationSeal{}) or
            self.owner_event_projection_generation != 0)
            return false;
        const client = if (self.owned_client) |*owned| owned else return false;
        const evidence = if (self.owned_evidence) |*owned| owned else return false;
        if (!commitHeadersPairwiseDisjoint(self)) return false;
        const ranges = commitHeaderRanges(self, client, evidence);
        var source_ranges: client_mod.ExternalSourceOwnerRangeScratch = .{};
        for (ranges) |range| {
            if (range.addr != @intFromPtr(client))
                client.preflightExternalAdoptionDestinationWithScratch(
                    @ptrFromInt(range.addr),
                    range.len,
                    &source_ranges,
                ) catch return false;
            if (plan.backlog.overlapsOwnedBacking(range.addr, range.len) or
                external_event_materialization.preparedMetadataOverlapsOwnedBacking(
                    &plan.metadata,
                    &evidence.seed,
                    &evidence.cleanup_seed,
                    range.addr,
                    range.len,
                ))
                return false;
        }
        if (plan.metadata_take.primary_seal) |seal| {
            if (seal.backing_len != 0 and
                plan.backlog.overlapsOwnedBacking(
                    seal.backing_addr,
                    seal.backing_len,
                ))
                return false;
            if (seal.backing_len != 0)
                client.preflightExternalAdoptionDestinationWithScratch(
                    @ptrFromInt(seal.backing_addr),
                    seal.backing_len,
                    &source_ranges,
                ) catch return false;
        }
        if (!plan.screen_take.validate(
            &plan.backlog,
            &self.committed_screen,
            client,
            &self.inbox_ledger,
            self,
        ) or !plan.metadata_take.validate(
            &plan.metadata,
            &evidence.seed,
            &evidence.cleanup_seed,
            &self.owner_metadata,
            @intFromPtr(self),
        ) or !plan.scalar_take.validate(self) or
            !self.client_cleanup_take.validate(
                client,
                &plan.backlog.client_disarm,
                &plan.backlog.inventory,
                &plan.backlog.cleanup_inventory,
            ))
            return false;
        if (!adoptionOwnerBackingsPairwiseDisjoint(
            plan,
            client,
            evidence,
            &source_ranges,
        ))
            return false;
        return commitHeadersPairwiseDisjoint(self);
    }

    fn mintAdoptedCommitPermit(
        self: *const ExternalPumpStorage,
        out: *AdoptedCommitPermit,
    ) bool {
        if (!std.meta.eql(out.*, AdoptedCommitPermit{}) or
            rangesOverlap(
                @intFromPtr(out),
                @sizeOf(AdoptedCommitPermit),
                @intFromPtr(self),
                @sizeOf(ExternalPumpStorage),
            ) or !self.validateFinalSeal())
            return false;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .storage_addr = @intFromPtr(self),
            .operation_generation = self.operation_generation,
            .final_seal_digest = self.prepared_adoption.final_seal.digest,
        };
        return true;
    }

    fn commitOwnerScalarTakeUnchecked(
        self: *ExternalPumpStorage,
        take: *PreparedOwnerScalarTake,
    ) void {
        if (take.resize) |event|
            bindOwnerResize(self, event)
        else
            self.owner_resize = .none;
        self.owner_authority = take.authority;
        self.owner_request_ids = take.request_ids;
        take.* = .{ .lifecycle = .committed_tombstone };
    }

    pub fn commitAdoption(
        self: *ExternalPumpStorage,
    ) CommitAdoptionResult {
        var recorder: NoopCommitRecorder = .{};
        return self.commitAdoptionWithRecorder(NoopCommitRecorder, &recorder);
    }

    fn commitAdoptionWithRecorder(
        self: *ExternalPumpStorage,
        comptime Recorder: type,
        recorder: *Recorder,
    ) CommitAdoptionResult {
        if (active_external_operation_addr != 0)
            return .transaction_busy;
        if (self.saved_self_addr != @intFromPtr(self) or
            self.lifecycle == .empty or self.lifecycle == .dead or
            self.lifecycle == .live)
            return .dead;
        if (self.lifecycle != .adopting or self.semantic_state != .adopting)
            return self.latchCommitTerminal();

        active_external_operation_addr = @intFromPtr(self);
        defer active_external_operation_addr = 0;
        if (cross_owner_quarantine_latched.load(.acquire))
            return self.latchCommitTerminal();
        const client = if (self.owned_client) |*owned| owned else return self.latchCommitTerminal();
        const evidence = if (self.owned_evidence) |*owned| owned else return self.latchCommitTerminal();
        const plan = &self.prepared_adoption;
        // Failure injection is test-only and runs before the final validation/permit mint. Once
        // the permit exists, no generic recorder receives a mutable sealed owner graph.
        recorder.beforePermit(&plan.backlog, &self.inbox_ledger);
        var source_ranges: client_mod.ExternalSourceOwnerRangeScratch = .{};
        const owner_backings_disjoint = self.validatedOwnerBackingDisjointness(
            client,
            evidence,
            &source_ranges,
        ) orelse return self.latchCommitTerminal();
        if (!owner_backings_disjoint)
            return self.latchCrossOwnerAliasTerminal();
        var permit: AdoptedCommitPermit = .{};
        if (!self.mintAdoptedCommitPermit(&permit))
            return self.latchCommitTerminal();
        // This is the final fallible precommit. The thread-wide lease stays published through any
        // terminal cleanup. Seed-plan retirement is deferred so the ledger-to-live suffix itself
        // contains no allocator callback.
        var seed_retirement: external_inbox_ledger.PreparedSeedRetirement = .{};
        plan.backlog.commitScreenSeeds(
            client,
            &self.inbox_ledger,
            &seed_retirement,
        ) catch return self.latchCommitTerminal();
        recorder.record(.ledger_seed);

        self.commitAdoptionUnchecked(
            Recorder,
            recorder,
            &permit,
            client,
            evidence,
            plan,
        );
        seed_retirement.retire();
        return .adopted;
    }

    fn validatedOwnerBackingDisjointness(
        self: *const ExternalPumpStorage,
        client: *const client_mod.Client,
        evidence: *const PreparedAdoptionEvidence,
        scratch: *client_mod.ExternalSourceOwnerRangeScratch,
    ) ?bool {
        const plan = &self.prepared_adoption;
        // Every outer slice/header authority is validated before the global proof enumerates a
        // nested screen or metadata element. `null` means another leaf is invalid; the ordinary
        // final-seal rejection path then selects its independently sealed cleanup mirror.
        if (!plan.screen_take.validateOuterTransferDescriptors(&plan.backlog))
            return null;
        const owner_backings_disjoint = adoptionOwnerBackingsPairwiseDisjoint(
            plan,
            client,
            evidence,
            scratch,
        );
        if (!owner_backings_disjoint) return false;
        if (!plan.screen_take.validate(
            &plan.backlog,
            &self.committed_screen,
            client,
            &self.inbox_ledger,
            self,
        ) or !plan.metadata_take.validate(
            &plan.metadata,
            &evidence.seed,
            &evidence.cleanup_seed,
            &self.owner_metadata,
            @intFromPtr(self),
        ) or !plan.scalar_take.validate(self) or
            !self.client_cleanup_take.validate(
                client,
                &plan.backlog.client_disarm,
                &plan.backlog.inventory,
                &plan.backlog.cleanup_inventory,
            ))
            return null;
        return true;
    }

    fn commitAdoptionUnchecked(
        self: *ExternalPumpStorage,
        comptime Recorder: type,
        recorder: *Recorder,
        permit: *AdoptedCommitPermit,
        client: *client_mod.Client,
        evidence: *PreparedAdoptionEvidence,
        plan: *PreparedExternalAdoption,
    ) void {
        // `mintAdoptedCommitPermit` is the only caller and the ledger barrier has already
        // succeeded. Consume the linear permit before touching the first destination so it cannot
        // authorize a second suffix. No validation or failure branch is permitted from here on.
        permit.consumed = true;

        // The order is part of the c3c-2b2 linearization contract; none of these mechanics
        // allocates, invokes callbacks, validates, returns an error, or panics.
        plan.backlog.commitIntoUnchecked(
            &plan.screen_take,
            &self.committed_screen,
        );
        recorder.record(.screen_destination);
        external_event_materialization.commitOwnerMetadataTakeUnchecked(
            &plan.metadata_take,
            &plan.metadata,
            &evidence.seed,
            &evidence.cleanup_seed,
            &self.owner_metadata,
        );
        recorder.record(.metadata_destination);
        bindOwnerIncarnation(self, evidence.attach_instance_id);
        self.commitOwnerScalarTakeUnchecked(&plan.scalar_take);
        bindOwnerAuthority(self);
        self.bindPendingSummaries();
        self.owner_event_projection_generation = 0;
        recorder.record(.scalar_destination);
        client_mod.commitExternalAdoptionTakeUnchecked(
            client,
            &plan.backlog.client_disarm,
            &plan.backlog.inventory,
            &plan.backlog.cleanup_inventory,
            &self.client_cleanup_take,
        );
        recorder.record(.client_cleanup_take);
        plan.* = .{ .lifecycle = .committed_tombstone };
        recorder.record(.prepared_tombstone);
        self.semantic_state = .{ .active = .valid };
        recorder.record(.semantic_active);
        self.lifecycle = .live;
        recorder.record(.lifecycle_live);
    }

    fn latchCommitTerminal(
        self: *ExternalPumpStorage,
    ) CommitAdoptionResult {
        // No ledger ownership was published. Draining a pristine ledger would itself advance its
        // mutation epoch and would make a rejected final seal observable as a partial commit.
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = .invariant_failure,
            .fd_disposition = .owner_cleanup,
        } };
        self.resetPreparedAdoption();
        if (self.owned_client) |*owned| owned.deinit();
        self.owned_client = null;
        if (self.owned_evidence) |*owned| owned.deinit();
        self.owned_evidence = null;
        self.client_transfer.deinit();
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_request_ids = null;
        _ = self.inbox_ledger.finish() catch {};
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        return .terminal_latched;
    }

    fn latchCrossOwnerAliasTerminal(
        self: *ExternalPumpStorage,
    ) CommitAdoptionResult {
        // Once two independently freed owner graphs name the same backing, neither prepared graph
        // is a trustworthy cleanup authority. Quarantine both prepared graphs rather than invoking
        // either allocator through attacker-controlled mirrors. The original Client remains the
        // canonical source owner and is the only graph reclaimed here. This bounded corruption
        // leak is preferable to an arbitrary or double free and is observable as a terminal
        // invariant failure.
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = .invariant_failure,
            .fd_disposition = .owner_cleanup,
        } };
        _ = cross_owner_quarantine_latched.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        );
        _ = cross_owner_quarantine_events.fetchAdd(1, .acq_rel);
        self.prepared_adoption = .{ .lifecycle = .aborted_tombstone };
        self.client_cleanup_take = .{ .lifecycle = .aborted };
        if (self.owned_client) |*owned| owned.deinit();
        self.owned_client = null;
        self.owned_evidence = null;
        self.client_transfer.deinit();
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_request_ids = null;
        _ = self.inbox_ledger.finish() catch {};
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        return .terminal_latched;
    }

    fn resetPreparedAdoption(self: *ExternalPumpStorage) void {
        if (self.client_cleanup_take.requiresTypedCleanup()) {
            // A forged/moved committed tag must never reach generic deinit, which requires the
            // aggregate scratch and would panic without it. The source owners are still intact on
            // every pre-ledger failure, so clean those and leave the untrusted mirror inert.
            self.prepared_adoption.deinit(if (self.owned_client) |*owned|
                owned.allocator
            else
                null);
            self.prepared_adoption = .{};
            return;
        }
        self.client_cleanup_take.deinit();
        self.client_cleanup_take = .{};
        self.prepared_adoption.deinit(if (self.owned_client) |*owned|
            owned.allocator
        else
            null);
        self.prepared_adoption = .{};
    }

    pub fn teardown(
        self: *ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) TeardownResult {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return .moved_storage;
        if (active_external_operation_addr != 0)
            return .transaction_busy;
        switch (self.lifecycle) {
            .empty, .dead => return .already_dead,
            .constructing, .normalizing, .adoption_preparing, .tearing_down => return .transaction_busy,
            .adopting, .live => {},
        }
        active_external_operation_addr = @intFromPtr(self);
        defer active_external_operation_addr = 0;
        return self.teardownUnderHeldOperationLease(cleanup_scratch);
    }

    fn teardownUnderHeldOperationLease(
        self: *ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) TeardownResult {
        if (active_external_operation_addr != @intFromPtr(self))
            return .transaction_busy;
        if (self.saved_self_addr != @intFromPtr(self))
            return .moved_storage;
        switch (self.lifecycle) {
            .adopting, .live => {},
            .empty, .dead => return .already_dead,
            else => return .transaction_busy,
        }
        if (cleanupScratchOverlapsStorage(self, cleanup_scratch))
            return self.quarantineOwnerTeardown(cleanup_scratch, false);
        if (!cleanup_scratch.isReady())
            return self.quarantineOwnerTeardown(cleanup_scratch, false);
        if (self.owner_teardown_generation == std.math.maxInt(u64))
            return self.quarantineOwnerTeardown(cleanup_scratch, true);
        const next_generation = self.owner_teardown_generation + 1;

        // Before adoption commit, every allocation still belongs to the prepared graph rather
        // than the committed screen/metadata/take owners. Keep that graph on its established
        // cleanup path while the same aggregate operation lease closes allocator re-entry. The
        // committed path below is reserved for the owner graph that requires the frozen suffix.
        if (self.lifecycle == .adopting and
            !self.committed_screen.requiresTypedCleanup() and
            !self.owner_metadata.requiresTypedCleanup() and
            !self.client_cleanup_take.requiresTypedCleanup())
        {
            return switch (self.closeUncommittedOwned(.invariant_failure)) {
                .cleaned => .cleaned,
                .cleaned_with_invariant => .cleaned_with_invariant,
                .invalid_committed_owner => self.quarantineOwnerTeardown(
                    cleanup_scratch,
                    true,
                ),
            };
        }

        self.inbox_ledger.beginOwnerTeardown(
            next_generation,
            &cleanup_scratch.ledger_permit,
        ) catch return self.quarantineOwnerTeardown(cleanup_scratch, true);

        if (self.committed_screen.requiresTypedCleanup()) {
            if (!self.committed_screen.prepareFrozenCleanup(
                self,
                &cleanup_scratch.screen_plan,
                &cleanup_scratch.screen_prepared,
                &cleanup_scratch.screen_frozen,
            )) return self.quarantineOwnerTeardown(cleanup_scratch, true);
        } else {
            cleanup_scratch.screen_plan.initInPlace(
                &.{},
                std.StaticBitSet(external_inbox_ledger.max_items).initEmpty(),
            ) catch return self.quarantineOwnerTeardown(cleanup_scratch, true);
        }
        if (self.owner_metadata.requiresTypedCleanup() and
            !self.owner_metadata.prepareFrozenCleanup(
                self,
                &cleanup_scratch.metadata_prepared,
                &cleanup_scratch.metadata_frozen,
            ))
            return self.quarantineOwnerTeardown(cleanup_scratch, true);
        if (self.client_cleanup_take.requiresTypedCleanup() and
            !self.client_cleanup_take.prepareFrozenCleanup(
                &cleanup_scratch.client,
                &cleanup_scratch.take_prepared,
                &cleanup_scratch.take_frozen,
            ))
            return self.quarantineOwnerTeardown(cleanup_scratch, true);
        self.inbox_ledger.prepareFreezeAllForOwnerTeardown(
            &cleanup_scratch.ledger_permit,
            &cleanup_scratch.screen_plan,
            &cleanup_scratch.ledger_prepared,
            &cleanup_scratch.ledger_frozen,
        ) catch return self.quarantineOwnerTeardown(cleanup_scratch, true);

        if (self.owned_client) |*owned| {
            cleanup_scratch.range_scratch.source = .{};
            owned.preflightExternalAdoptionDestinationWithScratch(
                cleanup_scratch,
                @sizeOf(ExternalPumpCleanupScratch),
                &cleanup_scratch.range_scratch.source,
            ) catch return self.quarantineOwnerTeardown(cleanup_scratch, true);
        }
        if (!self.prepareAggregateOwnerRangeProof(cleanup_scratch))
            return self.quarantineOwnerTeardown(cleanup_scratch, true);

        self.tombstonePendingSummaries();
        self.lifecycle = .tearing_down;
        const terminal_state: client_pump.ExternalPumpState = switch (self.semantic_state) {
            .terminal => self.semantic_state,
            else => .{ .terminal = .{
                .reason = .invariant_failure,
                .fd_disposition = .owner_cleanup,
            } },
        };
        const storage_addr = @intFromPtr(self);
        const evidence_snapshot = self.evidence_snapshot;
        const operation_generation = self.operation_generation;
        const external_identity_teardown_generation =
            cleanup_scratch.ledger_prepared.terminal_external_identity_seal.generation;
        self.semantic_state = terminal_state;
        self.owner_teardown_generation = next_generation;

        if (cleanup_scratch.metadata_prepared.lifecycle != .empty)
            self.owner_metadata.commitFrozenCleanupUnchecked(
                &cleanup_scratch.metadata_prepared,
                &cleanup_scratch.metadata_frozen,
            );
        if (cleanup_scratch.take_prepared.lifecycle != .empty)
            client_mod.commitExternalAdoptionTakeFrozenCleanupUnchecked(
                &self.client_cleanup_take,
                &cleanup_scratch.take_prepared,
                &cleanup_scratch.take_frozen,
            );
        const ledger_summary =
            self.inbox_ledger.commitFreezeAllForOwnerTeardownUnchecked(
                &cleanup_scratch.ledger_permit,
                &cleanup_scratch.ledger_prepared,
                &cleanup_scratch.ledger_frozen,
            );
        if (cleanup_scratch.screen_prepared.lifecycle != .empty)
            self.committed_screen.commitFrozenCleanupUnchecked(
                &cleanup_scratch.screen_prepared,
                &cleanup_scratch.screen_frozen,
            );
        cleanup_scratch.moved_client = self.owned_client;
        self.owned_client = null;
        cleanup_scratch.moved_evidence = self.owned_evidence;
        self.owned_evidence = null;
        self.prepared_adoption = .{ .lifecycle = .committed_tombstone };
        self.client_transfer = .{};
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_authority_seal = .{};
        self.owner_request_ids = null;
        self.owner_incarnation = 0;
        self.owner_incarnation_seal = .{};
        self.owner_event_projection_generation = 0;
        cleanup_scratch.lifecycle = .frozen;

        var local_ledger = cleanup_scratch.ledger_frozen;
        var local_metadata = cleanup_scratch.metadata_frozen;
        var local_take = cleanup_scratch.take_frozen;
        var local_client_scratch = cleanup_scratch.client;
        var local_moved_client = cleanup_scratch.moved_client;
        var local_moved_evidence = cleanup_scratch.moved_evidence;
        var local_screen = cleanup_scratch.screen_frozen;
        cleanup_scratch.* = .{
            .saved_self_addr = @intFromPtr(cleanup_scratch),
            .lifecycle = .frozen,
        };
        local_ledger.saved_self_addr = @intFromPtr(&local_ledger);
        local_metadata.saved_self_addr = if (local_metadata.saved_self_addr == 0)
            0
        else
            @intFromPtr(&local_metadata);
        local_screen.saved_self_addr = if (local_screen.saved_self_addr == 0)
            0
        else
            @intFromPtr(&local_screen);
        local_take.saved_self_addr = if (local_take.saved_self_addr == 0)
            0
        else
            @intFromPtr(&local_take);

        var had_invariant = ledger_summary.had_invariant or
            ledger_summary.orphan_count != 0;
        if (local_ledger.finishCallbackHidden() != .cleaned)
            had_invariant = true;
        if (local_metadata.saved_self_addr != 0) {
            had_invariant = had_invariant or local_metadata.had_invariant;
            if (external_event_materialization.finishFrozenCleanup(
                &local_metadata,
            ) != .cleaned) had_invariant = true;
        }
        if (local_take.saved_self_addr != 0 and
            client_mod.finishFrozenCleanupWithHiddenScratch(
                &local_take,
                &local_client_scratch,
            ) != .cleaned)
            had_invariant = true;
        if (local_moved_client) |*owned| owned.deinit();
        local_moved_client = null;
        if (local_moved_evidence) |*owned| owned.deinit();
        local_moved_evidence = null;
        if (local_screen.saved_self_addr != 0 and
            client_external_adoption.finishFrozenCleanup(
                &local_screen,
            ) != .cleaned)
            had_invariant = true;

        self.saved_self_addr = storage_addr;
        self.evidence_snapshot = evidence_snapshot;
        self.owned_client = null;
        self.owned_evidence = null;
        self.client_transfer = .{};
        self.inbox_ledger.restoreFinishedOwnerTeardownUnchecked(
            next_generation,
            external_identity_teardown_generation,
        );
        self.prepared_adoption = .{ .lifecycle = .committed_tombstone };
        self.committed_screen = .{ .lifecycle = .cleaned_tombstone };
        self.screen_pending_summary = .{ .lifecycle = .tombstone };
        self.owner_metadata = .{ .lifecycle = .cleaned_tombstone };
        self.metadata_pending_summary = .{ .lifecycle = .tombstone };
        self.client_cleanup_take = .{ .lifecycle = .aborted };
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_authority_seal = .{};
        self.owner_request_ids = null;
        self.owner_incarnation = 0;
        self.owner_incarnation_seal = .{};
        self.owner_event_projection_generation = 0;
        self.operation_generation = operation_generation;
        self.owner_teardown_generation = next_generation;
        self.semantic_state = terminal_state;
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        cleanup_scratch.resetReady();
        return if (had_invariant) .cleaned_with_invariant else .cleaned;
    }

    fn prepareAggregateOwnerRangeProof(
        self: *const ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
    ) bool {
        var source_ranges = cleanup_scratch.range_scratch.source;
        cleanup_scratch.range_scratch_kind = .teardown;
        cleanup_scratch.range_scratch = .{ .teardown = .{} };
        const ranges = &cleanup_scratch.range_scratch.teardown;
        if (self.owned_client) |*owned|
            owned.appendExternalOwnerRangesForTeardown(
                &source_ranges,
                ranges,
            ) catch return false;
        if (self.owned_evidence) |*evidence|
            evidence.appendCleanupRange(ranges) catch return false;
        self.inbox_ledger.appendPreparedOwnerTeardownRanges(
            &cleanup_scratch.ledger_prepared,
            ranges,
        ) catch return false;
        if (cleanup_scratch.screen_prepared.lifecycle != .empty)
            self.committed_screen.appendPreparedFrozenCleanupRanges(
                &cleanup_scratch.screen_prepared,
                ranges,
            ) catch return false;
        if (cleanup_scratch.metadata_prepared.lifecycle != .empty)
            self.owner_metadata.appendPreparedFrozenCleanupRanges(
                &cleanup_scratch.metadata_prepared,
                ranges,
            ) catch return false;
        if (cleanup_scratch.take_prepared.lifecycle != .empty)
            self.client_cleanup_take.appendPreparedFrozenCleanupRanges(
                &cleanup_scratch.take_prepared,
                ranges,
            ) catch return false;
        ranges.validate(&.{
            .{
                .start = @intFromPtr(self),
                .len = @sizeOf(ExternalPumpStorage),
            },
            .{
                .start = @intFromPtr(cleanup_scratch),
                .len = @sizeOf(ExternalPumpCleanupScratch),
            },
        }) catch return false;
        return true;
    }

    fn quarantineOwnerTeardown(
        self: *ExternalPumpStorage,
        cleanup_scratch: *ExternalPumpCleanupScratch,
        scratch_trusted: bool,
    ) TeardownResult {
        self.tombstonePendingSummaries();
        self.lifecycle = .dead;
        self.semantic_state = .{ .terminal = .{
            .reason = .invariant_failure,
            .fd_disposition = .owner_cleanup,
        } };
        _ = cross_owner_quarantine_latched.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        );
        _ = cross_owner_quarantine_events.fetchAdd(1, .acq_rel);
        if (scratch_trusted)
            cleanup_scratch.lifecycle = .poisoned;
        self.owner_incarnation = 0;
        self.owner_incarnation_seal = .{};
        self.owner_event_projection_generation = 0;
        releaseActiveStorage(@intFromPtr(self));
        return .quarantined;
    }

    fn requireAddress(self: *const ExternalPumpStorage) AccessError!void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return error.MovedStorage;
    }

    fn closeUncommittedOwned(
        self: *ExternalPumpStorage,
        reason: client_pump.TerminalReason,
    ) UncommittedCloseResult {
        // This leaf owns only the pre-commit prepared graph. A committed owner must go through the
        // frozen aggregate suffix, which has caller-owned descriptor storage for callback hiding.
        const metadata_is_allocation_free_baseline =
            self.owner_metadata.isCommitted() and
            self.owner_metadata.metadata != .current;
        if (self.committed_screen.requiresTypedCleanup() or
            (self.owner_metadata.requiresTypedCleanup() and
                !metadata_is_allocation_free_baseline) or
            self.client_cleanup_take.requiresTypedCleanup())
            return .invalid_committed_owner;
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        self.prepared_adoption.deinit(if (self.owned_client) |*owned|
            owned.allocator
        else
            null);
        if (metadata_is_allocation_free_baseline)
            self.owner_metadata.deinitCommitted();
        if (self.owned_client) |*owned| owned.deinit();
        self.owned_client = null;
        if (self.owned_evidence) |*owned| owned.deinit();
        self.owned_evidence = null;
        self.client_transfer.deinit();
        self.owner_resize = .none;
        self.owner_authority = .empty;
        self.owner_request_ids = null;
        const drain_report = self.inbox_ledger.drainAll() catch
            external_inbox_ledger.DrainReport{
                .drained_active_count = 0,
                .drained_bytes = 0,
                .had_sticky_invariant = true,
            };
        const ledger_result = self.inbox_ledger.finish();
        self.lifecycle = .dead;
        releaseActiveStorage(@intFromPtr(self));
        if (drain_report.drained_active_count != 0 or
            drain_report.had_sticky_invariant)
            return .cleaned_with_invariant;
        return if (ledger_result) |_| .cleaned else |_| .cleaned_with_invariant;
    }
};

fn cleanupScratchOverlapsStorage(
    storage: *const ExternalPumpStorage,
    cleanup_scratch: *const ExternalPumpCleanupScratch,
) bool {
    return cleanupScratchRangeOverlapsStorage(
        @intFromPtr(storage),
        @intFromPtr(cleanup_scratch),
    );
}

fn teardownForTest(storage: *ExternalPumpStorage) TeardownResult {
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    std.debug.assert(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    return storage.teardown(&cleanup_scratch);
}

fn cleanupScratchRangeOverlapsStorage(
    storage_addr: usize,
    cleanup_scratch_addr: usize,
) bool {
    return rangesOverlap(
        cleanup_scratch_addr,
        @sizeOf(ExternalPumpCleanupScratch),
        storage_addr,
        @sizeOf(ExternalPumpStorage),
    );
}

fn consumeFrozenClientQueues(
    client: *client_mod.Client,
    cleanup_scratch: *ExternalPumpCleanupScratch,
) void {
    client_mod.commitExternalRecoveryDiscardUnchecked(
        client,
        &cleanup_scratch.recovery_discard,
        &cleanup_scratch.client,
    );
}

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

fn terminalReasonForDecision(
    decision: external_source_decision.PreparedSourceDecision,
) client_pump.TerminalReason {
    return switch (decision.verdict) {
        .ended => .runtime_ended,
        .revoked => .revoked,
        .host_recovery, .client_recovery, .adopted => .invariant_failure,
        .terminal => |reason| switch (reason) {
            .request_id_zero => .request_id_exhausted,
            .inconsistent_fold => .invariant_failure,
            .fold => |fold_reason| switch (fold_reason) {
                .source,
                .transport,
                .metadata_equivocation,
                .resize_equivocation,
                => .protocol_error,
                .stale_metadata_candidate,
                .ordinal_exhausted,
                .ordinal_mismatch,
                .moved_accumulator,
                => .invariant_failure,
            },
        },
    };
}

fn terminalReasonForPrepareError(
    err: client_external_adoption.PrepareError,
) client_pump.TerminalReason {
    return switch (err) {
        error.OutOfMemory => .invariant_failure,
        error.MetadataTooLarge => .resource_exhausted,
        error.InvalidStream,
        error.InvalidHeader,
        error.InvalidPartial,
        error.InvalidRequestId,
        error.InvalidScreenSemantic,
        error.IneligibleProfile,
        error.InvalidCompatibilityProvenance,
        => .protocol_error,
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
        error.TeardownActive,
        error.InvalidAddress,
        => .invariant_failure,
    };
}

fn terminalReasonForAuthorityError(
    err: PrepareAuthorityError,
) client_pump.TerminalReason {
    return switch (err) {
        error.ProtocolAuthority => .protocol_error,
        error.InvariantAuthority => .invariant_failure,
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

fn adoptionFinalSealDigest(
    storage: *const ExternalPumpStorage,
    permit: *const PreparedAdoptionFinalSeal,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("maru.external-adoption-commit.v1");
    writer.writeU64(1);
    writer.writeUsize(permit.storage_addr);
    writer.writeUsize(permit.plan_addr);
    writer.writeUsize(permit.client_addr);
    writer.writeUsize(permit.ledger_addr);
    writer.writeUsize(permit.evidence_addr);
    writer.writeUsize(permit.client_cleanup_take_addr);
    writer.writeUsize(permit.screen_take_addr);
    writer.writeUsize(permit.metadata_take_addr);
    writer.writeUsize(permit.scalar_take_addr);
    writer.writeUsize(permit.committed_screen_addr);
    writer.writeUsize(permit.screen_pending_summary_addr);
    writer.writeUsize(permit.owner_metadata_addr);
    writer.writeUsize(permit.metadata_pending_summary_addr);
    writer.writeUsize(permit.owner_resize_addr);
    writer.writeUsize(permit.owner_authority_addr);
    writer.writeUsize(permit.owner_request_ids_addr);
    writer.writeU64(permit.operation_generation);
    const plan = &storage.prepared_adoption;
    // Preparation temporarily publishes `.adoption_preparing`; the sealed commit state is the
    // stable `.adopting` lifecycle observed after the callback window closes.
    writer.writeU8(@intFromEnum(StorageLifecycle.adopting));
    writer.writeU8(@intFromEnum(plan.lifecycle));
    writer.writeU8(@intFromEnum(plan.branch));
    writer.writeU8(plan.screen_take.lifecycleCode());
    writer.writeU8(plan.metadata_take.lifecycleCode());
    writer.writeU8(@intFromEnum(plan.scalar_take.lifecycle));
    writer.writeU8(storage.client_cleanup_take.lifecycleCode());
    writer.writeU8(@intFromEnum(storage.committed_screen.lifecycle));
    writer.writeU8(@intFromEnum(storage.owner_metadata.lifecycle));
    writer.writeU8(@intFromEnum(std.meta.activeTag(storage.owner_resize)));
    writer.writeU8(@intFromEnum(std.meta.activeTag(storage.owner_authority)));
    writer.writeBool(storage.owner_request_ids != null);
    writer.writeU128(storage.evidence_snapshot.runtime_id);
    writer.writeU64(storage.evidence_snapshot.stream_id);
    writer.writeU8(@intFromEnum(storage.evidence_snapshot.initial_role));
    writer.writeU64(
        storage.evidence_snapshot.initial_controller_generation,
    );
    if (storage.owned_evidence) |evidence| {
        writer.writeU64(evidence.attach_instance_id);
        writer.writeUsize(evidence.saved_self_addr);
        writer.writeU8(@intFromEnum(evidence.lifecycle));
    } else {
        writer.writeU64(0);
        writer.writeUsize(0);
        writer.writeU8(0);
    }
    const ledger_view = storage.inbox_ledger.accountingView();
    writer.writeUsize(ledger_view.charged_bytes);
    writer.writeUsize(ledger_view.charged_items);
    writer.writeU64(ledger_view.mutation_epoch);
    writer.writeBool(ledger_view.valid);
    writer.writeBool(ledger_view.pristine_zero);
    writer.writeU64(plan.screen_take.target_stream);
    writer.writeUsize(plan.screen_take.tokens_addr);
    writer.writeUsize(plan.screen_take.tokens_len);
    writer.writeBytes(&storage.client_cleanup_take.inventory_cleanup_seal);
    writer.writeBytes(&storage.client_cleanup_take.cleanup_inventory_cleanup_seal);
    writer.writeBytes(&storage.client_cleanup_take.inventory_backing_seal);
    writer.writeBytes(&storage.client_cleanup_take.cleanup_inventory_backing_seal);
    writer.writeUsize(storage.client_cleanup_take.allocator_ptr_addr);
    writer.writeUsize(storage.client_cleanup_take.allocator_vtable_addr);
    if (plan.metadata_take.primary_seal) |seal| {
        writer.writeBool(true);
        writer.writeBytes(&seal.raw_digest);
        writer.writeBytes(&seal.semantic_digest);
    } else writer.writeBool(false);
    if (plan.metadata_take.cleanup_seal) |seal| {
        writer.writeBool(true);
        writer.writeBytes(&seal.raw_digest);
        writer.writeBytes(&seal.semantic_digest);
    } else writer.writeBool(false);
    if (plan.scalar_take.resize) |resize| {
        writer.writeU8(1);
        writer.writeU128(resize.runtime_id);
        writer.writeU16(resize.cols);
        writer.writeU16(resize.rows);
        writer.writeU64(resize.resize_generation);
    } else writer.writeU8(0);
    switch (plan.scalar_take.authority) {
        .empty => writer.writeU8(0),
        .current => |authority| {
            writer.writeU8(1);
            writer.writeU8(@intFromEnum(authority.role));
            switch (authority.generation) {
                .untracked => writer.writeU8(0),
                .tracked => |generation| {
                    writer.writeU8(1);
                    writer.writeU64(generation);
                },
            }
            writer.writeU8(@intFromEnum(authority.flow));
        },
    }
    switch (plan.scalar_take.request_ids) {
        .available => |next| {
            writer.writeU8(0);
            writer.writeU64(next);
        },
        .last_available => writer.writeU8(1),
        .max_consumed => writer.writeU8(2),
    }
    return writer.finish();
}

const CommitHeaderRange = struct {
    addr: usize,
    len: usize,
};

fn commitHeadersPairwiseDisjoint(storage: *const ExternalPumpStorage) bool {
    const client = if (storage.owned_client) |*owned| owned else return false;
    const evidence = if (storage.owned_evidence) |*owned| owned else return false;
    const ranges = commitHeaderRanges(storage, client, evidence);
    for (ranges, 0..) |left, index| {
        for (ranges[index + 1 ..]) |right| {
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
        }
    }
    return true;
}

fn commitHeaderRanges(
    storage: *const ExternalPumpStorage,
    client: *const client_mod.Client,
    evidence: *const PreparedAdoptionEvidence,
) [17]CommitHeaderRange {
    const plan = &storage.prepared_adoption;
    return .{
        .{ .addr = @intFromPtr(&plan.backlog), .len = @sizeOf(client_external_adoption.PreparedScreenBacklog) },
        .{ .addr = @intFromPtr(&plan.metadata), .len = @sizeOf(external_event_materialization.Prepared) },
        .{ .addr = @intFromPtr(&plan.screen_take), .len = @sizeOf(client_external_adoption.PreparedCommittedScreenTake) },
        .{ .addr = @intFromPtr(&plan.metadata_take), .len = @sizeOf(external_event_materialization.PreparedOwnerMetadataTake) },
        .{ .addr = @intFromPtr(&plan.scalar_take), .len = @sizeOf(PreparedOwnerScalarTake) },
        .{ .addr = @intFromPtr(&plan.final_seal), .len = @sizeOf(PreparedAdoptionFinalSeal) },
        .{ .addr = @intFromPtr(&storage.client_cleanup_take), .len = @sizeOf(client_mod.ExternalAdoptionTake) },
        .{ .addr = @intFromPtr(&storage.committed_screen), .len = @sizeOf(client_external_adoption.CommittedScreenBacklog) },
        .{ .addr = @intFromPtr(&storage.screen_pending_summary), .len = @sizeOf(ScreenPendingSummarySeal) },
        .{ .addr = @intFromPtr(&storage.owner_metadata), .len = @sizeOf(external_event_materialization.OwnerMetadataState) },
        .{ .addr = @intFromPtr(&storage.metadata_pending_summary), .len = @sizeOf(MetadataPendingSummarySeal) },
        .{ .addr = @intFromPtr(&storage.owner_resize), .len = @sizeOf(OwnerResizeState) },
        .{ .addr = @intFromPtr(&storage.owner_authority), .len = @sizeOf(OwnerAuthorityState) },
        .{ .addr = @intFromPtr(&storage.owner_request_ids), .len = @sizeOf(?client_pump.RequestIdState) },
        .{ .addr = @intFromPtr(client), .len = @sizeOf(client_mod.Client) },
        .{ .addr = @intFromPtr(evidence), .len = @sizeOf(PreparedAdoptionEvidence) },
        .{ .addr = @intFromPtr(&storage.inbox_ledger), .len = @sizeOf(external_inbox_ledger.ExternalInboxLedger) },
    };
}

fn adoptionOwnerBackingsPairwiseDisjoint(
    plan: *const PreparedExternalAdoption,
    client: *const client_mod.Client,
    evidence: *const PreparedAdoptionEvidence,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    const transfer = plan.backlog.transfer orelse return true;
    if (!screenSliceDisjointFromClientAndMetadata(
        client_mod.ExternalScreenCopy,
        transfer.copies,
        plan,
        client,
        evidence,
        scratch,
    ) or !screenSliceDisjointFromClientAndMetadata(
        external_inbox_ledger.OwnedPayload,
        transfer.wrappers,
        plan,
        client,
        evidence,
        scratch,
    ) or !screenSliceDisjointFromClientAndMetadata(
        external_inbox_ledger.Token,
        transfer.tokens,
        plan,
        client,
        evidence,
        scratch,
    )) {
        return false;
    }
    for (transfer.copies) |copy| {
        if (!screenRangeDisjointFromClientAndMetadata(
            @intFromPtr(copy.view.ptr),
            copy.view.len,
            plan,
            client,
            evidence,
            scratch,
        )) {
            return false;
        }
    }
    inline for (.{
        plan.backlog.inventory,
        plan.backlog.cleanup_inventory,
        plan.backlog.client_disarm.inventory,
        plan.backlog.client_disarm.cleanup_inventory,
    }) |maybe_inventory| {
        if (maybe_inventory) |inventory| {
            if (!inventoryBackingsDisjointFromMetadata(
                &inventory,
                plan,
                evidence,
            )) {
                return false;
            }
        }
    }
    const metadata_disjoint = metadataBackingsDisjointFromClient(
        &plan.metadata,
        &evidence.seed,
        &evidence.cleanup_seed,
        client,
        scratch,
    );
    return metadata_disjoint;
}

fn screenRangeDisjointFromClientAndMetadata(
    addr: usize,
    len: usize,
    plan: *const PreparedExternalAdoption,
    client: *const client_mod.Client,
    evidence: *const PreparedAdoptionEvidence,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    if (len == 0) return true;
    client.preflightExternalAdoptionDestinationWithScratch(
        @ptrFromInt(addr),
        len,
        scratch,
    ) catch return false;
    return !external_event_materialization.preparedMetadataOverlapsOwnedBacking(
        &plan.metadata,
        &evidence.seed,
        &evidence.cleanup_seed,
        addr,
        len,
    );
}

fn screenSliceDisjointFromClientAndMetadata(
    comptime T: type,
    slice: []const T,
    plan: *const PreparedExternalAdoption,
    client: *const client_mod.Client,
    evidence: *const PreparedAdoptionEvidence,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    const len = std.math.mul(usize, slice.len, @sizeOf(T)) catch return false;
    return screenRangeDisjointFromClientAndMetadata(
        @intFromPtr(slice.ptr),
        len,
        plan,
        client,
        evidence,
        scratch,
    );
}

fn inventoryBackingsDisjointFromMetadata(
    inventory: *const client_mod.ExternalAdoptionInventory,
    plan: *const PreparedExternalAdoption,
    evidence: *const PreparedAdoptionEvidence,
) bool {
    inline for (.{
        inventory.batch_descriptors,
        inventory.cleanup_batch_descriptors,
        inventory.stream_descriptors,
        inventory.cleanup_stream_descriptors,
        inventory.event_descriptors,
        inventory.cleanup_event_descriptors,
        inventory.build_id_copy,
        inventory.cleanup_build_id_copy,
        inventory.lifecycle_copy,
        inventory.cleanup_lifecycle_copy,
    }) |slice| {
        const len = std.math.mul(
            usize,
            slice.len,
            @sizeOf(std.meta.Child(@TypeOf(slice))),
        ) catch return false;
        if (len != 0 and
            external_event_materialization.preparedMetadataOverlapsOwnedBacking(
                &plan.metadata,
                &evidence.seed,
                &evidence.cleanup_seed,
                @intFromPtr(slice.ptr),
                len,
            ))
            return false;
    }
    return true;
}

fn metadataBackingsDisjointFromClient(
    prepared: *const external_event_materialization.Prepared,
    initial: *const runtime_metadata_wire.InitialMetadataSeed,
    cleanup: *const runtime_metadata_wire.InitialMetadataSeed,
    client: *const client_mod.Client,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    if (!metadataSeedBackingDisjointFromClient(initial, client, scratch) or
        !metadataSeedBackingDisjointFromClient(cleanup, client, scratch))
        return false;
    return switch (prepared.metadata) {
        .event => |event| (if (event.logical) |dto|
            metadataDtoBackingDisjointFromClient(&dto, client, scratch)
        else
            true) and (if (event.cleanup) |dto|
            metadataDtoBackingDisjointFromClient(&dto, client, scratch)
        else
            true),
        else => true,
    };
}

fn metadataSeedBackingDisjointFromClient(
    seed: *const runtime_metadata_wire.InitialMetadataSeed,
    client: *const client_mod.Client,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    return switch (seed.*) {
        .current => |dto| metadataDtoBackingDisjointFromClient(
            &dto,
            client,
            scratch,
        ),
        else => true,
    };
}

fn metadataDtoBackingDisjointFromClient(
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
    client: *const client_mod.Client,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    const backing = dto.backing orelse return true;
    client.preflightExternalAdoptionDestinationWithScratch(
        backing.ptr,
        backing.len,
        scratch,
    ) catch return false;
    return true;
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

fn rangeContains(
    outer_start: usize,
    outer_len: usize,
    inner_start: usize,
    inner_len: usize,
) bool {
    if (outer_start == 0 or outer_len == 0 or inner_start == 0 or inner_len == 0)
        return false;
    const outer_end = std.math.add(usize, outer_start, outer_len) catch return false;
    const inner_end = std.math.add(usize, inner_start, inner_len) catch return false;
    return inner_start >= outer_start and inner_end <= outer_end;
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

const TestCommitRecorder = struct {
    storage: *ExternalPumpStorage,
    phases: [8]CommitPhase = undefined,
    count: usize = 0,
    state_order_valid: bool = true,
    callback_counter: ?*const usize = null,
    callbacks_after_ledger: usize = 0,

    inline fn beforePermit(
        _: *TestCommitRecorder,
        backlog: *client_external_adoption.PreparedScreenBacklog,
        ledger: *external_inbox_ledger.ExternalInboxLedger,
    ) void {
        _ = backlog;
        _ = ledger;
    }

    inline fn record(self: *TestCommitRecorder, phase: CommitPhase) void {
        if (self.count >= self.phases.len) {
            self.state_order_valid = false;
            return;
        }
        self.phases[self.count] = phase;
        self.count += 1;
        if (self.callback_counter) |counter| {
            if (phase == .ledger_seed) {
                self.callbacks_after_ledger = counter.*;
            } else {
                self.state_order_valid = self.state_order_valid and
                    counter.* == self.callbacks_after_ledger;
            }
        }
        self.state_order_valid = self.state_order_valid and
            switch (phase) {
                .ledger_seed => self.storage.lifecycle == .adopting and
                    self.storage.committed_screen.isEmpty() and
                    self.storage.owner_metadata.isEmpty(),
                .screen_destination => self.storage.lifecycle == .adopting and
                    self.storage.committed_screen.isCommitted(self.storage) and
                    self.storage.owner_metadata.isEmpty(),
                .metadata_destination => self.storage.lifecycle == .adopting and
                    self.storage.owner_metadata.isCommitted() and
                    self.storage.owner_authority == .empty,
                .scalar_destination => self.storage.lifecycle == .adopting and
                    self.storage.owner_authority == .current and
                    !self.storage.client_cleanup_take.isCommitted(),
                .client_cleanup_take => self.storage.lifecycle == .adopting and
                    self.storage.client_cleanup_take.isCommitted(),
                .prepared_tombstone => self.storage.lifecycle == .adopting and
                    self.storage.prepared_adoption.lifecycle ==
                        .committed_tombstone,
                .semantic_active => self.storage.lifecycle == .adopting and
                    self.storage.semantic_state == .active,
                .lifecycle_live => self.storage.lifecycle == .live and
                    self.storage.semantic_state == .active,
            };
    }
};

const LedgerPreconditionDriftRecorder = struct {
    const Scenario = enum {
        stale_plan,
        invalid_plan,
        planning_disabled,
        drained,
        invariant_failure,
    };

    scenario: Scenario,
    injected: ?external_inbox_ledger.AccountingView = null,
    phase_count: usize = 0,

    inline fn beforePermit(
        self: *LedgerPreconditionDriftRecorder,
        backlog: *client_external_adoption.PreparedScreenBacklog,
        ledger: *external_inbox_ledger.ExternalInboxLedger,
    ) void {
        switch (self.scenario) {
            .stale_plan => ledger.mutation_epoch +%= 1,
            .invalid_plan => backlog.seed_plan.payload_wrappers_addr +%= 1,
            .planning_disabled => ledger.planning_disabled = true,
            .drained => ledger.draining_or_drained = true,
            .invariant_failure => ledger.charged_items = 1,
        }
        self.injected = ledger.accountingView();
    }

    inline fn record(self: *LedgerPreconditionDriftRecorder, _: CommitPhase) void {
        self.phase_count += 1;
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
        prepare_preflight_oom_drift,
        take_alloc_oom_drift,
        teardown_reentry,
        commit_cleanup_reentry,
        cleanup_authority_drift,
        cleanup_nested_descriptor_drift,
        suffix_storage_drift,
    };

    parent: std.mem.Allocator,
    mode: Mode = .idle,
    fired: bool = false,
    callback_count: usize = 0,
    storage: ?*ExternalPumpStorage = null,
    cleanup_scratch: ?*ExternalPumpCleanupScratch = null,
    source: ?*client_mod.Client = null,
    evidence: ?*PreparedAdoptionEvidence = null,
    nested_storage: ?*ExternalPumpStorage = null,
    nested_source: ?*client_mod.Client = null,
    nested_evidence: ?*PreparedAdoptionEvidence = null,
    nested_init_reason: ?InitFailureReason = null,
    nested_teardown: ?TeardownResult = null,
    nested_prepare_tag: ?std.meta.Tag(AdoptionPrepareStatus) = null,
    nested_commit: ?CommitAdoptionResult = null,
    saved_event_byte: ?u8 = null,
    source_was_tombstoned_at_proof_free: bool = false,
    saved_io_mode: ?client_external_mode.Mode = null,
    saved_connection_profile: ?client_mod.ConnectionProfile = null,
    saved_compatibility_profile: ?compatibility.Profile = null,
    screen_copies: ?[]client_mod.ExternalScreenCopy = null,
    screen_wrappers: ?[]external_inbox_ledger.OwnedPayload = null,

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
        self.callback_count += 1;
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
                        prepareAdoptionForTest(self.storage.?)
                    else
                        prepareAdoptionForTest(self.nested_storage.?),
                );
                if (self.mode == .cross_prepare_reentry)
                    self.nested_teardown = teardownForTest(self.nested_storage.?);
            } else {
                self.nested_teardown = teardownForTest(self.storage.?);
            }
        } else if (!self.fired and self.mode == .prepare_cleanup_teardown and
            self.storage.?.lifecycle == .adoption_preparing and
            self.storage.?.prepared_adoption.metadata.saved_self_addr != 0)
        {
            self.fired = true;
            const payload = self.source.?.pending_events.items[0].payload;
            self.saved_event_byte = payload[0];
            payload[0] ^= 1;
        } else if (!self.fired and self.mode == .prepare_preflight_oom_drift and
            self.storage.?.lifecycle == .adoption_preparing and
            self.storage.?.prepared_adoption.lifecycle == .empty)
        {
            self.fired = true;
            self.source.?.pending_event_bytes +%= 1;
            return null;
        } else if (!self.fired and self.mode == .take_alloc_oom_drift and
            self.storage.?.lifecycle == .adoption_preparing and
            self.storage.?.prepared_adoption.backlog.lifecycle == .prepared and
            self.storage.?.client_cleanup_take.saved_self_address == 0)
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
        self.callback_count += 1;
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
        self.callback_count += 1;
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
        self.callback_count += 1;
        if (self.mode == .prepare_cleanup_teardown and
            self.fired and self.nested_teardown == null and
            self.storage.?.lifecycle == .adoption_preparing)
        {
            self.nested_teardown = teardownForTest(self.storage.?);
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
            self.nested_teardown = teardownForTest(self.storage.?);
        } else if (!self.fired and self.mode == .commit_cleanup_reentry and
            self.storage.?.lifecycle == .tearing_down)
        {
            self.fired = true;
            self.nested_commit = self.storage.?.commitAdoption();
            self.nested_teardown = teardownForTest(self.storage.?);
        } else if (!self.fired and self.mode == .cleanup_authority_drift and
            self.storage.?.lifecycle == .tearing_down)
        {
            self.fired = true;
            const foreign = @as(
                [*]client_mod.ExternalScreenCopy,
                @ptrFromInt(@alignOf(client_mod.ExternalScreenCopy)),
            )[0..1];
            self.storage.?.prepared_adoption.backlog.transfer = .{
                .copies = foreign,
                .cleanup_copies = foreign,
                .copies_addr = @intFromPtr(foreign.ptr),
                .copies_len = foreign.len,
            };
            self.storage.?.prepared_adoption.screen_take.commit_transfer = .{
                .copies = foreign,
                .cleanup_copies = foreign,
                .copies_addr = @intFromPtr(foreign.ptr),
                .copies_len = foreign.len,
            };
        } else if (!self.fired and
            self.mode == .cleanup_nested_descriptor_drift and
            self.storage.?.lifecycle == .tearing_down)
        {
            self.fired = true;
            const foreign = @as([*]u8, @ptrFromInt(1))[0..1];
            self.screen_copies.?[0].bytes = foreign;
            self.screen_copies.?[0].view = foreign;
            self.screen_wrappers.?[0].allocation_ptr = foreign.ptr;
            self.screen_wrappers.?[0].logical_len = foreign.len;
        } else if (!self.fired and self.mode == .suffix_storage_drift and
            (self.storage.?.lifecycle == .adoption_preparing or
                self.storage.?.lifecycle == .tearing_down))
        {
            self.fired = true;
            self.storage.?.saved_self_addr = 0;
            self.storage.?.evidence_snapshot.runtime_id = 0;
            self.storage.?.semantic_state = .constructing;
            self.storage.?.owner_authority = .empty;
            self.storage.?.owner_request_ids = null;
            self.storage.?.inbox_ledger.charged_items = 1;
            self.storage.?.inbox_ledger.retired_items = 1;
            self.storage.?.inbox_ledger.retired_bytes = 1;
            self.storage.?.inbox_ledger.next_generation = std.math.maxInt(u64);
            self.storage.?.inbox_ledger.generation_exhausted = true;
            self.storage.?.inbox_ledger.mutation_epoch = std.math.maxInt(u64);
            self.storage.?.inbox_ledger.invariant_failed = true;
            if (self.cleanup_scratch) |scratch| scratch.saved_self_addr = 0;
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
    return initTestStorageWithOptions(out, source, attachment, .{
        .test_skip_process_owner_reservation = true,
    });
}

fn initTestStorageWithOptions(
    out: *ExternalPumpStorage,
    source: *client_mod.Client,
    attachment: AttachmentEvidence,
    options: InitOptions,
) InitResult {
    var test_options = options;
    test_options.test_skip_process_owner_reservation = true;
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
        test_options,
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
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    defer _ = teardownForTest(&storage);
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    try std.testing.expect(evidence.lifecycle == .committed_tombstone);
    const owned = &storage.owned_evidence.?.seed.current;
    try std.testing.expectEqualStrings("/repo", owned.cwd());
    try std.testing.expectEqualStrings("zsh", owned.foregroundProcesses()[0].slice());
    try std.testing.expect(storage.owned_evidence.?.validate(&storage.owned_client.?));
    const rx_state = switch (storage.owned_client.?.io_mode) {
        .external => |*state| state,
        .blocking => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_mode.RxProvenanceLifecycle.bound,
        rx_state.rx_provenance.lifecycle,
    );
    try std.testing.expectEqual(@as(u64, 12), rx_state.rx_provenance.identity.?.attach_instance_id);
    try std.testing.expectEqual(
        @intFromPtr(&storage.owned_client),
        rx_state.rx_provenance.identity.?.destination_slot_addr,
    );
    try std.testing.expect(client_external_mode.parserSealValid(
        rx_state,
        &storage.owned_client.?.parser,
    ));
}

test "prepared Client transfer binds token destination profile and parser content" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    fixture.client.attach_instance_id = 77;
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
            try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
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
    try std.testing.expect(storage.committed_screen.isEmpty());
    try std.testing.expect(storage.owner_metadata.isEmpty());
    try std.testing.expect(storage.owner_resize == .none);
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(storage.owner_request_ids == null);
    try std.testing.expectError(error.NotActive, storage.requireActive());
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    fixture.client.deinit(); // moved-from cleanup must not close/free the destination owner.
    fixture.client.deinit(); // the tombstone itself is an idempotent no-op.
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
}

test "external pump refuses re-entrant teardown while a transaction owns the storage" {
    // Both in-flight windows must answer `busy`. Tearing down here would report `cleaned` to the
    // re-entrant caller while the still-running `initInPlace` goes on to publish `.adopting` over
    // the `.dead` it just wrote — a storage that two owners each believe they hold.
    var storage: ExternalPumpStorage = .{};
    storage.saved_self_addr = @intFromPtr(&storage);

    storage.lifecycle = .constructing;
    try std.testing.expectEqual(TeardownResult.transaction_busy, teardownForTest(&storage));
    try std.testing.expectEqual(StorageLifecycle.constructing, storage.lifecycle);

    storage.lifecycle = .normalizing;
    try std.testing.expectEqual(TeardownResult.transaction_busy, teardownForTest(&storage));
    try std.testing.expectEqual(StorageLifecycle.normalizing, storage.lifecycle);

    // A refusal is not a tombstone: the transaction still reaches its own terminal states.
    storage.lifecycle = .empty;
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&outer_storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
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

    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(TeardownResult.transaction_busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    const init_result = initTestStorage(&storage, &fixture.client, valid_evidence);
    try std.testing.expect(init_result == .initialized);
    const prepare_result = prepareAdoptionForTest(&storage);
    try std.testing.expect(prepare_result == .prepared_adopted);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .adopting);
    const prepared_valid = storage.prepared_adoption.validate(&storage);
    try std.testing.expect(prepared_valid);
    const authority = storage.prepared_adoption.source_decision.?.verdict.adopted.authority;
    try std.testing.expect(authority.role == .controller);
    try std.testing.expectEqual(
        @as(u64, 3),
        authority.generation.tracked,
    );
    const scalar_take = &storage.prepared_adoption.scalar_take;
    try std.testing.expect(scalar_take.validate(&storage));
    var moved_scalar_take = scalar_take.*;
    try std.testing.expect(!moved_scalar_take.validate(&storage));
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(storage.owner_request_ids == null);
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
    copied_outer.deinit(null);
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
    const client_allocator = storage.owned_client.?.allocator;
    const alternate_wrappers = try client_allocator.alloc(
        external_inbox_ledger.OwnedPayload,
        original_wrappers.len,
    );
    defer client_allocator.free(alternate_wrappers);
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
}

test "c3c-2b2 combined commit publishes adopted state only after every owner take" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.committed_screen.isEmpty());
    try std.testing.expect(storage.owner_metadata.isEmpty());
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(!storage.client_cleanup_take.isCommitted());

    var recorder = TestCommitRecorder{ .storage = &storage };
    try std.testing.expectEqual(
        CommitAdoptionResult.adopted,
        storage.commitAdoptionWithRecorder(TestCommitRecorder, &recorder),
    );
    try std.testing.expect(recorder.state_order_valid);
    try std.testing.expectEqual(@as(usize, 8), recorder.count);
    try std.testing.expectEqualSlices(
        CommitPhase,
        &.{
            .ledger_seed,
            .screen_destination,
            .metadata_destination,
            .scalar_destination,
            .client_cleanup_take,
            .prepared_tombstone,
            .semantic_active,
            .lifecycle_live,
        },
        &recorder.phases,
    );
    try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .active);
    try std.testing.expect(storage.semantic_state.active == .valid);
    try std.testing.expect(storage.committed_screen.isCommitted(&storage));
    try std.testing.expect(storage.owner_metadata.isCommitted());
    try std.testing.expect(storage.owner_authority == .current);
    try std.testing.expectEqual(
        OwnerAuthorityFlow.initial_fence,
        storage.owner_authority.current.flow,
    );
    try std.testing.expect(storage.owner_request_ids != null);
    try std.testing.expect(storage.client_cleanup_take.isCommitted());
    try std.testing.expectEqual(
        AdoptionLifecycle.committed_tombstone,
        storage.prepared_adoption.lifecycle,
    );
    try std.testing.expectEqual(
        CommitAdoptionResult.dead,
        storage.commitAdoption(),
    );
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        teardownForTest(&storage),
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
}

test "c3c-3a screen consume retires ledger payload without callback until aggregate teardown" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    inline for (.{ "first", "second" }) |text| {
        const payload = try fixture.client.allocator.dupe(u8, text);
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes += payload.len;
    }
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expectEqual(
        CommitAdoptionResult.adopted,
        storage.commitAdoption(),
    );
    try std.testing.expectEqual(@as(usize, 2), storage.committed_screen.retained_count);
    try std.testing.expectEqual(@as(usize, 2), storage.inbox_ledger.charged_items);

    const callbacks_before = probe.callback_count;
    active_external_operation_addr = 1;
    try std.testing.expectError(error.TransactionBusy, storage.consumeScreenRetained(1));
    active_external_operation_addr = 0;
    try std.testing.expectEqual(@as(usize, 2), storage.committed_screen.retained_count);
    try storage.consumeScreenRetained(1);
    try std.testing.expectEqual(callbacks_before, probe.callback_count);
    try std.testing.expectEqual(@as(usize, 1), storage.committed_screen.retained_count);
    try std.testing.expect(storage.committed_screen.released.isSet(1));
    try std.testing.expectEqual(@as(usize, 1), storage.inbox_ledger.charged_items);
    try std.testing.expectError(
        error.InvalidRetirement,
        storage.consumeScreenRetained(1),
    );
    try std.testing.expectEqual(callbacks_before, probe.callback_count);

    // Teardown while one token remains active and the other is retired proves that both
    // ownership classes enter the same frozen cleanup exactly once.
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(probe.callback_count > callbacks_before);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
}

test "d2b1 whole-turn lease snapshots inherited blockers once at final addresses" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);

    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
        padding: [64]u8 = [_]u8{0} ** 64,
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    try std.testing.expect(storage.validateWholeTurnLease(&lease));
    const generation = storage.operation_generation;
    try storage.snapshotInheritedRxBlockersUnderHeldLease(
        &lease,
        &turn_scratch.snapshot,
    );
    try std.testing.expect(turn_scratch.snapshot.committed_screen_pending);
    try std.testing.expect(turn_scratch.snapshot.hasBlocker());
    try std.testing.expect(
        try storage.validateAndConsumeInheritedSnapshot(
            &lease,
            &turn_scratch.snapshot,
        ),
    );
    try std.testing.expect(turn_scratch.snapshot.lifecycle == .consumed);
    try std.testing.expectError(
        error.InvalidSnapshot,
        storage.validateAndConsumeInheritedSnapshot(
            &lease,
            &turn_scratch.snapshot,
        ),
    );
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&lease),
    );
    try std.testing.expect(!storage.validateWholeTurnLease(&lease));
    try std.testing.expectEqual(generation, storage.operation_generation);
}

test "d2b1 whole-turn lease rejects copy alias stale snapshot and nested operation" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);

    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
        padding: [64]u8 = [_]u8{0} ** 64,
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    var copied_lease = lease;
    try std.testing.expect(!storage.validateWholeTurnLease(&copied_lease));
    try std.testing.expectEqual(
        WholeTurnReleaseResult.ignored_untrusted,
        storage.releaseWholeTurnLease(&copied_lease),
    );
    try std.testing.expect(storage.validateWholeTurnLease(&lease));
    var nested: ExternalWholeTurnLease = .{};
    try std.testing.expectError(
        error.TransactionBusy,
        storage.acquireWholeTurnLease(
            &nested,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        ),
    );
    try storage.snapshotInheritedRxBlockersUnderHeldLease(
        &lease,
        &turn_scratch.snapshot,
    );
    var copied_snapshot = turn_scratch.snapshot;
    try std.testing.expectError(
        error.InvalidSnapshot,
        storage.validateAndConsumeInheritedSnapshot(
            &lease,
            &copied_snapshot,
        ),
    );
    turn_scratch.snapshot.generation += 1;
    try std.testing.expectError(
        error.InvalidSnapshot,
        storage.validateAndConsumeInheritedSnapshot(
            &lease,
            &turn_scratch.snapshot,
        ),
    );
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&lease),
    );

    var aliased: ExternalWholeTurnLease = .{};
    try std.testing.expectError(
        error.InvalidDescriptor,
        storage.acquireWholeTurnLease(
            &aliased,
            @intFromPtr(&aliased),
            @sizeOf(ExternalWholeTurnLease),
        ),
    );
}

test "d2b1 canonical lease drift aborts terminal and releases the operation reservation" {
    const Drift = enum {
        digest,
        lifecycle,
        storage_addr,
        generation,
        saved_self_addr,
    };
    inline for (std.meta.tags(Drift)) |drift| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var turn_scratch = struct {
            snapshot: InheritedRxBlockerSnapshot = .{},
            padding: [64]u8 = [_]u8{0} ** 64,
        }{};
        var lease: ExternalWholeTurnLease = .{};
        try storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        );
        switch (drift) {
            .digest => lease.digest[0] ^= 1,
            .lifecycle => lease.lifecycle = .aborted,
            .storage_addr => lease.storage_addr +%= 1,
            .generation => lease.operation_generation +%= 1,
            .saved_self_addr => lease.saved_self_addr +%= 1,
        }
        try std.testing.expectEqual(
            WholeTurnReleaseResult.aborted_terminal,
            storage.releaseWholeTurnLease(&lease),
        );
        try std.testing.expect(storage.semantic_state == .terminal);
        var replacement: ExternalWholeTurnLease = .{};
        try std.testing.expectError(
            error.Terminal,
            storage.acquireWholeTurnLease(
                &replacement,
                @intFromPtr(&turn_scratch),
                @sizeOf(@TypeOf(turn_scratch)),
            ),
        );
        try std.testing.expectEqual(
            TeardownResult.cleaned,
            teardownForTest(&storage),
        );
    }
}

test "d2b1 intact lease release preserves a terminal latched during the turn" {
    inline for (.{
        client_pump.TerminalReason.revoked,
        client_pump.TerminalReason.protocol_error,
        client_pump.TerminalReason.deadline_exceeded,
    }) |reason| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var turn_scratch = struct {
            snapshot: InheritedRxBlockerSnapshot = .{},
        }{};
        var lease: ExternalWholeTurnLease = .{};
        try storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        );
        storage.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        try std.testing.expectEqual(
            WholeTurnReleaseResult.released,
            storage.releaseWholeTurnLease(&lease),
        );
        try std.testing.expect(lease.lifecycle == .released);
        try std.testing.expectEqual(
            reason,
            storage.semantic_state.terminal.reason,
        );
        try std.testing.expectEqual(
            TeardownResult.cleaned,
            teardownForTest(&storage),
        );
    }
}

test "d2b1 storage lifecycle drift cannot forge dead and bypass cleanup" {
    inline for (.{
        StorageLifecycle.empty,
        StorageLifecycle.tearing_down,
        StorageLifecycle.dead,
    }) |forged_lifecycle| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var turn_scratch = struct {
            snapshot: InheritedRxBlockerSnapshot = .{},
        }{};
        var lease: ExternalWholeTurnLease = .{};
        try storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        );
        storage.lifecycle = forged_lifecycle;
        try std.testing.expectEqual(
            WholeTurnReleaseResult.aborted_terminal,
            storage.releaseWholeTurnLease(&lease),
        );
        try std.testing.expect(lease.lifecycle == .aborted);
        try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
        try std.testing.expectEqual(
            client_pump.TerminalReason.invariant_failure,
            storage.semantic_state.terminal.reason,
        );
        try std.testing.expectEqual(
            TeardownResult.cleaned,
            teardownForTest(&storage),
        );
    }
}

test "d2b1 canonical storage address drift is restored for terminal cleanup" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    storage.saved_self_addr +%= 1;
    try std.testing.expectEqual(
        WholeTurnReleaseResult.aborted_terminal,
        storage.releaseWholeTurnLease(&lease),
    );
    try std.testing.expectEqual(@intFromPtr(&storage), storage.saved_self_addr);
    try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        storage.semantic_state.terminal.reason,
    );
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        teardownForTest(&storage),
    );
}

test "d2b1 semantic lifecycle drift aborts without losing cleanup authority" {
    inline for (.{
        client_pump.ExternalPumpState.constructing,
        client_pump.ExternalPumpState.adopting,
    }) |forged_semantic| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var turn_scratch = struct {
            snapshot: InheritedRxBlockerSnapshot = .{},
        }{};
        var lease: ExternalWholeTurnLease = .{};
        try storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        );
        storage.semantic_state = forged_semantic;
        try std.testing.expectEqual(
            WholeTurnReleaseResult.aborted_terminal,
            storage.releaseWholeTurnLease(&lease),
        );
        try std.testing.expect(lease.lifecycle == .aborted);
        try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
        try std.testing.expectEqual(
            client_pump.TerminalReason.invariant_failure,
            storage.semantic_state.terminal.reason,
        );
        try std.testing.expectEqual(
            TeardownResult.cleaned,
            teardownForTest(&storage),
        );
    }
}

test "d2b1 whole-turn snapshot must live inside sealed scratch" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var outside: InheritedRxBlockerSnapshot = .{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    try std.testing.expectError(
        error.InvalidDescriptor,
        storage.snapshotInheritedRxBlockersUnderHeldLease(
            &lease,
            &outside,
        ),
    );
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&lease),
    );
}

test "d2b1 moved storage cannot mint an inherited snapshot" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    const saved_addr = storage.saved_self_addr;
    storage.saved_self_addr +%= 1;
    try std.testing.expectError(
        error.TransactionBusy,
        storage.snapshotInheritedRxBlockersUnderHeldLease(
            &lease,
            &turn_scratch.snapshot,
        ),
    );
    storage.saved_self_addr = saved_addr;
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&lease),
    );
}

test "d2b1 prior-turn snapshot cannot replay under a fresh lease" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    var first_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var first_lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &first_lease,
        @intFromPtr(&first_scratch),
        @sizeOf(@TypeOf(first_scratch)),
    );
    try storage.snapshotInheritedRxBlockersUnderHeldLease(
        &first_lease,
        &first_scratch.snapshot,
    );
    var stale_snapshot = first_scratch.snapshot;
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&first_lease),
    );

    var second_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var second_lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &second_lease,
        @intFromPtr(&second_scratch),
        @sizeOf(@TypeOf(second_scratch)),
    );
    try std.testing.expectError(
        error.InvalidSnapshot,
        storage.validateAndConsumeInheritedSnapshot(
            &second_lease,
            &stale_snapshot,
        ),
    );
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&second_lease),
    );
}

test "d2b1 snapshot cannot cross storage authority" {
    var first_fixture = try TestClient.init();
    defer first_fixture.deinitPeer();
    var second_fixture = try TestClient.init();
    defer second_fixture.deinitPeer();
    var first: ExternalPumpStorage = .{};
    var second: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&first, &first_fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(
        initTestStorage(&second, &second_fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&first) == .prepared_adopted);
    try std.testing.expect(first.commitAdoption() == .adopted);
    try std.testing.expect(prepareAdoptionForTest(&second) == .prepared_adopted);
    try std.testing.expect(second.commitAdoption() == .adopted);
    defer _ = teardownForTest(&first);
    defer _ = teardownForTest(&second);

    var first_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var first_lease: ExternalWholeTurnLease = .{};
    try first.acquireWholeTurnLease(
        &first_lease,
        @intFromPtr(&first_scratch),
        @sizeOf(@TypeOf(first_scratch)),
    );
    try first.snapshotInheritedRxBlockersUnderHeldLease(
        &first_lease,
        &first_scratch.snapshot,
    );
    var foreign_snapshot = first_scratch.snapshot;
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        first.releaseWholeTurnLease(&first_lease),
    );

    var second_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var second_lease: ExternalWholeTurnLease = .{};
    try second.acquireWholeTurnLease(
        &second_lease,
        @intFromPtr(&second_scratch),
        @sizeOf(@TypeOf(second_scratch)),
    );
    try std.testing.expectError(
        error.InvalidSnapshot,
        second.validateAndConsumeInheritedSnapshot(
            &second_lease,
            &foreign_snapshot,
        ),
    );
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        second.releaseWholeTurnLease(&second_lease),
    );
}

test "d2b1 metadata owner drift invalidates O1 inherited summary" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try storage.acquireWholeTurnLease(
        &lease,
        @intFromPtr(&turn_scratch),
        @sizeOf(@TypeOf(turn_scratch)),
    );
    const saved_owner_addr = storage.owner_metadata.saved_self_addr;
    storage.owner_metadata.saved_self_addr +%= 1;
    try std.testing.expectError(
        error.InvalidSnapshot,
        storage.snapshotInheritedRxBlockersUnderHeldLease(
            &lease,
            &turn_scratch.snapshot,
        ),
    );
    storage.owner_metadata.saved_self_addr = saved_owner_addr;
    try std.testing.expectEqual(
        WholeTurnReleaseResult.released,
        storage.releaseWholeTurnLease(&lease),
    );
}

test "d2b1 summary scalar and digest drift reject snapshot without consuming it" {
    const Drift = enum {
        screen_count,
        screen_digest,
        metadata_digest,
    };
    inline for (std.meta.tags(Drift)) |drift| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        defer _ = teardownForTest(&storage);
        var turn_scratch = struct {
            snapshot: InheritedRxBlockerSnapshot = .{},
        }{};
        var lease: ExternalWholeTurnLease = .{};
        try storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        );
        const screen_summary = storage.screen_pending_summary;
        const metadata_summary = storage.metadata_pending_summary;
        switch (drift) {
            .screen_count => storage.screen_pending_summary.retained_count +%= 1,
            .screen_digest => storage.screen_pending_summary.digest[0] ^= 1,
            .metadata_digest => storage.metadata_pending_summary.digest[0] ^= 1,
        }
        try std.testing.expectError(
            error.InvalidSnapshot,
            storage.snapshotInheritedRxBlockersUnderHeldLease(
                &lease,
                &turn_scratch.snapshot,
            ),
        );
        storage.screen_pending_summary = screen_summary;
        storage.metadata_pending_summary = metadata_summary;
        try std.testing.expectEqual(
            WholeTurnReleaseResult.released,
            storage.releaseWholeTurnLease(&lease),
        );
    }
}

test "d2b1 generation exhaustion rejects whole-turn acquire before mutation" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    storage.operation_generation = std.math.maxInt(u64);
    var turn_scratch = struct {
        snapshot: InheritedRxBlockerSnapshot = .{},
    }{};
    var lease: ExternalWholeTurnLease = .{};
    try std.testing.expectError(
        error.GenerationExhausted,
        storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(&turn_scratch),
            @sizeOf(@TypeOf(turn_scratch)),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), active_external_operation_addr);
    try std.testing.expectEqual(@as(usize, 0), active_external_lease_addr);
    try std.testing.expect(std.meta.eql(lease, ExternalWholeTurnLease{}));
    storage.operation_generation -= 1;
}

test "d2b1 pending summary reseals after exact screen retirement" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    const generation = storage.screen_pending_summary.generation;
    try storage.consumeScreenRetained(0);
    try std.testing.expect(storage.screenPendingSummaryValid());
    try std.testing.expectEqual(
        generation + 1,
        storage.screen_pending_summary.generation,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        storage.screen_pending_summary.retained_count,
    );
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        teardownForTest(&storage),
    );
    try std.testing.expect(storage.screen_pending_summary.lifecycle == .tombstone);
    try std.testing.expect(storage.metadata_pending_summary.lifecycle == .tombstone);
}

test "d2b1 whole-turn lease rejects committed owner backing as scratch" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    defer _ = teardownForTest(&storage);
    const tokens = storage.committed_screen.primary.transfer.tokens;
    var lease: ExternalWholeTurnLease = .{};
    try std.testing.expectError(
        error.InvalidDescriptor,
        storage.acquireWholeTurnLease(
            &lease,
            @intFromPtr(tokens.ptr),
            tokens.len * @sizeOf(external_inbox_ledger.Token),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), active_external_operation_addr);
}

test "d2b1 quarantine tombstones pending summaries before abandoning cleanup" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var storage: ExternalPumpStorage = .{};
    storage.saved_self_addr = @intFromPtr(&storage);
    storage.lifecycle = .live;
    storage.semantic_state = .{ .active = .valid };
    storage.screen_pending_summary.lifecycle = .bound;
    storage.metadata_pending_summary.lifecycle = .bound;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(
        &cleanup_scratch,
    ));
    active_external_operation_addr = @intFromPtr(&storage);
    try std.testing.expectEqual(
        TeardownResult.quarantined,
        storage.quarantineOwnerTeardown(&cleanup_scratch, true),
    );
    active_external_operation_addr = 0;
    try std.testing.expect(storage.screen_pending_summary.lifecycle == .tombstone);
    try std.testing.expect(storage.metadata_pending_summary.lifecycle == .tombstone);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
}

test "c3c-3a screen bitmap and ledger retirement drift fail closed in both directions" {
    const Drift = enum { bitmap_only, ledger_only };
    inline for (std.meta.tags(Drift)) |drift| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        const payload = try fixture.client.allocator.dupe(u8, "screen");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes = payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expectEqual(
            CommitAdoptionResult.adopted,
            storage.commitAdoption(),
        );
        switch (drift) {
            .bitmap_only => {
                storage.committed_screen.released.set(0);
                storage.committed_screen.retained_count -= 1;
            },
            .ledger_only => {
                try storage.consumeScreenRetained(0);
                storage.committed_screen.released.unset(0);
                storage.committed_screen.retained_count += 1;
            },
        }
        try std.testing.expectEqual(
            TeardownResult.cleaned_with_invariant,
            teardownForTest(&storage),
        );
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-2b2 final permit drift terminalizes before ledger mutation" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    const before = storage.inbox_ledger.accountingView();
    storage.prepared_adoption.final_seal.operation_generation +%= 1;

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    const after = storage.inbox_ledger.accountingView();
    try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
    try std.testing.expectEqual(@as(usize, 0), after.charged_items);
    try std.testing.expectEqual(@as(usize, 0), after.charged_bytes);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .terminal);
    try std.testing.expectEqual(
        CommitAdoptionResult.dead,
        storage.commitAdoption(),
    );
}

test "c3c-2b2 adopted commit permit is final-address bound and linear" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    var permit: AdoptedCommitPermit = .{};
    try std.testing.expect(storage.mintAdoptedCommitPermit(&permit));
    try std.testing.expect(permit.validate(&storage));
    var moved = permit;
    try std.testing.expect(!moved.validate(&storage));
    permit.consumed = true;
    try std.testing.expect(!permit.validate(&storage));
}

test "c3c-2b2 nonempty post-ledger suffix defers allocator callback until publication" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    const callbacks_before_commit = probe.callback_count;
    var recorder = TestCommitRecorder{
        .storage = &storage,
        .callback_counter = &probe.callback_count,
    };
    try std.testing.expectEqual(
        CommitAdoptionResult.adopted,
        storage.commitAdoptionWithRecorder(TestCommitRecorder, &recorder),
    );
    try std.testing.expect(recorder.state_order_valid);
    try std.testing.expect(recorder.callbacks_after_ledger >=
        callbacks_before_commit);
    try std.testing.expectEqual(
        recorder.callbacks_after_ledger + 1,
        probe.callback_count,
    );
    try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
}

test "c3c-2b2 final permit rejects bound address and leaf drift before ledger mutation" {
    const Scenario = enum {
        storage_addr,
        plan_addr,
        client_addr,
        ledger_addr,
        evidence_addr,
        client_cleanup_take_addr,
        screen_take_addr,
        metadata_take_addr,
        scalar_take_addr,
        committed_screen_addr,
        screen_pending_summary_addr,
        owner_metadata_addr,
        metadata_pending_summary_addr,
        owner_resize_addr,
        owner_authority_addr,
        owner_request_ids_addr,
        committed_screen_lifecycle,
        owner_metadata_lifecycle,
        owner_resize_lifecycle,
        owner_authority_lifecycle,
        owner_request_ids_lifecycle,
        screen_take,
        metadata_take,
        client_take,
        scalar_take,
    };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        const before = storage.inbox_ledger.accountingView();
        switch (scenario) {
            .storage_addr => storage.prepared_adoption.final_seal.storage_addr +%= 1,
            .plan_addr => storage.prepared_adoption.final_seal.plan_addr +%= 1,
            .client_addr => storage.prepared_adoption.final_seal.client_addr +%= 1,
            .ledger_addr => storage.prepared_adoption.final_seal.ledger_addr +%= 1,
            .evidence_addr => storage.prepared_adoption.final_seal.evidence_addr +%= 1,
            .client_cleanup_take_addr => storage.prepared_adoption.final_seal
                .client_cleanup_take_addr +%= 1,
            .screen_take_addr => storage.prepared_adoption.final_seal.screen_take_addr +%= 1,
            .metadata_take_addr => storage.prepared_adoption.final_seal.metadata_take_addr +%= 1,
            .scalar_take_addr => storage.prepared_adoption.final_seal.scalar_take_addr +%= 1,
            .committed_screen_addr => storage.prepared_adoption.final_seal
                .committed_screen_addr +%= 1,
            .screen_pending_summary_addr => storage.prepared_adoption.final_seal
                .screen_pending_summary_addr +%= 1,
            .owner_metadata_addr => storage.prepared_adoption.final_seal.owner_metadata_addr +%= 1,
            .metadata_pending_summary_addr => storage.prepared_adoption.final_seal
                .metadata_pending_summary_addr +%= 1,
            .owner_resize_addr => storage.prepared_adoption.final_seal.owner_resize_addr +%= 1,
            .owner_authority_addr => storage.prepared_adoption.final_seal
                .owner_authority_addr +%= 1,
            .owner_request_ids_addr => storage.prepared_adoption.final_seal
                .owner_request_ids_addr +%= 1,
            .committed_screen_lifecycle => storage.committed_screen.lifecycle = .cleaned_tombstone,
            .owner_metadata_lifecycle => storage.owner_metadata.lifecycle = .cleaned_tombstone,
            .owner_resize_lifecycle => {
                bindOwnerResize(&storage, .{
                    .runtime_id = valid_evidence.runtime_id,
                    .cols = 80,
                    .rows = 24,
                    .resize_generation = 1,
                });
                storage.owner_resize.current.seal.pending = false;
            },
            .owner_authority_lifecycle => storage.owner_authority = .{ .current = .{
                .role = .controller,
                .generation = .{ .tracked = 3 },
                .flow = .initial_fence,
            } },
            .owner_request_ids_lifecycle => storage.owner_request_ids = .{ .available = 1 },
            .screen_take => storage.prepared_adoption.screen_take.target_stream +%= 1,
            .metadata_take => storage.prepared_adoption.metadata_take.lifecycle =
                .aborted_tombstone,
            .client_take => storage.client_cleanup_take.inventory_cleanup_seal[0] ^= 1,
            .scalar_take => storage.prepared_adoption.scalar_take.request_ids = .max_consumed,
        }
        try std.testing.expectEqual(
            CommitAdoptionResult.terminal_latched,
            storage.commitAdoption(),
        );
        const after = storage.inbox_ledger.accountingView();
        try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
        try std.testing.expectEqual(@as(usize, 0), after.charged_items);
        try std.testing.expectEqual(@as(usize, 0), after.charged_bytes);
        try std.testing.expect(storage.semantic_state == .terminal);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-2b2 digest equality cannot authorize scalar semantic drift" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    const before = storage.inbox_ledger.accountingView();
    storage.prepared_adoption.scalar_take.request_ids = .max_consumed;
    // Re-seal the attacker-controlled aggregate transcript. The leaf validator, not digest
    // equality, remains the semantic authority.
    storage.prepared_adoption.final_seal = storage.expectedFinalSeal();

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    const after = storage.inbox_ledger.accountingView();
    try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
    try std.testing.expectEqual(@as(usize, 0), after.charged_items);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
}

test "c3c-2b2 cross-owner screen payload alias terminalizes without double free" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    try std.testing.expect(!crossOwnerQuarantineStatus().latched);
    var fixture = try TestClient.initWithAllocator(std.heap.page_allocator);
    defer fixture.deinitPeer();
    const source_payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = source_payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = source_payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);

    const transfer = storage.prepared_adoption.backlog.transfer.?;
    const abandoned_payload = transfer.copies[0].bytes;
    var abandoned_inventory = storage.prepared_adoption.backlog.inventory.?;
    transfer.copies[0].bytes = storage.owned_client.?.pending_batches.items[0].bytes;
    transfer.copies[0].view = storage.owned_client.?.pending_batches.items[0].bytes;
    transfer.wrappers[0].allocation_ptr =
        storage.owned_client.?.pending_batches.items[0].bytes.ptr;
    transfer.wrappers[0].logical_len =
        storage.owned_client.?.pending_batches.items[0].bytes.len;
    // Even an attacker that recomputes the aggregate transcript cannot turn overlapping owner
    // graphs into a valid permit; the address proof is an independent leaf authority.
    storage.prepared_adoption.final_seal = storage.expectedFinalSeal();
    const before = storage.inbox_ledger.accountingView();

    try std.testing.expect(!storage.validateFinalSeal());
    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    const after = storage.inbox_ledger.accountingView();
    try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
    try std.testing.expectEqual(@as(usize, 0), after.charged_items);
    try std.testing.expectEqual(@as(usize, 0), after.charged_bytes);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .terminal);
    const quarantine = crossOwnerQuarantineStatus();
    try std.testing.expect(quarantine.latched);
    try std.testing.expectEqual(@as(u64, 1), quarantine.event_count);
    try std.testing.expectEqual(
        max_cross_owner_quarantine_bytes,
        quarantine.leaked_bytes_upper_bound,
    );

    var rejected_fixture = try TestClient.init();
    defer rejected_fixture.deinitPeer();
    defer rejected_fixture.client.deinit();
    var rejected_storage: ExternalPumpStorage = .{};
    const rejected = initTestStorage(
        &rejected_storage,
        &rejected_fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(
        InitFailureReason.process_quarantined,
        rejected.reason,
    );
    try std.testing.expectEqual(
        SourceDisposition.preserved,
        rejected.source_disposition,
    );

    // The corruption path deliberately quarantines untrusted prepared owners. Reclaim the
    // fixture's known-good pre-attack allocations explicitly; the aliased Client payload was
    // reclaimed exactly once by the canonical Client owner.
    std.heap.page_allocator.free(abandoned_payload);
    std.heap.page_allocator.free(transfer.tokens);
    std.heap.page_allocator.free(transfer.wrappers);
    std.heap.page_allocator.free(transfer.copies);
    abandoned_inventory.deinit();
}

test "c3c-2b2 invalid outer screen descriptors fail before nested dereference" {
    const Scenario = enum { foreign_pointer, overflowed_mirror_len };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        const source_payload = try fixture.client.allocator.dupe(u8, "screen");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = source_payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes = source_payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        const before = storage.inbox_ledger.accountingView();
        const transfer = &storage.prepared_adoption.backlog.transfer.?;
        switch (scenario) {
            .foreign_pointer => {
                transfer.copies = @as(
                    [*]client_mod.ExternalScreenCopy,
                    @ptrFromInt(@alignOf(client_mod.ExternalScreenCopy)),
                )[0..transfer.copies.len];
            },
            .overflowed_mirror_len => {
                transfer.copies_len = std.math.maxInt(usize);
            },
        }

        try std.testing.expectEqual(
            CommitAdoptionResult.terminal_latched,
            storage.commitAdoption(),
        );
        const after = storage.inbox_ledger.accountingView();
        try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
        try std.testing.expectEqual(@as(usize, 0), after.charged_items);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-2b2 screen cleanup ignores correlated foreign descriptor mirrors" {
    const Scenario = enum {
        primary_copies,
        primary_wrappers,
        primary_tokens,
        independent_copies,
        independent_wrappers,
        independent_tokens,
        independent_copies_and_seal,
        independent_wrappers_and_seal,
        independent_tokens_and_seal,
    };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        const source_payload = try fixture.client.allocator.dupe(u8, "screen");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = source_payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes = source_payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        const primary = &storage.prepared_adoption.backlog.transfer.?;
        const independent = &storage.prepared_adoption.backlog.cleanup_transfer.?;
        switch (scenario) {
            .primary_copies => {
                const foreign = @as(
                    [*]client_mod.ExternalScreenCopy,
                    @ptrFromInt(@alignOf(client_mod.ExternalScreenCopy)),
                )[0..primary.copies.len];
                primary.copies = foreign;
                primary.cleanup_copies = foreign;
            },
            .primary_wrappers => {
                const foreign = @as(
                    [*]external_inbox_ledger.OwnedPayload,
                    @ptrFromInt(@alignOf(external_inbox_ledger.OwnedPayload)),
                )[0..primary.wrappers.len];
                primary.wrappers = foreign;
                primary.cleanup_wrappers = foreign;
            },
            .primary_tokens => {
                const foreign = @as(
                    [*]external_inbox_ledger.Token,
                    @ptrFromInt(@alignOf(external_inbox_ledger.Token)),
                )[0..primary.tokens.len];
                primary.tokens = foreign;
                primary.cleanup_tokens = foreign;
            },
            .independent_copies => {
                const foreign = @as(
                    [*]client_mod.ExternalScreenCopy,
                    @ptrFromInt(@alignOf(client_mod.ExternalScreenCopy)),
                )[0..independent.copies.len];
                independent.copies = foreign;
                independent.cleanup_copies = foreign;
            },
            .independent_wrappers => {
                const foreign = @as(
                    [*]external_inbox_ledger.OwnedPayload,
                    @ptrFromInt(@alignOf(external_inbox_ledger.OwnedPayload)),
                )[0..independent.wrappers.len];
                independent.wrappers = foreign;
                independent.cleanup_wrappers = foreign;
            },
            .independent_tokens => {
                const foreign = @as(
                    [*]external_inbox_ledger.Token,
                    @ptrFromInt(@alignOf(external_inbox_ledger.Token)),
                )[0..independent.tokens.len];
                independent.tokens = foreign;
                independent.cleanup_tokens = foreign;
            },
            .independent_copies_and_seal => {
                const foreign = @as(
                    [*]client_mod.ExternalScreenCopy,
                    @ptrFromInt(@alignOf(client_mod.ExternalScreenCopy)),
                )[0..independent.copies.len];
                independent.copies = foreign;
                independent.cleanup_copies = foreign;
                independent.copies_addr = @intFromPtr(foreign.ptr);
            },
            .independent_wrappers_and_seal => {
                const foreign = @as(
                    [*]external_inbox_ledger.OwnedPayload,
                    @ptrFromInt(@alignOf(external_inbox_ledger.OwnedPayload)),
                )[0..independent.wrappers.len];
                independent.wrappers = foreign;
                independent.cleanup_wrappers = foreign;
                independent.wrappers_addr = @intFromPtr(foreign.ptr);
            },
            .independent_tokens_and_seal => {
                const foreign = @as(
                    [*]external_inbox_ledger.Token,
                    @ptrFromInt(@alignOf(external_inbox_ledger.Token)),
                )[0..independent.tokens.len];
                independent.tokens = foreign;
                independent.cleanup_tokens = foreign;
                independent.tokens_addr = @intFromPtr(foreign.ptr);
            },
        }
        const before = storage.inbox_ledger.accountingView();

        try std.testing.expectEqual(
            CommitAdoptionResult.terminal_latched,
            storage.commitAdoption(),
        );
        const after = storage.inbox_ledger.accountingView();
        try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
        try std.testing.expectEqual(@as(usize, 0), after.charged_items);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-2b2 screen cleanup requires majority allocator authority" {
    const Scenario = enum {
        primary,
        cleanup,
        both,
        both_and_seal,
        take,
    };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        const source_payload = try fixture.client.allocator.dupe(u8, "screen");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = source_payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes = source_payload.len;
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        const backlog = &storage.prepared_adoption.backlog;
        switch (scenario) {
            .primary => backlog.allocator = std.heap.page_allocator,
            .cleanup => backlog.cleanup_allocator = std.heap.page_allocator,
            .both => {
                backlog.allocator = std.heap.page_allocator;
                backlog.cleanup_allocator = std.heap.page_allocator;
            },
            .both_and_seal => {
                backlog.allocator = std.heap.page_allocator;
                backlog.cleanup_allocator = std.heap.page_allocator;
                backlog.allocator_ptr_addr =
                    @intFromPtr(std.heap.page_allocator.ptr);
                backlog.allocator_vtable_addr =
                    @intFromPtr(std.heap.page_allocator.vtable);
            },
            .take => {
                storage.prepared_adoption.screen_take.allocator =
                    std.heap.page_allocator;
            },
        }
        const before = storage.inbox_ledger.accountingView();

        try std.testing.expectEqual(
            CommitAdoptionResult.terminal_latched,
            storage.commitAdoption(),
        );
        const after = storage.inbox_ledger.accountingView();
        try std.testing.expectEqual(before.mutation_epoch, after.mutation_epoch);
        try std.testing.expectEqual(@as(usize, 0), after.charged_items);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-2b2 ledger precondition drift terminalizes before ledger call and publication" {
    inline for (std.meta.tags(LedgerPreconditionDriftRecorder.Scenario)) |scenario| {
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        var recorder = LedgerPreconditionDriftRecorder{ .scenario = scenario };
        try std.testing.expectEqual(
            CommitAdoptionResult.terminal_latched,
            storage.commitAdoptionWithRecorder(
                LedgerPreconditionDriftRecorder,
                &recorder,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), recorder.phase_count);
        const injected = recorder.injected.?;
        const after = storage.inbox_ledger.accountingView();
        try std.testing.expectEqual(injected.mutation_epoch, after.mutation_epoch);
        try std.testing.expectEqual(injected.charged_items, after.charged_items);
        try std.testing.expectEqual(injected.charged_bytes, after.charged_bytes);
        try std.testing.expect(storage.committed_screen.isEmpty());
        try std.testing.expect(storage.owner_metadata.isEmpty());
        try std.testing.expect(storage.owner_authority == .empty);
        try std.testing.expect(!storage.client_cleanup_take.isCommitted());
        try std.testing.expect(storage.semantic_state == .terminal);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expectEqual(
            CommitAdoptionResult.dead,
            storage.commitAdoption(),
        );
    }
}

test "c3c-2b2 terminal cleanup rejects allocator callback reentry" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    probe.storage = &storage;
    probe.mode = .commit_cleanup_reentry;
    probe.fired = false;
    storage.prepared_adoption.final_seal.operation_generation +%= 1;

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(
        CommitAdoptionResult.transaction_busy,
        probe.nested_commit.?,
    );
    try std.testing.expectEqual(TeardownResult.transaction_busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        CommitAdoptionResult.dead,
        storage.commitAdoption(),
    );
    try std.testing.expectEqual(
        TeardownResult.already_dead,
        teardownForTest(&storage),
    );
}

test "c3c-2b2 cleanup freezes screen authority before first allocator callback" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client, event_json);
    const screen = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = screen,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = screen.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    probe.storage = &storage;
    probe.mode = .cleanup_authority_drift;
    probe.fired = false;
    storage.prepared_adoption.final_seal.operation_generation +%= 1;

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        CommitAdoptionResult.dead,
        storage.commitAdoption(),
    );
}

test "c3c-2b2 cleanup deep freezes nested screen descriptors before allocator callback" {
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client, event_json);
    const screen = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = screen,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = screen.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    probe.storage = &storage;
    probe.screen_copies = storage.prepared_adoption.backlog.transfer.?.copies;
    probe.screen_wrappers = storage.prepared_adoption.backlog.transfer.?.wrappers;
    probe.mode = .cleanup_nested_descriptor_drift;
    probe.fired = false;
    storage.prepared_adoption.final_seal.operation_generation +%= 1;

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        CommitAdoptionResult.dead,
        storage.commitAdoption(),
    );
}

test "c3c-2b2 corrupted committed cleanup tag fails closed without generic deinit panic" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    storage.client_cleanup_take.lifecycle = .committed;
    storage.client_cleanup_take.saved_self_address +%= 1;

    try std.testing.expectEqual(
        CommitAdoptionResult.terminal_latched,
        storage.commitAdoption(),
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(
        storage.client_cleanup_take.requiresTypedCleanup(),
    );
    try std.testing.expectEqual(
        TeardownResult.already_dead,
        teardownForTest(&storage),
    );
}

test "c3c-2b2 prepared scalar take aborts on ordinary teardown" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.prepared_adoption.scalar_take.validate(&storage));
    try std.testing.expect(storage.owner_resize == .none);
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(storage.owner_request_ids == null);

    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(storage.owner_resize == .none);
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(storage.owner_request_ids == null);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
}

test "c3c-2b2 prepared scalar take derives pending resize from the adopted decision" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    );
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    const take = &storage.prepared_adoption.scalar_take;
    const resize = take.resize orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 132), resize.cols);
    try std.testing.expectEqual(@as(u16, 43), resize.rows);
    try std.testing.expectEqual(@as(u64, 9), resize.resize_generation);
    try std.testing.expect(storage.owner_resize == .none);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    try std.testing.expect(storage.owner_resize == .current);
    try std.testing.expect(ownerResizeValid(&storage));
    try std.testing.expect(storage.owner_resize.current.pending);
    try std.testing.expectEqual(@as(u16, 132), storage.owner_resize.current.event.cols);
}

test "c3c-3b adopted owner seals incarnation and metadata query fails closed" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    try std.testing.expect(ownerIncarnationValid(&storage));
    try std.testing.expect(storage.owner_event_projection_generation == 0);
    try std.testing.expect(storage.metadataState() == .state);

    active_external_operation_addr = @intFromPtr(&storage);
    try std.testing.expect(storage.metadataState() == .transaction_busy);
    active_external_operation_addr = 0;

    const metadata_addr = storage.owner_metadata.saved_self_addr;
    storage.owner_metadata.saved_self_addr +%= 1;
    try std.testing.expect(storage.metadataState() == .invalid_owner);
    storage.owner_metadata.saved_self_addr = metadata_addr;
}

test "c3c-3b resize projection retries then clears only the matching pending baseline" {
    const ProjectionProbe = struct {
        calls: usize = 0,
        decision: ProjectionDecision = .retry_preserved,
        last_resize: ?resize_wire.Event = null,

        fn project(raw: *anyopaque, view: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.last_resize = switch (view) {
                .resized => |event| event,
                .metadata => null,
            };
            return self.decision;
        }
    };

    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    );
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);

    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);

    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = ProjectionProbe{};
    const projector = OwnerEventProjector{
        .context = &probe,
        .context_len = @sizeOf(ProjectionProbe),
        .project = ProjectionProbe.project,
    };
    try std.testing.expect(
        storage.projectOwnerEventInternal(projector, &cleanup_scratch) ==
            .retry_preserved,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(storage.owner_resize.current.pending);
    try std.testing.expectEqual(@as(u64, 1), storage.owner_event_projection_generation);

    probe.decision = .applied;
    try std.testing.expect(
        storage.projectOwnerEventInternal(projector, &cleanup_scratch) ==
            .applied,
    );
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(!storage.owner_resize.current.pending);
    try std.testing.expect(ownerResizeValid(&storage));
    try std.testing.expectEqual(@as(u64, 2), storage.owner_event_projection_generation);
    try std.testing.expect(storage.owner_metadata.metadata.current.pending);
    try std.testing.expect(
        storage.projectOwnerEventInternal(projector, &cleanup_scratch) ==
            .applied,
    );
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    try std.testing.expect(probe.last_resize == null);
    try std.testing.expect(!storage.owner_metadata.metadata.current.pending);
    try std.testing.expect(
        storage.projectOwnerEventInternal(projector, &cleanup_scratch) == .none,
    );
}

test "c3c-3b metadata projection borrows logical DTO only for the callback" {
    const ProjectionProbe = struct {
        calls: usize = 0,
        saw_revision: u64 = 0,
        saw_cwd: bool = false,

        fn project(raw: *anyopaque, view: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            switch (view) {
                .resized => {},
                .metadata => |metadata| {
                    self.saw_revision = metadata.revision;
                    self.saw_cwd = std.mem.eql(u8, metadata.cwd, "/repo");
                },
            }
            return .applied;
        }
    };
    const event_json =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client, event_json);
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = ProjectionProbe{};
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(ProjectionProbe),
            .project = ProjectionProbe.project,
        }, &cleanup_scratch) == .applied,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u64, 2), probe.saw_revision);
    try std.testing.expect(probe.saw_cwd);
    try std.testing.expect(!storage.owner_metadata.metadata.current.pending);
    const summary = storage.owner_metadata.metadataStateSummary(&storage).?;
    try std.testing.expect(summary == .current);
    try std.testing.expect(!summary.current.pending);
}

test "c3c-3b projection generation exhaustion closes the valid owner under the held lease" {
    const Probe = struct {
        calls: usize = 0,
        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .applied;
        }
    };
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    storage.owner_event_projection_generation = std.math.maxInt(u64) - 1;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{};
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .applied,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        storage.owner_event_projection_generation,
    );
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(storage.owner_incarnation == 0);
    try std.testing.expect(cleanup_scratch.isReady());
    const accounting = storage.inbox_ledger.accountingView();
    try std.testing.expect(accounting.valid);
    try std.testing.expectEqual(@as(usize, 0), accounting.charged_bytes);
    try std.testing.expectEqual(@as(usize, 0), accounting.charged_items);
    try std.testing.expectEqual(@as(usize, 0), accounting.retired_bytes);
    try std.testing.expectEqual(@as(usize, 0), accounting.retired_items);
}

test "c3c-3b raw initial fence drift cannot authorize a projection" {
    const Probe = struct {
        calls: usize = 0,
        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .applied;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    storage.owner_authority.current.flow = .clear;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{};
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    if (storage.owned_client) |*owned| owned.deinit();
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b projector context cannot alias storage authority" {
    const Probe = struct {
        var calls: usize = 0;
        fn project(_: *anyopaque, _: OwnerEventView) ProjectionDecision {
            calls += 1;
            return .applied;
        }
    };
    Probe.calls = 0;
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &storage,
            .context_len = @sizeOf(ExternalPumpStorage),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(@as(usize, 0), Probe.calls);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(cleanup_scratch.isReady());
}

test "c3c-3b projector context rejects partial storage overlap and range overflow" {
    const Probe = struct {
        var calls: usize = 0;
        fn project(_: *anyopaque, _: OwnerEventView) ProjectionDecision {
            calls += 1;
            return .applied;
        }
    };
    const ContextCase = enum { partial_storage, overflow };
    inline for (std.enums.values(ContextCase)) |context_case| {
        Probe.calls = 0;
        var fixture = try TestClient.init();
        defer fixture.deinitPeer();
        try appendTestEvent(&fixture.client,
            \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
        );
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var fence: projection_test.PreparedInitialFenceClear = .{};
        try std.testing.expect(projection_test.prepare(&storage, &fence));
        try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
        var cleanup_scratch: ExternalPumpCleanupScratch = .{};
        try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
        const context_addr: usize = switch (context_case) {
            .partial_storage => @intFromPtr(&storage) + 1,
            .overflow => std.math.maxInt(usize) - 7,
        };
        try std.testing.expect(
            storage.projectOwnerEventInternal(.{
                .context = @ptrFromInt(context_addr),
                .context_len = 16,
                .project = Probe.project,
            }, &cleanup_scratch) == .terminal_latched,
        );
        try std.testing.expectEqual(@as(usize, 0), Probe.calls);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expect(cleanup_scratch.isReady());
    }
}

test "c3c-3b projection rejects exact and partial scratch storage alias before header read" {
    const Probe = struct {
        var calls: usize = 0;
        fn project(_: *anyopaque, _: OwnerEventView) ProjectionDecision {
            calls += 1;
            return .applied;
        }
    };
    inline for (.{ @as(usize, 0), @alignOf(ExternalPumpCleanupScratch) }) |offset| {
        resetCrossOwnerQuarantineForTest();
        defer resetCrossOwnerQuarantineForTest();
        Probe.calls = 0;
        var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
        defer fixture.deinitPeer();
        try appendTestEvent(&fixture.client,
            \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
        );
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var fence: projection_test.PreparedInitialFenceClear = .{};
        try std.testing.expect(projection_test.prepare(&storage, &fence));
        try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
        var context: u8 = 0;
        const aliased_scratch: *ExternalPumpCleanupScratch =
            @ptrFromInt(@intFromPtr(&storage) + offset);
        try std.testing.expect(
            storage.projectOwnerEventInternal(.{
                .context = &context,
                .context_len = @sizeOf(u8),
                .project = Probe.project,
            }, aliased_scratch) == .terminal_latched,
        );
        try std.testing.expectEqual(@as(usize, 0), Probe.calls);
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expect(crossOwnerQuarantineStatus().latched);
        if (storage.owned_client) |*owned| owned.deinit();
        storage.owned_client = null;
        if (storage.owned_evidence) |*owned| owned.deinit();
        storage.owned_evidence = null;
    }
}

test "c3c-3b projection callback reentry stays transaction busy" {
    const Probe = struct {
        storage: *ExternalPumpStorage,
        scratch: *ExternalPumpCleanupScratch,
        metadata_result: ?std.meta.Tag(MetadataStateResult) = null,
        teardown_result: ?TeardownResult = null,
        projection_result: ?ProjectOwnerEventResult = null,

        fn nestedProject(_: *anyopaque, _: OwnerEventView) ProjectionDecision {
            return .applied;
        }

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.metadata_result = std.meta.activeTag(self.storage.metadataState());
            self.teardown_result = self.storage.teardown(self.scratch);
            self.projection_result = self.storage.projectOwnerEventInternal(.{
                .context = self,
                .context_len = @sizeOf(@This()),
                .project = nestedProject,
            }, self.scratch);
            return .retry_preserved;
        }
    };
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage, .scratch = &cleanup_scratch };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .retry_preserved,
    );
    try std.testing.expect(
        probe.metadata_result.? == .transaction_busy,
    );
    try std.testing.expect(probe.teardown_result.? == .transaction_busy);
    try std.testing.expect(probe.projection_result.? == .transaction_busy);
    try std.testing.expect(storage.owner_resize.current.pending);
}

test "c3c-3b unread scratch work arrays are overwritten before teardown reads them" {
    const Probe = struct {
        scratch: *ExternalPumpCleanupScratch,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            @memset(std.mem.asBytes(&self.scratch.range_scratch.source), 0xa5);
            @memset(std.mem.asBytes(&self.scratch.client.batches), 0x5a);
            @memset(std.mem.asBytes(&self.scratch.client.stream), 0x5a);
            @memset(std.mem.asBytes(&self.scratch.client.events), 0x5a);
            return .applied;
        }
    };
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .scratch = &cleanup_scratch };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .applied,
    );
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        storage.teardown(&cleanup_scratch),
    );
    try std.testing.expect(cleanup_scratch.isReady());
}

test "c3c-3b meaningful scratch header drift is quarantined without reading work arrays" {
    const Probe = struct {
        scratch: *ExternalPumpCleanupScratch,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.scratch.saved_self_addr +%= 1;
            @memset(std.mem.asBytes(&self.scratch.client.batches), 0xa5);
            return .applied;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .scratch = &cleanup_scratch };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    try std.testing.expect(
        cleanup_scratch.saved_self_addr != @intFromPtr(&cleanup_scratch),
    );
    if (storage.owned_client) |*owned| owned.deinit();
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b scratch and forged owner drift quarantines before owner dereference" {
    const Probe = struct {
        storage: *ExternalPumpStorage,
        scratch: *ExternalPumpCleanupScratch,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.scratch.saved_self_addr +%= 1;
            const client = if (self.storage.owned_client) |*owned|
                owned
            else
                unreachable;
            client.pending_batches.items.ptr = @ptrFromInt(0x1000);
            client.pending_batches.items.len = 1;
            client.pending_batches.capacity = 1;
            return .applied;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage, .scratch = &cleanup_scratch };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    try std.testing.expect(
        cleanup_scratch.saved_self_addr != @intFromPtr(&cleanup_scratch),
    );
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b projection quarantines deep screen token drift for either callback decision" {
    const Probe = struct {
        storage: *ExternalPumpStorage,
        decision: ProjectionDecision,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const tokens = self.storage.committed_screen.primary.transfer.tokens;
            tokens[0].generation +%= 1;
            return self.decision;
        }
    };
    inline for (.{ ProjectionDecision.applied, ProjectionDecision.retry_preserved }) |decision| {
        resetCrossOwnerQuarantineForTest();
        defer resetCrossOwnerQuarantineForTest();
        var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
        defer fixture.deinitPeer();
        const payload = try fixture.client.allocator.dupe(u8, "screen");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes = payload.len;
        try appendTestEvent(&fixture.client,
            \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
        );
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        try std.testing.expect(storage.committed_screen.primary.transfer.tokens.len != 0);
        var fence: projection_test.PreparedInitialFenceClear = .{};
        try std.testing.expect(projection_test.prepare(&storage, &fence));
        try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
        var cleanup_scratch: ExternalPumpCleanupScratch = .{};
        try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
        var probe = Probe{ .storage = &storage, .decision = decision };
        try std.testing.expect(
            storage.projectOwnerEventInternal(.{
                .context = &probe,
                .context_len = @sizeOf(Probe),
                .project = Probe.project,
            }, &cleanup_scratch) == .terminal_latched,
        );
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expect(crossOwnerQuarantineStatus().latched);
        if (storage.owned_client) |*owned| owned.deinit();
        storage.owned_client = null;
        if (storage.owned_evidence) |*owned| owned.deinit();
        storage.owned_evidence = null;
    }
}

test "c3c-3b projection quarantines adoption inventory backing element drift" {
    const Probe = struct {
        storage: *ExternalPumpStorage,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.storage.client_cleanup_take.plan_inventory.?
                .batch_descriptors[0].stream_id +%= 1;
            return .retry_preserved;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    if (storage.owned_client) |*owned| owned.deinit();
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b projection permit generation drift cannot authorize callback result" {
    const Probe = struct {
        storage: *ExternalPumpStorage,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.storage.owner_event_projection_generation +%= 1;
            return .applied;
        }
    };
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(cleanup_scratch.isReady());
}

test "c3c-3b projection rejects forged Client list descriptor before dereference" {
    const Probe = struct {
        storage: *ExternalPumpStorage,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const client = if (self.storage.owned_client) |*owned|
                owned
            else
                unreachable;
            client.pending_batches.items.ptr = @ptrFromInt(0x1000);
            client.pending_batches.items.len = 1;
            client.pending_batches.capacity = 1;
            return .applied;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    // The forged graph is intentionally quarantined and must not be traversed by fixture cleanup.
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b projection rejects independent owner scalar drift after callback" {
    const Mutation = enum { lifecycle, semantic, incarnation, resize_pending };
    const Probe = struct {
        storage: *ExternalPumpStorage,
        mutation: Mutation,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (self.mutation) {
                .lifecycle => self.storage.lifecycle = .adopting,
                .semantic => self.storage.semantic_state = .adopting,
                .incarnation => self.storage.owner_incarnation +%= 1,
                .resize_pending => self.storage.owner_resize.current.pending = false,
            }
            return .retry_preserved;
        }
    };
    inline for (std.enums.values(Mutation)) |mutation| {
        resetCrossOwnerQuarantineForTest();
        defer resetCrossOwnerQuarantineForTest();
        var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
        defer fixture.deinitPeer();
        try appendTestEvent(&fixture.client,
            \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
        );
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(storage.commitAdoption() == .adopted);
        var fence: projection_test.PreparedInitialFenceClear = .{};
        try std.testing.expect(projection_test.prepare(&storage, &fence));
        try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
        var cleanup_scratch: ExternalPumpCleanupScratch = .{};
        try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
        var probe = Probe{ .storage = &storage, .mutation = mutation };
        try std.testing.expect(
            storage.projectOwnerEventInternal(.{
                .context = &probe,
                .context_len = @sizeOf(Probe),
                .project = Probe.project,
            }, &cleanup_scratch) == .terminal_latched,
        );
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expect(crossOwnerQuarantineStatus().latched);
        if (storage.owned_client) |*owned| owned.deinit();
        storage.owned_client = null;
        if (storage.owned_evidence) |*owned| owned.deinit();
        storage.owned_evidence = null;
    }
}

test "c3c-3b projection rejects metadata seal drift after callback" {
    const Probe = struct {
        storage: *ExternalPumpStorage,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.storage.owner_metadata.metadata.current.logical_seal
                .raw_digest[0] ^= 0xff;
            return .applied;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    fixture.client.metadata_support = .supported;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    if (storage.owned_client) |*owned| owned.deinit();
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-3b projection rejects deep ledger slot drift after callback" {
    const Probe = struct {
        storage: *ExternalPumpStorage,

        fn project(raw: *anyopaque, _: OwnerEventView) ProjectionDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = external_inbox_ledger.projection_test
                .driftFirstActiveGeneration(&self.storage.inbox_ledger);
            return .retry_preserved;
        }
    };
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    try appendTestEvent(&fixture.client,
        \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000aa","cols":132,"rows":43,"resize_generation":9,"reason":"controller"}}
    );
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.commitAdoption() == .adopted);
    var fence: projection_test.PreparedInitialFenceClear = .{};
    try std.testing.expect(projection_test.prepare(&storage, &fence));
    try std.testing.expect(projection_test.commit(&storage, &fence) == .cleared);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(&cleanup_scratch));
    var probe = Probe{ .storage = &storage };
    try std.testing.expect(
        storage.projectOwnerEventInternal(.{
            .context = &probe,
            .context_len = @sizeOf(Probe),
            .project = Probe.project,
        }, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    if (storage.owned_client) |*owned| owned.deinit();
    storage.owned_client = null;
    if (storage.owned_evidence) |*owned| owned.deinit();
    storage.owned_evidence = null;
}

test "c3c-2b1 pending resize scalar is cleared without damaging ownership" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    bindOwnerResize(&storage, .{
        .runtime_id = valid_evidence.runtime_id,
        .cols = 132,
        .rows = 43,
        .resize_generation = 9,
    });
    storage.owner_authority = .{ .current = .{
        .role = .controller,
        .generation = .{ .tracked = 3 },
        .flow = .initial_fence,
    } };
    storage.owner_request_ids = .{ .available = 7 };

    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(storage.owner_resize == .none);
    try std.testing.expect(storage.owner_authority == .empty);
    try std.testing.expect(storage.owner_request_ids == null);
}

test "recovery baseline metadata teardown is allocation-free and canonical" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(external_event_materialization.commitRecoveryBaseline(
        &storage.owner_metadata,
        @intFromPtr(&storage),
        @intFromPtr(&storage.owned_evidence.?),
        .unsupported,
    ));
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expectEqual(
        external_event_materialization.OwnerMetadataState{
            .lifecycle = .cleaned_tombstone,
        },
        storage.owner_metadata,
    );
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
}

test "c3c-2b1 generic teardown fails closed on partial owner descriptors" {
    const Owner = enum { screen, metadata };
    inline for (std.meta.tags(Owner)) |owner| {
        resetCrossOwnerQuarantineForTest();
        defer resetCrossOwnerQuarantineForTest();
        // Quarantine deliberately abandons an untrusted owner graph. Use the process allocator so
        // this corruption fixture proves bounded fail-close behavior without asking the testing
        // allocator to treat the intentional abandonment as an ordinary cleanup leak.
        var fixture = try TestClient.initWithAllocator(std.heap.page_allocator);
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        switch (owner) {
            .screen => storage.committed_screen.storage_addr = @intFromPtr(&storage),
            .metadata => storage.owner_metadata.storage_addr = @intFromPtr(&storage),
        }
        try std.testing.expectEqual(
            TeardownResult.quarantined,
            teardownForTest(&storage),
        );
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    }
}

test "c3c-3 aggregate teardown restores caller scratch and is idempotent" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expectEqual(
        CommitAdoptionResult.adopted,
        storage.commitAdoption(),
    );
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(
        &cleanup_scratch,
    ));
    try std.testing.expectEqual(
        TeardownResult.cleaned,
        storage.teardown(&cleanup_scratch),
    );
    try std.testing.expect(cleanup_scratch.isReady());
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        TeardownResult.already_dead,
        storage.teardown(&cleanup_scratch),
    );
    try std.testing.expect(cleanup_scratch.isReady());
}

test "c3c-3 aggregate teardown overwrites allocator callback mutation from hidden terminal scalars" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expectEqual(
        CommitAdoptionResult.adopted,
        storage.commitAdoption(),
    );
    probe.storage = &storage;
    probe.mode = .suffix_storage_drift;
    probe.fired = false;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(
        &cleanup_scratch,
    ));
    probe.cleanup_scratch = &cleanup_scratch;

    try std.testing.expectEqual(
        TeardownResult.cleaned,
        storage.teardown(&cleanup_scratch),
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(@intFromPtr(&storage), storage.saved_self_addr);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(storage.semantic_state == .terminal);
    const ledger = storage.inbox_ledger.accountingView();
    try std.testing.expect(ledger.valid);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectEqual(@as(usize, 0), ledger.retired_items);
    try std.testing.expectEqual(@as(usize, 0), ledger.retired_bytes);
    try std.testing.expectEqual(@as(u64, 1), ledger.next_generation);
    try std.testing.expect(!ledger.generation_exhausted);
    try std.testing.expectEqual(@as(u64, 0), ledger.mutation_epoch);
    try std.testing.expect(!ledger.invariant_failed);
    try std.testing.expect(cleanup_scratch.isReady());
}

test "c3c-3 aggregate teardown quarantines moved scratch and exhausted generation before callbacks" {
    const Scenario = enum { moved_scratch, exhausted_generation };
    inline for (std.meta.tags(Scenario)) |scenario| {
        resetCrossOwnerQuarantineForTest();
        defer resetCrossOwnerQuarantineForTest();
        var fixture = try TestClient.initWithAllocator(std.heap.page_allocator);
        defer fixture.deinitPeer();
        var storage: ExternalPumpStorage = .{};
        try std.testing.expect(
            initTestStorage(&storage, &fixture.client, valid_evidence) ==
                .initialized,
        );
        var cleanup_scratch: ExternalPumpCleanupScratch = .{};
        try std.testing.expect(ExternalPumpCleanupScratch.initInPlace(
            &cleanup_scratch,
        ));
        var moved = cleanup_scratch;
        const target = switch (scenario) {
            .moved_scratch => &moved,
            .exhausted_generation => blk: {
                storage.owner_teardown_generation = std.math.maxInt(u64);
                break :blk &cleanup_scratch;
            },
        };
        try std.testing.expectEqual(
            TeardownResult.quarantined,
            storage.teardown(target),
        );
        try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
        try std.testing.expectEqual(@as(usize, 0), fixture.client.pending_batch_bytes);
        switch (scenario) {
            .moved_scratch => try std.testing.expectEqual(
                ExternalPumpCleanupScratchLifecycle.ready,
                moved.lifecycle,
            ),
            .exhausted_generation => try std.testing.expectEqual(
                ExternalPumpCleanupScratchLifecycle.poisoned,
                cleanup_scratch.lifecycle,
            ),
        }
    }
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
        defer _ = teardownForTest(&storage);
        probe.storage = &storage;
        probe.mode = mode;

        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
        try std.testing.expect(probe.fired);
        switch (mode) {
            .prepare_reentry => try std.testing.expectEqual(
                std.meta.Tag(AdoptionPrepareStatus).retryable_preserved,
                probe.nested_prepare_tag.?,
            ),
            .prepare_teardown => try std.testing.expectEqual(
                TeardownResult.transaction_busy,
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
    defer _ = teardownForTest(&outer_storage);
    try std.testing.expect(
        initTestStorage(&nested_storage, &nested_fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&nested_storage);
    probe.storage = &outer_storage;
    probe.nested_storage = &nested_storage;
    probe.mode = .cross_prepare_reentry;

    try std.testing.expect(prepareAdoptionForTest(&outer_storage) == .prepared_adopted);
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(
        std.meta.Tag(AdoptionPrepareStatus).retryable_preserved,
        probe.nested_prepare_tag.?,
    );
    try std.testing.expectEqual(TeardownResult.transaction_busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.adopting, nested_storage.lifecycle);
    try std.testing.expectEqual(
        AdoptionLifecycle.empty,
        nested_storage.prepared_adoption.lifecycle,
    );
    try std.testing.expect(nested_storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expect(prepareAdoptionForTest(&nested_storage) == .prepared_adopted);
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
    defer _ = teardownForTest(&storage);
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .prepare_cleanup_teardown;

    const result = prepareAdoptionForTest(&storage);
    try std.testing.expect(result == .terminal_latched);
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(TeardownResult.transaction_busy, probe.nested_teardown.?);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(AdoptionLifecycle.empty, storage.prepared_adoption.lifecycle);
    try std.testing.expect(storage.owned_client == null);
}

test "external adoption proves the whole aggregate destination before writing it" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
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
    defer _ = teardownForTest(&storage);

    storage.owned_client.?.pending_events.items[0].payload =
        std.mem.asBytes(&storage.prepared_adoption)[0..original_payload.len];
    const result = prepareAdoptionForTest(&storage);
    try std.testing.expect(result == .terminal_latched);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
}

test "external adoption commits every non-adopted decision before returning" {
    const Case = struct {
        payload: []const u8,
        status: std.meta.Tag(AdoptionPrepareStatus),
        lifecycle: StorageLifecycle,
        terminal_reason: ?client_pump.TerminalReason,
    };
    const cases = [_]Case{
        .{
            .payload = "{\"event\":\"snapshot.invalidated\"}",
            .status = .recovery_committed,
            .lifecycle = .live,
            .terminal_reason = null,
        },
        .{
            .payload = "{\"event\":\"runtime.ended\"}",
            .status = .terminal_latched,
            .lifecycle = .dead,
            .terminal_reason = .runtime_ended,
        },
        .{
            .payload = "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
            .status = .terminal_latched,
            .lifecycle = .dead,
            .terminal_reason = .revoked,
        },
        .{
            .payload = "event",
            .status = .terminal_latched,
            .lifecycle = .dead,
            .terminal_reason = .protocol_error,
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
        defer _ = teardownForTest(&storage);

        const result = prepareAdoptionForTest(&storage);
        try std.testing.expectEqual(case.status, std.meta.activeTag(result));
        try std.testing.expectEqual(case.lifecycle, storage.lifecycle);
        if (case.terminal_reason) |reason| {
            try std.testing.expectEqual(reason, storage.semantic_state.terminal.reason);
        } else {
            const recovery = storage.semantic_state.active.host_recovery.ack_unadmitted;
            try std.testing.expectEqual(@as(u64, 1), recovery.epoch);
            try std.testing.expectEqual(
                @as(i128, 1) + 30 * @as(i128, std.time.ns_per_s),
                recovery.deadline_ns,
            );
            try std.testing.expect(storage.owner_authority == .current);
            try std.testing.expect(storage.owner_request_ids != null);
            try std.testing.expect(storage.owner_resize == .none);
            try std.testing.expect(storage.owner_metadata.isCommitted());
            try std.testing.expect(storage.owned_client != null);
            try std.testing.expect(storage.owned_client.?.io_mode == .external);
            try std.testing.expectEqual(
                @as(usize, 0),
                storage.owned_client.?.pending_events.items.len,
            );
            try std.testing.expectEqual(
                @as(u64, 0),
                storage.owned_client.?.next_request_id,
            );
            try std.testing.expect(
                storage.inbox_ledger.accountingView().pristine_zero,
            );
            try std.testing.expectEqual(
                TeardownResult.cleaned,
                teardownForTest(&storage),
            );
        }
        try std.testing.expect(
            storage.prepared_adoption.lifecycle == .committed_tombstone or
                storage.prepared_adoption.lifecycle == .empty or
                storage.prepared_adoption.lifecycle == .aborted_tombstone,
        );
    }
}

test "recovery suffix restores callback-mutated storage before live publish" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client, "{\"event\":\"snapshot.invalidated\"}");
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    probe.storage = &storage;
    probe.mode = .suffix_storage_drift;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());

    try std.testing.expect(
        storage.prepareAdoption(7, &cleanup_scratch) == .recovery_committed,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(@intFromPtr(&storage), storage.saved_self_addr);
    try std.testing.expectEqual(valid_evidence, storage.evidence_snapshot);
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
    try std.testing.expect(
        storage.semantic_state == .active and
            storage.semantic_state.active == .host_recovery,
    );
    try std.testing.expect(storage.owner_authority == .current);
    try std.testing.expect(storage.owner_request_ids != null);
    try std.testing.expect(storage.owned_client != null);
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
}

test "terminal suffix restores callback-mutated storage before dead publish" {
    var probe = AllocatorCallbackProbe{ .parent = std.testing.allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client, "{\"event\":\"runtime.ended\"}");
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    probe.storage = &storage;
    probe.mode = .suffix_storage_drift;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());

    try std.testing.expect(
        storage.prepareAdoption(7, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(@intFromPtr(&storage), storage.saved_self_addr);
    try std.testing.expectEqual(valid_evidence, storage.evidence_snapshot);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.runtime_ended,
        storage.semantic_state.terminal.reason,
    );
    try std.testing.expect(storage.owned_client == null);
    try std.testing.expect(storage.owned_evidence == null);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
}

test "external recovery deadline overflow terminalizes before live publication" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    try appendTestEvent(&fixture.client, "{\"event\":\"snapshot.invalidated\"}");
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());

    try std.testing.expect(
        storage.prepareAdoption(
            std.math.maxInt(i128),
            &cleanup_scratch,
        ) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        storage.semantic_state.terminal.reason,
    );
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expect(cleanup_scratch.isReady());
}

test "external zero request id terminalizes with exact public reason" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    fixture.client.next_request_id = 0;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());

    try std.testing.expect(
        storage.prepareAdoption(1, &cleanup_scratch) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.request_id_exhausted,
        storage.semantic_state.terminal.reason,
    );
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
}

test "external local screen item cap commits client recovery" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const batch_count = external_inbox_limits.max_items / 2 + 1;
    const stream_count = external_inbox_limits.max_items + 1 - batch_count;
    var index: usize = 0;
    while (index < batch_count) : (index += 1) {
        const payload = try fixture.client.allocator.dupe(u8, "s");
        try fixture.client.pending_batches.append(fixture.client.allocator, .{
            .is_snapshot = false,
            .stream_id = valid_evidence.stream_id,
            .bytes = payload,
            .allocator = fixture.client.allocator,
        });
        fixture.client.pending_batch_bytes += payload.len;
    }
    index = 0;
    while (index < stream_count) : (index += 1) {
        const payload = try fixture.client.allocator.dupe(u8, "s");
        try fixture.client.pending_stream.append(fixture.client.allocator, .{
            .header = .{
                .kind = .delta_chunk,
                .stream_id = valid_evidence.stream_id,
                .payload_len = @intCast(payload.len),
                .flags = protocol.Flags.end_stream,
            },
            .payload = payload,
        });
        fixture.client.pending_stream_bytes += payload.len;
    }
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());

    try std.testing.expect(
        storage.prepareAdoption(9, &cleanup_scratch) == .recovery_committed,
    );
    const recovery = storage.semantic_state.active.client_recovery.control_wait;
    try std.testing.expectEqual(@as(u64, 1), recovery.epoch);
    try std.testing.expectEqual(
        @as(i128, 9) + 30 * @as(i128, std.time.ns_per_s),
        recovery.deadline_ns,
    );
    try std.testing.expectEqual(StorageLifecycle.live, storage.lifecycle);
    try std.testing.expectEqual(
        @as(usize, 0),
        storage.owned_client.?.pending_batches.items.len,
    );
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
}

test "external adoption rejects moved cleanup scratch with bounded quarantine" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var fixture = try TestClient.initWithAllocator(std.heap.c_allocator);
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    var original: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(original.initInPlace());
    var moved = original;

    try std.testing.expect(
        storage.prepareAdoption(1, &moved) == .terminal_latched,
    );
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    try std.testing.expectEqual(
        max_cross_owner_quarantine_bytes,
        crossOwnerQuarantineStatus().leaked_bytes_upper_bound,
    );
}

test "external cleanup scratch rejects exact and partial storage aliases" {
    const storage_addr: usize = 0x100000;
    const storage_len = @sizeOf(ExternalPumpStorage);
    const scratch_len = @sizeOf(ExternalPumpCleanupScratch);
    try std.testing.expect(cleanupScratchRangeOverlapsStorage(
        storage_addr,
        storage_addr,
    ));
    try std.testing.expect(cleanupScratchRangeOverlapsStorage(
        storage_addr,
        storage_addr + storage_len - 1,
    ));
    try std.testing.expect(cleanupScratchRangeOverlapsStorage(
        storage_addr,
        storage_addr - scratch_len + 1,
    ));
    try std.testing.expect(!cleanupScratchRangeOverlapsStorage(
        storage_addr,
        storage_addr + storage_len,
    ));
    try std.testing.expect(!cleanupScratchRangeOverlapsStorage(
        storage_addr,
        storage_addr - scratch_len,
    ));
}

test "terminal discard validation drift quarantines without allocator callbacks" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var probe = AllocatorCallbackProbe{ .parent = std.heap.c_allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "screen");
    try fixture.client.pending_batches.append(fixture.client.allocator, .{
        .is_snapshot = false,
        .stream_id = valid_evidence.stream_id,
        .bytes = payload,
        .allocator = fixture.client.allocator,
    });
    fixture.client.pending_batch_bytes = payload.len;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    const owned_fd = storage.owned_client.?.fd;
    var cleanup_scratch: ExternalPumpCleanupScratch = .{};
    try std.testing.expect(cleanup_scratch.initInPlace());
    cleanup_scratch.range_scratch.source = .{};
    try storage.owned_client.?.prepareExternalRecoveryDiscard(
        valid_evidence.stream_id,
        &cleanup_scratch.client,
        &cleanup_scratch.range_scratch.source,
        &cleanup_scratch.recovery_discard,
    );
    storage.owned_client.?.pending_batch_bytes += 1;
    const callbacks_before = probe.callback_count;

    try std.testing.expect(
        storage.finishImmediateTerminal(.revoked, &cleanup_scratch) ==
            .terminal_latched,
    );
    try std.testing.expectEqual(callbacks_before, probe.callback_count);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.revoked,
        storage.semantic_state.terminal.reason,
    );
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
    _ = c.close(owned_fd);
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
    defer _ = teardownForTest(&storage);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
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
    try std.testing.expect(prepareAdoptionForTest(&baseline_storage) == .prepared_adopted);
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
        teardownForTest(&baseline_storage),
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
    defer _ = teardownForTest(&exact_storage);
    try std.testing.expect(prepareAdoptionForTest(&exact_storage) == .prepared_adopted);
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
    defer _ = teardownForTest(&over_storage);
    const over_result = prepareAdoptionForTest(&over_storage);
    try std.testing.expect(over_result == .terminal_latched);
    try std.testing.expectEqual(AdoptionLifecycle.empty, over_storage.prepared_adoption.lifecycle);
    try std.testing.expect(over_storage.inbox_ledger.accountingView().pristine_zero);
    try std.testing.expectEqual(StorageLifecycle.dead, over_storage.lifecycle);
    try std.testing.expectEqual(
        client_pump.TerminalReason.resource_exhausted,
        over_storage.semantic_state.terminal.reason,
    );
    try std.testing.expect(over_storage.owned_client == null);
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
    defer _ = teardownForTest(&storage);

    failing.fail_index = failing.alloc_index;
    try std.testing.expect(prepareAdoptionForTest(&storage) == .retryable_preserved);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(AdoptionLifecycle.empty, storage.prepared_adoption.lifecycle);
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    try std.testing.expect(storage.prepared_adoption.validate(&storage));
}

test "external take proof OOM with allocator callback drift is terminal" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var probe = AllocatorCallbackProbe{ .parent = std.heap.c_allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    defer _ = teardownForTest(&storage);
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .take_alloc_oom_drift;

    const result = prepareAdoptionForTest(&storage);
    try std.testing.expect(result == .terminal_latched);
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expectEqual(
        AdoptionLifecycle.aborted_tombstone,
        storage.prepared_adoption.lifecycle,
    );
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
}

test "adopted destination preflight OOM revalidates source before retry" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var probe = AllocatorCallbackProbe{ .parent = std.heap.c_allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        initTestStorage(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .prepare_preflight_oom_drift;

    try std.testing.expect(
        prepareAdoptionForTest(&storage) == .terminal_latched,
    );
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(crossOwnerQuarantineStatus().latched);
    try std.testing.expect(storage.inbox_ledger.accountingView().pristine_zero);
}

test "non-adopted terminal skips adopted destination allocating preflight" {
    resetCrossOwnerQuarantineForTest();
    defer resetCrossOwnerQuarantineForTest();
    var probe = AllocatorCallbackProbe{ .parent = std.heap.c_allocator };
    var fixture = try TestClient.initWithAllocator(probe.allocator());
    defer fixture.deinitPeer();
    const payload = try fixture.client.allocator.dupe(u8, "{}");
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
    probe.storage = &storage;
    probe.source = &storage.owned_client.?;
    probe.mode = .prepare_preflight_oom_drift;

    try std.testing.expect(
        prepareAdoptionForTest(&storage) == .terminal_latched,
    );
    try std.testing.expect(!probe.fired);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(!crossOwnerQuarantineStatus().latched);
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
    try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
    storage.prepared_adoption.lifecycle = .committed_tombstone;
    storage.prepared_adoption.backlog.client_disarm.lifecycle = @enumFromInt(3);
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
        defer _ = teardownForTest(&storage);
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
        const first = prepareAdoptionForTest(&storage);
        if (!failing.has_induced_failure) {
            try std.testing.expect(first == .prepared_adopted);
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
        try std.testing.expect(prepareAdoptionForTest(&storage) == .prepared_adopted);
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
    defer _ = teardownForTest(&frozen_storage);
    try std.testing.expect(prepareAdoptionForTest(&frozen_storage) == .prepared_adopted);
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
        client_pump.TerminalReason.protocol_error,
        terminalReasonForAuthorityError(error.ProtocolAuthority),
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        terminalReasonForAuthorityError(error.InvariantAuthority),
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
}

test "product initialization reserves one process external pump owner until teardown" {
    var first = try TestClient.init();
    defer first.deinitPeer();
    var first_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var first_evidence: PreparedAdoptionEvidence = .{};
    defer first_evidence.deinit();
    try sealAttachEvidence(
        &first_evidence,
        101,
        &first.client,
        valid_evidence,
        &first_seed,
    );
    var first_storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(
            &first_storage,
            &first.client,
            &first_evidence,
        ) == .initialized,
    );

    var second = try TestClient.init();
    defer second.deinitPeer();
    defer second.client.deinit();
    var second_seed: runtime_metadata_wire.InitialMetadataSeed = .unsupported;
    var second_evidence: PreparedAdoptionEvidence = .{};
    defer second_evidence.deinit();
    try sealAttachEvidence(
        &second_evidence,
        102,
        &second.client,
        valid_evidence,
        &second_seed,
    );
    var second_storage: ExternalPumpStorage = .{};
    const busy = ExternalPumpStorage.initInPlace(
        &second_storage,
        &second.client,
        &second_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.process_owner_busy, busy.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, busy.source_disposition);
    try std.testing.expect(second_evidence.validate(&second.client));
    try std.testing.expectEqual(StorageLifecycle.empty, second_storage.lifecycle);

    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&first_storage));
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(
            &second_storage,
            &second.client,
            &second_evidence,
        ) == .initialized,
    );
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&second_storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned_with_invariant, teardownForTest(&storage));
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
    try std.testing.expect(c.fcntl(old_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(old_fd, c.dup2(fixture.peer_fd, old_fd));
    defer _ = c.close(old_fd);
    try std.testing.expectEqual(TeardownResult.already_dead, teardownForTest(&storage));
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
    try std.testing.expectEqual(TeardownResult.moved_storage, teardownForTest(&forged));
    try std.testing.expectEqual(TeardownResult.cleaned, teardownForTest(&storage));
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
