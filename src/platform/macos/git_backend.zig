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
const dock_panel = maru.session.dock_panel;

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
    diff_inflight: usize = 0,
    diff_result: ?DiffResult = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*r| r.deinit(self.allocator);
        if (self.diff_result) |*r| r.deinit(self.allocator);
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
    /// diff 작업이면 읽을 대상(저장소 루트 기준 상대경로 + 비교 기준). 목록 갱신 작업이면 null이다.
    diff: ?DiffTarget = null,

    const DiffTarget = struct {
        rel_path: []u8,
        /// rename의 옛 경로(그 외 빈 값). 왼쪽(HEAD)만 이 경로를 쓴다.
        orig_rel_path: []u8,
        base: dock_panel.DiffBase,
    };
};

/// diff 본문 두 쪽. 목록 결과(`Result`)와 슬롯을 나눠 갖는다 — 목록 갱신과 본문 열기가 서로를 취소하지 않게.
pub const DiffResult = struct {
    original: []u8 = &.{},
    modified: []u8 = &.{},
    ok: bool = false,
    /// 한쪽이라도 상한에서 잘렸다. **잘린 내용을 온전한 파일처럼 보여 주지 않기 위해** 호출자가 이 사실을 쓴다.
    truncated: bool = false,
    request_id: u64 = 0,

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.original);
        allocator.free(self.modified);
        self.* = .{};
    }
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
        // 아직 안 빼 간 결과가 있으면 받지 않는다. 받으면 그 worker의 결과를 버리게 되고, 호출자의 in-flight가
        // 영영 안 풀려 **목록이 그 자리에서 얼어붙는다**(손 확인에서 실제로 그랬다 — diff 슬롯과 같은 결함).
        if (state.shutting_down or state.inflight >= max_inflight or state.result != null) {
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

    /// diff 본문 두 쪽을 읽는다. 목록 갱신과 **다른 슬롯**을 쓰므로 목록을 새로 고치는 중에도 본문을 열 수 있다.
    /// `rel_path`는 저장소 루트 기준 상대경로여야 한다(git `<rev>:<path>` 규약 — git_command.blobSpec).
    pub fn submitDiff(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        rel_path: []const u8,
        orig_rel_path: []const u8,
        base: dock_panel.DiffBase,
        request_id: u64,
    ) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        // 아직 안 빼 간 결과가 있으면 받지 않는다. 받으면 그 worker의 결과를 **버리게 되고**, 요청을 건 entry는
        // ready도 failed도 아닌 채 남아 영영 pending이 된다(리뷰에서 잡힌 고착). 호출자는 다음 폴에서 다시 건다.
        if (state.shutting_down or state.diff_inflight >= max_inflight or state.diff_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.diff_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonDiff();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id, .diff = null };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseDiffJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseDiffJob(job);
        const owned_path = state.allocator.dupe(u8, rel_path) catch return self.releaseDiffJob(job);
        job.diff = .{ .rel_path = owned_path, .orig_rel_path = &.{}, .base = base };
        job.diff.?.orig_rel_path = state.allocator.dupe(u8, orig_rel_path) catch return self.releaseDiffJob(job);
        const thread = std.Thread.spawn(.{}, diffWorker, .{job}) catch return self.releaseDiffJob(job);
        thread.detach();
        return true;
    }

    /// 부분 구성된 diff job을 되돌린다(할당 실패 경로 단일화 — 어느 단계에서 실패해도 같은 정리).
    fn releaseDiffJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        if (job.diff) |d| {
            state.allocator.free(d.rel_path);
            if (d.orig_rel_path.len > 0) state.allocator.free(d.orig_rel_path);
        }
        if (job.repo.len > 0) state.allocator.free(job.repo);
        if (job.git_exe.len > 0) state.allocator.free(job.git_exe);
        state.allocator.destroy(job);
        return self.abandonDiff();
    }

    fn abandonDiff(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.diff_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    /// 완료된 diff 본문의 소유권을 넘긴다. frame tick에서 불러도 syscall이 없다.
    pub fn takeDiffResult(self: *Backend) ?DiffResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.diff_result orelse return null;
        state.diff_result = null;
        return result;
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

/// 비교 기준에 따라 두 쪽을 모은다(docs/editor-surface.md §3.5 표).
///   staged   : `HEAD:<path>` ↔ `:<path>`   (커밋된 것 ↔ 스테이지된 것)
///   unstaged : `:<path>`     ↔ 작업트리 파일 (스테이지된 것 ↔ 지금 파일)
///   untracked: 없음          ↔ 작업트리 파일 (비교 대상이 없다 — 왼쪽은 빈 문서)
fn diffWorker(job: *Job) void {
    const state = job.state;
    const target = job.diff.?;
    var result: DiffResult = .{ .request_id = job.request_id };
    // **없는 쪽은 빈 문서다.** 추가된 파일은 왼쪽이 없고 삭제된 파일은 오른쪽이 없다 — 둘 다 정상적인 비교이며
    // 목록에서 가장 흔한 상태다. 이걸 실패로 접으면 삭제·추가를 아예 못 본다(리뷰에서 잡힌 결함).
    // 진짜 실패는 **양쪽 다 못 읽은 경우**뿐이다 — 보여 줄 것이 없다.
    var had_side = false;
    var truncated = false;

    // untracked는 비교 대상 자체가 없다 — 왼쪽을 읽지 않는다(읽으면 같은 경로가 추적 중일 때 엉뚱한 내용이 실린다).
    if (target.base != .untracked) {
        const side: git_command.BlobSide = if (target.base == .staged) .head else .index;
        if (blobSide(state.allocator, job, side)) |out| {
            result.original = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
    } else had_side = true; // 왼쪽이 없는 것이 이 기준의 정상이다

    if (target.base == .staged) {
        if (blobSide(state.allocator, job, .index)) |out| {
            result.modified = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
    } else if (worktreeSide(state.allocator, job.repo, target.rel_path)) |out| {
        result.modified = out.bytes;
        if (out.truncated) truncated = true;
        had_side = true;
    } else |_| {}

    result.ok = had_side;
    result.truncated = truncated;

    state.allocator.free(target.rel_path);
    if (target.orig_rel_path.len > 0) state.allocator.free(target.orig_rel_path);
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    // 실패도 결과로 싣는다 — 안 실으면 호출자의 in-flight가 안 풀려 화면이 "여는 중"에 고착된다(목록에서 겪은 결함).
    if (!state.shutting_down and state.diff_result == null) {
        state.diff_result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.diff_inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

/// `Output`을 그대로 돌려준다 — `truncated`를 버리면 상한에서 잘린 내용이 온전한 파일처럼 보인다(리뷰 지적).
fn blobSide(allocator: std.mem.Allocator, job: *Job, side: git_command.BlobSide) !Output {
    var spec_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    // rename은 왼쪽이 옛 경로다 — 새 경로로 HEAD를 읽으면 그 blob이 없어 비교가 통째로 실패한다.
    const target = job.diff.?;
    const path = if (side == .head and target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    const spec = git_command.blobSpec(side, path, &spec_buf) orelse return error.PathTooLong;
    return runWithArg(allocator, .show_blob, job.git_exe, job.repo, spec);
}

/// 작업트리 파일은 git을 거치지 않고 그대로 읽는다 — 같은 바이트이고 프로세스를 하나 덜 띄운다.
///
/// **symlink는 따라가지 않는다**(`O_NOFOLLOW`). 저장소에 `key.txt -> ~/.ssh/id_rsa` 같은 링크가 있으면 그 행을
/// 눌렀을 때 저장소 밖 파일 내용이 비교 화면에 그대로 실린다 — 파일 패널의 다른 읽기 경로가 이미 no-follow를
/// 강제하는 것과 같은 이유다. 링크 자체를 보여 주는 것은 후속(git은 링크 대상 경로 문자열을 blob으로 준다).
fn worktreeSide(allocator: std.mem.Allocator, repo: []const u8, rel_path: []const u8) !Output {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ repo, rel_path }) catch return error.PathTooLong;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    const bytes = try readAllFd(allocator, fd);
    return .{ .bytes = bytes, .truncated = bytes.len >= max_output_bytes };
}

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
    return runWithArg(allocator, kind, git_exe, repo, null);
}

fn runWithArg(
    allocator: std.mem.Allocator,
    kind: git_command.Kind,
    git_exe: []const u8,
    repo: []const u8,
    arg: ?[]const u8,
) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv_slices = git_command.build(kind, git_exe, repo, arg, &argv_buf);

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

test "diff 본문을 기준별로 읽는다(end-to-end)" {
    // 목록과 달리 본문은 "무엇과 무엇을 비교하는가"가 기준마다 다르다. 실제 저장소·실제 git으로 세 기준을 전부
    // 태워 그 대응을 고정한다(fake로는 `HEAD:` 와 `:` 의 차이가 검증되지 않는다).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&repo_buf, repo_buf.len) orelse return error.NoCwd;
    const repo = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    var backend = try Backend.init(testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    // 커밋돼 있는 파일이라 `HEAD:` 와 작업트리 양쪽에서 읽힌다. 내용 자체가 아니라 **비지 않았는지**를 본다
    // (내용을 고정하면 이 파일을 고칠 때마다 테스트가 깨진다).
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", .staged, 1));
    const staged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var staged_result = staged;
    defer staged_result.deinit(testing.allocator);
    try testing.expect(staged_result.ok);
    try testing.expect(staged_result.original.len > 0); // HEAD:build.zig
    try testing.expect(staged_result.modified.len > 0); // :build.zig(index)

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", .unstaged, 2));
    const unstaged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var unstaged_result = unstaged;
    defer unstaged_result.deinit(testing.allocator);
    try testing.expect(unstaged_result.ok);
    try testing.expect(unstaged_result.modified.len > 0); // 작업트리 파일(git을 안 거친다)

    // untracked는 왼쪽이 **없는 것이 정상**이다 — 실패로 접지 않는다.
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", .untracked, 3));
    const untracked = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var untracked_result = untracked;
    defer untracked_result.deinit(testing.allocator);
    try testing.expect(untracked_result.ok);
    try testing.expectEqual(@as(usize, 0), untracked_result.original.len);
    try testing.expect(untracked_result.modified.len > 0);

    // 없는 경로는 실패를 **결과로** 싣는다(in-flight가 풀려야 화면이 "여는 중"에 안 갇힌다).
    try testing.expect(backend.submitDiff(exe, repo, "no/such/file.txt", "", .staged, 4));
    const missing = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var missing_result = missing;
    defer missing_result.deinit(testing.allocator);
    try testing.expect(!missing_result.ok);
}

fn waitForDiff(backend: *Backend) ?DiffResult {
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeDiffResult()) |result| return result;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return null;
}
