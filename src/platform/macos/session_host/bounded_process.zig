//! macOS 외부 관측 명령의 단일 bounded process 실행 경계.
//!
//! Release adapter와 upgrade codesign은 같은 fork/exec, bounded capture, monotonic deadline,
//! process-group kill 규율을 공유한다. 성공은 exact exit 0과 pipe EOF를 모두 관측한 뒤에만 반환한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

const poll_quantum_ms: c_int = 50;
const CaptureMode = enum { merged, stdout_only };

pub const Error = error{
    InvalidExecutable,
    InvalidBudget,
    PipeFailed,
    ForkFailed,
    ProcessGroupFailed,
    CaptureFailed,
    OutputTooLarge,
    TimedOut,
    WaitFailed,
    ChildFailed,
};

pub fn runCapture(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    return runCaptureOptionalEnvironment(io, executable, argv, null, output, budget_ns, .merged);
}

/// Runs with exactly `environment`; no parent variable survives into the child.
pub fn runCaptureEnvironment(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    return runCaptureOptionalEnvironment(io, executable, argv, environment, output, budget_ns, .merged);
}

/// Runs with exactly `environment`, captures bounded stdout, and sends stderr to `/dev/null`.
pub fn runCaptureEnvironmentStdout(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    return runCaptureOptionalEnvironment(io, executable, argv, environment, output, budget_ns, .stdout_only);
}

fn runCaptureOptionalEnvironment(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    output: []u8,
    budget_ns: i128,
    capture_mode: CaptureMode,
) Error![]const u8 {
    if (executable.len < 2 or executable[0] != '/' or
        std.mem.indexOfScalar(u8, executable, 0) != null) return error.InvalidExecutable;
    if (budget_ns <= 0 or output.len == 0) return error.InvalidBudget;
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    if (!setCloseOnExec(pipe_fds[0]) or !setCloseOnExec(pipe_fds[1])) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.PipeFailed;
    }

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.ForkFailed;
    }
    if (pid == 0) childExec(executable, argv, environment, pipe_fds, capture_mode);

    _ = c.close(pipe_fds[1]);
    if (!establishProcessGroup(pid)) {
        terminateGroup(pid);
        _ = reapChild(pid, null);
        _ = c.close(pipe_fds[0]);
        return error.ProcessGroupFailed;
    }

    var used: usize = 0;
    var eof = false;
    var child_reaped = false;
    var status: c_int = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const deadline = std.math.add(i128, start, budget_ns) catch std.math.maxInt(i128);
    var failure: ?Error = null;

    while (!(eof and child_reaped)) {
        if (!child_reaped) switch (pollChild(pid, &status)) {
            .running => {},
            .reaped => child_reaped = true,
            .failed => {
                failure = error.WaitFailed;
                break;
            },
        };
        if (eof and child_reaped) break;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (now >= deadline) {
            failure = error.TimedOut;
            break;
        }
        const remaining_ms = @divTrunc(deadline - now + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        const wait_ms: c_int = @intCast(@min(remaining_ms, poll_quantum_ms));
        var fds = [_]c.pollfd{.{
            .fd = if (eof) -1 else pipe_fds[0],
            .events = c.POLL.IN,
            .revents = 0,
        }};
        const rc = c.poll(&fds, if (eof) 0 else 1, wait_ms);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            failure = error.CaptureFailed;
            break;
        }
        if (rc == 0 or eof) continue;
        if (fds[0].revents & (c.POLL.ERR | c.POLL.NVAL) != 0) {
            failure = error.CaptureFailed;
            break;
        }
        if (fds[0].revents & (c.POLL.IN | c.POLL.HUP) == 0) continue;

        var overflow: [1]u8 = undefined;
        const destination = if (used == output.len) overflow[0..] else output[used..];
        const count = c.read(pipe_fds[0], destination.ptr, destination.len);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            failure = error.CaptureFailed;
            break;
        }
        if (count == 0) {
            eof = true;
        } else if (used == output.len) {
            failure = error.OutputTooLarge;
            break;
        } else {
            used += @intCast(count);
        }
    }

    _ = c.close(pipe_fds[0]);
    if (failure != null or !child_reaped) terminateGroup(pid);
    if (!child_reaped and !reapChild(pid, &status)) return error.WaitFailed;
    if (failure) |err| return err;
    const unsigned_status: u32 = @bitCast(status);
    if (!eof or !c.W.IFEXITED(unsigned_status) or c.W.EXITSTATUS(unsigned_status) != 0)
        return error.ChildFailed;
    return output[0..used];
}

fn childExec(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    pipe_fds: [2]c.fd_t,
    capture_mode: CaptureMode,
) noreturn {
    if (c.setpgid(0, 0) != 0) c._exit(126);
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (dev_null < 0 or c.dup2(dev_null, 0) < 0 or
        c.dup2(pipe_fds[1], 1) < 0 or
        c.dup2(if (capture_mode == .merged) pipe_fds[1] else dev_null, 2) < 0) c._exit(126);
    _ = c.close(dev_null);
    _ = c.close(pipe_fds[0]);
    _ = c.close(pipe_fds[1]);
    if (environment) |envp| {
        _ = execve(executable.ptr, argv, envp);
    } else {
        _ = execv(executable.ptr, argv);
    }
    c._exit(126);
}

fn establishProcessGroup(pid: c.pid_t) bool {
    while (true) {
        if (c.setpgid(pid, pid) == 0) return true;
        switch (posix.errno(-1)) {
            .INTR => continue,
            // The child can win the race by setting its group and entering exec first.
            .ACCES => return true,
            else => return false,
        }
    }
}

fn terminateGroup(pid: c.pid_t) void {
    _ = c.kill(-pid, c.SIG.KILL);
    _ = c.kill(pid, c.SIG.KILL);
}

fn setCloseOnExec(fd: c.fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    return flags >= 0 and c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) == 0;
}

const ChildPoll = enum { running, reaped, failed };

fn pollChild(pid: c.pid_t, status: *c_int) ChildPoll {
    while (true) {
        const rc = c.waitpid(pid, status, c.W.NOHANG);
        if (rc == pid) return .reaped;
        if (rc == 0) return .running;
        if (posix.errno(rc) != .INTR) return .failed;
    }
}

fn reapChild(pid: c.pid_t, status: ?*c_int) bool {
    var discarded: c_int = 0;
    const destination = status orelse &discarded;
    while (true) {
        const rc = c.waitpid(pid, destination, 0);
        if (rc == pid) return true;
        if (rc >= 0 or posix.errno(rc) != .INTR) return false;
    }
}
