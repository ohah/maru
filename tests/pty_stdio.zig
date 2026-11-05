//! Real PTY descriptor layouts, including daemon launches with missing stdio.
//! The C oracle runs before a shell can repair descriptor or terminal state.
const std = @import("std");
const c = std.c;
const t = std.testing;
const Pty = @import("maru").pty.PtySession;
extern "c" fn pthread_atfork(?*const fn () callconv(.c) void, ?*const fn () callconv(.c) void, ?*const fn () callconv(.c) void) c_int;

fn countFds() usize {
    var n: usize = 0;
    for (0..512) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) >= 0) {
        n += 1;
    };
    return n;
}
fn probe(buf: *[4096]u8) ![:0]const u8 {
    const n = try std.Io.Dir.cwd().realPathFile(t.io, @import("pty_stdio_probe").path, buf[0..4095]);
    buf[n] = 0;
    return buf[0..n :0];
}
const Stdio = struct {
    saved: [3]c.fd_t = @splat(-1),
    flags: [3]c_int = @splat(0),
    fn init(closed: u3, cloexec: u3) !Stdio {
        var self: Stdio = .{};
        errdefer self.deinit();
        for (0..3) |i| if ((closed | cloexec) & (@as(u3, 1) << @intCast(i)) != 0) {
            self.flags[i] = c.fcntl(@intCast(i), c.F.GETFD);
            self.saved[i] = c.fcntl(@intCast(i), c.F.DUPFD_CLOEXEC, @as(c_int, 64));
            if (self.saved[i] < 0) return error.StdioBackupFailed;
        };
        for (0..3) |i| {
            const bit = @as(u3, 1) << @intCast(i);
            if (closed & bit != 0) _ = c.close(@intCast(i)) else if (cloexec & bit != 0)
                if (c.fcntl(@intCast(i), c.F.SETFD, self.flags[i] | c.FD_CLOEXEC) < 0) return error.StdioFlagsFailed;
        }
        return self;
    }
    fn deinit(self: *Stdio) void {
        for (&self.saved, 0..) |*fd, i| if (fd.* >= 0) {
            _ = c.dup2(fd.*, @intCast(i));
            _ = c.fcntl(@intCast(i), c.F.SETFD, self.flags[i]);
            _ = c.close(fd.*);
            fd.* = -1;
        };
    }
};
const Case = struct {
    closed: u3 = 0,
    cloexec: u3 = 0,
    mode: []const u8 = "report",
    cwd: ?[]const u8 = null,
    env: []const []const u8 = &.{"TERM=xterm-256color"},
    expected: ?[]const u8 = null,
    code: u8 = 0,
};
fn exerciseInner(case: Case, exe: []const u8) !c.pid_t {
    var stdio = try Stdio.init(case.closed, case.cloexec);
    defer stdio.deinit();
    var session = try Pty.spawn(t.allocator, .{ .command = exe, .args = &.{ case.mode, "argument with spaces" }, .cwd = case.cwd, .env = case.env, .size = .{ .cols = 91, .rows = 27 }, .cell_width_px = 9, .cell_height_px = 17 });
    defer session.deinit();
    if (std.mem.eql(u8, case.mode, "read")) try session.writeInput("maru\n");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(t.allocator);
    var buf: [4096]u8 = undefined;
    var done = false;
    for (0..5000) |_| {
        switch (try session.readChunk(&buf)) {
            .data => |n| {
                try output.appendSlice(t.allocator, buf[0..n]);
            },
            .again => {},
            .eof => if (try session.reapIfExited()) |status| {
                try t.expectEqual(@import("maru").pty.ExitStatus{ .exited = case.code }, status);
                done = true;
                break;
            },
        }
        var delay: c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(@ptrCast(&delay), 0, 2);
    }
    if (!done) return error.CollectionDeadline;
    if (std.mem.eql(u8, case.mode, "report")) {
        for ([_][]const u8{ "tty:111 sid:1 group:1 foreground:1", "size:91x27 px:819x459", "COUT", "CERR", "arg:argument with spaces" }) |expected|
            try t.expect(std.mem.indexOf(u8, output.items, expected) != null);
    } else if (std.mem.eql(u8, case.mode, "read")) try t.expect(std.mem.indexOf(u8, output.items, "read:maru") != null);
    if (case.expected) |expected| try t.expect(std.mem.indexOf(u8, output.items, expected) != null);
    return session.child_pid;
}
fn exercise(case: Case) !void {
    var path_buf: [4096]u8 = undefined;
    const exe = try probe(&path_buf);
    const before = countFds();
    const pid = try exerciseInner(case, exe);
    try t.expectEqual(before, countFds());
    var status: c_int = 0;
    try t.expect(c.waitpid(pid, &status, c.W.NOHANG) < 0);
    try t.expectEqual(std.posix.E.CHILD, std.posix.errno(@as(c_int, -1)));
}

test "PTS01 ordinary PTY session group foreground stdio and cleanup" {
    try exercise(.{});
}
test "PTS02 closed stdin does not turn child stdin into a closed master" {
    try exercise(.{ .closed = 1 });
}
test "PTS03 closed stdout retains terminal output" {
    try exercise(.{ .closed = 2 });
}
test "PTS04 closed stderr retains terminal error output" {
    try exercise(.{ .closed = 4 });
}
test "PTS05 closed stdin and stdout preserve slave source" {
    try exercise(.{ .closed = 3 });
}
test "PTS06 closed stdin and stderr preserve slave source" {
    try exercise(.{ .closed = 5 });
}
test "PTS07 closed stdout and stderr preserve source and master ownership" {
    try exercise(.{ .closed = 6 });
}
test "PTS08 all closed stdio retain a controlling terminal" {
    try exercise(.{ .closed = 7 });
}
test "PTS09 parent stdin CLOEXEC does not reach child stdin" {
    try exercise(.{ .cloexec = 1 });
}
test "PTS10 parent stdout CLOEXEC does not reach child stdout" {
    try exercise(.{ .cloexec = 2 });
}
test "PTS11 parent stderr CLOEXEC does not reach child stderr" {
    try exercise(.{ .cloexec = 4 });
}
test "PTS12 input works with closed stdin and stdout" {
    try exercise(.{ .closed = 3, .mode = "read" });
}
test "PTS13 input works with closed stdout and stderr" {
    try exercise(.{ .closed = 6, .mode = "read" });
}
test "PTS14 closed stdin and CLOEXEC outputs preserve terminal size" {
    try exercise(.{ .closed = 1, .cloexec = 6 });
}
test "PTS15 all closed stdio preserve explicit cwd environment and argv" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    const expected = try std.fmt.allocPrint(t.allocator, "cwd:{s} env:kept", .{root});
    defer t.allocator.free(expected);
    try exercise(.{ .closed = 7, .cwd = root, .env = &.{ "TERM=xterm-256color", "PTY_PROBE=kept" }, .expected = expected });
}
test "PTS16 missing cwd retains HOME fallback with closed stdio" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    const home = try std.fmt.allocPrint(t.allocator, "HOME={s}", .{root});
    defer t.allocator.free(home);
    const expected = try std.fmt.allocPrint(t.allocator, "cwd:{s}", .{root});
    defer t.allocator.free(expected);
    try exercise(.{ .closed = 7, .cwd = "/nonexistent-maru-pty-stdio", .env = &.{ "TERM=xterm-256color", home }, .expected = expected });
}
test "PTS17 missing cwd without HOME preserves inherited cwd" {
    var buf: [4096]u8 = undefined;
    const root = buf[0..try std.Io.Dir.cwd().realPath(t.io, &buf)];
    const expected = try std.fmt.allocPrint(t.allocator, "cwd:{s}", .{root});
    defer t.allocator.free(expected);
    try exercise(.{ .closed = 1, .cwd = "/nonexistent-maru-pty-stdio", .expected = expected });
}
test "PTS18 real nonzero status remains observable with closed stdout" {
    try exercise(.{ .closed = 2, .mode = "exit", .code = 42 });
}
const ForkProbe = struct {
    var installed = false;
    var active = false;
    var before: [512]bool = @splat(false);
    var missing: usize = 0;
    var added: usize = 0;
    fn prepare() callconv(.c) void {
        if (!active) return;
        for (before, 0..) |existed, i| {
            const flags = c.fcntl(@intCast(i), c.F.GETFD);
            if (!existed and flags >= 0) {
                added += 1;
                if (flags & c.FD_CLOEXEC == 0) missing += 1;
            }
        }
    }
};
test "PTS19 both PTY endpoints and wake pipe are CLOEXEC at the fork boundary" {
    if (!ForkProbe.installed) {
        try t.expectEqual(@as(c_int, 0), pthread_atfork(ForkProbe.prepare, null, null));
        ForkProbe.installed = true;
    }
    for (&ForkProbe.before, 0..) |*open, i| open.* = c.fcntl(@intCast(i), c.F.GETFD) >= 0;
    ForkProbe.missing = 0;
    ForkProbe.added = 0;
    ForkProbe.active = true;
    defer ForkProbe.active = false;
    try exercise(.{});
    try t.expectEqual(@as(usize, 4), ForkProbe.added);
    try t.expectEqual(@as(usize, 0), ForkProbe.missing);
}
test "PTS20 partial low-fd promotion failure revokes every PTY endpoint" {
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 128, .max = saved.max });
    defer std.posix.setrlimit(.NOFILE, saved) catch {};
    var stdio = try Stdio.init(3, 0);
    defer stdio.deinit();
    var held: [128]c.fd_t = undefined;
    var n: usize = 0;
    defer for (held[0..n]) |fd| {
        _ = c.close(fd);
    };
    while (n < held.len) {
        const fd = c.fcntl(2, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (fd < 0) break;
        held[n] = fd;
        n += 1;
    }
    try t.expect(n > 2);
    n -= 1;
    _ = c.close(held[n]); // One high slot: first promotion succeeds, second must unwind.
    const before = countFds();
    if (Pty.spawn(t.allocator, .{ .command = "/usr/bin/true", .size = .{ .cols = 80, .rows = 24 } })) |value| {
        var session = value;
        session.deinit();
        return error.ExpectedResourceFailure;
    } else |_| {}
    try t.expectEqual(before, countFds());
}
