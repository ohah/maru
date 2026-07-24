//! session-host **실 runtime 소유자**(`RuntimeManager`) — server.zig의 `RuntimeOps` seam을 실제 PTY runtime으로
//! 구현한다(§4·§13) — P3-e2b.
//!
//! P2에서 만든 `app.InProcessTermBackend`(=`TermRuntimeBackend` 계약의 in-process 구현)를 **그대로 재사용**한다.
//! host는 앱 프로세스가 아니지만 runtime 소유(PTY fork·reader·surface 코어)는 앱과 동일한 자원이라, `LiveSurfaceRegistry`+
//! `SurfaceRuntime`+`LivePtySession` 스택을 새로 만들지 않고 계약 뒤로 재사용한다(layering-and-portability.md §3.1
//! "src/app = 이식 시 재사용하는 OS 중립 공통 runtime"; SSOT — reader 동시성·수명 로직을 복제하지 않는다).
//!
//! ID 매핑(§4): server/wire는 128-bit `runtime_id`로 runtime을 가리키고, in-process backend는 u64 `RuntimeHandle`
//! (=surface handle)로 가리킨다. 이 매니저가 그 경계를 잇는다 — spawn마다 단조 증가 handle을 발급해 backend에 넘기고,
//! 무작위 `runtime_id`를 발급해 host `TerminalRuntimeRegistry`(재접속 조회·capability state)에 등록한 뒤, 그 entry의
//! opaque `runtime` 슬롯(그 목적이 "실 runtime handle 보관")에 handle을 실어 둔다. terminate는 그 슬롯에서 handle을
//! 되읽어 backend 수명을 끝낸다. 별도 side map이 없다.
//!
//! macOS 전용(실 forkpty·arc4random). server.zig(codec·순수)는 이 파일을 모르고 `RuntimeOps` 중립 vtable만 안다 —
//! 그래서 codec은 platform-import-0로 남고, 실 runtime 소유는 이 platform 경계 파일에 갇힌다. `maru`는 named module
//! import라(exe/test 모듈이 maru를 의존) codec 순수성과 무관하다.
//!
//! e2b 범위: spawn(실 PTY + reader) + terminate(clean teardown)까지다. attach 입력/resize(e2c)와 snapshot/delta
//! stream demux(e2d), host-backed `TermRuntimeBackend`(e2e)는 후속이다. 그래서 spawn은 output을 core에 반영하는
//! reader만 시작하고(process_in_reader=true), 화면 stream은 아직 내보내지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const server = @import("server.zig");
const reg = @import("registry.zig");
const core_command_wire = @import("core_command_wire.zig");
const screen_snapshot = @import("screen_snapshot.zig");
const screen_stream = @import("screen_stream.zig");
const handoff_codec = @import("handoff_codec.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령을 host core에 적용
const terminal = maru.terminal; // §6c 원격 검색(Match) 등

const InProcessTermBackend = maru.app.InProcessTermBackend;
const LiveRegistry = maru.app.in_process_term_backend.LiveRegistry;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const RuntimeHandle = maru.app.TermRuntimeHandle;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;

// host runtime의 PTY→core 이벤트 큐 용량. 제품 경로(app_session.default_queue_capacity)와 같은 16으로 맞춰
// 재접속한 GUI가 in-process와 같은 backpressure를 보게 한다(e2d stream이 이 큐를 소비).
const default_queue_capacity: usize = 16;
const foreground_refresh_ns: i128 = 500 * std.time.ns_per_ms;

const ForegroundCache = struct {
    names: [64]ForegroundProcessName = undefined,
    count: usize = 0,
    pgid: ?i32 = null,
    refreshed_at_ns: i128 = 0,
};

// macOS libc CSPRNG(std.posix 미노출 — 이 파일은 macOS 전용). runtime_id 발급용.
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;

/// hex 문자열을 바이트로 디코드해 `out`에 채우고 채운 길이를 돌려준다(§6c 검색어 — 임의 텍스트라 hex로 실어 escape 회피).
/// 홀수/잘못된 hex나 `out` 초과는 거기서 멈춘다(best-effort — 검색어는 부가 기능).
fn hexDecodeInto(hex: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 <= hex.len and n < out.len) : (i += 2) {
        out[n] = std.fmt.parseInt(u8, hex[i .. i + 2], 16) catch break;
        n += 1;
    }
    return n;
}

/// host가 소유하는 실 terminal runtime 표. `RuntimeOps`를 통해 server.zig가 이걸 구동한다. self-referential이라
/// **in-place `init`**을 쓴다(caller가 `var m: RuntimeManager = undefined; m.init(...)`) — backend가 아래 두 registry의
/// 안정 주소를 캡처하므로 init 후 매니저를 이동하면 안 된다.
pub const RuntimeManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 앱과 동일한 소유 스택 — 이 매니저가 **소유**한다(host 수명). backend가 아래 두 필드의 주소를 든다.
    live_registry: LiveRegistry,
    surface_runtime: SurfaceRuntime,
    backend_impl: InProcessTermBackend,
    /// host의 runtime_id 키드 표. 이 매니저가 아니라 daemon이 소유한다(SocketServer도 참조) — 여기선 등록/해제만 한다.
    host_registry: *reg.TerminalRuntimeRegistry,
    /// 다음 in-process handle. 1부터 발급한다 — 0은 opaque 슬롯의 null과 겹치므로 handle로 쓰지 않는다.
    next_handle: RuntimeHandle = 1,
    /// observation은 client/창/stream마다 100ms cadence로 호출될 수 있지만 OS process 열거는 runtime당 최대 2Hz다.
    /// cwd/title/OSC 상태는 계속 100ms full-state로 읽고, 비싼 foreground syscall 결과만 공유 cache한다.
    foreground_cache: std.AutoHashMapUnmanaged(RuntimeHandle, ForegroundCache) = .empty,

    /// self-referential 필드를 안정 주소로 세운다. caller가 준 `*RuntimeManager` 슬롯을 채운다(반환 이동 없음).
    pub fn init(self: *RuntimeManager, allocator: std.mem.Allocator, io: std.Io, host_registry: *reg.TerminalRuntimeRegistry) void {
        self.allocator = allocator;
        self.io = io;
        self.live_registry = LiveRegistry.init(allocator);
        self.surface_runtime = SurfaceRuntime.init(allocator);
        self.backend_impl = InProcessTermBackend.init(allocator, io, &self.live_registry, &self.surface_runtime);
        self.host_registry = host_registry;
        self.next_handle = 1;
        self.foreground_cache = .empty;
    }

    /// 소유 registry를 해제한다. **호출 전 모든 runtime이 terminate돼 있어야** 한다(reader join·슬롯 회수가 terminate에서
    /// 일어난다) — 남은 runtime이 있으면 reader 스레드가 join되지 않은 채 슬롯이 사라진다. graceful 종료 경로(§6)가 붙기
    /// 전까지 host는 SIGTERM으로 내려가 OS가 자식·스레드를 회수하므로 이 deinit은 clean-return 경로용이다.
    pub fn deinit(self: *RuntimeManager) void {
        self.foreground_cache.deinit(self.allocator);
        self.surface_runtime.deinit();
        self.live_registry.deinit();
        self.* = undefined;
    }

    /// server.zig가 dispatch에 넘길 중립 vtable. `ctx`는 이 매니저다.
    pub fn runtimeOps(self: *RuntimeManager) server.RuntimeOps {
        return .{ .ctx = self, .spawn = spawnOp, .terminate = terminateOp, .write_input = writeInputOp, .resize = resizeOp, .snapshot = snapshotOp, .delta = deltaOp, .notification = notificationOp, .core_command = coreCommandOp, .selected_text = selectedTextOp, .select_op = selectOpOp, .find = findOp, .observation = observationOp, .report_mouse = reportMouseOp };
    }

    pub const OwnerDrainSummary = struct {
        visited: usize = 0,
        output_events: usize = 0,
        exited: usize = 0,
        read_errors: usize = 0,
        failures: usize = 0,
    };

    pub const QuiesceError = error{
        TooManyRuntimes,
        Attached,
        RuntimeMissing,
        RuntimeNotLive,
        PauseFailed,
        UnsafeFrontier,
    };

    /// GUI attachment가 0이어도 host가 reader event queue의 수명 owner다. daemon tick이 이 함수를 호출해
    /// coalesced output 신호를 비우고, 검증된 `.exited`만 exact-once reap/remove한다. `.read_error`는 child
    /// 종료 증거가 아니므로 reader thread만 join하고 runtime/child를 보존한다.
    ///
    /// HashMap iterator 중 unregister하지 않도록 먼저 bounded ID/handle snapshot을 만들고 두 번째 단계에서
    /// 제거한다. 한 tick에 256개를 넘으면 다음 tick이 나머지를 처리한다(U1/U2 upgrade runtime cap과 동일).
    pub fn drainOwnedEvents(self: *RuntimeManager) OwnerDrainSummary {
        const Item = struct { runtime_id: u128, handle: RuntimeHandle };
        var items: [256]Item = undefined;
        var item_count: usize = 0;
        var it = self.host_registry.entries.iterator();
        while (it.next()) |entry| {
            if (item_count == items.len) break;
            const slot = entry.value_ptr.*.runtime orelse continue;
            items[item_count] = .{ .runtime_id = entry.key_ptr.*, .handle = @intFromPtr(slot) };
            item_count += 1;
        }

        var remove_ids: [256]u128 = undefined;
        var remove_count: usize = 0;
        var result: OwnerDrainSummary = .{};
        for (items[0..item_count]) |item| {
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(item.handle) orelse {
                result.failures += 1;
                continue;
            };
            result.visited += 1;
            var pump = terminal_slot.live_pty.pump(&self.surface_runtime);
            const drained = pump.drainAvailable() catch {
                result.failures += 1;
                continue;
            };
            result.output_events += drained.output_events;
            if (drained.ended) |ended| switch (ended) {
                .exited => {
                    result.exited += 1;
                    remove_ids[remove_count] = item.runtime_id;
                    remove_count += 1;
                },
                .read_error => {
                    result.read_errors += 1;
                    terminal_slot.live_pty.finishAfterReadError();
                },
            };
        }
        for (remove_ids[0..remove_count]) |runtime_id| self.terminateRuntime(runtime_id);
        return result;
    }

    /// U2 phase 1: owner event를 먼저 drain한 뒤 attachment/lifecycle을 재검사하고 모든 reader에 pause를 요청한다.
    /// 하나라도 실패하면 이미 요청한 reader의 request flag를 취소해 serving 상태를 보존한다.
    pub fn requestUpgradeQuiesce(self: *RuntimeManager) QuiesceError!usize {
        _ = self.drainOwnedEvents();
        if (self.host_registry.count() > 256) return error.TooManyRuntimes;

        const Item = struct { entry: *reg.RuntimeEntry, terminal_slot: *maru.app.live_pty.LiveSurface.Terminal };
        var items: [256]Item = undefined;
        var count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.controller != null or entry.observers.items.len != 0) return error.Attached;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const handle: RuntimeHandle = @intFromPtr(slot);
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradeEligible()) return error.RuntimeNotLive;
            items[count] = .{ .entry = entry, .terminal_slot = terminal_slot };
            count += 1;
        }

        var requested: usize = 0;
        errdefer for (items[0..requested]) |item| item.terminal_slot.live_pty.cancelUpgradePause();
        for (items[0..count]) |item| {
            item.terminal_slot.live_pty.requestUpgradePause() catch return error.PauseFailed;
            requested += 1;
        }
        return count;
    }

    /// U2 phase 2: 모든 reader가 safe-point를 publish했는지 관찰한다. 일부만 도달했을 때 join하지 않아
    /// deadline rollback이 모든 reader를 signal-only cancel할 수 있게 한다.
    pub fn upgradeQuiesceReached(self: *RuntimeManager) bool {
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse return false;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return false;
            if (!terminal_slot.live_pty.upgradePauseReached()) return false;
        }
        return true;
    }

    /// U2 phase 3: 모든 reader가 reached인 것이 확인된 뒤 thread를 join하고 queue/lifecycle frontier를 전량 검증한다.
    /// false면 caller가 `resumeUpgradeQuiesce`로 원상복구한다.
    pub fn joinAndValidateUpgradeQuiesce(self: *RuntimeManager) QuiesceError!void {
        if (!self.upgradeQuiesceReached()) return error.PauseFailed;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.controller != null or entry.observers.items.len != 0) return error.Attached;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.joinUpgradePause()) return error.UnsafeFrontier;
            if (!terminal_slot.live_pty.session.upgradeEligible()) return error.RuntimeNotLive;
        }
        // Reader가 마지막 core write 뒤 coalesced output 신호를 enqueue했을 수 있다. 모든 thread가 join된 뒤 owner가
        // 이를 한 번 더 drain한다. Exit/read_error가 관측되면 status를 버리지 않고 정상 lifecycle로 넘기고 upgrade는 abort.
        const drained = self.drainOwnedEvents();
        if (drained.exited != 0 or drained.read_errors != 0 or drained.failures != 0) return error.RuntimeNotLive;
        var verify = self.host_registry.entries.valueIterator();
        while (verify.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse return error.RuntimeMissing;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradePausedAndSafe()) return error.UnsafeFrontier;
        }
    }

    /// U2 rollback/resume. reached 전 reader는 request만 취소하고, join된 reader는 같은 graph에 새 thread를 시작한다.
    pub fn resumeUpgradeQuiesce(self: *RuntimeManager) void {
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const slot = entry_ptr.*.runtime orelse continue;
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(@intFromPtr(slot)) orelse continue;
            if (terminal_slot.live_pty.upgradePausedAndSafe()) {
                terminal_slot.live_pty.resumeAfterUpgradePause() catch {};
            } else {
                terminal_slot.live_pty.cancelUpgradePause();
            }
        }
    }

    /// U1/U2 bridge: 모든 reader가 join된 safe frontier에서 host/runtime logical DTO를 원자적으로 encode한다.
    /// HashMap 순서는 wire 순서가 아니므로 stable in-process handle 순으로 정렬한다. fd slot은 caller가 예약한
    /// 연속 범위의 logical 번호만 기록하며 여기서는 실제 dup/CLOEXEC를 건드리지 않는다(U3 소유).
    pub fn encodeQuiescedHost(
        self: *RuntimeManager,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        first_fd_slot: u16,
    ) (QuiesceError || handoff_codec.Error)![]u8 {
        if (!self.upgradeQuiesceReached() or self.host_registry.count() > handoff_codec.max_runtime_count)
            return error.UnsafeFrontier;
        const Item = struct {
            handle: RuntimeHandle,
            entry: *reg.RuntimeEntry,
            terminal_slot: *maru.app.live_pty.LiveSurface.Terminal,
        };
        var items: [handoff_codec.max_runtime_count]Item = undefined;
        var count: usize = 0;
        var it = self.host_registry.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            const slot = entry.runtime orelse return error.RuntimeMissing;
            const handle: RuntimeHandle = @intFromPtr(slot);
            const terminal_slot = self.backend_impl.terminalForHostLifecycle(handle) orelse return error.RuntimeMissing;
            if (!terminal_slot.live_pty.upgradePausedAndSafe() or !terminal_slot.live_pty.session.upgradeEligible())
                return error.UnsafeFrontier;
            items[count] = .{ .handle = handle, .entry = entry, .terminal_slot = terminal_slot };
            count += 1;
        }
        std.mem.sort(Item, items[0..count], {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                return a.handle < b.handle;
            }
        }.lessThan);
        if (@as(usize, first_fd_slot) + count > std.math.maxInt(u16)) return error.LimitExceeded;

        var views: [handoff_codec.max_runtime_count]handoff_codec.RuntimeView = undefined;
        var locked: usize = 0;
        defer for (items[0..locked]) |item| item.terminal_slot.surface.unlockCore(self.io);
        for (items[0..count], 0..) |item, index| {
            item.terminal_slot.surface.lockCore(self.io);
            locked += 1;
            const session = item.terminal_slot.live_pty.session;
            const size = session.canonicalSize();
            if (size.cols != item.entry.cols or size.rows != item.entry.rows) return error.UnsafeFrontier;
            views[index] = .{
                .runtime_id = item.entry.id,
                .surface_id = item.handle,
                .child_pid = session.childPid(),
                .cols = item.entry.cols,
                .rows = item.entry.rows,
                .resize_generation = item.entry.resize_generation,
                .fd_slot = first_fd_slot + @as(u16, @intCast(index)),
                .core = &item.terminal_slot.surface.core,
            };
        }
        return handoff_codec.encodeHost(allocator, .{
            .host_id = host_id,
            .upgrade_epoch = upgrade_epoch,
            .next_handle = self.next_handle,
            .runtimes = views[0..count],
        });
    }

    fn spawnOp(ctx: *anyopaque, params: server.RuntimeSpawnParams) anyerror!u128 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        return self.spawnRuntime(params);
    }

    fn terminateOp(ctx: *anyopaque, runtime_id: u128) void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        self.terminateRuntime(runtime_id);
    }

    fn writeInputOp(ctx: *anyopaque, runtime_id: u128, bytes: []const u8) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().writeInput(handle, bytes);
    }

    fn resizeOp(ctx: *anyopaque, runtime_id: u128, cols: u16, rows: u16) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().resize(handle, .{ .cols = cols, .rows = rows }, self.io);
    }

    /// host 실제 core/PTY에서 화면 외 runtime 관측을 한 번에 owned copy한다. foreground syscall은 runtime별 500ms
    /// cache로 core lock 밖에서 수행하고, cwd/title/semantic/input modes/OSC5379는 reader와 같은 core lock 아래에서 복사한다.
    /// 1회성 agent progress는 multi-subscriber wire에서 제외한다.
    fn observationOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror!server.RuntimeObservation {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const be = self.backend_impl.backend();

        const cache_gop = try self.foreground_cache.getOrPut(self.allocator, handle);
        if (!cache_gop.found_existing) cache_gop.value_ptr.* = .{};
        const foreground = cache_gop.value_ptr;
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (foreground.refreshed_at_ns == 0 or now_ns - foreground.refreshed_at_ns >= foreground_refresh_ns) {
            foreground.count = be.foregroundProcessNames(handle, &foreground.names);
            foreground.pgid = be.foregroundProcessGroup(handle);
            foreground.refreshed_at_ns = now_ns;
        }
        const process_count = foreground.count;
        const foreground_pgid = foreground.pgid;
        const processes = try allocator.alloc(server.RuntimeObservation.Process, process_count);
        var process_names_initialized: usize = 0;
        errdefer {
            for (processes[0..process_names_initialized]) |p| allocator.free(p.name);
            allocator.free(processes);
        }
        for (foreground.names[0..process_count], 0..) |p, i| {
            processes[i] = .{ .pid = p.pid, .name = try allocator.dupe(u8, p.slice()) };
            process_names_initialized += 1;
        }

        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        const core = &surface.core;
        const cwd = try allocator.dupe(u8, core.currentCwd());
        errdefer allocator.free(cwd);
        const title = try allocator.dupe(u8, core.windowTitle());
        errdefer allocator.free(title);
        const ssh_dest: ?[]u8 = if (core.sshRemoteDest()) |dest| try allocator.dupe(u8, dest) else null;
        errdefer if (ssh_dest) |dest| allocator.free(dest);
        const result = server.RuntimeObservation{
            .cwd = cwd,
            .window_title = title,
            .ssh_remote_dest = ssh_dest,
            .semantic_state = @intFromEnum(core.semantic_state),
            .alt_active = core.alt_active,
            .app_cursor_keys = core.application_cursor_keys,
            // §입력 패리티: host-backed 일반 key 인코딩(DECKPAM numpad·kitty keyboard)이 placeholder core 기본값이 아니라
            // host의 실제 모드를 쓰도록 관측으로 나른다(DECCKM app_cursor_keys 형제). kitty_flags는 스택 최상단 u5.
            .app_keypad = core.application_keypad,
            .kitty_flags = core.kitty_flags.current().int(),
            .alternate_scroll = core.alternate_scroll,
            .mouse_tracking = core.mouse_tracking != .none,
            .bracketed_paste = core.bracketed_paste,
            .observer_generation = core.observerGeneration(),
            .title_generation = core.title_generation.load(.monotonic),
            .cols = core.size.cols,
            .rows = core.size.rows,
            .foreground_available = true,
            .foreground_pgid = foreground_pgid,
            .processes = processes,
        };
        return result;
    }

    /// runtime의 현재 화면을 screen_stream 레코드 스트림으로 투영한다(§12, P3-e2d). reader 스레드가 core를 쓰므로
    /// **core_mutex를 잡은 채** 투영하고(투영이 grapheme·색을 소유 버퍼로 복사), 반환된 소유 바이트만 unlock 뒤 caller가
    /// snapshot_chunk로 나눠 보낸다(io-render-threading.md — snapshot 슬라이스는 core alias라 lock 밖으로 새면 안 됨).
    fn snapshotOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        return screen_snapshot.projectSnapshot(allocator, &surface.core, .{ .generation = generation });
    }

    /// `base`(client가 마지막으로 받은 full snapshot) 대비 현재 화면 변화를 계산한다(§9 delta). core lock 아래에서 현재
    /// full snapshot(다음 base)과 delta를 함께 만든다. grid/alt-screen 변화면 delta 대신 fresh snapshot을 보낸다(client가
    /// 화면 교체). `send`와 `new_base`는 항상 별개 버퍼다(caller가 둘 다 free해도 안전).
    fn deltaOp(ctx: *anyopaque, runtime_id: u128, base: []const u8, allocator: std.mem.Allocator) anyerror!server.StreamUpdate {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        const generation = if (self.host_registry.get(runtime_id)) |e| e.resize_generation else 0;
        const opts = screen_snapshot.ProjectOptions{ .generation = generation };
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);

        // computeDelta가 delta와 새 base(현재 full snapshot)를 **한 번의 row build로** 함께 준다(재투영 없음).
        const result = screen_snapshot.computeDelta(allocator, base, &surface.core, opts) catch |e| switch (e) {
            error.SnapshotRequired => {
                // grid/alt 변화 → delta 불가, fresh snapshot을 보낸다. send는 new_base와 별개 버퍼여야 하므로 복사한다.
                const snap = try screen_snapshot.projectSnapshot(allocator, &surface.core, opts);
                errdefer allocator.free(snap);
                const send = allocator.dupe(u8, snap) catch return error.OutOfMemory;
                return .{ .send = send, .is_snapshot = true, .new_base = snap };
            },
            else => return e,
        };
        return .{ .send = result.delta, .is_snapshot = false, .new_base = result.snapshot };
    }

    /// runtime의 대기 중인 OSC 9/777 데스크톱 알림을 빼서 JSON `{title, body}`로 준다(§6.32). host의 `TerminalCore`가
    /// 파싱해 둔 title/body를 **core lock 아래** 읽고 clearNotification한다(reader 스레드가 core를 쓰므로, snapshot과 동일한
    /// off-thread 동기화). 없으면 `{title:"",body:""}`. title/body는 임의 바이트라 실 JSON encoder로 escape한다.
    fn notificationOp(ctx: *anyopaque, runtime_id: u128, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        if (surface.core.pendingNotification()) |n| {
            js.write(.{ .title = n.title, .body = n.body }) catch return error.OutOfMemory;
            surface.core.clearNotification(); // drain — 다음 조회는 없음.
        } else {
            js.write(.{ .title = "", .body = "" }) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 검증된 wire command를 내부 `CoreCommand`로 명시 변환해 host reader queue에 넣는다. focus가 만드는
    /// `pendingResponse`와 config/viewport mutation을 dispatch thread가 직접 적용하지 않아, 로컬과 동일하게 reader가
    /// core의 유일한 mutator이자 PTY response writer로 남는다.
    fn coreCommandOp(ctx: *anyopaque, runtime_id: u128, wire_command: core_command_wire.Command) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const command = try coreCommandFromWire(wire_command);
        return self.backend_impl.backend().enqueueCoreCommand(handle, command, self.io);
    }

    /// host-backed 마우스 리포트(§ 입력 패리티): client 마우스 이벤트를 host의 **reader에 report_mouse core command로
    /// enqueue**한다 — reader가 적용하면 core가 자기 mouse_tracking/format으로 SGR/x10 응답을 만들고, reader가 그
    /// pendingResponse를 PTY로 흘린다(로컬 휠·클릭 경로와 **동형**: enqueueCoreCommand→reader 적용+flush). dispatch
    /// 스레드가 직접 apply+writeInput하면 reader의 response PTY-write와 같은 자식-stdin fd에 동시 쓰기(race)가 되므로,
    /// 모든 PTY 입력 쓰기를 reader 단일 스레드로 모은다(§io-render-threading).
    fn reportMouseOp(ctx: *anyopaque, runtime_id: u128, report: server.MouseReport) anyerror!void {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        return self.backend_impl.backend().enqueueCoreCommand(handle, .{ .report_mouse = .{
            .button = report.button,
            .col = report.col,
            .row = report.row,
            .x_px = report.x_px,
            .y_px = report.y_px,
            .pressed = report.pressed,
            .motion = report.motion,
            .mods = report.mods,
        } }, self.io);
    }

    /// 원격 client가 보낸 뷰포트 선택 span을 host core에 적용해 텍스트를 뽑는다(§6b 원격 선택 복사). **로컬과 같은
    /// `extractSelection`** 을 재사용하므로 soft-wrap 이음·블록·스크롤백 걸친 선택까지 충실하다(선택 의미론 단일 출처). host
    /// core의 선택은 평소 미사용(client가 렌더용 span 소유)이라 **core lock 아래 transient set-extract-clear**가 안전하다.
    /// span의 뷰포트 좌표는 host의 현재 view_offset 기준으로 abs 변환된다(selectionStart/Extend가 내부에서). JSON `{text}`(임의
    /// 바이트라 실 encoder로 escape). 추출 실패/빈 선택은 `{text:""}`.
    fn selectedTextOp(ctx: *anyopaque, runtime_id: u128, span: server.SelectSpan, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        surface.core.selectionStart(span.sr, span.sc);
        if (span.block) surface.core.setSelectionBlock(true);
        surface.core.selectionExtend(span.er, span.ec);
        const extracted = surface.core.extractSelection(allocator) catch null;
        defer if (extracted) |e| allocator.free(e);
        surface.core.selectionClear(); // transient — host core 선택 원복.
        const text: []const u8 = extracted orelse "";
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(.{ .text = text }) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// 단어/줄 선택(§6b-2): host가 **콘텐츠를 아는 자기 core**로 경계를 계산해(`selectWordAt`/`selectLineAt`) 결과 뷰포트 선택
    /// span을 JSON으로 준다. 빈 client placeholder는 경계를 모르므로 host가 계산(선택 의미론 host 단일 출처). span만 계산해
    /// 돌려주고 host core 선택은 원복(transient — client가 그 span을 placeholder에 적용해 하이라이트, 복사는 #6b-1 selected_text).
    /// 구분자(word-separators) forwarding은 후속 — 기본 "" (공백 경계, config 기본값과 일치). 미지원 op·빈 선택은 `{sel:false}`.
    fn selectOpOp(ctx: *anyopaque, runtime_id: u128, op: []const u8, row: u16, col: u16, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (std.mem.eql(u8, op, "word")) {
            surface.core.selectWordAt(row, col, ""); // 기본 공백 경계(구분자 forwarding 후속).
        } else if (std.mem.eql(u8, op, "line")) {
            surface.core.selectLineAt(row);
        } else {
            return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
        }
        const maybe = surface.core.selectionViewportSpan();
        surface.core.selectionClear(); // transient 원복.
        if (maybe) |sp| {
            return std.fmt.allocPrint(allocator, "{{\"sel\":true,\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ sp.start.row, sp.start.col, sp.end.row, sp.end.col, sp.block }) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "{\"sel\":false}") catch return error.OutOfMemory;
    }

    /// 원격 검색(§6c): client가 보낸 검색어(hex)로 host가 **콘텐츠·스크롤백을 아는 자기 core**에서 `findMatches`(로컬과 같은
    /// 함수)로 매치를 찾고, 보이는 매치를 `matchViewportSpan`으로 클립해 `{count, spans:[sr,sc,er,ec,...]}`로 준다(선택과 같이
    /// 검색 의미론 host 단일 출처). count=전체 매치 수, spans=현재 뷰포트에 보이는 매치의 flat 좌표. core lock 아래(findMatches가
    /// 스크롤백 rewrap으로 core mutate).
    fn findOp(ctx: *anyopaque, runtime_id: u128, query_hex: []const u8, cur_index: u32, scroll: bool, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RuntimeManager = @ptrCast(@alignCast(ctx));
        const handle = self.handleFor(runtime_id) orelse return error.RuntimeNotFound;
        const surface = self.backend_impl.surfaceFor(handle) orelse return error.RuntimeNotFound;
        var qbuf: [512]u8 = undefined;
        const query = qbuf[0..hexDecodeInto(query_hex, &qbuf)];

        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        var matches: std.ArrayList(terminal.Match) = .empty;
        defer matches.deinit(allocator);
        surface.core.findMatches(allocator, query, &matches) catch {}; // 실패 시 빈 매치(best-effort).
        // §6c-2 네비: scroll이면 현재 매치(cur_index)의 abs 위치로 host 화면을 이동한다 — client가 그 매치를 보게(view_offset
        // 변화 → 다음 delta로 스크롤 화면 투영). 그 뒤 클립하므로 현재 매치가 보이게 된다.
        if (scroll and cur_index < matches.items.len) {
            surface.core.scrollToAbs(matches.items[cur_index].start.row);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [96]u8 = undefined;
        // cur=현재 매치의 뷰포트 span(보이면 4정수, 안 보이면 빈 배열).
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{{\"count\":{d},\"cur\":[", .{matches.items.len}));
        if (cur_index < matches.items.len) {
            if (surface.core.matchViewportSpan(matches.items[cur_index])) |cs| {
                try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ cs.start.row, cs.start.col, cs.end.row, cs.end.col }));
            }
        }
        // spans=보이는 **비현재** 매치.
        try out.appendSlice(allocator, "],\"spans\":[");
        var first = true;
        for (matches.items, 0..) |m, mi| {
            if (mi == cur_index) continue; // 현재는 cur에 담았다.
            const span = surface.core.matchViewportSpan(m) orelse continue; // 뷰포트 밖 매치는 렌더 안 함.
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ span.start.row, span.start.col, span.end.row, span.end.col }));
        }
        try out.appendSlice(allocator, "]}");
        return out.toOwnedSlice(allocator);
    }

    /// runtime_id → in-process handle. registry entry의 opaque 슬롯에서 되읽는다(spawn이 심어 둔 값). 없으면 null.
    fn handleFor(self: *RuntimeManager, runtime_id: u128) ?RuntimeHandle {
        const entry = self.host_registry.get(runtime_id) orelse return null;
        const slot = entry.runtime orelse return null;
        return @intFromPtr(slot);
    }

    /// 실 PTY runtime을 띄운다: backend.spawn(forkpty) → attach(reader 시작) → host registry 등록. `runtime_id`를 돌려준다.
    /// argv/cwd 슬라이스는 backend.spawn이 동기적으로 복사하므로(PtySession.spawn이 dupeZ) transient여도 안전하다.
    /// 에러 집합은 backend(anyerror)를 그대로 전파한다 — `error.EmptyArgv`/`error.IdSpaceExhausted`는 이 매니저 고유.
    fn spawnRuntime(self: *RuntimeManager, params: server.RuntimeSpawnParams) anyerror!u128 {
        if (params.argv.len == 0) return error.EmptyArgv; // server가 이미 거르지만 방어(handle 낭비 방지).
        const handle = self.next_handle;
        const be = self.backend_impl.backend();
        const size = maru.terminal.Size{ .cols = params.cols, .rows = params.rows };
        const args: []const []const u8 = if (params.argv.len > 1) params.argv[1..] else &.{};
        const initial_config: ?core_command.RuntimeConfig = if (params.initial_config) |config| blk: {
            const command = try coreCommandFromWire(.{ .set_runtime_config = config });
            break :blk command.set_runtime_config;
        } else null;

        _ = try be.spawn(.{
            .handle = handle,
            .request = .{
                .command = params.argv[0],
                .args = args,
                .cwd = params.cwd,
                .login = params.login,
                .env = params.env,
                .parent_env = params.parent_env,
                .env_overrides = params.env_overrides,
                .term = params.term,
                .zdotdir = params.zdotdir,
                .ssh_integration_bin = params.ssh_integration_bin,
                .pane_id = params.pane_id,
                .size = size,
            },
            .size = size,
            .queue_capacity = default_queue_capacity,
            // backend seam이 pre-reader bootstrap의 단일 소유자다. 새 backend도 이 필드를 무시하면 first-output
            // parity 계약을 만족하지 못하며, RuntimeManager가 surface 구현을 알아 직접 mutate하지 않는다.
            .initial_config = initial_config,
        });
        // 여기부터 실패하면 방금 만든 runtime을 회수한다(closeAndDetach로 PTY/자식/reader 종료 → remove로 reader join+슬롯 해제).
        errdefer {
            be.closeAndDetach(handle);
            be.remove(handle);
        }
        _ = try be.attach(handle, true); // backend가 initial_config를 적용한 뒤 reader 시작 — 첫 output부터 host 설정 사용.

        // 무작위 runtime_id를 발급해 host registry에 등록한다. 충돌은 사실상 불가능하지만 방어적으로 재시도한다.
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const rid = newRuntimeId();
            const entry = self.host_registry.register(rid, params.cols, params.rows) catch |err| switch (err) {
                error.DuplicateRuntime => continue,
                else => return err,
            };
            entry.runtime = @ptrFromInt(handle); // opaque 슬롯에 handle 보관(그 목적: 실 runtime handle). handle>=1이라 non-null.
            self.next_handle += 1;
            return rid;
        }
        return error.IdSpaceExhausted; // 8회 연속 128-bit 충돌 — 도달 불가.
    }

    /// runtime을 종료한다(§8 `runtime end`). 멱등 — 없는 id/handle 미기록은 무시한다. registry entry의 opaque 슬롯에서
    /// handle을 되읽어 backend 수명을 끝내고(closeAndDetach → remove), registry에서 뗀다.
    fn terminateRuntime(self: *RuntimeManager, runtime_id: u128) void {
        const entry = self.host_registry.get(runtime_id) orelse return; // 없는 id — 멱등 no-op.
        const slot = entry.runtime orelse {
            self.host_registry.unregister(runtime_id); // handle 미기록(비정상) — registry만 정리.
            return;
        };
        const handle: RuntimeHandle = @intFromPtr(slot);
        const be = self.backend_impl.backend();
        be.closeAndDetach(handle); // PTY/자식/reader 종료 + routing detach(멱등).
        be.remove(handle); // reader join → surface/live_pty 번들 deinit → 슬롯 회수.
        _ = self.foreground_cache.remove(handle);
        self.host_registry.unregister(runtime_id);
    }
};

fn coreCommandFromWire(command: core_command_wire.Command) error{InvalidCommand}!core_command.CoreCommand {
    return switch (command) {
        .scroll => |delta| .{ .scroll = std.math.cast(isize, delta) orelse return error.InvalidCommand },
        .scroll_to_bottom => .scroll_to_bottom,
        .scroll_to_abs => |row| .{ .scroll_to_abs = std.math.cast(usize, row) orelse return error.InvalidCommand },
        .scroll_to_offset => |offset| .{ .scroll_to_offset = std.math.cast(usize, offset) orelse return error.InvalidCommand },
        .report_focus => |gained| .{ .report_focus = gained },
        .set_cell_metrics => |metrics| .{ .set_cell_metrics = .{ .width = metrics.width, .height = metrics.height } },
        .set_default_colors => |colors| .{ .set_default_colors = .{
            .foreground = rgbFromWire(colors.foreground),
            .background = rgbFromWire(colors.background),
        } },
        .set_config_palette => |wire_palette| blk: {
            var palette: [16]?terminal.Rgb = .{null} ** 16;
            for (wire_palette, 0..) |maybe_rgb, index| {
                palette[index] = if (maybe_rgb) |rgb| rgbFromWire(rgb) else null;
            }
            break :blk .{ .set_config_palette = palette };
        },
        .set_max_scrollback => |lines| .{ .set_max_scrollback = std.math.cast(usize, lines) orelse return error.InvalidCommand },
        .set_ambiguous_wide => |wide| .{ .set_ambiguous_wide = wide },
        .set_emoji_wide => |wide| .{ .set_emoji_wide = wide },
        .set_runtime_config => |config| .{ .set_runtime_config = .{
            .max_scrollback = std.math.cast(usize, config.max_scrollback) orelse return error.InvalidCommand,
            .ambiguous_wide = config.ambiguous_wide,
            .emoji_wide = config.emoji_wide,
            .palette = paletteFromWire(config.palette),
            .default_colors = .{
                .foreground = rgbFromWire(config.default_colors.foreground),
                .background = rgbFromWire(config.default_colors.background),
            },
            .cell_metrics = if (config.cell_metrics) |metrics| .{
                .width = metrics.width,
                .height = metrics.height,
            } else null,
        } },
        .jump_to_prompt => |direction| .{ .jump_to_prompt = direction },
    };
}

fn rgbFromWire(rgb: u32) terminal.Rgb {
    return .{
        .r = @truncate(rgb >> 16),
        .g = @truncate(rgb >> 8),
        .b = @truncate(rgb),
    };
}

fn paletteFromWire(wire_palette: core_command_wire.Command.Palette) [16]?terminal.Rgb {
    var palette: [16]?terminal.Rgb = .{null} ** 16;
    for (wire_palette, 0..) |maybe_rgb, index| {
        palette[index] = if (maybe_rgb) |rgb| rgbFromWire(rgb) else null;
    }
    return palette;
}

test "runtime manager maps every bounded wire command without silent variants" {
    var wire_palette: core_command_wire.Command.Palette = .{null} ** 16;
    wire_palette[3] = 0x12_34_56;
    const mapped = try coreCommandFromWire(.{ .set_config_palette = wire_palette });
    try std.testing.expect(mapped == .set_config_palette);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, mapped.set_config_palette[3].?);

    const focus = try coreCommandFromWire(.{ .report_focus = true });
    try std.testing.expect(focus == .report_focus);
    try std.testing.expect(focus.report_focus);

    const defaults = try coreCommandFromWire(.{ .set_default_colors = .{
        .foreground = 0xAA_BB_CC,
        .background = 0x01_02_03,
    } });
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xAA, .g = 0xBB, .b = 0xCC }, defaults.set_default_colors.foreground);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x01, .g = 0x02, .b = 0x03 }, defaults.set_default_colors.background);
}

/// 128-bit runtime_id를 발급한다(§4 opaque random). macOS `arc4random_buf`는 실패하지 않는 CSPRNG다(daemon.newHostId 대칭).
fn newRuntimeId() u128 {
    var bytes: [16]u8 = undefined;
    arc4random_buf(&bytes, bytes.len);
    return std.mem.readInt(u128, &bytes, .big);
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS PTY: RuntimeOps로 실 runtime을 띄우고 내린다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 영속 host의 핵심은 GUI 밖에서 **실 PTY runtime을 소유**하는
// 것이다. server.zig의 read-only 조회를 넘어, `RuntimeOps.spawn`이 실제 forkpty로 셸을 띄워 host registry에 재접속
// 조회 대상으로 노출하고, `terminate`가 그 PTY/자식/reader를 누수 없이 회수하는지 고정한다. testing.allocator가
// 누수를(reader join 실패·슬롯 미회수) 잡는다. 실 forkpty라 macOS opt-in(non-macOS는 barrel에서 제외돼 test 자체가 없다).
// ─────────────────────────────────────────────────────────────────────────────

test "runtime manager: spawns a real PTY runtime through RuntimeOps and terminates it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();

    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // 짧게 종료하는 controlled command를 RuntimeOps.spawn으로 띄운다(실 forkpty). argv는 transient(스택) — spawn이 복사한다.
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .cwd = null,
        .cols = 40,
        .rows = 10,
    });

    // host registry가 이 runtime을 재접속 조회 대상으로 노출한다(runtime.list/get이 이걸 읽는다).
    try std.testing.expectEqual(@as(usize, 1), host_registry.count());
    const entry = host_registry.get(rid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 40), entry.cols);
    try std.testing.expect(entry.runtime != null); // opaque 슬롯에 handle이 실려 있다.

    // terminate: PTY/자식/reader를 정리하고 registry에서 제거한다.
    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    // 두 번째 terminate는 no-op(없는 id 무시) — 멱등.
    ops.terminate(ops.ctx, rid);
}

test "runtime manager: owner drain reaps an exited runtime with zero GUI attachments exactly once" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    _ = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .cwd = null, .cols = 20, .rows = 4 });
    var total_exited: usize = 0;
    var attempts: usize = 0;
    while (attempts < 300 and host_registry.count() != 0) : (attempts += 1) {
        const drained = mgr.drainOwnedEvents();
        total_exited += drained.exited;
        if (host_registry.count() != 0) _ = usleep(10 * 1000);
    }
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
    try std.testing.expectEqual(@as(usize, 1), total_exited);
    const after = mgr.drainOwnedEvents();
    try std.testing.expectEqual(@as(usize, 0), after.exited);
}

test "runtime manager: U2 quiesce encodes and resumes the same live PTY without attachments" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const terminal_slot = mgr.backend_impl.terminalForHostLifecycle(handle) orelse return error.TestUnexpectedResult;
    const child_before = terminal_slot.live_pty.session.childPid();
    const fd_before = terminal_slot.live_pty.session.inheritedMasterFd() orelse return error.TestUnexpectedResult;

    try ops.write_input(ops.ctx, rid, "before\n");
    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 500 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try mgr.joinAndValidateUpgradeQuiesce();

    const encoded = try mgr.encodeQuiescedHost(allocator, 0xCAFE, 3, 40);
    defer allocator.free(encoded);
    var decoded = try handoff_codec.decodeHost(allocator, encoded);
    decoded.deinit();

    mgr.resumeUpgradeQuiesce();
    try std.testing.expectEqual(child_before, terminal_slot.live_pty.session.childPid());
    try std.testing.expectEqual(fd_before, terminal_slot.live_pty.session.inheritedMasterFd().?);
    try ops.write_input(ops.ctx, rid, "after\n");
}

test "runtime manager: U2 quiesce refuses attached runtimes without pausing their reader" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    _ = try host_registry.attach(rid, 99, .observer);
    try std.testing.expectError(error.Attached, mgr.requestUpgradeQuiesce());
    _ = try host_registry.detach(rid, 99);

    try ops.write_input(ops.ctx, rid, "still-live\n");
}

test "runtime manager: U2 pause reaches a safe frontier under continuous PTY output and resumes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();
    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do printf x; done" },
        .cwd = null,
        .cols = 20,
        .rows = 4,
    });
    defer ops.terminate(ops.ctx, rid);

    try std.testing.expectEqual(@as(usize, 1), try mgr.requestUpgradeQuiesce());
    var attempts: usize = 0;
    while (attempts < 5000 and !mgr.upgradeQuiesceReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(mgr.upgradeQuiesceReached());
    try mgr.joinAndValidateUpgradeQuiesce();
    mgr.resumeUpgradeQuiesce();
    try ops.write_input(ops.ctx, rid, "ignored-but-admitted");
}

test "runtime manager: initial config is applied before fast first output reaches the host core" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    var palette: core_command_wire.Command.Palette = .{null} ** 16;
    palette[1] = 0x11_22_33;
    const ops = mgr.runtimeOps();
    const script = "i=0; while [ $i -lt 1100 ]; do echo x; i=$((i+1)); done; sleep 2";
    const rid = try ops.spawn(ops.ctx, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = null,
        .cols = 20,
        .rows = 5,
        .initial_config = .{
            .max_scrollback = 1200,
            .ambiguous_wide = true,
            .emoji_wide = false,
            .palette = palette,
            .default_colors = .{ .foreground = 0xAA_BB_CC, .background = 0x01_02_03 },
            .cell_metrics = .{ .width = 9, .height = 18 },
        },
    });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    // spawn이 돌아온 시점에는 reader가 시작됐지만 config는 그보다 먼저 적용돼 있어야 한다.
    surface.lockCore(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1200), surface.core.maxScrollback());
    try std.testing.expect(surface.core.ambiguous_wide);
    try std.testing.expectEqual(@as(u8, 0x22), surface.core.config_palette[1].?.g);
    surface.unlockCore(std.testing.io);

    // 기본 cap(1000)보다 많은 첫 burst를 보존한다. config가 attach 뒤 RPC였다면 앞부분이 기본 cap에서 먼저 evict될 수 있다.
    var retained = false;
    var attempts: usize = 0;
    while (attempts < 300 and !retained) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        retained = surface.core.scrollbackLen() > 1000;
        surface.unlockCore(std.testing.io);
        if (!retained) _ = usleep(10 * 1000);
    }
    try std.testing.expect(retained);
}

test "runtime manager: writeInput and resize reach a real runtime through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    // cat은 입력 EOF까지 살아 있어 writeInput/resize를 적용할 실 runtime을 준다.
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 10 });

    // writeInput/resize가 실 backend에 에러 없이 위임된다(실제 화면 반영은 e2d stream이 검증). 매니저 resizeOp는 backend
    // 적용만 하고 canonical(registry) 갱신은 server.dispatchResize의 몫이라, 여기선 backend 위임 성공만 본다.
    try ops.write_input(ops.ctx, rid, "hello\n");
    try ops.resize(ops.ctx, rid, 100, 30);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.write_input(ops.ctx, 0xDEADBEEF, "x"));
    try std.testing.expectError(error.RuntimeNotFound, ops.resize(ops.ctx, 0xDEADBEEF, 10, 10));

    ops.terminate(ops.ctx, rid);
    try std.testing.expectEqual(@as(usize, 0), host_registry.count());
}

test "runtime manager: bounded core config commands reach the real host reader core" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    var wire_palette: core_command_wire.Command.Palette = .{null} ** 16;
    wire_palette[2] = 0x12_34_56;
    try ops.core_command(ops.ctx, rid, .{ .set_runtime_config = .{
        .max_scrollback = 321,
        .ambiguous_wide = true,
        .emoji_wide = false,
        .palette = wire_palette,
        .default_colors = .{
            .foreground = 0xAA_BB_CC,
            .background = 0x01_02_03,
        },
        .cell_metrics = .{ .width = 9, .height = 18 },
    } });

    // RuntimeOps 응답은 command admission을 뜻한다. 실제 reader 적용도 bounded하게 기다려 host core 상태로 증명한다.
    var applied = false;
    var attempts: usize = 0;
    while (attempts < 100 and !applied) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        applied = surface.core.maxScrollback() == 321 and
            surface.core.ambiguous_wide and
            !surface.core.emoji_wide and
            surface.core.cell_width_px == 9 and
            surface.core.cell_height_px == 18 and
            surface.core.default_fg_rgb.r == 0xAA and
            surface.core.default_bg_rgb.b == 0x03 and
            surface.core.config_palette[2] != null and
            surface.core.config_palette[2].?.g == 0x34;
        surface.unlockCore(std.testing.io);
        if (!applied) _ = usleep(10 * 1000);
    }
    try std.testing.expect(applied);
}

test "runtime manager: focus report is written back to the real PTY by the host reader" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const result_path = try std.fs.path.join(allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path, "focus.hex" });
    defer allocator.free(result_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "stty raw -echo; printf '\\033[?1004h'; dd bs=1 count=5 2>/dev/null | od -An -tx1 | tr -d ' \\n' > '{s}'",
        .{result_path},
    );
    defer allocator.free(script);

    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = null, .cols = 40, .rows = 10 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;

    // 자식이 DECSET 1004를 출력해 host core가 focus report를 요청할 때까지 기다린다.
    var focus_enabled = false;
    var attempts: usize = 0;
    while (attempts < 200 and !focus_enabled) : (attempts += 1) {
        surface.lockCore(std.testing.io);
        focus_enabled = surface.core.focus_events;
        surface.unlockCore(std.testing.io);
        if (!focus_enabled) _ = usleep(10 * 1000);
    }
    try std.testing.expect(focus_enabled);

    // 별도 input/command queue가 실제 PTY에서도 호출 순서를 보존해야 한다. reader는 A를 fence까지 쓴 뒤
    // focus command가 만든 CSI I를 우선 쓰고, 그 뒤 suffix B를 쓴다.
    try ops.write_input(ops.ctx, rid, "A");
    try ops.core_command(ops.ctx, rid, .{ .report_focus = true });
    try ops.write_input(ops.ctx, rid, "B");

    // reader가 `A`, `CSI I`, `B` 다섯 바이트를 정확한 순서로 PTY에 쓰면 자식이 별도 파일에 hex로 남긴다.
    // 단순 core mutation이나 command/input 순서가 뒤집힌 구현으로는 이 값이 생기지 않는다.
    var saw_ordered_bytes = false;
    attempts = 0;
    while (attempts < 200 and !saw_ordered_bytes) : (attempts += 1) {
        const result = tmp.dir.readFileAlloc(std.testing.io, "focus.hex", allocator, .limited(4096)) catch null;
        if (result) |bytes| {
            saw_ordered_bytes = std.mem.indexOf(u8, bytes, "411b5b4942") != null;
            allocator.free(bytes);
        }
        if (!saw_ordered_bytes) _ = usleep(10 * 1000);
    }
    try std.testing.expect(saw_ordered_bytes);
}

test "runtime manager: snapshot projects the runtime's live screen through RuntimeOps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });

    // snapshot이 실 core를 lock한 채 투영해 첫 record(screen_meta)에 spawn 크기(24x6)를 담는다.
    const snap = try ops.snapshot(ops.ctx, rid, allocator);
    defer allocator.free(snap);
    var rs = screen_stream.RecordStream{ .bytes = snap };
    const first = (try rs.next()).?;
    const s = try screen_stream.RecordStream.split(first);
    try std.testing.expectEqual(screen_stream.RecordKind.screen_meta, s.header.kind);
    const meta = try screen_stream.decodeScreenMeta(s.body);
    try std.testing.expectEqual(@as(u16, 24), meta.cols);
    try std.testing.expectEqual(@as(u16, 6), meta.rows);

    // 없는 runtime_id는 RuntimeNotFound(다른 runtime으로 새지 않는다).
    try std.testing.expectError(error.RuntimeNotFound, ops.snapshot(ops.ctx, 0xDEADBEEF, allocator));

    ops.terminate(ops.ctx, rid);
}

test "runtime manager: observation exports host-owned cwd title ssh and semantic metadata" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 24, .rows = 6 });
    defer ops.terminate(ops.ctx, rid);
    const handle = mgr.handleFor(rid) orelse return error.TestUnexpectedResult;
    const surface = mgr.backend_impl.surfaceFor(handle) orelse return error.TestUnexpectedResult;
    surface.lockCore(std.testing.io);
    surface.core.write(
        "\x1b]7;file://localhost/tmp/metadata-repo\x07" ++
            "\x1b]2;metadata-title\x07" ++
            "\x1b]5379;ssh;user@workbox\x07" ++
            "\x1b]133;C\x07",
    ) catch |err| {
        surface.unlockCore(std.testing.io);
        return err;
    };
    surface.unlockCore(std.testing.io);

    var observation = try ops.observation(ops.ctx, rid, allocator);
    defer observation.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp/metadata-repo", observation.cwd);
    try std.testing.expectEqualStrings("metadata-title", observation.window_title);
    try std.testing.expectEqualStrings("user@workbox", observation.ssh_remote_dest.?);
    try std.testing.expectEqual(@as(u8, @intFromEnum(terminal.SemanticPrompt.command)), observation.semantic_state);
    try std.testing.expect(observation.foreground_available);
}

test "runtime manager: empty argv is rejected before allocating a handle" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var host_registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer host_registry.deinit();
    var mgr: RuntimeManager = undefined;
    mgr.init(allocator, std.testing.io, &host_registry);
    defer mgr.deinit();

    const ops = mgr.runtimeOps();
    try std.testing.expectError(error.EmptyArgv, ops.spawn(ops.ctx, .{ .argv = &.{}, .cwd = null, .cols = 80, .rows = 24 }));
    try std.testing.expectEqual(@as(usize, 0), host_registry.count()); // 실패라 registry에 아무것도 안 남는다.
}
