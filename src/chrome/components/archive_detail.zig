//! Archive session detail panel Chrome component facade.
//!
//! The panel receives only an already-redacted presentation DTO. It deliberately has no archive
//! parser, AppSession, PTY, provider executable, filesystem, or Metal import; the platform host
//! resolves its opaque actions only in the later AS4-b integration slice.

pub const types = @import("archive_detail/types.zig");
pub const ids = @import("archive_detail/ids.zig");
pub const build = @import("archive_detail/build.zig");
pub const view = @import("archive_detail/view.zig");
