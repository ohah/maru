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
//! DECCKM/DECKPAM/kitty mode와 selection autoscroll/전체 선택 parity는 후속 gate다. macOS 전용(client·Surface·app 계약).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_runtime = @import("remote_runtime.zig");
const close_authority = @import("remote_close_authority.zig");
const close_contract = @import("remote_close_contract.zig");
const event_pump_contract = @import("remote_event_pump_contract.zig");
const process_seal = @import("process_seal_service.zig");
const pending_event_owner = @import("pending_event_owner.zig");
const core_command_wire = @import("core_command_wire.zig");
const host_pool_mod = @import("host_pool.zig");
const host_adapter_mod = @import("host_adapter.zig");
const shutdown_attempt = @import("shutdown_attempt_authority.zig");
const shutdown_connector = @import("shutdown_admin_connector.zig");
const shutdown_current_admin = @import("shutdown_current_admin.zig");
const client_deadline = @import("client_deadline.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령 라우팅

const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const TermRuntimeBackend = term_backend.TermRuntimeBackend;
const RuntimeHandle = term_backend.RuntimeHandle;
const SpawnParams = term_backend.SpawnParams;
const RuntimeLink = maru.app.RuntimeLink;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const PtyIo = maru.app.runtime.PtyIo;
const runtime_pump = maru.app.runtime_pump;
const RuntimeEventPump = runtime_pump.RuntimeEventPump;
const DrainSummary = runtime_pump.DrainSummary;
const CoreCommand = maru.session.core_command.CoreCommand;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;
const nonblocking_input_chunk: usize = 16 * 1024;
const RemoteRuntime = remote_runtime.RemoteRuntime;
const HostAdapter = host_adapter_mod.HostAdapter;
const AdapterPool = host_pool_mod.HostPool(HostAdapter);
pub const max_remote_backend_runtimes: usize = 4096;

const B5TestState = if (builtin.is_test) struct {
    threadlocal var scan_hook: ?*const fn (*RemoteTermBackend) void = null;
    threadlocal var skip_destroy: bool = false;
    threadlocal var event_pump_hook: ?*const fn (RuntimeHandle, *RemoteRuntime) DrainSummary = null;
    threadlocal var app_quit_routing_target_count: usize = 0;
    threadlocal var app_quit_runtime_count_at_terminalize: usize = 0;
    threadlocal var app_quit_runtime_count_at_owner_settlement: usize = 0;
    threadlocal var app_quit_pending_idle_count: usize = 0;
    threadlocal var app_quit_source_zero_count: usize = 0;
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
    const Mode = enum {
        spawn_and_attach,
        attach_only,
    };

    const RuntimeEntry = struct {
        runtime: *RemoteRuntime,
        host_id: u128,
        runtime_generation: u64,
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
    app_quit_routing_tombstoned: bool = false,
    app_quit_connections_terminalized: bool = false,
    app_quit_owner_graphs_settled: bool = false,
    app_quit_shutdown_started_at_ns: u64 = 0,
    app_quit_shutdown_deadline_ns: u64 = 0,
    app_quit_first_ticket: u64 = 0,
    app_quit_target_count: u32 = 0,
    next_shutdown_connection_identity: u64 = 0,

    const vtable = term_backend.VTable{
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

    /// 남은 원격 runtime을 회수한다(각각 라우팅 표에서 detach + host terminate + client-side deinit). client connection과
    /// surface_runtime은 borrowed라 안 건드린다(소유는 caller).
    pub fn deinit(self: *RemoteTermBackend) void {
        var it = self.runtimes.iterator();
        while (it.next()) |kv| {
            self.destroyRuntimeEntry(kv.key_ptr.*, kv.value_ptr.*, .terminate);
        }
        self.runtimes.deinit(self.allocator);
        if (self.reserved_runtime_count != 0 or self.close_operation_owner.active)
            process_seal.fatalIntegrity(.proof_loss);
        self.releaseProductSingleton();
        self.* = undefined;
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
        remote_backend_singleton_generation = generation;
        remote_backend_singleton_addr = @intFromPtr(self);
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
            if (row.value_ptr.runtime.frame_summary_ready) return;
        }
        var handles: [max_remote_backend_runtimes]RuntimeHandle = undefined;
        var handle_count: usize = 0;
        var iterator = self.runtimes.iterator();
        while (iterator.next()) |row| {
            row.value_ptr.runtime.frame_summary = .{};
            row.value_ptr.runtime.frame_summary_ready = true;
            handles[handle_count] = row.key_ptr.*;
            handle_count += 1;
        }
        if (handle_count == 0) {
            self.event_pump_cursor = 0;
            return;
        }
        std.mem.sort(RuntimeHandle, handles[0..handle_count], {}, std.sort.asc(RuntimeHandle));
        if (self.event_pump_cursor >= handle_count) self.event_pump_cursor = 0;
        const selected_count = @min(handle_count, event_pump_contract.max_owners_per_frame);
        _ = event_pump_contract.frameBudget(
            selected_count,
            selected_count * event_pump_contract.retained_parts_per_owner * protocol.max_control_json,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        for (0..selected_count) |offset| {
            const index = (self.event_pump_cursor + offset) % handle_count;
            const entry = self.runtimes.get(handles[index]) orelse
                process_seal.fatalIntegrity(.proof_loss);
            entry.runtime.frame_summary = if (builtin.is_test and B5TestState.event_pump_hook != null)
                B5TestState.event_pump_hook.?(handles[index], entry.runtime)
            else
                drainRemoteNow(entry.runtime);
        }
        self.event_pump_cursor = event_pump_contract.nextCursor(
            self.event_pump_cursor,
            handle_count,
            selected_count,
        ) catch process_seal.fatalIntegrity(.proof_loss);
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
        if (self.app_quit_routing_tombstoned or now_ns <= 0 or now_ns > std.math.maxInt(u64)) return false;
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
            break :blk adapter.logicalClient();
        } else if ((self.client orelse return error.HostNotFound).host_id == host_id)
            self.client.?
        else
            return error.HostNotFound;
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        if (selected_adapter) |adapter|
            try rr.attachExistingWithAdapter(adapter, self.allocator, self.io, handle, runtime_id_hex, size)
        else
            try rr.attachExisting(selected_client, self.allocator, self.io, handle, runtime_id_hex, size);
        // 재접속은 **기존** host runtime이라 이후 단계(map put)가 실패해도 terminate 금지(§7 attach는 terminate 안 함) —
        // client-side(surface/screen)만 회수한다. spawn 경로는 방금 우리가 띄운 runtime이라 deinit(terminate)이 맞지만
        // attach는 남의 runtime이므로 detachClientSide로 되돌려야 재접속 실패가 세션을 죽이지 않는다.
        errdefer rr.detachClientSide();
        try self.runtimes.put(self.allocator, handle, .{
            .runtime = rr,
            .host_id = host_id,
            .runtime_generation = try self.issueRuntimeGeneration(),
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

    /// 이 handle이 controller를 못 얻고 observer로 붙었는가(§9 — 두 번째 controller는 조용히 강등된다).
    /// host-backed가 아니면 false다. GUI가 "화면은 나오는데 입력이 안 된다"를 사용자에게 설명하는 근거다.
    pub fn attachedAsObserver(self: *RemoteTermBackend, handle: RuntimeHandle) bool {
        const entry = self.runtimes.get(handle) orelse return false;
        return entry.runtime.attachedAsObserver();
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
    pub fn selectedTextFor(self: *RemoteTermBackend, handle: RuntimeHandle, span: maru.terminal.SelectionSpan) ?[]u8 {
        const entry = self.runtimes.get(handle) orelse return null;
        return (entry.runtime.selectedText(span) catch return null) orelse null;
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
    pub fn clipboardWriteFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?remote_runtime.RemoteRuntime.ClipboardWrite {
        const entry = self.runtimes.get(handle) orelse return null;
        return (entry.runtime.clipboardWrite() catch return null) orelse null;
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
            break :blk adapter.logicalClient();
        } else blk: {
            const client = self.client orelse return error.HostNotFound;
            selected_host_id = client.host_id;
            break :blk client;
        };
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        const request = persistentSpawnRequest(params.request);
        if (selected_adapter) |adapter|
            try rr.spawnWithAdapter(adapter, self.allocator, self.io, params.handle, request, params.size, params.initial_config)
        else
            try rr.spawnWithConfig(selected_client, self.allocator, self.io, params.handle, request, params.size, params.initial_config);
        errdefer rr.deinit(); // spawn 성공 후 map 삽입이 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지).
        try self.runtimes.put(self.allocator, params.handle, .{
            .runtime = rr,
            .host_id = selected_host_id,
            .runtime_generation = try self.issueRuntimeGeneration(),
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
        if (rr.frame_summary_ready) {
            const summary = rr.frame_summary;
            rr.frame_summary = .{};
            rr.frame_summary_ready = false;
            return summary;
        }
        return drainRemoteNow(rr);
    }

    fn drainRemoteNow(rr: *RemoteRuntime) DrainSummary {
        var summary: DrainSummary = .{};
        if (rr.pump_ended) return summary;
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
                        rr.pump_ended = true;
                        rr.surface.process_state = .exited;
                        summary.ended = .{ .read_error = @errorName(err) };
                        break;
                    },
                }
            };
            switch (result) {
                .idle => break,
                .event_pending => break,
                .metadata => continue,
                .screen => summary.output_events += 1,
                .ended => {
                    rr.pump_ended = true;
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
        try remote_runtime.testing_api.initializePendingOwners(&rr);
        rr.client = &client;
        rr.allocator = allocator;
        rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        rr.direct_input_offset = 0;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.pump_ended = false;
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
        try remote_runtime.testing_api.initializePendingOwners(&rr);
        rr.client = &client;
        rr.generation_adapter = null;
        rr.allocator = allocator;
        rr.io = std.testing.io;
        rr.runtime_id_hex = "00000000000000000000000000000001".*;
        rr.attachment = .init(testing.allocator, .{ .runtime_id = 1, .stream_id = 7, .role = .controller, .controller_generation = 1 });
        rr.resize_seq = 0;
        rr.direct_input = .empty;
        defer rr.direct_input.deinit(allocator);
        rr.direct_input_offset = 0;
        rr.pending_controls = .empty;
        defer rr.pending_controls.deinit(allocator);
        rr.blocking_flush_active = false;
        rr.pump_ended = false;
        rr.resync_needed = false;
        rr.observation = .{};
        defer rr.observation.deinit(allocator);
        rr.event_generation_tracking = .tracked;
        rr.resize_generation = 0;
        rr.resize_baseline_present = false;
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
        const entry = self.runtimes.get(handle) orelse return;
        if ((self.app_quit_routing_tombstoned or self.app_quit_connections_terminalized) and
            !self.app_quit_owner_graphs_settled)
            process_seal.fatalIntegrity(.proof_loss);

        // Runtime owner와 attachment graph를 map membership이 살아 있는 동안 먼저 닫는다. 이 호출 뒤에는 callback과
        // fallible 작업이 없으며, exact row를 제거한 다음 allocation과 host lease만 마지막으로 회수한다.
        const generation_adapter = entry.runtime.generation_adapter;
        self.surface_runtime.detachSurface(handle);
        entry.runtime.detachClientSide();
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
        if (rr.observation.availability != .current or !rr.observation.foreground_available) return null;
        return rr.observation.foreground_pgid;
    }

    /// host-backed 터미널의 자원 표본은 **아직 없다**(docs/status-bar.md §6 "keep-alive를 켜면 터미널이 0이 된다").
    /// PTY가 host 프로세스 안에 있어 앱에서 트리를 훑을 수 없고, host가 `live_child_pid`를 들고 있으므로
    /// 나중에 이 함수를 RPC로 채우면 된다 — 그때 재설계가 아니라 구멍 메우기다. 지금은 0이라 항목이 안 뜬다
    /// (0을 그리면 "터미널이 메모리를 안 쓴다"는 거짓말이 된다).
    fn resourceSamples(ctx: *anyopaque, handle: RuntimeHandle, out: []maru.session.resource_usage.Sample) usize {
        _ = ctx;
        _ = handle;
        _ = out;
        return 0;
    }

    /// **원격 runtime은 커널 cwd 폴백이 없다.** PTY와 그 자식 프로세스가 host 데몬 프로세스에 살아서 GUI
    /// 프로세스의 `proc_pidinfo`가 닿지 않는다(pid 네임스페이스가 아니라 소유 프로세스가 다른 문제다).
    /// 그래서 원격 Term의 cwd는 host가 observation으로 실어 보내는 OSC 7 값이 유일한 출처다 — bash/fish나
    /// TUI가 화면을 리셋한 뒤에는 비어 있을 수 있다. 메우려면 host가 관측 payload에 cwd를 더해야 하고 그건
    /// wire schema 변경이라 docs/session-host-upgrade.md의 호환 규약을 건드린다(별도 슬라이스).
    fn processCwd(ctx: *anyopaque, handle: RuntimeHandle, out: []u8) ?[]const u8 {
        _ = ctx;
        _ = handle;
        _ = out;
        return null;
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []ForegroundProcessName) usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return 0).runtime;
        if (rr.observation.availability != .current or !rr.observation.foreground_available) return 0;
        const count = @min(out.len, rr.observation.foreground_processes.items.len);
        @memcpy(out[0..count], rr.observation.foreground_processes.items[0..count]);
        return count;
    }

    fn readObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground; // host event가 bounded cadence로 foreground까지 coherent하게 갱신한다.
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        if (out.availability == rr.observation.availability and
            out.revision == rr.observation.revision and
            out.size.cols == rr.observation.size.cols and
            out.size.rows == rr.observation.size.rows)
            return;
        try out.replace(allocator, rr.observation.view());
    }

    fn refreshObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground;
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        try rr.refreshObservation();
        try out.replace(allocator, rr.observation.view());
    }

    fn dumpRecentText(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = (self.runtimes.get(handle) orelse return error.UnknownSurface).runtime;
        return rr.attachment.screenPtr().?.dumpRecentTextUtf8(allocator, self.io, max_rows, max_bytes);
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
            .reset_input_modes => try rr.queueCoreCommand(.reset_input_modes),
            // §6b-1 드래그 선택: 하이라이트 span은 client 좌표라 **placeholder core에 적용해 즉시** 반영한다(렌더가 이미
            // surface.core.selectionViewportSpan을 읽음 — 새 렌더 배선/span-push 불요, 왕복 지연 없음). 복사(콘텐츠 연산)는
            // app_session.copyText가 이 span을 host로 보내 host의 extractSelection으로 한다(선택 의미론=host 단일 출처).
            // 콘텐츠 인지 경계(word/line)는 빈 placeholder에선 부정확하므로 후속(#6b-2, host 계산). scroll_and_extend(autoscroll
            // 드래그)도 후속. select_all은 placeholder 뷰포트 전체 선택 → 보이는 화면 복사(host가 스크롤백까지는 후속).
            // select_clear도 같은 분류다 — 하이라이트가 placeholder에 있으니 해제도 placeholder에서 한다(host 왕복 불요).
            .select_start, .select_extend, .select_extend_or_collapse, .select_all, .select_clear => core_command.apply(&rr.surface.core, cmd),
            // §6b-2 단어/줄 선택: 콘텐츠 인지 경계는 빈 placeholder가 모르므로 **host가 계산해 span을 돌려준다**(selectContentAware).
            // 그 span을 placeholder에 적용해 하이라이트(렌더가 selectionViewportSpan을 읽음). 복사는 #6b-1이 그 span으로 host 추출.
            .select_word => |s| {
                if (rr.selectContentAware("word", s.row, s.col) catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            .select_line => |row| {
                if (rr.selectContentAware("line", row, 0) catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            // host scroll과 client-local highlight를 한 transaction으로 묶는 wire가 아직 없어 별도 selection parity slice가
            // 소유한다. 명시 분기로 남겨 새 command 누락과 구분한다.
            .scroll_and_extend => {},
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
    return request;
}

test "persistent spawn omits process-local MARU_PANE_ID without mutating local fallback request" {
    const local: maru.pty.SpawnRequest = .{ .command = "/bin/zsh", .pane_id = 42 };
    const persistent = persistentSpawnRequest(local);
    try std.testing.expectEqual(@as(?u64, 42), local.pane_id);
    try std.testing.expectEqual(@as(?u64, null), persistent.pane_id);
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
    probe.target_addr = @intFromPtr(fixture.runtime.observation.cwd.items.ptr);
    probe.target_len = fixture.runtime.observation.cwd.items.len;
    probe.armed = true;

    try testing.expectEqual(term_backend.CloseProgress.complete, backend_value.backend().finishAfterTermination(42));
    try testing.expectEqual(@as(usize, 1), probe.callback_count);
    try testing.expect(probe.saw_committed_cleanup);
    try testing.expectEqual(term_backend.RemoveProgress.event_pending, probe.reentrant_remove.?);
    try testing.expect(backend_value.runtimes.contains(42));
    try testing.expectEqual(term_backend.RemoveProgress.removed, RemoteTermBackend.remove(&backend_value, 42));
    try testing.expect(!backend_value.runtimes.contains(42));
}

test "C3-3b4 remote backend는 실제 host runtime을 TermRuntimeBackend 계약으로 구동한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (std.c.getenv("MARU_SESSION_HOST_REMOTE_BACKEND_REAL_HOST")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "skip-in-aggregate-v1")) return error.SkipZigTest;
    }
    try HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rtb-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
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
        _ = c.rmdir(dir_path.ptr);
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
    var frame_pump = try be.pump(1); // 원격 모드 RuntimeEventPump.

    // **핵심**: GUI 키 입력 hot path와 **똑같이** self.runtime.writeInput(surface.id, ...)로 보낸다 — 계약 vtable을 우회해도
    // 원격 PtyIo→client.sendInput→host로 라우팅된다(app_session 무변경으로 원격 입력이 도달함을 증명). host가 echo → delta →
    // pump.drainAvailable()(원격 drain)로 소비해 Surface에 "h"가 반영되는지 폴링(host delta tick ~20ms).
    try surface_runtime.writeInput(1, .{ .bytes = "hello\n" });
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        const ds = try frame_pump.drainAvailable();
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') {
            found = true;
            try testing.expect(ds.output_events > 0); // 배치가 적용된 tick은 렌더 트리거를 낸다.
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // hot path(SurfaceRuntime)를 통한 원격 입력이 host를 거쳐 Surface에 반영됐다.

    // resize도 hot path(self.runtime.resize)로 원격 PtyIo→resize RPC에 도달한다(에러 없이 위임).
    try surface_runtime.resize(1, .{ .cols = 80, .rows = 24 }, io);

    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(1));
    try testing.expectEqual(term_backend.RemoveProgress.removed, be.remove(1)); // client-side 회수(map 제거 + SurfaceRuntime detach + host terminate 멱등).
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
    try HostAdapter.initializeProcessRuntime();
    const allocator = testing.allocator;
    const io = testing.io;

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
    try testing.expectError(error.HostInUse, pool.remove(host_a));
    const runtime_a_id = be_impl.runtimeIdFor(11).?;

    var pump_b = try be.pump(22);
    try surface_runtime.writeInput(22, .{ .bytes = "before\n" });
    var saw_before = false;
    var attempts: usize = 0;
    while (attempts < 100 and !saw_before) : (attempts += 1) {
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
    try testing.expectEqual(host_a, be_impl.runtimeHostId(33).?);
    try testing.expectEqual(host_b, be_impl.runtimeHostId(22).?);
    try surface_runtime.writeInput(22, .{ .bytes = "after\n" });
    var saw_after = false;
    attempts = 0;
    while (attempts < 100 and !saw_after) : (attempts += 1) {
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
    remote_runtime.testing_api.armSettlementContention(1);
    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(33));
    try testing.expectEqual(term_backend.CloseProgress.event_pending, be.closeAndDetach(22));
    try testing.expectEqual(@as(u8, @intFromEnum(close_authority.Lifecycle.settling)), be_impl.runtimes.get(22).?.runtime.close_authority.lifecycle_raw);
    try testing.expectEqual(
        @intFromEnum(pending_event_owner.PendingLifecycle.prepared),
        be_impl.runtimes.get(22).?.runtime.pending_event_owner.lifecycle_raw,
    );
    // 실제 frame은 close 재시도 전에 semantic pump를 돌린다. terminate가 만든 runtime.ended까지
    // 관측해야 느린 runner에서도 queued event를 남긴 채 Runtime을 제거하지 않는다.
    var saw_close_ended = false;
    attempts = 0;
    while (attempts < 100 and !saw_close_ended) : (attempts += 1) {
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
    try testing.expectEqual(term_backend.CloseProgress.complete, be.closeAndDetach(22));
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
            self.runtimes[index].frame_summary_ready = false;
            self.runtimes[index].frame_summary = .{};
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
            self.runtimes[index].frame_summary_ready = false;
            self.runtimes[index].frame_summary = .{};
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
