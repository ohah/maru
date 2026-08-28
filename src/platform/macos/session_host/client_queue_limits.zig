//! Dependency-neutral item-count limits shared by the blocking Client and response provenance.

pub const max_screen_items: usize = 4096;
pub const max_pending_events: usize = 4 * 256;
pub const max_recovery_streams: usize = 256;

/// The blocking frame reader returns or disposes one completed frame before parsing the next.
pub const max_observed_response_payloads: usize = 1;
