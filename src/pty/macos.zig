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

// 포그라운드 프로세스 감지(foregroundProcessName) — tcgetpgrp: 터미널 포그라운드 pgid, proc_name: libproc(libSystem
// 내장, 추가 링크 불요)로 pid의 프로세스 이름. macOS 전용(pty/macos.zig 자체가 macOS 전용).
extern "c" fn tcgetpgrp(fd: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

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

        // login=true면 login(1)으로 감싸 전체 로그인 세션을 셋업한다(Terminal.app·Ghostty와 동일).
        // 셋업 실패(getpwuid 등 — 정상 사용자에선 사실상 없음)면 평범한 비-login 셸로 fallback한다
        // (Ghostty와 동일하게 dash-argv0가 아니라 그냥 plain).
        var login_wrap: ?MacosLogin = if (request.login)
            (MacosLogin.build(allocator, request) catch |err| blk: {
                std.log.scoped(.pty).warn("login(1) 래핑 실패({}) — 비-login 셸로 fallback", .{err});
                break :blk null;
            })
        else
            null;
        defer if (login_wrap) |*lw| lw.deinit(allocator);

        const eff_command: []const u8 = if (login_wrap != null) "/usr/bin/login" else request.command;
        const eff_args: []const []const u8 = if (login_wrap) |lw| lw.args else request.args;

        const command_z = try allocator.dupeZ(u8, eff_command);
        defer allocator.free(command_z);

        const cwd_z = if (request.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
        defer if (cwd_z) |cwd| allocator.free(cwd);

        var argv_storage = try ArgvStorage.init(allocator, eff_command, eff_args);
        defer argv_storage.deinit();

        var env_storage = try EnvStorage.init(allocator, request.env, request.term, request.zdotdir);
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
        // master fd를 non-blocking으로 둔다. write는 버퍼에 들어가는 만큼만 쓰고 EAGAIN이면
        // 0을 돌려줘(아래 writeFd) 큰 붙여넣기가 UI tick을 동결시키지 않는다 — poll만으로는
        // 512B 여유를 보장 못 해 blocking fd에선 write가 막힐 수 있었다(#5). reader는 poll-
        // readable 후 read하므로 EAGAIN은 드문 race이고 readEvent가 재시도한다.
        try setNonBlocking(master_fd);

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

        var buffer: [4096]u8 = undefined;
        const read_len = while (true) {
            try self.waitReadableOrClosing(fd);
            break std.posix.read(fd, &buffer) catch |err| switch (err) {
                // PTY EOF is reported as EIO on some Unix implementations after
                // the slave side closes. Treat it the same as a zero-byte read so
                // callers do not need OS-specific EOF rules.
                error.InputOutput => 0,
                // master fd가 O_NONBLOCK이라 poll-readable과 read 사이의 드문 race에서 EAGAIN이
                // 날 수 있다 — 데이터가 아직 없다는 뜻이니 다시 기다린다(루프, 스택 안전).
                error.WouldBlock => continue,
                else => {
                    if (self.closing.load(.acquire)) return error.SessionClosed;
                    return err;
                },
            };
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
            if (n == 0) {
                // non-blocking 버퍼가 찼다 — writable이 될 때까지(또는 close) 기다렸다 재시도한다.
                // 키 입력은 작아 거의 안 걸리지만, 전량 전달 계약은 지킨다.
                try self.waitWritableOrClosing(fd);
                continue;
            }
            written += n;
        }
    }

    fn waitWritableOrClosing(self: *PtySession, fd: std.posix.fd_t) !void {
        if (self.closing.load(.acquire)) return error.SessionClosed;
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 },
            .{ .fd = self.wake_read_fd, .events = poll_in_events, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch return error.WriteFailed;
        if (self.closing.load(.acquire)) return error.SessionClosed;
    }

    /// non-blocking 한 청크 쓰기: master fd가 O_NONBLOCK이라 버퍼에 들어가는 만큼만 쓰고(부분
    /// 쓰기 가능) 쓴 길이를 돌려준다. 버퍼가 차면 EAGAIN→0 — 자식이 stdin을 안 읽어도 절대
    /// 막히지 않는다(블록 fd+poll은 512B 여유를 보장 못 해 막힐 수 있었다, #5). 큰 붙여넣기를
    /// tick에 걸쳐 흘려보내는 paste 큐가 쓴다.
    pub fn writeInputNonBlocking(self: *PtySession, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        const fd = try self.activeMasterFd();
        return try writeFd(fd, bytes[0..@min(bytes.len, 512)]);
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

    /// 이 PTY의 **포그라운드 프로세스 그룹 리더의 프로세스 이름**을 out에 채워 반환한다(없으면 null). 셸 안에서
    /// `claude`/`codex`를 실행하면 그게 포그라운드가 되므로, 어느 에이전트가 도는지 식별하는 데 쓴다. tcgetpgrp로
    /// 터미널 포그라운드 pgid를 얻고(=그룹 리더 pid — 파이프라인이면 첫 단계라 비-리더 단계는 못 봄, v1 한계),
    /// libproc proc_name으로 이름을 얻는다(libSystem 내장, 추가 링크 불요). 닫혔거나 fd 음수·pgid≤0·proc_name 실패면
    /// null. proc_name은 NUL-종단 이름을 복사하고 strlen(=복사 바이트)을 반환하므로 out[0..n]은 NUL 없는 깨끗한 이름.
    /// out은 ≥ 2*MAXCOMLEN(32) 바이트여야 한다(작으면 proc_name이 0 반환 → null). 호출자가 [256]u8로 넘긴다.
    /// **틱 스레드에서만 호출**(close는 closing만 올리고 fd는 reader join 후 deinit에서만 닫혀 fd 재사용 레이스 없음).
    pub fn foregroundProcessName(self: *PtySession, out: []u8) ?[]const u8 {
        if (self.closing.load(.acquire)) return null;
        const fd = self.master_fd.load(.acquire);
        if (fd < 0) return null;
        const pgid = tcgetpgrp(fd);
        if (pgid <= 0) return null;
        const n = proc_name(pgid, out.ptr, @intCast(out.len));
        if (n <= 0) return null; // 0=실패(버퍼<32 포함). proc_name은 ≤ buffersize-1만 반환하므로 out[0..n]은 항상 buf 내.
        return out[0..@intCast(n)];
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

    // argv[0]=command(경로 그대로), argv[1..]=args. login shell 셋업은 spawn에서 login(1) 래핑으로
    // 처리하므로(MacosLogin) 여기는 평범하게 둔다.
    fn init(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !ArgvStorage {
        const argc = 1 + args.len;
        const strings = try allocator.alloc([:0]u8, argc);
        errdefer allocator.free(strings);

        var initialized: usize = 0;
        errdefer {
            for (strings[0..initialized]) |owned| allocator.free(owned);
        }

        strings[0] = try allocator.dupeZ(u8, command);
        initialized += 1;

        for (args, 0..) |arg, index| {
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

// macOS login(1) 래핑 — Terminal.app·Ghostty와 동일하게 전체 로그인 세션(getlogin()·SHELL·utmp·
// hushlogin)을 셋업한 뒤 셸을 login shell로 exec한다. 단순히 argv[0]에 `-`만 붙이면 .zprofile은
// 읽지만 getlogin()/SHELL/세션 env가 안 잡혀, 그에 의존하는 셸 설정(예: $TERM_PROGRAM별 키바인딩)이
// 어긋난다(실측: Cmd+Left는 되는데 Cmd+Right는 안 됨). 형태(Ghostty가 Apple login.c를 읽고 찾은):
//   /usr/bin/login [-q] -flp <user> /bin/bash --noprofile --norc -c "exec -l <shell> <args>"
//   -f 인증 생략, -l login(1)이 cwd를 home으로 안 바꾸게, -p env 보존, -q hushlogin(.hushlogin 있을 때).
//   설정 무로드 bash가 `exec -l`로 최종 셸을 login shell로 교체한다(bash가 zsh보다 exec ~2배 빠름).
const MacosLogin = struct {
    owned: [][]u8, // 동적 할당 인자(username 복사, "exec -l ..." 문자열) — deinit이 해제
    args: [][]const u8, // ArgvStorage에 넘길 login(1) 인자(리터럴 + owned 슬라이스 혼합)

    fn build(allocator: std.mem.Allocator, request: types.SpawnRequest) !MacosLogin {
        const pw = std.c.getpwuid(std.c.getuid()) orelse return error.NoPasswd;
        const username = std.mem.span(pw.name orelse return error.NoUsername);

        // hushlogin: 홈에 .hushlogin이 있으면 login 배너를 억제(-q). login(1) -l은 cwd 기준으로
        // 보므로 우리가 홈을 직접 확인해 -q를 준다(Ghostty와 동일 이유).
        const hush = if (pw.dir) |dir_ptr| blk: {
            const home = std.mem.span(dir_ptr);
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/.hushlogin", .{home}) catch break :blk false;
            break :blk std.c.access(path.ptr, std.posix.F_OK) == 0;
        } else false;

        // "exec -l <command> <arg1> ..." — bash가 실행해 최종 셸을 login shell로 교체한다.
        var cmd_buf: std.ArrayList(u8) = .empty;
        defer cmd_buf.deinit(allocator);
        try cmd_buf.appendSlice(allocator, "exec -l ");
        try cmd_buf.appendSlice(allocator, request.command);
        for (request.args) |a| {
            try cmd_buf.append(allocator, ' ');
            try cmd_buf.appendSlice(allocator, a);
        }
        const exec_cmd = try cmd_buf.toOwnedSlice(allocator);
        errdefer allocator.free(exec_cmd);
        const user_dup = try allocator.dupe(u8, username);
        errdefer allocator.free(user_dup);

        var owned: std.ArrayList([]u8) = .empty;
        errdefer owned.deinit(allocator);
        try owned.append(allocator, exec_cmd);
        try owned.append(allocator, user_dup);

        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(allocator);
        if (hush) try args.append(allocator, "-q");
        try args.append(allocator, "-flp");
        try args.append(allocator, user_dup);
        try args.append(allocator, "/bin/bash");
        try args.append(allocator, "--noprofile");
        try args.append(allocator, "--norc");
        try args.append(allocator, "-c");
        try args.append(allocator, exec_cmd);

        return .{
            .owned = try owned.toOwnedSlice(allocator),
            .args = try args.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *MacosLogin, allocator: std.mem.Allocator) void {
        for (self.owned) |s| allocator.free(s);
        allocator.free(self.owned);
        allocator.free(self.args);
    }
};

// env가 비어 있으면 부모 환경을 그대로 상속한다.
// 명시 env가 있으면 execve가 요구하는 null-terminated envp 배열로 바꿔 child에게만 전달한다.
const EnvStorage = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    envp: ?[:null]?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, env: []const []const u8, term: []const u8, zdotdir: ?[]const u8) !EnvStorage {
        if (env.len == 0) {
            // 부모 환경을 물려주되 TERM/COLORTERM은 Maru 값으로 덮어쓴다. 부모 TERM을 그대로 주면
            // (예: 멀티플렉서 TERM, 또는 Maru 동작과 안 맞는 terminfo) zsh의 SIGWINCH redraw가
            // wrap 행 수를 잘못 계산해(상대 커서 이동 \e[A 횟수가 어긋남) 프롬프트가 중복된다.
            // 기본 xterm-256color는 Maru의 xterm식(auto-wrap + deferred wrap) 동작과 맞는다. 단
            // 사용자 config(`term =`)로 바꿀 수 있다. zdotdir이 있으면 셸 통합용 ZDOTDIR을 주입한다.
            return initFromParentWithTermOverride(allocator, term, zdotdir);
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

    // 부모 환경(std.c.environ)을 복사하되 TERM은 인자 값(기본 xterm-256color, 사용자 config로 변경
    // 가능)으로, COLORTERM은 truecolor로 교체한 owned envp를 만든다. zdotdir이 있으면 ZDOTDIR을
    // 그 값으로 주입하고(셸 통합), 기존 ZDOTDIR은 MARU_ZDOTDIR_PREV로 보존해 통합 .zshenv가 복원한다.
    fn initFromParentWithTermOverride(allocator: std.mem.Allocator, term: []const u8, zdotdir: ?[]const u8) !EnvStorage {
        var entries: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (entries.items) |owned| allocator.free(owned);
            entries.deinit(allocator);
        }

        // 부모의 모든 env entry를 복사한다. 단 TERM/COLORTERM(+통합 시 ZDOTDIR/MARU_ZDOTDIR_PREV)은
        // 건너뛰고 아래에서 우리 값으로 넣는다(중복 키는 첫 항목이 이기므로 부모 것을 빼야 한다).
        var old_zdotdir: ?[]const u8 = null; // environ 슬라이스(프로세스 수명 동안 유효) — 루프 후 사용
        const environ = std.c.environ;
        var index: usize = 0;
        while (environ[index]) |entry| : (index += 1) {
            const slice = std.mem.span(entry);
            if (std.mem.startsWith(u8, slice, "TERM=") or std.mem.startsWith(u8, slice, "COLORTERM=")) continue;
            if (zdotdir != null) {
                if (std.mem.startsWith(u8, slice, "ZDOTDIR=")) {
                    old_zdotdir = slice["ZDOTDIR=".len..];
                    continue;
                }
                if (std.mem.startsWith(u8, slice, "MARU_ZDOTDIR_PREV=")) continue; // stale 제거
            }
            // dupe를 지역 변수로 받아 append 실패(OOM) 시에도 고아가 되지 않게 한다 — errdefer는
            // entries.items만 해제하므로 append 인자 안에서 dupe하면 그 문자열이 샌다.
            const owned = try allocator.dupeZ(u8, slice);
            entries.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
        }
        const term_owned = try std.fmt.allocPrintSentinel(allocator, "TERM={s}", .{term}, 0);
        entries.append(allocator, term_owned) catch |err| {
            allocator.free(term_owned);
            return err;
        };
        const colorterm_owned = try allocator.dupeZ(u8, "COLORTERM=truecolor");
        entries.append(allocator, colorterm_owned) catch |err| {
            allocator.free(colorterm_owned);
            return err;
        };
        if (zdotdir) |zd| {
            const z = try std.fmt.allocPrintSentinel(allocator, "ZDOTDIR={s}", .{zd}, 0);
            entries.append(allocator, z) catch |err| {
                allocator.free(z);
                return err;
            };
            if (old_zdotdir) |prev| {
                const p = try std.fmt.allocPrintSentinel(allocator, "MARU_ZDOTDIR_PREV={s}", .{prev}, 0);
                entries.append(allocator, p) catch |err| {
                    allocator.free(p);
                    return err;
                };
            }
        }

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
        // cwd 실패는 setsid/ioctl/dup2와 달리 **복구 가능**하다: 요청한 디렉터리가 사라졌거나(복원/TOCTOU — 검사
        // 후 spawn 사이 삭제) 접근 불가여도 셸을 잃는 것보다 다른 디렉터리에서라도 여는 게 낫다. 죽지 않고(_exit
        // 126 제거) $HOME으로 폴백하고, $HOME도 없거나 실패하면 상속 cwd 그대로 둔다. async-signal-safe만 사용
        // (envp 스캔·chdir, 할당 없음). 이게 cwd 정합성의 단일 권위 — Zig 쪽 usableRestoreCwd는 이른 필터일 뿐이다.
        if (std.c.chdir(dir.ptr) < 0) {
            if (homeFromEnv(envp)) |home| _ = std.c.chdir(home);
        }
    }
    if (std.c.dup2(slave_fd, 0) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 1) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 2) < 0) std.c._exit(126);

    _ = std.c.close(master_fd);
    if (slave_fd > 2) _ = std.c.close(slave_fd);

    _ = std.c.execve(command.ptr, argv, envp);
    std.c._exit(127);
}

/// envp("KEY=VALUE" C 문자열들, null 종단 배열)에서 HOME 값을 찾는다(없으면 null). child의 chdir 폴백용 —
/// async-signal-safe(순수 스캔, 할당·syscall 없음). 반환 포인터는 envp가 가리키는 문자열 내부(복사 없음).
fn homeFromEnv(envp: [*:null]const ?[*:0]const u8) ?[*:0]const u8 {
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (std.mem.startsWith(u8, e, "HOME=") and e.len > "HOME=".len) return entry + "HOME=".len;
    }
    return null;
}

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) return error.FcntlFailed;
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
        if (err == .AGAIN) return 0; // non-blocking: 지금은 더 못 쓴다(버퍼 참)
        return error.WriteFailed;
    }
}

// Closing a session whose child is still alive escalates SIGHUP -> SIGTERM ->
// SIGKILL, giving the child a bounded grace window to exit (and run shell close
// traps) at each step before forcing the next. SIGKILL cannot be caught so the
// child is guaranteed to terminate — but the reap is a BOUNDED poll
// (reapBoundedAfterKill), NOT a blocking wait4: it gives up after ~3s rather than
// risk close()/deinit hanging forever (observed wait4(pid, 0) never returning under
// reader-thread reap races; 22-minute hang). On give-up the dead child is left for
// launchd/init to harvest as an orphan — a zombie bounded to process lifetime,
// which is preferred over an unbounded hang (so a zombie CAN briefly remain, only
// until the parent process exits). This is intentionally synchronous in deinit.
const shutdown_grace_attempts = 6;
const shutdown_grace_interval_ms = 10;

fn shutdownChild(pid: std.c.pid_t) void {
    if (pid <= 0) return;

    if (signalAndReap(pid, .HUP)) return;
    if (signalAndReap(pid, .TERM)) return;

    // Last resort: SIGKILL is uncatchable. 그래도 reap을 무한 blocking wait4로 기다리지 않는다 —
    // 멀티스레드 + reader thread의 reap 경합, PTY 버퍼 상태 등으로 wait4(pid, 0)이 영영 안
    // 돌아오는 경우가 관측됐다(close/deinit이 22분 hang). bounded poll로 바꿔, SIGKILL 후
    // 정해진 창 안에 reap되면 거두고(보통 수 ms), 안 되면 포기한다 — close는 절대 막히지 않는다.
    // 남은 자식은 부모(테스트/앱) 종료 시 launchd/init이 거둔다(고아 reap). reaped 못 해도
    // zombie 누수는 프로세스 수명 한정이라 무한 hang보다 안전하다.
    _ = std.c.kill(-pid, .KILL);
    _ = std.c.kill(pid, .KILL);
    reapBoundedAfterKill(pid);
}

// SIGKILL 이후 유계 reap: WNOHANG poll을 짧게 반복하며 최대 shutdown_kill_reap_attempts번
// 기다린다. 무한 blocking wait4 대신 — close/deinit이 어떤 OS 이상에서도 막히지 않게.
const shutdown_kill_reap_attempts = 300; // 300 × 10ms = 최대 3s(보통 1~2회에 거둠)
fn reapBoundedAfterKill(pid: std.c.pid_t) void {
    var attempt: usize = 0;
    while (attempt < shutdown_kill_reap_attempts) : (attempt += 1) {
        if (tryReap(pid) != .alive) return; // reaped 또는 이미 gone
        sleepMillis(shutdown_grace_interval_ms);
    }
    // 여기 도달 = SIGKILL 후에도 정해진 창 안에 reap 안 됨(드문 OS 이상). 무한 대기 대신 포기한다.
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

test "EnvStorage empty env inherits the parent but forces TERM/COLORTERM to Maru's values" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, "xterm-256color", null);
    defer storage.deinit();

    var term_count: usize = 0;
    var colorterm_count: usize = 0;
    var maru_term = false;
    var maru_colorterm = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        if (std.mem.startsWith(u8, slice, "TERM=")) {
            term_count += 1;
            maru_term = std.mem.eql(u8, slice, "TERM=xterm-256color");
        }
        if (std.mem.startsWith(u8, slice, "COLORTERM=")) {
            colorterm_count += 1;
            maru_colorterm = std.mem.eql(u8, slice, "COLORTERM=truecolor");
        }
    }
    // 부모 TERM/COLORTERM은 제거되고 Maru 값이 정확히 하나씩 있어야 한다(중복 키는 첫 항목이
    // 이기므로 부모 것이 남으면 override가 안 먹는다).
    try std.testing.expectEqual(@as(usize, 1), term_count);
    try std.testing.expectEqual(@as(usize, 1), colorterm_count);
    try std.testing.expect(maru_term);
    try std.testing.expect(maru_colorterm);
    try std.testing.expect(i >= 2); // 부모 env도 물려받았다(최소 PATH 등)
}

test "EnvStorage explicit env is passed through verbatim (term arg ignored)" {
    // 명시 env면 term 인자는 무시된다(테스트가 완전한 env를 직접 준다).
    var storage = try EnvStorage.init(std.testing.allocator, &.{ "FOO=bar", "TERM=dumb" }, "xterm-ghostty", null);
    defer storage.deinit();
    const envp = storage.envpPtr();
    try std.testing.expectEqualStrings("FOO=bar", std.mem.span(envp[0].?));
    try std.testing.expectEqualStrings("TERM=dumb", std.mem.span(envp[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), envp[2]);
}

test "ArgvStorage uses the command path as argv[0] and appends args" {
    var storage = try ArgvStorage.init(std.testing.allocator, "/bin/zsh", &.{"-i"});
    defer storage.deinit();
    try std.testing.expectEqualStrings("/bin/zsh", std.mem.span(storage.argv[0].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(storage.argv[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), storage.argv[2]);
}

test "MacosLogin wraps the shell in login(1) -flp <user> bash exec -l" {
    var lw = try MacosLogin.build(std.testing.allocator, .{ .command = "/bin/zsh", .args = &.{"-i"}, .login = true });
    defer lw.deinit(std.testing.allocator);
    // -q(hushlogin)는 환경 의존이라 빼고, 핵심 구조를 확인한다.
    var saw_flp = false;
    var saw_bash = false;
    var saw_exec = false;
    for (lw.args) |a| {
        if (std.mem.eql(u8, a, "-flp")) saw_flp = true;
        if (std.mem.eql(u8, a, "/bin/bash")) saw_bash = true;
        if (std.mem.eql(u8, a, "exec -l /bin/zsh -i")) saw_exec = true;
    }
    try std.testing.expect(saw_flp);
    try std.testing.expect(saw_bash);
    try std.testing.expect(saw_exec); // 최종 셸을 login shell로 교체하는 exec 명령
}

test "EnvStorage empty env uses the supplied TERM (configurable)" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, "xterm-ghostty", null);
    defer storage.deinit();
    var found = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(entry), "TERM=xterm-ghostty")) found = true;
    }
    try std.testing.expect(found); // config term이 셸 env에 반영된다
}

test "EnvStorage injects ZDOTDIR for shell integration and preserves the old one" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, "xterm-256color", "/cache/maru/zsh");
    defer storage.deinit();
    var saw_zdotdir = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(entry), "ZDOTDIR=/cache/maru/zsh")) saw_zdotdir = true;
    }
    try std.testing.expect(saw_zdotdir); // 통합 디렉터리가 ZDOTDIR로 주입됨
}
