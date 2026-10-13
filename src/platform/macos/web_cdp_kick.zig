//! DevTools 호출에 kick(숨은 탭을 깨우는 작은 스크린샷, W9b②-3)을 붙이는가 — `web_cdp_ops` 가 호출마다 정하고 `web_osr.devtoolsCallKick`
//! 이 그대로 받는다(둘 사이에 옮겨 적는 대응이 없게 — 적대 리뷰 5 회차: `app_host_abi` 에서 종류를 bool 로 옮기던 줄은 시험이 닿지 않았다).

/// `required` — 두 자리가 다 비어야 보내고 없으면 `Busy`(숨은 탭에서 kick 없이 가면 30 초 매달리는 접근성 질의·5 초 걸리는 포인터
/// 이동). `best_effort` — 자리가 하나뿐이면 주 호출만(kick 없이도 답하는 wait 의 확인 — 숨은 탭에서 rAF 로 나타나는 요소를 늦게 볼
/// 뿐이다; 이동하는 순간에 잃은 kick 이 그 탭의 둘째 자리를 쥔 동안에도 확인이 멈추지 않게 — 적대 리뷰 3 회차).
/// `reserve`(W9a②) — kick 은 보내지 않되 `required` 처럼 두 자리가 다 비어 있을 때만 보낸다: executeScript 의 둘째 자리는 시한에 보낼
/// `Runtime.terminateExecution` 몫이다(자리가 없으면 멈추지 않는 스크립트를 끝낼 길이 없어 그 탭이 35 초 멈췄다 — 계획 공격 3 회차).
pub const Kick = enum {
    none,
    best_effort,
    required,
    reserve,

    /// 자리가 하나뿐이면 주 호출만 보내도 되는가.
    pub fn optional(self: Kick) bool {
        return self == .best_effort;
    }
};
