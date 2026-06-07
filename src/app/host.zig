const std = @import("std");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("surface.zig");
const window_mod = @import("window.zig");

pub const default_artifact_dir = "zig-out/maru-app-smoke";

pub const HostError = std.mem.Allocator.Error || runtime_pump.PumpError || renderer.GlyphQuadError || renderer.GlyphRasterError || error{
    NoActiveSurface,
};

pub const AppHostFrame = struct {
    surface_id: runtime_mod.SurfaceId,
    size: terminal.Size,
    process_state: surface_mod.ProcessState,
    drain_summary: runtime_pump.DrainSummary,
    render_frame: renderer.RenderFrame,

    pub fn deinit(self: *AppHostFrame, allocator: std.mem.Allocator) void {
        self.render_frame.deinit(allocator);
        self.* = undefined;
    }
};

pub fn buildFrame(
    allocator: std.mem.Allocator,
    app_window: *window_mod.AppWindow,
    pump: *runtime_pump.RuntimeEventPump,
    renderer_state: *renderer.RendererState,
    shaper: anytype,
) HostError!AppHostFrame {
    // 실제 AppKit frame loop가 붙기 전에도 "한 frame에서 할 일"을 먼저 고정한다.
    // app host는 queue를 비우고, active surface snapshot을 renderer frame으로 바꾼다.
    // 이 경계가 있어야 나중에 macOS window loop가 terminal storage나 glyph atlas를
    // 직접 만지지 않는다.
    const drain_summary = try pump.drainAvailable();
    const active = app_window.active() orelse return error.NoActiveSurface;
    const render_frame = try renderer_state.buildFrame(allocator, active.core.snapshot(), shaper);

    return .{
        .surface_id = active.id,
        .size = active.core.size,
        .process_state = active.process_state,
        .drain_summary = drain_summary,
        .render_frame = render_frame,
    };
}

pub fn sendInputToActiveSurface(
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    input: runtime_mod.TerminalInput,
) HostError!void {
    // keybinding resolver가 이미 terminal input으로 분류한 bytes만 여기로 내려온다.
    // app host는 active surface를 고르는 책임만 갖고, key encoding 자체는 하지 않는다.
    const active = app_window.active() orelse return error.NoActiveSurface;
    try runtime.writeInput(active.id, input);
}

pub fn resizeActiveSurface(
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    size: terminal.Size,
) HostError!void {
    // window resize는 screen storage와 PTY 둘 다 바꾼다. SurfaceRuntime을 통하면
    // 두 경로가 같은 action에서 함께 일어나고, app host가 TerminalCore를 직접 고치지 않는다.
    const active = app_window.active() orelse return error.NoActiveSurface;
    try runtime.resize(active.id, size);
}

pub const AppSmokeConfig = struct {
    artifact_dir: []const u8 = default_artifact_dir,
    initial_size: terminal.Size = .{ .cols = 24, .rows = 4 },
    resized_size: terminal.Size = .{ .cols = 32, .rows = 6 },
    output: []const u8 = "maru app host\n",
    input_bytes: []const u8 = "echo smoke\n",
};

pub const AppSmokeResult = struct {
    summary: []u8,
    draw_list: []u8,
    glyph_frame: []u8,

    pub fn deinit(self: *AppSmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.draw_list);
        allocator.free(self.glyph_frame);
        self.* = undefined;
    }
};

pub fn runSmoke(io: std.Io, allocator: std.mem.Allocator, config: AppSmokeConfig) !AppSmokeResult {
    // 이 smoke는 아직 실제 UI가 아니다. 목적은 AppKit 없이도 app host가
    // window/surface/runtime/renderer 계약을 한 번에 조립할 수 있음을 확인하는 것이다.
    // 실제 UI로 확인 가능한 시점은 macOS AppKit host 또는 Metal surface PR에서 따로 알린다.
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, config.initial_size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "app smoke";
    surfaces[0].command = "memory-pty";

    var app_window: window_mod.AppWindow = .{ .tabs = &surfaces };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(io, allocator, 4);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    const output_bytes = try allocator.dupe(u8, config.output);
    // pushBlocking이 성공하면 output bytes 소유권은 queue로 넘어간다(drain 때 pump가
    // event.deinit으로, 미소비 시 queue.deinit이 해제한다). 그래서 push 성공 뒤에도
    // 살아남는 errdefer로 free하면 이미 해제된 bytes를 다시 free하는 double-free가 된다.
    // PtyReader.run과 같은 "push 실패 때만 producer가 해제" 계약을 따른다.
    queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = output_bytes } }) catch |err| {
        allocator.free(output_bytes);
        return err;
    };

    try resizeActiveSurface(&app_window, &runtime, config.resized_size);
    try sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = config.input_bytes });

    var frame = try buildFrame(allocator, &app_window, &pump, &renderer_state, renderer.FakeFontBackend{});
    defer frame.deinit(allocator);

    const draw_list_text = try renderDrawList(allocator, frame.render_frame.draw_list);
    errdefer allocator.free(draw_list_text);
    const glyph_frame_text = try renderGlyphFrame(allocator, frame.render_frame);
    errdefer allocator.free(glyph_frame_text);

    const render_stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    const summary = try renderSmokeSummary(allocator, config, frame, render_stats, &memory_pty);
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, config.artifact_dir, .{
        .summary = summary,
        .draw_list = draw_list_text,
        .glyph_frame = glyph_frame_text,
    });

    return .{
        .summary = summary,
        .draw_list = draw_list_text,
        .glyph_frame = glyph_frame_text,
    };
}

const SmokeArtifacts = struct {
    summary: []const u8,
    draw_list: []const u8,
    glyph_frame: []const u8,
};

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    artifacts: SmokeArtifacts,
) !void {
    try ensureDir(io, artifact_dir);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/app-host.summary.txt", .{artifact_dir});
    defer allocator.free(summary_path);
    const draw_list_path = try std.fmt.allocPrint(allocator, "{s}/app-host.draw-list.txt", .{artifact_dir});
    defer allocator.free(draw_list_path);
    const glyph_frame_path = try std.fmt.allocPrint(allocator, "{s}/app-host.glyph-frame.txt", .{artifact_dir});
    defer allocator.free(glyph_frame_path);

    try writeText(io, summary_path, artifacts.summary);
    try writeText(io, draw_list_path, artifacts.draw_list);
    try writeText(io, glyph_frame_path, artifacts.glyph_frame);
}

fn renderSmokeSummary(
    allocator: std.mem.Allocator,
    config: AppSmokeConfig,
    frame: AppHostFrame,
    render_stats: renderer.RenderFrameStats,
    memory_pty: *const MemoryPty,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.app-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{config.artifact_dir});
    try writer.writeAll("visible_ui=false\n");
    try writer.writeAll("ui_note=not_yet_appkit_or_metal\n");
    try writer.print("active_surface_id={d}\n", .{frame.surface_id});
    try writer.print("size.cols={d}\n", .{frame.size.cols});
    try writer.print("size.rows={d}\n", .{frame.size.rows});
    try writer.print("process_state={s}\n", .{@tagName(frame.process_state)});
    try writer.print("output_events={d}\n", .{frame.drain_summary.output_events});
    try writer.print("exit_events={d}\n", .{frame.drain_summary.exit_events});
    // 제품 frame 통계는 renderer가 소유한 공유 직렬화기로 남긴다. visible smoke들과 같은
    // "renderer_" schema를 써서 app-smoke artifact의 frame 통계 키도 서로 일치시킨다.
    try renderer.writeRenderFrameStats(writer, "renderer_", render_stats);
    try writer.print("input_bytes.len={d}\n", .{memory_pty.writes.items.len});
    try writer.print("resize_calls={d}\n", .{memory_pty.resize_calls});
    if (memory_pty.last_size) |size| {
        try writer.print("pty_last_size.cols={d}\n", .{size.cols});
        try writer.print("pty_last_size.rows={d}\n", .{size.rows});
    } else {
        try writer.writeAll("pty_last_size=none\n");
    }

    return output.toOwnedSlice();
}

fn renderGlyphFrame(allocator: std.mem.Allocator, render_frame: renderer.RenderFrame) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    // app-smoke는 아직 픽셀을 보여주지 않는다. 대신 이 artifact가 backend가 받을
    // glyph/atlas 입력을 사람이 볼 수 있게 만든다. 나중에 실제 Metal renderer가 붙으면
    // screenshot 실패와 frame data 실패를 분리해서 추적할 수 있다.
    const glyph_frame = render_frame.glyph_frame;
    const quad_frame = render_frame.glyph_quad_frame;
    const raster_frame = render_frame.glyph_raster_frame;
    const writer = &output.writer;
    try writer.writeAll("maru.glyph-frame.v1\n");
    try writer.print("backend={s}\n", .{@tagName(render_frame.backend)});
    try writer.print("size cols={d} rows={d}\n", .{ glyph_frame.size.cols, glyph_frame.size.rows });
    try writer.print("glyphs len={d}\n", .{glyph_frame.glyphs.len});
    try writer.print("quads len={d}\n", .{quad_frame.glyphs.len});
    try writer.print("quad_stats glyph_count={d} uv_count={d} ready={}\n", .{
        quad_frame.stats.glyph_count,
        quad_frame.stats.uv_count,
        quad_frame.stats.ready(),
    });
    try writer.print("raster_uploads len={d} bytes={d} zero_ink={d} ready={}\n", .{
        raster_frame.uploads.len,
        raster_frame.stats.byte_count,
        raster_frame.stats.zero_ink_uploads,
        raster_frame.stats.ready(),
    });
    try writer.print("uploads len={d}\n", .{glyph_frame.uploads.len});
    try writer.print("stats glyph_count={d} upload_count={d} reused_count={d} fallback_count={d} replacement_count={d}\n", .{
        glyph_frame.stats.glyph_count,
        glyph_frame.stats.upload_count,
        glyph_frame.stats.reused_count,
        glyph_frame.stats.fallback_count,
        glyph_frame.stats.replacement_count,
    });
    for (glyph_frame.glyphs) |glyph| {
        try writer.print(
            "glyph row={d} col={d} codepoint=U+{X:0>4} font_id={d} glyph_id={d} slot={d} fallback={} replacement={}\n",
            .{
                glyph.run.row,
                glyph.run.col,
                glyph.run.codepoint,
                glyph.run.font_id,
                glyph.run.glyph_id,
                glyph.slot.id,
                glyph.run.fallback,
                glyph.run.replacement,
            },
        );
    }
    for (glyph_frame.uploads) |upload| {
        try writer.print(
            "upload glyph_index={d} slot={d} bytes={d} evicted={}\n",
            .{ upload.glyph_index, upload.slot.id, upload.upload_bytes, upload.evicted != null },
        );
    }
    for (raster_frame.uploads) |upload| {
        try writer.print(
            "raster glyph_index={d} slot={d} offset={d} bytes={d} row_bytes={d} non_clear={d}\n",
            .{
                upload.glyph_index,
                upload.slot.id,
                upload.bytes_offset,
                upload.byte_count,
                upload.bytes_per_row,
                upload.non_clear_pixels,
            },
        );
    }

    return output.toOwnedSlice();
}

fn renderDrawList(allocator: std.mem.Allocator, draw_list: renderer.DrawList) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.draw-list.v1\n");
    try writer.print("size cols={d} rows={d}\n", .{ draw_list.size.cols, draw_list.size.rows });
    try writer.print("cells len={d}\n", .{draw_list.cells.len});
    for (draw_list.cells) |cell| {
        try writer.print(
            "cell row={d} col={d} codepoint=U+{X:0>4} width={d} underline={}\n",
            .{ cell.row, cell.col, cell.codepoint, cell.width, cell.style.underline },
        );
    }
    try writer.print("overlays len={d}\n", .{draw_list.overlays.len});
    for (draw_list.overlays) |overlay| {
        switch (overlay) {
            .cursor => |cursor| try writer.print(
                "overlay cursor row={d} col={d} visible={}\n",
                .{ cursor.row, cursor.col, cursor.visible },
            ),
            .underline => |underline| try writer.print(
                "overlay underline row={d} col={d} width={d}\n",
                .{ underline.row, underline.col, underline.width },
            ),
        }
    }

    return output.toOwnedSlice();
}

fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
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

test "app host frame drains runtime events and builds renderer frame for active surface" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 12, .rows = 2 })};
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

    const bytes = try allocator.dupe(u8, "frame");
    // push 성공 시 queue가 bytes를 소유한다(아래 buildFrame의 drain이 pump를 통해 해제).
    // 실패할 때만 직접 해제해야 double-free 없이 누수도 막는다(runSmoke와 같은 계약).
    queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } }) catch |err| {
        allocator.free(bytes);
        return err;
    };

    var frame = try buildFrame(allocator, &app_window, &pump, &renderer_state, renderer.FakeFontBackend{});
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(runtime_mod.SurfaceId, 1), frame.surface_id);
    try std.testing.expectEqual(@as(usize, 1), frame.drain_summary.output_events);
    try std.testing.expect(frame.render_frame.draw_list.cells.len >= 5);
    try std.testing.expect(frame.render_frame.glyphFrameConsistent());
}

test "app host routes focused input and resize through SurfaceRuntime" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var app_window: window_mod.AppWindow = .{ .tabs = &surfaces };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    try sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = "abc" });
    try resizeActiveSurface(&app_window, &runtime, .{ .cols = 30, .rows = 5 });

    try std.testing.expectEqualStrings("abc", memory_pty.writes.items);
    try std.testing.expectEqual(@as(usize, 1), memory_pty.resize_calls);
    try std.testing.expectEqual(terminal.Size{ .cols = 30, .rows = 5 }, memory_pty.last_size.?);
    try std.testing.expectEqual(terminal.Size{ .cols = 30, .rows = 5 }, surfaces[0].core.size);
}

test "app smoke summary marks that real UI is not visible yet" {
    const cells = try std.testing.allocator.alloc(renderer.DrawCell, 0);
    const draw_overlays = try std.testing.allocator.alloc(renderer.DrawOverlay, 0);
    const glyphs = try std.testing.allocator.alloc(renderer.glyph_frame.PreparedGlyph, 0);
    const glyph_overlays = try std.testing.allocator.alloc(renderer.DrawOverlay, 0);
    const uploads = try std.testing.allocator.alloc(renderer.GlyphUpload, 0);
    const quads = try std.testing.allocator.alloc(renderer.GlyphQuad, 0);
    const quad_overlays = try std.testing.allocator.alloc(renderer.DrawOverlay, 0);
    const raster_uploads = try std.testing.allocator.alloc(renderer.GlyphRasterUpload, 0);
    const raster_pixels = try std.testing.allocator.alloc(u8, 0);

    var render_frame: renderer.RenderFrame = .{
        .backend = renderer.initialBackendForMacOS(),
        .draw_list = .{
            .size = .{ .cols = 3, .rows = 1 },
            .cursor = .{},
            .dirty = null,
            .cells = cells,
            .overlays = draw_overlays,
        },
        .glyph_frame = .{
            .size = .{ .cols = 3, .rows = 1 },
            .cursor = .{},
            .dirty = null,
            .glyphs = glyphs,
            .overlays = glyph_overlays,
            .uploads = uploads,
            .stats = .{},
        },
        .glyph_quad_frame = .{
            .size = .{ .cols = 3, .rows = 1 },
            .cursor = .{},
            .dirty = null,
            .glyphs = quads,
            .overlays = quad_overlays,
            .stats = .{},
        },
        .glyph_raster_frame = .{
            .uploads = raster_uploads,
            .pixels = raster_pixels,
            .stats = .{},
        },
    };
    defer render_frame.deinit(std.testing.allocator);

    const frame: AppHostFrame = .{
        .surface_id = 1,
        .size = render_frame.draw_list.size,
        .process_state = .running,
        .drain_summary = .{ .output_events = 1 },
        .render_frame = render_frame,
    };
    // 이 테스트는 renderSmokeSummary의 문자열 계약만 확인한다. frame 소유권은 위의
    // render_frame defer가 관리하므로 AppHostFrame.deinit은 호출하지 않는다.

    var memory_pty = MemoryPty.init(std.testing.allocator);
    defer memory_pty.deinit();

    // frame 통계는 공유 직렬화기로 남기므로, 이 문자열 계약 테스트는 통계를 직접 주입한다
    // (visible smoke들의 success fixture와 같은 방식). prepared()=true가 되도록 비어 있지
    // 않은 frame을 흉내 낸다.
    const render_stats: renderer.RenderFrameStats = .{
        .consistent = true,
        .backend = .metal,
        .surface_cols = 3,
        .surface_rows = 1,
        .draw_cells = 3,
        .draw_overlays = 0,
        .glyph_count = 3,
        .glyph_quad_count = 3,
        .glyph_uv_count = 3,
        .glyph_uv_ready = true,
        .glyph_raster_upload_count = 2,
        .glyph_raster_byte_count = 392,
        .glyph_raster_zero_ink_count = 1,
        .glyph_raster_ready = true,
        .upload_count = 2,
        .reused_count = 1,
        .fallback_count = 0,
        .replacement_count = 0,
        .atlas_entries = 2,
    };
    const summary = try renderSmokeSummary(
        std.testing.allocator,
        .{ .artifact_dir = "zig-out/test-app-smoke" },
        frame,
        render_stats,
        &memory_pty,
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.app-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=not_yet_appkit_or_metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_backend=metal\n") != null);
    // app host도 visible smoke들과 같은 renderer_* 키를 쓴다(예전 glyph_frame_ready/glyph_count).
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_entries=2\n") != null);
}

test "app smoke glyph artifact records backend frame input" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    var renderer_state = renderer.RendererState.init(std.testing.allocator, .{});
    defer renderer_state.deinit();

    core.clearDirty();
    try core.write("A");
    var render_frame = try renderer_state.buildFrame(
        std.testing.allocator,
        core.snapshot(),
        renderer.FakeFontBackend{},
    );
    defer render_frame.deinit(std.testing.allocator);

    const artifact = try renderGlyphFrame(std.testing.allocator, render_frame);
    defer std.testing.allocator.free(artifact);

    try std.testing.expect(std.mem.indexOf(u8, artifact, "maru.glyph-frame.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "quads len=") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "quad_stats glyph_count=") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "raster_uploads len=") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "glyph row=0 col=0 codepoint=U+0041") != null);
}
