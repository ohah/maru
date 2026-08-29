//! P5c3c-1a absolute-deadline socket transport.
//!
//! `Client` remains the sole fd/parser owner. This leaf only performs bounded readiness and
//! established byte I/O against a borrowed fd; injected ops make connect completion and byte drip
//! deterministic without teaching the protocol client about clocks or poll syscalls.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

pub const Error = error{
    InvalidDeadline,
    EndpointAbsent,
    EndpointDenied,
    EndpointTransient,
    ConnectFailed,
    Timeout,
    Closed,
    ReadFailed,
    WriteFailed,
    FlagFailed,
    SocketOptionFailed,
};

pub const ClockSource = struct {
    context: *anyopaque,
    now_ns: *const fn (context: *anyopaque) i128,
};

const Clock = union(enum) {
    io: std.Io,
    injected: ClockSource,
};

pub const AbsoluteDeadline = struct {
    clock: Clock,
    expires_at_ns: i128,

    pub fn after(io: std.Io, budget_ns: i128) Error!AbsoluteDeadline {
        if (budget_ns <= 0) return error.InvalidDeadline;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        return .{
            .clock = .{ .io = io },
            .expires_at_ns = std.math.add(i128, now, budget_ns) catch
                return error.InvalidDeadline,
        };
    }

    /// Carries a caller-owned monotonic absolute deadline across a worker handoff without
    /// manufacturing a fresh phase budget.
    pub fn fromAbsolute(io: std.Io, expires_at_ns: i128) Error!AbsoluteDeadline {
        if (expires_at_ns <= std.Io.Clock.awake.now(io).nanoseconds)
            return error.InvalidDeadline;
        return .{ .clock = .{ .io = io }, .expires_at_ns = expires_at_ns };
    }

    pub fn fromInjected(source: ClockSource, expires_at_ns: i128) AbsoluteDeadline {
        return .{ .clock = .{ .injected = source }, .expires_at_ns = expires_at_ns };
    }

    pub fn nowNs(self: AbsoluteDeadline) i128 {
        return switch (self.clock) {
            .io => |io| std.Io.Clock.awake.now(io).nanoseconds,
            .injected => |source| source.now_ns(source.context),
        };
    }

    pub fn remainingNs(self: AbsoluteDeadline) i128 {
        const now = self.nowNs();
        if (now >= self.expires_at_ns) return 0;
        return std.math.sub(i128, self.expires_at_ns, now) catch std.math.maxInt(i128);
    }

    fn pollTimeoutMs(self: AbsoluteDeadline) Error!c_int {
        const remaining = self.remainingNs();
        if (remaining <= 0) return error.Timeout;
        const rounded = std.math.divCeil(i128, remaining, std.time.ns_per_ms) catch
            return error.InvalidDeadline;
        return @intCast(@min(rounded, std.math.maxInt(c_int)));
    }
};

pub const ConnectOutcome = enum { connected, in_progress };
pub const WaitKind = enum { readable, writable };
pub const WaitOutcome = enum { ready, interrupted, timed_out, failed };

pub const SocketErrorResult = union(enum) {
    value: c_int,
    failed,
};

pub const ConnectResult = union(enum) {
    outcome: ConnectOutcome,
    absent,
    denied,
    transient,
    failed,
};

pub const IoResult = union(enum) {
    count: usize,
    would_block,
    interrupted,
    eof,
    failed,
};

pub const Ops = struct {
    context: *anyopaque,
    socket: *const fn (context: *anyopaque) c.fd_t,
    set_cloexec: *const fn (context: *anyopaque, fd: c.fd_t) bool,
    get_flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    set_flags: *const fn (context: *anyopaque, fd: c.fd_t, flags: c_int) bool,
    set_nosigpipe: *const fn (context: *anyopaque, fd: c.fd_t) bool,
    connect: *const fn (context: *anyopaque, fd: c.fd_t, path: [:0]const u8) ConnectResult,
    wait: *const fn (
        context: *anyopaque,
        fd: c.fd_t,
        kind: WaitKind,
        timeout_ms: c_int,
    ) WaitOutcome,
    socket_error: *const fn (context: *anyopaque, fd: c.fd_t) SocketErrorResult,
    read: *const fn (context: *anyopaque, fd: c.fd_t, dst: []u8) IoResult,
    write: *const fn (context: *anyopaque, fd: c.fd_t, src: []const u8) IoResult,
    close: *const fn (context: *anyopaque, fd: c.fd_t) void,
};

pub const Connected = struct {
    fd: c.fd_t,
    saved_flags: c_int,

    pub fn restoreBlocking(self: Connected, ops: Ops) Error!void {
        if (!ops.set_flags(ops.context, self.fd, self.saved_flags)) return error.FlagFailed;
    }
};

pub fn connectUnixUntil(
    ops: Ops,
    path: [:0]const u8,
    deadline: AbsoluteDeadline,
) Error!Connected {
    if (deadline.remainingNs() <= 0) return error.Timeout;
    const fd = ops.socket(ops.context);
    if (fd < 0) return error.ConnectFailed;
    errdefer ops.close(ops.context, fd);

    if (!ops.set_cloexec(ops.context, fd)) return error.FlagFailed;
    const saved_flags = ops.get_flags(ops.context, fd) orelse return error.FlagFailed;
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (!ops.set_flags(ops.context, fd, saved_flags | nonblocking)) return error.FlagFailed;
    if (!ops.set_nosigpipe(ops.context, fd)) return error.SocketOptionFailed;

    const connect_result = ops.connect(ops.context, fd, path);
    if (deadline.remainingNs() <= 0) return error.Timeout;
    switch (connect_result) {
        .outcome => |outcome| {
            if (outcome == .connected) {
                return .{ .fd = fd, .saved_flags = saved_flags };
            }
        },
        .absent => return error.EndpointAbsent,
        .denied => return error.EndpointDenied,
        .transient => return error.EndpointTransient,
        .failed => return error.ConnectFailed,
    }

    while (true) {
        const timeout_ms = try deadline.pollTimeoutMs();
        const wait_result = ops.wait(ops.context, fd, .writable, timeout_ms);
        if (deadline.remainingNs() <= 0) return error.Timeout;
        switch (wait_result) {
            .interrupted => continue,
            .timed_out => return error.Timeout,
            .failed => return error.ConnectFailed,
            .ready => {},
        }
        const socket_error_result = ops.socket_error(ops.context, fd);
        if (deadline.remainingNs() <= 0) return error.Timeout;
        const socket_error_value = switch (socket_error_result) {
            .value => |value| value,
            .failed => return error.ConnectFailed,
        };
        if (socket_error_value == 0) return .{ .fd = fd, .saved_flags = saved_flags };
        const socket_error: posix.E = @enumFromInt(socket_error_value);
        return switch (classifyConnectErrno(socket_error)) {
            .absent => error.EndpointAbsent,
            .denied => error.EndpointDenied,
            .transient => error.EndpointTransient,
            .other => error.ConnectFailed,
        };
    }
}

pub fn writeAllUntil(
    ops: Ops,
    fd: c.fd_t,
    bytes: []const u8,
    deadline: AbsoluteDeadline,
) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (deadline.remainingNs() <= 0) return error.Timeout;
        const write_result = ops.write(ops.context, fd, bytes[offset..]);
        if (deadline.remainingNs() <= 0) return error.Timeout;
        switch (write_result) {
            .count => |count| {
                if (count == 0 or count > bytes.len - offset) return error.WriteFailed;
                offset += count;
            },
            .interrupted => continue,
            .would_block => try waitUntil(ops, fd, .writable, deadline),
            .eof, .failed => return error.WriteFailed,
        }
    }
}

pub fn readSomeUntil(
    ops: Ops,
    fd: c.fd_t,
    dst: []u8,
    deadline: AbsoluteDeadline,
) Error!usize {
    while (true) {
        if (deadline.remainingNs() <= 0) return error.Timeout;
        const read_result = ops.read(ops.context, fd, dst);
        if (deadline.remainingNs() <= 0) return error.Timeout;
        switch (read_result) {
            .count => |count| {
                if (count == 0 or count > dst.len) return error.ReadFailed;
                return count;
            },
            .interrupted => continue,
            .would_block => try waitUntil(ops, fd, .readable, deadline),
            .eof => return error.Closed,
            .failed => return error.ReadFailed,
        }
    }
}

/// Waits for a retry interval without manufacturing a new phase budget. `wake_at` is derived once,
/// so repeated EINTR cannot restart the delay. Reaching the parent phase boundary is always a
/// timeout; waking earlier after the requested delay is success.
pub fn waitBackoffUntil(
    ops: Ops,
    delay_ns: i128,
    deadline: AbsoluteDeadline,
) Error!void {
    if (delay_ns < 0) return error.InvalidDeadline;
    const started = deadline.nowNs();
    if (started >= deadline.expires_at_ns) return error.Timeout;
    const requested = std.math.add(i128, started, delay_ns) catch std.math.maxInt(i128);
    const wake_at = @min(requested, deadline.expires_at_ns);
    while (true) {
        const now = deadline.nowNs();
        if (now >= deadline.expires_at_ns) return error.Timeout;
        if (now >= wake_at) return;
        const remaining = wake_at - now;
        const rounded = std.math.divCeil(i128, remaining, std.time.ns_per_ms) catch
            return error.InvalidDeadline;
        const timeout_ms: c_int = @intCast(@min(rounded, std.math.maxInt(c_int)));
        const wait_result = ops.wait(ops.context, -1, .readable, timeout_ms);
        if (deadline.nowNs() >= deadline.expires_at_ns) return error.Timeout;
        switch (wait_result) {
            .interrupted => continue,
            .ready, .timed_out => {},
            .failed => return error.ConnectFailed,
        }
    }
}

fn waitUntil(
    ops: Ops,
    fd: c.fd_t,
    kind: WaitKind,
    deadline: AbsoluteDeadline,
) Error!void {
    while (true) {
        const timeout_ms = try deadline.pollTimeoutMs();
        const wait_result = ops.wait(ops.context, fd, kind, timeout_ms);
        if (deadline.remainingNs() <= 0) return error.Timeout;
        switch (wait_result) {
            .ready => return,
            .interrupted => continue,
            .timed_out => return error.Timeout,
            .failed => return if (kind == .readable) error.ReadFailed else error.WriteFailed,
        }
    }
}

const EndpointFailure = enum { absent, denied, transient, other };

fn classifyConnectErrno(err: posix.E) EndpointFailure {
    return switch (err) {
        .NOENT, .CONNREFUSED => .absent,
        .ACCES, .PERM => .denied,
        .INTR, .AGAIN, .TIMEDOUT, .INPROGRESS => .transient,
        else => .other,
    };
}

pub const posix_ops = Ops{
    .context = @ptrFromInt(1),
    .socket = PosixOps.socket,
    .set_cloexec = PosixOps.setCloseOnExec,
    .get_flags = PosixOps.getFlags,
    .set_flags = PosixOps.setFlags,
    .set_nosigpipe = PosixOps.setNoSigPipe,
    .connect = PosixOps.connect,
    .wait = PosixOps.wait,
    .socket_error = PosixOps.socketError,
    .read = PosixOps.read,
    .write = PosixOps.write,
    .close = PosixOps.close,
};

const PosixOps = struct {
    fn socket(_: *anyopaque) c.fd_t {
        return c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    }

    fn setCloseOnExec(_: *anyopaque, fd: c.fd_t) bool {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        return flags >= 0 and c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) == 0;
    }

    fn getFlags(_: *anyopaque, fd: c.fd_t) ?c_int {
        const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        return if (flags < 0) null else flags;
    }

    fn setFlags(_: *anyopaque, fd: c.fd_t, flags: c_int) bool {
        return c.fcntl(fd, c.F.SETFL, flags) == 0;
    }

    fn setNoSigPipe(_: *anyopaque, fd: c.fd_t) bool {
        if (builtin.os.tag != .macos) return true;
        const one: c_int = 1;
        return c.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.NOSIGPIPE,
            @ptrCast(&one),
            @sizeOf(c_int),
        ) == 0;
    }

    fn connect(_: *anyopaque, fd: c.fd_t, path: [:0]const u8) ConnectResult {
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        // Include the terminator in the fixed sockaddr_un path without importing the host
        // listener stack merely for its equivalent validation helper.
        if (path.len >= addr.path.len) return .denied;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        if (rc == 0) return .{ .outcome = .connected };
        const connect_errno = posix.errno(rc);
        if (connect_errno == .INPROGRESS) return .{ .outcome = .in_progress };
        return switch (classifyConnectErrno(connect_errno)) {
            .absent => .absent,
            .denied => .denied,
            .transient => .transient,
            .other => .failed,
        };
    }

    fn wait(
        _: *anyopaque,
        fd: c.fd_t,
        kind: WaitKind,
        timeout_ms: c_int,
    ) WaitOutcome {
        var poll_fd = [1]c.pollfd{.{
            .fd = fd,
            .events = if (kind == .readable) c.POLL.IN else c.POLL.OUT,
            .revents = 0,
        }};
        const rc = c.poll(@ptrCast(&poll_fd), 1, timeout_ms);
        if (rc > 0) {
            if (poll_fd[0].revents & c.POLL.NVAL != 0) return .failed;
            const requested: c_short = if (kind == .readable) c.POLL.IN else c.POLL.OUT;
            const terminal: c_short = c.POLL.ERR | c.POLL.HUP;
            if (poll_fd[0].revents & (requested | terminal) != 0)
                return .ready;
            return .failed;
        }
        if (rc == 0) return .timed_out;
        return if (posix.errno(rc) == .INTR) .interrupted else .failed;
    }

    fn socketError(_: *anyopaque, fd: c.fd_t) SocketErrorResult {
        var value: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.ERROR,
            @ptrCast(&value),
            &len,
        ) != 0 or len != @sizeOf(c_int)) return .failed;
        return .{ .value = value };
    }

    fn read(_: *anyopaque, fd: c.fd_t, dst: []u8) IoResult {
        const rc = c.read(fd, dst.ptr, dst.len);
        if (rc > 0) return .{ .count = @intCast(rc) };
        if (rc == 0) return .eof;
        return switch (posix.errno(rc)) {
            .INTR => .interrupted,
            .AGAIN => .would_block,
            else => .failed,
        };
    }

    fn write(_: *anyopaque, fd: c.fd_t, src: []const u8) IoResult {
        // macOS has no per-send MSG_NOSIGNAL. The connector sets SO_NOSIGPIPE once before
        // connect so every later write reports EPIPE instead of terminating the process.
        const rc = c.send(fd, src.ptr, src.len, 0);
        if (rc > 0) return .{ .count = @intCast(rc) };
        if (rc == 0) return .failed;
        return switch (posix.errno(rc)) {
            .INTR => .interrupted,
            .AGAIN => .would_block,
            else => .failed,
        };
    }

    fn close(_: *anyopaque, fd: c.fd_t) void {
        _ = c.close(fd);
    }
};

const Fake = struct {
    now_ns: i128 = 0,
    fd: c.fd_t = 7,
    flags: c_int = 0x20,
    connect_result: ConnectResult = .{ .outcome = .in_progress },
    waits: []const WaitOutcome = &.{.ready},
    wait_index: usize = 0,
    socket_error_result: SocketErrorResult = .{ .value = 0 },
    writes: []const IoResult = &.{},
    write_index: usize = 0,
    reads: []const IoResult = &.{},
    read_index: usize = 0,
    closed: usize = 0,
    set_flags_calls: usize = 0,
    set_flags_fail_at: ?usize = null,
    last_set_flags: c_int = 0,
    get_flags_ok: bool = true,
    cloexec_ok: bool = true,
    cloexec_calls: usize = 0,
    nosigpipe_calls: usize = 0,
    nosigpipe_ok: bool = true,
    advance_ns_per_wait: i128 = 0,
    advance_ns_per_connect: i128 = 0,
    advance_ns_per_socket_error: i128 = 0,
    advance_ns_per_read: i128 = 0,
    advance_ns_per_write: i128 = 0,
    write_lengths: [8]usize = @splat(0),
    write_length_count: usize = 0,

    fn clock(ctx: *anyopaque) i128 {
        return cast(ctx).now_ns;
    }

    fn ops(self: *Fake) Ops {
        return .{
            .context = self,
            .socket = fakeSocket,
            .set_cloexec = fakeSetCloseOnExec,
            .get_flags = fakeGetFlags,
            .set_flags = fakeSetFlags,
            .set_nosigpipe = fakeNoSigPipe,
            .connect = fakeConnect,
            .wait = fakeWait,
            .socket_error = fakeSocketError,
            .read = fakeRead,
            .write = fakeWrite,
            .close = fakeClose,
        };
    }

    fn deadline(self: *Fake, expires_at_ns: i128) AbsoluteDeadline {
        return .fromInjected(.{ .context = self, .now_ns = clock }, expires_at_ns);
    }

    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn fakeSocket(ctx: *anyopaque) c.fd_t {
        return cast(ctx).fd;
    }
    fn fakeSetCloseOnExec(ctx: *anyopaque, _: c.fd_t) bool {
        const self = cast(ctx);
        self.cloexec_calls += 1;
        return self.cloexec_ok;
    }
    fn fakeGetFlags(ctx: *anyopaque, _: c.fd_t) ?c_int {
        const self = cast(ctx);
        return if (self.get_flags_ok) self.flags else null;
    }
    fn fakeSetFlags(ctx: *anyopaque, _: c.fd_t, flags: c_int) bool {
        const self = cast(ctx);
        self.set_flags_calls += 1;
        self.last_set_flags = flags;
        if (self.set_flags_fail_at) |call| if (self.set_flags_calls == call) return false;
        return true;
    }
    fn fakeNoSigPipe(ctx: *anyopaque, _: c.fd_t) bool {
        const self = cast(ctx);
        self.nosigpipe_calls += 1;
        return self.nosigpipe_ok;
    }
    fn fakeConnect(ctx: *anyopaque, _: c.fd_t, _: [:0]const u8) ConnectResult {
        const self = cast(ctx);
        self.now_ns += self.advance_ns_per_connect;
        return self.connect_result;
    }
    fn fakeWait(ctx: *anyopaque, _: c.fd_t, _: WaitKind, _: c_int) WaitOutcome {
        const self = cast(ctx);
        if (self.wait_index >= self.waits.len) return .timed_out;
        const result = self.waits[self.wait_index];
        self.wait_index += 1;
        self.now_ns += self.advance_ns_per_wait;
        return result;
    }
    fn fakeSocketError(ctx: *anyopaque, _: c.fd_t) SocketErrorResult {
        const self = cast(ctx);
        self.now_ns += self.advance_ns_per_socket_error;
        return self.socket_error_result;
    }
    fn fakeRead(ctx: *anyopaque, _: c.fd_t, _: []u8) IoResult {
        const self = cast(ctx);
        self.now_ns += self.advance_ns_per_read;
        if (self.read_index >= self.reads.len) return .would_block;
        const result = self.reads[self.read_index];
        self.read_index += 1;
        return result;
    }
    fn fakeWrite(ctx: *anyopaque, _: c.fd_t, src: []const u8) IoResult {
        const self = cast(ctx);
        self.now_ns += self.advance_ns_per_write;
        if (self.write_length_count < self.write_lengths.len) {
            self.write_lengths[self.write_length_count] = src.len;
            self.write_length_count += 1;
        }
        if (self.write_index >= self.writes.len) return .would_block;
        const result = self.writes[self.write_index];
        self.write_index += 1;
        return result;
    }
    fn fakeClose(ctx: *anyopaque, _: c.fd_t) void {
        cast(ctx).closed += 1;
    }
};

test "deadline connector completes EINPROGRESS only after readiness and SO_ERROR" {
    var fake = Fake{ .waits = &.{ .interrupted, .ready } };
    const connected = try connectUnixUntil(fake.ops(), "socket", fake.deadline(100));
    try std.testing.expectEqual(fake.fd, connected.fd);
    try std.testing.expectEqual(fake.flags, connected.saved_flags);
    try std.testing.expectEqual(@as(usize, 2), fake.wait_index);
    try std.testing.expectEqual(@as(usize, 1), fake.nosigpipe_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.cloexec_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.closed);
    try connected.restoreBlocking(fake.ops());
    try std.testing.expectEqual(@as(usize, 2), fake.set_flags_calls);
    try std.testing.expectEqual(fake.flags, fake.last_set_flags);
}

test "deadline connector closes exact fd on timeout denial and SO_ERROR" {
    var timeout = Fake{ .waits = &.{.timed_out} };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(timeout.ops(), "socket", timeout.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), timeout.closed);

    var denied = Fake{ .connect_result = .denied };
    try std.testing.expectError(
        error.EndpointDenied,
        connectUnixUntil(denied.ops(), "socket", denied.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), denied.closed);

    var refused = Fake{ .socket_error_result = .{ .value = @intFromEnum(posix.E.CONNREFUSED) } };
    try std.testing.expectError(
        error.EndpointAbsent,
        connectUnixUntil(refused.ops(), "socket", refused.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), refused.closed);

    var so_error_failed = Fake{ .socket_error_result = .failed };
    try std.testing.expectError(
        error.ConnectFailed,
        connectUnixUntil(so_error_failed.ops(), "socket", so_error_failed.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), so_error_failed.closed);

    var ready_at_boundary = Fake{
        .waits = &.{.ready},
        .advance_ns_per_wait = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(
            ready_at_boundary.ops(),
            "socket",
            ready_at_boundary.deadline(100),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), ready_at_boundary.closed);

    var immediate_at_boundary = Fake{
        .connect_result = .{ .outcome = .connected },
        .advance_ns_per_connect = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(
            immediate_at_boundary.ops(),
            "socket",
            immediate_at_boundary.deadline(100),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), immediate_at_boundary.closed);

    var denied_at_boundary = Fake{
        .connect_result = .denied,
        .advance_ns_per_connect = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(
            denied_at_boundary.ops(),
            "socket",
            denied_at_boundary.deadline(100),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), denied_at_boundary.closed);

    var poll_failure_at_boundary = Fake{
        .waits = &.{.failed},
        .advance_ns_per_wait = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(
            poll_failure_at_boundary.ops(),
            "socket",
            poll_failure_at_boundary.deadline(100),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), poll_failure_at_boundary.closed);

    var socket_error_failure_at_boundary = Fake{
        .waits = &.{.ready},
        .socket_error_result = .failed,
        .advance_ns_per_socket_error = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        connectUnixUntil(
            socket_error_failure_at_boundary.ops(),
            "socket",
            socket_error_failure_at_boundary.deadline(100),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), socket_error_failure_at_boundary.closed);
}

test "deadline connector closes on every pre-connect fd option failure" {
    var cloexec = Fake{ .cloexec_ok = false };
    try std.testing.expectError(
        error.FlagFailed,
        connectUnixUntil(cloexec.ops(), "socket", cloexec.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), cloexec.closed);

    var get_flags = Fake{ .get_flags_ok = false };
    try std.testing.expectError(
        error.FlagFailed,
        connectUnixUntil(get_flags.ops(), "socket", get_flags.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), get_flags.closed);

    var set_flags = Fake{ .set_flags_fail_at = 1 };
    try std.testing.expectError(
        error.FlagFailed,
        connectUnixUntil(set_flags.ops(), "socket", set_flags.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), set_flags.closed);

    var nosigpipe = Fake{ .nosigpipe_ok = false };
    try std.testing.expectError(
        error.SocketOptionFailed,
        connectUnixUntil(nosigpipe.ops(), "socket", nosigpipe.deadline(100)),
    );
    try std.testing.expectEqual(@as(usize, 1), nosigpipe.closed);
}

test "deadline established I/O preserves partial offsets and absolute timeout" {
    var fake = Fake{
        .writes = &.{
            .{ .count = 2 },
            .would_block,
            .interrupted,
            .{ .count = 3 },
        },
        .waits = &.{ .ready, .ready },
        .reads = &.{ .would_block, .interrupted, .{ .count = 4 } },
    };
    try writeAllUntil(fake.ops(), fake.fd, "hello", fake.deadline(100));
    try std.testing.expectEqualSlices(
        usize,
        &.{ 5, 3, 3, 3 },
        fake.write_lengths[0..fake.write_length_count],
    );
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try readSomeUntil(
        fake.ops(),
        fake.fd,
        &buf,
        fake.deadline(100),
    ));

    fake.now_ns = 100;
    try std.testing.expectError(
        error.Timeout,
        writeAllUntil(fake.ops(), fake.fd, "x", fake.deadline(100)),
    );

    var drip = Fake{
        .writes = &.{ .{ .count = 1 }, .would_block, .{ .count = 1 } },
        .waits = &.{.ready},
        .advance_ns_per_wait = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        writeAllUntil(drip.ops(), drip.fd, "ab", drip.deadline(100)),
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{ 2, 1 },
        drip.write_lengths[0..drip.write_length_count],
    );

    var final_write_at_boundary = Fake{
        .writes = &.{.{ .count = 2 }},
        .advance_ns_per_write = 100,
    };
    try std.testing.expectError(
        error.Timeout,
        writeAllUntil(
            final_write_at_boundary.ops(),
            final_write_at_boundary.fd,
            "ab",
            final_write_at_boundary.deadline(100),
        ),
    );

    var final_read_at_boundary = Fake{
        .reads = &.{.{ .count = 1 }},
        .advance_ns_per_read = 100,
    };
    var one: [1]u8 = undefined;
    try std.testing.expectError(
        error.Timeout,
        readSomeUntil(
            final_read_at_boundary.ops(),
            final_read_at_boundary.fd,
            &one,
            final_read_at_boundary.deadline(100),
        ),
    );
}

test "deadline backoff does not restart after EINTR or cross the phase boundary" {
    var interrupted = Fake{
        .waits = &.{ .interrupted, .timed_out },
        .advance_ns_per_wait = 3,
    };
    try waitBackoffUntil(interrupted.ops(), 5, interrupted.deadline(100));
    try std.testing.expectEqual(@as(usize, 2), interrupted.wait_index);
    try std.testing.expectEqual(@as(i128, 6), interrupted.now_ns);

    var capped = Fake{
        .waits = &.{.timed_out},
        .advance_ns_per_wait = 5,
    };
    try std.testing.expectError(
        error.Timeout,
        waitBackoffUntil(capped.ops(), 100, capped.deadline(5)),
    );
    try std.testing.expectEqual(@as(usize, 1), capped.wait_index);
}

const LimitedSocketOps = struct {
    max_read: usize,
    max_write: usize,

    fn ops(self: *LimitedSocketOps) Ops {
        var result = posix_ops;
        result.context = self;
        result.read = read;
        result.write = write;
        return result;
    }

    fn cast(ctx: *anyopaque) *LimitedSocketOps {
        return @ptrCast(@alignCast(ctx));
    }

    fn read(ctx: *anyopaque, fd: c.fd_t, dst: []u8) IoResult {
        const self = cast(ctx);
        return posix_ops.read(posix_ops.context, fd, dst[0..@min(dst.len, self.max_read)]);
    }

    fn write(ctx: *anyopaque, fd: c.fd_t, src: []const u8) IoResult {
        const self = cast(ctx);
        return posix_ops.write(posix_ops.context, fd, src[0..@min(src.len, self.max_write)]);
    }
};

const ConnectedPairOps = struct {
    fd: c.fd_t,

    fn ops(self: *ConnectedPairOps) Ops {
        var result = posix_ops;
        result.context = self;
        result.socket = socket;
        result.connect = connect;
        return result;
    }

    fn cast(ctx: *anyopaque) *ConnectedPairOps {
        return @ptrCast(@alignCast(ctx));
    }

    fn socket(ctx: *anyopaque) c.fd_t {
        return cast(ctx).fd;
    }

    fn connect(_: *anyopaque, _: c.fd_t, _: [:0]const u8) ConnectResult {
        return .{ .outcome = .connected };
    }
};

test "deadline established I/O uses real socketpair with partial reads and writes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const current = c.fcntl(fds[0], c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(current >= 0);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fds[0], c.F.SETFL, current | nonblocking));

    var limited = LimitedSocketOps{ .max_read = 2, .max_write = 2 };
    const deadline = try AbsoluteDeadline.after(std.testing.io, 5 * std.time.ns_per_s);
    try writeAllUntil(limited.ops(), fds[0], "abcdef", deadline);
    var received: [6]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 6), c.read(fds[1], &received, received.len));
    try std.testing.expectEqualStrings("abcdef", &received);

    try std.testing.expectEqual(@as(isize, 4), c.write(fds[1], "wxyz", 4));
    var first: [4]u8 = undefined;
    const first_count = try readSomeUntil(limited.ops(), fds[0], &first, deadline);
    try std.testing.expectEqual(@as(usize, 2), first_count);
    const second_count = try readSomeUntil(limited.ops(), fds[0], first[first_count..], deadline);
    try std.testing.expectEqual(@as(usize, 2), second_count);
    try std.testing.expectEqualStrings("wxyz", &first);

    const timeout = try AbsoluteDeadline.after(std.testing.io, std.time.ns_per_ms);
    try std.testing.expectError(
        error.Timeout,
        readSomeUntil(limited.ops(), fds[0], &first, timeout),
    );
}

test "deadline connector SO_NOSIGPIPE turns peer close into write error" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var client_open = true;
    defer {
        if (client_open) _ = c.close(fds[0]);
    }
    var peer_open = true;
    defer {
        if (peer_open) _ = c.close(fds[1]);
    }
    var pair = ConnectedPairOps{ .fd = fds[0] };
    const deadline = try AbsoluteDeadline.after(std.testing.io, 5 * std.time.ns_per_s);
    const connected = try connectUnixUntil(pair.ops(), "socket", deadline);
    client_open = false;
    _ = c.close(fds[1]);
    peer_open = false;
    try std.testing.expectError(
        error.WriteFailed,
        writeAllUntil(pair.ops(), connected.fd, "must-not-sigpipe", deadline),
    );
    pair.ops().close(pair.ops().context, connected.fd);
}
