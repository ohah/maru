const std = @import("std");

// MARU_DEBUG 진단 게이트의 단일 출처. coretext_raster(.font_metrics)와 app_dev_session(.screen)
// 같은 여러 진단 site가 같은 env 이름과 read-once 캐시 정책을 쓰도록 한 곳에 모은다. 환경변수는
// 프로세스 수명 동안 안 바뀌므로 한 번만 조회해 캐시한다(libc getenv, no-alloc).
var enabled_cache: ?bool = null;

/// MARU_DEBUG가 설정돼 있으면 true. 미설정 시 비용은 분기 하나(캐시 히트).
pub fn maruDebugEnabled() bool {
    if (enabled_cache == null) {
        enabled_cache = std.c.getenv("MARU_DEBUG") != null;
    }
    return enabled_cache.?;
}

var no_synth_cache: ?bool = null;

/// MARU_NO_SYNTH가 설정돼 있으면 true 1 — box/block 글리프 합성을 끄고 폰트 글리프 경로로 되돌린다.
/// 클로드 로고(block elements) 색이 합성 후 흰색으로 바뀐 회귀를 같은 빌드에서 A/B로 격리하기 위한
/// 런타임 토글(머지해야 테스트 가능한 사용자 환경에서 폰트 경로 vs 합성 경로를 한 번에 비교).
pub fn maruNoSynthEnabled() bool {
    if (no_synth_cache == null) {
        no_synth_cache = std.c.getenv("MARU_NO_SYNTH") != null;
    }
    return no_synth_cache.?;
}
