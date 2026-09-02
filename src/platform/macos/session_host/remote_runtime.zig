//! remote_runtime — **client 쪽 원격 runtime**(host runtime의 client-side 상대) — P3-e2e-2c-2.
//!
//! host의 `runtime_manager`(host 프로세스가 실 PTY/`TerminalCore`를 소유)와 대칭이다: 이쪽은 client RPC로 그 host runtime을
//! spawn/제어하고, host가 보내는 snapshot/delta stream을 `RemoteScreen`(조립기+cell 격자)으로 조립해 **원격-backed `Surface`**
//! 로 노출한다. GUI는 이 `Surface`를 in-process runtime과 똑같이 렌더한다(`surface.renderSnapshot()` — SSOT). 즉 이 파일이
//! "원격 runtime = client가 든 Surface 하나"라는 client-side 소유 모델을 만든다.
//!
//! 범위(e2e-2c-2): client-side runtime 소유·제어·화면까지다. P2 `TermRuntimeBackend` **vtable 어댑터**와 GUI **frame-loop
//! pump 배선**(delta stream을 매 프레임 소비, `RuntimeEventPump` 재해석)은 app_session이 프레임 루프를 만지는 **e3**에서 이
//! 위에 얹는다 — 여기 `pumpDelta`는 그 배선이 부를 수 있는 최소 단위(한 delta batch 소비)다. macOS 전용(client·Surface·terminal).

const std = @import("std");
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");
const catchup_stage_contract = @import("catchup_stage_contract.zig");
const client_deadline = @import("client_deadline.zig");
const maru = @import("maru");
const terminal = maru.terminal;
const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const runtime_pump_mod = maru.app.runtime_pump;
const input_owner_mod = maru.app.input_owner;
const client_mod = @import("client.zig");
const client_slot_mod = @import("client_slot.zig");
const r2a_client_slot = client_slot_mod;
const client_poison = @import("client_poison.zig");
const client_idle_pump_evidence = @import("client_idle_pump_evidence.zig");
const control_response_wire = @import("control_response_wire.zig");
const protocol = @import("protocol.zig");
const screen_assembler = @import("maru").session.screen_assembler;
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const resize_wire = @import("resize_wire.zig");
const core_command_wire = @import("core_command_wire.zig");
const runtime_pending_control = @import("runtime_pending_control.zig");
const pending_event_owner_mod = @import("pending_event_owner.zig");
const remote_close_authority = @import("remote_close_authority.zig");
const shutdown_attempt_authority_mod = @import("shutdown_attempt_authority.zig");
const shutdown_current_admin_mod = @import("shutdown_current_admin.zig");
const runtime_lifetime_owner_mod = @import("runtime_lifetime_owner.zig");
const reconnect_mutation_seal = @import("reconnect_mutation_seal.zig");
const process_seal_service = @import("process_seal_service.zig");
const remote_attachment = @import("remote_attachment.zig");
const generation_attachment_mod = @import("generation_attachment.zig");
const generation_contract = @import("generation_attachment_contract.zig");
const generation_event_contract_mod = @import("generation_event_contract.zig");
const pending_event_preparation_mod = @import("pending_event_preparation.zig");
const remote_runtime_pending_event_mod = @import("remote_runtime_pending_event.zig");
const runtime_event_prepared_types_mod = @import("runtime_event_prepared_types.zig");
const runtime_observation_digest_mod = @import("runtime_observation_digest.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const host_adapter_mod = @import("host_adapter.zig");
const app_process_incident_owner = @import("app_process_incident_owner.zig");
const incident_publication_contract = maru.observability.incident_publication_contract;
const connection_incident = @import("maru").observability.connection_incident;
const host_manifest_mod = @import("host_manifest.zig");
const client_poison_mod = @import("client_poison.zig");
const stable_screen_source = @import("stable_screen_source.zig");
const reconnect_generation_slot = @import("reconnect_generation_slot.zig");
const reconnect_reducer = @import("reconnect_reducer.zig");
const process_identity_mod = @import("process_identity.zig");

var remote_runtime_owner_incarnation_issuer: std.atomic.Value(u64) = .init(1);
var reconnect_generation_owner_incarnation_issuer: std.atomic.Value(u64) = .init(1);

const B4SemanticProofLossStage = enum(u8) {
    none = 0,
    observation_drift = 1,
    continuation_drift = 2,
};

const B4SemanticProofLossTestState = if (builtin.is_test) struct {
    threadlocal var stage: B4SemanticProofLossStage = .none;
} else struct {};

fn nextRemoteRuntimeOwnerIncarnation() ?u64 {
    var current = remote_runtime_owner_incarnation_issuer.load(.monotonic);
    while (current != 0 and current != std.math.maxInt(u64)) {
        if (remote_runtime_owner_incarnation_issuer.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
            continue;
        }
        return current;
    }
    return null;
}

fn nextReconnectGenerationOwnerIncarnation() ?u64 {
    var current = reconnect_generation_owner_incarnation_issuer.load(.monotonic);
    while (current != 0 and current != std.math.maxInt(u64)) {
        if (reconnect_generation_owner_incarnation_issuer.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
            continue;
        }
        return current;
    }
    return null;
}

const RuntimeAttachment = union(enum) {
    legacy: remote_attachment.RemoteAttachment,
    generation: generation_attachment_mod.GenerationAttachment,

    pub fn init(allocator: std.mem.Allocator, state: remote_attachment.State) RuntimeAttachment {
        return .{ .legacy = remote_attachment.RemoteAttachment.init(allocator, state) };
    }

    fn initGenerationInPlace(
        self: *RuntimeAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) !void {
        self.* = .{ .generation = .{} };
        try generation_attachment_mod.GenerationAttachment.initInPlace(&self.generation, adapter);
    }

    fn deinit(self: *RuntimeAttachment) void {
        switch (self.*) {
            .legacy => |*value| value.deinit(),
            .generation => @panic("generation attachment requires its retained adapter"),
        }
    }

    fn deinitWithConnection(self: *RuntimeAttachment, connection: RuntimeConnection) void {
        switch (self.*) {
            .legacy => |*value| switch (connection) {
                .legacy => value.deinit(),
                .generation => @panic("runtime connection and attachment mode diverged"),
            },
            .generation => |*value| switch (connection) {
                .legacy => @panic("runtime connection and attachment mode diverged"),
                .generation => |adapter| value.deinit(adapter),
            },
        }
    }

    fn streamId(self: *const RuntimeAttachment) u64 {
        return switch (self.*) {
            .legacy => |*value| value.streamId(),
            .generation => |*value| value.streamId(),
        };
    }

    fn allowsMutation(self: *const RuntimeAttachment) bool {
        return switch (self.*) {
            .legacy => |*value| value.allowsMutation(),
            .generation => |*value| generationAttachmentAttached(value) and value.allowsMutation(),
        };
    }

    fn mutationAllowed(
        self: *const RuntimeAttachment,
        client: *const client_mod.Client,
    ) bool {
        return switch (self.*) {
            .legacy => |*value| value.allowsMutation() and
                !client.hasBufferedControllerRevokeForStream(value.streamId()),
            .generation => |*value| generationAttachmentAttached(value) and value.allowsMutation(),
        };
    }

    fn statePtr(self: *RuntimeAttachment) *remote_attachment.State {
        return switch (self.*) {
            .legacy => |*value| &value.state,
            .generation => |*value| value.statePtr(),
        };
    }

    pub fn screenPtr(self: *RuntimeAttachment) ?*@import("remote_screen.zig").RemoteScreen {
        return switch (self.*) {
            .legacy => |*value| if (value.screen) |*screen| screen else null,
            .generation => |*value| value.screenPtr(),
        };
    }

    fn initScreen(self: *RuntimeAttachment, codec: u16) anyerror!void {
        return switch (self.*) {
            .legacy => |*value| value.initScreen(codec),
            .generation => |*value| value.initScreen(codec),
        };
    }

    fn pumpScreen(
        self: *RuntimeAttachment,
        io: std.Io,
    ) (client_mod.ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!remote_attachment.PumpScreenResult {
        return switch (self.*) {
            .legacy => |*value| value.pumpScreen(io),
            .generation => |*value| value.pumpScreen(io),
        };
    }

    fn discardPendingScreen(
        self: *RuntimeAttachment,
    ) remote_attachment.LeaseError!void {
        return switch (self.*) {
            .legacy => |*value| value.discardPendingScreen(),
            .generation => |*value| value.discardPendingScreen(),
        };
    }

    fn applyValidatedRevokedAndFence(
        self: *RuntimeAttachment,
        client: ?*client_mod.Client,
        generation: u64,
    ) anyerror!client_mod.Client.RevokeFence {
        return switch (self.*) {
            .legacy => |*value| blk: {
                try value.applyValidatedRevoked(generation);
                break :blk try (client orelse return error.ProtocolError).fenceRevokedStream(value.streamId());
            },
            .generation => |*value| switch (try value.applyValidatedRevokedAndFence(generation)) {
                .no_pending_stream_frame => .no_pending_stream_frame,
                .cancelled_before_write => .cancelled_before_write,
                .partial_frame_requires_close => .partial_frame_requires_close,
            },
        };
    }

    fn applyPreparedRevokedNoFail(self: *RuntimeAttachment, generation: u64) void {
        switch (self.*) {
            .legacy => process_seal_service.fatalIntegrity(.proof_loss),
            .generation => |*value| value.applyPreparedRevokedNoFail(generation),
        }
    }

    fn sendInput(
        self: *RuntimeAttachment,
        client: *client_mod.Client,
        bytes: []const u8,
    ) client_mod.ClientError!void {
        return switch (self.*) {
            .legacy => |*value| client.sendInput(value.streamId(), bytes),
            .generation => |*value| value.sendInput(bytes) catch |err|
                return mapGenerationInputError(err),
        };
    }

    fn sendInputNonBlocking(
        self: *RuntimeAttachment,
        client: *client_mod.Client,
        bytes: []const u8,
    ) client_mod.ClientError!usize {
        return switch (self.*) {
            .legacy => |*value| client.sendInputNonBlocking(value.streamId(), bytes),
            .generation => |*value| value.sendInputNonBlocking(bytes) catch |err|
                return mapGenerationInputError(err),
        };
    }

    fn pumpPendingOutput(
        self: *RuntimeAttachment,
        client: ?*client_mod.Client,
    ) client_mod.ClientError!bool {
        return switch (self.*) {
            .legacy => (client orelse return error.ProtocolError).pumpPendingOutput(),
            .generation => |*value| value.pumpPendingOutput() catch |err|
                return mapGenerationInputError(err),
        };
    }

    fn sendResyncNonBlocking(
        self: *RuntimeAttachment,
        client: ?*client_mod.Client,
    ) client_mod.ClientError!bool {
        return switch (self.*) {
            .legacy => |*value| blk: {
                const transport = client orelse return error.ProtocolError;
                const accepted = try transport.sendResyncNonBlocking(value.streamId());
                break :blk accepted;
            },
            .generation => |*value| value.sendResyncNonBlocking() catch |err|
                return mapGenerationInputError(err),
        };
    }

    fn screenRecoveryState(
        self: *RuntimeAttachment,
        client: ?*client_mod.Client,
    ) client_mod.ClientError!client_mod.ScreenRecoveryState {
        return switch (self.*) {
            .legacy => |*value| (client orelse return error.ProtocolError)
                .screenRecoveryState(value.streamId()),
            .generation => |*value| value.screenRecoveryState() catch |err|
                return mapGenerationInputError(err),
        };
    }

    fn callOrdered(
        self: *RuntimeAttachment,
        client: ?*client_mod.Client,
        method: []const u8,
        params_json: ?[]const u8,
    ) client_mod.ClientError![]u8 {
        return switch (self.*) {
            .legacy => (client orelse return error.ProtocolError).call(method, params_json),
            .generation => |*value| value.callOrdered(method, params_json),
        };
    }

    fn callDecoded(
        self: *RuntimeAttachment,
        runtime: *RemoteRuntime,
        client: ?*client_mod.Client,
        request: generation_contract.RuntimeRequest,
        legacy_method: []const u8,
        legacy_params_json: ?[]const u8,
        context: *anyopaque,
        decoder: generation_contract.RpcDecoder,
        poison_capture: ?client_slot_mod.PreparedExecutionPoisonCaptureRequest,
    ) client_mod.ClientError!generation_contract.RpcDecodeDisposition {
        if (&runtime.currentGeneration().attachment != self) return error.ProtocolError;
        if (!generation_contract.runtimeRequestTagRawValid(@ptrCast(&request.tag)))
            return error.ProtocolError;
        const tag: generation_contract.RuntimeRequestTag = @enumFromInt(request.tag);
        if (!std.mem.eql(u8, generation_contract.requestMethod(tag), legacy_method))
            return error.ProtocolError;
        return switch (self.*) {
            .legacy => blk: {
                const legacy = client orelse return error.ProtocolError;
                const response = try legacy.call(legacy_method, legacy_params_json);
                defer legacy.allocator.free(response);
                switch (preDecodeBufferedEvents(runtime)) {
                    .proceed => {},
                    .stale => return error.Unauthorized,
                    .busy => return error.AdminBusy,
                    .out_of_memory => return error.OutOfMemory,
                    .protocol_failure => return error.ProtocolError,
                    .connection_closed => return error.ConnectionClosed,
                }
                const disposition = decoder(context, tag, response);
                if (disposition == .protocol_failure)
                    legacy.poison(.peer_contract_violation);
                break :blk disposition;
            },
            .generation => |*value| generation_attachment_mod.executeRequestWithDecoderOwned(
                value,
                request,
                context,
                decoder,
                runtime,
                preDecodeBufferedEvents,
                poison_capture,
            ) catch |err| {
                return mapGenerationDecodedError(err);
            },
        };
    }

    fn preDecodeBufferedEvents(context: *anyopaque) generation_contract.RpcPreDecodeDisposition {
        const runtime: *RemoteRuntime = @ptrCast(@alignCast(context));
        const before_role = runtime.currentGeneration().attachment.statePtr().role;
        const before_generation = runtime.currentGeneration().attachment.statePtr().controller_generation;
        const drained = runtime.drainObservationEvents() catch |err| return switch (err) {
            error.AdminBusy => .busy,
            error.OutOfMemory => .out_of_memory,
            error.ConnectionClosed => .connection_closed,
            else => .protocol_failure,
        };
        if (drained.ended) return .connection_closed;
        const after = runtime.currentGeneration().attachment.statePtr();
        return if (before_role == .controller and
            (after.role != .controller or after.controller_generation != before_generation))
            .stale
        else
            .proceed;
    }

    fn hasBufferedControllerRevoke(
        self: *const RuntimeAttachment,
        client: *const client_mod.Client,
    ) bool {
        return switch (self.*) {
            .legacy => client.hasBufferedControllerRevoke(),
            .generation => |*value| value.hasBufferedControllerRevoke(),
        };
    }

    fn bindLegacyTransport(
        self: *RuntimeAttachment,
        transport: remote_attachment.AttachmentTransport,
    ) error{AlreadyBound}!void {
        return switch (self.*) {
            .legacy => |*value| value.bindTransport(transport),
            .generation => error.AlreadyBound,
        };
    }
};

const RuntimeConnection = union(enum) {
    legacy: *client_mod.Client,
    generation: *host_adapter_mod.HostAdapter,
};

fn mapGenerationInputError(err: @import("generation_transport.zig").InputError) client_mod.ClientError {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner, error.ProtocolError => error.ProtocolError,
        error.Unauthorized => error.Unauthorized,
        error.ResourceExhausted => error.OutOfMemory,
        error.ConnectionClosed => error.ConnectionClosed,
    };
}

fn mapGenerationDecodedError(err: @import("generation_transport.zig").Error) client_mod.ClientError {
    return switch (err) {
        error.AdminBusy => error.AdminBusy,
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionClosed => error.ConnectionClosed,
        error.ProtocolError,
        error.InvalidPreparedRpc,
        error.MovedOrCopied,
        error.DestinationOccupied,
        error.IdentityExhausted,
        error.InvalidTransport,
        error.InvalidReceipt,
        error.InvalidResponseDestination,
        => error.ProtocolError,
        else => |client_error| client_error,
    };
}

fn mapGenerationEventError(
    err: @import("generation_transport.zig").EventError,
) client_mod.ClientError {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner, error.Corrupt => error.ProtocolError,
        error.Terminal => error.ConnectionClosed,
    };
}

fn mapGenerationPurgeError(
    err: @import("generation_transport.zig").PurgeEndedError,
) client_mod.ClientError {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner, error.Corrupt => error.ProtocolError,
        error.Terminal => error.ConnectionClosed,
    };
}

const EventGenerationTracking = enum {
    untracked,
    tracked,
};

/// host에서 가져온 대기 OSC 9/777 데스크톱 알림 한 건(§6.32). title/body는 owned(caller가 deinit).
pub const Notification = struct {
    pub const Route = struct {
        host_id: u128,
        runtime_id: u128,
        event_id: u64,
        occurred_at_ns: u64,
    };
    title: []u8,
    body: []u8,
    display_label: ?[]u8 = null,
    route: ?Route = null,
    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
        if (self.display_label) |label| allocator.free(label);
    }
};

pub const NotificationBootstrap = struct {
    config_generation: u64,
    notifications_osc: bool,
    display_label: []const u8,
};

fn attachmentReadBatch(
    context: *anyopaque,
    stream_id: u64,
) client_mod.ClientError!?remote_attachment.AttachmentBatchLease {
    const client: *client_mod.Client = @ptrCast(@alignCast(context));
    return if (try client.readStreamBatch(stream_id)) |batch|
        .{ .untracked = batch }
    else
        null;
}

fn attachmentDropStream(context: *anyopaque, stream_id: u64) void {
    const client: *client_mod.Client = @ptrCast(@alignCast(context));
    client.dropBufferedStream(stream_id);
}

fn attachmentFailClosed(context: *anyopaque, reason: client_poison.ConnectionReason) void {
    const client: *client_mod.Client = @ptrCast(@alignCast(context));
    client.poison(reason);
}

fn attachmentTransport(client: *client_mod.Client) remote_attachment.AttachmentTransport {
    return .{
        .context = client,
        .read_batch = attachmentReadBatch,
        .drop_stream = attachmentDropStream,
        .fail_closed = attachmentFailClosed,
    };
}

fn metadataDtoMatchesObservation(
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
    view: term_backend.RuntimeObservationView,
) bool {
    if (view.availability != .current or
        dto.revision != view.revision or
        dto.observer_generation != view.observer_generation or
        dto.title_generation != view.title_generation or
        dto.cols != view.size.cols or dto.rows != view.size.rows or
        @intFromEnum(dto.semantic_state) != @intFromEnum(view.semantic_state) or
        dto.alt_active != view.alt_active or
        dto.app_cursor_keys != view.app_cursor_keys or
        dto.app_keypad != view.app_keypad or
        dto.kitty_flags != view.kitty_flags or
        dto.alternate_scroll != view.alternate_scroll or
        dto.mouse_tracking != view.mouse_tracking or
        dto.mouse_tracking_mode != view.mouse_tracking_mode or
        dto.bracketed_paste != view.bracketed_paste or
        dto.bell_count != view.bell_count or
        dto.clipboard_write_seq != view.clipboard_write_seq or
        dto.clipboard_read_seq != view.clipboard_read_seq or
        dto.foreground_available != view.foreground_available or
        dto.foreground_pgid != view.foreground_pgid or
        !std.mem.eql(u8, dto.cwd(), view.cwd) or
        !std.mem.eql(u8, dto.cwdHost(), view.cwd_host) or
        !std.mem.eql(u8, dto.windowTitle(), view.window_title) or
        !std.mem.eql(u8, dto.clipboardReadTarget(), view.clipboard_read_target) or
        ((dto.sshRemoteDest() == null) != (view.ssh_remote_dest == null)) or
        dto.process_count != view.foreground_processes.len)
        return false;
    if (dto.sshRemoteDest()) |dest|
        if (!std.mem.eql(u8, dest, view.ssh_remote_dest.?)) return false;
    for (dto.foregroundProcesses(), view.foreground_processes) |a, b| {
        if (a.pid != b.pid or !std.mem.eql(u8, a.slice(), b.slice())) return false;
    }
    return true;
}

/// host-backed runtime의 프로세스 뿌리 둘. **0은 "모른다"** 다 — 구 host(필드 없음)이거나 아직 관측이
/// 도착하지 않은 상태이고, 그때 소비자는 표본을 못 얻는 것으로 다룬다(0을 그리면 "0바이트를 쓰는 중"이 된다).
pub const ProcessIdentity = struct {
    /// host가 fork한 PTY 자식(`login`/셸)의 pid. 이 pid의 **트리**가 그 터미널의 사용량이다.
    child_pid: i32 = 0,
    /// 그 자식을 소유한 session host 데몬의 pid. 이 pid **자신만**이 데몬 오버헤드다(트리를 훑으면
    /// 위의 자식들과 겹쳐 이중 계산이 된다).
    host_pid: i32 = 0,

    /// 관측이 실어 온 값을 흡수한다. **0은 덮어쓰지 않는다** — 구 host의 관측이나 자식이 이미 회수된
    /// 관측이 한 번 섞이면 알고 있던 뿌리가 사라지고 그 탭이 영영 `—`가 된다. 값은 runtime 수명 동안
    /// 안 바뀌므로(PTY는 한 번 fork된다) **유지가 옳다**.
    pub fn adopt(self: *ProcessIdentity, child_pid: i32, host_pid: i32) void {
        if (child_pid > 0) self.child_pid = child_pid;
        if (host_pid > 0) self.host_pid = host_pid;
    }

    /// 관측을 못 믿을 때(`availability != .current`) **아무것도 모르는 상태**로 되돌린다.
    ///
    /// pid 는 캐시다 — host 와 말이 끊긴 뒤에도 값이 남아 있는데, 그 사이 그 pid 가 죽고 **OS 가 같은
    /// 번호를 남에게 재사용하면 남의 메모리를 그 탭 것으로 그린다.** 숫자가 그럴듯해서 화면으로는 절대
    /// 못 잡는 종류라, 못 믿을 때는 재지 않는 편이 낫다(그 행은 `—`가 된다).
    ///
    /// **캐시를 지우지는 않는다** — 다시 `current` 가 되면 그대로 살아난다(재접속마다 뿌리를 잃으면
    /// 그 탭이 한동안 `—`로 남는다). 판정만 하고 값은 `adopt` 가 소유한다.
    pub fn trusted(self: ProcessIdentity, observation_is_current: bool) ProcessIdentity {
        return if (observation_is_current) self else .{};
    }
};

/// Active connection과 함께 교체·retire되는 generation-local owner bundle이다. CR2a는 기존
/// field를 물리적으로 묶기만 하며 allocator, Surface와 stable input/lifecycle owner를 섞지 않는다.
pub const RemoteGeneration = struct {
    connection: RuntimeConnection,
    /// Stable shell generation과 독립된 shared Client transport generation이다.
    /// generation connection에서는 exact HostAdapter.ClientSlot current와 일치해야 한다.
    connection_generation: u64 = 0,
    attachment: RuntimeAttachment,
    event_generation_tracking: EventGenerationTracking,
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    resize_generation: u64,
    resize_baseline_present: bool,
    // shared transport hard failure를 이 runtime surface에 한 번만 투영한다. connection 하나를 여러 runtime이
    // 공유하므로 각 runtime pump가 자기 surface를 exited로 latch하되 매 frame 같은 read_error를 재방출하지 않는다.
    pump_ended: bool,
    resync_needed: bool,
    observation_probe_active: u64 = 0,
    /// Timed-out correlation retained until its late event arrives. A new probe cannot overtake it.
    observation_probe_abandoned: u64 = 0,
    observation_probe_completed: u64 = 0,
    frame_summary_ready: bool = false,
    frame_summary: runtime_pump_mod.DrainSummary = .{},
    observation: term_backend.RuntimeObservation, // host attach/event에서 받은 화면 외 full-state owned cache.
};

/// 남이 세션을 좁혔는가(S11-6). `requested` 는 이 client 가 마지막으로 요청한 열, `applied` 는
/// host 가 **방금 확정한** 열이다. 돌려주는 값은 좁혀진 열이고 0 은 「아무도 안 좁혔다」다.
///
/// **`runtime.resized` 순간에만 부른다.** 프레임마다 창 크기와 견주면 사용자가 창을 넓히는 동안
/// host 확정 전까지 참이 되어 폰이 없어도 표시가 번쩍인다.
pub fn narrowedFrom(requested: u16, applied: u16) u16 {
    // **「아직 요청한 적 없음」(`requested == 0`)에 가드를 두지 않는다.** u16 이라 그때는
    // `applied < 0` 이 성립할 수 없어 이 식이 이미 0 을 낸다 — 가드를 두었더니 변이 검사에서
    // 살아남아 닿지 않는 코드임이 드러났다(2026-09-02). 그 경우의 «동작» 은 아래 판정자가 지킨다.
    return if (applied < requested) applied else 0;
}

const RemoteGenerationSlot = reconnect_generation_slot.GenerationSlot(RemoteGeneration);

pub const PreparedReconnect = struct {
    const Lifecycle = enum(u8) { pristine, candidate };

    self_addr: usize = 0,
    owner_addr: usize = 0,
    lifecycle: Lifecycle = .pristine,
    candidate: RemoteGenerationSlot.PreparedCandidate = .{},
};

/// CR3c2 tick-end authority. retiring RemoteGeneration과 oldest retired Client를
/// 각각의 final-address receipt로 고정하고 exact 같은 transport generation일 때만 묶는다.
pub const PreparedOrderedRetiringReclaim = struct {
    pub const Lifecycle = enum(u8) { pristine, prepared, reclaimed };

    self_addr: usize = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_addr: usize = 0,
    owner_incarnation: u64 = 0,
    adapter_addr: usize = 0,
    connection_generation: u64 = 0,
    remote: RemoteGenerationSlot.PreparedRetiringReclaim = .{},
    client: client_slot_mod.PreparedRetiredClientReclaim = .{},
    lifecycle: Lifecycle = .pristine,
};

fn preparedOrderedRetiringLifecycleRawValid(
    value: *const PreparedOrderedRetiringReclaim.Lifecycle,
) bool {
    return switch (@as(*const u8, @ptrCast(value)).*) {
        @intFromEnum(PreparedOrderedRetiringReclaim.Lifecycle.pristine),
        @intFromEnum(PreparedOrderedRetiringReclaim.Lifecycle.prepared),
        @intFromEnum(PreparedOrderedRetiringReclaim.Lifecycle.reclaimed),
        => true,
        else => false,
    };
}

fn generationAttachmentTerminal(
    attachment: *const generation_attachment_mod.GenerationAttachment,
) bool {
    return @as(*const u8, @ptrCast(&attachment.lifecycle)).* ==
        @intFromEnum(generation_attachment_mod.Lifecycle.terminal);
}

fn generationAttachmentAttached(
    attachment: *const generation_attachment_mod.GenerationAttachment,
) bool {
    return @as(*const u8, @ptrCast(&attachment.lifecycle)).* ==
        @intFromEnum(generation_attachment_mod.Lifecycle.attached);
}

const ReconnectGenerationEffect = enum(u8) {
    retain,
    prepare_candidate,
    abort_candidate_if_present,
    publish_candidate,
    reclaim_retiring_if_present,
};

const reconnect_resident_budget = @import("reconnect_resident_budget.zig");
const reconnect_admission_owner = @import("reconnect_admission_owner.zig");

/// Reducer의 closed Decision을 실제 generation owner effect와 연결하는 단일 제품 표다.
/// 상태 전이와 제품 effect가 따로 drift하지 않도록 새 Decision은 이 switch를 반드시 갱신한다.
fn reconnectGenerationEffect(decision: reconnect_reducer.Decision) ReconnectGenerationEffect {
    return switch (decision) {
        .prepare_candidate, .retry_job => .prepare_candidate,
        .abort_candidate_restore_old,
        .abort_candidate_restore_old_with_paused_notice,
        .abort_candidate_freeze_old,
        .publish_unavailable_with_retry,
        .publish_ended,
        .publish_job_unavailable,
        .close_preserve_old,
        .close_preserve_old_with_paused_notice,
        .close_freeze_with_retry,
        .close_finish_terminal,
        => .abort_candidate_if_present,
        .publish_new_and_open, .close_publish_new => .publish_candidate,
        .finish_job => .reclaim_retiring_if_present,
        .retain_staged_observer,
        .seal_mutations,
        .retain_clean_seal,
        .retain_ambiguous_seal,
        .start_authority_commit,
        .retain_takeover_unknown,
        .retain_controller_evidence,
        .retain_authority_conflict,
        .retain_gone_evidence,
        .wait_for_direct_release,
        .resume_with_direct_grant,
        .publish_retry_conflict,
        .start_publication,
        .publish_termination_pending,
        .publish_termination_unconfirmed,
        .abandon_shell_to_inventory,
        => .retain,
    };
}

fn reconnectRetiringMatchesLocal(
    local: reconnect_reducer.LocalState,
    has_retiring: bool,
) bool {
    return has_retiring == (local == .published_new);
}

/// Stable `RemoteRuntime` 안에 final-address로 고정되는 reconnect executor다. reducer state와
/// `PreparedReconnect`를 같은 owner가 보유하고 product effect 성공 뒤에만 다음 state를 게시한다.
const ReconnectProductExecutor = struct {
    self_addr: usize = 0,
    owner_pid: u32 = 0,
    owner_thread: ?std.Thread.Id = null,
    generation_owner_addr: usize = 0,
    state: ?reconnect_reducer.State = null,
    prepared: PreparedReconnect = .{},
    admission: ?reconnect_admission_owner.Projection = null,
    admission_seal: process_seal_service.CleanupSeal = [_]u8{0} ** 32,
    resident_budget_addr: usize = 0,
    resident_lease: reconnect_resident_budget.Lease = .{},
    live: bool = false,

    fn initInPlace(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        job_generation: u64,
    ) !void {
        if (!std.meta.eql(self.*, ReconnectProductExecutor{})) return error.InvalidAuthority;
        try owner.validate();
        const shell_generation = try owner.currentGeneration();
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_pid = process_identity_mod.currentProcessId(),
            .owner_thread = std.Thread.getCurrentId(),
            .generation_owner_addr = @intFromPtr(owner),
            .state = reconnect_reducer.State.initial(job_generation, shell_generation),
            .prepared = .{},
            .live = true,
        };
    }

    fn bindAdmission(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
        admission: reconnect_admission_owner.Projection,
        resident_bytes: usize,
    ) !void {
        try self.validate(owner);
        if (self.admission != null or self.resident_budget_addr != 0 or
            !std.meta.eql(self.resident_lease, reconnect_resident_budget.Lease{}))
            return error.Busy;
        const shell_generation = try owner.currentGeneration();
        try budget.reserve(&self.resident_lease, resident_bytes, .candidate);
        const seal = self.sealAdmission(budget, admission) catch |err| {
            budget.release(&self.resident_lease, .candidate) catch
                process_seal_service.fatalIntegrity(.proof_loss);
            return err;
        };
        self.admission = admission;
        self.admission_seal = seal;
        self.resident_budget_addr = @intFromPtr(budget);
        self.state = reconnect_reducer.State.initial(
            admission.incident_id.sequence,
            shell_generation,
        );
    }

    fn apply(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        event: reconnect_reducer.Event,
        args: anytype,
        comptime initializer: anytype,
    ) !reconnect_reducer.Decision {
        try self.validate(owner);
        const result = try reconnect_reducer.reduce(self.state.?, event);
        try self.executeEffect(owner, reconnectGenerationEffect(result.decision), args, initializer);
        self.state = result.state;
        return result.decision;
    }

    fn applyCloseTransition(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        event: CloseEvent,
    ) !reconnect_reducer.Decision {
        try self.validate(owner);
        const result = try reconnect_reducer.reduce(self.state.?, try event.reducerEvent());
        switch (reconnectGenerationEffect(result.decision)) {
            .retain => {},
            .abort_candidate_if_present => {
                const budget = if (self.resident_budget_addr != 0 and self.resident_lease.role == .candidate)
                    @as(*reconnect_resident_budget.ReconnectAdmissionBudget, @ptrFromInt(self.resident_budget_addr))
                else
                    null;
                if (budget) |value| try value.validateLeaseRole(&self.resident_lease, .candidate);
                if (!std.meta.eql(self.prepared, PreparedReconnect{})) try owner.abort(&self.prepared);
                if (budget) |value| {
                    value.release(&self.resident_lease, .candidate) catch
                        process_seal_service.fatalIntegrity(.proof_loss);
                    self.resident_budget_addr = 0;
                    self.admission = null;
                    self.admission_seal = [_]u8{0} ** 32;
                }
            },
            .publish_candidate => {
                if (std.meta.eql(self.prepared, PreparedReconnect{})) return error.InvalidAuthority;
                const budget = if (self.resident_budget_addr != 0)
                    @as(*reconnect_resident_budget.ReconnectAdmissionBudget, @ptrFromInt(self.resident_budget_addr))
                else
                    null;
                if (budget) |value| try value.validateLeaseRole(&self.resident_lease, .candidate);
                try owner.publish(&self.prepared);
                if (budget) |value| value.publishSwap(null, &self.resident_lease) catch
                    process_seal_service.fatalIntegrity(.proof_loss);
            },
            else => return error.InvalidAuthority,
        }
        self.state = result.state;
        return result.decision;
    }

    fn completeJob(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        summary: reconnect_reducer.TerminalSummary,
    ) !void {
        try self.validate(owner);
        const result = try reconnect_reducer.completeJob(self.state.?, summary);
        if (reconnectGenerationEffect(result.decision) != .reclaim_retiring_if_present)
            return error.InvalidAuthority;
        const has_retiring = try owner.slot.hasRetiring();
        if (!reconnectRetiringMatchesLocal(self.state.?.local, has_retiring))
            return error.InvalidAuthority;
        if (self.resident_budget_addr != 0) {
            const budget: *reconnect_resident_budget.ReconnectAdmissionBudget = @ptrFromInt(
                self.resident_budget_addr,
            );
            try budget.validateLeaseRole(&self.resident_lease, self.resident_lease.role);
        }
        if (has_retiring) try owner.reclaimRetiringAtTickEnd();
        if (self.resident_budget_addr != 0) {
            const budget: *reconnect_resident_budget.ReconnectAdmissionBudget = @ptrFromInt(
                self.resident_budget_addr,
            );
            budget.release(&self.resident_lease, self.resident_lease.role) catch
                process_seal_service.fatalIntegrity(.proof_loss);
            self.resident_budget_addr = 0;
            self.admission = null;
            self.admission_seal = [_]u8{0} ** 32;
        }
        self.state = result.state;
    }

    fn deinit(self: *ReconnectProductExecutor, owner: *ReconnectGenerationOwner) !void {
        // attach/spawn은 wire 응답과 initial snapshot을 모두 검증한 뒤에만 executor를
        // 게시한다. 그 전 실패를 정산하는 RemoteRuntime errdefer도 같은 teardown
        // leaf를 사용하므로 pristine destination은 mutation 없는 정상 정산이다.
        if (std.meta.eql(self.*, ReconnectProductExecutor{})) return;
        try self.validate(owner);
        if (!std.meta.eql(self.prepared, PreparedReconnect{}) or self.state.?.phaseTag() != .healthy)
            return error.Busy;
        if (self.resident_budget_addr != 0) {
            const budget: *reconnect_resident_budget.ReconnectAdmissionBudget = @ptrFromInt(
                self.resident_budget_addr,
            );
            try budget.validateLeaseRole(&self.resident_lease, self.resident_lease.role);
            budget.release(&self.resident_lease, self.resident_lease.role) catch
                process_seal_service.fatalIntegrity(.proof_loss);
            self.resident_budget_addr = 0;
            self.admission = null;
            self.admission_seal = [_]u8{0} ** 32;
        }
        if (self.admission != null or
            !std.meta.eql(self.resident_lease, reconnect_resident_budget.Lease{}))
            return error.InvalidAuthority;
        self.* = .{};
    }

    fn preflightExternalPublication(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        next_shell_generation: u64,
    ) !u64 {
        try self.validate(owner);
        // Legacy CR5 callers have no resident admission. CR6e-c3b2b deliberately retains a
        // fully validated bound admission through publication and releases it only after the
        // all-runtime terminal summary. `validate` above authenticates either complete shape and
        // rejects every partial lease/admission combination.
        if (!std.meta.eql(self.prepared, PreparedReconnect{}))
            return error.InvalidAuthority;
        const job_generation = switch (self.state.?.phase) {
            .healthy => |value| value,
            else => return error.InvalidAuthority,
        };
        const expected_shell_generation = std.math.add(
            u64,
            self.state.?.shell_generation,
            1,
        ) catch return error.InvalidAuthority;
        if (expected_shell_generation != next_shell_generation) return error.InvalidAuthority;
        return std.math.add(u64, job_generation, 1) catch error.InvalidAuthority;
    }

    fn publishExternalNoFail(
        self: *ReconnectProductExecutor,
        next_job_generation: u64,
        next_shell_generation: u64,
    ) void {
        self.state = reconnect_reducer.State.initial(next_job_generation, next_shell_generation);
    }

    fn executeEffect(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
        effect: ReconnectGenerationEffect,
        args: anytype,
        comptime initializer: anytype,
    ) !void {
        switch (effect) {
            .retain => {},
            .prepare_candidate => {
                if (!std.meta.eql(self.prepared, PreparedReconnect{}))
                    return error.InvalidAuthority;
                try owner.prepare(&self.prepared, args, initializer);
            },
            .abort_candidate_if_present => {
                const budget = if (self.resident_budget_addr != 0 and self.resident_lease.role == .candidate)
                    @as(*reconnect_resident_budget.ReconnectAdmissionBudget, @ptrFromInt(self.resident_budget_addr))
                else
                    null;
                if (budget) |value| try value.validateLeaseRole(&self.resident_lease, .candidate);
                if (!std.meta.eql(self.prepared, PreparedReconnect{}))
                    try owner.abort(&self.prepared);
                if (budget) |value| {
                    value.release(&self.resident_lease, .candidate) catch
                        process_seal_service.fatalIntegrity(.proof_loss);
                    self.resident_budget_addr = 0;
                    self.admission = null;
                    self.admission_seal = [_]u8{0} ** 32;
                }
            },
            .publish_candidate => {
                if (std.meta.eql(self.prepared, PreparedReconnect{}))
                    return error.InvalidAuthority;
                const budget = if (self.resident_budget_addr != 0)
                    @as(*reconnect_resident_budget.ReconnectAdmissionBudget, @ptrFromInt(self.resident_budget_addr))
                else
                    null;
                if (budget) |value| try value.validateLeaseRole(&self.resident_lease, .candidate);
                try owner.publish(&self.prepared);
                if (budget) |value| value.publishSwap(null, &self.resident_lease) catch
                    process_seal_service.fatalIntegrity(.proof_loss);
            },
            // finish_job은 reduce(event)가 아니라 completeJob()에서만 생긴다.
            // terminal effect를 이 일반 event executor에서 실행하면 dead caller가 생긴다.
            .reclaim_retiring_if_present => return error.InvalidAuthority,
        }
    }

    fn validate(
        self: *ReconnectProductExecutor,
        owner: *ReconnectGenerationOwner,
    ) !void {
        if (!self.live or self.self_addr != @intFromPtr(self) or
            self.owner_pid == 0 or self.owner_pid != process_identity_mod.currentProcessId() or
            self.owner_thread == null or self.owner_thread.? != std.Thread.getCurrentId() or
            self.generation_owner_addr != @intFromPtr(owner) or self.state == null or
            !reconnect_reducer.valid(self.state.?)) return error.InvalidAuthority;
        try owner.validate();
        if (self.resident_budget_addr == 0) {
            if (self.admission != null or !std.mem.eql(u8, &self.admission_seal, &([_]u8{0} ** 32)) or
                !std.meta.eql(self.resident_lease, reconnect_resident_budget.Lease{}))
                return error.InvalidAuthority;
        } else {
            if (self.admission == null or !self.resident_lease.active or
                self.resident_lease.owner_addr != self.resident_budget_addr)
                return error.InvalidAuthority;
            const budget: *reconnect_resident_budget.ReconnectAdmissionBudget = @ptrFromInt(
                self.resident_budget_addr,
            );
            _ = try budget.snapshot();
            try budget.validateLeaseRole(&self.resident_lease, self.resident_lease.role);
            const expected = try self.sealAdmission(budget, self.admission.?);
            if (!std.crypto.timing_safe.eql(
                process_seal_service.CleanupSeal,
                self.admission_seal,
                expected,
            )) return error.InvalidAuthority;
        }
        if (self.state.?.shell_generation != try owner.currentGeneration())
            return error.InvalidAuthority;
    }

    fn sealAdmission(
        self: *const ReconnectProductExecutor,
        budget: *const reconnect_resident_budget.ReconnectAdmissionBudget,
        admission: reconnect_admission_owner.Projection,
    ) !process_seal_service.CleanupSeal {
        return process_seal_service.reconnectExecutorAdmissionSeal(
            self.owner_pid,
            self.resident_lease.process_nonce,
            .{
                .executor_addr = @intFromPtr(self),
                .generation_owner_addr = self.generation_owner_addr,
                .budget_addr = @intFromPtr(budget),
                .lease_addr = @intFromPtr(&self.resident_lease),
                .lease_generation = self.resident_lease.generation,
                .slot_index = admission.slot_index,
                .slot_generation = admission.slot_generation,
                .host_id = admission.host_id,
                .host_adapter_generation = admission.host_adapter_generation,
                .connection_generation = admission.connection_generation,
                .incident_app_instance_nonce = admission.incident_id.app_instance_nonce,
                .incident_sequence = admission.incident_id.sequence,
            },
        );
    }
};

pub const DirectReleaseProjection = struct {
    host_id: u128 = 0,
    host_adapter_generation: u64 = 0,
    connection_generation: u64 = 0,
    incident_app_instance_nonce: u128 = 0,
    incident_sequence: u64 = 0,
    job_generation: u64 = 0,
    shell_generation: u64 = 0,
    attempt: u64 = 0,
    candidate_connection_generation: u64 = 0,
    deadline_ns: u64 = 0,
    runtime_id: [16]u8 = [_]u8{0} ** 16,
};

/// CR5 host job이 connect 전에 runtime membership을 봉인할 때 읽는 최소 identity다.
/// mutation/local 전이는 host job의 runtime ledger가 소유하므로 이 projection은 stable runtime id와
/// 현재 shell generation만 내보낸다.
pub const RuntimeSetIdentityProjection = struct {
    runtime_id: u128,
    shell_generation: u64,
};

pub const CloseEventTag = enum(u8) {
    termination_requested = 1,
    reconnect_quiesced = 2,
    termination_timed_out = 3,
    abandon_to_inventory = 4,
};

/// Coordinator 밖으로 pointer나 reducer 내부 union을 노출하지 않는 closed close event다.
pub const CloseEvent = struct {
    tag_raw: u8 = 0,
    intent_generation: u64 = 0,
    shell_generation: u64 = 0,
    deadline_ns: u64 = 0,
    now_ns: u64 = 0,
    old_transport_usable: u8 = 0,
    retry_present: u8 = 0,
    retry_row_id: u64 = 0,
    retry_generation: u64 = 0,
    retry_shell_generation: u64 = 0,

    pub fn init(close_tag: CloseEventTag) CloseEvent {
        return .{ .tag_raw = @intFromEnum(close_tag) };
    }

    pub fn tag(self: CloseEvent) !CloseEventTag {
        return switch (self.tag_raw) {
            1 => .termination_requested,
            2 => .reconnect_quiesced,
            3 => .termination_timed_out,
            4 => .abandon_to_inventory,
            else => error.InvalidExternalEvent,
        };
    }

    fn reducerEvent(self: CloseEvent) !reconnect_reducer.Event {
        return switch (try self.tag()) {
            .termination_requested => blk: {
                if (self.intent_generation == 0 or self.shell_generation == 0 or self.deadline_ns == 0 or
                    self.now_ns != 0 or self.old_transport_usable != 0 or self.retry_present != 0 or
                    self.retry_row_id != 0 or self.retry_generation != 0 or self.retry_shell_generation != 0)
                    return error.InvalidExternalEvent;
                break :blk .{ .close_requested = .{
                    .intent_generation = self.intent_generation,
                    .shell_generation = self.shell_generation,
                    .deadline_ns = self.deadline_ns,
                } };
            },
            .reconnect_quiesced => blk: {
                if (self.intent_generation != 0 or self.shell_generation != 0 or self.deadline_ns != 0 or
                    self.now_ns != 0 or self.old_transport_usable > 1 or self.retry_present > 1)
                    return error.InvalidExternalEvent;
                const retry: ?reconnect_reducer.RetryReservation = if (self.retry_present == 1) .{
                    .row_id = self.retry_row_id,
                    .generation = self.retry_generation,
                    .shell_generation = self.retry_shell_generation,
                } else null;
                if (retry == null and (self.retry_row_id != 0 or self.retry_generation != 0 or
                    self.retry_shell_generation != 0)) return error.InvalidExternalEvent;
                break :blk .{ .reconnect_quiesced_for_close = .{
                    .old_transport_usable = self.old_transport_usable == 1,
                    .retry = retry,
                } };
            },
            .termination_timed_out => blk: {
                if (self.now_ns == 0 or self.intent_generation != 0 or self.shell_generation != 0 or
                    self.deadline_ns != 0 or self.old_transport_usable != 0 or self.retry_present != 0 or
                    self.retry_row_id != 0 or self.retry_generation != 0 or self.retry_shell_generation != 0)
                    return error.InvalidExternalEvent;
                break :blk .{ .close_timed_out = .{ .now_ns = self.now_ns } };
            },
            .abandon_to_inventory => blk: {
                if (self.intent_generation != 0 or self.shell_generation != 0 or self.deadline_ns != 0 or
                    self.now_ns != 0 or self.old_transport_usable != 0 or self.retry_present != 0 or
                    self.retry_row_id != 0 or self.retry_generation != 0 or self.retry_shell_generation != 0)
                    return error.InvalidExternalEvent;
                break :blk .abandon_to_inventory;
            },
        };
    }
};

/// Reducer union을 padding-free scalar로 정규화한 before/after snapshot이다.
pub const CloseStateProjection = struct {
    phase_raw: u8 = 0,
    job_generation: u64 = 0,
    work_shell_generation: u64 = 0,
    attempt: u64 = 0,
    candidate_connection_generation: u64 = 0,
    phase_deadline_ns: u64 = 0,
    runtime_id: [16]u8 = [_]u8{0} ** 16,
    unavailable_retry_at_ns: u64 = 0,
    unavailable_last_attempt: u64 = 0,
    unavailable_last_candidate_connection_generation: u64 = 0,
    ledger_raw: u8 = 0,
    local_raw: u8 = 0,
    mutation_raw: u8 = 0,
    close_raw: u8 = 0,
    close_intent_generation: u64 = 0,
    close_shell_generation: u64 = 0,
    close_deadline_ns: u64 = 0,
    retry_present: u8 = 0,
    retry_row_id: u64 = 0,
    retry_generation: u64 = 0,
    retry_shell_generation: u64 = 0,
    shell_generation: u64 = 0,
};

pub const CloseTransitionProjection = struct {
    before: CloseStateProjection = .{},
    event: CloseEvent = .{},
    decision_raw: u8 = 0,
    after: CloseStateProjection = .{},
};

pub fn closeTransitionDigest(projection: CloseTransitionProjection) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.reconnect-close-transition.v1");
    updateCloseState(&hasher, projection.before);
    updateCloseEvent(&hasher, projection.event);
    updateCloseU8(&hasher, projection.decision_raw);
    updateCloseState(&hasher, projection.after);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn updateCloseU8(hasher: *std.crypto.hash.Blake3, value: u8) void {
    hasher.update(&.{value});
}

fn updateCloseU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn updateCloseEvent(hasher: *std.crypto.hash.Blake3, event: CloseEvent) void {
    updateCloseU8(hasher, event.tag_raw);
    updateCloseU64(hasher, event.intent_generation);
    updateCloseU64(hasher, event.shell_generation);
    updateCloseU64(hasher, event.deadline_ns);
    updateCloseU64(hasher, event.now_ns);
    updateCloseU8(hasher, event.old_transport_usable);
    updateCloseU8(hasher, event.retry_present);
    updateCloseU64(hasher, event.retry_row_id);
    updateCloseU64(hasher, event.retry_generation);
    updateCloseU64(hasher, event.retry_shell_generation);
}

fn updateCloseState(hasher: *std.crypto.hash.Blake3, state: CloseStateProjection) void {
    updateCloseU8(hasher, state.phase_raw);
    updateCloseU64(hasher, state.job_generation);
    updateCloseU64(hasher, state.work_shell_generation);
    updateCloseU64(hasher, state.attempt);
    updateCloseU64(hasher, state.candidate_connection_generation);
    updateCloseU64(hasher, state.phase_deadline_ns);
    hasher.update(&state.runtime_id);
    updateCloseU64(hasher, state.unavailable_retry_at_ns);
    updateCloseU64(hasher, state.unavailable_last_attempt);
    updateCloseU64(hasher, state.unavailable_last_candidate_connection_generation);
    updateCloseU8(hasher, state.ledger_raw);
    updateCloseU8(hasher, state.local_raw);
    updateCloseU8(hasher, state.mutation_raw);
    updateCloseU8(hasher, state.close_raw);
    updateCloseU64(hasher, state.close_intent_generation);
    updateCloseU64(hasher, state.close_shell_generation);
    updateCloseU64(hasher, state.close_deadline_ns);
    updateCloseU8(hasher, state.retry_present);
    updateCloseU64(hasher, state.retry_row_id);
    updateCloseU64(hasher, state.retry_generation);
    updateCloseU64(hasher, state.retry_shell_generation);
    updateCloseU64(hasher, state.shell_generation);
}

fn closeStateProjection(state: reconnect_reducer.State) CloseStateProjection {
    var out: CloseStateProjection = .{
        .phase_raw = @intFromEnum(state.phaseTag()),
        .ledger_raw = @intFromEnum(state.ledger),
        .local_raw = @intFromEnum(state.local),
        .mutation_raw = @intFromEnum(state.mutation),
        .close_raw = @intFromEnum(std.meta.activeTag(state.close)),
        .shell_generation = state.shell_generation,
    };
    switch (state.phase) {
        .healthy => |generation| out.job_generation = generation,
        .preparing, .mutation_sealing, .authority_committing, .publishing => |work| {
            out.job_generation = work.job_generation;
            out.work_shell_generation = work.shell_generation;
            out.attempt = work.attempt;
            out.candidate_connection_generation = work.candidate_connection_generation;
            out.phase_deadline_ns = work.deadline_ns;
        },
        .retry_wait_release => |retry| {
            out.job_generation = retry.work.job_generation;
            out.work_shell_generation = retry.work.shell_generation;
            out.attempt = retry.work.attempt;
            out.candidate_connection_generation = retry.work.candidate_connection_generation;
            out.phase_deadline_ns = retry.work.deadline_ns;
            out.runtime_id = retry.runtime_id;
        },
        .unavailable => |value| {
            out.job_generation = value.job_generation;
            out.work_shell_generation = value.shell_generation;
            out.unavailable_retry_at_ns = value.retry_at_ns;
            out.phase_deadline_ns = value.deadline_ns;
            out.unavailable_last_attempt = value.last_attempt;
            out.unavailable_last_candidate_connection_generation = value.last_candidate_connection_generation;
        },
    }
    switch (state.close) {
        .none => {},
        .termination_pending, .termination_unconfirmed => |intent| {
            out.close_intent_generation = intent.intent_generation;
            out.close_shell_generation = intent.shell_generation;
            out.close_deadline_ns = intent.deadline_ns;
        },
        .abandoned_to_inventory => |generation| out.close_intent_generation = generation,
    }
    if (state.retry) |retry| {
        out.retry_present = 1;
        out.retry_row_id = retry.row_id;
        out.retry_generation = retry.generation;
        out.retry_shell_generation = retry.shell_generation;
    }
    return out;
}

fn closeTransitionProjectionForState(
    state: reconnect_reducer.State,
    event: CloseEvent,
) !CloseTransitionProjection {
    const result = try reconnect_reducer.reduce(state, try event.reducerEvent());
    return .{
        .before = closeStateProjection(state),
        .event = event,
        .decision_raw = @intFromEnum(result.decision),
        .after = closeStateProjection(result.state),
    };
}

/// CR2e-d의 제품 generation owner. 실제 RemoteGeneration을 candidate node의 final address에서
/// 완성하고 stable screen writer gate 안에서 slot current와 target을 함께 게시한다.
pub const ReconnectGenerationOwner = struct {
    self_addr: usize = 0,
    owner_pid: u32 = 0,
    owner_incarnation: u64 = 0,
    owner_thread: ?std.Thread.Id = null,
    allocator: ?std.mem.Allocator = null,
    screen_source: ?*stable_screen_source.StableScreenSource = null,
    screen_published: bool = false,
    slot: RemoteGenerationSlot = .{},

    const PublishContext = struct {
        slot: *RemoteGenerationSlot,
        candidate: *RemoteGenerationSlot.PreparedCandidate,

        fn commit(self: PublishContext) void {
            self.slot.publishCandidateNoFail(self.candidate);
        }
    };

    pub fn initInPlace(
        self: *ReconnectGenerationOwner,
        allocator: std.mem.Allocator,
        screen_source_ptr: *stable_screen_source.StableScreenSource,
        initial_generation: u64,
        args: anytype,
        comptime initializer: anytype,
    ) !void {
        try self.initBuildingInPlace(
            allocator,
            screen_source_ptr,
            initial_generation,
            args,
            initializer,
        );
        errdefer self.deinit() catch
            @panic("initial reconnect generation cleanup lost final owner");
        try self.publishInitial();
    }

    /// 제품 `RemoteRuntime`은 최초 generation payload를 final inline node에서 먼저 만들고,
    /// attach/snapshot이 screen을 완성한 뒤에만 stable proxy에 게시한다.
    pub fn initBuildingInPlace(
        self: *ReconnectGenerationOwner,
        allocator: std.mem.Allocator,
        screen_source_ptr: *stable_screen_source.StableScreenSource,
        initial_generation: u64,
        args: anytype,
        comptime initializer: anytype,
    ) !void {
        if (!self.pristine()) return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_pid = process_identity_mod.currentProcessId(),
            .owner_incarnation = nextReconnectGenerationOwnerIncarnation() orelse
                return error.InvalidAuthority,
            .owner_thread = std.Thread.getCurrentId(),
            .allocator = allocator,
            .screen_source = screen_source_ptr,
        };
        errdefer self.* = .{};
        try self.slot.initInPlace(allocator, initial_generation, args, initializer);
    }

    pub fn publishInitial(self: *ReconnectGenerationOwner) !void {
        try self.validate();
        if (self.screen_published or self.screen_source.?.current.kind != .unavailable)
            return error.InvalidAuthority;
        const generation = try self.slot.currentGeneration();
        const payload = try self.slot.currentPayload();
        const source = generationScreenSource(payload) orelse return error.InvalidAuthority;
        _ = try self.screen_source.?.publishLive(source, generation);
        self.screen_published = true;
    }

    /// CR3b R2a cross-owner leaf. Stable proxy는 이 CR2 owner만 쓰고 HostAdapter는
    /// 자기 ClientSlot store-only suffix만 제공한다.
    pub fn publishUnavailableForClientRetirement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        permit: *r2a_client_slot.PreparedAdmissionClose,
        expected_generation: u64,
        next_generation: u64,
    ) (r2a_client_slot.ClientSlot.RetirementDetachError || stable_screen_source.PublishError || error{InvalidAuthority})!stable_screen_source.RetiredTarget {
        try self.validate();
        if (!self.screen_published or try self.currentGeneration() != expected_generation)
            return error.InvalidAuthority;
        const current = try self.slot.currentPayload();
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        try adapter.slot.preflightRetirementDetach(permit, expected_generation, next_generation);
        const Context = struct {
            slot: *r2a_client_slot.ClientSlot,
            permit: *r2a_client_slot.PreparedAdmissionClose,
            expected: u64,
            next: u64,

            fn commit(context: @This()) void {
                context.slot.commitRetirementDetachNoFail(
                    context.permit,
                    context.expected,
                    context.next,
                );
            }
        };
        return self.screen_source.?.publishUnavailableFromLiveWithCommit(
            expected_generation,
            next_generation,
            Context{
                .slot = &adapter.slot,
                .permit = permit,
                .expected = expected_generation,
                .next = next_generation,
            },
            Context.commit,
        );
    }

    /// CR3b R2b product substrate. The final-address cleanup handle is fully prepared before the
    /// R2a writer gate and receives transport ownership in the same no-fail commit.
    pub fn publishUnavailableForClientRetirementWithCleanup(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        permit: *r2a_client_slot.PreparedAdmissionClose,
        cleanup: *r2a_client_slot.PreparedRetirementCleanup,
        expected_generation: u64,
        next_generation: u64,
    ) (r2a_client_slot.ClientSlot.RetirementDetachError || r2a_client_slot.ClientSlot.RetirementCleanupError || stable_screen_source.PublishError || error{InvalidAuthority})!stable_screen_source.RetiredTarget {
        try self.validate();
        if (!self.screen_published or try self.currentGeneration() != expected_generation)
            return error.InvalidAuthority;
        const current = try self.slot.currentPayload();
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        try adapter.slot.preflightRetirementDetach(permit, expected_generation, next_generation);
        try adapter.slot.preflightRetirementCleanup(permit, cleanup, next_generation);
        const Context = struct {
            slot: *r2a_client_slot.ClientSlot,
            permit: *r2a_client_slot.PreparedAdmissionClose,
            cleanup: *r2a_client_slot.PreparedRetirementCleanup,
            expected: u64,
            next: u64,

            fn commit(context: @This()) void {
                context.slot.commitRetirementCleanupNoFail(
                    context.permit,
                    context.cleanup,
                    context.next,
                );
                context.slot.commitRetirementDetachNoFail(
                    context.permit,
                    context.expected,
                    context.next,
                );
            }
        };
        return self.screen_source.?.publishUnavailableFromLiveWithCommit(
            expected_generation,
            next_generation,
            Context{
                .slot = &adapter.slot,
                .permit = permit,
                .cleanup = cleanup,
                .expected = expected_generation,
                .next = next_generation,
            },
            Context.commit,
        );
    }

    /// CR3c1 integrated forward-only suffix. The stable-screen writer gate hides the interval in
    /// which the old attachment is terminalized, then the Client cleanup/detach and unavailable
    /// target are published. A reader can observe either the old live generation or the complete
    /// unavailable placeholder, never a live target backed by a terminal attachment.
    pub fn publishUnavailableAfterAttachmentRetirement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        permit: *r2a_client_slot.PreparedAdmissionClose,
        cleanup: *r2a_client_slot.PreparedRetirementCleanup,
        expected_generation: u64,
        next_generation: u64,
    ) (r2a_client_slot.ClientSlot.RetirementDetachError || r2a_client_slot.ClientSlot.RetirementCleanupError || stable_screen_source.PublishError || error{InvalidAuthority})!stable_screen_source.RetiredTarget {
        try self.validate();
        if (!self.screen_published or try self.currentGeneration() != expected_generation)
            return error.InvalidAuthority;
        const current = @constCast(try self.slot.currentPayload());
        switch (current.connection) {
            .generation => |current_adapter| {
                if (current_adapter != adapter) return error.InvalidAuthority;
            },
            .legacy => return error.InvalidAuthority,
        }
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return error.InvalidAuthority,
        };
        try adapter.slot.preflightRetirementDetachBeforeAdmissionClose(
            permit,
            expected_generation,
            next_generation,
        );
        try adapter.slot.preflightRetirementCleanupBeforeAdmissionClose(
            permit,
            cleanup,
            next_generation,
        );
        const Context = struct {
            adapter: *host_adapter_mod.HostAdapter,
            attachment: *generation_attachment_mod.GenerationAttachment,
            permit: *r2a_client_slot.PreparedAdmissionClose,
            cleanup: *r2a_client_slot.PreparedRetirementCleanup,
            expected: u64,
            next: u64,

            fn commit(context: @This()) !void {
                switch (context.attachment.tryDeinit(context.adapter)) {
                    .cleaned, .terminal_handoff => {},
                    .busy => return error.Busy,
                    .already_terminal, .corrupt => process_seal_service.fatalIntegrity(.proof_loss),
                }
                context.adapter.commitAdmissionClose(context.permit) catch
                    @panic("CR3c1 admission close drifted inside writer gate");
                context.adapter.slot.commitRetirementCleanupNoFail(
                    context.permit,
                    context.cleanup,
                    context.next,
                );
                context.adapter.slot.commitRetirementDetachNoFail(
                    context.permit,
                    context.expected,
                    context.next,
                );
            }
        };
        return self.screen_source.?.publishUnavailableFromLiveWithFallibleCommit(
            expected_generation,
            next_generation,
            Context{
                .adapter = adapter,
                .attachment = attachment,
                .permit = permit,
                .cleanup = cleanup,
                .expected = expected_generation,
                .next = next_generation,
            },
            Context.commit,
        );
    }

    fn prepareHostWideRetirement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) !void {
        try self.validate();
        if (!self.screen_published or transaction_addr == 0 or transaction_generation == 0)
            return error.InvalidAuthority;
        const expected_generation = try self.currentGeneration();
        const next_generation = std.math.add(u64, expected_generation, 1) catch
            return error.InvalidAuthority;
        const current = @constCast(try self.slot.currentPayload());
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return error.InvalidAuthority,
        };
        try attachment.prepareHostRetirement(adapter, transaction_addr, transaction_generation);
        errdefer attachment.abortHostRetirement(
            adapter,
            transaction_addr,
            transaction_generation,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
        try self.screen_source.?.prepareUnavailableFromLive(
            expected_generation,
            next_generation,
            transaction_addr,
            transaction_generation,
        );
    }

    fn hostWideRetirementPreparedExact(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) bool {
        self.validate() catch return false;
        if (!self.screen_published or transaction_addr == 0 or transaction_generation == 0)
            return false;
        const expected_generation = self.currentGeneration() catch return false;
        const next_generation = std.math.add(u64, expected_generation, 1) catch return false;
        const current = @constCast(self.slot.currentPayload() catch return false);
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter) return false,
            .legacy => return false,
        }
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return false,
        };
        return attachment.hostRetirementPreparedExact(
            adapter,
            transaction_addr,
            transaction_generation,
        ) and self.screen_source.?.preparedUnavailableExact(
            expected_generation,
            next_generation,
            transaction_addr,
            transaction_generation,
        );
    }

    fn abortHostWideRetirement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) !void {
        if (!self.hostWideRetirementPreparedExact(
            adapter,
            transaction_addr,
            transaction_generation,
        )) return error.InvalidAuthority;
        const current = @constCast(try self.slot.currentPayload());
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return error.InvalidAuthority,
        };
        try self.screen_source.?.abortPreparedUnavailable(transaction_addr, transaction_generation);
        attachment.abortHostRetirement(
            adapter,
            transaction_addr,
            transaction_generation,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
    }

    fn commitHostWideRetirementNoFail(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) void {
        if (!self.hostWideRetirementPreparedExact(
            adapter,
            transaction_addr,
            transaction_generation,
        )) process_seal_service.fatalIntegrity(.proof_loss);
        const current = @constCast(self.slot.currentPayload() catch
            process_seal_service.fatalIntegrity(.proof_loss));
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => process_seal_service.fatalIntegrity(.proof_loss),
        };
        attachment.commitHostRetirementNoFail(
            adapter,
            transaction_addr,
            transaction_generation,
        );
        self.screen_source.?.commitPreparedUnavailableNoFail(
            transaction_addr,
            transaction_generation,
        );
    }

    fn hostWideRetirementCommittedExact(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
    ) bool {
        self.validate() catch return false;
        if (!self.screen_published) return false;
        const expected_generation = self.currentGeneration() catch return false;
        const unavailable_generation = std.math.add(u64, expected_generation, 1) catch return false;
        const current = @constCast(self.slot.currentPayload() catch return false);
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter) return false,
            .legacy => return false,
        }
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return false,
        };
        return attachment.hostRetirementCommittedExact(adapter) and
            self.screen_source.?.unavailableExact(unavailable_generation);
    }

    fn hostReconnectPublishedNewExact(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        mutation_owner: *const reconnect_mutation_seal.MutationOwner,
        input_epoch: u64,
    ) bool {
        self.validate() catch return false;
        if (!self.screen_published or input_epoch == 0) return false;
        const generation = self.currentGeneration() catch return false;
        const current = self.slot.currentPayload() catch return false;
        switch (current.connection) {
            .generation => |current_adapter| if (current_adapter != adapter) return false,
            .legacy => return false,
        }
        const attachment = switch (current.attachment) {
            .generation => |*value| value,
            .legacy => return false,
        };
        return attachment.allowsMutation() and mutation_owner.admits(generation, input_epoch);
    }

    pub fn prepare(
        self: *ReconnectGenerationOwner,
        out: *PreparedReconnect,
        args: anytype,
        comptime initializer: anytype,
    ) !void {
        try self.validate();
        if (!self.screen_published) return error.InvalidAuthority;
        if (rangesOverlap(self, @sizeOf(ReconnectGenerationOwner), out, @sizeOf(PreparedReconnect)) or
            !std.meta.eql(out.*, PreparedReconnect{})) return error.InvalidAuthority;
        try self.slot.beginCandidate(&out.candidate);
        var initialized = false;
        errdefer if (initialized)
            self.slot.abortCandidateInPlace(
                &out.candidate,
                self.allocator.?,
                deinitRemoteGeneration,
            ) catch @panic("reconnect candidate cleanup lost final owner")
        else
            self.slot.abortEmptyCandidate(&out.candidate) catch
                @panic("empty reconnect candidate cleanup lost final owner");
        try self.slot.initializeCandidate(&out.candidate, args, initializer);
        initialized = true;
        const payload = try self.slot.candidatePayload(&out.candidate);
        const candidate_source = generationScreenSource(payload) orelse return error.InvalidAuthority;
        const current_payload = try self.slot.currentPayload();
        const current_source = generationScreenSource(current_payload) orelse return error.InvalidAuthority;
        if (screenSourcesEqual(candidate_source, current_source)) return error.InvalidAuthority;
        out.self_addr = @intFromPtr(out);
        out.owner_addr = self.self_addr;
        out.lifecycle = .candidate;
    }

    /// CR3c1 forward-recovery preparation. The old attachment was terminalized before admission
    /// close, so its screen source is intentionally unavailable; the published Client receipt and
    /// same-generation placeholder replace the ordinary live-current source comparison.
    fn preflightUnavailableAfterAttachmentRetirement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        expected_connection_generation: u64,
    ) !void {
        try self.validate();
        if (!self.screen_published or expected_connection_generation == 0) return error.InvalidAuthority;
        const current_generation = try self.slot.currentGeneration();
        const placeholder_generation = std.math.add(u64, current_generation, 1) catch
            return error.InvalidAuthority;
        const current_payload = try self.slot.currentPayload();
        if (self.screen_source.?.current.kind != .unavailable or
            self.screen_source.?.current.generation != placeholder_generation or
            current_payload.connection_generation != expected_connection_generation)
            return error.InvalidAuthority;
        switch (current_payload.connection) {
            .generation => |current_adapter| if (current_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        switch (current_payload.attachment) {
            .generation => |*attachment| if (!generationAttachmentTerminal(attachment))
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
    }

    pub fn prepareAfterClientReplacement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        published: *const r2a_client_slot.PreparedClientReplacement,
        out: *PreparedReconnect,
        args: anytype,
        comptime initializer: anytype,
    ) !void {
        try self.validate();
        if (!self.screen_published) return error.InvalidAuthority;
        try adapter.preflightPublishedClientReplacement(published);
        if (rangesOverlap(self, @sizeOf(ReconnectGenerationOwner), out, @sizeOf(PreparedReconnect)) or
            !std.meta.eql(out.*, PreparedReconnect{})) return error.InvalidAuthority;
        try self.preflightUnavailableAfterAttachmentRetirement(
            adapter,
            published.expected_connection_generation,
        );

        try self.slot.beginCandidate(&out.candidate);
        var initialized = false;
        errdefer if (initialized)
            self.slot.abortCandidateInPlace(
                &out.candidate,
                self.allocator.?,
                deinitRemoteGeneration,
            ) catch @panic("CR3c1 candidate cleanup lost final owner")
        else
            self.slot.abortEmptyCandidate(&out.candidate) catch
                @panic("CR3c1 empty candidate cleanup lost final owner");
        try self.slot.initializeCandidate(&out.candidate, args, initializer);
        initialized = true;
        const candidate_payload = try self.slot.candidatePayload(&out.candidate);
        if (generationScreenSource(candidate_payload) == null or
            candidate_payload.connection_generation != published.next_connection_generation)
            return error.InvalidAuthority;
        out.self_addr = @intFromPtr(out);
        out.owner_addr = self.self_addr;
        out.lifecycle = .candidate;
    }

    pub fn publish(
        self: *ReconnectGenerationOwner,
        prepared: *PreparedReconnect,
    ) !void {
        try self.validatePrepared(prepared);
        if (!self.screen_published) return error.InvalidAuthority;
        try self.slot.preflightPublishCandidate(&prepared.candidate);
        const current_generation = try self.slot.currentGeneration();
        const current_payload = try self.slot.currentPayload();
        const current_source = generationScreenSource(current_payload) orelse return error.InvalidAuthority;
        if (self.screen_source.?.current.kind != .live or
            self.screen_source.?.current.generation != current_generation or
            !screenSourcesEqual(self.screen_source.?.current.source, current_source))
            return error.InvalidAuthority;
        const payload = try self.slot.candidatePayload(&prepared.candidate);
        const source = generationScreenSource(payload) orelse return error.InvalidAuthority;
        const generation = prepared.candidate.generation;
        const retired = try self.screen_source.?.publishLiveWithCommit(
            source,
            generation,
            PublishContext{ .slot = &self.slot, .candidate = &prepared.candidate },
            PublishContext.commit,
        );
        if (retired.kind != .live or retired.generation != current_generation or
            !screenSourcesEqual(retired.source, current_source))
            @panic("stable screen retired target diverged after generation commit");
        prepared.* = .{};
    }

    /// CR3c1 publication bridge. R2c가 이미 게시한 Client connection generation을
    /// fully prepared RemoteGeneration candidate와 unavailable placeholder에 결속한다.
    pub fn publishAfterClientReplacement(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
    ) (r2a_client_slot.ClientSlot.ClientReplacementError || stable_screen_source.PublishError || error{ InvalidAuthority, RetiringBusy })!void {
        try self.validatePrepared(reconnect);
        if (!self.screen_published) return error.InvalidAuthority;
        try adapter.preflightPublishedClientReplacement(published);
        try self.slot.preflightPublishCandidate(&reconnect.candidate);
        try self.preflightClientGenerationPair(adapter, reconnect, published);

        const current_generation = try self.slot.currentGeneration();
        const candidate_generation = reconnect.candidate.generation;
        if (self.screen_source.?.current.kind != .unavailable or
            self.screen_source.?.current.generation != candidate_generation or
            candidate_generation <= current_generation)
            return error.InvalidAuthority;
        const candidate_payload = try self.slot.candidatePayload(&reconnect.candidate);
        const candidate_source = generationScreenSource(candidate_payload) orelse return error.InvalidAuthority;

        const Context = struct {
            owner: *ReconnectGenerationOwner,
            adapter: *host_adapter_mod.HostAdapter,
            reconnect: *PreparedReconnect,
            published: *const r2a_client_slot.PreparedClientReplacement,

            fn commit(context: @This()) void {
                context.adapter.preflightPublishedClientReplacement(context.published) catch
                    @panic("CR3c1 published Client authority drifted inside writer gate");
                context.owner.slot.preflightPublishCandidate(&context.reconnect.candidate) catch
                    @panic("CR3c1 RemoteGeneration authority drifted inside writer gate");
                context.owner.preflightClientGenerationPair(
                    context.adapter,
                    context.reconnect,
                    context.published,
                ) catch @panic("CR3c1 cross-owner generation binding drifted inside writer gate");
                context.owner.slot.publishCandidateNoFail(&context.reconnect.candidate);
            }
        };
        try self.screen_source.?.promoteUnavailableToLiveWithCommit(
            candidate_source,
            candidate_generation,
            Context{
                .owner = self,
                .adapter = adapter,
                .reconnect = reconnect,
                .published = published,
            },
            Context.commit,
        );
        reconnect.* = .{};
    }

    fn preflightClientGenerationPair(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
    ) error{InvalidAuthority}!void {
        const current_payload = self.slot.currentPayload() catch return error.InvalidAuthority;
        const candidate_payload = self.slot.candidatePayload(&reconnect.candidate) catch
            return error.InvalidAuthority;
        const next_connection_generation = std.math.add(
            u64,
            published.expected_connection_generation,
            1,
        ) catch return error.InvalidAuthority;
        if (current_payload.connection_generation == 0 or
            current_payload.connection_generation != published.expected_connection_generation or
            candidate_payload.connection_generation != published.next_connection_generation or
            published.next_connection_generation != next_connection_generation or
            adapter.connectionGeneration() != published.next_connection_generation)
            return error.InvalidAuthority;
        switch (current_payload.connection) {
            .generation => |current_adapter| {
                if (current_adapter != adapter) return error.InvalidAuthority;
            },
            .legacy => return error.InvalidAuthority,
        }
        switch (candidate_payload.connection) {
            .generation => |candidate_adapter| {
                if (candidate_adapter != adapter) return error.InvalidAuthority;
            },
            .legacy => return error.InvalidAuthority,
        }
    }

    fn prepareCandidateCatchupStage(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        runtime_id: u128,
        request_nonce: u128,
        deadline: client_deadline.AbsoluteDeadline,
        io: std.Io,
    ) anyerror!*const catchup_stage_contract.PreparedStage {
        try self.validatePrepared(reconnect);
        try self.preflightClientGenerationPair(adapter, reconnect, published);
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        return switch (candidate.attachment) {
            .generation => |*attachment| attachment.prepareCatchupStage(
                runtime_id,
                request_nonce,
                deadline,
                io,
            ),
            .legacy => error.InvalidAuthority,
        };
    }

    fn validateCandidateCatchupStage(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
        require_fresh: bool,
    ) bool {
        self.validatePrepared(reconnect) catch return false;
        self.preflightClientGenerationPair(adapter, reconnect, published) catch return false;
        const candidate = @constCast(self.slot.candidatePayload(&reconnect.candidate) catch return false);
        return switch (candidate.attachment) {
            .generation => |*attachment| if (require_fresh)
                attachment.validateCatchupStage(stage, deadline)
            else
                deadline.expires_at_ns == stage.deadline_expires_at_ns and
                    attachment.catchupStageAuthorityMatches(stage),
            .legacy => false,
        };
    }

    fn executeCandidateControllerTakeoverUntil(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!generation_attachment_mod.GenerationAttachment.ControllerTransferOutcome {
        if (!self.validateCandidateCatchupStage(
            adapter,
            reconnect,
            published,
            stage,
            deadline,
            true,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        return switch (candidate.attachment) {
            .generation => |*attachment| attachment.executeControllerTakeoverUntil(stage, deadline),
            .legacy => error.InvalidAuthority,
        };
    }

    fn validateCandidateControllerEvidence(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) bool {
        self.validatePrepared(reconnect) catch return false;
        self.preflightClientGenerationPair(adapter, reconnect, published) catch return false;
        const candidate = @constCast(self.slot.candidatePayload(&reconnect.candidate) catch return false);
        return switch (candidate.attachment) {
            .generation => |*attachment| attachment.validateControllerEvidence(
                stage,
                controller_generation,
            ),
            .legacy => false,
        };
    }

    fn abortCandidateControllerEvidence(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) anyerror!void {
        if (!self.validateCandidateControllerEvidence(
            adapter,
            reconnect,
            published,
            stage,
            controller_generation,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.releaseControllerEvidence(
                stage,
                controller_generation,
            ),
            .legacy => return error.InvalidAuthority,
        }
        try self.abort(reconnect);
    }

    fn promoteCandidateControllerEvidence(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) anyerror!void {
        if (!self.validateCandidateControllerEvidence(
            adapter,
            reconnect,
            published,
            stage,
            controller_generation,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.promoteControllerEvidence(
                stage,
                controller_generation,
            ),
            .legacy => return error.InvalidAuthority,
        }
    }

    fn validateCandidatePromotedController(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) bool {
        self.validatePrepared(reconnect) catch return false;
        self.preflightClientGenerationPair(adapter, reconnect, published) catch return false;
        const candidate = @constCast(self.slot.candidatePayload(&reconnect.candidate) catch return false);
        return switch (candidate.attachment) {
            .generation => |*attachment| attachment.validatePromotedController(
                stage,
                controller_generation,
            ),
            .legacy => false,
        };
    }

    fn abortCandidatePromotedController(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) anyerror!void {
        if (!self.validateCandidatePromotedController(
            adapter,
            reconnect,
            published,
            stage,
            controller_generation,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.releasePromotedController(
                stage,
                controller_generation,
            ),
            .legacy => return error.InvalidAuthority,
        }
        try self.abort(reconnect);
    }

    fn forceCandidatePromotedResizeUntil(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
        size: terminal.Size,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!void {
        if (!self.validateCandidatePromotedController(
            adapter,
            reconnect,
            published,
            stage,
            controller_generation,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        if (candidate.resize_seq == resize_wire.max_counter) return error.SequenceExhausted;
        const next_sequence = candidate.resize_seq + 1;
        const result = switch (candidate.attachment) {
            .generation => |*attachment| try attachment.forcePromotedControllerResizeUntil(
                stage,
                controller_generation,
                size.cols,
                size.rows,
                next_sequence,
                deadline,
            ),
            .legacy => return error.InvalidAuthority,
        };
        candidate.resize_seq = next_sequence;
        candidate.resize_generation = result.resize_generation;
        candidate.resize_baseline_present = true;
        candidate.observation.size = size;
    }

    fn abortCandidatePromotedControllerAfterTerminal(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) anyerror!void {
        try self.validatePrepared(reconnect);
        try self.preflightClientGenerationPair(adapter, reconnect, published);
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.releasePromotedControllerAfterTerminalTransport(
                stage,
                controller_generation,
            ),
            .legacy => return error.InvalidAuthority,
        }
        try self.abort(reconnect);
    }

    fn preflightCandidatePromotedPublication(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
        expected_size: terminal.Size,
    ) !void {
        if (!self.validateCandidatePromotedController(
            adapter,
            reconnect,
            published,
            stage,
            controller_generation,
        )) return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        if (candidate.resize_seq == 0 or !candidate.resize_baseline_present or
            !std.meta.eql(candidate.observation.size, expected_size))
            return error.InvalidAuthority;
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.preflightReleasePromotedController(
                stage,
                controller_generation,
            ),
            .legacy => return error.InvalidAuthority,
        }
    }

    fn abortCandidateCatchupStage(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!void {
        if (!self.validateCandidateCatchupStage(adapter, reconnect, published, stage, deadline, false))
            return error.InvalidAuthority;
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| try attachment.abortCatchupStage(stage),
            .legacy => return error.InvalidAuthority,
        }
        try self.abort(reconnect);
    }

    fn abortCandidateCatchupStageForClosedOutcome(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        reconnect: *PreparedReconnect,
        published: *const r2a_client_slot.PreparedClientReplacement,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!void {
        try self.validatePrepared(reconnect);
        try self.preflightClientGenerationPair(adapter, reconnect, published);
        const candidate = @constCast(try self.slot.candidatePayload(&reconnect.candidate));
        switch (candidate.attachment) {
            .generation => |*attachment| {
                if (deadline.expires_at_ns == stage.deadline_expires_at_ns and
                    attachment.catchupStageAuthorityMatches(stage))
                {
                    try attachment.abortCatchupStage(stage);
                } else {
                    try attachment.abortCatchupStageAfterTerminalTransport(stage);
                }
            },
            .legacy => return error.InvalidAuthority,
        }
        try self.abort(reconnect);
    }

    pub fn abort(self: *ReconnectGenerationOwner, prepared: *PreparedReconnect) !void {
        try self.validatePrepared(prepared);
        try self.slot.abortCandidateInPlace(
            &prepared.candidate,
            self.allocator.?,
            deinitRemoteGeneration,
        );
        prepared.* = .{};
    }

    pub fn reclaimRetiring(self: *ReconnectGenerationOwner) !void {
        try self.validate();
        try self.slot.reclaimRetiringInPlace(self.allocator.?, deinitRemoteGeneration);
    }

    /// CR5 host-wide reconnect keeps one retired shared Client alive until every runtime has
    /// released its matching retiring generation. The ordinary CR3c leaf below still owns the
    /// final remote-first/client-second pair; this intermediate leaf proves that the retained
    /// Client is the exact matching generation, then reclaims only this runtime's remote owner.
    fn reclaimRetiringGenerationRetainingClientAtTickEnd(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
    ) !void {
        try self.validate();
        var remote: RemoteGenerationSlot.PreparedRetiringReclaim = .{};
        try self.slot.prepareRetiringReclaim(&remote);
        const payload = try self.slot.retiringPayload(&remote);
        switch (payload.connection) {
            .generation => |remote_adapter| if (remote_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        switch (payload.attachment) {
            .generation => |attachment| if (!generationAttachmentTerminal(&attachment))
                return error.NotReady,
            .legacy => return error.InvalidAuthority,
        }
        var retained_client: client_slot_mod.PreparedRetiredClientReclaim = .{};
        try adapter.prepareRetiredClientReclaim(&retained_client);
        if (payload.connection_generation == 0 or
            payload.connection_generation != retained_client.connection_generation)
            return error.InvalidAuthority;
        self.slot.commitRetiringReclaimInPlaceNoFail(
            &remote,
            self.allocator.?,
            deinitRemoteGeneration,
        );
    }

    /// 두 owner를 읽기만 하는 prepare 단계다. generation mismatch나 어느 한쪽의
    /// readiness 부족은 destination까지 pristine으로 되돌리고 파괴를 시작하지 않는다.
    pub fn prepareOrderedRetiringReclaim(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        out: *PreparedOrderedRetiringReclaim,
    ) !void {
        try self.validate();
        if (!std.meta.eql(out.*, PreparedOrderedRetiringReclaim{}) or
            rangesOverlap(self, @sizeOf(ReconnectGenerationOwner), out, @sizeOf(PreparedOrderedRetiringReclaim)) or
            rangesOverlap(adapter, @sizeOf(host_adapter_mod.HostAdapter), out, @sizeOf(PreparedOrderedRetiringReclaim)))
            return error.InvalidAuthority;
        errdefer out.* = .{};
        const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
            return error.InvalidAuthority;
        if (identity.pid != self.owner_pid or identity.process_nonce == 0)
            return error.InvalidAuthority;
        try self.slot.prepareRetiringReclaim(&out.remote);
        const remote = try self.slot.retiringPayload(&out.remote);
        switch (remote.connection) {
            .generation => |remote_adapter| if (remote_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        switch (remote.attachment) {
            .generation => |attachment| if (!generationAttachmentTerminal(&attachment))
                return error.NotReady,
            .legacy => return error.InvalidAuthority,
        }
        try adapter.prepareRetiredClientReclaim(&out.client);
        if (remote.connection_generation == 0 or
            remote.connection_generation != out.client.connection_generation)
            return error.InvalidAuthority;
        out.self_addr = @intFromPtr(out);
        out.pid = identity.pid;
        out.process_nonce = identity.process_nonce;
        out.owner_addr = @intFromPtr(self);
        out.owner_incarnation = self.owner_incarnation;
        out.adapter_addr = @intFromPtr(adapter);
        out.connection_generation = remote.connection_generation;
        out.lifecycle = .prepared;
    }

    pub fn preflightOrderedRetiringReclaim(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        prepared: *const PreparedOrderedRetiringReclaim,
    ) !void {
        try self.validate();
        const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
            return error.InvalidAuthority;
        if (!preparedOrderedRetiringLifecycleRawValid(&prepared.lifecycle) or
            prepared.lifecycle != .prepared or prepared.self_addr != @intFromPtr(prepared) or
            prepared.pid != identity.pid or prepared.process_nonce != identity.process_nonce or
            prepared.owner_addr != @intFromPtr(self) or prepared.owner_incarnation != self.owner_incarnation or
            prepared.adapter_addr != @intFromPtr(adapter) or
            prepared.connection_generation == 0)
            return error.InvalidAuthority;
        try self.slot.preflightRetiringReclaim(&prepared.remote);
        const remote = try self.slot.retiringPayload(&prepared.remote);
        switch (remote.connection) {
            .generation => |remote_adapter| if (remote_adapter != adapter)
                return error.InvalidAuthority,
            .legacy => return error.InvalidAuthority,
        }
        switch (remote.attachment) {
            .generation => |attachment| if (!generationAttachmentTerminal(&attachment))
                return error.NotReady,
            .legacy => return error.InvalidAuthority,
        }
        if (remote.connection_generation != prepared.connection_generation or
            prepared.client.connection_generation != prepared.connection_generation)
            return error.InvalidAuthority;
        try adapter.preflightRetiredClientReclaim(&prepared.client);
    }

    /// 같은 owner turn에서 모든 preflight를 끝낸 뒤 RemoteGeneration을 먼저 파괴한다.
    /// 그 attachment가 Client pin을 놓은 뒤에만 matching retired Client node를 회수한다.
    pub fn commitOrderedRetiringReclaimAtTickEndNoFail(
        self: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
        prepared: *PreparedOrderedRetiringReclaim,
    ) void {
        self.preflightOrderedRetiringReclaim(adapter, prepared) catch
            @panic("CR3c2 ordered reclaim authority drifted after preflight");
        self.slot.commitRetiringReclaimInPlaceNoFail(
            &prepared.remote,
            self.allocator.?,
            deinitRemoteGeneration,
        );
        if (builtin.is_test) Cr3c2OrderedReclaimTestState.recordRemote(self, adapter);
        adapter.commitRetiredClientReclaimAtTickEndNoFail(&prepared.client);
        if (builtin.is_test) Cr3c2OrderedReclaimTestState.recordClient(self, adapter);
        prepared.lifecycle = .reclaimed;
    }

    /// Reconnect executor의 tick-end sole leaf. generation-backed retiring owner는 반드시
    /// matching Client와 ordered reclaim하고 legacy test owner만 독립 정산한다.
    pub fn reclaimRetiringAtTickEnd(self: *ReconnectGenerationOwner) !void {
        try self.validate();
        var remote: RemoteGenerationSlot.PreparedRetiringReclaim = .{};
        try self.slot.prepareRetiringReclaim(&remote);
        const payload = try self.slot.retiringPayload(&remote);
        switch (payload.connection) {
            .legacy => self.slot.commitRetiringReclaimInPlaceNoFail(
                &remote,
                self.allocator.?,
                deinitRemoteGeneration,
            ),
            .generation => |adapter| {
                remote = .{};
                var ordered: PreparedOrderedRetiringReclaim = .{};
                try self.prepareOrderedRetiringReclaim(adapter, &ordered);
                self.commitOrderedRetiringReclaimAtTickEndNoFail(adapter, &ordered);
            },
        }
    }

    pub fn deinit(self: *ReconnectGenerationOwner) !void {
        try self.validate();
        if (try self.slot.hasRetiring() or self.slot.candidate != null) return error.Busy;
        if (self.screen_published and self.screen_source.?.current.kind == .live) {
            const current_generation = try self.slot.currentGeneration();
            const payload = try self.slot.currentPayload();
            const source = generationScreenSource(payload) orelse return error.InvalidAuthority;
            if (self.screen_source.?.current.kind != .live or
                self.screen_source.?.current.generation != current_generation or
                !screenSourcesEqual(self.screen_source.?.current.source, source))
                return error.InvalidAuthority;
            const retired = (try self.screen_source.?.close()) orelse return error.InvalidAuthority;
            if (retired.kind != .live or retired.generation != current_generation or
                !screenSourcesEqual(retired.source, source))
                @panic("reconnect generation and stable screen retirement diverged");
        } else {
            if (self.screen_source.?.current.kind != .unavailable) return error.InvalidAuthority;
            if (self.screen_published) {
                const current_generation = try self.slot.currentGeneration();
                if (current_generation == std.math.maxInt(u64) or
                    self.screen_source.?.current.generation != current_generation + 1)
                    return error.InvalidAuthority;
                const current = try self.slot.currentPayload();
                switch (current.connection) {
                    .generation => |adapter| switch (current.attachment) {
                        .generation => |*attachment| if (generationAttachmentTerminal(attachment)) {
                            const next_connection_generation = std.math.add(
                                u64,
                                current.connection_generation,
                                1,
                            ) catch return error.InvalidAuthority;
                            const replacement_failed =
                                adapter.connectionGeneration() == current.connection_generation and
                                adapter.slot.retiredClientCount() == 0;
                            const replacement_published =
                                adapter.connectionGeneration() == next_connection_generation and
                                adapter.slot.retiredClientCount() != 0;
                            const published_current_failed =
                                adapter.connectionGeneration() == current.connection_generation and
                                adapter.slot.retiredClientCount() != 0 and
                                adapter.slot.attachmentConnectionFailureReason() != null;
                            if (!replacement_failed and !replacement_published and
                                !published_current_failed)
                                return error.InvalidAuthority;
                        } else adapter.slot.validateRetirementPlaceholder(
                            self.screen_source.?.current.generation,
                        ) catch return error.InvalidAuthority,
                        .legacy => return error.InvalidAuthority,
                    },
                    .legacy => return error.InvalidAuthority,
                }
            }
            if ((try self.screen_source.?.close()) != null)
                @panic("unpublished stable screen retired a live target");
        }
        self.slot.deinitInPlace(self.allocator.?, deinitRemoteGeneration) catch
            @panic("reconnect generation deinit proof lost after screen close");
        self.* = .{};
    }

    pub fn currentGeneration(self: *ReconnectGenerationOwner) !u64 {
        try self.validate();
        return self.slot.currentGeneration();
    }

    fn validate(self: *ReconnectGenerationOwner) !void {
        if (self.self_addr != @intFromPtr(self) or self.owner_pid == 0 or self.owner_incarnation == 0 or
            self.owner_pid != process_identity_mod.currentProcessId() or self.owner_thread == null or
            self.owner_thread.? != std.Thread.getCurrentId() or self.allocator == null or
            self.screen_source == null) return error.InvalidAuthority;
    }

    fn pristine(self: *const ReconnectGenerationOwner) bool {
        return self.self_addr == 0 and self.owner_pid == 0 and self.owner_incarnation == 0 and
            self.owner_thread == null and
            self.allocator == null and self.screen_source == null and !self.screen_published and
            self.slot.self_addr == 0 and self.slot.owner_pid == 0 and self.slot.incarnation == 0 and
            self.slot.owner_thread == null and
            self.slot.allocator == null and self.slot.lifecycle == .pristine and
            self.slot.next_generation == 0 and self.slot.current == null and
            self.slot.retiring == null and self.slot.candidate == null and
            self.slot.inline_node.self_addr == 0 and self.slot.inline_node.slot_addr == 0 and
            self.slot.inline_node.incarnation == 0 and
            self.slot.inline_node.generation == 0 and !self.slot.inline_node.heap_owned and
            self.slot.inline_node.lifecycle == .pristine and !self.slot.inline_node.payload_present;
    }

    fn validatePrepared(
        self: *ReconnectGenerationOwner,
        prepared: *PreparedReconnect,
    ) !void {
        try self.validate();
        if (rangesOverlap(self, @sizeOf(ReconnectGenerationOwner), prepared, @sizeOf(PreparedReconnect)) or
            prepared.self_addr != @intFromPtr(prepared) or prepared.owner_addr != self.self_addr or
            prepared.lifecycle != .candidate) return error.InvalidAuthority;
    }
};

fn generationScreenSource(generation: *const RemoteGeneration) ?maru.session.surface.ScreenSource {
    const mutable: *RemoteGeneration = @constCast(generation);
    const screen = mutable.attachment.screenPtr() orelse return null;
    return screen.screenSource();
}

fn screenSourcesEqual(
    a: maru.session.surface.ScreenSource,
    b: maru.session.surface.ScreenSource,
) bool {
    return a.ctx == b.ctx and a.vtable == b.vtable;
}

fn deinitRemoteGeneration(generation: *RemoteGeneration, allocator: std.mem.Allocator) void {
    switch (generation.attachment) {
        .generation => |*attachment| {
            // `.terminal` is the exact source-zero result produced by the attachment rollback/deinit
            // leaf and must not be deinitialized a second time (`GenerationAttachment.tryDeinit`
            // deliberately rejects replay). `.shell` still goes through the canonical deinitializer
            // so its final-address transport authority is checked before retirement.
            if (generationAttachmentTerminal(attachment)) {
                attachment.* = undefined;
            } else switch (generation.connection) {
                .generation => |adapter| attachment.deinit(adapter),
                .legacy => @panic("runtime connection and attachment mode diverged"),
            }
        },
        .legacy => |*attachment| switch (generation.connection) {
            .legacy => attachment.deinit(),
            .generation => @panic("runtime connection and attachment mode diverged"),
        },
    }
    generation.observation.deinit(allocator);
    if (builtin.is_test) ReconnectGenerationTestState.deinit_count += 1;
    generation.* = undefined;
}

const InitialRemoteGenerationArgs = struct {
    allocator: std.mem.Allocator,
    connection: RuntimeConnection,
};

fn initInitialRemoteGeneration(
    out: *RemoteGeneration,
    args: InitialRemoteGenerationArgs,
) !void {
    out.* = .{
        .connection = args.connection,
        .connection_generation = switch (args.connection) {
            .legacy => 0,
            .generation => |adapter| adapter.connectionGeneration(),
        },
        .attachment = switch (args.connection) {
            .legacy => .{ .legacy = remote_attachment.RemoteAttachment.init(args.allocator, .{
                .runtime_id = 0,
                .stream_id = 0,
                .role = .observer,
                .controller_generation = 0,
            }) },
            .generation => .{ .generation = .{} },
        },
        .event_generation_tracking = .untracked,
        .resize_seq = 0,
        .resize_generation = 0,
        .resize_baseline_present = false,
        .pump_ended = false,
        .resync_needed = false,
        .observation = .{},
    };
    if (args.connection == .generation)
        try out.attachment.generation.initInPlace(args.connection.generation);
}

const ObserverReconnectCandidateArgs = struct {
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
    runtime_id: u128,
    deadline: ?client_deadline.AbsoluteDeadline = null,
};

/// CR4a candidate initializer. 모든 socket/화면 mutation은 heap candidate의 final address에서
/// 끝나며 실패 시 caller가 current generation을 건드리지 않고 이 payload만 정산할 수 있다.
fn initObserverReconnectCandidate(
    out: *RemoteGeneration,
    args: ObserverReconnectCandidateArgs,
) !void {
    const runtime = args.runtime;
    const capabilities = runtime.connectionCapabilities();
    out.* = .{
        .connection = .{ .generation = args.adapter },
        .connection_generation = args.adapter.connectionGeneration(),
        .attachment = .{ .generation = .{} },
        .event_generation_tracking = .untracked,
        .resize_seq = 0,
        .resize_generation = 0,
        .resize_baseline_present = false,
        .pump_ended = false,
        .resync_needed = false,
        .observation = .{},
    };
    var live = true;
    errdefer if (live) deinitRemoteGeneration(out, runtime.allocator);

    try out.attachment.generation.initInPlace(args.adapter);
    const prepared = try out.attachment.generation.prepareObserverAttach(args.adapter, args.runtime_id);
    const result = if (args.deadline) |deadline|
        try out.attachment.generation.executePreparedAttachUntil(args.adapter, prepared, deadline)
    else
        try out.attachment.generation.executePreparedAttach(args.adapter, prepared);
    const correlated = switch (result) {
        .accepted => |value| value,
        .typed_reject => return error.ObserverAttachRejected,
        .uncertain_or_connection_failure => return error.ObserverAttachConnectionFailed,
    };
    var response_open = true;
    defer if (response_open) {
        _ = out.attachment.generation.finishResponse(args.adapter);
        out.attachment.generation.abortExecutedAttach(
            args.adapter,
            correlated.executed_call,
        ) catch @panic("CR4a observer response rollback lost final candidate");
    };
    const response = try out.attachment.generation.responseBytes(args.adapter);
    const generation_schema: runtime_metadata_wire.AttachGenerationSchema = switch (capabilities.attach_schema) {
        .frozen_controller_only => .frozen_controller_only,
        .granted_roles => if (capabilities.peer_attach_generation)
            .granted_with_generation
        else
            .granted_without_generation,
    };
    var decoded = remote_attachment.decodeAttachResponse(
        runtime.allocator,
        response,
        args.runtime_id,
        .observer,
        .{
            .generation_schema = generation_schema,
            .metadata_support = switch (capabilities.metadata_support) {
                .unsupported => .unsupported,
                .supported => .supported,
            },
        },
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Malformed,
        error.ResourceExhausted,
        error.CapabilityViolation,
        => error.ObserverAttachProtocolFailed,
    };
    defer decoded.deinit();
    const accepted = switch (decoded) {
        .wire_error => return error.ObserverAttachRejected,
        .accepted => |*value| value,
    };
    switch (accepted.initial_metadata) {
        .current => |*dto| {
            _ = try RemoteRuntime.applyMetadataDtoToObservation(
                runtime.allocator,
                &out.observation,
                dto,
            );
            // attach 응답이 **처음이자 대개 유일한** 전달 기회다 — pid는 안 바뀌므로 이후 metadata event가
            // 다시 실어 보내도 값이 같고, revision 필터에 걸리면 event 자체가 안 온다.
            RemoteRuntime.adoptProcessIdentity(runtime, dto);
        },
        .unsupported, .unavailable => {},
    }
    out.event_generation_tracking = switch (generation_schema) {
        .frozen_controller_only, .granted_without_generation => .untracked,
        .granted_with_generation => .tracked,
    };
    if (out.attachment.generation.finishResponse(args.adapter) != .cleaned)
        @panic("CR4a observer response cleanup lost final candidate");
    try out.attachment.generation.commitAccepted(
        args.adapter,
        correlated,
        accepted.state,
        runtime.allocator,
    );
    response_open = false;

    var snapshot: initial_snapshot_owner_mod.InitialSnapshotOwner = .{};
    if (args.deadline) |deadline|
        try out.attachment.generation.readInitialSnapshotUntil(&snapshot, deadline)
    else
        try out.attachment.generation.readInitialSnapshot(&snapshot);
    var snapshot_live = true;
    defer if (snapshot_live) snapshot.deinit() catch
        @panic("CR4a initial snapshot cleanup lost final candidate");
    const bytes = try snapshot.borrow();
    try out.attachment.generation.initScreen(capabilities.screen_codec_version);
    // CR4 authority receipt는 legacy sequence-0 delta를 절대 증거로 사용하지 않는다.
    out.attachment.generation.screenPtr().?.requireSequencedDeltas();
    out.attachment.generation.screenPtr().?.viewport_scrolled_known =
        capabilities.screen_viewport_scrolled;
    out.attachment.generation.screenPtr().?.applySnapshot(bytes, runtime.io) catch |err| {
        snapshot.deinit() catch
            @panic("CR4a initial snapshot cleanup lost final candidate");
        snapshot_live = false;
        out.attachment.generation.poisonInitialSnapshotApply(
            err == error.OutOfMemory,
        ) catch @panic("CR4a snapshot failure lost sealed candidate transport");
        return err;
    };
    try snapshot.deinit();
    snapshot_live = false;

    // CR4a prerequisite는 snapshot owner까지만 닫는다. delta frontier를 여기서 임의로 idle로
    // 간주하면 아직 없는 product job/deadline receipt를 우회하므로 actual connect gate가 소유한다.
    live = false;
}

fn rangesOverlap(a: anytype, a_len: usize, b: anytype, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

/// 한 원격 runtime. self-referential(`surface.remote`가 attachment screen을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    generation_owner: ReconnectGenerationOwner,
    reconnect_executor: ReconnectProductExecutor,
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    /// 이 client 가 **마지막으로 성공적으로 요청한** 열(S11-6). 0 이면 아직 한 번도 안 보냈다.
    requested_cols: u16 = 0,
    /// 남이 세션을 좁혀 둔 열. 0 이면 아무도 안 좁혔다.
    ///
    /// **`runtime.resized` 가 올 때만 정한다** — 그 순간의 크기는 host 가 방금 확정한 값이라
    /// 내가 요청한 값과 견주면 그 자리에서 판정된다. 프레임마다 창 크기와 견주면 내가 창을 넓히는
    /// 동안 host 확정 전까지 참이 되어 폰이 없어도 표시가 번쩍인다.
    ///
    /// **generation 이 아니라 여기 산다.** 재연결하면 generation 이 새로 서는데, 그때 이 값이
    /// 0 이 되면 **세션은 여전히 좁은데 표시만 사라진다** — 「아무 신호 없이 줄이지 않는다」가
    /// 깨진다(적대적 검증 3회차). 이 둘은 연결이 아니라 **내 의도**에 대한 사실이라 연결보다 오래 산다.
    narrowed_cols: u16 = 0,
    // blocking `SurfaceRuntime.writeInput`의 key bytes와 그 사이 core command를 한 시간축으로 보존한다.
    // control.barrier는 그 명령보다 먼저 host에 도착해야 하는 direct_input byte prefix 끝이다.
    direct_input: std.ArrayListUnmanaged(u8),
    direct_input_offset: usize,
    input_batches: input_owner_mod.StableQueueState,
    mutation_owner: reconnect_mutation_seal.MutationOwner = .{},
    paused_input_metadata: ?reconnect_mutation_seal.PausedInputMetadata = null,
    paused_paste_store: reconnect_mutation_seal.PausedPasteStore = .{},
    event_cursor: maru.app.EventCursor = .{},
    pending_controls: std.ArrayListUnmanaged(runtime_pending_control.RawQueuedRuntimeControl),
    // A blocking drain owns both mutation queues until it either commits or returns an error.
    // Allocator callbacks and other same-thread callbacks must not recursively consume the
    // front item while the outer drain still holds a copied value for that item.
    blocking_flush_active: bool = false,
    pending_event_owner: pending_event_owner_mod.PendingEventOwner,
    close_authority: remote_close_authority.CloseAuthority = .{},
    shutdown_attempt_authority: shutdown_attempt_authority_mod.ShutdownAttemptAuthority = .{},
    shutdown_current_admin: shutdown_current_admin_mod.CurrentAdminCoordinator = .{},
    runtime_lifetime: runtime_lifetime_owner_mod.RuntimeLifetimeOwner,
    screen_source: *stable_screen_source.StableScreenSource,
    surface: Surface, // 원격-backed(surface.remote = attachment screen source). GUI가 이걸 렌더.
    // client placeholder는 현재 viewport highlight만 표현한다. Select All 의도는 별도 비트로 소유해
    // copy 때 host의 권위 scrollback 전체에서 selectAll→extractSelection을 원자 실행한다.
    selection_all: bool = false,
    selection_host_authoritative: bool = false,
    /// host가 관측에 실어 보낸 프로세스 신원 — PTY 자식 뿌리와 그것을 소유한 host 프로세스.
    ///
    /// **generation이 아니라 runtime에 둔다.** 값이 runtime 수명 동안 안 바뀌므로(PTY는 한 번 fork된다)
    /// 재접속으로 generation이 갈려도 같은 사실이고, 여기 두면 attach 경로와 event 경로가 같은 자리를 쓴다.
    /// 상태바 리소스 항목이 이 뿌리로 트리를 직접 잰다(docs/status-bar.md §4.1 "host-backed 터미널").
    process_identity: ProcessIdentity = .{},

    /// Stable shell의 실제 `GenerationSlot.currentPayload()`만 current generation을 결정한다.
    fn currentGeneration(self: *RemoteRuntime) *RemoteGeneration {
        return @constCast(self.generation_owner.slot.currentPayload() catch
            @panic("runtime generation slot lost current payload authority"));
    }

    fn currentGenerationConst(self: *const RemoteRuntime) *const RemoteGeneration {
        return self.generation_owner.slot.currentPayload() catch
            @panic("runtime generation slot lost current payload authority");
    }

    fn currentAttachmentTerminal(self: *const RemoteRuntime) bool {
        return switch (self.currentGenerationConst().attachment) {
            .generation => |*attachment| generationAttachmentTerminal(attachment),
            .legacy => false,
        };
    }

    /// `RemoteTermBackend`는 active generation의 저장 위치를 알지 않고 frame/observation 역할만 요청한다.
    /// e2에서 current가 inline node에서 heap node로 바뀌어도 backend 호출 계약은 그대로 유지된다.
    pub const backend_api = struct {
        pub const ReconnectClientReplacementResult = union(enum) {
            published,
            forward_failed: anyerror,
        };

        pub fn reconnectRuntimeSetIdentity(
            runtime: *RemoteRuntime,
        ) !RuntimeSetIdentityProjection {
            try runtime.admitRuntimeOperation();
            const runtime_id = std.fmt.parseInt(u128, &runtime.runtime_id_hex, 16) catch
                return error.InvalidAuthority;
            const shell_generation = try runtime.generation_owner.currentGeneration();
            if (runtime_id == 0 or shell_generation == 0) return error.InvalidAuthority;
            return .{ .runtime_id = runtime_id, .shell_generation = shell_generation };
        }

        pub fn prepareHostWideRetirement(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            transaction_addr: usize,
            transaction_generation: u64,
        ) !void {
            try runtime.admitRuntimeOperation();
            return runtime.generation_owner.prepareHostWideRetirement(
                adapter,
                transaction_addr,
                transaction_generation,
            );
        }

        pub fn hostWideRetirementPreparedExact(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            transaction_addr: usize,
            transaction_generation: u64,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.hostWideRetirementPreparedExact(
                adapter,
                transaction_addr,
                transaction_generation,
            );
        }

        pub fn abortHostWideRetirement(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            transaction_addr: usize,
            transaction_generation: u64,
        ) !void {
            try runtime.admitRuntimeOperation();
            return runtime.generation_owner.abortHostWideRetirement(
                adapter,
                transaction_addr,
                transaction_generation,
            );
        }

        pub fn commitHostWideRetirementNoFail(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            transaction_addr: usize,
            transaction_generation: u64,
        ) void {
            runtime.admitRuntimeOperation() catch
                process_seal_service.fatalIntegrity(.proof_loss);
            runtime.generation_owner.commitHostWideRetirementNoFail(
                adapter,
                transaction_addr,
                transaction_generation,
            );
        }

        pub fn hostWideRetirementCommittedExact(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.hostWideRetirementCommittedExact(adapter);
        }

        pub fn hostReconnectPublishedNewExact(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.hostReconnectPublishedNewExact(
                adapter,
                &runtime.mutation_owner,
                runtime.input_batches.epoch,
            );
        }

        pub fn hostReconnectTerminalIdentityExact(
            runtime: *RemoteRuntime,
            expected_runtime_id: u128,
            expected_shell_generation: u64,
        ) bool {
            if (expected_runtime_id == 0 or expected_shell_generation == 0) return false;
            const runtime_id = std.fmt.parseInt(u128, &runtime.runtime_id_hex, 16) catch return false;
            const generation = runtime.generation_owner.currentGeneration() catch return false;
            return runtime_id == expected_runtime_id and generation == expected_shell_generation;
        }

        pub fn reclaimHostWideRetiringGenerationRetainingClient(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.reclaimRetiringGenerationRetainingClientAtTickEnd(adapter);
        }

        /// CR4a single-runtime forward transaction. Fresh Client ownership stays in the backend job;
        /// this leaf only performs the canonical old-generation retirement and same-adapter publication.
        /// Once the unavailable shell is published, failures are forward-only. The caller must seal a
        /// terminal forward-failed job rather than aborting it or restoring the retired attachment.
        pub fn publishReconnectClientReplacement(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            source: *client_mod.Client,
            out: *r2a_client_slot.PreparedClientReplacement,
        ) anyerror!ReconnectClientReplacementResult {
            try runtime.admitRuntimeOperation();
            if (source.host_id == 0 or source.host_id != adapter.hostId() or
                adapter.connectionGeneration() == 0 or !std.meta.eql(out.*, r2a_client_slot.PreparedClientReplacement{}))
                return error.InvalidAuthority;

            const expected_generation = try runtime.generation_owner.currentGeneration();
            const placeholder_generation = std.math.add(u64, expected_generation, 1) catch
                return error.InvalidAuthority;
            var admission: r2a_client_slot.PreparedAdmissionClose = .{};
            try adapter.prepareAdmissionClose(adapter.connectionGeneration(), &admission);
            var admission_prepared = true;
            errdefer if (admission_prepared)
                adapter.cancelAdmissionClose(&admission) catch
                    process_seal_service.fatalIntegrity(.proof_loss);

            var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
            try adapter.prepareRetirementCleanup(&admission, placeholder_generation, &cleanup);
            var cleanup_prepared = true;
            errdefer if (cleanup_prepared)
                adapter.abortRetirementCleanup(&cleanup) catch
                    process_seal_service.fatalIntegrity(.proof_loss);

            _ = try runtime.generation_owner.publishUnavailableAfterAttachmentRetirement(
                adapter,
                &admission,
                &cleanup,
                expected_generation,
                placeholder_generation,
            );
            admission_prepared = false;
            cleanup_prepared = false;
            adapter.finishRetirementCleanup(&cleanup) catch
                process_seal_service.fatalIntegrity(.proof_loss);

            adapter.prepareClientReplacement(&cleanup, source, out) catch |err|
                return .{ .forward_failed = err };
            adapter.publishClientReplacementNoFail(out);
            return .published;
        }

        pub fn preflightReconnectClientReplacementFailure(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            expected_connection_generation: u64,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            if (expected_connection_generation == 0 or
                adapter.connectionGeneration() != expected_connection_generation)
                return error.InvalidAuthority;
            try runtime.generation_owner.preflightUnavailableAfterAttachmentRetirement(
                adapter,
                expected_connection_generation,
            );
        }

        /// Backend host job의 published replacement를 observer candidate와 caught-up receipt로
        /// 한 번에 확장한다. attach, initial snapshot, delta와 barrier는 caller가 준 동일 deadline을 공유한다.
        pub fn prepareReconnectObserverStage(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            request_nonce: u128,
            deadline: client_deadline.AbsoluteDeadline,
            out: *PreparedReconnect,
        ) anyerror!*const catchup_stage_contract.PreparedStage {
            if (request_nonce == 0) return error.InvalidAuthority;
            if (deadline.remainingNs() <= 0) return error.DeadlineExceeded;
            try runtime.prepareObserverReconnectCandidateUntil(adapter, published, deadline, out);
            errdefer runtime.generation_owner.abort(out) catch
                process_seal_service.fatalIntegrity(.proof_loss);
            const runtime_id = std.fmt.parseInt(u128, &runtime.runtime_id_hex, 16) catch
                return error.InvalidAuthority;
            return runtime.generation_owner.prepareCandidateCatchupStage(
                adapter,
                out,
                published,
                runtime_id,
                request_nonce,
                deadline,
                runtime.io,
            );
        }

        pub fn validateReconnectObserverStage(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            deadline: client_deadline.AbsoluteDeadline,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.validateCandidateCatchupStage(
                adapter,
                reconnect,
                published,
                stage,
                deadline,
                true,
            );
        }

        pub fn validateReconnectObserverStageForCleanup(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            deadline: client_deadline.AbsoluteDeadline,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.validateCandidateCatchupStage(
                adapter,
                reconnect,
                published,
                stage,
                deadline,
                false,
            );
        }

        pub fn sealReconnectMutations(
            runtime: *RemoteRuntime,
            budget: *reconnect_mutation_seal.GlobalPasteBudget,
        ) anyerror!reconnect_mutation_seal.SealResult {
            try runtime.admitRuntimeOperation();
            return runtime.sealReconnectMutationQueue(budget);
        }

        pub fn executeReconnectControllerTakeoverUntil(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            deadline: client_deadline.AbsoluteDeadline,
        ) anyerror!generation_attachment_mod.GenerationAttachment.ControllerTransferOutcome {
            try runtime.admitRuntimeOperation();
            return runtime.generation_owner.executeCandidateControllerTakeoverUntil(
                adapter,
                reconnect,
                published,
                stage,
                deadline,
            );
        }

        pub fn validateReconnectControllerEvidence(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.validateCandidateControllerEvidence(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        pub fn abortReconnectControllerEvidence(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.abortCandidateControllerEvidence(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        pub fn promoteReconnectControllerEvidence(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.promoteCandidateControllerEvidence(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        pub fn validateReconnectPromotedController(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) bool {
            runtime.admitRuntimeOperation() catch return false;
            return runtime.generation_owner.validateCandidatePromotedController(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        pub fn abortReconnectPromotedController(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.abortCandidatePromotedController(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        pub fn forceReconnectCandidateResizeUntil(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
            deadline: client_deadline.AbsoluteDeadline,
        ) anyerror!terminal.Size {
            try runtime.admitRuntimeOperation();
            runtime.surface.lockCore(runtime.io);
            defer runtime.surface.unlockCore(runtime.io);
            const size = runtime.surface.renderSnapshot().size;
            try runtime.generation_owner.forceCandidatePromotedResizeUntil(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
                size,
                deadline,
            );
            return size;
        }

        pub fn abortReconnectPromotedControllerAfterTerminal(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.abortCandidatePromotedControllerAfterTerminal(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
            );
        }

        fn publishReconnectPromotedCandidateImpl(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
            expected_size: terminal.Size,
            retain_shared_client: bool,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.preflightCandidatePromotedPublication(
                adapter,
                reconnect,
                published,
                stage,
                controller_generation,
                expected_size,
            );
            if (runtime.direct_input.items.len != 0 or runtime.direct_input_offset != 0 or
                runtime.input_batches.records.items.len != 0 or
                runtime.pending_controls.items.len != 0)
                return error.InvalidAuthority;
            const next_shell_generation = reconnect.candidate.generation;
            const next_input_epoch = std.math.add(u64, runtime.input_batches.epoch, 1) catch
                return error.InvalidAuthority;
            try runtime.mutation_owner.preflightReopen(next_shell_generation, next_input_epoch);
            const next_executor_job_generation = try runtime.reconnect_executor.preflightExternalPublication(
                &runtime.generation_owner,
                next_shell_generation,
            );

            // publishAfterClientReplacement performs every fallible stable-screen/generation
            // preflight before its writer commit. From its successful return onward this suffix
            // contains no recoverable branch: drift is proof loss.
            try runtime.generation_owner.publishAfterClientReplacement(
                adapter,
                reconnect,
                published,
            );
            runtime.input_batches.epoch = next_input_epoch;
            runtime.input_batches.next_sequence = 0;
            runtime.mutation_owner.reopenNoFail(next_shell_generation, next_input_epoch);
            runtime.reconnect_executor.publishExternalNoFail(
                next_executor_job_generation,
                next_shell_generation,
            );
            switch (runtime.currentGeneration().attachment) {
                .generation => |*attachment| attachment.releasePromotedControllerNoFail(
                    stage,
                    controller_generation,
                ),
                .legacy => process_seal_service.fatalIntegrity(.proof_loss),
            }
            if (retain_shared_client) {
                runtime.generation_owner.reclaimRetiringGenerationRetainingClientAtTickEnd(adapter) catch
                    process_seal_service.fatalIntegrity(.proof_loss);
            } else {
                var reclaim: PreparedOrderedRetiringReclaim = .{};
                runtime.generation_owner.prepareOrderedRetiringReclaim(adapter, &reclaim) catch
                    process_seal_service.fatalIntegrity(.proof_loss);
                runtime.generation_owner.commitOrderedRetiringReclaimAtTickEndNoFail(adapter, &reclaim);
            }
        }

        pub fn publishReconnectPromotedCandidate(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
            expected_size: terminal.Size,
        ) anyerror!void {
            return publishReconnectPromotedCandidateImpl(
                runtime,
                adapter,
                published,
                reconnect,
                stage,
                controller_generation,
                expected_size,
                false,
            );
        }

        pub fn publishReconnectPromotedCandidateRetainingSharedClient(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            controller_generation: u64,
            expected_size: terminal.Size,
        ) anyerror!void {
            return publishReconnectPromotedCandidateImpl(
                runtime,
                adapter,
                published,
                reconnect,
                stage,
                controller_generation,
                expected_size,
                true,
            );
        }

        pub fn reconnectMutationSealDigest(
            runtime: *const RemoteRuntime,
        ) ?process_seal_service.CleanupSeal {
            return runtime.reconnectMutationSealDigest();
        }

        pub fn abortReconnectObserverStage(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            deadline: client_deadline.AbsoluteDeadline,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.abortCandidateCatchupStage(
                adapter,
                reconnect,
                published,
                stage,
                deadline,
            );
        }

        pub fn abortReconnectObserverStageForClosedOutcome(
            runtime: *RemoteRuntime,
            adapter: *host_adapter_mod.HostAdapter,
            published: *const r2a_client_slot.PreparedClientReplacement,
            reconnect: *PreparedReconnect,
            stage: *const catchup_stage_contract.PreparedStage,
            deadline: client_deadline.AbsoluteDeadline,
        ) anyerror!void {
            try runtime.admitRuntimeOperation();
            try runtime.generation_owner.abortCandidateCatchupStageForClosedOutcome(
                adapter,
                reconnect,
                published,
                stage,
                deadline,
            );
        }

        pub fn matchesReconnectAdmission(
            runtime: *const RemoteRuntime,
            admission: reconnect_admission_owner.Projection,
        ) bool {
            const connection = runtime.currentGenerationConst().connection;
            return switch (connection) {
                .legacy => false,
                .generation => |adapter| adapter.hostId() == admission.host_id and
                    adapter.connectionGeneration() == admission.connection_generation,
            };
        }

        /// c3 main-owner completion validation must prove that the admission which justified a
        /// blocking worker is still bound to every runtime. Connection identity alone is too
        /// weak: a later incident on the same generation must not be allowed to consume an older
        /// worker completion.
        pub fn matchesBoundReconnectIdentity(
            runtime: *RemoteRuntime,
            host_id: u128,
            host_adapter_generation: u64,
            connection_generation: u64,
            incident_app_instance_nonce: u128,
            incident_sequence: u64,
        ) bool {
            runtime.reconnect_executor.validate(&runtime.generation_owner) catch return false;
            const admission = runtime.reconnect_executor.admission orelse return false;
            return admission.host_id == host_id and
                admission.host_adapter_generation == host_adapter_generation and
                admission.connection_generation == connection_generation and
                admission.incident_id.app_instance_nonce == incident_app_instance_nonce and
                admission.incident_id.sequence == incident_sequence and
                matchesReconnectAdmission(runtime, admission);
        }

        /// Terminal settlement authenticates the stored admission and resident lease without
        /// consulting the mutable current connection. A successful CR5 publication has already
        /// advanced that generation, but it must still release the original incident's lease.
        pub fn preflightBoundReconnectSettlement(
            runtime: *RemoteRuntime,
            budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
            host_id: u128,
            host_adapter_generation: u64,
            connection_generation: u64,
            incident_app_instance_nonce: u128,
            incident_sequence: u64,
        ) !void {
            try runtime.reconnect_executor.validate(&runtime.generation_owner);
            const admission = runtime.reconnect_executor.admission orelse return error.InvalidAuthority;
            if (runtime.reconnect_executor.resident_budget_addr != @intFromPtr(budget) or
                admission.host_id != host_id or
                admission.host_adapter_generation != host_adapter_generation or
                admission.connection_generation != connection_generation or
                admission.incident_id.app_instance_nonce != incident_app_instance_nonce or
                admission.incident_id.sequence != incident_sequence)
                return error.InvalidAuthority;
            try budget.validateLeaseRole(
                &runtime.reconnect_executor.resident_lease,
                runtime.reconnect_executor.resident_lease.role,
            );
        }

        pub fn settleBoundReconnectAdmissionNoFail(
            runtime: *RemoteRuntime,
            budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
        ) void {
            budget.release(
                &runtime.reconnect_executor.resident_lease,
                runtime.reconnect_executor.resident_lease.role,
            ) catch process_seal_service.fatalIntegrity(.proof_loss);
            runtime.reconnect_executor.resident_budget_addr = 0;
            runtime.reconnect_executor.admission = null;
            runtime.reconnect_executor.admission_seal = [_]u8{0} ** 32;
        }

        pub fn bindReconnectAdmission(
            runtime: *RemoteRuntime,
            budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
            admission: reconnect_admission_owner.Projection,
            resident_bytes: usize,
        ) !void {
            try preflightReconnectAdmission(runtime, admission);
            try runtime.reconnect_executor.bindAdmission(
                &runtime.generation_owner,
                budget,
                admission,
                resident_bytes,
            );
        }

        pub fn preflightReconnectAdmission(
            runtime: *RemoteRuntime,
            admission: reconnect_admission_owner.Projection,
        ) !void {
            if (!matchesReconnectAdmission(runtime, admission)) return error.StaleAdmission;
            try runtime.reconnect_executor.validate(&runtime.generation_owner);
            if (runtime.reconnect_executor.admission != null or
                runtime.reconnect_executor.resident_budget_addr != 0 or
                !std.meta.eql(runtime.reconnect_executor.resident_lease, reconnect_resident_budget.Lease{}))
                return error.Busy;
        }

        pub fn directReleaseProjection(runtime: *RemoteRuntime) !DirectReleaseProjection {
            try runtime.reconnect_executor.validate(&runtime.generation_owner);
            const admission = runtime.reconnect_executor.admission orelse return error.InvalidAuthority;
            if (!matchesReconnectAdmission(runtime, admission)) return error.StaleExternalEvent;
            const retry = switch (runtime.reconnect_executor.state.?.phase) {
                .retry_wait_release => |value| value,
                else => return error.IllegalTransition,
            };
            return .{
                .host_id = admission.host_id,
                .host_adapter_generation = admission.host_adapter_generation,
                .connection_generation = admission.connection_generation,
                .incident_app_instance_nonce = admission.incident_id.app_instance_nonce,
                .incident_sequence = admission.incident_id.sequence,
                .job_generation = retry.work.job_generation,
                .shell_generation = retry.work.shell_generation,
                .attempt = retry.work.attempt,
                .candidate_connection_generation = retry.work.candidate_connection_generation,
                .deadline_ns = retry.work.deadline_ns,
                .runtime_id = retry.runtime_id,
            };
        }

        pub fn applyDirectReleaseProjection(
            runtime: *RemoteRuntime,
            expected: DirectReleaseProjection,
        ) !void {
            const actual = try directReleaseProjection(runtime);
            if (!std.meta.eql(actual, expected)) return error.StaleExternalEvent;
            const result = try reconnect_reducer.reduce(runtime.reconnect_executor.state.?, .retry_direct_granted);
            if (result.decision != .resume_with_direct_grant or
                reconnectGenerationEffect(result.decision) != .retain)
                return error.InvalidAuthority;
            runtime.reconnect_executor.state = result.state;
        }

        pub fn closeTransitionProjection(
            runtime: *RemoteRuntime,
            event: CloseEvent,
        ) !CloseTransitionProjection {
            try runtime.reconnect_executor.validate(&runtime.generation_owner);
            return closeTransitionProjectionForState(runtime.reconnect_executor.state.?, event);
        }

        pub fn applyCloseTransitionProjection(
            runtime: *RemoteRuntime,
            expected: CloseTransitionProjection,
        ) !void {
            const actual = try closeTransitionProjection(runtime, expected.event);
            if (!std.meta.eql(actual, expected)) return error.StaleExternalEvent;
            const decision = try runtime.reconnect_executor.applyCloseTransition(
                &runtime.generation_owner,
                expected.event,
            );
            if (@intFromEnum(decision) != expected.decision_raw)
                process_seal_service.fatalIntegrity(.proof_loss);
        }

        pub fn hostReconnectAbandonedToInventoryExact(runtime: *RemoteRuntime) bool {
            runtime.reconnect_executor.validate(&runtime.generation_owner) catch return false;
            const state = runtime.reconnect_executor.state orelse return false;
            return switch (state.close) {
                .abandoned_to_inventory => true,
                else => false,
            };
        }

        pub fn frameSummaryReady(runtime: *const RemoteRuntime) bool {
            return runtime.currentGenerationConst().frame_summary_ready;
        }

        pub fn prepareFrameSummary(runtime: *RemoteRuntime) void {
            const generation = runtime.currentGeneration();
            generation.frame_summary = .{};
            generation.frame_summary_ready = true;
        }

        pub fn hasBufferedFrameWork(runtime: *RemoteRuntime) client_mod.ClientError!bool {
            try runtime.admitRuntimeOperation();
            const generation = runtime.currentGeneration();
            return switch (generation.connection) {
                .legacy => false,
                .generation => |adapter| adapter.hasBufferedRuntimeWork(
                    generation.attachment.streamId(),
                ),
            };
        }

        pub fn hasAnyBufferedFrameWork(runtime: *RemoteRuntime) client_mod.ClientError!bool {
            try runtime.admitRuntimeOperation();
            return switch (runtime.currentGeneration().connection) {
                .legacy => false,
                .generation => |adapter| adapter.hasAnyBufferedRuntimeWork(),
            };
        }

        pub fn hasImmediateFrameWork(runtime: *const RemoteRuntime) bool {
            runtime.admitRuntimeOperation() catch return false;
            const generation = runtime.currentGenerationConst();
            return runtime.direct_input_offset < runtime.direct_input.items.len or
                runtime.pending_controls.items.len != 0 or generation.resync_needed;
        }

        pub fn storeFrameSummary(runtime: *RemoteRuntime, summary: runtime_pump_mod.DrainSummary) void {
            runtime.currentGeneration().frame_summary = summary;
        }

        pub fn takeFrameSummary(runtime: *RemoteRuntime) ?runtime_pump_mod.DrainSummary {
            const generation = runtime.currentGeneration();
            if (!generation.frame_summary_ready) return null;
            const summary = generation.frame_summary;
            generation.frame_summary = .{};
            generation.frame_summary_ready = false;
            return summary;
        }

        pub fn pumpEnded(runtime: *const RemoteRuntime) bool {
            return runtime.currentGenerationConst().pump_ended;
        }

        pub fn markPumpEnded(runtime: *RemoteRuntime) void {
            runtime.currentGeneration().pump_ended = true;
        }

        pub fn foregroundProcessGroup(runtime: *const RemoteRuntime) ?i32 {
            const observation = &runtime.currentGenerationConst().observation;
            if (observation.availability != .current or !observation.foreground_available) return null;
            return observation.foreground_pgid;
        }

        pub fn copyForegroundProcessNames(
            runtime: *const RemoteRuntime,
            out: []maru.pty.types.ForegroundProcessName,
        ) usize {
            const observation = &runtime.currentGenerationConst().observation;
            if (observation.availability != .current or !observation.foreground_available) return 0;
            const count = @min(out.len, observation.foreground_processes.items.len);
            @memcpy(out[0..count], observation.foreground_processes.items[0..count]);
            return count;
        }

        /// host가 알려 준 프로세스 뿌리 둘. 상태바 리소스 표본이 이걸로 트리를 잰다 — 관측(`RuntimeObservation`)
        /// 에 싣지 않는 이유는 그 타입이 **두 backend가 공유하는 seam**이고, 이 사실은 원격에만 있기 때문이다.
        ///
        /// **관측이 current가 아니면 0을 돌려준다**(= "모른다"). `foregroundProcessGroup`이 같은 자리에 건
        /// 것과 같은 가드다. pid는 캐시라 host와 말이 끊긴 뒤에도 값이 남아 있는데, 그 사이 그 pid가 죽고
        /// **OS가 같은 번호를 남에게 재사용하면 남의 메모리를 그 탭 것으로 그린다** — 숫자가 그럴듯해서
        /// 화면으로는 절대 못 잡는 종류다. 못 믿을 때는 재지 않는 편이 낫다(그 행은 `—`가 된다).
        pub fn processIdentity(runtime: *const RemoteRuntime) ProcessIdentity {
            return runtime.process_identity.trusted(
                runtime.currentGenerationConst().observation.availability == .current,
            );
        }

        pub fn observationMatches(runtime: *const RemoteRuntime, out: *const term_backend.RuntimeObservation) bool {
            const observation = &runtime.currentGenerationConst().observation;
            return out.availability == observation.availability and
                out.revision == observation.revision and
                out.size.cols == observation.size.cols and
                out.size.rows == observation.size.rows;
        }

        pub fn copyObservation(
            runtime: *const RemoteRuntime,
            allocator: std.mem.Allocator,
            out: *term_backend.RuntimeObservation,
        ) !void {
            try out.replace(allocator, runtime.currentGenerationConst().observation.view());
        }

        pub fn dumpRecentText(
            runtime: *RemoteRuntime,
            allocator: std.mem.Allocator,
            io: std.Io,
            max_rows: usize,
            max_bytes: usize,
        ) ![]u8 {
            const screen = runtime.currentGeneration().attachment.screenPtr() orelse
                return error.ConnectionClosed;
            return screen.dumpRecentTextUtf8(
                allocator,
                io,
                max_rows,
                max_bytes,
            );
        }
    };

    fn generationConnection(self: *const RemoteRuntime) ?*host_adapter_mod.HostAdapter {
        return switch (self.currentGenerationConst().connection) {
            .legacy => null,
            .generation => |adapter| adapter,
        };
    }

    fn legacyConnection(self: *const RemoteRuntime) *client_mod.Client {
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| client,
            .generation => @panic("generation runtime cannot borrow a raw Client"),
        };
    }

    fn legacyConnectionOrNull(self: *const RemoteRuntime) ?*client_mod.Client {
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| client,
            .generation => null,
        };
    }

    fn testingClient(self: *const RemoteRuntime) *client_mod.Client {
        if (!builtin.is_test) unreachable;
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| client,
            .generation => |adapter| host_adapter_mod.HostAdapter.testing.rawClient(adapter),
        };
    }

    fn poisonConnection(self: *RemoteRuntime, reason: client_poison_mod.ConnectionReason) void {
        switch (self.currentGeneration().connection) {
            .legacy => |client| client.poison(reason),
            .generation => switch (self.currentGeneration().attachment) {
                // generation connection 에 legacy attachment 는 성립할 수 없는 조합이다(손상).
                .legacy => process_seal_service.fatalIntegrity(.poison_kind_mismatch),
                // poison 을 전달하지 못했다. seal 손상일 수도, 이미 끝난 전이일 수도 있다 —
                // 지금은 둘 다 치명으로 남기되 사유만 갈라 다음 사고에서 로그로 판별되게 한다.
                .generation => |*attachment| attachment.poison(reason) catch
                    process_seal_service.fatalIntegrity(.poison_undeliverable),
            },
        }
    }

    fn connectionCapabilities(self: *const RemoteRuntime) generation_contract.GenerationCapabilities {
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| blk: {
                const profile = client.compatibility_profile orelse
                    @import("compatibility.zig").profileForMajor(client.wire_major) orelse
                    @panic("legacy connection has an unsupported wire major");
                break :blk .{
                    .wire_major = client.wire_major,
                    .screen_codec_version = client.screen_codec_version,
                    .attach_schema = switch (profile.attach_schema) {
                        .frozen_controller_only => .frozen_controller_only,
                        .granted_roles => .granted_roles,
                    },
                    .metadata_support = switch (client.metadata_support) {
                        .unsupported => .unsupported,
                        .supported => .supported,
                    },
                    .peer_attach_generation = client.attachment_capabilities.peer_attach_generation,
                    .controller_transfer = client.attachment_capabilities.negotiated_controller_transfer,
                    .screen_viewport_scrolled = client.screen_viewport_scrolled_v1,
                    .async_scroll_to_bottom = client.async_scroll_to_bottom_v1,
                    .async_observation_probe = client.async_observation_probe_v1,
                    .notification_stream_auth = client.notification_stream_auth_v1,
                    .notification_delivery = client.notification_delivery_v1,
                    .runtime_clipboard = client.runtime_clipboard_v1,
                    .runtime_core_command = client.runtime_core_command_v1,
                    .runtime_link_at = client.runtime_link_at_v1,
                    .runtime_selected_text = client.runtime_selected_text_v1,
                    .runtime_selection_state = client.runtime_selection_state_v1,
                };
            },
            .generation => |adapter| adapter.generationCapabilities(),
        };
    }

    /// app-quit 준비는 disk discovery를 다시 하지 않고 runtime이 이미 붙잡은 exact adapter snapshot만 읽는다.
    pub fn appQuitShutdownManifest(self: *const RemoteRuntime) ?host_manifest_mod.Descriptor {
        return switch (self.currentGenerationConst().connection) {
            .legacy => null,
            .generation => |adapter| adapter.shutdownManifest(),
        };
    }

    /// shutdown authority의 target transcript는 host/runtime identity를 고정 길이 값으로만 받는다.
    pub fn appQuitRuntimeId(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    /// host에 runtime을 띄우고(`runtime.spawn`) controller로 attach한 뒤 첫 snapshot을 조립해 원격 Surface를 세운다.
    /// 실패 시 이미 띄운 host runtime을 회수한다(orphan 방지). `argv`/`size`는 spawn할 셸 스펙이다.
    pub fn spawn(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
    ) anyerror!void {
        return self.spawnWithConfig(client, allocator, io, surface_id, request, size, null);
    }

    pub fn spawnWithConfig(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
    ) anyerror!void {
        return self.spawnWithConnection(
            .{ .legacy = client },
            allocator,
            io,
            surface_id,
            request,
            size,
            initial_config,
            null,
        );
    }

    pub fn spawnWithConfigAndNotification(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
        notification: NotificationBootstrap,
    ) anyerror!void {
        return self.spawnWithConnection(.{ .legacy = client }, allocator, io, surface_id, request, size, initial_config, notification);
    }

    pub fn spawnWithAdapter(
        self: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
    ) anyerror!void {
        return self.spawnWithConnection(
            .{ .generation = adapter },
            allocator,
            io,
            surface_id,
            request,
            size,
            initial_config,
            null,
        );
    }

    pub fn spawnWithAdapterAndNotification(
        self: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
        notification: NotificationBootstrap,
    ) anyerror!void {
        return self.spawnWithConnection(.{ .generation = adapter }, allocator, io, surface_id, request, size, initial_config, notification);
    }

    fn spawnWithConnection(
        self: *RemoteRuntime,
        connection: RuntimeConnection,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        initial_config: ?maru.session.core_command.RuntimeConfig,
        notification: ?NotificationBootstrap,
    ) anyerror!void {
        // origin/main의 구 v2 daemon도 runtime.spawn_full 이름은 알지만 unknown `runtime_config` 필드를 무시한다.
        // 새 config codec과 함께 도입된 capability가 없으면 잘못된 기본값으로 spawn 성공을 가장하지 않고,
        // AppSession이 명시적인 in-process fallback 경로를 선택하게 한다.
        const runtime_core_command = switch (connection) {
            .legacy => |client| client.runtime_core_command_v1,
            .generation => |adapter| adapter.generationCapabilities().runtime_core_command,
        };
        if (initial_config != null and !runtime_core_command) return error.UnsupportedSpawnContract;
        const notification_delivery = switch (connection) {
            .legacy => |client| client.notification_delivery_v1,
            .generation => |adapter| adapter.generationCapabilities().notification_delivery,
        };
        if (notification != null and !notification_delivery) return error.UnsupportedSpawnContract;
        try self.initializeGenerationOwner(connection, allocator, io, size);
        errdefer self.deinitGenerationOwnerAndScreenSource();
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.input_batches = .{};
        self.mutation_owner = .{};
        try self.mutation_owner.initInPlace(
            try self.generation_owner.currentGeneration(),
            self.input_batches.epoch,
        );
        self.paused_input_metadata = null;
        self.paused_paste_store = .{};
        self.event_cursor = .{};
        self.pending_controls = .empty;
        self.blocking_flush_active = false;
        self.pending_event_owner = .{};
        self.close_authority = .{};
        self.shutdown_attempt_authority = .{};
        self.shutdown_current_admin = .{};
        self.runtime_lifetime = .{};
        self.selection_all = false;
        self.selection_host_authoritative = false;
        try self.initializePendingEventOwner();

        // 1. runtime.spawn_full — host가 확장 spawn 계약으로 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, request, size, initial_config, notification) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        // 기존 v2 host가 새 필드를 unknown JSON으로 무시해 다른 셸을 띄우지 않도록 새 method 이름을 쓴다. 구 host는
        // invalid_request로 거부하고 기존 runtime attach는 계속 v2로 가능하다.
        const spawn_resp = switch (connection) {
            .legacy => |client| try client.call("runtime.spawn_full", spawn_params),
            .generation => |adapter| try adapter.spawnRuntime(spawn_params),
        };
        defer allocator.free(spawn_resp);
        self.runtime_id_hex = client_mod.extractRuntimeId(spawn_resp) orelse {
            if (std.mem.indexOf(u8, spawn_resp, "invalid_request") != null) return error.UnsupportedSpawnContract;
            return error.SpawnFailed;
        };
        // 이 지점부터 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지) — spawn한 건 우리 소유다.
        errdefer self.terminateBestEffort();

        try self.attachAndAssemble(surface_id, size);
    }

    /// **이미 host에 있는 runtime에 재접속**한다(spawn 없이) — GUI를 재실행하면 workspace가 저장한 `runtime_id_hex`로 같은
    /// host runtime에 붙어 화면·PID·scrollback을 잇는다(§7). runtime이 없으면(host 재시작·runtime 종료 등) attach가
    /// **`error.RuntimeNotFound`**(host가 그 코드를 긍정적으로 응답)를 내고, stale handle은 `error.StaleHostHandle`,
    /// 원인을 단정할 수 없으면 `error.AttachFailed`다. restore caller는 앞의 둘만 "영구 없음"으로 보고 그 Term을 종료
    /// placeholder로 둘 수 있으며, `AttachFailed`는 계속 fail-closed다(§7 접속 실패 행렬).
    /// **`spawn`과 달리 실패해도 runtime을 terminate하지 않는다** — 우리가 띄운 게 아니라 pre-existing이므로(남의 runtime을
    /// attach 실패로 죽이면 안 됨). 성공 뒤 이 RemoteRuntime은 spawn한 것과 동일하게 다룬다(input/resize/pump/terminate).
    pub fn attachExisting(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        return self.attachExistingWithConnection(
            .{ .legacy = client },
            allocator,
            io,
            surface_id,
            runtime_id_hex,
            size,
        );
    }

    pub fn attachExistingWithAdapter(
        self: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        return self.attachExistingWithConnection(
            .{ .generation = adapter },
            allocator,
            io,
            surface_id,
            runtime_id_hex,
            size,
        );
    }

    fn attachExistingWithConnection(
        self: *RemoteRuntime,
        connection: RuntimeConnection,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        try self.initializeGenerationOwner(connection, allocator, io, size);
        errdefer self.deinitGenerationOwnerAndScreenSource();
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.input_batches = .{};
        self.mutation_owner = .{};
        try self.mutation_owner.initInPlace(
            try self.generation_owner.currentGeneration(),
            self.input_batches.epoch,
        );
        self.paused_input_metadata = null;
        self.paused_paste_store = .{};
        self.event_cursor = .{};
        self.pending_controls = .empty;
        self.blocking_flush_active = false;
        self.pending_event_owner = .{};
        self.close_authority = .{};
        self.shutdown_attempt_authority = .{};
        self.shutdown_current_admin = .{};
        self.runtime_lifetime = .{};
        self.selection_all = false;
        self.selection_host_authoritative = false;
        try self.initializePendingEventOwner();
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    fn initializeGenerationOwner(
        self: *RemoteRuntime,
        connection: RuntimeConnection,
        allocator: std.mem.Allocator,
        io: std.Io,
        size: terminal.Size,
    ) !void {
        self.allocator = allocator;
        self.io = io;
        self.generation_owner = .{};
        self.reconnect_executor = .{};
        self.screen_source = try allocator.create(stable_screen_source.StableScreenSource);
        errdefer allocator.destroy(self.screen_source);
        try self.screen_source.initUnavailableInPlace(allocator, io, size);
        errdefer {
            _ = self.screen_source.close() catch null;
            self.screen_source.deinit();
        }
        try self.generation_owner.initBuildingInPlace(
            allocator,
            self.screen_source,
            2,
            InitialRemoteGenerationArgs{
                .allocator = allocator,
                .connection = connection,
            },
            initInitialRemoteGeneration,
        );
    }

    fn initializePendingEventOwner(self: *RemoteRuntime) anyerror!void {
        // legacy와 generation은 같은 process seal domain을 공유한다. generation identity는
        // legacy pristine 우회를 만드는 근거가 아니라 추가 일치 증거로만 사용한다.
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        const process_identity = try process_seal_service.currentReadyIdentity();
        if (self.currentGeneration().connection == .generation) {
            const adapter = self.currentGeneration().connection.generation;
            const adapter_identity = adapter.slot.generationBatchAdapterIdentity() catch
                return error.InvalidOwner;
            if (adapter_identity.pid != process_identity.pid or
                adapter_identity.process_nonce != process_identity.process_nonce)
                return error.InvalidOwner;
        }
        const owner_incarnation = nextRemoteRuntimeOwnerIncarnation() orelse
            return error.OwnerIncarnationExhausted;
        // The lifetime row performs the only recoverable readiness check before publication.
        try self.runtime_lifetime.initInPlace(
            @intFromPtr(self),
            @intFromPtr(&self.pending_event_owner),
            process_identity.process_nonce,
            owner_incarnation,
        );
        self.pending_event_owner.initInPlace(owner_incarnation) catch
            process_seal_service.fatalIntegrity(.proof_loss);
    }

    /// Attachment가 source authority를 밖으로 내보내지 않은 채 Runtime snapshot을 immutable Pending으로 게시한다.
    fn classifyAndPrepareEvent(
        self: *RemoteRuntime,
    ) pending_event_preparation_mod.PrepareError!generation_attachment_mod.GenerationAttachment.PreparedSettlement {
        return self.currentGeneration().attachment.generation.preparePendingSettlement(.{
            .allocator = self.allocator,
            .lifetime_owner = &self.runtime_lifetime,
            .pending_owner = &self.pending_event_owner,
            .runtime_addr = @intFromPtr(self),
            .runtime_extent = @sizeOf(RemoteRuntime),
            .observation = &self.currentGeneration().observation,
            .direct_input = &self.direct_input,
            .direct_input_offset = &self.direct_input_offset,
            .pending_controls = &self.pending_controls,
            .blocking_flush_active = &self.blocking_flush_active,
            .resize_generation = &self.currentGeneration().resize_generation,
            .resize_baseline_present = &self.currentGeneration().resize_baseline_present,
        });
    }

    /// 기존 preparation 단위 테스트가 실제 source view 변조를 주입할 때만 쓰는 격리 helper다.
    fn classifyAndPrepareEventFromSourceForTest(
        self: *RemoteRuntime,
        source_owner: *generation_event_contract_mod.EventOwner,
        source_view: generation_event_contract_mod.PreparationEventView,
        correlation: client_slot_mod.EventCorrelation,
    ) pending_event_preparation_mod.PrepareError!void {
        if (!builtin.is_test) unreachable;
        const context: pending_event_preparation_mod.RuntimePreparationContext = .{
            .runtime_addr = @intFromPtr(self),
            .allocator = self.allocator,
            .lifetime_owner = &self.runtime_lifetime,
            .pending_owner = &self.pending_event_owner,
            .observation = &self.currentGeneration().observation,
            .direct_input = &self.direct_input,
            .direct_input_offset = &self.direct_input_offset,
            .pending_controls = &self.pending_controls,
            .blocking_flush_active = &self.blocking_flush_active,
            .resize_generation = &self.currentGeneration().resize_generation,
            .resize_baseline_present = &self.currentGeneration().resize_baseline_present,
            .source_owner = source_owner,
            .source_view = source_view,
            .correlation = correlation,
        };
        const operation_preflight = self.runtime_lifetime.preflightPreparation() catch |err| return switch (err) {
            error.Busy => error.Busy,
            error.InvalidOwner => error.InvalidOwner,
        };
        const source_identity = pending_event_preparation_mod.sourceIdentityFromView(source_view) catch
            return error.InvalidOwner;
        const source_receipt = pending_event_preparation_mod.preflightSource(
            context,
            source_view,
            operation_preflight,
        ) catch return error.InvalidOwner;
        const snapshot = pending_event_preparation_mod.snapshotRuntimeContext(
            context,
            operation_preflight.owner_incarnation,
            std.mem.zeroes(@FieldType(
                pending_event_preparation_mod.RuntimeSemanticSnapshot,
                "operation_identity",
            )),
            source_identity,
        ) catch return error.InvalidOwner;
        const recipe = pending_event_preparation_mod.recipeFromSourceView(source_view) catch
            return error.InvalidOwner;
        var frame: pending_event_preparation_mod.PreparationFrame = undefined;
        pending_event_preparation_mod.initFrameInPlace(&frame, .{
            .context = context,
            .operation_preflight = operation_preflight,
            .source_receipt = source_receipt,
            .snapshot = snapshot,
            .recipe = recipe,
        }, @sizeOf(RemoteRuntime));
        try remote_runtime_pending_event_mod.prepareTakenEvent(&frame);
    }

    fn admitRuntimeOperation(self: *const RemoteRuntime) client_mod.ClientError!void {
        _ = self.runtime_lifetime.preflightPreparation() catch |err| return switch (err) {
            error.Busy => error.AdminBusy,
            error.InvalidOwner => error.ProtocolError,
        };
    }

    fn admitDestructiveRuntimeOperation(self: *const RemoteRuntime) void {
        self.admitRuntimeOperation() catch
            process_seal_service.fatalIntegrity(.destructive_reentry);
    }

    /// spawn/attachExisting 공통(§10 attach 순서): controller attach(stream_id) → 첫 snapshot 조립 → 원격-backed Surface.
    /// `self.runtime_id_hex`가 이미 채워져 있어야 한다(spawn=runtime.spawn 응답, attachExisting=저장된 값).
    fn attachAndAssemble(self: *RemoteRuntime, surface_id: u64, size: terminal.Size) anyerror!void {
        self.currentGeneration().frame_summary_ready = false;
        self.currentGeneration().frame_summary = .{};
        // 2. runtime.attach(controller) — stream_id + snapshot 순서(§10).
        const runtime_id = std.fmt.parseInt(u128, &self.runtime_id_hex, 16) catch
            return error.AttachFailed;
        var legacy_response: ?[]u8 = null;
        defer if (legacy_response) |bytes| self.allocator.free(bytes);
        var generation_accepted: ?generation_contract.CorrelatedExecutedCall = null;
        var generation_binding_open = false;
        defer if (generation_binding_open) {
            const accepted = generation_accepted orelse
                @panic("generation attach cleanup lost execute receipt");
            _ = self.currentGeneration().attachment.generation.finishResponse(self.generationConnection().?);
            self.currentGeneration().attachment.generation.abortExecutedAttach(
                self.generationConnection().?,
                accepted.executed_call,
            ) catch @panic("generation attach rollback failed");
        };
        const attach_resp: []const u8 = if (self.generationConnection()) |adapter| blk: {
            try self.currentGeneration().attachment.initGenerationInPlace(adapter);
            const prepared = try self.currentGeneration().attachment.generation.prepareControllerAttach(
                adapter,
                runtime_id,
            );
            const result = try self.currentGeneration().attachment.generation.executePreparedAttach(adapter, prepared);
            const correlated = switch (result) {
                .accepted => |value| value,
                .typed_reject => {
                    _ = self.currentGeneration().attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
                .uncertain_or_connection_failure => {
                    _ = self.currentGeneration().attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
            };
            generation_accepted = correlated;
            generation_binding_open = true;
            break :blk try self.currentGeneration().attachment.generation.responseBytes(adapter);
        } else blk: {
            var attach_buf: [96]u8 = undefined;
            const attach_params = std.fmt.bufPrint(
                &attach_buf,
                "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
                .{self.runtime_id_hex},
            ) catch return error.AttachFailed;
            const response = self.legacyConnection().call("runtime.attach", attach_params) catch |err| {
                // `Client.call` can consume a committed response and then fail while duplicating its
                // payload. At that point no stream id exists for targeted rollback, so even an OOM
                // that might have happened before send is conservatively connection-fatal.
                if (err == error.OutOfMemory) self.poisonConnection(.local_resource_exhausted);
                return err;
            };
            legacy_response = response;
            break :blk response;
        };
        const capabilities = self.connectionCapabilities();
        const generation_schema: runtime_metadata_wire.AttachGenerationSchema = switch (capabilities.attach_schema) {
            .frozen_controller_only => .frozen_controller_only,
            .granted_roles => if (capabilities.peer_attach_generation)
                .granted_with_generation
            else
                .granted_without_generation,
        };
        var decoded = remote_attachment.decodeAttachResponse(
            self.allocator,
            attach_resp,
            runtime_id,
            .controller,
            .{
                .generation_schema = generation_schema,
                .metadata_support = switch (capabilities.metadata_support) {
                    .unsupported => .unsupported,
                    .supported => .supported,
                },
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.poisonConnection(.local_resource_exhausted);
                return error.OutOfMemory;
            },
            error.Malformed, error.ResourceExhausted, error.CapabilityViolation => {
                self.poisonConnection(.peer_contract_violation);
                return error.AttachFailed;
            },
        };
        defer decoded.deinit();
        const accepted = switch (decoded) {
            .wire_error => |code| return switch (code) {
                .runtime_not_found => error.RuntimeNotFound,
                .stale_host => error.StaleHostHandle,
                else => error.AttachFailed,
            },
            .accepted => |*value| value,
        };
        switch (accepted.initial_metadata) {
            .current => |*dto| _ = self.applyMetadataDto(dto) catch |err| {
                self.poisonConnection(.peer_contract_violation);
                return err;
            },
            .unsupported, .unavailable => {},
        }
        self.currentGeneration().event_generation_tracking = switch (generation_schema) {
            .frozen_controller_only, .granted_without_generation => .untracked,
            .granted_with_generation => .tracked,
        };
        if (self.generationConnection()) |adapter| {
            if (self.currentGeneration().attachment.generation.finishResponse(adapter) != .cleaned)
                @panic("generation attach response cleanup failed");
            try self.currentGeneration().attachment.generation.commitAccepted(
                adapter,
                generation_accepted.?,
                accepted.state,
                self.allocator,
            );
            generation_binding_open = false;
        } else {
            self.currentGeneration().attachment = .init(self.allocator, accepted.state);
            self.currentGeneration().attachment.bindLegacyTransport(attachmentTransport(self.legacyConnection())) catch {
                self.poisonConnection(.local_invariant_violation);
                return error.AttachFailed;
            };
        }
        // attach RPC가 controller lease를 잡은 뒤 snapshot/화면 조립이 실패하면 caller에는 아직 완성된
        // RemoteRuntime이 없어 detachClientSide를 부를 수 없다. 이 구간에서 반드시 lease와 demux 큐를 되돌린다.
        errdefer {
            self.detachBestEffort();
            self.currentGeneration().attachment.deinitWithConnection(self.currentGeneration().connection);
        }

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        var generation_snapshot: initial_snapshot_owner_mod.InitialSnapshotOwner = .{};
        var generation_snapshot_live = false;
        var legacy_snapshot: ?[]u8 = null;
        const snap: []const u8 = switch (self.currentGeneration().attachment) {
            .legacy => blk: {
                const bytes = try self.legacyConnection().readSnapshot(self.currentGeneration().attachment.streamId());
                legacy_snapshot = bytes;
                break :blk bytes;
            },
            .generation => |*value| blk: {
                try value.readInitialSnapshot(&generation_snapshot);
                generation_snapshot_live = true;
                break :blk try generation_snapshot.borrow();
            },
        };
        defer if (legacy_snapshot) |bytes|
            self.allocator.free(bytes)
        else if (generation_snapshot_live)
            generation_snapshot.deinit() catch
                @panic("generation initial snapshot cleanup lost final owner");
        try self.currentGeneration().attachment.initScreen(capabilities.screen_codec_version);
        // mode bit 자체는 v2에도 우연히 존재할 수 있으므로 hello_ack에서 명시 협상한 host일 때만 "0 = live bottom"을
        // 신뢰한다. 구 host는 capability=false로 두고, RemoteScreen이 snapshot별 visible cursor 증거만으로
        // legacy live preedit/candidate를 허용한다. hidden/ambiguous snapshot은 계속 fail-closed다.
        self.currentGeneration().attachment.screenPtr().?.viewport_scrolled_known = capabilities.screen_viewport_scrolled;
        self.currentGeneration().attachment.screenPtr().?.applySnapshot(snap, self.io) catch |err| {
            switch (self.currentGeneration().attachment) {
                .legacy => {},
                .generation => |*value| {
                    // The snapshot owner holds the node's initial-snapshot permit. Release that
                    // exact owner before fail-closing the transport; the public poison path must
                    // continue to reject unrelated mutation while any operation permit is live.
                    generation_snapshot.deinit() catch
                        @panic("generation initial snapshot cleanup lost final owner");
                    generation_snapshot_live = false;
                    value.poisonInitialSnapshotApply(
                        err == error.OutOfMemory,
                    ) catch @panic("generation snapshot apply failure lost its sealed transport");
                },
            }
            return err;
        };

        // 4. 원격-backed Surface를 세운다(로컬 core는 placeholder — 렌더는 remote 소스로 간다).
        self.surface = try Surface.init(self.allocator, surface_id, size);
        errdefer self.surface.deinit();
        try self.generation_owner.publishInitial();
        try self.reconnect_executor.initInPlace(&self.generation_owner, 1);
        self.surface.remote = self.screen_source.screenSource();
    }

    /// CR4a product leaf. 기존 stable shell은 읽기만 하고 fresh generation Client에 observer로
    /// attach한 완성 candidate를 준비한다. takeover/publication/input은 후속 gate의 별도 권위다.
    pub fn prepareObserverReconnectCandidate(
        self: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        published: *const r2a_client_slot.PreparedClientReplacement,
        out: *PreparedReconnect,
    ) anyerror!void {
        try self.admitRuntimeOperation();
        const runtime_id = std.fmt.parseInt(u128, &self.runtime_id_hex, 16) catch
            return error.AttachFailed;
        if (runtime_id == 0 or adapter.connectionGeneration() == 0)
            return error.InvalidAuthority;
        try self.generation_owner.prepareAfterClientReplacement(
            adapter,
            published,
            out,
            ObserverReconnectCandidateArgs{
                .runtime = self,
                .adapter = adapter,
                .runtime_id = runtime_id,
            },
            initObserverReconnectCandidate,
        );
    }

    pub fn prepareObserverReconnectCandidateUntil(
        self: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        published: *const r2a_client_slot.PreparedClientReplacement,
        deadline: client_deadline.AbsoluteDeadline,
        out: *PreparedReconnect,
    ) anyerror!void {
        try self.admitRuntimeOperation();
        if (deadline.remainingNs() <= 0) return error.DeadlineExceeded;
        const runtime_id = std.fmt.parseInt(u128, &self.runtime_id_hex, 16) catch
            return error.AttachFailed;
        if (runtime_id == 0 or adapter.connectionGeneration() == 0)
            return error.InvalidAuthority;
        try self.generation_owner.prepareAfterClientReplacement(
            adapter,
            published,
            out,
            ObserverReconnectCandidateArgs{
                .runtime = self,
                .adapter = adapter,
                .runtime_id = runtime_id,
                .deadline = deadline,
            },
            initObserverReconnectCandidate,
        );
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    fn deinitGenerationOwnerAndScreenSource(self: *RemoteRuntime) void {
        self.reconnect_executor.deinit(&self.generation_owner) catch
            @panic("runtime reconnect executor teardown lost final authority");
        self.generation_owner.deinit() catch
            @panic("runtime generation owner teardown lost final authority");
        self.screen_source.deinit();
        self.allocator.destroy(self.screen_source);
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.admitDestructiveRuntimeOperation();
        self.terminateBestEffort();
        // terminate response보다 먼저 온 async continuation도 call이 pending_stream에 보존하므로 RPC 뒤 한 번에 회수한다.
        self.surface.deinit();
        self.deinitGenerationOwnerAndScreenSource();
        if (self.paused_paste_store.initialized()) self.paused_paste_store.deinit();
        self.direct_input.deinit(self.allocator);
        self.input_batches.deinit(self.allocator);
        self.pending_controls.deinit(self.allocator);
        self.* = undefined;
    }

    /// client-side 자원만 회수한다(surface/screen) — **host runtime은 안 죽인다**(terminate 안 보냄). 앱 quit 시 host-backed
    /// Term을 이걸로 정리하면 runtime이 host에 남아(연결 EOF를 host가 detach로 처리해 유지, §6 app-quit=detach) GUI 재실행 시
    /// `attachExisting`으로 재접속한다. `deinit`과 대칭이되 terminate만 뺀다.
    pub fn detachClientSide(self: *RemoteRuntime) void {
        self.admitDestructiveRuntimeOperation();
        self.detachClientSideImpl(true);
    }

    /// App-quit owner가 shared data connection을 먼저 terminalize하고 host EOF가 controller lease를
    /// 회수하도록 만든 뒤의 no-wire suffix다. 일반 detach와 달리 이미 닫힌 Client에 detach RPC를 다시
    /// 발행하지 않는다. 이 leaf는 backend의 closed app-quit ordering에서만 호출해야 한다.
    pub fn detachClientSideAfterSharedConnectionTerminalized(self: *RemoteRuntime) void {
        self.admitDestructiveRuntimeOperation();
        self.detachClientSideImpl(false);
    }

    fn detachClientSideImpl(self: *RemoteRuntime, send_detach: bool) void {
        // shared connection은 앱 종료 전까지 EOF가 오지 않을 수 있다. RPC detach 없이 로컬 객체만 버리면 host의 controller
        // lease가 남아 같은 connection의 재attach가 controller_busy가 되므로 subscription을 먼저 명시 해제한다.
        if (send_detach) self.detachBestEffort();
        self.surface.deinit();
        self.deinitGenerationOwnerAndScreenSource();
        if (self.paused_paste_store.initialized()) self.paused_paste_store.deinit();
        self.direct_input.deinit(self.allocator);
        self.input_batches.deinit(self.allocator);
        self.pending_controls.deinit(self.allocator);
        self.* = undefined;
    }

    /// controller를 요청했는데 다른 client가 이미 쥐고 있어 **observer로 강등**된 상태인가.
    ///
    /// host가 두 번째 controller를 조용히 observer로 강등하는 것은 설계대로다(§9 다중 client와 resize —
    /// "두 번째 controller는 조용히 observer로 강등(`controller_busy`)"). `decodeAttachResponse`도 그 조합을
    /// 검증해 attachment 상태까지 실어 나른다. **문제는 그 사실을 아무도 읽지 않는다는 것**이었다 — 그래서
    /// 사용자는 화면은 멀쩡히 갱신되는데 키 입력만 전부 `Unauthorized`로 버려지는 터미널을 이유도 모른 채
    /// 마주한다. 강등 자체를 막지 않고(계약대로다) 관측만 가능하게 한다.
    pub fn attachedAsObserver(self: *const RemoteRuntime) bool {
        return !self.currentGenerationConst().attachment.allowsMutation();
    }

    /// A retained Term is not proof that its transport survived or reconnected. Product-level
    /// AppKit evidence therefore treats only a non-terminal current generation as live; controller
    /// authority is reported separately through `attachedAsObserver`.
    pub fn currentAttachmentLive(self: *const RemoteRuntime) bool {
        return !self.currentAttachmentTerminal();
    }

    pub fn usesGenerationAttachment(self: *const RemoteRuntime) bool {
        return switch (self.currentGenerationConst().attachment) {
            .generation => true,
            .legacy => false,
        };
    }

    /// 렌더/입력 라우팅에 쓸 Surface(GUI가 in-process처럼 다룬다).
    pub fn surfacePtr(self: *RemoteRuntime) *Surface {
        self.admitDestructiveRuntimeOperation();
        return &self.surface;
    }

    fn mutationAllowed(self: *const RemoteRuntime) bool {
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| self.currentGenerationConst().attachment.mutationAllowed(client),
            .generation => self.currentGenerationConst().attachment.allowsMutation(),
        };
    }

    fn beginStableMutation(
        self: *RemoteRuntime,
        out: *reconnect_mutation_seal.MutationLease,
    ) client_mod.ClientError!void {
        const shell_generation = self.generation_owner.currentGeneration() catch blk: {
            if (!builtin.is_test) return error.ProtocolError;
            break :blk self.generation_owner.slot.currentGeneration() catch @as(u64, 1);
        };
        if (builtin.is_test and self.mutation_owner.lifecycle == .pristine) {
            self.mutation_owner.initInPlace(
                shell_generation,
                self.input_batches.epoch,
            ) catch return error.ProtocolError;
        }
        self.mutation_owner.beginMutation(
            shell_generation,
            self.input_batches.epoch,
            out,
        ) catch |err| return switch (err) {
            error.ReconnectBusy, error.Busy => error.AdminBusy,
            else => error.ProtocolError,
        };
    }

    fn finishStableMutation(
        self: *RemoteRuntime,
        lease: *reconnect_mutation_seal.MutationLease,
    ) void {
        self.mutation_owner.finishMutation(lease) catch
            process_seal_service.fatalIntegrity(.proof_loss);
    }

    fn reconnectSealKind(kind: input_owner_mod.QueueRecordKind) reconnect_mutation_seal.SealKind {
        return switch (kind) {
            .key_bytes => .key_bytes,
            .paste => .paste,
            .ime_commit => .ime_commit,
            .osc52_response => .osc52_response,
            .scroll_to_bottom => .scroll_to_bottom,
            .core_command => .core_command,
            .observation_probe => .observation_probe,
        };
    }

    /// CR4a가 unavailable placeholder를 게시한 뒤에도 old-generation mutation owner를 일부러
    /// 전진시키지 않으므로 새 input과 queue pump는 닫히고 기존 bytes는 보존된다. CR4b는 caught-up
    /// staged receipt 아래에서 이 leaf를 호출해 metadata와 허용된 완전 paste 하나만 stable owner로 옮긴다.
    fn sealReconnectMutationQueue(
        self: *RemoteRuntime,
        budget: *reconnect_mutation_seal.GlobalPasteBudget,
    ) anyerror!reconnect_mutation_seal.SealResult {
        const shell_generation = self.mutation_owner.shell_generation;
        const input_epoch = self.input_batches.epoch;
        const initial_direct_input_offset = self.direct_input_offset;
        const progress = try self.mutation_owner.beginSeal(shell_generation, input_epoch);
        if (progress == .waiting_for_leases) return error.Busy;
        var seal_committed = false;
        errdefer if (!seal_committed)
            self.mutation_owner.abortSeal(shell_generation, input_epoch) catch
                process_seal_service.fatalIntegrity(.proof_loss);

        const runtime_value = std.fmt.parseInt(u128, &self.runtime_id_hex, 16) catch
            return error.InvalidAuthority;
        if (runtime_value == 0 or !budget.initialized()) return error.InvalidAuthority;
        var runtime_id: [16]u8 = undefined;
        std.mem.writeInt(u128, &runtime_id, runtime_value, .big);
        if (!self.paused_paste_store.initialized()) {
            try self.paused_paste_store.initInPlace(
                self.allocator,
                budget,
                runtime_id,
                shell_generation,
                input_epoch,
            );
        } else if (self.paused_input_metadata != null or
            (try self.paused_paste_store.projection()) != null)
        {
            return error.Busy;
        }

        const records = self.input_batches.records.items;
        if (records.len == 0) {
            if (self.direct_input_offset != self.direct_input.items.len or
                self.pending_controls.items.len != 0) return error.InvalidAuthority;
            const result = try self.mutation_owner.finishSeal(.clean);
            seal_committed = true;
            return result;
        }

        const entries = try self.allocator.alloc(reconnect_mutation_seal.SealEntry, records.len);
        defer self.allocator.free(entries);
        var byte_cursor = self.direct_input_offset;
        var control_cursor: usize = 0;
        var paste_selected = false;
        var paste_id: u64 = 0;
        var expected_sequence = records[0].sequence;
        if (expected_sequence == 0) return error.InvalidAuthority;
        for (records, 0..) |record, index| {
            if (record.epoch != input_epoch or record.sequence != expected_sequence)
                return error.InvalidAuthority;
            expected_sequence = std.math.add(u64, expected_sequence, 1) catch
                return error.InvalidAuthority;
            if (record.kind.isControl()) {
                if (control_cursor >= self.pending_controls.items.len or record.end_offset != byte_cursor)
                    return error.InvalidAuthority;
                const payload = std.mem.asBytes(&self.pending_controls.items[control_cursor]);
                entries[index] = .{
                    .kind = reconnectSealKind(record.kind),
                    .sequence = record.sequence,
                    .queued_payload = payload,
                };
                control_cursor += 1;
                continue;
            }
            if (record.end_offset <= byte_cursor or record.end_offset > self.direct_input.items.len)
                return error.InvalidAuthority;
            const payload = self.direct_input.items[byte_cursor..record.end_offset];
            const preserve_paste = record.kind == .paste and !paste_selected and
                (index != 0 or self.direct_input_offset == 0);
            entries[index] = .{
                .kind = reconnectSealKind(record.kind),
                .sequence = record.sequence,
                .queued_payload = payload,
                .complete_original = if (preserve_paste) payload else null,
            };
            if (preserve_paste) {
                paste_selected = true;
                paste_id = record.sequence;
            }
            byte_cursor = record.end_offset;
        }
        if (byte_cursor != self.direct_input.items.len or
            control_cursor != self.pending_controls.items.len) return error.InvalidAuthority;

        const metadata = try self.paused_paste_store.sealEntries(entries, paste_id, self.io);
        // sealEntries는 각 live payload를 secure wipe한다. consumed prefix와 spare semantic bytes도
        // 별도 owner가 없으므로 전체 logical backing을 한 번 더 지운 뒤 descriptor만 비운다.
        std.crypto.secureZero(u8, self.direct_input.items);
        self.direct_input.clearRetainingCapacity();
        self.direct_input_offset = 0;
        self.pending_controls.clearRetainingCapacity();
        self.input_batches.records.clearRetainingCapacity();
        self.paused_input_metadata = metadata;
        const classification: reconnect_mutation_seal.SealClassification =
            if (self.blocking_flush_active or initial_direct_input_offset != 0)
                .ambiguous
            else
                .clean;
        const result = self.mutation_owner.finishSeal(classification) catch
            process_seal_service.fatalIntegrity(.proof_loss);
        seal_committed = true;
        return result;
    }

    fn reconnectMutationSealDigest(self: *const RemoteRuntime) ?process_seal_service.CleanupSeal {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.mutation_owner.lifecycle)).*;
        if (lifecycle_raw != @intFromEnum(reconnect_mutation_seal.MutationLifecycle.sealed_clean) and
            lifecycle_raw != @intFromEnum(reconnect_mutation_seal.MutationLifecycle.sealed_ambiguous))
            return null;
        if (self.mutation_owner.active_leases != 0 or !self.paused_paste_store.initialized()) return null;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const hashInt = struct {
            fn add(target: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
                var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, .little);
                target.update(&bytes);
            }
        }.add;
        hashInt(&hasher, u8, lifecycle_raw);
        hashInt(&hasher, u64, self.mutation_owner.shell_generation);
        hashInt(&hasher, u64, self.mutation_owner.input_epoch);
        if (self.paused_input_metadata) |metadata| {
            hashInt(&hasher, u8, 1);
            hasher.update(&metadata.runtime_id);
            hashInt(&hasher, u64, metadata.shell_generation);
            hashInt(&hasher, u64, metadata.input_epoch);
            hashInt(&hasher, u64, metadata.first_sequence);
            hashInt(&hasher, u64, metadata.last_sequence);
            hashInt(&hasher, u32, metadata.total_count);
            hashInt(&hasher, u64, metadata.total_bytes);
            for (metadata.kinds) |kind| {
                hashInt(&hasher, u32, kind.count);
                hashInt(&hasher, u64, kind.bytes);
                hashInt(&hasher, u64, kind.first_sequence);
                hashInt(&hasher, u64, kind.last_sequence);
            }
        } else hashInt(&hasher, u8, 0);
        const paste = self.paused_paste_store.projection() catch return null;
        if (paste) |projection| {
            hashInt(&hasher, u8, 1);
            hashInt(&hasher, u64, projection.id);
            hasher.update(&projection.runtime_id);
            hashInt(&hasher, u64, projection.shell_generation);
            hashInt(&hasher, u64, projection.input_epoch);
            hashInt(&hasher, u64, projection.full_length);
            hasher.update(&projection.hash);
            hashInt(&hasher, u96, @bitCast(projection.expires_at_ns));
        } else hashInt(&hasher, u8, 0);
        var result: process_seal_service.CleanupSeal = undefined;
        hasher.final(&result);
        return result;
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (bytes.len == 0) return;
        // SurfaceRuntime가 이 권위 거부를 InputSuppressed로 바꿔 trace 0과 paste 영구 폐기를
        // 함께 보장한다. 성공으로 숨기면 실제 PTY에 안 간 입력이 trace에 기록된다.
        if (!self.mutationAllowed()) return error.Unauthorized;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        const pending = self.direct_input.items.len - self.direct_input_offset;
        if (bytes.len > max_direct_input_bytes -| pending) return error.OutOfMemory;
        const sequence = try self.nextInputSequence();
        // byte backing과 transcript를 모두 reserve한 뒤에만 observable compaction/append를 수행한다.
        self.direct_input.ensureTotalCapacity(self.allocator, pending + bytes.len) catch return error.OutOfMemory;
        self.input_batches.records.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        self.compactDirectInput();
        self.direct_input.appendSliceAssumeCapacity(bytes);
        self.input_batches.records.appendAssumeCapacity(.{
            .kind = .key_bytes,
            .epoch = self.input_batches.epoch,
            .sequence = sequence,
            .end_offset = self.direct_input.items.len,
        });
        self.input_batches.next_sequence = sequence;
        // 소유권을 queue가 인수한 뒤에는 backpressure나 frame encode OOM을 오류로 돌려 caller가 같은 key를
        // 실패/재시도 처리하게 하지 않는다. hard connection error만 전파하고 tick이 이어 보낸다.
        _ = try self.pumpQueuedInput();
    }

    /// UI tick의 입력을 client 연결의 bounded pending frame에 맡긴다. 반환값은 wire write량이 아니라 client가 소유권을
    /// 인수한 payload 길이라 caller가 partial socket write를 같은 입력으로 재시도하지 않는다.
    pub fn sendInputNonBlocking(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!usize {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        if (!(try self.pumpQueuedInput())) return 0;
        return switch (self.currentGeneration().connection) {
            .legacy => |client| self.currentGeneration().attachment.sendInputNonBlocking(client, bytes),
            .generation => self.currentGeneration().attachment.generation.sendInputNonBlocking(bytes) catch |err|
                return mapGenerationInputError(err),
        };
    }

    /// AppSession의 remote paste/IME/OSC52 batch를 stable runtime queue가 한 번에 인수한다.
    /// reserve가 모두 끝난 뒤에만 bytes/record/sequence를 게시하므로 실패는 mutation 0이다.
    pub fn enqueueInputBatch(self: *RemoteRuntime, batch: input_owner_mod.InputBatch) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        const total = std.math.add(usize, batch.first.len, batch.second.len) catch return error.OutOfMemory;
        if (total == 0) return;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        const pending = self.direct_input.items.len - self.direct_input_offset;
        if (total > max_direct_input_bytes -| pending) return error.OutOfMemory;
        const sequence = try self.nextInputSequence();
        // consumed prefix compaction도 observable mutation이다. 두 backing의 reserve를 먼저 끝내고 나서만
        // compact해야 allocator 실패가 byte/offset/record를 전혀 바꾸지 않는다.
        try self.direct_input.ensureTotalCapacity(self.allocator, pending + total);
        try self.input_batches.records.ensureUnusedCapacity(self.allocator, 1);
        self.compactDirectInput();

        const start = self.direct_input.items.len;
        self.direct_input.appendSliceAssumeCapacity(batch.first);
        if (batch.normalize_first_newlines) {
            for (self.direct_input.items[start..][0..batch.first.len]) |*byte| {
                if (byte.* == '\n') byte.* = '\r';
            }
        }
        self.direct_input.appendSliceAssumeCapacity(batch.second);
        self.input_batches.records.appendAssumeCapacity(.{
            .kind = input_owner_mod.QueueRecordKind.fromBatch(batch.kind),
            .epoch = self.input_batches.epoch,
            .sequence = sequence,
            .end_offset = self.direct_input.items.len,
        });
        self.input_batches.next_sequence = sequence;
        // queue ownership은 이미 이전됐다. hard transport 오류도 caller 재복사를 유도하면 중복 입력이 되므로
        // 다음 pump/terminalization이 stable queue를 정산하게 두고 admission은 성공으로 유지한다.
        _ = self.pumpQueuedInput() catch false;
    }

    /// AppKit callback-safe live-bottom 요청. socket read/blocking write를 하지 않고 stream-local intent만
    /// bounded control FIFO에 넣은 뒤 DONTWAIT admission을 한 번 시도한다. 같은 byte barrier의 연속 scroll은
    /// coalesce하고, 슬롯이 다른 frame으로 막혔으면 tick/input 경로가 다시 시도한다.
    pub fn requestScrollToBottom(self: *RemoteRuntime) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        switch (self.currentGeneration().attachment) {
            .legacy => if (!self.legacyConnection().async_scroll_to_bottom_v1) return,
            .generation => {},
        }
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        const barrier = self.direct_input.items.len;
        if (self.pending_controls.items.len > 0) {
            const last = self.pending_controls.items[self.pending_controls.items.len - 1];
            const decoded = runtime_pending_control.decode(&last) orelse return self.failControlAdmission();
            if (decoded.barrier == std.math.cast(u64, barrier) and decoded.control == .scroll_to_bottom) {
                _ = try self.pumpQueuedInput();
                return;
            }
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        const sequence = try self.nextInputSequence();
        const raw = runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(barrier) orelse
            return self.failControlAdmission();
        self.pending_controls.ensureUnusedCapacity(self.allocator, 1) catch return self.failControlAdmission();
        self.input_batches.records.ensureUnusedCapacity(self.allocator, 1) catch return self.failControlAdmission();
        self.pending_controls.appendAssumeCapacity(raw);
        self.input_batches.records.appendAssumeCapacity(.{
            .kind = .scroll_to_bottom,
            .epoch = self.input_batches.epoch,
            .sequence = sequence,
            .end_offset = barrier,
        });
        self.input_batches.next_sequence = sequence;
        _ = try self.pumpQueuedInput();
    }

    /// focus/config/prompt 등 host-authoritative 명령을 input과 같은 stream-local 시간축에 넣는다. queue가 인수한 뒤
    /// socket backpressure가 생겨도 다음 frame tick이 재시도하며, bounded cap을 넘으면 명시적으로 실패한다.
    pub fn queueCoreCommand(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        // core-command v1은 이미 배포된 닫힌 집합이다. clear를 그 bit 아래 암묵 확장하면 current GUI가 N-1 host에
        // unknown op를 보내 연결을 fail-close한다. 전용 capability가 없으면 안전한 degraded no-op이다.
        if (command == .clear_screen and !self.connectionSupportsClearScreen()) return;
        switch (self.currentGeneration().attachment) {
            .legacy => if (!self.legacyConnection().runtime_core_command_v1) {
                if (command.isLegacyScroll()) return self.sendCoreCommandBlocking(command);
                return;
            },
            .generation => {},
        }
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        const sequence = try self.nextInputSequence();
        const barrier = self.direct_input.items.len;
        const raw = runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
            self.direct_input.items.len,
            command,
        ) orelse return self.failControlAdmission();
        self.pending_controls.ensureUnusedCapacity(self.allocator, 1) catch return self.failControlAdmission();
        self.input_batches.records.ensureUnusedCapacity(self.allocator, 1) catch return self.failControlAdmission();
        self.pending_controls.appendAssumeCapacity(raw);
        self.input_batches.records.appendAssumeCapacity(.{
            .kind = .core_command,
            .epoch = self.input_batches.epoch,
            .sequence = sequence,
            .end_offset = barrier,
        });
        self.input_batches.next_sequence = sequence;
        _ = try self.pumpQueuedInput();
    }

    pub const ObservationProbeAdmission = enum { accepted, busy, unsupported };
    pub const ObservationProbePoll = enum { pending, completed, stale };

    /// Queues one fresh metadata barrier on the existing managed generation connection. The
    /// nonce becomes active in the same stable mutation that publishes its input barrier, so an
    /// event can never complete an action that was not admitted locally.
    pub fn requestObservationProbe(
        self: *RemoteRuntime,
        nonce: u64,
    ) client_mod.ClientError!ObservationProbeAdmission {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (nonce == 0) return error.ProtocolError;
        const generation = self.currentGeneration();
        if (generation.connection != .generation or
            !self.connectionCapabilities().async_observation_probe)
            return .unsupported;
        if (generation.observation_probe_active != 0 or generation.observation_probe_abandoned != 0 or
            generation.observation_probe_completed != 0)
            return .busy;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        if (self.pending_controls.items.len >= max_pending_controls) {
            try self.failControlAdmission();
            unreachable;
        }
        const sequence = try self.nextInputSequence();
        const barrier = self.direct_input.items.len;
        const raw = runtime_pending_control.RawQueuedRuntimeControl.observationProbe(barrier, nonce) orelse
            return error.ProtocolError;
        self.pending_controls.ensureUnusedCapacity(self.allocator, 1) catch {
            try self.failControlAdmission();
            unreachable;
        };
        self.input_batches.records.ensureUnusedCapacity(self.allocator, 1) catch {
            try self.failControlAdmission();
            unreachable;
        };
        self.pending_controls.appendAssumeCapacity(raw);
        self.input_batches.records.appendAssumeCapacity(.{
            .kind = .observation_probe,
            .epoch = self.input_batches.epoch,
            .sequence = sequence,
            .end_offset = barrier,
        });
        self.input_batches.next_sequence = sequence;
        generation.observation_probe_active = nonce;
        _ = self.pumpQueuedInput() catch |err| {
            // The control may already be resident in the managed Client or on the socket. The
            // caller has not observed `.accepted`, so it cannot own cancellation; retain only an
            // abandoned correlation that consumes an exact late metadata event without applying
            // it to a later user action. A terminal/reconnected generation discards this state.
            generation.observation_probe_active = 0;
            generation.observation_probe_abandoned = nonce;
            return err;
        };
        return .accepted;
    }

    pub fn pollObservationProbe(self: *RemoteRuntime, nonce: u64) ObservationProbePoll {
        if (nonce == 0) return .stale;
        const generation = self.currentGeneration();
        if (generation.observation_probe_completed == nonce) {
            generation.observation_probe_completed = 0;
            return .completed;
        }
        if (generation.observation_probe_active == nonce) return .pending;
        return .stale;
    }

    /// Stops publishing a timed-out result to AppSession while retaining exact late-event
    /// correlation. This avoids poisoning the shared managed connection merely because the host
    /// answered after the user-action deadline.
    pub fn abandonObservationProbe(self: *RemoteRuntime, nonce: u64) bool {
        if (nonce == 0 or self.currentGeneration().observation_probe_active != nonce or
            self.currentGeneration().observation_probe_abandoned != 0)
            return false;
        self.currentGeneration().observation_probe_active = 0;
        self.currentGeneration().observation_probe_abandoned = nonce;
        return true;
    }

    fn connectionSupportsClearScreen(self: *const RemoteRuntime) bool {
        return switch (self.currentGenerationConst().connection) {
            .legacy => |client| client.runtime_clear_screen_v1,
            .generation => |adapter| adapter.supportsClearScreen(),
        };
    }

    const max_direct_input_bytes: usize = 64 * 1024;
    const max_pending_controls: usize = 64;

    fn nextInputSequence(self: *const RemoteRuntime) client_mod.ClientError!u64 {
        const sequence = std.math.add(u64, self.input_batches.next_sequence, 1) catch return error.OutOfMemory;
        if (sequence == 0 or self.input_batches.epoch == 0) return error.ProtocolError;
        return sequence;
    }

    const queue_testing = if (builtin.is_test) struct {
        fn appendRecord(
            self: *RemoteRuntime,
            kind: input_owner_mod.QueueRecordKind,
            end_offset: usize,
        ) !void {
            const sequence = try self.nextInputSequence();
            try self.input_batches.records.append(self.allocator, .{
                .kind = kind,
                .epoch = self.input_batches.epoch,
                .sequence = sequence,
                .end_offset = end_offset,
            });
            self.input_batches.next_sequence = sequence;
        }
    } else struct {};

    fn failControlAdmission(self: *RemoteRuntime) client_mod.ClientError!void {
        // cap 초과뿐 아니라 queue allocation OOM도 caller가 UI best-effort로 삼키면 최종 focus/config 상태가
        // 조용히 유실된다. 이 stream만 복구할 ACK가 없으므로 shared connection을 poison해 다음 pump가
        // 명시적 disconnect와 surface exit latch를 관측하게 한다.
        self.poisonConnection(.local_queue_exhausted);
        return error.ConnectionClosed;
    }

    fn admitControl(self: *RemoteRuntime, raw: runtime_pending_control.RawQueuedRuntimeControl) client_mod.ClientError!bool {
        if (!self.mutationAllowed()) return error.Unauthorized;
        const control = runtime_pending_control.decode(&raw) orelse return error.ProtocolError;
        if (self.currentGeneration().attachment == .generation) {
            return self.currentGeneration().attachment.generation.sendControlNonBlocking(raw.control) catch |err|
                return normalizeGenerationControlError(err);
        }
        return switch (control.control) {
            .scroll_to_bottom => self.legacyConnection().sendScrollToBottomNonBlocking(self.currentGeneration().attachment.streamId()) catch |err| switch (err) {
                error.OutOfMemory => false,
                else => return err,
            },
            .core_command => |raw_command| blk: {
                const command = runtime_pending_control.toCoreCommand(raw_command);
                const params = core_command_wire.encodeParams(self.allocator, self.currentGeneration().attachment.streamId(), command) catch break :blk false;
                defer self.allocator.free(params);
                break :blk self.legacyConnection().sendCoreCommandNonBlocking(self.currentGeneration().attachment.streamId(), params) catch |err| switch (err) {
                    error.OutOfMemory => false,
                    else => return err,
                };
            },
            .observation_probe => return error.ProtocolError,
        };
    }

    fn normalizeGenerationControlError(
        err: @import("generation_transport.zig").ControlError,
    ) client_mod.ClientError!bool {
        // Product parity: a negotiated older host consumes unsupported best-effort controls
        // without a wire fallback. Retryable local admission retains the queue.
        return switch (err) {
            error.Unsupported => true,
            error.Busy, error.ResourceExhausted => false,
            error.InvalidOwner, error.ProtocolError => error.ProtocolError,
            error.Unauthorized => error.Unauthorized,
            error.ConnectionClosed => error.ConnectionClosed,
        };
    }

    fn normalizeGenerationBlockingControlError(
        err: @import("generation_transport.zig").ControlError,
    ) client_mod.ClientError!void {
        return switch (err) {
            error.Unsupported => {},
            error.ResourceExhausted => error.OutOfMemory,
            error.Busy => error.AdminBusy,
            error.InvalidOwner, error.ProtocolError => error.ProtocolError,
            error.Unauthorized => error.Unauthorized,
            error.ConnectionClosed => error.ConnectionClosed,
        };
    }

    fn compactDirectInput(self: *RemoteRuntime) void {
        if (self.direct_input_offset == 0) return;
        // 모든 control barrier는 아직 소비하지 않은 byte suffix 안에 있다. suffix를 앞으로 당길 때 같은 양만큼
        // 보정해 input→control→input 시간 위치를 보존한다.
        const consumed = self.direct_input_offset;
        const remaining = self.direct_input.items[consumed..];
        std.mem.copyForwards(u8, self.direct_input.items[0..remaining.len], remaining);
        self.direct_input.items.len = remaining.len;
        for (self.pending_controls.items) |*control| {
            std.debug.assert(control.barrier >= consumed);
            control.barrier -= @intCast(consumed);
        }
        for (self.input_batches.records.items) |*record| {
            std.debug.assert(record.end_offset >= consumed);
            record.end_offset -= consumed;
        }
        self.direct_input_offset = 0;
    }

    fn retireInputQueueRecords(self: *RemoteRuntime) void {
        var retired: usize = 0;
        while (retired < self.input_batches.records.items.len and
            !self.input_batches.records.items[retired].kind.isControl() and
            self.input_batches.records.items[retired].end_offset <= self.direct_input_offset) : (retired += 1)
        {}
        if (retired == 0) return;
        const remaining = self.input_batches.records.items[retired..];
        std.mem.copyForwards(input_owner_mod.QueueRecord, self.input_batches.records.items[0..remaining.len], remaining);
        self.input_batches.records.items.len = remaining.len;
    }

    fn validateControlRecord(
        self: *const RemoteRuntime,
        kind: input_owner_mod.QueueRecordKind,
        barrier: usize,
    ) client_mod.ClientError!void {
        if (self.input_batches.records.items.len == 0) return error.ProtocolError;
        const record = self.input_batches.records.items[0];
        if (record.kind != kind or record.end_offset != barrier or
            record.epoch != self.input_batches.epoch or record.sequence == 0)
            return error.ProtocolError;
    }

    fn retireControlRecordNoFail(self: *RemoteRuntime) void {
        std.debug.assert(self.input_batches.records.items.len > 0);
        _ = self.input_batches.records.orderedRemove(0);
    }

    /// 직접 key FIFO와 control FIFO를 단일 시간 순서로 Client outbound에 넘긴다.
    const QueuedInputPump = enum { ready, blocked, sibling_revoke };

    fn pumpQueuedInputOutcome(self: *RemoteRuntime) client_mod.ClientError!QueuedInputPump {
        // Blocking drain이 front item의 copied value를 들고 있는 동안 callback이 public queue API를
        // 재진입해 같은 item을 소비하지 못하게 한다. false는 기존 backpressure와 같은 retained-owner 결과다.
        if (self.blocking_flush_active) return .blocked;
        if (!self.mutation_owner.admits(
            self.generation_owner.currentGeneration() catch blk: {
                if (!builtin.is_test) return error.ProtocolError;
                break :blk self.generation_owner.slot.currentGeneration() catch @as(u64, 1);
            },
            self.input_batches.epoch,
        )) return .blocked;
        if (!self.currentGeneration().attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return .ready;
        }
        if (self.legacyConnectionOrNull()) |client|
            if (self.currentGeneration().attachment.hasBufferedControllerRevoke(client)) return .sibling_revoke;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = std.math.cast(usize, control.barrier) orelse return error.ProtocolError;
                if (self.direct_input_offset < barrier) {
                    const accepted = switch (self.currentGeneration().connection) {
                        .legacy => |client| self.currentGeneration().attachment.sendInputNonBlocking(
                            client,
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ),
                        .generation => self.currentGeneration().attachment.generation.sendInputNonBlocking(
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ) catch |err| return mapGenerationInputError(err),
                    } catch |err| switch (err) {
                        error.OutOfMemory, error.AdminBusy => return .blocked,
                        else => return err,
                    };
                    if (accepted == 0) return .blocked;
                    self.direct_input_offset += accepted;
                    self.retireInputQueueRecords();
                    continue;
                }
                const decoded = runtime_pending_control.decode(&control) orelse return error.ProtocolError;
                try self.validateControlRecord(
                    switch (decoded.control) {
                        .scroll_to_bottom => .scroll_to_bottom,
                        .core_command => .core_command,
                        .observation_probe => .observation_probe,
                    },
                    barrier,
                );
                if (!(try self.admitControl(control))) return .blocked;
                self.retireControlRecordNoFail();
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                const accepted = switch (self.currentGeneration().connection) {
                    .legacy => |client| self.currentGeneration().attachment.sendInputNonBlocking(
                        client,
                        self.direct_input.items[self.direct_input_offset..],
                    ),
                    .generation => self.currentGeneration().attachment.generation.sendInputNonBlocking(
                        self.direct_input.items[self.direct_input_offset..],
                    ) catch |err| return mapGenerationInputError(err),
                } catch |err| switch (err) {
                    error.OutOfMemory, error.AdminBusy => return .blocked,
                    else => return err,
                };
                if (accepted == 0) return .blocked;
                self.direct_input_offset += accepted;
                self.retireInputQueueRecords();
                continue;
            }
            self.retireInputQueueRecords();
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return .ready;
        }
    }

    /// `true` means the input/control FIFO is fully drained. `false` retains historical callers;
    /// the frame pump uses the typed outcome so only a sibling revoke may bypass this ordering gate.
    fn pumpQueuedInput(self: *RemoteRuntime) client_mod.ClientError!bool {
        return (try self.pumpQueuedInputOutcome()) == .ready;
    }

    /// 이 runtime이 이미 소유한 key/control barrier를 blocking RPC보다 먼저 전송한다. RemoteRuntime의 FIFO와
    /// Client의 connection-level pending frame이라는 두 ownership 층 사이에서 mouse/core/resize RPC가 key를
    /// 추월하지 않게 하는 단일 경계다. 각 blocking RPC는 원래도 Client.call에서 pending socket write를 기다린다.
    fn flushQueuedInputBlocking(self: *RemoteRuntime) client_mod.ClientError!void {
        if (self.blocking_flush_active) return error.AdminBusy;
        self.blocking_flush_active = true;
        defer self.blocking_flush_active = false;
        if (!self.currentGeneration().attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return;
        }
        if (self.legacyConnectionOrNull()) |client|
            if (self.currentGeneration().attachment.hasBufferedControllerRevoke(client)) return error.AdminBusy;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = std.math.cast(usize, control.barrier) orelse return error.ProtocolError;
                if (self.direct_input_offset < barrier) {
                    switch (self.currentGeneration().connection) {
                        .legacy => |client| try self.currentGeneration().attachment.sendInput(
                            client,
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ),
                        .generation => self.currentGeneration().attachment.generation.sendInput(
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ) catch |err| return mapGenerationInputError(err),
                    }
                    self.direct_input_offset = barrier;
                    self.retireInputQueueRecords();
                    continue;
                }
                const decoded = runtime_pending_control.decode(&control) orelse return error.ProtocolError;
                try self.validateControlRecord(
                    switch (decoded.control) {
                        .scroll_to_bottom => .scroll_to_bottom,
                        .core_command => .core_command,
                        .observation_probe => .observation_probe,
                    },
                    barrier,
                );
                try self.flushControlBlocking(control);
                self.retireControlRecordNoFail();
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                switch (self.currentGeneration().connection) {
                    .legacy => |client| try self.currentGeneration().attachment.sendInput(
                        client,
                        self.direct_input.items[self.direct_input_offset..],
                    ),
                    .generation => self.currentGeneration().attachment.generation.sendInput(
                        self.direct_input.items[self.direct_input_offset..],
                    ) catch |err| return mapGenerationInputError(err),
                }
                self.direct_input_offset = self.direct_input.items.len;
                self.retireInputQueueRecords();
                continue;
            }
            self.retireInputQueueRecords();
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return;
        }
    }

    fn flushControlBlocking(self: *RemoteRuntime, raw: runtime_pending_control.RawQueuedRuntimeControl) client_mod.ClientError!void {
        const control = runtime_pending_control.decode(&raw) orelse return error.ProtocolError;
        if (self.currentGeneration().attachment == .generation) {
            self.currentGeneration().attachment.generation.sendControl(raw.control) catch |err|
                return normalizeGenerationBlockingControlError(err);
            return;
        }
        switch (control.control) {
            .scroll_to_bottom => try self.legacyConnection().sendScrollToBottom(self.currentGeneration().attachment.streamId()),
            .core_command => |raw_command| {
                const command = runtime_pending_control.toCoreCommand(raw_command);
                const params = core_command_wire.encodeParams(self.allocator, self.currentGeneration().attachment.streamId(), command) catch
                    return error.OutOfMemory;
                defer self.allocator.free(params);
                try self.legacyConnection().sendCoreCommand(self.currentGeneration().attachment.streamId(), params);
            },
            .observation_probe => return error.ProtocolError,
        }
    }

    fn callOrdered(self: *RemoteRuntime, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        try self.flushQueuedInputBlocking();
        return self.currentGeneration().attachment.callOrdered(self.legacyConnectionOrNull(), method, params_json);
    }

    const BoundRpcDecodeApply = *const fn (
        runtime: *RemoteRuntime,
        output: *anyopaque,
        bytes: []const u8,
    ) client_mod.ClientError!void;

    const BoundRpcDecodeContext = struct {
        runtime: *RemoteRuntime,
        expected_tag: generation_contract.RuntimeRequestTag,
        output: *anyopaque,
        apply: BoundRpcDecodeApply,
        decode_error: ?client_mod.ClientError = null,
    };

    fn decodeBoundRpcCallback(
        raw_context: *anyopaque,
        tag: generation_contract.RuntimeRequestTag,
        bytes: []const u8,
    ) generation_contract.RpcDecodeDisposition {
        const context: *BoundRpcDecodeContext = @ptrCast(@alignCast(raw_context));
        if (tag != context.expected_tag) {
            context.decode_error = error.ProtocolError;
            return .protocol_failure;
        }
        context.apply(context.runtime, context.output, bytes) catch |err| {
            context.decode_error = err;
            return if (err == error.ProtocolError) .protocol_failure else .reusable;
        };
        return .reusable;
    }

    fn callDecoded(
        self: *RemoteRuntime,
        request: generation_contract.RuntimeRequest,
        legacy_method: []const u8,
        legacy_params_json: ?[]const u8,
        output: *anyopaque,
        apply: BoundRpcDecodeApply,
    ) client_mod.ClientError!void {
        switch (self.currentGeneration().connection) {
            .legacy => |client| try client.ingestReadableOutOfBandEvidence(),
            .generation => |adapter| try adapter.ingestRuntimeReadableEvidence(),
        }
        switch (RuntimeAttachment.preDecodeBufferedEvents(self)) {
            .proceed => {},
            .stale => return error.Unauthorized,
            .busy => return error.AdminBusy,
            .out_of_memory => return error.OutOfMemory,
            .protocol_failure => return error.ProtocolError,
            .connection_closed => return error.ConnectionClosed,
        }
        try self.flushQueuedInputBlocking();
        return self.callDecodedAfterFlush(
            request,
            legacy_method,
            legacy_params_json,
            output,
            apply,
        );
    }

    fn callDecodedAfterFlush(
        self: *RemoteRuntime,
        request: generation_contract.RuntimeRequest,
        legacy_method: []const u8,
        legacy_params_json: ?[]const u8,
        output: *anyopaque,
        apply: BoundRpcDecodeApply,
    ) client_mod.ClientError!void {
        const tag: generation_contract.RuntimeRequestTag = @enumFromInt(request.tag);
        var context: BoundRpcDecodeContext = .{
            .runtime = self,
            .expected_tag = tag,
            .output = output,
            .apply = apply,
        };
        const disposition = try self.executeDecodedWithManagedPoison(
            request,
            legacy_method,
            legacy_params_json,
            &context,
            decodeBoundRpcCallback,
        );
        if (context.decode_error) |err| return err;
        if (disposition != .reusable) return error.ProtocolError;
    }

    /// Every generation prepared-execution caller crosses this owner once. Timestamp authority is
    /// acquired before ClientSlot enters the registered operation; publication runs only after the
    /// attachment call has unwound that operation.
    fn executeDecodedWithManagedPoison(
        self: *RemoteRuntime,
        request: generation_contract.RuntimeRequest,
        legacy_method: []const u8,
        legacy_params_json: ?[]const u8,
        context: *anyopaque,
        decoder: generation_contract.RpcDecoder,
    ) client_mod.ClientError!generation_contract.RpcDecodeDisposition {
        var poison_capture: incident_publication_contract.PreparedExecutionPoisonCapture = .{};
        var prepared_poison: incident_publication_contract.PreparedManagedPoison = .{};
        var timestamp_receipt: ?app_process_incident_owner.PublicationTimestampReceipt = null;
        const poison_request: ?client_slot_mod.PreparedExecutionPoisonCaptureRequest = switch (self.currentGeneration().connection) {
            .legacy => null,
            .generation => blk: {
                const receipt = app_process_incident_owner.publicationTimestampReceipt() catch |err| {
                    if (builtin.is_test and err == error.InvalidOwner) break :blk null;
                    return error.ProtocolError;
                };
                timestamp_receipt = receipt;
                break :blk .{
                    .timestamp_ns = receipt.timestamp_ns,
                    .controller_generation = self.currentGeneration().attachment.statePtr().controller_generation,
                    .source_site_raw = @intFromEnum(connection_incident.SourceSite.client_response),
                    .allocator_source_site_raw = @intFromEnum(connection_incident.SourceSite.client_cleanup),
                    .capture_addr = @intFromPtr(&poison_capture),
                    .prepared_addr = @intFromPtr(&prepared_poison),
                };
            },
        };
        const disposition = self.currentGeneration().attachment.callDecoded(
            self,
            self.legacyConnectionOrNull(),
            request,
            legacy_method,
            legacy_params_json,
            context,
            decoder,
            poison_request,
        ) catch |err| {
            if (prepared_poison.lifecycle_raw ==
                @intFromEnum(incident_publication_contract.ManagedPoisonLifecycle.prepared))
            {
                const adapter = self.generationConnection() orelse return error.ProtocolError;
                _ = app_process_incident_owner.publishPreparedManagedPoison(
                    adapter,
                    &prepared_poison,
                    timestamp_receipt orelse return error.ProtocolError,
                ) catch return error.ProtocolError;
            } else if (!std.meta.eql(prepared_poison, incident_publication_contract.PreparedManagedPoison{})) {
                return error.ProtocolError;
            }
            return err;
        };
        return disposition;
    }

    fn discardQueuedMutations(self: *RemoteRuntime) void {
        self.direct_input.clearRetainingCapacity();
        self.direct_input_offset = 0;
        self.input_batches.records.clearRetainingCapacity();
        self.pending_controls.clearRetainingCapacity();
    }

    /// canonical PTY size를 바꾼다(host `runtime.resize`). host가 실 `TerminalCore`+`TIOCSWINSZ`에 적용한다.
    pub const ResizeError = client_mod.ClientError || error{
        ResizeRejected,
        RuntimeNotFound,
        ResourceExhausted,
        SequenceExhausted,
    };

    /// RPC replies and async events are two transports for the same host-authoritative full
    /// state. Keep their revision/equivocation rule here so delivery order cannot change whether
    /// an equal-generation size conflict is accepted.
    fn applyResizeFullState(
        self: *RemoteRuntime,
        size: terminal.Size,
        generation: u64,
    ) client_mod.ClientError!bool {
        if (!self.currentGeneration().resize_baseline_present or generation > self.currentGeneration().resize_generation) {
            self.currentGeneration().resize_generation = generation;
            self.currentGeneration().observation.size = size;
            self.currentGeneration().resize_baseline_present = true;
            return true;
        }
        if (generation == self.currentGeneration().resize_generation and
            !std.meta.eql(size, self.currentGeneration().observation.size))
        {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        return false;
    }

    /// 남이 세션을 좁혀 둔 열(S11-6). 0 이면 아무도 안 좁혔다 — 상태줄이 이 값으로 판정한다.
    ///
    pub fn narrowedCols(self: *const RemoteRuntime) u16 {
        return self.narrowed_cols;
    }

    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) ResizeError!void {
        try self.admitRuntimeOperation();
        // Observer viewport follows the controller's canonical runtime size; local window changes
        // are acknowledged as a no-op instead of becoming an infinite GUI retry.
        if (!self.mutationAllowed()) return;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        if (self.currentGeneration().resize_seq == resize_wire.max_counter)
            return error.SequenceExhausted;
        self.currentGeneration().resize_seq += 1;
        var buf: [96]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buf, .{ .resize = .{
            .stream_id = self.currentGeneration().attachment.streamId(),
            .cols = cols,
            .rows = rows,
            .client_sequence = self.currentGeneration().resize_seq,
        } }) catch |err| return switch (err) {
            error.InvalidRequest => error.ResizeRejected,
            error.BufferTooSmall => error.OutOfMemory,
        };
        var context: ResizeDecodeContext = .{
            .runtime = self,
            .client_sequence = self.currentGeneration().resize_seq,
        };
        try self.flushQueuedInputBlocking();
        const disposition = self.executeDecodedWithManagedPoison(
            generation_contract.RuntimeRequest.resize(.{
                .cols = cols,
                .rows = rows,
                .client_sequence = self.currentGeneration().resize_seq,
            }),
            encoded.method,
            encoded.params,
            &context,
            decodeResizeCallback,
        ) catch |err| return err;
        if (context.decode_error) |err| return err;
        if (disposition != .reusable) return error.ProtocolError;
        // **성공한 뒤에야 「내가 요청한 값」이 된다**(S11-6). 보내기 전에 적으면 실패한 요청이
        // 요청으로 남아, 아무도 안 좁혔는데 host 의 현재 크기가 그 값보다 작다는 이유로 상태줄이
        // **「폰이 좁혔다」고 거짓말한다**(적대적 검증 2회차).
        self.requested_cols = cols;
    }

    const ResizeDecodeContext = struct {
        runtime: *RemoteRuntime,
        client_sequence: u64,
        decode_error: ?ResizeError = null,
    };

    fn decodeResizeCallback(
        raw_context: *anyopaque,
        tag: generation_contract.RuntimeRequestTag,
        bytes: []const u8,
    ) generation_contract.RpcDecodeDisposition {
        const context: *ResizeDecodeContext = @ptrCast(@alignCast(raw_context));
        if (tag != .resize) {
            context.decode_error = error.ProtocolError;
            return .protocol_failure;
        }
        const reply = decodeResizeReply(
            context.runtime.allocator,
            bytes,
            context.client_sequence,
        ) catch |err| {
            context.decode_error = err;
            return if (err == error.ProtocolError) .protocol_failure else .reusable;
        };
        switch (reply) {
            .stale => {},
            .applied => |applied| {
                _ = context.runtime.applyResizeFullState(
                    .{ .cols = applied.cols, .rows = applied.rows },
                    applied.resize_generation,
                ) catch |err| {
                    context.decode_error = err;
                    return if (err == error.ProtocolError) .protocol_failure else .reusable;
                };
            },
        }
        return .reusable;
    }

    /// 내 stream(§멀티 runtime demux)의 다음 화면 배치 하나를 소비해 원격 화면에 반영한다(§9/§10). **논블로킹** — 내 배치가
    /// 없으면 `idle`, metadata만 적용했으면 `metadata`, 화면 batch를 적용했으면 `screen`을 돌려준다. caller는 있는 동안
    /// 반복해 다 비우되 metadata를 PTY output activity로 세지 않는다(`RemoteTermBackend`의
    /// drain이 이걸로 `RuntimeEventPump.drainAvailable`과 같은 의미를 만든다). client가 `stream_id`로 demux하므로 여기 도달한
    /// 배치는 **항상 내 것**이다(예전엔 남의 배치를 free해 유실 — code-review #1; 이제 client가 남의 것은 버퍼해 그 runtime pump로
    /// 보낸다). host가 grid/alt 변화 시 delta 대신 fresh snapshot을 push하므로 둘 다 처리한다(is_snapshot이면 리셋, 아니면 증분).
    pub const PumpResult = enum { idle, event_pending, metadata, screen, ended };

    fn publishReadPumpPoisonCapture(
        self: *RemoteRuntime,
        capture: *incident_publication_contract.ReadPumpPoisonCapture,
        timestamp: app_process_incident_owner.PublicationTimestampReceipt,
    ) client_mod.ClientError!void {
        if (capture.self_addr != @intFromPtr(capture) or
            capture.timestamp_ns != timestamp.timestamp_ns or
            capture.source_site_raw != @intFromEnum(connection_incident.SourceSite.client_read) or
            capture.reason_present_raw != 1 or
            std.enums.fromInt(client_poison.ConnectionReason, capture.reason_raw) == null or
            capture.lifecycle_raw != @intFromEnum(incident_publication_contract.ReadPumpPoisonCaptureLifecycle.finalized))
            return error.ProtocolError;
        const generation = switch (self.currentGeneration().attachment) {
            .legacy => return error.ProtocolError,
            .generation => |*value| value,
        };
        const adapter = self.generationConnection() orelse return error.ProtocolError;
        if (capture.batch_adapter_addr != @intFromPtr(&generation.batch_adapter) or
            capture.slot_addr != @intFromPtr(&adapter.slot) or
            capture.controller_generation != self.currentGeneration().attachment.statePtr().controller_generation or
            capture.client_addr != @intFromPtr(adapter.slot.logicalClient()))
            return error.ProtocolError;
        var prepared: incident_publication_contract.PreparedManagedPoison = .{};
        adapter.prepareManagedPoisonRequest(capture.timestamp_ns, .{
            .reason_raw = capture.reason_raw,
            .source_site_raw = capture.source_site_raw,
            .controller_generation = capture.controller_generation,
        }, &prepared) catch return error.ProtocolError;
        _ = app_process_incident_owner.publishPreparedManagedPoison(
            adapter,
            &prepared,
            timestamp,
        ) catch return error.ProtocolError;
    }

    pub fn pumpDelta(
        self: *RemoteRuntime,
    ) (client_mod.ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!PumpResult {
        client_idle_pump_evidence.recordPumpDelta();
        try self.admitRuntimeOperation();
        switch (self.currentGeneration().attachment) {
            .legacy => return self.pumpDeltaInner(),
            .generation => {},
        }
        const timestamp = app_process_incident_owner.publicationTimestampReceipt() catch |err| {
            if (builtin.is_test and err == error.InvalidOwner) return self.pumpDeltaInner();
            return error.ProtocolError;
        };
        client_idle_pump_evidence.recordTimestampSeal();
        var capture: incident_publication_contract.ReadPumpPoisonCapture = .{};
        const generation = switch (self.currentGeneration().attachment) {
            .legacy => unreachable,
            .generation => |*value| value,
        };
        generation.armReadPumpPoisonCapture(
            &capture,
            timestamp.timestamp_ns,
            self.currentGeneration().attachment.statePtr().controller_generation,
        ) catch return error.ProtocolError;
        const result = self.pumpDeltaInner() catch |err| {
            generation.disarmReadPumpPoisonCapture(&capture);
            if (capture.reason_present_raw == 1) {
                try self.publishReadPumpPoisonCapture(&capture, timestamp);
                return err;
            }
            if (capture.reason_present_raw != 0 or capture.reason_raw != 0)
                return error.ProtocolError;
            return err;
        };
        generation.disarmReadPumpPoisonCapture(&capture);
        if (capture.reason_present_raw == 1) {
            try self.publishReadPumpPoisonCapture(&capture, timestamp);
            return error.ConnectionClosed;
        }
        if (capture.reason_present_raw != 0 or capture.reason_raw != 0)
            return error.ProtocolError;
        return result;
    }

    /// screen batch 가 GUI transport 에서 나올 수 없는 outcome 으로 끝났다. 세션 종료로 이어지므로 사유를 남긴다.
    fn logScreenBatchTerminal(self: *const RemoteRuntime, outcome: anytype) void {
        if (builtin.is_test) return;
        std.log.err(
            "remote screen batch terminal: outcome={s} runtime={s}",
            .{ @tagName(outcome), self.runtime_id_hex },
        );
    }

    fn pumpDeltaInner(
        self: *RemoteRuntime,
    ) (client_mod.ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!PumpResult {
        // Revoke/ended events fence mutation. Consume already-buffered authority events before
        // advancing any input/control that was accepted on a previous UI turn.
        var events = self.drainObservationEvents() catch |err| switch (err) {
            error.AdminBusy => return .event_pending,
            else => return err,
        };
        if (events.ended) return .ended;
        if (try self.currentGeneration().attachment.screenRecoveryState(self.legacyConnectionOrNull()) == .needs_resync) {
            self.currentGeneration().resync_needed = true;
            try self.currentGeneration().attachment.discardPendingScreen();
        }
        // 마지막 non-blocking input 뒤에 새 입력/RPC가 영원히 없더라도 frame-loop pump가 연결의 bounded pending frame을
        // 계속 DONTWAIT로 진전시킨다. Client 하나를 여러 runtime이 공유하므로 어느 runtime pump가 호출해도 충분하다.
        const input_outcome = try self.pumpQueuedInputOutcome();
        if (input_outcome == .blocked)
            return if (events.metadata) .metadata else .idle;
        if (input_outcome == .ready)
            _ = try self.currentGeneration().attachment.pumpPendingOutput(self.legacyConnectionOrNull());
        try self.pumpResyncIntent();
        if (input_outcome == .sibling_revoke)
            return if (events.metadata) .metadata else .idle;
        switch (try self.currentGeneration().attachment.pumpScreen(self.io)) {
            .idle => {
                // readStreamBatch가 socket에서 event만 읽어 pending queue에 넣고 screen batch 없이 돌아올 수 있다.
                const after_read = self.drainObservationEvents() catch |err| switch (err) {
                    error.AdminBusy => return .event_pending,
                    else => return err,
                };
                if (after_read.ended) return .ended;
                events.metadata = after_read.metadata or events.metadata;
                return if (events.metadata) .metadata else .idle;
            },
            .applied => {},
            // The blocking GUI transport never produces charged recovery batches. These outcomes
            // belong to the external owner adapter and cannot be interpreted as ordinary screen
            // activity on this connection.
            .recovery_commit_pending, .terminal => |outcome| {
                // **왜 세션이 끝나는지 남긴다.** 이 `ProtocolError` 는 `drainRemoteNow` 의 복구 목록
                // (`GenerationGap`·`MalformedRow`)에 없어 `else` 로 떨어지고, 거기서 `process_state = .exited`
                // 로 세션이 종료된다 — resync 를 시도하지 않으므로 화면이 마지막 상태로 굳고 앱 재시작
                // 말고는 복구 수단이 없다. 바로 위 주석이 "예전엔 read_error 로 뭉개 터미널이 영구 멈췄다"
                // 고 적어 둔 그 실패 모드에, 이 두 outcome 은 아직 남아 있다.
                //
                // 두 outcome 은 원인이 다르다(복구 배치가 왔다 vs 스트림이 끝났다). 사유 없이 나가면
                // 2026-08-27 처럼 「장시간 sleep 뒤 화면이 깨진다」는 관찰만 남고 어느 쪽인지 못 좁힌다.
                logScreenBatchTerminal(self, outcome);
                return error.ProtocolError;
            },
        }
        const after_screen = self.drainObservationEvents() catch |err| switch (err) {
            error.AdminBusy => return .event_pending,
            else => return err,
        };
        if (after_screen.ended) return .ended;
        return .screen;
    }

    const EventDrain = struct {
        metadata: bool = false,
        ended: bool = false,
    };

    const GenerationDrainHookStage = enum {
        before_pending_release,
        before_purge,
        after_purge_not_ended,
        after_current_apply,
        before_current_release,
    };
    const GenerationDrainHookDecision = enum { proceed, busy };
    const GenerationDrainHook = *const fn (
        *RemoteRuntime,
        GenerationDrainHookStage,
    ) GenerationDrainHookDecision;

    fn drainObservationEvents(self: *RemoteRuntime) client_mod.ClientError!EventDrain {
        return switch (self.currentGeneration().attachment) {
            .legacy => self.drainLegacyObservationEvents(),
            .generation => self.drainGenerationObservationEvents(),
        };
    }

    fn drainLegacyObservationEvents(self: *RemoteRuntime) client_mod.ClientError!EventDrain {
        var result: EventDrain = .{};
        while (try self.legacyConnection().takeEventForStream(self.currentGeneration().attachment.streamId())) |frame| {
            defer self.legacyConnection().releaseEvent(frame);
            const verdict = frame.preflight orelse
                runtime_event_wire.preflightEvent(frame.payload, .{});
            try self.applyObservationEvent(
                &result,
                frame.header,
                frame.payload,
                verdict,
            );
        }
        if (result.ended) self.legacyConnection().dropBufferedStream(self.currentGeneration().attachment.streamId());
        return result;
    }

    fn drainGenerationObservationEvents(self: *RemoteRuntime) client_mod.ClientError!EventDrain {
        return self.drainGenerationObservationEventsWithHook(null);
    }

    /// Event-take corruption is discovered while ClientSlot owns a registered operation. Capture
    /// only the reason there, then publish through the process owner after `takeEvent` has unwound
    /// the operation. This is the caller-3 product ingress; it never stores publisher pointers.
    fn takeGenerationEventWithManagedPoison(
        self: *RemoteRuntime,
        generation: *generation_attachment_mod.GenerationAttachment,
    ) @import("generation_transport.zig").EventError!@import("generation_transport.zig").EventTakeOutcome {
        var capture: incident_publication_contract.RegisteredOperationPoisonCapture = .{};
        var prepared: incident_publication_contract.PreparedManagedPoison = .{};
        const timestamp = app_process_incident_owner.publicationTimestampReceipt() catch |err| {
            if (builtin.is_test and err == error.InvalidOwner) return generation.takeEvent();
            return error.Corrupt;
        };
        const outcome = generation.takeEventWithPoisonCapture(.{
            .timestamp_ns = timestamp.timestamp_ns,
            .controller_generation = self.currentGeneration().attachment.statePtr().controller_generation,
            .source_site_raw = @intFromEnum(connection_incident.SourceSite.client_slot_operation),
            .capture_addr = @intFromPtr(&capture),
            .prepared_addr = @intFromPtr(&prepared),
        }) catch |err| {
            if (prepared.lifecycle_raw ==
                @intFromEnum(incident_publication_contract.ManagedPoisonLifecycle.prepared))
            {
                const adapter = self.generationConnection() orelse return error.Corrupt;
                _ = app_process_incident_owner.publishPreparedManagedPoison(
                    adapter,
                    &prepared,
                    timestamp,
                ) catch return error.Corrupt;
            } else if (!std.meta.eql(prepared, incident_publication_contract.PreparedManagedPoison{})) {
                return error.Corrupt;
            }
            return err;
        };
        if (!std.meta.eql(prepared, incident_publication_contract.PreparedManagedPoison{}))
            return error.Corrupt;
        return outcome;
    }

    fn drainGenerationObservationEventsWithHook(
        self: *RemoteRuntime,
        comptime hook: ?GenerationDrainHook,
    ) client_mod.ClientError!EventDrain {
        var result: EventDrain = .{};
        while (true) {
            const generation = &self.currentGeneration().attachment.generation;
            const pending_lifecycle = std.enums.fromInt(
                pending_event_owner_mod.PendingLifecycle,
                self.pending_event_owner.lifecycle_raw,
            ) orelse process_seal_service.fatalIntegrity(.proof_loss);
            if (pending_lifecycle == .prepared) {
                const prepared = generation.preparedSettlementIdentity() catch
                    return error.ProtocolError;
                try self.settleAndCommitPreparedEvent(
                    prepared,
                    &result,
                    .before_pending_release,
                    hook,
                );
                continue;
            }
            if (pending_lifecycle != .idle)
                process_seal_service.fatalIntegrity(.proof_loss);
            if (hook) |run| _ = run(self, .before_purge);
            switch (generation.purgeEndedStream() catch |err|
                return mapGenerationPurgeError(err)) {
                .purged => {
                    result.ended = true;
                    return result;
                },
                .not_ended => if (hook) |run| {
                    _ = run(self, .after_purge_not_ended);
                },
            }
            switch (self.takeGenerationEventWithManagedPoison(generation) catch |err|
                return mapGenerationEventError(err)) {
                .idle => return result,
                .ended_pending => return error.AdminBusy,
                .taken => {},
            }
            const prepared = self.classifyAndPrepareEvent() catch |err| return switch (err) {
                error.Busy => error.AdminBusy,
                error.InvalidOwner => error.ProtocolError,
            };
            try self.settleAndCommitPreparedEvent(
                prepared,
                &result,
                .before_current_release,
                hook,
            );
        }
    }

    fn settleAndCommitPreparedEvent(
        self: *RemoteRuntime,
        prepared: generation_attachment_mod.GenerationAttachment.PreparedSettlement,
        result: *EventDrain,
        stage: GenerationDrainHookStage,
        comptime hook: ?GenerationDrainHook,
    ) client_mod.ClientError!void {
        const borrowed = self.pending_event_owner.borrowPrepared() catch
            return error.ProtocolError;
        if (borrowed.observation_probe_nonce != 0 and
            ((self.currentGeneration().observation_probe_active != borrowed.observation_probe_nonce and
                self.currentGeneration().observation_probe_abandoned != borrowed.observation_probe_nonce) or
                self.currentGeneration().observation_probe_completed != 0))
        {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (hook) |run| if (run(self, stage) == .busy) return error.AdminBusy;
        remote_runtime_pending_event_mod.settlePreparedEvent(
            &self.runtime_lifetime,
            &self.pending_event_owner,
            &self.currentGeneration().attachment.generation,
            prepared.correlation,
            borrowed.effect,
        ) catch |err| return switch (err) {
            error.Busy => error.AdminBusy,
            error.InvalidOwner => error.ProtocolError,
        };
        try self.commitPreparedSemanticEvent(result);
        if (hook) |run| _ = run(self, .after_current_apply);
    }

    fn commitPreparedSemanticEvent(
        self: *RemoteRuntime,
        result: *EventDrain,
    ) client_mod.ClientError!void {
        var permit: pending_event_owner_mod.PreparedSemanticCommit = .{};
        const decision = self.pending_event_owner.beginSemanticCommit(&permit) catch
            process_seal_service.fatalIntegrity(.proof_loss);
        const tag = std.enums.fromInt(
            runtime_event_prepared_types_mod.PreparedEventTag,
            decision.prepared_tag_raw,
        ) orelse process_seal_service.fatalIntegrity(.proof_loss);
        const publish = decision.publish_raw == 1;
        if (decision.publish_raw > 1)
            process_seal_service.fatalIntegrity(.proof_loss);

        var moved_observation: term_backend.RuntimeObservation = .{};
        defer moved_observation.deinit(self.allocator);
        if (tag == .metadata_commit) {
            self.pending_event_owner.moveCommittedObservationNoFail(
                &permit,
                &moved_observation,
            );
            if (publish) std.mem.swap(
                term_backend.RuntimeObservation,
                &self.currentGeneration().observation,
                &moved_observation,
            );
        }

        if (publish) switch (tag) {
            .ignored, .resize_noop, .metadata_noop, .metadata_commit => {
                result.metadata = result.metadata or tag == .metadata_commit;
            },
            .ended => result.ended = true,
            .invalidated => self.currentGeneration().resync_needed = true,
            .resize_commit => {
                self.currentGeneration().observation.size = .{ .cols = decision.cols, .rows = decision.rows };
                self.currentGeneration().resize_generation = decision.resize_generation;
                self.currentGeneration().resize_baseline_present = true;
                result.metadata = true;
            },
            .revoked => {
                self.currentGeneration().attachment.applyPreparedRevokedNoFail(decision.revoke_fence);
                self.discardQueuedMutations();
                result.metadata = true;
            },
            .failure => {},
        };

        const expected_post_digest = self.semanticPostDigest(result);

        // 이전 observation의 allocator callback이 바꿀 수 있는 모든 공개 상태를 POST 증명에 포함해야 한다.
        // callback을 Pending finish 뒤로 미루면 이미 게시한 semantic completion이 callback drift를 놓친다.
        moved_observation.deinit(self.allocator);
        if (builtin.is_test) switch (B4SemanticProofLossTestState.stage) {
            .none => {},
            .observation_drift => {
                B4SemanticProofLossTestState.stage = .none;
                self.currentGeneration().observation.revision +%= 1;
            },
            .continuation_drift => {
                B4SemanticProofLossTestState.stage = .none;
                permit.seal[0] ^= 1;
            },
        };
        const post_digest = self.semanticPostDigest(result);
        if (!std.crypto.timing_safe.eql(
            process_seal_service.CleanupSeal,
            expected_post_digest,
            post_digest,
        )) process_seal_service.fatalIntegrity(.proof_loss);
        self.pending_event_owner.recordSemanticPostNoFail(&permit, post_digest);
        self.pending_event_owner.finishSemanticCommitNoFail(&permit);

        if (decision.observation_probe_nonce != 0) {
            if (self.currentGeneration().observation_probe_active == decision.observation_probe_nonce and
                self.currentGeneration().observation_probe_abandoned == 0 and
                self.currentGeneration().observation_probe_completed == 0)
            {
                self.currentGeneration().observation_probe_active = 0;
                self.currentGeneration().observation_probe_completed = decision.observation_probe_nonce;
            } else if (self.currentGeneration().observation_probe_abandoned == decision.observation_probe_nonce and
                self.currentGeneration().observation_probe_active == 0 and
                self.currentGeneration().observation_probe_completed == 0)
            {
                self.currentGeneration().observation_probe_abandoned = 0;
            } else process_seal_service.fatalIntegrity(.proof_loss);
        }

        if (tag == .failure) {
            const failure = std.enums.fromInt(
                runtime_event_prepared_types_mod.PreparationFailure,
                decision.failure_raw,
            ) orelse process_seal_service.fatalIntegrity(.proof_loss);
            return switch (failure) {
                .out_of_memory, .local_resource_exhausted => error.OutOfMemory,
                .protocol_error => error.ProtocolError,
                .connection_closed => error.ConnectionClosed,
            };
        }
    }

    fn semanticPostDigest(self: *RemoteRuntime, result: *const EventDrain) process_seal_service.CleanupSeal {
        const graph = runtime_observation_digest_mod.cleanupGraph(
            &self.currentGeneration().observation,
            self.allocator,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
        const observation_digest = runtime_observation_digest_mod.digest(
            &self.currentGeneration().observation,
            graph,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
        const attachment_state = self.currentGeneration().attachment.statePtr();
        return runtime_observation_digest_mod.semanticPostDigest(.{
            .observation_digest = observation_digest,
            .resync_needed = self.currentGeneration().resync_needed,
            .resize_generation = self.currentGeneration().resize_generation,
            .resize_baseline_present = self.currentGeneration().resize_baseline_present,
            .attachment_role_raw = @intFromEnum(attachment_state.role),
            .controller_generation = attachment_state.controller_generation,
            .metadata_published = result.metadata,
            .ended_published = result.ended,
        });
    }

    /// close sweep는 새 event를 take하지 않고 이미 게시된 Pending만 tick당 한 번 전진시킨다.
    pub fn advancePendingEventForClose(self: *RemoteRuntime) term_backend.CloseProgress {
        const lifecycle = std.enums.fromInt(
            pending_event_owner_mod.PendingLifecycle,
            self.pending_event_owner.lifecycle_raw,
        ) orelse process_seal_service.fatalIntegrity(.proof_loss);
        switch (lifecycle) {
            .idle => return .complete,
            .preparing, .settling, .committed_cleanup => return .event_pending,
            .prepared => {},
        }
        const prepared = self.currentGeneration().attachment.generation.preparedSettlementIdentity() catch
            process_seal_service.fatalIntegrity(.proof_loss);
        var result: EventDrain = .{};
        self.settleAndCommitPreparedEvent(prepared, &result, .before_pending_release, null) catch |err| return switch (err) {
            error.AdminBusy => .event_pending,
            else => process_seal_service.fatalIntegrity(.proof_loss),
        };
        return if (pending_event_owner_mod.closeReadiness(&self.pending_event_owner) == .complete)
            .complete
        else
            .event_pending;
    }

    fn applyObservationEvent(
        self: *RemoteRuntime,
        result: *EventDrain,
        header: protocol.Header,
        payload: []const u8,
        verdict: runtime_event_wire.Verdict,
    ) client_mod.ClientError!void {
        const observation_probe_nonce: ?u64 = switch (verdict) {
            .accepted => |accepted| switch (accepted.event) {
                .metadata => |metadata| metadata.observation_probe_nonce,
                else => null,
            },
            else => null,
        };
        if (observation_probe_nonce) |nonce| {
            if (self.currentGeneration().observation_probe_active != nonce or
                self.currentGeneration().observation_probe_completed != 0)
            {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
        }
        const classification = runtime_metadata_wire.classifyAndMaterializeEvent(
            self.allocator,
            .{
                .runtime_id = self.currentGeneration().attachment.statePtr().runtime_id,
                .stream_id = self.currentGeneration().attachment.statePtr().stream_id,
            },
            .{
                .role = switch (self.currentGeneration().attachment.statePtr().role) {
                    .observer => .observer,
                    .controller => .controller,
                },
                .generation = switch (self.currentGeneration().event_generation_tracking) {
                    .untracked => .untracked,
                    .tracked => .{
                        .tracked = self.currentGeneration().attachment.statePtr().controller_generation,
                    },
                },
            },
            .{
                .expected_major = self.connectionCapabilities().wire_major,
                .metadata_support = switch (self.connectionCapabilities().metadata_support) {
                    .unsupported => .unsupported,
                    .supported => .supported,
                },
                .verdict = verdict,
            },
            .{
                .major = header.major,
                .kind = header.kind,
                .stream_id = header.stream_id,
                .request_id = header.request_id,
                .flags = header.flags,
                .payload_len = header.payload_len,
                .payload = payload,
            },
        ) catch |err| {
            self.poisonConnection(eventMaterializationPoisonReason(err));
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ProtocolError,
            };
        };
        const event = switch (classification) {
            .accepted => |accepted| accepted,
            .violation => {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            },
        };
        switch (event) {
            .revoked => |generation| {
                const revoke_fence = self.currentGeneration().attachment.applyValidatedRevokedAndFence(
                    self.legacyConnectionOrNull(),
                    generation,
                ) catch {
                    self.poisonConnection(.local_invariant_violation);
                    return error.ProtocolError;
                };
                self.discardQueuedMutations();
                switch (revoke_fence) {
                    .no_pending_stream_frame, .cancelled_before_write => {},
                    .partial_frame_requires_close => {
                        self.poisonConnection(.outbound_partial_write);
                        return error.ConnectionClosed;
                    },
                }
                result.metadata = true;
            },
            .invalidated => {
                // Latch before releasing the event. The next frame-pump turn admits one
                // bounded response-free stream ack; backpressure leaves it set for retry.
                self.currentGeneration().resync_needed = true;
            },
            .resized => |resized| {
                const size: terminal.Size = .{ .cols = resized.cols, .rows = resized.rows };
                if (try self.applyResizeFullState(size, resized.resize_generation))
                    result.metadata = true;
                // **여기서만 판정한다**(S11-6). 이 순간의 크기는 host 가 방금 확정한 값이라,
                // 내가 요청한 값보다 좁으면 남이 좁힌 것이다(그럴 수 있는 경로는 뷰포트 선언뿐).
                // 폰이 떠나면 host 가 기준으로 되돌려 이 값이 다시 같아지고 표시가 사라진다 —
                // 붙는 전이와 떠나는 전이가 **둘 다** 이 이벤트로 온다.
                self.narrowed_cols = narrowedFrom(self.requested_cols, size.cols);
            },
            .metadata => |metadata| {
                var dto = metadata;
                defer dto.deinit();
                result.metadata = (self.applyMetadataDto(&dto) catch |err| {
                    self.poisonConnection(.peer_contract_violation);
                    return err;
                }) or result.metadata;
                if (observation_probe_nonce) |nonce| {
                    self.currentGeneration().observation_probe_active = 0;
                    self.currentGeneration().observation_probe_completed = nonce;
                }
            },
            .ended => result.ended = true,
        }
    }

    fn eventMaterializationPoisonReason(
        err: runtime_metadata_wire.EventMaterializationError,
    ) client_poison.ConnectionReason {
        return switch (err) {
            error.OutOfMemory => .local_resource_exhausted,
            error.LocalInvariant => .local_invariant_violation,
            error.Malformed,
            error.ResourceExhausted,
            error.CapabilityViolation,
            => .peer_contract_violation,
        };
    }

    fn pumpResyncIntent(self: *RemoteRuntime) client_mod.ClientError!void {
        if (!self.currentGeneration().resync_needed) return;
        const accepted = self.currentGeneration().attachment.sendResyncNonBlocking(self.legacyConnectionOrNull()) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => return err,
        };
        if (accepted) self.currentGeneration().resync_needed = false;
    }

    fn applyMetadataDto(
        self: *RemoteRuntime,
        dto: *const runtime_metadata_wire.OwnedMetadataDto,
    ) error{ OutOfMemory, ProtocolError }!bool {
        adoptProcessIdentity(self, dto);
        return applyMetadataDtoToObservation(
            self.allocator,
            &self.currentGeneration().observation,
            dto,
        );
    }

    /// 관측이 실어 온 pid를 받아 둔다. **0이면 덮어쓰지 않는다** — 구 host나 자식이 이미 회수된 관측이
    /// 한 번 섞이면 알고 있던 뿌리가 사라지고 그 탭이 영영 `—`가 된다(값은 원래 안 바뀌므로 유지가 옳다).
    fn adoptProcessIdentity(
        self: *RemoteRuntime,
        dto: *const runtime_metadata_wire.OwnedMetadataDto,
    ) void {
        self.process_identity.adopt(dto.child_pid, dto.host_pid);
    }

    fn applyMetadataDtoToObservation(
        allocator: std.mem.Allocator,
        observation: *term_backend.RuntimeObservation,
        dto: *const runtime_metadata_wire.OwnedMetadataDto,
    ) error{ OutOfMemory, ProtocolError }!bool {
        if (dto.revision < observation.revision) return false;
        if (dto.revision == observation.revision) {
            // A revision is a semantic version, not merely an ordering hint. Accepting different
            // cwd/SSH data under the same revision would let the synchronous SSH barrier return
            // success while retaining a stale destination.
            if (!metadataDtoMatchesObservation(dto, observation.view()))
                return error.ProtocolError;
            return false;
        }
        var processes: [runtime_metadata_wire.max_process_entries]maru.pty.types.ForegroundProcessName =
            undefined;
        for (dto.foregroundProcesses(), 0..) |process, index| {
            processes[index] = .{
                .pid = process.pid,
                .len = process.len,
                .bytes = process.bytes,
            };
        }
        try observation.replace(allocator, .{
            .availability = .current,
            .revision = dto.revision,
            .observer_generation = dto.observer_generation,
            .title_generation = dto.title_generation,
            .size = .{ .cols = dto.cols, .rows = dto.rows },
            .cwd = dto.cwd(),
            .cwd_host = dto.cwdHost(),
            .window_title = dto.windowTitle(),
            .ssh_remote_dest = dto.sshRemoteDest(),
            .semantic_state = @enumFromInt(@intFromEnum(dto.semantic_state)),
            .alt_active = dto.alt_active,
            .app_cursor_keys = dto.app_cursor_keys,
            .app_keypad = dto.app_keypad,
            .kitty_flags = dto.kitty_flags,
            .alternate_scroll = dto.alternate_scroll,
            .mouse_tracking = dto.mouse_tracking,
            .mouse_tracking_mode = dto.mouse_tracking_mode,
            .bell_count = dto.bell_count,
            .clipboard_write_seq = dto.clipboard_write_seq,
            .clipboard_read_seq = dto.clipboard_read_seq,
            .clipboard_read_target = dto.clipboardReadTarget(),
            .bracketed_paste = dto.bracketed_paste,
            .foreground_available = dto.foreground_available,
            .foreground_pgid = dto.foreground_pgid,
            .foreground_processes = processes[0..dto.process_count],
        });
        return true;
    }

    /// host runtime을 종료한다(client-side 자원은 남긴다 — 회수는 `deinit`). `TermRuntimeBackend.close_and_detach`/`close`가
    /// 부른다(계약: routing 끊고 프로세스 kill). 멱등(host가 없는 id 무시). client 객체는 이후 `remove`→`deinit`에서 회수한다.
    pub fn terminate(self: *RemoteRuntime) void {
        self.admitDestructiveRuntimeOperation();
        self.terminateBestEffort();
    }

    /// host에 fresh snapshot 재요청(§9 desync 복구) — 조립기가 `GenerationGap`/`MalformedRow`로 뒤처졌을 때 `pumpDelta` 실패
    /// 경로가 부른다. host가 다음 delta tick에 현재 full snapshot을 snapshot_chunk로 push하고, 그걸 `pumpDelta`의 applySnapshot이
    /// 받아 generation을 리셋해 복구한다(delta는 base_generation이 현재라 stale client를 못 고쳐 snapshot이 유일한 복구). 응답 무시.
    pub fn requestResync(self: *RemoteRuntime) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        var buf: [64]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buf, .{ .resync = .{
            .stream_id = self.currentGeneration().attachment.streamId(),
        } }) catch |err| return switch (err) {
            error.InvalidRequest => error.ProtocolError,
            error.BufferTooSmall => error.OutOfMemory,
        };
        const resp = try self.callOrdered(encoded.method, encoded.params);
        defer self.allocator.free(resp);
        try decodeResyncReply(self.legacyConnectionOrNull(), self.allocator, resp);
    }

    /// periodic event보다 강한 metadata barrier. SSH upload처럼 stale destination으로 실행하면 안 되는 user action이
    /// 직전에 호출한다. host가 subscription revision/base와 같은 원자 상태에서 응답하므로 성공 뒤 observation은 host가
    /// 응답을 만든 시점의 full-state다.
    pub fn refreshObservation(self: *RemoteRuntime) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.currentGeneration().attachment.streamId()}) catch return error.OutOfMemory;
        var before = self.currentGeneration().observation.revision;
        try self.callDecoded(
            generation_contract.RuntimeRequest.observation(),
            "runtime.observation",
            params,
            &before,
            applyObservationResponse,
        );
    }

    fn applyObservationResponse(self: *RemoteRuntime, raw_before: *anyopaque, resp: []const u8) client_mod.ClientError!void {
        const before: *const u64 = @ptrCast(@alignCast(raw_before));
        var seed = runtime_metadata_wire.decodeObservationEnvelope(
            self.allocator,
            resp,
        ) catch |err| {
            self.poisonConnection(.peer_contract_violation);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Malformed, error.ResourceExhausted, error.CapabilityViolation => error.ProtocolError,
            };
        };
        defer seed.deinit();
        const dto = switch (seed) {
            .current => |*current| current,
            .unsupported, .unavailable => {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            },
        };
        const revision = dto.revision;
        if (revision < before.*) {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        const changed = self.applyMetadataDto(dto) catch |err| {
            self.poisonConnection(.peer_contract_violation);
            return err;
        };
        if (revision > before.* and !changed) {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (self.currentGeneration().observation.availability != .current or self.currentGeneration().observation.revision != revision) {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
    }

    /// host에 뷰포트 선택 span을 보내 host의 `extractSelection`(로컬과 같은 함수)으로 뽑은 텍스트를 받는다(§6b 원격 선택 복사).
    /// **선택 의미론은 host core 단일 출처** — client는 렌더용 span만 보내고 콘텐츠 추출(soft-wrap 이음·블록·스크롤백)은 host가
    /// 한다. 단 앱보다 먼저 떠 계속 살아 있는 구 host는 이 RPC를 모르므로 capability가 없을 때만 현재 client 화면 projection의
    /// 보이는 선택을 추출한다. 반환 텍스트는 caller 소유(빈 선택/오류면 null). `block`은 std.fmt가 true/false로 찍어 유효 JSON.
    pub fn selectedText(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        try self.admitRuntimeOperation();
        if (!self.connectionCapabilities().runtime_selected_text or self.attachedAsObserver())
            return self.selectedTextFromProjection(span);
        var buf: [208]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{},\"all\":{},\"authoritative\":{}}}", .{ self.currentGeneration().attachment.streamId(), span.start.row, span.start.col, span.end.row, span.end.col, span.block, self.selection_all, self.selection_host_authoritative }) catch return error.OutOfMemory;
        var output: ?[]u8 = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.selectedText(.{
                .start_row = span.start.row,
                .start_col = span.start.col,
                .end_row = span.end.row,
                .end_col = span.end.col,
                .block = span.block,
                .all = self.selection_all,
                .authoritative = self.selection_host_authoritative,
            }),
            "runtime.selected_text",
            params,
            &output,
            applySelectedTextResponse,
        );
        return output;
    }

    /// Extracts the current remote selection even when a freshly published screen delta has
    /// replaced the client placeholder and erased its render-only span. Once the host owns an
    /// authoritative selection (or Select All intent), the coordinates in selected_text are
    /// deliberately ignored by the host; requiring a client span here would make Cmd+A then
    /// Cmd+C race the next projection refresh.
    pub fn selectedTextCurrent(self: *RemoteRuntime, span: ?terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        const effective = span orelse blk: {
            if (!self.selection_all and !self.selection_host_authoritative) {
                return null;
            }
            break :blk terminal.SelectionSpan{
                .start = .{ .row = 0, .col = 0 },
                .end = .{ .row = 0, .col = 0 },
                .block = false,
            };
        };
        return self.selectedText(effective);
    }

    fn applySelectedTextResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *?[]u8 = @ptrCast(@alignCast(raw_output));
        output.* = try runtime.decodeSelectedTextResponse(bytes);
    }

    fn decodeSelectedTextResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?[]u8 {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        // error envelope는 알려진 코드일 때만 "선택 없음"으로 접는다(모르는 코드 = schema 드리프트).
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        // capability를 광고한 host가 success schema를 지키지 않으면 같은 connection의 나머지 RPC도 신뢰할 수 없다.
        // 구 host 호환은 capability=false에서만 허용하고, 거짓 광고/드리프트는 빈 복사로 숨기지 않는다.
        const text = obj.string("text") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.fields.len != 1) { // 선언한 키(text) 하나만 허용.
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (text.len == 0) return null;
        return self.allocator.dupe(u8, text) catch return error.OutOfMemory;
    }

    /// 원격 Cmd+클릭 링크 열기: host가 **콘텐츠·cwd·파일시스템을 아는 자기 core**로 `extractUrlAt`(추출 + resolve + 존재
    /// stat)을 실행하게 하고 열 대상을 받는다. `scopes`는 client의 `input.link-detection` 비트라 hover 필터와 같은 값을
    /// 보낸다("밑줄 보이는 곳 = 열리는 곳" 유지). capability 없는 구 host에는 **보내지 않는다** — 모르는 RPC를 시험하는
    /// 대신 원격 링크 열기를 비활성한다(잘못된 경로를 여는 것보다 안전). 링크가 없거나 미존재 경로면 null.
    /// 반환 텍스트는 caller 소유. docs/link-detection.md §원격(host-backed) 세션.
    pub const RemoteLink = struct { text: []u8, kind: terminal.LinkKind };

    pub fn linkAt(self: *RemoteRuntime, row: u16, col: u16, scopes: u8) client_mod.ClientError!?RemoteLink {
        try self.admitRuntimeOperation();
        if (!self.connectionCapabilities().runtime_link_at) return null;
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"row\":{d},\"col\":{d},\"scopes\":{d}}}", .{ self.currentGeneration().attachment.streamId(), row, col, scopes }) catch return error.OutOfMemory;
        var output: ?RemoteLink = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.linkAt(.{ .row = row, .col = col, .scopes = scopes }),
            "runtime.link_at",
            params,
            &output,
            applyLinkAtResponse,
        );
        return output;
    }

    fn applyLinkAtResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *?RemoteLink = @ptrCast(@alignCast(raw_output));
        output.* = try runtime.decodeLinkAtResponse(bytes);
    }

    /// `runtime.link_at` success는 링크가 있으면 `{"text":"...","kind":N}`, 없으면 `{"text":""}`다.
    /// `decodeSelectedTextResponse`와 **같은 strict 디코더**를 쓰되 이 두 형태만 허용한다. 예전엔 응답 스키마마다 파서를
    /// 골라 썼고, 필드가 정확히 하나인 객체만 받는 파서에 link success를 통과시키려다 정상 응답이 InvalidJson으로 떨어져
    /// 연결이 fail-close됐다(밑줄은 뜨는데 Cmd+클릭만 안 열리던 버그). `{"error":...}`나 빈 text는 "링크 없음"(null)이다.
    fn decodeLinkAtResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?RemoteLink {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null; // 알려진 error = 링크 없음(일반 클릭으로 흐른다 — 선택 복사와 같은 정책).
        }
        const text = obj.string("text") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        // host의 no-link success는 `{text:""}` 하나뿐이다. 이 분기를 kind보다 먼저 판정해야 기존 same-major host가
        // 미존재 경로를 정상적으로 "링크 없음"으로 돌려줄 때 schema 위반으로 오인하지 않는다.
        if (text.len == 0) {
            if (obj.fields.len != 1) {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const kind_raw = obj.number("kind") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.hasUnknownKey(&.{ "text", "kind" })) { // 선언 밖 키 = schema 드리프트.
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        const kind: terminal.LinkKind = switch (kind_raw) {
            0 => .url,
            1 => .file_path,
            else => {
                // 숫자로 파싱됐다는 사실만으로 wire enum이 유효한 것은 아니다. 미래 kind를 URL로 추측하면 새 의미를
                // 잘못 실행하므로, 같은 major의 정의된 값만 받고 나머지는 connection 전체를 신뢰하지 않는다.
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            },
        };
        return .{
            .text = self.allocator.dupe(u8, text) catch return error.OutOfMemory,
            .kind = kind,
        };
    }

    /// OSC 52 write 결과. `text`가 null이면 대기 중이 없거나(빈 요청) 너무 커서 못 실은 것이고, `too_large`가
    /// 그 둘을 가른다 — client는 too_large면 로컬과 같은 "복사가 너무 큼" 안내를 띄운다(조용한 유실 금지).
    pub const ClipboardWrite = struct { text: ?[]u8, too_large: bool };

    fn eventCursorSnapshot(self: *const RemoteRuntime) maru.app.event_cursor.Snapshot {
        const observation = &self.currentGenerationConst().observation;
        return .{
            .observer_generation = observation.observer_generation,
            .bell_count = observation.bell_count,
            .clipboard_write_seq = observation.clipboard_write_seq,
            .clipboard_read_seq = observation.clipboard_read_seq,
        };
    }

    pub fn takeBellEvent(self: *RemoteRuntime) bool {
        return self.event_cursor.takeBell(self.eventCursorSnapshot());
    }

    pub fn takeClipboardReadTarget(self: *RemoteRuntime, allocator: std.mem.Allocator) !?[]u8 {
        const prepared = self.event_cursor.prepare(.clipboard_read, self.eventCursorSnapshot()) orelse return null;
        const owned = try allocator.dupe(u8, self.currentGeneration().observation.clipboard_read_target.items);
        errdefer allocator.free(owned);
        const after = self.eventCursorSnapshot();
        // **`observer_generation` 은 보지 않는다.** 그 값은 출력 revision 이라(PTY 바이트마다 증가)
        // RPC 왕복 중 셸이 한 줄만 뱉어도 달라진다. 여기서 비교하면 가져온 결과를 거의 매번 버리는데,
        // host 는 이미 버퍼를 비운 뒤라 사용자의 복사가 사라진다(persistent-session-host.md 규율 3).
        // 확인해야 할 것은 "그 사이 seq 가 또 움직였나" 이고 그건 아래 seq 비교가 한다.
        if (after.clipboard_read_seq != prepared.sequence or
            !std.mem.eql(u8, owned, self.currentGeneration().observation.clipboard_read_target.items))
        {
            return error.ProtocolError;
        }
        if (!self.event_cursor.commit(prepared)) return error.InvalidOwner;
        return owned;
    }

    /// OSC 52 write 텍스트를 host에서 가져온다(host는 넘기면 비운다). capability 없는 구 host면 null —
    /// 원격 클립보드 쓰기가 비활성이다(모르는 RPC를 시험하지 않는다). 반환 텍스트는 caller 소유.
    ///
    /// **base64로 받는다**: OSC 52 데이터는 임의 바이트라 JSON 문자열로 그대로 오면 strict 디코더의 UTF-8 검증에
    /// 걸려 connection이 fail-close된다(복사 한 번에 앱 전역 연결이 끊긴다). host가 base64로 싣고 여기서 푼다.
    pub fn clipboardWrite(self: *RemoteRuntime) client_mod.ClientError!?ClipboardWrite {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.connectionCapabilities().runtime_clipboard) return null;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        const prepared = self.event_cursor.prepare(.clipboard_write, self.eventCursorSnapshot()) orelse return null;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.currentGeneration().attachment.streamId()}) catch return error.OutOfMemory;
        var output: ?ClipboardWrite = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.clipboardWrite(),
            "runtime.clipboard_write",
            params,
            &output,
            applyClipboardWriteResponse,
        );
        if (output == null) return null;
        errdefer if (output.?.text) |text| self.allocator.free(text);
        const after = self.eventCursorSnapshot();
        // **`observer_generation` 은 보지 않는다.** 그 값은 출력 revision 이라(PTY 바이트마다 증가)
        // RPC 왕복 중 셸이 한 줄만 뱉어도 달라진다. 여기서 비교하면 가져온 결과를 거의 매번 버리는데,
        // host 는 이미 버퍼를 비운 뒤라 사용자의 복사가 사라진다(persistent-session-host.md 규율 3).
        // 확인해야 할 것은 "그 사이 seq 가 또 움직였나" 이고 그건 아래 seq 비교가 한다.
        if (after.clipboard_write_seq != prepared.sequence) {
            return error.ProtocolError;
        }
        if (!self.event_cursor.commit(prepared)) return error.ProtocolError;
        return output;
    }

    fn applyClipboardWriteResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *?ClipboardWrite = @ptrCast(@alignCast(raw_output));
        output.* = try runtime.decodeClipboardWriteResponse(bytes);
    }

    fn decodeClipboardWriteResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?ClipboardWrite {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const b64 = obj.string("b64") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const too_large = (obj.number("too_large") orelse 0) != 0;
        if (obj.hasUnknownKey(&.{ "b64", "too_large" })) {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (b64.len == 0) return .{ .text = null, .too_large = too_large };
        const dec = std.base64.standard.Decoder;
        const size = dec.calcSizeForSlice(b64) catch {
            self.poisonConnection(.peer_contract_violation); // capability를 광고한 host가 유효하지 않은 base64를 보냈다 = schema 드리프트
            return error.ProtocolError;
        };
        const out = self.allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer self.allocator.free(out);
        dec.decode(out, b64) catch {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        return .{ .text = out, .too_large = false };
    }

    /// 구 host 호환 경로. RemoteScreen이 조립한 현재 viewport에서만 추출한다.    /// 구 host 호환 경로. RemoteScreen이 조립한 현재 viewport에서만 추출한다. 구 screen wire에는 soft-wrap bit가 없어
    /// multi-row 선형 선택은 보이는 행 사이에 개행을 보존하는 degraded 정책이며, capability가 있는 최신 host에서는 반드시
    /// 위 RPC를 써 host SSOT를 유지한다.
    fn selectedTextFromProjection(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        return self.currentGeneration().attachment.screenPtr().?.extractVisibleSelection(self.allocator, self.io, span);
    }

    /// 원격 검색(§6c): 검색어로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서 `findMatches`(로컬과 같은 함수)로 매치를 찾게
    /// 하고, 보이는 매치의 뷰포트 span을 `out_spans`에 채운다(검색 의미론 host 단일 출처). 전체 매치 수를 돌려준다(뷰포트 밖 포함).
    /// `out_spans`는 먼저 비운다. 검색어는 임의 텍스트라 hex로 실어 escape를 피한다(상한 256 char).
    /// §6c 검색 결과. `count`=전체 매치 수, `cur`=현재 매치(cur_index)의 뷰포트 span(안 보이면 null). 보이는 **비현재** 매치는
    /// `out_spans`에 채운다(하이라이트용).
    /// `voff`=host가 이 span들을 계산한 기준 view_offset. client는 자기 화면(delta로 조립한 projection)의
    /// view_offset과 같을 때만 span을 그린다 — scroll=true 요청이 host 화면을 옮긴 직후의 응답은 client가 아직
    /// 그 스크롤 delta를 못 받은 화면과 좌표계가 어긋나기 때문이다. host가 이 필드를 안 보내면(앱보다 오래 사는
    /// 구 host 데몬) null이고, 그 연결에서는 종전대로 즉시 적용한다 — 새 필드가 없다는 사실 자체가 구 host의
    /// 유일한 신호라 별도 capability 비트를 두지 않는다(find 응답은 count/cur도 같은 관대한 파싱 규율이다).
    pub const FindResult = struct { count: usize, cur: ?terminal.SelectionSpan, voff: ?u64 };

    const FindDecodeOutput = struct {
        spans: *std.ArrayList(terminal.SelectionSpan),
        result: FindResult = .{ .count = 0, .cur = null, .voff = null },
    };

    pub fn find(self: *RemoteRuntime, query: []const u8, cur_index: u32, scroll: bool, out_spans: *std.ArrayList(terminal.SelectionSpan)) client_mod.ClientError!FindResult {
        try self.admitRuntimeOperation();
        if (scroll and !self.mutationAllowed()) return error.Unauthorized;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        var mutation_active = false;
        if (scroll) {
            try self.beginStableMutation(&mutation_lease);
            mutation_active = true;
        }
        defer if (mutation_active) self.finishStableMutation(&mutation_lease);
        out_spans.clearRetainingCapacity();
        var hexbuf: [512]u8 = undefined;
        const qn = @min(query.len, hexbuf.len / 2);
        const hex_chars = "0123456789abcdef";
        for (query[0..qn], 0..) |b, i| {
            hexbuf[i * 2] = hex_chars[b >> 4];
            hexbuf[i * 2 + 1] = hex_chars[b & 0xf];
        }
        var buf: [640]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"q\":\"{s}\",\"cur\":{d},\"scroll\":{}}}", .{ self.currentGeneration().attachment.streamId(), hexbuf[0 .. qn * 2], cur_index, scroll }) catch return error.OutOfMemory;
        const request = generation_contract.FindRequest.init(query[0..qn], cur_index, scroll) orelse
            return error.ProtocolError;
        var output: FindDecodeOutput = .{ .spans = out_spans };
        try self.callDecoded(
            generation_contract.RuntimeRequest.find(request),
            "runtime.find",
            params,
            &output,
            applyFindResponse,
        );
        return output.result;
    }

    fn applyFindResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *FindDecodeOutput = @ptrCast(@alignCast(raw_output));
        const count = client_mod.extractU64Field(bytes, "\"count\":") orelse 0;
        output.result = .{
            .count = @intCast(count),
            .cur = parseFirstSpan(bytes, "\"cur\":["),
            .voff = client_mod.extractU64Field(bytes, "\"voff\":"),
        };
        parseSpansInto(bytes, output.spans, runtime.allocator);
    }

    /// 단어/줄 선택(§6b-2): host가 콘텐츠를 아는 자기 core로 경계를 계산하게 하고(`selectWordAt`/`selectLineAt`) 결과 뷰포트
    /// 선택 span을 받는다(빈 placeholder는 경계를 모른다 = 선택 의미론 host 단일 출처). caller는 이 span을 placeholder에 적용해
    /// 하이라이트한다(복사는 #6b-1 selectedText가 그 span으로 host 추출). `op`는 고정 리터럴("word"/"line"). 선택 없으면 null.
    pub fn selectContentAware(self: *RemoteRuntime, op: []const u8, row: u16, col: u16, separators: []const u8) client_mod.ClientError!?terminal.SelectionSpan {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        if (separators.len > 64 or !std.unicode.utf8ValidateSlice(separators)) return error.ProtocolError;
        var separators_hex: [128]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (separators, 0..) |byte, index| {
            separators_hex[index * 2] = hex_chars[byte >> 4];
            separators_hex[index * 2 + 1] = hex_chars[byte & 0xf];
        }
        const separators_hex_len = separators.len * 2;
        var buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"op\":\"{s}\",\"row\":{d},\"col\":{d},\"separators_hex\":\"{s}\"}}", .{ self.currentGeneration().attachment.streamId(), op, row, col, separators_hex[0..separators_hex_len] }) catch return error.OutOfMemory;
        const kind: generation_contract.SelectKind = if (std.mem.eql(u8, op, "word"))
            .word
        else if (std.mem.eql(u8, op, "line"))
            .line
        else if (std.mem.eql(u8, op, "all"))
            .all
        else
            return error.ProtocolError;
        var request: generation_contract.SelectRequest = .{ .kind = kind, .row = row, .col = col };
        @memcpy(request.separators[0..separators.len], separators);
        request.separators_len = @intCast(separators.len);
        var output: SelectDecodeOutput = .{};
        try self.callDecoded(
            generation_contract.RuntimeRequest.selectOp(request),
            "runtime.select_op",
            params,
            &output,
            applySelectResponse,
        );
        // A successful all request is the semantic selection authority. The returned
        // viewport span is only a render projection and may be absent while the host
        // still owns a valid full-history selection (for example across a projection
        // refresh). Coupling these two made Cmd+A then Cmd+C lose the all intent.
        if (kind == .all) {
            self.selection_all = true;
            if (self.connectionCapabilities().runtime_selection_state)
                self.selection_host_authoritative = true;
        } else if (self.connectionCapabilities().runtime_selection_state and output.viewport != null) {
            self.selection_host_authoritative = true;
        }
        return output.viewport;
    }

    const SelectDecodeOutput = struct {
        viewport: ?terminal.SelectionSpan = null,
    };

    fn applySelectResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *SelectDecodeOutput = @ptrCast(@alignCast(raw_output));
        const Response = struct {
            sel: bool,
            sr: ?u16 = null,
            sc: ?u16 = null,
            er: ?u16 = null,
            ec: ?u16 = null,
            block: ?bool = null,
        };
        const parsed = std.json.parseFromSlice(Response, runtime.allocator, bytes, .{
            .ignore_unknown_fields = false,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer parsed.deinit();
        const response = parsed.value;
        if (!response.sel) {
            if (response.sr != null or response.sc != null or response.er != null or response.ec != null or response.block != null) {
                runtime.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return;
        }
        const sr = response.sr orelse {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const sc = response.sc orelse {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const er = response.er orelse {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const ec = response.ec orelse {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const block = response.block orelse {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        output.viewport = .{
            .start = .{ .row = sr, .col = sc },
            .end = .{ .row = er, .col = ec },
            .block = block,
        };
    }

    pub fn clearSelectAllIntent(self: *RemoteRuntime) void {
        self.selection_all = false;
    }

    pub fn supportsSelectionState(self: *const RemoteRuntime) bool {
        return self.connectionCapabilities().runtime_selection_state;
    }

    pub fn mirrorSelectionCommand(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        if (!self.connectionCapabilities().runtime_selection_state) return;
        switch (command) {
            .selection_start, .selection_extend, .selection_extend_or_collapse, .selection_scroll_and_extend => {
                try self.queueCoreCommand(command);
                self.selection_host_authoritative = true;
                self.selection_all = false;
            },
            .selection_clear => {
                try self.queueCoreCommand(command);
                self.selection_host_authoritative = false;
                self.selection_all = false;
            },
            else => return error.ProtocolError,
        }
    }

    /// host-authoritative core command를 strict bounded codec으로 보낸다. 구 host는 scroll 4종만 이해하므로 capability가
    /// 없는 연결에는 그 legacy subset만 보내고 focus/config/prompt는 unknown RPC를 시험하지 않고 degraded no-op으로 둔다.
    pub fn sendCoreCommandBlocking(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!shouldSendCoreCommand(
            self.connectionCapabilities().runtime_core_command,
            self.connectionSupportsClearScreen(),
            command,
        )) return;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        const params = core_command_wire.encodeParams(self.allocator, self.currentGeneration().attachment.streamId(), command) catch return error.OutOfMemory;
        defer self.allocator.free(params);
        var output: u8 = 0;
        try self.callDecoded(
            generation_contract.RuntimeRequest.coreCommand(runtime_pending_control.projectCoreCommand(command)),
            "runtime.core_command",
            params,
            &output,
            applyDiscardedResponse,
        );
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): 마우스 이벤트를 host로 보내 host core가 자기 mouse_tracking/format으로
    /// SGR 리포트를 인코딩·PTY 주입하게 한다. 인코딩 모드가 host에만 있어 client는 raw 이벤트만 전달한다(방식 B).
    pub fn sendMouseReport(self: *RemoteRuntime, m: maru.session.core_command.MouseReport) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        var buf: [192]u8 = undefined;
        const params = std.fmt.bufPrint(
            &buf,
            "{{\"stream_id\":{d},\"button\":{d},\"col\":{d},\"row\":{d},\"x_px\":{d},\"y_px\":{d},\"pressed\":{},\"motion\":{},\"mods\":{d}}}",
            .{ self.currentGeneration().attachment.streamId(), m.button, m.col, m.row, m.x_px, m.y_px, m.pressed, m.motion, m.mods },
        ) catch return error.OutOfMemory;
        var output: u8 = 0;
        try self.callDecoded(
            generation_contract.RuntimeRequest.reportMouse(.{
                .button = m.button,
                .col = m.col,
                .row = m.row,
                .x_px = m.x_px,
                .y_px = m.y_px,
                .pressed = m.pressed,
                .motion = m.motion,
                .mods = m.mods,
            }),
            "runtime.report_mouse",
            params,
            &output,
            applyDiscardedResponse,
        );
    }

    /// 실행 중 runtime의 daemon-owned notification snapshot을 현재 controller generation에 묶어 교체한다.
    /// capability가 없는 구 host에는 RPC를 보내지 않는다. 이 경우 daemon 내부 OS sink도 존재하지 않으므로 local
    /// 설정만 바꾸는 것이 호환 동작이다.
    /// `config.update` 는 controller_generation 을 CAS 처럼 실어 보낸다. 그 값은 attach 로 오르고
    /// attach rollback·controller revoke 로 **내려가므로**, RPC 왕복 중 어긋나 host 가
    /// `invalid_generation` 으로 거절하는 것은 손상이 아니라 **정상 경합**이다.
    ///
    /// 2026-08-30 실측: 재접속 복원에서 이 거절이 10 회 중 2 회 났고, 재시도가 없어서 그 탭의 attach 가
    /// 통째로 실패했다. 실패는 거기서 멈추지 않는다 — 복원이 불완전해지고, 종료 시 그 부분 상태가
    /// workspace checkpoint 를 덮어써 창·탭 배치를 잃는다. 경합 한 번에 세션 배치를 잃지 않도록
    /// 최신 generation 을 다시 읽어 유한 재시도한다. `callDecoded` 가 응답 처리 전에 버퍼된 이벤트를
    /// 배수하므로(`preDecodeBufferedEvents`) 재시도 시점의 로컬 값은 갱신돼 있다.
    pub fn updateNotificationConfig(
        self: *RemoteRuntime,
        config_generation: u64,
        notifications_osc: bool,
        display_label: []const u8,
    ) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.connectionCapabilities().notification_delivery) return;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const controller_generation = self.currentGeneration().attachment.statePtr().controller_generation;
            const update = generation_contract.NotificationConfigUpdateRequest.init(
                controller_generation,
                config_generation,
                notifications_osc,
                display_label,
            ) orelse return error.ProtocolError;
            var params_buffer: [768]u8 = undefined;
            var writer = std.Io.Writer.fixed(&params_buffer);
            var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
            json.write(.{
                .stream_id = self.currentGeneration().attachment.streamId(),
                .expected_controller_generation = controller_generation,
                .config_generation = config_generation,
                .notifications_osc = notifications_osc,
                .display_label = display_label,
            }) catch return error.OutOfMemory;
            var outcome: NotificationConfigOutcome = .{};
            try self.callDecoded(
                generation_contract.RuntimeRequest.notificationConfigUpdate(update),
                "config.update",
                writer.buffered(),
                &outcome,
                applyNotificationConfigUpdateResponse,
            );
            if (outcome.applied) return;
            if (!outcome.stale_generation or attempt + 1 >= max_config_update_attempts) {
                if (!builtin.is_test)
                    std.log.warn("cfgupd gave up rt={s} gen={d} attempts={d} stale={}", .{
                        self.runtime_id_hex[0..8],
                        controller_generation,
                        attempt + 1,
                        outcome.stale_generation,
                    });
                return error.ProtocolError;
            }
            if (!builtin.is_test)
                std.log.warn("cfgupd retry rt={s} gen={d} attempt={d}", .{
                    self.runtime_id_hex[0..8],
                    controller_generation,
                    attempt + 1,
                });
        }
    }

    /// `config.update` 의 generation 경합 재시도 상한. 경합은 attach rollback/revoke 와 겹칠 때만
    /// 나므로 한두 번이면 수렴한다. 무한 재시도는 host 가 진짜로 값을 못 맞추는 상황을 숨긴다.
    const max_config_update_attempts: u8 = 3;

    /// `config.update` 한 번의 결과. host 는 실패를 전부 typed error 로 답하므로 «적용 안 됨» 만으로는
    /// 재시도해도 되는 경합인지, 손 쓸 수 없는 거절인지 가릴 수 없다. 그 구분을 여기서 실어 올린다.
    const NotificationConfigOutcome = struct {
        applied: bool = false,
        /// `invalid_generation` — 보낸 `expected_controller_generation` 이 host 의 현재 값과 어긋났다.
        /// controller_generation 은 attach 로 오르고 rollback/revoke 로 내려가므로 RPC 왕복 중 어긋나는
        /// 것은 CAS 실패와 같은 **정상** 경합이다. 최신 값으로 다시 보내면 된다.
        stale_generation: bool = false,
    };

    fn applyNotificationConfigUpdateResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *NotificationConfigOutcome = @ptrCast(@alignCast(raw_output));
        const obj = decodeStrictObject(runtime.allocator, bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        // error envelope는 알려진 코드일 때만 "적용 안 됨"으로 접는다(모르는 코드 = schema 드리프트).
        // host는 이 RPC의 실패를 **전부** typed error로 답한다 — `{"applied":false}`를 보내는 경로가
        // server에 없다. 그래서 아래 success schema 검사에 걸리는 유일한 실제 응답이 error envelope이고,
        // 이걸 계약 위반으로 읽으면 controller_generation 경합(재접속·exec 업그레이드) 같은 **정상**
        // 거절이 connection poison으로, 다시 앱 abort(proof_loss)로 승격된다. 형제 디코더
        // (selected_text/link_at/clipboard_write/notification)와 같은 모양을 지킨다.
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                runtime.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            output.applied = false;
            output.stale_generation = std.mem.eql(u8, code, "invalid_generation");
            return;
        }
        if (obj.boolean("applied") != true or obj.hasUnknownKey(&.{"applied"})) {
            runtime.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        output.applied = true;
    }

    /// host에 대기 중인 OSC 9/777 데스크톱 알림을 뺀다(§6.32 — host가 core와 함께 알림을 소유·전달). 없으면 null. host-backed
    /// 터미널의 알림은 host의 `TerminalCore`가 파싱하므로 client가 이걸로 가져와 GUI 알림 funnel에 넣는다(app_session이 surfacing).
    /// 반환 title/body는 caller 소유(Notification.deinit로 회수). 둘 다 빈 값이면(host 대기 없음) null.
    pub fn takeNotification(self: *RemoteRuntime) client_mod.ClientError!?Notification {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        // Capability 없는 same-major 구 host는 runtime_id-only RPC를 exact subscription으로
        // authorize하지 못한다. Observer가 shared pending event를 소비하지 않도록 fail-closed한다.
        if (!self.connectionCapabilities().notification_stream_auth) return null;
        var mutation_lease: reconnect_mutation_seal.MutationLease = .{};
        try self.beginStableMutation(&mutation_lease);
        defer self.finishStableMutation(&mutation_lease);
        var buf: [96]u8 = undefined;
        const stable_delivery = self.connectionCapabilities().notification_delivery;
        const params = notificationParams(
            &buf,
            self.currentGeneration().attachment.streamId(),
            stable_delivery,
        ) catch return error.OutOfMemory;
        var output: ?Notification = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.notification(),
            "runtime.notification",
            params,
            &output,
            applyNotificationResponse,
        );
        return output;
    }

    fn applyNotificationResponse(runtime: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *?Notification = @ptrCast(@alignCast(raw_output));
        output.* = try runtime.decodeNotificationResponse(bytes);
    }

    fn applyDiscardedResponse(_: *RemoteRuntime, _: *anyopaque, _: []const u8) client_mod.ClientError!void {}

    fn notificationParams(
        buf: []u8,
        stream_id: u64,
        stable_delivery: bool,
    ) error{NoSpaceLeft}![]u8 {
        return if (stable_delivery)
            std.fmt.bufPrint(buf, "{{\"stream_id\":{d},\"delivery_version\":1}}", .{stream_id})
        else
            std.fmt.bufPrint(buf, "{{\"stream_id\":{d}}}", .{stream_id});
    }

    /// `runtime.notification`의 success envelope는 항상 문자열 `title`·`body` 두 필드다. 알림이 없어도 host가 둘을 빈
    /// 문자열로 보내므로 필드 누락을 "없음"으로 추측하지 않는다. 같은 major에서 필드 집합이나 타입이 달라지면 이후 RPC도
    /// 신뢰할 수 없어 connection을 fail-close한다.
    ///
    /// fail-close는 같은 host 연결을 공유하는 모든 runtime을 닫는다. 정상 경로가 여기로
    /// 오지 않기 때문이다(code-review max에서 제기됨): 이 RPC를 모르는 구 host는 **error 응답**을 보내고 위 error 분기가
    /// null로 접어 연결을 유지하며, 필드 집합이 다른 빌드에는 애초에 붙지 않는다(`validateExactClient`가 host_id·
    /// screen_codec_version·wire_major·build_id 일치를 요구한다 — host_connect.zig). 여기 도달 = 같은 빌드가 계약을
    /// 어겼다는 뜻이고, 그 연결로 이후 RPC를 계속 보내는 쪽이 더 위험하다.
    fn decodeNotificationResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?Notification {
        if (self.connectionCapabilities().notification_delivery)
            return self.decodeStableNotificationResponse(resp);
        // std.json.parseFromSlice 대신 **수동 디코드** — parseFromSlice가 숫자 파서(f128 소프트플로트 ___divtf3/___fixtfti
        // 등)를 링크로 끌어와, 이 경로가 live가 되면 ReleaseSafe 제품 빌드(macos-mermaid-perf)가 undefined symbol로
        // 깨진다(code-review 후속). 파싱은 selected_text/link_at과 **같은 strict 디코더**를 쓴다 — 응답 schema 위반을
        // RPC마다 다르게 다루지 않는다는 §"같은 major" 불변식을 알림 경로도 함께 지킨다.
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.poisonConnection(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const title_src = obj.string("title") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        const body_src = obj.string("body") orelse {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.hasUnknownKey(&.{ "title", "body" })) {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (title_src.len == 0 and body_src.len == 0) return null; // host에 대기 알림 없음(빈 {title,body}).
        const title = self.allocator.dupe(u8, title_src) catch return error.OutOfMemory;
        errdefer self.allocator.free(title);
        const body = self.allocator.dupe(u8, body_src) catch return error.OutOfMemory;
        return .{ .title = title, .body = body };
    }

    fn decodeStableNotificationResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?Notification {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const decoded = decodeStableNotificationPayload(arena.allocator(), resp) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return self.notificationProtocolFailure(),
        } orelse return null;
        const title = self.allocator.dupe(u8, decoded.title) catch return error.OutOfMemory;
        errdefer self.allocator.free(title);
        const body = self.allocator.dupe(u8, decoded.body) catch return error.OutOfMemory;
        errdefer self.allocator.free(body);
        const label = self.allocator.dupe(u8, decoded.display_label) catch return error.OutOfMemory;
        return .{
            .title = title,
            .body = body,
            .display_label = label,
            .route = .{
                .host_id = decoded.host_id,
                .runtime_id = decoded.runtime_id,
                .event_id = decoded.event_id,
                .occurred_at_ns = decoded.occurred_at_ns,
            },
        };
    }

    fn notificationProtocolFailure(self: *RemoteRuntime) client_mod.ClientError {
        self.poisonConnection(.peer_contract_violation);
        return error.ProtocolError;
    }

    const StableNotificationDecoded = struct {
        host_id: u128,
        runtime_id: u128,
        event_id: u64,
        occurred_at_ns: u64,
        title: []const u8,
        body: []const u8,
        display_label: []const u8,
    };

    const StableDecodeError = error{ OutOfMemory, InvalidJson };

    fn decodeStableNotificationPayload(allocator: std.mem.Allocator, resp: []const u8) StableDecodeError!?StableNotificationDecoded {
        var scanner = std.json.Scanner.initCompleteInput(allocator, resp);
        defer scanner.deinit();
        if ((try stableToken(&scanner, allocator, protocol.max_control_json)) != .object_begin)
            return error.InvalidJson;
        const root_key = stableString(try stableToken(&scanner, allocator, protocol.max_control_json)) orelse
            return error.InvalidJson;
        if (std.mem.eql(u8, root_key, "error")) {
            const code = stableString(try stableToken(&scanner, allocator, protocol.max_control_json)) orelse
                return error.InvalidJson;
            if (protocol.ErrorCode.fromWireName(code) == null or
                (try stableToken(&scanner, allocator, protocol.max_control_json)) != .object_end or
                (try stableToken(&scanner, allocator, protocol.max_control_json)) != .end_of_document)
                return error.InvalidJson;
            return null;
        }
        if (!std.mem.eql(u8, root_key, "event")) return error.InvalidJson;
        const event_start = try stableToken(&scanner, allocator, protocol.max_control_json);
        if (event_start == .null) {
            if ((try stableToken(&scanner, allocator, protocol.max_control_json)) != .object_end or
                (try stableToken(&scanner, allocator, protocol.max_control_json)) != .end_of_document)
                return error.InvalidJson;
            return null;
        }
        if (event_start != .object_begin) return error.InvalidJson;
        var hid: ?[]const u8 = null;
        var rid: ?[]const u8 = null;
        var eid: ?u64 = null;
        var occurred_at_ns: ?u64 = null;
        var title: ?[]const u8 = null;
        var body: ?[]const u8 = null;
        var display_label: ?[]const u8 = null;
        while (true) {
            const key_token = try stableToken(&scanner, allocator, protocol.max_control_json);
            if (key_token == .object_end) break;
            const key = stableString(key_token) orelse return error.InvalidJson;
            const value = try stableToken(&scanner, allocator, protocol.max_control_json);
            if (std.mem.eql(u8, key, "hid")) {
                if (hid != null) return error.InvalidJson;
                hid = stableString(value) orelse return error.InvalidJson;
            } else if (std.mem.eql(u8, key, "rid")) {
                if (rid != null) return error.InvalidJson;
                rid = stableString(value) orelse return error.InvalidJson;
            } else if (std.mem.eql(u8, key, "eid")) {
                if (eid != null) return error.InvalidJson;
                eid = try stableU64(value);
            } else if (std.mem.eql(u8, key, "occurred_at_ns")) {
                if (occurred_at_ns != null) return error.InvalidJson;
                occurred_at_ns = try stableU64(value);
            } else if (std.mem.eql(u8, key, "title")) {
                if (title != null) return error.InvalidJson;
                title = stableString(value) orelse return error.InvalidJson;
            } else if (std.mem.eql(u8, key, "body")) {
                if (body != null) return error.InvalidJson;
                body = stableString(value) orelse return error.InvalidJson;
            } else if (std.mem.eql(u8, key, "display_label")) {
                if (display_label != null) return error.InvalidJson;
                display_label = stableString(value) orelse return error.InvalidJson;
            } else return error.InvalidJson;
        }
        if ((try stableToken(&scanner, allocator, protocol.max_control_json)) != .object_end or
            (try stableToken(&scanner, allocator, protocol.max_control_json)) != .end_of_document)
            return error.InvalidJson;
        const host_id = parseStableHex128(hid orelse return error.InvalidJson) orelse return error.InvalidJson;
        const runtime_id = parseStableHex128(rid orelse return error.InvalidJson) orelse return error.InvalidJson;
        const event_id = eid orelse return error.InvalidJson;
        if (host_id == 0 or runtime_id == 0 or event_id == 0) return error.InvalidJson;
        return .{
            .host_id = host_id,
            .runtime_id = runtime_id,
            .event_id = event_id,
            .occurred_at_ns = occurred_at_ns orelse return error.InvalidJson,
            .title = title orelse return error.InvalidJson,
            .body = body orelse return error.InvalidJson,
            .display_label = display_label orelse return error.InvalidJson,
        };
    }

    fn stableToken(scanner: *std.json.Scanner, allocator: std.mem.Allocator, max_len: usize) StableDecodeError!std.json.Token {
        return scanner.nextAllocMax(allocator, .alloc_if_needed, max_len) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
    }

    fn stableString(token: std.json.Token) ?[]const u8 {
        return switch (token) {
            .string => |value| value,
            .allocated_string => |value| value,
            else => null,
        };
    }

    fn stableU64(token: std.json.Token) StableDecodeError!u64 {
        const value = switch (token) {
            .number => |bytes| bytes,
            .allocated_number => |bytes| bytes,
            else => return error.InvalidJson,
        };
        return std.fmt.parseInt(u64, value, 10) catch error.InvalidJson;
    }

    fn parseStableHex128(text: []const u8) ?u128 {
        if (text.len != 32) return null;
        return std.fmt.parseInt(u128, text, 16) catch null;
    }

    /// `key` 뒤 `[...]` 배열의 **첫 4정수**를 `SelectionSpan`으로 파싱한다(§6c-2 현재 매치 `"cur":[sr,sc,er,ec]`). 4개 미만
    /// (빈 배열=현재 매치 안 보임)이면 null. std.json 안 씀(f128 회피).
    fn parseFirstSpan(resp: []const u8, key: []const u8) ?terminal.SelectionSpan {
        const start = std.mem.indexOf(u8, resp, key) orelse return null;
        var i = start + key.len;
        var nums: [4]u16 = undefined;
        var ni: usize = 0;
        while (i < resp.len and resp[i] != ']' and ni < 4) {
            if (resp[i] < '0' or resp[i] > '9') {
                i += 1;
                continue;
            }
            var j = i;
            while (j < resp.len and resp[j] >= '0' and resp[j] <= '9') j += 1;
            nums[ni] = std.fmt.parseInt(u16, resp[i..j], 10) catch return null;
            i = j;
            ni += 1;
        }
        if (ni < 4) return null; // 빈/불완전 = 현재 매치 뷰포트 밖.
        return .{ .start = .{ .row = nums[0], .col = nums[1] }, .end = .{ .row = nums[2], .col = nums[3] }, .block = false };
    }

    /// `{...,"spans":[sr,sc,er,ec, sr,sc,er,ec, ...]}`의 flat 정수 배열을 4개씩 `SelectionSpan`으로 파싱해 `out`에 append한다
    /// (§6c 검색 매치 뷰포트 span). std.json.parseFromSlice 대신 수동 스캔(f128 회피, decodeStrictObject와 같은 이유).
    /// 잘못된 형식/append 실패는 best-effort로 멈춘다(검색은 부가 기능).
    fn parseSpansInto(resp: []const u8, out: *std.ArrayList(terminal.SelectionSpan), allocator: std.mem.Allocator) void {
        const key = "\"spans\":[";
        const start = std.mem.indexOf(u8, resp, key) orelse return;
        var i = start + key.len;
        var nums: [4]u16 = undefined;
        var ni: usize = 0;
        while (i < resp.len and resp[i] != ']') {
            if (resp[i] < '0' or resp[i] > '9') { // 구분자(`,` 공백) 스킵.
                i += 1;
                continue;
            }
            var j = i;
            while (j < resp.len and resp[j] >= '0' and resp[j] <= '9') j += 1;
            nums[ni] = std.fmt.parseInt(u16, resp[i..j], 10) catch break;
            i = j;
            ni += 1;
            if (ni == 4) {
                out.append(allocator, .{ .start = .{ .row = nums[0], .col = nums[1] }, .end = .{ .row = nums[2], .col = nums[3] }, .block = false }) catch return;
                ni = 0;
            }
        }
    }

    /// strict RPC 응답 객체 하나. 값은 string(escape 해제)·정수·bool만 담는다.
    /// 배열 값을 쓰는 응답(`runtime.find`의 span 목록)은 아직 전용 스캐너를 쓴다(§한계 — 확장하려면 여기 Value에 더한다).
    const StrictObject = struct {
        fields: []Field,
        allocator: std.mem.Allocator,

        const Value = union(enum) { string: []u8, number: u64, boolean: bool };
        const Field = struct { key: []u8, value: Value };

        fn deinit(self: StrictObject) void {
            for (self.fields) |f| {
                self.allocator.free(f.key);
                switch (f.value) {
                    .string => |v| self.allocator.free(v),
                    .number, .boolean => {},
                }
            }
            self.allocator.free(self.fields);
        }

        /// 키의 문자열 값(없거나 정수면 null). 소유권은 객체에 남는다 — caller가 쓰려면 dupe한다.
        fn string(self: StrictObject, key: []const u8) ?[]const u8 {
            for (self.fields) |f| {
                if (std.mem.eql(u8, f.key, key)) return switch (f.value) {
                    .string => |v| v,
                    .number, .boolean => null,
                };
            }
            return null;
        }

        /// 키의 정수 값(없거나 문자열이면 null).
        fn number(self: StrictObject, key: []const u8) ?u64 {
            for (self.fields) |f| {
                if (std.mem.eql(u8, f.key, key)) return switch (f.value) {
                    .number => |v| v,
                    .string, .boolean => null,
                };
            }
            return null;
        }

        fn boolean(self: StrictObject, key: []const u8) ?bool {
            for (self.fields) |f| {
                if (std.mem.eql(u8, f.key, key)) return switch (f.value) {
                    .boolean => |v| v,
                    .string, .number => null,
                };
            }
            return null;
        }

        /// 응답에 **선언하지 않은 키**가 섞였는가 — schema 드리프트 판정(호출자가 fail-close 근거로 쓴다).
        fn hasUnknownKey(self: StrictObject, allowed: []const []const u8) bool {
            outer: for (self.fields) |f| {
                for (allowed) |a| {
                    if (std.mem.eql(u8, f.key, a)) continue :outer;
                }
                return true;
            }
            return false;
        }
    };

    /// MRSH RPC 응답 객체의 **strict** 디코더 — 응답 문자열 파싱의 단일 출처다.
    ///
    /// 왜 strict인가: [영속 세션 호스트](../../../../docs/persistent-session-host.md) §"같은 major"는 "capability를 광고한
    /// host의 응답 schema가 어긋나면 구 host로 추측해 downgrade하지 않고 connection을 fail-close한다"를 불변식으로 둔다.
    /// 관대한 키 검색(부분 스캔)은 스키마 위반을 조용히 넘겨 이 불변식을 RPC마다 다르게 만들므로 응답 파싱에는 쓰지 않는다
    /// (선택 복사만 strict이고 나머지는 관대하던 옛 혼재가 실제로 `link_at` 응답을 오파싱하는 버그를 낳았다).
    /// 객체를 **끝까지 소비**하고(trailing garbage 거부), 중복 키·미종료 문자열·숫자 아닌 토큰을 모두 InvalidJson으로 본다.
    fn decodeStrictObject(allocator: std.mem.Allocator, json: []const u8) error{ OutOfMemory, InvalidJson }!StrictObject {
        var fields: std.ArrayListUnmanaged(StrictObject.Field) = .empty;
        errdefer {
            for (fields.items) |f| {
                allocator.free(f.key);
                switch (f.value) {
                    .string => |v| allocator.free(v),
                    .number, .boolean => {},
                }
            }
            fields.deinit(allocator);
        }
        var i: usize = 0;
        skipJsonWhitespace(json, &i);
        if (i >= json.len or json[i] != '{') return error.InvalidJson;
        i += 1;
        skipJsonWhitespace(json, &i);
        if (i < json.len and json[i] == '}') { // 빈 객체 `{}`도 유효한 응답이다(호출자가 의미를 정한다).
            i += 1;
            skipJsonWhitespace(json, &i);
            if (i != json.len) return error.InvalidJson;
            return .{ .fields = fields.toOwnedSlice(allocator) catch return error.OutOfMemory, .allocator = allocator };
        }
        while (true) {
            skipJsonWhitespace(json, &i);
            const key = try decodeStrictJsonStringAt(allocator, json, &i);
            var key_owned = true;
            errdefer if (key_owned) allocator.free(key);
            for (fields.items) |f| {
                if (std.mem.eql(u8, f.key, key)) return error.InvalidJson; // 중복 키 = 손상.
            }
            skipJsonWhitespace(json, &i);
            if (i >= json.len or json[i] != ':') return error.InvalidJson;
            i += 1;
            skipJsonWhitespace(json, &i);
            if (i >= json.len) return error.InvalidJson;
            const value: StrictObject.Value = if (json[i] == '"')
                .{ .string = try decodeStrictJsonStringAt(allocator, json, &i) }
            else if (std.mem.startsWith(u8, json[i..], "true")) blk: {
                i += 4;
                break :blk .{ .boolean = true };
            } else if (std.mem.startsWith(u8, json[i..], "false")) blk: {
                i += 5;
                break :blk .{ .boolean = false };
            } else .{ .number = try decodeStrictJsonNumberAt(json, &i) };
            fields.append(allocator, .{ .key = key, .value = value }) catch {
                switch (value) {
                    .string => |v| allocator.free(v),
                    .number, .boolean => {},
                }
                return error.OutOfMemory;
            };
            key_owned = false; // 목록이 소유 — 위 errdefer가 이중 free하지 않게.
            skipJsonWhitespace(json, &i);
            if (i >= json.len) return error.InvalidJson;
            if (json[i] == ',') {
                i += 1;
                continue;
            }
            if (json[i] == '}') {
                i += 1;
                break;
            }
            return error.InvalidJson;
        }
        skipJsonWhitespace(json, &i);
        if (i != json.len) return error.InvalidJson; // trailing garbage = 손상.
        return .{ .fields = fields.toOwnedSlice(allocator) catch return error.OutOfMemory, .allocator = allocator };
    }

    /// 응답 정수 필드(비음수). 소수점·지수·부호는 응답 schema에 없으므로 손상으로 본다(strict).
    fn decodeStrictJsonNumberAt(json: []const u8, i: *usize) error{InvalidJson}!u64 {
        const start = i.*;
        while (i.* < json.len and std.ascii.isDigit(json[i.*])) i.* += 1;
        if (i.* == start) return error.InvalidJson;
        return std.fmt.parseInt(u64, json[start..i.*], 10) catch error.InvalidJson;
    }

    fn skipJsonWhitespace(json: []const u8, i: *usize) void {
        while (i.* < json.len and switch (json[i.*]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) i.* += 1;
    }

    fn decodeStrictJsonStringAt(
        allocator: std.mem.Allocator,
        json: []const u8,
        i: *usize,
    ) error{ OutOfMemory, InvalidJson }![]u8 {
        if (i.* >= json.len or json[i.*] != '"') return error.InvalidJson;
        i.* += 1;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        while (i.* < json.len) {
            const ch = json[i.*];
            i.* += 1;
            if (ch == '"') {
                const owned = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
                if (!std.unicode.utf8ValidateSlice(owned)) {
                    allocator.free(owned);
                    return error.InvalidJson;
                }
                return owned;
            }
            if (ch < 0x20) return error.InvalidJson;
            if (ch != '\\') {
                out.append(allocator, ch) catch return error.OutOfMemory;
                continue;
            }
            if (i.* >= json.len) return error.InvalidJson;
            const escaped = json[i.*];
            i.* += 1;
            switch (escaped) {
                '"' => out.append(allocator, '"') catch return error.OutOfMemory,
                '\\' => out.append(allocator, '\\') catch return error.OutOfMemory,
                '/' => out.append(allocator, '/') catch return error.OutOfMemory,
                'n' => out.append(allocator, '\n') catch return error.OutOfMemory,
                'r' => out.append(allocator, '\r') catch return error.OutOfMemory,
                't' => out.append(allocator, '\t') catch return error.OutOfMemory,
                'b' => out.append(allocator, 0x08) catch return error.OutOfMemory,
                'f' => out.append(allocator, 0x0c) catch return error.OutOfMemory,
                'u' => {
                    if (i.* + 4 > json.len) return error.InvalidJson;
                    const cp = std.fmt.parseInt(u21, json[i.* .. i.* + 4], 16) catch return error.InvalidJson;
                    if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidJson;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidJson;
                    out.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
                    i.* += 4;
                },
                else => return error.InvalidJson,
            }
        }
        return error.InvalidJson;
    }

    fn terminateBestEffort(self: *RemoteRuntime) void {
        // CR4 forward recovery has already retired the only live attachment before publishing the
        // unavailable shell. There is no stream/controller authority left from which a terminate
        // RPC can be issued; local owner teardown must proceed without dereferencing the terminal
        // attachment or attempting to restore the old graph.
        if (self.currentAttachmentTerminal()) return;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return;
        // terminate는 runtime 자체를 파괴하므로 input/control blocking flush OOM에서 retained mutation을 의미상 대체하는
        // 유일한 ordering 예외다. 재시도 owner를 남기지 않고 queue를 폐기한 뒤 terminate를 시도한다.
        self.flushQueuedInputBlocking() catch |err| {
            if (err == error.OutOfMemory) {
                self.discardQueuedMutations();
            } else {
                self.failCloseTeardownFlush(err);
                return;
            }
        };
        var output: u8 = 0;
        self.callDecodedAfterFlush(
            generation_contract.RuntimeRequest.terminate(),
            "runtime.terminate",
            params,
            &output,
            applyDiscardedResponse,
        ) catch |err| {
            // cleanup request를 만들거나 응답을 추적할 메모리조차 없으면 shared connection을 닫아 host EOF 경로가
            // 모든 attachment/controller lease를 회수하게 한다.
            if (err == error.OutOfMemory) self.poisonConnection(.local_resource_exhausted);
            return;
        };
    }

    /// detach가 끝내 실패하면 host에 controller lease가 남는다. 그 결과는 조용하지 않다 — 다음 attach가
    /// `controller_busy`가 되어 **화면은 그려지는데 키 입력만 안 먹는** 상태가 되고, 사용자에게는 "터미널이
    /// 멈췄다"로 보인다. 지금까지 이 실패는 어디에도 남지 않아 원인을 추적할 수 없었으므로 한 줄 남긴다.
    /// GUI stdout/stderr는 `/dev/null`이라(Dock 실행) 터미널에서 앱을 직접 띄울 때만 보인다.
    fn logDetachIncomplete(stage: []const u8, err: anyerror) void {
        if (builtin.is_test) return;
        std.log.err(
            "remote runtime detach incomplete: stage={s} error={s} — controller lease may linger (next attach can be controller_busy)",
            .{ stage, @errorName(err) },
        );
    }

    fn detachBestEffort(self: *RemoteRuntime) void {
        if (self.currentAttachmentTerminal()) return;
        if (self.currentGeneration().attachment.streamId() == 0) return;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.currentGeneration().attachment.streamId()}) catch return;
        // detach는 retained mutation을 추월하지 않는다. flush 실패에서 detach RPC는 0이고, 아직 live일 수 있는
        // local OOM/Busy는 connection EOF로 모든 controller lease를 회수하도록 fail-close한다.
        self.flushQueuedInputBlocking() catch |err| {
            self.failCloseTeardownFlush(err);
            logDetachIncomplete("flush", err);
            return;
        };
        var output: u8 = 0;
        self.callDecodedAfterFlush(
            generation_contract.RuntimeRequest.detach(),
            "runtime.detach",
            params,
            &output,
            applyDiscardedResponse,
        ) catch |err| {
            if (err == error.OutOfMemory) {
                self.poisonConnection(.local_resource_exhausted);
            } else if (err == error.AdminBusy) {
                // The latch may appear after the preflight turn. No teardown retry owner remains,
                // so preserve revoke-before-wire ordering by converging through host EOF cleanup.
                self.poisonConnection(.attachment_cleanup_failed);
            }
            logDetachIncomplete("detach", err);
            return;
        };
    }

    fn failCloseTeardownFlush(self: *RemoteRuntime, err: client_mod.ClientError) void {
        if (err == error.ConnectionClosed) return;
        self.poisonConnection(if (err == error.OutOfMemory)
            .local_resource_exhausted
        else
            .attachment_cleanup_failed);
    }
};

fn decodeResizeReply(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected_sequence: u64,
) RemoteRuntime.ResizeError!control_response_wire.ResizeReply {
    return control_response_wire.decodeResizeResponse(
        allocator,
        payload,
        .{ .resize = .{ .client_sequence = expected_sequence } },
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RuntimeNotFound => error.RuntimeNotFound,
        error.ResourceExhausted => error.ResourceExhausted,
        error.Rejected => error.ResizeRejected,
        error.Malformed => error.ProtocolError,
    };
}

fn decodeResyncReply(
    client: ?*client_mod.Client,
    allocator: std.mem.Allocator,
    payload: []const u8,
) client_mod.ClientError!void {
    control_response_wire.decodeResyncEnvelope(allocator, payload) catch |err| {
        if (err != error.OutOfMemory) if (client) |value| value.poison(.peer_contract_violation);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProtocolError,
        };
    };
}

fn shouldSendCoreCommand(runtime_core_command_v1: bool, runtime_clear_screen_v1: bool, command: core_command_wire.Command) bool {
    if (command == .clear_screen) return runtime_core_command_v1 and runtime_clear_screen_v1;
    return runtime_core_command_v1 or command.isLegacyScroll();
}

pub const testing_api = if (builtin.is_test) struct {
    pub const SemanticFixture = B4SemanticFixture;

    pub fn initSemanticRuntimeOnAdapter(
        runtime: *RemoteRuntime,
        adapter: *host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        runtime_id_hex: [32]u8,
        surface_id: u64,
    ) !void {
        try runtime.initializeGenerationOwner(
            .{ .generation = adapter },
            allocator,
            std.testing.io,
            .{ .cols = 1, .rows = 1 },
        );
        errdefer runtime.deinitGenerationOwnerAndScreenSource();
        runtime.pending_event_owner = .{};
        runtime.runtime_lifetime = .{};
        try runtime.initializePendingEventOwner();
        runtime.allocator = allocator;
        runtime.io = std.testing.io;
        runtime.runtime_id_hex = runtime_id_hex;
        runtime.currentGeneration().resize_seq = 0;
        runtime.currentGeneration().resize_generation = 0;
        runtime.currentGeneration().resize_baseline_present = false;
        runtime.direct_input = .empty;
        runtime.input_batches = .{};
        runtime.direct_input_offset = 0;
        runtime.pending_controls = .empty;
        runtime.blocking_flush_active = false;
        runtime.currentGeneration().pump_ended = false;
        runtime.currentGeneration().resync_needed = false;
        runtime.currentGeneration().observation = .{};
        runtime.close_authority = .{};
        runtime.shutdown_attempt_authority = .{};
        runtime.shutdown_current_admin = .{};
        try runtime.attachAndAssemble(surface_id, .{ .cols = 1, .rows = 1 });
    }

    pub fn deinitSemanticRuntimeOnAdapter(runtime: *RemoteRuntime) void {
        runtime.surface.deinit();
        runtime.deinitGenerationOwnerAndScreenSource();
        runtime.direct_input.deinit(runtime.allocator);
        runtime.input_batches.deinit(runtime.allocator);
        runtime.pending_controls.deinit(runtime.allocator);
    }

    pub fn serveSemanticAttachPeers(fd: c.fd_t, count: usize) void {
        defer _ = c.close(fd);
        const allocator = std.heap.page_allocator;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const request = readPeerFrame(fd, allocator) catch return;
            defer allocator.free(request.payload);
            const stream_id: u64 = @intCast(index + 7);
            const response_json = std.fmt.allocPrint(
                allocator,
                "{{\"result\":{{\"stream_id\":{d},\"controller_generation\":3," ++
                    "\"granted\":{{\"observe\":true,\"input\":true,\"resize\":true}}," ++
                    "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}}}",
                .{stream_id},
            ) catch return;
            defer allocator.free(response_json);
            const response = framing.encodeFrame(
                allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                response_json,
            ) catch return;
            defer allocator.free(response);
            var records: std.ArrayListUnmanaged(u8) = .empty;
            defer records.deinit(allocator);
            const meta = screen_stream.encodeScreenMeta(
                allocator,
                .{ .kind = .screen_meta, .generation = 1 },
                .{ .cols = 1, .rows = 1, .cursor = .{} },
            ) catch return;
            defer allocator.free(meta);
            screen_stream.appendRecord(&records, allocator, meta) catch return;
            var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
            const row = screen_stream.encodeRow(
                allocator,
                .{ .kind = .row, .generation = 1 },
                .{ .row_index = 0, .runs = &runs },
            ) catch return;
            defer allocator.free(row);
            screen_stream.appendRecord(&records, allocator, row) catch return;
            const snapshot = framing.encodeFrame(
                allocator,
                .{ .kind = .snapshot_chunk, .stream_id = stream_id, .flags = protocol.Flags.end_stream },
                records.items,
            ) catch return;
            defer allocator.free(snapshot);
            socket_server.writeAll(fd, response) catch return;
            socket_server.writeAll(fd, snapshot) catch return;
        }
    }

    pub fn setHostRetirementBusy(runtime: *RemoteRuntime, busy: bool) void {
        const attachment = &runtime.currentGeneration().attachment.generation;
        if (attachment.lifecycle != .attached)
            @panic("host retirement busy seam requires an attached generation");
        attachment.catchup_stage_owner.state = if (busy) .building else .idle;
    }

    pub fn setHostRetirementLifecycleRaw(runtime: *RemoteRuntime, raw: u8) u8 {
        const attachment = &runtime.currentGeneration().attachment.generation;
        const lifecycle_raw = @as(*u8, @ptrCast(&attachment.lifecycle));
        const previous = lifecycle_raw.*;
        lifecycle_raw.* = raw;
        return previous;
    }

    pub fn setHostRetirementPayloadReleaseStateRaw(runtime: *RemoteRuntime, raw: u8) u8 {
        const attachment = &runtime.currentGeneration().attachment.generation;
        const payload = &(attachment.payload orelse
            @panic("host retirement payload seam requires an attached payload"));
        const state_raw = @as(*u8, @ptrCast(&payload.state.failed_release_state));
        const previous = state_raw.*;
        state_raw.* = raw;
        return previous;
    }

    pub fn hostRetirementPristine(runtime: *RemoteRuntime) bool {
        const attachment = &runtime.currentGeneration().attachment.generation;
        const source = runtime.screen_source;
        return attachment.lifecycle == .attached and
            attachment.retirement_transaction_addr == 0 and
            attachment.retirement_transaction_generation == 0 and
            attachment.retirement_adapter_addr == 0 and
            source.current.kind == .live and
            !source.writer_pending.load(.acquire) and
            source.prepared_transaction_addr == 0 and
            source.prepared_transaction_generation == 0 and
            source.prepared_expected_generation == 0 and
            source.prepared_next_generation == 0;
    }

    pub fn armOrderedReconnectReclaimTrace() void {
        Cr3c2OrderedReclaimTestState.arm();
    }

    pub fn disarmOrderedReconnectReclaimTrace() void {
        Cr3c2OrderedReclaimTestState.disarm();
    }

    pub fn orderedReconnectReclaimTrace() [2]u8 {
        if (Cr3c2OrderedReclaimTestState.len != 2)
            @panic("ordered reconnect reclaim trace is incomplete");
        return .{
            @intFromEnum(Cr3c2OrderedReclaimTestState.stages[0]) + 1,
            @intFromEnum(Cr3c2OrderedReclaimTestState.stages[1]) + 1,
        };
    }

    pub fn hasBoundReconnectAdmission(runtime: *RemoteRuntime) bool {
        return runtime.reconnect_executor.admission != null and
            runtime.reconnect_executor.resident_budget_addr != 0 and
            runtime.reconnect_executor.resident_lease.active;
    }

    pub fn releaseBoundReconnectAdmission(
        runtime: *RemoteRuntime,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) !void {
        try runtime.reconnect_executor.validate(&runtime.generation_owner);
        if (runtime.reconnect_executor.resident_budget_addr != @intFromPtr(budget))
            return error.InvalidAuthority;
        try budget.release(
            &runtime.reconnect_executor.resident_lease,
            runtime.reconnect_executor.resident_lease.role,
        );
        runtime.reconnect_executor.resident_budget_addr = 0;
        runtime.reconnect_executor.admission = null;
        runtime.reconnect_executor.admission_seal = [_]u8{0} ** 32;
    }

    pub fn armDirectReleaseWait(
        runtime: *RemoteRuntime,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
        admission: reconnect_admission_owner.Projection,
        runtime_id: [16]u8,
        deadline_ns: u64,
    ) !void {
        try runtime.reconnect_executor.bindAdmission(
            &runtime.generation_owner,
            budget,
            admission,
            reconnect_resident_budget.max_entry_bytes,
        );
        const work: reconnect_reducer.Work = .{
            .job_generation = admission.incident_id.sequence,
            .shell_generation = try runtime.generation_owner.currentGeneration(),
            .attempt = 1,
            .candidate_connection_generation = admission.connection_generation + 1,
            .deadline_ns = deadline_ns,
        };
        const args = ReconnectGenerationTestArgs{
            .allocator = runtime.allocator,
            .stream_id = 0xE3C2,
        };
        _ = try runtime.reconnect_executor.apply(
            &runtime.generation_owner,
            .{ .begin_prepare = work },
            args,
            initReconnectTestGeneration,
        );
        inline for (.{
            reconnect_reducer.Event.observer_staged,
            reconnect_reducer.Event.begin_mutation_seal,
            reconnect_reducer.Event.seal_clean,
            reconnect_reducer.Event.begin_authority_commit,
            reconnect_reducer.Event.authority_conflict,
            reconnect_reducer.Event{ .begin_retry_wait_release = .{ .work = work, .runtime_id = runtime_id } },
        }) |event| _ = try runtime.reconnect_executor.apply(
            &runtime.generation_owner,
            event,
            args,
            initReconnectTestGeneration,
        );
    }

    pub fn resetDirectReleaseFixture(runtime: *RemoteRuntime) void {
        if (!std.meta.eql(runtime.reconnect_executor.prepared, PreparedReconnect{}))
            runtime.generation_owner.abort(&runtime.reconnect_executor.prepared) catch
                @panic("test reconnect candidate abort failed");
        runtime.reconnect_executor.state = reconnect_reducer.State.initial(
            runtime.reconnect_executor.admission.?.incident_id.sequence,
            runtime.generation_owner.currentGeneration() catch @panic("test generation authority lost"),
        );
    }

    pub fn directReleaseProjection(runtime: *RemoteRuntime) !DirectReleaseProjection {
        return RemoteRuntime.backend_api.directReleaseProjection(runtime);
    }

    pub const DirectReleaseSnapshot = struct {
        state: reconnect_reducer.State,
        prepared: PreparedReconnect,
        admission: reconnect_admission_owner.Projection,
        admission_seal: process_seal_service.CleanupSeal,
        resident_budget_addr: usize,
        resident_lease: reconnect_resident_budget.Lease,
    };

    pub fn directReleaseSnapshot(runtime: *RemoteRuntime) !DirectReleaseSnapshot {
        try runtime.reconnect_executor.validate(&runtime.generation_owner);
        return .{
            .state = runtime.reconnect_executor.state.?,
            .prepared = runtime.reconnect_executor.prepared,
            .admission = runtime.reconnect_executor.admission orelse return error.InvalidAuthority,
            .admission_seal = runtime.reconnect_executor.admission_seal,
            .resident_budget_addr = runtime.reconnect_executor.resident_budget_addr,
            .resident_lease = runtime.reconnect_executor.resident_lease,
        };
    }

    pub const CloseCase = enum {
        preserve_old,
        preserve_old_with_paused_notice,
        publish_new,
        freeze_with_retry,
        finish_terminal,
    };

    pub const CloseSnapshot = struct {
        state: reconnect_reducer.State,
        prepared: PreparedReconnect,
        admission: ?reconnect_admission_owner.Projection,
        admission_seal: process_seal_service.CleanupSeal,
        resident_budget_addr: usize,
        resident_lease: reconnect_resident_budget.Lease,
        current_generation: u64,
        has_retiring: bool,
    };

    pub fn armCloseCase(
        runtime: *RemoteRuntime,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
        admission: reconnect_admission_owner.Projection,
        case: CloseCase,
    ) !void {
        try runtime.reconnect_executor.bindAdmission(
            &runtime.generation_owner,
            budget,
            admission,
            reconnect_resident_budget.max_entry_bytes,
        );
        const work: reconnect_reducer.Work = .{
            .job_generation = admission.incident_id.sequence,
            .shell_generation = try runtime.generation_owner.currentGeneration(),
            .attempt = 1,
            .candidate_connection_generation = admission.connection_generation + 1,
            .deadline_ns = std.math.maxInt(u64),
        };
        const args = ReconnectGenerationTestArgs{
            .allocator = runtime.allocator,
            .stream_id = 0xE3C3,
        };
        _ = try runtime.reconnect_executor.apply(
            &runtime.generation_owner,
            .{ .begin_prepare = work },
            args,
            initReconnectTestGeneration,
        );
        switch (case) {
            .preserve_old => {},
            .preserve_old_with_paused_notice => {
                inline for (.{
                    reconnect_reducer.Event.observer_staged,
                    reconnect_reducer.Event.begin_mutation_seal,
                    reconnect_reducer.Event.seal_ambiguous,
                }) |event| _ = try runtime.reconnect_executor.apply(
                    &runtime.generation_owner,
                    event,
                    args,
                    initReconnectTestGeneration,
                );
            },
            .publish_new, .freeze_with_retry, .finish_terminal => {
                inline for (.{
                    reconnect_reducer.Event.observer_staged,
                    reconnect_reducer.Event.begin_mutation_seal,
                    reconnect_reducer.Event.seal_clean,
                    reconnect_reducer.Event.begin_authority_commit,
                }) |event| _ = try runtime.reconnect_executor.apply(
                    &runtime.generation_owner,
                    event,
                    args,
                    initReconnectTestGeneration,
                );
                _ = try runtime.reconnect_executor.apply(
                    &runtime.generation_owner,
                    switch (case) {
                        .publish_new => .controller_evidenced,
                        .freeze_with_retry => .authority_conflict,
                        .finish_terminal => .gone_positive,
                        else => unreachable,
                    },
                    args,
                    initReconnectTestGeneration,
                );
            },
        }
    }

    pub fn closeTransitionProjection(
        runtime: *RemoteRuntime,
        event: CloseEvent,
    ) !CloseTransitionProjection {
        return RemoteRuntime.backend_api.closeTransitionProjection(runtime, event);
    }

    pub fn closeSnapshot(runtime: *RemoteRuntime) !CloseSnapshot {
        try runtime.reconnect_executor.validate(&runtime.generation_owner);
        return .{
            .state = runtime.reconnect_executor.state.?,
            .prepared = runtime.reconnect_executor.prepared,
            .admission = runtime.reconnect_executor.admission,
            .admission_seal = runtime.reconnect_executor.admission_seal,
            .resident_budget_addr = runtime.reconnect_executor.resident_budget_addr,
            .resident_lease = runtime.reconnect_executor.resident_lease,
            .current_generation = try runtime.generation_owner.currentGeneration(),
            .has_retiring = try runtime.generation_owner.slot.hasRetiring(),
        };
    }

    pub fn projectCloseState(state: reconnect_reducer.State) CloseStateProjection {
        return closeStateProjection(state);
    }

    pub fn expectedCloseDecision(case: CloseCase) u8 {
        return @intFromEnum(switch (case) {
            .preserve_old => reconnect_reducer.Decision.close_preserve_old,
            .preserve_old_with_paused_notice => .close_preserve_old_with_paused_notice,
            .publish_new => .close_publish_new,
            .freeze_with_retry => .close_freeze_with_retry,
            .finish_terminal => .close_finish_terminal,
        });
    }

    pub fn cleanupCloseFixture(
        runtime: *RemoteRuntime,
        budget: *reconnect_resident_budget.ReconnectAdmissionBudget,
    ) void {
        if (!std.meta.eql(runtime.reconnect_executor.prepared, PreparedReconnect{}))
            runtime.generation_owner.abort(&runtime.reconnect_executor.prepared) catch
                @panic("test reconnect candidate abort failed");
        if (runtime.generation_owner.slot.hasRetiring() catch
            @panic("test reconnect retiring query failed"))
            runtime.generation_owner.reclaimRetiring() catch
                @panic("test reconnect retiring cleanup failed");
        if (runtime.reconnect_executor.resident_budget_addr != 0) {
            budget.release(
                &runtime.reconnect_executor.resident_lease,
                runtime.reconnect_executor.resident_lease.role,
            ) catch @panic("test reconnect budget cleanup failed");
        }
        runtime.reconnect_executor.resident_budget_addr = 0;
        runtime.reconnect_executor.admission = null;
        runtime.reconnect_executor.admission_seal = [_]u8{0} ** 32;
        runtime.reconnect_executor.state = reconnect_reducer.State.initial(
            1,
            runtime.generation_owner.currentGeneration() catch
                @panic("test reconnect current generation lost"),
        );
    }

    pub const AppQuitOwnerSnapshot = struct {
        pending_idle: bool,
        owner_pristine: bool,
        correlation_pristine: bool,
        event_generation_mirror: u64,
        blocker_count: usize,
        pin_count: usize,
        quarantine_occupied: usize,
        quarantine_retained_bytes: usize,
    };

    pub fn appQuitOwnerSnapshot(runtime: *RemoteRuntime) !AppQuitOwnerSnapshot {
        const adapter = runtime.generationConnection() orelse return error.InvalidOwner;
        const attachment = switch (runtime.currentGeneration().attachment) {
            .generation => |*value| value,
            .legacy => return error.InvalidOwner,
        };
        const source = try generation_attachment_mod.testing_api.eventReleaseSourceSnapshot(adapter);
        const settlement = generation_attachment_mod.testing_api.settlementSourceSnapshot(attachment);
        return .{
            .pending_idle = runtime.pending_event_owner.lifecycle_raw ==
                @intFromEnum(pending_event_owner_mod.PendingLifecycle.idle),
            .owner_pristine = settlement.owner_pristine,
            .correlation_pristine = settlement.correlation_pristine,
            .event_generation_mirror = settlement.event_generation_mirror,
            .blocker_count = source.blocker_count,
            .pin_count = source.pin_count,
            .quarantine_occupied = source.quarantine_occupied,
            .quarantine_retained_bytes = source.quarantine_retained_bytes,
        };
    }

    pub fn appQuitSourceZero(adapter: *host_adapter_mod.HostAdapter) bool {
        const source = generation_attachment_mod.testing_api.eventReleaseSourceSnapshot(adapter) catch return false;
        return source.blocker_count == 0 and source.pin_count == 0 and
            source.quarantine_occupied == 0 and source.quarantine_retained_bytes == 0;
    }

    var detached_test_client: client_mod.Client = undefined;

    fn initializeTestGeneration(
        runtime: *RemoteRuntime,
        allocator: std.mem.Allocator,
        connection: RuntimeConnection,
    ) !void {
        // 대부분의 legacy fixture는 `RemoteRuntime = undefined`에서 필요한 owner만 순서대로
        // 조립한다. 제품 constructor와 마찬가지로 mutation owner도 먼저 pristine으로 만들어
        // 이후 input epoch가 정해진 첫 mutation에서 final-address 초기화할 수 있게 한다.
        runtime.mutation_owner = .{};
        runtime.generation_owner = .{};
        try runtime.generation_owner.slot.initInPlace(
            allocator,
            2,
            InitialRemoteGenerationArgs{
                .allocator = allocator,
                .connection = connection,
            },
            initInitialRemoteGeneration,
        );
    }

    pub fn initializeDetachedGeneration(runtime: *RemoteRuntime, allocator: std.mem.Allocator) !void {
        try initializeTestGeneration(runtime, allocator, .{ .legacy = &detached_test_client });
    }

    pub fn initializeGenerationForConnection(
        runtime: *RemoteRuntime,
        connection: RuntimeConnection,
    ) !void {
        const allocator = switch (connection) {
            .legacy => |client| client.allocator,
            .generation => |adapter| host_adapter_mod.HostAdapter.testing.rawClient(adapter).allocator,
        };
        try initializeTestGeneration(runtime, allocator, connection);
    }

    pub fn initializeLegacyConnection(runtime: *RemoteRuntime, client: *client_mod.Client) void {
        initializeTestGeneration(runtime, client.allocator, .{ .legacy = client }) catch
            @panic("test runtime generation initialization failed");
    }

    pub fn generationAdapter(runtime: *RemoteRuntime) ?*host_adapter_mod.HostAdapter {
        return runtime.generationConnection();
    }

    pub fn generation(runtime: *RemoteRuntime) *RemoteGeneration {
        return runtime.currentGeneration();
    }

    /// 테스트 fixture도 제품 constructor와 같은 process identity와 final-address owner 경로를 사용한다.
    pub fn initializePendingOwners(runtime: *RemoteRuntime) !void {
        runtime.pending_event_owner = .{};
        runtime.runtime_lifetime = .{};
        try runtime.initializePendingEventOwner();
    }

    pub fn armSettlementContention(count: usize) void {
        runtime_lifetime_owner_mod.testing.armSettlementContention(count);
    }

    /// 실제 Runtime의 generation stream에 event를 넣어 close pump가 소비할 prepared owner를 만든다.
    pub fn preparePendingEventForClose(runtime: *RemoteRuntime, payload: []const u8) !void {
        const adapter = runtime.generationConnection() orelse return error.InvalidOwner;
        try host_adapter_mod.HostAdapter.testing.rawClient(adapter).bufferGenerationEventForTest(runtime.currentGeneration().attachment.streamId(), payload);
        switch (try runtime.currentGeneration().attachment.generation.takeEvent()) {
            .taken => {},
            else => return error.TestUnexpectedResult,
        }
        _ = try runtime.classifyAndPrepareEvent();
    }

    pub fn armSemanticProofLoss(stage_raw: u8) void {
        const stage = std.enums.fromInt(B4SemanticProofLossStage, stage_raw) orelse
            @panic("알 수 없는 b4 semantic proof-loss stage");
        if (stage == .none or B4SemanticProofLossTestState.stage != .none)
            @panic("b4 semantic proof-loss stage가 이미 활성 상태다");
        B4SemanticProofLossTestState.stage = stage;
    }
} else struct {};

test "2c4 RuntimeConnection은 legacy와 generation arm을 정확히 구분한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var legacy_client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0x2C40,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(1).?,
    };
    defer legacy_client.parser.deinit();
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &legacy_client);
    defer adapter.deinit();

    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeTestGeneration(
        &runtime,
        testing.allocator,
        .{ .legacy = &legacy_client },
    );
    runtime.currentGeneration().connection = .{ .legacy = &legacy_client };
    try testing.expect(runtime.generationConnection() == null);
    try testing.expect(runtime.legacyConnectionOrNull().? == &legacy_client);

    runtime.currentGeneration().connection = .{ .generation = &adapter };
    try testing.expect(runtime.generationConnection().? == &adapter);
    try testing.expect(runtime.legacyConnectionOrNull() == null);
}

test "2c4 generation arm은 pointer-free capability projection만 반환한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0x2C41,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(1).?,
        .runtime_core_command_v1 = true,
        .runtime_selected_text_v1 = true,
    };
    defer client.parser.deinit();
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
    defer adapter.deinit();
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeTestGeneration(
        &runtime,
        testing.allocator,
        .{ .generation = &adapter },
    );
    runtime.currentGeneration().connection = .{ .generation = &adapter };

    const capabilities = runtime.connectionCapabilities();
    try testing.expect(capabilities.runtime_core_command);
    try testing.expect(capabilities.runtime_selected_text);
    try testing.expectEqual(client.wire_major, capabilities.wire_major);
}

test "f3c0 remote runtime resize reply preserves stale size and uses host-clamped applied size" {
    try std.testing.expectEqual(
        control_response_wire.ResizeReply.stale,
        try decodeResizeReply(std.testing.allocator, "{\"result\":{\"stale\":true}}", 7),
    );
    try std.testing.expectEqual(
        @as(u16, 2),
        (try decodeResizeReply(
            std.testing.allocator,
            "{\"result\":{\"cols\":2,\"rows\":1,\"client_sequence\":7,\"resize_generation\":3,\"changed\":true}}",
            7,
        )).applied.cols,
    );
    try std.testing.expectError(
        error.ResourceExhausted,
        decodeResizeReply(std.testing.allocator, "{\"error\":\"resource_exhausted\"}", 7),
    );
    try std.testing.expectError(
        error.ProtocolError,
        decodeResizeReply(std.testing.allocator, "{\"result\":{\"cols\":1,\"rows\":1,\"client_sequence\":7,\"resize_generation\":3,\"changed\":true}}", 7),
    );
    try std.testing.expectError(
        error.ProtocolError,
        decodeResizeReply(
            std.testing.allocator,
            "{\"result\":{\"cols\":2,\"rows\":1,\"client_sequence\":8,\"resize_generation\":3,\"changed\":true}}",
            7,
        ),
    );
}

test "f3c0 remote runtime resync maps valid malformed error and OOM without drift" {
    var valid_client = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer valid_client.deinit();
    try decodeResyncReply(
        &valid_client,
        std.testing.allocator,
        "{\"result\":{\"resync\":true}}",
    );
    try std.testing.expect(!valid_client.unusable);

    inline for (.{
        "{\"result\":{\"resync\":false}}",
        "{\"error\":\"invalid_request\"}",
    }) |payload| {
        var rejected = client_mod.Client{
            .allocator = std.testing.allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(std.testing.allocator),
        };
        defer rejected.deinit();
        try std.testing.expectError(
            error.ProtocolError,
            decodeResyncReply(&rejected, std.testing.allocator, payload),
        );
        try std.testing.expect(rejected.unusable);
    }

    const Runner = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var client = client_mod.Client{
                .allocator = std.testing.allocator,
                .fd = -1,
                .host_id = 1,
                .parser = framing.FrameParser.init(std.testing.allocator),
            };
            defer client.deinit();
            decodeResyncReply(
                &client,
                allocator,
                "{\"result\":{\"resync\":true}}",
            ) catch |err| {
                if (err != error.OutOfMemory) return err;
                try std.testing.expect(!client.unusable);
                return err;
            };
            try std.testing.expect(!client.unusable);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Runner.run,
        .{},
    );
}

test "remote runtime fails the shared connection on an immediately consumed foreign resize" {
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var foreign = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = try allocator.dupe(
            u8,
            \\{"event":"runtime.resized","data":{"runtime_id":"000000000000000000000000000000bb","cols":140,"rows":50,"resize_generation":10,"reason":"controller"}}
            ,
        ),
    };
    foreign.header.payload_len = @intCast(foreign.payload.len);
    try client.pending_events.append(allocator, foreign);
    client.pending_event_bytes = foreign.payload.len;

    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
    runtime.currentGeneration().event_generation_tracking = .tracked;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.currentGeneration().resize_generation = 0;
    runtime.currentGeneration().resize_baseline_present = false;
    runtime.currentGeneration().observation = .{};
    defer runtime.currentGeneration().observation.deinit(allocator);
    try std.testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try std.testing.expect(client.unusable);
    try std.testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
}

test "remote runtime: extended core commands require capability while legacy scroll remains compatible" {
    try std.testing.expect(shouldSendCoreCommand(false, false, .{ .scroll = 1 }));
    try std.testing.expect(!shouldSendCoreCommand(false, false, .{ .report_focus = true }));
    try std.testing.expect(!shouldSendCoreCommand(false, false, .{ .set_max_scrollback = 1000 }));
    try std.testing.expect(shouldSendCoreCommand(true, false, .{ .report_focus = false }));
    try std.testing.expect(!shouldSendCoreCommand(true, false, .clear_screen));
    try std.testing.expect(shouldSendCoreCommand(true, true, .clear_screen));
}

test "CR3a-2c3c C2 projects every product core command into the closed generation control" {
    const commands = [_]core_command_wire.Command{
        .{ .scroll = -1 },
        .scroll_to_bottom,
        .{ .scroll_to_abs = 2 },
        .{ .scroll_to_offset = 3 },
        .{ .report_focus = true },
        .{ .set_cell_metrics = .{ .width = 4, .height = 5 } },
        .{ .set_default_colors = .{ .foreground = 6, .background = 7 } },
        .{ .set_config_palette = .{null} ** 16 },
        .{ .set_max_scrollback = 8 },
        .{ .set_ambiguous_wide = true },
        .{ .set_emoji_wide = false },
        .{ .set_default_cursor_shape = 2 },
        .{ .set_runtime_config = .{
            .max_scrollback = 9,
            .ambiguous_wide = true,
            .emoji_wide = false,
            .palette = .{null} ** 16,
            .default_colors = .{ .foreground = 10, .background = 11 },
            .cell_metrics = .{ .width = 12, .height = 13 },
            .cursor_shape = 1,
        } },
        .{ .jump_to_prompt = -1 },
        .clear_screen,
        .reset_input_modes,
        .{ .selection_start = .{ .row = 1, .col = 2, .block = true } },
        .{ .selection_extend = .{ .row = 3, .col = 4 } },
        .{ .selection_extend_or_collapse = .{ .row = 5, .col = 6 } },
        .{ .selection_scroll_and_extend = .{ .row = 0, .col = 7, .delta = 1 } },
        .selection_clear,
    };
    const expected = [_]generation_contract.CoreCommandRequest{
        .{ .scroll = -1 },
        .scroll_to_bottom,
        .{ .scroll_to_abs = 2 },
        .{ .scroll_to_offset = 3 },
        .{ .report_focus = true },
        .{ .set_cell_metrics = .{ .width = 4, .height = 5 } },
        .{ .set_default_colors = .{ .foreground = 6, .background = 7 } },
        .{ .set_config_palette = .{null} ** 16 },
        .{ .set_max_scrollback = 8 },
        .{ .set_ambiguous_wide = true },
        .{ .set_emoji_wide = false },
        .{ .set_default_cursor_shape = 2 },
        .{ .set_runtime_config = .{
            .max_scrollback = 9,
            .ambiguous_wide = true,
            .emoji_wide = false,
            .palette = .{null} ** 16,
            .foreground = 10,
            .background = 11,
            .cell_width = 12,
            .cell_height = 13,
            .cursor_shape = 1,
        } },
        .{ .jump_to_prompt = -1 },
        .clear_screen,
        .reset_input_modes,
        .{ .selection_start = .{ .row = 1, .col = 2, .block = true } },
        .{ .selection_extend = .{ .row = 3, .col = 4 } },
        .{ .selection_extend_or_collapse = .{ .row = 5, .col = 6 } },
        .{ .selection_scroll_and_extend = .{ .row = 0, .col = 7, .delta = 1 } },
        .selection_clear,
    };
    try testing.expectEqual(
        @as(usize, @typeInfo(core_command_wire.Command).@"union".fields.len),
        commands.len,
    );
    try testing.expectEqual(
        commands.len,
        @typeInfo(generation_contract.CoreCommandRequest).@"union".fields.len,
    );
    for (commands, expected) |command, oracle| {
        const projected = runtime_pending_control.projectCoreCommand(command);
        try testing.expect(std.meta.eql(oracle, projected));
        const decoded = generation_contract.RuntimeControl.coreCommand(projected).decode() orelse
            return error.TestExpectedEqual;
        try testing.expect(std.meta.eql(
            oracle,
            switch (decoded) {
                .core_command => |value| value,
                .scroll_to_bottom => return error.TestExpectedEqual,
                .observation_probe => return error.TestExpectedEqual,
            },
        ));
    }
    const without_metrics = runtime_pending_control.projectCoreCommand(.{
        .set_runtime_config = .{
            .max_scrollback = 14,
            .ambiguous_wide = false,
            .emoji_wide = true,
            .palette = .{null} ** 16,
            .default_colors = .{ .foreground = 15, .background = 16 },
            .cell_metrics = null,
            .cursor_shape = 2,
        },
    });
    try testing.expect(std.meta.eql(
        generation_contract.CoreCommandRequest{ .set_runtime_config = .{
            .max_scrollback = 14,
            .ambiguous_wide = false,
            .emoji_wide = true,
            .palette = .{null} ** 16,
            .foreground = 15,
            .background = 16,
            .cell_width = 0,
            .cell_height = 0,
            .cursor_shape = 2,
        } },
        without_metrics,
    ));
}

test "CR3a-2c3c C2 normalizes only unsupported and retryable generation control outcomes" {
    try testing.expect(try RemoteRuntime.normalizeGenerationControlError(error.Unsupported));
    try testing.expect(!(try RemoteRuntime.normalizeGenerationControlError(error.Busy)));
    try testing.expect(!(try RemoteRuntime.normalizeGenerationControlError(error.ResourceExhausted)));
    try testing.expectError(
        error.ProtocolError,
        RemoteRuntime.normalizeGenerationControlError(error.InvalidOwner),
    );
    try testing.expectError(
        error.ProtocolError,
        RemoteRuntime.normalizeGenerationControlError(error.ProtocolError),
    );
    try testing.expectError(
        error.Unauthorized,
        RemoteRuntime.normalizeGenerationControlError(error.Unauthorized),
    );
    try testing.expectError(
        error.ConnectionClosed,
        RemoteRuntime.normalizeGenerationControlError(error.ConnectionClosed),
    );
}

test "CR3a-2c3c C3 preserves blocking generation control error semantics" {
    try RemoteRuntime.normalizeGenerationBlockingControlError(error.Unsupported);
    try testing.expectError(
        error.OutOfMemory,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.ResourceExhausted),
    );
    try testing.expectError(
        error.AdminBusy,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.Busy),
    );
    try testing.expectError(
        error.ProtocolError,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.InvalidOwner),
    );
    try testing.expectError(
        error.ProtocolError,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.ProtocolError),
    );
    try testing.expectError(
        error.Unauthorized,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.Unauthorized),
    );
    try testing.expectError(
        error.ConnectionClosed,
        RemoteRuntime.normalizeGenerationBlockingControlError(error.ConnectionClosed),
    );
}

test "remote runtime: new spawn config fails closed against a legacy daemon that would ignore the field" {
    var client = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_core_command_v1 = false,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try std.testing.expectError(error.UnsupportedSpawnContract, rr.spawnWithConfig(
        &client,
        std.testing.allocator,
        std.testing.io,
        1,
        .{ .command = "/bin/cat" },
        .{ .cols = 80, .rows = 24 },
        .{
            .max_scrollback = 1000,
            .ambiguous_wide = false,
            .emoji_wide = true,
            .palette = .{null} ** 16,
            .default_colors = .{
                .foreground = .{ .r = 0xD0, .g = 0xD0, .b = 0xD0 },
                .background = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
            },
            .cell_metrics = null,
        },
    ));
}

test "remote runtime: advertised selected-text capability with a missing response field fails the connection closed" {
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_selected_text_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var rr: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&rr, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&rr, &adapter);

    try std.testing.expectError(
        error.ProtocolError,
        rr.decodeSelectedTextResponse("{\"error\":{\"code\":\"invalid_request\"}}"),
    );
    try std.testing.expectError(error.ConnectionClosed, client.call("host.info", null));
}

// OSC 52 데이터는 임의 바이트다. JSON 문자열로 그대로 보내면 strict 디코더의 UTF-8 검증에 걸려 connection이
// fail-close되므로(복사 한 번에 앱 전역 연결이 끊긴다) base64로 나른다. 그 왕복과 too_large 신호를 고정한다.
test "remote runtime: clipboardWrite는 base64로 임의 바이트를 복원하고 too_large를 전한다" {
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_clipboard_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;

    // 0xFF 같은 non-UTF-8 바이트도 그대로 복원된다(예전 구현은 여기서 연결을 죽였다).
    {
        const raw = [_]u8{ 0xFF, 0x00, 'h', 'i', 0xFE };
        var b64: [16]u8 = undefined;
        const enc = std.base64.standard.Encoder.encode(&b64, &raw);
        const body = try std.fmt.allocPrint(allocator, "{{\"b64\":\"{s}\",\"too_large\":0}}", .{enc});
        defer allocator.free(body);
        const got = (try rr.decodeClipboardWriteResponse(body)).?;
        defer if (got.text) |t| allocator.free(t);
        try std.testing.expectEqualSlices(u8, &raw, got.text.?);
        try std.testing.expect(!got.too_large);
    }
    // 대기 없음 → text null.
    {
        const got = (try rr.decodeClipboardWriteResponse("{\"b64\":\"\",\"too_large\":0}")).?;
        try std.testing.expect(got.text == null);
        try std.testing.expect(!got.too_large);
    }
    // 너무 커서 못 실은 경우 → text 없이 too_large(사용자에게 안내해야 하는 상태).
    {
        const got = (try rr.decodeClipboardWriteResponse("{\"b64\":\"\",\"too_large\":1}")).?;
        try std.testing.expect(got.text == null);
        try std.testing.expect(got.too_large);
    }
    // 선언 밖 키·깨진 base64는 schema 드리프트로 fail-close 한다.
    try std.testing.expectError(error.ProtocolError, rr.decodeClipboardWriteResponse("{\"b64\":\"\",\"too_large\":0,\"extra\":\"x\"}"));
    try std.testing.expectError(error.ProtocolError, rr.decodeClipboardWriteResponse("{\"b64\":\"!!!!\",\"too_large\":0}"));
}

test "remote runtime: config.update의 typed error는 poison 없이 «적용 안 됨»으로 접힌다" {
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;

    // host는 이 RPC의 실패를 전부 typed error로 답한다(`{"applied":false}` 경로가 server에 없다).
    // 예전 디코더는 error envelope에 `applied`가 없다는 이유로 계약 위반으로 읽어 connection을
    // poison했고, attachment가 전환 중이면 그 poison이 앱 abort(proof_loss)까지 승격됐다.
    // 재접속·exec 업그레이드 중의 generation 경합은 **정상** 거절이므로 연결을 죽이지 않는다.
    // invalid_generation 만 재시도 가능한 경합으로 표시된다 — 나머지 typed error 는 접히되 재시도하지 않는다.
    for ([_]struct { body: []const u8, stale: bool }{
        .{ .body = "{\"error\":\"invalid_generation\"}", .stale = true },
        .{ .body = "{\"error\":\"unauthorized\"}", .stale = false },
        .{ .body = "{\"error\":\"runtime_not_found\"}", .stale = false },
    }) |case| {
        var outcome: RemoteRuntime.NotificationConfigOutcome = .{ .applied = true };
        try rr.applyNotificationConfigUpdateResponse(@ptrCast(&outcome), case.body);
        try std.testing.expect(!outcome.applied);
        try std.testing.expectEqual(case.stale, outcome.stale_generation);
        try std.testing.expect(client.first_poison_reason == null);
    }

    // 성공 schema는 그대로 적용된다.
    var outcome: RemoteRuntime.NotificationConfigOutcome = .{};
    try rr.applyNotificationConfigUpdateResponse(@ptrCast(&outcome), "{\"applied\":true}");
    try std.testing.expect(outcome.applied);
    try std.testing.expect(!outcome.stale_generation);
    try std.testing.expect(client.first_poison_reason == null);
}

test "remote runtime: config.update의 schema 드리프트는 여전히 연결을 닫는다" {
    const allocator = std.testing.allocator;
    // 모르는 error 코드와 선언 밖 키는 «같은 major» 불변식 위반이라 fail-close를 유지한다.
    for ([_][]const u8{
        "{\"error\":\"no_such_code\"}",
        "{\"error\":\"unauthorized\",\"extra\":1}",
        "{\"applied\":false}",
        "{\"applied\":true,\"extra\":1}",
        "{}",
    }) |body| {
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
        rr.pending_event_owner = .{};
        rr.runtime_lifetime = .{};
        try rr.initializePendingEventOwner();
        rr.allocator = allocator;

        var outcome: RemoteRuntime.NotificationConfigOutcome = .{};
        try std.testing.expectError(
            error.ProtocolError,
            rr.applyNotificationConfigUpdateResponse(@ptrCast(&outcome), body),
        );
        try std.testing.expect(client.first_poison_reason != null);
    }
}

test "remote runtime: 응답 객체 디코더는 strict다(escape·미종료·trailing·중복 키 거부)" {
    const allocator = std.testing.allocator;
    // 문자열 escape 해제 + 정수 필드가 한 객체에서 함께 파싱된다(selected_text와 link_at이 같은 파서를 쓴다).
    {
        const obj = try RemoteRuntime.decodeStrictObject(allocator, "{\"text\":\"e\\u000a\",\"kind\":1}");
        defer obj.deinit();
        try std.testing.expectEqualStrings("e\n", obj.string("text").?);
        try std.testing.expectEqual(@as(u64, 1), obj.number("kind").?);
        try std.testing.expect(obj.string("kind") == null); // 타입이 다르면 null(문자열로 읽히지 않는다)
        try std.testing.expect(!obj.hasUnknownKey(&.{ "text", "kind" }));
        try std.testing.expect(obj.hasUnknownKey(&.{"text"})); // 선언 밖 키 탐지
    }
    // typed error envelope는 그대로 유효하다(호출자가 알려진 코드인지 확인해 접는다).
    {
        const obj = try RemoteRuntime.decodeStrictObject(allocator, "{\"error\":\"invalid_request\"}");
        defer obj.deinit();
        try std.testing.expect(protocol.ErrorCode.fromWireName(obj.string("error").?) != null);
    }
    // 손상은 전부 InvalidJson — 호출자가 fail-close 한다(문서 §"같은 major": schema 어긋나면 downgrade 추측 금지).
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"text\":\"unterminated}"));
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"text\":\"bad\\q\"}"));
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"text\":\"ok\"} trailing"));
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"text\":\"a\",\"text\":\"b\"}"));
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"kind\":-1}")); // 음수는 응답 schema에 없다
    try std.testing.expectError(error.InvalidJson, RemoteRuntime.decodeStrictObject(allocator, "{\"a\":{\"b\":1}}")); // 중첩은 미지원(§한계)
}

/// `{argv:[...], cols, rows}` spawn params를 JSON으로 만든다(caller free). argv는 임의 바이트라 실 JSON encoder로 escape한다
/// (client hand-built JSON의 신뢰 계약 밖 — client.zig 주석대로 임의 argv는 stringify로).
fn buildSpawnParams(
    allocator: std.mem.Allocator,
    request: maru.pty.SpawnRequest,
    size: terminal.Size,
    initial_config: ?maru.session.core_command.RuntimeConfig,
    notification: ?NotificationBootstrap,
) error{OutOfMemory}![]u8 {
    const argv = allocator.alloc([]const u8, 1 + request.args.len) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = request.command;
    for (request.args, 0..) |arg, i| argv[i + 1] = arg;
    var pane_id_buf: [16]u8 = undefined;
    const pane_id: ?[]const u8 = if (request.pane_id) |id|
        std.fmt.bufPrint(&pane_id_buf, "{x:0>16}", .{id}) catch return error.OutOfMemory
    else
        null;
    var inherited: std.ArrayListUnmanaged([]const u8) = .empty;
    defer inherited.deinit(allocator);
    if (request.env.len == 0 and request.parent_env == null) {
        const environ = std.c.environ;
        var index: usize = 0;
        while (environ[index]) |entry| : (index += 1) {
            inherited.append(allocator, std.mem.span(entry)) catch return error.OutOfMemory;
        }
    }
    // env=[]의 "호출자 부모 상속" 의미를 오래 살아 있는 daemon 환경으로 바꾸지 않는다. GUI가 본 raw parent
    // snapshot을 별도 필드로 보내고, host의 단일 EnvStorage가 TERM/ZDOTDIR/config override를 그대로 적용한다.
    const parent_env: []const []const u8 = if (request.env.len != 0)
        &.{}
    else if (request.parent_env) |snapshot|
        snapshot
    else
        inherited.items;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(.{
        .argv = argv,
        .cwd = request.cwd,
        .login = request.login,
        .env = request.env,
        .parent_env = parent_env,
        .env_overrides = request.env_overrides,
        .term = request.term,
        // **왼쪽은 wire tag, 오른쪽은 Zig 필드다.** 이 익명 구조체의 필드 이름이 그대로 JSON 키가 되므로
        // `.zdotdir`은 손대지 않는다(영속 호스트라 새 앱이 옛 호스트와 대화한다 — docs/windows-platform.md §4.2).
        .zdotdir = if (request.shell_integration) |si| si.assetsDir() else null,
        .ssh_integration_bin = request.ssh_integration_bin,
        .pane_id = pane_id,
        .cols = size.cols,
        .rows = size.rows,
        .runtime_config = if (initial_config) |config| coreConfigToSpawnWire(config) else null,
        .notification_config = notification,
    }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

const RuntimeConfigSpawnWire = struct {
    lines: u64,
    ambiguous_wide: bool,
    emoji_wide: bool,
    palette: core_command_wire.Command.Palette,
    foreground: u32,
    background: u32,
    cell_width: u32,
    cell_height: u32,
    /// config `cursor.shape`(0=block/1=underline/2=bar). spawn 시점에 실어 보내야 child의 **첫 출력 전**에 host core
    /// 기본 모양이 정해진다(set_runtime_config만 쓰면 첫 프롬프트가 block으로 한 프레임 스치는 race).
    cursor_shape: u8,
};

fn coreConfigToSpawnWire(config: maru.session.core_command.RuntimeConfig) RuntimeConfigSpawnWire {
    var palette: core_command_wire.Command.Palette = .{null} ** 16;
    for (config.palette, 0..) |maybe_rgb, index| {
        palette[index] = if (maybe_rgb) |rgb|
            (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b
        else
            null;
    }
    return .{
        .lines = @intCast(config.max_scrollback),
        .ambiguous_wide = config.ambiguous_wide,
        .emoji_wide = config.emoji_wide,
        .palette = palette,
        .foreground = (@as(u32, config.default_colors.foreground.r) << 16) |
            (@as(u32, config.default_colors.foreground.g) << 8) |
            config.default_colors.foreground.b,
        .background = (@as(u32, config.default_colors.background.r) << 16) |
            (@as(u32, config.default_colors.background.g) << 8) |
            config.default_colors.background.b,
        .cell_width = if (config.cell_metrics) |metrics| metrics.width else 0,
        .cell_height = if (config.cell_metrics) |metrics| metrics.height else 0,
        .cursor_shape = @intFromEnum(config.default_cursor_shape),
    };
}

test "remote runtime: spawn wire preserves extended SpawnRequest fields" {
    const allocator = std.testing.allocator;
    const request: maru.pty.SpawnRequest = .{
        .command = "/bin/zsh",
        .args = &.{ "-l", "-c", "pwd" },
        .cwd = "/tmp/maru cwd",
        .login = true,
        .env = &.{ "BASE=one", "UNICODE=한글" },
        .parent_env = &.{"SHOULD=NOT_BE_SENT"},
        .env_overrides = &.{ "BASE=two", "MARU_FLAG=yes" },
        .term = "xterm-maru",
        // 중립 필드는 `shell_integration_dir`로 바뀌었지만 **wire 키는 `"zdotdir"` 그대로**여야 한다 —
        // 아래 단언이 그 JSON 키를 직접 확인해 그 사실을 못 박는다(docs/windows-platform.md §4.2).
        .shell_integration = .{ .assets_dir = "/tmp/maru-zdotdir" },
        .ssh_integration_bin = "/Applications/Maru.app/Contents/MacOS/maru",
        .pane_id = 0x1234,
    };
    var palette: [16]?terminal.Rgb = .{null} ** 16;
    palette[0] = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const json = try buildSpawnParams(allocator, request, .{ .cols = 132, .rows = 43 }, .{
        .max_scrollback = 4321,
        .ambiguous_wide = true,
        .emoji_wide = false,
        .palette = palette,
        .default_colors = .{
            .foreground = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
            .background = .{ .r = 0x01, .g = 0x02, .b = 0x03 },
        },
        .cell_metrics = .{ .width = 9, .height = 18 },
    }, null);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"argv\":[\"/bin/zsh\",\"-l\",\"-c\",\"pwd\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cwd\":\"/tmp/maru cwd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"login\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env\":[\"BASE=one\",\"UNICODE=한글\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parent_env\":[]") != null); // explicit env가 우선한다.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env_overrides\":[\"BASE=two\",\"MARU_FLAG=yes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"term\":\"xterm-maru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"zdotdir\":\"/tmp/maru-zdotdir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_integration_bin\":\"/Applications/Maru.app/Contents/MacOS/maru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pane_id\":\"0000000000001234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cols\":132") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rows\":43") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"runtime_config\":{\"lines\":4321") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"foreground\":11189196") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cell_width\":9,\"cell_height\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_scrollback\"") == null); // host decoder와 다른 내부 필드명 누출 금지.
}

fn seedMetadataTestObservation(
    observation: *term_backend.RuntimeObservation,
    allocator: std.mem.Allocator,
) !void {
    var process: maru.pty.types.ForegroundProcessName = .{
        .pid = 55,
        .len = "claude".len,
    };
    @memcpy(process.bytes[0.."claude".len], "claude");
    try observation.replace(allocator, .{
        .availability = .current,
        .revision = 2,
        .observer_generation = 9,
        .title_generation = 4,
        .size = .{ .cols = 120, .rows = 40 },
        .cwd = "/safe",
        .window_title = "work",
        .ssh_remote_dest = "safe-host",
        .semantic_state = .command,
        .alt_active = true,
        .app_cursor_keys = true,
        .foreground_available = true,
        .foreground_pgid = 55,
        .foreground_processes = &.{process},
    });
}

fn expectGuiMetadataProjectionFailurePreservesCache(
    payload: []const u8,
    support: runtime_metadata_wire.MetadataSupport,
    expected: enum { malformed_drop, fail_closed },
) !void {
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = @import("framing.zig").FrameParser.init(allocator),
        .metadata_support = .supported,
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.currentGeneration().attachment.deinit();
    rr.currentGeneration().observation = .{};
    defer rr.currentGeneration().observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.currentGeneration().observation, allocator);
    client.metadata_support = support;
    const event_wire = try framing.encodeFrame(
        allocator,
        .{
            .major = protocol.version_major,
            .kind = .event,
            .stream_id = 7,
        },
        payload,
    );
    defer allocator.free(event_wire);
    const response_wire = try framing.encodeFrame(
        allocator,
        .{
            .major = protocol.version_major,
            .kind = .response,
            .request_id = client.next_request_id,
        },
        "{\"result\":{}}",
    );
    defer allocator.free(response_wire);
    const request_wire = try framing.encodeFrame(
        allocator,
        .{
            .major = protocol.version_major,
            .kind = .request,
            .request_id = client.next_request_id,
        },
        "{\"method\":\"host.info\",\"params\":{}}",
    );
    defer allocator.free(request_wire);
    try socket_server.writeAll(fds[1], event_wire);
    try socket_server.writeAll(fds[1], response_wire);

    switch (expected) {
        .malformed_drop => {
            const response = try client.call("host.info", "{}");
            defer allocator.free(response);
            try std.testing.expectEqualStrings("{\"result\":{}}", response);
            try std.testing.expect(!client.unusable);
            try std.testing.expect(client.fd >= 0);
        },
        .fail_closed => {
            try std.testing.expectError(error.ProtocolError, client.call("host.info", "{}"));
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
        },
    }
    try std.testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.pending_event_bytes);
    try std.testing.expectEqual(@as(u64, 2), rr.currentGeneration().observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.currentGeneration().observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.currentGeneration().observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.currentGeneration().observation.ssh_remote_dest.items);
    try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.currentGeneration().observation.semantic_state);
    try std.testing.expect(rr.currentGeneration().observation.alt_active);
    try std.testing.expect(rr.currentGeneration().observation.app_cursor_keys);
    try std.testing.expectEqual(@as(u16, 120), rr.currentGeneration().observation.size.cols);
    try std.testing.expectEqual(@as(u16, 40), rr.currentGeneration().observation.size.rows);
    try std.testing.expectEqual(@as(?i32, 55), rr.currentGeneration().observation.foreground_pgid);
    try std.testing.expectEqual(@as(usize, 1), rr.currentGeneration().observation.foreground_processes.items.len);
    try std.testing.expectEqualStrings(
        "claude",
        rr.currentGeneration().observation.foreground_processes.items[0].slice(),
    );
    if (expected == .fail_closed) {
        // stream close는 client가 peer 방향 kernel send buffer에 이미 넣은 request를 폐기하지 않는다. 그
        // request를 정확히 전부 읽은 뒤에야 EOF가 보여야 하므로, 첫 read==0을 요구하면 올바른 fail-close도
        // 실패로 오판한다. 반대 방향 response는 Client parser가 소유하다가 connection teardown에서 버린다.
        var drained: [256]u8 = undefined;
        var drained_len: usize = 0;
        while (true) {
            const n = c.read(
                fds[1],
                drained[drained_len..].ptr,
                drained.len - drained_len,
            );
            try std.testing.expect(n >= 0);
            if (n == 0) break;
            drained_len += @intCast(n);
            try std.testing.expect(drained_len <= drained.len);
        }
        try std.testing.expectEqualSlices(u8, request_wire, drained[0..drained_len]);
    }
}

test "remote runtime: GUI metadata ingress drops malformed and fail-closes resource or capability" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var processes: std.Io.Writer.Allocating = .init(allocator);
    defer processes.deinit();
    for (0..runtime_metadata_wire.max_process_entries + 1) |index| {
        if (index != 0) try processes.writer.writeByte(',');
        try processes.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    const attack = try std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"runtime.metadata\",\"metadata_revision\":3,\"metadata\":{{\"cwd\":\"/attacker\",\"window_title\":\"bad\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":1,\"processes\":[{s}]}}}}",
        .{processes.written()},
    );
    defer allocator.free(attack);
    const malformed =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":3,\"metadata\":{\"cwd\":\"/partial\"}}";
    const valid =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/attacker","window_title":"bad","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try expectGuiMetadataProjectionFailurePreservesCache(
        malformed,
        .supported,
        .malformed_drop,
    );
    // A syntactically malformed envelope has no trusted event identity. GUI malformed-drop
    // precedence therefore applies before capability enforcement; a valid metadata envelope on
    // the same unsupported profile is still a capability violation below.
    try expectGuiMetadataProjectionFailurePreservesCache(
        malformed,
        .unsupported,
        .malformed_drop,
    );
    try expectGuiMetadataProjectionFailurePreservesCache(attack, .supported, .fail_closed);
    try expectGuiMetadataProjectionFailurePreservesCache(valid, .unsupported, .fail_closed);
}

const Attach2eFailureCase = enum { typed_reject, response_eof };

fn run2eAttachFailureSocket(selected: Attach2eFailureCase) !void {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const Peer = struct {
        fn run(fd: c.fd_t, mode: Attach2eFailureCase) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            if (request.header.kind != .request or
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") == null)
                return;
            if (mode == .response_eof) return;
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"error\":\"runtime_not_found\"}",
            ) catch return;
            defer std.heap.page_allocator.free(response);
            socket_server.writeAll(fd, response) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], selected });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeTestGeneration(
        &rr,
        allocator,
        .{ .generation = &adapter },
    );
    rr.currentGeneration().connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.mutation_owner = .{};
    rr.paused_input_metadata = null;
    rr.paused_paste_store = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.currentGeneration().observation.deinit(allocator);

    const result = rr.attachAndAssemble(1, .{ .cols = 80, .rows = 24 });
    switch (selected) {
        .typed_reject => try std.testing.expectError(error.RuntimeNotFound, result),
        .response_eof => try std.testing.expectError(error.AttachFailed, result),
    }
    peer.join();
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.currentGeneration().attachment.generation.batch_adapter.slot_addr);
}

test "CR3a-2e actual socket typed reject는 준비한 row와 pin과 batch를 exact 원복한다" {
    try run2eAttachFailureSocket(.typed_reject);
}

test "CR3a-2e actual socket response 전 EOF는 준비한 row와 pin과 batch를 exact 원복한다" {
    try run2eAttachFailureSocket(.response_eof);
}

test "CR3a-2e actual socket malformed accepted는 cache를 보존하고 준비 권위를 정리한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var processes: std.Io.Writer.Allocating = .init(allocator);
    defer processes.deinit();
    for (0..runtime_metadata_wire.max_process_entries + 1) |index| {
        if (index != 0) try processes.writer.writeByte(',');
        try processes.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"result\":{{\"stream_id\":7,\"controller_generation\":1,\"granted\":{{\"observe\":true,\"input\":true,\"resize\":true}},\"controller_busy\":false,\"metadata_revision\":3,\"metadata\":{{\"cwd\":\"/attacker\",\"window_title\":\"bad\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":1,\"processes\":[{s}]}}}}}}",
        .{processes.written()},
    );
    defer allocator.free(body);
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        body,
    );
    defer allocator.free(response);
    const AttachPeer = struct {
        fn run(fd: c.fd_t, wire: []const u8, eof_seen: *bool) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            if (request.header.kind != .request or
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") == null)
                return;
            socket_server.writeAll(fd, wire) catch return;
            var poll_fd = posix.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
            if (c.poll(@ptrCast(&poll_fd), 1, 1_000) <= 0) return;
            var byte: [1]u8 = undefined;
            eof_seen.* = c.read(fd, &byte, byte.len) == 0;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var eof_seen = false;
    var peer = try std.Thread.spawn(.{}, AttachPeer.run, .{
        fds[1],
        response,
        &eof_seen,
    });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .generation = &adapter });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.mutation_owner = .{};
    rr.paused_input_metadata = null;
    rr.paused_paste_store = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.currentGeneration().observation.deinit(allocator);
    try rr.currentGeneration().observation.replace(allocator, .{
        .availability = .current,
        .revision = 2,
        .cwd = "/safe",
        .window_title = "work",
        .ssh_remote_dest = "safe-host",
        .size = .{ .cols = 120, .rows = 40 },
    });
    try std.testing.expectError(
        error.AttachFailed,
        rr.attachAndAssemble(1, .{ .cols = 80, .rows = 24 }),
    );
    peer.join();
    try std.testing.expect(eof_seen);
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    try std.testing.expectEqual(@as(u64, 2), rr.currentGeneration().observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.currentGeneration().observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.currentGeneration().observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.currentGeneration().observation.ssh_remote_dest.items);
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.currentGeneration().attachment.generation.batch_adapter.slot_addr);
}

test "CR3a-2e actual socket accepted 뒤 snapshot EOF는 committed stream 권위를 exact 정리한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const body =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1," ++
        "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
        "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        body,
    );
    defer allocator.free(response);
    const AttachThenEofPeer = struct {
        fn run(fd: c.fd_t, wire: []const u8) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            if (request.header.kind != .request or
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") == null)
                return;
            socket_server.writeAll(fd, wire) catch return;
            // Closing immediately after the accepted response makes the product readSnapshot
            // path fail after binding commit, where generation cleanup must be exact.
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, AttachThenEofPeer.run, .{ fds[1], response });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .generation = &adapter });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};

    try std.testing.expectError(
        error.ConnectionClosed,
        rr.attachAndAssemble(1, .{ .cols = 80, .rows = 24 }),
    );
    peer.join();
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.slot.current.cleanup_registry.count(),
    );
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.currentGeneration().attachment.generation.batch_adapter.slot_addr);
}

const SnapshotFreeReentryProbe = struct {
    parent: std.mem.Allocator,
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
    armed: bool = false,
    fired: bool = false,
    outcome: ?generation_attachment_mod.DeinitOutcome = null,
    slot_outcome: ?@import("client_slot.zig").DeinitOutcome = null,

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
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed and !self.fired) {
            self.fired = true;
            self.outcome = switch (self.runtime.currentGeneration().attachment) {
                .generation => |*value| value.tryDeinit(self.adapter),
                .legacy => .corrupt,
            };
            self.slot_outcome = self.adapter.slot.tryDeinit();
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

const OneShotFailAllocator = struct {
    parent: std.mem.Allocator,
    failed: bool = false,

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
        if (!self.failed) {
            self.failed = true;
            return null;
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

const BlockingControlReentryAllocator = struct {
    parent: std.mem.Allocator,
    runtime: *RemoteRuntime,
    fired: bool = false,
    observed_admin_busy: bool = false,
    observed_pump_blocked: bool = false,
    observed_pump_error: ?client_mod.ClientError = null,
    observed_queue_len: usize = 0,

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
        if (!self.fired) {
            self.fired = true;
            self.observed_queue_len = self.runtime.pending_controls.items.len;
            if (self.runtime.pumpQueuedInput()) |drained| {
                self.observed_pump_blocked = !drained;
            } else |err| {
                self.observed_pump_error = err;
            }
            self.runtime.flushQueuedInputBlocking() catch |err| {
                self.observed_admin_busy = err == error.AdminBusy;
            };
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

test "CR3a-2c1 CR3a-2c3c C2 CR3a-2c3c C3 generation attach admits nonblocking and blocking typed control" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const response_body =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1," ++
        "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
        "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        response_body,
    );
    defer allocator.free(response);
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&records, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&records, allocator, row);
    const snapshot = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        records.items,
    );
    defer allocator.free(snapshot);
    const Peer = struct {
        fn run(
            fd: c.fd_t,
            response_wire: []const u8,
            snapshot_wire: []const u8,
            control_ok: *bool,
            oom_retry_ok: *bool,
            retry_control_ok: *bool,
            blocking_order_ok: *bool,
            blocking_busy_ok: *bool,
            blocking_oom_retry_ok: *bool,
            scroll_and_suffix_ok: *bool,
            unsupported_wire_zero: *bool,
            blocking_unsupported_wire_zero: *bool,
            blocking_unsupported_ready: *std.atomic.Value(u8),
            blocking_unsupported_checked: *std.atomic.Value(u8),
            blocking_oom_ready: *std.atomic.Value(u8),
            blocking_oom_retry_checked: *std.atomic.Value(u8),
            release_filler: *std.atomic.Value(u8),
            filler_drained: *std.atomic.Value(u8),
            blocking_filler_len: *usize,
            retry_filler_len: *usize,
        ) void {
            defer _ = c.close(fd);
            // 전체 test artifact가 병렬로 실행될 때도 이 복합 wire fixture의 peer가 제품 쪽보다 먼저
            // 닫히지 않게 한다. 각 단계는 아래 flag/frame oracle로 별도 검증되며 60초 뒤에는 닫힌다.
            var read_timeout = posix.timeval{ .sec = 60, .usec = 0 };
            if (c.setsockopt(
                fd,
                c.SOL.SOCKET,
                c.SO.RCVTIMEO,
                &read_timeout,
                @sizeOf(posix.timeval),
            ) != 0) return;
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            if (request.header.kind != .request or
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") == null)
                return;
            socket_server.writeAll(fd, response_wire) catch return;
            socket_server.writeAll(fd, snapshot_wire) catch return;
            const control = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(control.payload);
            control_ok.* = control.header.kind == .core_command and
                control.header.stream_id == 7 and
                std.mem.indexOf(u8, control.payload, "\"op\":\"report_focus\"") != null;
            const oom_retry = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(oom_retry.payload);
            oom_retry_ok.* = oom_retry.header.kind == .core_command and
                oom_retry.header.stream_id == 7 and
                std.mem.indexOf(u8, oom_retry.payload, "\"direction\":1") != null;
            const blocking_prefix = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_prefix.payload);
            const blocking_control = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_control.payload);
            const blocking_suffix = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_suffix.payload);
            blocking_order_ok.* = blocking_prefix.header.kind == .input_bytes and
                blocking_prefix.header.stream_id == 7 and std.mem.eql(u8, blocking_prefix.payload, "C") and
                blocking_control.header.kind == .core_command and
                blocking_control.header.stream_id == 7 and
                std.mem.indexOf(u8, blocking_control.payload, "\"gained\":true") != null and
                blocking_suffix.header.kind == .input_bytes and
                blocking_suffix.header.stream_id == 7 and std.mem.eql(u8, blocking_suffix.payload, "D");
            const blocking_busy_outer = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_busy_outer.payload);
            blocking_busy_ok.* = blocking_busy_outer.header.kind == .scroll_to_bottom and
                blocking_busy_outer.header.stream_id == 7 and blocking_busy_outer.payload.len == 0;
            waitRemoteTestFlag(blocking_unsupported_ready) catch return;
            var unsupported_poll = posix.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
            blocking_unsupported_wire_zero.* = c.poll(@ptrCast(&unsupported_poll), 1, 100) == 0;
            blocking_unsupported_checked.store(1, .release);
            waitRemoteTestFlag(blocking_oom_ready) catch return;
            const blocking_filler = peer_allocator.alloc(u8, blocking_filler_len.*) catch return;
            defer peer_allocator.free(blocking_filler);
            readRemoteTestExactWithin(fd, blocking_filler, 60) catch return;
            const prior_input = readPeerFrameAfterFiller(fd, peer_allocator, 0xA5) catch return;
            defer peer_allocator.free(prior_input.payload);
            const blocking_oom_retry = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_oom_retry.payload);
            const blocking_oom_suffix = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(blocking_oom_suffix.payload);
            blocking_oom_retry_ok.* = prior_input.header.kind == .input_bytes and
                prior_input.header.stream_id == 7 and std.mem.eql(u8, prior_input.payload, "E") and
                blocking_oom_retry.header.kind == .core_command and
                blocking_oom_retry.header.stream_id == 7 and
                std.mem.indexOf(u8, blocking_oom_retry.payload, "\"direction\":-1") != null and
                blocking_oom_suffix.header.kind == .input_bytes and
                blocking_oom_suffix.header.stream_id == 7 and std.mem.eql(u8, blocking_oom_suffix.payload, "F");
            blocking_oom_retry_checked.store(1, .release);
            waitRemoteTestFlag(release_filler) catch return;
            const filler = peer_allocator.alloc(u8, retry_filler_len.*) catch return;
            defer peer_allocator.free(filler);
            // 두 번째 포화 구간은 앞선 blocking/OOM/RPC 단계까지 같은 peer가 수행한 뒤 시작한다.
            // 전체 artifact 부하가 큰 경우에도 포화 해제 자체의 bounded oracle이 먼저 만료되지 않게 한다.
            readRemoteTestExactWithin(fd, filler, 60) catch return;
            filler_drained.store(1, .release);
            const input = readPeerFrameAfterFiller(fd, peer_allocator, 0xA5) catch return;
            defer peer_allocator.free(input.payload);
            const retry_control = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(retry_control.payload);
            retry_control_ok.* = input.header.kind == .input_bytes and
                input.header.stream_id == 7 and std.mem.eql(u8, input.payload, "A") and
                retry_control.header.kind == .core_command and
                retry_control.header.stream_id == 7 and
                std.mem.indexOf(u8, retry_control.payload, "\"gained\":false") != null;
            const scroll = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(scroll.payload);
            const suffix = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(suffix.payload);
            scroll_and_suffix_ok.* = scroll.header.kind == .scroll_to_bottom and
                scroll.header.stream_id == 7 and scroll.payload.len == 0 and
                suffix.header.kind == .input_bytes and suffix.header.stream_id == 7 and
                std.mem.eql(u8, suffix.payload, "B");
            var poll_fd = posix.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
            unsupported_wire_zero.* = c.poll(@ptrCast(&poll_fd), 1, 100) == 0;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var client_fd_owned_by_adapter = false;
    defer {
        if (!client_fd_owned_by_adapter) _ = c.close(fds[0]);
    }
    var peer_fd_owned_by_thread = false;
    defer {
        if (!peer_fd_owned_by_thread) _ = c.close(fds[1]);
    }
    var control_ok = false;
    var oom_retry_ok = false;
    var retry_control_ok = false;
    var blocking_order_ok = false;
    var blocking_busy_ok = false;
    var blocking_oom_retry_ok = false;
    var scroll_and_suffix_ok = false;
    var unsupported_wire_zero = false;
    var blocking_unsupported_wire_zero = false;
    var blocking_unsupported_ready = std.atomic.Value(u8).init(0);
    var blocking_unsupported_checked = std.atomic.Value(u8).init(0);
    var blocking_oom_ready = std.atomic.Value(u8).init(0);
    var blocking_oom_retry_checked = std.atomic.Value(u8).init(0);
    var release_filler = std.atomic.Value(u8).init(0);
    var filler_drained = std.atomic.Value(u8).init(0);
    var blocking_filler_len: usize = 0;
    var retry_filler_len: usize = 0;
    var peer = try std.Thread.spawn(.{}, Peer.run, .{
        fds[1],                      response,                      snapshot,
        &control_ok,                 &oom_retry_ok,                 &retry_control_ok,
        &blocking_order_ok,          &blocking_busy_ok,             &blocking_oom_retry_ok,
        &scroll_and_suffix_ok,       &unsupported_wire_zero,        &blocking_unsupported_wire_zero,
        &blocking_unsupported_ready, &blocking_unsupported_checked, &blocking_oom_ready,
        &blocking_oom_retry_checked, &release_filler,               &filler_drained,
        &blocking_filler_len,        &retry_filler_len,
    });
    peer_fd_owned_by_thread = true;
    var peer_joined = false;
    defer {
        blocking_unsupported_ready.store(1, .release);
        blocking_oom_ready.store(1, .release);
        release_filler.store(1, .release);
        _ = c.shutdown(fds[0], c.SHUT.RDWR);
        if (!peer_joined) peer.join();
    }
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .async_scroll_to_bottom_v1 = true,
        .runtime_core_command_v1 = true,
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    client_fd_owned_by_adapter = true;
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try rr.initializeGenerationOwner(
        .{ .generation = &adapter },
        allocator,
        std.testing.io,
        .{ .cols = 1, .rows = 1 },
    );
    defer rr.deinitGenerationOwnerAndScreenSource();
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    rr.mutation_owner = .{};
    rr.paused_input_metadata = null;
    rr.paused_paste_store = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    var free_probe = SnapshotFreeReentryProbe{
        .parent = allocator,
        .runtime = &rr,
        .adapter = &adapter,
        .armed = true,
    };
    adapter.slot.current.guarded_allocator.parent = free_probe.allocator();

    try rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
    var attachment_live = true;
    defer {
        if (attachment_live) {
            rr.surface.deinit();
        }
    }
    try rr.queueCoreCommand(.{ .report_focus = true });
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).runtime_core_command_v1 = false;
    try rr.queueCoreCommand(.{ .scroll = 1 });
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).runtime_core_command_v1 = true;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const saved_client_allocator = host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator;
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = failing.allocator();
    const oom_result = rr.queueCoreCommand(.{ .jump_to_prompt = 1 });
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = saved_client_allocator;
    try oom_result;
    try std.testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try std.testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    while (!(try rr.pumpQueuedInput())) {}
    try rr.direct_input.appendSlice(allocator, "CD");
    try RemoteRuntime.queue_testing.appendRecord(&rr, .key_bytes, 1);
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        1,
        .{ .report_focus = true },
    ).?);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .core_command, 1);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .key_bytes, 2);
    try rr.flushQueuedInputBlocking();
    try std.testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(0).?);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .scroll_to_bottom, 0);
    var blocking_reentry = BlockingControlReentryAllocator{
        .parent = allocator,
        .runtime = &rr,
    };
    const blocking_reentry_saved_allocator = host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator;
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = blocking_reentry.allocator();
    const blocking_reentry_result = rr.flushQueuedInputBlocking();
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = blocking_reentry_saved_allocator;
    try blocking_reentry_result;
    try std.testing.expect(blocking_reentry.fired);
    try std.testing.expect(blocking_reentry.observed_admin_busy);
    try std.testing.expect(blocking_reentry.observed_pump_blocked);
    try std.testing.expect(blocking_reentry.observed_pump_error == null);
    try std.testing.expectEqual(@as(usize, 1), blocking_reentry.observed_queue_len);
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).async_scroll_to_bottom_v1 = false;
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(0).?);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .scroll_to_bottom, 0);
    try rr.flushQueuedInputBlocking();
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    blocking_unsupported_ready.store(1, .release);
    try waitRemoteTestFlag(&blocking_unsupported_checked);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).async_scroll_to_bottom_v1 = true;
    blocking_filler_len = try fillRemoteTestSendBuffer(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
    try std.testing.expectEqual(
        @as(usize, 1),
        try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).sendInputNonBlocking(7, "E"),
    );
    try rr.direct_input.appendSlice(allocator, "F");
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        0,
        .{ .jump_to_prompt = -1 },
    ).?);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .core_command, 0);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .key_bytes, 1);
    var blocking_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const blocking_saved_allocator = host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator;
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = blocking_failing.allocator();
    blocking_oom_ready.store(1, .release);
    const blocking_oom_result = rr.flushQueuedInputBlocking();
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).allocator = blocking_saved_allocator;
    try std.testing.expectError(error.OutOfMemory, blocking_oom_result);
    try std.testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try std.testing.expectEqualStrings("F", rr.direct_input.items[rr.direct_input_offset..]);
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try std.testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    try rr.flushQueuedInputBlocking();
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    try std.testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try waitRemoteTestFlag(&blocking_oom_retry_checked);
    retry_filler_len = try fillRemoteTestSendBuffer(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
    try std.testing.expectEqual(@as(usize, 1), try rr.sendInputNonBlocking("A"));
    try rr.queueCoreCommand(.{ .report_focus = false });
    try rr.requestScrollToBottom();
    try rr.requestScrollToBottom();
    try rr.sendInput("B");
    // send-buffer 포화 뒤에도 커널이 첫 control 전체를 받아들일 수 있다. 남은
    // queue 길이는 1 또는 2지만, 아래 peer oracle이 wire 순서를 끝까지 검증한다.
    try std.testing.expect(rr.pending_controls.items.len >= 1);
    try std.testing.expect(rr.pending_controls.items.len <= 2);
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound != null);
    release_filler.store(1, .release);
    try waitRemoteTestFlag(&filler_drained);
    const pending = &host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?;
    if (pending.offset == 0) {
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds +
            60 * std.time.ns_per_s;
        while (true) {
            const written = c.send(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd, pending.frame.ptr, 1, 0);
            if (written == 1) break;
            if (written < 0 and posix.errno(written) == .INTR) continue;
            if (written < 0 and posix.errno(written) == .AGAIN) {
                if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline)
                    return error.RemoteTestDeadlineExceeded;
                var poll_fd = posix.pollfd{
                    .fd = host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd,
                    .events = c.POLL.OUT,
                    .revents = 0,
                };
                const ready = c.poll(@ptrCast(&poll_fd), 1, 50);
                if (ready < 0 and posix.errno(ready) == .INTR) continue;
                if (ready < 0 or poll_fd.revents & (c.POLL.ERR | c.POLL.NVAL) != 0)
                    return error.TestUnexpectedResult;
                continue;
            }
            return error.TestUnexpectedResult;
        }
        pending.offset = 1;
    }
    try std.testing.expect(pending.offset > 0 and pending.offset < pending.frame.len);
    while (!(try rr.currentGeneration().attachment.pumpPendingOutput(host_adapter_mod.HostAdapter.testing.rawClient(&adapter)))) {}
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    while (!(try rr.pumpQueuedInput())) {}
    peer.join();
    peer_joined = true;
    try std.testing.expect(control_ok);
    try std.testing.expect(oom_retry_ok);
    try std.testing.expect(retry_control_ok);
    try std.testing.expect(blocking_order_ok);
    try std.testing.expect(blocking_busy_ok);
    try std.testing.expect(blocking_oom_retry_ok);
    try std.testing.expect(scroll_and_suffix_ok);
    try std.testing.expect(unsupported_wire_zero);
    try std.testing.expect(blocking_unsupported_wire_zero);
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        0,
        .{ .report_focus = true },
    ).?);
    try RemoteRuntime.queue_testing.appendRecord(&rr, .core_command, 0);
    try std.testing.expectError(error.ConnectionClosed, rr.flushQueuedInputBlocking());
    try std.testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    try std.testing.expectEqual(
        @import("client_poison.zig").ConnectionReason.outbound_write_ambiguous,
        host_adapter_mod.HostAdapter.testing.rawClient(&adapter).firstPoisonReason().?,
    );
    try std.testing.expectError(error.ConnectionClosed, rr.flushQueuedInputBlocking());
    try std.testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try std.testing.expect(free_probe.fired);
    try std.testing.expectEqual(generation_attachment_mod.DeinitOutcome.busy, free_probe.outcome.?);
    try std.testing.expectEqual(
        @import("client_slot.zig").DeinitOutcome.busy,
        free_probe.slot_outcome.?,
    );
    try std.testing.expect(adapter.slot.initialSnapshotPermitIdle());
    try std.testing.expect(rr.usesGenerationAttachment());
    try std.testing.expectEqual(@as(u21, 'x'), rr.currentGeneration().attachment.screenPtr().?.grid.cells[0].codepoint);
    rr.surface.deinit();
    attachment_live = false;
}

test "CR3a-2c3a generation revoke partial wire poisons the RemoteRuntime connection" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3," ++
            "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
            "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
    );
    defer allocator.free(response);
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&records, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&records, allocator, row);
    const snapshot = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        records.items,
    );
    defer allocator.free(snapshot);
    const Peer = struct {
        fn run(fd: c.fd_t, response_wire: []const u8, snapshot_wire: []const u8) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            socket_server.writeAll(fd, response_wire) catch return;
            socket_server.writeAll(fd, snapshot_wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response, snapshot });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try rr.initializeGenerationOwner(
        .{ .generation = &adapter },
        allocator,
        std.testing.io,
        .{ .cols = 1, .rows = 1 },
    );
    defer rr.deinitGenerationOwnerAndScreenSource();
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    try rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
    peer.join();

    const pending = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 7 },
        "partially-written",
    );
    rr.testingClient().pending_outbound = .{
        .frame = pending,
        .offset = 1,
        .stream_id = 7,
    };
    try rr.testingClient().bufferGenerationEventForTest(
        7,
        "{\"event\":\"controller.revoked\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );

    try std.testing.expectError(error.ConnectionClosed, rr.drainObservationEvents());
    try std.testing.expect(rr.testingClient().unusable);
    try std.testing.expectEqual(
        @import("client_poison.zig").ConnectionReason.outbound_partial_write,
        rr.testingClient().firstPoisonReason().?,
    );
    try std.testing.expectEqual(remote_attachment.Role.observer, rr.currentGeneration().attachment.statePtr().role);
    try std.testing.expectError(error.Unauthorized, rr.sendInputNonBlocking("late"));
    rr.surface.deinit();
}

test "CR3a-2c3d C3-2 product drain purges ended generation before screen progress" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3," ++
            "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
            "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
    );
    defer allocator.free(response);
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&records, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&records, allocator, row);
    const snapshot = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        records.items,
    );
    defer allocator.free(snapshot);
    const Peer = struct {
        fn run(fd: c.fd_t, response_wire: []const u8, snapshot_wire: []const u8) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            socket_server.writeAll(fd, response_wire) catch return;
            socket_server.writeAll(fd, snapshot_wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response, snapshot });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try rr.initializeGenerationOwner(
        .{ .generation = &adapter },
        allocator,
        std.testing.io,
        .{ .cols = 1, .rows = 1 },
    );
    defer rr.deinitGenerationOwnerAndScreenSource();
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    try rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
    peer.join();

    const Hook = struct {
        var force_release_busy = false;
        var inject_ended_after_purge = false;
        var exhaust_retry_budget = false;
        var ended_pending_count: usize = 0;

        fn run(
            runtime: *RemoteRuntime,
            stage: RemoteRuntime.GenerationDrainHookStage,
        ) RemoteRuntime.GenerationDrainHookDecision {
            if (stage == .before_current_release and force_release_busy) {
                force_release_busy = false;
                return .busy;
            }
            if (stage == .after_purge_not_ended and inject_ended_after_purge) {
                if (!exhaust_retry_budget) inject_ended_after_purge = false;
                runtime.testingClient().bufferGenerationEventForTest(
                    runtime.currentGeneration().attachment.streamId(),
                    "{\"event\":\"runtime.ended\"}",
                ) catch @panic("C3-2 race hook failed to publish ended event");
                ended_pending_count += 1;
            }
            if (stage == .before_purge and exhaust_retry_budget and ended_pending_count != 0) {
                runtime.testingClient().dropBufferedStream(runtime.currentGeneration().attachment.streamId());
            }
            return .proceed;
        }
    };
    Hook.force_release_busy = true;
    try rr.testingClient().bufferGenerationEventForTest(
        7,
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":2,\"rows\":1,\"resize_generation\":10,\"reason\":\"controller\"}}",
    );
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    try std.testing.expect(rr.currentGeneration().attachment.generation.event_generation_mirror != 0);
    const after_release_retry = try rr.drainObservationEvents();
    try std.testing.expect(!after_release_retry.ended);
    try std.testing.expect(after_release_retry.metadata);
    try std.testing.expectEqual(@as(u64, 0), rr.currentGeneration().attachment.generation.event_generation_mirror);

    Hook.force_release_busy = true;
    try rr.testingClient().bufferGenerationEventForTest(7, "{\"event\":\"snapshot.invalidated\"}");
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    try std.testing.expect(rr.currentGeneration().attachment.generation.event_generation_mirror != 0);
    const invalidated = try rr.drainObservationEvents();
    try std.testing.expect(!invalidated.ended);
    try std.testing.expect(rr.currentGeneration().resync_needed);
    try std.testing.expectEqual(@as(u64, 0), rr.currentGeneration().attachment.generation.event_generation_mirror);

    try rr.direct_input.appendSlice(allocator, "budget-must-not-send");
    Hook.exhaust_retry_budget = true;
    Hook.inject_ended_after_purge = true;
    Hook.ended_pending_count = 0;
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        Hook.ended_pending_count,
    );
    try std.testing.expectEqualStrings("budget-must-not-send", rr.direct_input.items);
    try std.testing.expectEqual(@as(u21, 'x'), rr.currentGeneration().attachment.screenPtr().?.grid.cells[0].codepoint);
    Hook.exhaust_retry_budget = false;
    Hook.inject_ended_after_purge = false;
    try std.testing.expect((try rr.drainObservationEvents()).ended);
    rr.direct_input.clearRetainingCapacity();

    try rr.testingClient().bufferGenerationEventForTest(8, "{\"event\":\"runtime.ended\"}");
    try rr.testingClient().screen_inbox.pending_batches.append(allocator, .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "stale-target"),
        .allocator = allocator,
    });
    try rr.testingClient().screen_inbox.pending_batches.append(allocator, .{
        .stream_id = 8,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "sibling"),
        .allocator = allocator,
    });
    rr.testingClient().screen_inbox.pending_batch_bytes = "stale-target".len + "sibling".len;

    Hook.inject_ended_after_purge = true;
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    const ended = try rr.drainGenerationObservationEventsWithHook(Hook.run);
    try std.testing.expect(ended.ended);
    try std.testing.expectEqual(@as(usize, 1), rr.testingClient().pending_events.items.len);
    try std.testing.expectEqual(@as(u64, 8), rr.testingClient().pending_events.items[0].header.stream_id);
    try std.testing.expectEqual(@as(usize, 1), rr.testingClient().screen_inbox.pending_batches.items.len);
    try std.testing.expectEqual(@as(u64, 8), rr.testingClient().screen_inbox.pending_batches.items[0].stream_id);
    try std.testing.expectEqualStrings("sibling", rr.testingClient().screen_inbox.pending_batches.items[0].bytes);
    try std.testing.expectEqual(@as(u21, 'x'), rr.currentGeneration().attachment.screenPtr().?.grid.cells[0].codepoint);
    try std.testing.expectEqual(@as(u64, 0), rr.currentGeneration().attachment.generation.event_generation_mirror);

    try rr.direct_input.appendSlice(allocator, "must-not-send");
    try rr.testingClient().bufferGenerationEventForTest(7, "{\"event\":\"runtime.ended\"}");
    try rr.testingClient().screen_inbox.pending_batches.append(allocator, .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "second-stale-target"),
        .allocator = allocator,
    });
    rr.testingClient().screen_inbox.pending_batch_bytes += "second-stale-target".len;
    try std.testing.expectEqual(RemoteRuntime.PumpResult.ended, try rr.pumpDelta());
    try std.testing.expectEqualStrings("must-not-send", rr.direct_input.items);
    try std.testing.expect(rr.currentGeneration().resync_needed);
    try std.testing.expectEqual(@as(u21, 'x'), rr.currentGeneration().attachment.screenPtr().?.grid.cells[0].codepoint);

    rr.surface.deinit();
}

const B4SemanticFixture = struct {
    allocator: std.mem.Allocator,
    client: client_mod.Client,
    adapter: host_adapter_mod.HostAdapter,
    runtime: RemoteRuntime,

    pub fn initInPlace(self: *@This()) !void {
        return self.initInPlaceWithAllocator(std.testing.allocator);
    }

    pub fn initInPlaceWithAllocator(self: *@This(), allocator: std.mem.Allocator) !void {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        const response = try framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = 1 },
            "{\"result\":{\"stream_id\":7,\"controller_generation\":3," ++
                "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
                "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        );
        defer allocator.free(response);
        var records: std.ArrayListUnmanaged(u8) = .empty;
        defer records.deinit(allocator);
        const meta = try screen_stream.encodeScreenMeta(
            allocator,
            .{ .kind = .screen_meta, .generation = 1 },
            .{ .cols = 1, .rows = 1, .cursor = .{} },
        );
        defer allocator.free(meta);
        try screen_stream.appendRecord(&records, allocator, meta);
        var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
        const row = try screen_stream.encodeRow(
            allocator,
            .{ .kind = .row, .generation = 1 },
            .{ .row_index = 0, .runs = &runs },
        );
        defer allocator.free(row);
        try screen_stream.appendRecord(&records, allocator, row);
        const snapshot = try framing.encodeFrame(
            allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
            records.items,
        );
        defer allocator.free(snapshot);
        const Peer = struct {
            fn run(fd: c.fd_t, response_wire: []const u8, snapshot_wire: []const u8) void {
                defer _ = c.close(fd);
                const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
                defer std.heap.page_allocator.free(request.payload);
                socket_server.writeAll(fd, response_wire) catch return;
                socket_server.writeAll(fd, snapshot_wire) catch return;
            }
        };
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response, snapshot });
        self.allocator = allocator;
        self.client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
            .attachment_capabilities = .{ .peer_attach_generation = true },
            .metadata_support = .supported,
            .compatibility_profile = @import("compatibility.zig").profileForMajor(
                protocol.version_major,
            ).?,
        };
        try host_adapter_mod.HostAdapter.initInPlace(&self.adapter, allocator, &self.client);
        try self.runtime.initializeGenerationOwner(
            .{ .generation = &self.adapter },
            allocator,
            std.testing.io,
            .{ .cols = 1, .rows = 1 },
        );
        self.runtime.pending_event_owner = .{};
        self.runtime.runtime_lifetime = .{};
        try self.runtime.initializePendingEventOwner();
        self.runtime.allocator = allocator;
        self.runtime.io = std.testing.io;
        self.runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
        self.runtime.currentGeneration().resize_seq = 0;
        self.runtime.currentGeneration().resize_generation = 0;
        self.runtime.currentGeneration().resize_baseline_present = false;
        self.runtime.direct_input = .empty;
        self.runtime.input_batches = .{};
        self.runtime.direct_input_offset = 0;
        self.runtime.pending_controls = .empty;
        self.runtime.blocking_flush_active = false;
        self.runtime.currentGeneration().pump_ended = false;
        self.runtime.currentGeneration().resync_needed = false;
        self.runtime.currentGeneration().observation = .{};
        self.runtime.close_authority = .{};
        self.runtime.shutdown_attempt_authority = .{};
        self.runtime.shutdown_current_admin = .{};
        try self.runtime.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
        peer.join();
    }

    pub fn deinit(self: *@This()) void {
        self.runtime.surface.deinit();
        self.runtime.deinitGenerationOwnerAndScreenSource();
        self.runtime.direct_input.deinit(self.allocator);
        self.runtime.pending_controls.deinit(self.allocator);
        self.adapter.deinit();
    }

    pub fn publish(self: *@This(), payload: []const u8) !RemoteRuntime.EventDrain {
        try self.runtime.testingClient().bufferGenerationEventForTest(7, payload);
        return self.runtime.drainObservationEvents();
    }

    pub fn prepareForClose(self: *@This(), payload: []const u8) !void {
        try self.runtime.testingClient().bufferGenerationEventForTest(7, payload);
        switch (try self.runtime.currentGeneration().attachment.generation.takeEvent()) {
            .taken => {},
            else => return error.TestUnexpectedResult,
        }
        _ = try self.runtime.classifyAndPrepareEvent();
    }
};

const B4SemanticProofLossAllocator = struct {
    parent: std.mem.Allocator,
    runtime: ?*RemoteRuntime = null,
    target_addr: usize = 0,
    target_len: usize = 0,
    armed: bool = false,

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
            const runtime = self.runtime orelse @panic("b4 proof-loss runtime가 없다");
            runtime.pending_event_owner.progress_seal[0] ^= 1;
        }
        self.parent.rawFree(memory, alignment, ra);
    }
};

const B4ProofLossCase = enum {
    old_owner_callback,
    observation,
    continuation,
};

fn runB4ProofLossChild(case: B4ProofLossCase) noreturn {
    var allocator_probe = B4SemanticProofLossAllocator{ .parent = std.testing.allocator };
    var fixture: B4SemanticFixture = undefined;
    fixture.initInPlaceWithAllocator(allocator_probe.allocator()) catch std.c._exit(125);
    _ = fixture.publish(b4_metadata_base) catch std.c._exit(125);
    fixture.prepareForClose(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":5,\"metadata\":{" ++
            "\"cwd\":\"/proof-loss\",\"window_title\":\"proof\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":2,\"title_generation\":2," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
            "\"foreground_pgid\":null,\"processes\":[]}}",
    ) catch std.c._exit(125);
    switch (case) {
        .old_owner_callback => {
            allocator_probe.runtime = &fixture.runtime;
            allocator_probe.target_addr = @intFromPtr(fixture.runtime.currentGeneration().observation.cwd.items.ptr);
            allocator_probe.target_len = fixture.runtime.currentGeneration().observation.cwd.items.len;
            allocator_probe.armed = true;
        },
        .observation => testing_api.armSemanticProofLoss(@intFromEnum(B4SemanticProofLossStage.observation_drift)),
        .continuation => testing_api.armSemanticProofLoss(@intFromEnum(B4SemanticProofLossStage.continuation_drift)),
    }
    _ = fixture.runtime.advancePendingEventForClose();
    std.c._exit(124);
}

fn expectB4ProofLoss(case: B4ProofLossCase) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const enabled = std.c.getenv("MARU_C3B4_PROOF_LOSS") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(enabled), "fresh-artifact-v1")) return error.SkipZigTest;
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) runB4ProofLossChild(case);
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

const b4_metadata_base =
    "{\"event\":\"runtime.metadata\",\"metadata_revision\":4,\"metadata\":{" ++
    "\"cwd\":\"/base\",\"window_title\":\"base\",\"ssh_remote_dest\":null," ++
    "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
    "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1," ++
    "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
    "\"foreground_pgid\":null,\"processes\":[]}}";
const b4_metadata_stale =
    "{\"event\":\"runtime.metadata\",\"metadata_revision\":3,\"metadata\":{" ++
    "\"cwd\":\"/stale\",\"window_title\":\"stale\",\"ssh_remote_dest\":null," ++
    "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
    "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1," ++
    "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
    "\"foreground_pgid\":null,\"processes\":[]}}";
const b4_metadata_probe_noop =
    "{\"event\":\"runtime.metadata\",\"metadata_revision\":4,\"observation_probe_nonce\":48879,\"metadata\":{" ++
    "\"cwd\":\"/base\",\"window_title\":\"base\",\"ssh_remote_dest\":null," ++
    "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
    "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1," ++
    "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
    "\"foreground_pgid\":null,\"processes\":[]}}";

test "C3-3b4 proof-loss subprocess는 metadata old owner callback 뒤 seal drift를 fail-stop한다" {
    try expectB4ProofLoss(.old_owner_callback);
}

test "C3-3b4 proof-loss subprocess는 새 observation semantic drift를 fail-stop한다" {
    try expectB4ProofLoss(.observation);
}

test "C3-3b4 proof-loss subprocess는 committed cleanup continuation drift를 fail-stop한다" {
    try expectB4ProofLoss(.continuation);
}

test "C3-3b4 실제 Runtime event ignored는 live 의미 상태를 바꾸지 않는다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    _ = try fixture.publish(b4_metadata_base);
    const before = try runtime_observation_digest_mod.digest(
        &fixture.runtime.currentGeneration().observation,
        try runtime_observation_digest_mod.cleanupGraph(&fixture.runtime.currentGeneration().observation, fixture.allocator),
    );
    const result = try fixture.publish(b4_metadata_stale);
    const after = try runtime_observation_digest_mod.digest(
        &fixture.runtime.currentGeneration().observation,
        try runtime_observation_digest_mod.cleanupGraph(&fixture.runtime.currentGeneration().observation, fixture.allocator),
    );
    try std.testing.expect(!result.metadata and !result.ended);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "C3-3b4 실제 Runtime event ended는 settlement 뒤 종료를 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    try std.testing.expect((try fixture.publish("{\"event\":\"runtime.ended\"}")).ended);
    try std.testing.expectEqual(@intFromEnum(pending_event_owner_mod.PendingLifecycle.idle), fixture.runtime.pending_event_owner.lifecycle_raw);
}

test "C3-3b4 실제 Runtime event invalidated는 settlement 뒤 resync intent를 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    const result = try fixture.publish("{\"event\":\"snapshot.invalidated\"}");
    try std.testing.expect(!result.ended and fixture.runtime.currentGeneration().resync_needed);
}

test "C3-3b4 실제 Runtime event resize_noop은 기존 크기를 보존한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    fixture.runtime.currentGeneration().resize_generation = 10;
    fixture.runtime.currentGeneration().resize_baseline_present = true;
    fixture.runtime.currentGeneration().observation.size = .{ .cols = 90, .rows = 30 };
    const result = try fixture.publish(
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}",
    );
    try std.testing.expect(!result.metadata);
    try std.testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.currentGeneration().observation.size);
}

test "C3-3b4 실제 Runtime event resize_commit은 generation과 크기를 함께 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    const result = try fixture.publish(
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":10,\"reason\":\"controller\"}}",
    );
    try std.testing.expect(result.metadata);
    try std.testing.expectEqual(@as(u64, 10), fixture.runtime.currentGeneration().resize_generation);
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 40 }, fixture.runtime.currentGeneration().observation.size);
}

test "C3-3b4 실제 Runtime event metadata_noop은 기존 observation을 보존한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    _ = try fixture.publish(b4_metadata_base);
    const before = fixture.runtime.currentGeneration().observation.revision;
    const result = try fixture.publish(b4_metadata_base);
    try std.testing.expect(!result.metadata);
    try std.testing.expectEqual(before, fixture.runtime.currentGeneration().observation.revision);
    try std.testing.expectEqualStrings("/base", fixture.runtime.currentGeneration().observation.cwd.items);
}

test "C3-3b4 실제 Runtime event metadata_commit은 새 observation을 원자 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    const result = try fixture.publish(b4_metadata_base);
    try std.testing.expect(result.metadata);
    try std.testing.expectEqual(@as(u64, 4), fixture.runtime.currentGeneration().observation.revision);
    try std.testing.expectEqualStrings("/base", fixture.runtime.currentGeneration().observation.cwd.items);
}

test "managed runtime completes async observation probe only after correlated metadata noop commits" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    _ = try fixture.publish(b4_metadata_base);
    fixture.runtime.currentGeneration().observation_probe_active = 48879;
    const result = try fixture.publish(b4_metadata_probe_noop);
    try std.testing.expect(!result.metadata);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.currentGeneration().observation_probe_active);
    try std.testing.expectEqual(@as(u64, 48879), fixture.runtime.currentGeneration().observation_probe_completed);
}

test "managed runtime retires a late abandoned observation without publishing completion" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    _ = try fixture.publish(b4_metadata_base);
    fixture.runtime.currentGeneration().observation_probe_active = 48879;
    try std.testing.expect(fixture.runtime.abandonObservationProbe(48879));
    _ = try fixture.publish(b4_metadata_probe_noop);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.currentGeneration().observation_probe_active);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.currentGeneration().observation_probe_abandoned);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.currentGeneration().observation_probe_completed);
}

test "C3-3b4 실제 Runtime event revoked는 fence effect 뒤 의미 결과를 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    const result = try fixture.publish(
        "{\"event\":\"controller.revoked\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );
    try std.testing.expect(result.metadata);
    try std.testing.expectEqual(remote_attachment.Role.observer, fixture.runtime.currentGeneration().attachment.statePtr().role);
    try std.testing.expectEqual(@as(u64, 4), fixture.runtime.currentGeneration().attachment.statePtr().controller_generation);
}

test "C3-3b4 실제 Runtime event failure는 confirmed effect 뒤 prepared 의미를 억제한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    fixture.runtime.currentGeneration().resize_generation = 10;
    fixture.runtime.currentGeneration().resize_baseline_present = true;
    fixture.runtime.currentGeneration().observation.size = .{ .cols = 90, .rows = 30 };
    try std.testing.expectError(error.ProtocolError, fixture.publish(
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":10,\"reason\":\"controller\"}}",
    ));
    try std.testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.currentGeneration().observation.size);
    try std.testing.expectEqual(@intFromEnum(pending_event_owner_mod.PendingLifecycle.idle), fixture.runtime.pending_event_owner.lifecycle_raw);
}

const B4BusyHook = struct {
    threadlocal var busy_once: bool = false;
    threadlocal var inject_ended_once: bool = false;

    fn run(
        runtime: *RemoteRuntime,
        stage: RemoteRuntime.GenerationDrainHookStage,
    ) RemoteRuntime.GenerationDrainHookDecision {
        if (stage == .before_current_release and busy_once) {
            busy_once = false;
            return .busy;
        }
        if (stage == .after_purge_not_ended and inject_ended_once) {
            inject_ended_once = false;
            runtime.testingClient().bufferGenerationEventForTest(
                runtime.currentGeneration().attachment.streamId(),
                "{\"event\":\"runtime.ended\"}",
            ) catch @panic("b4 ended race fixture publication failed");
        }
        return .proceed;
    }
};

test "C3-3b4 pump round-robin은 Busy owner를 같은 tick에 재시도하지 않는다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    B4BusyHook.busy_once = true;
    try fixture.runtime.testingClient().bufferGenerationEventForTest(
        7,
        "{\"event\":\"snapshot.invalidated\"}",
    );
    try std.testing.expectError(
        error.AdminBusy,
        fixture.runtime.drainGenerationObservationEventsWithHook(B4BusyHook.run),
    );
    try std.testing.expect(fixture.runtime.currentGeneration().attachment.generation.event_generation_mirror != 0);
    try std.testing.expectEqual(@intFromEnum(pending_event_owner_mod.PendingLifecycle.prepared), fixture.runtime.pending_event_owner.lifecycle_raw);
    _ = try fixture.runtime.drainObservationEvents();
}

test "C3-3b4 pump round-robin은 Busy owner를 다음 tick에 exact once 완료한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    B4BusyHook.busy_once = true;
    try fixture.runtime.testingClient().bufferGenerationEventForTest(
        7,
        "{\"event\":\"snapshot.invalidated\"}",
    );
    try std.testing.expectError(
        error.AdminBusy,
        fixture.runtime.drainGenerationObservationEventsWithHook(B4BusyHook.run),
    );
    _ = try fixture.runtime.drainObservationEvents();
    try std.testing.expect(fixture.runtime.currentGeneration().resync_needed);
    try std.testing.expectEqual(@intFromEnum(pending_event_owner_mod.PendingLifecycle.idle), fixture.runtime.pending_event_owner.lifecycle_raw);
}

test "C3-3b4 pump round-robin은 purge ended를 take보다 먼저 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    B4BusyHook.inject_ended_once = true;
    try std.testing.expectError(
        error.AdminBusy,
        fixture.runtime.drainGenerationObservationEventsWithHook(B4BusyHook.run),
    );
    try std.testing.expect((try fixture.runtime.drainObservationEvents()).ended);
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.currentGeneration().attachment.generation.event_generation_mirror);
}

test "CR3a-2c1 malformed generation snapshot poisons before exact attachment rollback" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1," ++
            "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}," ++
            "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
    );
    defer allocator.free(response);
    const malformed = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "not-a-screen-record",
    );
    defer allocator.free(malformed);
    const Peer = struct {
        fn run(fd: c.fd_t, response_wire: []const u8, snapshot_wire: []const u8) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            if (request.header.kind != .request) return;
            socket_server.writeAll(fd, response_wire) catch return;
            socket_server.writeAll(fd, snapshot_wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response, malformed });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(
            protocol.version_major,
        ).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .generation = &adapter });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.currentGeneration().resize_seq = 0;
    rr.currentGeneration().resize_generation = 0;
    rr.currentGeneration().resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    rr.currentGeneration().observation = .{};
    defer rr.currentGeneration().observation.deinit(allocator);

    try std.testing.expectError(
        error.Truncated,
        rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 }),
    );
    peer.join();
    try std.testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.peer_contract_violation,
        host_adapter_mod.HostAdapter.testing.rawClient(&adapter).firstPoisonReason().?,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.slot.current.cleanup_registry.count(),
    );
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.currentGeneration().attachment.generation.batch_adapter.slot_addr);
}

test "remote runtime: actual GUI metadata event is atomic across every projection allocation failure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/next/repo","window_title":"next work","ssh_remote_dest":"next-host","semantic_state":2,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":false,"observer_generation":10,"title_generation":5,"cols":132,"rows":43,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"codex"}]}}
    ;
    const event_wire = try framing.encodeFrame(
        allocator,
        .{
            .major = protocol.version_major,
            .kind = .event,
            .stream_id = 7,
        },
        payload,
    );
    defer allocator.free(event_wire);
    const response_wire = try framing.encodeFrame(
        allocator,
        .{
            .major = protocol.version_major,
            .kind = .response,
            .request_id = 1,
        },
        "{\"result\":{}}",
    );
    defer allocator.free(response_wire);
    const ParseCounter = struct {
        fn note(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };

    var saw_success = false;
    for (0..16) |fail_index| {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        defer _ = c.close(fds[1]);
        var parse_count: usize = 0;
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
            .metadata_support = .supported,
            .event_parse_observer = .{
                .context = &parse_count,
                .on_parse = ParseCounter.note,
            },
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
        rr.pending_event_owner = .{};
        rr.runtime_lifetime = .{};
        try rr.initializePendingEventOwner();
        rr.currentGeneration().attachment = .init(allocator, .{
            .runtime_id = 0xaa,
            .stream_id = 7,
            .role = .controller,
            .controller_generation = 1,
        });
        defer rr.currentGeneration().attachment.deinit();
        rr.currentGeneration().observation = .{};
        try rr.currentGeneration().observation.replace(allocator, .{
            .availability = .current,
            .revision = 2,
            .cwd = "/safe",
            .window_title = "work",
            .ssh_remote_dest = "safe-host",
            .size = .{ .cols = 120, .rows = 40 },
        });

        try socket_server.writeAll(fds[1], event_wire);
        try socket_server.writeAll(fds[1], response_wire);
        const response = try client.call("host.info", "{}");
        defer allocator.free(response);
        try std.testing.expectEqual(@as(usize, 1), parse_count);
        try std.testing.expectEqual(@as(usize, 1), client.pending_events.items.len);

        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        rr.allocator = failing.allocator();
        defer rr.currentGeneration().observation.deinit(rr.allocator);
        const drained = rr.drainObservationEvents();
        if (drained) |result| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expect(result.metadata);
            try std.testing.expectEqual(@as(u64, 3), rr.currentGeneration().observation.revision);
            try std.testing.expectEqualStrings("/next/repo", rr.currentGeneration().observation.cwd.items);
            try std.testing.expect(!client.unusable);
            try std.testing.expect(!failing.has_induced_failure);
            saw_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(u64, 2), rr.currentGeneration().observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.currentGeneration().observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.currentGeneration().observation.window_title.items);
            try std.testing.expectEqualStrings(
                "safe-host",
                rr.currentGeneration().observation.ssh_remote_dest.items,
            );
            try std.testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
        }
    }
    try std.testing.expect(saw_success);
}

const ObservationBarrierOutcome = enum { current, fail_closed };

fn expectObservationBarrierDisposition(
    response_payload: []const u8,
    outcome: ObservationBarrierOutcome,
) !void {
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    const Peer = struct {
        fn run(fd: c.fd_t, encoded_payload: []const u8) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                encoded_payload,
            ) catch return;
            defer std.heap.page_allocator.free(response);
            socket_server.writeAll(fd, response) catch return;
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response_payload });
    defer peer.join();
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .metadata_support = .supported,
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.currentGeneration().attachment.deinit();
    rr.direct_input = .empty;
    rr.input_batches = .{};
    defer rr.direct_input.deinit(allocator);
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.pending_controls.deinit(allocator);
    rr.currentGeneration().observation = .{};
    defer rr.currentGeneration().observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.currentGeneration().observation, allocator);

    switch (outcome) {
        .current => try rr.refreshObservation(),
        .fail_closed => try std.testing.expectError(
            error.ProtocolError,
            rr.refreshObservation(),
        ),
    }
    switch (outcome) {
        .current => {
            try std.testing.expect(!client.unusable);
            try std.testing.expectEqual(fds[0], client.fd);
            try std.testing.expectEqual(term_backend.ObservationAvailability.current, rr.currentGeneration().observation.availability);
            try std.testing.expectEqual(@as(u64, 3), rr.currentGeneration().observation.revision);
            try std.testing.expectEqualStrings("/fresh", rr.currentGeneration().observation.cwd.items);
            try std.testing.expectEqualStrings("fresh-title", rr.currentGeneration().observation.window_title.items);
            try std.testing.expectEqualStrings("fresh-host", rr.currentGeneration().observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.input, rr.currentGeneration().observation.semantic_state);
            try std.testing.expect(!rr.currentGeneration().observation.alt_active);
            try std.testing.expect(!rr.currentGeneration().observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 90), rr.currentGeneration().observation.size.cols);
            try std.testing.expectEqual(@as(u16, 30), rr.currentGeneration().observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 77), rr.currentGeneration().observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.currentGeneration().observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "zsh",
                rr.currentGeneration().observation.foreground_processes.items[0].slice(),
            );
        },
        .fail_closed => {
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
            try std.testing.expectEqual(@as(u64, 2), rr.currentGeneration().observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.currentGeneration().observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.currentGeneration().observation.window_title.items);
            try std.testing.expectEqualStrings("safe-host", rr.currentGeneration().observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.currentGeneration().observation.semantic_state);
            try std.testing.expect(rr.currentGeneration().observation.alt_active);
            try std.testing.expect(rr.currentGeneration().observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 120), rr.currentGeneration().observation.size.cols);
            try std.testing.expectEqual(@as(u16, 40), rr.currentGeneration().observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 55), rr.currentGeneration().observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.currentGeneration().observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "claude",
                rr.currentGeneration().observation.foreground_processes.items[0].slice(),
            );
        },
    }
}

test "remote runtime: observation barrier projects current and fail-closes malformed or resource metadata" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const current =
        \\{"result":{"metadata_revision":3,"metadata":{"cwd":"/fresh","window_title":"fresh-title","ssh_remote_dest":"fresh-host","semantic_state":2,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":10,"title_generation":5,"cols":90,"rows":30,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"zsh"}]}}}
    ;
    try expectObservationBarrierDisposition(current, .current);
    const escaped_revision = try std.mem.replaceOwned(
        u8,
        allocator,
        current,
        "metadata_revision",
        "metadata_\\u0072evision",
    );
    defer allocator.free(escaped_revision);
    try expectObservationBarrierDisposition(escaped_revision, .current);

    const malformed =
        "{\"result\":{\"metadata_revision\":3,\"metadata\":{\"cwd\":\"/partial\"}}}";
    try expectObservationBarrierDisposition(malformed, .fail_closed);
    try expectObservationBarrierDisposition(
        "{\"result\":{\"metadata_revision\":184467440737095516150,\"metadata\":null}}",
        .fail_closed,
    );
    const same_revision_equivocation =
        \\{"result":{"metadata_revision":2,"metadata":{"cwd":"/safe","window_title":"work","ssh_remote_dest":"attacker-host","semantic_state":3,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":true,"observer_generation":9,"title_generation":4,"cols":120,"rows":40,"foreground_available":true,"foreground_pgid":55,"processes":[{"pid":55,"name":"claude"}]}}}
    ;
    try expectObservationBarrierDisposition(same_revision_equivocation, .fail_closed);

    var processes: std.Io.Writer.Allocating = .init(allocator);
    defer processes.deinit();
    for (0..runtime_metadata_wire.max_process_entries + 1) |index| {
        if (index != 0) try processes.writer.writeByte(',');
        try processes.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    const resource = try std.fmt.allocPrint(
        allocator,
        "{{\"result\":{{\"metadata_revision\":3,\"metadata\":{{\"cwd\":\"/attacker\",\"window_title\":\"bad\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":1,\"processes\":[{s}]}}}}}}",
        .{processes.written()},
    );
    defer allocator.free(resource);
    try expectObservationBarrierDisposition(resource, .fail_closed);
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host에 client-side 원격 runtime을 띄우고 화면을 몬다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 원격 runtime이 client 쪽에서 **하나의 Surface**로 다뤄져야
// GUI가 in-process와 같은 코드로 렌더한다(SSOT). fork한 host에 RemoteRuntime.spawn으로 셸을 띄우면 그 Surface가 host
// 화면을 반영하고, 입력→delta→Surface 갱신이 도는지, terminate로 회수되는지 고정한다. 실 forkpty·socket이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const ReconnectGenerationTestState = if (builtin.is_test) struct {
    threadlocal var deinit_count: usize = 0;
} else struct {};

const Cr3c2OrderedReclaimTestState = if (builtin.is_test) struct {
    const Stage = enum(u8) { remote, client };
    threadlocal var armed = false;
    threadlocal var stages: [2]Stage = undefined;
    threadlocal var len: usize = 0;

    fn arm() void {
        armed = true;
        len = 0;
    }

    fn disarm() void {
        armed = false;
        len = 0;
    }

    fn recordRemote(
        owner: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
    ) void {
        if (!armed) return;
        if ((owner.slot.hasRetiring() catch true) or adapter.slot.retiredClientCount() != 1 or len != 0)
            @panic("CR3c2 remote-first reclaim ordering drifted");
        stages[len] = .remote;
        len += 1;
    }

    fn recordClient(
        owner: *ReconnectGenerationOwner,
        adapter: *host_adapter_mod.HostAdapter,
    ) void {
        if (!armed) return;
        if ((owner.slot.hasRetiring() catch true) or adapter.slot.retiredClientCount() != 0 or len != 1)
            @panic("CR3c2 client-second reclaim ordering drifted");
        stages[len] = .client;
        len += 1;
    }
} else struct {};

const Cr3c2OwnerProjection = if (builtin.is_test) struct {
    owner_incarnation: u64,
    slot_incarnation: u64,
    shell_generation: u64,
    screen_kind: stable_screen_source.TargetKind,
    screen_generation: u64,
    remote_node_addr: usize,
    remote_shell_generation: u64,
    remote_connection_generation: u64,
    remote_attachment_lifecycle_raw: u8,
    client_generation: u64,
    retired_client_addr: usize,
    retired_client_generation: u64,
    remote_deinit_count: usize,
} else struct {};

fn cr3c2OwnerProjection(
    owner: *ReconnectGenerationOwner,
    adapter: *host_adapter_mod.HostAdapter,
    proxy: *stable_screen_source.StableScreenSource,
) !Cr3c2OwnerProjection {
    if (!builtin.is_test) unreachable;
    const remote_node = owner.slot.retiring orelse return error.InvalidAuthority;
    const client_node = adapter.slot.retired[0] orelse return error.InvalidAuthority;
    return .{
        .owner_incarnation = owner.owner_incarnation,
        .slot_incarnation = owner.slot.incarnation,
        .shell_generation = try owner.currentGeneration(),
        .screen_kind = proxy.current.kind,
        .screen_generation = proxy.current.generation,
        .remote_node_addr = @intFromPtr(remote_node),
        .remote_shell_generation = remote_node.generation,
        .remote_connection_generation = remote_node.payload.connection_generation,
        .remote_attachment_lifecycle_raw = switch (remote_node.payload.attachment) {
            .generation => |attachment| @intFromEnum(attachment.lifecycle),
            .legacy => return error.InvalidAuthority,
        },
        .client_generation = adapter.connectionGeneration(),
        .retired_client_addr = @intFromPtr(client_node),
        .retired_client_generation = client_node.connection_generation,
        .remote_deinit_count = ReconnectGenerationTestState.deinit_count,
    };
}

/// CR4a starts after CR3c's irreversible forward-recovery boundary: the old attachment is
/// terminal, the stable shell is unavailable, and the fresh Client is already the adapter's
/// current generation. Observer preparation may still fail, but it must not publish a
/// RemoteGeneration or mutate the unavailable shell.
fn publishCr4aReplacementPrerequisite(
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
    source: *client_mod.Client,
    out: *r2a_client_slot.PreparedClientReplacement,
) !void {
    var admission: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(adapter.connectionGeneration(), &admission);
    const placeholder_generation = std.math.add(
        u64,
        try runtime.generation_owner.currentGeneration(),
        1,
    ) catch return error.InvalidAuthority;
    var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
    try adapter.prepareRetirementCleanup(&admission, placeholder_generation, &cleanup);
    _ = try runtime.generation_owner.publishUnavailableAfterAttachmentRetirement(
        adapter,
        &admission,
        &cleanup,
        placeholder_generation - 1,
        placeholder_generation,
    );
    try adapter.finishRetirementCleanup(&cleanup);
    try host_adapter_mod.HostAdapter.testing.publishReplacementForCr3c(
        adapter,
        &cleanup,
        source,
        out,
    );
}

fn expectCr3c2OrderedPreflightRejectPreserves(
    owner: *ReconnectGenerationOwner,
    adapter: *host_adapter_mod.HostAdapter,
    proxy: *stable_screen_source.StableScreenSource,
    prepared: *PreparedOrderedRetiringReclaim,
) !void {
    if (!builtin.is_test) unreachable;
    const owner_before = try cr3c2OwnerProjection(owner, adapter, proxy);
    const receipt_before = prepared.*;
    const deinit_before = ReconnectGenerationTestState.deinit_count;
    try testing.expectError(
        error.InvalidAuthority,
        owner.preflightOrderedRetiringReclaim(adapter, prepared),
    );
    try testing.expectEqual(owner_before, try cr3c2OwnerProjection(owner, adapter, proxy));
    try testing.expectEqual(receipt_before, prepared.*);
    try testing.expectEqual(deinit_before, ReconnectGenerationTestState.deinit_count);
}

const ReconnectGenerationTestArgs = struct {
    allocator: std.mem.Allocator,
    stream_id: u64,
    metadata: []const u8 = "",
};

const R2aTestGeneration = if (builtin.is_test) struct {
    const Args = struct {
        allocator: std.mem.Allocator,
        adapter: *host_adapter_mod.HostAdapter,
        runtime_id: u128,
        stream_id: u64,
        connection_generation: ?u64 = null,
    };

    fn init(out: *RemoteGeneration, args: Args) !void {
        out.* = .{
            .connection = .{ .generation = args.adapter },
            .connection_generation = args.connection_generation orelse args.adapter.connectionGeneration(),
            .attachment = .{ .generation = .{} },
            .event_generation_tracking = .tracked,
            .resize_seq = 0,
            .resize_generation = 0,
            .resize_baseline_present = false,
            .pump_ended = false,
            .resync_needed = false,
            .observation = .{},
        };
        try generation_attachment_mod.testing_api.initAttached(
            &out.attachment.generation,
            args.adapter,
            args.allocator,
            args.runtime_id,
            args.stream_id,
        );
        errdefer out.attachment.generation.deinit(args.adapter);
        try out.attachment.initScreen(screen_stream.codec_version);
    }
} else struct {};

const Cr4aCatchupStageCase = enum {
    success,
    barrier_only_success,
    controller_success,
    controller_allocator_reentry,
    controller_conflict,
    controller_status_buffered_revoke,
    controller_foreign,
    controller_cas_conflict,
    controller_cas_conflict_buffered_revoke,
    controller_buffered_revoke,
    controller_sent_unknown,
    controller_pre_failed,
    controller_status_resource_failed,
    controller_takeover_resource_failed,
    controller_deadline_pre,
    controller_resize_success,
    controller_resize_stale,
    controller_resize_wrong_size,
    controller_resize_eof,
    controller_resize_oom,
    generation_gap,
    malformed_delta,
    batch_cap_plus_one,
    cell_cap_plus_one,
    request_oom,
    missing_barrier,
};

fn cr4cResizeCase(selected: Cr4aCatchupStageCase) bool {
    return switch (selected) {
        .controller_resize_success,
        .controller_resize_stale,
        .controller_resize_wrong_size,
        .controller_resize_eof,
        .controller_resize_oom,
        => true,
        else => false,
    };
}

fn controllerTransferCase(selected: Cr4aCatchupStageCase) bool {
    return switch (selected) {
        .controller_success,
        .controller_allocator_reentry,
        .controller_conflict,
        .controller_status_buffered_revoke,
        .controller_foreign,
        .controller_cas_conflict,
        .controller_cas_conflict_buffered_revoke,
        .controller_buffered_revoke,
        .controller_sent_unknown,
        .controller_pre_failed,
        .controller_status_resource_failed,
        .controller_takeover_resource_failed,
        .controller_deadline_pre,
        .controller_resize_success,
        .controller_resize_stale,
        .controller_resize_wrong_size,
        .controller_resize_eof,
        .controller_resize_oom,
        => true,
        else => false,
    };
}

const ControllerTakeoverReentryAllocator = if (builtin.is_test) struct {
    parent: std.mem.Allocator,
    attachment: ?*generation_attachment_mod.GenerationAttachment = null,
    stage: ?*const catchup_stage_contract.PreparedStage = null,
    deadline: ?client_deadline.AbsoluteDeadline = null,
    armed: bool = false,
    fired: bool = false,
    rejected: bool = false,

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
        if (self.armed and !self.fired) {
            self.fired = true;
            if (self.attachment.?.executeControllerTakeoverUntil(
                self.stage.?,
                self.deadline.?,
            )) |_| {
                self.rejected = false;
            } else |err| {
                self.rejected = err == error.InvalidAuthority;
            }
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
} else struct {};

fn runCr4aCatchupStageCase(selected: Cr4aCatchupStageCase) !void {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":9,\"controller_generation\":3," ++
            "\"granted\":{\"observe\":true,\"input\":false,\"resize\":false}," ++
            "\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
    );
    defer allocator.free(response);
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&records, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "n", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&records, allocator, row);
    const snapshot = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 9,
            .flags = protocol.Flags.end_stream,
        },
        records.items,
    );
    defer allocator.free(snapshot);
    var delta_wire: std.ArrayListUnmanaged(u8) = .empty;
    defer delta_wire.deinit(allocator);
    const delta_count: u64 = if (selected == .barrier_only_success)
        0
    else if (selected == .batch_cap_plus_one)
        catchup_stage_contract.max_batches + 1
    else
        1;
    var delta_index: u64 = 0;
    while (delta_index < delta_count) : (delta_index += 1) {
        var delta_records: std.ArrayListUnmanaged(u8) = .empty;
        defer delta_records.deinit(allocator);
        if (selected == .malformed_delta) {
            try delta_records.appendSlice(allocator, "not-a-screen-record");
        } else {
            var delta_runs = [_]screen_stream.Run{.{
                .grapheme = "m",
                .width = 1,
                .count = if (selected == .cell_cap_plus_one)
                    @intCast(catchup_stage_contract.max_decoded_cells + 1)
                else
                    1,
            }};
            const sequence = if (selected == .generation_gap) 2 else delta_index + 1;
            const delta_record = try screen_stream.encodeSetRuns(
                allocator,
                .{ .kind = .set_runs, .generation = 1, .sequence = sequence },
                .{ .base_generation = 1, .row_index = 0, .start_col = 0, .runs = &delta_runs },
            );
            defer allocator.free(delta_record);
            try screen_stream.appendRecord(&delta_records, allocator, delta_record);
        }
        const delta = try framing.encodeFrame(
            allocator,
            .{ .kind = .delta_chunk, .stream_id = 9, .flags = protocol.Flags.end_stream },
            delta_records.items,
        );
        defer allocator.free(delta);
        try delta_wire.appendSlice(allocator, delta);
    }
    const request_nonce: u128 = 0x00112233445566778899aabbccddeeff;
    const catchup_identity: catchup_barrier_contract.CatchupIdentity = .{
        .subscription = .{ .value = 1 },
        .runtime_id = 0xaa,
        .connection = .{ .monotonic_id = 1, .slot_generation = 1 },
        .host_id = 0x44,
        .request_nonce = request_nonce,
    };
    const barrier_payload = try (catchup_barrier_contract.Barrier{
        .identity = catchup_identity,
        .target = .{
            .generation = 1,
            .sequence = if (selected == .barrier_only_success)
                0
            else if (selected == .generation_gap)
                2
            else if (selected == .batch_cap_plus_one)
                delta_count
            else
                1,
        },
    }).encode();
    const barrier = try framing.encodeFrame(
        allocator,
        .{ .kind = .screen_frontier_barrier, .stream_id = 9 },
        &barrier_payload,
    );
    defer allocator.free(barrier);

    const Peer = struct {
        fn run(
            fd: c.fd_t,
            response_wire: []const u8,
            snapshot_wire: []const u8,
            delta_frames_wire: []const u8,
            barrier_wire: []const u8,
            release: *std.atomic.Value(u8),
            observer_seen: *std.atomic.Value(u8),
            peer_stage: *std.atomic.Value(u8),
            peer_case: Cr4aCatchupStageCase,
        ) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const observed = request.header.kind == .request and
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") != null and
                std.mem.indexOf(u8, request.payload, "\"mode\":\"observer\"") != null;
            observer_seen.store(@intFromBool(observed), .release);
            if (!observed) return;
            peer_stage.store(1, .release);
            socket_server.writeAll(fd, response_wire) catch return;
            socket_server.writeAll(fd, snapshot_wire) catch return;
            const catchup_request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(catchup_request.payload);
            if (catchup_request.header.kind != .request or
                std.mem.indexOf(u8, catchup_request.payload, "\"method\":\"runtime.catchup\"") == null or
                std.mem.indexOf(u8, catchup_request.payload, "00112233445566778899aabbccddeeff") == null)
                return;
            peer_stage.store(2, .release);
            const catchup_response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = catchup_request.header.request_id },
                "{\"result\":{\"catchup\":\"armed\",\"stream_id\":9," ++
                    "\"request_nonce\":\"00112233445566778899aabbccddeeff\"," ++
                    "\"host_id\":\"00000000000000000000000000000044\"," ++
                    "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
                    "\"subscription_id\":\"0000000000000001\"," ++
                    "\"connection_id\":\"0000000000000001\"," ++
                    "\"connection_generation\":\"0000000000000001\"}}",
            ) catch return;
            defer std.heap.page_allocator.free(catchup_response);
            socket_server.writeAll(fd, catchup_response) catch return;
            peer_stage.store(3, .release);
            socket_server.writeAll(fd, delta_frames_wire) catch return;
            peer_stage.store(4, .release);
            if (barrier_wire.len != 0) {
                socket_server.writeAll(fd, barrier_wire) catch return;
                peer_stage.store(5, .release);
            }
            const controller_transfer = controllerTransferCase(peer_case);
            if (controller_transfer) {
                if (peer_case == .controller_deadline_pre) {
                    const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                    while (release.load(.acquire) == 0) _ = c.nanosleep(&delay, null);
                    return;
                }
                const status_request = readPeerFrame(fd, std.heap.page_allocator) catch return;
                defer std.heap.page_allocator.free(status_request.payload);
                if (status_request.header.kind != .request or
                    std.mem.indexOf(u8, status_request.payload, "\"method\":\"controller.status\"") == null)
                    return;
                const status_response = framing.encodeFrame(
                    std.heap.page_allocator,
                    .{ .kind = .response, .request_id = status_request.header.request_id },
                    if (peer_case == .controller_conflict)
                        "{\"error\":\"unauthorized\"}"
                    else if (peer_case == .controller_pre_failed)
                        "{\"result\":{}}"
                    else if (peer_case == .controller_status_resource_failed)
                        "{\"error\":\"resource_exhausted\"}"
                    else if (peer_case == .controller_foreign)
                        "{\"result\":{\"stream_id\":9,\"controller_generation\":3,\"controller\":true}}"
                    else
                        "{\"result\":{\"stream_id\":9,\"controller_generation\":3,\"controller\":false}}",
                ) catch return;
                defer std.heap.page_allocator.free(status_response);
                if (peer_case == .controller_status_buffered_revoke) {
                    const revoke_wire = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .event, .stream_id = 9 },
                        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":9,\"controller_generation\":4,\"reason\":\"takeover\"}}",
                    ) catch return;
                    defer std.heap.page_allocator.free(revoke_wire);
                    socket_server.writeAll(fd, revoke_wire) catch return;
                }
                socket_server.writeAll(fd, status_response) catch return;
                peer_stage.store(if (peer_case == .controller_status_buffered_revoke) 8 else 6, .release);
                if (peer_case == .controller_conflict or
                    peer_case == .controller_status_buffered_revoke or peer_case == .controller_foreign)
                {
                    const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                    while (release.load(.acquire) == 0) _ = c.nanosleep(&delay, null);
                    return;
                }
                if (peer_case == .controller_pre_failed or
                    peer_case == .controller_status_resource_failed) return;
                const takeover_request = readPeerFrame(fd, std.heap.page_allocator) catch return;
                defer std.heap.page_allocator.free(takeover_request.payload);
                if (takeover_request.header.kind != .request or
                    std.mem.indexOf(u8, takeover_request.payload, "\"method\":\"controller.takeover\"") == null or
                    std.mem.indexOf(u8, takeover_request.payload, "\"expected_controller_generation\":3") == null)
                    return;
                const takeover_response = framing.encodeFrame(
                    std.heap.page_allocator,
                    .{ .kind = .response, .request_id = takeover_request.header.request_id },
                    "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\"," ++
                        "\"stream_id\":9,\"controller_generation\":4,\"reason\":\"takeover\"," ++
                        "\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
                ) catch return;
                defer std.heap.page_allocator.free(takeover_response);
                if (peer_case == .controller_sent_unknown) {
                    socket_server.writeAll(fd, takeover_response[0..5]) catch return;
                    peer_stage.store(7, .release);
                    return;
                }
                if (peer_case == .controller_cas_conflict) {
                    const conflict_response = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .response, .request_id = takeover_request.header.request_id },
                        "{\"error\":\"invalid_generation\"}",
                    ) catch return;
                    defer std.heap.page_allocator.free(conflict_response);
                    socket_server.writeAll(fd, conflict_response) catch return;
                    peer_stage.store(7, .release);
                    const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                    while (release.load(.acquire) == 0) _ = c.nanosleep(&delay, null);
                    return;
                }
                if (peer_case == .controller_cas_conflict_buffered_revoke) {
                    const revoke_wire = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .event, .stream_id = 9 },
                        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":9,\"controller_generation\":4,\"reason\":\"takeover\"}}",
                    ) catch return;
                    defer std.heap.page_allocator.free(revoke_wire);
                    const conflict_response = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .response, .request_id = takeover_request.header.request_id },
                        "{\"error\":\"invalid_generation\"}",
                    ) catch return;
                    defer std.heap.page_allocator.free(conflict_response);
                    socket_server.writeAll(fd, revoke_wire) catch return;
                    socket_server.writeAll(fd, conflict_response) catch return;
                    peer_stage.store(8, .release);
                    return;
                }
                if (peer_case == .controller_takeover_resource_failed) {
                    const resource_response = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .response, .request_id = takeover_request.header.request_id },
                        "{\"error\":\"resource_exhausted\"}",
                    ) catch return;
                    defer std.heap.page_allocator.free(resource_response);
                    socket_server.writeAll(fd, resource_response) catch return;
                    peer_stage.store(7, .release);
                    return;
                }
                socket_server.writeAll(fd, takeover_response) catch return;
                peer_stage.store(7, .release);
                if (cr4cResizeCase(peer_case)) {
                    const resize_request = readPeerFrame(fd, std.heap.page_allocator) catch return;
                    defer std.heap.page_allocator.free(resize_request.payload);
                    if (resize_request.header.kind != .request or
                        std.mem.indexOf(u8, resize_request.payload, "\"method\":\"runtime.resize\"") == null or
                        std.mem.indexOf(u8, resize_request.payload, "\"cols\":80") == null or
                        std.mem.indexOf(u8, resize_request.payload, "\"rows\":24") == null)
                        return;
                    peer_stage.store(9, .release);
                    if (peer_case == .controller_resize_eof) return;
                    const resize_response = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .response, .request_id = resize_request.header.request_id },
                        if (peer_case == .controller_resize_stale)
                            "{\"result\":{\"stale\":true}}"
                        else if (peer_case == .controller_resize_wrong_size)
                            "{\"result\":{\"cols\":81,\"rows\":24,\"client_sequence\":1,\"resize_generation\":2,\"changed\":true}}"
                        else
                            "{\"result\":{\"cols\":80,\"rows\":24,\"client_sequence\":1,\"resize_generation\":2,\"changed\":true}}",
                    ) catch return;
                    defer std.heap.page_allocator.free(resize_response);
                    socket_server.writeAll(fd, resize_response) catch return;
                    peer_stage.store(10, .release);
                }
                if (peer_case == .controller_buffered_revoke) {
                    const revoke_wire = framing.encodeFrame(
                        std.heap.page_allocator,
                        .{ .kind = .event, .stream_id = 9 },
                        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":9,\"controller_generation\":4,\"reason\":\"takeover\"}}",
                    ) catch return;
                    defer std.heap.page_allocator.free(revoke_wire);
                    socket_server.writeAll(fd, revoke_wire) catch return;
                    peer_stage.store(8, .release);
                }
            }
            const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            while (release.load(.acquire) == 0) _ = c.nanosleep(&delay, null);
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var raw_client_fd_owned = true;
    var peer_fd_owned = true;
    errdefer {
        if (raw_client_fd_owned) _ = c.close(fds[0]);
        if (peer_fd_owned) _ = c.close(fds[1]);
    }
    var release = std.atomic.Value(u8).init(0);
    var observer_seen = std.atomic.Value(u8).init(0);
    var peer_stage = std.atomic.Value(u8).init(0);
    var peer = try std.Thread.spawn(.{}, Peer.run, .{
        fds[1],                                            response, snapshot,       delta_wire.items,
        if (selected == .missing_barrier) "" else barrier, &release, &observer_seen, &peer_stage,
        selected,
    });
    peer_fd_owned = false;
    defer {
        if (raw_client_fd_owned) {
            _ = c.close(fds[0]);
            raw_client_fd_owned = false;
        }
        release.store(1, .release);
        peer.join();
    }

    var old_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x44,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = controllerTransferCase(selected),
        },
        .runtime_catchup_barrier_v1 = true,
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &old_client);
    defer {
        host_adapter_mod.HostAdapter.testing.reclaimAllRetiredForCr3c(&adapter) catch
            @panic("CR4a retired Client cleanup failed");
        adapter.deinit();
    }
    var new_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x44,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = controllerTransferCase(selected),
        },
        .runtime_catchup_barrier_v1 = true,
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    raw_client_fd_owned = false;
    defer new_client.deinit();

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(allocator, std.testing.io, .{ .cols = 1, .rows = 1 });
    defer proxy.deinit();
    var reentry_allocator = ControllerTakeoverReentryAllocator{ .parent = allocator };
    const generation_allocator = if (selected == .controller_allocator_reentry)
        reentry_allocator.allocator()
    else
        allocator;
    var runtime: RemoteRuntime = undefined;
    runtime.generation_owner = .{};
    try runtime.generation_owner.initInPlace(
        allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = generation_allocator,
            .adapter = &adapter,
            .runtime_id = 0xaa,
            .stream_id = 7,
        },
        R2aTestGeneration.init,
    );
    defer runtime.generation_owner.deinit() catch
        @panic("CR4a old generation cleanup lost final owner");
    runtime.allocator = generation_allocator;
    runtime.io = std.testing.io;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    var replacement: r2a_client_slot.PreparedClientReplacement = .{};
    try publishCr4aReplacementPrerequisite(&runtime, &adapter, &new_client, &replacement);
    const unavailable_generation = try runtime.generation_owner.currentGeneration();
    const unavailable_source = proxy.current;

    var prepared: PreparedReconnect = .{};
    try runtime.prepareObserverReconnectCandidate(&adapter, &replacement, &prepared);
    defer if (prepared.lifecycle == .candidate)
        runtime.generation_owner.abort(&prepared) catch
            @panic("CR4a candidate cleanup lost final owner");
    const candidate = @constCast(try runtime.generation_owner.slot.candidatePayload(&prepared.candidate));
    try std.testing.expectEqual(@as(u8, 1), observer_seen.load(.acquire));
    try std.testing.expectEqual(r2a_client_slot.PreparedClientReplacement.Lifecycle.published, replacement.lifecycle);
    try std.testing.expectEqual(@as(u64, 2), adapter.connectionGeneration());
    switch (candidate.connection) {
        .generation => |candidate_adapter| try std.testing.expect(candidate_adapter == &adapter),
        .legacy => return error.InvalidAuthority,
    }
    try std.testing.expectEqual(remote_attachment.Role.observer, candidate.attachment.statePtr().role);
    try std.testing.expectEqual(@as(u21, 'n'), candidate.attachment.screenPtr().?.grid.cells[0].codepoint);
    var catchup_failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    const current_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    const original_client_allocator = current_client.allocator;
    if (selected == .request_oom) current_client.allocator = catchup_failing.allocator();
    defer current_client.allocator = original_client_allocator;
    var staged: ?*const catchup_stage_contract.PreparedStage = null;
    const DeadlineClock = struct {
        fn now(context: *anyopaque) i128 {
            return @as(*i128, @ptrCast(@alignCast(context))).*;
        }
    };
    var deadline_now_ns: i128 = 0;
    const catchup_deadline = if (selected == .controller_deadline_pre)
        client_deadline.AbsoluteDeadline.fromInjected(
            .{ .context = &deadline_now_ns, .now_ns = DeadlineClock.now },
            100,
        )
    else
        try client_deadline.AbsoluteDeadline.after(
            std.testing.io,
            if (selected == .missing_barrier) 100 * std.time.ns_per_ms else std.time.ns_per_s,
        );
    var prepare_error: ?anyerror = null;
    switch (candidate.attachment) {
        .generation => |*generation| {
            staged = generation.prepareCatchupStage(
                0xaa,
                request_nonce,
                catchup_deadline,
                std.testing.io,
            ) catch |err| blk: {
                prepare_error = err;
                break :blk null;
            };
        },
        .legacy => return error.InvalidAuthority,
    }
    const success_case = selected == .success or selected == .barrier_only_success or
        controllerTransferCase(selected);
    if (!success_case) {
        const expected_error: anyerror = switch (selected) {
            .generation_gap => error.GenerationGap,
            .malformed_delta => error.Truncated,
            .batch_cap_plus_one => error.BatchLimitExceeded,
            .cell_cap_plus_one => error.CellLimitExceeded,
            .request_oom => error.OutOfMemory,
            .missing_barrier => error.DeadlineExceeded,
            else => unreachable,
        };
        const expected_poison: client_poison.ConnectionReason = switch (selected) {
            .generation_gap, .malformed_delta => .frame_malformed,
            .batch_cap_plus_one, .cell_cap_plus_one => .event_queue_overflow,
            .request_oom => .local_resource_exhausted,
            .missing_barrier => .read_timeout,
            else => unreachable,
        };
        try std.testing.expectEqual(expected_error, prepare_error.?);
        try std.testing.expectEqual(expected_poison, current_client.firstPoisonReason().?);
        const expected_peer_stage: u8 = switch (selected) {
            .request_oom => 1,
            .missing_barrier => 4,
            else => 5,
        };
        var peer_stage_wait: usize = 0;
        while (peer_stage.load(.acquire) != expected_peer_stage and peer_stage_wait < 2000) : (peer_stage_wait += 1) {
            const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = c.nanosleep(&delay, null);
        }
        try std.testing.expectEqual(
            expected_peer_stage,
            peer_stage.load(.acquire),
        );
        try std.testing.expect(staged == null);
        try std.testing.expectEqual(
            @as(u21, 'n'),
            candidate.attachment.screenPtr().?.grid.cells[0].codepoint,
        );
        try std.testing.expectEqual(@as(c.fd_t, -1), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
        try std.testing.expectEqual(unavailable_generation, try runtime.generation_owner.currentGeneration());
        try std.testing.expectEqual(unavailable_source, proxy.current);
        try runtime.generation_owner.abort(&prepared);
        try std.testing.expect(runtime.generation_owner.slot.candidate == null);
        return;
    }
    try std.testing.expect(prepare_error == null);
    const staged_receipt = staged.?;
    try std.testing.expectEqual(catchup_stage_contract.Lifecycle.staged, staged_receipt.lifecycle);
    const expected_batches: u32 = if (selected == .barrier_only_success) 0 else 1;
    const expected_cells: u64 = if (selected == .barrier_only_success) 0 else 1;
    const expected_sequence: u64 = if (selected == .barrier_only_success) 0 else 1;
    const expected_codepoint: u21 = if (selected == .barrier_only_success) 'n' else 'm';
    try std.testing.expectEqual(expected_batches, staged_receipt.accounting.batches);
    try std.testing.expectEqual(expected_cells, staged_receipt.accounting.decoded_cells);
    try std.testing.expectEqual(expected_sequence, staged_receipt.target.sequence);
    try std.testing.expectEqual(expected_codepoint, candidate.attachment.screenPtr().?.grid.cells[0].codepoint);
    const controller_case = controllerTransferCase(selected);
    if (controller_case) {
        if (selected == .controller_deadline_pre)
            deadline_now_ns = catchup_deadline.expires_at_ns;
        switch (candidate.attachment) {
            .generation => |*generation| {
                if (selected == .controller_allocator_reentry) {
                    reentry_allocator.attachment = generation;
                    reentry_allocator.stage = staged_receipt;
                    reentry_allocator.deadline = catchup_deadline;
                    reentry_allocator.armed = true;
                }
                const outcome = try generation.executeControllerTakeoverUntil(
                    staged_receipt,
                    catchup_deadline,
                );
                switch (selected) {
                    .controller_success,
                    .controller_allocator_reentry,
                    .controller_resize_success,
                    .controller_resize_stale,
                    .controller_resize_wrong_size,
                    .controller_resize_eof,
                    .controller_resize_oom,
                    => switch (outcome) {
                        .new_controller_evidenced => |generation_value| {
                            if (selected == .controller_allocator_reentry) {
                                try std.testing.expect(reentry_allocator.fired);
                                try std.testing.expect(reentry_allocator.rejected);
                            }
                            try std.testing.expectEqual(@as(u64, 4), generation_value);
                            try std.testing.expectEqual(remote_attachment.Role.observer, generation.statePtr().role);
                            try std.testing.expect(generation.validateControllerEvidence(staged_receipt, 4));
                            try std.testing.expectEqual(catchup_stage_contract.Lifecycle.consumed, staged_receipt.lifecycle);
                            try std.testing.expectEqual(@as(u8, 7), peer_stage.load(.acquire));
                            if (cr4cResizeCase(selected)) {
                                try generation.promoteControllerEvidence(staged_receipt, 4);
                                try std.testing.expect(generation.validatePromotedController(staged_receipt, 4));
                                var resize_failing = std.testing.FailingAllocator.init(
                                    allocator,
                                    .{ .fail_index = 0 },
                                );
                                if (selected == .controller_resize_oom)
                                    current_client.allocator = resize_failing.allocator();
                                const resize_result = generation.forcePromotedControllerResizeUntil(
                                    staged_receipt,
                                    4,
                                    80,
                                    24,
                                    1,
                                    catchup_deadline,
                                );
                                current_client.allocator = original_client_allocator;
                                switch (selected) {
                                    .controller_resize_success => {
                                        const applied = try resize_result;
                                        try std.testing.expectEqual(@as(u64, 2), applied.resize_generation);
                                        try std.testing.expect(applied.changed);
                                        try std.testing.expectEqual(@as(u8, 10), peer_stage.load(.acquire));
                                        try generation.releasePromotedController(staged_receipt, 4);
                                    },
                                    .controller_resize_stale => {
                                        try std.testing.expectError(error.StaleResize, resize_result);
                                        try std.testing.expectEqual(@as(u8, 10), peer_stage.load(.acquire));
                                        try std.testing.expectEqual(
                                            client_poison.ConnectionReason.peer_contract_violation,
                                            current_client.firstPoisonReason().?,
                                        );
                                        try generation.releasePromotedControllerAfterTerminalTransport(staged_receipt, 4);
                                    },
                                    .controller_resize_wrong_size => {
                                        try std.testing.expectError(error.InvalidResizeResponse, resize_result);
                                        try std.testing.expectEqual(@as(u8, 10), peer_stage.load(.acquire));
                                        try std.testing.expectEqual(
                                            client_poison.ConnectionReason.peer_contract_violation,
                                            current_client.firstPoisonReason().?,
                                        );
                                        try generation.releasePromotedControllerAfterTerminalTransport(staged_receipt, 4);
                                    },
                                    .controller_resize_eof => {
                                        try std.testing.expectError(error.ConnectionClosed, resize_result);
                                        try std.testing.expectEqual(@as(u8, 9), peer_stage.load(.acquire));
                                        try std.testing.expectEqual(
                                            client_poison.ConnectionReason.connection_eof,
                                            current_client.firstPoisonReason().?,
                                        );
                                        try generation.releasePromotedControllerAfterTerminalTransport(staged_receipt, 4);
                                    },
                                    .controller_resize_oom => {
                                        try std.testing.expectError(error.OutOfMemory, resize_result);
                                        try std.testing.expectEqual(@as(u8, 7), peer_stage.load(.acquire));
                                        try std.testing.expectEqual(
                                            client_poison.ConnectionReason.local_resource_exhausted,
                                            current_client.firstPoisonReason().?,
                                        );
                                        try generation.releasePromotedControllerAfterTerminalTransport(staged_receipt, 4);
                                    },
                                    else => unreachable,
                                }
                            } else {
                                try generation.releaseControllerEvidence(staged_receipt, 4);
                            }
                            try std.testing.expect(!generation.validateControllerEvidence(staged_receipt, 4));
                            try std.testing.expectEqual(
                                generation_attachment_mod.testing_api.DeinitReadiness{
                                    .stage_idle = true,
                                    .response_terminal = true,
                                    .event_ready = true,
                                    .transport_ready = true,
                                    .batch_ready = true,
                                    .operation_idle = true,
                                    .rpc_free = true,
                                    .prepared_settled = true,
                                    .response_settled = true,
                                    .bound_drop_ready = true,
                                },
                                generation_attachment_mod.testing_api.deinitReadiness(generation, &adapter),
                            );
                        },
                        else => return error.TestUnexpectedResult,
                    },
                    .controller_conflict,
                    .controller_foreign,
                    .controller_cas_conflict,
                    => {
                        try std.testing.expect(outcome == .authority_conflict);
                        try std.testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
                        const expected_stage: u8 = switch (selected) {
                            .controller_conflict, .controller_foreign => 6,
                            .controller_cas_conflict => 7,
                            else => unreachable,
                        };
                        try std.testing.expectEqual(expected_stage, peer_stage.load(.acquire));
                        try generation.abortCatchupStage(staged_receipt);
                        try std.testing.expectEqual(
                            generation_attachment_mod.testing_api.DeinitReadiness{
                                .stage_idle = true,
                                .response_terminal = true,
                                .event_ready = true,
                                .transport_ready = true,
                                .batch_ready = true,
                                .operation_idle = true,
                                .rpc_free = true,
                                .prepared_settled = true,
                                .response_settled = true,
                                .bound_drop_ready = true,
                            },
                            generation_attachment_mod.testing_api.deinitReadiness(generation, &adapter),
                        );
                    },
                    .controller_sent_unknown => {
                        try std.testing.expect(outcome == .takeover_sent_unknown);
                        const terminal_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
                        try std.testing.expect(terminal_client.unusable);
                        try std.testing.expectEqual(
                            client_poison.ConnectionReason.frame_malformed,
                            terminal_client.firstPoisonReason().?,
                        );
                        try std.testing.expectEqual(@as(u8, 7), peer_stage.load(.acquire));
                        try generation.abortCatchupStageAfterTerminalTransport(staged_receipt);
                    },
                    .controller_buffered_revoke, .controller_cas_conflict_buffered_revoke => {
                        try std.testing.expect(outcome == .takeover_sent_unknown);
                        const terminal_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
                        try std.testing.expect(terminal_client.unusable);
                        try std.testing.expectEqual(
                            client_poison.ConnectionReason.response_correlation_lost,
                            terminal_client.firstPoisonReason().?,
                        );
                        try std.testing.expectEqual(@as(u8, 8), peer_stage.load(.acquire));
                        try generation.abortCatchupStageAfterTerminalTransport(staged_receipt);
                    },
                    .controller_pre_failed,
                    .controller_status_buffered_revoke,
                    .controller_status_resource_failed,
                    .controller_takeover_resource_failed,
                    .controller_deadline_pre,
                    => {
                        try std.testing.expect(outcome == .pre_takeover_failed);
                        const terminal_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
                        try std.testing.expect(terminal_client.unusable);
                        try std.testing.expectEqual(
                            if (selected == .controller_deadline_pre)
                                client_poison.ConnectionReason.read_timeout
                            else if (selected == .controller_status_buffered_revoke)
                                client_poison.ConnectionReason.response_correlation_lost
                            else if (selected == .controller_status_resource_failed or
                                selected == .controller_takeover_resource_failed)
                                client_poison.ConnectionReason.local_invariant_violation
                            else
                                client_poison.ConnectionReason.peer_contract_violation,
                            terminal_client.firstPoisonReason().?,
                        );
                        try std.testing.expectEqual(
                            if (selected == .controller_deadline_pre)
                                @as(u8, 5)
                            else if (selected == .controller_status_buffered_revoke)
                                @as(u8, 8)
                            else if (selected == .controller_takeover_resource_failed)
                                @as(u8, 7)
                            else
                                @as(u8, 6),
                            peer_stage.load(.acquire),
                        );
                        try generation.abortCatchupStageAfterTerminalTransport(staged_receipt);
                    },
                    else => unreachable,
                }
            },
            .legacy => return error.InvalidAuthority,
        }
        try runtime.generation_owner.abort(&prepared);
        try std.testing.expect(runtime.generation_owner.slot.candidate == null);
        return;
    }
    switch (candidate.attachment) {
        .generation => |*generation| {
            try std.testing.expect(generation.validateCatchupStage(staged_receipt, catchup_deadline));
            try std.testing.expectError(
                error.Busy,
                generation.prepareCatchupStage(
                    0xaa,
                    request_nonce + 1,
                    catchup_deadline,
                    std.testing.io,
                ),
            );
            var copied = staged_receipt.*;
            try std.testing.expect(!generation.validateCatchupStage(&copied, catchup_deadline));
            const mutable_stage = @constCast(staged_receipt);
            mutable_stage.node_incarnation +%= 1;
            try std.testing.expect(!generation.validateCatchupStage(staged_receipt, catchup_deadline));
            mutable_stage.node_incarnation -%= 1;
            mutable_stage.identity.request_nonce +%= 1;
            try std.testing.expect(!generation.validateCatchupStage(staged_receipt, catchup_deadline));
            mutable_stage.identity.request_nonce -%= 1;
            mutable_stage.snapshot.sequence +%= 1;
            try std.testing.expect(!generation.validateCatchupStage(staged_receipt, catchup_deadline));
            mutable_stage.snapshot.sequence -%= 1;
            mutable_stage.accounting.batches +%= 1;
            try std.testing.expect(!generation.validateCatchupStage(staged_receipt, catchup_deadline));
            mutable_stage.accounting.batches -%= 1;
            const lifecycle_raw: *u8 = @ptrCast(&mutable_stage.lifecycle);
            const saved_lifecycle_raw = lifecycle_raw.*;
            var invalid_lifecycle: u16 = 4;
            while (invalid_lifecycle <= std.math.maxInt(u8)) : (invalid_lifecycle += 1) {
                lifecycle_raw.* = @intCast(invalid_lifecycle);
                try std.testing.expect(!generation.validateCatchupStage(staged_receipt, catchup_deadline));
                try std.testing.expectError(
                    error.InvalidAuthority,
                    generation.abortCatchupStage(staged_receipt),
                );
                lifecycle_raw.* = saved_lifecycle_raw;
                try std.testing.expect(generation.validateCatchupStage(staged_receipt, catchup_deadline));
            }
            var expired_now = staged_receipt.deadline_expires_at_ns;
            const ExpiredClock = struct {
                fn now(context: *anyopaque) i128 {
                    return @as(*i128, @ptrCast(@alignCast(context))).*;
                }
            };
            const expired_deadline = client_deadline.AbsoluteDeadline.fromInjected(
                .{ .context = &expired_now, .now_ns = ExpiredClock.now },
                staged_receipt.deadline_expires_at_ns,
            );
            try std.testing.expect(!generation.validateCatchupStage(staged_receipt, expired_deadline));
            try generation.abortCatchupStage(staged_receipt);
            try std.testing.expectEqual(catchup_stage_contract.Lifecycle.aborted, staged_receipt.lifecycle);
            try std.testing.expectError(error.InvalidAuthority, generation.abortCatchupStage(staged_receipt));
        },
        .legacy => return error.InvalidAuthority,
    }
    try std.testing.expectEqual(unavailable_generation, try runtime.generation_owner.currentGeneration());
    try std.testing.expectEqual(unavailable_source, proxy.current);
    try runtime.generation_owner.abort(&prepared);
    try std.testing.expect(runtime.generation_owner.slot.candidate == null);
}

test "CR4a actual socket observer는 같은 adapter의 final candidate에 snapshot delta receipt를 조립한다" {
    try runCr4aCatchupStageCase(.success);
    try runCr4aCatchupStageCase(.barrier_only_success);
}

test "CR4b actual socket controller takeover는 staged observer를 controller evidence로 exact once 전환한다" {
    try runCr4aCatchupStageCase(.controller_success);
    try runCr4aCatchupStageCase(.controller_allocator_reentry);
}

test "CR4b actual socket controller takeover는 conflict unknown pre failure를 closed ledger로 봉인한다" {
    try runCr4aCatchupStageCase(.controller_conflict);
    try runCr4aCatchupStageCase(.controller_status_buffered_revoke);
    try runCr4aCatchupStageCase(.controller_foreign);
    try runCr4aCatchupStageCase(.controller_cas_conflict);
    try runCr4aCatchupStageCase(.controller_cas_conflict_buffered_revoke);
    try runCr4aCatchupStageCase(.controller_buffered_revoke);
    try runCr4aCatchupStageCase(.controller_sent_unknown);
    try runCr4aCatchupStageCase(.controller_pre_failed);
    try runCr4aCatchupStageCase(.controller_status_resource_failed);
    try runCr4aCatchupStageCase(.controller_takeover_resource_failed);
    try runCr4aCatchupStageCase(.controller_deadline_pre);
}

test "CR4c C2 actual socket forced resize는 success stale wrong size EOF OOM을 구분한다" {
    try runCr4aCatchupStageCase(.controller_resize_success);
    try runCr4aCatchupStageCase(.controller_resize_stale);
    try runCr4aCatchupStageCase(.controller_resize_wrong_size);
    try runCr4aCatchupStageCase(.controller_resize_eof);
    try runCr4aCatchupStageCase(.controller_resize_oom);
}

test "CR4a actual socket catchup hostile은 gap malformed cap plus one missing barrier를 fail close한다" {
    inline for (.{
        Cr4aCatchupStageCase.generation_gap,
        Cr4aCatchupStageCase.malformed_delta,
        Cr4aCatchupStageCase.batch_cap_plus_one,
        Cr4aCatchupStageCase.cell_cap_plus_one,
        Cr4aCatchupStageCase.request_oom,
        Cr4aCatchupStageCase.missing_barrier,
    }) |selected| try runCr4aCatchupStageCase(selected);
}

const Cr4aObserverFailure = enum { typed_reject, response_eof };

fn runCr4aObserverFailurePreservesPublishedClient(selected: Cr4aObserverFailure) !void {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const Peer = struct {
        fn run(
            fd: c.fd_t,
            mode: Cr4aObserverFailure,
            observer_seen: *std.atomic.Value(u8),
            release: *std.atomic.Value(u8),
        ) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const observed = request.header.kind == .request and
                std.mem.indexOf(u8, request.payload, "\"mode\":\"observer\"") != null;
            observer_seen.store(@intFromBool(observed), .release);
            if (!observed or mode == .response_eof) return;
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"error\":\"runtime_not_found\"}",
            ) catch return;
            defer std.heap.page_allocator.free(response);
            socket_server.writeAll(fd, response) catch return;
            const delay = c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            while (release.load(.acquire) == 0) _ = c.nanosleep(&delay, null);
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var raw_client_fd_owned = true;
    var peer_fd_owned = true;
    errdefer {
        if (raw_client_fd_owned) _ = c.close(fds[0]);
        if (peer_fd_owned) _ = c.close(fds[1]);
    }
    var observer_seen = std.atomic.Value(u8).init(0);
    var release = std.atomic.Value(u8).init(0);
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], selected, &observer_seen, &release });
    peer_fd_owned = false;
    defer {
        if (raw_client_fd_owned) {
            _ = c.close(fds[0]);
            raw_client_fd_owned = false;
        }
        release.store(1, .release);
        peer.join();
    }

    var old_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x45,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &old_client);
    defer {
        host_adapter_mod.HostAdapter.testing.reclaimAllRetiredForCr3c(&adapter) catch
            @panic("CR4a retired Client cleanup failed");
        adapter.deinit();
    }
    var new_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x45,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .metadata_support = .supported,
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    raw_client_fd_owned = false;
    defer new_client.deinit();

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(allocator, std.testing.io, .{ .cols = 1, .rows = 1 });
    defer proxy.deinit();
    var runtime: RemoteRuntime = undefined;
    runtime.generation_owner = .{};
    try runtime.generation_owner.initInPlace(
        allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = allocator,
            .adapter = &adapter,
            .runtime_id = 0xaa,
            .stream_id = 7,
        },
        R2aTestGeneration.init,
    );
    defer runtime.generation_owner.deinit() catch
        @panic("CR4a old generation cleanup lost final owner");
    runtime.allocator = allocator;
    runtime.io = std.testing.io;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    var replacement: r2a_client_slot.PreparedClientReplacement = .{};
    try publishCr4aReplacementPrerequisite(&runtime, &adapter, &new_client, &replacement);
    const unavailable_generation = try runtime.generation_owner.currentGeneration();
    const unavailable_source = proxy.current;
    const published_node_addr = @intFromPtr(adapter.slot.current);
    const published_generation = adapter.connectionGeneration();
    const retired_count = adapter.slot.retiredClientCount();
    var prepared: PreparedReconnect = .{};
    try std.testing.expectError(switch (selected) {
        .typed_reject => error.ObserverAttachRejected,
        .response_eof => error.ObserverAttachConnectionFailed,
    }, runtime.prepareObserverReconnectCandidate(&adapter, &replacement, &prepared));
    try std.testing.expectEqual(@as(u8, 1), observer_seen.load(.acquire));
    try std.testing.expectEqual(PreparedReconnect{}, prepared);
    try std.testing.expect(runtime.generation_owner.slot.candidate == null);
    try std.testing.expectEqual(unavailable_generation, try runtime.generation_owner.currentGeneration());
    try std.testing.expectEqual(unavailable_source, proxy.current);
    try std.testing.expectEqual(published_node_addr, @intFromPtr(adapter.slot.current));
    try std.testing.expectEqual(r2a_client_slot.PreparedClientReplacement.Lifecycle.published, replacement.lifecycle);
    try std.testing.expectEqual(published_generation, adapter.connectionGeneration());
    try std.testing.expectEqual(retired_count, adapter.slot.retiredClientCount());
    switch (selected) {
        .typed_reject => {
            try std.testing.expect(adapter.slot.current.client.fd >= 0);
            try std.testing.expect(!adapter.slot.current.client.unusable);
        },
        .response_eof => {
            try std.testing.expectEqual(@as(c.fd_t, -1), adapter.slot.current.client.fd);
            try std.testing.expect(adapter.slot.current.client.unusable);
        },
    }
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
}

test "CR4a observer 실패는 typed reject와 EOF에서 unavailable shell과 새 Client를 보존한다" {
    try runCr4aObserverFailurePreservesPublishedClient(.typed_reject);
    try runCr4aObserverFailurePreservesPublishedClient(.response_eof);
}

const ReconnectResidentLedger = if (builtin.is_test) struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    live_allocations: usize = 0,
    peak_allocations: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
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
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        ) orelse return null;
        self.live_bytes = std.math.add(usize, self.live_bytes, len) catch
            @panic("reconnect resident byte ledger overflow");
        self.live_allocations = std.math.add(usize, self.live_allocations, 1) catch
            @panic("reconnect resident allocation ledger overflow");
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        self.peak_allocations = @max(self.peak_allocations, self.live_allocations);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        )) return false;
        self.adjustResize(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.adjustResize(memory.len, new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.live_bytes < memory.len or self.live_allocations == 0)
            @panic("reconnect resident ledger underflow");
        self.live_bytes -= memory.len;
        self.live_allocations -= 1;
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }

    fn adjustResize(self: *@This(), old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.live_bytes = std.math.add(usize, self.live_bytes, new_len - old_len) catch
                @panic("reconnect resident resize ledger overflow");
        } else {
            if (self.live_bytes < old_len - new_len)
                @panic("reconnect resident resize ledger underflow");
            self.live_bytes -= old_len - new_len;
        }
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }
} else struct {};

fn reconnectCandidateResidentBytes() !usize {
    return switch (builtin.mode) {
        .Debug => 3568,
        .ReleaseFast => 3552,
        else => error.SkipZigTest,
    };
}

fn initReconnectTestGeneration(
    out: *RemoteGeneration,
    args: ReconnectGenerationTestArgs,
) !void {
    out.* = .{
        .connection = .{ .legacy = @ptrFromInt(@alignOf(client_mod.Client)) },
        .attachment = .init(args.allocator, .{
            .runtime_id = 0xA001,
            .stream_id = args.stream_id,
            .role = .controller,
            .controller_generation = args.stream_id,
        }),
        .event_generation_tracking = .tracked,
        .resize_seq = args.stream_id,
        .resize_generation = args.stream_id,
        .resize_baseline_present = true,
        .pump_ended = false,
        .resync_needed = false,
        .observation = .{},
    };
    errdefer out.attachment.deinit();
    try out.attachment.initScreen(screen_stream.codec_version);
    if (args.metadata.len != 0) {
        try out.observation.replace(args.allocator, .{
            .availability = .current,
            .revision = args.stream_id,
            .observer_generation = args.stream_id,
            .title_generation = @intCast(args.stream_id),
            .size = .{ .cols = 80, .rows = 24 },
            .cwd = args.metadata,
        });
    }
}

pub const rss_testing_api = if (builtin.is_test) struct {
    const resident_budget = @import("reconnect_resident_budget.zig");
    pub const owner_count: usize = resident_budget.max_entries;
    pub const max_entry_bytes: usize = resident_budget.max_entry_bytes;
    pub const max_tracked_bytes: usize = resident_budget.max_tracked_bytes;
    pub const metadata_bytes_per_generation: usize = 128 * 1024;

    const Fixture = struct {
        proxy: stable_screen_source.StableScreenSource = undefined,
        owner: ReconnectGenerationOwner = .{},
        prepared: PreparedReconnect = .{},
        proxy_initialized: bool = false,
        initialized: bool = false,
        pressured: bool = false,
    };

    pub const Snapshot = extern struct {
        generation_count: u64,
        live_bytes: u64,
        peak_bytes: u64,
        live_allocations: u64,
        peak_allocations: u64,
    };

    pub const Workload = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        ledger: ReconnectResidentLedger,
        metadata: []u8,
        fixtures: []Fixture,

        pub fn initInPlace(self: *Workload, allocator: std.mem.Allocator, io: std.Io) !void {
            const metadata = try allocator.alloc(u8, metadata_bytes_per_generation);
            errdefer allocator.free(metadata);
            @memset(metadata, 'r');
            const fixtures = try allocator.alloc(Fixture, owner_count);
            errdefer allocator.free(fixtures);
            for (fixtures) |*fixture| fixture.* = .{};
            self.* = .{
                .allocator = allocator,
                .io = io,
                .ledger = .{ .parent = allocator },
                .metadata = metadata,
                .fixtures = fixtures,
            };
            errdefer self.deinit();
            for (self.fixtures, 0..) |*fixture, index| {
                try fixture.proxy.initUnavailableInPlace(
                    allocator,
                    io,
                    .{ .cols = 80, .rows = 24 },
                );
                fixture.proxy_initialized = true;
                fixture.owner = .{};
                fixture.prepared = .{};
                fixture.initialized = false;
                fixture.pressured = false;
                try fixture.owner.initInPlace(
                    self.ledger.allocator(),
                    &fixture.proxy,
                    2,
                    ReconnectGenerationTestArgs{
                        .allocator = self.ledger.allocator(),
                        .stream_id = @as(u64, @intCast(0xE320 + index * 2)),
                        .metadata = self.metadata,
                    },
                    initReconnectTestGeneration,
                );
                fixture.initialized = true;
            }
        }

        pub fn pressure(self: *Workload) !void {
            for (self.fixtures, 0..) |*fixture, index| {
                if (!fixture.initialized or fixture.pressured) return error.InvalidState;
                try fixture.owner.prepare(
                    &fixture.prepared,
                    ReconnectGenerationTestArgs{
                        .allocator = self.ledger.allocator(),
                        .stream_id = @as(u64, @intCast(0xE321 + index * 2)),
                        .metadata = self.metadata,
                    },
                    initReconnectTestGeneration,
                );
                errdefer fixture.owner.abort(&fixture.prepared) catch
                    @panic("RSS candidate abort failed");
                try fixture.owner.publish(&fixture.prepared);
                fixture.pressured = true;
            }
        }

        pub fn snapshot(self: *const Workload) Snapshot {
            var generation_count: u64 = 0;
            for (self.fixtures) |fixture| {
                if (fixture.initialized) generation_count += 1;
                if (fixture.pressured) generation_count += 1;
            }
            return .{
                .generation_count = generation_count,
                .live_bytes = @intCast(self.ledger.live_bytes),
                .peak_bytes = @intCast(self.ledger.peak_bytes),
                .live_allocations = @intCast(self.ledger.live_allocations),
                .peak_allocations = @intCast(self.ledger.peak_allocations),
            };
        }

        pub fn deinitAndSnapshot(self: *Workload) Snapshot {
            for (self.fixtures) |*fixture| {
                if (fixture.initialized) {
                    if (!std.meta.eql(fixture.prepared, PreparedReconnect{}))
                        fixture.owner.abort(&fixture.prepared) catch
                            @panic("RSS candidate cleanup failed");
                    if (fixture.pressured) {
                        fixture.owner.reclaimRetiring() catch
                            @panic("RSS retiring cleanup failed");
                        fixture.pressured = false;
                    }
                    deinitReconnectTestOwner(&fixture.owner, &fixture.proxy);
                    fixture.initialized = false;
                    fixture.proxy_initialized = false;
                } else if (fixture.proxy_initialized) {
                    _ = fixture.proxy.close() catch
                        @panic("RSS proxy cleanup failed");
                    fixture.proxy.deinit();
                    fixture.proxy_initialized = false;
                }
            }
            const final = self.snapshot();
            if (final.generation_count != 0 or final.live_bytes != 0 or
                final.live_allocations != 0)
                @panic("RSS workload ledger did not reach final zero");
            self.allocator.free(self.fixtures);
            self.allocator.free(self.metadata);
            self.* = undefined;
            return final;
        }

        pub fn deinit(self: *Workload) void {
            _ = self.deinitAndSnapshot();
        }
    };
} else struct {};

test "CR2e-e3a2 RSS workload는 64 current와 candidate retiring 압력을 ledger final zero로 회수한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var workload: rss_testing_api.Workload = undefined;
    // 대량 실제 세대의 목적은 제품 allocator RSS를 재는 것이므로 DebugAllocator를
    // 거치지 않는다. 논리 누수는 workload ledger의 final-zero가 별도로 닫는다.
    try workload.initInPlace(std.heap.c_allocator, testing.io);
    var workload_live = true;
    defer if (workload_live) workload.deinit();

    const baseline = workload.snapshot();
    try testing.expectEqual(@as(u64, rss_testing_api.owner_count), baseline.generation_count);
    try testing.expect(baseline.live_bytes != 0);
    try testing.expect(baseline.live_allocations != 0);

    try workload.pressure();
    const pressure = workload.snapshot();
    try testing.expectEqual(@as(u64, rss_testing_api.owner_count * 2), pressure.generation_count);
    try testing.expect(pressure.live_bytes > baseline.live_bytes);
    try testing.expect(pressure.live_allocations > baseline.live_allocations);
    try testing.expect(pressure.peak_bytes >= pressure.live_bytes);
    try testing.expect(pressure.peak_allocations >= pressure.live_allocations);

    const final = workload.deinitAndSnapshot();
    workload_live = false;
    try testing.expectEqual(@as(u64, 0), final.generation_count);
    try testing.expectEqual(@as(u64, 0), final.live_bytes);
    try testing.expectEqual(@as(u64, 0), final.live_allocations);
}

fn failReconnectTestGeneration(
    _: *RemoteGeneration,
    _: ReconnectGenerationTestArgs,
) error{InjectedFailure}!void {
    return error.InjectedFailure;
}

fn reconnectTestWork(shell_generation: u64) reconnect_reducer.Work {
    return .{
        .job_generation = 3,
        .shell_generation = shell_generation,
        .attempt = 1,
        .candidate_connection_generation = 2,
        .deadline_ns = 100,
    };
}

fn reconnectTestRetry(shell_generation: u64) reconnect_reducer.RetryReservation {
    return .{ .row_id = 7, .generation = 11, .shell_generation = shell_generation };
}

fn deinitReconnectTestOwner(
    owner: *ReconnectGenerationOwner,
    proxy: *stable_screen_source.StableScreenSource,
) void {
    owner.deinit() catch @panic("test reconnect owner deinit failed");
    proxy.deinit();
}

fn readReconnectOwnerFromForeignThread(
    owner: *ReconnectGenerationOwner,
    rejected: *std.atomic.Value(bool),
) void {
    _ = owner.currentGeneration() catch |err| {
        rejected.store(err == error.InvalidAuthority, .release);
        return;
    };
}

test "CR2e-d PreparedReconnect는 실제 generation과 screen target을 한 번에 게시하고 old를 exact once retire한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    ReconnectGenerationTestState.deinit_count = 0;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x11 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);

    var prepared: PreparedReconnect = .{};
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x22 },
        initReconnectTestGeneration,
    );
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 2), proxy.current.generation);
    try owner.publish(&prepared);
    try testing.expectEqual(@as(u64, 3), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 3), proxy.current.generation);
    try testing.expect(try owner.slot.hasRetiring());
    try testing.expectEqual(@as(usize, 0), ReconnectGenerationTestState.deinit_count);
    try testing.expectError(error.Busy, owner.deinit());
    try testing.expectEqual(@as(u64, 3), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 3), proxy.current.generation);
    try owner.reclaimRetiring();
    try testing.expect(!try owner.slot.hasRetiring());
    try testing.expectEqual(@as(usize, 1), ReconnectGenerationTestState.deinit_count);
}

fn runCr3cC1PublicationCase(host_id: u128, hostile: bool, ordered_reclaim: bool) !void {
    if (ordered_reclaim) ReconnectGenerationTestState.deinit_count = 0;
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var old_pair: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &old_pair));
    defer _ = c.close(old_pair[1]);
    var initial: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = old_pair[0],
        .host_id = host_id,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &initial);
    var adapter_live = true;
    defer if (adapter_live) {
        host_adapter_mod.HostAdapter.testing.reclaimAllRetiredForCr3c(&adapter) catch
            @panic("CR3c1 fixture retired Client cleanup failed");
        adapter.deinit();
    };

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    var proxy_live = true;
    defer if (proxy_live) {
        _ = proxy.close() catch null;
        proxy.deinit();
    };
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = host_id,
            .stream_id = 7,
            .connection_generation = 1,
        },
        R2aTestGeneration.init,
    );
    var reconnect: PreparedReconnect = .{};
    var reconnect_prepared = false;
    var owner_live = true;
    defer if (owner_live) {
        if (reconnect_prepared) owner.abort(&reconnect) catch
            @panic("CR3c1 fixture RemoteGeneration abort failed");
        if (owner.slot.hasRetiring() catch false) owner.reclaimRetiring() catch
            @panic("CR3c1 fixture retiring RemoteGeneration cleanup failed");
        owner.deinit() catch @panic("CR3c1 fixture owner cleanup failed");
    };

    var admission: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(1, &admission);
    var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
    try adapter.prepareRetirementCleanup(&admission, 3, &cleanup);
    if (hostile) {
        const current_payload = @constCast(try owner.slot.currentPayload());
        current_payload.attachment.generation.response.lifecycle = .accepted;
        try testing.expectError(
            error.Busy,
            owner.publishUnavailableAfterAttachmentRetirement(
                &adapter,
                &admission,
                &cleanup,
                2,
                3,
            ),
        );
        try testing.expectEqual(stable_screen_source.TargetKind.live, proxy.current.kind);
        current_payload.attachment.generation.response.lifecycle = .terminal;
        var copied_admission = admission;
        const screen_before = proxy.current;
        try testing.expectError(
            error.InvalidOwner,
            owner.publishUnavailableAfterAttachmentRetirement(
                &adapter,
                &copied_admission,
                &cleanup,
                2,
                3,
            ),
        );
        try testing.expect(std.meta.eql(screen_before, proxy.current));
        try testing.expectEqual(@as(u64, 1), adapter.connectionGeneration());
    }
    _ = try owner.publishUnavailableAfterAttachmentRetirement(
        &adapter,
        &admission,
        &cleanup,
        2,
        3,
    );
    try adapter.finishRetirementCleanup(&cleanup);
    try testing.expectEqual(stable_screen_source.TargetKind.unavailable, proxy.current.kind);
    try testing.expectEqual(@as(u64, 3), proxy.current.generation);

    var new_pair: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &new_pair));
    defer _ = c.close(new_pair[1]);
    var replacement_source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = new_pair[0],
        .host_id = host_id,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var replacement: r2a_client_slot.PreparedClientReplacement = .{};
    try host_adapter_mod.HostAdapter.testing.publishReplacementForCr3c(
        &adapter,
        &cleanup,
        &replacement_source,
        &replacement,
    );
    try testing.expectEqual(@as(u64, 2), adapter.connectionGeneration());
    try testing.expectEqual(@as(usize, 1), adapter.slot.retiredClientCount());

    try owner.prepareAfterClientReplacement(
        &adapter,
        &replacement,
        &reconnect,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = host_id,
            .stream_id = 0xC3C102,
            .connection_generation = 2,
        },
        R2aTestGeneration.init,
    );
    reconnect_prepared = true;

    if (hostile) {
        const shell_before = try owner.currentGeneration();
        const screen_before = proxy.current;
        const client_generation_before = adapter.connectionGeneration();
        const retired_before = adapter.slot.retiredClientCount();
        var copied = reconnect;
        try testing.expectError(
            error.InvalidAuthority,
            owner.publishAfterClientReplacement(&adapter, &copied, &replacement),
        );
        var copied_receipt = replacement;
        try testing.expectError(
            error.InvalidOwner,
            owner.publishAfterClientReplacement(&adapter, &reconnect, &copied_receipt),
        );
        var foreign_client: client_mod.Client = .{
            .allocator = testing.allocator,
            .fd = -1,
            .host_id = host_id + 1,
            .parser = framing.FrameParser.init(testing.allocator),
        };
        var foreign_adapter: host_adapter_mod.HostAdapter = undefined;
        try host_adapter_mod.HostAdapter.initInPlace(
            &foreign_adapter,
            testing.allocator,
            &foreign_client,
        );
        defer foreign_adapter.deinit();
        try testing.expectError(
            error.InvalidOwner,
            owner.publishAfterClientReplacement(&foreign_adapter, &reconnect, &replacement),
        );
        const candidate = @constCast(try owner.slot.candidatePayload(&reconnect.candidate));
        candidate.connection_generation = 3;
        try testing.expectError(
            error.InvalidAuthority,
            owner.publishAfterClientReplacement(&adapter, &reconnect, &replacement),
        );
        candidate.connection_generation = 2;
        try testing.expectEqual(shell_before, try owner.currentGeneration());
        try testing.expect(std.meta.eql(screen_before, proxy.current));
        try testing.expectEqual(client_generation_before, adapter.connectionGeneration());
        try testing.expectEqual(retired_before, adapter.slot.retiredClientCount());
    }

    try owner.publishAfterClientReplacement(&adapter, &reconnect, &replacement);
    reconnect_prepared = false;
    try testing.expectEqual(@as(u64, 3), try owner.currentGeneration());
    try testing.expectEqual(stable_screen_source.TargetKind.live, proxy.current.kind);
    try testing.expectEqual(@as(u64, 3), proxy.current.generation);
    try testing.expect(try owner.slot.hasRetiring());
    const current_payload = try owner.slot.currentPayload();
    try testing.expectEqual(@as(u64, 2), current_payload.connection_generation);
    try testing.expectEqual(@as(u64, 2), adapter.connectionGeneration());
    try testing.expectEqual(@as(usize, 1), adapter.slot.retiredClientCount());

    if (ordered_reclaim) {
        var ordered: PreparedOrderedRetiringReclaim = .{};
        if (hostile) {
            const retiring = &owner.slot.retiring.?.payload;
            const before = try cr3c2OwnerProjection(&owner, &adapter, &proxy);
            switch (retiring.attachment) {
                .generation => |*attachment| {
                    attachment.lifecycle = .shell;
                    try testing.expectError(
                        error.NotReady,
                        owner.prepareOrderedRetiringReclaim(&adapter, &ordered),
                    );
                    attachment.lifecycle = .terminal;
                },
                .legacy => unreachable,
            }
            try testing.expectEqual(PreparedOrderedRetiringReclaim{}, ordered);
            try testing.expectEqual(before, try cr3c2OwnerProjection(&owner, &adapter, &proxy));
            const saved_generation = retiring.connection_generation;
            retiring.connection_generation = saved_generation + 1;
            const mismatch_before = try cr3c2OwnerProjection(&owner, &adapter, &proxy);
            try testing.expectError(
                error.InvalidAuthority,
                owner.prepareOrderedRetiringReclaim(&adapter, &ordered),
            );
            try testing.expectEqual(PreparedOrderedRetiringReclaim{}, ordered);
            try testing.expectEqual(mismatch_before, try cr3c2OwnerProjection(&owner, &adapter, &proxy));
            retiring.connection_generation = saved_generation;
        }
        try owner.prepareOrderedRetiringReclaim(&adapter, &ordered);
        if (hostile) {
            var copied = ordered;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &copied);
            const saved_pid = ordered.pid;
            ordered.pid +%= 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            ordered.pid = saved_pid;
            const saved_incarnation = owner.owner_incarnation;
            owner.owner_incarnation += 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            owner.owner_incarnation = saved_incarnation;
            const saved_nonce = ordered.process_nonce;
            ordered.process_nonce +%= 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            ordered.process_nonce = saved_nonce;
            const lifecycle_raw: *u8 = @ptrCast(&ordered.lifecycle);
            const saved_lifecycle = lifecycle_raw.*;
            lifecycle_raw.* = 0xff;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            lifecycle_raw.* = saved_lifecycle;
            const saved_remote_active = ordered.remote.active_raw;
            ordered.remote.active_raw = 0xff;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            ordered.remote.active_raw = saved_remote_active;
            const saved_slot_incarnation = ordered.remote.slot_incarnation;
            ordered.remote.slot_incarnation +%= 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            ordered.remote.slot_incarnation = saved_slot_incarnation;
            const saved_node_incarnation = ordered.remote.node_incarnation;
            ordered.remote.node_incarnation +%= 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            ordered.remote.node_incarnation = saved_node_incarnation;
            const retiring = @constCast(try owner.slot.retiringPayload(&ordered.remote));
            retiring.connection_generation += 1;
            try expectCr3c2OrderedPreflightRejectPreserves(&owner, &adapter, &proxy, &ordered);
            retiring.connection_generation -= 1;
        }
        ordered = .{};
        Cr3c2OrderedReclaimTestState.arm();
        defer Cr3c2OrderedReclaimTestState.disarm();
        var executor: ReconnectProductExecutor = .{};
        try executor.initInPlace(&owner, 3);
        var executor_live = true;
        defer if (executor_live)
            executor.deinit(&owner) catch @panic("CR3c2 executor cleanup failed");
        executor.state = .{
            .phase = .{ .publishing = reconnectTestWork(2) },
            .ledger = .new_controller_evidenced,
            .local = .published_new,
            .mutation = .open,
            .close = .{ .none = {} },
            .shell_generation = 3,
            .retry = null,
        };
        try executor.completeJob(&owner, .{
            .job_generation = 3,
            .total = 1,
            .published_new = 1,
            .frozen_unavailable = 0,
            .ended = 0,
            .retry_reserved = 0,
        });
        try executor.deinit(&owner);
        executor_live = false;
        try testing.expectEqual(@as(usize, 2), Cr3c2OrderedReclaimTestState.len);
        try testing.expectEqual(Cr3c2OrderedReclaimTestState.Stage.remote, Cr3c2OrderedReclaimTestState.stages[0]);
        try testing.expectEqual(Cr3c2OrderedReclaimTestState.Stage.client, Cr3c2OrderedReclaimTestState.stages[1]);
        try testing.expectEqual(@as(usize, 1), ReconnectGenerationTestState.deinit_count);
    } else {
        try owner.reclaimRetiring();
        try host_adapter_mod.HostAdapter.testing.reclaimAllRetiredForCr3c(&adapter);
    }
    try testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
    try owner.deinit();
    owner_live = false;
    proxy.deinit();
    proxy_live = false;
    adapter.deinit();
    adapter_live = false;
}

test "CR3c C1은 published Client와 RemoteGeneration placeholder를 같은 세대로 승격한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try runCr3cC1PublicationCase(0xC3C1001, false, false);
}

test "CR3c C1은 copied receipt와 connection generation drift를 mutation 없이 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try runCr3cC1PublicationCase(0xC3C1002, true, false);
}

test "CR3c C2는 matching RemoteGeneration 뒤 retired Client를 같은 tick에서 회수한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try runCr3cC1PublicationCase(0xC3C2001, false, true);
}

test "CR3c C2는 generation mismatch와 copied receipt를 파괴 없이 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try runCr3cC1PublicationCase(0xC3C2002, true, true);
}

test "CR3b R2a RemoteGeneration owner는 placeholder와 Client tombstone을 원자 게시한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC3B2A1,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &source);
    defer adapter.deinit();

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    errdefer {
        _ = proxy.close() catch @panic("R2a proxy failure cleanup lost owner");
        proxy.deinit();
    }
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = 0xC3B2A1,
            .stream_id = 0xC3B2A2,
        },
        R2aTestGeneration.init,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);

    var permit: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(1, &permit);
    try adapter.commitAdmissionClose(&permit);
    const client_before = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    try testing.expectEqual(fds[0], client_before.fd);
    try testing.expect(!client_before.unusable);
    try testing.expect(client_before.first_poison_reason == null);
    const retired = try owner.publishUnavailableForClientRetirement(&adapter, &permit, 2, 3);
    try testing.expectEqual(stable_screen_source.TargetKind.live, retired.kind);
    try testing.expectEqual(@as(u64, 2), retired.generation);
    try testing.expectEqual(r2a_client_slot.PreparedAdmissionClose.Lifecycle.consumed, permit.lifecycle);
    const projection = r2a_client_slot.testing.retirementProjection(&adapter.slot);
    try testing.expectEqual(r2a_client_slot.AdmissionLifecycle.closed, projection.admission);
    try testing.expectEqual(r2a_client_slot.RetirementLifecycle.detached, projection.retirement);
    try testing.expectEqual(@as(u64, 3), projection.placeholder_generation);
    try testing.expectEqual(@as(u64, 1), projection.connection_generation);
    const client_after = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    try testing.expectEqual(fds[0], client_after.fd);
    try testing.expect(!client_after.unusable);
    try testing.expect(client_after.first_poison_reason == null);
    try proxy.tryLock(testing.io);
    defer proxy.unlockPinned(testing.io);
    try testing.expectEqual(@as(u21, '['), proxy.screenSource().vtable.render_snapshot(
        proxy.screenSource().ctx,
    ).cells[0].codepoint);
}

test "CR3b R2a RemoteGeneration preflight 실패는 proxy와 Client permit을 변경하지 않는다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0xC3B2A2,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &source);
    defer adapter.deinit();
    var foreign_source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0xC3B2AF,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var foreign_adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&foreign_adapter, testing.allocator, &foreign_source);
    defer foreign_adapter.deinit();
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    errdefer {
        _ = proxy.close() catch @panic("R2a proxy failure cleanup lost owner");
        proxy.deinit();
    }
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = 0xC3B2B1,
            .stream_id = 0xC3B2B2,
        },
        R2aTestGeneration.init,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);

    var permit: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(1, &permit);
    try adapter.commitAdmissionClose(&permit);
    const before = permit;
    try testing.expectError(
        error.InvalidAuthority,
        owner.publishUnavailableForClientRetirement(&adapter, &permit, 3, 4),
    );
    try testing.expect(std.meta.eql(before, permit));
    const projection = r2a_client_slot.testing.retirementProjection(&adapter.slot);
    try testing.expectEqual(r2a_client_slot.RetirementLifecycle.live, projection.retirement);
    try testing.expectEqual(@as(u64, 0), projection.placeholder_generation);
    try adapter.cancelAdmissionClose(&permit);

    var foreign_permit: r2a_client_slot.PreparedAdmissionClose = .{};
    try foreign_adapter.prepareAdmissionClose(1, &foreign_permit);
    try foreign_adapter.commitAdmissionClose(&foreign_permit);
    const foreign_before = foreign_permit;
    try testing.expectError(
        error.InvalidAuthority,
        owner.publishUnavailableForClientRetirement(&foreign_adapter, &foreign_permit, 2, 3),
    );
    try testing.expect(std.meta.eql(foreign_before, foreign_permit));
    const foreign_projection = r2a_client_slot.testing.retirementProjection(&foreign_adapter.slot);
    try testing.expectEqual(r2a_client_slot.RetirementLifecycle.live, foreign_projection.retirement);
    try testing.expectEqual(@as(u64, 0), foreign_projection.placeholder_generation);
    try foreign_adapter.cancelAdmissionClose(&foreign_permit);
}

test "CR3b R2b cleanup handle은 fd와 pending frame을 gate 밖에서 exact once 정산한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC3B2B3,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &source);
    defer adapter.deinit();
    const pending = try testing.allocator.dupe(u8, "r2b-pending-frame");
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound = .{
        .frame = pending,
        .stream_id = 0xB201,
        .offset = 3,
    };

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    errdefer {
        _ = proxy.close() catch @panic("R2b proxy failure cleanup lost owner");
        proxy.deinit();
    }
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = 0xC3B2B3,
            .stream_id = 0xC3B2B4,
        },
        R2aTestGeneration.init,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);

    var permit: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(1, &permit);
    try adapter.commitAdmissionClose(&permit);
    var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
    try adapter.prepareRetirementCleanup(&permit, 3, &cleanup);
    var cleanup_finished = false;
    defer if (!cleanup_finished) {
        if (cleanup.lifecycle == .prepared) {
            adapter.abortRetirementCleanup(&cleanup) catch
                @panic("R2b prepared cleanup fallback failed");
        } else if (cleanup.lifecycle == .committed) {
            adapter.finishRetirementCleanup(&cleanup) catch
                @panic("R2b committed cleanup fallback failed");
        }
    };
    const retired = try owner.publishUnavailableForClientRetirementWithCleanup(
        &adapter,
        &permit,
        &cleanup,
        2,
        3,
    );
    try testing.expectEqual(stable_screen_source.TargetKind.live, retired.kind);
    try testing.expectEqual(r2a_client_slot.PreparedRetirementCleanup.Lifecycle.committed, cleanup.lifecycle);
    const detached = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    try testing.expect(detached.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), detached.fd);
    try testing.expect(detached.pending_outbound == null);
    try testing.expect(detached.first_poison_reason == null);
    try testing.expect(c.fcntl(fds[0], c.F.GETFD) >= 0);
    try adapter.finishRetirementCleanup(&cleanup);
    cleanup_finished = true;
    try testing.expectEqual(r2a_client_slot.PreparedRetirementCleanup.Lifecycle.consumed, cleanup.lifecycle);
    try testing.expectEqual(@as(usize, 0), cleanup.allocator_ptr);
    try testing.expectEqual(@as(usize, 0), cleanup.allocator_vtable);
    try testing.expectEqual(@as(usize, 0), cleanup.pending_frame_addr);
    try testing.expectEqual(@as(c.fd_t, -1), cleanup.fd);
    const closed_rc = c.fcntl(fds[0], c.F.GETFD);
    try testing.expect(closed_rc < 0);
    try testing.expectEqual(posix.E.BADF, posix.errno(closed_rc));
    try testing.expectError(error.InvalidOwner, adapter.finishRetirementCleanup(&cleanup));
}

test "CR3b R2b cleanup handle은 external pump reservation을 commit 뒤에만 정산한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC3B2B5,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &source);
    defer adapter.deinit();
    const client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);

    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    errdefer {
        _ = proxy.close() catch @panic("R2b external proxy failure cleanup lost owner");
        proxy.deinit();
    }
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = 0xC3B2B5,
            .stream_id = 0xC3B2B6,
        },
        R2aTestGeneration.init,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);
    try r2a_client_slot.testing.enterExternalMode(&adapter.slot);
    {
        var aborted_permit: r2a_client_slot.PreparedAdmissionClose = .{};
        try adapter.prepareAdmissionClose(1, &aborted_permit);
        try adapter.commitAdmissionClose(&aborted_permit);
        var permit_cancelled = false;
        defer if (!permit_cancelled) {
            adapter.cancelAdmissionClose(&aborted_permit) catch
                @panic("R2b external abort admission fallback failed");
        };
        var aborted_cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
        try adapter.prepareRetirementCleanup(&aborted_permit, 3, &aborted_cleanup);
        var cleanup_aborted = false;
        defer if (!cleanup_aborted) {
            adapter.abortRetirementCleanup(&aborted_cleanup) catch
                @panic("R2b external abort cleanup fallback failed");
        };
        try testing.expectEqual(@as(u8, 1), aborted_cleanup.external_deinit_reserved_raw);
        try adapter.abortRetirementCleanup(&aborted_cleanup);
        cleanup_aborted = true;
        try adapter.cancelAdmissionClose(&aborted_permit);
        permit_cancelled = true;
        try testing.expect(client.io_mode == .external);
    }

    var permit: r2a_client_slot.PreparedAdmissionClose = .{};
    var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
    try adapter.prepareAdmissionClose(1, &permit);
    try adapter.commitAdmissionClose(&permit);
    var permit_settled = false;
    defer if (!permit_settled and permit.lifecycle != .consumed) {
        adapter.cancelAdmissionClose(&permit) catch
            @panic("R2b external admission fallback failed");
    };
    try adapter.prepareRetirementCleanup(&permit, 3, &cleanup);
    var cleanup_settled = false;
    defer if (!cleanup_settled) {
        if (cleanup.lifecycle == .prepared) {
            adapter.abortRetirementCleanup(&cleanup) catch
                @panic("R2b external prepared cleanup fallback failed");
        } else if (cleanup.lifecycle == .committed) {
            adapter.finishRetirementCleanup(&cleanup) catch
                @panic("R2b external committed cleanup fallback failed");
        }
    };
    try testing.expectEqual(@as(u8, 1), cleanup.external_deinit_reserved_raw);
    _ = try owner.publishUnavailableForClientRetirementWithCleanup(
        &adapter,
        &permit,
        &cleanup,
        2,
        3,
    );
    permit_settled = true;
    try adapter.finishRetirementCleanup(&cleanup);
    cleanup_settled = true;
    try testing.expect(client.io_mode == .blocking);
}

test "CR3b R2b cleanup preflight 실패와 copied handle은 자원과 cancel 권위를 보존한다" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0xC3B2B7,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &source);
    defer adapter.deinit();
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 24, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        R2aTestGeneration.Args{
            .allocator = testing.allocator,
            .adapter = &adapter,
            .runtime_id = 0xC3B2B7,
            .stream_id = 0xC3B2B8,
        },
        R2aTestGeneration.init,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);
    var permit: r2a_client_slot.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(1, &permit);
    try adapter.commitAdmissionClose(&permit);
    var permit_settled = false;
    defer if (!permit_settled) {
        adapter.cancelAdmissionClose(&permit) catch
            @panic("R2b preflight admission fallback failed");
    };
    var cleanup: r2a_client_slot.PreparedRetirementCleanup = .{};
    try adapter.prepareRetirementCleanup(&permit, 3, &cleanup);
    var cleanup_settled = false;
    defer if (!cleanup_settled) {
        adapter.abortRetirementCleanup(&cleanup) catch
            @panic("R2b preflight cleanup fallback failed");
    };
    const before = cleanup;
    var copied = cleanup;
    try testing.expectError(
        error.InvalidOwner,
        owner.publishUnavailableForClientRetirementWithCleanup(&adapter, &permit, &copied, 2, 3),
    );
    try testing.expect(std.meta.eql(before, cleanup));
    try testing.expectError(
        error.InvalidAuthority,
        owner.publishUnavailableForClientRetirementWithCleanup(&adapter, &permit, &cleanup, 3, 4),
    );
    try testing.expect(std.meta.eql(before, cleanup));
    try adapter.abortRetirementCleanup(&cleanup);
    cleanup_settled = true;
    try testing.expectEqual(r2a_client_slot.PreparedRetirementCleanup.Lifecycle.cancelled, cleanup.lifecycle);
    try adapter.cancelAdmissionClose(&permit);
    permit_settled = true;
    const projection = r2a_client_slot.testing.retirementProjection(&adapter.slot);
    try testing.expectEqual(r2a_client_slot.AdmissionLifecycle.open, projection.admission);
    try testing.expectEqual(r2a_client_slot.RetirementLifecycle.live, projection.retirement);
}

test "CR2e-d PreparedReconnect prepare 실패와 abort는 current와 screen을 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    ReconnectGenerationTestState.deinit_count = 0;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x31 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);

    var prepared: PreparedReconnect = .{};
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x32 },
        initReconnectTestGeneration,
    );
    try owner.abort(&prepared);
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 2), proxy.current.generation);
    try testing.expectEqual(@as(usize, 1), ReconnectGenerationTestState.deinit_count);
    try testing.expect(!try owner.slot.hasRetiring());
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x33 },
        initReconnectTestGeneration,
    );
    try owner.publish(&prepared);
    try testing.expectEqual(@as(u64, 4), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 4), proxy.current.generation);
    try owner.reclaimRetiring();
    try testing.expectEqual(@as(usize, 2), ReconnectGenerationTestState.deinit_count);
}

test "CR2e-d PreparedReconnect는 copied stale cross-owner token을 mutation 없이 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x41 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&owner, &proxy);
    var prepared: PreparedReconnect = .{};
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x42 },
        initReconnectTestGeneration,
    );
    var copied = prepared;
    try testing.expectError(error.InvalidAuthority, owner.publish(&copied));
    var copied_owner = owner;
    try testing.expectError(error.InvalidAuthority, copied_owner.currentGeneration());
    var foreign_rejected = std.atomic.Value(bool).init(false);
    const foreign = try std.Thread.spawn(.{}, readReconnectOwnerFromForeignThread, .{ &owner, &foreign_rejected });
    foreign.join();
    try testing.expect(foreign_rejected.load(.acquire));
    var other_proxy: stable_screen_source.StableScreenSource = undefined;
    try other_proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var other_owner: ReconnectGenerationOwner = .{};
    try other_owner.initInPlace(
        testing.allocator,
        &other_proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x43 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&other_owner, &other_proxy);
    try testing.expectError(error.InvalidAuthority, other_owner.publish(&prepared));
    const canonical_target = proxy.current;
    proxy.current.source = other_proxy.current.source;
    try testing.expectError(error.InvalidAuthority, owner.publish(&prepared));
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    proxy.current = canonical_target;
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 2), proxy.current.generation);
    try owner.abort(&prepared);
}

fn reconnectAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var proxy_live = true;
    defer if (proxy_live) {
        _ = proxy.close() catch null;
        proxy.deinit();
    };
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = allocator, .stream_id = 0x51 },
        initReconnectTestGeneration,
    );
    var owner_live = true;
    defer if (owner_live) {
        deinitReconnectTestOwner(&owner, &proxy);
        proxy_live = false;
    };
    var prepared: PreparedReconnect = .{};
    owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = allocator, .stream_id = 0x52 },
        initReconnectTestGeneration,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
            try testing.expectEqual(@as(u64, 2), proxy.current.generation);
            return error.OutOfMemory;
        },
        else => return err,
    };
    try owner.abort(&prepared);
    deinitReconnectTestOwner(&owner, &proxy);
    owner_live = false;
    proxy_live = false;
}

test "CR2e-d PreparedReconnect allocator fail-index는 final-address candidate와 current를 누수 없이 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, reconnectAllocationFailureCase, .{});
}

test "CR2e-e1 current accessor는 inline generation final address를 단일 출처로 반환한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var runtime: RemoteRuntime = undefined;
    runtime.generation_owner = .{};
    try runtime.generation_owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x61 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&runtime.generation_owner, &proxy);
    const slot_payload = try runtime.generation_owner.slot.currentPayload();
    try testing.expectEqual(@intFromPtr(slot_payload), @intFromPtr(runtime.currentGeneration()));
    try testing.expectEqual(@intFromPtr(slot_payload), @intFromPtr(runtime.currentGenerationConst()));
}

test "CR2e-e1 backend facade는 frame state를 raw generation 저장소 없이 투영한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var runtime: RemoteRuntime = undefined;
    runtime.generation_owner = .{};
    try runtime.generation_owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x62 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&runtime.generation_owner, &proxy);

    try testing.expect(!RemoteRuntime.backend_api.frameSummaryReady(&runtime));
    RemoteRuntime.backend_api.prepareFrameSummary(&runtime);
    try testing.expect(RemoteRuntime.backend_api.frameSummaryReady(&runtime));
    RemoteRuntime.backend_api.storeFrameSummary(&runtime, .{ .output_events = 7 });
    const summary = RemoteRuntime.backend_api.takeFrameSummary(&runtime) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 7), summary.output_events);
    try testing.expect(RemoteRuntime.backend_api.takeFrameSummary(&runtime) == null);
    RemoteRuntime.backend_api.markPumpEnded(&runtime);
    try testing.expect(RemoteRuntime.backend_api.pumpEnded(&runtime));
}
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const screen_stream = @import("maru").session.screen_stream;

fn readPeerFrame(fd: c.fd_t, allocator: std.mem.Allocator) !struct { header: protocol.Header, payload: []u8 } {
    var header_bytes: [protocol.header_size]u8 = undefined;
    var offset: usize = 0;
    while (offset < header_bytes.len) {
        const rc = c.read(fd, header_bytes[offset..].ptr, header_bytes.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.ConnectionClosed;
    }
    const header = try protocol.Header.decode(&header_bytes);
    const payload = try allocator.alloc(u8, header.payload_len);
    errdefer allocator.free(payload);
    offset = 0;
    while (offset < payload.len) {
        const rc = c.read(fd, payload[offset..].ptr, payload.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.ConnectionClosed;
    }
    return .{ .header = header, .payload = payload };
}

fn readPeerFrameAfterFiller(
    fd: c.fd_t,
    allocator: std.mem.Allocator,
    filler: u8,
) !struct { header: protocol.Header, payload: []u8 } {
    var header_bytes: [protocol.header_size]u8 = undefined;
    var first: [1]u8 = undefined;
    while (true) {
        const rc = c.read(fd, &first, 1);
        if (rc == 1) {
            if (first[0] == filler) continue;
            header_bytes[0] = first[0];
            break;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.ConnectionClosed;
    }
    var offset: usize = 1;
    while (offset < header_bytes.len) {
        const rc = c.read(fd, header_bytes[offset..].ptr, header_bytes.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.ConnectionClosed;
    }
    const header = try protocol.Header.decode(&header_bytes);
    const payload = try allocator.alloc(u8, header.payload_len);
    errdefer allocator.free(payload);
    offset = 0;
    while (offset < payload.len) {
        const rc = c.read(fd, payload[offset..].ptr, payload.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.ConnectionClosed;
    }
    return .{ .header = header, .payload = payload };
}

const PreviousAttachPeer = struct {
    fn run(fd: c.fd_t, snapshot: []const u8, ok: *bool) void {
        defer _ = c.close(fd);
        const allocator = std.heap.page_allocator;
        const attach = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(attach.payload);
        if (attach.header.major != 1 or attach.header.kind != .request or
            std.mem.indexOf(u8, attach.payload, "\"method\":\"runtime.attach\"") == null) return;
        const response = framing.encodeFrame(
            allocator,
            .{ .kind = .response, .major = 1, .request_id = attach.header.request_id },
            "{\"result\":{\"stream_id\":9,\"controller_generation\":1,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false}}",
        ) catch return;
        defer allocator.free(response);
        @import("socket_server.zig").writeAll(fd, response) catch return;
        const snapshot_frame = framing.encodeFrame(
            allocator,
            .{ .kind = .snapshot_chunk, .major = 1, .stream_id = 9, .flags = protocol.Flags.end_stream },
            snapshot,
        ) catch return;
        defer allocator.free(snapshot_frame);
        @import("socket_server.zig").writeAll(fd, snapshot_frame) catch return;

        const detach = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(detach.payload);
        if (detach.header.major != 1 or std.mem.indexOf(u8, detach.payload, "\"method\":\"runtime.detach\"") == null)
            return;
        const detached = framing.encodeFrame(
            allocator,
            .{ .kind = .response, .major = 1, .request_id = detach.header.request_id },
            "{\"ok\":true}",
        ) catch return;
        defer allocator.free(detached);
        @import("socket_server.zig").writeAll(fd, detached) catch return;
        ok.* = true;
    }
};

const CurrentMetadataAttachPeer = struct {
    fn run(
        fd: c.fd_t,
        attach_body: []const u8,
        snapshot: []const u8,
        event_body: []const u8,
        ok: *bool,
    ) void {
        defer _ = c.close(fd);
        const allocator = std.heap.page_allocator;
        const attach = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(attach.payload);
        if (attach.header.kind != .request or
            std.mem.indexOf(u8, attach.payload, "\"method\":\"runtime.attach\"") == null)
            return;
        const attach_response = framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = attach.header.request_id },
            attach_body,
        ) catch return;
        defer allocator.free(attach_response);
        socket_server.writeAll(fd, attach_response) catch return;
        const snapshot_frame = framing.encodeFrame(
            allocator,
            .{
                .kind = .snapshot_chunk,
                .stream_id = 7,
                .flags = protocol.Flags.end_stream,
            },
            snapshot,
        ) catch return;
        defer allocator.free(snapshot_frame);
        socket_server.writeAll(fd, snapshot_frame) catch return;

        const barrier = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(barrier.payload);
        if (barrier.header.kind != .request or
            std.mem.indexOf(u8, barrier.payload, "\"method\":\"host.info\"") == null)
            return;
        const event = framing.encodeFrame(
            allocator,
            .{ .kind = .event, .stream_id = 7 },
            event_body,
        ) catch return;
        defer allocator.free(event);
        socket_server.writeAll(fd, event) catch return;
        const barrier_response = framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = barrier.header.request_id },
            "{\"result\":{}}",
        ) catch return;
        defer allocator.free(barrier_response);
        socket_server.writeAll(fd, barrier_response) catch return;
        ok.* = true;
    }
};

const ResizeOrderingPeer = struct {
    fn sendResizeResponse(
        fd: c.fd_t,
        allocator: std.mem.Allocator,
        request_id: u64,
        cols: u16,
    ) !void {
        var body_buf: [160]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buf,
            "{{\"result\":{{\"cols\":{d},\"rows\":40,\"client_sequence\":1,\"resize_generation\":5,\"changed\":true}}}}",
            .{cols},
        );
        const response = try framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = request_id },
            body,
        );
        defer allocator.free(response);
        try socket_server.writeAll(fd, response);
    }

    fn sendResizeEventAndBarrier(
        fd: c.fd_t,
        allocator: std.mem.Allocator,
        request_id: u64,
        cols: u16,
    ) !void {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buf,
            "{{\"event\":\"runtime.resized\",\"data\":{{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":{d},\"rows\":40,\"resize_generation\":5,\"reason\":\"controller\"}}}}",
            .{cols},
        );
        const event = try framing.encodeFrame(
            allocator,
            .{ .kind = .event, .stream_id = 7 },
            body,
        );
        defer allocator.free(event);
        try socket_server.writeAll(fd, event);
        const response = try framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = request_id },
            "{\"result\":{}}",
        );
        defer allocator.free(response);
        try socket_server.writeAll(fd, response);
    }

    fn run(
        fd: c.fd_t,
        attach_body: []const u8,
        snapshot: []const u8,
        event_first: bool,
        ok: *bool,
    ) void {
        defer _ = c.close(fd);
        const allocator = std.heap.page_allocator;
        const attach = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(attach.payload);
        const attach_response = framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = attach.header.request_id },
            attach_body,
        ) catch return;
        defer allocator.free(attach_response);
        socket_server.writeAll(fd, attach_response) catch return;
        const snapshot_frame = framing.encodeFrame(
            allocator,
            .{
                .kind = .snapshot_chunk,
                .stream_id = 7,
                .flags = protocol.Flags.end_stream,
            },
            snapshot,
        ) catch return;
        defer allocator.free(snapshot_frame);
        socket_server.writeAll(fd, snapshot_frame) catch return;

        const first = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(first.payload);
        if (event_first) {
            if (std.mem.indexOf(u8, first.payload, "\"method\":\"host.info\"") == null)
                return;
            sendResizeEventAndBarrier(fd, allocator, first.header.request_id, 100) catch return;
        } else {
            if (std.mem.indexOf(u8, first.payload, "\"method\":\"runtime.resize\"") == null)
                return;
            sendResizeResponse(fd, allocator, first.header.request_id, 100) catch return;
        }
        const second = readPeerFrame(fd, allocator) catch return;
        defer allocator.free(second.payload);
        if (event_first) {
            if (std.mem.indexOf(u8, second.payload, "\"method\":\"runtime.resize\"") == null)
                return;
            sendResizeResponse(fd, allocator, second.header.request_id, 101) catch return;
        } else {
            if (std.mem.indexOf(u8, second.payload, "\"method\":\"host.info\"") == null)
                return;
            sendResizeEventAndBarrier(fd, allocator, second.header.request_id, 101) catch return;
        }
        ok.* = true;
    }
};

test "remote runtime attaches through N-1 MRSH and normalizes frozen v1 screen records" {
    const allocator = std.testing.allocator;
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1, .version = 1 },
        .{ .cols = 4, .rows = 1, .cursor = .{ .col = 3, .row = 0 } },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&stream, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "o", .width = 1, .count = 4 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1, .version = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&stream, allocator, row);

    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var peer_ok = false;
    var peer = try std.Thread.spawn(.{}, PreviousAttachPeer.run, .{ fds[1], stream.items, &peer_ok });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0xAA,
        .wire_major = 1,
        .screen_codec_version = 1,
        .parser = framing.FrameParser.initForMajor(allocator, 1),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(1).?,
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    const runtime_id: [32]u8 = "00112233445566778899aabbccddeeff".*;
    try rr.attachExisting(&client, allocator, std.testing.io, 77, runtime_id, .{ .cols = 4, .rows = 1 });
    {
        rr.surface.lockCore(std.testing.io);
        defer rr.surface.unlockCore(std.testing.io);
        const snapshot = rr.surface.renderSnapshot();
        try std.testing.expectEqual(@as(u16, 4), snapshot.size.cols);
        try std.testing.expectEqual(@as(u21, 'o'), snapshot.cells[0].codepoint);
    }
    rr.detachClientSide();
    peer.join();
    try std.testing.expect(peer_ok);
}

test "remote runtime actual attach seed and event path share revision and semantic rules" {
    const allocator = std.testing.allocator;
    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&snapshot, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&snapshot, allocator, row);

    const attach_body =
        \\{"result":{"stream_id":7,"controller_generation":1,"granted":{"observe":true,"input":true,"resize":true},"controller_busy":false,"metadata_revision":4,"metadata":{"cwd":"/base","window_title":"base","ssh_remote_dest":"base-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}}
    ;
    const cases = [_]struct {
        event: []const u8,
        outcome: enum { unchanged, newer, conflict, sealed_revision_mutation, sealed_header_mutation },
    }{
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":4,"metadata":{"cwd":"/base","window_title":"base","ssh_remote_dest":"base-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .unchanged,
        },
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/stale","window_title":"stale","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .unchanged,
        },
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":5,"metadata":{"cwd":"/new","window_title":"new","ssh_remote_dest":"new-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":2,"title_generation":2,"cols":90,"rows":30,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .newer,
        },
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":4,"metadata":{"cwd":"/evil","window_title":"base","ssh_remote_dest":"evil-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .conflict,
        },
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":5,"metadata":{"cwd":"/new","window_title":"new","ssh_remote_dest":"new-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":2,"title_generation":2,"cols":90,"rows":30,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .sealed_revision_mutation,
        },
        .{
            .event =
            \\{"event":"runtime.metadata","metadata_revision":5,"metadata":{"cwd":"/new","window_title":"new","ssh_remote_dest":"new-host","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":2,"title_generation":2,"cols":90,"rows":30,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
            ,
            .outcome = .sealed_header_mutation,
        },
    };
    for (cases) |case| {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var peer_ok = false;
        var peer = try std.Thread.spawn(.{}, CurrentMetadataAttachPeer.run, .{
            fds[1],
            attach_body,
            snapshot.items,
            case.event,
            &peer_ok,
        });
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
            .attachment_capabilities = .{ .peer_attach_generation = true },
            .metadata_support = .supported,
            .compatibility_profile = @import("compatibility.zig").profileForMajor(
                protocol.version_major,
            ).?,
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try rr.attachExisting(
            &client,
            allocator,
            std.testing.io,
            77,
            "000000000000000000000000000000aa".*,
            .{ .cols = 1, .rows = 1 },
        );
        try std.testing.expectEqual(@as(u64, 4), rr.currentGeneration().observation.revision);
        try std.testing.expectEqualStrings("/base", rr.currentGeneration().observation.cwd.items);
        const barrier = try client.call("host.info", "{}");
        allocator.free(barrier);
        peer.join();
        try std.testing.expect(peer_ok);
        switch (case.outcome) {
            .sealed_revision_mutation => switch (client.pending_events.items[0].preflight.?) {
                .accepted => |*accepted| switch (accepted.event) {
                    .metadata => |*metadata| metadata.revision = std.math.maxInt(u64),
                    else => unreachable,
                },
                else => unreachable,
            },
            .sealed_header_mutation => client.pending_events.items[0].header.stream_id = 8,
            else => {},
        }
        switch (case.outcome) {
            .unchanged => {
                const result = try rr.drainObservationEvents();
                try std.testing.expect(!result.metadata);
                try std.testing.expectEqual(@as(u64, 4), rr.currentGeneration().observation.revision);
                try std.testing.expectEqualStrings("/base", rr.currentGeneration().observation.cwd.items);
                try std.testing.expect(!client.unusable);
            },
            .newer => {
                const result = try rr.drainObservationEvents();
                try std.testing.expect(result.metadata);
                try std.testing.expectEqual(@as(u64, 5), rr.currentGeneration().observation.revision);
                try std.testing.expectEqualStrings("/new", rr.currentGeneration().observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "new-host",
                    rr.currentGeneration().observation.ssh_remote_dest.items,
                );
                try std.testing.expect(!client.unusable);
            },
            .conflict => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.currentGeneration().observation.revision);
                try std.testing.expectEqualStrings("/base", rr.currentGeneration().observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.currentGeneration().observation.ssh_remote_dest.items,
                );
            },
            .sealed_revision_mutation, .sealed_header_mutation => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.currentGeneration().observation.revision);
                try std.testing.expectEqualStrings("/base", rr.currentGeneration().observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.currentGeneration().observation.ssh_remote_dest.items,
                );
            },
        }
        if (!client.unusable) client.poison(.peer_contract_violation);
        rr.detachClientSide();
    }
}

test "remote runtime actual resize response and event reject equal-generation conflict in both orders" {
    const allocator = std.testing.allocator;
    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&snapshot, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&snapshot, allocator, row);
    const attach_body =
        \\{"result":{"stream_id":7,"controller_generation":1,"granted":{"observe":true,"input":true,"resize":true},"controller_busy":false,"metadata_revision":1,"metadata":{"cwd":"/base","window_title":"base","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}}
    ;

    for ([_]bool{ false, true }) |event_first| {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var peer_ok = false;
        var peer = try std.Thread.spawn(.{}, ResizeOrderingPeer.run, .{
            fds[1],
            attach_body,
            snapshot.items,
            event_first,
            &peer_ok,
        });
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
            .attachment_capabilities = .{ .peer_attach_generation = true },
            .metadata_support = .supported,
            .compatibility_profile = @import("compatibility.zig").profileForMajor(
                protocol.version_major,
            ).?,
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try rr.attachExisting(
            &client,
            allocator,
            std.testing.io,
            77,
            "000000000000000000000000000000aa".*,
            .{ .cols = 1, .rows = 1 },
        );
        if (event_first) {
            const barrier = try client.call("host.info", "{}");
            allocator.free(barrier);
            const applied = try rr.drainObservationEvents();
            try std.testing.expect(applied.metadata);
            try std.testing.expectError(error.ProtocolError, rr.resize(101, 40));
        } else {
            try rr.resize(100, 40);
            const barrier = try client.call("host.info", "{}");
            allocator.free(barrier);
            try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
        }
        peer.join();
        try std.testing.expect(peer_ok);
        try std.testing.expect(client.unusable);
        try std.testing.expectEqual(@as(u64, 5), rr.currentGeneration().resize_generation);
        try std.testing.expectEqual(
            terminal.Size{ .cols = 100, .rows = 40 },
            rr.currentGeneration().observation.size,
        );
        rr.detachClientSide();
    }
}

test "remote runtime observer locally consumes input and sends no resize mutation" {
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeDetachedGeneration(&runtime, testing.allocator);
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    });
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer runtime.currentGeneration().attachment.deinit();
    try testing.expectError(error.Unauthorized, runtime.sendInput("x"));
    try testing.expectError(error.Unauthorized, runtime.sendInputNonBlocking("paste"));
    try runtime.resize(80, 24);
}

test "remote runtime revoke demotes authority and cancels queued mutation before write" {
    const allocator = testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .pending_outbound = .{
            .frame = try allocator.dupe(u8, "not-yet-written"),
            .stream_id = 7,
        },
    };
    defer client.deinit();
    var event = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    event.header.payload_len = @intCast(event.payload.len);
    try client.pending_events.append(allocator, event);
    client.pending_event_bytes = event.payload.len;

    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer runtime.currentGeneration().attachment.deinit();
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    defer runtime.direct_input.deinit(allocator);
    try runtime.direct_input.appendSlice(allocator, "queued");
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    defer runtime.pending_controls.deinit(allocator);
    try runtime.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(6).?);
    runtime.currentGeneration().observation = .{};

    const drained = try runtime.drainObservationEvents();
    try testing.expect(drained.metadata);
    try testing.expectEqual(remote_attachment.Role.observer, runtime.currentGeneration().attachment.statePtr().role);
    try testing.expectEqual(@as(u64, 4), runtime.currentGeneration().attachment.statePtr().controller_generation);
    try testing.expectEqual(@as(usize, 0), runtime.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), runtime.pending_controls.items.len);
    try testing.expect(client.pending_outbound == null);
    try testing.expect(!client.unusable);
}

test "remote runtime rejects revoke when attach generation is untracked" {
    const allocator = testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var event = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    event.header.payload_len = @intCast(event.payload.len);
    try client.pending_events.append(allocator, event);
    client.pending_event_bytes = event.payload.len;

    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 0,
    });
    defer runtime.currentGeneration().attachment.deinit();
    runtime.currentGeneration().event_generation_tracking = .untracked;
    runtime.currentGeneration().observation = .{};

    try testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try testing.expect(client.unusable);
    try testing.expectEqual(remote_attachment.Role.controller, runtime.currentGeneration().attachment.statePtr().role);
}

test "own buffered revoke suppresses newly arriving input before role cache catches up" {
    const allocator = testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try client.bufferGenerationEventForTest(
        7,
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );

    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer runtime.currentGeneration().attachment.deinit();
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    defer runtime.direct_input.deinit(allocator);
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    defer runtime.pending_controls.deinit(allocator);

    // Role cache는 아직 controller지만 own-stream revoke가 먼저 도착했으므로 SurfaceRuntime가
    // InputSuppressed로 바꿀 Unauthorized를 반환하고 queue/wire ownership을 만들지 않는다.
    try testing.expect(runtime.currentGeneration().attachment.allowsMutation());
    try testing.expect(client.hasBufferedControllerRevokeForStream(7));
    try testing.expect(!client.hasBufferedControllerRevokeForStream(8));
    try testing.expectError(error.Unauthorized, runtime.sendInput("key"));
    try testing.expectError(error.Unauthorized, runtime.sendInputNonBlocking("paste"));
    try testing.expectEqual(@as(usize, 0), runtime.direct_input.items.len);
    try testing.expect(client.pending_outbound == null);
}

fn initGenerationRuntimeAggregateFixture(
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
    client: *client_mod.Client,
) !void {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    try host_adapter_mod.HostAdapter.initInPlace(adapter, testing.allocator, client);
    try initGenerationRuntimeForAdapter(runtime, adapter);
}

fn initGenerationRuntimeForAdapter(
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
) !void {
    try testing_api.initializeTestGeneration(
        runtime,
        testing.allocator,
        .{ .generation = adapter },
    );
    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = undefined;
    runtime.currentGeneration().attachment = .{ .generation = .{} };
    try generation_attachment_mod.testing_api.initAttached(
        &runtime.currentGeneration().attachment.generation,
        adapter,
        testing.allocator,
        0xaa,
        7,
    );
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.mutation_owner = .{};
    try runtime.mutation_owner.initInPlace(
        try runtime.generation_owner.slot.currentGeneration(),
        runtime.input_batches.epoch,
    );
    runtime.paused_input_metadata = null;
    runtime.paused_paste_store = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().resync_needed = false;
    runtime.currentGeneration().observation = .{};
    runtime.currentGeneration().event_generation_tracking = .tracked;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.currentGeneration().resize_generation = 0;
    runtime.currentGeneration().resize_baseline_present = false;
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
}

fn deinitGenerationRuntimeAggregateFixture(
    runtime: *RemoteRuntime,
    adapter: *host_adapter_mod.HostAdapter,
) void {
    deinitGenerationRuntimeForAdapter(runtime);
    adapter.deinit();
}

fn deinitGenerationRuntimeForAdapter(runtime: *RemoteRuntime) void {
    runtime.currentGeneration().observation.deinit(testing.allocator);
    runtime.direct_input.deinit(testing.allocator);
    runtime.pending_controls.deinit(testing.allocator);
    runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
}

test "CR0b prepared execution poison은 held operation suffix를 호출한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const owner_fd = c.dup(tmp.dir.handle);
    if (owner_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(owner_fd);
    var owner: app_process_incident_owner.AppProcessIncidentOwner = .{};
    try owner.ensureReady(testing.allocator, owner_fd, identity.process_nonce, 0xC002);
    var owner_settled = false;
    defer if (!owner_settled) {
        app_process_incident_owner.publication_port_testing_api.reset();
        _ = owner.shutdown() catch {};
    };
    try app_process_incident_owner.publication_port_testing_api.install(&owner);

    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t) void {
            defer _ = c.close(fd);
            const request_frame = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request_frame.payload);
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});

    var pool = Pool.init(testing.allocator);
    defer pool.deinit();
    const adapter = try testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC003,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var permit: maru.observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;

    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeForAdapter(&runtime, adapter);
    defer deinitGenerationRuntimeForAdapter(&runtime);
    runtime.currentGeneration().pump_ended = false;
    var pre_publication: app_process_incident_owner.publication_port_testing_api.PrePublicationSnapshot = .{};
    app_process_incident_owner.publication_port_testing_api.armPrePublicationSnapshot(&pre_publication);
    defer app_process_incident_owner.publication_port_testing_api.disarmPrePublicationSnapshot();
    const Apply = struct {
        fn apply(_: *RemoteRuntime, _: *anyopaque, _: []const u8) client_mod.ClientError!void {}
    };
    var output: u8 = 0;
    try testing.expectError(
        error.ConnectionClosed,
        runtime.callDecodedAfterFlush(
            generation_contract.RuntimeRequest.observation(),
            generation_contract.requestMethod(.observation),
            null,
            &output,
            Apply.apply,
        ),
    );
    peer.join();

    try testing.expect(pre_publication.observed);
    try testing.expect(!pre_publication.first_reason_present);
    try testing.expect(pre_publication.client_was_usable);
    try testing.expectEqual(fds[0], pre_publication.fd);
    try testing.expect(!pre_publication.pending_outbound_present);
    try testing.expectEqual(@as(u8, 0), pre_publication.incident_count);
    try testing.expectEqual(@as(u128, 0), pre_publication.pending_slots);
    try testing.expectEqual(@as(u8, 0), pre_publication.reconnect_count);
    try testing.expectEqual(
        @intFromEnum(client_poison.ConnectionReason.connection_eof),
        pre_publication.reason_raw,
    );
    try testing.expectEqual(
        @intFromEnum(connection_incident.SourceSite.client_response),
        pre_publication.source_site_raw,
    );
    try testing.expectEqual(runtime.currentGeneration().attachment.statePtr().controller_generation, pre_publication.controller_generation);

    const published = adapter.slot.logicalClientConst();
    try testing.expectEqual(client_poison.ConnectionReason.connection_eof, published.first_poison_reason.?);
    try testing.expect(published.first_incident_id.sequence != 0);
    try testing.expect(!std.mem.eql(
        u8,
        &published.incident_repeat_key.fingerprint,
        &([_]u8{0} ** 32),
    ));
    try testing.expect(published.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), published.fd);
    try testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try testing.expectEqual(published.first_incident_id, admission.incident_id);
    try owner.reconnect_admissions.consume(admission);
    app_process_incident_owner.publication_port_testing_api.reset();
    const shutdown = try owner.shutdown();
    owner_settled = true;
    try testing.expectEqual(@import("incident_runtime.zig").ShutdownResult.joined, shutdown);
}

test "CR0b actual outbound RPC ambiguity는 canonical suffix를 호출한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const owner_fd = c.dup(tmp.dir.handle);
    if (owner_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(owner_fd);
    var owner: app_process_incident_owner.AppProcessIncidentOwner = .{};
    try owner.ensureReady(testing.allocator, owner_fd, identity.process_nonce, 0xC062);
    var owner_settled = false;
    defer if (!owner_settled) {
        app_process_incident_owner.publication_port_testing_api.reset();
        _ = owner.shutdown() catch {};
    };
    try app_process_incident_owner.publication_port_testing_api.install(&owner);

    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    socket_server.setNoSigPipe(fds[0]);
    const flags = c.fcntl(fds[0], c.F.GETFL, @as(c_int, 0));
    try testing.expect(flags >= 0);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try testing.expectEqual(@as(c_int, 0), c.fcntl(fds[0], c.F.SETFL, flags | nonblocking));

    const pending_len = 1024 * 1024;
    const pending_frame = try testing.allocator.alloc(u8, pending_len);
    @memset(pending_frame, 0xA5);
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();
    const adapter = try testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC063,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
        .pending_outbound = .{
            .frame = pending_frame,
            .stream_id = 0xC064,
            .offset = 1,
        },
    };
    var permit: maru.observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;

    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeForAdapter(&runtime, adapter);
    defer deinitGenerationRuntimeForAdapter(&runtime);
    runtime.currentGeneration().pump_ended = false;
    var pre_publication: app_process_incident_owner.publication_port_testing_api.PrePublicationSnapshot = .{};
    app_process_incident_owner.publication_port_testing_api.armPrePublicationSnapshot(&pre_publication);
    defer app_process_incident_owner.publication_port_testing_api.disarmPrePublicationSnapshot();

    try testing.expectError(error.WriteFailed, runtime.resize(91, 27));

    try testing.expect(pre_publication.observed);
    try testing.expect(!pre_publication.first_reason_present);
    try testing.expect(pre_publication.client_was_usable);
    try testing.expectEqual(fds[0], pre_publication.fd);
    try testing.expect(pre_publication.pending_outbound_present);
    try testing.expectEqual(@as(u8, 0), pre_publication.incident_count);
    try testing.expectEqual(@as(u128, 0), pre_publication.pending_slots);
    try testing.expectEqual(@as(u8, 0), pre_publication.reconnect_count);
    try testing.expectEqual(
        @intFromEnum(client_poison.ConnectionReason.outbound_write_ambiguous),
        pre_publication.reason_raw,
    );
    try testing.expectEqual(
        @intFromEnum(connection_incident.SourceSite.client_response),
        pre_publication.source_site_raw,
    );
    try testing.expectEqual(runtime.currentGeneration().attachment.statePtr().controller_generation, pre_publication.controller_generation);
    try testing.expectEqual(@as(u32, 1), pre_publication.pending_request_count);
    try testing.expectEqual(
        @intFromEnum(connection_incident.OutboundPhase.partial),
        pre_publication.outbound_phase_raw,
    );
    try testing.expect(pre_publication.outbound_offset > 1);
    try testing.expect(pre_publication.outbound_offset < pending_len);
    try testing.expectEqual(@as(u64, pending_len), pre_publication.outbound_length);
    try testing.expectEqual(
        @as(u64, pending_len) - pre_publication.outbound_offset,
        pre_publication.queue_bytes,
    );

    const published = adapter.slot.logicalClientConst();
    try testing.expectEqual(client_poison.ConnectionReason.outbound_write_ambiguous, published.first_poison_reason.?);
    try testing.expect(published.first_incident_id.sequence != 0);
    try testing.expect(!std.mem.eql(
        u8,
        &published.incident_repeat_key.fingerprint,
        &([_]u8{0} ** 32),
    ));
    try testing.expect(published.pending_outbound == null);
    try testing.expect(published.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), published.fd);
    try testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try testing.expectEqual(published.first_incident_id, admission.incident_id);
    try owner.reconnect_admissions.consume(admission);
    app_process_incident_owner.publication_port_testing_api.reset();
    const shutdown = try owner.shutdown();
    owner_settled = true;
    try testing.expectEqual(@import("incident_runtime.zig").ShutdownResult.joined, shutdown);
}

test "CR0b actual read event pump poison은 canonical suffix를 호출한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const owner_fd = c.dup(tmp.dir.handle);
    if (owner_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(owner_fd);
    var owner: app_process_incident_owner.AppProcessIncidentOwner = .{};
    try owner.ensureReady(testing.allocator, owner_fd, identity.process_nonce, 0xC032);
    var owner_settled = false;
    defer if (!owner_settled) {
        app_process_incident_owner.publication_port_testing_api.reset();
        _ = owner.shutdown() catch {};
    };
    try app_process_incident_owner.publication_port_testing_api.install(&owner);

    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    // Keep the peer's read half alive so the pre-read output pump cannot race the EOF path.
    // Only the peer write half closes: the actual generation read must therefore observe EOF.
    try testing.expectEqual(@as(c_int, 0), c.shutdown(fds[1], 1));

    var pool = Pool.init(testing.allocator);
    defer pool.deinit();
    const adapter = try testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC033,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var permit: maru.observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;

    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeForAdapter(&runtime, adapter);
    defer deinitGenerationRuntimeForAdapter(&runtime);
    runtime.currentGeneration().pump_ended = false;
    var pre_publication: app_process_incident_owner.publication_port_testing_api.PrePublicationSnapshot = .{};
    app_process_incident_owner.publication_port_testing_api.armPrePublicationSnapshot(&pre_publication);
    defer app_process_incident_owner.publication_port_testing_api.disarmPrePublicationSnapshot();

    try testing.expectError(error.ConnectionClosed, runtime.pumpDelta());

    try testing.expect(pre_publication.observed);
    try testing.expect(!pre_publication.first_reason_present);
    try testing.expect(pre_publication.client_was_usable);
    try testing.expectEqual(fds[0], pre_publication.fd);
    try testing.expectEqual(@as(u8, 0), pre_publication.incident_count);
    try testing.expectEqual(@as(u128, 0), pre_publication.pending_slots);
    try testing.expectEqual(@as(u8, 0), pre_publication.reconnect_count);
    try testing.expectEqual(
        @intFromEnum(client_poison.ConnectionReason.connection_eof),
        pre_publication.reason_raw,
    );
    try testing.expectEqual(
        @intFromEnum(connection_incident.SourceSite.client_read),
        pre_publication.source_site_raw,
    );
    try testing.expectEqual(runtime.currentGeneration().attachment.statePtr().controller_generation, pre_publication.controller_generation);

    const published = adapter.slot.logicalClientConst();
    try testing.expectEqual(client_poison.ConnectionReason.connection_eof, published.first_poison_reason.?);
    try testing.expect(published.first_incident_id.sequence != 0);
    try testing.expect(!std.mem.eql(
        u8,
        &published.incident_repeat_key.fingerprint,
        &([_]u8{0} ** 32),
    ));
    try testing.expect(published.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), published.fd);
    try testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try testing.expectEqual(published.first_incident_id, admission.incident_id);
    try owner.reconnect_admissions.consume(admission);
    app_process_incident_owner.publication_port_testing_api.reset();
    const shutdown = try owner.shutdown();
    owner_settled = true;
    try testing.expectEqual(@import("incident_runtime.zig").ShutdownResult.joined, shutdown);
}

test "CR0b allocator callback deferred poison은 canonical suffix를 호출한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    const PoisoningAllocator = struct {
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        parent: std.mem.Allocator,
        client: ?*client_mod.Client = null,
        armed: std.atomic.Value(bool) = .init(false),
        fired: bool = false,
        first_reason_absent: bool = false,
        client_was_usable: bool = false,
        fd_unchanged: bool = false,
        expected_fd: c.fd_t = -1,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn inject(self: *@This()) bool {
            if (!self.armed.swap(false, .acq_rel)) return false;
            const client = self.client orelse return false;
            if (!client_mod.generationAllocatorCallbackActive()) return false;
            client.poison(.local_resource_exhausted);
            self.fired = true;
            self.first_reason_absent = client.first_poison_reason == null;
            self.client_was_usable = !client.unusable;
            self.fd_unchanged = client.fd == self.expected_fd;
            return true;
        }

        fn alloc(
            context: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.inject()) return null;
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.inject()) return false;
            return self.parent.vtable.resize(
                self.parent.ptr,
                memory,
                alignment,
                new_len,
                return_address,
            );
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.inject()) return null;
            return self.parent.vtable.remap(
                self.parent.ptr,
                memory,
                alignment,
                new_len,
                return_address,
            );
        }

        fn free(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
        }
    };

    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const owner_fd = c.dup(tmp.dir.handle);
    if (owner_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(owner_fd);
    var owner: app_process_incident_owner.AppProcessIncidentOwner = .{};
    try owner.ensureReady(testing.allocator, owner_fd, identity.process_nonce, 0xC022);
    var owner_settled = false;
    defer if (!owner_settled) {
        app_process_incident_owner.publication_port_testing_api.reset();
        _ = owner.shutdown() catch {};
    };
    try app_process_incident_owner.publication_port_testing_api.install(&owner);

    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var poison_allocator: PoisoningAllocator = .{ .parent = testing.allocator };
    const Peer = struct {
        fn run(fd: c.fd_t, armed: *std.atomic.Value(bool)) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"result\":{\"metadata_revision\":1,\"metadata\":{\"cwd\":\"/tmp\",\"window_title\":\"allocator\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}}",
            ) catch return;
            defer std.heap.page_allocator.free(response);
            armed.store(true, .release);
            socket_server.writeAll(fd, response) catch return;
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], &poison_allocator.armed });
    var peer_joined = false;
    defer if (!peer_joined) peer.join();

    var pool = Pool.init(testing.allocator);
    defer pool.deinit();
    const adapter = try testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = poison_allocator.allocator(),
        .fd = fds[0],
        .host_id = 0xC023,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = framing.FrameParser.init(poison_allocator.allocator()),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var permit: maru.observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;

    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeForAdapter(&runtime, adapter);
    defer deinitGenerationRuntimeForAdapter(&runtime);
    runtime.currentGeneration().pump_ended = false;
    poison_allocator.client = runtime.testingClient();
    poison_allocator.expected_fd = fds[0];
    var pre_publication: app_process_incident_owner.publication_port_testing_api.PrePublicationSnapshot = .{};
    app_process_incident_owner.publication_port_testing_api.armPrePublicationSnapshot(&pre_publication);
    defer app_process_incident_owner.publication_port_testing_api.disarmPrePublicationSnapshot();
    const Apply = struct {
        fn apply(_: *RemoteRuntime, _: *anyopaque, _: []const u8) client_mod.ClientError!void {}
    };
    var output: u8 = 0;
    try testing.expectError(
        error.OutOfMemory,
        runtime.callDecodedAfterFlush(
            generation_contract.RuntimeRequest.observation(),
            generation_contract.requestMethod(.observation),
            null,
            &output,
            Apply.apply,
        ),
    );
    peer.join();
    peer_joined = true;

    try testing.expect(poison_allocator.fired);
    try testing.expect(poison_allocator.first_reason_absent);
    try testing.expect(poison_allocator.client_was_usable);
    try testing.expect(poison_allocator.fd_unchanged);
    try testing.expect(pre_publication.observed);
    try testing.expect(!pre_publication.first_reason_present);
    try testing.expect(pre_publication.client_was_usable);
    try testing.expectEqual(fds[0], pre_publication.fd);
    try testing.expectEqual(@as(u8, 0), pre_publication.incident_count);
    try testing.expectEqual(@as(u128, 0), pre_publication.pending_slots);
    try testing.expectEqual(@as(u8, 0), pre_publication.reconnect_count);
    try testing.expectEqual(
        @intFromEnum(client_poison.ConnectionReason.local_resource_exhausted),
        pre_publication.reason_raw,
    );
    try testing.expectEqual(
        @intFromEnum(connection_incident.SourceSite.client_cleanup),
        pre_publication.source_site_raw,
    );

    const published = adapter.slot.logicalClientConst();
    try testing.expectEqual(client_poison.ConnectionReason.local_resource_exhausted, published.first_poison_reason.?);
    try testing.expect(published.first_incident_id.sequence != 0);
    try testing.expect(published.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), published.fd);
    try testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try testing.expectEqual(published.first_incident_id, admission.incident_id);
    try owner.reconnect_admissions.consume(admission);
    app_process_incident_owner.publication_port_testing_api.reset();
    const shutdown = try owner.shutdown();
    owner_settled = true;
    try testing.expectEqual(@import("incident_runtime.zig").ShutdownResult.joined, shutdown);
}

test "CR0b registered operation deferred poison은 canonical suffix를 호출한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const owner_fd = c.dup(tmp.dir.handle);
    if (owner_fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(owner_fd);
    var owner: app_process_incident_owner.AppProcessIncidentOwner = .{};
    try owner.ensureReady(testing.allocator, owner_fd, identity.process_nonce, 0xC012);
    var owner_settled = false;
    defer if (!owner_settled) {
        app_process_incident_owner.publication_port_testing_api.reset();
        _ = owner.shutdown() catch {};
    };
    try app_process_incident_owner.publication_port_testing_api.install(&owner);

    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();
    const adapter = try testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC013,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
    };
    var permit: maru.observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;

    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeForAdapter(&runtime, adapter);
    defer deinitGenerationRuntimeForAdapter(&runtime);
    try runtime.testingClient().bufferGenerationEventForTest(7, "{\"event\":\"snapshot.invalidated\"}");
    client_slot_mod.registered_operation_poison_testing_api.armAfterValidation();
    defer client_slot_mod.registered_operation_poison_testing_api.reset();
    var pre_publication: app_process_incident_owner.publication_port_testing_api.PrePublicationSnapshot = .{};
    app_process_incident_owner.publication_port_testing_api.armPrePublicationSnapshot(&pre_publication);
    defer app_process_incident_owner.publication_port_testing_api.disarmPrePublicationSnapshot();

    try testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try testing.expect(pre_publication.observed);
    try testing.expect(!pre_publication.first_reason_present);
    try testing.expect(pre_publication.client_was_usable);
    try testing.expectEqual(fds[0], pre_publication.fd);
    try testing.expectEqual(@as(u8, 0), pre_publication.incident_count);
    try testing.expectEqual(@as(u128, 0), pre_publication.pending_slots);
    try testing.expectEqual(@as(u8, 0), pre_publication.reconnect_count);
    try testing.expectEqual(
        @intFromEnum(client_poison.ConnectionReason.local_invariant_violation),
        pre_publication.reason_raw,
    );
    try testing.expectEqual(
        @intFromEnum(connection_incident.SourceSite.client_slot_operation),
        pre_publication.source_site_raw,
    );
    try testing.expectEqual(runtime.currentGeneration().attachment.statePtr().controller_generation, pre_publication.controller_generation);

    const published = adapter.slot.logicalClientConst();
    try testing.expectEqual(client_poison.ConnectionReason.local_invariant_violation, published.first_poison_reason.?);
    try testing.expect(published.first_incident_id.sequence != 0);
    try testing.expect(published.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), published.fd);
    try testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try testing.expectEqual(published.first_incident_id, admission.incident_id);
    try owner.reconnect_admissions.consume(admission);

    app_process_incident_owner.publication_port_testing_api.reset();
    const shutdown = try owner.shutdown();
    owner_settled = true;
    try testing.expectEqual(@import("incident_runtime.zig").ShutdownResult.joined, shutdown);
}

fn deinitGenerationAttachmentFixture(
    attachment: *generation_attachment_mod.GenerationAttachment,
    adapter: *host_adapter_mod.HostAdapter,
) void {
    testing.expectEqual(
        generation_attachment_mod.DeinitOutcome.cleaned,
        attachment.tryDeinit(adapter),
    ) catch @panic("generation attachment fixture cleanup failed");
}

fn runC2TypedFamilySocket(tag: generation_contract.RuntimeRequestTag) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t, expected_method: []const u8, response_payload: []const u8) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            if (std.mem.indexOf(u8, request.payload, expected_method) == null) return;
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                response_payload,
            ) catch return;
            defer std.heap.page_allocator.free(response);
            socket_server.writeAll(fd, response) catch return;
        }
    };
    const response_payload: []const u8 = switch (tag) {
        .resize => "{\"result\":{\"cols\":80,\"rows\":24,\"client_sequence\":1,\"resize_generation\":1,\"changed\":true}}",
        .observation => "{\"result\":{\"metadata_revision\":1,\"metadata\":{\"cwd\":\"/tmp\",\"window_title\":\"c2\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}}",
        .selected_text => "{\"text\":\"x\"}",
        .link_at => "{\"text\":\"\"}",
        .clipboard_write => "{\"b64\":\"\",\"too_large\":0}",
        .find => "{\"count\":0,\"spans\":[]}",
        .select_op => "{\"sel\":false}",
        .notification => "{\"event\":null}",
        .notification_config_update => "{\"applied\":true}",
        .core_command, .report_mouse, .terminate, .detach => "{}",
        .spawn_full, .attach_controller, .attach_observer => unreachable,
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{
        fds[1],
        generation_contract.requestMethod(tag),
        response_payload,
    });
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C200 + @as(u128, @intFromEnum(tag)),
        .parser = framing.FrameParser.init(testing.allocator),
        .compatibility_profile = @import("compatibility.zig").profileForMajor(1).?,
    };
    client.runtime_selected_text_v1 = true;
    client.runtime_link_at_v1 = true;
    client.runtime_clipboard_v1 = true;
    client.runtime_core_command_v1 = true;
    client.notification_stream_auth_v1 = true;
    client.notification_delivery_v1 = true;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
    runtime.currentGeneration().resize_seq = 0;
    runtime.currentGeneration().pump_ended = false;
    if (tag == .clipboard_write) {
        runtime.event_cursor = .{ .observer_generation = runtime.currentGeneration().observation.observer_generation };
        runtime.currentGeneration().observation.clipboard_write_seq = 1;
    }
    switch (tag) {
        .resize => try runtime.resize(80, 24),
        .observation => try runtime.refreshObservation(),
        .selected_text => if (try runtime.selectedText(.{
            .start = .{ .row = 0, .col = 0 },
            .end = .{ .row = 0, .col = 1 },
            .block = false,
        })) |text| runtime.allocator.free(text),
        .link_at => if (try runtime.linkAt(0, 0, 1)) |link| runtime.allocator.free(link.text),
        .clipboard_write => if (try runtime.clipboardWrite()) |value| if (value.text) |text| runtime.allocator.free(text),
        .find => {
            var spans: std.ArrayList(terminal.SelectionSpan) = .empty;
            defer spans.deinit(runtime.allocator);
            _ = try runtime.find("x", 0, false, &spans);
        },
        .select_op => _ = try runtime.selectContentAware("word", 0, 0, ""),
        .core_command => try runtime.sendCoreCommandBlocking(.scroll_to_bottom),
        .report_mouse => try runtime.sendMouseReport(.{
            .button = 0,
            .col = 0,
            .row = 0,
            .x_px = 0,
            .y_px = 0,
            .pressed = true,
            .motion = false,
            .mods = 0,
        }),
        .notification => if (try runtime.takeNotification()) |value| value.deinit(runtime.allocator),
        .notification_config_update => try runtime.updateNotificationConfig(7, true, "workspace"),
        .terminate => runtime.terminate(),
        .detach => {
            runtime.admitDestructiveRuntimeOperation();
            runtime.detachBestEffort();
        },
        .spawn_full, .attach_controller, .attach_observer => unreachable,
    }
    peer.join();
    try testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
}

test "2c3e C2 제품 RPC family는 resize를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.resize);
}

test "2c3e C2 제품 RPC family는 observation을 typed request로 실행한다" {
    try runC2TypedFamilySocket(.observation);
}

test "2c3e C2 제품 RPC family는 selected text를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.selected_text);
}

test "2c3e C2 제품 RPC family는 link at을 typed request로 실행한다" {
    try runC2TypedFamilySocket(.link_at);
}

test "2c3e C2 제품 RPC family는 clipboard write를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.clipboard_write);
}

test "2c3e C2 제품 RPC family는 find를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.find);
}

test "2c3e C2 제품 RPC family는 select op를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.select_op);
}

test "2c3e C2 제품 RPC family는 core command를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.core_command);
}

test "2c3e C2 제품 RPC family는 report mouse를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.report_mouse);
}

test "2c3e C2 제품 RPC family는 notification을 typed request로 실행한다" {
    try runC2TypedFamilySocket(.notification);
}

test "P4 N2b1 제품 RPC family는 실행 중 notification config를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.notification_config_update);
}

test "2c3e C2 제품 RPC family는 terminate를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.terminate);
}

test "2c3e C2 제품 RPC family는 detach를 typed request로 실행한다" {
    try runC2TypedFamilySocket(.detach);
}

const C3CadenceAttachmentMode = enum { legacy, generation };

fn runC3ResponsePredecessor(
    mode: C3CadenceAttachmentMode,
    predecessor: framing.Frame,
    expect_stale: bool,
    expect_snapshot: bool,
) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t, first: framing.Frame) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const first_wire = framing.encodeFrame(
                std.heap.page_allocator,
                first.header,
                first.payload,
            ) catch return;
            defer std.heap.page_allocator.free(first_wire);
            socket_server.writeAll(fd, first_wire) catch return;
            const response_wire = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"result\":{\"metadata_revision\":4,\"metadata\":{\"cwd\":\"/rpc\",\"window_title\":\"rpc\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":4,\"title_generation\":4,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}}",
            ) catch return;
            defer std.heap.page_allocator.free(response_wire);
            socket_server.writeAll(fd, response_wire) catch return;
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], predecessor });
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C300 + @as(u128, @intFromEnum(mode)),
        .parser = framing.FrameParser.init(testing.allocator),
        .metadata_support = .supported,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.currentGeneration().connection = .{ .generation = &adapter };
        runtime.currentGeneration().attachment.deinit();
        runtime.currentGeneration().attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(
            &runtime.currentGeneration().attachment.generation,
            &adapter,
            testing.allocator,
            0xaa,
            7,
        );
        runtime.currentGeneration().attachment.statePtr().role = .controller;
        runtime.currentGeneration().attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.currentGeneration().observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    const outcome = runtime.refreshObservation();
    if (expect_stale) {
        try testing.expectError(error.Unauthorized, outcome);
        try testing.expectEqual(remote_attachment.Role.observer, runtime.currentGeneration().attachment.statePtr().role);
        try testing.expectEqual(@as(u64, 0), runtime.currentGeneration().observation.revision);
    } else {
        try outcome;
        try testing.expectEqual(@as(u64, 4), runtime.currentGeneration().observation.revision);
        if (expect_snapshot) {
            try testing.expectEqual(@as(usize, 1), runtime.testingClient().screen_inbox.pending_stream.items.len);
            try testing.expectEqualStrings(
                predecessor.payload,
                runtime.testingClient().screen_inbox.pending_stream.items[0].payload,
            );
        }
    }
}

fn runC3ResponseFollower(
    mode: C3CadenceAttachmentMode,
    follower: framing.Frame,
    kind: enum { revoke, metadata, snapshot },
) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t, after: framing.Frame) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"result\":{\"metadata_revision\":4,\"metadata\":{\"cwd\":\"/rpc\",\"window_title\":\"rpc\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":4,\"title_generation\":4,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}}",
            ) catch return;
            defer std.heap.page_allocator.free(response);
            const next = framing.encodeFrame(std.heap.page_allocator, after.header, after.payload) catch return;
            defer std.heap.page_allocator.free(next);
            socket_server.writeAll(fd, response) catch return;
            socket_server.writeAll(fd, next) catch return;
            var ack: [1]u8 = undefined;
            _ = c.read(fd, &ack, ack.len);
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], follower });
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C320 + @as(u128, @intFromEnum(mode)),
        .parser = framing.FrameParser.init(testing.allocator),
        .metadata_support = .supported,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.currentGeneration().connection = .{ .generation = &adapter };
        runtime.currentGeneration().attachment.deinit();
        runtime.currentGeneration().attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.currentGeneration().attachment.generation, &adapter, testing.allocator, 0xaa, 7);
        runtime.currentGeneration().attachment.statePtr().role = .controller;
        runtime.currentGeneration().attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer {
        _ = c.write(runtime.testingClient().fd, "x", 1);
        peer.join();
        runtime.currentGeneration().observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    try runtime.refreshObservation();
    try testing.expectEqual(@as(u64, 4), runtime.currentGeneration().observation.revision);
    try testing.expectEqual(remote_attachment.Role.controller, runtime.currentGeneration().attachment.statePtr().role);
    switch (kind) {
        .snapshot => {
            const batch = (try runtime.testingClient().readStreamBatch(7)) orelse return error.TestUnexpectedResult;
            defer batch.deinit();
            try testing.expect(batch.is_snapshot);
            try testing.expectEqualStrings(follower.payload, batch.bytes);
        },
        .revoke, .metadata => {
            try testing.expect((try runtime.testingClient().readStreamBatch(7)) == null);
            const drained = try runtime.drainObservationEvents();
            try testing.expect(drained.metadata);
            if (kind == .revoke) {
                try testing.expectEqual(remote_attachment.Role.observer, runtime.currentGeneration().attachment.statePtr().role);
                try testing.expectEqual(@as(u64, 4), runtime.currentGeneration().attachment.statePtr().controller_generation);
            } else {
                try testing.expectEqual(@as(u64, 5), runtime.currentGeneration().observation.revision);
            }
            const second = try runtime.drainObservationEvents();
            try testing.expect(!second.metadata and !second.ended);
        },
    }
}

fn runC3EofCadence(mode: C3CadenceAttachmentMode, cut: enum { immediate, complete, header, payload }) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t, selected: @TypeOf(cut), closed: *std.atomic.Value(u8)) void {
            defer {
                _ = c.close(fd);
                closed.store(1, .release);
            }
            if (selected == .immediate) return;
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            const response = framing.encodeFrame(
                std.heap.page_allocator,
                .{ .kind = .response, .request_id = request.header.request_id },
                "{\"result\":{\"metadata_revision\":4,\"metadata\":{\"cwd\":\"/rpc\",\"window_title\":\"rpc\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":4,\"title_generation\":4,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}}",
            ) catch return;
            defer std.heap.page_allocator.free(response);
            const len = switch (selected) {
                .immediate => unreachable,
                .complete => response.len,
                .header => protocol.header_size - 1,
                .payload => protocol.header_size + 3,
            };
            socket_server.writeAll(fd, response[0..len]) catch return;
        }
    };
    var peer_closed = std.atomic.Value(u8).init(0);
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], cut, &peer_closed });
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C340 + @as(u128, @intFromEnum(mode)),
        .parser = framing.FrameParser.init(testing.allocator),
        .metadata_support = .supported,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.currentGeneration().connection = .{ .generation = &adapter };
        runtime.currentGeneration().attachment.deinit();
        runtime.currentGeneration().attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.currentGeneration().attachment.generation, &adapter, testing.allocator, 0xaa, 7);
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.currentGeneration().observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    if (cut == .immediate) {
        // 이 행은 연결 중 동시 close 경쟁이 아니라 호출 전에 이미 관측 가능한 EOF의 RX-first 계약을 검증한다.
        try waitRemoteTestFlag(&peer_closed);
        try testing.expectError(error.ConnectionClosed, runtime.refreshObservation());
        try testing.expectEqual(@as(u64, 0), runtime.currentGeneration().observation.revision);
    } else if (cut == .complete) {
        try runtime.refreshObservation();
        try testing.expectEqual(@as(u64, 4), runtime.currentGeneration().observation.revision);
        try testing.expectError(error.ConnectionClosed, runtime.testingClient().readStreamBatch(7));
    } else {
        try testing.expectError(error.ProtocolError, runtime.refreshObservation());
        try testing.expectEqual(@as(u64, 0), runtime.currentGeneration().observation.revision);
    }
    try testing.expect(runtime.testingClient().unusable);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_events.items.len);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().screen_inbox.pending_stream.items.len);
}

fn runC3InvalidCadence(
    mode: C3CadenceAttachmentMode,
    invalid: enum { malformed, unknown, wrong_correlation },
) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    const Peer = struct {
        fn run(fd: c.fd_t, selected: @TypeOf(invalid)) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            if (selected == .malformed) {
                var header = (protocol.Header{
                    .kind = .response,
                    .request_id = request.header.request_id,
                    .payload_len = 0,
                }).encode();
                header[0] ^= 0xff;
                socket_server.writeAll(fd, &header) catch return;
                return;
            }
            const header: protocol.Header = switch (selected) {
                .unknown => .{ .kind = @enumFromInt(0x7fff), .request_id = request.header.request_id },
                .wrong_correlation => .{ .kind = .response, .request_id = request.header.request_id + 1 },
                .malformed => unreachable,
            };
            const wire = framing.encodeFrame(std.heap.page_allocator, header, "{}") catch return;
            defer std.heap.page_allocator.free(wire);
            socket_server.writeAll(fd, wire) catch return;
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], invalid });
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C360 + @as(u128, @intFromEnum(mode)),
        .parser = framing.FrameParser.init(testing.allocator),
        .metadata_support = .supported,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.currentGeneration().connection = .{ .generation = &adapter };
        runtime.currentGeneration().attachment.deinit();
        runtime.currentGeneration().attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.currentGeneration().attachment.generation, &adapter, testing.allocator, 0xaa, 7);
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.currentGeneration().observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    try testing.expectError(error.ProtocolError, runtime.refreshObservation());
    try testing.expect(runtime.testingClient().unusable);
    try testing.expectEqual(@as(u64, 0), runtime.currentGeneration().observation.revision);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_events.items.len);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().screen_inbox.pending_stream.items.len);
}

test "2c3e C3 socket cadence는 response 전 revoke를 먼저 settle하고 stale RPC를 게시하지 않는다" {
    const payload = "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}";
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponsePredecessor(
        mode,
        .{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = @constCast(payload) },
        true,
        false,
    );
}

test "2c3e C3 socket cadence는 response 전 metadata event를 먼저 settle한 뒤 decoder를 한 번 호출한다" {
    const payload = "{\"event\":\"runtime.metadata\",\"metadata_revision\":3,\"metadata\":{\"cwd\":\"/event\",\"window_title\":\"event\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":3,\"title_generation\":3,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponsePredecessor(
        mode,
        .{ .header = .{ .kind = .event, .stream_id = 7 }, .payload = @constCast(payload) },
        false,
        false,
    );
}

test "2c3e C3 socket cadence는 response 전 snapshot을 먼저 보존한 뒤 decoder를 한 번 호출한다" {
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(testing.allocator);
    const meta = try screen_stream.encodeScreenMeta(
        testing.allocator,
        .{ .kind = .screen_meta, .generation = 9 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer testing.allocator.free(meta);
    try screen_stream.appendRecord(&records, testing.allocator, meta);
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponsePredecessor(
        mode,
        .{
            .header = .{
                .kind = .snapshot_chunk,
                .stream_id = 7,
                .flags = protocol.Flags.end_stream,
            },
            .payload = records.items,
        },
        false,
        true,
    );
}

test "2c3e C3 socket cadence는 response 뒤 revoke를 다음 turn에 exact once settle한다" {
    const payload = "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}";
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponseFollower(mode, .{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = @constCast(payload),
    }, .revoke);
}

test "2c3e C3 socket cadence는 response 뒤 metadata event를 다음 turn에 exact once settle한다" {
    const payload = "{\"event\":\"runtime.metadata\",\"metadata_revision\":5,\"metadata\":{\"cwd\":\"/next\",\"window_title\":\"next\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":5,\"title_generation\":5,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponseFollower(mode, .{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = @constCast(payload),
    }, .metadata);
}

test "2c3e C3 socket cadence는 response 뒤 snapshot을 다음 turn에 byte-exact 보존한다" {
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(testing.allocator);
    const meta = try screen_stream.encodeScreenMeta(testing.allocator, .{ .kind = .screen_meta, .generation = 11 }, .{ .cols = 1, .rows = 1, .cursor = .{} });
    defer testing.allocator.free(meta);
    try screen_stream.appendRecord(&records, testing.allocator, meta);
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3ResponseFollower(mode, .{
        .header = .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        .payload = records.items,
    }, .snapshot);
}

test "2c3e C3 socket cadence는 immediate EOF를 선처리하고 완성 response 뒤 EOF를 다음 turn terminal로 보존한다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| {
        try runC3EofCadence(mode, .immediate);
        try runC3EofCadence(mode, .complete);
    }
}

test "2c3e C3 socket cadence는 partial header 뒤 EOF에서 decoder 없이 source-zero로 닫힌다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3EofCadence(mode, .header);
}

test "2c3e C3 socket cadence는 partial payload 뒤 EOF에서 decoder 없이 source-zero로 닫힌다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3EofCadence(mode, .payload);
}

test "2c3e C3 socket cadence는 response 전 malformed frame을 decoder 없이 terminalize한다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3InvalidCadence(mode, .malformed);
}

test "2c3e C3 socket cadence는 unknown kind와 wrong correlation을 decoder 없이 terminalize한다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| {
        try runC3InvalidCadence(mode, .unknown);
        try runC3InvalidCadence(mode, .wrong_correlation);
    }
}

fn runC3UnreadRevokeBeforeTx(mode: C3CadenceAttachmentMode) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0x2C3E_C380 + @as(u128, @intFromEnum(mode)),
        .parser = framing.FrameParser.init(testing.allocator),
        .metadata_support = .supported,
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.currentGeneration().connection = .{ .generation = &adapter };
        runtime.currentGeneration().attachment.deinit();
        runtime.currentGeneration().attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.currentGeneration().attachment.generation, &adapter, testing.allocator, 0xaa, 7);
        runtime.currentGeneration().attachment.statePtr().role = .controller;
        runtime.currentGeneration().attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.currentGeneration().observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    try runtime.direct_input.appendSlice(testing.allocator, "stale-input");
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.currentGeneration().event_generation_tracking = .tracked;
    defer {
        runtime.currentGeneration().observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.currentGeneration().attachment.deinitWithConnection(runtime.currentGeneration().connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    const payload = "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const wire = try framing.encodeFrame(testing.allocator, .{ .kind = .event, .stream_id = 7 }, payload);
    defer testing.allocator.free(wire);
    try socket_server.writeAll(fds[1], wire);
    try testing.expectError(error.Unauthorized, runtime.refreshObservation());
    try testing.expectEqual(remote_attachment.Role.observer, runtime.currentGeneration().attachment.statePtr().role);
    try testing.expectEqual(@as(usize, 0), runtime.direct_input.items.len);
    var poll_fd = posix.pollfd{ .fd = fds[1], .events = c.POLL.IN, .revents = 0 };
    try testing.expectEqual(@as(c_int, 0), c.poll(@ptrCast(&poll_fd), 1, 50));
}

test "2c3e C3 socket cadence는 unread revoke를 queued TX보다 먼저 처리한다" {
    inline for (.{ C3CadenceAttachmentMode.legacy, .generation }) |mode| try runC3UnreadRevokeBeforeTx(mode);
}

fn runPreparationDtoDriftChild(metadata: []const u8) noreturn {
    const generation_transport_mod = @import("generation_transport.zig");
    const Probe = struct {
        fn run(
            _: void,
            _: *generation_transport_mod.GenerationTransport,
            source_owner: anytype,
            view: anytype,
            correlation: anytype,
        ) !void {
            var runtime: RemoteRuntime = undefined;
            try testing_api.initializeDetachedGeneration(&runtime, testing.allocator);
            runtime.allocator = testing.allocator;
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            runtime.blocking_flush_active = false;
            runtime.currentGeneration().resize_generation = 0;
            runtime.currentGeneration().resize_baseline_present = false;
            runtime.currentGeneration().observation = .{};
            runtime.pending_event_owner = .{};
            runtime.runtime_lifetime = .{};
            try runtime.initializePendingEventOwner();
            pending_event_preparation_mod.testing.armObservationContentDriftOnDtoFree();
            try runtime.classifyAndPrepareEventFromSourceForTest(source_owner, view, correlation);
            return error.TestUnexpectedResult;
        }
    };
    generation_transport_mod.testing.withTakenPreparation(metadata, {}, Probe.run) catch
        std.c._exit(125);
    std.c._exit(124);
}

test "C3-3b2b3 DTO role callback drift는 fresh artifact에서 fail-stop한다" {
    // 이 행은 build가 별도로 만든 exact-one death artifact에서만 실행한다.
    // aggregate root에서는 정상 테스트 뒤의 process seal을 물려받으므로 목표 callback을 증명하지 못한다.
    if (builtin.test_functions.len != 1) return;
    const metadata =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/next/repo","window_title":"next work","ssh_remote_dest":"next-host","semantic_state":2,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":false,"observer_generation":10,"title_generation":5,"cols":132,"rows":43,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"codex"}]}}
    ;
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) runPreparationDtoDriftChild(metadata);
    var status: c_int = 0;
    try testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: c_uint = @bitCast(status);
    try testing.expect(std.c.W.IFEXITED(unsigned));
    try testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

test "C3-3b2b3 integration adapter prepares a canonical real-take event" {
    try testing.expectEqual(@as(usize, 2736), @sizeOf(pending_event_owner_mod.PendingEventOwner));
    const expected_runtime_size: usize = switch (builtin.os.tag) {
        .macos => switch (builtin.mode) {
            // 값은 **실측이다** — Debug 와 ReleaseFast 의 델타가 서로 다를 수 있어(필드가 기존 패딩에
            // 들어가면 안 커진다) 한쪽 델타를 다른 쪽에 옮겨 적으면 틀린다.
            .Debug => 11440,
            .ReleaseFast => 11376,
            else => unreachable,
        },
        // ⚠️ 이 두 값은 **이 트리에서 측정할 수 없다.** `remote_runtime` 은 배럴이 macOS 에서만 열어서
        // (session_host.zig `if (builtin.os.tag == .macos)`) linux 로는 이 파일이 아예 컴파일되지 않는다.
        // 그래서 `process_identity` 를 더하면서도 손대지 않았다 — 잴 수 없는 자리에 숫자를 지어 넣지 않는다.
        .linux => switch (builtin.mode) {
            .Debug => 11328,
            .ReleaseFast => 11280,
            else => unreachable,
        },
        else => unreachable,
    };
    const expected_runtime_remainder: usize = switch (builtin.os.tag) {
        .macos => switch (builtin.mode) {
            .Debug => 8704,
            .ReleaseFast => 8640,
            else => unreachable,
        },
        // 위와 같은 이유로 측정 불가 — 원래 값 그대로다.
        .linux => switch (builtin.mode) {
            .Debug => 8608,
            .ReleaseFast => 8560,
            else => unreachable,
        },
        else => unreachable,
    };
    try testing.expectEqual(expected_runtime_size, @sizeOf(RemoteRuntime));
    try testing.expectEqual(
        expected_runtime_remainder,
        @sizeOf(RemoteRuntime) - @sizeOf(pending_event_owner_mod.PendingEventOwner),
    );
    try testing.expectEqual(
        @as(usize, 11_206_656),
        @sizeOf(pending_event_owner_mod.PendingEventOwner) * 4096,
    );
    const generation_transport_mod = @import("generation_transport.zig");
    const Probe = struct {
        fn run(
            fail_index: usize,
            transport: *generation_transport_mod.GenerationTransport,
            source_owner: anytype,
            view: anytype,
            correlation: anytype,
        ) !void {
            const runtime = try testing.allocator.create(RemoteRuntime);
            defer testing.allocator.destroy(runtime);
            var failing = testing.FailingAllocator.init(
                testing.allocator,
                .{ .fail_index = fail_index },
            );
            try testing_api.initializeDetachedGeneration(runtime, failing.allocator());
            runtime.allocator = failing.allocator();
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            defer runtime.direct_input.deinit(runtime.allocator);
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            defer runtime.pending_controls.deinit(runtime.allocator);
            runtime.blocking_flush_active = false;
            runtime.currentGeneration().resize_generation = 0;
            runtime.currentGeneration().resize_baseline_present = false;
            runtime.currentGeneration().observation = .{};
            defer runtime.currentGeneration().observation.deinit(runtime.allocator);
            runtime.pending_event_owner = .{};
            runtime.runtime_lifetime = .{};
            try runtime.initializePendingEventOwner();

            try runtime.classifyAndPrepareEventFromSourceForTest(source_owner, view, correlation);
            const prepared = try runtime.pending_event_owner.borrowPrepared();
            if (fail_index < 5) {
                switch (prepared.event) {
                    .failure => |failure| try testing.expectEqual(
                        @import("runtime_event_prepared_types.zig").PreparationFailure.out_of_memory,
                        failure,
                    ),
                    else => return error.TestUnexpectedResult,
                }
                // Both values are semantically valid and share the same poison effect. Only the
                // keyed publication transcript may distinguish this coherent raw-storage rewrite.
                const original_failure = runtime.pending_event_owner.prepared.failure_raw;
                runtime.pending_event_owner.prepared.failure_raw = @intFromEnum(
                    @import("runtime_event_prepared_types.zig").PreparationFailure.local_resource_exhausted,
                );
                try testing.expectError(
                    error.InvalidOwner,
                    runtime.pending_event_owner.borrowPrepared(),
                );
                runtime.pending_event_owner.prepared.failure_raw = original_failure;
                const original_raw = runtime.pending_event_owner.prepared;
                runtime.pending_event_owner.prepared.prepared_tag_raw = @intFromEnum(
                    @import("runtime_event_prepared_types.zig").PreparedEventTag.ignored,
                );
                runtime.pending_event_owner.prepared.effect_tag_raw = @intFromEnum(
                    @import("runtime_event_prepared_types.zig").EffectTag.none,
                );
                runtime.pending_event_owner.prepared.failure_raw = 0;
                runtime.pending_event_owner.prepared.connection_reason_raw = 0;
                try testing.expectError(
                    error.InvalidOwner,
                    runtime.pending_event_owner.borrowPrepared(),
                );
                runtime.pending_event_owner.prepared = original_raw;
            } else {
                switch (prepared.event) {
                    .metadata_commit => |observation| {
                        try testing.expectEqual(@as(u64, 3), observation.revision);
                        try testing.expectEqualStrings("/next/repo", observation.cwd.items);
                        try testing.expectEqualStrings("next work", observation.window_title.items);
                        try testing.expectEqualStrings("next-host", observation.ssh_remote_dest.items);
                        try testing.expectEqual(@as(usize, 1), observation.foreground_processes.items.len);
                    },
                    else => return error.TestUnexpectedResult,
                }
                try testing.expectEqual(
                    @intFromEnum(@import("pending_event_owner.zig").PendingSourceLeaseState.consumed),
                    runtime.pending_event_owner.source_lease.state_raw,
                );
                try testing.expectEqual(
                    @intFromEnum(@import("pending_event_owner.zig").PendingReleaseState.live),
                    runtime.pending_event_owner.release_receipt.state_raw,
                );
                try testing.expectEqual(
                    @intFromEnum(@import("runtime_lifetime_owner.zig").State.idle),
                    runtime.runtime_lifetime.state_raw,
                );
                try testing.expect(runtime.pending_event_owner.cleanup_graph.cwd.address != 0);
                try testing.expect(runtime.pending_event_owner.cleanup_graph.window_title.address != 0);
                try testing.expect(runtime.pending_event_owner.cleanup_graph.ssh_remote_dest.address != 0);
                try testing.expect(runtime.pending_event_owner.cleanup_graph.foreground_processes.address != 0);

                const source_lease = runtime.pending_event_owner.source_lease;
                runtime.pending_event_owner.source_lease.state_raw =
                    @intFromEnum(@import("pending_event_owner.zig").PendingSourceLeaseState.active);
                try testing.expectError(
                    error.InvalidOwner,
                    runtime.pending_event_owner.borrowPrepared(),
                );
                runtime.pending_event_owner.source_lease = source_lease;

                const release_receipt = runtime.pending_event_owner.release_receipt;
                runtime.pending_event_owner.release_receipt.state_raw =
                    @intFromEnum(@import("pending_event_owner.zig").PendingReleaseState.consumed);
                try testing.expectError(
                    error.InvalidOwner,
                    runtime.pending_event_owner.borrowPrepared(),
                );
                runtime.pending_event_owner.release_receipt = release_receipt;

                var spliced = runtime.pending_event_owner;
                spliced.self_addr = @intFromPtr(&spliced);
                try testing.expectError(error.InvalidOwner, spliced.borrowPrepared());
            }
            try testing.expectError(error.Busy, transport.releaseEvent(source_owner));
            try testing.expectEqual(
                generation_transport_mod.TerminalizeReadiness.busy,
                generation_transport_mod.preflightTerminalizeOwned(transport, transport.owner_addr),
            );
            try testing.expectError(error.Busy, transport.purgeEndedStream());

            if (fail_index >= 5) {
                const cwd = runtime.pending_event_owner.prepared.next_observation.cwd.items;
                cwd[0] ^= 1;
                try testing.expectError(error.InvalidOwner, runtime.pending_event_owner.borrowPrepared());
                cwd[0] ^= 1;
                _ = try runtime.pending_event_owner.borrowPrepared();
                try pending_event_owner_mod.testing.discardPreparedForFixture(
                    &runtime.pending_event_owner,
                    runtime.allocator,
                );
                try testing.expectError(
                    error.InvalidOwner,
                    pending_event_owner_mod.testing.discardPreparedForFixture(
                        &runtime.pending_event_owner,
                        runtime.allocator,
                    ),
                );
            }

            // b2b3 has no product settlement. Restore live authority only so the canonical harness
            // can use the existing release path to reclaim its real attachment fixture.
            try generation_event_contract_mod.testing.rollbackPreparationPending(source_owner);
        }
    };

    const metadata =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/next/repo","window_title":"next work","ssh_remote_dest":"next-host","semantic_state":2,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":false,"observer_generation":10,"title_generation":5,"cols":132,"rows":43,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"codex"}]}}
    ;
    // dto backing plus cwd, window title, SSH destination, and process array are the five actual
    // nonzero allocations for this canonical metadata event. Ordinals 0..4 publish OOM; ordinal 5
    // is the first-success sentinel and proves that the schedule has no undocumented sixth callback.
    for (0..6) |fail_index|
        try generation_transport_mod.testing.withTakenPreparation(metadata, fail_index, Probe.run);
}

test "C3-3b2b3 integration adapter rejects every preflight before source mutation" {
    const generation_transport_mod = @import("generation_transport.zig");
    const RejectProbe = struct {
        fn run(
            scenario: usize,
            transport: *generation_transport_mod.GenerationTransport,
            source_owner: anytype,
            original_view: anytype,
            correlation: anytype,
        ) !void {
            var runtime: RemoteRuntime = undefined;
            try testing_api.initializeDetachedGeneration(&runtime, testing.allocator);
            runtime.allocator = testing.allocator;
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            defer runtime.direct_input.deinit(runtime.allocator);
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            defer runtime.pending_controls.deinit(runtime.allocator);
            runtime.blocking_flush_active = false;
            runtime.currentGeneration().resize_generation = 0;
            runtime.currentGeneration().resize_baseline_present = false;
            runtime.currentGeneration().observation = .{};
            defer runtime.currentGeneration().observation.deinit(runtime.allocator);
            runtime.pending_event_owner = .{};
            runtime.runtime_lifetime = .{};
            try runtime.initializePendingEventOwner();

            var view = original_view;
            var operation_lease: ?runtime_lifetime_owner_mod.RuntimeOperationLease = null;
            defer if (operation_lease) |*lease| runtime.runtime_lifetime.abort(lease);
            switch (scenario) {
                0 => {
                    const preflight = try runtime.runtime_lifetime.preflightPreparation();
                    operation_lease = try runtime.runtime_lifetime.acquirePreparation(preflight);
                    try testing.expectError(
                        error.Busy,
                        runtime.classifyAndPrepareEventFromSourceForTest(source_owner, view, correlation),
                    );
                },
                1 => {
                    view.event.payload = view.event.payload[0 .. view.event.payload.len - 1];
                    try testing.expectError(
                        error.InvalidOwner,
                        runtime.classifyAndPrepareEventFromSourceForTest(source_owner, view, correlation),
                    );
                },
                2 => {
                    runtime.direct_input_offset = 1;
                    try testing.expectError(
                        error.InvalidOwner,
                        runtime.classifyAndPrepareEventFromSourceForTest(source_owner, view, correlation),
                    );
                },
                else => unreachable,
            }

            try testing.expectEqual(
                @intFromEnum(pending_event_owner_mod.PendingLifecycle.idle),
                runtime.pending_event_owner.lifecycle_raw,
            );
            if (scenario != 0) try testing.expectEqual(
                @intFromEnum(runtime_lifetime_owner_mod.State.idle),
                runtime.runtime_lifetime.state_raw,
            );
            const after = try generation_transport_mod.preparationEventViewOwned(transport, source_owner);
            try testing.expect(std.meta.eql(original_view, after));
        }
    };

    const metadata =
        \\{"event":"runtime.metadata","metadata_revision":3,"metadata":{"cwd":"/next/repo","window_title":"next work","ssh_remote_dest":"next-host","semantic_state":2,"alt_active":true,"app_cursor_keys":true,"alternate_scroll":false,"observer_generation":10,"title_generation":5,"cols":132,"rows":43,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"codex"}]}}
    ;
    for (0..3) |scenario|
        try generation_transport_mod.testing.withTakenPreparation(metadata, scenario, RejectProbe.run);
}

fn takeAggregateRevokeForFixture(runtime: *RemoteRuntime) !void {
    try testing.expectEqual(
        @import("generation_transport.zig").EventTakeOutcome.taken,
        try runtime.currentGeneration().attachment.generation.takeEvent(),
    );
}

test "C3-3a3 product remote runtime aggregate rejects central RPC and retains queued mutation" {
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0xC333,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(7, "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":2,\"reason\":\"takeover\"}}");
    try takeAggregateRevokeForFixture(&runtime);
    try runtime.direct_input.appendSlice(testing.allocator, "retained");
    try testing.expect(!(try runtime.pumpQueuedInput()));
    try testing.expectEqualStrings("retained", runtime.direct_input.items);
    try testing.expectError(error.AdminBusy, runtime.callOrdered("runtime.snapshot", "{}"));
    try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try runtime.currentGeneration().attachment.generation.releaseEvent();
}

test "C3-3a3 product remote runtime observer remains a local no-op while aggregate is live" {
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 0xC334,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(7, "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":2,\"reason\":\"takeover\"}}");
    try takeAggregateRevokeForFixture(&runtime);
    try testing.expectEqual(@as(usize, 1), try adapter.slot.current.cleanup_registry.connectionOrderingBlockerCount());
    try runtime.direct_input.appendSlice(testing.allocator, "observer-retained");
    runtime.currentGeneration().attachment.statePtr().role = .observer;
    try testing.expectError(error.Unauthorized, runtime.sendInput("x"));
    try runtime.resize(80, 24);
    try testing.expectEqualStrings("observer-retained", runtime.direct_input.items);
    try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try runtime.currentGeneration().attachment.generation.releaseEvent();
    try testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.connectionOrderingBlockerCount());
    try testing.expectEqualStrings("observer-retained", runtime.direct_input.items);
}

fn writeAggregateRevokeWire(fd: c.fd_t) !void {
    const payload =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":2,\"reason\":\"takeover\"}}";
    const wire = try framing.encodeFrame(testing.allocator, .{ .kind = .event, .stream_id = 7 }, payload);
    defer testing.allocator.free(wire);
    try socket_server.writeAll(fd, wire);
}

fn writeC3cEventWire(fd: c.fd_t, payload: []const u8) !void {
    const wire = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .event, .stream_id = 7 },
        payload,
    );
    defer testing.allocator.free(wire);
    try socket_server.writeAll(fd, wire);
}

fn replaceFixtureConnectionWithOpenPeer(
    runtime: *RemoteRuntime,
    peer_fd: *c.fd_t,
) !void {
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    if (runtime.testingClient().fd >= 0) _ = c.close(runtime.testingClient().fd);
    runtime.testingClient().fd = fds[0];
    peer_fd.* = fds[1];
}

fn expectC3cSourceZero(
    runtime: *RemoteRuntime,
    source_before: testing_api.AppQuitOwnerSnapshot,
    callback_before: usize,
) !void {
    const source = try testing_api.appQuitOwnerSnapshot(runtime);
    try testing.expect(source.pending_idle);
    try testing.expect(source.owner_pristine);
    try testing.expect(source.correlation_pristine);
    try testing.expectEqual(@as(u64, 0), source.event_generation_mirror);
    try testing.expectEqual(source_before.blocker_count, source.blocker_count);
    try testing.expectEqual(source_before.pin_count, source.pin_count);
    try testing.expectEqual(source_before.quarantine_occupied, source.quarantine_occupied);
    try testing.expectEqual(source_before.quarantine_retained_bytes, source.quarantine_retained_bytes);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_events.items.len);
    try testing.expectEqual(
        callback_before + 1,
        generation_attachment_mod.testing_api.pendingEventPayloadCallbackCount(),
    );
}

test "C3-3c 열린 peer의 revoked event는 settlement source-zero 뒤 observer를 게시한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    var peer_fd: c.fd_t = -1;
    try replaceFixtureConnectionWithOpenPeer(&fixture.runtime, &peer_fd);
    defer {
        if (peer_fd >= 0) _ = c.close(peer_fd);
    }
    const source_before = try testing_api.appQuitOwnerSnapshot(&fixture.runtime);
    const callback_before = generation_attachment_mod.testing_api.pendingEventPayloadCallbackCount();
    try writeC3cEventWire(
        peer_fd,
        "{\"event\":\"controller.revoked\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );
    try testing.expect((try fixture.runtime.testingClient().readStreamBatch(7)) == null);
    const result = try fixture.runtime.drainObservationEvents();
    try testing.expect(result.metadata and !result.ended);
    try testing.expectEqual(remote_attachment.Role.observer, fixture.runtime.currentGeneration().attachment.statePtr().role);
    try testing.expectEqual(@as(u64, 4), fixture.runtime.currentGeneration().attachment.statePtr().controller_generation);
    try testing.expect(!fixture.runtime.testingClient().unusable);
    try expectC3cSourceZero(&fixture.runtime, source_before, callback_before);
}

test "C3-3c 열린 peer의 unknown event는 source-zero 뒤 connection을 poison한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    var peer_fd: c.fd_t = -1;
    try replaceFixtureConnectionWithOpenPeer(&fixture.runtime, &peer_fd);
    defer {
        if (peer_fd >= 0) _ = c.close(peer_fd);
    }
    const source_before = try testing_api.appQuitOwnerSnapshot(&fixture.runtime);
    const callback_before = generation_attachment_mod.testing_api.pendingEventPayloadCallbackCount();
    const before_size = fixture.runtime.currentGeneration().observation.size;
    try writeC3cEventWire(peer_fd, "{\"event\":\"future.event\",\"data\":{}}");
    try testing.expect((try fixture.runtime.testingClient().readStreamBatch(7)) == null);
    try testing.expect(fixture.runtime.testingClient().firstPoisonReason() == null);
    try testing.expectError(error.ProtocolError, fixture.runtime.drainObservationEvents());
    try testing.expect(fixture.runtime.testingClient().unusable);
    try testing.expectEqual(
        @import("client_poison.zig").ConnectionReason.peer_contract_violation,
        fixture.runtime.testingClient().firstPoisonReason().?,
    );
    try testing.expectEqual(before_size, fixture.runtime.currentGeneration().observation.size);
    try expectC3cSourceZero(&fixture.runtime, source_before, callback_before);
}

test "C3-3c 열린 peer의 semantic failure는 source-zero 뒤 prepared 의미를 게시하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    var peer_fd: c.fd_t = -1;
    try replaceFixtureConnectionWithOpenPeer(&fixture.runtime, &peer_fd);
    defer {
        if (peer_fd >= 0) _ = c.close(peer_fd);
    }
    fixture.runtime.currentGeneration().resize_generation = 10;
    fixture.runtime.currentGeneration().resize_baseline_present = true;
    fixture.runtime.currentGeneration().observation.size = .{ .cols = 90, .rows = 30 };
    const source_before = try testing_api.appQuitOwnerSnapshot(&fixture.runtime);
    const callback_before = generation_attachment_mod.testing_api.pendingEventPayloadCallbackCount();
    try writeC3cEventWire(
        peer_fd,
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":10,\"reason\":\"controller\"}}",
    );
    try testing.expect((try fixture.runtime.testingClient().readStreamBatch(7)) == null);
    try testing.expectError(error.ProtocolError, fixture.runtime.drainObservationEvents());
    try testing.expect(fixture.runtime.testingClient().unusable);
    try testing.expectEqual(@as(u64, 10), fixture.runtime.currentGeneration().resize_generation);
    try testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.currentGeneration().observation.size);
    try expectC3cSourceZero(&fixture.runtime, source_before, callback_before);
}

fn expectActualSocketWireZero(fd: c.fd_t) !void {
    var poll_fd = posix.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
    try testing.expectEqual(@as(c_int, 0), c.poll(@ptrCast(&poll_fd), 1, 50));
}

test "C3-3a3 actual socket target offset zero is cancelled and aggregate settles to zero" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = fds[0],
        .host_id = 0xC335,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
    const filler_len = try fillRemoteTestSendBuffer(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
    try testing.expectEqual(
        @as(usize, "target-owned-frame".len),
        try runtime.currentGeneration().attachment.generation.sendInputNonBlocking("target-owned-frame"),
    );
    try testing.expectEqual(@as(u64, 7), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.stream_id);
    try testing.expectEqual(@as(usize, 0), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.offset);
    try writeAggregateRevokeWire(fds[1]);
    try testing.expect((try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).readStreamBatch(7)) == null);
    const drained = try runtime.drainObservationEvents();
    try testing.expect(drained.metadata);
    try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.connectionOrderingBlockerCount());
    const filler = try testing.allocator.alloc(u8, filler_len);
    defer testing.allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    try expectActualSocketWireZero(fds[1]);
}

test "C3-3a3 actual socket partial target fails closed and sibling owner resumes after aggregate zero" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    {
        var fds: [2]c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var client: client_mod.Client = .{
            .allocator = testing.allocator,
            .fd = fds[0],
            .host_id = 0xC336,
            .parser = framing.FrameParser.init(testing.allocator),
        };
        var adapter: host_adapter_mod.HostAdapter = undefined;
        var runtime: RemoteRuntime = undefined;
        try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
        defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
        const filler_len = try fillRemoteTestSendBuffer(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
        const payload = try testing.allocator.alloc(u8, 64 * 1024);
        defer testing.allocator.free(payload);
        @memset(payload, 'p');
        try testing.expectEqual(payload.len, try runtime.currentGeneration().attachment.generation.sendInputNonBlocking(payload));
        try testing.expectEqual(@as(usize, 0), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.offset);
        var filler_prefix: [4096]u8 = undefined;
        try readRemoteTestExact(fds[1], &filler_prefix);
        try testing.expect(filler_len >= filler_prefix.len);
        _ = try runtime.currentGeneration().attachment.generation.pumpPendingOutput();
        try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.offset > 0);
        try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.offset <
            host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.frame.len);
        try writeAggregateRevokeWire(fds[1]);
        try testing.expect((try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).readStreamBatch(7)) == null);
        try testing.expectError(error.ConnectionClosed, runtime.drainObservationEvents());
        try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
        try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
        try testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.connectionOrderingBlockerCount());
    }
    {
        var fds: [2]c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var client: client_mod.Client = .{
            .allocator = testing.allocator,
            .fd = fds[0],
            .host_id = 0xC337,
            .parser = framing.FrameParser.init(testing.allocator),
        };
        var adapter: host_adapter_mod.HostAdapter = undefined;
        var runtime: RemoteRuntime = undefined;
        try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
        defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
        var sibling: generation_attachment_mod.GenerationAttachment = .{};
        try generation_attachment_mod.testing_api.initAttached(
            &sibling,
            &adapter,
            testing.allocator,
            0xbb,
            8,
        );
        defer deinitGenerationAttachmentFixture(&sibling, &adapter);
        const filler_len = try fillRemoteTestSendBuffer(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).fd);
        try testing.expectEqual(
            @as(usize, "sibling-owned-frame".len),
            try sibling.sendInputNonBlocking("sibling-owned-frame"),
        );
        const sibling_addr = @intFromPtr(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.frame.ptr);
        try writeAggregateRevokeWire(fds[1]);
        try testing.expect((try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).readStreamBatch(7)) == null);
        _ = try runtime.drainObservationEvents();
        const preserved = host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?;
        try testing.expectEqual(@as(u64, 8), preserved.stream_id);
        try testing.expectEqual(@as(usize, 0), preserved.offset);
        try testing.expectEqual(sibling_addr, @intFromPtr(preserved.frame.ptr));
        try testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.connectionOrderingBlockerCount());
        const filler = try testing.allocator.alloc(u8, filler_len);
        defer testing.allocator.free(filler);
        try readRemoteTestExact(fds[1], filler);
        try testing.expect(try runtime.currentGeneration().attachment.generation.pumpPendingOutput());
        try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
        const frame = try framing.encodeFrame(testing.allocator, .{
            .kind = .input_bytes,
            .stream_id = 8,
        }, "sibling-owned-frame");
        defer testing.allocator.free(frame);
        const received = try testing.allocator.alloc(u8, frame.len);
        defer testing.allocator.free(received);
        try readRemoteTestExact(fds[1], received);
        try testing.expectEqualSlices(u8, frame, received);
    }
}

test "sibling runtime cannot flush a stream whose buffered revoke is not consumed yet" {
    const allocator = testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
        .pending_outbound = .{
            .frame = try allocator.dupe(u8, "stream-eight"),
            .stream_id = 8,
        },
    };
    defer client.deinit();
    try client.bufferGenerationEventForTest(
        8,
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"stream_id\":8,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );

    var sibling: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&sibling, .{ .legacy = &client });
    sibling.pending_event_owner = .{};
    sibling.runtime_lifetime = .{};
    try sibling.initializePendingEventOwner();
    sibling.allocator = allocator;
    sibling.io = testing.io;
    sibling.currentGeneration().attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    defer sibling.currentGeneration().attachment.deinit();
    sibling.direct_input = .empty;
    defer sibling.direct_input.deinit(allocator);
    sibling.input_batches = .{};
    defer sibling.input_batches.deinit(allocator);
    sibling.direct_input_offset = 0;
    sibling.pending_controls = .empty;
    sibling.blocking_flush_active = false;
    defer sibling.pending_controls.deinit(allocator);
    sibling.currentGeneration().resync_needed = false;
    sibling.currentGeneration().observation = .{};

    // A foreign-stream revoke blocks shared wire progress, not local admission for this still-
    // controller sibling. The input remains owned by its bounded queue until stream 8 consumes.
    try sibling.sendInput("preserve-me");
    try sibling.sendInput("-new");
    try sibling.requestScrollToBottom();
    try testing.expectEqual(RemoteRuntime.PumpResult.idle, try sibling.pumpDelta());
    try testing.expectEqualStrings("preserve-me-new", sibling.direct_input.items);
    try testing.expectEqual(@as(usize, 1), sibling.pending_controls.items.len);
    try testing.expectEqual(@as(usize, "preserve-me-new".len), sibling.pending_controls.items[0].barrier);
    try testing.expect(client.pending_outbound != null);
    try testing.expectEqual(@as(usize, 0), client.pending_outbound.?.offset);
    try testing.expect(client.hasBufferedControllerRevoke());
}
const socket_server = @import("socket_server.zig");

fn fillRemoteTestSendBuffer(fd: c.fd_t) !usize {
    var requested: c_int = 4096;
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &requested, @sizeOf(c_int));
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.TestUnexpectedResult;
    const nonblock_flag: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock_flag) < 0) return error.TestUnexpectedResult;
    defer _ = c.fcntl(fd, c.F.SETFL, flags);
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xA5);
    var total: usize = 0;
    while (true) {
        const rc = c.send(fd, &chunk, chunk.len, posix.MSG.DONTWAIT);
        if (rc > 0) {
            total += @intCast(rc);
            if (total > 64 * 1024 * 1024) return error.TestUnexpectedResult;
            continue;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc < 0 and posix.errno(rc) == .AGAIN) return total;
        return error.TestUnexpectedResult;
    }
}

fn readRemoteTestExact(fd: c.fd_t, out: []u8) !void {
    return readRemoteTestExactWithin(fd, out, 10);
}

fn readRemoteTestExactWithin(fd: c.fd_t, out: []u8, timeout_seconds: u64) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds +
        timeout_seconds * std.time.ns_per_s;
    var offset: usize = 0;
    while (offset < out.len) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline)
            return error.RemoteTestDeadlineExceeded;
        var poll_fd = posix.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        const ready = c.poll(@ptrCast(&poll_fd), 1, 50);
        if (ready == 0) continue;
        if (ready < 0) {
            if (posix.errno(ready) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (poll_fd.revents & (c.POLL.ERR | c.POLL.NVAL) != 0)
            return error.TestUnexpectedResult;
        const rc = c.read(fd, out[offset..].ptr, out.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn waitRemoteTestFlag(flag: *std.atomic.Value(u8)) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds +
        10 * std.time.ns_per_s;
    while (flag.load(.acquire) == 0) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline)
            return error.RemoteTestDeadlineExceeded;
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
}

fn remoteOrderingPeer(fd: c.fd_t, expected: []const u8, response: []const u8, ok: *bool) void {
    const received = std.heap.page_allocator.alloc(u8, expected.len) catch return;
    defer std.heap.page_allocator.free(received);
    readRemoteTestExact(fd, received) catch return;
    ok.* = std.mem.eql(u8, expected, received);
    if (response.len > 0) socket_server.writeAll(fd, response) catch return;
}

test "remote runtime retains direct key behind async scroll barrier under socket backpressure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.records.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expect(filler_len > 0);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(9, "A"));

    // 실제 상위 호출 순서: imeBegin이 scroll intent를 만들고, 일반 key writeInput이 B를 보낸다.
    // B는 would-block을 오류로 돌리지 않고 RemoteRuntime이 소유해 재시도해야 한다.
    try rr.requestScrollToBottom();
    try rr.sendInput("B");
    try testing.expectEqualStrings("B", rr.direct_input.items[rr.direct_input_offset..]);
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 9 }, "A");
    defer allocator.free(a_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 9 }, "");
    defer allocator.free(scroll_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 9 }, "B");
    defer allocator.free(b_frame);
    const received = try allocator.alloc(u8, a_frame.len + scroll_frame.len + b_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    var offset: usize = 0;
    try testing.expectEqualSlices(u8, a_frame, received[offset..][0..a_frame.len]);
    offset += a_frame.len;
    try testing.expectEqualSlices(u8, scroll_frame, received[offset..][0..scroll_frame.len]);
    offset += scroll_frame.len;
    try testing.expectEqualSlices(u8, b_frame, received[offset..][0..b_frame.len]);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "managed observation probe stays nonblocking on an actual stalled socket and retires its late event" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_observation_probe_v1 = true,
        .metadata_support = .supported,
        .attachment_capabilities = .{ .peer_attach_generation = true },
        .compatibility_profile = @import("compatibility.zig").profileForMajor(protocol.version_major).?,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    const managed_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);

    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .generation = &adapter });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.runtime_id_hex = "00000000000000000000000000000001".*;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.currentGeneration().observation.deinit(allocator);

    try testing.expectEqual(
        generation_attachment_mod.DeinitOutcome.cleaned,
        rr.currentGeneration().attachment.generation.tryDeinit(&adapter),
    );
    rr.currentGeneration().attachment.generation = .{};
    try generation_attachment_mod.testing_api.initAttached(
        &rr.currentGeneration().attachment.generation,
        &adapter,
        allocator,
        1,
        94,
    );
    defer rr.currentGeneration().attachment.generation.deinit(&adapter);
    const connection_generation = adapter.connectionGeneration();

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expect(filler_len > 0);
    try testing.expectEqual(@as(usize, 1), try managed_client.sendInputNonBlocking(94, "X"));

    const nonce: u64 = 0xBEEF;
    try testing.expectEqual(RemoteRuntime.ObservationProbeAdmission.accepted, try rr.requestObservationProbe(nonce));
    try testing.expectEqual(RemoteRuntime.ObservationProbePoll.pending, rr.pollObservationProbe(nonce));
    try testing.expectEqual(connection_generation, adapter.connectionGeneration());
    try testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);
    try testing.expect(rr.abandonObservationProbe(nonce));
    try testing.expectEqual(RemoteRuntime.ObservationProbePoll.stale, rr.pollObservationProbe(nonce));

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try managed_client.pumpPendingOutput())) {}
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try managed_client.pumpPendingOutput())) {}

    const input_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 94 }, "X");
    defer allocator.free(input_frame);
    var nonce_wire: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_wire, nonce, .big);
    const probe_frame = try framing.encodeFrame(
        allocator,
        .{ .kind = .observation_probe, .stream_id = 94, .flags = protocol.Flags.optional },
        &nonce_wire,
    );
    defer allocator.free(probe_frame);
    const received = try allocator.alloc(u8, input_frame.len + probe_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    try testing.expectEqualSlices(u8, input_frame, received[0..input_frame.len]);
    try testing.expectEqualSlices(u8, probe_frame, received[input_frame.len..]);

    const event_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 94 },
        b4_metadata_probe_noop,
    );
    defer allocator.free(event_wire);
    try socket_server.writeAll(fds[1], event_wire);
    _ = try rr.pumpDelta();
    try testing.expectEqual(@as(u64, 0), rr.currentGeneration().observation_probe_active);
    try testing.expectEqual(@as(u64, 0), rr.currentGeneration().observation_probe_abandoned);
    try testing.expectEqual(@as(u64, 0), rr.currentGeneration().observation_probe_completed);
    try testing.expectEqual(connection_generation, adapter.connectionGeneration());
    try testing.expect(!host_adapter_mod.HostAdapter.testing.rawClient(&adapter).unusable);

    // If the first pump rejects a pre-existing queue transcript after admission, the caller has
    // never received `.accepted`. The runtime must nevertheless retain a tombstone because the
    // just-admitted frame may already have crossed an ownership boundary.
    try rr.pending_controls.append(
        allocator,
        runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(0).?,
    );
    const failed_nonce: u64 = 0xCAFE;
    try testing.expectError(error.ProtocolError, rr.requestObservationProbe(failed_nonce));
    try testing.expectEqual(@as(u64, 0), rr.currentGeneration().observation_probe_active);
    try testing.expectEqual(failed_nonce, rr.currentGeneration().observation_probe_abandoned);
}

test "CR2d1 remote input owner는 paste IME OSC52 batch를 epoch sequence golden queue로 소유한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(allocator, .{ .runtime_id = 1, .stream_id = 91, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    rr.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, rr.enqueueInputBatch(.{ .kind = .paste, .first = "no-mutation" }));
    rr.allocator = allocator;
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
    try testing.expectEqual(@as(u64, 0), rr.input_batches.next_sequence);

    rr.input_batches.epoch = 0;
    try testing.expectError(error.ProtocolError, rr.enqueueInputBatch(.{ .kind = .paste, .first = "zero-epoch" }));
    rr.input_batches.epoch = 1;
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
    try testing.expectEqual(@as(u64, 0), rr.input_batches.next_sequence);

    try rr.direct_input.appendNTimes(allocator, 'q', RemoteRuntime.max_direct_input_bytes);
    try testing.expectError(error.OutOfMemory, rr.enqueueInputBatch(.{ .kind = .paste, .first = "over-cap" }));
    try testing.expectEqual(@as(usize, RemoteRuntime.max_direct_input_bytes), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
    try testing.expectEqual(@as(u64, 0), rr.input_batches.next_sequence);
    rr.direct_input.clearRetainingCapacity();

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expect(filler_len > 0);
    // Client가 이미 한 frame을 소유하게 해 첫 batch도 Client pending 뒤에 머물게 한다. 단순 socket fill만으로는
    // Client 자체의 pending slot이 비어 첫 batch가 그 slot으로 이동해 runtime transcript에서 먼저 retire될 수 있다.
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(91, "X"));
    try rr.enqueueInputBatch(.{ .kind = .paste, .first = "paste|" });
    try rr.enqueueInputBatch(.{ .kind = .ime_commit, .first = "ime\n", .second = "replay|", .normalize_first_newlines = true });
    try rr.enqueueInputBatch(.{ .kind = .osc52_response, .first = "osc52" });
    try testing.expectEqualStrings("paste|ime\rreplay|osc52", rr.direct_input.items[rr.direct_input_offset..]);
    try testing.expectEqual(@as(usize, 3), rr.input_batches.records.items.len);
    inline for (.{ input_owner_mod.QueueRecordKind.paste, .ime_commit, .osc52_response }, 1..) |kind, sequence| {
        const record = rr.input_batches.records.items[sequence - 1];
        try testing.expectEqual(kind, record.kind);
        try testing.expectEqual(@as(u64, 1), record.epoch);
        try testing.expectEqual(@as(u64, sequence), record.sequence);
    }

    const bytes_before = rr.direct_input.items.len;
    rr.input_batches.next_sequence = std.math.maxInt(u64);
    try testing.expectError(error.OutOfMemory, rr.enqueueInputBatch(.{ .kind = .paste, .first = "overflow" }));
    try testing.expectEqual(bytes_before, rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 3), rr.input_batches.records.items.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try client.pumpPendingOutput())) {}
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const x_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 91 }, "X");
    defer allocator.free(x_frame);
    const paste_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 91 }, "paste|ime\rreplay|osc52");
    defer allocator.free(paste_frame);
    const received = try allocator.alloc(u8, x_frame.len + paste_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    try testing.expectEqualSlices(u8, x_frame, received[0..x_frame.len]);
    try testing.expectEqualSlices(u8, paste_frame, received[x_frame.len..]);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
}

test "CR4b stable queue seal은 lease drain 뒤 metadata와 완전 paste만 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "0000000000000000000000000000002a".*;
    rr.direct_input = .empty;
    defer rr.direct_input.deinit(allocator);
    rr.direct_input_offset = 0;
    rr.input_batches = .{};
    defer rr.input_batches.deinit(allocator);
    rr.pending_controls = .empty;
    defer rr.pending_controls.deinit(allocator);
    rr.blocking_flush_active = false;
    try rr.direct_input.appendSlice(allocator, "keypaste");
    try rr.input_batches.records.append(allocator, .{
        .kind = .key_bytes,
        .epoch = 1,
        .sequence = 1,
        .end_offset = 3,
    });
    try rr.input_batches.records.append(allocator, .{
        .kind = .paste,
        .epoch = 1,
        .sequence = 2,
        .end_offset = 8,
    });
    rr.input_batches.next_sequence = 2;
    try rr.mutation_owner.initInPlace(2, 1);
    rr.paused_input_metadata = null;
    rr.paused_paste_store = .{};
    var budget: reconnect_mutation_seal.GlobalPasteBudget = .{};
    try budget.initInPlace();
    defer {
        if (rr.paused_paste_store.initialized()) rr.paused_paste_store.deinit();
        budget.deinit();
    }

    var lease: reconnect_mutation_seal.MutationLease = .{};
    try rr.mutation_owner.beginMutation(2, 1, &lease);
    try testing.expectError(error.Busy, rr.sealReconnectMutationQueue(&budget));
    try testing.expectEqual(reconnect_mutation_seal.MutationLifecycle.sealing, rr.mutation_owner.lifecycle);
    try rr.mutation_owner.finishMutation(&lease);

    try testing.expectEqual(
        reconnect_mutation_seal.SealResult.sealed_clean,
        try rr.sealReconnectMutationQueue(&budget),
    );
    const metadata = rr.paused_input_metadata.?;
    try testing.expectEqual(@as(u32, 2), metadata.total_count);
    try testing.expectEqual(@as(u64, 8), metadata.total_bytes);
    try testing.expectEqual(@as(u32, 1), metadata.kinds[@intFromEnum(reconnect_mutation_seal.SealKind.key_bytes)].count);
    try testing.expectEqual(@as(u32, 1), metadata.kinds[@intFromEnum(reconnect_mutation_seal.SealKind.paste)].count);
    const paste = (try rr.paused_paste_store.projection()).?;
    try testing.expectEqual(@as(u64, 2), paste.id);
    try testing.expectEqual(@as(u64, 5), paste.full_length);
    try testing.expectEqual(@as(usize, 5), budget.reservedBytes());
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
    try testing.expect(rr.reconnectMutationSealDigest() != null);
    var rejected: reconnect_mutation_seal.MutationLease = .{};
    try testing.expectError(error.ReconnectBusy, rr.mutation_owner.beginMutation(2, 1, &rejected));
}

test "CR4b stable queue seal은 partial prefix를 ambiguous로 봉인하고 OOM은 queue mutation 0이다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    {
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
        rr.allocator = allocator;
        rr.io = std.testing.io;
        rr.runtime_id_hex = "0000000000000000000000000000002b".*;
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        try rr.direct_input.appendSlice(allocator, "abcdef");
        rr.direct_input_offset = 2;
        rr.input_batches = .{};
        defer rr.input_batches.deinit(allocator);
        try rr.input_batches.records.append(allocator, .{
            .kind = .key_bytes,
            .epoch = 1,
            .sequence = 1,
            .end_offset = 6,
        });
        rr.input_batches.next_sequence = 1;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.blocking_flush_active = false;
        try rr.mutation_owner.initInPlace(2, 1);
        rr.paused_input_metadata = null;
        rr.paused_paste_store = .{};
        var budget: reconnect_mutation_seal.GlobalPasteBudget = .{};
        try budget.initInPlace();
        defer {
            rr.paused_paste_store.deinit();
            budget.deinit();
        }

        try testing.expectEqual(
            reconnect_mutation_seal.SealResult.sealed_ambiguous,
            try rr.sealReconnectMutationQueue(&budget),
        );
        try testing.expectEqual(
            reconnect_mutation_seal.MutationLifecycle.sealed_ambiguous,
            rr.mutation_owner.lifecycle,
        );
        const metadata = rr.paused_input_metadata.?;
        try testing.expectEqual(@as(u64, 4), metadata.total_bytes);
        try testing.expectEqual(@as(u32, 1), metadata.total_count);
        try testing.expect((try rr.paused_paste_store.projection()) == null);
        try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
        try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
        try testing.expectEqual(@as(usize, 0), budget.reservedBytes());
    }

    {
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer client.deinit();
        var rr: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
        rr.io = std.testing.io;
        rr.runtime_id_hex = "0000000000000000000000000000002c".*;
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        try rr.direct_input.appendSlice(allocator, "retained");
        rr.direct_input_offset = 0;
        rr.input_batches = .{};
        defer rr.input_batches.deinit(allocator);
        try rr.input_batches.records.append(allocator, .{
            .kind = .key_bytes,
            .epoch = 1,
            .sequence = 1,
            .end_offset = 8,
        });
        rr.input_batches.next_sequence = 1;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.blocking_flush_active = false;
        try rr.mutation_owner.initInPlace(2, 1);
        rr.paused_input_metadata = null;
        rr.paused_paste_store = .{};
        var budget: reconnect_mutation_seal.GlobalPasteBudget = .{};
        try budget.initInPlace();
        defer {
            rr.paused_paste_store.deinit();
            budget.deinit();
        }
        var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        rr.allocator = failing.allocator();

        try testing.expectError(error.OutOfMemory, rr.sealReconnectMutationQueue(&budget));
        try testing.expectEqual(reconnect_mutation_seal.MutationLifecycle.open, rr.mutation_owner.lifecycle);
        try testing.expectEqualStrings("retained", rr.direct_input.items);
        try testing.expectEqual(@as(usize, 1), rr.input_batches.records.items.len);
        try testing.expect(rr.paused_input_metadata == null);
        try testing.expect((try rr.paused_paste_store.projection()) == null);
        try testing.expectEqual(@as(usize, 0), budget.reservedBytes());
    }
}

test "CR2d2 remote input owner는 key와 control을 같은 epoch sequence로 ordered merge한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(allocator, .{ .runtime_id = 1, .stream_id = 92, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expect(filler_len > 0);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(92, "X"));
    try rr.sendInput("key|");
    try rr.enqueueInputBatch(.{ .kind = .paste, .first = "paste|" });
    try rr.requestScrollToBottom();
    try rr.sendInput("after|");
    try rr.requestScrollToBottom();
    try rr.queueCoreCommand(.{ .report_focus = true });

    const expected_kinds = [_]input_owner_mod.QueueRecordKind{
        .key_bytes,
        .paste,
        .scroll_to_bottom,
        .key_bytes,
        .scroll_to_bottom,
        .core_command,
    };
    try testing.expectEqual(expected_kinds.len, rr.input_batches.records.items.len);
    for (expected_kinds, 1..) |kind, sequence| {
        const record = rr.input_batches.records.items[sequence - 1];
        try testing.expectEqual(kind, record.kind);
        try testing.expectEqual(@as(u64, 1), record.epoch);
        try testing.expectEqual(@as(u64, sequence), record.sequence);
    }

    const bytes_before = rr.direct_input.items.len;
    const records_before = rr.input_batches.records.items.len;
    const controls_before = rr.pending_controls.items.len;
    rr.input_batches.next_sequence = std.math.maxInt(u64);
    try testing.expectError(error.OutOfMemory, rr.sendInput("overflow"));
    try testing.expectError(error.OutOfMemory, rr.requestScrollToBottom());
    try testing.expectEqual(bytes_before, rr.direct_input.items.len);
    try testing.expectEqual(records_before, rr.input_batches.records.items.len);
    try testing.expectEqual(controls_before, rr.pending_controls.items.len);
    rr.input_batches.next_sequence = @intCast(expected_kinds.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try client.pumpPendingOutput())) {}
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const x_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 92 }, "X");
    defer allocator.free(x_frame);
    const before_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 92 }, "key|paste|");
    defer allocator.free(before_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 92 }, "");
    defer allocator.free(scroll_frame);
    const after_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 92 }, "after|");
    defer allocator.free(after_frame);
    const params = try core_command_wire.encodeParams(allocator, 92, .{ .report_focus = true });
    defer allocator.free(params);
    const command_frame = try framing.encodeFrame(allocator, .{ .kind = .core_command, .stream_id = 92 }, params);
    defer allocator.free(command_frame);
    const total = x_frame.len + before_frame.len + scroll_frame.len + after_frame.len + scroll_frame.len + command_frame.len;
    const received = try allocator.alloc(u8, total);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    var offset: usize = 0;
    inline for (.{ x_frame, before_frame, scroll_frame, after_frame, scroll_frame, command_frame }) |frame| {
        try testing.expectEqualSlices(u8, frame, received[offset..][0..frame.len]);
        offset += frame.len;
    }
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    try testing.expectEqual(@as(usize, 0), rr.input_batches.records.items.len);
}

test "CR2d2 remote control transcript drift는 wire admission 전에 거부된다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(allocator, .{ .runtime_id = 1, .stream_id = 93, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    _ = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expectEqual(@as(usize, "owned".len), try client.sendInputNonBlocking(93, "owned"));
    try rr.requestScrollToBottom();
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try testing.expectEqual(@as(usize, 1), rr.input_batches.records.items.len);
    rr.input_batches.records.items[0].kind = .core_command;

    try testing.expectError(error.ProtocolError, rr.pumpQueuedInput());
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);
    try testing.expectEqual(@as(usize, 1), rr.input_batches.records.items.len);
    try testing.expectEqual(input_owner_mod.QueueRecordKind.core_command, rr.input_batches.records.items[0].kind);
}

test "CR2d3 remote stable shell은 BEL과 OSC52 read cursor를 Window 밖에서 소유한다" {
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeDetachedGeneration(&runtime, testing.allocator);
    runtime.event_cursor = .{};
    runtime.currentGeneration().observation = .{
        .observer_generation = 4,
        .bell_count = 7,
        .clipboard_write_seq = 8,
        .clipboard_read_seq = 9,
    };
    try testing.expect(!runtime.takeBellEvent());
    try testing.expect((try runtime.takeClipboardReadTarget(testing.allocator)) == null);

    runtime.currentGeneration().observation.bell_count = 8;
    runtime.currentGeneration().observation.clipboard_read_seq = 10;
    try runtime.currentGeneration().observation.clipboard_read_target.appendSlice(testing.allocator, "c");
    defer runtime.currentGeneration().observation.clipboard_read_target.deinit(testing.allocator);
    try testing.expect(runtime.takeBellEvent());
    try testing.expect(!runtime.takeBellEvent());
    const target = (try runtime.takeClipboardReadTarget(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("c", target);
    try testing.expect((try runtime.takeClipboardReadTarget(testing.allocator)) == null);

    runtime.currentGeneration().observation.clipboard_read_seq = 11;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, runtime.takeClipboardReadTarget(failing.allocator()));
    try testing.expectEqual(@as(u64, 10), runtime.event_cursor.clipboard_read_seq);
    const retried = (try runtime.takeClipboardReadTarget(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(retried);
    try testing.expectEqualStrings("c", retried);
}

test "remote runtime preserves input core-command input order under socket backpressure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.records.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(10, "A"));
    try rr.queueCoreCommand(.{ .report_focus = true });
    try rr.sendInput("B");
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items.len);

    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 10 }, "A");
    defer allocator.free(a_frame);
    const params = try core_command_wire.encodeParams(allocator, 10, .{ .report_focus = true });
    defer allocator.free(params);
    const command_frame = try framing.encodeFrame(allocator, .{ .kind = .core_command, .stream_id = 10 }, params);
    defer allocator.free(command_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 10 }, "B");
    defer allocator.free(b_frame);
    const received = try allocator.alloc(u8, a_frame.len + command_frame.len + b_frame.len);
    defer allocator.free(received);
    try readRemoteTestExact(fds[1], received);
    var offset: usize = 0;
    try testing.expectEqualSlices(u8, a_frame, received[offset..][0..a_frame.len]);
    offset += a_frame.len;
    try testing.expectEqualSlices(u8, command_frame, received[offset..][0..command_frame.len]);
    offset += command_frame.len;
    try testing.expectEqualSlices(u8, b_frame, received[offset..][0..b_frame.len]);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "CR3a-2c3c C2 remote runtime control cap overflow fail-closes instead of silently losing final state" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    for (0..RemoteRuntime.max_pending_controls) |_| {
        try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
            0,
            .{ .report_focus = true },
        ).?);
    }
    try testing.expectError(error.ConnectionClosed, rr.queueCoreCommand(.{ .report_focus = false }));
    try testing.expect(client.unusable);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "CR3a-2c3c C2 remote runtime control allocation failure also fail-closes instead of silently losing final state" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = failing.allocator();
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    defer rr.pending_controls.deinit(rr.allocator);

    try testing.expectError(error.ConnectionClosed, rr.queueCoreCommand(.{ .report_focus = false }));
    try testing.expect(client.unusable);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "remote runtime owns exact-cap key after client encode OOM and rejects cap plus one" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = client_mod.Client{
        .allocator = failing.allocator(),
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 11, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.records.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.ensureTotalCapacity(allocator, RemoteRuntime.max_direct_input_bytes);

    const exact = try allocator.alloc(u8, RemoteRuntime.max_direct_input_bytes);
    defer allocator.free(exact);
    @memset(exact, 'K');
    // Client frame allocation fails after RemoteRuntime admission. The call still succeeds because the FIFO now
    // owns the key bytes; reporting failure here would permit a caller retry and duplicate later delivery.
    try rr.sendInput(exact);
    try testing.expectEqual(RemoteRuntime.max_direct_input_bytes, rr.direct_input.items.len);
    try testing.expectError(error.OutOfMemory, rr.sendInput("X"));
    try testing.expectEqual(RemoteRuntime.max_direct_input_bytes, rr.direct_input.items.len);

    failing.fail_index = std.math.maxInt(usize);
    const expected = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 11 },
        exact,
    );
    defer allocator.free(expected);
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, remoteOrderingPeer, .{ fds[1], expected, "", &peer_ok });
    while (!(try rr.pumpQueuedInput())) {}
    while (!(try client.pumpPendingOutput())) {}
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
}

test "remote runtime compaction rebases a pending scroll barrier" {
    const allocator = testing.allocator;
    var rr: RemoteRuntime = undefined;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    defer rr.direct_input.deinit(allocator);
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.appendSlice(allocator, "ABC");
    rr.direct_input_offset = 1;
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(2).?);
    rr.compactDirectInput();
    try testing.expectEqualStrings("BC", rr.direct_input.items);
    try testing.expectEqual(@as(usize, 0), rr.direct_input_offset);
    try testing.expectEqual(@as(usize, 1), rr.pending_controls.items[0].barrier);
}

test "remote runtime flushes key and scroll barrier before mouse RPC" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .async_scroll_to_bottom_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 13, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.records.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const filler_len = try fillRemoteTestSendBuffer(fds[0]);
    try testing.expectEqual(@as(usize, 1), try client.sendInputNonBlocking(13, "A"));
    try rr.requestScrollToBottom();
    try rr.sendInput("B");
    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);

    const a_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 13 }, "A");
    defer allocator.free(a_frame);
    const scroll_frame = try framing.encodeFrame(allocator, .{ .kind = .scroll_to_bottom, .stream_id = 13 }, "");
    defer allocator.free(scroll_frame);
    const b_frame = try framing.encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 13 }, "B");
    defer allocator.free(b_frame);
    const params = "{\"stream_id\":13,\"button\":0,\"col\":2,\"row\":3,\"x_px\":4,\"y_px\":5,\"pressed\":true,\"motion\":false,\"mods\":0}";
    const request_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"runtime.report_mouse\",\"params\":{s}}}",
        .{params},
    );
    defer allocator.free(request_payload);
    const request_frame = try framing.encodeFrame(
        allocator,
        .{ .kind = .request, .request_id = 1 },
        request_payload,
    );
    defer allocator.free(request_frame);
    const expected = try allocator.alloc(u8, a_frame.len + scroll_frame.len + b_frame.len + request_frame.len);
    defer allocator.free(expected);
    var offset: usize = 0;
    @memcpy(expected[offset..][0..a_frame.len], a_frame);
    offset += a_frame.len;
    @memcpy(expected[offset..][0..scroll_frame.len], scroll_frame);
    offset += scroll_frame.len;
    @memcpy(expected[offset..][0..b_frame.len], b_frame);
    offset += b_frame.len;
    @memcpy(expected[offset..][0..request_frame.len], request_frame);
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"ok\":true}}",
    );
    defer allocator.free(response);
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, remoteOrderingPeer, .{ fds[1], expected, response, &peer_ok });
    rr.sendMouseReport(.{
        .button = 0,
        .col = 2,
        .row = 3,
        .x_px = 4,
        .y_px = 5,
        .pressed = true,
        .motion = false,
        .mods = 0,
    }) catch |err| {
        peer.join();
        return err;
    };
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
}

test "CR3a-2c3c C3 detach OOM sends no RPC and fail-closes for host lease cleanup" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = client_mod.Client{
        .allocator = failing.allocator(),
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 17, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    // FailingAllocator는 fail_index에서 계속 실패한다. detach request를 만들 수 없어도 shared socket을 닫아
    // host EOF cleanup이 controller lease를 회수해야 한다.
    rr.detachBestEffort();
    try testing.expect(client.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), client.fd);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "CR3a-2c3c C3 terminate OOM discards superseded queued mutation before cleanup attempt" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = client_mod.Client{
        .allocator = failing.allocator(),
        .fd = fds[0],
        .host_id = 1,
        .runtime_core_command_v1 = true,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = failing.allocator();
    rr.runtime_id_hex = "00000000000000000000000000000001".*;
    rr.currentGeneration().attachment = .init(testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 17,
        .role = .controller,
        .controller_generation = 1,
    });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.input_batches.records.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.appendSlice(allocator, "superseded");
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        0,
        .{ .report_focus = true },
    ).?);
    try rr.input_batches.records.append(allocator, .{
        .kind = .core_command,
        .epoch = rr.input_batches.epoch,
        .sequence = 1,
        .end_offset = 0,
    });
    rr.input_batches.next_sequence = 1;

    rr.terminateBestEffort();
    try testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    try testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try testing.expectEqual(@as(usize, 0), rr.direct_input_offset);
    try testing.expect(client.unusable);
}

test "CR3a-2c3a CR3a-2c3c C3 detach Busy fail-closes without mutation or RPC wire" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try client.bufferGenerationEventForTest(
        17,
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"00000000000000000000000000000001\",\"stream_id\":17,\"controller_generation\":2,\"reason\":\"takeover\"}}",
    );
    const pending = try allocator.dupe(u8, "must-not-reach-peer");
    client.pending_outbound = .{ .frame = pending, .stream_id = 17 };

    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.currentGeneration().attachment = .init(testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 17,
        .role = .controller,
        .controller_generation = 1,
    });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    rr.detachBestEffort();
    try testing.expect(client.unusable);
    try testing.expectEqual(@as(c.fd_t, -1), client.fd);
    try testing.expect(client.pending_outbound == null);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

const daemon = @import("daemon.zig");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn signalMetadataParityFifo(path: [:0]const u8) !void {
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{
            .ACCMODE = .WRONLY,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0) catch {
            _ = usleep(20 * 1000);
            continue;
        };
        defer _ = c.close(fd);
        if (c.write(fd, "go\n".ptr, 3) == 3) return;
        return error.FifoSignalFailed;
    }
    return error.FifoReaderUnavailable;
}

fn metadataParitySurfaceContains(runtime: *RemoteRuntime, io: std.Io, expected: []const u8) bool {
    const surface = runtime.surfacePtr();
    surface.lockCore(io);
    defer surface.unlockCore(io);
    const cells = surface.renderSnapshot().cells;
    var matched: usize = 0;
    for (cells) |cell| {
        if (cell.codepoint == expected[matched]) {
            matched += 1;
            if (matched == expected.len) return true;
        } else {
            matched = if (cell.codepoint == expected[0]) 1 else 0;
        }
    }
    return false;
}

fn metadataParityProcessesEqual(
    actual: []const maru.pty.types.ForegroundProcessName,
    expected: []const maru.pty.types.ForegroundProcessName,
) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |left, right| {
        if (left.pid != right.pid or !std.mem.eql(u8, left.slice(), right.slice())) return false;
    }
    return true;
}

test "remote runtime: spawns over the wire, renders host screen into a Surface, and reflects input via delta" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // client-side 원격 runtime: 화면 밖 metadata OSC를 먼저 emit한 뒤 cat으로 전환한다. 실제 독립 host reader가
    // cwd/title/SSH destination을 소유 core에 파싱하고 event wire로 client cache까지 보내는 제품 경로를 함께 고정한다.
    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{
        .command = "/bin/sh",
        .args = &.{
            "-c",
            "printf '\\033]5379;ssh;user@workbox\\007\\033]7;file://localhost/tmp/remote-meta\\007\\033]2;remote-title\\007'; exec /bin/cat",
        },
    }, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

    var metadata_found = false;
    var metadata_attempts: usize = 0;
    while (metadata_attempts < 100 and !metadata_found) : (metadata_attempts += 1) {
        _ = rr.pumpDelta() catch break;
        metadata_found = std.mem.eql(u8, rr.currentGeneration().observation.cwd.items, "/tmp/remote-meta");
        if (!metadata_found) _ = usleep(20 * 1000);
    }
    try testing.expect(metadata_found);
    try testing.expectEqualStrings("remote-title", rr.currentGeneration().observation.window_title.items);
    try testing.expect(rr.currentGeneration().observation.ssh_remote_dest_present);
    try testing.expectEqualStrings("user@workbox", rr.currentGeneration().observation.ssh_remote_dest.items);

    // 입력을 보내면 host가 echo → 화면 row0이 바뀌고 delta가 온다. pumpDelta는 논블로킹이라 delta가 도착할 때까지 폴링한다
    // (host delta tick ~20ms). Surface에 "h"가 반영되는지 본다.
    try rr.sendInput("hello\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // 원격 runtime의 화면 변화가 client Surface에 반영됐다.
}

// code-review #1 회귀 — 두 원격 runtime이 **connection 하나**를 공유할 때, 예전엔 한 runtime의 pump가 소켓에서 다른
// runtime의 배치를 읽어 free해(discard) 두 번째 화면이 영구 유실됐다. client의 stream_id demux가 남의 배치를 버퍼해 그
// runtime pump로 보내므로 **둘 다** 자기 echo를 화면에 반영해야 한다. 실 fork host + 실 socket이라 macOS opt-in.
test "remote runtime: two runtimes sharing one connection both receive their own screen updates (demux)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-mux-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // 한 client에 두 원격 runtime을 띄운다(둘 다 /bin/cat). 서로 다른 host runtime → 서로 다른 stream_id로 attach된다.
    var rr1: RemoteRuntime = undefined;
    try rr1.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr1.deinit();
    var rr2: RemoteRuntime = undefined;
    try rr2.spawn(&client, allocator, io, 2, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr2.deinit();
    try testing.expect(rr1.currentGeneration().attachment.streamId() != rr2.currentGeneration().attachment.streamId()); // 공유 connection이지만 stream이 갈린다.

    const s1 = rr1.surfacePtr();
    const s2 = rr2.surfacePtr();

    // 각 runtime에 **다른** 입력을 보낸다 → host가 각자 echo → 각 stream에 delta가 온다. 두 pump를 매 tick 함께 돌려
    // (frame loop처럼) 둘 다 자기 echo('h'/'w')를 반영하는지 본다. demux 없으면 먼저 도는 pump가 남의 배치를 삼켜 하나는
    // 영영 못 받는다.
    try rr1.sendInput("hello\n");
    try rr2.sendInput("world\n");
    var f1 = false;
    var f2 = false;
    var attempts: usize = 0;
    while (attempts < 200 and !(f1 and f2)) : (attempts += 1) {
        _ = rr1.pumpDelta() catch break;
        _ = rr2.pumpDelta() catch break;
        s1.lockCore(io);
        const a = s1.renderSnapshot().cells[0].codepoint;
        s1.unlockCore(io);
        s2.lockCore(io);
        const b = s2.renderSnapshot().cells[0].codepoint;
        s2.unlockCore(io);
        if (a == 'h') f1 = true;
        if (b == 'w') f2 = true;
        if (!(f1 and f2)) _ = usleep(20 * 1000);
    }
    try testing.expect(f1); // rr1 화면이 자기 echo를 받았다.
    try testing.expect(f2); // rr2도 — 남의 pump에 배치를 뺏기지 않았다(demux).
}

// ⚠️ **픽스처의 순서는 제품 순서다**: `5379`(ssh 진입) → 그 세션의 `OSC 7` → 제목.
//
// 예전에는 `OSC 7 → 제목 → 5379` 였는데, 그 순서는 제품에서 일어나지 않는다 — `maru ssh` 래퍼는
// **exec 직전**에 5379 를 보내므로 그 앞의 OSC 7 은 「ssh 를 치기 직전 로컬 셸」의 것이고, 진입과 함께
// 무효가 된다(`dispatchMaru` — ssh-integration.md §9.6). 그 규칙이 들어오면서 옛 순서는 「cwd 가 남아
// 있다」를 더 이상 만족하지 못한다. 이 test 가 무는 것은 **런타임별 메타데이터 격리**이지 순서가 아니라,
// 순서만 실제와 맞췄다.
test "P3-e4d-1 actual metadata events stay isolated and reattach starts current" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-e4d1-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&socket_buf, "{s}/control.sock", .{dir_path}) catch
        return error.SkipZigTest;
    var fifo_a_buf: [256]u8 = undefined;
    const fifo_a = std.fmt.bufPrintZ(&fifo_a_buf, "/tmp/maru-e4d1-a-{d}.fifo", .{c.getpid()}) catch
        return error.SkipZigTest;
    var fifo_b_buf: [256]u8 = undefined;
    const fifo_b = std.fmt.bufPrintZ(&fifo_b_buf, "/tmp/maru-e4d1-b-{d}.fifo", .{c.getpid()}) catch
        return error.SkipZigTest;
    var commit_buf: [256]u8 = undefined;
    const detached_commit = std.fmt.bufPrintZ(&commit_buf, "/tmp/maru-e4d1-a2-{d}.commit", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(fifo_a.ptr);
    _ = c.unlink(fifo_b.ptr);
    _ = c.unlink(detached_commit.ptr);
    if (mkfifo(fifo_a.ptr, 0o600) != 0) return error.SkipZigTest;
    defer _ = c.unlink(fifo_a.ptr);
    if (mkfifo(fifo_b.ptr, 0o600) != 0) return error.SkipZigTest;
    defer _ = c.unlink(fifo_b.ptr);
    defer _ = c.unlink(detached_commit.ptr);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |value| break :blk value else |_| {
                _ = usleep(20 * 1000);
            }
        }
        return error.TestUnexpectedResult;
    };
    // HostAdapter moves the connected Client into its final-address ClientSlot. The adapter is
    // therefore the sole transport owner for both runtimes and their reconnect generation.
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var command_a_buf: [2048]u8 = undefined;
    const command_a = try std.fmt.bufPrint(
        &command_a_buf,
        "printf '\\033]5379;ssh;a0\\007\\033]7;file://localhost/tmp/e4d-a0\\007\\033]2;e4d-a0\\007A0\\n'; " ++
            "IFS= read -r _ < '{s}'; " ++
            "printf '\\033]5379;ssh;a1\\007\\033]7;file://localhost/tmp/e4d-a1\\007\\033]2;e4d-a1\\007A1\\n'; " ++
            "IFS= read -r _ < '{s}'; " ++
            "printf '\\033]5379;ssh;a2\\007\\033]7;file://localhost/tmp/e4d-a2\\007\\033]2;e4d-a2\\007A2\\n'; " ++
            "stty -icanon -echo min 0 time 30 2>/dev/null; printf '\\033]11;?\\033\\\\'; " ++
            "dd bs=64 count=1 >/dev/null 2>/dev/null; : > '{s}'; exec /bin/cat",
        .{ fifo_a, fifo_a, detached_commit },
    );
    var command_b_buf: [1536]u8 = undefined;
    const command_b = try std.fmt.bufPrint(
        &command_b_buf,
        "printf '\\033]5379;ssh;b0\\007\\033]7;file://localhost/tmp/e4d-b0\\007\\033]2;e4d-b0\\007B0\\n'; " ++
            "IFS= read -r _ < '{s}'; " ++
            "printf '\\033]5379;ssh;b1\\007\\033]7;file://localhost/tmp/e4d-b1\\007\\033]2;e4d-b1\\007B1\\n'; " ++
            "exec /bin/cat",
        .{fifo_b},
    );

    var runtime_a: RemoteRuntime = undefined;
    var runtime_a_live = false;
    defer if (runtime_a_live) runtime_a.deinit();
    try runtime_a.spawnWithAdapter(&adapter, allocator, io, 1, .{
        .command = "/bin/sh",
        .args = &.{ "-c", command_a },
    }, .{ .cols = 40, .rows = 10 }, null);
    runtime_a_live = true;
    var runtime_b: RemoteRuntime = undefined;
    try runtime_b.spawnWithAdapter(&adapter, allocator, io, 2, .{
        .command = "/bin/sh",
        .args = &.{ "-c", command_b },
    }, .{ .cols = 40, .rows = 10 }, null);
    defer runtime_b.deinit();

    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        const a = &runtime_a.currentGeneration().observation;
        const b = &runtime_b.currentGeneration().observation;
        if (std.mem.eql(u8, a.cwd.items, "/tmp/e4d-a0") and
            std.mem.eql(u8, b.cwd.items, "/tmp/e4d-b0") and
            metadataParitySurfaceContains(&runtime_a, io, "A0") and
            metadataParitySurfaceContains(&runtime_b, io, "B0")) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 150);

    // Let the foreground sampler settle while both children are blocked in the shell builtin read.
    // The product deadline is 500ms. The old 10 * 20ms wait captured the attach-time foreground
    // revision as the baseline, so the first legitimate sampler publication during A's update made
    // B look contaminated. Cross at least one full deadline before freezing pointer/revision identity.
    for (0..35) |_| {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        _ = usleep(20 * 1000);
    }
    const b_before = &runtime_b.currentGeneration().observation;
    const b_revision = b_before.revision;
    const b_cwd_ptr = b_before.cwd.items.ptr;
    const b_title_ptr = b_before.window_title.items.ptr;
    const b_ssh_ptr = b_before.ssh_remote_dest.items.ptr;
    const b_process_ptr = b_before.foreground_processes.items.ptr;
    const b_pgid = b_before.foreground_pgid;
    const b_processes = try allocator.dupe(
        maru.pty.types.ForegroundProcessName,
        b_before.foreground_processes.items,
    );
    defer allocator.free(b_processes);

    try signalMetadataParityFifo(fifo_a);
    attempts = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        if (std.mem.eql(u8, runtime_a.currentGeneration().observation.cwd.items, "/tmp/e4d-a1") and
            metadataParitySurfaceContains(&runtime_a, io, "A1")) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 150);
    const b_after_a = &runtime_b.currentGeneration().observation;
    try testing.expectEqual(b_revision, b_after_a.revision);
    try testing.expectEqual(b_cwd_ptr, b_after_a.cwd.items.ptr);
    try testing.expectEqual(b_title_ptr, b_after_a.window_title.items.ptr);
    try testing.expectEqual(b_ssh_ptr, b_after_a.ssh_remote_dest.items.ptr);
    try testing.expectEqual(b_process_ptr, b_after_a.foreground_processes.items.ptr);
    try testing.expectEqual(b_pgid, b_after_a.foreground_pgid);
    try testing.expect(metadataParityProcessesEqual(b_after_a.foreground_processes.items, b_processes));
    try testing.expectEqualStrings("/tmp/e4d-b0", b_after_a.cwd.items);
    try testing.expectEqualStrings("e4d-b0", b_after_a.window_title.items);
    try testing.expectEqualStrings("b0", b_after_a.ssh_remote_dest.items);

    const a_after_first = &runtime_a.currentGeneration().observation;
    const a_revision = a_after_first.revision;
    const a_cwd_ptr = a_after_first.cwd.items.ptr;
    const a_title_ptr = a_after_first.window_title.items.ptr;
    const a_ssh_ptr = a_after_first.ssh_remote_dest.items.ptr;
    const a_process_ptr = a_after_first.foreground_processes.items.ptr;
    const a_pgid = a_after_first.foreground_pgid;
    const a_processes = try allocator.dupe(
        maru.pty.types.ForegroundProcessName,
        a_after_first.foreground_processes.items,
    );
    defer allocator.free(a_processes);
    try signalMetadataParityFifo(fifo_b);
    attempts = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        if (std.mem.eql(u8, runtime_b.currentGeneration().observation.cwd.items, "/tmp/e4d-b1") and
            metadataParitySurfaceContains(&runtime_b, io, "B1")) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 150);
    for (0..10) |_| {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        _ = usleep(20 * 1000);
    }
    const b_after_update_revision = runtime_b.currentGeneration().observation.revision;
    const a_after_b = &runtime_a.currentGeneration().observation;
    try testing.expectEqual(a_revision, a_after_b.revision);
    try testing.expectEqual(a_cwd_ptr, a_after_b.cwd.items.ptr);
    try testing.expectEqual(a_title_ptr, a_after_b.window_title.items.ptr);
    try testing.expectEqual(a_ssh_ptr, a_after_b.ssh_remote_dest.items.ptr);
    try testing.expectEqual(a_process_ptr, a_after_b.foreground_processes.items.ptr);
    try testing.expectEqual(a_pgid, a_after_b.foreground_pgid);
    try testing.expect(metadataParityProcessesEqual(a_after_b.foreground_processes.items, a_processes));
    try testing.expectEqualStrings("/tmp/e4d-a1", a_after_b.cwd.items);
    try testing.expectEqualStrings("e4d-a1", a_after_b.window_title.items);
    try testing.expectEqualStrings("a1", a_after_b.ssh_remote_dest.items);

    const runtime_id_a = runtime_a.runtimeIdHex();
    runtime_a.detachClientSide();
    runtime_a_live = false;
    try signalMetadataParityFifo(fifo_a);
    attempts = 0;
    while (attempts < 150 and c.access(detached_commit.ptr, c.F_OK) != 0) : (attempts += 1)
        _ = usleep(20 * 1000);
    try testing.expect(c.access(detached_commit.ptr, c.F_OK) == 0);

    // The child creates detached_commit only after receiving the OSC 11 reply. That reply is emitted
    // by the host reader after it has parsed the preceding A2 metadata, so this attach cannot race the
    // metadata commit. attachExisting must publish the current full-state before returning; no pump is
    // allowed between return and these assertions.
    var reattached: RemoteRuntime = undefined;
    try RemoteRuntime.attachExistingWithAdapter(
        &reattached,
        &adapter,
        allocator,
        io,
        3,
        runtime_id_a,
        .{ .cols = 40, .rows = 10 },
    );
    defer reattached.deinit();
    try testing.expectEqual(runtime_id_a, reattached.runtimeIdHex());
    const current = &reattached.currentGeneration().observation;
    try testing.expect(current.revision != 0);
    try testing.expectEqualStrings("/tmp/e4d-a2", current.cwd.items);
    try testing.expectEqualStrings("e4d-a2", current.window_title.items);
    try testing.expect(current.ssh_remote_dest_present);
    try testing.expectEqualStrings("a2", current.ssh_remote_dest.items);
    try testing.expect(metadataParitySurfaceContains(&reattached, io, "A2"));
    try testing.expectEqual(b_after_update_revision, runtime_b.currentGeneration().observation.revision);
    try testing.expectEqualStrings("/tmp/e4d-b1", runtime_b.currentGeneration().observation.cwd.items);
}

test "K3 actual daemon kernel cwd survives detach and preserves authority isolation" {
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var control_dir_buf: [256]u8 = undefined;
    const control_dir = std.fmt.bufPrintZ(&control_dir_buf, "/tmp/maru-sh-k3-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&socket_buf, "{s}/control.sock", .{control_dir}) catch
        return error.SkipZigTest;
    var cwd_a0_buf: [256]u8 = undefined;
    const cwd_a0 = std.fmt.bufPrintZ(&cwd_a0_buf, "/private/tmp/maru-k3-a0-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var cwd_a1_buf: [256]u8 = undefined;
    const cwd_a1 = std.fmt.bufPrintZ(&cwd_a1_buf, "/private/tmp/maru-k3-a1-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var cwd_b_buf: [256]u8 = undefined;
    const cwd_b = std.fmt.bufPrintZ(&cwd_b_buf, "/private/tmp/maru-k3-b-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var fifo_buf: [256]u8 = undefined;
    const fifo = std.fmt.bufPrintZ(&fifo_buf, "/tmp/maru-k3-{d}.fifo", .{c.getpid()}) catch
        return error.SkipZigTest;
    var detached_commit_buf: [256]u8 = undefined;
    const detached_commit = std.fmt.bufPrintZ(&detached_commit_buf, "/tmp/maru-k3-{d}.detached", .{c.getpid()}) catch
        return error.SkipZigTest;
    var cat_ready_buf: [256]u8 = undefined;
    const cat_ready = std.fmt.bufPrintZ(&cat_ready_buf, "/tmp/maru-k3-{d}.cat", .{c.getpid()}) catch
        return error.SkipZigTest;

    _ = c.unlink(fifo.ptr);
    _ = c.unlink(detached_commit.ptr);
    _ = c.unlink(cat_ready.ptr);
    _ = c.rmdir(cwd_a0.ptr);
    _ = c.rmdir(cwd_a1.ptr);
    _ = c.rmdir(cwd_b.ptr);
    if (mkdir(cwd_a0.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(cwd_a0.ptr);
    if (mkdir(cwd_a1.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(cwd_a1.ptr);
    if (mkdir(cwd_b.ptr, 0o700) != 0) return error.SkipZigTest;
    defer _ = c.rmdir(cwd_b.ptr);
    if (mkfifo(fifo.ptr, 0o600) != 0) return error.SkipZigTest;
    defer _ = c.unlink(fifo.ptr);
    defer _ = c.unlink(detached_commit.ptr);
    defer _ = c.unlink(cat_ready.ptr);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, control_dir, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(control_dir.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |value| break :blk value else |_| {
                _ = usleep(20 * 1000);
            }
        }
        return error.TestUnexpectedResult;
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var command_a_buf: [1536]u8 = undefined;
    const command_a = try std.fmt.bufPrint(
        &command_a_buf,
        "cd '{s}'; IFS= read -r _ < '{s}'; " ++
            "cd '{s}'; sleep 1; : > '{s}'; IFS= read -r _ < '{s}'; : > '{s}'; exec /bin/cat",
        .{ cwd_a0, fifo, cwd_a1, detached_commit, fifo, cat_ready },
    );
    var command_b_buf: [512]u8 = undefined;
    const command_b = try std.fmt.bufPrint(&command_b_buf, "cd '{s}'; exec /bin/cat", .{cwd_b});

    var runtime_a: RemoteRuntime = undefined;
    var runtime_a_live = false;
    defer if (runtime_a_live) runtime_a.deinit();
    try runtime_a.spawnWithAdapter(&adapter, allocator, io, 1, .{
        .command = "/bin/sh",
        .args = &.{ "-c", command_a },
        .shell_integration = null,
    }, .{ .cols = 80, .rows = 24 }, null);
    runtime_a_live = true;
    var runtime_b: RemoteRuntime = undefined;
    try runtime_b.spawnWithAdapter(&adapter, allocator, io, 2, .{
        .command = "/bin/sh",
        .args = &.{ "-c", command_b },
        .shell_integration = null,
    }, .{ .cols = 80, .rows = 24 }, null);
    defer runtime_b.deinit();

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        const a = &runtime_a.currentGeneration().observation;
        const b = &runtime_b.currentGeneration().observation;
        if (std.mem.eql(u8, a.cwd.items, cwd_a0) and a.cwd_host.items.len != 0 and
            std.mem.eql(u8, b.cwd.items, cwd_b) and b.cwd_host.items.len != 0) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 200);
    const authority = try allocator.dupe(u8, runtime_a.currentGeneration().observation.cwd_host.items);
    defer allocator.free(authority);
    try testing.expectEqualStrings(authority, runtime_b.currentGeneration().observation.cwd_host.items);

    // Cross another full sampler interval before freezing B. A's detached update must not advance or
    // replace the sibling observation, even though both runtimes share one HostAdapter and connection.
    for (0..35) |_| {
        _ = try runtime_a.pumpDelta();
        _ = try runtime_b.pumpDelta();
        _ = usleep(20 * 1000);
    }
    const b_revision = runtime_b.currentGeneration().observation.revision;
    const b_cwd_ptr = runtime_b.currentGeneration().observation.cwd.items.ptr;
    const b_host_ptr = runtime_b.currentGeneration().observation.cwd_host.items.ptr;

    const runtime_id_a = runtime_a.runtimeIdHex();
    runtime_a.detachClientSide();
    runtime_a_live = false;
    try signalMetadataParityFifo(fifo);
    attempts = 0;
    while (attempts < 150 and c.access(detached_commit.ptr, c.F_OK) != 0) : (attempts += 1)
        _ = usleep(20 * 1000);
    try testing.expect(c.access(detached_commit.ptr, c.F_OK) == 0);

    var reattached: RemoteRuntime = undefined;
    try RemoteRuntime.attachExistingWithAdapter(
        &reattached,
        &adapter,
        allocator,
        io,
        3,
        runtime_id_a,
        .{ .cols = 80, .rows = 24 },
    );
    defer reattached.deinit();
    // attachExisting assembles the initial full-state before returning. A pump here would weaken the
    // restore contract by allowing a later delta to hide stale attach metadata.
    const current = &reattached.currentGeneration().observation;
    try testing.expectEqualStrings(cwd_a1, current.cwd.items);
    try testing.expectEqualStrings(authority, current.cwd_host.items);
    try testing.expectEqual(b_revision, runtime_b.currentGeneration().observation.revision);
    try testing.expectEqual(b_cwd_ptr, runtime_b.currentGeneration().observation.cwd.items.ptr);
    try testing.expectEqual(b_host_ptr, runtime_b.currentGeneration().observation.cwd_host.items.ptr);
    try testing.expectEqualStrings(cwd_b, runtime_b.currentGeneration().observation.cwd.items);
    try testing.expectEqualStrings(authority, runtime_b.currentGeneration().observation.cwd_host.items);

    try signalMetadataParityFifo(fifo);
    attempts = 0;
    while (attempts < 150 and c.access(cat_ready.ptr, c.F_OK) != 0) : (attempts += 1)
        _ = usleep(20 * 1000);
    try testing.expect(c.access(cat_ready.ptr, c.F_OK) == 0);

    try reattached.sendInput("\x1b]7;file://localhost/tmp/maru-k3-osc\x07\n");
    attempts = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = try reattached.pumpDelta();
        const observation = &reattached.currentGeneration().observation;
        if (std.mem.eql(u8, observation.cwd.items, "/tmp/maru-k3-osc") and
            std.mem.eql(u8, observation.cwd_host.items, "localhost")) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 150);

    // RIS clears OSC cwd, then the known SSH destination must suppress the still-valid local kernel
    // cache. Waiting beyond 500ms proves a later sampler tick cannot leak the local ssh-client cwd.
    try reattached.sendInput("\x1bc\x1b]5379;ssh;user@remote\x07\n");
    for (0..45) |_| {
        _ = try reattached.pumpDelta();
        _ = usleep(20 * 1000);
    }
    const ssh_observation = &reattached.currentGeneration().observation;
    try testing.expect(ssh_observation.ssh_remote_dest_present);
    try testing.expectEqualStrings("user@remote", ssh_observation.ssh_remote_dest.items);
    try testing.expectEqual(@as(usize, 0), ssh_observation.cwd.items.len);
    try testing.expectEqual(@as(usize, 0), ssh_observation.cwd_host.items.len);

    try reattached.sendInput("\x1b]5379;ssh-end\x07\x1b]7;file://remote.example/tmp/remote-k3\x07\n");
    attempts = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = try reattached.pumpDelta();
        const observation = &reattached.currentGeneration().observation;
        if (!observation.ssh_remote_dest_present and
            std.mem.eql(u8, observation.cwd.items, "/tmp/remote-k3") and
            std.mem.eql(u8, observation.cwd_host.items, "remote.example")) break;
        _ = usleep(20 * 1000);
    }
    try testing.expect(attempts < 150);
}

test "remote runtime: attachExisting reconnects to a pre-existing host runtime and renders its screen" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-att-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // host에 runtime을 하나 띄운다(raw runtime.spawn — client controller 없이). runtime_id를 얻어 "재실행 후 재접속" 상황을 만든다.
    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = client_mod.extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false);
        return;
    };

    // **재접속**: attachExisting으로 그 runtime에 붙어 원격-backed Surface를 세운다(spawn 없이 — 저장된 runtime_id로).
    var rr: RemoteRuntime = undefined;
    try rr.attachExisting(&client, allocator, io, 1, rid, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();
    try testing.expectEqual(rid, rr.runtimeIdHex()); // 재접속한 runtime_id가 저장한 값과 같다.

    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0); // 그 runtime의 화면(빈 40x10 cat)을 조립했다.

    // 재접속한 controller로 입력→echo→화면 반영(재접속이 실제 제어권을 얻었다).
    try rr.sendInput("hi\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found);

    // 없는 runtime_id에 attachExisting → **error.RuntimeNotFound**. host가 `runtime_not_found`를 긍정적으로 응답했다는
    // 뜻이라 그 handle은 다시는 붙을 수 없고, restore caller가 그 Term만 종료 placeholder로 둘 수 있다(§7 접속 실패
    // 행렬). 뭉뚱그린 AttachFailed로 남기면 일시 장애와 구분이 안 돼 살아 있는 세션까지 버리게 된다. 실패해도 남의
    // runtime을 안 죽인다(terminate errdefer 없음).
    var bogus: RemoteRuntime = undefined;
    const bogus_id: [32]u8 = "deadbeefdeadbeefdeadbeefdeadbeef".*;
    try testing.expectError(error.RuntimeNotFound, bogus.attachExisting(&client, allocator, io, 2, bogus_id, .{ .cols = 40, .rows = 10 }));
}

test "P4 N2b1 product runtime pulls stable host OSC notification" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-notif-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawnWithConfigAndNotification(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 }, null, .{
        .config_generation = 1,
        .notifications_osc = true,
        .display_label = "workspace",
    });
    defer rr.deinit();

    // 처음엔 대기 알림 없음(fresh cat).
    if (try rr.takeNotification()) |n| {
        n.deinit(allocator);
        try testing.expect(false);
    }

    // OSC 777 알림 시퀀스를 입력 → cat이 raw로 echo → host core가 파싱 → notification pending. 폴링으로 뺀다(host tick·echo 대기).
    try rr.sendInput("\x1b]777;notify;Deploy;done in 3s\x1b\\\n");
    var got: ?Notification = null;
    var attempts: usize = 0;
    while (attempts < 100 and got == null) : (attempts += 1) {
        got = try rr.takeNotification();
        if (got == null) _ = usleep(20 * 1000);
    }
    const n = got orelse {
        try testing.expect(false);
        return;
    };
    defer n.deinit(allocator);
    // host의 TerminalCore가 파싱한 OSC 777 title/body가 client로 전달됐다(host-backed 터미널의 알림이 유실 안 됨).
    try testing.expectEqualStrings("Deploy", n.title);
    try testing.expectEqualStrings("done in 3s", n.body);
    try testing.expectEqual(client.host_id, n.route.?.host_id);
    try testing.expectEqualStrings("workspace", n.display_label.?);

    // 실행 중 config off는 이후 core pending을 journal에 넣지 않는다. 같은 controller generation의 더 큰 config
    // generation만 받아들이며, 이미 받은 첫 row에는 영향을 주지 않는다.
    try rr.updateNotificationConfig(2, false, "workspace");
    try rr.sendInput("\x1b]9;must stay hidden\x07\n");
    attempts = 0;
    while (attempts < 20) : (attempts += 1) {
        if (try rr.takeNotification()) |unexpected| {
            unexpected.deinit(allocator);
            try testing.expect(false);
        }
        _ = usleep(20 * 1000);
    }

    // 다시 켠 뒤 바꾼 label은 다음 event에만 snapshot된다.
    try rr.updateNotificationConfig(3, true, "renamed workspace");
    try rr.sendInput("\x1b]777;notify;Deploy;second\x1b\\\n");
    var second: ?Notification = null;
    attempts = 0;
    while (attempts < 100 and second == null) : (attempts += 1) {
        second = try rr.takeNotification();
        if (second == null) _ = usleep(20 * 1000);
    }
    const n2 = second orelse {
        try testing.expect(false);
        return;
    };
    defer n2.deinit(allocator);
    try testing.expectEqualStrings("second", n2.body);
    try testing.expectEqualStrings("renamed workspace", n2.display_label.?);
}

// takeNotification의 수동 JSON 문자열 디코더(std.json.parseFromSlice의 f128 링크 회피). host의 std.json.Stringify escape를
// 되돈다 — 순수 함수라 fork host 없이 escape 처리를 고정한다(제어문자 \u00XX·\" \\ \n \t \uXXXX·키 부재·빈 값·둘째 필드).
// runtime.link_at은 link success의 {text,kind}와 no-link의 {text:""} 두 형태다. 처음엔 selected_text의
// 단일-필드 디코더를 재사용해 link success를 InvalidJson으로 보고 connection을 fail-close시켰다 — 밑줄은 뜨는데
// Cmd+클릭만 안 열리던 실제 버그다. 두 success 형태·escape·error와 각 schema 위반을 여기서 고정한다.
test "remote runtime: decodeLinkAtResponse는 link와 no-link success schema를 구분한다" {
    const allocator = testing.allocator;
    // schema 위반 경로가 connection을 fail-close 하므로 실 client를 붙인다(undefined client면 그 경로에서 크래시).
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_link_at_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rt: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
    rt.allocator = allocator;

    // url(kind 0) — 두 필드가 함께 와도 파싱된다(이전 디코더는 여기서 실패했다).
    {
        const link = (try rt.decodeLinkAtResponse("{\"text\":\"https://example.com/x\",\"kind\":0}")).?;
        defer allocator.free(link.text);
        try testing.expectEqualStrings("https://example.com/x", link.text);
        try testing.expectEqual(terminal.LinkKind.url, link.kind);
    }
    // file_path(kind 1) — Swift가 URL(fileURLWithPath:)로 여는 분기라 종류가 유실되면 안 된다.
    {
        const link = (try rt.decodeLinkAtResponse("{\"text\":\"/tmp/a b.md\",\"kind\":1}")).?;
        defer allocator.free(link.text);
        try testing.expectEqualStrings("/tmp/a b.md", link.text);
        try testing.expectEqual(terminal.LinkKind.file_path, link.kind);
    }
    // escape된 텍스트(따옴표·백슬래시)도 원문으로 복원된다.
    {
        const link = (try rt.decodeLinkAtResponse("{\"text\":\"/tmp/a\\\"b\",\"kind\":1}")).?;
        defer allocator.free(link.text);
        try testing.expectEqualStrings("/tmp/a\"b", link.text);
    }
    // host의 실제 no-link wire는 kind 없는 text-only다(미존재 경로 포함) → null, client는 일반 클릭으로 흘린다.
    try testing.expect((try rt.decodeLinkAtResponse("{\"text\":\"\"}")) == null);
    // host error 응답도 링크 없음으로 본다(연결을 죽이지 않는다).
    try testing.expect((try rt.decodeLinkAtResponse("{\"error\":\"invalid_request\"}")) == null);
    try testing.expect(!client.unusable);

    const invalid = [_][]const u8{
        "{\"text\":\"x\",\"kind\":0,\"extra\":\"no\"}", // 선언 밖 필드
        "{\"text\":\"x\"}", // non-empty link의 kind 누락
        "{\"text\":\"x\",\"kind\":2}", // 닫힌 wire enum 밖
        "{\"text\":\"\",\"kind\":0}", // no-link success는 text-only
        "{\"text\":\"\",\"kind\":2}", // 빈 text도 미래 enum을 숨기지 않음
        "{\"error\":\"future_error\"}", // 모르는 error code
    };
    for (invalid) |response| {
        // 각 schema 위반이 독립적으로 connection을 poison하는지 첫 실패 이전 상태에서 검증한다.
        var bad_client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .runtime_link_at_v1 = true,
            .parser = framing.FrameParser.init(allocator),
        };
        defer bad_client.deinit();
        var bad_rt: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&bad_rt, .{ .legacy = &bad_client });
        bad_rt.allocator = allocator;
        try testing.expectError(error.ProtocolError, bad_rt.decodeLinkAtResponse(response));
        try testing.expect(bad_client.unusable);
    }
}

test "remote runtime: notification success schema는 title과 body만 정확히 허용한다" {
    const allocator = testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rt: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
    rt.allocator = allocator;

    {
        const notification = (try rt.decodeNotificationResponse(
            "{\"title\":\"Deploy\",\"body\":\"done in 3s\"}",
        )).?;
        defer notification.deinit(allocator);
        try testing.expectEqualStrings("Deploy", notification.title);
        try testing.expectEqualStrings("done in 3s", notification.body);
    }
    try testing.expect((try rt.decodeNotificationResponse("{\"title\":\"\",\"body\":\"\"}")) == null);
    try testing.expect((try rt.decodeNotificationResponse("{\"error\":\"invalid_request\"}")) == null);
    try testing.expect(!client.unusable);

    // host는 알림이 없어도 두 필드를 빈 문자열로 보낸다. 필드 누락이나 선언 밖 필드는 "알림 없음"이 아니라 schema drift다.
    const invalid = [_][]const u8{
        "{\"title\":\"Deploy\"}",
        "{\"body\":\"done\"}",
        "{\"title\":1,\"body\":\"done\"}",
        "{\"title\":\"Deploy\",\"body\":1}",
        "{\"title\":\"Deploy\",\"body\":\"done\",\"extra\":\"no\"}",
        "{\"title\":\"Deploy\",\"body\":\"done\"",
        "{\"title\":\"Deploy\",\"body\":\"done\"} trailing",
        "{\"title\":\"Deploy\",\"title\":\"Again\",\"body\":\"done\"}",
        "{\"error\":\"future_error\"}",
        "{\"error\":1}",
        "{\"error\":\"invalid_request\",\"title\":\"Deploy\",\"body\":\"done\"}",
    };
    for (invalid) |response| {
        var bad_client = client_mod.Client{
            .allocator = allocator,
            .fd = -1,
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        defer bad_client.deinit();
        var bad_rt: RemoteRuntime = undefined;
        try testing_api.initializeGenerationForConnection(&bad_rt, .{ .legacy = &bad_client });
        bad_rt.allocator = allocator;
        try testing.expectError(error.ProtocolError, bad_rt.decodeNotificationResponse(response));
        try testing.expect(bad_client.unusable);
    }
}

test "remote runtime: notification selector follows negotiated stream auth capability" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"stream_id\":7}",
        try RemoteRuntime.notificationParams(&buf, 7, false),
    );
    try testing.expectEqualStrings(
        "{\"stream_id\":7,\"delivery_version\":1}",
        try RemoteRuntime.notificationParams(&buf, 7, true),
    );
}

test "P4 N2b1 stable notification response decodes exact route and owned presentation" {
    const allocator = testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .notification_stream_auth_v1 = true,
        .notification_delivery_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var rt: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
    rt.allocator = allocator;
    const notification = (try rt.decodeNotificationResponse(
        "{\"event\":{\"hid\":\"00000000000000000000000000000011\",\"rid\":\"00000000000000000000000000000022\",\"eid\":3,\"occurred_at_ns\":4,\"title\":\"Deploy\",\"body\":\"done\",\"display_label\":\"workspace\"}}",
    )).?;
    defer notification.deinit(allocator);
    try testing.expectEqual(@as(u128, 0x11), notification.route.?.host_id);
    try testing.expectEqual(@as(u128, 0x22), notification.route.?.runtime_id);
    try testing.expectEqual(@as(u64, 3), notification.route.?.event_id);
    try testing.expectEqualStrings("workspace", notification.display_label.?);
    const reordered = (try rt.decodeNotificationResponse(
        "{\"event\":{\"body\":\"done\",\"rid\":\"00000000000000000000000000000022\",\"display_label\":\"workspace\",\"title\":\"Deploy\",\"occurred_at_ns\":4,\"eid\":3,\"hid\":\"00000000000000000000000000000011\"}}",
    )).?;
    defer reordered.deinit(allocator);
    try testing.expectEqual(@as(u128, 0x11), reordered.route.?.host_id);
    try testing.expect((try rt.decodeNotificationResponse("{\"event\":null}")) == null);
}

test "P4 N2b1 stable notification response preserves OOM and connection reuse" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var client = client_mod.Client{
                .allocator = allocator,
                .fd = -1,
                .host_id = 1,
                .notification_stream_auth_v1 = true,
                .notification_delivery_v1 = true,
                .parser = framing.FrameParser.init(allocator),
            };
            defer client.deinit();
            var rt: RemoteRuntime = undefined;
            try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
            rt.allocator = allocator;
            const notification = (rt.decodeNotificationResponse(
                "{\"event\":{\"body\":\"done\",\"rid\":\"00000000000000000000000000000022\",\"display_label\":\"workspace\",\"title\":\"Deploy\",\"occurred_at_ns\":4,\"eid\":3,\"hid\":\"00000000000000000000000000000011\"}}",
            ) catch |err| {
                if (err != error.OutOfMemory) return err;
                try testing.expect(!client.unusable);
                return err;
            }).?;
            notification.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{});
}

test "remote runtime: notification decode는 모든 할당 실패 지점에서 소유 메모리를 회수한다" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var client = client_mod.Client{
                .allocator = allocator,
                .fd = -1,
                .host_id = 1,
                .parser = framing.FrameParser.init(allocator),
            };
            defer client.deinit();
            var rt: RemoteRuntime = undefined;
            try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
            rt.allocator = allocator;
            const notification = (rt.decodeNotificationResponse(
                "{\"title\":\"Deploy\",\"body\":\"done in 3s\"}",
            ) catch |err| {
                // allocator 압박은 peer의 wire 손상이 아니다. 어느 할당 지점이 실패해도 shared connection은 재사용 가능해야 한다.
                if (err != error.OutOfMemory) return err;
                try testing.expect(!client.unusable);
                return err;
            }).?;
            notification.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{});
}

test "remote runtime: link decode OOM은 소유 메모리를 회수하고 connection을 유지한다" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var client = client_mod.Client{
                .allocator = allocator,
                .fd = -1,
                .host_id = 1,
                .runtime_link_at_v1 = true,
                .parser = framing.FrameParser.init(allocator),
            };
            defer client.deinit();
            var rt: RemoteRuntime = undefined;
            try testing_api.initializeGenerationForConnection(&rt, .{ .legacy = &client });
            rt.allocator = allocator;
            const link = (rt.decodeLinkAtResponse(
                "{\"text\":\"https://example.com/x\",\"kind\":0}",
            ) catch |err| {
                if (err != error.OutOfMemory) return err;
                try testing.expect(!client.unusable);
                return err;
            }).?;
            allocator.free(link.text);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{});
}

test "f3c0 remote runtime requestResync makes the host push a fresh snapshot (desync 복구)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-rsy-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // attach가 첫 snapshot을 이미 소비했다 — 이제 fresh snapshot을 **재요청**한다.
    try rr.requestResync();

    // host가 다음 delta tick에 snapshot_chunk를 push한다(delta 아님). 그 배치가 is_snapshot인지 확인한다(input 없어 delta는 안 옴).
    var saw_snapshot = false;
    var attempts: usize = 0;
    while (attempts < 150 and !saw_snapshot) : (attempts += 1) {
        if (try rr.testingClient().readStreamBatch(rr.currentGeneration().attachment.streamId())) |batch| {
            defer batch.deinit();
            if (batch.is_snapshot) saw_snapshot = true;
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_snapshot); // resync 요청이 host의 fresh snapshot push를 유발했다(generation 리셋 = 복구 경로).
}

test "remote runtime: snapshot.invalidated latches one nonblocking resync ack" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var peer_ok = false;
    const Peer = struct {
        fn run(fd: c.fd_t, ok: *bool) void {
            defer _ = c.close(fd);
            const request = readPeerFrame(fd, std.heap.page_allocator) catch return;
            defer std.heap.page_allocator.free(request.payload);
            if (request.header.kind != .stream_ack or
                request.header.stream_id != 9 or
                !std.mem.eql(u8, request.payload, "{\"action\":\"resync\"}"))
                return;
            ok.* = true;
        }
    };
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], &peer_ok });

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    var event = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 9 },
        .payload = try allocator.dupe(u8, "{\"event\":\"snapshot.invalidated\"}"),
    };
    event.header.payload_len = @intCast(event.payload.len);
    try client.pending_events.append(allocator, event);
    client.pending_event_bytes = event.payload.len;
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const drained = try rr.drainObservationEvents();
    try testing.expect(!drained.metadata);
    try testing.expect(!drained.ended);
    try testing.expect(rr.currentGeneration().resync_needed);
    try rr.pumpResyncIntent();
    try testing.expect(!rr.currentGeneration().resync_needed);
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
}

// R4: sibling revoke는 그 stream의 input만 fence한다. 내 deferred resync는 input FIFO와 독립된 control이며
// 같은 pump turn에서 exact once admission되어야 한다.
test "R4 sibling revoke does not block my deferred resync" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);

    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();

    // 남의 pane(stream 10)이 controller를 빼앗겼다. 그 runtime이 아직 pump되지 않아 버퍼에 남아 있다.
    try client.bufferGenerationEventForTest(
        10,
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":10,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );
    // 내 pane(stream 9)은 화면을 회수당했다.
    try client.bufferGenerationEventForTest(9, "{\"event\":\"snapshot.invalidated\"}");

    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    // 내 무효화는 소비되어 resync 의도가 걸린다.
    try rr.mutation_owner.initInPlace(
        try rr.generation_owner.slot.currentGeneration(),
        rr.input_batches.epoch,
    );
    _ = try rr.drainObservationEvents();
    try testing.expect(rr.currentGeneration().resync_needed);
    // 남의 revoke는 여전히 버퍼에 남아 있다 — 소비할 주인은 stream 10의 runtime이다.
    try testing.expect(client.hasBufferedControllerRevoke());

    // sibling revoke가 input pump를 막아도 outer pump의 resync 단계는 실행된다.
    try testing.expect(!(try rr.pumpQueuedInput()));
    try testing.expectEqual(RemoteRuntime.PumpResult.idle, try rr.pumpDelta());
    try testing.expect(!rr.currentGeneration().resync_needed);
    const ack = try readPeerFrame(fds[1], allocator);
    defer allocator.free(ack.payload);
    try testing.expectEqual(protocol.Kind.stream_ack, ack.header.kind);
    try testing.expectEqual(@as(u64, 9), ack.header.stream_id);
    try testing.expectEqualStrings("{\"action\":\"resync\"}", ack.payload);
}

test "remote runtime: typed ended event terminates only its stream pump" {
    const allocator = testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try client.bufferGenerationEventForTest(9, "{\"event\":\"runtime.ended\"}");
    try client.bufferGenerationEventForTest(10, "{\"event\":\"runtime.ended\"}");
    try client.screen_inbox.pending_batches.append(allocator, .{
        .stream_id = 9,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "stale"),
        .allocator = allocator,
    });
    try client.screen_inbox.pending_batches.append(allocator, .{
        .stream_id = 10,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "sibling"),
        .allocator = allocator,
    });
    client.screen_inbox.pending_batch_bytes = "stale".len + "sibling".len;
    _ = try client.screen_inbox.recovery.invalidate(9);
    _ = try client.screen_inbox.recovery.invalidate(10);
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().pump_ended = false;
    rr.currentGeneration().resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    try testing.expectEqual(RemoteRuntime.PumpResult.ended, try rr.pumpDelta());
    try testing.expectEqual(@as(usize, 1), client.pending_events.items.len);
    try testing.expectEqual(@as(u64, 10), client.pending_events.items[0].header.stream_id);
    try testing.expectEqual(@as(usize, 1), client.screen_inbox.pending_batches.items.len);
    try testing.expectEqual(@as(u64, 10), client.screen_inbox.pending_batches.items[0].stream_id);
    try testing.expectEqualStrings("sibling", client.screen_inbox.pending_batches.items[0].bytes);
    try testing.expectEqual(client_mod.ScreenRecoveryState.valid, client.screenRecoveryState(9));
    try testing.expectEqual(client_mod.ScreenRecoveryState.needs_resync, client.screenRecoveryState(10));
}

test "remote runtime: resync intent survives occupied outbound slot and emits one ack after drain" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    const filled = try fillRemoteTestSendBuffer(fds[0]);
    client.pending_outbound = .{
        .frame = try framing.encodeFrame(
            allocator,
            .{ .kind = .input_bytes, .stream_id = 3 },
            "older",
        ),
        .stream_id = 3,
    };
    var event = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 9 },
        .payload = try allocator.dupe(u8, "{\"event\":\"snapshot.invalidated\"}"),
    };
    event.header.payload_len = @intCast(event.payload.len);
    try client.pending_events.append(allocator, event);
    client.pending_event_bytes = event.payload.len;
    var rr: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&rr, .{ .legacy = &client });
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.currentGeneration().attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.currentGeneration().resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    _ = try rr.drainObservationEvents();
    try rr.pumpResyncIntent();
    try testing.expect(rr.currentGeneration().resync_needed);
    try testing.expect(client.pending_outbound != null);

    const filler = try allocator.alloc(u8, filled);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    try testing.expect(try client.pumpPendingOutput());
    const older = try readPeerFrame(fds[1], allocator);
    defer allocator.free(older.payload);
    try testing.expectEqual(protocol.Kind.input_bytes, older.header.kind);

    try rr.pumpResyncIntent();
    try testing.expect(!rr.currentGeneration().resync_needed);
    const ack = try readPeerFrame(fds[1], allocator);
    defer allocator.free(ack.payload);
    try testing.expectEqual(protocol.Kind.stream_ack, ack.header.kind);
    try testing.expectEqual(@as(u64, 9), ack.header.stream_id);
    try testing.expectEqualStrings("{\"action\":\"resync\"}", ack.payload);
    try rr.pumpResyncIntent();
    try testing.expect(client.pending_outbound == null);
}

// code-review #6a end-to-end — 원격 스크롤백. 스크롤 core command를 host로 라우팅하면 host가 자기 core view_offset을 바꾸고,
// projectSnapshot/computeDelta가 renderSnapshot(뷰포트)을 써서 그 스크롤백 윈도를 client에 투영한다. TOPMARKER를 화면 밖
// (스크롤백)으로 민 뒤 위로 스크롤 → client 화면 최상단에 TOPMARKER가 나타나는지 실 fork host로 고정. macOS opt-in.
test "remote runtime: scroll core command routes to host so client sees scrolled-back content (§6a)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-scr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // TOPMARKER 한 줄 + 8행을 넘기는 filler → TOPMARKER는 스크롤백으로 밀려 화면 밖(host 기본 scrollback 1000행).
    try rr.sendInput("TOPMARKER\n");
    var k: usize = 0;
    while (k < 20) : (k += 1) try rr.sendInput("filler\n");

    // host echo가 화면에 반영될 때까지 pump — 바닥엔 filler(row0 시작이 'f', TOPMARKER는 안 보임).
    var settled = false;
    var attempts: usize = 0;
    while (attempts < 200 and !settled) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'f') settled = true else _ = usleep(20 * 1000);
    }
    try testing.expect(settled); // 바닥 화면은 filler(TOPMARKER는 스크롤백)

    // **위로 스크롤**(host core view_offset 이동 → renderSnapshot 뷰포트가 스크롤백 윈도로) → 최상단에 TOPMARKER.
    try rr.queueCoreCommand(.{ .scroll = 100 }); // 위로 100(스크롤백 top으로 cap)

    var saw_marker = false;
    attempts = 0;
    while (attempts < 200 and !saw_marker) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'T') saw_marker = true else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_marker); // 스크롤 명령이 host를 거쳐 client 화면을 스크롤백(TOPMARKER)으로 이동시켰다(#6a).
}

// code-review #6b end-to-end — 원격 선택 복사. client가 뷰포트 선택 span을 host로 보내면, host가 자기 core에 적용해
// **로컬과 같은 `extractSelection`**(선택 의미론 단일 출처)으로 텍스트를 뽑아 돌려주는지 실 fork host로 고정한다. 하이라이트는
// placeholder core(app_session)가 즉시 그리고, 이 복사만 host가 해석한다("client 렌더/host 해석"). macOS opt-in.
test "remote runtime: selectedText extracts the selection text on the host (§6b, extractSelection 재사용)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-sel-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "HELLO"를 입력 → cat echo → host core row0 = "HELLO". RemoteScreen에 반영될 때까지 pump(= host가 처리 완료).
    try rr.sendInput("HELLO\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'H') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // 뷰포트 선택 span (0,0)~(0,4) = row0의 "HELLO"를 host에 보내 host가 extractSelection으로 뽑는다.
    const span: terminal.SelectionSpan = .{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 4 }, .block = false };
    const text = (try rr.selectedText(span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(text);
    try testing.expectEqualStrings("HELLO", text); // host가 자기 core에서 선택 텍스트를 뽑아 client로 전달했다(선택 의미론=host).

    // 앱보다 먼저 떠 있던 같은-major 구 host를 협상 결과로 재현한다. 실제 host snapshot으로 조립한 RemoteScreen만
    // 남아 있고 placeholder core는 비어 있으므로, 이 assertion은 fallback이 렌더 projection을 읽는지 제품과 같은
    // 조건으로 검증한다(옛 잘못된 테스트처럼 placeholder에 문자열을 직접 쓰지 않는다).
    client.runtime_selected_text_v1 = false;
    const legacy_text = (try rr.selectedText(span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(legacy_text);
    try testing.expectEqualStrings("HELLO", legacy_text);
}

// code-review #6b-2 end-to-end — 단어/줄 선택. 빈 client placeholder는 단어/줄 경계를 모르므로 host가 콘텐츠로 계산해
// span을 돌려준다(selectContentAware → runtime.select_op). 그 span으로 selectedText를 부르면(=client가 placeholder에 적용 후
// #6b-1 복사와 같은 경로) 그 단어/줄 텍스트가 나온다. 실 fork host로 왕복 고정. macOS opt-in.
test "CR6e-c3c remote select-all copy survives projection refresh (§6b-2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-wl-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "foo.bar baz"를 입력 → cat echo → host core row0. RemoteScreen 반영까지 pump.
    try rr.sendInput("foo.bar baz\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'f') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // (0,0)의 **단어** = "foo"를 host가 사용자 구분자 '.'로 경계 계산 → span. 빈 구분자면
    // "foo.bar"가 잡히므로, 이 단언은 config 값이 client→wire→host core 전체를 통과했음을 증명한다.
    const word_span = (try rr.selectContentAware("word", 0, 0, ".")) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u16, 0), word_span.start.col); // "foo" 시작
    const word = (try rr.selectedText(word_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(word);
    try testing.expectEqualStrings("foo", word); // host가 client의 '.' 경계로 단어를 잡았다(빈 placeholder는 못 함).

    // **줄** 선택 = row0 전체 "foo.bar baz".
    const line_span = (try rr.selectContentAware("line", 0, 0, "")) orelse {
        try testing.expect(false);
        return;
    };
    const line = (try rr.selectedText(line_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(line);
    try testing.expectEqualStrings("foo.bar baz", line); // 줄 전체(host 계산).

    // viewport(8행)보다 긴 내용을 만든 뒤 전체 선택한다. placeholder만 고르면 보이는 8행 밖 EARLY-00은
    // 복사될 수 없으므로, 이 단언이 Cmd+A 의도→host selectAll→scrollback 추출 전체 경로를 증명한다.
    try rr.sendInput("EARLY-00\nEARLY-01\nEARLY-02\nEARLY-03\nEARLY-04\nEARLY-05\nEARLY-06\nEARLY-07\nEARLY-08\nEARLY-09\nEARLY-10\nEARLY-11\n");
    attempts = 0;
    while (attempts < 150) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        _ = usleep(20 * 1000);
    }
    const all_span = (try rr.selectContentAware("all", 0, 0, "")) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(rr.selection_all);
    const all_text = (try rr.selectedText(all_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(all_text);
    try testing.expect(std.mem.indexOf(u8, all_text, "EARLY-00") != null);
    try testing.expect(std.mem.indexOf(u8, all_text, "EARLY-11") != null);

    // A following screen publication may replace the client projection and erase its
    // render-only span. The host still owns Select All, so copy must remain available.
    rr.surface.core.selectionClear();
    const after_projection_refresh = (try rr.selectedTextCurrent(null)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(after_projection_refresh);
    try testing.expect(std.mem.indexOf(u8, after_projection_refresh, "EARLY-00") != null);
    try testing.expect(std.mem.indexOf(u8, after_projection_refresh, "EARLY-11") != null);
}

// code-review #6c end-to-end — 원격 검색. 빈 client placeholder는 검색을 못 하므로 host가 자기 core(콘텐츠·스크롤백)에서
// findMatches로 매치를 찾아 보이는 뷰포트 span을 돌려주는지 실 fork host로 고정한다(검색 의미론 host 단일 출처). macOS opt-in.
test "remote runtime: find matches on the host and returns viewport spans (§6c)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-find-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, .gui)) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "xyz"를 입력. PTY는 **라인 에코 + cat 출력**으로 같은 줄을 2번 낸다(row0=에코, row1=cat) → "xyz" 매치 2개.
    // 결정적이려면 두 줄이 다 올 때까지(row1[0]=='x') 기다린다.
    try rr.sendInput("xyz\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const snap = surface.renderSnapshot();
        const row1_c0 = snap.cells[snap.size.cols].codepoint; // row1 col0
        surface.unlockCore(io);
        if (row1_c0 == 'x') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // "xyz" 검색(현재 매치=index 0) → host가 2개(에코 줄=row0 + cat 줄=row1) 찾고, cur=현재(row0)·spans=비현재(row1).
    var spans: std.ArrayList(terminal.SelectionSpan) = .empty;
    defer spans.deinit(allocator);
    const r0 = try rr.find("xyz", 0, false, &spans);
    try testing.expectEqual(@as(usize, 2), r0.count); // 전체 매치 수
    try testing.expect(r0.cur != null); // 현재 매치(index0) 뷰포트 span
    try testing.expectEqual(@as(u16, 0), r0.cur.?.start.row); // 현재 매치는 row0
    try testing.expectEqual(@as(usize, 1), spans.items.len); // 비현재 보이는 매치 = row1 1개
    try testing.expectEqual(@as(u16, 1), spans.items[0].start.row);

    // §6c-2 네비: 현재 매치를 index 1로 → cur=row1, 비현재=row0. (host가 cur_index로 현재 매치를 가른다)
    const r1 = try rr.find("xyz", 1, false, &spans);
    try testing.expectEqual(@as(usize, 2), r1.count);
    try testing.expect(r1.cur != null);
    try testing.expectEqual(@as(u16, 1), r1.cur.?.start.row); // 현재 매치가 row1로 바뀜
    try testing.expectEqual(@as(u16, 0), spans.items[0].start.row); // 비현재 = row0

    // scroll=true(⌘G 네비)도 크래시 없이 현재 매치를 준다(내용이 다 보여 scrollToAbs는 사실상 무이동).
    const rs = try rr.find("xyz", 0, true, &spans);
    try testing.expectEqual(@as(usize, 2), rs.count);

    // 없는 검색어 → 0.
    const zero = try rr.find("zzz", 0, false, &spans);
    try testing.expectEqual(@as(usize, 0), zero.count);
    try testing.expect(zero.cur == null);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "C3-3b2b2 compatibility maps event materialization failures by provenance" {
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_resource_exhausted,
        RemoteRuntime.eventMaterializationPoisonReason(error.OutOfMemory),
    );
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_invariant_violation,
        RemoteRuntime.eventMaterializationPoisonReason(error.LocalInvariant),
    );
    inline for (.{
        error.Malformed,
        error.ResourceExhausted,
        error.CapabilityViolation,
    }) |err| try std.testing.expectEqual(
        client_poison.ConnectionReason.peer_contract_violation,
        RemoteRuntime.eventMaterializationPoisonReason(err),
    );
}

test "CR2a RemoteGeneration field inventory는 generation owner 열두 개만 포함한다" {
    const fields = @typeInfo(RemoteGeneration).@"struct".fields;
    const expected_generation_size: usize = switch (builtin.mode) {
        .Debug => 3520,
        .ReleaseFast => 3504,
        else => unreachable,
    };
    try testing.expectEqual(expected_generation_size, @sizeOf(RemoteGeneration));
    const expected_runtime_size: usize = switch (builtin.os.tag) {
        .macos => switch (builtin.mode) {
            // 값은 **실측이다** — Debug 와 ReleaseFast 의 델타가 서로 다를 수 있어(필드가 기존 패딩에
            // 들어가면 안 커진다) 한쪽 델타를 다른 쪽에 옮겨 적으면 틀린다.
            .Debug => 11440,
            .ReleaseFast => 11376,
            else => unreachable,
        },
        // ⚠️ 이 두 값은 **이 트리에서 측정할 수 없다.** `remote_runtime` 은 배럴이 macOS 에서만 열어서
        // (session_host.zig `if (builtin.os.tag == .macos)`) linux 로는 이 파일이 아예 컴파일되지 않는다.
        // 그래서 `process_identity` 를 더하면서도 손대지 않았다 — 잴 수 없는 자리에 숫자를 지어 넣지 않는다.
        .linux => switch (builtin.mode) {
            .Debug => 11328,
            .ReleaseFast => 11280,
            else => unreachable,
        },
        else => unreachable,
    };
    try testing.expectEqual(expected_runtime_size, @sizeOf(RemoteRuntime));
    const expected = [_][]const u8{
        "connection",
        "connection_generation",
        "attachment",
        "event_generation_tracking",
        "resize_seq",
        "resize_generation",
        "resize_baseline_present",
        "pump_ended",
        "resync_needed",
        "observation_probe_active",
        "observation_probe_abandoned",
        "observation_probe_completed",
        "frame_summary_ready",
        "frame_summary",
        "observation",
    };
    try testing.expectEqual(expected.len, fields.len);
    inline for (expected, fields) |name, field| try testing.expectEqualStrings(name, field.name);
    inline for (.{
        "allocator",
        "io",
        "runtime_id_hex",
        "direct_input",
        "direct_input_offset",
        "pending_controls",
        "blocking_flush_active",
        "pending_event_owner",
        "close_authority",
        "shutdown_attempt_authority",
        "shutdown_current_admin",
        "runtime_lifetime",
        "surface",
    }) |name| try testing.expect(!@hasField(RemoteGeneration, name));
}

test "CR2a RemoteGeneration 추출은 distinct state와 allocator ownership을 보존한다" {
    const runtime_fields = @typeInfo(RemoteRuntime).@"struct".fields;
    try testing.expectEqual(@as(usize, 1), comptime countField(runtime_fields, "generation_owner"));
    inline for (@typeInfo(RemoteGeneration).@"struct".fields) |field|
        try testing.expect(!@hasField(RemoteRuntime, field.name));

    var generation: RemoteGeneration = .{
        .connection = .{ .legacy = @ptrFromInt(@alignOf(client_mod.Client)) },
        .attachment = .init(testing.allocator, .{
            .runtime_id = 0xA1,
            .stream_id = 0xB2,
            .role = .observer,
            .controller_generation = 0xC3,
        }),
        .event_generation_tracking = .tracked,
        .resize_seq = 0xD4,
        .resize_generation = 0xE5,
        .resize_baseline_present = true,
        .pump_ended = true,
        .resync_needed = true,
        .frame_summary_ready = true,
        .frame_summary = .{ .output_events = 0xF6, .exit_events = 0x17 },
        .observation = .{},
    };
    defer generation.observation.deinit(testing.allocator);
    defer generation.attachment.deinit();
    try generation.observation.cwd.appendSlice(testing.allocator, "/cr2a");

    try testing.expect(generation.connection == .legacy);
    try testing.expectEqual(@as(u64, 0xB2), generation.attachment.streamId());
    try testing.expectEqual(EventGenerationTracking.tracked, generation.event_generation_tracking);
    try testing.expectEqual(@as(u64, 0xD4), generation.resize_seq);
    try testing.expectEqual(@as(u64, 0xE5), generation.resize_generation);
    try testing.expect(generation.resize_baseline_present);
    try testing.expect(generation.pump_ended);
    try testing.expect(generation.resync_needed);
    try testing.expect(generation.frame_summary_ready);
    try testing.expectEqual(@as(usize, 0xF6), generation.frame_summary.output_events);
    try testing.expectEqual(@as(usize, 0x17), generation.frame_summary.exit_events);
    try testing.expectEqualStrings("/cr2a", generation.observation.cwd.items);
}

test "CR2b RemoteRuntime attach는 Surface에 stable proxy를 한 번 게시한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();

    const remote = fixture.runtime.surface.remote orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromPtr(fixture.runtime.screen_source), @intFromPtr(remote.ctx));
    try testing.expect(@intFromPtr(fixture.runtime.currentGeneration().attachment.screenPtr().?) != @intFromPtr(remote.ctx));
    fixture.runtime.surface.lockCore(std.testing.io);
    const snapshot = fixture.runtime.surface.renderSnapshot();
    try testing.expectEqual(@as(u21, 'x'), snapshot.cells[0].codepoint);
    fixture.runtime.surface.unlockCore(std.testing.io);
}

test "CR6e-c3c reconnect 전환 중 recent text 조회는 nullable screen을 fail-closed 한다" {
    var client: client_mod.Client = .{
        .allocator = testing.allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(testing.allocator),
    };
    defer client.deinit();
    var runtime: RemoteRuntime = undefined;
    try testing_api.initializeGenerationForConnection(&runtime, .{ .legacy = &client });
    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.currentGeneration().attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 1,
    });
    defer runtime.currentGeneration().attachment.deinit();

    try testing.expectError(
        error.ConnectionClosed,
        RemoteRuntime.backend_api.dumpRecentText(
            &runtime,
            testing.allocator,
            testing.io,
            8,
            4096,
        ),
    );
}

test "CR2e-e2a 제품 runtime은 최초 inline slot payload와 stable screen을 결속한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();

    const slot = &fixture.runtime.generation_owner.slot;
    const current = try slot.currentPayload();
    try testing.expectEqual(@as(u64, 2), try slot.currentGeneration());
    try testing.expectEqual(@intFromPtr(&slot.inline_node.payload), @intFromPtr(current));
    try testing.expectEqual(@intFromPtr(current), @intFromPtr(fixture.runtime.currentGeneration()));
    try testing.expect(fixture.runtime.generation_owner.screen_published);
    try testing.expectEqual(stable_screen_source.TargetKind.live, fixture.runtime.screen_source.current.kind);
    try testing.expectEqual(@as(u64, 2), fixture.runtime.screen_source.current.generation);
    const source = generationScreenSource(current) orelse return error.TestUnexpectedResult;
    try testing.expect(screenSourcesEqual(source, fixture.runtime.screen_source.current.source));
}

test "CR2e-e2a 제품 runtime teardown은 slot payload와 stable screen을 exact once 정산한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    ReconnectGenerationTestState.deinit_count = 0;
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    var runtime_live = true;
    defer if (runtime_live) fixture.deinit();

    fixture.runtime.detachClientSide();
    runtime_live = false;
    fixture.adapter.deinit();
    try testing.expectEqual(@as(usize, 1), ReconnectGenerationTestState.deinit_count);
}

test "CR2e-e2b 제품 executor는 reducer 성공 뒤 actual candidate를 게시하고 retiring을 회수한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    ReconnectGenerationTestState.deinit_count = 0;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x11 },
        initReconnectTestGeneration,
    );
    var pristine_executor: ReconnectProductExecutor = .{};
    const owner_before_pristine_teardown = owner;
    try pristine_executor.deinit(&owner);
    try testing.expect(std.meta.eql(owner_before_pristine_teardown, owner));
    var executor: ReconnectProductExecutor = .{};
    try executor.initInPlace(&owner, 3);
    defer {
        executor.deinit(&owner) catch @panic("test executor deinit failed");
        deinitReconnectTestOwner(&owner, &proxy);
    }

    const args = ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x22 };
    const work = reconnectTestWork(2);
    try testing.expectEqual(
        reconnect_reducer.Decision.prepare_candidate,
        try executor.apply(&owner, .{ .begin_prepare = work }, args, initReconnectTestGeneration),
    );
    inline for (.{
        reconnect_reducer.Event.observer_staged,
        reconnect_reducer.Event.begin_mutation_seal,
        reconnect_reducer.Event.seal_clean,
        reconnect_reducer.Event.begin_authority_commit,
        reconnect_reducer.Event.controller_evidenced,
        reconnect_reducer.Event.begin_publish,
    }) |event| _ = try executor.apply(&owner, event, args, initReconnectTestGeneration);
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    const before_failed_publish = executor.state.?;
    proxy.current.generation = 99;
    try testing.expectError(
        error.InvalidAuthority,
        executor.apply(&owner, .publish_new, args, initReconnectTestGeneration),
    );
    try testing.expect(std.meta.eql(before_failed_publish, executor.state.?));
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expect(!std.meta.eql(PreparedReconnect{}, executor.prepared));
    try testing.expect(!try owner.slot.hasRetiring());
    proxy.current.generation = 2;
    try testing.expectEqual(
        reconnect_reducer.Decision.publish_new_and_open,
        try executor.apply(&owner, .publish_new, args, initReconnectTestGeneration),
    );
    try testing.expectEqual(@as(u64, 3), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 3), proxy.current.generation);
    try testing.expect(try owner.slot.hasRetiring());
    try executor.completeJob(&owner, .{
        .job_generation = 3,
        .total = 1,
        .published_new = 1,
        .frozen_unavailable = 0,
        .ended = 0,
        .retry_reserved = 0,
    });
    try testing.expect(!try owner.slot.hasRetiring());
    try testing.expectEqual(@as(usize, 1), ReconnectGenerationTestState.deinit_count);
}

test "CR2e-e3b2 actual stable executor는 resident lease 아래 retain publish reclaim을 정산한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0xB201 },
        initReconnectTestGeneration,
    );
    var executor: ReconnectProductExecutor = .{};
    try executor.initInPlace(&owner, 3);
    var budget: reconnect_resident_budget.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    const admission: reconnect_admission_owner.Projection = .{
        .slot_index = 0,
        .slot_generation = 1,
        .host_id = 0xB2,
        .host_adapter_generation = 1,
        .connection_generation = 2,
        .incident_id = .{ .app_instance_nonce = 1, .sequence = 3 },
    };
    try executor.bindAdmission(&owner, &budget, admission, reconnect_resident_budget.max_entry_bytes);
    try testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    const args = ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0xB202 };
    const state_before_drift = executor.state.?;
    const budget_before_drift = try budget.snapshot();
    executor.admission.?.host_id +%= 1;
    try testing.expectError(
        error.InvalidAuthority,
        executor.apply(&owner, .{ .begin_prepare = reconnectTestWork(2) }, args, initReconnectTestGeneration),
    );
    executor.admission = admission;
    try testing.expectEqualDeep(state_before_drift, executor.state.?);
    try testing.expectEqualDeep(budget_before_drift, try budget.snapshot());
    executor.resident_lease.role = .current;
    try testing.expectError(
        error.InvalidAuthority,
        executor.apply(&owner, .{ .begin_prepare = reconnectTestWork(2) }, args, initReconnectTestGeneration),
    );
    executor.resident_lease.role = .candidate;
    try testing.expectEqualDeep(state_before_drift, executor.state.?);
    try testing.expectEqualDeep(budget_before_drift, try budget.snapshot());
    _ = try executor.apply(&owner, .{ .begin_prepare = reconnectTestWork(2) }, args, initReconnectTestGeneration);
    inline for (.{
        reconnect_reducer.Event.observer_staged,
        reconnect_reducer.Event.begin_mutation_seal,
        reconnect_reducer.Event.seal_clean,
        reconnect_reducer.Event.begin_authority_commit,
        reconnect_reducer.Event.controller_evidenced,
        reconnect_reducer.Event.begin_publish,
    }) |event| {
        _ = try executor.apply(&owner, event, args, initReconnectTestGeneration);
        try testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    }
    _ = try executor.apply(&owner, .publish_new, args, initReconnectTestGeneration);
    try testing.expectEqual(reconnect_resident_budget.Role.current, executor.resident_lease.role);
    try executor.completeJob(&owner, .{
        .job_generation = 3,
        .total = 1,
        .published_new = 1,
        .frozen_unavailable = 0,
        .ended = 0,
        .retry_reserved = 0,
    });
    try testing.expectEqual(@as(usize, 0), (try budget.snapshot()).live_entries);
    try executor.deinit(&owner);
    try budget.deinit();
    deinitReconnectTestOwner(&owner, &proxy);
}

test "CR2e-e2b 제품 executor는 abort와 effect 실패에서 reducer state와 current를 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x31 },
        initReconnectTestGeneration,
    );
    var executor: ReconnectProductExecutor = .{};
    try executor.initInPlace(&owner, 3);
    defer {
        executor.deinit(&owner) catch @panic("test executor deinit failed");
        deinitReconnectTestOwner(&owner, &proxy);
    }
    const initial = executor.state.?;
    const args = ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x32 };
    try testing.expectError(
        error.InjectedFailure,
        executor.apply(
            &owner,
            .{ .begin_prepare = reconnectTestWork(2) },
            args,
            failReconnectTestGeneration,
        ),
    );
    try testing.expect(std.meta.eql(initial, executor.state.?));
    try testing.expect(std.meta.eql(PreparedReconnect{}, executor.prepared));
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());

    _ = try executor.apply(
        &owner,
        .{ .begin_prepare = reconnectTestWork(2) },
        args,
        initReconnectTestGeneration,
    );
    inline for (.{
        reconnect_reducer.Event.observer_staged,
        reconnect_reducer.Event.begin_mutation_seal,
        reconnect_reducer.Event.seal_clean,
    }) |event| _ = try executor.apply(&owner, event, args, initReconnectTestGeneration);
    try testing.expectEqual(
        reconnect_reducer.Decision.abort_candidate_restore_old,
        try executor.apply(&owner, .precommit_failed_clean, args, initReconnectTestGeneration),
    );
    try testing.expect(std.meta.eql(PreparedReconnect{}, executor.prepared));
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expect(!try owner.slot.hasRetiring());

    _ = try executor.apply(
        &owner,
        .{ .begin_prepare = reconnectTestWork(2) },
        args,
        initReconnectTestGeneration,
    );
    inline for (.{
        reconnect_reducer.Event.observer_staged,
        reconnect_reducer.Event.begin_mutation_seal,
        reconnect_reducer.Event.seal_ambiguous,
        reconnect_reducer.Event.begin_authority_commit,
        reconnect_reducer.Event.takeover_sent_unknown,
        reconnect_reducer.Event.begin_publish,
    }) |event| _ = try executor.apply(&owner, event, args, initReconnectTestGeneration);
    _ = try executor.apply(
        &owner,
        .{ .freeze_with_reserved_retry = reconnectTestRetry(2) },
        args,
        initReconnectTestGeneration,
    );
    try executor.completeJob(&owner, .{
        .job_generation = 3,
        .total = 1,
        .published_new = 0,
        .frozen_unavailable = 1,
        .ended = 0,
        .retry_reserved = 1,
    });
    try testing.expect(!try owner.slot.hasRetiring());
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
}

test "CR2e-e2b 제품 executor는 copied cross-owner authority를 effect 전에 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        testing.allocator,
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x41 },
        initReconnectTestGeneration,
    );
    var executor: ReconnectProductExecutor = .{};
    try executor.initInPlace(&owner, 3);
    defer {
        executor.deinit(&owner) catch @panic("test executor deinit failed");
        deinitReconnectTestOwner(&owner, &proxy);
    }
    var copied = executor;
    const owner_before = owner;
    try testing.expectError(error.InvalidAuthority, copied.apply(
        &owner,
        .{ .begin_prepare = reconnectTestWork(2) },
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x42 },
        initReconnectTestGeneration,
    ));
    try testing.expect(std.meta.eql(owner_before, owner));
    try testing.expect(std.meta.eql(PreparedReconnect{}, executor.prepared));

    var foreign_proxy: stable_screen_source.StableScreenSource = undefined;
    try foreign_proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 4, .rows = 2 });
    var foreign_owner: ReconnectGenerationOwner = .{};
    try foreign_owner.initInPlace(
        testing.allocator,
        &foreign_proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x43 },
        initReconnectTestGeneration,
    );
    defer deinitReconnectTestOwner(&foreign_owner, &foreign_proxy);
    try testing.expectError(error.InvalidAuthority, executor.apply(
        &foreign_owner,
        .{ .begin_prepare = reconnectTestWork(2) },
        ReconnectGenerationTestArgs{ .allocator = testing.allocator, .stream_id = 0x44 },
        initReconnectTestGeneration,
    ));
    try testing.expectEqual(@as(u64, 2), try owner.currentGeneration());
    try testing.expectEqual(@as(u64, 2), try foreign_owner.currentGeneration());
    try testing.expect(std.meta.eql(PreparedReconnect{}, executor.prepared));
    try testing.expect(!try owner.slot.hasRetiring());
    try testing.expect(!try foreign_owner.slot.hasRetiring());
}

test "CR2e-e2b 제품 executor는 reachable Decision 31개와 effect table을 전수 일치시킨다" {
    const D = reconnect_reducer.Decision;
    const E = ReconnectGenerationEffect;
    const rows = [_]struct { decision: D, effect: E }{
        .{ .decision = .prepare_candidate, .effect = .prepare_candidate },
        .{ .decision = .retain_staged_observer, .effect = .retain },
        .{ .decision = .seal_mutations, .effect = .retain },
        .{ .decision = .retain_clean_seal, .effect = .retain },
        .{ .decision = .retain_ambiguous_seal, .effect = .retain },
        .{ .decision = .abort_candidate_restore_old, .effect = .abort_candidate_if_present },
        .{ .decision = .abort_candidate_restore_old_with_paused_notice, .effect = .abort_candidate_if_present },
        .{ .decision = .abort_candidate_freeze_old, .effect = .abort_candidate_if_present },
        .{ .decision = .start_authority_commit, .effect = .retain },
        .{ .decision = .retain_takeover_unknown, .effect = .retain },
        .{ .decision = .retain_controller_evidence, .effect = .retain },
        .{ .decision = .retain_authority_conflict, .effect = .retain },
        .{ .decision = .retain_gone_evidence, .effect = .retain },
        .{ .decision = .wait_for_direct_release, .effect = .retain },
        .{ .decision = .resume_with_direct_grant, .effect = .retain },
        .{ .decision = .publish_retry_conflict, .effect = .retain },
        .{ .decision = .start_publication, .effect = .retain },
        .{ .decision = .publish_new_and_open, .effect = .publish_candidate },
        .{ .decision = .publish_unavailable_with_retry, .effect = .abort_candidate_if_present },
        .{ .decision = .publish_ended, .effect = .abort_candidate_if_present },
        .{ .decision = .publish_job_unavailable, .effect = .abort_candidate_if_present },
        .{ .decision = .retry_job, .effect = .prepare_candidate },
        .{ .decision = .finish_job, .effect = .reclaim_retiring_if_present },
        .{ .decision = .publish_termination_pending, .effect = .retain },
        .{ .decision = .close_preserve_old, .effect = .abort_candidate_if_present },
        .{ .decision = .close_preserve_old_with_paused_notice, .effect = .abort_candidate_if_present },
        .{ .decision = .close_publish_new, .effect = .publish_candidate },
        .{ .decision = .close_freeze_with_retry, .effect = .abort_candidate_if_present },
        .{ .decision = .close_finish_terminal, .effect = .abort_candidate_if_present },
        .{ .decision = .publish_termination_unconfirmed, .effect = .retain },
        .{ .decision = .abandon_shell_to_inventory, .effect = .retain },
    };
    try testing.expectEqual(@typeInfo(D).@"enum".fields.len, rows.len);
    var seen: [rows.len]bool = @splat(false);
    for (rows) |row| {
        try testing.expectEqual(row.effect, reconnectGenerationEffect(row.decision));
        const index = @intFromEnum(row.decision);
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |value| try testing.expect(value);
    inline for (.{
        reconnect_reducer.LocalState.published_old,
        reconnect_reducer.LocalState.frozen_unavailable,
        reconnect_reducer.LocalState.ended,
    }) |local| {
        try testing.expect(reconnectRetiringMatchesLocal(local, false));
        try testing.expect(!reconnectRetiringMatchesLocal(local, true));
    }
    try testing.expect(reconnectRetiringMatchesLocal(.published_new, true));
    try testing.expect(!reconnectRetiringMatchesLocal(.published_new, false));
    try expectEveryReconnectDecisionReachable();
}

test "CR2e-e3a1 candidate base resident ledger는 prepare abort와 final zero를 고정한다" {
    const candidate_resident_bytes = try reconnectCandidateResidentBytes();
    ReconnectGenerationTestState.deinit_count = 0;
    var ledger = ReconnectResidentLedger{ .parent = testing.allocator };
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 80, .rows = 24 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        ledger.allocator(),
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = ledger.allocator(), .stream_id = 0xE301 },
        initReconnectTestGeneration,
    );
    var prepared: PreparedReconnect = .{};
    var owner_live = true;
    defer {
        if (!std.meta.eql(prepared, PreparedReconnect{}))
            owner.abort(&prepared) catch @panic("candidate cleanup failed");
        if (owner_live) {
            if (owner.slot.hasRetiring() catch false)
                owner.reclaimRetiring() catch @panic("retiring cleanup failed");
            deinitReconnectTestOwner(&owner, &proxy);
        }
    }

    const baseline_bytes = ledger.live_bytes;
    const baseline_allocations = ledger.live_allocations;
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = ledger.allocator(), .stream_id = 0xE302 },
        initReconnectTestGeneration,
    );
    const candidate_bytes = ledger.live_bytes - baseline_bytes;
    const candidate_allocations = ledger.live_allocations - baseline_allocations;
    try testing.expectEqual(candidate_resident_bytes, candidate_bytes);
    try testing.expectEqual(@as(usize, 1), candidate_allocations);
    try testing.expectEqual(baseline_bytes + candidate_resident_bytes, ledger.peak_bytes);
    try testing.expectEqual(baseline_allocations + 1, ledger.peak_allocations);
    try owner.abort(&prepared);
    try testing.expectEqual(baseline_bytes, ledger.live_bytes);
    try testing.expectEqual(baseline_allocations, ledger.live_allocations);

    try owner.deinit();
    owner_live = false;
    proxy.deinit();
    try testing.expectEqual(@as(usize, 0), ledger.live_bytes);
    try testing.expectEqual(@as(usize, 0), ledger.live_allocations);
}

test "CR2e-e3a1 candidate base publish retiring reclaim은 logical delta를 exact once 회수한다" {
    const candidate_resident_bytes = try reconnectCandidateResidentBytes();
    ReconnectGenerationTestState.deinit_count = 0;
    var ledger = ReconnectResidentLedger{ .parent = testing.allocator };
    var proxy: stable_screen_source.StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(testing.allocator, testing.io, .{ .cols = 80, .rows = 24 });
    var owner: ReconnectGenerationOwner = .{};
    try owner.initInPlace(
        ledger.allocator(),
        &proxy,
        2,
        ReconnectGenerationTestArgs{ .allocator = ledger.allocator(), .stream_id = 0xE311 },
        initReconnectTestGeneration,
    );
    var prepared: PreparedReconnect = .{};
    var owner_live = true;
    defer {
        if (!std.meta.eql(prepared, PreparedReconnect{}))
            owner.abort(&prepared) catch @panic("candidate cleanup failed");
        if (owner_live) {
            if (owner.slot.hasRetiring() catch false)
                owner.reclaimRetiring() catch @panic("retiring cleanup failed");
            deinitReconnectTestOwner(&owner, &proxy);
        }
    }

    const baseline_bytes = ledger.live_bytes;
    const baseline_allocations = ledger.live_allocations;
    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = ledger.allocator(), .stream_id = 0xE312 },
        initReconnectTestGeneration,
    );
    const prepared_bytes = ledger.live_bytes;
    const prepared_allocations = ledger.live_allocations;
    try owner.publish(&prepared);
    try testing.expectEqual(prepared_bytes, ledger.live_bytes);
    try testing.expectEqual(prepared_allocations, ledger.live_allocations);
    try testing.expect(try owner.slot.hasRetiring());
    try owner.reclaimRetiring();
    try testing.expect(!(try owner.slot.hasRetiring()));
    try testing.expectEqual(candidate_resident_bytes, ledger.live_bytes - baseline_bytes);
    try testing.expectEqual(@as(usize, 1), ledger.live_allocations - baseline_allocations);

    try owner.prepare(
        &prepared,
        ReconnectGenerationTestArgs{ .allocator = ledger.allocator(), .stream_id = 0xE313 },
        initReconnectTestGeneration,
    );
    try testing.expectEqual(
        2 * candidate_resident_bytes,
        ledger.live_bytes - baseline_bytes,
    );
    try testing.expectEqual(@as(usize, 2), ledger.live_allocations - baseline_allocations);
    try testing.expectEqual(
        baseline_bytes + 2 * candidate_resident_bytes,
        ledger.peak_bytes,
    );
    try testing.expectEqual(baseline_allocations + 2, ledger.peak_allocations);
    try owner.publish(&prepared);
    try owner.reclaimRetiring();
    try testing.expectEqual(candidate_resident_bytes, ledger.live_bytes - baseline_bytes);
    try testing.expectEqual(@as(usize, 1), ledger.live_allocations - baseline_allocations);

    try owner.deinit();
    owner_live = false;
    proxy.deinit();
    try testing.expectEqual(@as(usize, 0), ledger.live_bytes);
    try testing.expectEqual(@as(usize, 0), ledger.live_allocations);
}

fn expectEveryReconnectDecisionReachable() !void {
    const work = reconnectTestWork(2);
    const retry_work: reconnect_reducer.Work = .{
        .job_generation = 3,
        .shell_generation = 2,
        .attempt = 2,
        .candidate_connection_generation = 3,
        .deadline_ns = 200,
    };
    const retry2 = reconnectTestRetry(2);
    const retry3 = reconnectTestRetry(3);
    const events = [_]reconnect_reducer.Event{
        .{ .begin_prepare = work },
        .observer_staged,
        .begin_mutation_seal,
        .seal_clean,
        .seal_ambiguous,
        .precommit_failed_clean,
        .precommit_failed_ambiguous_usable,
        .{ .precommit_failed_ambiguous_unusable = retry2 },
        .begin_authority_commit,
        .takeover_sent_unknown,
        .controller_evidenced,
        .authority_conflict,
        .gone_positive,
        .{ .begin_retry_wait_release = .{ .work = work, .runtime_id = .{1} ** 16 } },
        .retry_direct_granted,
        .{ .retry_expired = .{ .now_ns = 100 } },
        .begin_publish,
        .publish_new,
        .{ .freeze_with_reserved_retry = retry2 },
        .end_runtime,
        .{ .prepare_unavailable = .{
            .job_generation = 3,
            .shell_generation = 2,
            .last_attempt = 1,
            .last_candidate_connection_generation = 2,
            .retry_at_ns = 50,
            .deadline_ns = 100,
        } },
        .{ .prepare_unavailable = .{
            .job_generation = 3,
            .shell_generation = 2,
            .last_attempt = 2,
            .last_candidate_connection_generation = 3,
            .retry_at_ns = 150,
            .deadline_ns = 200,
        } },
        .{ .retry_unavailable = .{ .work = retry_work, .clock = .{ .now_ns = 50 } } },
        .{ .close_requested = .{ .intent_generation = 1, .shell_generation = 2, .deadline_ns = 300 } },
        .{ .close_requested = .{ .intent_generation = 1, .shell_generation = 3, .deadline_ns = 300 } },
        .{ .reconnect_quiesced_for_close = .{ .old_transport_usable = true, .retry = null } },
        .{ .reconnect_quiesced_for_close = .{ .old_transport_usable = false, .retry = retry2 } },
        .{ .reconnect_quiesced_for_close = .{ .old_transport_usable = false, .retry = retry3 } },
        .{ .close_timed_out = .{ .now_ns = 300 } },
        .abandon_to_inventory,
    };
    var states: std.ArrayListUnmanaged(reconnect_reducer.State) = .empty;
    defer states.deinit(testing.allocator);
    try states.append(testing.allocator, reconnect_reducer.State.initial(3, 2));
    var decisions: [@typeInfo(reconnect_reducer.Decision).@"enum".fields.len]bool = @splat(false);
    var cursor: usize = 0;
    while (cursor < states.items.len) : (cursor += 1) {
        const before = states.items[cursor];
        for (events) |event| {
            const result = reconnect_reducer.reduce(before, event) catch |err| {
                try testing.expectEqual(error.IllegalTransition, err);
                continue;
            };
            decisions[@intFromEnum(result.decision)] = true;
            try appendUniqueReconnectState(&states, result.state);
        }
        const summaries = [_]reconnect_reducer.TerminalSummary{
            .{ .job_generation = 3, .total = 1, .published_new = 1, .frozen_unavailable = 0, .ended = 0, .retry_reserved = 0 },
            .{ .job_generation = 3, .total = 1, .published_new = 0, .frozen_unavailable = 1, .ended = 0, .retry_reserved = 1 },
            .{ .job_generation = 3, .total = 1, .published_new = 0, .frozen_unavailable = 0, .ended = 1, .retry_reserved = 0 },
        };
        for (summaries) |summary| {
            const result = reconnect_reducer.completeJob(before, summary) catch |err| {
                try testing.expectEqual(error.IllegalTransition, err);
                continue;
            };
            decisions[@intFromEnum(result.decision)] = true;
            try appendUniqueReconnectState(&states, result.state);
        }
        try testing.expect(states.items.len <= 2048);
    }
    for (decisions, 0..) |reached, index| {
        if (!reached) {
            std.debug.print("unreachable reconnect decision: {s}\n", .{
                @tagName(@as(reconnect_reducer.Decision, @enumFromInt(index))),
            });
        }
        try testing.expect(reached);
    }
}

fn appendUniqueReconnectState(
    states: *std.ArrayListUnmanaged(reconnect_reducer.State),
    state: reconnect_reducer.State,
) !void {
    for (states.items) |existing| if (std.meta.eql(existing, state)) return;
    try states.append(testing.allocator, state);
}

fn countField(comptime fields: []const std.builtin.Type.StructField, comptime name: []const u8) usize {
    comptime var result: usize = 0;
    inline for (fields) |field| if (std.mem.eql(u8, field.name, name)) {
        result += 1;
    };
    return result;
}

test "ProcessIdentity.adopt: 0은 알던 뿌리를 지우지 않는다" {
    // 이 테스트가 증명하는 것(터미널에서 왜 중요한가): 이 pid가 상태바가 host-backed 터미널을 재는
    // 유일한 뿌리다. 한 번이라도 0으로 덮이면 그 탭의 메모리·CPU가 **영영** `—`가 되는데, 화면에서는
    // "원래 안 나오는 값"과 구분되지 않아 회귀를 눈으로 못 잡는다.
    var id: ProcessIdentity = .{};
    id.adopt(4242, 99);
    try std.testing.expectEqual(@as(i32, 4242), id.child_pid);
    try std.testing.expectEqual(@as(i32, 99), id.host_pid);

    id.adopt(0, 0); // 구 host 관측이 한 번 섞였다 — 유지되어야 한다.
    try std.testing.expectEqual(@as(i32, 4242), id.child_pid);
    try std.testing.expectEqual(@as(i32, 99), id.host_pid);

    // 한쪽만 실려 와도 다른 쪽은 그대로다(둘은 독립된 사실이다).
    id.adopt(7, 0);
    try std.testing.expectEqual(@as(i32, 7), id.child_pid);
    try std.testing.expectEqual(@as(i32, 99), id.host_pid);
}

test "ProcessIdentity.trusted: 못 믿는 관측에서는 아무것도 모르는 상태로 돌려준다" {
    // 이 테스트가 증명하는 것(터미널에서 왜 중요한가): 이 가드가 없으면 host 와 말이 끊긴 뒤에도 캐시된
    // pid 로 계속 재고, 그 pid 가 죽고 **OS 가 같은 번호를 재사용하는 순간 남의 프로세스 메모리가 그 탭의
    // 값으로 그려진다.** 숫자가 그럴듯해서 화면으로는 절대 못 잡는 종류라 여기서 못박는다.
    const known: ProcessIdentity = .{ .child_pid = 4242, .host_pid = 99 };

    // current 면 그대로 — 재는 데 쓴다.
    try std.testing.expectEqual(@as(i32, 4242), known.trusted(true).child_pid);
    try std.testing.expectEqual(@as(i32, 99), known.trusted(true).host_pid);

    // current 가 아니면 **둘 다** 0 이다. 하나만 막으면 데몬 행이나 탭 행 중 한쪽이 계속 잘못 그려진다.
    try std.testing.expectEqual(@as(i32, 0), known.trusted(false).child_pid);
    try std.testing.expectEqual(@as(i32, 0), known.trusted(false).host_pid);

    // **캐시를 지우지는 않는다** — 다시 current 가 되면 살아나야 한다(재접속마다 뿌리를 잃으면 그 탭이
    // 한동안 `—`로 남는다). `trusted` 는 값 판정이지 소거가 아니다.
    try std.testing.expectEqual(@as(i32, 4242), known.trusted(true).child_pid);
}

test "S11-6 실패한 리사이즈는 «요청» 이 아니다 — 안 그러면 상태줄이 거짓말한다" {
    const T = std.testing;
    // 이 판정자가 지키는 것은 **순서**다: `requested_cols` 는 RPC 가 성공한 뒤에만 바뀐다.
    // 보내기 전에 적으면, 요청이 실패해 host 크기가 그대로일 때
    // `narrowedFrom(요청=100, 확정=80)` 이 80 을 내어 **아무도 안 좁혔는데** 표시가 뜬다.
    //
    // 그 순서 자체는 `resize()` 안에 있고 여기서는 그 순서가 지켜졌을 때의 **값**을 고정한다:
    // 실패했으면 `requested_cols` 는 예전 값(여기서는 80)으로 남아 있어야 하고, 그러면 판정이 0 이다.
    try T.expectEqual(@as(u16, 0), narrowedFrom(80, 80));
    // 반대로 보내기 전에 적었다면 100 이 남아 이 값이 80 을 냈을 것이다.
    try T.expectEqual(@as(u16, 80), narrowedFrom(100, 80));
}

test "S11-6 «남이 좁혔나» 는 요청한 값과 확정된 값만으로 정해진다" {
    const T = std.testing;
    // 한 번도 요청한 적이 없으면 견줄 대상이 없다 — 붙자마자 온 첫 이벤트가 여기 걸린다.
    try T.expectEqual(@as(u16, 0), narrowedFrom(0, 50));

    // 내가 요청한 대로 됐다.
    try T.expectEqual(@as(u16, 0), narrowedFrom(80, 80));

    // **폰이 붙었다** — 내가 80 을 요청했는데 host 가 50 을 확정했다.
    try T.expectEqual(@as(u16, 50), narrowedFrom(80, 50));

    // **폰이 떠났다** — host 가 기준으로 되돌려 내 요청과 같아졌다. 표시가 사라져야 한다.
    // 이 전이를 놓치면 항목이 영영 안 사라진다(설계 단계에서 잡은 구멍이다).
    try T.expectEqual(@as(u16, 0), narrowedFrom(80, 80));

    // **내가 창을 줄인 것은 «남이 좁힌 것» 이 아니다.**
    try T.expectEqual(@as(u16, 0), narrowedFrom(40, 40));

    // 남이 넓힐 수는 없지만(줄이기만 한다), 그런 값이 와도 표시하지 않는다.
    try T.expectEqual(@as(u16, 0), narrowedFrom(80, 100));
}

test "S11-6 좁힘 상태는 연결보다 오래 산다 — generation 이 아니라 runtime 이 든다" {
    // **재연결하면 generation 이 새로 선다**(`initInitialRemoteGeneration` 이 기본값으로 채운다).
    // 이 둘이 거기 살면 그때 0 이 되어 **세션은 여전히 좁은데 표시만 사라진다** — 계약이 금지한
    // 「아무 신호 없이 줄어든 상태」가 된다(적대적 검증 3회차).
    //
    // 이 둘은 연결이 아니라 **내 의도**에 대한 사실이라 연결보다 오래 살아야 한다.
    try testing.expect(!@hasField(RemoteGeneration, "requested_cols"));
    try testing.expect(!@hasField(RemoteGeneration, "narrowed_cols"));
    try testing.expect(@hasField(RemoteRuntime, "requested_cols"));
    try testing.expect(@hasField(RemoteRuntime, "narrowed_cols"));
}
