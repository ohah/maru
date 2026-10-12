//! 외부 포매터 한 번 실행(tooling §8.2t·§8.1, 계획 docs/plans/editor-external-formatter.md) — 문서 본문을 stdin 으로 넣고 stdout 을
//! 받는다. **메인 스레드를 막지 않는다**: 작업 스레드 하나가 실행하고 결과를 결과 목록에 남기면, 메인이 tick 에서 id 로 가져간다
//! (`tool_env` 와 같은 모양 — 이 모듈엔 `Io` 가 없어 pthread 잠금).
//!
//! §8.1 의 실행 규칙: 셸 없이 argv 로(`execve`), cwd 는 저장소 루트, 환경은 호출자가 준 것(사용자 셸 환경 — 위생·제외 목록을 지난 것).
//! 자식은 제 프로세스 그룹의 우두머리라 시한·상한에서 **그룹째** 끝낸다(`kill(-pid)`) — 포매터가 띄운 자식(Node 워커)도 남지 않는다.
//! `std.process.run` 은 앱 Io 에서 못 쓴다(fork + execve — `tool_env`·`lsp_process` 와 같다).

const std = @import("std");
const builtin = @import("builtin");

/// 작업 스레드는 창(세션)보다 오래 살 수 있다 — 앱 전역 수명의 allocator.
const gpa = std.heap.smp_allocator;

/// 시한 — Node 로 도는 포매터의 첫 실행이 1 초를 넘는다(§8.2r 의 1 초는 떠 있는 서버의 응답 시한이다).
pub const default_timeout_ms: u32 = 3000;
/// stdout 상한 — 넘으면 그룹째 끝내고 `too_large`.
pub const max_stdout_bytes: usize = 16 << 20;
/// stderr 는 앞부분만 든다(알림에 첫 줄을 싣는다) — 나머지는 읽어 버린다(파이프가 차서 자식이 멈추지 않게).
pub const max_stderr_bytes: usize = 64 << 10;

pub const Request = struct {
    /// argv(첫 칸은 실행 파일의 절대 경로).
    argv: []const []const u8,
    /// 저장소 루트.
    cwd: []const u8,
    /// 자식 환경(`null` 이면 앱 환경). 빌린다 — `start` 가 복사한다.
    envp: ?[*:null]const ?[*:0]const u8,
    stdin: []const u8,
    timeout_ms: u32 = default_timeout_ms,
};

pub const Outcome = union(enum) {
    /// 끝났다. `code` 는 종료 코드(신호로 끝났으면 `null`). stdout·stderr 는 결과가 소유한다.
    exited: struct { code: ?u8, stdout: []u8, stderr: []u8 },
    /// 시한을 넘겨 그룹째 끝냈다.
    timeout,
    /// stdout 이 상한을 넘어 그룹째 끝냈다.
    too_large,
    /// 띄우지 못했다(fork·파이프·메모리). 실행 파일이 없거나 실행할 수 없으면 자식이 127·126 으로 끝난다(`exited`).
    spawn_failed,
};

pub const Result = struct {
    id: u64,
    outcome: Outcome,
    elapsed_ms: u64,

    pub fn deinit(self: *Result) void {
        switch (self.outcome) {
            .exited => |e| {
                gpa.free(e.stdout);
                gpa.free(e.stderr);
            },
            else => {},
        }
        gpa.destroy(self);
    }
};

/// 작업 스레드 → 메인. `lock` 안에서만 읽고 쓴다.
var results: std.ArrayList(*Result) = .empty;
/// 결과를 기다리지 않게 된 id(창이 닫혔다·새 요청이 덮었다) — 결과가 오면 곧바로 버린다.
var abandoned: std.ArrayList(u64) = .empty;
var lock: std.c.pthread_mutex_t = .{};
var next_id: std.atomic.Value(u64) = .init(1);
/// 떠 있는 작업 수(판정자가 기다린다).
var running: std.atomic.Value(u32) = .init(0);

const Job = struct {
    id: u64,
    argv: [][:0]u8,
    cwd: [:0]u8,
    env: ?[][:0]u8,
    stdin: []u8,
    timeout_ms: u32,

    fn destroy(self: *Job) void {
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        gpa.free(self.cwd);
        if (self.env) |e| {
            for (e) |s| gpa.free(s);
            gpa.free(e);
        }
        gpa.free(self.stdin);
        gpa.destroy(self);
    }
};

/// 실행을 시작하고 id 를 돌려준다(결과는 `take(id)`). 복사·스레드를 못 만들면 `null`.
pub fn start(req: Request) ?u64 {
    const job = copyJob(req) catch return null;
    _ = running.fetchAdd(1, .acq_rel);
    const t = std.Thread.spawn(.{}, worker, .{job}) catch {
        _ = running.fetchSub(1, .acq_rel);
        job.destroy();
        return null;
    };
    t.detach();
    return job.id;
}

fn copyJob(req: Request) !*Job {
    if (req.argv.len == 0) return error.NoArgv;
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    const argv = try gpa.alloc([:0]u8, req.argv.len);
    var n_argv: usize = 0;
    errdefer {
        for (argv[0..n_argv]) |a| gpa.free(a);
        gpa.free(argv);
    }
    for (req.argv) |a| {
        argv[n_argv] = try gpa.dupeZ(u8, a);
        n_argv += 1;
    }
    const cwd = try gpa.dupeZ(u8, req.cwd);
    errdefer gpa.free(cwd);
    var env: ?[][:0]u8 = null;
    var n_env: usize = 0;
    errdefer if (env) |e| {
        for (e[0..n_env]) |s| gpa.free(s);
        gpa.free(e);
    };
    if (req.envp) |envp| {
        var count: usize = 0;
        while (envp[count] != null) count += 1;
        env = try gpa.alloc([:0]u8, count);
        while (n_env < count) : (n_env += 1) env.?[n_env] = try gpa.dupeZ(u8, std.mem.span(envp[n_env].?));
    }
    const stdin = try gpa.dupe(u8, req.stdin);
    job.* = .{ .id = next_id.fetchAdd(1, .monotonic), .argv = argv, .cwd = cwd, .env = env, .stdin = stdin, .timeout_ms = req.timeout_ms };
    return job;
}

/// 그 id 의 결과(아직이면 `null`). 받은 쪽이 `deinit` 한다.
pub fn take(id: u64) ?*Result {
    _ = std.c.pthread_mutex_lock(&lock);
    defer _ = std.c.pthread_mutex_unlock(&lock);
    for (results.items, 0..) |r, i| if (r.id == id) {
        _ = results.swapRemove(i);
        return r;
    };
    return null;
}

/// 그 id 의 결과를 더 기다리지 않는다 — 이미 왔으면 버리고, 아직이면 올 때 버린다.
pub fn abandon(id: u64) void {
    _ = std.c.pthread_mutex_lock(&lock);
    for (results.items, 0..) |r, i| if (r.id == id) {
        _ = results.swapRemove(i);
        _ = std.c.pthread_mutex_unlock(&lock);
        return r.deinit();
    };
    abandoned.append(gpa, id) catch {};
    _ = std.c.pthread_mutex_unlock(&lock);
}

fn worker(job: *Job) void {
    defer _ = running.fetchSub(1, .acq_rel);
    defer job.destroy();
    const started = nowMs();
    const outcome = run(job);
    const r = gpa.create(Result) catch return discardOutcome(outcome);
    r.* = .{ .id = job.id, .outcome = outcome, .elapsed_ms = nowMs() -| started };
    _ = std.c.pthread_mutex_lock(&lock);
    for (abandoned.items, 0..) |id, i| if (id == job.id) {
        _ = abandoned.swapRemove(i);
        _ = std.c.pthread_mutex_unlock(&lock);
        return r.deinit();
    };
    results.append(gpa, r) catch {
        _ = std.c.pthread_mutex_unlock(&lock);
        return r.deinit();
    };
    _ = std.c.pthread_mutex_unlock(&lock);
}

fn discardOutcome(o: Outcome) void {
    switch (o) {
        .exited => |e| {
            gpa.free(e.stdout);
            gpa.free(e.stderr);
        },
        else => {},
    }
}

extern "c" fn getdtablesize() c_int;
const f_setnosigpipe: c_int = 73; // macOS `F_SETNOSIGPIPE` — 닫힌 stdin 에 쓰다 SIGPIPE 로 앱이 죽지 않게

fn run(job: *Job) Outcome {
    // argv·envp 포인터 배열을 fork 전에 만든다 — 자식에서 할당하지 않는다.
    const argv = gpa.alloc(?[*:0]const u8, job.argv.len + 1) catch return .spawn_failed;
    defer gpa.free(argv);
    for (job.argv, 0..) |a, i| argv[i] = a.ptr;
    argv[job.argv.len] = null;
    var envp_buf: ?[]?[*:0]const u8 = null;
    defer if (envp_buf) |e| gpa.free(e);
    if (job.env) |env| {
        const e = gpa.alloc(?[*:0]const u8, env.len + 1) catch return .spawn_failed;
        for (env, 0..) |s, i| e[i] = s.ptr;
        e[env.len] = null;
        envp_buf = e;
    }
    const envp: [*:null]const ?[*:0]const u8 = if (envp_buf) |e| @ptrCast(e.ptr) else @ptrCast(std.c.environ);

    var in_fds: [2]std.c.fd_t = undefined;
    var out_fds: [2]std.c.fd_t = undefined;
    var err_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&in_fds) != 0) return .spawn_failed;
    if (std.c.pipe(&out_fds) != 0) {
        closeBoth(in_fds);
        return .spawn_failed;
    }
    if (std.c.pipe(&err_fds) != 0) {
        closeBoth(in_fds);
        closeBoth(out_fds);
        return .spawn_failed;
    }
    // 부모 쪽 끝은 다른 자식(언어 서버·셸)에 새지 않게 CLOEXEC.
    for ([_]std.c.fd_t{ in_fds[1], out_fds[0], err_fds[0] }) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

    const pid = std.c.fork();
    if (pid < 0) {
        closeBoth(in_fds);
        closeBoth(out_fds);
        closeBoth(err_fds);
        return .spawn_failed;
    }
    if (pid == 0) {
        if (std.c.setpgid(0, 0) != 0) std.c._exit(126);
        if (std.c.dup2(in_fds[0], 0) < 0 or std.c.dup2(out_fds[1], 1) < 0 or std.c.dup2(err_fds[1], 2) < 0) std.c._exit(126);
        // 앱의 fd 를 포매터에 넘기지 않는다(CLOEXEC 가 없는 것이 있다 — `tool_env` 와 같은 규율).
        const max_fd = getdtablesize();
        var fd: c_int = 3;
        while (fd < max_fd) : (fd += 1) _ = std.c.close(fd);
        if (std.c.chdir(job.cwd.ptr) != 0) std.c._exit(126);
        _ = std.c.execve(job.argv[0].ptr, @ptrCast(argv.ptr), envp);
        std.c._exit(127);
    }
    _ = std.c.setpgid(pid, pid); // 자식이 exec 하기 전에 kill(-pid) 가 닿게(경쟁 막기 — `lsp_process` 와 같다)
    _ = std.c.close(in_fds[0]);
    _ = std.c.close(out_fds[1]);
    _ = std.c.close(err_fds[1]);
    _ = std.c.fcntl(in_fds[1], f_setnosigpipe, @as(c_int, 1));
    for ([_]std.c.fd_t{ in_fds[1], out_fds[0], err_fds[0] }) |fd| setNonBlocking(fd);

    var stdin_fd: std.c.fd_t = in_fds[1];
    var stdout_fd: std.c.fd_t = out_fds[0];
    var stderr_fd: std.c.fd_t = err_fds[0];
    defer for ([_]std.c.fd_t{ stdin_fd, stdout_fd, stderr_fd }) |fd| {
        if (fd >= 0) _ = std.c.close(fd);
    };
    if (job.stdin.len == 0) {
        _ = std.c.close(stdin_fd);
        stdin_fd = -1;
    }

    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    var keep = false;
    defer if (!keep) {
        out.deinit(gpa);
        err.deinit(gpa);
    };
    var written: usize = 0;
    var status: c_int = 0;
    var exited = false;
    const deadline = nowMs() + job.timeout_ms;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (!exited) {
            const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (r == pid) exited = true;
        }
        // 자식이 끝났고 파이프도 다 닫혔으면 끝. 끝났는데 파이프를 쥔 손자가 있으면 시한까지 읽다가 그룹째 끝낸다.
        if (exited and stdout_fd < 0 and stderr_fd < 0) break;
        const now = nowMs();
        if (now >= deadline) return killGroup(pid, exited, .timeout);
        var fds: [3]std.c.pollfd = undefined;
        var n: usize = 0;
        if (stdin_fd >= 0) {
            fds[n] = .{ .fd = stdin_fd, .events = std.c.POLL.OUT, .revents = 0 };
            n += 1;
        }
        if (stdout_fd >= 0) {
            fds[n] = .{ .fd = stdout_fd, .events = std.c.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (stderr_fd >= 0) {
            fds[n] = .{ .fd = stderr_fd, .events = std.c.POLL.IN, .revents = 0 };
            n += 1;
        }
        // 파이프가 다 닫혔으면 자식이 끝나기만 기다린다(짧게 자며 — `waitpid` 에는 시한이 없다).
        const step: u64 = if (n == 0) 10 else 50;
        const wait_ms: c_int = @intCast(@min(deadline - now, step));
        if (n > 0) {
            const pr = std.c.poll(&fds, @intCast(n), wait_ms);
            if (pr < 0 and std.posix.errno(pr) != .INTR) return killGroup(pid, exited, .spawn_failed);
        } else sleepMs(@intCast(wait_ms));
        for (fds[0..n]) |p| {
            if (p.revents == 0) continue;
            if (p.fd == stdin_fd) {
                const w = std.c.write(stdin_fd, job.stdin[written..].ptr, job.stdin.len - written);
                if (w > 0) written += @intCast(w);
                if ((w < 0 and std.posix.errno(w) != .AGAIN) or written == job.stdin.len) {
                    _ = std.c.close(stdin_fd); // 다 썼거나 자식이 stdin 을 닫았다 — EOF 를 준다
                    stdin_fd = -1;
                }
            } else if (p.fd == stdout_fd) {
                const r = std.c.read(stdout_fd, &buf, buf.len);
                if (r > 0) {
                    if (out.items.len + @as(usize, @intCast(r)) > max_stdout_bytes) return killGroup(pid, exited, .too_large);
                    out.appendSlice(gpa, buf[0..@intCast(r)]) catch return killGroup(pid, exited, .spawn_failed);
                } else if (r == 0 or std.posix.errno(r) != .AGAIN) {
                    _ = std.c.close(stdout_fd);
                    stdout_fd = -1;
                }
            } else if (p.fd == stderr_fd) {
                const r = std.c.read(stderr_fd, &buf, buf.len);
                if (r > 0) {
                    const room = max_stderr_bytes -| err.items.len;
                    err.appendSlice(gpa, buf[0..@min(room, @as(usize, @intCast(r)))]) catch {};
                } else if (r == 0 or std.posix.errno(r) != .AGAIN) {
                    _ = std.c.close(stderr_fd);
                    stderr_fd = -1;
                }
            }
        }
    }
    // 자식이 끝났다 — 같은 그룹에 남은 것(포매터가 띄우고 놓은 손자)도 끝낸다.
    _ = std.c.kill(-pid, std.c.SIG.KILL);
    const stdout = out.toOwnedSlice(gpa) catch return .spawn_failed;
    const stderr = err.toOwnedSlice(gpa) catch {
        gpa.free(stdout);
        return .spawn_failed;
    };
    keep = true;
    const st: u32 = @bitCast(status);
    const code: ?u8 = if (std.posix.W.IFEXITED(st)) std.posix.W.EXITSTATUS(st) else null;
    return .{ .exited = .{ .code = code, .stdout = stdout, .stderr = stderr } };
}

/// 그룹째 끝내고 거둔다(좀비를 남기지 않는다).
fn killGroup(pid: std.c.pid_t, exited: bool, outcome: Outcome) Outcome {
    _ = std.c.kill(-pid, std.c.SIG.KILL);
    if (!exited) {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        var st: c_int = 0;
        _ = std.c.waitpid(pid, &st, 0);
    }
    return outcome;
}

fn closeBoth(fds: [2]std.c.fd_t) void {
    _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);
}

fn setNonBlocking(fd: std.c.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

/// 판정자 — 떠 있는 작업이 다 끝날 때까지(상한 `ms`) 기다린다.
pub fn waitIdleForTest(ms: u64) bool {
    if (!builtin.is_test) @compileError("test-only");
    var waited: u64 = 0;
    while (running.load(.acquire) != 0) : (waited += 5) {
        if (waited >= ms) return false;
        sleepMs(5);
    }
    return true;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn runAndWait(req: Request) !*Result {
    const id = start(req) orelse return error.StartFailed;
    var waited: u64 = 0;
    while (waited < 10_000) : (waited += 5) {
        if (take(id)) |r| return r;
        sleepMs(5);
    }
    return error.NoResult;
}

test "EFP1 실행기 — stdin 을 넣고 stdout 을 받는다(파이프 버퍼보다 큰 입력도 막히지 않는다), 0 이 아닌 종료와 stderr, 실행 파일 없음은 127, cwd·환경은 준 것 (tooling §8.2t)" {
    // `cat` — 1 MiB(파이프 버퍼 64 KiB 의 열여섯 배)를 그대로.
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    {
        const r = try runAndWait(.{ .argv = &.{"/bin/cat"}, .cwd = "/", .envp = null, .stdin = big });
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 0), r.outcome.exited.code);
        try testing.expectEqualSlices(u8, big, r.outcome.exited.stdout);
    }
    {
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", "echo 'syntax error at 1:2' >&2; echo partial; exit 2" }, .cwd = "/", .envp = null, .stdin = "" });
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 2), r.outcome.exited.code);
        try testing.expectEqualStrings("syntax error at 1:2\n", r.outcome.exited.stderr);
        try testing.expectEqualStrings("partial\n", r.outcome.exited.stdout);
    }
    {
        const r = try runAndWait(.{ .argv = &.{"/nonexistent/prettier"}, .cwd = "/", .envp = null, .stdin = "x" });
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 127), r.outcome.exited.code);
    }
    {
        // cwd 와 환경 — 준 것만(앱 환경의 변수는 안 샌다).
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
        const env = [_:null]?[*:0]const u8{ "MARU_FMT_PROBE=yes", null };
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", "pwd -P; echo \"$MARU_FMT_PROBE:${HOME:-none}\"" }, .cwd = root, .envp = &env, .stdin = "" });
        defer r.deinit();
        var want_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "{s}\nyes:none\n", .{root}), r.outcome.exited.stdout);
    }
    {
        // stdin 을 안 읽고 끝나도(파이프가 닫혀도) 앱이 SIGPIPE 로 죽지 않는다.
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", "exec 0<&-; echo done" }, .cwd = "/", .envp = null, .stdin = big });
        defer r.deinit();
        try testing.expectEqualStrings("done\n", r.outcome.exited.stdout);
    }
}

test "EFP2 실행기 — 시한이면 그룹째 끝내고(손자까지) 거둔다, stdout 상한이면 too_large, stderr 는 앞부분만; 버린 id 의 결과는 남지 않는다" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    {
        // 손자(`sleep` 을 백그라운드로)가 pid 를 남긴다 — 시한 뒤 그 pid 도 살아 있지 않아야 한다.
        var cmd_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "sleep 30 & echo $! > '{s}/gc'; sleep 30", .{root});
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", cmd }, .cwd = "/", .envp = null, .stdin = "", .timeout_ms = 300 });
        defer r.deinit();
        try testing.expect(r.outcome == .timeout);
        const gc = try tmp.dir.readFileAlloc(testing.io, "gc", testing.allocator, .limited(64));
        defer testing.allocator.free(gc);
        const gpid = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, gc, " \n"), 10);
        sleepMs(50);
        try testing.expect(std.c.kill(gpid, @enumFromInt(0)) != 0); // 손자도 없다(신호 0 — 있는지만 본다)
    }
    {
        // stdout 상한 — 끝없이 쓰는 자식을 그룹째 끝낸다.
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", "yes 0123456789abcdef" }, .cwd = "/", .envp = null, .stdin = "" });
        defer r.deinit();
        try testing.expect(r.outcome == .too_large);
    }
    {
        // stderr 는 앞부분만 — 나머지는 읽어 버려 자식이 멈추지 않는다.
        const r = try runAndWait(.{ .argv = &.{ "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; echo ok" }, .cwd = "/", .envp = null, .stdin = "" });
        defer r.deinit();
        try testing.expectEqual(max_stderr_bytes, r.outcome.exited.stderr.len);
        try testing.expectEqualStrings("ok\n", r.outcome.exited.stdout);
    }
    {
        // 버린 id — 결과가 와도 남지 않는다.
        const id = start(.{ .argv = &.{ "/bin/sh", "-c", "sleep 0.1; echo x" }, .cwd = "/", .envp = null, .stdin = "" }).?;
        abandon(id);
        try testing.expect(waitIdleForTest(5000));
        try testing.expect(take(id) == null);
        _ = std.c.pthread_mutex_lock(&lock);
        defer _ = std.c.pthread_mutex_unlock(&lock);
        try testing.expectEqual(@as(usize, 0), abandoned.items.len);
    }
}
