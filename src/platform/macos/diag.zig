const std = @import("std");

// MARU_DEBUG 진단 게이트의 단일 출처. coretext_raster(.font_metrics)와 app_session(.screen)
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

/// [실험 계측] 줄 끝 빈 셀 trim A/B 게이트. `MARU_FT_TRIM_BLANK`가 있으면 true.
/// renderer 의 `draw_list.experiment_trim_blank` 를 켜는 데만 쓴다 — 왜 실험인지는 그 선언의 주석이 단일 출처다.
var trim_blank_cache: ?bool = null;

pub fn trimBlankExperimentEnabled() bool {
    if (trim_blank_cache == null) {
        trim_blank_cache = std.c.getenv("MARU_FT_TRIM_BLANK") != null;
    }
    return trim_blank_cache.?;
}

/// [실험 계측] 이미지 픽셀 버퍼 재사용 A/B 게이트. `MARU_FT_REUSE_IMG`가 있으면 true.
var reuse_img_cache: ?bool = null;

pub fn reuseImagePixelsExperimentEnabled() bool {
    if (reuse_img_cache == null) {
        reuse_img_cache = std.c.getenv("MARU_FT_REUSE_IMG") != null;
    }
    return reuse_img_cache.?;
}
