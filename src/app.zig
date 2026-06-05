pub const runtime = @import("app/runtime.zig");
pub const surface = @import("app/surface.zig");
pub const window = @import("app/window.zig");

pub const AppWindow = window.AppWindow;
pub const PtyId = runtime.PtyId;
pub const PtyIo = runtime.PtyIo;
pub const RestorableSurfaceMetadata = surface.RestorableSurfaceMetadata;
pub const RuntimeError = runtime.RuntimeError;
pub const RuntimeLink = runtime.RuntimeLink;
pub const RuntimePtyEvent = runtime.RuntimePtyEvent;
pub const Surface = surface.Surface;
pub const SurfaceId = runtime.SurfaceId;
pub const SurfaceRuntime = runtime.SurfaceRuntime;
pub const TerminalInput = runtime.TerminalInput;
pub const ProcessState = surface.ProcessState;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in app/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
