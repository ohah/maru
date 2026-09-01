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
const git_write_command = maru.session.git_write_command;
const git_locate = maru.session.git_locate;
const dock_panel = maru.session.dock_panel;
const repo_path = maru.session.repo_path;
const safe_open = @import("safe_open.zig");

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
/// `git` 실행 파일을 찾는다(POSIX 전용 — 아래 이유).
///
/// **Windows 에서는 `null` 이다.** 이 함수는 `PATH` 를 `std.c.environ` 에서 읽고 `access(X_OK)` 로
/// 걸러내는데, msvcrt 에는 `environ` 심볼이 아예 없어 **링크가 깨진다**(실측: W8.4⒞2 가 처음
/// 부르자 `lld-link: undefined symbol: environ`). 그리고 그 일이 Windows 에서는 필요하지도 않다 —
/// `CreateProcessW` 가 `PATH` 를 스스로 찾으므로 호출자는 `"git"` 을 그대로 넘기면 된다
/// (`win32-git-smoke`·`win32-scm-draw-smoke` 가 이미 그렇게 한다).
///
/// **조용히 `null` 을 내는 것이 아니다** — 호출자는 `orelse "git"` 으로 그 뜻을 적어야 한다.
pub fn locate(buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
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
    /// **원격 저장소 루트**(`rev-parse --show-toplevel`, RS3). 로컬 읽기에서는 비어 있다 — 로컬은
    /// walk-up 으로 이미 안다. 원격은 물어봐야 하고, 그 답이 있어야 상대경로를 절대경로로 만들어
    /// **작업트리 파일을 읽을 수 있다**(diff 오른쪽).
    ///
    /// **목록과 같은 왕복에 실어 온다.** 따로 물으면 원격 왕복이 하나 더 늘고, 그 사이에 사용자가
    /// 다른 pane 으로 옮기면 루트와 목록이 다른 저장소의 것이 된다.
    repo_root: []u8 = &.{},
    /// `git status --porcelain=v2 --branch` 출력.
    status: []u8 = &.{},
    /// `git diff --numstat HEAD` 출력 — **목록 행의 증감**(행의 기본 비교와 같은 범위). unborn 저장소에서는
    /// HEAD가 없어 실패하므로 **빈 문자열**이고, 그때는 호출자가 `numstat_staged`를 대신 쓴다(§3.5.2).
    numstat_head: []u8 = &.{},
    /// `git diff --numstat --cached` 출력.
    numstat_staged: []u8 = &.{},
    /// `git diff --numstat` 출력.
    numstat_worktree: []u8 = &.{},
    /// `git worktree list --porcelain` 출력. 도크가 워크트리마다 한 줄을 세우기 때문에 읽는다(§3.5.1c).
    /// **선택이다** — 실패해도 목록은 성립한다(그 저장소는 자기 한 줄로만 뜬다).
    worktrees: []u8 = &.{},
    /// `git rev-list --count --left-right origin/HEAD...HEAD` 출력 — **기본 브랜치 대비** ahead/behind(§3.5).
    /// **선택이다**: origin/HEAD가 없거나 unborn이면 실패하고, 그때 호출자는 `status`의 `@{u}` 값으로 돌아간다.
    ahead_behind: []u8 = &.{},
    /// `git rev-parse --abbrev-ref origin/HEAD` 출력 — **기준 브랜치의 이름**(§3.5). 비어 있으면
    /// `origin/HEAD`가 없는 저장소다(clone 방식에 따라 없을 수 있다).
    ///
    /// **`ahead_behind`가 비었다는 사실과 다른 사실이다**: 그쪽은 기준이 없어도, HEAD가 unborn이어도 빈다.
    /// 두 상태의 답이 달라서(앞은 사용자가 기준을 골라야 하고 뒤는 첫 커밋이 풀어 준다) 따로 읽는다.
    default_base: []u8 = &.{},
    /// `git remote` 출력 — 이 저장소에 원격이 **있는가**(P6). 도크의 `Fetch`를 켤지 정하는 사실이고,
    /// **선택이다**: 못 읽으면 원격이 없는 것으로 보고 버튼을 끈다(없는 것을 눌러 실패로 배우게 하지 않는다).
    remotes: []u8 = &.{},
    /// 마지막 턴 스냅샷 이후 바뀐 것(§6.1). 스냅샷이 없으면 빈 문자열이고 그 섹션은 안 나온다.
    /// 셋 다 정상 종료했는가. 하나라도 실패하면 부분 결과를 쓰지 않는다(섹션이 서로 다른 시점을 섞지 않게).
    ok: bool = false,
    /// 출력이 상한에 걸려 잘렸는가. 목록 끝에 그 사실을 표시한다.
    truncated: bool = false,
    /// 이 결과가 어느 요청의 것인지. 늦게 온 결과가 최신 화면을 덮어쓰지 않게 호출자가 대조한다.
    request_id: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.status);
        allocator.free(self.numstat_head);
        allocator.free(self.numstat_staged);
        allocator.free(self.numstat_worktree);
        allocator.free(self.worktrees);
        allocator.free(self.remotes);
        allocator.free(self.ahead_behind);
        allocator.free(self.default_base);
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
    ignore_inflight: usize = 0,
    ignore_result: ?IgnoreResult = null,
    /// 머리 줄용 가벼운 읽기(P3d-③). **자기 슬롯을 쓴다** — 목록 읽기와 섞이면 둘 중 하나가 다른 쪽을
    /// 기다리게 되고, 사용자가 보고 있는 저장소의 갱신이 배경 읽기에 밀린다.
    repo_status_inflight: usize = 0,
    repo_status_result: ?RepoStatusResult = null,
    log_inflight: usize = 0,
    log_result: ?LogResult = null,
    commit_files_inflight: usize = 0,
    commit_files_result: ?CommitFilesResult = null,
    /// 쓰기도 **별도 슬롯**이다. 읽기와 공유하면 스테이지 결과가 목록 갱신에 밀려 사라지고, 호출자의
    /// in-flight가 안 풀려 `+`가 영영 안 눌린 것처럼 보인다(diff 슬롯을 가른 것과 같은 이유).
    /// **깊이는 1이다** — §6이 "큐가 아니라 in-flight 하나"라고 못박았다.
    write_inflight: usize = 0,
    write_result: ?WriteResult = null,
    /// **fetch는 쓰기와 또 다른 슬롯이다**(P6). index를 만지지 않으므로 §6의 직렬화(`index.lock` 때문에
    /// 있는 규칙) 대상이 아니고, 무엇보다 **네트워크라 오래 걸린다** — 쓰기 슬롯을 쓰면 느린 원격 하나가
    /// 커밋 버튼과 목록 갱신을 통째로 붙잡는다(§6-1이 쓰기 중 읽기를 막으므로 도크가 멈춘 것처럼 보인다).
    fetch_inflight: usize = 0,
    fetch_result: ?WriteResult = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*r| r.deinit(self.allocator);
        if (self.diff_result) |*r| r.deinit(self.allocator);
        if (self.snapshot_result) |*r| r.deinit(self.allocator);
        if (self.branches_result) |*r| r.deinit(self.allocator);
        if (self.ignore_result) |*r| r.deinit(self.allocator);
        if (self.repo_status_result) |*r| r.deinit(self.allocator);
        if (self.log_result) |*r| r.deinit(self.allocator);
        if (self.commit_files_result) |*r| r.deinit(self.allocator);
        if (self.write_result) |*r| r.deinit(self.allocator);
        if (self.fetch_result) |*r| r.deinit(self.allocator);
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
    /// 파일 목록 작업이 읽을 rev(커밋 OID 또는 턴 OID 쌍). 상태 갱신 작업은 쓰지 않는다.
    snapshot_tree: []u8 = &.{},
    /// diff 작업이면 읽을 대상(저장소 루트 기준 상대경로 + 비교 기준). 목록 갱신 작업이면 null이다.
    diff: ?DiffTarget = null,
    /// 히스토리 읽기가 요청한 커밋 수(P4). 다른 작업은 쓰지 않는다.
    limit: u32 = 0,
    /// 파일 목록 읽기가 쓸 명령(P4b 커밋 · P5 턴). 다른 작업은 쓰지 않는다.
    file_list_kind: git_command.Kind = .commit_files,
    /// 비교의 **기준**(owned, 빈 값이면 `origin/HEAD`). ahead/behind·merge-base·브랜치 범위 셋이 이 하나를
    /// 쓴다 — 갈리면 화면의 숫자와 그 아래 목록이 서로 다른 질문의 답이 된다(§3.5).
    /// **여기 오는 값은 이미 `git_command.isSafeBaseRef`를 통과했다**(`submit`이 거른다).
    base: []u8 = &.{},
    /// `check-ignore` 가 물어볼 경로들(owned, 저장소 루트 기준 상대경로). 다른 작업은 쓰지 않는다.
    /// 한 배치는 `git_command.check_ignore_batch` 이하다 — 호출자가 그만큼씩 끊어 넣는다.
    ignore_paths: [][]u8 = &.{},
    /// 원격(SSH) 실행 대상(owned, RS2 — [계획](../../../docs/plans/remote-scm.md)). 둘 다 비어 있으면
    /// **로컬**이다.
    ///
    /// **목록 읽기 job 만 채운다.** diff·쓰기·브랜치는 RS3·RS4 가 같은 자리에 붙인다 — 지금 그쪽 job 은
    /// 이 필드를 안 쓰므로(빈 슬라이스) 해제할 것도 없다.
    remote_dest: []u8 = &.{},
    remote_ctl: []u8 = &.{},
    /// 원격 **저장소 루트**(RS3). diff 의 오른쪽(작업트리)은 git 으로 못 읽어 파일을 직접 읽는데, 그때
    /// 상대경로를 절대경로로 만드는 데 쓴다. 목록 읽기에서 받아 둔 값을 호출자가 그대로 넘긴다.
    remote_root: []u8 = &.{},

    /// 이 job 이 원격이면 그 대상. 둘 중 하나라도 비면 **로컬로 본다** — 반쪽짜리 원격 대상으로
    /// 명령을 만드느니 로컬로 도는 편이 낫다는 뜻이 아니라, `buildRemote` 가 그 값을 거부하기 때문에
    /// 애초에 그 상태를 만들지 않는다(호출자가 쌍으로 넣는다).
    fn remoteTarget(self: *const Job) ?git_command.Remote {
        if (self.remote_dest.len == 0 or self.remote_ctl.len == 0) return null;
        return .{ .dest = self.remote_dest, .control_path = self.remote_ctl };
    }

    /// 원격 문자열을 해제한다(로컬 job 이면 무동작).
    fn freeRemote(self: *Job, allocator: std.mem.Allocator) void {
        if (self.remote_dest.len > 0) allocator.free(self.remote_dest);
        if (self.remote_ctl.len > 0) allocator.free(self.remote_ctl);
        if (self.remote_root.len > 0) allocator.free(self.remote_root);
        self.remote_dest = &.{};
        self.remote_ctl = &.{};
        self.remote_root = &.{};
    }

    const DiffTarget = struct {
        rel_path: []u8,
        /// rename의 옛 경로(그 외 빈 값). 왼쪽(HEAD)만 이 경로를 쓴다.
        orig_rel_path: []u8,
        /// 비교의 **왼쪽 rev**. `.commit`은 그 커밋, `.turn_range`는 왼쪽 스냅샷 tree다.
        ///
        /// 이름이 `merge_base` 였던 것은 이 자리를 처음 쓴 기준이 「브랜치에 COMMIT 됨」(`merge-base ↔ HEAD`)
        /// 이었기 때문인데, 그 기준이 2026-08-27 에 걷히면서 **merge-base 를 담는 경로가 하나도 없어졌다** —
        /// 남겨 두면 이름이 값을 두고 거짓말한다.
        left_rev: []u8,
        /// `.turn_range`의 **오른쪽 tree**. 다른 기준에서는 빈 값이다(오른쪽이 작업트리이거나 그 커밋 자신).
        right_rev: []u8 = &.{},
        base: dock_panel.DiffBase,
    };
};

/// 턴 스냅샷 결과. `tree`가 비어 있으면 실패다(저장소가 아니거나 git이 거절).
/// 로컬 브랜치 목록. `for-each-ref` 출력을 **줄 단위 그대로** 담는다 — 쪼개는 것은 소비자(순수 파서)가 한다.
/// `check-ignore` 결과 — **무시된 경로만** NUL 구분으로 담긴 원문(owned)이다. 파싱은 순수 계층
/// (`git_status.iterateIgnored`)이 하고, 여기서는 바이트만 나른다(백엔드가 의미를 해석하지 않는다).
pub const IgnoreResult = struct {
    request_id: u64,
    ok: bool = false,
    text: []u8 = &.{},

    pub fn deinit(self: *IgnoreResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.text = &.{};
    }
};

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

/// **머리 줄 하나를 채우는 가벼운 읽기**의 결과(P3d-③). 목록에 뜬 저장소 중 지금 보고 있지 않은 것들을
/// 하나씩 이 경로로 읽는다.
///
/// **`status` 하나만 돈다.** 머리 줄에 필요한 것(브랜치·분리 HEAD·ahead/behind·파일 개수)이 전부 그
/// 출력에 있고, `numstat` 셋·merge-base·branch 범위는 **펼쳐서 파일 줄을 그릴 때만** 쓰인다. 저장소
/// 여덟이면 프로세스가 48개가 아니라 13개가 되는 차이가 여기서 나온다(§3.5.1c).
/// 히스토리 탭의 커밋 목록 읽기 결과(P4). **자기 슬롯**을 쓴다 — 그 탭을 볼 때만 읽고, 목록 읽기가
/// 도는 동안에도 따로 돌 수 있어야 한다(둘은 같은 저장소를 읽지만 `index.lock`을 잡지 않는 읽기다).
pub const LogResult = struct {
    request_id: u64,
    ok: bool = false,
    /// 어느 저장소의 답인지. 목록이 그 사이에 바뀔 수 있으므로 **경로로 맞춘다**.
    repo: []u8 = &.{},
    /// 몇 개를 요청했는지. "더 보기"로 상한을 올린 뒤 늦게 온 옛 답을 구별한다.
    limit: u32 = 0,
    /// `git log --format=…` 출력(owned).
    text: []u8 = &.{},
    /// 상한에서 잘렸나. **조용히 자르지 않는다** — 목록 끝에 그 사실을 적어야 사용자가 "더 없다"와
    /// "더 못 읽었다"를 구별한다(목록 읽기가 같은 규율을 갖는다).
    truncated: bool = false,

    pub fn deinit(self: *LogResult, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.text);
        self.repo = &.{};
        self.text = &.{};
    }
};

/// **펼친 항목 하나의 파일 목록** 읽기 결과(P4b 커밋 · P5 턴). 목록 읽기와 **다른 슬롯**이다 —
/// 목록을 다시 읽는 동안에도 펼친 항목의 파일이 남아 있어야 한다.
///
/// 슬롯이 하나인 이유: 두 탭 모두 **한 번에 하나만** 펼치므로 동시에 둘을 읽을 일이 없다.
pub const CommitFilesResult = struct {
    request_id: u64,
    ok: bool = false,
    /// 어느 항목의 답인지 — 커밋이면 그 OID, 턴이면 `<treeA> <treeB>`. 사용자가 빠르게 다른 항목을
    /// 펼치면 늦게 온 답이 남의 줄을 채운다.
    oid: []u8 = &.{},
    /// `git show --name-status` 출력(owned).
    text: []u8 = &.{},
    /// 상한에서 잘렸나(위와 같은 규율).
    truncated: bool = false,

    pub fn deinit(self: *CommitFilesResult, allocator: std.mem.Allocator) void {
        allocator.free(self.oid);
        allocator.free(self.text);
        self.oid = &.{};
        self.text = &.{};
    }
};

pub const RepoStatusResult = struct {
    request_id: u64,
    ok: bool = false,
    /// 어느 저장소의 답인지. **경로를 함께 싣는다** — 목록은 그 사이에 바뀔 수 있고, 순서로 맞추면
    /// 늦게 온 답이 남의 줄을 채운다.
    repo: []u8 = &.{},
    /// `git status --porcelain=v2 --branch` 출력(owned).
    text: []u8 = &.{},

    pub fn deinit(self: *RepoStatusResult, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.text);
        self.repo = &.{};
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
        /// 비교의 **기준**(빈 값이면 `origin/HEAD`). 세 명령이 이 하나를 쓴다(§3.5).
        base: []const u8,
        request_id: u64,
        /// 원격(SSH) 대상. null 이면 로컬이다(RS2 — [계획](../../../docs/plans/remote-scm.md)).
        /// 호출자는 **control socket 이 실제로 있는지 먼저 확인**해 넘긴다 — 없으면 ssh 가 새 연결을
        /// 시도하며 비밀번호를 물을 수 있고, 그러면 이 읽기는 영영 안 끝난다.
        remote: ?git_command.Remote,
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
        // **심층 방어이지 정책이 아니다.** 고른 기준을 거르는 자리는 호출자(고를 때·읽어 올 때)다 —
        // 여기서 조용히 기본값으로 돌아가면 사용자가 고른 기준 대신 **다른 질문의 답**이 화면에 뜬다.
        // 그래도 argv에 싣기 직전에 한 번 더 보는 이유는 이 값이 파일(workspace)을 거쳐 오기 때문이다
        // (§6: 밖에서 온 문자열은 인자 자리에서 다시 본다).
        job.base = if (git_command.isSafeBaseRef(base))
            state.allocator.dupe(u8, base) catch &.{}
        else
            &.{};
        // 원격이면 대상을 **쌍으로** 싣는다. 한쪽만 실리면 `remoteTarget` 이 로컬로 읽어, 원격을 보는
        // 화면에 로컬 저장소가 뜬다 — 그래서 하나라도 복사에 실패하면 둘 다 비운다(로컬로 도는 대신
        // 이 읽기가 실패하도록 아래 `runOn` 이 거부하는 편이 낫지만, 그 판단은 argv 층 몫이다).
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch &.{};
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch &.{};
            if (job.remote_dest.len == 0 or job.remote_ctl.len == 0) job.freeRemote(state.allocator);
        }
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            job.freeRemote(state.allocator);
            state.allocator.free(job.git_exe);
            state.allocator.free(job.repo);
            state.allocator.destroy(job);
            return self.abandon();
        };
        thread.detach();
        return true;
    }

    /// 쓰기 하나를 **비동기로** 건다. **깊이 1이다** — 이미 도는 쓰기나 안 가져간 결과가 있으면 거절한다
    /// (§6: 큐가 아니라 in-flight 하나). 거절되면 호출자가 그 클릭을 낙관 반영하지 않고 흘린다.
    ///
    /// 여기서 직렬화를 **판정만** 하고 정책은 호출자가 갖는다 — 그 동안 눌린 `+`/`−`를 어떻게 다룰지는
    /// 화면 상태를 든 쪽만 안다(§7).
    pub fn submitWrite(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        kind: git_write_command.Kind,
        paths: []const []const u8,
        message_file: ?[]const u8,
        request_id: u64,
        /// 원격이면 그 대상(RS4a). `null` 이면 로컬. **쌍으로 받는다** — 반쪽만 오면
        /// `git_write_command.buildRemote` 가 거부한다.
        remote: ?git_write_command.Remote,
    ) bool {
        // **fetch는 이 문으로 못 들어온다.** 들어오면 네트워크 명령이 index 슬롯을 잡아 §6-1대로 목록
        // 읽기까지 멈춘다 — 슬롯이 갈린 이유가 사라진다.
        if (kind.usesNetwork()) return false;
        return self.submitWriteJob(.index, git_exe, repo, kind, paths, message_file, request_id, remote);
    }

    /// 원격 갱신(`fetch --prune`)을 건다(P6). **쓰기와 다른 슬롯**이라 커밋·스테이지가 막히지 않는다 —
    /// fetch는 index를 만지지 않으므로 §6의 직렬화 대상이 아니고, 네트워크라 오래 걸린다.
    ///
    /// ⚠️ **원격 저장소에는 이 문을 쓰지 않는다**(RS4 계약 §6.3). 우리 ssh 명령에는 `SSH_AUTH_SOCK` 도
    /// PATH 도 tty 도 없어(실측 2026-09-01) 인증이 필요한 원격에서 **항상** 실패하고, 물어볼 곳도 없다.
    /// 원격 fetch 는 `push`·`pull` 과 같은 길로 간다 — 활성 pane 에 명령을 넣고 실행은 사용자가 한다(RS4c).
    pub fn submitFetch(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        return self.submitWriteJob(.network, git_exe, repo, .fetch, &.{}, null, request_id, null);
    }

    fn submitWriteJob(
        self: *Backend,
        slot: WriteSlot,
        git_exe: []const u8,
        repo: []const u8,
        kind: git_write_command.Kind,
        paths: []const []const u8,
        message_file: ?[]const u8,
        request_id: u64,
        remote: ?git_write_command.Remote,
    ) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        const busy = switch (slot) {
            .index => state.write_inflight != 0 or state.write_result != null,
            .network => state.fetch_inflight != 0 or state.fetch_result != null,
        };
        if (state.shutting_down or busy) {
            state.mutex.unlock(state.io);
            return false;
        }
        switch (slot) {
            .index => state.write_inflight += 1,
            .network => state.fetch_inflight += 1,
        }
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(WriteJob) catch return self.abandonWrite(slot);
        job.* = .{
            .state = state,
            .slot = slot,
            .git_exe = &.{},
            .repo = &.{},
            .paths = &.{},
            .message_file = null,
            .kind = kind,
            .request_id = request_id,
        };
        // **원격 두 축은 쌍으로 든다** — 하나만 들면 `remoteTarget()` 이 로컬로 읽어 원격 경로를
        // 로컬 git 에 넘긴다(RS3 적대적 검증 6회차에서 diff 가 그렇게 새어 나갔다).
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch {
                job.deinit();
                return self.abandonWrite(slot);
            };
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch {
                job.deinit();
                return self.abandonWrite(slot);
            };
        }
        job.git_exe = state.allocator.dupe(u8, git_exe) catch {
            job.deinit();
            return self.abandonWrite(slot);
        };
        job.repo = state.allocator.dupe(u8, repo) catch {
            job.deinit();
            return self.abandonWrite(slot);
        };
        job.paths = state.allocator.alloc([]u8, paths.len) catch {
            job.deinit();
            return self.abandonWrite(slot);
        };
        // 부분 실패에서 `deinit`이 미초기화 슬라이스를 free하지 않도록 먼저 비운다.
        for (job.paths) |*p| p.* = &.{};
        for (paths, job.paths) |src, *dst| {
            dst.* = state.allocator.dupe(u8, src) catch {
                job.deinit();
                return self.abandonWrite(slot);
            };
        }
        if (message_file) |m| {
            job.message_file = state.allocator.dupe(u8, m) catch {
                job.deinit();
                return self.abandonWrite(slot);
            };
        }

        const thread = std.Thread.spawn(.{}, writeWorker, .{job}) catch {
            job.deinit();
            return self.abandonWrite(slot);
        };
        thread.detach();
        return true;
    }

    /// 제출에 실패했을 때 잡아 둔 자리를 되돌린다. **`abandon`과 슬롯이 달라 따로 있다.**
    fn abandonWrite(self: *Backend, slot: WriteSlot) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        switch (slot) {
            .index => state.write_inflight -= 1,
            .network => state.fetch_inflight -= 1,
        }
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    /// 끝난 쓰기 결과를 가져간다(호출자 소유 — `deinit`으로 해제한다).
    pub fn takeWriteResult(self: *Backend) ?WriteResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const taken = state.write_result;
        state.write_result = null;
        return taken;
    }

    /// 끝난 fetch 결과를 가져간다(호출자 소유). 쓰기와 **같은 모양**이다 — 성공 여부와 stderr를 함께 싣는
    /// 이유도 같다(§5: 성공을 추정하지 않고, 실패 이유를 가공해서 보여 준다).
    pub fn takeFetchResult(self: *Backend) ?WriteResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const taken = state.fetch_result;
        state.fetch_result = null;
        return taken;
    }

    /// diff 본문 두 쪽을 읽는다. 목록 갱신과 **다른 슬롯**을 쓰므로 목록을 새로 고치는 중에도 본문을 열 수 있다.
    /// `rel_path`는 저장소 루트 기준 상대경로여야 한다(git `<rev>:<path>` 규약 — git_command.blobSpec).
    pub fn submitDiff(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        rel_path: []const u8,
        orig_rel_path: []const u8,
        /// 비교의 **왼쪽 rev**(위 `DiffTarget.left_rev`).
        left_rev: []const u8,
        /// `.turn_range`의 **오른쪽 tree**(P5). 다른 기준은 빈 문자열이다 — 오른쪽이 작업트리이거나
        /// 커밋 자신이라 따로 받을 값이 없다.
        right_rev: []const u8,
        base: dock_panel.DiffBase,
        request_id: u64,
        /// 원격(SSH) 대상과 그 저장소 루트(RS3). null 이면 로컬이다. 루트는 **작업트리 쪽**을 읽을 때만
        /// 쓰이며, 비어 있으면 그 쪽을 읽지 않는다(왼쪽만 뜬 diff 가 되고, 그것이 정직하다).
        remote: ?git_command.Remote,
        remote_root: []const u8,
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
        job.diff = .{ .rel_path = owned_path, .orig_rel_path = &.{}, .left_rev = &.{}, .base = base };
        job.diff.?.orig_rel_path = state.allocator.dupe(u8, orig_rel_path) catch return self.releaseDiffJob(job);
        job.diff.?.left_rev = state.allocator.dupe(u8, left_rev) catch return self.releaseDiffJob(job);
        job.diff.?.right_rev = state.allocator.dupe(u8, right_rev) catch return self.releaseDiffJob(job);
        // 원격이면 대상을 **셋 다** 싣는다(목적지·소켓·루트). 하나라도 복사에 실패하면 전부 비운다 —
        // 반쪽 원격 대상으로는 `runOn` 이 로컬로 돌아, 원격 diff 를 보는 화면에 로컬 파일이 실린다.
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch &.{};
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch &.{};
            job.remote_root = state.allocator.dupe(u8, remote_root) catch &.{};
            if (job.remote_dest.len == 0 or job.remote_ctl.len == 0) job.freeRemote(state.allocator);
        }
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
            if (d.left_rev.len > 0) state.allocator.free(d.left_rev);
        }
        job.freeRemote(state.allocator);
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
    /// 파일 탐색기의 **무시된 항목 판정**을 건다(사용자 결정 2026-08-18). 이미 하나가 돌고 있거나 결과가
    /// 안 걷혔으면 거절한다 — 트리를 빠르게 펼칠 때 프로세스가 쌓이지 않게, 다른 읽기와 같은 규율이다.
    /// 거절되면 그 화면은 그냥 판정이 없는 상태로 남는다(모르면 흐리게 하지 않는다).
    pub fn submitCheckIgnore(self: *Backend, git_exe: []const u8, repo: []const u8, paths: []const []const u8, request_id: u64) bool {
        if (paths.len == 0) return false;
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.ignore_inflight >= max_inflight or state.ignore_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.ignore_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonIgnore();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseIgnoreJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseIgnoreJob(job);
        // 경로는 호출자 문자열 수명에 매이지 않게 복사한다(다른 job 필드와 같은 규율).
        const owned = state.allocator.alloc([]u8, @min(paths.len, git_command.check_ignore_batch)) catch return self.releaseIgnoreJob(job);
        var filled: usize = 0;
        for (paths[0..owned.len]) |path| {
            owned[filled] = state.allocator.dupe(u8, path) catch break;
            filled += 1;
        }
        job.ignore_paths = owned[0..filled];
        if (filled == 0) {
            state.allocator.free(owned);
            job.ignore_paths = &.{};
            return self.releaseIgnoreJob(job);
        }
        const thread = std.Thread.spawn(.{}, ignoreWorker, .{job}) catch return self.releaseIgnoreJob(job);
        thread.detach();
        return true;
    }

    fn releaseIgnoreJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        for (job.ignore_paths) |p| state.allocator.free(p);
        if (job.ignore_paths.len > 0) state.allocator.free(job.ignore_paths);
        state.allocator.destroy(job);
        return self.abandonIgnore();
    }

    fn abandonIgnore(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.ignore_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    /// 완료된 `check-ignore` 결과의 소유권을 넘긴다(없으면 null).
    pub fn takeIgnoreResult(self: *Backend) ?IgnoreResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const r = state.ignore_result orelse return null;
        state.ignore_result = null;
        return r;
    }

    /// 브랜치 목록을 읽는다. `kind`는 `.branches`(전환용 — 로컬만) 또는 `.base_candidates`(기준 후보 —
    /// 원격 추적 ref 포함)다. 결과는 같은 슬롯으로 오므로 **부르는 쪽이 용도를 기억해야 한다**.
    pub fn submitBranches(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        kind: git_command.Kind,
        request_id: u64,
    ) bool {
        std.debug.assert(kind == .branches or kind == .base_candidates);
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
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id, .file_list_kind = kind };
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

    /// 머리 줄 하나를 채우는 읽기를 건다. 이미 하나가 돌고 있거나 결과가 안 걷혔으면 **거절한다** —
    /// 목록이 여덟이어도 프로세스는 언제나 하나다.
    pub fn submitRepoStatus(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.repo_status_inflight > 0 or state.repo_status_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.repo_status_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonRepoStatus();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseRepoStatusJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseRepoStatusJob(job);
        const thread = std.Thread.spawn(.{}, repoStatusWorker, .{job}) catch return self.releaseRepoStatusJob(job);
        thread.detach();
        return true;
    }

    /// 히스토리 목록을 건다(P4). 하나가 돌고 있거나 결과가 안 걷혔으면 거절한다 — 탭을 빠르게
    /// 오가도 프로세스는 하나다.
    pub fn submitLog(self: *Backend, git_exe: []const u8, repo: []const u8, limit: u32, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.log_inflight > 0 or state.log_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.log_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonLog();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id, .limit = limit };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseLogJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseLogJob(job);
        const thread = std.Thread.spawn(.{}, logWorker, .{job}) catch return self.releaseLogJob(job);
        thread.detach();
        return true;
    }

    fn releaseLogJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        state.allocator.destroy(job);
        return self.abandonLog();
    }

    fn abandonLog(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.log_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    pub fn takeLogResult(self: *Backend) ?LogResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.log_result orelse return null;
        state.log_result = null;
        return result;
    }

    /// 그 커밋이 바꾼 파일 목록을 읽는다(P4b). `oid`는 hex 검증을 거친 값이어야 한다 — argv 조립이
    /// 다시 검증하지만, 여기서도 임의 문자열을 그대로 넘기지 않는 것이 규율이다.
    pub fn submitCommitFiles(self: *Backend, git_exe: []const u8, repo: []const u8, oid: []const u8, request_id: u64) bool {
        return self.submitFileList(git_exe, repo, .commit_files, oid, request_id);
    }

    /// 턴 하나가 바꾼 파일 목록(P5). 키는 `<treeA> <treeB>`이고 **둘 다 hex여야 한다**.
    pub fn submitTurnFiles(self: *Backend, git_exe: []const u8, repo: []const u8, pair: []const u8, request_id: u64) bool {
        return self.submitFileList(git_exe, repo, .turn_name_status, pair, request_id);
    }

    /// 펼친 항목 하나의 파일 목록을 읽는다(커밋·턴 공용).
    fn submitFileList(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        kind: git_command.Kind,
        key: []const u8,
        request_id: u64,
    ) bool {
        // **rev 자리에 넣어도 되는 값인지 여기서 막는다**(§6 심층 방어). blob spec 둘은 같은 술어로
        // 이미 걸러지지만, 이 명령들은 rev를 그대로 인자로 실으므로 그 검사가 여기 없으면 유일한 구멍이 된다.
        if (!isRevKey(key)) return false;
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.commit_files_inflight > 0 or state.commit_files_result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.commit_files_inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

        const job = state.allocator.create(Job) catch return self.abandonCommitFiles();
        job.* = .{ .state = state, .git_exe = &.{}, .repo = &.{}, .request_id = request_id, .file_list_kind = kind };
        job.git_exe = state.allocator.dupe(u8, git_exe) catch return self.releaseCommitFilesJob(job);
        job.repo = state.allocator.dupe(u8, repo) catch return self.releaseCommitFilesJob(job);
        job.snapshot_tree = state.allocator.dupe(u8, key) catch return self.releaseCommitFilesJob(job);
        const thread = std.Thread.spawn(.{}, commitFilesWorker, .{job}) catch return self.releaseCommitFilesJob(job);
        thread.detach();
        return true;
    }

    fn releaseCommitFilesJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        if (job.snapshot_tree.len > 0) state.allocator.free(job.snapshot_tree);
        state.allocator.destroy(job);
        return self.abandonCommitFiles();
    }

    fn abandonCommitFiles(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.commit_files_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    pub fn takeCommitFilesResult(self: *Backend) ?CommitFilesResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.commit_files_result orelse return null;
        state.commit_files_result = null;
        return result;
    }

    fn releaseRepoStatusJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        state.allocator.destroy(job);
        return self.abandonRepoStatus();
    }

    fn abandonRepoStatus(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        state.repo_status_inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    pub fn takeRepoStatusResult(self: *Backend) ?RepoStatusResult {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.repo_status_result orelse return null;
        state.repo_status_result = null;
        return result;
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

fn repoStatusWorker(job: *Job) void {
    const state = job.state;
    var result: RepoStatusResult = .{ .request_id = job.request_id };
    result.repo = state.allocator.dupe(u8, job.repo) catch &.{};
    if (run(state.allocator, .status, job.git_exe, job.repo)) |out| {
        result.text = out.bytes;
        result.ok = true;
    } else |_| {}
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    // **실패해도 결과를 남긴다** — 안 남기면 호출자의 in-flight가 안 풀려 그 줄이 영영 "읽는 중"이다
    // (목록 읽기가 같은 이유로 실패 결과를 남긴다).
    if (!state.shutting_down and state.repo_status_result == null) {
        state.repo_status_result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.repo_status_inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

fn logWorker(job: *Job) void {
    const state = job.state;
    var result: LogResult = .{ .request_id = job.request_id, .limit = job.limit };
    result.repo = state.allocator.dupe(u8, job.repo) catch &.{};
    var limit_buf: [16]u8 = undefined;
    const limit_arg = std.fmt.bufPrint(&limit_buf, "{d}", .{job.limit}) catch "200";
    if (runWithArg(state.allocator, .log, job.git_exe, job.repo, limit_arg)) |out| {
        result.text = out.bytes;
        result.truncated = out.truncated;
        result.ok = true;
    } else |_| {}
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    // **실패해도 결과를 남긴다** — 안 남기면 in-flight가 안 풀려 탭이 영영 "읽는 중"이다.
    // 첫 커밋 전 저장소는 `git log`가 실패하는데, 그건 오류가 아니라 "커밋이 없다"이고 호출자가 그렇게 읽는다.
    if (!state.shutting_down and state.log_result == null) {
        state.log_result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.log_inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

/// rev 키로 넘겨도 되는 값인가. 커밋은 hex 하나, 턴은 hex 둘(공백 구분)이다 — **둘 다** 검사한다.
fn isRevKey(key: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, key, ' ');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (!git_command.isHexRev(part)) return false;
    }
    return n == 1 or n == 2;
}

fn commitFilesWorker(job: *Job) void {
    const state = job.state;
    var result: CommitFilesResult = .{ .request_id = job.request_id };
    // 커밋 OID는 `snapshot_tree` 자리를 빌린다 — 그 필드는 "이 작업이 읽을 rev"라는 같은 뜻이다.
    result.oid = state.allocator.dupe(u8, job.snapshot_tree) catch &.{};
    if (runWithArg(state.allocator, job.file_list_kind, job.git_exe, job.repo, job.snapshot_tree)) |out| {
        result.text = out.bytes;
        result.truncated = out.truncated;
        result.ok = true;
    } else |_| {}
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    if (job.snapshot_tree.len > 0) state.allocator.free(job.snapshot_tree);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    // 실패도 결과로 남긴다 — 안 남기면 in-flight가 안 풀려 그 커밋이 영영 "읽는 중"이다.
    if (!state.shutting_down and state.commit_files_result == null) {
        state.commit_files_result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.commit_files_inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

fn ignoreWorker(job: *Job) void {
    const state = job.state;
    var result: IgnoreResult = .{ .request_id = job.request_id };
    // `run` 은 kind 하나로 argv 를 만드는 경로라, 경로가 붙는 이 명령만 argv 를 직접 조립해 넘긴다.
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.buildCheckIgnore(job.git_exe, job.repo, job.ignore_paths, &argv_buf);
    if (runArgv(state.allocator, argv)) |out| {
        result.text = out.bytes;
        // **exit code 1 은 "무시된 것이 없음"이다**(git 계약) — 실패가 아니다. `runArgv` 가 그 구분을 준다.
        result.ok = true;
    } else |_| {}

    state.mutex.lockUncancelable(state.io);
    if (state.ignore_result) |*old| old.deinit(state.allocator);
    state.ignore_result = result;
    state.ignore_inflight -= 1;
    state.mutex.unlock(state.io);

    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    for (job.ignore_paths) |p| state.allocator.free(p);
    if (job.ignore_paths.len > 0) state.allocator.free(job.ignore_paths);
    state.allocator.destroy(job);
    state.release();
}

fn branchesWorker(job: *Job) void {
    const state = job.state;
    var result: BranchesResult = .{ .request_id = job.request_id };
    // 어떤 목록인지는 **호출자가 정한다**(전환용 로컬 브랜치 / 기준 후보 — §3.5). 여기서 고르면
    // 같은 워커가 두 뜻을 갖고, 부르는 쪽은 무엇이 올지 모른 채 결과를 받는다.
    if (run(state.allocator, job.file_list_kind, job.git_exe, job.repo)) |out| {
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

/// status 읽기 한 벌의 **선택 명령들**: 실패해도 목록은 성립하고, 여기서 ok를 내리면 그 상태의 저장소에서
/// 목록 전체가 실패로 보인다.
///
/// **상수로 둔 이유는 그 수를 세는 판정자가 필요해서다.** 소비자를 잃은 읽기 셋(`merge-base`·브랜치 범위
/// `--name-status`·`--numstat`)이 13일 동안 매 status 읽기마다 프로세스를 띄우고 출력을 버렸는데, 그동안
/// **아무 테스트도 빨개지지 않았다** — 명령의 *형태*를 보는 테스트는 있었지만 *몇 개인지*를 보는 것은
/// 없었다. 아래 `한 벌이 띄우는 프로세스 수` 테스트가 그 자리를 메운다(docs/plans/scm-dock.md §2.5).
const optional_reads = .{
    // **`numstat_head`도 선택이다**: unborn 저장소에는 HEAD가 없어 실패하는데, 그건 그 상태의 정상이고
    // 그때는 목록이 `numstat_staged`로 증감을 붙인다. 여기서 ok를 내리면 첫 커밋 전 저장소가 통째로
    // "git 읽기에 실패했습니다"가 된다.
    .{ git_command.Kind.numstat_head, "numstat_head" },
    // **워크트리 목록도 선택이다.** 아주 오래된 git에는 `worktree list`가 없고, 그때는 그 저장소가
    // 목록에 자기 한 줄로만 뜬다 — 워크트리를 못 찾는 것이지 저장소를 못 읽는 것이 아니다.
    .{ git_command.Kind.worktree_list, "worktrees" },
    // **원격 목록도 선택이다.** 못 읽으면 `Fetch`가 꺼진 채 "원격 없음"으로 보이는데, 그건 틀릴 수
    // 있어도 **안전한 쪽으로 틀린다**(누르면 될 것을 못 누른다 vs. 안 되는 것을 눌러 실패를 본다).
    .{ git_command.Kind.remotes, "remotes" },
    // **기본 브랜치 대비 ahead/behind도 선택이다**(§3.5). origin/HEAD가 없는 저장소(로컬 전용·clone
    // 아님)에서는 실패하는데 그건 정상이고, 그때는 화면이 `@{u}` 값으로 돌아간다.
    .{ git_command.Kind.ahead_behind, "ahead_behind" },
    // **기준 이름 읽기도 선택이다**(§3.5). `origin/HEAD`가 없는 저장소에서 실패하고, 그 실패가 곧
    // "사용자가 기준을 골라야 한다"는 신호다 — `ahead_behind`의 실패만으로는 unborn과 구별되지 않는다.
    .{ git_command.Kind.default_base, "default_base" },
};

/// 같은 한 벌의 **필수 명령들**: 하나라도 실패하면 목록이 성립하지 않는다.
const required_reads = .{
    .{ git_command.Kind.status, "status" },
    .{ git_command.Kind.numstat_staged, "numstat_staged" },
    .{ git_command.Kind.numstat_worktree, "numstat_worktree" },
};

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
    if (target.base == .turn_range) {
        // 턴 하나: 스냅샷 tree 둘. **양쪽 다 tree라** 작업트리를 읽지 않는다 — 그 턴의 결과가 지금
        // 파일 상태와 무관하게 고정된다(§3.5.4).
        if (commitSide(state.allocator, job, target.left_rev)) |out| {
            result.original = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        if (commitSide(state.allocator, job, target.right_rev)) |out| {
            result.modified = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        result.ok = had_side;
        result.truncated = truncated;
        finishDiff(state, job, target, result);
        return;
    }

    if (target.base == .commit) {
        // 히스토리에서 고른 커밋: `커밋^ ↔ 커밋`(P4b). 둘 다 커밋이라 작업트리를 읽지 않는다 —
        // 그 커밋 시점의 두 쪽이라 지금 파일이 무엇이든 화면이 바뀌지 않아야 한다.
        //
        // **왼쪽 실패는 정상일 수 있다**: 루트 커밋에는 `^`가 없다. 그때는 오른쪽만 실려 "새로 생긴
        // 파일"과 같은 모양이 되는데, 루트 커밋의 파일은 실제로 그렇다.
        if (commitParentSide(state.allocator, job, target.left_rev)) |out| {
            result.original = out.bytes;
            if (out.truncated) truncated = true;
            had_side = true;
        } else |_| {}
        if (commitSide(state.allocator, job, target.left_rev)) |out| {
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
        const side: git_command.BlobSide = switch (target.base) {
            .staged, .conflict => .head,
            // `.commit`·`.turn_range`는 위에서 이미 돌려보냈다 — 여기 오면 그 자체가 버그다.
            .unstaged, .untracked, .commit, .turn_range => .index,
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
    } else if (worktreeSideOn(state.allocator, job, target.rel_path)) |out| {
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
    if (target.left_rev.len > 0) state.allocator.free(target.left_rev);
    if (target.right_rev.len > 0) state.allocator.free(target.right_rev);
    job.freeRemote(state.allocator);
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

/// 그 커밋의 blob(브랜치 섹션 왼쪽). rename이면 옛 경로를 읽는다 — 새 경로는 그 커밋에 없다.
fn commitSide(allocator: std.mem.Allocator, job: *Job, rev: []const u8) !Output {
    var spec_buf: [std.fs.max_path_bytes + 72]u8 = undefined;
    const target = job.diff.?;
    const path = if (target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    const trimmed = std.mem.trim(u8, rev, " \t\r\n"); // merge-base 출력은 개행으로 끝난다
    const spec = git_command.commitBlobSpec(trimmed, path, &spec_buf) orelse return error.BadRev;
    return runOn(allocator, job.remoteTarget(), .show_blob, job.git_exe, job.repo, spec);
}

/// 그 커밋의 **부모** 쪽 blob. 루트 커밋에서는 git이 실패하고 그게 곧 "왼쪽이 없다"이다.
fn commitParentSide(allocator: std.mem.Allocator, job: *Job, rev: []const u8) !Output {
    var spec_buf: [std.fs.max_path_bytes + 72]u8 = undefined;
    const target = job.diff.?;
    // rename은 왼쪽이 옛 경로다 — 새 경로로 부모를 읽으면 그 blob이 없어 왼쪽이 통째로 빈다.
    const path = if (target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    const trimmed = std.mem.trim(u8, rev, " \t\r\n");
    const spec = git_command.commitParentBlobSpec(trimmed, path, &spec_buf) orelse return error.BadRev;
    return runOn(allocator, job.remoteTarget(), .show_blob, job.git_exe, job.repo, spec);
}

fn blobSide(allocator: std.mem.Allocator, job: *Job, side: git_command.BlobSide) !Output {
    var spec_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    // rename은 왼쪽이 옛 경로다 — 새 경로로 HEAD를 읽으면 그 blob이 없어 비교가 통째로 실패한다.
    const target = job.diff.?;
    const path = if (side == .head and target.orig_rel_path.len > 0) target.orig_rel_path else target.rel_path;
    if (!repo_path.isSafeRelative(path)) return error.UnsafePath;
    const spec = git_command.blobSpec(side, path, &spec_buf) orelse return error.PathTooLong;
    return runOn(allocator, job.remoteTarget(), .show_blob, job.git_exe, job.repo, spec);
}

/// 작업트리 파일은 git을 거치지 않고 그대로 읽는다 — 같은 바이트이고 프로세스를 하나 덜 띄운다.
///
/// **경로 요소마다 symlink를 거부한다.** 마지막 요소만 `O_NOFOLLOW`로 막으면 중간 디렉터리가 링크일 때(`a/b.txt`의
/// `a`가 `/etc`를 가리킴) 저장소 밖이 열린다. diff는 남의 코드를 보려고 만든 기능이라 **적대적 저장소를 여는 것이
/// 정상 사용**이고(§6), 읽은 내용은 신뢰 origin 웹뷰로 들어간다. 파일 패널의 다른 읽기 경로도 component마다
/// no-follow를 강제한다 — diff만 예외로 둘 이유가 없다.
/// diff 의 **오른쪽(작업트리)** — 로컬이면 파일을 직접 열고, 원격이면 ssh 로 읽는다(RS3).
///
/// **git 으로는 못 읽는다**: `git show :<path>` 는 index 이고 `HEAD:<path>` 는 커밋이라, 작업트리의 지금
/// 내용을 내는 git 명령이 없다. 그래서 원격에서 이 한 자리만 git 이 아닌 명령을 쓴다
/// (`git_command.buildRemoteFileRead` — 인용·상한은 그쪽이 소유한다).
///
/// **루트가 없으면 읽지 않는다.** 원격 루트는 목록 읽기와 같은 왕복에서 받아 오는데(RS3), 그것이 비어
/// 있으면 상대경로를 절대경로로 만들 수 없다. 추측해서 여는 것보다 **오른쪽이 없는 diff** 가 정직하다.
fn worktreeSideOn(allocator: std.mem.Allocator, job: *Job, rel_path: []const u8) !Output {
    const remote = job.remoteTarget() orelse return worktreeSide(allocator, job.repo, rel_path);
    if (!repo_path.isSafeRelative(rel_path)) return error.UnsafePath;
    if (job.remote_root.len == 0) return error.GitFailed;
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ job.remote_root, rel_path }) catch return error.GitFailed;
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    var cmd_buf: [git_command.max_remote_command_bytes]u8 = undefined;
    const argv = git_command.buildRemoteFileRead(abs, remote, &argv_buf, &cmd_buf) orelse return error.GitFailed;
    const out = try runArgvWithEnv(allocator, argv, null);
    // ⚠️ **잘림을 원격 상한으로 다시 판정한다**(RS3a 적대적 검증 3회차). `runArgvWithEnv` 는 로컬 상한
    // (`max_output_bytes`, 16 MiB)으로만 보는데 원격은 그 전에 `head -c` 로 **4 MiB 에서 잘린다** —
    // 그대로 두면 잘린 파일이 `truncated = false` 로 와서 **온전한 파일처럼** 화면에 뜬다(뷰어는 잘린
    // 내용을 「너무 큼」으로 말할 기회를 잃는다).
    return .{
        .bytes = out.bytes,
        .truncated = out.truncated or out.bytes.len >= git_command.max_remote_file_bytes,
    };
}

fn worktreeSide(allocator: std.mem.Allocator, repo: []const u8, rel_path: []const u8) !Output {
    if (!repo_path.isSafeRelative(rel_path)) return error.UnsafePath;
    const fd = try safe_open.openNoFollow(repo, rel_path);
    defer _ = std.c.close(fd);
    const bytes = try readAllFd(allocator, fd);
    return .{ .bytes = bytes, .truncated = bytes.len >= max_output_bytes };
}

fn worker(job: *Job) void {
    const state = job.state;
    var result: Result = .{ .request_id = job.request_id };
    var ok = true;
    var truncated = false;
    // **고른 기준이 `↑N ↓N`의 범위를 정한다**(§3.5). 없으면(빈 값) 기본 브랜치(`origin/HEAD`)다.
    //
    // 예전에는 이 기준을 **셋이 함께** 썼다(ahead/behind · `merge-base` · 브랜치 범위 diff). 나머지 둘은
    // 「브랜치에 COMMIT 됨」섹션의 것이었고 그 섹션이 사라지며 소비자를 잃어 2026-08-27 에 걷혔다.
    var range_buf: [git_command.max_base_range_len]u8 = undefined;
    // `submit`이 이미 걸렀으므로 여기서 null이 나오지 않는다. 그래도 orelse를 두는 이유는 그 사실이
    // **다른 파일의 규율**이기 때문이다 — 그쪽이 느슨해지면 여기서 죽는 대신 기본값으로 돈다.
    const base_range: []const u8 = if (job.base.len > 0)
        (git_command.baseRange(job.base, &range_buf) orelse git_command.default_base_range)
    else
        git_command.default_base_range;
    inline for (optional_reads) |pair| {
        const arg: ?[]const u8 = switch (pair[0]) {
            .ahead_behind => base_range,
            // 기준 이름 자체를 묻는 읽기에는 기준을 안 넘긴다 — 그 답이 곧 기본값이다.
            else => null,
        };
        if (runOn(state.allocator, job.remoteTarget(), pair[0], job.git_exe, job.repo, arg)) |out| {
            @field(result, pair[1]) = out.bytes;
            // **선택 명령의 잘림도 화면에 말한다**(적대적 검증 2026-08-14). 여기서 삼키면 `numstat_head`가
            // 상한에 걸렸을 때 앞쪽 파일만 숫자를 갖고 나머지는 조용히 빈 채로 남는다 — 사용자는 그것을
            // "안 바뀐 파일"로 읽는다. 실패(그 값이 없는 것)와 잘림(값이 반만 있는 것)은 다른 상태다.
            if (out.truncated) truncated = true;
        } else |_| {}
    }
    // **원격이면 루트를 함께 묻는다**(RS3). 로컬은 walk-up 으로 이미 알아 물을 필요가 없고, 원격은
    // 이 왕복에 얹지 않으면 diff 를 열 때 왕복이 하나 더 늘어난다 — 그 사이 pane 이 바뀌면 루트와
    // 목록이 **다른 저장소**의 것이 된다.
    if (job.remoteTarget() != null) {
        if (runOn(state.allocator, job.remoteTarget(), .repo_root, job.git_exe, job.repo, null)) |out| {
            defer state.allocator.free(out.bytes);
            const trimmed = std.mem.trim(u8, out.bytes, " \t\r\n");
            if (trimmed.len > 0) result.repo_root = state.allocator.dupe(u8, trimmed) catch &.{};
        } else |_| {}
    }
    inline for (required_reads) |pair| {
        if (ok) {
            const out = runOn(state.allocator, job.remoteTarget(), pair[0], job.git_exe, job.repo, null) catch null;
            if (out) |o| {
                @field(result, pair[1]) = o.bytes;
                if (o.truncated) truncated = true;
            } else ok = false;
        }
    }
    result.ok = ok;
    result.truncated = truncated;
    if (job.base.len > 0) state.allocator.free(job.base);
    job.freeRemote(state.allocator);
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
    return runOn(allocator, null, kind, git_exe, repo, arg);
}

/// 로컬이면 argv 를 그대로, **원격이면 `buildRemote` 로 감싸** 실행한다(RS2 — [계획](../../../docs/plans/remote-scm.md)).
///
/// **감싸는 자리를 여기 하나로 둔다.** kind 마다 감싸면 하나를 빠뜨리는 순간 그 명령만 로컬에서 돌아
/// **목록은 원격인데 증감은 로컬 것**이 된다 — 화면에서는 구별되지 않는 종류의 거짓말이다.
///
/// 조립이 거절되면(`null`) `error.GitFailed` 다. 거절은 곧 「그 값으로는 원격에 아무것도 보내지 않는다」
/// 이므로(제어문자·수상한 dest·버퍼 초과), 로컬로 **폴백하지 않는다** — 폴백은 원격을 보는 사용자에게
/// 로컬 저장소를 보여 주는 바로 그 사고다.
fn runOn(
    allocator: std.mem.Allocator,
    remote: ?git_command.Remote,
    kind: git_command.Kind,
    git_exe: []const u8,
    repo: []const u8,
    arg: ?[]const u8,
) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const local = git_command.build(kind, git_exe, repo, arg, &argv_buf);
    const target = remote orelse return runArgvWithEnv(allocator, local, null);
    var remote_buf: [git_command.max_argv][]const u8 = undefined;
    var cmd_buf: [git_command.max_remote_command_bytes]u8 = undefined;
    const argv = git_command.buildRemote(local, target, &remote_buf, &cmd_buf) orelse return error.GitFailed;
    return runArgvWithEnv(allocator, argv, null);
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
    return runArgvWithEnv(allocator, argv_slices, index_file);
}

/// **argv 를 직접 받는 진입점.** `check-ignore` 는 경로가 argv 뒤에 붙어 kind 하나로 만들 수 없어
/// (`git_command.buildCheckIgnore`) 이 자리를 쓴다. 아래 본문은 원래 `runWithEnv` 의 것 그대로다 —
/// 실행 방식(fork+exec+pipe·환경 덮어쓰기·exit code 해석)을 두 벌로 만들지 않기 위해 갈랐다.
fn runArgv(allocator: std.mem.Allocator, argv_slices: []const []const u8) !Output {
    return runArgvWithEnv(allocator, argv_slices, null);
}

fn runArgvWithEnv(
    allocator: std.mem.Allocator,
    argv_slices: []const []const u8,
    index_file: ?[]const u8,
) !Output {
    // **Windows 는 `CreateProcessW` + 익명 파이프로 간다.** 아래 POSIX 갈래는 `fork`/`execve` 를 쓰는데
    // Windows 에는 없다(`std.c.fork` 가 그 타깃에서 `void` 라 분석되는 순간 컴파일이 깨진다). `comptime`
    // 분기라 **고른 쪽만 분석**되므로 두 갈래가 한 파일에 있어도 서로를 안 깨뜨린다.
    //
    // **POSIX 갈래는 한 줄도 안 건드린다.** 돌아가는 검증된 경로를 옮기지 않는 것이 이 배선의 전제다 —
    // 옮기면 검증할 수 없는 코드로 검증된 코드를 바꾸는 일이 된다(Windows 호스트에서는 POSIX 테스트를
    // 못 돌린다).
    if (comptime builtin.os.tag == .windows) return runArgvWithEnvWindows(allocator, argv_slices, index_file);

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

    // 읽기는 **stdout만** 받는다. stderr에는 경로·사용자·저장소 정보가 섞이므로 파이프로 받지 않고 /dev/null로
    // 버린다(docs/editor-surface-tooling.md §6 — raw로 흘리지 않는다). 실패 여부는 종료 코드로 충분하다.
    // 쓰기는 정반대라(§5 — 가공해서 보여 준다) `spawnCapture`가 그 축을 인자로 받는다.
    const spawned = try spawnCapture(allocator, &argv, env_ptrs.items.ptr, .stdout_only, null);
    defer allocator.free(spawned.stderr_bytes); // 읽기 경로에서는 항상 빈 슬라이스다
    errdefer allocator.free(spawned.stdout_bytes);
    if (spawned.exit_code != 0) return error.GitFailed;
    // 상한에 걸렸는지는 길이로 판정한다 — 잘렸으면 목록 끝에 그 사실을 표시한다(조용히 일부만 보여 주지 않는다).
    return .{ .bytes = spawned.stdout_bytes, .truncated = spawned.stdout_bytes.len >= max_output_bytes };
}

/// `runArgvWithEnv` 의 Windows 갈래. **POSIX 갈래와 같은 계약을 지킨다** — 읽기라 stdout 만 받고,
/// 환경은 상속한 뒤 덮어쓰며, 사용자 환경의 `GIT_INDEX_FILE` 은 통째로 뺀다(남겨 두면 우리 명령이
/// 남의 index 에 쓴다).
///
/// 실행기는 `platform/windows/win32_process.zig` 다. `std.process.Child` 를 안 쓰는 것은 이 저장소의
/// 방침이고(0.16 에서 io 기반으로 개편 — `ssh_upload.zig`·`update_check.zig` 가 같은 이유로 피한다),
/// 그쪽은 `pty/windows.zig` 가 검증한 결(`CreateProcessW` + 익명 파이프)을 따른다.
fn runArgvWithEnvWindows(
    allocator: std.mem.Allocator,
    argv_slices: []const []const u8,
    index_file: ?[]const u8,
) !Output {
    // 캡처 러너는 **배럴을 통해** 온다. 상대 경로(`../windows/…`)로 가져오면 모듈 루트가
    // `platform/macos` 안인 아티팩트(`macos-chrome-lab-smoke` 등)에서 **모듈 밖**이 되어 macOS 빌드가
    // 깨진다 — 함수 안으로 옮겨도 소용없다. `@import` 는 파일 단위로 먼저 해석되기 때문이다(실측으로
    // 두 번 확인했다).
    const win32_process = maru.win32_process;
    // 덮어쓰기 목록은 POSIX 갈래와 **같은 단일 출처**에서 온다(`git_command.env_overrides`) — 두 벌로
    // 만들면 한쪽만 갱신되는 순간 Windows 에서만 `GIT_TERMINAL_PROMPT` 가 빠져 자격 증명 창이 뜬다.
    var overrides: std.ArrayList(win32_process.EnvVar) = .empty;
    defer overrides.deinit(allocator);
    for (git_command.env_overrides) |o| {
        overrides.append(allocator, .{ .name = o.name, .value = o.value }) catch return error.GitFailed;
    }
    if (index_file) |path| {
        overrides.append(allocator, .{ .name = "GIT_INDEX_FILE", .value = path }) catch return error.GitFailed;
    }

    var result = win32_process.capture(
        allocator,
        argv_slices,
        null, // git 은 `-C <repo>` 로 저장소를 받는다 — cwd 를 또 바꾸면 판정의 주인이 둘이 된다.
        .stdout_only,
        overrides.items,
        // 덮어쓰기에 이미 있으면 그쪽이 이기므로 중복이 아니다. 없을 때(스냅샷이 아닌 명령) 사용자
        // 환경의 값을 **빼는** 것이 이 자리의 일이다.
        &.{"GIT_INDEX_FILE"},
        max_output_bytes,
    ) catch return error.GitFailed;
    errdefer result.deinit(allocator);

    // POSIX 갈래와 같은 판정이다 — 0 이 아니면 실패고, 그때 stdout 은 버린다(부분 출력을 정상 결과로
    // 싣지 않는다).
    //
    // **여기서 손으로 놓지 않는다.** 위 `errdefer` 가 이미 그 일을 하는데 한 번 더 부르면 **이중
    // 해제**다 — `Output.deinit` 이 `self.* = undefined` 로 덮으므로 두 번째 `free` 는 0xAA 포인터를
    // 넘긴다. git 이 0 이 아닌 코드로 끝나는 것은 **흔한 일**이고(저장소가 아닌 폴더에서 열면 늘
    // 그렇다), 그때마다 프로세스가 죽었다 — 실측 2026-08-27: `Segmentation fault at address
    // 0xffffffffffffffff`, `repoStatusWorker` 스레드.
    if (result.exit_code != 0) return error.GitFailed;
    return .{ .bytes = result.bytes, .truncated = result.truncated };
}

/// **어느 스트림 하나만** 파이프로 받을지. 읽기와 쓰기가 정확히 반대다.
///
/// **파이프는 언제나 하나다.** 둘을 동시에 열고 한쪽을 끝까지 읽으면, 자식이 다른 쪽 파이프 버퍼(64 KiB)를
/// 채운 채 write에서 블록하고 우리는 첫 쪽 EOF를 기다려 **교착한다**. §5가 "hook 출력은 수천 줄이 될 수
/// 있다"고 못박았으므로 그 상황은 가정이 아니라 예정된 일이다. 다행히 필요한 것도 언제나 하나다 —
/// 읽기는 stdout만 쓰고(stderr에는 경로·사용자 정보가 섞여 §6이 금지한다), 쓰기는 stderr만 쓴다
/// (`add`는 조용하고 `rm --cached`의 stdout은 화면에 안 낸다). 그래서 나머지 하나는 /dev/null로 보낸다.
const Capture = enum {
    /// stdout을 받고 stderr를 버린다(읽기 — §6: raw로 흘리지 않는다).
    stdout_only,
    /// stderr를 받고 stdout을 버린다(쓰기 — §5: 실패 이유를 가공해서 보여 준다).
    stderr_only,
};

const Spawned = struct {
    /// `stderr_only`면 빈 슬라이스다.
    stdout_bytes: []u8,
    /// `stdout_only`면 빈 슬라이스다. 빈 슬라이스도 free는 안전하므로 호출자가 분기 없이 해제한다.
    stderr_bytes: []u8,
    /// 정상 종료가 아니면 -1.
    exit_code: c_int,
};

/// **fork + execve + 파이프 수집의 단일 출처.** 읽기·쓰기가 이 함수를 공유한다.
///
/// argv·env는 호출자가 이미 C 배열로 만들어 둔 것을 받는다(그 조립이 읽기/쓰기마다 다르기 때문이고,
/// 여기서 다시 만들면 어느 쪽 규칙을 쓸지 이 함수가 알아야 한다).
fn spawnCapture(
    allocator: std.mem.Allocator,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*]const ?[*:0]const u8,
    capture: Capture,
    /// **원격 커밋만** 이 자리를 쓴다(RS4b). `null` 이면 stdin 은 `/dev/null` 이고, 그것이 기본이다 —
    /// 아래 자식 갈래의 주석이 그 이유를 든다(저장소 훅이 `read` 로 멈추는 것을 막는다).
    ///
    /// 값이 있어도 그 보호는 유지된다: 다 보내면 **write 끝을 닫아** 자식이 EOF 를 본다. 실측으로
    /// 확인했다 — `commit -F -` 는 stdin 을 먼저 다 읽고, 이어 도는 `pre-commit` hook 은 **빈 stdin** 을
    /// 받는다(2026-09-01 harness sshd).
    stdin_bytes: ?[]const u8,
) !Spawned {
    var pipe_fds: [2]c_int = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.GitFailed;
    // 동시에 도는 다른 fork(셸 PTY spawn 등)로 write 끝이 새면 EOF가 안 와 read가 영원히 블록한다.
    _ = std.c.fcntl(pipe_fds[0], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(pipe_fds[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

    var in_fds: [2]c_int = .{ -1, -1 };
    if (stdin_bytes != null) {
        if (std.c.pipe(&in_fds) != 0) {
            _ = std.c.close(pipe_fds[0]);
            _ = std.c.close(pipe_fds[1]);
            return error.GitFailed;
        }
        _ = std.c.fcntl(in_fds[0], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        _ = std.c.fcntl(in_fds[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        // ⚠️ **자식이 먼저 죽으면 write 가 SIGPIPE 로 앱을 죽인다.** 이 저장소는 그것을 fd 단위로
        // 막는다(`runtime_manager.OutputWake` 와 같은 규율) — 전역 무시는 곳곳의 처분을 바꾼다.
        _ = std.c.fcntl(in_fds[1], std.c.F.SETNOSIGPIPE, @as(c_int, 1));
    }

    // 파이프로 받을 fd와 /dev/null로 보낼 fd.
    const piped_fd: c_int = switch (capture) {
        .stdout_only => 1,
        .stderr_only => 2,
    };
    const nulled_fd: c_int = switch (capture) {
        .stdout_only => 2,
        .stderr_only => 1,
    };

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        if (in_fds[0] >= 0) {
            _ = std.c.close(in_fds[0]);
            _ = std.c.close(in_fds[1]);
        }
        return error.GitFailed;
    }
    if (pid == 0) {
        // child: dup2/open/close/execve만(async-signal-safe).
        _ = std.c.dup2(pipe_fds[1], piped_fd);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, nulled_fd);
            // **stdin도 /dev/null이다.** 상속하면 stdin을 읽는 자식이 블록한다 —
            // `GIT_TERMINAL_PROMPT=0`은 git *자신의* 프롬프트만 막고, 저장소가 심어 둔 hook 스크립트가
            // `read`를 부르는 것은 못 막는다. §1이 "프롬프트가 뜨면 그 명령은 영영 안 끝난다"고 한 그
            // 상황이 그렇게 생긴다. /dev/null이면 즉시 EOF라 hook은 진행하거나 스스로 실패한다.
            // **입력을 주는 경우에만** 그 파이프가 stdin 이다(RS4b). 그때도 우리가 다 쓰면 닫으므로
            // 자식은 EOF 를 본다 — hook 이 `read` 로 멈추지 않는다는 보장이 유지된다.
            if (in_fds[0] < 0) _ = std.c.dup2(devnull, 0);
            _ = std.c.close(devnull);
        }
        if (in_fds[0] >= 0) {
            _ = std.c.dup2(in_fds[0], 0);
            _ = std.c.close(in_fds[0]);
            _ = std.c.close(in_fds[1]);
        }
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        _ = std.c.execve(argv[0].?, @ptrCast(argv), @ptrCast(envp));
        std.c._exit(127); // execve 실패
    }

    _ = std.c.close(pipe_fds[1]);
    if (in_fds[0] >= 0) _ = std.c.close(in_fds[0]); // 부모는 read 끝을 안 쓴다
    const collected = if (stdin_bytes) |payload|
        // **겹쳐 돌린다** — 순차로 하면 교착한다(`pumpStdinAndDrain` 주석).
        pumpStdinAndDrain(allocator, pipe_fds[0], in_fds[1], payload, max_output_bytes)
    else switch (capture) {
        .stdout_only => readAllFd(allocator, pipe_fds[0]),
        // 쓰기는 끝까지 비운다 — 상한에서 멈추면 사용자의 git을 도중에 죽인다.
        .stderr_only => readAllFdDraining(allocator, pipe_fds[0], max_output_bytes),
    };
    _ = std.c.close(pipe_fds[0]);
    const bytes = collected catch {
        _ = reapPid(pid);
        return error.GitFailed;
    };
    errdefer allocator.free(bytes);

    const exit_code = reapPid(pid);
    return switch (capture) {
        .stdout_only => .{ .stdout_bytes = bytes, .stderr_bytes = &.{}, .exit_code = exit_code },
        .stderr_only => .{ .stdout_bytes = &.{}, .stderr_bytes = bytes, .exit_code = exit_code },
    };
}

/// fd에서 EOF까지, 상한까지 읽는다(호출자 소유). 상한을 넘으면 거기서 멈추고 자식은 SIGPIPE/EPIPE로 끝난다 —
/// 화면에 못 들어갈 분량을 계속 받을 이유가 없다.
/// 상한까지만 **보관**하되 EOF까지 **계속 읽어 비운다**. 쓰기 전용이다.
///
/// 읽기(`readAllFd`)는 상한에서 멈춰 자식을 EPIPE로 끊는 것이 **의도다**(§6 — 화면에 못 들어갈 분량을 계속
/// 받을 이유가 없다). 쓰기에서 같은 일을 하면 **사용자의 git을 index 쓰는 도중에 죽인다** — 중간에 죽은
/// git은 `index.lock`을 남기고, 그다음부터 사용자의 터미널 git까지 막힌다. 우리가 시키지도 않은 상태다.
/// 그래서 쓰기는 메모리만 유계로 두고 파이프는 끝까지 비운다.
/// stdin 을 흘리면서 **동시에** 출력을 비운다(RS4b).
///
/// ⚠️ **순차로 하면 교착한다.** 「stdin 을 다 쓴 뒤 stderr 를 읽는다」로 두면, 자식이 우리 입력을 다
/// 소비하기 전에 stderr 파이프를 가득 채우는 순간 둘 다 멈춘다 — 우리는 write 에서, 자식은 write 에서.
/// 원격 커밋에서 그 상황은 흔하다: `pre-commit` hook 이 수천 줄을 쏟는 동안 우리는 아직 메시지를
/// 보내는 중이다(실측 2026-09-01: 512 KiB 메시지 + 2 만 줄 stderr 가 실제로 겹친다).
///
/// 그래서 `poll` 로 두 방향을 함께 본다. 다 쓰면 **write 끝을 닫아** 자식에게 EOF 를 준다 —
/// 닫지 않으면 `commit -F -` 가 입력이 끝나기를 영원히 기다린다.
fn pumpStdinAndDrain(
    allocator: std.mem.Allocator,
    out_fd: c_int,
    in_fd: c_int,
    payload: []const u8,
    keep_max: usize,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [16 * 1024]u8 = undefined;
    var sent: usize = 0;
    var write_fd = in_fd;
    // 다 보냈으면 바로 닫는다 — 빈 메시지도 EOF 가 필요하다.
    if (payload.len == 0) {
        _ = std.c.close(write_fd);
        write_fd = -1;
    }
    while (true) {
        var fds: [2]std.c.pollfd = .{
            .{ .fd = out_fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = write_fd, .events = std.c.POLL.OUT, .revents = 0 },
        };
        const n_fds: std.c.nfds_t = if (write_fd >= 0) 2 else 1;
        const ready = std.c.poll(&fds, n_fds, -1);
        if (ready < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            if (write_fd >= 0) _ = std.c.close(write_fd);
            return error.ReadFailed;
        }
        if (write_fd >= 0 and fds[1].revents != 0) {
            const rest = payload[sent..];
            const w = std.c.write(write_fd, rest.ptr, rest.len);
            if (w > 0) sent += @intCast(w);
            // **EPIPE 는 실패가 아니다** — 자식이 먼저 끝난 것이고, 그 종료 코드가 사실을 말한다.
            // (write 끝에 `SETNOSIGPIPE` 를 걸어 두어 신호가 아니라 오류로 온다.)
            if (w <= 0 or sent == payload.len) {
                _ = std.c.close(write_fd);
                write_fd = -1;
            }
        }
        if (fds[0].revents != 0) {
            const r = std.posix.read(out_fd, &tmp) catch {
                if (write_fd >= 0) _ = std.c.close(write_fd);
                return error.ReadFailed;
            };
            if (r == 0) break; // EOF — 자식이 끝났다
            if (buf.items.len < keep_max) {
                const room = keep_max - buf.items.len;
                try buf.appendSlice(allocator, tmp[0..@min(r, room)]);
            }
            // 상한을 넘어도 **읽기는 계속한다** — 멈추면 자식이 EPIPE 로 죽는다.
        }
    }
    if (write_fd >= 0) _ = std.c.close(write_fd);
    return buf.toOwnedSlice(allocator);
}

fn readAllFdDraining(allocator: std.mem.Allocator, fd: c_int, keep_max: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch return error.ReadFailed;
        if (n == 0) break; // EOF
        if (buf.items.len < keep_max) {
            const room = keep_max - buf.items.len;
            try buf.appendSlice(allocator, tmp[0..@min(n, room)]);
        }
        // 상한을 넘은 뒤에도 **읽기는 계속한다** — 여기서 멈추면 자식이 EPIPE로 죽는다.
    }
    return buf.toOwnedSlice(allocator);
}

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

/// 비동기 쓰기 하나의 결과(호출자가 `takeWriteResult`로 가져간다).
/// 원격으로 보낼 커밋 메시지의 상한. 넘으면 **자르지 않고 거절한다** — 잘린 커밋 메시지는
/// 「덜 적힌 것」이 아니라 **다른 메시지**이고, 그것은 되돌릴 수 없는 자리에 박힌다.
/// (로컬은 파일을 그대로 넘기므로 이 상한이 없다 — 원격만의 조항이다.)
pub const max_commit_message_bytes: usize = 1 << 20;

pub const WriteResult = struct {
    request_id: u64,
    /// 프로세스를 띄우지도 못한 경우(조립 거부·spawn 실패)는 `false`이고 `stderr`가 비어 있다.
    spawned: bool,
    exit_code: c_int,
    /// git이 낸 stderr **원본**. 화면에 내기 전에 호출자가 redact·절단한다(§5).
    stderr: []u8,
    stderr_truncated: bool,
    /// 이 쓰기가 **원격으로 갔는가**(RS4a). 실패를 어떻게 말할지가 갈린다 — `ssh` 는 **자기 실패에만**
    /// 255 를 쓰므로(실측 2026-09-01: 소켓이 죽으면 `Host key verification failed.` + 255), 원격 쓰기의
    /// 255 는 「git 이 거부했다」가 아니라 **「git 까지 못 갔다」**다. 그 둘을 안 가르면 ssh 가 한 말이
    /// 저장소 이야기로 화면에 뜨고, 사용자는 자기 저장소를 의심한다.
    remote: bool = false,

    /// 명령이 git 에 닿지도 못했는가. **원격에서만 참일 수 있다** — 로컬 git 이 255 를 내는 일은 없고,
    /// 있다 해도 그것은 git 이 한 말이다.
    pub fn transportFailed(self: WriteResult) bool {
        return self.remote and self.spawned and self.exit_code == 255;
    }

    pub fn ok(self: WriteResult) bool {
        return self.spawned and self.exit_code == 0;
    }

    pub fn deinit(self: *WriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr);
        self.stderr = &.{};
    }
};

/// 결과가 들어갈 자리. **fetch를 쓰기와 가르는 유일한 축이다** — 실행 경로(argv·env 조립, spawn, stderr
/// 수집)는 같고, 어느 슬롯에 결과를 놓고 어느 in-flight를 푸는지만 다르다.
const WriteSlot = enum { index, network };

const WriteJob = struct {
    state: *State,
    slot: WriteSlot = .index,
    git_exe: []u8,
    repo: []u8,
    /// 경로 문자열과 그 슬라이스 배열 둘 다 job이 소유한다 — 호출자의 프레임 arena는 이 worker보다 먼저 죽는다.
    paths: [][]u8,
    message_file: ?[]u8,
    kind: git_write_command.Kind,
    request_id: u64,
    /// 원격(SSH) 실행 대상(owned, RS4a). **둘 다 비어 있으면 로컬이다** — 읽기 `Job` 과 같은 모양이라
    /// 두 축이 같은 규율을 따른다.
    remote_dest: []u8 = &.{},
    remote_ctl: []u8 = &.{},

    /// 이 job 이 원격이면 그 대상. 하나라도 비면 **로컬로 본다** — 반쪽짜리 대상으로 명령을 만드느니
    /// 로컬이 낫다는 뜻이 아니라, 호출자가 쌍으로 넣으므로 그 상태가 애초에 안 생긴다.
    fn remoteTarget(self: *const WriteJob) ?git_write_command.Remote {
        if (self.remote_dest.len == 0 or self.remote_ctl.len == 0) return null;
        return .{ .dest = self.remote_dest, .control_path = self.remote_ctl };
    }

    fn deinit(self: *WriteJob) void {
        const allocator = self.state.allocator;
        allocator.free(self.git_exe);
        allocator.free(self.repo);
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
        if (self.message_file) |m| allocator.free(m);
        if (self.remote_dest.len != 0) allocator.free(self.remote_dest);
        if (self.remote_ctl.len != 0) allocator.free(self.remote_ctl);
        allocator.destroy(self);
    }
};

fn writeWorker(job: *WriteJob) void {
    const state = job.state;
    const allocator = state.allocator;

    // `runWriteSync`는 `[]const []const u8`을 받는다. job이 든 가변 슬라이스를 그대로 넘길 수 없어 얇게 뷰를 만든다.
    var view_buf: [git_write_command.max_batch_paths][]const u8 = undefined;
    const n = @min(job.paths.len, view_buf.len);
    for (job.paths[0..n], view_buf[0..n]) |src, *dst| dst.* = src;

    var result: WriteResult = .{
        .request_id = job.request_id,
        .spawned = false,
        .exit_code = -1,
        .stderr = &.{},
        .stderr_truncated = false,
    };
    if (runWriteSync(allocator, job.kind, job.git_exe, job.repo, view_buf[0..n], job.message_file, job.remoteTarget())) |out| {
        result = .{
            .request_id = job.request_id,
            .spawned = true,
            .exit_code = out.exit_code,
            .stderr = out.stderr_bytes,
            .stderr_truncated = out.stderr_truncated,
            .remote = job.remoteTarget() != null,
        };
    } else |_| {
        // 조립 거부·spawn 실패. **성공으로 추정하지 않는다**(§5) — 호출자가 목록을 다시 읽어 사실과 맞춘다.
    }

    state.mutex.lockUncancelable(state.io);
    switch (job.slot) {
        .index => {
            if (state.write_result) |*old| old.deinit(allocator); // 못 가져간 결과는 버린다(최신이 사실이다)
            state.write_result = result;
            state.write_inflight -= 1;
        },
        .network => {
            if (state.fetch_result) |*old| old.deinit(allocator);
            state.fetch_result = result;
            state.fetch_inflight -= 1;
        },
    }
    state.mutex.unlock(state.io);

    job.deinit();
    state.release();
}

/// 쓰기 명령 하나의 결과. 읽기의 `Output`과 달리 **종료 코드와 stderr를 싣는다** — §5가 "성공을 추정하지
/// 않는다"와 "실패 이유를 가공해서 보여 준다"를 요구하기 때문이다.
pub const WriteOutput = struct {
    exit_code: c_int,
    /// git이 낸 stderr **원본**. 화면에 내기 전에 호출자가 redact·길이 절단을 한다(§5) — 이 층은 사실만 옮긴다.
    stderr_bytes: []u8,
    /// stderr가 상한에 걸려 잘렸나. hook 출력은 수천 줄이 될 수 있다.
    stderr_truncated: bool,

    pub fn ok(self: WriteOutput) bool {
        return self.exit_code == 0;
    }

    pub fn deinit(self: WriteOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr_bytes);
    }
};

/// 쓰기 명령 하나를 **동기로** 실행한다.
///
/// 비동기 제출 표면을 따로 두지 않는 이유: 쓰기는 §6대로 **in-flight 하나**로 직렬화되고, 그 직렬화를
/// 소유하는 쪽은 화면 상태를 함께 든 호출자(app_session)다. 여기에 큐를 하나 더 만들면 직렬화 규칙이 두
/// 곳으로 갈린다. 이 함수는 worker 스레드에서 불린다.
///
/// **argv·env는 `git_write_command`가 소유한다** — 읽기와 갈린 축(index 잠금·hook·stderr)이 그 모듈의
/// 테스트로 전수 고정돼 있고, 여기서 다시 정하면 그 고정이 무의미해진다.
pub fn runWriteSync(
    allocator: std.mem.Allocator,
    kind: git_write_command.Kind,
    git_exe: []const u8,
    repo: []const u8,
    paths: []const []const u8,
    message_file: ?[]const u8,
    /// 원격이면 그 대상(RS4a). 로컬 argv 를 만든 뒤 **한 자리에서** 감싼다 — 감싸는 자리가 둘이면
    /// 한쪽만 고쳐지고, 그 어긋남은 「로컬에서는 막힌 것이 원격에서 열린다」로 나타난다.
    remote: ?git_write_command.Remote,
) !WriteOutput {
    // **조립 오류를 `GitFailed`로 뭉개지 않는다.** 경로 거부(절대경로·`..`)는 *우리가* 손대지 않기로 한
    // 일이고 git이 실패한 것이 아니다 — §5의 "실패는 사실대로"가 그 둘을 구별하라고 한다. 뭉개면 화면에
    // "git 실패"라고 뜨고 사용자는 저장소를 의심한다.
    var argv_slices_buf: [git_write_command.fixed_argv_max + git_write_command.max_batch_paths][]const u8 = undefined;
    // 배치 나누기는 **호출자 몫이다**(§2 — 중간에 실패할 수 있고, 그때 목록을 다시 읽는 판단은 화면 상태를
    // 든 쪽이 한다). 여기서 조용히 자르면 일부만 스테이지되고 호출자는 전부 됐다고 믿는다.
    if (paths.len > git_write_command.max_batch_paths) return error.TooManyPaths;
    // ⚠️ **원격 커밋은 메시지를 stdin 으로 보낸다**(RS4b · 계약 §6.2). 로컬은 `-F <메시지 파일>` 인데
    // **그 파일은 로컬에 있다** — 원격에서 그 경로는 없거나 **남의 파일**이다. 그래서 원격에서는 파일명
    // 자리에 `-` 를 넣고(그러면 `commit -F -`) 바이트를 파이프로 흘린다.
    var message_buf: ?[]u8 = null;
    defer if (message_buf) |m| allocator.free(m);
    const remote_commit = remote != null and kind == .commit;
    if (remote_commit) {
        const path = message_file orelse return error.GitFailed;
        message_buf = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            allocator,
            .limited(max_commit_message_bytes),
        ) catch return error.CommitMessageUnreadable;
    }
    const effective_message_file: ?[]const u8 = if (remote_commit) "-" else message_file;
    const local_argv = try git_write_command.build(kind, git_exe, repo, paths, effective_message_file, &argv_slices_buf);

    // **원격이면 여기서 한 번 감싼다.** 아래 실행 갈래 둘은 그대로 두고 argv 만 바뀐다 — 감싸기를
    // 실행 갈래 안에 두면 Windows/POSIX 두 곳에 같은 코드가 생긴다.
    var remote_argv_buf: [git_write_command.remote_argv_len][]const u8 = undefined;
    var remote_cmd_buf: [git_write_command.max_remote_command_bytes]u8 = undefined;
    const argv_slices = if (remote) |target|
        // **실패가 자기 이름을 말한다.** `GitFailed` 로 뭉개면 화면에 「git 실패」가 뜨고 사용자는
        // 저장소를 의심한다 — 실제로는 우리가 명령을 **만들지 못한** 것이다(§5: 실패는 사실대로).
        git_write_command.buildRemote(local_argv, target, &remote_argv_buf, &remote_cmd_buf) orelse
            return error.RemoteCommandTooLong
    else blk: {
        // ⚠️ **로컬 실행은 절대경로만 받는다**(RS4a 7회차). 원격 갈래는 `argv[0]` 을 버리고 이름으로
        // 부르므로 호출자가 `"git"` 을 넘겨도 되는데, 그 값이 **로컬 갈래로 새면** `execve` 가 상대경로를
        // cwd 기준으로 풀어 **저장소 안의 `git` 이라는 파일**을 실행할 수 있다. 원격 라우팅이 어느
        // 이유로든 떨어져도 그 결과가 임의 실행이 되면 안 된다 — 여기서 닫는다.
        if (!std.fs.path.isAbsolute(git_exe)) return error.GitExeNotAbsolute;
        break :blk local_argv;
    };

    // **Windows 는 캡처 러너로 간다.** 읽기 갈래(`runArgvWithEnv`)와 같은 이유이고, 여기서 갈리는 것은
    // **어느 스트림을 받느냐**다 — 쓰기는 stderr 를 받는다(git 이 왜 거부했는지 못 보여 주면 쓸 수 없는
    // 기능이다). argv 조립은 위에서 이미 끝났으므로 두 갈래가 **같은 argv** 를 쓴다.
    // **`if/else` 여야 한다** — `if (...) return X;` 로 두면 아래 POSIX 본문이 Windows 에서도
    // 분석돼 `environ` 링크가 깨진다. 그래서 이 갈래는 주석만 있고 **한 번도 링크된 적이 없었다**
    // (W8.4⒞2 가 처음 부르자 `undefined symbol: environ` 으로 드러났다).
    if (comptime builtin.os.tag == .windows) {
        // 원격 쓰기는 macOS 축이다(control socket · `maru ssh`). Windows 갈래는 로컬만 온다.
        std.debug.assert(remote == null);
        return runWriteSyncWindows(allocator, argv_slices);
    } else {
        return runWriteSyncPosix(allocator, kind, argv_slices, message_buf);
    }
}

/// `runWriteSync` 의 POSIX 갈래. **따로 함수로 둔 이유는 위 주석**이다 — 한 함수에 두면 Windows 에서도
/// 본문이 분석된다.
fn runWriteSyncPosix(
    allocator: std.mem.Allocator,
    kind: git_write_command.Kind,
    argv_slices: []const []const u8,
    /// 원격 커밋의 메시지(RS4b). `null` 이면 stdin 은 `/dev/null` 이고 그것이 기본이다.
    stdin_bytes: ?[]const u8,
) !WriteOutput {
    var argv_store: std.ArrayList([:0]u8) = .empty;
    defer {
        for (argv_store.items) |a| allocator.free(a);
        argv_store.deinit(allocator);
    }
    var argv_ptrs: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv_ptrs.deinit(allocator);
    for (argv_slices) |a| {
        const copy = allocator.dupeZ(u8, a) catch return error.GitFailed;
        argv_store.append(allocator, copy) catch return error.GitFailed;
        argv_ptrs.append(allocator, copy.ptr) catch return error.GitFailed;
    }
    argv_ptrs.append(allocator, null) catch return error.GitFailed;

    // 환경은 **상속한 뒤 덮어쓴다**(읽기와 같은 규율). 다른 점은 덮어쓰는 목록뿐이고, 그 목록에
    // `GIT_OPTIONAL_LOCKS`가 없다는 것이 쓰기의 계약이다 — 쓰기는 index를 잠가야 한다(§1).
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
        for (git_write_command.envOverrides(kind)) |o| {
            if (std.mem.eql(u8, pair[0..eq], o.name)) continue :outer;
        }
        // 사용자 환경의 `GIT_INDEX_FILE`은 항상 버린다 — 남겨 두면 우리 쓰기가 **남의 index**에 간다.
        // 읽기보다 이쪽이 더 위험하다(읽기는 잘못된 답을 주고, 쓰기는 잘못된 곳을 바꾼다).
        if (std.mem.eql(u8, pair[0..eq], "GIT_INDEX_FILE")) continue :outer;
        const copy = allocator.dupeZ(u8, pair) catch return error.GitFailed;
        env_store.append(allocator, copy) catch return error.GitFailed;
        env_ptrs.append(allocator, copy.ptr) catch return error.GitFailed;
    }
    // **환경 목록은 명령 종류가 고른다**(fetch만 갈린다 — §4). 여기서 배열을 직접 고르면 "fetch인데 읽기
    // 환경으로 돌았다"가 조용히 생긴다.
    for (git_write_command.envOverrides(kind)) |o| {
        const joined = std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ o.name, o.value }, 0) catch return error.GitFailed;
        env_store.append(allocator, joined) catch return error.GitFailed;
        env_ptrs.append(allocator, joined.ptr) catch return error.GitFailed;
    }
    env_ptrs.append(allocator, null) catch return error.GitFailed;

    const spawned = try spawnCapture(allocator, @ptrCast(argv_ptrs.items.ptr), env_ptrs.items.ptr, .stderr_only, stdin_bytes);
    // 쓰기의 stdout은 애초에 /dev/null로 갔다(`add`는 조용하고 `rm --cached`의 목록은 화면에 안 낸다).
    allocator.free(spawned.stdout_bytes); // 빈 슬라이스 — 분기 없이 해제한다
    return .{
        .exit_code = spawned.exit_code,
        .stderr_bytes = spawned.stderr_bytes,
        .stderr_truncated = spawned.stderr_bytes.len >= max_output_bytes,
    };
}

/// `runWriteSync` 의 Windows 갈래. **읽기 갈래와 정확히 반대다** — stderr 를 받고 stdout 을 버린다
/// (`add` 는 조용하고 `rm --cached` 의 목록은 화면에 안 낸다). git 이 왜 거부했는지 못 보여 주면 쓸 수
/// 없는 기능이라 stderr 가 이 경로의 산출물이다(docs/editor-surface-dock-write.md 의 스트림 표).
///
/// **읽기와 달리 실패를 오류로 올리지 않는다.** 0 이 아닌 종료 코드는 "git 이 거부했다" 는 **사실**이고,
/// 화면이 그것을 보여 줘야 한다. 여기서 `error.GitFailed` 로 바꾸면 그 이유가 사라진다.
fn runWriteSyncWindows(
    allocator: std.mem.Allocator,
    argv_slices: []const []const u8,
) !WriteOutput {
    // 읽기 갈래와 같이 **배럴을 통해** 온다 — 상대 경로로 가져오면 모듈 루트가 `platform/macos` 안인
    // 아티팩트에서 모듈 밖이 되어 macOS 빌드가 깨진다(§2m.9 에 그 실측이 있다).
    const win32_process = maru.win32_process;
    var overrides: std.ArrayList(win32_process.EnvVar) = .empty;
    defer overrides.deinit(allocator);
    // 읽기 갈래와 **같은 단일 출처**다(`git_command.env_overrides`) — 두 벌로 만들면 한쪽만 갱신되는
    // 순간 쓰기에서만 `GIT_TERMINAL_PROMPT` 가 빠져 자격 증명 창이 뜨고 커밋이 영영 안 끝난다.
    for (git_command.env_overrides) |o| {
        overrides.append(allocator, .{ .name = o.name, .value = o.value }) catch return error.GitFailed;
    }

    const result = win32_process.capture(
        allocator,
        argv_slices,
        null, // git 은 `-C <repo>` 로 저장소를 받는다.
        .stderr_only,
        overrides.items,
        &.{"GIT_INDEX_FILE"},
        max_output_bytes,
    ) catch return error.GitFailed;

    return .{
        // POSIX 갈래는 정상 종료가 아니면 -1 을 싣는다. Windows 는 `GetExitCodeProcess` 가 성공하면
        // 언제나 값이 있으므로 그대로 옮긴다 — 다만 `c_int` 로 좁히면서 아주 큰 코드(`0xC0000005` 같은
        // 예외 코드)가 음수가 될 수 있는데, 판정이 `== 0` 이라 결과가 갈리지 않는다.
        .exit_code = @bitCast(result.exit_code),
        .stderr_bytes = result.bytes,
        .stderr_truncated = result.truncated,
    };
}

const testing = std.testing;

test "status 한 벌이 띄우는 프로세스 수 — 소비자 없는 읽기가 붙으면 여기서 걸린다" {
    // **이 판정자가 없어서 결함이 13일 동안 숨었다.** 「브랜치에 COMMIT 됨」섹션이 사라진 뒤
    // `merge-base`·브랜치 범위 `--name-status`·`--numstat` 셋이 매 읽기마다 돌면서 출력을 버렸는데,
    // 명령의 *형태*를 보는 테스트는 있었어도 *몇 개인지*를 보는 것은 없었다(docs/plans/scm-dock.md §2.5).
    //
    // **수를 늘리는 것 자체가 금지는 아니다.** 늘려야 할 이유가 있으면 이 수와 함께 그 이유를 적으면
    // 된다 — 이 테스트가 막는 것은 **아무도 모르게** 늘거나, 화면이 사라졌는데 읽기만 남는 일이다.
    try testing.expectEqual(@as(usize, 5), optional_reads.len);
    try testing.expectEqual(@as(usize, 3), required_reads.len);

    // 실린 kind 가 전부 **결과를 담을 자리**를 갖는지도 함께 본다. 이것은 **다른 종류**의 사고를 막는다 —
    // 자리 없이 실행만 하는 읽기. 이 건은 그 반대였다(자리는 있고 읽는 사람이 없었다). 그쪽은 위의
    // 개수 판정과 리뷰가 잡고, 이 줄은 이 목록이 `Result` 와 어긋나는 것을 잡는다.
    inline for (optional_reads ++ required_reads) |pair| {
        try testing.expect(@hasField(Result, pair[1]));
    }
}

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
    try testing.expect(backend.submit(exe, repo, "", 7, null)); // 로컬(RS2 — 원격이면 `Remote` 를 넘긴다)

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
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", "", .staged, 1, null, ""));
    const staged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var staged_result = staged;
    defer staged_result.deinit(worker_allocator);
    try testing.expect(staged_result.ok);
    try testing.expect(staged_result.original.len > 0); // HEAD:build.zig
    try testing.expect(staged_result.modified.len > 0); // :build.zig(index)

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", "", .unstaged, 2, null, ""));
    const unstaged = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var unstaged_result = unstaged;
    defer unstaged_result.deinit(worker_allocator);
    try testing.expect(unstaged_result.ok);
    try testing.expect(unstaged_result.modified.len > 0); // 작업트리 파일(git을 안 거친다)

    // untracked는 왼쪽이 **없는 것이 정상**이다 — 실패로 접지 않는다.
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", "", .untracked, 3, null, ""));
    const untracked = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var untracked_result = untracked;
    defer untracked_result.deinit(worker_allocator);
    try testing.expect(untracked_result.ok);
    try testing.expectEqual(@as(usize, 0), untracked_result.original.len);
    try testing.expect(untracked_result.modified.len > 0);

    // 없는 경로는 실패를 **결과로** 싣는다(in-flight가 풀려야 화면이 "여는 중"에 안 갇힌다).
    try testing.expect(backend.submitDiff(exe, repo, "no/such/file.txt", "", "", "", .staged, 4, null, ""));
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

test "diff 왼쪽 rev 는 hex 만 받는다(end-to-end — 인자 주입 차단)" {
    // 앞선 판은 「브랜치 기준 diff」(`merge-base ↔ HEAD`)를 돌렸다. 그 기준은 2026-08-27 에 걷혔고
    // (그리는 섹션이 2026-08-14 에 사라졌다) 이 테스트가 증언하던 것 중 **살아남은 규율은 이것**이다:
    // 왼쪽 rev 가 hex 가 아니면 spec 자체가 안 만들어져 그쪽이 빈 채로 온다. `git_command` 단위
    // 테스트가 `commitBlobSpec` 을 이미 고정하지만, **`submitDiff` 경로가 그 판정을 실제로 지나는지**는
    // 여기서만 보인다 — 그 사이에 인자를 그대로 싣는 길이 생기면 단위 테스트는 여전히 초록이다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&repo_buf, repo_buf.len) orelse return error.NoCwd;
    const repo = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    // **대조군이 먼저다.** hex rev 로는 왼쪽이 실제로 차야, 아래의 0 이 「거부됐다」는 뜻이 된다 —
    // 대조군이 없으면 경로가 통째로 죽어도(예: spec 을 아무도 안 만들어도) 이 테스트는 초록이다.
    var head_buf: [64]u8 = undefined;
    const head_oid = headOid(exe, repo, &head_buf) orelse return error.SkipZigTest;
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", head_oid, "", .commit, 1, null, ""));
    var good = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer good.deinit(worker_allocator);
    try testing.expect(good.modified.len > 0); // `<oid>:build.zig`

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "origin/HEAD", "", .commit, 2, null, ""));
    var bad = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer bad.deinit(worker_allocator);
    try testing.expectEqual(@as(usize, 0), bad.original.len);
    try testing.expectEqual(@as(usize, 0), bad.modified.len);
}

/// 이 저장소의 HEAD 해시(hex). 위 테스트의 대조군이 **진짜 rev** 여야 하므로 실측으로 얻는다.
fn headOid(git_exe: []const u8, repo: []const u8, buf: []u8) ?[]const u8 {
    const out = runWithArg(worker_allocator, .log, git_exe, repo, "1") catch return null;
    defer worker_allocator.free(out.bytes);
    var it = maru.session.git_log.iterate(out.bytes);
    const first = it.next() orelse return null;
    if (first.oid.len == 0 or first.oid.len > buf.len) return null;
    @memcpy(buf[0..first.oid.len], first.oid);
    return buf[0..first.oid.len];
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
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", "", .conflict, 1, null, ""));
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
}

// ── 쓰기 end-to-end (실제 임시 저장소) ─────────────────────────────────────────
//
// 계획서 P2가 요구한 검증이다: stage→unstage 왕복, `MM`(부분 스테이지), 경로에 공백·비ASCII·`-` 시작.
// argv 조립은 `session.git_write_command`가 헤드리스로 전수 고정하므로, **여기서 보는 것은 그 argv가 실제
// git에 통하는가**뿐이다(플래그를 맞게 조립해도 git 버전이 안 받으면 소용없다).

/// fixture가 파일을 만들 때 쓰는 Io. 실행 경로(`spawnCapture`)는 io를 쓰지 않으므로 여기서만 필요하다.
const fixture_io = std.Io.Threaded.global_single_threaded.io();

const WriteFixture = struct {
    dir: std.testing.TmpDir,
    root: []u8,
    /// **힙에 든다.** 이 구조체는 값으로 반환되므로 자기 안의 버퍼를 가리키면 반환하는 순간 댕글링이 된다 —
    /// 실제로 그렇게 두었더니 argv[0]이 쓰레기가 되어 어떤 호출은 되고 어떤 호출은 exit 127로 죽는
    /// 비결정적 실패가 났다.
    exe: []u8,

    fn init(allocator: std.mem.Allocator) !?WriteFixture {
        var self: WriteFixture = .{ .dir = std.testing.tmpDir(.{}), .root = &.{}, .exe = &.{} };
        errdefer self.dir.cleanup();
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const located = locate(&exe_buf) orelse {
            self.dir.cleanup();
            return null; // git 없는 기기에서는 판정할 것이 없다
        };
        self.exe = try allocator.dupe(u8, located);
        errdefer allocator.free(self.exe);
        // 저장소는 **절대경로**로 넘긴다 — 상대경로를 실행 경로에 쓰지 않는 계약(§6)이 쓰기에도 그대로 간다.
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try self.dir.dir.realPath(fixture_io, &root_buf);
        self.root = try allocator.dupe(u8, root_buf[0..root_len]);
        errdefer allocator.free(self.root);
        // `init` 자체는 우리 쓰기 경로가 아니므로 그냥 돌린다. 사용자 신원이 없는 CI를 위해 로컬 config를 박는다.
        try self.plainGit(allocator, &.{ "init", "-q" });
        try self.plainGit(allocator, &.{ "config", "user.email", "t@example.com" });
        try self.plainGit(allocator, &.{ "config", "user.name", "t" });
        return self;
    }

    fn deinit(self: *WriteFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.exe);
        self.dir.cleanup();
    }

    /// 준비용 git(우리 쓰기 계약 밖). 인자를 그대로 넘긴다.
    fn plainGit(self: *WriteFixture, allocator: std.mem.Allocator, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, self.exe);
        try argv.append(allocator, "-C");
        try argv.append(allocator, self.root);
        for (args) |a| try argv.append(allocator, a);

        var store: std.ArrayList([:0]u8) = .empty;
        defer {
            for (store.items) |a| allocator.free(a);
            store.deinit(allocator);
        }
        var ptrs: std.ArrayList(?[*:0]const u8) = .empty;
        defer ptrs.deinit(allocator);
        for (argv.items) |a| {
            const c = try allocator.dupeZ(u8, a);
            try store.append(allocator, c);
            try ptrs.append(allocator, c.ptr);
        }
        try ptrs.append(allocator, null);
        const spawned = try spawnCapture(allocator, @ptrCast(ptrs.items.ptr), @ptrCast(std.c.environ), .stderr_only, null);
        allocator.free(spawned.stdout_bytes);
        allocator.free(spawned.stderr_bytes);
        if (spawned.exit_code != 0) return error.PrepareFailed;
    }

    /// hook 스크립트를 실행 가능하게 만든다(안 하면 git이 조용히 건너뛴다).
    fn chmodExec(self: *WriteFixture, sub_path: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ self.root, sub_path });
        if (std.c.chmod(full, 0o755) != 0) return error.ChmodFailed;
    }

    fn write(self: *WriteFixture, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |sub| {
            self.dir.dir.createDir(fixture_io, sub, .default_dir) catch {};
        }
        try self.dir.dir.writeFile(fixture_io, .{ .sub_path = path, .data = bytes });
    }

    /// 읽기 경로의 `git status --porcelain=v2` 출력. 스테이지 여부를 사실로 확인하는 유일한 출처다.
    /// **v1이 아니다** — 행이 `1 <XY> ...`이고 추적되지 않은 파일은 `? <경로>`다.
    fn status(self: *WriteFixture, allocator: std.mem.Allocator) ![]u8 {
        const out = try runWithArg(allocator, .status, self.exe, self.root, null);
        return out.bytes;
    }

    fn run(self: *WriteFixture, allocator: std.mem.Allocator, kind: git_write_command.Kind, paths: []const []const u8) !WriteOutput {
        return runWriteSync(allocator, kind, self.exe, self.root, paths, null, null);
    }

    /// 커밋 — 메시지 파일을 함께 넘긴다(§2: `-m`이 아니다).
    fn commit(self: *WriteFixture, allocator: std.mem.Allocator, message_file: []const u8) !WriteOutput {
        return runWriteSync(allocator, .commit, self.exe, self.root, &.{}, message_file, null);
    }

    /// 준비용 git의 **출력**을 받는다(로그 확인용). `plainGit`과 같은 조립을 쓰되 stdout을 돌려준다.
    fn capture(self: *WriteFixture, allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, self.exe);
        try argv.append(allocator, "-C");
        try argv.append(allocator, self.root);
        for (args) |a| try argv.append(allocator, a);
        var store: std.ArrayList([:0]u8) = .empty;
        defer {
            for (store.items) |a| allocator.free(a);
            store.deinit(allocator);
        }
        var ptrs: std.ArrayList(?[*:0]const u8) = .empty;
        defer ptrs.deinit(allocator);
        for (argv.items) |a| {
            const c = try allocator.dupeZ(u8, a);
            try store.append(allocator, c);
            try ptrs.append(allocator, c.ptr);
        }
        try ptrs.append(allocator, null);
        const spawned = try spawnCapture(allocator, @ptrCast(ptrs.items.ptr), @ptrCast(std.c.environ), .stdout_only, null);
        allocator.free(spawned.stderr_bytes);
        return spawned.stdout_bytes;
    }
};

test "쓰기 end-to-end: 커밋이 실제로 만들어지고 메시지가 파일에서 온다" {
    // §2가 `-m`을 금지한 근거를 **실행으로** 고정한다: 여러 줄·따옴표·비ASCII가 든 메시지가 argv를
    // 거치지 않고 그대로 커밋에 들어간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.zig", "hello\n");
    var staged = try fx.run(allocator, .stage, &.{"a.zig"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());

    // 메시지 파일은 **저장소 밖**이다(제품도 캐시 디렉터리에 둔다) — 안에 두면 그 파일이 목록에 뜬다.
    var msg_dir = std.testing.tmpDir(.{});
    defer msg_dir.cleanup();
    var msg_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msg_root_len = try msg_dir.dir.realPath(fixture_io, &msg_root_buf);
    var msg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msg_path = try std.fmt.bufPrint(&msg_path_buf, "{s}/msg", .{msg_root_buf[0..msg_root_len]});
    const message = "fix: 따옴표 \"와\" 여러 줄\n\n본문 — 비ASCII·`백틱`·$변수\n";
    try msg_dir.dir.writeFile(fixture_io, .{ .sub_path = "msg", .data = message });

    var committed = try fx.commit(allocator, msg_path);
    defer committed.deinit(allocator);
    try testing.expect(committed.ok());

    // 커밋 메시지가 **원문 그대로**인가.
    const log = try fx.capture(allocator, &.{ "log", "-1", "--pretty=%B" });
    defer allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "fix: 따옴표 \"와\" 여러 줄") != null);
    try testing.expect(std.mem.indexOf(u8, log, "본문 — 비ASCII·`백틱`·$변수") != null);

    // 그리고 작업트리가 깨끗해졌다(스테이지된 것이 커밋으로 넘어갔다).
    const st = try fx.status(allocator);
    defer allocator.free(st);
    try testing.expect(std.mem.indexOf(u8, st, "a.zig") == null);
}

test "쓰기 end-to-end: pre-commit hook이 거부하면 커밋이 안 만들어지고 그 이유가 stderr로 온다" {
    // §3이 hook을 막지 않기로 한 근거다 — 사용자가 설치한 검사는 우리 커밋에도 걸려야 하고,
    // 거부 사유가 안 보이면 무엇을 고쳐야 할지 모른다(§5).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.zig", "hello\n");
    var staged = try fx.run(allocator, .stage, &.{"a.zig"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());

    try fx.write(".git/hooks/pre-commit", "#!/bin/sh\necho '린트 실패: a.zig' 1>&2\nexit 1\n");
    try fx.chmodExec(".git/hooks/pre-commit"); // 안 하면 git이 hook을 조용히 건너뛴다

    var msg_dir = std.testing.tmpDir(.{});
    defer msg_dir.cleanup();
    var msg_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msg_root_len = try msg_dir.dir.realPath(fixture_io, &msg_root_buf);
    var msg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msg_path = try std.fmt.bufPrint(&msg_path_buf, "{s}/msg", .{msg_root_buf[0..msg_root_len]});
    try msg_dir.dir.writeFile(fixture_io, .{ .sub_path = "msg", .data = "wip\n" });

    var rejected = try fx.commit(allocator, msg_path);
    defer rejected.deinit(allocator);
    try testing.expect(!rejected.ok()); // hook이 막았다
    try testing.expect(std.mem.indexOf(u8, rejected.stderr_bytes, "린트 실패") != null); // 이유가 온다

    // 커밋이 **안 만들어졌다** — 실패를 성공으로 추정하지 않는 근거다(§5).
    const log = try fx.capture(allocator, &.{ "log", "--oneline" });
    defer allocator.free(log);
    try testing.expectEqual(@as(usize, 0), log.len);
}

test "쓰기 end-to-end: stage → unstage 왕복이 index에 실제로 반영된다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.zig", "hello\n");

    // 스테이지 — 추적되지 않던 파일이 index에 들어간다.
    var staged = try fx.run(allocator, .stage, &.{"a.zig"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());
    {
        const st = try fx.status(allocator);
        defer allocator.free(st);
        try testing.expect(std.mem.indexOf(u8, st, "1 A. ") != null); // index에 추가됨(v2)
    }

    // 언스테이지 — **unborn이다**(첫 커밋 전). `restore --staged`는 여기서 실패하므로 `rm --cached`가 맞다.
    var unborn = try fx.run(allocator, .unstage_unborn, &.{"a.zig"});
    defer unborn.deinit(allocator);
    try testing.expect(unborn.ok());
    {
        const st = try fx.status(allocator);
        defer allocator.free(st);
        try testing.expect(std.mem.indexOf(u8, st, "? a.zig") != null); // 다시 추적되지 않음(v2)
    }
}

test "쓰기 end-to-end: unborn에서 restore --staged는 실제로 실패한다(그래서 rm --cached가 있다)" {
    // §2가 unborn 변종을 둔 근거를 **추정이 아니라 실행으로** 고정한다. git이 나중에 이걸 허용하게 되면
    // 이 테스트가 깨지고, 그때 변종을 지울 수 있다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.zig", "hello\n");
    var staged = try fx.run(allocator, .stage, &.{"a.zig"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());

    var bad = try fx.run(allocator, .unstage, &.{"a.zig"});
    defer bad.deinit(allocator);
    try testing.expect(!bad.ok());
    // 실패 이유가 stderr로 온다 — §5가 "가공해서 보여 준다"고 한 그 바이트다.
    try testing.expect(bad.stderr_bytes.len > 0);
}

test "쓰기 end-to-end: MM(부분 스테이지) — 스테이지 뒤 또 고치면 양쪽에 난다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.zig", "one\n");
    var first = try fx.run(allocator, .stage, &.{"a.zig"});
    defer first.deinit(allocator);
    try testing.expect(first.ok());
    try fx.plainGit(allocator, &.{ "commit", "-q", "-m", "init" });

    try fx.write("a.zig", "two\n");
    var second = try fx.run(allocator, .stage, &.{"a.zig"});
    defer second.deinit(allocator);
    try testing.expect(second.ok());
    try fx.write("a.zig", "three\n");

    const st = try fx.status(allocator);
    defer allocator.free(st);
    // index에도 작업트리에도 변경이 있다 = `MM`. 두 섹션에 각각 나야 하는 그 파일이다.
    try testing.expect(std.mem.indexOf(u8, st, "1 MM ") != null); // index에도 작업트리에도 변경(v2)

    // 커밋이 있으므로 이제 `restore --staged`가 통한다(unborn 변종이 필요 없는 상태).
    var un = try fx.run(allocator, .unstage, &.{"a.zig"});
    defer un.deinit(allocator);
    try testing.expect(un.ok());
    const after = try fx.status(allocator);
    defer allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "1 .M ") != null); // 작업트리에만 변경(v2)
}

test "쓰기 end-to-end: 공백·비ASCII·`-` 시작 경로가 그대로 통한다(셸을 안 거친다)" {
    // 이 셋이 P2 검증 목록의 핵심이다. 셸을 거치면 따옴표·글로빙으로 깨지고, `--`가 없으면 `-`가 옵션이 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    const paths = [_][]const u8{ "with space.txt", "한글 파일.txt", "-leading-dash.txt", "dir/nested file.txt" };
    for (paths) |p| try fx.write(p, "x\n");

    var out = try fx.run(allocator, .stage, &paths);
    defer out.deinit(allocator);
    try testing.expect(out.ok());

    const st = try fx.status(allocator);
    defer allocator.free(st);
    // `core.quotePath=false`라 비ASCII가 C-quote되지 않고 그대로 나온다.
    for (paths) |p| {
        try testing.expect(std.mem.indexOf(u8, st, p) != null);
    }
}

test "쓰기 end-to-end: 모두 스테이지·모두 언스테이지" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.txt", "a\n");
    try fx.write("b.txt", "b\n");

    var all = try fx.run(allocator, .stage_all, &.{});
    defer all.deinit(allocator);
    try testing.expect(all.ok());
    {
        const st = try fx.status(allocator);
        defer allocator.free(st);
        try testing.expect(std.mem.indexOf(u8, st, "1 A. ") != null);
        try testing.expect(std.mem.count(u8, st, "1 A. ") == 2);
    }

    // unborn이므로 `rm --cached -r -- .`다.
    var none = try fx.run(allocator, .unstage_all_unborn, &.{});
    defer none.deinit(allocator);
    try testing.expect(none.ok());
    const st = try fx.status(allocator);
    defer allocator.free(st);
    try testing.expect(std.mem.indexOf(u8, st, "? a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, st, "? b.txt") != null);
}

test "쓰기 end-to-end: hook이 파이프 버퍼를 넘겨 쏟아도 교착하지 않는다" {
    // **이 테스트가 없으면 못 잡는 결함이었다.** 초판은 stdout·stderr 파이프를 둘 다 열고 stdout을 끝까지
    // 읽은 뒤 stderr를 읽었다. 자식이 stderr 버퍼(64 KiB)를 채우면 자식은 write에서, 우리는 stdout EOF에서
    // 서로를 기다린다 — §5가 "hook 출력은 수천 줄이 될 수 있다"고 못박았으니 가정이 아니라 예정된 일이다.
    // 지금은 파이프를 **하나만** 열어 그 상황이 구조적으로 불가능하다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.txt", "one\n");
    var staged = try fx.run(allocator, .stage, &.{"a.txt"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());

    // 파이프 버퍼(64 KiB)를 확실히 넘기는 양을 stderr로 쏟고 거부하는 pre-commit hook.
    try fx.write(".git/hooks/pre-commit",
        \\#!/bin/sh
        \\i=0
        \\while [ $i -lt 4000 ]; do
        \\  echo "hook: this line exists only to fill the stderr pipe buffer $i" >&2
        \\  i=$((i+1))
        \\done
        \\exit 1
        \\
    );
    try fx.chmodExec(".git/hooks/pre-commit");

    // 메시지 파일은 **저장소 밖**이다(§2) — 여기서는 tmp 루트 옆에 둔다.
    const msg_path = try std.fs.path.join(allocator, &.{ fx.root, "..", "commit-msg.txt" });
    defer allocator.free(msg_path);
    try fx.dir.dir.writeFile(fixture_io, .{ .sub_path = "../commit-msg.txt", .data = "subject\n" });

    // hook이 허용되는 유일한 명령이 커밋이다(§3) — 그래서 이 경로로만 이 상황이 생긴다.
    var out = try runWriteSync(allocator, .commit, fx.exe, fx.root, &.{}, msg_path, null);
    defer out.deinit(allocator);

    try testing.expect(!out.ok()); // hook이 거부했다
    // 이유가 실제로 손에 들어온다 — §5가 화면에 내라고 한 그 바이트다.
    try testing.expect(out.stderr_bytes.len > 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, out.stderr_bytes, "hook: this line exists") != null);
}

test "쓰기 stderr는 상한을 넘겨도 파이프를 끝까지 비운다(자식을 EPIPE로 죽이지 않는다)" {
    // 읽기는 상한에서 멈춰 자식을 끊는 것이 의도지만, 쓰기에서 그러면 **사용자의 git을 index 쓰는 도중에
    // 죽이고 `index.lock`을 남긴다**. 보관은 유계, 배수는 끝까지임을 파이프로 직접 고정한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fds: [2]c_int = undefined;
    try testing.expect(std.c.pipe(&fds) == 0);
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = std.c.dup2(fds[1], 1);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        // 상한(4 KiB)의 수십 배를 쏟는다. 부모가 도중에 멈추면 SIGPIPE로 죽어 exit code가 0이 아니게 된다.
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "i=0; while [ $i -lt 3000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done", null };
        _ = std.c.execve("/bin/sh", @ptrCast(&argv), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.close(fds[1]);
    const keep: usize = 4096;
    const bytes = try readAllFdDraining(allocator, fds[0], keep);
    defer allocator.free(bytes);
    _ = std.c.close(fds[0]);

    try testing.expectEqual(keep, bytes.len); // 보관은 상한까지만
    // **자식이 정상 종료했다** = 우리가 파이프를 끝까지 비웠다는 뜻이다(멈췄으면 SIGPIPE로 죽는다).
    try testing.expectEqual(@as(c_int, 0), reapPid(pid));
}

test "자식의 stdin은 /dev/null이다(stdin을 읽는 hook이 멈추지 않는다)" {
    // `GIT_TERMINAL_PROMPT=0`은 git 자신의 프롬프트만 막는다. 저장소가 심어 둔 hook이 `read`를 부르면
    // 상속된 stdin에서 블록하고, 그 쓰기는 §1이 경고한 "영영 안 끝나는 명령"이 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = worker_allocator;
    var fx = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fx.deinit(allocator);

    try fx.write("a.txt", "one\n");
    var staged = try fx.run(allocator, .stage, &.{"a.txt"});
    defer staged.deinit(allocator);
    try testing.expect(staged.ok());

    // stdin을 읽고, EOF면 그 사실을 stderr로 알린 뒤 거부하는 hook.
    try fx.write(".git/hooks/pre-commit",
        \\#!/bin/sh
        \\if read line; then
        \\  echo "hook: read a line" >&2
        \\else
        \\  echo "hook: stdin was eof" >&2
        \\fi
        \\exit 1
        \\
    );
    try fx.chmodExec(".git/hooks/pre-commit");

    const msg_path = try std.fs.path.join(allocator, &.{ fx.root, "..", "stdin-msg.txt" });
    defer allocator.free(msg_path);
    try fx.dir.dir.writeFile(fixture_io, .{ .sub_path = "../stdin-msg.txt", .data = "subject\n" });

    var out = try runWriteSync(allocator, .commit, fx.exe, fx.root, &.{}, msg_path, null);
    defer out.deinit(allocator);
    try testing.expect(!out.ok());
    // **즉시 EOF**여야 한다. 상속된 stdin이면 여기서 블록하거나 남의 입력을 삼킨다.
    try testing.expect(std.mem.indexOf(u8, out.stderr_bytes, "hook: stdin was eof") != null);
}

test "실제 저장소: 커밋 파일 목록과 `커밋^` 쪽 blob (P4b)" {
    // **가정이 아니라 git에게 묻는다**: 루트 커밋에 `^`가 없다는 것, `show`가 그 커밋도 파일로 낸다는
    // 것, 첫 부모 기준이 병합에서도 한 줄에 한 상태를 준다는 것 — 셋 다 명령의 실제 동작이다.
    const allocator = std.testing.allocator;
    var fixture = (try WriteFixture.init(allocator)) orelse return error.SkipZigTest;
    defer fixture.deinit(allocator);

    // ① 루트 커밋: 파일 하나.
    try fixture.write("a.txt", "one\n");
    try fixture.plainGit(allocator, &.{ "add", "a.txt" });
    try fixture.plainGit(allocator, &.{ "commit", "-q", "-m", "root" });

    // ② 두 번째 커밋: 그 파일을 고치고 하나를 더한다.
    try fixture.write("a.txt", "two\n");
    try fixture.write("b.txt", "new\n");
    try fixture.plainGit(allocator, &.{ "add", "a.txt", "b.txt" });
    try fixture.plainGit(allocator, &.{ "commit", "-q", "-m", "second" });

    // 목록을 읽어 두 커밋의 OID를 얻는다(제품과 같은 명령).
    const log_out = try runWithArg(allocator, .log, fixture.exe, fixture.root, "10");
    defer allocator.free(log_out.bytes);
    var it = maru.session.git_log.iterate(log_out.bytes);
    const second = it.next() orelse return error.MissingCommit;
    const root = it.next() orelse return error.MissingCommit;
    try std.testing.expect(second.hasParent());
    try std.testing.expect(!root.hasParent()); // **루트 커밋은 부모가 없다**

    // ③ 두 번째 커밋이 바꾼 파일: `a.txt`(M)와 `b.txt`(A).
    const files_out = try runWithArg(allocator, .commit_files, fixture.exe, fixture.root, second.oid);
    defer allocator.free(files_out.bytes);
    // **증감도 같은 출력에서 온다**(`--raw --numstat` — P4c). 형식이 갈리면 여기서 걸린다: 실제 git 을
    // 돌리는 자리라 「우리가 안다고 적은 형식」이 아니라 **그 버전이 실제로 내는 형식**을 본다.
    var names = maru.session.git_status.iterateCommitFiles(files_out.bytes);
    var saw_modified = false;
    var saw_added = false;
    var count: usize = 0;
    while (names.next()) |entry| : (count += 1) {
        if (std.mem.eql(u8, entry.path, "a.txt") and entry.letter == 'M') {
            saw_modified = true;
            try std.testing.expect(entry.has_delta);
            try std.testing.expectEqual(@as(u32, 1), entry.added); // `one` → `two`
            try std.testing.expectEqual(@as(u32, 1), entry.removed);
        }
        if (std.mem.eql(u8, entry.path, "b.txt") and entry.letter == 'A') {
            saw_added = true;
            try std.testing.expect(entry.has_delta);
            try std.testing.expectEqual(@as(u32, 1), entry.added);
            try std.testing.expectEqual(@as(u32, 0), entry.removed);
        }
    }
    try std.testing.expect(saw_modified and saw_added);
    // numstat 줄이 파일로 새면 여기서 **네 줄**이 된다(그 회귀는 화면에서 목록이 두 배가 되는 모습이다).
    try std.testing.expectEqual(@as(usize, 2), count);

    // ④ 루트 커밋도 파일을 낸다(`diff <oid>^ <oid>`였다면 여기서 실패한다).
    const root_files = try runWithArg(allocator, .commit_files, fixture.exe, fixture.root, root.oid);
    defer allocator.free(root_files.bytes);
    var root_names = maru.session.git_status.iterateCommitFiles(root_files.bytes);
    const first_entry = root_names.next() orelse return error.MissingRootFile;
    try std.testing.expectEqualStrings("a.txt", first_entry.path);
    try std.testing.expectEqual(@as(u8, 'A'), first_entry.letter);

    // ⑤ 비교의 두 쪽: `커밋^:a.txt`는 옛 내용, `커밋:a.txt`는 새 내용.
    var spec_buf: [std.fs.max_path_bytes + 72]u8 = undefined;
    const parent_spec = maru.session.git_command.commitParentBlobSpec(second.oid, "a.txt", &spec_buf).?;
    const left = try runWithArg(allocator, .show_blob, fixture.exe, fixture.root, parent_spec);
    defer allocator.free(left.bytes);
    try std.testing.expectEqualStrings("one\n", left.bytes);

    var spec_buf2: [std.fs.max_path_bytes + 72]u8 = undefined;
    const own_spec = maru.session.git_command.commitBlobSpec(second.oid, "a.txt", &spec_buf2).?;
    const right = try runWithArg(allocator, .show_blob, fixture.exe, fixture.root, own_spec);
    defer allocator.free(right.bytes);
    try std.testing.expectEqualStrings("two\n", right.bytes);

    // ⑥ 루트 커밋의 `^`는 **없다** — 그 실패가 곧 "왼쪽이 없다"이다.
    var spec_buf3: [std.fs.max_path_bytes + 72]u8 = undefined;
    const root_parent = maru.session.git_command.commitParentBlobSpec(root.oid, "a.txt", &spec_buf3).?;
    try std.testing.expectError(error.GitFailed, runWithArg(allocator, .show_blob, fixture.exe, fixture.root, root_parent));
}

test "commit_files 읽기는 hex가 아닌 rev를 거절한다 (P4b 적대적 검증)" {
    // 이 명령은 rev를 **그대로 인자로** 싣는다 — `--upload-pack=…` 같은 값이 통과하면 우리가 닫아 둔
    // 외부 프로세스 경로가 다시 열린다.
    const allocator = std.testing.allocator;
    var backend = try Backend.init(fixture_io);
    defer backend.deinit();
    try std.testing.expect(!backend.submitCommitFiles("/usr/bin/git", "/repo", "--upload-pack=evil", 1));
    try std.testing.expect(!backend.submitCommitFiles("/usr/bin/git", "/repo", "HEAD", 2));
    _ = allocator;
}

test "파일 목록 읽기는 hex가 아닌 rev를 거절한다(커밋·턴 둘 다) (P5)" {
    var backend = try Backend.init(fixture_io);
    defer backend.deinit();
    const good = "650a0bbef96a1dd562e0d39f262260ae002c1545";
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", "HEAD HEAD~1", 1));
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", good ++ " --upload-pack=x", 2));
    // 셋 이상도 거절한다 — 인자가 하나 더 붙는 길을 열지 않는다.
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", good ++ " " ++ good ++ " " ++ good, 3));
}

test "원격 쓰기 실패: ssh 가 한 말과 git 이 한 말을 가른다 (RS4a 5회차)" {
    // `ssh` 는 **자기 실패에만** 255 를 쓴다(실측 2026-09-01: 소켓이 죽으면
    // `Host key verification failed.` + 255). 그 stderr 를 저장소 이야기로 보여 주면 사용자가 자기
    // 저장소를 의심한다 — 그 화면에서는 무엇을 고쳐야 할지 알 수 없다.
    var died: WriteResult = .{
        .request_id = 1,
        .spawned = true,
        .exit_code = 255,
        .stderr = &.{},
        .stderr_truncated = false,
        .remote = true,
    };
    try std.testing.expect(died.transportFailed());

    // **로컬의 255 는 git 이 한 말이다** — 원격이 아닌데 갈라 버리면 진짜 사유를 가린다.
    var local255 = died;
    local255.remote = false;
    try std.testing.expect(!local255.transportFailed());

    // **git 이 실제로 거부한 것은 그대로 낸다**(128 = fatal, 1 = 거절 — 실측으로 둘 다 왔다).
    for ([_]c_int{ 1, 128 }) |code| {
        var refused = died;
        refused.exit_code = code;
        try std.testing.expect(!refused.transportFailed());
    }
    // 띄우지도 못했으면 그것은 **로컬** 실패다(그 자리는 `spawned=false` 가 이미 가른다).
    var unspawned = died;
    unspawned.spawned = false;
    try std.testing.expect(!unspawned.transportFailed());
    // 성공은 실패가 아니다.
    var okr = died;
    okr.exit_code = 0;
    try std.testing.expect(!okr.transportFailed());
    try std.testing.expect(okr.ok());
}

test "원격 쓰기: 원격 라우팅이 떨어져도 상대경로 git 을 실행하지 않는다 (RS4a 7회차)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // 호출자는 **원격일 때만** `"git"`(이름)을 넘긴다 — `buildRemote` 가 `argv[0]` 을 버리기 때문이다.
    // 그 값이 어떤 이유로든 **로컬 갈래**로 새면 `execve("git", …)` 가 되고, POSIX 는 PATH 를 안 뒤지고
    // **cwd 기준 상대경로**로 푼다 — 저장소 안에 `git` 이라는 실행 파일이 있으면 그것이 돈다.
    //
    // 그 상태가 「명령 실패」로 끝나는 것과 「남의 스크립트 실행」으로 끝나는 것은 하늘과 땅이다.
    try std.testing.expectError(
        error.GitExeNotAbsolute,
        runWriteSync(allocator, .stage, "git", "/srv/app", &.{"a.txt"}, null, null),
    );
    // 원격이면 이름이어도 된다 — 그 자리는 `execve` 가 아니라 **원격 셸**이 푼다(PATH 처방이 그 위에 있다).
    const out = try runWriteSync(
        allocator,
        .stage,
        "git",
        "/srv/app",
        &.{"a.txt"},
        null,
        .{ .dest = "u@nowhere.invalid", .control_path = "/nonexistent/sock" },
    );
    defer allocator.free(out.stderr_bytes);
    // 소켓이 없으니 ssh 가 **자기 실패**로 끝난다 — git 이 한 말이 아니다(5회차와 같은 축).
    try std.testing.expectEqual(@as(c_int, 255), out.exit_code);
}

/// 원격 SCM 판정자가 쓰는 **실물 SSH 하네스**. `tools/remote-scm/ssh_harness.sh` 가 env 로 준다.
///
/// ⚠️ **없으면 건너뛴다 — 없는 것을 있다고 치고 통과시키지 않는다.** 개발자 기계에서 손으로 돌릴 때는
/// 그 스크립트를 거치지 않으면 이 판정자들이 조용히 안 돈다. 그것이 맞다: 원격 판정을 **가짜 대상**으로
/// 통과시키면 그 초록은 아무것도 뜻하지 않는다.
fn remoteScmHarness() ?struct { dest: []const u8, ctl: []const u8, repo: []const u8 } {
    const dest_z = std.c.getenv("MARU_REMOTE_SCM_DEST") orelse return null;
    const ctl_z = std.c.getenv("MARU_REMOTE_SCM_CTL") orelse return null;
    const repo_z = std.c.getenv("MARU_REMOTE_SCM_REPO") orelse return null;
    const dest = std.mem.span(dest_z);
    const ctl = std.mem.span(ctl_z);
    const repo = std.mem.span(repo_z);
    if (dest.len == 0 or ctl.len == 0 or repo.len == 0) return null;
    return .{ .dest = dest, .ctl = ctl, .repo = repo };
}

test "원격 커밋: 512 KiB 메시지가 stdin 으로 가고, hook 이 stderr 를 쏟아도 안 멈춘다 (RS4b)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hx = remoteScmHarness() orelse return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const remote: git_write_command.Remote = .{ .dest = hx.dest, .control_path = hx.ctl };

    // ⚠️ **이 판정자가 «멈추면» 그것이 실패다.** stdin 을 다 쓴 뒤에야 stderr 를 읽는 구현에서는,
    // hook 이 파이프를 채우는 순간 둘 다 선다 — 우리는 write 에서, 자식은 write 에서.
    // 아래 셋이 그 상황을 **결정적으로** 만든다: 스테이지된 파일 + 시끄러운 hook + 파이프보다 큰 메시지.
    var b: [std.fs.max_path_bytes]u8 = undefined;

    // ⑴ 커밋할 것이 있어야 hook 이 돈다(없으면 git 은 hook 을 안 부른다 — 첫 판정자가 그래서 헛돌았다).
    // **매번 다른 내용**이어야 한다 — 같으면 두 번째 실행에서 커밋할 것이 없어 hook 이 안 돌고,
    // 그러면 이 판정자가 겹침을 재현하지 못한 채 초록이 된다(그 함정을 한 번 밟았다).
    const file = try std.fmt.bufPrint(&b, "{s}/rs4b-probe.txt", .{hx.repo});
    var stamp: [64]u8 = undefined;
    const content = try std.fmt.bufPrint(&stamp, "probe {d}\n", .{std.Io.Clock.awake.now(io).nanoseconds});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = content });
    const staged = try runWriteSync(allocator, .stage, git_write_command.remote_git_exe, hx.repo, &.{"rs4b-probe.txt"}, null, remote);
    allocator.free(staged.stderr_bytes);
    try std.testing.expectEqual(@as(c_int, 0), staged.exit_code); // RS4a 가 원격 index 를 실제로 바꾼다

    // ⑵ 파이프 버퍼(수십 KiB)를 훌쩍 넘는 stderr 를 내는 hook.
    const hook_dir = try std.fmt.bufPrint(&b, "{s}/.git/hooks", .{hx.repo});
    std.Io.Dir.cwd().createDirPath(io, hook_dir) catch {}; // 이미 있으면 그대로 쓴다
    var hook_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hook = try std.fmt.bufPrint(&hook_buf, "{s}/pre-commit", .{hook_dir});
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = hook,
        .data = "#!/bin/sh\nawk 'BEGIN{for(i=0;i<20000;i++)print \"noise line \" i}' >&2\nexit 0\n",
    });
    defer std.Io.Dir.cwd().deleteFile(io, hook) catch {};
    // 실행 비트를 세운다 — git 은 실행 가능한 hook 만 부른다.
    const hook_z = try allocator.dupeZ(u8, hook);
    defer allocator.free(hook_z);
    if (std.c.chmod(hook_z, 0o755) != 0) return error.SkipZigTest;

    // ⑶ 512 KiB 메시지.
    const big = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0.."RS4b-STDIN".len], "RS4b-STDIN");
    big[10] = '\n';
    big[11] = '\n';
    big[big.len - 1] = '\n';
    var msg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msg_path = try std.fmt.bufPrint(&msg_buf, "{s}/.git/rs4b-msg.txt", .{hx.repo});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = msg_path, .data = big });
    defer std.Io.Dir.cwd().deleteFile(io, msg_path) catch {};

    const out = try runWriteSync(allocator, .commit, git_write_command.remote_git_exe, hx.repo, &.{}, msg_path, remote);
    defer allocator.free(out.stderr_bytes);
    try std.testing.expectEqual(@as(c_int, 0), out.exit_code);
    try std.testing.expect(out.stderr_bytes.len > 64 * 1024); // hook 이 실제로 쏟았다(겹침이 일어났다)

    // **바이트가 그대로 도착했나.** 원격이 loopback 이라 그 저장소를 직접 읽어 대조할 수 있다.
    const head = try runArgvWithEnv(allocator, &.{ "/usr/bin/git", "-C", hx.repo, "log", "-1", "--format=%B" }, null);
    defer allocator.free(head.bytes);
    try std.testing.expect(std.mem.startsWith(u8, head.bytes, "RS4b-STDIN"));
    try std.testing.expect(head.bytes.len >= big.len - 2); // 잘리지 않았다
}
