//! host_connect — client의 **connect-or-launch 오케스트레이션**(§10 발견 실행층) — P3-e3-4.
//!
//! `discovery.zig`(순수 state machine)의 결정을 실 syscall(connect/flock/spawnDetached)로 **수행**한다: host가 있으면
//! 붙고, 없으면 detached helper를 **하나만** 띄워 붙는다(여러 GUI가 동시에 시작해도 중복 spawn 없이 — start lock winner만
//! spawn). AppSession이 keep-alive일 때 이걸 불러 host connection을 얻는다(e3-4b). 실패하면 null → caller가 in-process로
//! 폴백한다(host 문제가 GUI를 막지 않는다). macOS 전용(실 fork/exec/flock; 순수 결정은 discovery.zig가 이미 테스트).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const discovery = @import("discovery.zig");
const launcher = @import("launcher.zig");
const client_mod = @import("client.zig");

// flock(2)은 std.c 미노출(macOS 전용). start lock 직렬화용. LOCK_EX=2·LOCK_NB=4(sys/file.h).
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
extern "c" fn usleep(usec: c_uint) c_int;

pub const Options = struct {
    /// spawn 뒤(또는 lock loser로서) host가 뜰 때까지 재connect 시도 횟수 × 간격. 기본 150×20ms=3s(cold launch 여유).
    connect_attempts: usize = 150,
    connect_delay_ms: u32 = 20,
};

/// host에 연결하거나(있으면) detached helper를 띄워 연결한다(§10 connect-first→start-lock→spawn). 반환 `Client`는
/// **caller 소유**(deinit 책임). `null`이면 host를 못 얻었다(권한 거부·spawn 실패·denied 등) — caller는 in-process로
/// 폴백한다. `exe_path`=현재 maru 실행 파일(helper로 exec), `base_cache_dir`=user cache dir(그 아래 `session-host/`).
pub fn connectOrLaunch(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) ?client_mod.Client {
    if (builtin.os.tag != .macos) return null;

    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return null;
    var sock_buf: [640]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return null;

    // 1. connect-first(§10): 있으면 바로 쓴다.
    var first = tryConnect(allocator, socket);
    switch (discovery.afterConnect(.spawn_ready, first.probe)) {
        .use_connection => return first.client,
        .need_start_lock => {}, // 아래 start-lock 경로.
        // host_unavailable(spawn_ready라 안 옴)·fail_denied·기타 → in-process 폴백.
        else => {
            if (first.client) |*cl| cl.deinit();
            return null;
        },
    }

    // 2. need_start_lock: lock 파일을 열고 nonblocking flock으로 "내가 시작 책임인가"를 가른다. lock은 fd close로 해제되며,
    // spawn+재connect가 끝날 때까지(defer) 잡고 있어 동시 시작자들이 하나의 host로 수렴하게 한다(daemon은 socket bind가
    // liveness라 lock을 안 쓴다 — 순수 시작 직렬화용).
    ensureDir(dir);
    const lock_fd = openLock(dir) orelse return null; // lock 못 열면(권한 등) 폴백.
    defer _ = c.close(lock_fd);
    const lock_probe: discovery.LockProbe = if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) .acquired else .contended;

    // 3. lock 취득/경합 뒤 다시 connect(§10 "lock 직전 race"): 그 사이 다른 프로세스가 bind했을 수 있다.
    var second = tryConnect(allocator, socket);
    switch (discovery.afterStartLock(lock_probe, second.probe)) {
        .use_connection => return second.client, // 방금 다른 winner가 띄운 host.
        .spawn_host => {
            if (second.client) |*cl| cl.deinit(); // 방어(연결됐으면 use_connection이었어야).
            // detached helper 띄우기: `maru __session-host <socket>`(daemon이 socket dirname으로 dir 도출).
            launcher.spawnDetached(allocator, exe_path, &[_][:0]const u8{socket}) catch return null;
            return connectWithBackoff(allocator, socket, opts); // 뜰 때까지 재시도.
        },
        .wait_and_connect => {
            if (second.client) |*cl| cl.deinit();
            return connectWithBackoff(allocator, socket, opts); // loser는 winner의 host를 기다린다.
        },
        // fail_denied 등 → 폴백.
        else => {
            if (second.client) |*cl| cl.deinit();
            return null;
        },
    }
}

const ConnectResult = struct { probe: discovery.ConnectProbe, client: ?client_mod.Client };

/// 한 번 connect를 시도해 probe와(성공 시) Client를 함께 준다. `ConnectFailed`=host 없음(absent, spawn 가능), 그 외
/// 오류=denied(host가 있으나 못 씀 — spawn-storm 방지로 폴백). 성공하면 client를 담아 돌려준다(caller가 소유/deinit).
fn tryConnect(allocator: std.mem.Allocator, socket: [:0]const u8) ConnectResult {
    if (client_mod.Client.connect(allocator, socket, "gui")) |cl| {
        return .{ .probe = .connected, .client = cl };
    } else |err| {
        return .{
            .probe = switch (err) {
                error.ConnectFailed => .absent,
                else => .denied, // IncompatibleVersion·HandshakeFailed 등: host는 있으나 못 씀 → 새로 안 띄운다.
            },
            .client = null,
        };
    }
}

fn connectWithBackoff(allocator: std.mem.Allocator, socket: [:0]const u8, opts: Options) ?client_mod.Client {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        if (client_mod.Client.connect(allocator, socket, "gui")) |cl| return cl else |_| {}
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return null;
}

/// session-host 디렉터리를 0700으로 만든다(best-effort — EEXIST 무해). lock 파일 생성에 필요하다. 소유/perm의 진짜
/// 검증은 host `SocketServer.bind`가 fstatat(SYMLINK_NOFOLLOW)로 한다(§11) — 여기선 lock을 놓을 자리만 확보한다.
fn ensureDir(dir: [:0]const u8) void {
    _ = c.mkdir(dir.ptr, 0o700);
}

fn openLock(dir: [:0]const u8) ?c.fd_t {
    var lock_buf: [640]u8 = undefined;
    const lock = discovery.lockPathIn(&lock_buf, dir) catch return null;
    const fd = c.open(lock.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return null;
    return fd;
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork host에 connect-first로 붙고, host 없을 땐 폴백)
//
// 이 테스트가 증명하는 것(그리고 왜 e3에서 중요한가): keep-alive GUI가 시작할 때 "있으면 붙고 없으면 하나 띄운다"는
// 발견 실행층이 실제 socket/flock/connect로 도는지 고정한다. use_connection(이미 뜬 host에 붙음)과 폴백(host도 없고
// spawn도 실패 → null로 in-process 유지)을 검증한다. 실 maru 바이너리를 helper로 exec하는 spawn_host end-to-end는
// OS E2E(§14) 몫이라(테스트 바이너리엔 maru exe 경로가 없다) 여기선 다루지 않는다. 실 syscall이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const daemon = @import("daemon.zig");

test "host_connect: connect-first attaches to an already-running host (no spawn)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hc-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // 제품에선 base=user cache dir(이미 존재). host bind는 <base>/session-host만 mkdir하므로 base를 먼저 만든다.
    // discovery 경로와 **동일하게** host를 띄운다: <base>/session-host/{control.sock}.
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var sock_buf: [320]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir, socket) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var lp_buf: [320]u8 = undefined;
        if (discovery.lockPathIn(&lp_buf, dir)) |lp| _ = c.unlink(lp.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    // host가 bind할 때까지 잠깐 기다렸다가 connect-first로 붙는다(spawn 없이). exe_path는 이 경로에선 안 쓰이므로 더미.
    // (호스트가 아직 안 떴으면 첫 connect가 absent→start-lock→우리가 spawn을 시도하는데, 더미 exe라 폴백될 수 있어
    //  host가 확실히 뜰 때까지 기다린 뒤 부른다.)
    var up = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (client_mod.Client.connect(allocator, socket, "gui")) |cl| {
            var probe = cl;
            probe.deinit();
            up = true;
            break;
        } else |_| _ = usleep(20 * 1000);
    }
    try testing.expect(up);

    var client = connectOrLaunch(allocator, "/nonexistent-maru", base, .{ .connect_attempts = 5, .connect_delay_ms = 10 }) orelse {
        try testing.expect(false);
        return;
    };
    defer client.deinit();
    try testing.expect(client.host_id != 0); // hello_ack로 host_id를 받은 유효한 연결.
}

test "host_connect: falls back to null when no host exists and spawn cannot bind" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hcf-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // base 존재 → spawn_host 경로를 실제로 탄다(lock 취득→spawn 실패→backoff→null).
    defer {
        // 테스트가 만든 dir/lock 정리(host는 안 떴다).
        var dir_buf: [256]u8 = undefined;
        if (discovery.sessionHostDirPath(&dir_buf, base)) |dir| {
            var lp_buf: [320]u8 = undefined;
            if (discovery.lockPathIn(&lp_buf, dir)) |lp| _ = c.unlink(lp.ptr) else |_| {}
            _ = c.rmdir(dir.ptr);
        } else |_| {}
        _ = c.rmdir(base.ptr);
    }

    // host 없음 + helper exe가 bind 못 함(/nonexistent → exec 실패 _exit 127) → 짧은 backoff 뒤 null(in-process 폴백).
    const result = connectOrLaunch(allocator, "/nonexistent-maru-helper", base, .{ .connect_attempts = 3, .connect_delay_ms = 10 });
    try testing.expect(result == null);
}
