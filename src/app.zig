pub const headless_demo = @import("app/headless_demo.zig");
pub const pty_reader = @import("app/pty_reader.zig");
pub const runtime = @import("app/runtime.zig");
pub const runtime_pump = @import("app/runtime_pump.zig");
pub const surface = @import("app/surface.zig");
pub const window = @import("app/window.zig");

pub const AppWindow = window.AppWindow;
pub const HeadlessDemoConfig = headless_demo.DemoConfig;
pub const HeadlessDemoResult = headless_demo.DemoResult;
pub const PtyEventQueue = pty_reader.PtyEventQueue;
pub const PtyId = runtime.PtyId;
pub const PtyIo = runtime.PtyIo;
pub const PtyReader = pty_reader.PtyReader;
pub const QueuedPtyEvent = pty_reader.QueuedPtyEvent;
pub const QueueError = pty_reader.QueueError;
pub const RestorableSurfaceMetadata = surface.RestorableSurfaceMetadata;
pub const RuntimeError = runtime.RuntimeError;
pub const RuntimeEventPump = runtime_pump.RuntimeEventPump;
pub const RuntimeLink = runtime.RuntimeLink;
pub const RuntimePtyEvent = runtime.RuntimePtyEvent;
pub const RuntimePumpError = runtime_pump.PumpError;
pub const RuntimePumpDrainSummary = runtime_pump.DrainSummary;
pub const RuntimePumpTermination = runtime_pump.Termination;
pub const RuntimePumpedEvent = runtime_pump.PumpedEvent;
pub const RuntimePumpedEventKind = runtime_pump.PumpedEventKind;
pub const Surface = surface.Surface;
pub const SurfaceId = runtime.SurfaceId;
pub const SurfaceRuntime = runtime.SurfaceRuntime;
pub const TerminalInput = runtime.TerminalInput;
pub const ProcessState = surface.ProcessState;

pub const runHeadlessDemo = headless_demo.run;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in app/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
