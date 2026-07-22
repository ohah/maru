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
//! ⚠️미완(후속): (1) core command(scrollback/clear 등)는 host core를 만져야 하나 wire RPC가 없어 no-op(e3-3),
//! (2) foreground process group/names query wire 없음→null/0(agent observer 원격 미지원), (3) spawn이 argv/size만
//! 보내고 cwd/login/env는 아직 안 실음(RemoteRuntime.spawn 한계 — app_session 배선 전 확장 필요). macOS 전용
//! (client·Surface·app 계약).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const client_mod = @import("client.zig");
const remote_runtime = @import("remote_runtime.zig");

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
const RemoteRuntime = remote_runtime.RemoteRuntime;

/// 한 host connection 위의 원격 term backend. `client`는 borrowed(수명은 caller — app_session이 discovery/connect로 만든
/// connection). `runtimes`가 handle(=surface_id)↔`RemoteRuntime`를 잇는다. **`RemoteRuntime`은 self-referential**(surface.
/// remote가 자기 조립기를 가리킴)이라 heap에 개별 할당해 안정 주소를 준다(map value = `*RemoteRuntime`).
pub const RemoteTermBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.Client,
    // 앱의 in-process 라우팅 표(borrowed — 소유는 AppRuntime). attach가 원격 Term을 여기에 **원격 PtyIo**로 등록해,
    // GUI 입력 hot path(self.runtime.writeInput/resize/enqueueCoreCommand, surface.id 라우팅)가 in-process와 똑같이
    // 원격 Term에 도달하게 한다 — sink만 write_queue→client.sendInput/resize RPC로 갈린다(app_session hot path 무변경).
    // in-process Term은 write_queue PtyIo로 등록되는 것과 대칭. `remove`가 뗀다.
    surface_runtime: *SurfaceRuntime,
    runtimes: std.AutoHashMapUnmanaged(RuntimeHandle, *RemoteRuntime) = .empty,

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
        .foreground_process_names = foregroundProcessNames,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *client_mod.Client, surface_runtime: *SurfaceRuntime) RemoteTermBackend {
        return .{ .allocator = allocator, .io = io, .client = client, .surface_runtime = surface_runtime };
    }

    /// 남은 원격 runtime을 회수한다(각각 라우팅 표에서 detach + host terminate + client-side deinit). client connection과
    /// surface_runtime은 borrowed라 안 건드린다(소유는 caller).
    pub fn deinit(self: *RemoteTermBackend) void {
        var it = self.runtimes.iterator();
        while (it.next()) |kv| {
            self.surface_runtime.detachSurface(kv.key_ptr.*); // link(원격 PtyIo)를 먼저 뗀다 — rr.surface가 곧 무효.
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.runtimes.deinit(self.allocator);
        self.* = undefined;
    }

    /// GUI가 쓰는 계약 값(in-process와 동일 표면). ctx는 heap-pin된 backend를 가리켜야 한다(caller가 안정 주소 보장).
    pub fn backend(self: *RemoteTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// **이미 host에 있는 runtime에 재접속**해 원격-backed Surface를 만든다(§7 GUI 재접속, e3-5). spawn과 달리 새 runtime을
    /// 안 띄우고 저장된 `runtime_id_hex`에 붙는다. runtime이 없으면(host 재시작 등) attachExisting이 error를 내고 caller
    /// (app_session restore)가 fresh spawn으로 폴백한다. **vtable 밖 — host 전용**이라 app_session이 restore 경로에서 직접
    /// 부른다. spawn과 동일하게 반환 뒤 `attach`(vtable)로 원격 PtyIo를 라우팅 표에 등록해야 입력이 흐른다.
    pub fn attachTerm(self: *RemoteTermBackend, handle: RuntimeHandle, runtime_id_hex: [32]u8, size: maru.terminal.Size) anyerror!*Surface {
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        try rr.attachExisting(self.client, self.allocator, self.io, handle, runtime_id_hex, size);
        // 재접속은 **기존** host runtime이라 이후 단계(map put)가 실패해도 terminate 금지(§7 attach는 terminate 안 함) —
        // client-side(surface/screen)만 회수한다. spawn 경로는 방금 우리가 띄운 runtime이라 deinit(terminate)이 맞지만
        // attach는 남의 runtime이므로 detachClientSide로 되돌려야 재접속 실패가 세션을 죽이지 않는다.
        errdefer rr.detachClientSide();
        try self.runtimes.put(self.allocator, handle, rr);
        return &rr.surface;
    }

    /// handle의 host runtime_id(hex)를 돌려준다 — workspace capture가 저장해 재실행 시 `attachTerm`으로 재접속한다(§7, e3-5).
    /// 없으면(원격 아님·미등록) null.
    pub fn runtimeIdFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?[32]u8 {
        const rr = self.runtimes.get(handle) orelse return null;
        return rr.runtimeIdHex();
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*Surface {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        // argv = [command] ++ args (host의 spawnRuntime이 argv[0]=command, argv[1..]=args로 되돌린다). rr.spawn이 동기적으로
        // JSON escape 복사하므로 이 임시 슬라이스는 spawn 뒤 해제해도 안전하다.
        const argv = try self.allocator.alloc([]const u8, 1 + params.request.args.len);
        defer self.allocator.free(argv);
        argv[0] = params.request.command;
        for (params.request.args, 0..) |a, i| argv[i + 1] = a;

        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        try rr.spawn(self.client, self.allocator, self.io, params.handle, argv, params.size);
        errdefer rr.deinit(); // spawn 성공 후 map 삽입이 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지).
        try self.runtimes.put(self.allocator, params.handle, rr);
        return &rr.surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!RuntimeLink {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = process_in_reader; // 원격은 spawn이 이미 host에 controller attach했다(output은 host가 처리, 로컬 reader 없음).
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        // 원격 Term을 앱 라우팅 표에 **원격 PtyIo**로 등록한다(in-process가 write_queue PtyIo로 등록되는 것과 대칭).
        // 이후 self.runtime.writeInput/resize/enqueueCoreCommand(handle)가 이 PtyIo로 갈려 sendInput/resize RPC로 간다 —
        // GUI 입력 hot path는 로컬/원격을 모른다. handle=surface_id=pty_id라 라우팅 키 변환이 없다.
        return self.surface_runtime.attach(&rr.surface, handle, remotePtyIo(rr));
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!RuntimeEventPump {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        // 원격 pump: frame loop의 drainAvailable이 delta stream을 소비하도록 vtable을 심는다(e3-1). ctx=이 RemoteRuntime.
        return RuntimeEventPump.initRemote(self.allocator, .{ .ctx = rr, .drain = drainRemote });
    }

    /// `RemotePump.drain` — 원격 delta stream을 논블로킹으로 다 비워 `DrainSummary`를 만든다(로컬 큐 drain과 같은 의미).
    /// 적용된 배치 수만큼 output_events(→ metal_dirty), wire/apply 오류는 error로 던지지 않고 ended(read_error)로 바꿔
    /// frame loop가 surface를 exited로 표시하게 한다(로컬 read_error 계약과 동형 — host 연결 끊김 = 세션 종료).
    fn drainRemote(ctx: *anyopaque) DrainSummary {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        var summary: DrainSummary = .{};
        while (true) {
            const applied = rr.pumpDelta() catch |err| {
                // @errorName은 정적 문자열이라 DrainSummary.ended가 소비될 때까지 산다(runtime_pump.Termination 계약).
                if (summary.ended == null) summary.ended = .{ .read_error = @errorName(err) };
                break;
            };
            if (!applied) break; // idle — 더 없음.
            summary.output_events += 1;
        }
        return summary;
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return rr.sendInput(bytes);
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        try rr.sendInput(bytes); // socket write는 blocking writeAll이라 전량 전송으로 본다(paste도 host가 흡수).
        return bytes.len;
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: CoreCommand, io: std.Io) anyerror!void {
        _ = ctx;
        _ = handle;
        _ = cmd;
        _ = io;
        // 원격은 host가 core를 소유한다 — core command(scrollback/clear 등)를 host로 보내는 wire RPC는 후속(e3-3).
        // 지금은 no-op(계약 표면만 채운다). app_session은 아직 이 경로를 계약이 아니라 self.runtime으로 직접 부르므로
        // (e3 탐색이 확인한 우회) 현재 배선에선 원격 Term에 core command가 도달하지도 않는다.
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: maru.terminal.Size, io: std.Io) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = io;
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return rr.resize(size.cols, size.rows);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.get(handle)) |rr| rr.terminate(); // host runtime kill(멱등). client 객체는 remove가 회수.
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.get(handle)) |rr| rr.terminate();
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) void {
        _ = ctx;
        _ = handle;
        // 원격은 join할 로컬 reader 스레드가 없다(host가 소유). 종료는 drainRemote의 ended로 관측된다 — no-op.
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.fetchRemove(handle)) |kv| {
            self.surface_runtime.detachSurface(handle); // 라우팅 link(원격 PtyIo)를 먼저 뗀다 — rr.surface가 곧 무효.
            kv.value.deinit(); // host terminate(멱등) + surface/remote_screen 회수. 이후 handle과 surface 포인터는 무효.
            self.allocator.destroy(kv.value);
        }
    }

    /// 원격 Term을 **terminate 없이** 회수한다(§6 app-quit=detach, e3-6). `remove`와 대칭이되 host `runtime.terminate`를 안
    /// 보낸다 — 라우팅 link를 떼고 client-side rr만 free하므로 runtime이 host에 남아 재접속 대상이 된다(연결이 닫히면 host가
    /// controller를 detach로 처리해 유지). 앱 quit 시 host-backed Term에 쓴다(윈도우/탭 명시 close는 `remove`=terminate).
    /// **vtable 밖** — app_session deinit이 app_quitting일 때 직접 부른다.
    pub fn detachTerm(self: *RemoteTermBackend, handle: RuntimeHandle) void {
        if (self.runtimes.fetchRemove(handle)) |kv| {
            self.surface_runtime.detachSurface(handle);
            kv.value.detachClientSide(); // surface/remote_screen만 회수 — terminate 안 함(runtime 생존).
            self.allocator.destroy(kv.value);
        }
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        _ = ctx;
        _ = handle;
        return null; // 원격 foreground pgid query wire 없음(후속) — agent observer는 원격에서 미지원.
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []ForegroundProcessName) usize {
        _ = ctx;
        _ = handle;
        _ = out;
        return 0;
    }

    // ── 원격 PtyIo(SurfaceRuntime link의 input/resize sink) ─────────────────────────
    //
    // in-process는 link의 PtyIo가 live_pty write_queue를 가리키지만, 원격은 여기 세 함수가 그 자리를 채워 sendInput/
    // resize RPC로 보낸다. ctx=*RemoteRuntime. `enqueue_command`는 null로 둔다 — 원격 core command wire RPC가 없어
    // SurfaceRuntime이 placeholder core에 직접 적용으로 폴백한다(후속 e3; placeholder는 렌더 안 되므로 무해하나 config
    // 명령이 host core엔 도달 안 함). `write_input_nb`는 채운다(paste 논블로킹 계약 — socket write는 전량 전송으로 본다).

    fn remotePtyIo(rr: *RemoteRuntime) PtyIo {
        return .{
            .ctx = rr,
            .write_input = ioWriteInput,
            .resize_fn = ioResize,
            .write_input_nb = ioWriteInputNonBlocking,
        };
    }

    fn ioWriteInput(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.sendInput(bytes);
    }

    fn ioWriteInputNonBlocking(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        try rr.sendInput(bytes); // socket blocking writeAll — 전량 전송으로 본다(host가 흡수).
        return bytes.len;
    }

    fn ioResize(ctx: *anyopaque, size: maru.terminal.Size) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.resize(size.cols, size.rows);
    }
};

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

test "remote term backend: drives a real host runtime through the TermRuntimeBackend contract" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // 앱 라우팅 표(GUI 입력 hot path가 쓰는 그 표). backend가 원격 Term을 여기 등록한다.
    var surface_runtime = maru.app.SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();

    var be_impl = RemoteTermBackend.init(allocator, io, &client, &surface_runtime);
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

    be.closeAndDetach(1);
    be.remove(1); // client-side 회수(map 제거 + SurfaceRuntime detach + host terminate 멱등).
    try testing.expectEqual(@as(usize, 0), be_impl.runtimes.count());
    // remove가 라우팅 표에서도 뗐다 — 이제 hot path 입력은 UnknownSurface(dangling link 없음).
    try testing.expectError(error.UnknownSurface, surface_runtime.writeInput(1, .{ .bytes = "x" }));
}
