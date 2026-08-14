//! 도크 소스 컨트롤 뷰의 **git 읽기 backend**(L4). render tick은 `submit`/`takeResult`만 부르고 둘 다 메모리
//! 조작뿐이다 — 실제 프로세스 spawn·출력 수집은 detached worker thread에서 한다.
//!
//! `file_tree_backend`와 같은 형태다(제출·bounded in-flight·완료 큐). 다르게 만들 이유가 없고, 같은 모양이면
//! frame tick에서 syscall이 도는지 판단하는 규칙이 하나로 유지된다.
//!
//! **무엇을 실행할지는 여기서 정하지 않는다.** argv·env는 `session.git_command`가 소유하고(안전 조건이 전부
//! 거기 있다 — docs/editor-surface-tooling.md §6) 이 모듈은 그것을 그대로 spawn한다. 출력 해석도 `session.git_status`가
//! 한다. 즉 이 파일의 책임은 **프로세스 수명과 상한**뿐이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const git_command = maru.session.git_command;
const git_locate = maru.session.git_locate;
const dock_panel = maru.session.dock_panel;
const repo_path = maru.session.repo_path;

/// **이 backend가 쓰는 유일한 allocator.** State·job·argv·결과 버퍼가 전부 여기서 나온다.
///
/// 왜 프로세스 수명이어야 하는가: worker는 detach라 자기를 만든 창 세션보다 오래 살 수 있고, 그동안 계속
/// 할당·해제한다. State를 refcount로 붙드는 것만으로는 부족하다 — **refcount는 객체를 붙들 뿐 그 객체가 나온
/// allocator를 붙들지 못한다.** 세션 수명 allocator를 쓰면 세션이 먼저 끝나는 순간 worker가 파괴된 allocator를
/// 만진다(실측: 누수 2건 + segfault).
///
/// **결과 버퍼도 여기서 나온다** — `Result`/`DiffResult`/`SnapshotResult`/`BranchesResult`를 넘겨받은 쪽은
/// 반드시 이 allocator로 해제해야 한다(세션 allocator로 해제하면 heap이 깨진다). 그래서 pub이다.
pub const worker_allocator: std.mem.Allocator = std.heap.smp_allocator;

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

/// 명령 하나의 출력 상한. 상한을 넘으면 **잘린 사실을 결과에 싣는다** — 조용히 일부만 보여 주지 않는다.
///
/// **payload 상한(`diff_payload.max_side_bytes`)보다 커야 한다.** 작으면 blob이 여기서 먼저 잘려 "너무 큼"으로
/// 거절되는데, 그 판단은 payload 정책이 해야 한다(같은 한계를 두 곳에서 다르게 말하면 안 된다). 목록 출력은
/// 원래 이보다 훨씬 작다.
pub const max_output_bytes: usize = 16 << 20;

pub const Result = struct {
    /// `git status --porcelain=v2 --branch` 출력.
    status: []u8 = &.{},
    /// `git diff --numstat HEAD` 출력 — **목록 행의 증감**(행의 기본 비교와 같은 범위). unborn 저장소에서는
    /// HEAD가 없어 실패하므로 **빈 문자열**이고, 그때는 호출자가 `numstat_staged`를 대신 쓴다(§3.5.2).
    numstat_head: []u8 = &.{},
    /// `git diff --numstat --cached` 출력.
    numstat_staged: []u8 = &.{},
    /// `git diff --numstat` 출력.
    numstat_worktree: []u8 = &.{},
    /// 기본 브랜치와 갈린 지점 이후 이 브랜치가 바꾼 것(`--name-status`/`--numstat`). **없으면 빈 문자열**이고
    /// 그건 실패가 아니라 "그 섹션이 없는 것"이다(origin/HEAD 없는 저장소 — docs/editor-surface-dock.md §3.5).
    branch_name_status: []u8 = &.{},
    branch_numstat: []u8 = &.{},
    /// 그 갈린 지점의 커밋 해시. 브랜치 섹션 행의 diff 왼쪽이 이 커밋이다.
    merge_base: []u8 = &.{},
    /// 마지막 턴 스냅샷 이후 바뀐 것(§6.1). 스냅샷이 없으면 빈 문자열이고 그 섹션은 안 나온다.
    turn_name_status: []u8 = &.{},
    turn_numstat: []u8 = &.{},
    /// 셋 다 정상 종료했는가. 하나라도 실패하면 부분 결과를 쓰지 않는다(섹션이 서로 다른 시점을 섞지 않게).
    ok: bool = false,
    /// 출력이 상한에 걸려 잘렸는가. 목록 끝에 그 사실을 표시한다.
    truncated: bool = false,
    /// 이 결과가 어느 요청의 것인지. 늦게 온 결과가 최신 화면을 덮어쓰지 않게 호출자가 대조한다.
    request_id: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.numstat_head);
        allocator.free(self.numstat_staged);
        allocator.free(self.numstat_worktree);
        allocator.free(self.branch_name_status);
        allocator.free(self.branch_numstat);
        allocator.free(self.merge_base);
        allocator.free(self.turn_name_status);
        allocator.free(self.turn_numstat);
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
    /// 턴 스냅샷은 **별도 슬롯**이다 — 턴이 끝나는 순간은 사용자가 목록을 보거나 diff를 여는 순간과 겹치는데,
    /// 슬롯을 공유하면 그때마다 한쪽이 취소돼 "가끔 스냅샷이 안 찍히는" 상태가 된다.
    snapshot_inflight: usize = 0,
    snapshot_result: ?SnapshotResult = null,
    branches_inflight: usize = 0,
    branches_result: ?BranchesResult = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*r| r.deinit(self.allocator);
        if (self.diff_result) |*r| r.deinit(self.allocator);
        if (self.snapshot_result) |*r| r.deinit(self.allocator);
        if (self.branches_result) |*r| r.deinit(self.allocator);
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
    /// 목록 작업이 함께 읽을 턴 스냅샷(빈 값이면 그 섹션 없음).
    snapshot_tree: []u8 = &.{},
    index_file: []u8 = &.{},
    /// diff 작업이면 읽을 대상(저장소 루트 기준 상대경로 + 비교 기준). 목록 갱신 작업이면 null이다.
    diff: ?DiffTarget = null,

    const DiffTarget = struct {
        rel_path: []u8,
        /// rename의 옛 경로(그 외 빈 값). 왼쪽(HEAD)만 이 경로를 쓴다.
        orig_rel_path: []u8,
        /// `.branch` 기준의 왼쪽 커밋(merge-base 해시). 다른 기준에서는 빈 값이다.
        merge_base: []u8,
        base: dock_panel.DiffBase,
    };
};

/// 턴 스냅샷 결과. `tree`가 비어 있으면 실패다(저장소가 아니거나 git이 거절).
/// 로컬 브랜치 목록. `for-each-ref` 출력을 **줄 단위 그대로** 담는다 — 쪼개는 것은 소비자(순수 파서)가 한다.
pub const BranchesResult = struct {
    request_id: u64,
    ok: bool = false,
    /// `\n`으로 구분된 브랜치 이름들(owned). 실패면 빈 슬라이스.
    text: []u8 = &.{},

    pub fn deinit(self: *BranchesResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.text = &.{};
    }
};

pub const SnapshotResult = struct {
    tree: []u8 = &.{},
    surface_id: u64 = 0,

    pub fn deinit(self: *SnapshotResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tree);
        self.* = .{};
    }
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

    /// **allocator를 받지 않는다.** 이 backend의 worker는 detach되어 소유자(창 세션)보다 오래 살 수 있고,
    /// 살아 있는 동안 계속 할당·해제한다. 그래서 필요한 것은 "State를 refcount로 붙드는 것"이 아니라
    /// **allocator 자체가 worker보다 오래 사는 것**이다 — refcount는 객체를 붙들 뿐 allocator를 붙들지 못한다.
    ///
    /// 그 요구를 호출자에게 맡기면 조용히 어길 수 있다(실제로 테스트가 `testing.allocator`를 넘겨 어겼고,
    /// worker가 파괴된 allocator로 argv를 할당·해제하다 누수 2건 + segfault가 났다). 그래서 **인자에서 없애고**
    /// 프로세스 수명 allocator를 여기서 고정한다 — 이제 어길 수 있는 호출자가 존재하지 않는다.
    ///
    /// 대가(정직하게): 이 backend가 쓰는 메모리는 `testing.allocator`의 누수 검출 대상이 아니다. 대신 해제는
    /// refcount가 보장하고 할당 크기가 유계다(출력 상한·`--count=200`). 이건 detach 설계가 원래 택한 대가이고,
    /// 창을 닫을 때 background 작업을 기다리지 않는다는 이득과 맞바꾼 것이다.
    pub fn init(io: std.Io) !Backend {
        const state = try worker_allocator.create(State);
        errdefer worker_allocator.destroy(state);
        state.* = .{ .allocator = worker_allocator, .io = io };
        return .{ .state = state };
    }

    /// **기다리지 않는다.** 돌고 있는 worker는 detach된 채 두고 자기 ref만 놓는다 — 창을 닫는 경로라 여기서
    /// background 작업의 완료를 기다리면 그만큼 UI가 멈춘다. 기다릴 이유도 없다: `shutting_down`이 켜졌으니
    /// 그 결과는 어차피 버려지고, worker가 쓰는 allocator는 프로세스 수명이라(`init` 참고) 우리가 사라져도 유효하다.
    /// 마지막 ref를 놓는 쪽이 State를 회수한다.
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
    pub fn submit(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        /// 마지막 턴 스냅샷 tree(없으면 빈 문자열 — 그러면 그 섹션을 아예 안 읽는다).
        snapshot_tree: []const u8,
        index_file: []const u8,
        request_id: u64,
    ) bool {
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
        job.snapshot_tree = state.allocator.dupe(u8, snapshot_tree) catch &.{};
        job.index_file = state.allocator.dupe(u8, index_file) catch &.{};
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
        merge_base: []const u8,
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
        job.diff = .{ .rel_path = owned_path, .orig_rel_path = &.{}, .merge_base = &.{}, .base = base };
        job.diff.?.orig_rel_path = state.allocator.dupe(u8, orig_rel_path) catch return self.releaseDiffJob(job);
        job.diff.?.merge_base = state.allocator.dupe(u8, merge_base) catch return self.releaseDiffJob(job);
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
            if (d.merge_base.len > 0) state.allocator.free(d.merge_base);
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

    /// 턴 스냅샷을 찍는다(별도 슬롯). 실패하면 그냥 안 찍힌 것이고, 다음 턴에 다시 시도한다 —
    /// 스냅샷 실패로 목록·diff가 영향을 받지 않게 결과 슬롯을 나눠 뒀다.
    /// 로컬 브랜치 목록을 비동기로 읽는다. 읽기 전용이라 index/네트워크를 안 건드린다(git_command.branches 계약).
    /// 이미 하나가 돌고 있거나 결과가 안 걷혔으면 **거절한다**(false) — 클릭 연타로 프로세스가 쌓이지 않게.
    pub fn submitBranches(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.branches_inflight >= max_inflight or state.branches_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.branches_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonBranches();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseBranchesJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseBranchesJob(job);
        const thread = std.Thread.spawn(.{}, branchesWorker, .{job}) catch return self.releaseBranchesJob(job);
        thread.detach();
        return true;
    }

    fn releaseBranchesJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        state.allocator.destroy(job);
        return self.abandonBranches();
    }

    fn abandonBranches(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.branches_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    pub fn takeBranchesResult(self: *Backend) ?BranchesResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.branches_result orelse return null;
        state.branches_result = null;
        return result;
    }

    pub fn submitSnapshot(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        index_file: []const u8,
        surface_id: u64,
    ) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.snapshot_inflight >= max_inflight or state.snapshot_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.snapshot_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(SnapshotJob) catch return self.abandonSnapshot();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .index_file = &.{}, .surface_id = surface_id };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseSnapshotJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseSnapshotJob(job);
        job.index_file = state.allocator.dupe(u8, index_file) catch return self.releaseSnapshotJob(job);
        const thread = std.Thread.spawn(.{}, snapshotWorker, .{job}) catch return self.releaseSnapshotJob(job);
        thread.detach();
        return true;
    }

    fn releaseSnapshotJob(self: *Backend, job: *SnapshotJob) bool {
        const state = job.state;
        if (job.index_file.len > 0) state.allocator.free(job.index_file);
        if (job.repo.len > 0) state.allocator.free(job.repo);
        if (job.git_exe.len > 0) state.allocator.free(job.git_exe);
        state.allocator.destroy(job);
        return self.abandonSnapshot();
    }

    fn abandonSnapshot(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.snapshot_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    pub fn takeSnapshotResult(self: *Backend) ?SnapshotResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.snapshot_result orelse return null;
        state.snapshot_result = null;
        return result;
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

/// 비교 기준에 따라 두 쪽을 모은다(docs/editor-surface-dock.md §3.5 표).
///   staged   : `HEAD:<path>` ↔ `:<path>`   (커밋된 것 ↔ 스테이지된 것)
///   unstaged : `:<path>`     ↔ 작업트리 파일 (스테이지된 것 ↔ 지금 파일)
///   untracked: 없음          ↔ 작업트리 파일 (비교 대상이 없다 — 왼쪽은 빈 문서)
const SnapshotJob = struct {
    state: *State,
    git_exe: []u8,
    repo: []u8,
    index_file: []u8,
    surface_id: u64,
};

fn snapshotWorker(job: *SnapshotJob) void {
    const state = job.state;
    var result: SnapshotResult = .{ .surface_id = job.surface_id };
    if (takeTurnSnapshot(state.allocator, job.git_exe, job.repo, job.index_file)) |tree| {
        result.tree = tree;
    } else |_| {}

    state.allocator.free(job.index_file);
    state.allocator.free(job.repo);
    state.allocator.free(job.git_exe);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    if (!state.shutting_down and state.snapshot_result == null) {
        state.snapshot_result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.snapshot_inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

fn branchesWorker(job: *Job) void {
    const state = job.state;
    var result: BranchesResult = .{ .request_id = job.request_id };
    if (run(state.allocator, .branches, job.git_exe, job.repo)) |out| {
        result.text = out.bytes;
        result.ok = true;
    } else |_| {}

    state.mutex.lockUncancelable(state.io);
    // 걷어가지 않은 앞선 결과가 있으면 그것을 버리고 새것을 남긴다(최신이 맞다).
    if (state.branches_result) |*old| old.deinit(state.allocator);
    state.branches_result = result;
    state.branches_inflight -= 1;
    state.mutex.unlock(state.io);

    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);
    state.release();
}

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
    if (target.base == .turn) {
        // 턴 기준: 스냅샷 tree ↔ 작업트리. 왼쪽은 그 tree의 blob, 오른쪽은 지금 파일이다 — 스냅샷은 커밋이 아니라
        // tree라 `<tree>:<경로>`로 읽는다(같은 `git show` 문법이다).
        if (commitSide(state.allocator, job, target.merge_base)) |out| {
            result.original = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        if (worktreeSide(state.allocator, job.repo, target.rel_path)) |out| {
            result.modified = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        result.ok = had_side;
        result.truncated = truncated;
        finishDiff(state, job, target, result);
        return;
    }

    if (target.base == .branch) {
        // 브랜치 섹션: 갈린 지점(merge-base) ↔ HEAD. 둘 다 커밋이라 작업트리를 읽지 않는다.
        if (commitSide(state.allocator, job, target.merge_base)) |out| {
            result.original = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        if (blobSide(state.allocator, job, .head)) |out| {
            result.modified = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        result.ok = had_side;
        result.truncated = truncated;
        finishDiff(state, job, target, result);
        return;
    }

    if (target.base != .untracked) {
        // 충돌은 왼쪽이 HEAD다 — index엔 stage 0이 없어 `:<경로>`가 실패한다(실측).
        // 기본 비교(`head_worktree`)도 왼쪽이 HEAD다 — 오른쪽은 아래에서 작업트리를 읽는다.
        const side: git_command.BlobSide = switch (target.base) {
            .staged, .conflict, .head_worktree => .head,
            .unstaged, .untracked, .branch, .turn => .index,
        };
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

    finishDiff(state, job, target, result);
}

/// worker의 마지막 절차(소유 해제 + 결과 적재)를 한 곳에 둔다 — 기준마다 갈라진 경로가 같은 정리를 공유한다.
fn finishDiff(state: *State, job: *Job, target: Job.DiffTarget, result_in: DiffResult) void {
    var result = result_in;
    state.allocator.free(target.rel_path);
    if (target.orig_rel_path.len > 0) state.allocator.free(target.orig_rel_path);
    if (target.merge_base.len > 0) state.allocator.free(target.merge_base);
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
/// 턴 스냅샷을 찍고 tree OID를 돌려준다(호출자 소유). 세 명령이 **같은 임시 index**를 공유한다:
/// `read-tree HEAD` → `add -A` → `write-tree`. 진짜 index·작업트리는 안 바뀐다(실측으로 확인).
///
/// **임시 index는 저장소 밖**이어야 한다 — 안에 두면 그 파일 자체가 `add -A`에 잡혀 스냅샷이 자기를 포함한다.
pub fn takeTurnSnapshot(
    allocator: std.mem.Allocator,
    git_exe: []const u8,
    repo: []const u8,
    index_file: []const u8,
) ![]u8 {
    // `read-tree HEAD`는 **커밋이 하나도 없는 저장소에서 실패한다** — 그건 오류가 아니라 "기준이 빈 트리"라는
    // 뜻이다(에이전트가 새 프로젝트를 만드는 흔한 경우). 실패해도 그대로 두면 임시 index가 빈 채로 남고,
    // 이어지는 `add -A`가 작업트리 전체를 담아 정확히 우리가 원하는 스냅샷이 된다. 여기서 접으면 첫 커밋 전까지
    // "에이전트가 방금 바꾼 것"이 통째로 안 뜬다.
    {
        const out = runWithEnv(allocator, .snapshot_read_tree, git_exe, repo, null, index_file) catch null;
        if (out) |ok| {
            allocator.free(ok.bytes);
        } else {
            // 실패했으면 임시 index를 **지우고** 시작한다. 이 파일은 턴마다 재사용하므로(그래야 24 ms다),
            // 남겨 두면 지난 턴의 항목이 남아 스냅샷이 "그때 있던 파일 + 지금 파일"이 된다.
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrintZ(&path_buf, "{s}", .{index_file})) |path_z| {
                _ = std.c.unlink(path_z.ptr);
            } else |_| {}
        }
    }
    {
        const out = try runWithEnv(allocator, .snapshot_add, git_exe, repo, null, index_file);
        allocator.free(out.bytes); // 출력이 없다(실패는 종료 코드로 온다)
    }
    const written = try runWithEnv(allocator, .snapshot_write_tree, git_exe, repo, null, index_file);
    errdefer allocator.free(written.bytes);
    const trimmed = std.mem.trim(u8, written.bytes, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(written.bytes);
        return error.GitFailed;
    }
    const oid = try allocator.dupe(u8, trimmed);
    allocator.free(written.bytes);
    return oid;
}

/// 스냅샷 이후 바뀐 것(`--name-status`/`--numstat`). 비교 시점의 작업트리를 같은 임시 index에 다시 반영한 뒤 본다 —
/// 그래야 추적되지 않은 파일까지 들어온다.
pub fn diffSinceSnapshot(
    allocator: std.mem.Allocator,
    git_exe: []const u8,
    repo: []const u8,
    index_file: []const u8,
    tree_oid: []const u8,
    kind: git_command.Kind,
) ![]u8 {
    const refreshed = try runWithEnv(allocator, .snapshot_read_tree, git_exe, repo, null, index_file);
    allocator.free(refreshed.bytes);
    const added = try runWithEnv(allocator, .snapshot_add, git_exe, repo, null, index_file);
    allocator.free(added.bytes);
    const out = try runWithEnv(allocator, kind, git_exe, repo, tree_oid, index_file);
    return out.bytes;
}

/// 그 커밋의 blob(브랜치 섹션 왼쪽). rename이면 옛 경로를 읽는다 — 새 경로는 그 커밋에 없다.
fn commitSide(allocator: std.mem.Allocator, job: *Job, rev: []const u8) !Output {
    var spec_buf: [std.fs.max_path_bytes + 72]u8 = undefined;
    const target = job.diff.?;
    const path = if (target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    const trimmed = std.mem.trim(u8, rev, " \t\r\n"); // merge-base 출력은 개행으로 끝난다
    const spec = git_command.commitBlobSpec(trimmed, path, &spec_buf) orelse return error.BadRev;
    return runWithArg(allocator, .show_blob, job.git_exe, job.repo, spec);
}

fn blobSide(allocator: std.mem.Allocator, job: *Job, side: git_command.BlobSide) !Output {
    var spec_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    // rename은 왼쪽이 옛 경로다 — 새 경로로 HEAD를 읽으면 그 blob이 없어 비교가 통째로 실패한다.
    const target = job.diff.?;
    const path = if (side == .head and target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    if (!repo_path.isSafeRelative(path)) return error.UnsafePath;
    const spec = git_command.blobSpec(side, path, &spec_buf) orelse return error.PathTooLong;
    return runWithArg(allocator, .show_blob, job.git_exe, job.repo, spec);
}

/// 작업트리 파일은 git을 거치지 않고 그대로 읽는다 — 같은 바이트이고 프로세스를 하나 덜 띄운다.
///
/// **경로 요소마다 symlink를 거부한다.** 마지막 요소만 `O_NOFOLLOW`로 막으면 중간 디렉터리가 링크일 때(`a/b.txt`의
/// `a`가 `/etc`를 가리킴) 저장소 밖이 열린다. diff는 남의 코드를 보려고 만든 기능이라 **적대적 저장소를 여는 것이
/// 정상 사용**이고(§6), 읽은 내용은 신뢰 origin 웹뷰로 들어간다. 파일 패널의 다른 읽기 경로도 component마다
/// no-follow를 강제한다 — diff만 예외로 둘 이유가 없다.
fn worktreeSide(allocator: std.mem.Allocator, repo: []const u8, rel_path: []const u8) !Output {
    if (!repo_path.isSafeRelative(rel_path)) return error.UnsafePath;
    const fd = try openNoFollow(repo, rel_path);
    defer _ = std.c.close(fd);
    const bytes = try readAllFd(allocator, fd);
    return .{ .bytes = bytes, .truncated = bytes.len >= max_output_bytes };
}

/// 저장소 루트에서 시작해 경로 요소를 하나씩 `openat`으로 내려가며 연다. **각 단계가 `O_NOFOLLOW`**라 어느
/// 요소든 symlink면 그 자리에서 실패한다(ELOOP). 마지막 요소만 파일로 연다.
fn openNoFollow(repo: []const u8, rel_path: []const u8) !c_int {
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_z = std.fmt.bufPrintZ(&repo_buf, "{s}", .{repo}) catch return error.PathTooLong;
    // 루트 자체는 사용자가 연 폴더라 따라가도 된다(그 경로를 고른 것이 사용자다) — 그 **아래**부터 막는다.
    var dir_fd = std.c.open(repo_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true });
    if (dir_fd < 0) return error.OpenFailed;

    var it = std.mem.splitScalar(u8, rel_path, '/');
    var pending: ?[]const u8 = it.next();
    while (pending) |segment| {
        const next = it.next();
        var seg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seg_z = std.fmt.bufPrintZ(&seg_buf, "{s}", .{segment}) catch {
            _ = std.c.close(dir_fd);
            return error.PathTooLong;
        };
        const is_last = next == null;
        const flags: std.c.O = if (is_last)
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }
        else
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true };
        const opened = std.c.openat(dir_fd, seg_z.ptr, flags, @as(std.c.mode_t, 0));
        _ = std.c.close(dir_fd);
        if (opened < 0) return error.OpenFailed;
        if (is_last) return opened;
        dir_fd = opened;
        pending = next;
    }
    _ = std.c.close(dir_fd);
    return error.OpenFailed; // rel_path가 비어 있었다(isSafeRelative가 이미 막지만 경로를 열어 두지 않는다)
}

fn worker(job: *Job) void {
    const state = job.state;
    var result: Result = .{ .request_id = job.request_id };
    var ok = true;
    var truncated = false;
    // 브랜치 범위 셋은 **선택**이다: origin/HEAD가 없으면 실패하는데 그건 정상이고 그 섹션만 없다.
    // 여기서 ok를 내리면 기준을 못 잡는 저장소에서 목록 전체가 실패로 보인다.
    inline for (.{
        .{ git_command.Kind.merge_base, "merge_base" },
        .{ git_command.Kind.branch_name_status, "branch_name_status" },
        .{ git_command.Kind.branch_numstat, "branch_numstat" },
        // **`numstat_head`도 선택이다**: unborn 저장소에는 HEAD가 없어 실패하는데, 그건 그 상태의 정상이고
        // 그때는 목록이 `numstat_staged`로 증감을 붙인다. 여기서 ok를 내리면 첫 커밋 전 저장소가 통째로
        // "git 읽기에 실패했습니다"가 된다.
        .{ git_command.Kind.numstat_head, "numstat_head" },
    }) |pair| {
        if (run(state.allocator, pair[0], job.git_exe, job.repo)) |out| {
            @field(result, pair[1]) = out.bytes;
        } else |_| {}
    }
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
    // 턴 범위는 스냅샷이 있을 때만 읽는다. **실패해도 목록을 깨지 않는다**(브랜치 섹션과 같은 규율).
    if (ok and job.snapshot_tree.len > 0 and job.index_file.len > 0) {
        if (diffSinceSnapshot(state.allocator, job.git_exe, job.repo, job.index_file, job.snapshot_tree, .snapshot_name_status)) |bytes| {
            result.turn_name_status = bytes;
        } else |_| {}
        if (diffSinceSnapshot(state.allocator, job.git_exe, job.repo, job.index_file, job.snapshot_tree, .snapshot_numstat)) |bytes| {
            result.turn_numstat = bytes;
        } else |_| {}
    }
    result.ok = ok;
    result.truncated = truncated;
    if (job.snapshot_tree.len > 0) state.allocator.free(job.snapshot_tree);
    if (job.index_file.len > 0) state.allocator.free(job.index_file);
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
    return runWithEnv(allocator, kind, git_exe, repo, arg, null);
}

/// `index_file`이 있으면 `GIT_INDEX_FILE`로 걸어 **그 index에만** 쓰게 한다(턴 스냅샷). 진짜 index를 안 건드리는
/// 근거가 이 한 줄이므로, 스냅샷 명령은 반드시 이 경로로만 돈다.
fn runWithEnv(
    allocator: std.mem.Allocator,
    kind: git_command.Kind,
    git_exe: []const u8,
    repo: []const u8,
    arg: ?[]const u8,
    index_file: ?[]const u8,
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
        // 사용자 환경의 `GIT_INDEX_FILE`은 **항상 버린다**. 남겨 두면 우리 명령이 그 index에 쓰게 되어, 스냅샷이
        // 아닌 명령까지 남의 index를 건드린다(스냅샷은 아래에서 우리 값을 명시적으로 건다).
        if (std.mem.eql(u8, pair[0..eq], "GIT_INDEX_FILE")) continue :outer;
        const copy = allocator.dupeZ(u8, pair) catch return error.GitFailed;
        env_store.append(allocator, copy) catch return error.GitFailed;
        env_ptrs.append(allocator, copy.ptr) catch return error.GitFailed;
    }
    for (git_command.env_overrides) |o| {
        const joined = std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ o.name, o.value }, 0) catch return error.GitFailed;
        env_store.append(allocator, joined) catch return error.GitFailed;
        env_ptrs.append(allocator, joined.ptr) catch return error.GitFailed;
    }
    if (index_file) |path| {
        const joined = std.fmt.allocPrintSentinel(allocator, "GIT_INDEX_FILE={s}", .{path}, 0) catch return error.GitFailed;
        env_store.append(allocator, joined) catch return error.GitFailed;
        env_ptrs.append(allocator, joined.ptr) catch return error.GitFailed;
    }
    env_ptrs.append(allocator, null) catch return error.GitFailed;

    // stdout만 받는다. stderr에는 경로·사용자·저장소 정보가 섞이므로 파이프로 받지 않고 /dev/null로 버린다
    // (docs/editor-surface-tooling.md §6 — raw로 흘리지 않는다). 실패 여부는 종료 코드로 충분하다.
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
    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
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

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submit(exe, repo, "", "", 7));

    // git status는 큰 저장소에서 수백 ms 걸린다. 10초까지 기다린 뒤에도 없으면 배관이 끊긴 것으로 본다.
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
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

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    // 커밋돼 있는 파일이라 `HEAD:` 와 작업트리 양쪽에서 읽힌다. 내용 자체가 아니라 **비지 않았는지**를 본다
    // (내용을 고정하면 이 파일을 고칠 때마다 테스트가 깨진다).
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", .staged, 1));
    const staged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var staged_result = staged;
    defer staged_result.deinit(worker_allocator);
    try testing.expect(staged_result.ok);
    try testing.expect(staged_result.original.len > 0); // HEAD:build.zig
    try testing.expect(staged_result.modified.len > 0); // :build.zig(index)

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", .unstaged, 2));
    const unstaged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var unstaged_result = unstaged;
    defer unstaged_result.deinit(worker_allocator);
    try testing.expect(unstaged_result.ok);
    try testing.expect(unstaged_result.modified.len > 0); // 작업트리 파일(git을 안 거친다)

    // untracked는 왼쪽이 **없는 것이 정상**이다 — 실패로 접지 않는다.
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", .untracked, 3));
    const untracked = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var untracked_result = untracked;
    defer untracked_result.deinit(worker_allocator);
    try testing.expect(untracked_result.ok);
    try testing.expectEqual(@as(usize, 0), untracked_result.original.len);
    try testing.expect(untracked_result.modified.len > 0);

    // 없는 경로는 실패를 **결과로** 싣는다(in-flight가 풀려야 화면이 "여는 중"에 안 갇힌다).
    try testing.expect(backend.submitDiff(exe, repo, "no/such/file.txt", "", "", .staged, 4));
    const missing = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var missing_result = missing;
    defer missing_result.deinit(worker_allocator);
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

test "브랜치 기준 diff는 merge-base와 HEAD를 읽는다(end-to-end)" {
    // 다른 기준과 달리 **양쪽 다 커밋**이라 작업트리를 읽지 않는다. 실제 저장소·실제 git으로 그 대응을 고정한다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&repo_buf, repo_buf.len) orelse return error.NoCwd;
    const repo = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    // 목록 읽기가 merge-base를 함께 준다 — 브랜치 섹션의 왼쪽이 그 커밋이다.
    try testing.expect(backend.submit(exe, repo, "", "", 1));
    var listed = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer listed.deinit(worker_allocator);
    if (listed.merge_base.len == 0) return error.SkipZigTest; // origin/HEAD 없는 clone이면 이 섹션 자체가 없다
    const merge_base = std.mem.trim(u8, listed.merge_base, " \t\r\n");

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", merge_base, .branch, 2));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);
    try testing.expect(result.ok);
    try testing.expect(result.original.len > 0); // merge-base:build.zig
    try testing.expect(result.modified.len > 0); // HEAD:build.zig

    // hex가 아닌 rev는 애초에 spec이 안 만들어져 실패한다(인자 주입 차단이 실제로 걸리는지).
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "origin/HEAD", .branch, 3));
    var bad = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer bad.deinit(worker_allocator);
    try testing.expectEqual(@as(usize, 0), bad.original.len);
}

fn waitForList(backend: *Backend) ?Result {
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeResult()) |result| return result;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return null;
}

test "충돌 파일도 diff가 열린다(HEAD ↔ 작업트리)" {
    // 충돌 중에는 index에 stage 0이 없어 `:<경로>`가 실패한다 — 그대로 두면 왼쪽이 비어 파일 전체가 추가로 보인다.
    // 실제 충돌 저장소를 만들어 그 경로를 태운다(fake로는 stage 0 부재가 재현되지 않는다).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    // 저장소를 만들 자리: 현재 작업 디렉터리 밑의 임시 경로(테스트가 끝나면 지운다). `std.testing.tmpDir`는
    // 0.16에서 realpath를 안 줘서 경로를 직접 만든다.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-conflict-diff", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });

    if (!makeConflictRepo(exe, repo)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", .conflict, 1));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);

    try testing.expect(result.ok);
    try testing.expect(result.original.len > 0); // HEAD:f.txt — 비어 있으면 전부 추가로 보인다
    // 작업트리에는 충돌 표시가 들어 있다 — 그걸 그대로 보여 주는 것이 이 기준의 목적이다.
    try testing.expect(std.mem.indexOf(u8, result.modified, "<<<<<<<") != null);
}

/// 임시 디렉터리에 충돌 상태 저장소를 만든다(성공하면 true). git이 없거나 실패하면 false — 그 환경에서는 스킵한다.
fn makeConflictRepo(exe: []const u8, repo: []const u8) bool {
    const steps = [_][]const []const u8{
        &.{ exe, "init", "-q", "-b", "main", repo },
        &.{ exe, "-C", repo, "config", "user.email", "t@t" },
        &.{ exe, "-C", repo, "config", "user.name", "t" },
    };
    for (steps) |argv| {
        if (!runQuiet(argv)) return false;
    }
    writeFileAt(repo, "f.txt", "line1\nline2\n") catch return false;
    if (!runQuiet(&.{ exe, "-C", repo, "add", "f.txt" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "base" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "-b", "other" })) return false;
    writeFileAt(repo, "f.txt", "line1\nOTHER\n") catch return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "other" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "main" })) return false;
    writeFileAt(repo, "f.txt", "line1\nMAIN\n") catch return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "main" })) return false;
    // 이 merge는 **실패해야** 충돌 상태가 된다 — 성공하면 이 테스트의 전제가 깨진 것이다.
    return !runQuiet(&.{ exe, "-C", repo, "merge", "other" });
}

fn writeFileAt(dir: []const u8, name: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name });
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// argv를 돌려 성공(exit 0)이면 true. 출력은 버린다(테스트 픽스처 준비용).
pub const testRunQuiet = runQuiet;
pub const testWriteFile = writeFileAt;

fn runQuiet(argv: []const []const u8) bool {
    var store: [8][:0]u8 = undefined;
    var c_argv: [9:null]?[*:0]const u8 = undefined;
    var built: usize = 0;
    defer for (store[0..built]) |a| testing.allocator.free(a);
    for (argv) |a| {
        if (built >= store.len) return false;
        store[built] = testing.allocator.dupeZ(u8, a) catch return false;
        c_argv[built] = store[built].ptr;
        built += 1;
    }
    c_argv[built] = null;

    const pid = std.c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = std.c.execve(c_argv[0].?, @ptrCast(&c_argv), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    return reapPid(pid) == 0;
}

// [E1 종료 조건] 저장소 밖으로 나가는 경로는 읽지 않는다. 문자열 판정(`repo_path`)만으로는 symlink를 못 막으므로
// **실제 링크가 든 저장소**를 만들어 확인한다 — 이 방어가 도는지는 파일 시스템이 있어야 판정된다.
test "저장소 밖을 가리키는 symlink는 읽지 않는다" {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-symlink-escape", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });

    if (!runQuiet(&.{ exe, "init", "-q", "-b", "main", repo })) return error.SkipZigTest;
    writeFileAt(repo, "inside.txt", "safe\n") catch return error.SkipZigTest;

    // ⑴ 마지막 요소가 링크: `secret.txt -> /etc/hosts`
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = std.fmt.bufPrintZ(&link_buf, "{s}/secret.txt", .{repo}) catch return error.SkipZigTest;
    if (!runQuiet(&.{ "/bin/ln", "-s", "/etc/hosts", link })) return error.SkipZigTest;
    // ⑵ 중간 요소가 링크: `escape/ -> /etc` (마지막만 막으면 여기로 새어 나간다)
    var dir_link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_link = std.fmt.bufPrintZ(&dir_link_buf, "{s}/escape", .{repo}) catch return error.SkipZigTest;
    if (!runQuiet(&.{ "/bin/ln", "-s", "/etc", dir_link })) return error.SkipZigTest;

    // 정상 파일은 읽힌다(방어가 기능을 죽이지 않았다는 대조군).
    const inside = try worktreeSide(testing.allocator, repo, "inside.txt");
    defer testing.allocator.free(inside.bytes);
    try testing.expect(inside.bytes.len > 0);

    // 링크는 어느 위치에 있든 실패한다.
    try testing.expectError(error.OpenFailed, worktreeSide(testing.allocator, repo, "secret.txt"));
    try testing.expectError(error.OpenFailed, worktreeSide(testing.allocator, repo, "escape/hosts"));
    // 문자열 단계에서 걸리는 것들.
    try testing.expectError(error.UnsafePath, worktreeSide(testing.allocator, repo, "../outside.txt"));
    try testing.expectError(error.UnsafePath, worktreeSide(testing.allocator, repo, "/etc/hosts"));
}

test "턴 스냅샷은 진짜 index와 작업트리를 건드리지 않는다(end-to-end)" {
    // 이 기능의 안전 근거가 "임시 index만 쓴다"이므로, 실제 저장소에서 **진짜 index가 그대로인지**를 확인한다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-turn-snapshot", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });

    if (!runQuiet(&.{ exe, "init", "-q", "-b", "main", repo })) return error.SkipZigTest;
    if (!runQuiet(&.{ exe, "-C", repo, "config", "user.email", "t@t" })) return error.SkipZigTest;
    if (!runQuiet(&.{ exe, "-C", repo, "config", "user.name", "t" })) return error.SkipZigTest;
    writeFileAt(repo, "a.txt", "v1\n") catch return error.SkipZigTest;
    if (!runQuiet(&.{ exe, "-C", repo, "add", "a.txt" })) return error.SkipZigTest;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "base" })) return error.SkipZigTest;

    // 턴이 끝난 시점: 추적되는 파일 수정 + 새 파일(추적되지 않음).
    writeFileAt(repo, "a.txt", "v2\n") catch return error.SkipZigTest;
    writeFileAt(repo, "b.txt", "new\n") catch return error.SkipZigTest;

    // 임시 index는 **저장소 밖**에 둔다(안에 두면 자기가 스냅샷에 잡힌다).
    var index_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_file = std.fmt.bufPrint(&index_buf, "{s}/.zig-cache/tmp-turn-index", .{cwd}) catch return error.SkipZigTest;
    var idx_rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_rm = std.fmt.bufPrintZ(&idx_rm_buf, "{s}", .{index_file}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-f", idx_rm });
    defer _ = runQuiet(&.{ "/bin/rm", "-f", idx_rm });

    const snapshot = try takeTurnSnapshot(testing.allocator, exe, repo, index_file);
    defer testing.allocator.free(snapshot);
    try testing.expect(snapshot.len >= 40); // tree OID

    // **진짜 index는 그대로다**: a.txt는 여전히 스테이지 안 됨(`.M`), b.txt는 여전히 추적 안 됨(`?`).
    var status_buf: [git_command.max_argv][]const u8 = undefined;
    const status_argv = git_command.build(.status, exe, repo, null, &status_buf);
    _ = status_argv;
    const status = try runWithArg(testing.allocator, .status, exe, repo, null);
    defer testing.allocator.free(status.bytes);
    try testing.expect(std.mem.indexOf(u8, status.bytes, "1 .M") != null);
    try testing.expect(std.mem.indexOf(u8, status.bytes, "? b.txt") != null);

    // 스냅샷 직후에는 바뀐 게 없다.
    const none = try diffSinceSnapshot(testing.allocator, exe, repo, index_file, snapshot, .snapshot_name_status);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", std.mem.trim(u8, none, " \t\r\n"));

    // 그 뒤 파일을 고치면 **그 파일만** 나온다(추적되지 않은 새 파일도 포함).
    writeFileAt(repo, "a.txt", "v3\n") catch return error.SkipZigTest;
    writeFileAt(repo, "c.txt", "later\n") catch return error.SkipZigTest;
    const changed = try diffSinceSnapshot(testing.allocator, exe, repo, index_file, snapshot, .snapshot_name_status);
    defer testing.allocator.free(changed);
    try testing.expect(std.mem.indexOf(u8, changed, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, changed, "c.txt") != null);
    try testing.expect(std.mem.indexOf(u8, changed, "b.txt") == null); // 스냅샷에 이미 있던 파일은 안 나온다
}
