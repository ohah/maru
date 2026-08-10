//! One-way facade from RemoteRuntime's dormant generation-event path into immutable preparation.
//!
//! Runtime owns the final-address frame. This module neither copies its context nor imports
//! RemoteRuntime, so preparation policy and ownership cannot acquire a reverse dependency.

const preparation = @import("pending_event_preparation.zig");

pub const PrepareError = preparation.PrepareError;

pub fn prepareTakenEvent(frame: *preparation.PreparationFrame) PrepareError!void {
    return preparation.prepare(frame);
}

// Keep the non-test facade instantiated even while the normal product pump caller remains zero.
comptime {
    _ = @TypeOf(prepareTakenEvent);
}
