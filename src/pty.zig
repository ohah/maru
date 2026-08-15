pub const types = @import("pty/types.zig");
pub const session = @import("pty/session.zig");

pub const Backend = types.Backend;
pub const ExitStatus = types.ExitStatus;
pub const PtyEvent = types.PtyEvent;
pub const PtyHandle = types.PtyHandle;
pub const PtySession = session.PtySession;
pub const backend_available = session.backend_available;
pub const SpawnRequest = types.SpawnRequest;
pub const plannedBackendForMacOS = types.plannedBackendForMacOS;
pub const resolveInteractiveShell = types.resolveInteractiveShell;
pub const selfResourceSample = session.selfResourceSample;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in pty/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
