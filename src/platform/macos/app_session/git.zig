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
const path_shape = maru.path_shape;

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const scroll_ops = @import("scroll.zig");
const diag_gate = app_session_mod.diag_gate;
const git_command = app_session_mod.git_command;
const git_status = maru.session.git_status; // check-ignore 출력 파서(순수 계층)
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
/// 기준이 바뀌었는데 아직 그 기준으로 못 읽었으면 다시 건다(§3.5).
///
/// **도는 읽기를 버리지 않는다.** 버리면 백엔드가 아직 안 걷힌 결과를 들고 있어 새 제출이 거절될 수
/// 있고(그 슬롯은 깊이 1이다), 그러면 이 갱신이 통째로 사라진다. 옛 기준의 답이 한 프레임 늦게 보였다가
/// 바로잡히는 쪽이, 영영 안 바뀌는 쪽보다 낫다.
///
/// **도는 동안에는 아무것도 안 한다**(적대적 검증 2026-08-19). 이 자리는 tick housekeeping이고 그
/// 블록의 규율이 "blocking I/O를 늘리지 않는다"인데, `refreshGitStatus`는 저장소 walk-up과 git 실행
/// 파일 탐색으로 `access(2)`를 친다 — 플래그가 오래 서 있는 상황(git 없음·저장소 아님)에서 매 프레임
/// 그 질문을 다시 하면 답은 늘 같고 비용만 든다. 그래서 **도는 것이 끝난 뒤 한 번만** 시도하고,
/// 결과와 무관하게 플래그를 내린다: 그때도 못 걸었다면 이유가 지속적인 것이고, 도크를 여는 경로가
/// 어차피 새 읽기를 건다(그 읽기는 이미 고른 기준으로 나간다).
pub fn pumpBaseReread(self: *AppSession) void {
    if (!self.scm_base_reread_pending) return;
    if (self.git_inflight != 0 or self.scm_write_inflight != 0) return; // 아직 도는 중 — 끝나면 이 자리로 온다
    self.scm_base_reread_pending = false;
    refreshGitStatus(self);
}

/// 활성 Term 이 원격이면 그 **SCM 대상**(목적지 · control socket · 원격 cwd). 로컬이면 null.
///
/// RS2 — [계획](../../../../docs/plans/remote-scm.md). 여기가 「원격을 본다」를 정하는 **유일한 자리**다:
/// 목록 읽기도, 뒤따를 diff·쓰기도 이 판정 하나를 공유해야 「목록은 원격인데 클릭은 로컬」이 원리적으로
/// 불가능해진다.
///
/// **control socket 이 실제로 있어야 한다.** 없으면 `ssh` 가 새 연결을 시도하며 비밀번호를 물을 수 있고,
/// 그러면 그 읽기는 영영 안 끝난다(계약 §2.2 ⑸). 그때는 원격 SCM 이 **꺼진 채로** 남는 편이 맞다.
///
/// 슬라이스는 전부 호출자가 준 버퍼를 가리킨다 — 관측 캐시를 그대로 들고 나가면 다음
/// `refreshTermObservation` 이 그 밑을 바꾼다.
pub fn remoteScmTarget(
    self: *AppSession,
    dest_buf: []u8,
    ctl_buf: []u8,
    cwd_buf: []u8,
) ?struct { dest: []const u8, ctl: []const u8, cwd: []const u8 } {
    if (builtin.os.tag != .macos) return null;
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .terminal) return null;
    term_ops.refreshTermObservation(self, term, false, false);
    if (term.rt.observation.availability == .unavailable) return null;
    if (!term.rt.observation.ssh_remote_dest_present) return null;

    const dest = term.rt.observation.ssh_remote_dest.items;
    if (dest.len == 0 or dest.len > dest_buf.len) return null;
    // **원격 경로는 관측(OSC 7)만이 안다.** 커널 조회는 로컬 ssh 클라이언트의 cwd 라 여기서 쓰면 안 된다
    // (§9.4 가 링크 감지에서 막은 그 함정).
    const cwd = term.rt.observation.cwd.items;
    if (cwd.len == 0 or cwd.len > cwd_buf.len) return null;
    if (!std.fs.path.isAbsolute(cwd)) return null;

    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len == 0) return null;
    const ctl = maru.cli.ssh.controlSocketPath(self.allocator, home, dest) catch return null;
    defer self.allocator.free(ctl);
    if (ctl.len > ctl_buf.len) return null;
    // 소켓이 **지금 있는가**. `maru ssh` 가 세션마다 만들고 끊기면 사라진다.
    _ = std.Io.Dir.cwd().statFile(self.io, ctl, .{ .follow_symlinks = false }) catch return null;

    @memcpy(dest_buf[0..dest.len], dest);
    @memcpy(ctl_buf[0..ctl.len], ctl);
    @memcpy(cwd_buf[0..cwd.len], cwd);
    return .{ .dest = dest_buf[0..dest.len], .ctl = ctl_buf[0..ctl.len], .cwd = cwd_buf[0..cwd.len] };
}

pub fn refreshGitStatus(self: *AppSession) void {
    if (self.dock.view != .source_control) return;
    // 목록을 다시 읽는 시점은 **비활성 저장소들의 머리 줄도** 다시 읽을 시점이다(P3d-③) — 그쪽은
    // 감시 대상이 아니라 이 시점 말고는 갱신될 길이 없다. 지우지 않고 낡음 표시만 한다: 지우면 다시
    // 읽는 동안 머리 줄이 "읽는 중…"으로 되돌아가 화면이 깜빡인다.
    scm_dock_ops.markRepoStatusStale(self);
    if (self.git_inflight != 0) return;
    if (self.scm_write_inflight != 0) return; // 위와 같은 이유(§6-1)
    var dest_buf: [max_remote_dest_bytes]u8 = undefined;
    var ctl_buf: [std.fs.max_path_bytes]u8 = undefined;
    var remote_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (remoteScmTarget(self, &dest_buf, &ctl_buf, &remote_cwd_buf)) |r| {
        // **원격 cwd 를 그대로 대상으로 쓴다.** `git -C <cwd>` 가 상위 저장소를 스스로 찾으므로 목록에는
        // 루트가 필요 없다. 루트가 필요한 것은 파일 절대경로를 만드는 자리(diff·열기)이고 그것은 RS3 다.
        submitGitRead(self, r.cwd, .{ .dest = r.dest, .control_path = r.ctl });
        return;
    }
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = gitRepoRoot(self, &repo_buf) orelse return;
    submitGitRead(self, repo, null);
}

/// **이미 해석한 저장소로** 읽기를 건다. `gitRepoRoot`를 다시 부르지 않는 진입점이라, 저장소를 방금 판정한
/// 호출자(`followActiveTerminalRepo`)가 같은 walk-up과 같은 기록을 두 번 하지 않는다.
fn submitGitRead(self: *AppSession, repo: []const u8, remote: ?git_command.Remote) void {
    if (self.dock.view != .source_control) return;
    if (self.git_inflight != 0) return;
    // **쓰기가 도는 동안 읽기를 걸지 않는다**(쓰기 문서 §6-1). 겹치면 `index.lock`에서 뒤엣것이 즉시
    // 실패하고, 무엇보다 그 읽기는 쓰기 **이전** 상태를 담아 와 화면을 되돌린다. 쓰기가 끝나면
    // `drainScmWrite`가 한 번 건다.
    if (self.scm_write_inflight != 0) return;
    // **기억·감시를 실행 파일 탐색보다 먼저** 한다. git이 없어 아래에서 돌아가더라도 "지금 보는 저장소"는
    // 확정된 사실이고, 여기서 안 남기면 호출자가 매 tick 다시 "저장소가 바뀌었다"로 읽어 무효화가 반복된다.
    rememberGitRepo(self, repo);
    rememberGitRepoDest(self, if (remote) |r| r.dest else null);
    // **원격은 감시하지 않는다.** `.git` 을 지켜보는 것은 로컬 파일시스템 감시자이고, 원격 경로를 주면
    // 로컬에 우연히 있는 같은 경로를 감시하게 된다 — 남의 저장소가 바뀔 때마다 원격 목록을 다시 읽는다.
    // 원격 목록의 갱신은 포커스 전환과 사용자의 새로고침이 맡는다(RS2 의 알려진 한계).
    if (remote == null) ensureGitWatch(self, repo);
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
    // **비교 기준을 함께 넘긴다**(§3.5). 고른 것이 없으면 빈 값이고 그러면 `origin/HEAD`다 —
    // 이 하나가 ahead/behind·merge-base·브랜치 범위 셋의 왼쪽이라 여기서 갈리면 화면의 숫자와
    // 그 아래 목록이 서로 다른 질문의 답이 된다.
    const base = scm_dock_ops.scmBaseRefFor(self, repo);
    if (self.git_backend.?.submit(git_exe, repo, base, self.git_request_seq, remote)) {
        self.git_inflight = self.git_request_seq;
        // **여기서만 내린다**(§3.5). 고른 기준이 실제로 argv에 실린 자리가 여기이고, 위의 어느 이른
        // 반환이든 그 선택은 아직 화면에 닿지 않았다 — 그때 플래그를 내리면 조용히 잊는 것이다.
        self.scm_base_reread_pending = false;
    }
}

/// 원격 목적지(`user@host`)의 상한. `ssh` 가 받는 값이고 관측에서 오므로 넉넉히 잡되 유계로 둔다.
pub const max_remote_dest_bytes: usize = 256;

/// 지금 보는 저장소를 **통째로 놓는다**(경로 + 호스트). 원격↔로컬 전환에서 한쪽만 놓으면 짝이 어긋난
/// 상태가 남는다.
fn forgetGitRepo(self: *AppSession) void {
    if (self.git_repo) |path| self.allocator.free(path);
    self.git_repo = null;
    rememberGitRepoDest(self, null); // 안내 정리는 그 함수가 진다(같은 판정을 두 곳에 두지 않는다)
    rememberRemoteRepoRoot(self, null); // 루트도 함께 놓는다 — 셋이 한 쌍이다(경로·호스트·루트)
}

/// 그 목록이 어느 호스트의 것인지 기억한다(null = 로컬). `rememberGitRepo` 와 **같은 자리에서** 부른다 —
/// 둘이 갈리면 경로만 맞고 호스트가 낡은 상태가 생기고, 그것이 곧 원격 목록에 로컬 동작을 거는 길이다.
pub fn rememberGitRepoDest(self: *AppSession, dest: ?[]const u8) void {
    const want = dest orelse {
        const had = self.git_repo_dest;
        if (had) |old| self.allocator.free(old);
        self.git_repo_dest = null;
        // **양방향이다**(적대적 검증 4회차 — 판정자가 잡았다). 로컬 → 원격만 치우고 반대를 빼먹으면,
        // 원격에서 낸 「원격 세션이라 아직 목록만 읽습니다」가 **로컬 목록 위에** 그대로 남는다.
        if (had != null) scm_dock_ops.clearScmWriteError(self);
        return;
    };
    if (self.git_repo_dest) |current| {
        if (std.mem.eql(u8, current, want)) return;
        self.allocator.free(current);
    }
    // **호스트가 바뀌면 직전 동작 결과 줄을 버린다**(적대적 검증 2회차). `rememberGitRepo` 가 같은 일을
    // 하지만 그쪽은 **경로**로만 판정해서, 로컬 `/srv/app` → 원격 `/srv/app` 처럼 경로가 같고 호스트만
    // 바뀌는 전환을 못 본다 — 그때 「원격 세션이라 아직 목록만 읽습니다」가 로컬 목록 위에 그대로 남는다.
    scm_dock_ops.clearScmWriteError(self);
    self.git_repo_dest = self.allocator.dupe(u8, want) catch null;
}

/// 이 비교가 **어느 호스트의 것인지** 열 때 박는다(RS3). `diff_repo` 와 같은 규율이다 — 나중에 세션
/// 상태를 다시 읽으면, diff 를 열어 둔 채 다른 pane 으로 옮겼을 때 그 비교가 **다른 호스트의 것**으로
/// 해석된다. 경로만 보면 원격 `/srv/app` 과 로컬 `/srv/app` 이 같은 값이라 그 오해는 조용히 일어난다.
///
/// **루트가 없으면 목적지도 안 박는다.** 둘은 한 쌍이고, 목적지만 있으면 작업트리 쪽을 못 읽는 채로
/// 「원격 diff」라고 주장하게 된다 — 그 상태는 화면에서 실패와 구별되지 않는다.
fn stampDiffRemote(self: *AppSession, entry: *dock_panel.Entry, repo: []const u8) void {
    const dest = self.git_repo_dest orelse return;
    const root = self.git_repo_remote_root orelse return;
    // ⚠️ **그 비교가 선 저장소가 활성 원격 저장소일 때만 박는다**(적대적 검증 8회차).
    //
    // 목록은 저장소를 여럿 싣고(§3.5.1c), **비활성 저장소 행**도 파일 줄을 낸다 — 그 행을 열면
    // `repo_override` 로 다른 경로가 온다. 활성 목적지를 무조건 박으면 **로컬 저장소 행에 원격 표식**이
    // 붙고, 그 비교는 원격에서 `<원격 루트>/<rel>` 을 읽으려 든다: 없으면 실패하고, 원격에 우연히 같은
    // 경로가 있으면 **남의 파일**을 그 자리에 보여 준다.
    const current = self.git_repo orelse return;
    if (!std.mem.eql(u8, current, repo)) return;
    const owned_dest = self.allocator.dupe(u8, dest) catch return;
    const owned_root = self.allocator.dupe(u8, root) catch {
        self.allocator.free(owned_dest);
        return;
    };
    entry.diff_remote_dest = owned_dest;
    entry.diff_remote_root = owned_root;
}

/// **이 저장소에 쓰기를 걸 때 어디로 보내는가**(RS4a). 셋으로 답한다:
///
/// - `.local` — 로컬 git 으로 그대로 간다.
/// - `.remote` — 그 목적지·소켓으로 보낸다.
/// - `.unavailable` — **보내지 않는다.** 원격 저장소인데 control socket 이 없다. 로컬로 떨어뜨리면
///   원격 경로를 로컬 git 에 넘기는데, 로컬에 우연히 같은 경로가 있으면 **남의 파일을 바꾼다.**
///   읽기(RS3 6회차)에서는 남의 파일을 *보여* 줬고, 쓰기는 *바꾼다* — 더 나쁘다.
///
/// ⚠️ **활성 목적지를 무조건 쓰지 않는다**(RS3 8회차와 같은 함정). 목록은 저장소를 여럿 싣고
/// **비활성 저장소 행**도 동작 버튼을 낸다 — 그 행은 `repo_override` 로 다른 경로를 준다. 활성 목적지를
/// 무조건 붙이면 **로컬 저장소 행의 스테이지가 원격으로** 날아간다. 그래서 `repo` 가 **활성 저장소와
/// 같을 때만** 원격이다.
pub const WriteTarget = union(enum) {
    local,
    remote: struct { dest: []const u8, control_path: []const u8 },
    unavailable,
};

pub fn writeTargetFor(self: *AppSession, repo: []const u8, ctl_buf: []u8) WriteTarget {
    const dest = self.git_repo_dest orelse return .local;
    const current = self.git_repo orelse return .local;
    if (!std.mem.eql(u8, current, repo)) return .local; // 비활성(로컬) 저장소 행
    const ctl = remoteControlSocketFor(self, dest, ctl_buf) orelse return .unavailable;
    return .{ .remote = .{ .dest = dest, .control_path = ctl } };
}

/// 그 목적지의 **control socket 경로**(있을 때만). `remoteScmTarget` 이 활성 Term 에서 대상을 고르는
/// 자리라면, 이쪽은 **이미 정해진 목적지**의 소켓을 되찾는 자리다 — diff 는 열 때 박아 둔 호스트를 쓰므로
/// 활성 Term 을 다시 묻지 않는다(그 사이 pane 이 바뀌었을 수 있다).
///
/// 소켓이 없으면 null — 없는 채로 ssh 를 부르면 새 연결을 열며 비밀번호를 물어 그 읽기가 안 끝난다.
pub fn remoteControlSocketFor(self: *AppSession, dest: []const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    if (dest.len == 0) return null;
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len == 0) return null;
    const ctl = maru.cli.ssh.controlSocketPath(self.allocator, home, dest) catch return null;
    defer self.allocator.free(ctl);
    if (ctl.len > buf.len) return null;
    _ = std.Io.Dir.cwd().statFile(self.io, ctl, .{ .follow_symlinks = false }) catch return null;
    @memcpy(buf[0..ctl.len], ctl);
    return buf[0..ctl.len];
}

/// 원격 저장소 루트를 기억한다(null = 없음/로컬). `git_repo_dest` 와 **같은 규율**이다 — 짝이 어긋나면
/// 원격 목록을 보면서 옛 루트로 파일을 열게 된다.
pub fn rememberRemoteRepoRoot(self: *AppSession, root: ?[]const u8) void {
    const want = root orelse {
        if (self.git_repo_remote_root) |old| self.allocator.free(old);
        self.git_repo_remote_root = null;
        return;
    };
    if (self.git_repo_remote_root) |current| {
        if (std.mem.eql(u8, current, want)) return;
        self.allocator.free(current);
    }
    self.git_repo_remote_root = self.allocator.dupe(u8, want) catch null;
}

/// 지금 목록이 **원격의 것인가**. 로컬 경로로 해석하면 안 되는 자리(파일 열기·감시·쓰기·턴 스냅샷)가
/// 전부 이 하나를 묻는다.
pub fn scmTargetIsRemote(self: *const AppSession) bool {
    return self.git_repo_dest != null;
}

/// 목록을 읽은 저장소를 기억한다. 같은 값이면 다시 할당하지 않는다.
pub fn rememberGitRepo(self: *AppSession, repo: []const u8) void {
    if (self.git_repo) |current| {
        if (std.mem.eql(u8, current, repo)) return;
        // **초안을 옮겨 담는 유일한 자리**다 — 여기가 옛 저장소와 새 저장소를 동시에 아는 곳이다.
        scm_dock_ops.switchCommitDraft(self, current, repo);
        // 방금 누른 동작의 결과 줄은 **그 저장소의 것**이다(P6). 남겨 두면 다른 저장소의 목록 위에
        // `원격에서 가져왔습니다`가 그대로 떠서, 하지도 않은 일을 한 것처럼 말한다.
        scm_dock_ops.clearScmWriteError(self);
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
    // ① **활성 Term 이 원격이면 그쪽이 대상이다**(RS2). 여기서 로컬 순위로 내려가면 원격 pane 을 보는
    // 동안 화면에 로컬 저장소가 남는다 — 그 상태에서 누른 스테이지가 보고 있지도 않은 파일을 바꾼다.
    var dest_buf: [max_remote_dest_bytes]u8 = undefined;
    var ctl_buf: [std.fs.max_path_bytes]u8 = undefined;
    var remote_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (remoteScmTarget(self, &dest_buf, &ctl_buf, &remote_cwd_buf)) |r| {
        const same_host = if (self.git_repo_dest) |d| std.mem.eql(u8, d, r.dest) else false;
        const same_path = if (self.git_repo) |p| std.mem.eql(u8, p, r.cwd) else false;
        if (same_host and same_path) return; // 바뀔 때만
        clearScmResult(self);
        submitGitRead(self, r.cwd, .{ .dest = r.dest, .control_path = r.ctl });
        return;
    }
    // ② **원격을 보다 로컬로 돌아왔다.** 목록도 기억도 함께 놓는다 — `git_repo` 에 남은 **원격 경로**를
    // 그대로 두면 아래 2 순위가 그것을 로컬 경로로 walk-up 해, 로컬에 우연히 같은 경로가 있으면
    // **남의 저장소를 원격인 척** 보여 준다(§9.4 와 같은 함정).
    if (scmTargetIsRemote(self)) {
        clearScmResult(self);
        forgetGitRepo(self);
    }
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
    submitGitRead(self, repo, null);
}

/// 화면에 남은 목록·실패·선택·in-flight를 버린다. **저장소가 갈릴 때와 "저장소 없음"으로 판정될 때가 같은 정리를
/// 요구**하므로 한 자리에 둔다 — 복붙해 두면 한쪽만 고쳐져 다른 쪽에 남의 저장소 상태가 남는다.
fn clearScmResult(self: *AppSession) void {
    if (self.git_result) |*result| result.deinit(git_backend_mod.worker_allocator);
    self.git_result = null;
    scm_dock_ops.invalidateRepoList(self); // 저장소가 갈렸다 — 목록도 다시 걷는다
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
///
/// **다시 그리기를 함께 세운다.** 세대를 올린 순간부터 그 화면의 클릭은 표가 새 세대로 **다시 발행될
/// 때까지** 거부되는데, 그 발행은 렌더가 도는 프레임에만 일어난다 — `metal_dirty`가 안 서면 표가 영영
/// 안 따라오고 클릭이 죽은 채로 남는다. 지금까지는 호출부 넷이 저마다 세우고 있었을 뿐이라 **하나만
/// 빠져도** 같은 버그가 조용히 돌아왔다. 그 짝을 호출 규약이 아니라 이 함수가 진다.
pub fn bumpScmDockGeneration(self: *AppSession) void {
    self.scm_dock_snapshot_generation +%= 1;
    if (self.scm_dock_snapshot_generation == 0) self.scm_dock_snapshot_generation = 1;
    self.metal_dirty = true;
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
    drainIgnoreResults(self); // 탐색기 무시 표시 — 같은 tick 에서 걷어 rows 를 한 번만 다시 만든다
    var backend = &(self.git_backend orelse return);
    // 턴 스냅샷 결과를 링에 넣는다. 같은 tree가 연달아 오면 링이 스스로 무시한다(빈 비교 방지 — §6.1).
    while (backend.takeBranchesResult()) |taken| {
        var res = taken;
        self.branch_menu_pending = false;
        defer res.deinit(git_backend_mod.worker_allocator); // backend가 준 버퍼는 backend allocator로만 해제한다
        if (!res.ok or res.text.len == 0) {
            self.showNoticeKey(.git_branch_list_failed); // 조용히 아무 일도 안 일어나는 것보다 낫다
            continue;
        }
        // **소유권을 인수하지 않고 복사한다.** `branch_menu_text`는 세션 소유 필드이고(테스트도 세션 allocator로
        // 채운다) `clearBranchMenuText`가 세션 allocator로 해제한다. backend 버퍼를 그대로 실으면 한 필드에 두
        // allocator의 메모리가 섞여, 어느 쪽으로 해제해도 한쪽이 heap을 깬다. 복사는 `--count=200`으로 유계다.
        const owned = self.allocator.dupe(u8, res.text) catch {
            self.showNoticeKey(.git_branch_list_failed);
            continue;
        };
        settings_ops.clearBranchMenuText(self);
        self.branch_menu_text = owned;
        self.branch_menu_len = git_command.collectBranches(self.branch_menu_text, &self.branch_menu_names);
        // **어느 클릭의 답인지는 요청이 기억해 뒀다**(§3.5) — 목록 자체는 용도를 모른다.
        switch (self.branch_menu_purpose) {
            .switch_branch => settings_ops.openBranchMenu(self),
            .pick_base => scm_dock_ops.openBaseMenu(self),
        }
    }
    while (backend.takeSnapshotResult()) |taken| {
        var snapshot = taken;
        // **"언제·누가"는 여기서 붙인다**(P5). 링은 순서만 알지 시간을 모르고, 에이전트 종류는 그 turn을
        // 돌린 Term이 갖고 있다 — 스냅샷이 도착한 이 자리가 둘을 아는 유일한 지점이다.
        const captured_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        // **링은 세션이 소유한다**(AT0 — 계약 §6.1). 키는 그 Term 의 provider 세션 신원이고, 저장소는
        // `ringFor` 가 함께 받아 **그 세션이 옮겼는지**를 판정한다(옮겼으면 그 링만 비운다).
        //
        // 신원이 사라졌으면(그 사이 Term 이 죽었거나 관측 모드로 떨어졌다) 넣을 자리가 없으므로 버린다 —
        // 화면에도 그 세션 줄이 없으니 잃는 것이 없다.
        // **요청할 때 붙들어 둔 신원**을 쓴다 — 여기서 다시 조회하면 `/clear` 로 세션이 갈린 경우 옛
        // 턴이 새 세션에 붙는다(적대적 검증 1회차).
        const identity = self.turn_snapshot_session orelse "";
        if (identity.len > 0) {
            // **요청할 때 붙들어 둔 저장소**를 쓴다 — 여기서 `git_repo` 를 다시 읽으면 그 사이 다른
            // 워크트리로 옮겼을 때 멀쩡한 링을 «저장소가 바뀌었다» 로 비운다(적대적 검증 3회차).
            const repo = self.turn_snapshot_repo orelse "";
            if (self.turn_rings.ringFor(identity, repo)) |ring| {
                ring.push(.{
                    .tree = snapshot.tree,
                    .surface_id = snapshot.surface_id,
                    .captured_s = captured_s,
                    .agent_kind = @intFromEnum(agentKindForSurface(self, snapshot.surface_id)),
                    // **요청할 때 붙들어 둔 턴 키**를 쓴다 — 신원·저장소와 같은 이유다. 여기서 Term 의
                    // 진행 상태를 다시 읽으면 그 사이 다음 턴이 시작된 경우 **옛 스냅샷에 새 턴 키**가
                    // 붙는다(계약 §3.1 이 시각 대신 키를 쓰라고 한 이유가 그런 어긋남이다).
                    .turn_key = self.turn_snapshot_key[0..self.turn_snapshot_key_len],
                    .title = self.turn_snapshot_title[0..self.turn_snapshot_title_len],
                    // 같은 이유로 **요청할 때 봉인해 둔 캡처**를 쓴다.
                    .capture_id = self.turn_snapshot_capture,
                });
            }
        }
        // **링이 바뀌는 유일한 tick 지점이 여기다** — 그래서 사본 정리도 여기 한 자리에 둔다.
        sweepTurnCaptures(self);
        self.turn_snapshot_key_len = 0;
        self.turn_snapshot_title_len = 0;
        self.turn_snapshot_capture = 0;
        if (self.turn_snapshot_session) |sid| self.allocator.free(sid);
        self.turn_snapshot_session = null;
        if (self.turn_snapshot_repo) |path| self.allocator.free(path);
        self.turn_snapshot_repo = null;
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
        // **원격 저장소 루트를 목록과 같은 결과에서 받는다**(RS3). 이 값이 있어야 diff 가 상대경로를
        // 절대경로로 만들어 작업트리 파일을 읽는다. 로컬 결과에는 비어 있고, 그때는 기억을 비운다 —
        // 남겨 두면 로컬 목록을 보는 동안 옛 원격 루트가 살아 있어 그 쌍으로 파일을 열 수 있다.
        rememberRemoteRepoRoot(self, if (result.repo_root.len > 0) result.repo_root else null);
        if (self.git_result) |*old| old.deinit(git_backend_mod.worker_allocator);
        self.git_result = result;
        // 새 결과에는 새 워크트리 목록이 실려 있을 수 있다 — 목록 캐시를 그 자리에서 무효화한다
        // (주기를 기다리면 방금 만든 워크트리가 최대 500ms 늦게 뜬다).
        scm_dock_ops.invalidateRepoList(self);
        // 새 목록이다 — 옛 화면을 겨냥한 늦은 클릭을 거부한다(세대 대조).
        bumpScmDockGeneration(self);
        // 목록이 짧아졌으면 offset을 창 안으로 당긴다. 발행·렌더는 `scmEffectiveScrollPx`가 매번
        // 유계화하지만 **raw 값은 그대로 남아**, 목록이 다시 길어질 때 그 자리로 튄다. 탐색기가
        // `updateFileTree`에서 같은 일을 하는 것과 같은 자리다.
        //
        // **여기서 쓰는 상한은 아직 옛 목록의 것이다** — 새 결과로 만든 목록은 다음 투영에서 나온다.
        // 그래서 이 호출은 근사이고, 정확히 당기는 것은 그 투영(`rememberScrollExtent`)이다. 그래도
        // 남겨 두는 이유는 도크가 접혀 투영이 한동안 안 도는 동안에도 raw 값이 자라지 않게 하는 것이다.
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
/// 방금 읽은 디렉터리의 항목들이 git 무시 대상인지 묻는다(파일 탐색기 흐리게 표시).
///
/// **경로는 저장소 루트 기준 상대경로**로 넘긴다 — `git -C <repo> check-ignore` 가 그렇게 해석하고,
/// 절대경로를 주면 저장소 밖 경로로 취급돼 조용히 답이 비는 경우가 있다.
///
/// 한 번에 `check_ignore_batch` 개까지만 묻는다(argv 한도). 그보다 많은 디렉터리는 **첫 배치만** 판정이
/// 서고 나머지는 판정 없이 남는다 — 흐리게 하지 않는 쪽이라 틀린 표시가 되지는 않는다. 배치를 여러 번
/// 돌리는 것은 후속(요청 큐가 필요하다).
pub fn requestIgnoredForPaths(self: *AppSession, dir_path: []const u8, entries: anytype) void {
    if (self.git_backend == null) return;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = gitRepoRoot(self, &repo_buf) orelse return; // 저장소가 아니면 물어볼 것이 없다
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;

    // 상대경로 조각을 한 버퍼에 이어 담고 슬라이스만 넘긴다(항목마다 할당하지 않는다).
    self.git_ignore_query_buf.clearRetainingCapacity();
    self.git_ignore_query_paths.clearRetainingCapacity();
    for (entries) |entry| {
        if (self.git_ignore_query_paths.items.len >= git_command.check_ignore_batch) break;
        const start = self.git_ignore_query_buf.items.len;
        self.git_ignore_query_buf.appendSlice(self.allocator, dir_path) catch break;
        self.git_ignore_query_buf.append(self.allocator, '/') catch break;
        self.git_ignore_query_buf.appendSlice(self.allocator, entry.name) catch break;
        const abs = self.git_ignore_query_buf.items[start..];
        // 저장소 루트 접두를 떼어 상대경로로 만든다. 밖이면 건너뛴다(그 항목은 판정 없이 남는다).
        //
        // **`startsWith` 만으로는 부족하다** — 그것은 `/a/proj` 를 `/a/project/x` 의 루트로 통과시켜
        // `rel = "ect/x"` 라는 쓰레기를 만든다. `abs` 는 파일 트리의 `dir_path`, `repo` 는 터미널 cwd 에서
        // 거슬러 올라간 값이라 **서로 다른 출처**이고 형제 접두가 실제로 가능하다. 그 경로가
        // `check-ignore` 로 가면 판정이 어긋나 `.gitignore` 된 항목이 흐려지지 않는다.
        // 경계 검사와 후행 구분자 처리를 함께 갖는 `path_shape.relativeUnderRoot` 가 단일 출처다
        // (계약 §5.2 ⒝ — 문서가 "두 곳" 이라 한 것은 `root.len + 1` 철자만 센 것이었다).
        const rel = path_shape.relativeUnderRoot(abs, repo) orelse {
            self.git_ignore_query_buf.shrinkRetainingCapacity(start);
            continue;
        };
        if (rel.len == 0) {
            self.git_ignore_query_buf.shrinkRetainingCapacity(start);
            continue;
        }
        self.git_ignore_query_paths.append(self.allocator, rel) catch break;
    }
    if (self.git_ignore_query_paths.items.len == 0) return;
    self.git_ignore_request_id +%= 1;
    // 거절되면(이미 하나가 돌고 있음) 그냥 넘어간다 — 다음 스캔이 다시 묻는다.
    _ = self.git_backend.?.submitCheckIgnore(git_exe, repo, self.git_ignore_query_paths.items, self.git_ignore_request_id);
}

/// `check-ignore` 결과를 트리에 반영한다. 무시된 것으로 돌아온 경로만 표시하고, 이번 배치에서 물었던
/// 나머지는 **표시를 지운다** — 그렇게 해야 `.gitignore` 를 고쳐 무시가 풀린 항목이 흐린 채로 남지 않는다.
pub fn drainIgnoreResults(self: *AppSession) void {
    var backend = &(self.git_backend orelse return);
    while (backend.takeIgnoreResult()) |taken| {
        var res = taken;
        defer res.deinit(git_backend_mod.worker_allocator);
        if (!res.ok) continue;
        // 물었던 경로를 먼저 지우고(이번 답이 권위다), 무시된 것만 다시 세운다.
        for (self.git_ignore_query_paths.items) |rel| {
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (joinRepoPath(self, rel, &abs_buf)) |abs| self.file_tree.markIgnored(abs, false);
        }
        var it = git_status.iterateIgnored(res.text);
        while (it.next()) |rel| {
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (joinRepoPath(self, rel, &abs_buf)) |abs| self.file_tree.markIgnored(abs, true);
        }
        self.file_tree_rows_dirty = true;
        self.metal_dirty = true;
    }
}

/// 저장소 루트 기준 상대경로를 트리가 쓰는 절대경로로 되돌린다.
fn joinRepoPath(self: *AppSession, rel: []const u8, buf: []u8) ?[]const u8 {
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = gitRepoRoot(self, &repo_buf) orelse return null;
    if (repo.len + 1 + rel.len > buf.len) return null;
    @memcpy(buf[0..repo.len], repo);
    buf[repo.len] = '/';
    @memcpy(buf[repo.len + 1 ..][0..rel.len], rel);
    return buf[0 .. repo.len + 1 + rel.len];
}

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
    // **원격 목록을 보는 동안에는 로컬 순위로 내려가지 않는다**(RS2). `git_repo` 에 든 것이 원격 경로라
    // 로컬 walk-up 은 뜻이 없고, 우연히 같은 경로가 로컬에 있으면 남의 저장소를 답한다. 「모른다」가
    // 정확한 답이고, 호출자는 그때 직전 판단을 유지한다.
    if (scmTargetIsRemote(self)) return .unknown;
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
pub fn noticeNotARepo() []const u8 {
    return maru.i18n.t(.git_not_a_repo);
}
pub fn noticeRepoUnknown() []const u8 {
    return maru.i18n.t(.git_repo_unknown);
}
/// 읽기는 성공했고 바뀐 것이 없다. **위 둘과 같은 표에 둔다** — 사용자에게는 셋 다 "목록이 비었다"로
/// 보이지만 서로 다른 사실이고, 문구를 흩어 두면 한쪽만 고쳐져 같은 화면이 두 가지를 말한다.
/// 이 문장만 목록 컴포넌트가 그린다(나머지 둘은 목록을 그리기 전에 나온다).
pub fn noticeNoChanges() []const u8 {
    return maru.i18n.t(.git_no_changes);
}

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
    if (self.git_missing) return maru.i18n.t(.git_not_installed);
    return switch (gitRepoTarget(self, probe)) {
        .none => noticeNotARepo(),
        .unknown => noticeRepoUnknown(),
        .repo => if (self.git_failed) maru.i18n.t(.git_read_failed) else maru.i18n.t(.scm_loading),
    };
}

/// 그 surface를 든 Term의 에이전트 종류(없으면 `.none`). 스냅샷은 surface_id만 싣고 오므로 여기서
/// 되찾는다 — Term이 그 사이 닫혔으면 `.none`이고, 그건 "모른다"가 아니라 "그 값을 잃었다"이다.
/// «직전에 본 에이전트 세션» 을 갱신한다. 같은 값이면 아무것도 하지 않는다(할당을 아낀다).
pub fn rememberAgentSession(self: *AppSession, identity: []const u8) void {
    if (identity.len == 0) return;
    const remembered = self.last_agent_session orelse "";
    if (std.mem.eql(u8, remembered, identity)) return;
    const owned = self.allocator.dupe(u8, identity) catch return;
    if (self.last_agent_session) |old_sid| self.allocator.free(old_sid);
    self.last_agent_session = owned;
}

/// 목록·비교가 볼 **세션 신원**. 활성 Term 에 에이전트가 있으면 그것이고, 없으면 **직전에 본 세션**이다.
///
/// 폴백이 필요한 이유는 diff 다: 턴 목록에서 파일을 클릭하면 활성 Term 이 파일 Term 이 되어 신원이 비는데,
/// 사용자는 **그 diff 를 보면서 목록을 봐야 한다.** 활성만 보면 그 순간 목록과 비교 기준이 함께 사라진다
/// (적대적 검증 4회차 — 통합 테스트가 잡았다). [§3.5](../../../docs/editor-surface-dock.md)가 저장소 판정에
/// «직전에 목록을 읽은 저장소» 를 2순위로 두는 것과 같은 규율이다.
///
/// **조회가 한 자리인 것이 중요하다.** 처음에는 화면 쪽에만 폴백을 넣었는데, 비교 기준을 만드는 이쪽
/// 경로가 여전히 활성만 보아 diff 를 열면 턴 범위가 비었다.
pub fn activeOrLastSessionIdentity(self: *AppSession) []const u8 {
    if (self.surface_initialized) {
        const live = sessionIdentityFor(self, term_ops.activeSurface(self).id);
        if (live.len > 0) {
            rememberAgentSession(self, live);
            return live;
        }
    }
    return self.last_agent_session orelse "";
}

/// 어느 링에도 **가리켜지지 않는** 그림자 사본을 해제한다(계약 §4.4).
///
/// **「지우는 호출」로 두지 않는 이유**: 턴이 사라지는 길이 넷이고 호출 방식은 셋을 흘린다.
/// ⑴ `Ring.push` 가 8칸을 넘겨 덮는다 ⑵ `RingMap.victim()` 이 세션을 통째로 밀어낸다
/// ⑶ `ringFor` 가 저장소 전환에 링을 **대입 한 줄로** 갈아 끼운다(호출을 끼울 자리가 없다)
/// ⑷ `push` 가 dedup 으로 거절한다(봉인·발급 **직후**라 그 순간 고아가 된다).
///
/// 넷을 질문 하나로 덮는다 — 「이 사본을 아직 가리키는 스냅샷이 있나」. 규모는 세션 8 × 링 8 = 64라
/// 매 수확마다 돌려도 공짜다.
pub fn sweepTurnCaptures(self: *AppSession) void {
    var live: [maru.session.turn_snapshot.max_sessions * maru.session.turn_snapshot.capacity + 1]u64 = undefined;
    var n: usize = 0;
    // ⚠️ **아직 링에 없지만 살아 있는 것이 하나 있다.** 봉인된 사본은 `submitSnapshot` 이 받아들여진 뒤
    // **harvest 가 돌 때까지** 링에 안 들어간다(git worker 가 tree 를 뜨는 동안). 그 창에 다음 턴이
    // 끝나면 sweep 이 **아직 쓸 사본을 해제**하고, 그 뒤 harvest 가 그 id 로 push 해도
    // `sealedTurn` 이 null 이라 그 턴의 `✎` 와 셸 고지가 **조용히 사라진다.**
    //
    // 그래서 요청 중인 id 를 살아 있는 것으로 친다 — `turn_snapshot_session`·`_repo`·`_key` 를 요청
    // 시점에 붙들어 두는 것과 **같은 규율**이다(수확 때 다시 만들지 않는다).
    if (self.turn_snapshot_capture != 0) {
        live[n] = self.turn_snapshot_capture;
        n += 1;
    }
    for (&self.turn_rings.entries) |*entry| {
        if (entry.used == 0) continue;
        var back: usize = 0;
        while (back < entry.ring.len) : (back += 1) {
            const snap = entry.ring.nth(back) orelse break;
            if (snap.capture_id == 0) continue;
            if (n == live.len) break;
            live[n] = snap.capture_id;
            n += 1;
        }
    }
    self.turn_captures.sweep(self.allocator, live[0..n]);
}

/// 그 surface 의 **provider 세션 신원**(없으면 빈 슬라이스). 링의 키다(§6.1 AT0).
///
/// 훅 모드에서는 `applyHookEvent` → `adoptHookSessionIdentity` 가 payload 의 `session_id` 로 채워 두므로
/// 턴이 끝나는 순간 이미 있다(AT1).
/// 관측 모드에서는 자식 프로세스 env 폴링에 기대는데 그 창을 대부분 놓치므로(1초 폴링 ↔ 짧은 도구)
/// 비어 있는 것이 정상이다 — 그때는 링을 만들지 않는다.
pub fn sessionIdentityFor(self: *AppSession, surface_id: u64) []const u8 {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.surface.id == surface_id) return term.agent_transcript.identity();
            }
        }
    }
    return "";
}

fn agentKindForSurface(self: *AppSession, surface_id: u64) app_session_mod.AgentKind {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.surface.id == surface_id) return term.agent_kind;
            }
        }
    }
    return .none;
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
pub fn openDiffForScmRow(self: *AppSession, repo_override: ?[]const u8, row: scm_view.FileRow) void {
    // git 출력이 이상하거나 우리 파싱이 어긋나면 루트 밖 경로가 여기까지 올 수 있다. **여는 단계에서** 막는다 —
    // 백엔드도 같은 판정을 하지만, 열지 말아야 할 것으로 Term을 만들면 사용자에게 빈 화면이 남는다(§6 심층 방어).
    if (!maru.session.repo_path.isSafeRelative(row.path)) {
        self.showNoticeKey(.git_path_outside_repo);
        return;
    }
    // **목록을 읽은 그 저장소**를 쓴다. 여기서 다시 구하면 첫 diff가 열린 뒤 활성 Term이 웹 Term이라
    // cwd 폴백이 빈 값을 보고 null이 되어 두 번째 행부터 조용히 무시된다(손 확인에서 그랬다).
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    // **그 행이 선 저장소**를 쓴다(②d — 목록에 저장소가 여럿이고 비활성 저장소도 파일 줄을 낸다).
    // 없으면 목록을 읽은 그 저장소로 떨어진다: 여기서 다시 구하면 첫 diff가 열린 뒤 활성 Term이 웹
    // Term이라 cwd 폴백이 빈 값을 보고 null이 되어 두 번째 행부터 조용히 무시된다(손 확인에서 그랬다).
    const repo = repo_override orelse self.git_repo orelse (gitRepoRoot(self, &repo_buf) orelse return);
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ repo, row.path }) catch return;
    // 하위 모듈은 텍스트 비교가 없다(커밋 포인터라 blob이 없고 작업트리 쪽은 디렉터리다 — 실측).
    // 빈 화면을 여느니 이유를 말한다.
    if (row.submodule) {
        self.showNoticeKey(.git_submodule_no_diff);
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

/// 히스토리에서 고른 **커밋 하나의 파일** 비교를 연다(P4b). 커밋 OID까지 유일성 키에 넣어야 다른
/// 커밋의 같은 파일이 서로를 덮지 않는다.
pub fn openCommitDiffTerm(
    self: *AppSession,
    repo: []const u8,
    abs_path: []const u8,
    rel_path: []const u8,
    orig_rel_path: ?[]const u8,
    commit_oid: []const u8,
) void {
    if (diffTermForCommit(self, abs_path, .commit, commit_oid)) |existing| {
        _ = self.activateExistingFileTerm(existing);
        return;
    }
    const opened = pane_ops.openFileTermInActivePane(self, abs_path, .diff) catch return;
    const entry = opened.term.file_entry orelse return;
    entry.diff_base = .commit;
    self.freeDiffPaths(entry);
    entry.diff_rel_path = self.allocator.dupe(u8, rel_path) catch &.{};
    entry.diff_orig_rel_path = if (orig_rel_path) |o| (self.allocator.dupe(u8, o) catch &.{}) else &.{};
    entry.diff_repo = self.allocator.dupe(u8, repo) catch &.{};
    stampDiffRemote(self, entry, repo);
    // **이 비교가 어느 커밋인지**는 열 때 정해 들고 다닌다 — 나중에 다시 구하면 그 사이 다른 커밋을
    // 펼쳤을 때 남의 커밋을 읽는다.
    entry.diff_commit_oid = self.allocator.dupe(u8, commit_oid) catch &.{};
    self.requestDiffContent(entry);
    editor_diff_ops.markRequested(self, opened.term);
}

/// 에이전트 타임라인에서 고른 **턴 하나의 파일** 비교를 연다(P5). 유일성 키에 두 tree가 들어간다 —
/// 턴마다 다른 탭이어야 두 턴을 나란히 놓고 볼 수 있다.
pub fn openTurnDiffTerm(
    self: *AppSession,
    repo: []const u8,
    abs_path: []const u8,
    rel_path: []const u8,
    orig_rel_path: ?[]const u8,
    base_tree: []const u8,
    head_tree: []const u8,
) void {
    if (diffTermForTurn(self, abs_path, base_tree, head_tree)) |existing| {
        _ = self.activateExistingFileTerm(existing);
        return;
    }
    const opened = pane_ops.openFileTermInActivePane(self, abs_path, .diff) catch return;
    const entry = opened.term.file_entry orelse return;
    entry.diff_base = .turn_range;
    self.freeDiffPaths(entry);
    entry.diff_rel_path = self.allocator.dupe(u8, rel_path) catch &.{};
    entry.diff_orig_rel_path = if (orig_rel_path) |o| (self.allocator.dupe(u8, o) catch &.{}) else &.{};
    entry.diff_repo = self.allocator.dupe(u8, repo) catch &.{};
    stampDiffRemote(self, entry, repo);
    entry.diff_commit_oid = self.allocator.dupe(u8, base_tree) catch &.{};
    entry.diff_right_oid = self.allocator.dupe(u8, head_tree) catch &.{};
    self.requestDiffContent(entry);
    editor_diff_ops.markRequested(self, opened.term);
}

/// 같은 파일이라도 **턴이 다르면 다른 탭**이다(커밋과 같은 규율).
pub fn diffTermForTurn(self: *AppSession, abs_path: []const u8, base_tree: []const u8, head_tree: []const u8) ?*Term {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (entry.kind != .diff or entry.diff_base != .turn_range) continue;
                if (!std.mem.eql(u8, entry.diff_commit_oid, base_tree)) continue;
                if (!std.mem.eql(u8, entry.diff_right_oid, head_tree)) continue;
                if (std.mem.eql(u8, entry.path, abs_path)) return term;
            }
        }
    }
    return null;
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
    stampDiffRemote(self, entry, repo);
    self.requestDiffContent(entry);
    // 재시도 창(6초)은 **요청 시점**부터 흐른다. 네이티브가 아니면 무동작이다.
    editor_diff_ops.markRequested(self, opened.term);
}

pub fn diffTermFor(self: *AppSession, abs_path: []const u8, base: dock_panel.DiffBase) ?*Term {
    return diffTermForCommit(self, abs_path, base, "");
}

/// 위와 같되 **커밋 기준은 그 커밋까지** 본다(P4b 적대적 검증).
///
/// 유일성 키가 `(경로, kind, base)`뿐이면 **다른 커밋의 같은 파일이 같은 탭을 재사용**한다 — 사용자는
/// 방금 누른 커밋을 눌렀는데 앞서 본 커밋의 내용을 보게 된다. 커밋마다 다른 탭이어야 두 커밋을 나란히
/// 놓고 볼 수도 있다.
pub fn diffTermForCommit(self: *AppSession, abs_path: []const u8, base: dock_panel.DiffBase, commit_oid: []const u8) ?*Term {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (entry.kind != .diff or entry.diff_base != base) continue;
                if (base == .commit and !std.mem.eql(u8, entry.diff_commit_oid, commit_oid)) continue;
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
