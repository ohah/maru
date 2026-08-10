//! Final-address raw owner for one prepared generation event.
//!
//! Callback-visible storage never persists a Zig tagged union.  Tags and scalar payloads are
//! validated first, then `borrowPrepared` reconstructs a typed view whose metadata pointer cannot
//! outlive this owner.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const prepared_types = @import("runtime_event_prepared_types.zig");
const client_poison = @import("client_poison.zig");
const cleanup = @import("event_cleanup_seal.zig");
const process_seal = @import("process_seal_service.zig");
const observation_digest = @import("runtime_observation_digest.zig");

const RuntimeObservation = maru.app.RuntimeObservation;
const zero_digest = [_]u8{0} ** 32;

pub const PendingLifecycle = enum(u8) {
    idle = 0,
    preparing = 1,
    prepared = 2,
    settling = 3,
    committed_cleanup = 4,
};

pub const PendingEventIdentity = struct {
    expected_major: u16 = 0,
    metadata_support_raw: u8 = 0,
    correlation_binding_digest: [32]u8 = zero_digest,
    payload_digest: [32]u8 = zero_digest,
    admission_projection_digest: [32]u8 = zero_digest,
    wire_major: u16 = 0,
    admission_tag: u8 = 0,
    registry_incarnation: u64 = 0,
    binding_reservation_id: u64 = 0,
    event_node_incarnation: u64 = 0,
    stream_id: u64 = 0,
    event_generation: u64 = 0,
    event_owner_addr: u64 = 0,
    slot_incarnation: u64 = 0,
    owner_node_incarnation: u64 = 0,
    transport_incarnation: u64 = 0,
    host_id: u128 = 0,
    runtime_id: u128 = 0,
    connection_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
};

// The authority owner keeps a nominal type so the neutral cleanup leaf cannot acquire a reverse
// dependency. Its wire-independent scalar schema must nevertheless remain exactly identical to the
// cleanup transcript identity used by the seal service.
comptime {
    const owner_fields = std.meta.fields(PendingEventIdentity);
    const cleanup_fields = std.meta.fields(cleanup.PendingEventIdentity);
    if (owner_fields.len != cleanup_fields.len)
        @compileError("PendingEventIdentity field count drifted from cleanup SSOT");
    for (owner_fields, cleanup_fields) |owner_field, cleanup_field| {
        if (!std.mem.eql(u8, owner_field.name, cleanup_field.name) or owner_field.type != cleanup_field.type)
            @compileError("PendingEventIdentity schema drifted from cleanup SSOT");
    }
}

pub const RawPreparedEventStorage = struct {
    prepared_tag_raw: u8 = 0,
    effect_tag_raw: u8 = 0,
    failure_raw: u8 = 0,
    connection_reason_raw: u8 = 0,
    reserved: [4]u8 = [_]u8{0} ** 4,
    cols: u16 = 0,
    rows: u16 = 0,
    revoke_fence: u64 = 0,
    next_observation: RuntimeObservation = .{},
};

pub const PendingEventSourceReceipt = struct {
    event_identity: PendingEventIdentity = .{},
    runtime_addr: u64 = 0,
    pending_owner_addr: u64 = 0,
    payload_addr: u64 = 0,
    payload_len: u64 = 0,
    runtime_incarnation: u64 = 0,
    pending_owner_incarnation: u64 = 0,
    source_lease_incarnation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    receipt_seal: cleanup.CleanupSeal = zero_digest,
};

pub const PendingSourceLeaseState = enum(u8) {
    pristine = 0,
    active = 1,
    consumed = 2,
    aborted = 3,
};

pub const PendingEventSourceLease = struct {
    receipt: PendingEventSourceReceipt = .{},
    state_raw: u8 = @intFromEnum(PendingSourceLeaseState.pristine),
    reserved: [7]u8 = [_]u8{0} ** 7,
    attempt: u64 = 0,
    lease_seal: cleanup.CleanupSeal = zero_digest,
};

pub const PendingReleaseState = enum(u8) {
    pristine = 0,
    live = 1,
    consumed = 2,
};

pub const PendingEventReleaseReceipt = struct {
    event_identity: PendingEventIdentity = .{},
    pending_owner_addr: u64 = 0,
    pending_owner_incarnation: u64 = 0,
    source_lease_incarnation: u64 = 0,
    attempt: u64 = 0,
    state_raw: u8 = @intFromEnum(PendingReleaseState.pristine),
    reserved: [7]u8 = [_]u8{0} ** 7,
    release_seal: cleanup.CleanupSeal = zero_digest,
};

pub const PreparedEvent = union(prepared_types.PreparedEventTag) {
    ignored,
    ended,
    invalidated,
    resize_noop,
    resize_commit: maru.terminal.Size,
    metadata_noop,
    metadata_commit: *const RuntimeObservation,
    revoked: u64,
    failure: prepared_types.PreparationFailure,
};

pub const BorrowedPrepared = struct {
    event: PreparedEvent,
    effect: prepared_types.EffectRequest,
};

pub const PublicationEvidence = struct {
    cleanup_graph: cleanup.ObservationCleanupGraph,
    transcript_input: cleanup.CleanupTranscriptInput,
    progress_input: cleanup.CleanupProgressInput,
    transcript_seal: cleanup.CleanupSeal,
    progress_seal: cleanup.CleanupSeal,
};

pub const OwnerError = error{
    Busy,
    InvalidOwner,
};

pub const PendingEventOwner = struct {
    lifecycle_raw: u8 = @intFromEnum(PendingLifecycle.idle),
    reserved: [7]u8 = [_]u8{0} ** 7,
    self_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    next_attempt: u64 = 1,
    active_attempt: u64 = 0,
    operation_incarnation: u64 = 0,
    source_lease_incarnation: u64 = 0,
    event_identity: PendingEventIdentity = .{},
    prepared: RawPreparedEventStorage = .{},
    source_lease: PendingEventSourceLease = .{},
    release_receipt: PendingEventReleaseReceipt = .{},
    cleanup_graph: cleanup.ObservationCleanupGraph = .{},
    progress_input: ?cleanup.CleanupProgressInput = null,
    transcript_seal: cleanup.CleanupSeal = zero_digest,
    progress_seal: cleanup.CleanupSeal = zero_digest,

    pub fn initInPlace(self: *PendingEventOwner, owner_incarnation: u64) OwnerError!void {
        if (owner_incarnation == 0) return error.InvalidOwner;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_incarnation = owner_incarnation,
        };
    }

    /// Burns the attempt before any later allocation can fail.
    pub fn beginPrepare(self: *PendingEventOwner, identity: PendingEventIdentity) OwnerError!u64 {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.idle)) return error.Busy;
        if (self.next_attempt == 0 or self.next_attempt == std.math.maxInt(u64))
            return error.InvalidOwner;
        if (!rawStoragePristine(&self.prepared) or self.active_attempt != 0)
            return error.InvalidOwner;

        const attempt = self.next_attempt;
        self.next_attempt += 1;
        self.active_attempt = attempt;
        self.event_identity = identity;
        self.lifecycle_raw = @intFromEnum(PendingLifecycle.preparing);
        return attempt;
    }

    pub fn nextSourceLeaseIncarnation(self: *const PendingEventOwner) OwnerError!u64 {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.idle)) return error.Busy;
        if (self.source_lease_incarnation == std.math.maxInt(u64)) return error.InvalidOwner;
        return std.math.add(u64, self.source_lease_incarnation, 1) catch error.InvalidOwner;
    }

    fn publishNoAllocation(
        self: *PendingEventOwner,
        attempt: u64,
        value: prepared_types.PreparedDecision,
    ) OwnerError!void {
        if (std.meta.activeTag(value.projection) == .metadata_commit)
            return error.InvalidOwner;
        return self.publish(attempt, value, null, null, true);
    }

    fn publishFailure(
        self: *PendingEventOwner,
        attempt: u64,
        failure_value: prepared_types.PreparationFailure,
        effect: prepared_types.EffectRequest,
    ) OwnerError!void {
        return self.publish(
            attempt,
            .{ .projection = .{ .failure = failure_value }, .effect = effect },
            null,
            null,
            true,
        );
    }

    fn publishMetadata(
        self: *PendingEventOwner,
        attempt: u64,
        next_observation: *RuntimeObservation,
    ) OwnerError!void {
        return self.publish(
            attempt,
            .{ .projection = .metadata_commit, .effect = .none },
            next_observation,
            null,
            true,
        );
    }

    /// Installs the already-minted source authority only if it names this exact begin attempt.
    pub fn bindSourceLease(
        self: *PendingEventOwner,
        attempt: u64,
        lease: PendingEventSourceLease,
    ) OwnerError!void {
        try self.validatePreparing(attempt);
        if (!sourceLeaseValid(self, attempt, &lease)) return error.InvalidOwner;
        const expected_incarnation = std.math.add(u64, self.source_lease_incarnation, 1) catch
            return error.InvalidOwner;
        if (lease.receipt.source_lease_incarnation != expected_incarnation) return error.InvalidOwner;
        if (!sourceLeasePristine(&self.source_lease) or !releaseReceiptPristine(&self.release_receipt))
            return error.InvalidOwner;
        self.source_lease = lease;
        self.source_lease_incarnation = lease.receipt.source_lease_incarnation;
    }

    /// Canonical source-backed publication. All keyed seals are prepared before its no-fail writes.
    pub fn publishPrepared(
        self: *PendingEventOwner,
        attempt: u64,
        value: prepared_types.PreparedDecision,
        next_observation: ?*RuntimeObservation,
        evidence: PublicationEvidence,
    ) OwnerError!void {
        try self.validatePreparing(attempt);
        const prepared_source = try self.prepareSourcePublication(attempt);
        try self.publish(attempt, value, next_observation, evidence, false);
        self.source_lease = prepared_source[0];
        self.release_receipt = prepared_source[1];
        self.lifecycle_raw = @intFromEnum(PendingLifecycle.prepared);
    }

    /// Called only after scratch has been cleaned under exact proof and immediately before the
    /// caller fail-stops. The aborted source lease is retained as audit evidence and this function
    /// never returns; a later attempt therefore cannot strand a newly-pending event row.
    pub fn abortPrepare(self: *PendingEventOwner, attempt: u64) noreturn {
        self.retainAbortEvidenceOrFatal(attempt);
        process_seal.fatalIntegrity(.proof_loss);
    }

    fn retainAbortEvidenceOrFatal(self: *PendingEventOwner, attempt: u64) void {
        self.validatePreparing(attempt) catch process_seal.fatalIntegrity(.proof_loss);
        if (!rawStoragePristine(&self.prepared) or !releaseReceiptPristine(&self.release_receipt))
            process_seal.fatalIntegrity(.proof_loss);
        if (!sourceLeasePristine(&self.source_lease)) {
            if (!sourceLeaseValid(self, attempt, &self.source_lease))
                process_seal.fatalIntegrity(.proof_loss);
            const state = std.enums.fromInt(PendingSourceLeaseState, self.source_lease.state_raw) orelse
                process_seal.fatalIntegrity(.proof_loss);
            if (state == .active) {
                var aborted = self.source_lease;
                aborted.state_raw = @intFromEnum(PendingSourceLeaseState.aborted);
                aborted.lease_seal = process_seal.pendingSourceLeaseSeal(
                    aborted.receipt.pid,
                    aborted.receipt.process_nonce,
                    sourceLeaseSealInput(aborted),
                ) catch process_seal.fatalIntegrity(.proof_loss);
                self.source_lease = aborted;
            } else if (state != .aborted) process_seal.fatalIntegrity(.proof_loss);
        }
    }

    pub fn borrowPrepared(self: *const PendingEventOwner) OwnerError!BorrowedPrepared {
        return self.borrowPreparedImpl(true);
    }

    fn borrowPreparedForOwnerUnitTest(self: *const PendingEventOwner) OwnerError!BorrowedPrepared {
        if (!builtin.is_test) unreachable;
        return self.borrowPreparedImpl(false);
    }

    fn borrowPreparedImpl(self: *const PendingEventOwner, validate_authority: bool) OwnerError!BorrowedPrepared {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.prepared))
            return error.InvalidOwner;
        if (self.active_attempt == 0) return error.InvalidOwner;
        if (!allZero(&self.reserved) or !allZero(&self.prepared.reserved))
            return error.InvalidOwner;
        if (validate_authority and
            (!sourceLeaseValidState(self, self.active_attempt, &self.source_lease, .consumed) or
                !releaseReceiptValid(self, self.active_attempt, &self.release_receipt)))
            return error.InvalidOwner;

        const tag = std.enums.fromInt(
            prepared_types.PreparedEventTag,
            self.prepared.prepared_tag_raw,
        ) orelse return error.InvalidOwner;
        const effect_tag = std.enums.fromInt(
            prepared_types.EffectTag,
            self.prepared.effect_tag_raw,
        ) orelse return error.InvalidOwner;
        if (validate_authority) try self.validateStoredCleanupEvidence(tag == .metadata_commit);

        const event: PreparedEvent = switch (tag) {
            .ignored => blk: {
                try self.expectInactiveScalars();
                break :blk .ignored;
            },
            .ended => blk: {
                try self.expectInactiveScalars();
                break :blk .ended;
            },
            .invalidated => blk: {
                try self.expectInactiveScalars();
                break :blk .invalidated;
            },
            .resize_noop => blk: {
                try self.expectInactiveScalars();
                break :blk .resize_noop;
            },
            .resize_commit => blk: {
                if (self.prepared.failure_raw != 0 or self.prepared.revoke_fence != 0 or
                    !observationIsCanonicalEmpty(&self.prepared.next_observation))
                    return error.InvalidOwner;
                break :blk .{ .resize_commit = .{
                    .cols = self.prepared.cols,
                    .rows = self.prepared.rows,
                } };
            },
            .metadata_noop => blk: {
                try self.expectInactiveScalars();
                break :blk .metadata_noop;
            },
            .metadata_commit => blk: {
                if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
                    self.prepared.rows != 0 or self.prepared.revoke_fence != 0)
                    return error.InvalidOwner;
                break :blk .{ .metadata_commit = &self.prepared.next_observation };
            },
            .revoked => blk: {
                if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
                    self.prepared.rows != 0 or
                    !observationIsCanonicalEmpty(&self.prepared.next_observation))
                    return error.InvalidOwner;
                break :blk .{ .revoked = self.prepared.revoke_fence };
            },
            .failure => blk: {
                if (self.prepared.cols != 0 or self.prepared.rows != 0 or
                    self.prepared.revoke_fence != 0 or
                    !observationIsCanonicalEmpty(&self.prepared.next_observation))
                    return error.InvalidOwner;
                break :blk .{ .failure = std.enums.fromInt(
                    prepared_types.PreparationFailure,
                    self.prepared.failure_raw,
                ) orelse return error.InvalidOwner };
            },
        };

        const effect: prepared_types.EffectRequest = switch (effect_tag) {
            .none => blk: {
                if (self.prepared.connection_reason_raw != 0) return error.InvalidOwner;
                break :blk .none;
            },
            .poison => .{ .poison = std.enums.fromInt(
                client_poison.ConnectionReason,
                self.prepared.connection_reason_raw,
            ) orelse return error.InvalidOwner },
            .revoke_fence => .{ .revoke_fence = self.prepared.revoke_fence },
        };
        if (!effectMatchesEvent(event, effect)) return error.InvalidOwner;
        return .{ .event = event, .effect = effect };
    }

    fn publish(
        self: *PendingEventOwner,
        attempt: u64,
        value: prepared_types.PreparedDecision,
        next_observation: ?*RuntimeObservation,
        evidence: ?PublicationEvidence,
        publish_ready: bool,
    ) OwnerError!void {
        try self.validatePreparing(attempt);
        if (!rawStoragePristine(&self.prepared)) return error.InvalidOwner;
        if (!decisionEffectValid(value)) return error.InvalidOwner;
        const retains_observation = std.meta.activeTag(value.projection) == .metadata_commit;
        if (evidence) |proof| {
            if (!decisionMatchesProgress(value, proof.progress_input)) return error.InvalidOwner;
            try self.validatePublicationEvidence(attempt, proof, retains_observation);
        }
        if (retains_observation) {
            const observation = next_observation orelse return error.InvalidOwner;
            if (evidence) |proof|
                if (!graphMatchesObservation(proof.cleanup_graph, observation) or
                    !std.crypto.timing_safe.eql(
                        cleanup.Digest,
                        observation_digest.digest(observation, proof.cleanup_graph) catch
                            return error.InvalidOwner,
                        proof.progress_input.retained_observation_digest,
                    )) return error.InvalidOwner;
        } else if (next_observation != null or
            (evidence != null and !std.mem.allEqual(u8, std.mem.asBytes(&evidence.?.cleanup_graph), 0)))
            return error.InvalidOwner;

        var raw: RawPreparedEventStorage = .{};
        raw.prepared_tag_raw = @intFromEnum(std.meta.activeTag(value.projection));
        raw.effect_tag_raw = @intFromEnum(std.meta.activeTag(value.effect));
        switch (value.projection) {
            .resize_commit => |size| {
                raw.cols = size.cols;
                raw.rows = size.rows;
            },
            .revoked => |fence| raw.revoke_fence = fence,
            .failure => |failure_value| raw.failure_raw = @intFromEnum(failure_value),
            .metadata_commit => {
                const observation = next_observation orelse return error.InvalidOwner;
                raw.next_observation = observation.*;
                observation.* = .{};
            },
            else => if (next_observation != null) return error.InvalidOwner,
        }
        switch (value.effect) {
            .none => {},
            .poison => |reason| raw.connection_reason_raw = @intFromEnum(reason),
            .revoke_fence => |fence| {
                if (raw.revoke_fence != fence) return error.InvalidOwner;
            },
        }
        if (evidence) |proof| {
            self.cleanup_graph = proof.cleanup_graph;
            self.progress_input = proof.progress_input;
            self.transcript_seal = proof.transcript_seal;
            self.progress_seal = proof.progress_seal;
        } else if (!std.mem.allEqual(u8, std.mem.asBytes(&self.cleanup_graph), 0) or
            self.progress_input != null or
            !std.mem.allEqual(u8, &self.transcript_seal, 0) or
            !std.mem.allEqual(u8, &self.progress_seal, 0)) return error.InvalidOwner;
        self.prepared = raw;
        if (publish_ready) self.lifecycle_raw = @intFromEnum(PendingLifecycle.prepared);
    }

    fn validatePublicationEvidence(
        self: *const PendingEventOwner,
        attempt: u64,
        proof: PublicationEvidence,
        retains_observation: bool,
    ) OwnerError!void {
        if (!transcriptBoundToOwner(self, attempt, proof.transcript_input) or
            !std.meta.eql(proof.progress_input.transcript_input, proof.transcript_input) or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, proof.progress_input.transcript_seal, proof.transcript_seal))
            return error.InvalidOwner;
        const transcript = proof.transcript_input;
        const identity = self.event_identity;
        if (transcript.host_id != identity.host_id or transcript.runtime_id != identity.runtime_id or
            transcript.connection_generation != identity.connection_generation or transcript.slot_incarnation != identity.slot_incarnation or
            transcript.owner_node_incarnation != identity.owner_node_incarnation or transcript.transport_incarnation != identity.transport_incarnation or
            transcript.registry_incarnation != identity.registry_incarnation or transcript.binding_reservation_id != identity.binding_reservation_id or
            transcript.event_node_incarnation != identity.event_node_incarnation or transcript.stream_id != identity.stream_id or
            transcript.event_generation != identity.event_generation or transcript.event_owner_addr != identity.event_owner_addr or
            transcript.wire_major != identity.wire_major or transcript.expected_major != identity.expected_major or
            transcript.metadata_support_raw != identity.metadata_support_raw or transcript.admission_tag != identity.admission_tag or
            !std.crypto.timing_safe.eql(cleanup.Digest, transcript.correlation_binding_digest, identity.correlation_binding_digest) or
            !std.crypto.timing_safe.eql(cleanup.Digest, transcript.payload_digest, identity.payload_digest) or
            !std.crypto.timing_safe.eql(cleanup.Digest, transcript.admission_projection_digest, identity.admission_projection_digest))
            return error.InvalidOwner;
        const graph = switch (proof.transcript_input.plan) {
            .preparation => |plan| plan.next_observation,
            else => return error.InvalidOwner,
        };
        if (retains_observation) {
            if (!std.meta.eql(graph, proof.cleanup_graph) or
                proof.progress_input.step != .finished or proof.progress_input.next_role != .none or
                proof.progress_input.completed_mask != 0xff or
                std.mem.allEqual(u8, &proof.progress_input.retained_observation_digest, 0))
                return error.InvalidOwner;
        } else if (!std.mem.allEqual(u8, std.mem.asBytes(&proof.cleanup_graph), 0) or
            proof.progress_input.step != .finished or proof.progress_input.next_role != .none or
            proof.progress_input.completed_mask != 0xff or
            !std.mem.allEqual(u8, &proof.progress_input.retained_observation_digest, 0))
            return error.InvalidOwner;
        const expected_transcript = process_seal.cleanupTranscriptSeal(
            self.event_identity.pid,
            self.event_identity.process_nonce,
            proof.transcript_input,
        ) catch return error.InvalidOwner;
        if (!std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_transcript, proof.transcript_seal))
            return error.InvalidOwner;
        const expected_progress = process_seal.cleanupProgressSeal(
            self.event_identity.pid,
            self.event_identity.process_nonce,
            proof.progress_input,
        ) catch return error.InvalidOwner;
        if (!std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_progress, proof.progress_seal))
            return error.InvalidOwner;
    }

    fn validateStoredCleanupEvidence(self: *const PendingEventOwner, retains_observation: bool) OwnerError!void {
        const progress_input = self.progress_input orelse return error.InvalidOwner;
        const transcript_input = progress_input.transcript_input;
        if (!transcriptBoundToOwner(self, self.active_attempt, transcript_input) or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, progress_input.transcript_seal, self.transcript_seal))
            return error.InvalidOwner;
        const expected_transcript = process_seal.cleanupTranscriptSeal(
            self.event_identity.pid,
            self.event_identity.process_nonce,
            transcript_input,
        ) catch return error.InvalidOwner;
        const expected_progress = process_seal.cleanupProgressSeal(
            self.event_identity.pid,
            self.event_identity.process_nonce,
            progress_input,
        ) catch return error.InvalidOwner;
        if (!std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_transcript, self.transcript_seal) or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_progress, self.progress_seal))
            return error.InvalidOwner;
        if (!rawDecisionMatchesProgress(self.prepared, progress_input)) return error.InvalidOwner;
        if (retains_observation) {
            if (!graphMatchesObservation(self.cleanup_graph, &self.prepared.next_observation) or
                std.mem.allEqual(u8, &progress_input.retained_observation_digest, 0))
                return error.InvalidOwner;
            const current = observation_digest.digest(&self.prepared.next_observation, self.cleanup_graph) catch
                return error.InvalidOwner;
            if (!std.crypto.timing_safe.eql(cleanup.Digest, current, progress_input.retained_observation_digest))
                return error.InvalidOwner;
        } else if (!std.mem.allEqual(u8, &progress_input.retained_observation_digest, 0)) {
            return error.InvalidOwner;
        }
    }

    fn validateAddress(self: *const PendingEventOwner) OwnerError!void {
        if (self.self_addr != @intFromPtr(self) or self.owner_incarnation == 0)
            return error.InvalidOwner;
    }

    fn validatePreparing(self: *const PendingEventOwner, attempt: u64) OwnerError!void {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.preparing) or
            attempt == 0 or self.active_attempt != attempt)
            return error.InvalidOwner;
    }

    fn expectInactiveScalars(self: *const PendingEventOwner) OwnerError!void {
        if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
            self.prepared.rows != 0 or self.prepared.revoke_fence != 0 or
            !observationIsCanonicalEmpty(&self.prepared.next_observation))
            return error.InvalidOwner;
    }

    fn prepareSourcePublication(
        self: *const PendingEventOwner,
        attempt: u64,
    ) OwnerError!struct { PendingEventSourceLease, PendingEventReleaseReceipt } {
        if (!sourceLeaseValid(self, attempt, &self.source_lease) or
            !releaseReceiptPristine(&self.release_receipt)) return error.InvalidOwner;
        var consumed = self.source_lease;
        consumed.state_raw = @intFromEnum(PendingSourceLeaseState.consumed);
        consumed.lease_seal = process_seal.pendingSourceLeaseSeal(
            consumed.receipt.pid,
            consumed.receipt.process_nonce,
            sourceLeaseSealInput(consumed),
        ) catch return error.InvalidOwner;

        var release: PendingEventReleaseReceipt = .{
            .event_identity = consumed.receipt.event_identity,
            .pending_owner_addr = self.self_addr,
            .pending_owner_incarnation = self.owner_incarnation,
            .source_lease_incarnation = self.source_lease_incarnation,
            .attempt = attempt,
            .state_raw = @intFromEnum(PendingReleaseState.live),
        };
        release.release_seal = process_seal.pendingReleaseSeal(
            consumed.receipt.pid,
            consumed.receipt.process_nonce,
            releaseSealInput(release),
        ) catch return error.InvalidOwner;
        return .{ consumed, release };
    }
};

pub const testing = if (builtin.is_test) struct {
    fn descriptorUsesAllocator(
        descriptor: cleanup.CleanupDescriptor,
        allocator: std.mem.Allocator,
    ) bool {
        return descriptor.present == 0 or
            (descriptor.allocator_ptr == @intFromPtr(allocator.ptr) and
                descriptor.allocator_vtable == @intFromPtr(allocator.vtable));
    }

    fn graphUsesAllocator(graph: cleanup.ObservationCleanupGraph, allocator: std.mem.Allocator) bool {
        return descriptorUsesAllocator(graph.cwd, allocator) and
            descriptorUsesAllocator(graph.cwd_host, allocator) and
            descriptorUsesAllocator(graph.window_title, allocator) and
            descriptorUsesAllocator(graph.ssh_remote_dest, allocator) and
            descriptorUsesAllocator(graph.clipboard_read_target, allocator) and
            descriptorUsesAllocator(graph.foreground_processes, allocator) and
            descriptorUsesAllocator(graph.agent_progress, allocator);
    }

    pub fn retainAbortEvidenceForFixture(owner: *PendingEventOwner, attempt: u64) void {
        owner.retainAbortEvidenceOrFatal(attempt);
    }

    pub fn discardPreparedForFixture(owner: *PendingEventOwner, allocator: std.mem.Allocator) OwnerError!void {
        const borrowed = try owner.borrowPrepared();
        switch (borrowed.event) {
            .metadata_commit => {},
            else => return error.InvalidOwner,
        }
        if (!graphUsesAllocator(owner.cleanup_graph, allocator)) return error.InvalidOwner;
        owner.prepared.next_observation.deinit(allocator);
        owner.prepared = .{};
        owner.source_lease = .{};
        owner.release_receipt = .{};
        owner.cleanup_graph = .{};
        owner.progress_input = null;
        owner.transcript_seal = zero_digest;
        owner.progress_seal = zero_digest;
        owner.active_attempt = 0;
        owner.operation_incarnation = 0;
        owner.event_identity = .{};
        owner.lifecycle_raw = @intFromEnum(PendingLifecycle.idle);
    }
} else struct {};

fn descriptorMatchesList(descriptor: cleanup.CleanupDescriptor, list: anytype) bool {
    const T = std.meta.Child(@TypeOf(list.items));
    const len = std.math.mul(u64, list.items.len, @sizeOf(T)) catch return false;
    const capacity = std.math.mul(u64, list.capacity, @sizeOf(T)) catch return false;
    if (len == 0) return std.mem.allEqual(u8, std.mem.asBytes(&descriptor), 0) and list.capacity == 0;
    return list.items.len == list.capacity and descriptor.present == 1 and
        descriptor.address == @intFromPtr(list.items.ptr) and descriptor.length_bytes == len and
        descriptor.capacity_bytes == capacity and descriptor.alignment_log2 == std.math.log2_int(usize, @alignOf(T));
}

fn graphMatchesObservation(graph: cleanup.ObservationCleanupGraph, observation: *const RuntimeObservation) bool {
    return descriptorMatchesList(graph.cwd, observation.cwd) and
        descriptorMatchesList(graph.cwd_host, observation.cwd_host) and
        descriptorMatchesList(graph.window_title, observation.window_title) and
        descriptorMatchesList(graph.ssh_remote_dest, observation.ssh_remote_dest) and
        descriptorMatchesList(graph.clipboard_read_target, observation.clipboard_read_target) and
        descriptorMatchesList(graph.foreground_processes, observation.foreground_processes) and
        descriptorMatchesList(graph.agent_progress, observation.agent_progress);
}

fn rawStoragePristine(raw: *const RawPreparedEventStorage) bool {
    return raw.prepared_tag_raw == 0 and raw.effect_tag_raw == 0 and
        raw.failure_raw == 0 and raw.connection_reason_raw == 0 and
        allZero(&raw.reserved) and raw.cols == 0 and raw.rows == 0 and
        raw.revoke_fence == 0 and observationIsCanonicalEmpty(&raw.next_observation);
}

fn sourceLeasePristine(lease: *const PendingEventSourceLease) bool {
    return std.meta.eql(lease.*, PendingEventSourceLease{});
}

fn releaseReceiptPristine(receipt: *const PendingEventReleaseReceipt) bool {
    return std.meta.eql(receipt.*, PendingEventReleaseReceipt{});
}

fn sourceLeaseSealInput(lease: PendingEventSourceLease) cleanup.PendingSourceLeaseSealInput {
    return .{
        .receipt = sourceReceiptSealInput(lease.receipt),
        .state_raw = lease.state_raw,
        .reserved = lease.reserved,
        .attempt = lease.attempt,
    };
}

fn releaseSealInput(receipt: PendingEventReleaseReceipt) cleanup.PendingReleaseSealInput {
    return .{
        .event_identity = identityForSeal(receipt.event_identity),
        .pending_owner_addr = receipt.pending_owner_addr,
        .pending_owner_incarnation = receipt.pending_owner_incarnation,
        .source_lease_incarnation = receipt.source_lease_incarnation,
        .attempt = receipt.attempt,
        .state_raw = receipt.state_raw,
        .reserved = receipt.reserved,
    };
}

fn sourceLeaseValid(
    owner: *const PendingEventOwner,
    attempt: u64,
    lease: *const PendingEventSourceLease,
) bool {
    return sourceLeaseValidState(owner, attempt, lease, .active);
}

fn sourceLeaseValidState(
    owner: *const PendingEventOwner,
    attempt: u64,
    lease: *const PendingEventSourceLease,
    expected_state: PendingSourceLeaseState,
) bool {
    if (lease.state_raw != @intFromEnum(expected_state) or
        lease.attempt != attempt or !allZero(&lease.reserved) or
        lease.receipt.pending_owner_addr != owner.self_addr or
        lease.receipt.pending_owner_incarnation != owner.owner_incarnation or
        lease.receipt.source_lease_incarnation == 0 or
        !std.meta.eql(lease.receipt.event_identity, owner.event_identity))
        return false;
    const input = sourceReceiptSealInput(lease.receipt);
    const receipt_seal = process_seal.pendingSourceReceiptSeal(
        lease.receipt.pid,
        lease.receipt.process_nonce,
        input,
    ) catch return false;
    const lease_seal = process_seal.pendingSourceLeaseSeal(
        lease.receipt.pid,
        lease.receipt.process_nonce,
        sourceLeaseSealInput(lease.*),
    ) catch return false;
    return std.crypto.timing_safe.eql(cleanup.CleanupSeal, receipt_seal, lease.receipt.receipt_seal) and
        std.crypto.timing_safe.eql(cleanup.CleanupSeal, lease_seal, lease.lease_seal);
}

fn releaseReceiptValid(
    owner: *const PendingEventOwner,
    attempt: u64,
    receipt: *const PendingEventReleaseReceipt,
) bool {
    if (receipt.state_raw != @intFromEnum(PendingReleaseState.live) or receipt.attempt != attempt or
        !allZero(&receipt.reserved) or receipt.pending_owner_addr != owner.self_addr or
        receipt.pending_owner_incarnation != owner.owner_incarnation or
        receipt.source_lease_incarnation != owner.source_lease_incarnation or
        !std.meta.eql(receipt.event_identity, owner.event_identity)) return false;
    const expected = process_seal.pendingReleaseSeal(
        receipt.event_identity.pid,
        receipt.event_identity.process_nonce,
        releaseSealInput(receipt.*),
    ) catch return false;
    return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, receipt.release_seal);
}

fn sourceReceiptSealInput(receipt: PendingEventSourceReceipt) cleanup.PendingSourceReceiptSealInput {
    return .{
        .event_identity = identityForSeal(receipt.event_identity),
        .runtime_addr = receipt.runtime_addr,
        .pending_owner_addr = receipt.pending_owner_addr,
        .payload_addr = receipt.payload_addr,
        .payload_len = receipt.payload_len,
        .runtime_incarnation = receipt.runtime_incarnation,
        .pending_owner_incarnation = receipt.pending_owner_incarnation,
        .source_lease_incarnation = receipt.source_lease_incarnation,
        .pid = receipt.pid,
        .process_nonce = receipt.process_nonce,
        .thread_id = receipt.thread_id,
    };
}

fn identityForSeal(value: PendingEventIdentity) cleanup.PendingEventIdentity {
    var out: cleanup.PendingEventIdentity = undefined;
    inline for (std.meta.fields(cleanup.PendingEventIdentity)) |field|
        @field(out, field.name) = @field(value, field.name);
    return out;
}

fn transcriptIdentity(value: cleanup.CleanupTranscriptInput) cleanup.PendingEventIdentity {
    return .{
        .expected_major = value.expected_major,
        .metadata_support_raw = value.metadata_support_raw,
        .correlation_binding_digest = value.correlation_binding_digest,
        .payload_digest = value.payload_digest,
        .admission_projection_digest = value.admission_projection_digest,
        .wire_major = value.wire_major,
        .admission_tag = value.admission_tag,
        .registry_incarnation = value.registry_incarnation,
        .binding_reservation_id = value.binding_reservation_id,
        .event_node_incarnation = value.event_node_incarnation,
        .stream_id = value.stream_id,
        .event_generation = value.event_generation,
        .event_owner_addr = value.event_owner_addr,
        .slot_incarnation = value.slot_incarnation,
        .owner_node_incarnation = value.owner_node_incarnation,
        .transport_incarnation = value.transport_incarnation,
        .host_id = value.host_id,
        .runtime_id = value.runtime_id,
        .connection_generation = value.connection_generation,
        .pid = 0,
        .process_nonce = 0,
    };
}

fn transcriptBoundToOwner(owner: *const PendingEventOwner, attempt: u64, value: cleanup.CleanupTranscriptInput) bool {
    var expected = identityForSeal(owner.event_identity);
    // CleanupTranscriptInput intentionally omits the process-domain pair; the keyed seals bind it.
    expected.pid = 0;
    expected.process_nonce = 0;
    return attempt != 0 and attempt == owner.active_attempt and
        value.preparation_attempt == attempt and value.pending_owner_addr == owner.self_addr and
        value.pending_owner_incarnation == owner.owner_incarnation and value.pending_lifecycle == .preparing and
        std.meta.eql(transcriptIdentity(value), expected);
}

fn observationIsCanonicalEmpty(observation: *const RuntimeObservation) bool {
    return std.meta.eql(observation.*, RuntimeObservation{});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn effectMatchesEvent(event: PreparedEvent, effect: prepared_types.EffectRequest) bool {
    return switch (event) {
        .revoked => |fence| switch (effect) {
            .revoke_fence => |effect_fence| effect_fence == fence,
            else => false,
        },
        .failure => |value| switch (value) {
            .out_of_memory, .local_resource_exhausted => switch (effect) {
                .poison => |reason| reason == .local_resource_exhausted,
                else => false,
            },
            .protocol_error => switch (effect) {
                .poison => |reason| reason == .peer_contract_violation,
                else => false,
            },
            .connection_closed => std.meta.activeTag(effect) == .none,
        },
        else => std.meta.activeTag(effect) == .none,
    };
}

fn decisionEffectValid(value: prepared_types.PreparedDecision) bool {
    return switch (value.projection) {
        .revoked => |fence| switch (value.effect) {
            .revoke_fence => |effect_fence| effect_fence == fence,
            else => false,
        },
        .failure => |failure_value| switch (failure_value) {
            .out_of_memory, .local_resource_exhausted => switch (value.effect) {
                .poison => |reason| reason == .local_resource_exhausted,
                else => false,
            },
            .protocol_error => switch (value.effect) {
                .poison => |reason| reason == .peer_contract_violation,
                else => false,
            },
            .connection_closed => std.meta.activeTag(value.effect) == .none,
        },
        else => std.meta.activeTag(value.effect) == .none,
    };
}

fn decisionMatchesProgress(
    value: prepared_types.PreparedDecision,
    progress: cleanup.CleanupProgressInput,
) bool {
    return std.meta.eql(progress.decision, prepared_types.sealProjection(value));
}

fn rawDecisionMatchesProgress(
    raw: RawPreparedEventStorage,
    progress: cleanup.CleanupProgressInput,
) bool {
    return std.meta.eql(projectionFromRaw(raw), progress.decision);
}

/// The persisted owner has additional storage fields, but every sealed decision scalar keeps the
/// same name and type. Reflection makes a future projection field an immediate compile failure
/// instead of silently omitting it from borrow-time authentication.
fn projectionFromRaw(raw: RawPreparedEventStorage) prepared_types.DecisionSealProjection {
    var projection: prepared_types.DecisionSealProjection = .{ .bound_raw = 1 };
    inline for (std.meta.fields(prepared_types.DecisionSealProjection)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "bound_raw")) {
            if (!@hasField(RawPreparedEventStorage, field.name))
                @compileError("raw prepared decision field missing: " ++ field.name);
            if (@TypeOf(@field(raw, field.name)) != field.type)
                @compileError("raw prepared decision field type drift: " ++ field.name);
            @field(projection, field.name) = @field(raw, field.name);
        }
    }
    return projection;
}

fn testIdentity() PendingEventIdentity {
    return .{
        .expected_major = 2,
        .metadata_support_raw = 1,
        .stream_id = 7,
        .event_generation = 9,
        .host_id = 11,
        .runtime_id = 12,
        .pid = 42,
        .process_nonce = 13,
    };
}

test "C3-3b2b3 owner identity exact projection and lifecycle ABI" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PendingLifecycle.idle));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PendingLifecycle.preparing));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(PendingLifecycle.prepared));
    const names = .{ "expected_major", "metadata_support_raw", "correlation_binding_digest", "payload_digest", "admission_projection_digest", "wire_major", "admission_tag", "registry_incarnation", "binding_reservation_id", "event_node_incarnation", "stream_id", "event_generation", "event_owner_addr", "slot_incarnation", "owner_node_incarnation", "transport_incarnation", "host_id", "runtime_id", "connection_generation", "pid", "process_nonce" };
    inline for (std.meta.fields(PendingEventIdentity), names) |field, name|
        try std.testing.expectEqualStrings(name, field.name);

    const source_fields = .{
        .{ "event_identity", PendingEventIdentity }, .{ "runtime_addr", u64 },
        .{ "pending_owner_addr", u64 },              .{ "payload_addr", u64 },
        .{ "payload_len", u64 },                     .{ "runtime_incarnation", u64 },
        .{ "pending_owner_incarnation", u64 },       .{ "source_lease_incarnation", u64 },
        .{ "pid", u32 },                             .{ "process_nonce", u64 },
        .{ "thread_id", u64 },                       .{ "receipt_seal", cleanup.CleanupSeal },
    };
    inline for (std.meta.fields(PendingEventSourceReceipt), source_fields) |field, expected| {
        try std.testing.expectEqualStrings(expected[0], field.name);
        try std.testing.expect(field.type == expected[1]);
    }
    const release_fields = .{
        .{ "event_identity", PendingEventIdentity }, .{ "pending_owner_addr", u64 },
        .{ "pending_owner_incarnation", u64 },       .{ "source_lease_incarnation", u64 },
        .{ "attempt", u64 },                         .{ "state_raw", u8 },
        .{ "reserved", [7]u8 },                      .{ "release_seal", cleanup.CleanupSeal },
    };
    inline for (std.meta.fields(PendingEventReleaseReceipt), release_fields) |field, expected| {
        try std.testing.expectEqualStrings(expected[0], field.name);
        try std.testing.expect(field.type == expected[1]);
    }
}

test "C3-3b2b3 owner initializes pristine at its final address" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    try std.testing.expectEqual(@intFromPtr(&owner), owner.self_addr);
    try std.testing.expectEqual(@as(u64, 1), owner.next_attempt);
    try std.testing.expect(rawStoragePristine(&owner.prepared));
    try std.testing.expect(@alignOf(PendingEventOwner) <= 16);
    try std.testing.expect(@sizeOf(PendingEventOwner) <= 4096);
    try std.testing.expectEqual(@as(usize, 16), std.meta.fields(PendingEventOwner).len);
}

test "C3-3b2b3 owner burns attempts and rejects busy begin" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    try std.testing.expectEqual(@as(u64, 1), try owner.nextSourceLeaseIncarnation());
    try std.testing.expectEqual(@as(u64, 1), try owner.beginPrepare(testIdentity()));
    try std.testing.expectEqual(@as(u64, 2), owner.next_attempt);
    try std.testing.expectError(error.Busy, owner.beginPrepare(testIdentity()));
    try std.testing.expectError(error.Busy, owner.nextSourceLeaseIncarnation());
}

test "C3-3b2b3 owner publishes and borrows no-allocation projections" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    const attempt = try owner.beginPrepare(testIdentity());
    try owner.publishNoAllocation(attempt, prepared_types.decide(.ended));
    const borrowed = try owner.borrowPreparedForOwnerUnitTest();
    try std.testing.expectEqual(prepared_types.PreparedEventTag.ended, std.meta.activeTag(borrowed.event));
    try std.testing.expectEqual(prepared_types.EffectTag.none, std.meta.activeTag(borrowed.effect));
}

test "C3-3b2b3 owner publishes typed failure without owning observation" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    const attempt = try owner.beginPrepare(testIdentity());
    try owner.publishFailure(attempt, .protocol_error, .{ .poison = .peer_contract_violation });
    const borrowed = try owner.borrowPreparedForOwnerUnitTest();
    try std.testing.expectEqual(prepared_types.PreparedEventTag.failure, std.meta.activeTag(borrowed.event));
    try std.testing.expect(observationIsCanonicalEmpty(&owner.prepared.next_observation));
}

test "C3-3b2b3 owner metadata borrow points into sole persisted storage" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    const attempt = try owner.beginPrepare(testIdentity());
    var next: RuntimeObservation = .{ .revision = 17 };
    try owner.publishMetadata(attempt, &next);
    const borrowed = try owner.borrowPreparedForOwnerUnitTest();
    const observation = switch (borrowed.event) {
        .metadata_commit => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 17), observation.revision);
    try std.testing.expectEqual(@intFromPtr(&owner.prepared.next_observation), @intFromPtr(observation));
    try std.testing.expect(observationIsCanonicalEmpty(&next));
}

test "C3-3b2b3 owner rejects copied replayed and invalid raw tags" {
    var owner: PendingEventOwner = undefined;
    try owner.initInPlace(3);
    const attempt = try owner.beginPrepare(testIdentity());
    var copied = owner;
    try std.testing.expectError(error.InvalidOwner, copied.publishNoAllocation(attempt, prepared_types.decide(.ended)));
    try std.testing.expectError(error.InvalidOwner, owner.publishNoAllocation(attempt + 1, prepared_types.decide(.ended)));
    try owner.publishNoAllocation(attempt, prepared_types.decide(.ended));
    owner.prepared.prepared_tag_raw = 255;
    try std.testing.expectError(error.InvalidOwner, owner.borrowPreparedForOwnerUnitTest());
}
