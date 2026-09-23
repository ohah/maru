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
    const commands = try cloexecCopy(0);
    const events = try cloexecCopy(1);
    const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (null_fd < 0) return error.StdioUnavailable;
    if (std.c.dup2(null_fd, 0) < 0) return error.StdioUnavailable;
    _ = std.c.close(null_fd);
    if (std.c.dup2(2, 1) < 0) return error.StdioUnavailable;
    return .{ .commands = commands, .events = events };
}

fn cloexecCopy(fd: c_int) Error!c_int {
    const copy = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (copy < 0) return error.StdioUnavailable;
    return copy;
}
