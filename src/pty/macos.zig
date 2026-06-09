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

// master fd에 요청하는 입력 이벤트는 readable(POLL.IN)뿐이다. HUP/ERR/NVAL은
// output-only 플래그라 events에 넣어도 무시되고 revents로만 전달된다.
const poll_in_events: i16 = @intCast(std.posix.POLL.IN);
const poll_readable_revents: i16 = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR);

pub const PtySession = struct {
    master_fd: std.atomic.Value(std.posix.fd_t),
    child_pid: std.c.pid_t,
    size: terminal.Size,
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reaping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // close()가 reader thread의 blocking poll을 즉시 깨우기 위한 self-pipe.
    // wake_write로 1바이트를 보내면 poll이 곧바로 반환하므로 timeout 폴링 없이
    // close를 관측한다(close 지연 ~0, 출력 없는 pane의 주기적 wakeup 0).
    // master_fd는 reader가 끝난(join) 뒤 deinit에서만 닫아 fd 재사용 레이스를 없앤다.
    wake_read_fd: std.posix.fd_t,
    wake_write_fd: std.atomic.Value(std.posix.fd_t),

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

        // close()가 blocking poll을 깨우는 self-pipe. child에게 새지 않도록 양 끝을
        // close-on-exec로 둔다(exec 시 닫히고, 다른 session spawn에도 상속되지 않는다).
        var wake_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&wake_fds) != 0) return error.PipeFailed;
        errdefer {
            closeFd(wake_fds[0]);
            closeFd(wake_fds[1]);
        }
        try setCloseOnExec(wake_fds[0]);
        try setCloseOnExec(wake_fds[1]);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            childExec(command_z, argv_storage.argv.ptr, env_storage.envpPtr(), cwd_z, master_fd, slave_fd);
        }

        closeFd(slave_fd);
        return .{
            .master_fd = std.atomic.Value(std.posix.fd_t).init(master_fd),
            .child_pid = pid,
            .size = request.size,
            .wake_read_fd = wake_fds[0],
            .wake_write_fd = std.atomic.Value(std.posix.fd_t).init(wake_fds[1]),
        };
    }

    pub fn close(self: *PtySession) void {
        // close는 reader thread를 깨우고 child를 정리하는 lifecycle API다.
        // deinit처럼 객체를 undefined로 만들지 않기 때문에 app은 close -> reader.join
        // -> deinit 순서로 안전하게 종료할 수 있다. master fd는 여기서 닫지 않고
        // deinit(=join 이후)에서 닫는다. reader가 아직 그 fd 번호로 poll/read 중일 때
        // 닫으면 OS가 번호를 재사용해 reader가 엉뚱한 fd를 읽을 수 있기 때문이다.
        self.closing.store(true, .release);

        // closing을 올린 뒤 self-pipe로 reader의 blocking poll을 즉시 깨운다.
        self.signalWake();

        if (!self.exited.load(.acquire) and !self.reaping.swap(true, .acq_rel)) {
            shutdownChild(self.child_pid);
            self.exited.store(true, .release);
        }
    }

    pub fn deinit(self: *PtySession) void {
        // reader가 이미 join된 상태에서만 호출되는 단계라(close -> join -> deinit),
        // 여기서 비로소 master fd와 self-pipe를 닫는다.
        self.close();

        const fd = self.master_fd.swap(-1, .acq_rel);
        if (fd >= 0) closeFd(fd);

        const wake_write = self.wake_write_fd.swap(-1, .acq_rel);
        if (wake_write >= 0) closeFd(wake_write);
        closeFd(self.wake_read_fd);

        self.* = undefined;
    }

    fn signalWake(self: *PtySession) void {
        const fd = self.wake_write_fd.load(.acquire);
        if (fd < 0) return;
        // 1바이트만 보내면 충분하다. close는 많아야 두 번(stopAndJoin + deinit)
        // 호출되고 pipe 버퍼는 넉넉하므로 가득 차 blocking될 일은 없다.
        var byte = [_]u8{0};
        while (true) {
            const rc = std.c.write(fd, &byte, byte.len);
            if (rc >= 0) return;
            if (std.posix.errno(rc) == .INTR) continue;
            return; // best-effort: 이미 신호됐거나 닫힌 경우는 무시한다.
        }
    }

    pub fn readEvent(self: *PtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        if (self.exited.load(.acquire)) return error.NoMoreEvents;
        const fd = self.activeMasterFd() catch return error.SessionClosed;
        try self.waitReadableOrClosing(fd);

        var buffer: [4096]u8 = undefined;
        const read_len = std.posix.read(fd, &buffer) catch |err| switch (err) {
            // PTY EOF is reported as EIO on some Unix implementations after
            // the slave side closes. Treat it the same as a zero-byte read so
            // callers do not need OS-specific EOF rules.
            error.InputOutput => 0,
            else => {
                if (self.closing.load(.acquire)) return error.SessionClosed;
                return err;
            },
        };

        if (read_len > 0) {
            const owned = try allocator.dupe(u8, buffer[0..read_len]);
            return .{ .output = owned };
        }

        // EOF. Reap the child, but never block in a bare waitpid so close() can
        // always interrupt us. The child has usually exited already (that is what
        // produced the EOF), so the non-blocking reap below returns immediately. If
        // the child only closed its stdio but keeps running, wait for its real exit
        // through kqueue NOTE_EXIT (or a close wake) instead of a blocking waitpid.
        while (true) {
            if (self.closing.load(.acquire)) return error.SessionClosed;
            // reaping을 잡는 건 close()와 double-reap을 피하기 위해서다. WNOHANG가
            // 실패하거나 아직 살아 있으면 다시 풀어줘 close()/deinit이 거둘 수 있게 한다.
            if (self.reaping.swap(true, .acq_rel)) return error.SessionClosed;

            const reaped = reapNoHang(self.child_pid) catch |err| {
                self.reaping.store(false, .release);
                return err;
            };
            if (reaped) |status| {
                self.exited.store(true, .release);
                return .{ .exited = status };
            }

            // child가 stdio만 닫고 계속 살아 있다(드문 daemonize 경우). reap 권한을
            // 돌려주고, 실제 종료나 close가 올 때까지 kqueue로 기다린다.
            self.reaping.store(false, .release);
            try self.waitChildExitOrClosing();
        }
    }

    pub fn writeInput(self: *PtySession, bytes: []const u8) !void {
        const fd = try self.activeMasterFd();
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try writeFd(fd, bytes[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    pub fn resize(self: *PtySession, size: terminal.Size) !void {
        const fd = try self.activeMasterFd();
        var window_size = winsizeFromTerminalSize(size);
        if (std.c.ioctl(fd, tio_cs_winsz, &window_size) < 0) return error.IoctlFailed;
        self.size = size;
    }

    pub fn currentSize(self: *PtySession) !terminal.Size {
        const fd = try self.activeMasterFd();
        var window_size: std.posix.winsize = undefined;
        if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, &window_size) < 0) return error.IoctlFailed;
        return .{ .cols = window_size.col, .rows = window_size.row };
    }

    fn activeMasterFd(self: *PtySession) !std.posix.fd_t {
        // close()는 master fd를 닫지 않고 closing 플래그만 올린다(close 주석 참고).
        // 그래서 닫힌 세션 여부는 fd 음수가 아니라 closing으로 판단한다.
        if (self.closing.load(.acquire)) return error.SessionClosed;
        const fd = self.master_fd.load(.acquire);
        if (fd < 0) return error.SessionClosed;
        return fd;
    }

    fn waitReadableOrClosing(self: *PtySession, fd: std.posix.fd_t) !void {
        while (true) {
            if (self.closing.load(.acquire)) return error.SessionClosed;

            var fds = [_]std.posix.pollfd{
                .{ .fd = fd, .events = poll_in_events, .revents = 0 },
                .{ .fd = self.wake_read_fd, .events = poll_in_events, .revents = 0 },
            };
            // timeout -1: master fd가 readable이 되거나 close()가 self-pipe로
            // 깨울 때까지 무한 대기한다. 출력 없는 pane은 주기적 wakeup 없이 잠든다.
            _ = try std.posix.poll(&fds, -1);

            // wake/close를 master-readable보다 먼저 확인한다. close()가 막 닫고
            // 재사용된 fd가 readable로 보여도 엉뚱한 read로 새지 않게 한다.
            if (self.closing.load(.acquire)) return error.SessionClosed;
            if (fds[1].revents != 0) return error.SessionClosed;

            const revents = fds[0].revents;
            if ((revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) return error.PollFailed;
            if ((revents & poll_readable_revents) != 0) return;
        }
    }

    // EOF를 봤지만 child가 아직 살아 있을 때(stdio만 닫은 daemonize 경우) 호출한다.
    // bare blocking waitpid 대신 kqueue로 child의 실제 종료(EVFILT_PROC/NOTE_EXIT)와
    // close의 self-pipe wake(EVFILT_READ)를 함께 기다린다. 그래서 child가 끝내 종료하지
    // 않아도 close()/stopAndJoin이 우리를 깨워 join이 멈추지 않는다.
    fn waitChildExitOrClosing(self: *PtySession) !void {
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        defer closeFd(kq);

        // EV_RECEIPT로 각 등록의 성공/실패를 eventlist로 즉시 돌려받는다(대기 안 함).
        var changes = [_]std.c.Kevent{
            .{
                .ident = @intCast(self.child_pid),
                .filter = std.c.EVFILT.PROC,
                .flags = std.c.EV.ADD | std.c.EV.RECEIPT,
                .fflags = std.c.NOTE.EXIT,
                .data = 0,
                .udata = 0,
            },
            .{
                .ident = @intCast(self.wake_read_fd),
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.ADD | std.c.EV.RECEIPT,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };
        var receipts: [changes.len]std.c.Kevent = undefined;
        const reg = std.c.kevent(kq, &changes, changes.len, &receipts, receipts.len, null);
        if (reg < 0) return error.KeventFailed;

        var idx: usize = 0;
        while (idx < @as(usize, @intCast(reg))) : (idx += 1) {
            const ev = receipts[idx];
            if ((ev.flags & std.c.EV.ERROR) == 0 or ev.data == 0) continue;
            // child가 등록 직전에 종료해 PROC 등록이 실패하면(ESRCH 등) NOTE_EXIT를
            // 못 받는다. 그냥 반환해 호출부의 WNOHANG 재시도가 zombie를 거두게 한다.
            if (ev.filter == std.c.EVFILT.PROC) return;
            // wake pipe 등록 실패는 비정상이므로 에러로 알린다.
            return error.KeventFailed;
        }

        // child 종료(NOTE_EXIT) 또는 close wake가 올 때까지 막는다. 어느 쪽이든
        // 깨어나면 호출부가 closing/WNOHANG로 다음에 무엇을 할지 다시 정한다.
        var events: [changes.len]std.c.Kevent = undefined;
        while (true) {
            const n = std.c.kevent(kq, &changes, 0, &events, events.len, null);
            if (n >= 0) return;
            if (std.posix.errno(n) == .INTR) continue;
            return error.KeventFailed;
        }
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

    fn init(allocator: std.mem.Allocator, env: []const []const u8) !EnvStorage {
        if (env.len == 0) {
            // 부모 환경을 물려주되 TERM/COLORTERM은 Maru 값으로 덮어쓴다. 부모 TERM을 그대로 주면
            // (예: tmux/screen TERM, 또는 Maru 동작과 안 맞는 terminfo) zsh의 SIGWINCH redraw가
            // wrap 행 수를 잘못 계산해(상대 커서 이동 \e[A 횟수가 어긋남) 프롬프트가 중복된다.
            // Maru는 xterm식(auto-wrap + deferred wrap)이라 xterm-256color terminfo와 맞는다.
            // (Ghostty도 TERM을 자기 값으로 명시 설정하고 폴백이 xterm-256color다 — 동작 비교 확인.)
            return initFromParentWithTermOverride(allocator);
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
        };
    }

    // 부모 환경(std.c.environ)을 복사하되 TERM/COLORTERM을 Maru 표준값으로 교체한 owned envp를 만든다.
    fn initFromParentWithTermOverride(allocator: std.mem.Allocator) !EnvStorage {
        var entries: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (entries.items) |owned| allocator.free(owned);
            entries.deinit(allocator);
        }

        // 부모의 모든 env entry를 복사한다. 단 TERM/COLORTERM은 건너뛰고 아래에서 우리 값으로 넣는다
        // (중복 키는 첫 항목이 이기므로, 우리 값만 남도록 부모 것을 빼야 한다).
        const environ = std.c.environ;
        var index: usize = 0;
        while (environ[index]) |entry| : (index += 1) {
            const slice = std.mem.span(entry);
            if (std.mem.startsWith(u8, slice, "TERM=") or std.mem.startsWith(u8, slice, "COLORTERM=")) continue;
            try entries.append(allocator, try allocator.dupeZ(u8, slice));
        }
        try entries.append(allocator, try allocator.dupeZ(u8, "TERM=xterm-256color"));
        try entries.append(allocator, try allocator.dupeZ(u8, "COLORTERM=truecolor"));

        const strings = try entries.toOwnedSlice(allocator);
        errdefer {
            for (strings) |owned| allocator.free(owned);
            allocator.free(strings);
        }

        const envp = try allocator.allocSentinel(?[*:0]const u8, strings.len, null);
        for (strings, 0..) |entry, i| envp[i] = entry.ptr;

        return .{
            .allocator = allocator,
            .strings = strings,
            .envp = envp,
        };
    }

    // 두 init 경로 모두 owned envp를 만든다(빈 env면 부모 복사 + TERM 덮어쓰기, 명시 env면 그대로).
    // 그래서 항상 owned 메모리를 해제하고 owned envp를 반환한다(예전 uses_parent 분기는 제거됨).
    fn deinit(self: *EnvStorage) void {
        for (self.strings) |entry| self.allocator.free(entry);
        self.allocator.free(self.strings);
        self.allocator.free(self.envp.?);
    }

    fn envpPtr(self: *const EnvStorage) [*:null]const ?[*:0]const u8 {
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

// Non-blocking reap. Returns the decoded status if the child has become a
// zombie, null if it is still running, or an error if there is nothing to wait
// on. The reader uses this so it never blocks indefinitely in waitpid: when the
// child is still alive it waits for the real exit via kqueue instead (see
// waitChildExitOrClosing), which a close() can always interrupt.
fn reapNoHang(pid: std.c.pid_t) !?types.ExitStatus {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return decodeExitStatus(status);
        if (rc == 0) return null;
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return error.WaitPidFailed; // ECHILD 등: 거둘 child가 없다.
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
