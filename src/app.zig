pub const surface = @import("app/surface.zig");
pub const window = @import("app/window.zig");

pub const AppWindow = window.AppWindow;
pub const Surface = surface.Surface;
pub const ProcessState = surface.ProcessState;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in app/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
