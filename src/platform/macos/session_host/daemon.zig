//! `maru-sessiond` entrypoint — 별도 프로세스로 뜨는 session host의 accept loop(§6 host 수명, §10) — P3-d2c.
//!
//! GUI가 `maru __session-host <socket_path>`로 detached spawn하면(P3-d2c launcher/main 배선) 이 함수가 그 자식
//! 프로세스의 본체가 된다: host_id를 발급하고, 주입받은 경로에 unix socket을 bind(P3-d2a `SocketServer`)한 뒤, poll-gated
//! accept loop로 client 연결을 받아 `Connection` dispatch(P3-d1)로 hello/command에 응답한다. 부모(GUI)가 종료해도 이
//! 프로세스는 자기 세션(`setsid`)에서 독립적으로 살아 남는다 — 그것이 "GUI를 죽여도 host 생존"의 실체다.
//!
//! macOS 전용(실 socket/fork syscall). 현재 host는 `RuntimeManager`를 함께 소유하고 `runtime.spawn`/attach/input/resize/
//! terminate와 화면 stream을 처리한다. 초기 P3-d2c process smoke는 빈 registry에서 hello·host.info 왕복으로
//! "부모와 독립된 프로세스가 socket을 소유하고 재접속에 응답한다"는 핵심 수명 계약을 먼저 실증했다.
//!
//! 종료: 제품 loop는 `SIGTERM`의 기본 동작으로 끝나며 남은 socket 파일은 다음 bind가 안전하게 회수한다(P3-d2a 계약).
//! product-path process smoke만 `/tmp/maru-sh-product-*` socket과 test env가 함께 있을 때 첫 연결 뒤 정상 deinit한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const socket_server = @import("socket_server.zig");
const reg = @import("registry.zig");
const runtime_manager = @import("runtime_manager.zig");
const upgrade = @import("upgrade_coordinator.zig");

pub const RunError = socket_server.BindError || error{OutOfMemory};

// macOS/BSD libc의 CSPRNG와 sleep(std.posix 미노출이라 직접 extern — daemon은 macOS 전용).
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;

/// accept loop 한 tick의 poll timeout(ms). 이 주기로 깨어나 listen fd 상태를 확인한다(향후 idle-grace 종료 판정 자리).
pub const poll_timeout_ms: i32 = 200;

/// 128-bit host_id를 발급한다(§4 opaque random). macOS `arc4random_buf`는 실패하지 않는 CSPRNG라 별도 fallback이 없다.
fn newHostId() u128 {
    var bytes: [16]u8 = undefined;
    arc4random_buf(&bytes, bytes.len);
    return std.mem.readInt(u128, &bytes, .big);
}

/// session host 본체. `dir_path`(0700)에 `socket_path`(0600)로 bind하고 SIGTERM(프로세스 종료)까지 accept loop를 돈다.
/// 개별 연결의 serve 오류는 무시하고 다른 client를 계속 받는다(한 client가 host를 못 죽인다, §9 bounded client).
/// `io`는 `runtime_manager`가 실 PTY runtime(reader/큐)을 소유하는 데 쓴다 — spawn/terminate가 이 io 위에서 돈다.
pub fn runSessionHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: [:0]const u8,
    socket_path: [:0]const u8,
) RunError!void {
    // 제품 launcher argv를 실제 `maru` 바이너리까지 관통하는 process smoke가 detached orphan을 남기지 않도록,
    // 테스트가 명시한 경우 첫 client 연결을 처리한 뒤 정상 종료한다. 일반 제품 환경에는 이 변수가 없어 기존의 영속
    // accept loop를 그대로 돈다. 환경은 시작 시 한 번만 읽어 parent가 spawn 직후 unset해도 child의 동작이 안정적이다.
    const test_oneshot = if (std.c.getenv("MARU_SESSION_HOST_TEST_ONESHOT")) |value|
        std.mem.eql(u8, std.mem.span(value), "maru-test-only-v1") and
            std.mem.startsWith(u8, socket_path, "/tmp/maru-sh-product-")
    else
        false;
    var test_idle_ticks: usize = 0;

    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();

    // 실 runtime 소유자(app InProcessTermBackend 재사용). registry를 함께 참조해 spawn이 재접속 조회 대상으로 등록한다.
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(allocator, io, &registry);
    defer manager.deinit();

    var server = try socket_server.SocketServer.bind(allocator, dir_path, socket_path, newHostId(), &registry);
    defer server.deinit();
    server.runtime_ops = manager.runtimeOps(); // 이제 이 host는 read-only가 아니라 runtime.spawn/terminate를 처리한다.
    var admission_gate = upgrade.AdmissionGate.init(io);
    server.admission_gate = &admission_gate;
    server.owner_tick_ctx = &manager;
    server.owner_tick = struct {
        fn tick(ctx: *anyopaque) void {
            const owner: *runtime_manager.RuntimeManager = @ptrCast(@alignCast(ctx));
            _ = owner.drainOwnedEvents();
        }
    }.tick;

    while (true) {
        server.tickOwner();
        switch (server.pollReady(poll_timeout_ms)) {
            .ready => {
                server.serveOnce() catch {}; // 개별 연결 오류(write 실패 등)는 host를 죽이지 않는다.
                if (test_oneshot) break;
            },
            .timeout => {
                // test runner가 client 연결 전에 중단돼도 detached orphan을 남기지 않는다(25×200ms=5s).
                if (test_oneshot) {
                    test_idle_ticks += 1;
                    if (test_idle_ticks >= 25) break;
                }
            },
            .broken => break, // listen fd 회복 불가 — 루프 종료.
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host가 부모와 독립돼 살아 client에 응답)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 영속 세션의 핵심은 "GUI 프로세스가 죽어도 host가 살아
// 재접속에 응답한다"는 것이다. 실제로 fork한 자식을 `setsid`로 독립 세션에 두고 session host를 돌린 뒤, 부모가 client로
// connect해 hello→host.info를 왕복하고, 마지막에 SIGTERM으로 host를 내린다. 부모가 자식 fd를 잡지 않고 자식이 독립
// 세션이라, 부모 수명과 무관하게 host가 socket을 소유한다. 실 fork/socket이라 macOS opt-in이다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");

fn waitConnect(socket_path: [:0]const u8, deadline_ms: u64) ?c.fd_t {
    // host가 bind할 때까지 짧게 재시도하며 connect한다(fork 직후 socket이 아직 없을 수 있다).
    var waited: u64 = 0;
    while (waited < deadline_ms) : (waited += 20) {
        const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return null;
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) == 0) return fd;
        _ = c.close(fd);
        _ = usleep(20 * 1000); // 20ms
    }
    return null;
}

test "daemon: forked host survives parent-independent (setsid) and answers hello/host.info" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir_buf: [256]u8 = undefined;
    const pid0 = c.getpid();
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-daemon-{d}", .{pid0}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        // 자식 = host. setsid로 부모와 독립된 세션 리더가 된다(부모가 죽어도 SIGHUP·세션 종료에 안 묶임).
        _ = c.setsid();
        // 자식은 곧 _exit하므로 leak 검증이 필요 없다 — page_allocator로 충분. io는 blocking testing.io면 족하다
        // (이 host 테스트는 runtime을 spawn하지 않고 hello/host.info만 응답하므로 io는 backend 생성에만 쓰인다).
        runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        std.c._exit(0); // atexit/deinit 재실행 없이 즉시 종료(fork 자식 규약).
    }

    // 부모 = client. host가 bind할 때까지 재시도 connect. 끝에 host를 내리고 자식을 reap한다.
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    const fd = waitConnect(socket_path, 3000) orelse {
        try testing.expect(false); // host가 3초 안에 socket을 안 열었다.
        return;
    };
    defer _ = c.close(fd);

    // hello → hello_ack.
    const hello = try framing.encodeFrame(allocator, .{ .kind = .hello, .request_id = 1 }, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    defer allocator.free(hello);
    try socket_server.writeAll(fd, hello);

    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try testing.expect(readKind(fd, &parser, allocator, .hello_ack));

    // host.info → 살아 있는 host가 응답(runtime_count 포함).
    const req = try framing.encodeFrame(allocator, .{ .kind = .request, .request_id = 2 }, "{\"method\":\"host.info\"}");
    defer allocator.free(req);
    try socket_server.writeAll(fd, req);
    try testing.expect(readKindContains(fd, &parser, allocator, .response, "runtime_count"));
}

fn readKind(fd: c.fd_t, parser: *framing.FrameParser, a: std.mem.Allocator, want: protocol.Kind) bool {
    var buf: [1024]u8 = undefined;
    while (true) {
        if (parser.next() catch return false) |f| {
            defer f.deinit(a);
            return f.header.kind == want;
        }
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) return false;
        parser.push(buf[0..@intCast(n)]) catch return false;
    }
}

fn readKindContains(fd: c.fd_t, parser: *framing.FrameParser, a: std.mem.Allocator, want: protocol.Kind, needle: []const u8) bool {
    var buf: [1024]u8 = undefined;
    while (true) {
        if (parser.next() catch return false) |f| {
            defer f.deinit(a);
            return f.header.kind == want and std.mem.indexOf(u8, f.payload, needle) != null;
        }
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) return false;
        parser.push(buf[0..@intCast(n)]) catch return false;
    }
}
