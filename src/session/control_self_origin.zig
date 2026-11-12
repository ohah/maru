//! 컨트롤 플레인 self-origin 판정(§8.4 「1g」) — 소켓에 붙은 프로세스가 **어느 pane 에서 왔는지**를 OS 가 본
//! 프로세스 관계로 찾는다. 순수(L2): 프로세스 정보는 주입한 공급자(`Provider`)가 주고, 이 파일은 판정만 한다.
//!
//! **왜 셀렉터(`$MARU_PANE_ID`)를 믿지 않나.** 셀렉터는 주장이다 — 같은 uid 의 아무 프로세스나 pane 번호를 대면
//! 그 pane 으로 행세했고, 그것이 browser.* 의 확인 grant(pane·대상 탭·scope 를 세션 동안 기억)까지 탔다. 그리고
//! 세션 유지 pane(기본)에는 셀렉터 자체가 없어 에이전트가 확인 모달을 아예 받지 못했다(재실행 뒤 낡은 번호가 다른
//! pane 을 가리키지 않게 일부러 비운다). 그래서 서버가 직접 찾는다(사용자 결정 2026-10-09).
//!
//! **어떻게 찾나.** 붙은 프로세스(peer)에서 부모 쪽으로 거슬러 올라가 **자기 제어 터미널의 foreground 그룹에 속한 첫
//! 조상**을 찾는다 — 요청이 「지금 그 pane 의 foreground 작업(셸이 프롬프트에 있으면 셸)」에서 나왔는가(사용자 결정
//! 2026-10-09). peer 자신만 보지 않는 것은 에이전트 때문이다: Claude Code 는 Bash 도구의 명령을 새 세션(setsid)으로
//! 띄워 명령에는 제어 터미널이 없고, Codex 는 자식을 새 process group 으로 띄워 터미널은 있지만 foreground 가 아니다
//! (둘 다 실측 — 본체는 pane 의 tty·foreground). 다른 작업(vim 등)이 foreground 인 동안의 백그라운드 작업은 조상 셸도
//! foreground 가 아니라 거절된다. 찾은 프로세스의 **세션 번호**가 어느 pane 인지를 정한다 — pane 의 셸은 뿌리
//! 프로세스(`login`)가 연 세션 안에 있고 세션 번호 = 그 뿌리의 pid 다(실측: in-process·세션 호스트 pane 모두). 세션
//! 번호 → pane 은 L4 가 각 Term 의 뿌리 pid 와 맞춘다.
//!
//! 프로세스는 자기 부모를 고를 수 없고 살아 있는 남의 세션에 들어갈 수 없으므로, pane 번호를 안다고 이 판정을 흉내 내기
//! 어렵다. 다만 **최선의 노력이지 하드 경계는 아니다**(§8.4) — 같은 uid 는 그 pane 안에서 명령을 띄울 수 있고, pane 의
//! 셸이 끝난 뒤 앱이 그것을 보기 전의 짧은 틈에 같은 pid 를 받은 세션은 가리지 못한다(세션 번호와 뿌리 pid 를 숫자로만
//! 맞춘다). 알려진 한계: pane 안에서 띄운 tmux·screen·`ssh localhost`·`script`·편집기 내장 터미널 안의 명령은 그 안쪽
//! 터미널의 세션이라 거절된다.
const std = @import("std");

/// 한 프로세스에 대해 공급자가 주는 것. macOS 는 `proc_pidinfo(PROC_PIDTBSDINFO)`.
pub const ProcInfo = struct {
    pid: i32,
    ppid: i32,
    pgid: i32,
    /// 유효 uid.
    uid: u32,
    /// 제어 터미널이 있는가(macOS `PROC_FLAG_CONTROLT` 이고 tty 장치가 NODEV 가 아님).
    has_ctty: bool,
    /// 제어 터미널의 foreground process group(제어 터미널이 없으면 의미 없음).
    tpgid: i32,
    /// 시작 시각(벽시계 µs). pid 재사용을 가른다.
    start_us: u64,
    /// W9e②: 끝났지만 부모가 아직 거두지 않았다(macOS `SZOMB`) — 주인 판정에서는 끝난 것이다(구현 적대 리뷰 LOW).
    zombie: bool = false,
};

pub const Provider = struct {
    ctx: *anyopaque,
    lookup: *const fn (ctx: *anyopaque, pid: i32) ?ProcInfo,
    /// `getsid(pid)` — 세션 번호(실패면 null).
    session_of: *const fn (ctx: *anyopaque, pid: i32) ?i32,
};

/// 찾은 출처 — 자기 제어 터미널의 foreground 그룹에 속한 첫 조상(`ctty_pid` — 이름은 「터미널을 가진 프로세스」)과 그 세션.
pub const Origin = struct {
    ctty_pid: i32,
    ctty_start_us: u64,
    sid: i32,
    /// W9e②: 그 foreground 작업의 **맨 위 프로세스** — 첫 조상에서 같은 세션·같은 uid·같은 process group 인 동안 부모로 올라간 끝(`jobTop`).
    /// Claude Code 면 `claude`(Bash 도구 셸은 setsid — 실측 PHASE0_v3 c), Codex 면 `codex`, `npx` 처럼 감싼 것이면 감싼 쪽. CPU·네트워크 조건의
    /// 주인이다(사용자 결정 7 — 그 프로세스가 끝나면 푼다). 0 이면 모른다(시험의 손으로 만든 출처).
    job_pid: i32 = 0,
    job_start_us: u64 = 0,
    /// W9e②: 붙은 프로세스 자신(MCP·REPL 의 `holder` — 연결이 끊기면 끝나는 프로세스).
    peer_pid: i32 = 0,
    peer_start_us: u64 = 0,
    /// W9e② 확인 결정 9: 그 foreground 작업을 띄운 **셸** — 맨 위(`job`)의 부모가 같은 uid·같은 세션·제어 터미널이 있고 다른 process group 이며
    /// 자식보다 늦게 시작하지 않았으면 그 부모(`shellOf`). pane 에서 사람이 친 명령이면 그 pane 의 셸(login 의 자식)이다. 0 이면 없다.
    shell_pid: i32 = 0,
    shell_start_us: u64 = 0,
};

/// W9e②: 한 프로세스(pid 와 시작 시각 — pid 재사용을 가른다).
pub const Proc = struct { pid: i32, start_us: u64 };

/// W9e②: CPU·네트워크 조건의 주인. `job` 은 에이전트 프로세스(1g foreground 작업의 맨 위), `holder` 는 MCP·REPL 처럼 요청을 낸 오래 사는
/// 프로세스(있으면 둘 중 하나라도 끝나면 푼다 — 「연결이 끊기면」).
pub const Owner = struct {
    job: Proc,
    holder: ?Proc = null,
    /// W9e② 확인 결정 9: `job` 이 에이전트가 아니라 사람이 그 명령을 친 셸이다(셸이 끝나거나 `clear` 하면 푼다).
    shell: bool = false,

    pub fn kind(self: Owner) []const u8 {
        if (self.shell) return "shell";
        return if (self.holder != null) "session" else "agent";
    }
};

/// W9e②: 출처와 `holder` 주장으로 주인을 정한다. `holder` 주장은 주인을 **더할** 뿐이다(수명을 줄인다).
/// 한 번짜리 CLI 가 곧 그 작업의 맨 위면(사람이 셸에서 직접 쳤다 — 앞에 에이전트가 없다) 그 명령은 곧 끝나므로 주인으로 삼지 않고, **그 명령을 띄운
/// 셸**(`shell_pid` — 보통 그 pane 의 셸)을 주인으로 삼는다(사용자 확인 결정 9 2026-10-29 — 셸이 끝나거나 `clear` 하면 푼다). 셸을 못 찾으면(셸이
/// `exec` 로 그 명령이 됐다 — 부모가 root 의 login) 주인이 없다(`no_agent_process`).
pub fn ownerOf(origin: Origin, holder: bool) ?Owner {
    if (origin.job_pid <= 1 or origin.peer_pid <= 1) return null;
    const job: Proc = .{ .pid = origin.job_pid, .start_us = origin.job_start_us };
    const peer: Proc = .{ .pid = origin.peer_pid, .start_us = origin.peer_start_us };
    if (holder) return .{ .job = job, .holder = peer };
    if (job.pid == peer.pid and job.start_us == peer.start_us) {
        if (origin.shell_pid <= 1) return null;
        return .{ .job = .{ .pid = origin.shell_pid, .start_us = origin.shell_start_us }, .shell = true };
    }
    return .{ .job = job };
}

/// W9e②: 그 프로세스가 아직 그 프로세스인가(같은 pid·같은 시작 시각 — 끝났거나 pid 를 물려받은 다른 프로세스면 거짓).
pub fn alive(provider: Provider, p: Proc) bool {
    const info = provider.lookup(provider.ctx, p.pid) orelse return false;
    return info.pid == p.pid and info.start_us == p.start_us and !info.zombie;
}

/// W9e②: 주인이 모두 살아 있는가.
pub fn ownerAlive(provider: Provider, o: Owner) bool {
    if (!alive(provider, o.job)) return false;
    if (o.holder) |h| if (!alive(provider, h)) return false;
    return true;
}

/// W9e②: foreground 작업의 맨 위 — 같은 세션·같은 uid·같은 process group·부모가 자식보다 늦게 시작하지 않은 동안 부모로(깊이 `max_depth`).
fn jobTop(provider: Provider, start_pid: i32, start_info: ProcInfo, sid: i32, server_uid: u32) struct { Proc, ProcInfo } {
    var cur = start_pid;
    var cur_info = start_info;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        if (cur_info.ppid <= 1 or cur_info.ppid == cur) break;
        const parent = provider.lookup(provider.ctx, cur_info.ppid) orelse break;
        if (parent.pid != cur_info.ppid or parent.uid != server_uid or !parent.has_ctty) break;
        if (parent.pgid != cur_info.pgid) break;
        if (parent.start_us > cur_info.start_us) break;
        const psid = provider.session_of(provider.ctx, parent.pid) orelse break;
        if (psid != sid) break;
        cur = parent.pid;
        cur_info = parent;
    }
    return .{ .{ .pid = cur, .start_us = cur_info.start_us }, cur_info };
}

/// W9e② 확인 결정 9: 그 작업을 띄운 셸 — 맨 위의 부모가 같은 uid·같은 세션·제어 터미널이 있고 다른 process group(셸은 작업마다 새 그룹을
/// 만든다)이며 자식보다 늦게 시작하지 않았고 끝나지 않았으면 그 부모. 못 찾으면 null.
fn shellOf(provider: Provider, top: Proc, top_info: ProcInfo, sid: i32, server_uid: u32) ?Proc {
    if (top_info.ppid <= 1 or top_info.ppid == top.pid) return null;
    const parent = provider.lookup(provider.ctx, top_info.ppid) orelse return null;
    if (parent.pid != top_info.ppid or parent.uid != server_uid or !parent.has_ctty or parent.zombie) return null;
    if (parent.pgid == top_info.pgid) return null;
    if (parent.start_us > top.start_us) return null;
    const psid = provider.session_of(provider.ctx, parent.pid) orelse return null;
    if (psid != sid) return null;
    return .{ .pid = parent.pid, .start_us = parent.start_us };
}

pub const Reject = enum {
    /// peer 정보를 못 읽었다(이미 끝났다 등).
    peer_unknown,
    /// peer 가 연결을 받은 뒤에 시작했다 — 셀렉터를 쓴 프로세스가 끝나고 그 pid 를 다른 프로세스가 받았다.
    peer_newer_than_accept,
    /// 거슬러 오르는 중에 정보를 못 읽었다(root 프로세스 등).
    lookup_failed,
    uid_mismatch,
    /// 제어 터미널을 가진 조상이 없다(launchd 아래의 데몬, 고아 등).
    no_ctty_ancestor,
    depth_exceeded,
    /// 터미널을 가진 조상은 있었지만 그 터미널의 foreground 그룹에 속한 조상이 없다(다른 작업이 foreground 인 동안의
    /// 백그라운드 작업 등).
    background,
    /// 거슬러 오르는 중 부모가 자식보다 늦게 시작했다 — 그 pid 를 다른 프로세스가 물려받았다.
    ancestor_replaced,
    /// 처음 만난 제어 터미널의 세션을 벗어났다 — pane 안에서 연 안쪽 터미널(`script`·편집기 내장 터미널 등)의 프로세스가
    /// 바깥 pane 의 foreground 조상으로 통과하지 않게 세션 경계에서 멈춘다(적대 리뷰 2 회차).
    terminal_changed,
    session_unknown,
};

pub const Result = union(enum) {
    origin: Origin,
    reject: Reject,
};

/// 거슬러 오를 최대 깊이. 셸 → 에이전트 → 도구 셸 → CLI 는 4 안팎이다.
pub const max_depth: usize = 16;

pub fn findOrigin(provider: Provider, peer_pid: i32, server_uid: u32, accept_us: u64) Result {
    if (peer_pid <= 1) return .{ .reject = .peer_unknown };
    var pid = peer_pid;
    var child_start: u64 = std.math.maxInt(u64);
    // 처음 만난 제어 터미널 프로세스의 세션 — 그 세션 안에서만 foreground 조상을 찾는다. 그 뒤로 끊기면(foreground 조상
    // 없이 root `login` 등에 닿음) 「백그라운드」다.
    var first_sid: ?i32 = null;
    var peer_start: u64 = 0;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const saw_ctty = first_sid != null;
        const info = provider.lookup(provider.ctx, pid) orelse return .{ .reject = if (depth == 0)
            .peer_unknown
        else if (saw_ctty)
            .background
        else
            .lookup_failed };
        if (info.pid != pid) return .{ .reject = .lookup_failed };
        if (depth == 0 and info.start_us > accept_us) return .{ .reject = .peer_newer_than_accept };
        if (depth == 0) peer_start = info.start_us;
        if (info.start_us > child_start) return .{ .reject = .ancestor_replaced };
        if (info.uid != server_uid) return .{ .reject = if (saw_ctty) .background else .uid_mismatch };
        if (info.has_ctty) {
            const sid = provider.session_of(provider.ctx, pid) orelse return .{ .reject = .session_unknown };
            if (sid <= 1) return .{ .reject = .session_unknown };
            if (first_sid) |first| {
                if (sid != first) return .{ .reject = .terminal_changed };
            } else first_sid = sid;
            if (info.pgid > 0 and info.pgid == info.tpgid) {
                const top, const top_info = jobTop(provider, pid, info, sid, server_uid);
                const sh: Proc = shellOf(provider, top, top_info, sid, server_uid) orelse .{ .pid = 0, .start_us = 0 };
                return .{ .origin = .{ .ctty_pid = pid, .ctty_start_us = info.start_us, .sid = sid, .job_pid = top.pid, .job_start_us = top.start_us, .peer_pid = peer_pid, .peer_start_us = peer_start, .shell_pid = sh.pid, .shell_start_us = sh.start_us } };
            }
        }
        if (info.ppid <= 1 or info.ppid == pid) return .{ .reject = if (saw_ctty) .background else .no_ctty_ancestor };
        child_start = info.start_us;
        pid = info.ppid;
    }
    return .{ .reject = .depth_exceeded };
}

/// 서버가 찾은 pane(`found`)과 클라이언트가 주장한 셀렉터(`claimed`)로 이 요청의 두 앵커를 정한다(1g).
/// - `browser_pane` = 찾은 pane — browser 확인 grant(§9.2 Model B)의 pane. 셀렉터가 필요 없다.
/// - `selector` = 찾은 pane 과 같은 주장만 남긴다(metadata:self 앵커). 다르거나 못 찾았으면 null — metadata 는 셀렉터
///   없는 연결처럼 전체(사용자 결정 「목록은 지금처럼」), 남의 pane 번호로 그 pane 의 grant 를 못 탄다.
pub const Anchors = struct { selector: ?u64, browser_pane: ?u64 };

pub fn anchors(found: ?u64, claimed: ?u64) Anchors {
    const kept: ?u64 = if (claimed) |c| (if (found != null and found.? == c) c else null) else null;
    return .{ .selector = kept, .browser_pane = found };
}

/// 요청을 처리하는 지금도 그 출처가 그대로인가 — 같은 프로세스(시작 시각)이고, 여전히 그 터미널의 foreground 이며,
/// 같은 세션이다. 연결 하나에 요청이 여럿 올 수 있어(지속 세션) 요청마다 다시 본다(§8.4).
pub fn stillForeground(provider: Provider, origin: Origin) bool {
    const info = provider.lookup(provider.ctx, origin.ctty_pid) orelse return false;
    if (info.pid != origin.ctty_pid or info.start_us != origin.ctty_start_us) return false;
    if (!info.has_ctty or info.pgid <= 0 or info.pgid != info.tpgid) return false;
    const sid = provider.session_of(provider.ctx, origin.ctty_pid) orelse return false;
    return sid == origin.sid;
}

// ── 시험(가짜 공급자) ───────────────────────────────────────────────────────────────────────────────────────

const Fake = struct {
    procs: []const ProcInfo,
    sessions: []const [2]i32, // {pid, sid}
    /// 공급자가 다른 pid 의 정보를 돌려주는 경우를 흉내 낸다(커널 버퍼가 엉뚱한 프로세스로 찬 경우 등).
    lie_about: ?i32 = null,

    fn lookup(ctx: *anyopaque, pid: i32) ?ProcInfo {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (self.procs) |p| if (p.pid == pid) {
            var out = p;
            if (self.lie_about != null and self.lie_about.? == pid) out.pid = pid + 1000;
            return out;
        };
        return null;
    }

    fn sessionOf(ctx: *anyopaque, pid: i32) ?i32 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (self.sessions) |s| if (s[0] == pid) return s[1];
        return null;
    }

    fn provider(self: *Fake) Provider {
        return .{ .ctx = self, .lookup = lookup, .session_of = sessionOf };
    }
};

const uid: u32 = 501;
const accepted: u64 = 1_000_000;
// pane 의 뿌리 login(root, 세션 100) → 셸(foreground 일 때 pgid 101).
const login: ProcInfo = .{ .pid = 100, .ppid = 50, .pgid = 100, .uid = 0, .has_ctty = true, .tpgid = 101, .start_us = 10 };

fn shell(tpgid: i32) ProcInfo {
    return .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = tpgid, .start_us = 20 };
}

fn expectOrigin(result: Result, ctty_pid: i32, sid: i32) !void {
    switch (result) {
        .origin => |o| {
            try std.testing.expectEqual(ctty_pid, o.ctty_pid);
            try std.testing.expectEqual(sid, o.sid);
        },
        .reject => |r| {
            std.debug.print("rejected: {s}\n", .{@tagName(r)});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectReject(result: Result, reason: Reject) !void {
    switch (result) {
        .origin => return error.TestUnexpectedResult,
        .reject => |r| try std.testing.expectEqual(reason, r),
    }
}

test "셸에서 직접 친 명령은 자기 터미널로 통과한다" {
    // 셸이 CLI 를 foreground 로 띄웠다(CLI pgid 102 = tpgid).
    var fake: Fake = .{
        .procs = &.{ login, shell(102), .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = true, .tpgid = 102, .start_us = 30 } },
        .sessions = &.{.{ 102, 100 }},
    };
    try expectOrigin(findOrigin(fake.provider(), 102, uid, accepted), 102, 100);
}

test "에이전트가 새 세션으로 띄운 명령(제어 터미널 없음)은 터미널을 가진 에이전트 본체로 통과한다" {
    // 셸 → claude(foreground, pgid 103 = tpgid) → zsh -c(setsid, tty 없음) → maru CLI(tty 없음).
    var fake: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 104, .ppid = 103, .pgid = 104, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 40 },
            .{ .pid = 105, .ppid = 104, .pgid = 104, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 50 },
        },
        .sessions = &.{.{ 103, 100 }},
    };
    try expectOrigin(findOrigin(fake.provider(), 105, uid, accepted), 103, 100);
}

test "Codex 처럼 새 process group 으로 띄운 명령(터미널은 있지만 foreground 아님)은 foreground 인 부모로 통과한다" {
    // 셸 → codex(foreground, pgid 103 = tpgid) → 명령(pgid 104, 같은 tty).
    var fake: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 104, .ppid = 103, .pgid = 104, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 40 },
        },
        .sessions = &.{ .{ 103, 100 }, .{ 104, 100 } },
    };
    try expectOrigin(findOrigin(fake.provider(), 104, uid, accepted), 103, 100);
}

test "셸이 프롬프트에 있을 때의 `&` 는 통과하고, 다른 작업이 foreground 인 동안의 백그라운드는 거절된다" {
    const bg: ProcInfo = .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 30 };
    // 셸이 foreground(tpgid 101) — 그 셸에서 나왔다.
    var idle: Fake = .{ .procs = &.{ login, shell(101), bg }, .sessions = &.{ .{ 101, 100 }, .{ 102, 100 } } };
    try expectOrigin(findOrigin(idle.provider(), 102, uid, accepted), 101, 100);
    // vim(pgid 150)이 foreground — 백그라운드 작업도 그 셸도 foreground 가 아니고, 위는 읽을 수 없는 root login.
    var busy_bg = bg;
    busy_bg.tpgid = 150;
    var busy: Fake = .{ .procs = &.{ shell(150), busy_bg }, .sessions = &.{ .{ 101, 100 }, .{ 102, 100 } } };
    try expectReject(findOrigin(busy.provider(), 102, uid, accepted), .background);
    // root login 까지 읽히더라도(시험 공급자) uid 가 달라 백그라운드로 끝난다.
    var busy_login: Fake = .{ .procs = &.{ login, shell(150), busy_bg }, .sessions = &.{ .{ 101, 100 }, .{ 102, 100 } } };
    try expectReject(findOrigin(busy_login.provider(), 102, uid, accepted), .background);
}

test "거슬러 오르는 중 부모가 자식보다 늦게 시작했으면 pid 를 물려받은 다른 프로세스라 거절된다" {
    var fake: Fake = .{
        .procs = &.{
            .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 50 },
            .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 40 },
        },
        .sessions = &.{.{ 101, 100 }},
    };
    try expectReject(findOrigin(fake.provider(), 102, uid, accepted), .ancestor_replaced);
}

test "처음 만난 터미널의 세션을 벗어나면 멈춘다 — 안쪽 터미널의 백그라운드가 바깥 pane 의 foreground 조상으로 통과하지 않는다" {
    // pane(세션 100): 셸 → script(foreground, pgid 103) → 안쪽 pty(세션 200): 안쪽 셸(pgid 201) — vim(pgid 250)이
    // foreground — 백그라운드 작업(pgid 202).
    var fake: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 201, .ppid = 103, .pgid = 201, .uid = uid, .has_ctty = true, .tpgid = 250, .start_us = 40 },
            .{ .pid = 202, .ppid = 201, .pgid = 202, .uid = uid, .has_ctty = true, .tpgid = 250, .start_us = 50 },
        },
        .sessions = &.{ .{ 103, 100 }, .{ 201, 201 }, .{ 202, 201 } },
    };
    try expectReject(findOrigin(fake.provider(), 202, uid, accepted), .terminal_changed);
    // 안쪽 셸이 foreground 면 안쪽 세션으로 찾는다(어느 pane 의 뿌리도 아니라 L4 가 못 찾는다).
    var inner_fg: Fake = .{
        .procs = &.{
            .{ .pid = 201, .ppid = 103, .pgid = 201, .uid = uid, .has_ctty = true, .tpgid = 201, .start_us = 40 },
            .{ .pid = 202, .ppid = 201, .pgid = 202, .uid = uid, .has_ctty = true, .tpgid = 201, .start_us = 50 },
        },
        .sessions = &.{ .{ 201, 201 }, .{ 202, 201 } },
    };
    try expectOrigin(findOrigin(inner_fg.provider(), 202, uid, accepted), 201, 201);
}

test "세션 번호가 1 이하이거나 정보의 pid 가 다르면 거절된다" {
    var low_sid: Fake = .{ .procs = &.{ login, shell(101) }, .sessions = &.{.{ 101, 1 }} };
    try expectReject(findOrigin(low_sid.provider(), 101, uid, accepted), .session_unknown);
    // 공급자가 다른 pid 의 정보를 돌려줬다 — 사슬 안이든 요청 때 재확인이든 믿지 않는다.
    var wrong_pid: Fake = .{ .procs = &.{ login, shell(101) }, .sessions = &.{.{ 101, 100 }}, .lie_about = 101 };
    try expectReject(findOrigin(wrong_pid.provider(), 101, uid, accepted), .lookup_failed);
    try std.testing.expect(!stillForeground(wrong_pid.provider(), .{ .ctty_pid = 101, .ctty_start_us = 20, .sid = 100 }));
}

test "앵커: 셀렉터는 찾은 pane 과 같을 때만 남고, browser grant 의 pane 은 늘 찾은 pane 이다" {
    try std.testing.expectEqual(Anchors{ .selector = 7, .browser_pane = 7 }, anchors(7, 7));
    try std.testing.expectEqual(Anchors{ .selector = null, .browser_pane = 7 }, anchors(7, 9)); // 남의 번호 — 버린다
    try std.testing.expectEqual(Anchors{ .selector = null, .browser_pane = 7 }, anchors(7, null)); // 세션 유지 pane
    try std.testing.expectEqual(Anchors{ .selector = null, .browser_pane = null }, anchors(null, 9)); // pane 밖
    try std.testing.expectEqual(Anchors{ .selector = null, .browser_pane = null }, anchors(null, null));
}

test "제어 터미널을 가진 조상이 없으면(launchd 아래 데몬·고아) 거절된다" {
    var fake: Fake = .{
        .procs = &.{
            .{ .pid = 200, .ppid = 1, .pgid = 200, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 30 },
            .{ .pid = 201, .ppid = 200, .pgid = 200, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 40 },
        },
        .sessions = &.{},
    };
    try expectReject(findOrigin(fake.provider(), 201, uid, accepted), .no_ctty_ancestor);
}

test "다른 사용자의 프로세스나 읽을 수 없는 조상을 지나면 거절된다" {
    var other_uid: Fake = .{
        .procs = &.{.{ .pid = 300, .ppid = 299, .pgid = 300, .uid = 0, .has_ctty = true, .tpgid = 300, .start_us = 30 }},
        .sessions = &.{.{ 300, 300 }},
    };
    try expectReject(findOrigin(other_uid.provider(), 300, uid, accepted), .uid_mismatch);
    // 터미널 없는 자식 → 정보를 못 읽는 부모.
    var unreadable: Fake = .{
        .procs = &.{.{ .pid = 301, .ppid = 299, .pgid = 301, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 30 }},
        .sessions = &.{},
    };
    try expectReject(findOrigin(unreadable.provider(), 301, uid, accepted), .lookup_failed);
    var gone: Fake = .{ .procs = &.{}, .sessions = &.{} };
    try expectReject(findOrigin(gone.provider(), 302, uid, accepted), .peer_unknown);
    try expectReject(findOrigin(gone.provider(), 1, uid, accepted), .peer_unknown);
}

test "연결을 받은 뒤에 시작한 peer 는 pid 를 물려받은 다른 프로세스라 거절된다" {
    var fake: Fake = .{
        .procs = &.{ login, shell(101), .{ .pid = 102, .ppid = 101, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = accepted + 1 } },
        .sessions = &.{.{ 102, 100 }},
    };
    try expectReject(findOrigin(fake.provider(), 102, uid, accepted), .peer_newer_than_accept);
}

test "부모가 자기 자신이거나 사슬이 너무 길면 끝난다" {
    var self_parent: Fake = .{
        .procs = &.{.{ .pid = 400, .ppid = 400, .pgid = 400, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 30 }},
        .sessions = &.{},
    };
    try expectReject(findOrigin(self_parent.provider(), 400, uid, accepted), .no_ctty_ancestor);
    var chain: [max_depth + 2]ProcInfo = undefined;
    for (&chain, 0..) |*p, i| {
        const pid: i32 = @intCast(500 + i);
        p.* = .{ .pid = pid, .ppid = pid + 1, .pgid = pid, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 30 };
    }
    var long: Fake = .{ .procs = &chain, .sessions = &.{} };
    try expectReject(findOrigin(long.provider(), 500, uid, accepted), .depth_exceeded);
}

test "세션 번호를 못 읽으면 거절된다" {
    var fake: Fake = .{ .procs = &.{ login, shell(101) }, .sessions = &.{} };
    try expectReject(findOrigin(fake.provider(), 101, uid, accepted), .session_unknown);
}

test "요청마다: 같은 프로세스가 여전히 foreground 일 때만 출처가 유효하다" {
    var fake: Fake = .{ .procs = &.{ login, shell(101) }, .sessions = &.{.{ 101, 100 }} };
    const origin: Origin = .{ .ctty_pid = 101, .ctty_start_us = 20, .sid = 100 };
    try std.testing.expect(stillForeground(fake.provider(), origin));
    // 셸이 다른 작업을 foreground 로 띄웠다.
    var moved: Fake = .{ .procs = &.{ login, shell(150) }, .sessions = &.{.{ 101, 100 }} };
    try std.testing.expect(!stillForeground(moved.provider(), origin));
    // 끝나고 그 pid 를 다른 프로세스가 받았다(시작 시각이 다르다).
    var reused: Fake = .{
        .procs = &.{.{ .pid = 101, .ppid = 1, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 99 }},
        .sessions = &.{.{ 101, 100 }},
    };
    try std.testing.expect(!stillForeground(reused.provider(), origin));
    var gone: Fake = .{ .procs = &.{}, .sessions = &.{} };
    try std.testing.expect(!stillForeground(gone.provider(), origin));
    // 같은 프로세스·foreground 인데 세션만 바뀌었다(다른 세션으로 옮겨 갔다).
    var moved_session: Fake = .{ .procs = &.{ login, shell(101) }, .sessions = &.{.{ 101, 300 }} };
    try std.testing.expect(!stillForeground(moved_session.provider(), origin));
}

// ── W9e②: 조건의 주인(에이전트 프로세스) ─────────────────────────────────────────────────────────────────────

fn expectJob(result: Result, job: i32, peer: i32) !Origin {
    switch (result) {
        .origin => |o| {
            try std.testing.expectEqual(job, o.job_pid);
            try std.testing.expectEqual(peer, o.peer_pid);
            return o;
        },
        .reject => return error.TestUnexpectedResult,
    }
}

test "W9e②: 작업의 맨 위 — 셸에서 친 CLI 는 자신(주인은 그 셸 — 확인 결정 9), claude 의 setsid 명령은 claude, npx 로 감싼 에이전트는 감싼 쪽, 셸은 넘지 않는다" {
    var direct: Fake = .{
        .procs = &.{ login, shell(102), .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = true, .tpgid = 102, .start_us = 30 } },
        .sessions = &.{ .{ 102, 100 }, .{ 101, 100 } },
    };
    const o1 = try expectJob(findOrigin(direct.provider(), 102, uid, accepted), 102, 102);
    // 한 번짜리 CLI 가 곧 맨 위 — 그 명령은 곧 끝나므로 그 명령을 띄운 pane 의 셸(101)이 주인(확인 결정 9).
    const sh = ownerOf(o1, false).?;
    try std.testing.expectEqual(@as(i32, 101), sh.job.pid);
    try std.testing.expectEqual(@as(u64, 20), sh.job.start_us);
    try std.testing.expect(sh.shell and sh.holder == null);
    try std.testing.expectEqualStrings("shell", sh.kind());
    try std.testing.expectEqual(@as(i32, 102), ownerOf(o1, true).?.job.pid); // REPL 이 셸의 foreground 면 그 REPL 이 주인
    var agent: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 104, .ppid = 103, .pgid = 104, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 40 },
            .{ .pid = 105, .ppid = 104, .pgid = 104, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 50 },
        },
        .sessions = &.{ .{ 103, 100 }, .{ 101, 100 } },
    };
    const o2 = try expectJob(findOrigin(agent.provider(), 105, uid, accepted), 103, 105);
    const own = ownerOf(o2, false).?;
    try std.testing.expectEqual(@as(i32, 103), own.job.pid);
    try std.testing.expect(own.holder == null);
    try std.testing.expectEqualStrings("agent", own.kind());
    const mcp = ownerOf(o2, true).?;
    try std.testing.expectEqual(@as(i32, 105), mcp.holder.?.pid);
    try std.testing.expectEqualStrings("session", mcp.kind());
    // npx(103) → node claude(106, 같은 그룹) → setsid 셸(107) → CLI(108).
    var wrapped: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 106, .ppid = 103, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 35 },
            .{ .pid = 107, .ppid = 106, .pgid = 107, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 40 },
            .{ .pid = 108, .ppid = 107, .pgid = 107, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 50 },
        },
        .sessions = &.{ .{ 103, 100 }, .{ 106, 100 }, .{ 101, 100 } },
    };
    _ = try expectJob(findOrigin(wrapped.provider(), 108, uid, accepted), 103, 108);
}

test "W9e②: 맨 위를 오르다 멈추는 곳 — 늦게 시작한 부모(pid 재사용)·다른 세션·다른 uid 는 넘지 않는다, 주인의 생존은 pid 와 시작 시각으로" {
    // 106 의 부모 103 이 106 보다 늦게 시작했다(물려받은 pid) — 106 에서 멈춘다.
    var late: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 60 },
            .{ .pid = 106, .ppid = 103, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 35 },
        },
        .sessions = &.{ .{ 103, 100 }, .{ 106, 100 } },
    };
    _ = try expectJob(findOrigin(late.provider(), 106, uid, accepted), 106, 106);
    var other_sid: Fake = .{
        .procs = &.{
            login,
            shell(103),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 },
            .{ .pid = 106, .ppid = 103, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 35 },
        },
        .sessions = &.{ .{ 103, 999 }, .{ 106, 100 } },
    };
    _ = try expectJob(findOrigin(other_sid.provider(), 106, uid, accepted), 106, 106);
    // 생존: 같은 pid 라도 시작 시각이 다르면 끝난 것이다.
    var procs: Fake = .{ .procs = &.{.{ .pid = 103, .ppid = 1, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 103, .start_us = 30 }}, .sessions = &.{} };
    try std.testing.expect(alive(procs.provider(), .{ .pid = 103, .start_us = 30 }));
    try std.testing.expect(!alive(procs.provider(), .{ .pid = 103, .start_us = 31 })); // pid 재사용
    try std.testing.expect(!alive(procs.provider(), .{ .pid = 104, .start_us = 30 })); // 끝남
    var zombie: Fake = .{ .procs = &.{.{ .pid = 103, .ppid = 1, .pgid = 103, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 30, .zombie = true }}, .sessions = &.{} };
    try std.testing.expect(!alive(zombie.provider(), .{ .pid = 103, .start_us = 30 })); // 끝났고 아직 거두지 않았다
    try std.testing.expect(ownerAlive(procs.provider(), .{ .job = .{ .pid = 103, .start_us = 30 } }));
    try std.testing.expect(!ownerAlive(procs.provider(), .{ .job = .{ .pid = 103, .start_us = 30 }, .holder = .{ .pid = 104, .start_us = 1 } })); // MCP 연결이 끊겼다
    // 손으로 만든 출처(주인 모름)는 주인이 없다.
    try std.testing.expect(ownerOf(.{ .ctty_pid = 1, .ctty_start_us = 0, .sid = 2 }, true) == null);
}

test "W9e② 확인 결정 9: 사람이 친 CLI 의 주인은 그 명령을 띄운 셸 — exec 로 셸이 그 명령이 됐으면 없다, 셸이 아닌 부모는 넘지 않는다" {
    const cli: ProcInfo = .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = true, .tpgid = 102, .start_us = 30 };
    // 셸이 `exec maru …` — 그 명령이 곧 pane 의 셸 자리(부모는 root 의 login): 주인 없음.
    var execd: Fake = .{
        .procs = &.{ login, .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 20 } },
        .sessions = &.{ .{ 101, 100 }, .{ 100, 100 } },
    };
    const oe = try expectJob(findOrigin(execd.provider(), 101, uid, accepted), 101, 101);
    try std.testing.expect(ownerOf(oe, false) == null);
    try std.testing.expectEqual(@as(i32, 0), oe.shell_pid);
    // 셸 안에서 띄운 bash(103) 에서 친 CLI(104): 주인은 가장 안쪽 셸 bash(그 bash 가 끝나면 푼다).
    var nested: Fake = .{
        .procs = &.{
            login,
            shell(104),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 104, .start_us = 25 },
            .{ .pid = 104, .ppid = 103, .pgid = 104, .uid = uid, .has_ctty = true, .tpgid = 104, .start_us = 30 },
        },
        .sessions = &.{ .{ 101, 100 }, .{ 103, 100 }, .{ 104, 100 } },
    };
    const on = try expectJob(findOrigin(nested.provider(), 104, uid, accepted), 104, 104);
    try std.testing.expectEqual(@as(i32, 103), ownerOf(on, false).?.job.pid);
    // 에이전트(codex 103 — 같은 세션)의 자식이 SIGTTOU 를 무시하고 tcsetpgrp 로 스스로 foreground 가 됐다: 「셸」 은 그 부모 codex —
    // 사람인 척해도 주인은 에이전트 자신이라 수명이 늘지 않는다.
    var codex: Fake = .{
        .procs = &.{
            login,
            shell(105),
            .{ .pid = 103, .ppid = 101, .pgid = 103, .uid = uid, .has_ctty = true, .tpgid = 105, .start_us = 25 },
            .{ .pid = 105, .ppid = 103, .pgid = 105, .uid = uid, .has_ctty = true, .tpgid = 105, .start_us = 30 },
        },
        .sessions = &.{ .{ 101, 100 }, .{ 103, 100 }, .{ 105, 100 } },
    };
    const oc = try expectJob(findOrigin(codex.provider(), 105, uid, accepted), 105, 105);
    try std.testing.expectEqual(@as(i32, 103), ownerOf(oc, false).?.job.pid);
    // 부모가 셸 자격이 없으면 주인 없음: 끝났고 거두지 않음(좀비)·늦게 시작(pid 재사용)·다른 세션·제어 터미널 없음·다른 uid.
    const bad_parents = [_]ProcInfo{
        .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 102, .start_us = 20, .zombie = true },
        .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 102, .start_us = 40 },
        .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = uid, .has_ctty = false, .tpgid = 0, .start_us = 20 },
        .{ .pid = 101, .ppid = 100, .pgid = 101, .uid = 0, .has_ctty = true, .tpgid = 102, .start_us = 20 },
    };
    for (bad_parents) |bp| {
        var f: Fake = .{ .procs = &.{ login, bp, cli }, .sessions = &.{ .{ 101, 100 }, .{ 102, 100 } } };
        const o = try expectJob(findOrigin(f.provider(), 102, uid, accepted), 102, 102);
        try std.testing.expect(ownerOf(o, false) == null);
    }
    // 공급자가 부모 자리에 다른 pid 의 정보를 돌려준다 — 셸로 삼지 않는다(변이 S11).
    var lying: Fake = .{ .procs = &.{ login, shell(102), cli }, .sessions = &.{ .{ 101, 100 }, .{ 102, 100 }, .{ 1101, 100 } }, .lie_about = 101 };
    try std.testing.expect(ownerOf(try expectJob(findOrigin(lying.provider(), 102, uid, accepted), 102, 102), false) == null);
    // 같은 그룹의 사슬이 깊이 상한(16)을 넘어 맨 위 오르기가 멈췄다 — 그 부모는 같은 작업이라 셸이 아니다(변이 S4).
    var deep_procs: [max_depth + 3]ProcInfo = undefined;
    var deep_sessions: [max_depth + 3][2]i32 = undefined;
    for (0..max_depth + 3) |i| {
        const pid: i32 = 200 + @as(i32, @intCast(i));
        deep_procs[i] = .{ .pid = pid, .ppid = if (i == max_depth + 2) 101 else pid + 1, .pgid = 300, .uid = uid, .has_ctty = true, .tpgid = 300, .start_us = 100 - i };
        deep_sessions[i] = .{ pid, 100 };
    }
    var deep: Fake = .{ .procs = &deep_procs, .sessions = &deep_sessions };
    const od = findOrigin(deep.provider(), 200, uid, accepted).origin;
    try std.testing.expectEqual(@as(i32, 200 + @as(i32, @intCast(max_depth))), od.job_pid);
    try std.testing.expectEqual(@as(i32, 0), od.shell_pid);
    var other_session: Fake = .{ .procs = &.{ login, shell(102), cli }, .sessions = &.{ .{ 101, 999 }, .{ 102, 100 } } };
    try std.testing.expect(ownerOf(try expectJob(findOrigin(other_session.provider(), 102, uid, accepted), 102, 102), false) == null);
    // 주인 셸의 생존 — 셸이 끝나면(없음·좀비·같은 pid 의 다른 프로세스) 거짓. `exec zsh` 는 pid·시작 시각이 그대로라 산다.
    var alive_shell: Fake = .{ .procs = &.{shell(102)}, .sessions = &.{} };
    const own: Owner = .{ .job = .{ .pid = 101, .start_us = 20 }, .shell = true };
    try std.testing.expect(ownerAlive(alive_shell.provider(), own));
    var gone: Fake = .{ .procs = &.{}, .sessions = &.{} };
    try std.testing.expect(!ownerAlive(gone.provider(), own));
    var reused: Fake = .{ .procs = &.{.{ .pid = 101, .ppid = 1, .pgid = 101, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 77 }}, .sessions = &.{} };
    try std.testing.expect(!ownerAlive(reused.provider(), own));
}
