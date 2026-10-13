//! Chromium 탭 JS 대화상자의 「누가 띄웠나」와 「에이전트가 답해도 되나」(W9c② — docs/plans/web-osr-backend.md W9c C6''·C13) — L2 순수.
//!
//! 시험이 증명하는 것: 대화상자가 도착한 순간의 두 시각(에이전트 입력·사용자 입력)으로 원인을 한 번 정하고, 그 원인과 지금 상태로
//! 에이전트의 답을 허락한다. 브라우저 패널에서 중요한 이유 — 에이전트가 사용자의 「저장하지 않은 입력이 있습니다」 질문에 몰래 「떠나기」로
//! 답하면 사용자의 글이 사라진다. 그래서 사용자가 띄운 것은 절대, 누가 띄웠는지 모르는 것은 에이전트가 연 탭에서만 답하게 한다.
//!
//! 원인은 **도착할 때 한 번** 정해 대화상자에 적는다(계획 공격 3 회차 — 답할 때 「지금 − 사용자 시각」 으로 재면 시간이 지나며 판정이
//! 바뀌었다). 시각은 모두 같은 단조 시계(web_osr 의 CLOCK_MONOTONIC)여야 한다 — 다른 시계와 섞으면 잠자기 뒤 몇 시간이 어긋났다(실측
//! 11,995 초).

const std = @import("std");

/// 대화상자를 띄운 쪽(도착할 때 정한다).
pub const Cause = enum {
    /// 창 안에 에이전트 입력만 있었다.
    agent,
    /// 창 안에 사용자 입력만 있었다 — 또는 사용자가 묻는 닫기의 떠나기 확인이다.
    user,
    /// 둘 다 창 안에 있었고 에이전트가 더 늦었다(사용자가 더 늦으면 `user` — W9c② 적대 리뷰 2 회차).
    ambiguous,
    /// 둘 다 없었다(오래된 타이머·서버가 늦게 보낸 응답 등).
    unknown,
};

/// 「방금」 의 폭. 계획 공격 3 회차 실측: 트리거 뒤 대화상자까지의 지연은 maru·CEF 몫이 1~40 ms 이고 나머지는 페이지 자신의 지연
/// (setTimeout·fetch)이다. 숨은 탭은 타이머가 약 1 초 단위로 묶인다 — 그 둘을 넉넉히 덮고, 사용자가 다른 일을 시작했을 만한 시간보다
/// 짧게 잡았다. 3 초 fetch 뒤 alert(+3,010 ms)는 에이전트 것으로, 8 초 fetch 뒤 alert 는 「모름」 으로 간다.
pub const window_ms: i64 = 5_000;

fn recent(t: i64, now: i64) bool {
    return now - t <= window_ms;
}

/// 도착 시각 `now` 에 팝업 가족의 마지막 에이전트 입력 `agent_ms` 와 마지막 사용자 입력 `user_ms` 로 원인을 정한다. `user_close` 는
/// 사용자가 고른 닫기를 페이지에 묻는 중(`close_ask` asking·asked, 에이전트의 닫기가 아님)인데 온 떠나기 확인이다 — 시각과 무관하게
/// 사용자 것이다.
pub fn classify(agent_ms: i64, user_ms: i64, now: i64, user_close: bool) Cause {
    if (user_close) return .user;
    const a = recent(agent_ms, now);
    const u = recent(user_ms, now);
    // 둘 다 창 안 — 마지막에 움직인 쪽이 띄웠을 공산이 크다. 사용자가 더 늦으면 사용자 것(2 회차: 에이전트 op 1 초 뒤 사용자가 다른 앱에
    // 놓은 dragend 의 confirm 을 「모호」 로 봐 보이지 않는 탭이라 에이전트가 답했다). 에이전트가 더 늦으면 모호(사용자가 누른 직후의 에이전트
    // 누름 — 사용자의 늦은 confirm 일 수 있다).
    if (a and u) return if (user_ms >= agent_ms) .user else .ambiguous;
    if (a) return .agent;
    if (u) return .user;
    return .unknown;
}

/// 답하는 순간의 상태(대화상자 하나).
pub const Situation = struct {
    cause: Cause,
    /// 어느 창이 sheet 로 사용자에게 보이고 있다(`Dialog.shown_by != 0`).
    shown: bool,
    /// 대화상자가 도착한 뒤 사용자가 그 탭에 손댔다(페이지 입력·주소창·탐색 단추).
    user_input_since_arrival: bool,
    /// 그 탭은 묻는 에이전트(pane)가 `browser.open` 으로 연 탭이다(C13).
    agent_tab: bool,
};

/// 에이전트가 이 대화상자에 답해도 되는가(닫기·확인 공통). C6'':
/// - 사용자가 띄운 것 — 절대.
/// - 에이전트가 띄운 것 — 된다.
/// - 둘 다 — 사용자에게 보이지 않고 도착 뒤 사용자가 손대지 않았을 때만.
/// - 모름 — 에이전트가 연 탭에서, 사용자에게 보이지 않을 때만(C13: grant 는 세션 내내 남는다 — 오래된 grant 로 사람 탭의 누가 띄웠는지
///   모르는 질문에 답하지 않게).
pub fn mayAnswer(s: Situation) bool {
    return switch (s.cause) {
        .user => false,
        .agent => true,
        .ambiguous => !s.shown and !s.user_input_since_arrival,
        .unknown => s.agent_tab and !s.shown,
    };
}

/// 떠나기 확인(`before_unload`)을 「떠나기」로 답해도 되는가 — `mayAnswer` 에 더해, 사용자가 이 문서에 한 번도 손대지 않았어야 한다
/// (저장하지 않은 사용자 입력을 지킨다). 「머무르기」는 `mayAnswer` 만 본다.
pub fn mayLeave(s: Situation, document_touched_by_user: bool) bool {
    return mayAnswer(s) and !document_touched_by_user;
}

// ── 시험 ──────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const never: i64 = std.math.minInt(i64) / 2;

test "W9c②: 원인은 도착 시각의 창(5 초) 안에 누구 입력이 있었나로 — 에이전트만·사용자만·둘 다·없음" {
    const now: i64 = 100_000;
    try testing.expectEqual(Cause.agent, classify(now - 10, never, now, false));
    try testing.expectEqual(Cause.agent, classify(now - window_ms, now - window_ms - 1, now, false)); // 경계: 정확히 5 초는 안
    try testing.expectEqual(Cause.user, classify(never, now - 10, now, false));
    try testing.expectEqual(Cause.user, classify(now - window_ms - 1, now - 1, now, false)); // 에이전트 입력은 5 초 밖
    try testing.expectEqual(Cause.ambiguous, classify(now - 1, now - 2, now, false)); // 에이전트가 더 늦다 — 모호
    try testing.expectEqual(Cause.user, classify(now - 2, now - 1, now, false)); // 사용자가 더 늦다 — 사용자 것(2 회차)
    try testing.expectEqual(Cause.user, classify(now - 2, now - 2, now, false)); // 같은 때 — 사용자 쪽으로
    try testing.expectEqual(Cause.unknown, classify(never, never, now, false));
    try testing.expectEqual(Cause.unknown, classify(now - 8_000, now - 9_000, now, false)); // 8 초 fetch 뒤 alert
}

test "W9c②: 사용자가 묻는 닫기의 떠나기 확인은 에이전트가 방금 눌렀어도 사용자 것이다" {
    const now: i64 = 50_000;
    try testing.expectEqual(Cause.user, classify(now - 1, never, now, true));
    try testing.expectEqual(Cause.user, classify(never, never, now, true));
}

test "W9c②: 답해도 되나 — 사용자 것은 절대, 에이전트 것은 늘, 모호는 안 보이고 손대지 않았을 때, 모름은 에이전트가 연 탭에서 안 보일 때만" {
    const base: Situation = .{ .cause = .agent, .shown = true, .user_input_since_arrival = true, .agent_tab = false };
    try testing.expect(mayAnswer(base)); // 에이전트 것 — 보여도·손댔어도
    var s = base;
    s.cause = .user;
    s.shown = false;
    s.user_input_since_arrival = false;
    s.agent_tab = true;
    try testing.expect(!mayAnswer(s)); // 사용자 것 — 어떤 상태든

    s = .{ .cause = .ambiguous, .shown = false, .user_input_since_arrival = false, .agent_tab = false };
    try testing.expect(mayAnswer(s));
    s.shown = true;
    try testing.expect(!mayAnswer(s)); // 사용자가 sheet 로 보고 있다
    s.shown = false;
    s.user_input_since_arrival = true;
    try testing.expect(!mayAnswer(s)); // 도착 뒤 사용자가 손댔다

    s = .{ .cause = .unknown, .shown = false, .user_input_since_arrival = false, .agent_tab = false };
    try testing.expect(!mayAnswer(s)); // 사람의 탭(오래된 grant) — C13
    s.agent_tab = true;
    try testing.expect(mayAnswer(s));
    s.shown = true;
    try testing.expect(!mayAnswer(s));
}

test "W9c②: 떠나기 확인의 「떠나기」는 사용자가 그 문서에 손대지 않았을 때만 — 「머무르기」는 답할 수 있으면 된다" {
    const s: Situation = .{ .cause = .agent, .shown = false, .user_input_since_arrival = false, .agent_tab = true };
    try testing.expect(mayLeave(s, false));
    try testing.expect(!mayLeave(s, true)); // 사용자가 쓴 글이 있다
    try testing.expect(mayAnswer(s)); // 머무르기는 된다
    var u = s;
    u.cause = .user;
    try testing.expect(!mayLeave(u, false));
}
