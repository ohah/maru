//! 소스 컨트롤 도크 Chrome component facade.
//!
//! domain 데이터는 `types.Props`로 들어오고, geometry/action 투영은 `build`, semantic paint/text 방출은
//! `view`가 소유한다. 이 facade는 의도적으로 AppSession·git·Metal을 import하지 않는다.

pub const types = @import("scm_dock/types.zig");
pub const ids = @import("scm_dock/ids.zig");
pub const build = @import("scm_dock/build.zig");
pub const view = @import("scm_dock/view.zig");
/// 스크롤 투영 — 높이 규칙은 `types.DockMetrics.itemHeight` 가 소유하고 여기서는 감싸기만 한다.
pub const scroll = @import("scm_dock/scroll.zig");

test {
    // 자식 파일의 테스트를 빌드에 집계한다(chrome.zig와 같은 관용구 — `refAllDecls`는 한 단계라
    // facade만 ref하면 자식 테스트가 실행되지 않는다).
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
}
