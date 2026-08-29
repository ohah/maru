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
const settlement = @import("pending_event_settlement_contract.zig");
const lifetime = @import("runtime_lifetime_owner.zig");

const RuntimeObservation = maru.app.RuntimeObservation;
const CloseProgress = maru.app.term_runtime_backend.CloseProgress;
const zero_digest = [_]u8{0} ** 32;

pub const PendingLifecycle = enum(u8) {
    idle = 0,
    preparing = 1,
    prepared = 2,
    settling = 3,
    committed_cleanup = 4,
};

/// close sweep는 b4 전에는 semantic event를 실행하지 않고 이 readiness만 읽는다.
/// invalid raw를 pending으로 숨기면 파괴가 영구 보류되므로 dedicated fail-stop으로 닫는다.
pub fn closeReadinessRaw(lifecycle_raw: u8) CloseProgress {
    const lifecycle = std.enums.fromInt(PendingLifecycle, lifecycle_raw) orelse
        process_seal.fatalIntegrity(.invalid_pending_close_lifecycle);
    return switch (lifecycle) {
        .idle => .complete,
        .preparing, .prepared, .settling, .committed_cleanup => .event_pending,
    };
}

pub fn closeReadiness(self: *const PendingEventOwner) CloseProgress {
    return closeReadinessRaw(self.lifecycle_raw);
}

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
    semantic_generation: u64 = 0,
    observation_probe_nonce: u64 = 0,
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
    resize_commit: prepared_types.PreparedResizeCommit,
    metadata_noop,
    metadata_commit: *const RuntimeObservation,
    revoked: u64,
    failure: prepared_types.PreparationFailure,
};

pub const BorrowedPrepared = struct {
    event: PreparedEvent,
    effect: prepared_types.EffectRequest,
    observation_probe_nonce: u64,
};

pub const SemanticCommitPhase = enum(u8) {
    pristine = 0,
    prepared = 1,
    observation_moved = 2,
    post_recorded = 3,
    consumed = 4,
};

pub const SemanticCommitDecision = struct {
    prepared_tag_raw: u8,
    publish_raw: u8,
    disposition_raw: u8,
    reserved: [5]u8 = [_]u8{0} ** 5,
    cols: u16 = 0,
    rows: u16 = 0,
    resize_generation: u64 = 0,
    revoke_fence: u64 = 0,
    observation_probe_nonce: u64 = 0,
    failure_raw: u8 = 0,
    reserved_tail: [7]u8 = [_]u8{0} ** 7,
};

pub const PreparedSemanticCommit = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    disposition_seal: cleanup.CleanupSeal = zero_digest,
    prepared_seal: cleanup.CleanupSeal = zero_digest,
    decision: SemanticCommitDecision = .{
        .prepared_tag_raw = 0,
        .publish_raw = 0,
        .disposition_raw = 0,
    },
    phase_raw: u8 = @intFromEnum(SemanticCommitPhase.pristine),
    observation_moved_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    semantic_post_digest: cleanup.CleanupSeal = zero_digest,
    seal: cleanup.CleanupSeal = zero_digest,
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
    settlement_disposition: settlement.SettlementDisposition = .{},

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

    pub fn settlementEffectProjection(self: *const PendingEventOwner) OwnerError!settlement.PendingEffectProjection {
        const borrowed = try self.borrowPreparedImpl(true);
        if (!releaseReceiptValid(self, self.active_attempt, &self.release_receipt) or
            std.mem.allEqual(u8, &self.progress_seal, 0))
            return error.InvalidOwner;
        const effect_request: settlement.EffectRequestProjection = switch (borrowed.effect) {
            .none => .{},
            .poison => |reason| .{
                .tag_raw = @intFromEnum(settlement.EffectRequestTag.poison),
                .requested_reason = .{ .present_raw = 1, .reason_raw = @intFromEnum(reason) },
            },
            .revoke_fence => |fence| .{
                .tag_raw = @intFromEnum(settlement.EffectRequestTag.revoke_fence),
                .revoke_fence = fence,
            },
        };
        return .{
            .pending_owner_addr = self.self_addr,
            .owner_incarnation = self.owner_incarnation,
            .attempt = self.active_attempt,
            .event_generation = self.event_identity.event_generation,
            .prepared_effect_digest = self.progress_seal,
            .effect_request = effect_request,
            .release = .{
                .event_identity = identityForSeal(self.release_receipt.event_identity),
                .pending_owner_addr = self.release_receipt.pending_owner_addr,
                .pending_owner_incarnation = self.release_receipt.pending_owner_incarnation,
                .source_lease_incarnation = self.release_receipt.source_lease_incarnation,
                .attempt = self.release_receipt.attempt,
                .state_raw = self.release_receipt.state_raw,
                .reserved = self.release_receipt.reserved,
                .release_seal = self.release_receipt.release_seal,
            },
        };
    }

    /// lifecycle과 receipt를 바꾸지 않고 Pending-owned settlement 절반을 준비한다.
    pub fn preflightSettlement(
        self: *PendingEventOwner,
        lifetime_owner: *const lifetime.RuntimeLifetimeOwner,
        lease: *const lifetime.RuntimeSettlementLease,
        input: settlement.PendingSettlementInput,
        out: *settlement.PreparedPendingSettlementPermit,
    ) OwnerError!void {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.prepared)) return error.Busy;
        if (!std.meta.eql(out.*, settlement.PreparedPendingSettlementPermit{}) or
            !std.meta.eql(self.settlement_disposition, settlement.SettlementDisposition{}))
            return error.InvalidOwner;
        if (!lifetime_owner.validatePreparedSettlementBinding(lease, input.lease) or
            input.pending_owner_addr != self.self_addr or
            input.owner_incarnation != self.owner_incarnation or input.attempt != self.active_attempt or
            input.source_lease_incarnation != self.source_lease_incarnation or
            input.event_generation != self.event_identity.event_generation or
            input.lease.operation_identity.pending_owner_addr != self.self_addr or
            input.lease.operation_identity.pid != self.event_identity.pid or
            input.lease.operation_identity.process_nonce != self.event_identity.process_nonce or
            input.lease.operation_identity.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            input.effect_out_addr == 0 or input.release_out_addr == 0 or
            input.effect_out_addr == input.release_out_addr or
            !sourceLeaseValidState(self, self.active_attempt, &self.source_lease, .consumed) or
            !releaseReceiptValid(self, self.active_attempt, &self.release_receipt) or
            !std.crypto.timing_safe.eql(
                settlement.Digest,
                input.release_receipt_digest,
                self.release_receipt.release_seal,
            )) return error.InvalidOwner;

        var permit: settlement.PreparedPendingSettlementPermit = .{
            .self_addr = @intFromPtr(out),
            .pid = self.event_identity.pid,
            .process_nonce = self.event_identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .pending_owner_addr = self.self_addr,
            .owner_incarnation = self.owner_incarnation,
            .attempt = self.active_attempt,
            .source_lease_incarnation = self.source_lease_incarnation,
            .event_generation = self.event_identity.event_generation,
            .effect_out_addr = input.effect_out_addr,
            .release_out_addr = input.release_out_addr,
            .disposition_addr = @intFromPtr(&self.settlement_disposition),
            .scratch_ranges_digest = input.lease.ranges_digest,
            .scratch_pristine_digest = input.lease.pristine_digest,
            .preflight_proof_seal_digest = input.lease.preflight_proof_seal_digest,
            .lease_seal_digest = input.lease.lease_seal_digest,
            .release_receipt_digest = input.release_receipt_digest,
        };
        permit.seal = settlement.sealPendingSettlementPermit(permit) catch return error.InvalidOwner;
        out.* = permit;
        // lifecycle byte만 ready marker이며 일부만 기록된 permit은 항상 invalid다.
        out.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.prepared);
    }

    pub fn armSettlementNoFail(
        self: *PendingEventOwner,
        lifetime_owner: *lifetime.RuntimeLifetimeOwner,
        lease: *lifetime.RuntimeSettlementLease,
        permit: *settlement.PreparedPendingSettlementPermit,
        binding: settlement.RuntimeSettlementLeaseBinding,
    ) void {
        if (!lifetime_owner.validatePreparedSettlementBinding(lease, binding) or
            !self.settlementArmPreflightValid(permit, binding))
            process_seal.fatalIntegrity(.proof_loss);
        // paired admission은 두 owner 사이에 branch, callback, recoverable return이 없다.
        lifetime_owner.admitSettlementNoFail(lease, binding);
        if (!lifetime_owner.validateAdmittedSettlementBinding(lease, binding))
            process_seal.fatalIntegrity(.proof_loss);
        self.lifecycle_raw = @intFromEnum(PendingLifecycle.settling);
    }

    fn settlementArmPreflightValid(
        self: *const PendingEventOwner,
        permit: *const settlement.PreparedPendingSettlementPermit,
        binding: settlement.RuntimeSettlementLeaseBinding,
    ) bool {
        _ = self.borrowPreparedImpl(true) catch return false;
        return self.pendingSettlementPermitMatches(permit, binding) and
            std.meta.eql(self.settlement_disposition, settlement.SettlementDisposition{}) and
            std.crypto.timing_safe.eql(
                settlement.Digest,
                permit.release_receipt_digest,
                self.release_receipt.release_seal,
            );
    }

    pub fn publishSettlementNoFail(
        self: *PendingEventOwner,
        lifetime_owner: *const lifetime.RuntimeLifetimeOwner,
        lease: *const lifetime.RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
        permit: *settlement.PreparedPendingSettlementPermit,
        effect_permit: *settlement.PreparedEffectPermit,
        effect: *settlement.EffectCommitEvidence,
        release: *settlement.EventReleaseCompletion,
    ) void {
        if (!lifetime_owner.validateAdmittedSettlementBinding(lease, binding) or
            self.lifecycle_raw != @intFromEnum(PendingLifecycle.settling) or
            !self.pendingSettlementPermitMatches(permit, binding) or
            permit.pending_owner_addr != self.self_addr or permit.owner_incarnation != self.owner_incarnation or
            permit.attempt != self.active_attempt or permit.effect_out_addr != @intFromPtr(effect) or
            permit.release_out_addr != @intFromPtr(release) or
            !settlement.validEffectCommitEvidenceFor(effect_permit, binding, effect) or
            !settlement.validEventReleaseCompletion(release) or
            !settlementEvidenceMatches(self, effect) or !settlementEvidenceMatches(self, release) or
            !releaseReceiptValid(self, self.active_attempt, &self.release_receipt) or
            !std.crypto.timing_safe.eql(
                settlement.Digest,
                permit.release_receipt_digest,
                self.release_receipt.release_seal,
            ))
            process_seal.fatalIntegrity(.proof_loss);

        const outcome = std.enums.fromInt(settlement.ConfirmedEffectOutcome, effect.outcome_raw) orelse
            process_seal.fatalIntegrity(.proof_loss);
        const recovery = std.enums.fromInt(settlement.EffectRecovery, effect.recovery_raw) orelse
            process_seal.fatalIntegrity(.proof_loss);
        const disposition_tag: settlement.SettlementDispositionTag = if (recovery == .trusted_local_invariant)
            .suppress_local_invariant
        else if (outcome == .terminal_cleanup_confirmed)
            .suppress_terminal
        else
            .publish_prepared;
        var consumed = self.release_receipt;
        consumed.state_raw = @intFromEnum(PendingReleaseState.consumed);
        consumed.release_seal = process_seal.pendingReleaseSeal(
            consumed.event_identity.pid,
            consumed.event_identity.process_nonce,
            releaseSealInput(consumed),
        ) catch process_seal.fatalIntegrity(.proof_loss);

        var disposition: settlement.SettlementDisposition = .{
            .self_addr = @intFromPtr(&self.settlement_disposition),
            .disposition_raw = @intFromEnum(disposition_tag),
            .pid = self.event_identity.pid,
            .process_nonce = self.event_identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .pending_owner_addr = self.self_addr,
            .owner_incarnation = self.owner_incarnation,
            .attempt = self.active_attempt,
            .event_generation = self.event_identity.event_generation,
            .effect_evidence_digest = effect.seal,
            .registry_completion_digest = release.seal,
            .consumed_receipt_digest = consumed.release_seal,
        };
        disposition.seal = settlement.sealSettlementDisposition(
            disposition,
            self.event_identity.pid,
            self.event_identity.process_nonce,
        ) catch process_seal.fatalIntegrity(.proof_loss);

        self.release_receipt = consumed;
        self.settlement_disposition = disposition;
        self.settlement_disposition.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.prepared);
        permit.consumed_raw = 1;
        permit.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.consumed);
        effect_permit.consumed_raw = 1;
        effect_permit.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.consumed);
    }

    /// b3가 게시한 disposition과 prepared bytes를 한 번 검증해 b4 의미 commit 권위로 바꾼다.
    /// 이 전이 뒤에는 Runtime read/mutation이 continuation을 제시하는 commit suffix로만 가능하다.
    pub fn beginSemanticCommit(
        self: *PendingEventOwner,
        out: *PreparedSemanticCommit,
    ) OwnerError!SemanticCommitDecision {
        if (!std.meta.eql(out.*, PreparedSemanticCommit{})) return error.InvalidOwner;
        const borrowed = try self.borrowStoredPreparedImpl(true, .settling);
        if (!self.validSettlementDisposition()) return error.InvalidOwner;
        const disposition = std.enums.fromInt(
            settlement.SettlementDispositionTag,
            self.settlement_disposition.disposition_raw,
        ) orelse return error.InvalidOwner;
        const decision: SemanticCommitDecision = .{
            .prepared_tag_raw = @intFromEnum(std.meta.activeTag(borrowed.event)),
            .publish_raw = @intFromBool(disposition == .publish_prepared),
            .disposition_raw = @intFromEnum(disposition),
            .cols = switch (borrowed.event) {
                .resize_commit => |resize| resize.size.cols,
                else => 0,
            },
            .rows = switch (borrowed.event) {
                .resize_commit => |resize| resize.size.rows,
                else => 0,
            },
            .resize_generation = switch (borrowed.event) {
                .resize_commit => |resize| resize.resize_generation,
                else => 0,
            },
            .revoke_fence = switch (borrowed.event) {
                .revoked => |fence| fence,
                else => 0,
            },
            .observation_probe_nonce = borrowed.observation_probe_nonce,
            .failure_raw = switch (borrowed.event) {
                .failure => |failure| @intFromEnum(failure),
                else => 0,
            },
        };
        var prepared: PreparedSemanticCommit = .{
            .self_addr = @intFromPtr(out),
            .pid = self.event_identity.pid,
            .process_nonce = self.event_identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .pending_owner_addr = self.self_addr,
            .owner_incarnation = self.owner_incarnation,
            .attempt = self.active_attempt,
            .event_generation = self.event_identity.event_generation,
            .disposition_seal = self.settlement_disposition.seal,
            .prepared_seal = self.progress_seal,
            .decision = decision,
            .phase_raw = @intFromEnum(SemanticCommitPhase.prepared),
        };
        prepared.seal = semanticCommitSeal(prepared) catch return error.InvalidOwner;

        self.lifecycle_raw = @intFromEnum(PendingLifecycle.committed_cleanup);
        self.settlement_disposition.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.consumed);
        out.* = prepared;
        return decision;
    }

    /// metadata backing을 callback 전에 caller의 stack owner로 이동하고 public Pending source를 즉시 tombstone한다.
    pub fn moveCommittedObservationNoFail(
        self: *PendingEventOwner,
        permit: *PreparedSemanticCommit,
        out: *RuntimeObservation,
    ) void {
        if (!self.validSemanticCommit(permit, .prepared) or
            permit.decision.prepared_tag_raw != @intFromEnum(prepared_types.PreparedEventTag.metadata_commit) or
            !observationIsCanonicalEmpty(out) or permit.observation_moved_raw != 0)
            process_seal.fatalIntegrity(.proof_loss);
        out.* = self.prepared.next_observation;
        self.prepared.next_observation = .{};
        permit.observation_moved_raw = 1;
        permit.phase_raw = @intFromEnum(SemanticCommitPhase.observation_moved);
        permit.seal = semanticCommitSeal(permit.*) catch process_seal.fatalIntegrity(.proof_loss);
    }

    /// Runtime owner가 실제 semantic POST를 검증한 뒤 그 digest만 continuation에 기록한다.
    pub fn recordSemanticPostNoFail(
        self: *PendingEventOwner,
        permit: *PreparedSemanticCommit,
        semantic_post_digest: cleanup.CleanupSeal,
    ) void {
        const tag = std.enums.fromInt(prepared_types.PreparedEventTag, permit.decision.prepared_tag_raw) orelse
            process_seal.fatalIntegrity(.proof_loss);
        const expected_phase: SemanticCommitPhase = if (tag == .metadata_commit)
            .observation_moved
        else
            .prepared;
        if (!self.validSemanticCommit(permit, expected_phase) or
            std.mem.allEqual(u8, &semantic_post_digest, 0))
            process_seal.fatalIntegrity(.proof_loss);
        permit.semantic_post_digest = semantic_post_digest;
        permit.phase_raw = @intFromEnum(SemanticCommitPhase.post_recorded);
        permit.seal = semanticCommitSeal(permit.*) catch process_seal.fatalIntegrity(.proof_loss);
    }

    /// callback 뒤 exact continuation과 tombstone을 다시 확인한 뒤 owner를 다음 event용 idle로 되돌린다.
    pub fn finishSemanticCommitNoFail(
        self: *PendingEventOwner,
        permit: *PreparedSemanticCommit,
    ) void {
        if (!self.validSemanticCommit(permit, .post_recorded))
            process_seal.fatalIntegrity(.proof_loss);
        const tag = std.enums.fromInt(prepared_types.PreparedEventTag, permit.decision.prepared_tag_raw) orelse
            process_seal.fatalIntegrity(.proof_loss);
        if (tag == .metadata_commit and
            (!observationIsCanonicalEmpty(&self.prepared.next_observation) or permit.observation_moved_raw != 1))
            process_seal.fatalIntegrity(.proof_loss);

        self.prepared = .{};
        self.source_lease = .{};
        self.release_receipt = .{};
        self.cleanup_graph = .{};
        self.progress_input = null;
        self.transcript_seal = zero_digest;
        self.progress_seal = zero_digest;
        self.settlement_disposition = .{};
        self.active_attempt = 0;
        self.operation_incarnation = 0;
        self.event_identity = .{};
        self.lifecycle_raw = @intFromEnum(PendingLifecycle.idle);
        permit.phase_raw = @intFromEnum(SemanticCommitPhase.consumed);
        permit.seal = semanticCommitSeal(permit.*) catch process_seal.fatalIntegrity(.proof_loss);
    }

    fn validSettlementDisposition(self: *const PendingEventOwner) bool {
        const value = self.settlement_disposition;
        if (value.lifecycle_raw != @intFromEnum(settlement.AuthorityLifecycle.prepared) or
            std.enums.fromInt(settlement.SettlementDispositionTag, value.disposition_raw) == null or
            !std.mem.allEqual(u8, &value.reserved, 0) or value.reserved_pid != 0 or
            value.self_addr != @intFromPtr(&self.settlement_disposition) or
            value.pid != self.event_identity.pid or value.process_nonce != self.event_identity.process_nonce or
            value.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            value.pending_owner_addr != self.self_addr or value.owner_incarnation != self.owner_incarnation or
            value.attempt != self.active_attempt or value.event_generation != self.event_identity.event_generation or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, value.consumed_receipt_digest, self.release_receipt.release_seal) or
            std.mem.allEqual(u8, &value.effect_evidence_digest, 0) or
            std.mem.allEqual(u8, &value.registry_completion_digest, 0)) return false;
        const expected = settlement.sealSettlementDisposition(value, value.pid, value.process_nonce) catch return false;
        return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, value.seal);
    }

    fn validSemanticCommit(
        self: *const PendingEventOwner,
        permit: *const PreparedSemanticCommit,
        expected_phase: SemanticCommitPhase,
    ) bool {
        if (self.lifecycle_raw != @intFromEnum(PendingLifecycle.committed_cleanup) or
            permit.self_addr != @intFromPtr(permit) or permit.pid != self.event_identity.pid or
            permit.process_nonce != self.event_identity.process_nonce or permit.reserved_pid != 0 or
            permit.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            permit.pending_owner_addr != self.self_addr or permit.owner_incarnation != self.owner_incarnation or
            permit.attempt != self.active_attempt or permit.event_generation != self.event_identity.event_generation or
            permit.phase_raw != @intFromEnum(expected_phase) or !std.mem.allEqual(u8, &permit.reserved, 0) or
            !std.mem.allEqual(u8, &permit.decision.reserved, 0) or
            !std.mem.allEqual(u8, &permit.decision.reserved_tail, 0) or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, permit.disposition_seal, self.settlement_disposition.seal) or
            !std.crypto.timing_safe.eql(cleanup.CleanupSeal, permit.prepared_seal, self.progress_seal)) return false;
        const expected = semanticCommitSeal(permit.*) catch return false;
        return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, permit.seal);
    }

    fn pendingSettlementPermitMatches(
        self: *const PendingEventOwner,
        permit: *const settlement.PreparedPendingSettlementPermit,
        lease: settlement.RuntimeSettlementLeaseBinding,
    ) bool {
        return settlement.validPendingSettlementPermit(permit) and
            settlement.validRuntimeSettlementBinding(lease) and
            permit.pending_owner_addr == self.self_addr and permit.owner_incarnation == self.owner_incarnation and
            permit.attempt == self.active_attempt and permit.source_lease_incarnation == self.source_lease_incarnation and
            permit.event_generation == self.event_identity.event_generation and
            permit.disposition_addr == @intFromPtr(&self.settlement_disposition) and
            std.crypto.timing_safe.eql(settlement.Digest, permit.scratch_ranges_digest, lease.ranges_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, permit.scratch_pristine_digest, lease.pristine_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, permit.preflight_proof_seal_digest, lease.preflight_proof_seal_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, permit.lease_seal_digest, lease.lease_seal_digest);
    }

    fn borrowPreparedForOwnerUnitTest(self: *const PendingEventOwner) OwnerError!BorrowedPrepared {
        if (!builtin.is_test) unreachable;
        return self.borrowPreparedImpl(false);
    }

    fn borrowPreparedImpl(self: *const PendingEventOwner, validate_authority: bool) OwnerError!BorrowedPrepared {
        return self.borrowStoredPreparedImpl(validate_authority, .prepared);
    }

    fn borrowStoredPreparedImpl(
        self: *const PendingEventOwner,
        validate_authority: bool,
        expected_lifecycle: PendingLifecycle,
    ) OwnerError!BorrowedPrepared {
        try self.validateAddress();
        if (self.lifecycle_raw != @intFromEnum(expected_lifecycle))
            return error.InvalidOwner;
        if (self.active_attempt == 0) return error.InvalidOwner;
        if (!allZero(&self.reserved) or !allZero(&self.prepared.reserved))
            return error.InvalidOwner;
        if (validate_authority) {
            const release_state: PendingReleaseState = if (expected_lifecycle == .settling or
                expected_lifecycle == .committed_cleanup)
                .consumed
            else
                .live;
            if (!sourceLeaseValidState(self, self.active_attempt, &self.source_lease, .consumed) or
                !releaseReceiptValidState(self, self.active_attempt, &self.release_receipt, release_state))
                return error.InvalidOwner;
        }

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
                if (self.prepared.failure_raw != 0 or self.prepared.semantic_generation == 0 or
                    !observationIsCanonicalEmpty(&self.prepared.next_observation))
                    return error.InvalidOwner;
                break :blk .{ .resize_commit = .{
                    .size = .{ .cols = self.prepared.cols, .rows = self.prepared.rows },
                    .resize_generation = self.prepared.semantic_generation,
                } };
            },
            .metadata_noop => blk: {
                try self.expectInactiveScalarsAllowProbe();
                break :blk .metadata_noop;
            },
            .metadata_commit => blk: {
                if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
                    self.prepared.rows != 0 or self.prepared.semantic_generation != 0)
                    return error.InvalidOwner;
                break :blk .{ .metadata_commit = &self.prepared.next_observation };
            },
            .revoked => blk: {
                if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
                    self.prepared.rows != 0 or
                    !observationIsCanonicalEmpty(&self.prepared.next_observation))
                    return error.InvalidOwner;
                if (self.prepared.semantic_generation == 0) return error.InvalidOwner;
                break :blk .{ .revoked = self.prepared.semantic_generation };
            },
            .failure => blk: {
                if (self.prepared.cols != 0 or self.prepared.rows != 0 or
                    self.prepared.semantic_generation != 0 or
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
            .revoke_fence => .{ .revoke_fence = self.prepared.semantic_generation },
        };
        if (!effectMatchesEvent(event, effect)) return error.InvalidOwner;
        if (self.prepared.observation_probe_nonce != 0 and
            tag != .metadata_noop and tag != .metadata_commit)
            return error.InvalidOwner;
        return .{
            .event = event,
            .effect = effect,
            .observation_probe_nonce = self.prepared.observation_probe_nonce,
        };
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
        raw.observation_probe_nonce = value.observation_probe_nonce;
        switch (value.projection) {
            .resize_commit => |resize| {
                raw.cols = resize.size.cols;
                raw.rows = resize.size.rows;
                raw.semantic_generation = resize.resize_generation;
            },
            .revoked => |fence| raw.semantic_generation = fence,
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
                if (raw.semantic_generation != fence) return error.InvalidOwner;
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
            self.prepared.rows != 0 or self.prepared.semantic_generation != 0 or
            !observationIsCanonicalEmpty(&self.prepared.next_observation))
            return error.InvalidOwner;
    }

    fn expectInactiveScalarsAllowProbe(self: *const PendingEventOwner) OwnerError!void {
        if (self.prepared.failure_raw != 0 or self.prepared.cols != 0 or
            self.prepared.rows != 0 or self.prepared.semantic_generation != 0 or
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

fn semanticCommitSeal(value: PreparedSemanticCommit) process_seal.ReadyError!cleanup.CleanupSeal {
    return process_seal.preparedSemanticCommitSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .pending_owner_addr = value.pending_owner_addr,
        .owner_incarnation = value.owner_incarnation,
        .attempt = value.attempt,
        .event_generation = value.event_generation,
        .disposition_seal = value.disposition_seal,
        .prepared_seal = value.prepared_seal,
        .prepared_tag_raw = value.decision.prepared_tag_raw,
        .publish_raw = value.decision.publish_raw,
        .resize_generation = value.decision.resize_generation,
        .observation_probe_nonce = value.decision.observation_probe_nonce,
        .phase_raw = value.phase_raw,
        .observation_moved_raw = value.observation_moved_raw,
        .semantic_post_digest = value.semantic_post_digest,
    });
}

pub const testing = if (builtin.is_test) struct {
    pub fn initPreparedForSettlement(
        owner: *PendingEventOwner,
        identity: PendingEventIdentity,
        decision: prepared_types.PreparedDecision,
        seed: u8,
    ) !void {
        try owner.initInPlace(0xA000 + @as(u64, seed));
        const attempt = try owner.beginPrepare(identity);
        try owner.publishNoAllocation(attempt, decision);
        const transcript: cleanup.CleanupTranscriptInput = .{
            .host_id = identity.host_id,
            .runtime_id = identity.runtime_id,
            .connection_generation = identity.connection_generation,
            .slot_incarnation = identity.slot_incarnation,
            .owner_node_incarnation = identity.owner_node_incarnation,
            .transport_incarnation = identity.transport_incarnation,
            .registry_incarnation = identity.registry_incarnation,
            .binding_reservation_id = identity.binding_reservation_id,
            .event_node_incarnation = identity.event_node_incarnation,
            .stream_id = identity.stream_id,
            .event_generation = identity.event_generation,
            .event_owner_addr = identity.event_owner_addr,
            .wire_major = identity.wire_major,
            .expected_major = identity.expected_major,
            .metadata_support_raw = identity.metadata_support_raw,
            .admission_tag = identity.admission_tag,
            .correlation_binding_digest = identity.correlation_binding_digest,
            .payload_digest = identity.payload_digest,
            .admission_projection_digest = identity.admission_projection_digest,
            .pending_owner_addr = owner.self_addr,
            .pending_owner_incarnation = owner.owner_incarnation,
            .cleanup_plan_addr = 0xA100 + @as(u64, seed),
            .runtime_addr = 0xA200 + @as(u64, seed),
            .observation_addr = 0xA300 + @as(u64, seed),
            .observation_revision = 0,
            .observer_generation = 0,
            .title_generation = 0,
            .observation_digest = [_]u8{0x71 +% seed} ** 32,
            .preparation_attempt = attempt,
            .pending_lifecycle = .preparing,
            .plan = .{ .preparation = .{ .dto_backing = .{}, .next_observation = .{} } },
        };
        const transcript_seal = try process_seal.cleanupTranscriptSeal(identity.pid, identity.process_nonce, transcript);
        const progress: cleanup.CleanupProgressInput = .{
            .transcript_input = transcript,
            .transcript_seal = transcript_seal,
            .phase = .preparation,
            .step = .finished,
            .next_role = .none,
            .completed_mask = 0xff,
            .decision = prepared_types.sealProjection(decision),
        };
        owner.progress_input = progress;
        owner.transcript_seal = transcript_seal;
        owner.progress_seal = try process_seal.cleanupProgressSeal(identity.pid, identity.process_nonce, progress);
        owner.source_lease_incarnation = 1;
        var source_receipt: PendingEventSourceReceipt = .{
            .event_identity = identity,
            .runtime_addr = transcript.runtime_addr,
            .pending_owner_addr = owner.self_addr,
            .pending_owner_incarnation = owner.owner_incarnation,
            .source_lease_incarnation = 1,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
        };
        source_receipt.receipt_seal = try process_seal.pendingSourceReceiptSeal(
            identity.pid,
            identity.process_nonce,
            sourceReceiptSealInput(source_receipt),
        );
        owner.source_lease = .{
            .receipt = source_receipt,
            .state_raw = @intFromEnum(PendingSourceLeaseState.consumed),
            .attempt = attempt,
        };
        owner.source_lease.lease_seal = try process_seal.pendingSourceLeaseSeal(
            identity.pid,
            identity.process_nonce,
            sourceLeaseSealInput(owner.source_lease),
        );
        owner.release_receipt = .{
            .event_identity = identity,
            .pending_owner_addr = owner.self_addr,
            .pending_owner_incarnation = owner.owner_incarnation,
            .source_lease_incarnation = 1,
            .attempt = attempt,
            .state_raw = @intFromEnum(PendingReleaseState.live),
        };
        owner.release_receipt.release_seal = try process_seal.pendingReleaseSeal(
            identity.pid,
            identity.process_nonce,
            releaseSealInput(owner.release_receipt),
        );
    }

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
        owner.settlement_disposition = .{};
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
        raw.semantic_generation == 0 and raw.observation_probe_nonce == 0 and
        observationIsCanonicalEmpty(&raw.next_observation);
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
    return releaseReceiptValidState(owner, attempt, receipt, .live);
}

fn releaseReceiptValidState(
    owner: *const PendingEventOwner,
    attempt: u64,
    receipt: *const PendingEventReleaseReceipt,
    state: PendingReleaseState,
) bool {
    if (receipt.state_raw != @intFromEnum(state) or receipt.attempt != attempt or
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

fn settlementEvidenceMatches(owner: *const PendingEventOwner, evidence: anytype) bool {
    return evidence.pid == owner.event_identity.pid and
        evidence.process_nonce == owner.event_identity.process_nonce and
        evidence.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
        evidence.pending_owner_addr == owner.self_addr and
        evidence.owner_incarnation == owner.owner_incarnation and
        evidence.attempt == owner.active_attempt and
        evidence.event_generation == owner.event_identity.event_generation;
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
    if (value.observation_probe_nonce != 0) switch (value.projection) {
        .metadata_noop, .metadata_commit => {},
        else => return false,
    };
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

/// persisted owner와 sealed projection의 scalar 이름과 타입을 exact 대조한다.
/// resize generation과 revoke fence는 서로 배타적인 tag가 쓰는 `semantic_generation` 하나를 공유한다.
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
    try std.testing.expectEqual(@as(usize, 17), std.meta.fields(PendingEventOwner).len);
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

const SettlementFixture = struct {
    owner: PendingEventOwner = .{},
    lifetime_owner: lifetime.RuntimeLifetimeOwner = .{},
    lease: lifetime.RuntimeSettlementLease = .{},
    permit: settlement.PreparedPendingSettlementPermit = .{},
    effect_permit: settlement.PreparedEffectPermit = .{},
    effect: settlement.EffectCommitEvidence = .{},
    completion: settlement.EventReleaseCompletion = .{},
    binding: settlement.RuntimeSettlementLeaseBinding = .{},

    fn init(self: *SettlementFixture, seed: u8) !void {
        const ready = try ensureSettlementReady();
        try self.owner.initInPlace(0x3000 + @as(u64, seed));
        var identity = testIdentity();
        identity.pid = process_seal.currentProcessId();
        identity.process_nonce = ready;
        identity.event_generation = 0x5000 + @as(u64, seed);
        identity.wire_major = identity.expected_major;
        identity.connection_generation = 0x5050 + @as(u64, seed);
        identity.slot_incarnation = 0x5060 + @as(u64, seed);
        identity.owner_node_incarnation = 0x5070 + @as(u64, seed);
        identity.transport_incarnation = 0x5080 + @as(u64, seed);
        identity.correlation_binding_digest = [_]u8{0x59 +% seed} ** 32;
        identity.payload_digest = [_]u8{0x69 +% seed} ** 32;
        identity.registry_incarnation = 0x5100 + @as(u64, seed);
        identity.binding_reservation_id = 0x5200 + @as(u64, seed);
        identity.event_node_incarnation = 0x5300 + @as(u64, seed);
        identity.event_owner_addr = 0x5400 + @as(u64, seed);
        const attempt = try self.owner.beginPrepare(identity);
        const decision = prepared_types.decide(.ended);
        try self.owner.publishNoAllocation(attempt, decision);
        const transcript: cleanup.CleanupTranscriptInput = .{
            .host_id = identity.host_id,
            .runtime_id = identity.runtime_id,
            .connection_generation = identity.connection_generation,
            .slot_incarnation = identity.slot_incarnation,
            .owner_node_incarnation = identity.owner_node_incarnation,
            .transport_incarnation = identity.transport_incarnation,
            .registry_incarnation = identity.registry_incarnation,
            .binding_reservation_id = identity.binding_reservation_id,
            .event_node_incarnation = identity.event_node_incarnation,
            .stream_id = identity.stream_id,
            .event_generation = identity.event_generation,
            .event_owner_addr = identity.event_owner_addr,
            .wire_major = identity.wire_major,
            .expected_major = identity.expected_major,
            .metadata_support_raw = identity.metadata_support_raw,
            .admission_tag = identity.admission_tag,
            .correlation_binding_digest = identity.correlation_binding_digest,
            .payload_digest = identity.payload_digest,
            .admission_projection_digest = identity.admission_projection_digest,
            .pending_owner_addr = self.owner.self_addr,
            .pending_owner_incarnation = self.owner.owner_incarnation,
            .cleanup_plan_addr = 0x5500 + @as(u64, seed),
            .runtime_addr = 0x5600 + @as(u64, seed),
            .observation_addr = 0x5700 + @as(u64, seed),
            .observation_revision = 0,
            .observer_generation = 0,
            .title_generation = 0,
            .observation_digest = [_]u8{0x58 +% seed} ** 32,
            .preparation_attempt = attempt,
            .pending_lifecycle = .preparing,
            .plan = .{ .preparation = .{ .dto_backing = .{}, .next_observation = .{} } },
        };
        const transcript_seal = try process_seal.cleanupTranscriptSeal(
            identity.pid,
            identity.process_nonce,
            transcript,
        );
        const progress: cleanup.CleanupProgressInput = .{
            .transcript_input = transcript,
            .transcript_seal = transcript_seal,
            .phase = .preparation,
            .step = .finished,
            .next_role = .none,
            .completed_mask = 0xff,
            .decision = prepared_types.sealProjection(decision),
        };
        const progress_seal = try process_seal.cleanupProgressSeal(
            identity.pid,
            identity.process_nonce,
            progress,
        );
        self.owner.progress_input = progress;
        self.owner.transcript_seal = transcript_seal;
        self.owner.progress_seal = progress_seal;

        self.owner.source_lease_incarnation = 1;
        var source_receipt: PendingEventSourceReceipt = .{
            .event_identity = identity,
            .runtime_addr = 0x6000 + @as(u64, seed),
            .pending_owner_addr = self.owner.self_addr,
            .pending_owner_incarnation = self.owner.owner_incarnation,
            .source_lease_incarnation = 1,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
        };
        source_receipt.receipt_seal = try process_seal.pendingSourceReceiptSeal(
            identity.pid,
            identity.process_nonce,
            sourceReceiptSealInput(source_receipt),
        );
        self.owner.source_lease = .{
            .receipt = source_receipt,
            .state_raw = @intFromEnum(PendingSourceLeaseState.consumed),
            .attempt = attempt,
        };
        self.owner.source_lease.lease_seal = try process_seal.pendingSourceLeaseSeal(
            identity.pid,
            identity.process_nonce,
            sourceLeaseSealInput(self.owner.source_lease),
        );
        self.owner.release_receipt = .{
            .event_identity = identity,
            .pending_owner_addr = self.owner.self_addr,
            .pending_owner_incarnation = self.owner.owner_incarnation,
            .source_lease_incarnation = 1,
            .attempt = attempt,
            .state_raw = @intFromEnum(PendingReleaseState.live),
        };
        self.owner.release_receipt.release_seal = try process_seal.pendingReleaseSeal(
            identity.pid,
            identity.process_nonce,
            releaseSealInput(self.owner.release_receipt),
        );

        try self.lifetime_owner.initInPlace(
            source_receipt.runtime_addr,
            self.owner.self_addr,
            identity.process_nonce,
            0x8000 + @as(u64, seed),
        );
        var proof: settlement.SettlementScratchPreflightProof = .{
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .ranges_digest = [_]u8{seed +% 1} ** 32,
            .pristine_digest = [_]u8{seed +% 2} ** 32,
        };
        proof.proof_seal = try settlement.sealScratchPreflightProof(proof);
        self.binding = try self.lifetime_owner.acquireSettlement(&self.lease, proof);
        try self.owner.preflightSettlement(&self.lifetime_owner, &self.lease, .{
            .lease = self.binding,
            .pending_owner_addr = self.owner.self_addr,
            .owner_incarnation = self.owner.owner_incarnation,
            .attempt = attempt,
            .source_lease_incarnation = 1,
            .event_generation = identity.event_generation,
            .effect_out_addr = @intFromPtr(&self.effect),
            .release_out_addr = @intFromPtr(&self.completion),
            .release_receipt_digest = self.owner.release_receipt.release_seal,
        }, &self.permit);
    }

    fn arm(self: *SettlementFixture) void {
        self.owner.armSettlementNoFail(&self.lifetime_owner, &self.lease, &self.permit, self.binding);
    }

    fn replaceDecision(self: *SettlementFixture, decision: prepared_types.PreparedDecision) !void {
        self.owner.prepared = .{};
        self.owner.prepared.prepared_tag_raw = @intFromEnum(std.meta.activeTag(decision.projection));
        self.owner.prepared.effect_tag_raw = @intFromEnum(std.meta.activeTag(decision.effect));
        self.owner.prepared.observation_probe_nonce = decision.observation_probe_nonce;
        switch (decision.projection) {
            .resize_commit => |resize| {
                self.owner.prepared.cols = resize.size.cols;
                self.owner.prepared.rows = resize.size.rows;
                self.owner.prepared.semantic_generation = resize.resize_generation;
            },
            .revoked => |fence| self.owner.prepared.semantic_generation = fence,
            .failure => |failure| self.owner.prepared.failure_raw = @intFromEnum(failure),
            .metadata_commit => self.owner.prepared.next_observation.revision = 17,
            else => {},
        }
        switch (decision.effect) {
            .none => {},
            .poison => |reason| self.owner.prepared.connection_reason_raw = @intFromEnum(reason),
            .revoke_fence => |fence| self.owner.prepared.semantic_generation = fence,
        }
        var progress = self.owner.progress_input.?;
        progress.decision = prepared_types.sealProjection(decision);
        progress.retained_observation_digest = if (std.meta.activeTag(decision.projection) == .metadata_commit)
            try observation_digest.digest(&self.owner.prepared.next_observation, .{})
        else
            zero_digest;
        self.owner.progress_input = progress;
        self.owner.progress_seal = try process_seal.cleanupProgressSeal(
            self.owner.event_identity.pid,
            self.owner.event_identity.process_nonce,
            progress,
        );
    }

    fn settle(self: *SettlementFixture, disposition: settlement.SettlementDispositionTag) !void {
        self.arm();
        try self.prepareEvidence(disposition);
        self.owner.publishSettlementNoFail(
            &self.lifetime_owner,
            &self.lease,
            self.binding,
            &self.permit,
            &self.effect_permit,
            &self.effect,
            &self.completion,
        );
        self.lifetime_owner.consumeSettlementNoFail(&self.lease);
    }

    fn prepareEvidence(self: *SettlementFixture, disposition: settlement.SettlementDispositionTag) !void {
        const common = .{
            .pid = self.owner.event_identity.pid,
            .process_nonce = self.owner.event_identity.process_nonce,
            .thread_id = @as(u64, @intCast(std.Thread.getCurrentId())),
            .pending_owner_addr = self.owner.self_addr,
            .owner_incarnation = self.owner.owner_incarnation,
            .attempt = self.owner.active_attempt,
            .event_generation = self.owner.event_identity.event_generation,
        };
        self.effect_permit = fixtureEffectPermit(disposition);
        self.effect_permit.self_addr = @intFromPtr(&self.effect_permit);
        self.effect_permit.pid = common.pid;
        self.effect_permit.process_nonce = common.process_nonce;
        self.effect_permit.thread_id = common.thread_id;
        self.effect_permit.pending_owner_addr = common.pending_owner_addr;
        self.effect_permit.owner_incarnation = common.owner_incarnation;
        self.effect_permit.attempt = common.attempt;
        self.effect_permit.event_generation = common.event_generation;
        self.effect_permit.correlation_digest = self.owner.event_identity.correlation_binding_digest;
        self.effect_permit.prepared_effect_digest = self.owner.progress_seal;
        self.effect_permit.slot_incarnation = self.owner.event_identity.slot_incarnation;
        self.effect_permit.node_incarnation = self.owner.event_identity.owner_node_incarnation;
        self.effect_permit.binding_incarnation = self.owner.event_identity.binding_reservation_id;
        self.effect_permit.transport_incarnation = self.owner.event_identity.transport_incarnation;
        self.effect_permit.operation_node_addr = 0x9100;
        self.effect_permit.operation_registry_index = 1;
        self.effect_permit.operation_id = 1;
        self.effect_permit.target_stream_id = self.owner.event_identity.stream_id;
        self.effect_permit.effect_out_addr = @intFromPtr(&self.effect);
        self.effect_permit.effect_out_extent = @sizeOf(settlement.EffectCommitEvidence);
        self.effect_permit.effect_out_alignment = @alignOf(settlement.EffectCommitEvidence);
        self.effect_permit.effect_out_pristine_digest = [_]u8{0x91} ** 32;
        self.effect_permit.scratch_ranges_digest = self.binding.ranges_digest;
        self.effect_permit.scratch_pristine_digest = self.binding.pristine_digest;
        self.effect_permit.preflight_proof_seal_digest = self.binding.preflight_proof_seal_digest;
        self.effect_permit.lease_seal_digest = self.binding.lease_seal_digest;
        self.effect_permit.preflight_authority_digest = [_]u8{0x92} ** 32;
        self.effect_permit.seal = try settlement.sealPreparedEffectPermit(self.effect_permit);
        self.effect_permit.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.prepared);
        if (disposition != .suppress_local_invariant) {
            settlement.publishEffectCommitEvidenceNoFail(
                &self.effect_permit,
                self.binding,
                &self.effect,
            );
        } else self.effect = .{
            .self_addr = @intFromPtr(&self.effect),
            .outcome_raw = @intFromEnum(settlement.ConfirmedEffectOutcome.poison_confirmed),
            .recovery_raw = @intFromEnum(settlement.EffectRecovery.trusted_local_invariant),
            .pid = common.pid,
            .process_nonce = common.process_nonce,
            .thread_id = common.thread_id,
            .pending_owner_addr = common.pending_owner_addr,
            .owner_incarnation = common.owner_incarnation,
            .attempt = common.attempt,
            .event_generation = common.event_generation,
            .commit_authority_digest = [_]u8{0xa1} ** 32,
            .cleanup_completion_digest = [_]u8{0xa2} ** 32,
            .confirmed_effect_digest = [_]u8{0xa3} ** 32,
        };
        if (disposition == .suppress_local_invariant) {
            self.effect.seal = try settlement.sealEffectCommitEvidence(self.effect);
            self.effect.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.prepared);
        }
        self.completion = .{
            .self_addr = @intFromPtr(&self.completion),
            .pid = common.pid,
            .process_nonce = common.process_nonce,
            .thread_id = common.thread_id,
            .pending_owner_addr = common.pending_owner_addr,
            .owner_incarnation = common.owner_incarnation,
            .attempt = common.attempt,
            .event_generation = common.event_generation,
            .registry_incarnation = self.owner.event_identity.registry_incarnation,
            .binding_reservation_id = self.owner.event_identity.binding_reservation_id,
            .event_node_incarnation = self.owner.event_identity.event_node_incarnation,
            .stream_id = self.owner.event_identity.stream_id,
            .event_owner_addr = self.owner.event_identity.event_owner_addr,
            .source_lease_incarnation = self.owner.source_lease_incarnation,
            .ordering_class_raw = 1,
            .release_receipt_digest = self.owner.release_receipt.release_seal,
            .permit_digest = self.permit.seal,
            .consumed_blocker_count = 1,
            .freed_payload_count = 1,
            .consumed_pin_count = 1,
            .settled_quarantine_count = 1,
            .post_transcript_digest = [_]u8{0xb3} ** 32,
        };
        self.completion.authority_digest = settlement.eventReleaseCompletionAuthorityDigest(self.completion);
        self.completion.seal = try settlement.sealEventReleaseCompletion(self.completion);
        self.completion.lifecycle_raw = @intFromEnum(settlement.AuthorityLifecycle.prepared);
    }
};

fn expectSemanticCommit(
    seed: u8,
    decision: prepared_types.PreparedDecision,
    disposition: settlement.SettlementDispositionTag,
) !void {
    var fixture: SettlementFixture = .{};
    try fixture.init(seed);
    try fixture.replaceDecision(decision);
    try fixture.settle(disposition);
    var permit: PreparedSemanticCommit = .{};
    const commit = try fixture.owner.beginSemanticCommit(&permit);
    try std.testing.expectEqual(@intFromEnum(std.meta.activeTag(decision.projection)), commit.prepared_tag_raw);
    try std.testing.expectEqual(@intFromBool(disposition == .publish_prepared), commit.publish_raw);
    try std.testing.expectEqual(decision.observation_probe_nonce, commit.observation_probe_nonce);
    var moved: RuntimeObservation = .{};
    if (std.meta.activeTag(decision.projection) == .metadata_commit)
        fixture.owner.moveCommittedObservationNoFail(&permit, &moved);
    fixture.owner.recordSemanticPostNoFail(&permit, [_]u8{seed +% 0xd0} ** 32);
    fixture.owner.finishSemanticCommitNoFail(&permit);
    try std.testing.expectEqual(@intFromEnum(PendingLifecycle.idle), fixture.owner.lifecycle_raw);
    try std.testing.expectEqual(@intFromEnum(SemanticCommitPhase.consumed), permit.phase_raw);
    moved.deinit(std.testing.allocator);
}

test "C3-3b4 Pending semantic commit은 ignored를 exact once 소비한다" {
    try expectSemanticCommit(31, prepared_types.decide(.{ .metadata = .{
        .current_revision = 2,
        .incoming_revision = 1,
        .semantic_equal = false,
        .content_equal = false,
    } }), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 ended를 exact once 소비한다" {
    try expectSemanticCommit(32, prepared_types.decide(.ended), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 invalidated를 exact once 소비한다" {
    try expectSemanticCommit(33, prepared_types.decide(.invalidated), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 resize_noop을 exact once 소비한다" {
    try expectSemanticCommit(34, prepared_types.decide(.{ .resize = .{
        .baseline_present = true,
        .current_generation = 4,
        .current_size = .{ .cols = 80, .rows = 24 },
        .incoming_generation = 3,
        .incoming_size = .{ .cols = 100, .rows = 30 },
    } }), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 resize_commit을 exact once 소비한다" {
    try expectSemanticCommit(35, prepared_types.decide(.{ .resize = .{
        .baseline_present = false,
        .current_generation = 0,
        .current_size = .{ .cols = 80, .rows = 24 },
        .incoming_generation = 1,
        .incoming_size = .{ .cols = 100, .rows = 30 },
    } }), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 metadata_noop을 exact once 소비한다" {
    try expectSemanticCommit(36, prepared_types.decide(.{ .metadata = .{
        .current_revision = 2,
        .incoming_revision = 2,
        .semantic_equal = true,
        .content_equal = true,
    } }), .publish_prepared);
}

test "Pending semantic commit seals async observation probe correlation through metadata noop" {
    var decision = prepared_types.decide(.{ .metadata = .{
        .current_revision = 2,
        .incoming_revision = 2,
        .semantic_equal = true,
        .content_equal = true,
    } });
    decision.observation_probe_nonce = 48879;
    try expectSemanticCommit(46, decision, .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 metadata_commit 소유권을 exact once 이전한다" {
    try expectSemanticCommit(37, prepared_types.decide(.{ .metadata = .{
        .current_revision = 2,
        .incoming_revision = 3,
        .semantic_equal = false,
        .content_equal = false,
    } }), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 revoked를 exact once 소비한다" {
    try expectSemanticCommit(38, prepared_types.decide(.{ .revoked = .{
        .successor_fence = 9,
        .successor_fence_valid = true,
    } }), .publish_prepared);
}

test "C3-3b4 Pending semantic commit은 failure를 suppress disposition에 맞춰 소비한다" {
    try expectSemanticCommit(39, prepared_types.decide(.connection_closed), .suppress_terminal);
}

fn fixtureEffectPermit(disposition: settlement.SettlementDispositionTag) settlement.PreparedEffectPermit {
    if (disposition != .suppress_terminal) return .{
        .action_raw = @intFromEnum(settlement.EffectAction.none),
        .fd_before = 9,
        .fd_after = 9,
    };
    return .{
        .action_raw = @intFromEnum(settlement.EffectAction.terminal_cleanup),
        .first_reason_before = .{ .present_raw = 1, .reason_raw = 0 },
        .first_reason_after = .{ .present_raw = 1, .reason_raw = 0 },
        .unusable_before_raw = 1,
        .unusable_after_raw = 1,
        .fd_before = -1,
        .fd_after = -1,
        .fd_disposition_raw = @intFromEnum(settlement.FdDisposition.already_detached),
    };
}

fn ensureSettlementReady() !u64 {
    if (process_seal.currentReadyIdentity()) |identity| return identity.process_nonce else |err| switch (err) {
        error.NotReady => {},
        else => return err,
    }
    const nonce: u64 = 0xc33b_3300_0000_0001;
    const receipt = try process_seal.prepare(process_seal.currentProcessId(), nonce);
    process_seal.commitReady(receipt);
    return nonce;
}

test "C3-3b3 authority receipt는 range와 pristine 상태를 봉인한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(1);
    try std.testing.expect(settlement.validPendingSettlementPermit(&fixture.permit));
    try std.testing.expect(std.crypto.timing_safe.eql(settlement.Digest, fixture.binding.ranges_digest, fixture.permit.scratch_ranges_digest));
    try fixture.prepareEvidence(.publish_prepared);
    const canonical_seal = fixture.effect.seal;
    fixture.effect.reserved[0] = 0xff;
    const padding_independent = try settlement.sealEffectCommitEvidence(fixture.effect);
    try std.testing.expect(std.crypto.timing_safe.eql(settlement.Digest, canonical_seal, padding_independent));
    try std.testing.expect(!settlement.validEffectCommitEvidence(&fixture.effect));
}

test "C3-3b3 authority receipt는 pending release projection을 봉인한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(2);
    var replay = fixture.permit;
    replay.release_receipt_digest[0] ^= 1;
    try std.testing.expect(!settlement.validPendingSettlementPermit(&replay));
    try std.testing.expectEqual(@intFromEnum(PendingReleaseState.live), fixture.owner.release_receipt.state_raw);
    try fixture.prepareEvidence(.publish_prepared);
    fixture.effect.recovery_raw = @intFromEnum(settlement.EffectRecovery.trusted_local_invariant);
    fixture.effect.outcome_raw = @intFromEnum(settlement.ConfirmedEffectOutcome.none_confirmed);
    fixture.effect.seal = try settlement.sealEffectCommitEvidence(fixture.effect);
    try std.testing.expect(!settlement.validEffectCommitEvidence(&fixture.effect));
}

test "C3-3b3 authority receipt는 exact event release completion만 허용한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(3);
    fixture.arm();
    try fixture.prepareEvidence(.publish_prepared);
    try std.testing.expect(settlement.validEventReleaseCompletion(&fixture.completion));
    try std.testing.expect(fixture.lifetime_owner.validateAdmittedSettlementBinding(&fixture.lease, fixture.binding));
    try std.testing.expect(fixture.owner.pendingSettlementPermitMatches(&fixture.permit, fixture.binding));
    try std.testing.expect(settlementEvidenceMatches(&fixture.owner, &fixture.completion));
    try std.testing.expect(releaseReceiptValid(&fixture.owner, fixture.owner.active_attempt, &fixture.owner.release_receipt));
    try std.testing.expect(settlement.validEffectCommitEvidence(&fixture.effect));
    try std.testing.expect(settlementEvidenceMatches(&fixture.owner, &fixture.effect));
    try std.testing.expectEqual(@intFromPtr(&fixture.effect), fixture.permit.effect_out_addr);
    try std.testing.expectEqual(@intFromPtr(&fixture.completion), fixture.permit.release_out_addr);
    try std.testing.expect(std.crypto.timing_safe.eql(
        settlement.Digest,
        fixture.permit.release_receipt_digest,
        fixture.owner.release_receipt.release_seal,
    ));
    fixture.owner.publishSettlementNoFail(
        &fixture.lifetime_owner,
        &fixture.lease,
        fixture.binding,
        &fixture.permit,
        &fixture.effect_permit,
        &fixture.effect,
        &fixture.completion,
    );
    try std.testing.expectEqual(@intFromEnum(PendingReleaseState.consumed), fixture.owner.release_receipt.state_raw);
    try std.testing.expectEqual(@as(u16, 1), fixture.completion.consumed_blocker_count);
}

test "C3-3b3 authority receipt는 disposition을 마지막에 ready로 게시한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(4);
    fixture.arm();
    try fixture.prepareEvidence(.suppress_terminal);
    fixture.owner.publishSettlementNoFail(
        &fixture.lifetime_owner,
        &fixture.lease,
        fixture.binding,
        &fixture.permit,
        &fixture.effect_permit,
        &fixture.effect,
        &fixture.completion,
    );
    try std.testing.expectEqual(@intFromEnum(settlement.AuthorityLifecycle.prepared), fixture.owner.settlement_disposition.lifecycle_raw);
    try std.testing.expectEqual(@intFromEnum(settlement.SettlementDispositionTag.suppress_terminal), fixture.owner.settlement_disposition.disposition_raw);
}

test "C3-3b3 authority receipt는 copy splice replay를 거부한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(5);
    var copied = fixture.permit;
    try std.testing.expect(!settlement.validPendingSettlementPermit(&copied));
    fixture.permit.attempt +%= 1;
    try std.testing.expect(!settlement.validPendingSettlementPermit(&fixture.permit));

    fixture.permit = copied;
    fixture.lifetime_owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
    fixture.lease = .{};
    var next_proof: settlement.SettlementScratchPreflightProof = .{
        .pid = fixture.owner.event_identity.pid,
        .process_nonce = fixture.owner.event_identity.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .ranges_digest = [_]u8{0xc1} ** 32,
        .pristine_digest = [_]u8{0xc2} ** 32,
    };
    next_proof.proof_seal = try settlement.sealScratchPreflightProof(next_proof);
    const next_binding = try fixture.lifetime_owner.acquireSettlement(&fixture.lease, next_proof);
    try std.testing.expect(!fixture.owner.pendingSettlementPermitMatches(&fixture.permit, next_binding));
    fixture.lifetime_owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
}

test "C3-3b3 authority receipt는 protected range alias를 거부한다" {
    var fixture: SettlementFixture = .{};
    try fixture.init(6);
    var occupied: settlement.PreparedPendingSettlementPermit = .{};
    const input: settlement.PendingSettlementInput = .{
        .lease = fixture.binding,
        .pending_owner_addr = fixture.owner.self_addr,
        .owner_incarnation = fixture.owner.owner_incarnation,
        .attempt = fixture.owner.active_attempt,
        .source_lease_incarnation = fixture.owner.source_lease_incarnation,
        .event_generation = fixture.owner.event_identity.event_generation,
        .effect_out_addr = @intFromPtr(&fixture.effect),
        .release_out_addr = @intFromPtr(&fixture.effect),
        .release_receipt_digest = fixture.owner.release_receipt.release_seal,
    };
    try std.testing.expectError(error.InvalidOwner, fixture.owner.preflightSettlement(
        &fixture.lifetime_owner,
        &fixture.lease,
        input,
        &occupied,
    ));
    try std.testing.expect(std.meta.eql(occupied, settlement.PreparedPendingSettlementPermit{}));
    fixture.owner.lifecycle_raw = @intFromEnum(PendingLifecycle.preparing);
    try std.testing.expect(!fixture.owner.settlementArmPreflightValid(&fixture.permit, fixture.binding));
    try std.testing.expect(fixture.lifetime_owner.validatePreparedSettlementBinding(&fixture.lease, fixture.binding));
}
