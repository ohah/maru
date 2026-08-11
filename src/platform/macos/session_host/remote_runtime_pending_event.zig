//! One-way facade from RemoteRuntime's dormant generation-event path into immutable preparation.
//!
//! Runtime owns the final-address frame. This module neither copies its context nor imports
//! RemoteRuntime, so preparation policy and ownership cannot acquire a reverse dependency.

const preparation = @import("pending_event_preparation.zig");
const settlement = @import("pending_event_settlement.zig");
const lifetime = @import("runtime_lifetime_owner.zig");
const pending_owner = @import("pending_event_owner.zig");
const attachment = @import("generation_attachment.zig");
const transport = @import("generation_transport.zig");
const prepared_types = @import("runtime_event_prepared_types.zig");

pub const PrepareError = preparation.PrepareError;

pub fn prepareTakenEvent(frame: *preparation.PreparationFrame) PrepareError!void {
    return preparation.prepare(frame);
}

/// RemoteRuntime이 소유한 exact inline owner만 b3 coordinator에 전달하는 sole 제품 adapter다.
pub fn settlePreparedEvent(
    lifetime_owner: *lifetime.RuntimeLifetimeOwner,
    owner: *pending_owner.PendingEventOwner,
    generation: *attachment.GenerationAttachment,
    correlation: transport.EventCorrelation,
    effect: prepared_types.EffectRequest,
) error{ Busy, InvalidOwner }!void {
    return settlement.settlePendingEvent(lifetime_owner, owner, generation, correlation, effect);
}

// Keep the non-test facade instantiated even while the normal product pump caller remains zero.
comptime {
    _ = @TypeOf(prepareTakenEvent);
    _ = @TypeOf(settlePreparedEvent);
}
