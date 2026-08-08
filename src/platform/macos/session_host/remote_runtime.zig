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
const client_mod = @import("client.zig");
const client_poison = @import("client_poison.zig");
const control_response_wire = @import("control_response_wire.zig");
const protocol = @import("protocol.zig");
const screen_assembler = @import("screen_assembler.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const resize_wire = @import("resize_wire.zig");
const core_command_wire = @import("core_command_wire.zig");
const remote_attachment = @import("remote_attachment.zig");
const generation_attachment_mod = @import("generation_attachment.zig");
const generation_contract = @import("generation_attachment_contract.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const host_adapter_mod = @import("host_adapter.zig");

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

    fn deinitWithAdapter(self: *RuntimeAttachment, generation_adapter: ?*host_adapter_mod.HostAdapter) void {
        switch (self.*) {
            .legacy => |*value| value.deinit(),
            .generation => |*value| value.deinit(generation_adapter orelse
                @panic("generation attachment lost its retained adapter")),
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
        client: *client_mod.Client,
        generation: u64,
    ) anyerror!client_mod.Client.RevokeFence {
        return switch (self.*) {
            .legacy => |*value| blk: {
                try value.applyValidatedRevoked(generation);
                break :blk try client.fenceRevokedStream(value.streamId());
            },
            .generation => |*value| switch (try value.applyValidatedRevokedAndFence(generation)) {
                .no_pending_stream_frame => .no_pending_stream_frame,
                .cancelled_before_write => .cancelled_before_write,
                .partial_frame_requires_close => .partial_frame_requires_close,
            },
        };
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
        client: *client_mod.Client,
    ) client_mod.ClientError!bool {
        return switch (self.*) {
            .legacy => client.pumpPendingOutput(),
            .generation => |*value| value.pumpPendingOutput() catch |err|
                return mapGenerationInputError(err),
        };
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

fn mapGenerationInputError(err: @import("generation_transport.zig").InputError) client_mod.ClientError {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner, error.ProtocolError => error.ProtocolError,
        error.Unauthorized => error.Unauthorized,
        error.ResourceExhausted => error.OutOfMemory,
        error.ConnectionClosed => error.ConnectionClosed,
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

/// 한 원격 runtime. self-referential(`surface.remote`가 attachment screen을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    client: *client_mod.Client, // borrowed — 여러 runtime이 한 connection을 공유한다(stream_id로 구분).
    generation_adapter: ?*host_adapter_mod.HostAdapter,
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    attachment: RuntimeAttachment,
    event_generation_tracking: EventGenerationTracking,
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    resize_generation: u64,
    resize_baseline_present: bool,
    // blocking `SurfaceRuntime.writeInput`의 key bytes와 그 사이 core command를 한 시간축으로 보존한다.
    // control.barrier는 그 명령보다 먼저 host에 도착해야 하는 direct_input byte prefix 끝이다.
    direct_input: std.ArrayListUnmanaged(u8),
    direct_input_offset: usize,
    pending_controls: std.ArrayListUnmanaged(PendingControl),
    // shared transport hard failure를 이 runtime surface에 한 번만 투영한다. connection 하나를 여러 runtime이
    // 공유하므로 각 runtime pump가 자기 surface를 exited로 latch하되 매 frame 같은 read_error를 재방출하지 않는다.
    pump_ended: bool,
    resync_needed: bool,
    observation: term_backend.RuntimeObservation, // host attach/event에서 받은 화면 외 full-state owned cache.
    surface: Surface, // 원격-backed(surface.remote = attachment screen source). GUI가 이걸 렌더.

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
        return self.spawnWithOwner(
            client,
            null,
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
        return self.spawnWithOwner(
            adapter.logicalClient(),
            adapter,
            allocator,
            io,
            surface_id,
            request,
            size,
            initial_config,
        );
    }

    fn spawnWithOwner(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        generation_adapter: ?*host_adapter_mod.HostAdapter,
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
        if (initial_config != null and !client.runtime_core_command_v1) return error.UnsupportedSpawnContract;
        self.client = client;
        self.generation_adapter = generation_adapter;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.resize_generation = 0;
        self.resize_baseline_present = false;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.pending_controls = .empty;
        self.pump_ended = false;
        self.resync_needed = false;
        self.observation = .{};
        errdefer self.observation.deinit(allocator);

        // 1. runtime.spawn_full — host가 확장 spawn 계약으로 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, request, size, initial_config) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        // 기존 v2 host가 새 필드를 unknown JSON으로 무시해 다른 셸을 띄우지 않도록 새 method 이름을 쓴다. 구 host는
        // invalid_request로 거부하고 기존 runtime attach는 계속 v2로 가능하다.
        const spawn_resp = try client.call("runtime.spawn_full", spawn_params);
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
        return self.attachExistingWithOwner(
            client,
            null,
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
        return self.attachExistingWithOwner(
            adapter.logicalClient(),
            adapter,
            allocator,
            io,
            surface_id,
            runtime_id_hex,
            size,
        );
    }

    fn attachExistingWithOwner(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        generation_adapter: ?*host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        self.client = client;
        self.generation_adapter = generation_adapter;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.resize_generation = 0;
        self.resize_baseline_present = false;
        self.direct_input = .empty;
        self.direct_input_offset = 0;
        self.pending_controls = .empty;
        self.pump_ended = false;
        self.resync_needed = false;
        self.observation = .{};
        errdefer self.observation.deinit(allocator);
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    /// spawn/attachExisting 공통(§10 attach 순서): controller attach(stream_id) → 첫 snapshot 조립 → 원격-backed Surface.
    /// `self.runtime_id_hex`가 이미 채워져 있어야 한다(spawn=runtime.spawn 응답, attachExisting=저장된 값).
    fn attachAndAssemble(self: *RemoteRuntime, surface_id: u64, size: terminal.Size) anyerror!void {
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
            _ = self.attachment.generation.finishResponse(self.generation_adapter.?);
            self.attachment.generation.abortExecutedAttach(
                self.generation_adapter.?,
                accepted.executed_call,
            ) catch @panic("generation attach rollback failed");
        };
        const attach_resp: []const u8 = if (self.generation_adapter) |adapter| blk: {
            try self.attachment.initGenerationInPlace(adapter);
            const prepared = try self.attachment.generation.prepareControllerAttach(
                adapter,
                runtime_id,
            );
            const result = try self.attachment.generation.executePreparedAttach(adapter, prepared);
            const correlated = switch (result) {
                .accepted => |value| value,
                .typed_reject => {
                    _ = self.attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
                .uncertain_or_connection_failure => {
                    _ = self.attachment.generation.finishResponse(adapter);
                    return error.AttachFailed;
                },
            };
            generation_accepted = correlated;
            generation_binding_open = true;
            break :blk try self.attachment.generation.responseBytes(adapter);
        } else blk: {
            var attach_buf: [96]u8 = undefined;
            const attach_params = std.fmt.bufPrint(
                &attach_buf,
                "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
                .{self.runtime_id_hex},
            ) catch return error.AttachFailed;
            const response = self.client.call("runtime.attach", attach_params) catch |err| {
                // `Client.call` can consume a committed response and then fail while duplicating its
                // payload. At that point no stream id exists for targeted rollback, so even an OOM
                // that might have happened before send is conservatively connection-fatal.
                if (err == error.OutOfMemory) self.client.poison(.local_resource_exhausted);
                return err;
            };
            legacy_response = response;
            break :blk response;
        };
        const compatibility_profile = self.client.compatibility_profile orelse {
            self.client.poison(.local_invariant_violation);
            return error.AttachFailed;
        };
        const generation_schema: runtime_metadata_wire.AttachGenerationSchema = switch (compatibility_profile.attach_schema) {
            .frozen_controller_only => .frozen_controller_only,
            .granted_roles => if (self.client.attachment_capabilities.peer_attach_generation)
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
                .metadata_support = self.client.metadata_support,
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.client.poison(.local_resource_exhausted);
                return error.OutOfMemory;
            },
            error.Malformed, error.ResourceExhausted, error.CapabilityViolation => {
                self.client.poison(.peer_contract_violation);
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
                self.client.poison(.peer_contract_violation);
                return err;
            },
            .unsupported, .unavailable => {},
        }
        self.event_generation_tracking = switch (generation_schema) {
            .frozen_controller_only, .granted_without_generation => .untracked,
            .granted_with_generation => .tracked,
        };
        if (self.generation_adapter) |adapter| {
            if (self.attachment.generation.finishResponse(adapter) != .cleaned)
                @panic("generation attach response cleanup failed");
            try self.attachment.generation.commitAccepted(
                adapter,
                generation_accepted.?,
                accepted.state,
                self.allocator,
            );
            generation_binding_open = false;
        } else {
            self.attachment = .init(self.allocator, accepted.state);
            self.attachment.bindLegacyTransport(attachmentTransport(self.client)) catch {
                self.client.poison(.local_invariant_violation);
                return error.AttachFailed;
            };
        }
        // attach RPC가 controller lease를 잡은 뒤 snapshot/화면 조립이 실패하면 caller에는 아직 완성된
        // RemoteRuntime이 없어 detachClientSide를 부를 수 없다. 이 구간에서 반드시 lease와 demux 큐를 되돌린다.
        errdefer {
            self.detachBestEffort();
            self.attachment.deinitWithAdapter(self.generation_adapter);
        }

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        var generation_snapshot: initial_snapshot_owner_mod.InitialSnapshotOwner = .{};
        var generation_snapshot_live = false;
        var legacy_snapshot: ?[]u8 = null;
        const snap: []const u8 = switch (self.attachment) {
            .legacy => blk: {
                const bytes = try self.client.readSnapshot(self.attachment.streamId());
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
        try self.attachment.initScreen(self.client.screen_codec_version);
        // mode bit 자체는 v2에도 우연히 존재할 수 있으므로 hello_ack에서 명시 협상한 host일 때만 "0 = live bottom"을
        // 신뢰한다. 구 host는 capability=false로 두고, RemoteScreen이 snapshot별 visible cursor 증거만으로
        // legacy live preedit/candidate를 허용한다. hidden/ambiguous snapshot은 계속 fail-closed다.
        self.attachment.screenPtr().?.viewport_scrolled_known = self.client.screen_viewport_scrolled_v1;
        self.attachment.screenPtr().?.applySnapshot(snap, self.io) catch |err| {
            switch (self.attachment) {
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
        self.surface.remote = self.attachment.screenPtr().?.screenSource();
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.terminateBestEffort();
        // terminate response보다 먼저 온 async continuation도 call이 pending_stream에 보존하므로 RPC 뒤 한 번에 회수한다.
        self.surface.deinit();
        self.attachment.deinitWithAdapter(self.generation_adapter);
        self.observation.deinit(self.allocator);
        self.direct_input.deinit(self.allocator);
        self.pending_controls.deinit(self.allocator);
        self.* = undefined;
    }

    /// client-side 자원만 회수한다(surface/screen) — **host runtime은 안 죽인다**(terminate 안 보냄). 앱 quit 시 host-backed
    /// Term을 이걸로 정리하면 runtime이 host에 남아(연결 EOF를 host가 detach로 처리해 유지, §6 app-quit=detach) GUI 재실행 시
    /// `attachExisting`으로 재접속한다. `deinit`과 대칭이되 terminate만 뺀다.
    pub fn detachClientSide(self: *RemoteRuntime) void {
        // shared connection은 앱 종료 전까지 EOF가 오지 않을 수 있다. RPC detach 없이 로컬 객체만 버리면 host의 controller
        // lease가 남아 같은 connection의 재attach가 controller_busy가 되므로 subscription을 먼저 명시 해제한다.
        self.detachBestEffort();
        self.surface.deinit();
        self.attachment.deinitWithAdapter(self.generation_adapter); // stream demux queue + attachment-owned screen.
        self.observation.deinit(self.allocator);
        self.direct_input.deinit(self.allocator);
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
        return !self.attachment.allowsMutation();
    }

    pub fn usesGenerationAttachment(self: *const RemoteRuntime) bool {
        return switch (self.attachment) {
            .generation => true,
            .legacy => false,
        };
    }

    /// 렌더/입력 라우팅에 쓸 Surface(GUI가 in-process처럼 다룬다).
    pub fn surfacePtr(self: *RemoteRuntime) *Surface {
        return &self.surface;
    }

    fn mutationAllowed(self: *const RemoteRuntime) bool {
        return self.attachment.mutationAllowed(self.client);
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
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
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!(try self.pumpQueuedInput())) return 0;
        return self.attachment.sendInputNonBlocking(self.client, bytes);
    }

    /// AppKit callback-safe live-bottom 요청. socket read/blocking write를 하지 않고 stream-local intent만
    /// bounded control FIFO에 넣은 뒤 DONTWAIT admission을 한 번 시도한다. 같은 byte barrier의 연속 scroll은
    /// coalesce하고, 슬롯이 다른 frame으로 막혔으면 tick/input 경로가 다시 시도한다.
    pub fn requestScrollToBottom(self: *RemoteRuntime) client_mod.ClientError!void {
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.client.async_scroll_to_bottom_v1) return;
        const barrier = self.direct_input.items.len;
        if (self.pending_controls.items.len > 0) {
            const last = self.pending_controls.items[self.pending_controls.items.len - 1];
            if (last.barrier == barrier and last.op == .scroll_to_bottom) {
                _ = try self.pumpQueuedInput();
                return;
            }
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        self.pending_controls.append(self.allocator, .{ .barrier = barrier, .op = .scroll_to_bottom }) catch
            return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    /// focus/config/prompt 등 host-authoritative 명령을 input과 같은 stream-local 시간축에 넣는다. queue가 인수한 뒤
    /// socket backpressure가 생겨도 다음 frame tick이 재시도하며, bounded cap을 넘으면 명시적으로 실패한다.
    pub fn queueCoreCommand(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.client.runtime_core_command_v1) {
            if (command.isLegacyScroll()) return self.sendCoreCommandBlocking(command);
            return;
        }
        if (self.pending_controls.items.len >= max_pending_controls) return self.failControlAdmission();
        self.pending_controls.append(self.allocator, .{
            .barrier = self.direct_input.items.len,
            .op = .{ .core_command = command },
        }) catch return self.failControlAdmission();
        _ = try self.pumpQueuedInput();
    }

    const max_direct_input_bytes: usize = 64 * 1024;
    const max_pending_controls: usize = 64;

    fn failControlAdmission(self: *RemoteRuntime) client_mod.ClientError!void {
        // cap 초과뿐 아니라 queue allocation OOM도 caller가 UI best-effort로 삼키면 최종 focus/config 상태가
        // 조용히 유실된다. 이 stream만 복구할 ACK가 없으므로 shared connection을 poison해 다음 pump가
        // 명시적 disconnect와 surface exit latch를 관측하게 한다.
        self.client.poison(.local_queue_exhausted);
        return error.ConnectionClosed;
    }

    const PendingControl = struct {
        barrier: usize,
        op: union(enum) {
            scroll_to_bottom,
            core_command: core_command_wire.Command,
        },
    };

    fn admitControl(self: *RemoteRuntime, control: PendingControl) client_mod.ClientError!bool {
        if (!self.mutationAllowed()) return error.Unauthorized;
        return switch (control.op) {
            .scroll_to_bottom => self.client.sendScrollToBottomNonBlocking(self.attachment.streamId()) catch |err| switch (err) {
                error.OutOfMemory => false,
                else => return err,
            },
            .core_command => |command| blk: {
                const params = core_command_wire.encodeParams(self.allocator, self.attachment.streamId(), command) catch break :blk false;
                defer self.allocator.free(params);
                break :blk self.client.sendCoreCommandNonBlocking(self.attachment.streamId(), params) catch |err| switch (err) {
                    error.OutOfMemory => false,
                    else => return err,
                };
            },
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
            control.barrier -= consumed;
        }
        self.direct_input_offset = 0;
    }

    /// 직접 key FIFO와 control FIFO를 단일 시간 순서로 Client outbound에 넘긴다.
    /// 반환 false는 socket backpressure로 아직 queue/barrier가 남았다는 뜻이며 데이터 소유권은 유지된다.
    fn pumpQueuedInput(self: *RemoteRuntime) client_mod.ClientError!bool {
        if (!self.attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return true;
        }
        if (self.attachment.hasBufferedControllerRevoke(self.client)) return false;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = control.barrier;
                if (self.direct_input_offset < barrier) {
                    const accepted = self.attachment.sendInputNonBlocking(
                        self.client,
                        self.direct_input.items[self.direct_input_offset..barrier],
                    ) catch |err| switch (err) {
                        error.OutOfMemory, error.AdminBusy => return false,
                        else => return err,
                    };
                    if (accepted == 0) return false;
                    self.direct_input_offset += accepted;
                    continue;
                }
                if (!(try self.admitControl(control))) return false;
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                const accepted = self.attachment.sendInputNonBlocking(
                    self.client,
                    self.direct_input.items[self.direct_input_offset..],
                ) catch |err| switch (err) {
                    error.OutOfMemory, error.AdminBusy => return false,
                    else => return err,
                };
                if (accepted == 0) return false;
                self.direct_input_offset += accepted;
                continue;
            }
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return true;
        }
    }

    /// 이 runtime이 이미 소유한 key/control barrier를 blocking RPC보다 먼저 전송한다. RemoteRuntime의 FIFO와
    /// Client의 connection-level pending frame이라는 두 ownership 층 사이에서 mouse/core/resize RPC가 key를
    /// 추월하지 않게 하는 단일 경계다. 각 blocking RPC는 원래도 Client.call에서 pending socket write를 기다린다.
    fn flushQueuedInputBlocking(self: *RemoteRuntime) client_mod.ClientError!void {
        if (!self.attachment.allowsMutation()) {
            self.discardQueuedMutations();
            return;
        }
        if (self.attachment.hasBufferedControllerRevoke(self.client)) return error.AdminBusy;
        while (true) {
            if (self.pending_controls.items.len > 0) {
                const control = self.pending_controls.items[0];
                const barrier = control.barrier;
                if (self.direct_input_offset < barrier) {
                    try self.attachment.sendInput(
                        self.client,
                        self.direct_input.items[self.direct_input_offset..barrier],
                    );
                    self.direct_input_offset = barrier;
                    continue;
                }
                switch (control.op) {
                    .scroll_to_bottom => try self.client.sendScrollToBottom(self.attachment.streamId()),
                    .core_command => |command| {
                        const params = core_command_wire.encodeParams(self.allocator, self.attachment.streamId(), command) catch
                            return error.OutOfMemory;
                        defer self.allocator.free(params);
                        try self.client.sendCoreCommand(self.attachment.streamId(), params);
                    },
                }
                _ = self.pending_controls.orderedRemove(0);
                continue;
            }
            if (self.direct_input_offset < self.direct_input.items.len) {
                try self.attachment.sendInput(
                    self.client,
                    self.direct_input.items[self.direct_input_offset..],
                );
                self.direct_input_offset = self.direct_input.items.len;
                continue;
            }
            self.direct_input.clearRetainingCapacity();
            self.direct_input_offset = 0;
            return;
        }
    }

    fn callOrdered(self: *RemoteRuntime, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        try self.flushQueuedInputBlocking();
        return self.client.call(method, params_json);
    }

    fn discardQueuedMutations(self: *RemoteRuntime) void {
        self.direct_input.clearRetainingCapacity();
        self.direct_input_offset = 0;
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
        if (!self.resize_baseline_present or generation > self.resize_generation) {
            self.resize_generation = generation;
            self.observation.size = size;
            self.resize_baseline_present = true;
            return true;
        }
        if (generation == self.resize_generation and
            !std.meta.eql(size, self.observation.size))
        {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
        return false;
    }

    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) ResizeError!void {
        // Observer viewport follows the controller's canonical runtime size; local window changes
        // are acknowledged as a no-op instead of becoming an infinite GUI retry.
        if (!self.mutationAllowed()) return;
        if (self.resize_seq == resize_wire.max_counter)
            return error.SequenceExhausted;
        self.resize_seq += 1;
        var buf: [96]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buf, .{ .resize = .{
            .stream_id = self.attachment.streamId(),
            .cols = cols,
            .rows = rows,
            .client_sequence = self.resize_seq,
        } }) catch |err| return switch (err) {
            error.InvalidRequest => error.ResizeRejected,
            error.BufferTooSmall => error.OutOfMemory,
        };
        const resp = try self.callOrdered(encoded.method, encoded.params);
        defer self.allocator.free(resp);
        const reply = decodeResizeReply(self.allocator, resp, self.resize_seq) catch |err| {
            if (err == error.ProtocolError) self.client.poison(.peer_contract_violation);
            return err;
        };
        switch (reply) {
            .stale => {},
            .applied => |applied| {
                _ = try self.applyResizeFullState(
                    .{ .cols = applied.cols, .rows = applied.rows },
                    applied.resize_generation,
                );
            },
        }
    }

    /// 내 stream(§멀티 runtime demux)의 다음 화면 배치 하나를 소비해 원격 화면에 반영한다(§9/§10). **논블로킹** — 내 배치가
    /// 없으면 `idle`, metadata만 적용했으면 `metadata`, 화면 batch를 적용했으면 `screen`을 돌려준다. caller는 있는 동안
    /// 반복해 다 비우되 metadata를 PTY output activity로 세지 않는다(`RemoteTermBackend`의
    /// drain이 이걸로 `RuntimeEventPump.drainAvailable`과 같은 의미를 만든다). client가 `stream_id`로 demux하므로 여기 도달한
    /// 배치는 **항상 내 것**이다(예전엔 남의 배치를 free해 유실 — code-review #1; 이제 client가 남의 것은 버퍼해 그 runtime pump로
    /// 보낸다). host가 grid/alt 변화 시 delta 대신 fresh snapshot을 push하므로 둘 다 처리한다(is_snapshot이면 리셋, 아니면 증분).
    pub const PumpResult = enum { idle, metadata, screen, ended };

    pub fn pumpDelta(
        self: *RemoteRuntime,
    ) (client_mod.ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!PumpResult {
        // Revoke/ended events fence mutation. Consume already-buffered authority events before
        // advancing any input/control that was accepted on a previous UI turn.
        var events = try self.drainObservationEvents();
        if (events.ended) return .ended;
        // 마지막 non-blocking input 뒤에 새 입력/RPC가 영원히 없더라도 frame-loop pump가 연결의 bounded pending frame을
        // 계속 DONTWAIT로 진전시킨다. Client 하나를 여러 runtime이 공유하므로 어느 runtime pump가 호출해도 충분하다.
        if (!(try self.pumpQueuedInput()))
            return if (events.metadata) .metadata else .idle;
        _ = try self.attachment.pumpPendingOutput(self.client);
        try self.pumpResyncIntent();
        switch (try self.attachment.pumpScreen(self.io)) {
            .idle => {
                // readStreamBatch가 socket에서 event만 읽어 pending queue에 넣고 screen batch 없이 돌아올 수 있다.
                const after_read = try self.drainObservationEvents();
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
        const after_screen = try self.drainObservationEvents();
        if (after_screen.ended) return .ended;
        return .screen;
    }

    const EventDrain = struct {
        metadata: bool = false,
        ended: bool = false,
    };

    fn drainObservationEvents(self: *RemoteRuntime) client_mod.ClientError!EventDrain {
        var result: EventDrain = .{};
        while (try self.client.takeEventForStream(self.attachment.streamId())) |frame| {
            defer self.client.releaseEvent(frame);
            const verdict = frame.preflight orelse
                runtime_event_wire.preflightEvent(frame.payload, .{});
            const classification = runtime_metadata_wire.classifyAndMaterializeEvent(
                self.allocator,
                .{
                    .runtime_id = self.attachment.statePtr().runtime_id,
                    .stream_id = self.attachment.statePtr().stream_id,
                },
                .{
                    .role = switch (self.attachment.statePtr().role) {
                        .observer => .observer,
                        .controller => .controller,
                    },
                    .generation = switch (self.event_generation_tracking) {
                        .untracked => .untracked,
                        .tracked => .{
                            .tracked = self.attachment.statePtr().controller_generation,
                        },
                    },
                },
                .{
                    .expected_major = self.client.wire_major,
                    .metadata_support = self.client.metadata_support,
                    .verdict = verdict,
                },
                .{
                    .major = frame.header.major,
                    .kind = frame.header.kind,
                    .stream_id = frame.header.stream_id,
                    .request_id = frame.header.request_id,
                    .flags = frame.header.flags,
                    .payload_len = frame.header.payload_len,
                    .payload = frame.payload,
                },
            ) catch |err| {
                self.client.poison(if (err == error.OutOfMemory)
                    .local_resource_exhausted
                else
                    .peer_contract_violation);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ProtocolError,
                };
            };
            const event = switch (classification) {
                .accepted => |accepted| accepted,
                .violation => {
                    self.client.poison(.peer_contract_violation);
                    return error.ProtocolError;
                },
            };
            switch (event) {
                .revoked => |generation| {
                    const revoke_fence = self.attachment.applyValidatedRevokedAndFence(
                        self.client,
                        generation,
                    ) catch {
                        self.client.poison(.local_invariant_violation);
                        return error.ProtocolError;
                    };
                    self.discardQueuedMutations();
                    switch (revoke_fence) {
                        .no_pending_stream_frame, .cancelled_before_write => {},
                        .partial_frame_requires_close => {
                            self.client.poison(.outbound_partial_write);
                            return error.ConnectionClosed;
                        },
                    }
                    result.metadata = true;
                },
                .invalidated => {
                    // Latch before releasing the event. The next frame-pump turn admits one
                    // bounded response-free stream ack; backpressure leaves it set for retry.
                    self.resync_needed = true;
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
                        self.client.poison(.peer_contract_violation);
                        return err;
                    }) or result.metadata;
                },
                .ended => result.ended = true,
            }
        }
        if (result.ended) self.client.dropBufferedStream(self.attachment.streamId());
        return result;
    }

    fn pumpResyncIntent(self: *RemoteRuntime) client_mod.ClientError!void {
        if (!self.resync_needed) return;
        const accepted = self.client.sendResyncNonBlocking(self.attachment.streamId()) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => return err,
        };
        if (accepted) self.resync_needed = false;
    }

    fn applyMetadataDto(
        self: *RemoteRuntime,
        dto: *const runtime_metadata_wire.OwnedMetadataDto,
    ) error{ OutOfMemory, ProtocolError }!bool {
        if (dto.revision < self.observation.revision) return false;
        if (dto.revision == self.observation.revision) {
            // A revision is a semantic version, not merely an ordering hint. Accepting different
            // cwd/SSH data under the same revision would let the synchronous SSH barrier return
            // success while retaining a stale destination.
            if (!metadataDtoMatchesObservation(dto, self.observation.view()))
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
        try self.observation.replace(self.allocator, .{
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
        self.terminateBestEffort();
    }

    /// host에 fresh snapshot 재요청(§9 desync 복구) — 조립기가 `GenerationGap`/`MalformedRow`로 뒤처졌을 때 `pumpDelta` 실패
    /// 경로가 부른다. host가 다음 delta tick에 현재 full snapshot을 snapshot_chunk로 push하고, 그걸 `pumpDelta`의 applySnapshot이
    /// 받아 generation을 리셋해 복구한다(delta는 base_generation이 현재라 stale client를 못 고쳐 snapshot이 유일한 복구). 응답 무시.
    pub fn requestResync(self: *RemoteRuntime) client_mod.ClientError!void {
        var buf: [64]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buf, .{ .resync = .{
            .stream_id = self.attachment.streamId(),
        } }) catch |err| return switch (err) {
            error.InvalidRequest => error.ProtocolError,
            error.BufferTooSmall => error.OutOfMemory,
        };
        const resp = try self.callOrdered(encoded.method, encoded.params);
        defer self.allocator.free(resp);
        try decodeResyncReply(self.client, self.allocator, resp);
    }

    /// periodic event보다 강한 metadata barrier. SSH upload처럼 stale destination으로 실행하면 안 되는 user action이
    /// 직전에 호출한다. host가 subscription revision/base와 같은 원자 상태에서 응답하므로 성공 뒤 observation은 host가
    /// 응답을 만든 시점의 full-state다.
    pub fn refreshObservation(self: *RemoteRuntime) client_mod.ClientError!void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.attachment.streamId()}) catch return error.OutOfMemory;
        const before = self.observation.revision;
        const resp = try self.callOrdered("runtime.observation", params);
        defer self.allocator.free(resp);
        var seed = runtime_metadata_wire.decodeObservationEnvelope(
            self.allocator,
            resp,
        ) catch |err| {
            self.client.poison(.peer_contract_violation);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Malformed, error.ResourceExhausted, error.CapabilityViolation => error.ProtocolError,
            };
        };
        defer seed.deinit();
        const dto = switch (seed) {
            .current => |*current| current,
            .unsupported, .unavailable => {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            },
        };
        const revision = dto.revision;
        if (revision < before) {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
        const changed = self.applyMetadataDto(dto) catch |err| {
            self.client.poison(.peer_contract_violation);
            return err;
        };
        if (revision > before and !changed) {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (self.observation.availability != .current or self.observation.revision != revision) {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
    }

    /// host에 뷰포트 선택 span을 보내 host의 `extractSelection`(로컬과 같은 함수)으로 뽑은 텍스트를 받는다(§6b 원격 선택 복사).
    /// **선택 의미론은 host core 단일 출처** — client는 렌더용 span만 보내고 콘텐츠 추출(soft-wrap 이음·블록·스크롤백)은 host가
    /// 한다. 단 앱보다 먼저 떠 계속 살아 있는 구 host는 이 RPC를 모르므로 capability가 없을 때만 현재 client 화면 projection의
    /// 보이는 선택을 추출한다. 반환 텍스트는 caller 소유(빈 선택/오류면 null). `block`은 std.fmt가 true/false로 찍어 유효 JSON.
    pub fn selectedText(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        if (!self.client.runtime_selected_text_v1) return self.selectedTextFromProjection(span);
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ self.attachment.streamId(), span.start.row, span.start.col, span.end.row, span.end.col, span.block }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.selected_text", params);
        defer self.allocator.free(resp);
        return self.decodeSelectedTextResponse(resp);
    }

    fn decodeSelectedTextResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?[]u8 {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        // error envelope는 알려진 코드일 때만 "선택 없음"으로 접는다(모르는 코드 = schema 드리프트).
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        // capability를 광고한 host가 success schema를 지키지 않으면 같은 connection의 나머지 RPC도 신뢰할 수 없다.
        // 구 host 호환은 capability=false에서만 허용하고, 거짓 광고/드리프트는 빈 복사로 숨기지 않는다.
        const text = obj.string("text") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.fields.len != 1) { // 선언한 키(text) 하나만 허용.
            self.client.poison(.peer_contract_violation);
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
        if (!self.client.runtime_link_at_v1) return null;
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"row\":{d},\"col\":{d},\"scopes\":{d}}}", .{ self.attachment.streamId(), row, col, scopes }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.link_at", params);
        defer self.allocator.free(resp);
        return self.decodeLinkAtResponse(resp);
    }

    /// `runtime.link_at` success는 링크가 있으면 `{"text":"...","kind":N}`, 없으면 `{"text":""}`다.
    /// `decodeSelectedTextResponse`와 **같은 strict 디코더**를 쓰되 이 두 형태만 허용한다. 예전엔 응답 스키마마다 파서를
    /// 골라 썼고, 필드가 정확히 하나인 객체만 받는 파서에 link success를 통과시키려다 정상 응답이 InvalidJson으로 떨어져
    /// 연결이 fail-close됐다(밑줄은 뜨는데 Cmd+클릭만 안 열리던 버그). `{"error":...}`나 빈 text는 "링크 없음"(null)이다.
    fn decodeLinkAtResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?RemoteLink {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null; // 알려진 error = 링크 없음(일반 클릭으로 흐른다 — 선택 복사와 같은 정책).
        }
        const text = obj.string("text") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        // host의 no-link success는 `{text:""}` 하나뿐이다. 이 분기를 kind보다 먼저 판정해야 기존 same-major host가
        // 미존재 경로를 정상적으로 "링크 없음"으로 돌려줄 때 schema 위반으로 오인하지 않는다.
        if (text.len == 0) {
            if (obj.fields.len != 1) {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const kind_raw = obj.number("kind") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.hasUnknownKey(&.{ "text", "kind" })) { // 선언 밖 키 = schema 드리프트.
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
        const kind: terminal.LinkKind = switch (kind_raw) {
            0 => .url,
            1 => .file_path,
            else => {
                // 숫자로 파싱됐다는 사실만으로 wire enum이 유효한 것은 아니다. 미래 kind를 URL로 추측하면 새 의미를
                // 잘못 실행하므로, 같은 major의 정의된 값만 받고 나머지는 connection 전체를 신뢰하지 않는다.
                self.client.poison(.peer_contract_violation);
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
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!self.client.runtime_clipboard_v1) return null;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.attachment.streamId()}) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.clipboard_write", params);
        defer self.allocator.free(resp);
        return self.decodeClipboardWriteResponse(resp);
    }

    fn decodeClipboardWriteResponse(self: *RemoteRuntime, resp: []const u8) client_mod.ClientError!?ClipboardWrite {
        const obj = decodeStrictObject(self.allocator, resp) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const b64 = obj.string("b64") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        const too_large = (obj.number("too_large") orelse 0) != 0;
        if (obj.hasUnknownKey(&.{ "b64", "too_large" })) {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        }
        if (b64.len == 0) return .{ .text = null, .too_large = too_large };
        const dec = std.base64.standard.Decoder;
        const size = dec.calcSizeForSlice(b64) catch {
            self.client.poison(.peer_contract_violation); // capability를 광고한 host가 유효하지 않은 base64를 보냈다 = schema 드리프트
            return error.ProtocolError;
        };
        const out = self.allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer self.allocator.free(out);
        dec.decode(out, b64) catch {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        return .{ .text = out, .too_large = false };
    }

    /// 구 host 호환 경로. RemoteScreen이 조립한 현재 viewport에서만 추출한다.    /// 구 host 호환 경로. RemoteScreen이 조립한 현재 viewport에서만 추출한다. 구 screen wire에는 soft-wrap bit가 없어
    /// multi-row 선형 선택은 보이는 행 사이에 개행을 보존하는 degraded 정책이며, capability가 있는 최신 host에서는 반드시
    /// 위 RPC를 써 host SSOT를 유지한다.
    fn selectedTextFromProjection(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        return self.attachment.screenPtr().?.extractVisibleSelection(self.allocator, self.io, span);
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

    pub fn find(self: *RemoteRuntime, query: []const u8, cur_index: u32, scroll: bool, out_spans: *std.ArrayList(terminal.SelectionSpan)) client_mod.ClientError!FindResult {
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
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"q\":\"{s}\",\"cur\":{d},\"scroll\":{}}}", .{ self.attachment.streamId(), hexbuf[0 .. qn * 2], cur_index, scroll }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.find", params);
        defer self.allocator.free(resp);
        const count = client_mod.extractU64Field(resp, "\"count\":") orelse 0;
        const cur = parseFirstSpan(resp, "\"cur\":[");
        parseSpansInto(resp, out_spans, self.allocator);
        return .{ .count = @intCast(count), .cur = cur, .voff = client_mod.extractU64Field(resp, "\"voff\":") };
    }

    /// 단어/줄 선택(§6b-2): host가 콘텐츠를 아는 자기 core로 경계를 계산하게 하고(`selectWordAt`/`selectLineAt`) 결과 뷰포트
    /// 선택 span을 받는다(빈 placeholder는 경계를 모른다 = 선택 의미론 host 단일 출처). caller는 이 span을 placeholder에 적용해
    /// 하이라이트한다(복사는 #6b-1 selectedText가 그 span으로 host 추출). `op`는 고정 리터럴("word"/"line"). 선택 없으면 null.
    pub fn selectContentAware(self: *RemoteRuntime, op: []const u8, row: u16, col: u16) client_mod.ClientError!?terminal.SelectionSpan {
        if (!self.mutationAllowed()) return error.Unauthorized;
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"op\":\"{s}\",\"row\":{d},\"col\":{d}}}", .{ self.attachment.streamId(), op, row, col }) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.select_op", params);
        defer self.allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"sel\":true") == null) return null; // 빈 선택(공백 셀 등).
        const sr = client_mod.extractU64Field(resp, "\"sr\":") orelse return null;
        const sc = client_mod.extractU64Field(resp, "\"sc\":") orelse return null;
        const er = client_mod.extractU64Field(resp, "\"er\":") orelse return null;
        const ec = client_mod.extractU64Field(resp, "\"ec\":") orelse return null;
        const block = std.mem.indexOf(u8, resp, "\"block\":true") != null;
        return .{ .start = .{ .row = @intCast(sr), .col = @intCast(sc) }, .end = .{ .row = @intCast(er), .col = @intCast(ec) }, .block = block };
    }

    /// host-authoritative core command를 strict bounded codec으로 보낸다. 구 host는 scroll 4종만 이해하므로 capability가
    /// 없는 연결에는 그 legacy subset만 보내고 focus/config/prompt는 unknown RPC를 시험하지 않고 degraded no-op으로 둔다.
    pub fn sendCoreCommandBlocking(self: *RemoteRuntime, command: core_command_wire.Command) client_mod.ClientError!void {
        if (!self.mutationAllowed()) return error.Unauthorized;
        if (!shouldSendCoreCommand(self.client.runtime_core_command_v1, command)) return;
        const params = core_command_wire.encodeParams(self.allocator, self.attachment.streamId(), command) catch return error.OutOfMemory;
        defer self.allocator.free(params);
        const resp = try self.callOrdered("runtime.core_command", params);
        self.allocator.free(resp);
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): 마우스 이벤트를 host로 보내 host core가 자기 mouse_tracking/format으로
    /// SGR 리포트를 인코딩·PTY 주입하게 한다. 인코딩 모드가 host에만 있어 client는 raw 이벤트만 전달한다(방식 B).
    pub fn sendMouseReport(self: *RemoteRuntime, m: maru.session.core_command.MouseReport) client_mod.ClientError!void {
        if (!self.mutationAllowed()) return error.Unauthorized;
        var buf: [192]u8 = undefined;
        const params = std.fmt.bufPrint(
            &buf,
            "{{\"stream_id\":{d},\"button\":{d},\"col\":{d},\"row\":{d},\"x_px\":{d},\"y_px\":{d},\"pressed\":{},\"motion\":{},\"mods\":{d}}}",
            .{ self.attachment.streamId(), m.button, m.col, m.row, m.x_px, m.y_px, m.pressed, m.motion, m.mods },
        ) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.report_mouse", params);
        self.allocator.free(resp);
    }

    /// host에 대기 중인 OSC 9/777 데스크톱 알림을 뺀다(§6.32 — host가 core와 함께 알림을 소유·전달). 없으면 null. host-backed
    /// 터미널의 알림은 host의 `TerminalCore`가 파싱하므로 client가 이걸로 가져와 GUI 알림 funnel에 넣는다(app_session이 surfacing).
    /// 반환 title/body는 caller 소유(Notification.deinit로 회수). 둘 다 빈 값이면(host 대기 없음) null.
    pub fn takeNotification(self: *RemoteRuntime) client_mod.ClientError!?Notification {
        // Capability 없는 same-major 구 host는 runtime_id-only RPC를 exact subscription으로
        // authorize하지 못한다. Observer가 shared pending event를 소비하지 않도록 fail-closed한다.
        if (!self.client.notification_stream_auth_v1) return null;
        var buf: [96]u8 = undefined;
        const params = notificationParams(
            &buf,
            self.attachment.streamId(),
        ) catch return error.OutOfMemory;
        const resp = try self.callOrdered("runtime.notification", params);
        defer self.allocator.free(resp);
        return self.decodeNotificationResponse(resp);
    }

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
    /// fail-close의 폭발 반경(`self.client`는 그 host의 **모든 runtime이 공유**한다)이 정당한 이유는, 정상 경로가 여기로
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
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        defer obj.deinit();
        if (obj.string("error")) |code| {
            if (obj.fields.len != 1 or protocol.ErrorCode.fromWireName(code) == null) {
                self.client.poison(.peer_contract_violation);
                return error.ProtocolError;
            }
            return null;
        }
        const title_src = obj.string("title") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        const body_src = obj.string("body") orelse {
            self.client.poison(.peer_contract_violation);
            return error.ProtocolError;
        };
        if (obj.hasUnknownKey(&.{ "title", "body" })) {
            self.client.poison(.peer_contract_violation);
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
        // lifecycle cleanup은 transient input-frame OOM 때문에 생략하면 안 된다. 가능한 경우 accepted input을 먼저
        // flush하되, 준비 OOM이면 terminate 자체는 계속 시도한다.
        self.flushQueuedInputBlocking() catch |err| if (err != error.OutOfMemory) return;
        const resp = self.client.call("runtime.terminate", params) catch |err| {
            // cleanup request를 만들거나 응답을 추적할 메모리조차 없으면 shared connection을 닫아 host EOF 경로가
            // 모든 attachment/controller lease를 회수하게 한다.
            if (err == error.OutOfMemory) self.client.poison(.local_resource_exhausted);
            return;
        };
        self.allocator.free(resp);
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
        if (self.attachment.streamId() == 0) return;
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.attachment.streamId()}) catch return;
        // controller lease 해제는 큐에 남은 입력보다 **우선한다**. 그래서 flush가 실패해도 detach를 건너뛰지 않는다.
        //
        // 이전에는 OOM이 아닌 실패(예: `AdminBusy`)면 곧바로 return해 detach RPC를 보내지 않았는데, 근거였던
        // "hard connection error면 어차피 EOF detach된다"가 **shared connection에서는 성립하지 않는다**
        // (`detachClientSide` 주석: 앱 종료 전까지 EOF가 오지 않는다). 그래서 lease가 host에 그대로 남아 다음
        // attach가 `controller_busy`가 되고, 사용자는 입력이 안 되는 터미널을 보게 된다. connection이 이미
        // 죽었다면 아래 detach도 실패할 뿐이라 시도 자체는 무해하다.
        self.flushQueuedInputBlocking() catch |err| {
            if (err == error.OutOfMemory) {
                self.client.poison(.local_resource_exhausted);
            } else if (err == error.AdminBusy) {
                // No retry owner remains after teardown. Closing the shared connection lets host
                // EOF release every lease without sending pre-revoke mutation wire.
                self.client.poison(.attachment_cleanup_failed);
            }
            logDetachIncomplete("flush", err);
            return;
        };
        const resp = self.client.call("runtime.detach", params) catch |err| {
            if (err == error.OutOfMemory) {
                self.client.poison(.local_resource_exhausted);
            } else if (err == error.AdminBusy) {
                // The latch may appear after the preflight turn. No teardown retry owner remains,
                // so preserve revoke-before-wire ordering by converging through host EOF cleanup.
                self.client.poison(.attachment_cleanup_failed);
            }
            logDetachIncomplete("detach", err);
            return;
        };
        self.allocator.free(resp);
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
    client: *client_mod.Client,
    allocator: std.mem.Allocator,
    payload: []const u8,
) client_mod.ClientError!void {
    control_response_wire.decodeResyncEnvelope(allocator, payload) catch |err| {
        if (err != error.OutOfMemory) client.poison(.peer_contract_violation);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProtocolError,
        };
    };
}

fn shouldSendCoreCommand(runtime_core_command_v1: bool, command: core_command_wire.Command) bool {
    return runtime_core_command_v1 or command.isLegacyScroll();
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
    runtime.client = &client;
    runtime.allocator = allocator;
    runtime.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
    runtime.event_generation_tracking = .tracked;
    runtime.runtime_id_hex = "000000000000000000000000000000aa".*;
    runtime.resize_generation = 0;
    runtime.resize_baseline_present = false;
    runtime.observation = .{};
    defer runtime.observation.deinit(allocator);
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
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = -1,
        .host_id = 1,
        .runtime_selected_text_v1 = true,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;

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
    rr.client = &client;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.attachment.deinit();
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.observation, allocator);
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
    try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.observation.ssh_remote_dest.items);
    try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.observation.semantic_state);
    try std.testing.expect(rr.observation.alt_active);
    try std.testing.expect(rr.observation.app_cursor_keys);
    try std.testing.expectEqual(@as(u16, 120), rr.observation.size.cols);
    try std.testing.expectEqual(@as(u16, 40), rr.observation.size.rows);
    try std.testing.expectEqual(@as(?i32, 55), rr.observation.foreground_pgid);
    try std.testing.expectEqual(@as(usize, 1), rr.observation.foreground_processes.items.len);
    try std.testing.expectEqualStrings(
        "claude",
        rr.observation.foreground_processes.items[0].slice(),
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

test "remote runtime: actual GUI attach resource failure closes and preserves existing cache" {
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
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.resize_seq = 0;
    rr.resize_generation = 0;
    rr.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);
    try rr.observation.replace(allocator, .{
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
    try std.testing.expect(adapter.logicalClient().unusable);
    try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
    try std.testing.expectEqualStrings("/safe", rr.observation.cwd.items);
    try std.testing.expectEqualStrings("work", rr.observation.window_title.items);
    try std.testing.expectEqualStrings("safe-host", rr.observation.ssh_remote_dest.items);
}

test "CR3a-2a committed GUI attach rolls back generation ownership when snapshot EOF follows" {
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
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.resize_seq = 0;
    rr.resize_generation = 0;
    rr.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

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
            self.outcome = switch (self.runtime.attachment) {
                .generation => |*value| value.tryDeinit(self.adapter),
                .legacy => .corrupt,
            };
            self.slot_outcome = self.adapter.slot.tryDeinit();
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

test "CR3a-2c1 generation GUI attach applies an initial snapshot through its final owner" {
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
        fn run(fd: c.fd_t, response_wire: []const u8, snapshot_wire: []const u8) void {
            defer _ = c.close(fd);
            const peer_allocator = std.heap.page_allocator;
            const request = readPeerFrame(fd, peer_allocator) catch return;
            defer peer_allocator.free(request.payload);
            if (request.header.kind != .request or
                std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.attach\"") == null)
                return;
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
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.resize_seq = 0;
    rr.resize_generation = 0;
    rr.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    var free_probe = SnapshotFreeReentryProbe{
        .parent = allocator,
        .runtime = &rr,
        .adapter = &adapter,
        .armed = true,
    };
    adapter.slot.current.guarded_allocator.parent = free_probe.allocator();

    try rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
    peer.join();
    try std.testing.expect(free_probe.fired);
    try std.testing.expectEqual(generation_attachment_mod.DeinitOutcome.busy, free_probe.outcome.?);
    try std.testing.expectEqual(
        @import("client_slot.zig").DeinitOutcome.busy,
        free_probe.slot_outcome.?,
    );
    try std.testing.expect(adapter.slot.initialSnapshotPermitIdle());
    try std.testing.expect(rr.usesGenerationAttachment());
    try std.testing.expectEqual(@as(u21, 'x'), rr.attachment.screenPtr().?.grid.cells[0].codepoint);
    rr.surface.deinit();
    rr.attachment.deinitWithAdapter(&adapter);
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
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.resize_seq = 0;
    rr.resize_generation = 0;
    rr.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);
    try rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 });
    peer.join();

    const pending = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 7 },
        "partially-written",
    );
    rr.client.pending_outbound = .{
        .frame = pending,
        .offset = 1,
        .stream_id = 7,
    };
    var event = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{" ++
                "\"runtime_id\":\"000000000000000000000000000000aa\"," ++
                "\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    event.header.payload_len = @intCast(event.payload.len);
    try rr.client.pending_events.append(allocator, event);
    rr.client.pending_event_bytes = event.payload.len;

    try std.testing.expectError(error.ConnectionClosed, rr.drainObservationEvents());
    try std.testing.expect(rr.client.unusable);
    try std.testing.expectEqual(
        @import("client_poison.zig").ConnectionReason.outbound_partial_write,
        rr.client.firstPoisonReason().?,
    );
    try std.testing.expectEqual(remote_attachment.Role.observer, rr.attachment.statePtr().role);
    try std.testing.expectError(error.Unauthorized, rr.sendInputNonBlocking("late"));
    rr.surface.deinit();
    rr.attachment.deinitWithAdapter(&adapter);
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
    rr.client = adapter.logicalClient();
    rr.generation_adapter = &adapter;
    rr.allocator = allocator;
    rr.io = std.testing.io;
    rr.runtime_id_hex = "000000000000000000000000000000aa".*;
    rr.resize_seq = 0;
    rr.resize_generation = 0;
    rr.resize_baseline_present = false;
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    try std.testing.expectError(
        error.Truncated,
        rr.attachAndAssemble(1, .{ .cols = 1, .rows = 1 }),
    );
    peer.join();
    try std.testing.expect(adapter.logicalClient().unusable);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.peer_contract_violation,
        adapter.logicalClient().firstPoisonReason().?,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.slot.current.cleanup_registry.count(),
    );
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
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
        rr.client = &client;
        rr.attachment = .init(allocator, .{
            .runtime_id = 0xaa,
            .stream_id = 7,
            .role = .controller,
            .controller_generation = 1,
        });
        defer rr.attachment.deinit();
        rr.observation = .{};
        try rr.observation.replace(allocator, .{
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
        defer rr.observation.deinit(rr.allocator);
        const drained = rr.drainObservationEvents();
        if (drained) |result| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expect(result.metadata);
            try std.testing.expectEqual(@as(u64, 3), rr.observation.revision);
            try std.testing.expectEqualStrings("/next/repo", rr.observation.cwd.items);
            try std.testing.expect(!client.unusable);
            try std.testing.expect(!failing.has_induced_failure);
            saw_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(usize, 1), parse_count);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.observation.window_title.items);
            try std.testing.expectEqualStrings(
                "safe-host",
                rr.observation.ssh_remote_dest.items,
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
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .metadata_support = .supported,
    };
    defer client.deinit();
    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer rr.attachment.deinit();
    rr.direct_input = .empty;
    defer rr.direct_input.deinit(allocator);
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.pending_controls.deinit(allocator);
    rr.observation = .{};
    defer rr.observation.deinit(allocator);

    try seedMetadataTestObservation(&rr.observation, allocator);

    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        response_payload,
    );
    defer allocator.free(response);
    try socket_server.writeAll(fds[1], response);

    switch (outcome) {
        .current => try rr.refreshObservation(),
        .fail_closed => try std.testing.expectError(
            error.ProtocolError,
            rr.refreshObservation(),
        ),
    }
    const request = try readPeerFrame(fds[1], allocator);
    defer allocator.free(request.payload);
    try std.testing.expectEqual(protocol.Kind.request, request.header.kind);
    try std.testing.expectEqual(@as(u64, 1), request.header.request_id);
    try std.testing.expect(
        std.mem.indexOf(u8, request.payload, "\"method\":\"runtime.observation\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, request.payload, "\"stream_id\":7") != null,
    );

    switch (outcome) {
        .current => {
            try std.testing.expect(!client.unusable);
            try std.testing.expectEqual(fds[0], client.fd);
            try std.testing.expectEqual(term_backend.ObservationAvailability.current, rr.observation.availability);
            try std.testing.expectEqual(@as(u64, 3), rr.observation.revision);
            try std.testing.expectEqualStrings("/fresh", rr.observation.cwd.items);
            try std.testing.expectEqualStrings("fresh-title", rr.observation.window_title.items);
            try std.testing.expectEqualStrings("fresh-host", rr.observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.input, rr.observation.semantic_state);
            try std.testing.expect(!rr.observation.alt_active);
            try std.testing.expect(!rr.observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 90), rr.observation.size.cols);
            try std.testing.expectEqual(@as(u16, 30), rr.observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 77), rr.observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "zsh",
                rr.observation.foreground_processes.items[0].slice(),
            );
        },
        .fail_closed => {
            try std.testing.expect(client.unusable);
            try std.testing.expectEqual(@as(c.fd_t, -1), client.fd);
            try std.testing.expectEqual(@as(u64, 2), rr.observation.revision);
            try std.testing.expectEqualStrings("/safe", rr.observation.cwd.items);
            try std.testing.expectEqualStrings("work", rr.observation.window_title.items);
            try std.testing.expectEqualStrings("safe-host", rr.observation.ssh_remote_dest.items);
            try std.testing.expectEqual(terminal.SemanticPrompt.command, rr.observation.semantic_state);
            try std.testing.expect(rr.observation.alt_active);
            try std.testing.expect(rr.observation.app_cursor_keys);
            try std.testing.expectEqual(@as(u16, 120), rr.observation.size.cols);
            try std.testing.expectEqual(@as(u16, 40), rr.observation.size.rows);
            try std.testing.expectEqual(@as(?i32, 55), rr.observation.foreground_pgid);
            try std.testing.expectEqual(@as(usize, 1), rr.observation.foreground_processes.items.len);
            try std.testing.expectEqualStrings(
                "claude",
                rr.observation.foreground_processes.items[0].slice(),
            );
            var byte: [1]u8 = undefined;
            try std.testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
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
    const snapshot = rr.surface.renderSnapshot();
    try std.testing.expectEqual(@as(u16, 4), snapshot.size.cols);
    try std.testing.expectEqual(@as(u21, 'o'), snapshot.cells[0].codepoint);
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
        try std.testing.expectEqual(@as(u64, 4), rr.observation.revision);
        try std.testing.expectEqualStrings("/base", rr.observation.cwd.items);
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
                try std.testing.expectEqual(@as(u64, 4), rr.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.observation.cwd.items);
                try std.testing.expect(!client.unusable);
            },
            .newer => {
                const result = try rr.drainObservationEvents();
                try std.testing.expect(result.metadata);
                try std.testing.expectEqual(@as(u64, 5), rr.observation.revision);
                try std.testing.expectEqualStrings("/new", rr.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "new-host",
                    rr.observation.ssh_remote_dest.items,
                );
                try std.testing.expect(!client.unusable);
            },
            .conflict => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.observation.ssh_remote_dest.items,
                );
            },
            .sealed_revision_mutation, .sealed_header_mutation => {
                try std.testing.expectError(error.ProtocolError, rr.drainObservationEvents());
                try std.testing.expect(client.unusable);
                try std.testing.expectEqual(@as(u64, 4), rr.observation.revision);
                try std.testing.expectEqualStrings("/base", rr.observation.cwd.items);
                try std.testing.expectEqualStrings(
                    "base-host",
                    rr.observation.ssh_remote_dest.items,
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
        try std.testing.expectEqual(@as(u64, 5), rr.resize_generation);
        try std.testing.expectEqual(
            terminal.Size{ .cols = 100, .rows = 40 },
            rr.observation.size,
        );
        rr.detachClientSide();
    }
}

test "remote runtime observer locally consumes input and sends no resize mutation" {
    var runtime: RemoteRuntime = undefined;
    runtime.attachment = .init(testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    });
    runtime.event_generation_tracking = .tracked;
    defer runtime.attachment.deinit();
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
    runtime.client = &client;
    runtime.allocator = allocator;
    runtime.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.event_generation_tracking = .tracked;
    defer runtime.attachment.deinit();
    runtime.direct_input = .empty;
    defer runtime.direct_input.deinit(allocator);
    try runtime.direct_input.appendSlice(allocator, "queued");
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    defer runtime.pending_controls.deinit(allocator);
    try runtime.pending_controls.append(allocator, .{
        .barrier = 6,
        .op = .scroll_to_bottom,
    });
    runtime.observation = .{};

    const drained = try runtime.drainObservationEvents();
    try testing.expect(drained.metadata);
    try testing.expectEqual(remote_attachment.Role.observer, runtime.attachment.statePtr().role);
    try testing.expectEqual(@as(u64, 4), runtime.attachment.statePtr().controller_generation);
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
    runtime.client = &client;
    runtime.allocator = allocator;
    runtime.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 0,
    });
    defer runtime.attachment.deinit();
    runtime.event_generation_tracking = .untracked;
    runtime.observation = .{};

    try testing.expectError(error.ProtocolError, runtime.drainObservationEvents());
    try testing.expect(client.unusable);
    try testing.expectEqual(remote_attachment.Role.controller, runtime.attachment.statePtr().role);
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
    var revoke = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 7 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    revoke.header.payload_len = @intCast(revoke.payload.len);
    try client.pending_events.append(allocator, revoke);
    client.pending_event_bytes = revoke.payload.len;

    var runtime: RemoteRuntime = undefined;
    runtime.client = &client;
    runtime.allocator = allocator;
    runtime.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    runtime.event_generation_tracking = .tracked;
    defer runtime.attachment.deinit();
    runtime.direct_input = .empty;
    defer runtime.direct_input.deinit(allocator);
    runtime.direct_input_offset = 0;
    runtime.pending_controls = .empty;
    defer runtime.pending_controls.deinit(allocator);

    // Role cache는 아직 controller지만 own-stream revoke가 먼저 도착했으므로 SurfaceRuntime가
    // InputSuppressed로 바꿀 Unauthorized를 반환하고 queue/wire ownership을 만들지 않는다.
    try testing.expect(runtime.attachment.allowsMutation());
    try testing.expect(client.hasBufferedControllerRevokeForStream(7));
    try testing.expect(!client.hasBufferedControllerRevokeForStream(8));
    try testing.expectError(error.Unauthorized, runtime.sendInput("key"));
    try testing.expectError(error.Unauthorized, runtime.sendInputNonBlocking("paste"));
    try testing.expectEqual(@as(usize, 0), runtime.direct_input.items.len);
    try testing.expect(client.pending_outbound == null);
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
    var revoke = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 8 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"stream_id\":8,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    revoke.header.payload_len = @intCast(revoke.payload.len);
    try client.pending_events.append(allocator, revoke);
    client.pending_event_bytes = revoke.payload.len;

    var sibling: RemoteRuntime = undefined;
    sibling.client = &client;
    sibling.allocator = allocator;
    sibling.io = testing.io;
    sibling.attachment = .init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    defer sibling.attachment.deinit();
    sibling.direct_input = .empty;
    defer sibling.direct_input.deinit(allocator);
    try sibling.direct_input.appendSlice(allocator, "preserve-me");
    sibling.direct_input_offset = 0;
    sibling.pending_controls = .empty;
    defer sibling.pending_controls.deinit(allocator);
    sibling.resync_needed = false;
    sibling.observation = .{};

    // A foreign-stream revoke blocks shared wire progress, not local admission for this still-
    // controller sibling. The input remains owned by its bounded queue until stream 8 consumes.
    try sibling.sendInput("-new");
    try testing.expectEqual(RemoteRuntime.PumpResult.idle, try sibling.pumpDelta());
    try testing.expectEqualStrings("preserve-me-new", sibling.direct_input.items);
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
    var offset: usize = 0;
    while (offset < out.len) {
        const rc = c.read(fd, out[offset..].ptr, out.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return error.TestUnexpectedResult;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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

test "remote runtime control cap overflow fail-closes instead of silently losing final state" {
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);
    for (0..RemoteRuntime.max_pending_controls) |_| {
        try rr.pending_controls.append(allocator, .{
            .barrier = 0,
            .op = .{ .core_command = .{ .report_focus = true } },
        });
    }
    try testing.expectError(error.ConnectionClosed, rr.queueCoreCommand(.{ .report_focus = false }));
    try testing.expect(client.unusable);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "remote runtime control allocation failure also fail-closes instead of silently losing final state" {
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
    rr.client = &client;
    rr.allocator = failing.allocator();
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 10, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 11, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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
    defer rr.direct_input.deinit(allocator);
    rr.pending_controls = .empty;
    defer rr.pending_controls.deinit(allocator);
    try rr.direct_input.appendSlice(allocator, "ABC");
    rr.direct_input_offset = 1;
    try rr.pending_controls.append(allocator, .{ .barrier = 2, .op = .scroll_to_bottom });
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 13, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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

test "remote runtime lifecycle cleanup fail-closes the connection on persistent allocator OOM" {
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 17, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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

test "CR3a-2c3a detach fail-closes buffered revoke without flushing pending mutation wire" {
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
    var revoke = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 17 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"00000000000000000000000000000001\",\"stream_id\":17,\"controller_generation\":2,\"reason\":\"takeover\"}}",
        ),
    };
    revoke.header.payload_len = @intCast(revoke.payload.len);
    try client.pending_events.append(allocator, revoke);
    client.pending_event_bytes = revoke.payload.len;
    const pending = try allocator.dupe(u8, "must-not-reach-peer");
    client.pending_outbound = .{ .frame = pending, .stream_id = 17 };

    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.attachment = .init(testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 17,
        .role = .controller,
        .controller_generation = 1,
    });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
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
        metadata_found = std.mem.eql(u8, rr.observation.cwd.items, "/tmp/remote-meta");
        if (!metadata_found) _ = usleep(20 * 1000);
    }
    try testing.expect(metadata_found);
    try testing.expectEqualStrings("remote-title", rr.observation.window_title.items);
    try testing.expect(rr.observation.ssh_remote_dest_present);
    try testing.expectEqualStrings("user@workbox", rr.observation.ssh_remote_dest.items);

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
    try testing.expect(rr1.attachment.streamId() != rr2.attachment.streamId()); // 공유 connection이지만 stream이 갈린다.

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
    rt.client = &client;
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
        bad_rt.client = &bad_client;
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
    rt.client = &client;
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
        bad_rt.client = &bad_client;
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
            rt.client = &client;
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
            rt.client = &client;
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
        if (try rr.client.readStreamBatch(rr.attachment.streamId())) |batch| {
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    const drained = try rr.drainObservationEvents();
    try testing.expect(!drained.metadata);
    try testing.expect(!drained.ended);
    try testing.expect(rr.resync_needed);
    try rr.pumpResyncIntent();
    try testing.expect(!rr.resync_needed);
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
    var foreign_revoke = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 10 },
        .payload = try allocator.dupe(
            u8,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":10,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        ),
    };
    foreign_revoke.header.payload_len = @intCast(foreign_revoke.payload.len);
    // 내 pane(stream 9)은 화면을 회수당했다.
    var invalidated = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 9 },
        .payload = try allocator.dupe(u8, "{\"event\":\"snapshot.invalidated\"}"),
    };
    invalidated.header.payload_len = @intCast(invalidated.payload.len);
    try client.pending_events.append(allocator, foreign_revoke);
    try client.pending_events.append(allocator, invalidated);
    client.pending_event_bytes = foreign_revoke.payload.len + invalidated.payload.len;

    var rr: RemoteRuntime = undefined;
    rr.client = &client;
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    // 내 무효화는 소비되어 resync 의도가 걸린다.
    _ = try rr.drainObservationEvents();
    try testing.expect(rr.resync_needed);
    // 남의 revoke는 여전히 버퍼에 남아 있다 — 소비할 주인은 stream 10의 runtime이다.
    try testing.expect(client.hasBufferedControllerRevoke());

    // 소켓은 멀쩡하고 보낼 입력도 없는데, 남의 latch 하나가 내 진행을 막는다.
    try testing.expect(!(try rr.pumpQueuedInput()));
    // 그래서 `pumpDelta`는 여기서 조기 반환하고 resync는 전송 시도조차 되지 않는다.
    try testing.expect(rr.resync_needed);
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
    var ended = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 9 },
        .payload = try allocator.dupe(u8, "{\"event\":\"runtime.ended\"}"),
    };
    ended.header.payload_len = @intCast(ended.payload.len);
    var sibling = client_mod.BufferedEvent{
        .header = .{ .kind = .event, .stream_id = 10 },
        .payload = try allocator.dupe(u8, "{\"event\":\"runtime.ended\"}"),
    };
    sibling.header.payload_len = @intCast(sibling.payload.len);
    try client.pending_events.append(allocator, ended);
    try client.pending_events.append(allocator, sibling);
    client.pending_event_bytes = ended.payload.len + sibling.payload.len;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.pump_ended = false;
    rr.resync_needed = false;
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
    rr.client = &client;
    rr.allocator = allocator;
    rr.io = testing.io;
    rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 9, .role = .controller, .controller_generation = 1 });
    rr.direct_input = .empty;
    rr.direct_input_offset = 0;
    rr.pending_controls = .empty;
    rr.resync_needed = false;
    defer rr.direct_input.deinit(allocator);
    defer rr.pending_controls.deinit(allocator);

    _ = try rr.drainObservationEvents();
    try rr.pumpResyncIntent();
    try testing.expect(rr.resync_needed);
    try testing.expect(client.pending_outbound != null);

    const filler = try allocator.alloc(u8, filled);
    defer allocator.free(filler);
    try readRemoteTestExact(fds[1], filler);
    try testing.expect(try client.pumpPendingOutput());
    const older = try readPeerFrame(fds[1], allocator);
    defer allocator.free(older.payload);
    try testing.expectEqual(protocol.Kind.input_bytes, older.header.kind);

    try rr.pumpResyncIntent();
    try testing.expect(!rr.resync_needed);
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
