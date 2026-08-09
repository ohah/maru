//! InProcessTermBackend — `TermRuntimeBackend` 계약의 in-process 구현(docs/persistent-session-host.md §13 P2).
//!
//! 앱 프로세스 **안에서** 도는 terminal runtime을 계약 뒤로 감싼다. 소유·라우팅 자원은 새로 만들지 않고 이미
//! 앱 전역(`AppRuntime`)이 소유한 세 가지를 참조만 한다:
//!   - `LiveSurfaceRegistry(LiveSurface)` — surface + live PTY 번들을 surface_id 키드 heap 슬롯으로 **소유**.
//!   - `SurfaceRuntime` — surface_id 키드 input/resize/output 라우팅 표.
//! 즉 이 adapter는 상태를 갖지 않는 얇은 배선이고, 실제 수명/라우팅은 기존 `LivePtySession`/`SurfaceRuntime`
//! 계약 그대로다. `RuntimeHandle`은 in-process에서 surface_id(=pty_id)와 같은 값이라 매핑이 1:1이다.
//!
//! 이 adapter가 존재하는 이유(seam): GUI layout(`session_model.Term`)이 지금까지 `*LivePtySession`을 직접 들던
//! 것을 opaque handle + 계약으로 바꾸면, "runtime이 in-process냐 원격 host냐"가 GUI에서 사라진다. P3의
//! `maru-sessiond` backend는 같은 `TermRuntimeBackend` 계약을 transport 위에서 구현해 이 파일을 대체/보완한다.
//!
//! web Term은 다루지 않는다 — web arm(`LiveSurface.web`)은 live PTY가 없는 sentinel surface라 terminal runtime
//! 계약의 대상이 아니다. web 슬롯 handle로 온 계약 호출은 terminal이 아니므로 `UnknownSurface`/null/no-op으로 떨어진다.

const builtin = @import("builtin");
const std = @import("std");
const terminal = @import("../terminal.zig");
const pty = @import("../pty.zig");
const resource_usage = @import("../session/resource_usage.zig"); // seam은 순수 타입을 쓴다(플랫폼 타입을 위로 올리지 않는다)
const surface_mod = @import("../session/surface.zig");
const live_surface_registry = @import("../session/live_surface_registry.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const core_command = @import("../session/core_command.zig");
const live_pty = @import("live_pty.zig");
const term_backend = @import("term_runtime_backend.zig");

const TermRuntimeBackend = term_backend.TermRuntimeBackend;
const RuntimeHandle = term_backend.RuntimeHandle;
const SpawnParams = term_backend.SpawnParams;

/// 앱 전역 `LiveSurface` 소유 레지스트리 타입 — `AppRuntime.live_registry`와 **같은** 인스턴스화라야 handle이
/// 같은 슬롯을 가리킨다(app_runtime.zig가 이 타입으로 필드를 둔다).
pub const LiveRegistry = live_surface_registry.LiveSurfaceRegistry(live_pty.LiveSurface);

pub const InProcessTermBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 소유는 `AppRuntime`이 한다 — adapter는 참조만 든다(창보다 오래 사는 앱 전역 자원, app_runtime.zig 참조).
    registry: *LiveRegistry,
    runtime: *runtime_mod.SurfaceRuntime,

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
        .read_observation = readObservation,
        .refresh_observation = readObservation,
        .dump_recent_text = dumpRecentText,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        registry: *LiveRegistry,
        runtime: *runtime_mod.SurfaceRuntime,
    ) InProcessTermBackend {
        return .{ .allocator = allocator, .io = io, .registry = registry, .runtime = runtime };
    }

    pub fn backend(self: *InProcessTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// handle이 가리키는 슬롯이 terminal arm이면 그 arm 포인터를, web arm/미등록이면 null을 돌려준다.
    /// live PTY 접근은 전부 이 helper를 거쳐 web/미등록 handle이 조용히 no-op/거부되게 한다.
    fn terminalSlot(self: *InProcessTermBackend, handle: RuntimeHandle) ?*live_pty.LiveSurface.Terminal {
        const slot = self.registry.findBySurface(handle) orelse return null;
        return switch (slot.*) {
            .terminal => |*t| t,
            .web => null,
        };
    }

    /// handle의 복구 가능한 `Surface`(그리드/스크롤백/코어)를 돌려준다 — terminal arm이면 그 surface, web/미등록이면 null.
    /// session-host(P3-e2d)가 화면 snapshot을 투영하려 코어를 lock한 채 읽을 때 이 accessor로 surface를 얻는다(LiveSurface
    /// arm 구조를 이 app 계층에 가둔다 — caller는 `*Surface`만 안다).
    pub fn surfaceFor(self: *InProcessTermBackend, handle: RuntimeHandle) ?*surface_mod.Surface {
        const t = self.terminalSlot(handle) orelse return null;
        return &t.surface;
    }

    /// session host owner-drain/quiesce 전용 수명 seam. 공용 `TermRuntimeBackend` vtable에 host-only 정책을
    /// 새기지 않고, host의 `RuntimeManager`만 pinned terminal bundle을 열거해 queue/reader lifecycle을 전진한다.
    pub fn terminalForHostLifecycle(self: *InProcessTermBackend, handle: RuntimeHandle) ?*live_pty.LiveSurface.Terminal {
        return self.terminalSlot(handle);
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*surface_mod.Surface {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        // control-plane self selector(MARU_PANE_ID)는 caller가 명시한 GUI surface id를 보존하고, 일반 in-process caller가
        // 비워 둔 경우에만 이 backend의 handle을 기본값으로 쓴다.
        var req = params.request;
        if (req.pane_id == null) req.pane_id = params.handle;

        // 슬롯을 앱 전역 registry에 잡고 terminal arm을 확정한다(undefined 슬롯에 arm 태그를 먼저 심어야 아래
        // &slot.terminal.X가 활성 arm을 가리킨다 — createTerm과 동일 계약).
        const slot = try self.registry.create(params.handle, 0);
        slot.* = .{ .terminal = .{ .internal_allocator = self.allocator } };

        // 부분 init 정리: live_pty/surface를 각각 in-place init하고, 성공 플래그로 갈라 그만큼만 sub-deinit +
        // removeUninitialized로 슬롯 메모리만 해제한다(deinit 없이). remove(=번들 deinit)는 둘 다 inited 가정이라
        // 부분 상태엔 못 쓴다 — createTerm의 2-pass 정리 계약을 그대로 옮긴 것.
        var live_initialized = false;
        var surface_initialized = false;
        errdefer {
            if (live_initialized) slot.terminal.live_pty.deinit();
            if (surface_initialized) slot.terminal.surface.deinit();
            self.registry.removeUninitialized(params.handle) catch {};
        }

        try slot.terminal.live_pty.init(self.io, self.allocator, params.handle, req, params.queue_capacity);
        live_initialized = true;

        slot.terminal.surface = try surface_mod.Surface.init(self.allocator, params.handle, params.size);
        surface_initialized = true;

        // reader가 시작되기 전의 원자적 bootstrap snapshot만 backend 계약으로 받는다. caller가 spawn 뒤 필드를 하나씩
        // 바꾸는 동안 child 첫 출력이 기본값으로 parse되는 race를 막고, 원격 host와 같은 first-output 의미론을 지킨다.
        // scrollback arena처럼 wire snapshot에 없는 client 메모리 정책은 계속 caller가 attach 전에 적용한다.
        if (params.initial_config) |config| core_command.apply(&slot.terminal.surface.core, .{ .set_runtime_config = config });
        return &slot.terminal.surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return error.UnknownSurface;
        return t.live_pty.attachSurface(self.runtime, &t.surface, process_in_reader);
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return error.UnknownSurface;
        return t.live_pty.pump(self.runtime);
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInput(handle, .{ .bytes = bytes });
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInputNonBlocking(handle, bytes);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.enqueueCoreCommand(handle, cmd, io);
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.resize(handle, size, io);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        if (self.terminalSlot(handle)) |t| t.live_pty.closeAndDetach(self.runtime);
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        if (self.terminalSlot(handle)) |t| t.live_pty.close();
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        if (self.terminalSlot(handle)) |t| t.live_pty.finishAfterTermination();
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        // 번들 deinit(reader join → custom_name 해제 → surface.deinit → 슬롯 해제). closeAndDetach/close로 종료를
        // 끝낸 뒤 부른다. 미등록 handle이면 registry가 error를 돌려주고 여기서 무시한다(멱등 teardown).
        self.registry.remove(handle) catch {};
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return null;
        return t.live_pty.session.foregroundProcessGroup();
    }

    fn resourceSamples(ctx: *anyopaque, handle: RuntimeHandle, out: []resource_usage.Sample) usize {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return 0;
        // 플랫폼 타입 → 순수 타입 변환은 **여기 한 곳**이다. seam 위(app_session)는 pty 타입을 모른다.
        var raw: [max_resource_samples]pty.types.ProcessResourceSample = undefined;
        const room = @min(out.len, raw.len);
        const n = t.live_pty.session.resourceSamples(raw[0..room]);
        for (raw[0..n], out[0..n]) |src, *dst| dst.* = .{
            .pid = src.pid,
            .footprint_bytes = src.footprint_bytes,
            .cpu_ns = src.cpu_ns,
        };
        return n;
    }

    /// 한 번에 변환할 표본 상한(스택 버퍼). 호출자가 더 큰 out을 줘도 이만큼씩만 채운다.
    const max_resource_samples: usize = 64;

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return 0;
        return t.live_pty.session.foregroundProcessNames(out);
    }

    fn readObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return error.UnknownSurface;

        // process 열거는 core lock과 무관하고 syscall을 포함하므로 lock 밖에서 먼저 끝낸다. include=false면 caller cache의
        // coherent foreground 값을 그대로 보존한다.
        var process_buf: [64]pty.types.ForegroundProcessName = undefined;
        const process_count = if (include_foreground) t.live_pty.session.foregroundProcessNames(&process_buf) else 0;
        const foreground_pgid = if (include_foreground) t.live_pty.session.foregroundProcessGroup() else out.foreground_pgid;
        const foreground_processes = if (include_foreground) process_buf[0..process_count] else out.foreground_processes.items;

        t.surface.lockCore(self.io);
        defer t.surface.unlockCore(self.io);
        const core = &t.surface.core;
        const progress = core.agentProgress();
        if (!include_foreground and progress.len == 0 and out.availability == .current) {
            const core_dest = core.sshRemoteDest();
            const same_dest = out.ssh_remote_dest_present == (core_dest != null) and
                (core_dest == null or std.mem.eql(u8, out.ssh_remote_dest.items, core_dest.?));
            if (same_dest and
                std.mem.eql(u8, out.cwd.items, core.currentCwd()) and
                // host도 비교한다 — 경로가 우연히 같고 host만 바뀌는 전이(로컬 /Users/me → 원격 /Users/me)에서
                // 이 skip이 갱신을 통째로 삼키면 원격 세션이 계속 로컬로 보인다.
                std.mem.eql(u8, out.cwd_host.items, core.currentCwdHost()) and
                std.mem.eql(u8, out.window_title.items, core.windowTitle()) and
                out.size.cols == core.size.cols and out.size.rows == core.size.rows and
                out.semantic_state == core.semantic_state and
                out.alt_active == core.alt_active and
                out.app_cursor_keys == core.application_cursor_keys and
                out.alternate_scroll == core.alternate_scroll)
            {
                // PTY output은 observer generation만 자주 바꾼다. metadata가 동일하면 문자열/process owned cache를
                // 매 100ms 재할당하지 않고 scalar generation만 전진시킨다.
                out.revision = core.observerGeneration();
                out.observer_generation = core.observerGeneration();
                out.title_generation = core.title_generation.load(.monotonic);
                return;
            }
        }
        try out.replace(allocator, .{
            .availability = .current,
            .revision = core.observerGeneration(),
            .observer_generation = core.observerGeneration(),
            .title_generation = core.title_generation.load(.monotonic),
            .size = core.size,
            .cwd = core.currentCwd(),
            .cwd_host = core.currentCwdHost(),
            .window_title = core.windowTitle(),
            .ssh_remote_dest = core.sshRemoteDest(),
            .semantic_state = core.semantic_state,
            .alt_active = core.alt_active,
            .app_cursor_keys = core.application_cursor_keys,
            .alternate_scroll = core.alternate_scroll,
            .foreground_available = if (include_foreground) true else out.foreground_available,
            .foreground_pgid = foreground_pgid,
            .foreground_processes = foreground_processes,
            .agent_progress = progress,
        });
        // owned cache로 복사 성공한 뒤에만 1회성 progress를 소비한다. OOM이면 core 값을 남겨 다음 poll에서 재시도한다.
        if (progress.len != 0) core.clearAgentProgress();
    }

    fn dumpRecentText(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        const self: *InProcessTermBackend = @ptrCast(@alignCast(ctx));
        const t = self.terminalSlot(handle) orelse return error.UnknownSurface;
        t.surface.lockCore(self.io);
        defer t.surface.unlockCore(self.io);
        return t.surface.core.dumpRecentTextUtf8(allocator, max_rows, max_bytes);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// in-process adapter 통합 테스트 (실 macOS PTY)
//
// 이 테스트가 증명하는 것: in-process adapter가 계약(spawn/attach/pump/finish/remove)을 실제 PTY·reader 스레드·
// 큐 위에서 정확히 구현한다 — GUI가 `*LivePtySession`을 전혀 만지지 않고 handle과 `TermRuntimeBackend`만으로
// 통제된 셸을 spawn해 종료까지 몰고 자원을 누수 없이 회수한다. fake 계약 테스트(term_runtime_backend.zig)가
// 라우팅·수명 표면을 non-macOS에서 고정한다면, 이 테스트는 실 PTY 경로에서 같은 계약이 성립함을 고정한다.
//
// 실 PTY라 macOS opt-in이다(non-macOS는 skip). testing.allocator가 누수를 검증한다(remove가 슬롯 번들을
// reader join까지 정리하지 않으면 실패).
// ─────────────────────────────────────────────────────────────────────────────

test "in-process term backend: contract drives a controlled command to termination and reclaims the slot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var registry = LiveRegistry.init(allocator);
    defer registry.deinit();
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var backend_impl = InProcessTermBackend.init(allocator, std.testing.io, &registry, &runtime);
    const be = backend_impl.backend();

    // spawn: GUI가 받는 것은 handle(아래 상수)과 *Surface뿐 — *LivePtySession은 backend 안에 있다.
    const handle: RuntimeHandle = 11;
    const surface = try be.spawn(.{
        .handle = handle,
        .request = .{ .command = "/bin/sh", .args = &.{ "-c", "printf 'contract ok\\n'" } },
        .size = .{ .cols = 20, .rows = 3 },
        .queue_capacity = 4,
    });
    try std.testing.expectEqual(handle, surface.id);

    // attach: controlled command라 process_in_reader=false(큐-드레인 경로). reader가 여기서 start된다.
    _ = try be.attach(handle, false);

    // pump: 종료까지 drain해 output/exit를 surface 코어에 반영한다.
    var event_pump = try be.pump(handle);
    const summary = try event_pump.drainBlockingUntilTermination();
    try std.testing.expect(summary.ended != null);

    // terminate + reclaim: 종료 관측 후 finish(reader join) → detach → 슬롯 회수. 누수 없이 끝나야 한다.
    be.finishAfterTermination(handle);
    be.closeAndDetach(handle);
    be.remove(handle);

    // 회수 후 같은 handle 조회는 없음(null) — 슬롯이 실제로 사라졌다.
    try std.testing.expect(registry.findBySurface(handle) == null);
}

test "in-process term backend: web-arm handle is not treated as a terminal runtime" {
    const allocator = std.testing.allocator;
    var registry = LiveRegistry.init(allocator);
    defer registry.deinit();
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var backend_impl = InProcessTermBackend.init(allocator, std.testing.io, &registry, &runtime);
    const be = backend_impl.backend();

    // web arm 슬롯을 직접 만들어(PTY 없음) terminal 계약이 그 handle을 terminal로 오인하지 않는지 본다.
    const handle: RuntimeHandle = 21;
    const slot = try registry.create(handle, 0);
    slot.* = .{ .web = .{ .internal_allocator = allocator } };
    slot.web.surface = try surface_mod.Surface.init(allocator, handle, .{ .cols = 1, .rows = 1 });

    // terminal 계약 호출은 web arm을 UnknownSurface/null/0으로 떨군다(live PTY가 없으니 조작하면 안 됨).
    try std.testing.expectError(error.UnknownSurface, be.attach(handle, false));
    try std.testing.expectError(error.UnknownSurface, be.pump(handle));
    try std.testing.expectEqual(@as(?i32, null), be.foregroundProcessGroup(handle));
    be.closeAndDetach(handle); // no-op(패닉/오조작 없이 통과)

    // web 슬롯 정리(remove가 web arm deinit = sentinel surface.deinit + 슬롯 해제).
    be.remove(handle);
    try std.testing.expect(registry.findBySurface(handle) == null);
}
