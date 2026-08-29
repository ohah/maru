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
const startup_readiness = @import("startup_readiness.zig");
const posix = std.posix;
const socket_server = @import("socket_server.zig");
const reg = @import("registry.zig");
const runtime_manager = @import("runtime_manager.zig");
const notification_os_delivery = @import("notification_os_delivery.zig");
const upgrade = @import("upgrade_coordinator.zig");
const discovery = @import("discovery.zig");
const owner_lease = @import("owner_lease.zig");
const host_manifest = @import("host_manifest.zig");
const agent_hook_logs = @import("agent_hook_logs.zig");
const screen_stream = @import("maru").session.screen_stream;
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
const incident_runtime = @import("incident_runtime.zig");
const incident_publisher_registry = @import("incident_publisher_registry.zig");
const process_seal_service = @import("process_seal_service.zig");
const incident_bootstrap_contract = @import("incident_bootstrap_contract.zig");

pub const RunError = socket_server.BindError || error{
    OutOfMemory,
    OwnerLeaseFailed,
    ManifestFailed,
    ProcessIdentityUnavailable,
};

/// ReleaseFast process fixture 전용 private observation seam. 제품 protocol/capability를
/// 넓히지 않고 actual owner turn 뒤 canonical ledger/stall과 PTY reader bytes를 전달한다.
/// callback action이 reset 또는 stop을 요청할 수 있으며 stop은 loop를 정상 종료한다.
pub const FixtureAction = enum { continue_serving, reset_stall, disconnect_clients, stop };

pub const FixtureProbe = struct {
    ctx: *anyopaque,
    after_turn: *const fn (
        ctx: *anyopaque,
        telemetry: poll_owner.TelemetrySnapshot,
        pty_output_bytes: u64,
        output_wake: runtime_manager.RuntimeManager.OutputWakeEvidence,
        child_exit: runtime_manager.RuntimeManager.ChildExitEvidence,
        observation: runtime_manager.RuntimeManager.ObservationPerformanceEvidence,
        metadata_sampler: runtime_manager.RuntimeManager.MetadataSamplerEvidence,
        screen: runtime_manager.RuntimeManager.ScreenPerformanceEvidence,
    ) FixtureAction,
};

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

fn bootstrapIncidentRuntime(
    allocator: std.mem.Allocator,
    dir_path: [:0]const u8,
) !*incident_runtime.ConnectionIncidentRuntime {
    const owner_fd = c.open(dir_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (owner_fd < 0) return error.ManifestFailed;
    defer _ = c.close(owner_fd);
    const mkdir_result = c.mkdirat(owner_fd, "incidents", 0o700);
    if (mkdir_result != 0 and posix.errno(mkdir_result) != .EXIST) return error.ManifestFailed;
    const incident_fd = c.openat(
        owner_fd,
        "incidents",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (incident_fd < 0) return error.ManifestFailed;
    var incident_stat: posix.Stat = undefined;
    if (c.fstat(incident_fd, &incident_stat) != 0 or !posix.S.ISDIR(incident_stat.mode) or
        incident_stat.uid != c.getuid() or c.fchmod(incident_fd, 0o700) != 0)
        return error.ManifestFailed;
    defer _ = c.close(incident_fd);
    var app_instance_nonce = newHostId();
    // 두 nonce는 host_id와 별도 발급한다. artifact identity가 endpoint 교체나 host manifest
    // generation에 종속되면 같은 프로세스의 장애 sequence가 외부 routing identity 변화로 갈라질 수 있다.
    if (app_instance_nonce == 0) app_instance_nonce = newHostId();
    var process_nonce: u64 = 0;
    while (process_nonce == 0) process_nonce = @truncate(newHostId());
    if (builtin.is_test)
        process_seal_service.testing_api.resetInheritedForkedDaemonProcessSealIfPresent() catch
            return error.ManifestFailed;
    const prepared_seal = process_seal_service.prepare(@intCast(c.getpid()), process_nonce) catch
        return error.ManifestFailed;
    process_seal_service.commitReady(prepared_seal);
    return incident_runtime.ConnectionIncidentRuntime.create(
        allocator,
        @intCast(c.getpid()),
        process_nonce,
        app_instance_nonce,
        incident_fd,
    ) catch return error.ManifestFailed;
}

fn removeEmptyIncidentDirectory(dir_path: [:0]const u8) void {
    const owner_fd = c.open(dir_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (owner_fd < 0) return;
    defer _ = c.close(owner_fd);
    // 기록이 하나라도 있으면 ENOTEMPTY로 그대로 보존한다. 비어 있는 bootstrap 흔적만 지워 기존 owner-directory
    // teardown 계약을 유지하며, 파일을 순회하거나 이름을 신뢰하지 않는다.
    _ = c.unlinkat(owner_fd, "incidents", posix.AT.REMOVEDIR);
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
    return runSessionHostImpl(allocator, io, dir_path, socket_path, null, false, null, null, null);
}

/// 별도 ReleaseFast fixture executable만 사용하는 entrypoint. ambient env나 public MRSH
/// method가 아니라 caller가 명시적으로 넘긴 private channel adapter만 관측한다.
pub fn runSessionHostForFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: [:0]const u8,
    socket_path: [:0]const u8,
    probe: FixtureProbe,
) RunError!void {
    return runSessionHostImpl(allocator, io, dir_path, socket_path, null, false, probe, null, null);
}

/// Exact-identity counterpart used only by a separately linked process fixture. This preserves
/// the product discovery/manifest/socket identity while the private callback supplies fault
/// injection without adding a product protocol command or ambient daemon environment switch.
pub fn runSessionHostWithIdentityForFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
    probe: FixtureProbe,
) RunError!void {
    if (host_id == 0) return error.ManifestFailed;
    short_endpoint.validateCurrentSocketPath(socket_path, host_id) catch return error.ManifestFailed;
    short_endpoint.prepareCurrentUserNamespace() catch return error.ManifestFailed;
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, false, probe, null, null);
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
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, false, null, null, null);
}

/// Fresh detached launch 전용 entrypoint. notifier는 startup 결과만 소유하며 accept loop 수명이나
/// same-PID upgrade/restore handoff에는 참여하지 않는다.
pub fn runSessionHostWithIdentityStartup(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
    notifier: *startup_readiness.Notifier,
) RunError!void {
    if (host_id == 0) return error.ManifestFailed;
    short_endpoint.validateCurrentSocketPath(socket_path, host_id) catch return error.ManifestFailed;
    short_endpoint.prepareCurrentUserNamespace() catch return error.ManifestFailed;
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, false, null, notifier, null);
}

/// Product fresh-launch path with the process-local macOS notification adapter. Keeping the adapter
/// explicit prevents fixtures and non-product callers from accidentally claiming OS delivery.
pub fn runSessionHostWithIdentityStartupAndNotificationAdapter(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
    notifier: *startup_readiness.Notifier,
    adapter: notification_os_delivery.Adapter,
) RunError!void {
    if (host_id == 0) return error.ManifestFailed;
    short_endpoint.validateCurrentSocketPath(socket_path, host_id) catch return error.ManifestFailed;
    short_endpoint.prepareCurrentUserNamespace() catch return error.ManifestFailed;
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, false, null, notifier, adapter);
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
    return runSessionHostImpl(allocator, io, session_dir, socket_path, host_id, true, null, null, null);
}

/// exec layout(연속 `exec_fd_set.max_slots`개 슬롯) + 최대 runtime의 PTY master/wake pipe + listener·lease 여유.
/// 무한대를 요청하지 않는 이유는 아래 `raiseFileDescriptorLimit` 주석 참고.
const desired_fd_limit = 8192;

/// `/tmp` 정리 회피 주기(**벽시계 1시간**).
///
/// macOS `com.apple.tmp_cleaner`가 **매일 0시**에 돌며 `atime`·`mtime`·`ctime`이 **모두** 3일을 넘긴 항목을
/// 지운다(`daily_clean_tmps_days="3"`). 우리 endpoint와 manifest는 bind/publish 시각 이후 아무도 건드리지
/// 않으므로 — 실측에서 소켓 파일의 시각이 bind 시점 그대로였다 — 3일 이상 조용한 host는 자기 endpoint를
/// 잃는다. 프로세스는 멀쩡히 살아 있는데 아무도 찾지 못하는 상태가 되고, 사용자에게는 "세션이 그냥 사라진"
/// 것으로 보인다.
///
/// 그래서 살아 있는 동안 주기적으로 시각을 갱신해 그 조건을 깬다. 3일 한계에 1시간은 충분히 짧고 비용은
/// `utimensat` 몇 번이라 사실상 없다.
///
/// **tick 수가 아니라 벽시계로 잰다.** `pollOnce`는 `poll_timeout_ms`를 보장하지 않는다 — armed upgrade나
/// 도착한 이벤트가 있으면 즉시 반환하므로, 입력이 활발한 host에서는 tick이 훨씬 빨리 돈다. tick으로 세면
/// 그런 host가 초당 여러 번 touch하게 되어 의미 없는 syscall을 반복한다.
const runtime_touch_interval_ms: u64 = 60 * 60 * 1000;

/// 자연 종료 유예 — `poll_timeout_ms`(200ms) × 이 횟수만큼 **연속으로** 비어 있어야 종료한다(= 5초).
/// 마지막 runtime이 사라진 직후 곧바로 죽으면, 그 순간 재접속하려던 GUI가 endpoint를 잃고 새 host를 띄우게 된다.
const natural_exit_idle_ticks: usize = 25;

/// 지금 host가 스스로 물러나도 되는가. 순수 판정이라 실 daemon 없이 경계를 테스트로 고정한다.
///
/// 세 조건을 **모두** 요구한다.
///   - `served_any_runtime`: runtime을 한 번이라도 서빙했어야 한다. 없으면 방금 뜬 host가 GUI의 첫 spawn을
///     받기도 전에 자신을 종료해, 그 host를 띄운 GUI가 endpoint를 잃는다.
///   - `runtime_count == 0`: detach된 keep-alive 세션이 하나라도 있으면 살아남아야 한다 — 그게 이 host의
///     존재 이유다(문서: "runtime이 하나라도 살아 있으면 구 host를 종료하지 않는다").
///   - `client_count == 0`: 붙어 있는 GUI가 곧 spawn할 수 있으므로 끊지 않는다.
fn shouldExitNaturally(
    served_any_runtime: bool,
    runtime_count: usize,
    client_count: usize,
    empty_idle_ticks: usize,
) bool {
    if (!served_any_runtime or runtime_count != 0 or client_count != 0) return false;
    return empty_idle_ticks >= natural_exit_idle_ticks;
}

/// 지금 `/tmp` 정리 회피 touch를 할 차례인가. **벽시계 기준**이라 tick이 얼마나 빨리 도는지와 무관하다.
/// 순수 함수라 주기 정책을 daemon 루프 없이 검증한다.
///
/// "아직 한 번도 안 찍음"을 `0`이 아니라 `null`로 표현하는 이유: 단조 시계는 부팅 후 경과라 host가 부팅
/// 직후에 뜨면 `now_ms` 자체가 작다. `0`을 sentinel로 쓰면 그 host의 첫 touch가 1시간 뒤로 밀려, 그동안
/// 물려받은 옛 시각이 그대로 남는다.
fn shouldTouchRuntimeArtifacts(now_ms: u64, last_touch_ms: ?u64) bool {
    const last = last_touch_ms orelse return true;
    return now_ms -| last >= runtime_touch_interval_ms;
}

/// 단조 시계의 현재 ms. touch 주기를 벽시계로 재기 위한 것이라 절대 시각일 필요는 없다.
fn awakeMs(io: std.Io) u64 {
    const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (now_ns <= 0) 0 else @intCast(@divFloor(now_ns, std.time.ns_per_ms));
}

/// endpoint·manifest·그 부모 디렉터리의 시각을 현재로 갱신해 `tmp_cleaner`의 3일 조건을 깬다.
///
/// **best-effort다.** 실패해도 host는 계속 돈다 — 갱신하지 못하면 최악의 경우 3일 뒤 endpoint를 잃지만, 그
/// 때문에 지금 살아 있는 세션을 끊는 것이 더 나쁘다. 디렉터리까지 찍는 이유는 정리 규칙이 빈 디렉터리도
/// (`-empty -mtime +3`) 대상으로 삼기 때문이다.
fn touchRuntimeArtifacts(
    dir_path: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
    published_manifest: ?*host_manifest.Published,
) void {
    // null times = 현재 시각으로 설정(POSIX). AT_SYMLINK_NOFOLLOW를 주지 않아 경로를 그대로 따른다.
    _ = c.utimensat(c.AT.FDCWD, socket_path.ptr, null, 0);
    _ = c.utimensat(c.AT.FDCWD, dir_path.ptr, null, 0);
    if (published_manifest) |published| {
        _ = published.touchExact() catch {};
    } else {
        var manifest_buf: [512]u8 = undefined;
        if (host_manifest.manifestPathIn(&manifest_buf, dir_path, host_id)) |path| {
            _ = c.utimensat(c.AT.FDCWD, path.ptr, null, 0);
        } else |_| {}
    }
    // 소켓과 manifest의 부모(`/tmp/maru-<uid>`, `.../sh`)도 함께 찍는다. 자식이 남아 있으면 `-empty` 조건에
    // 걸리지 않지만, 자식이 먼저 지워진 뒤 빈 디렉터리로 남는 창을 없앤다.
    // 우리가 **실제로 쓰는** 뿌리를 찍는다. uid 로 다시 계산하면 격리된 실행에서 남의 자리를 건드리면서
    // 정작 자기 endpoint 는 안 찍어, 살아 있는 host 가 tmp 정리에 지워지는 원래 실패로 되돌아간다.
    var root_buf: [256]u8 = undefined;
    if (short_endpoint.currentUserRootPathIn(&root_buf)) |root| {
        _ = c.utimensat(c.AT.FDCWD, root.ptr, null, 0);
    } else |_| {}
    var sock_dir_buf: [272]u8 = undefined;
    if (short_endpoint.currentSocketDirPathIn(&sock_dir_buf)) |sock_dir| {
        _ = c.utimensat(c.AT.FDCWD, sock_dir.ptr, null, 0);
    } else |_| {}
}

test "tmp 정리 회피: 처음엔 즉시, 그 뒤엔 벽시계 주기로만 touch한다" {
    // macOS tmp_cleaner는 atime·mtime·ctime이 **모두** 3일을 넘긴 항목을 지운다. 주기가 3일을 넘기면 살아 있는
    // host가 자기 endpoint를 잃고 프로세스는 남은 채 아무도 찾지 못하는 상태가 된다.
    try std.testing.expect(shouldTouchRuntimeArtifacts(1_000, null)); // 아직 안 찍음 — 물려받은 옛 시각을 즉시 덮는다
    const base: u64 = 1_000_000;
    try std.testing.expect(!shouldTouchRuntimeArtifacts(base, base));
    try std.testing.expect(!shouldTouchRuntimeArtifacts(base + runtime_touch_interval_ms - 1, base));
    try std.testing.expect(shouldTouchRuntimeArtifacts(base + runtime_touch_interval_ms, base));
    // 단조 시계가 뒤로 가는 일은 없어야 하지만, 그렇더라도 saturating 뺄셈이라 폭주하지 않는다.
    try std.testing.expect(!shouldTouchRuntimeArtifacts(base, base + 5_000));
}

test "tmp 정리 회피: touch가 실제로 파일 시각을 되돌린다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 판정 함수만 테스트하면 `utimensat` 호출이 런타임에 무효여도(잘못된 인자·경로) 통과한다. 그러면 host는
    // 매시간 아무 일도 하지 않고 3일 뒤 endpoint를 잃는다 — 정확히 막으려던 그 상태다.
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-touch-test-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    var sock_buf: [192]u8 = undefined;
    const fake_socket = try std.fmt.bufPrintZ(&sock_buf, "{s}/endpoint.sock", .{dir});
    defer {
        _ = c.unlink(fake_socket.ptr);
        _ = c.rmdir(dir.ptr);
    }
    const fd = c.open(fake_socket.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.SkipZigTest;
    _ = c.close(fd);

    // 아주 오래된 시각으로 밀어 3일 조건을 넘긴 상태를 만든다(절대 시각은 무관 — 과거이기만 하면 된다).
    const ancient: c.timespec = .{ .sec = 1_000_000_000, .nsec = 0 }; // 2001년
    const past: [2]c.timespec = .{ ancient, ancient };
    if (c.utimensat(c.AT.FDCWD, fake_socket.ptr, &past, 0) != 0) return error.SkipZigTest;

    const cwd = std.Io.Dir.cwd();
    const before = cwd.statFile(testing.io, fake_socket, .{}) catch return error.SkipZigTest;
    touchRuntimeArtifacts(dir, fake_socket, 0xabcd, null);
    const after = cwd.statFile(testing.io, fake_socket, .{}) catch return error.SkipZigTest;

    // 갱신되지 않으면 3일 조건을 못 깨고, host는 살아 있는데도 endpoint를 잃는다.
    try testing.expect(after.mtime.nanoseconds > before.mtime.nanoseconds);
}

test "tmp 정리 회피 주기는 tmp_cleaner의 3일 한계보다 충분히 짧다" {
    // 이 부등식이 깨지면 host가 살아 있는데도 endpoint가 사라진다. 상수를 키우는 변경이 조용히 넘어가지 못하게 한다.
    //
    // **벽시계로 재는 것이 계약의 일부다.** 예전엔 tick 수로 셌는데 `pollOnce`가 `poll_timeout_ms`를 보장하지
    // 않아(armed upgrade·도착한 이벤트가 있으면 즉시 반환) 바쁜 host에서는 실제 경과가 훨씬 짧았다.
    const three_days_ms: u64 = 3 * 24 * 60 * 60 * 1000;
    try std.testing.expect(runtime_touch_interval_ms * 24 <= three_days_ms); // 한계의 1/24 이하 — 정리 주기(하루)보다 짧다
}

/// 시작 시 열 수 있는 fd 상한(soft)을 올린다. **exec 업그레이드가 여기에 걸려 한 번도 성공하지 못했다.**
///
/// `upgrade_product_coordinator.findAvailableLayout(40)`은 fd 40부터 `exec_fd_set.max_slots`
/// (= `max_runtime_count` 256 + 3 = **259**)개의 **연속 빈 슬롯**을 찾는다. 그런데 launchd가 GUI 앱에 주는
/// 기본 soft limit은 **256**이고 host는 그것을 그대로 상속하므로, Dock·Finder로 켠 앱이 띄운 host에서는
/// `40 + 259 > 256`이라 탐색 루프가 **한 번도 돌지 않고** `null`이 된다. 그러면
/// `upgrade_loop.finishPreclosedWithoutLayout`이 곧바로 `status=resumed reason=handoff_failed`로 끝낸다.
///
/// 실측이 이를 뒷받침한다: 모든 host manifest의 `upgrade_epoch`가 0이었고(한 번도 교체된 적 없음), 빌드를
/// 바꿀 때마다 옛 host가 고아로 쌓였다. 터미널에서 띄운 앱(셸 `ulimit -n`을 상속)만 이 조건을 통과했다.
///
/// hard limit은 보통 무한대지만 macOS는 무한대를 받지 않고 `kern.maxfilesperproc`을 넘으면 EINVAL이므로,
/// 필요한 만큼만 요청한다. **best-effort**다 — 실패해도 host의 본 기능(keep-alive)은 그대로이므로 오류로
/// 올리지 않는다. 못 올리면 업그레이드만 기존처럼 실패하고 새 host가 뜬다.
/// host의 진단 출력을 `<session_dir>/host-<id>.log`로 돌린다.
///
/// launcher가 detached spawn하면서 std fd를 전부 `/dev/null`로 보내므로(`redirectStdioToDevNull`) **host 안에서
/// 무슨 일이 있었는지 볼 방법이 전혀 없다.** GUI 쪽은 터미널에서 앱을 직접 띄우면 stderr가 보이지만 host는 그
/// 방법조차 없다 — 실제로 "host는 살아 있는데 그 연결만 끊겼다"(`error=ConnectionClosed`)를 만났을 때 host가 왜
/// 닫았는지 확인할 수단이 없어 추적이 막혔다.
///
/// stdout/stdin은 그대로 `/dev/null`에 둔다(PTY 출력이 섞이면 안 된다). append 모드라 exec 업그레이드로 같은
/// host가 이미지를 갈아타도 기록이 이어진다. **best-effort**다: 못 열면 조용히 기존 fd를 유지한다.
fn redirectStderrToHostLog(session_dir: [:0]const u8, host_id: ?u128) void {
    const id = host_id orelse return;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/host-{x:0>32}.log",
        .{ std.mem.sliceTo(session_dir, 0), id },
    ) catch return;
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return;
    defer if (fd > 2) {
        _ = c.close(fd);
    };
    _ = c.dup2(fd, 2);
}

fn raiseFileDescriptorLimit() void {
    var limit = posix.getrlimit(.NOFILE) catch return;
    const target = @min(limit.max, desired_fd_limit);
    if (limit.cur >= target) return;
    limit.cur = target;
    posix.setrlimit(.NOFILE, limit) catch {};
}

fn runSessionHostImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: [:0]const u8,
    socket_path: [:0]const u8,
    exact_host_id: ?u128,
    test_allow_any_upgrade_target: bool,
    fixture_probe: ?FixtureProbe,
    startup_notifier: ?*startup_readiness.Notifier,
    notification_adapter: ?notification_os_delivery.Adapter,
) RunError!void {
    // exec 업그레이드 layout을 확보할 수 있도록 가장 먼저 올린다. 이후 열리는 socket/PTY/lease fd가 상한에
    // 걸리지 않게 하려면 어떤 fd를 열기 전이어야 한다.
    raiseFileDescriptorLimit();
    // 그다음 진단 출력을 파일로 돌린다 — 이후 단계의 실패도 기록에 남아야 한다.
    redirectStderrToHostLog(dir_path, exact_host_id);
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

    // 기록기 backing은 daemon lifetime보다 길 수 있으므로 stack owner에 두지 않는다. 정상 종료에서는 join 뒤
    // 해제하고, regular-file I/O가 200 ms를 넘긴 경우 runtime 스스로 detach하며 process 종료까지 backing을 보존한다.
    const incident_owner = bootstrapIncidentRuntime(allocator, dir_path) catch return error.ManifestFailed;
    var incident_registry: incident_publisher_registry.Registry = .{};
    var incident_published = false;
    // publication 전·후 소유권을 하나의 defer에서만 정산한다. detached writer는
    // open directory FD에 나중에도 쓸 수 있으므로 pathname을 보존하고, joined/abort 정산 뒤에만 빈 directory를 제거한다.
    defer {
        var remove_empty = false;
        if (incident_published) {
            if (incident_owner.shutdownPublished(&incident_registry)) |outcome|
                remove_empty = outcome == .joined or outcome == .degraded_joined
            else |_| {}
        } else {
            // registry publication 전에도 runtime writer는 이미 시작했으므로 detached outcome은 pathname을 보존한다.
            if (incident_owner.abortUnpublished()) |outcome|
                remove_empty = outcome == .joined or outcome == .degraded_joined
            else |_| {}
        }
        if (remove_empty) removeEmptyIncidentDirectory(dir_path);
    }
    incident_registry.initInPlace(incident_owner.process_nonce) catch return error.ManifestFailed;
    incident_owner.installPublisherRegistry(&incident_registry) catch return error.ManifestFailed;
    incident_published = true;

    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();

    // 실 runtime 소유자(app InProcessTermBackend 재사용). registry를 함께 참조해 spawn이 재접속 조회 대상으로 등록한다.
    // **host_id 를 manager 보다 먼저 정한다.** 그 값이 spawn 이 자식에게 실을 훅 로그 인스턴스 칸이라
    // `init` 이 요구한다(docs/agent-hooks.md §4). 업그레이드로 프로세스가 바뀌어도 `host_id` 는 물려받으므로
    // (`upgrade_bootstrap` 이 불일치를 거부한다) 그 칸의 이름이 exec 을 넘어 유지된다 — pid 로 지으면
    // 후계자가 «죽은 인스턴스» 로 보여 살아 있는 runtime 의 로그를 정리가 거둔다.
    const host_id = exact_host_id orelse newHostId();
    // 훅 로그 base 는 manager 보다 오래 살아야 한다(칸을 거두는 아래 defer 도 이 값을 쓴다) — 그래서
    // manager 보다 **먼저** 등록해 LIFO 로 가장 나중에 풀리게 한다.
    const hook_log_base = agent_hook_logs.resolveCacheBase(allocator);
    defer if (hook_log_base) |base| allocator.free(base);
    // **함수 스코프여야 한다.** 이것을 `if (hook_log_base) |base| { … defer … }` 안에 두면 그 블록이
    // 끝나는 즉시 돌아 **방금 만든 칸을 시작하자마자 지운다**(그러면 그 host 의 훅은 영영 안 돈다).
    // 등록 순서가 곧 해제 순서의 역이라, base 해제(위)보다 뒤·manager 해제(아래)보다 앞에 둔다.
    defer if (hook_log_base) |base| agent_hook_logs.removeInstanceDir(io, base, host_id);
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.initWithHostId(allocator, io, &registry, host_id, if (hook_log_base) |base| .{
        .host_id = host_id,
        .log_base = base,
    } else null);
    defer manager.deinit();
    if (notification_adapter) |adapter| manager.installNotificationOsAdapter(adapter);
    // 죽은 host 가 남긴 칸을 거둔다(SIGKILL 로 아래 정리가 못 돈 경우의 안전망). 살아 있는 남의 칸은
    // manifest 로 가려 남긴다 — GUI 는 이 질문에 답할 수 없어 이 정리가 host 쪽에 있다.
    if (hook_log_base) |base| agent_hook_logs.sweepDeadHostDirs(io, base, host_id);
    manager.enableOutputWake() catch return error.ManifestFailed;
    if (fixture_probe != null) {
        manager.enableOutputMetrics();
        manager.fixtureEnableObservationPerformanceEvidence();
        manager.fixtureEnableScreenPerformanceEvidence();
    }
    // socket 을 **실제로 만드는** 자리다. uid 로 계산하면 격리를 켠 실행에서도 사용자의 공용
    // `/tmp/maru-<uid>/sh` 에 socket 이 생겨, 이 host 의 열쇠(격리된 registry)와 자물쇠가 갈린다.
    // 위 tmp-touch 가 지키는 뿌리와도 어긋나 살아 있는 socket 이 정리 대상이 된다.
    var socket_dir_buf: [272]u8 = undefined;
    const bind_dir = if (exact_host_id != null)
        short_endpoint.currentSocketDirPathIn(&socket_dir_buf) catch return error.ManifestFailed
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
    server.owner_wake_fd = manager.outputWakeReadFd().?;
    server.owner_wake_ctx = &manager;
    server.owner_wake_drain = struct {
        fn drain(ctx: *anyopaque) bool {
            const owner: *runtime_manager.RuntimeManager = @ptrCast(@alignCast(ctx));
            return owner.drainOutputWake();
        }
    }.drain;

    var fd_owner = poll_owner.Owner.init(allocator, io, &server) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ProcessIdentityUnavailable => error.ProcessIdentityUnavailable,
    };
    defer fd_owner.deinit();
    // 이 지점 이전에는 ready를 보내지 않는다. owner lease, incident owner, runtime manager, bound socket,
    // ready manifest/authority와 실제 poll owner가 모두 살아 있어야 부모가 connect retry를 시작해도 된다.
    if (startup_notifier) |notifier| notifier.ready();
    // 자연 종료 판정 상태. `served_any_runtime`이 없으면 **방금 뜬 host**(아직 GUI가 첫 runtime을 만들기 전)가
    // 곧바로 자기 자신을 종료해 버린다 — spawn한 GUI가 endpoint를 잃는다.
    var served_any_runtime = false;
    var empty_idle_ticks: usize = 0;
    var last_touch_ms: ?u64 = null;
    while (true) {
        fd_owner.requireCurrentProcessOrFatal();
        server.tickOwner();
        // `/tmp`는 매일 정리된다. 살아 있는 동안 endpoint·manifest 시각을 갱신하지 않으면 3일 이상 조용한
        // host가 자기 endpoint를 잃고, 프로세스는 살아 있는데 아무도 찾지 못하는 상태가 된다.
        const now_ms = awakeMs(io);
        if (shouldTouchRuntimeArtifacts(now_ms, last_touch_ms)) {
            touchRuntimeArtifacts(
                dir_path,
                socket_path,
                host_id,
                if (published_manifest) |*published| published else null,
            );
            last_touch_ms = now_ms;
        }
        if (registry.count() != 0) served_any_runtime = true;
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
            .idle => {
                if (test_oneshot) {
                    test_idle_ticks += 1;
                    if (test_idle_ticks >= 25) break;
                }
                // docs/session-host-upgrade.md 계약: "attachment가 0이어도 runtime이 하나라도 살아 있으면 구
                // host를 종료하지 않으며, runtime count가 0이 된 뒤에만 자연 종료한다." 이 경로가 구현되지
                // 않아 고아 host가 영구히 남았다 — 실측에서 자식 0개인 host가 계속 살아 있어 수동으로 죽여야
                // 했고, build_id가 바뀔 때마다 그런 host가 하나씩 쌓였다.
                //
                // 세 조건을 **모두** 요구한다. runtime을 한 번이라도 서빙했어야 하고(신생 host 보호), 지금
                // runtime이 0이어야 하며(detach된 keep-alive 세션이 있으면 살아남는다), 붙어 있는 client도
                // 없어야 한다(곧 spawn할 GUI를 끊지 않는다).
                if (served_any_runtime and registry.count() == 0 and fd_owner.activeCount() == 0)
                    empty_idle_ticks += 1
                else
                    empty_idle_ticks = 0;
                if (shouldExitNaturally(
                    served_any_runtime,
                    registry.count(),
                    fd_owner.activeCount(),
                    empty_idle_ticks,
                )) break;
            },
            .progress => {},
            .listener_broken => break,
            // A fork child must not run any inherited owner/path cleanup defer. The common fatal
            // leaf exits immediately with proof-loss provenance instead of unwinding this loop.
            .authority_lost => fd_owner.requireCurrentProcessOrFatal(),
        }
        if (fixture_probe) |probe| {
            switch (probe.after_turn(
                probe.ctx,
                fd_owner.telemetrySnapshot(),
                manager.totalPtyOutputBytes(),
                manager.fixtureOutputWakeEvidence(),
                manager.fixtureChildExitEvidence(),
                manager.fixtureObservationPerformanceEvidence(),
                manager.fixtureMetadataSamplerEvidence(),
                manager.fixtureScreenPerformanceEvidence(),
            )) {
                .continue_serving => {},
                .reset_stall => fd_owner.resetFixtureStallTelemetry(),
                .disconnect_clients => fd_owner.disconnect_fixture_clients(),
                .stop => break,
            }
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
        var incidents_buf: [320]u8 = undefined;
        if (std.fmt.bufPrintZ(&incidents_buf, "{s}/incidents", .{dir_path})) |incidents| _ = c.rmdir(incidents.ptr) else |_| {}
        std.Io.Dir.cwd().deleteTree(testing.io, dir_path) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
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
        var incidents_buf: [320]u8 = undefined;
        if (std.fmt.bufPrintZ(&incidents_buf, "{s}/incidents", .{dir_path})) |incidents| _ = c.rmdir(incidents.ptr) else |_| {}
        std.Io.Dir.cwd().deleteTree(testing.io, dir_path) catch {}; // 루트 통째로 — daemon 잔재가 남아 rmdir 은 실패한다
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

// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): host는 GUI가 꺼져도 살아남아야 세션이 유지되지만,
// **영원히 살아남으면 안 된다**. docs/session-host-upgrade.md는 "runtime count가 0이 된 뒤에만 자연 종료한다"고
// 계약하는데 그 경로가 구현되지 않아, 자식이 0개인 host가 계속 남아 build_id가 바뀔 때마다 하나씩 쌓였다(실측:
// 4개까지 누적, 전부 수동으로 죽여야 했다). 반대로 성급하게 죽이면 더 나쁘다 — 방금 뜬 host가 첫 spawn을 받기
// 전에 자신을 종료하면 그 host를 띄운 GUI가 endpoint를 잃고, detach된 keep-alive 세션이 남아 있는데 죽으면
// 사용자의 셸이 통째로 사라진다. 그래서 "한 번 서빙했고, 지금 runtime 0이고, 붙은 client도 0"이라는 세 조건과
// 유예 tick을 전부 요구한다. 순수 판정이라 실 daemon·소켓 없이 이 경계를 고정한다.
test "daemon 자연 종료: 서빙 이력·runtime 0·client 0·유예를 모두 만족할 때만 물러난다" {
    const enough = natural_exit_idle_ticks;
    // 정상 종료 조건.
    try testing.expect(shouldExitNaturally(true, 0, 0, enough));

    // 신생 host 보호 — 아직 아무 runtime도 서빙하지 않았으면 절대 죽지 않는다.
    try testing.expect(!shouldExitNaturally(false, 0, 0, enough));
    // 살아 있는 keep-alive 세션이 있으면 남는다. 여기서 죽으면 사용자의 셸이 사라진다.
    try testing.expect(!shouldExitNaturally(true, 1, 0, enough));
    // 붙어 있는 GUI가 곧 spawn할 수 있으므로 끊지 않는다.
    try testing.expect(!shouldExitNaturally(true, 0, 1, enough));
    // 유예가 차기 전에는 물러나지 않는다 — 마지막 runtime 소멸 직후 재접속하려는 GUI를 위한 창이다.
    try testing.expect(!shouldExitNaturally(true, 0, 0, enough - 1));
    try testing.expect(!shouldExitNaturally(true, 0, 0, 0));
}

test "CR0b daemon incident bootstrap prerequisite는 실제 daemon process owner domain을 발급한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // process seal을 이미 발급한 aggregate process에서는 같은 PID bootstrap을 다시 열 수 없다.
    // build가 만든 exact-one prerequisite artifact만 fresh process owner를 설치한다.
    if (builtin.test_functions.len != 1) return;
    // PID 기반 /tmp 이름은 stale crash나 병렬 실행과 충돌할 수 있다. tmpDir가 원자적으로 소유한
    // 경로와 recursive cleanup을 사용해 이 테스트가 다른 process의 artifact를 관측하지 않게 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const runtime = try bootstrapIncidentRuntime(std.testing.allocator, path);
    var runtime_settled = false;
    defer if (!runtime_settled) {
        _ = runtime.abortUnpublished() catch {};
    };
    try std.testing.expectEqual(@as(u64, @intCast(c.getpid())), runtime.pid);
    try std.testing.expect(runtime.process_nonce != 0);
    try std.testing.expect(runtime.service.process_nonce != 0);
    try std.testing.expectEqual(runtime.process_nonce, runtime.service.process_nonce);
    try std.testing.expectEqual(runtime.process_nonce, runtime.store.process_nonce);
    try std.testing.expect(runtime.service.app_instance_nonce != 0);
    try std.testing.expectEqual(runtime.service.app_instance_nonce, runtime.store.app_instance_nonce);
    try std.testing.expect(runtime.runtime_generation != 0 and runtime.service_generation != 0);
    try std.testing.expect(runtime.runtime_generation != runtime.service_generation);
    try std.testing.expectEqual(runtime.service_generation, runtime.service.service_generation);
    try std.testing.expectEqual(@as(u64, 0), runtime.service.last_issued_sequence);
    const shutdown_outcome = try runtime.abortUnpublished();
    // joined는 backing을 이미 free하고 detached는 process-lifetime backing으로 전환한다. 어느 쪽이든
    // 반환 뒤에는 같은 runtime을 다시 정산할 수 없으므로 assertion보다 먼저 settled를 게시한다.
    runtime_settled = true;
    try std.testing.expectEqual(incident_runtime.ShutdownResult.joined, shutdown_outcome);
}

test "CR0b bootstrap 4 daemon child는 실제 bootstrap transcript를 게시한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // parent runner가 주입한 exact-one child artifact에서만 fresh daemon domain을 발급한다.
    if (builtin.test_functions.len != 1) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const runtime = try bootstrapIncidentRuntime(std.testing.allocator, path);
    var settled = false;
    defer if (!settled) {
        _ = runtime.abortUnpublished() catch {};
    };
    try incident_bootstrap_contract.testing_api.writeChildTranscript(.{
        .pid = @intCast(runtime.pid),
        .role_raw = @intFromEnum(incident_bootstrap_contract.Role.daemon),
        .reserved = .{ 0, 0, 0 },
        .process_nonce = runtime.process_nonce,
        .service_process_nonce = runtime.service.process_nonce,
        .app_instance_nonce = runtime.service.app_instance_nonce,
        .runtime_generation = runtime.runtime_generation,
        .service_generation = runtime.service_generation,
        .last_issued_sequence = runtime.service.last_issued_sequence,
    });
    const outcome = try runtime.abortUnpublished();
    settled = true;
    try std.testing.expectEqual(incident_runtime.ShutdownResult.joined, outcome);
}
