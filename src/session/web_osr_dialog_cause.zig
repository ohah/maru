//! Chromium 탭 JS 대화상자의 「누가 띄웠나」(W9c② — docs/plans/web-osr-backend.md W9c C6''·C13) — L2 순수.
//!
//! 시험이 증명하는 것: 대화상자가 도착한 순간의 두 시각(에이전트 입력·사용자 입력)으로 원인을 한 번 정한다. 원인은 목록(`browser.dialog`)이 싣는
//! 정보다 — 에이전트가 답해도 되는가는 가르지 않는다(사용자 결정 2026-11-17 「에이전트는 사용자와 같은 힘」: 사람이 띄운 것·누가 띄웠는지 모르는 것·
//! 사람이 입력한 문서의 떠나기 확인도 에이전트가 답한다 — 옛 `mayAnswer`·`mayLeave` 를 걷었다).
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
