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
extern "c" fn cfmakeraw(termios_p: *posix.termios) void;
extern "c" fn usleep(usec: c_uint) c_int;
const darwin_tiocswinsz: c_int = @bitCast(@as(u32, 0x80087467));

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
    UnsupportedSignalDisposition,
    RawModeFailed,
};

pub const RestoreError = error{RestoreFailed};
pub const SignalReadError = error{InvalidSignalByte};
pub const WindowSizeError = error{ WindowSizeUnavailable, InvalidWindowSize };

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
const managed_signals = termination_signals ++ [_]posix.SIG{.WINCH};

const SignalRecord = struct {
    signal: posix.SIG,
    previous: posix.Sigaction,
};

const Ops = struct {
    context: *anyopaque,
    get_termios: *const fn (*anyopaque, c.fd_t) anyerror!posix.termios,
    get_winsize: *const fn (*anyopaque, c.fd_t) anyerror!posix.winsize,
    block_signals: *const fn (*anyopaque, *posix.sigset_t) anyerror!void,
    restore_signal_mask: *const fn (*anyopaque, posix.sigset_t) anyerror!void,
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
    signals: [managed_signals.len]SignalRecord,
    installed_signals: usize,
    ops: Ops,
    termios_pending: bool,
    resources_pending: bool,
    restore_mask_pending: bool,
    restore_mask: posix.sigset_t,
    owner_token: u64,

    pub fn enter(fd: c.fd_t) EnterError!RawTty {
        return enterWithOps(fd, posix_ops);
    }

    fn enterWithOps(fd: c.fd_t, ops: Ops) EnterError!RawTty {
        const original = ops.get_termios(ops.context, fd) catch return error.NotATerminal;
        const window = ops.get_winsize(ops.context, fd) catch
            return error.WindowSizeUnavailable;
        if (window.col == 0 or window.row == 0) return error.InvalidWindowSize;

        var previous_mask: posix.sigset_t = undefined;
        ops.block_signals(ops.context, &previous_mask) catch
            return error.SignalHandlerFailed;
        var mask_blocked = true;
        errdefer if (mask_blocked)
            ops.restore_signal_mask(ops.context, previous_mask) catch {};

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
            .termios_pending = false,
            .resources_pending = true,
            .restore_mask_pending = false,
            .restore_mask = undefined,
            .owner_token = @atomicRmw(
                u64,
                &next_owner_token,
                .Add,
                1,
                .seq_cst,
            ),
        };
        errdefer {
            _ = self.restoreSignals();
            self.closeWakePipe();
        }

        // Only one external attach loop exists in a CLI process. Publishing the wake fd before
        // installing handlers prevents an installed handler from ever observing an invalid fd.
        if (@cmpxchgStrong(c.fd_t, &active_signal_write_fd, -1, pipe[1], .seq_cst, .seq_cst) != null)
            return error.SignalHandlerFailed;
        @atomicStore(u32, &active_pending_signal_bits, 0, .seq_cst);
        @atomicStore(c.pid_t, &active_signal_pid, c.getpid(), .seq_cst);
        @atomicStore(u64, &active_owner_token, self.owner_token, .seq_cst);
        errdefer @atomicStore(c.pid_t, &active_signal_pid, -1, .seq_cst);
        errdefer @atomicStore(u64, &active_owner_token, 0, .seq_cst);
        errdefer _ = @cmpxchgStrong(
            c.fd_t,
            &active_signal_write_fd,
            pipe[1],
            -1,
            .seq_cst,
            .seq_cst,
        );

        for (managed_signals) |signal| {
            var previous: posix.Sigaction = undefined;
            ops.install_signal(
                ops.context,
                signal,
                signalAction(),
                &previous,
            ) catch return error.SignalHandlerFailed;
            if (previous.handler.handler != posix.SIG.DFL) {
                var ignored: posix.Sigaction = undefined;
                ops.install_signal(
                    ops.context,
                    signal,
                    previous,
                    &ignored,
                ) catch return error.SignalHandlerFailed;
                return error.UnsupportedSignalDisposition;
            }
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
        self.termios_pending = true;
        ops.restore_signal_mask(ops.context, previous_mask) catch {
            _ = ops.set_termios(ops.context, fd, original) catch {};
            self.termios_pending = false;
            return error.SignalHandlerFailed;
        };
        mask_blocked = false;
        return self;
    }

    /// Restores the borrowed TTY exactly once. All attach exits converge here.
    pub fn restore(self: *RawTty) RestoreError!void {
        if (!self.termios_pending and !self.resources_pending and !self.restore_mask_pending)
            return;
        if (@atomicLoad(u64, &active_owner_token, .seq_cst) != self.owner_token)
            return error.RestoreFailed;

        var failed = false;
        if (!self.restore_mask_pending) {
            self.ops.block_signals(self.ops.context, &self.restore_mask) catch {
                failed = true;
            };
            if (!failed) self.restore_mask_pending = true;
        }
        if (self.termios_pending) {
            var termios_failed = false;
            self.ops.set_termios(self.ops.context, self.fd, self.original) catch {
                failed = true;
                termios_failed = true;
            };
            if (!termios_failed) self.termios_pending = false;
        }
        // Keep the signal wake bridge alive while termios is still raw so a retryable restore
        // failure cannot turn the next termination signal into an unclean raw-TTY exit.
        if (self.resources_pending and !self.termios_pending) {
            if (!self.restoreSignals()) {
                failed = true;
            } else {
                _ = @cmpxchgStrong(
                    c.fd_t,
                    &active_signal_write_fd,
                    self.wake_write_fd,
                    -1,
                    .seq_cst,
                    .seq_cst,
                );
                @atomicStore(c.pid_t, &active_signal_pid, -1, .seq_cst);
                @atomicStore(u32, &active_pending_signal_bits, 0, .seq_cst);
                self.closeWakePipe();
                self.resources_pending = false;
            }
        }
        if (self.restore_mask_pending) {
            var mask_restore_failed = false;
            self.ops.restore_signal_mask(self.ops.context, self.restore_mask) catch {
                failed = true;
                mask_restore_failed = true;
            };
            if (!mask_restore_failed) self.restore_mask_pending = false;
        }
        if (!self.termios_pending and !self.resources_pending and !self.restore_mask_pending)
            @atomicStore(u64, &active_owner_token, 0, .seq_cst);
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
    pub fn readSignal(self: *RawTty) SignalReadError!?posix.SIG {
        var byte: [1]u8 = undefined;
        while (true) {
            const count = c.read(self.wake_read_fd, &byte, 1);
            if (count == 1) {
                for (managed_signals) |signal|
                    if (byte[0] == @intFromEnum(signal)) {
                        _ = @atomicRmw(
                            u32,
                            &active_pending_signal_bits,
                            .And,
                            ~signalBit(signal),
                            .seq_cst,
                        );
                        return signal;
                    };
                return error.InvalidSignalByte;
            }
            if (count == 0) return null;
            return switch (posix.errno(count)) {
                .INTR => continue,
                .AGAIN => null,
                else => null,
            };
        }
    }

    pub const WakeBatch = struct {
        termination: ?posix.SIG = null,
        resize: bool = false,
    };

    pub fn drainWakeBatch(self: *RawTty) SignalReadError!WakeBatch {
        var batch: WakeBatch = .{};
        while (try self.readSignal()) |signal| {
            if (signal == .WINCH) {
                batch.resize = true;
            } else if (batch.termination == null) {
                batch.termination = signal;
            }
        }
        const pending = @atomicRmw(
            u32,
            &active_pending_signal_bits,
            .Xchg,
            0,
            .seq_cst,
        );
        for (managed_signals) |signal| {
            if (pending & signalBit(signal) == 0) continue;
            if (signal == .WINCH) {
                batch.resize = true;
            } else if (batch.termination == null) {
                batch.termination = signal;
            }
        }
        if (batch.termination != null) batch.resize = false;
        return batch;
    }

    pub fn currentSize(self: *const RawTty) WindowSizeError!Size {
        const window = self.ops.get_winsize(self.ops.context, self.fd) catch
            return error.WindowSizeUnavailable;
        if (window.col == 0 or window.row == 0) return error.InvalidWindowSize;
        return .{ .cols = window.col, .rows = window.row };
    }

    /// Restores local state and then preserves the caller-visible signal semantics.
    pub fn restoreAndForward(self: *RawTty, signal: posix.SIG) RestoreError!void {
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            self.restore() catch continue;
            break;
        } else return error.RestoreFailed;
        _ = c.kill(c.getpid(), signal);
    }

    fn restoreSignals(self: *RawTty) bool {
        while (self.installed_signals > 0) {
            const index = self.installed_signals - 1;
            const record = self.signals[index];
            var ignored: posix.Sigaction = undefined;
            self.ops.install_signal(
                self.ops.context,
                record.signal,
                record.previous,
                &ignored,
            ) catch {
                // Stop at the first failed reverse-order record. The failed record and every
                // lower record remain in their original slots for an alias-free retry.
                return false;
            };
            self.installed_signals = index;
        }
        return true;
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
    // Use the target libc's documented terminal policy rather than maintaining a subtly
    // divergent local flag list. Darwin cfmakeraw intentionally differs from common Linux
    // summaries (notably IGNBRK/IMAXBEL/CREAD).
    cfmakeraw(&raw);
    return raw;
}

var active_signal_write_fd: c.fd_t = -1;
var active_signal_pid: c.pid_t = -1;
var active_pending_signal_bits: u32 = 0;
var next_owner_token: u64 = 1;
var active_owner_token: u64 = 0;

fn signalBit(signal: posix.SIG) u32 {
    for (managed_signals, 0..) |candidate, index|
        if (candidate == signal)
            return @as(u32, 1) << @intCast(index);
    return 0;
}

fn signalAction() posix.Sigaction {
    return .{
        .handler = .{ .handler = wakeSignalHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
}

fn wakeSignalHandler(signal: posix.SIG) callconv(.c) void {
    // `fork` duplicates process memory but not the ownership identity. A child must never write
    // into the parent's inherited self-pipe. P5c3 additionally keeps the attach CLI single-threaded
    // and fork-free while this process-global handler is installed.
    if (c.getpid() != @atomicLoad(c.pid_t, &active_signal_pid, .seq_cst))
        c._exit(@intCast(128 + @intFromEnum(signal)));
    const fd = @atomicLoad(c.fd_t, &active_signal_write_fd, .seq_cst);
    if (fd < 0) return;
    _ = @atomicRmw(
        u32,
        &active_pending_signal_bits,
        .Or,
        signalBit(signal),
        .seq_cst,
    );
    const byte = [1]u8{@intCast(@intFromEnum(signal))};
    while (true) {
        const written = c.write(fd, &byte, byte.len);
        if (written == byte.len) return;
        if (written < 0 and posix.errno(written) == .INTR) continue;
        // EAGAIN means the pipe is already readable, so the event loop is guaranteed a wake.
        return;
    }
}

var posix_context: u8 = 0;
const posix_ops: Ops = .{
    .context = &posix_context,
    .get_termios = posixGetTermios,
    .get_winsize = posixGetWinsize,
    .block_signals = posixBlockSignals,
    .restore_signal_mask = posixRestoreSignalMask,
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

fn posixBlockSignals(_: *anyopaque, previous: *posix.sigset_t) !void {
    var set = posix.sigemptyset();
    for (managed_signals) |signal| posix.sigaddset(&set, signal);
    posix.sigprocmask(posix.SIG.BLOCK, &set, previous);
}

fn posixRestoreSignalMask(_: *anyopaque, previous: posix.sigset_t) !void {
    posix.sigprocmask(posix.SIG.SETMASK, &previous, null);
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
    original.iflag.IMAXBEL = true;
    original.oflag.OPOST = true;
    original.lflag.ECHO = true;
    original.lflag.ECHONL = true;
    original.lflag.ICANON = true;
    original.lflag.ISIG = true;
    original.lflag.IEXTEN = true;
    original.cflag.PARENB = true;
    original.cflag.CREAD = false;
    original.cc[@intFromEnum(posix.V.MIN)] = 7;
    original.cc[@intFromEnum(posix.V.TIME)] = 9;
    const saved = original;

    const raw = makeRaw(original);
    try std.testing.expectEqualDeep(saved, original);
    try std.testing.expect(raw.iflag.IGNBRK);
    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.PARMRK);
    try std.testing.expect(!raw.iflag.ISTRIP);
    try std.testing.expect(!raw.iflag.INLCR);
    try std.testing.expect(!raw.iflag.IGNCR);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.IXON);
    try std.testing.expect(!raw.iflag.IMAXBEL);
    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ECHONL);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expectEqual(posix.CSIZE.CS8, raw.cflag.CSIZE);
    try std.testing.expect(!raw.cflag.PARENB);
    try std.testing.expect(raw.cflag.CREAD);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(posix.V.TIME)]);
}

test "real openpty enters raw mode, reports initial size, and restores exactly" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
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
    const wake_read_fd = owner.wake_read_fd;
    const wake_write_fd = owner.wake_write_fd;
    const read_status = c.fcntl(wake_read_fd, c.F.GETFL, @as(c_int, 0));
    const write_status = c.fcntl(wake_write_fd, c.F.GETFL, @as(c_int, 0));
    const read_descriptor = c.fcntl(wake_read_fd, c.F.GETFD, @as(c_int, 0));
    const write_descriptor = c.fcntl(wake_write_fd, c.F.GETFD, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expect(read_status & nonblocking != 0);
    try std.testing.expect(write_status & nonblocking != 0);
    try std.testing.expect(read_descriptor & c.FD_CLOEXEC != 0);
    try std.testing.expect(write_descriptor & c.FD_CLOEXEC != 0);
    try std.testing.expectEqual(Size{ .cols = 113, .rows = 37 }, owner.initial_size);
    const during = try posix.tcgetattr(slave);
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);
    try std.testing.expectEqual(@as(u8, 1), during.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), during.cc[@intFromEnum(posix.V.TIME)]);

    try owner.restore();
    try owner.restore();
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(
        wake_read_fd,
        c.F.GETFD,
        @as(c_int, 0),
    ));
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(
        wake_write_fd,
        c.F.GETFD,
        @as(c_int, 0),
    ));
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
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
    block_calls: usize = 0,
    restore_mask_calls: usize = 0,
    restored_by_signal: [managed_signals.len]usize = .{0} ** managed_signals.len,

    fn ops(self: *FakeOps) Ops {
        return .{
            .context = self,
            .get_termios = fakeGetTermios,
            .get_winsize = fakeGetWinsize,
            .block_signals = fakeBlockSignals,
            .restore_signal_mask = fakeRestoreSignalMask,
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

fn fakeBlockSignals(context: *anyopaque, previous: *posix.sigset_t) !void {
    const self = fake(context);
    self.block_calls += 1;
    try self.hit();
    previous.* = std.mem.zeroes(posix.sigset_t);
}

fn fakeRestoreSignalMask(context: *anyopaque, _: posix.sigset_t) !void {
    const self = fake(context);
    self.restore_mask_calls += 1;
    try self.hit();
}

fn fakeMakePipe(context: *anyopaque) ![2]c.fd_t {
    const self = fake(context);
    try self.hit();
    return .{ 100, 101 };
}

fn fakeInstallSignal(
    context: *anyopaque,
    signal: posix.SIG,
    action: posix.Sigaction,
    previous: *posix.Sigaction,
) !void {
    const self = fake(context);
    try self.hit();
    previous.* = std.mem.zeroes(posix.Sigaction);
    if (action.handler.handler == wakeSignalHandler) {
        self.installed += 1;
    } else {
        self.restored += 1;
        for (managed_signals, 0..) |candidate, index| {
            if (candidate == signal) self.restored_by_signal[index] += 1;
        }
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
    // get termios, get winsize, block mask, pipe, five handlers, raw tcsetattr,
    // restore mask. Cleanup calls occur after the one-shot injected failure.
    for (0..11) |fail_at| {
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
                2 => error.SignalHandlerFailed,
                3 => error.SignalPipeFailed,
                4...8 => error.SignalHandlerFailed,
                9 => error.RawModeFailed,
                10 => error.SignalHandlerFailed,
                else => unreachable,
            },
            RawTty.enterWithOps(42, backend.ops()),
        );
        try std.testing.expectEqual(
            @as(usize, if (fail_at == 10) 1 else 0),
            backend.raw_sets,
        );
        try std.testing.expectEqual(@as(usize, 0), backend.terminate_requests);
        if (fail_at < 3) {
            try std.testing.expectEqual(@as(usize, 0), backend.close_count);
        } else if (fail_at == 3) {
            try std.testing.expectEqual(@as(usize, 0), backend.close_count);
        } else {
            try std.testing.expectEqual(@as(usize, 2), backend.close_count);
            try std.testing.expectEqual(backend.installed, backend.restored);
        }
        if (fail_at == 9 or fail_at == 10) {
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

test "zero window dimensions fail before signal or terminal mutation" {
    const original = fakeInitialTermios();
    var backend: FakeOps = .{
        .original = original,
        .current = original,
        .window = .{ .row = 0, .col = 113, .xpixel = 0, .ypixel = 0 },
    };
    try std.testing.expectError(
        error.InvalidWindowSize,
        RawTty.enterWithOps(42, backend.ops()),
    );
    try std.testing.expectEqual(@as(usize, 2), backend.call_index);
    try std.testing.expectEqual(@as(usize, 0), backend.raw_sets);
    try std.testing.expectEqual(@as(usize, 0), backend.close_count);
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

test "termios restore failure keeps signal resources and retries to exact cleanup" {
    const original = fakeInitialTermios();
    var backend: FakeOps = .{ .original = original, .current = original };
    var owner = try RawTty.enterWithOps(42, backend.ops());
    // restore: block mask, then original termios.
    backend.fail_at = backend.call_index + 1;

    try std.testing.expectError(error.RestoreFailed, owner.finish(.socket_read_error));
    try std.testing.expectEqual(@as(usize, 0), backend.close_count);
    try std.testing.expectEqual(@as(c.fd_t, 101), @atomicLoad(
        c.fd_t,
        &active_signal_write_fd,
        .seq_cst,
    ));
    try owner.finish(.socket_read_error);
    try std.testing.expectEqual(@as(usize, 3), backend.block_calls);
    try std.testing.expectEqual(@as(usize, 2), backend.close_count);
    try std.testing.expectEqual(backend.installed, backend.restored);
    try std.testing.expectEqual(@as(usize, 0), backend.terminate_requests);
    try std.testing.expectEqual(@as(c.fd_t, -1), @atomicLoad(
        c.fd_t,
        &active_signal_write_fd,
        .seq_cst,
    ));
}

test "signal mask restore failure remains retryable after other resources close" {
    const original = fakeInitialTermios();
    var backend: FakeOps = .{ .original = original, .current = original };
    var owner = try RawTty.enterWithOps(42, backend.ops());
    // restore: block, termios, five handlers, then original mask.
    backend.fail_at = backend.call_index + 7;

    try std.testing.expectError(error.RestoreFailed, owner.finish(.detach));
    try std.testing.expect(owner.restore_mask_pending);
    try std.testing.expectEqual(@as(usize, 2), backend.close_count);
    try owner.finish(.detach);
    try std.testing.expect(!owner.restore_mask_pending);
}

test "signal handler restore failure retries every signal identity exactly once" {
    const original = fakeInitialTermios();
    var backend: FakeOps = .{ .original = original, .current = original };
    var owner = try RawTty.enterWithOps(42, backend.ops());
    // restore: block mask, termios, then the first reverse-order handler.
    backend.fail_at = backend.call_index + 2;

    try std.testing.expectError(error.RestoreFailed, owner.finish(.protocol_error));
    try std.testing.expectEqual(@as(usize, 0), backend.restored);
    try std.testing.expectEqual(@as(usize, 0), backend.close_count);
    try std.testing.expectEqual(@as(c.fd_t, 101), @atomicLoad(
        c.fd_t,
        &active_signal_write_fd,
        .seq_cst,
    ));
    // The failed handler remains retryable; the second call restores it before closing the pipe.
    try owner.finish(.protocol_error);
    try std.testing.expectEqual(@as(usize, 3), backend.block_calls);
    try std.testing.expectEqual(@as(usize, managed_signals.len), backend.restored);
    for (backend.restored_by_signal) |count|
        try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 2), backend.close_count);
}

fn waitChildDeadline(pid: c.pid_t, timeout_ms: i64) !u32 {
    var status: c_int = 0;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    while (started.untilNow(std.testing.io, .awake).toMilliseconds() < timeout_ms) {
        const result = c.waitpid(pid, &status, c.W.NOHANG);
        if (result == pid) return @bitCast(status);
        if (result < 0 and posix.errno(result) == .INTR) continue;
        if (result < 0) return error.TestUnexpectedResult;
        _ = usleep(10_000);
    }
    return error.TestTimedOut;
}

fn killAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, posix.SIG.KILL);
    _ = waitChildDeadline(pid, 5_000) catch {};
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
    var child_reaped = false;
    errdefer if (!child_reaped) killAndReap(pid);
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
            if (owner.readSignal() catch c._exit(126)) |received| {
                owner.restoreAndForward(received) catch c._exit(123);
                c._exit(124);
            }
        }
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    var marker: [1]u8 = undefined;
    var ready_poll = [_]posix.pollfd{.{
        .fd = ready[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = try posix.poll(&ready_poll, 5_000);
    if (ready_count != 1 or ready_poll[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0)
        return error.TestTimedOut;
    while (true) {
        const count = c.read(ready[0], &marker, marker.len);
        if (count == 1) break;
        if (count < 0 and posix.errno(count) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
    const during = try posix.tcgetattr(slave);
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);

    if (c.kill(pid, signal) != 0) return error.TestUnexpectedResult;
    const status = try waitChildDeadline(pid, 5_000);
    child_reaped = true;
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
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    for (termination_signals) |signal| try runSignalRestoreCase(signal);
}

test "invalid self-pipe byte is rejected without constructing an arbitrary signal" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var owner = try RawTty.enter(slave);
    defer owner.restore() catch {};
    const invalid = [1]u8{255};
    try std.testing.expectEqual(@as(isize, 1), c.write(
        owner.wake_write_fd,
        &invalid,
        invalid.len,
    ));
    try std.testing.expectError(error.InvalidSignalByte, owner.readSignal());
}

test "SIGWINCH bursts coalesce and termination wins in one wake batch" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var owner = try RawTty.enter(slave);
    defer owner.restore() catch {};

    const resize_bytes = [_]u8{
        @intCast(@intFromEnum(posix.SIG.WINCH)),
        @intCast(@intFromEnum(posix.SIG.WINCH)),
        @intCast(@intFromEnum(posix.SIG.WINCH)),
    };
    try std.testing.expectEqual(
        @as(isize, resize_bytes.len),
        c.write(owner.wake_write_fd, &resize_bytes, resize_bytes.len),
    );
    const resize_only = try owner.drainWakeBatch();
    try std.testing.expect(resize_only.resize);
    try std.testing.expectEqual(@as(?posix.SIG, null), resize_only.termination);

    const mixed = [_]u8{
        @intCast(@intFromEnum(posix.SIG.WINCH)),
        @intCast(@intFromEnum(posix.SIG.TERM)),
        @intCast(@intFromEnum(posix.SIG.WINCH)),
    };
    try std.testing.expectEqual(
        @as(isize, mixed.len),
        c.write(owner.wake_write_fd, &mixed, mixed.len),
    );
    const terminated = try owner.drainWakeBatch();
    try std.testing.expect(!terminated.resize);
    try std.testing.expectEqual(posix.SIG.TERM, terminated.termination.?);
}

test "termination survives a SIGWINCH-saturated wake pipe" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var owner = try RawTty.enter(slave);
    defer owner.restore() catch {};

    const winch_byte = [1]u8{@intCast(@intFromEnum(posix.SIG.WINCH))};
    var written: usize = 0;
    while (written < 1024 * 1024) : (written += 1) {
        const result = c.write(owner.wake_write_fd, &winch_byte, winch_byte.len);
        if (result == 1) continue;
        try std.testing.expectEqual(posix.E.AGAIN, posix.errno(result));
        break;
    }
    try std.testing.expect(written < 1024 * 1024);

    // The signal byte cannot enter the full pipe. The atomic pending class remains authoritative.
    wakeSignalHandler(.TERM);
    const batch = try owner.drainWakeBatch();
    try std.testing.expectEqual(posix.SIG.TERM, batch.termination.?);
    try std.testing.expect(!batch.resize);
}

test "openpty child turns SIGWINCH burst into one latest window size" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var ready: [2]c.fd_t = undefined;
    var release: [2]c.fd_t = undefined;
    var report: [2]c.fd_t = undefined;
    if (c.pipe(&ready) != 0 or c.pipe(&release) != 0 or c.pipe(&report) != 0)
        return error.TestUnexpectedResult;
    defer {
        for (ready ++ release ++ report) |fd| _ = c.close(fd);
    }

    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    var child_reaped = false;
    errdefer if (!child_reaped) killAndReap(pid);
    if (pid == 0) {
        _ = c.close(master);
        _ = c.close(ready[0]);
        _ = c.close(release[1]);
        _ = c.close(report[0]);
        var owner = RawTty.enter(slave) catch c._exit(130);
        const marker = [1]u8{1};
        if (c.write(ready[1], &marker, 1) != 1) c._exit(131);
        var go: [1]u8 = undefined;
        while (true) {
            const count = c.read(release[0], &go, 1);
            if (count == 1) break;
            if (count < 0 and posix.errno(count) == .INTR) continue;
            c._exit(132);
        }
        const batch = owner.drainWakeBatch() catch c._exit(133);
        if (!batch.resize or batch.termination != null) c._exit(134);
        const latest = owner.currentSize() catch c._exit(135);
        if (c.write(report[1], std.mem.asBytes(&latest), @sizeOf(Size)) !=
            @sizeOf(Size)) c._exit(136);
        owner.restore() catch c._exit(137);
        c._exit(0);
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    _ = c.close(release[0]);
    release[0] = -1;
    _ = c.close(report[1]);
    report[1] = -1;
    var marker: [1]u8 = undefined;
    var ready_poll = [_]posix.pollfd{.{
        .fd = ready[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    if (try posix.poll(&ready_poll, 5_000) != 1 or c.read(ready[0], &marker, 1) != 1)
        return error.TestTimedOut;
    inline for (&.{
        posix.winsize{ .row = 30, .col = 100, .xpixel = 0, .ypixel = 0 },
        posix.winsize{ .row = 40, .col = 120, .xpixel = 0, .ypixel = 0 },
        posix.winsize{ .row = 50, .col = 140, .xpixel = 0, .ypixel = 0 },
    }) |next| {
        var mutable = next;
        if (c.ioctl(master, darwin_tiocswinsz, &mutable) != 0 or
            c.kill(pid, posix.SIG.WINCH) != 0)
            return error.TestUnexpectedResult;
    }
    if (c.write(release[1], &marker, 1) != 1) return error.TestUnexpectedResult;
    var latest: Size = undefined;
    var report_poll = [_]posix.pollfd{.{
        .fd = report[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    if (try posix.poll(&report_poll, 5_000) != 1 or
        c.read(report[0], std.mem.asBytes(&latest), @sizeOf(Size)) !=
            @sizeOf(Size))
        return error.TestTimedOut;
    try std.testing.expectEqual(Size{ .cols = 140, .rows = 50 }, latest);
    const status = try waitChildDeadline(pid, 5_000);
    child_reaped = true;
    try std.testing.expect(c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), c.W.EXITSTATUS(status));
}

fn signalActionsEqual(a: posix.Sigaction, b: posix.Sigaction) bool {
    return a.handler.handler == b.handler.handler and
        a.flags == b.flags and
        std.mem.eql(u8, std.mem.asBytes(&a.mask), std.mem.asBytes(&b.mask));
}

fn expectUnsupportedDisposition(action: posix.Sigaction) !void {
    var previous: posix.Sigaction = undefined;
    posix.sigaction(.HUP, &action, &previous);
    defer posix.sigaction(.HUP, &previous, null);

    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);

    try std.testing.expectError(
        error.UnsupportedSignalDisposition,
        RawTty.enter(slave),
    );
    var after_action: posix.Sigaction = undefined;
    posix.sigaction(.HUP, null, &after_action);
    try std.testing.expect(signalActionsEqual(action, after_action));
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

fn customSignalHandler(_: posix.SIG) callconv(.c) void {}

test "ignored and custom termination dispositions are rejected without mutation" {
    const ignored: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    try expectUnsupportedDisposition(ignored);

    var custom_mask = posix.sigemptyset();
    posix.sigaddset(&custom_mask, .INT);
    const custom: posix.Sigaction = .{
        .handler = .{ .handler = customSignalHandler },
        .mask = custom_mask,
        .flags = posix.SA.RESTART,
    };
    try expectUnsupportedDisposition(custom);
}

test "forked child cannot signal the parent raw TTY self-pipe" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var owner = try RawTty.enter(slave);
    defer owner.restore() catch {};

    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.kill(c.getpid(), posix.SIG.TERM);
        c._exit(124);
    }
    var child_reaped = false;
    errdefer if (!child_reaped) killAndReap(pid);
    const status = try waitChildDeadline(pid, 5_000);
    child_reaped = true;
    try std.testing.expect(c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 143), c.W.EXITSTATUS(status));

    var poll_fds = [_]posix.pollfd{.{
        .fd = owner.wake_read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&poll_fds, 0));
}

test "stale copied owner cannot repeat cleanup after the lexical owner finishes" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    const initial = fakeInitialTermios();
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, &initial, &window));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var owner = try RawTty.enter(slave);
    var stale_copy = owner;
    try owner.restore();
    try std.testing.expectError(error.RestoreFailed, stale_copy.restore());
}
