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
const maru = @import("maru");
const terminal = maru.terminal;
const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const runtime_pump_mod = maru.app.runtime_pump;
const input_owner_mod = maru.app.input_owner;
const client_mod = @import("client.zig");
const client_slot_mod = @import("client_slot.zig");
const client_poison = @import("client_poison.zig");
const control_response_wire = @import("control_response_wire.zig");
const protocol = @import("protocol.zig");
const screen_assembler = @import("screen_assembler.zig");
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

var remote_runtime_owner_incarnation_issuer: std.atomic.Value(u64) = .init(1);

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
            .generation => |*value| value.allowsMutation(),
        };
    }

    fn mutationAllowed(
        self: *const RuntimeAttachment,
        client: *const client_mod.Client,
    ) bool {
        return switch (self.*) {
            .legacy => |*value| value.allowsMutation() and
                !client.hasBufferedControllerRevokeForStream(value.streamId()),
            .generation => |*value| value.allowsMutation(),
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
            .legacy => |*value| (client orelse return error.ProtocolError).sendResyncNonBlocking(value.streamId()),
            .generation => |*value| value.sendResyncNonBlocking() catch |err|
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
        client: ?*client_mod.Client,
        request: generation_contract.RuntimeRequest,
        legacy_method: []const u8,
        legacy_params_json: ?[]const u8,
        context: *anyopaque,
        decoder: generation_contract.RpcDecoder,
        poison_capture: ?client_slot_mod.PreparedExecutionPoisonCaptureRequest,
    ) client_mod.ClientError!generation_contract.RpcDecodeDisposition {
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
                switch (preDecodeBufferedEvents(self)) {
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
                self,
                preDecodeBufferedEvents,
                poison_capture,
            ) catch |err| {
                if (self.statePtr().role == .observer) return error.Unauthorized;
                return mapGenerationDecodedError(err);
            },
        };
    }

    fn preDecodeBufferedEvents(context: *anyopaque) generation_contract.RpcPreDecodeDisposition {
        const self: *RuntimeAttachment = @ptrCast(@alignCast(context));
        const generation: *RemoteGeneration = @fieldParentPtr("attachment", self);
        const runtime: *RemoteRuntime = @fieldParentPtr("generation", generation);
        const before_role = runtime.generation.attachment.statePtr().role;
        const before_generation = runtime.generation.attachment.statePtr().controller_generation;
        const drained = runtime.drainObservationEvents() catch |err| return switch (err) {
            error.AdminBusy => .busy,
            error.OutOfMemory => .out_of_memory,
            error.ConnectionClosed => .connection_closed,
            else => .protocol_failure,
        };
        if (drained.ended) return .connection_closed;
        const after = runtime.generation.attachment.statePtr();
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
    title: []u8,
    body: []u8,
    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
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

/// Active connection과 함께 교체·retire되는 generation-local owner bundle이다. CR2a는 기존
/// field를 물리적으로 묶기만 하며 allocator, Surface와 stable input/lifecycle owner를 섞지 않는다.
pub const RemoteGeneration = struct {
    connection: RuntimeConnection,
    attachment: RuntimeAttachment,
    event_generation_tracking: EventGenerationTracking,
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    resize_generation: u64,
    resize_baseline_present: bool,
    // shared transport hard failure를 이 runtime surface에 한 번만 투영한다. connection 하나를 여러 runtime이
    // 공유하므로 각 runtime pump가 자기 surface를 exited로 latch하되 매 frame 같은 read_error를 재방출하지 않는다.
    pump_ended: bool,
    resync_needed: bool,
    frame_summary_ready: bool = false,
    frame_summary: runtime_pump_mod.DrainSummary = .{},
    observation: term_backend.RuntimeObservation, // host attach/event에서 받은 화면 외 full-state owned cache.
};

/// 한 원격 runtime. self-referential(`surface.remote`가 attachment screen을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    generation: RemoteGeneration,
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    // blocking `SurfaceRuntime.writeInput`의 key bytes와 그 사이 core command를 한 시간축으로 보존한다.
    // control.barrier는 그 명령보다 먼저 host에 도착해야 하는 direct_input byte prefix 끝이다.
    direct_input: std.ArrayListUnmanaged(u8),
    direct_input_offset: usize,
    input_batches: input_owner_mod.StableQueueState,
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

    fn generationConnection(self: *const RemoteRuntime) ?*host_adapter_mod.HostAdapter {
        return switch (self.generation.connection) {
            .legacy => null,
            .generation => |adapter| adapter,
        };
    }

    fn legacyConnection(self: *const RemoteRuntime) *client_mod.Client {
        return switch (self.generation.connection) {
            .legacy => |client| client,
            .generation => @panic("generation runtime cannot borrow a raw Client"),
        };
    }

    fn legacyConnectionOrNull(self: *const RemoteRuntime) ?*client_mod.Client {
        return switch (self.generation.connection) {
            .legacy => |client| client,
            .generation => null,
        };
    }

    fn testingClient(self: *const RemoteRuntime) *client_mod.Client {
        if (!builtin.is_test) unreachable;
        return switch (self.generation.connection) {
            .legacy => |client| client,
            .generation => |adapter| host_adapter_mod.HostAdapter.testing.rawClient(adapter),
        };
    }

    fn poisonConnection(self: *RemoteRuntime, reason: client_poison_mod.ConnectionReason) void {
        switch (self.generation.connection) {
            .legacy => |client| client.poison(reason),
            .generation => switch (self.generation.attachment) {
                .legacy => process_seal_service.fatalIntegrity(.proof_loss),
                .generation => |*attachment| attachment.poison(reason) catch
                    process_seal_service.fatalIntegrity(.proof_loss),
            },
        }
    }

    fn connectionCapabilities(self: *const RemoteRuntime) generation_contract.GenerationCapabilities {
        return switch (self.generation.connection) {
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
                    .screen_viewport_scrolled = client.screen_viewport_scrolled_v1,
                    .async_scroll_to_bottom = client.async_scroll_to_bottom_v1,
                    .notification_stream_auth = client.notification_stream_auth_v1,
                    .runtime_clipboard = client.runtime_clipboard_v1,
                    .runtime_core_command = client.runtime_core_command_v1,
                    .runtime_link_at = client.runtime_link_at_v1,
                    .runtime_selected_text = client.runtime_selected_text_v1,
                };
            },
            .generation => |adapter| adapter.generationCapabilities(),
        };
    }

    /// app-quit 준비는 disk discovery를 다시 하지 않고 runtime이 이미 붙잡은 exact adapter snapshot만 읽는다.
    pub fn appQuitShutdownManifest(self: *const RemoteRuntime) ?host_manifest_mod.Descriptor {
        return switch (self.generation.connection) {
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
        );
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
        );
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
    ) anyerror!void {
        // origin/main의 구 v2 daemon도 runtime.spawn_full 이름은 알지만 unknown `runtime_config` 필드를 무시한다.
        // 새 config codec과 함께 도입된 capability가 없으면 잘못된 기본값으로 spawn 성공을 가장하지 않고,
        // AppSession이 명시적인 in-process fallback 경로를 선택하게 한다.
        const runtime_core_command = switch (connection) {
            .legacy => |client| client.runtime_core_command_v1,
            .generation => |adapter| adapter.generationCapabilities().runtime_core_command,
        };
        if (initial_config != null and !runtime_core_command) return error.UnsupportedSpawnContract;
        self.generation.connection = connection;
        self.allocator = allocator;
        self.io = io;
        self.generation.resize_seq = 0;
        self.generation.resize_generation = 0;
        self.generation.resize_baseline_present = false;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.input_batches = .{};
        self.pending_controls = .empty;
        self.blocking_flush_active = false;
        self.generation.pump_ended = false;
        self.generation.resync_needed = false;
        self.pending_event_owner = .{};
        self.close_authority = .{};
        self.shutdown_attempt_authority = .{};
        self.shutdown_current_admin = .{};
        self.runtime_lifetime = .{};
        try self.initializePendingEventOwner();
        self.generation.observation = .{};
        errdefer self.generation.observation.deinit(allocator);

        // 1. runtime.spawn_full — host가 확장 spawn 계약으로 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, request, size, initial_config) catch return error.OutOfMemory;
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
        self.generation.connection = connection;
        self.allocator = allocator;
        self.io = io;
        self.generation.resize_seq = 0;
        self.generation.resize_generation = 0;
        self.generation.resize_baseline_present = false;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.input_batches = .{};
        self.pending_controls = .empty;
        self.blocking_flush_active = false;
        self.generation.pump_ended = false;
        self.generation.resync_needed = false;
        self.pending_event_owner = .{};
        self.close_authority = .{};
        self.shutdown_attempt_authority = .{};
        self.shutdown_current_admin = .{};
        self.runtime_lifetime = .{};
        try self.initializePendingEventOwner();
        self.generation.observation = .{};
        errdefer self.generation.observation.deinit(allocator);
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    fn initializePendingEventOwner(self: *RemoteRuntime) anyerror!void {
        // legacy와 generation은 같은 process seal domain을 공유한다. generation identity는
        // legacy pristine 우회를 만드는 근거가 아니라 추가 일치 증거로만 사용한다.
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        const process_identity = try process_seal_service.currentReadyIdentity();
        if (self.generation.connection == .generation) {
            const adapter = self.generation.connection.generation;
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
        return self.generation.attachment.generation.preparePendingSettlement(.{
            .allocator = self.allocator,
            .lifetime_owner = &self.runtime_lifetime,
            .pending_owner = &self.pending_event_owner,
            .runtime_addr = @intFromPtr(self),
            .runtime_extent = @sizeOf(RemoteRuntime),
            .observation = &self.generation.observation,
            .direct_input = &self.direct_input,
            .direct_input_offset = &self.direct_input_offset,
            .pending_controls = &self.pending_controls,
            .blocking_flush_active = &self.blocking_flush_active,
            .resize_generation = &self.generation.resize_generation,
            .resize_baseline_present = &self.generation.resize_baseline_present,
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
            .observation = &self.generation.observation,
            .direct_input = &self.direct_input,
            .direct_input_offset = &self.direct_input_offset,
            .pending_controls = &self.pending_controls,
            .blocking_flush_active = &self.blocking_flush_active,
            .resize_generation = &self.generation.resize_generation,
            .resize_baseline_present = &self.generation.resize_baseline_present,
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
        self.screen_source = try self.allocator.create(stable_screen_source.StableScreenSource);
        errdefer self.allocator.destroy(self.screen_source);
        try self.screen_source.initUnavailableInPlace(self.allocator, self.io, size);
        errdefer {
            _ = self.screen_source.close() catch null;
            self.screen_source.deinit();
        }
        self.generation.frame_summary_ready = false;
        self.generation.frame_summary = .{};
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
            _ = self.generation.attachment.generation.finishResponse(self.generationConnection().?);
            self.generation.attachment.generation.abortExecutedAttach(
                self.generationConnection().?,
                accepted.executed_call,
            ) catch @panic("generation attach rollback failed");
        };
        const attach_resp: []const u8 = if (self.generationConnection()) |adapter| blk: {
            try self.generation.attachment.initGenerationInPlace(adapter);
            const prepared = try self.generation.attachment.generation.prepareControllerAttach(
                adapter,
                runtime_id,
            );
            const result = try self.generation.attachment.generation.executePreparedAttach(adapter, prepared);
            const correlated = switch (result) {
                .accepted => |value| value,
                .typed_reject => {
                    _ = self.generation.attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
                .uncertain_or_connection_failure => {
                    _ = self.generation.attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
            };
            generation_accepted = correlated;
            generation_binding_open = true;
            break :blk try self.generation.attachment.generation.responseBytes(adapter);
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
        self.generation.event_generation_tracking = switch (generation_schema) {
            .frozen_controller_only, .granted_without_generation => .untracked,
            .granted_with_generation => .tracked,
        };
        if (self.generationConnection()) |adapter| {
            if (self.generation.attachment.generation.finishResponse(adapter) != .cleaned)
                @panic("generation attach response cleanup failed");
            try self.generation.attachment.generation.commitAccepted(
                adapter,
                generation_accepted.?,
                accepted.state,
                self.allocator,
            );
            generation_binding_open = false;
        } else {
            self.generation.attachment = .init(self.allocator, accepted.state);
            self.generation.attachment.bindLegacyTransport(attachmentTransport(self.legacyConnection())) catch {
                self.poisonConnection(.local_invariant_violation);
                return error.AttachFailed;
            };
        }
        // attach RPC가 controller lease를 잡은 뒤 snapshot/화면 조립이 실패하면 caller에는 아직 완성된
        // RemoteRuntime이 없어 detachClientSide를 부를 수 없다. 이 구간에서 반드시 lease와 demux 큐를 되돌린다.
        errdefer {
            self.detachBestEffort();
            self.generation.attachment.deinitWithConnection(self.generation.connection);
        }

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        var generation_snapshot: initial_snapshot_owner_mod.InitialSnapshotOwner = .{};
        var generation_snapshot_live = false;
        var legacy_snapshot: ?[]u8 = null;
        const snap: []const u8 = switch (self.generation.attachment) {
            .legacy => blk: {
                const bytes = try self.legacyConnection().readSnapshot(self.generation.attachment.streamId());
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
        try self.generation.attachment.initScreen(capabilities.screen_codec_version);
        // mode bit 자체는 v2에도 우연히 존재할 수 있으므로 hello_ack에서 명시 협상한 host일 때만 "0 = live bottom"을
        // 신뢰한다. 구 host는 capability=false로 두고, RemoteScreen이 snapshot별 visible cursor 증거만으로
        // legacy live preedit/candidate를 허용한다. hidden/ambiguous snapshot은 계속 fail-closed다.
        self.generation.attachment.screenPtr().?.viewport_scrolled_known = capabilities.screen_viewport_scrolled;
        self.generation.attachment.screenPtr().?.applySnapshot(snap, self.io) catch |err| {
            switch (self.generation.attachment) {
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
        _ = try self.screen_source.publishLive(
            self.generation.attachment.screenPtr().?.screenSource(),
            2,
        );
        self.surface.remote = self.screen_source.screenSource();
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    fn deinitScreenSource(self: *RemoteRuntime) void {
        _ = self.screen_source.close() catch
            @panic("stable screen proxy close lost final owner");
        self.screen_source.deinit();
        self.allocator.destroy(self.screen_source);
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.admitDestructiveRuntimeOperation();
        self.terminateBestEffort();
        // terminate response보다 먼저 온 async continuation도 call이 pending_stream에 보존하므로 RPC 뒤 한 번에 회수한다.
        self.surface.deinit();
        self.deinitScreenSource();
        self.generation.attachment.deinitWithConnection(self.generation.connection);
        self.generation.observation.deinit(self.allocator);
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
        // shared connection은 앱 종료 전까지 EOF가 오지 않을 수 있다. RPC detach 없이 로컬 객체만 버리면 host의 controller
        // lease가 남아 같은 connection의 재attach가 controller_busy가 되므로 subscription을 먼저 명시 해제한다.
        self.detachBestEffort();
        self.surface.deinit();
        self.deinitScreenSource();
        self.generation.attachment.deinitWithConnection(self.generation.connection); // stream demux queue + attachment-owned screen.
        self.generation.observation.deinit(self.allocator);
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
        return !self.generation.attachment.allowsMutation();
    }

    pub fn usesGenerationAttachment(self: *const RemoteRuntime) bool {
        return switch (self.generation.attachment) {
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
        return switch (self.generation.connection) {
            .legacy => |client| self.generation.attachment.mutationAllowed(client),
            .generation => self.generation.attachment.allowsMutation(),
        };
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (bytes.len == 0) return;
        // SurfaceRuntime가 이 권위 거부를 InputSuppressed로 바꿔 trace 0과 paste 영구 폐기를
        // 함께 보장한다. 성공으로 숨기면 실제 PTY에 안 간 입력이 trace에 기록된다.
        if (!self.mutationAllowed()) return error.Unauthorized;
        self.compactDirectInput();
        const pending = self.direct_input.items.len - self.direct_input_offset;
        if (bytes.len > max_direct_input_bytes -| pending) return error.OutOfMemory;
        self.direct_input.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
        // 소유권을 queue가 인수한 뒤에는 backpressure나 frame encode OOM을 오류로 돌려 caller가 같은 key를
        // 실패/재시도 처리하게 하지 않는다. hard connection error만 전파하고 tick이 이어 보낸다.
        _ = try self.pumpQueuedInput();
    }

    /// UI tick의 입력을 client 연결의 bounded pending frame에 맡긴다. 반환값은 wire write량이 아니라 client가 소유권을
    /// 인수한 payload 길이라 caller가 partial socket write를 같은 입력으로 재시도하지 않는다.
    pub fn sendInputNonBlocking(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!usize {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!(try self.pumpQueuedInput())) return 0;
        return switch (self.generation.connection) {
            .legacy => |client| self.generation.attachment.sendInputNonBlocking(client, bytes),
            .generation => self.generation.attachment.generation.sendInputNonBlocking(bytes) catch |err|
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
        const pending = self.direct_input.items.len - self.direct_input_offset;
        if (total > max_direct_input_bytes -| pending) return error.OutOfMemory;
        const sequence = std.math.add(u64, self.input_batches.next_sequence, 1) catch return error.OutOfMemory;
        if (sequence == 0 or self.input_batches.epoch == 0) return error.ProtocolError;
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
            .kind = batch.kind,
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
        switch (self.generation.attachment) {
            .legacy => if (!self.legacyConnection().async_scroll_to_bottom_v1) return,
            .generation => {},
        }
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
        self.pending_controls.append(self.allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(barrier) orelse
            return self.failControlAdmission()) catch
            return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    /// focus/config/prompt 등 host-authoritative 명령을 input과 같은 stream-local 시간축에 넣는다. queue가 인수한 뒤
    /// socket backpressure가 생겨도 다음 frame tick이 재시도하며, bounded cap을 넘으면 명시적으로 실패한다.
    pub fn queueCoreCommand(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        switch (self.generation.attachment) {
            .legacy => if (!self.legacyConnection().runtime_core_command_v1) {
                if (command.isLegacyScroll()) return self.sendCoreCommandBlocking(command);
                return;
            },
            .generation => {},
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        self.pending_controls.append(self.allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
            self.direct_input.items.len,
            command,
        ) orelse return self.failControlAdmission()) catch return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    const max_direct_input_bytes: usize = 64 * 1024;
    const max_pending_controls: usize = 64;

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
        if (self.generation.attachment == .generation) {
            return self.generation.attachment.generation.sendControlNonBlocking(raw.control) catch |err|
                return normalizeGenerationControlError(err);
        }
        return switch (control.control) {
            .scroll_to_bottom => self.legacyConnection().sendScrollToBottomNonBlocking(self.generation.attachment.streamId()) catch |err| switch (err) {
                error.OutOfMemory => false,
                else => return err,
            },
            .core_command => |raw_command| blk: {
                const command = runtime_pending_control.toCoreCommand(raw_command);
                const params = core_command_wire.encodeParams(self.allocator, self.generation.attachment.streamId(), command) catch break :blk false;
                defer self.allocator.free(params);
                break :blk self.legacyConnection().sendCoreCommandNonBlocking(self.generation.attachment.streamId(), params) catch |err| switch (err) {
                    error.OutOfMemory => false,
                    else => return err,
                };
            },
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

    fn retireInputBatchRecords(self: *RemoteRuntime) void {
        var retired: usize = 0;
        while (retired < self.input_batches.records.items.len and
            self.input_batches.records.items[retired].end_offset <= self.direct_input_offset) : (retired += 1)
        {}
        if (retired == 0) return;
        const remaining = self.input_batches.records.items[retired..];
        std.mem.copyForwards(input_owner_mod.BatchRecord, self.input_batches.records.items[0..remaining.len], remaining);
        self.input_batches.records.items.len = remaining.len;
    }

    /// 직접 key FIFO와 control FIFO를 단일 시간 순서로 Client outbound에 넘긴다.
    /// 반환 false는 socket backpressure로 아직 queue/barrier가 남았다는 뜻이며 데이터 소유권은 유지된다.
    fn pumpQueuedInput(self: *RemoteRuntime) client_mod.ClientError!bool {
        // Blocking drain이 front item의 copied value를 들고 있는 동안 callback이 public queue API를
        // 재진입해 같은 item을 소비하지 못하게 한다. false는 기존 backpressure와 같은 retained-owner 결과다.
        if (self.blocking_flush_active) return false;
        if (!self.generation.attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return true;
        }
        if (self.legacyConnectionOrNull()) |client|
            if (self.generation.attachment.hasBufferedControllerRevoke(client)) return false;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = std.math.cast(usize, control.barrier) orelse return error.ProtocolError;
                if (self.direct_input_offset < barrier) {
                    const accepted = switch (self.generation.connection) {
                        .legacy => |client| self.generation.attachment.sendInputNonBlocking(
                            client,
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ),
                        .generation => self.generation.attachment.generation.sendInputNonBlocking(
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ) catch |err| return mapGenerationInputError(err),
                    } catch |err| switch (err) {
                        error.OutOfMemory, error.AdminBusy => return false,
                        else => return err,
                    };
                    if (accepted == 0) return false;
                    self.direct_input_offset += accepted;
                    self.retireInputBatchRecords();
                    continue;
                }
                if (!(try self.admitControl(control))) return false;
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                const accepted = switch (self.generation.connection) {
                    .legacy => |client| self.generation.attachment.sendInputNonBlocking(
                        client,
                        self.direct_input.items[self.direct_input_offset..],
                    ),
                    .generation => self.generation.attachment.generation.sendInputNonBlocking(
                        self.direct_input.items[self.direct_input_offset..],
                    ) catch |err| return mapGenerationInputError(err),
                } catch |err| switch (err) {
                    error.OutOfMemory, error.AdminBusy => return false,
                    else => return err,
                };
                if (accepted == 0) return false;
                self.direct_input_offset += accepted;
                self.retireInputBatchRecords();
                continue;
            }
            self.retireInputBatchRecords();
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return true;
        }
    }

    /// 이 runtime이 이미 소유한 key/control barrier를 blocking RPC보다 먼저 전송한다. RemoteRuntime의 FIFO와
    /// Client의 connection-level pending frame이라는 두 ownership 층 사이에서 mouse/core/resize RPC가 key를
    /// 추월하지 않게 하는 단일 경계다. 각 blocking RPC는 원래도 Client.call에서 pending socket write를 기다린다.
    fn flushQueuedInputBlocking(self: *RemoteRuntime) client_mod.ClientError!void {
        if (self.blocking_flush_active) return error.AdminBusy;
        self.blocking_flush_active = true;
        defer self.blocking_flush_active = false;
        if (!self.generation.attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return;
        }
        if (self.legacyConnectionOrNull()) |client|
            if (self.generation.attachment.hasBufferedControllerRevoke(client)) return error.AdminBusy;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = std.math.cast(usize, control.barrier) orelse return error.ProtocolError;
                if (self.direct_input_offset < barrier) {
                    switch (self.generation.connection) {
                        .legacy => |client| try self.generation.attachment.sendInput(
                            client,
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ),
                        .generation => self.generation.attachment.generation.sendInput(
                            self.direct_input.items[self.direct_input_offset..barrier],
                        ) catch |err| return mapGenerationInputError(err),
                    }
                    self.direct_input_offset = barrier;
                    self.retireInputBatchRecords();
                    continue;
                }
                try self.flushControlBlocking(control);
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                switch (self.generation.connection) {
                    .legacy => |client| try self.generation.attachment.sendInput(
                        client,
                        self.direct_input.items[self.direct_input_offset..],
                    ),
                    .generation => self.generation.attachment.generation.sendInput(
                        self.direct_input.items[self.direct_input_offset..],
                    ) catch |err| return mapGenerationInputError(err),
                }
                self.direct_input_offset = self.direct_input.items.len;
                self.retireInputBatchRecords();
                continue;
            }
            self.retireInputBatchRecords();
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return;
        }
    }

    fn flushControlBlocking(self: *RemoteRuntime, raw: runtime_pending_control.RawQueuedRuntimeControl) client_mod.ClientError!void {
        const control = runtime_pending_control.decode(&raw) orelse return error.ProtocolError;
        if (self.generation.attachment == .generation) {
            self.generation.attachment.generation.sendControl(raw.control) catch |err|
                return normalizeGenerationBlockingControlError(err);
            return;
        }
        switch (control.control) {
            .scroll_to_bottom => try self.legacyConnection().sendScrollToBottom(self.generation.attachment.streamId()),
            .core_command => |raw_command| {
                const command = runtime_pending_control.toCoreCommand(raw_command);
                const params = core_command_wire.encodeParams(self.allocator, self.generation.attachment.streamId(), command) catch
                    return error.OutOfMemory;
                defer self.allocator.free(params);
                try self.legacyConnection().sendCoreCommand(self.generation.attachment.streamId(), params);
            },
        }
    }

    fn callOrdered(self: *RemoteRuntime, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        try self.flushQueuedInputBlocking();
        return self.generation.attachment.callOrdered(self.legacyConnectionOrNull(), method, params_json);
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
        switch (self.generation.connection) {
            .legacy => |client| try client.ingestReadableOutOfBandEvidence(),
            .generation => |adapter| try adapter.ingestRuntimeReadableEvidence(),
        }
        switch (RuntimeAttachment.preDecodeBufferedEvents(&self.generation.attachment)) {
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
        const poison_request: ?client_slot_mod.PreparedExecutionPoisonCaptureRequest = switch (self.generation.connection) {
            .legacy => null,
            .generation => blk: {
                const receipt = app_process_incident_owner.publicationTimestampReceipt() catch |err| {
                    if (builtin.is_test and err == error.InvalidOwner) break :blk null;
                    return error.ProtocolError;
                };
                timestamp_receipt = receipt;
                break :blk .{
                    .timestamp_ns = receipt.timestamp_ns,
                    .controller_generation = self.generation.attachment.statePtr().controller_generation,
                    .source_site_raw = @intFromEnum(connection_incident.SourceSite.client_response),
                    .allocator_source_site_raw = @intFromEnum(connection_incident.SourceSite.client_cleanup),
                    .capture_addr = @intFromPtr(&poison_capture),
                    .prepared_addr = @intFromPtr(&prepared_poison),
                };
            },
        };
        const disposition = self.generation.attachment.callDecoded(
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
        if (!self.generation.resize_baseline_present or generation > self.generation.resize_generation) {
            self.generation.resize_generation = generation;
            self.generation.observation.size = size;
            self.generation.resize_baseline_present = true;
            return true;
        }
        if (generation == self.generation.resize_generation and
            !std.meta.eql(size, self.generation.observation.size))
        {
            self.poisonConnection(.peer_contract_violation);
            return error.ProtocolError;
        }
        return false;
    }

    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) ResizeError!void {
        try self.admitRuntimeOperation();
        // Observer viewport follows the controller's canonical runtime size; local window changes
        // are acknowledged as a no-op instead of becoming an infinite GUI retry.
        if (!self.mutationAllowed()) return;
        if (self.generation.resize_seq == resize_wire.max_counter)
            return error.SequenceExhausted;
        self.generation.resize_seq += 1;
        var buf: [96]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buf, .{ .resize = .{
            .stream_id = self.generation.attachment.streamId(),
            .cols = cols,
            .rows = rows,
            .client_sequence = self.generation.resize_seq,
        } }) catch |err| return switch (err) {
            error.InvalidRequest => error.ResizeRejected,
            error.BufferTooSmall => error.OutOfMemory,
        };
        var context: ResizeDecodeContext = .{
            .runtime = self,
            .client_sequence = self.generation.resize_seq,
        };
        try self.flushQueuedInputBlocking();
        const disposition = self.executeDecodedWithManagedPoison(
            generation_contract.RuntimeRequest.resize(.{
                .cols = cols,
                .rows = rows,
                .client_sequence = self.generation.resize_seq,
            }),
            encoded.method,
            encoded.params,
            &context,
            decodeResizeCallback,
        ) catch |err| return err;
        if (context.decode_error) |err| return err;
        if (disposition != .reusable) return error.ProtocolError;
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
        const generation = switch (self.generation.attachment) {
            .legacy => return error.ProtocolError,
            .generation => |*value| value,
        };
        const adapter = self.generationConnection() orelse return error.ProtocolError;
        if (capture.batch_adapter_addr != @intFromPtr(&generation.batch_adapter) or
            capture.slot_addr != @intFromPtr(&adapter.slot) or
            capture.controller_generation != self.generation.attachment.statePtr().controller_generation or
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
        try self.admitRuntimeOperation();
        switch (self.generation.attachment) {
            .legacy => return self.pumpDeltaInner(),
            .generation => {},
        }
        const timestamp = app_process_incident_owner.publicationTimestampReceipt() catch |err| {
            if (builtin.is_test and err == error.InvalidOwner) return self.pumpDeltaInner();
            return error.ProtocolError;
        };
        var capture: incident_publication_contract.ReadPumpPoisonCapture = .{};
        const generation = switch (self.generation.attachment) {
            .legacy => unreachable,
            .generation => |*value| value,
        };
        generation.armReadPumpPoisonCapture(
            &capture,
            timestamp.timestamp_ns,
            self.generation.attachment.statePtr().controller_generation,
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
        // 마지막 non-blocking input 뒤에 새 입력/RPC가 영원히 없더라도 frame-loop pump가 연결의 bounded pending frame을
        // 계속 DONTWAIT로 진전시킨다. Client 하나를 여러 runtime이 공유하므로 어느 runtime pump가 호출해도 충분하다.
        if (!(try self.pumpQueuedInput()))
            return if (events.metadata) .metadata else .idle;
        _ = try self.generation.attachment.pumpPendingOutput(self.legacyConnectionOrNull());
        try self.pumpResyncIntent();
        switch (try self.generation.attachment.pumpScreen(self.io)) {
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
            .recovery_commit_pending, .terminal => return error.ProtocolError,
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
        return switch (self.generation.attachment) {
            .legacy => self.drainLegacyObservationEvents(),
            .generation => self.drainGenerationObservationEvents(),
        };
    }

    fn drainLegacyObservationEvents(self: *RemoteRuntime) client_mod.ClientError!EventDrain {
        var result: EventDrain = .{};
        while (try self.legacyConnection().takeEventForStream(self.generation.attachment.streamId())) |frame| {
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
        if (result.ended) self.legacyConnection().dropBufferedStream(self.generation.attachment.streamId());
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
            .controller_generation = self.generation.attachment.statePtr().controller_generation,
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
            const generation = &self.generation.attachment.generation;
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
        if (hook) |run| if (run(self, stage) == .busy) return error.AdminBusy;
        remote_runtime_pending_event_mod.settlePreparedEvent(
            &self.runtime_lifetime,
            &self.pending_event_owner,
            &self.generation.attachment.generation,
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
                &self.generation.observation,
                &moved_observation,
            );
        }

        if (publish) switch (tag) {
            .ignored, .resize_noop, .metadata_noop, .metadata_commit => {
                result.metadata = result.metadata or tag == .metadata_commit;
            },
            .ended => result.ended = true,
            .invalidated => self.generation.resync_needed = true,
            .resize_commit => {
                self.generation.observation.size = .{ .cols = decision.cols, .rows = decision.rows };
                self.generation.resize_generation = decision.resize_generation;
                self.generation.resize_baseline_present = true;
                result.metadata = true;
            },
            .revoked => {
                self.generation.attachment.applyPreparedRevokedNoFail(decision.revoke_fence);
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
                self.generation.observation.revision +%= 1;
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
            &self.generation.observation,
            self.allocator,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
        const observation_digest = runtime_observation_digest_mod.digest(
            &self.generation.observation,
            graph,
        ) catch process_seal_service.fatalIntegrity(.proof_loss);
        const attachment_state = self.generation.attachment.statePtr();
        return runtime_observation_digest_mod.semanticPostDigest(.{
            .observation_digest = observation_digest,
            .resync_needed = self.generation.resync_needed,
            .resize_generation = self.generation.resize_generation,
            .resize_baseline_present = self.generation.resize_baseline_present,
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
        const prepared = self.generation.attachment.generation.preparedSettlementIdentity() catch
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
        const classification = runtime_metadata_wire.classifyAndMaterializeEvent(
            self.allocator,
            .{
                .runtime_id = self.generation.attachment.statePtr().runtime_id,
                .stream_id = self.generation.attachment.statePtr().stream_id,
            },
            .{
                .role = switch (self.generation.attachment.statePtr().role) {
                    .observer => .observer,
                    .controller => .controller,
                },
                .generation = switch (self.generation.event_generation_tracking) {
                    .untracked => .untracked,
                    .tracked => .{
                        .tracked = self.generation.attachment.statePtr().controller_generation,
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
                const revoke_fence = self.generation.attachment.applyValidatedRevokedAndFence(
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
                self.generation.resync_needed = true;
            },
            .resized => |resized| {
                const size: terminal.Size = .{ .cols = resized.cols, .rows = resized.rows };
                if (try self.applyResizeFullState(size, resized.resize_generation))
                    result.metadata = true;
            },
            .metadata => |metadata| {
                var dto = metadata;
                defer dto.deinit();
                result.metadata = (self.applyMetadataDto(&dto) catch |err| {
                    self.poisonConnection(.peer_contract_violation);
                    return err;
                }) or result.metadata;
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
        if (!self.generation.resync_needed) return;
        const accepted = self.generation.attachment.sendResyncNonBlocking(self.legacyConnectionOrNull()) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => return err,
        };
        if (accepted) self.generation.resync_needed = false;
    }

    fn applyMetadataDto(
        self: *RemoteRuntime,
        dto: *const runtime_metadata_wire.OwnedMetadataDto,
    ) error{ OutOfMemory, ProtocolError }!bool {
        if (dto.revision < self.generation.observation.revision) return false;
        if (dto.revision == self.generation.observation.revision) {
            // A revision is a semantic version, not merely an ordering hint. Accepting different
            // cwd/SSH data under the same revision would let the synchronous SSH barrier return
            // success while retaining a stale destination.
            if (!metadataDtoMatchesObservation(dto, self.generation.observation.view()))
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
        try self.generation.observation.replace(self.allocator, .{
            .availability = .current,
            .revision = dto.revision,
            .observer_generation = dto.observer_generation,
            .title_generation = dto.title_generation,
            .size = .{ .cols = dto.cols, .rows = dto.rows },
            .cwd = dto.cwd(),
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
            .stream_id = self.generation.attachment.streamId(),
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
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.generation.attachment.streamId()}) catch return error.OutOfMemory;
        var before = self.generation.observation.revision;
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
        if (self.generation.observation.availability != .current or self.generation.observation.revision != revision) {
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
        if (!self.connectionCapabilities().runtime_selected_text) return self.selectedTextFromProjection(span);
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ self.generation.attachment.streamId(), span.start.row, span.start.col, span.end.row, span.end.col, span.block }) catch return error.OutOfMemory;
        var output: ?[]u8 = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.selectedText(.{
                .start_row = span.start.row,
                .start_col = span.start.col,
                .end_row = span.end.row,
                .end_col = span.end.col,
                .block = span.block,
            }),
            "runtime.selected_text",
            params,
            &output,
            applySelectedTextResponse,
        );
        return output;
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
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"row\":{d},\"col\":{d},\"scopes\":{d}}}", .{ self.generation.attachment.streamId(), row, col, scopes }) catch return error.OutOfMemory;
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

    /// OSC 52 write 텍스트를 host에서 가져온다(host는 넘기면 비운다). capability 없는 구 host면 null —
    /// 원격 클립보드 쓰기가 비활성이다(모르는 RPC를 시험하지 않는다). 반환 텍스트는 caller 소유.
    ///
    /// **base64로 받는다**: OSC 52 데이터는 임의 바이트라 JSON 문자열로 그대로 오면 strict 디코더의 UTF-8 검증에
    /// 걸려 connection이 fail-close된다(복사 한 번에 앱 전역 연결이 끊긴다). host가 base64로 싣고 여기서 푼다.
    pub fn clipboardWrite(self: *RemoteRuntime) client_mod.ClientError!?ClipboardWrite {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.connectionCapabilities().runtime_clipboard) return null;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.generation.attachment.streamId()}) catch return error.OutOfMemory;
        var output: ?ClipboardWrite = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.clipboardWrite(),
            "runtime.clipboard_write",
            params,
            &output,
            applyClipboardWriteResponse,
        );
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
        return self.generation.attachment.screenPtr().?.extractVisibleSelection(self.allocator, self.io, span);
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
        out_spans.clearRetainingCapacity();
        var hexbuf: [512]u8 = undefined;
        const qn = @min(query.len, hexbuf.len / 2);
        const hex_chars = "0123456789abcdef";
        for (query[0..qn], 0..) |b, i| {
            hexbuf[i * 2] = hex_chars[b >> 4];
            hexbuf[i * 2 + 1] = hex_chars[b & 0xf];
        }
        var buf: [640]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"q\":\"{s}\",\"cur\":{d},\"scroll\":{}}}", .{ self.generation.attachment.streamId(), hexbuf[0 .. qn * 2], cur_index, scroll }) catch return error.OutOfMemory;
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
    pub fn selectContentAware(self: *RemoteRuntime, op: []const u8, row: u16, col: u16) client_mod.ClientError!?terminal.SelectionSpan {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"op\":\"{s}\",\"row\":{d},\"col\":{d}}}", .{ self.generation.attachment.streamId(), op, row, col }) catch return error.OutOfMemory;
        const kind: generation_contract.SelectKind = if (std.mem.eql(u8, op, "word"))
            .word
        else if (std.mem.eql(u8, op, "line"))
            .line
        else
            return error.ProtocolError;
        var output: ?terminal.SelectionSpan = null;
        try self.callDecoded(
            generation_contract.RuntimeRequest.selectOp(.{ .kind = kind, .row = row, .col = col }),
            "runtime.select_op",
            params,
            &output,
            applySelectResponse,
        );
        return output;
    }

    fn applySelectResponse(_: *RemoteRuntime, raw_output: *anyopaque, bytes: []const u8) client_mod.ClientError!void {
        const output: *?terminal.SelectionSpan = @ptrCast(@alignCast(raw_output));
        if (std.mem.indexOf(u8, bytes, "\"sel\":true") == null) return;
        const sr = client_mod.extractU64Field(bytes, "\"sr\":") orelse return;
        const sc = client_mod.extractU64Field(bytes, "\"sc\":") orelse return;
        const er = client_mod.extractU64Field(bytes, "\"er\":") orelse return;
        const ec = client_mod.extractU64Field(bytes, "\"ec\":") orelse return;
        output.* = .{
            .start = .{ .row = @intCast(sr), .col = @intCast(sc) },
            .end = .{ .row = @intCast(er), .col = @intCast(ec) },
            .block = std.mem.indexOf(u8, bytes, "\"block\":true") != null,
        };
    }

    /// host-authoritative core command를 strict bounded codec으로 보낸다. 구 host는 scroll 4종만 이해하므로 capability가
    /// 없는 연결에는 그 legacy subset만 보내고 focus/config/prompt는 unknown RPC를 시험하지 않고 degraded no-op으로 둔다.
    pub fn sendCoreCommandBlocking(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        try self.admitRuntimeOperation();
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!shouldSendCoreCommand(self.connectionCapabilities().runtime_core_command, command)) return;
        const params = core_command_wire.encodeParams(self.allocator, self.generation.attachment.streamId(), command) catch return error.OutOfMemory;
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
        var buf: [192]u8 = undefined;
        const params = std.fmt.bufPrint(
            &buf,
            "{{\"stream_id\":{d},\"button\":{d},\"col\":{d},\"row\":{d},\"x_px\":{d},\"y_px\":{d},\"pressed\":{},\"motion\":{},\"mods\":{d}}}",
            .{ self.generation.attachment.streamId(), m.button, m.col, m.row, m.x_px, m.y_px, m.pressed, m.motion, m.mods },
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

    /// host에 대기 중인 OSC 9/777 데스크톱 알림을 뺀다(§6.32 — host가 core와 함께 알림을 소유·전달). 없으면 null. host-backed
    /// 터미널의 알림은 host의 `TerminalCore`가 파싱하므로 client가 이걸로 가져와 GUI 알림 funnel에 넣는다(app_session이 surfacing).
    /// 반환 title/body는 caller 소유(Notification.deinit로 회수). 둘 다 빈 값이면(host 대기 없음) null.
    pub fn takeNotification(self: *RemoteRuntime) client_mod.ClientError!?Notification {
        try self.admitRuntimeOperation();
        // Capability 없는 same-major 구 host는 runtime_id-only RPC를 exact subscription으로
        // authorize하지 못한다. Observer가 shared pending event를 소비하지 않도록 fail-closed한다.
        if (!self.connectionCapabilities().notification_stream_auth) return null;
        var buf: [96]u8 = undefined;
        const params = notificationParams(
            &buf,
            self.generation.attachment.streamId(),
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
    ) error{NoSpaceLeft}![]u8 {
        return std.fmt.bufPrint(
            buf,
            "{{\"stream_id\":{d}}}",
            .{stream_id},
        );
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

    /// strict RPC 응답 객체 하나. 값은 string(escape 해제)과 정수만 담는다 — 현재 응답 schema가 그 둘만 쓴다.
    /// 배열 값을 쓰는 응답(`runtime.find`의 span 목록)은 아직 전용 스캐너를 쓴다(§한계 — 확장하려면 여기 Value에 더한다).
    const StrictObject = struct {
        fields: []Field,
        allocator: std.mem.Allocator,

        const Value = union(enum) { string: []u8, number: u64 };
        const Field = struct { key: []u8, value: Value };

        fn deinit(self: StrictObject) void {
            for (self.fields) |f| {
                self.allocator.free(f.key);
                switch (f.value) {
                    .string => |v| self.allocator.free(v),
                    .number => {},
                }
            }
            self.allocator.free(self.fields);
        }

        /// 키의 문자열 값(없거나 정수면 null). 소유권은 객체에 남는다 — caller가 쓰려면 dupe한다.
        fn string(self: StrictObject, key: []const u8) ?[]const u8 {
            for (self.fields) |f| {
                if (std.mem.eql(u8, f.key, key)) return switch (f.value) {
                    .string => |v| v,
                    .number => null,
                };
            }
            return null;
        }

        /// 키의 정수 값(없거나 문자열이면 null).
        fn number(self: StrictObject, key: []const u8) ?u64 {
            for (self.fields) |f| {
                if (std.mem.eql(u8, f.key, key)) return switch (f.value) {
                    .number => |v| v,
                    .string => null,
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
                    .number => {},
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
            else
                .{ .number = try decodeStrictJsonNumberAt(json, &i) };
            fields.append(allocator, .{ .key = key, .value = value }) catch {
                switch (value) {
                    .string => |v| allocator.free(v),
                    .number => {},
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
        if (self.generation.attachment.streamId() == 0) return;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.generation.attachment.streamId()}) catch return;
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

fn shouldSendCoreCommand(runtime_core_command_v1: bool, command: core_command_wire.Command) bool {
    return runtime_core_command_v1 or command.isLegacyScroll();
}

pub const testing_api = if (builtin.is_test) struct {
    pub const SemanticFixture = B4SemanticFixture;

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
        const attachment = switch (runtime.generation.attachment) {
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

    pub fn initializeLegacyConnection(runtime: *RemoteRuntime, client: *client_mod.Client) void {
        runtime.generation.connection = .{ .legacy = client };
    }

    pub fn generationAdapter(runtime: *RemoteRuntime) ?*host_adapter_mod.HostAdapter {
        return runtime.generationConnection();
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
        try host_adapter_mod.HostAdapter.testing.rawClient(adapter).bufferGenerationEventForTest(runtime.generation.attachment.streamId(), payload);
        switch (try runtime.generation.attachment.generation.takeEvent()) {
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
    runtime.generation.connection = .{ .legacy = &legacy_client };
    try testing.expect(runtime.generationConnection() == null);
    try testing.expect(runtime.legacyConnectionOrNull().? == &legacy_client);

    runtime.generation.connection = .{ .generation = &adapter };
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
    runtime.generation.connection = .{ .generation = &adapter };

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
    runtime.generation.connection = .{ .legacy = &client };
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
    runtime.generation.event_generation_tracking = .tracked;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.generation.resize_generation = 0;
    runtime.generation.resize_baseline_present = false;
    runtime.generation.observation = .{};
    defer runtime.generation.observation.deinit(allocator);
    try std.testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try std.testing.expect(client.unusable);
    try std.testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
}

test "remote runtime: extended core commands require capability while legacy scroll remains compatible" {
    try std.testing.expect(shouldSendCoreCommand(false, .{ .scroll = 1 }));
    try std.testing.expect(!shouldSendCoreCommand(false, .{ .report_focus = true }));
    try std.testing.expect(!shouldSendCoreCommand(false, .{ .set_max_scrollback = 1000 }));
    try std.testing.expect(shouldSendCoreCommand(true, .{ .report_focus = false }));
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
        .reset_input_modes,
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
        .reset_input_modes,
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
    rr.generation.connection = .{ .legacy = &client };
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
        .zdotdir = request.zdotdir,
        .ssh_integration_bin = request.ssh_integration_bin,
        .pane_id = pane_id,
        .cols = size.cols,
        .rows = size.rows,
        .runtime_config = if (initial_config) |config| coreConfigToSpawnWire(config) else null,
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
        .zdotdir = "/tmp/maru-zdotdir",
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
    });
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.generation.attachment.deinit();
    rr.generation.observation = .{};
    defer rr.generation.observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.generation.observation, allocator);
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
    try std.testing.expectEqual(@as(u64, 2), rr.generation.observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.generation.observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.generation.observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.generation.observation.ssh_remote_dest.items);
    try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.generation.observation.semantic_state);
    try std.testing.expect(rr.generation.observation.alt_active);
    try std.testing.expect(rr.generation.observation.app_cursor_keys);
    try std.testing.expectEqual(@as(u16, 120), rr.generation.observation.size.cols);
    try std.testing.expectEqual(@as(u16, 40), rr.generation.observation.size.rows);
    try std.testing.expectEqual(@as(?i32, 55), rr.generation.observation.foreground_pgid);
    try std.testing.expectEqual(@as(usize, 1), rr.generation.observation.foreground_processes.items.len);
    try std.testing.expectEqualStrings(
        "claude",
        rr.generation.observation.foreground_processes.items[0].slice(),
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.generation.observation.deinit(allocator);

    const result = rr.attachAndAssemble(1, .{ .cols = 80, .rows = 24 });
    switch (selected) {
        .typed_reject => try std.testing.expectError(error.RuntimeNotFound, result),
        .response_eof => try std.testing.expectError(error.AttachFailed, result),
    }
    peer.join();
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.generation.attachment.generation.batch_adapter.slot_addr);
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.generation.observation.deinit(allocator);
    try rr.generation.observation.replace(allocator, .{
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
    try std.testing.expectEqual(@as(u64, 2), rr.generation.observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.generation.observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.generation.observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.generation.observation.ssh_remote_dest.items);
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), rr.generation.attachment.generation.batch_adapter.slot_addr);
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.generation.observation.deinit(allocator);

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
    try std.testing.expectEqual(@as(usize, 0), rr.generation.attachment.generation.batch_adapter.slot_addr);
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
            self.outcome = switch (self.runtime.generation.attachment) {
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.generation.observation.deinit(allocator);

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
            rr.deinitScreenSource();
            rr.generation.attachment.deinitWithConnection(rr.generation.connection);
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
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        1,
        .{ .report_focus = true },
    ).?);
    try rr.flushQueuedInputBlocking();
    try std.testing.expectEqual(@as(usize, 0), rr.direct_input.items.len);
    try std.testing.expectEqual(@as(usize, 0), rr.pending_controls.items.len);
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(0).?);
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
    while (!(try rr.generation.attachment.pumpPendingOutput(host_adapter_mod.HostAdapter.testing.rawClient(&adapter)))) {}
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
    try std.testing.expectEqual(@as(u21, 'x'), rr.generation.attachment.screenPtr().?.grid.cells[0].codepoint);
    rr.surface.deinit();
    rr.deinitScreenSource();
    rr.generation.attachment.deinitWithConnection(rr.generation.connection);
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.generation.observation.deinit(allocator);
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
    try std.testing.expectEqual(remote_attachment.Role.observer, rr.generation.attachment.statePtr().role);
    try std.testing.expectError(error.Unauthorized, rr.sendInputNonBlocking("late"));
    rr.surface.deinit();
    rr.deinitScreenSource();
    rr.generation.attachment.deinitWithConnection(rr.generation.connection);
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    defer rr.generation.observation.deinit(allocator);
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
                    runtime.generation.attachment.streamId(),
                    "{\"event\":\"runtime.ended\"}",
                ) catch @panic("C3-2 race hook failed to publish ended event");
                ended_pending_count += 1;
            }
            if (stage == .before_purge and exhaust_retry_budget and ended_pending_count != 0) {
                runtime.testingClient().dropBufferedStream(runtime.generation.attachment.streamId());
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
    try std.testing.expect(rr.generation.attachment.generation.event_generation_mirror != 0);
    const after_release_retry = try rr.drainObservationEvents();
    try std.testing.expect(!after_release_retry.ended);
    try std.testing.expect(after_release_retry.metadata);
    try std.testing.expectEqual(@as(u64, 0), rr.generation.attachment.generation.event_generation_mirror);

    Hook.force_release_busy = true;
    try rr.testingClient().bufferGenerationEventForTest(7, "{\"event\":\"snapshot.invalidated\"}");
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    try std.testing.expect(rr.generation.attachment.generation.event_generation_mirror != 0);
    const invalidated = try rr.drainObservationEvents();
    try std.testing.expect(!invalidated.ended);
    try std.testing.expect(rr.generation.resync_needed);
    try std.testing.expectEqual(@as(u64, 0), rr.generation.attachment.generation.event_generation_mirror);

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
    try std.testing.expectEqual(@as(u21, 'x'), rr.generation.attachment.screenPtr().?.grid.cells[0].codepoint);
    Hook.exhaust_retry_budget = false;
    Hook.inject_ended_after_purge = false;
    try std.testing.expect((try rr.drainObservationEvents()).ended);
    rr.direct_input.clearRetainingCapacity();

    try rr.testingClient().bufferGenerationEventForTest(8, "{\"event\":\"runtime.ended\"}");
    try rr.testingClient().pending_batches.append(allocator, .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "stale-target"),
        .allocator = allocator,
    });
    try rr.testingClient().pending_batches.append(allocator, .{
        .stream_id = 8,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "sibling"),
        .allocator = allocator,
    });
    rr.testingClient().pending_batch_bytes = "stale-target".len + "sibling".len;

    Hook.inject_ended_after_purge = true;
    try std.testing.expectError(
        error.AdminBusy,
        rr.drainGenerationObservationEventsWithHook(Hook.run),
    );
    const ended = try rr.drainGenerationObservationEventsWithHook(Hook.run);
    try std.testing.expect(ended.ended);
    try std.testing.expectEqual(@as(usize, 1), rr.testingClient().pending_events.items.len);
    try std.testing.expectEqual(@as(u64, 8), rr.testingClient().pending_events.items[0].header.stream_id);
    try std.testing.expectEqual(@as(usize, 1), rr.testingClient().pending_batches.items.len);
    try std.testing.expectEqual(@as(u64, 8), rr.testingClient().pending_batches.items[0].stream_id);
    try std.testing.expectEqualStrings("sibling", rr.testingClient().pending_batches.items[0].bytes);
    try std.testing.expectEqual(@as(u21, 'x'), rr.generation.attachment.screenPtr().?.grid.cells[0].codepoint);
    try std.testing.expectEqual(@as(u64, 0), rr.generation.attachment.generation.event_generation_mirror);

    try rr.direct_input.appendSlice(allocator, "must-not-send");
    try rr.testingClient().bufferGenerationEventForTest(7, "{\"event\":\"runtime.ended\"}");
    try rr.testingClient().pending_batches.append(allocator, .{
        .stream_id = 7,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "second-stale-target"),
        .allocator = allocator,
    });
    rr.testingClient().pending_batch_bytes += "second-stale-target".len;
    try std.testing.expectEqual(RemoteRuntime.PumpResult.ended, try rr.pumpDelta());
    try std.testing.expectEqualStrings("must-not-send", rr.direct_input.items);
    try std.testing.expect(rr.generation.resync_needed);
    try std.testing.expectEqual(@as(u21, 'x'), rr.generation.attachment.screenPtr().?.grid.cells[0].codepoint);

    rr.surface.deinit();
    rr.deinitScreenSource();
    rr.generation.attachment.deinitWithConnection(rr.generation.connection);
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
        self.runtime.generation.connection = .{ .generation = &self.adapter };
        self.runtime.pending_event_owner = .{};
        self.runtime.runtime_lifetime = .{};
        try self.runtime.initializePendingEventOwner();
        self.runtime.allocator = allocator;
        self.runtime.io = std.testing.io;
        self.runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
        self.runtime.generation.resize_seq = 0;
        self.runtime.generation.resize_generation = 0;
        self.runtime.generation.resize_baseline_present = false;
        self.runtime.direct_input = .empty;
        self.runtime.input_batches = .{};
        self.runtime.direct_input_offset = 0;
        self.runtime.pending_controls = .empty;
        self.runtime.blocking_flush_active = false;
        self.runtime.generation.pump_ended = false;
        self.runtime.generation.resync_needed = false;
        self.runtime.generation.observation = .{};
        self.runtime.close_authority = .{};
        self.runtime.shutdown_attempt_authority = .{};
        self.runtime.shutdown_current_admin = .{};
        try self.runtime.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
        peer.join();
    }

    pub fn deinit(self: *@This()) void {
        self.runtime.surface.deinit();
        self.runtime.deinitScreenSource();
        self.runtime.direct_input.deinit(self.allocator);
        self.runtime.pending_controls.deinit(self.allocator);
        self.runtime.generation.observation.deinit(self.allocator);
        self.runtime.generation.attachment.deinitWithConnection(self.runtime.generation.connection);
        self.adapter.deinit();
    }

    pub fn publish(self: *@This(), payload: []const u8) !RemoteRuntime.EventDrain {
        try self.runtime.testingClient().bufferGenerationEventForTest(7, payload);
        return self.runtime.drainObservationEvents();
    }

    pub fn prepareForClose(self: *@This(), payload: []const u8) !void {
        try self.runtime.testingClient().bufferGenerationEventForTest(7, payload);
        switch (try self.runtime.generation.attachment.generation.takeEvent()) {
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
            allocator_probe.target_addr = @intFromPtr(fixture.runtime.generation.observation.cwd.items.ptr);
            allocator_probe.target_len = fixture.runtime.generation.observation.cwd.items.len;
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
        &fixture.runtime.generation.observation,
        try runtime_observation_digest_mod.cleanupGraph(&fixture.runtime.generation.observation, fixture.allocator),
    );
    const result = try fixture.publish(b4_metadata_stale);
    const after = try runtime_observation_digest_mod.digest(
        &fixture.runtime.generation.observation,
        try runtime_observation_digest_mod.cleanupGraph(&fixture.runtime.generation.observation, fixture.allocator),
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
    try std.testing.expect(!result.ended and fixture.runtime.generation.resync_needed);
}

test "C3-3b4 실제 Runtime event resize_noop은 기존 크기를 보존한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    fixture.runtime.generation.resize_generation = 10;
    fixture.runtime.generation.resize_baseline_present = true;
    fixture.runtime.generation.observation.size = .{ .cols = 90, .rows = 30 };
    const result = try fixture.publish(
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}",
    );
    try std.testing.expect(!result.metadata);
    try std.testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.generation.observation.size);
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
    try std.testing.expectEqual(@as(u64, 10), fixture.runtime.generation.resize_generation);
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 40 }, fixture.runtime.generation.observation.size);
}

test "C3-3b4 실제 Runtime event metadata_noop은 기존 observation을 보존한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    _ = try fixture.publish(b4_metadata_base);
    const before = fixture.runtime.generation.observation.revision;
    const result = try fixture.publish(b4_metadata_base);
    try std.testing.expect(!result.metadata);
    try std.testing.expectEqual(before, fixture.runtime.generation.observation.revision);
    try std.testing.expectEqualStrings("/base", fixture.runtime.generation.observation.cwd.items);
}

test "C3-3b4 실제 Runtime event metadata_commit은 새 observation을 원자 게시한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    const result = try fixture.publish(b4_metadata_base);
    try std.testing.expect(result.metadata);
    try std.testing.expectEqual(@as(u64, 4), fixture.runtime.generation.observation.revision);
    try std.testing.expectEqualStrings("/base", fixture.runtime.generation.observation.cwd.items);
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
    try std.testing.expectEqual(remote_attachment.Role.observer, fixture.runtime.generation.attachment.statePtr().role);
    try std.testing.expectEqual(@as(u64, 4), fixture.runtime.generation.attachment.statePtr().controller_generation);
}

test "C3-3b4 실제 Runtime event failure는 confirmed effect 뒤 prepared 의미를 억제한다" {
    var fixture: B4SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    fixture.runtime.generation.resize_generation = 10;
    fixture.runtime.generation.resize_baseline_present = true;
    fixture.runtime.generation.observation.size = .{ .cols = 90, .rows = 30 };
    try std.testing.expectError(error.ProtocolError, fixture.publish(
        "{\"event\":\"runtime.resized\",\"data\":{" ++
            "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
            "\"cols\":120,\"rows\":40,\"resize_generation\":10,\"reason\":\"controller\"}}",
    ));
    try std.testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.generation.observation.size);
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
                runtime.generation.attachment.streamId(),
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
    try std.testing.expect(fixture.runtime.generation.attachment.generation.event_generation_mirror != 0);
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
    try std.testing.expect(fixture.runtime.generation.resync_needed);
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
    try std.testing.expectEqual(@as(u64, 0), fixture.runtime.generation.attachment.generation.event_generation_mirror);
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
    rr.generation.connection = .{ .generation = &adapter };
    rr.generation.connection = .{ .generation = &adapter };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.generation.resize_seq = 0;
    rr.generation.resize_generation = 0;
    rr.generation.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    rr.generation.observation = .{};
    defer rr.generation.observation.deinit(allocator);

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
    try std.testing.expectEqual(@as(usize, 0), rr.generation.attachment.generation.batch_adapter.slot_addr);
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
        rr.generation.connection = .{ .legacy = &client };
        rr.pending_event_owner = .{};
        rr.runtime_lifetime = .{};
        try rr.initializePendingEventOwner();
        rr.generation.attachment = .init(allocator, .{
            .runtime_id = 0xaa,
            .stream_id = 7,
            .role = .controller,
            .controller_generation = 1,
        });
        defer rr.generation.attachment.deinit();
        rr.generation.observation = .{};
        try rr.generation.observation.replace(allocator, .{
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
        defer rr.generation.observation.deinit(rr.allocator);
        const drained = rr.drainObservationEvents();
        if (drained) |result| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expect(result.metadata);
            try std.testing.expectEqual(@as(u64, 3), rr.generation.observation.revision);
            try std.testing.expectEqualStrings("/next/repo", rr.generation.observation.cwd.items);
            try std.testing.expect(!client.unusable);
            try std.testing.expect(!failing.has_induced_failure);
            saw_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(u64, 2), rr.generation.observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.generation.observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.generation.observation.window_title.items);
            try std.testing.expectEqualStrings(
                "safe-host",
                rr.generation.observation.ssh_remote_dest.items,
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.generation.attachment.deinit();
    rr.direct_input = .empty;
    rr.input_batches = .{};
    defer rr.direct_input.deinit(allocator);
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.pending_controls.deinit(allocator);
    rr.generation.observation = .{};
    defer rr.generation.observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.generation.observation, allocator);

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
            try std.testing.expectEqual(term_backend.ObservationAvailability.current, rr.generation.observation.availability);
            try std.testing.expectEqual(@as(u64, 3), rr.generation.observation.revision);
            try std.testing.expectEqualStrings("/fresh", rr.generation.observation.cwd.items);
            try std.testing.expectEqualStrings("fresh-title", rr.generation.observation.window_title.items);
            try std.testing.expectEqualStrings("fresh-host", rr.generation.observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.input, rr.generation.observation.semantic_state);
            try std.testing.expect(!rr.generation.observation.alt_active);
            try std.testing.expect(!rr.generation.observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 90), rr.generation.observation.size.cols);
            try std.testing.expectEqual(@as(u16, 30), rr.generation.observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 77), rr.generation.observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.generation.observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "zsh",
                rr.generation.observation.foreground_processes.items[0].slice(),
            );
        },
        .fail_closed => {
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
            try std.testing.expectEqual(@as(u64, 2), rr.generation.observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.generation.observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.generation.observation.window_title.items);
            try std.testing.expectEqualStrings("safe-host", rr.generation.observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.generation.observation.semantic_state);
            try std.testing.expect(rr.generation.observation.alt_active);
            try std.testing.expect(rr.generation.observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 120), rr.generation.observation.size.cols);
            try std.testing.expectEqual(@as(u16, 40), rr.generation.observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 55), rr.generation.observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.generation.observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "claude",
                rr.generation.observation.foreground_processes.items[0].slice(),
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
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const screen_stream = @import("screen_stream.zig");

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
            "{\"stream_id\":9}",
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
        try std.testing.expectEqual(@as(u64, 4), rr.generation.observation.revision);
        try std.testing.expectEqualStrings("/base", rr.generation.observation.cwd.items);
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
                try std.testing.expectEqual(@as(u64, 4), rr.generation.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.generation.observation.cwd.items);
                try std.testing.expect(!client.unusable);
            },
            .newer => {
                const result = try rr.drainObservationEvents();
                try std.testing.expect(result.metadata);
                try std.testing.expectEqual(@as(u64, 5), rr.generation.observation.revision);
                try std.testing.expectEqualStrings("/new", rr.generation.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "new-host",
                    rr.generation.observation.ssh_remote_dest.items,
                );
                try std.testing.expect(!client.unusable);
            },
            .conflict => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.generation.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.generation.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.generation.observation.ssh_remote_dest.items,
                );
            },
            .sealed_revision_mutation, .sealed_header_mutation => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.generation.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.generation.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.generation.observation.ssh_remote_dest.items,
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
        try std.testing.expectEqual(@as(u64, 5), rr.generation.resize_generation);
        try std.testing.expectEqual(
            terminal.Size{ .cols = 100, .rows = 40 },
            rr.generation.observation.size,
        );
        rr.detachClientSide();
    }
}

test "remote runtime observer locally consumes input and sends no resize mutation" {
    var runtime: RemoteRuntime = undefined;
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    });
    runtime.generation.event_generation_tracking = .tracked;
    defer runtime.generation.attachment.deinit();
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
    runtime.generation.connection = .{ .legacy = &client };
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.generation.event_generation_tracking = .tracked;
    defer runtime.generation.attachment.deinit();
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    defer runtime.direct_input.deinit(allocator);
    try runtime.direct_input.appendSlice(allocator, "queued");
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    defer runtime.pending_controls.deinit(allocator);
    try runtime.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(6).?);
    runtime.generation.observation = .{};

    const drained = try runtime.drainObservationEvents();
    try testing.expect(drained.metadata);
    try testing.expectEqual(remote_attachment.Role.observer, runtime.generation.attachment.statePtr().role);
    try testing.expectEqual(@as(u64, 4), runtime.generation.attachment.statePtr().controller_generation);
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
    runtime.generation.connection = .{ .legacy = &client };
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 0,
    });
    defer runtime.generation.attachment.deinit();
    runtime.generation.event_generation_tracking = .untracked;
    runtime.generation.observation = .{};

    try testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try testing.expect(client.unusable);
    try testing.expectEqual(remote_attachment.Role.controller, runtime.generation.attachment.statePtr().role);
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
    runtime.generation.connection = .{ .legacy = &client };
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.allocator = allocator;
    runtime.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.generation.event_generation_tracking = .tracked;
    defer runtime.generation.attachment.deinit();
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    defer runtime.direct_input.deinit(allocator);
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    defer runtime.pending_controls.deinit(allocator);

    // Role cache는 아직 controller지만 own-stream revoke가 먼저 도착했으므로 SurfaceRuntime가
    // InputSuppressed로 바꿀 Unauthorized를 반환하고 queue/wire ownership을 만들지 않는다.
    try testing.expect(runtime.generation.attachment.allowsMutation());
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
    runtime.generation.connection = .{ .generation = adapter };
    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = undefined;
    runtime.generation.attachment = .{ .generation = .{} };
    try generation_attachment_mod.testing_api.initAttached(
        &runtime.generation.attachment.generation,
        adapter,
        testing.allocator,
        0xaa,
        7,
    );
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.resync_needed = false;
    runtime.generation.observation = .{};
    runtime.generation.event_generation_tracking = .tracked;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.generation.resize_generation = 0;
    runtime.generation.resize_baseline_present = false;
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
    runtime.generation.observation.deinit(testing.allocator);
    runtime.direct_input.deinit(testing.allocator);
    runtime.pending_controls.deinit(testing.allocator);
    runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
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
    runtime.generation.pump_ended = false;
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
    try testing.expectEqual(runtime.generation.attachment.statePtr().controller_generation, pre_publication.controller_generation);

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
    runtime.generation.pump_ended = false;
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
    try testing.expectEqual(runtime.generation.attachment.statePtr().controller_generation, pre_publication.controller_generation);
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
    runtime.generation.pump_ended = false;
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
    try testing.expectEqual(runtime.generation.attachment.statePtr().controller_generation, pre_publication.controller_generation);

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
    runtime.generation.pump_ended = false;
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
    try testing.expectEqual(runtime.generation.attachment.statePtr().controller_generation, pre_publication.controller_generation);

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
        .notification => "{\"title\":\"\",\"body\":\"\"}",
        .core_command, .report_mouse, .terminate, .detach => "{}",
        .spawn_full, .attach_controller => unreachable,
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
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var runtime: RemoteRuntime = undefined;
    try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);
    defer deinitGenerationRuntimeAggregateFixture(&runtime, &adapter);
    runtime.generation.resize_seq = 0;
    runtime.generation.pump_ended = false;
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
        .select_op => _ = try runtime.selectContentAware("word", 0, 0),
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
        .terminate => runtime.terminate(),
        .detach => {
            runtime.admitDestructiveRuntimeOperation();
            runtime.detachBestEffort();
        },
        .spawn_full, .attach_controller => unreachable,
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
    runtime.generation.connection = .{ .legacy = &client };

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.generation.connection = .{ .generation = &adapter };
        runtime.generation.attachment.deinit();
        runtime.generation.attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(
            &runtime.generation.attachment.generation,
            &adapter,
            testing.allocator,
            0xaa,
            7,
        );
        runtime.generation.attachment.statePtr().role = .controller;
        runtime.generation.attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.generation.observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    const outcome = runtime.refreshObservation();
    if (expect_stale) {
        try testing.expectError(error.Unauthorized, outcome);
        try testing.expectEqual(remote_attachment.Role.observer, runtime.generation.attachment.statePtr().role);
        try testing.expectEqual(@as(u64, 0), runtime.generation.observation.revision);
    } else {
        try outcome;
        try testing.expectEqual(@as(u64, 4), runtime.generation.observation.revision);
        if (expect_snapshot) {
            try testing.expectEqual(@as(usize, 1), runtime.testingClient().pending_stream.items.len);
            try testing.expectEqualStrings(
                predecessor.payload,
                runtime.testingClient().pending_stream.items[0].payload,
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
    runtime.generation.connection = .{ .legacy = &client };

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.generation.connection = .{ .generation = &adapter };
        runtime.generation.attachment.deinit();
        runtime.generation.attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.generation.attachment.generation, &adapter, testing.allocator, 0xaa, 7);
        runtime.generation.attachment.statePtr().role = .controller;
        runtime.generation.attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.event_generation_tracking = .tracked;
    defer {
        _ = c.write(runtime.testingClient().fd, "x", 1);
        peer.join();
        runtime.generation.observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    try runtime.refreshObservation();
    try testing.expectEqual(@as(u64, 4), runtime.generation.observation.revision);
    try testing.expectEqual(remote_attachment.Role.controller, runtime.generation.attachment.statePtr().role);
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
                try testing.expectEqual(remote_attachment.Role.observer, runtime.generation.attachment.statePtr().role);
                try testing.expectEqual(@as(u64, 4), runtime.generation.attachment.statePtr().controller_generation);
            } else {
                try testing.expectEqual(@as(u64, 5), runtime.generation.observation.revision);
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
    runtime.generation.connection = .{ .legacy = &client };

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.generation.connection = .{ .generation = &adapter };
        runtime.generation.attachment.deinit();
        runtime.generation.attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.generation.attachment.generation, &adapter, testing.allocator, 0xaa, 7);
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.generation.observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    if (cut == .immediate) {
        // 이 행은 연결 중 동시 close 경쟁이 아니라 호출 전에 이미 관측 가능한 EOF의 RX-first 계약을 검증한다.
        try waitRemoteTestFlag(&peer_closed);
        try testing.expectError(error.ConnectionClosed, runtime.refreshObservation());
        try testing.expectEqual(@as(u64, 0), runtime.generation.observation.revision);
    } else if (cut == .complete) {
        try runtime.refreshObservation();
        try testing.expectEqual(@as(u64, 4), runtime.generation.observation.revision);
        try testing.expectError(error.ConnectionClosed, runtime.testingClient().readStreamBatch(7));
    } else {
        try testing.expectError(error.ProtocolError, runtime.refreshObservation());
        try testing.expectEqual(@as(u64, 0), runtime.generation.observation.revision);
    }
    try testing.expect(runtime.testingClient().unusable);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_events.items.len);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_stream.items.len);
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
    runtime.generation.connection = .{ .legacy = &client };

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.generation.connection = .{ .generation = &adapter };
        runtime.generation.attachment.deinit();
        runtime.generation.attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.generation.attachment.generation, &adapter, testing.allocator, 0xaa, 7);
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.event_generation_tracking = .tracked;
    defer {
        peer.join();
        runtime.generation.observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    try testing.expectError(error.ProtocolError, runtime.refreshObservation());
    try testing.expect(runtime.testingClient().unusable);
    try testing.expectEqual(@as(u64, 0), runtime.generation.observation.revision);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_events.items.len);
    try testing.expectEqual(@as(usize, 0), runtime.testingClient().pending_stream.items.len);
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
    runtime.generation.connection = .{ .legacy = &client };

    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.generation.attachment = .init(testing.allocator, .{ .runtime_id = 0xaa, .stream_id = 7, .role = .controller, .controller_generation = 3 });
    if (mode == .generation) {
        try host_adapter_mod.HostAdapter.initializeProcessRuntime();
        try host_adapter_mod.HostAdapter.initInPlace(&adapter, testing.allocator, &client);
        runtime.generation.connection = .{ .generation = &adapter };
        runtime.generation.attachment.deinit();
        runtime.generation.attachment = .{ .generation = .{} };
        try generation_attachment_mod.testing_api.initAttached(&runtime.generation.attachment.generation, &adapter, testing.allocator, 0xaa, 7);
        runtime.generation.attachment.statePtr().role = .controller;
        runtime.generation.attachment.statePtr().controller_generation = 3;
    }
    runtime.pending_event_owner = .{};
    runtime.runtime_lifetime = .{};
    try runtime.initializePendingEventOwner();
    runtime.generation.observation = .{};
    runtime.direct_input = .empty;
    runtime.input_batches = .{};
    try runtime.direct_input.appendSlice(testing.allocator, "stale-input");
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    runtime.blocking_flush_active = false;
    runtime.generation.event_generation_tracking = .tracked;
    defer {
        runtime.generation.observation.deinit(testing.allocator);
        runtime.direct_input.deinit(testing.allocator);
        runtime.pending_controls.deinit(testing.allocator);
        runtime.generation.attachment.deinitWithConnection(runtime.generation.connection);
        if (runtime.generationConnection()) |_| adapter.deinit() else client.deinit();
    }
    const payload = "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const wire = try framing.encodeFrame(testing.allocator, .{ .kind = .event, .stream_id = 7 }, payload);
    defer testing.allocator.free(wire);
    try socket_server.writeAll(fds[1], wire);
    try testing.expectError(error.Unauthorized, runtime.refreshObservation());
    try testing.expectEqual(remote_attachment.Role.observer, runtime.generation.attachment.statePtr().role);
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
            runtime.allocator = testing.allocator;
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            runtime.blocking_flush_active = false;
            runtime.generation.resize_generation = 0;
            runtime.generation.resize_baseline_present = false;
            runtime.generation.observation = .{};
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
    try testing.expectEqual(@as(usize, 2720), @sizeOf(pending_event_owner_mod.PendingEventOwner));
    const expected_runtime_size: usize = switch (builtin.mode) {
        .Debug => 9184,
        .ReleaseFast => 9120,
        else => unreachable,
    };
    const expected_runtime_remainder: usize = switch (builtin.mode) {
        .Debug => 6464,
        .ReleaseFast => 6400,
        else => unreachable,
    };
    try testing.expectEqual(expected_runtime_size, @sizeOf(RemoteRuntime));
    try testing.expectEqual(
        expected_runtime_remainder,
        @sizeOf(RemoteRuntime) - @sizeOf(pending_event_owner_mod.PendingEventOwner),
    );
    try testing.expectEqual(
        @as(usize, 11_141_120),
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
            runtime.allocator = failing.allocator();
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            defer runtime.direct_input.deinit(runtime.allocator);
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            defer runtime.pending_controls.deinit(runtime.allocator);
            runtime.blocking_flush_active = false;
            runtime.generation.resize_generation = 0;
            runtime.generation.resize_baseline_present = false;
            runtime.generation.observation = .{};
            defer runtime.generation.observation.deinit(runtime.allocator);
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
            runtime.allocator = testing.allocator;
            runtime.direct_input = .empty;
            runtime.input_batches = .{};
            defer runtime.direct_input.deinit(runtime.allocator);
            runtime.direct_input_offset = 0;
            runtime.pending_controls = .empty;
            defer runtime.pending_controls.deinit(runtime.allocator);
            runtime.blocking_flush_active = false;
            runtime.generation.resize_generation = 0;
            runtime.generation.resize_baseline_present = false;
            runtime.generation.observation = .{};
            defer runtime.generation.observation.deinit(runtime.allocator);
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
        try runtime.generation.attachment.generation.takeEvent(),
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
    try runtime.generation.attachment.generation.releaseEvent();
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
    runtime.generation.attachment.statePtr().role = .observer;
    try testing.expectError(error.Unauthorized, runtime.sendInput("x"));
    try runtime.resize(80, 24);
    try testing.expectEqualStrings("observer-retained", runtime.direct_input.items);
    try testing.expect(host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound == null);
    try runtime.generation.attachment.generation.releaseEvent();
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
    try testing.expectEqual(remote_attachment.Role.observer, fixture.runtime.generation.attachment.statePtr().role);
    try testing.expectEqual(@as(u64, 4), fixture.runtime.generation.attachment.statePtr().controller_generation);
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
    const before_size = fixture.runtime.generation.observation.size;
    try writeC3cEventWire(peer_fd, "{\"event\":\"future.event\",\"data\":{}}");
    try testing.expect((try fixture.runtime.testingClient().readStreamBatch(7)) == null);
    try testing.expect(fixture.runtime.testingClient().firstPoisonReason() == null);
    try testing.expectError(error.ProtocolError, fixture.runtime.drainObservationEvents());
    try testing.expect(fixture.runtime.testingClient().unusable);
    try testing.expectEqual(
        @import("client_poison.zig").ConnectionReason.peer_contract_violation,
        fixture.runtime.testingClient().firstPoisonReason().?,
    );
    try testing.expectEqual(before_size, fixture.runtime.generation.observation.size);
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
    fixture.runtime.generation.resize_generation = 10;
    fixture.runtime.generation.resize_baseline_present = true;
    fixture.runtime.generation.observation.size = .{ .cols = 90, .rows = 30 };
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
    try testing.expectEqual(@as(u64, 10), fixture.runtime.generation.resize_generation);
    try testing.expectEqual(terminal.Size{ .cols = 90, .rows = 30 }, fixture.runtime.generation.observation.size);
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
        try runtime.generation.attachment.generation.sendInputNonBlocking("target-owned-frame"),
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
        try testing.expectEqual(payload.len, try runtime.generation.attachment.generation.sendInputNonBlocking(payload));
        try testing.expectEqual(@as(usize, 0), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_outbound.?.offset);
        var filler_prefix: [4096]u8 = undefined;
        try readRemoteTestExact(fds[1], &filler_prefix);
        try testing.expect(filler_len >= filler_prefix.len);
        _ = try runtime.generation.attachment.generation.pumpPendingOutput();
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
        try testing.expect(try runtime.generation.attachment.generation.pumpPendingOutput());
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
    sibling.generation.connection = .{ .legacy = &client };
    sibling.pending_event_owner = .{};
    sibling.runtime_lifetime = .{};
    try sibling.initializePendingEventOwner();
    sibling.allocator = allocator;
    sibling.io = testing.io;
    sibling.generation.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    defer sibling.generation.attachment.deinit();
    sibling.direct_input = .empty;
    defer sibling.direct_input.deinit(allocator);
    try sibling.direct_input.appendSlice(allocator, "preserve-me");
    sibling.direct_input_offset = 0;
    sibling.pending_controls = .empty;
    sibling.blocking_flush_active = false;
    defer sibling.pending_controls.deinit(allocator);
    try sibling.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.scrollToBottom(
        "preserve-me-new".len,
    ).?);
    sibling.generation.resync_needed = false;
    sibling.generation.observation = .{};

    // A foreign-stream revoke blocks shared wire progress, not local admission for this still-
    // controller sibling. The input remains owned by its bounded queue until stream 8 consumes.
    try sibling.sendInput("-new");
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(allocator, .{ .runtime_id = 1, .stream_id = 91, .role = .controller, .controller_generation = 1 });
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
    inline for (.{ input_owner_mod.InputBatchKind.paste, .ime_commit, .osc52_response }, 1..) |kind, sequence| {
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = failing.allocator();
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 11, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 13, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    defer rr.direct_input.deinit(allocator);
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 17, .role = .controller, .controller_generation = 1 });
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = failing.allocator();
    rr.runtime_id_hex = "00000000000000000000000000000001".*;
    rr.generation.attachment = .init(testing.allocator, .{
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
    try rr.direct_input.appendSlice(allocator, "superseded");
    try rr.pending_controls.append(allocator, runtime_pending_control.RawQueuedRuntimeControl.coreCommand(
        0,
        .{ .report_focus = true },
    ).?);

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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.generation.attachment = .init(testing.allocator, .{
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
            "printf '\\033]7;file://localhost/tmp/remote-meta\\007\\033]2;remote-title\\007\\033]5379;ssh;user@workbox\\007'; exec /bin/cat",
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
        metadata_found = std.mem.eql(u8, rr.generation.observation.cwd.items, "/tmp/remote-meta");
        if (!metadata_found) _ = usleep(20 * 1000);
    }
    try testing.expect(metadata_found);
    try testing.expectEqualStrings("remote-title", rr.generation.observation.window_title.items);
    try testing.expect(rr.generation.observation.ssh_remote_dest_present);
    try testing.expectEqualStrings("user@workbox", rr.generation.observation.ssh_remote_dest.items);

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
    try testing.expect(rr1.generation.attachment.streamId() != rr2.generation.attachment.streamId()); // 공유 connection이지만 stream이 갈린다.

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

test "remote runtime: takeNotification pulls a host-side OSC 9/777 desktop notification (§6.32)" {
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
    try rr.spawn(&client, allocator, io, 1, .{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 });
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
    rt.generation.connection = .{ .legacy = &client };
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
        bad_rt.generation.connection = .{ .legacy = &bad_client };
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
    rt.generation.connection = .{ .legacy = &client };
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
        bad_rt.generation.connection = .{ .legacy = &bad_client };
        bad_rt.allocator = allocator;
        try testing.expectError(error.ProtocolError, bad_rt.decodeNotificationResponse(response));
        try testing.expect(bad_client.unusable);
    }
}

test "remote runtime: notification selector follows negotiated stream auth capability" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"stream_id\":7}",
        try RemoteRuntime.notificationParams(&buf, 7),
    );
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
            rt.generation.connection = .{ .legacy = &client };
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
            rt.generation.connection = .{ .legacy = &client };
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
        if (try rr.testingClient().readStreamBatch(rr.generation.attachment.streamId())) |batch| {
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const drained = try rr.drainObservationEvents();
    try testing.expect(!drained.metadata);
    try testing.expect(!drained.ended);
    try testing.expect(rr.generation.resync_needed);
    try rr.pumpResyncIntent();
    try testing.expect(!rr.generation.resync_needed);
    peer.join();
    try testing.expect(peer_ok);
    try testing.expectEqual(@as(usize, 0), client.pending_events.items.len);
}

// 화면 정지 재현: host가 screen pressure로 내 화면을 회수하면 `snapshot.invalidated`만 보내고, 복구는 GUI가
// 능동적으로 보내는 resync에 달려 있다. 그런데 `pumpDelta`는 `pumpQueuedInput`이 false면 `pumpResyncIntent`에
// 닿기 전에 조기 반환하고, `hasBufferedControllerRevoke`는 **남의 stream** revoke 하나만 버퍼에 있어도 false를
// 만든다. 주인 runtime이 그 이벤트를 소비하기 전까지 같은 Client를 공유하는 모든 pane의 화면 복구가 함께 멈춘다.
test "remote runtime: 남의 stream revoke가 내 화면 resync 의도까지 막는다" {
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    // 내 무효화는 소비되어 resync 의도가 걸린다.
    _ = try rr.drainObservationEvents();
    try testing.expect(rr.generation.resync_needed);
    // 남의 revoke는 여전히 버퍼에 남아 있다 — 소비할 주인은 stream 10의 runtime이다.
    try testing.expect(client.hasBufferedControllerRevoke());

    // 소켓은 멀쩡하고 보낼 입력도 없는데, 남의 latch 하나가 내 진행을 막는다.
    try testing.expect(!(try rr.pumpQueuedInput()));
    // 그래서 `pumpDelta`는 여기서 조기 반환하고 resync는 전송 시도조차 되지 않는다.
    try testing.expect(rr.generation.resync_needed);
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
    try client.pending_batches.append(allocator, .{
        .stream_id = 9,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "stale"),
        .allocator = allocator,
    });
    try client.pending_batches.append(allocator, .{
        .stream_id = 10,
        .is_snapshot = false,
        .bytes = try allocator.dupe(u8, "sibling"),
        .allocator = allocator,
    });
    client.pending_batch_bytes = "stale".len + "sibling".len;
    var rr: RemoteRuntime = undefined;
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.pump_ended = false;
    rr.generation.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    try testing.expectEqual(RemoteRuntime.PumpResult.ended, try rr.pumpDelta());
    try testing.expectEqual(@as(usize, 1), client.pending_events.items.len);
    try testing.expectEqual(@as(u64, 10), client.pending_events.items[0].header.stream_id);
    try testing.expectEqual(@as(usize, 1), client.pending_batches.items.len);
    try testing.expectEqual(@as(u64, 10), client.pending_batches.items[0].stream_id);
    try testing.expectEqualStrings("sibling", client.pending_batches.items[0].bytes);
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
    rr.generation.connection = .{ .legacy = &client };
    rr.pending_event_owner = .{};
    rr.runtime_lifetime = .{};
    try rr.initializePendingEventOwner();
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.generation.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.input_batches = .{};
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.blocking_flush_active = false;
    rr.generation.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    _ = try rr.drainObservationEvents();
    try rr.pumpResyncIntent();
    try testing.expect(rr.generation.resync_needed);
    try testing.expect(client.pending_outbound != null);

    const filler = try allocator.alloc(u8, filled);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    try testing.expect(try client.pumpPendingOutput());
    const older = try readPeerFrame(fds[1], allocator);
    defer allocator.free(older.payload);
    try testing.expectEqual(protocol.Kind.input_bytes, older.header.kind);

    try rr.pumpResyncIntent();
    try testing.expect(!rr.generation.resync_needed);
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
test "remote runtime: selectContentAware computes word/line boundaries on the host (§6b-2)" {
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

    // "foo bar"를 입력 → cat echo → host core row0. RemoteScreen 반영까지 pump.
    try rr.sendInput("foo bar\n");
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

    // (0,0)의 **단어** = "foo"를 host가 경계 계산 → span. 그 span으로 텍스트를 뽑으면 "foo".
    const word_span = (try rr.selectContentAware("word", 0, 0)) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u16, 0), word_span.start.col); // "foo" 시작
    const word = (try rr.selectedText(word_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(word);
    try testing.expectEqualStrings("foo", word); // host가 공백 경계로 단어를 잡았다(빈 placeholder는 못 함).

    // **줄** 선택 = row0 전체 "foo bar".
    const line_span = (try rr.selectContentAware("line", 0, 0)) orelse {
        try testing.expect(false);
        return;
    };
    const line = (try rr.selectedText(line_span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(line);
    try testing.expectEqualStrings("foo bar", line); // 줄 전체(host 계산).
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

test "CR2a RemoteGeneration field inventory는 generation owner 열한 개만 포함한다" {
    const fields = @typeInfo(RemoteGeneration).@"struct".fields;
    const expected_generation_size: usize = switch (builtin.mode) {
        .Debug => 3072,
        .ReleaseFast => 3056,
        else => unreachable,
    };
    try testing.expectEqual(expected_generation_size, @sizeOf(RemoteGeneration));
    const expected_runtime_size: usize = switch (builtin.mode) {
        .Debug => 9184,
        .ReleaseFast => 9120,
        else => unreachable,
    };
    try testing.expectEqual(expected_runtime_size, @sizeOf(RemoteRuntime));
    const expected = [_][]const u8{
        "connection",
        "attachment",
        "event_generation_tracking",
        "resize_seq",
        "resize_generation",
        "resize_baseline_present",
        "pump_ended",
        "resync_needed",
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
    try testing.expectEqual(@as(usize, 1), comptime countField(runtime_fields, "generation"));
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
    try testing.expect(@intFromPtr(fixture.runtime.generation.attachment.screenPtr().?) != @intFromPtr(remote.ctx));
    fixture.runtime.surface.lockCore(std.testing.io);
    const snapshot = fixture.runtime.surface.renderSnapshot();
    try testing.expectEqual(@as(u21, 'x'), snapshot.cells[0].codepoint);
    fixture.runtime.surface.unlockCore(std.testing.io);
}

fn countField(comptime fields: []const std.builtin.Type.StructField, comptime name: []const u8) usize {
    comptime var result: usize = 0;
    inline for (fields) |field| if (std.mem.eql(u8, field.name, name)) {
        result += 1;
    };
    return result;
}
