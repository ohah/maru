//! 에이전트 관측 — 상태·종류·트랜스크립트 폴링, 상태줄 조정, 스피너, 사이드바 에이전트 행,
//! 세션 재개.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F14).
//!
//! **에이전트 세션 기록 도크는 여기가 아니다** — 그건 F1이 `agent_dock.zig`로 가져갔다. 이름이
//! `agentSessionArchive*`인 열 개는 본문이 `agent_dock.agentSessionDockSmokeProbe(self)` 같은 위임
//! 한 줄인 **F1의 ABI facade**라 제외했다(F8의 `scrollToCurrentMatch`와 같은 판단 — 남의 facade를
//! 옮기면 원본에서 멀어진다).
//!
//! 여기 있는 것은 **관측**이다. 에이전트가 무엇을 하고 있는지 주기적으로 읽어(`pollAgentKinds`·
//! `pollAgentState`·`pollAgentTranscript`) 상태줄과 사이드바 행에 반영한다. 읽기 자체는 worker
//! (`agent_observer`·`agent_transcript`)가 소유하고, 여기서는 그 결과를 메인 스레드 상태로 옮긴다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const git_ops = @import("git.zig");
const usableRestoreCwd = app_session_mod.usableRestoreCwd;
const writeExecutableFile = AppSession.writeExecutableFile;
const resolveConfiguredShell = app_session_mod.resolveConfiguredShell;
const writeStatusLineCommand = AppSession.writeStatusLineCommand;
const buildResumeShellCommand = app_session_mod.buildResumeShellCommand;
const readStatusLineState = AppSession.readStatusLineState;
const turnStateOf = AppSession.turnStateOf;
const StatuslineLock = AppSession.StatuslineLock;
const agent_dock = app_session_mod.agent_dock;
const agent_screen_tail_bytes = app_session_mod.agent_screen_tail_bytes;
const agent_screen_tail_rows = app_session_mod.agent_screen_tail_rows;
const diag_gate = app_session_mod.diag_gate;
const readFileAlloc = AppSession.readFileAlloc;
const readFileState = AppSession.readFileState;
const sidebar_ops = @import("sidebar.zig");
const spawnRequest = app_session_mod.spawnRequest;
const agentProcessPid = app_session_mod.agentProcessPid;
const agent_activity_window_ms = app_session_mod.agent_activity_window_ms;
const agent_running_flag = app_session_mod.agent_running_flag;
const classifyAgentProcesses = app_session_mod.classifyAgentProcesses;
const layout_math = app_session_mod.layout_math;
const sessionCacheBase = AppSession.sessionCacheBase;
const settings_ops = @import("settings.zig");
const spinner_wave = app_session_mod.spinner_wave;
const transcript_poll_interval_ms = app_session_mod.transcript_poll_interval_ms;
const workspace_ops = @import("workspace.zig");
const AgentKind = app_session_mod.AgentKind;
const AgentTally = AppSession.AgentTally;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const WorkspaceAgent = AppSession.WorkspaceAgent;
const agent_age_repaint_interval_ms = app_session_mod.agent_age_repaint_interval_ms;
const agent_observer_interval_ms = app_session_mod.agent_observer_interval_ms;
const agent_poll_interval_ms = app_session_mod.agent_poll_interval_ms;
const agent_session_archive_backend = app_session_mod.agent_session_archive_backend;
const agent_spin_interval_ms = app_session_mod.agent_spin_interval_ms;
const git_backend_mod = app_session_mod.git_backend_mod;
const is_macos = app_session_mod.is_macos;
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");

/// 에이전트 턴이 끝났다 — 그 순간의 작업트리를 tree 하나로 굳힌다(§6.1). 실패하면 그냥 안 찍힌 것이고
/// 다음 턴에 다시 시도한다(스냅샷 실패가 목록·diff를 막지 않는다).
pub fn captureTurnSnapshot(self: *AppSession, surface_id: u64) void {
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = self.git_repo orelse (git_ops.gitRepoRoot(self, &repo_buf) orelse return);
    // 저장소가 바뀌었으면 링을 버린다 — 다른 저장소의 tree로 비교하면 전부 삭제로 보인다.
    if (self.turn_ring_repo) |current| {
        if (!std.mem.eql(u8, current, repo)) {
            self.allocator.free(current);
            self.turn_ring_repo = null;
            self.turn_ring = .{};
        }
    }
    if (self.turn_ring_repo == null) self.turn_ring_repo = self.allocator.dupe(u8, repo) catch return;

    const index_file = self.turnIndexPath() orelse return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.allocator, self.io) catch return;
    }
    _ = self.git_backend.?.submitSnapshot(git_exe, repo, index_file, surface_id);
}

/// Archive에서 고른 provider-native session을 새 terminal 탭으로 재개한다. transcript를 셸에 paste하거나
/// `sh -c`로 조립하지 않고, `/usr/bin/env`와 provider argv를 분리해 직접 exec 한다.
pub fn resumeAgentSessionInNewTerm(self: *AppSession, record: *const agent_session_archive_backend.Record) !void {
    const pane = pane_ops.activePane(self);
    const size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, self.active_pane_rect.w, self.active_pane_rect.h);
    var cfg = self.new_tab_config;
    cfg.size = size;
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.new_tab_zdotdir, self.new_tab_ssh_bin);
    const provider_command: []const u8 = record.parsed.provider.label();
    const args = switch (record.parsed.provider) {
        .claude => [_][]const u8{ "claude", "--resume", record.parsed.session_id },
        .codex => [_][]const u8{ "codex", "resume", record.parsed.session_id },
    };
    // The isolated AppKit fixture supplies one absolute fake executable so it can prove the
    // provider-native argv without starting a real account session or depending on the build
    // runner's inherited PATH.  That seam stays a direct exec with no shell wrapper.
    var shell_command: ?[]u8 = null;
    defer if (shell_command) |owned| self.allocator.free(owned);
    if (agent_dock.archiveSmokeFakeProviderExecutable(record.parsed.provider)) |fake_executable| {
        req.command = fake_executable;
        req.args = args[1..];
        req.login = false;
    } else {
        // 제품 경로는 **사용자 로그인 셸을 거쳐** provider를 찾는다. 예전에는 `/usr/bin/env claude`를
        // 직접 exec했는데, 그러면 provider를 **부모 프로세스의 PATH에서만** 찾는다. 터미널에서 띄운
        // 앱은 셸 PATH를 상속해 우연히 동작했지만 Dock/Finder에서 띄운 앱은 실패했다 — GUI 앱이
        // 물려받는 PATH에는 `~/.local/bin`이나 버전 매니저 shim이 없다(실측: `launchctl getenv PATH`
        // 미설정, `env -i … zsh -lc 'command -v claude'` 실패, `-lic`는 성공).
        //
        // `login = true`만 켜는 것으로는 안 된다. login(1) 래핑은 최종적으로
        // `… -c "exec -l '<command>' '<args>'"`를 만드는데, `<command>`가 `/usr/bin/env`면 exec 대상이
        // 셸이 아니라 **dotfile을 읽는 주체가 없다**. 그래서 exec 대상 자체를 셸로 만든다.
        //
        // 셸 종류로 분기하지 않는다. 분기해서 직접 exec으로 폴백해 봐야 그건 **이 커밋이 고치는
        // 바로 그 실패**(Dock에서 PATH 못 찾음)로 되돌아가는 것이고, 경로가 둘이 되어 유지보수만
        // 는다. 셸이 이 인자를 못 받으면 그 셸이 에러를 내고 PTY 화면에 그대로 뜬다 — 조용히
        // 실패하지 않으므로 사용자가 원인을 본다.
        shell_command = try buildResumeShellCommand(self.allocator, &args);
        req.command = resolveConfiguredShell(self.loaded_config.config.shell.command);
        // `-i`가 필요하다: PATH를 `.zshrc`에 두는 환경이 흔하고 zsh는 `-l`만으로는 그 파일을 읽지
        // 않는다. 일반 새 탭은 이미 대화형 로그인 셸이므로 이 경로가 오히려 나머지 탭과 동작을
        // 일치시킨다. `exec`로 중간 셸을 남기지 않아 실행 중 판정(foreground process group 열거)도
        // 그대로 성립한다.
        req.args = &[_][]const u8{ "-l", "-i", "-c", shell_command.? };
        req.login = true;
    }
    // cwd는 **명령 문자열에 넣지 않고** spawn 작업 디렉터리로만 전달한다 — 셸 메타문자가 명령으로
    // 재해석될 여지를 두지 않는다.
    if (usableRestoreCwd(record.parsed.cwd)) |cwd| req.cwd = cwd;
    const term = try self.createTerm(req, size, cfg.queue_capacity, provider_command, args[0]);
    errdefer self.destroyTerm(term);
    try pane.terms.append(self.allocator, term);
    self.focusTerm(pane.terms.items.len - 1);
}

pub fn tallyAgents(self: *const AppSession) AgentTally {
    var t: AgentTally = .{};
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                switch (term.agent_state) {
                    .running => {
                        t.running += 1;
                        // 대표 kind는 **처음 만난 것**이다 — 섞여 있을 때 무엇을 대표로 삼을지 의미 있는
                        // 규칙이 없고, 개수가 이미 "여럿"을 말해 준다.
                        if (t.running_kind == .none and term.agent_kind != .none) t.running_kind = term.agent_kind;
                    },
                    .blocked => t.blocked += 1,
                    .unknown, .idle => {},
                }
            }
        }
    }
    return t;
}

pub fn agentStatePriority(state: maru.session.agent_observer.State) u8 {
    return switch (state) {
        .blocked => 3,
        .running => 2,
        .idle => 1,
        .unknown => 0,
    };
}

/// 이 탭(tab_index)의 에이전트 상태/종류 변화가 **화면에 보이는 running 표시**에 영향을 주는가 — pollAgentKinds/State의
/// metal_dirty 게이트. 옛 "활성 Term만 보이면 재렌더"에서 확장한다: (1) 사이드바 카드 스피너·아이콘·색은 이제 **워크스페이스
/// 단위**(tabHasRunningAgent/tabAgentKind)라 그 탭의 **어느 Term** 상태가 바뀌어도 카드가 바뀐다 → 카드가 보이면 재렌더.
/// (2) 탭 바는 **활성 탭의 모든 Term**에 정적 플래그(●)를 그리므로 활성 탭의 어느 Term 변화든 반영해야 한다. 둘 다 안 보이면
/// (접힘/최소 + 비활성 탭) 진짜로 화면에 없으니 재렌더 안 함(안 보이는 background Term churn으로 헛 재렌더 방지 — 옛 게이트 취지 유지).
pub fn agentDisplayVisible(self: *AppSession, tab_index: usize) bool {
    // (1) 사이드바 카드가 보이고 이 탭이 검색 필터를 통과하면(displaySlotOf 재사용 — 멤버십 스캔 단일 출처, code-review high).
    if (!self.sidebar_collapsed and !self.chrome_minimal and self.displaySlotOf(tab_index) != null) return true;
    // (2) 탭 바가 그려지고(chrome_minimal이면 paneBarHeightPx==0) 이 탭이 활성이면 이 탭의 Term들이 탭으로 보인다.
    return pane_ops.paneBarHeightPx(self) > 0 and self.app_window.active_tab == tab_index;
}

/// 에이전트 행의 ✕ → **그 Term 하나만** 닫는다(워크스페이스나 pane이 아니라). 인덱스는 클릭 시점에 재조회해
/// 유효하지 않으면 무동작한다. 실행 중 명령 확인은 Term 단위 닫기의 기존 규율(`closeTermAt` → 캐스케이드)을
/// 그대로 따른다 — 마지막 Term이면 pane이, 마지막 pane이면 워크스페이스가 함께 닫힌다.
pub fn closeAgentRow(self: *AppSession, tab_index: usize, pane_index: usize, term_index: usize) void {
    if (tab_index >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_index];
    if (pane_index >= tab.panes.items.len) return;
    if (term_index >= tab.panes.items[pane_index].terms.items.len) return;
    // **반드시 requestClose를 거친다**: 실행 중 명령 확인 모달과 마지막-Term 캐스케이드(pane→탭→세션 latch)가
    // 거기 있다. closeTermAt을 직접 부르면 (1) 돌고 있는 에이전트가 확인 없이 죽고 (2) 마지막 워크스페이스의
    // 마지막 Term에서 closeTab이 세션 latch로 빠지며 해제된 surface에 쓰고(UAF) 이어지는 rebuild가 빈 pane을
    // 인덱싱해 패닉한다(code-review max).
    self.requestClose(.{ .agent_term = .{ .tab = tab_index, .pane = pane_index, .term = term_index } });
}

/// 에이전트 행 클릭 → **그 에이전트가 도는 자리**로 이동한다(§5): 워크스페이스 전환 → 그 Pane 포커스 →
/// 그 Pane 안에서 그 Term 탭 활성화. **3단계가 핵심이다** — Pane까지만 가면 그 Pane의 현재 활성 탭이 보일 뿐,
/// 사용자가 목록에서 지목한 에이전트는 여전히 가려진 탭에 있다.
/// 인덱스는 클릭 시점에 **재조회**해 유효하지 않으면(사이 tick에 닫힘·종료) 무동작한다(stale deref 금지).
pub fn focusAgentRow(self: *AppSession, tab_index: usize, pane_index: usize, term_index: usize) void {
    if (tab_index >= self.tabs.items.len) return;
    _ = tab_ops.switchTab(self, tab_index); // 1) 다른 카드였으면 그 워크스페이스로
    const tab = self.tabs.items[tab_index];
    if (pane_index >= tab.panes.items.len) return;
    const pane = tab.panes.items[pane_index];
    _ = pane_ops.focusPaneByPtr(self, pane); // 2) 그 Pane으로(같은 pane이면 무동작)
    if (term_index >= pane.terms.items.len) return;
    self.focusTerm(term_index); // 3) 그 Pane 안 그 Term 탭으로 — 가려진 탭이 실제로 앞으로 나온다
    self.metal_dirty = true;
}

/// 카드 아래에 붙는 **에이전트 목록 행**을 방출한다(§1 규칙): 0개면 아무것도, 1개면 행 하나만(토글 없음),
/// 2개 이상이면 `N agents` 토글 + (펼쳐졌으면) 행들. 접힘은 `tab.agents_collapsed`가 든다(비영속, §4).
pub fn appendAgentRows(self: *AppSession, out: *std.ArrayList(chrome.components.sidebar.Row), tab_index: usize, depth: u8) void {
    if (tab_index >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_index];
    var agents: std.ArrayList(WorkspaceAgent) = .empty;
    defer agents.deinit(self.allocator);
    workspace_ops.collectWorkspaceAgents(tab, &agents, self.allocator);
    if (agents.items.len == 0) return;
    // **1개일 때도 토글을 낸다.** 처음엔 "1개면 토글 없이 행 하나"로 뒀지만(토글이 군더더기라고 봤다), 실사용에서
    // 에이전트 하나짜리 카드도 접을 수 없어 목록이 길어지는 게 불편했다(사용자 요청). 접기는 개수와 무관하게
    // "이 카드를 지금 얼마나 펼쳐 둘 것인가"의 문제다.
    out.append(self.allocator, .{
        .agent_toggle = .{
            .tab = tab_index,
            .count = std.math.lossyCast(u16, agents.items.len),
            .collapsed = tab.agents_collapsed,
            .depth = depth,
            .last = tab.agents_collapsed, // 접히면 토글이 이 묶음의 마지막 행이다(아래 여백을 카드와 같게)
        },
    }) catch return;
    if (tab.agents_collapsed) return; // 접혔으면 행은 안 낸다(토글만 남는다)
    for (agents.items, 0..) |ag, idx| {
        out.append(self.allocator, .{
            .agent = .{
                .tab = tab_index,
                .pane = ag.pane,
                .term = ag.term,
                .depth = depth,
                .lines = sidebar_ops.sidebarAgentRowLines(self, tab, ag),
                .last = idx + 1 == agents.items.len, // 마지막 행만 아래 여백을 카드와 같게(밴드 하단)
            },
        }) catch return;
    }
}

/// 인덱스 경로 → 라이브 Term(범위 밖이면 null). 목록 행이 포인터 대신 인덱스를 드는 계약의 재조회 지점이다.
pub fn agentTermOf(tab: *Tab, ag: WorkspaceAgent) ?*Term {
    if (ag.pane >= tab.panes.items.len) return null;
    const pane = tab.panes.items[ag.pane];
    if (ag.term >= pane.terms.items.len) return null;
    return pane.terms.items[ag.term];
}

pub fn agentPollIntervalTicks(self: *const AppSession) u32 {
    return self.ticksForMs(agent_poll_interval_ms);
}

pub fn agentObserverIntervalTicks(self: *const AppSession) u32 {
    return self.ticksForMs(agent_observer_interval_ms);
}

/// running 에이전트 스피너(사이드바 이퀄라이저 파형) 위상을 한 스텝 진행한다 — **tick()에서 출력과 무관하게 매 tick**
/// 호출된다. 커서 blink(updateCursorBlink)와 달리 스피너는 활성 surface의 출력과 무관한 애니메이션이라, 출력 게이트
/// (`output>0`이면 resetCursorBlink, else updateCursorBlink)에 얹으면 안 된다 — 연속 출력(SSH firehose·바쁜 원격 TUI)이
/// 매 tick 스피너 advance를 굶겨 **다른 탭의 running 에이전트 스피너가 멈추던** 버그의 근본 수정(§10.5 primary). 사이드바에
/// **실제로 보이는** 카드 중 running 에이전트가 있거나 archive worker가 목록을 읽는 동안에만 위상을 진행하고 사이드바만 부분
/// 투영(chrome_dirty)한다. archive spinner도 같은 wall-clock 위상을 재사용해 별도 tick/타이머를 만들지 않는다.
pub fn advanceAgentSpinner(self: *AppSession) void {
    if (!anyAgentRunning(self) and !self.agent_session_archive_loading) {
        self.agent_spin_last_ns = 0; // running 없음 — 무동작 + baseline 리셋(다음 running이 새 위상으로 시작)
        return;
    }
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (self.agent_spin_last_ns == 0) {
        self.agent_spin_last_ns = now; // 첫 running tick — baseline만 세팅, 위상 불변
        return;
    }
    const interval_ns: i128 = @as(i128, agent_spin_interval_ms) * std.time.ns_per_ms;
    const elapsed = now - self.agent_spin_last_ns;
    if (elapsed < interval_ns) return; // 한 주기 안 지남 — 아직 진행 안 함
    // **wall-clock 경과분**만큼 위상 진행(tick 카운트 아님). tick이 느리거나 stall 후 재개돼도 실시간을 따라가
    // 부드럽고, 큰 gap이면 여러 프레임을 한 번에 catch-up한다(§10.5 secondary). 소비한 interval의 나머지는 남겨
    // (last_ns를 정확히 소비분만큼 전진) 위상을 실시간에 drift 없이 고정한다. 파형 길이(14)로 wrap.
    const steps = @divTrunc(elapsed, interval_ns);
    const wrap: u8 = @intCast(@mod(steps, @as(i128, spinner_wave.len)));
    self.agent_spin_frame = (self.agent_spin_frame + wrap) % @as(u8, @intCast(spinner_wave.len));
    self.agent_spin_last_ns += steps * interval_ns;
    self.chrome_dirty = true; // [A] 사이드바만 부분 투영(sync hold 중에도 진행 + full-grid 재셰이프 회피)
}

/// 사이드바에 **실제로 보이는** 워크스페이스 카드 중 running 에이전트가 있으면 true — 스피너 위상을 진행할지/사이드바를
/// 재투영할지 결정한다. 접힘이면 스피너가 안 보이고(false), 검색 필터로 숨은 탭은 카드가 없으므로(스피너 미표시) 제외해야
/// 한다 — 그래서 `tabs` 전체가 아니라 `sidebar_rows`(필터 통과 = 표시 카드)만 본다(code-review high #1: 옛 전체-스캔이
/// 접힘·필터아웃에도 130ms 재투영을 돌리던 회귀). 빈 검색이면 visible_tabs=전체라 평소와 동일.
pub fn anyAgentRunning(self: *AppSession) bool {
    // **사이드바 카드의 애니메이션 파형만** 이 위상 게이트에 걸린다 — 탭바 running 표시는 **정적 1칸 플래그(●)**라
    // 매 프레임 재투영이 필요 없다(상태 변화 시에만 pollAgentKinds가 dirty; 게이트는 agentDisplayVisible이 탭바까지 커버).
    // 접힘·chrome_minimal이면 사이드바가 없어(sidebar_width_px=0) 카드 파형도 없으니 false(표시면 없는데 130ms 재셰이프
    // 방지, code-review high #1 + max). 검색 필터로 숨은 탭은 카드가 없으므로 `sidebar_rows`만 본다. running 판정은
    // 활성 Term만이 아니라 **어느 pane/Term이든**(tabHasRunningAgent) — 백그라운드 Term도 카드 파형을 돌린다(범위 확장).
    if (self.sidebar_collapsed or self.chrome_minimal) return false;
    for (self.sidebar_rows.items) |row| switch (row) {
        .card => |c| if (c.tab < self.tabs.items.len and tab_ops.tabHasRunningAgent(self.tabs.items[c.tab])) return true,
        .agent_toggle, .agent => {}, // 같은 탭의 부속이라 카드 판정으로 충분
        .group_header => {}, // 헤더 row엔 에이전트가 없다
    };
    return false;
}

pub fn pollAgentKinds(self: *AppSession) void {
    self.agent_poll_ticks += 1;
    self.agent_observer_poll_ticks += 1;
    // 시간 경과만으로 바뀌는 표시(활동 시각)를 위한 주기적 재렌더. 사이드바가 보이고 에이전트가 하나라도
    // 있을 때만 — 그 조건이 아니면 그릴 것이 없다.
    self.agent_age_repaint_ticks += 1;
    if (self.agent_age_repaint_ticks >= self.ticksForMs(agent_age_repaint_interval_ms)) {
        self.agent_age_repaint_ticks = 0;
        // 사이드바 카드가 실제로 보이는 상태에서만(접힘·minimal chrome이면 그릴 자리가 없다).
        if (!self.sidebar_collapsed and !self.chrome_minimal and anyAgentPresent(self)) self.metal_dirty = true;
    }
    const periodic_kind_probe = self.agent_poll_ticks >= agentPollIntervalTicks(self);
    const observer_probe = self.agent_observer_poll_ticks >= agentObserverIntervalTicks(self);
    if (!periodic_kind_probe and !observer_probe) return;
    if (periodic_kind_probe) self.agent_poll_ticks = 0;
    if (observer_probe) self.agent_observer_poll_ticks = 0;
    if (!self.surface_initialized) return;
    // 모든 pane × 모든 Term을 보되 syscall은 ≈0.5s로 throttle한다. 화면에 카드/탭바가 실제로 보이는 탭만
    // 상태 변화 시 dirty해, background observer가 불필요한 프레임을 만들지 않는다.
    for (self.tabs.items, 0..) |tab, ti| {
        const displayed = agentDisplayVisible(self, ti); // 스피너/플래그/아이콘 재렌더 게이트(카드 or 활성 탭 탭바) — 탭 내 모든 Term 공유
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.live_initialized or term.rt.terminated) continue; // 종료(미reap) Term은 건너뜀(dispatchBell과 동형)
                const be = self.backendFor(term);
                be.readObservation(term.rt.handle, self.allocator, &term.rt.observation, periodic_kind_probe) catch {
                    // 마지막 coherent snapshot은 유지하되 current로 가장하지 않는다. remote reconnect 동안 kind/state를
                    // none/idle로 덮지 않는 것이 알림 누락보다 안전하다.
                    if (term.rt.observation.availability == .current)
                        term.rt.observation.availability = .stale;
                };
                const observation_current = term.rt.observation.availability == .current;
                const foreground_available = observation_current and term.rt.observation.foreground_available;
                const pgid = if (observer_probe and foreground_available)
                    (term.rt.observation.foreground_pgid orelse 0)
                else
                    term.rt.agent_observer_pgid;
                const pgid_changed = observer_probe and pgid != term.rt.agent_observer_pgid;
                if (observer_probe and foreground_available) term.rt.agent_observer_pgid = pgid;
                if ((periodic_kind_probe or pgid_changed) and foreground_available) {
                    const prev = term.agent_kind;
                    term.agent_kind = classifyAgentProcesses(term.rt.observation.foreground_processes.items);
                    if (diag_gate.maruDebugEnabled()) std.log.scoped(.agentdiag).info("kind={s} pgid_changed={} live={} term=0x{x}", .{ @tagName(term.agent_kind), pgid_changed, term.rt.live_initialized, @intFromPtr(term) });
                    if (term.agent_kind != prev) {
                        if (displayed) self.metal_dirty = true; // 보이는 Term의 에이전트 변화만 재렌더
                        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info("agent: {s}", .{@tagName(term.agent_kind)});
                        // 새 프로세스의 화면/OSC/activity를 이전 상태와 섞지 않는다.
                        term.agent_state = .unknown;
                        term.agent_stabilizer.reset();
                        term.agent_screen_generation = 0;
                        term.agent_last_output_ms = 0;
                        // 새 프로세스의 대화를 이전 세션 것과 섞지 않는다. 응답 줄이 사라지면 행 줄 수도
                        // 바뀌므로 **재투영까지** 해야 한다 — metal_dirty만으로는 행 높이가 옛 값으로 남는다.
                        const had_reply_kind = term.agent_transcript.owned.reply().len > 0;
                        term.agent_transcript.reset();
                        if (had_reply_kind) sidebar_ops.rebuildSidebar(self) catch {};
                    }
                }
                if (observer_probe and observation_current and term.agent_kind != .none) {
                    pollAgentState(self, term, displayed);
                    pollAgentTranscript(self, term, displayed);
                }
            }
        }
    }
}

/// 세션 기록 파일에서 그 Term의 **마지막 대화**(프롬프트·응답)를 갱신한다(docs/sidebar-agent-list.md §7).
///
/// **선택적 보강**(계약 1)이라 어떤 실패도 조용히 지나간다 — 디렉터리가 없든(경로 인코딩 규칙이 provider 변경으로
/// 어긋나든), 파일을 못 열든, JSON이 깨졌든 행은 아이콘·상태·폴더·브랜치로 정상 동작하고 대화 줄만 빈다.
/// 그래서 이 함수는 error를 내지 않는다.
pub fn pollAgentTranscript(self: *AppSession, term: *Term, displayed: bool) void {
    if (term.agent_kind == .none) return;
    const cache = &term.agent_transcript;
    const now = self.awakeMs();
    if (cache.last_poll_ms != 0 and now -| cache.last_poll_ms < transcript_poll_interval_ms) return;
    cache.last_poll_ms = now;

    // **줄 수를 좌우하는 값**으로 재투영을 판정한다. 예전엔 `isEmpty()`(프롬프트 OR 응답) 변화로 봤는데, 행
    // 줄 수는 `reply()`만 늘리므로 "프롬프트는 이미 있고 응답만 새로 왔다"에서 재투영이 안 돌아 렌더는 3줄을
    // 그리고 행 높이는 2줄로 남았다 — 그러면 응답 줄이 다음 행 위에 그려지고 클릭이 이웃 행의 ✕에 닿는다
    // (code-review max). 프롬프트는 1행 안에서 자리를 바꿀 뿐이라 줄 수에 영향이 없다.
    // **provider가 밝힌 세션 신원**을 먼저 확보한다(§7.2 채택안). 얻으면 그 값으로 파일을 확정하고, 못 얻으면
    // 아래 provider 경로가 활동 상관 폴백으로 내려간다. 자식이 떠 있는 순간에만 읽히므로 캐시가 필수다.
    // The provider-native identity is also the authority for the archive detail's exact
    // live-Term action.  It must not depend on a shell OSC-7 CWD report: an agent launched
    // before its shell integration emits CWD can still be the already-open session the user
    // asked to return to.  Transcript path lookup below does require CWD, so keep that
    // optional enrichment separate from identity observation.
    refreshAgentSessionIdentity(self, term);
    const cwd = term.rt.observation.cwd.items;
    if (cwd.len == 0) return;
    const had_reply = cache.owned.reply().len > 0;
    // provider마다 다른 건 **경로 규칙·신원 확인·레코드 모양** 셋뿐이다(§7.3). 매핑 규율(고정하지 않음)·throttle·
    // 재투영은 여기 공통으로 남는다.
    const changed = switch (term.agent_kind) {
        .claude => refreshClaudeTranscript(self, term, cwd),
        .codex => refreshCodexTranscript(self, term, cwd),
        .none => false,
    };
    if (!changed) return;

    // 대화 **유무**가 바뀌면 행 줄 수가 바뀌므로 재투영이 필요하다(행 높이·hit-test·밴드가 sidebar_rows에서
    // 나온다). 텍스트만 바뀐 경우엔 라벨이 매 프레임 조립되므로 dirty만 세우면 된다.
    const has_reply = cache.owned.reply().len > 0;
    if (has_reply != had_reply) sidebar_ops.rebuildSidebar(self) catch {};
    if (displayed) self.metal_dirty = true;
}

/// 자식 프로세스 env에서 세션 신원을 읽는다(§7.2.1 — 기본 경로, 사용자 파일 무침습).
pub fn agentIdentityFromChildEnv(self: *AppSession, term: *Term, key: []const u8, buf: []u8) ?[]const u8 {
    _ = self;
    const pid = agentProcessPid(term.rt.observation.foreground_processes.items, term.agent_kind) orelse return null;
    return maru.pty.PtySession.agentSessionIdentity(pid, key, buf);
}

/// claude 상태줄 훅이 적어둔 per-pane 신원 파일을 읽는다(§7.2.2 — 옵션 보강).
///
/// 훅은 `MARU_PANE_ID`(= surface id)를 파일명으로 쓰므로 **어느 Term의 세션인지가 자동으로 붙는다**. 자식 env가
/// 안 잡히는 경우(도구를 한 번도 안 쓴 세션)를 이 경로가 메운다. codex는 해당 없다 — 외부 스크립트를 실행하는
/// 상태줄 설정이 없다.
pub fn agentIdentityFromStatuslineFile(self: *AppSession, term: *Term, buf: []u8) ?[]const u8 {
    if (term.agent_kind != .claude) return null;
    const sl = maru.session.agent_statusline;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = sessionCacheBase(a) orelse return null;
    const path = std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ base, sl.session_dir_rel, term.surfaceId() }) catch return null;
    const raw = readFileAlloc(self.io, a, path) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!sl.plausibleIdentity(trimmed)) return null;
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

/// claude 상태줄 훅을 config(`sidebar.agent-transcript-hook`)에 맞춰 설치하거나 제거한다. 앱 시작 시 한 번,
/// 그리고 config 재적용 때 호출한다(docs/sidebar-agent-list.md §7.2.2).
///
/// **사용자 소유 파일을 건드리는 유일한 자리**라 규율을 여기서 지킨다:
/// - 이미 사용자가 쓰던 상태줄이 있으면 **지우지 않고 감싼다**(우리 스크립트가 그 명령을 그대로 실행).
/// - 감쌌던 원래 명령의 **단일 출처는 설치 마커**다. 스크립트 안의 표식은 사람이 읽으라고 있는 것이고, 우리가
///   매 실행마다 덮어쓰는 파일을 유일한 근거로 삼았다가 실제로 사용자 상태줄을 영구히 잃었다(§7.2.2).
/// - 마커 파일 `flock`으로 **인스턴스 사이를 직렬화**한다. 잡지 못하면 물러난다.
/// - 끄면 감쌌던 원래 명령을 `statusLine`에 복원하고 우리 것(스크립트·마커)을 지운다 — 설치 전 상태로 돌아간다.
///
/// best-effort다. 실패는 조용히 지나간다 — 이 훅이 없어도 대화는 자식 신원 경로(§7.2.1)로 대부분 잡힌다.
pub fn reconcileAgentStatusline(self: *AppSession) void {
    if (!is_macos) return;
    const sl = maru.session.agent_statusline;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // **claude가 설치돼 있을 때만 손댄다.** 설정 디렉터리는 claude 자신의 규칙대로 `CLAUDE_CONFIG_DIR`이
    // 우선이고 없으면 `$HOME/.claude`다(과거 hook cleanup과 같은 판정). 그 디렉터리가 없으면 claude를 쓰지
    // 않는 사람이므로 **디렉터리를 만들지 않고 그대로 물러난다** — 남의 홈에 우리 흔적을 남길 이유가 없다.
    var claude_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const claude_dir = settings_ops.claudeConfigDir(&claude_dir_buf) orelse return;
    const dir_handle = std.Io.Dir.openDirAbsolute(self.io, claude_dir, .{}) catch return;
    dir_handle.close(self.io);
    const script_path = std.fmt.allocPrint(a, "{s}/{s}", .{ claude_dir, sl.script_name }) catch return;
    const settings_path = std.fmt.allocPrint(a, "{s}/settings.json", .{claude_dir}) catch return;
    const marker_path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ claude_dir, sl.marker_name }, 0) catch return;

    const want = self.loaded_config.config.sidebar.agent_transcript_hook;

    // 여기서부터 끝까지가 하나의 read-modify-write다 — 락 안에서만 읽고 쓴다. 읽기와 쓰기 사이에 다른 인스턴스가
    // 끼어드는 것이 원본 소실의 원인이었다.
    //
    // 훅을 끈 사람에게는 **마커를 만들지 않는다**(`create = want`). 만들었다 지우는 것도 남의 홈을 건드리는
    // 일이고, 조기 반환 경로에서 빈 마커가 잔류한다. 마커가 없으면 잠글 것도 없으니 락 없이 진행한다.
    const marker_existed = readFileState(self.io, a, marker_path) != .absent;
    const lock = switch (StatuslineLock.acquire(marker_path, want)) {
        // 다른 인스턴스가 지금 같은 일을 하고 있다 → 우리가 할 일은 없다.
        .contended => return,
        // 애초에 잠글 수 없는 환경(권한·파일시스템)이다. 락을 넣기 전과 같은 위험을 지고 진행한다 —
        // 조용한 영구 무동작보다 낫다.
        .unlockable => |l| l,
        .locked => |l| l,
    };
    defer lock.release();
    var marker_written = false;
    // 잠그느라 **새로 만든** 빈 마커는 아무것도 기록하지 않았으면 남기지 않는다(원래 있던 마커는 건드리지 않는다).
    defer if (!marker_existed and !marker_written) {
        std.Io.Dir.cwd().deleteFile(self.io, marker_path) catch {};
    };

    const script_read = readFileState(self.io, a, script_path);
    const script_state: sl.ScriptState = switch (script_read) {
        .absent => .absent,
        .unreadable => .unreadable,
        .present => .present,
    };
    const existing_script: ?[]const u8 = switch (script_read) {
        .present => |body| body,
        else => null,
    };
    const settings = readStatusLineState(a, self.io, settings_path);
    const marker: ?sl.Marker = switch (readFileState(self.io, a, marker_path)) {
        .present => |text| sl.parseMarker(text),
        else => null,
    };
    const script_wrapped = if (existing_script) |body| sl.extractWrappedCommand(a, body) else null;

    if (!want) {
        // **복원**: 마커 → 스크립트 wrap 순으로 원본을 찾는다. 사용자가 그 사이 statusLine을 직접 바꿨다면
        // (우리 것이 아니면) settings는 그대로 두고 우리 파일만 거둔다.
        const restored = switch (sl.restoreActionFor(settings, marker, script_wrapped)) {
            // 현재 상태를 못 읽었다 — 지우고 나면 되돌릴 근거가 사라지므로 **아무것도 하지 않는다**.
            .unknown => return,
            .leave => true,
            .set => |cmd| writeStatusLineCommand(a, self.io, settings_path, cmd, settings),
            .clear => writeStatusLineCommand(a, self.io, settings_path, null, settings),
        };
        // **복원에 실패했으면 근거를 지우지 않는다.** 지워버리면 사용자가 나중에 파일을 고쳐도 되살릴 것이 없다.
        if (!restored) return;
        std.Io.Dir.cwd().deleteFile(self.io, script_path) catch {};
        // 마커는 락 대상이라 지금 잡고 있는 fd가 가리킨다. 지우고 나서 close해도 락은 정상적으로 풀린다.
        std.Io.Dir.cwd().deleteFile(self.io, marker_path) catch {};
        return;
    }

    // 읽은 뒤에도 우리가 잠근 그 마커가 맞는지 확인한다 — 다른 인스턴스가 지우고 새로 만들었으면 우리 락은
    // 더 이상 아무것도 막지 못한다.
    if (!lock.stillOwns(self.io, marker_path)) return;

    // 계획(없으면 설치·우리 것이면 갱신·남의 것이면 감싼다)과 **써도 되는가**를 함께 판정한다.
    const write = switch (sl.actionFor(settings, marker, script_state, script_wrapped)) {
        .skip => return,
        .write => |w| w,
    };

    const cache_base = sessionCacheBase(a) orelse return;
    const session_dir = std.fmt.allocPrint(a, "{s}/{s}", .{ cache_base, sl.session_dir_rel }) catch return;

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    sl.scriptBody(&body, a, session_dir, write.wrapped) catch return;

    // 마커를 **스크립트보다 먼저** 쓴다 — 이 순서라야 중간에 죽어도 원본을 되찾을 근거가 남는다. 확정이 아닌
    // 값(모르는 상태에서 나온 것)은 기록하지 않는다: `wrapped 0`은 나중에 `statusLine` 키를 지우는 근거가 된다.
    if (write.record_marker) {
        var marker_body: std.ArrayListUnmanaged(u8) = .empty;
        defer marker_body.deinit(a);
        sl.markerBody(&marker_body, a, write.wrapped) catch return;
        // 내용이 같으면 다시 쓰지 않는다 — reconcile은 세팅 GUI 조작마다 돌고, 매번 truncate하면 그때마다
        // 잘린 마커가 보이는 창이 생긴다.
        const same = switch (readFileState(self.io, a, marker_path)) {
            .present => |old| std.mem.eql(u8, old, marker_body.items),
            else => false,
        };
        marker_written = same or lock.writeBody(marker_body.items);
        if (!marker_written) return; // 근거를 남기지 못했으면 스크립트도 바꾸지 않는다
    } else {
        marker_written = marker != null; // 기존 마커는 그대로 둔다
    }

    // 내용이 같으면 쓰지 않는다 — 매 실행마다 사용자 파일의 mtime을 흔들 이유가 없다.
    if (existing_script) |old| if (std.mem.eql(u8, old, body.items)) {
        if (settings != .command or !sl.commandIsOurs(settings.command))
            _ = writeStatusLineCommand(a, self.io, settings_path, script_path, settings);
        return;
    };
    writeExecutableFile(self.io, script_path, body.items, true) catch return;
    _ = writeStatusLineCommand(a, self.io, settings_path, script_path, settings);
}

/// 에이전트가 자식에게 내려주는 **세션 신원**을 캐시에 채운다(claude `CLAUDE_CODE_SESSION_ID`, codex
/// `CODEX_THREAD_ID`). 이미 값이 있으면 자식이 없어도 유지하고, 새 값이 오면 교체한다(`/clear`로 세션이
/// 갈리는 경우 — 같은 프로세스가 새 id를 내려준다).
///
/// 자식은 **도구 실행 중에만** 존재하므로 대부분의 호출은 null이다. 그래서 값을 얻지 못한 것 자체는 실패가
/// 아니고, 호출부는 신원이 있으면 확정 결속·없으면 활동 상관 폴백으로 갈린다.
pub fn refreshAgentSessionIdentity(self: *AppSession, term: *Term) void {
    if (!is_macos) return; // 원격 host-backed는 pid가 이 기계에 없다 — 폴백 경로가 받는다
    const key: []const u8 = switch (term.agent_kind) {
        .claude => "CLAUDE_CODE_SESSION_ID",
        .codex => "CODEX_THREAD_ID",
        .none => return,
    };
    var buf: [maru.session.agent_transcript.max_identity_bytes]u8 = undefined;
    const value = agentIdentityFromChildEnv(self, term, key, &buf) orelse
        agentIdentityFromStatuslineFile(self, term, &buf) orelse return;
    const cache = &term.agent_transcript;
    if (std.mem.eql(u8, cache.identity(), value)) return;
    // 신원이 바뀌었다 = 다른 세션이다. 옛 대화가 새 세션 행에 남지 않게 매핑을 통째로 버린다.
    cache.reset();
    cache.setIdentity(value);
    self.metal_dirty = true;
}

/// claude: 작업 디렉터리를 인코딩한 디렉터리의 **직속** 파일만 본다 — 서브에이전트 기록은 `<세션 id>/` 하위에
/// 쌓이므로 그것만으로 배제된다(§7.3). 대화가 갱신됐으면 true.
pub fn refreshClaudeTranscript(self: *AppSession, term: *Term, cwd: []const u8) bool {
    const tr = maru.session.agent_transcript;
    const cache = &term.agent_transcript;
    // **신원이 없으면 아무것도 하지 않는다.** 예전엔 여기서 "그 디렉터리의 가장 최신 파일"을 추측했는데, 그게
    // 새 터미널에 직전 세션의 대화를 붙이고(사용자 제보) 같은 cwd의 두 에이전트가 서로의 대화를 물게 했다.
    // 추측으로 틀린 대화를 보여주느니 비우는 편이 낫다는 계약 1과도 어긋났다 — 그래서 폴백을 없앴다(§7.2).
    if (cache.identity_len == 0) return false;
    var claude_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const claude_dir = settings_ops.claudeConfigDir(&claude_dir_buf) orelse return false;
    var slug_buf: [1024]u8 = undefined;
    const slug = tr.claudeDirName(cwd, &slug_buf) orelse return false;
    var path_buf: [2048]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/projects/{s}", .{ claude_dir, slug }) catch return false;
    const dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{}) catch return false;
    defer dir.close(self.io);

    // **신원이 곧 파일명이다** — `CLAUDE_CODE_SESSION_ID`가 그대로 `<id>.jsonl`이다(provider가 자식 env로 밝힌
    // 값, §7.2). 디렉터리를 훑을 것도 시간을 비교할 것도 없다.
    var name_buf: [tr.max_name_bytes]u8 = undefined;
    const wanted = std.fmt.bufPrint(&name_buf, "{s}.jsonl", .{cache.identity()}) catch return false;
    if (!std.mem.eql(u8, wanted, cache.fileName())) {
        cache.setFileName(wanted);
        cache.read_mtime_ns = 0;
        cache.owned.clear();
    }

    // mtime이 그대로면 다시 읽지 않는다(계약 4).
    const st = dir.statFile(self.io, cache.fileName(), .{}) catch return false;
    if (st.mtime.nanoseconds == cache.read_mtime_ns) return false;
    cache.read_mtime_ns = st.mtime.nanoseconds;

    const tail_buf = self.allocator.alloc(u8, tr.max_tail_bytes) catch return false;
    defer self.allocator.free(tail_buf);
    const tail = tr.readTail(self.io, dir, cache.fileName(), tail_buf);
    if (tail.len == 0) return false;

    var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer parse_arena.deinit();
    var fresh: maru.session.agent_transcript.Owned = .{};
    tr.parseClaudeTail(parse_arena.allocator(), tail, &fresh);
    // 못 찾은 항목은 이전 값을 지킨다(§7.8) — provider 무관 공통 규율.
    tr.mergeKeepingMissing(&cache.owned, &fresh);
    return true;
}

/// codex: 날짜 계층(`YYYY/MM/DD`)이라 디렉터리 이름이 작업 디렉터리를 말해주지 않고, 서브에이전트 기록이
/// **같은 계층에 섞인다**(실측: 최근 40개 중 32개). 그래서 최근 후보를 열어 `session_meta`로 신원을 확인한다 —
/// `thread_source == "user"`이고 cwd가 이 Term과 같은 첫 후보를 고른다. 대화가 갱신됐으면 true.
pub fn refreshCodexTranscript(self: *AppSession, term: *Term, cwd: []const u8) bool {
    const tr = maru.session.agent_transcript;
    const cache = &term.agent_transcript;
    _ = cwd; // 신원으로 파일을 확정하므로 cwd 대조가 필요 없다(그 값이 곧 그 세션이다)
    if (cache.identity_len == 0) return false; // claude와 같은 이유로 폴백 없음(§7.2)
    const home_z = std.c.getenv("HOME") orelse return false;
    const home = std.mem.span(home_z);
    var path_buf: [2048]u8 = undefined;
    const root_path = std.fmt.bufPrint(&path_buf, "{s}/.codex/sessions", .{home}) catch return false;
    const root = std.Io.Dir.openDirAbsolute(self.io, root_path, .{}) catch return false;
    defer root.close(self.io);

    // **신원이 파일명에 박혀 있다** — rollout 파일명이 `rollout-<ts>-<thread_id>.jsonl`이고 `CODEX_THREAD_ID`가
    // 그 thread_id(= `session_meta.id`)다. 후보를 열어 신원을 확인할 필요가 없어졌다.
    if (cache.name_len == 0) {
        var suffix_buf: [tr.max_identity_bytes + 8]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "{s}.jsonl", .{cache.identity()}) catch return false;
        var found_buf: [tr.max_name_bytes]u8 = undefined;
        const found = tr.findCodexByThreadId(self.io, root, suffix, &found_buf) orelse return false;
        cache.setFileName(found);
        cache.read_mtime_ns = 0;
    }

    const st = root.statFile(self.io, cache.fileName(), .{}) catch return false;
    if (st.mtime.nanoseconds == cache.read_mtime_ns) return false;
    cache.read_mtime_ns = st.mtime.nanoseconds;

    const tail_buf = self.allocator.alloc(u8, tr.max_tail_bytes) catch return false;
    defer self.allocator.free(tail_buf);
    const tail = tr.readTail(self.io, root, cache.fileName(), tail_buf);
    if (tail.len == 0) return false;

    var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer parse_arena.deinit();
    var fresh: maru.session.agent_transcript.Owned = .{};
    tr.parseCodexTail(parse_arena.allocator(), tail, &fresh);
    tr.mergeKeepingMissing(&cache.owned, &fresh);
    return true;
}

/// 어느 Term이든 에이전트가 돌고 있는가 — 활동 시각 재렌더 게이트. 전-Term 순회지만 필드 읽기뿐이라 20초에
/// 한 번 도는 비용으로 무시할 만하다.
pub fn anyAgentPresent(self: *AppSession) bool {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.agent_kind != .none) return true;
            }
        }
    }
    return false;
}

/// foreground process와 터미널이 이미 소유한 bounded 화면 tail·OSC title/progress·최근 PTY 출력을 결합한다.
/// raw 화면/제목은 로그에 남기지 않고, 순수 observer의 rule id와 최종 상태만 진단한다.
pub fn pollAgentState(self: *AppSession, term: *Term, displayed: bool) void {
    const agent: maru.session.agent_observer.Agent = switch (term.agent_kind) {
        .none => return,
        .claude => .claude,
        .codex => .codex,
    };
    const observation = &term.rt.observation;
    if (observation.availability != .current) return;
    const generation = observation.observer_generation;
    const now_ms = self.awakeMs();
    const activity_age_ms = now_ms -| term.agent_last_output_ms;
    const output_active = term.agent_last_output_ms != 0 and activity_age_ms <= agent_activity_window_ms;
    if (generation == term.agent_screen_generation and term.agent_state == .idle and !output_active and
        !term.agent_stabilizer.needsExpiryProbe()) return;
    const screen = self.backendFor(term).dumpRecentText(term.rt.handle, self.allocator, agent_screen_tail_rows, agent_screen_tail_bytes) catch null;
    defer if (screen) |owned| self.allocator.free(owned);

    term.agent_screen_generation = generation;
    const detection = maru.session.agent_observer.detect(agent, .{
        .screen = screen orelse "",
        .osc_title = observation.window_title.items,
        .osc_progress = observation.agent_progress.items,
        .output_active = output_active,
    });
    observation.clearAgentProgress();
    const previous = term.agent_state;
    const current = term.agent_stabilizer.observe(detection, now_ms);
    term.agent_state = current;
    // 턴이 끝난 순간의 작업트리를 굳힌다(§6.1) — "에이전트가 방금 바꾼 것"의 기준이 이 tree다.
    if (maru.session.turn_snapshot.isTurnEnd(turnStateOf(previous), turnStateOf(current))) {
        captureTurnSnapshot(self, term.surfaceId());
    }
    if (current != previous) {
        if (displayed) self.metal_dirty = true;
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info(
            "agent previous={s} state={s} rule={s} idle={} blocker={} running={} activity_age_ms={d}",
            .{ @tagName(previous), @tagName(current), detection.rule_id, detection.visible_idle, detection.visible_blocker, detection.visible_running, activity_age_ms },
        );
    }
}

/// 에이전트 종류 브랜드색(claude=Anthropic 코랄 #CC785C, codex=OpenAI 청록 #10A37F). none이면 null. 아이콘·상태줄
/// 스피너·탭바 파형이 **모두 이 단일 출처**를 쓴다(색이 갈리지 않게 — code-review max, 옛 두 곳 하드코딩 통합).
pub fn agentBrandColor(kind: AgentKind) ?maru.color.Rgb {
    return switch (kind) {
        .claude => .{ .r = 0xCC, .g = 0x78, .b = 0x5C }, // Anthropic 공식 코랄 #CC785C
        .codex => .{ .r = 0x10, .g = 0xA3, .b = 0x7F }, // OpenAI 청록 #10A37F
        .none => null,
    };
}

/// running 마커(`●`) UTF-8 한 글자. 셀 draw list가 마커만 그릴 때 쓴다(제목은 measured 경로).
pub fn agentFlagUtf8() []const u8 {
    return "\u{25CF}";
}

pub fn recolorAgentFlagCells(cells: anytype, kind: AgentKind) void {
    const brand = agentBrandColor(kind) orelse return;
    for (cells) |*c| {
        if (c.codepoint == agent_running_flag) c.style.foreground = .{ .rgb = brand };
    }
}
