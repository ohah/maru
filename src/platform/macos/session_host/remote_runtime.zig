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

        // 1. runtime.spawn — host가 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, argv, size) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        const spawn_resp = try client.call("runtime.spawn", spawn_params);
        defer allocator.free(spawn_resp);
        self.runtime_id_hex = client_mod.extractRuntimeId(spawn_resp) orelse return error.SpawnFailed;
        // 이 지점부터 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지).
        errdefer self.terminateBestEffort();

        // 2. runtime.attach(controller) — stream_id + snapshot 순서(§10).
        var attach_buf: [96]u8 = undefined;
        const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{self.runtime_id_hex}) catch return error.AttachFailed;
        const attach_resp = try client.call("runtime.attach", attach_params);
        defer allocator.free(attach_resp);
        self.stream_id = client_mod.extractU64Field(attach_resp, "\"stream_id\":") orelse return error.AttachFailed;

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        const snap = try client.readSnapshot(self.stream_id);
        defer allocator.free(snap);
        self.remote_screen = try remote_screen.RemoteScreen.init(allocator);
        errdefer self.remote_screen.deinit();
        try self.remote_screen.applySnapshot(snap, io);

        // 4. 원격-backed Surface를 세운다(로컬 core는 placeholder — 렌더는 remote 소스로 간다).
        self.surface = try Surface.init(allocator, surface_id, size);
        self.surface.remote = self.remote_screen.screenSource();
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.terminateBestEffort();
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
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d},\"client_sequence\":0}}", .{ self.stream_id, cols, rows }) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.resize", params);
        self.allocator.free(resp);
    }

    /// 다음 delta batch 하나를 소비해 원격 화면에 반영한다(§10 delta_chunk stream). frame-loop(e3)가 매 프레임 부른다.
    /// GenerationGap이면 caller가 fresh snapshot을 재요청해야 한다(§9 — 이 재요청 배선도 e3).
    pub fn pumpDelta(self: *RemoteRuntime) (client_mod.ClientError || screen_assembler.ApplyError)!void {
        const d = try self.client.readDelta(self.stream_id);
        defer self.allocator.free(d);
        try self.remote_screen.applyDelta(d, self.io);
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

    // 입력을 보내면 host가 echo → 화면 row0이 바뀌고 delta가 온다. delta batch를 몇 번 소비해 Surface에 "h"가 반영되는지 본다.
    try rr.sendInput("hello\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 8 and !found) : (attempts += 1) {
        rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true;
    }
    try testing.expect(found); // 원격 runtime의 화면 변화가 client Surface에 반영됐다.
}
