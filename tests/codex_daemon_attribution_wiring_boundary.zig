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
    _ = try expectOnce(parent, "self.codex_daemon_parents.remember(ev.hook_ppid, verdict);", "판정 기억");
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
    // 묶인 세션은 그 Term 이 살아 있고 codex 가 돌 때만 쓴다.
    _ = try expectOnce(route, "if (t.agent_kind == .codex) bound = id;", "묶음 재확인");
    try expectCount(src, "attr.decide(", 1, "판정 호출 수");
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
    _ = try expectOnce(routed, "tb.step(self, target, ev);", "재배정 적용");
    _ = try expectOnce(routed, "if (backlog) target.hook.notice.clear();", "따라잡기 중 알림 억제");

    const poll = try fnBody(src, "pollAgentHookEvents");
    _ = try expectOnce(poll, "term.agent_hook_log_present = term.agent_hook_routed; return;", "파일 없음 갈래");

    const consumer = try fnBody(src, "pollAgentConsumer");
    const observe = std.mem.indexOf(u8, consumer, ".observe => {") orelse return error.WiringChanged;
    const in_observe = consumer[observe..];
    _ = try expectOnce(in_observe, "term.agent_hook_routed = false;", "관측 모드에서 재배정 해제");
    _ = try expectOnce(in_observe, "self.codex_daemon_bindings.dropTarget(term.surfaceId());", "관측 모드에서 묶음 해제");
}
