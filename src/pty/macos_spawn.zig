//! macOS 의 `posix_spawn` 을 `POSIX_SPAWN_CLOEXEC_DEFAULT` 로만 부르는 헬퍼(docs/session-host-image-channel.md §7).
//!
//! `posix_spawn` 계열(Darwin `system()` 포함)은 `pthread_atfork` 를 부르지 않아, 앱이 이미지 채널로 받은 fd 를 지키는 fork 울타리
//! (`session_host/fork_fd_fence.zig`)를 지나지 않는다. CLOEXEC_DEFAULT 는 file action 으로 명시한 fd 말고는 자식에 하나도 넘기지
//! 않는다 — 받은 fd 가 아직 CLOEXEC 가 아니어도 새지 않는다. 앱 코드는 `posix_spawn`·`posix_spawnp`·`system` 을 이 파일 밖에서
//! 부르지 않는다(`tests/boundary/spawn_cloexec_axis.zig`).
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// 자식의 stdio(0·1·2).
pub const Stdio = enum {
    /// 부모의 0·1·2 를 그대로 넘긴다(`system()` 과 같다). 그 밖의 fd 는 하나도 넘기지 않는다.
    inherit,
    /// `/dev/null` 로 돌린다 — 자식이 부모의 어떤 fd 도 갖지 않는다.
    dev_null,
};

pub const SpawnError = error{SpawnFailed};

extern "c" fn posix_spawnattr_setsigmask(attr: *c.posix_spawnattr_t, mask: *const c.sigset_t) c_int;
extern "c" fn posix_spawnattr_setsigdefault(attr: *c.posix_spawnattr_t, signals: *const c.sigset_t) c_int;

/// `path` 를 `argv`·`envp` 로 띄운다. fd 는 `stdio` 가 정한 0·1·2 만 넘긴다.
pub fn spawn(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    stdio: Stdio,
) SpawnError!c.pid_t {
    return spawnImpl(path, argv, envp, stdio, null, null);
}

/// Map only the named stdio descriptors. Null slots are closed in the child.
/// Sources must be nonstdio descriptors or the same stdio slot (no cycles).
/// CLOEXEC_DEFAULT closes every other descriptor, even above a lowered soft
/// limit or opened by another thread while spawn is being prepared.
pub fn spawnMapped(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, sources: [3]?c.fd_t) SpawnError!c.pid_t {
    for (sources, 0..) |source, index| if (source) |fd| {
        if (fd < 0 or (fd < 3 and fd != @as(c.fd_t, @intCast(index)))) return error.SpawnFailed;
    };
    return spawnImpl(path, argv, envp, .inherit, null, sources);
}

const CaptureOptions = struct { write_fd: c.fd_t, directory_fd: c.fd_t };
pub const Captured = struct { pid: c.pid_t, stdout_fd: c.fd_t };

/// Search owns the returned descriptor and PID. Prepare all owned argv/env memory
/// before spawn, and preserve the already-open root rather than resolving its path again.
pub fn captureStdout(a: std.mem.Allocator, argv: []const []const u8, environment: *const std.process.Environ.Map, directory_fd: c.fd_t) !Captured {
    if (argv.len == 0 or !std.fs.path.isAbsolute(argv[0])) return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owned = arena.allocator();
    const args = try owned.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArguments;
        args[i] = (try owned.dupeSentinel(u8, arg, 0)).ptr;
    }
    const env = try environment.createPosixBlock(owned, .{});
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.SpawnFailed;
    errdefer for (pipe) |fd| {
        _ = c.close(fd);
    };
    for (pipe) |fd| if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.SpawnFailed;
    const pid = try spawnImpl(args[0].?, args.ptr, env.slice.ptr, .dev_null, .{ .write_fd = pipe[1], .directory_fd = directory_fd }, null);
    _ = c.close(pipe[1]);
    return .{ .pid = pid, .stdout_fd = pipe[0] };
}

fn spawnImpl(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, stdio: Stdio, capture: ?CaptureOptions, mappings: ?[3]?c.fd_t) SpawnError!c.pid_t {
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawnattr_destroy(&attr);
    // 신호도 기본값으로 — exec 는 부르는 스레드의 신호 마스크와 무시(SIG_IGN) 처분을 물려준다. 그대로 두면 SIGTERM 을 막은
    // 스레드가 띄운 자식은 TERM 으로 끝나지 않고, SIGPIPE 를 무시하는 앱의 셸은 파이프가 닫혀도 멈추지 않는다(`system()` 은
    // INT·QUIT 을 기본으로 돌리고 마스크를 비운다). 마스크는 비우고 모든 신호를 기본 처리로 시작한다.
    if (c.posix_spawnattr_setflags(&attr, .{ .CLOEXEC_DEFAULT = true, .SETSIGMASK = true, .SETSIGDEF = true }) != 0)
        return error.SpawnFailed;
    var empty_mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&empty_mask);
    if (posix_spawnattr_setsigmask(&attr, &empty_mask) != 0) return error.SpawnFailed;
    var all_signals: c.sigset_t = undefined;
    _ = c.sigfillset(&all_signals);
    if (posix_spawnattr_setsigdefault(&attr, &all_signals) != 0) return error.SpawnFailed;
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (capture) |output| {
        if (c.posix_spawn_file_actions_addfchdir_np(&actions, output.directory_fd) != 0) return error.SpawnFailed;
    }
    for ([_]c.fd_t{ 0, 1, 2 }) |fd| {
        if (mappings) |sources| {
            if (sources[@intCast(fd)]) |source| {
                if (c.posix_spawn_file_actions_adddup2(&actions, source, fd) != 0) return error.SpawnFailed;
            }
            continue;
        }

        if (fd == 1) if (capture) |output| {
            if (c.posix_spawn_file_actions_adddup2(&actions, output.write_fd, 1) != 0) return error.SpawnFailed;
            continue;
        };

        // 닫힌 stdio 를 넘기라고 하면 spawn 이 EBADF 로 실패한다 — `system()` 처럼 띄우려면 그 자리는 `/dev/null` 로 채운다.
        const inherit = stdio == .inherit and c.fcntl(fd, c.F.GETFD) != -1;
        if (inherit) {
            if (c.posix_spawn_file_actions_addinherit_np(&actions, fd) != 0) return error.SpawnFailed;
        } else {
            const flags: c_int = if (fd == 0) 0 else 1; // O_RDONLY · O_WRONLY
            if (c.posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", flags, 0) != 0) return error.SpawnFailed;
        }
    }
    if (mappings) |sources| {
        for (sources, 0..) |source, index| {
            if (source == null and c.fcntl(@intCast(index), c.F.GETFD) >= 0 and c.posix_spawn_file_actions_addclose(&actions, @intCast(index)) != 0) return error.SpawnFailed;
            if (source) |fd| {
                if (fd < 3) continue;
                var already_closed = false;
                for (sources[0..index]) |previous| if (previous == source) {
                    already_closed = true;
                };
                if (!already_closed and c.posix_spawn_file_actions_addclose(&actions, fd) != 0) return error.SpawnFailed;
            }
        }
    }
    var pid: c.pid_t = 0;
    if (c.posix_spawn(&pid, path, &actions, &attr, argv, envp) != 0) return error.SpawnFailed;
    return pid;
}

/// 자식을 기다려 wait status 를 준다(EINTR 은 다시 기다린다). 기다릴 수 없으면 null.
pub fn wait(pid: c.pid_t) ?c_int {
    while (true) {
        var status: c_int = 0;
        const rc = c.waitpid(pid, &status, 0);
        if (rc == pid) return status;
        if (rc == -1 and c._errno().* == @backingInt(c.E.INTR)) continue;
        return null;
    }
}

/// `system()` 대신 — `/bin/sh -c command` 를 부모 환경·stdio 로 돌려 wait status 를 준다(띄우지 못하면 -1). 0·1·2 말고는 넘기지 않는다.
pub fn runShell(command: [*:0]const u8) c_int {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const pid = spawn("/bin/sh", &argv, c.environ, .inherit) catch return -1;
    return wait(pid) orelse -1;
}

const testing = std.testing;

test "macos spawn: a shell sees only stdio — a parent fd without CLOEXEC is not inherited" {
    // `pty` 배럴에 걸려 모든 타깃에서 분석된다 — macOS 밖에서는 아래를 분석하지 않는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // CLOEXEC 가 꺼진 fd — 이미지 채널로 막 받아 아직 `F_SETFD` 전인 세그먼트 fd 와 같은 처지다.
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.TestUnexpectedResult;
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    try testing.expectEqual(@as(c_int, 0), c.fcntl(fds[0], c.F.GETFD) & c.FD_CLOEXEC);
    var command_buf: [64]u8 = undefined;
    const probe = try std.fmt.bufPrintSentinel(&command_buf, "[ -e /dev/fd/{d} ] && exit 7; exit 3", .{fds[0]}, 0);
    const status = runShell(probe.ptr);
    try testing.expect(c.W.IFEXITED(@bitCast(status)));
    try testing.expectEqual(@as(u8, 3), c.W.EXITSTATUS(@bitCast(status)));
    // stdio 는 넘긴다 — `system()` 과 같다.
    const stdio_status = runShell("[ -e /dev/fd/0 ] && [ -e /dev/fd/1 ] && [ -e /dev/fd/2 ] && exit 5; exit 6");
    try testing.expectEqual(@as(u8, 5), c.W.EXITSTATUS(@bitCast(stdio_status)));
}

test "macos spawn: a closed stdio does not fail the shell — that slot becomes /dev/null" {
    // `pty` 배럴에 걸려 모든 타깃에서 분석된다 — macOS 밖에서는 아래를 분석하지 않는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 닫힌 stdin — GUI 앱이 0 을 닫고 떠도 terminfo 컴파일이 폴백으로 빠지지 않아야 한다.
    const saved = c.dup(0);
    try testing.expect(saved >= 0);
    defer {
        _ = c.dup2(saved, 0);
        _ = c.close(saved);
    }
    _ = c.close(0);
    const status = runShell("exit 4");
    try testing.expect(status != -1);
    try testing.expectEqual(@as(u8, 4), c.W.EXITSTATUS(@bitCast(status)));
}

test "macos spawn: dev_null stdio hands the child no parent fd at all, and a missing program is SpawnFailed" {
    // `pty` 배럴에 걸려 모든 타깃에서 분석된다 — macOS 밖에서는 아래를 분석하지 않는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "[ -t 0 ] || [ -t 1 ] && exit 9; exit 4" };
    const envp = [_:null]?[*:0]const u8{};
    const pid = try spawn("/bin/sh", &argv, &envp, .dev_null);
    const status = wait(pid) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 4), c.W.EXITSTATUS(@bitCast(status)));
    const missing = [_:null]?[*:0]const u8{"/nonexistent/maru-spawn-probe"};
    try testing.expectError(error.SpawnFailed, spawn("/nonexistent/maru-spawn-probe", &missing, &envp, .dev_null));
}

test "macos spawn: the child starts with default signal handling — a blocked or ignored SIGTERM in the parent does not reach it" {
    // `pty` 배럴에 걸려 모든 타깃에서 분석된다 — macOS 밖에서는 아래를 분석하지 않는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 부모 스레드가 SIGTERM 을 막고(무시도 하고) 있어도 자식은 기본 처리로 시작해야 한다 — exec 는 신호 마스크와 무시 처분을
    // 물려준다. 물려받으면 TERM 으로 끝내려던 자식(시간 초과한 codesign 등)이 살아남는다.
    var blocked: c.sigset_t = undefined;
    _ = c.sigemptyset(&blocked);
    _ = c.sigaddset(&blocked, .TERM);
    var previous_mask: c.sigset_t = undefined;
    if (c.pthread_sigmask(c.SIG.BLOCK, &blocked, &previous_mask) != 0) return error.TestUnexpectedResult;
    defer _ = c.pthread_sigmask(c.SIG.SETMASK, &previous_mask, &blocked);
    var ignore: c.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = blocked, .flags = 0 };
    var previous_action: c.Sigaction = undefined;
    if (c.sigaction(.TERM, &ignore, &previous_action) != 0) return error.TestUnexpectedResult;
    defer _ = c.sigaction(.TERM, &previous_action, null);

    // 자식이 exec 를 마친 뒤 **스스로** TERM 을 보낸다 — 부모가 곧바로 보내면 무거운 부하에서 아직 exec 중인 자식에게 도착한
    // 신호가 늦게 처리돼 2 초 예산을 넘겼다(같은 모양의 `web_osr_install` 테스트가 8 중 병렬 + 바쁜 루프 16 에서 120 번 중 2~5 번,
    // CI #4449). 물려받으면 잡는 것은 그대로다: 무시 처분을 물려받은 sh 는 그 신호를 되돌릴 수 없어(POSIX — 시작 때 무시된
    // 신호) 살아남아 정상 종료하고, 막힌 마스크를 물려받으면 신호가 보류된 채 정상 종료한다 — 둘 다 아래 IFSIGNALED 에서 빨갛다.
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "kill -TERM $$" };
    const envp = [_:null]?[*:0]const u8{};
    const pid = try spawn("/bin/sh", &argv, &envp, .dev_null);
    // 10 초 안에 TERM 으로 끝나야 한다(실제 자식을 띄우는 판정자의 부하 실측 ~3 초 — 시간은 이 테스트의 주제가 아니다).
    // 못 끝나면 KILL 로 거두고 실패.
    var waited_ms: usize = 0;
    var status: c_int = 0;
    const exited = while (waited_ms < 10_000) : (waited_ms += 10) {
        if (c.waitpid(pid, &status, std.posix.W.NOHANG) == pid) break true;
        var ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    } else false;
    if (!exited) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, &status, 0);
    }
    try testing.expect(exited);
    try testing.expect(c.W.IFSIGNALED(@bitCast(status)));
    try testing.expectEqual(c.SIG.TERM, c.W.TERMSIG(@bitCast(status)));
}
