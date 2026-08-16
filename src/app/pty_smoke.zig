const std = @import("std");
const observability = @import("../observability.zig");
const pty = @import("../pty.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const host = @import("host.zig");
const live_pty_mod = @import("live_pty.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const artifact_io = @import("artifact_io.zig");
const fixture_script = @import("fixture_script.zig");
const smoke_drain = @import("smoke_drain.zig");
const surface_mod = @import("../session/surface.zig");
const window_mod = @import("../session/window.zig");

pub const default_artifact_dir = "zig-out/maru-app-pty-smoke";

/// fixture 규칙은 [fixture_script.zig](fixture_script.zig)가 단일 출처다 — OS별 셸과 "스크립트는 인자
/// 하나" 제약이 거기 있다.
const host_command = fixture_script.oneShot(
    @import("builtin").os.tag,
    "printf 'maru app pty\\n'; printf 'renderer frame\\n'",
    "echo maru app pty& echo renderer frame",
);

pub const AppPtySmokeConfig = struct {
    artifact_dir: []const u8 = default_artifact_dir,
    size: terminal.Size = .{ .cols = 40, .rows = 6 },
    command: []const u8 = host_command.command,
    args: []const []const u8 = host_command.args,
    expected_text: []const u8 = "maru app pty",
    drain_timeout_ms: i64 = smoke_drain.default_timeout_ms,
};

pub const AppPtySmokeResult = struct {
    summary: []u8,
    raw: []u8,
    screen: []u8,
    snapshot: []u8,
    frame: []u8,

    pub fn deinit(self: *AppPtySmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.raw);
        allocator.free(self.screen);
        allocator.free(self.snapshot);
        allocator.free(self.frame);
        self.* = undefined;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, config: AppPtySmokeConfig) !AppPtySmokeResult {
    // 이 smoke는 실제 UI 직전의 결합점이다. 실제 PTY process를 띄우고,
    // reader/queue/runtime/app host/renderer frame까지 통과시킨다. 창은 아직 띄우지
    // 않으므로 visible_ui=false로 남겨, "실행 가능한 app 경로"와 "보이는 앱"을 섞지 않는다.
    var live_pty: live_pty_mod.LivePtySession = undefined;
    try live_pty.init(io, allocator, 10, .{
        .command = config.command,
        .args = config.args,
        .size = config.size,
    }, 16);
    defer live_pty.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, config.size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "app pty smoke";
    surfaces[0].command = config.command;

    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try live_pty.attachSurface(&runtime, &surfaces[0], false); // controlled smoke — 리더 처리 끔(큐-드레인)

    var pump = live_pty.pump(&runtime);
    var raw_bytes: std.ArrayList(u8) = .empty;
    errdefer raw_bytes.deinit(allocator);
    const drain_summary = try drainUntilTerminationWithRaw(
        io,
        allocator,
        live_pty.eventQueue(),
        &pump,
        &raw_bytes,
        config.drain_timeout_ms,
    );

    live_pty.finishAfterTermination();

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var frame = try host.buildFrameAfterDrain(
        allocator,
        &app_window,
        &renderer_state,
        renderer.FakeFontBackend{},
        drain_summary,
        io,
    );
    defer frame.deinit(allocator);

    const render_stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    const raw = try raw_bytes.toOwnedSlice(allocator);
    errdefer allocator.free(raw);

    const screen = try surfaces[0].core.dumpUtf8(allocator);
    errdefer allocator.free(screen);

    const snapshot = try observability.snapshot.renderTerminalSnapshot(allocator, surfaces[0].core.snapshot());
    errdefer allocator.free(snapshot);

    const frame_artifact = try renderFrameArtifact(allocator, frame, render_stats);
    errdefer allocator.free(frame_artifact);

    const summary = try renderSummary(allocator, .{
        .config = config,
        .drain_summary = drain_summary,
        .process_state = surfaces[0].process_state,
        .render_stats = render_stats,
        .raw_bytes_len = raw.len,
        .screen_contains_expected = std.mem.indexOf(u8, screen, config.expected_text) != null,
    });
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, config.artifact_dir, .{
        .summary = summary,
        .raw = raw,
        .screen = screen,
        .snapshot = snapshot,
        .frame = frame_artifact,
    });

    return .{
        .summary = summary,
        .raw = raw,
        .screen = screen,
        .snapshot = snapshot,
        .frame = frame_artifact,
    };
}

fn drainUntilTerminationWithRaw(
    io: std.Io,
    allocator: std.mem.Allocator,
    queue: *pty_reader.PtyEventQueue,
    pump: *runtime_pump.RuntimeEventPump,
    raw_bytes: *std.ArrayList(u8),
    timeout_ms: i64,
) !runtime_pump.DrainSummary {
    var summary: runtime_pump.DrainSummary = .{};

    while (true) {
        const event = try smoke_drain.popWithDeadline(io, queue, .{ .timeout_ms = timeout_ms });
        if (event == .output) {
            // applyQueuedEvent가 event bytes를 해제하므로, artifact로 남길 raw bytes는
            // 그 전에 별도 버퍼에 복사한다. 이 복사는 smoke/debug 경로에만 있고
            // 제품 hot path에는 들어가지 않는다.
            try raw_bytes.appendSlice(allocator, event.output.bytes);
        }
        const pumped = try pump.applyQueuedEvent(event);
        summary.recordPumpedEvent(pumped);

        if (summary.ended != null) return summary;
    }
}

const SmokeArtifacts = struct {
    summary: []const u8,
    raw: []const u8,
    screen: []const u8,
    snapshot: []const u8,
    frame: []const u8,
};

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    artifacts: SmokeArtifacts,
) !void {
    try ensureDir(io, artifact_dir);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/app-pty.summary.txt", .{artifact_dir});
    defer allocator.free(summary_path);
    const raw_path = try std.fmt.allocPrint(allocator, "{s}/app-pty.raw.txt", .{artifact_dir});
    defer allocator.free(raw_path);
    const screen_path = try std.fmt.allocPrint(allocator, "{s}/app-pty.screen.txt", .{artifact_dir});
    defer allocator.free(screen_path);
    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/app-pty.snapshot.txt", .{artifact_dir});
    defer allocator.free(snapshot_path);
    const frame_path = try std.fmt.allocPrint(allocator, "{s}/app-pty.frame.txt", .{artifact_dir});
    defer allocator.free(frame_path);

    try writeText(io, summary_path, artifacts.summary);
    try writeText(io, raw_path, artifacts.raw);
    try writeTextWithFinalNewline(io, allocator, screen_path, artifacts.screen);
    try writeText(io, snapshot_path, artifacts.snapshot);
    try writeText(io, frame_path, artifacts.frame);
}

const SummaryInput = struct {
    config: AppPtySmokeConfig,
    drain_summary: runtime_pump.DrainSummary,
    process_state: surface_mod.ProcessState,
    render_stats: renderer.RenderFrameStats,
    raw_bytes_len: usize,
    screen_contains_expected: bool,
};

fn renderSummary(allocator: std.mem.Allocator, input: SummaryInput) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.app-pty-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{input.config.artifact_dir});
    try writer.writeAll("visible_ui=false\n");
    try writer.writeAll("ui_note=real_pty_app_host_renderer_frame_without_appkit_window\n");
    try writer.writeAll("renderer_input=surface_runtime_live_pty\n");
    try writer.writeAll("renderer_shaper=fake_font_backend\n");
    try writer.print("command={s}\n", .{input.config.command});
    try writer.print("args.len={d}\n", .{input.config.args.len});
    try writer.print("drain_timeout_ms={d}\n", .{input.config.drain_timeout_ms});
    try writer.print("size.cols={d}\n", .{input.config.size.cols});
    try writer.print("size.rows={d}\n", .{input.config.size.rows});
    try writer.print("output_events={d}\n", .{input.drain_summary.output_events});
    try writer.print("exit_events={d}\n", .{input.drain_summary.exit_events});
    try writer.print("process_state={s}\n", .{@tagName(input.process_state)});
    try writer.writeAll("termination=");
    try writeTermination(writer, input.drain_summary.ended);
    try writer.writeByte('\n');
    try writer.print("raw_bytes={d}\n", .{input.raw_bytes_len});
    try writer.print("screen_contains_expected={}\n", .{input.screen_contains_expected});
    try renderer.writeRenderFrameStats(writer, "renderer_", input.render_stats);

    return output.toOwnedSlice();
}

fn renderFrameArtifact(
    allocator: std.mem.Allocator,
    frame: host.AppHostFrame,
    stats: renderer.RenderFrameStats,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.app-pty-frame.v1\n");
    try writer.print("surface_id={d}\n", .{frame.surface_id});
    try writer.print("size.cols={d}\n", .{frame.size.cols});
    try writer.print("size.rows={d}\n", .{frame.size.rows});
    try writer.print("process_state={s}\n", .{@tagName(frame.process_state)});
    try renderer.writeRenderFrameStats(writer, "renderer_", stats);
    try writer.print("draw_cells={d}\n", .{frame.render_frame.draw_list.cells.len});
    for (frame.render_frame.draw_list.cells) |cell| {
        try writer.print("cell row={d} col={d} codepoint=U+{X:0>4} width={d}\n", .{
            cell.row,
            cell.col,
            cell.codepoint,
            cell.width,
        });
    }

    return output.toOwnedSlice();
}

const writeTermination = runtime_pump.writeTermination;
const writeExitStatus = runtime_pump.writeExitStatus;
const writeText = artifact_io.writeText;
const writeTextWithFinalNewline = artifact_io.writeTextWithFinalNewline;
const ensureDir = artifact_io.ensureDir;

test "app PTY smoke summary records live PTY to renderer frame boundary" {
    const summary = try renderSummary(std.testing.allocator, .{
        .config = .{ .artifact_dir = "zig-out/test-app-pty-smoke", .size = .{ .cols = 12, .rows = 3 } },
        .drain_summary = .{
            .output_events = 2,
            .exit_events = 1,
            .ended = .{ .exited = .{ .exited = 0 } },
        },
        .process_state = .exited,
        .render_stats = .{
            .consistent = true,
            .backend = .metal,
            .surface_cols = 12,
            .surface_rows = 3,
            .draw_cells = 8,
            .draw_overlays = 1,
            .glyph_count = 8,
            .glyph_quad_count = 8,
            .glyph_uv_count = 8,
            .glyph_uv_ready = true,
            .glyph_raster_upload_count = 4,
            .glyph_raster_skipped_count = 0,
            .glyph_raster_out_of_bounds_skip_count = 0,
            .glyph_raster_error_skip_count = 0,
            .glyph_raster_byte_count = 784,
            .glyph_raster_zero_ink_count = 0,
            .glyph_raster_ready = true,
            .upload_count = 4,
            .reused_count = 4,
            .fallback_count = 0,
            .replacement_count = 0,
            .atlas_entries = 4,
        },
        .raw_bytes_len = 32,
        .screen_contains_expected = true,
    });
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.app-pty-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=surface_runtime_live_pty\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=fake_font_backend\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drain_timeout_ms=5000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "termination=exited(code=0)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screen_contains_expected=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
}

test "app PTY frame artifact records renderer input cells" {
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(std.testing.allocator, 9, .{ .cols = 4, .rows = 2 })};
    defer surfaces[0].deinit();
    try surfaces[0].core.write("PTY");

    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(std.testing.allocator, .{});
    defer renderer_state.deinit();

    var frame = try host.buildFrameAfterDrain(
        std.testing.allocator,
        &app_window,
        &renderer_state,
        renderer.FakeFontBackend{},
        .{ .output_events = 1 },
        std.testing.io,
    );
    defer frame.deinit(std.testing.allocator);

    const stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    const artifact = try renderFrameArtifact(std.testing.allocator, frame, stats);
    defer std.testing.allocator.free(artifact);

    try std.testing.expect(std.mem.indexOf(u8, artifact, "maru.app-pty-frame.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "surface_id=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "cell row=0 col=0 codepoint=U+0050") != null);
}
