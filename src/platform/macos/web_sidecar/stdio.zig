//! sidecar 의 표준 입출력을 프로토콜 전용으로 떼어 낸다(W1b, docs/plans/web-osr-backend.md C2).
//!
//! maru 는 sidecar 의 stdin 으로 명령을, stdout 으로 알림을 받는다. 그런데 Chromium·helper 가 stdout 에 무엇을 찍으면
//! frame 이 깨진다. 그래서 시작하자마자 원래 두 fd 를 CLOEXEC 사본으로 옮기고(helper 에게 새지 않게), fd 0 은
//! `/dev/null`, fd 1 은 stderr 로 돌린다. 이후 frame 은 돌려받은 두 fd 로만 오간다.

const std = @import("std");

pub const Channels = struct {
    /// maru → sidecar 명령(원래 stdin).
    commands: c_int,
    /// sidecar → maru 알림(원래 stdout).
    events: c_int,
};

pub const Error = error{StdioUnavailable};

const SIGPIPE: c_int = 13;
const SIG_IGN: usize = 1;
extern "c" fn signal(sig: c_int, handler: usize) usize;

pub fn take() Error!Channels {
    // maru 가 먼저 사라져 알림을 쓸 곳이 닫혀도 프로세스가 신호로 죽지 않고 쓰기 오류로 알게 한다.
    _ = signal(SIGPIPE, SIG_IGN);
    // stderr 가 닫힌 채 띄워지면 아래 dup2 가 실패해 시작을 못 했다(적대 검증) — 비어 있는 0~2 는 /dev/null 로 채운다.
    // stdin·stdout 이 닫혀 있다면 채널이 없는 것이라 아래 cloexecCopy 가 실패로 알린다.
    fillClosedWithNull(2);
    const commands = try cloexecCopy(0);
    const events = try cloexecCopy(1);
    // stdout 과 stderr 가 같은 대상(같은 pipe)이면 fd 1 을 stderr 로 돌려도 여전히 프로토콜 채널이다 — 그때는 둘 다
    // /dev/null 로 돌린다(helper 가 물려받는 stderr 도 채널이 아니게).
    const same_target = sameFile(1, 2);
    try redirectToNull(0, .RDONLY);
    if (same_target) {
        try redirectToNull(1, .WRONLY);
        try redirectToNull(2, .WRONLY);
    } else if (std.c.dup2(2, 1) < 0) return error.StdioUnavailable;
    closeInherited(commands, events);
    return .{ .commands = commands, .events = events };
}

fn fillClosedWithNull(fd: c_int) void {
    if (std.c.fcntl(fd, std.c.F.GETFD) >= 0) return;
    const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (null_fd >= 0 and null_fd != fd) {
        _ = std.c.dup2(null_fd, fd);
        _ = std.c.close(null_fd);
    }
}

fn redirectToNull(fd: c_int, mode: std.posix.ACCMODE) Error!void {
    const null_fd = std.c.open("/dev/null", .{ .ACCMODE = mode });
    if (null_fd < 0) return error.StdioUnavailable;
    defer if (null_fd != fd) {
        _ = std.c.close(null_fd);
    };
    if (null_fd != fd and std.c.dup2(null_fd, fd) < 0) return error.StdioUnavailable;
}

fn sameFile(a: c_int, b: c_int) bool {
    var sa: std.c.Stat = undefined;
    var sb: std.c.Stat = undefined;
    if (std.c.fstat(a, &sa) != 0 or std.c.fstat(b, &sb) != 0) return false;
    return sa.dev == sb.dev and sa.ino == sb.ino;
}

/// maru 에서 새어 들어온 fd(PTY master 등)를 쥐지 않는다 — 쥐고 있으면 maru 쪽 자원이 sidecar 수명만큼 산다.
fn closeInherited(keep_a: c_int, keep_b: c_int) void {
    var fd: c_int = 3;
    while (fd < 256) : (fd += 1) {
        if (fd != keep_a and fd != keep_b) _ = std.c.close(fd);
    }
}

fn cloexecCopy(fd: c_int) Error!c_int {
    const copy = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (copy < 0) return error.StdioUnavailable;
    return copy;
}
