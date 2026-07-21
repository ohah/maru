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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *client_mod.Client) RemoteTermBackend {
        return .{ .allocator = allocator, .io = io, .client = client };
    }

    /// 남은 원격 runtime을 회수한다(각각 host terminate + client-side deinit). client connection은 borrowed라 안 닫는다.
    pub fn deinit(self: *RemoteTermBackend) void {
        var it = self.runtimes.valueIterator();
        while (it.next()) |rr| {
            rr.*.deinit();
            self.allocator.destroy(rr.*);
        }
        self.runtimes.deinit(self.allocator);
        self.* = undefined;
    }

    /// GUI가 쓰는 계약 값(in-process와 동일 표면). ctx는 heap-pin된 backend를 가리켜야 한다(caller가 안정 주소 보장).
    pub fn backend(self: *RemoteTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
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
        if (!self.runtimes.contains(handle)) return error.UnknownSurface;
        return .{ .surface_id = handle, .pty_id = handle }; // in-process 라우팅 상관 쌍의 원격 대응(handle이 두 역할 겸함).
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
            kv.value.deinit(); // host terminate(멱등) + surface/remote_screen 회수. 이후 handle과 surface 포인터는 무효.
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

    var be_impl = RemoteTermBackend.init(allocator, io, &client);
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

    _ = try be.attach(1, true); // 원격은 no-op이지만 계약 표면을 탄다(RuntimeLink 반환).
    var frame_pump = try be.pump(1); // 원격 모드 RuntimeEventPump.

    // 입력을 계약으로 보내면 host가 echo → delta가 온다. pump.drainAvailable()(원격 drain)로 소비해 Surface에 "h"가
    // 반영되는지 폴링한다(host delta tick ~20ms).
    try be.writeInput(1, "hello\n");
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
    try testing.expect(found); // 계약을 통한 원격 runtime의 화면 변화가 Surface에 반영됐다.

    be.closeAndDetach(1);
    be.remove(1); // client-side 회수(map에서 제거 + host terminate 멱등).
    try testing.expectEqual(@as(usize, 0), be_impl.runtimes.count());
}
