//! git · SCM — 저장소 탐지와 브랜치·상태 갱신, SCM 뷰 행 구성, diff term 열기.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F15).
//! ABI가 직접 부르는 것이 없어 facade가 0개다 — git 상태는 Zig가 주기적으로 갱신해 사이드바·SCM 뷰에
//! 반영할 뿐 호스트가 물어보지 않는다.
//!
//! `scmDrawWindow`는 여기 없다 — 이름은 SCM이지만 본문이 `dock_ops` 위임 한 줄인 **F5 dock의 facade**다
//! (F8 `scrollToCurrentMatch`·F14 `agentSessionArchive*`와 같은 유형). 실제 그리기 창 계산은 도크가 한다.
//!
//! 실행 자체는 worker(`git_backend`·`git_command`)가 소유하고, 여기서는 그 결과를 메인 스레드 상태로
//! 옮기고 UI에 반영하는 일만 한다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const scroll_ops = @import("scroll.zig");
const diag_gate = app_session_mod.diag_gate;
const git_command = app_session_mod.git_command;
const layout_math = app_session_mod.layout_math;
const scm_dock_ops = @import("scm_dock.zig");
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
const editor_diff_ops = @import("editor_diff.zig");
const settings_ops = @import("settings.zig");
const tab_ops = @import("tab.zig");
const Term = app_session_mod.Term;
const dock_panel = app_session_mod.dock_panel;
const file_panel_ops = @import("file_panel.zig");
const git_backend_mod = app_session_mod.git_backend_mod;
const repoRootFor = AppSession.repoRootFor;
const scm_row_capacity = app_session_mod.scm_row_capacity;
const scm_view = app_session_mod.scm_view;

/// git 읽기를 건다. 소스 컨트롤 뷰를 보고 있지 않으면 아무것도 하지 않는다 — 안 보는 화면 때문에 프로세스를
/// 띄우지 않는다. 이미 in-flight면 건너뛴다(큐를 쌓아 오래된 결과를 줄줄이 만들지 않는다 — §3.5).
pub fn refreshGitStatus(self: *AppSession) void {
    if (self.dock.view != .source_control) return;
    if (self.git_inflight != 0) return;
    if (self.scm_write_inflight != 0) return; // 위와 같은 이유(§6-1)
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = gitRepoRoot(self, &repo_buf) orelse return;
    submitGitRead(self, repo);
}

/// **이미 해석한 저장소로** 읽기를 건다. `gitRepoRoot`를 다시 부르지 않는 진입점이라, 저장소를 방금 판정한
/// 호출자(`followActiveTerminalRepo`)가 같은 walk-up과 같은 기록을 두 번 하지 않는다.
fn submitGitRead(self: *AppSession, repo: []const u8) void {
    if (self.dock.view != .source_control) return;
    if (self.git_inflight != 0) return;
    // **쓰기가 도는 동안 읽기를 걸지 않는다**(쓰기 문서 §6-1). 겹치면 `index.lock`에서 뒤엣것이 즉시
    // 실패하고, 무엇보다 그 읽기는 쓰기 **이전** 상태를 담아 와 화면을 되돌린다. 쓰기가 끝나면
    // `drainScmWrite`가 한 번 건다.
    if (self.scm_write_inflight != 0) return;
    // **기억·감시를 실행 파일 탐색보다 먼저** 한다. git이 없어 아래에서 돌아가더라도 "지금 보는 저장소"는
    // 확정된 사실이고, 여기서 안 남기면 호출자가 매 tick 다시 "저장소가 바뀌었다"로 읽어 무효화가 반복된다.
    rememberGitRepo(self, repo);
    ensureGitWatch(self, repo);
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    // 실행 파일을 먼저 확정한다. 못 찾으면 **실행을 시도하지 않고** 미설치로 표시한다(docs/editor-surface-tooling.md §6).
    // 후보 열거에만 PATH를 쓰고 exec는 확정된 절대경로로 한다(셸·execvp 경유 없음 = PATH hijack 차단 유지).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse {
        self.git_missing = true;
        self.metal_dirty = true;
        return;
    };
    self.git_missing = false;
    self.git_request_seq += 1;
    // **턴 스냅샷은 그것을 뜬 저장소에서만 유효하다.** 다른 저장소에 그 tree OID를 넘기면 `git diff <남의 tree>`가
    // 그 저장소 안에서 해석돼 "이번 턴에 바뀐 것" 섹션이 엉뚱한 diff로 채워진다(같은 프로젝트의 다른 clone·
    // worktree면 object DB에 그 tree가 실제로 있어 조용히 성공한다). `captureTurnSnapshot`이 링을 만들 때 같은
    // 이유로 저장소를 대조하는데, **소비하는 쪽에도** 있어야 저장소를 바꾸는 모든 경로가 덮인다.
    const snapshot = blk: {
        const ring_repo = self.turn_ring_repo orelse break :blk "";
        if (!std.mem.eql(u8, ring_repo, repo)) break :blk "";
        break :blk if (self.turn_ring.latest()) |snap| snap.oid() else "";
    };
    if (self.git_backend.?.submit(git_exe, repo, snapshot, self.turnIndexPath() orelse "", self.git_request_seq)) {
        self.git_inflight = self.git_request_seq;
    }
}

/// 목록을 읽은 저장소를 기억한다. 같은 값이면 다시 할당하지 않는다.
pub fn rememberGitRepo(self: *AppSession, repo: []const u8) void {
    if (self.git_repo) |current| {
        if (std.mem.eql(u8, current, repo)) return;
        // **초안을 옮겨 담는 유일한 자리**다 — 여기가 옛 저장소와 새 저장소를 동시에 아는 곳이다.
        scm_dock_ops.switchCommitDraft(self, current, repo);
        self.allocator.free(current);
        self.git_repo = null;
    } else {
        scm_dock_ops.switchCommitDraft(self, null, repo);
    }
    self.git_repo = self.allocator.dupe(u8, repo) catch null;
}

/// 감시할 **실제 git 디렉터리**. 보통은 `<repo>/.git`이지만, 링크된 워크트리에서는 그것이 디렉터리가
/// 아니라 `gitdir: <경로>` 한 줄이 든 **파일**이고 index·HEAD는 그 경로 아래에 산다.
///
/// **그래서 `.git`만 감시하면 워크트리에서는 아무 일도 안 일어난다** — `git add`가 그 파일을 건드리지
/// 않기 때문이다(실측 2026-08-16: stage 전후 mtime 불변, 바뀐 것은
/// `<주 저장소>/.git/worktrees/<이름>/index`였다). 목록이 터미널에서 친 git 명령에 반응하지 않는다.
///
/// 읽기에 실패하거나 형식이 아니면 `<repo>/.git`으로 되돌린다 — 일반 저장소가 그 답이고, 워크트리에서
/// 실패하면 예전과 같은(갱신 없는) 상태일 뿐 **틀린 디렉터리를 감시하지는 않는다**.
fn gitWatchTarget(self: *AppSession, repo: []const u8, buf: []u8) []const u8 {
    var dot_git_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dot_git = std.fmt.bufPrint(&dot_git_buf, "{s}/.git", .{repo}) catch return repo;
    // 디렉터리면 읽기가 실패한다 — 그게 일반 저장소이고, 폴백이 곧 정답이다.
    const data = std.Io.Dir.cwd().readFileAlloc(self.io, dot_git, self.allocator, .limited(4096)) catch
        return copyInto(dot_git, buf);
    defer self.allocator.free(data);
    return maru.session.repo_path.gitDirFromDotGitFile(data, repo, buf) orelse copyInto(dot_git, buf);
}

fn copyInto(source: []const u8, buf: []u8) []const u8 {
    if (source.len > buf.len) return source;
    @memcpy(buf[0..source.len], source);
    return buf[0..source.len];
}

/// 그 저장소의 git 디렉터리를 감시 목록에 올린다. 같은 경로면 아무것도 하지 않는다(중복 요청 금지).
pub fn ensureGitWatch(self: *AppSession, repo: []const u8) void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = gitWatchTarget(self, repo, &target_buf);
    if (self.git_watch_path) |current| {
        if (std.mem.eql(u8, current, target)) return;
        self.allocator.free(current);
        self.git_watch_path = null;
    }
    const path = self.allocator.dupe(u8, target) catch return;
    const request = self.allocator.dupe(u8, path) catch {
        self.allocator.free(path);
        return;
    };
    if (self.git_watch_request) |old| self.allocator.free(old);
    self.git_watch_request = request;
    self.git_watch_path = path;
}

/// 그 경로가 저장소 내부(`.git`) 변경인가 — 목록을 다시 읽어야 하는 신호다.
pub fn isGitInternalPath(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "/.git")) return true;
    return std.mem.indexOf(u8, path, "/.git/") != null;
}

/// **활성 터미널이 다른 저장소로 옮겨 갔으면 목록을 다시 읽는다**(docs/editor-surface-dock.md §3.5).
///
/// 이게 없으면 `refreshGitStatus`를 부르는 트리거가 도크 뷰 전환·`.git` 감시·턴 스냅샷뿐이라, 탭을 옮기거나
/// `cd`로 다른 저장소에 들어가도 목록이 옛 저장소에 멈춰 있고 감시자도 옛 `.git`을 계속 본다.
///
/// 정책은 파일 탐색기의 `followActiveTerminalCwd`(file_panel.zig)와 **같은 넷**을 쓴다 — 축이 하나여야 두 뷰가
/// 같은 저장소를 본다: ⑴ 뷰가 보일 때만 ⑵ 활성 pane·활성 Term만 ⑶ **모르면 직전 값 유지** ⑷ 바뀔 때만.
///
/// ⑶이 특히 중요하다: diff를 열면 활성 Term이 웹 Term이 되어 cwd가 없어지는데, 그걸 "저장소 없음"으로 읽으면
/// 목록이 사라지거나 탐색기 root로 튄다. `gitRepoTarget`이 그 경우 `.unknown`(또는 2순위)을 주므로 no-op이 된다.
///
/// **⑶의 "모르면"은 "저장소가 아니면"과 다르다.** 터미널이 저장소 아닌 폴더에 서 있다고 답한 것은 확정된 사실
/// (`.none`)이고, 그때는 유지가 아니라 **버리는** 것이 §3.5의 규정이다 — 유지하면 탐색기는 새 폴더를, 목록은 옛
/// 저장소를 보여 준다. 둘을 같은 null로 받던 동안 이 함수는 구별할 수 없어 둘 다 유지했다(사용자 보고 2026-08-12).
pub fn followActiveTerminalRepo(self: *AppSession) void {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = switch (gitRepoTarget(self, &repo_buf)) {
        .repo => |found| found,
        .unknown => return, // 모르면 직전 판단을 유지한다(파일 Term·원격 세션)
        .none => {
            // 터미널이 저장소 아닌 폴더에 서 있다 — 결론은 "저장소 없음"이므로 옛 목록을 버려 뷰가 그 안내를
            // 내게 한다(안내는 `git_result == null`일 때만 그려진다). **읽기를 새로 걸지는 않는다** — 읽을
            // 저장소가 없다.
            //
            // "지금 보는 저장소"(`git_repo`)는 놓지 않는다. 그 값은 열려 있는 diff(`openDiffForScmRow`)와 턴
            // 스냅샷(`captureTurnSnapshot`)이 대상으로 쓰는 것이고, 여기서 지워야 하는 것은 화면의 목록이다.
            // 1순위가 답을 준 동안에는 2순위가 조회되지 않으므로 남겨 둬도 목록 판정에는 영향이 없다.
            if (scmResultCleared(self)) return; // **멱등**: 매 tick 도는 경로라 반복 무효화는 렌더를 계속 깨운다
            clearScmResult(self);
            return;
        },
    };
    if (self.git_repo) |current| if (std.mem.eql(u8, current, repo)) return; // 바뀔 때만

    // 저장소가 갈렸다. 옛 결과를 그대로 두면 새 저장소의 목록이 도착할 때까지 **남의 저장소 상태**가 화면에 남는다.
    clearScmResult(self);
    // 이미 해석한 저장소를 그대로 넘긴다 — `refreshGitStatus`를 부르면 같은 walk-up을 한 번 더 한다.
    // 기억·감시 이동도 저쪽이 (실행 파일 탐색보다 먼저) 하므로 여기서 중복하지 않는다.
    submitGitRead(self, repo);
}

/// 화면에 남은 목록·실패·선택·in-flight를 버린다. **저장소가 갈릴 때와 "저장소 없음"으로 판정될 때가 같은 정리를
/// 요구**하므로 한 자리에 둔다 — 복붙해 두면 한쪽만 고쳐져 다른 쪽에 남의 저장소 상태가 남는다.
fn clearScmResult(self: *AppSession) void {
    if (self.git_result) |*result| result.deinit(git_backend_mod.worker_allocator);
    self.git_result = null;
    self.git_failed = false; // 옛 저장소의 실패를 새 저장소에 물려주지 않는다
    self.scm_scroll = .{}; // 다른 목록이므로 스크롤·선택은 의미가 없다(엉뚱한 행이 선택돼 보인다)
    self.scm_selected_row = null;
    // **옛 저장소로 날아간 요청을 포기한다.** 이게 없으면 두 가지가 동시에 깨진다: ⑴ `refreshGitStatus`가
    // in-flight를 보고 그냥 돌아가 새 저장소를 영영 안 읽고, ⑵ 뒤늦게 도착한 옛 응답이 `request_id ==
    // git_inflight`로 통과해 남의 저장소 목록으로 화면을 채운다. 0으로 두면 기존 "늦게 온 응답은 버린다"
    // 규칙이 그대로 그 응답을 걸러낸다.
    self.git_inflight = 0;
    // 목록이 바뀌면 **옛 화면을 겨냥한 늦은 클릭**을 거부해야 한다(component action 표의 세대 대조).
    bumpScmDockGeneration(self);
    self.metal_dirty = true;
}

/// 소스 컨트롤 도크의 스냅샷 세대를 올린다. 늦게 도착한 포인터가 옛 목록의 행 인덱스로 엉뚱한 파일을
/// 열지 못하게 하는 유일한 장치다. **그리는 쪽에서 올리면 안 된다** — 그 프레임의 클릭이 전부 거부된다.
pub fn bumpScmDockGeneration(self: *AppSession) void {
    self.scm_dock_snapshot_generation +%= 1;
    if (self.scm_dock_snapshot_generation == 0) self.scm_dock_snapshot_generation = 1;
}

/// 이미 비어 있나. `.none`이 매 tick 반복되므로 무효화가 한 번만 돌게 하는 가드다 — 없으면 `metal_dirty`가
/// 프레임마다 서서, 저장소 아닌 폴더에 서 있는 동안 렌더가 계속 깨어난다.
fn scmResultCleared(self: *const AppSession) bool {
    return self.git_result == null and self.git_inflight == 0 and !self.git_failed and self.scm_selected_row == null;
}

/// 완료된 git 결과를 받아 세션에 싣는다(큐에서 꺼내기만 — 결과 처리 자체엔 I/O가 없다).
///
/// **다만 syscall이 0은 아니다.** 앞의 `followActiveTerminalRepo`가 활성 터미널의 폴더를 확인하는데, OSC 7이 없는
/// 셸에서는 그게 커널 조회로 내려간다(≈0.5초 주기로 캐시 — `proc_cwd_poll_interval_ns`). 그리고 저장소가 바뀌었거나
/// 아직 결과가 없으면 `refreshGitStatus`가 git 프로세스를 띄운다. 둘 다 이 함수가 생기기 전부터 tick이 지던
/// 책임이지만("재요청은 tick이 소유한다"), 주기적 syscall이 새로 들어온 것은 사실이라 여기 적어 둔다.
pub fn drainGitStatus(self: *AppSession) void {
    // 활성 터미널이 다른 저장소로 옮겨 갔는지 먼저 본다 — 아래 "결과가 없으면 한 번 건다"보다 앞이어야
    // 옛 저장소로 요청을 걸어 두고 곧바로 버리는 낭비가 없다.
    followActiveTerminalRepo(self);
    // 복원으로 소스 컨트롤 뷰가 켜진 채 시작하면 `setDockView`를 거치지 않아 첫 읽기가 안 걸린다(실측).
    // 결과도 없고 in-flight도 없을 때만 한 번 건다 — 조건이 결과 도착으로 스스로 닫히므로 폴링이 아니다.
    if (self.dock.view == .source_control and self.git_result == null and self.git_inflight == 0 and !self.git_failed and !self.git_missing) refreshGitStatus(self);
    // 아직 못 건 diff 요청을 여기서 다시 건다. 백엔드 슬롯이 차 있으면 submit이 false를 주므로(그 경우
    // request_id가 0으로 남는다) 다음 tick에 자연히 재시도된다 — 브리지가 아니라 tick이 이 책임을 진다.
    if (self.git_backend != null) {
        var it = file_panel_ops.fileEntries(self);
        while (it.next()) |entry| {
            if (entry.kind != .diff or entry.diff_ready or entry.diff_failed) continue;
            if (entry.diff_request_id == 0) self.requestDiffContent(entry);
        }
    }
    var backend = &(self.git_backend orelse return);
    // 턴 스냅샷 결과를 링에 넣는다. 같은 tree가 연달아 오면 링이 스스로 무시한다(빈 비교 방지 — §6.1).
    while (backend.takeBranchesResult()) |taken| {
        var res = taken;
        self.branch_menu_pending = false;
        defer res.deinit(git_backend_mod.worker_allocator); // backend가 준 버퍼는 backend allocator로만 해제한다
        if (!res.ok or res.text.len == 0) {
            self.showNotice("브랜치 목록을 읽지 못했습니다"); // 조용히 아무 일도 안 일어나는 것보다 낫다
            continue;
        }
        // **소유권을 인수하지 않고 복사한다.** `branch_menu_text`는 세션 소유 필드이고(테스트도 세션 allocator로
        // 채운다) `clearBranchMenuText`가 세션 allocator로 해제한다. backend 버퍼를 그대로 실으면 한 필드에 두
        // allocator의 메모리가 섞여, 어느 쪽으로 해제해도 한쪽이 heap을 깬다. 복사는 `--count=200`으로 유계다.
        const owned = self.allocator.dupe(u8, res.text) catch {
            self.showNotice("브랜치 목록을 읽지 못했습니다");
            continue;
        };
        settings_ops.clearBranchMenuText(self);
        self.branch_menu_text = owned;
        self.branch_menu_len = git_command.collectBranches(self.branch_menu_text, &self.branch_menu_names);
        settings_ops.openBranchMenu(self);
    }
    while (backend.takeSnapshotResult()) |taken| {
        var snapshot = taken;
        self.turn_ring.push(snapshot.tree, snapshot.surface_id);
        snapshot.deinit(git_backend_mod.worker_allocator);
        // 새 기준이 생겼으니 목록을 다시 읽는다(그 섹션이 이제 나온다).
        refreshGitStatus(self);
    }
    // diff 본문 결과를 그 entry로 흘린다. request_id로 짝을 맞춰 **늦게 온 옛 결과가 새 내용을 덮지 않게** 한다.
    while (backend.takeDiffResult()) |taken| {
        var diff_result = taken;
        outer: for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    const entry = term.file_entry orelse continue;
                    if (entry.kind != .diff or entry.diff_request_id != diff_result.request_id) continue;
                    if (diff_result.ok) {
                        // **우리 행이 그 버퍼를 빌린다.** 내용을 풀기 전에 먼저 놓지 않으면 해제된
                        // 메모리를 가리키는 행이 남는다(네이티브 diff Term일 때만 동작).
                        editor_diff_ops.invalidate(self, term);
                        self.freeDiffContent(entry); // rel_path는 남긴다 — 새로 고칠 때 다시 읽을 대상이다
                        entry.diff_original = diff_result.original;
                        entry.diff_modified = diff_result.modified;
                        entry.diff_ready = true;
                        entry.diff_truncated = diff_result.truncated;
                        diff_result.original = &.{};
                        diff_result.modified = &.{};
                    } else entry.diff_failed = true;
                    break :outer;
                }
            }
        }
        // 짝이 없으면(그 사이 Term이 닫혔다) 결과를 그냥 버린다 — 아래 deinit이 어느 경우든 해제한다.
        diff_result.deinit(git_backend_mod.worker_allocator);
        self.metal_dirty = true;
    }
    while (backend.takeResult()) |taken| {
        var result = taken;
        if (result.request_id != self.git_inflight) {
            result.deinit(git_backend_mod.worker_allocator); // 늦게 온 응답이 최신 화면을 덮지 않는다
            continue;
        }
        self.git_inflight = 0;
        if (!result.ok) {
            // 실패한 읽기는 결과로 삼지 않는다(섹션이 옛 시점과 섞이지 않게). in-flight만 풀고 상태를 남긴다.
            result.deinit(git_backend_mod.worker_allocator);
            self.git_failed = true;
            self.metal_dirty = true;
            continue;
        }
        self.git_failed = false;
        if (self.git_result) |*old| old.deinit(git_backend_mod.worker_allocator);
        self.git_result = result;
        // 새 목록이다 — 옛 화면을 겨냥한 늦은 클릭을 거부한다(세대 대조).
        bumpScmDockGeneration(self);
        // 목록이 짧아졌으면 offset을 창 안으로 당긴다. 발행·렌더는 `scmEffectiveScrollPx`가 매번
        // 유계화하지만 **raw 값은 그대로 남아**, 목록이 다시 길어질 때 그 자리로 튄다. 탐색기가
        // `updateFileTree`에서 같은 일을 하는 것과 같은 자리다.
        scroll_ops.clampScmScroll(self);
        self.metal_dirty = true;
        // 진단은 **수치만** 남긴다 — 경로·브랜치명·상태 원문은 사용자 저장소 내용이라 로그에 넣지 않는다
        // (docs/editor-surface-tooling.md §8.3의 민감정보 경계와 같은 규율).
        // `head`가 0인데 unborn이 아니면 **증감이 통째로 빈 화면**이라는 뜻이라, 그 갈림이 로그에 보여야 한다
        // (목록은 숫자 자리를 조용히 비우므로 화면만 봐서는 "변경이 없다"와 구별되지 않는다).
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.scm).info(
            "git status bytes={d} head={d} staged={d} unborn={} truncated={} req={d}",
            .{
                result.status.len,
                result.numstat_head.len,
                result.numstat_staged.len,
                maru.session.git_status.parseHead(result.status).unborn,
                result.truncated,
                result.request_id,
            },
        );
    }
}

/// 커널 cwd 폴백을 다시 물어보는 주기. syscall이라 매 프레임 돌릴 수 없고, `cd` 반영이 사람 눈에 즉각적으로
/// 보일 만큼은 자주여야 한다 — 에이전트 감지가 쓰는 주기와 같은 급이다(app_session.zig의 `agent_poll_ticks` 주석).
///
/// **tick 카운터가 아니라 시각으로 잰다.** `activeTerminalCwd`는 한 프레임에 여러 번 불린다(탐색기 reveal +
/// 소스 컨트롤 판정 + `refreshGitStatus` 안의 재판정). 호출마다 카운터를 올리면 실효 주기가 호출 수만큼 짧아져
/// 주석이 주장하는 값과 달라진다 — 시각으로 재면 호출 빈도와 무관하게 이 값이 그대로 지켜진다.
const proc_cwd_poll_interval_ns: i128 = 500 * std.time.ns_per_ms;

/// **활성 터미널이 서 있는 폴더.** 소스 컨트롤 뷰와 파일 탐색기가 공유하는 단일 해석 지점이다.
///
/// 출처가 둘이고 순서가 있다:
/// 1. **OSC 7**(셸이 프롬프트마다 보고). 가장 싸고 정확하다 — syscall이 없다.
/// 2. **커널 조회**(`processCwd` seam). OSC 7이 비었을 때의 폴백이다. 비는 경우가 드물지 않다:
///    maru의 셸 통합은 zsh 전용이라 bash/fish는 아예 안 보내고, claude·codex 같은 전체화면 TUI가 시작하며
///    RIS(ESC c)를 보내면 `TerminalCore.fullReset`이 보고된 cwd를 지워 그 프로그램이 떠 있는 내내 비어 있다.
///
/// **터미널이 아닌 Term(파일·브라우저·diff)은 null이다.** 여기서 억지로 값을 만들면, diff를 여는 순간 활성 Term이
/// 웹 Term으로 바뀌면서 저장소가 엉뚱하게 갈린다(`git_repo` 필드 주석이 적은 그 회귀다). 호출자는 null을
/// "모른다 = 직전 판단을 유지한다"로 읽어야 하고, "저장소 없음"으로 읽으면 안 된다.
///
/// **원격 세션도 null이다.** 두 출처 모두 원격에서는 로컬을 가리키기 때문이다: OSC 7은 host authority를 버리고
/// 경로만 남기므로 원격 경로가 로컬 경로처럼 보이고, 커널 조회는 애초에 로컬 `ssh` 클라이언트 프로세스의 cwd를
/// 답한다. 그대로 쓰면 **로컬에 같은 경로가 있을 때 남의 저장소를 원격인 척 보여 주고**, 거기서 stage/discard 하면
/// 보고 있지도 않은 로컬 파일이 바뀐다. 링크 감지가 정확히 같은 함정을 이미 겪었고 같은 판정으로 막았다
/// (`linkScopesForTerm`·docs/ssh-integration.md §9.4). 저장소 목록은 그보다 더 위험하므로 같은 규율을 따른다.
///
/// **한계(정직하게)**: maru 통합을 거치지 않은 맨 `ssh`이고 원격에 OSC 7 보고자도 없으면 두 신호가 다 비어
/// 원격임을 알 수 없다. 링크 감지와 같은 한계이며, 그 경우 커널 폴백이 로컬 cwd를 답한다.
///
/// **버퍼 크기를 타입으로 고정한다**(`[]u8`이 아니라 `*[max_path_bytes]u8`). 아래에서 OSC 7 보고가 버퍼보다 길면
/// 커널 조회로 내려가는데, 그 선택은 "버퍼가 `PATH_MAX`이므로 그보다 긴 보고는 어떤 syscall도 받지 않는 경로다"에
/// 기대고 있다. 호출자가 더 작은 버퍼를 주면 그 전제가 깨져 **멀쩡한 OSC 7 값이 조용히 버려지고** TUI 실행 중
/// 커널이 답하는 다른 폴더가 대신 쓰인다. 관례로 두지 않고 타입으로 못 박는다 — 호출부는 이미 이 크기를 넘긴다.
pub fn activeTerminalCwd(self: *AppSession, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (self.tabs.items.len == 0) return null;
    return termCwd(self, pane_ops.activePane(self).activeTerm(), buf);
}

/// 위 규칙을 **임의의 Term**에 적용한 것. `activeTerminalCwd`는 이제 "활성 Term을 골라 이걸 부른다"일 뿐이라
/// 두 함수의 판정은 정의상 같다.
///
/// **왜 Term 단위가 필요한가**: 사이드바는 활성 Term 하나가 아니라 **모든 탭의 모든 Term**에 대해 폴더·브랜치
/// 줄을 그린다(docs/sidebar-agent-list.md §2.1). 예전에는 사이드바만 이 2단 규칙 밖에 있어 관측(OSC 7)만 봤고,
/// 그래서 OSC 7이 없는 Term — 셸 통합이 없는 bash/fish, 그리고 `zsh -l -i -c "exec <provider> --resume"`로
/// 띄워 프롬프트를 한 번도 그리지 않는 **재개 Term** — 에서는 소스 컨트롤 뷰가 저장소를 멀쩡히 찾는 동안
/// 사이드바만 "cwd 없음"으로 폴더줄·브랜치줄을 통째로 지웠다. 축이 하나여야 두 뷰가 같은 곳을 본다
/// (`followActiveTerminalRepo`·`followActiveTerminalCwd`가 같은 이유로 이미 이 함수를 공유한다).
pub fn termCwd(self: *AppSession, term: *Term, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (term.kind != .terminal) return null;
    term_ops.refreshTermObservation(self, term, false, false);
    // OSC 7 authority가 로컬이 아니다 → 보고된 경로는 원격 것이다.
    if (app_session_mod.termCwdIsRemote(term)) return null;
    // 보고자가 없어도 maru가 아는 ssh 세션이면 커널 폴백이 ssh 클라이언트를 가리키므로 물어보지 않는다.
    if (term.rt.observation.ssh_remote_dest_present) return null;
    if (term.rt.observation.availability != .unavailable) {
        const cwd = term.rt.observation.cwd.items;
        // `cwd.len > buf.len`이면 커널 조회로 내려간다. 버퍼는 `PATH_MAX`라, 그보다 긴 보고는 **실제로 열 수 없는
        // 경로**다(어떤 syscall도 받지 않는다). 그런 값을 쓰느니 커널이 아는 진짜 cwd를 쓰는 편이 맞다.
        if (cwd.len > 0 and cwd.len <= buf.len) {
            @memcpy(buf[0..cwd.len], cwd);
            return buf[0..cwd.len];
        }
    }
    return procCwdCached(self, term, buf);
}

/// 커널 cwd 폴백 + 저주기 캐시. 매 프레임 `proc_pidinfo`를 부르면 OSC 7이 없는 셸에서 프레임마다 syscall이 된다.
///
/// **캐시는 Term별이다**(`term.rt.proc_cwd_*`). 예전에는 AppSession에 한 칸뿐이었고 "그 칸이 어느 Term 것인가"를
/// 들고 있다가 다르면 주기를 무시하고 다시 물었다 — 활성 Term 하나만 물어보던 시절의 보정이다. 사이드바가 같은
/// 규칙을 쓰면서 rebuild가 모든 Term을 훑게 되자 그 한 칸은 Term들이 서로 밀어내는 자리가 됐다(캐시가 무의미해지고
/// rebuild마다 Term 수만큼 syscall). Term별로 두면 그 보정 자체가 필요 없다 — 각 Term이 자기 시각으로 자기 답을 한다.
fn procCwdCached(self: *AppSession, term: *Term, buf: []u8) ?[]const u8 {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (now - term.rt.proc_cwd_polled_ns >= proc_cwd_poll_interval_ns) {
        term.rt.proc_cwd_polled_ns = now;
        term.rt.proc_cwd_len = 0;
        if (self.backendFor(term).processCwd(term.rt.handle, &term.rt.proc_cwd_buf)) |cwd| {
            term.rt.proc_cwd_len = cwd.len;
        }
    }
    const len = term.rt.proc_cwd_len;
    if (len == 0 or len > buf.len) return null;
    @memcpy(buf[0..len], term.rt.proc_cwd_buf[0..len]);
    return buf[0..len];
}

/// 사이드바 카드·에이전트 행·상태바의 **경로줄이 표시할 cwd**. `termCwd`와 같은 2단 규칙에 **원격 표시**만
/// 더한 것이다.
///
/// 원격을 따로 가르는 이유: `termCwd`는 원격에서 null을 낸다(커널 조회가 로컬 ssh 클라이언트의 cwd를 답해
/// 남의 저장소를 원격인 척 보여 주기 때문 — 그 판단은 저장소 선택에 맞다). 그런데 **표시**는 다른 문제다.
/// 원격 세션에서 이 줄은 "지금 어느 호스트의 어디에 있나"를 알려 주는 유일한 자리이므로, 관측이 준 경로를
/// 그대로 쓰고 호출자가 host 접두를 붙인다(docs/ssh-integration.md §9.3). 그 경로로 로컬 `.git`을 읽지는
/// 않는다 — 브랜치 파생은 계속 `termCwd`(원격이면 null)를 거친다.
pub fn termCwdForDisplay(self: *AppSession, term: *Term, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (term.kind != .terminal) return null;
    term_ops.refreshTermObservation(self, term, false, false);
    if (app_session_mod.termCwdIsRemote(term)) {
        if (term.rt.observation.availability == .unavailable) return null;
        const cwd = term.rt.observation.cwd.items;
        if (cwd.len == 0 or cwd.len > buf.len) return null;
        @memcpy(buf[0..cwd.len], cwd);
        return buf[0..cwd.len];
    }
    return termCwd(self, term, buf);
}

/// 목록이 대상으로 삼을 **저장소 루트**. 우선순위가 곧 제품 동작이라 순서를 지킨다
/// (docs/editor-surface-dock.md §3.5 "대상 저장소를 정하는 규칙").
///
/// 1. **활성 터미널의 cwd.** 사용자가 "지금 보고 있는 것"의 권위다. 파일 탐색기도 같은 축으로 움직인다
///    (docs/file-explorer.md §1 — 활성 터미널 cwd를 따라 reveal한다). 두 뷰가 다른 저장소를 보면 안 된다.
/// 2. **직전에 목록을 읽은 저장소**(`git_repo`). 터미널이 cwd를 모를 때 쓴다 — 특히 **diff를 열면 활성 Term이
///    웹 Term이 되어 1번이 null**이 되는데, 그때 3번으로 떨어지면 열려 있는 diff와 목록이 다른 저장소를 가리킨다.
/// 3. **파일 탐색기 root.** 터미널이 아직 아무것도 보고하지 않은 첫 진입(창을 열자마자 도크를 편 경우)의 바닥값.
///
/// 셋 다 실패하면 null이고 뷰는 빈 안내를 낸다.
///
/// **"없다"와 "모른다"를 구별해야 하는 호출자는 `gitRepoTarget`을 쓴다.** 이 함수는 둘을 같은 null로 뭉갠다.
pub fn gitRepoRoot(self: *AppSession, buf: []u8) ?[]const u8 {
    return switch (gitRepoTarget(self, buf)) {
        .repo => |found| found,
        .none, .unknown => null,
    };
}

/// 위 판정의 **3-상태 결과**(docs/editor-surface-dock.md §3.5 "판정은 3-상태다").
///
/// `?[]const u8` 하나로는 표현할 수 없는 구별이 있다 — 두 결론이 호출자에게 **반대되는** 행동을 요구하기 때문이다:
/// `.none`은 화면에 남은 목록을 **버려야** 하고, `.unknown`은 직전 판단을 **유지해야** 한다. 같은 null로 돌려주던
/// 동안 호출자는 구별할 수 없어 안전한 쪽(유지)으로만 읽었고, 그래서 저장소 아닌 폴더로 `cd` 하면 옛 목록이 그대로
/// 남았다(사용자 보고 2026-08-12 — 아래 `gitRepoTarget`의 1순위 주석이 금지한 상태가 호출자 쪽에서 재현된 것이다).
pub const RepoTarget = union(enum) {
    /// 대상 저장소가 확정됐다. slice는 호출자가 넘긴 `buf` 안을 가리킨다.
    repo: []const u8,
    /// **터미널이 답했고 그 폴더는 저장소가 아니다.** 확정된 "저장소 없음"이라 2·3순위로 내려가지 않는다.
    none,
    /// **아무도 답을 못 줬다**(파일 Term·원격 세션이고 2·3순위도 비었다). 모르는 것이므로 직전 판단을 유지한다.
    unknown,
};

pub fn gitRepoTarget(self: *AppSession, buf: []u8) RepoTarget {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (activeTerminalCwd(self, &cwd_buf)) |cwd| {
        // **터미널이 답했으면 그 답으로 끝난다.** 그 폴더가 저장소가 아니면 결론은 "저장소 없음"이지
        // "아래 순위로 내려간다"가 아니다 — 내려가면 저장소 아닌 곳으로 `cd` 했을 때 옛 저장소에 영영
        // 고정돼(2·3순위가 계속 답을 준다) 탐색기는 새 폴더를, 목록은 옛 저장소를 가리키게 된다.
        // 아래 두 순위는 **터미널이 답을 못 준 경우**(파일 Term·원격 세션)의 것이다.
        if (repoRootForCached(self, cwd, buf)) |found| return .{ .repo = found };
        return .none;
    }
    // **2순위도 캐시를 거친다.** diff를 열어 둔 상태(활성 Term이 파일 Term)는 흔한데, 그때 1순위가 null이라
    // 매 tick 여기로 내려온다 — 캐시 없이 두면 walk-up syscall이 그 상태에서 프레임마다 그대로 돈다.
    if (self.git_repo) |current| {
        if (repoRootForCached(self, current, buf)) |found| return .{ .repo = found };
    }
    // 3순위는 캐시하지 않는다 — 1·2순위가 **둘 다** 답을 못 준 첫 진입에만 도는 경로라 매 프레임 반복되지 않고,
    // root가 여러 개면 캐시 슬롯 하나로는 오히려 서로를 밀어낸다.
    for (self.file_tree.roots.items) |root| {
        if (repoRootFor(root.path, buf)) |found| return .{ .repo = found };
    }
    return .unknown;
}

/// 저장소 판정이 사용자에게 보이는 **두 문구**. 도크의 빈 안내와 브랜치 메뉴가 같은 판정을 쓰므로 문자열도
/// 한 자리에 둔다 — 복붙해 두면 한쪽만 고쳐져 같은 상태를 두 가지로 말한다(적대적 검증에서 브랜치 메뉴가
/// 실제로 옛 단정에 남아 있었다).
pub const notice_not_a_repo = "git 저장소가 아닙니다";
pub const notice_repo_unknown = "저장소를 확인할 수 없습니다";
/// 읽기는 성공했고 바뀐 것이 없다. **위 둘과 같은 표에 둔다** — 사용자에게는 셋 다 "목록이 비었다"로
/// 보이지만 서로 다른 사실이고, 문구를 흩어 두면 한쪽만 고쳐져 같은 화면이 두 가지를 말한다.
/// 이 문장만 목록 컴포넌트가 그린다(나머지 둘은 목록을 그리기 전에 나온다).
pub const notice_no_changes = "변경 사항 없음";

/// 목록이 비었을 때 도크가 낼 **안내 문구**. 우선순위는 실행할 수 없음 → 볼 것이 없음 → 실패 → 진행 중이다.
///
/// **`gitRepoRoot`가 아니라 `gitRepoTarget`을 본다.** 전자는 "저장소가 아니다"(`.none`)와 "모른다"(`.unknown` —
/// 원격 세션·파일 Term이라 물어볼 곳이 없다)를 같은 null로 뭉개므로, 그걸로 문구를 고르면 후자까지 "저장소가
/// 아닙니다"로 단정해 **저장소 안에 서 있는 사용자에게 없는 사실을 알린다**(사용자 보고 2026-08-13: 로컬 세션이
/// 원격으로 오판된 동안 이 문구가 진짜 원인을 가렸다).
///
/// 렌더 안 표현식으로 두지 않고 함수로 뺀 이유도 그것이다 — 세 상태를 테스트에서 각각 짚을 수 있어야 두 결론이
/// 다시 한 문구로 접히는 회귀를 단위로 잡는다.
pub fn scmEmptyNotice(self: *AppSession, probe: []u8) []const u8 {
    if (self.git_missing) return "git이 설치되어 있지 않습니다";
    return switch (gitRepoTarget(self, probe)) {
        .none => notice_not_a_repo,
        .unknown => notice_repo_unknown,
        .repo => if (self.git_failed) "git 읽기에 실패했습니다" else "읽는 중…",
    };
}

/// `repoRootFor`의 walk-up을 저주기로 캐시한다. **매 프레임 도는 경로이기 때문**이다: `repoRootFor`는 루트까지
/// 올라가며 경로 구성요소마다 `access(2)`를 한 번씩 쓴다(깊은 cwd면 호출당 여덟 번쯤). tick이 이걸 프레임마다
/// 돌리면 blocking syscall이 초당 수천 번이 되어 프레임 페이싱과 배터리를 갉는다.
///
/// 캐시 키는 cwd 문자열이고, cwd가 그대로여도 `proc_cwd_poll_interval_ns`마다 다시 걷는다 — 같은 폴더에서
/// `git init`을 하면 답이 바뀌므로 영구 캐시는 틀린다. 이 주기가 그 반영 지연의 상한이다.
///
/// 결과는 항상 cwd의 **접두**다(walk-up이 상위로만 간다). 그래서 root를 따로 저장하지 않고 길이만 들고 있는다.
fn repoRootForCached(self: *AppSession, cwd: []const u8, buf: []u8) ?[]const u8 {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    const same_cwd = self.repo_root_cwd_len == cwd.len and
        std.mem.eql(u8, self.repo_root_cwd_buf[0..self.repo_root_cwd_len], cwd);
    if (!same_cwd or now - self.repo_root_walked_ns >= proc_cwd_poll_interval_ns) {
        self.repo_root_walked_ns = now;
        self.repo_root_cwd_len = 0;
        self.repo_root_len = 0;
        if (cwd.len <= self.repo_root_cwd_buf.len) {
            @memcpy(self.repo_root_cwd_buf[0..cwd.len], cwd);
            self.repo_root_cwd_len = cwd.len;
            var probe: [std.fs.max_path_bytes]u8 = undefined;
            if (repoRootFor(cwd, &probe)) |root| {
                // **접두임을 확인하고서만 길이로 줄인다.** walk-up이 상위로만 가므로 접두인 것이 맞지만,
                // 그 가정이 틀리면 `cwd[0..len]`은 조용히 **실재하는 다른 디렉터리**가 되어 남의 저장소를
                // 보여 준다. 가정을 검사로 바꾼다 — 어긋나면 캐시하지 않고 이번 답만 그대로 쓴다.
                if (root.len <= cwd.len and std.mem.eql(u8, root, cwd[0..root.len])) {
                    self.repo_root_len = root.len;
                } else {
                    self.repo_root_cwd_len = 0; // 캐시 무효 — 다음 호출도 직접 걷는다
                    if (root.len > buf.len) return null;
                    @memcpy(buf[0..root.len], root);
                    return buf[0..root.len];
                }
            }
        }
    }
    if (self.repo_root_len == 0 or self.repo_root_len > buf.len) return null;
    @memcpy(buf[0..self.repo_root_len], self.repo_root_cwd_buf[0..self.repo_root_len]);
    return buf[0..self.repo_root_len];
}

/// 목록 모델을 만든다. **렌더·포인터·스크롤 상한이 전부 이 함수를 지난다** — 각자 `scm_view.build`를
/// 부르던 동안에는 인자 하나만 어긋나도 그린 자리와 눌리는 자리가 갈렸다(입력을 한 곳에서 고른다).
///
/// **증감의 출처는 셋이다**: 행은 자기가 선 섹션의 범위(`--cached` / 작업트리)를 쓰고, 요약 줄의 합계만
/// `HEAD ↔ 작업트리` 한 범위에서 낸다 — 두 섹션의 numstat을 더하면 `MM` 파일이 두 번 세어진다.
///
/// **합계의 폴백 조건이 "출력이 비었나"가 아니라 "unborn인가"인 이유**(적대적 검증 2026-08-14): 평범한
/// 저장소에서 `numstat_head`가 실패해도 출력은 똑같이 비어 있다. 빈 값으로 갈아타면 **index 기준 숫자를
/// HEAD 기준인 척** 보여 준다 — 사용자는 커밋 직전에 그 숫자를 본다.
pub fn buildScmModel(self: *AppSession, out: []scm_view.Row, scratch: []u8) ?scm_view.Model {
    const result = self.git_result orelse return null;
    const total = if (maru.session.git_status.parseHead(result.status).unborn)
        result.numstat_staged
    else
        result.numstat_head;
    // **잘림은 모델까지 간다.** 플래그를 여기서 삼키면 화면이 "변경이 없다"와 같은 모습이 되는데 원인은 정반대다.
    return scm_view.build(
        result.status,
        result.numstat_staged,
        result.numstat_worktree,
        total,
        self.scm_collapsed,
        self.scm_expanded,
        result.truncated,
        out,
        scratch,
    );
}

/// **셀 그리드 히트테스트(`scmRowAt`·`scmRowAtIndex`·`scmTotalRows`)는 P1b에서 제거했다.** 좌표를 행
/// 인덱스로 바꾸는 일은 이제 published component tree 하나가 하고(`scm_dock.zig`), 그 tree가 렌더와
/// 같은 기하를 쓴다 — 두 곳이 각자 행 높이를 곱하던 것이 "그린 자리와 눌리는 자리"가 어긋난 원인이었다.
/// 그 행이 가리키는 비교를 연다. 경로는 저장소 루트 기준이므로 절대경로를 만들어 Term identity로 쓴다.
pub fn openDiffForScmRow(self: *AppSession, row: scm_view.FileRow) void {
    // git 출력이 이상하거나 우리 파싱이 어긋나면 루트 밖 경로가 여기까지 올 수 있다. **여는 단계에서** 막는다 —
    // 백엔드도 같은 판정을 하지만, 열지 말아야 할 것으로 Term을 만들면 사용자에게 빈 화면이 남는다(§6 심층 방어).
    if (!maru.session.repo_path.isSafeRelative(row.path)) {
        self.showNotice("저장소 밖을 가리키는 경로는 열지 않습니다");
        return;
    }
    // **목록을 읽은 그 저장소**를 쓴다. 여기서 다시 구하면 첫 diff가 열린 뒤 활성 Term이 웹 Term이라
    // cwd 폴백이 빈 값을 보고 null이 되어 두 번째 행부터 조용히 무시된다(손 확인에서 그랬다).
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = self.git_repo orelse (gitRepoRoot(self, &repo_buf) orelse return);
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ repo, row.path }) catch return;
    // 하위 모듈은 텍스트 비교가 없다(커밋 포인터라 blob이 없고 작업트리 쪽은 디렉터리다 — 실측).
    // 빈 화면을 여느니 이유를 말한다.
    if (row.submodule) {
        self.showNotice("하위 모듈은 비교를 표시하지 않습니다");
        return;
    }
    // **섹션이 곧 기준이다**(§3.5.2 — 2026-08-14 2차 결정으로 복귀). 행이 선 그룹이 비교 범위를 정하므로
    // 위 행(스테이지된 변경)은 `HEAD ↔ index`, 아래 행(변경 사항)은 `index ↔ 작업트리`를 연다. 같은 파일이
    // 양쪽에 있어도 base가 유일성 키에 들어 서로를 덮지 않는다.
    const base: dock_panel.DiffBase = if (row.conflicted)
        .conflict
    else if (row.untracked)
        .untracked
    else switch (row.section) {
        .staged => .staged,
        .changes => .unstaged,
    };
    // rename은 왼쪽이 옛 경로다(`R` 행의 orig_path). 스테이지된 rename만 그 구분이 의미 있다.
    openDiffTerm(self, repo, abs, row.path, row.orig_path, base);
}

/// 소스 컨트롤 행을 눌렀을 때 그 비교를 여는 지점. **유일성 키는 `(경로, kind, base)`**라 같은 파일의
/// 스테이지·미스테이지 diff가 서로를 덮지 않는다(docs/editor-surface-dock.md §3.5).
pub fn openDiffTerm(
    self: *AppSession,
    repo: []const u8,
    abs_path: []const u8,
    rel_path: []const u8,
    orig_rel_path: ?[]const u8,
    base: dock_panel.DiffBase,
) void {
    if (diffTermFor(self, abs_path, base)) |existing| {
        _ = self.activateExistingFileTerm(existing);
        return;
    }
    const opened = pane_ops.openFileTermInActivePane(self, abs_path, .diff) catch return;
    const entry = opened.term.file_entry orelse return;
    entry.diff_base = base;
    // 옛 값이 있으면 먼저 푼다 — 대입만 하면 그 할당이 회수 불가가 된다(리뷰에서 잡힌 누수).
    self.freeDiffPaths(entry);
    entry.diff_rel_path = self.allocator.dupe(u8, rel_path) catch &.{};
    // rename은 왼쪽이 **옛 경로**다. 새 경로로 `HEAD:`를 읽으면 그 blob이 없어 비교가 통째로 실패한다.
    entry.diff_orig_rel_path = if (orig_rel_path) |o| (self.allocator.dupe(u8, o) catch &.{}) else &.{};
    // **저장소 루트는 호출자에게서 받는다.** 여기서 다시 구하면 방금 활성화된 diff 웹 Term의 cwd(빈 값)를 보고
    // null이 되어 영영 실패로 굳는다(리뷰에서 잡힌 결함) — 목록을 만든 그 루트를 그대로 쓴다.
    entry.diff_repo = self.allocator.dupe(u8, repo) catch &.{};
    self.requestDiffContent(entry);
    // 재시도 창(6초)은 **요청 시점**부터 흐른다. 네이티브가 아니면 무동작이다.
    editor_diff_ops.markRequested(self, opened.term);
}

pub fn diffTermFor(self: *AppSession, abs_path: []const u8, base: dock_panel.DiffBase) ?*Term {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (entry.kind != .diff or entry.diff_base != base) continue;
                if (std.mem.eql(u8, entry.path, abs_path)) return term;
            }
        }
    }
    return null;
}

/// term의 git 브랜치(owned 캐시). 그 surface의 cwd(OSC 7)가 바뀌었을 때만 .git/HEAD를 walk-up해 재계산한다
/// (사이드바는 매 프레임 빌드되므로 fs 읽기를 cwd 변경으로 게이트). 없으면 null. 반환은 term 소유(다음 cwd 변경/
/// teardown까지 유효). 파생값이라 영속 안 함 — restore가 cwd에서 재도출.
pub fn termGitBranch(self: *AppSession, term: *Term) ?[]const u8 {
    // 관측만 보던 자리다. 이제 소스 컨트롤·탐색기와 **같은 2단 규칙**을 쓴다 — 그래야 같은 화면에서 목록은
    // 저장소를 찾았는데 사이드바 카드만 브랜치를 못 찾는 일이 없다. `termCwd`가 관측 refresh와 원격 가드를
    // 모두 맡으므로 여기서 다시 하지 않는다.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = termCwd(self, term, &buf) orelse "";
    return termGitBranchForCwd(self, term, cwd);
}

/// 브랜치 캐시의 **백스톱** 주기. 이 값이 갱신의 1차 수단이 아니다 — `.git` 변경 이벤트가 1차이고
/// (`invalidateTermGitBranches`), 이 주기는 **그 이벤트가 닿지 않는 저장소**를 위한 마지막 그물이다: 터미널만
/// 그 폴더에 있고 탐색기 root도 SCM 뷰도 아닌 저장소는 감시 대상이 아니라 이벤트가 오지 않는다.
///
/// 그래서 `proc_cwd_poll_interval_ns`(0.5초)보다 훨씬 길게 잡는다. 사이드바는 매 프레임, **term마다** 이 경로를
/// 부르므로 짧은 주기는 tick 귀속 blocking FS(walk-up `access` + `.git/HEAD` open/read/alloc)를 term 수만큼
/// 만든다 — `docs/performance-budget.md`가 FS를 tick 귀속 0으로 지향하는 것과 반대 방향이다.
pub const git_branch_backstop_interval_ns: i128 = 5 * std.time.ns_per_s;

/// `.git` 이벤트가 앞당기는 재계산의 **하한**. 이벤트 하나하나를 즉시 재계산으로 바꾸면 rebase·대량 checkout이
/// `.git`을 수백 번 건드리는 동안 프레임마다 term 수만큼 fs를 읽는다(폴링보다 나빠진다). `refreshGitStatus`가
/// in-flight 가드로 이벤트 몰림을 흡수하는 것과 같은 규율이다.
pub const git_branch_event_floor_ns: i128 = 200 * std.time.ns_per_ms;

/// `.git`이 바뀌었다 — 모든 term의 브랜치 캐시 만료를 **앞당긴다**(갱신의 1차 경로).
///
/// `git checkout`은 cwd를 바꾸지 않으므로 OSC 7으로는 감지되지 않고, 브랜치가 든 `.git/HEAD`만 바뀐다. 그 변경은
/// 이미 `fileTreeChanged`로 들어와 SCM 목록을 다시 읽게 하고 있었다 — 같은 신호를 브랜치 표시에도 연결해 두
/// 표시가 **같은 이벤트로** 움직이게 한다(그러지 않으면 목록은 갱신됐는데 상태바만 옛 브랜치가 남는다).
///
/// 값을 0으로 밀지 않는 이유는 `git_branch_event_floor_ns` 주석에 있다.
pub fn invalidateTermGitBranches(self: *AppSession) void {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    const target = now - git_branch_backstop_interval_ns + git_branch_event_floor_ns;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        // **앞당기기만 한다.** 이미 더 이른 만료(오래 안 읽은 term·아직 안 읽은 0)를 이 값으로 덮으면 이벤트가
        // 오히려 갱신을 **늦춘다** — 무효화가 지연 장치가 되는 역전이다.
        if (term.git_branch_polled_ns > target) term.git_branch_polled_ns = target;
    };
    self.metal_dirty = true; // 다음 프레임에 다시 그려야 새 브랜치가 보인다
}

/// 이미 확보한 runtime observation `cwd`로 git 브랜치 캐시를 계산한다. blocking .git/HEAD 읽기와 runtime 관측을
/// 분리하며, sidebar와 control-plane이 이 단일 파생 경로를 공유한다. 캐시 키·재계산 로직은 단일 출처(재구현 금지).
pub fn termGitBranchForCwd(self: *AppSession, term: *Term, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return null;
    // 원격 cwd에는 로컬 `.git`이 없다. 읽어 봐야 항상 실패인데다, 같은 경로가 로컬에도 우연히 있으면 **엉뚱한
    // repo의 브랜치**를 원격 세션 카드에 붙인다. 그래서 파일을 열기 전에 끊는다(ssh-integration.md §9.4).
    if (app_session_mod.termCwdIsRemote(term)) return null;
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (term.git_branch_cwd) |c| {
        // 캐시 적중은 **cwd가 같고 백스톱 주기 안일 때만**이다. cwd만 키로 쓰면 같은 폴더에서 일어난 변화가
        // 영영 반영되지 않는다 — `git checkout`으로 브랜치를 바꿔도, `git init`으로 저장소를 만들어도, 저장소를
        // 지워도 cwd는 그대로다(마지막 경우가 실제로 드러났다: 도크는 "git 저장소가 아닙니다"인데 상태바는 옛
        // 브랜치를 계속 표시).
        //
        // **갱신의 1차 경로는 이 주기가 아니라 `.git` 변경 이벤트**(`invalidateTermGitBranches`)다. 사이드바는
        // 매 프레임, term마다 이 함수를 부르므로 주기를 짧게 잡으면 그 자체가 tick 귀속 blocking FS가 된다.
        if (std.mem.eql(u8, c, cwd) and now - term.git_branch_polled_ns < git_branch_backstop_interval_ns)
            return term.git_branch;
    }
    term.git_branch_polled_ns = now;
    // cwd 변경 또는 백스톱 만료 → 재계산(옛 캐시 해제 후 갱신).
    if (term.git_branch) |b| self.allocator.free(b);
    if (term.git_branch_cwd) |c| self.allocator.free(c);
    term.git_branch = readGitBranch(self.io, self.allocator, cwd);
    term.git_branch_cwd = self.allocator.dupe(u8, cwd) catch null;
    if (diag_gate.maruDebugEnabled()) std.log.scoped(.git).info("branch: cwd={s} -> {?s}", .{ cwd, term.git_branch });
    return term.git_branch;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

/// cwd(OSC 7 보고)에서 부모로 올라가며 `<dir>/.git/HEAD`를 찾아 git 브랜치명을 도출한다(owned 슬라이스, 호출자 해제).
/// `ref: refs/heads/<branch>`면 그 branch, detached(raw SHA)면 짧게 7자. 못 찾으면 null(브랜치 표시 없음).
/// 절대 경로만, walk-up은 루트까지(깊이 128 가드). 베이스: git이 cwd부터 부모로 .git을 찾는 방식. worktree(.git가
/// gitdir: 파일)는 best-effort 미지원(.git/HEAD 못 읽으면 null) — 후속. fs 읽기는 cwd 변경 시에만(termGitBranch 캐시).
pub fn readGitBranch(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0 or cwd.len >= std.fs.max_path_bytes or !std.fs.path.isAbsolute(cwd)) return null;
    var dir: []const u8 = cwd;
    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const head_path = std.fmt.bufPrint(&buf, "{s}/.git/HEAD", .{dir}) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096))) |data| {
            defer allocator.free(data);
            // .git/HEAD가 있으니 이미 repo 안 — 파싱 결과가 null이어도 더 올라가지 않는다.
            return if (parseGitHead(data)) |b| (allocator.dupe(u8, b) catch null) else null;
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len >= dir.len) return null; // 진전 없음(루트 도달)
        dir = parent;
    }
    return null;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

/// `.git/HEAD` 내용에서 브랜치명을 뽑는 순수 파서(입력 슬라이스 참조 반환 — 할당 없음). `ref: refs/heads/<branch>`면
/// branch, detached(raw SHA ≥7 hex)면 짧게 7자, 그 외(빈 ref·쓰레기)면 null. readGitBranch가 fs 읽은 뒤 호출·dupe.
pub fn parseGitHead(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    const ref_prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const branch = trimmed[ref_prefix.len..];
        return if (branch.len == 0) null else branch;
    }
    return if (isHexStr(trimmed) and trimmed.len >= 7) trimmed[0..7] else null;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub fn isHexStr(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return s.len > 0;
}
