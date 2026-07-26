//! 외부 session-host client가 빌린 controlling TTY의 수명 owner.
//!
//! 공개 `maru attach`와 resize loop는 후속 P5c2/P5c3가 이 모듈을 소비한다. 이 모듈은 host runtime을
//! 소유하지 않으며 local termios와 종료 signal wake만 관리한다. 따라서 어떤 정리 경로도 runtime/child
//! terminate를 호출할 수 없다.

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

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const EnterError = error{
    NotATerminal,
    WindowSizeUnavailable,
    InvalidWindowSize,
    SignalPipeFailed,
    SignalHandlerFailed,
    RawModeFailed,
};

pub const RestoreError = error{RestoreFailed};

pub const ExitReason = enum {
    detach,
    input_eof,
    protocol_error,
    socket_read_error,
    socket_write_error,
    controller_revoked,
};

const termination_signals = [_]posix.SIG{
    .HUP,
    .INT,
    .QUIT,
    .TERM,
};

const SignalRecord = struct {
    signal: posix.SIG,
    previous: posix.Sigaction,
};

const Ops = struct {
    context: *anyopaque,
    get_termios: *const fn (*anyopaque, c.fd_t) anyerror!posix.termios,
    get_winsize: *const fn (*anyopaque, c.fd_t) anyerror!posix.winsize,
    make_pipe: *const fn (*anyopaque) anyerror![2]c.fd_t,
    install_signal: *const fn (
        *anyopaque,
        posix.SIG,
        posix.Sigaction,
        *posix.Sigaction,
    ) anyerror!void,
    set_termios: *const fn (*anyopaque, c.fd_t, posix.termios) anyerror!void,
    close_fd: *const fn (*anyopaque, c.fd_t) void,
};

/// `RawTty` is intentionally non-copy-safe by convention: exactly one lexical owner must call
/// `restore`. P5c3 keeps it as a stack local around the attach event loop rather than storing it
/// in a copyable session model.
pub const RawTty = struct {
    fd: c.fd_t,
    original: posix.termios,
    initial_size: Size,
    wake_read_fd: c.fd_t,
    wake_write_fd: c.fd_t,
    signals: [termination_signals.len]SignalRecord,
    installed_signals: usize,
    ops: Ops,
    active: bool,

    pub fn enter(fd: c.fd_t) EnterError!RawTty {
        return enterWithOps(fd, posix_ops);
    }

    fn enterWithOps(fd: c.fd_t, ops: Ops) EnterError!RawTty {
        const original = ops.get_termios(ops.context, fd) catch return error.NotATerminal;
        const window = ops.get_winsize(ops.context, fd) catch
            return error.WindowSizeUnavailable;
        if (window.col == 0 or window.row == 0) return error.InvalidWindowSize;

        const pipe = ops.make_pipe(ops.context) catch return error.SignalPipeFailed;
        var self: RawTty = .{
            .fd = fd,
            .original = original,
            .initial_size = .{ .cols = window.col, .rows = window.row },
            .wake_read_fd = pipe[0],
            .wake_write_fd = pipe[1],
            .signals = undefined,
            .installed_signals = 0,
            .ops = ops,
            .active = false,
        };
        errdefer {
            self.restoreSignals();
            self.closeWakePipe();
        }

        // Only one external attach loop exists in a CLI process. Publishing the wake fd before
        // installing handlers prevents an installed handler from ever observing an invalid fd.
        if (@cmpxchgStrong(c.fd_t, &active_signal_write_fd, -1, pipe[1], .seq_cst, .seq_cst) != null)
            return error.SignalHandlerFailed;
        errdefer _ = @cmpxchgStrong(
            c.fd_t,
            &active_signal_write_fd,
            pipe[1],
            -1,
            .seq_cst,
            .seq_cst,
        );

        for (termination_signals) |signal| {
            var previous: posix.Sigaction = undefined;
            ops.install_signal(
                ops.context,
                signal,
                signalAction(),
                &previous,
            ) catch return error.SignalHandlerFailed;
            self.signals[self.installed_signals] = .{
                .signal = signal,
                .previous = previous,
            };
            self.installed_signals += 1;
        }

        const raw = makeRaw(original);
        ops.set_termios(ops.context, fd, raw) catch {
            // A platform tcsetattr failure is treated conservatively: even if the kernel reports
            // failure after a partial device-side change, attempt the exact saved state once.
            _ = ops.set_termios(ops.context, fd, original) catch {};
            return error.RawModeFailed;
        };
        self.active = true;
        return self;
    }

    /// Restores the borrowed TTY exactly once. All attach exits converge here.
    pub fn restore(self: *RawTty) RestoreError!void {
        if (!self.active) return;
        self.active = false;

        var failed = false;
        self.ops.set_termios(self.ops.context, self.fd, self.original) catch {
            failed = true;
        };
        self.restoreSignals();
        _ = @cmpxchgStrong(
            c.fd_t,
            &active_signal_write_fd,
            self.wake_write_fd,
            -1,
            .seq_cst,
            .seq_cst,
        );
        self.closeWakePipe();
        if (failed) return error.RestoreFailed;
    }

    /// The reason is intentionally diagnostic-only: no local exit path is allowed to acquire
    /// authority over the remote runtime or choose a different cleanup sequence.
    pub fn finish(self: *RawTty, reason: ExitReason) RestoreError!void {
        _ = reason;
        return self.restore();
    }

    /// Returns one pending termination signal. The handler only writes this byte; restoration is
    /// deliberately performed by the ordinary attach event-loop context.
    pub fn readSignal(self: *RawTty) ?posix.SIG {
        var byte: [1]u8 = undefined;
        while (true) {
            const count = c.read(self.wake_read_fd, &byte, 1);
            if (count == 1) return @enumFromInt(byte[0]);
            if (count == 0) return null;
            return switch (posix.errno(count)) {
                .INTR => continue,
                .AGAIN => null,
                else => null,
            };
        }
    }

    /// Restores local state and then preserves the caller-visible signal semantics.
    pub fn restoreAndReraise(self: *RawTty, signal: posix.SIG) noreturn {
        self.restore() catch {
            c._exit(125);
        };
        _ = c.kill(c.getpid(), signal);
        c._exit(@intCast(128 + @intFromEnum(signal)));
    }

    fn restoreSignals(self: *RawTty) void {
        while (self.installed_signals > 0) {
            self.installed_signals -= 1;
            const record = self.signals[self.installed_signals];
            var ignored: posix.Sigaction = undefined;
            self.ops.install_signal(
                self.ops.context,
                record.signal,
                record.previous,
                &ignored,
            ) catch {};
        }
    }

    fn closeWakePipe(self: *RawTty) void {
        if (self.wake_read_fd >= 0) {
            self.ops.close_fd(self.ops.context, self.wake_read_fd);
            self.wake_read_fd = -1;
        }
        if (self.wake_write_fd >= 0) {
            self.ops.close_fd(self.ops.context, self.wake_write_fd);
            self.wake_write_fd = -1;
        }
    }
};

fn makeRaw(original: posix.termios) posix.termios {
    var raw = original;
    // P5c1 TDD red: IGNBRK clearing is still intentionally absent; the contract test fails.
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    return raw;
}

var active_signal_write_fd: c.fd_t = -1;

fn signalAction() posix.Sigaction {
    return .{
        .handler = .{ .handler = terminationSignalHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
}

fn terminationSignalHandler(signal: posix.SIG) callconv(.c) void {
    const fd = @atomicLoad(c.fd_t, &active_signal_write_fd, .seq_cst);
    if (fd < 0) return;
    const byte = [1]u8{@intCast(@intFromEnum(signal))};
    _ = c.write(fd, &byte, byte.len);
}

var posix_context: u8 = 0;
const posix_ops: Ops = .{
    .context = &posix_context,
    .get_termios = posixGetTermios,
    .get_winsize = posixGetWinsize,
    .make_pipe = posixMakePipe,
    .install_signal = posixInstallSignal,
    .set_termios = posixSetTermios,
    .close_fd = posixCloseFd,
};

fn posixGetTermios(_: *anyopaque, fd: c.fd_t) !posix.termios {
    return posix.tcgetattr(fd);
}

fn posixGetWinsize(_: *anyopaque, fd: c.fd_t) !posix.winsize {
    var size: posix.winsize = undefined;
    if (c.ioctl(fd, c.T.IOCGWINSZ, &size) < 0) return error.IoctlFailed;
    return size;
}

fn posixMakePipe(_: *anyopaque) ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    for (fds) |fd| {
        const status = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        const descriptor = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
        if (status < 0 or descriptor < 0 or
            c.fcntl(fd, c.F.SETFL, status | nonblocking) < 0 or
            c.fcntl(fd, c.F.SETFD, descriptor | c.FD_CLOEXEC) < 0)
            return error.PipeFailed;
    }
    return fds;
}

fn posixInstallSignal(
    _: *anyopaque,
    signal: posix.SIG,
    action: posix.Sigaction,
    previous: *posix.Sigaction,
) !void {
    posix.sigaction(signal, &action, previous);
}

fn posixSetTermios(_: *anyopaque, fd: c.fd_t, value: posix.termios) !void {
    try posix.tcsetattr(fd, .FLUSH, value);
}

fn posixCloseFd(_: *anyopaque, fd: c.fd_t) void {
    _ = c.close(fd);
}

test "raw mode matches cfmakeraw contract without changing the saved value" {
    var original: posix.termios = std.mem.zeroes(posix.termios);
    original.iflag.IGNBRK = true;
    original.iflag.BRKINT = true;
    original.iflag.PARMRK = true;
    original.iflag.ISTRIP = true;
    original.iflag.INLCR = true;
    original.iflag.IGNCR = true;
    original.iflag.ICRNL = true;
    original.iflag.IXON = true;
    original.oflag.OPOST = true;
    original.lflag.ECHO = true;
    original.lflag.ECHONL = true;
    original.lflag.ICANON = true;
    original.lflag.ISIG = true;
    original.lflag.IEXTEN = true;
    original.cflag.PARENB = true;
    original.cc[@intFromEnum(posix.V.MIN)] = 7;
    original.cc[@intFromEnum(posix.V.TIME)] = 9;
    const saved = original;

    const raw = makeRaw(original);
    try std.testing.expectEqualDeep(saved, original);
    try std.testing.expect(!raw.iflag.IGNBRK);
    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.PARMRK);
    try std.testing.expect(!raw.iflag.ISTRIP);
    try std.testing.expect(!raw.iflag.INLCR);
    try std.testing.expect(!raw.iflag.IGNCR);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.IXON);
    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ECHONL);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expectEqual(posix.CSIZE.CS8, raw.cflag.CSIZE);
    try std.testing.expect(!raw.cflag.PARENB);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(posix.V.TIME)]);
}

test "real openpty enters raw mode, reports initial size, and restores exactly" {
    var initial: posix.termios = std.mem.zeroes(posix.termios);
    initial.iflag.ICRNL = true;
    initial.oflag.OPOST = true;
    initial.lflag.ECHO = true;
    initial.lflag.ICANON = true;
    initial.lflag.ISIG = true;
    initial.lflag.IEXTEN = true;
    initial.cflag.CREAD = true;
    initial.cflag.CSIZE = .CS8;
    initial.cc[@intFromEnum(posix.V.MIN)] = 3;
    initial.cc[@intFromEnum(posix.V.TIME)] = 4;
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);

    var owner = try RawTty.enter(slave);
    try std.testing.expectEqual(Size{ .cols = 113, .rows = 37 }, owner.initial_size);
    const during = try posix.tcgetattr(slave);
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);
    try std.testing.expectEqual(@as(u8, 1), during.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), during.cc[@intFromEnum(posix.V.TIME)]);

    try owner.restore();
    try owner.restore();
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

const FakeOps = struct {
    original: posix.termios,
    current: posix.termios,
    window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 },
    fail_at: ?usize = null,
    call_index: usize = 0,
    close_count: usize = 0,
    installed: usize = 0,
    restored: usize = 0,
    raw_sets: usize = 0,
    original_sets: usize = 0,
    terminate_requests: usize = 0,

    fn ops(self: *FakeOps) Ops {
        return .{
            .context = self,
            .get_termios = fakeGetTermios,
            .get_winsize = fakeGetWinsize,
            .make_pipe = fakeMakePipe,
            .install_signal = fakeInstallSignal,
            .set_termios = fakeSetTermios,
            .close_fd = fakeCloseFd,
        };
    }

    fn hit(self: *FakeOps) !void {
        const index = self.call_index;
        self.call_index += 1;
        if (self.fail_at != null and self.fail_at.? == index) return error.Injected;
    }
};

fn fake(context: *anyopaque) *FakeOps {
    return @ptrCast(@alignCast(context));
}

fn fakeGetTermios(context: *anyopaque, _: c.fd_t) !posix.termios {
    const self = fake(context);
    try self.hit();
    return self.original;
}

fn fakeGetWinsize(context: *anyopaque, _: c.fd_t) !posix.winsize {
    const self = fake(context);
    try self.hit();
    return self.window;
}

fn fakeMakePipe(context: *anyopaque) ![2]c.fd_t {
    const self = fake(context);
    try self.hit();
    return .{ 100, 101 };
}

fn fakeInstallSignal(
    context: *anyopaque,
    _: posix.SIG,
    action: posix.Sigaction,
    previous: *posix.Sigaction,
) !void {
    const self = fake(context);
    try self.hit();
    previous.* = std.mem.zeroes(posix.Sigaction);
    if (action.handler.handler == terminationSignalHandler) {
        self.installed += 1;
    } else {
        self.restored += 1;
    }
}

fn fakeSetTermios(context: *anyopaque, _: c.fd_t, value: posix.termios) !void {
    const self = fake(context);
    try self.hit();
    if (std.mem.eql(
        u8,
        std.mem.asBytes(&value),
        std.mem.asBytes(&self.original),
    )) {
        self.original_sets += 1;
    } else {
        self.raw_sets += 1;
    }
    self.current = value;
}

fn fakeCloseFd(context: *anyopaque, _: c.fd_t) void {
    fake(context).close_count += 1;
}

fn fakeInitialTermios() posix.termios {
    var value: posix.termios = std.mem.zeroes(posix.termios);
    value.iflag.ICRNL = true;
    value.oflag.OPOST = true;
    value.lflag.ECHO = true;
    value.lflag.ICANON = true;
    value.lflag.ISIG = true;
    value.lflag.IEXTEN = true;
    value.cflag.CREAD = true;
    value.cflag.CSIZE = .CS8;
    return value;
}

test "raw TTY enter fail-index has zero mutation or exact rollback" {
    // get termios, get winsize, pipe, four handlers, raw tcsetattr.
    for (0..8) |fail_at| {
        const original = fakeInitialTermios();
        var backend: FakeOps = .{
            .original = original,
            .current = original,
            .fail_at = fail_at,
        };
        try std.testing.expectError(
            switch (fail_at) {
                0 => error.NotATerminal,
                1 => error.WindowSizeUnavailable,
                2 => error.SignalPipeFailed,
                3...6 => error.SignalHandlerFailed,
                7 => error.RawModeFailed,
                else => unreachable,
            },
            RawTty.enterWithOps(42, backend.ops()),
        );
        try std.testing.expectEqual(@as(usize, 0), backend.raw_sets);
        try std.testing.expectEqual(@as(usize, 0), backend.terminate_requests);
        if (fail_at < 2) {
            try std.testing.expectEqual(@as(usize, 0), backend.close_count);
        } else if (fail_at == 2) {
            try std.testing.expectEqual(@as(usize, 0), backend.close_count);
        } else {
            try std.testing.expectEqual(@as(usize, 2), backend.close_count);
            try std.testing.expectEqual(backend.installed, backend.restored);
        }
        if (fail_at == 7) {
            try std.testing.expectEqual(@as(usize, 1), backend.original_sets);
            try std.testing.expectEqualDeep(original, backend.current);
        }
        try std.testing.expectEqual(@as(c.fd_t, -1), @atomicLoad(
            c.fd_t,
            &active_signal_write_fd,
            .seq_cst,
        ));
    }
}

test "every non-signal exit reason uses one idempotent restore and never terminates runtime" {
    for (std.enums.values(ExitReason)) |reason| {
        const original = fakeInitialTermios();
        var backend: FakeOps = .{ .original = original, .current = original };
        var owner = try RawTty.enterWithOps(42, backend.ops());
        try std.testing.expectEqual(@as(usize, 1), backend.raw_sets);
        try owner.finish(reason);
        try owner.finish(reason);
        try std.testing.expectEqual(@as(usize, 1), backend.original_sets);
        try std.testing.expectEqual(@as(usize, 2), backend.close_count);
        try std.testing.expectEqual(backend.installed, backend.restored);
        try std.testing.expectEqual(@as(usize, 0), backend.terminate_requests);
    }
}

test "restore failure is reported after signal handlers and pipe are still reclaimed" {
    const original = fakeInitialTermios();
    var backend: FakeOps = .{ .original = original, .current = original };
    var owner = try RawTty.enterWithOps(42, backend.ops());
    backend.fail_at = backend.call_index;

    try std.testing.expectError(error.RestoreFailed, owner.finish(.socket_read_error));
    try owner.finish(.socket_read_error);
    try std.testing.expectEqual(@as(usize, 2), backend.close_count);
    try std.testing.expectEqual(backend.installed, backend.restored);
    try std.testing.expectEqual(@as(usize, 0), backend.terminate_requests);
    try std.testing.expectEqual(@as(c.fd_t, -1), @atomicLoad(
        c.fd_t,
        &active_signal_write_fd,
        .seq_cst,
    ));
}

fn waitChild(pid: c.pid_t) !u32 {
    var status: c_int = 0;
    while (true) {
        const result = c.waitpid(pid, &status, 0);
        if (result == pid) return @bitCast(status);
        if (result < 0 and posix.errno(result) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn runSignalRestoreCase(signal: posix.SIG) !void {
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 41, .col = 119, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    if (openpty(&master, &slave, null, &initial, &window) != 0)
        return error.TestUnexpectedResult;
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);

    var ready: [2]c.fd_t = undefined;
    if (c.pipe(&ready) != 0) return error.TestUnexpectedResult;
    defer _ = c.close(ready[0]);
    defer _ = c.close(ready[1]);

    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.close(master);
        _ = c.close(ready[0]);
        var owner = RawTty.enter(slave) catch c._exit(120);
        const marker = [1]u8{1};
        if (c.write(ready[1], &marker, marker.len) != marker.len) c._exit(121);
        var poll_fds = [_]posix.pollfd{.{
            .fd = owner.wake_read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        while (true) {
            _ = posix.poll(&poll_fds, -1) catch c._exit(122);
            if (owner.readSignal()) |received| owner.restoreAndReraise(received);
        }
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    var marker: [1]u8 = undefined;
    while (true) {
        const count = c.read(ready[0], &marker, marker.len);
        if (count == 1) break;
        if (count < 0 and posix.errno(count) == .INTR) continue;
        _ = c.kill(pid, posix.SIG.KILL);
        _ = waitChild(pid) catch {};
        return error.TestUnexpectedResult;
    }
    const during = try posix.tcgetattr(slave);
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);

    if (c.kill(pid, signal) != 0) return error.TestUnexpectedResult;
    const status = try waitChild(pid);
    try std.testing.expect(c.W.IFSIGNALED(status));
    try std.testing.expectEqual(signal, c.W.TERMSIG(status));
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

test "real PTY restores before reraising every supported termination signal" {
    for (termination_signals) |signal| try runSignalRestoreCase(signal);
}
