//! `maru attach`가 discovery 전에 적용하는 interactive TTY identity gate.
//! Raw mode나 fd status flag를 바꾸지 않으며 stdin/stdout이 같은 slave device라는 증거만 반환한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn openpty(
    amaster: *c.fd_t,
    aslave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;

pub const Error = error{
    NotATerminal,
    DifferentTerminal,
    StatFailed,
};

pub const Identity = struct {
    device: c.dev_t,
};

pub fn validate(stdin_fd: c.fd_t, stdout_fd: c.fd_t) Error!Identity {
    if (c.isatty(stdin_fd) != 1 or c.isatty(stdout_fd) != 1)
        return error.NotATerminal;
    var stdin_stat: c.Stat = undefined;
    var stdout_stat: c.Stat = undefined;
    if (c.fstat(stdin_fd, &stdin_stat) != 0 or c.fstat(stdout_fd, &stdout_stat) != 0)
        return error.StatFailed;
    if ((stdin_stat.mode & posix.S.IFMT) != posix.S.IFCHR or
        (stdout_stat.mode & posix.S.IFMT) != posix.S.IFCHR)
        return error.NotATerminal;
    if (stdin_stat.rdev != stdout_stat.rdev)
        return error.DifferentTerminal;
    return .{ .device = stdin_stat.rdev };
}

test "attach TTY gate accepts the same PTY slave without mutating fd flags" {
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = c.fcntl(slave, c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(before >= 0);
    const identity = try validate(slave, slave);
    try std.testing.expect(identity.device != 0);
    try std.testing.expectEqual(before, c.fcntl(slave, c.F.GETFL, @as(c_int, 0)));
}

test "attach TTY gate rejects one-sided non-TTY and different slaves" {
    var first_master: c.fd_t = -1;
    var first_slave: c.fd_t = -1;
    var second_master: c.fd_t = -1;
    var second_slave: c.fd_t = -1;
    try std.testing.expectEqual(
        @as(c_int, 0),
        openpty(&first_master, &first_slave, null, null, null),
    );
    defer _ = c.close(first_master);
    defer _ = c.close(first_slave);
    try std.testing.expectEqual(
        @as(c_int, 0),
        openpty(&second_master, &second_slave, null, null, null),
    );
    defer _ = c.close(second_master);
    defer _ = c.close(second_slave);

    var pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&pipe));
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try std.testing.expectError(error.NotATerminal, validate(first_slave, pipe[1]));
    try std.testing.expectError(error.NotATerminal, validate(pipe[0], first_slave));
    try std.testing.expectError(
        error.DifferentTerminal,
        validate(first_slave, second_slave),
    );
}
