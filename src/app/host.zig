const std = @import("std");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("surface.zig");
const window_mod = @import("window.zig");

pub const default_artifact_dir = "zig-out/maru-app-smoke";

pub const HostError = std.mem.Allocator.Error || runtime_pump.PumpError || error{
    NoActiveSurface,
};

pub const AppHostFrame = struct {
    surface_id: runtime_mod.SurfaceId,
    size: terminal.Size,
    process_state: surface_mod.ProcessState,
    drain_summary: runtime_pump.DrainSummary,
    draw_list: renderer.DrawList,

    pub fn deinit(self: *AppHostFrame, allocator: std.mem.Allocator) void {
        self.draw_list.deinit(allocator);
        self.* = undefined;
    }
};

pub fn buildFrame(
    allocator: std.mem.Allocator,
    app_window: *window_mod.AppWindow,
    pump: *runtime_pump.RuntimeEventPump,
) HostError!AppHostFrame {
    // 실제 AppKit frame loop가 붙기 전에도 "한 frame에서 할 일"을 먼저 고정한다.
    // app host는 queue를 비우고, active surface snapshot을 renderer 입력으로 바꾼다.
    // 이 경계가 있어야 나중에 macOS window loop가 terminal storage를 직접 만지지 않는다.
    const drain_summary = try pump.drainAvailable();
    const active = app_window.active() orelse return error.NoActiveSurface;
    const draw_list = try renderer.buildDrawList(allocator, active.core.snapshot());

    return .{
        .surface_id = active.id,
        .size = active.core.size,
        .process_state = active.process_state,
        .drain_summary = drain_summary,
        .draw_list = draw_list,
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

    pub fn deinit(self: *AppSmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.draw_list);
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

    const output_bytes = try allocator.dupe(u8, config.output);
    errdefer allocator.free(output_bytes);
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = output_bytes } });

    try resizeActiveSurface(&app_window, &runtime, config.resized_size);
    try sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = config.input_bytes });

    var frame = try buildFrame(allocator, &app_window, &pump);
    defer frame.deinit(allocator);

    const draw_list_text = try renderDrawList(allocator, frame.draw_list);
    errdefer allocator.free(draw_list_text);

    const summary = try renderSmokeSummary(allocator, config, frame, memory_pty);
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, config.artifact_dir, .{
        .summary = summary,
        .draw_list = draw_list_text,
    });

    return .{
        .summary = summary,
        .draw_list = draw_list_text,
    };
}

const SmokeArtifacts = struct {
    summary: []const u8,
    draw_list: []const u8,
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

    try writeText(io, summary_path, artifacts.summary);
    try writeText(io, draw_list_path, artifacts.draw_list);
}

fn renderSmokeSummary(
    allocator: std.mem.Allocator,
    config: AppSmokeConfig,
    frame: AppHostFrame,
    memory_pty: MemoryPty,
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
    try writer.print("draw_cells={d}\n", .{frame.draw_list.cells.len});
    try writer.print("draw_overlays={d}\n", .{frame.draw_list.overlays.len});
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

test "app host frame drains runtime events and builds draw list for active surface" {
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

    const bytes = try allocator.dupe(u8, "frame");
    errdefer allocator.free(bytes);
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });

    var frame = try buildFrame(allocator, &app_window, &pump);
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(runtime_mod.SurfaceId, 1), frame.surface_id);
    try std.testing.expectEqual(@as(usize, 1), frame.drain_summary.output_events);
    try std.testing.expect(frame.draw_list.cells.len >= 5);
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
    const draw_list: renderer.DrawList = .{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{},
        .dirty = null,
        .cells = &.{},
        .overlays = &.{},
    };
    const frame: AppHostFrame = .{
        .surface_id = 1,
        .size = draw_list.size,
        .process_state = .running,
        .drain_summary = .{ .output_events = 1 },
        .draw_list = draw_list,
    };
    var memory_pty = MemoryPty.init(std.testing.allocator);
    defer memory_pty.deinit();

    const summary = try renderSmokeSummary(
        std.testing.allocator,
        .{ .artifact_dir = "zig-out/test-app-smoke" },
        frame,
        memory_pty,
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.app-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=not_yet_appkit_or_metal\n") != null);
}
