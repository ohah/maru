//! Process-global reconnect admission policy constants.
//!
//! Queue ownership, active resident work, and resident bytes are distinct limits.
//! The queue owner and resident budget import this module instead of deriving policy
//! from an implementation inventory that happens to have the same size.

pub const max_queued_admissions: usize = 64;
pub const max_active_resident_entries: usize = 8;
pub const max_resident_bytes: usize = 128 * 1024 * 1024;

comptime {
    if (max_queued_admissions == 0 or max_active_resident_entries == 0 or
        max_active_resident_entries > max_queued_admissions or max_resident_bytes == 0)
        @compileError("invalid reconnect admission policy");
}
