//! Session Dock Chrome component의 facade다.
//!
//! 도메인 데이터는 `types.Props`로 들어오고, geometry/action 투영은 `build`가, semantic paint/text
//! emission은 `view`가 소유한다. 이 facade에는 AppSession/provider/Metal import를 의도적으로 두지 않는다.

pub const types = @import("session_dock/types.zig");
pub const ids = @import("session_dock/ids.zig");
pub const build = @import("session_dock/build.zig");
pub const view = @import("session_dock/view.zig");
/// 항목 높이 규칙과 스크롤 투영 — `build` 가 노드를 놓는 높이와 **같은 값**을 낸다.
pub const scroll = @import("session_dock/scroll.zig");
