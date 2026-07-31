//! 도크 소스 컨트롤 뷰의 **git 읽기 backend**(L4). render tick은 `submit`/`takeResult`만 부르고 둘 다 메모리
//! 조작뿐이다 — 실제 프로세스 spawn·출력 수집은 detached worker thread에서 한다.
//!
//! `file_tree_backend`와 같은 형태다(제출·bounded in-flight·완료 큐). 다르게 만들 이유가 없고, 같은 모양이면
//! frame tick에서 syscall이 도는지 판단하는 규칙이 하나로 유지된다.
//!
//! **무엇을 실행할지는 여기서 정하지 않는다.** argv·env는 `session.git_command`가 소유하고(안전 조건이 전부
//! 거기 있다 — docs/editor-surface.md §6) 이 모듈은 그것을 그대로 spawn한다. 출력 해석도 `session.git_status`가
//! 한다. 즉 이 파일의 책임은 **프로세스 수명과 상한**뿐이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const git_command = maru.session.git_command;
const git_locate = maru.session.git_locate;

/// git 실행 파일 경로를 찾는다. **없으면 null** — 호출자는 그 사실을 화면에 말하고 실행을 시도하지 않는다.
/// 후보 순서는 `git_locate`(순수)가 정하고, 여기서는 존재·실행권만 본다.
pub fn locate(buf: []u8) ?[]const u8 {
    var toolchain: ?bool = null;
    var it = git_locate.candidates(pathEnv());
    while (it.next(buf)) |candidate| {
        if (!isExecutableFile(candidate)) continue;
        if (git_locate.isShim(candidate)) {
            // shim은 개발자 도구 설치 모달을 띄울 수 있어 증거가 있을 때만 쓴다(git_locate.shim_path 참고).
            if (toolchain == null) toolchain = anyToolchain();
            if (!toolchain.?) continue;
        }
        return candidate;
    }
    return null;
}

fn anyToolchain() bool {
    for (git_locate.toolchain_probes) |probe| {
        if (isExecutableFile(probe)) return true;
    }
    return false;
}

/// 실행 가능한 **정규 파일**인가. access(X_OK)는 디렉터리도 통과시키므로 경로 끝에 `/`를 붙여 한 번 더 본다
/// (정규 파일이면 ENOTDIR로 실패) — app_session.isExecutablePath와 같은 판정이다.
fn isExecutableFile(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    if (std.c.access(z.ptr, std.posix.X_OK) != 0) return false;
    const dz = std.fmt.bufPrintZ(&buf, "{s}/", .{path}) catch return false;
    return std.c.access(dz.ptr, std.posix.F_OK) != 0;
}

fn pathEnv() []const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        if (std.mem.startsWith(u8, pair, "PATH=")) return pair["PATH=".len..];
    }
    return "";
}

/// 창 하나가 동시에 돌리는 git 읽기 요청 수. 뷰가 하나뿐이라 1이면 충분하고, 갱신이 겹치면 뒤 요청을 버린다
/// (오래된 결과로 화면을 덮어쓰지 않기 위해 어차피 최신 하나만 쓴다).
pub const max_inflight: usize = 1;

/// 명령 하나의 출력 상한. 변경 파일이 수만 개인 저장소에서도 목록은 화면에 다 못 들어가므로, 여기서 잘라도
/// 사용자가 보는 것은 같다. 상한을 넘으면 **잘린 사실을 결과에 싣는다** — 조용히 일부만 보여 주지 않는다.
pub const max_output_bytes: usize = 1 << 20;

pub const Result = struct {
    /// `git status --porcelain=v2 --branch` 출력.
    status: []u8 = &.{},
    /// `git diff --numstat --cached` 출력.
    numstat_staged: []u8 = &.{},
    /// `git diff --numstat` 출력.
    numstat_worktree: []u8 = &.{},
    /// 셋 다 정상 종료했는가. 하나라도 실패하면 부분 결과를 쓰지 않는다(섹션이 서로 다른 시점을 섞지 않게).
    ok: bool = false,
    /// 출력이 상한에 걸려 잘렸는가. 목록 끝에 그 사실을 표시한다.
    truncated: bool = false,
    /// 이 결과가 어느 요청의 것인지. 늦게 온 결과가 최신 화면을 덮어쓰지 않게 호출자가 대조한다.
    request_id: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.numstat_staged);
        allocator.free(self.numstat_worktree);
        self.* = .{};
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(u32) = .init(1),
    shutting_down: bool = false,
    inflight: usize = 0,
    result: ?Result = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*r| r.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const Job = struct {
    state: *State,
    /// worker가 소유하고 끝나면 해제한다(호출자 문자열 수명에 매이지 않게 복사해 넘긴다).
    git_exe: []u8,
    repo: []u8,
    request_id: u64,
};

pub const Backend = struct {
    state: ?*State = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        state.mutex.unlock(state.io);
        self.state = null;
        state.release();
    }

    /// 요청을 건다. frame tick에서 불러도 syscall이 없다(스레드 생성만). 이미 in-flight면 false —
    /// 호출자는 다음 갱신 시점에 다시 시도한다(큐를 쌓아 오래된 결과를 줄줄이 만들지 않는다).
    pub fn submit(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight >= max_inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandon();
        job.* = .{
            .state = state,
            .git_exe = state.allocator.dupe(u8, git_exe) catch {
                state.allocator.destroy(job);
                return self.abandon();
            },
            .repo = undefined,
            .request_id = request_id,
        };
        job.repo = state.allocator.dupe(u8, repo) catch {
            state.allocator.free(job.git_exe);
            state.allocator.destroy(job);
            return self.abandon();
        };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.free(job.git_exe);
            state.allocator.free(job.repo);
            state.allocator.destroy(job);
            return self.abandon();
        };
        thread.detach();
        return true;
    }

    fn abandon(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    /// 완료 결과 하나의 소유권을 호출자에게 넘긴다. frame tick에서 불러도 syscall이 없다.
    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.result orelse return null;
        state.result = null;
        return result;
    }
};

fn worker(job: *Job) void {
    const state = job.state;
    var result: Result = .{ .request_id = job.request_id };
    var ok = true;
    var truncated = false;
    inline for (.{
        .{ git_command.Kind.status, "status" },
        .{ git_command.Kind.numstat_staged, "numstat_staged" },
        .{ git_command.Kind.numstat_worktree, "numstat_worktree" },
    }) |pair| {
        if (ok) {
            const out = run(state.allocator, pair[0], job.git_exe, job.repo) catch null;
            if (out) |o| {
                @field(result, pair[1]) = o.bytes;
                if (o.truncated) truncated = true;
            } else ok = false;
        }
    }
    result.ok = ok;
    result.truncated = truncated;
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    // **실패해도 결과를 남긴다.** 안 남기면 호출자의 in-flight가 영영 안 풀려 화면이 "읽는 중"에 고착된다
    // (손 확인에서 실제로 그랬다). 실패는 `ok=false`로 실어 호출자가 상태를 구분해 표시한다.
    if (!state.shutting_down and state.result == null) {
        state.result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

const Output = struct { bytes: []u8, truncated: bool };

fn run(allocator: std.mem.Allocator, kind: git_command.Kind, git_exe: []const u8, repo: []const u8) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv_slices = git_command.build(kind, git_exe, repo, &argv_buf);

    // **posix fork+exec+pipe로 띄운다**(update_check.zig·ssh_upload.zig와 같은 결). `std.process.run`은 0.16에서
    // io 기반인데 앱 Io가 `init_single_threaded`(할당기 없음·동시성 미지원)라 그 자리에서 OutOfMemory로 실패한다 —
    // 목록이 영영 "읽는 중"에 머무는 원인이었고, backend 전용 Io를 따로 만들어도 자식 대기에서 블록했다.
    // io를 안 쓰는 이 경로만 백그라운드 스레드에서 성립한다(end-to-end 테스트가 이 결론을 고정한다).
    var argv_store: [git_command.max_argv][:0]u8 = undefined;
    var argv: [git_command.max_argv + 1:null]?[*:0]const u8 = undefined;
    var built: usize = 0;
    defer for (argv_store[0..built]) |a| allocator.free(a);
    for (argv_slices) |a| {
        argv_store[built] = allocator.dupeZ(u8, a) catch return error.GitFailed;
        argv[built] = argv_store[built].ptr;
        built += 1;
    }
    argv[built] = null;

    // 환경은 **상속한 뒤 덮어쓴다**. 사용자 환경의 GIT_* 가 읽기 전용 계약을 깨므로 override가 마지막에 와야 하고
    // (git_command.env_overrides), 상속을 통째로 버리면 사용자의 git 설정 경로가 달라져 셸에서 보는 것과 다른 답이
    // 나온다. execve는 배열 하나만 받으므로 여기서 합쳐 만든다.
    var env_store: std.ArrayList([:0]u8) = .empty;
    defer {
        for (env_store.items) |e| allocator.free(e);
        env_store.deinit(allocator);
    }
    var env_ptrs: std.ArrayList(?[*:0]const u8) = .empty;
    defer env_ptrs.deinit(allocator);
    var i: usize = 0;
    outer: while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        for (git_command.env_overrides) |o| {
            if (std.mem.eql(u8, pair[0..eq], o.name)) continue :outer; // override가 이긴다
        }
        const copy = allocator.dupeZ(u8, pair) catch return error.GitFailed;
        env_store.append(allocator, copy) catch return error.GitFailed;
        env_ptrs.append(allocator, copy.ptr) catch return error.GitFailed;
    }
    for (git_command.env_overrides) |o| {
        const joined = std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ o.name, o.value }, 0) catch return error.GitFailed;
        env_store.append(allocator, joined) catch return error.GitFailed;
        env_ptrs.append(allocator, joined.ptr) catch return error.GitFailed;
    }
    env_ptrs.append(allocator, null) catch return error.GitFailed;

    // stdout만 받는다. stderr에는 경로·사용자·저장소 정보가 섞이므로 파이프로 받지 않고 /dev/null로 버린다
    // (docs/editor-surface.md §6 — raw로 흘리지 않는다). 실패 여부는 종료 코드로 충분하다.
    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return error.GitFailed;
    // 동시에 도는 다른 fork(셸 PTY spawn 등)로 write 끝이 새면 EOF가 안 와 read가 영원히 블록한다.
    _ = std.c.fcntl(out_pipe[0], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(out_pipe[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        return error.GitFailed;
    }
    if (pid == 0) {
        // child: dup2/open/close/execve만(async-signal-safe).
        _ = std.c.dup2(out_pipe[1], 1);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.execve(argv[0].?, @ptrCast(&argv), @ptrCast(env_ptrs.items.ptr));
        std.c._exit(127); // execve 실패
    }

    _ = std.c.close(out_pipe[1]);
    const collected = readAllFd(allocator, out_pipe[0]);
    _ = std.c.close(out_pipe[0]);
    const bytes = collected catch {
        _ = reapPid(pid);
        return error.GitFailed;
    };
    errdefer allocator.free(bytes);
    if (reapPid(pid) != 0) return error.GitFailed;
    // 상한에 걸렸는지는 길이로 판정한다 — 잘렸으면 목록 끝에 그 사실을 표시한다(조용히 일부만 보여 주지 않는다).
    return .{ .bytes = bytes, .truncated = bytes.len >= max_output_bytes };
}

/// fd에서 EOF까지, 상한까지 읽는다(호출자 소유). 상한을 넘으면 거기서 멈추고 자식은 SIGPIPE/EPIPE로 끝난다 —
/// 화면에 못 들어갈 분량을 계속 받을 이유가 없다.
fn readAllFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch return error.ReadFailed; // EINTR는 std.posix.read가 재시도
        if (n == 0) break; // EOF
        try buf.appendSlice(allocator, tmp[0..n]);
        if (buf.items.len >= max_output_bytes) break;
    }
    return buf.toOwnedSlice(allocator);
}

/// 자식을 reap하고 exit code를 돌려준다(정상 종료가 아니면 -1). waitpid 반환값을 확인한다 — 버리면 EINTR 때
/// status가 0으로 남아 "성공"으로 오판되어 빈 출력을 정상 결과로 싣게 된다(update_check.reapPid와 같은 이유).
fn reapPid(pid: std.c.pid_t) c_int {
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) < 0) return -1;
    const us: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(us)) return @intCast(std.c.W.EXITSTATUS(us));
    return -1;
}

const testing = std.testing;

test "제출 없이 열고 닫아도 안전하다(수명 계약)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 실제 spawn을 테스트에서 돌리지 않는다 — worker가 detached라 테스트 종료와 경합해 결과가 비결정적이 된다.
    // 여기서 고정하는 것은 **수명**뿐이고, argv·env는 `session.git_command`가, 파싱은 `session.git_status`가
    // 각각 헤드리스로 전수 검증한다.
    var backend = try Backend.init(testing.allocator, std.Io.Threaded.global_single_threaded.io());
    backend.deinit();
    try testing.expect(backend.state == null);
}

test "locate는 실행 가능한 절대경로를 돌려주거나 없다고 말한다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 이 저장소의 CI·개발 기기에는 git이 있다. 있으면 절대경로 실행 파일이어야 하고, 없다면 null이어야 한다
    // (조용히 shim 경로를 돌려주면 안 된다 — 실행 시 설치 모달이 뜬다).
    if (locate(&buf)) |exe| {
        try testing.expect(std.fs.path.isAbsolute(exe));
        try testing.expect(isExecutableFile(exe));
        if (git_locate.isShim(exe)) try testing.expect(anyToolchain());
    }
}

test "실행 불가 경로는 후보에서 걸러진다" {
    try testing.expect(!isExecutableFile("/nonexistent/git"));
    try testing.expect(!isExecutableFile("/usr")); // 디렉터리는 X_OK를 통과하지만 실행 파일이 아니다
}

test "실제 저장소를 읽어 세 출력을 채운다(end-to-end)" {
    // 손 확인에서 화면이 "읽는 중"에 고착됐다. submit→worker→takeResult 전 구간이 실제로 도는지 여기서 못 박는다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest; // git 없는 기기에서는 판정할 것이 없다
    // 테스트는 저장소 안에서 돈다. `.`을 그대로 넘겨도 git이 -C로 해석하지만, 상대경로를 실행 경로에 쓰지 않는
    // 계약(§6)에 맞춰 절대경로로 바꿔 넘긴다.
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&repo_buf, repo_buf.len) orelse return error.NoCwd;
    const repo = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    var backend = try Backend.init(testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submit(exe, repo, 7));

    // git status는 큰 저장소에서 수백 ms 걸린다. 10초까지 기다린 뒤에도 없으면 배관이 끊긴 것으로 본다.
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeResult()) |taken| {
            var result = taken;
            defer result.deinit(testing.allocator);
            try testing.expectEqual(@as(u64, 7), result.request_id);
            try testing.expect(result.ok);
            try testing.expect(std.mem.startsWith(u8, result.status, "# branch."));
            return;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.GitReadNeverCompleted;
}
