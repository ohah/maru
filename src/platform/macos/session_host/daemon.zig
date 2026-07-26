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
const discovery = @import("discovery.zig");
const owner_lease = @import("owner_lease.zig");
const host_manifest = @import("host_manifest.zig");
const screen_stream = @import("screen_stream.zig");
const short_endpoint = @import("short_endpoint.zig");
const protocol = @import("protocol.zig");
const host_authority = @import("host_authority.zig");
const staged_image = @import("staged_image.zig");
const rollback_image = @import("rollback_image.zig");
const upgrade_target = @import("upgrade_target.zig");
const code_signature = @import("code_signature.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const upgrade_executor = @import("upgrade_executor.zig");
const upgrade_loop = @import("upgrade_loop.zig");
const poll_owner = @import("poll_owner.zig");

pub const RunError = socket_server.BindError || error{ OutOfMemory, OwnerLeaseFailed, ManifestFailed };

// macOS/BSD libc의 CSPRNG와 sleep(std.posix 미노출이라 직접 extern — daemon은 macOS 전용).
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;

/// accept loop 한 tick의 poll timeout(ms). 이 주기로 깨어나 listen fd 상태를 확인한다(향후 idle-grace 종료 판정 자리).
pub const poll_timeout_ms: i32 = 200;

/// 128-bit host_id를 발급한다(§4 opaque random). macOS `arc4random_buf`는 실패하지 않는 CSPRNG라 별도 fallback이 없다.
fn newHostId() u128 {
    var id: u128 = 0;
    while (id == 0) {
        var bytes: [16]u8 = undefined;
        arc4random_buf(&bytes, bytes.len);
        id = std.mem.readInt(u128, &bytes, .big);
    }
    return id;
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
    return runSessionHostImpl(allocator, io, dir_path, socket_path, null, false);
}

/// Product host별 discovery 경로. Launcher가 먼저 발급한 host_id가 short endpoint, owner lease, manifest, hello에서
/// 하나의 identity로 유지된다.
pub fn runSessionHostWithIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
) RunError!void {
    if (host_id == 0) return error.ManifestFailed;
    short_endpoint.validateCurrentSocketPath(socket_path, host_id) catch return error.ManifestFailed;
    short_endpoint.prepareCurrentUserNamespace() catch return error.ManifestFailed;
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, false);
}

/// Process fixture entrypoint. It changes only the release-signer decision; staging, typed
/// readiness marker, coordinator, real exec, restore activation, and poll owners remain product
/// code. A non-test artifact cannot reference this declaration.
pub fn runSessionHostWithIdentityTestAuthorizer(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
) RunError!void {
    if (!builtin.is_test) @compileError("test upgrade authorizer is test-only");
    if (host_id == 0) return error.ManifestFailed;
    short_endpoint.validateCurrentSocketPath(socket_path, host_id) catch return error.ManifestFailed;
    short_endpoint.prepareCurrentUserNamespace() catch return error.ManifestFailed;
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, true);
}

fn runSessionHostImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: [:0]const u8,
    socket_path: [:0]const u8,
    exact_host_id: ?u128,
    test_allow_any_upgrade_target: bool,
) RunError!void {
    // 제품 launcher argv를 실제 `maru` 바이너리까지 관통하는 process smoke가 detached orphan을 남기지 않도록,
    // 테스트가 명시한 경우 첫 client 연결을 처리한 뒤 정상 종료한다. 일반 제품 환경에는 이 변수가 없어 기존의 영속
    // accept loop를 그대로 돈다. 환경은 시작 시 한 번만 읽어 parent가 spawn 직후 unset해도 child의 동작이 안정적이다.
    const test_oneshot = if (std.c.getenv("MARU_SESSION_HOST_TEST_ONESHOT")) |value|
        std.mem.eql(u8, std.mem.span(value), "maru-test-only-v1") and
            exact_host_id != null
    else
        false;
    var test_idle_ticks: usize = 0;

    // SocketServer.bind는 stale socket을 unlink하므로 lifetime owner lease보다 먼저 실행하면 안 된다. 경쟁 host가
    // 기존 live host의 endpoint를 끊지 못하도록 owner-only directory를 먼저 검증하고 lease를 선취한다.
    const mkdir_rc = c.mkdir(dir_path.ptr, 0o700);
    if (mkdir_rc != 0 and posix.errno(mkdir_rc) != .EXIST) return error.OwnerLeaseFailed;
    if (c.chmod(dir_path.ptr, 0o700) != 0) return error.OwnerLeaseFailed;
    var dir_stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, dir_path.ptr, &dir_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(dir_stat.mode) or dir_stat.uid != c.getuid()) return error.OwnerLeaseFailed;
    if (exact_host_id) |host_id| host_manifest.prepareHostDirectory(dir_path, host_id) catch
        return error.OwnerLeaseFailed;
    var owner_path_buf: [832]u8 = undefined;
    const owner_path = if (exact_host_id) |host_id|
        host_manifest.ownerLockPathIn(&owner_path_buf, dir_path, host_id) catch return error.OwnerLeaseFailed
    else
        discovery.ownerLockPathIn(&owner_path_buf, dir_path) catch return error.OwnerLeaseFailed;
    var lifetime_owner = owner_lease.OwnerLease.acquire(owner_path) catch return error.OwnerLeaseFailed;
    defer {
        if (exact_host_id != null) _ = lifetime_owner.unlinkOwnedWhileLocked(owner_path) catch {};
        lifetime_owner.deinit();
        if (exact_host_id) |host_id| host_manifest.removeEmptyHostDirectories(dir_path, host_id);
    }

    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();

    // 실 runtime 소유자(app InProcessTermBackend 재사용). registry를 함께 참조해 spawn이 재접속 조회 대상으로 등록한다.
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(allocator, io, &registry);
    defer manager.deinit();

    const host_id = exact_host_id orelse newHostId();
    var socket_dir_buf: [112]u8 = undefined;
    const bind_dir = if (exact_host_id != null)
        short_endpoint.socketDirPathIn(&socket_dir_buf, c.getuid()) catch return error.ManifestFailed
    else
        dir_path;
    var server = try socket_server.SocketServer.bind(allocator, bind_dir, socket_path, host_id, &registry);
    defer server.deinit();
    const executable_path_raw = std.process.executablePathAlloc(io, allocator) catch return error.ManifestFailed;
    defer allocator.free(executable_path_raw);
    const executable_path = allocator.dupeZ(u8, executable_path_raw) catch return error.OutOfMemory;
    defer allocator.free(executable_path);
    const build_id = host_manifest.buildIdForExecutable(allocator, executable_path) catch return error.ManifestFailed;
    defer allocator.free(build_id);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = if (exact_host_id) |exact|
        host_manifest.hostDirPathIn(&host_dir_buf, dir_path, exact) catch
            return error.ManifestFailed
    else
        dir_path;
    var rollback_authority: ?rollback_image.Authority = null;
    defer if (rollback_authority) |*rollback| rollback.deinit();
    var signature_authorizer = code_signature.Authorizer{
        .io = io,
        .current_executable = executable_path,
    };
    const test_authorizer: upgrade_target.Authorizer = .{
        .ctx = @ptrFromInt(1),
        .allowed = struct {
            fn allowed(_: *anyopaque, _: [:0]const u8) bool {
                return true;
            }
        }.allowed,
    };
    var target_stager = upgrade_target.Stager{
        .owner_dir = host_dir,
        .authorizer = if (test_allow_any_upgrade_target)
            test_authorizer
        else
            signature_authorizer.ops(),
    };
    var upgrade_attempt_owner: ?upgrade_owner.UpgradeOwner = null;
    defer if (upgrade_attempt_owner) |*owner| owner.deinit();
    var product_executor: upgrade_executor.ProductExecutor = .{
        .allocator = allocator,
    };
    if (exact_host_id != null) {
        if (staged_image.inspect(executable_path)) |running_identity| {
            if (rollback_image.Authority.prepare(
                allocator,
                executable_path,
                running_identity,
                host_dir,
            )) |prepared_rollback| {
                rollback_authority = prepared_rollback;
                // The app/updater pathname can be replaced while this daemon
                // lives. The canonical self-image is owner-only and promotion
                // rotates its contents while keeping this path stable.
                signature_authorizer.current_executable =
                    rollback_authority.?.image.path;
                upgrade_attempt_owner = upgrade_owner.UpgradeOwner.init(
                    allocator,
                    target_stager.ops(),
                    .{
                        .ctx = &registry,
                        .is_busy = struct {
                            fn busy(ctx: *anyopaque) bool {
                                const runtime_registry: *reg.TerminalRuntimeRegistry =
                                    @ptrCast(@alignCast(ctx));
                                return runtime_registry.attachmentCount() != 0;
                            }
                        }.busy,
                    },
                );
            } else |_| {
                // Keep-alive is the primary service. If live-upgrade staging
                // cannot be prepared, serve normally without advertising it.
            }
        } else |_| {
            // buildIdForExecutable already validated launch identity, but an
            // exact reinspection race only disables upgrade capability.
        }
    }
    var published_manifest: ?host_manifest.Published = null;
    if (exact_host_id != null) {
        published_manifest = host_manifest.publish(allocator, dir_path, .{
            .host_id = host_id,
            .build_id = build_id,
            .protocol_major = protocol.version_major,
            .screen_codec_version = screen_stream.codec_version,
            .upgrade_epoch = 0,
            .lifecycle = .ready,
            .endpoint = socket_path,
        }) catch return error.ManifestFailed;
    }
    defer if (published_manifest) |*published| published.deinit();
    var authority: ?host_authority.HostAuthority = if (published_manifest) |*published|
        host_authority.HostAuthority.init(allocator, published, &server, .{
            .host_id = host_id,
            .build_id = build_id,
            .protocol_major = protocol.version_major,
            .screen_codec_version = screen_stream.codec_version,
            .upgrade_epoch = 0,
            .lifecycle = .ready,
            .endpoint = socket_path,
        }) catch return error.ManifestFailed
    else
        null;
    defer if (authority) |*owner| owner.deinit();
    if (authority) |*owner| {
        if (upgrade_attempt_owner) |*upgrade_owner_value|
            owner.installUpgradeController(upgrade_owner_value.ops());
    }
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

    var fd_owner = poll_owner.Owner.init(allocator, io, &server) catch return error.OutOfMemory;
    defer fd_owner.deinit();
    while (true) {
        server.tickOwner();
        switch (fd_owner.pollOnce(poll_timeout_ms) catch return error.OutOfMemory) {
            .upgrade_ready => {
                const marker = fd_owner.takeArmedUpgrade() orelse return error.ManifestFailed;
                if (upgrade_attempt_owner == null or rollback_authority == null or
                    upgrade_loop.processPreclosed(marker, .{
                        .allocator = allocator,
                        .io = io,
                        .owner = &upgrade_attempt_owner.?,
                        .manager = &manager,
                        .gate = &admission_gate,
                        .lifetime_owner = &lifetime_owner,
                        .rollback_authority = &rollback_authority.?,
                        .authority = authority.?.upgradeAuthority(),
                        .executor = product_executor.ops(),
                        .owner_dir = host_dir,
                        .session_dir = dir_path,
                        .socket_path = socket_path,
                    }) == .fail_stop)
                    return error.ManifestFailed;
            },
            .idle => if (test_oneshot) {
                test_idle_ticks += 1;
                if (test_idle_ticks >= 25) break;
            },
            .progress => {},
            .listener_broken => break,
        }
        if (test_oneshot and fd_owner.total_admitted != 0 and fd_owner.activeCount() == 0) break;
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

test "daemon: competing host is rejected before it can unlink the live owner socket" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-owner-race-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&socket_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        var owner_buf: [320]u8 = undefined;
        if (discovery.ownerLockPathIn(&owner_buf, dir_path)) |path| _ = c.unlink(path.ptr) else |_| {}
        _ = c.rmdir(dir_path.ptr);
    }
    const first = waitConnect(socket_path, 3000) orelse return error.TestUnexpectedResult;
    _ = c.close(first);
    try testing.expectError(
        error.OwnerLeaseFailed,
        runSessionHost(std.heap.page_allocator, testing.io, dir_path, socket_path),
    );
    const second = waitConnect(socket_path, 500) orelse return error.TestUnexpectedResult;
    _ = c.close(second);
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
