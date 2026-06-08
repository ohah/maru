pub const artifact_io = @import("app/artifact_io.zig");
pub const headless_demo = @import("app/headless_demo.zig");
pub const frame_loop = @import("app/frame_loop.zig");
pub const host = @import("app/host.zig");
pub const live_pty = @import("app/live_pty.zig");
pub const live_pty_registry = @import("app/live_pty_registry.zig");
pub const pty_loop_smoke = @import("app/pty_loop_smoke.zig");
pub const pty_smoke = @import("app/pty_smoke.zig");
pub const pty_reader = @import("app/pty_reader.zig");
pub const runtime = @import("app/runtime.zig");
pub const runtime_pump = @import("app/runtime_pump.zig");
pub const smoke_drain = @import("app/smoke_drain.zig");
pub const surface = @import("app/surface.zig");
pub const window = @import("app/window.zig");

pub const AppWindow = window.AppWindow;
pub const AppHostFrame = host.AppHostFrame;
pub const AppHostError = host.HostError;
pub const AppFrameLoop = frame_loop.FrameLoop;
pub const AppFrameLoopSmokeConfig = frame_loop.FrameLoopSmokeConfig;
pub const AppFrameLoopSmokeResult = frame_loop.FrameLoopSmokeResult;
pub const AppFrameLoopTick = frame_loop.FrameLoopTick;
pub const AppPtyLoopSmokeConfig = pty_loop_smoke.AppPtyLoopSmokeConfig;
pub const AppPtyLoopSmokeResult = pty_loop_smoke.AppPtyLoopSmokeResult;
pub const KeyHandlingResult = host.KeyHandlingResult;
pub const LivePtyRegistry = live_pty_registry.LivePtyRegistry;
pub const LivePtyRegistryError = live_pty_registry.RegistryError;
pub const LivePtySession = live_pty.LivePtySession;
pub const AppPtySmokeConfig = pty_smoke.AppPtySmokeConfig;
pub const AppPtySmokeResult = pty_smoke.AppPtySmokeResult;
pub const AppSmokeConfig = host.AppSmokeConfig;
pub const AppSmokeResult = host.AppSmokeResult;
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
pub const SmokeDrainDeadlineConfig = smoke_drain.DeadlineConfig;
pub const Surface = surface.Surface;
pub const SurfaceId = runtime.SurfaceId;
pub const SurfaceRuntime = runtime.SurfaceRuntime;
pub const TerminalInput = runtime.TerminalInput;
pub const ProcessState = surface.ProcessState;

pub const buildAppHostFrame = host.buildFrame;
pub const buildAppHostFrameAfterDrain = host.buildFrameAfterDrain;
pub const closeActiveLivePty = host.closeActiveLivePty;
pub const handleKeyEvent = host.handleKeyEvent;
pub const resizeActiveSurface = host.resizeActiveSurface;
pub const runAppFrameLoopSmoke = frame_loop.runSmoke;
pub const runAppPtyLoopSmoke = pty_loop_smoke.run;
pub const runAppPtySmoke = pty_smoke.run;
pub const runAppSmoke = host.runSmoke;
pub const sendInputToActiveSurface = host.sendInputToActiveSurface;
pub const runHeadlessDemo = headless_demo.run;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in app/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
