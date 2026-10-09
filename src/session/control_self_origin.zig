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
};

pub const Provider = struct {
    ctx: *anyopaque,
    lookup: *const fn (ctx: *anyopaque, pid: i32) ?ProcInfo,
    /// `getsid(pid)` — 세션 번호(실패면 null).
    session_of: *const fn (ctx: *anyopaque, pid: i32) ?i32,
};

/// 찾은 출처 — 제어 터미널을 가진 첫 조상과 그 세션.
pub const Origin = struct {
    ctty_pid: i32,
    ctty_start_us: u64,
    sid: i32,
};

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
    // 터미널을 가진 조상을 지났는가 — 그 뒤로 끊기면(foreground 조상 없이 root `login` 등에 닿음) 「백그라운드」다.
    var saw_ctty = false;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const info = provider.lookup(provider.ctx, pid) orelse return .{ .reject = if (depth == 0)
            .peer_unknown
        else if (saw_ctty)
            .background
        else
            .lookup_failed };
        if (info.pid != pid) return .{ .reject = .lookup_failed };
        if (depth == 0 and info.start_us > accept_us) return .{ .reject = .peer_newer_than_accept };
        if (info.start_us > child_start) return .{ .reject = .ancestor_replaced };
        if (info.uid != server_uid) return .{ .reject = if (saw_ctty) .background else .uid_mismatch };
        if (info.has_ctty) {
            saw_ctty = true;
            if (info.pgid > 0 and info.pgid == info.tpgid) {
                const sid = provider.session_of(provider.ctx, pid) orelse return .{ .reject = .session_unknown };
                if (sid <= 1) return .{ .reject = .session_unknown };
                return .{ .origin = .{ .ctty_pid = pid, .ctty_start_us = info.start_us, .sid = sid } };
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

    fn lookup(ctx: *anyopaque, pid: i32) ?ProcInfo {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (self.procs) |p| if (p.pid == pid) return p;
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
        .sessions = &.{.{ 103, 100 }},
    };
    try expectOrigin(findOrigin(fake.provider(), 104, uid, accepted), 103, 100);
}

test "셸이 프롬프트에 있을 때의 `&` 는 통과하고, 다른 작업이 foreground 인 동안의 백그라운드는 거절된다" {
    const bg: ProcInfo = .{ .pid = 102, .ppid = 101, .pgid = 102, .uid = uid, .has_ctty = true, .tpgid = 101, .start_us = 30 };
    // 셸이 foreground(tpgid 101) — 그 셸에서 나왔다.
    var idle: Fake = .{ .procs = &.{ login, shell(101), bg }, .sessions = &.{.{ 101, 100 }} };
    try expectOrigin(findOrigin(idle.provider(), 102, uid, accepted), 101, 100);
    // vim(pgid 150)이 foreground — 백그라운드 작업도 그 셸도 foreground 가 아니고, 위는 읽을 수 없는 root login.
    var busy_bg = bg;
    busy_bg.tpgid = 150;
    var busy: Fake = .{ .procs = &.{ shell(150), busy_bg }, .sessions = &.{.{ 101, 100 }} };
    try expectReject(findOrigin(busy.provider(), 102, uid, accepted), .background);
    // root login 까지 읽히더라도(시험 공급자) uid 가 달라 백그라운드로 끝난다.
    var busy_login: Fake = .{ .procs = &.{ login, shell(150), busy_bg }, .sessions = &.{.{ 101, 100 }} };
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
}
