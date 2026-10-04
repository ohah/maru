//! codex 공유 데몬이 돌린 훅 이벤트를 **어느 Term 의 것인가**로 되찾는 순수 규칙([계약](../../docs/agent-hooks.md) §4.4).
//!
//! **문제**: codex 0.157 부터 TUI 는 얇은 클라이언트이고, 세션·훅·도구는 공유 데몬
//! `codex app-server --managed-daemon` 하나가 돌린다. 그 데몬은 **먼저 뜬 TUI 의 자식**이라 그 pane 의 env
//! (`MARU_HOOK_INSTANCE`·`MARU_HOOK_PANE`)를 물려받는다. 그래서 나중 pane 의 세션 훅도 **첫 pane 의 파일**에
//! 적힌다 — 파일 이름(pane)이 증거가 못 된다(2026-10-04 실측: 오른쪽 pane 의 세션 이벤트 26건이 전부 대기 중인
//! 왼쪽 pane 파일에 있었고, 사이드바는 그 세션을 왼쪽에 붙였다). openai/codex#48500 이 같은 결함이다.
//!
//! **해법**(muxa #197 · Orca #23411 과 같은 수준): 훅이 «pane 터미널 밖에서 돌았다» 는 표식을 남기면
//! (`agent_hook_command` — 데몬은 세션 리더라 제어 터미널이 없다), 그 이벤트의 파일 이름은 믿지 않고
//! `session_id` 로 귀속한다:
//!
//! 1. 이미 묶인 세션이면 그 Term.
//! 2. 같은 cwd 에서 codex 가 도는 로컬 Term(후보)이 **하나**면 그 Term.
//! 3. 여럿이면 **프롬프트 제출** 때 그 프롬프트가 화면에 보이는 후보가 **정확히 하나**일 때만 그 Term.
//! 4. 나머지는 어느 Term 에도 붙이지 않는다 — 틀린 pane 에 붙이느니 화면 관측만 남긴다.
//!
//! **이 파일은 순수하다.** 프로세스도 화면도 읽지 않는다 — 호출자가 모은 사실로 판정만 한다.

const std = @import("std");

/// 훅이 «pane 터미널 밖에서 돌았다» 를 적는 JSON 키. 훅은 이 키를 payload **맨 앞**에 끼운다
/// (`agent_hook_command.build`). 줄 형식(`<provider>\t<payload>`)을 안 바꾸므로 옛 파서는 모르는 키로 건너뛴다.
pub const detached_key = "maru_detached";
/// 훅이 끼우는 바이트 그대로. 훅의 상한 계산이 이 길이만큼 자리를 비워 둔다.
pub const detached_field = "\"" ++ detached_key ++ "\":true,";

/// 표식을 믿는 provider. claude 는 공유 데몬이 없고 그 훅 커맨드에는 표식 자체가 없다.
pub const daemon_provider = "codex";

/// 프롬프트로 후보를 고를 때의 **최소 길이**(공백을 뺀 코드포인트 수).
///
/// 짧은 프롬프트(「계속」·「ok」·`/new`)는 다른 pane 화면에도 우연히 있을 수 있다. 유일성 요구가 1차 방어이고
/// 이 하한은 2차다. muxa #197 이 같은 자리에 12 를 쓴다 — 한글은 글자당 정보가 많아 12 코드포인트면 한 문장이다.
pub const min_prompt_codepoints: usize = 12;

/// 이 이벤트가 데몬 표식을 단 codex 이벤트인가. 아니면 지금 규칙(파일 이름 = pane)을 그대로 쓴다.
pub fn isDaemonEvent(provider: []const u8, detached: bool) bool {
    return detached and std.mem.eql(u8, provider, daemon_provider);
}

/// 후보 하나 — 같은 cwd 에서 codex 가 도는 로컬 Term.
pub const Candidate = struct {
    id: u64,
    /// 이번 프롬프트가 그 Term 화면에 보이는가. 프롬프트 이벤트가 아니면 쓰지 않는다.
    shows_prompt: bool = false,
};

pub const Input = struct {
    /// 이미 묶인 Term(살아 있고 codex 가 도는 것만 — 호출자가 확인한다).
    bound: ?u64 = null,
    candidates: []const Candidate = &.{},
    /// `UserPromptSubmit` 인가.
    prompt_event: bool = false,
    /// 그 프롬프트가 `min_prompt_codepoints` 를 넘는가(`longEnough`).
    prompt_long_enough: bool = false,
};

/// 붙이지 않은 이유. 진단 한 줄에 실린다.
pub const Reason = enum {
    /// 같은 cwd 에 codex Term 이 없다(데몬이 maru 밖 클라이언트의 세션을 돌리는 경우 포함).
    no_candidate,
    /// 후보가 여럿인데 아직 프롬프트가 안 왔다(세션 시작·이어 하기 직후).
    ambiguous_before_prompt,
    /// 후보가 여럿인데 프롬프트가 짧다.
    prompt_too_short,
    /// 후보가 여럿인데 그 프롬프트가 보이는 화면이 하나가 아니다(없거나 둘 이상).
    prompt_not_unique,
};

pub const Decision = union(enum) {
    /// 그 Term 에 적용한다. `bind` 면 이 세션을 그 Term 에 묶는다.
    route: struct { target: u64, bind: bool },
    /// 어느 Term 에도 붙이지 않는다.
    drop: Reason,
};

/// 판정. 순서가 곧 계약이다 — 묶인 세션이 먼저, 후보 하나, 프롬프트 유일 일치, 그 밖은 버림.
pub fn decide(in: Input) Decision {
    if (in.bound) |t| return .{ .route = .{ .target = t, .bind = false } };
    if (in.candidates.len == 0) return .{ .drop = .no_candidate };
    if (in.candidates.len == 1) return .{ .route = .{ .target = in.candidates[0].id, .bind = true } };
    if (!in.prompt_event) return .{ .drop = .ambiguous_before_prompt };
    if (!in.prompt_long_enough) return .{ .drop = .prompt_too_short };
    var found: ?u64 = null;
    for (in.candidates) |c| {
        if (!c.shows_prompt) continue;
        if (found != null) return .{ .drop = .prompt_not_unique };
        found = c.id;
    }
    const t = found orelse return .{ .drop = .prompt_not_unique };
    return .{ .route = .{ .target = t, .bind = true } };
}

/// ASCII 공백을 **전부** 지운다. 화면은 프롬프트를 폭에 맞춰 줄바꿈하고 앞에 장식을 붙이므로, 공백까지 지우고
/// 부분문자열로 비교해야 줄바꿈 위치와 무관해진다. 담을 수 있는 만큼만 담는다.
pub fn compact(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    for (raw) |b| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
        if (n == out.len) break;
        out[n] = b;
        n += 1;
    }
    return out[0..n];
}

/// 공백을 지운 프롬프트가 하한을 넘는가(코드포인트로 센다 — 바이트로 세면 한글이 세 배로 길어 보인다).
pub fn longEnough(compacted: []const u8) bool {
    const count = std.unicode.utf8CountCodepoints(compacted) catch compacted.len;
    return count >= min_prompt_codepoints;
}

/// 공백을 지운 화면에 공백을 지운 프롬프트가 있는가.
pub fn screenShows(compacted_screen: []const u8, compacted_prompt: []const u8) bool {
    if (compacted_prompt.len == 0) return false;
    return std.mem.indexOf(u8, compacted_screen, compacted_prompt) != null;
}

/// 두 경로가 같은 디렉터리인가(끝의 `/` 하나는 무시한다).
pub fn sameDir(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimSlash(a), trimSlash(b));
}

fn trimSlash(p: []const u8) []const u8 {
    if (p.len > 1 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
    return p;
}

/// 세션 → Term 묶음. 고정 크기라 힙을 안 잡는다. 가득 차면 **가장 오래 쓰지 않은** 것을 밀어낸다.
pub const Bindings = struct {
    pub const capacity = 16;
    pub const max_session_bytes = 64;

    const Entry = struct {
        session: [max_session_bytes]u8 = undefined,
        session_len: u8 = 0,
        target: u64 = 0,
        used: u64 = 0,
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    clock: u64 = 0,

    pub fn lookup(self: *Bindings, session: []const u8) ?u64 {
        const e = self.find(session) orelse return null;
        self.clock += 1;
        e.used = self.clock;
        return e.target;
    }

    /// 묶는다. 이미 있으면 대상을 바꾼다. 담을 수 없는 길이면 묶지 않는다(자르면 다른 세션과 섞인다).
    pub fn bind(self: *Bindings, session: []const u8, target: u64) void {
        if (session.len == 0 or session.len > max_session_bytes) return;
        self.clock += 1;
        if (self.find(session)) |e| {
            e.target = target;
            e.used = self.clock;
            return;
        }
        var slot = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.session_len == 0) {
                slot = e;
                break;
            }
            if (e.used < slot.used) slot = e;
        }
        @memcpy(slot.session[0..session.len], session);
        slot.session_len = @intCast(session.len);
        slot.target = target;
        slot.used = self.clock;
    }

    pub fn unbind(self: *Bindings, session: []const u8) void {
        if (self.find(session)) |e| e.session_len = 0;
    }

    /// 그 Term 이 닫혔거나 codex 를 벗어났다 — 그 Term 에 묶인 세션을 모두 푼다.
    pub fn dropTarget(self: *Bindings, target: u64) void {
        for (&self.entries) |*e| {
            if (e.session_len != 0 and e.target == target) e.session_len = 0;
        }
    }

    fn find(self: *Bindings, session: []const u8) ?*Entry {
        if (session.len == 0) return null;
        for (&self.entries) |*e| {
            if (e.session_len == session.len and std.mem.eql(u8, e.session[0..e.session_len], session)) return e;
        }
        return null;
    }
};

const testing = std.testing;

test "codex 데몬 귀속: 판정표 — 묶임이 먼저, 후보 하나, 프롬프트 유일 일치, 그 밖은 버림" {
    const two_one_match = [_]Candidate{ .{ .id = 89 }, .{ .id = 90, .shows_prompt = true } };
    const two_both = [_]Candidate{ .{ .id = 89, .shows_prompt = true }, .{ .id = 90, .shows_prompt = true } };
    const two_none = [_]Candidate{ .{ .id = 89 }, .{ .id = 90 } };
    const one = [_]Candidate{.{ .id = 90 }};
    const Case = struct { in: Input, want: Decision };
    const cases = [_]Case{
        // 묶인 세션은 후보가 여럿이어도 그 Term — 도구 이벤트마다 화면을 다시 볼 이유가 없다.
        .{ .in = .{ .bound = 90, .candidates = &two_none }, .want = .{ .route = .{ .target = 90, .bind = false } } },
        .{ .in = .{ .candidates = &.{} }, .want = .{ .drop = .no_candidate } },
        .{ .in = .{ .candidates = &one }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        // 2026-10-04 실측 모양: 같은 cwd 의 codex 둘, 세션 시작(프롬프트 전) — 물려받은 89 에 붙이지 않는다.
        .{ .in = .{ .candidates = &two_one_match }, .want = .{ .drop = .ambiguous_before_prompt } },
        .{ .in = .{ .candidates = &two_one_match, .prompt_event = true }, .want = .{ .drop = .prompt_too_short } },
        .{ .in = .{ .candidates = &two_one_match, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        .{ .in = .{ .candidates = &two_both, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .drop = .prompt_not_unique } },
        .{ .in = .{ .candidates = &two_none, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .drop = .prompt_not_unique } },
    };
    for (cases) |c| try testing.expectEqualDeep(c.want, decide(c.in));
}

test "codex 데몬 귀속: 표식은 codex 에서만 믿고, 프롬프트 비교는 줄바꿈과 무관하며 짧은 것은 안 믿는다" {
    try testing.expect(isDaemonEvent("codex", true));
    try testing.expect(!isDaemonEvent("codex", false));
    try testing.expect(!isDaemonEvent("claude", true));

    var pb: [128]u8 = undefined;
    var sb: [256]u8 = undefined;
    const prompt = compact(&pb, "용량이 너무 없는데 용량 한번 체크 해주세요");
    // 화면은 폭에 맞춰 접고 장식(`›`)을 붙인다.
    const screen = compact(&sb, "› 용량이 너무 없는데 용량 한번\n  체크 해주세요\n\n• Working (18s)");
    try testing.expect(screenShows(screen, prompt));
    try testing.expect(!screenShows(compact(&sb, "› Look who's at the keyboard."), prompt));
    try testing.expect(!screenShows(screen, ""));
    try testing.expect(longEnough(prompt));
    try testing.expect(!longEnough(compact(&pb, "계속 진행해 주세요")));
    try testing.expect(!longEnough(compact(&pb, "ok")));

    try testing.expect(sameDir("/w/payhere-homepage", "/w/payhere-homepage/"));
    try testing.expect(!sameDir("/w/payhere-homepage", "/w/payhere"));
}

test "codex 데몬 귀속: 묶음은 세션마다 하나, Term 이 떠나면 풀리고, 가득 차면 오래된 것부터 밀린다" {
    var b: Bindings = .{};
    b.bind("01a105dd", 90);
    try testing.expectEqual(@as(?u64, 90), b.lookup("01a105dd"));
    // /new 로 새 세션이 와도 옛 묶음과 섞이지 않는다.
    try testing.expectEqual(@as(?u64, null), b.lookup("01a105ee"));
    b.bind("01a105dd", 91);
    try testing.expectEqual(@as(?u64, 91), b.lookup("01a105dd"));
    b.dropTarget(91);
    try testing.expectEqual(@as(?u64, null), b.lookup("01a105dd"));
    // 담을 수 없는 길이는 묶지 않는다(자르면 앞부분이 같은 두 세션이 섞인다).
    b.bind("x" ** (Bindings.max_session_bytes + 1), 1);
    try testing.expectEqual(@as(?u64, null), b.lookup("x" ** Bindings.max_session_bytes));

    var f: Bindings = .{};
    var name: [8]u8 = undefined;
    for (0..Bindings.capacity) |i| f.bind(std.fmt.bufPrint(&name, "s{d:0>3}", .{i}) catch unreachable, i);
    _ = f.lookup("s000"); // 가장 먼저 넣었지만 방금 썼다
    f.bind("new", 99);
    try testing.expectEqual(@as(?u64, 0), f.lookup("s000"));
    try testing.expectEqual(@as(?u64, null), f.lookup("s001")); // 가장 오래 안 쓴 것이 밀렸다
    try testing.expectEqual(@as(?u64, 99), f.lookup("new"));
}
