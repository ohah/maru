//! Pointer-free cleanup ownership transcripts used by the session-host preparation path.
//!
//! This leaf owns canonical fixed-width encoding only. It deliberately has no process secret,
//! allocator, runtime, PTY, or event authority dependency; the process seal service adds keyed
//! authentication and higher layers project their concrete owners into these neutral values.

const std = @import("std");
const builtin = @import("builtin");
const decision_seal = @import("runtime_prepared_decision_seal.zig");

pub const CleanupSeal = [32]u8;
pub const Digest = [32]u8;

pub const TerminalCleanupIdentitySealInput = struct {
    self_addr: u64,
    thread_id: u64,
    node_addr: u64,
    node_incarnation: u64,
    registry_incarnation: u64,
    connection_generation: u64,
    stream_id: u64,
    token_count: u32,
    ordered_token_digest: Digest,
    surviving_descriptor_count: u32,
    quarantined_descriptor_count: u32,
    accounting_count: u32,
    accounting_bytes: u64,
    request_generation: u64,
};

pub const TerminalCleanupStateSealInput = struct {
    self_addr: u64,
    lifecycle_raw: u8,
    state_generation: u64,
    identity_seal: CleanupSeal,
};

pub const TerminalDrainIdentitySealInput = struct {
    self_addr: u64,
    thread_id: u64,
    node_addr: u64,
    node_incarnation: u64,
    registry_incarnation: u64,
    handoff_identity_seal: CleanupSeal,
    handoff_state_seal: CleanupSeal,
    handoff_state_generation: u64,
    row_slot: u16,
    row_kind_raw: u8,
    row_generation: u64,
    accounting_client_addr: u64,
    accounting_transfer_id: u64,
    accounting_byte_count: u64,
    payload_addr: u64,
    payload_len: u64,
    allocator_ptr: u64,
    allocator_vtable: u64,
    callback_ordinal: u32,
};

pub const TerminalDrainStateSealInput = struct {
    self_addr: u64,
    lifecycle_raw: u8,
    state_generation: u64,
    identity_seal: CleanupSeal,
};

pub const CloseAuthorityIdentitySealInput = struct {
    self_addr: u64,
    thread_id: u64,
    runtime_addr: u64,
    handle: u64,
    runtime_generation: u64,
    host_id: u128,
    close_request_generation: u64,
    close_schedule_ticket: u64,
    request_kind_raw: u8,
    disposition_raw: u8,
};

pub const CloseAuthorityStateSealInput = struct {
    self_addr: u64,
    state_generation: u64,
    lifecycle_raw: u8,
    identity_seal: CleanupSeal,
};

pub const CloseOperationPinSealInput = struct {
    self_addr: u64,
    backend_addr: u64,
    thread_id: u64,
    operation_generation: u64,
    handle: u64,
    runtime_addr: u64,
    runtime_generation: u64,
    close_request_generation: u64,
    close_schedule_ticket: u64,
    expected_state_generation: u64,
    expected_lifecycle_raw: u8,
    lifecycle_raw: u8,
    identity_seal: CleanupSeal,
};

pub const RuntimeAdmissionSealInput = struct {
    self_addr: u64,
    backend_addr: u64,
    thread_id: u64,
    request_generation: u64,
    state_raw: u8,
};

pub const PreparedAdmissionCloseSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    slot_addr: u64,
    slot_incarnation: u64,
    node_addr: u64,
    node_incarnation: u64,
    connection_generation: u64,
    request_generation: u64,
    lifecycle_raw: u8,
};

pub const PreparedRetirementCleanupSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    slot_addr: u64,
    slot_incarnation: u64,
    node_addr: u64,
    node_incarnation: u64,
    connection_generation: u64,
    admission_request_generation: u64,
    placeholder_generation: u64,
    allocator_ptr: u64,
    allocator_vtable: u64,
    fd: i32,
    pending_frame_addr: u64,
    pending_frame_len: u64,
    pending_stream_id: u64,
    pending_offset: u64,
    external_deinit_reserved_raw: u8,
    lifecycle_raw: u8,
};

pub const PreparedClientReplacementSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    slot_addr: u64,
    slot_incarnation: u64,
    old_node_addr: u64,
    old_node_incarnation: u64,
    new_node_addr: u64,
    new_node_incarnation: u64,
    expected_connection_generation: u64,
    next_connection_generation: u64,
    cleanup_seal: CleanupSeal,
    candidate_digest: CleanupSeal,
    lifecycle_raw: u8,
};

pub const PreparedRetiredClientReclaimSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    slot_addr: u64,
    slot_incarnation: u64,
    retired_index: u8,
    node_addr: u64,
    node_incarnation: u64,
    connection_generation: u64,
    node_digest: CleanupSeal,
    lifecycle_raw: u8,
};

pub const WindowCloseTicketReservationSealInput = struct {
    self_addr: u64,
    backend_addr: u64,
    thread_id: u64,
    first_ticket: u64,
    last_ticket: u64,
    target_count: u32,
    target_digest: Digest,
    state_raw: u8,
};

pub const RemoteBackendSingletonSealInput = struct {
    self_addr: u64,
    backend_addr: u64,
    thread_id: u64,
    owner_generation: u64,
    lifecycle_raw: u8,
};

pub const HostReconnectJobSealInput = struct {
    self_addr: u64,
    backend_addr: u64,
    backend_generation: u64,
    thread_id: u64,
    job_generation: u64,
    host_id: u128,
    adapter_addr: u64,
    adapter_generation: u64,
    expected_connection_generation: u64,
    deadline_ns_low: u64,
    deadline_ns_high: u64,
    client_addr: u64,
    client_fd: i32,
    client_owner_digest: Digest,
    client_identity_digest: Digest,
    runtime_row_count: u32,
    runtime_rows_addr: u64,
    runtime_rows_digest: Digest,
    runtime_cursor_next_index: u32,
    runtime_cursor_terminal_count: u32,
    runtime_cursor_failed_raw: u8,
    terminal_summary_digest: Digest,
    runtime_handle: u64,
    runtime_addr: u64,
    runtime_generation: u64,
    shared_admission_addr: u64,
    shared_admission_lifecycle_raw: u8,
    shared_admission_seal: Digest,
    shared_cleanup_addr: u64,
    shared_cleanup_lifecycle_raw: u8,
    shared_cleanup_seal: Digest,
    replacement_addr: u64,
    replacement_slot_addr: u64,
    replacement_old_node_addr: u64,
    replacement_new_node_addr: u64,
    replacement_expected_connection_generation: u64,
    replacement_next_connection_generation: u64,
    replacement_lifecycle_raw: u8,
    replacement_seal: Digest,
    request_nonce: u128,
    candidate_failure_reason_raw: u8,
    reconnect_addr: u64,
    reconnect_owner_addr: u64,
    reconnect_lifecycle_raw: u8,
    candidate_addr: u64,
    candidate_slot_addr: u64,
    candidate_node_addr: u64,
    candidate_generation: u64,
    candidate_active: u8,
    stage_addr: u64,
    stage_digest: Digest,
    mutation_digest: Digest,
    controller_generation: u64,
    state_raw: u8,
};

pub const HostReconnectWindowTransactionSealInput = struct {
    self_addr: u64,
    owner_addr: u64,
    owner_generation: u64,
    thread_id: u64,
    transaction_generation: u64,
    job_generation: u64,
    host_id: u128,
    pool_membership_generation: u64,
    expected_connection_generation: u64,
    summary_digest: Digest,
    rows_digest: Digest,
    bindings_digest: Digest,
    binding_count: u32,
    target_window_addr: u64,
    target_runtime_handle: u64,
    target_surface_id: u64,
    action_generation: u64,
    expires_at_ns: u64,
    action_kind_raw: u8,
    lifecycle_raw: u8,
};

pub const HostReconnectWindowOwnerSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    owner_generation: u64,
    next_transaction_generation: u64,
    active_transaction_addr: u64,
    active_action_generation: u64,
    spent_action_generation: u64,
    spent_action_digest: Digest,
    lifecycle_raw: u8,
};

pub const SessionHostCoordinatorSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    lifecycle_raw: u8,
};

pub const ExternalReconnectReceiptSealInput = struct {
    self_addr: u64,
    coordinator_addr: u64,
    thread_id: u64,
    backend_addr: u64,
    backend_generation: u64,
    runtime_handle: u64,
    runtime_generation: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    incident_app_instance_nonce: u128,
    incident_sequence: u64,
    job_generation: u64,
    shell_generation: u64,
    attempt: u64,
    candidate_connection_generation: u64,
    deadline_ns: u64,
    runtime_id: [16]u8,
    lifecycle_raw: u8,
};

pub const ReconnectCloseReceiptSealInput = struct {
    self_addr: u64,
    coordinator_addr: u64,
    thread_id: u64,
    backend_addr: u64,
    backend_generation: u64,
    runtime_handle: u64,
    runtime_generation: u64,
    runtime_id: [32]u8,
    transition_digest: Digest,
    lifecycle_raw: u8,
};

pub const PreparedHostPublicationSealInput = struct {
    self_addr: u64,
    pool_addr: u64,
    host_id: u128,
    adapter_addr: u64,
    adapter_generation: u64,
    owned_raw: u8,
    lifecycle_raw: u8,
};

pub const IncidentBindingSealInput = struct {
    client_addr: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    wire_major: u16,
    host_class_raw: u8,
};

pub const IncidentPublisherAuthoritySealInput = struct {
    self_addr: u64,
    registry_addr: u64,
    registry_generation: u64,
    runtime_addr: u64,
    runtime_generation: u64,
    service_addr: u64,
    service_generation: u64,
    service_process_nonce: u64,
    owner_thread: u64,
    app_instance_nonce: u128,
    lifecycle_raw: u8,
};

pub const IncidentPublisherLeaseSealInput = struct {
    self_addr: u64,
    registry_addr: u64,
    registry_generation: u64,
    authority_addr: u64,
    runtime_addr: u64,
    runtime_generation: u64,
    service_addr: u64,
    service_generation: u64,
    owner_thread: u64,
    lease_generation: u64,
    consumed_raw: u8,
};

pub const IncidentClientOperationSealInput = struct {
    self_addr: u64,
    slot_addr: u64,
    slot_generation: u64,
    node_addr: u64,
    node_generation: u64,
    client_addr: u64,
    connection_generation: u64,
    operation_id: u64,
    registry_index: u16,
    owner_thread: u64,
    authority_digest: CleanupSeal,
    commit_digest: CleanupSeal,
    repeat_key_seal: CleanupSeal,
    lifecycle_raw: u8,
};

pub const IncidentRepeatKeySealInput = struct {
    self_addr: u64,
    client_addr: u64,
    connection_generation: u64,
    app_instance_nonce: u128,
    sequence: u64,
    fingerprint: CleanupSeal,
    binding_seal: CleanupSeal,
    lifecycle_raw: u8,
};

pub const PreparedIncidentPublicationSealInput = struct {
    self_addr: u64,
    kind_raw: u8,
    lease_addr: u64,
    lease_generation: u64,
    lease_seal: CleanupSeal,
    runtime_generation: u64,
    service_generation: u64,
    service_token_addr: u64,
    service_token_seal: CleanupSeal,
    service_lifecycle_raw: u8,
    client_token_addr: u64,
    client_token_seal: CleanupSeal,
    client_lifecycle_raw: u8,
    input_digest: CleanupSeal,
    lifecycle_raw: u8,
};

/// One-shot handoff from a held Client mutation to the later managed publication owner.
/// The canonical input digest binds the complete pointer-free incident projection without
/// duplicating its wire schema in this platform seal module.
pub const PreparedManagedPoisonSealInput = struct {
    self_addr: u64,
    owner_thread: u64,
    slot_addr: u64,
    slot_generation: u64,
    node_addr: u64,
    node_generation: u64,
    binding_seal: CleanupSeal,
    input_digest: CleanupSeal,
    lifecycle_raw: u8,
};

/// Process-global lookup token for the GUI incident owner. The token contains no publisher
/// pointer; resolving it always revalidates the final owner graph before use.
pub const IncidentPublicationPortSealInput = struct {
    owner_addr: u64,
    owner_thread: u64,
    registry_addr: u64,
    pid: u32,
    process_nonce: u64,
    app_instance_nonce: u128,
    owner_lifecycle_raw: u8,
};

pub const IncidentPublicationTimestampSealInput = struct {
    owner_addr: u64,
    owner_thread: u64,
    pid: u32,
    process_nonce: u64,
    app_instance_nonce: u128,
    timestamp_ns: i128,
};

pub const ReconnectAdmissionSealInput = struct {
    self_addr: u64,
    owner_thread: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    incident_app_instance_nonce: u128,
    incident_sequence: u64,
    disposition_raw: u8,
    lifecycle_raw: u8,
};

pub const PreparedReconnectDispatchSealInput = struct {
    self_addr: u64,
    owner_addr: u64,
    owner_thread: u64,
    slot_index: u8,
    slot_generation: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    incident_app_instance_nonce: u128,
    incident_sequence: u64,
    attempt_generation: u64,
    lifecycle_raw: u8,
};

pub const ReconnectExecutorAdmissionSealInput = struct {
    executor_addr: u64,
    generation_owner_addr: u64,
    budget_addr: u64,
    lease_addr: u64,
    lease_generation: u64,
    slot_index: u8,
    slot_generation: u64,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    incident_app_instance_nonce: u128,
    incident_sequence: u64,
};

pub const PendingTermCloseSealInput = struct {
    self_addr: u64,
    app_session_addr: u64,
    app_session_generation: u64,
    term_addr: u64,
    surface_id: u64,
    handle: u64,
    term_close_generation: u64,
    request_generation: u64,
    request_kind_raw: u8,
    phase_raw: u8,
    graph_seal: CleanupSeal,
};

pub const PendingTermCloseGraphSealInput = struct {
    self_addr: u64,
    app_session_addr: u64,
    app_session_generation: u64,
    graph_generation: u64,
    target_count: u32,
    target_digest: Digest,
    lifecycle_raw: u8,
};

pub const ShutdownAttemptAuthoritySealInput = struct {
    self_addr: u64,
    thread_id: u64,
    close_request_generation: u64,
    target_digest: Digest,
    attempt_generation: u64,
    disposition_raw: u8,
    lifecycle_raw: u8,
    connection_lease_generation: u64,
    deadline_ns: u64,
    outcome_digest: Digest,
};

pub const ShutdownConnectionReceiptSealInput = struct {
    self_addr: u64,
    authority_addr: u64,
    thread_id: u64,
    close_request_generation: u64,
    target_digest: Digest,
    attempt_generation: u64,
    connection_identity: u64,
    lease_generation: u64,
    operation_raw: u8,
    inventory_attempt_raw: u8,
    consumed_raw: u8,
    transcript_digest: Digest,
};

pub const PendingAppQuitShutdownSealInput = struct {
    self_addr: u64,
    app_session_addr: u64,
    backend_addr: u64,
    thread_id: u64,
    started_at_ns: u64,
    deadline_ns: u64,
    target_count: u32,
    target_cursor: u32,
    lifecycle_raw: u8,
};

/// Stable event identity copied from the trusted take projection.  This value deliberately owns
/// no pointer: addresses are identities only and must never be dereferenced by this leaf.
pub const PendingEventIdentity = struct {
    expected_major: u16,
    metadata_support_raw: u8,
    correlation_binding_digest: Digest,
    payload_digest: Digest,
    admission_projection_digest: Digest,
    wire_major: u16,
    admission_tag: u8,
    registry_incarnation: u64,
    binding_reservation_id: u64,
    event_node_incarnation: u64,
    stream_id: u64,
    event_generation: u64,
    event_owner_addr: u64,
    slot_incarnation: u64,
    owner_node_incarnation: u64,
    transport_incarnation: u64,
    host_id: u128,
    runtime_id: u128,
    connection_generation: u64,
    pid: u32,
    process_nonce: u64,
};

pub const PendingOperationSealInput = struct {
    state_raw: u8,
    operation_kind_raw: u8,
    reader_count: u16,
    reserved: [4]u8,
    self_addr: u64,
    runtime_addr: u64,
    pending_owner_addr: u64,
    pid: u32,
    reserved_pid: u32,
    process_nonce: u64,
    thread_id: u64,
    owner_incarnation: u64,
    next_operation_incarnation: u64,
    active_operation_incarnation: u64,
    close_generation: u64,
};

pub const RuntimeOperationIdentity = struct {
    lifetime_owner_addr: u64,
    runtime_addr: u64,
    pending_owner_addr: u64,
    pid: u32,
    reserved_pid: u32,
    process_nonce: u64,
    thread_id: u64,
    owner_incarnation: u64,
    operation_incarnation: u64,
    operation_kind_raw: u8,
    operation_seal: CleanupSeal,
};

pub const SettlementScratchProofSealInput = struct {
    thread_id: u64,
    ranges_digest: Digest,
    pristine_digest: Digest,
};

pub const RuntimeSettlementLeaseSealInput = struct {
    lease_addr: u64,
    lease_extent: u64,
    lease_alignment: u64,
    operation: RuntimeOperationIdentity,
    ranges_digest: Digest,
    pristine_digest: Digest,
    preflight_proof_seal_digest: Digest,
};

pub const RuntimeSettlementBindingSealInput = struct {
    lease_addr: u64,
    lifetime_owner_addr: u64,
    operation: RuntimeOperationIdentity,
    ranges_digest: Digest,
    pristine_digest: Digest,
    preflight_proof_seal_digest: Digest,
    lease_seal_digest: Digest,
};

pub const PendingSettlementPermitSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    pending_owner_addr: u64,
    owner_incarnation: u64,
    attempt: u64,
    source_lease_incarnation: u64,
    event_generation: u64,
    effect_out_addr: u64,
    release_out_addr: u64,
    disposition_addr: u64,
    ranges_digest: Digest,
    pristine_digest: Digest,
    preflight_proof_seal_digest: Digest,
    lease_seal_digest: Digest,
    release_receipt_digest: Digest,
};

pub const PreparedEventReleasePermitSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    registry_addr: u64,
    registry_incarnation: u64,
    binding_reservation_id: u64,
    entry_index: u16,
    event_node_incarnation: u64,
    stream_id: u64,
    event_generation: u64,
    event_owner_addr: u64,
    pending_owner_addr: u64,
    pending_owner_incarnation: u64,
    source_lease_incarnation: u64,
    attempt: u64,
    ordering_class_raw: u8,
    expected_blocker_count: u64,
    completion_addr: u64,
    completion_extent: u64,
    completion_alignment: u64,
    completion_pristine_digest: Digest,
    begun_addr: u64,
    begun_extent: u64,
    begun_alignment: u64,
    begun_pristine_digest: Digest,
    scratch_ranges_digest: Digest,
    scratch_pristine_digest: Digest,
    preflight_proof_seal_digest: Digest,
    lease_seal_digest: Digest,
    release_receipt_digest: Digest,
    event_owner_seal: Digest,
    payload_addr: u64,
    payload_len: u64,
    payload_digest: Digest,
    allocator_ptr: u64,
    allocator_vtable: u64,
    pin_owner_addr: u64,
    lease_addr: u64,
    slot_addr: u64,
    node_addr: u64,
    pin_slot_incarnation: u64,
    pin_node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    pin_process_nonce: u64,
    quarantine_slot_index: u16,
    quarantine_reservation_generation: u64,
    source_authority_digest: Digest,
};

pub const EventReleaseCompletionSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    registry_incarnation: u64,
    binding_reservation_id: u64,
    event_node_incarnation: u64,
    stream_id: u64,
    event_generation: u64,
    event_owner_addr: u64,
    pending_owner_addr: u64,
    pending_owner_incarnation: u64,
    source_lease_incarnation: u64,
    attempt: u64,
    ordering_class_raw: u8,
    consumed_blocker_count: u16,
    freed_payload_count: u8,
    consumed_pin_count: u8,
    settled_quarantine_count: u8,
    post_transcript_digest: Digest,
    release_receipt_digest: Digest,
    permit_digest: Digest,
    authority_digest: Digest,
};

pub const PendingEventReleaseBegunSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    effect_permit_addr: u64,
    release_permit_addr: u64,
    operation_id: u64,
    event_owner_addr: u64,
    event_generation: u64,
    pin_count_before: u64,
    correlation_digest: Digest,
    effect_permit_seal: Digest,
    release_permit_seal: Digest,
    pin_receipt_seal: Digest,
    owner_tombstone_receipt: Digest,
    correlation_tombstone_receipt: Digest,
    mirror_tombstone_receipt: Digest,
    callback_returned_receipt: Digest,
    lifecycle_raw: u8,
    callback_active_raw: u8,
};

pub const EventReleaseLeafReceiptSealInput = struct {
    role_raw: u8,
    reserved: [7]u8,
    identity_a: u64,
    identity_b: u64,
    identity_c: u64,
    identity_d: u64,
    identity_e: u64,
    identity_f: u64,
    before_a: u64,
    before_b: u64,
    after_a: u64,
    after_b: u64,
};
pub const EventReleasePhaseReceiptSealInput = struct {
    role_raw: u8,
    lifecycle_before_raw: u8,
    lifecycle_after_raw: u8,
    invocation_count: u8,
    reserved: [4]u8,
    event_owner_addr: u64,
    event_generation: u64,
    begun_addr: u64,
    invocation_ordinal: u64,
    before_digest: Digest,
    after_digest: Digest,
    permit_seal: Digest,
    tls_begun_seal: Digest,
};

pub const SettlementScratchRangeSealInput = struct {
    thread_id: u64,
    ranges_digest: Digest,
    disposition_offset: u64,
};

pub const PreparedEffectPermitSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    pending_owner_addr: u64,
    owner_incarnation: u64,
    attempt: u64,
    event_generation: u64,
    correlation_digest: Digest,
    prepared_effect_digest: Digest,
    effect_request_tag_raw: u8,
    requested_reason_present_raw: u8,
    requested_reason_raw: u8,
    requested_revoke_fence: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    binding_incarnation: u64,
    transport_incarnation: u64,
    operation_node_addr: u64,
    operation_id: u64,
    operation_registry_index: u16,
    target_stream_id: u64,
    action_raw: u8,
    first_reason_before_present_raw: u8,
    first_reason_before_raw: u8,
    first_reason_after_present_raw: u8,
    first_reason_after_raw: u8,
    unusable_before_raw: u8,
    unusable_after_raw: u8,
    fd_before: i32,
    fd_after: i32,
    fd_disposition_raw: u8,
    close_attempt_count: u8,
    outbound_relation_raw: u8,
    outbound_disposition_raw: u8,
    cleanup_mode_raw: u8,
    cleanup_count: u8,
    outbound_offset: u64,
    outbound_len: u64,
    outbound_descriptor_digest: Digest,
    cleanup_callback_provenance_digest: Digest,
    effect_out_addr: u64,
    effect_out_extent: u64,
    effect_out_alignment: u64,
    effect_out_pristine_digest: Digest,
    scratch_ranges_digest: Digest,
    scratch_pristine_digest: Digest,
    preflight_proof_seal_digest: Digest,
    lease_seal_digest: Digest,
    preflight_authority_digest: Digest,
};

pub const EffectCommitEvidenceSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    pending_owner_addr: u64,
    owner_incarnation: u64,
    attempt: u64,
    event_generation: u64,
    outcome_raw: u8,
    recovery_raw: u8,
    first_reason_before_present_raw: u8,
    first_reason_before_raw: u8,
    first_reason_after_present_raw: u8,
    first_reason_after_raw: u8,
    unusable_before_raw: u8,
    unusable_after_raw: u8,
    fd_before: i32,
    fd_after: i32,
    fd_disposition_raw: u8,
    close_attempt_count: u8,
    outbound_relation_raw: u8,
    outbound_disposition_raw: u8,
    cleanup_mode_raw: u8,
    cleanup_count: u8,
    outbound_descriptor_digest: Digest,
    cleanup_completion_digest: Digest,
    confirmed_effect_digest: Digest,
    commit_authority_digest: Digest,
};

pub const SettlementDispositionSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    pending_owner_addr: u64,
    owner_incarnation: u64,
    attempt: u64,
    event_generation: u64,
    disposition_raw: u8,
    effect_evidence_digest: Digest,
    registry_completion_digest: Digest,
    consumed_receipt_digest: Digest,
};

pub const PreparedSemanticCommitSealInput = struct {
    self_addr: u64,
    thread_id: u64,
    pending_owner_addr: u64,
    owner_incarnation: u64,
    attempt: u64,
    event_generation: u64,
    disposition_seal: Digest,
    prepared_seal: Digest,
    prepared_tag_raw: u8,
    publish_raw: u8,
    resize_generation: u64,
    observation_probe_nonce: u64,
    phase_raw: u8,
    observation_moved_raw: u8,
    semantic_post_digest: Digest,
};

pub const RuntimeOperationPreflight = struct {
    lifetime_owner_addr: u64,
    runtime_addr: u64,
    pending_owner_addr: u64,
    pid: u32,
    reserved_pid: u32,
    process_nonce: u64,
    thread_id: u64,
    owner_incarnation: u64,
    expected_next_operation: u64,
    expected_operation_seal: CleanupSeal,
};

pub const PendingReleaseSealInput = struct {
    event_identity: PendingEventIdentity,
    pending_owner_addr: u64,
    pending_owner_incarnation: u64,
    source_lease_incarnation: u64,
    attempt: u64,
    state_raw: u8,
    reserved: [7]u8,
};

pub const PendingSourceReceiptSealInput = struct {
    event_identity: PendingEventIdentity,
    runtime_addr: u64,
    pending_owner_addr: u64,
    payload_addr: u64,
    payload_len: u64,
    runtime_incarnation: u64,
    pending_owner_incarnation: u64,
    source_lease_incarnation: u64,
    pid: u32,
    process_nonce: u64,
    thread_id: u64,
};

pub const PendingSourceLeaseSealInput = struct {
    receipt: PendingSourceReceiptSealInput,
    state_raw: u8,
    reserved: [7]u8,
    attempt: u64,
};

pub const PendingPreparationFrameSealInput = struct {
    frame_addr: u64,
    runtime_addr: u64,
    lifetime_owner_addr: u64,
    pending_owner_addr: u64,
    observation_addr: u64,
    direct_input_addr: u64,
    pending_controls_addr: u64,
    source_owner_addr: u64,
    operation_preflight: RuntimeOperationPreflight,
    operation_identity: RuntimeOperationIdentity,
    source_receipt: PendingSourceReceiptSealInput,
    source_lease: PendingSourceLeaseSealInput,
    snapshot_digest: Digest,
    recipe_digest: Digest,
    scratch_graph_digest: Digest,
    dto_content_digest: Digest,
    transfer_projection_mask: u8,
    transfer_observation_digest: Digest,
    transcript_mirror: Digest,
    progress_mirror: Digest,
    cleanup_descriptor: CleanupDescriptor,
    protected_ranges_digest: Digest,
    allocator_context_addr: u64,
    allocator_context_projection_digest: Digest,
};

pub const PendingLifecycle = enum(u8) {
    idle = 0,
    preparing = 1,
    prepared = 2,
    settling = 3,
    committed_cleanup = 4,
};

pub const CleanupPhase = enum(u8) {
    preparation = 1,
    committed_observation = 2,
};

pub const CleanupStep = enum(u8) {
    ready = 1,
    freeing = 2,
    freed = 3,
    finished = 4,
};

pub const CleanupRole = enum(u8) {
    none = 0,
    dto_backing = 1,
    cwd = 2,
    cwd_host = 3,
    window_title = 4,
    ssh_remote_dest = 5,
    clipboard_read_target = 6,
    foreground_processes = 7,
    agent_progress = 8,
};

pub const CleanupDescriptor = struct {
    present: u8 = 0,
    address: u64 = 0,
    length_bytes: u64 = 0,
    capacity_bytes: u64 = 0,
    alignment_log2: u8 = 0,
    allocator_ptr: u64 = 0,
    allocator_vtable: u64 = 0,
};

pub const ObservationCleanupGraph = struct {
    cwd: CleanupDescriptor = .{},
    cwd_host: CleanupDescriptor = .{},
    window_title: CleanupDescriptor = .{},
    ssh_remote_dest: CleanupDescriptor = .{},
    clipboard_read_target: CleanupDescriptor = .{},
    foreground_processes: CleanupDescriptor = .{},
    agent_progress: CleanupDescriptor = .{},
};

pub const CleanupPlanTag = enum(u8) {
    preparation = 1,
    committed_observation = 2,
};

pub const CleanupPlanInput = union(CleanupPlanTag) {
    preparation: struct {
        dto_backing: CleanupDescriptor,
        next_observation: ObservationCleanupGraph,
    },
    committed_observation: struct {
        old_observation: ObservationCleanupGraph,
    },
};

pub const CleanupProgressState = struct {
    phase: CleanupPhase,
    step: CleanupStep,
    next_role: CleanupRole,
    completed_mask: u8,
};

pub const CleanupTranscriptInput = struct {
    host_id: u128,
    runtime_id: u128,
    connection_generation: u64,
    slot_incarnation: u64,
    owner_node_incarnation: u64,
    transport_incarnation: u64,
    registry_incarnation: u64,
    binding_reservation_id: u64,
    event_node_incarnation: u64,
    stream_id: u64,
    event_generation: u64,
    event_owner_addr: u64,
    wire_major: u16,
    expected_major: u16,
    metadata_support_raw: u8,
    admission_tag: u8,
    correlation_binding_digest: Digest,
    payload_digest: Digest,
    admission_projection_digest: Digest,
    pending_owner_addr: u64,
    pending_owner_incarnation: u64,
    cleanup_plan_addr: u64,
    runtime_addr: u64,
    observation_addr: u64,
    observation_revision: u64,
    observer_generation: u64,
    title_generation: u32,
    observation_digest: Digest,
    preparation_attempt: u64,
    pending_lifecycle: PendingLifecycle,
    plan: CleanupPlanInput,
};

pub const CleanupProgressInput = struct {
    transcript_input: CleanupTranscriptInput,
    transcript_seal: CleanupSeal,
    phase: CleanupPhase,
    step: CleanupStep,
    next_role: CleanupRole,
    completed_mask: u8,
    retained_observation_digest: Digest = [_]u8{0} ** 32,
    decision: decision_seal.Projection = .{},
};

pub const ObservationStringRole = enum(u8) {
    cwd = 1,
    cwd_host = 2,
    window_title = 3,
    ssh_remote_dest = 4,
    clipboard_read_target = 5,
    agent_progress = 6,
};

pub const ForegroundProcessDigestInput = struct {
    pid: i32 = 0,
    len: u8 = 0,
    bytes: [128]u8 = [_]u8{0} ** 128,
};

pub const ForegroundProcessesDigestInput = struct {
    count: u8 = 0,
    entries: [64]ForegroundProcessDigestInput =
        [_]ForegroundProcessDigestInput{.{}} ** 64,
};

pub const ObservationCleanupDigestInput = struct {
    availability: u8,
    revision: u64,
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    ssh_remote_dest_present: u8,
    semantic_state: u8,
    alt_active: u8,
    app_cursor_keys: u8,
    app_keypad: u8,
    kitty_flags: u8,
    alternate_scroll: u8,
    mouse_tracking: u8,
    mouse_tracking_mode: u8,
    bracketed_paste: u8,
    bell_count: u64,
    clipboard_write_seq: u64,
    clipboard_read_seq: u64,
    foreground_available: u8,
    foreground_pgid_present: u8,
    foreground_pgid: i32,
    foreground_process_count: u8,
    graph: ObservationCleanupGraph,
    cwd_digest: Digest,
    cwd_host_digest: Digest,
    window_title_digest: Digest,
    ssh_remote_dest_digest: Digest,
    clipboard_read_target_digest: Digest,
    foreground_processes_digest: Digest,
    agent_progress_digest: Digest,
};

const string_domains = [_][]const u8{
    "maru.runtime-observation.string.cwd.v1",
    "maru.runtime-observation.string.cwd-host.v1",
    "maru.runtime-observation.string.window-title.v1",
    "maru.runtime-observation.string.ssh-remote-dest.v1",
    "maru.runtime-observation.string.clipboard-read-target.v1",
    "maru.runtime-observation.string.agent-progress.v1",
};
const foreground_domain = "maru.runtime-observation.foreground-processes.v1";
const observation_domain = "maru.runtime-observation.cleanup.v1";

fn fatalNonCanonical() noreturn {
    switch (@import("builtin").os.tag) {
        .macos, .linux => std.c._exit(70),
        else => @trap(),
    }
}

fn hashDomain(domain: []const u8) std.crypto.hash.Blake3 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(domain);
    return hasher;
}

fn writeInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn finish(hasher: *std.crypto.hash.Blake3) Digest {
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn cleanupDescriptorCanonical(value: CleanupDescriptor) bool {
    if (value.present == 0) return value.address == 0 and value.length_bytes == 0 and
        value.capacity_bytes == 0 and value.alignment_log2 == 0 and
        value.allocator_ptr == 0 and value.allocator_vtable == 0;
    if (value.present != 1 or value.address == 0 or value.length_bytes == 0 or
        value.capacity_bytes != value.length_bytes or value.alignment_log2 > 63 or
        // Allocator context address zero is valid for stateless allocators. Presence is carried
        // by `present`; the vtable must exist and the context value remains sealed exactly.
        value.allocator_vtable == 0)
        return false;
    const alignment = @as(u64, 1) << @intCast(value.alignment_log2);
    if (value.address & (alignment - 1) != 0) return false;
    const end = std.math.add(u64, value.address, value.capacity_bytes) catch return false;
    return end != 0;
}

fn graphCanonical(graph: ObservationCleanupGraph) bool {
    return cleanupDescriptorCanonical(graph.cwd) and
        cleanupDescriptorCanonical(graph.cwd_host) and
        cleanupDescriptorCanonical(graph.window_title) and
        cleanupDescriptorCanonical(graph.ssh_remote_dest) and
        cleanupDescriptorCanonical(graph.clipboard_read_target) and
        cleanupDescriptorCanonical(graph.foreground_processes) and
        cleanupDescriptorCanonical(graph.agent_progress);
}

fn cleanupPlanCanonical(plan: CleanupPlanInput) bool {
    return switch (plan) {
        .preparation => |value| cleanupDescriptorCanonical(value.dto_backing) and
            graphCanonical(value.next_observation),
        .committed_observation => |value| graphCanonical(value.old_observation),
    };
}

fn digestNonzero(value: Digest) bool {
    return !std.mem.allEqual(u8, &value, 0);
}

fn cleanupTranscriptInputCanonical(input: CleanupTranscriptInput) bool {
    return input.host_id != 0 and input.runtime_id != 0 and
        input.connection_generation != 0 and input.slot_incarnation != 0 and
        input.owner_node_incarnation != 0 and input.transport_incarnation != 0 and
        input.registry_incarnation != 0 and input.binding_reservation_id != 0 and
        input.event_node_incarnation != 0 and input.stream_id != 0 and
        input.event_generation != 0 and input.event_owner_addr != 0 and
        input.wire_major != 0 and input.expected_major != 0 and
        input.metadata_support_raw <= 1 and input.admission_tag <= 1 and
        digestNonzero(input.correlation_binding_digest) and
        digestNonzero(input.payload_digest) and
        ((input.admission_tag == 0 and
            !digestNonzero(input.admission_projection_digest)) or
            (input.admission_tag == 1 and
                digestNonzero(input.admission_projection_digest))) and
        input.pending_owner_addr != 0 and input.pending_owner_incarnation != 0 and
        input.cleanup_plan_addr != 0 and input.runtime_addr != 0 and
        input.observation_addr != 0 and digestNonzero(input.observation_digest) and
        input.preparation_attempt != 0 and cleanupPlanCanonical(input.plan) and
        switch (input.plan) {
            .preparation => input.pending_lifecycle == .preparing,
            .committed_observation => input.pending_lifecycle == .committed_cleanup,
        };
}

fn cleanupProgressInputCanonical(input: CleanupProgressInput) bool {
    if (!cleanupTranscriptInputCanonical(input.transcript_input)) return false;
    if (!progressCanonical(input.transcript_input.plan, .{
        .phase = input.phase,
        .step = input.step,
        .next_role = input.next_role,
        .completed_mask = input.completed_mask,
    })) return false;
    return decisionProjectionCanonical(input);
}

fn decisionProjectionCanonical(input: CleanupProgressInput) bool {
    return decision_seal.canonical(
        input.decision,
        digestNonzero(input.retained_observation_digest),
    );
}

pub fn observationStringDigest(role: ObservationStringRole, bytes: []const u8) Digest {
    var hasher = hashDomain(string_domains[@intFromEnum(role) - 1]);
    hasher.update(bytes);
    return finish(&hasher);
}

fn foregroundProcessesInputCanonical(input: ForegroundProcessesDigestInput) bool {
    if (input.count > input.entries.len) return false;
    for (input.entries[0..input.count]) |entry| {
        if (entry.len > entry.bytes.len) return false;
        if (!std.mem.allEqual(u8, entry.bytes[entry.len..], 0)) return false;
    }
    for (input.entries[input.count..]) |entry| {
        if (entry.pid != 0 or entry.len != 0 or !std.mem.allEqual(u8, &entry.bytes, 0))
            return false;
    }
    return true;
}

pub fn foregroundProcessesDigest(input: ForegroundProcessesDigestInput) Digest {
    if (!foregroundProcessesInputCanonical(input)) fatalNonCanonical();
    var hasher = hashDomain(foreground_domain);
    writeInt(&hasher, u8, input.count);
    for (input.entries[0..input.count]) |entry| {
        writeInt(&hasher, i32, entry.pid);
        writeInt(&hasher, u8, entry.len);
        hasher.update(entry.bytes[0..entry.len]);
    }
    return finish(&hasher);
}

fn boolRawValid(value: u8) bool {
    return value <= 1;
}

fn descriptorDigestCoupled(descriptor: CleanupDescriptor, digest: Digest) bool {
    return (descriptor.present == 0) == std.mem.allEqual(u8, &digest, 0);
}

fn observationCleanupInputCanonical(input: ObservationCleanupDigestInput) bool {
    if (input.availability > 2 or input.semantic_state > 3 or
        input.mouse_tracking_mode > 4 or input.kitty_flags > 31 or
        input.foreground_process_count > 64 or
        !boolRawValid(input.ssh_remote_dest_present) or
        !boolRawValid(input.alt_active) or !boolRawValid(input.app_cursor_keys) or
        !boolRawValid(input.app_keypad) or !boolRawValid(input.alternate_scroll) or
        !boolRawValid(input.mouse_tracking) or !boolRawValid(input.bracketed_paste) or
        !boolRawValid(input.foreground_available) or
        !boolRawValid(input.foreground_pgid_present) or !graphCanonical(input.graph))
        return false;
    if (input.foreground_pgid_present == 0 and input.foreground_pgid != 0) return false;
    if (input.ssh_remote_dest_present != input.graph.ssh_remote_dest.present or
        !descriptorDigestCoupled(input.graph.cwd, input.cwd_digest) or
        !descriptorDigestCoupled(input.graph.cwd_host, input.cwd_host_digest) or
        !descriptorDigestCoupled(input.graph.window_title, input.window_title_digest) or
        !descriptorDigestCoupled(input.graph.ssh_remote_dest, input.ssh_remote_dest_digest) or
        !descriptorDigestCoupled(
            input.graph.clipboard_read_target,
            input.clipboard_read_target_digest,
        ) or
        !descriptorDigestCoupled(
            input.graph.foreground_processes,
            input.foreground_processes_digest,
        ) or
        !descriptorDigestCoupled(input.graph.agent_progress, input.agent_progress_digest))
        return false;
    if ((input.foreground_process_count == 0) !=
        (input.graph.foreground_processes.present == 0)) return false;
    return true;
}

fn writeDescriptor(hasher: *std.crypto.hash.Blake3, value: CleanupDescriptor) void {
    writeInt(hasher, u8, value.present);
    writeInt(hasher, u64, value.address);
    writeInt(hasher, u64, value.length_bytes);
    writeInt(hasher, u64, value.capacity_bytes);
    writeInt(hasher, u8, value.alignment_log2);
    writeInt(hasher, u64, value.allocator_ptr);
    writeInt(hasher, u64, value.allocator_vtable);
}

fn writeGraph(hasher: *std.crypto.hash.Blake3, graph: ObservationCleanupGraph) void {
    inline for (std.meta.fields(ObservationCleanupGraph)) |field|
        writeDescriptor(hasher, @field(graph, field.name));
}

fn observationCleanupDigestUnchecked(input: ObservationCleanupDigestInput) Digest {
    var hasher = hashDomain(observation_domain);
    inline for (.{
        .{ u8, input.availability },
        .{ u64, input.revision },
        .{ u64, input.observer_generation },
        .{ u32, input.title_generation },
        .{ u16, input.cols },
        .{ u16, input.rows },
        .{ u8, input.ssh_remote_dest_present },
        .{ u8, input.semantic_state },
        .{ u8, input.alt_active },
        .{ u8, input.app_cursor_keys },
        .{ u8, input.app_keypad },
        .{ u8, input.kitty_flags },
        .{ u8, input.alternate_scroll },
        .{ u8, input.mouse_tracking },
        .{ u8, input.mouse_tracking_mode },
        .{ u8, input.bracketed_paste },
        .{ u64, input.bell_count },
        .{ u64, input.clipboard_write_seq },
        .{ u64, input.clipboard_read_seq },
        .{ u8, input.foreground_available },
        .{ u8, input.foreground_pgid_present },
        .{ i32, input.foreground_pgid },
        .{ u8, input.foreground_process_count },
    }) |item| writeInt(&hasher, item[0], item[1]);
    writeGraph(&hasher, input.graph);
    inline for (.{
        input.cwd_digest,
        input.cwd_host_digest,
        input.window_title_digest,
        input.ssh_remote_dest_digest,
        input.clipboard_read_target_digest,
        input.foreground_processes_digest,
        input.agent_progress_digest,
    }) |digest| hasher.update(&digest);
    return finish(&hasher);
}

pub fn observationCleanupDigest(input: ObservationCleanupDigestInput) Digest {
    if (!observationCleanupInputCanonical(input)) fatalNonCanonical();
    return observationCleanupDigestUnchecked(input);
}

fn descriptorPresentMask(plan: CleanupPlanInput) u8 {
    var mask: u8 = 0;
    switch (plan) {
        .preparation => |value| {
            if (value.dto_backing.present == 1) mask |= 1 << 0;
            inline for (std.meta.fields(ObservationCleanupGraph), 1..) |field, bit| {
                if (@field(value.next_observation, field.name).present == 1) {
                    mask |= @as(u8, 1) << @intCast(bit);
                }
            }
        },
        .committed_observation => |value| {
            inline for (std.meta.fields(ObservationCleanupGraph), 0..) |field, bit| {
                if (@field(value.old_observation, field.name).present == 1) {
                    mask |= @as(u8, 1) << @intCast(bit);
                }
            }
        },
    }
    return mask;
}

fn fullMask(plan: CleanupPlanInput) u8 {
    return switch (plan) {
        .preparation => 0xff,
        .committed_observation => 0x7f,
    };
}

fn phaseFor(plan: CleanupPlanInput) CleanupPhase {
    return switch (plan) {
        .preparation => .preparation,
        .committed_observation => .committed_observation,
    };
}

fn roleForBit(plan: CleanupPlanInput, bit: u3) CleanupRole {
    return switch (plan) {
        .preparation => @enumFromInt(@as(u8, bit) + 1),
        .committed_observation => @enumFromInt(@as(u8, bit) + 2),
    };
}

fn lastPresentRole(plan: CleanupPlanInput, present_mask: u8) CleanupRole {
    var bit: i8 = switch (plan) {
        .preparation => 7,
        .committed_observation => 6,
    };
    while (bit >= 0) : (bit -= 1) {
        const shift: u3 = @intCast(bit);
        if (present_mask & (@as(u8, 1) << shift) != 0) return roleForBit(plan, shift);
    }
    return .none;
}

pub fn initialProgress(plan: CleanupPlanInput) CleanupProgressState {
    if (!cleanupPlanCanonical(plan)) fatalNonCanonical();
    const present = descriptorPresentMask(plan);
    const full = fullMask(plan);
    if (present == 0) return .{
        .phase = phaseFor(plan),
        .step = .finished,
        .next_role = .none,
        .completed_mask = full,
    };
    return .{
        .phase = phaseFor(plan),
        .step = .ready,
        .next_role = lastPresentRole(plan, present),
        .completed_mask = full & ~present,
    };
}

fn bitForRole(plan: CleanupPlanInput, role: CleanupRole) ?u3 {
    const raw = @intFromEnum(role);
    return switch (plan) {
        .preparation => if (raw >= 1 and raw <= 8) @intCast(raw - 1) else null,
        .committed_observation => if (raw >= 2 and raw <= 8) @intCast(raw - 2) else null,
    };
}

fn progressCanonical(plan: CleanupPlanInput, state: CleanupProgressState) bool {
    if (!cleanupPlanCanonical(plan) or state.phase != phaseFor(plan)) return false;
    const present = descriptorPresentMask(plan);
    const full = fullMask(plan);
    if (state.step == .finished)
        return state.next_role == .none and state.completed_mask == full;
    const absent = full & ~present;
    if (state.completed_mask & absent != absent) return false;
    if (state.completed_mask & ~full != 0) return false;
    const remaining = present & ~state.completed_mask;
    const completed_present = state.completed_mask & present;
    const expected_next = lastPresentRole(plan, remaining);
    if (remaining != 0) {
        const next_bit = bitForRole(plan, expected_next) orelse return false;
        const lower_mask = (@as(u8, 1) << next_bit) - 1;
        if ((state.completed_mask & present & lower_mask) != 0) return false;
    } else if ((state.completed_mask & present) != present) return false;
    return switch (state.step) {
        .ready, .freeing => remaining != 0 and state.next_role == expected_next,
        .freed => completed_present != 0 and state.next_role == expected_next,
        .finished => unreachable,
    };
}

pub fn assertCleanupTranscriptCanonical(input: CleanupTranscriptInput) void {
    if (!cleanupTranscriptInputCanonical(input)) fatalNonCanonical();
}

pub fn assertCleanupProgressCanonical(input: CleanupProgressInput) void {
    if (!cleanupProgressInputCanonical(input)) fatalNonCanonical();
}

/// Recoverable canonicality probes exist only in test binaries; product callers get fatal asserts.
const testCleanupDescriptorCanonical = cleanupDescriptorCanonical;
const testCleanupPlanCanonical = cleanupPlanCanonical;
const testCleanupTranscriptInputCanonical = cleanupTranscriptInputCanonical;
const testCleanupProgressInputCanonical = cleanupProgressInputCanonical;
const testDecisionProjectionCanonical = decisionProjectionCanonical;
const testForegroundProcessesInputCanonical = foregroundProcessesInputCanonical;
const testObservationCleanupInputCanonical = observationCleanupInputCanonical;
const testObservationCleanupDigestUnchecked = observationCleanupDigestUnchecked;
const testProgressCanonical = progressCanonical;
pub const testing = if (builtin.is_test) struct {
    pub const cleanupDescriptorCanonical = testCleanupDescriptorCanonical;
    pub const cleanupPlanCanonical = testCleanupPlanCanonical;
    pub const cleanupTranscriptInputCanonical = testCleanupTranscriptInputCanonical;
    pub const cleanupProgressInputCanonical = testCleanupProgressInputCanonical;
    pub const decisionProjectionCanonical = testDecisionProjectionCanonical;
    pub const foregroundProcessesInputCanonical = testForegroundProcessesInputCanonical;
    pub const observationCleanupInputCanonical = testObservationCleanupInputCanonical;
    pub const observationCleanupDigestUnchecked = testObservationCleanupDigestUnchecked;
    pub const progressCanonical = testProgressCanonical;
} else struct {};
