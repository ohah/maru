//! codex 공유 데몬이 돌린 훅 이벤트가 **파일 이름(pane)이 아니라 세션 id 로** 귀속되는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-10-04 — 같은 폴더의 두 pane 에서 codex 0.160 을 띄우자 사이드바가 둘을 뒤바꿔 보였다. codex 는 0.157 부터
//! 세션·훅을 공유 데몬 하나가 돌리고, 그 데몬은 먼저 뜬 pane 의 env 를 물려받아 **나중 pane 의 세션 훅도 첫 pane 파일에**
//! 적는다. 앱은 파일 이름을 pane 으로 믿고 그 세션 신원을 대기 중인 첫 pane 에 채택했다(openai/codex#48500 와 같은 결함).
//!
//! 판정 자체(`src/session/codex_daemon_attribution.zig`)와 훅이 싣는 부모 pid 칸(`agent_hook_command`)은 순수 테스트가 잰다.
//! 앱 배치 루프는 `app_session` 테스트라 PR 에서 안 돈다 — 그래서 루프가 **판정을 지나서만** 적용하는지, 데몬이 돌린
//! 이벤트가 판정 없이 `adoptHookSessionIdentity` 로 흐를 길이 없는지, 재배정받은 Term 이 관측 모드로 떨어지지 않고
//! 에이전트가 떠나면 묶음이 풀리는지를 여기서 글자로 잰다.

const std = @import("std");

const agent_path = "src/platform/macos/app_session/agent.zig";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectCount(haystack: []const u8, needle: []const u8, want: usize, what: []const u8) !void {
    const n = countAll(haystack, needle);
    if (n != want) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — {d} 번이어야 한다\n", .{ what, needle, n, want });
        return error.WiringChanged;
    }
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    try expectCount(haystack, needle, 1, what);
    return std.mem.indexOf(u8, haystack, needle).?;
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "codex 데몬 귀속 — 배치 루프는 판정을 지나서만 적용하고, 데몬이 돌린 이벤트는 판정 없이 이 pane 에 채택되지 않는다" {
    const a = std.testing.allocator;
    const raw = try read(a, agent_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // ⑴ 로컬 배치 루프: 모든 이벤트가 `routeHookEvent` 를 지나고, 이 Term 의 배치에 넣는 것은 `.here` 갈래뿐이다.
    const poll = try fnBody(src, "pollAgentHookEvents");
    _ = try expectOnce(poll, "for (events[0..batch.count]) |ev| switch (routeHookEvent(self, term, ev)) { .here => turn_batch.step(self, term, ev), .elsewhere, .dropped => {}, };", "배치 루프");
    try expectCount(poll, "turn_batch.step(", 1, "배치 루프 밖의 적용");

    // ⑵ 판정의 입구: 데몬이 돌린 이벤트가 아니면 예전 그대로(`.here`), 맞으면 순수 판정 **한 번**을 지난다.
    const route = try fnBody(src, "routeHookEvent");
    const gate = try expectOnce(route, "if (!attr.isDaemonEvent(ev.provider, hookParentIsDaemon(self, ev))) return .here;", "데몬 게이트");
    // 데몬 판정은 훅이 실은 `$PPID` 의 argv 로 한다 — 제어 터미널 같은 대리 증거가 아니다(첫 판의 오판).
    const parent = try fnBody(src, "hookParentIsDaemon");
    _ = try expectOnce(parent, "if (ev.hook_ppid == 0 or !std.mem.eql(u8, ev.provider, attr.daemon_provider)) return false;", "칸 없는 옛 줄");
    _ = try expectOnce(parent, "maru.pty.PtySession.judgeProcessArgs(pid, &attr.isManagedDaemonArgs) orelse return false;", "argv 판정");
    // 판정 기억의 키는 (pid, 시작 시각) — pid 만이면 재사용된 pid 에 옛 판정이 붙는다.
    const started_at = try expectOnce(parent, "const started = maru.pty.PtySession.processStartMicros(pid) orelse return false;", "시작 시각");
    const lookup_at = try expectOnce(parent, "if (self.codex_daemon_parents.lookup(ev.hook_ppid, started)) |known| return known;", "판정 조회");
    _ = try expectOnce(parent, "self.codex_daemon_parents.remember(ev.hook_ppid, started, verdict);", "판정 기억");
    if (!(started_at < lookup_at)) return error.WiringChanged;

    // 후보 자격은 순수 층이 정하고, 세 사실을 **그 Term 에서** 읽어 넘긴다 — 원격 칸이 빠지면 원격 pane 이 후보가 된다.
    const eligible_at = try expectOnce(route, "if (!attr.eligible(.{ .terminal = t.kind == .terminal, .codex = t.agent_kind == .codex, .remote = isRemoteAgentPane(t) })) continue;", "후보 자격");
    const any_at = try expectOnce(route, "any_cwd[any_count] = .{ .id = t.surfaceId() };", "cwd 무관 후보");
    if (!(eligible_at < any_at)) return error.WiringChanged;
    // 묶음은 그 목록으로 살아 있는지 보고, SessionStart 면 버린다 — 그 판정은 순수 층(`Bindings.resolve`)에 있다.
    const resolve_at = try expectOnce(route, "const bound = self.codex_daemon_bindings.resolve(sid, ev.kind == .session_start, any_cwd[0..any_count]);", "묶음 조회");
    if (!(any_at < resolve_at)) return error.WiringChanged;
    try expectCount(route, "codex_daemon_bindings.lookup(", 0, "검사 없는 묶음 조회");
    // 같은 cwd 후보도 순수 층이 정하고, 그 판정을 지난 것만 넣는다.
    const same_at = try expectOnce(route, "if (!attr.sameCwdCandidate(git_ops.termCwd(self, t, &t_cwd_buf), ev_cwd)) continue;", "같은 cwd");
    const cand_at = try expectOnce(route, "candidates[count] = .{ .id = a.id };", "같은 cwd 후보");
    if (!(resolve_at < same_at and same_at < cand_at)) return error.WiringChanged;

    const decide_at = try expectOnce(route, "const decision = attr.decide(.{", "순수 판정");
    // 판정은 두 후보 목록을 다 받는다 — cwd 무관 목록이 빠지면 `codex -C <dir>` 의 하나뿐인 pane 도 버려진다.
    _ = try expectOnce(route[decide_at..], ".candidates = candidates[0..count], .any_cwd = any_cwd[0..any_count],", "판정 입력");
    if (!(gate < decide_at)) return error.WiringChanged;
    // 판정 앞에서 `.here` 로 빠지는 길은 게이트 하나뿐이다 — 그 밖의 조기 `.here` 는 판정 우회다.
    try expectCount(route[0..decide_at], "return .here", 1, "판정 앞의 .here");
    // 버림은 어느 Term 에도 적용하지 않는다. 이 Term 에 적용하는 것은 판정이 이 Term 을 가리킬 때뿐이다.
    _ = try expectOnce(route, ".drop => |reason| { noteDaemonDrop(self, sid, reason); return .dropped; },", "버림 갈래");
    _ = try expectOnce(route, "if (r.target == term.surfaceId()) return .here;", "이 Term 갈래");
    _ = try expectOnce(route, "if (r.bind) self.codex_daemon_bindings.bind(sid, r.target);", "묶음");
    _ = try expectOnce(route[decide_at..], ".bound = bound,", "판정의 묶음 입력");
    try expectCount(src, "attr.decide(", 1, "판정 호출 수");
    // 진단은 (세션, 사유)마다 한 번 — 마지막 키 하나가 아니라 작은 집합으로 거른다.
    const drop = try fnBody(src, "noteDaemonDrop");
    _ = try expectOnce(drop, "if (!self.codex_daemon_drop_log.first(maru.session.codex_daemon_attribution.dropKey(sid, reason))) return;", "진단 거르기");
    // 이 함수는 신원을 직접 채택하지 않는다 — 채택은 판정이 고른 Term 의 배치 안에서만 일어난다.
    try expectCount(route, "adoptHookSessionIdentity", 0, "판정 함수 안의 신원 채택");
}

test "codex 데몬 귀속 — 재배정받은 Term 은 자기 파일이 없어도 훅 모드에 남고, 에이전트가 떠나면 묶음이 풀린다" {
    const a = std.testing.allocator;
    const raw = try read(a, agent_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const routed = try fnBody(src, "applyRoutedHookEvent");
    _ = try expectOnce(routed, "target.agent_hook_routed = true;", "재배정 표식");
    // 따라잡기는 받는 Term 에도 그 적용 동안 선다 — 회전본 건지기와 같은 되돌림 모양이다.
    const save_at = try expectOnce(routed, "const restore_catchup = target.hook.backlog_catchup;", "따라잡기 저장");
    const set_at = try expectOnce(routed, "target.hook.backlog_catchup = restore_catchup or backlog;", "따라잡기 세움");
    const back_at = try expectOnce(routed, "defer target.hook.backlog_catchup = restore_catchup;", "따라잡기 되돌림");
    const step_at = try expectOnce(routed, "tb.step(self, target, ev);", "재배정 적용");
    const finish_at = try expectOnce(routed, "tb.finish(self, target);", "재배정 배치 끝");
    // 배지는 권위표를 지나야 움직인다 — 훅 자리만 쓰고 끝나면 받는 Term 의 배지가 안 바뀐다.
    const arb_at = try expectOnce(routed, "arbitrateAgentState(self, target, false);", "재배정 뒤 권위표");
    if (!(save_at < set_at and set_at < back_at and back_at < step_at and step_at < finish_at and finish_at < arb_at)) return error.WiringChanged;
    _ = try expectOnce(routed, "if (backlog) target.hook.notice.clear();", "따라잡기 중 알림 억제");

    // 회전본 건지기도 귀속을 지난다 — 이 파일에 적힌 남의 세션 이벤트가 여기서 이 Term 에 붙으면 안 된다.
    const rotated = try fnBody(src, "drainRotatedAgentHookLog");
    const route_at = try expectOnce(rotated, "switch (routeHookEvent(self, term, ev)) { .here => {}, .elsewhere, .dropped => continue, }", "회전본 귀속");
    const apply_at = try expectOnce(rotated, "const applied = applyHookEvent(self, term, ev);", "회전본 적용");
    if (!(route_at < apply_at)) return error.WiringChanged;

    const poll = try fnBody(src, "pollAgentHookEvents");
    _ = try expectOnce(poll, "term.agent_hook_log_present = term.agent_hook_routed; return;", "파일 없음 갈래");

    const consumer = try fnBody(src, "pollAgentConsumer");
    const observe = std.mem.indexOf(u8, consumer, ".observe => {") orelse return error.WiringChanged;
    const in_observe = consumer[observe..];
    _ = try expectOnce(in_observe, "term.agent_hook_routed = false;", "관측 모드에서 재배정 해제");
    _ = try expectOnce(in_observe, "self.codex_daemon_bindings.dropTarget(term.surfaceId());", "관측 모드에서 묶음 해제");
}
