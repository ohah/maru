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
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
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
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = gitRepoRoot(self, &repo_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.allocator, self.io) catch return;
    }
    // 실행 파일을 먼저 확정한다. 못 찾으면 **실행을 시도하지 않고** 미설치로 표시한다(docs/editor-surface.md §6).
    // 후보 열거에만 PATH를 쓰고 exec는 확정된 절대경로로 한다(셸·execvp 경유 없음 = PATH hijack 차단 유지).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse {
        self.git_missing = true;
        self.metal_dirty = true;
        return;
    };
    self.git_missing = false;
    ensureGitWatch(self, repo);
    rememberGitRepo(self, repo);
    self.git_request_seq += 1;
    const snapshot = if (self.turn_ring.latest()) |snap| snap.oid() else "";
    if (self.git_backend.?.submit(git_exe, repo, snapshot, self.turnIndexPath() orelse "", self.git_request_seq)) {
        self.git_inflight = self.git_request_seq;
    }
}

/// 목록을 읽은 저장소를 기억한다. 같은 값이면 다시 할당하지 않는다.
pub fn rememberGitRepo(self: *AppSession, repo: []const u8) void {
    if (self.git_repo) |current| {
        if (std.mem.eql(u8, current, repo)) return;
        self.allocator.free(current);
        self.git_repo = null;
    }
    self.git_repo = self.allocator.dupe(u8, repo) catch null;
}

/// 그 저장소의 `.git`을 감시 목록에 올린다. 같은 경로면 아무것도 하지 않는다(중복 요청 금지).
pub fn ensureGitWatch(self: *AppSession, repo: []const u8) void {
    if (self.git_watch_path) |current| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "{s}/.git", .{repo}) catch return;
        if (std.mem.eql(u8, current, want)) return;
        self.allocator.free(current);
        self.git_watch_path = null;
    }
    const path = std.fmt.allocPrint(self.allocator, "{s}/.git", .{repo}) catch return;
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

/// 완료된 git 결과를 받아 세션에 싣는다. frame tick에서 호출해도 syscall이 없다.
pub fn drainGitStatus(self: *AppSession) void {
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
        if (!res.ok or res.text.len == 0) {
            res.deinit(self.allocator);
            self.showNotice("브랜치 목록을 읽지 못했습니다"); // 조용히 아무 일도 안 일어나는 것보다 낫다
            continue;
        }
        settings_ops.clearBranchMenuText(self);
        self.branch_menu_text = res.text; // 소유권 인수 — 이름 슬라이스가 이 버퍼를 빌린다
        self.branch_menu_len = git_command.collectBranches(self.branch_menu_text, &self.branch_menu_names);
        settings_ops.openBranchMenu(self);
    }
    while (backend.takeSnapshotResult()) |taken| {
        var snapshot = taken;
        self.turn_ring.push(snapshot.tree, snapshot.surface_id);
        snapshot.deinit(self.allocator);
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
        diff_result.deinit(self.allocator);
        self.metal_dirty = true;
    }
    while (backend.takeResult()) |taken| {
        var result = taken;
        if (result.request_id != self.git_inflight) {
            result.deinit(self.allocator); // 늦게 온 응답이 최신 화면을 덮지 않는다
            continue;
        }
        self.git_inflight = 0;
        if (!result.ok) {
            // 실패한 읽기는 결과로 삼지 않는다(섹션이 옛 시점과 섞이지 않게). in-flight만 풀고 상태를 남긴다.
            result.deinit(self.allocator);
            self.git_failed = true;
            self.metal_dirty = true;
            continue;
        }
        self.git_failed = false;
        if (self.git_result) |*old| old.deinit(self.allocator);
        self.git_result = result;
        // 목록이 짧아졌으면 offset을 창 안으로 당긴다. 발행·렌더는 `scmEffectiveScrollPx`가 매번
        // 유계화하지만 **raw 값은 그대로 남아**, 목록이 다시 길어질 때 그 자리로 튄다. 탐색기가
        // `updateFileTree`에서 같은 일을 하는 것과 같은 자리다.
        scroll_ops.clampScmScroll(self);
        self.metal_dirty = true;
        // 진단은 **수치만** 남긴다 — 경로·브랜치명·상태 원문은 사용자 저장소 내용이라 로그에 넣지 않는다
        // (docs/editor-surface.md §8.3의 민감정보 경계와 같은 규율).
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.scm).info(
            "git status bytes={d}/{d}/{d} truncated={} req={d}",
            .{ result.status.len, result.numstat_staged.len, result.numstat_worktree.len, result.truncated, result.request_id },
        );
    }
}

/// 소스 컨트롤 뷰가 볼 저장소. **탐색기 root → 활성 터미널 cwd** 순으로 찾는다.
///
/// 탐색기를 먼저 보는 이유는 사용자가 트리로 고른 것이 명시적 의사이기 때문이고, 없을 때 활성 터미널 cwd로
/// 내려가는 이유는 탐색기가 애초에 그 cwd를 따라가기 때문이다(file-explorer.md §1 ET-CWD). 폴더를 열지 않은
/// 창에서도 "지금 일하는 저장소"가 보이는 게 맞다 — 그러지 않으면 터미널이 저장소 안인데도 "git 저장소가
/// 아닙니다"가 뜬다(손 확인에서 실제로 그랬다).
///
/// 결과 슬라이스는 `buf`에 담아 돌려준다(walk-up 중간 경로라 어디도 소유하지 않는다).
pub fn gitRepoRoot(self: *AppSession, buf: []u8) ?[]const u8 {
    for (self.file_tree.roots.items) |root| {
        if (repoRootFor(root.path, buf)) |found| return found;
    }
    const term = tab_ops.activeTab(self).activeTerm();
    term_ops.refreshTermObservation(self, term, false, false);
    const cwd = if (term.rt.observation.availability != .unavailable) term.rt.observation.cwd.items else "";
    return repoRootFor(cwd, buf);
}

/// 소스 컨트롤 목록에서 그 좌표의 **파일 행**을 찾는다(섹션 헤더는 null). 렌더와 같은 모델을 같은 입력으로
/// 다시 만들어 판정한다 — 그린 자리와 눌리는 자리가 어긋나지 않게 한다(행 목록을 따로 캐시하지 않는 이유다).
/// 반환 슬라이스는 `git_result` 소유라 다음 갱신 전까지만 유효하다(호출자가 그 자리에서 쓴다).
pub fn scmRowAt(self: *AppSession, x_px: f64, y_px: f64, out: []scm_view.Row, scratch: []u8) ?scm_view.Row {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self) or self.cell_height_px == 0) return null;
    const rect = dock_ops.dockGeometry(self).tree_content;
    if (!layout_math.pointInRect(x_px, y_px, rect)) return null;
    // 스크롤바 위 클릭이 행 선택으로 새면 안 된다(탐색기와 같은 규율, SV3b).
    if (dock_ops.dockListScrollbarGeometry(self)) |geometry| if (geometry.trackContains(x_px, y_px)) return null;
    // **첫 줄은 브랜치 헤더다**(렌더와 같은 자리 규칙 — 여기서 빼지 않으면 한 줄씩 어긋나 엉뚱한 행이
    // 열린다). 헤더는 스크롤 좌표 밖이므로 목록 좌표는 그 아래에서 시작한다.
    const list_top = @as(f64, @floatFromInt(rect.y + self.cell_height_px));
    if (y_px < list_top) return null;
    // 픽셀 스크롤이라 뷰포트 안 y를 content 좌표로 올린 뒤 나눈다(SV3a — 탐색기와 같은 식).
    const content_y = @as(f64, @floatFromInt(scroll_ops.scmEffectiveScrollPx(self))) + (y_px - list_top);
    const index: usize = @intFromFloat(content_y / @as(f64, @floatFromInt(self.cell_height_px)));
    const row = scmRowAtIndex(self, index, out, scratch) orelse return null;
    self.scm_selected_row = index;
    self.metal_dirty = true;
    return row;
}

/// 모델에서 그 인덱스의 행. 렌더와 **같은 입력**으로 만든다(그린 자리와 눌리는 자리를 하나로 유지).
pub fn scmRowAtIndex(self: *AppSession, index: usize, out: []scm_view.Row, scratch: []u8) ?scm_view.Row {
    const result = self.git_result orelse return null;
    const model = scm_view.build(
        result.status,
        result.numstat_staged,
        result.numstat_worktree,
        result.branch_name_status,
        result.branch_numstat,
        result.turn_name_status,
        result.turn_numstat,
        self.scm_collapsed,
        self.scm_expanded,
        out,
        scratch,
    );
    if (index >= model.rows.len) return null;
    return model.rows[index];
}

/// 목록 전체 행 수(스크롤 상한 계산용). 화면 크기와 무관하게 모델이 만들 수 있는 만큼 센다.
///
/// **버퍼는 렌더·hit-test와 같은 크기여야 한다.** 이 값이 스크롤 content 높이의 출처이므로, 여기서만
/// 더 많이 세면 그리지 못하는 행까지 스크롤 범위에 들어가 목록 아래에 빈 곳이 생긴다(적대적 검증에서
/// 512 vs 128로 어긋나 있던 것을 맞췄다).
pub fn scmTotalRows(self: *AppSession) usize {
    var buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const result = self.git_result orelse return 0;
    const model = scm_view.build(
        result.status,
        result.numstat_staged,
        result.numstat_worktree,
        result.branch_name_status,
        result.branch_numstat,
        result.turn_name_status,
        result.turn_numstat,
        self.scm_collapsed,
        self.scm_expanded,
        &buf,
        &scratch,
    );
    return model.rows.len;
}

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
    const base: dock_panel.DiffBase = if (row.conflicted) .conflict else switch (row.section) {
        .staged => .staged,
        .unstaged => .unstaged,
        .untracked => .untracked,
        .branch => .branch,
        .turn => .turn,
    };
    // rename은 왼쪽이 옛 경로다(`R` 행의 orig_path). 스테이지된 rename만 그 구분이 의미 있다.
    openDiffTerm(self, repo, abs, row.path, row.orig_path, base);
}

/// 소스 컨트롤 행을 눌렀을 때 그 비교를 여는 지점. **유일성 키는 `(경로, kind, base)`**라 같은 파일의
/// 스테이지·미스테이지 diff가 서로를 덮지 않는다(docs/editor-surface.md §3.5).
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
    term_ops.refreshTermObservation(self, term, false, false);
    const cwd = if (term.rt.observation.availability != .unavailable) term.rt.observation.cwd.items else "";
    return termGitBranchForCwd(self, term, cwd);
}

/// 이미 확보한 runtime observation `cwd`로 git 브랜치 캐시를 계산한다. blocking .git/HEAD 읽기와 runtime 관측을
/// 분리하며, sidebar와 control-plane이 이 단일 파생 경로를 공유한다. 캐시 키·재계산 로직은 단일 출처(재구현 금지).
pub fn termGitBranchForCwd(self: *AppSession, term: *Term, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return null;
    if (term.git_branch_cwd) |c| {
        if (std.mem.eql(u8, c, cwd)) return term.git_branch; // 캐시 적중(cwd 불변)
    }
    // cwd 변경 → 재계산(옛 캐시 해제 후 갱신).
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
