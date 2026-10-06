//! 재접속 job 이 붙든 runtime 의 Term 을 사용자가 닫을 때 **언제 backend 를 닫는가** — 순수 판정(std-only).
//!
//! ## 왜 있나
//!
//! 재접속(CR5)은 여러 프레임에 걸친 host 단위 job 이다. job 은 시작할 때 host 의 runtime 행을 붙들고
//! (`runtime_rows`), `connected` 다음 전이가 그 runtime 의 attachment 를 `retirement_prepared` 로 얼린다. 그 동안
//! 사용자가 ⌘W 로 탭을 닫으면 두 갈래로 앱이 끝났다.
//!
//! - **얼림 구간**: `destroyTerm` 이 같은 호출 안에서 `remove` → runtime `deinit` 까지 가는데, 얼린 attachment 의
//!   `tryDeinit` 이 `.busy` 라 `teardown invariant violated` 로 abort 한다.
//! - **커밋 뒤**: `remove` 는 끝나지만 job 이 붙든 행이 맵에서 사라져 다음 전이의 `runtimes.get` 이 실패하고
//!   `fatalIntegrity(.proof_loss)` 로 끝난다.
//!
//! 사용자 닫기(`closeActiveTerm`·`closeActivePane`·`closeTab` → `destroyTerm`)는 Term 을 트리에서 이미 뺀 뒤라
//! backend 의 「아직」(`.event_pending`)을 돌려받아도 다시 부를 자리가 없었다 — 그래서 `@panic` 이었다.
//!
//! ## 판정
//!
//! job 이 그 runtime 을 붙든 동안은 backend 에 닫기를 **보내지 않는다**. Term 은 UI 에서 바로 사라지고(트리에서 이미
//! 빠졌다), backend 닫기·제거와 Term heap 해제만 AppSession 의 미룬 목록으로 넘어가 tick 마다 다시 묻는다. job 이
//! 끝나면(완료든 실패든) 그때 평소 순서로 닫는다.
//!
//! 「붙들었는가」는 job 이 **진행 중**일 때만이다. 실패로 끝난 job(`host_failure_complete`, retained-terminal)은
//! 다음 재접속 전까지 backend 가 들고 있지만 더는 전이하지 않고 그 attachment 는 이미 terminal 이다 — 거기까지
//! 미루면 ⌘W 가 영영 안 닫힌다.

const std = @import("std");

/// backend job 이 지금 어떤 상태인가 — 호출부가 job 상태를 이 셋으로 접어 넘긴다.
pub const JobPhase = enum {
    /// job 이 없거나 `idle` 이다.
    none,
    /// 연결부터 완료 요약 정산 전까지 — 프레임마다 전이하며 행의 runtime 을 맵에서 찾는다.
    in_flight,
    /// 실패로 끝나 backend 가 보관 중(`host_failure_complete`). 더는 전이하지 않는다.
    retained_terminal,
};

/// job 이 이 runtime 을 붙들었는가. 행에 있고 job 이 진행 중일 때만 참이다.
pub fn holdsRuntime(phase: JobPhase, in_rows: bool) bool {
    return in_rows and phase == .in_flight;
}

/// 판정을 부르는 자리. 첫 시도는 `destroyTerm` 안(사용자 닫기·정리), 재시도는 미룬 목록의 tick 이다.
pub const Attempt = enum { first, retry };

pub const Action = enum {
    /// 지금 backend 를 부른다(닫기면 `closeAndDetach`, 제거면 `remove`) / 다음 단계로 간다.
    proceed,
    /// 이번에는 backend 에 아무것도 보내지 않고 미룬 목록에 둔다(재시도면 목록에 그대로 둔다).
    defer_teardown,
    /// backend 제거까지 끝났다 — Term heap 을 푼다.
    finish,
    /// 첫 시도에서 job 이 붙들지도 않았는데 backend 가 「아직」이라 했다. 사용자 닫기는 이 결과를 다시 부를 자리가
    /// 없으므로 불변식 위반이다(예전 `@panic` 과 같은 자리·같은 의미).
    invariant_violation,
};

/// backend 에 닫기를 보내기 **전에** 묻는다. job 이 붙든 runtime 이면 보내지 않는다.
pub fn admit(held_by_reconnect: bool) Action {
    return if (held_by_reconnect) .defer_teardown else .proceed;
}

/// `closeAndDetach` 가 끝났는가(`complete`)를 받아 다음을 정한다.
pub fn afterClose(attempt: Attempt, complete: bool) Action {
    if (complete) return .proceed;
    return switch (attempt) {
        .first => .invariant_violation,
        .retry => .defer_teardown,
    };
}

/// `remove` 가 runtime 을 뺐는가(`removed`)를 받아 다음을 정한다.
pub fn afterRemove(attempt: Attempt, removed: bool) Action {
    if (removed) return .finish;
    return switch (attempt) {
        .first => .invariant_violation,
        .retry => .defer_teardown,
    };
}

test "재접속 닫기 미룸: 진행 중인 job 이 행으로 붙든 runtime 만 붙든 것이다" {
    try std.testing.expect(holdsRuntime(.in_flight, true));
    try std.testing.expect(!holdsRuntime(.in_flight, false));
    try std.testing.expect(!holdsRuntime(.none, true));
    // 실패로 끝나 보관 중인 job 은 전이하지 않는다 — 여기까지 미루면 ⌘W 가 영영 안 닫힌다.
    try std.testing.expect(!holdsRuntime(.retained_terminal, true));
}

test "재접속 닫기 미룸: job 이 붙든 runtime 은 backend 에 닫기를 보내지 않고 미룬다" {
    try std.testing.expectEqual(Action.defer_teardown, admit(true));
    try std.testing.expectEqual(Action.proceed, admit(false));
}

test "재접속 닫기 미룸: 첫 시도의 「아직」은 불변식 위반, 재시도의 「아직」은 다음 tick 으로 미룬다" {
    try std.testing.expectEqual(Action.invariant_violation, afterClose(.first, false));
    try std.testing.expectEqual(Action.defer_teardown, afterClose(.retry, false));
    try std.testing.expectEqual(Action.invariant_violation, afterRemove(.first, false));
    try std.testing.expectEqual(Action.defer_teardown, afterRemove(.retry, false));
}

test "재접속 닫기 미룸: 닫기가 끝나면 제거로, 제거가 끝나면 해제로 간다 — 첫 시도와 재시도가 같다" {
    inline for (.{ Attempt.first, Attempt.retry }) |attempt| {
        try std.testing.expectEqual(Action.proceed, afterClose(attempt, true));
        try std.testing.expectEqual(Action.finish, afterRemove(attempt, true));
    }
}
