//! C3-3b3 정산 소유자가 공유하는 포인터 없는 권위 값을 정의한다.

const std = @import("std");
const seal_types = @import("event_cleanup_seal.zig");
const process_seal = @import("process_seal_service.zig");

pub const Digest = [32]u8;
pub const zero_digest = [_]u8{0} ** 32;

pub const SettlementScratchPreflightProof = struct {
    pid: u32 = 0,
    reserved: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    ranges_digest: Digest = zero_digest,
    pristine_digest: Digest = zero_digest,
    proof_seal: Digest = zero_digest,
};

pub const SettlementScratchRangeProof = struct {
    pid: u32 = 0,
    reserved: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    ranges_digest: Digest = zero_digest,
    disposition_offset: u64 = 0,
    proof_seal: Digest = zero_digest,
};

pub const EffectAction = enum(u8) {
    none = 0,
    poison = 1,
    revoke_clean = 2,
    revoke_cancel = 3,
    revoke_partial_poison = 4,
    terminal_cleanup = 5,
};
pub const OutboundRelation = enum(u8) { absent = 0, target = 1, sibling = 2 };
pub const OutboundDisposition = enum(u8) {
    absent = 0,
    preserved = 1,
    freed = 2,
    cancelled = 3,
    partial_poisoned = 4,
};
pub const CleanupMode = enum(u8) { none = 0, allocator_free = 1 };
pub const FdDisposition = enum(u8) { preserved = 0, already_detached = 1, detached_close_attempted = 2 };

pub const ReasonProjection = struct {
    present_raw: u8 = 0,
    reason_raw: u8 = 0,
};
pub const EffectRequestTag = enum(u8) { none = 0, poison = 1, revoke_fence = 2 };
pub const EffectRequestProjection = struct {
    tag_raw: u8 = @intFromEnum(EffectRequestTag.none),
    requested_reason: ReasonProjection = .{},
    revoke_fence: u64 = 0,
};
pub const CanonicalEffectPlan = struct {
    effect_request: EffectRequestProjection = .{},
    action_raw: u8 = @intFromEnum(EffectAction.none),
    first_reason_before: ReasonProjection = .{},
    first_reason_after: ReasonProjection = .{},
    unusable_before_raw: u8 = 0,
    unusable_after_raw: u8 = 0,
    fd_before: i32 = -1,
    fd_after: i32 = -1,
    fd_disposition_raw: u8 = @intFromEnum(FdDisposition.preserved),
    close_attempt_count: u8 = 0,
    outbound_relation_raw: u8 = @intFromEnum(OutboundRelation.absent),
    outbound_disposition_raw: u8 = @intFromEnum(OutboundDisposition.absent),
    cleanup_mode_raw: u8 = @intFromEnum(CleanupMode.none),
    cleanup_count: u8 = 0,
    outbound_offset: u64 = 0,
    outbound_len: u64 = 0,
    outbound_descriptor_digest: Digest = zero_digest,
    cleanup_callback_provenance_digest: Digest = zero_digest,
};

pub const EffectPreflightInput = struct {
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    correlation_digest: Digest = zero_digest,
    prepared_effect_digest: Digest = zero_digest,
    effect_request: EffectRequestProjection = .{},
    target_stream_id: u64 = 0,
    effect_out_addr: u64 = 0,
    effect_out_extent: u64 = 0,
    effect_out_alignment: u64 = 0,
    effect_out_pristine_digest: Digest = zero_digest,
    lease: RuntimeSettlementLeaseBinding = .{},
};

pub const PreparedEffectPermit = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    consumed_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    correlation_digest: Digest = zero_digest,
    prepared_effect_digest: Digest = zero_digest,
    effect_request: EffectRequestProjection = .{},
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    binding_incarnation: u64 = 0,
    transport_incarnation: u64 = 0,
    operation_node_addr: u64 = 0,
    operation_id: u64 = 0,
    operation_registry_index: u16 = 0,
    reserved_operation: [6]u8 = [_]u8{0} ** 6,
    target_stream_id: u64 = 0,
    action_raw: u8 = @intFromEnum(EffectAction.none),
    first_reason_before: ReasonProjection = .{},
    first_reason_after: ReasonProjection = .{},
    unusable_before_raw: u8 = 0,
    unusable_after_raw: u8 = 0,
    reserved_action: [3]u8 = [_]u8{0} ** 3,
    fd_before: i32 = -1,
    fd_after: i32 = -1,
    fd_disposition_raw: u8 = @intFromEnum(FdDisposition.preserved),
    close_attempt_count: u8 = 0,
    outbound_relation_raw: u8 = @intFromEnum(OutboundRelation.absent),
    outbound_disposition_raw: u8 = @intFromEnum(OutboundDisposition.absent),
    cleanup_mode_raw: u8 = @intFromEnum(CleanupMode.none),
    cleanup_count: u8 = 0,
    reserved_outbound: [2]u8 = [_]u8{0} ** 2,
    outbound_offset: u64 = 0,
    outbound_len: u64 = 0,
    outbound_descriptor_digest: Digest = zero_digest,
    cleanup_callback_provenance_digest: Digest = zero_digest,
    effect_out_addr: u64 = 0,
    effect_out_extent: u64 = 0,
    effect_out_alignment: u64 = 0,
    effect_out_pristine_digest: Digest = zero_digest,
    scratch_ranges_digest: Digest = zero_digest,
    scratch_pristine_digest: Digest = zero_digest,
    preflight_proof_seal_digest: Digest = zero_digest,
    lease_seal_digest: Digest = zero_digest,
    preflight_authority_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const RuntimeSettlementLeaseBinding = struct {
    lease_addr: u64 = 0,
    lifetime_owner_addr: u64 = 0,
    operation_identity: seal_types.RuntimeOperationIdentity = std.mem.zeroes(seal_types.RuntimeOperationIdentity),
    ranges_digest: Digest = zero_digest,
    pristine_digest: Digest = zero_digest,
    preflight_proof_seal_digest: Digest = zero_digest,
    lease_seal_digest: Digest = zero_digest,
    binding_seal: Digest = zero_digest,
};

pub const AuthorityLifecycle = enum(u8) { pristine = 0, prepared = 1, consumed = 2 };
pub const SettlementDispositionTag = enum(u8) {
    publish_prepared = 0,
    suppress_terminal = 1,
    suppress_local_invariant = 2,
};
pub const ConfirmedEffectOutcome = enum(u8) {
    none_confirmed = 0,
    poison_confirmed = 1,
    revoke_clean = 2,
    revoke_cancelled = 3,
    revoke_partial_poisoned = 4,
    terminal_cleanup_confirmed = 5,
};
pub const EffectRecovery = enum(u8) { none = 0, trusted_local_invariant = 1 };

pub const PendingSettlementInput = struct {
    lease: RuntimeSettlementLeaseBinding = .{},
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    source_lease_incarnation: u64 = 0,
    event_generation: u64 = 0,
    effect_out_addr: u64 = 0,
    release_out_addr: u64 = 0,
    release_receipt_digest: Digest = zero_digest,
};

pub const PreparedPendingSettlementPermit = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    consumed_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    source_lease_incarnation: u64 = 0,
    event_generation: u64 = 0,
    effect_out_addr: u64 = 0,
    release_out_addr: u64 = 0,
    disposition_addr: u64 = 0,
    scratch_ranges_digest: Digest = zero_digest,
    scratch_pristine_digest: Digest = zero_digest,
    preflight_proof_seal_digest: Digest = zero_digest,
    lease_seal_digest: Digest = zero_digest,
    release_receipt_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const EffectCommitEvidence = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    consumed_raw: u8 = 0,
    outcome_raw: u8 = 0,
    recovery_raw: u8 = @intFromEnum(EffectRecovery.none),
    reserved: [4]u8 = [_]u8{0} ** 4,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    first_reason_before: ReasonProjection = .{},
    first_reason_after: ReasonProjection = .{},
    unusable_before_raw: u8 = 0,
    unusable_after_raw: u8 = 0,
    fd_disposition_raw: u8 = @intFromEnum(FdDisposition.preserved),
    close_attempt_count: u8 = 0,
    outbound_relation_raw: u8 = @intFromEnum(OutboundRelation.absent),
    outbound_disposition_raw: u8 = @intFromEnum(OutboundDisposition.absent),
    cleanup_mode_raw: u8 = @intFromEnum(CleanupMode.none),
    reserved_effect: [1]u8 = [_]u8{0} ** 1,
    fd_before: i32 = -1,
    fd_after: i32 = -1,
    cleanup_count: u8 = 0,
    reserved_count: [7]u8 = [_]u8{0} ** 7,
    commit_authority_digest: Digest = zero_digest,
    outbound_descriptor_digest: Digest = zero_digest,
    cleanup_completion_digest: Digest = zero_digest,
    confirmed_effect_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const EventReleaseCompletion = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    outcome_raw: u8 = 0,
    detail_raw: u8 = 0,
    reserved: [5]u8 = [_]u8{0} ** 5,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    registry_incarnation: u64 = 0,
    binding_reservation_id: u64 = 0,
    event_node_incarnation: u64 = 0,
    stream_id: u64 = 0,
    event_owner_addr: u64 = 0,
    source_lease_incarnation: u64 = 0,
    ordering_class_raw: u8 = 0,
    reserved_ordering: [7]u8 = [_]u8{0} ** 7,
    release_receipt_digest: Digest = zero_digest,
    permit_digest: Digest = zero_digest,
    consumed_blocker_count: u16 = 0,
    freed_payload_count: u8 = 0,
    consumed_pin_count: u8 = 0,
    settled_quarantine_count: u8 = 0,
    reserved_count: [3]u8 = [_]u8{0} ** 3,
    post_transcript_digest: Digest = zero_digest,
    authority_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const PendingRegistryReleaseReceipt = struct {
    event_identity: seal_types.PendingEventIdentity = std.mem.zeroes(seal_types.PendingEventIdentity),
    pending_owner_addr: u64 = 0,
    pending_owner_incarnation: u64 = 0,
    source_lease_incarnation: u64 = 0,
    attempt: u64 = 0,
    state_raw: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,
    release_seal: Digest = zero_digest,
};

pub const PendingEffectProjection = struct {
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    prepared_effect_digest: Digest = zero_digest,
    effect_request: EffectRequestProjection = .{},
    release: PendingRegistryReleaseReceipt = .{},
};

pub const PreparedEventReleasePermit = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    consumed_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    registry_addr: u64 = 0,
    registry_incarnation: u64 = 0,
    binding_reservation_id: u64 = 0,
    entry_index: u16 = 0,
    reserved_entry: [6]u8 = [_]u8{0} ** 6,
    event_node_incarnation: u64 = 0,
    stream_id: u64 = 0,
    event_generation: u64 = 0,
    event_owner_addr: u64 = 0,
    pending_owner_addr: u64 = 0,
    pending_owner_incarnation: u64 = 0,
    source_lease_incarnation: u64 = 0,
    attempt: u64 = 0,
    ordering_class_raw: u8 = 0,
    reserved_ordering: [7]u8 = [_]u8{0} ** 7,
    expected_blocker_count: u64 = 0,
    completion_addr: u64 = 0,
    completion_extent: u64 = 0,
    completion_alignment: u64 = 0,
    completion_pristine_digest: Digest = zero_digest,
    begun_addr: u64 = 0,
    begun_extent: u64 = 0,
    begun_alignment: u64 = 0,
    begun_pristine_digest: Digest = zero_digest,
    scratch_ranges_digest: Digest = zero_digest,
    scratch_pristine_digest: Digest = zero_digest,
    preflight_proof_seal_digest: Digest = zero_digest,
    lease_seal_digest: Digest = zero_digest,
    release_receipt_digest: Digest = zero_digest,
    event_owner_seal: Digest = zero_digest,
    payload_addr: u64 = 0,
    payload_len: u64 = 0,
    payload_digest: Digest = zero_digest,
    allocator_ptr: u64 = 0,
    allocator_vtable: u64 = 0,
    pin_owner_addr: u64 = 0,
    lease_addr: u64 = 0,
    slot_addr: u64 = 0,
    node_addr: u64 = 0,
    pin_slot_incarnation: u64 = 0,
    pin_node_incarnation: u64 = 0,
    host_id: u128 = 0,
    connection_generation: u64 = 0,
    pin_process_nonce: u64 = 0,
    quarantine_slot_index: u16 = 0,
    reserved_quarantine: [6]u8 = [_]u8{0} ** 6,
    quarantine_reservation_generation: u64 = 0,
    source_authority_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const SettlementDisposition = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = @intFromEnum(AuthorityLifecycle.pristine),
    disposition_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    pending_owner_addr: u64 = 0,
    owner_incarnation: u64 = 0,
    attempt: u64 = 0,
    event_generation: u64 = 0,
    effect_evidence_digest: Digest = zero_digest,
    registry_completion_digest: Digest = zero_digest,
    consumed_receipt_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const EventReleasePostProjection = struct {
    registry_closed_digest: Digest = zero_digest,
    quarantine_closed_digest: Digest = zero_digest,
    pin_consumed_digest: Digest = zero_digest,
    callback_invoked_digest: Digest = zero_digest,
    owner_tombstoned_digest: Digest = zero_digest,
    correlation_tombstoned_digest: Digest = zero_digest,
    mirror_tombstoned_digest: Digest = zero_digest,
    callback_invocation_count: u8 = 0,
    source_tombstone_count: u8 = 0,
};
pub const EventReleasePostContext = struct {
    registry_incarnation: u64,
    binding_reservation_id: u64,
    event_node_incarnation: u64,
    event_generation: u64,
    event_owner_addr: u64,
    begun_addr: u64,
    payload_len: u64,
    quarantine_slot_index: u64,
    quarantine_reservation_generation: u64,
    pin_owner_addr: u64,
    lease_addr: u64,
    permit_seal: Digest,
    pin_node_incarnation: u64,
    pin_stream_id: u64,
    pin_slot_addr: u64,
    pin_connection_generation: u64,
    owner_pre_seal: Digest,
    correlation_pre_digest: Digest,
    mirror_pre_digest: Digest,
    registry: EventReleaseLeafReceipt,
    quarantine: EventReleaseLeafReceipt,
    pin: EventReleaseLeafReceipt,
    owner: EventReleasePhaseReceipt,
    correlation: EventReleasePhaseReceipt,
    mirror: EventReleasePhaseReceipt,
    callback: EventReleasePhaseReceipt,
};

pub const EventReleaseLeafRole = enum(u8) { registry = 1, quarantine = 2, pin = 3 };
pub const EventReleaseLeafReceipt = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    role_raw: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,
    identity_a: u64 = 0,
    identity_b: u64 = 0,
    identity_c: u64 = 0,
    identity_d: u64 = 0,
    identity_e: u64 = 0,
    identity_f: u64 = 0,
    before_a: u64 = 0,
    before_b: u64 = 0,
    after_a: u64 = 0,
    after_b: u64 = 0,
    seal: Digest = zero_digest,
};
pub const EventReleasePhaseRole = enum(u8) { owner = 1, correlation = 2, mirror = 3, callback = 4 };
pub const EventReleasePhaseReceipt = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    role_raw: u8 = 0,
    lifecycle_before_raw: u8 = 0,
    lifecycle_after_raw: u8 = 0,
    invocation_count: u8 = 0,
    reserved: [4]u8 = [_]u8{0} ** 4,
    event_owner_addr: u64 = 0,
    event_generation: u64 = 0,
    begun_addr: u64 = 0,
    invocation_ordinal: u64 = 0,
    before_digest: Digest = zero_digest,
    after_digest: Digest = zero_digest,
    permit_seal: Digest = zero_digest,
    tls_begun_seal: Digest = zero_digest,
    seal: Digest = zero_digest,
};
pub fn sealEventReleasePhaseReceipt(v: EventReleasePhaseReceipt) process_seal.ReadyError!Digest {
    return process_seal.eventReleasePhaseReceiptSeal(v.pid, v.process_nonce, .{
        .role_raw = v.role_raw,
        .lifecycle_before_raw = v.lifecycle_before_raw,
        .lifecycle_after_raw = v.lifecycle_after_raw,
        .invocation_count = v.invocation_count,
        .reserved = v.reserved,
        .event_owner_addr = v.event_owner_addr,
        .event_generation = v.event_generation,
        .begun_addr = v.begun_addr,
        .invocation_ordinal = v.invocation_ordinal,
        .before_digest = v.before_digest,
        .after_digest = v.after_digest,
        .permit_seal = v.permit_seal,
        .tls_begun_seal = v.tls_begun_seal,
    });
}
pub fn validEventReleasePhaseReceipt(v: EventReleasePhaseReceipt, role: EventReleasePhaseRole) bool {
    if (v.pid == 0 or v.process_nonce == 0 or v.thread_id == 0 or v.role_raw != @intFromEnum(role) or
        v.event_owner_addr == 0 or v.event_generation == 0 or v.begun_addr == 0 or
        std.mem.allEqual(u8, &v.before_digest, 0) or std.mem.allEqual(u8, &v.after_digest, 0) or
        std.mem.allEqual(u8, &v.permit_seal, 0) or !std.mem.allEqual(u8, &v.reserved, 0)) return false;
    if ((role == .callback) != (v.invocation_count == 1 and v.invocation_ordinal == 1 and !std.mem.allEqual(u8, &v.tls_begun_seal, 0))) return false;
    const lifecycle_ok = switch (role) {
        .owner => v.lifecycle_before_raw == 1 and v.lifecycle_after_raw == 2,
        .correlation => v.lifecycle_before_raw == 3 and v.lifecycle_after_raw == 4,
        .mirror => v.lifecycle_before_raw == 4 and v.lifecycle_after_raw == 5,
        .callback => v.lifecycle_before_raw == 6 and v.lifecycle_after_raw == 7,
    };
    if (!lifecycle_ok) return false;
    const expected = sealEventReleasePhaseReceipt(v) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, v.seal);
}
pub fn makeEventReleasePhaseReceipt(
    role: EventReleasePhaseRole,
    lifecycle_before_raw: u8,
    lifecycle_after_raw: u8,
    event_owner_addr: u64,
    event_generation: u64,
    begun_addr: u64,
    before_digest: Digest,
    after_digest: Digest,
    permit_seal: Digest,
    tls_begun_seal: Digest,
) process_seal.ReadyError!EventReleasePhaseReceipt {
    const ready = try process_seal.currentReadyIdentity();
    var v: EventReleasePhaseReceipt = .{ .pid = ready.pid, .process_nonce = ready.process_nonce, .thread_id = @intCast(std.Thread.getCurrentId()), .role_raw = @intFromEnum(role), .lifecycle_before_raw = lifecycle_before_raw, .lifecycle_after_raw = lifecycle_after_raw, .invocation_count = if (role == .callback) 1 else 0, .event_owner_addr = event_owner_addr, .event_generation = event_generation, .begun_addr = begun_addr, .invocation_ordinal = if (role == .callback) 1 else 0, .before_digest = before_digest, .after_digest = after_digest, .permit_seal = permit_seal, .tls_begun_seal = tls_begun_seal };
    v.seal = try sealEventReleasePhaseReceipt(v);
    return v;
}

pub fn canonicalEventReleasePhaseAfterDigest(role: EventReleasePhaseRole, begun_addr: u64, event_owner_addr: u64, event_generation: u64, lifecycle_after_raw: u8) Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("maru.event-release-canonical-after-zero.v1\x00");
    hashInt(&h, u8, @intFromEnum(role));
    hashInt(&h, u64, begun_addr);
    hashInt(&h, u64, event_owner_addr);
    hashInt(&h, u64, event_generation);
    hashInt(&h, u8, lifecycle_after_raw);
    return finishDigest(&h);
}
pub fn canonicalEventReleaseMirrorBeforeDigest(event_generation: u64) Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("maru.event-release-mirror-before.v1\x00");
    hashInt(&h, u64, event_generation);
    return finishDigest(&h);
}

pub fn sealEventReleaseLeafReceipt(value: EventReleaseLeafReceipt) process_seal.ReadyError!Digest {
    return process_seal.eventReleaseLeafReceiptSeal(value.pid, value.process_nonce, .{
        .role_raw = value.role_raw,
        .reserved = value.reserved,
        .identity_a = value.identity_a,
        .identity_b = value.identity_b,
        .identity_c = value.identity_c,
        .identity_d = value.identity_d,
        .identity_e = value.identity_e,
        .identity_f = value.identity_f,
        .before_a = value.before_a,
        .before_b = value.before_b,
        .after_a = value.after_a,
        .after_b = value.after_b,
    });
}

pub fn validEventReleaseLeafReceipt(value: EventReleaseLeafReceipt, role: EventReleaseLeafRole) bool {
    if (value.pid == 0 or value.process_nonce == 0 or value.thread_id == 0 or
        value.role_raw != @intFromEnum(role) or !std.mem.allEqual(u8, &value.reserved, 0)) return false;
    const incremented_after_a = std.math.add(u64, value.after_a, 1) catch return false;
    const exact_transition = switch (role) {
        .registry => value.identity_a != 0 and value.identity_b != 0 and value.identity_c != 0 and
            value.identity_d != 0 and value.before_a == incremented_after_a and value.before_b != value.after_b,
        .quarantine => value.identity_b != 0 and value.identity_c != 0 and value.identity_d != 0 and
            value.before_a == incremented_after_a and value.before_b > value.after_b,
        .pin => value.identity_a != 0 and value.identity_b != 0 and value.identity_c != 0 and
            value.identity_d != 0 and value.before_a == incremented_after_a and value.before_b == 0 and value.after_b == 0,
    };
    if (!exact_transition) return false;
    const expected = sealEventReleaseLeafReceipt(value) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn atomicSettlementImplemented() !void {
    return error.C3B3NotImplemented;
}

pub fn sealScratchPreflightProof(value: SettlementScratchPreflightProof) process_seal.ReadyError!Digest {
    return process_seal.settlementScratchProofSeal(value.pid, value.process_nonce, .{
        .thread_id = value.thread_id,
        .ranges_digest = value.ranges_digest,
        .pristine_digest = value.pristine_digest,
    });
}

pub fn sealScratchRangeProof(value: SettlementScratchRangeProof) process_seal.ReadyError!Digest {
    return process_seal.settlementScratchRangeSeal(value.pid, value.process_nonce, .{
        .thread_id = value.thread_id,
        .ranges_digest = value.ranges_digest,
        .disposition_offset = value.disposition_offset,
    });
}

pub fn validScratchRangeProof(value: SettlementScratchRangeProof) bool {
    if (value.pid == 0 or value.reserved != 0 or value.process_nonce == 0 or value.thread_id == 0 or
        std.mem.allEqual(u8, &value.ranges_digest, 0)) return false;
    const expected = sealScratchRangeProof(value) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.proof_seal);
}

pub fn sealPreparedEffectPermit(value: PreparedEffectPermit) process_seal.ReadyError!Digest {
    return process_seal.preparedEffectPermitSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .pending_owner_addr = value.pending_owner_addr,
        .owner_incarnation = value.owner_incarnation,
        .attempt = value.attempt,
        .event_generation = value.event_generation,
        .correlation_digest = value.correlation_digest,
        .prepared_effect_digest = value.prepared_effect_digest,
        .effect_request_tag_raw = value.effect_request.tag_raw,
        .requested_reason_present_raw = value.effect_request.requested_reason.present_raw,
        .requested_reason_raw = value.effect_request.requested_reason.reason_raw,
        .requested_revoke_fence = value.effect_request.revoke_fence,
        .slot_incarnation = value.slot_incarnation,
        .node_incarnation = value.node_incarnation,
        .binding_incarnation = value.binding_incarnation,
        .transport_incarnation = value.transport_incarnation,
        .operation_node_addr = value.operation_node_addr,
        .operation_id = value.operation_id,
        .operation_registry_index = value.operation_registry_index,
        .target_stream_id = value.target_stream_id,
        .action_raw = value.action_raw,
        .first_reason_before_present_raw = value.first_reason_before.present_raw,
        .first_reason_before_raw = value.first_reason_before.reason_raw,
        .first_reason_after_present_raw = value.first_reason_after.present_raw,
        .first_reason_after_raw = value.first_reason_after.reason_raw,
        .unusable_before_raw = value.unusable_before_raw,
        .unusable_after_raw = value.unusable_after_raw,
        .fd_before = value.fd_before,
        .fd_after = value.fd_after,
        .fd_disposition_raw = value.fd_disposition_raw,
        .close_attempt_count = value.close_attempt_count,
        .outbound_relation_raw = value.outbound_relation_raw,
        .outbound_disposition_raw = value.outbound_disposition_raw,
        .cleanup_mode_raw = value.cleanup_mode_raw,
        .cleanup_count = value.cleanup_count,
        .outbound_offset = value.outbound_offset,
        .outbound_len = value.outbound_len,
        .outbound_descriptor_digest = value.outbound_descriptor_digest,
        .cleanup_callback_provenance_digest = value.cleanup_callback_provenance_digest,
        .effect_out_addr = value.effect_out_addr,
        .effect_out_extent = value.effect_out_extent,
        .effect_out_alignment = value.effect_out_alignment,
        .effect_out_pristine_digest = value.effect_out_pristine_digest,
        .scratch_ranges_digest = value.scratch_ranges_digest,
        .scratch_pristine_digest = value.scratch_pristine_digest,
        .preflight_proof_seal_digest = value.preflight_proof_seal_digest,
        .lease_seal_digest = value.lease_seal_digest,
        .preflight_authority_digest = value.preflight_authority_digest,
    });
}

fn validReasonProjectionShape(value: ReasonProjection) bool {
    return switch (value.present_raw) {
        0 => value.reason_raw == 0,
        1 => true,
        else => false,
    };
}

fn reasonEqual(a: ReasonProjection, b: ReasonProjection) bool {
    return a.present_raw == b.present_raw and a.reason_raw == b.reason_raw;
}

fn validEffectRequestShape(value: EffectRequestProjection) bool {
    if (!validReasonProjectionShape(value.requested_reason)) return false;
    const tag = std.enums.fromInt(EffectRequestTag, value.tag_raw) orelse return false;
    return switch (tag) {
        .none => value.requested_reason.present_raw == 0 and value.revoke_fence == 0,
        .poison => value.requested_reason.present_raw == 1 and value.revoke_fence == 0,
        .revoke_fence => value.requested_reason.present_raw == 0 and value.revoke_fence != 0,
    };
}

fn validOutboundShape(value: *const CanonicalEffectPlan) bool {
    const relation = std.enums.fromInt(OutboundRelation, value.outbound_relation_raw) orelse return false;
    if (relation == .absent) return value.outbound_offset == 0 and value.outbound_len == 0 and
        std.mem.allEqual(u8, &value.outbound_descriptor_digest, 0);
    return value.outbound_len != 0 and value.outbound_offset < value.outbound_len and
        !std.mem.allEqual(u8, &value.outbound_descriptor_digest, 0);
}

fn cleanupShape(value: *const CanonicalEffectPlan, count: u8) bool {
    const mode = std.enums.fromInt(CleanupMode, value.cleanup_mode_raw) orelse return false;
    if (count == 0) return mode == .none and value.cleanup_count == 0 and
        std.mem.allEqual(u8, &value.cleanup_callback_provenance_digest, 0);
    return count == 1 and mode == .allocator_free and value.cleanup_count == 1 and
        !std.mem.allEqual(u8, &value.cleanup_callback_provenance_digest, 0);
}

pub fn validCanonicalEffectPlanShape(value: *const CanonicalEffectPlan) bool {
    if (!validEffectRequestShape(value.effect_request) or
        !validReasonProjectionShape(value.first_reason_before) or
        !validReasonProjectionShape(value.first_reason_after) or
        value.unusable_before_raw > 1 or value.unusable_after_raw > 1 or
        std.enums.fromInt(FdDisposition, value.fd_disposition_raw) == null or
        value.close_attempt_count > 1 or
        std.enums.fromInt(OutboundDisposition, value.outbound_disposition_raw) == null or
        !validOutboundShape(value)) return false;

    const action = std.enums.fromInt(EffectAction, value.action_raw) orelse return false;
    const request: EffectRequestTag = @enumFromInt(value.effect_request.tag_raw);
    const relation: OutboundRelation = @enumFromInt(value.outbound_relation_raw);
    const disposition: OutboundDisposition = @enumFromInt(value.outbound_disposition_raw);
    const fd_disposition: FdDisposition = @enumFromInt(value.fd_disposition_raw);
    const before = value.first_reason_before;
    const after = value.first_reason_after;
    const descriptor_absent = relation == .absent;
    const preserved_fd = value.fd_before >= 0 and value.fd_after == value.fd_before and
        fd_disposition == .preserved and value.close_attempt_count == 0;
    const detached_fd = value.fd_before >= 0 and value.fd_after == -1 and
        fd_disposition == .detached_close_attempted and value.close_attempt_count == 1;

    return switch (action) {
        .none => request == .none and before.present_raw == 0 and after.present_raw == 0 and
            value.unusable_before_raw == 0 and value.unusable_after_raw == 0 and preserved_fd and
            ((descriptor_absent and disposition == .absent and cleanupShape(value, 0)) or
                (!descriptor_absent and disposition == .preserved and cleanupShape(value, 0))),
        .poison => request == .poison and value.unusable_before_raw == 0 and value.unusable_after_raw == 1 and
            detached_fd and ((before.present_raw == 0 and reasonEqual(after, value.effect_request.requested_reason)) or
            (before.present_raw == 1 and reasonEqual(before, after))) and
            ((descriptor_absent and disposition == .absent and cleanupShape(value, 0)) or
                (!descriptor_absent and disposition == .freed and cleanupShape(value, 1))),
        .revoke_clean => request == .revoke_fence and before.present_raw == 0 and after.present_raw == 0 and
            value.unusable_before_raw == 0 and value.unusable_after_raw == 0 and preserved_fd and
            ((descriptor_absent and disposition == .absent and cleanupShape(value, 0)) or
                (relation == .sibling and disposition == .preserved and cleanupShape(value, 0))),
        .revoke_cancel => request == .revoke_fence and before.present_raw == 0 and after.present_raw == 0 and
            value.unusable_before_raw == 0 and value.unusable_after_raw == 0 and preserved_fd and
            relation == .target and value.outbound_offset == 0 and disposition == .cancelled and cleanupShape(value, 1),
        .revoke_partial_poison => request == .revoke_fence and value.unusable_before_raw == 0 and
            value.unusable_after_raw == 1 and detached_fd and relation == .target and value.outbound_offset > 0 and
            disposition == .partial_poisoned and cleanupShape(value, 1) and after.present_raw == 1 and
            (before.present_raw == 0 or reasonEqual(before, after)),
        .terminal_cleanup => before.present_raw == 1 and reasonEqual(before, after) and
            value.unusable_before_raw == 1 and value.unusable_after_raw == 1 and
            ((value.fd_before == -1 and value.fd_after == -1 and fd_disposition == .already_detached and
                value.close_attempt_count == 0) or detached_fd) and
            ((descriptor_absent and disposition == .absent and cleanupShape(value, 0)) or
                (!descriptor_absent and disposition == .freed and cleanupShape(value, 1))),
    };
}

pub fn effectPlanFromPermit(value: *const PreparedEffectPermit) CanonicalEffectPlan {
    return .{
        .effect_request = value.effect_request,
        .action_raw = value.action_raw,
        .first_reason_before = value.first_reason_before,
        .first_reason_after = value.first_reason_after,
        .unusable_before_raw = value.unusable_before_raw,
        .unusable_after_raw = value.unusable_after_raw,
        .fd_before = value.fd_before,
        .fd_after = value.fd_after,
        .fd_disposition_raw = value.fd_disposition_raw,
        .close_attempt_count = value.close_attempt_count,
        .outbound_relation_raw = value.outbound_relation_raw,
        .outbound_disposition_raw = value.outbound_disposition_raw,
        .cleanup_mode_raw = value.cleanup_mode_raw,
        .cleanup_count = value.cleanup_count,
        .outbound_offset = value.outbound_offset,
        .outbound_len = value.outbound_len,
        .outbound_descriptor_digest = value.outbound_descriptor_digest,
        .cleanup_callback_provenance_digest = value.cleanup_callback_provenance_digest,
    };
}

pub fn applyEffectPlanToPermit(value: *PreparedEffectPermit, plan: CanonicalEffectPlan) void {
    value.effect_request = plan.effect_request;
    value.action_raw = plan.action_raw;
    value.first_reason_before = plan.first_reason_before;
    value.first_reason_after = plan.first_reason_after;
    value.unusable_before_raw = plan.unusable_before_raw;
    value.unusable_after_raw = plan.unusable_after_raw;
    value.fd_before = plan.fd_before;
    value.fd_after = plan.fd_after;
    value.fd_disposition_raw = plan.fd_disposition_raw;
    value.close_attempt_count = plan.close_attempt_count;
    value.outbound_relation_raw = plan.outbound_relation_raw;
    value.outbound_disposition_raw = plan.outbound_disposition_raw;
    value.cleanup_mode_raw = plan.cleanup_mode_raw;
    value.cleanup_count = plan.cleanup_count;
    value.outbound_offset = plan.outbound_offset;
    value.outbound_len = plan.outbound_len;
    value.outbound_descriptor_digest = plan.outbound_descriptor_digest;
    value.cleanup_callback_provenance_digest = plan.cleanup_callback_provenance_digest;
}

fn hashReason(hasher: *std.crypto.hash.Blake3, value: ReasonProjection) void {
    hashInt(hasher, u8, value.present_raw);
    hashInt(hasher, u8, value.reason_raw);
}

fn hashCanonicalEffectPlan(hasher: *std.crypto.hash.Blake3, value: CanonicalEffectPlan) void {
    hashInt(hasher, u8, value.effect_request.tag_raw);
    hashReason(hasher, value.effect_request.requested_reason);
    hashInt(hasher, u64, value.effect_request.revoke_fence);
    hashInt(hasher, u8, value.action_raw);
    hashReason(hasher, value.first_reason_before);
    hashReason(hasher, value.first_reason_after);
    hashInt(hasher, u8, value.unusable_before_raw);
    hashInt(hasher, u8, value.unusable_after_raw);
    hashInt(hasher, i32, value.fd_before);
    hashInt(hasher, i32, value.fd_after);
    hashInt(hasher, u8, value.fd_disposition_raw);
    hashInt(hasher, u8, value.close_attempt_count);
    hashInt(hasher, u8, value.outbound_relation_raw);
    hashInt(hasher, u8, value.outbound_disposition_raw);
    hashInt(hasher, u8, value.cleanup_mode_raw);
    hashInt(hasher, u8, value.cleanup_count);
    hashInt(hasher, u64, value.outbound_offset);
    hashInt(hasher, u64, value.outbound_len);
    hasher.update(&value.outbound_descriptor_digest);
    hasher.update(&value.cleanup_callback_provenance_digest);
}

fn finishDigest(hasher: *std.crypto.hash.Blake3) Digest {
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn preflightEffectAuthorityDigest(
    plan: CanonicalEffectPlan,
    binding: RuntimeSettlementLeaseBinding,
    effect_out_addr: u64,
    effect_out_extent: u64,
    effect_out_alignment: u64,
    effect_out_pristine_digest: Digest,
) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.effect-preflight-authority.v1\x00");
    hashCanonicalEffectPlan(&hasher, plan);
    hasher.update(&binding.binding_seal);
    hasher.update(&binding.lease_seal_digest);
    hashInt(&hasher, u64, effect_out_addr);
    hashInt(&hasher, u64, effect_out_extent);
    hashInt(&hasher, u64, effect_out_alignment);
    hasher.update(&effect_out_pristine_digest);
    return finishDigest(&hasher);
}

pub fn cleanupCompletionDigest(permit_seal: Digest, plan: CanonicalEffectPlan) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.effect-cleanup-completion.v1\x00");
    hasher.update(&permit_seal);
    // 정리 순서는 fd 닫기 시도 뒤 allocator 정리로 고정한다.
    hasher.update("close\x00");
    hashInt(&hasher, u8, plan.close_attempt_count);
    hashInt(&hasher, i32, plan.fd_before);
    hasher.update("allocator-free\x00");
    hashInt(&hasher, u8, plan.cleanup_count);
    hasher.update(&plan.outbound_descriptor_digest);
    hashCanonicalEffectPlan(&hasher, plan);
    return finishDigest(&hasher);
}

pub fn confirmedEffectDigest(plan: CanonicalEffectPlan, cleanup_completion_digest: Digest) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.confirmed-effect.v1\x00");
    hashCanonicalEffectPlan(&hasher, plan);
    hasher.update(&cleanup_completion_digest);
    return finishDigest(&hasher);
}

pub fn commitEffectAuthorityDigest(
    permit_seal: Digest,
    binding: RuntimeSettlementLeaseBinding,
    effect_out_addr: u64,
    effect_out_extent: u64,
    effect_out_alignment: u64,
    effect_out_pristine_digest: Digest,
    confirmed_effect_digest: Digest,
) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.effect-commit-authority.v1\x00");
    hasher.update(&permit_seal);
    hasher.update(&binding.binding_seal);
    hasher.update(&binding.lease_seal_digest);
    hashInt(&hasher, u64, effect_out_addr);
    hashInt(&hasher, u64, effect_out_extent);
    hashInt(&hasher, u64, effect_out_alignment);
    hasher.update(&effect_out_pristine_digest);
    hasher.update(&confirmed_effect_digest);
    return finishDigest(&hasher);
}

pub fn confirmedOutcomeForAction(action: EffectAction) ConfirmedEffectOutcome {
    return switch (action) {
        .none => .none_confirmed,
        .poison => .poison_confirmed,
        .revoke_clean => .revoke_clean,
        .revoke_cancel => .revoke_cancelled,
        .revoke_partial_poison => .revoke_partial_poisoned,
        .terminal_cleanup => .terminal_cleanup_confirmed,
    };
}

fn evidenceProjectionMatchesPlan(value: *const EffectCommitEvidence, plan: CanonicalEffectPlan) bool {
    const action = std.enums.fromInt(EffectAction, plan.action_raw) orelse return false;
    return value.outcome_raw == @intFromEnum(confirmedOutcomeForAction(action)) and
        value.recovery_raw == @intFromEnum(EffectRecovery.none) and
        std.meta.eql(value.first_reason_before, plan.first_reason_before) and
        std.meta.eql(value.first_reason_after, plan.first_reason_after) and
        value.unusable_before_raw == plan.unusable_before_raw and
        value.unusable_after_raw == plan.unusable_after_raw and
        value.fd_before == plan.fd_before and value.fd_after == plan.fd_after and
        value.fd_disposition_raw == plan.fd_disposition_raw and
        value.close_attempt_count == plan.close_attempt_count and
        value.outbound_relation_raw == plan.outbound_relation_raw and
        value.outbound_disposition_raw == plan.outbound_disposition_raw and
        value.cleanup_mode_raw == plan.cleanup_mode_raw and value.cleanup_count == plan.cleanup_count and
        std.crypto.timing_safe.eql(Digest, value.outbound_descriptor_digest, plan.outbound_descriptor_digest);
}

pub fn publishEffectCommitEvidenceNoFail(
    permit: *const PreparedEffectPermit,
    binding: RuntimeSettlementLeaseBinding,
    out: *EffectCommitEvidence,
) void {
    if (!validPreparedEffectPermit(permit) or permit.consumed_raw != 0 or
        permit.effect_out_addr != @intFromPtr(out) or !std.meta.eql(out.*, EffectCommitEvidence{}))
        @panic("C3-3b3 effect evidence authority drifted after admission");
    const plan = effectPlanFromPermit(permit);
    const cleanup_digest = cleanupCompletionDigest(permit.seal, plan);
    const confirmed_digest = confirmedEffectDigest(plan, cleanup_digest);
    const authority_digest = commitEffectAuthorityDigest(
        permit.seal,
        binding,
        permit.effect_out_addr,
        permit.effect_out_extent,
        permit.effect_out_alignment,
        permit.effect_out_pristine_digest,
        confirmed_digest,
    );
    out.* = .{
        .self_addr = @intFromPtr(out),
        .outcome_raw = @intFromEnum(confirmedOutcomeForAction(@enumFromInt(plan.action_raw))),
        .pid = permit.pid,
        .process_nonce = permit.process_nonce,
        .thread_id = permit.thread_id,
        .pending_owner_addr = permit.pending_owner_addr,
        .owner_incarnation = permit.owner_incarnation,
        .attempt = permit.attempt,
        .event_generation = permit.event_generation,
        .first_reason_before = plan.first_reason_before,
        .first_reason_after = plan.first_reason_after,
        .unusable_before_raw = plan.unusable_before_raw,
        .unusable_after_raw = plan.unusable_after_raw,
        .fd_disposition_raw = plan.fd_disposition_raw,
        .close_attempt_count = plan.close_attempt_count,
        .outbound_relation_raw = plan.outbound_relation_raw,
        .outbound_disposition_raw = plan.outbound_disposition_raw,
        .cleanup_mode_raw = plan.cleanup_mode_raw,
        .fd_before = plan.fd_before,
        .fd_after = plan.fd_after,
        .cleanup_count = plan.cleanup_count,
        .commit_authority_digest = authority_digest,
        .outbound_descriptor_digest = plan.outbound_descriptor_digest,
        .cleanup_completion_digest = cleanup_digest,
        .confirmed_effect_digest = confirmed_digest,
    };
    out.seal = sealEffectCommitEvidence(out.*) catch
        @panic("C3-3b3 effect evidence seal service unavailable after admission");
    out.lifecycle_raw = @intFromEnum(AuthorityLifecycle.prepared);
}

pub fn validEffectCommitEvidenceFor(
    permit: *const PreparedEffectPermit,
    binding: RuntimeSettlementLeaseBinding,
    value: *const EffectCommitEvidence,
) bool {
    if (!validPreparedEffectPermit(permit) or !validEffectCommitEvidence(value) or
        permit.effect_out_addr != @intFromPtr(value) or
        value.pending_owner_addr != permit.pending_owner_addr or value.owner_incarnation != permit.owner_incarnation or
        value.attempt != permit.attempt or value.event_generation != permit.event_generation)
        return false;
    const plan = effectPlanFromPermit(permit);
    if (!evidenceProjectionMatchesPlan(value, plan)) return false;
    const cleanup_digest = cleanupCompletionDigest(permit.seal, plan);
    if (!std.crypto.timing_safe.eql(Digest, cleanup_digest, value.cleanup_completion_digest)) return false;
    const confirmed_digest = confirmedEffectDigest(plan, cleanup_digest);
    if (!std.crypto.timing_safe.eql(Digest, confirmed_digest, value.confirmed_effect_digest)) return false;
    const authority = commitEffectAuthorityDigest(
        permit.seal,
        binding,
        permit.effect_out_addr,
        permit.effect_out_extent,
        permit.effect_out_alignment,
        permit.effect_out_pristine_digest,
        confirmed_digest,
    );
    return std.crypto.timing_safe.eql(Digest, authority, value.commit_authority_digest);
}

pub fn validPreparedEffectPermit(value: *const PreparedEffectPermit) bool {
    const plan = effectPlanFromPermit(value);
    if (value.self_addr != @intFromPtr(value) or value.lifecycle_raw != @intFromEnum(AuthorityLifecycle.prepared) or
        value.consumed_raw != 0 or value.pid == 0 or value.reserved_pid != 0 or value.process_nonce == 0 or
        value.thread_id == 0 or value.pending_owner_addr == 0 or value.owner_incarnation == 0 or value.attempt == 0 or
        value.event_generation == 0 or
        value.slot_incarnation == 0 or value.node_incarnation == 0 or value.binding_incarnation == 0 or
        value.transport_incarnation == 0 or value.operation_node_addr == 0 or value.operation_id == 0 or
        value.target_stream_id == 0 or
        std.mem.allEqual(u8, &value.correlation_digest, 0) or
        std.mem.allEqual(u8, &value.prepared_effect_digest, 0) or
        !validCanonicalEffectPlanShape(&plan) or
        value.effect_out_addr == 0 or value.effect_out_extent != @sizeOf(EffectCommitEvidence) or
        value.effect_out_alignment != @alignOf(EffectCommitEvidence) or value.effect_out_addr % value.effect_out_alignment != 0 or
        std.mem.allEqual(u8, &value.effect_out_pristine_digest, 0) or
        std.mem.allEqual(u8, &value.scratch_ranges_digest, 0) or
        std.mem.allEqual(u8, &value.scratch_pristine_digest, 0) or
        std.mem.allEqual(u8, &value.preflight_proof_seal_digest, 0) or
        std.mem.allEqual(u8, &value.lease_seal_digest, 0) or
        std.mem.allEqual(u8, &value.preflight_authority_digest, 0) or
        !std.mem.allEqual(u8, &value.reserved, 0) or !std.mem.allEqual(u8, &value.reserved_operation, 0) or
        !std.mem.allEqual(u8, &value.reserved_action, 0) or
        !std.mem.allEqual(u8, &value.reserved_outbound, 0)) return false;
    const expected = sealPreparedEffectPermit(value.*) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn validScratchPreflightProof(value: SettlementScratchPreflightProof) bool {
    if (value.pid == 0 or value.reserved != 0 or value.process_nonce == 0 or value.thread_id == 0 or
        std.mem.allEqual(u8, &value.ranges_digest, 0) or std.mem.allEqual(u8, &value.pristine_digest, 0)) return false;
    const expected = sealScratchPreflightProof(value) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.proof_seal);
}

pub fn sealRuntimeSettlementLease(
    pid: u32,
    process_nonce: u64,
    lease_addr: u64,
    lease_extent: u64,
    lease_alignment: u64,
    operation: seal_types.RuntimeOperationIdentity,
    ranges_digest: Digest,
    pristine_digest: Digest,
    proof_seal_digest: Digest,
) process_seal.ReadyError!Digest {
    return process_seal.runtimeSettlementLeaseSeal(pid, process_nonce, .{
        .lease_addr = lease_addr,
        .lease_extent = lease_extent,
        .lease_alignment = lease_alignment,
        .operation = operation,
        .ranges_digest = ranges_digest,
        .pristine_digest = pristine_digest,
        .preflight_proof_seal_digest = proof_seal_digest,
    });
}

pub fn sealRuntimeSettlementBinding(value: RuntimeSettlementLeaseBinding) process_seal.ReadyError!Digest {
    return process_seal.runtimeSettlementBindingSeal(value.operation_identity.pid, value.operation_identity.process_nonce, .{
        .lease_addr = value.lease_addr,
        .lifetime_owner_addr = value.lifetime_owner_addr,
        .operation = value.operation_identity,
        .ranges_digest = value.ranges_digest,
        .pristine_digest = value.pristine_digest,
        .preflight_proof_seal_digest = value.preflight_proof_seal_digest,
        .lease_seal_digest = value.lease_seal_digest,
    });
}

pub fn validRuntimeSettlementBinding(value: RuntimeSettlementLeaseBinding) bool {
    if (value.lease_addr == 0 or value.lifetime_owner_addr == 0 or
        value.operation_identity.lifetime_owner_addr != value.lifetime_owner_addr or
        value.operation_identity.runtime_addr == 0 or value.operation_identity.pending_owner_addr == 0 or
        value.operation_identity.pid == 0 or value.operation_identity.pid != process_seal.currentProcessId() or
        value.operation_identity.reserved_pid != 0 or value.operation_identity.process_nonce == 0 or
        value.operation_identity.thread_id == 0 or
        value.operation_identity.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
        value.operation_identity.owner_incarnation == 0 or value.operation_identity.operation_incarnation == 0 or
        value.operation_identity.operation_kind_raw != 3 or
        std.mem.allEqual(u8, &value.operation_identity.operation_seal, 0) or
        std.mem.allEqual(u8, &value.ranges_digest, 0) or
        std.mem.allEqual(u8, &value.pristine_digest, 0) or
        std.mem.allEqual(u8, &value.preflight_proof_seal_digest, 0) or
        std.mem.allEqual(u8, &value.lease_seal_digest, 0)) return false;
    const expected = sealRuntimeSettlementBinding(value) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.binding_seal);
}

pub fn sealPendingSettlementPermit(value: PreparedPendingSettlementPermit) process_seal.ReadyError!Digest {
    return process_seal.pendingSettlementPermitSeal(value.pid, value.process_nonce, permitSealInput(value));
}

pub fn validPendingSettlementPermit(value: *const PreparedPendingSettlementPermit) bool {
    if (value.self_addr != @intFromPtr(value) or value.lifecycle_raw != @intFromEnum(AuthorityLifecycle.prepared) or
        value.consumed_raw != 0 or value.pid == 0 or value.process_nonce == 0 or value.thread_id == 0 or
        !std.mem.allEqual(u8, &value.reserved, 0)) return false;
    const expected = sealPendingSettlementPermit(value.*) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn sealEffectCommitEvidence(value: EffectCommitEvidence) process_seal.ReadyError!Digest {
    return process_seal.effectCommitEvidenceSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .pending_owner_addr = value.pending_owner_addr,
        .owner_incarnation = value.owner_incarnation,
        .attempt = value.attempt,
        .event_generation = value.event_generation,
        .outcome_raw = value.outcome_raw,
        .recovery_raw = value.recovery_raw,
        .first_reason_before_present_raw = value.first_reason_before.present_raw,
        .first_reason_before_raw = value.first_reason_before.reason_raw,
        .first_reason_after_present_raw = value.first_reason_after.present_raw,
        .first_reason_after_raw = value.first_reason_after.reason_raw,
        .unusable_before_raw = value.unusable_before_raw,
        .unusable_after_raw = value.unusable_after_raw,
        .fd_before = value.fd_before,
        .fd_after = value.fd_after,
        .fd_disposition_raw = value.fd_disposition_raw,
        .close_attempt_count = value.close_attempt_count,
        .outbound_relation_raw = value.outbound_relation_raw,
        .outbound_disposition_raw = value.outbound_disposition_raw,
        .cleanup_mode_raw = value.cleanup_mode_raw,
        .cleanup_count = value.cleanup_count,
        .outbound_descriptor_digest = value.outbound_descriptor_digest,
        .cleanup_completion_digest = value.cleanup_completion_digest,
        .confirmed_effect_digest = value.confirmed_effect_digest,
        .commit_authority_digest = value.commit_authority_digest,
    });
}

pub fn validEffectCommitEvidence(value: *const EffectCommitEvidence) bool {
    if (value.self_addr != @intFromPtr(value) or value.lifecycle_raw != @intFromEnum(AuthorityLifecycle.prepared) or
        value.consumed_raw != 0 or
        value.pid == 0 or value.reserved_pid != 0 or value.process_nonce == 0 or value.thread_id == 0 or
        value.pending_owner_addr == 0 or value.owner_incarnation == 0 or value.attempt == 0 or value.event_generation == 0 or
        std.enums.fromInt(ConfirmedEffectOutcome, value.outcome_raw) == null or
        std.enums.fromInt(EffectRecovery, value.recovery_raw) == null or
        !validReasonProjectionShape(value.first_reason_before) or
        !validReasonProjectionShape(value.first_reason_after) or
        value.unusable_before_raw > 1 or value.unusable_after_raw > 1 or
        std.enums.fromInt(FdDisposition, value.fd_disposition_raw) == null or value.close_attempt_count > 1 or
        std.enums.fromInt(OutboundRelation, value.outbound_relation_raw) == null or
        std.enums.fromInt(OutboundDisposition, value.outbound_disposition_raw) == null or
        std.enums.fromInt(CleanupMode, value.cleanup_mode_raw) == null or value.cleanup_count > 1 or
        std.mem.allEqual(u8, &value.cleanup_completion_digest, 0) or
        std.mem.allEqual(u8, &value.confirmed_effect_digest, 0) or
        std.mem.allEqual(u8, &value.commit_authority_digest, 0) or
        !std.mem.allEqual(u8, &value.reserved, 0) or !std.mem.allEqual(u8, &value.reserved_count, 0) or
        !std.mem.allEqual(u8, &value.reserved_effect, 0)) return false;
    const outcome: ConfirmedEffectOutcome = @enumFromInt(value.outcome_raw);
    const recovery: EffectRecovery = @enumFromInt(value.recovery_raw);
    if (recovery == .trusted_local_invariant and outcome != .poison_confirmed) return false;
    const expected = sealEffectCommitEvidence(value.*) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn sealEventReleaseCompletion(value: EventReleaseCompletion) process_seal.ReadyError!Digest {
    return process_seal.eventReleaseCompletionSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .registry_incarnation = value.registry_incarnation,
        .binding_reservation_id = value.binding_reservation_id,
        .event_node_incarnation = value.event_node_incarnation,
        .stream_id = value.stream_id,
        .event_generation = value.event_generation,
        .event_owner_addr = value.event_owner_addr,
        .pending_owner_addr = value.pending_owner_addr,
        .pending_owner_incarnation = value.owner_incarnation,
        .source_lease_incarnation = value.source_lease_incarnation,
        .attempt = value.attempt,
        .ordering_class_raw = value.ordering_class_raw,
        .consumed_blocker_count = value.consumed_blocker_count,
        .freed_payload_count = value.freed_payload_count,
        .consumed_pin_count = value.consumed_pin_count,
        .settled_quarantine_count = value.settled_quarantine_count,
        .post_transcript_digest = value.post_transcript_digest,
        .release_receipt_digest = value.release_receipt_digest,
        .permit_digest = value.permit_digest,
        .authority_digest = value.authority_digest,
    });
}

pub fn validEventReleaseCompletion(value: *const EventReleaseCompletion) bool {
    if (value.self_addr != @intFromPtr(value) or value.lifecycle_raw != @intFromEnum(AuthorityLifecycle.prepared) or
        value.pid == 0 or value.reserved_pid != 0 or value.process_nonce == 0 or value.thread_id == 0 or
        value.outcome_raw != 0 or value.detail_raw != 0 or value.registry_incarnation == 0 or
        value.binding_reservation_id == 0 or value.event_node_incarnation == 0 or value.stream_id == 0 or
        value.event_generation == 0 or value.event_owner_addr == 0 or value.pending_owner_addr == 0 or
        value.owner_incarnation == 0 or value.source_lease_incarnation == 0 or value.attempt == 0 or
        (value.ordering_class_raw != 1 and value.ordering_class_raw != 2) or
        value.consumed_blocker_count != 1 or value.freed_payload_count != 1 or
        value.consumed_pin_count != 1 or value.settled_quarantine_count != 1 or
        std.mem.allEqual(u8, &value.post_transcript_digest, 0) or
        std.mem.allEqual(u8, &value.release_receipt_digest, 0) or
        std.mem.allEqual(u8, &value.permit_digest, 0) or std.mem.allEqual(u8, &value.authority_digest, 0) or
        !std.mem.allEqual(u8, &value.reserved, 0) or !std.mem.allEqual(u8, &value.reserved_count, 0) or
        !std.mem.allEqual(u8, &value.reserved_ordering, 0)) return false;
    const authority = eventReleaseCompletionAuthorityDigest(value.*);
    if (!std.crypto.timing_safe.eql(Digest, authority, value.authority_digest)) return false;
    const expected = sealEventReleaseCompletion(value.*) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn eventReleaseCompletionAuthorityDigest(value: EventReleaseCompletion) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.event-release-completion-authority.v2");
    inline for (.{
        value.registry_incarnation,          value.binding_reservation_id,       value.event_node_incarnation,
        value.stream_id,                     value.event_generation,             value.event_owner_addr,
        value.pending_owner_addr,            value.owner_incarnation,            value.source_lease_incarnation,
        value.attempt,                       @as(u64, value.ordering_class_raw), @as(u64, value.consumed_blocker_count),
        @as(u64, value.freed_payload_count), @as(u64, value.consumed_pin_count), @as(u64, value.settled_quarantine_count),
    }) |scalar| hashInt(&hasher, u64, scalar);
    hasher.update(&value.release_receipt_digest);
    hasher.update(&value.permit_digest);
    hasher.update(&value.post_transcript_digest);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn sealPreparedEventReleasePermit(value: PreparedEventReleasePermit) process_seal.ReadyError!Digest {
    return process_seal.preparedEventReleasePermitSeal(value.pid, value.process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .registry_addr = value.registry_addr,
        .registry_incarnation = value.registry_incarnation,
        .binding_reservation_id = value.binding_reservation_id,
        .entry_index = value.entry_index,
        .event_node_incarnation = value.event_node_incarnation,
        .stream_id = value.stream_id,
        .event_generation = value.event_generation,
        .event_owner_addr = value.event_owner_addr,
        .pending_owner_addr = value.pending_owner_addr,
        .pending_owner_incarnation = value.pending_owner_incarnation,
        .attempt = value.attempt,
        .source_lease_incarnation = value.source_lease_incarnation,
        .ordering_class_raw = value.ordering_class_raw,
        .expected_blocker_count = value.expected_blocker_count,
        .completion_addr = value.completion_addr,
        .completion_extent = value.completion_extent,
        .completion_alignment = value.completion_alignment,
        .completion_pristine_digest = value.completion_pristine_digest,
        .begun_addr = value.begun_addr,
        .begun_extent = value.begun_extent,
        .begun_alignment = value.begun_alignment,
        .begun_pristine_digest = value.begun_pristine_digest,
        .scratch_ranges_digest = value.scratch_ranges_digest,
        .scratch_pristine_digest = value.scratch_pristine_digest,
        .preflight_proof_seal_digest = value.preflight_proof_seal_digest,
        .lease_seal_digest = value.lease_seal_digest,
        .release_receipt_digest = value.release_receipt_digest,
        .event_owner_seal = value.event_owner_seal,
        .payload_addr = value.payload_addr,
        .payload_len = value.payload_len,
        .payload_digest = value.payload_digest,
        .allocator_ptr = value.allocator_ptr,
        .allocator_vtable = value.allocator_vtable,
        .pin_owner_addr = value.pin_owner_addr,
        .lease_addr = value.lease_addr,
        .slot_addr = value.slot_addr,
        .node_addr = value.node_addr,
        .pin_slot_incarnation = value.pin_slot_incarnation,
        .pin_node_incarnation = value.pin_node_incarnation,
        .host_id = value.host_id,
        .connection_generation = value.connection_generation,
        .pin_process_nonce = value.pin_process_nonce,
        .quarantine_slot_index = value.quarantine_slot_index,
        .quarantine_reservation_generation = value.quarantine_reservation_generation,
        .source_authority_digest = value.source_authority_digest,
    });
}

pub fn eventReleaseSourceAuthorityDigest(value: PreparedEventReleasePermit) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.event-release-source-authority.v2\x00");
    inline for (.{
        value.event_owner_addr,  value.payload_addr,                    value.payload_len,                       value.allocator_ptr,
        value.allocator_vtable,  value.pin_owner_addr,                  value.lease_addr,                        value.slot_addr,
        value.node_addr,         value.pin_slot_incarnation,            value.pin_node_incarnation,              value.connection_generation,
        value.pin_process_nonce, @as(u64, value.quarantine_slot_index), value.quarantine_reservation_generation,
    }) |scalar| hashInt(&hasher, u64, scalar);
    hashInt(&hasher, u128, value.host_id);
    hasher.update(&value.event_owner_seal);
    hasher.update(&value.payload_digest);
    hasher.update(&value.release_receipt_digest);
    return finishDigest(&hasher);
}

pub fn eventReleasePostTranscriptDigest(
    permit_seal: Digest,
    post: EventReleasePostProjection,
) ?Digest {
    if (std.mem.allEqual(u8, &permit_seal, 0) or post.callback_invocation_count != 1 or
        post.source_tombstone_count != 1) return null;
    inline for (.{
        post.registry_closed_digest,
        post.quarantine_closed_digest,
        post.pin_consumed_digest,
        post.callback_invoked_digest,
        post.owner_tombstoned_digest,
        post.correlation_tombstoned_digest,
        post.mirror_tombstoned_digest,
    }) |digest| if (std.mem.allEqual(u8, &digest, 0)) return null;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.event-release-post-transcript.v1\x00");
    hasher.update(&permit_seal);
    inline for (.{
        post.registry_closed_digest,
        post.quarantine_closed_digest,
        post.pin_consumed_digest,
        post.callback_invoked_digest,
        post.owner_tombstoned_digest,
        post.correlation_tombstoned_digest,
        post.mirror_tombstoned_digest,
    }) |digest| hasher.update(&digest);
    hashInt(&hasher, u8, post.callback_invocation_count);
    hashInt(&hasher, u8, post.source_tombstone_count);
    return finishDigest(&hasher);
}

pub fn validEventReleasePostTranscript(
    permit_seal: Digest,
    post: EventReleasePostProjection,
    expected_digest: Digest,
) bool {
    const actual = eventReleasePostTranscriptDigest(permit_seal, post) orelse return false;
    return std.crypto.timing_safe.eql(Digest, actual, expected_digest);
}

pub fn validEventReleasePostCompletionContext(
    permit_seal: Digest,
    post: EventReleasePostProjection,
    completion: EventReleaseCompletion,
) bool {
    return std.crypto.timing_safe.eql(Digest, permit_seal, completion.permit_digest) and
        validEventReleasePostTranscript(permit_seal, post, completion.post_transcript_digest) and
        std.crypto.timing_safe.eql(
            Digest,
            eventReleaseCompletionAuthorityDigest(completion),
            completion.authority_digest,
        );
}
pub fn validEventReleasePostContext(context: EventReleasePostContext, post: EventReleasePostProjection, completion: EventReleaseCompletion) bool {
    if (!validEventReleaseLeafReceipt(context.registry, .registry) or !validEventReleaseLeafReceipt(context.quarantine, .quarantine) or
        !validEventReleaseLeafReceipt(context.pin, .pin) or !validEventReleasePhaseReceipt(context.owner, .owner) or
        !validEventReleasePhaseReceipt(context.correlation, .correlation) or !validEventReleasePhaseReceipt(context.mirror, .mirror) or
        !validEventReleasePhaseReceipt(context.callback, .callback)) return false;
    if (context.registry.identity_a != context.registry_incarnation or context.registry.identity_b != context.binding_reservation_id or
        context.registry.identity_c != context.event_node_incarnation or context.registry.identity_d != context.event_generation or
        context.quarantine.identity_c != context.event_node_incarnation or context.quarantine.identity_d != context.event_owner_addr or
        context.quarantine.identity_a != context.quarantine_slot_index or context.quarantine.identity_b != context.quarantine_reservation_generation or
        context.pin.identity_a != context.pin_owner_addr or context.pin.identity_b != context.lease_addr or
        context.pin.identity_c != context.pin_node_incarnation or context.pin.identity_d != context.pin_stream_id or
        context.pin.identity_e != context.pin_slot_addr or context.pin.identity_f != context.pin_connection_generation or
        context.quarantine.before_b - context.quarantine.after_b != context.payload_len or
        context.owner.event_owner_addr != context.event_owner_addr or context.owner.event_generation != context.event_generation or
        !std.crypto.timing_safe.eql(Digest, context.owner.before_digest, context.owner_pre_seal) or
        !std.crypto.timing_safe.eql(Digest, context.correlation.before_digest, context.correlation_pre_digest) or
        !std.crypto.timing_safe.eql(Digest, context.mirror.before_digest, context.mirror_pre_digest))
        return false;
    inline for (.{ context.owner, context.correlation, context.mirror, context.callback }) |receipt|
        if (!std.crypto.timing_safe.eql(Digest, receipt.permit_seal, context.permit_seal) or
            receipt.begun_addr != context.begun_addr or receipt.event_owner_addr != context.event_owner_addr or
            receipt.event_generation != context.event_generation or !std.crypto.timing_safe.eql(Digest, receipt.after_digest, canonicalEventReleasePhaseAfterDigest(@enumFromInt(receipt.role_raw), receipt.begun_addr, receipt.event_owner_addr, receipt.event_generation, receipt.lifecycle_after_raw))) return false;
    if (!std.crypto.timing_safe.eql(Digest, context.callback.before_digest, context.callback.tls_begun_seal) or
        context.callback.begun_addr != context.begun_addr) return false;
    return std.crypto.timing_safe.eql(Digest, post.registry_closed_digest, context.registry.seal) and
        std.crypto.timing_safe.eql(Digest, post.quarantine_closed_digest, context.quarantine.seal) and
        std.crypto.timing_safe.eql(Digest, post.pin_consumed_digest, context.pin.seal) and
        std.crypto.timing_safe.eql(Digest, post.owner_tombstoned_digest, context.owner.seal) and
        std.crypto.timing_safe.eql(Digest, post.correlation_tombstoned_digest, context.correlation.seal) and
        std.crypto.timing_safe.eql(Digest, post.mirror_tombstoned_digest, context.mirror.seal) and
        std.crypto.timing_safe.eql(Digest, post.callback_invoked_digest, context.callback.seal) and
        validEventReleasePostCompletionContext(context.permit_seal, post, completion);
}

pub fn validPreparedEventReleasePermit(value: *const PreparedEventReleasePermit) bool {
    if (value.self_addr != @intFromPtr(value) or
        value.lifecycle_raw != @intFromEnum(AuthorityLifecycle.prepared) or value.consumed_raw != 0 or
        value.pid == 0 or value.reserved_pid != 0 or value.process_nonce == 0 or value.thread_id == 0 or
        value.registry_addr == 0 or value.registry_incarnation == 0 or value.binding_reservation_id == 0 or
        value.event_node_incarnation == 0 or value.stream_id == 0 or value.event_generation == 0 or
        value.event_owner_addr == 0 or value.pending_owner_addr == 0 or value.pending_owner_incarnation == 0 or
        value.source_lease_incarnation == 0 or value.attempt == 0 or
        (value.ordering_class_raw != 1 and value.ordering_class_raw != 2) or value.expected_blocker_count == 0 or
        value.completion_addr == 0 or value.completion_extent != @sizeOf(EventReleaseCompletion) or
        value.completion_alignment != @alignOf(EventReleaseCompletion) or
        value.completion_addr % value.completion_alignment != 0 or
        std.mem.allEqual(u8, &value.completion_pristine_digest, 0) or
        value.begun_addr == 0 or value.begun_extent == 0 or value.begun_alignment == 0 or
        value.begun_addr % value.begun_alignment != 0 or
        std.mem.allEqual(u8, &value.begun_pristine_digest, 0) or
        std.mem.allEqual(u8, &value.scratch_ranges_digest, 0) or
        std.mem.allEqual(u8, &value.scratch_pristine_digest, 0) or
        std.mem.allEqual(u8, &value.preflight_proof_seal_digest, 0) or
        std.mem.allEqual(u8, &value.lease_seal_digest, 0) or
        std.mem.allEqual(u8, &value.release_receipt_digest, 0) or
        std.mem.allEqual(u8, &value.event_owner_seal, 0) or value.payload_addr == 0 or value.payload_len == 0 or
        // Stateless allocators (including the product allocator used by the macOS app) legally
        // carry a zero context pointer. The vtable is the presence discriminator; the context is
        // still sealed and must match the quarantine mirror exactly throughout release.
        std.mem.allEqual(u8, &value.payload_digest, 0) or value.allocator_vtable == 0 or
        value.pin_owner_addr == 0 or value.lease_addr == 0 or value.slot_addr == 0 or value.node_addr == 0 or
        value.pin_slot_incarnation == 0 or value.pin_node_incarnation == 0 or value.host_id == 0 or
        value.connection_generation == 0 or value.pin_process_nonce == 0 or
        value.quarantine_reservation_generation == 0 or std.mem.allEqual(u8, &value.source_authority_digest, 0) or
        !std.mem.allEqual(u8, &value.reserved, 0) or !std.mem.allEqual(u8, &value.reserved_entry, 0) or
        !std.mem.allEqual(u8, &value.reserved_ordering, 0) or
        !std.mem.allEqual(u8, &value.reserved_quarantine, 0)) return false;
    const source_authority = eventReleaseSourceAuthorityDigest(value.*);
    if (!std.crypto.timing_safe.eql(Digest, source_authority, value.source_authority_digest)) return false;
    const expected = sealPreparedEventReleasePermit(value.*) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.seal);
}

pub fn validPendingRegistryReleaseReceipt(value: PendingRegistryReleaseReceipt) bool {
    if (value.state_raw != 1 or value.pending_owner_addr == 0 or value.pending_owner_incarnation == 0 or
        value.source_lease_incarnation == 0 or value.attempt == 0 or
        !std.mem.allEqual(u8, &value.reserved, 0)) return false;
    const expected = process_seal.pendingReleaseSeal(value.event_identity.pid, value.event_identity.process_nonce, .{
        .event_identity = value.event_identity,
        .pending_owner_addr = value.pending_owner_addr,
        .pending_owner_incarnation = value.pending_owner_incarnation,
        .source_lease_incarnation = value.source_lease_incarnation,
        .attempt = value.attempt,
        .state_raw = value.state_raw,
        .reserved = value.reserved,
    }) catch return false;
    return std.crypto.timing_safe.eql(Digest, expected, value.release_seal);
}

pub fn sealSettlementDisposition(value: SettlementDisposition, pid: u32, process_nonce: u64) process_seal.ReadyError!Digest {
    return process_seal.settlementDispositionSeal(pid, process_nonce, .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .pending_owner_addr = value.pending_owner_addr,
        .owner_incarnation = value.owner_incarnation,
        .attempt = value.attempt,
        .event_generation = value.event_generation,
        .disposition_raw = value.disposition_raw,
        .effect_evidence_digest = value.effect_evidence_digest,
        .registry_completion_digest = value.registry_completion_digest,
        .consumed_receipt_digest = value.consumed_receipt_digest,
    });
}

fn permitSealInput(value: PreparedPendingSettlementPermit) process_seal.PendingSettlementPermitSealInput {
    return .{
        .self_addr = value.self_addr,
        .thread_id = value.thread_id,
        .pending_owner_addr = value.pending_owner_addr,
        .owner_incarnation = value.owner_incarnation,
        .attempt = value.attempt,
        .source_lease_incarnation = value.source_lease_incarnation,
        .event_generation = value.event_generation,
        .effect_out_addr = value.effect_out_addr,
        .release_out_addr = value.release_out_addr,
        .disposition_addr = value.disposition_addr,
        .ranges_digest = value.scratch_ranges_digest,
        .pristine_digest = value.scratch_pristine_digest,
        .preflight_proof_seal_digest = value.preflight_proof_seal_digest,
        .lease_seal_digest = value.lease_seal_digest,
        .release_receipt_digest = value.release_receipt_digest,
    };
}

pub fn pristineEventReleaseCompletionDigest() Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.event-release-completion-pristine.v2");
    const value = EventReleaseCompletion{};
    hashInt(&hasher, u64, value.self_addr);
    hashInt(&hasher, u8, value.lifecycle_raw);
    hashInt(&hasher, u8, value.outcome_raw);
    hashInt(&hasher, u8, value.detail_raw);
    hasher.update(&value.reserved);
    hashInt(&hasher, u32, value.pid);
    hashInt(&hasher, u32, value.reserved_pid);
    hashInt(&hasher, u64, value.process_nonce);
    hashInt(&hasher, u64, value.thread_id);
    hashInt(&hasher, u64, value.pending_owner_addr);
    hashInt(&hasher, u64, value.owner_incarnation);
    hashInt(&hasher, u64, value.attempt);
    hashInt(&hasher, u64, value.event_generation);
    hashInt(&hasher, u64, value.registry_incarnation);
    hashInt(&hasher, u64, value.binding_reservation_id);
    hashInt(&hasher, u64, value.event_node_incarnation);
    hashInt(&hasher, u64, value.stream_id);
    hashInt(&hasher, u64, value.event_owner_addr);
    hashInt(&hasher, u64, value.source_lease_incarnation);
    hashInt(&hasher, u8, value.ordering_class_raw);
    hasher.update(&value.reserved_ordering);
    hasher.update(&value.release_receipt_digest);
    hasher.update(&value.permit_digest);
    hashInt(&hasher, u16, value.consumed_blocker_count);
    hashInt(&hasher, u8, value.freed_payload_count);
    hashInt(&hasher, u8, value.consumed_pin_count);
    hashInt(&hasher, u8, value.settled_quarantine_count);
    hasher.update(&value.reserved_count);
    hasher.update(&value.post_transcript_digest);
    hasher.update(&value.authority_digest);
    hasher.update(&value.seal);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn pristineEffectCommitEvidenceDigest() Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.effect-commit-evidence-pristine.v1");
    const value = EffectCommitEvidence{};
    hashInt(&hasher, u64, value.self_addr);
    hashInt(&hasher, u8, value.lifecycle_raw);
    hashInt(&hasher, u8, value.consumed_raw);
    hashInt(&hasher, u8, value.outcome_raw);
    hashInt(&hasher, u8, value.recovery_raw);
    hasher.update(&value.reserved);
    hashInt(&hasher, u32, value.pid);
    hashInt(&hasher, u32, value.reserved_pid);
    hashInt(&hasher, u64, value.process_nonce);
    hashInt(&hasher, u64, value.thread_id);
    hashInt(&hasher, u64, value.pending_owner_addr);
    hashInt(&hasher, u64, value.owner_incarnation);
    hashInt(&hasher, u64, value.attempt);
    hashInt(&hasher, u64, value.event_generation);
    hashReason(&hasher, value.first_reason_before);
    hashReason(&hasher, value.first_reason_after);
    hashInt(&hasher, u8, value.unusable_before_raw);
    hashInt(&hasher, u8, value.unusable_after_raw);
    hashInt(&hasher, u8, value.fd_disposition_raw);
    hashInt(&hasher, u8, value.close_attempt_count);
    hashInt(&hasher, u8, value.outbound_relation_raw);
    hashInt(&hasher, u8, value.outbound_disposition_raw);
    hashInt(&hasher, u8, value.cleanup_mode_raw);
    hasher.update(&value.reserved_effect);
    hashInt(&hasher, i32, value.fd_before);
    hashInt(&hasher, i32, value.fd_after);
    hashInt(&hasher, u8, value.cleanup_count);
    hasher.update(&value.reserved_count);
    hasher.update(&value.commit_authority_digest);
    hasher.update(&value.outbound_descriptor_digest);
    hasher.update(&value.cleanup_completion_digest);
    hasher.update(&value.confirmed_effect_digest);
    hasher.update(&value.seal);
    return finishDigest(&hasher);
}

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}
