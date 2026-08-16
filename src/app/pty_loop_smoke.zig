const std = @import("std");
const config_mod = @import("../config.zig");
const observability = @import("../observability.zig");
const pty = @import("../pty.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const frame_loop_mod = @import("frame_loop.zig");
const live_pty_mod = @import("live_pty.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const artifact_io = @import("artifact_io.zig");
const fixture_script = @import("fixture_script.zig");
const smoke_drain = @import("smoke_drain.zig");
const surface_mod = @import("../session/surface.zig");
const window_mod = @import("../session/window.zig");

pub const default_artifact_dir = "zig-out/maru-app-pty-loop-smoke";
pub const default_interactive_artifact_dir = "zig-out/maru-app-pty-interactive-loop-smoke";

/// 두 줄 사이에 **짧은 지연**을 둔다 — 출력이 한 이벤트로 뭉치면 이 스모크가 재려는 "프레임이 이벤트를
/// 따라간다"가 검증되지 않는다. 지연 수단은 OS로 갈리고 그 규칙은 [fixture_script.zig](fixture_script.zig)에 있다.
const host_command = fixture_script.oneShot(
    @import("builtin").os.tag,
    "printf 'Maru PTY loop first\\r\\n'; " ++ fixture_script.posix_short_sleep ++ "; printf 'Maru PTY loop second\\r\\n'",
    "echo Maru PTY loop first& " ++ fixture_script.windows_short_sleep ++ "& echo Maru PTY loop second",
);

pub const AppPtyLoopSmokeConfig = struct {
    artifact_dir: []const u8 = default_artifact_dir,
    size: terminal.Size = .{ .cols = 40, .rows = 6 },
    command: []const u8 = host_command.command,
    args: []const []const u8 = host_command.args,
    expected_text: []const u8 = "Maru PTY loop second",
    max_event_frames: usize = 16,
    drain_timeout_ms: i64 = smoke_drain.default_timeout_ms,
    interactive_shell: bool = false,
    scripted_key_chord: []const u8 = "Cmd+I",
    scripted_input: []const u8 = "",
};

pub const AppPtyLoopSmokeResult = struct {
    summary: []u8,
    frames: []u8,
    raw: []u8,
    screen: []u8,
    snapshot: []u8,

    pub fn deinit(self: *AppPtyLoopSmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.frames);
        allocator.free(self.raw);
        allocator.free(self.screen);
        allocator.free(self.snapshot);
        self.* = undefined;
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    smoke_config: AppPtyLoopSmokeConfig,
) !AppPtyLoopSmokeResult {
    // 이 smoke는 실제 macOS PTY reader thread와 FrameLoop를 같이 태운다.
    // 아직 AppKit event loop는 아니지만, UI main loop가 할 일을 headless로 반복한다.
    var live_pty: live_pty_mod.LivePtySession = undefined;
    try live_pty.init(io, allocator, 10, .{
        .command = smoke_config.command,
        .args = smoke_config.args,
        .size = smoke_config.size,
    }, 16);
    defer live_pty.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, smoke_config.size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "app pty loop smoke";
    surfaces[0].command = smoke_config.command;

    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try live_pty.attachSurface(&runtime, &surfaces[0], false); // controlled smoke — 리더 처리 끔(큐-드레인)

    var pump = live_pty.pump(&runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    // io: frame 조립 코어 락(docs/io-render-threading.md PR3). live_pty.pump의 queue.io에 기대지 않고 valid한 io를 직접 넘긴다.
    var frame_loop = frame_loop_mod.FrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state, io);

    const scripted_input = try sendScriptedInputIfConfigured(&frame_loop, smoke_config);

    var raw_bytes: std.ArrayList(u8) = .empty;
    errdefer raw_bytes.deinit(allocator);
    var frame_log: std.Io.Writer.Allocating = .init(allocator);
    errdefer frame_log.deinit();
    try frame_log.writer.writeAll("maru.app-pty-loop-frames.v1\n");

    var counts: LoopCounts = .{};
    while (counts.event_frames < smoke_config.max_event_frames) {
        const drain_summary = try drainOneBatchWithRaw(
            io,
            allocator,
            live_pty.eventQueue(),
            &pump,
            &raw_bytes,
            smoke_config.drain_timeout_ms,
        );
        counts.recordDrain(drain_summary);

        var event_tick = try frame_loop.tickAfterDrain(drain_summary, renderer.FakeFontBackend{});
        defer event_tick.deinit(allocator);
        try writeTick(&frame_log.writer, event_tick);
        counts.recordTick(event_tick);

        if (!counts.inserted_idle_probe) {
            // 실제 app loop는 PTY event가 없을 때도 frame을 만들 수 있어야 한다.
            // 첫 event 뒤에 빈 queue tick을 강제로 넣어 idle frame 계약을 산출물에 남긴다.
            var idle_tick = try frame_loop.tick(renderer.FakeFontBackend{});
            defer idle_tick.deinit(allocator);
            try writeTick(&frame_log.writer, idle_tick);
            counts.recordTick(idle_tick);
            counts.inserted_idle_probe = true;
        }

        if (event_tick.ended()) break;
    } else {
        return error.AppPtyLoopSmokeExceededMaxFrames;
    }

    live_pty.finishAfterTermination();

    const raw = try raw_bytes.toOwnedSlice(allocator);
    errdefer allocator.free(raw);
    const frames = try frame_log.toOwnedSlice();
    errdefer allocator.free(frames);
    const screen = try surfaces[0].core.dumpUtf8(allocator);
    errdefer allocator.free(screen);
    const snapshot = try observability.snapshot.renderTerminalSnapshot(allocator, surfaces[0].core.snapshot());
    errdefer allocator.free(snapshot);
    const summary = try renderSummary(allocator, .{
        .config = smoke_config,
        .counts = counts,
        .frame_ticks = frame_loop.frame_index,
        .process_state = surfaces[0].process_state,
        .screen_contains_expected = std.mem.indexOf(u8, screen, smoke_config.expected_text) != null,
        .raw_bytes_len = raw.len,
        .scripted_input = scripted_input,
    });
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, smoke_config.artifact_dir, .{
        .summary = summary,
        .frames = frames,
        .raw = raw,
        .screen = screen,
        .snapshot = snapshot,
    });

    return .{
        .summary = summary,
        .frames = frames,
        .raw = raw,
        .screen = screen,
        .snapshot = snapshot,
    };
}

const LoopCounts = struct {
    event_frames: usize = 0,
    idle_frames: usize = 0,
    output_events: usize = 0,
    exit_events: usize = 0,
    inserted_idle_probe: bool = false,
    termination: ?runtime_pump.Termination = null,

    fn recordDrain(self: *LoopCounts, drain_summary: runtime_pump.DrainSummary) void {
        self.event_frames += 1;
        self.output_events += drain_summary.output_events;
        self.exit_events += drain_summary.exit_events;
        if (self.termination == null) self.termination = drain_summary.ended;
    }

    fn recordTick(self: *LoopCounts, tick: frame_loop_mod.FrameLoopTick) void {
        if (tick.frame.drain_summary.output_events == 0 and tick.frame.drain_summary.exit_events == 0) {
            self.idle_frames += 1;
        }
    }
};

fn drainOneBatchWithRaw(
    io: std.Io,
    allocator: std.mem.Allocator,
    queue: *pty_reader.PtyEventQueue,
    pump: *runtime_pump.RuntimeEventPump,
    raw_bytes: *std.ArrayList(u8),
    timeout_ms: i64,
) !runtime_pump.DrainSummary {
    // deadline으로 최소 event 하나를 기다린 뒤, 이미 쌓인 event는 같은 frame에 묶는다.
    // smoke가 멈춰도 실패 원인을 남겨야 하므로 제품용 blocking queue를 그대로 쓰지 않는다.
    // raw artifact는 applyQueuedEvent가 output bytes를 해제하기 전에 복사해야 한다.
    var summary: runtime_pump.DrainSummary = .{};
    const first = try smoke_drain.popWithDeadline(io, queue, .{ .timeout_ms = timeout_ms });
    try applyEventWithRaw(allocator, pump, raw_bytes, first, &summary);
    while (queue.tryPop()) |event| {
        try applyEventWithRaw(allocator, pump, raw_bytes, event, &summary);
    }
    return summary;
}

fn applyEventWithRaw(
    allocator: std.mem.Allocator,
    pump: *runtime_pump.RuntimeEventPump,
    raw_bytes: *std.ArrayList(u8),
    event: pty_reader.QueuedPtyEvent,
    summary: *runtime_pump.DrainSummary,
) !void {
    if (event == .output) {
        try raw_bytes.appendSlice(allocator, event.output.bytes);
    }
    const pumped = try pump.applyQueuedEvent(event);
    summary.recordPumpedEvent(pumped);
}

const SummaryInput = struct {
    config: AppPtyLoopSmokeConfig,
    counts: LoopCounts,
    frame_ticks: usize,
    process_state: surface_mod.ProcessState,
    screen_contains_expected: bool,
    raw_bytes_len: usize,
    scripted_input: ScriptedInputProbe,
};

fn renderSummary(allocator: std.mem.Allocator, input: SummaryInput) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.app-pty-loop-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{input.config.artifact_dir});
    try writer.writeAll("visible_ui=false\n");
    try writer.writeAll("ui_note=real_pty_reader_repeated_frame_loop_without_appkit_window\n");
    try writer.writeAll("renderer_input=surface_runtime_live_pty_frame_loop\n");
    try writer.writeAll("renderer_shaper=fake_font_backend\n");
    try writer.print("interactive_shell={}\n", .{input.config.interactive_shell});
    try writer.print("command={s}\n", .{input.config.command});
    try writer.print("args.len={d}\n", .{input.config.args.len});
    try writer.print("drain_timeout_ms={d}\n", .{input.config.drain_timeout_ms});
    try writer.print("scripted_key_event_sent={}\n", .{input.scripted_input.sent});
    try writer.print("scripted_key_event_result={s}\n", .{input.scripted_input.result});
    try writer.print("scripted_terminal_input_bytes={d}\n", .{input.scripted_input.terminal_input_bytes_len});
    try writer.print("size.cols={d}\n", .{input.config.size.cols});
    try writer.print("size.rows={d}\n", .{input.config.size.rows});
    try writer.print("frame_ticks={d}\n", .{input.frame_ticks});
    try writer.print("event_frame_ticks={d}\n", .{input.counts.event_frames});
    try writer.print("idle_frame_ticks={d}\n", .{input.counts.idle_frames});
    try writer.print("output_events={d}\n", .{input.counts.output_events});
    try writer.print("exit_events={d}\n", .{input.counts.exit_events});
    try writer.print("process_state={s}\n", .{@tagName(input.process_state)});
    try writer.writeAll("termination=");
    try writeTermination(writer, input.counts.termination);
    try writer.writeByte('\n');
    try writer.print("raw_bytes={d}\n", .{input.raw_bytes_len});
    try writer.print("screen_contains_expected={}\n", .{input.screen_contains_expected});
    try writer.print("frames_artifact={s}/app-pty-loop.frames.txt\n", .{input.config.artifact_dir});
    try writer.print("raw_artifact={s}/app-pty-loop.raw.txt\n", .{input.config.artifact_dir});
    try writer.print("screen_artifact={s}/app-pty-loop.screen.txt\n", .{input.config.artifact_dir});
    try writer.print("snapshot_artifact={s}/app-pty-loop.snapshot.txt\n", .{input.config.artifact_dir});

    return output.toOwnedSlice();
}

const ScriptedInputProbe = struct {
    sent: bool = false,
    result: []const u8 = "none",
    terminal_input_bytes_len: usize = 0,
};

fn sendScriptedInputIfConfigured(
    frame_loop: *frame_loop_mod.FrameLoop,
    smoke_config: AppPtyLoopSmokeConfig,
) !ScriptedInputProbe {
    if (smoke_config.scripted_input.len == 0) return .{};

    const chord = try config_mod.KeyChord.parse(smoke_config.scripted_key_chord);
    const resolver: config_mod.KeyBindingResolver = .{
        .terminal_bindings = &.{.{
            .chord = chord,
            .input = .{ .send_text = smoke_config.scripted_input },
        }},
    };
    try resolver.validate();

    // 이 synthetic event는 OS native key capture를 흉내 내려는 것이 아니다.
    // 목적은 app frame loop가 이미 가진 keybinding resolver 경계로 terminal bytes를
    // 쓰는지 고정하는 것이다. 실제 AppKit keyDown payload는 visible Metal smoke가 맡는다.
    const key_event = try keyEventFromChord(chord);
    const key_result = try frame_loop.handleKeyEvent(resolver, key_event, true, null);
    return switch (key_result) {
        .terminal_input => |terminal_input| .{
            .sent = true,
            .result = @tagName(key_result),
            .terminal_input_bytes_len = terminal_input.bytes_len,
        },
        .app_action, .ignored => .{
            .sent = false,
            .result = @tagName(key_result),
        },
    };
}

fn keyEventFromChord(chord: config_mod.KeyChord) !terminal.KeyEvent {
    return .{
        .key = switch (chord.key) {
            .char => |codepoint| .{ .char = codepoint },
            .enter => .enter,
            .escape => .escape,
            .tab => .tab,
            .backspace => .backspace,
            .delete => .delete,
            .insert => .insert,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .arrow_up => .arrow_up,
            .arrow_down => .arrow_down,
            .arrow_left => .arrow_left,
            .arrow_right => .arrow_right,
            .function => |n| .{ .function = n },
        },
        .modifiers = chord.modifiers,
    };
}

fn writeTick(writer: *std.Io.Writer, tick: frame_loop_mod.FrameLoopTick) !void {
    try writer.print(
        "tick index={d} output_events={d} exit_events={d} ended={} prepared={} draw_cells={d} glyphs={d} atlas_entries={d}\n",
        .{
            tick.index,
            tick.frame.drain_summary.output_events,
            tick.frame.drain_summary.exit_events,
            tick.ended(),
            tick.render_stats.prepared(),
            tick.render_stats.draw_cells,
            tick.render_stats.glyph_count,
            tick.render_stats.atlas_entries,
        },
    );
}

const SmokeArtifacts = struct {
    summary: []const u8,
    frames: []const u8,
    raw: []const u8,
    screen: []const u8,
    snapshot: []const u8,
};

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    artifacts: SmokeArtifacts,
) !void {
    try ensureDir(io, artifact_dir);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/app-pty-loop.summary.txt", .{artifact_dir});
    defer allocator.free(summary_path);
    const frames_path = try std.fmt.allocPrint(allocator, "{s}/app-pty-loop.frames.txt", .{artifact_dir});
    defer allocator.free(frames_path);
    const raw_path = try std.fmt.allocPrint(allocator, "{s}/app-pty-loop.raw.txt", .{artifact_dir});
    defer allocator.free(raw_path);
    const screen_path = try std.fmt.allocPrint(allocator, "{s}/app-pty-loop.screen.txt", .{artifact_dir});
    defer allocator.free(screen_path);
    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/app-pty-loop.snapshot.txt", .{artifact_dir});
    defer allocator.free(snapshot_path);

    try writeText(io, summary_path, artifacts.summary);
    try writeText(io, frames_path, artifacts.frames);
    try writeText(io, raw_path, artifacts.raw);
    try writeTextWithFinalNewline(io, allocator, screen_path, artifacts.screen);
    try writeText(io, snapshot_path, artifacts.snapshot);
}

const writeTermination = runtime_pump.writeTermination;
const writeExitStatus = runtime_pump.writeExitStatus;
const writeText = artifact_io.writeText;
const writeTextWithFinalNewline = artifact_io.writeTextWithFinalNewline;
const ensureDir = artifact_io.ensureDir;

const FakePty = struct {
    written: [128]u8 = undefined,
    written_len: usize = 0,

    fn io(self: *FakePty) runtime_mod.PtyIo {
        return .{
            .ctx = self,
            .write_input = writeInput,
            .resize_fn = resize,
        };
    }

    fn writeInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        if (self.written_len + bytes.len > self.written.len) return error.FakePtyWriteTooLarge;
        @memcpy(self.written[self.written_len..][0..bytes.len], bytes);
        self.written_len += bytes.len;
    }

    fn resize(ctx: *anyopaque, size: terminal.Size) !void {
        _ = ctx;
        _ = size;
    }
};

test "app PTY loop batch drain copies raw bytes before pump ownership ends" {
    // 실제 PTY reader가 넘긴 output bytes는 pump가 해제한다. loop smoke가 raw artifact를
    // 남기려면 그 전에 복사해야 하므로, 이 테스트가 ownership 순서를 고정한다.
    const allocator = std.testing.allocator;
    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surface, 10, fake_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    const bytes = try allocator.dupe(u8, "loop raw");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });

    const summary = try drainOneBatchWithRaw(
        std.testing.io,
        allocator,
        &queue,
        &pump,
        &raw,
        smoke_drain.default_timeout_ms,
    );
    try std.testing.expectEqual(@as(usize, 1), summary.output_events);
    try std.testing.expectEqual(@as(usize, 1), summary.exit_events);
    try std.testing.expectEqualStrings("loop raw", raw.items);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
}

test "app PTY loop drain reports a smoke timeout instead of hanging forever" {
    // shell startup이나 reader thread가 멈추면 smoke가 CI를 붙잡으면 안 된다.
    // 첫 event가 오지 않는 queue에서 deadline error가 나오는지 고정한다.
    const allocator = std.testing.allocator;
    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surface, 10, fake_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    try std.testing.expectError(
        error.SmokeDrainTimedOut,
        drainOneBatchWithRaw(std.testing.io, allocator, &queue, &pump, &raw, 1),
    );
}

test "app PTY loop scripted input goes through FrameLoop keybinding boundary" {
    // interactive shell smoke는 직접 PtySession.writeInput을 부르지 않는다. app host가
    // 실제로 사용할 FrameLoop.handleKeyEvent 경계를 지나야, shortcut 정책과 terminal
    // input 정책이 제품 loop와 smoke에서 갈라지지 않는다.
    const allocator = std.testing.allocator;
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 })};
    defer surfaces[0].deinit();
    var fake_pty: FakePty = .{};
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, fake_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };
    var frame_loop = frame_loop_mod.FrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state, pump.queue.io);

    const input = "printf smoke\nexit\n";
    const probe = try sendScriptedInputIfConfigured(&frame_loop, .{
        .scripted_input = input,
        .scripted_key_chord = "Cmd+I",
    });

    try std.testing.expect(probe.sent);
    try std.testing.expectEqualStrings("terminal_input", probe.result);
    try std.testing.expectEqual(input.len, probe.terminal_input_bytes_len);
    try std.testing.expectEqualStrings(input, fake_pty.written[0..fake_pty.written_len]);
}

test "app PTY loop summary records repeated event and idle frame contract" {
    // summary는 PR에서 사람이 보는 계약이다. 실제 UI가 아니며, event frame과 idle frame이
    // 둘 다 존재한다는 사실을 명확히 남겨야 다음 AppKit loop PR의 기준점이 된다.
    const summary = try renderSummary(std.testing.allocator, .{
        .config = .{ .artifact_dir = "zig-out/test-app-pty-loop-smoke", .size = .{ .cols = 12, .rows = 3 } },
        .counts = .{
            .event_frames = 2,
            .idle_frames = 1,
            .output_events = 2,
            .exit_events = 1,
            .inserted_idle_probe = true,
            .termination = .{ .exited = .{ .exited = 0 } },
        },
        .frame_ticks = 3,
        .process_state = .exited,
        .screen_contains_expected = true,
        .raw_bytes_len = 40,
        .scripted_input = .{},
    });
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.app-pty-loop-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=surface_runtime_live_pty_frame_loop\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "interactive_shell=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drain_timeout_ms=5000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "scripted_key_event_sent=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "scripted_key_event_result=none\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "frame_ticks=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "event_frame_ticks=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "idle_frame_ticks=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "termination=exited(code=0)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screen_contains_expected=true\n") != null);
}
