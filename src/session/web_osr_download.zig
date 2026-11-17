//! Chromium 탭 다운로드를 받을지·보류할지·저장 창을 띄울지(W10a·W10b, 사용자 결정 2026-11-17) — L2 순수.
//!
//! 시험이 증명하는 것: 새 다운로드 하나의 처음 상태가 「묻기 설정·실행될 수 있는 종류·누가 시작했나」 만으로 정해지고, 에이전트가 몬
//! 다운로드(에이전트 탭이거나 에이전트의 최근 동작)는 실행 파일이어도 보류하지 않는다는 것. 브라우저 패널에서 중요한 이유 — 보류는
//! 페이지가 사람 모르게 `.command`·`.pkg` 같은 파일을 떨구는 것을 막는 브라우저의 안전인데, 사용자는 에이전트에게 모든 권한을 주기로
//! 했다(2026-11-16 「AI가 모든 접근 가능하게」 → 2026-11-17 「실행 파일 다운로드 보류 없애기」). 그래서 에이전트가 몬 것만 사람이 몬
//! 것처럼 받고, **아무도 몰지 않은 것**(사용자 탭에서 페이지가 스스로)은 그대로 보류한다.
//!
//! 「몰았다」 의 시각 규칙은 사람과 에이전트가 같다(`gestureLive`) — 동작 뒤 `window_ms` 안이고 그 뒤 주 프레임에 새 문서가 오지 않았다.
//! 누른 링크가 연 다른 문서가 몇 초 뒤 스스로 받는 것은 그 누름의 다운로드가 아니다(W10a 적대 리뷰 1 회차).

const std = @import("std");

/// 새 다운로드의 처음 상태.
pub const Start = enum {
    /// 저장할 곳을 묻는다(「매번 묻기」 — 사람이 누른 것만).
    asking,
    /// 받지 않고 붙든다 — 목록 창에서 「받기」 를 눌러야 받는다.
    held,
    /// 곧 받는다(`~/Downloads`, 같은 이름이면 번호).
    save,
};

pub const Facts = struct {
    /// 설정 `browser.download-ask`.
    ask: bool,
    /// 실행될 수 있는 종류(`web_downloads.isRisky` — 확장자).
    risky: bool,
    /// 사람이 그 탭에서 시작했다(누름·키·주소창 — `gestureLive`).
    by_user: bool,
    /// 에이전트가 몰았다 — 에이전트 탭(◈)이거나 에이전트의 최근 동작(`gestureLive`).
    by_agent: bool,
    /// 그 탭에 이미 저장 창을 기다리는 다운로드가 있다(한 탭에 하나씩 묻는다 — W10b 설계 공격 H3).
    asking_in_tab: bool,
};

/// 처음 상태. 묻기를 켰으면 지금 그대로다 — 사람이 누른 것만 묻고 나머지는 보류(에이전트 것도 — 저장 창은 사람이 답해야 해서 에이전트가
/// 띄우게 하지 않는다, 사용자 확인 대기 결정). 묻기를 껐으면 실행 파일만 보류하되, 사람이나 에이전트가 몬 것은 받는다.
pub fn start(f: Facts) Start {
    if (f.ask) return if (f.by_user and !f.asking_in_tab) .asking else .held;
    if (f.risky and !f.by_user and !f.by_agent) return .held;
    return .save;
}

/// 다운로드 목록 창을 앞으로 낼 것인가(Swift 가 maru 가 앞이고 터미널 창이 키일 때만 낸다 — 키는 빼앗지 않는다). 사람이 시작한 것(저장 창이
/// 뜨는 것은 빼고 — 겹치지 않게)과 보류한 것(「받기」 를 눌러야 한다)은 지금처럼, 그리고 **에이전트가 받은 실행 파일** — 예전에 보류로 창을
/// 내던 바로 그 다운로드다. 이제 묻지 않고 받으니 사람이 「에이전트가 무엇을 받았는지」 를 알게 남긴다(권한이 아니라 정보 — ◈ 와 같은 결).
pub fn showsList(f: Facts, s: Start) bool {
    return (f.by_user and s != .asking) or s == .held or (f.by_agent and f.risky and s == .save);
}

/// 동작 시각 `t` 가 지금(`now`) 다운로드를 「몬」 것으로 치는가 — `window` 안이고 그 뒤 새 문서(`last_nav`)가 오지 않았다. 시각은 모두 같은
/// 단조 시계여야 한다. `t` 가 `now` 보다 늦으면(같은 밀리초의 순서) 창 안이다.
pub fn gestureLive(t: i64, last_nav: i64, now: i64, window: i64) bool {
    return t > last_nav and now - t <= window;
}

// ── 시험 ──────────────────────────────────────────────────────────────────────────────────────────────

test "묻기를 껐을 때: 실행 파일은 사람도 에이전트도 몰지 않았을 때만 보류, 보통 파일은 늘 받는다" {
    const T = std.testing;
    // 32 칸 전수 — 기대는 규칙을 손으로 다시 적은 것이다(구현을 부르지 않는다).
    for ([_]bool{ false, true }) |ask| for ([_]bool{ false, true }) |risky| for ([_]bool{ false, true }) |by_user| for ([_]bool{ false, true }) |by_agent| for ([_]bool{ false, true }) |busy| {
        const f: Facts = .{ .ask = ask, .risky = risky, .by_user = by_user, .by_agent = by_agent, .asking_in_tab = busy };
        const want: Start = if (ask)
            (if (by_user and !busy) .asking else .held)
        else if (risky and !by_user and !by_agent) .held else .save;
        try T.expectEqual(want, start(f));
    };
    // 이 변경의 핵심 칸들을 이름으로도 고정한다.
    try T.expectEqual(Start.save, start(.{ .ask = false, .risky = true, .by_user = false, .by_agent = true, .asking_in_tab = false })); // 에이전트의 .command
    try T.expectEqual(Start.held, start(.{ .ask = false, .risky = true, .by_user = false, .by_agent = false, .asking_in_tab = false })); // 아무도 몰지 않은 .command
    try T.expectEqual(Start.save, start(.{ .ask = false, .risky = true, .by_user = true, .by_agent = false, .asking_in_tab = false })); // 사람의 .command(전과 같다)
}

test "묻기를 켰을 때: 에이전트가 몬 것도 저장 창을 띄우지 않고 보류한다(지금 그대로), 사람의 것은 한 탭에 하나씩 묻는다" {
    const T = std.testing;
    try T.expectEqual(Start.held, start(.{ .ask = true, .risky = true, .by_user = false, .by_agent = true, .asking_in_tab = false }));
    try T.expectEqual(Start.held, start(.{ .ask = true, .risky = false, .by_user = false, .by_agent = true, .asking_in_tab = false }));
    try T.expectEqual(Start.asking, start(.{ .ask = true, .risky = true, .by_user = true, .by_agent = true, .asking_in_tab = false }));
    try T.expectEqual(Start.held, start(.{ .ask = true, .risky = false, .by_user = true, .by_agent = false, .asking_in_tab = true }));
}

test "목록 창: 사람이 시작한 것(묻는 것은 빼고)·보류한 것·에이전트가 받은 실행 파일 — 에이전트의 보통 파일은 내지 않는다" {
    const T = std.testing;
    const agent_exe: Facts = .{ .ask = false, .risky = true, .by_user = false, .by_agent = true, .asking_in_tab = false };
    try T.expect(showsList(agent_exe, start(agent_exe)));
    const agent_txt: Facts = .{ .ask = false, .risky = false, .by_user = false, .by_agent = true, .asking_in_tab = false };
    try T.expect(!showsList(agent_txt, start(agent_txt)));
    const page_exe: Facts = .{ .ask = false, .risky = true, .by_user = false, .by_agent = false, .asking_in_tab = false };
    try T.expectEqual(Start.held, start(page_exe));
    try T.expect(showsList(page_exe, .held));
    const page_txt: Facts = .{ .ask = false, .risky = false, .by_user = false, .by_agent = false, .asking_in_tab = false };
    try T.expect(!showsList(page_txt, start(page_txt)));
    const user_ask: Facts = .{ .ask = true, .risky = false, .by_user = true, .by_agent = false, .asking_in_tab = false };
    try T.expect(!showsList(user_ask, start(user_ask))); // 저장 창이 뜬다 — 목록과 겹치지 않게
    const user_save: Facts = .{ .ask = false, .risky = false, .by_user = true, .by_agent = false, .asking_in_tab = false };
    try T.expect(showsList(user_save, start(user_save)));
    // 묻기 켬의 에이전트 것은 보류라 창을 낸다(받기를 눌러야 한다).
    const agent_ask: Facts = .{ .ask = true, .risky = true, .by_user = false, .by_agent = true, .asking_in_tab = false };
    try T.expect(showsList(agent_ask, start(agent_ask)));
}

test "몸짓 시각: 창 안이고 그 뒤 새 문서가 없을 때만 — 창의 끝은 들고, 새 문서와 같은 시각은 무효" {
    const T = std.testing;
    try T.expect(gestureLive(1000, 0, 1000, 3000));
    try T.expect(gestureLive(1000, 0, 4000, 3000)); // 끝 — 든다
    try T.expect(!gestureLive(1000, 0, 4001, 3000));
    try T.expect(!gestureLive(1000, 1000, 1500, 3000)); // 동작과 같은 때 새 문서 — 무효
    try T.expect(!gestureLive(1000, 1200, 1500, 3000)); // 동작 뒤 새 문서
    try T.expect(gestureLive(1300, 1200, 1500, 3000)); // 새 문서에서 다시 동작
    try T.expect(gestureLive(1600, 0, 1500, 3000)); // 같은 밀리초의 순서(동작이 now 보다 늦게 찍혔다)
    const never: i64 = std.math.minInt(i64) / 2; // web_osr 의 「없음」 값
    try T.expect(!gestureLive(never, never, 1500, 3000));
}
