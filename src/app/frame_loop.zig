const std = @import("std");
const config_mod = @import("../config.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const host = @import("host.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("surface.zig");
const window_mod = @import("window.zig");

pub const default_artifact_dir = "zig-out/maru-app-loop-smoke";

pub const FrameLoop = struct {
    allocator: std.mem.Allocator,
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    pump: *runtime_pump.RuntimeEventPump,
    renderer_state: *renderer.RendererState,
    frame_index: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        app_window: *window_mod.AppWindow,
        runtime: *runtime_mod.SurfaceRuntime,
        pump: *runtime_pump.RuntimeEventPump,
        renderer_state: *renderer.RendererState,
    ) FrameLoop {
        return .{
            .allocator = allocator,
            .app_window = app_window,
            .runtime = runtime,
            .pump = pump,
            .renderer_state = renderer_state,
        };
    }

    pub fn tick(self: *FrameLoop, shaper: anytype) !FrameLoopTick {
        // 제품 window loop가 붙으면 매 display tick에서 이 순서가 반복된다.
        // 먼저 PTY queue를 non-blocking으로 비우고, 그 결과가 반영된 active surface만
        // renderer frame으로 만든다. 이 순서를 여기서 고정해야 native UI가
        // TerminalCore나 GlyphAtlas를 직접 만지지 않는다.
        const frame = try host.buildFrame(
            self.allocator,
            self.app_window,
            self.pump,
            self.renderer_state,
            shaper,
        );
        return self.finishTick(frame);
    }

    pub fn tickAfterDrain(
        self: *FrameLoop,
        drain_summary: runtime_pump.DrainSummary,
        shaper: anytype,
    ) !FrameLoopTick {
        // 일부 smoke는 queue event bytes를 artifact로 복사한 뒤 pump에 적용해야 한다.
        // 그런 경로도 frame 조립과 atlas state 관리는 같은 FrameLoop가 소유하도록
        // 이미 적용된 drain summary를 받아 frame만 만드는 진입점을 둔다.
        const frame = try host.buildFrameAfterDrain(
            self.allocator,
            self.app_window,
            self.renderer_state,
            shaper,
            drain_summary,
        );
        return self.finishTick(frame);
    }

    fn finishTick(self: *FrameLoop, frame: host.AppHostFrame) !FrameLoopTick {
        var owned_frame = frame;
        errdefer owned_frame.deinit(self.allocator);

        const index = self.frame_index;
        self.frame_index += 1;

        return .{
            .index = index,
            .frame = owned_frame,
            .render_stats = renderer.renderFrameStats(owned_frame.render_frame, self.renderer_state.atlas.entryCount()),
        };
    }

    pub fn handleKeyEvent(
        self: *FrameLoop,
        resolver: config_mod.KeyBindingResolver,
        event: terminal.KeyEvent,
    ) !host.KeyHandlingResult {
        // Platform code는 normalized event만 넘긴다. app-vs-terminal 판정은 기존
        // AppHost 정책을 그대로 쓰게 해서 smoke와 제품 loop가 다른 key 정책을 갖지 않게 한다.
        return host.handleKeyEvent(self.app_window, self.runtime, resolver, event);
    }

    pub fn resizeActiveSurface(self: *FrameLoop, size: terminal.Size) !void {
        // resize도 frame loop가 직접 storage를 고치는 대신 SurfaceRuntime action으로 보낸다.
        // 그래야 PTY resize와 TerminalCore resize가 한 경로에서 같이 일어난다.
        try host.resizeActiveSurface(self.app_window, self.runtime, size);
    }
};

pub const FrameLoopTick = struct {
    index: usize,
    frame: host.AppHostFrame,
    render_stats: renderer.RenderFrameStats,

    pub fn deinit(self: *FrameLoopTick, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
        self.* = undefined;
    }

    pub fn ended(self: FrameLoopTick) bool {
        return self.frame.drain_summary.ended != null;
    }
};

pub const FrameLoopSmokeConfig = struct {
    artifact_dir: []const u8 = default_artifact_dir,
    size: terminal.Size = .{ .cols = 32, .rows = 5 },
    first_output: []const u8 = "frame loop first\r\n",
    second_output: []const u8 = "frame loop second",
};

pub const FrameLoopSmokeResult = struct {
    summary: []u8,
    frames: []u8,
    screen: []u8,

    pub fn deinit(self: *FrameLoopSmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.frames);
        allocator.free(self.screen);
        self.* = undefined;
    }
};

pub fn runSmoke(
    io: std.Io,
    allocator: std.mem.Allocator,
    smoke_config: FrameLoopSmokeConfig,
) !FrameLoopSmokeResult {
    // 이 smoke는 아직 실제 AppKit window loop가 아니다. 대신 native loop가 호출하게 될
    // app-level tick 순서를 deterministic queue event로 먼저 고정한다.
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, smoke_config.size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "app frame loop smoke";
    surfaces[0].command = "memory-pty";

    var app_window: window_mod.AppWindow = .{ .tabs = &surfaces };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(io, allocator, 8);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    var loop = FrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state);
    var frame_log: std.Io.Writer.Allocating = .init(allocator);
    errdefer frame_log.deinit();
    try frame_log.writer.writeAll("maru.app-loop-frames.v1\n");

    try pushOutput(&queue, allocator, 10, smoke_config.first_output);
    var first = try loop.tick(renderer.FakeFontBackend{});
    defer first.deinit(allocator);
    try writeTick(&frame_log.writer, first);

    var idle = try loop.tick(renderer.FakeFontBackend{});
    defer idle.deinit(allocator);
    try writeTick(&frame_log.writer, idle);

    try pushOutput(&queue, allocator, 10, smoke_config.second_output);
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });
    var final = try loop.tick(renderer.FakeFontBackend{});
    defer final.deinit(allocator);
    try writeTick(&frame_log.writer, final);

    const screen = try surfaces[0].core.dumpUtf8(allocator);
    errdefer allocator.free(screen);
    const frames = try frame_log.toOwnedSlice();
    errdefer allocator.free(frames);
    const summary = try renderSummary(allocator, .{
        .config = smoke_config,
        .frame_ticks = loop.frame_index,
        .first = &first,
        .idle = &idle,
        .final = &final,
        .process_state = surfaces[0].process_state,
        .screen = screen,
        .terminal_writes = memory_pty.writes.items.len,
        .resize_calls = memory_pty.resize_calls,
    });
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, smoke_config.artifact_dir, .{
        .summary = summary,
        .frames = frames,
        .screen = screen,
    });

    return .{
        .summary = summary,
        .frames = frames,
        .screen = screen,
    };
}

fn pushOutput(
    queue: *pty_reader.PtyEventQueue,
    allocator: std.mem.Allocator,
    pty_id: runtime_mod.PtyId,
    bytes: []const u8,
) !void {
    const owned = try allocator.dupe(u8, bytes);
    // push 성공 뒤에는 queue가 bytes를 소유한다. 실패할 때만 producer가 해제해야
    // 이후 RuntimeEventPump의 event.deinit과 double-free가 나지 않는다.
    queue.pushBlocking(.{ .output = .{ .pty_id = pty_id, .bytes = owned } }) catch |err| {
        allocator.free(owned);
        return err;
    };
}

const SummaryInput = struct {
    config: FrameLoopSmokeConfig,
    frame_ticks: usize,
    first: *const FrameLoopTick,
    idle: *const FrameLoopTick,
    final: *const FrameLoopTick,
    process_state: surface_mod.ProcessState,
    screen: []const u8,
    terminal_writes: usize,
    resize_calls: usize,
};

fn renderSummary(allocator: std.mem.Allocator, input: SummaryInput) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.app-loop-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{input.config.artifact_dir});
    try writer.writeAll("visible_ui=false\n");
    try writer.writeAll("ui_note=headless_frame_loop_contract_before_appkit_event_loop\n");
    try writer.print("frame_ticks={d}\n", .{input.frame_ticks});
    try writer.print("frames_with_output={d}\n", .{countFramesWithOutput(input)});
    try writer.print("idle_frame_ticks={d}\n", .{countIdleFrames(input)});
    try writer.print("first_frame_prepared={}\n", .{input.first.render_stats.prepared()});
    try writer.print("idle_frame_prepared={}\n", .{input.idle.render_stats.prepared()});
    try writer.print("final_frame_prepared={}\n", .{input.final.render_stats.prepared()});
    try writer.print("final_frame_ended={}\n", .{input.final.ended()});
    try writer.print("process_state={s}\n", .{@tagName(input.process_state)});
    try writer.print("terminal_writes={d}\n", .{input.terminal_writes});
    try writer.print("resize_calls={d}\n", .{input.resize_calls});
    try writer.print("screen_contains_first={}\n", .{screenContainsOutput(input.screen, input.config.first_output)});
    try writer.print("screen_contains_second={}\n", .{screenContainsOutput(input.screen, input.config.second_output)});
    try renderer.writeRenderFrameStats(writer, "final_renderer_", input.final.render_stats);
    try writer.print("frames_artifact={s}/app-loop.frames.txt\n", .{input.config.artifact_dir});
    try writer.print("screen_artifact={s}/app-loop.screen.txt\n", .{input.config.artifact_dir});

    return output.toOwnedSlice();
}

fn countFramesWithOutput(input: SummaryInput) usize {
    var count: usize = 0;
    for ([_]*const FrameLoopTick{ input.first, input.idle, input.final }) |tick| {
        if (tick.frame.drain_summary.output_events > 0) count += 1;
    }
    return count;
}

fn countIdleFrames(input: SummaryInput) usize {
    var count: usize = 0;
    for ([_]*const FrameLoopTick{ input.first, input.idle, input.final }) |tick| {
        if (tick.frame.drain_summary.output_events == 0 and tick.frame.drain_summary.exit_events == 0) {
            count += 1;
        }
    }
    return count;
}

fn screenContainsOutput(screen: []const u8, output: []const u8) bool {
    // TerminalCore screen dump에는 제어문자 자체가 남지 않는다. smoke summary는
    // PTY byte-for-byte echo가 아니라 화면에 보이는 marker가 남았는지를 말해야 한다.
    const visible_marker = std.mem.trimEnd(u8, output, "\r\n");
    return visible_marker.len > 0 and std.mem.indexOf(u8, screen, visible_marker) != null;
}

fn writeTick(writer: *std.Io.Writer, tick: FrameLoopTick) !void {
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
    screen: []const u8,
};

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    artifacts: SmokeArtifacts,
) !void {
    try ensureDir(io, artifact_dir);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/app-loop.summary.txt", .{artifact_dir});
    defer allocator.free(summary_path);
    const frames_path = try std.fmt.allocPrint(allocator, "{s}/app-loop.frames.txt", .{artifact_dir});
    defer allocator.free(frames_path);
    const screen_path = try std.fmt.allocPrint(allocator, "{s}/app-loop.screen.txt", .{artifact_dir});
    defer allocator.free(screen_path);

    try writeText(io, summary_path, artifacts.summary);
    try writeText(io, frames_path, artifacts.frames);
    try writeTextWithFinalNewline(io, allocator, screen_path, artifacts.screen);
}

fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

fn writeTextWithFinalNewline(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
) !void {
    const text = try std.fmt.allocPrint(allocator, "{s}\n", .{contents});
    defer allocator.free(text);
    try writeText(io, path, text);
}

fn ensureDir(io: std.Io, dir: []const u8) !void {
    if (dir.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

const MemoryPty = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8) = .empty,
    resize_calls: usize = 0,
    last_size: ?terminal.Size = null,

    fn init(allocator: std.mem.Allocator) MemoryPty {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MemoryPty) void {
        self.writes.deinit(self.allocator);
    }

    fn io(self: *MemoryPty) runtime_mod.PtyIo {
        return .{
            .ctx = self,
            .write_input = writeInput,
            .resize_fn = resize,
        };
    }

    fn writeInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *MemoryPty = @ptrCast(@alignCast(ctx));
        try self.writes.appendSlice(self.allocator, bytes);
    }

    fn resize(ctx: *anyopaque, size: terminal.Size) !void {
        const self: *MemoryPty = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        self.last_size = size;
    }
};

test "app frame loop ticks keep building frames while the queue is empty or active" {
    // 이 테스트는 native window loop가 아직 없어도 tick API가 output/idle/exit frame을
    // 같은 state 위에서 계속 만들 수 있음을 증명한다. 실제 UI loop는 이 계약을 호출만 한다.
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 16, .rows = 3 })};
    defer surfaces[0].deinit();
    var app_window: window_mod.AppWindow = .{ .tabs = &surfaces };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 4);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var loop = FrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state);

    try pushOutput(&queue, allocator, 10, "first");
    var first = try loop.tick(renderer.FakeFontBackend{});
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), first.index);
    try std.testing.expectEqual(@as(usize, 1), first.frame.drain_summary.output_events);
    try std.testing.expect(first.render_stats.prepared());

    var idle = try loop.tick(renderer.FakeFontBackend{});
    defer idle.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), idle.index);
    try std.testing.expectEqual(@as(usize, 0), idle.frame.drain_summary.output_events);
    try std.testing.expect(idle.render_stats.prepared());

    try pushOutput(&queue, allocator, 10, "second");
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });
    var final = try loop.tick(renderer.FakeFontBackend{});
    defer final.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), final.index);
    try std.testing.expectEqual(@as(usize, 1), final.frame.drain_summary.output_events);
    try std.testing.expectEqual(@as(usize, 1), final.frame.drain_summary.exit_events);
    try std.testing.expect(final.ended());
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surfaces[0].process_state);
}

test "app frame loop routes key events through the same app host policy" {
    // keyboard input은 platform별 코드가 가장 쉽게 갈라지는 영역이다. frame loop가
    // 별도 정책을 만들지 않고 AppHost keybinding resolver를 그대로 쓰는지 고정한다.
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 16, .rows = 3 })};
    defer surfaces[0].deinit();
    var app_window: window_mod.AppWindow = .{ .tabs = &surfaces };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 4);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var loop = FrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state);

    const resolver: config_mod.KeyBindingResolver = .{
        .terminal_bindings = &.{.{
            .chord = try config_mod.KeyChord.parse("Cmd+B"),
            .input = .{ .send_text = "typed\n" },
        }},
    };
    try resolver.validate();

    const result = try loop.handleKeyEvent(resolver, .{
        .key = .{ .char = 'b' },
        .modifiers = .{ .command = true },
    });
    try std.testing.expectEqual(@as(usize, "typed\n".len), result.terminal_input.bytes_len);
    try std.testing.expectEqualStrings("typed\n", memory_pty.writes.items);
}

test "app frame loop smoke summary exposes multi-frame contract" {
    // smoke summary는 사람이 PR에서 보는 계약 문서다. output frame, idle frame,
    // termination frame이 모두 산출물에 남아야 다음 native loop PR의 기준점이 된다.
    var result = try runSmoke(std.testing.io, std.testing.allocator, .{
        .artifact_dir = "zig-out/test-app-loop-smoke",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.summary, "maru.app-loop-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "visible_ui=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "frame_ticks=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "frames_with_output=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "idle_frame_ticks=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "final_frame_ended=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "screen_contains_first=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "screen_contains_second=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.frames, "tick index=1 output_events=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.screen, "frame loop second") != null);
}
