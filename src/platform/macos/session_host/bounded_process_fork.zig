//! Legacy POSIX test-host backend. Darwin product creation uses macos_spawn instead.
//! Release-adapter integration also executes on Linux; retain its existing fork/exec
//! and redundant-group-call semantics without analyzing Darwin-only spawn actions.
const std = @import("std");
const c = std.c;
const posix = std.posix;
const Error = error{ SpawnSetupFailed, SpawnFailed };
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;

pub fn spawnCapture(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    pipe_fds: [2]c.fd_t,
    stderr_pipe_fds: ?[2]c.fd_t,
    dev_null: c.fd_t,
    merged: bool,
) Error!c.pid_t {
    const max_fd = getdtablesize();
    if (max_fd <= 3) return error.SpawnSetupFailed;
    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) childExec(executable, argv, environment, directory_fd, input_fd, pipe_fds, stderr_pipe_fds, dev_null, merged, max_fd);
    return pid;
}

pub fn spawnInherited(executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8, environment: [*:null]const ?[*:0]const u8, descriptors: [2]c.fd_t, dev_null: c.fd_t) Error!c.pid_t {
    const max_fd = getdtablesize();
    if (max_fd <= 4) return error.SpawnSetupFailed;
    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) childExecInheritedPipe(executable, argv, environment, descriptors, dev_null, max_fd);
    return pid;
}

fn childExec(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    pipe_fds: [2]c.fd_t,
    stderr_pipe_fds: ?[2]c.fd_t,
    dev_null: c.fd_t,
    merged: bool,
    max_fd: c_int,
) noreturn {
    const stdin_fd = input_fd orelse dev_null;
    if (c.setpgid(0, 0) != 0 or c.dup2(stdin_fd, 0) < 0 or
        c.dup2(pipe_fds[1], 1) < 0 or
        c.dup2(if (stderr_pipe_fds) |fds| fds[1] else if (merged) pipe_fds[1] else dev_null, 2) < 0) c._exit(126);
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

fn childExecInheritedPipe(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    receipt_pipe: [2]c.fd_t,
    dev_null: c.fd_t,
    max_fd: c_int,
) noreturn {
    const receipt_fd: c.fd_t = 3;
    if (c.setpgid(0, 0) != 0 or
        c.dup2(dev_null, 0) < 0 or c.dup2(dev_null, 1) < 0 or c.dup2(dev_null, 2) < 0 or
        c.dup2(receipt_pipe[1], receipt_fd) < 0 or
        c.fcntl(receipt_fd, c.F.SETFD, @as(c_int, 0)) != 0) c._exit(126);
    var inherited_fd: c_int = 4;
    while (inherited_fd < max_fd) : (inherited_fd += 1) _ = c.close(inherited_fd);
    _ = execve(executable.ptr, argv, environment);
    c._exit(126);
}

/// Preserve Linux's existing handling of the redundant parent group call:
/// exec won (ACCES) or the child has already exited (SRCH) still retains its status.
pub fn establishGroup(pid: c.pid_t) bool {
    while (true) {
        if (c.setpgid(pid, pid) == 0) return true;
        switch (posix.errno(-1)) {
            .INTR => continue,
            .ACCES, .SRCH => return true,
            else => return false,
        }
    }
}
