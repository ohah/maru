//! Process-global keyed seal service for session-host ownership registries.
//!
//! ClientSlot's canonical bootstrap is the only production initializer. It publishes the secret
//! ready only after the issuer registries exist, never exposes or resets the raw key, rejects a
//! forked process before secret/registry access, and offers fixed-domain typed derivation only.

const builtin = @import("builtin");
const std = @import("std");
const cleanup_seal = @import("event_cleanup_seal.zig");
const process_identity = @import("process_identity.zig");

const secret_len = 32;
const capability_domain = "maru.capability.registry-key.v2";
const cleanup_transcript_domain = "maru.cleanup.transcript.v1";
const cleanup_progress_domain = "maru.cleanup.progress.v1";
const pending_operation_domain = "maru.pending-operation.v1";
const pending_release_domain = "maru.pending-release.v1";
const pending_source_receipt_domain = "maru.pending-source-receipt.v1";
const pending_source_lease_domain = "maru.pending-source-lease.v1";
const pending_preparation_frame_domain = "maru.pending-preparation-frame.v1";
const settlement_scratch_proof_domain = "maru.settlement-scratch-proof.v1";
const runtime_settlement_lease_domain = "maru.runtime-settlement-lease.v1";
const runtime_settlement_binding_domain = "maru.runtime-settlement-binding.v1";
const pending_settlement_permit_domain = "maru.pending-settlement-permit.v1";
const settlement_disposition_domain = "maru.settlement-disposition.v1";
const prepared_semantic_commit_domain = "maru.prepared-semantic-commit.v1";
const prepared_event_release_permit_domain = "maru.prepared-event-release-permit.v2";
const event_release_completion_domain = "maru.event-release-completion.v2";
const settlement_scratch_range_domain = "maru.settlement-scratch-range.v1";
const prepared_effect_permit_domain = "maru.prepared-effect-permit.v1";
const effect_commit_evidence_domain = "maru.effect-commit-evidence.v1";
const pending_event_release_begun_domain = "maru.pending-event-release-begun.v1";
const event_release_leaf_receipt_domain = "maru.event-release-leaf-receipt.v1";
const event_release_phase_receipt_domain = "maru.event-release-phase-receipt.v1";
const terminal_cleanup_identity_domain = "maru.terminal-cleanup-identity.v1";
const terminal_cleanup_state_domain = "maru.terminal-cleanup-state.v1";
const terminal_drain_identity_domain = "maru.terminal-drain-identity.v1";
const terminal_drain_state_domain = "maru.terminal-drain-state.v1";
const close_authority_identity_domain = "maru.close-authority-identity.v1";
const close_authority_state_domain = "maru.close-authority-state.v1";
const close_operation_pin_domain = "maru.close-operation-pin.v1";
const runtime_admission_domain = "maru.runtime-admission.v1";
const prepared_admission_close_domain = "maru.prepared-admission-close.v1";
const prepared_retirement_cleanup_domain = "maru.prepared-retirement-cleanup.v1";
const prepared_client_replacement_domain = "maru.prepared-client-replacement.v1";
const prepared_retired_client_reclaim_domain = "maru.prepared-retired-client-reclaim.v1";
const window_close_ticket_reservation_domain = "maru.window-close-ticket-reservation.v1";
const remote_backend_singleton_domain = "maru.remote-backend-singleton.v1";
const host_reconnect_job_domain = "maru.host-reconnect-job.v1";
const host_reconnect_window_transaction_domain = "maru.host-reconnect-window-transaction.v1";
const host_reconnect_window_owner_domain = "maru.host-reconnect-window-owner.v1";
const session_host_coordinator_domain = "maru.session-host-coordinator.v1";
const external_reconnect_receipt_domain = "maru.external-reconnect-receipt.v1";
const reconnect_close_receipt_domain = "maru.reconnect-close-receipt.v1";
const prepared_host_publication_domain = "maru.prepared-host-publication.v1";
const incident_binding_domain = "maru.incident-binding.v1";
const incident_publisher_authority_domain = "maru.incident-publisher-authority.v1";
const incident_publisher_lease_domain = "maru.incident-publisher-lease.v1";
const incident_client_operation_domain = "maru.incident-client-operation.v1";
const incident_repeat_key_domain = "maru.incident-repeat-key.v1";
const prepared_incident_publication_domain = "maru.prepared-incident-publication.v1";
const prepared_managed_poison_domain = "maru.prepared-managed-poison.v1";
const incident_publication_port_domain = "maru.incident-publication-port.v1";
const incident_publication_timestamp_domain = "maru.incident-publication-timestamp.v1";
const reconnect_admission_domain = "maru.reconnect-admission.v1";
const prepared_reconnect_dispatch_domain = "maru.prepared-reconnect-dispatch.v1";
const reconnect_executor_admission_domain = "maru.reconnect-executor-admission.v1";
const pending_term_close_domain = "maru.pending-term-close.v1";
const pending_term_close_graph_domain = "maru.pending-term-close-graph.v1";
const shutdown_attempt_authority_domain = "maru.shutdown-attempt-authority.v1";
const shutdown_connection_receipt_domain = "maru.shutdown-connection-receipt.v1";
const pending_app_quit_shutdown_domain = "maru.pending-app-quit-shutdown.v1";

pub const CleanupSeal = cleanup_seal.CleanupSeal;
pub const CleanupTranscriptInput = cleanup_seal.CleanupTranscriptInput;
pub const CleanupProgressInput = cleanup_seal.CleanupProgressInput;
pub const PendingOperationSealInput = cleanup_seal.PendingOperationSealInput;
pub const PendingReleaseSealInput = cleanup_seal.PendingReleaseSealInput;
pub const PendingSourceReceiptSealInput = cleanup_seal.PendingSourceReceiptSealInput;
pub const PendingSourceLeaseSealInput = cleanup_seal.PendingSourceLeaseSealInput;
pub const PendingPreparationFrameSealInput = cleanup_seal.PendingPreparationFrameSealInput;
pub const SettlementScratchProofSealInput = cleanup_seal.SettlementScratchProofSealInput;
pub const RuntimeSettlementLeaseSealInput = cleanup_seal.RuntimeSettlementLeaseSealInput;
pub const RuntimeSettlementBindingSealInput = cleanup_seal.RuntimeSettlementBindingSealInput;
pub const PendingSettlementPermitSealInput = cleanup_seal.PendingSettlementPermitSealInput;
pub const SettlementDispositionSealInput = cleanup_seal.SettlementDispositionSealInput;
pub const PreparedSemanticCommitSealInput = cleanup_seal.PreparedSemanticCommitSealInput;
pub const PreparedEventReleasePermitSealInput = cleanup_seal.PreparedEventReleasePermitSealInput;
pub const EventReleaseCompletionSealInput = cleanup_seal.EventReleaseCompletionSealInput;
pub const SettlementScratchRangeSealInput = cleanup_seal.SettlementScratchRangeSealInput;
pub const PreparedEffectPermitSealInput = cleanup_seal.PreparedEffectPermitSealInput;
pub const EffectCommitEvidenceSealInput = cleanup_seal.EffectCommitEvidenceSealInput;
pub const PendingEventReleaseBegunSealInput = cleanup_seal.PendingEventReleaseBegunSealInput;
pub const EventReleaseLeafReceiptSealInput = cleanup_seal.EventReleaseLeafReceiptSealInput;
pub const EventReleasePhaseReceiptSealInput = cleanup_seal.EventReleasePhaseReceiptSealInput;
pub const TerminalCleanupIdentitySealInput = cleanup_seal.TerminalCleanupIdentitySealInput;
pub const TerminalCleanupStateSealInput = cleanup_seal.TerminalCleanupStateSealInput;
pub const TerminalDrainIdentitySealInput = cleanup_seal.TerminalDrainIdentitySealInput;
pub const TerminalDrainStateSealInput = cleanup_seal.TerminalDrainStateSealInput;
pub const CloseAuthorityIdentitySealInput = cleanup_seal.CloseAuthorityIdentitySealInput;
pub const CloseAuthorityStateSealInput = cleanup_seal.CloseAuthorityStateSealInput;
pub const CloseOperationPinSealInput = cleanup_seal.CloseOperationPinSealInput;
pub const RuntimeAdmissionSealInput = cleanup_seal.RuntimeAdmissionSealInput;
pub const PreparedAdmissionCloseSealInput = cleanup_seal.PreparedAdmissionCloseSealInput;
pub const PreparedRetirementCleanupSealInput = cleanup_seal.PreparedRetirementCleanupSealInput;
pub const PreparedClientReplacementSealInput = cleanup_seal.PreparedClientReplacementSealInput;
pub const PreparedRetiredClientReclaimSealInput = cleanup_seal.PreparedRetiredClientReclaimSealInput;
pub const WindowCloseTicketReservationSealInput = cleanup_seal.WindowCloseTicketReservationSealInput;
pub const RemoteBackendSingletonSealInput = cleanup_seal.RemoteBackendSingletonSealInput;
pub const HostReconnectJobSealInput = cleanup_seal.HostReconnectJobSealInput;
pub const HostReconnectWindowTransactionSealInput = cleanup_seal.HostReconnectWindowTransactionSealInput;
pub const HostReconnectWindowOwnerSealInput = cleanup_seal.HostReconnectWindowOwnerSealInput;
pub const SessionHostCoordinatorSealInput = cleanup_seal.SessionHostCoordinatorSealInput;
pub const ExternalReconnectReceiptSealInput = cleanup_seal.ExternalReconnectReceiptSealInput;
pub const ReconnectCloseReceiptSealInput = cleanup_seal.ReconnectCloseReceiptSealInput;
pub const PreparedHostPublicationSealInput = cleanup_seal.PreparedHostPublicationSealInput;
pub const IncidentBindingSealInput = cleanup_seal.IncidentBindingSealInput;
pub const IncidentPublisherAuthoritySealInput = cleanup_seal.IncidentPublisherAuthoritySealInput;
pub const IncidentPublisherLeaseSealInput = cleanup_seal.IncidentPublisherLeaseSealInput;
pub const IncidentClientOperationSealInput = cleanup_seal.IncidentClientOperationSealInput;
pub const IncidentRepeatKeySealInput = cleanup_seal.IncidentRepeatKeySealInput;
pub const PreparedIncidentPublicationSealInput = cleanup_seal.PreparedIncidentPublicationSealInput;
pub const PreparedManagedPoisonSealInput = cleanup_seal.PreparedManagedPoisonSealInput;
pub const IncidentPublicationPortSealInput = cleanup_seal.IncidentPublicationPortSealInput;
pub const IncidentPublicationTimestampSealInput = cleanup_seal.IncidentPublicationTimestampSealInput;
pub const ReconnectAdmissionSealInput = cleanup_seal.ReconnectAdmissionSealInput;
pub const PreparedReconnectDispatchSealInput = cleanup_seal.PreparedReconnectDispatchSealInput;
pub const ReconnectExecutorAdmissionSealInput = cleanup_seal.ReconnectExecutorAdmissionSealInput;
pub const PendingTermCloseSealInput = cleanup_seal.PendingTermCloseSealInput;
pub const PendingTermCloseGraphSealInput = cleanup_seal.PendingTermCloseGraphSealInput;
pub const ShutdownAttemptAuthoritySealInput = cleanup_seal.ShutdownAttemptAuthoritySealInput;
pub const ShutdownConnectionReceiptSealInput = cleanup_seal.ShutdownConnectionReceiptSealInput;
pub const PendingAppQuitShutdownSealInput = cleanup_seal.PendingAppQuitShutdownSealInput;

pub const PrepareError = error{
    ProcessDomainMismatch,
    EntropyUnavailable,
    ZeroKey,
    Terminal,
};

pub const ReadyError = error{
    ProcessDomainMismatch,
    NotReady,
    Terminal,
};

pub const IntegrityReason = enum(u8) {
    invalid_runtime_lifetime = 1,
    invalid_source_authority = 2,
    invalid_preparation_frame = 3,
    callback_drift = 4,
    counter_exhausted = 5,
    destructive_reentry = 6,
    proof_loss = 7,
    invalid_pending_close_lifecycle = 8,
    close_ticket_exhausted = 9,
    close_runtime_absent = 10,
    active_close_operation = 11,
    incident_authority = 12,
    unexpected_connection_poison = 13,
};

// Diagnostic evidence only: it grants no cleanup or recovery authority, and the first reason wins.
var integrity_evidence: std.atomic.Value(u8) = .init(0);

/// **죽기 전에 사유와 호출 지점을 남긴다.** 이 함수는 484 곳에서 불리는데, 사유를 원자 변수에만
/// 담고 어디에도 쓰지 않은 채 `_exit(86)` 했다 — 바로 위 주석이 "Diagnostic evidence only" 라고
/// 적어 둔 그 증거가 프로세스와 함께 사라진다.
///
/// 2026-08-29~30 실측: 앱이 업데이트마다 조용히 사라졌다. `_exit` 은 `atexit` 도 시그널 핸들러도
/// 못 잡으므로 앱 로그에 한 줄도 없고 크래시 리포트도 없다. 그래서 종료 마커조차 안 찍혀
/// «SIGKILL 이다» 라고 오판했고, launchd 의 `exited due to exit(86)` 을 시스템 로그에서 찾고 나서야
/// 이 함수에 도달했다. 계측을 넣자 사유가 `proof_loss(7)` 로 즉시 드러났다.
///
/// 두 줄을 쓴다. 먼저 사유 한 줄 — 이건 실패하지 않는다. 그 다음 스택 추적으로 **호출자의 파일:줄**
/// 을 남긴다. 사유만으로는 안 좁혀지기 때문이다: `proof_loss` 하나가 339 곳에서 불리고 그중 198 곳이
/// `remote_term_backend.zig` 한 파일이다. `@returnAddress()` 를 먼저 시도했지만 ReleaseFast 의
/// tail call 때문에 이 함수 자신을 가리켜 쓸모가 없었다(실측).
///
/// 스택 추적은 무겁고 async-signal-safe 하지 않지만 여기는 어차피 죽는 자리다 — 그 비용으로 484 개
/// 호출처 중 어디였는지를 산다. 실패해도 사유 한 줄은 이미 나간 뒤다. 동작은 그대로 —
/// 여전히 즉시 `_exit(86)` 하고 아무 정리도 복구도 하지 않는다.
pub fn fatalIntegrity(reason: IntegrityReason) noreturn {
    _ = integrity_evidence.cmpxchgStrong(0, @intFromEnum(reason), .acq_rel, .acquire);
    if (!builtin.is_test) {
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "fatal integrity: reason={s}({d}) — process exits with 86\n",
            .{ @tagName(reason), @intFromEnum(reason) },
        ) catch "fatal integrity: reason=<unformattable> — process exits with 86\n";
        _ = std.c.write(2, line.ptr, line.len);
        std.debug.dumpCurrentStackTrace(.{});
    }
    switch (builtin.os.tag) {
        .macos, .linux => std.c._exit(86),
        else => @trap(),
    }
}

pub const PreparedReceipt = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    incarnation: u64 = 0,
    token: u64 = 0,
};

pub const CapabilityKeyInput = struct {
    counter: u64,
    slot_index: u16,
    slot_generation: u64,
};

pub const ReadyIdentity = struct {
    pid: u32,
    process_nonce: u64,
};

const State = enum(u8) {
    uninitialized,
    initializing,
    ready,
    terminal,
};

const EntropyMode = union(enum) {
    production,
    zero,
    unavailable,
    scalar_seed: u64,
    scalar_seed_zero_output: u64,
};

const PauseHook = struct {
    reached: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
};

const Service = struct {
    state: std.atomic.Value(u8) = .init(@intFromEnum(State.uninitialized)),
    owner_pid: u32 = 0,
    owner_nonce: u64 = 0,
    incarnation: u64 = 0,
    receipt_token: u64 = 0,
    secret: [secret_len]u8 = [_]u8{0} ** secret_len,
    pause_hook: if (builtin.is_test) ?*PauseHook else void = if (builtin.is_test) null else {},

    fn loadState(self: *const Service, comptime order: std.builtin.AtomicOrder) State {
        return @enumFromInt(self.state.load(order));
    }

    fn publishTerminal(self: *Service) void {
        self.state.store(@intFromEnum(State.terminal), .release);
    }

    fn secureEntropy(destination: []u8) PrepareError!void {
        switch (builtin.os.tag) {
            .macos => std.c.arc4random_buf(destination.ptr, destination.len),
            .linux => {
                var offset: usize = 0;
                while (offset < destination.len) {
                    const rc = std.c.getrandom(destination[offset..].ptr, destination.len - offset, 0);
                    if (rc < 0) {
                        if (std.posix.errno(rc) == .INTR) continue;
                        return error.EntropyUnavailable;
                    }
                    if (rc == 0) return error.EntropyUnavailable;
                    offset += @intCast(rc);
                }
            },
            else => return error.EntropyUnavailable,
        }
    }

    fn fillEntropy(self: *Service, mode: EntropyMode) PrepareError!void {
        switch (mode) {
            .production => try secureEntropy(&self.secret),
            .zero => @memset(&self.secret, 0),
            .unavailable => return error.EntropyUnavailable,
            .scalar_seed, .scalar_seed_zero_output => |seed_value| {
                if (seed_value == 0) return error.ZeroKey;
                var hasher = std.crypto.hash.Blake3.init(.{});
                hasher.update("maru.process-seal.test-seed.v1");
                var seed: [8]u8 = undefined;
                std.mem.writeInt(u64, &seed, seed_value, .little);
                hasher.update(&seed);
                hasher.final(&self.secret);
                if (mode == .scalar_seed_zero_output) @memset(&self.secret, 0);
            },
        }
    }

    fn prepareWithEntropy(
        self: *Service,
        pid: u32,
        process_nonce: u64,
        mode: EntropyMode,
    ) PrepareError!PreparedReceipt {
        if (pid == 0 or process_nonce == 0 or currentProcessId() != pid)
            return error.ProcessDomainMismatch;

        const observed = self.loadState(.acquire);
        if (observed == .terminal) return error.Terminal;
        if (observed != .uninitialized) return error.ProcessDomainMismatch;
        if (self.state.cmpxchgStrong(
            @intFromEnum(State.uninitialized),
            @intFromEnum(State.initializing),
            .acq_rel,
            .acquire,
        )) |_| return error.ProcessDomainMismatch;

        self.owner_pid = pid;
        self.owner_nonce = process_nonce;
        self.incarnation = 1;
        self.fillEntropy(mode) catch |err| {
            self.publishTerminal();
            return err;
        };
        var any: u8 = 0;
        for (self.secret) |byte| any |= byte;
        if (any == 0) {
            self.publishTerminal();
            return error.ZeroKey;
        }
        if (builtin.is_test) {
            if (self.pause_hook) |hook| {
                hook.reached.store(true, .release);
                while (!hook.proceed.load(.acquire)) std.atomic.spinLoopHint();
            }
        }

        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update("maru.process-seal.prepared-receipt.v1");
        var material: [20]u8 = undefined;
        std.mem.writeInt(u32, material[0..4], pid, .little);
        std.mem.writeInt(u64, material[4..12], process_nonce, .little);
        std.mem.writeInt(u64, material[12..20], self.incarnation, .little);
        hasher.update(&material);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        self.receipt_token = std.mem.readInt(u64, digest[0..8], .little);
        if (self.receipt_token == 0) {
            self.publishTerminal();
            return error.ZeroKey;
        }
        return .{
            .pid = pid,
            .process_nonce = process_nonce,
            .incarnation = self.incarnation,
            .token = self.receipt_token,
        };
    }

    fn fatalInvalidReceipt() noreturn {
        switch (builtin.os.tag) {
            .macos, .linux => std.c._exit(70),
            else => @trap(),
        }
    }

    fn commitReady(self: *Service, receipt: PreparedReceipt) void {
        if (self.loadState(.acquire) != .initializing or receipt.pid != self.owner_pid or
            receipt.process_nonce != self.owner_nonce or receipt.incarnation != self.incarnation or
            receipt.token == 0 or receipt.token != self.receipt_token)
            fatalInvalidReceipt();
        self.receipt_token = 0;
        self.state.store(@intFromEnum(State.ready), .release);
    }

    fn validateReady(self: *const Service, pid: u32, process_nonce: u64) ReadyError!void {
        // This PID check intentionally precedes every inherited secret or lock access.
        if (pid == 0 or process_nonce == 0 or currentProcessId() != pid)
            return error.ProcessDomainMismatch;
        switch (self.loadState(.acquire)) {
            .uninitialized, .initializing => return error.NotReady,
            .terminal => return error.Terminal,
            .ready => {},
        }
        if (self.owner_pid != pid or self.owner_nonce != process_nonce)
            return error.ProcessDomainMismatch;
    }

    fn currentReadyIdentity(self: *const Service) ReadyError!ReadyIdentity {
        const pid = currentProcessId();
        if (pid == 0) return error.ProcessDomainMismatch;
        switch (self.loadState(.acquire)) {
            .uninitialized, .initializing => return error.NotReady,
            .terminal => return error.Terminal,
            .ready => {},
        }
        // A ready service rejects a fork before returning inherited process-domain material.
        if (self.owner_pid != pid or self.owner_nonce == 0) return error.ProcessDomainMismatch;
        return .{ .pid = pid, .process_nonce = self.owner_nonce };
    }

    fn capabilityRegistryKey(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        input: CapabilityKeyInput,
    ) ReadyError!u64 {
        try self.validateReady(pid, process_nonce);
        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update(capability_domain);
        var transcript: [18]u8 = undefined;
        std.mem.writeInt(u64, transcript[0..8], input.counter, .little);
        std.mem.writeInt(u16, transcript[8..10], input.slot_index, .little);
        std.mem.writeInt(u64, transcript[10..18], input.slot_generation, .little);
        hasher.update(&transcript);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const key = std.mem.readInt(u64, digest[0..8], .little);
        if (key == 0) fatalInvalidReceipt();
        return key;
    }

    fn cleanupTranscriptSealAfterReady(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        input: CleanupTranscriptInput,
    ) CleanupSeal {
        cleanup_seal.assertCleanupTranscriptCanonical(input);
        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update(cleanup_transcript_domain);
        updateInt(&hasher, u32, pid);
        updateInt(&hasher, u64, process_nonce);
        updateCleanupTranscript(&hasher, input);
        var result: CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn cleanupTranscriptSeal(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        input: CleanupTranscriptInput,
    ) ReadyError!CleanupSeal {
        try self.validateReady(pid, process_nonce);
        return self.cleanupTranscriptSealAfterReady(pid, process_nonce, input);
    }

    fn cleanupProgressSeal(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        input: CleanupProgressInput,
    ) ReadyError!CleanupSeal {
        try self.validateReady(pid, process_nonce);
        cleanup_seal.assertCleanupProgressCanonical(input);
        const transcript = self.cleanupTranscriptSealAfterReady(
            pid,
            process_nonce,
            input.transcript_input,
        );
        if (!std.crypto.timing_safe.eql(CleanupSeal, transcript, input.transcript_seal))
            fatalInvalidReceipt();
        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update(cleanup_progress_domain);
        updateInt(&hasher, u32, pid);
        updateInt(&hasher, u64, process_nonce);
        updateCleanupProgress(&hasher, input);
        var result: CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn pendingSeal(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        domain: []const u8,
        input: anytype,
    ) ReadyError!CleanupSeal {
        try self.validateReady(pid, process_nonce);
        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update(domain);
        updateInt(&hasher, u32, pid);
        updateInt(&hasher, u64, process_nonce);
        updateFixedValue(&hasher, input);
        var result: CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }
};

fn updateInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn updateCleanupProgress(hasher: *std.crypto.hash.Blake3, input: CleanupProgressInput) void {
    updateCleanupTranscript(hasher, input.transcript_input);
    hasher.update(&input.transcript_seal);
    updateInt(hasher, u8, @intFromEnum(input.phase));
    updateInt(hasher, u8, @intFromEnum(input.step));
    updateInt(hasher, u8, @intFromEnum(input.next_role));
    updateInt(hasher, u8, input.completed_mask);
    hasher.update(&input.retained_observation_digest);
    updateFixedValue(hasher, input.decision);
}

/// Canonical, padding-free encoder for the closed pointer-free seal input graph.
fn updateFixedValue(hasher: *std.crypto.hash.Blake3, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => updateInt(hasher, T, value),
        .array => |array| {
            if (array.child != u8) @compileError("seal arrays must contain bytes");
            hasher.update(&value);
        },
        .@"struct" => inline for (std.meta.fields(T)) |field|
            updateFixedValue(hasher, @field(value, field.name)),
        else => @compileError("pending seal inputs must remain pointer-free fixed values"),
    }
}

fn updateDescriptor(hasher: *std.crypto.hash.Blake3, value: cleanup_seal.CleanupDescriptor) void {
    updateInt(hasher, u8, value.present);
    updateInt(hasher, u64, value.address);
    updateInt(hasher, u64, value.length_bytes);
    updateInt(hasher, u64, value.capacity_bytes);
    updateInt(hasher, u8, value.alignment_log2);
    updateInt(hasher, u64, value.allocator_ptr);
    updateInt(hasher, u64, value.allocator_vtable);
}

fn updateGraph(hasher: *std.crypto.hash.Blake3, graph: cleanup_seal.ObservationCleanupGraph) void {
    inline for (std.meta.fields(cleanup_seal.ObservationCleanupGraph)) |field|
        updateDescriptor(hasher, @field(graph, field.name));
}

fn updatePlan(hasher: *std.crypto.hash.Blake3, plan: cleanup_seal.CleanupPlanInput) void {
    updateInt(hasher, u8, @intFromEnum(std.meta.activeTag(plan)));
    switch (plan) {
        .preparation => |value| {
            updateDescriptor(hasher, value.dto_backing);
            updateGraph(hasher, value.next_observation);
        },
        .committed_observation => |value| updateGraph(hasher, value.old_observation),
    }
}

fn updateCleanupTranscript(
    hasher: *std.crypto.hash.Blake3,
    input: CleanupTranscriptInput,
) void {
    updateInt(hasher, u128, input.host_id);
    updateInt(hasher, u128, input.runtime_id);
    updateInt(hasher, u64, input.connection_generation);
    updateInt(hasher, u64, input.slot_incarnation);
    updateInt(hasher, u64, input.owner_node_incarnation);
    updateInt(hasher, u64, input.transport_incarnation);
    updateInt(hasher, u64, input.registry_incarnation);
    updateInt(hasher, u64, input.binding_reservation_id);
    updateInt(hasher, u64, input.event_node_incarnation);
    updateInt(hasher, u64, input.stream_id);
    updateInt(hasher, u64, input.event_generation);
    updateInt(hasher, u64, input.event_owner_addr);
    updateInt(hasher, u16, input.wire_major);
    updateInt(hasher, u16, input.expected_major);
    updateInt(hasher, u8, input.metadata_support_raw);
    updateInt(hasher, u8, input.admission_tag);
    hasher.update(&input.correlation_binding_digest);
    hasher.update(&input.payload_digest);
    hasher.update(&input.admission_projection_digest);
    updateInt(hasher, u64, input.pending_owner_addr);
    updateInt(hasher, u64, input.pending_owner_incarnation);
    updateInt(hasher, u64, input.cleanup_plan_addr);
    updateInt(hasher, u64, input.runtime_addr);
    updateInt(hasher, u64, input.observation_addr);
    updateInt(hasher, u64, input.observation_revision);
    updateInt(hasher, u64, input.observer_generation);
    updateInt(hasher, u32, input.title_generation);
    hasher.update(&input.observation_digest);
    updateInt(hasher, u64, input.preparation_attempt);
    updateInt(hasher, u8, @intFromEnum(input.pending_lifecycle));
    updatePlan(hasher, input.plan);
}

var process_service: Service = .{};

pub const testing_api = if (builtin.is_test) struct {
    /// fork child가 상속한 ready seal만 exec의 fresh global 상태로 되돌린다.
    /// pristine 프로세스는 손대지 않고, 같은 PID의 live seal은 절대 초기화하지 않는다.
    pub fn resetInheritedForkedDaemonProcessSealIfPresent() error{InvalidTestState}!void {
        const current_pid = currentProcessId();
        if (current_pid == 0) return error.InvalidTestState;
        switch (process_service.loadState(.acquire)) {
            .uninitialized => return,
            .ready => {
                if (process_service.owner_pid == 0 or process_service.owner_pid == current_pid)
                    return error.InvalidTestState;
                process_service = .{};
            },
            .initializing, .terminal => return error.InvalidTestState,
        }
    }
} else struct {};

pub fn currentProcessId() u32 {
    return process_identity.currentProcessId();
}

pub fn generateProcessNonce() PrepareError!u64 {
    var bytes: [8]u8 = undefined;
    try Service.secureEntropy(&bytes);
    const nonce = std.mem.readInt(u64, &bytes, .little);
    if (nonce == 0) return error.ZeroKey;
    return nonce;
}

pub fn prepare(pid: u32, process_nonce: u64) PrepareError!PreparedReceipt {
    return process_service.prepareWithEntropy(pid, process_nonce, .production);
}

pub fn commitReady(receipt: PreparedReceipt) void {
    process_service.commitReady(receipt);
}

pub fn validateReady(pid: u32, process_nonce: u64) ReadyError!void {
    return process_service.validateReady(pid, process_nonce);
}

pub fn currentReadyIdentity() ReadyError!ReadyIdentity {
    return process_service.currentReadyIdentity();
}

pub fn capabilityRegistryKey(
    pid: u32,
    process_nonce: u64,
    input: CapabilityKeyInput,
) ReadyError!u64 {
    return process_service.capabilityRegistryKey(pid, process_nonce, input);
}

pub fn cleanupTranscriptSeal(
    pid: u32,
    process_nonce: u64,
    input: CleanupTranscriptInput,
) ReadyError!CleanupSeal {
    return process_service.cleanupTranscriptSeal(pid, process_nonce, input);
}

pub fn cleanupProgressSeal(
    pid: u32,
    process_nonce: u64,
    input: CleanupProgressInput,
) ReadyError!CleanupSeal {
    return process_service.cleanupProgressSeal(pid, process_nonce, input);
}

pub fn pendingOperationSeal(pid: u32, process_nonce: u64, input: PendingOperationSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_operation_domain, input);
}

pub fn pendingReleaseSeal(pid: u32, process_nonce: u64, input: PendingReleaseSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_release_domain, input);
}

pub fn pendingSourceReceiptSeal(pid: u32, process_nonce: u64, input: PendingSourceReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_source_receipt_domain, input);
}

pub fn pendingSourceLeaseSeal(pid: u32, process_nonce: u64, input: PendingSourceLeaseSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_source_lease_domain, input);
}

pub fn pendingPreparationFrameSeal(pid: u32, process_nonce: u64, input: PendingPreparationFrameSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_preparation_frame_domain, input);
}

pub fn settlementScratchProofSeal(pid: u32, process_nonce: u64, input: SettlementScratchProofSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, settlement_scratch_proof_domain, input);
}

pub fn runtimeSettlementLeaseSeal(pid: u32, process_nonce: u64, input: RuntimeSettlementLeaseSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, runtime_settlement_lease_domain, input);
}

pub fn runtimeSettlementBindingSeal(pid: u32, process_nonce: u64, input: RuntimeSettlementBindingSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, runtime_settlement_binding_domain, input);
}

pub fn pendingSettlementPermitSeal(pid: u32, process_nonce: u64, input: PendingSettlementPermitSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_settlement_permit_domain, input);
}

pub fn settlementDispositionSeal(pid: u32, process_nonce: u64, input: SettlementDispositionSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, settlement_disposition_domain, input);
}

pub fn preparedSemanticCommitSeal(pid: u32, process_nonce: u64, input: PreparedSemanticCommitSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_semantic_commit_domain, input);
}

pub fn preparedEventReleasePermitSeal(pid: u32, process_nonce: u64, input: PreparedEventReleasePermitSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_event_release_permit_domain, input);
}

pub fn eventReleaseCompletionSeal(pid: u32, process_nonce: u64, input: EventReleaseCompletionSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, event_release_completion_domain, input);
}

pub fn settlementScratchRangeSeal(pid: u32, process_nonce: u64, input: SettlementScratchRangeSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, settlement_scratch_range_domain, input);
}

pub fn preparedEffectPermitSeal(pid: u32, process_nonce: u64, input: PreparedEffectPermitSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_effect_permit_domain, input);
}

pub fn effectCommitEvidenceSeal(pid: u32, process_nonce: u64, input: EffectCommitEvidenceSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, effect_commit_evidence_domain, input);
}

pub fn pendingEventReleaseBegunSeal(pid: u32, process_nonce: u64, input: PendingEventReleaseBegunSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_event_release_begun_domain, input);
}

pub fn eventReleaseLeafReceiptSeal(pid: u32, process_nonce: u64, input: EventReleaseLeafReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, event_release_leaf_receipt_domain, input);
}
pub fn eventReleasePhaseReceiptSeal(pid: u32, process_nonce: u64, input: EventReleasePhaseReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, event_release_phase_receipt_domain, input);
}

pub fn terminalCleanupIdentitySeal(pid: u32, process_nonce: u64, input: TerminalCleanupIdentitySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, terminal_cleanup_identity_domain, input);
}

pub fn terminalCleanupStateSeal(pid: u32, process_nonce: u64, input: TerminalCleanupStateSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, terminal_cleanup_state_domain, input);
}

pub fn terminalDrainIdentitySeal(pid: u32, process_nonce: u64, input: TerminalDrainIdentitySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, terminal_drain_identity_domain, input);
}

pub fn terminalDrainStateSeal(pid: u32, process_nonce: u64, input: TerminalDrainStateSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, terminal_drain_state_domain, input);
}

pub fn closeAuthorityIdentitySeal(pid: u32, process_nonce: u64, input: CloseAuthorityIdentitySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, close_authority_identity_domain, input);
}

pub fn closeAuthorityStateSeal(pid: u32, process_nonce: u64, input: CloseAuthorityStateSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, close_authority_state_domain, input);
}

pub fn closeOperationPinSeal(pid: u32, process_nonce: u64, input: CloseOperationPinSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, close_operation_pin_domain, input);
}

pub fn runtimeAdmissionSeal(pid: u32, process_nonce: u64, input: RuntimeAdmissionSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, runtime_admission_domain, input);
}

pub fn preparedAdmissionCloseSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedAdmissionCloseSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_admission_close_domain, input);
}

pub fn preparedRetirementCleanupSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedRetirementCleanupSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_retirement_cleanup_domain, input);
}

pub fn preparedClientReplacementSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedClientReplacementSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_client_replacement_domain, input);
}

pub fn preparedRetiredClientReclaimSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedRetiredClientReclaimSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_retired_client_reclaim_domain, input);
}

pub fn windowCloseTicketReservationSeal(pid: u32, process_nonce: u64, input: WindowCloseTicketReservationSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, window_close_ticket_reservation_domain, input);
}

pub fn remoteBackendSingletonSeal(pid: u32, process_nonce: u64, input: RemoteBackendSingletonSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, remote_backend_singleton_domain, input);
}

pub fn hostReconnectJobSeal(pid: u32, process_nonce: u64, input: HostReconnectJobSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, host_reconnect_job_domain, input);
}

pub fn hostReconnectWindowTransactionSeal(
    pid: u32,
    process_nonce: u64,
    input: HostReconnectWindowTransactionSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, host_reconnect_window_transaction_domain, input);
}

pub fn hostReconnectWindowOwnerSeal(
    pid: u32,
    process_nonce: u64,
    input: HostReconnectWindowOwnerSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, host_reconnect_window_owner_domain, input);
}

pub fn sessionHostCoordinatorSeal(pid: u32, process_nonce: u64, input: SessionHostCoordinatorSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, session_host_coordinator_domain, input);
}

pub fn externalReconnectReceiptSeal(pid: u32, process_nonce: u64, input: ExternalReconnectReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, external_reconnect_receipt_domain, input);
}

pub fn reconnectCloseReceiptSeal(pid: u32, process_nonce: u64, input: ReconnectCloseReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, reconnect_close_receipt_domain, input);
}

pub fn preparedHostPublicationSeal(pid: u32, process_nonce: u64, input: PreparedHostPublicationSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_host_publication_domain, input);
}

pub fn incidentBindingSeal(pid: u32, process_nonce: u64, input: IncidentBindingSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_binding_domain, input);
}

pub fn incidentPublisherAuthoritySeal(pid: u32, process_nonce: u64, input: IncidentPublisherAuthoritySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_publisher_authority_domain, input);
}

pub fn incidentPublisherLeaseSeal(pid: u32, process_nonce: u64, input: IncidentPublisherLeaseSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_publisher_lease_domain, input);
}

pub fn incidentClientOperationSeal(pid: u32, process_nonce: u64, input: IncidentClientOperationSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_client_operation_domain, input);
}

pub fn incidentRepeatKeySeal(pid: u32, process_nonce: u64, input: IncidentRepeatKeySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_repeat_key_domain, input);
}

pub fn preparedIncidentPublicationSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedIncidentPublicationSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_incident_publication_domain, input);
}

pub fn preparedManagedPoisonSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedManagedPoisonSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_managed_poison_domain, input);
}

pub fn incidentPublicationPortSeal(
    pid: u32,
    process_nonce: u64,
    input: IncidentPublicationPortSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_publication_port_domain, input);
}

pub fn incidentPublicationTimestampSeal(
    pid: u32,
    process_nonce: u64,
    input: IncidentPublicationTimestampSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, incident_publication_timestamp_domain, input);
}

pub fn reconnectAdmissionSeal(
    pid: u32,
    process_nonce: u64,
    input: ReconnectAdmissionSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, reconnect_admission_domain, input);
}

pub fn preparedReconnectDispatchSeal(
    pid: u32,
    process_nonce: u64,
    input: PreparedReconnectDispatchSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, prepared_reconnect_dispatch_domain, input);
}

pub fn reconnectExecutorAdmissionSeal(
    pid: u32,
    process_nonce: u64,
    input: ReconnectExecutorAdmissionSealInput,
) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, reconnect_executor_admission_domain, input);
}

pub fn pendingTermCloseSeal(pid: u32, process_nonce: u64, input: PendingTermCloseSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_term_close_domain, input);
}

pub fn pendingTermCloseGraphSeal(pid: u32, process_nonce: u64, input: PendingTermCloseGraphSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_term_close_graph_domain, input);
}

pub fn shutdownAttemptAuthoritySeal(pid: u32, process_nonce: u64, input: ShutdownAttemptAuthoritySealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, shutdown_attempt_authority_domain, input);
}

pub fn shutdownConnectionReceiptSeal(pid: u32, process_nonce: u64, input: ShutdownConnectionReceiptSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, shutdown_connection_receipt_domain, input);
}

pub fn pendingAppQuitShutdownSeal(pid: u32, process_nonce: u64, input: PendingAppQuitShutdownSealInput) ReadyError!CleanupSeal {
    return process_service.pendingSeal(pid, process_nonce, pending_app_quit_shutdown_domain, input);
}

fn testCleanupDescriptor(address: u64) cleanup_seal.CleanupDescriptor {
    return .{
        .present = 1,
        .address = address,
        .length_bytes = 8,
        .capacity_bytes = 8,
        .alignment_log2 = 3,
        .allocator_ptr = 0x8000,
        .allocator_vtable = 0x9000,
    };
}

fn testCleanupTranscript() CleanupTranscriptInput {
    var graph: cleanup_seal.ObservationCleanupGraph = .{};
    graph.cwd = testCleanupDescriptor(0x1000);
    return .{
        .host_id = 1,
        .runtime_id = 2,
        .connection_generation = 3,
        .slot_incarnation = 4,
        .owner_node_incarnation = 5,
        .transport_incarnation = 6,
        .registry_incarnation = 7,
        .binding_reservation_id = 8,
        .event_node_incarnation = 9,
        .stream_id = 10,
        .event_generation = 11,
        .event_owner_addr = 0x2000,
        .wire_major = 2,
        .expected_major = 2,
        .metadata_support_raw = 1,
        .admission_tag = 1,
        .correlation_binding_digest = [_]u8{1} ** 32,
        .payload_digest = [_]u8{2} ** 32,
        .admission_projection_digest = [_]u8{3} ** 32,
        .pending_owner_addr = 0x3000,
        .pending_owner_incarnation = 12,
        .cleanup_plan_addr = 0x4000,
        .runtime_addr = 0x5000,
        .observation_addr = 0x6000,
        .observation_revision = 13,
        .observer_generation = 14,
        .title_generation = 15,
        .observation_digest = [_]u8{4} ** 32,
        .preparation_attempt = 16,
        .pending_lifecycle = .preparing,
        .plan = .{ .preparation = .{
            .dto_backing = testCleanupDescriptor(0x7000),
            .next_observation = graph,
        } },
    };
}

fn testEncodedTranscript(input: CleanupTranscriptInput) CleanupSeal {
    var hasher = std.crypto.hash.Blake3.init(.{ .key = [_]u8{0x5a} ** 32 });
    hasher.update(cleanup_transcript_domain);
    updateInt(&hasher, u32, 1234);
    updateInt(&hasher, u64, 906);
    updateCleanupTranscript(&hasher, input);
    var result: CleanupSeal = undefined;
    hasher.final(&result);
    return result;
}

fn testEncodedProgress(input: CleanupProgressInput) CleanupSeal {
    var hasher = std.crypto.hash.Blake3.init(.{ .key = [_]u8{0x5a} ** 32 });
    hasher.update(cleanup_progress_domain);
    updateInt(&hasher, u32, 1234);
    updateInt(&hasher, u64, 906);
    updateCleanupProgress(&hasher, input);
    var result: CleanupSeal = undefined;
    hasher.final(&result);
    return result;
}

test "C3-3b2b1 cleanup seal transcript is deterministic and binds process domain" {
    const pid = currentProcessId();
    var service: Service = .{};
    const receipt = try service.prepareWithEntropy(pid, 901, .{ .scalar_seed = 77 });
    service.commitReady(receipt);
    const input = testCleanupTranscript();
    const first = try service.cleanupTranscriptSeal(pid, 901, input);
    const replay = try service.cleanupTranscriptSeal(pid, 901, input);
    try std.testing.expectEqualSlices(u8, &first, &replay);
    try std.testing.expectError(
        error.ProcessDomainMismatch,
        service.cleanupTranscriptSeal(pid, 902, input),
    );
}

test "C3-3b2b1 cleanup seal transcript binds identity plan and attempt" {
    const pid = currentProcessId();
    var service: Service = .{};
    const receipt = try service.prepareWithEntropy(pid, 903, .{ .scalar_seed = 78 });
    service.commitReady(receipt);
    const baseline_input = testCleanupTranscript();
    const baseline = try service.cleanupTranscriptSeal(pid, 903, baseline_input);

    var changed = baseline_input;
    changed.event_generation += 1;
    try std.testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &try service.cleanupTranscriptSeal(pid, 903, changed),
    ));
    changed = baseline_input;
    changed.preparation_attempt += 1;
    try std.testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &try service.cleanupTranscriptSeal(pid, 903, changed),
    ));
    changed = baseline_input;
    changed.plan.preparation.dto_backing.address += 8;
    try std.testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &try service.cleanupTranscriptSeal(pid, 903, changed),
    ));
}

test "C3-3b2b1 cleanup seal progress revalidates transcript and separates domain" {
    const pid = currentProcessId();
    var service: Service = .{};
    const receipt = try service.prepareWithEntropy(pid, 904, .{ .scalar_seed = 79 });
    service.commitReady(receipt);
    const transcript_input = testCleanupTranscript();
    const transcript = try service.cleanupTranscriptSeal(pid, 904, transcript_input);
    const initial = cleanup_seal.initialProgress(transcript_input.plan);
    const progress = try service.cleanupProgressSeal(pid, 904, .{
        .transcript_input = transcript_input,
        .transcript_seal = transcript,
        .phase = initial.phase,
        .step = initial.step,
        .next_role = initial.next_role,
        .completed_mask = initial.completed_mask,
    });
    try std.testing.expect(!std.mem.eql(u8, &transcript, &progress));
    try std.testing.expectEqualSlices(
        u8,
        &progress,
        &try service.cleanupProgressSeal(pid, 904, .{
            .transcript_input = transcript_input,
            .transcript_seal = transcript,
            .phase = initial.phase,
            .step = initial.step,
            .next_role = initial.next_role,
            .completed_mask = initial.completed_mask,
        }),
    );
}

test "C3-3b2b1 cleanup seal unknown admission has a canonical zero projection" {
    const pid = currentProcessId();
    var service: Service = .{};
    const receipt = try service.prepareWithEntropy(pid, 905, .{ .scalar_seed = 80 });
    service.commitReady(receipt);
    var input = testCleanupTranscript();
    input.admission_tag = 0;
    input.admission_projection_digest = [_]u8{0} ** 32;
    _ = try service.cleanupTranscriptSeal(pid, 905, input);
}

test "C3-3b2b1 cleanup seal transcript fixed encoding has a golden digest" {
    const actual = testEncodedTranscript(testCleanupTranscript());
    const expected = [_]u8{
        0x0c, 0x65, 0x75, 0x4b, 0x82, 0xe8, 0xb0, 0xcf,
        0x62, 0x41, 0xc6, 0xbf, 0x8d, 0x52, 0x18, 0xf9,
        0x9a, 0xda, 0x95, 0x33, 0x14, 0xc7, 0x89, 0x38,
        0x4a, 0x9e, 0x15, 0x44, 0x0f, 0xa3, 0xe0, 0x71,
    };
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const progress_state = cleanup_seal.initialProgress(testCleanupTranscript().plan);
    const progress_actual = testEncodedProgress(.{
        .transcript_input = testCleanupTranscript(),
        .transcript_seal = actual,
        .phase = progress_state.phase,
        .step = progress_state.step,
        .next_role = progress_state.next_role,
        .completed_mask = progress_state.completed_mask,
    });
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x7b, 0x1d, 0x6d, 0x66, 0xc2, 0x11, 0xbb, 0xb1,
        0x5c, 0xa1, 0xdc, 0x59, 0xec, 0x7f, 0x0c, 0x5e,
        0x7a, 0x98, 0xb1, 0x94, 0xc0, 0x60, 0x99, 0xfb,
        0xfe, 0x9b, 0x6f, 0xd9, 0xcf, 0xb5, 0x3a, 0xa3,
    }, &progress_actual);
}

test "C3-3b2b1 cleanup seal transcript encoder binds every declared field" {
    const baseline_input = testCleanupTranscript();
    const baseline = testEncodedTranscript(baseline_input);
    inline for (std.meta.fields(CleanupTranscriptInput)) |field| {
        var changed = baseline_input;
        if (comptime std.mem.eql(u8, field.name, "pending_lifecycle")) {
            changed.pending_lifecycle = .prepared;
        } else if (comptime std.mem.eql(u8, field.name, "plan")) {
            changed.plan = .{ .committed_observation = .{ .old_observation = .{} } };
        } else switch (@typeInfo(field.type)) {
            .int => @field(changed, field.name) +%= 1,
            .array => @field(changed, field.name)[0] ^= 1,
            else => @compileError("unhandled cleanup transcript field type: " ++ field.name),
        }
        try std.testing.expect(!std.mem.eql(
            u8,
            &baseline,
            &testEncodedTranscript(changed),
        ));
    }

    const progress_state = cleanup_seal.initialProgress(baseline_input.plan);
    const progress_input: CleanupProgressInput = .{
        .transcript_input = baseline_input,
        .transcript_seal = baseline,
        .phase = progress_state.phase,
        .step = progress_state.step,
        .next_role = progress_state.next_role,
        .completed_mask = progress_state.completed_mask,
    };
    const progress_baseline = testEncodedProgress(progress_input);
    inline for (std.meta.fields(CleanupProgressInput)) |field| {
        var changed = progress_input;
        if (comptime std.mem.eql(u8, field.name, "transcript_input")) {
            changed.transcript_input.host_id +%= 1;
        } else if (comptime std.mem.eql(u8, field.name, "decision")) {
            changed.decision.bound_raw +%= 1;
        } else switch (@typeInfo(field.type)) {
            .int => @field(changed, field.name) +%= 1,
            .array => @field(changed, field.name)[0] ^= 1,
            .@"enum" => @field(changed, field.name) = @enumFromInt(
                @intFromEnum(@field(changed, field.name)) +% 1,
            ),
            else => @compileError("unhandled cleanup progress field type: " ++ field.name),
        }
        try std.testing.expect(!std.mem.eql(
            u8,
            &progress_baseline,
            &testEncodedProgress(changed),
        ));
    }
    inline for (std.meta.fields(@TypeOf(progress_input.decision))) |field| {
        var changed = progress_input;
        @field(changed.decision, field.name) +%= 1;
        try std.testing.expect(!std.mem.eql(
            u8,
            &progress_baseline,
            &testEncodedProgress(changed),
        ));
    }
}

test "C3-3b2b1 cleanup seal transcript encoder binds every nested cleanup descriptor" {
    const baseline_input = testCleanupTranscript();
    const baseline = testEncodedTranscript(baseline_input);
    inline for (std.meta.fields(cleanup_seal.CleanupDescriptor)) |descriptor_field| {
        var changed = baseline_input;
        @field(changed.plan.preparation.dto_backing, descriptor_field.name) +%= 1;
        try std.testing.expect(!std.mem.eql(u8, &baseline, &testEncodedTranscript(changed)));
    }
    inline for (std.meta.fields(cleanup_seal.ObservationCleanupGraph)) |owner_field| {
        inline for (std.meta.fields(cleanup_seal.CleanupDescriptor)) |descriptor_field| {
            var changed = baseline_input;
            @field(
                @field(changed.plan.preparation.next_observation, owner_field.name),
                descriptor_field.name,
            ) +%= 1;
            try std.testing.expect(!std.mem.eql(
                u8,
                &baseline,
                &testEncodedTranscript(changed),
            ));
        }
    }
    var committed_input = baseline_input;
    committed_input.plan = .{ .committed_observation = .{
        .old_observation = baseline_input.plan.preparation.next_observation,
    } };
    const committed_baseline = testEncodedTranscript(committed_input);
    inline for (std.meta.fields(cleanup_seal.ObservationCleanupGraph)) |owner_field| {
        inline for (std.meta.fields(cleanup_seal.CleanupDescriptor)) |descriptor_field| {
            var changed = committed_input;
            @field(
                @field(changed.plan.committed_observation.old_observation, owner_field.name),
                descriptor_field.name,
            ) +%= 1;
            try std.testing.expect(!std.mem.eql(
                u8,
                &committed_baseline,
                &testEncodedTranscript(changed),
            ));
        }
    }
}

test "C3-3b2b1 cleanup seal invalid transcript and progress fail-stop" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var case_id: u8 = 0;
    while (case_id < 4) : (case_id += 1) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            const pid = currentProcessId();
            var service: Service = .{};
            const receipt = service.prepareWithEntropy(
                pid,
                907,
                .{ .scalar_seed = 82 },
            ) catch std.c._exit(125);
            service.commitReady(receipt);
            var transcript_input = testCleanupTranscript();
            const transcript = service.cleanupTranscriptSeal(
                pid,
                907,
                transcript_input,
            ) catch std.c._exit(125);
            var progress = cleanup_seal.initialProgress(transcript_input.plan);
            var supplied = transcript;
            switch (case_id) {
                0 => supplied[0] ^= 1,
                1 => transcript_input.event_generation += 1,
                2 => progress.completed_mask = 0,
                3 => {
                    transcript_input.admission_tag = 1;
                    transcript_input.admission_projection_digest = [_]u8{0} ** 32;
                },
                else => unreachable,
            }
            _ = service.cleanupProgressSeal(pid, 907, .{
                .transcript_input = transcript_input,
                .transcript_seal = supplied,
                .phase = progress.phase,
                .step = progress.step,
                .next_role = progress.next_role,
                .completed_mask = progress.completed_mask,
            }) catch std.c._exit(125);
            std.c._exit(124);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
        try std.testing.expectEqual(
            @as(u8, 70),
            @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))),
        );
    }
}

test "C3-3b2a process seal publishes ready last and derives domain key" {
    var service: Service = .{};
    const pid = currentProcessId();
    const receipt = try service.prepareWithEntropy(pid, 71, .production);
    try std.testing.expectError(error.NotReady, service.validateReady(pid, 71));
    service.commitReady(receipt);
    try service.validateReady(pid, 71);
    const first = try service.capabilityRegistryKey(pid, 71, .{
        .counter = 1,
        .slot_index = 2,
        .slot_generation = 3,
    });
    const replay = try service.capabilityRegistryKey(pid, 71, .{
        .counter = 1,
        .slot_index = 2,
        .slot_generation = 3,
    });
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, replay);
    try std.testing.expectError(error.ProcessDomainMismatch, service.validateReady(pid, 72));
}

test "C3-3b2a process seal zero and entropy failure become terminal" {
    const pid = currentProcessId();
    var zero_service: Service = .{};
    try std.testing.expectError(error.ZeroKey, zero_service.prepareWithEntropy(pid, 81, .zero));
    try std.testing.expectError(error.Terminal, zero_service.prepareWithEntropy(pid, 81, .production));
    try std.testing.expectError(error.Terminal, zero_service.validateReady(pid, 81));

    var unavailable_service: Service = .{};
    try std.testing.expectError(
        error.EntropyUnavailable,
        unavailable_service.prepareWithEntropy(pid, 82, .unavailable),
    );
    try std.testing.expectError(error.Terminal, unavailable_service.validateReady(pid, 82));
}

test "C3-3b2a process seal deterministic seed rejects zero input and output" {
    const pid = currentProcessId();
    var zero_input: Service = .{};
    try std.testing.expectError(
        error.ZeroKey,
        zero_input.prepareWithEntropy(pid, 83, .{ .scalar_seed = 0 }),
    );
    try std.testing.expectError(error.Terminal, zero_input.validateReady(pid, 83));

    var zero_output: Service = .{};
    try std.testing.expectError(
        error.ZeroKey,
        zero_output.prepareWithEntropy(pid, 84, .{ .scalar_seed_zero_output = 1 }),
    );
    try std.testing.expectError(error.Terminal, zero_output.validateReady(pid, 84));

    var first: Service = .{};
    var second: Service = .{};
    const first_receipt = try first.prepareWithEntropy(pid, 85, .{ .scalar_seed = 9 });
    const second_receipt = try second.prepareWithEntropy(pid, 85, .{ .scalar_seed = 9 });
    first.commitReady(first_receipt);
    second.commitReady(second_receipt);
    const input: CapabilityKeyInput = .{ .counter = 1, .slot_index = 1, .slot_generation = 1 };
    try std.testing.expectEqual(
        try first.capabilityRegistryKey(pid, 85, input),
        try second.capabilityRegistryKey(pid, 85, input),
    );
}

test "C3-3b2a process seal concurrent first prepare has one unpublished winner" {
    const Context = struct {
        service: Service = .{},
        pid: u32,
        receipt: PreparedReceipt = .{},
        winners: std.atomic.Value(u8) = .init(0),

        fn run(self: *@This()) void {
            const receipt = self.service.prepareWithEntropy(
                self.pid,
                86,
                .{ .scalar_seed = 11 },
            ) catch return;
            self.receipt = receipt;
            _ = self.winners.fetchAdd(1, .acq_rel);
        }
    };
    var context: Context = .{ .pid = currentProcessId() };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Context.run, .{&context});
    for (&threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u8, 1), context.winners.load(.acquire));
    try std.testing.expectError(error.NotReady, context.service.validateReady(context.pid, 86));
    context.service.commitReady(context.receipt);
    try context.service.validateReady(context.pid, 86);
}

test "C3-3b2a process seal publication pause exposes only not ready" {
    const Context = struct {
        service: Service = .{},
        hook: PauseHook = .{},
        receipt: PreparedReceipt = .{},
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.receipt = self.service.prepareWithEntropy(
                currentProcessId(),
                87,
                .{ .scalar_seed = 13 },
            ) catch {
                self.failed.store(true, .release);
                return;
            };
        }
    };
    var context: Context = .{};
    context.service.pause_hook = &context.hook;
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    while (!context.hook.reached.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectError(
        error.NotReady,
        context.service.validateReady(currentProcessId(), 87),
    );
    context.hook.proceed.store(true, .release);
    thread.join();
    try std.testing.expect(!context.failed.load(.acquire));
    context.service.commitReady(context.receipt);
    try context.service.validateReady(currentProcessId(), 87);
}

test "C3-3b2a process seal rejects process domain before secret use" {
    var service: Service = .{};
    const pid = currentProcessId();
    try std.testing.expectError(
        error.ProcessDomainMismatch,
        service.prepareWithEntropy(if (pid == std.math.maxInt(u32)) pid - 1 else pid + 1, 91, .production),
    );
    try std.testing.expectEqual(State.uninitialized, service.loadState(.acquire));
}

test "C3-3b2a process seal invalid receipt and replay use fixed fatal exit" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var case_id: u8 = 0;
    while (case_id < 5) : (case_id += 1) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            var service: Service = .{};
            const receipt = service.prepareWithEntropy(
                currentProcessId(),
                101,
                .{ .scalar_seed = 19 },
            ) catch std.c._exit(125);
            if (case_id == 4) {
                service.commitReady(receipt);
                service.commitReady(receipt);
            }
            var invalid = receipt;
            switch (case_id) {
                0 => invalid.pid +%= 1,
                1 => invalid.process_nonce +%= 1,
                2 => invalid.incarnation +%= 1,
                3 => invalid.token +%= 1,
                else => unreachable,
            }
            service.commitReady(invalid);
            std.c._exit(124);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
        try std.testing.expectEqual(@as(u8, 70), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))));
    }
}

test "C3-3b2a process seal fork child rejects inherited ready state before key" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var service: Service = .{};
    const pid = currentProcessId();
    const receipt = try service.prepareWithEntropy(pid, 102, .{ .scalar_seed = 23 });
    service.commitReady(receipt);
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        service.validateReady(currentProcessId(), 102) catch |err| switch (err) {
            error.ProcessDomainMismatch => std.c._exit(0),
            else => std.c._exit(123),
        };
        std.c._exit(122);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))));
}
