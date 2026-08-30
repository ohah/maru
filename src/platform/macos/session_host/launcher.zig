//! detached-helper launcher — 앱이 `maru __session-host <socket>`를 부모와 독립된 프로세스로 띄운다(§10, §15
//! host launch = detached helper) — P3-d2d.
//!
//! GUI가 첫 persistent runtime을 필요로 할 때(discovery가 `spawn_host`로 판정, P3-d2b) 이 launcher가 session host
//! helper를 **double-fork + setsid**로 띄운다. 그러면 손자(host)는 부모(GUI)와 다른 세션·프로세스 그룹의 orphan이 되어
//! GUI가 종료·크래시해도 살아 남고(init이 reap), GUI는 중간 자식만 reap해 zombie를 남기지 않는다. 이것이 "GUI를 죽여도
//! host 생존"을 배포에서 성립시키는 수명 배선이다.
//!
//! macOS 전용(실 fork/exec/setsid). 순수 부분(argv 조립)은 non-macOS에서도 TDD하고, 실 spawn 메커니즘은 관찰 가능한
//! 자식(marker 파일)으로 process smoke한다. 실제 `maru` 바이너리를 host로 띄우는 제품 argv/CLI 진입은
//! `host_connect.zig`의 product-path process smoke가 검증한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const entrypoint = @import("entrypoint.zig");
const short_endpoint = @import("short_endpoint.zig");
const startup_readiness = @import("startup_readiness.zig");

// execv는 std.c 미노출이라 직접 extern(현재 environ 상속). readiness launch는 fork 전에 만든 envp로 std.c.execve를 쓴다.
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
// 상속 fd를 명시적으로 닫기 위한 descriptor table 크기(soft limit, macOS는 OPEN_MAX로 상한). std.c 미노출이라 extern.
extern "c" fn getdtablesize() c_int;
// 상태 파이프용. `std.c` 에 `pipe`·`fcntl` 이 있지만 이 파일은 이미 libc 를 직접 부르는 규율이라 같은 자리에 둔다.
extern "c" fn pipe(fds: *[2]c.fd_t) c_int;
extern "c" fn fcntl(fd: c.fd_t, cmd: c_int, ...) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// `maru <exe>`를 session host로 전환하는 hidden 서브커맨드 이름. main.zig dispatch와 이 launcher가 공유하는 단일 출처다.
pub const subcommand = entrypoint.subcommand;

pub const SpawnError = error{ ForkFailed, OutOfMemory, ExecFailed, StartupFailed, SharedUserNamespace };

/// host helper의 argv를 조립한다(순수) —
/// `[exe_path, "__session-host", session_dir, socket_path, 32-hex-host_id]`. exec에 넘길 NUL 종단 포인터
/// 배열은 실 spawn 경로가 만들고, 이 함수는 사람이 읽고 테스트하기 쉬운 슬라이스 목록만 돌려준다(caller가 free).
pub fn sessionHostArgv(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    session_dir: []const u8,
    socket_path: []const u8,
    host_id_hex: []const u8,
) error{OutOfMemory}![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 5);
    argv[0] = exe_path;
    argv[1] = subcommand;
    argv[2] = session_dir;
    argv[3] = socket_path;
    argv[4] = host_id_hex;
    return argv;
}

/// 제품 session host 전용 launch API. caller가 raw `spawnDetached` args를 직접 조립하지 않게 하여 hidden subcommand
/// 누락(`maru <socket>`으로 잘못 실행)을 구조적으로 막는다.
pub fn spawnSessionHostDetached(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
) SpawnError!void {
    const host_hex = std.fmt.allocPrintSentinel(allocator, "{x:0>32}", .{host_id}, 0) catch
        return error.OutOfMemory;
    defer allocator.free(host_hex);
    try spawnDetached(allocator, exe_path, &.{ subcommand, session_dir, socket_path, host_hex }, true);
}

/// Signed release E2E 전용 supervised launch. 제품과 같은 hidden command/stdio/fd 경계를 실행하지만
/// double-fork하지 않아 caller가 exact child PID를 소유하고 실패 경로에서도 `waitpid`로 반드시 회수할 수 있다.
/// 앱의 persistent lifetime 계약은 `spawnSessionHostDetached`만 사용한다.
pub fn spawnSessionHostSupervisedForTest(
    allocator: std.mem.Allocator,
    isolated_root: [:0]const u8,
    exe_path: [:0]const u8,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
) SpawnError!c.pid_t {
    if (builtin.os.tag != .macos) return error.ForkFailed;
    try validateIsolatedTestNamespace(isolated_root, session_dir, socket_path);
    const host_hex = std.fmt.allocPrintSentinel(allocator, "{x:0>32}", .{host_id}, 0) catch
        return error.OutOfMemory;
    defer allocator.free(host_hex);
    const args: []const [:0]const u8 = &.{ subcommand, session_dir, socket_path, host_hex };
    var argv = allocator.alloc(?[*:0]const u8, args.len + 2) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = exe_path.ptr;
    for (args, 0..) |arg, i| argv[i + 1] = arg.ptr;
    argv[args.len + 1] = null;

    var child_env = buildTestRootEnvironment(allocator, isolated_root) catch return error.OutOfMemory;
    defer child_env.deinit(allocator);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        closeInheritedFds(null, null);
        redirectStdioToDevNull();
        clearSessionHostTestEnvironment();
        _ = c.execve(exe_path.ptr, @ptrCast(argv.ptr), @ptrCast(child_env.envp.ptr));
        std.c._exit(127);
    }
    return pid;
}

fn pathIsBelow(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root) or path[root.len] != '/')
        return false;
    var components = std.mem.splitScalar(u8, path[root.len + 1 ..], '/');
    var count: usize = 0;
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
        count += 1;
    }
    return count != 0;
}

fn validateIsolatedTestNamespace(
    isolated_root: [:0]const u8,
    session_dir: []const u8,
    socket_path: []const u8,
) error{SharedUserNamespace}!void {
    const tmp_prefix = "/tmp/";
    if (!std.mem.startsWith(u8, isolated_root, tmp_prefix) or
        isolated_root.len == tmp_prefix.len or
        std.mem.indexOfScalar(u8, isolated_root[tmp_prefix.len..], '/') != null or
        !pathIsBelow(isolated_root, session_dir) or !pathIsBelow(isolated_root, socket_path))
        return error.SharedUserNamespace;

    // `/tmp` 자체는 macOS에서 `/private/tmp` 별칭일 수 있다. 그 플랫폼 별칭은 허용하되 우리가
    // 소유하는 leaf는 symlink가 아닌 exact owner-only directory여야 한다.
    var root_stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, isolated_root.ptr, &root_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(root_stat.mode) or root_stat.uid != c.getuid() or
        (root_stat.mode & 0o777) != 0o700)
        return error.SharedUserNamespace;

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_ptr = c.realpath(isolated_root.ptr, &resolved_buf) orelse
        return error.SharedUserNamespace;
    const resolved = std.mem.span(resolved_ptr);

    var shared_buf: [64]u8 = undefined;
    const shared = short_endpoint.userRootPathIn(&shared_buf, c.getuid()) catch
        return error.SharedUserNamespace;
    var resolved_shared_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_shared = if (c.realpath(shared.ptr, &resolved_shared_buf)) |ptr|
        std.mem.span(ptr)
    else
        shared;
    if (std.mem.eql(u8, resolved, resolved_shared)) return error.SharedUserNamespace;
}

/// 격리 override를 모르는 frozen N-1 binary 전용. caller가 먼저 공용 namespace를 exclusive
/// `claimEmptySharedLegacyFixture`로 소유한 경우에만 열린다. 일반/current fixture는 이 API를 쓰지 않는다.
pub fn spawnSessionHostSupervisedLegacySharedForTest(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_id: u128,
) SpawnError!c.pid_t {
    if (builtin.os.tag != .macos or !builtin.is_test) return error.SharedUserNamespace;
    const marker = c.getenv(short_endpoint.legacy_shared_fixture_env) orelse
        return error.SharedUserNamespace;
    if (!std.mem.eql(u8, std.mem.span(marker), short_endpoint.legacy_shared_fixture_value))
        return error.SharedUserNamespace;

    const host_hex = std.fmt.allocPrintSentinel(allocator, "{x:0>32}", .{host_id}, 0) catch
        return error.OutOfMemory;
    defer allocator.free(host_hex);
    const args: []const [:0]const u8 = &.{ subcommand, session_dir, socket_path, host_hex };
    var argv = allocator.alloc(?[*:0]const u8, args.len + 2) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = exe_path.ptr;
    for (args, 0..) |arg, i| argv[i + 1] = arg.ptr;
    argv[args.len + 1] = null;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        closeInheritedFds(null, null);
        redirectStdioToDevNull();
        clearSessionHostTestEnvironment();
        _ = execv(exe_path.ptr, @ptrCast(argv.ptr));
        std.c._exit(127);
    }
    return pid;
}

const TestRootEnvironment = struct {
    envp: []?[*:0]const u8,
    entry: [:0]u8,

    fn deinit(self: *TestRootEnvironment, allocator: std.mem.Allocator) void {
        allocator.free(self.entry);
        allocator.free(self.envp);
        self.* = undefined;
    }
};

fn buildTestRootEnvironment(
    allocator: std.mem.Allocator,
    isolated_root: []const u8,
) error{OutOfMemory}!TestRootEnvironment {
    var inherited_count: usize = 0;
    while (c.environ[inherited_count] != null) : (inherited_count += 1) {}
    var envp = try allocator.alloc(?[*:0]const u8, inherited_count + 2);
    errdefer allocator.free(envp);
    const entry = try std.fmt.allocPrintSentinel(
        allocator,
        "MARU_SESSION_HOST_ROOT={s}",
        .{isolated_root},
        0,
    );
    errdefer allocator.free(entry);

    var written: usize = 0;
    for (0..inherited_count) |index| {
        const inherited = c.environ[index] orelse unreachable;
        const text = std.mem.span(inherited);
        if (std.mem.startsWith(u8, text, short_endpoint.root_override_env) and
            text.len > short_endpoint.root_override_env.len and
            text[short_endpoint.root_override_env.len] == '=') continue;
        if (isSessionHostTestEnvironmentAssignment(text)) continue;
        envp[written] = inherited;
        written += 1;
    }
    envp[written] = entry.ptr;
    @memset(envp[written + 1 ..], null);
    return .{ .envp = envp, .entry = entry };
}

/// `exe_path`를 `args`(NUL 종단 슬라이스들)로 **detached** 실행한다: double-fork로 손자를 부모와 독립시키고, setsid로
/// 새 세션 리더가 되게 하며, std fd를 `/dev/null`로 돌려 부모 터미널에 묶이지 않게 한다. 부모는 중간 자식만 waitpid로
/// reap하고 즉시 반환한다(손자는 orphan → init reap). exec 실패는 손자에서 `_exit(127)`로 끝난다.
fn spawnDetached(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    args: []const [:0]const u8,
    wait_for_daemon: bool,
) SpawnError!void {
    if (builtin.os.tag != .macos) return error.ForkFailed;

    // exec argv: [exe_path, args..., null]. child가 exec 전에 쓰므로 부모 메모리라도 fork로 복제돼 안전하다.
    var argv = allocator.alloc(?[*:0]const u8, args.len + 2) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = exe_path.ptr;
    for (args, 0..) |a, i| argv[i + 1] = a.ptr;
    argv[args.len + 1] = null;

    // **상태 파이프**: 손자의 `execv` 성패를 부모가 **즉시** 알기 위한 통로다. 더블 fork 라 손자는 orphan 이고
    // 부모에게는 `waitpid` 할 자식이 없어, 이 통로가 없으면 exec 실패를 알 방법이 아예 없다 — 그러면 호출부가
    // 재시도 예산을 통째로 물고서야 «안 떴다» 로 끝낸다(실측 4123 ms).
    //
    // 동작은 표준 관용구다: 쓰기 끝에 `FD_CLOEXEC` 를 걸어 두면 **exec 성공 시 커널이 그 fd 를 닫아** 부모가
    // EOF 를 보고, **실패하면** 손자가 그 파이프에 `errno` 를 적고 죽어 부모가 이유까지 받는다.
    var status_fds: [2]c.fd_t = undefined;
    const have_pipe = pipe(&status_fds) == 0;
    if (have_pipe and fcntl(status_fds[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
        _ = c.close(status_fds[0]);
        _ = c.close(status_fds[1]);
        return error.StartupFailed;
    }
    // 파이프를 못 만들면 예전처럼 «띄우고 잊는다» 로 돈다 — 진단이 없을 뿐 회귀는 아니다.
    const write_fd: ?c.fd_t = if (have_pipe) status_fds[1] else null;

    // exec 성공과 daemon 준비는 다른 사실이다. fresh host만 별도 Unix socketpair를 물려받아 owner lease,
    // bind, ready manifest, poll owner가 모두 준비됐는지 한 바이트로 답한다. socket을 쓰는 이유는 parent가
    // legacy timeout 뒤 닫아도 SO_NOSIGPIPE로 daemon process가 죽지 않게 하기 위해서다.
    var ready_fds: [2]c.fd_t = undefined;
    const have_ready = wait_for_daemon and
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &ready_fds) == 0;
    if (wait_for_daemon and !have_ready) {
        if (have_pipe) {
            _ = c.close(status_fds[0]);
            _ = c.close(status_fds[1]);
        }
        return error.StartupFailed;
    }
    if (have_ready) {
        const enabled: c_int = 1;
        if (c.setsockopt(
            ready_fds[1],
            posix.SOL.SOCKET,
            posix.SO.NOSIGPIPE,
            @ptrCast(&enabled),
            @sizeOf(c_int),
        ) != 0) {
            if (have_pipe) {
                _ = c.close(status_fds[0]);
                _ = c.close(status_fds[1]);
            }
            _ = c.close(ready_fds[0]);
            _ = c.close(ready_fds[1]);
            return error.StartupFailed;
        }
    }
    const ready_write_fd: ?c.fd_t = if (have_ready) ready_fds[1] else null;

    // 다중 스레드 GUI의 fork child에서 setenv/allocator lock을 건드리지 않는다. readiness envp와 문자열은
    // fork 전에 부모가 만들고, child는 async-signal-safe execve에 이미 완성된 포인터만 넘긴다.
    var readiness_env: ?ReadinessEnvironment = null;
    if (ready_write_fd) |fd| {
        readiness_env = buildReadinessEnvironment(allocator, fd) catch {
            if (have_pipe) {
                _ = c.close(status_fds[0]);
                _ = c.close(status_fds[1]);
            }
            _ = c.close(ready_fds[0]);
            _ = c.close(ready_fds[1]);
            return error.OutOfMemory;
        };
    }
    defer if (readiness_env) |*env| env.deinit(allocator);

    const pid1 = c.fork();
    if (pid1 < 0) {
        if (have_pipe) {
            _ = c.close(status_fds[0]);
            _ = c.close(status_fds[1]);
        }
        if (have_ready) {
            _ = c.close(ready_fds[0]);
            _ = c.close(ready_fds[1]);
        }
        return error.ForkFailed;
    }
    if (pid1 == 0) {
        // 중간 자식: 새 세션 리더가 된 뒤 다시 fork해 손자를 만든다. 중간 자식이 곧 죽으면 손자는 session leader가 아니라
        // orphan이 되어 controlling terminal을 다시 얻지 않는다(daemon 관용구).
        _ = c.setsid();
        const pid2 = c.fork();
        if (pid2 < 0) {
            if (write_fd) |fd| {
                const byte = [_]u8{1};
                _ = c.write(fd, &byte, 1);
            }
            std.c._exit(127);
        }
        if (pid2 == 0) {
            // stdio 위 상속 fd(GUI socket·PTY master·control-plane·capability fd)를 exec 전에 모두 닫는다. fork는 부모
            // fd 테이블을 복제하고 exec는 CLOEXEC 아닌 fd를 그대로 넘기므로, 닫지 않으면 detached host가 GUI 자원을
            // 물려받아 fd 누수·정보 노출이 생긴다(§11). 그다음 0/1/2를 /dev/null로 돌린다(닫힌 3번을 재사용).
            // 상태 파이프만 남긴다 — 그 fd 는 exec 가 성공하면 CLOEXEC 로 저절로 닫힌다.
            closeInheritedFds(write_fd, ready_write_fd);
            redirectStdioToDevNull();
            if (readiness_env) |env|
                _ = c.execve(exe_path.ptr, @ptrCast(argv.ptr), @ptrCast(env.envp.ptr))
            else
                _ = execv(exe_path.ptr, @ptrCast(argv.ptr));
            // 여기 왔으면 exec 실패다. 이유를 한 바이트로 적어 보낸다(부모는 «왔다/안 왔다» 로 가른다).
            if (write_fd) |fd| {
                const code: u8 = @truncate(@as(u32, @bitCast(std.c._errno().*)));
                var byte = [_]u8{code};
                _ = c.write(fd, &byte, 1);
            }
            std.c._exit(127); // execv는 성공 시 반환하지 않는다 — 여기 오면 exec 실패.
        }
        std.c._exit(0); // 중간 자식 종료 → 손자 orphan(부모는 손자를 모른다).
    }
    // 부모(GUI): 쓰기 끝을 **먼저 닫는다**. 우리 사본이 열려 있으면 EOF 가 영영 안 온다.
    if (have_pipe) _ = c.close(status_fds[1]);
    if (have_ready) _ = c.close(ready_fds[1]);
    // 중간 자식을 reap해 zombie를 안 남긴다. 손자(host)는 부모와 무관하게 산다. **reap 이 먼저다** — 중간 자식도
    // 쓰기 끝 사본을 갖고 있어, 그것이 사라지기 전에 읽으면 exec 가 성공했는데도 잠깐 막힌다.
    var status: c_int = undefined;
    while (true) {
        const waited = c.waitpid(pid1, &status, 0);
        if (waited >= 0) break;
        if (posix.errno(waited) == .INTR) continue;
        if (have_pipe) _ = c.close(status_fds[0]);
        if (have_ready) _ = c.close(ready_fds[0]);
        return error.StartupFailed;
    }

    if (have_pipe) {
        defer _ = c.close(status_fds[0]);
        var buf: [1]u8 = undefined;
        var n: isize = undefined;
        while (true) {
            n = c.read(status_fds[0], &buf, buf.len);
            if (n >= 0 or posix.errno(n) != .INTR) break;
        }
        // n == 0 → EOF → exec 성공(커널이 CLOEXEC 로 닫았다). n > 0 → 손자가 실패 이유를 적고 죽었다.
        if (n != 0) {
            if (have_ready) _ = c.close(ready_fds[0]);
            return error.ExecFailed;
        }
    }
    if (have_ready) {
        defer _ = c.close(ready_fds[0]);
        switch (startup_readiness.awaitParent(ready_fds[0], startup_readiness.legacy_wait_ms)) {
            .ready, .legacy_timeout => return,
            .failed => return error.StartupFailed,
        }
    }
}

const ReadinessEnvironment = struct {
    envp: []?[*:0]const u8,
    entry: [:0]u8,

    fn deinit(self: *ReadinessEnvironment, allocator: std.mem.Allocator) void {
        allocator.free(self.entry);
        allocator.free(self.envp);
        self.* = undefined;
    }
};

fn buildReadinessEnvironment(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
) error{OutOfMemory}!ReadinessEnvironment {
    var inherited_count: usize = 0;
    while (c.environ[inherited_count] != null) : (inherited_count += 1) {}
    var envp = try allocator.alloc(?[*:0]const u8, inherited_count + 2);
    errdefer allocator.free(envp);
    const entry = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}={d}",
        .{ startup_readiness.env_name, fd },
        0,
    );
    errdefer allocator.free(entry);

    var written: usize = 0;
    for (0..inherited_count) |index| {
        const inherited = c.environ[index] orelse unreachable;
        const text = std.mem.span(inherited);
        if (std.mem.startsWith(u8, text, startup_readiness.env_name) and
            text.len > startup_readiness.env_name.len and
            text[startup_readiness.env_name.len] == '=') continue;
        envp[written] = inherited;
        written += 1;
    }
    envp[written] = entry.ptr;
    @memset(envp[written + 1 ..], null);
    return .{ .envp = envp, .entry = entry };
}

/// stdio(0·1·2) 위의 상속 fd를 모두 닫는다. CLOEXEC에 의존하지 않고 fd 3..getdtablesize()를 명시적으로 close해
/// detached host가 부모(GUI) fd를 하나도 물려받지 않게 한다(best-effort — 이미 닫힌 fd의 close는 무해). redirect보다
/// **먼저** 불러야 /dev/null redirect가 쓰는 fd 3이 곧바로 닫히지 않는다.
fn closeInheritedFds(keep_a: ?c.fd_t, keep_b: ?c.fd_t) void {
    const max_fd = getdtablesize();
    if (max_fd <= 3) return;
    var fd: c_int = 3;
    while (fd < max_fd) : (fd += 1) {
        // **상태 파이프만 예외다.** 그 fd 까지 닫으면 exec 실패를 부모에게 알릴 통로가 사라져,
        // 손자가 죽어도 부모는 재시도 예산을 통째로 물고서야 «안 떴다» 를 안다(실측 4123 ms).
        if (keep_a) |k| {
            if (fd == k) continue;
        }
        if (keep_b) |k| if (fd == k) continue;
        _ = c.close(fd);
    }
}

/// detached host의 std fd를 `/dev/null`로 돌린다(부모 터미널 미점유). 열기 실패해도 exec는 진행한다(best-effort).
fn redirectStdioToDevNull() void {
    const fd = c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0));
    if (fd < 0) return;
    _ = c.dup2(fd, 0);
    _ = c.dup2(fd, 1);
    _ = c.dup2(fd, 2);
    if (fd > 2) _ = c.close(fd);
}

const session_host_test_environment_names = [_][:0]const u8{
    "MARU_SESSION_HOST_ACTIVATION_MARKER",
    "MARU_SESSION_HOST_PRODUCT_EXE",
    "MARU_SESSION_HOST_REQUIRE_PRODUCT_LAUNCH_SMOKE",
    "MARU_SESSION_HOST_RESTORE_TEST_EXE",
    "MARU_SESSION_HOST_TEST_ONESHOT",
    "MARU_SESSION_HOST_UPGRADE_NEW_EXE",
    "MARU_SESSION_HOST_UPGRADE_NEXT_EXE",
    "MARU_SESSION_HOST_UPGRADE_OLD_EXE",
};

fn isSessionHostTestEnvironmentAssignment(entry: []const u8) bool {
    for (session_host_test_environment_names) |name| {
        if (entry.len > name.len and std.mem.startsWith(u8, entry, name) and
            entry[name.len] == '=') return true;
    }
    return false;
}

fn clearSessionHostTestEnvironment() void {
    for (session_host_test_environment_names) |name| _ = unsetenv(name.ptr);
}

// ─────────────────────────────────────────────────────────────────────────────
// 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 앱이 session host를 **부모와 독립된** 프로세스로 띄워야
// GUI가 죽어도 host가 산다. argv 조립(순수)이 `maru __session-host <socket>` 형태인지, double-fork spawn이 실제로
// 부모를 막지 않고 detached 자식을 실행하는지(관찰 가능한 marker 파일로) 고정한다. 실 fork/exec는 macOS opt-in이다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "launcher: sessionHostArgv includes exact session dir, socket, and host identity" {
    const allocator = testing.allocator;
    const argv = try sessionHostArgv(
        allocator,
        "/usr/local/bin/maru",
        "/tmp/cache/session-host",
        "/tmp/maru-501/sh/0000000000000000000000000000aabb.sock",
        "0000000000000000000000000000aabb",
    );
    defer allocator.free(argv);
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings("/usr/local/bin/maru", argv[0]);
    try testing.expectEqualStrings("__session-host", argv[1]);
    try testing.expectEqualStrings("/tmp/cache/session-host", argv[2]);
    try testing.expectEqualStrings("/tmp/maru-501/sh/0000000000000000000000000000aabb.sock", argv[3]);
    try testing.expectEqualStrings("0000000000000000000000000000aabb", argv[4]);
}

test "launcher: readiness envp is completed before fork and replaces ambient startup fd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try testing.expect(startup_readiness.installEnvironment(99));
    defer _ = unsetenv(startup_readiness.env_name.ptr);

    var env = try buildReadinessEnvironment(testing.allocator, 17);
    defer env.deinit(testing.allocator);
    var matches: usize = 0;
    for (env.envp) |entry_ptr| {
        const entry = entry_ptr orelse continue;
        const text = std.mem.span(entry);
        if (std.mem.startsWith(u8, text, startup_readiness.env_name) and
            text.len > startup_readiness.env_name.len and
            text[startup_readiness.env_name.len] == '=')
        {
            matches += 1;
            try testing.expectEqualStrings("MARU_SESSION_HOST_STARTUP_FD=17", text);
        }
    }
    try testing.expectEqual(@as(usize, 1), matches);
}

test "launcher: signed E2E supervised child has an exact waitpid owner" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrintZ(
        &root_buf,
        "/tmp/maru-supervised-test-isolated-{d}",
        .{c.getpid()},
    );
    if (c.mkdir(root.ptr, 0o700) != 0) return error.IsolatedFixtureUnavailable;
    defer _ = c.rmdir(root.ptr);
    var session_buf: [128]u8 = undefined;
    const session_dir = try std.fmt.bufPrintZ(&session_buf, "{s}/session-host", .{root});
    var socket_buf: [160]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&socket_buf, "{s}/sh/unused.sock", .{root});
    const pid = try spawnSessionHostSupervisedForTest(
        testing.allocator,
        root,
        "/usr/bin/false",
        session_dir,
        socket_path,
        1,
    );
    var status: c_int = undefined;
    try testing.expectEqual(pid, c.waitpid(pid, &status, 0));
}

test "launcher: product-child fixture rejects traversal and symlink aliases of the live namespace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var shared_buf: [64]u8 = undefined;
    const shared = try short_endpoint.userRootPathIn(&shared_buf, c.getuid());

    var traversal_buf: [96]u8 = undefined;
    const traversal = try std.fmt.bufPrintZ(
        &traversal_buf,
        "/tmp/maru-launcher-alias/../maru-{d}",
        .{c.getuid()},
    );
    var traversal_session_buf: [128]u8 = undefined;
    const traversal_session = try std.fmt.bufPrintZ(&traversal_session_buf, "{s}/session-host", .{traversal});
    var traversal_socket_buf: [160]u8 = undefined;
    const traversal_socket = try std.fmt.bufPrintZ(&traversal_socket_buf, "{s}/sh/test.sock", .{traversal});
    try std.testing.expectError(
        error.SharedUserNamespace,
        validateIsolatedTestNamespace(traversal, traversal_session, traversal_socket),
    );

    var isolated_buf: [96]u8 = undefined;
    const isolated = try std.fmt.bufPrintZ(
        &isolated_buf,
        "/tmp/maru-launcher-isolated-{d}",
        .{c.getpid()},
    );
    if (c.mkdir(isolated.ptr, 0o700) != 0) return error.IsolatedFixtureUnavailable;
    defer _ = c.rmdir(isolated.ptr);
    var child_traversal_buf: [160]u8 = undefined;
    const child_traversal = try std.fmt.bufPrintZ(
        &child_traversal_buf,
        "{s}/../maru-{d}/session-host",
        .{ isolated, c.getuid() },
    );
    var isolated_socket_buf: [160]u8 = undefined;
    const isolated_socket = try std.fmt.bufPrintZ(&isolated_socket_buf, "{s}/sh/test.sock", .{isolated});
    try std.testing.expectError(
        error.SharedUserNamespace,
        validateIsolatedTestNamespace(isolated, child_traversal, isolated_socket),
    );

    var alias_buf: [96]u8 = undefined;
    const alias = try std.fmt.bufPrintZ(
        &alias_buf,
        "/tmp/maru-launcher-live-alias-{d}",
        .{c.getpid()},
    );
    if (c.symlink(shared.ptr, alias) != 0) return error.SymlinkFixtureFailed;
    defer _ = c.unlink(alias.ptr);
    var alias_session_buf: [128]u8 = undefined;
    const alias_session = try std.fmt.bufPrintZ(&alias_session_buf, "{s}/session-host", .{alias});
    var alias_socket_buf: [160]u8 = undefined;
    const alias_socket = try std.fmt.bufPrintZ(&alias_socket_buf, "{s}/sh/test.sock", .{alias});
    try std.testing.expectError(
        error.SharedUserNamespace,
        validateIsolatedTestNamespace(alias, alias_session, alias_socket),
    );
}

test "launcher: isolated exec environment drops every host test control" {
    for (session_host_test_environment_names) |name| {
        var assignment_buf: [128]u8 = undefined;
        const assignment = try std.fmt.bufPrint(&assignment_buf, "{s}=ambient", .{name});
        try std.testing.expect(isSessionHostTestEnvironmentAssignment(assignment));
        try std.testing.expect(!isSessionHostTestEnvironmentAssignment(name));
    }
    try std.testing.expect(!isSessionHostTestEnvironmentAssignment("MARU_SESSION_HOST_ROOT=/tmp/example"));
    try std.testing.expect(!isSessionHostTestEnvironmentAssignment("PATH=/usr/bin:/bin"));
}

test "launcher: spawnDetached runs a detached child without blocking the parent (marker)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrintZ(&marker_buf, "/tmp/maru-sh-launch-{d}.marker", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.unlink(marker.ptr); // 이전 잔해 제거.

    // detached로 `/bin/sh -c 'touch <marker>'`를 띄운다. 부모(테스트)는 즉시 반환하고, 손자가 marker를 만든다.
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "touch {s}", .{marker}) catch return error.SkipZigTest;
    const dash_c: [:0]const u8 = "-c";
    try spawnDetached(allocator, "/bin/sh", &.{ dash_c, cmd }, false);

    // 손자가 marker를 만들 때까지 짧게 대기(부모는 손자를 reap하지 않으므로 파일 존재로 관찰).
    var attempts: usize = 0;
    var seen = false;
    while (attempts < 100) : (attempts += 1) {
        if (c.access(marker.ptr, 0) == 0) {
            seen = true;
            break;
        }
        _ = usleepMs(20);
    }
    _ = c.unlink(marker.ptr);
    try testing.expect(seen);
}

// 더블 fork 라 부모에게는 손자를 `waitpid` 할 방법이 없다. 그래서 `execv` 가 실패하면 예전에는 **아무도 몰랐고**,
// 호출부가 재시도 예산을 통째로 문 뒤에야 «안 떴다» 로 끝냈다(실측 4123 ms — 실행 권한 없는 파일로 재현했다).
// 상태 파이프가 그 사실을 즉시 돌려준다.
//
// 이 판정자는 «즉시» 를 시간으로 재지 않는다 — 시간 단언은 느린 CI 에서 흔들린다. 대신 **오류가 돌아오는지**를
// 본다. 옛 동작에서는 오류 자체가 없었으므로 그것만으로 회귀를 잡는다.
test "launcher: exec 실패를 부모가 즉시 안다 — 예전엔 알 방법이 없었다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    // 파일은 있는데 실행이 안 되는 상태 = 부분 설치·격리된 바이너리의 모양이다.
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/maru-sh-noexec-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.SkipZigTest;
    _ = c.close(fd);
    defer _ = c.unlink(path.ptr);

    const dummy: [:0]const u8 = "x";
    try testing.expectError(error.ExecFailed, spawnDetached(allocator, path, &.{dummy}, false));
}

// 존재하지 않는 경로도 같은 자리에서 걸린다 — `execv` 는 손자에서 실패하므로 부모가 알 방법이 파이프뿐이다.
test "launcher: 없는 실행 파일도 exec 실패로 돌아온다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const dummy: [:0]const u8 = "x";
    try testing.expectError(
        error.ExecFailed,
        spawnDetached(allocator, "/tmp/maru-sh-does-not-exist-at-all", &.{dummy}, false),
    );
}

test "launcher: product daemon pre-ready failure is reported through startup channel" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const product_exe: [:0]const u8 = std.mem.span(product_raw);

    var host_dir_buf: [160]u8 = undefined;
    const host_dir = std.fmt.bufPrintZ(
        &host_dir_buf,
        "/tmp/maru-sh-startup-file-{d}",
        .{c.getpid()},
    ) catch return error.SkipZigTest;
    _ = c.unlink(host_dir.ptr);
    const file_fd = c.open(
        host_dir.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
        @as(c.mode_t, 0o600),
    );
    if (file_fd < 0) return error.SkipZigTest;
    _ = c.close(file_fd);
    defer _ = c.unlink(host_dir.ptr);

    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x51A7;
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    defer _ = c.unlink(socket.ptr);

    // exec는 성공하지만 owner directory 자리에 일반 파일이 있으므로 daemon이 bind/manifest 전에
    // OwnerLeaseFailed로 닫힌다. 부모가 이를 ExecFailed가 아닌 StartupFailed로 받는지가 제품 배선을 증명한다.
    try testing.expectError(
        error.StartupFailed,
        spawnSessionHostDetached(testing.allocator, product_exe, host_dir, socket, host_id),
    );
}

extern "c" fn usleep(usec: c_uint) c_int;
fn usleepMs(ms: c_uint) c_int {
    return usleep(ms * 1000);
}
