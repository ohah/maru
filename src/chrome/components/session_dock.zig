//! Session Dock Chrome component facade.
//!
//! Domain data enters as `types.Props`; geometry/action projection lives in `build`, and semantic
//! paint/text emission lives in `view`. This facade intentionally has no AppSession/provider/Metal import.

pub const types = @import("session_dock/types.zig");
pub const ids = @import("session_dock/ids.zig");
pub const build = @import("session_dock/build.zig");
pub const view = @import("session_dock/view.zig");
