//! macOS 외부 관측 명령의 단일 bounded process 실행 경계.
//!
//! Release adapter와 upgrade codesign은 같은 fork/exec, bounded capture, monotonic deadline,
//! process-group kill 규율을 공유한다. 성공은 exact exit 0과 pipe EOF를 모두 관측한 뒤에만 반환한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;

const poll_quantum_ms: c_int = 50;
const CaptureMode = enum { merged, stdout_only };

pub const Error = error{
    InvalidExecutable,
    InvalidDirectoryFd,
    InvalidInputFd,
    InvalidExpectedSize,
    InvalidBudget,
    PipeFailed,
    SpawnSetupFailed,
    SpawnFailed,
    ProcessGroupFailed,
    CaptureFailed,
    OutputTooLarge,
    TimedOut,
    WaitFailed,
    ChildFailed,
};

pub const Digest = struct { size: u64, sha256: [64]u8 };

pub fn runCapture(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    return runCaptureOptionalEnvironment(io, executable, argv, null, null, null, output, budget_ns, .merged);
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
    return runCaptureOptionalEnvironment(io, executable, argv, environment, null, null, output, budget_ns, .merged);
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
    return runCaptureOptionalEnvironment(io, executable, argv, environment, null, null, output, budget_ns, .stdout_only);
}

/// Runs with exactly `environment`, streams one already-held regular file as stdin, and captures
/// bounded stdout. The child seeks its inherited stdin to byte zero before exec.
pub fn runCaptureEnvironmentStdoutInputFd(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    input_fd: c.fd_t,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    if (!validInputFd(io, input_fd)) return error.InvalidInputFd;
    return runCaptureOptionalEnvironment(io, executable, argv, environment, null, input_fd, output, budget_ns, .stdout_only);
}

/// Runs with exactly `environment` and hashes bounded stdout without retaining its body.
/// `expected_size` is also the hard byte cap, so an oversized remote body stops immediately.
pub fn runDigestEnvironmentStdout(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    expected_size: u64,
    budget_ns: i128,
) Error!Digest {
    if (executable.len < 2 or executable[0] != '/' or std.mem.indexOfScalar(u8, executable, 0) != null)
        return error.InvalidExecutable;
    if (expected_size == 0 or expected_size > std.math.maxInt(usize)) return error.InvalidExpectedSize;
    if (budget_ns <= 0) return error.InvalidBudget;

    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    if (!setCloseOnExec(pipe_fds[0]) or !setCloseOnExec(pipe_fds[1])) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.PipeFailed;
    }
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (dev_null < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.SpawnSetupFailed;
    }
    const pid = spawnChild(executable, argv, environment, null, null, pipe_fds, dev_null, .stdout_only) catch |err| {
        _ = c.close(dev_null);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return err;
    };
    _ = c.close(dev_null);
    _ = c.close(pipe_fds[1]);
    if (!establishProcessGroup(pid)) {
        terminateGroup(pid);
        _ = reapChild(pid, null);
        _ = c.close(pipe_fds[0]);
        return error.ProcessGroupFailed;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var used: u64 = 0;
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
        var fds = [_]c.pollfd{.{ .fd = if (eof) -1 else pipe_fds[0], .events = c.POLL.IN, .revents = 0 }};
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
        var bytes: [64 * 1024]u8 = undefined;
        const remaining = expected_size - used;
        const capacity: usize = if (remaining >= bytes.len) bytes.len else @intCast(remaining + 1);
        const count = c.read(pipe_fds[0], &bytes, capacity);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            failure = error.CaptureFailed;
            break;
        }
        if (count == 0) {
            eof = true;
        } else if (@as(u64, @intCast(count)) > remaining) {
            failure = error.OutputTooLarge;
            break;
        } else {
            const count_usize: usize = @intCast(count);
            hasher.update(bytes[0..count_usize]);
            used += @intCast(count);
        }
    }
    _ = c.close(pipe_fds[0]);
    if (failure != null or !child_reaped) terminateGroup(pid);
    if (!child_reaped and !reapChild(pid, &status)) return error.WaitFailed;
    if (failure) |err| return err;
    const unsigned_status: u32 = @bitCast(status);
    if (!eof or !c.W.IFEXITED(unsigned_status) or c.W.EXITSTATUS(unsigned_status) != 0) return error.ChildFailed;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .size = used, .sha256 = std.fmt.bytesToHex(digest, .lower) };
}

/// Runs with exactly `environment` and binds one held directory fd as the child cwd.
pub fn runCaptureEnvironmentStdoutDirectory(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    directory_fd: c.fd_t,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    if (!validDirectoryFd(directory_fd)) return error.InvalidDirectoryFd;
    return runCaptureOptionalEnvironment(io, executable, argv, environment, directory_fd, null, output, budget_ns, .stdout_only);
}

/// Executes one exact `./leaf` below a held directory vnode. The fork child performs only
/// async-signal-safe descriptor/process operations before execve.
pub fn runCaptureEnvironmentStdoutHeldExecutable(
    io: std.Io,
    relative_executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    directory_fd: c.fd_t,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    if (!validHeldExecutable(relative_executable)) return error.InvalidExecutable;
    if (!validDirectoryFd(directory_fd)) return error.InvalidDirectoryFd;
    return runCaptureOptionalEnvironmentHeld(io, relative_executable, argv, environment, directory_fd, output, budget_ns);
}

fn runCaptureOptionalEnvironmentHeld(
    io: std.Io,
    relative_executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    directory_fd: c.fd_t,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    return runCaptureCommon(io, relative_executable, argv, environment, directory_fd, null, output, budget_ns, .stdout_only);
}

fn runCaptureOptionalEnvironment(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    output: []u8,
    budget_ns: i128,
    capture_mode: CaptureMode,
) Error![]const u8 {
    if (executable.len < 2 or executable[0] != '/' or
        std.mem.indexOfScalar(u8, executable, 0) != null) return error.InvalidExecutable;
    return runCaptureCommon(io, executable, argv, environment, directory_fd, input_fd, output, budget_ns, capture_mode);
}

fn runCaptureCommon(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    output: []u8,
    budget_ns: i128,
    capture_mode: CaptureMode,
) Error![]const u8 {
    if (budget_ns <= 0 or output.len == 0) return error.InvalidBudget;
    if (directory_fd) |fd| if (!validDirectoryFd(fd)) return error.InvalidDirectoryFd;
    if (input_fd) |fd| if (!validInputFd(io, fd)) return error.InvalidInputFd;
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    if (!setCloseOnExec(pipe_fds[0]) or !setCloseOnExec(pipe_fds[1])) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.PipeFailed;
    }

    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (dev_null < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.SpawnSetupFailed;
    }
    const pid = spawnChild(executable, argv, environment, directory_fd, input_fd, pipe_fds, dev_null, capture_mode) catch |err| {
        _ = c.close(dev_null);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return err;
    };

    _ = c.close(dev_null);
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

fn spawnChild(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    pipe_fds: [2]c.fd_t,
    dev_null: c.fd_t,
    capture_mode: CaptureMode,
) Error!c.pid_t {
    const max_fd = getdtablesize();
    if (max_fd <= 3) return error.SpawnSetupFailed;
    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) childExec(executable, argv, environment, directory_fd, input_fd, pipe_fds, dev_null, capture_mode, max_fd);
    return pid;
}

fn childExec(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    pipe_fds: [2]c.fd_t,
    dev_null: c.fd_t,
    capture_mode: CaptureMode,
    max_fd: c_int,
) noreturn {
    const stdin_fd = input_fd orelse dev_null;
    if (c.setpgid(0, 0) != 0 or c.dup2(stdin_fd, 0) < 0 or
        c.dup2(pipe_fds[1], 1) < 0 or
        c.dup2(if (capture_mode == .merged) pipe_fds[1] else dev_null, 2) < 0) c._exit(126);
    if (input_fd != null and c.lseek(0, 0, c.SEEK.SET) < 0) c._exit(126);
    if (directory_fd) |fd| if (c.fchdir(fd) != 0) c._exit(126);
    var inherited_fd: c_int = 3;
    while (inherited_fd < max_fd) : (inherited_fd += 1) _ = c.close(inherited_fd);
    if (environment) |envp| {
        _ = execve(executable.ptr, argv, envp);
    } else {
        _ = execv(executable.ptr, argv);
    }
    c._exit(126);
}

/// What the parent should do after `setpgid` on the freshly forked child failed.
pub const GroupOutcome = enum { established, retry, failed };

/// The child sets its own group before exec, so two errno values still mean the
/// group is in place and only the parent's redundant call lost a race:
///   ACCES  the child reached exec first;
///   SRCH   the child already exited, so nothing is left to place in a group.
/// Treating SRCH as failure replaces the child's real exit status with
/// ProcessGroupFailed. How often that happens is decided by `RLIMIT_NOFILE`:
/// `childExec` below closes every descriptor up to `getdtablesize()` before exec,
/// so a high limit buys the parent enough time to always win, and a low one does
/// not. Measured on macOS with an exec that fails into `_exit(126)`, 300 spawns
/// each:
///   ulimit -n 1048576 / 65536 / 4096   0 ProcessGroupFailed
///   ulimit -n 256                      7 ProcessGroupFailed
///   ulimit -n 64                       8 ProcessGroupFailed
/// 256 is not a corner: it is what `launchctl limit maxfiles` reports, so it is
/// the soft limit the GUI app inherits. Tests run from a shell whose limit is
/// 1048576, which is why the harness never saw this.
pub fn classifyGroupErrno(err: posix.E) GroupOutcome {
    return switch (err) {
        .INTR => .retry,
        .ACCES, .SRCH => .established,
        else => .failed,
    };
}

fn establishProcessGroup(pid: c.pid_t) bool {
    while (true) {
        if (c.setpgid(pid, pid) == 0) return true;
        switch (classifyGroupErrno(posix.errno(-1))) {
            .retry => continue,
            .established => return true,
            .failed => return false,
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

fn validDirectoryFd(fd: c.fd_t) bool {
    if (fd < 3 or c.fcntl(fd, c.F.GETFD, @as(c_int, 0)) < 0) return false;
    // Opening `.` relative to the held fd proves directory capability without
    // mutating process cwd. This also avoids Zig 0.16's target-specific `Stat`
    // declaration while preserving the same fail-closed check on Darwin/Linux.
    const probe = c.openat(fd, ".", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, @as(c.mode_t, 0));
    if (probe < 0) return false;
    return c.close(probe) == 0;
}

fn validInputFd(io: std.Io, fd: c.fd_t) bool {
    if (fd < 3 or c.fcntl(fd, c.F.GETFD, @as(c_int, 0)) < 0) return false;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return false;
    return stat.kind == .file;
}

fn validHeldExecutable(executable: [:0]const u8) bool {
    if (!std.mem.startsWith(u8, executable, "./") or executable.len <= 2) return false;
    const leaf = executable[2..];
    return !std.mem.eql(u8, leaf, ".") and !std.mem.eql(u8, leaf, "..") and
        std.mem.indexOfScalar(u8, leaf, '/') == null and std.mem.indexOfScalar(u8, executable, 0) == null;
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
