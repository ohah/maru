//! Real PTY descriptor layouts, including daemon launches with missing stdio.
//! The C oracle runs before a shell can repair descriptor or terminal state.
const std = @import("std");
const c = std.c;
const t = std.testing;
const Pty = @import("maru").pty.PtySession;
extern "c" fn pause() c_int;
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
    // A test runner may have inherited its own descriptors. Detect newly leaked
    // PTY/status FDs without pretending to repair that pre-existing environment.
    var allowed_buf: [2048]u8 = undefined;
    var used: usize = 0;
    for (3..256) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) >= 0) {
        const part = try std.fmt.bufPrint(allowed_buf[used..], "{d},", .{fd});
        used += part.len;
    };
    const allowed = try std.fmt.allocPrint(t.allocator, "PTY_ALLOWED_FDS={s}", .{allowed_buf[0..used]});
    defer t.allocator.free(allowed);
    const env = try t.allocator.alloc([]const u8, case.env.len + 1);
    defer t.allocator.free(env);
    @memcpy(env[0..case.env.len], case.env);
    env[case.env.len] = allowed;
    var session = try Pty.spawn(t.allocator, .{ .command = exe, .args = &.{ case.mode, "argument with spaces" }, .cwd = case.cwd, .env = env, .size = .{ .cols = 91, .rows = 27 }, .cell_width_px = 9, .cell_height_px = 17 });
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
        for ([_][]const u8{ "tty:111 sid:1 group:1 foreground:1", "size:91x27 px:819x459", "COUT", "CERR", "arg:argument with spaces", "unexpected_fds:0" }) |expected|
            if (std.mem.indexOf(u8, output.items, expected) == null) {
                std.debug.print("missing {s}: {s}\n", .{ expected, output.items });
                return error.MissingProbeOutput;
            };
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
    try t.expectEqual(@as(usize, 6), ForkProbe.added);
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

const Status = @import("maru").pty.child_setup_status;
const SetupFault = struct {
    const Kind = enum { none, session, terminal, stdin, stdout, stderr, magic, version, stage, reserved, zero_errno, negative_errno, short, duplicate, fragment, early_zero, hang };
    var installed = false;
    var kind: Kind = .none;
    var before: [512]bool = @splat(false);
    var writer: c.fd_t = -1;
    var slave: c.fd_t = -1;
    var pid_pipe: [2]c.fd_t = .{ -1, -1 };
    fn finish() void {
        kind = .none;
        for (&pid_pipe) |*fd| {
            if (fd.* >= 0) _ = c.close(fd.*);
            fd.* = -1;
        }
    }
    fn reportedPid() !c.pid_t {
        var pid: c.pid_t = 0;
        try t.expectEqual(@as(isize, @sizeOf(c.pid_t)), c.read(pid_pipe[0], @ptrCast(&pid), @sizeOf(c.pid_t)));
        try t.expect(pid > 0);
        return pid;
    }
    fn prepare() callconv(.c) void {
        if (kind == .none) return;
        writer = -1;
        slave = -1;
        for (before, 0..) |open, i| {
            if (open or c.fcntl(@intCast(i), c.F.GETFD) < 0) continue;
            const fd: c.fd_t = @intCast(i);
            const flags = c.fcntl(fd, c.F.GETFL);
            if (flags & 3 == 1) writer = fd; // last new writer is the setup channel
            if (c.isatty(fd) == 1 and flags & @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })) == 0) slave = fd;
        }
    }
    fn child() callconv(.c) void {
        if (kind != .none) {
            var pid = c.getpid();
            _ = c.write(pid_pipe[1], @ptrCast(&pid), @sizeOf(c.pid_t));
            _ = c.close(pid_pipe[0]);
            _ = c.close(pid_pipe[1]);
        }
        switch (kind) {
            .none => return,
            .session => {
                _ = c.setsid();
                return;
            },
            .terminal => {
                _ = c.close(slave);
                return;
            },
            .stdin, .stdout, .stderr => {
                const limit: c.rlimit = .{ .cur = switch (kind) {
                    .stdin => 0,
                    .stdout => 1,
                    else => 2,
                }, .max = 1024 };
                if (c.setrlimit(.NOFILE, &limit) != 0) c._exit(119);
                return;
            },
            .early_zero => c._exit(0),
            .hang => {
                while (true) _ = pause();
            },
            else => {},
        }
        var bytes = Status.encode(.{ .stage = .exec, .native_errno = @backingInt(std.posix.E.NOENT) });
        switch (kind) {
            .magic => bytes[0] = 'X',
            .version => bytes[4] = 2,
            .stage => bytes[5] = 99,
            .reserved => bytes[6] = 1,
            .zero_errno => @memset(bytes[8..12], 0),
            .negative_errno => @memset(bytes[8..12], 255),
            else => {},
        }
        const n: usize = if (kind == .short) 7 else bytes.len;
        if (kind == .fragment) {
            for (bytes) |byte| {
                var b = byte;
                _ = c.write(writer, @ptrCast(&b), 1);
            }
        } else _ = c.write(writer, &bytes, n);
        if (kind == .duplicate) _ = c.write(writer, &bytes, n);
        c._exit(126);
    }
    fn begin(k: Kind) !void {
        if (!installed) {
            try t.expectEqual(@as(c_int, 0), pthread_atfork(prepare, null, child));
            installed = true;
        }
        try t.expectEqual(@as(c_int, 0), c.pipe(&pid_pipe));
        errdefer finish();
        for (pid_pipe) |fd| try t.expect(c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) >= 0);
        const flags = c.fcntl(pid_pipe[0], c.F.GETFL);
        try t.expect(c.fcntl(pid_pipe[0], c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) >= 0);
        for (&before, 0..) |*open, i| open.* = c.fcntl(@intCast(i), c.F.GETFD) >= 0;
        kind = k;
    }
};
fn assertSetupFailure(kind: SetupFault.Kind, expected: anyerror, stage: ?Status.Stage, native: std.posix.E) !void {
    const before = countFds();
    var path: [4096]u8 = undefined;
    const exe = try probe(&path);
    try SetupFault.begin(kind);
    defer SetupFault.finish();
    var failure: ?Pty.SpawnFailure = null;
    if (Pty.spawnReporting(t.allocator, .{ .command = exe, .env = &.{"TERM=xterm-256color"}, .size = .{ .cols = 80, .rows = 24 } }, &failure)) |value| {
        var session = value;
        session.deinit();
        return error.ExpectedSetupFailure;
    } else |err| try t.expectEqual(expected, err);
    const pid = try SetupFault.reportedPid();
    SetupFault.finish();
    var child_status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &child_status, c.W.NOHANG));
    try t.expectEqual(std.posix.E.CHILD, std.posix.errno(@as(c_int, -1)));
    try t.expectEqual(before, countFds());
    try t.expect(SetupFault.writer > 2 and SetupFault.slave > 2);
    if (stage) |s| {
        const f = failure orelse return error.MissingSetupFailure;
        try t.expectEqual(pid, f.child_pid);
        try t.expectEqual(s, f.stage);
        try t.expectEqual(@as(u32, @backingInt(native)), f.native_errno);
        var status: c_int = 0;
        try t.expectEqual(@as(c.pid_t, -1), c.waitpid(f.child_pid, &status, c.W.NOHANG));
        try t.expectEqual(std.posix.E.CHILD, std.posix.errno(@as(c_int, -1)));
        try t.expectEqual(@as(c_int, -1), c.kill(-f.child_pid, @fromBackingInt(@intCast(0))));
    } else try t.expect(failure == null);
}
test "PSE01 actual setsid errno and child reap reach parent" {
    try assertSetupFailure(.session, error.ChildSessionFailed, .session, .PERM);
}
test "PSE02 actual controlling terminal failure retains EBADF" {
    try assertSetupFailure(.terminal, error.ChildTerminalFailed, .terminal, .BADF);
}
test "PSE03 stdin mapping failure retains stage and errno" {
    try assertSetupFailure(.stdin, error.ChildStdioFailed, .stdin, .BADF);
}
test "PSE04 stdout mapping failure retains stage and errno" {
    try assertSetupFailure(.stdout, error.ChildStdioFailed, .stdout, .BADF);
}
test "PSE05 stderr mapping failure retains stage and errno" {
    try assertSetupFailure(.stderr, error.ChildStdioFailed, .stderr, .BADF);
}
test "PSE06 corrupted magic is not a child errno" {
    try assertSetupFailure(.magic, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE07 unknown version is rejected" {
    try assertSetupFailure(.version, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE08 unknown stage is rejected" {
    try assertSetupFailure(.stage, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE09 reserved bytes are rejected" {
    try assertSetupFailure(.reserved, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE10 zero errno is rejected" {
    try assertSetupFailure(.zero_errno, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE11 negative errno is rejected" {
    try assertSetupFailure(.negative_errno, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE12 truncated status is rejected" {
    try assertSetupFailure(.short, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE13 duplicate status is rejected" {
    try assertSetupFailure(.duplicate, error.InvalidChildSetupStatus, null, .SUCCESS);
}
test "PSE14 fragmented status retains exact child failure" {
    try assertSetupFailure(.fragment, error.ChildExecFailed, .exec, .NOENT);
}
test "PSE15 EOF with child zero exit retains exit lifecycle" {
    try SetupFault.begin(.early_zero);
    defer SetupFault.finish();
    try exercise(.{ .mode = "exit-code-zero" });
}
test "PSE16 stalled child is bounded and descriptors are revoked" {
    try assertSetupFailure(.hang, error.ChildSetupTimedOut, null, .SUCCESS);
}
// Unexpected success still owns a live session; revoke it before failing a test.
fn expectSpawnFailure(expected: anyerror, outcome: anytype) !void {
    if (outcome) |value| {
        var session = value;
        session.deinit();
        return error.ExpectedSpawnFailure;
    } else |err| try t.expectEqual(expected, err);
}
fn missingExec(closed: u3) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    const missing = try std.fmt.allocPrint(t.allocator, "{s}/absent executable", .{root});
    defer t.allocator.free(missing);
    const before = countFds();
    var backup = try Stdio.init(closed, 0);
    defer backup.deinit();
    var failure: ?Pty.SpawnFailure = null;
    try expectSpawnFailure(error.ChildExecFailed, Pty.spawnReporting(t.allocator, .{ .command = missing, .env = &.{"TERM=xterm-256color"}, .size = .{ .cols = 80, .rows = 24 } }, &failure));
    const f = failure orelse return error.MissingSetupFailure;
    try t.expectEqual(Status.Stage.exec, f.stage);
    try t.expectEqual(@as(u32, @backingInt(std.posix.E.NOENT)), f.native_errno);
    var status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(f.child_pid, &status, c.W.NOHANG));
    backup.deinit();
    try t.expectEqual(before, countFds());
}
test "PSE17 actual missing executable fails spawn and is reaped" {
    try missingExec(0);
}
test "PSE18 all closed stdio still delivers failure" {
    try missingExec(7);
}
test "PSE19 stdin and stderr closed still delivers failure" {
    try missingExec(5);
}
test "PSE20 stale diagnostics are cleared on validation failure" {
    var failure: ?Pty.SpawnFailure = .{ .stage = .exec, .native_errno = 2, .child_pid = 123 };
    try expectSpawnFailure(error.EmptyCommand, Pty.spawnReporting(t.allocator, .{ .command = "", .size = .{ .cols = 80, .rows = 24 } }, &failure));
    try t.expect(failure == null);
}
test "PSE21 normal target exit 126 remains an exit event" {
    try exercise(.{ .mode = "exit126", .code = 126 });
}
test "PSE22 normal target exit 127 remains an exit event" {
    try exercise(.{ .mode = "exit127", .code = 127 });
}
test "PSE23 codec preserves all stages and a full width errno" {
    for (std.enums.values(Status.Stage)) |stage| {
        const f: Status.Failure = .{ .stage = stage, .native_errno = 65537 };
        try t.expectEqual(f, try Status.decode(&Status.encode(f)));
    }
}
test "PSE24 codec rejects every truncated prefix and trailing data" {
    const bytes = Status.encode(.{ .stage = .exec, .native_errno = 2 });
    for (0..bytes.len) |n| try t.expectError(error.InvalidChildSetupStatus, Status.decode(bytes[0..n]));
    var extra: [13]u8 = undefined;
    @memcpy(extra[0..12], &bytes);
    extra[12] = 0;
    try t.expectError(error.InvalidChildSetupStatus, Status.decode(&extra));
}

fn badExecutable(mode: c.mode_t, expected: std.posix.E) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bad executable", .data = "not an executable image\n" });
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    const path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/bad executable", .{root}, 0);
    defer t.allocator.free(path);
    try t.expectEqual(@as(c_int, 0), c.chmod(path, mode));
    const before = countFds();
    var failure: ?Pty.SpawnFailure = null;
    try expectSpawnFailure(error.ChildExecFailed, Pty.spawnReporting(t.allocator, .{ .command = path, .env = &.{"TERM=xterm-256color"}, .size = .{ .cols = 80, .rows = 24 } }, &failure));
    const f = failure orelse return error.MissingSetupFailure;
    try t.expectEqual(Status.Stage.exec, f.stage);
    try t.expectEqual(@as(u32, @backingInt(expected)), f.native_errno);
    var status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(f.child_pid, &status, c.W.NOHANG));
    try t.expectEqual(std.posix.E.CHILD, std.posix.errno(@as(c_int, -1)));
    try t.expectEqual(before, countFds());
}
test "PSE25 nonexecutable file reports native EACCES" {
    try badExecutable(0o600, .ACCES);
}
test "PSE26 malformed executable reports native ENOEXEC" {
    try badExecutable(0o700, .NOEXEC);
}

const ConcurrentSetup = struct {
    threadlocal var stall: bool = false;
    var active = std.atomic.Value(bool).init(false);
    var prepared = std.atomic.Value(bool).init(false);
    var forked = std.atomic.Value(bool).init(false);
    var pid_pipe: [2]c.fd_t = undefined;
    var result: ?anyerror = null;
    fn prepare() callconv(.c) void {
        if (!active.load(.acquire)) return;
        if (stall) {
            prepared.store(true, .release);
            var delay: c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
            _ = c.poll(@ptrCast(&delay), 0, 100);
        } else {
            for (0..2000) |_| {
                if (forked.load(.acquire)) break;
                var delay: c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
                _ = c.poll(@ptrCast(&delay), 0, 1);
            }
        }
    }
    fn parent() callconv(.c) void {
        if (active.load(.acquire) and stall) forked.store(true, .release);
    }
    fn child() callconv(.c) void {
        if (!active.load(.acquire) or !stall) return;
        var pid = c.getpid();
        _ = c.write(pid_pipe[1], @ptrCast(&pid), @sizeOf(c.pid_t));
        while (true) _ = pause();
    }
    fn run() void {
        stall = true;
        defer stall = false;
        var failure: ?Pty.SpawnFailure = null;
        if (Pty.spawnReporting(t.allocator, .{ .command = "/bin/sh", .args = &.{ "-c", "exit 0" }, .env = &.{"TERM=xterm-256color"}, .size = .{ .cols = 80, .rows = 24 } }, &failure)) |value| {
            var session = value;
            session.deinit();
            result = error.UnexpectedStallSuccess;
        } else |err| result = err;
    }
};
test "PSE27 concurrent healthy spawn does not wait on stalled sibling writer" {
    const before = countFds();
    try t.expectEqual(@as(c_int, 0), c.pipe(&ConcurrentSetup.pid_pipe));
    defer for (ConcurrentSetup.pid_pipe) |fd| {
        _ = c.close(fd);
    };
    for (ConcurrentSetup.pid_pipe) |fd| try t.expect(c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) >= 0);
    try t.expectEqual(@as(c_int, 0), pthread_atfork(ConcurrentSetup.prepare, ConcurrentSetup.parent, ConcurrentSetup.child));
    ConcurrentSetup.active.store(true, .release);
    defer ConcurrentSetup.active.store(false, .release);
    const worker = try std.Thread.spawn(.{}, ConcurrentSetup.run, .{});
    var joined = false;
    defer if (!joined) worker.join();
    for (0..2000) |_| {
        if (ConcurrentSetup.prepared.load(.acquire)) break;
        var delay: c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(@ptrCast(&delay), 0, 1);
    }
    try t.expect(ConcurrentSetup.prepared.load(.acquire));
    const start = std.Io.Clock.awake.now(t.io);
    var path: [4096]u8 = undefined;
    const healthy_pid = try exerciseInner(.{}, try probe(&path));
    var healthy_status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(healthy_pid, &healthy_status, c.W.NOHANG));
    const elapsed = start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds;
    try t.expect(elapsed < 2500 * std.time.ns_per_ms);
    worker.join();
    joined = true; // result is published by join, not by an arbitrary sleep
    ConcurrentSetup.active.store(false, .release);
    try t.expectEqual(error.ChildSetupTimedOut, ConcurrentSetup.result.?);
    var pid: c.pid_t = 0;
    try t.expectEqual(@as(isize, @sizeOf(c.pid_t)), c.read(ConcurrentSetup.pid_pipe[0], @ptrCast(&pid), @sizeOf(c.pid_t)));
    var status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &status, c.W.NOHANG));
    try t.expectEqual(before + 2, countFds());
}

test "PSE28 public spawn returns exec failure instead of a dead session" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    const missing = try std.fmt.allocPrint(t.allocator, "{s}/absent public target", .{root});
    defer t.allocator.free(missing);
    const before = countFds();
    try expectSpawnFailure(error.ChildExecFailed, Pty.spawn(t.allocator, .{
        .command = missing,
        .env = &.{"TERM=xterm-256color"},
        .size = .{ .cols = 80, .rows = 24 },
    }));
    try t.expectEqual(before, countFds());
}
