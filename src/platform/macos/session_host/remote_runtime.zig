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
const client_mod = @import("client.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("screen_assembler.zig");

/// 한 원격 runtime. self-referential(`surface.remote`가 `&self.remote_screen`을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    client: *client_mod.Client, // borrowed — 여러 runtime이 한 connection을 공유한다(stream_id로 구분).
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    stream_id: u64, // attach가 발급한 stream — input/resize/delta 라우팅.
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    remote_screen: remote_screen.RemoteScreen, // 조립기+cell 격자(surface의 화면 소스).
    surface: Surface, // 원격-backed(surface.remote = remote_screen.screenSource()). GUI가 이걸 렌더.

    /// host에 runtime을 띄우고(`runtime.spawn`) controller로 attach한 뒤 첫 snapshot을 조립해 원격 Surface를 세운다.
    /// 실패 시 이미 띄운 host runtime을 회수한다(orphan 방지). `argv`/`size`는 spawn할 셸 스펙이다.
    pub fn spawn(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        argv: []const []const u8,
        size: terminal.Size,
    ) anyerror!void {
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;

        // 1. runtime.spawn — host가 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, argv, size) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        const spawn_resp = try client.call("runtime.spawn", spawn_params);
        defer allocator.free(spawn_resp);
        self.runtime_id_hex = client_mod.extractRuntimeId(spawn_resp) orelse return error.SpawnFailed;
        // 이 지점부터 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지) — spawn한 건 우리 소유다.
        errdefer self.terminateBestEffort();

        try self.attachAndAssemble(surface_id, size);
    }

    /// **이미 host에 있는 runtime에 재접속**한다(spawn 없이) — GUI를 재실행하면 workspace가 저장한 `runtime_id_hex`로 같은
    /// host runtime에 붙어 화면·PID·scrollback을 잇는다(§7). runtime이 없으면(host 재시작·runtime 종료 등) attach가
    /// `error.AttachFailed`(host RuntimeNotFound → 응답에 stream_id 없음)를 내고, caller가 fresh `spawn`으로 폴백한다.
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
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    /// spawn/attachExisting 공통(§10 attach 순서): controller attach(stream_id) → 첫 snapshot 조립 → 원격-backed Surface.
    /// `self.runtime_id_hex`가 이미 채워져 있어야 한다(spawn=runtime.spawn 응답, attachExisting=저장된 값).
    fn attachAndAssemble(self: *RemoteRuntime, surface_id: u64, size: terminal.Size) anyerror!void {
        // 2. runtime.attach(controller) — stream_id + snapshot 순서(§10).
        var attach_buf: [96]u8 = undefined;
        const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{self.runtime_id_hex}) catch return error.AttachFailed;
        const attach_resp = try self.client.call("runtime.attach", attach_params);
        defer self.allocator.free(attach_resp);
        self.stream_id = client_mod.extractU64Field(attach_resp, "\"stream_id\":") orelse return error.AttachFailed;

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        const snap = try self.client.readSnapshot(self.stream_id);
        defer self.allocator.free(snap);
        self.remote_screen = try remote_screen.RemoteScreen.init(self.allocator);
        errdefer self.remote_screen.deinit();
        try self.remote_screen.applySnapshot(snap, self.io);

        // 4. 원격-backed Surface를 세운다(로컬 core는 placeholder — 렌더는 remote 소스로 간다).
        self.surface = try Surface.init(self.allocator, surface_id, size);
        self.surface.remote = self.remote_screen.screenSource();
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.terminateBestEffort();
        self.surface.deinit();
        self.remote_screen.deinit();
        self.* = undefined;
    }

    /// client-side 자원만 회수한다(surface/screen) — **host runtime은 안 죽인다**(terminate 안 보냄). 앱 quit 시 host-backed
    /// Term을 이걸로 정리하면 runtime이 host에 남아(연결 EOF를 host가 detach로 처리해 유지, §6 app-quit=detach) GUI 재실행 시
    /// `attachExisting`으로 재접속한다. `deinit`과 대칭이되 terminate만 뺀다.
    pub fn detachClientSide(self: *RemoteRuntime) void {
        self.surface.deinit();
        self.remote_screen.deinit();
        self.* = undefined;
    }

    /// 렌더/입력 라우팅에 쓸 Surface(GUI가 in-process처럼 다룬다).
    pub fn surfacePtr(self: *RemoteRuntime) *Surface {
        return &self.surface;
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
        return self.client.sendInput(self.stream_id, bytes);
    }

    /// canonical PTY size를 바꾼다(host `runtime.resize`). host가 실 `TerminalCore`+`TIOCSWINSZ`에 적용한다.
    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) client_mod.ClientError!void {
        self.resize_seq += 1; // 단조 증가 — registry가 이하 sequence를 stale로 거부(첫 resize만 적용되는 버그 방지).
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d},\"client_sequence\":{d}}}", .{ self.stream_id, cols, rows, self.resize_seq }) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.resize", params);
        self.allocator.free(resp);
    }

    /// 다음 화면 stream 배치 하나를 소비해 원격 화면에 반영한다(§9/§10). **논블로킹** — 배치가 없으면(idle) `false`를, 하나
    /// 소비했으면 `true`를 돌려준다(caller가 배치가 있는 동안 반복해 다 비운다 — `RemoteTermBackend`의 drain이 이걸로
    /// `RuntimeEventPump.drainAvailable`과 같은 의미를 만든다). host가 grid/alt 변화 시 delta 대신 fresh snapshot을 push하므로
    /// 둘 다 처리한다(is_snapshot이면 화면 리셋, 아니면 증분). 다른 runtime의 배치는 화면엔 반영 안 하되 소비는 됐으니 `true`.
    pub fn pumpDelta(self: *RemoteRuntime) (client_mod.ClientError || screen_assembler.ApplyError)!bool {
        const batch = (try self.client.readStreamBatch(self.allocator)) orelse return false; // idle.
        defer self.allocator.free(batch.bytes);
        if (batch.stream_id != self.stream_id) return true; // 다른 runtime(멀티) — 소비만, 화면 미반영(라우팅은 e3 프레임 루프).
        if (batch.is_snapshot) {
            try self.remote_screen.applySnapshot(batch.bytes, self.io); // §9 fresh snapshot(grid/alt 변화) → 화면 리셋.
        } else {
            try self.remote_screen.applyDelta(batch.bytes, self.io);
        }
        return true;
    }

    /// host runtime을 종료한다(client-side 자원은 남긴다 — 회수는 `deinit`). `TermRuntimeBackend.close_and_detach`/`close`가
    /// 부른다(계약: routing 끊고 프로세스 kill). 멱등(host가 없는 id 무시). client 객체는 이후 `remove`→`deinit`에서 회수한다.
    pub fn terminate(self: *RemoteRuntime) void {
        self.terminateBestEffort();
    }

    fn terminateBestEffort(self: *RemoteRuntime) void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return;
        const resp = self.client.call("runtime.terminate", params) catch return;
        self.allocator.free(resp);
    }
};

/// `{argv:[...], cols, rows}` spawn params를 JSON으로 만든다(caller free). argv는 임의 바이트라 실 JSON encoder로 escape한다
/// (client hand-built JSON의 신뢰 계약 밖 — client.zig 주석대로 임의 argv는 stringify로).
fn buildSpawnParams(allocator: std.mem.Allocator, argv: []const []const u8, size: terminal.Size) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(.{ .argv = argv, .cols = size.cols, .rows = size.rows }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
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
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // client-side 원격 runtime: /bin/cat을 띄우고 원격-backed Surface를 세운다.
    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

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
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
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

    // 없는 runtime_id에 attachExisting → error.AttachFailed(host RuntimeNotFound). app_session restore가 이 신호로 fresh
    // spawn 폴백한다. 실패해도 남의 runtime을 안 죽인다(terminate errdefer 없음).
    var bogus: RemoteRuntime = undefined;
    const bogus_id: [32]u8 = "deadbeefdeadbeefdeadbeefdeadbeef".*;
    try testing.expectError(error.AttachFailed, bogus.attachExisting(&client, allocator, io, 2, bogus_id, .{ .cols = 40, .rows = 10 }));
}
