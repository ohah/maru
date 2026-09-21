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
const remote_shell = maru.session.remote_shell;
const git_locate = maru.session.git_locate;
const dock_panel = maru.session.dock_panel;
const repo_path = maru.session.repo_path;
const safe_open = @import("safe_open.zig");
const turn_index_cache = @import("turn_index_cache.zig"); // 임시 index 의 수명 — 워커가 오래된 형제를 프로세스당 한 번 쓸어 낸다

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

/// 읽기가 왜 실패했는가. **「읽지 못함」 하나로 뭉개면 사용자는 무엇을 고쳐야 할지 모른다** —
/// 원격에 git 이 없는 것과 연결이 끊긴 것은 **고치는 방법이 다르다**(RS4 계약 §2.2 ⑺).
///
/// 실측(2026-09-01): 없는 명령은 **127**, ssh 전송 실패는 **255** 로 갈린다. `git` 자신은 그 둘을
/// 안 쓴다(fatal 은 128, 거절은 1) — 그래서 원격에서만 그 두 값이 우리 이야기다.
/// 읽기 오류를 **화면이 쓰는 사유**로 바꾼다. 규칙이 한 자리여야 하는 이유는, 사본이 갈리면 한쪽만
/// 새 사유를 배우기 때문이다 — 이 저장소가 반복해서 당한 모양이다(원격 SCM §2.2 ⑷ 의 PATH 처방이
/// 세 곳에 흩어져 셋 다 틀렸던 그 일). 목록·히스토리·커밋 파일 목록이 **같은 함수**를 부른다.
pub fn readFailureFor(err: anyerror) ReadFailure {
    return switch (err) {
        error.RemoteGitMissing => .remote_git_missing,
        error.RemoteTransportFailed => .remote_transport,
        else => .generic,
    };
}

pub const ReadFailure = enum {
    /// git 이 돌았고 우리가 그 실패를 딱히 분류하지 못한다(로컬의 기본값이기도 하다).
    generic,
    /// 원격 PATH 에 `git` 이 없다(exit 127). 처방을 깔아도 못 찾은 것이므로 **사용자가 깔아야 한다.**
    remote_git_missing,
    /// ssh 가 자기 실패로 끝났다(exit 255). git 까지 **닿지도 못했다** — 저장소 이야기가 아니다.
    remote_transport,
};

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
    /// `ok == false` 일 때 **왜**. 화면이 이유를 말할 수 있게 실어 나른다.
    failure: ReadFailure = .generic,
    /// 출력이 상한에 걸려 잘렸는가. 목록 끝에 그 사실을 표시한다.
    truncated: bool = false,
    /// **시작 마커가 남은 충돌 경로들**(S4 — NUL 구분, `git grep -l -z`). 충돌 행이 하나도 없으면 비어
    /// 있고 `conflict_scan_ok` 가 참이다.
    conflict_markers: []u8 = &.{},
    /// 위 판정을 **했는가**. 거짓이면 모든 충돌 행이 「마커 남음」으로 취급된다(`+` 를 아끼는 쪽이 안전하다)
    /// — 「판정 못 함」과 「전부 해결됨」은 다른 상태라 빈 목록만으로는 가를 수 없다.
    conflict_scan_ok: bool = false,
    /// 이 결과가 어느 요청의 것인지. 늦게 온 결과가 최신 화면을 덮어쓰지 않게 호출자가 대조한다.
    request_id: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.status);
        allocator.free(self.conflict_markers);
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
    /// **이 답을 어느 저장소에 물었나**(owned). `check-ignore` 의 출력은 그 저장소 루트 기준 **상대경로**라,
    /// 절대경로로 되돌리려면 그 루트가 있어야 한다.
    ///
    /// ⚠️ **물을 때의 저장소를 답이 직접 들고 온다 — 소비자가 다시 고르지 않는다.** 예전에는 드레인이
    /// `gitRepoRoot` 로 루트를 **다시** 골랐는데, 그 값은 도크가 기억하는 저장소라 **묻던 저장소와 다를 수
    /// 있다**(탐색기가 터미널과 다른 저장소를 볼 때·원격 SCM 목록을 본 뒤). 그러면 답이 **엉뚱한
    /// 절대경로**에 붙어, 흐림이 안 서거나 남의 행이 흐려진다. 나가는 자리와 돌아오는 자리가 갈리면
    /// 한쪽이 낡는다 — 답이 자기 질문의 틀을 들고 오게 한다.
    repo: []u8 = &.{},
    /// **이 답이 무엇을 물었나**(owned). 출력에는 «무시된 것»만 오므로, 무시가 풀린 항목의 표시를
    /// 지우려면 «물어본 전체»가 필요하다.
    ///
    /// ⚠️ **위 `repo` 와 같은 이유로 답이 들고 온다 — 호출자에게 다시 묻지 않는다.** 한때는 소비자가
    /// 세션 버퍼를 「물어본 것」으로 읽었는데, 그 버퍼는 배치마다 덮이고 백엔드는 답이 걸려 있는 동안
    /// 새 요청을 **거절**한다 — 「A 를 물어 둔 채 B 를 담」으면 버퍼는 B 것이 되고, 뒤늦게 온 A 의 답이
    /// **B 의 행들을 지웠다**(아무도 B 를 물어본 적이 없는데 흐림이 풀린다 — 적대적 검증 10 회차).
    /// 답이 자기 질문을 들고 오면 그 갈림 자체가 없다.
    asked: []const []u8 = &.{},

    pub fn deinit(self: *IgnoreResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.repo);
        for (self.asked) |a| allocator.free(a);
        if (self.asked.len > 0) allocator.free(self.asked);
        self.text = &.{};
        self.repo = &.{};
        self.asked = &.{};
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
    /// **왜 못 읽었나**(RS7d). `ok = false` 일 때만 뜻이 있다 — 목록 읽기(`Result.failure`)와 같은
    /// 타입·같은 규칙(`readFailureFor`)이다.
    failure: ReadFailure = .generic,

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
    /// **왜 못 읽었나**(RS7d) — 위와 같은 타입·같은 규칙.
    failure: ReadFailure = .generic,

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
    /// 왼쪽. `.merge_stages` 에서는 **현재 것**(`:2:` — ours)이다.
    original: []u8 = &.{},
    /// 오른쪽. `.merge_stages` 에서는 **들어온 것**(`:3:` — theirs)이다.
    modified: []u8 = &.{},
    /// **공통 조상**(`:1:`) — `.merge_stages` 에서만 찬다(S3a).
    ///
    /// **빈 것과 «없는 것»이 다르다**: add/add 충돌은 조상이 아예 없고(양쪽이 새로 만들었다),
    /// 조상이 **빈 파일**인 경우도 있다. 그 둘을 길이로 가르면 빈 조상이 「없음」으로 읽혀 3-way 가
    /// 근거 없이 2-way 로 저하한다 — 그래서 `has_base` 를 따로 든다.
    base: []u8 = &.{},
    /// 세 판 중 **무엇을 읽었나**(S3a). 「열 수 있나」·「2-way 로 저하하나」는 이 값이 답한다.
    ///
    /// **불리언으로 풀어 두지 않는다.** 예전에는 `has_base` 하나만 실었는데, 그 값을 만드는 자리가
    /// 워커와 여기 **둘**이 되어 한쪽을 「내용이 비었나」로 바꿔도 아무 판정자가 안 깨어났다
    /// (적대적 검증 1회차). 판정을 소유한 타입을 그대로 실으면 그 두 번째 자리가 아예 없다.
    stages: maru.session.editor.conflict.StageSet = .{},
    ok: bool = false,
    /// 한쪽이라도 상한에서 잘렸다. **잘린 내용을 온전한 파일처럼 보여 주지 않기 위해** 호출자가 이 사실을 쓴다.
    truncated: bool = false,
    request_id: u64 = 0,

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.original);
        allocator.free(self.modified);
        allocator.free(self.base);
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
        //
        // ⚠️ **부분 복사를 남기지 않는다.** 예전에는 중간에 실패하면 `owned[0..filled]` 를 실었는데,
        // 그 슬라이스는 **할당한 것과 길이가 다르다** — 뒤에서 `free` 하는 자리들(`releaseIgnoreJob`·
        // `IgnoreResult.deinit`)이 배열 크기를 슬라이스 길이로 읽으므로 **엉뚱한 크기로 반납**한다.
        // 하나라도 못 담으면 통째로 물리고 이 tick 은 안 묻는다 — 다음 스캔이 다시 묻는다.
        // ⚠️ **여기서 «보낼 만큼만» 담는다.** 예전에는 개수 상한만 보고 전부 담았는데, 실제로 나가는
        // 것은 stdin 페이로드라 **바이트 상한에서 잘린다** — 그러면 `asked` 에는 보낸 적 없는 경로가
        // 섞이고, 드레인이 그 행들의 표시를 지운다(아무도 안 물어봤는데 흐림이 풀린다). 경로가 길고
        // 항목이 많은 **깊은 디렉터리**에서 실제로 닿는다(512 × 128 B 면 넘는다).
        //
        // 「물어본 것」과 「보낸 것」이 갈리면 한쪽이 낡는다 — 여기서 하나로 만든다(적대적 검증 16 회차).
        const take = blk: {
            var budget: usize = 0;
            var n: usize = 0;
            while (n < @min(paths.len, git_command.check_ignore_batch)) : (n += 1) {
                const next = budget + paths[n].len + 1;
                if (next > git_command.max_check_ignore_stdin_bytes) break;
                budget = next;
            }
            break :blk n;
        };
        if (take == 0) return self.releaseIgnoreJob(job);
        const owned = state.allocator.alloc([]u8, take) catch return self.releaseIgnoreJob(job);
        var filled: usize = 0;
        for (paths[0..owned.len]) |path| {
            owned[filled] = state.allocator.dupe(u8, path) catch break;
            filled += 1;
        }
        if (filled < owned.len) {
            for (owned[0..filled]) |p| state.allocator.free(p);
            state.allocator.free(owned); // **할당한 그 슬라이스 그대로** 반납한다
            job.ignore_paths = &.{};
            return self.releaseIgnoreJob(job);
        }
        job.ignore_paths = owned;
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
    /// 판정자용: `check-ignore` 답을 **직접 심는다**. 실제 git 을 안 띄우고 「답이 어느 틀로 도착했나」를
    /// 세울 방법이 이것뿐이다 — 그 틀이 소비자에서 다시 골라지지 않는지가 이 자리의 계약이다.
    /// 소유는 결과가 진다(`deinit` 가 둘 다 푼다).
    pub fn pushIgnoreResultForTest(self: *Backend, repo: []const u8, asked: []const []const u8, text: []const u8) bool {
        const state = self.state orelse return false;
        const repo_copy = state.allocator.dupe(u8, repo) catch return false;
        const text_copy = state.allocator.dupe(u8, text) catch {
            state.allocator.free(repo_copy);
            return false;
        };
        var result: IgnoreResult = .{ .request_id = 0, .ok = true, .text = text_copy, .repo = repo_copy };
        if (asked.len > 0) {
            const owned = state.allocator.alloc([]u8, asked.len) catch {
                result.deinit(state.allocator);
                return false;
            };
            var filled: usize = 0;
            for (asked) |a| {
                owned[filled] = state.allocator.dupe(u8, a) catch break;
                filled += 1;
            }
            // **부분 목록은 안 싣는다** — 못 담긴 행의 표시가 안 지워져 무시가 풀린 항목이 흐린 채로
            // 남는다. 여기까지 왔으면 그냥 실패다(판정자용 주입이라 재시도가 없다).
            //
            // 정리는 **손으로** 한다: `owned` 는 `asked.len` 으로 잡았으므로 `owned[0..filled]` 를
            // 넘기면 원래 슬라이스가 아니다.
            if (filled < asked.len) {
                for (owned[0..filled]) |a| state.allocator.free(a);
                state.allocator.free(owned);
                result.deinit(state.allocator);
                return false;
            }
            result.asked = owned;
        }
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.ignore_result) |*old| old.deinit(state.allocator);
        state.ignore_result = result;
        return true;
    }

    /// `check-ignore` 자리가 차 있나 — 도는 작업이 있거나, 아직 아무도 안 걷어간 답이 있으면 참.
    ///
    /// **거절된 질의를 다시 걸 때가 언제인지**를 tick 이 이 값으로 정한다. 없으면 tick 이 매번 다시
    /// 걸어 보고 매번 거절당해, 스캔만 계속 도는 헛바퀴가 된다.
    pub fn ignoreBusy(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.ignore_inflight > 0 or state.ignore_result != null;
    }

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
    pub fn submitRepoStatus(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        request_id: u64,
        remote: ?git_command.Remote,
    ) bool {
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
        // **원격 두 축은 쌍으로 든다** — 하나만 들면 `remoteTarget()` 이 로컬로 읽어 원격 경로를
        // 이쪽 git 에 준다(목록 읽기 job 이 같은 규율을 진다).
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch return self.releaseRepoStatusJob(job);
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch return self.releaseRepoStatusJob(job);
        }
        const thread = std.Thread.spawn(.{}, repoStatusWorker, .{job}) catch return self.releaseRepoStatusJob(job);
        thread.detach();
        return true;
    }

    /// 히스토리 목록을 건다(P4). 하나가 돌고 있거나 결과가 안 걷혔으면 거절한다 — 탭을 빠르게
    /// 오가도 프로세스는 하나다.
    ///
    /// `remote` 가 있으면 **저쪽 기계에서** 읽는다(RS7b — [계획](../../../docs/plans/remote-scm.md) §18.3).
    /// 목록 읽기(`submit`)·머리 줄(`submitRepoStatus`)과 **같은 모양**이다: 두 축을 쌍으로 들고,
    /// 감싸는 일은 `runOn` 한 자리가 한다.
    pub fn submitLog(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        limit: u32,
        request_id: u64,
        remote: ?git_command.Remote,
    ) bool {
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
        // **원격 두 축은 쌍으로 든다** — 하나만 들면 `remoteTarget()` 이 로컬로 읽어 원격 경로를
        // 이쪽 git 에 준다(목록 읽기·머리 줄 job 이 같은 규율을 진다).
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch return self.releaseLogJob(job);
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch return self.releaseLogJob(job);
        }
        const thread = std.Thread.spawn(.{}, logWorker, .{job}) catch return self.releaseLogJob(job);
        thread.detach();
        return true;
    }

    fn releaseLogJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        // **원격 두 축도 여기서 푼다**(RS7b). 제출이 실패하는 경로마다 새면 탭을 오갈 때마다 조금씩
        // 쌓인다 — `releaseRepoStatusJob` 이 같은 이유로 `freeRemote` 를 부른다.
        job.freeRemote(state.allocator);
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
    ///
    /// `remote` 가 있으면 **저쪽 기계에서** 읽는다(RS7c — [계획](../../../docs/plans/remote-scm.md) §18.4).
    pub fn submitCommitFiles(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        oid: []const u8,
        request_id: u64,
        remote: ?git_command.Remote,
    ) bool {
        return self.submitFileList(git_exe, repo, .commit_files, oid, request_id, remote);
    }

    /// 턴 하나가 바꾼 파일 목록(P5). 키는 `<treeA> <treeB>`이고 **둘 다 hex여야 한다**.
    ///
    /// **tree 가 있는 기계에서 읽는다**(AT3c). 원격 Term 의 턴은 `captureTurnSnapshot` 이 저쪽에 찍으므로 그
    /// object 는 저쪽에만 있다 — 호출자가 링의 저장소 키(`turn_snapshot.machineOf`)로 기계를 고른다. 로컬 tree 를
    /// 원격에 묻거나 그 반대는 «없는 object» 실패다(RS7c §18.4 가 막았던 자리).
    pub fn submitTurnFiles(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        pair: []const u8,
        request_id: u64,
        remote: ?git_command.Remote,
    ) bool {
        return self.submitFileList(git_exe, repo, .turn_name_status, pair, request_id, remote);
    }

    /// 펼친 항목 하나의 파일 목록을 읽는다(커밋·턴 공용).
    fn submitFileList(
        self: *Backend,
        git_exe: []const u8,
        repo: []const u8,
        kind: git_command.Kind,
        key: []const u8,
        request_id: u64,
        remote: ?git_command.Remote,
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
        // **원격 두 축은 쌍으로 든다**(하나만 들면 `remoteTarget()` 이 로컬로 읽는다).
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch return self.releaseCommitFilesJob(job);
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch return self.releaseCommitFilesJob(job);
        }
        const thread = std.Thread.spawn(.{}, commitFilesWorker, .{job}) catch return self.releaseCommitFilesJob(job);
        thread.detach();
        return true;
    }

    fn releaseCommitFilesJob(self: *Backend, job: *Job) bool {
        const state = job.state;
        state.allocator.free(job.git_exe);
        state.allocator.free(job.repo);
        if (job.snapshot_tree.len > 0) state.allocator.free(job.snapshot_tree);
        job.freeRemote(state.allocator); // 원격 두 축도 여기서 푼다(RS7c)
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
        // **원격 축도 푼다**(RS5). 쌍 중 뒤엣것 dupe 가 실패하면 앞엣것이 이미 잡혀 있다 — 안 풀면
        // 그 자리가 샌다(CI 의 DebugAllocator 가 같은 모양을 이미 한 번 잡았다).
        if (job.remote_dest.len > 0) state.allocator.free(job.remote_dest);
        if (job.remote_ctl.len > 0) state.allocator.free(job.remote_ctl);
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
        /// 원격 Term 이면 그 목적지(AT3c). `index_file` 은 그때 **원격 경로**다(로컬 파일이 아니다).
        remote: ?git_command.Remote,
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
        if (remote) |r| {
            job.remote_dest = state.allocator.dupe(u8, r.dest) catch return self.releaseSnapshotJob(job);
            job.remote_ctl = state.allocator.dupe(u8, r.control_path) catch return self.releaseSnapshotJob(job);
        }
        const thread = std.Thread.spawn(.{}, snapshotWorker, .{job}) catch return self.releaseSnapshotJob(job);
        thread.detach();
        return true;
    }

    fn releaseSnapshotJob(self: *Backend, job: *SnapshotJob) bool {
        const state = job.state;
        if (job.remote_ctl.len > 0) state.allocator.free(job.remote_ctl);
        if (job.remote_dest.len > 0) state.allocator.free(job.remote_dest);
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
    /// 원격 Term 의 턴(AT3c) — 비면 로컬. 둘 다 있어야 원격이다(`remoteTarget`).
    remote_dest: []u8 = &.{},
    remote_ctl: []u8 = &.{},

    fn remoteTarget(self: *const SnapshotJob) ?git_command.Remote {
        if (self.remote_dest.len == 0 or self.remote_ctl.len == 0) return null;
        return .{ .dest = self.remote_dest, .control_path = self.remote_ctl };
    }
};

fn snapshotWorker(job: *SnapshotJob) void {
    const state = job.state;
    var result: SnapshotResult = .{ .surface_id = job.surface_id };
    // 오래된 형제 index(크래시로 남은 다른 창의 것)를 프로세스당 한 번 거둔다 — 메인이 아니라 여기인 이유는
    // 수천 개를 `stat` 하는 비용이 프레임에 들어가면 안 되기 때문이다. 쓰기 **앞**이라 방금 쓴 파일은 후보가 아니다.
    if (job.remoteTarget()) |remote| {
        // **원격 턴**(AT3c): 임시 index 는 원격 `/tmp` 의 파일이고 세 명령이 각각 ControlMaster 위 exec 하나다.
        // 형제 index 정리는 로컬 파일 세계의 일이라 여기선 없다.
        if (takeTurnSnapshotRemote(state.allocator, remote, job.repo, job.index_file)) |tree| {
            result.tree = tree;
        } else |_| {}
    } else {
        _ = turn_index_cache.sweepStaleSiblingsOnce(state.io, job.index_file);
        if (takeTurnSnapshot(state.allocator, job.git_exe, job.repo, job.index_file)) |tree| {
            result.tree = tree;
        } else |_| {}
    }

    if (job.remote_ctl.len > 0) state.allocator.free(job.remote_ctl);
    if (job.remote_dest.len > 0) state.allocator.free(job.remote_dest);
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
    // **원격 인지 러너를 쓴다**(RS5). 예전에는 `run` 이라 로컬 git 이 그 경로에 돌았고, 원격 저장소의
    // 워크트리 행에서 **저쪽 기계의 경로를 이쪽 git 이 읽었다**(적대적 검증 2026-09-02).
    if (runOn(state.allocator, job.remoteTarget(), .status, job.git_exe, job.repo, null)) |out| {
        result.text = out.bytes;
        result.ok = true;
    } else |_| {}
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    if (job.remote_dest.len > 0) state.allocator.free(job.remote_dest);
    if (job.remote_ctl.len > 0) state.allocator.free(job.remote_ctl);
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
    // **원격 인지 러너를 쓴다**(RS7b). `runWithArg` 였을 때는 로컬 git 이 원격 경로에 돌았다.
    if (runOn(state.allocator, job.remoteTarget(), .log, job.git_exe, job.repo, limit_arg)) |out| {
        result.text = out.bytes;
        result.truncated = out.truncated;
        result.ok = true;
    } else |err| {
        // **왜 실패했는지 싣는다**(RS7d — §18.5). 목록 읽기와 **같은 함수**로 바꾼다.
        result.failure = readFailureFor(err);
    }
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    job.freeRemote(state.allocator);
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
    // **원격 인지 러너를 쓴다**(RS7c). 턴 축은 호출자가 막으므로 여기 오는 원격은 커밋뿐이다.
    if (runOn(state.allocator, job.remoteTarget(), job.file_list_kind, job.git_exe, job.repo, job.snapshot_tree)) |out| {
        result.text = out.bytes;
        result.truncated = out.truncated;
        result.ok = true;
    } else |err| {
        result.failure = readFailureFor(err); // RS7d — 같은 규칙, 같은 함수
    }
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    if (job.snapshot_tree.len > 0) state.allocator.free(job.snapshot_tree);
    job.freeRemote(state.allocator);
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
    // **물은 저장소를 답에 싣는다**(`IgnoreResult.repo` 주석). 못 실으면 빈 슬라이스이고, 소비자는
    // 그 답을 **버린다** — 틀을 모르는 상대경로를 절대경로로 만들 방법이 없다.
    result.repo = state.allocator.dupe(u8, job.repo) catch &.{};
    // `run` 은 kind 하나로 argv 를 만드는 경로라, 경로가 붙는 이 명령만 argv 를 직접 조립해 넘긴다.
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.buildCheckIgnore(job.git_exe, job.repo, &argv_buf);
    // 경로는 **stdin** 으로 간다(`-z` 는 `--stdin` 과만 성립한다 — `git_command` 의 kind 주석).
    //
    // **필요한 만큼만 잡는다.** 처음에는 상한(64 KiB)을 통째로 잡았는데, 이 워커는 **디렉터리를 읽을
    // 때마다** 돈다 — 실제 페이로드는 항목 수에 비례해 보통 수백 바이트다(이 저장소 루트에서 199).
    // 상한은 「여기서 끊는다」는 **정책**이지 「여기까지 잡아 둔다」가 아니다.
    //
    // 그리고 이 크기는 **자르지 않는다** — 담을 때 이미 바이트 상한을 지켰으므로(`submitCheckIgnore`)
    // `job.ignore_paths` 는 통째로 들어간다. 여기서 다시 `@min` 을 걸면 「보낸 것」과 「물어본 것」이
    // 갈리는 자리가 되살아난다.
    var want: usize = 0;
    for (job.ignore_paths) |path| want += path.len + 1;
    const payload_buf: []u8 = state.allocator.alloc(u8, want) catch &.{};
    defer if (payload_buf.len > 0) state.allocator.free(payload_buf);
    const payload = git_command.checkIgnoreStdin(job.ignore_paths, payload_buf);
    if (payload.len > 0) {
        // **exit 1 은 「무시된 것이 없음」이다**(git 계약) — 실패가 아니라 **빈 답**이다. 그 구분을
        // 여기서 명시적으로 요구한다: 예전 주석은 「`runArgv` 가 그 구분을 준다」고 적었지만 그쪽은
        // `exit_code != 0` 을 전부 `GitFailed` 로 접고 있었다(적대적 검증 2026-09-14).
        if (runArgvCheckIgnore(state.allocator, argv, payload)) |out| {
            result.text = out.bytes;
            result.ok = true;
        } else |_| {}
    }

    // **물어본 목록을 답에 싣는다**(`IgnoreResult.asked` 주석). job 의 소유권을 그대로 넘긴다.
    result.asked = job.ignore_paths;
    job.ignore_paths = &.{};

    state.mutex.lockUncancelable(state.io);
    if (state.ignore_result) |*old| old.deinit(state.allocator);
    state.ignore_result = result;
    state.ignore_inflight -= 1;
    state.mutex.unlock(state.io);

    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    // **경로는 안 버린다 — 답에 실어 보냈다**(`IgnoreResult.asked`). 소유권이 result 로 넘어갔으므로
    // 여기서 풀면 소비자가 해제된 메모리를 읽는다.
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

/// 목록의 충돌 경로들에 시작 마커가 남았는지 `git grep` 으로 묻는다(S4). `conflict_markers_batch` 씩 끊어
/// 돌리고, 한 배치라도 실패하면 **판정 못 함**(`conflict_scan_ok = false`)으로 남긴다 — 반쪽 답으로 `+` 를
/// 내면 마커가 남은 파일이 스테이지된다.
fn scanConflictMarkers(allocator: std.mem.Allocator, job: *const Job, result: *Result) void {
    var paths: [git_command.conflict_markers_batch][]const u8 = undefined;
    var n: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = maru.session.git_status.iterate(result.status);
    var any = false;
    while (it.next()) |entry| {
        if (!entry.isConflicted()) continue;
        any = true;
        paths[n] = entry.path;
        n += 1;
        if (n == paths.len) {
            if (!runMarkersBatch(allocator, job, paths[0..n], &out)) return;
            n = 0;
        }
    }
    if (n > 0 and !runMarkersBatch(allocator, job, paths[0..n], &out)) return;
    if (any) result.conflict_markers = out.toOwnedSlice(allocator) catch return;
    result.conflict_scan_ok = true;
}

fn runMarkersBatch(allocator: std.mem.Allocator, job: *const Job, paths: []const []const u8, out: *std.ArrayList(u8)) bool {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const local = git_command.buildConflictMarkers(job.git_exe, job.repo, paths, &argv_buf) orelse return false;
    // **exit 1 은 「마커 없음」이다** — `check-ignore` 와 같은 계약이고 이 명령 하나에만 연다.
    const o = if (job.remoteTarget()) |target| blk: {
        var remote_buf: [git_command.max_argv][]const u8 = undefined;
        var cmd_buf: [git_command.max_remote_command_bytes]u8 = undefined;
        const argv = git_command.buildRemote(local, target, &remote_buf, &cmd_buf) orelse return false;
        break :blk runArgvWithEnv(allocator, argv, null, true, null, true) catch return false;
    } else runArgvWithEnv(allocator, local, null, false, null, true) catch return false;
    defer allocator.free(o.bytes);
    // ⚠️ **로컬 e2e 로 못 가르는 셋**(S4 적대적 2회차 B7·B8·B9): ① 이 잘림 가드 — 상한이 커서 경로 몇 개로는
    // 안 잘린다, ② 원격 갈래의 `empty_on_exit_1` — 원격 저장소가 판정자에 없다, ③ 비충돌 행을 grep 에
    // 넣어도 목록은 충돌 행만 조회하므로 답이 같다(비용만 는다). 셋 다 규칙으로 남긴다.
    if (o.truncated) return false; // 반쪽 목록으로는 답할 수 없다
    out.appendSlice(allocator, o.bytes) catch return false;
    return true;
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

    if (target.base == .merge_stages) {
        // **충돌 중의 세 판**(S3a). 평상시 index 에는 stage 0 하나뿐이고 충돌이 나면 그 자리에
        // 1·2·3 이 들어선다 — 그래서 이 갈래만 `:<n>:` 을 읽는다.
        //
        // **조상이 없는 것은 정상이다**(add/add — 양쪽이 같은 경로를 새로 만들었다). 루트 커밋의
        // 부모 blob 을 「왼쪽이 없다」로 읽는 것과 같은 판단이고, 실패로 접으면 그 충돌을 아예 못 연다.
        var stages: maru.session.editor.conflict.StageSet = .{};
        // **세 판을 한 자리에서 읽는다.** 갈래를 셋으로 풀어 두면 「잘렸다」를 옮기는 자리도 셋이 되고,
        // 그중 하나만 지운 변이는 **나머지 둘이 덮어 준다** — 픽스처가 세 판을 다 넘겨도 안 죽는다
        // (적대적 검증 3회차 W3·W3b 실측). 자리를 하나로 모으면 그 변이가 존재할 곳이 없다.
        const reads = [_]struct {
            side: git_command.BlobSide,
            dst: *[]u8,
            seen: *bool,
        }{
            // **내용이 비어도 조상은 조상이다** — 「읽혔나」는 길이가 아니라 이 자리가 답한다.
            .{ .side = .stage_base, .dst = &result.base, .seen = &stages.has_base },
            .{ .side = .stage_ours, .dst = &result.original, .seen = &stages.has_ours },
            .{ .side = .stage_theirs, .dst = &result.modified, .seen = &stages.has_theirs },
        };
        for (reads) |read| {
            if (blobSide(state.allocator, job, read.side)) |out| {
                read.dst.* = out.bytes;
                read.seen.* = true;
                if (out.truncated) truncated = true;
            } else |_| {}
        }
        // **판정은 중립이 소유한다**(`conflict.StageSet`) — 여기서 손으로 풀어 적으면 규칙을 쓰는 자리가
        // 둘이 되고, 한쪽만 바꾼 변이가 산다(적대적 검증 1회차 실측).
        result.stages = stages;
        // **조상이 없어도 연다**(`openable()`): add/add 충돌은 `:1:` 이 아예 없다. 여기에
        // `and stages.has_base` 를 더하면 그 충돌을 아예 못 열게 되고, 그 갈림은 실제 add/add 저장소가
        // 있어야만 보인다 — 그 하네스가 `makeStageRepo(.add_add)` 다(적대적 검증 3회차에서 사살).
        result.ok = stages.openable();
        result.truncated = truncated;
        finishDiff(state, job, target, result);
        return;
    }

    if (target.base != .untracked) {
        // 충돌은 왼쪽이 HEAD다 — index엔 stage 0이 없어 `:<경로>`가 실패한다(실측).
        const side: git_command.BlobSide = switch (target.base) {
            .staged, .conflict => .head,
            // `.commit`·`.turn_range`는 위에서 이미 돌려보냈다 — 여기 오면 그 자체가 버그다.
            .unstaged, .untracked, .commit, .turn_range, .merge_stages => .index,
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

/// `takeTurnSnapshot` 의 **원격판**(AT3c). 같은 세 단계를 `runOnWithIndex` 로 원격에서 돌린다 — `GIT_INDEX_FILE` 은
/// 원격 명령 문자열에 실리고(`git_command.buildRemoteWithIndex`), 그 경로는 원격 `/tmp` 의 파일이다.
///
/// 로컬과 다른 점 하나: `read-tree HEAD` 가 실패한 unborn 저장소에서 로컬은 index 파일을 `unlink` 하지만 원격에는
/// 그 손이 없다 — git 자신에게 `read-tree --empty` 로 비우게 한다. 그것도 실패하면(index 파일을 못 만드는 곳)
/// `add -A` 가 실패해 스냅샷이 없다고 드러난다 — 지난 턴의 항목이 섞인 스냅샷을 내지는 않는다.
pub fn takeTurnSnapshotRemote(
    allocator: std.mem.Allocator,
    remote: git_command.Remote,
    repo: []const u8,
    index_file: []const u8,
) ![]u8 {
    {
        const out = runOnWithIndex(allocator, remote, .snapshot_read_tree, repo, index_file) catch null;
        if (out) |ok| {
            allocator.free(ok.bytes);
        } else {
            const cleared = try runOnWithIndex(allocator, remote, .snapshot_read_tree_empty, repo, index_file);
            allocator.free(cleared.bytes);
        }
    }
    {
        const out = try runOnWithIndex(allocator, remote, .snapshot_add, repo, index_file);
        allocator.free(out.bytes);
    }
    const written = try runOnWithIndex(allocator, remote, .snapshot_write_tree, repo, index_file);
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

/// `runOn` + 원격 임시 index(AT3c). 원격 전용이다 — 로컬 index 는 `runWithEnv` 가 자식 env 로 건다.
fn runOnWithIndex(
    allocator: std.mem.Allocator,
    remote: git_command.Remote,
    kind: git_command.Kind,
    repo: []const u8,
    index_file: []const u8,
) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const local = git_command.build(kind, git_command.remote_git_exe, repo, null, &argv_buf);
    var remote_buf: [git_command.max_argv][]const u8 = undefined;
    var cmd_buf: [git_command.max_remote_command_bytes]u8 = undefined;
    const argv = git_command.buildRemoteWithIndex(local, remote, index_file, &remote_buf, &cmd_buf) orelse return error.GitFailed;
    return runArgvWithEnv(allocator, argv, null, true, null, false) catch |err| return mapRemoteExitError(err);
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
    // **이 읽기도 원격이다**(적대적 검증 1회차). `runOn` 만 배선하고 여기를 빼면, 소켓이 죽어 diff 가
    // 안 열려도 화면은 「읽지 못함」만 말한다 — 목록은 「연결이 끊겼다」라고 말하는데 diff 는 딴소리를
    // 하는 셈이라, 사용자는 둘 중 무엇을 믿을지 알 수 없다.
    const out = runArgvWithEnv(allocator, argv, null, true, null, false) catch |err| return mapRemoteExitError(err);
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
    var failure: ReadFailure = .generic;
    inline for (required_reads) |pair| {
        if (ok) {
            if (runOn(state.allocator, job.remoteTarget(), pair[0], job.git_exe, job.repo, null)) |o| {
                @field(result, pair[1]) = o.bytes;
                if (o.truncated) truncated = true;
            } else |err| {
                ok = false;
                // **왜 실패했는지 싣는다.** 「읽지 못함」 하나로 뭉개면 사용자는 원격에 git 을 깔아야
                // 하는지, 연결을 다시 붙여야 하는지 알 수 없다.
                failure = readFailureFor(err);
            }
        }
    }
    // **충돌 행의 마커 판정**(S4). 같은 왕복에 얹는다 — 따로 물으면 목록과 판정이 다른 순간의 것이 된다.
    if (ok) scanConflictMarkers(state.allocator, job, &result);
    result.ok = ok;
    result.failure = failure;
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
/// 원격 종료 코드를 **이야기**로 바꾼다. `runOn` 안에 인라인으로 두면 「git 없는 원격」을 만들지 않고는
/// 이 규칙을 셀 수 없다 — 그런 원격은 우리 기계에 만들 수 없다(`/usr/bin/git` 이 늘 있다). 그래서 뗐다.
///
/// **원격에서만 부른다.** 로컬 git 은 127·255 를 안 쓰고(fatal 은 128, 거절은 1), 쓴다면 그것은 git 이
/// 한 말이라 우리가 다시 해석하면 안 된다.
fn mapRemoteExitError(err: anyerror) anyerror {
    return switch (err) {
        error.ExitCommandNotFound => error.RemoteGitMissing, //   원격 PATH 에 git 이 없다
        error.ExitTransportFailed => error.RemoteTransportFailed, // 거기까지 못 갔다
        else => err,
    };
}

fn runOn(
    allocator: std.mem.Allocator,
    remote: ?git_command.Remote,
    kind: git_command.Kind,
    git_exe: []const u8,
    repo: []const u8,
    arg: ?[]const u8,
) !Output {
    // ⚠️ **`check-ignore` 는 이 길로 못 간다.** 그 명령은 경로를 **stdin** 으로 받는데 이 경로는
    // stdin 을 `/dev/null` 로 묶는다 — 그러면 원격 git 이 **빈 입력**을 읽고 「무시된 것이 없다」를
    // 정상 답으로 내놓는다. 실패가 아니라 **조용히 틀린 답**이고, 화면에는 「이 저장소엔 무시된 것이
    // 없다」로 보인다. 지금은 부르는 자리가 없지만(원격 탐색기는 흐림을 안 묻는다) 여기 kind 는
    // 런타임 값이라 **더해지는 순간 그 모양이 성립한다.**
    if (kind == .check_ignore) return error.CheckIgnoreNeedsStdin;
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const local = git_command.build(kind, git_exe, repo, arg, &argv_buf);
    const target = remote orelse return runArgvWithEnv(allocator, local, null, false, null, false);
    var remote_buf: [git_command.max_argv][]const u8 = undefined;
    var cmd_buf: [git_command.max_remote_command_bytes]u8 = undefined;
    const argv = git_command.buildRemote(local, target, &remote_buf, &cmd_buf) orelse return error.GitFailed;
    // **원격에서만 종료 코드를 이야기로 바꾼다.** 로컬 git 이 127·255 를 내는 일은 없고, 낸다면 그것은
    // git 이 한 말이라 우리가 다시 해석하면 안 된다.
    return runArgvWithEnv(allocator, argv, null, true, null, false) catch |err| return mapRemoteExitError(err);
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
    return runArgvWithEnv(allocator, argv_slices, index_file, false, null, false);
}

/// **argv 를 직접 받는 진입점.** `check-ignore` 는 경로가 argv 뒤에 붙어 kind 하나로 만들 수 없어
/// (`git_command.buildCheckIgnore`) 이 자리를 쓴다. 아래 본문은 원래 `runWithEnv` 의 것 그대로다 —
/// 실행 방식(fork+exec+pipe·환경 덮어쓰기·exit code 해석)을 두 벌로 만들지 않기 위해 갈랐다.
fn runArgv(allocator: std.mem.Allocator, argv_slices: []const []const u8) !Output {
    return runArgvWithEnv(allocator, argv_slices, null, false, null, false);
}

/// `check-ignore` 전용 진입점 — 경로를 stdin 으로 보내고, **exit 1 을 빈 답으로 받는다.**
///
/// 그 둘을 한 함수로 묶는 이유: 둘 다 **이 명령 하나의 계약**이라 다른 읽기에 새면 안 된다.
/// exit 1 을 일반 읽기에 열어 주면 「git 이 거부했다」가 조용히 빈 목록으로 보인다.
fn runArgvCheckIgnore(allocator: std.mem.Allocator, argv_slices: []const []const u8, stdin_bytes: []const u8) !Output {
    return runArgvWithEnv(allocator, argv_slices, null, false, stdin_bytes, true);
}

fn runArgvWithEnv(
    allocator: std.mem.Allocator,
    argv_slices: []const []const u8,
    index_file: ?[]const u8,
    /// **원격 명령일 때만 참.** 127·255 를 이름 있는 오류로 올릴지 정한다(RS4 §2.2 ⑺).
    ///
    /// ⚠️ **로컬에서 켜면 거짓말이 된다.** 우리 자식은 `execve` 가 실패하면 스스로 **127** 로 끝난다
    /// (셸 관례를 따른 것이다 — 아래 `_exit(127)`). 그 상태는 「원격에 git 이 없다」가 아니라
    /// 「로컬 git 을 못 띄웠다」이고, 화면에 「원격에 git 을 깔라」고 적으면 사용자는 엉뚱한 기계를
    /// 손본다. 그래서 로컬은 예전처럼 `GitFailed` 하나로 둔다(적대적 검증 1회차).
    remote_exit_codes: bool,
    /// 자식 stdin 으로 보낼 바이트(없으면 `/dev/null`). `check-ignore --stdin` 만 쓴다.
    stdin_bytes: ?[]const u8,
    /// **exit 1 을 「빈 답」으로 받을지.** `check-ignore` 만 참이다 — 그 명령은 「무시된 것이 없음」을
    /// 1 로 말한다(git 계약). 다른 읽기에 열어 주면 거부가 빈 목록으로 보인다.
    empty_on_exit_1: bool,
) !Output {
    // **Windows 는 `CreateProcessW` + 익명 파이프로 간다.** 아래 POSIX 갈래는 `fork`/`execve` 를 쓰는데
    // Windows 에는 없다(`std.c.fork` 가 그 타깃에서 `void` 라 분석되는 순간 컴파일이 깨진다). `comptime`
    // 분기라 **고른 쪽만 분석**되므로 두 갈래가 한 파일에 있어도 서로를 안 깨뜨린다.
    //
    // **POSIX 갈래는 한 줄도 안 건드린다.** 돌아가는 검증된 경로를 옮기지 않는 것이 이 배선의 전제다 —
    // 옮기면 검증할 수 없는 코드로 검증된 코드를 바꾸는 일이 된다(Windows 호스트에서는 POSIX 테스트를
    // 못 돌린다).
    if (comptime builtin.os.tag == .windows) return runArgvWithEnvWindows(allocator, argv_slices, index_file, remote_exit_codes, stdin_bytes, empty_on_exit_1);

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
    const spawned = try spawnCapture(allocator, &argv, env_ptrs.items.ptr, .stdout_only, stdin_bytes);
    defer allocator.free(spawned.stderr_bytes); // 읽기 경로에서는 항상 빈 슬라이스다
    errdefer allocator.free(spawned.stdout_bytes);
    // 상한에 걸렸는지는 길이로 판정한다 — 잘렸으면 목록 끝에 그 사실을 표시한다(조용히 일부만 보여 주지 않는다).
    const capped = spawned.stdout_bytes.len >= max_output_bytes;
    // ⚠️ **상한에서 끊었으면 종료 코드는 «우리가» 만든 것이다.** `readAllFd` 는 상한에서 읽기를 멈추고
    // 자식을 EPIPE 로 끊는데(그것이 이 파일의 의도다), 그러면 자식은 신호로 죽어 `reapPid` 가 -1 을
    // 준다. 그 값을 실패로 읽으면 **방금 받아 둔 잘린 내용을 통째로 버린다** — 게다가 자식이 우리보다
    // 먼저 다 써 버리면 0 이라, 같은 파일이 **운에 따라** 열리거나 안 열렸다(실측 2026-09-14: 16 MiB
    // 판을 읽는 판정자가 10 회 중 1 회 빨갰고, 그때 세 판 중 둘이 0 바이트로 왔다).
    if (!capped) {
        // **127·255 는 이름을 붙여 올린다**(RS4 §2.2 ⑺). 그 둘은 「git 이 거부했다」가 아니라 각각
        // 「명령을 못 찾았다」·「거기까지 못 갔다」다 — 상한에 닿은 읽기에는 해당이 없다.
        if (remote_exit_codes) {
            if (spawned.exit_code == 127) return error.ExitCommandNotFound;
            if (spawned.exit_code == 255) return error.ExitTransportFailed;
        }
        // **`check-ignore` 의 1 은 실패가 아니다**(위 인자 주석) — 「물어본 것 중 무시된 것이 없다」이고,
        // 그때 stdout 은 비어 있다. 그 구분이 없으면 무시 항목이 하나도 없는 디렉터리마다 답이 통째로
        // 버려져 「아직 안 물어본 상태」와 구별되지 않는다.
        //
        // **상한 갈래 안이 맞는 자리다**: 잘린 읽기의 종료 코드는 우리가 만든 것이라(위 주석) 거기서
        // 1 을 보고 「무시된 것이 없다」고 단정하면, 실은 **답이 잘린** 것을 빈 답이라고 말하게 된다.
        if (!(spawned.exit_code == 1 and empty_on_exit_1) and spawned.exit_code != 0) return error.GitFailed;
    }
    return .{ .bytes = spawned.stdout_bytes, .truncated = capped };
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
    /// POSIX 갈래와 같은 뜻 — 원격 명령일 때만 127·255 를 이름 있는 오류로 올린다.
    remote_exit_codes: bool,
    /// ⚠️ **이 갈래는 아직 stdin 을 안 보낸다.** 캡처 러너(`win32_process`)에 그 배관이 없다.
    /// 값이 오면 **명령을 만들지 않고 실패로 돌려준다** — `--stdin` 을 준 채 아무것도 안 보내면
    /// git 이 빈 입력을 읽고 「무시된 것 없음」을 내므로, 조용히 **틀린 답**이 된다.
    stdin_bytes: ?[]const u8,
    /// POSIX 갈래와 같은 뜻 — `check-ignore` 의 exit 1 을 빈 답으로 받는다.
    empty_on_exit_1: bool,
) !Output {
    if (stdin_bytes != null) return error.GitFailed;
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
    if (remote_exit_codes) { // POSIX 갈래와 같은 판정
        if (result.exit_code == 127) return error.ExitCommandNotFound;
        if (result.exit_code == 255) return error.ExitTransportFailed;
    }
    if (result.exit_code == 1 and empty_on_exit_1) return .{ .bytes = result.bytes, .truncated = false };
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

    /// 원격 PATH 에 `git` 이 없다(127). **읽기와 같은 말을 해야 한다**(적대적 검증 3회차) — 목록은
    /// 「원격에 git 이 없습니다」라고 하는데 스테이지는 셸이 뱉은 `sh: git: command not found` 를 그대로
    /// 보여 주면, 사용자는 두 화면이 **다른 문제**를 말한다고 읽는다.
    ///
    /// 로컬은 이 판정을 안 받는다 — 우리 자식은 `execve` 실패에도 127 을 내므로(그쪽은 「로컬 git 을
    /// 못 띄웠다」이지 원격 이야기가 아니다).
    pub fn remoteGitMissing(self: WriteResult) bool {
        return self.remote and self.spawned and self.exit_code == 127;
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

test "읽기 실패 사유는 한 규칙에서 나온다 (RS7d)" {
    // 목록·히스토리·커밋 파일 목록이 **같은 함수**를 부른다. 사본이 갈리면 한쪽만 새 사유를 배우고,
    // 그 화면만 「읽지 못했습니다」로 뭉개진다 — 이 저장소가 반복해서 당한 모양이다.
    try testing.expectEqual(ReadFailure.remote_git_missing, readFailureFor(error.RemoteGitMissing));
    try testing.expectEqual(ReadFailure.remote_transport, readFailureFor(error.RemoteTransportFailed));
    // **분류 못 하는 것은 분류하지 않는다** — git 이 한 말(128·1)을 우리가 다시 해석하면 안 된다.
    try testing.expectEqual(ReadFailure.generic, readFailureFor(error.GitFailed));
    try testing.expectEqual(ReadFailure.generic, readFailureFor(error.OutOfMemory));
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

/// 판정자 전용: **세 판이 든 충돌 저장소**를 만든다(성공하면 true).
///
/// 이 파일에 이미 있는 `makeConflictRepo` 는 **내용 충돌 하나**만 만든다. 여기서는 축이 하나 더 있다:
/// `add_add` 가 참이면 양쪽이 **같은 경로를 새로** 만들어 **공통 조상이 없는** 충돌이 된다 — 그때
/// index 에는 `:1:` 이 아예 안 실린다(실제 git 으로 확인했다).
///
/// 이 하네스가 없던 동안 워커의 세 판 배선이 **통째로 무판정**이었다(적대적 검증 2회차: 조상을 현재
/// 것 자리에 싣는 변이, 안전 경로 검사를 지운 변이 따위가 여섯이 살아남았다).
/// 세 판 픽스처의 **축**. 조상이 어떤 모양인가로 갈린다 — 이 셋이 `StageSet` 의 세 갈래를 각각 연다.
const StageFixture = enum {
    /// 흔한 내용 충돌 — 세 판이 다 있다.
    content,
    /// 양쪽이 같은 경로를 **새로** 만들었다 — `:1:` 이 아예 없다(실측: `ls-files -u` 에 2·3 만 뜬다).
    add_add,
    /// 조상이 **빈 파일**이다 — `:1:` 은 있고 내용이 0 바이트다(실측: 빈 blob `e69de29`).
    /// 「없는 것」과 「빈 것」을 길이로 가르면 이 경우가 2-way 로 잘못 저하한다.
    empty_base,
};

fn makeStageRepo(exe: []const u8, repo: []const u8, fixture: StageFixture) bool {
    const steps = [_][]const []const u8{
        &.{ exe, "init", "-q", "-b", "main", repo },
        &.{ exe, "-C", repo, "config", "user.email", "t@t" },
        &.{ exe, "-C", repo, "config", "user.name", "t" },
    };
    for (steps) |argv| {
        if (!runQuiet(argv)) return false;
    }

    switch (fixture) {
        .add_add => {
            // 씨앗만 공통이고 `f.txt` 는 양쪽에서 **새로** 생긴다 — 조상이 없다.
            writeFileAt(repo, "seed.txt", "seed\n") catch return false;
            if (!runQuiet(&.{ exe, "-C", repo, "add", "seed.txt" })) return false;
            if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "seed" })) return false;
            if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "-b", "other" })) return false;
            writeFileAt(repo, "f.txt", "theirs only\n") catch return false;
        },
        .content, .empty_base => {
            writeFileAt(repo, "f.txt", if (fixture == .empty_base) "" else "BASE\n") catch return false;
            if (!runQuiet(&.{ exe, "-C", repo, "add", "f.txt" })) return false;
            if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "base" })) return false;
            if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "-b", "other" })) return false;
            writeFileAt(repo, "f.txt", "THEIRS\n") catch return false;
        },
    }
    if (!runQuiet(&.{ exe, "-C", repo, "add", "f.txt" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "theirs" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "main" })) return false;
    writeFileAt(repo, "f.txt", "OURS\n") catch return false;
    if (!runQuiet(&.{ exe, "-C", repo, "add", "f.txt" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "ours" })) return false;
    // 이 merge 는 **실패해야** 충돌 상태가 된다 — 성공하면 이 픽스처의 전제가 깨진 것이다.
    return !runQuiet(&.{ exe, "-C", repo, "merge", "other" });
}

/// 판정자 전용: `.zig-cache` 밑 임시 저장소 경로. `std.testing.tmpDir` 는 0.16 에서 realpath 를 안 주므로
/// (이 파일의 앞선 판정자가 이미 그렇게 적어 두었다) 경로를 직접 만든다.
fn tmpRepoPath(buf: []u8, name: []const u8) ?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return null;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    return std.fmt.bufPrint(buf, "{s}/.zig-cache/{s}", .{ cwd, name }) catch null;
}

test "진짜 충돌에서 세 판을 읽는다 — :1:·:2:·:3: (S3a end-to-end)" {
    // **성공 경로다.** 아래 실패 판정자는 세 판이 **다 없을** 때만 보므로, 「어느 판이 어느 자리에 실리나」가
    // 통째로 무판정이었다(적대적 검증 2회차에서 여섯이 살아남았다).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = tmpRepoPath(&repo_buf, "tmp-merge-stages") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!makeStageRepo(exe, repo, .content)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", "", .merge_stages, 11, null, ""));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);

    try testing.expect(result.ok);
    // **자리가 뜻이다**: `:1:` 조상 · `:2:` 현재 것 · `:3:` 들어온 것. 뒤바뀌면 pane 이 남의 것을 띄운다.
    try testing.expect(result.stages.has_base);
    try testing.expect(result.stages.has_ours);
    try testing.expect(result.stages.has_theirs);
    try testing.expectEqualStrings("BASE\n", result.base);
    try testing.expectEqualStrings("OURS\n", result.original);
    try testing.expectEqualStrings("THEIRS\n", result.modified);
    try testing.expect(!result.stages.degradesToTwoWay());
    try testing.expect(!result.truncated);
    try testing.expectEqual(@as(u64, 11), result.request_id);

    // **rename 의 옛 경로는 stage 에 안 쓴다.** 왼쪽이 HEAD 인 기준에서는 옛 경로로 읽어야 blob 이
    // 잡히지만(그쪽 규칙이다), 충돌 stage 는 **지금 경로**에 실린다 — 옛 경로로 읽으면 세 판이 전부
    // 안 잡혀 충돌을 못 연다. 여기서는 index 에 없는 옛 경로를 일부러 실어 그 갈림을 드러낸다.
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "gone.txt", "", "", .merge_stages, 15, null, ""));
    var renamed = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer renamed.deinit(worker_allocator);
    try testing.expect(renamed.ok);
    try testing.expectEqualStrings("OURS\n", renamed.original);
    try testing.expectEqualStrings("BASE\n", renamed.base);

    // **저장소 밖으로 나가는 경로는 결과로 실패한다.**
    //
    // 정직하게: 이 판정자는 `repo_path.isSafeRelative` 가 **도는지**는 못 가른다 — 실측(2026-09-14)에서
    // git 자신이 먼저 거절한다(`git show :1:../f.txt` → `fatal: '../f.txt' is outside repository`,
    // `:1:a/../f.txt` → `does not exist`). 즉 그 방어를 지운 변이는 이 갈래에서 **등가**다. 방어는
    // 그대로 둔다(git 이 거절하는 것에 기대는 것보다 우리가 안 보내는 편이 낫다). 여기서 재는 것은
    // 「깨끗하게 실패하고 결과가 **한 번** 도착한다」 — 그것이 화면을 「여는 중」에서 풀어 준다.
    try testing.expect(backend.submitDiff(exe, repo, "../escape.txt", "", "", "", .merge_stages, 12, null, ""));
    var escaped = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer escaped.deinit(worker_allocator);
    try testing.expect(!escaped.ok);
    try testing.expectEqual(@as(usize, 0), escaped.base.len);
}

test "조상이 «빈 파일»이어도 3-way 다 — 길이로 가르지 않는다 (S3a end-to-end)" {
    // `:1:` 이 **없는 것**(add/add)과 **비어 있는 것**은 다르다. 길이로 가르면 빈 조상이 「없음」으로
    // 읽혀 3-way 가 근거 없이 2-way 로 저하한다 — 실측으로 stage 1 은 빈 blob(`e69de29`)으로 실린다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = tmpRepoPath(&repo_buf, "tmp-merge-stages-empty") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!makeStageRepo(exe, repo, .empty_base)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", "", .merge_stages, 16, null, ""));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);

    try testing.expect(result.ok);
    try testing.expectEqual(@as(usize, 0), result.base.len); // 내용은 비었고
    try testing.expect(result.stages.has_base); // **그래도 조상은 있다**
    try testing.expect(!result.stages.degradesToTwoWay()); // 그러므로 3-way 를 유지한다
}

test "상한을 넘는 판은 «잘린 채로» 도착한다 (S3a end-to-end)" {
    // 상한(16 MiB)을 넘는 판은 **잘라서 싣고 잘렸다고 말한다**. 잘림 표시를 안 싣는 변이는 화면이
    // 「이게 전부」라고 거짓말하게 만드는데, 상한을 넘는 픽스처가 없으면 그 변이가 산다(적대적 검증
    // 2회차 W3·W10 — 둘 다 살아남았다).
    //
    // **대조군은 바로 위 판정자다**(작은 저장소 → `truncated == false`). 여기만 있으면 `truncated` 를
    // 항상 참으로 두는 변이가 산다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = tmpRepoPath(&repo_buf, "tmp-merge-stages-big") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });

    // 한 줄짜리 거대 파일이다 — 줄이 하나뿐이라 git 의 병합은 세 판을 **통째로** 충돌로 보고,
    // 16 MiB 를 줄 단위로 훑는 비용이 들지 않는다.
    // **여유가 파이프 버퍼보다 훨씬 커야 한다.** 상한에 「딱 몇 바이트」만 더한 파일로 재면, 우리가
    // 읽기를 멈추는 순간 git 이 **이미 다 쓰고 끝나 있을 수** 있어 종료 코드가 0 으로 온다 — 그러면
    // 이 판정자가 **10 회 중 9 회만** 빨간, 재는 쪽이 흔들리는 자가 된다(실측 2026-09-14). 1 MiB 를
    // 더해 두면 파이프 버퍼(64 KiB)에 다 안 들어가 자식이 반드시 write 에서 살아 있다.
    const big = testing.allocator.alloc(u8, max_output_bytes + (1 << 20)) catch return error.SkipZigTest;
    defer testing.allocator.free(big);
    @memset(big, 'a');
    big[big.len - 1] = '\n';
    // **앞머리를 다르게 둔다** — 잘림은 꼬리를 먹으므로, 뒤에 두면 어느 판인지 확인할 수 없다.
    if (!makeBigStageRepo(exe, repo, big)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", "", .merge_stages, 14, null, ""));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);

    try testing.expect(result.ok);
    try testing.expect(result.truncated); // ← W3·W10 이 여기서 죽는다
    // **상한은 «메모리 한계»다** — 넘겨 받으면 잘렸다고 말해도 소용없다(그만큼 들고 있는 것이 문제다).
    try testing.expect(result.base.len <= max_output_bytes);
    try testing.expect(result.original.len <= max_output_bytes);
    try testing.expect(result.modified.len <= max_output_bytes);
    // 잘려도 **자리는 지킨다**: 앞머리가 곧 어느 판인지의 증거다.
    try testing.expect(std.mem.startsWith(u8, result.base, "BASE"));
    try testing.expect(std.mem.startsWith(u8, result.original, "OURS"));
    try testing.expect(std.mem.startsWith(u8, result.modified, "THRS"));
}

/// 위 판정자 전용: 세 판이 **전부 상한을 넘는** 충돌 저장소. `big` 은 호출자가 쥔 스크래치다(16 MiB 를
/// 세 번 따로 잡지 않는다) — 앞 4 바이트만 갈아 끼워 세 판을 만든다.
fn makeBigStageRepo(exe: []const u8, repo: []const u8, big: []u8) bool {
    const steps = [_][]const []const u8{
        &.{ exe, "init", "-q", "-b", "main", repo },
        &.{ exe, "-C", repo, "config", "user.email", "t@t" },
        &.{ exe, "-C", repo, "config", "user.name", "t" },
    };
    for (steps) |argv| {
        if (!runQuiet(argv)) return false;
    }
    const write = struct {
        fn f(dir: []const u8, buf: []u8, tag: []const u8) bool {
            @memcpy(buf[0..4], tag);
            writeFileAt(dir, "f.txt", buf) catch return false;
            return true;
        }
    }.f;

    if (!write(repo, big, "BASE")) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "add", "f.txt" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "base" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "-b", "other" })) return false;
    if (!write(repo, big, "THRS")) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "theirs" })) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "main" })) return false;
    if (!write(repo, big, "OURS")) return false;
    if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "ours" })) return false;
    return !runQuiet(&.{ exe, "-C", repo, "merge", "other" });
}

test "add/add 충돌에는 조상이 «없다» — 2-way 로 저하한다 (S3a end-to-end)" {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;

    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = tmpRepoPath(&repo_buf, "tmp-merge-stages-addadd") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!makeStageRepo(exe, repo, .add_add)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submitDiff(exe, repo, "f.txt", "", "", "", .merge_stages, 13, null, ""));
    var result = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer result.deinit(worker_allocator);

    // **조상이 없어도 «연다».** 실패로 접으면 add/add 충돌은 아예 못 고친다 — 이것이 `openable()` 의 값이다.
    try testing.expect(result.ok);
    try testing.expect(!result.stages.has_base);
    try testing.expect(result.stages.has_ours);
    try testing.expect(result.stages.has_theirs);
    try testing.expect(result.stages.degradesToTwoWay());
    try testing.expectEqual(@as(usize, 0), result.base.len);
    try testing.expectEqualStrings("OURS\n", result.original);
    try testing.expectEqualStrings("theirs only\n", result.modified);
}

test "충돌이 «아닌» 파일에 3-way 를 걸면 깨끗하게 실패한다 (S3a end-to-end)" {
    // **성공 경로는 여기서 못 잰다** — 충돌 중인 저장소가 있어야 하고, 이 저장소에는 그것을 만드는
    // 하네스가 없다(쓰기 명령 어휘가 `init`·`merge` 를 **일부러** 안 갖는다 — 닫힌 어휘가 그 모듈의
    // 계약이다). 그 대신 성공 경로는 실제 `git merge` 로 손 확인했고 PR 에 적었다.
    //
    // **여기서 재는 것은 실패의 «모양»이다**: 평상시 index 에는 stage 0 하나뿐이라 `:1:`·`:2:`·`:3:`
    // 이 전부 없다. 그때 in-flight 가 풀리고 결과가 **한 번** 도착해야 화면이 「여는 중」에 안 갇힌다
    // (같은 규율을 「없는 경로」 판정자가 이미 적어 두었다).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&repo_buf, repo_buf.len) orelse return error.NoCwd;
    const repo = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", "", .merge_stages, 7, null, ""));
    const got = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    var result = got;
    defer result.deinit(worker_allocator);
    // 충돌이 아니므로 세 판이 다 없다 — **실패를 결과로 싣는다**(크래시도, 영영 pending 도 아니다).
    try testing.expect(!result.ok);
    try testing.expect(!result.stages.has_base);
    try testing.expect(result.stages.degradesToTwoWay()); // 조상이 없으니 2-way 다
    try testing.expectEqual(@as(usize, 0), result.original.len);
    try testing.expectEqual(@as(usize, 0), result.modified.len);
    try testing.expectEqual(@as(usize, 0), result.base.len);
    try testing.expectEqual(@as(u64, 7), result.request_id);

    // **다음 요청을 받는다** — in-flight 가 풀렸다는 뜻이다(안 풀리면 그 자리에서 화면이 멈춘다).
    try testing.expect(backend.submitDiff(exe, repo, "build.zig", "", "", "", .staged, 8, null, ""));
    var next = waitForDiff(&backend) orelse return error.DiffNeverCompleted;
    defer next.deinit(worker_allocator);
    try testing.expect(next.ok);
}

test "DiffResult 는 세 판을 «전부» 놓는다 — 누수 (S3a end-to-end 그래프)" {
    // **backend 의 end-to-end 판정자는 `worker_allocator` 를 쓴다** — 누수 검사가 없다. 그래서 조상
    // 바이트를 안 놓는 변이가 그쪽에서는 살아남는다(적대적 검증 1회차). 여기서는 `testing.allocator`
    // 로 잡아 놓게 해서, 빠뜨린 `free` 가 곧 빨간 줄이 되게 한다.
    const allocator = testing.allocator;
    var result: DiffResult = .{
        .original = try allocator.dupe(u8, "ours"),
        .modified = try allocator.dupe(u8, "theirs"),
        .base = try allocator.dupe(u8, "base"),
        .stages = .{ .has_base = true, .has_ours = true, .has_theirs = true },
        .ok = true,
    };
    result.deinit(allocator);
    // 비운 뒤에는 판정도 초기값이다 — 남아 있으면 다음 요청이 옛 저하 판정을 물려받는다.
    try testing.expect(!result.stages.has_base);
    try testing.expectEqual(@as(usize, 0), result.base.len);
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

test "실제 충돌 저장소: 마커가 남은 동안은 «남음», 지우면 «없음» — 그리고 git 은 여전히 UU 다 (S4 end-to-end)" {
    // 목록 한 벌에 실린 마커 판정(`git grep -l -z`)이 **진짜 git** 에서 도는지 본다. 판정의 두 갈래(남음/없음)와
    // 「판정을 했다」 표시, 그리고 이 조각의 전제 — 해결해도 상태 문자가 안 바뀐다 — 를 한 저장소에서 잰다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-conflict-markers", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!makeConflictRepo(exe, repo)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();

    // ⑴ 마커가 남은 상태: 판정을 했고, f.txt 가 목록에 있다.
    try testing.expect(backend.submit(exe, repo, "", 1, null));
    var before = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer before.deinit(worker_allocator);
    try testing.expect(before.ok);
    try testing.expect(before.conflict_scan_ok);
    try testing.expect(std.mem.indexOf(u8, before.conflict_markers, "f.txt\x00") != null);
    try testing.expect(std.mem.indexOf(u8, before.status, "u UU") != null);

    // ⑵ 마커를 지우고 저장한다(편집기 밖에서 해결한 것과 같다) → 목록은 비고, 판정은 했고, git 은 여전히 UU 다.
    //    **여덟 개짜리 `<<<<<<<<` 는 마커가 아니다**(`markerOf` 와 같은 규칙 — 정확히 일곱 자 + 공백/줄 끝).
    //    패턴에서 `( |$)` 를 떼면 이 줄이 걸려 해결한 파일이 영영 `→` 다(적대적 2회차 B5).
    try writeFileAt(repo, "f.txt", "<<<<<<<< not a marker\nresolved\n");
    try testing.expect(backend.submit(exe, repo, "", 2, null));
    var after = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer after.deinit(worker_allocator);
    try testing.expect(after.ok);
    try testing.expect(after.conflict_scan_ok);
    try testing.expectEqual(@as(usize, 0), after.conflict_markers.len);
    try testing.expect(std.mem.indexOf(u8, after.status, "u UU") != null); // 전제: add 전까지 UU

    // ⑶ 그 결과로 모델을 세우면 그 행의 동작이 `+` 다 — 그리고 ⑴ 의 결과로는 `→` 다.
    var rows: [16]maru.session.scm_view.Row = undefined;
    var scratch: [512]u8 = undefined;
    const sc = maru.session.scm_view.section_count;
    const m_after = maru.session.scm_view.buildWithMarkers(after.status, after.conflict_markers, "", "", "", .{false} ** sc, .{true} ** sc, false, &rows, &scratch);
    try testing.expectEqual(maru.session.scm_view.RowAction.stage, m_after.rows[1].file.action);
    const m_before = maru.session.scm_view.buildWithMarkers(before.status, before.conflict_markers, "", "", "", .{false} ** sc, .{true} ** sc, false, &rows, &scratch);
    try testing.expectEqual(maru.session.scm_view.RowAction.resolve, m_before.rows[1].file.action);
}

test "실제 충돌 저장소: 배치보다 많은 충돌 파일 — 한 배치도 빠뜨리지 않고, 해결한 것만 빠진다 (S4 end-to-end)" {
    // `git grep` 은 경로를 `conflict_markers_batch` 개씩 끊어 돌린다. 둘째 배치를 안 돌리거나 꼬리를 흘리면
    // 그 파일들은 「마커 없음」으로 읽혀 **마커가 남은 파일에 `+` 가 선다** — 이 조각이 막아야 하는 바로 그 사고다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-conflict-markers-many", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    const n = git_command.conflict_markers_batch + 3; // 두 배치 + 꼬리
    if (!makeManyConflictRepo(exe, repo, n)) return error.SkipZigTest;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submit(exe, repo, "", 1, null));
    var before = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer before.deinit(worker_allocator);
    try testing.expect(before.ok and before.conflict_scan_ok);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "c{d}.txt\x00", .{i});
        try testing.expect(std.mem.indexOf(u8, before.conflict_markers, name) != null);
    }

    // 앞 셋과 맨 끝을 해결한다 → 그 넷만 목록에서 빠진다.
    for ([_]usize{ 0, 1, 2, n - 1 }) |k| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "c{d}.txt", .{k});
        try writeFileAt(repo, name, "resolved\n");
    }
    try testing.expect(backend.submit(exe, repo, "", 2, null));
    var after = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer after.deinit(worker_allocator);
    try testing.expect(after.ok and after.conflict_scan_ok);
    i = 0;
    while (i < n) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "c{d}.txt\x00", .{i});
        const resolved = (i <= 2) or (i == n - 1);
        try testing.expectEqual(!resolved, std.mem.indexOf(u8, after.conflict_markers, name) != null);
    }
}

test "실제 충돌 저장소: grep 이 실패하면 «판정 못 함» — 충돌 행은 전부 → 로 남는다 (S4 end-to-end)" {
    // 「판정 못 함」과 「전부 해결됨」은 다른 상태다. 배치 하나가 실패했는데 «했다» 고 적으면 빈 목록이
    // 「전부 해결됨」으로 읽혀 마커가 남은 파일에 `+` 가 선다(적대적 2회차 B2 — 진짜 git 은 안 실패해서
    // 못 갈렸다). `grep` 만 실패시키고 나머지는 진짜 git 에 위임하는 래퍼로 그 갈래를 연다.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "{s}/.zig-cache/tmp-conflict-markers-fail", .{cwd}) catch return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = runQuiet(&.{ "/bin/rm", "-rf", rm_path });
    // **배치보다 많은 충돌 파일로** — 첫 배치(꽉 찬 것)의 실패와 꼬리 배치의 실패는 다른 줄이라 둘 다 지나야
    // 한다(적대적 3회차 C3: 충돌 하나짜리 픽스처는 꼬리 줄만 지났다).
    if (!makeManyConflictRepo(exe, repo, git_command.conflict_markers_batch + 3)) return error.SkipZigTest;

    // 래퍼: 인자에 `c0.txt` 가 있으면(= **첫 배치**) 2 로 죽고, 아니면 진짜 git 으로 넘긴다 — 꼬리 배치는
    // 성공하게 두어야 「첫 배치의 실패를 삼키고 꼬리만 보고 «했다»」는 변이가 갈린다(적대적 4회차 D1: 모든
    // grep 을 죽이면 꼬리 줄이 먼저 실패해 그 변이가 살았다). `-C <repo>`·`-c k=v` 가 앞에 오므로 「첫
    // 비옵션 인자」로는 못 가른다(실측).
    var script_buf: [1024]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf,
        \\#!/bin/sh
        \\for a in "$@"; do
        \\  [ "$a" = c0.txt ] && exit 2
        \\done
        \\exec "{s}" "$@"
        \\
    , .{exe});
    try writeFileAt(repo, "fake-git.sh", script);
    var wrapper_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wrapper = try std.fmt.bufPrintZ(&wrapper_buf, "{s}/fake-git.sh", .{repo});
    if (std.c.chmod(wrapper.ptr, 0o755) != 0) return error.ChmodFailed;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try testing.expect(backend.submit(wrapper, repo, "", 1, null));
    var r = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer r.deinit(worker_allocator);
    try testing.expect(r.ok); // 목록 자체는 섰다 — 판정만 못 했다
    try testing.expect(!r.conflict_scan_ok);
    var rows: [16]maru.session.scm_view.Row = undefined;
    var scratch: [512]u8 = undefined;
    const sc = maru.session.scm_view.section_count;
    const m = maru.session.scm_view.buildWithMarkers(r.status, if (r.conflict_scan_ok) r.conflict_markers else null, "", "", "", .{false} ** sc, .{true} ** sc, false, &rows, &scratch);
    try testing.expectEqual(maru.session.scm_view.RowAction.resolve, m.rows[1].file.action);

    // **꼬리 배치만 실패해도** 같다(적대적 5회차 E2 — 첫 배치만 죽이는 래퍼로는 꼬리 줄이 안 갈렸다).
    const n = git_command.conflict_markers_batch + 3;
    var last_buf: [32]u8 = undefined;
    const last = try std.fmt.bufPrint(&last_buf, "c{d}.txt", .{n - 1});
    const script2 = try std.fmt.bufPrint(&script_buf,
        \\#!/bin/sh
        \\for a in "$@"; do
        \\  [ "$a" = {s} ] && exit 2
        \\done
        \\exec "{s}" "$@"
        \\
    , .{ last, exe });
    try writeFileAt(repo, "fake-git.sh", script2);
    try testing.expect(backend.submit(wrapper, repo, "", 2, null));
    var r2 = waitForList(&backend) orelse return error.ListNeverCompleted;
    defer r2.deinit(worker_allocator);
    try testing.expect(r2.ok);
    try testing.expect(!r2.conflict_scan_ok);
}

/// `n` 개 파일이 전부 충돌한 저장소(S4 배치 판정자용).
fn makeManyConflictRepo(exe: []const u8, repo: []const u8, n: usize) bool {
    const steps = [_][]const []const u8{
        &.{ exe, "init", "-q", "-b", "main", repo },
        &.{ exe, "-C", repo, "config", "user.email", "t@t" },
        &.{ exe, "-C", repo, "config", "user.name", "t" },
    };
    for (steps) |argv| {
        if (!runQuiet(argv)) return false;
    }
    const Side = enum { base, other, main };
    inline for (.{ Side.base, Side.other, Side.main }) |side| {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "c{d}.txt", .{i}) catch return false;
            const content = switch (side) {
                .base => "line1\nline2\n",
                .other => "line1\nOTHER\n",
                .main => "line1\nMAIN\n",
            };
            writeFileAt(repo, name, content) catch return false;
        }
        switch (side) {
            .base => {
                if (!runQuiet(&.{ exe, "-C", repo, "add", "-A" })) return false;
                if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qm", "base" })) return false;
                if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "-b", "other" })) return false;
            },
            .other => {
                if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "other" })) return false;
                if (!runQuiet(&.{ exe, "-C", repo, "checkout", "-q", "main" })) return false;
            },
            .main => {
                if (!runQuiet(&.{ exe, "-C", repo, "commit", "-qam", "main" })) return false;
            },
        }
    }
    return !runQuiet(&.{ exe, "-C", repo, "merge", "other" });
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
/// **판정자 전용 하네스를 이 파일 밖으로 연다.** 병합 모드(S3b-1)의 끝에서 끝까지 판정자는 **진짜
/// 충돌 저장소**가 있어야 「어느 기준으로 무엇을 읽었나」를 잴 수 있는데, 그 저장소를 만드는 어휘는
/// 여기에만 있다(제품의 git 쓰기 어휘는 `init`·`merge` 를 일부러 안 갖는다). 위 둘과 같은 규율이다.
pub const testMakeStageRepo = makeStageRepo;
pub const testWriteFileAt = writeFileAt;

/// 판정자용 — 그 저장소의 `status --porcelain=v2` 원문(끝 NUL 없이). 실패하면 `null`.
pub fn testGitStatusLines(exe: []const u8, repo: []const u8, out: []u8) ?[]const u8 {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.build(.status, exe, repo, null, &argv_buf);
    const o = runArgv(std.heap.page_allocator, argv) catch return null;
    defer std.heap.page_allocator.free(o.bytes);
    const n = @min(o.bytes.len, out.len);
    @memcpy(out[0..n], o.bytes[0..n]);
    return out[0..n];
}
pub const testTmpRepoPath = tmpRepoPath;
pub const TestStageFixture = StageFixture;

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
        // **사용자의 전역 무시 목록도 끊는다**(`initRepoForTest` 주석 — 같은 이유). 실측으로
        // 전역 `core.excludesFile` 하나가 이 파일의 쓰기 판정자 넷을 함께 빨갛게 만들었다.
        try self.plainGit(allocator, &.{ "config", "core.excludesFile", "" });
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
    try std.testing.expect(!backend.submitCommitFiles("/usr/bin/git", "/repo", "--upload-pack=evil", 1, null));
    try std.testing.expect(!backend.submitCommitFiles("/usr/bin/git", "/repo", "HEAD", 2, null));
    _ = allocator;
}

test "파일 목록 읽기는 hex가 아닌 rev를 거절한다(커밋·턴 둘 다) (P5)" {
    var backend = try Backend.init(fixture_io);
    defer backend.deinit();
    const good = "650a0bbef96a1dd562e0d39f262260ae002c1545";
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", "HEAD HEAD~1", 1, null));
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", good ++ " --upload-pack=x", 2, null));
    // 셋 이상도 거절한다 — 인자가 하나 더 붙는 길을 열지 않는다.
    try std.testing.expect(!backend.submitTurnFiles("/usr/bin/git", "/repo", good ++ " " ++ good ++ " " ++ good, 3, null));
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
        try std.testing.expect(!refused.remoteGitMissing());
    }

    // **원격에 git 이 없는 것도 이름으로 말한다**(적대적 검증 3회차) — 목록과 쓰기가 같은 말을 해야
    // 사용자가 두 화면을 한 문제로 읽는다.
    var no_git = died;
    no_git.exit_code = 127;
    try std.testing.expect(no_git.remoteGitMissing());
    try std.testing.expect(!no_git.transportFailed());
    // **로컬의 127 은 우리 자식의 `execve` 실패다** — 원격 이야기로 바꾸면 엉뚱한 기계를 손보게 한다.
    var local_127 = no_git;
    local_127.remote = false;
    try std.testing.expect(!local_127.remoteGitMissing());
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

test "바이트 상한에 걸려 못 보낸 경로는 «물어본 목록»에도 없다" {
    // **적대적 검증 16 회차(2026-09-14).** 개수 상한(512)만 보고 전부 담았는데, 실제로 나가는 것은
    // stdin 페이로드라 **바이트 상한(64 KiB)에서 잘린다.** 그러면 `asked` 에는 **보낸 적 없는
    // 경로**가 섞이고, 드레인이 그 행들의 표시를 지운다 — 아무도 안 물어봤는데 흐림이 풀린다.
    //
    // 경로가 길고 항목이 많은 **깊은 디렉터리**에서 실제로 닿는다: 512 × 128 B 면 이미 넘는다.
    // 「물어본 것」과 「보낸 것」이 갈리면 한쪽이 낡는다 — 담는 자리에서 하나로 만들었고, 여기서 센다.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_len = tmp.dir.realPath(io, &repo_buf) catch return error.SkipZigTest;
    const repo = repo_buf[0..repo_len];
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = locate(&exe_buf) orelse return error.SkipZigTest;
    if (!initRepoForTest(allocator, git_exe, repo)) return error.SkipZigTest;

    // 경로 하나가 200 B — 512 개면 약 102 KiB 라 64 KiB 상한을 확실히 넘는다.
    const one_len: usize = 200;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var i: usize = 0;
    while (i < git_command.check_ignore_batch) : (i += 1) {
        const off = names.items.len;
        var one: [256]u8 = undefined;
        @memset(one[0..one_len], 'p');
        _ = try std.fmt.bufPrint(one[0..8], "{d:0>8}", .{i}); // 서로 다른 이름
        try names.appendSlice(allocator, one[0..one_len]);
        try paths.append(allocator, names.items[off..][0..one_len]);
    }
    // **모으는 동안 자란 버퍼**라 슬라이스가 밀렸다 — 오프셋으로 다시 만든다(그 함정은 8 회차에서 봤다).
    for (paths.items, 0..) |*slot, n| slot.* = names.items[n * one_len ..][0..one_len];

    var backend = try Backend.init(io);
    defer backend.deinit();
    try std.testing.expect(backend.submitCheckIgnore(git_exe, repo, paths.items, 11));

    var taken: ?IgnoreResult = null;
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        taken = backend.takeIgnoreResult();
        if (taken != null) break;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    var res = taken orelse return error.IgnoreReadNeverCompleted;
    defer res.deinit(worker_allocator);

    try std.testing.expect(res.ok); // 잘렸어도 **명령 자체는 성공**해야 한다
    // ⑴ 전부는 못 갔다 — 전제(이 판정자가 상한에 실제로 닿았나).
    try std.testing.expect(res.asked.len < paths.items.len);
    // ⑵ 그리고 **간 것과 같다**: 물어본 목록의 바이트 합이 상한 안이다.
    var sent: usize = 0;
    for (res.asked) |a| sent += a.len + 1;
    try std.testing.expect(sent <= git_command.max_check_ignore_stdin_bytes);
    // ⑶ 한 칸 더 넣었으면 넘었을 것 — 「덜 보냈다」가 아니라 「담을 수 있는 만큼 보냈다」.
    try std.testing.expect(sent + one_len + 1 > git_command.max_check_ignore_stdin_bytes);
    // ⑷ 내용이 앞에서부터 그대로다.
    try std.testing.expectEqualStrings(paths.items[0], res.asked[0]);
    try std.testing.expectEqualStrings(paths.items[res.asked.len - 1], res.asked[res.asked.len - 1]);
}

test "check-ignore 답은 «물어본 목록»을 통째로 들고 온다 — 실제 백엔드로" {
    // **적대적 검증 11 회차(2026-09-14).** 10 회차가 `IgnoreResult.asked` 를 더하면서 소유권이
    // job → result 로 **넘어가는** 길이 생겼다. 그 길을 앱 층 판정자(주입)로만 덮어 두면, 실제
    // worker 가 무엇을 싣는지는 아무도 안 본다.
    //
    // 여기서 무는 것 셋:
    //   ⑴ 물어본 **전부**가 답에 실린다(부분이면 안 물어본 행의 표시가 안 지워진다).
    //   ⑵ 순서·내용이 그대로다.
    //   ⑶ **소유권이 진짜 넘어왔다** — job 이 이미 죽은 뒤에 읽어도 살아 있는 바이트다.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_len = tmp.dir.realPath(io, &repo_buf) catch return error.SkipZigTest;
    const repo = repo_buf[0..repo_len];

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = locate(&exe_buf) orelse return error.SkipZigTest;
    if (!initRepoForTest(allocator, git_exe, repo)) return error.SkipZigTest;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ignore_path = try std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{repo});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ignore_path, .data = "*.tmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.tmp", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.zig", .data = "" });

    var backend = try Backend.init(io);
    defer backend.deinit();

    // **호출자 버퍼는 곧 사라진다** — 제품에서도 그렇다(질의가 넘기는 것은 **트리가 소유한** 문자열의
    // 슬라이스이고, 다음 스냅샷이 그 자리를 갈아엎는다). 답이 그 메모리를 가리키고 있으면 여기서 드러난다.
    var scratch: [64]u8 = undefined;
    @memcpy(scratch[0..5], "a.tmp");
    @memcpy(scratch[5..13], "keep.zig");
    const asked_in = [_][]const u8{ scratch[0..5], scratch[5..13] };
    try std.testing.expect(backend.submitCheckIgnore(git_exe, repo, &asked_in, 7));
    @memset(&scratch, 0xAA); // 호출자 버퍼를 뭉갠다

    // **안 오면 실패다 — 건너뛰지 않는다.** 첫 판이 `SkipZigTest` 였는데, 그러면 이 판정자는 조용히
    // 공허해진다(실측: 초록인데 skip 수만 하나 늘었다). 10 초는 `waitForDiff` 와 같은 선이다.
    var taken: ?IgnoreResult = null;
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        taken = backend.takeIgnoreResult();
        if (taken != null) break;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    var res = taken orelse return error.IgnoreReadNeverCompleted;
    defer res.deinit(worker_allocator);

    try std.testing.expect(res.ok);
    try std.testing.expectEqual(@as(u64, 7), res.request_id);
    // ⑴⑵ 물어본 전부가, 순서 그대로.
    try std.testing.expectEqual(@as(usize, 2), res.asked.len);
    try std.testing.expectEqualStrings("a.tmp", res.asked[0]);
    try std.testing.expectEqualStrings("keep.zig", res.asked[1]);
    // ⑶ 답 본문은 무시된 것만.
    try std.testing.expectEqualStrings("a.tmp\x00", res.text);
}

test "runOn 은 check-ignore 를 실어 나르지 않는다 — 빈 stdin 은 «틀린 성공»이다" {
    // **적대적 검증 9 회차.** 8 회차가 `check-ignore` 를 `--stdin` 으로 옮기면서 **새 표면**을 만들었다:
    // 경로가 argv 에 없으므로, 이 명령을 stdin 없이 돌리면 실패하지 않고 **빈 입력을 읽고 성공한다.**
    // 그 답은 「무시된 것이 없다」이고, 「저장소를 못 읽었다」와 달리 화면에 아무 경고도 안 남긴다.
    //
    // `runOn` 은 `kind` 를 **런타임 값**으로 받으므로 컴파일러가 이것을 막아 주지 않는다 — 지금
    // 부르는 자리가 없다는 사실은 «다음 사람이 안 부른다»를 뜻하지 않는다.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // 로컬로도, 원격으로도 안 된다 — 둘 다 stdin 을 안 싣는 같은 경로다.
    // **전용 오류로 받는다.** `GitFailed` 로 두면 이 판정자가 공허해진다 — 게이트를 지워도 git 이
    // 빈 stdin 으로 exit 1 을 내 같은 오류가 나오기 때문이다(실측으로 확인하고 갈랐다).
    try std.testing.expectError(
        error.CheckIgnoreNeedsStdin,
        runOn(allocator, null, .check_ignore, "/usr/bin/git", "/repo", null),
    );
    try std.testing.expectError(
        error.CheckIgnoreNeedsStdin,
        runOn(
            allocator,
            .{ .dest = "u@nowhere.invalid", .control_path = "/nonexistent/sock" },
            .check_ignore,
            git_command.remote_git_exe,
            "/repo",
            null,
        ),
    );

    // **대조군**: 다른 kind 는 이 자리에서 막히지 않는다(여기서 막히면 위 단언이 공허해진다).
    // 저장소가 아닌 경로라 git 이 거절하지만, 그것은 **git 이 한 말**이라 다른 오류로 온다.
    const other = runOn(allocator, null, .status, "/usr/bin/git", "/nonexistent-repo-xyz", null);
    if (other) |out| {
        allocator.free(out.bytes);
    } else |err| {
        try std.testing.expect(err == error.GitFailed); // 도달은 했다 — 위 게이트가 아니라 git 의 답이다
    }
}

test "check-ignore 는 진짜 git 을 통과한다 — 무시된 것, 없는 것, 개행이 든 이름" {
    // ⚠️ **모양만 보는 판정자로는 12 일을 못 잡았다.** 예전 argv 는
    // `git -C <repo> … check-ignore -z <경로들>` 이었는데, git 은 그 조합을
    // `fatal: -z only makes sense with --stdin` 으로 **거절한다**(exit 128). 그래서 `.gitignore`
    // 흐림은 화면에서 **한 번도 뜬 적이 없었고**, argv 토큰을 세는 판정자들은 전부 초록이었다.
    //
    // 그러니 이 판정자는 **실제로 돌린다.** 세 가지를 한 번에 문다:
    //   ⑴ 무시된 것이 있으면 그 경로들이 NUL 로 끊겨 온다.
    //   ⑵ 무시된 것이 **하나도 없으면** git 은 **exit 1** 이다 — 그것은 실패가 아니라 **빈 답**이고,
    //      실패로 접으면 「안 물어본 상태」와 구별되지 않아 흐림이 영영 안 선다.
    //   ⑶ 이름에 **개행**이 들어 있어도 답이 갈라지지 않는다 — `-z` 를 쓰는 이유가 그것이고,
    //      `--stdin` 없이는 그 `-z` 를 못 쓴다.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_len = tmp.dir.realPath(io, &repo_buf) catch return error.SkipZigTest;
    const repo = repo_buf[0..repo_len];

    // 저장소를 만든다. git 이 없으면 이 판정자는 성립하지 않는다.
    {
        var exe_buf0: [std.fs.max_path_bytes]u8 = undefined;
        const git_exe0 = locate(&exe_buf0) orelse return error.SkipZigTest;
        if (!initRepoForTest(allocator, git_exe0, repo)) return error.SkipZigTest;
    }

    // `.gitignore` 와 항목들. **개행이 든 이름**이 ⑶ 의 자리다.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ignore_path = try std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{repo});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ignore_path, .data = "build/\n*.tmp\n" });

    // **항목이 실제로 있어야 한다.** `build/` 는 «디렉터리일 때만» 맞는 패턴이라, 그 자리가 비어
    // 있으면 git 은 무시로 안 친다 — 탐색기가 묻는 것은 늘 «방금 읽어 본 실제 항목»이므로 여기서도
    // 같은 조건을 만든다(이 함정에 한 번 걸려 판정자가 빨갰다).
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.tmp", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "odd\nname.tmp", .data = "" });

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = locate(&exe_buf) orelse return error.SkipZigTest;
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.buildCheckIgnore(git_exe, repo, &argv_buf);
    var payload_buf: [4096]u8 = undefined;

    // ⑴ 무시된 것이 섞여 있다.
    {
        const paths = [_][]const u8{ "build", "keep.zig", "a.tmp" };
        const payload = git_command.checkIgnoreStdin(&paths, &payload_buf);
        const out = try runArgvCheckIgnore(allocator, argv, payload);
        defer allocator.free(out.bytes);
        var saw_build = false;
        var saw_tmp = false;
        var saw_keep = false;
        var it = std.mem.splitScalar(u8, out.bytes, 0);
        while (it.next()) |one| {
            if (one.len == 0) continue;
            if (std.mem.eql(u8, one, "build")) saw_build = true;
            if (std.mem.eql(u8, one, "a.tmp")) saw_tmp = true;
            if (std.mem.eql(u8, one, "keep.zig")) saw_keep = true;
        }
        try std.testing.expect(saw_build);
        try std.testing.expect(saw_tmp);
        try std.testing.expect(!saw_keep); // 안 무시된 것은 답에 없다
    }

    // ⑵ 하나도 안 무시된 배치 — git 은 **1** 로 끝난다. 그래도 `ok` 여야 한다.
    {
        const paths = [_][]const u8{ "keep.zig", ".gitignore" };
        const payload = git_command.checkIgnoreStdin(&paths, &payload_buf);
        const out = try runArgvCheckIgnore(allocator, argv, payload);
        defer allocator.free(out.bytes);
        try std.testing.expectEqual(@as(usize, 0), out.bytes.len); // 빈 답이지 실패가 아니다
    }

    // ⑶ 개행이 든 이름. `-z` 가 없으면 이 한 줄이 **두 줄**로 읽힌다.
    {
        const paths = [_][]const u8{"odd\nname.tmp"};
        const payload = git_command.checkIgnoreStdin(&paths, &payload_buf);
        const out = try runArgvCheckIgnore(allocator, argv, payload);
        defer allocator.free(out.bytes);
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, out.bytes, 0);
        while (it.next()) |one| {
            if (one.len == 0) continue;
            count += 1;
            try std.testing.expectEqualStrings("odd\nname.tmp", one); // 통째로 한 답이다
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

/// 원격 SCM 판정자가 쓰는 **실물 SSH 하네스**. `tools/remote-scm/ssh_harness.sh` 가 env 로 준다.
///
/// ⚠️ **없으면 건너뛴다 — 없는 것을 있다고 치고 통과시키지 않는다.** 개발자 기계에서 손으로 돌릴 때는
/// 그 스크립트를 거치지 않으면 이 판정자들이 조용히 안 돈다. 그것이 맞다: 원격 판정을 **가짜 대상**으로
/// 통과시키면 그 초록은 아무것도 뜻하지 않는다.
/// 판정자용: 임시 디렉터리에 저장소 하나를 세운다. **큐를 거치지 않고** 바로 돌린다 — 이 파일 밖의
/// 판정자가 `runArgvWithEnv` 를 못 부르므로(비공개) 여기 한 줄로 열어 둔다.
///
/// ⚠️ **사용자의 전역 무시 목록을 끊는다**(`core.excludesFile` 을 빈 값으로 박는다).
/// `GIT_CONFIG_NOSYSTEM` 은 `/etc/gitconfig` 만 막고 **`~/.gitconfig` 는 안 막는다** — 제품에게는
/// 그것이 맞지만(사용자의 git 이 실제로 그렇게 무시한다) 판정자에게는 **기계마다 답이 달라진다**는
/// 뜻이다. 실측(적대적 검증 13 회차): 전역에 `*.zig` 를 넣으면 이 파일의 실-git 판정자들이 무더기로
/// 빨개진다. 저장소 로컬 값이 전역을 이기므로 여기서 끊는다(`WriteFixture.init` 과 같은 규율).
pub fn initRepoForTest(allocator: std.mem.Allocator, git_exe: []const u8, repo: []const u8) bool {
    const init_out = runArgvWithEnv(allocator, &.{ git_exe, "-C", repo, "init", "-q" }, null, false, null, false) catch return false;
    allocator.free(init_out.bytes);
    const cfg = runArgvWithEnv(allocator, &.{ git_exe, "-C", repo, "config", "core.excludesFile", "" }, null, false, null, false) catch return false;
    allocator.free(cfg.bytes);
    return true;
}

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
    const head = try runArgvWithEnv(allocator, &.{ "/usr/bin/git", "-C", hx.repo, "log", "-1", "--format=%B" }, null, false, null, false);
    defer allocator.free(head.bytes);
    try std.testing.expect(std.mem.startsWith(u8, head.bytes, "RS4b-STDIN"));
    try std.testing.expect(head.bytes.len >= big.len - 2); // 잘리지 않았다
}

test "원격 히스토리: 커밋 목록이 저쪽 기계에서 오고 구분자가 그대로 도착한다 (RS7b)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hx = remoteScmHarness() orelse return error.SkipZigTest;
    const remote: git_command.Remote = .{ .dest = hx.dest, .control_path = hx.ctl };

    // ⑴ **wire 부터 본다.** 여기가 RS7a 이전에 원리적으로 막혀 있던 자리다 — `--format=` 토큰에 날
    //    바이트가 있으면 `buildRemote` 가 명령을 아예 안 만들어 `error.GitFailed` 다. 그러니 이 한 줄이
    //    통과한다는 사실 자체가 「토큰이 인쇄 가능해졌다」의 실물 증거다.
    const out = try runOn(allocator, remote, .log, git_command.remote_git_exe, hx.repo, "5");
    defer allocator.free(out.bytes);
    try std.testing.expect(out.bytes.len > 0);

    // ⑵ **구분자가 그대로 도착했나.** `%x1f` 는 git 이 **출력에** 그 바이트를 낸다 — 링크를 건너오며
    //    바뀌지 않았는지(개행 변환·인코딩)를 바이트로 확인한다.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.bytes, maru.session.git_log.field_sep) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.bytes, maru.session.git_log.record_sep) != null);

    // ⑶ **파서가 실제로 커밋을 세운다.** 「바이트가 왔다」와 「목록이 선다」는 다른 사실이다.
    var it = maru.session.git_log.iterate(out.bytes);
    const first = it.next() orelse return error.RemoteLogParsedNoCommit;
    try std.testing.expect(first.oid.len >= 7);
    try std.testing.expect(first.author.len > 0);

    // ⑷ **`submitLog` 배선도 같은 값을 낸다.** 위는 러너까지고, 이것은 job 이 원격 두 축을 쌍으로
    //    들고 worker 까지 나르는지를 본다(하나만 들면 `remoteTarget()` 이 로컬로 읽는다).
    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try std.testing.expect(backend.submitLog(git_command.remote_git_exe, hx.repo, 5, 41, remote));
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeLogResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
            try std.testing.expectEqual(@as(u64, 41), result.request_id);
            try std.testing.expect(result.ok);
            try std.testing.expectEqualStrings(hx.repo, result.repo);
            try std.testing.expect(std.mem.indexOfScalar(u8, result.text, maru.session.git_log.record_sep) != null);
            break;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    } else return error.RemoteLogNeverCompleted;

    // ⑸ **대조군 — 정말 링크를 탔는가.** 이 하네스의 원격은 loopback 이라 `hx.repo` 가 **이쪽에도
    //    있는 경로**다. 그래서 위 넷은 「로컬 git 이 답했다」로도 전부 통과한다 — 그 자체로는 원격을
    //    증명하지 못한다. 소켓을 죽은 것으로 바꾸면 갈린다: 원격 경로면 전송이 실패하고, 로컬로
    //    새고 있으면 **여전히 성공한다.**
    const dead: git_command.Remote = .{ .dest = hx.dest, .control_path = "/nonexistent/sock" };
    try std.testing.expectError(
        error.RemoteTransportFailed,
        runOn(allocator, dead, .log, git_command.remote_git_exe, hx.repo, "5"),
    );

    // 같은 대조군을 **`submitLog` 배선에도** 건다. job 이 두 축을 안 나르면 `remoteTarget()` 이 null 이라
    // 로컬로 돌아 `ok = true` 가 된다 — 그때 이 단언이 잡는다.
    try std.testing.expect(backend.submitLog(git_command.remote_git_exe, hx.repo, 5, 42, dead));
    spins = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeLogResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
            try std.testing.expectEqual(@as(u64, 42), result.request_id);
            try std.testing.expect(!result.ok); // 죽은 소켓으로는 못 읽는다
            return;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.RemoteLogDeadSocketNeverCompleted;
}

test "원격 커밋의 파일 목록도 저쪽 기계에서 온다 (RS7c)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hx = remoteScmHarness() orelse return error.SkipZigTest;
    const remote: git_command.Remote = .{ .dest = hx.dest, .control_path = hx.ctl };

    // 읽을 커밋은 **그 저장소가 실제로 가진 것**이어야 한다 — 손으로 적은 oid 는 「없는 커밋」 실패와
    // 구별이 안 된다. 히스토리 목록(RS7b)이 내는 첫 커밋을 그대로 쓴다.
    const log_out = try runOn(allocator, remote, .log, git_command.remote_git_exe, hx.repo, "1");
    defer allocator.free(log_out.bytes);
    var it = maru.session.git_log.iterate(log_out.bytes);
    const head = it.next() orelse return error.RemoteLogParsedNoCommit;

    var backend = try Backend.init(std.Io.Threaded.global_single_threaded.io());
    defer backend.deinit();
    try std.testing.expect(backend.submitCommitFiles(git_command.remote_git_exe, hx.repo, head.oid, 51, remote));
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeCommitFilesResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
            try std.testing.expectEqual(@as(u64, 51), result.request_id);
            try std.testing.expect(result.ok);
            try std.testing.expectEqualStrings(head.oid, result.oid);
            // `--raw` 줄은 `:` 로 시작한다 — 「무언가 왔다」가 아니라 **그 형식이 왔다**를 본다.
            try std.testing.expect(std.mem.indexOfScalar(u8, result.text, ':') != null);
            break;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    } else return error.RemoteCommitFilesNeverCompleted;

    // **대조군** — 하네스 원격이 loopback 이라 위만으로는 「원격이다」가 증명되지 않는다(RS7b 와 같은
    // 이유). 소켓을 죽이면 원격 경로는 실패하고, 로컬로 새고 있으면 **여전히 성공한다.**
    const dead: git_command.Remote = .{ .dest = hx.dest, .control_path = "/nonexistent/sock" };
    try std.testing.expect(backend.submitCommitFiles(git_command.remote_git_exe, hx.repo, head.oid, 52, dead));
    spins = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeCommitFilesResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
            try std.testing.expectEqual(@as(u64, 52), result.request_id);
            try std.testing.expect(!result.ok);
            return;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.RemoteCommitFilesDeadSocketNeverCompleted;
}

// [AT3c] **원격 턴 스냅샷이 저쪽 기계에서 찍힌다.** 임시 index 는 원격 경로이고 명령 문자열의 env 로 실린다
// (`buildRemoteWithIndex`). 진짜 index 는 건드리지 않는다 — 로컬 e2e 판정자와 같은 안전 근거를 원격에서 다시 잰다.
test "원격 턴 스냅샷: 임시 index 로 tree 를 굳히고 진짜 index 는 그대로다 (AT3c)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hx = remoteScmHarness() orelse return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const remote: git_command.Remote = .{ .dest = hx.dest, .control_path = hx.ctl };

    // 턴이 끝난 시점의 작업트리: 추적 안 되는 새 파일 하나(매번 다른 이름 — 앞 판정자가 남긴 것과 안 섞이게).
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "at3c-{d}.txt", .{std.Io.Clock.awake.now(io).nanoseconds});
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ hx.repo, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "turn\n" });
    defer std.Io.Dir.cwd().deleteFile(io, file) catch {};

    // 임시 index 는 **원격 `/tmp`** — 제품이 쓰는 모양 그대로(`remoteTurnIndexPath`). 끝나면 지운다.
    var index_buf: [96]u8 = undefined;
    const index_file = try std.fmt.bufPrint(&index_buf, "/tmp/maru-turn-test-{d}.idx", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, index_file) catch {};

    const oid = try takeTurnSnapshotRemote(allocator, remote, hx.repo, index_file);
    defer allocator.free(oid);
    try std.testing.expect(oid.len >= 40);

    // ⑴ **tree 에 그 파일이 있다** — `add -A` 가 임시 index 를 채웠다. 제품이 턴 목록에 쓰는 **바로 그 명령**
    //    (`turn_name_status`, `HEAD <tree>`)으로 저쪽 git 에게 묻는다 — 목록 읽기가 원격 tree 에 닿는다는 증거다.
    var pair_buf: [128]u8 = undefined;
    const pair = try std.fmt.bufPrint(&pair_buf, "HEAD {s}", .{oid});
    const listed = try runOn(allocator, remote, .turn_name_status, git_command.remote_git_exe, hx.repo, pair);
    defer allocator.free(listed.bytes);
    try std.testing.expect(std.mem.indexOf(u8, listed.bytes, name) != null);

    // ⑵ **진짜 index 는 그대로다** — 그 파일은 여전히 추적되지 않는다(`?`).
    const status = try runOn(allocator, remote, .status, git_command.remote_git_exe, hx.repo, null);
    defer allocator.free(status.bytes);
    var q_buf: [96]u8 = undefined;
    const untracked = try std.fmt.bufPrint(&q_buf, "? {s}", .{name});
    try std.testing.expect(std.mem.indexOf(u8, status.bytes, untracked) != null);

    // ⑶ **임시 index 가 원격 경로에 생겼다**(loopback 이라 같은 파일시스템 — 대조에서만 직접 본다).
    _ = try std.Io.Dir.cwd().statFile(io, index_file, .{});

    // ⑷ **`submitSnapshot` 배선** — job 이 원격 두 축을 worker 까지 나른다.
    var backend = try Backend.init(io);
    defer backend.deinit();
    try std.testing.expect(backend.submitSnapshot(git_command.remote_git_exe, hx.repo, index_file, 77, remote));
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        if (backend.takeSnapshotResult()) |taken| {
            var result = taken;
            defer result.deinit(worker_allocator);
            try std.testing.expectEqual(@as(u64, 77), result.surface_id);
            try std.testing.expectEqualStrings(oid, result.tree); // 같은 작업트리 = 같은 tree
            break;
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    } else return error.RemoteSnapshotNeverCompleted;

    // ⑸ **대조군** — 죽은 소켓이면 실패해야 한다(로컬로 새면 loopback 저장소가 있어 여전히 성공한다).
    const dead: git_command.Remote = .{ .dest = hx.dest, .control_path = "/nonexistent/sock" };
    try std.testing.expectError(error.RemoteTransportFailed, takeTurnSnapshotRemote(allocator, dead, hx.repo, index_file));
}

test "원격 읽기 실패: git 이 없는 것과 연결이 끊긴 것을 가른다 (RS4 §2.2 ⑺)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hx = remoteScmHarness() orelse return error.SkipZigTest;
    const remote: git_command.Remote = .{ .dest = hx.dest, .control_path = hx.ctl };

    // ⑴ **연결이 끊기면 «전송 실패»다.** 그 stderr 는 ssh 가 한 말이라 저장소 이야기가 아니다.
    try std.testing.expectError(
        error.RemoteTransportFailed,
        runOn(allocator, .{ .dest = hx.dest, .control_path = "/nonexistent/sock" }, .status, git_command.remote_git_exe, hx.repo, null),
    );

    // ⑵ **원격에서 «명령 없음»(127)이 실제로 그 오류로 올라온다.**
    //
    //    ⚠️ 「git 없는 원격」을 만들 수는 없다 — 이 기계에는 `/usr/bin/git` 이 늘 있고, `buildRemote` 는
    //    `argv[0]` 을 버리므로 가짜 경로를 넘겨도 원격은 여전히 `git` 을 찾는다(RS4a 의 설계다).
    //    그래서 **실물 전송 위에서 진짜 127** 을 내고, 그것이 어떤 오류로 오는지 본다.
    var argv_buf: [remote_shell.ssh_argv_len][]const u8 = undefined;
    const missing = remote_shell.sshArgv(
        .{ .dest = hx.dest, .control_path = hx.ctl },
        &argv_buf,
        "'sh' '-c' 'exit 127'",
    ).?;
    try std.testing.expectError(error.ExitCommandNotFound, runArgvWithEnv(allocator, missing, null, true, null, false));
    // 그리고 `runOn` 이 그것을 **이야기로 바꾼다** — 두 조각을 따로 세야 「원격을 못 만든다」는 사정이
    // 규칙 자체를 안 보는 핑계가 되지 않는다.
    try std.testing.expectEqual(@as(anyerror, error.RemoteGitMissing), mapRemoteExitError(error.ExitCommandNotFound));
    try std.testing.expectEqual(@as(anyerror, error.RemoteTransportFailed), mapRemoteExitError(error.ExitTransportFailed));
    // **git 이 한 말은 안 건드린다.**
    try std.testing.expectEqual(@as(anyerror, error.GitFailed), mapRemoteExitError(error.GitFailed));

    // ⚠️ **로컬에서는 127 을 그렇게 읽지 않는다**(적대적 검증 1회차). 우리 자식은 `execve` 가 실패하면
    //    스스로 127 로 끝난다 — 그것은 「원격에 git 이 없다」가 아니라 「로컬 git 을 못 띄웠다」이고,
    //    화면에 「원격에 git 을 깔라」고 적으면 사용자는 **엉뚱한 기계**를 손본다.
    try std.testing.expectError(
        error.GitFailed,
        runArgvWithEnv(allocator, &.{"/definitely/not/a/binary"}, null, false, null, false),
    );
    // 같은 명령을 **원격 해석으로** 부르면 그때는 이름이 붙는다 — 갈리는 것은 그 스위치 하나다.
    try std.testing.expectError(
        error.ExitCommandNotFound,
        runArgvWithEnv(allocator, &.{"/definitely/not/a/binary"}, null, true, null, false),
    );

    // ⑶ **원격 파일 읽기(diff 오른쪽)도 같은 이름을 받는다**(적대적 검증 1회차). `runOn` 만 배선하면
    //    목록은 「연결이 끊겼다」인데 diff 는 「읽지 못함」이라, 사용자는 둘 중 무엇을 믿을지 모른다.
    {
        var fr_buf: [git_command.max_argv][]const u8 = undefined;
        var fr_cmd: [git_command.max_remote_command_bytes]u8 = undefined;
        const dead: git_command.Remote = .{ .dest = hx.dest, .control_path = "/nonexistent/sock" };
        const fr = git_command.buildRemoteFileRead("/etc/hosts", dead, &fr_buf, &fr_cmd).?;
        try std.testing.expectError(
            error.ExitTransportFailed,
            runArgvWithEnv(allocator, fr, null, true, null, false),
        );
    }

    // ⑷ **git 이 실제로 거부한 것은 그대로 둔다** — 저장소가 아닌 폴더는 128 이고, 그것은 git 이 한 말이다.
    try std.testing.expectError(
        error.GitFailed,
        runOn(allocator, remote, .status, git_command.remote_git_exe, "/", null),
    );
}
