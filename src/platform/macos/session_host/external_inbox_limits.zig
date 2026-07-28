//! Pure fixed limits shared by external inbox accounting and source decision.

const protocol = @import("protocol.zig");

pub const max_bytes: usize = protocol.max_client_screen_inbox;
pub const max_items: usize = protocol.max_client_screen_items;
