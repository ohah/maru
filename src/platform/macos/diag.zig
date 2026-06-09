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
