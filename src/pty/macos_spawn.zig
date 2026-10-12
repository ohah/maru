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

/// `path` 를 `argv`·`envp` 로 띄운다. fd 는 `stdio` 가 정한 0·1·2 만 넘긴다.
pub fn spawn(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    stdio: Stdio,
) SpawnError!c.pid_t {
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawnattr_destroy(&attr);
    if (c.posix_spawnattr_setflags(&attr, .{ .CLOEXEC_DEFAULT = true }) != 0) return error.SpawnFailed;
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    for ([_]c.fd_t{ 0, 1, 2 }) |fd| {
        // 닫힌 stdio 를 넘기라고 하면 spawn 이 EBADF 로 실패한다 — `system()` 처럼 띄우려면 그 자리는 `/dev/null` 로 채운다.
        const inherit = stdio == .inherit and c.fcntl(fd, c.F.GETFD) != -1;
        if (inherit) {
            if (c.posix_spawn_file_actions_addinherit_np(&actions, fd) != 0) return error.SpawnFailed;
        } else {
            const flags: c_int = if (fd == 0) 0 else 1; // O_RDONLY · O_WRONLY
            if (c.posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", flags, 0) != 0) return error.SpawnFailed;
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
        if (rc == -1 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
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
    const probe = try std.fmt.bufPrintZ(&command_buf, "[ -e /dev/fd/{d} ] && exit 7; exit 3", .{fds[0]});
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
