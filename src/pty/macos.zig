const std = @import("std");
const terminal = @import("../terminal.zig");
const types = @import("types.zig");

// macOS의 첫 backend는 openpty로 master/slave fd만 만들고 fork/exec는 직접 한다.
// 이 경계가 있어야 cwd/env/stdio/controlling-terminal 실패를 단계별 artifact로 남길 수 있다.
extern "c" fn openpty(
    amaster: *std.c.fd_t,
    aslave: *std.c.fd_t,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*std.posix.winsize,
) c_int;

// Used by the session-close grace window between escalation signals.
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

const tio_cs_ctty: c_int = 0x20007461;
const tio_cs_winsz: c_int = @bitCast(@as(u32, 0x80087467));

pub const PtySession = struct {
    master_fd: std.posix.fd_t,
    child_pid: std.c.pid_t,
    size: terminal.Size,
    exited: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, request: types.SpawnRequest) !PtySession {
        try validateRequest(request);

        const command_z = try allocator.dupeZ(u8, request.command);
        defer allocator.free(command_z);

        const cwd_z = if (request.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
        defer if (cwd_z) |cwd| allocator.free(cwd);

        var argv_storage = try ArgvStorage.init(allocator, request);
        defer argv_storage.deinit();

        var env_storage = try EnvStorage.init(allocator, request.env);
        defer env_storage.deinit();

        var window_size = winsizeFromTerminalSize(request.size);
        var master_fd: std.c.fd_t = undefined;
        var slave_fd: std.c.fd_t = undefined;
        if (openpty(&master_fd, &slave_fd, null, null, &window_size) < 0) return error.OpenptyFailed;
        errdefer {
            closeFd(master_fd);
            closeFd(slave_fd);
        }

        try setCloseOnExec(master_fd);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            childExec(command_z, argv_storage.argv.ptr, env_storage.envpPtr(), cwd_z, master_fd, slave_fd);
        }

        closeFd(slave_fd);
        return .{
            .master_fd = master_fd,
            .child_pid = pid,
            .size = request.size,
        };
    }

    pub fn deinit(self: *PtySession) void {
        if (self.master_fd >= 0) {
            closeFd(self.master_fd);
            self.master_fd = -1;
        }
        if (!self.exited) {
            shutdownChild(self.child_pid);
        }
        self.* = undefined;
    }

    pub fn readEvent(self: *PtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        if (self.exited) return error.NoMoreEvents;

        var buffer: [4096]u8 = undefined;
        const read_len = std.posix.read(self.master_fd, &buffer) catch |err| switch (err) {
            // PTY EOF is reported as EIO on some Unix implementations after
            // the slave side closes. Treat it the same as a zero-byte read so
            // callers do not need OS-specific EOF rules.
            error.InputOutput => 0,
            else => return err,
        };

        if (read_len > 0) {
            const owned = try allocator.dupe(u8, buffer[0..read_len]);
            return .{ .output = owned };
        }

        // Reap before latching `exited`: if waitForChild fails we must leave the
        // session un-exited so deinit still attempts to reap the child instead of
        // leaking it and silently dropping the exit status.
        const status = try waitForChild(self.child_pid);
        self.exited = true;
        return .{ .exited = status };
    }

    pub fn writeInput(self: *PtySession, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try writeFd(self.master_fd, bytes[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    pub fn resize(self: *PtySession, size: terminal.Size) !void {
        var window_size = winsizeFromTerminalSize(size);
        if (std.c.ioctl(self.master_fd, tio_cs_winsz, &window_size) < 0) return error.IoctlFailed;
        self.size = size;
    }

    pub fn currentSize(self: *PtySession) !terminal.Size {
        var window_size: std.posix.winsize = undefined;
        if (std.c.ioctl(self.master_fd, std.c.T.IOCGWINSZ, &window_size) < 0) return error.IoctlFailed;
        return .{ .cols = window_size.col, .rows = window_size.row };
    }
};

// execve는 argv 문자열들이 child가 exec될 때까지 유효해야 한다.
// 그래서 request의 slice를 그대로 빌려 쓰지 않고, null-terminated 복사본을 session spawn 중에 보관한다.
const ArgvStorage = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    argv: [:null]?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, request: types.SpawnRequest) !ArgvStorage {
        const argc = 1 + request.args.len;
        const strings = try allocator.alloc([:0]u8, argc);
        errdefer allocator.free(strings);

        var initialized: usize = 0;
        errdefer {
            for (strings[0..initialized]) |owned| allocator.free(owned);
        }

        strings[0] = try allocator.dupeZ(u8, request.command);
        initialized += 1;

        for (request.args, 0..) |arg, index| {
            strings[index + 1] = try allocator.dupeZ(u8, arg);
            initialized += 1;
        }

        const argv = try allocator.allocSentinel(?[*:0]const u8, argc, null);
        errdefer allocator.free(argv);
        for (strings, 0..) |arg, index| argv[index] = arg.ptr;

        return .{ .allocator = allocator, .strings = strings, .argv = argv };
    }

    fn deinit(self: *ArgvStorage) void {
        for (self.strings) |arg| self.allocator.free(arg);
        self.allocator.free(self.strings);
        self.allocator.free(self.argv);
    }
};

// env가 비어 있으면 부모 환경을 그대로 상속한다.
// 명시 env가 있으면 execve가 요구하는 null-terminated envp 배열로 바꿔 child에게만 전달한다.
const EnvStorage = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    envp: ?[:null]?[*:0]const u8,
    uses_parent: bool,

    fn init(allocator: std.mem.Allocator, env: []const []const u8) !EnvStorage {
        if (env.len == 0) {
            return .{
                .allocator = allocator,
                .strings = &.{},
                .envp = null,
                .uses_parent = true,
            };
        }

        const strings = try allocator.alloc([:0]u8, env.len);
        errdefer allocator.free(strings);

        var initialized: usize = 0;
        errdefer {
            for (strings[0..initialized]) |owned| allocator.free(owned);
        }

        for (env, 0..) |entry, index| {
            strings[index] = try allocator.dupeZ(u8, entry);
            initialized += 1;
        }

        const envp = try allocator.allocSentinel(?[*:0]const u8, env.len, null);
        errdefer allocator.free(envp);
        for (strings, 0..) |entry, index| envp[index] = entry.ptr;

        return .{
            .allocator = allocator,
            .strings = strings,
            .envp = envp,
            .uses_parent = false,
        };
    }

    fn deinit(self: *EnvStorage) void {
        if (self.uses_parent) return;
        for (self.strings) |entry| self.allocator.free(entry);
        self.allocator.free(self.strings);
        self.allocator.free(self.envp.?);
    }

    fn envpPtr(self: *const EnvStorage) [*:null]const ?[*:0]const u8 {
        if (self.uses_parent) return std.c.environ;
        return self.envp.?.ptr;
    }
};

fn validateRequest(request: types.SpawnRequest) !void {
    if (request.command.len == 0) return error.EmptyCommand;
    if (request.size.cols == 0 or request.size.rows == 0) return error.InvalidSize;
    for (request.env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=') == null) return error.InvalidEnvironmentEntry;
    }
}

fn childExec(
    command: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[:0]const u8,
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
) noreturn {
    // Child process에서는 Zig error를 부모에게 안전하게 돌려줄 수 없다.
    // 실패 지점별로 보수적인 exit code를 남기고 즉시 종료해 parent가 lifecycle event로 관측하게 한다.
    if (std.c.setsid() < 0) std.c._exit(126);
    if (std.c.ioctl(slave_fd, tio_cs_ctty, @as(c_int, 0)) < 0) std.c._exit(126);
    if (cwd) |dir| {
        if (std.c.chdir(dir.ptr) < 0) std.c._exit(126);
    }
    if (std.c.dup2(slave_fd, 0) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 1) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 2) < 0) std.c._exit(126);

    _ = std.c.close(master_fd);
    if (slave_fd > 2) _ = std.c.close(slave_fd);

    _ = std.c.execve(command.ptr, argv, envp);
    std.c._exit(127);
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    // master fd는 parent runtime만 소유해야 한다. exec된 child에게 새면 EOF/exit 감지가 늦어질 수 있다.
    const flags = std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(fd, std.c.F.SETFD, flags | std.c.FD_CLOEXEC) < 0) return error.FcntlFailed;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return @intCast(rc);

        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return error.WriteFailed;
    }
}

// Closing a session whose child is still alive escalates SIGHUP -> SIGTERM ->
// SIGKILL, giving the child a bounded grace window to exit (and run shell close
// traps) at each step before forcing the next. SIGKILL cannot be caught, so the
// final blocking reap is guaranteed to make progress and the child can never be
// left as a zombie. This is intentionally synchronous in deinit; the reader
// thread step can move it off the close path later.
const shutdown_grace_attempts = 6;
const shutdown_grace_interval_ms = 10;

fn shutdownChild(pid: std.c.pid_t) void {
    if (pid <= 0) return;

    if (signalAndReap(pid, .HUP)) return;
    if (signalAndReap(pid, .TERM)) return;

    // Last resort: SIGKILL is uncatchable, so the child must terminate and the
    // blocking reap below cannot hang or leave a zombie behind.
    _ = std.c.kill(-pid, .KILL);
    _ = std.c.kill(pid, .KILL);
    reapBlocking(pid);
}

// Sends `sig` to the child's process group (setsid made it a leader) and to the
// child directly, then polls a bounded grace window. Returns true once the child
// has been reaped or is already gone, false if it is still alive after the
// window so the caller can escalate.
fn signalAndReap(pid: std.c.pid_t, sig: std.c.SIG) bool {
    _ = std.c.kill(-pid, sig);
    _ = std.c.kill(pid, sig);

    var attempt: usize = 0;
    while (attempt < shutdown_grace_attempts) : (attempt += 1) {
        if (tryReap(pid) != .alive) return true;
        sleepMillis(shutdown_grace_interval_ms);
    }
    return tryReap(pid) != .alive;
}

const ReapResult = enum { reaped, alive, gone };

fn tryReap(pid: std.c.pid_t) ReapResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return .reaped;
        if (rc == 0) return .alive;

        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        // ECHILD (already reaped) or any other error: nothing left to wait on.
        return .gone;
    }
}

fn reapBlocking(pid: std.c.pid_t) void {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc == pid) return;
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return; // ECHILD etc.: nothing to reap.
        }
        return; // rc == 0 needs WNOHANG; guard against an unexpected spin.
    }
}

fn sleepMillis(ms: u32) void {
    const req: std.c.timespec = .{
        .sec = 0,
        .nsec = @intCast(@as(u64, ms) * std.time.ns_per_ms),
    };
    // Best-effort grace delay; an EINTR just shortens this window, which is fine.
    _ = nanosleep(&req, null);
}

fn waitForChild(pid: std.c.pid_t) !types.ExitStatus {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc == pid) return decodeExitStatus(status);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return error.WaitPidFailed;
        }
    }
}

fn decodeExitStatus(status: c_int) types.ExitStatus {
    // macOS sys/wait.h: _WSTATUS(x) = x & 0x7f selects exit vs signal vs stop.
    const wstatus = status & 0x7f;
    // WIFEXITED: low 7 bits are 0 → normal exit, code in bits 8..15.
    if (wstatus == 0) {
        return .{ .exited = @intCast((status >> 8) & 0xff) };
    }
    // WIFSTOPPED: low 7 bits are 0x7f. waitForChild does not pass WUNTRACED so a
    // stopped child is not expected here; report it as unknown rather than as a
    // bogus terminating signal 0x7f.
    if (wstatus == 0x7f) {
        return .{ .unknown = status };
    }
    // WIFSIGNALED: terminating signal in the low 7 bits.
    return .{ .signaled = @intCast(wstatus) };
}

fn winsizeFromTerminalSize(size: terminal.Size) std.posix.winsize {
    return .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
}

test "decodeExitStatus reports normal exit code" {
    try std.testing.expectEqual(types.ExitStatus{ .exited = 7 }, decodeExitStatus(7 << 8));
}

test "decodeExitStatus reports a terminating signal" {
    // Killed by SIGKILL(9): low 7 bits hold the signal, with or without the
    // 0x80 core-dump flag.
    try std.testing.expectEqual(types.ExitStatus{ .signaled = 9 }, decodeExitStatus(9));
    try std.testing.expectEqual(types.ExitStatus{ .signaled = 9 }, decodeExitStatus(0x80 | 9));
}

test "decodeExitStatus reports a stopped child as unknown" {
    // WIFSTOPPED status (low 7 bits == 0x7f) must not be mistaken for signal 0x7f.
    try std.testing.expectEqual(types.ExitStatus{ .unknown = 0x137f }, decodeExitStatus(0x137f));
}

test "validateRequest rejects requests that cannot produce a reliable PTY" {
    // Invalid spawn input should fail before openpty/fork so tests and users do
    // not get half-created child processes with confusing lifecycle artifacts.
    try std.testing.expectError(
        error.EmptyCommand,
        validateRequest(.{ .command = "" }),
    );
    try std.testing.expectError(
        error.InvalidSize,
        validateRequest(.{ .command = "/bin/sh", .size = .{ .cols = 0, .rows = 24 } }),
    );
    try std.testing.expectError(
        error.InvalidEnvironmentEntry,
        validateRequest(.{ .command = "/bin/sh", .env = &.{"NOT_AN_ENV_PAIR"} }),
    );
}
