pub const app_runtime = @import("app/app_runtime.zig");
pub const workspace_checkpoint_product = @import("app/workspace_checkpoint_product.zig");
pub const artifact_io = @import("app/artifact_io.zig");
pub const headless_demo = @import("app/headless_demo.zig");
/// 데모·스모크 fixture 명령의 OS 갈래(단일 출처). 배럴에 걸어야 그 테스트가 모든 타깃에서 돈다.
pub const fixture_script = @import("app/fixture_script.zig");
pub const frame_loop = @import("app/frame_loop.zig");
pub const host = @import("app/host.zig");
pub const label = @import("app/label.zig");
pub const live_pty = @import("app/live_pty.zig");
pub const live_pty_registry = @import("app/live_pty_registry.zig");
pub const pty_loop_smoke = @import("app/pty_loop_smoke.zig");
pub const pty_smoke = @import("app/pty_smoke.zig");
pub const pty_reader = @import("app/pty_reader.zig");
/// sync(2026) 프레임 경계 자르기. **배럴에 건다** — 리더가 쓰는 순수 판정이라 모든 타깃에서 돌아야 한다.
pub const sync_frame_split = @import("app/sync_frame_split.zig");
pub const runtime = @import("app/runtime.zig");
pub const runtime_pump = @import("app/runtime_pump.zig");
pub const input_owner = @import("app/input_owner.zig");
pub const event_cursor = @import("app/event_cursor.zig");
pub const term_runtime_backend = @import("app/term_runtime_backend.zig");
pub const in_process_term_backend = @import("app/in_process_term_backend.zig");
pub const trace_recorder = @import("app/trace_recorder.zig");
pub const smoke_drain = @import("app/smoke_drain.zig");
pub const shutdown_wire_contract = @import("shutdown_wire_contract.zig");

pub const AppRuntime = app_runtime.AppRuntime;
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
pub const LiveSurface = live_pty.LiveSurface;
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
pub const PtyWriteQueue = pty_reader.PtyWriteQueue;
pub const CoreCommand = pty_reader.CoreCommand;
pub const CoreCommandQueue = pty_reader.CoreCommandQueue;
pub const QueuedPtyEvent = pty_reader.QueuedPtyEvent;
pub const QueueError = pty_reader.QueueError;
pub const RuntimeError = runtime.RuntimeError;
pub const RuntimeEventPump = runtime_pump.RuntimeEventPump;
pub const RuntimeLink = runtime.RuntimeLink;
pub const RuntimePtyEvent = runtime.RuntimePtyEvent;
pub const RuntimePumpError = runtime_pump.PumpError;
pub const RuntimePumpDrainSummary = runtime_pump.DrainSummary;
pub const RuntimePumpTermination = runtime_pump.Termination;
pub const RuntimePumpedEvent = runtime_pump.PumpedEvent;
pub const RuntimePumpedEventKind = runtime_pump.PumpedEventKind;
pub const InputOwner = input_owner.InputOwner;
pub const InputOwnerVTable = input_owner.VTable;
pub const EventCursor = event_cursor.EventCursor;
pub const TermRuntimeBackend = term_runtime_backend.TermRuntimeBackend;
pub const TermRuntimeBackendVTable = term_runtime_backend.VTable;
pub const TermRuntimeHandle = term_runtime_backend.RuntimeHandle;
pub const TermRuntimeSpawnParams = term_runtime_backend.SpawnParams;
pub const RuntimeObservation = term_runtime_backend.RuntimeObservation;
pub const RuntimeObservationView = term_runtime_backend.RuntimeObservationView;
pub const ObservationAvailability = term_runtime_backend.ObservationAvailability;
pub const InProcessTermBackend = in_process_term_backend.InProcessTermBackend;
pub const SmokeDrainDeadlineConfig = smoke_drain.DeadlineConfig;
pub const SurfaceId = runtime.SurfaceId;
pub const SurfaceRuntime = runtime.SurfaceRuntime;
pub const TerminalInput = runtime.TerminalInput;

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
pub const pickLabel = label.pick;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in app/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
