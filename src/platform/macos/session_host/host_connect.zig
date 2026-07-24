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
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;

pub const Options = struct {
    /// spawn 뒤(또는 lock loser로서) host가 뜰 때까지 재connect 시도 횟수 × 간격. 기본 150×20ms=3s(cold launch 여유).
    connect_attempts: usize = 150,
    connect_delay_ms: u32 = 20,
};

pub const FailureReason = enum {
    invalid_endpoint,
    endpoint_denied,
    incompatible_version,
    handshake_failed,
    protocol_error,
    launch_failed,
    startup_timeout,
    out_of_memory,
};

pub const Outcome = union(enum) {
    connected: client_mod.Client,
    failed: FailureReason,
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
    return switch (connectOrLaunchDetailed(allocator, exe_path, base_cache_dir, opts)) {
        .connected => |client| client,
        .failed => null,
    };
}

pub fn connectOrLaunchDetailed(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) Outcome {
    if (builtin.os.tag != .macos) return .{ .failed = .invalid_endpoint };

    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return .{ .failed = .invalid_endpoint };
    var sock_buf: [640]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return .{ .failed = .invalid_endpoint };

    // 1. connect-first(§10): 있으면 바로 쓴다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return .{ .connected = client },
        .absent => {},
        .transient => return connectWithBackoffDetailed(allocator, socket, opts),
        .failed => |reason| return .{ .failed = reason },
    }

    // 2. need_start_lock: lock 파일을 열고 nonblocking flock으로 "내가 시작 책임인가"를 가른다. lock은 fd close로 해제되며,
    // spawn+재connect가 끝날 때까지(defer) 잡고 있어 동시 시작자들이 하나의 host로 수렴하게 한다(daemon은 socket bind가
    // liveness라 lock을 안 쓴다 — 순수 시작 직렬화용).
    ensureDir(dir);
    const lock_fd = openLock(dir) orelse return .{ .failed = .endpoint_denied };
    defer _ = c.close(lock_fd);
    const lock_probe: discovery.LockProbe = if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) .acquired else .contended;

    // 3. lock 취득/경합 뒤 다시 connect(§10 "lock 직전 race"): 그 사이 다른 프로세스가 bind했을 수 있다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return .{ .connected = client },
        .transient => return connectWithBackoffDetailed(allocator, socket, opts),
        .failed => |reason| return .{ .failed = reason },
        .absent => {},
    }
    if (lock_probe == .contended) return connectWithBackoffDetailed(allocator, socket, opts);

    // detached helper 띄우기: `maru __session-host <socket>`(daemon이 socket dirname으로 dir 도출).
    launcher.spawnSessionHostDetached(allocator, exe_path, socket) catch return .{ .failed = .launch_failed };
    return connectWithBackoffDetailed(allocator, socket, opts);
}

const TryConnectResult = union(enum) {
    connected: client_mod.Client,
    absent,
    transient,
    failed: FailureReason,
};

fn connectFailure(err: client_mod.ClientError) TryConnectResult {
    return switch (err) {
        error.EndpointAbsent => .absent,
        error.EndpointTransient => .transient,
        error.EndpointDenied => .{ .failed = .endpoint_denied },
        error.IncompatibleVersion => .{ .failed = .incompatible_version },
        error.HandshakeFailed, error.ConnectionClosed, error.WriteFailed => .{ .failed = .handshake_failed },
        error.ProtocolError, error.EventQueueFull => .{ .failed = .protocol_error },
        error.OutOfMemory => .{ .failed = .out_of_memory },
    };
}

test "host_connect preserves endpoint and handshake failure classes" {
    try testing.expect(connectFailure(error.EndpointAbsent) == .absent);
    try testing.expect(connectFailure(error.EndpointTransient) == .transient);
    try testing.expectEqual(FailureReason.endpoint_denied, connectFailure(error.EndpointDenied).failed);
    try testing.expectEqual(FailureReason.incompatible_version, connectFailure(error.IncompatibleVersion).failed);
    try testing.expectEqual(FailureReason.handshake_failed, connectFailure(error.ConnectionClosed).failed);
    try testing.expectEqual(FailureReason.protocol_error, connectFailure(error.ProtocolError).failed);
    try testing.expectEqual(FailureReason.out_of_memory, connectFailure(error.OutOfMemory).failed);
}

/// 한 번 connect를 시도하되 endpoint 부재/권한/일시 오류와 wire 실패를 잃지 않는다.
fn tryConnect(allocator: std.mem.Allocator, socket: [:0]const u8) TryConnectResult {
    if (client_mod.Client.connect(allocator, socket, "gui")) |client| {
        return .{ .connected = client };
    } else |err| {
        return connectFailure(err);
    }
}

fn connectWithBackoffDetailed(allocator: std.mem.Allocator, socket: [:0]const u8, opts: Options) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnect(allocator, socket)) {
            .connected => |client| return .{ .connected = client },
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
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
// 발견 실행층이 실제 socket/flock/connect로 도는지 고정한다. use_connection(이미 뜬 host에 붙음), 제품 `maru`
// 바이너리의 spawn_host argv/hidden-command 진입, 폴백(host도 없고 spawn도 실패 → null로 in-process 유지)을 검증한다.
// 실 syscall이라 macOS opt-in.
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

test "host_connect: launches the product maru session host and completes host.info" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!@hasDecl(@import("root"), "require_product_launch_smoke")) return error.SkipZigTest;
    const allocator = testing.allocator;
    const product_exe_raw = std.c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse {
        try testing.expect(false); // macOS 공식 build wiring이 product artifact 주입을 잃으면 skip이 아니라 실패한다.
        return;
    };
    const product_exe: [:0]const u8 = std.mem.span(product_exe_raw);

    // PID만 쓰면 강제 종료 뒤 PID 재사용 시 stale host에 connect-first로 붙어 새 product exec를 건너뛸 수 있다.
    // CSPRNG nonce + 배타적 mkdir로 매 실행의 launch 경로가 비어 있음을 보장한다.
    var nonce: u64 = undefined;
    arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-product-{d}-{x}", .{ c.getpid(), nonce }) catch return error.SkipZigTest;
    try testing.expectEqual(@as(c_int, 0), c.mkdir(base.ptr, 0o700));

    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var sock_buf: [320]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return error.SkipZigTest;
    try testing.expect(c.access(socket.ptr, 0) != 0);

    defer {
        _ = c.unlink(socket.ptr);
        var lock_buf: [320]u8 = undefined;
        if (discovery.lockPathIn(&lock_buf, dir)) |lock| _ = c.unlink(lock.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    {
        var client = connectOrLaunch(allocator, product_exe, base, .{}) orelse {
            try testing.expect(false);
            return;
        };
        defer client.deinit();
        const response = try client.call("host.info", null);
        defer allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"runtime_count\":0") != null);
    }

    // oneshot host가 client EOF를 받고 정상 deinit하여 socket을 지웠는지까지 확인한다.
    var stopped = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (c.access(socket.ptr, 0) != 0) {
            stopped = true;
            break;
        }
        _ = usleep(20 * 1000);
    }
    try testing.expect(stopped);
}
