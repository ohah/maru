const std = @import("std");
const maru = @import("maru");
const app = maru.app;
const config = maru.config;
const observability = maru.observability;
const pty = maru.pty;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const metal_smoke = @import("metal_smoke.zig");

const artifact_dir = "zig-out/maru-macos-app-pty-metal-smoke";
const screenshot_path = artifact_dir ++ "/app-pty-metal-frame.ppm";
const default_duration_ms: u32 = 1500;
const max_duration_ms: u32 = 600_000;
const renderer_input_live_pty = "surface_runtime_live_pty_draw_list";

const AppPtyMetalSmokeConfig = struct {
    size: terminal.Size = .{ .cols = 40, .rows = 6 },
    command: []const u8 = "/bin/sh",
    args: []const []const u8 = &.{
        "-c",
        "printf 'Maru live pty\\n'; printf '한 Metal\\n'",
    },
    expected_text: []const u8 = "Maru live pty",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const duration_ms = readDurationMs();
    const appearance = try config.resolveAppearance(.{});
    var fixture = try buildLivePtyFixture(io, allocator, .{}, appearance);
    defer fixture.deinit(allocator);

    try resetArtifacts(io);
    var native: metal_smoke.NativeMetalSmokeResult = std.mem.zeroes(metal_smoke.NativeMetalSmokeResult);
    native.status = -1;
    metal_smoke.maru_macos_metal_smoke_run(
        duration_ms,
        fixture.metal.size.cols,
        fixture.metal.size.rows,
        fixture.metal.cells.ptr,
        fixture.metal.cells.len,
        fixture.metal.atlas_width_px,
        fixture.metal.atlas_height_px,
        fixture.metal.raster_uploads.ptr,
        fixture.metal.raster_uploads.len,
        fixture.metal.raster_pixels.ptr,
        fixture.metal.raster_pixels.len,
        screenshot_path.ptr,
        screenshot_path.len,
        &native,
    );

    const smoke_status = metal_smoke.deriveSmokeStatus(native);
    const summary = try renderSummary(allocator, .{
        .duration_ms = duration_ms,
        .status = smoke_status,
        .native = native,
        .fixture = fixture,
    });
    defer allocator.free(summary);

    try writeArtifacts(io, allocator, .{
        .summary = summary,
        .raw = fixture.raw,
        .screen = fixture.screen,
        .snapshot = fixture.snapshot,
    });
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!fixture.screen_contains_expected or
        !smoke_status.terminal_grid or
        !smoke_status.product_atlas_uploaded or
        !smoke_status.product_atlas_sampled or
        !smoke_status.screenshot_artifact) return error.MacosAppPtyMetalSmokeFailed;
}

const LivePtyMetalFixture = struct {
    metal: metal_smoke.SmokeFixture,
    raw: []u8,
    screen: []u8,
    snapshot: []u8,
    drain_summary: app.RuntimePumpDrainSummary,
    process_state: app.ProcessState,
    screen_contains_expected: bool,
    command: []const u8,
    args_len: usize,
    size: terminal.Size,

    fn deinit(self: *LivePtyMetalFixture, allocator: std.mem.Allocator) void {
        self.metal.deinit(allocator);
        allocator.free(self.raw);
        allocator.free(self.screen);
        allocator.free(self.snapshot);
        self.* = undefined;
    }
};

fn buildLivePtyFixture(
    io: std.Io,
    allocator: std.mem.Allocator,
    smoke_config: AppPtyMetalSmokeConfig,
    appearance: config.ResolvedAppearance,
) !LivePtyMetalFixture {
    // 이 smoke는 첫 visible PTY 경로다. shell UX가 아니라 app/PTY/renderer/platform 결합을
    // 검증하므로 prompt와 dotfile 영향을 받지 않는 controlled command만 실행한다.
    var session = try pty.PtySession.spawn(allocator, .{
        .command = smoke_config.command,
        .args = smoke_config.args,
        .size = smoke_config.size,
    });
    defer session.deinit();

    var surfaces = [_]app.Surface{try app.Surface.init(allocator, 1, smoke_config.size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "app pty metal smoke";
    surfaces[0].command = smoke_config.command;

    var app_window: app.AppWindow = .{ .tabs = &surfaces };

    var runtime = app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, app.PtyIo.fromSession(&session));

    var queue = try app.PtyEventQueue.init(io, allocator, 16);
    defer queue.deinit();

    var reader = app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();
    var reader_joined = false;
    errdefer if (!reader_joined) reader.stopAndJoin();

    var pump = app.RuntimeEventPump.init(allocator, &queue, &runtime);
    var raw_bytes: std.ArrayList(u8) = .empty;
    errdefer raw_bytes.deinit(allocator);
    const drain_summary = try drainBlockingUntilTerminationWithRaw(&queue, &pump, &raw_bytes, allocator);

    reader.join();
    reader_joined = true;
    queue.close();

    const active = app_window.active() orelse return error.NoActiveSurface;
    const screen = try active.core.dumpUtf8(allocator);
    errdefer allocator.free(screen);
    const snapshot = try observability.snapshot.renderTerminalSnapshot(allocator, active.core.snapshot());
    errdefer allocator.free(snapshot);
    const raw = try raw_bytes.toOwnedSlice(allocator);
    errdefer allocator.free(raw);

    const draw_list = try renderer.buildDrawList(allocator, active.core.snapshot());
    const metal_fixture = try metal_smoke.buildSmokeFixtureFromOwnedDrawList(
        allocator,
        appearance,
        draw_list,
        coretext_bridge.maru_macos_coretext_shape_draw_list,
        coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
        coretext_raster.CoreTextGlyphRasterizer.name,
        true,
        renderer_input_live_pty,
    );
    // buildSmokeFixtureFromOwnedDrawList가 성공하면 RenderFrame이 DrawList ownership을 가져간다.
    // 이후 이 scope에서 draw_list를 deinit하지 않는 것이 double-free를 막는 소유권 계약이다.
    errdefer {
        var fixture_for_cleanup = metal_fixture;
        fixture_for_cleanup.deinit(allocator);
    }

    return .{
        .metal = metal_fixture,
        .raw = raw,
        .screen = screen,
        .snapshot = snapshot,
        .drain_summary = drain_summary,
        .process_state = active.process_state,
        .screen_contains_expected = std.mem.indexOf(u8, screen, smoke_config.expected_text) != null,
        .command = smoke_config.command,
        .args_len = smoke_config.args.len,
        .size = smoke_config.size,
    };
}

fn drainBlockingUntilTerminationWithRaw(
    queue: *app.PtyEventQueue,
    pump: *app.RuntimeEventPump,
    raw_bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !app.RuntimePumpDrainSummary {
    var summary: app.RuntimePumpDrainSummary = .{};

    while (true) {
        const event = queue.popBlocking() orelse return error.ReaderQueueClosedBeforeTermination;
        if (event == .output) {
            // applyQueuedEvent가 output bytes를 해제하므로, screenshot과 함께 볼 raw artifact는
            // 적용 전에 복사한다. 이 복사는 smoke 전용이며 제품 frame loop에는 들어가지 않는다.
            try raw_bytes.appendSlice(allocator, event.output.bytes);
        }
        const pumped = try pump.applyQueuedEvent(event);
        summary.recordPumpedEvent(pumped);
        if (summary.ended != null) return summary;
    }
}

const SummaryInput = struct {
    duration_ms: u32,
    status: metal_smoke.SmokeStatus,
    native: metal_smoke.NativeMetalSmokeResult,
    fixture: LivePtyMetalFixture,
};

fn renderSummary(allocator: std.mem.Allocator, input: SummaryInput) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-app-pty-metal-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("visible_ui={}\n", .{input.status.visible_ui});
    try writer.print("metal_surface={}\n", .{input.status.metal_surface});
    try writer.print("terminal_grid={}\n", .{input.status.terminal_grid});
    try writer.print("product_atlas_uploaded={}\n", .{input.status.product_atlas_uploaded});
    try writer.print("product_atlas_sampled={}\n", .{input.status.product_atlas_sampled});
    try writer.print("screenshot_artifact={}\n", .{input.status.screenshot_artifact});
    if (input.status.screenshot_artifact) {
        try writer.print("screenshot_path={s}\n", .{screenshot_path});
        try writer.writeAll("screenshot_format=ppm_rgb_from_bgra8_drawable_readback\n");
    }
    const glyph_text = input.fixture.metal.uses_coretext_bytes and input.status.product_atlas_sampled;
    try writer.print("glyph_text={}\n", .{glyph_text});
    try writer.writeAll("ui_note=appkit_window_with_live_pty_coretext_drawlist_glyph_atlas_sampling\n");
    try writer.print("renderer_input={s}\n", .{input.fixture.metal.input});
    try writer.print("renderer_atlas_slot_placement={}\n", .{metal_smoke.nativeCellsHaveAtlasPlacement(input.fixture.metal.cells)});
    try renderer.writeRenderFrameStats(writer, "renderer_", input.fixture.metal.stats);
    try writer.print("renderer_shaper={s}\n", .{input.fixture.metal.shaper});
    try writer.print("renderer_rasterizer={s}\n", .{input.fixture.metal.rasterizer});
    try writer.print("command={s}\n", .{input.fixture.command});
    try writer.print("args.len={d}\n", .{input.fixture.args_len});
    try writer.print("size.cols={d}\n", .{input.fixture.size.cols});
    try writer.print("size.rows={d}\n", .{input.fixture.size.rows});
    try writer.print("output_events={d}\n", .{input.fixture.drain_summary.output_events});
    try writer.print("exit_events={d}\n", .{input.fixture.drain_summary.exit_events});
    try writer.print("process_state={s}\n", .{@tagName(input.fixture.process_state)});
    try writer.writeAll("termination=");
    try writeTermination(writer, input.fixture.drain_summary.ended);
    try writer.writeByte('\n');
    try writer.print("raw_bytes={d}\n", .{input.fixture.raw.len});
    try writer.print("screen_contains_expected={}\n", .{input.fixture.screen_contains_expected});
    try writer.print("duration_ms={d}\n", .{input.duration_ms});
    try writer.print("native_status={d}\n", .{input.native.status});
    try writer.print("window_visible={d}\n", .{input.native.window_visible});
    try writer.print("presented_frames={d}\n", .{input.native.presented_frames});
    try writer.print("readback_samples={d}\n", .{input.native.readback_samples});
    try writer.print("readback_failures={d}\n", .{input.native.readback_failures});
    try writer.print("atlas_uploads_requested={d}\n", .{input.native.atlas_uploads_requested});
    try writer.print("atlas_uploads_uploaded={d}\n", .{input.native.atlas_uploads_uploaded});
    try writer.print("atlas_readback_mismatched_bytes={d}\n", .{input.native.atlas_readback_mismatched_bytes});
    try writer.print("atlas_readback_failures={d}\n", .{input.native.atlas_readback_failures});
    try writer.print("atlas_sampled_cells={d}\n", .{input.native.atlas_sampled_cells});
    try writer.print("atlas_sample_missing_cells={d}\n", .{input.native.atlas_sample_missing_cells});
    try writer.print("screenshot_written={d}\n", .{input.native.screenshot_written});
    try writer.print("screenshot_bytes={d}\n", .{input.native.screenshot_bytes});
    try writer.print("raw_artifact={s}/app-pty-metal.raw.txt\n", .{artifact_dir});
    try writer.print("screen_artifact={s}/app-pty-metal.screen.txt\n", .{artifact_dir});
    try writer.print("snapshot_artifact={s}/app-pty-metal.snapshot.txt\n", .{artifact_dir});

    return output.toOwnedSlice();
}

fn writeTermination(writer: *std.Io.Writer, termination: ?app.RuntimePumpTermination) !void {
    if (termination == null) {
        try writer.writeAll("none");
        return;
    }

    switch (termination.?) {
        .exited => |status| {
            try writer.writeAll("exited(");
            try writeExitStatus(writer, status);
            try writer.writeByte(')');
        },
        .read_error => |message| try writer.print("read_error({s})", .{message}),
    }
}

fn writeExitStatus(writer: *std.Io.Writer, status: pty.ExitStatus) !void {
    switch (status) {
        .exited => |code| try writer.print("code={d}", .{code}),
        .signaled => |signal| try writer.print("signal={d}", .{signal}),
        .unknown => |raw| try writer.print("unknown={d}", .{raw}),
    }
}

const ArtifactInput = struct {
    summary: []const u8,
    raw: []const u8,
    screen: []const u8,
    snapshot: []const u8,
};

fn writeArtifacts(io: std.Io, allocator: std.mem.Allocator, artifacts: ArtifactInput) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try writeText(io, artifact_dir ++ "/app-pty-metal.summary.txt", artifacts.summary);
    try writeText(io, artifact_dir ++ "/app-pty-metal.raw.txt", artifacts.raw);
    const screen_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{artifacts.screen});
    defer allocator.free(screen_with_newline);
    try writeText(io, artifact_dir ++ "/app-pty-metal.screen.txt", screen_with_newline);
    try writeText(io, artifact_dir ++ "/app-pty-metal.snapshot.txt", artifacts.snapshot);
}

fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

fn resetArtifacts(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    std.Io.Dir.cwd().deleteFile(io, screenshot_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn readDurationMs() u32 {
    const raw_ptr = std.c.getenv("MARU_APP_PTY_METAL_SMOKE_MS") orelse return default_duration_ms;
    return durationFromEnv(std.mem.span(raw_ptr));
}

fn durationFromEnv(raw: []const u8) u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch return default_duration_ms;
    if (parsed == 0) return default_duration_ms;
    return @min(parsed, max_duration_ms);
}

test "app PTY Metal summary records live PTY and visible Metal evidence" {
    var native = std.mem.zeroes(metal_smoke.NativeMetalSmokeResult);
    native.status = 0;
    native.window_visible = 1;
    native.presented_frames = 2;
    native.readback_samples = 3;
    native.atlas_texture_created = 1;
    native.atlas_uploads_requested = 3;
    native.atlas_uploads_uploaded = 3;
    native.atlas_upload_bytes = 1024;
    native.atlas_readback_uploads = 3;
    native.atlas_sampled_cells = 3;
    native.screenshot_written = 1;
    native.screenshot_width = 800;
    native.screenshot_height = 400;
    native.screenshot_bytes = 960_000;

    var cells = [_]metal_smoke.NativeMetalCell{.{
        .row = 0,
        .col = 0,
        .width = 1,
        .codepoint = 'M',
        .slot_id = 1,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 14,
        .atlas_height_px = 14,
        .u0 = 0.0,
        .v0 = 0.0,
        .u1 = 0.01,
        .v1 = 0.01,
    }};
    var uploads = [_]metal_smoke.NativeMetalRasterUpload{};
    var pixels = [_]u8{};
    const metal_fixture: metal_smoke.SmokeFixture = .{
        .size = .{ .cols = 40, .rows = 6 },
        .cells = cells[0..],
        .atlas_width_px = 1024,
        .atlas_height_px = 1024,
        .raster_uploads = uploads[0..],
        .raster_pixels = pixels[0..],
        .uses_coretext_bytes = true,
        .stats = .{
            .consistent = true,
            .backend = .metal,
            .surface_cols = 40,
            .surface_rows = 6,
            .draw_cells = 240,
            .draw_overlays = 1,
            .glyph_count = 240,
            .glyph_quad_count = 240,
            .glyph_uv_count = 240,
            .glyph_uv_ready = true,
            .glyph_raster_upload_count = 3,
            .glyph_raster_skipped_count = 0,
            .glyph_raster_out_of_bounds_skip_count = 0,
            .glyph_raster_error_skip_count = 0,
            .glyph_raster_byte_count = 1024,
            .glyph_raster_zero_ink_count = 0,
            .glyph_raster_ready = true,
            .upload_count = 3,
            .reused_count = 237,
            .fallback_count = 1,
            .replacement_count = 0,
            .atlas_entries = 3,
        },
        .input = renderer_input_live_pty,
        .rasterizer = coretext_raster.CoreTextGlyphRasterizer.name,
    };
    const fixture: LivePtyMetalFixture = .{
        .metal = metal_fixture,
        .raw = @constCast("Maru live pty\n"),
        .screen = @constCast("Maru live pty"),
        .snapshot = @constCast("maru.snapshot.v3\n"),
        .drain_summary = .{
            .output_events = 1,
            .exit_events = 1,
            .ended = .{ .exited = .{ .exited = 0 } },
        },
        .process_state = .exited,
        .screen_contains_expected = true,
        .command = "/bin/sh",
        .args_len = 2,
        .size = .{ .cols = 40, .rows = 6 },
    };
    const summary = try renderSummary(std.testing.allocator, .{
        .duration_ms = 1500,
        .status = metal_smoke.deriveSmokeStatus(native),
        .native = native,
        .fixture = fixture,
    });
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-app-pty-metal-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_grid=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "product_atlas_sampled=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=surface_runtime_live_pty_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=coretext_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_rasterizer=coretext_glyph_rasterizer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "termination=exited(code=0)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screen_contains_expected=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_path=zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal-frame.ppm\n") != null);
}

test "app PTY Metal duration override clamps invalid, zero, and oversized values" {
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("abc"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv(""));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("0"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("99999999999"));
    try std.testing.expectEqual(@as(u32, 250), durationFromEnv("250"));
    try std.testing.expectEqual(max_duration_ms, durationFromEnv("99999999"));
}
