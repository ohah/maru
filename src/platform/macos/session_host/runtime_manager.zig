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

const InProcessTermBackend = maru.app.InProcessTermBackend;
const LiveRegistry = maru.app.in_process_term_backend.LiveRegistry;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const RuntimeHandle = maru.app.TermRuntimeHandle;

// host runtime의 PTY→core 이벤트 큐 용량. 제품 경로(app_session.default_queue_capacity)와 같은 16으로 맞춰
// 재접속한 GUI가 in-process와 같은 backpressure를 보게 한다(e2d stream이 이 큐를 소비).
const default_queue_capacity: usize = 16;

// macOS libc CSPRNG(std.posix 미노출 — 이 파일은 macOS 전용). runtime_id 발급용.
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;

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

    /// self-referential 필드를 안정 주소로 세운다. caller가 준 `*RuntimeManager` 슬롯을 채운다(반환 이동 없음).
    pub fn init(self: *RuntimeManager, allocator: std.mem.Allocator, io: std.Io, host_registry: *reg.TerminalRuntimeRegistry) void {
        self.allocator = allocator;
        self.io = io;
        self.live_registry = LiveRegistry.init(allocator);
        self.surface_runtime = SurfaceRuntime.init(allocator);
        self.backend_impl = InProcessTermBackend.init(allocator, io, &self.live_registry, &self.surface_runtime);
        self.host_registry = host_registry;
        self.next_handle = 1;
    }

    /// 소유 registry를 해제한다. **호출 전 모든 runtime이 terminate돼 있어야** 한다(reader join·슬롯 회수가 terminate에서
    /// 일어난다) — 남은 runtime이 있으면 reader 스레드가 join되지 않은 채 슬롯이 사라진다. graceful 종료 경로(§6)가 붙기
    /// 전까지 host는 SIGTERM으로 내려가 OS가 자식·스레드를 회수하므로 이 deinit은 clean-return 경로용이다.
    pub fn deinit(self: *RuntimeManager) void {
        self.surface_runtime.deinit();
        self.live_registry.deinit();
        self.* = undefined;
    }

    /// server.zig가 dispatch에 넘길 중립 vtable. `ctx`는 이 매니저다.
    pub fn runtimeOps(self: *RuntimeManager) server.RuntimeOps {
        return .{ .ctx = self, .spawn = spawnOp, .terminate = terminateOp, .write_input = writeInputOp, .resize = resizeOp };
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

        _ = try be.spawn(.{
            .handle = handle,
            .request = .{
                .command = params.argv[0],
                .args = args,
                .cwd = params.cwd,
                .pane_id = handle, // control-plane self selector = handle(in-process 계약과 동일).
                .size = size,
            },
            .size = size,
            .queue_capacity = default_queue_capacity,
        });
        // 여기부터 실패하면 방금 만든 runtime을 회수한다(closeAndDetach로 PTY/자식/reader 종료 → remove로 reader join+슬롯 해제).
        errdefer {
            be.closeAndDetach(handle);
            be.remove(handle);
        }
        _ = try be.attach(handle, true); // reader 시작. host runtime은 output을 core에 직접 반영한다(stream은 e2d).

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
        self.host_registry.unregister(runtime_id);
    }
};

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
