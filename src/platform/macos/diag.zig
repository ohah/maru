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

/// [진단 전용] `MARU_FT_SPLIT=N` — 첫 프레임 뒤 활성 pane 을 N 개가 되도록 가로 split 한다(각 pane 이 같은
/// `MARU_INTERACTIVE_SHELL` 페이로드를 돈다). 멀티 pane 이 tick 예산에 미치는 영향을 헤드리스로 재현하려는
/// 하네스 훅이다(present cadence §10.7). 미설정·비정수·1 이하면 0(아무것도 안 함). 상한 8.
var ft_split_cache: ?u8 = null;
pub fn ftSplitCount() u8 {
    if (ft_split_cache == null) {
        ft_split_cache = 0;
        if (std.c.getenv("MARU_FT_SPLIT")) |raw| {
            const n = std.fmt.parseInt(u8, std.mem.span(raw), 10) catch 0;
            ft_split_cache = if (n <= 1) 0 else @min(n, 8);
        }
    }
    return ft_split_cache.?;
}
