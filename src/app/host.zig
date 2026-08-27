const std = @import("std");
const config_mod = @import("../config.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const live_pty_mod = @import("live_pty.zig");
const live_pty_registry = @import("live_pty_registry.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const artifact_io = @import("artifact_io.zig");
const surface_mod = @import("../session/surface.zig");
const window_mod = @import("../session/window.zig");

pub const default_artifact_dir = "zig-out/maru-app-smoke";

pub const HostError = std.mem.Allocator.Error || runtime_pump.PumpError || renderer.GlyphQuadError || renderer.GlyphRasterError || error{
    NoActiveSurface,
    ActiveSurfaceNotAttachedToLivePty,
};

pub const KeyHandlingResult = union(enum) {
    app_action: config_mod.Action,
    terminal_input: struct {
        bytes_len: usize,
    },
    ignored,
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
    return try buildFrameAfterDrain(allocator, app_window, renderer_state, shaper, drain_summary, pump.queue.io);
}

pub fn buildFrameAfterDrain(
    allocator: std.mem.Allocator,
    app_window: *window_mod.AppWindow,
    renderer_state: *renderer.RendererState,
    shaper: anytype,
    drain_summary: runtime_pump.DrainSummary,
    io: std.Io,
) HostError!AppHostFrame {
    // 래스터라이저를 주지 않은 호출자는 fake를 쓴다 — 기존 동작 그대로다(`RendererState`가 같은 기본값을
    // 갖는다). 실제 폰트 픽셀이 필요한 호스트는 아래 `…WithRasterizer`를 쓴다.
    return buildFrameAfterDrainWithRasterizer(
        allocator,
        app_window,
        renderer_state,
        shaper,
        renderer.FakeGlyphRasterizer{},
        drain_summary,
        io,
    );
}

/// `buildFrameAfterDrain`과 같지만 **글리프 래스터라이저를 주입받는다.**
///
/// 이 변종을 둔 이유는 하나다: 코어 락 규율(`docs/io-render-threading.md` — 코어 읽기는 락 아래,
/// shaping은 락 밖)이 여기 한 곳에만 있어야 한다. 플랫폼 호스트가 자기 래스터라이저를 쓰려고 이 함수
/// 본문을 복사하면 그 규율이 두 곳으로 갈리고, 한쪽만 고쳐지는 순간 조용히 깨진다.
pub fn buildFrameAfterDrainWithRasterizer(
    allocator: std.mem.Allocator,
    app_window: *window_mod.AppWindow,
    renderer_state: *renderer.RendererState,
    shaper: anytype,
    rasterizer: anytype,
    drain_summary: runtime_pump.DrainSummary,
    io: std.Io,
) HostError!AppHostFrame {
    // 실제 app loop에서는 queue drain과 frame 조립이 같은 frame 안에 있지만, smoke나
    // trace recorder는 raw event를 먼저 관찰해야 할 수 있다. 이 helper는 drain 결과를
    // 받은 뒤 active surface만 renderer frame으로 바꾸므로 두 경로가 같은 조립 코드를 쓴다.
    const active = app_window.active() orelse return error.NoActiveSurface;
    // renderSnapshot: 스크롤백 뷰포트가 열려 있으면(view_offset>0) 합성된 윈도를, 바닥이면 활성
    // 화면을 준다. snapshot()을 쓰면 이 frame 조립 경로(비-CoreText/fake backend 포함)가 스크롤
    // 위치를 무시한다.
    //
    // I/O–렌더 스레딩 분리(docs/io-render-threading.md): 코어 읽기(renderSnapshot→buildDrawList,
    // 코어 메모리를 DrawList로 복사)는 **락 아래**, shaping(buildFrameFromDrawList — DrawList 복사본만
    // 봄)은 **락 밖**. PR3에서 리더의 core.write가 렌더 shaping에 안 막히게 한다.
    active.lockCore(io);
    const list_or = renderer.buildDrawList(allocator, active.renderSnapshot());
    active.unlockCore(io);
    var list = try list_or;
    errdefer list.deinit(allocator);
    const render_frame = try renderer_state.buildFrameFromDrawListWithRasterizer(allocator, list, shaper, rasterizer);

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

pub fn handleKeyEvent(
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    resolver: config_mod.KeyBindingResolver,
    event: terminal.KeyEvent,
    option_as_meta: bool,
    encode_options_override: ?terminal.input.EncodeOptions,
) !KeyHandlingResult {
    // Platform code gives us a normalized key event, but it must not decide
    // whether that key is an app action or terminal bytes. Keeping that choice
    // here gives AppKit, future Windows, and tests one shared policy.
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    // 인코딩 모드(DECCKM 등)는 active surface의 프로그램이 정한다 — vim이 ?1h를 보냈으면 화살표가 SS3로 가야
    // 하므로 매 키마다 core의 현재 모드를 읽어 인코더에 넘긴다. 단 host-backed는 active.core가 빈 placeholder라
    // 그 모드를 모른다(§입력 패리티) — 호출자(app_session)가 runtime observation에서 만든 override를 넘기고, 로컬은
    // null이라 아래처럼 실제 core 모드를 읽는다.
    var encode_options: terminal.input.EncodeOptions = encode_options_override orelse
        (if (app_window.active()) |active| active.core.encodeOptions() else .{});
    // option_as_meta는 core 모드가 아니라 config(input.option-as-meta)다 — 호출자(app)가 넘겨 인코더에 합친다.
    encode_options.option_as_meta = option_as_meta;
    const resolved = try resolver.resolve(event, &buffer, encode_options);
    return switch (resolved) {
        .app_action => |action| .{ .app_action = action },
        .ignored => .ignored,
        .terminal_input => |bytes| blk: {
            try sendInputToActiveSurface(app_window, runtime, .{ .bytes = bytes });
            break :blk .{ .terminal_input = .{ .bytes_len = bytes.len } };
        },
    };
}

pub fn resizeActiveSurface(
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    size: terminal.Size,
    io: std.Io,
) HostError!void {
    // window resize는 screen storage와 PTY 둘 다 바꾼다. SurfaceRuntime을 통하면
    // 두 경로가 같은 action에서 함께 일어나고, app host가 TerminalCore를 직접 고치지 않는다.
    const active = app_window.active() orelse return error.NoActiveSurface;
    try runtime.resize(active.id, size, io); // io는 코어 락(docs/io-render-threading.md)
}

pub fn closeActiveLivePty(
    app_window: *window_mod.AppWindow,
    runtime: *runtime_mod.SurfaceRuntime,
    registry: *live_pty_registry.LivePtyRegistry,
) HostError!void {
    // platform close event는 PTY owner 포인터를 직접 고르지 않고 app host 정책으로 들어와야 한다.
    // registry가 active surface에 붙은 live PTY를 찾고 닫으므로, future Swift/AppKit code는
    // 현재 focus와 다른 tab의 session을 실수로 닫을 수 없다.
    _ = app_window.active() orelse return error.NoActiveSurface;
    registry.closeActive(app_window, runtime) catch |err| switch (err) {
        error.ActiveSurfaceNotAttachedToLivePty => return error.ActiveSurfaceNotAttachedToLivePty,
    };
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

    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

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

    try resizeActiveSurface(&app_window, &runtime, config.resized_size, io);
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
    try writer.print("raster_uploads len={d} skips={d} bytes={d} zero_ink={d} ready={}\n", .{
        raster_frame.uploads.len,
        raster_frame.skips.len,
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
            "raster upload_index={d} glyph_index={d} slot={d} offset={d} bytes={d} row_bytes={d} non_clear={d} evicted={}\n",
            .{
                upload.upload_index,
                upload.glyph_index,
                upload.slot.id,
                upload.bytes_offset,
                upload.byte_count,
                upload.bytes_per_row,
                upload.non_clear_pixels,
                upload.evicted != null,
            },
        );
    }
    for (raster_frame.skips) |skip| {
        try writer.print(
            "raster_skip upload_index={d} glyph_index={d} slot={d} reason={s} evicted={}\n",
            .{
                skip.upload_index,
                skip.glyph_index,
                skip.slot.id,
                @tagName(skip.reason),
                skip.evicted != null,
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
            .line => |line| try writer.print(
                "overlay {s} row={d} col={d} width={d}\n",
                .{ @tagName(line.kind), line.row, line.col, line.width },
            ),
            .gutter => |gutter| try writer.print(
                "overlay gutter row={d} success={}\n",
                .{ gutter.row, gutter.success },
            ),
        }
    }

    return output.toOwnedSlice();
}

const writeText = artifact_io.writeText;
const ensureDir = artifact_io.ensureDir;

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

test "app host close action detaches active live PTY before closing queue" {
    // 이 테스트는 future AppKit close button이 호출할 app-level 진입점을 고정한다.
    // platform code가 LivePtySession을 직접 닫으면 active surface 검증을 건너뛸 수 있으므로,
    // host boundary에서 active tab과 live PTY link가 맞는지 먼저 확인해야 한다.
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    const link = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var write_queue = try pty_reader.PtyWriteQueue.init(std.testing.io, allocator, 4096);
    var command_queue = try pty_reader.CoreCommandQueue.init(std.testing.io, allocator, 1024);
    defer command_queue.deinit();
    defer write_queue.deinit();
    var live: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .io = std.testing.io,
        .session = undefined,
        .queue = &queue,
        .write_queue = &write_queue,
        .command_queue = &command_queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };
    var registry = live_pty_registry.LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live);

    try closeActiveLivePty(&app_window, &runtime, &registry);

    try std.testing.expect(live.link == null);
    try std.testing.expect(registry.findBySurface(1) == null);
    try std.testing.expectError(error.UnknownSurface, runtime.writeInput(1, .{ .bytes = "after close" }));
    try std.testing.expectError(error.UnknownPty, runtime.applyPtyEvent(.{
        .output = .{ .pty_id = 10, .bytes = "late output" },
    }, std.testing.io));
    try std.testing.expectError(error.QueueClosed, queue.tryPush(.{
        .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } },
    }));
}

test "app host close action reports an empty window as no active surface" {
    // 빈 window는 "active surface에 live PTY가 붙어 있지 않다"가 아니라
    // 닫을 active surface 자체가 없는 상태다. 오류를 분리해야 native close event 로그가
    // focus 문제와 PTY registry 문제를 구분할 수 있다.
    const allocator = std.testing.allocator;
    var surfaces: [0]surface_mod.Surface = .{};
    _ = &surfaces;
    var tab_ptrs = [_]*surface_mod.Surface{};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var registry = live_pty_registry.LivePtyRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectError(error.NoActiveSurface, closeActiveLivePty(&app_window, &runtime, &registry));
}

test "app host close action refuses to close a live PTY attached to another tab" {
    // close command는 현재 active tab만 닫아야 한다. 이 guard가 없으면 focus가 다른
    // tab으로 이동한 뒤 늦게 도착한 close event가 엉뚱한 PTY를 끊을 수 있다.
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{
        try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 }),
        try surface_mod.Surface.init(allocator, 2, .{ .cols = 10, .rows = 2 }),
    };
    defer surfaces[0].deinit();
    defer surfaces[1].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{ &surfaces[0], &surfaces[1] };
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs, .active_tab = 1 };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    const link = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var write_queue = try pty_reader.PtyWriteQueue.init(std.testing.io, allocator, 4096);
    var command_queue = try pty_reader.CoreCommandQueue.init(std.testing.io, allocator, 1024);
    defer command_queue.deinit();
    defer write_queue.deinit();
    var live: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .io = std.testing.io,
        .session = undefined,
        .queue = &queue,
        .write_queue = &write_queue,
        .command_queue = &command_queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };
    var registry = live_pty_registry.LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live);

    try std.testing.expectError(
        error.ActiveSurfaceNotAttachedToLivePty,
        closeActiveLivePty(&app_window, &runtime, &registry),
    );
    try std.testing.expect(live.link != null);
    try runtime.writeInput(1, .{ .bytes = "still attached" });
    try std.testing.expectEqualStrings("still attached", memory_pty.writes.items);
    try queue.tryPush(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });
}

test "app host frame drains runtime events and builds renderer frame for active surface" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 12, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

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
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    try sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = "abc" });
    try resizeActiveSurface(&app_window, &runtime, .{ .cols = 30, .rows = 5 }, std.testing.io);

    try std.testing.expectEqualStrings("abc", memory_pty.writes.items);
    try std.testing.expectEqual(@as(usize, 1), memory_pty.resize_calls);
    try std.testing.expectEqual(terminal.Size{ .cols = 30, .rows = 5 }, memory_pty.last_size.?);
    try std.testing.expectEqual(terminal.Size{ .cols = 30, .rows = 5 }, surfaces[0].core.size);
}

test "app host resolves terminal key events before writing to active PTY" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    const resolver: config_mod.KeyBindingResolver = .{
        .terminal_bindings = &.{.{
            .chord = try config_mod.KeyChord.parse("Cmd+B"),
            .input = .{ .send_control = 'b' },
        }},
    };
    try resolver.validate();

    const result = try handleKeyEvent(&app_window, &runtime, resolver, .{
        .key = .{ .char = 'b' },
        .modifiers = .{ .command = true },
    }, true, null);

    try std.testing.expectEqual(@as(usize, 1), result.terminal_input.bytes_len);
    try std.testing.expectEqualStrings("\x02", memory_pty.writes.items);
}

test "app host threads option_as_meta into encoding: true=ESC-prefix, false=plain (input.option-as-meta)" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    const resolver: config_mod.KeyBindingResolver = .{}; // 바인딩 없음 → Option+b는 terminal_input 인코딩으로
    try resolver.validate();

    // option_as_meta=true(기본): Option+b → ESC-prefix meta "\x1bb".
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .{ .char = 'b' }, .modifiers = .{ .option = true } }, true, null);
    try std.testing.expectEqualStrings("\x1bb", memory_pty.writes.items);

    // option_as_meta=false: ESC 없이 평문 "b"(macOS에선 Option-단독이 입력기 조합으로 빠지지만, 우회로 여기 와도 ESC 없음).
    memory_pty.writes.clearRetainingCapacity();
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .{ .char = 'b' }, .modifiers = .{ .option = true } }, false, null);
    try std.testing.expectEqualStrings("b", memory_pty.writes.items);
}

test "app host encodes arrows per the active surface's DECCKM mode" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    const resolver: config_mod.KeyBindingResolver = .{};

    // normal mode: CSI 화살표
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .arrow_up }, true, null);
    try std.testing.expectEqualStrings("\x1b[A", memory_pty.writes.items);

    // 프로그램(vim)이 DECCKM을 켜면 같은 키가 SS3로 인코딩돼야 한다.
    try surfaces[0].core.write("\x1b[?1h");
    memory_pty.writes.clearRetainingCapacity();
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .arrow_up }, true, null);
    try std.testing.expectEqualStrings("\x1bOA", memory_pty.writes.items);
}

// §입력 패리티 host-backed 재현: host-backed 터미널은 active.core가 **빈 placeholder**라 그 encodeOptions()를 읽으면
// host의 실제 DECCKM/DECKPAM/kitty를 모른다(항상 기본값). 예전 경로는 그래서 host가 ?1h/kitty를 켜도 화살표를 CSI legacy로
// 보냈다. app_session은 이제 runtime observation에서 만든 encode_options_override를 넘긴다 — 이 스모크는 override가
// **placeholder core를 이겨** host 모드대로 인코딩됨을 고정한다(placeholder는 그대로 기본값임도 확인 = 출처가 override).
test "app host: encode_options_override가 placeholder core를 이긴다(host-backed DECCKM/kitty parity)" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    const resolver: config_mod.KeyBindingResolver = .{};

    // active.core(placeholder)는 DECCKM off(기본)지만, host가 DECCKM을 켰다는 관측 override면 화살표가 SS3여야 한다.
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .arrow_up }, true, .{ .application_cursor_keys = true });
    try std.testing.expectEqualStrings("\x1bOA", memory_pty.writes.items); // override 승 — placeholder였다면 "\x1b[A"
    try std.testing.expect(!surfaces[0].core.application_cursor_keys); // placeholder core는 손대지 않음 = 출처는 override

    // kitty keyboard flag override면 escape 같은 키가 legacy(\x1b) 대신 CSI u(kitty progressive enhancement)로 분기한다.
    // encodeKey가 kitty_flags != 0일 때 encodeKitty로 가는지 = override가 kitty_flags도 실어 나름을 고정.
    memory_pty.writes.clearRetainingCapacity();
    _ = try handleKeyEvent(&app_window, &runtime, resolver, .{ .key = .escape }, true, .{ .kitty_flags = 1 });
    try std.testing.expectEqualStrings("\x1b[27u", memory_pty.writes.items); // kitty CSI u — legacy였다면 "\x1b"
}

test "app host does not leak app actions or ignored Cmd keys to PTY" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    const resolver: config_mod.KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = try config_mod.KeyChord.parse("Cmd+T"), .action = .new_tab }},
    };
    try resolver.validate();

    const app_result = try handleKeyEvent(&app_window, &runtime, resolver, .{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, true, null);
    try std.testing.expectEqual(config_mod.Action.new_tab, app_result.app_action);
    try std.testing.expectEqual(@as(usize, 0), memory_pty.writes.items.len);

    // **글자는 계산해서 고른다** — 손으로 박으면 그 글자가 묶이는 날 이 판정자가 규율(「안 묶인 Cmd 는
    // PTY 로 안 샌다」)이 아니라 예시 때문에 깨진다. 2026-08-27 에 ⌘S·⌘Z 를 배선하며 실제로 그랬다.
    const ignored = try handleKeyEvent(&app_window, &runtime, resolver, .{
        .key = .{ .char = config_mod.keybinding.unbound_command_char },
        .modifiers = .{ .command = true },
    }, true, null);
    try std.testing.expectEqual(KeyHandlingResult.ignored, ignored);
    try std.testing.expectEqual(@as(usize, 0), memory_pty.writes.items.len);
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
    const raster_skips = try std.testing.allocator.alloc(renderer.GlyphRasterSkip, 0);
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
            .skips = raster_skips,
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
        .glyph_raster_skipped_count = 0,
        .glyph_raster_out_of_bounds_skip_count = 0,
        .glyph_raster_error_skip_count = 0,
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

test "app host builds frames from the scrolled viewport, not just the active screen" {
    const allocator = std.testing.allocator;
    var memory_pty = MemoryPty.init(allocator);
    defer memory_pty.deinit();
    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 8, .rows = 2 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surfaces[0], 10, memory_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 4);
    defer queue.deinit();
    var pump = runtime_pump.RuntimeEventPump.init(allocator, &queue, &runtime);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    // "one"이 스크롤백으로 밀리고 활성 화면은 two/three. 한 줄 위로 스크롤하면 뷰포트 첫 행이
    // 스크롤백의 "one"이어야 한다 — snapshot()을 쓰면 여전히 "two"가 나와 이 테스트가 잡는다.
    try surfaces[0].core.write("one\r\ntwo\r\nthree");
    surfaces[0].core.scrollViewport(1);

    var frame = try buildFrame(allocator, &app_window, &pump, &renderer_state, renderer.FakeFontBackend{});
    defer frame.deinit(allocator);

    var row0: [8]u21 = .{' '} ** 8;
    for (frame.render_frame.draw_list.cells) |cell| {
        if (cell.row == 0 and cell.col < 8) row0[cell.col] = cell.codepoint;
    }
    try std.testing.expectEqual(@as(u21, 'o'), row0[0]);
    try std.testing.expectEqual(@as(u21, 'n'), row0[1]);
    try std.testing.expectEqual(@as(u21, 'e'), row0[2]);
}
