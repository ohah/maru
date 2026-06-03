pub const types = @import("pty/types.zig");

pub const Backend = types.Backend;
pub const PtyHandle = types.PtyHandle;
pub const SpawnRequest = types.SpawnRequest;
pub const plannedBackendForMacOS = types.plannedBackendForMacOS;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in pty/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
