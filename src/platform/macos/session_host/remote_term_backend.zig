//! remote_term_backend — host-backed `TermRuntimeBackend`(P2 계약의 원격 구현) — P3-e3-2.
//!
//! `app.InProcessTermBackend`의 형제다: 같은 `TermRuntimeBackend` vtable을 구현하되, 로컬 PTY를 소유하는 대신 client
//! RPC로 별도 host(`maru-sessiond`)에 runtime을 띄우고(그래야 GUI가 죽어도 PTY 생존) host가 push하는 화면 stream을
//! `RemoteRuntime`(조립기+원격-backed Surface)으로 조립한다. GUI는 이 backend를 in-process와 **똑같은 계약으로** 다뤄
//! spawn/attach/pump/입력/resize/close 한다 — 그래서 app_session의 spawn 체인·teardown은 backend가 로컬인지 원격인지
//! 모른다(§13 seam, e3-4 배선이 `termBackend()`가 이걸 반환하게 한다).
//!
//! 매핑: spawn→`RemoteRuntime.spawn`(runtime.spawn+attach+첫 snapshot)이 원격-backed Surface를 만들어 반환, pump→
//! `RuntimeEventPump.initRemote`(delta stream을 `DrainSummary`로 소비, e3-1), write_input→`sendInput`, resize→
//! `runtime.resize` RPC, close/remove→host terminate + client-side 회수. handle(u64)↔`RemoteRuntime`를 map으로 잇는다.
//!
//! metadata observation(cwd/title/SSH/foreground process/mode/size)은 host full-state event+fresh barrier로 읽는다.
//! focus/config/prompt command는 `runtime_core_command_v1`로 host reader에 보내며, 일반 key의
//! DECCKM/DECKPAM/kitty mode, DECSET 1003 motion과 selection autoscroll parity도 같은 원격 owner 경계를
//! 사용한다. macOS 전용(client·Surface·app 계약).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_runtime = @import("remote_runtime.zig");
const notification_delivery = @import("notification_delivery.zig");
const close_authority = @import("remote_close_authority.zig");
const close_contract = @import("remote_close_contract.zig");
const event_pump_contract = @import("remote_event_pump_contract.zig");
const process_seal = @import("process_seal_service.zig");
const pending_event_owner = @import("pending_event_owner.zig");
const core_command_wire = @import("core_command_wire.zig");
const host_pool_mod = @import("host_pool.zig");
const host_adapter_mod = @import("host_adapter.zig");
const client_slot_mod = @import("client_slot.zig");
const shutdown_attempt = @import("shutdown_attempt_authority.zig");
const shutdown_connector = @import("shutdown_admin_connector.zig");
const shutdown_current_admin = @import("shutdown_current_admin.zig");
const client_deadline = @import("client_deadline.zig");
const attach_phase_deadline = @import("attach_phase_deadline.zig");
const catchup_stage_contract = @import("catchup_stage_contract.zig");
const generation_attachment_mod = @import("generation_attachment.zig");
const host_connect = @import("host_connect.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");
const reconnect_admission_owner = @import("reconnect_admission_owner.zig");
const reconnect_resident_budget = @import("reconnect_resident_budget.zig");
const reconnect_mutation_seal = @import("reconnect_mutation_seal.zig");
const reconnect_reducer = @import("reconnect_reducer.zig");
const reconnect_worker_owner = @import("reconnect_worker_owner.zig");
const host_reconnect_runtime_ledger = @import("host_reconnect_runtime_ledger.zig");
const host_reconnect_runtime_transaction = @import("host_reconnect_runtime_transaction.zig");
const host_reconnect_window_transaction = @import("host_reconnect_window_transaction.zig");
const user_action_queue = @import("user_action_queue.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령 라우팅

const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const TermRuntimeBackend = term_backend.TermRuntimeBackend;
const InputOwnerVTable = maru.app.input_owner.VTable;
const RuntimeHandle = term_backend.RuntimeHandle;
const SpawnParams = term_backend.SpawnParams;
const RuntimeLink = maru.app.RuntimeLink;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const PtyIo = maru.app.runtime.PtyIo;
const runtime_pump = maru.app.runtime_pump;
const RuntimeEventPump = runtime_pump.RuntimeEventPump;
const client_idle_pump_evidence = @import("client_idle_pump_evidence.zig");
const DrainSummary = runtime_pump.DrainSummary;
const CoreCommand = maru.session.core_command.CoreCommand;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;
const nonblocking_input_chunk: usize = 16 * 1024;
const RemoteRuntime = remote_runtime.RemoteRuntime;
const HostAdapter = host_adapter_mod.HostAdapter;
const AdapterPool = host_pool_mod.HostPool(HostAdapter);
pub const max_remote_backend_runtimes: usize = protocol.max_inventory_runtimes;

fn boundedNotificationLabel(label: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(label)) return "";
    if (label.len <= notification_delivery.max_display_label_bytes) return label;
    var end = notification_delivery.max_display_label_bytes;
    while (end > 0 and (label[end] & 0xc0) == 0x80) end -= 1;
    return label[0..end];
}

pub const ReconnectDrainResult = enum { idle, started, retry_later, discarded_stale };

pub const DirectReleaseTarget = struct {
    runtime_handle: RuntimeHandle = 0,
    runtime_generation: u64 = 0,
    projection: remote_runtime.DirectReleaseProjection = .{},
};

pub const CloseTransitionTarget = struct {
    runtime_handle: RuntimeHandle = 0,
    runtime_generation: u64 = 0,
    runtime_id: [32]u8 = [_]u8{0} ** 32,
    projection: remote_runtime.CloseTransitionProjection = .{},
};

/// AppSession owns Window/topology identity while the backend owns runtime generation and the
/// terminal host-job rows.  The draft deliberately omits runtime_generation so callers cannot
/// manufacture that half of a CR5d binding.
pub const WindowBindingDraft = struct {
    window_addr: u64 = 0,
    app_session_generation: u64 = 0,
    graph_generation: u64 = 0,
    runtime_handle: RuntimeHandle = 0,
    surface_id: u64 = 0,
};

const WindowTransactionProjection = struct {
    summary: host_reconnect_runtime_ledger.TerminalSummary,
    rows: []const host_reconnect_runtime_ledger.RuntimeRow,
    binding_count: usize,
};

const ActualReconnectFixtureData = struct {
    cache_base: []const u8,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
};

const B5TestState = if (builtin.is_test) struct {
    threadlocal var scan_hook: ?*const fn (*RemoteTermBackend) void = null;
    threadlocal var skip_destroy: bool = false;
    threadlocal var event_pump_hook: ?*const fn (RuntimeHandle, *RemoteRuntime) DrainSummary = null;
    threadlocal var app_quit_routing_target_count: usize = 0;
    threadlocal var app_quit_runtime_count_at_terminalize: usize = 0;
    threadlocal var app_quit_runtime_count_at_owner_settlement: usize = 0;
    threadlocal var app_quit_pending_idle_count: usize = 0;
    threadlocal var app_quit_source_zero_count: usize = 0;
    threadlocal var cr4c_publication_drift: bool = false;
    threadlocal var cr5b_before_connect_hook: ?*const fn (*RemoteTermBackend, *const HostReconnectJob) void = null;
    threadlocal var cr5b_before_connect_seen: bool = false;
    threadlocal var cr5b_before_connect_valid: bool = false;
    threadlocal var cr5b_before_connect_row_count: u32 = 0;
    threadlocal var cr5b2b_runtime_commit_count: usize = 0;
    threadlocal var cr5b2b_retired_counts: [3]usize = .{0} ** 3;
    threadlocal var cr5d2_window_hook: ?*const fn (*RemoteTermBackend) anyerror!void = null;
    threadlocal var reconnect_coordinator_hook: ?*const fn (
        *RemoteTermBackend,
        ActualReconnectFixtureData,
    ) anyerror!void = null;
} else struct {};

pub const RemoteBackendSingletonLifecycle = enum(u8) {
    pristine = 0,
    claimed = 1,
    released = 2,
};

pub const RemoteBackendSingletonOwner = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    backend_addr: u64 = 0,
    owner_generation: u64 = 0,
    lifecycle_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

const HostReconnectJobState = enum(u8) {
    idle = 0,
    connected = 1,
    replacement_published = 2,
    replacement_failed = 3,
    candidate_staged = 4,
    candidate_failed = 5,
    candidate_rejected = 6,
    mutation_sealed = 7,
    controller_evidenced = 8,
    authority_conflict = 9,
    takeover_sent_unknown = 10,
    pre_takeover_failed = 11,
    controller_promoted = 12,
    preparing = 13,
    retirements_prepared = 14,
    shared_replacement_reserved = 15,
    shared_replacement_published = 16,
    runtime_transactions_complete = 17,
    host_failure_complete = 18,
};

pub const HostReconnectStart = union(enum) {
    connected,
    failed: host_connect.FailureReason,
    busy,
    invalid_authority,
};

pub const HostReconnectFrameProgress = enum(u8) {
    advanced,
    retry_later,
    completed_ready,
    retained_terminal_ready,
};

pub const HostReconnectTerminalKind = enum(u8) { completed, retained_terminal };

const CandidatePrepareFailure = union(enum) {
    rejected_usable,
    terminal: @import("client_poison.zig").ConnectionReason,
};

fn classifyCandidatePrepareFailure(err: anyerror) CandidatePrepareFailure {
    return switch (err) {
        error.ObserverAttachRejected => .rejected_usable,
        error.OutOfMemory, error.ResourceExhausted => .{ .terminal = .local_resource_exhausted },
        error.DeadlineExceeded => .{ .terminal = .read_timeout },
        error.ObserverAttachProtocolFailed,
        error.ProtocolError,
        error.CapabilityViolation,
        => .{ .terminal = .peer_contract_violation },
        error.ObserverAttachConnectionFailed, error.ConnectionClosed => .{ .terminal = .transport_read_failure },
        else => .{ .terminal = .local_invariant_violation },
    };
}

/// CR4 actual issuer가 만든 fresh Client의 유일한 임시 owner다. Client를 AppSession이나 개별 runtime으로
/// 흘리지 않고 backend의 final address에 붙잡아 두어, 후속 same-adapter replacement가 이 job만 소비하게 한다.
const HostReconnectJob = struct {
    self_addr: u64 = 0,
    backend_addr: u64 = 0,
    backend_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    job_generation: u64 = 0,
    host_id: u128 = 0,
    adapter_addr: u64 = 0,
    adapter_generation: u64 = 0,
    expected_connection_generation: u64 = 0,
    deadline: ?attach_phase_deadline.PhaseDeadline = null,
    client: ?client_mod.Client = null,
    runtime_row_count: u32 = 0,
    runtime_rows: [host_reconnect_runtime_ledger.max_runtime_rows]host_reconnect_runtime_ledger.RuntimeRow = undefined,
    runtime_rows_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    runtime_cursor: host_reconnect_runtime_transaction.Cursor = .{},
    terminal_summary: ?host_reconnect_runtime_ledger.TerminalSummary = null,
    runtime_handle: RuntimeHandle = 0,
    runtime_addr: u64 = 0,
    runtime_generation: u64 = 0,
    shared_admission: client_slot_mod.PreparedAdmissionClose = .{},
    shared_cleanup: client_slot_mod.PreparedRetirementCleanup = .{},
    replacement: client_slot_mod.PreparedClientReplacement = .{},
    request_nonce: u128 = 0,
    candidate_failure_reason_raw: u8 = 0,
    reconnect: remote_runtime.PreparedReconnect = .{},
    stage: ?*const catchup_stage_contract.PreparedStage = null,
    mutation_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    controller_generation: u64 = 0,
    state_raw: u8 = @intFromEnum(HostReconnectJobState.idle),
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,

    fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        hasher.update(&bytes);
    }

    fn clientIdentityDigest(value: *const client_mod.Client) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&hasher, u128, value.host_id);
        hashInt(&hasher, u64, value.upgrade_epoch);
        hashInt(&hasher, u64, value.authority_generation);
        hashInt(&hasher, u16, value.wire_major);
        hashInt(&hasher, u16, value.screen_codec_version);
        hashInt(&hasher, u8, @intFromBool(value.host_manifest_v1));
        hashInt(&hasher, u8, @intFromBool(value.runtime_catchup_barrier_v1));
        hashInt(&hasher, u8, if (value.connection_profile) |profile| @intFromEnum(profile) else std.math.maxInt(u8));
        const build_id = value.build_id orelse &.{};
        hashInt(&hasher, u64, @intCast(build_id.len));
        hasher.update(build_id);
        hashInt(&hasher, u64, @intCast(value.lifecycle.len));
        hasher.update(value.lifecycle);
        var result: process_seal.CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn stageDigest(stage: *const catchup_stage_contract.PreparedStage) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&hasher, u64, @intCast(stage.self_addr));
        hashInt(&hasher, u64, @intCast(stage.attachment_addr));
        hashInt(&hasher, u64, @intCast(stage.client_slot_addr));
        hashInt(&hasher, u64, stage.slot_incarnation);
        hashInt(&hasher, u64, stage.node_incarnation);
        hashInt(&hasher, u64, stage.connection_generation);
        hashInt(&hasher, u64, stage.transport_incarnation);
        hashInt(&hasher, u32, stage.pid);
        hashInt(&hasher, u64, stage.process_nonce);
        hashInt(&hasher, u64, @intCast(stage.owner_thread_id));
        hashInt(&hasher, u64, stage.stream_id);
        hashInt(&hasher, u64, stage.owner_generation);
        hashInt(&hasher, u64, stage.identity.subscription.value);
        hashInt(&hasher, u128, stage.identity.runtime_id);
        hashInt(&hasher, u64, stage.identity.connection.monotonic_id);
        hashInt(&hasher, u64, stage.identity.connection.slot_generation);
        hashInt(&hasher, u128, stage.identity.host_id);
        hashInt(&hasher, u128, stage.identity.request_nonce);
        hashInt(&hasher, u64, stage.snapshot.generation);
        hashInt(&hasher, u64, stage.snapshot.sequence);
        hashInt(&hasher, u64, stage.target.generation);
        hashInt(&hasher, u64, stage.target.sequence);
        hashInt(&hasher, u64, stage.accounting.batches);
        hashInt(&hasher, u64, stage.accounting.encoded_bytes);
        hashInt(&hasher, u64, stage.accounting.decoded_cells);
        hashInt(&hasher, u128, @bitCast(stage.deadline_expires_at_ns));
        hashInt(&hasher, u8, @as(*const u8, @ptrCast(&stage.lifecycle)).*);
        var result: process_seal.CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn runtimeSetJobIdentity(self: *const HostReconnectJob) host_reconnect_runtime_ledger.HostJobIdentity {
        return .{
            .job_generation = self.job_generation,
            .host_id = self.host_id,
            .pool_membership_generation = self.adapter_generation,
            .expected_connection_generation = self.expected_connection_generation,
        };
    }

    fn runtimeRowsSlice(self: *const HostReconnectJob) ?[]const host_reconnect_runtime_ledger.RuntimeRow {
        const count = std.math.cast(usize, self.runtime_row_count) orelse return null;
        if (count == 0 or count > self.runtime_rows.len) return null;
        return self.runtime_rows[0..count];
    }

    fn runtimeRowsDigest(rows: []const host_reconnect_runtime_ledger.RuntimeRow) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&hasher, u64, @intCast(rows.len));
        for (rows) |row| {
            hashInt(&hasher, u64, row.identity.job.job_generation);
            hashInt(&hasher, u128, row.identity.job.host_id);
            hashInt(&hasher, u64, row.identity.job.pool_membership_generation);
            hashInt(&hasher, u64, row.identity.job.expected_connection_generation);
            hashInt(&hasher, u64, row.identity.runtime_handle);
            hashInt(&hasher, u64, row.identity.runtime_addr);
            hashInt(&hasher, u64, row.identity.runtime_generation);
            hashInt(&hasher, u128, row.identity.runtime_id);
            hashInt(&hasher, u64, row.identity.shell_generation);
            hashInt(&hasher, u8, row.ledger_raw);
            hashInt(&hasher, u8, row.local_raw);
            hashInt(&hasher, u8, row.mutation_raw);
        }
        var result: process_seal.CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn terminalSummaryDigest(
        summary: ?host_reconnect_runtime_ledger.TerminalSummary,
    ) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&hasher, u8, @intFromBool(summary != null));
        if (summary) |value| {
            hashInt(&hasher, u64, value.job_generation);
            hashInt(&hasher, u128, value.host_id);
            hashInt(&hasher, u64, value.pool_membership_generation);
            hashInt(&hasher, u64, value.expected_connection_generation);
            hashInt(&hasher, u32, value.total);
            hashInt(&hasher, u32, value.published_old);
            hashInt(&hasher, u32, value.published_new);
            hashInt(&hasher, u32, value.frozen_unavailable);
            hashInt(&hasher, u32, value.ended);
            hashInt(&hasher, u32, value.retry_reserved);
        }
        var result: process_seal.CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    fn lessRuntimeRow(
        _: void,
        lhs: host_reconnect_runtime_ledger.RuntimeRow,
        rhs: host_reconnect_runtime_ledger.RuntimeRow,
    ) bool {
        return lhs.identity.runtime_handle < rhs.identity.runtime_handle;
    }

    fn stateRawValid(self: *const HostReconnectJob) bool {
        return switch (self.state_raw) {
            @intFromEnum(HostReconnectJobState.idle),
            @intFromEnum(HostReconnectJobState.connected),
            @intFromEnum(HostReconnectJobState.replacement_published),
            @intFromEnum(HostReconnectJobState.replacement_failed),
            @intFromEnum(HostReconnectJobState.candidate_staged),
            @intFromEnum(HostReconnectJobState.candidate_failed),
            @intFromEnum(HostReconnectJobState.candidate_rejected),
            @intFromEnum(HostReconnectJobState.mutation_sealed),
            @intFromEnum(HostReconnectJobState.controller_evidenced),
            @intFromEnum(HostReconnectJobState.authority_conflict),
            @intFromEnum(HostReconnectJobState.takeover_sent_unknown),
            @intFromEnum(HostReconnectJobState.pre_takeover_failed),
            @intFromEnum(HostReconnectJobState.controller_promoted),
            @intFromEnum(HostReconnectJobState.preparing),
            @intFromEnum(HostReconnectJobState.retirements_prepared),
            @intFromEnum(HostReconnectJobState.shared_replacement_reserved),
            @intFromEnum(HostReconnectJobState.shared_replacement_published),
            @intFromEnum(HostReconnectJobState.runtime_transactions_complete),
            @intFromEnum(HostReconnectJobState.host_failure_complete),
            => true,
            else => false,
        };
    }

    fn pristine(self: *const HostReconnectJob) bool {
        return self.state_raw == @intFromEnum(HostReconnectJobState.idle) and
            self.self_addr == 0 and self.backend_addr == 0 and self.backend_generation == 0 and
            self.pid == 0 and self.process_nonce == 0 and self.thread_id == 0 and
            self.job_generation == 0 and self.host_id == 0 and self.adapter_addr == 0 and
            self.adapter_generation == 0 and self.expected_connection_generation == 0 and
            self.deadline == null and self.client == null and
            self.runtime_row_count == 0 and std.mem.allEqual(u8, &self.runtime_rows_digest, 0) and
            self.runtime_cursor.pristine() and self.terminal_summary == null and
            self.runtime_handle == 0 and self.runtime_addr == 0 and self.runtime_generation == 0 and
            std.meta.eql(self.shared_admission, client_slot_mod.PreparedAdmissionClose{}) and
            std.meta.eql(self.shared_cleanup, client_slot_mod.PreparedRetirementCleanup{}) and
            std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) and
            self.request_nonce == 0 and self.candidate_failure_reason_raw == 0 and
            std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) and
            self.stage == null and
            std.mem.allEqual(u8, &self.mutation_digest, 0) and
            self.controller_generation == 0 and
            std.mem.allEqual(u8, &self.seal, 0);
    }

    fn replacementLifecycleRaw(self: *const HostReconnectJob) u8 {
        return @as(*const u8, @ptrCast(&self.replacement.lifecycle)).*;
    }

    fn sharedAdmissionLifecycleRaw(self: *const HostReconnectJob) u8 {
        return @as(*const u8, @ptrCast(&self.shared_admission.lifecycle)).*;
    }

    fn sharedCleanupLifecycleRaw(self: *const HostReconnectJob) u8 {
        return @as(*const u8, @ptrCast(&self.shared_cleanup.lifecycle)).*;
    }

    fn reconnectLifecycleRaw(self: *const HostReconnectJob) u8 {
        return @as(*const u8, @ptrCast(&self.reconnect.lifecycle)).*;
    }

    fn candidateFailureReason(self: *const HostReconnectJob) ?@import("client_poison.zig").ConnectionReason {
        if (self.candidate_failure_reason_raw == 0) return null;
        return std.enums.fromInt(
            @import("client_poison.zig").ConnectionReason,
            self.candidate_failure_reason_raw - 1,
        );
    }

    fn sealInput(self: *const HostReconnectJob) ?process_seal.HostReconnectJobSealInput {
        if (self.deadline == null) return null;
        const deadline_bits: u128 = @bitCast(self.deadline.?.absolute.expires_at_ns);
        const client_addr: u64 = if (self.client != null) @intFromPtr(&self.client.?) else 0;
        const client_fd: i32 = if (self.client) |*client| @intCast(client.fd) else -1;
        const client_owner_digest: process_seal.CleanupSeal = if (self.client) |*client|
            client.clientProjectionAuthorityDigest()
        else
            [_]u8{0} ** 32;
        const client_identity_digest: process_seal.CleanupSeal = if (self.client) |*client|
            clientIdentityDigest(client)
        else
            [_]u8{0} ** 32;
        return .{
            .self_addr = self.self_addr,
            .backend_addr = self.backend_addr,
            .backend_generation = self.backend_generation,
            .thread_id = self.thread_id,
            .job_generation = self.job_generation,
            .host_id = self.host_id,
            .adapter_addr = self.adapter_addr,
            .adapter_generation = self.adapter_generation,
            .expected_connection_generation = self.expected_connection_generation,
            .deadline_ns_low = @truncate(deadline_bits),
            .deadline_ns_high = @truncate(deadline_bits >> 64),
            .client_addr = client_addr,
            .client_fd = client_fd,
            .client_owner_digest = client_owner_digest,
            .client_identity_digest = client_identity_digest,
            .runtime_row_count = self.runtime_row_count,
            .runtime_rows_addr = @intFromPtr(&self.runtime_rows),
            .runtime_rows_digest = self.runtime_rows_digest,
            .runtime_cursor_next_index = self.runtime_cursor.next_index,
            .runtime_cursor_terminal_count = self.runtime_cursor.terminal_count,
            .runtime_cursor_failed_raw = self.runtime_cursor.failed_raw,
            .terminal_summary_digest = terminalSummaryDigest(self.terminal_summary),
            .runtime_handle = self.runtime_handle,
            .runtime_addr = self.runtime_addr,
            .runtime_generation = self.runtime_generation,
            .shared_admission_addr = @intFromPtr(&self.shared_admission),
            .shared_admission_lifecycle_raw = self.sharedAdmissionLifecycleRaw(),
            .shared_admission_seal = self.shared_admission.seal,
            .shared_cleanup_addr = @intFromPtr(&self.shared_cleanup),
            .shared_cleanup_lifecycle_raw = self.sharedCleanupLifecycleRaw(),
            .shared_cleanup_seal = self.shared_cleanup.seal,
            .replacement_addr = @intFromPtr(&self.replacement),
            .replacement_slot_addr = @intCast(self.replacement.slot_addr),
            .replacement_old_node_addr = @intCast(self.replacement.old_node_addr),
            .replacement_new_node_addr = @intCast(self.replacement.new_node_addr),
            .replacement_expected_connection_generation = self.replacement.expected_connection_generation,
            .replacement_next_connection_generation = self.replacement.next_connection_generation,
            .replacement_lifecycle_raw = self.replacementLifecycleRaw(),
            .replacement_seal = self.replacement.seal,
            .request_nonce = self.request_nonce,
            .candidate_failure_reason_raw = self.candidate_failure_reason_raw,
            .reconnect_addr = @intFromPtr(&self.reconnect),
            .reconnect_owner_addr = @intCast(self.reconnect.owner_addr),
            .reconnect_lifecycle_raw = self.reconnectLifecycleRaw(),
            .candidate_addr = @intCast(self.reconnect.candidate.self_addr),
            .candidate_slot_addr = @intCast(self.reconnect.candidate.slot_addr),
            .candidate_node_addr = @intCast(self.reconnect.candidate.node_addr),
            .candidate_generation = self.reconnect.candidate.generation,
            .candidate_active = @intFromBool(self.reconnect.candidate.active),
            .stage_addr = if (self.stage) |stage| @intFromPtr(stage) else 0,
            .stage_digest = if (self.stage) |stage| stageDigest(stage) else [_]u8{0} ** 32,
            .mutation_digest = self.mutation_digest,
            .controller_generation = self.controller_generation,
            .state_raw = self.state_raw,
        };
    }

    fn valid(self: *const HostReconnectJob, backend: *const RemoteTermBackend) bool {
        if (!self.stateRawValid() or self.state_raw == @intFromEnum(HostReconnectJobState.idle) or
            self.self_addr != @intFromPtr(self) or self.backend_addr != @intFromPtr(backend) or
            self.backend_generation == 0 or self.backend_generation != backend.singleton_owner.owner_generation or
            self.job_generation == 0 or self.job_generation != backend.next_host_reconnect_job_generation or
            self.host_id == 0 or self.adapter_addr == 0 or
            self.adapter_generation == 0 or self.expected_connection_generation == 0 or
            self.thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
        if (backend.host_reconnect_job != self) return false;
        const ready = process_seal.currentReadyIdentity() catch return false;
        if (self.pid != ready.pid or self.process_nonce != ready.process_nonce) return false;
        const pool = backend.host_pool orelse return false;
        const adapter = pool.get(self.host_id) orelse return false;
        if (@intFromPtr(adapter) != self.adapter_addr or
            pool.adapterGeneration(self.host_id) != self.adapter_generation) return false;
        if (!self.validateRuntimeSet(backend)) return false;
        const multi_runtime = !self.runtime_cursor.pristine();
        if (self.state_raw != @intFromEnum(HostReconnectJobState.runtime_transactions_complete) and
            self.state_raw != @intFromEnum(HostReconnectJobState.host_failure_complete) and
            self.terminal_summary != null) return false;
        if ((self.state_raw == @intFromEnum(HostReconnectJobState.preparing) or
            self.state_raw == @intFromEnum(HostReconnectJobState.connected) or
            self.state_raw == @intFromEnum(HostReconnectJobState.retirements_prepared) or
            self.state_raw == @intFromEnum(HostReconnectJobState.replacement_failed)) and
            multi_runtime) return false;
        if (self.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_reserved) and
            (!std.meta.eql(self.shared_admission, client_slot_mod.PreparedAdmissionClose{}) or
                !std.meta.eql(self.shared_cleanup, client_slot_mod.PreparedRetirementCleanup{})))
            return false;
        switch (self.state_raw) {
            @intFromEnum(HostReconnectJobState.preparing) => {
                if (self.client != null or adapter.connectionGeneration() != self.expected_connection_generation or
                    self.runtime_handle != 0 or self.runtime_addr != 0 or self.runtime_generation != 0 or
                    !std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
            },
            @intFromEnum(HostReconnectJobState.connected) => {
                if (self.client == null or self.client.?.fd < 0 or self.client.?.host_id != self.host_id or
                    !self.client.?.runtime_catchup_barrier_v1 or self.client.?.connection_profile != .gui or
                    adapter.connectionGeneration() != self.expected_connection_generation or
                    self.runtime_handle != 0 or self.runtime_addr != 0 or self.runtime_generation != 0 or
                    !std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
            },
            @intFromEnum(HostReconnectJobState.retirements_prepared) => {
                if (self.client == null or self.client.?.fd < 0 or self.client.?.host_id != self.host_id or
                    !self.client.?.runtime_catchup_barrier_v1 or self.client.?.connection_profile != .gui or
                    adapter.connectionGeneration() != self.expected_connection_generation or
                    self.runtime_handle != 0 or self.runtime_addr != 0 or self.runtime_generation != 0 or
                    !std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
                for (self.runtimeRowsSlice() orelse return false) |row| {
                    const entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
                    if (!RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
                        entry.runtime,
                        adapter,
                        @intFromPtr(self),
                        self.job_generation,
                    )) return false;
                }
            },
            @intFromEnum(HostReconnectJobState.shared_replacement_reserved) => {
                if (self.client == null or self.client.?.fd < 0 or self.client.?.host_id != self.host_id or
                    !self.client.?.runtime_catchup_barrier_v1 or self.client.?.connection_profile != .gui or
                    adapter.connectionGeneration() != self.expected_connection_generation or
                    self.runtime_handle != 0 or self.runtime_addr != 0 or self.runtime_generation != 0 or
                    self.replacementLifecycleRaw() !=
                        @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.reserved) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
                if (!self.runtime_cursor.valid(self.runtimeRowsSlice() orelse return false) or
                    self.runtime_cursor.next_index != 0 or self.runtime_cursor.failed_raw != 0 or
                    self.terminal_summary != null) return false;
                adapter.preflightRetirementCleanupBeforeAdmissionClose(
                    &self.shared_admission,
                    &self.shared_cleanup,
                    self.replacement.next_connection_generation,
                ) catch return false;
                adapter.preflightRetirementDetachBeforeAdmissionClose(
                    &self.shared_admission,
                    self.expected_connection_generation,
                    self.replacement.next_connection_generation,
                ) catch return false;
                adapter.preflightReservedClientReplacementNode(
                    &self.shared_cleanup,
                    &self.client.?,
                    &self.replacement,
                ) catch return false;
                for (self.runtimeRowsSlice() orelse return false) |row| {
                    const entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
                    if (!RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
                        entry.runtime,
                        adapter,
                        @intFromPtr(self),
                        self.job_generation,
                    )) return false;
                }
            },
            @intFromEnum(HostReconnectJobState.shared_replacement_published) => {
                if (self.client != null or self.runtime_handle != 0 or self.runtime_addr != 0 or
                    self.runtime_generation != 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0 or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                if (!self.runtime_cursor.valid(self.runtimeRowsSlice() orelse return false) or
                    self.terminal_summary != null) return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                for (self.runtimeRowsSlice() orelse return false) |row| {
                    const entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
                    const local = std.enums.fromInt(
                        host_reconnect_runtime_ledger.LocalState,
                        row.local_raw,
                    ) orelse return false;
                    const expected_shell_generation = if (local == .published_new)
                        std.math.add(u64, row.identity.shell_generation, 1) catch return false
                    else
                        row.identity.shell_generation;
                    if (!RemoteRuntime.backend_api.hostReconnectTerminalIdentityExact(
                        entry.runtime,
                        row.identity.runtime_id,
                        expected_shell_generation,
                    )) return false;
                    switch (local) {
                        .published_old, .frozen_unavailable => if (!RemoteRuntime.backend_api
                            .hostWideRetirementCommittedExact(entry.runtime, adapter)) return false,
                        .published_new => if (!RemoteRuntime.backend_api.hostReconnectPublishedNewExact(
                            entry.runtime,
                            adapter,
                        )) return false,
                        .ended => {},
                    }
                }
            },
            @intFromEnum(HostReconnectJobState.replacement_published) => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                if (multi_runtime) {
                    const active = self.runtime_cursor.activeRow(
                        self.runtimeRowsSlice() orelse return false,
                    ) orelse return false;
                    if (active.runtime_handle != self.runtime_handle or
                        active.runtime_addr != self.runtime_addr or
                        active.runtime_generation != self.runtime_generation) return false;
                }
            },
            @intFromEnum(HostReconnectJobState.replacement_failed) => {
                if (self.client == null or self.client.?.fd < 0 or self.client.?.host_id != self.host_id or
                    !self.client.?.runtime_catchup_barrier_v1 or self.client.?.connection_profile != .gui or
                    self.runtime_handle == 0 or self.runtime_addr == 0 or self.runtime_generation == 0 or
                    !std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0) return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.expected_connection_generation)
                    return false;
                RemoteRuntime.backend_api.preflightReconnectClientReplacementFailure(
                    entry.runtime,
                    adapter,
                    self.expected_connection_generation,
                ) catch return false;
            },
            @intFromEnum(HostReconnectJobState.candidate_staged),
            @intFromEnum(HostReconnectJobState.mutation_sealed),
            => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce == 0 or self.candidate_failure_reason_raw != 0 or self.stage == null)
                    return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                if (!RemoteRuntime.backend_api.validateReconnectObserverStageForCleanup(
                    entry.runtime,
                    adapter,
                    &self.replacement,
                    @constCast(&self.reconnect),
                    self.stage.?,
                    self.deadline.?.absolute,
                )) return false;
                const actual_mutation = RemoteRuntime.backend_api.reconnectMutationSealDigest(entry.runtime);
                if (self.state_raw == @intFromEnum(HostReconnectJobState.candidate_staged)) {
                    if (!std.mem.allEqual(u8, &self.mutation_digest, 0) or actual_mutation != null or
                        self.controller_generation != 0)
                        return false;
                } else {
                    if (actual_mutation == null or !std.crypto.timing_safe.eql(
                        process_seal.CleanupSeal,
                        actual_mutation.?,
                        self.mutation_digest,
                    ) or self.controller_generation != 0) return false;
                }
            },
            @intFromEnum(HostReconnectJobState.controller_evidenced),
            @intFromEnum(HostReconnectJobState.controller_promoted),
            => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce == 0 or self.candidate_failure_reason_raw != 0 or
                    self.stage == null or self.controller_generation == 0)
                    return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                const actual_mutation = RemoteRuntime.backend_api.reconnectMutationSealDigest(entry.runtime) orelse
                    return false;
                if (!std.crypto.timing_safe.eql(
                    process_seal.CleanupSeal,
                    actual_mutation,
                    self.mutation_digest,
                )) return false;
                if (self.state_raw == @intFromEnum(HostReconnectJobState.controller_evidenced)) {
                    if (!RemoteRuntime.backend_api.validateReconnectControllerEvidence(
                        entry.runtime,
                        adapter,
                        &self.replacement,
                        @constCast(&self.reconnect),
                        self.stage.?,
                        self.controller_generation,
                    )) return false;
                } else if (!RemoteRuntime.backend_api.validateReconnectPromotedController(
                    entry.runtime,
                    adapter,
                    &self.replacement,
                    @constCast(&self.reconnect),
                    self.stage.?,
                    self.controller_generation,
                )) return false;
            },
            @intFromEnum(HostReconnectJobState.authority_conflict),
            @intFromEnum(HostReconnectJobState.takeover_sent_unknown),
            @intFromEnum(HostReconnectJobState.pre_takeover_failed),
            => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce == 0 or !std.meta.eql(
                    self.reconnect,
                    remote_runtime.PreparedReconnect{},
                ) or self.stage != null or self.controller_generation != 0)
                    return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                const actual_mutation = RemoteRuntime.backend_api.reconnectMutationSealDigest(entry.runtime) orelse
                    return false;
                if (!std.crypto.timing_safe.eql(
                    process_seal.CleanupSeal,
                    actual_mutation,
                    self.mutation_digest,
                )) return false;
                if (self.state_raw == @intFromEnum(HostReconnectJobState.authority_conflict)) {
                    if (self.candidate_failure_reason_raw != 0) return false;
                    adapter.preflightAttachmentConnectionUsable() catch return false;
                } else {
                    const reason = self.candidateFailureReason() orelse return false;
                    adapter.preflightAttachmentConnectionFailedClosed(reason) catch return false;
                }
            },
            @intFromEnum(HostReconnectJobState.candidate_failed) => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or self.controller_generation != 0)
                    return false;
                const failure_reason = self.candidateFailureReason() orelse return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                adapter.preflightAttachmentConnectionFailedClosed(failure_reason) catch return false;
                if (!std.mem.allEqual(u8, &self.mutation_digest, 0)) {
                    const actual_mutation = RemoteRuntime.backend_api.reconnectMutationSealDigest(entry.runtime) orelse
                        return false;
                    if (!std.crypto.timing_safe.eql(
                        process_seal.CleanupSeal,
                        actual_mutation,
                        self.mutation_digest,
                    )) return false;
                }
            },
            @intFromEnum(HostReconnectJobState.candidate_rejected) => {
                if (self.client != null or self.runtime_handle == 0 or self.runtime_addr == 0 or
                    self.runtime_generation == 0 or self.replacementLifecycleRaw() !=
                    @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    self.request_nonce == 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or self.stage != null or
                    !std.mem.allEqual(u8, &self.mutation_digest, 0))
                    return false;
                const entry = backend.runtimes.get(self.runtime_handle) orelse return false;
                if (@intFromPtr(entry.runtime) != self.runtime_addr or
                    entry.runtime_generation != self.runtime_generation or entry.host_id != self.host_id or
                    entry.host_adapter_generation != self.adapter_generation or
                    adapter.connectionGeneration() != self.replacement.next_connection_generation or
                    self.replacement.expected_connection_generation != self.expected_connection_generation)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                adapter.preflightAttachmentConnectionUsable() catch return false;
            },
            @intFromEnum(HostReconnectJobState.runtime_transactions_complete) => {
                if (!multi_runtime or self.client != null or self.runtime_handle != 0 or
                    self.runtime_addr != 0 or self.runtime_generation != 0 or
                    self.request_nonce != 0 or self.candidate_failure_reason_raw != 0 or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0 or self.terminal_summary == null or
                    !self.terminal_summary.?.valid() or
                    !self.runtime_cursor.valid(self.runtimeRowsSlice() orelse return false) or
                    self.runtime_cursor.next_index != self.runtime_row_count)
                    return false;
                const expected_summary = host_reconnect_runtime_ledger.summarizeTerminalRows(
                    self.runtimeSetJobIdentity(),
                    self.runtimeRowsSlice() orelse return false,
                ) catch return false;
                if (!std.meta.eql(expected_summary, self.terminal_summary.?)) return false;
                if (expected_summary.frozen_unavailable == 0) {
                    if (!std.meta.eql(self.replacement, client_slot_mod.PreparedClientReplacement{}) or
                        adapter.slot.retiredClientCount() != 0) return false;
                } else {
                    if (self.replacementLifecycleRaw() !=
                        @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                        adapter.slot.retiredClientCount() != 1) return false;
                    adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                }
                for (self.runtimeRowsSlice() orelse return false) |row| {
                    const entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
                    const local = std.enums.fromInt(
                        host_reconnect_runtime_ledger.LocalState,
                        row.local_raw,
                    ) orelse return false;
                    const expected_shell_generation = if (local == .published_new)
                        std.math.add(u64, row.identity.shell_generation, 1) catch return false
                    else
                        row.identity.shell_generation;
                    if (!RemoteRuntime.backend_api.hostReconnectTerminalIdentityExact(
                        entry.runtime,
                        row.identity.runtime_id,
                        expected_shell_generation,
                    )) return false;
                    switch (local) {
                        .published_new => if (!RemoteRuntime.backend_api.hostReconnectPublishedNewExact(
                            entry.runtime,
                            adapter,
                        )) return false,
                        .frozen_unavailable => if (!RemoteRuntime.backend_api
                            .hostWideRetirementCommittedExact(entry.runtime, adapter)) return false,
                        .ended => {},
                        .published_old => return false,
                    }
                }
            },
            @intFromEnum(HostReconnectJobState.host_failure_complete) => {
                if (!multi_runtime or self.client != null or self.runtime_handle != 0 or
                    self.runtime_addr != 0 or self.runtime_generation != 0 or self.request_nonce != 0 or
                    self.candidateFailureReason() == null or
                    !std.meta.eql(self.reconnect, remote_runtime.PreparedReconnect{}) or
                    self.stage != null or !std.mem.allEqual(u8, &self.mutation_digest, 0) or
                    self.controller_generation != 0 or self.terminal_summary == null or
                    !self.terminal_summary.?.valid() or self.terminal_summary.?.published_new != 0 or
                    self.terminal_summary.?.frozen_unavailable != self.runtime_row_count or
                    !self.runtime_cursor.valid(self.runtimeRowsSlice() orelse return false) or
                    self.runtime_cursor.next_index != self.runtime_row_count or
                    self.replacementLifecycleRaw() !=
                        @intFromEnum(client_slot_mod.PreparedClientReplacement.Lifecycle.published) or
                    adapter.slot.retiredClientCount() != 1)
                    return false;
                adapter.preflightPublishedClientReplacement(&self.replacement) catch return false;
                adapter.preflightAttachmentConnectionFailedClosed(
                    self.candidateFailureReason().?,
                ) catch return false;
                const expected_summary = host_reconnect_runtime_ledger.summarizeTerminalRows(
                    self.runtimeSetJobIdentity(),
                    self.runtimeRowsSlice() orelse return false,
                ) catch return false;
                if (!std.meta.eql(expected_summary, self.terminal_summary.?)) return false;
                for (self.runtimeRowsSlice() orelse return false) |row| {
                    const entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
                    const ledger = std.enums.fromInt(
                        host_reconnect_runtime_ledger.RuntimeLedger,
                        row.ledger_raw,
                    ) orelse return false;
                    const expected_shell_generation = if (ledger == .new_controller_evidenced)
                        std.math.add(u64, row.identity.shell_generation, 1) catch return false
                    else
                        row.identity.shell_generation;
                    if (!RemoteRuntime.backend_api.hostReconnectTerminalIdentityExact(
                        entry.runtime,
                        row.identity.runtime_id,
                        expected_shell_generation,
                    ) or !RemoteRuntime.backend_api.hostWideRetirementCommittedExact(
                        entry.runtime,
                        adapter,
                    )) return false;
                }
            },
            else => return false,
        }
        if (multi_runtime and self.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_reserved) and
            self.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_published) and
            self.state_raw != @intFromEnum(HostReconnectJobState.runtime_transactions_complete) and
            self.state_raw != @intFromEnum(HostReconnectJobState.host_failure_complete))
        {
            const active = self.runtime_cursor.activeRow(
                self.runtimeRowsSlice() orelse return false,
            ) orelse return false;
            if (active.runtime_handle != self.runtime_handle or active.runtime_addr != self.runtime_addr or
                active.runtime_generation != self.runtime_generation) return false;
        }
        const input = self.sealInput() orelse return false;
        const expected = process_seal.hostReconnectJobSeal(self.pid, self.process_nonce, input) catch return false;
        return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, self.seal);
    }

    fn validateRuntimeSet(self: *const HostReconnectJob, backend: *const RemoteTermBackend) bool {
        const rows = self.runtimeRowsSlice() orelse return false;
        const identity = self.runtimeSetJobIdentity();
        if (!host_reconnect_runtime_ledger.validateCanonicalRows(identity, rows) or
            !std.crypto.timing_safe.eql(
                process_seal.CleanupSeal,
                runtimeRowsDigest(rows),
                self.runtime_rows_digest,
            )) return false;
        for (rows) |row| {
            const runtime_entry = backend.runtimes.get(row.identity.runtime_handle) orelse return false;
            if (runtime_entry.host_id != self.host_id or
                runtime_entry.host_adapter_generation != self.adapter_generation or
                @intFromPtr(runtime_entry.runtime) != row.identity.runtime_addr or
                runtime_entry.runtime_generation != row.identity.runtime_generation) return false;
            // The shared publication suffix terminalizes every old attachment. At that point the
            // ordinary runtime-operation admission used by the live runtime projection is
            // intentionally closed; the captured row plus the state-specific committed oracle
            // below remain the canonical authority instead of reopening the dead generation.
            if (self.runtime_cursor.pristine()) {
                const projection = RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(
                    runtime_entry.runtime,
                ) catch return false;
                if (projection.runtime_id != row.identity.runtime_id or
                    projection.shell_generation != row.identity.shell_generation) return false;
            }
        }
        var same_host_count: usize = 0;
        var iterator = backend.runtimes.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.host_id == self.host_id and
                entry.value_ptr.host_adapter_generation == self.adapter_generation)
                same_host_count += 1;
        }
        return same_host_count == rows.len;
    }

    fn prepareForConnect(
        self: *HostReconnectJob,
        backend: *RemoteTermBackend,
        host_id: u128,
        phase: attach_phase_deadline.PhaseDeadline,
    ) !void {
        if (backend.host_reconnect_job != self or !self.pristine() or host_id == 0 or
            phase.kind != .connect_hello or phase.absolute.remainingNs() <= 0) return error.InvalidAuthority;
        errdefer self.* = .{};
        const ready = try process_seal.currentReadyIdentity();
        const pool = backend.host_pool orelse return error.InvalidAuthority;
        const adapter = pool.get(host_id) orelse return error.InvalidAuthority;
        const adapter_generation = pool.adapterGeneration(host_id) orelse return error.InvalidAuthority;
        const connection_generation = adapter.connectionGeneration();
        const generation = std.math.add(u64, backend.next_host_reconnect_job_generation, 1) catch
            return error.InvalidAuthority;
        if (adapter_generation == 0 or connection_generation == 0 or generation == 0)
            return error.InvalidAuthority;
        self.self_addr = @intFromPtr(self);
        self.backend_addr = @intFromPtr(backend);
        self.backend_generation = backend.singleton_owner.owner_generation;
        self.pid = ready.pid;
        self.process_nonce = ready.process_nonce;
        self.thread_id = @intCast(std.Thread.getCurrentId());
        self.job_generation = generation;
        self.host_id = host_id;
        self.adapter_addr = @intFromPtr(adapter);
        self.adapter_generation = adapter_generation;
        self.expected_connection_generation = connection_generation;
        self.deadline = phase;

        const identity = self.runtimeSetJobIdentity();
        var iterator = backend.runtimes.iterator();
        var count: usize = 0;
        while (iterator.next()) |entry| {
            const runtime_entry = entry.value_ptr.*;
            if (runtime_entry.host_id != host_id or
                runtime_entry.host_adapter_generation != adapter_generation) continue;
            if (count >= self.runtime_rows.len) return error.InvalidAuthority;
            const projection = try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(runtime_entry.runtime);
            self.runtime_rows[count] = host_reconnect_runtime_ledger.RuntimeRow.init(.{
                .job = identity,
                .runtime_handle = entry.key_ptr.*,
                .runtime_addr = @intFromPtr(runtime_entry.runtime),
                .runtime_generation = runtime_entry.runtime_generation,
                .runtime_id = projection.runtime_id,
                .shell_generation = projection.shell_generation,
            }, .old_valid, .published_old, .open);
            count += 1;
        }
        if (count == 0) return error.InvalidAuthority;
        std.mem.sort(
            host_reconnect_runtime_ledger.RuntimeRow,
            self.runtime_rows[0..count],
            {},
            lessRuntimeRow,
        );
        if (!host_reconnect_runtime_ledger.validateCanonicalRows(identity, self.runtime_rows[0..count]))
            return error.InvalidAuthority;
        self.runtime_row_count = @intCast(count);
        self.runtime_rows_digest = runtimeRowsDigest(self.runtime_rows[0..count]);
        self.state_raw = @intFromEnum(HostReconnectJobState.preparing);
        const previous_job_generation = backend.next_host_reconnect_job_generation;
        backend.next_host_reconnect_job_generation = generation;
        errdefer backend.next_host_reconnect_job_generation = previous_job_generation;
        self.seal = try process_seal.hostReconnectJobSeal(self.pid, self.process_nonce, self.sealInput() orelse
            return error.InvalidAuthority);
        if (!self.valid(backend)) return error.InvalidAuthority;
    }

    fn adoptConnected(
        self: *HostReconnectJob,
        backend: *RemoteTermBackend,
        host_id: u128,
        phase: attach_phase_deadline.PhaseDeadline,
        source: *client_mod.Client,
    ) HostReconnectStart {
        if (backend.host_reconnect_job != self or !self.valid(backend) or
            self.state_raw != @intFromEnum(HostReconnectJobState.preparing)) return .busy;
        if (phase.kind != .connect_hello or phase.absolute.remainingNs() <= 0 or
            source.fd < 0 or source.host_id != host_id or host_id != self.host_id or
            !source.runtime_catchup_barrier_v1 or source.connection_profile != .gui) return .invalid_authority;
        const pool = backend.host_pool orelse return .invalid_authority;
        const adapter = pool.get(host_id) orelse return .invalid_authority;
        if (@intFromPtr(adapter) != self.adapter_addr or
            pool.adapterGeneration(host_id) != self.adapter_generation or
            adapter.connectionGeneration() != self.expected_connection_generation or
            !std.meta.eql(phase, self.deadline.?)) return .invalid_authority;
        self.client = source.*;
        self.state_raw = @intFromEnum(HostReconnectJobState.connected);
        source.* = undefined;
        self.seal = process_seal.hostReconnectJobSeal(
            self.pid,
            self.process_nonce,
            self.sealInput() orelse {
                self.client.?.deinit();
                self.client = null;
                self.state_raw = @intFromEnum(HostReconnectJobState.preparing);
                return .invalid_authority;
            },
        ) catch {
            self.client.?.deinit();
            self.client = null;
            self.state_raw = @intFromEnum(HostReconnectJobState.preparing);
            return .invalid_authority;
        };
        if (!self.valid(backend)) {
            self.client.?.deinit();
            self.client = null;
            self.state_raw = @intFromEnum(HostReconnectJobState.preparing);
            return .invalid_authority;
        }
        return .connected;
    }

    fn abort(self: *HostReconnectJob, backend: *RemoteTermBackend) !void {
        if (!self.valid(backend)) return error.InvalidHostReconnectJob;
        if (self.state_raw == @intFromEnum(HostReconnectJobState.shared_replacement_reserved)) {
            const pool = backend.host_pool orelse return error.InvalidHostReconnectJob;
            const adapter = pool.get(self.host_id) orelse return error.InvalidHostReconnectJob;
            adapter.abortReservedClientReplacementNode(
                &self.shared_cleanup,
                &self.client.?,
                &self.replacement,
            ) catch process_seal.fatalIntegrity(.proof_loss);
            adapter.abortRetirementCleanup(&self.shared_cleanup) catch
                process_seal.fatalIntegrity(.proof_loss);
            adapter.cancelAdmissionClose(&self.shared_admission) catch
                process_seal.fatalIntegrity(.proof_loss);
            self.shared_admission = .{};
            self.shared_cleanup = .{};
            self.replacement = .{};
            self.runtime_cursor = .{};
            self.terminal_summary = null;
            self.state_raw = @intFromEnum(HostReconnectJobState.retirements_prepared);
            self.seal = process_seal.hostReconnectJobSeal(
                self.pid,
                self.process_nonce,
                self.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        if (self.state_raw == @intFromEnum(HostReconnectJobState.retirements_prepared)) {
            const pool = backend.host_pool orelse return error.InvalidHostReconnectJob;
            const adapter = pool.get(self.host_id) orelse return error.InvalidHostReconnectJob;
            var index = @as(usize, self.runtime_row_count);
            while (index > 0) {
                index -= 1;
                const row = self.runtime_rows[index];
                const entry = backend.runtimes.get(row.identity.runtime_handle) orelse
                    process_seal.fatalIntegrity(.proof_loss);
                RemoteRuntime.backend_api.abortHostWideRetirement(
                    entry.runtime,
                    adapter,
                    @intFromPtr(self),
                    self.job_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            }
            self.state_raw = @intFromEnum(HostReconnectJobState.connected);
            self.seal = process_seal.hostReconnectJobSeal(
                self.pid,
                self.process_nonce,
                self.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        if (self.state_raw != @intFromEnum(HostReconnectJobState.connected)) return error.Busy;
        var owned = self.client;
        self.client = null;
        self.state_raw = @intFromEnum(HostReconnectJobState.idle);
        self.seal = [_]u8{0} ** 32;
        self.* = .{};
        if (owned) |*client| client.deinit();
    }
};

var remote_backend_singleton_mutex: std.atomic.Mutex = .unlocked;
var remote_backend_singleton_addr: u64 = 0;
var remote_backend_singleton_generation: u64 = 0;

pub const RuntimeAdmissionReservation = struct {
    self_addr: u64 = 0,
    backend_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    request_generation: u64 = 0,
    state_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const WindowCloseTicketReservation = struct {
    self_addr: u64 = 0,
    backend_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    first_ticket: u64 = 0,
    last_ticket: u64 = 0,
    target_count: u32 = 0,
    target_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    state_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const CloseMaintenanceStats = struct {
    visited_count: usize = 0,
    selected_count: usize = 0,
    removed_count: usize = 0,
};

/// 한 host connection 위의 원격 term backend. legacy 단일-host 모드의 `client`는 borrowed이고 pool 모드는
/// `host_pool`만 권위로 사용한다. **`RemoteRuntime`은 self-referential**(surface.remote가 자기 조립기를 가리킴)이라
/// heap에 개별 할당해 안정 주소를 주며, map value가 runtime과 host lease identity를 한 단위로 소유한다.
pub const RemoteTermBackend = struct {
    pub const WakeSource = struct {
        fd: std.c.fd_t,
        host_id: u128,
        connection_generation: u64,
    };

    const HostProbe = struct {
        host_id: u128,
        runtime: *RemoteRuntime,
    };

    fn hostProbeLessThan(_: void, lhs: HostProbe, rhs: HostProbe) bool {
        return lhs.host_id < rhs.host_id;
    }

    fn sortedHostsContain(hosts: []const u128, target: u128) bool {
        var low: usize = 0;
        var high = hosts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (hosts[middle] < target) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low < hosts.len and hosts[low] == target;
    }

    const Mode = enum {
        spawn_and_attach,
        attach_only,
    };

    const RuntimeEntry = struct {
        runtime: *RemoteRuntime,
        host_id: u128,
        host_adapter_generation: u64 = 0,
        runtime_generation: u64,
        notification_config_applied_generation: u64 = 0,
        notification_display_label: [notification_delivery.max_display_label_bytes]u8 =
            [_]u8{0} ** notification_delivery.max_display_label_bytes,
        notification_display_label_len: u16 = 0,

        fn notificationDisplayLabel(self: *const RuntimeEntry) []const u8 {
            return self.notification_display_label[0..self.notification_display_label_len];
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    client: ?*client_mod.Client,
    host_pool: ?*AdapterPool = null,
    mode: Mode = .spawn_and_attach,
    // 앱의 in-process 라우팅 표(borrowed — 소유는 AppRuntime). attach가 원격 Term을 여기에 **원격 PtyIo**로 등록해,
    // GUI 입력 hot path(self.runtime.writeInput/resize/enqueueCoreCommand, surface.id 라우팅)가 in-process와 똑같이
    // 원격 Term에 도달하게 한다 — sink만 write_queue→client.sendInput/resize RPC로 갈린다(app_session hot path 무변경).
    // in-process Term은 write_queue PtyIo로 등록되는 것과 대칭. `remove`가 뗀다.
    surface_runtime: *SurfaceRuntime,
    runtimes: std.AutoHashMapUnmanaged(RuntimeHandle, RuntimeEntry) = .empty,
    next_runtime_generation: u64 = 0,
    next_admission_generation: u64 = 0,
    reserved_runtime_count: usize = 0,
    close_ticket_issuer: close_contract.CloseTicketIssuer = .{},
    close_operation_owner: close_authority.CloseOperationOwner = .{},
    close_sweep: close_contract.CloseSweep = .inactive,
    event_pump_cursor: usize = 0,
    singleton_owner: RemoteBackendSingletonOwner = .{},
    host_reconnect_job: ?*HostReconnectJob = null,
    host_reconnect_preparing: bool = false,
    next_host_reconnect_job_generation: u64 = 0,
    shutdown_reclaim_host_id: u128 = 0,
    host_reconnect_window_owner: host_reconnect_window_transaction.Owner = .{},
    host_reconnect_window_transaction: host_reconnect_window_transaction.Transaction = .{},
    next_host_reconnect_window_action_generation: u64 = 0,
    paused_paste_budget: reconnect_mutation_seal.GlobalPasteBudget = .{},
    app_quit_routing_tombstoned: bool = false,
    app_quit_connections_terminalized: bool = false,
    app_quit_owner_graphs_settled: bool = false,
    app_quit_shutdown_started_at_ns: u64 = 0,
    app_quit_shutdown_deadline_ns: u64 = 0,
    app_quit_first_ticket: u64 = 0,
    app_quit_target_count: u32 = 0,
    next_shutdown_connection_identity: u64 = 0,

    notification_config_generation: u64 = 1,
    notifications_osc: bool = false,

    const vtable = term_backend.VTable{
        .input_owner = &input_vtable,
        .spawn = spawn,
        .attach = attach,
        .pump = pump,
        .write_input = writeInput,
        .write_input_nonblocking = writeInputNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .resize = resize,
        .close_and_detach = closeAndDetach,
        .close = close,
        .finish_after_termination = finishAfterTermination,
        .remove = remove,
        .foreground_process_group = foregroundProcessGroup,
        .resource_samples = resourceSamples,
        .foreground_process_names = foregroundProcessNames,
        .process_cwd = processCwd,
        .read_observation = readObservation,
        .refresh_observation = refreshObservation,
        .dump_recent_text = dumpRecentText,
    };

    pub const ReconnectProductSnapshot = struct {
        job_present: bool,
        preparing: bool,
        job_state_raw: u8,
        runtime_count: usize,
    };

    pub fn reconnectProductSnapshot(self: *const RemoteTermBackend) ReconnectProductSnapshot {
        return .{
            .job_present = self.host_reconnect_job != null,
            .preparing = self.host_reconnect_preparing,
            .job_state_raw = if (self.host_reconnect_job) |job| job.state_raw else 0,
            .runtime_count = self.runtimes.count(),
        };
    }

    const input_vtable = InputOwnerVTable{
        .write = writeInput,
        .write_nonblocking = writeInputNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .enqueue_batch = enqueueInputBatch,
    };

    /// Borrowed host socket identities for native read sources. Client/ClientSlot still own and
    /// close every descriptor; callers must replace a source whenever its identity tuple changes.
    /// 이 host 연결을 실제로 pump 하는 runtime 이 있는가. 없으면 그 fd 를 읽을 주체가 없다.
    fn hasRuntimeForHost(self: *RemoteTermBackend, host_id: u128) bool {
        var it = self.runtimes.iterator();
        while (it.next()) |row| {
            if (row.value_ptr.host_id == host_id) return true;
        }
        return false;
    }

    pub fn wakeSources(self: *RemoteTermBackend, out: []WakeSource) usize {
        if (self.host_pool) |pool| {
            var adapters: [max_remote_backend_runtimes]AdapterPool.AdapterSnapshot = undefined;
            const adapter_count = pool.adapterSnapshots(&adapters);
            if (adapter_count > adapters.len) process_seal.fatalIntegrity(.proof_loss);
            var count: usize = 0;
            for (adapters[0..adapter_count]) |snapshot| {
                const source = snapshot.adapter.wakeSource() orelse continue;
                // 읽는 주체가 없는 연결은 감시하지 않는다. `DispatchSourceRead` 는 레벨 트리거라
                // 핸들러가 소비하지 않으면 무한 재발화한다(Apple: "schedules its event handler
                // repeatedly while there is still data to read"). pump 는 `self.runtimes` 만 도므로
                // runtime 이 없는 adapter 의 fd 는 영원히 안 읽히고 그대로 폭주가 된다.
                if (!self.hasRuntimeForHost(source.host_id)) continue;
                if (count < out.len) out[count] = .{
                    .fd = source.fd,
                    .host_id = source.host_id,
                    .connection_generation = source.connection_generation,
                };
                count += 1;
            }
            return count;
        }
        const client = self.client orelse return 0;
        if (client.fd < 0 or client.host_id == 0) return 0;
        if (out.len != 0) out[0] = .{
            .fd = client.fd,
            .host_id = client.host_id,
            .connection_generation = 1,
        };
        return 1;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *client_mod.Client, surface_runtime: *SurfaceRuntime) RemoteTermBackend {
        return .{ .allocator = allocator, .io = io, .client = client, .surface_runtime = surface_runtime };
    }

    pub fn initWithPool(allocator: std.mem.Allocator, io: std.Io, pool: *AdapterPool, surface_runtime: *SurfaceRuntime) !RemoteTermBackend {
        _ = pool.spawnHost() orelse return error.SpawnHostUnavailable;
        var result = initAttachOnlyWithPool(allocator, io, pool, surface_runtime);
        result.mode = .spawn_and_attach;
        return result;
    }

    /// current host bootstrap이 실패해도 saved N-1 runtime에는 attach할 수 있다. 이 모드는 spawn host가 없음을
    /// 명시적으로 허용하며, 새 Term spawn은 `spawn()`의 `spawnHost()` gate에서 실패한다.
    pub fn initAttachOnlyWithPool(allocator: std.mem.Allocator, io: std.Io, pool: *AdapterPool, surface_runtime: *SurfaceRuntime) RemoteTermBackend {
        return .{
            .allocator = allocator,
            .io = io,
            .client = null,
            .host_pool = pool,
            .mode = .attach_only,
            .surface_runtime = surface_runtime,
        };
    }

    pub fn configureNotifications(self: *RemoteTermBackend, enabled: bool) client_mod.ClientError!void {
        if (self.notifications_osc != enabled) {
            const next_generation = std.math.add(u64, self.notification_config_generation, 1) catch
                return error.ProtocolError;
            self.notifications_osc = enabled;
            self.notification_config_generation = next_generation;
        }
        var values = self.runtimes.valueIterator();
        while (values.next()) |entry| {
            if (entry.notification_config_applied_generation == self.notification_config_generation) continue;
            entry.runtime.updateNotificationConfig(
                self.notification_config_generation,
                self.notifications_osc,
                entry.notificationDisplayLabel(),
            ) catch |err| {
                // Multi-runtime RPC는 분산 원자 commit이 아니다. 이미 적용된 entry는 완전본이고 그대로 두되,
                // 아직 target generation에 도달하지 못한 entry를 retryable 0으로 표시한다. AppSession의 매-frame
                // binding sync가 같은 label까지 포함한 완전본을 개별 재전송하므로 보상 RPC 자체가 실패해도
                // daemon 정책이 영구히 갈라지지 않는다.
                var retry_values = self.runtimes.valueIterator();
                while (retry_values.next()) |retry_entry| {
                    if (retry_entry.notification_config_applied_generation != self.notification_config_generation)
                        retry_entry.notification_config_applied_generation = 0;
                }
                return err;
            };
            entry.notification_config_applied_generation = self.notification_config_generation;
        }
    }

    /// GUI의 현재 binding 표시 라벨을 daemon runtime metadata에 반영한다. 빈 라벨은 host의 runtime-ID fallback을
    /// 요청한다. 라벨은 UTF-8 codepoint를 자르지 않는 256-byte 상한으로 정규화하며, 같은 값은 RPC/generation을
    /// 만들지 않는다. generation은 runtime metadata별 축이므로 이 runtime만 전진해도 다른 runtime snapshot과 충돌하지
    /// 않는다. 이후 전역 notifications 토글은 각 entry가 보존한 라벨을 포함한 완전본을 다시 보낸다.
    pub fn configureNotificationBinding(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        display_label: []const u8,
    ) client_mod.ClientError!void {
        const entry = self.runtimes.getPtr(handle) orelse return error.ProtocolError;
        const bounded = boundedNotificationLabel(display_label);
        if (std.mem.eql(u8, entry.notificationDisplayLabel(), bounded) and
            entry.notification_config_applied_generation != 0) return;
        const next_generation = std.math.add(u64, self.notification_config_generation, 1) catch
            return error.ProtocolError;
        try entry.runtime.updateNotificationConfig(next_generation, self.notifications_osc, bounded);
        self.notification_config_generation = next_generation;
        @memset(&entry.notification_display_label, 0);
        @memcpy(entry.notification_display_label[0..bounded.len], bounded);
        entry.notification_display_label_len = @intCast(bounded.len);
        entry.notification_config_applied_generation = next_generation;
    }

    /// restore-first attach-only backend가 같은 pool의 current host publication을 얻은 뒤 새 backend를 만들지 않고
    /// spawn owner로 승격한다. runtime map과 기존 N-1 lease는 그대로 유지한다.
    pub fn promoteToSpawnAndAttach(self: *RemoteTermBackend, pool: *AdapterPool) !void {
        if (self.host_pool != pool or pool.spawnHost() == null) return error.SpawnHostUnavailable;
        self.mode = .spawn_and_attach;
    }

    /// 남은 원격 runtime을 회수한다(각각 라우팅 표에서 detach + host terminate + client-side deinit). client connection과
    /// surface_runtime은 borrowed라 안 건드린다(소유는 caller).
    pub fn deinit(self: *RemoteTermBackend) void {
        if (self.host_reconnect_preparing) process_seal.fatalIntegrity(.proof_loss);
        if (self.host_reconnect_job != null) self.cancelHostReconnectForProcessShutdownNoFail();
        var it = self.runtimes.iterator();
        while (it.next()) |kv| {
            self.destroyRuntimeEntry(kv.key_ptr.*, kv.value_ptr.*, .terminate);
        }
        if (self.shutdown_reclaim_host_id != 0) {
            const pool = self.host_pool orelse process_seal.fatalIntegrity(.proof_loss);
            const adapter = pool.get(self.shutdown_reclaim_host_id) orelse
                process_seal.fatalIntegrity(.proof_loss);
            while (adapter.slot.retiredClientCount() != 0) {
                var reclaim: client_slot_mod.PreparedRetiredClientReclaim = .{};
                adapter.prepareRetiredClientReclaim(&reclaim) catch
                    process_seal.fatalIntegrity(.proof_loss);
                adapter.commitRetiredClientReclaimAtTickEndNoFail(&reclaim);
            }
            self.shutdown_reclaim_host_id = 0;
        }
        self.runtimes.deinit(self.allocator);
        if (self.reserved_runtime_count != 0 or self.close_operation_owner.active)
            process_seal.fatalIntegrity(.proof_loss);
        if (self.paused_paste_budget.initialized()) self.paused_paste_budget.deinit();
        self.releaseProductSingleton();
        self.* = undefined;
    }

    /// App Quit calls this while runtime entries still exist. It consumes every CR5 stage using
    /// the same state-specific cleanup as `deinit`, but defers retired Client reclamation until
    /// AppSession teardown has removed all runtime readers.
    pub fn cancelHostReconnectForProcessShutdownNoFail(self: *RemoteTermBackend) void {
        if (self.host_reconnect_preparing or self.shutdown_reclaim_host_id != 0)
            process_seal.fatalIntegrity(.proof_loss);
        const job = self.host_reconnect_job orelse process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        if (job.state_raw == @intFromEnum(HostReconnectJobState.candidate_staged) or
            job.state_raw == @intFromEnum(HostReconnectJobState.mutation_sealed) or
            job.state_raw == @intFromEnum(HostReconnectJobState.controller_evidenced) or
            job.state_raw == @intFromEnum(HostReconnectJobState.controller_promoted))
        {
            const pool = self.host_pool orelse process_seal.fatalIntegrity(.proof_loss);
            const adapter = pool.get(job.host_id) orelse process_seal.fatalIntegrity(.proof_loss);
            const entry = self.runtimes.get(job.runtime_handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            if (job.state_raw == @intFromEnum(HostReconnectJobState.controller_evidenced)) {
                RemoteRuntime.backend_api.abortReconnectControllerEvidence(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.controller_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            } else if (job.state_raw == @intFromEnum(HostReconnectJobState.controller_promoted)) {
                RemoteRuntime.backend_api.abortReconnectPromotedController(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.controller_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            } else {
                RemoteRuntime.backend_api.abortReconnectObserverStage(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.deadline.?.absolute,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            }
            job.stage = null;
            self.shutdown_reclaim_host_id = job.host_id;
            job.state_raw = @intFromEnum(HostReconnectJobState.idle);
            job.seal = [_]u8{0} ** 32;
            job.* = .{};
        } else if (job.state_raw == @intFromEnum(HostReconnectJobState.replacement_published) or
            job.state_raw == @intFromEnum(HostReconnectJobState.shared_replacement_published) or
            job.state_raw == @intFromEnum(HostReconnectJobState.runtime_transactions_complete) or
            job.state_raw == @intFromEnum(HostReconnectJobState.host_failure_complete) or
            job.state_raw == @intFromEnum(HostReconnectJobState.candidate_failed) or
            job.state_raw == @intFromEnum(HostReconnectJobState.candidate_rejected) or
            job.state_raw == @intFromEnum(HostReconnectJobState.authority_conflict) or
            job.state_raw == @intFromEnum(HostReconnectJobState.takeover_sent_unknown) or
            job.state_raw == @intFromEnum(HostReconnectJobState.pre_takeover_failed))
        {
            const pool = self.host_pool orelse process_seal.fatalIntegrity(.proof_loss);
            _ = pool.get(job.host_id) orelse process_seal.fatalIntegrity(.proof_loss);
            self.shutdown_reclaim_host_id = job.host_id;
            job.state_raw = @intFromEnum(HostReconnectJobState.idle);
            job.seal = [_]u8{0} ** 32;
            job.* = .{};
        } else if (job.state_raw == @intFromEnum(HostReconnectJobState.replacement_failed)) {
            var owned = job.client;
            job.client = null;
            job.state_raw = @intFromEnum(HostReconnectJobState.idle);
            job.seal = [_]u8{0} ** 32;
            job.* = .{};
            if (owned) |*client| client.deinit();
        } else {
            job.abort(self) catch process_seal.fatalIntegrity(.proof_loss);
        }
        self.host_reconnect_job = null;
        self.allocator.destroy(job);
    }

    /// AppHost의 process-global owner settlement는 남은 runtime을 terminate하는 일반 deinit을 준비 검사로 쓰지 않는다.
    /// 모든 AppSession이 자기 runtime을 이미 remove/detach했고 reservation/close operation도 없을 때만 true다.
    pub fn readyForProcessSettlement(self: *const RemoteTermBackend) bool {
        if (self.runtimes.count() != 0 or self.reserved_runtime_count != 0 or self.close_operation_owner.active or
            self.host_reconnect_preparing or self.host_reconnect_job != null)
            return false;
        return self.close_sweep == .inactive;
    }

    /// AppSession 전역 슬롯에 설치된 뒤에만 제품 singleton을 claim한다. 반환형 생성자 안에서 봉인하면
    /// 대입 이동이 final address를 바꾸므로, 이 호출의 exact 두 제품 caller가 설치와 publication 사이를 소유한다.
    pub fn claimProductSingleton(self: *RemoteTermBackend) !void {
        if (!std.meta.eql(self.singleton_owner, RemoteBackendSingletonOwner{})) return error.InvalidSingletonOwner;
        const ready = try process_seal.currentReadyIdentity();
        const thread_id: u64 = @intCast(std.Thread.getCurrentId());
        if (thread_id == 0) return error.InvalidSingletonOwner;
        while (!remote_backend_singleton_mutex.tryLock()) std.atomic.spinLoopHint();
        defer remote_backend_singleton_mutex.unlock();
        if (remote_backend_singleton_addr != 0) return error.RemoteBackendAlreadyClaimed;
        const generation = std.math.add(u64, remote_backend_singleton_generation, 1) catch
            return error.SingletonGenerationExhausted;
        self.singleton_owner = .{
            .pid = ready.pid,
            .process_nonce = ready.process_nonce,
            .thread_id = thread_id,
            .backend_addr = @intFromPtr(self),
            .owner_generation = generation,
            .lifecycle_raw = @intFromEnum(RemoteBackendSingletonLifecycle.claimed),
        };
        errdefer self.singleton_owner = .{};
        self.singleton_owner.seal = try remoteBackendSingletonSeal(&self.singleton_owner);
        if (!validRemoteBackendSingleton(&self.singleton_owner, @intFromPtr(self))) return error.InvalidSingletonOwner;
        try self.paused_paste_budget.initInPlace();
        errdefer self.paused_paste_budget = .{};
        remote_backend_singleton_generation = generation;
        remote_backend_singleton_addr = @intFromPtr(self);
    }

    /// Reconnect coordinator가 장기 backend pointer를 저장하지 않고 현재 canonical singleton을
    /// owner turn마다 다시 확인하는 좁은 projection gate다. runtime map은 읽거나 바꾸지 않는다.
    pub fn validateReconnectCoordinatorTarget(self: *RemoteTermBackend) !void {
        if (!validRemoteBackendSingleton(&self.singleton_owner, @intFromPtr(self)))
            return error.InvalidSingletonOwner;
        while (!remote_backend_singleton_mutex.tryLock()) std.atomic.spinLoopHint();
        defer remote_backend_singleton_mutex.unlock();
        if (remote_backend_singleton_addr != @intFromPtr(self) or
            remote_backend_singleton_generation != self.singleton_owner.owner_generation)
            return error.InvalidSingletonOwner;
    }

    pub fn singletonGenerationForCoordinator(self: *RemoteTermBackend) !u64 {
        try self.validateReconnectCoordinatorTarget();
        return self.singleton_owner.owner_generation;
    }

    /// Actual exact-host connect를 backend-owned job에 바로 이동한다. 성공 Client는 이 함수 밖으로 나오지 않으며,
    /// host pool의 같은 adapter가 후속 replacement를 수행할 때까지 job이 exact once 소유한다.
    pub fn beginHostReconnectConnect(
        self: *RemoteTermBackend,
        base_cache_dir: []const u8,
        host_id: u128,
        phase: attach_phase_deadline.PhaseDeadline,
    ) HostReconnectStart {
        self.validateReconnectCoordinatorTarget() catch return .invalid_authority;
        const pool = self.host_pool orelse return .invalid_authority;
        const adapter = pool.get(host_id) orelse return .invalid_authority;
        if (adapter.hostId() != host_id or phase.kind != .connect_hello or phase.absolute.remainingNs() <= 0)
            return .invalid_authority;
        if (self.app_quit_shutdown_deadline_ns != 0 or self.app_quit_routing_tombstoned or
            self.app_quit_connections_terminalized) return .invalid_authority;
        if (self.host_reconnect_preparing or self.host_reconnect_job != null) return .busy;
        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;
        const job = self.allocator.create(HostReconnectJob) catch return .{ .failed = .out_of_memory };
        var job_owned = true;
        defer if (job_owned) {
            self.host_reconnect_job = null;
            self.allocator.destroy(job);
        };
        job.* = .{};
        self.host_reconnect_job = job;
        job.prepareForConnect(self, host_id, phase) catch {
            job.* = .{};
            self.host_reconnect_job = null;
            return .invalid_authority;
        };
        if (builtin.is_test) if (B5TestState.cr5b_before_connect_hook) |hook| hook(self, job);
        var outcome = host_connect.connectExistingHostUntil(self.allocator, base_cache_dir, host_id, phase);
        const result: HostReconnectStart = switch (outcome) {
            .failed => |reason| .{ .failed = reason },
            .connected => |*connected| job.adoptConnected(self, host_id, phase, connected),
        };
        if (result != .connected) {
            self.host_reconnect_job = null;
            return result;
        }
        job_owned = false;
        return .connected;
    }

    /// Adopts the c2 worker's already-connected Client without repeating connect/hello on the
    /// AppSession frame thread. Before allocation or ownership transfer, revalidate the exact
    /// pool generation, old connection generation, and every runtime's bound incident identity.
    /// Failure leaves `source` owned by the caller so the completion can abandon it exactly once.
    pub fn beginHostReconnectCandidate(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
        phase: attach_phase_deadline.PhaseDeadline,
        source: *client_mod.Client,
    ) HostReconnectStart {
        self.validateReconnectCoordinatorTarget() catch return .invalid_authority;
        const pool = self.host_pool orelse return .invalid_authority;
        const adapter = pool.get(snapshot.host_id) orelse return .invalid_authority;
        if (snapshot.host_id == 0 or snapshot.pool_membership_generation == 0 or
            snapshot.connection_generation == 0 or snapshot.incident_app_instance_nonce == 0 or
            snapshot.incident_sequence == 0 or snapshot.absolute_deadline_ns == 0 or
            pool.adapterGeneration(snapshot.host_id) != snapshot.pool_membership_generation or
            adapter.connectionGeneration() != snapshot.connection_generation or
            phase.kind != .connect_hello or phase.absolute.expires_at_ns != snapshot.absolute_deadline_ns or
            phase.absolute.remainingNs() <= 0 or source.fd < 0 or source.host_id != snapshot.host_id or
            !source.runtime_catchup_barrier_v1 or source.connection_profile != .gui)
            return .invalid_authority;
        if (self.app_quit_shutdown_deadline_ns != 0 or self.app_quit_routing_tombstoned or
            self.app_quit_connections_terminalized) return .invalid_authority;
        if (self.host_reconnect_preparing or self.host_reconnect_job != null) return .busy;

        var matching_count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.host_id != snapshot.host_id) continue;
            if (entry.value_ptr.host_adapter_generation != snapshot.pool_membership_generation or
                !RemoteRuntime.backend_api.matchesBoundReconnectIdentity(
                    entry.value_ptr.runtime,
                    snapshot.host_id,
                    snapshot.pool_membership_generation,
                    snapshot.connection_generation,
                    snapshot.incident_app_instance_nonce,
                    snapshot.incident_sequence,
                )) return .invalid_authority;
            matching_count += 1;
        }
        if (matching_count == 0) return .invalid_authority;

        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;
        const job = self.allocator.create(HostReconnectJob) catch return .{ .failed = .out_of_memory };
        var job_owned = true;
        defer if (job_owned) {
            self.host_reconnect_job = null;
            self.allocator.destroy(job);
        };
        job.* = .{};
        self.host_reconnect_job = job;
        job.prepareForConnect(self, snapshot.host_id, phase) catch {
            job.* = .{};
            self.host_reconnect_job = null;
            return .invalid_authority;
        };
        const result = job.adoptConnected(self, snapshot.host_id, phase, source);
        if (result != .connected) {
            job.* = .{};
            self.host_reconnect_job = null;
            return result;
        }
        job_owned = false;
        return .connected;
    }

    /// Coordinator facade: reconstructs the original absolute deadline from the sealed snapshot
    /// and moves the candidate into the existing CR5 job without exposing backend `io`.
    pub fn adoptReconnectCoordinatorCandidate(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
        source: *client_mod.Client,
    ) HostReconnectStart {
        const absolute = client_deadline.AbsoluteDeadline.fromAbsolute(
            self.io,
            snapshot.absolute_deadline_ns,
        ) catch return .invalid_authority;
        return self.beginHostReconnectCandidate(
            snapshot,
            attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, absolute),
            source,
        );
    }

    pub fn abortHostReconnectConnect(self: *RemoteTermBackend) !void {
        try self.validateReconnectCoordinatorTarget();
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        try job.abort(self);
        self.host_reconnect_job = null;
        self.allocator.destroy(job);
    }

    /// Advances exactly one existing CR5 closed-state transition. It never connects, waits, joins,
    /// or loops over multiple state-machine stages in one frame turn.
    pub fn progressHostReconnectOne(self: *RemoteTermBackend) !HostReconnectFrameProgress {
        try self.validateReconnectCoordinatorTarget();
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self)) return error.InvalidHostReconnectJob;
        const state = std.enums.fromInt(HostReconnectJobState, job.state_raw) orelse
            return error.InvalidHostReconnectJob;
        switch (state) {
            .connected => try self.prepareHostReconnectRuntimeRetirements(),
            .retirements_prepared => try self.prepareHostReconnectSharedReplacement(),
            .shared_replacement_reserved => try self.commitHostReconnectSharedReplacement(),
            .shared_replacement_published => {
                if (job.runtime_cursor.activeRow(job.runtimeRowsSlice() orelse
                    return error.InvalidHostReconnectJob) != null)
                {
                    _ = try self.beginNextHostReconnectRuntimeTransaction();
                } else {
                    _ = try self.completeHostReconnectRuntimeTransactions();
                }
            },
            .replacement_published => _ = try self.prepareHostReconnectObserverStage(job.runtime_handle),
            .candidate_staged => _ = try self.sealHostReconnectMutations(job.runtime_handle),
            .mutation_sealed => _ = self.executeHostReconnectTakeover(job.runtime_handle) catch |err| {
                if (job.valid(self) and job.state_raw != @intFromEnum(HostReconnectJobState.mutation_sealed))
                    return .advanced;
                return err;
            },
            .controller_evidenced => try self.promoteHostReconnectControllerBinding(job.runtime_handle),
            .controller_promoted => self.publishHostReconnectGeneration(job.runtime_handle) catch |err| {
                if (job.valid(self) and job.state_raw != @intFromEnum(HostReconnectJobState.controller_promoted))
                    return .advanced;
                return err;
            },
            .candidate_rejected, .authority_conflict, .takeover_sent_unknown, .pre_takeover_failed => {
                _ = try self.failHostReconnectRuntimeTransactions();
            },
            .candidate_failed => {
                if (job.runtime_cursor.next_index == 0) {
                    _ = try self.failHostReconnectRuntimeTransactions();
                } else {
                    _ = try self.failHostReconnectRuntimeTransactionsAfterSharedClientTerminal();
                }
            },
            .runtime_transactions_complete => return .completed_ready,
            .host_failure_complete => return .retained_terminal_ready,
            .preparing, .replacement_failed, .idle => return error.InvalidHostReconnectJob,
        }
        return .advanced;
    }

    pub fn preflightHostReconnectTerminal(
        self: *RemoteTermBackend,
    ) !HostReconnectTerminalKind {
        try self.validateReconnectCoordinatorTarget();
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or job.terminal_summary == null or job.runtimeRowsSlice() == null)
            return error.InvalidHostReconnectJob;
        return switch (std.enums.fromInt(HostReconnectJobState, job.state_raw) orelse
            return error.InvalidHostReconnectJob) {
            .runtime_transactions_complete => .completed,
            .host_failure_complete => .retained_terminal,
            else => error.InvalidHostReconnectJob,
        };
    }

    pub fn finalizeCompletedHostReconnectNoFail(self: *RemoteTermBackend) void {
        const job = self.host_reconnect_job orelse process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.runtime_transactions_complete) or
            job.terminal_summary == null)
            process_seal.fatalIntegrity(.proof_loss);
        self.host_reconnect_job = null;
        job.* = .{};
        self.allocator.destroy(job);
    }

    /// CR5b-2a freezes every captured runtime before the shared Client is touched. A failure at
    /// row k releases rows 0..k-1 in reverse order and leaves the connected job reusable/abortable.
    pub fn prepareHostReconnectRuntimeRetirements(self: *RemoteTermBackend) anyerror!void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or job.state_raw != @intFromEnum(HostReconnectJobState.connected))
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        if (@intFromPtr(adapter) != job.adapter_addr or
            adapter.connectionGeneration() != job.expected_connection_generation)
            return error.InvalidHostReconnectJob;

        var prepared_count: usize = 0;
        errdefer {
            var index = prepared_count;
            while (index > 0) {
                index -= 1;
                const row = job.runtime_rows[index];
                const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                    process_seal.fatalIntegrity(.proof_loss);
                RemoteRuntime.backend_api.abortHostWideRetirement(
                    entry.runtime,
                    adapter,
                    @intFromPtr(job),
                    job.job_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            }
        }
        for (job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                return error.InvalidHostReconnectJob;
            try RemoteRuntime.backend_api.prepareHostWideRetirement(
                entry.runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            );
            prepared_count += 1;
        }
        job.state_raw = @intFromEnum(HostReconnectJobState.retirements_prepared);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    /// CR5b-2b completes every fallible shared-Client preparation before the first runtime is
    /// changed. The reserved node has no Client payload; abort therefore preserves both Clients.
    pub fn prepareHostReconnectSharedReplacement(self: *RemoteTermBackend) anyerror!void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.retirements_prepared))
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        if (@intFromPtr(adapter) != job.adapter_addr or
            adapter.connectionGeneration() != job.expected_connection_generation)
            return error.InvalidHostReconnectJob;
        const placeholder_generation = std.math.add(
            u64,
            job.expected_connection_generation,
            1,
        ) catch return error.InvalidHostReconnectJob;

        try adapter.prepareAdmissionClose(
            job.expected_connection_generation,
            &job.shared_admission,
        );
        var admission_prepared = true;
        errdefer if (admission_prepared)
            adapter.cancelAdmissionClose(&job.shared_admission) catch
                process_seal.fatalIntegrity(.proof_loss);
        try adapter.prepareRetirementCleanup(
            &job.shared_admission,
            placeholder_generation,
            &job.shared_cleanup,
        );
        var cleanup_prepared = true;
        errdefer if (cleanup_prepared)
            adapter.abortRetirementCleanup(&job.shared_cleanup) catch
                process_seal.fatalIntegrity(.proof_loss);
        try adapter.reserveClientReplacementNode(
            &job.shared_cleanup,
            &job.client.?,
            &job.replacement,
        );
        var replacement_reserved = true;
        errdefer if (replacement_reserved)
            adapter.abortReservedClientReplacementNode(
                &job.shared_cleanup,
                &job.client.?,
                &job.replacement,
            ) catch process_seal.fatalIntegrity(.proof_loss);

        job.runtime_cursor = try host_reconnect_runtime_transaction.Cursor.initial(
            job.runtimeSetJobIdentity(),
            job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob,
        );
        job.terminal_summary = null;

        job.state_raw = @intFromEnum(HostReconnectJobState.shared_replacement_reserved);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        replacement_reserved = false;
        cleanup_prepared = false;
        admission_prepared = false;
    }

    pub fn commitHostReconnectSharedReplacement(self: *RemoteTermBackend) !void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_reserved))
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        if (@intFromPtr(adapter) != job.adapter_addr or
            adapter.connectionGeneration() != job.expected_connection_generation)
            return error.InvalidHostReconnectJob;

        // `job.valid` above is the last recoverable whole-set preflight. From the first runtime
        // transition onward every drift is common proof loss and no callback/allocation is allowed.
        for (job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss)) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            RemoteRuntime.backend_api.commitHostWideRetirementNoFail(
                entry.runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            );
            if (builtin.is_test and B5TestState.cr5b2b_runtime_commit_count <
                B5TestState.cr5b2b_retired_counts.len)
            {
                B5TestState.cr5b2b_retired_counts[B5TestState.cr5b2b_runtime_commit_count] =
                    adapter.slot.retiredClientCount();
                B5TestState.cr5b2b_runtime_commit_count += 1;
            }
        }
        adapter.commitAdmissionClose(&job.shared_admission) catch
            process_seal.fatalIntegrity(.proof_loss);
        adapter.preflightRetirementCleanup(
            &job.shared_admission,
            &job.shared_cleanup,
            job.replacement.next_connection_generation,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        adapter.preflightRetirementDetach(
            &job.shared_admission,
            job.expected_connection_generation,
            job.replacement.next_connection_generation,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        adapter.commitRetirementCleanupNoFail(
            &job.shared_admission,
            &job.shared_cleanup,
            job.replacement.next_connection_generation,
        );
        adapter.commitRetirementDetachNoFail(
            &job.shared_admission,
            job.expected_connection_generation,
            job.replacement.next_connection_generation,
        );
        adapter.finishRetirementCleanup(&job.shared_cleanup) catch
            process_seal.fatalIntegrity(.proof_loss);
        adapter.publishReservedClientReplacementAfterRetirementNoFail(
            &job.shared_cleanup,
            &job.client.?,
            &job.replacement,
        );
        job.client = null;
        job.shared_admission = .{};
        job.shared_cleanup = .{};
        job.state_raw = @intFromEnum(HostReconnectJobState.shared_replacement_published);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    /// Selects exactly the next sorted runtime row without replacing the shared Client again.
    /// The existing CR4 observer/takeover/publication entrypoints consume this one-row scratch.
    pub fn beginNextHostReconnectRuntimeTransaction(self: *RemoteTermBackend) !RuntimeHandle {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_published))
            return error.InvalidHostReconnectJob;
        const rows = job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob;
        const identity = job.runtime_cursor.activeRow(rows) orelse return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(identity.runtime_handle) orelse return error.InvalidHostReconnectJob;
        if (@intFromPtr(entry.runtime) != identity.runtime_addr or
            entry.runtime_generation != identity.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        job.runtime_handle = identity.runtime_handle;
        job.runtime_addr = identity.runtime_addr;
        job.runtime_generation = identity.runtime_generation;
        job.state_raw = @intFromEnum(HostReconnectJobState.replacement_published);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return identity.runtime_handle;
    }

    /// After every runtime has either published its new generation or been forward-resolved, the
    /// shared retired Client can be reclaimed exactly once. Failure paths first release the active
    /// and untouched suffix generations; successful rows already released theirs at publication.
    fn settleHostReconnectSharedRetirementNoFail(
        self: *RemoteTermBackend,
        job: *HostReconnectJob,
        adapter: *host_adapter_mod.HostAdapter,
        first_unpublished_index: usize,
    ) void {
        const rows = job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss);
        if (first_unpublished_index > rows.len) process_seal.fatalIntegrity(.proof_loss);
        for (rows[first_unpublished_index..]) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            RemoteRuntime.backend_api.reclaimHostWideRetiringGenerationRetainingClient(
                entry.runtime,
                adapter,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        var client_reclaim: client_slot_mod.PreparedRetiredClientReclaim = .{};
        adapter.prepareRetiredClientReclaim(&client_reclaim) catch
            process_seal.fatalIntegrity(.proof_loss);
        adapter.commitRetiredClientReclaimAtTickEndNoFail(&client_reclaim);
        job.replacement = .{};
    }

    pub fn completeHostReconnectRuntimeTransactions(
        self: *RemoteTermBackend,
    ) !host_reconnect_runtime_ledger.TerminalSummary {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.shared_replacement_published))
            return error.InvalidHostReconnectJob;
        const summary = try job.runtime_cursor.finishSuccess(
            job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob,
        );
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        self.settleHostReconnectSharedRetirementNoFail(
            job,
            adapter,
            job.runtime_cursor.next_index,
        );
        job.terminal_summary = summary;
        job.state_raw = @intFromEnum(HostReconnectJobState.runtime_transactions_complete);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return summary;
    }

    /// Closes the active row and every untouched suffix after a typed post-publication failure.
    /// Earlier `published_new` rows are immutable: this transition only rewrites the active row
    /// and the still-pristine suffix, then tombstones the one-row CR4 scratch before sealing the
    /// allocation-free terminal summary.
    pub fn failHostReconnectRuntimeTransactions(
        self: *RemoteTermBackend,
    ) !host_reconnect_runtime_ledger.TerminalSummary {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or job.runtime_cursor.pristine())
            return error.InvalidHostReconnectJob;
        const failure_state = std.enums.fromInt(HostReconnectJobState, job.state_raw) orelse
            return error.InvalidHostReconnectJob;
        // A terminal shared-Client failure invalidates transport usability for every earlier
        // published row. Until the host-wide failure gate owns that all-row transition, never
        // seal those rows as `published_new/open`. A first-row failure has no earlier success and
        // can still close the whole set as frozen.
        if ((failure_state == .candidate_failed or failure_state == .takeover_sent_unknown or
            failure_state == .pre_takeover_failed) and job.runtime_cursor.next_index != 0)
            return error.InvalidHostReconnectJob;
        const disposition: host_reconnect_runtime_transaction.FailureDisposition = switch (failure_state) {
            .candidate_rejected, .candidate_failed => .retry_old_valid,
            .authority_conflict => .authority_conflict,
            .takeover_sent_unknown, .pre_takeover_failed => .takeover_sent_unknown,
            else => return error.InvalidHostReconnectJob,
        };
        const row_count = std.math.cast(usize, job.runtime_row_count) orelse
            return error.InvalidHostReconnectJob;
        const summary = try job.runtime_cursor.failAndResolveRemaining(
            job.runtime_rows[0..row_count],
            disposition,
        );
        job.runtime_rows_digest = HostReconnectJob.runtimeRowsDigest(
            job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss),
        );
        job.runtime_handle = 0;
        job.runtime_addr = 0;
        job.runtime_generation = 0;
        job.request_nonce = 0;
        job.candidate_failure_reason_raw = 0;
        job.reconnect = .{};
        job.stage = null;
        job.mutation_digest = [_]u8{0} ** 32;
        job.controller_generation = 0;
        job.terminal_summary = summary;
        job.state_raw = @intFromEnum(HostReconnectJobState.runtime_transactions_complete);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return summary;
    }

    /// A terminal shared transport invalidates every runtime on the connection, including rows
    /// that already published a new generation. Prepare all such rows first, publish unavailable
    /// in a no-fail suffix, then retain the terminal generations and retired Client under the retry
    /// job until runtime-first backend teardown can reclaim them in canonical order.
    pub fn failHostReconnectRuntimeTransactionsAfterSharedClientTerminal(
        self: *RemoteTermBackend,
    ) !host_reconnect_runtime_ledger.TerminalSummary {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or job.state_raw != @intFromEnum(HostReconnectJobState.candidate_failed) or
            job.runtime_cursor.next_index == 0)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        const reason = job.candidateFailureReason() orelse return error.InvalidHostReconnectJob;
        try adapter.preflightAttachmentConnectionFailedClosed(reason);
        const rows = job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob;
        const published_count: usize = job.runtime_cursor.next_index;
        var prepared_count: usize = 0;
        errdefer for (rows[0..prepared_count]) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            RemoteRuntime.backend_api.abortHostWideRetirement(
                entry.runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        };
        for (rows[0..published_count]) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                return error.InvalidHostReconnectJob;
            try RemoteRuntime.backend_api.prepareHostWideRetirement(
                entry.runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            );
            prepared_count += 1;
        }
        for (rows[0..published_count]) |row| {
            const entry = self.runtimes.get(row.identity.runtime_handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            RemoteRuntime.backend_api.commitHostWideRetirementNoFail(
                entry.runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            );
        }
        prepared_count = 0;
        const summary = try job.runtime_cursor.failAllForTerminalConnection(
            job.runtime_rows[0..rows.len],
        );
        job.runtime_rows_digest = HostReconnectJob.runtimeRowsDigest(
            job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss),
        );
        job.runtime_handle = 0;
        job.runtime_addr = 0;
        job.runtime_generation = 0;
        job.request_nonce = 0;
        job.reconnect = .{};
        job.stage = null;
        job.mutation_digest = [_]u8{0} ** 32;
        job.controller_generation = 0;
        job.terminal_summary = summary;
        job.state_raw = @intFromEnum(HostReconnectJobState.host_failure_complete);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return summary;
    }

    /// Connected job의 fresh Client를 같은 HostAdapter의 next connection generation으로 exact once 게시한다.
    /// runtime의 old attachment/unavailable 전환과 ClientSlot publication은 RemoteRuntime owner leaf가 수행하고,
    /// published receipt는 후속 observer candidate가 소비할 수 있도록 job의 final address에 남긴다.
    pub fn publishHostReconnectReplacement(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or job.state_raw != @intFromEnum(HostReconnectJobState.connected))
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (entry.host_id != job.host_id or entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        if (@intFromPtr(adapter) != job.adapter_addr or
            adapter.connectionGeneration() != job.expected_connection_generation)
            return error.InvalidHostReconnectJob;

        const result = try RemoteRuntime.backend_api.publishReconnectClientReplacement(
            entry.runtime,
            adapter,
            &job.client.?,
            &job.replacement,
        );
        if (result == .forward_failed) {
            job.runtime_handle = runtime_handle;
            job.runtime_addr = @intFromPtr(entry.runtime);
            job.runtime_generation = entry.runtime_generation;
            job.state_raw = @intFromEnum(HostReconnectJobState.replacement_failed);
            job.seal = process_seal.hostReconnectJobSeal(
                job.pid,
                job.process_nonce,
                job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
            ) catch process_seal.fatalIntegrity(.proof_loss);
            if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
            return result.forward_failed;
        }
        job.client = null;
        job.runtime_handle = runtime_handle;
        job.runtime_addr = @intFromPtr(entry.runtime);
        job.runtime_generation = entry.runtime_generation;
        job.state_raw = @intFromEnum(HostReconnectJobState.replacement_published);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    /// Published replacement를 같은 job의 final-address observer candidate와 staged receipt로
    /// 확장한다. connect부터 이어진 absolute deadline을 재생성하지 않으며 성공·실패 모두 재시도를 닫는다.
    pub fn prepareHostReconnectObserverStage(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!*const catchup_stage_contract.PreparedStage {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.replacement_published) or
            runtime_handle != job.runtime_handle)
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (@intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        const deadline = job.deadline.?.absolute;
        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;
        if (deadline.remainingNs() <= 0) {
            self.sealHostReconnectCandidateFailure(job, adapter, 0, .read_timeout);
            return error.DeadlineExceeded;
        }
        var request_nonce: u128 = 0;
        self.io.randomSecure(std.mem.asBytes(&request_nonce)) catch |err| {
            self.sealHostReconnectCandidateFailure(job, adapter, 0, .local_resource_exhausted);
            return err;
        };
        if (request_nonce == 0) {
            self.sealHostReconnectCandidateFailure(job, adapter, 0, .local_invariant_violation);
            return error.InvalidHostReconnectJob;
        }
        const stage = RemoteRuntime.backend_api.prepareReconnectObserverStage(
            entry.runtime,
            adapter,
            &job.replacement,
            request_nonce,
            deadline,
            &job.reconnect,
        ) catch |err| {
            switch (classifyCandidatePrepareFailure(err)) {
                .rejected_usable => self.sealHostReconnectCandidateRejected(job, adapter, request_nonce),
                .terminal => |reason| self.sealHostReconnectCandidateFailure(job, adapter, request_nonce, reason),
            }
            return err;
        };
        job.request_nonce = request_nonce;
        job.candidate_failure_reason_raw = 0;
        job.stage = stage;
        job.state_raw = @intFromEnum(HostReconnectJobState.candidate_staged);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return stage;
    }

    /// Caught-up observer receipt 아래 stable queue를 exact once 동결한다. CR4a가 placeholder를
    /// 게시한 뒤 old mutation generation을 전진시키지 않았기 때문에 이 시점까지 새 mutation과
    /// queue pump는 0이고, 기존 payload만 metadata/paused-paste owner로 이동한다.
    pub fn sealHostReconnectMutations(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!reconnect_mutation_seal.SealResult {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.candidate_staged) or
            runtime_handle != job.runtime_handle)
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (@intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        if (!RemoteRuntime.backend_api.validateReconnectObserverStage(
            entry.runtime,
            adapter,
            &job.replacement,
            &job.reconnect,
            job.stage.?,
            job.deadline.?.absolute,
        )) return error.InvalidHostReconnectJob;
        const result = try RemoteRuntime.backend_api.sealReconnectMutations(
            entry.runtime,
            &self.paused_paste_budget,
        );
        job.mutation_digest = RemoteRuntime.backend_api.reconnectMutationSealDigest(entry.runtime) orelse
            process_seal.fatalIntegrity(.proof_loss);
        job.state_raw = @intFromEnum(HostReconnectJobState.mutation_sealed);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        return result;
    }

    /// Stable mutation seal 뒤에만 status/CAS takeover를 한 번 실행한다. 어떤 closed outcome도
    /// mutation_sealed로 되돌아가지 않으므로 request 재시도 권위가 생기지 않는다.
    pub fn executeHostReconnectTakeover(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!generation_attachment_mod.GenerationAttachment.ControllerTransferOutcome {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.mutation_sealed) or
            runtime_handle != job.runtime_handle)
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (@intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;
        const outcome = try RemoteRuntime.backend_api.executeReconnectControllerTakeoverUntil(
            entry.runtime,
            adapter,
            &job.replacement,
            &job.reconnect,
            job.stage.?,
            job.deadline.?.absolute,
        );
        self.finishHostReconnectTakeoverOutcome(job, entry, adapter, outcome);
        return outcome;
    }

    /// CR4c C1 re-keys the already-evidenced observer candidate in place. It deliberately does
    /// not publish the RemoteGeneration, open the stable mutation owner, resize, or send input.
    pub fn promoteHostReconnectControllerBinding(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.controller_evidenced) or
            runtime_handle != job.runtime_handle)
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (@intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;
        try RemoteRuntime.backend_api.promoteReconnectControllerEvidence(
            entry.runtime,
            adapter,
            &job.replacement,
            &job.reconnect,
            job.stage.?,
            job.controller_generation,
        );
        job.state_raw = @intFromEnum(HostReconnectJobState.controller_promoted);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    /// CR4c C2: apply the local viewport to the unpublished controller candidate, then publish
    /// generation/screen, reopen only the new mutation epoch, and reclaim old generation/client
    /// in remote-first order. A successful return leaves no reconnect job behind.
    pub fn publishHostReconnectGeneration(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) anyerror!void {
        try self.validateReconnectCoordinatorTarget();
        if (self.host_reconnect_preparing) return error.Busy;
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.controller_promoted) or
            runtime_handle != job.runtime_handle)
            return error.InvalidHostReconnectJob;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        if (@intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation)
            return error.InvalidHostReconnectJob;
        const pool = self.host_pool orelse return error.InvalidHostReconnectJob;
        const adapter = pool.get(job.host_id) orelse return error.InvalidHostReconnectJob;
        self.host_reconnect_preparing = true;
        defer self.host_reconnect_preparing = false;

        const size = RemoteRuntime.backend_api.forceReconnectCandidateResizeUntil(
            entry.runtime,
            adapter,
            &job.replacement,
            &job.reconnect,
            job.stage.?,
            job.controller_generation,
            job.deadline.?.absolute,
        ) catch |err| {
            const reason: @import("client_poison.zig").ConnectionReason = switch (err) {
                error.OutOfMemory, error.ResourceExhausted => .local_resource_exhausted,
                error.DeadlineExceeded => .read_timeout,
                else => .peer_contract_violation,
            };
            if (RemoteRuntime.backend_api.validateReconnectPromotedController(
                entry.runtime,
                adapter,
                &job.replacement,
                &job.reconnect,
                job.stage.?,
                job.controller_generation,
            )) {
                RemoteRuntime.backend_api.abortReconnectPromotedController(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.controller_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            } else {
                RemoteRuntime.backend_api.abortReconnectPromotedControllerAfterTerminal(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.controller_generation,
                ) catch process_seal.fatalIntegrity(.proof_loss);
            }
            const canonical_reason = adapter.failCloseAttachmentConnection(reason) catch
                process_seal.fatalIntegrity(.proof_loss);
            job.stage = null;
            job.controller_generation = 0;
            job.candidate_failure_reason_raw = @intFromEnum(canonical_reason) + 1;
            job.state_raw = @intFromEnum(HostReconnectJobState.candidate_failed);
            job.seal = process_seal.hostReconnectJobSeal(
                job.pid,
                job.process_nonce,
                job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
            ) catch process_seal.fatalIntegrity(.proof_loss);
            if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
            return err;
        };

        if (builtin.is_test and B5TestState.cr4c_publication_drift) {
            B5TestState.cr4c_publication_drift = false;
            job.controller_generation +%= 1;
        }

        const multi_runtime = !job.runtime_cursor.pristine();
        if (multi_runtime and job.runtime_cursor.activeRow(
            job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob,
        ) == null) return error.InvalidHostReconnectJob;
        if (multi_runtime) {
            RemoteRuntime.backend_api.publishReconnectPromotedCandidateRetainingSharedClient(
                entry.runtime,
                adapter,
                &job.replacement,
                &job.reconnect,
                job.stage.?,
                job.controller_generation,
                size,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        } else {
            RemoteRuntime.backend_api.publishReconnectPromotedCandidate(
                entry.runtime,
                adapter,
                &job.replacement,
                &job.reconnect,
                job.stage.?,
                job.controller_generation,
                size,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        if (multi_runtime) {
            const row_count = std.math.cast(usize, job.runtime_row_count) orelse
                process_seal.fatalIntegrity(.proof_loss);
            job.runtime_cursor.commitPublishedNew(
                job.runtime_rows[0..row_count],
            ) catch process_seal.fatalIntegrity(.proof_loss);
            job.runtime_rows_digest = HostReconnectJob.runtimeRowsDigest(
                job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss),
            );
            job.runtime_handle = 0;
            job.runtime_addr = 0;
            job.runtime_generation = 0;
            job.request_nonce = 0;
            job.candidate_failure_reason_raw = 0;
            job.reconnect = .{};
            job.stage = null;
            job.mutation_digest = [_]u8{0} ** 32;
            job.controller_generation = 0;
            job.state_raw = @intFromEnum(HostReconnectJobState.shared_replacement_published);
            job.seal = process_seal.hostReconnectJobSeal(
                job.pid,
                job.process_nonce,
                job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
            ) catch process_seal.fatalIntegrity(.proof_loss);
            if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
            return;
        }
        job.stage = null;
        job.state_raw = @intFromEnum(HostReconnectJobState.idle);
        job.seal = [_]u8{0} ** 32;
        job.* = .{};
        self.host_reconnect_job = null;
        self.allocator.destroy(job);
    }

    fn finishHostReconnectTakeoverOutcome(
        self: *RemoteTermBackend,
        job: *HostReconnectJob,
        entry: RuntimeEntry,
        adapter: *host_adapter_mod.HostAdapter,
        outcome: generation_attachment_mod.GenerationAttachment.ControllerTransferOutcome,
    ) void {
        if (self.host_reconnect_job != job or
            job.state_raw != @intFromEnum(HostReconnectJobState.mutation_sealed) or
            @intFromPtr(entry.runtime) != job.runtime_addr or
            entry.runtime_generation != job.runtime_generation or entry.host_id != job.host_id or
            entry.host_adapter_generation != job.adapter_generation or job.stage == null)
            process_seal.fatalIntegrity(.proof_loss);
        switch (outcome) {
            .new_controller_evidenced => |generation| {
                job.controller_generation = generation;
                job.state_raw = @intFromEnum(HostReconnectJobState.controller_evidenced);
            },
            .authority_conflict => {
                job.state_raw = @intFromEnum(HostReconnectJobState.authority_conflict);
            },
            .takeover_sent_unknown => {
                const reason = adapter.failCloseAttachmentConnection(.response_correlation_lost) catch
                    process_seal.fatalIntegrity(.proof_loss);
                job.candidate_failure_reason_raw = @intFromEnum(reason) + 1;
                job.state_raw = @intFromEnum(HostReconnectJobState.takeover_sent_unknown);
            },
            .pre_takeover_failed => {
                const reason = adapter.failCloseAttachmentConnection(.local_invariant_violation) catch
                    process_seal.fatalIntegrity(.proof_loss);
                job.candidate_failure_reason_raw = @intFromEnum(reason) + 1;
                job.state_raw = @intFromEnum(HostReconnectJobState.pre_takeover_failed);
            },
        }
        switch (outcome) {
            .new_controller_evidenced => {},
            .authority_conflict => {
                RemoteRuntime.backend_api.abortReconnectObserverStage(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.deadline.?.absolute,
                ) catch process_seal.fatalIntegrity(.proof_loss);
                job.stage = null;
            },
            .takeover_sent_unknown, .pre_takeover_failed => {
                RemoteRuntime.backend_api.abortReconnectObserverStageForClosedOutcome(
                    entry.runtime,
                    adapter,
                    &job.replacement,
                    &job.reconnect,
                    job.stage.?,
                    job.deadline.?.absolute,
                ) catch process_seal.fatalIntegrity(.proof_loss);
                job.stage = null;
            },
        }
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    fn sealHostReconnectCandidateFailure(
        self: *RemoteTermBackend,
        job: *HostReconnectJob,
        adapter: *host_adapter_mod.HostAdapter,
        request_nonce: u128,
        reason: @import("client_poison.zig").ConnectionReason,
    ) void {
        if (self.host_reconnect_job != job or
            job.state_raw != @intFromEnum(HostReconnectJobState.replacement_published) or
            job.stage != null or !std.meta.eql(job.reconnect, remote_runtime.PreparedReconnect{}))
            process_seal.fatalIntegrity(.proof_loss);
        const canonical_reason = adapter.failCloseAttachmentConnection(reason) catch
            process_seal.fatalIntegrity(.proof_loss);
        job.request_nonce = request_nonce;
        job.candidate_failure_reason_raw = @intFromEnum(canonical_reason) + 1;
        job.state_raw = @intFromEnum(HostReconnectJobState.candidate_failed);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    fn sealHostReconnectCandidateRejected(
        self: *RemoteTermBackend,
        job: *HostReconnectJob,
        adapter: *host_adapter_mod.HostAdapter,
        request_nonce: u128,
    ) void {
        if (self.host_reconnect_job != job or request_nonce == 0 or
            job.state_raw != @intFromEnum(HostReconnectJobState.replacement_published) or
            job.stage != null or !std.meta.eql(job.reconnect, remote_runtime.PreparedReconnect{}))
            process_seal.fatalIntegrity(.proof_loss);
        adapter.preflightAttachmentConnectionUsable() catch process_seal.fatalIntegrity(.proof_loss);
        job.request_nonce = request_nonce;
        job.candidate_failure_reason_raw = 0;
        job.state_raw = @intFromEnum(HostReconnectJobState.candidate_rejected);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
    }

    pub fn directReleaseTarget(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) !DirectReleaseTarget {
        try self.validateReconnectCoordinatorTarget();
        if (runtime_handle == 0) return error.UnknownSurface;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        const projection = try RemoteRuntime.backend_api.directReleaseProjection(entry.runtime);
        if (projection.host_id != entry.host_id or
            projection.host_adapter_generation != entry.host_adapter_generation)
            return error.StaleExternalEvent;
        return .{
            .runtime_handle = runtime_handle,
            .runtime_generation = entry.runtime_generation,
            .projection = projection,
        };
    }

    pub fn applyDirectReleaseTarget(self: *RemoteTermBackend, target: DirectReleaseTarget) !void {
        try self.validateReconnectCoordinatorTarget();
        const entry = self.runtimes.get(target.runtime_handle) orelse return error.UnknownSurface;
        if (entry.runtime_generation != target.runtime_generation or
            entry.host_id != target.projection.host_id or
            entry.host_adapter_generation != target.projection.host_adapter_generation)
            return error.StaleExternalEvent;
        try RemoteRuntime.backend_api.applyDirectReleaseProjection(entry.runtime, target.projection);
    }

    pub fn closeTransitionTarget(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
        event: remote_runtime.CloseEvent,
    ) !CloseTransitionTarget {
        try self.validateReconnectCoordinatorTarget();
        if (runtime_handle == 0) return error.UnknownSurface;
        const entry = self.runtimes.get(runtime_handle) orelse return error.UnknownSurface;
        return .{
            .runtime_handle = runtime_handle,
            .runtime_generation = entry.runtime_generation,
            .runtime_id = entry.runtime.appQuitRuntimeId(),
            .projection = try RemoteRuntime.backend_api.closeTransitionProjection(entry.runtime, event),
        };
    }

    pub fn applyCloseTransitionTarget(
        self: *RemoteTermBackend,
        target: CloseTransitionTarget,
    ) !void {
        try self.validateReconnectCoordinatorTarget();
        const entry = self.runtimes.get(target.runtime_handle) orelse return error.UnknownSurface;
        const runtime_id = entry.runtime.appQuitRuntimeId();
        if (entry.runtime_generation != target.runtime_generation or
            !std.mem.eql(u8, &runtime_id, &target.runtime_id))
            return error.StaleExternalEvent;
        try RemoteRuntime.backend_api.applyCloseTransitionProjection(entry.runtime, target.projection);
    }

    /// CR5d-2 bridge: the backend keeps the terminal summary/runtime rows private and supplies the
    /// canonical runtime generation for each AppSession-owned Window draft.  No topology mutation
    /// occurs here; the returned transaction is still consumed only by the AppSession coordinator.
    pub fn prepareHostReconnectWindowTransaction(
        self: *RemoteTermBackend,
        drafts: []const WindowBindingDraft,
        action: host_reconnect_window_transaction.ActionRequest,
        now_ns: u64,
    ) !*host_reconnect_window_transaction.Transaction {
        if (action.action_generation != 0) return error.InvalidHostReconnectJob;
        if (std.meta.eql(self.host_reconnect_window_owner, host_reconnect_window_transaction.Owner{}))
            try self.host_reconnect_window_owner.initInPlace(self.singleton_owner.owner_generation);
        if (!std.meta.eql(self.host_reconnect_window_transaction, host_reconnect_window_transaction.Transaction{}))
            try host_reconnect_window_transaction.recycleConsumed(
                &self.host_reconnect_window_owner,
                &self.host_reconnect_window_transaction,
            );
        var bindings: [host_reconnect_window_transaction.max_bindings]host_reconnect_window_transaction.WindowBinding = undefined;
        const projection = try self.fillWindowTransactionProjection(drafts, &bindings);
        var canonical_action = action;
        canonical_action.action_generation = std.math.add(
            u64,
            self.next_host_reconnect_window_action_generation,
            1,
        ) catch return error.InvalidHostReconnectJob;
        try host_reconnect_window_transaction.prepare(
            &self.host_reconnect_window_owner,
            &self.host_reconnect_window_transaction,
            projection.summary,
            projection.rows,
            bindings[0..projection.binding_count],
            canonical_action,
            now_ns,
        );
        self.next_host_reconnect_window_action_generation = canonical_action.action_generation;
        return &self.host_reconnect_window_transaction;
    }

    pub fn consumeHostReconnectWindowTransaction(
        self: *RemoteTermBackend,
        transaction: *host_reconnect_window_transaction.Transaction,
        drafts: []const WindowBindingDraft,
        now_ns: u64,
    ) !void {
        var bindings: [host_reconnect_window_transaction.max_bindings]host_reconnect_window_transaction.WindowBinding = undefined;
        const projection = try self.fillWindowTransactionProjection(drafts, &bindings);
        try host_reconnect_window_transaction.consume(
            &self.host_reconnect_window_owner,
            transaction,
            projection.summary,
            projection.rows,
            bindings[0..projection.binding_count],
            now_ns,
        );
    }

    /// The only CR5d close commit.  Both fallible authorities are checked before consuming the
    /// Window gesture; after consume, applying the already-projected reducer transition is a
    /// same-thread no-allocation suffix and any drift is common proof loss.
    pub fn commitHostReconnectWindowClose(
        self: *RemoteTermBackend,
        transaction: *host_reconnect_window_transaction.Transaction,
        drafts: []const WindowBindingDraft,
        now_ns: u64,
    ) !void {
        if (transaction.action.kind_raw != @intFromEnum(host_reconnect_window_transaction.ActionKind.close))
            return error.InvalidHostReconnectJob;
        const close_target = try self.closeTransitionTarget(
            transaction.action.target_runtime_handle,
            remote_runtime.CloseEvent.init(.abandon_to_inventory),
        );
        if (close_target.projection.decision_raw != @intFromEnum(reconnect_reducer.Decision.abandon_shell_to_inventory))
            return error.InvalidHostReconnectJob;
        try self.consumeHostReconnectWindowTransaction(transaction, drafts, now_ns);
        self.applyCloseTransitionTarget(close_target) catch process_seal.fatalIntegrity(.proof_loss);
    }

    /// Removes one Window-abandoned runtime from the terminal host-wide job and the client-side
    /// backend graph in one forward-only suffix. The host runtime is not terminated: discovery can
    /// admit it again from inventory, while the remaining Window bindings keep the same job.
    pub fn detachAbandonedWindowTerm(
        self: *RemoteTermBackend,
        runtime_handle: RuntimeHandle,
    ) void {
        self.validateReconnectCoordinatorTarget() catch process_seal.fatalIntegrity(.proof_loss);
        const transaction = &self.host_reconnect_window_transaction;
        const job = self.host_reconnect_job orelse process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.host_failure_complete) or
            !host_reconnect_window_transaction.consumedExact(
                &self.host_reconnect_window_owner,
                transaction,
            ) or
            transaction.action.target_runtime_handle != runtime_handle)
            process_seal.fatalIntegrity(.proof_loss);
        const rows = job.runtimeRowsSlice() orelse process_seal.fatalIntegrity(.proof_loss);
        if (rows.len <= 1) process_seal.fatalIntegrity(.proof_loss);

        var removed_index: ?usize = null;
        var next_rows: [host_reconnect_runtime_ledger.max_runtime_rows]host_reconnect_runtime_ledger.RuntimeRow = undefined;
        var next_count: usize = 0;
        for (rows, 0..) |row, index| {
            if (row.identity.runtime_handle == runtime_handle) {
                if (removed_index != null) process_seal.fatalIntegrity(.proof_loss);
                removed_index = index;
            } else {
                next_rows[next_count] = row;
                next_count += 1;
            }
        }
        _ = removed_index orelse process_seal.fatalIntegrity(.proof_loss);
        const entry = self.runtimes.get(runtime_handle) orelse
            process_seal.fatalIntegrity(.proof_loss);
        if (!RemoteRuntime.backend_api.hostReconnectAbandonedToInventoryExact(entry.runtime))
            process_seal.fatalIntegrity(.proof_loss);
        const next_summary = host_reconnect_runtime_ledger.summarizeTerminalRows(
            job.runtimeSetJobIdentity(),
            next_rows[0..next_count],
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (next_summary.published_new != 0 or next_summary.frozen_unavailable != next_count)
            process_seal.fatalIntegrity(.proof_loss);

        @memcpy(job.runtime_rows[0..next_count], next_rows[0..next_count]);
        job.runtime_row_count = @intCast(next_count);
        job.runtime_cursor.next_index = @intCast(next_count);
        job.runtime_cursor.terminal_count = @intCast(next_count);
        job.runtime_rows_digest = HostReconnectJob.runtimeRowsDigest(job.runtime_rows[0..next_count]);
        job.terminal_summary = next_summary;
        self.surface_runtime.detachSurface(entry.runtime.surface.id);
        const removed = self.runtimes.fetchRemove(runtime_handle) orelse
            process_seal.fatalIntegrity(.proof_loss);
        if (removed.value.runtime != entry.runtime or removed.value.host_id != entry.host_id or
            removed.value.runtime_generation != entry.runtime_generation)
            process_seal.fatalIntegrity(.proof_loss);
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse process_seal.fatalIntegrity(.proof_loss),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        if (!job.valid(self)) process_seal.fatalIntegrity(.proof_loss);
        // Only resource callbacks remain. The authoritative job/map projection above is already
        // fully committed, so reentry cannot observe a half-removed runtime row.
        removed.value.runtime.detachClientSide();
        self.allocator.destroy(removed.value.runtime);
        if (self.host_pool) |pool| pool.release(removed.value.host_id);
    }

    pub fn revokeStaleHostReconnectWindowTransaction(
        self: *RemoteTermBackend,
        transaction: *host_reconnect_window_transaction.Transaction,
    ) !void {
        if (transaction != &self.host_reconnect_window_transaction) return error.InvalidHostReconnectJob;
        try host_reconnect_window_transaction.revokeStale(
            &self.host_reconnect_window_owner,
            transaction,
        );
    }

    fn fillWindowTransactionProjection(
        self: *RemoteTermBackend,
        drafts: []const WindowBindingDraft,
        bindings: *[host_reconnect_window_transaction.max_bindings]host_reconnect_window_transaction.WindowBinding,
    ) !WindowTransactionProjection {
        try self.validateReconnectCoordinatorTarget();
        const job = self.host_reconnect_job orelse return error.InvalidHostReconnectJob;
        if (!job.valid(self) or
            job.state_raw != @intFromEnum(HostReconnectJobState.host_failure_complete))
            return error.InvalidHostReconnectJob;
        const rows = job.runtimeRowsSlice() orelse return error.InvalidHostReconnectJob;
        const summary = job.terminal_summary orelse return error.InvalidHostReconnectJob;
        if (drafts.len > host_reconnect_window_transaction.max_bindings)
            return error.InvalidHostReconnectJob;
        for (drafts, 0..) |draft, index| {
            if (draft.window_addr == 0 or draft.app_session_generation == 0 or
                draft.graph_generation == 0 or draft.runtime_handle == 0 or draft.surface_id == 0 or
                (index != 0 and drafts[index - 1].runtime_handle >= draft.runtime_handle))
                return error.InvalidHostReconnectJob;
        }
        // A pair of Windows may also contain remote Terms from another host.  The backend job is
        // the authority for this host's exact runtime set, so select its sorted rows from the
        // broader sorted Window projection instead of requiring every remote Term to belong to
        // this job.  Missing or duplicate matching bindings remain a closed rejection.
        var draft_index: usize = 0;
        for (rows, 0..) |row, index| {
            while (draft_index < drafts.len and
                drafts[draft_index].runtime_handle < row.identity.runtime_handle) : (draft_index += 1)
            {}
            if (draft_index == drafts.len or
                drafts[draft_index].runtime_handle != row.identity.runtime_handle)
                return error.InvalidHostReconnectJob;
            const draft = drafts[draft_index];
            if (draft_index + 1 < drafts.len and
                drafts[draft_index + 1].runtime_handle == draft.runtime_handle)
                return error.InvalidHostReconnectJob;
            const entry = self.runtimes.get(draft.runtime_handle) orelse return error.InvalidHostReconnectJob;
            if (entry.runtime_generation != row.identity.runtime_generation or
                @intFromPtr(entry.runtime) != row.identity.runtime_addr)
                return error.InvalidHostReconnectJob;
            bindings[index] = .{
                .window_addr = draft.window_addr,
                .app_session_generation = draft.app_session_generation,
                .graph_generation = draft.graph_generation,
                .runtime_handle = draft.runtime_handle,
                .runtime_generation = row.identity.runtime_generation,
                .surface_id = draft.surface_id,
            };
            draft_index += 1;
        }
        return .{ .summary = summary, .rows = rows, .binding_count = rows.len };
    }

    fn releaseProductSingleton(self: *RemoteTermBackend) void {
        if (std.meta.eql(self.singleton_owner, RemoteBackendSingletonOwner{})) return;
        if (!validRemoteBackendSingleton(&self.singleton_owner, @intFromPtr(self)))
            process_seal.fatalIntegrity(.proof_loss);
        while (!remote_backend_singleton_mutex.tryLock()) std.atomic.spinLoopHint();
        defer remote_backend_singleton_mutex.unlock();
        if (remote_backend_singleton_addr != @intFromPtr(self) or
            remote_backend_singleton_generation != self.singleton_owner.owner_generation)
            process_seal.fatalIntegrity(.proof_loss);
        self.singleton_owner.lifecycle_raw = @intFromEnum(RemoteBackendSingletonLifecycle.released);
        self.singleton_owner.seal = remoteBackendSingletonSeal(&self.singleton_owner) catch
            process_seal.fatalIntegrity(.proof_loss);
        remote_backend_singleton_addr = 0;
    }

    const DestroyMode = enum { terminate, detach };

    fn destroyRuntimeEntry(self: *RemoteTermBackend, handle: RuntimeHandle, entry: RuntimeEntry, mode: DestroyMode) void {
        if (builtin.is_test and B5TestState.skip_destroy) return;
        self.surface_runtime.detachSurface(handle);
        switch (mode) {
            .terminate => entry.runtime.deinit(),
            .detach => entry.runtime.detachClientSide(),
        }
        self.allocator.destroy(entry.runtime);
        if (self.host_pool) |pool| pool.release(entry.host_id);
    }

    /// GUI가 쓰는 계약 값(in-process와 동일 표면). ctx는 heap-pin된 backend를 가리켜야 한다(caller가 안정 주소 보장).
    pub fn backend(self: *RemoteTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn reserveRuntimeAdmission(self: *RemoteTermBackend, out: *RuntimeAdmissionReservation) !void {
        if (!std.meta.eql(out.*, RuntimeAdmissionReservation{})) return error.InvalidReservation;
        if (self.runtimes.count() + self.reserved_runtime_count >= max_remote_backend_runtimes)
            return error.ResourceExhausted;
        self.next_admission_generation = std.math.add(u64, self.next_admission_generation, 1) catch
            return error.AdmissionGenerationExhausted;
        const ready = try process_seal.currentReadyIdentity();
        errdefer out.* = .{};
        out.* = .{
            .self_addr = @intFromPtr(out),
            .backend_addr = @intFromPtr(self),
            .pid = ready.pid,
            .process_nonce = ready.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .request_generation = self.next_admission_generation,
            .state_raw = 1,
        };
        out.seal = try runtimeAdmissionSeal(out);
        self.reserved_runtime_count += 1;
    }

    pub fn abortRuntimeAdmission(self: *RemoteTermBackend, reservation: *RuntimeAdmissionReservation) void {
        if (!self.validRuntimeAdmission(reservation) or self.reserved_runtime_count == 0)
            process_seal.fatalIntegrity(.proof_loss);
        self.reserved_runtime_count -= 1;
        reservation.state_raw = 3;
        reservation.seal = [_]u8{0} ** 32;
    }

    fn consumeRuntimeAdmission(self: *RemoteTermBackend, reservation: *RuntimeAdmissionReservation) void {
        if (!self.validRuntimeAdmission(reservation) or self.reserved_runtime_count == 0)
            process_seal.fatalIntegrity(.proof_loss);
        self.reserved_runtime_count -= 1;
        reservation.state_raw = 2;
        reservation.seal = [_]u8{0} ** 32;
    }

    fn validRuntimeAdmission(self: *const RemoteTermBackend, reservation: *const RuntimeAdmissionReservation) bool {
        const expected_seal = runtimeAdmissionSeal(reservation) catch return false;
        return reservation.self_addr == @intFromPtr(reservation) and reservation.backend_addr == @intFromPtr(self) and
            reservation.pid == process_seal.currentProcessId() and
            reservation.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
            reservation.request_generation != 0 and reservation.state_raw == 1 and
            std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected_seal, reservation.seal);
    }

    fn runtimeAdmissionSeal(reservation: *const RuntimeAdmissionReservation) process_seal.ReadyError!process_seal.CleanupSeal {
        return process_seal.runtimeAdmissionSeal(reservation.pid, reservation.process_nonce, .{
            .self_addr = @intFromPtr(reservation),
            .backend_addr = reservation.backend_addr,
            .thread_id = reservation.thread_id,
            .request_generation = reservation.request_generation,
            .state_raw = reservation.state_raw,
        });
    }

    fn issueRuntimeGeneration(self: *RemoteTermBackend) !u64 {
        self.next_runtime_generation = std.math.add(u64, self.next_runtime_generation, 1) catch
            return error.RuntimeGenerationExhausted;
        if (self.next_runtime_generation == 0) return error.RuntimeGenerationExhausted;
        return self.next_runtime_generation;
    }

    pub fn maintenanceCloseTick(self: *RemoteTermBackend) CloseMaintenanceStats {
        var stats: CloseMaintenanceStats = .{};
        var receipts: [max_remote_backend_runtimes]close_contract.CloseScanReceipt = undefined;
        var receipt_count: usize = 0;
        {
            var iterator = self.runtimes.iterator();
            while (iterator.next()) |row| {
                stats.visited_count += 1;
                const authority = &row.value_ptr.runtime.close_authority;
                if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.pristine)) continue;
                if (!close_authority.valid(authority)) process_seal.fatalIntegrity(.proof_loss);
                receipts[receipt_count] = .{
                    .handle = row.key_ptr.*,
                    .runtime_generation = row.value_ptr.runtime_generation,
                    .close_request_generation = authority.close_request_generation,
                    .close_schedule_ticket = authority.close_schedule_ticket,
                };
                receipt_count += 1;
            }
        }
        if (builtin.is_test) {
            if (B5TestState.scan_hook) |hook| hook(self);
        }
        var selected: [16]close_contract.CloseScanReceipt = undefined;
        const selected_count = close_contract.selectCloseSweep(&self.close_sweep, receipts[0..receipt_count], &selected);
        stats.selected_count = selected_count;
        for (selected[0..selected_count]) |receipt| {
            const row = self.runtimes.get(receipt.handle) orelse continue;
            const authority = &row.runtime.close_authority;
            if (row.runtime_generation != receipt.runtime_generation or
                authority.close_request_generation != receipt.close_request_generation or
                authority.close_schedule_ticket != receipt.close_schedule_ticket) continue;
            if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.ready_remove)) {
                if (remove(self, receipt.handle) == .removed) stats.removed_count += 1;
                continue;
            }
            const kind: close_authority.CloseRequestKind = switch (authority.request_kind_raw) {
                1...3 => @enumFromInt(authority.request_kind_raw),
                else => process_seal.fatalIntegrity(.proof_loss),
            };
            const disposition: close_authority.CloseDisposition = switch (authority.disposition_raw) {
                1...2 => @enumFromInt(authority.disposition_raw),
                else => process_seal.fatalIntegrity(.proof_loss),
            };
            _ = self.requestRuntimeClose(receipt.handle, kind, disposition);
        }
        return stats;
    }

    /// AppSession frame이 모든 Term pump를 부르기 전에 원격 owner를 최대 16개만 선택한다.
    /// 각 Term pump는 여기서 준비한 summary를 소비하므로 같은 frame의 Busy owner를 다시 실행하지 않는다.
    pub fn maintenanceEventTick(self: *RemoteTermBackend) void {
        var pending_iterator = self.runtimes.iterator();
        while (pending_iterator.next()) |row| {
            // 여러 AppSession window가 같은 backend를 순서대로 tick해도 앞 window가 만든 frame을 덮지 않는다.
            if (RemoteRuntime.backend_api.frameSummaryReady(row.value_ptr.runtime)) return;
        }
        var handles: [max_remote_backend_runtimes]RuntimeHandle = undefined;
        var handle_count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |row| {
            RemoteRuntime.backend_api.prepareFrameSummary(row.value_ptr.runtime);
            handles[handle_count] = row.key_ptr.*;
            handle_count += 1;
        }
        if (handle_count == 0) {
            self.event_pump_cursor = 0;
            return;
        }
        std.mem.sort(RuntimeHandle, handles[0..handle_count], {}, std.sort.asc(RuntimeHandle));
        if (self.event_pump_cursor >= handle_count) self.event_pump_cursor = 0;

        // The first round-robin owner is the connection probe. Its ordinary pump either consumes
        // its own batch or demultiplexes a sibling batch into the sealed canonical Client queue.
        // Only after that real read may the queue provide a routing hint for the remaining slots.
        const probe_handle = handles[self.event_pump_cursor];
        const probe_entry = self.runtimes.get(probe_handle) orelse
            process_seal.fatalIntegrity(.proof_loss);
        client_idle_pump_evidence.recordSelectedOwner();
        RemoteRuntime.backend_api.storeFrameSummary(
            probe_entry.runtime,
            if (builtin.is_test and B5TestState.event_pump_hook != null)
                B5TestState.event_pump_hook.?(probe_handle, probe_entry.runtime)
            else
                drainRemoteNow(probe_entry.runtime),
        );

        var host_probes: [max_remote_backend_runtimes]HostProbe = undefined;
        var ready_hosts: [max_remote_backend_runtimes]u128 = undefined;
        var ready_host_count: usize = 0;
        for (handles[0..handle_count], 0..) |handle, index| {
            const entry = self.runtimes.get(handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            host_probes[index] = .{ .host_id = entry.host_id, .runtime = entry.runtime };
        }
        std.mem.sort(HostProbe, host_probes[0..handle_count], {}, hostProbeLessThan);
        for (host_probes[0..handle_count], 0..) |probe, index| {
            if (index != 0 and host_probes[index - 1].host_id == probe.host_id) continue;
            if (RemoteRuntime.backend_api.hasAnyBufferedFrameWork(probe.runtime) catch false) {
                ready_hosts[ready_host_count] = probe.host_id;
                ready_host_count += 1;
            }
        }
        var priority = [_]bool{false} ** max_remote_backend_runtimes;
        for (handles[0..handle_count], 0..) |handle, index| {
            const entry = self.runtimes.get(handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            priority[index] = RemoteRuntime.backend_api.hasImmediateFrameWork(entry.runtime);
            const host_ready = sortedHostsContain(ready_hosts[0..ready_host_count], entry.host_id);
            if (host_ready)
                priority[index] = priority[index] or
                    (RemoteRuntime.backend_api.hasBufferedFrameWork(entry.runtime) catch false);
        }
        var selected: [event_pump_contract.max_owners_per_frame]RuntimeHandle = undefined;
        const selection = event_pump_contract.selectAfterProbe(
            handles[0..handle_count],
            self.event_pump_cursor,
            priority[0..handle_count],
            &selected,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        const selected_count = selection.count;
        _ = event_pump_contract.frameBudget(
            selected_count,
            selected_count * event_pump_contract.retained_parts_per_owner * protocol.max_control_json,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        for (selected[1..selected_count]) |handle| {
            const entry = self.runtimes.get(handle) orelse
                process_seal.fatalIntegrity(.proof_loss);
            client_idle_pump_evidence.recordSelectedOwner();
            RemoteRuntime.backend_api.storeFrameSummary(
                entry.runtime,
                if (builtin.is_test and B5TestState.event_pump_hook != null)
                    B5TestState.event_pump_hook.?(handle, entry.runtime)
                else
                    drainRemoteNow(entry.runtime),
            );
        }
        self.event_pump_cursor = event_pump_contract.nextCursor(
            self.event_pump_cursor,
            handle_count,
            selection.round_robin_advanced,
        ) catch process_seal.fatalIntegrity(.proof_loss);
    }

    /// Process-global admission queue의 첫 sealed row를 actual stable runtime에 넘기는 유일한
    /// drain leaf다. ResidentLimit은 row를 다시 admitted로 돌려 다음 frame이 같은 요청을 재시도한다.
    pub fn drainReconnectAdmission(
        self: *RemoteTermBackend,
        admissions: *reconnect_admission_owner.Owner,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) !ReconnectDrainResult {
        var dispatch: reconnect_admission_owner.PreparedReconnectDispatch = .{};
        admissions.prepareDispatch(&dispatch) catch |err| switch (err) {
            error.NotFound => return .idle,
            else => return err,
        };
        const result = try self.bindPreparedReconnectAdmission(&dispatch, admissions, budget);
        if (result == .started) {
            const projection: reconnect_admission_owner.Projection = .{
                .slot_index = dispatch.slot_index,
                .slot_generation = dispatch.slot_generation,
                .host_id = dispatch.host_id,
                .host_adapter_generation = dispatch.host_adapter_generation,
                .connection_generation = dispatch.connection_generation,
                .incident_id = dispatch.incident_id,
            };
            admissions.consumeScheduled(projection) catch
                process_seal.fatalIntegrity(.incident_authority);
        }
        return result;
    }

    /// c3b2a variant of the existing drain suffix. The caller already owns the final-address
    /// dispatch and keeps a successful row scheduled until its c1 reservation is committed.
    pub fn bindPreparedReconnectAdmission(
        self: *RemoteTermBackend,
        dispatch: *reconnect_admission_owner.PreparedReconnectDispatch,
        admissions: *reconnect_admission_owner.Owner,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) !ReconnectDrainResult {
        var dispatch_settled = false;
        defer if (!dispatch_settled) admissions.settleDispatch(dispatch, .retry_later) catch
            process_seal.fatalIntegrity(.incident_authority);
        const projection = try admissions.preparedProjection(dispatch);
        var selected: [max_remote_backend_runtimes]*RemoteRuntime = undefined;
        var selected_count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |row| {
            if (row.value_ptr.host_id != projection.host_id) continue;
            if (row.value_ptr.host_adapter_generation != projection.host_adapter_generation or
                !RemoteRuntime.backend_api.matchesReconnectAdmission(row.value_ptr.runtime, projection))
            {
                admissions.settleDispatch(dispatch, .discarded_stale) catch
                    process_seal.fatalIntegrity(.incident_authority);
                dispatch_settled = true;
                return .discarded_stale;
            }
            selected[selected_count] = row.value_ptr.runtime;
            selected_count += 1;
        }
        if (selected_count == 0) {
            admissions.settleDispatch(dispatch, .discarded_stale) catch
                process_seal.fatalIntegrity(.incident_authority);
            dispatch_settled = true;
            return .discarded_stale;
        }
        for (selected[0..selected_count]) |runtime|
            RemoteRuntime.backend_api.preflightReconnectAdmission(runtime, projection) catch |err| switch (err) {
                error.Busy => {
                    admissions.settleDispatch(dispatch, .retry_later) catch
                        process_seal.fatalIntegrity(.incident_authority);
                    dispatch_settled = true;
                    return .retry_later;
                },
                error.StaleAdmission, error.InvalidAuthority => {
                    admissions.settleDispatch(dispatch, .discarded_stale) catch
                        process_seal.fatalIntegrity(.incident_authority);
                    dispatch_settled = true;
                    return .discarded_stale;
                },
                else => return err,
            };
        if (!try budget.canReserveBatch(selected_count, reconnect_resident_budget.max_entry_bytes)) {
            admissions.settleDispatch(dispatch, .retry_later) catch
                process_seal.fatalIntegrity(.incident_authority);
            dispatch_settled = true;
            return .retry_later;
        }
        for (selected[0..selected_count]) |runtime| {
            RemoteRuntime.backend_api.bindReconnectAdmission(
                runtime,
                budget,
                projection,
                reconnect_resident_budget.max_entry_bytes,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        admissions.settleDispatch(dispatch, .scheduled) catch
            process_seal.fatalIntegrity(.incident_authority);
        dispatch_settled = true;
        return .started;
    }

    /// Coalescing never binds a second resident lease. It is legal only while every same-host
    /// runtime still carries the first c1 snapshot's exact admission identity.
    pub fn validateBoundReconnectSnapshot(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
    ) !void {
        try self.validateReconnectCoordinatorTarget();
        var count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |row| {
            if (row.value_ptr.host_id != snapshot.host_id) continue;
            if (row.value_ptr.host_adapter_generation != snapshot.pool_membership_generation or
                !RemoteRuntime.backend_api.matchesBoundReconnectIdentity(
                    row.value_ptr.runtime,
                    snapshot.host_id,
                    snapshot.pool_membership_generation,
                    snapshot.connection_generation,
                    snapshot.incident_app_instance_nonce,
                    snapshot.incident_sequence,
                ))
                return error.StaleAdmission;
            count += 1;
        }
        if (count == 0) return error.StaleAdmission;
    }

    /// Preflight every same-host resident admission before the first lease release. This remains
    /// valid after CR5 changes the current connection generation because the stored admission and
    /// lease, rather than mutable connection state, are the terminal settlement authority.
    pub fn preflightBoundReconnectSnapshotSettlement(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) !void {
        try self.validateReconnectCoordinatorTarget();
        var count: usize = 0;
        var preflight = self.runtimes.iterator();
        while (preflight.next()) |row| {
            if (row.value_ptr.host_id != snapshot.host_id) continue;
            if (row.value_ptr.host_adapter_generation != snapshot.pool_membership_generation)
                return error.StaleAdmission;
            try RemoteRuntime.backend_api.preflightBoundReconnectSettlement(
                row.value_ptr.runtime,
                budget,
                snapshot.host_id,
                snapshot.pool_membership_generation,
                snapshot.connection_generation,
                snapshot.incident_app_instance_nonce,
                snapshot.incident_sequence,
            );
            count += 1;
        }
        if (count == 0) return error.StaleAdmission;
    }

    pub fn settleBoundReconnectSnapshotNoFail(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) void {
        var settle = self.runtimes.iterator();
        while (settle.next()) |row| {
            if (row.value_ptr.host_id != snapshot.host_id) continue;
            RemoteRuntime.backend_api.settleBoundReconnectAdmissionNoFail(row.value_ptr.runtime, budget);
        }
    }

    pub fn settleBoundReconnectSnapshot(
        self: *RemoteTermBackend,
        snapshot: reconnect_worker_owner.Snapshot,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) !void {
        try self.preflightBoundReconnectSnapshotSettlement(snapshot, budget);
        self.settleBoundReconnectSnapshotNoFail(snapshot, budget);
    }

    /// app-quit은 Runtime graph를 해제하기 전에 target host별 shared data connection을 한 번만 terminalize한다.
    /// 모든 host를 먼저 preflight하므로 한 host의 Busy가 앞 host fd만 닫는 partial suffix를 만들지 않는다.
    pub fn terminalizeSharedConnectionsNoDestroy(self: *RemoteTermBackend) bool {
        if (self.app_quit_connections_terminalized) return true;
        if (!self.app_quit_routing_tombstoned) return false;
        if (self.close_operation_owner.active) return false;
        if (builtin.is_test) B5TestState.app_quit_runtime_count_at_terminalize = self.runtimes.count();
        if (self.host_pool == null) {
            const client = self.client orelse {
                if (self.runtimes.count() != 0) return false;
                self.app_quit_connections_terminalized = true;
                return true;
            };
            if (!client.canTerminalizeSharedConnectionNoDestroy()) return false;
            if (!client.terminalizeSharedConnectionNoDestroy()) process_seal.fatalIntegrity(.proof_loss);
            self.app_quit_connections_terminalized = true;
            return true;
        }

        var host_ids: [max_remote_backend_runtimes]u128 = undefined;
        var host_count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |entry| {
            const host_id = entry.value_ptr.host_id;
            var seen = false;
            for (host_ids[0..host_count]) |existing| if (existing == host_id) {
                seen = true;
                break;
            };
            if (seen) continue;
            host_ids[host_count] = host_id;
            host_count += 1;
        }
        for (host_ids[0..host_count]) |host_id| {
            const adapter = self.host_pool.?.get(host_id) orelse process_seal.fatalIntegrity(.proof_loss);
            if (!adapter.canTerminalizeSharedConnectionNoDestroy()) return false;
        }
        for (host_ids[0..host_count]) |host_id| {
            const adapter = self.host_pool.?.get(host_id) orelse process_seal.fatalIntegrity(.proof_loss);
            if (!adapter.terminalizeSharedConnectionNoDestroy()) process_seal.fatalIntegrity(.proof_loss);
        }
        self.app_quit_connections_terminalized = true;
        return true;
    }

    /// data fd가 닫힌 뒤 각 Runtime의 이미 게시된 Pending을 정산한다. 새 event를 take하지 않으며,
    /// 하나라도 아직 Busy이면 map과 Runtime을 그대로 둬 다음 owner-thread tick이 같은 graph를 재시도하게 한다.
    pub fn settlePendingOwnersForAppQuit(self: *RemoteTermBackend) bool {
        if (self.app_quit_owner_graphs_settled) return true;
        if (!self.app_quit_connections_terminalized) return false;

        var it = self.runtimes.valueIterator();
        while (it.next()) |entry| {
            if (entry.runtime.advancePendingEventForClose() != .complete) return false;
            if (builtin.is_test) {
                if (remote_runtime.testing_api.appQuitOwnerSnapshot(entry.runtime)) |snapshot| {
                    if (snapshot.pending_idle and snapshot.owner_pristine and snapshot.correlation_pristine and
                        snapshot.event_generation_mirror == 0)
                        B5TestState.app_quit_pending_idle_count += 1;
                } else |_| {}
            }
        }
        if (builtin.is_test) B5TestState.app_quit_runtime_count_at_owner_settlement = self.runtimes.count();
        self.app_quit_owner_graphs_settled = true;
        return true;
    }

    /// 첫 app-quit routing tombstone이 current와 previous target 모두가 공유할 절대 deadline을 한 번만 만든다.
    /// 후속 창 teardown은 같은 값을 재사용하며 target별 clock 재시작을 허용하지 않는다.
    pub fn beginAppQuitShutdown(self: *RemoteTermBackend, now_ns: i128) bool {
        if (self.app_quit_shutdown_deadline_ns != 0)
            return self.app_quit_shutdown_started_at_ns != 0;
        if (self.app_quit_routing_tombstoned or self.host_reconnect_preparing or
            self.host_reconnect_job != null or now_ns <= 0 or now_ns > std.math.maxInt(u64)) return false;
        const started_at_ns: u64 = @intCast(now_ns);
        const deadline_ns = std.math.add(u64, started_at_ns, 15 * std.time.ns_per_s) catch
            process_seal.fatalIntegrity(.proof_loss);
        self.app_quit_shutdown_started_at_ns = started_at_ns;
        self.app_quit_shutdown_deadline_ns = deadline_ns;
        return true;
    }

    /// shutdown connector와 target attempt authority는 이 값만 소비한다. target별 상대 timeout 계산은 금지한다.
    pub fn appQuitShutdownDeadline(self: *const RemoteTermBackend) ?u64 {
        return if (self.app_quit_shutdown_started_at_ns != 0 and self.app_quit_shutdown_deadline_ns != 0)
            self.app_quit_shutdown_deadline_ns
        else
            null;
    }

    /// end-all 확인은 모든 target을 먼저 검증한 뒤 close ticket, routing tombstone, shutdown authority를
    /// allocation/callback 없는 한 suffix에서 함께 게시한다. 반환한 개수가 AppSession cursor의 닫힌 범위다.
    pub fn prepareAppQuitEndAll(self: *RemoteTermBackend, now_ns: i128) !u32 {
        if (self.app_quit_target_count != 0 or self.app_quit_first_ticket != 0)
            return self.app_quit_target_count;
        if (!self.beginAppQuitShutdown(now_ns)) return error.InvalidAppQuitShutdown;
        if (self.runtimes.count() == 0) return 0;

        var handles: [max_remote_backend_runtimes]RuntimeHandle = undefined;
        var target_digests: [max_remote_backend_runtimes]process_seal.CleanupSeal = undefined;
        var count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |row| {
            const runtime = row.value_ptr.runtime;
            if (!std.meta.eql(runtime.shutdown_attempt_authority, shutdown_attempt.ShutdownAttemptAuthority{}) or
                runtime.close_authority.lifecycle_raw != @intFromEnum(close_authority.Lifecycle.pristine))
                return error.InvalidAppQuitShutdown;
            handles[count] = row.key_ptr.*;
            target_digests[count] = appQuitTargetDigest(row.key_ptr.*, row.value_ptr.*);
            count += 1;
        }
        std.mem.sort(RuntimeHandle, handles[0..count], {}, std.sort.asc(RuntimeHandle));
        // 정렬 뒤 digest도 같은 target 순서로 다시 계산한다. HashMap 순서는 shutdown ordinal의 권위가 아니다.
        for (handles[0..count], 0..) |handle, index| {
            const row = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.proof_loss);
            target_digests[index] = appQuitTargetDigest(handle, row);
        }

        var reservation: WindowCloseTicketReservation = .{};
        try self.reserveWindowCloseTickets(handles[0..count], &reservation);
        const first_ticket = reservation.first_ticket;
        self.publishWindowCloseAuthoritiesNoFail(handles[0..count], &reservation);
        for (handles[0..count], 0..) |handle, index| {
            const row = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.proof_loss);
            shutdown_attempt.prepare(
                &row.runtime.shutdown_attempt_authority,
                first_ticket + @as(u64, @intCast(index)),
                target_digests[index],
                .terminate_host,
                self.app_quit_shutdown_deadline_ns,
            ) catch process_seal.fatalIntegrity(.proof_loss);
        }
        self.app_quit_first_ticket = first_ticket;
        self.app_quit_target_count = @intCast(count);
        return self.app_quit_target_count;
    }

    fn appQuitTargetDigest(handle: RuntimeHandle, row: RuntimeEntry) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("maru.app-quit.target.v1");
        var scalar: [8]u8 = undefined;
        std.mem.writeInt(u64, &scalar, handle, .little);
        hasher.update(&scalar);
        std.mem.writeInt(u64, &scalar, row.runtime_generation, .little);
        hasher.update(&scalar);
        var host: [16]u8 = undefined;
        std.mem.writeInt(u128, &host, row.host_id, .little);
        hasher.update(&host);
        hasher.update(&row.runtime.appQuitRuntimeId());
        if (row.runtime.appQuitShutdownManifest()) |manifest| {
            std.mem.writeInt(u128, &host, manifest.host_id, .little);
            hasher.update(&host);
            std.mem.writeInt(u64, &scalar, manifest.upgrade_epoch, .little);
            hasher.update(&scalar);
            std.mem.writeInt(u64, &scalar, manifest.protocol_major, .little);
            hasher.update(&scalar);
            std.mem.writeInt(u64, &scalar, manifest.screen_codec_version, .little);
            hasher.update(&scalar);
            hasher.update(&.{@intFromEnum(manifest.lifecycle)});
            std.mem.writeInt(u64, &scalar, manifest.build_id.len, .little);
            hasher.update(&scalar);
            hasher.update(manifest.build_id);
            std.mem.writeInt(u64, &scalar, manifest.endpoint.len, .little);
            hasher.update(&scalar);
            hasher.update(manifest.endpoint);
        } else {
            hasher.update("manifest-unavailable");
        }
        return hasher.finalResult();
    }

    /// frame tick 하나는 현재 ordinal의 admin 상태를 한 단계만 진행한다. confirmed/bounded terminal 뒤에도
    /// Pending owner가 source-zero가 될 때까지 같은 ordinal을 유지해 AppSession graph가 먼저 파괴되지 않게 한다.
    pub fn advanceAppQuitEndAllTarget(self: *RemoteTermBackend, ordinal: u32, now_ns: u64) bool {
        if (self.app_quit_target_count == 0 or ordinal >= self.app_quit_target_count or
            self.app_quit_first_ticket == 0 or self.app_quit_shutdown_deadline_ns == 0)
            process_seal.fatalIntegrity(.proof_loss);
        const ticket = self.app_quit_first_ticket + ordinal;
        const row = self.appQuitRowForTicket(ticket) orelse process_seal.fatalIntegrity(.proof_loss);
        const authority = &row.runtime.shutdown_attempt_authority;
        if (!shutdown_attempt.valid(authority) or authority.close_request_generation != ticket)
            process_seal.fatalIntegrity(.proof_loss);

        if (authority.lifecycle_raw != @intFromEnum(shutdown_attempt.Lifecycle.terminal)) {
            if (now_ns >= self.app_quit_shutdown_deadline_ns) {
                shutdown_attempt.publishOutcome(authority, shutdown_attempt.key(authority), shutdownOutcomeDigest(authority, 1)) catch
                    process_seal.fatalIntegrity(.proof_loss);
            } else if (row.runtime.appQuitShutdownManifest()) |manifest| {
                if (manifest.protocol_major == protocol.version_major) {
                    self.advanceCurrentShutdownTarget(row.runtime, manifest, now_ns);
                } else if (shutdown_connector.exactPreviousManifestEligible(manifest)) {
                    self.advancePreviousShutdownTarget(row.runtime, manifest, now_ns);
                } else {
                    shutdown_attempt.publishOutcome(authority, shutdown_attempt.key(authority), shutdownOutcomeDigest(authority, 2)) catch
                        process_seal.fatalIntegrity(.proof_loss);
                }
            } else {
                shutdown_attempt.publishOutcome(authority, shutdown_attempt.key(authority), shutdownOutcomeDigest(authority, 3)) catch
                    process_seal.fatalIntegrity(.proof_loss);
            }
        }
        if (authority.lifecycle_raw != @intFromEnum(shutdown_attempt.Lifecycle.terminal)) return false;

        const close_owner = &row.runtime.close_authority;
        if (close_owner.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.routing_tombstoned))
            close_authority.advance(close_owner, .routing_tombstoned, .settling) catch
                process_seal.fatalIntegrity(.proof_loss);
        if (close_owner.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.settling)) {
            const readiness = row.runtime.advancePendingEventForClose();
            const ready = close_authority.publishReadyRemove(close_owner, readiness == .complete) catch
                process_seal.fatalIntegrity(.proof_loss);
            if (!ready) return false;
        }
        return close_owner.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.ready_remove);
    }

    fn advanceCurrentShutdownTarget(
        self: *RemoteTermBackend,
        runtime: *RemoteRuntime,
        manifest: @import("host_manifest.zig").Descriptor,
        now_ns: u64,
    ) void {
        const authority = &runtime.shutdown_attempt_authority;
        const coordinator = &runtime.shutdown_current_admin;
        const deadline = client_deadline.AbsoluteDeadline.fromInjected(.{
            .context = self,
            .now_ns = appQuitClockNow,
        }, self.app_quit_shutdown_deadline_ns);
        switch (coordinator.phase) {
            .ready => {
                var admin = switch (shutdown_connector.connectExactCurrentUntil(self.allocator, manifest, deadline)) {
                    .connected => |client| client,
                    .unavailable => return,
                };
                defer admin.deinit();
                var params_buf: [64]u8 = undefined;
                const runtime_id = runtime.appQuitRuntimeId();
                const params = std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&runtime_id}) catch
                    process_seal.fatalIntegrity(.proof_loss);
                var storage: client_mod.PreparedBlockingRpcStorage = .{};
                _ = admin.prepareBlockingRpcStorage(&storage, "runtime.terminate", params) catch return;
                var receipt: maru.app.shutdown_wire_contract.ShutdownConnectionReceipt = .{};
                coordinator.beginTerminate(authority, &receipt, now_ns, self.issueShutdownConnectionIdentity()) catch return;
                switch (admin.executePreparedBlockingRpcStorageUntil(&storage, self.allocator, deadline)) {
                    .accepted => |accepted| {
                        defer accepted.payload_allocator.free(accepted.payload);
                        if (std.mem.indexOf(u8, accepted.payload, "\"terminated\":true") != null)
                            coordinator.terminateConfirmed(authority, &receipt) catch
                                process_seal.fatalIntegrity(.proof_loss)
                        else
                            coordinator.terminateAmbiguous(authority, &receipt) catch
                                process_seal.fatalIntegrity(.proof_loss);
                    },
                    .not_executed => {
                        admin.abortPreparedBlockingRpcStorage(&storage) catch {};
                        coordinator.terminateNotExecuted(authority, &receipt) catch
                            process_seal.fatalIntegrity(.proof_loss);
                    },
                    .uncertain => coordinator.terminateAmbiguous(authority, &receipt) catch
                        process_seal.fatalIntegrity(.proof_loss),
                }
            },
            .awaiting_barrier => {
                var admin = switch (shutdown_connector.connectExactCurrentUntil(self.allocator, manifest, deadline)) {
                    .connected => |client| client,
                    .unavailable => return,
                };
                defer admin.deinit();
                var receipt: maru.app.shutdown_wire_contract.ShutdownConnectionReceipt = .{};
                coordinator.beginInventory(authority, &receipt, now_ns, self.issueShutdownConnectionIdentity(), true) catch return;
                switch (admin.runtimeInventoryUntil(deadline)) {
                    .inventory => |inventory_value| switch (inventory_value) {
                        .unavailable => coordinator.inventoryInvalid(authority, &receipt) catch
                            process_seal.fatalIntegrity(.proof_loss),
                        .complete => |complete_value| {
                            var complete = complete_value;
                            defer complete.deinit(self.allocator);
                            const runtime_id = runtime.appQuitRuntimeId();
                            const runtime_value = std.fmt.parseInt(u128, &runtime_id, 16) catch
                                process_seal.fatalIntegrity(.proof_loss);
                            var membership: shutdown_current_admin.Membership = .absent;
                            for (complete.runtime_ids) |candidate| if (candidate == runtime_value) {
                                membership = .present;
                                break;
                            };
                            coordinator.inventoryConfirmed(authority, &receipt, membership) catch
                                process_seal.fatalIntegrity(.proof_loss);
                        },
                    },
                    .not_executed => coordinator.inventoryInvalid(authority, &receipt) catch
                        process_seal.fatalIntegrity(.proof_loss),
                    .uncertain => {
                        _ = coordinator.inventoryAmbiguous(authority, &receipt) catch
                            process_seal.fatalIntegrity(.proof_loss);
                    },
                }
            },
            .terminate_live, .inventory_live => process_seal.fatalIntegrity(.proof_loss),
            .terminal => {},
        }
    }

    fn advancePreviousShutdownTarget(
        self: *RemoteTermBackend,
        runtime: *RemoteRuntime,
        manifest: @import("host_manifest.zig").Descriptor,
        now_ns: u64,
    ) void {
        const deadline = client_deadline.AbsoluteDeadline.fromInjected(.{
            .context = self,
            .now_ns = appQuitClockNow,
        }, self.app_quit_shutdown_deadline_ns);
        const runtime_id = runtime.appQuitRuntimeId();
        _ = shutdown_connector.terminateExactPreviousUntil(
            self.allocator,
            &runtime.shutdown_attempt_authority,
            manifest,
            &runtime_id,
            now_ns,
            self.issueShutdownConnectionIdentity(),
            deadline,
        );
    }

    fn appQuitRowForTicket(self: *RemoteTermBackend, ticket: u64) ?*RuntimeEntry {
        var iterator = self.runtimes.valueIterator();
        while (iterator.next()) |row| if (row.runtime.close_authority.close_schedule_ticket == ticket) return row;
        return null;
    }

    fn issueShutdownConnectionIdentity(self: *RemoteTermBackend) u64 {
        self.next_shutdown_connection_identity = std.math.add(u64, self.next_shutdown_connection_identity, 1) catch
            process_seal.fatalIntegrity(.proof_loss);
        if (self.next_shutdown_connection_identity == 0) process_seal.fatalIntegrity(.proof_loss);
        return self.next_shutdown_connection_identity;
    }

    fn appQuitClockNow(context: *anyopaque) i128 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(context));
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    fn shutdownOutcomeDigest(authority: *const shutdown_attempt.ShutdownAttemptAuthority, reason: u8) process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("maru.app-quit.shutdown-outcome.v1");
        hasher.update(&authority.target_digest);
        hasher.update(&.{reason});
        return hasher.finalResult();
    }

    /// detach-preserve app quit은 어느 Runtime도 free하기 전에 모든 GUI routing을 먼저 끊는다.
    pub fn tombstoneAllRoutingForAppQuit(self: *RemoteTermBackend) bool {
        if (self.app_quit_routing_tombstoned) return true;
        if (self.app_quit_shutdown_deadline_ns == 0 or self.close_operation_owner.active or
            self.app_quit_connections_terminalized) return false;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |entry| {
            const handle = entry.key_ptr.*;
            const runtime = entry.value_ptr.runtime;
            if (!self.surface_runtime.linkMatches(handle, &runtime.surface, handle, runtime)) return false;
        }
        iterator = self.runtimes.iterator();
        while (iterator.next()) |entry| self.surface_runtime.detachSurface(entry.key_ptr.*);
        if (builtin.is_test) B5TestState.app_quit_routing_target_count = self.runtimes.count();
        self.app_quit_routing_tombstoned = true;
        return true;
    }

    pub const testing_api = if (builtin.is_test) struct {
        pub const EvidenceAdapterPool = AdapterPool;

        pub fn evidenceAddOwnedClient(
            pool: *EvidenceAdapterPool,
            allocator: std.mem.Allocator,
            source: *client_mod.Client,
        ) !u128 {
            return addOwnedClient(pool, allocator, source);
        }

        pub fn runtimeUsesGenerationAttachment(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
        ) bool {
            const entry = remote_backend.runtimes.get(handle) orelse return false;
            return entry.runtime.usesGenerationAttachment();
        }

        pub fn cr5d2WindowSurface(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
        ) ?*Surface {
            const entry = remote_backend.runtimes.get(handle) orelse return null;
            return &entry.runtime.surface;
        }

        pub fn cr5d2WindowRuntime(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
        ) ?*RemoteRuntime {
            return (remote_backend.runtimes.get(handle) orelse return null).runtime;
        }

        pub fn cr5d2SetWindowSurfaceId(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
            surface_id: u64,
        ) !void {
            if (surface_id == 0) return error.InvalidTestState;
            const entry = remote_backend.runtimes.get(handle) orelse return error.InvalidTestState;
            entry.runtime.surface.id = surface_id;
        }

        pub fn cr5d2MakeTerminationUnconfirmed(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
        ) !void {
            const job = remote_backend.host_reconnect_job orelse return error.InvalidTestState;
            const rows = job.runtimeRowsSlice() orelse return error.InvalidTestState;
            const row = for (rows) |candidate| {
                if (candidate.identity.runtime_handle == handle) break candidate;
            } else return error.InvalidTestState;
            var target = try remote_backend.closeTransitionTarget(handle, .{
                .tag_raw = @intFromEnum(remote_runtime.CloseEventTag.termination_requested),
                .intent_generation = 1,
                .shell_generation = row.identity.shell_generation,
                .deadline_ns = 100,
            });
            try remote_backend.applyCloseTransitionTarget(target);
            target = try remote_backend.closeTransitionTarget(handle, .{
                .tag_raw = @intFromEnum(remote_runtime.CloseEventTag.termination_timed_out),
                .now_ns = 100,
            });
            try remote_backend.applyCloseTransitionTarget(target);
        }

        pub fn runCr5d2WindowFixture(
            hook: *const fn (*RemoteTermBackend) anyerror!void,
        ) !void {
            if (B5TestState.cr5d2_window_hook != null) return error.InvalidTestState;
            B5TestState.cr5d2_window_hook = hook;
            defer B5TestState.cr5d2_window_hook = null;
            try runCr4aActualIssuerReplacementStage(.multi_runtime_terminal_after_success);
        }

        pub const ActualReconnectFixture = ActualReconnectFixtureData;

        /// CR6e-c3b2b actual-daemon fixture. The caller drives the coordinator while this helper
        /// retains the daemon, pool, backend, and live runtime at their product addresses.
        pub fn runActualReconnectCoordinatorFixture(
            hook: *const fn (*RemoteTermBackend, ActualReconnectFixture) anyerror!void,
        ) !void {
            if (B5TestState.reconnect_coordinator_hook != null) return error.InvalidTestState;
            B5TestState.reconnect_coordinator_hook = hook;
            defer B5TestState.reconnect_coordinator_hook = null;
            try runCr4aActualIssuerReplacementStage(.coordinator_success);
        }

        /// CR2d3 AppSession routing fixture. `runtime`은 caller 소유이며 두 값이 scope를 벗어나기 전에
        /// 반드시 remove해야 한다. 제품 runtime admission은 이 test-only 경로를 보지 않는다.
        pub fn installEventCursorRuntime(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
            runtime: *RemoteRuntime,
        ) !void {
            if (handle == 0 or remote_backend.runtimes.contains(handle)) return error.InvalidTestState;
            try remote_backend.runtimes.put(remote_backend.allocator, handle, .{
                .runtime = runtime,
                .host_id = 1,
                .runtime_generation = 1,
            });
        }

        pub fn installReconnectRuntime(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
            runtime: *RemoteRuntime,
            runtime_generation: u64,
            host_adapter_generation: u64,
        ) !void {
            if (handle == 0 or runtime_generation == 0 or host_adapter_generation == 0 or
                remote_backend.runtimes.contains(handle))
                return error.InvalidTestState;
            try remote_backend.runtimes.put(remote_backend.allocator, handle, .{
                .runtime = runtime,
                .host_id = 1,
                .host_adapter_generation = host_adapter_generation,
                .runtime_generation = runtime_generation,
            });
        }

        pub fn initReconnectCoordinatorBackend(
            out: *RemoteTermBackend,
            allocator: std.mem.Allocator,
        ) !void {
            out.* = b5TestBackend(allocator);
            try out.claimProductSingleton();
        }

        pub fn removeEventCursorRuntime(remote_backend: *RemoteTermBackend, handle: RuntimeHandle) bool {
            return remote_backend.runtimes.remove(handle);
        }

        pub const SettlementBlocker = enum {
            runtime,
            reservation,
            close_operation,
            close_sweep,
        };

        /// AppHost settlement의 closed preflight 네 항을 제품 필드에서 각각 실행한다. 테스트가 끝나기 전
        /// `clearProcessSettlementBlocker`로 원복해야 일반 deinit의 proof-loss guard를 건드리지 않는다.
        pub fn setProcessSettlementBlocker(remote_backend: *RemoteTermBackend, blocker: SettlementBlocker) !void {
            if (remote_backend.runtimes.count() != 0 or remote_backend.reserved_runtime_count != 0 or
                remote_backend.close_operation_owner.active or remote_backend.close_sweep != .inactive)
                return error.InvalidTestState;
            switch (blocker) {
                .runtime => try remote_backend.runtimes.put(remote_backend.allocator, 1, .{
                    .runtime = @ptrFromInt(@alignOf(RemoteRuntime)),
                    .host_id = 1,
                    .runtime_generation = 1,
                }),
                .reservation => remote_backend.reserved_runtime_count = 1,
                .close_operation => remote_backend.close_operation_owner.active = true,
                .close_sweep => remote_backend.close_sweep = .{ .active = .{ .max_ticket = 1, .cursor_after_ticket = 0 } },
            }
        }

        pub fn clearProcessSettlementBlocker(remote_backend: *RemoteTermBackend, blocker: SettlementBlocker) void {
            switch (blocker) {
                .runtime => _ = remote_backend.runtimes.remove(1),
                .reservation => remote_backend.reserved_runtime_count = 0,
                .close_operation => remote_backend.close_operation_owner = .{},
                .close_sweep => remote_backend.close_sweep = .inactive,
            }
        }

        pub const AppQuitSnapshot = struct {
            routing_tombstoned: bool,
            connections_terminalized: bool,
            routing_target_count: usize,
            runtime_count_at_terminalize: usize,
            runtime_count_at_owner_settlement: usize,
            owner_graphs_settled: bool,
            pending_idle_count: usize,
            source_zero_count: usize,
            remaining_runtime_count: usize,
            shutdown_started_at_ns: u64,
            shutdown_deadline_ns: u64,
        };

        pub fn appQuitSnapshot(remote_backend: *const RemoteTermBackend) AppQuitSnapshot {
            return .{
                .routing_tombstoned = remote_backend.app_quit_routing_tombstoned,
                .connections_terminalized = remote_backend.app_quit_connections_terminalized,
                .routing_target_count = B5TestState.app_quit_routing_target_count,
                .runtime_count_at_terminalize = B5TestState.app_quit_runtime_count_at_terminalize,
                .runtime_count_at_owner_settlement = B5TestState.app_quit_runtime_count_at_owner_settlement,
                .owner_graphs_settled = remote_backend.app_quit_owner_graphs_settled,
                .pending_idle_count = B5TestState.app_quit_pending_idle_count,
                .source_zero_count = B5TestState.app_quit_source_zero_count,
                .remaining_runtime_count = remote_backend.runtimes.count(),
                .shutdown_started_at_ns = remote_backend.app_quit_shutdown_started_at_ns,
                .shutdown_deadline_ns = remote_backend.app_quit_shutdown_deadline_ns,
            };
        }

        pub fn appQuitTargetDeadline(remote_backend: *const RemoteTermBackend, kind: host_adapter_mod.Kind) ?u64 {
            _ = kind;
            if (remote_backend.app_quit_shutdown_started_at_ns == 0 or remote_backend.app_quit_shutdown_deadline_ns == 0)
                return null;
            return remote_backend.app_quit_shutdown_deadline_ns;
        }

        pub fn resetAppQuitSnapshot() void {
            B5TestState.app_quit_routing_target_count = 0;
            B5TestState.app_quit_runtime_count_at_terminalize = 0;
            B5TestState.app_quit_runtime_count_at_owner_settlement = 0;
            B5TestState.app_quit_pending_idle_count = 0;
            B5TestState.app_quit_source_zero_count = 0;
        }

        pub fn preparePendingOwnerForAppQuit(
            remote_backend: *RemoteTermBackend,
            handle: RuntimeHandle,
            payload: []const u8,
        ) !void {
            const entry = remote_backend.runtimes.get(handle) orelse return error.InvalidHandle;
            try remote_runtime.testing_api.preparePendingEventForClose(entry.runtime, payload);
        }
    } else struct {};

    /// **이미 host에 있는 runtime에 재접속**해 원격-backed Surface를 만든다(§7 GUI 재접속, e3-5). spawn과 달리 새 runtime을
    /// 안 띄우고 저장된 `runtime_id_hex`에 붙는다. runtime이 없으면(host 재시작 등) attachExisting이 error를 내고
    /// app_session restore는 동일 세션인 척 fresh spawn하지 않고 fail-closed한다. **vtable 밖 — host 전용**이라
    /// app_session이 restore 경로에서 직접 부른다. spawn과 동일하게 반환 뒤 `attach`(vtable)로 원격 PtyIo를
    /// 라우팅 표에 등록해야 입력이 흐른다.
    pub fn attachTerm(self: *RemoteTermBackend, handle: RuntimeHandle, runtime_id_hex: [32]u8, size: maru.terminal.Size) anyerror!*Surface {
        const host_id = if (self.host_pool) |pool|
            pool.spawnHostId() orelse return error.SpawnHostUnavailable
        else
            (self.client orelse return error.HostNotFound).host_id;
        return self.attachTermOnHost(host_id, handle, runtime_id_hex, size);
    }

    pub fn attachTermOnHost(
        self: *RemoteTermBackend,
        host_id: u128,
        handle: RuntimeHandle,
        runtime_id_hex: [32]u8,
        size: maru.terminal.Size,
    ) anyerror!*Surface {
        if (self.runtimes.contains(handle)) return error.RuntimeAlreadyRegistered;
        var admission: RuntimeAdmissionReservation = .{};
        try self.reserveRuntimeAdmission(&admission);
        errdefer self.abortRuntimeAdmission(&admission);
        var retained = false;
        errdefer if (retained) self.host_pool.?.release(host_id);
        var selected_adapter: ?*HostAdapter = null;
        const selected_client = if (self.host_pool) |pool| blk: {
            const adapter = try pool.retain(host_id);
            retained = true;
            if (adapter.hostId() != host_id) return error.HostIdentityMismatch;
            selected_adapter = adapter;
            break :blk null;
        } else if ((self.client orelse return error.HostNotFound).host_id == host_id)
            self.client.?
        else
            return error.HostNotFound;
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        if (selected_adapter) |adapter|
            try rr.attachExistingWithAdapter(adapter, self.allocator, self.io, handle, runtime_id_hex, size)
        else
            try rr.attachExisting(selected_client.?, self.allocator, self.io, handle, runtime_id_hex, size);
        // 재접속은 **기존** host runtime이라 이후 단계(map put)가 실패해도 terminate 금지(§7 attach는 terminate 안 함) —
        // client-side(surface/screen)만 회수한다. spawn 경로는 방금 우리가 띄운 runtime이라 deinit(terminate)이 맞지만
        // attach는 남의 runtime이므로 detachClientSide로 되돌려야 재접속 실패가 세션을 죽이지 않는다.
        errdefer rr.detachClientSide();
        // attach 대상은 이전 GUI가 남긴 snapshot을 갖고 있을 수 있다. 현재 앱의 complete snapshot을 map publication 전에
        // 확인해야 복원 직후 GUI 0으로 돌아가도 stale 알림 정책으로 동작하지 않는다. 실제 binding label은 AppSession이
        // Term을 layout에 결속한 직후 configureNotificationBinding으로 덮고, 이 단계는 안전한 runtime-ID fallback이다.
        // 이 호출의 실패는 **attach 를 막을 이유가 아니다.** 위 주석대로 여기서 넣는 label 은 안전한
        // runtime-ID fallback 이고 실제 값은 곧 binding 단계가 덮는다. 반면 여기서 error 를 올리면 창
        // 복원이 통째로 버려진다 — 복원은 탭을 전부 빌드한 뒤 swap 하므로 surface 하나가 실패하면 그
        // 창의 나머지도 함께 정리된다.
        //
        // 2026-08-30 실측: 재접속 복원에서 host 가 `invalid_generation` 으로 2 건을 거절했고, 그것만으로
        // 창 두 개(탭 10 개·surface 22 개)가 전부 열리지 않았다. 이어서 종료 시 그 부분 상태가 workspace
        // checkpoint 를 덮어써 배치까지 잃었다. controller_generation 은 attach 로 오르고 rollback/revoke 로
        // 내려가므로 왕복 중 어긋나는 것은 CAS 실패와 같은 정상 경합이고, 재시도해도 로컬 값이 갱신되지
        // 않아 수렴하지 않는다. 그래서 「거절되면 label 만 포기한다」가 맞는 처리다.
        rr.updateNotificationConfig(self.notification_config_generation, self.notifications_osc, "") catch |err| {
            if (err == error.OutOfMemory) return err;
            std.log.warn("attach kept despite notification config fallback failure: error={s}", .{@errorName(err)});
        };
        try self.runtimes.put(self.allocator, handle, .{
            .runtime = rr,
            .host_id = host_id,
            .host_adapter_generation = if (self.host_pool) |pool|
                pool.adapterGeneration(host_id) orelse return error.HostIdentityMismatch
            else
                0,
            .runtime_generation = try self.issueRuntimeGeneration(),
            .notification_config_applied_generation = self.notification_config_generation,
        });
        self.consumeRuntimeAdmission(&admission);
        return &rr.surface;
    }

    /// handle의 host runtime_id(hex)를 돌려준다 — workspace capture가 저장해 재실행 시 `attachTerm`으로 재접속한다(§7, e3-5).
    /// 없으면(원격 아님·미등록) null.
    pub fn runtimeIdFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?[32]u8 {
        const entry = self.runtimes.get(handle) orelse return null;
        return entry.runtime.runtimeIdHex();
    }

    pub fn runtimeHostId(self: *RemoteTermBackend, handle: RuntimeHandle) ?u128 {
        const entry = self.runtimes.get(handle) orelse return null;
        return entry.host_id;
    }

    /// Captures the immutable routing identity before a user action admits an async observation
    /// request. Completion must compare the whole tuple again; a recycled handle or same runtime
    /// ID on a newer backend generation is not the original drop target.
    pub fn userActionProbeIdentity(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        surface_id: u64,
    ) ?user_action_queue.TargetIdentity {
        const entry = self.runtimes.get(handle) orelse return null;
        if (surface_id == 0 or entry.host_id == 0 or entry.runtime_generation == 0) return null;
        return .{
            .surface_id = surface_id,
            .runtime_handle = handle,
            .host_id = entry.host_id,
            .runtime_id = entry.runtime.runtimeIdHex(),
            .runtime_generation = entry.runtime_generation,
        };
    }

    pub const ObservationProbeAdmission = RemoteRuntime.ObservationProbeAdmission;
    pub const ObservationProbePoll = RemoteRuntime.ObservationProbePoll;

    /// Starts a response-free freshness barrier on the runtime's existing managed connection.
    /// AppSession owns the action payload and deadline; this facade owns only exact handle routing.
    pub fn requestUserActionObservationProbe(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        nonce: u64,
    ) !ObservationProbeAdmission {
        const entry = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return entry.runtime.requestObservationProbe(nonce);
    }

    /// Polls one exact correlation without blocking or consuming a different action's result.
    pub fn pollUserActionObservationProbe(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        nonce: u64,
    ) ObservationProbePoll {
        const entry = self.runtimes.get(handle) orelse return .stale;
        return entry.runtime.pollObservationProbe(nonce);
    }

    pub fn abandonUserActionObservationProbe(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        nonce: u64,
    ) bool {
        const entry = self.runtimes.get(handle) orelse return false;
        return entry.runtime.abandonObservationProbe(nonce);
    }

    /// 이 handle이 controller를 못 얻고 observer로 붙었는가(§9 — 두 번째 controller는 조용히 강등된다).
    /// host-backed가 아니면 false다. GUI가 "화면은 나오는데 입력이 안 된다"를 사용자에게 설명하는 근거다.
    pub fn attachedAsObserver(self: *RemoteTermBackend, handle: RuntimeHandle) bool {
        const entry = self.runtimes.get(handle) orelse return false;
        return entry.runtime.attachedAsObserver();
    }

    pub fn currentAttachmentLive(self: *RemoteTermBackend, handle: RuntimeHandle) bool {
        const entry = self.runtimes.get(handle) orelse return false;
        return entry.runtime.currentAttachmentLive();
    }

    /// host-backed Term(handle)의 대기 OSC 9/777 데스크톱 알림을 host에서 pull한다(§6.32 GUI surfacing). 없거나 연결 오류면
    /// null(**best-effort** — 알림은 부가 기능이라 오류를 세션에 전파하지 않는다). 반환 `Notification.title/body`는 이 backend의
    /// allocator 소유(caller가 `deinit`). host core가 파싱한 알림(placeholder client core엔 없음)을 app_session 알림 경로에 잇는다.
    pub fn takeNotificationFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?remote_runtime.Notification {
        const entry = self.runtimes.get(handle) orelse return null;
        return entry.runtime.takeNotification() catch return null;
    }

    /// host-backed Term(handle)의 현재 뷰포트 선택 텍스트를 host에서 뽑는다(§6b — host의 `extractSelection` 재사용). 없거나
    /// 연결 오류면 null(best-effort — 복사는 부가라 세션에 전파 않음). caller가 free. 선택 span은 placeholder core가 렌더용으로
    /// 든 것을 app_session이 넘긴다(하이라이트=client 좌표, 복사 콘텐츠=host 해석).
    pub fn selectedTextFor(self: *RemoteTermBackend, handle: RuntimeHandle, span: ?maru.terminal.SelectionSpan) ?[]u8 {
        const entry = self.runtimes.get(handle) orelse return null;
        return (entry.runtime.selectedTextCurrent(span) catch return null) orelse null;
    }

    /// host-backed Term(handle)의 (row,col)에 있는 링크를 host가 추출·검증해 돌려준다(원격 Cmd+클릭 열기).
    /// 없거나 연결 오류/구 host면 null(best-effort — 링크 열기가 실패해도 세션에 전파하지 않는다). caller가 `.text`를 free.
    /// 열 대상 판정(soft-wrap 이음·cwd resolve·존재 stat)은 콘텐츠와 FS를 가진 host가 SSOT다.
    pub fn linkAtFor(self: *RemoteTermBackend, handle: RuntimeHandle, row: u16, col: u16, scopes: u8) ?remote_runtime.RemoteRuntime.RemoteLink {
        const entry = self.runtimes.get(handle) orelse return null;
        return (entry.runtime.linkAt(row, col, scopes) catch return null) orelse null;
    }

    /// host-backed Term(handle)의 대기 중 OSC 52 write 텍스트를 host에서 가져온다(없거나 구 host면 null).
    /// caller가 free. 정책 판정과 실제 NSPasteboard 쓰기는 client(app_session/Swift)가 한다.
    /// **삼킨 오류를 남긴다.** 이 `catch return null` 이 2026-08-29 에 OSC 52 가 host-backed 에서만
    /// 조용히 죽는 결함을 진단 불가로 만들었다 — 퀵 터미널(in-process)은 되는데 일반 탭은 안 되고,
    /// 로그가 한 줄도 없어 코드만 읽어서는 어느 관문이 막았는지 가릴 수 없었다. best-effort 동작은
    /// 그대로 두고(실패가 세션에 전파되지 않는다) 사실만 기록한다.
    var last_clipboard_error: []const u8 = "";
    pub fn clipboardWriteFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?remote_runtime.RemoteRuntime.ClipboardWrite {
        const entry = self.runtimes.get(handle) orelse return null;
        return (entry.runtime.clipboardWrite() catch |err| {
            // 같은 오류가 tick 마다 쌓이지 않게 종류가 바뀔 때만 찍는다.
            const name = @errorName(err);
            if (!builtin.is_test and !std.mem.eql(u8, last_clipboard_error, name)) {
                last_clipboard_error = name;
                std.log.warn("host clipboard write fetch failed: error={s}", .{name});
            }
            return null;
        }) orelse null;
    }

    pub fn takeBellFor(self: *RemoteTermBackend, handle: RuntimeHandle) bool {
        const entry = self.runtimes.get(handle) orelse return false;
        return entry.runtime.takeBellEvent();
    }

    pub fn takeClipboardReadFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?[]u8 {
        const entry = self.runtimes.get(handle) orelse return null;
        return entry.runtime.takeClipboardReadTarget(self.allocator) catch null;
    }

    /// host-backed Term(handle)에서 검색어 매치를 host가 찾게 하고(§6c — `findMatches` 재사용) 보이는 매치 뷰포트 span을
    /// `out_spans`에 채운다. 전체 매치 수를 돌려준다. 없거나 오류면 null(best-effort). 검색 의미론은 host core 단일 출처.
    pub fn findFor(self: *RemoteTermBackend, handle: RuntimeHandle, query: []const u8, cur_index: u32, scroll: bool, out_spans: *std.ArrayList(maru.terminal.SelectionSpan)) ?remote_runtime.RemoteRuntime.FindResult {
        const entry = self.runtimes.get(handle) orelse return null;
        return entry.runtime.find(query, cur_index, scroll, out_spans) catch null;
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*Surface {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.mode == .attach_only) return error.SpawnHostUnavailable;
        if (self.runtimes.contains(params.handle)) return error.RuntimeAlreadyRegistered;
        var admission: RuntimeAdmissionReservation = .{};
        try self.reserveRuntimeAdmission(&admission);
        errdefer self.abortRuntimeAdmission(&admission);
        var selected_host_id: u128 = 0;
        var retained = false;
        errdefer if (retained) self.host_pool.?.release(selected_host_id);
        var selected_adapter: ?*HostAdapter = null;
        const selected_client = if (self.host_pool) |pool| blk: {
            selected_host_id = pool.spawnHostId() orelse return error.SpawnHostUnavailable;
            const adapter = try pool.retain(selected_host_id);
            retained = true;
            if (adapter.hostId() != selected_host_id) return error.HostIdentityMismatch;
            selected_adapter = adapter;
            break :blk null;
        } else blk: {
            const client = self.client orelse return error.HostNotFound;
            selected_host_id = client.host_id;
            break :blk client;
        };
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        const request = persistentSpawnRequest(params.request);
        const notification: remote_runtime.NotificationBootstrap = .{
            .config_generation = self.notification_config_generation,
            .notifications_osc = self.notifications_osc,
            .display_label = "",
        };
        if (selected_adapter) |adapter|
            try rr.spawnWithAdapterAndNotification(adapter, self.allocator, self.io, params.handle, request, params.size, params.initial_config, notification)
        else
            try rr.spawnWithConfigAndNotification(selected_client.?, self.allocator, self.io, params.handle, request, params.size, params.initial_config, notification);
        errdefer rr.deinit(); // spawn 성공 후 map 삽입이 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지).
        try self.runtimes.put(self.allocator, params.handle, .{
            .runtime = rr,
            .host_id = selected_host_id,
            .host_adapter_generation = if (self.host_pool) |pool|
                pool.adapterGeneration(selected_host_id) orelse return error.HostIdentityMismatch
            else
                0,
            .runtime_generation = try self.issueRuntimeGeneration(),
            .notification_config_applied_generation = self.notification_config_generation,
        });
        self.consumeRuntimeAdmission(&admission);
        return &rr.surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!RuntimeLink {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = process_in_reader; // 원격은 spawn이 이미 host에 controller attach했다(output은 host가 처리, 로컬 reader 없음).
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        // 원격 Term을 앱 라우팅 표에 **원격 PtyIo**로 등록한다(in-process가 write_queue PtyIo로 등록되는 것과 대칭).
        // 이후 self.runtime.writeInput/resize/enqueueCoreCommand(handle)가 이 PtyIo로 갈려 sendInput/resize RPC로 간다 —
        // GUI 입력 hot path는 로컬/원격을 모른다. handle=surface_id=pty_id라 라우팅 키 변환이 없다.
        return self.surface_runtime.attach(&rr.surface, handle, remotePtyIo(rr));
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!RuntimeEventPump {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        // 원격 pump: frame loop의 drainAvailable이 delta stream을 소비하도록 vtable을 심는다(e3-1). ctx=이 RemoteRuntime.
        return RuntimeEventPump.initRemote(self.allocator, .{ .ctx = rr, .drain = drainRemote });
    }

    /// `RemotePump.drain` — 원격 delta stream을 논블로킹으로 다 비워 `DrainSummary`를 만든다(로컬 큐 drain과 같은 의미).
    /// 적용된 배치 수만큼 output_events(→ metal_dirty), wire/apply 오류는 error로 던지지 않고 ended(read_error)로 바꿔
    /// frame loop가 surface를 exited로 표시하게 한다(로컬 read_error 계약과 동형 — host 연결 끊김 = 세션 종료).
    fn drainRemote(ctx: *anyopaque) DrainSummary {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        if (RemoteRuntime.backend_api.takeFrameSummary(rr)) |summary| return summary;
        return drainRemoteNow(rr);
    }

    fn drainRemoteNow(rr: *RemoteRuntime) DrainSummary {
        var summary: DrainSummary = .{};
        if (RemoteRuntime.backend_api.pumpEnded(rr)) return summary;
        while (true) {
            const result = rr.pumpDelta() catch |err| {
                switch (err) {
                    // 복구 가능 desync(§9 — 조립기가 "reject-and-request-fresh"로 표시): host에 fresh snapshot을 재요청한다.
                    // 다음 tick에 snapshot_chunk가 와 applySnapshot이 generation을 리셋해 복구한다. read_error로 종료하지 **않는다**
                    // (예전엔 여기서 read_error로 뭉개 터미널이 영구 멈췄다 — code-review #7). resync 실패(연결 죽음)는 무시하되,
                    // 다음 pumpDelta가 그 연결 오류를 read_error로 잡아 세션을 정상 종료시킨다.
                    error.GenerationGap, error.MalformedRow => {
                        rr.requestResync() catch {};
                        break;
                    },
                    // 그 외(연결 끊김·codec DecodeError 등)는 세션 종료로 본다(로컬 read_error 계약과 동형). @errorName은 정적
                    // 문자열이라 DrainSummary.ended가 소비될 때까지 산다(runtime_pump.Termination 계약).
                    else => {
                        // remote pump는 local RuntimeEventPump.applyQueuedEvent를 거치지 않으므로 여기서 surface를 직접
                        // latch해야 SurfaceRuntime 입력 gate가 죽은 PtyIo로 재전송하지 않는다. runtime별 one-shot으로
                        // 올려 shared connection 실패가 매 frame 같은 read_error를 재발행하는 것도 막는다.
                        RemoteRuntime.backend_api.markPumpEnded(rr);
                        rr.surface.process_state = .exited;
                        summary.ended = .{ .read_error = @errorName(err) };
                        break;
                    },
                }
            };
            switch (result) {
                .idle => break,
                .event_pending => break,
                .metadata => {
                    client_idle_pump_evidence.recordMetadataEvent();
                    continue;
                },
                .screen => {
                    client_idle_pump_evidence.recordScreenEvent();
                    summary.output_events += 1;
                },
                .ended => {
                    client_idle_pump_evidence.recordEndedEvent();
                    RemoteRuntime.backend_api.markPumpEnded(rr);
                    rr.surface.process_state = .exited;
                    // Registry membership proves lifecycle end but no tombstone carries the child
                    // wait status. Preserve that uncertainty instead of fabricating exit code 0.
                    summary.ended = .{ .exited = .{ .unknown = 0 } };
                    summary.exit_events = 1;
                    break;
                },
            }
        }
        return summary;
    }

    test "remote transport failure latches surface exited exactly once" {
        const allocator = std.testing.allocator;
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        client.poison(.local_invariant_violation);

        var rr: RemoteRuntime = undefined;
        remote_runtime.testing_api.initializeLegacyConnection(&rr, &client);
        try remote_runtime.testing_api.initializePendingOwners(&rr);
        rr.allocator = allocator;
        rr.io = std.testing.io;
        rr.runtime_id_hex = "00000000000000000000000000000001".*;
        remote_runtime.testing_api.generation(&rr).attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
        remote_runtime.testing_api.generation(&rr).resize_seq = 0;
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        rr.input_batches = .{};
        defer rr.input_batches.deinit(allocator);
        try rr.mutation_owner.initInPlace(
            try rr.generation_owner.slot.currentGeneration(),
            rr.input_batches.epoch,
        );
        rr.direct_input_offset = 0;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.blocking_flush_active = false;
        remote_runtime.testing_api.generation(&rr).pump_ended = false;
        remote_runtime.testing_api.generation(&rr).resync_needed = false;
        remote_runtime.testing_api.generation(&rr).observation = .{};
        defer remote_runtime.testing_api.generation(&rr).observation.deinit(allocator);
        remote_runtime.testing_api.generation(&rr).event_generation_tracking = .tracked;
        remote_runtime.testing_api.generation(&rr).resize_generation = 0;
        remote_runtime.testing_api.generation(&rr).resize_baseline_present = false;
        rr.surface = try Surface.init(allocator, 77, .{ .cols = 20, .rows = 3 });
        defer rr.surface.deinit();
        rr.surface.process_state = .running;

        const first = drainRemote(&rr);
        try std.testing.expect(first.ended != null);
        try std.testing.expect(rr.surface.process_state == .exited);
        const second = drainRemote(&rr);
        try std.testing.expect(second.ended == null);
        try std.testing.expectEqual(@as(usize, 0), second.output_events);
    }

    test "typed runtime end projects unknown status and exits surface exactly once" {
        const allocator = std.testing.allocator;
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        var ended = client_mod.BufferedEvent{
            .header = .{ .kind = .event, .stream_id = 7 },
            .payload = try allocator.dupe(u8, "{\"event\":\"runtime.ended\"}"),
        };
        ended.header.payload_len = @intCast(ended.payload.len);
        try client.pending_events.append(allocator, ended);
        client.pending_event_bytes = ended.payload.len;

        var rr: RemoteRuntime = undefined;
        remote_runtime.testing_api.initializeLegacyConnection(&rr, &client);
        try remote_runtime.testing_api.initializePendingOwners(&rr);
        rr.allocator = allocator;
        rr.io = std.testing.io;
        rr.runtime_id_hex = "00000000000000000000000000000001".*;
        remote_runtime.testing_api.generation(&rr).attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
        remote_runtime.testing_api.generation(&rr).resize_seq = 0;
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        rr.input_batches = .{};
        defer rr.input_batches.deinit(allocator);
        rr.direct_input_offset = 0;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.blocking_flush_active = false;
        remote_runtime.testing_api.generation(&rr).pump_ended = false;
        remote_runtime.testing_api.generation(&rr).resync_needed = false;
        remote_runtime.testing_api.generation(&rr).observation = .{};
        defer remote_runtime.testing_api.generation(&rr).observation.deinit(allocator);
        remote_runtime.testing_api.generation(&rr).event_generation_tracking = .tracked;
        remote_runtime.testing_api.generation(&rr).resize_generation = 0;
        remote_runtime.testing_api.generation(&rr).resize_baseline_present = false;
        rr.surface = try Surface.init(allocator, 77, .{ .cols = 20, .rows = 3 });
        defer rr.surface.deinit();
        rr.surface.process_state = .running;

        const first = drainRemote(&rr);
        try std.testing.expectEqual(@as(usize, 1), first.exit_events);
        switch (first.ended.?) {
            .exited => |status| try std.testing.expectEqual(
                maru.pty.ExitStatus{ .unknown = 0 },
                status,
            ),
            .read_error => return error.TestUnexpectedResult,
        }
        try std.testing.expect(rr.surface.process_state == .exited);
        const second = drainRemote(&rr);
        try std.testing.expect(second.ended == null);
        try std.testing.expectEqual(@as(usize, 0), second.exit_events);
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return rr.sendInput(bytes);
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return writeInputChunk(rr, bytes);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: CoreCommand, io: std.Io) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = io;
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return routeCoreCommand(rr, cmd);
    }

    fn enqueueInputBatch(
        ctx: *anyopaque,
        handle: RuntimeHandle,
        batch: maru.app.input_owner.InputBatch,
    ) anyerror!maru.app.input_owner.BatchAdmission {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        try rr.enqueueInputBatch(batch);
        return .backend_owned;
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: maru.terminal.Size, io: std.Io) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = io;
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return rr.resize(size.cols, size.rows);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.CloseProgress {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        return self.requestRuntimeClose(handle, .close_and_detach, .terminate_host);
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.CloseProgress {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        return self.requestRuntimeClose(handle, .close_without_routing, .terminate_host);
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.CloseProgress {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        return self.requestRuntimeClose(handle, .finish_after_termination, .terminate_host);
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.RemoveProgress {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.close_operation_owner.active) return .event_pending;
        const entry = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.close_runtime_absent);
        if (!close_authority.valid(&entry.runtime.close_authority))
            process_seal.fatalIntegrity(.proof_loss);
        if (entry.runtime.close_authority.lifecycle_raw != @intFromEnum(close_authority.Lifecycle.ready_remove))
            return .event_pending;
        var pin: close_authority.CloseOperationPin = .{};
        close_authority.acquirePin(&self.close_operation_owner, &pin, @intFromPtr(self), &entry.runtime.close_authority) catch
            process_seal.fatalIntegrity(.proof_loss);
        close_authority.advance(&entry.runtime.close_authority, .ready_remove, .consumed) catch
            process_seal.fatalIntegrity(.proof_loss);
        var closing_receipt: close_contract.ClosingReceipt = .{ .scan = .{
            .handle = handle,
            .runtime_generation = entry.runtime_generation,
            .close_request_generation = entry.runtime.close_authority.close_request_generation,
            .close_schedule_ticket = entry.runtime.close_authority.close_schedule_ticket,
        } };
        close_authority.consumePin(&self.close_operation_owner, &pin, &entry.runtime.close_authority) catch
            process_seal.fatalIntegrity(.proof_loss);
        const removed = self.runtimes.fetchRemove(handle) orelse process_seal.fatalIntegrity(.close_runtime_absent);
        if (removed.value.runtime != entry.runtime or removed.value.runtime_generation != entry.runtime_generation)
            process_seal.fatalIntegrity(.close_runtime_absent);
        if (!close_contract.consumeClosingReceipt(&closing_receipt, closing_receipt.scan, self.runtimes.contains(handle)))
            process_seal.fatalIntegrity(.proof_loss);
        self.destroyRuntimeEntry(handle, removed.value, .terminate);
        return .removed;
    }

    fn requestRuntimeClose(
        self: *RemoteTermBackend,
        handle: RuntimeHandle,
        kind: close_authority.CloseRequestKind,
        disposition: close_authority.CloseDisposition,
    ) term_backend.CloseProgress {
        if (self.close_operation_owner.active) return .event_pending;
        const entry = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.close_runtime_absent);
        const authority = &entry.runtime.close_authority;
        if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.pristine)) {
            const ticket = self.close_ticket_issuer.issue() orelse
                process_seal.fatalIntegrity(.close_ticket_exhausted);
            close_authority.prepareCurrent(authority, .{
                .runtime_addr = @intFromPtr(entry.runtime),
                .handle = handle,
                .runtime_generation = entry.runtime_generation,
                .host_id = entry.host_id,
                .close_request_generation = ticket,
                .close_schedule_ticket = ticket,
                .request_kind = kind,
                .disposition = disposition,
            }) catch process_seal.fatalIntegrity(.proof_loss);
        }
        if (!close_authority.valid(authority) or authority.handle != handle or
            authority.runtime_generation != entry.runtime_generation or authority.request_kind_raw != @intFromEnum(kind))
            process_seal.fatalIntegrity(.proof_loss);
        var pin: close_authority.CloseOperationPin = .{};
        close_authority.acquirePin(&self.close_operation_owner, &pin, @intFromPtr(self), authority) catch |err| switch (err) {
            error.Busy => return .event_pending,
            else => process_seal.fatalIntegrity(.proof_loss),
        };
        defer close_authority.consumePin(&self.close_operation_owner, &pin, authority) catch
            process_seal.fatalIntegrity(.proof_loss);

        if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.open)) {
            if (kind == .close_and_detach) self.surface_runtime.detachSurface(handle);
            close_authority.advance(authority, .open, .routing_tombstoned) catch
                process_seal.fatalIntegrity(.proof_loss);
        }
        if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.routing_tombstoned)) {
            if (kind != .finish_after_termination) entry.runtime.terminate();
            close_authority.advance(authority, .routing_tombstoned, .settling) catch
                process_seal.fatalIntegrity(.proof_loss);
        }
        if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.settling)) {
            const readiness = entry.runtime.advancePendingEventForClose();
            const ready_remove = close_authority.publishReadyRemove(authority, readiness == .complete) catch
                process_seal.fatalIntegrity(.proof_loss);
            if (!ready_remove) return .event_pending;
        }
        return if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.ready_remove))
            .complete
        else
            .event_pending;
    }

    /// window graph가 어떤 target도 변경하기 전에 모든 remote runtime의 event readiness를 읽는다.
    /// 실제 authority/ticket/routing publication은 이 read-only 통과 뒤 AppSession의 commit suffix만 수행한다.
    pub fn windowCloseReadiness(self: *const RemoteTermBackend, handle: RuntimeHandle) term_backend.CloseProgress {
        if (self.close_operation_owner.active) return .event_pending;
        const entry = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.close_runtime_absent);
        const authority = &entry.runtime.close_authority;
        if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.pristine))
            return pending_event_owner.closeReadiness(&entry.runtime.pending_event_owner);
        if (!close_authority.valid(authority) or authority.handle != handle or authority.runtime_generation != entry.runtime_generation)
            process_seal.fatalIntegrity(.proof_loss);
        return if (authority.lifecycle_raw == @intFromEnum(close_authority.Lifecycle.ready_remove)) .complete else .event_pending;
    }

    /// 모든 target의 authority identity와 ticket 범위를 먼저 고정한다. 이 호출이 성공한 뒤에는 caller가
    /// AppSession graph destination을 봉인하고 `publishWindowCloseAuthoritiesNoFail`만 호출해야 한다.
    pub fn reserveWindowCloseTickets(
        self: *RemoteTermBackend,
        handles: []const RuntimeHandle,
        out: *WindowCloseTicketReservation,
    ) !void {
        if (!std.meta.eql(out.*, WindowCloseTicketReservation{}) or handles.len == 0 or
            handles.len > std.math.maxInt(u32) or self.close_operation_owner.active)
            return error.InvalidReservation;
        const digest = self.windowCloseTargetDigest(handles) orelse return error.InvalidReservation;
        const count: u64 = @intCast(handles.len);
        if (self.close_ticket_issuer.terminal or count > std.math.maxInt(u64) - self.close_ticket_issuer.last_issued)
            process_seal.fatalIntegrity(.close_ticket_exhausted);
        const first = self.close_ticket_issuer.last_issued + 1;
        const last = self.close_ticket_issuer.last_issued + count;
        const ready = try process_seal.currentReadyIdentity();
        out.* = .{
            .self_addr = @intFromPtr(out),
            .backend_addr = @intFromPtr(self),
            .pid = ready.pid,
            .process_nonce = ready.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .first_ticket = first,
            .last_ticket = last,
            .target_count = @intCast(handles.len),
            .target_digest = digest,
            .state_raw = 1,
        };
        errdefer out.* = .{};
        out.seal = try windowCloseTicketReservationSeal(out);
        self.close_ticket_issuer.last_issued = last;
        self.close_ticket_issuer.terminal = last == std.math.maxInt(u64);
    }

    /// ticket reservation 뒤에는 실패 가능한 작업을 두지 않는다. 모든 authority와 routing tombstone을 같은
    /// callback/allocation 0 suffix에서 게시하고 reservation을 exact once 소비한다.
    pub fn publishWindowCloseAuthoritiesNoFail(
        self: *RemoteTermBackend,
        handles: []const RuntimeHandle,
        reservation: *WindowCloseTicketReservation,
    ) void {
        if (!self.validWindowCloseTicketReservation(handles, reservation))
            process_seal.fatalIntegrity(.proof_loss);
        for (handles, 0..) |handle, index| {
            const entry = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.close_runtime_absent);
            const ticket = reservation.first_ticket + @as(u64, @intCast(index));
            close_authority.prepareCurrent(&entry.runtime.close_authority, .{
                .runtime_addr = @intFromPtr(entry.runtime),
                .handle = handle,
                .runtime_generation = entry.runtime_generation,
                .host_id = entry.host_id,
                .close_request_generation = ticket,
                .close_schedule_ticket = ticket,
                .request_kind = .close_and_detach,
                .disposition = .terminate_host,
            }) catch process_seal.fatalIntegrity(.proof_loss);
            self.surface_runtime.detachSurface(handle);
            close_authority.advance(&entry.runtime.close_authority, .open, .routing_tombstoned) catch
                process_seal.fatalIntegrity(.proof_loss);
        }
        reservation.state_raw = 2;
        reservation.seal = [_]u8{0} ** 32;
    }

    fn validWindowCloseTicketReservation(
        self: *const RemoteTermBackend,
        handles: []const RuntimeHandle,
        reservation: *const WindowCloseTicketReservation,
    ) bool {
        const digest = self.windowCloseTargetDigest(handles) orelse return false;
        const expected = windowCloseTicketReservationSeal(reservation) catch return false;
        return reservation.self_addr == @intFromPtr(reservation) and reservation.backend_addr == @intFromPtr(self) and
            reservation.pid == process_seal.currentProcessId() and
            reservation.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and reservation.state_raw == 1 and
            reservation.target_count == handles.len and reservation.first_ticket != 0 and
            reservation.last_ticket == reservation.first_ticket + handles.len - 1 and
            reservation.last_ticket == self.close_ticket_issuer.last_issued and
            std.mem.eql(u8, &reservation.target_digest, &digest) and
            std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, reservation.seal);
    }

    fn windowCloseTargetDigest(self: *const RemoteTermBackend, handles: []const RuntimeHandle) ?process_seal.CleanupSeal {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashWindowCloseInt(&hasher, u32, @intCast(handles.len));
        for (handles, 0..) |handle, index| {
            const entry = self.runtimes.get(handle) orelse return null;
            if (entry.runtime.close_authority.lifecycle_raw != @intFromEnum(close_authority.Lifecycle.pristine)) return null;
            _ = pending_event_owner.closeReadiness(&entry.runtime.pending_event_owner);
            if (!self.surface_runtime.linkMatches(handle, &entry.runtime.surface, handle, entry.runtime)) return null;
            for (handles[0..index]) |previous| if (previous == handle) return null;
            hashWindowCloseInt(&hasher, u64, handle);
            hashWindowCloseInt(&hasher, u64, @intFromPtr(entry.runtime));
            hashWindowCloseInt(&hasher, u64, entry.runtime_generation);
            hashWindowCloseInt(&hasher, u128, entry.host_id);
        }
        return hasher.finalResult();
    }

    /// 원격 Term을 **terminate 없이** 회수한다(§6 app-quit=detach, e3-6). `remove`와 대칭이되 host `runtime.terminate`를 안
    /// 보낸다 — 라우팅 link를 떼고 client-side rr만 free하므로 runtime이 host에 남아 재접속 대상이 된다(연결이 닫히면 host가
    /// controller를 detach로 처리해 유지). 앱 quit 시 host-backed Term에 쓴다(윈도우/탭 명시 close는 `remove`=terminate).
    /// **vtable 밖** — app_session deinit이 app_quitting일 때 직접 부른다.
    pub fn detachTerm(self: *RemoteTermBackend, handle: RuntimeHandle) void {
        if (!self.runtimes.contains(handle)) return;
        if ((self.app_quit_routing_tombstoned or self.app_quit_connections_terminalized) and
            !self.app_quit_owner_graphs_settled)
            process_seal.fatalIntegrity(.proof_loss);

        self.detachTermClientSideNoFail(handle);
    }

    fn detachTermClientSideNoFail(self: *RemoteTermBackend, handle: RuntimeHandle) void {
        const entry = self.runtimes.get(handle) orelse process_seal.fatalIntegrity(.proof_loss);
        // Runtime owner와 attachment graph를 map membership이 살아 있는 동안 먼저 닫는다. 이 호출 뒤에는 callback과
        // fallible 작업이 없으며, exact row를 제거한 다음 allocation과 host lease만 마지막으로 회수한다.
        const generation_adapter = if (builtin.is_test)
            remote_runtime.testing_api.generationAdapter(entry.runtime)
        else
            null;
        self.surface_runtime.detachSurface(handle);
        if (self.app_quit_connections_terminalized) {
            if (!self.app_quit_owner_graphs_settled) process_seal.fatalIntegrity(.proof_loss);
            entry.runtime.detachClientSideAfterSharedConnectionTerminalized();
        } else {
            entry.runtime.detachClientSide();
        }
        if (builtin.is_test) {
            if (generation_adapter) |adapter| {
                if (remote_runtime.testing_api.appQuitSourceZero(adapter))
                    B5TestState.app_quit_source_zero_count += 1;
            }
        }
        const removed = self.runtimes.fetchRemove(handle) orelse process_seal.fatalIntegrity(.proof_loss);
        if (removed.value.runtime != entry.runtime or removed.value.host_id != entry.host_id or
            removed.value.runtime_generation != entry.runtime_generation)
            process_seal.fatalIntegrity(.proof_loss);
        self.allocator.destroy(removed.value.runtime);
        if (self.host_pool) |pool| pool.release(removed.value.host_id);
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return null).runtime;
        return RemoteRuntime.backend_api.foregroundProcessGroup(rr);
    }

    /// host-backed 터미널의 자원 표본. PTY가 host 프로세스 안에 살아 **앱의 트리 walk가 자기 자식에서
    /// 출발해서는 못 닿지만**, 뿌리 pid만 알면 닿는다 — libproc은 같은 uid면 자손이 아닌 프로세스도
    /// 열거·조회하게 해 준다(실측: 비-자손 pid에서 `proc_listchildpids` 자식 5개, `proc_pid_rusage` rc=0.
    /// 다른 uid면 rc=-1). 그 뿌리를 host가 관측에 실어 보낸다(docs/status-bar.md §4.1).
    ///
    /// 예전 판은 무조건 0을 돌려줬고, 그래서 keep-alive를 켠 사용자에게는 모든 탭이 `—`였다.
    /// **호스트 데몬 자신은 여기서 안 센다** — 자식 트리와 겹치지 않게 별도 "모든 창 공유" 행이 갖는다
    /// (`hostProcessSamples`).
    fn resourceSamples(ctx: *anyopaque, handle: RuntimeHandle, out: []maru.session.resource_usage.Sample) usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return 0;
        const rr = (self.runtimes.get(handle) orelse return 0).runtime;
        const root = RemoteRuntime.backend_api.processIdentity(rr).child_pid;
        if (root <= 0) return 0; // 구 host이거나 관측이 아직 안 왔다 — 0을 그리지 않고 항목이 `—`로 남는다.
        var raw: [max_resource_samples]maru.pty.types.ProcessResourceSample = undefined;
        const room = @min(raw.len, out.len);
        const n = maru.pty.processTreeSamples(root, raw[0..room]);
        for (raw[0..n], 0..) |sample, i| out[i] = .{
            .pid = sample.pid,
            .footprint_bytes = sample.footprint_bytes,
            .cpu_ns = sample.cpu_ns,
        };
        return n;
    }

    /// 이 backend가 붙어 있는 **session host 데몬 프로세스 자신**의 표본(중복 제거). 트리를 훑지 **않는다** —
    /// 그 자식들은 위 `resourceSamples`가 탭별로 이미 세므로, 여기서 트리를 훑으면 같은 바이트를 두 번 센다.
    ///
    /// backend는 앱 전역이라(창마다가 아니다) 어느 창에서 물어도 같은 답이고, 그래서 상태바는 이 값을
    /// 앱 자신과 같은 **"모든 창 공유"** 행으로 낸다(docs/status-bar.md §4.1 "앱 자신은 센다"와 같은 규율).
    /// host가 여럿일 수 있어(업그레이드 중 구/신 host 공존) pid로 중복을 거른다.
    pub fn hostProcessSamples(self: *RemoteTermBackend, out: []maru.session.resource_usage.Sample) usize {
        var n: usize = 0;
        var it = self.runtimes.valueIterator();
        while (it.next()) |entry| {
            if (n >= out.len) break;
            const pid = RemoteRuntime.backend_api.processIdentity(entry.runtime).host_pid;
            if (pid <= 0) continue;
            var seen = false;
            for (out[0..n]) |prev| {
                if (prev.pid == pid) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const sample = maru.pty.processResourceSample(pid) orelse continue;
            out[n] = .{
                .pid = sample.pid,
                .footprint_bytes = sample.footprint_bytes,
                .cpu_ns = sample.cpu_ns,
            };
            n += 1;
        }
        return n;
    }

    /// 한 host-backed Term 트리에서 가져올 표본 상한. in-process backend의 같은 이름 상수와 같은 근거다
    /// (폭주 방어 — fork 폭탄이나 깊은 트리가 tick을 붙잡지 않게).
    const max_resource_samples: usize = 64;

    /// **원격 runtime은 커널 cwd 폴백이 없다.** PTY와 그 자식 프로세스가 host 데몬 프로세스에 살아서 GUI
    /// 프로세스의 `proc_pidinfo`가 닿지 않는다(pid 네임스페이스가 아니라 소유 프로세스가 다른 문제다).
    /// 그래서 원격 Term은 GUI process tree를 다시 훑지 않고 host가 observation에 넣은 paired cwd를 단독 출처로 쓴다.
    /// OSC 7이 없을 때의 kernel fallback도 PTY를 소유한 host에서 측정해 같은 observation으로 온다. 여기서 별도
    /// fallback을 열면 SSH 억제·authority·cadence가 둘로 갈리므로 계속 null이다.
    fn processCwd(ctx: *anyopaque, handle: RuntimeHandle, out: []u8) ?[]const u8 {
        _ = ctx;
        _ = handle;
        _ = out;
        return null;
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []ForegroundProcessName) usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return 0).runtime;
        return RemoteRuntime.backend_api.copyForegroundProcessNames(rr, out);
    }

    fn readObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground; // host event가 bounded cadence로 foreground까지 coherent하게 갱신한다.
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        if (RemoteRuntime.backend_api.observationMatches(rr, out)) return;
        try RemoteRuntime.backend_api.copyObservation(rr, allocator, out);
    }

    fn refreshObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground;
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        try rr.refreshObservation();
        try RemoteRuntime.backend_api.copyObservation(rr, allocator, out);
    }

    fn dumpRecentText(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return RemoteRuntime.backend_api.dumpRecentText(rr, allocator, self.io, max_rows, max_bytes);
    }

    // ── 원격 PtyIo(SurfaceRuntime link의 input/resize sink) ─────────────────────────
    //
    // in-process는 link의 PtyIo가 live_pty write_queue를 가리키지만, 원격은 여기 세 함수가 그 자리를 채워 sendInput/
    // resize RPC로 보낸다. ctx=*RemoteRuntime. `enqueue_command`는 `ioEnqueueCommand`로 연결해 스크롤·선택·
    // 마우스의 구현된 subset을 host/placeholder에 명시적으로 라우팅한다. 그 밖의 config/focus는 아직 drop한다.
    // `write_input_nb`는 채운다(paste 논블로킹 계약 — socket write는 전량 전송으로 본다).

    fn remotePtyIo(rr: *RemoteRuntime) PtyIo {
        return .{
            .ctx = rr,
            .write_input = ioWriteInput,
            .resize_fn = ioResize,
            .write_input_nb = ioWriteInputNonBlocking,
            .enqueue_command = ioEnqueueCommand, // host-authoritative command는 exhaustive router로 전달.
        };
    }

    /// SurfaceRuntime이 host-backed Term에 보내는 명령의 공용 진입점. host 소유 명령은 wire로, attachment-local 선택
    /// 하이라이트는 placeholder로 분류한다. IME marked text는 CoreCommand가 아니라 Surface의 client-local overlay라 이
    /// 경로에 들어오지 않으며, 확정 바이트만 write_input 경로를 탄다.
    fn ioEnqueueCommand(ctx: *anyopaque, cmd: core_command.CoreCommand) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return routeCoreCommand(rr, cmd);
    }

    /// local/remote backend의 공용 `CoreCommand` 계약을 원격 소유권에 따라 완전 분류한다. `else`를 두지 않아
    /// 새 variant가 추가되면 조용히 유실되지 않고 이 switch가 컴파일 오류로 routing 결정을 요구한다.
    fn routeCoreCommand(rr: *RemoteRuntime, cmd: core_command.CoreCommand) anyerror!void {
        switch (cmd) {
            .scroll => |delta| try rr.queueCoreCommand(.{ .scroll = std.math.cast(i64, delta) orelse return error.InvalidCommand }),
            // IME/key callback에서 호출될 수 있으므로 request/response RPC를 기다리지 않는다. stream-local
            // sticky intent + Client bounded outbound frame이 다음 input보다 앞선 wire 순서를 보존한다.
            .scroll_to_bottom => try rr.requestScrollToBottom(),
            .scroll_to_abs => |row| try rr.queueCoreCommand(.{ .scroll_to_abs = @intCast(row) }),
            .scroll_to_offset => |offset| try rr.queueCoreCommand(.{ .scroll_to_offset = @intCast(offset) }),
            .report_focus => |gained| try rr.queueCoreCommand(.{ .report_focus = gained }),
            .set_cell_metrics => |metrics| try rr.queueCoreCommand(.{ .set_cell_metrics = .{
                .width = metrics.width,
                .height = metrics.height,
            } }),
            .set_default_colors => |colors| try rr.queueCoreCommand(.{ .set_default_colors = .{
                .foreground = rgbToWire(colors.foreground),
                .background = rgbToWire(colors.background),
            } }),
            .set_config_palette => |palette| try rr.queueCoreCommand(.{ .set_config_palette = paletteToWire(palette) }),
            .set_max_scrollback => |lines| try rr.queueCoreCommand(.{ .set_max_scrollback = @intCast(lines) }),
            .set_ambiguous_wide => |wide| try rr.queueCoreCommand(.{ .set_ambiguous_wide = wide }),
            .set_emoji_wide => |wide| try rr.queueCoreCommand(.{ .set_emoji_wide = wide }),
            // cursor.shape reload — 기본 모양은 host core가 소유하므로(DECSCUSR 0/RIS 복귀 지점) 원격에 위임한다.
            .set_default_cursor_shape => |shape| try rr.queueCoreCommand(.{ .set_default_cursor_shape = @intFromEnum(shape) }),
            .set_runtime_config => |config| try rr.queueCoreCommand(.{ .set_runtime_config = .{
                .max_scrollback = @intCast(config.max_scrollback),
                .ambiguous_wide = config.ambiguous_wide,
                .emoji_wide = config.emoji_wide,
                .palette = paletteToWire(config.palette),
                .default_colors = .{
                    .foreground = rgbToWire(config.default_colors.foreground),
                    .background = rgbToWire(config.default_colors.background),
                },
                .cell_metrics = if (config.cell_metrics) |metrics| .{
                    .width = metrics.width,
                    .height = metrics.height,
                } else null,
                .cursor_shape = @intFromEnum(config.default_cursor_shape),
            } }),
            .jump_to_prompt => |direction| try rr.queueCoreCommand(.{ .jump_to_prompt = direction }),
            .clear_screen => try rr.queueCoreCommand(.clear_screen),
            .reset_input_modes => try rr.queueCoreCommand(.reset_input_modes),
            // §6b-1 드래그 선택: 하이라이트 span은 client 좌표라 **placeholder core에 적용해 즉시** 반영한다(렌더가 이미
            // surface.core.selectionViewportSpan을 읽음 — 새 렌더 배선/span-push 불요, 왕복 지연 없음). 복사(콘텐츠 연산)는
            // app_session.copyText가 이 span을 host로 보내 host의 extractSelection으로 한다(선택 의미론=host 단일 출처).
            // 콘텐츠 인지 경계(word/line/all)는 빈 placeholder에선 부정확하므로 host가 계산한다. negotiated selection-state는
            // 같은 start/extend/clear를 응답 없는 FIFO로 host에도 미러링해 화면 밖 자동스크롤 선택을 보존한다.
            .select_start => |point| {
                rr.clearSelectAllIntent();
                _ = core_command.apply(&rr.surface.core, cmd);
                try rr.mirrorSelectionCommand(.{ .selection_start = .{ .row = point.row, .col = point.col, .block = point.block } });
            },
            .select_extend => |point| {
                rr.clearSelectAllIntent();
                _ = core_command.apply(&rr.surface.core, cmd);
                try rr.mirrorSelectionCommand(.{ .selection_extend = .{ .row = point.row, .col = point.col } });
            },
            .select_extend_or_collapse => |point| {
                rr.clearSelectAllIntent();
                _ = core_command.apply(&rr.surface.core, cmd);
                try rr.mirrorSelectionCommand(.{ .selection_extend_or_collapse = .{ .row = point.row, .col = point.col } });
            },
            .select_clear => {
                rr.clearSelectAllIntent();
                _ = core_command.apply(&rr.surface.core, cmd);
                try rr.mirrorSelectionCommand(.selection_clear);
            },
            .select_all => {
                rr.clearSelectAllIntent();
                if (rr.selectContentAware("all", 0, 0, "") catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                } else {
                    // same-major 구 host는 all op를 모르므로 현재 viewport 선택으로만 안전하게 degraded된다.
                    _ = core_command.apply(&rr.surface.core, cmd);
                }
            },
            // §6b-2 단어/줄 선택: 콘텐츠 인지 경계는 빈 placeholder가 모르므로 **host가 계산해 span을 돌려준다**(selectContentAware).
            // word는 CoreCommand에 복사된 현재 config separator까지 bounded request에 복사해 reload 수명과 wire 수명을 분리한다.
            // 그 span을 placeholder에 적용해 하이라이트(렌더가 selectionViewportSpan을 읽음). 복사는 #6b-1이 그 span으로 host 추출.
            .select_word => |s| {
                rr.clearSelectAllIntent();
                if (rr.selectContentAware("word", s.row, s.col, s.separators[0..s.sep_len]) catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            .select_line => |row| {
                rr.clearSelectAllIntent();
                if (rr.selectContentAware("line", row, 0, "") catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            .scroll_and_extend => |step| {
                // same-major 구 host는 권위 anchor/head를 소유하지 못한다. client만 스크롤하면 host viewport와
                // 복사 좌표가 갈라지므로, capability가 없을 때는 종전처럼 전체 transaction을 no-op으로 낮춘다.
                if (!rr.supportsSelectionState()) return;
                const delta = std.math.cast(i8, step.delta) orelse return error.InvalidCommand;
                _ = core_command.apply(&rr.surface.core, cmd);
                try rr.mirrorSelectionCommand(.{ .selection_scroll_and_extend = .{
                    .delta = delta,
                    .row = step.row,
                    .col = step.col,
                } });
            },
            // §입력 패리티: 마우스 리포트는 host core가 자기 mouse_tracking/format으로 인코딩·PTY 주입해야 하므로
            // (인코딩 모드가 host에만 있음) raw 이벤트를 host로 보낸다(방식 B). placeholder core에 적용하면 응답이
            // client PTY로 안 가고(빈 placeholder) 인코딩 모드도 없어 무효다.
            .report_mouse => |m| try rr.sendMouseReport(m),
        }
    }

    fn rgbToWire(rgb: maru.terminal.Rgb) u32 {
        return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
    }

    fn paletteToWire(palette: [16]?maru.terminal.Rgb) core_command_wire.Command.Palette {
        var wire_palette: core_command_wire.Command.Palette = .{null} ** 16;
        for (palette, 0..) |maybe_rgb, index| {
            wire_palette[index] = if (maybe_rgb) |rgb| rgbToWire(rgb) else null;
        }
        return wire_palette;
    }

    fn ioWriteInput(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.sendInput(bytes);
    }

    fn ioWriteInputNonBlocking(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return writeInputChunk(rr, bytes);
    }

    fn ioResize(ctx: *anyopaque, size: maru.terminal.Size) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.resize(size.cols, size.rows);
    }
};

fn persistentSpawnRequest(request_in: maru.pty.SpawnRequest) maru.pty.SpawnRequest {
    var request = request_in;
    // MARU_PANE_ID는 GUI process-local surface id라 재실행 후 같은 persistent child 안에서 stale selector가 된다.
    // runtime↔새 surface rebinding 프로토콜 전에는 주입하지 않아 잘못된 다른 pane을 self로 선택하는 것보다 fail-closed한다.
    request.pane_id = null;
    // **훅 로그 경로의 두 칸도 같이 뗀다**(docs/agent-hooks.md §4). GUI 가 채운 값은 **GUI 프로세스**와
    // 그 프로세스의 surface 번호를 가리키는데, 이 자식은 host 가 띄우고 GUI 보다 오래 산다 — 실으면 재실행
    // 뒤 남의(또는 죽은) 칸에 쓴다. 떼면 훅이 조용히 나가 아무것도 안 남긴다(fail-closed).
    //
    // 여기서 뗀 자리는 **host 가 자기 신원으로 다시 채운다**(`formatHostInstance`/`formatRuntimePane` —
    // host_id 와 runtime_id 는 GUI 재실행을 넘어 살아 있는 유일한 이름이다). 그 배선은 host 쪽 슬라이스다.
    request.hook_instance = null;
    request.hook_pane = null;
    return request;
}

test "P4 N2b1 remote backend binding은 UTF-8 display label을 256-byte 경계에서만 자른다" {
    try std.testing.expectEqual(@as(usize, 256), boundedNotificationLabel("x" ** 300).len);
    const split = ("x" ** 255) ++ "한";
    try std.testing.expectEqual(@as(usize, 255), boundedNotificationLabel(split).len);
    try std.testing.expectEqualStrings("", boundedNotificationLabel("\xff"));

    var backend = b5TestBackend(testing.allocator);
    defer backend.runtimes.deinit(testing.allocator);
    backend.notification_config_generation = std.math.maxInt(u64);
    try testing.expectError(error.ProtocolError, backend.configureNotifications(true));
    try testing.expect(!backend.notifications_osc);
    try testing.expectEqual(std.math.maxInt(u64), backend.notification_config_generation);
}

test "persistent spawn omits process-local MARU_PANE_ID without mutating local fallback request" {
    const local: maru.pty.SpawnRequest = .{
        .command = "/bin/zsh",
        .pane_id = 42,
        .hook_instance = "4242",
        .hook_pane = "42",
    };
    const persistent = persistentSpawnRequest(local);
    try std.testing.expectEqual(@as(?u64, 42), local.pane_id);
    try std.testing.expectEqual(@as(?u64, null), persistent.pane_id);
    // 훅 경로의 두 칸도 같이 떨어진다 — 남기면 재실행 뒤 남의 칸에 쓴다.
    try std.testing.expectEqualStrings("4242", local.hook_instance.?);
    try std.testing.expectEqualStrings("42", local.hook_pane.?);
    try std.testing.expectEqual(@as(?[]const u8, null), persistent.hook_instance);
    try std.testing.expectEqual(@as(?[]const u8, null), persistent.hook_pane);
}

/// vtable 직접 호출과 SurfaceRuntime의 PtyIo 호출이 공유하는 paste 정책점. Client의 연결별 pending frame + DONTWAIT
/// flush를 쓰되, 한 UI tick이 새로 맡길 payload도 고정 상한으로 제한한다. 반환 길이 뒤의 나머지만 caller가 다음 tick에
/// 이어 보내며, pending에 수락된 prefix는 partial socket write여도 다시 보내지 않는다.
fn writeInputChunk(rr: *RemoteRuntime, bytes: []const u8) anyerror!usize {
    const chunk = bytes[0..boundedInputLen(bytes.len)];
    return rr.sendInputNonBlocking(chunk);
}

fn boundedInputLen(len: usize) usize {
    return @min(len, nonblocking_input_chunk);
}

test "remote nonblocking input policy consumes at most one bounded chunk per tick" {
    try std.testing.expectEqual(@as(usize, 0), boundedInputLen(0));
    try std.testing.expectEqual(nonblocking_input_chunk, boundedInputLen(nonblocking_input_chunk));
    try std.testing.expectEqual(nonblocking_input_chunk, boundedInputLen(nonblocking_input_chunk + 1));
}

test "CR2c remote InputOwner는 기존 UnknownSurface와 partial 의미를 그대로 쓴다" {
    const allocator = std.testing.allocator;
    var surface_runtime = SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();
    const unused_client: *client_mod.Client = @ptrFromInt(4096);
    var backend_impl = RemoteTermBackend.init(allocator, std.testing.io, unused_client, &surface_runtime);
    defer backend_impl.deinit();
    const owner = backend_impl.backend().inputOwner(0xC203);
    try std.testing.expectError(error.UnknownSurface, owner.write("late"));
    try std.testing.expectError(error.UnknownSurface, owner.writeNonBlocking("late"));
    try std.testing.expectError(error.UnknownSurface, owner.enqueueCoreCommand(.scroll_to_bottom, std.testing.io));
}

test "CR2d1 remote InputOwner batch는 unknown handle을 backend ownership으로 laundering하지 않는다" {
    const allocator = std.testing.allocator;
    var surface_runtime = SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();
    const unused_client: *client_mod.Client = @ptrFromInt(4096);
    var backend_impl = RemoteTermBackend.init(allocator, std.testing.io, unused_client, &surface_runtime);
    defer backend_impl.deinit();
    const owner = backend_impl.backend().inputOwner(0xD102);
    try std.testing.expectError(
        error.UnknownSurface,
        owner.enqueueBatch(.{ .kind = .osc52_response, .first = "late" }),
    );
}

test "CR2e-e3b2 admission drain은 resident cap에서 sealed row를 보존하고 release 뒤 actual runtime에 결속한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const identity = HostAdapter.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var fixtures: [2]remote_runtime.testing_api.SemanticFixture = undefined;
    try fixtures[0].initInPlace();
    defer fixtures[0].deinit();
    try fixtures[1].initInPlace();
    defer fixtures[1].deinit();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    for (&fixtures, 1..) |*fixture, handle| {
        try backend_value.runtimes.put(testing.allocator, handle, .{
            .runtime = &fixture.runtime,
            .host_id = 1,
            .host_adapter_generation = 3,
            .runtime_generation = 1,
        });
    }
    var admissions: reconnect_admission_owner.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    const publication = @import("maru").observability.incident_publication_contract;
    const incident = @import("maru").observability.connection_incident;
    const input: publication.IncidentInput = .{
        .timestamp_ns = 1,
        .host_id = 1,
        .host_adapter_generation = 3,
        .connection_generation = fixtures[0].adapter.connectionGeneration(),
        .wire_major = 1,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
    };
    try admissions.admit(.{
        .publication = .{
            .incident_id = .{ .app_instance_nonce = (@as(u128, 1) << 96) | 1, .sequence = 1 },
            .detail_present = true,
            .detail_slot = 0,
            .aggregate_slot = 0,
            .aggregate_generation = 1,
        },
        .wake = .queued,
        .kind_raw = @intFromEnum(publication.PublicationKind.first),
    }, input);
    var budget: reconnect_resident_budget.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    try testing.expectEqual(
        fixtures[0].adapter.connectionGeneration(),
        fixtures[1].adapter.connectionGeneration(),
    );
    var incumbents: [7]reconnect_resident_budget.Lease = @splat(.{});
    for (&incumbents) |*lease| try budget.reserve(lease, reconnect_resident_budget.max_entry_bytes, .candidate);
    const queued = (try admissions.peek()).?;
    try testing.expectEqual(
        ReconnectDrainResult.retry_later,
        try backend_value.drainReconnectAdmission(&admissions, &budget),
    );
    try testing.expectEqualDeep(queued, (try admissions.peek()).?);
    try testing.expectEqual(@as(u8, 1), admissions.count);
    try testing.expectEqual(@as(usize, 7), (try budget.snapshot()).live_entries);
    for (&fixtures) |*fixture| {
        try testing.expect(!remote_runtime.testing_api.hasBoundReconnectAdmission(&fixture.runtime));
    }
    try budget.release(&incumbents[0], .candidate);
    try budget.release(&incumbents[1], .candidate);
    try testing.expectEqual(
        ReconnectDrainResult.started,
        try backend_value.drainReconnectAdmission(&admissions, &budget),
    );
    try testing.expectEqual(@as(u8, 0), admissions.count);
    try testing.expectEqual(@as(usize, 7), (try budget.snapshot()).live_entries);
    for (&fixtures) |*fixture| {
        try testing.expect(remote_runtime.testing_api.hasBoundReconnectAdmission(&fixture.runtime));
        try testing.expect(RemoteRuntime.backend_api.matchesBoundReconnectIdentity(
            &fixture.runtime,
            1,
            3,
            input.connection_generation,
            (@as(u128, 1) << 96) | 1,
            1,
        ));
        try testing.expect(!RemoteRuntime.backend_api.matchesBoundReconnectIdentity(
            &fixture.runtime,
            1,
            3,
            input.connection_generation,
            1,
            1,
        ));
        try remote_runtime.testing_api.releaseBoundReconnectAdmission(&fixture.runtime, &budget);
    }
    for (incumbents[2..]) |*lease| try budget.release(lease, .candidate);
    try budget.deinit();
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host에 TermRuntimeBackend **계약으로** 원격 runtime을 몬다)
//
// 이 테스트가 증명하는 것(그리고 왜 e3에서 중요한가): GUI는 backend가 로컬인지 원격인지 모르고 `TermRuntimeBackend`
// 계약만 부른다. 그 계약(spawn→attach→pump→writeInput→close/remove)이 실 host runtime을 실제로 구동하고, pump가
// delta stream을 drainAvailable로 소비해 Surface에 입력 echo가 반영되는지 고정한다 — 즉 app_session이 이 backend를
// 꽂기만 하면(e3-4) host-backed 터미널이 in-process와 같은 코드로 도는지 검증. 실 forkpty·socket이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const c = std.c;
const posix = std.posix;
const daemon = @import("daemon.zig");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn addOwnedClient(pool: *AdapterPool, allocator: std.mem.Allocator, source: *client_mod.Client) !u128 {
    errdefer source.deinit();
    const adapter = try allocator.create(HostAdapter);
    errdefer allocator.destroy(adapter);
    try HostAdapter.initInPlace(adapter, allocator, source);
    errdefer adapter.deinit();
    const host_id = adapter.hostId();
    try pool.addOwned(host_id, adapter);
    return host_id;
}

fn b5TestBackend(allocator: std.mem.Allocator) RemoteTermBackend {
    return .{
        .allocator = allocator,
        .io = testing.io,
        .client = null,
        .surface_runtime = @ptrFromInt(@alignOf(SurfaceRuntime)),
    };
}

fn cr5bBeforeConnectProbe(backend: *RemoteTermBackend, job: *const HostReconnectJob) void {
    B5TestState.cr5b_before_connect_seen = true;
    B5TestState.cr5b_before_connect_valid = job.valid(backend) and
        job.state_raw == @intFromEnum(HostReconnectJobState.preparing) and
        job.runtime_row_count == 3 and
        job.runtime_rows[0].identity.runtime_handle == 10 and
        job.runtime_rows[1].identity.runtime_handle == 20 and
        job.runtime_rows[2].identity.runtime_handle == 30;
    B5TestState.cr5b_before_connect_row_count = job.runtime_row_count;
}

fn putCr5bRuntime(
    backend: *RemoteTermBackend,
    handle: RuntimeHandle,
    fixture: *remote_runtime.testing_api.SemanticFixture,
    host_id: u128,
    adapter_generation: u64,
    runtime_generation: u64,
    runtime_id_hex: [32]u8,
) !void {
    fixture.runtime.runtime_id_hex = runtime_id_hex;
    try backend.runtimes.put(testing.allocator, handle, .{
        .runtime = &fixture.runtime,
        .host_id = host_id,
        .host_adapter_generation = adapter_generation,
        .runtime_generation = runtime_generation,
    });
}

test "CR4a actual issuer job은 connected Client를 final address에서 exact once 소유한다" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    defer _ = c.close(current_fds[1]);
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    var runtime_fixture: remote_runtime.testing_api.SemanticFixture = undefined;
    try runtime_fixture.initInPlace();
    defer {
        _ = backend_value.runtimes.remove(1);
        runtime_fixture.deinit();
    }
    try backend_value.runtimes.put(testing.allocator, 1, .{
        .runtime = &runtime_fixture.runtime,
        .host_id = 91,
        .host_adapter_generation = pool.adapterGeneration(91).?,
        .runtime_generation = 1,
    });

    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 91,
        .runtime_catchup_barrier_v1 = true,
        .connection_profile = .gui,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var clock = struct {
        now_ns: i128 = 10,

        fn read(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }
    }{};
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        100,
    ));
    clock.now_ns = 100;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectConnect("/tmp/maru-cr4a-expired-must-not-connect", 91, phase),
    );
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expect(!backend_value.host_reconnect_preparing);
    clock.now_ns = 10;
    if (builtin.os.tag == .macos) {
        const failed = backend_value.beginHostReconnectConnect(
            "/tmp/maru-cr4a-actual-issuer-missing-base",
            91,
            phase,
        );
        try testing.expectEqual(host_connect.FailureReason.invalid_manifest, failed.failed);
        try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
        try testing.expect(!backend_value.host_reconnect_preparing);
        try testing.expectEqual(@as(u64, 1), backend_value.next_host_reconnect_job_generation);
    }
    const generation_before_oom = backend_value.next_host_reconnect_job_generation;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    backend_value.allocator = failing.allocator();
    const oom = backend_value.beginHostReconnectConnect(
        "/tmp/maru-cr4a-job-allocation-must-fail-first",
        91,
        phase,
    );
    try testing.expectEqual(host_connect.FailureReason.out_of_memory, oom.failed);
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expect(!backend_value.host_reconnect_preparing);
    try testing.expectEqual(generation_before_oom, backend_value.next_host_reconnect_job_generation);
    backend_value.allocator = testing.allocator;
    const job = try testing.allocator.create(HostReconnectJob);
    job.* = .{};
    backend_value.host_reconnect_job = job;
    var job_owned = true;
    errdefer if (job_owned) {
        if (job.client) |*owned| owned.deinit();
        backend_value.host_reconnect_job = null;
        testing.allocator.destroy(job);
    };
    try job.prepareForConnect(&backend_value, 91, phase);
    source.runtime_catchup_barrier_v1 = false;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        job.adoptConnected(&backend_value, 91, phase, &source),
    );
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(@intFromEnum(HostReconnectJobState.preparing), job.state_raw);
    try testing.expectEqual(@as(c.fd_t, fds[0]), source.fd);
    source.runtime_catchup_barrier_v1 = true;
    try testing.expectEqual(
        HostReconnectStart.connected,
        job.adoptConnected(&backend_value, 91, phase, &source),
    );
    try testing.expect(job.valid(&backend_value));
    try testing.expect(!backend_value.host_reconnect_preparing);
    try testing.expect(!backend_value.beginAppQuitShutdown(1));
    try testing.expectEqual(generation_before_oom + 1, backend_value.next_host_reconnect_job_generation);
    try testing.expectEqual(@as(c.fd_t, fds[0]), job.client.?.fd);

    const copied = job.*;
    try testing.expect(!copied.valid(&backend_value));
    const canonical_before = job.*;
    job.host_id = 92;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.client.?.upgrade_epoch += 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.deadline.?.absolute.expires_at_ns += 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.backend_generation += 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.pid +%= 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.process_nonce +%= 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.adapter_generation += 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    job.expected_connection_generation += 1;
    try testing.expect(!job.valid(&backend_value));
    job.* = canonical_before;
    var invalid_state: u16 = 2;
    while (invalid_state <= std.math.maxInt(u8)) : (invalid_state += 1) {
        job.state_raw = @intCast(invalid_state);
        try testing.expect(!job.valid(&backend_value));
        job.* = canonical_before;
    }
    try testing.expect(job.valid(&backend_value));

    var second_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &second_fds));
    defer _ = c.close(second_fds[1]);
    var second: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = second_fds[0],
        .host_id = 91,
        .runtime_catchup_barrier_v1 = true,
        .connection_profile = .gui,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    defer second.deinit();
    try testing.expectEqual(
        HostReconnectStart.busy,
        job.adoptConnected(&backend_value, 91, phase, &second),
    );
    try testing.expectEqualDeep(canonical_before, job.*);
    try testing.expectEqual(
        HostReconnectStart.busy,
        backend_value.beginHostReconnectConnect("/tmp/maru-cr4a-busy-must-not-connect", 91, phase),
    );
    try testing.expectEqualDeep(canonical_before, job.*);

    try backend_value.abortHostReconnectConnect();
    job_owned = false;
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expectError(error.InvalidHostReconnectJob, backend_value.abortHostReconnectConnect());
}

test "CR5b-1 host job은 actual connect 전에 same-host runtime set을 final address에 봉인한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try testing.expect(@sizeOf(HostReconnectJob) <= 512 * 1024);
    try HostAdapter.initializeProcessRuntime();

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    defer _ = c.close(current_fds[1]);
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var sibling_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sibling_fds));
    defer _ = c.close(sibling_fds[1]);
    var sibling: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = sibling_fds[0],
        .host_id = 92,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    try testing.expectEqual(@as(u128, 92), try addOwnedClient(&pool, testing.allocator, &sibling));
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();

    var fixtures: [4]remote_runtime.testing_api.SemanticFixture = undefined;
    for (&fixtures) |*fixture| try fixture.initInPlace();
    defer for (&fixtures) |*fixture| fixture.deinit();
    defer {
        _ = backend_value.runtimes.remove(10);
        _ = backend_value.runtimes.remove(20);
        _ = backend_value.runtimes.remove(30);
        _ = backend_value.runtimes.remove(40);
    }
    const host_generation = pool.adapterGeneration(91).?;
    try putCr5bRuntime(&backend_value, 30, &fixtures[0], 91, host_generation, 3, "000000000000000000000000000000a3".*);
    try putCr5bRuntime(&backend_value, 10, &fixtures[1], 91, host_generation, 1, "000000000000000000000000000000a1".*);
    try putCr5bRuntime(&backend_value, 20, &fixtures[2], 91, host_generation, 2, "000000000000000000000000000000a2".*);
    try putCr5bRuntime(
        &backend_value,
        40,
        &fixtures[3],
        92,
        pool.adapterGeneration(92).?,
        4,
        "000000000000000000000000000000b1".*,
    );

    var clock = struct {
        now_ns: i128 = 10,
        fn read(context: *anyopaque) i128 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_ns;
        }
    }{};
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        100,
    ));
    B5TestState.cr5b_before_connect_seen = false;
    B5TestState.cr5b_before_connect_valid = false;
    B5TestState.cr5b_before_connect_row_count = 0;
    B5TestState.cr5b_before_connect_hook = cr5bBeforeConnectProbe;
    defer B5TestState.cr5b_before_connect_hook = null;
    const result = backend_value.beginHostReconnectConnect(
        "/tmp/maru-cr5b1-missing-manifest-must-run-after-capture",
        91,
        phase,
    );
    try testing.expectEqual(host_connect.FailureReason.invalid_manifest, result.failed);
    try testing.expect(B5TestState.cr5b_before_connect_seen);
    try testing.expect(B5TestState.cr5b_before_connect_valid);
    try testing.expectEqual(@as(u32, 3), B5TestState.cr5b_before_connect_row_count);
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expectEqual(@as(u64, 1), backend_value.next_host_reconnect_job_generation);
    try testing.expectEqual(@as(usize, 4), backend_value.runtimes.count());
    try testing.expectEqual(@as(u64, 1), pool.get(91).?.connectionGeneration());
}

test "CR5b-1 host job runtime set은 copy membership identity drift와 empty를 mutation 없이 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    defer _ = c.close(current_fds[1]);
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    var fixtures: [4]remote_runtime.testing_api.SemanticFixture = undefined;
    for (&fixtures) |*fixture| try fixture.initInPlace();
    defer for (&fixtures) |*fixture| fixture.deinit();
    defer {
        _ = backend_value.runtimes.remove(10);
        _ = backend_value.runtimes.remove(20);
        _ = backend_value.runtimes.remove(30);
        _ = backend_value.runtimes.remove(40);
    }
    const adapter_generation = pool.adapterGeneration(91).?;
    try putCr5bRuntime(&backend_value, 10, &fixtures[0], 91, adapter_generation, 1, "000000000000000000000000000000c1".*);
    try putCr5bRuntime(&backend_value, 20, &fixtures[1], 91, adapter_generation, 2, "000000000000000000000000000000c2".*);
    try putCr5bRuntime(&backend_value, 30, &fixtures[2], 91, adapter_generation, 3, "000000000000000000000000000000c3".*);
    try putCr5bRuntime(&backend_value, 40, &fixtures[3], 92, 7, 4, "000000000000000000000000000000d1".*);
    var clock = struct {
        now_ns: i128 = 10,
        fn read(context: *anyopaque) i128 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_ns;
        }
    }{};
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        100,
    ));
    const job = try testing.allocator.create(HostReconnectJob);
    job.* = .{};
    backend_value.host_reconnect_job = job;
    defer {
        backend_value.host_reconnect_job = null;
        testing.allocator.destroy(job);
    }
    try job.prepareForConnect(&backend_value, 91, phase);
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(@as(u32, 3), job.runtime_row_count);

    const copied = try testing.allocator.create(HostReconnectJob);
    defer testing.allocator.destroy(copied);
    copied.* = job.*;
    try testing.expect(!copied.valid(&backend_value));
    try testing.expect(job.valid(&backend_value));

    job.runtime_rows[1].identity.runtime_id +%= 1;
    try testing.expect(!job.valid(&backend_value));
    job.runtime_rows[1].identity.runtime_id -%= 1;
    try testing.expect(job.valid(&backend_value));
    job.runtime_rows_digest[0] ^= 0x01;
    try testing.expect(!job.valid(&backend_value));
    job.runtime_rows_digest[0] ^= 0x01;
    try testing.expect(job.valid(&backend_value));
    job.runtime_row_count -= 1;
    try testing.expect(!job.valid(&backend_value));
    job.runtime_row_count += 1;
    try testing.expect(job.valid(&backend_value));

    const entry20 = backend_value.runtimes.getPtr(20).?;
    entry20.runtime_generation += 1;
    try testing.expect(!job.valid(&backend_value));
    entry20.runtime_generation -= 1;
    try testing.expect(job.valid(&backend_value));
    const runtime20_id = fixtures[1].runtime.runtime_id_hex;
    fixtures[1].runtime.runtime_id_hex = "000000000000000000000000000000ef".*;
    try testing.expect(!job.valid(&backend_value));
    fixtures[1].runtime.runtime_id_hex = runtime20_id;
    try testing.expect(job.valid(&backend_value));
    const runtime20 = entry20.runtime;
    entry20.runtime = &fixtures[0].runtime;
    try testing.expect(!job.valid(&backend_value));
    entry20.runtime = runtime20;
    try testing.expect(job.valid(&backend_value));
    const removed30 = backend_value.runtimes.fetchRemove(30).?;
    try testing.expect(!job.valid(&backend_value));
    try backend_value.runtimes.put(testing.allocator, removed30.key, removed30.value);
    try testing.expect(job.valid(&backend_value));
    const sibling_entry = backend_value.runtimes.getPtr(40).?;
    sibling_entry.host_id = 91;
    sibling_entry.host_adapter_generation = adapter_generation;
    try testing.expect(!job.valid(&backend_value));
    sibling_entry.host_id = 92;
    sibling_entry.host_adapter_generation = 7;
    try testing.expect(job.valid(&backend_value));

    job.* = .{};
    backend_value.host_reconnect_job = null;
    _ = backend_value.runtimes.remove(10);
    _ = backend_value.runtimes.remove(20);
    _ = backend_value.runtimes.remove(30);
    const empty = try testing.allocator.create(HostReconnectJob);
    defer testing.allocator.destroy(empty);
    empty.* = .{};
    backend_value.host_reconnect_job = empty;
    try testing.expectError(error.InvalidAuthority, empty.prepareForConnect(&backend_value, 91, phase));
    try testing.expect(empty.pristine());
    try testing.expectEqual(@as(u64, 1), backend_value.next_host_reconnect_job_generation);
    backend_value.host_reconnect_job = null;
}

test "CR6e-c3 main owner adopts only the exact bound worker candidate" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const identity = HostAdapter.publicationProcessIdentity() orelse return error.TestUnexpectedResult;

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var attach_peer = try std.Thread.spawn(
        .{},
        remote_runtime.testing_api.serveSemanticAttachPeers,
        .{ current_fds[1], @as(usize, 1) },
    );
    var attach_peer_joined = false;
    defer if (!attach_peer_joined) attach_peer.join();

    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    const adapter = pool.get(91).?;
    const adapter_generation = pool.adapterGeneration(91).?;
    const connection_generation = adapter.connectionGeneration();
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    var runtime: RemoteRuntime = undefined;
    try remote_runtime.testing_api.initSemanticRuntimeOnAdapter(
        &runtime,
        adapter,
        testing.allocator,
        "000000000000000000000000000000c3".*,
        1,
    );
    attach_peer.join();
    attach_peer_joined = true;
    defer remote_runtime.testing_api.deinitSemanticRuntimeOnAdapter(&runtime);
    try backend_value.runtimes.put(testing.allocator, 1, .{
        .runtime = &runtime,
        .host_id = 91,
        .host_adapter_generation = adapter_generation,
        .runtime_generation = 1,
    });
    defer _ = backend_value.runtimes.remove(1);

    const incident_nonce = (@as(u128, 1) << 96) | 0xC3;
    const projection: reconnect_admission_owner.Projection = .{
        .slot_index = 0,
        .slot_generation = 1,
        .host_id = 91,
        .host_adapter_generation = adapter_generation,
        .connection_generation = connection_generation,
        .incident_id = .{ .app_instance_nonce = incident_nonce, .sequence = 7 },
    };
    var budget: reconnect_resident_budget.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    try RemoteRuntime.backend_api.bindReconnectAdmission(
        &runtime,
        &budget,
        projection,
        reconnect_resident_budget.max_entry_bytes,
    );
    defer {
        remote_runtime.testing_api.releaseBoundReconnectAdmission(&runtime, &budget) catch unreachable;
        budget.deinit() catch unreachable;
    }

    var fresh_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fresh_fds));
    defer _ = c.close(fresh_fds[1]);
    var fresh: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fresh_fds[0],
        .host_id = 91,
        .runtime_catchup_barrier_v1 = true,
        .connection_profile = .gui,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var fresh_owned = true;
    defer if (fresh_owned) fresh.deinit();
    var clock = struct {
        now_ns: i128 = 10,
        fn read(context: *anyopaque) i128 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_ns;
        }
    }{};
    const deadline_ns: u64 = 100;
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        deadline_ns,
    ));
    const snapshot: reconnect_worker_owner.Snapshot = .{
        .host_id = 91,
        .pool_membership_generation = adapter_generation,
        .connection_generation = connection_generation,
        .incident_app_instance_nonce = incident_nonce,
        .incident_sequence = 7,
        .absolute_deadline_ns = deadline_ns,
    };
    var stale = snapshot;
    stale.incident_app_instance_nonce = 1;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectCandidate(stale, phase, &fresh),
    );
    try testing.expectEqual(@as(c.fd_t, fresh_fds[0]), fresh.fd);
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    stale = snapshot;
    stale.incident_sequence += 1;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectCandidate(stale, phase, &fresh),
    );
    stale = snapshot;
    stale.connection_generation += 1;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectCandidate(stale, phase, &fresh),
    );
    stale = snapshot;
    stale.pool_membership_generation += 1;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectCandidate(stale, phase, &fresh),
    );
    stale = snapshot;
    stale.absolute_deadline_ns += 1;
    try testing.expectEqual(
        HostReconnectStart.invalid_authority,
        backend_value.beginHostReconnectCandidate(stale, phase, &fresh),
    );
    try testing.expectEqual(@as(c.fd_t, fresh_fds[0]), fresh.fd);
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expectEqual(
        HostReconnectStart.connected,
        backend_value.beginHostReconnectCandidate(snapshot, phase, &fresh),
    );
    fresh_owned = false;
    try testing.expectEqual(@as(c.fd_t, fresh_fds[0]), backend_value.host_reconnect_job.?.client.?.fd);
    try backend_value.abortHostReconnectConnect();
}

test "CR5b-2a host job은 three-runtime retirement를 모두 준비한 뒤 mutation 없이 abort한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var attach_peer = try std.Thread.spawn(
        .{},
        remote_runtime.testing_api.serveSemanticAttachPeers,
        .{ current_fds[1], @as(usize, 3) },
    );
    var attach_peer_joined = false;
    defer if (!attach_peer_joined) attach_peer.join();

    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    const adapter = pool.get(91).?;
    const adapter_generation = pool.adapterGeneration(91).?;
    const connection_generation_before = adapter.connectionGeneration();
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    var runtimes: [3]RemoteRuntime = undefined;
    var initialized: usize = 0;
    defer {
        var index = initialized;
        while (index > 0) {
            index -= 1;
            remote_runtime.testing_api.deinitSemanticRuntimeOnAdapter(&runtimes[index]);
        }
    }
    const ids = [_][32]u8{
        "000000000000000000000000000000a1".*,
        "000000000000000000000000000000a2".*,
        "000000000000000000000000000000a3".*,
    };
    for (&runtimes, 0..) |*runtime, index| {
        try remote_runtime.testing_api.initSemanticRuntimeOnAdapter(
            runtime,
            adapter,
            testing.allocator,
            ids[index],
            @intCast(index + 1),
        );
        initialized += 1;
        try backend_value.runtimes.put(testing.allocator, @intCast((index + 1) * 10), .{
            .runtime = runtime,
            .host_id = 91,
            .host_adapter_generation = adapter_generation,
            .runtime_generation = @intCast(index + 1),
        });
    }
    attach_peer.join();
    attach_peer_joined = true;
    defer {
        _ = backend_value.runtimes.remove(10);
        _ = backend_value.runtimes.remove(20);
        _ = backend_value.runtimes.remove(30);
    }

    var fresh_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fresh_fds));
    defer _ = c.close(fresh_fds[1]);
    var fresh: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fresh_fds[0],
        .host_id = 91,
        .runtime_catchup_barrier_v1 = true,
        .connection_profile = .gui,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var clock = struct {
        now_ns: i128 = 10,
        fn read(context: *anyopaque) i128 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_ns;
        }
    }{};
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        100,
    ));
    const job = try testing.allocator.create(HostReconnectJob);
    job.* = .{};
    backend_value.host_reconnect_job = job;
    var job_owned = true;
    defer if (job_owned) {
        if (job.client) |*owned| owned.deinit();
        backend_value.host_reconnect_job = null;
        testing.allocator.destroy(job);
    };
    try job.prepareForConnect(&backend_value, 91, phase);
    try testing.expectEqual(HostReconnectStart.connected, job.adoptConnected(
        &backend_value,
        91,
        phase,
        &fresh,
    ));
    const generations_before = [_]u64{
        (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(&runtimes[0])).shell_generation,
        (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(&runtimes[1])).shell_generation,
        (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(&runtimes[2])).shell_generation,
    };

    for (0..runtimes.len) |busy_index| {
        remote_runtime.testing_api.setHostRetirementBusy(&runtimes[busy_index], true);
        try testing.expectError(error.Busy, backend_value.prepareHostReconnectRuntimeRetirements());
        remote_runtime.testing_api.setHostRetirementBusy(&runtimes[busy_index], false);
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(@intFromEnum(HostReconnectJobState.connected), job.state_raw);
        try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
        for (&runtimes, 0..) |*runtime, index| {
            try testing.expectEqual(
                generations_before[index],
                (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(runtime)).shell_generation,
            );
            try testing.expect(!RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
                runtime,
                adapter,
                @intFromPtr(job),
                job.job_generation,
            ));
            try testing.expect(remote_runtime.testing_api.hostRetirementPristine(runtime));
        }
    }

    for (0..runtimes.len) |corrupt_index| {
        const previous = remote_runtime.testing_api.setHostRetirementLifecycleRaw(
            &runtimes[corrupt_index],
            0xff,
        );
        try testing.expectError(
            error.InvalidOwner,
            backend_value.prepareHostReconnectRuntimeRetirements(),
        );
        _ = remote_runtime.testing_api.setHostRetirementLifecycleRaw(
            &runtimes[corrupt_index],
            previous,
        );
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(@intFromEnum(HostReconnectJobState.connected), job.state_raw);
        try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
        for (&runtimes, 0..) |*runtime, index| {
            try testing.expectEqual(
                generations_before[index],
                (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(runtime)).shell_generation,
            );
            try testing.expect(remote_runtime.testing_api.hostRetirementPristine(runtime));
        }
    }

    for (0..runtimes.len) |corrupt_index| {
        const previous = remote_runtime.testing_api.setHostRetirementPayloadReleaseStateRaw(
            &runtimes[corrupt_index],
            0xff,
        );
        try testing.expectError(
            error.InvalidOwner,
            backend_value.prepareHostReconnectRuntimeRetirements(),
        );
        _ = remote_runtime.testing_api.setHostRetirementPayloadReleaseStateRaw(
            &runtimes[corrupt_index],
            previous,
        );
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(@intFromEnum(HostReconnectJobState.connected), job.state_raw);
        try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
        for (&runtimes) |*runtime| try testing.expect(
            remote_runtime.testing_api.hostRetirementPristine(runtime),
        );
    }

    const drift_entry = backend_value.runtimes.getPtr(20).?;
    drift_entry.runtime_generation += 1;
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.prepareHostReconnectRuntimeRetirements(),
    );
    drift_entry.runtime_generation -= 1;
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
    for (&runtimes) |*runtime| try testing.expect(
        remote_runtime.testing_api.hostRetirementPristine(runtime),
    );

    try backend_value.prepareHostReconnectRuntimeRetirements();
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(@intFromEnum(HostReconnectJobState.retirements_prepared), job.state_raw);
    for (&runtimes) |*runtime| try testing.expect(
        RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
            runtime,
            adapter,
            @intFromPtr(job),
            job.job_generation,
        ),
    );
    var copied_job = job.*;
    try testing.expect(!copied_job.valid(&backend_value));
    try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());

    try backend_value.abortHostReconnectConnect();
    job_owned = false;
    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
    try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
    for (&runtimes, 0..) |*runtime, index| {
        try testing.expectEqual(
            generations_before[index],
            (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(runtime)).shell_generation,
        );
        try testing.expect(remote_runtime.testing_api.hostRetirementPristine(runtime));
    }
}

test "CR5b-2b host job은 three-runtime을 unavailable로 만든 뒤 shared Client를 exact once 교체한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();

    var current_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &current_fds));
    var current: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = current_fds[0],
        .host_id = 91,
        .parser = framing.FrameParser.init(testing.allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var attach_peer = try std.Thread.spawn(
        .{},
        remote_runtime.testing_api.serveSemanticAttachPeers,
        .{ current_fds[1], @as(usize, 3) },
    );
    var attach_peer_joined = false;
    defer if (!attach_peer_joined) attach_peer.join();

    var pool = AdapterPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expectEqual(@as(u128, 91), try addOwnedClient(&pool, testing.allocator, &current));
    const adapter = pool.get(91).?;
    const adapter_generation = pool.adapterGeneration(91).?;
    const connection_generation_before = adapter.connectionGeneration();
    var backend_value = RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        &pool,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    defer while (adapter.slot.retiredClientCount() != 0) {
        var reclaim: client_slot_mod.PreparedRetiredClientReclaim = .{};
        adapter.prepareRetiredClientReclaim(&reclaim) catch
            process_seal.fatalIntegrity(.proof_loss);
        adapter.commitRetiredClientReclaimAtTickEndNoFail(&reclaim);
    };

    var runtimes: [3]RemoteRuntime = undefined;
    var initialized: usize = 0;
    defer {
        var index = initialized;
        while (index > 0) {
            index -= 1;
            remote_runtime.testing_api.deinitSemanticRuntimeOnAdapter(&runtimes[index]);
        }
    }
    const ids = [_][32]u8{
        "000000000000000000000000000000b1".*,
        "000000000000000000000000000000b2".*,
        "000000000000000000000000000000b3".*,
    };
    for (&runtimes, 0..) |*runtime, index| {
        try remote_runtime.testing_api.initSemanticRuntimeOnAdapter(
            runtime,
            adapter,
            testing.allocator,
            ids[index],
            @intCast(index + 1),
        );
        initialized += 1;
        try backend_value.runtimes.put(testing.allocator, @intCast((index + 1) * 10), .{
            .runtime = runtime,
            .host_id = 91,
            .host_adapter_generation = adapter_generation,
            .runtime_generation = @intCast(index + 1),
        });
    }
    attach_peer.join();
    attach_peer_joined = true;
    defer {
        _ = backend_value.runtimes.remove(10);
        _ = backend_value.runtimes.remove(20);
        _ = backend_value.runtimes.remove(30);
    }

    var fresh_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fresh_fds));
    defer _ = c.close(fresh_fds[1]);
    var fresh: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fresh_fds[0],
        .host_id = 91,
        .runtime_catchup_barrier_v1 = true,
        .connection_profile = .gui,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var clock = struct {
        now_ns: i128 = 10,
        fn read(context: *anyopaque) i128 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_ns;
        }
    }{};
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, .fromInjected(
        .{ .context = &clock, .now_ns = @TypeOf(clock).read },
        100,
    ));
    const job = try testing.allocator.create(HostReconnectJob);
    job.* = .{};
    backend_value.host_reconnect_job = job;
    defer {
        if (backend_value.host_reconnect_job) |active_job| {
            if (active_job.state_raw == @intFromEnum(HostReconnectJobState.shared_replacement_published)) {
                active_job.state_raw = @intFromEnum(HostReconnectJobState.idle);
                active_job.seal = [_]u8{0} ** 32;
                active_job.* = .{};
                backend_value.host_reconnect_job = null;
                testing.allocator.destroy(active_job);
            } else {
                backend_value.abortHostReconnectConnect() catch
                    process_seal.fatalIntegrity(.proof_loss);
            }
        }
    }
    try job.prepareForConnect(&backend_value, 91, phase);
    try testing.expectEqual(HostReconnectStart.connected, job.adoptConnected(
        &backend_value,
        91,
        phase,
        &fresh,
    ));
    try backend_value.prepareHostReconnectRuntimeRetirements();
    // CR5 advances this prepared state and the shared-replacement state on separate AppKit
    // frames. An ordinary surface read between them must neither block nor invalidate the sealed
    // job; this is the product ordering that exposed the retained stable-screen writer gate.
    for (&runtimes) |*runtime| {
        runtime.surface.lockCore(testing.io);
        _ = runtime.surface.renderSnapshot();
        runtime.surface.unlockCore(testing.io);
    }
    try testing.expect(job.valid(&backend_value));
    try backend_value.prepareHostReconnectSharedReplacement();
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(
        @intFromEnum(HostReconnectJobState.shared_replacement_reserved),
        job.state_raw,
    );
    try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
    try testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
    for (&runtimes) |*runtime| try testing.expect(
        RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
            runtime,
            adapter,
            @intFromPtr(job),
            job.job_generation,
        ),
    );

    var copied_job = job.*;
    try testing.expect(!copied_job.valid(&backend_value));
    backend_value.host_reconnect_job = &copied_job;
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.commitHostReconnectSharedReplacement(),
    );
    backend_value.host_reconnect_job = job;
    try testing.expect(job.valid(&backend_value));
    job.replacement.slot_incarnation +%= 1;
    try testing.expect(!job.valid(&backend_value));
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.commitHostReconnectSharedReplacement(),
    );
    job.replacement.slot_incarnation -%= 1;
    try testing.expect(job.valid(&backend_value));
    job.job_generation +%= 1;
    try testing.expect(!job.valid(&backend_value));
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.commitHostReconnectSharedReplacement(),
    );
    job.job_generation -%= 1;
    try testing.expect(job.valid(&backend_value));
    job.replacement.old_node_incarnation +%= 1;
    try testing.expect(!job.valid(&backend_value));
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.commitHostReconnectSharedReplacement(),
    );
    job.replacement.old_node_incarnation -%= 1;
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(connection_generation_before, adapter.connectionGeneration());
    for (&runtimes) |*runtime| try testing.expect(
        RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
            runtime,
            adapter,
            @intFromPtr(job),
            job.job_generation,
        ),
    );

    B5TestState.cr5b2b_runtime_commit_count = 0;
    B5TestState.cr5b2b_retired_counts = .{0} ** 3;
    try backend_value.commitHostReconnectSharedReplacement();
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(
        @intFromEnum(HostReconnectJobState.shared_replacement_published),
        job.state_raw,
    );
    try testing.expectEqual(connection_generation_before + 1, adapter.connectionGeneration());
    try testing.expectEqual(@as(usize, 1), adapter.slot.retiredClientCount());
    try testing.expectEqual(@as(usize, 3), B5TestState.cr5b2b_runtime_commit_count);
    try testing.expectEqual([3]usize{ 0, 0, 0 }, B5TestState.cr5b2b_retired_counts);
    try testing.expectEqual(@as(?client_mod.Client, null), job.client);
    for (&runtimes) |*runtime| try testing.expect(
        RemoteRuntime.backend_api.hostWideRetirementCommittedExact(runtime, adapter),
    );
    try testing.expectError(
        error.InvalidHostReconnectJob,
        backend_value.commitHostReconnectSharedReplacement(),
    );
}

const Cr4aActualIssuerCandidateCase = enum {
    success,
    expired,
    rejected,
    mutation_sealed,
    controller_evidenced,
    controller_promoted,
    controller_published,
    controller_publish_expired,
    controller_publication_proof_loss,
    controller_conflict_ledger,
    controller_unknown_ledger,
    controller_pre_failed_ledger,
    multi_runtime_success,
    driver_multi_runtime_success,
    coordinator_success,
    multi_runtime_conflict_1,
    multi_runtime_conflict_2,
    multi_runtime_conflict_3,
    multi_runtime_terminal_after_success,
};

fn cr5b2cFailureIndex(selected: Cr4aActualIssuerCandidateCase) ?usize {
    return switch (selected) {
        .multi_runtime_conflict_1 => 0,
        .multi_runtime_conflict_2 => 1,
        .multi_runtime_conflict_3 => 2,
        .multi_runtime_terminal_after_success => 1,
        else => null,
    };
}

fn runCr4aActualIssuerReplacementStage(selected: Cr4aActualIssuerCandidateCase) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    const io = testing.io;
    const ClockFixture = struct {
        now_ns: i128 = 0,

        fn now(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }
    };
    var deadline_clock: ClockFixture = .{};
    const deadline_expires_at_ns: i128 = 10 * std.time.ns_per_s;

    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-cr4-job-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4352344A4F42;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    // An interrupted fixture can leave the pathname behind after its daemon has gone. Do not let
    // that stale readiness observation send the next run into a blocking hello on the wrong cut.
    _ = c.unlink(socket.ptr);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        if (selected != .controller_publication_proof_loss) _ = c.setsid();
        _ = unsetenv("MARU_SESSION_HOST_TEST_ONESHOT");
        daemon.runSessionHostWithIdentity(std.heap.page_allocator, io, dir, socket, host_id) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var path_buf: [832]u8 = undefined;
        if (host_manifest.manifestPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        if (host_manifest.ownerLockPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        std.Io.Dir.cwd().deleteTree(io, base) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
    }

    // SocketServer binds before the daemon finishes manifest/rollback preparation. A plain
    // blocking connect can therefore complete at the kernel backlog and then wait forever for
    // hello_ack while the daemon is still preparing (or has failed). Poll only for endpoint
    // publication, then bound connect readiness + the complete hello exchange with one deadline.
    var attempts: usize = 0;
    while (attempts < 200 and c.access(socket.ptr, c.F_OK) != 0) : (attempts += 1)
        _ = usleep(20 * 1000);
    try testing.expect(c.access(socket.ptr, c.F_OK) == 0);
    const initial_connect_deadline = try client_deadline.AbsoluteDeadline.after(
        io,
        30 * std.time.ns_per_s,
    );
    var initial = try client_mod.Client.connectUntil(
        allocator,
        socket,
        .gui,
        protocol.version_major,
        initial_connect_deadline,
    );
    var pool = AdapterPool.init(allocator);
    defer pool.deinit();
    try testing.expectEqual(host_id, try addOwnedClient(&pool, allocator, &initial));
    try pool.setSpawnHost(host_id);

    var surface_runtime = SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();
    var backend_value = try RemoteTermBackend.initWithPool(
        allocator,
        io,
        &pool,
        &surface_runtime,
    );
    try backend_value.claimProductSingleton();
    var backend_owned = true;
    defer if (backend_owned) backend_value.deinit();
    const size = maru.terminal.Size{ .cols = 80, .rows = 24 };
    const multi_runtime = selected == .multi_runtime_success or
        selected == .driver_multi_runtime_success or selected == .coordinator_success or
        cr5b2cFailureIndex(selected) != null;
    const runtime_count: usize = if (multi_runtime) 3 else 1;
    for (0..runtime_count) |index| _ = try backend_value.backend().spawn(.{
        .handle = @intCast(index + 1),
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });
    try testing.expectEqual(runtime_count, backend_value.runtimes.count());
    const initial_connection_generation = pool.get(host_id).?.connectionGeneration();
    if (selected == .coordinator_success) {
        const hook = B5TestState.reconnect_coordinator_hook orelse return error.InvalidTestState;
        try hook(&backend_value, .{
            .cache_base = base,
            .host_id = host_id,
            .host_adapter_generation = pool.adapterGeneration(host_id) orelse
                return error.InvalidTestState,
            .connection_generation = initial_connection_generation,
        });
        return;
    }
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .connect_hello,
        client_deadline.AbsoluteDeadline.fromInjected(
            .{ .context = &deadline_clock, .now_ns = ClockFixture.now },
            deadline_expires_at_ns,
        ),
    );
    try testing.expectEqual(
        HostReconnectStart.connected,
        backend_value.beginHostReconnectConnect(base, host_id, phase),
    );
    const job = backend_value.host_reconnect_job.?;
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(host_id, job.client.?.host_id);
    try testing.expectEqual(@intFromPtr(pool.get(host_id).?), job.adapter_addr);
    try testing.expectEqual(pool.adapterGeneration(host_id).?, job.adapter_generation);
    try testing.expect(job.client.?.runtime_catchup_barrier_v1);
    try testing.expect(phase.absolute.remainingNs() > 0);
    const connected_seal = job.seal;
    try testing.expectError(error.UnknownSurface, backend_value.publishHostReconnectReplacement(999));
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(connected_seal, job.seal);
    try testing.expectEqual(initial_connection_generation, pool.get(host_id).?.connectionGeneration());
    if (selected == .driver_multi_runtime_success) {
        var advanced: usize = 0;
        while (advanced < 64) : (advanced += 1) {
            const before = job.state_raw;
            switch (try backend_value.progressHostReconnectOne()) {
                .advanced => try testing.expect(before != job.state_raw),
                .retry_later => return error.TestUnexpectedResult,
                .retained_terminal_ready => return error.TestUnexpectedResult,
                .completed_ready => {
                    try testing.expectEqual(
                        HostReconnectTerminalKind.completed,
                        try backend_value.preflightHostReconnectTerminal(),
                    );
                    backend_value.finalizeCompletedHostReconnectNoFail();
                    try testing.expect(backend_value.host_reconnect_job == null);
                    try testing.expectEqual(@as(usize, 0), pool.get(host_id).?.slot.retiredClientCount());
                    return;
                },
            }
        }
        return error.TestUnexpectedResult;
    }
    if (multi_runtime) {
        try backend_value.prepareHostReconnectRuntimeRetirements();
        try backend_value.prepareHostReconnectSharedReplacement();
        try backend_value.commitHostReconnectSharedReplacement();
        try testing.expectEqual(
            @intFromEnum(HostReconnectJobState.shared_replacement_published),
            job.state_raw,
        );
        try testing.expectEqual(
            initial_connection_generation + 1,
            pool.get(host_id).?.connectionGeneration(),
        );
        const failure_index = cr5b2cFailureIndex(selected);
        var published_shell_generations = [_]u64{0} ** 3;
        var published_input_epochs = [_]u64{0} ** 3;
        for (0..runtime_count) |index| {
            const handle: RuntimeHandle = @intCast(index + 1);
            try testing.expectEqual(handle, try backend_value.beginNextHostReconnectRuntimeTransaction());
            if (failure_index != null and failure_index.? == index) {
                if (selected == .multi_runtime_terminal_after_success) {
                    deadline_clock.now_ns = deadline_expires_at_ns;
                    try testing.expectError(
                        error.DeadlineExceeded,
                        backend_value.prepareHostReconnectObserverStage(handle),
                    );
                    try testing.expectEqual(
                        @intFromEnum(HostReconnectJobState.candidate_failed),
                        job.state_raw,
                    );
                    try testing.expect(job.valid(&backend_value));
                    // Remove the second runtime from the backend map after the first publication.
                    // The host-wide preflight must unwind the first row and preserve the job
                    // before restoring the exact row allows a later clean retry to commit.
                    const adapter = pool.get(host_id).?;
                    const first_published = backend_value.runtimes.get(job.runtime_rows[0].identity.runtime_handle).?;
                    const missing_handle = job.runtime_rows[1].identity.runtime_handle;
                    const missing_entry = backend_value.runtimes.get(missing_handle).?;
                    try testing.expect(backend_value.runtimes.remove(missing_handle));
                    const job_before_preflight_reject = job.*;
                    try testing.expectError(
                        error.InvalidHostReconnectJob,
                        backend_value.failHostReconnectRuntimeTransactionsAfterSharedClientTerminal(),
                    );
                    try testing.expectEqualDeep(job_before_preflight_reject, job.*);
                    try testing.expect(!RemoteRuntime.backend_api.hostWideRetirementPreparedExact(
                        first_published.runtime,
                        adapter,
                        @intFromPtr(job),
                        job.job_generation,
                    ));
                    try backend_value.runtimes.put(allocator, missing_handle, missing_entry);
                    const summary = try backend_value
                        .failHostReconnectRuntimeTransactionsAfterSharedClientTerminal();
                    try testing.expect(job.valid(&backend_value));
                    try testing.expectEqual(@as(u32, 0), summary.published_new);
                    try testing.expectEqual(@as(u32, 3), summary.frozen_unavailable);
                    try testing.expectEqual(@as(u32, 3), summary.retry_reserved);
                    try testing.expectEqual(
                        @intFromEnum(HostReconnectJobState.host_failure_complete),
                        job.state_raw,
                    );
                    try testing.expectEqual(@as(u32, 3), job.runtime_cursor.next_index);
                    try testing.expectEqual(@as(i32, -1), host_adapter_mod.HostAdapter.testing.rawClient(
                        pool.get(host_id).?,
                    ).fd);
                    try testing.expectEqual(@as(usize, 1), pool.get(host_id).?.slot.retiredClientCount());
                    try testing.expectEqual(
                        client_slot_mod.PreparedClientReplacement.Lifecycle.published,
                        job.replacement.lifecycle,
                    );
                    for (job.runtime_rows[0..runtime_count], 0..) |row, row_index| {
                        try testing.expectEqual(
                            @intFromEnum(host_reconnect_runtime_ledger.LocalState.frozen_unavailable),
                            row.local_raw,
                        );
                        try testing.expectEqual(
                            @intFromEnum(host_reconnect_runtime_ledger.MutationState.closed),
                            row.mutation_raw,
                        );
                        try testing.expectEqual(
                            @intFromEnum(if (row_index == 0)
                                host_reconnect_runtime_ledger.RuntimeLedger.new_controller_evidenced
                            else
                                host_reconnect_runtime_ledger.RuntimeLedger.old_valid),
                            row.ledger_raw,
                        );
                    }
                    if (B5TestState.cr5d2_window_hook) |hook| {
                        try hook(&backend_value);
                        return;
                    }
                    try testing.expectError(
                        error.InvalidHostReconnectJob,
                        backend_value.failHostReconnectRuntimeTransactionsAfterSharedClientTerminal(),
                    );
                    return;
                }
                _ = try backend_value.prepareHostReconnectObserverStage(handle);
                try testing.expectEqual(
                    reconnect_mutation_seal.SealResult.sealed_clean,
                    try backend_value.sealHostReconnectMutations(handle),
                );
                backend_value.finishHostReconnectTakeoverOutcome(
                    job,
                    backend_value.runtimes.get(handle).?,
                    pool.get(host_id).?,
                    .authority_conflict,
                );
                try pool.get(host_id).?.preflightAttachmentConnectionUsable();
                const summary = try backend_value.failHostReconnectRuntimeTransactions();
                try testing.expectEqual(@as(u32, @intCast(index)), summary.published_new);
                try testing.expectEqual(@as(u32, @intCast(runtime_count - index)), summary.frozen_unavailable);
                try testing.expectEqual(@as(u32, 0), summary.published_old);
                try testing.expectEqual(
                    @intFromEnum(HostReconnectJobState.runtime_transactions_complete),
                    job.state_raw,
                );
                try testing.expect(job.valid(&backend_value));
                try testing.expectEqual(@as(usize, 1), pool.get(host_id).?.slot.retiredClientCount());
                try testing.expectEqual(
                    client_slot_mod.PreparedClientReplacement.Lifecycle.published,
                    job.replacement.lifecycle,
                );
                try pool.get(host_id).?.preflightAttachmentConnectionUsable();
                for (job.runtime_rows[0..runtime_count], 0..) |row, row_index| {
                    const expected_ledger: host_reconnect_runtime_ledger.RuntimeLedger =
                        if (row_index < index)
                            .new_controller_evidenced
                        else if (row_index == index)
                            .authority_conflict
                        else
                            .old_valid;
                    try testing.expectEqual(@intFromEnum(expected_ledger), row.ledger_raw);
                }
                for (0..index) |published_index| {
                    const published_runtime = backend_value.runtimes.get(
                        @intCast(published_index + 1),
                    ).?.runtime;
                    try testing.expectEqual(
                        published_shell_generations[published_index],
                        (try RemoteRuntime.backend_api.reconnectRuntimeSetIdentity(
                            published_runtime,
                        )).shell_generation,
                    );
                    try testing.expectEqual(
                        published_input_epochs[published_index],
                        published_runtime.input_batches.epoch,
                    );
                }
                var copied_terminal = job.*;
                try testing.expect(!copied_terminal.valid(&backend_value));
                const terminal_row = job.runtime_rows[0];
                job.runtime_rows[0].local_raw = @intFromEnum(
                    host_reconnect_runtime_ledger.LocalState.published_old,
                );
                try testing.expect(!job.valid(&backend_value));
                job.runtime_rows[0] = terminal_row;
                try testing.expect(job.valid(&backend_value));
                const identity_runtime = backend_value.runtimes.get(1).?.runtime;
                const runtime_id_before = identity_runtime.runtime_id_hex;
                identity_runtime.runtime_id_hex[0] = if (runtime_id_before[0] == '0') '1' else '0';
                try testing.expect(!job.valid(&backend_value));
                identity_runtime.runtime_id_hex = runtime_id_before;
                try testing.expect(job.valid(&backend_value));
                try testing.expectError(
                    error.InvalidHostReconnectJob,
                    backend_value.failHostReconnectRuntimeTransactions(),
                );
                const terminal_adapter = pool.get(host_id).?;
                backend_value.deinit();
                backend_owned = false;
                try testing.expectEqual(@as(usize, 0), terminal_adapter.slot.retiredClientCount());
                return;
            }
            _ = try backend_value.prepareHostReconnectObserverStage(handle);
            try testing.expectEqual(
                reconnect_mutation_seal.SealResult.sealed_clean,
                try backend_value.sealHostReconnectMutations(handle),
            );
            const outcome = try backend_value.executeHostReconnectTakeover(handle);
            switch (outcome) {
                .new_controller_evidenced => {},
                else => return error.TestUnexpectedResult,
            }
            try backend_value.promoteHostReconnectControllerBinding(handle);
            try backend_value.publishHostReconnectGeneration(handle);
            published_shell_generations[index] = (try RemoteRuntime.backend_api
                .reconnectRuntimeSetIdentity(backend_value.runtimes.get(handle).?.runtime)).shell_generation;
            published_input_epochs[index] = backend_value.runtimes.get(handle).?.runtime.input_batches.epoch;
            try testing.expectEqual(
                @intFromEnum(HostReconnectJobState.shared_replacement_published),
                job.state_raw,
            );
            try testing.expect(job.valid(&backend_value));
        }
        const summary = try backend_value.completeHostReconnectRuntimeTransactions();
        try testing.expectEqual(@as(u32, 3), summary.published_new);
        try testing.expectEqual(@as(u32, 0), summary.published_old);
        try testing.expectEqual(@as(u32, 0), summary.frozen_unavailable);
        try testing.expectEqual(
            @intFromEnum(HostReconnectJobState.runtime_transactions_complete),
            job.state_raw,
        );
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(@as(usize, 0), pool.get(host_id).?.slot.retiredClientCount());
        try testing.expect(std.meta.eql(
            job.replacement,
            client_slot_mod.PreparedClientReplacement{},
        ));
        var copied_terminal = job.*;
        try testing.expect(!copied_terminal.valid(&backend_value));
        const terminal_row = job.runtime_rows[0];
        job.runtime_rows[0].local_raw = @intFromEnum(
            host_reconnect_runtime_ledger.LocalState.published_old,
        );
        try testing.expect(!job.valid(&backend_value));
        job.runtime_rows[0] = terminal_row;
        try testing.expect(job.valid(&backend_value));
        const identity_runtime = backend_value.runtimes.get(1).?.runtime;
        const runtime_id_before = identity_runtime.runtime_id_hex;
        identity_runtime.runtime_id_hex[0] = if (runtime_id_before[0] == '0') '1' else '0';
        try testing.expect(!job.valid(&backend_value));
        identity_runtime.runtime_id_hex = runtime_id_before;
        try testing.expect(job.valid(&backend_value));
        try testing.expectError(
            error.InvalidHostReconnectJob,
            backend_value.completeHostReconnectRuntimeTransactions(),
        );
        return;
    }
    try backend_value.publishHostReconnectReplacement(1);
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(
        @intFromEnum(HostReconnectJobState.replacement_published),
        job.state_raw,
    );
    try testing.expect(job.client == null);
    try testing.expectEqual(@as(RuntimeHandle, 1), job.runtime_handle);
    try testing.expectEqual(
        initial_connection_generation + 1,
        pool.get(host_id).?.connectionGeneration(),
    );
    try testing.expectEqual(
        client_slot_mod.PreparedClientReplacement.Lifecycle.published,
        job.replacement.lifecycle,
    );
    try pool.get(host_id).?.preflightPublishedClientReplacement(&job.replacement);
    if (selected == .expired) {
        deadline_clock.now_ns = deadline_expires_at_ns;
        try testing.expectError(
            error.DeadlineExceeded,
            backend_value.prepareHostReconnectObserverStage(1),
        );
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(
            @intFromEnum(HostReconnectJobState.candidate_failed),
            job.state_raw,
        );
        try testing.expectEqual(@as(u128, 0), job.request_nonce);
        try testing.expectEqual(
            @intFromEnum(@import("client_poison.zig").ConnectionReason.read_timeout) + 1,
            job.candidate_failure_reason_raw,
        );
        try testing.expect(job.stage == null);
        try testing.expect(std.meta.eql(job.reconnect, remote_runtime.PreparedReconnect{}));
        try testing.expectEqual(@as(i32, -1), host_adapter_mod.HostAdapter.testing.rawClient(
            pool.get(host_id).?,
        ).fd);
        const failure_reason_raw = job.candidate_failure_reason_raw;
        const failure_seal = job.seal;
        job.candidate_failure_reason_raw =
            @intFromEnum(@import("client_poison.zig").ConnectionReason.peer_contract_violation) + 1;
        job.seal = process_seal.hostReconnectJobSeal(
            job.pid,
            job.process_nonce,
            job.sealInput() orelse return error.TestUnexpectedResult,
        ) catch return error.TestUnexpectedResult;
        try testing.expect(!job.valid(&backend_value));
        job.candidate_failure_reason_raw = failure_reason_raw;
        job.seal = failure_seal;
        try testing.expect(job.valid(&backend_value));
        try testing.expectError(
            error.InvalidHostReconnectJob,
            backend_value.prepareHostReconnectObserverStage(1),
        );
        return;
    }
    if (selected == .rejected) {
        const request_nonce: u128 = 0x4352344152454A454354;
        switch (classifyCandidatePrepareFailure(error.ObserverAttachRejected)) {
            .rejected_usable => {},
            .terminal => return error.TestUnexpectedResult,
        }
        backend_value.sealHostReconnectCandidateRejected(job, pool.get(host_id).?, request_nonce);
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(
            @intFromEnum(HostReconnectJobState.candidate_rejected),
            job.state_raw,
        );
        try testing.expectEqual(request_nonce, job.request_nonce);
        try testing.expectEqual(@as(u8, 0), job.candidate_failure_reason_raw);
        try pool.get(host_id).?.preflightAttachmentConnectionUsable();
        try testing.expectError(
            error.InvalidHostReconnectJob,
            backend_value.prepareHostReconnectObserverStage(1),
        );
        return;
    }
    const stage = try backend_value.prepareHostReconnectObserverStage(1);
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(
        @intFromEnum(HostReconnectJobState.candidate_staged),
        job.state_raw,
    );
    try testing.expectEqual(stage, job.stage.?);
    try testing.expectEqual(job.request_nonce, stage.identity.request_nonce);
    try testing.expectEqual(host_id, stage.identity.host_id);
    try testing.expectEqual(stage.snapshot, stage.target);
    try testing.expectEqual(@as(u64, 0), stage.accounting.batches);
    try testing.expectEqual(phase.absolute.expires_at_ns, stage.deadline_expires_at_ns);
    var copied = job.*;
    try testing.expect(!copied.valid(&backend_value));
    const runtime_generation = job.runtime_generation;
    job.runtime_generation +%= 1;
    try testing.expect(!job.valid(&backend_value));
    job.runtime_generation = runtime_generation;
    const replacement_generation = job.replacement.next_connection_generation;
    job.replacement.next_connection_generation +%= 1;
    try testing.expect(!job.valid(&backend_value));
    job.replacement.next_connection_generation = replacement_generation;
    try testing.expect(job.valid(&backend_value));
    const mutable_stage = @constCast(stage);
    mutable_stage.identity.request_nonce +%= 1;
    try testing.expect(!job.valid(&backend_value));
    mutable_stage.identity.request_nonce -%= 1;
    try testing.expect(job.valid(&backend_value));
    const state_raw = job.state_raw;
    job.state_raw = @intFromEnum(HostReconnectJobState.mutation_sealed);
    try testing.expect(!job.valid(&backend_value));
    job.state_raw = state_raw;
    for (8..256) |raw| {
        job.state_raw = @intCast(raw);
        try testing.expect(!job.valid(&backend_value));
    }
    job.state_raw = state_raw;
    try testing.expect(job.valid(&backend_value));
    try testing.expectError(error.InvalidHostReconnectJob, backend_value.publishHostReconnectReplacement(1));
    try testing.expectError(error.InvalidHostReconnectJob, backend_value.prepareHostReconnectObserverStage(1));
    try testing.expectError(error.Busy, backend_value.abortHostReconnectConnect());
    try testing.expectEqual(job, backend_value.host_reconnect_job.?);
    if (selected == .mutation_sealed or selected == .controller_evidenced or
        selected == .controller_promoted or selected == .controller_published or
        selected == .controller_publish_expired or selected == .controller_publication_proof_loss or
        selected == .controller_conflict_ledger or selected == .controller_unknown_ledger or
        selected == .controller_pre_failed_ledger)
    {
        try testing.expectEqual(
            reconnect_mutation_seal.SealResult.sealed_clean,
            try backend_value.sealHostReconnectMutations(1),
        );
        try testing.expect(job.valid(&backend_value));
        try testing.expectEqual(
            @intFromEnum(HostReconnectJobState.mutation_sealed),
            job.state_raw,
        );
        try testing.expect(!std.mem.allEqual(u8, &job.mutation_digest, 0));
        try testing.expectError(
            error.InvalidHostReconnectJob,
            backend_value.sealHostReconnectMutations(1),
        );
        if (selected == .controller_evidenced or selected == .controller_promoted or
            selected == .controller_published or selected == .controller_publish_expired or
            selected == .controller_publication_proof_loss)
        {
            const outcome = try backend_value.executeHostReconnectTakeover(1);
            switch (outcome) {
                .new_controller_evidenced => |generation| {
                    try testing.expect(generation > 0);
                    try testing.expectEqual(generation, job.controller_generation);
                },
                else => return error.TestUnexpectedResult,
            }
            try testing.expect(job.valid(&backend_value));
            try testing.expectEqual(
                @intFromEnum(HostReconnectJobState.controller_evidenced),
                job.state_raw,
            );
            try testing.expectError(
                error.InvalidHostReconnectJob,
                backend_value.executeHostReconnectTakeover(1),
            );
            if (selected == .controller_promoted or selected == .controller_published or
                selected == .controller_publish_expired or selected == .controller_publication_proof_loss)
            {
                const mutation_before = job.mutation_digest;
                try backend_value.promoteHostReconnectControllerBinding(1);
                try testing.expect(job.valid(&backend_value));
                try testing.expectEqual(
                    @intFromEnum(HostReconnectJobState.controller_promoted),
                    job.state_raw,
                );
                try testing.expect(std.crypto.timing_safe.eql(
                    process_seal.CleanupSeal,
                    mutation_before,
                    job.mutation_digest,
                ));
                try testing.expect(job.reconnect.candidate.active);
                try testing.expectError(
                    error.Unauthorized,
                    backend_value.runtimes.get(1).?.runtime.sendInput("CR4c C1 must stay sealed"),
                );
                try testing.expectError(
                    error.InvalidHostReconnectJob,
                    backend_value.promoteHostReconnectControllerBinding(1),
                );
                if (selected == .controller_published or selected == .controller_publication_proof_loss) {
                    const runtime = backend_value.runtimes.get(1).?.runtime;
                    const old_generation = runtime.mutation_owner.shell_generation;
                    const old_epoch = runtime.input_batches.epoch;
                    if (selected == .controller_publication_proof_loss)
                        B5TestState.cr4c_publication_drift = true;
                    remote_runtime.testing_api.armOrderedReconnectReclaimTrace();
                    defer remote_runtime.testing_api.disarmOrderedReconnectReclaimTrace();
                    try backend_value.publishHostReconnectGeneration(1);
                    try testing.expectEqual(
                        [_]u8{ 1, 2 },
                        remote_runtime.testing_api.orderedReconnectReclaimTrace(),
                    );
                    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
                    try testing.expect(runtime.mutation_owner.shell_generation > old_generation);
                    try testing.expectEqual(old_epoch + 1, runtime.input_batches.epoch);
                    try testing.expectEqual(
                        reconnect_mutation_seal.MutationLifecycle.open,
                        runtime.mutation_owner.lifecycle,
                    );
                    try testing.expectEqual(@as(usize, 0), pool.get(host_id).?.slot.retiredClientCount());
                    try testing.expect(!(try runtime.generation_owner.slot.hasRetiring()));
                    try runtime.sendInput("CR4c C2 input\n");
                    return;
                }
                if (selected == .controller_publish_expired) {
                    deadline_clock.now_ns = deadline_expires_at_ns;
                    try testing.expectError(
                        error.DeadlineExceeded,
                        backend_value.publishHostReconnectGeneration(1),
                    );
                    try testing.expect(job.valid(&backend_value));
                    try testing.expectEqual(
                        @intFromEnum(HostReconnectJobState.candidate_failed),
                        job.state_raw,
                    );
                    try testing.expect(job.stage == null);
                    try testing.expectEqual(@as(u64, 0), job.controller_generation);
                    try testing.expect(!std.mem.allEqual(u8, &job.mutation_digest, 0));
                    try testing.expectEqual(
                        @intFromEnum(@import("client_poison.zig").ConnectionReason.read_timeout) + 1,
                        job.candidate_failure_reason_raw,
                    );
                    try testing.expectEqual(@as(i32, -1), host_adapter_mod.HostAdapter.testing.rawClient(
                        pool.get(host_id).?,
                    ).fd);
                    const canonical_digest = job.mutation_digest;
                    const canonical_seal = job.seal;
                    job.mutation_digest[0] ^= 1;
                    job.seal = process_seal.hostReconnectJobSeal(
                        job.pid,
                        job.process_nonce,
                        job.sealInput() orelse return error.TestUnexpectedResult,
                    ) catch return error.TestUnexpectedResult;
                    try testing.expect(!job.valid(&backend_value));
                    job.mutation_digest = canonical_digest;
                    job.seal = canonical_seal;
                    try testing.expect(job.valid(&backend_value));
                    try testing.expectError(
                        error.InvalidHostReconnectJob,
                        backend_value.publishHostReconnectGeneration(1),
                    );
                    return;
                }
            }
        } else if (selected == .controller_conflict_ledger or
            selected == .controller_unknown_ledger or selected == .controller_pre_failed_ledger)
        {
            const injected: generation_attachment_mod.GenerationAttachment.ControllerTransferOutcome =
                if (selected == .controller_conflict_ledger)
                    .authority_conflict
                else if (selected == .controller_unknown_ledger)
                    .takeover_sent_unknown
                else
                    .pre_takeover_failed;
            backend_value.finishHostReconnectTakeoverOutcome(
                job,
                backend_value.runtimes.get(1).?,
                pool.get(host_id).?,
                injected,
            );
            try testing.expect(job.valid(&backend_value));
            try testing.expect(job.stage == null);
            try testing.expect(std.meta.eql(job.reconnect, remote_runtime.PreparedReconnect{}));
            try testing.expect(!std.mem.allEqual(u8, &job.mutation_digest, 0));
            try testing.expectEqual(@as(u64, 0), job.controller_generation);
            if (selected == .controller_conflict_ledger) {
                try testing.expectEqual(
                    @intFromEnum(HostReconnectJobState.authority_conflict),
                    job.state_raw,
                );
                try testing.expectEqual(@as(u8, 0), job.candidate_failure_reason_raw);
                try pool.get(host_id).?.preflightAttachmentConnectionUsable();
                const canonical_seal = job.seal;
                job.candidate_failure_reason_raw =
                    @intFromEnum(@import("client_poison.zig").ConnectionReason.peer_contract_violation) + 1;
                job.seal = process_seal.hostReconnectJobSeal(
                    job.pid,
                    job.process_nonce,
                    job.sealInput() orelse return error.TestUnexpectedResult,
                ) catch return error.TestUnexpectedResult;
                try testing.expect(!job.valid(&backend_value));
                job.candidate_failure_reason_raw = 0;
                job.seal = canonical_seal;
            } else {
                const expected_state = if (selected == .controller_unknown_ledger)
                    HostReconnectJobState.takeover_sent_unknown
                else
                    HostReconnectJobState.pre_takeover_failed;
                const expected_reason = if (selected == .controller_unknown_ledger)
                    @import("client_poison.zig").ConnectionReason.response_correlation_lost
                else
                    @import("client_poison.zig").ConnectionReason.local_invariant_violation;
                try testing.expectEqual(@intFromEnum(expected_state), job.state_raw);
                try testing.expectEqual(
                    @intFromEnum(expected_reason) + 1,
                    job.candidate_failure_reason_raw,
                );
                try pool.get(host_id).?.preflightAttachmentConnectionFailedClosed(expected_reason);
                const canonical_reason_raw = job.candidate_failure_reason_raw;
                const canonical_seal = job.seal;
                job.candidate_failure_reason_raw =
                    @intFromEnum(@import("client_poison.zig").ConnectionReason.peer_contract_violation) + 1;
                job.seal = process_seal.hostReconnectJobSeal(
                    job.pid,
                    job.process_nonce,
                    job.sealInput() orelse return error.TestUnexpectedResult,
                ) catch return error.TestUnexpectedResult;
                try testing.expect(!job.valid(&backend_value));
                job.candidate_failure_reason_raw = canonical_reason_raw;
                job.seal = canonical_seal;
            }
            try testing.expect(job.valid(&backend_value));
            try testing.expectError(
                error.InvalidHostReconnectJob,
                backend_value.executeHostReconnectTakeover(1),
            );
        }
        return;
    }
    deadline_clock.now_ns = deadline_expires_at_ns;
    try testing.expect(job.valid(&backend_value));
    try testing.expect(!RemoteRuntime.backend_api.validateReconnectObserverStage(
        backend_value.runtimes.get(1).?.runtime,
        pool.get(host_id).?,
        &job.replacement,
        &job.reconnect,
        job.stage.?,
        phase.absolute,
    ));
}

test "CR4a actual issuer job은 actual manifest socket Client를 same adapter replacement로 게시한다" {
    try runCr4aActualIssuerReplacementStage(.success);
}

test "CR4a actual issuer job은 expired shared deadline을 candidate 전에 fail close한다" {
    try runCr4aActualIssuerReplacementStage(.expired);
}

test "CR4a actual issuer job은 typed reject를 usable terminal state로 봉인한다" {
    try runCr4aActualIssuerReplacementStage(.rejected);
}

test "CR4b actual host job은 staged receipt 뒤 stable mutation을 exact once 봉인한다" {
    try runCr4aActualIssuerReplacementStage(.mutation_sealed);
}

test "CR4b actual host job은 status CAS takeover를 controller evidence로 exact once 봉인한다" {
    try runCr4aActualIssuerReplacementStage(.controller_evidenced);
}

test "CR4c C1 actual host job은 controller evidence binding을 unpublished candidate에서 승격한다" {
    try runCr4aActualIssuerReplacementStage(.controller_promoted);
}

test "CR4c C2 actual host job은 forced resize 뒤 generation을 게시하고 input과 ordered reclaim을 연다" {
    try runCr4aActualIssuerReplacementStage(.controller_published);
}

test "CR4c C2 actual host job은 expired forced resize를 fail close하고 sealed mutation을 보존한다" {
    try runCr4aActualIssuerReplacementStage(.controller_publish_expired);
}

fn cleanupCr4cPublicationProofLossArtifacts(child_pid: c.pid_t) void {
    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-cr4-job-{d}", .{child_pid}) catch return;
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return;
    const host_id: u128 = (@as(u128, @intCast(child_pid)) << 64) | 0x4352344A4F42;
    var socket_buf: [128]u8 = undefined;
    if (short_endpoint.currentSocketPathIn(&socket_buf, host_id)) |socket| _ = c.unlink(socket.ptr) else |_| {}
    var path_buf: [832]u8 = undefined;
    if (host_manifest.manifestPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
    if (host_manifest.ownerLockPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
    var host_dir_buf: [768]u8 = undefined;
    if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
    var hosts_buf: [640]u8 = undefined;
    if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
    _ = c.rmdir(dir.ptr);
    std.Io.Dir.cwd().deleteTree(testing.io, base) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
}

test "CR4c C2 publication suffix authority drift는 actual host job에서 proof loss로 종료한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (process_seal.currentReadyIdentity()) |_| return error.SkipZigTest else |err| switch (err) {
        error.NotReady => {},
        else => return err,
    }
    try short_endpoint.prepareCurrentUserNamespace();
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        if (c.setsid() < 0) c._exit(124);
        runCr4aActualIssuerReplacementStage(.controller_publication_proof_loss) catch c._exit(125);
        c._exit(87);
    }
    var status: c_int = 0;
    var reaped = false;
    var attempts: usize = 0;
    while (attempts < 20_000) : (attempts += 1) {
        const waited = c.waitpid(child, &status, posix.W.NOHANG);
        if (waited == child) {
            reaped = true;
            break;
        }
        if (waited < 0 and std.posix.errno(waited) != .INTR) break;
        _ = usleep(1_000);
    }
    _ = c.kill(-child, posix.SIG.TERM);
    _ = usleep(20_000);
    if (!reaped) {
        _ = c.kill(-child, posix.SIG.KILL);
        _ = c.kill(child, posix.SIG.KILL);
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited >= 0 or std.posix.errno(waited) != .INTR) break;
        }
    }
    cleanupCr4cPublicationProofLossArtifacts(child);
    try testing.expect(reaped);
    try testing.expectEqual(@as(c_int, 0), status & 0x7f);
    try testing.expectEqual(@as(c_int, 86), (status >> 8) & 0xff);
}

test "CR4b actual host job은 conflict unknown pre failure를 frozen ledger로 봉인한다" {
    try runCr4aActualIssuerReplacementStage(.controller_conflict_ledger);
    try runCr4aActualIssuerReplacementStage(.controller_unknown_ledger);
    try runCr4aActualIssuerReplacementStage(.controller_pre_failed_ledger);
}

test "CR5b-2c actual host job은 shared Client 하나로 three-runtime을 순서대로 게시한다" {
    try runCr4aActualIssuerReplacementStage(.multi_runtime_success);
}

test "CR6e-c3b2b frame driver는 actual shared Client job을 한 closed state씩 끝낸다" {
    try runCr4aActualIssuerReplacementStage(.driver_multi_runtime_success);
}

test "CR5b-2c actual host job은 kth failure에서 앞선 publication을 보존하고 suffix를 닫는다" {
    try runCr4aActualIssuerReplacementStage(.multi_runtime_conflict_1);
    try runCr4aActualIssuerReplacementStage(.multi_runtime_conflict_2);
    try runCr4aActualIssuerReplacementStage(.multi_runtime_conflict_3);
}

test "CR5c actual host job은 shared Client terminal에서 앞선 publication까지 host-wide unavailable로 닫는다" {
    try runCr4aActualIssuerReplacementStage(.multi_runtime_terminal_after_success);
}

test "CR4a actual issuer job은 replacement OOM을 forward failed로 봉인한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    const io = testing.io;

    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-cr4-job-oom-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4352344F4F4D;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        _ = unsetenv("MARU_SESSION_HOST_TEST_ONESHOT");
        daemon.runSessionHostWithIdentity(std.heap.page_allocator, io, dir, socket, host_id) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var path_buf: [832]u8 = undefined;
        if (host_manifest.manifestPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        if (host_manifest.ownerLockPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        std.Io.Dir.cwd().deleteTree(io, base) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
    }

    var initial: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 200) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket, .gui)) |connected| break :blk connected else |_| _ = usleep(20 * 1000);
        }
        return error.TestUnexpectedResult;
    };
    var pool = AdapterPool.init(allocator);
    defer pool.deinit();
    try testing.expectEqual(host_id, try addOwnedClient(&pool, allocator, &initial));
    try pool.setSpawnHost(host_id);
    var surface_runtime = SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();
    var backend_value = try RemoteTermBackend.initWithPool(allocator, io, &pool, &surface_runtime);
    try backend_value.claimProductSingleton();
    defer backend_value.deinit();
    const size = maru.terminal.Size{ .cols = 1, .rows = 1 };
    _ = try backend_value.backend().spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });
    const adapter = pool.get(host_id).?;
    const initial_connection_generation = adapter.connectionGeneration();
    const phase = try attach_phase_deadline.PhaseDeadline.start(io, .connect_hello);
    try testing.expectEqual(
        HostReconnectStart.connected,
        backend_value.beginHostReconnectConnect(base, host_id, phase),
    );
    const job = backend_value.host_reconnect_job.?;
    const original_node_allocator = adapter.slot.node_allocator;
    var failing = testing.FailingAllocator.init(original_node_allocator, .{ .fail_index = 0 });
    adapter.slot.node_allocator = failing.allocator();
    const result = backend_value.publishHostReconnectReplacement(1);
    adapter.slot.node_allocator = original_node_allocator;
    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(job.valid(&backend_value));
    try testing.expectEqual(
        @intFromEnum(HostReconnectJobState.replacement_failed),
        job.state_raw,
    );
    try testing.expect(job.client != null);
    try testing.expect(std.meta.eql(job.replacement, client_slot_mod.PreparedClientReplacement{}));
    try testing.expectEqual(initial_connection_generation, adapter.connectionGeneration());
    try RemoteRuntime.backend_api.preflightReconnectClientReplacementFailure(
        backend_value.runtimes.get(1).?.runtime,
        adapter,
        initial_connection_generation,
    );
    const failed_seal = job.seal;
    try testing.expectError(error.InvalidHostReconnectJob, backend_value.publishHostReconnectReplacement(1));
    try testing.expectEqual(failed_seal, job.seal);
    try testing.expectError(error.Busy, backend_value.abortHostReconnectConnect());
}

test "CR4a actual issuer job은 allocator fail-index 단계별 forward 경계와 final ledger zero를 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const io = testing.io;

    var base_buf: [176]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-cr4-job-fail-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [272]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4352344641494C;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        _ = unsetenv("MARU_SESSION_HOST_TEST_ONESHOT");
        daemon.runSessionHostWithIdentity(std.heap.page_allocator, io, dir, socket, host_id) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var path_buf: [832]u8 = undefined;
        if (host_manifest.manifestPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        if (host_manifest.ownerLockPathIn(&path_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        std.Io.Dir.cwd().deleteTree(io, base) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
    }

    var saw_connect_oom = false;
    var saw_replacement_preflight_oom = false;
    var saw_replacement_oom = false;
    var saw_candidate_oom = false;
    var first_success: ?usize = null;
    var fail_offset: usize = 0;
    while (fail_offset < 128) : (fail_offset += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const allocator = failing.allocator();
        {
            var initial: client_mod.Client = blk: {
                var attempts: usize = 0;
                while (attempts < 200) : (attempts += 1) {
                    if (client_mod.Client.connect(allocator, socket, .gui)) |connected| break :blk connected else |_| _ = usleep(20 * 1000);
                }
                return error.TestUnexpectedResult;
            };
            var pool = AdapterPool.init(allocator);
            var pool_live = true;
            defer if (pool_live) pool.deinit();
            try testing.expectEqual(host_id, try addOwnedClient(&pool, allocator, &initial));
            try pool.setSpawnHost(host_id);

            var surface_runtime = SurfaceRuntime.init(allocator);
            var surface_live = true;
            defer if (surface_live) surface_runtime.deinit();
            var backend_value = try RemoteTermBackend.initWithPool(allocator, io, &pool, &surface_runtime);
            var backend_live = true;
            defer if (backend_live) backend_value.deinit();
            try backend_value.claimProductSingleton();
            const size = maru.terminal.Size{ .cols = 1, .rows = 1 };
            _ = try backend_value.backend().spawn(.{
                .handle = 1,
                .request = .{ .command = "/bin/cat", .size = size },
                .size = size,
                .queue_capacity = 16,
            });
            const adapter = pool.get(host_id).?;
            const initial_connection_generation = adapter.connectionGeneration();
            const allocation_baseline = failing.alloc_index;
            failing.fail_index = std.math.add(usize, allocation_baseline, fail_offset) catch
                return error.TestUnexpectedResult;
            defer failing.fail_index = std.math.maxInt(usize);

            var staged = false;
            const phase = try attach_phase_deadline.PhaseDeadline.start(io, .connect_hello);
            switch (backend_value.beginHostReconnectConnect(base, host_id, phase)) {
                .failed => |reason| {
                    try testing.expectEqual(host_connect.FailureReason.out_of_memory, reason);
                    try testing.expect(failing.has_induced_failure);
                    try testing.expectEqual(@as(?*HostReconnectJob, null), backend_value.host_reconnect_job);
                    try testing.expectEqual(initial_connection_generation, adapter.connectionGeneration());
                    try testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
                    try adapter.preflightAttachmentConnectionUsable();
                    saw_connect_oom = true;
                },
                .connected => {
                    const job = backend_value.host_reconnect_job.?;
                    if (backend_value.publishHostReconnectReplacement(1)) |_| {
                        try testing.expectEqual(
                            @intFromEnum(HostReconnectJobState.replacement_published),
                            job.state_raw,
                        );
                        if (backend_value.prepareHostReconnectObserverStage(1)) |stage| {
                            try testing.expect(job.valid(&backend_value));
                            try testing.expectEqual(stage, job.stage.?);
                            try testing.expectEqual(
                                @intFromEnum(HostReconnectJobState.candidate_staged),
                                job.state_raw,
                            );
                            staged = true;
                        } else |err| {
                            try testing.expect(failing.has_induced_failure);
                            try testing.expect(job.valid(&backend_value));
                            try testing.expectEqual(
                                @intFromEnum(HostReconnectJobState.candidate_failed),
                                job.state_raw,
                            );
                            try testing.expect(job.stage == null);
                            try testing.expect(std.meta.eql(job.reconnect, remote_runtime.PreparedReconnect{}));
                            _ = switch (classifyCandidatePrepareFailure(err)) {
                                .terminal => |reason| reason,
                                .rejected_usable => return error.TestUnexpectedResult,
                            };
                            const expected_reason = host_adapter_mod.HostAdapter.testing.rawClient(adapter)
                                .firstPoisonReason() orelse return error.TestUnexpectedResult;
                            try testing.expectEqual(
                                @intFromEnum(expected_reason) + 1,
                                job.candidate_failure_reason_raw,
                            );
                            try adapter.preflightAttachmentConnectionFailedClosed(expected_reason);
                            saw_candidate_oom = true;
                        }
                    } else |err| {
                        try testing.expectEqual(error.OutOfMemory, err);
                        try testing.expect(failing.has_induced_failure);
                        try testing.expect(job.valid(&backend_value));
                        switch (job.state_raw) {
                            @intFromEnum(HostReconnectJobState.connected) => {
                                try testing.expectEqual(initial_connection_generation, adapter.connectionGeneration());
                                try testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
                                try adapter.preflightAttachmentConnectionUsable();
                                saw_replacement_preflight_oom = true;
                            },
                            @intFromEnum(HostReconnectJobState.replacement_failed) => {
                                try testing.expectEqual(initial_connection_generation, adapter.connectionGeneration());
                                try RemoteRuntime.backend_api.preflightReconnectClientReplacementFailure(
                                    backend_value.runtimes.get(1).?.runtime,
                                    adapter,
                                    initial_connection_generation,
                                );
                                saw_replacement_oom = true;
                            },
                            else => return error.TestUnexpectedResult,
                        }
                    }
                },
                .busy, .invalid_authority => return error.TestUnexpectedResult,
            }

            if (!failing.has_induced_failure) {
                try testing.expect(staged);
                if (first_success == null) {
                    first_success = fail_offset;
                } else {
                    try testing.expectEqual(first_success.? + 1, fail_offset);
                }
            }

            failing.fail_index = std.math.maxInt(usize);
            backend_value.deinit();
            backend_live = false;
            try testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
            try testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
            try testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
            try testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
            try testing.expectEqual(@as(usize, 0), adapter.slot.current.client.pending_catchup_barriers.items.len);
            surface_runtime.deinit();
            surface_live = false;
            pool.deinit();
            pool_live = false;
        }
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (first_success != null and fail_offset == first_success.? + 1) break;
    }
    try testing.expect(saw_connect_oom);
    try testing.expect(saw_replacement_preflight_oom);
    try testing.expect(saw_replacement_oom);
    try testing.expect(saw_candidate_oom);
    try testing.expect(first_success != null);
}

test "shared connection terminalize는 backend runtime map을 파괴하지 않는다" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    defer client.deinit();
    var backend_value = RemoteTermBackend.init(
        testing.allocator,
        testing.io,
        &client,
        @ptrFromInt(@alignOf(SurfaceRuntime)),
    );
    defer backend_value.runtimes.deinit(testing.allocator);
    try testing.expect(backend_value.beginAppQuitShutdown(1));
    try testing.expect(backend_value.tombstoneAllRoutingForAppQuit());
    try testing.expect(backend_value.terminalizeSharedConnectionsNoDestroy());
    try testing.expectEqual(@as(usize, 0), backend_value.runtimes.count());
    try testing.expect(client.unusable);
    try testing.expectEqual(@as(std.c.fd_t, -1), client.fd);
}

fn remoteBackendSingletonSeal(owner: *const RemoteBackendSingletonOwner) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.remoteBackendSingletonSeal(owner.pid, owner.process_nonce, .{
        .self_addr = @intFromPtr(owner),
        .backend_addr = owner.backend_addr,
        .thread_id = owner.thread_id,
        .owner_generation = owner.owner_generation,
        .lifecycle_raw = owner.lifecycle_raw,
    });
}

fn windowCloseTicketReservationSeal(
    reservation: *const WindowCloseTicketReservation,
) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.windowCloseTicketReservationSeal(reservation.pid, reservation.process_nonce, .{
        .self_addr = @intFromPtr(reservation),
        .backend_addr = reservation.backend_addr,
        .thread_id = reservation.thread_id,
        .first_ticket = reservation.first_ticket,
        .last_ticket = reservation.last_ticket,
        .target_count = reservation.target_count,
        .target_digest = reservation.target_digest,
        .state_raw = reservation.state_raw,
    });
}

fn hashWindowCloseInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    hasher.update(&encoded);
}

fn validRemoteBackendSingleton(owner: *const RemoteBackendSingletonOwner, backend_addr: u64) bool {
    if (backend_addr == 0 or owner.backend_addr != backend_addr or owner.owner_generation == 0 or
        owner.lifecycle_raw != @intFromEnum(RemoteBackendSingletonLifecycle.claimed) or
        owner.thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
    const ready = process_seal.currentReadyIdentity() catch return false;
    if (owner.pid != ready.pid or owner.process_nonce != ready.process_nonce) return false;
    const expected = remoteBackendSingletonSeal(owner) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, owner.seal);
}

fn b5FillSyntheticRows(backend_value: *RemoteTermBackend, count_value: usize) !void {
    const runtime_ptr: *RemoteRuntime = @ptrFromInt(@alignOf(RemoteRuntime));
    for (0..count_value) |index| {
        try backend_value.runtimes.put(backend_value.allocator, @intCast(index + 1), .{
            .runtime = runtime_ptr,
            .host_id = if (index % 2 == 0) 11 else 22,
            .runtime_generation = @intCast(index + 1),
        });
    }
}

test "C3-3b5 remote backend는 두 host 합계 runtime 4096개만 허용한다" {
    try HostAdapter.initializeProcessRuntime();
    var first_singleton = b5TestBackend(testing.allocator);
    var second_singleton = b5TestBackend(testing.allocator);
    try first_singleton.claimProductSingleton();
    const first_generation = first_singleton.singleton_owner.owner_generation;
    const copied_owner = first_singleton.singleton_owner;
    try testing.expect(!validRemoteBackendSingleton(&copied_owner, @intFromPtr(&first_singleton)));
    try testing.expectError(error.RemoteBackendAlreadyClaimed, second_singleton.claimProductSingleton());
    first_singleton.releaseProductSingleton();
    try second_singleton.claimProductSingleton();
    try testing.expect(second_singleton.singleton_owner.owner_generation > first_generation);
    second_singleton.releaseProductSingleton();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    try b5FillSyntheticRows(&backend_value, max_remote_backend_runtimes);
    try testing.expectEqual(@as(usize, max_remote_backend_runtimes), backend_value.runtimes.count());
    var reservation: RuntimeAdmissionReservation = .{};
    try testing.expectError(error.ResourceExhausted, backend_value.reserveRuntimeAdmission(&reservation));
    try testing.expectEqual(RuntimeAdmissionReservation{}, reservation);
}

test "C3-3b5 remote backend는 4097번째를 allocator와 host RPC 전에 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    try b5FillSyntheticRows(&backend_value, max_remote_backend_runtimes);
    const generation_before = backend_value.next_admission_generation;
    var reservation: RuntimeAdmissionReservation = .{};
    try testing.expectError(error.ResourceExhausted, backend_value.reserveRuntimeAdmission(&reservation));
    try testing.expectEqual(generation_before, backend_value.next_admission_generation);
    try testing.expectEqual(@as(usize, 0), backend_value.reserved_runtime_count);
}

test "C3-3b5 remote backend는 spawn 실패 reservation을 회수해 capacity를 재사용한다" {
    try HostAdapter.initializeProcessRuntime();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    const size: maru.terminal.Size = .{ .cols = 10, .rows = 4 };
    try testing.expectError(error.HostNotFound, backend_value.backend().spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/true", .size = size },
        .size = size,
        .queue_capacity = 1,
    }));
    try testing.expectEqual(@as(usize, 0), backend_value.reserved_runtime_count);
    var reservation: RuntimeAdmissionReservation = .{};
    try backend_value.reserveRuntimeAdmission(&reservation);
    backend_value.abortRuntimeAdmission(&reservation);
}

test "C3-3b5 remote backend는 attach와 restore 실패 reservation을 회수해 capacity를 재사용한다" {
    try HostAdapter.initializeProcessRuntime();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    try testing.expectError(error.HostNotFound, backend_value.attachTermOnHost(9, 1, [_]u8{'0'} ** 32, .{ .cols = 10, .rows = 4 }));
    try testing.expectEqual(@as(usize, 0), backend_value.reserved_runtime_count);
    var reservation: RuntimeAdmissionReservation = .{};
    try backend_value.reserveRuntimeAdmission(&reservation);
    backend_value.abortRuntimeAdmission(&reservation);
}

test "C3-3b5 remote backend scan scratch는 256 KiB 이하이고 callback allocation이 없다" {
    try testing.expect(@sizeOf(close_contract.CloseScanReceipt) * max_remote_backend_runtimes <= 256 * 1024);
    var fixed_storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_storage);
    var backend_value = b5TestBackend(fixed.allocator());
    const before = fixed.end_index;
    const stats = backend_value.maintenanceCloseTick();
    try testing.expectEqual(before, fixed.end_index);
    try testing.expectEqual(CloseMaintenanceStats{}, stats);
}

test "C3-3b5 remote backend는 iterator를 닫은 뒤에만 relookup과 callback을 수행한다" {
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    const Hook = struct {
        fn run(target: *RemoteTermBackend) void {
            b5FillSyntheticRows(target, 1) catch @panic("scan hook insertion failed");
        }
    };
    B5TestState.scan_hook = Hook.run;
    defer B5TestState.scan_hook = null;
    const stats = backend_value.maintenanceCloseTick();
    try testing.expectEqual(@as(usize, 0), stats.visited_count);
    try testing.expectEqual(@as(usize, 1), backend_value.runtimes.count());
}

test "C3-3b5 remote backend는 active pin 제거를 보류하고 다음 tick에 exact once 회수한다" {
    try HostAdapter.initializeProcessRuntime();
    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    const runtime_ptr = try testing.allocator.create(RemoteRuntime);
    defer testing.allocator.destroy(runtime_ptr);
    runtime_ptr.close_authority = .{};
    try close_authority.prepareCurrent(&runtime_ptr.close_authority, .{
        .runtime_addr = @intFromPtr(runtime_ptr),
        .handle = 7,
        .runtime_generation = 1,
        .host_id = 9,
        .close_request_generation = 1,
        .close_schedule_ticket = 1,
        .request_kind = .finish_after_termination,
        .disposition = .terminate_host,
    });
    try close_authority.advance(&runtime_ptr.close_authority, .open, .routing_tombstoned);
    try close_authority.advance(&runtime_ptr.close_authority, .routing_tombstoned, .settling);
    try testing.expect(try close_authority.publishReadyRemove(&runtime_ptr.close_authority, true));
    try backend_value.runtimes.put(testing.allocator, 7, .{ .runtime = runtime_ptr, .host_id = 9, .runtime_generation = 1 });
    backend_value.close_operation_owner.active = true;
    try testing.expectEqual(term_backend.CloseProgress.event_pending, backend_value.windowCloseReadiness(7));
    try testing.expectEqual(term_backend.RemoveProgress.event_pending, RemoteTermBackend.remove(&backend_value, 7));
    try testing.expect(backend_value.runtimes.contains(7));
    backend_value.close_operation_owner = .{};
    try testing.expectEqual(term_backend.CloseProgress.complete, backend_value.windowCloseReadiness(7));
    B5TestState.skip_destroy = true;
    defer B5TestState.skip_destroy = false;
    const stats = backend_value.maintenanceCloseTick();
    try testing.expectEqual(@as(usize, 1), stats.removed_count);
    try testing.expect(!backend_value.runtimes.contains(7));
    try testing.expectEqual(@as(usize, 0), backend_value.maintenanceCloseTick().removed_count);
}

test "C3-3b4 async close parity는 prepared event를 다음 tick settlement 뒤 제거한다" {
    var fixture: remote_runtime.testing_api.SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    try fixture.prepareForClose(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":4,\"metadata\":{" ++
            "\"cwd\":\"/close\",\"window_title\":\"close\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
            "\"foreground_pgid\":null,\"processes\":[]}}",
    );

    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    try backend_value.runtimes.put(testing.allocator, 41, .{
        .runtime = &fixture.runtime,
        .host_id = 1,
        .runtime_generation = 1,
    });
    B5TestState.skip_destroy = true;
    defer B5TestState.skip_destroy = false;
    remote_runtime.testing_api.armSettlementContention(1);

    try testing.expectEqual(term_backend.CloseProgress.event_pending, backend_value.backend().finishAfterTermination(41));
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.prepared),
        fixture.runtime.pending_event_owner.lifecycle_raw,
    );
    try testing.expectEqual(term_backend.CloseProgress.complete, backend_value.backend().finishAfterTermination(41));
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.idle),
        fixture.runtime.pending_event_owner.lifecycle_raw,
    );
    try testing.expectEqual(term_backend.RemoveProgress.removed, RemoteTermBackend.remove(&backend_value, 41));
    try testing.expect(!backend_value.runtimes.contains(41));
}

const B4SemanticCleanupProbe = struct {
    parent: std.mem.Allocator,
    backend: ?*RemoteTermBackend = null,
    runtime: ?*RemoteRuntime = null,
    handle: RuntimeHandle = 0,
    target_addr: usize = 0,
    target_len: usize = 0,
    armed: bool = false,
    callback_count: usize = 0,
    saw_committed_cleanup: bool = false,
    reentrant_remove: ?term_backend.RemoveProgress = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawAlloc(len, alignment, ra);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed and @intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len) {
            self.armed = false;
            self.callback_count += 1;
            const runtime = self.runtime orelse @panic("b4 semantic cleanup runtime가 없다");
            self.saw_committed_cleanup = runtime.pending_event_owner.lifecycle_raw ==
                @intFromEnum(pending_event_owner.PendingLifecycle.committed_cleanup);
            self.reentrant_remove = RemoteTermBackend.remove(
                self.backend orelse @panic("b4 semantic cleanup backend가 없다"),
                self.handle,
            );
        }
        self.parent.rawFree(memory, alignment, ra);
    }
};

test "C3-3b4 async close parity는 committed cleanup callback 뒤에만 제거한다" {
    var probe = B4SemanticCleanupProbe{ .parent = testing.allocator };
    var fixture: remote_runtime.testing_api.SemanticFixture = undefined;
    try fixture.initInPlaceWithAllocator(probe.allocator());
    defer fixture.deinit();
    _ = try fixture.publish(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":4,\"metadata\":{" ++
            "\"cwd\":\"/old-close-owner\",\"window_title\":\"old\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
            "\"foreground_pgid\":null,\"processes\":[]}}",
    );
    try fixture.prepareForClose(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":5,\"metadata\":{" ++
            "\"cwd\":\"/new-close-owner\",\"window_title\":\"new\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":2,\"title_generation\":2," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
            "\"foreground_pgid\":null,\"processes\":[]}}",
    );

    var backend_value = b5TestBackend(testing.allocator);
    defer backend_value.runtimes.deinit(testing.allocator);
    try backend_value.runtimes.put(testing.allocator, 42, .{
        .runtime = &fixture.runtime,
        .host_id = 1,
        .runtime_generation = 1,
    });
    B5TestState.skip_destroy = true;
    defer B5TestState.skip_destroy = false;
    probe.backend = &backend_value;
    probe.runtime = &fixture.runtime;
    probe.handle = 42;
    probe.target_addr = @intFromPtr(remote_runtime.testing_api.generation(&fixture.runtime).observation.cwd.items.ptr);
    probe.target_len = remote_runtime.testing_api.generation(&fixture.runtime).observation.cwd.items.len;
    probe.armed = true;

    const finish = backend_value.backend().finishAfterTermination(42);
    try testing.expectEqual(term_backend.CloseProgress.complete, finish);
    try testing.expectEqual(@as(usize, 1), probe.callback_count);
    try testing.expect(probe.saw_committed_cleanup);
    try testing.expectEqual(term_backend.RemoveProgress.event_pending, probe.reentrant_remove.?);
    try testing.expect(backend_value.runtimes.contains(42));
    try testing.expectEqual(term_backend.RemoveProgress.removed, RemoteTermBackend.remove(&backend_value, 42));
    try testing.expect(!backend_value.runtimes.contains(42));
}

test "P4 N2b1 remote backend binding은 실제 host runtime의 stable notification label을 갱신한다 (C3-3b4)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (std.c.getenv("MARU_SESSION_HOST_REMOTE_BACKEND_REAL_HOST")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "skip-in-aggregate-v1")) return error.SkipZigTest;
    }
    try HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    const io = testing.io;

    // Debug·ReleaseFast focused artifacts both launch a real daemon. Keep the same cross-process
    // fixture lock as the other actual-host backend tests: HostAdapter's process-global execution
    // runtime and forked socket fixture are deliberately exercised one artifact at a time.
    const fixture_lock_fd = c.open(
        "/tmp/maru-session-host-actual-fixture.lock",
        .{ .ACCMODE = .RDWR, .CREAT = true },
        @as(c.mode_t, 0o600),
    );
    if (fixture_lock_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(fixture_lock_fd);
    if (c.flock(fixture_lock_fd, posix.LOCK.EX) != 0) return error.TestUnexpectedResult;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rtb-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.close(fixture_lock_fd);
        _ = c.setsid();
        // The test runner control pipe must not survive an unexpected parent abort, otherwise the
        // build waits forever on an orphaned daemon instead of reporting the failing assertion.
        const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }
        var inherited_fd: c_int = 3;
        while (inherited_fd < 4096) : (inherited_fd += 1) _ = c.close(inherited_fd);
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
    }

    var client_value: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    var pool = AdapterPool.init(allocator);
    defer pool.deinit();
    const host_id = try addOwnedClient(&pool, allocator, &client_value);
    try pool.setSpawnHost(host_id);

    // 앱 라우팅 표(GUI 입력 hot path가 쓰는 그 표). backend가 원격 Term을 여기 등록한다.
    var surface_runtime = maru.app.SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();

    var be_impl = try RemoteTermBackend.initWithPool(allocator, io, &pool, &surface_runtime);
    defer be_impl.deinit();
    const be = be_impl.backend();

    // 계약으로 원격 runtime을 띄운다: /bin/cat, 40x10. 반환 Surface는 원격-backed(surface.remote 세팅).
    const size = maru.terminal.Size{ .cols = 40, .rows = 10 };
    const surface = try be.spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });
    try testing.expectError(error.RuntimeAlreadyRegistered, be.spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    }));
    const existing_runtime_id = be_impl.runtimeIdFor(1).?;
    try testing.expect(be_impl.runtimes.get(1).?.runtime.usesGenerationAttachment());
    try testing.expectError(
        error.RuntimeAlreadyRegistered,
        be_impl.attachTermOnHost(host_id, 1, existing_runtime_id, size),
    );
    try testing.expectEqual(@as(usize, 1), be_impl.runtimes.count());
    try testing.expectError(error.HostInUse, pool.remove(host_id));

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

    const link = try be.attach(1, true); // 원격 Term을 SurfaceRuntime에 원격 PtyIo로 등록한다(RuntimeLink 반환).
    try testing.expectEqual(@as(u64, 1), link.surface_id);

    // AppSession tick이 쓰는 backend API 그대로 현재 workspace/Term binding을 완전 snapshot으로 갱신한다. 이후 OSC가
    // 발화 시점의 owned label을 stable event에 싣는지 실제 PTY→host core→journal→GUI pull 왕복으로 증명한다.
    try be_impl.configureNotifications(true);
    try be_impl.configureNotificationBinding(1, "workspace › cat");
    try surface_runtime.writeInput(1, .{ .bytes = "\x1b]777;notify;Build;done\x1b\\\n" });
    var notification: ?remote_runtime.Notification = null;
    var attempts: usize = 0;
    while (attempts < 150 and notification == null) : (attempts += 1) {
        notification = be_impl.takeNotificationFor(1);
        if (notification == null) _ = usleep(20 * 1000);
    }
    var delivered = notification orelse {
        try testing.expect(false);
        return;
    };
    defer delivered.deinit(allocator);
    try testing.expectEqualStrings("workspace › cat", delivered.display_label.?);

    var frame_pump = try be.pump(1); // 원격 모드 RuntimeEventPump.

    // **핵심**: GUI 키 입력 hot path와 **똑같이** self.runtime.writeInput(surface.id, ...)로 보낸다 — 계약 vtable을 우회해도
    // 원격 PtyIo→client.sendInput→host로 라우팅된다(app_session 무변경으로 원격 입력이 도달함을 증명). host가 echo → delta →
    // pump.drainAvailable()(원격 drain)로 소비해 Surface에 "h"가 반영되는지 폴링(host delta tick ~20ms).
    try surface_runtime.writeInput(1, .{ .bytes = "hello\n" });
    var found = false;
    attempts = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        const ds = try frame_pump.drainAvailable();
        surface.lockCore(io);
        const snapshot = surface.renderSnapshot();
        var contains_h = false;
        for (snapshot.cells) |cell| {
            if (cell.codepoint == 'h') {
                contains_h = true;
                break;
            }
        }
        surface.unlockCore(io);
        if (contains_h) {
            found = true;
            try testing.expect(ds.output_events > 0); // 배치가 적용된 tick은 렌더 트리거를 낸다.
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // hot path(SurfaceRuntime)를 통한 원격 입력이 host를 거쳐 Surface에 반영됐다.

    // resize도 hot path(self.runtime.resize)로 원격 PtyIo→resize RPC에 도달한다(에러 없이 위임).
    try surface_runtime.resize(1, .{ .cols = 80, .rows = 24 }, io);

    // 앱 quit의 client-side detach를 축약해 같은 host runtime을 살려 둔 뒤 재attach한다. 새 backend entry publication 전에
    // 현재 `notifications_osc=true` 완전 snapshot이 적용돼, 실제 binding label sync 전에도 발화가 켜지고 runtime-ID
    // fallback label을 쓰는지 검증한다.
    surface_runtime.detachSurface(1);
    const detached = be_impl.runtimes.fetchRemove(1).?;
    detached.value.runtime.detachClientSide();
    allocator.destroy(detached.value.runtime);
    pool.release(host_id);
    // 새 GUI process가 만든 backend처럼 local config 축을 초기값으로 되돌린 뒤, AppSession backend 설치 경로가
    // loaded config=true를 runtime attach 전에 주입하는 순서를 재현한다. daemon에는 더 높은 옛 generation이 남아 있지만
    // 새 controller generation이므로 새 축의 nonzero generation 2가 정당하게 교체돼야 한다.
    be_impl.notifications_osc = false;
    be_impl.notification_config_generation = 1;
    try be_impl.configureNotifications(true);
    const restored_surface = try be_impl.attachTermOnHost(host_id, 2, existing_runtime_id, size);
    _ = restored_surface;
    _ = try be.attach(2, true);
    try surface_runtime.writeInput(2, .{ .bytes = "\x1b]777;notify;Restored;alive\x1b\\\n" });
    notification = null;
    attempts = 0;
    while (attempts < 150 and notification == null) : (attempts += 1) {
        notification = be_impl.takeNotificationFor(2);
        if (notification == null) _ = usleep(20 * 1000);
    }
    var restored_delivery = notification orelse {
        try testing.expect(false);
        return;
    };
    defer restored_delivery.deinit(allocator);
    try testing.expectEqualStrings(existing_runtime_id[0..], restored_delivery.display_label.?);

    var restored_pump = try be.pump(2);
    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(2));
    var saw_close_ended = false;
    attempts = 0;
    while (attempts < 100 and !saw_close_ended) : (attempts += 1) {
        const summary = try restored_pump.drainAvailable();
        saw_close_ended = summary.ended != null;
        if (!saw_close_ended) _ = usleep(20 * 1000);
    }
    try testing.expect(saw_close_ended);
    try testing.expectEqual(term_backend.RemoveProgress.removed, be.remove(2)); // client-side 회수(map 제거 + SurfaceRuntime detach + host terminate 멱등).
    try testing.expectEqual(@as(usize, 0), be_impl.runtimes.count());
    try testing.expect(try pool.remove(host_id));
    try testing.expectError(error.SpawnHostUnavailable, be.spawn(.{
        .handle = 2,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    }));
    // remove가 라우팅 표에서도 뗐다 — 이제 hot path 입력은 UnknownSurface(dangling link 없음).
    try testing.expectError(error.UnknownSurface, surface_runtime.writeInput(1, .{ .bytes = "x" }));
}

test "C3-3b5 remote backend는 두 host 창 ticket을 예약하고 pending target까지 routing을 일괄 게시한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (std.c.getenv("MARU_SESSION_HOST_WINDOW_CLOSE_MULTIHOST")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "skip-in-aggregate-v1")) return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    const io = testing.io;
    // 이 행은 daemon 두 개를 띄우므로 다른 actual-host artifact와 동시에 실행하지 않는다. lock은
    // 부모 fixture만 소유해야 fail-stop한 부모가 남긴 daemon child가 다음 실행을 영구 차단하지 않는다.
    const fixture_lock_path = "/tmp/maru-session-host-actual-fixture.lock";
    const fixture_lock_fd = c.open(
        fixture_lock_path,
        .{ .ACCMODE = .RDWR, .CREAT = true },
        @as(c.mode_t, 0o600),
    );
    if (fixture_lock_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(fixture_lock_fd);
    if (c.flock(fixture_lock_fd, posix.LOCK.EX) != 0) return error.TestUnexpectedResult;
    // Debug·ReleaseFast actual-host artifact가 병렬 실행될 때 daemon 두 개의 첫 frame이 2초를 넘길 수 있다.
    // 제품 deadline을 바꾸지 않고 이 외부 프로세스 fixture의 관측 상한만 6초로 둔다.
    const frame_attempt_limit = 300;

    var dir_a_buf: [256]u8 = undefined;
    const dir_a = std.fmt.bufPrintZ(&dir_a_buf, "/tmp/maru-sh-pool-a-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var socket_a_buf: [320]u8 = undefined;
    const socket_a = std.fmt.bufPrintZ(&socket_a_buf, "{s}/control.sock", .{dir_a}) catch return error.SkipZigTest;
    var dir_b_buf: [256]u8 = undefined;
    const dir_b = std.fmt.bufPrintZ(&dir_b_buf, "/tmp/maru-sh-pool-b-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var socket_b_buf: [320]u8 = undefined;
    const socket_b = std.fmt.bufPrintZ(&socket_b_buf, "{s}/control.sock", .{dir_b}) catch return error.SkipZigTest;

    const child_a = c.fork();
    if (child_a < 0) return error.SkipZigTest;
    if (child_a == 0) {
        _ = c.close(fixture_lock_fd);
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_a, socket_a) catch {};
        c._exit(0);
    }
    const child_b = c.fork();
    if (child_b < 0) {
        _ = c.kill(child_a, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child_a, &status, 0);
        return error.SkipZigTest;
    }
    if (child_b == 0) {
        _ = c.close(fixture_lock_fd);
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_b, socket_b) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child_a, posix.SIG.TERM);
        _ = c.kill(child_b, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child_a, &status, 0);
        _ = c.waitpid(child_b, &status, 0);
        _ = c.unlink(socket_a.ptr);
        _ = c.unlink(socket_b.ptr);
        _ = c.rmdir(dir_a.ptr);
        _ = c.rmdir(dir_b.ptr);
    }

    // daemon 자식은 pristine process-seal 상태에서 fork되어 각자 자기 PID 권위를 게시해야 한다.
    // 부모가 먼저 seal을 게시하면 fork child가 그 seal을 상속해 proof-loss로 정확히 fail-stop한다.
    try HostAdapter.initializeProcessRuntime();

    var connect_a: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_a, .gui)) |client| break :blk client else |_| _ = usleep(20 * 1000);
        }
        return error.TestUnexpectedResult;
    };
    var connect_b: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_b, .gui)) |client| break :blk client else |_| _ = usleep(20 * 1000);
        }
        connect_a.deinit();
        return error.TestUnexpectedResult;
    };
    const host_a = connect_a.host_id;
    const host_b = connect_b.host_id;
    try testing.expect(host_a != host_b);

    var pool = AdapterPool.init(allocator);
    defer pool.deinit();
    try testing.expectEqual(host_a, try addOwnedClient(&pool, allocator, &connect_a));
    try testing.expectEqual(host_b, try addOwnedClient(&pool, allocator, &connect_b));
    try pool.setSpawnHost(host_a);

    var surface_runtime = maru.app.SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();
    var be_impl = try RemoteTermBackend.initWithPool(allocator, io, &pool, &surface_runtime);
    defer be_impl.deinit();
    const be = be_impl.backend();
    const size: maru.terminal.Size = .{ .cols = 40, .rows = 10 };

    _ = try be.spawn(.{
        .handle = 11,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });
    _ = try be.attach(11, true);
    try pool.setSpawnHost(host_b);
    const surface_b = try be.spawn(.{
        .handle = 22,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });
    _ = try be.attach(22, true);
    try testing.expectEqual(host_a, be_impl.runtimeHostId(11).?);
    try testing.expectEqual(host_b, be_impl.runtimeHostId(22).?);
    const action_identity = be_impl.userActionProbeIdentity(11, 700).?;
    try testing.expectEqual(@as(u64, 700), action_identity.surface_id);
    try testing.expectEqual(@as(RuntimeHandle, 11), action_identity.runtime_handle);
    try testing.expectEqual(host_a, action_identity.host_id);
    try testing.expectEqual(be_impl.runtimeIdFor(11).?, action_identity.runtime_id);
    try testing.expect(action_identity.runtime_generation != 0);
    try testing.expect(be_impl.userActionProbeIdentity(999, 700) == null);
    try testing.expect(be_impl.userActionProbeIdentity(11, 0) == null);
    try testing.expectError(error.HostInUse, pool.remove(host_a));
    const runtime_a_id = be_impl.runtimeIdFor(11).?;

    var pump_b = try be.pump(22);
    try surface_runtime.writeInput(22, .{ .bytes = "before\n" });
    var saw_before = false;
    var attempts: usize = 0;
    while (attempts < frame_attempt_limit and !saw_before) : (attempts += 1) {
        _ = try pump_b.drainAvailable();
        surface_b.lockCore(io);
        const cells = surface_b.renderSnapshot().cells;
        for (cells) |cell| if (cell.codepoint == 'b') {
            saw_before = true;
            break;
        };
        surface_b.unlockCore(io);
        if (!saw_before) _ = usleep(20 * 1000);
    }
    try testing.expect(saw_before);

    // A runtime은 종료하지 않고 GUI만 detach한 뒤, spawn host가 B인 동안에도 saved host A로 exact reattach한다.
    // Adapter pool removal은 daemon retirement가 아니며, host 종료 가능 여부는 후속 authoritative inventory가 판정한다.
    be_impl.detachTerm(11);
    _ = try be_impl.attachTermOnHost(host_a, 33, runtime_a_id, size);
    try testing.expect(be_impl.runtimes.get(33).?.runtime.usesGenerationAttachment());
    _ = try be.attach(33, true);
    var pump_a = try be.pump(33);
    try testing.expectEqual(host_a, be_impl.runtimeHostId(33).?);
    try testing.expectEqual(host_b, be_impl.runtimeHostId(22).?);
    const reattached_identity = be_impl.userActionProbeIdentity(33, 700).?;
    try testing.expect(!std.meta.eql(action_identity, reattached_identity));
    try surface_runtime.writeInput(22, .{ .bytes = "after\n" });
    var saw_after = false;
    attempts = 0;
    while (attempts < frame_attempt_limit and !saw_after) : (attempts += 1) {
        _ = try pump_b.drainAvailable();
        surface_b.lockCore(io);
        const cells = surface_b.renderSnapshot().cells;
        for (cells) |cell| if (cell.codepoint == 'a') {
            saw_after = true;
            break;
        };
        surface_b.unlockCore(io);
        if (!saw_after) _ = usleep(20 * 1000);
    }
    try testing.expect(saw_after);

    try remote_runtime.testing_api.preparePendingEventForClose(
        be_impl.runtimes.get(22).?.runtime,
        "{\"event\":\"snapshot.invalidated\"}",
    );
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.prepared),
        be_impl.runtimes.get(22).?.runtime.pending_event_owner.lifecycle_raw,
    );
    const duplicate_handles = [_]RuntimeHandle{ 33, 33 };
    var rejected_reservation: WindowCloseTicketReservation = .{};
    const issuer_before_reject = be_impl.close_ticket_issuer;
    try testing.expectError(error.InvalidReservation, be_impl.reserveWindowCloseTickets(&duplicate_handles, &rejected_reservation));
    try testing.expectEqual(issuer_before_reject, be_impl.close_ticket_issuer);
    try testing.expectEqual(WindowCloseTicketReservation{}, rejected_reservation);

    const handles = [_]RuntimeHandle{ 33, 22 };
    var reservation: WindowCloseTicketReservation = .{};
    try be_impl.reserveWindowCloseTickets(&handles, &reservation);
    try testing.expectEqual(@as(u64, 1), reservation.first_ticket);
    try testing.expectEqual(@as(u64, 2), reservation.last_ticket);
    try testing.expect(be_impl.validWindowCloseTicketReservation(&handles, &reservation));
    var copied_reservation = reservation;
    try testing.expect(!be_impl.validWindowCloseTicketReservation(&handles, &copied_reservation));
    const reversed_handles = [_]RuntimeHandle{ 22, 33 };
    try testing.expect(!be_impl.validWindowCloseTicketReservation(&reversed_handles, &reservation));
    be_impl.publishWindowCloseAuthoritiesNoFail(&handles, &reservation);
    try testing.expectEqual(@as(u8, 2), reservation.state_raw);
    try testing.expectEqual(@as(u8, @intFromEnum(close_authority.Lifecycle.routing_tombstoned)), be_impl.runtimes.get(33).?.runtime.close_authority.lifecycle_raw);
    try testing.expectEqual(@as(u8, @intFromEnum(close_authority.Lifecycle.routing_tombstoned)), be_impl.runtimes.get(22).?.runtime.close_authority.lifecycle_raw);
    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(33));
    // C3 RX-first는 terminate response를 decoder에 넘기기 전에 준비된 target event를 정산한다.
    // persistent Busy의 다음-tick 계약은 별도 async close parity 테스트가 맡는다.
    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(22));
    try testing.expectEqual(@as(u8, @intFromEnum(close_authority.Lifecycle.ready_remove)), be_impl.runtimes.get(22).?.runtime.close_authority.lifecycle_raw);
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.idle),
        be_impl.runtimes.get(22).?.runtime.pending_event_owner.lifecycle_raw,
    );
    // 실제 frame은 remove 전에 두 host가 만든 runtime.ended를 모두 관측해야 한다.
    var saw_close_ended_a = false;
    attempts = 0;
    while (attempts < frame_attempt_limit and !saw_close_ended_a) : (attempts += 1) {
        const summary = try pump_a.drainAvailable();
        saw_close_ended_a = summary.ended != null;
        if (!saw_close_ended_a) _ = usleep(20 * 1000);
    }
    try testing.expect(saw_close_ended_a);
    var saw_close_ended = false;
    attempts = 0;
    while (attempts < frame_attempt_limit and !saw_close_ended) : (attempts += 1) {
        const summary = try pump_b.drainAvailable();
        saw_close_ended = summary.ended != null;
        if (!saw_close_ended) _ = usleep(20 * 1000);
    }
    try testing.expect(saw_close_ended);
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.idle),
        be_impl.runtimes.get(22).?.runtime.pending_event_owner.lifecycle_raw,
    );
    try testing.expectEqual(term_backend.RemoveProgress.removed, be.remove(33));
    try testing.expect(try pool.remove(host_a));
    try testing.expectEqual(term_backend.RemoveProgress.removed, be.remove(22));
    try testing.expect(try pool.remove(host_b));
}

const B4PumpFixture = struct {
    backend: RemoteTermBackend,
    runtimes: [17]RemoteRuntime = undefined,

    fn init(self: *@This(), count: usize) !void {
        self.backend = RemoteTermBackend.init(
            testing.allocator,
            testing.io,
            undefined,
            undefined,
        );
        for (0..count) |index| {
            try remote_runtime.testing_api.initializeDetachedGeneration(
                &self.runtimes[index],
                testing.allocator,
            );
            remote_runtime.testing_api.generation(&self.runtimes[index]).frame_summary_ready = false;
            remote_runtime.testing_api.generation(&self.runtimes[index]).frame_summary = .{};
            try self.backend.runtimes.put(testing.allocator, index + 1, .{
                .runtime = &self.runtimes[index],
                .host_id = 1,
                .runtime_generation = index + 1,
            });
        }
    }

    fn deinit(self: *@This()) void {
        B5TestState.event_pump_hook = null;
        self.backend.runtimes.deinit(testing.allocator);
    }

    fn consumeFrame(self: *@This(), count: usize) void {
        for (0..count) |index| {
            remote_runtime.testing_api.generation(&self.runtimes[index]).frame_summary_ready = false;
            remote_runtime.testing_api.generation(&self.runtimes[index]).frame_summary = .{};
        }
    }
};

const B4PumpProbe = struct {
    threadlocal var count: usize = 0;
    threadlocal var seen: [17]u8 = [_]u8{0} ** 17;

    fn reset() void {
        count = 0;
        seen = [_]u8{0} ** 17;
    }

    fn run(handle: RuntimeHandle, _: *RemoteRuntime) DrainSummary {
        count += 1;
        seen[handle - 1] += 1;
        return .{};
    }
};

test "C3-3b4 pump round-robin은 빈 queue를 idle로 반환한다" {
    var fixture: B4PumpFixture = undefined;
    try fixture.init(0);
    defer fixture.deinit();
    B4PumpProbe.reset();
    B5TestState.event_pump_hook = B4PumpProbe.run;
    fixture.backend.maintenanceEventTick();
    try testing.expectEqual(@as(usize, 0), B4PumpProbe.count);
    try testing.expectEqual(@as(usize, 0), fixture.backend.event_pump_cursor);
}

test "C3-3b4 pump round-robin은 16 owner를 한 tick에 한 번씩 진행한다" {
    var fixture: B4PumpFixture = undefined;
    try fixture.init(16);
    defer fixture.deinit();
    B4PumpProbe.reset();
    B5TestState.event_pump_hook = B4PumpProbe.run;
    fixture.backend.maintenanceEventTick();
    try testing.expectEqual(@as(usize, 16), B4PumpProbe.count);
    for (B4PumpProbe.seen[0..16]) |value| try testing.expectEqual(@as(u8, 1), value);
}

test "C3-3b4 pump round-robin은 17번째 owner를 다음 tick에 진행한다" {
    var fixture: B4PumpFixture = undefined;
    try fixture.init(17);
    defer fixture.deinit();
    B4PumpProbe.reset();
    B5TestState.event_pump_hook = B4PumpProbe.run;
    fixture.backend.maintenanceEventTick();
    try testing.expectEqual(@as(u8, 0), B4PumpProbe.seen[16]);
    fixture.consumeFrame(17);
    fixture.backend.maintenanceEventTick();
    try testing.expectEqual(@as(u8, 1), B4PumpProbe.seen[16]);
}

test "C3-3b4 pump round-robin은 frame retained bytes 상한을 넘지 않는다" {
    const maximum = event_pump_contract.max_owners_per_frame *
        event_pump_contract.retained_parts_per_owner * protocol.max_control_json;
    try testing.expectEqual(maximum, (try event_pump_contract.frameBudget(16, maximum)).retained_bytes);
    try testing.expectError(error.ResourceExhausted, event_pump_contract.frameBudget(16, maximum + 1));
}

test "C3-3b4 pump round-robin은 지속 유입에서도 기존 owner를 굶기지 않는다" {
    var fixture: B4PumpFixture = undefined;
    try fixture.init(17);
    defer fixture.deinit();
    B4PumpProbe.reset();
    B5TestState.event_pump_hook = B4PumpProbe.run;
    for (0..17) |_| {
        fixture.backend.maintenanceEventTick();
        fixture.consumeFrame(17);
    }
    for (B4PumpProbe.seen) |value| try testing.expect(value >= 16);
}
