const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const app = maru.app;
const config_mod = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const coretext_frame_builder = @import("coretext_frame_builder.zig");
const metal_frame = @import("metal_frame.zig");

// Metal DTO·view·owned 버퍼는 순수 모듈 metal_frame이 소유한다. ABI 표면으로 re-export만 한다.
pub const MetalCell = metal_frame.NativeMetalCell;
pub const MetalRasterUpload = metal_frame.NativeMetalRasterUpload;
pub const MetalFrame = metal_frame.MetalFrame;

pub const abi_version: u32 = 7;
pub const default_queue_capacity: u32 = 16;

// app_host_abi.zig가 이 파일을 import하므로 EventKind는 여기서 정의하고 거기서 re-export한다
// (순환 import 회피). FrameSummary.last_event_kind가 이 값을 그대로 싣는다.
pub const EventKind = enum(u32) {
    none = 0,
    frame_tick = 1,
    key_down = 2,
    resize = 3,
    close_requested = 4,
    app_should_terminate = 5,
};

pub const CommandKind = enum(u32) {
    controlled_smoke = 0,
    interactive_shell = 1,
};

pub const SessionConfig = extern struct {
    abi_version: u32,
    cols: u32,
    rows: u32,
    queue_capacity: u32,
    command_kind: u32,
    reserved: u32 = 0,
};

pub const FrameSummary = extern struct {
    abi_version: u32 = abi_version,
    terminal_surface: u32 = 0,
    frame_loop_ticks: u64 = 0,
    last_tick_index: u64 = 0,
    output_events: u64 = 0,
    exit_events: u64 = 0,
    surface_id: u64 = 0,
    glyph_count: u64 = 0,
    draw_cells: u64 = 0,
    atlas_entries: u64 = 0,
    key_events: u64 = 0,
    terminal_input_events: u64 = 0,
    terminal_input_bytes: u64 = 0,
    app_key_events: u64 = 0,
    ignored_key_events: u64 = 0,
    resize_events: u64 = 0,
    close_events: u64 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    process_state: u32 = 0,
    frame_prepared: u32 = 0,
    frame_consistent: u32 = 0,
    glyph_uv_ready: u32 = 0,
    glyph_raster_ready: u32 = 0,
    ended: u32 = 0,
    last_event_kind: u32 = @intFromEnum(EventKind.none),
    // 현재 retain된 Metal frame의 generation(u64를 u32로 truncate). host는 이 값이 그대로면
    // metalFrame() ABI를 부르지 않고 draw를 건너뛸 수 있다(idle tick 비용 절감). u32 wrap은
    // 사실상 발생하지 않고, 충돌해도 redraw 한 번 누락/추가일 뿐이라 무해하다.
    metal_generation: u32 = 0,
};

const NormalizedConfig = struct {
    size: terminal.Size,
    queue_capacity: usize,
    command_kind: CommandKind,
};

pub const DevSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    live_pty: app.LivePtySession = undefined,
    surfaces: [1]app.Surface = undefined,
    app_window: app.AppWindow = undefined,
    runtime: app.SurfaceRuntime = undefined,
    pump: app.RuntimeEventPump = undefined,
    renderer_state: renderer.RendererState = undefined,
    frame_loop: app.AppFrameLoop = undefined,
    // 제품 dev shell은 fake font backend가 아니라 실제 CoreText로 glyph frame을 만든다.
    // appearance(폰트/색)는 init에서 한 번 resolve해 매 tick의 CoreTextFrameBuilder에 쓴다.
    appearance: config_mod.ResolvedAppearance = undefined,
    // 한 cell의 픽셀 크기(정사각 glyph = font_size_px × device_scale). renderer fixed-cell
    // layout과 host resize가 같은 값을 쓰도록 init에서 한 번 계산해 metal frame으로 노출한다.
    cell_px: u32 = 0,
    live_initialized: bool = false,
    surface_initialized: bool = false,
    runtime_initialized: bool = false,
    renderer_initialized: bool = false,
    termination_finished: bool = false,
    total_output_events: u64 = 0,
    total_exit_events: u64 = 0,
    total_key_events: u64 = 0,
    total_terminal_input_events: u64 = 0,
    total_terminal_input_bytes: u64 = 0,
    total_app_key_events: u64 = 0,
    total_ignored_key_events: u64 = 0,
    total_resize_events: u64 = 0,
    total_close_events: u64 = 0,
    ended_seen: bool = false,
    last_summary: FrameSummary = .{},
    // 가장 최근 RenderFrame의 Metal 투영을 retain하는 owned 버퍼. metalFrame()이 이걸 가리키는
    // view를 돌려준다. metal_dirty가 true일 때만(첫 frame, 새 output, resize) 재투영한다.
    metal_buffer: metal_frame.MetalFrameBuffer = .{},
    metal_dirty: bool = true,

    pub fn init(
        self: *DevSession,
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_config: SessionConfig,
    ) !void {
        const config = try normalizeConfig(raw_config);

        self.* = .{
            .allocator = allocator,
            .io = io,
        };
        errdefer self.deinit();

        // Swift는 opaque handle만 보유하고, 이 구조체는 heap에 고정된다. LivePtySession의
        // reader thread가 `&live_pty.reader`를 잡고 돌기 때문에, 이 값을 만든 뒤에는
        // 절대 by-value로 이동하지 않는 것이 이번 ABI의 핵심 수명 계약이다.
        try self.live_pty.init(io, allocator, 10, spawnRequest(config), config.queue_capacity);
        self.live_initialized = true;

        self.surfaces[0] = try app.Surface.init(allocator, 1, config.size);
        self.surface_initialized = true;
        self.surfaces[0].title = "Maru dev shell";
        self.surfaces[0].command = commandName(config.command_kind);

        self.app_window = .{ .tabs = self.surfaces[0..] };
        self.runtime = app.SurfaceRuntime.init(allocator);
        self.runtime_initialized = true;
        _ = try self.live_pty.attachSurface(&self.runtime, &self.surfaces[0]);

        self.pump = self.live_pty.pump(&self.runtime);
        self.renderer_state = renderer.RendererState.init(allocator, .{});
        self.renderer_initialized = true;
        self.appearance = try config_mod.resolveAppearance(.{});
        // shaper와 같은 정책(textConfigFromFontSize, device_scale=1)으로 cell 픽셀 크기를
        // 도출해, renderer/host가 atlas glyph와 같은 크기로 cell을 깐다.
        self.cell_px = renderer.textConfigFromFontSize(self.appearance.font.size, 1).font_size_px;
        self.frame_loop = app.AppFrameLoop.init(allocator, &self.app_window, &self.runtime, &self.pump, &self.renderer_state);
        self.writeSummaryFromState();
    }

    pub fn handleKeyEvent(self: *DevSession, event: terminal.KeyEvent) !FrameSummary {
        // Swift/AppKit는 normalized key event만 전달한다. app-vs-terminal 판정과 PTY
        // write는 기존 FrameLoop 경계를 통과해야 smoke와 제품 app이 같은 shortcut 정책을 쓴다.
        self.total_key_events += 1;
        // 셸이 이미 종료/close된 뒤 도착한 입력은 라우팅할 live surface가 없다. FrameLoop로
        // 내려보내면 UnknownSurface/SessionClosed로 실패하는데, 그건 치명적 세션 fault가
        // 아니라 닫힌 pane의 late input이므로 ignored로 회계만 하고 정상으로 닫는다.
        if (self.ended_seen) {
            self.total_ignored_key_events += 1;
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
            return self.last_summary;
        }
        const result = try self.frame_loop.handleKeyEvent(config_mod.KeyBindingResolver{}, event);
        switch (result) {
            .terminal_input => |terminal_input| {
                self.total_terminal_input_events += 1;
                self.total_terminal_input_bytes += terminal_input.bytes_len;
            },
            .app_action => self.total_app_key_events += 1,
            .ignored => self.total_ignored_key_events += 1,
        }
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
        return self.last_summary;
    }

    pub fn resize(self: *DevSession, size: terminal.Size) !FrameSummary {
        // resize는 terminal grid와 PTY winsize가 함께 바뀌어야 한다. FrameLoop API를
        // 통해 SurfaceRuntime action으로 내려보내면 Swift가 두 책임을 다시 구현하지 않는다.
        self.total_resize_events += 1;
        // 종료된 세션의 resize도 live surface가 없어 실패한다. 닫히는 창의 late resize는
        // 치명적 오류가 아니므로 무시하고 정상으로 닫는다(key와 같은 정책).
        if (self.ended_seen) {
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
            return self.last_summary;
        }
        try self.frame_loop.resizeActiveSurface(size);
        // grid가 reflow됐으므로 다음 tick이 Metal frame을 재투영하게 dirty로 표시한다.
        self.metal_dirty = true;
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
        return self.last_summary;
    }

    pub fn tick(self: *DevSession) !FrameSummary {
        // macOS 제품 실행은 실제 CoreText shaper/rasterizer로 frame을 만든다(fake backend
        // 아님). 그래야 summary의 glyph/atlas 통계가 실제 rasterized glyph를 반영하고, 이후
        // 제품 Metal view가 같은 RenderFrame을 그대로 그릴 수 있다. CoreText는 platform
        // 경계라 builder가 소유한다.
        //
        // 비-macOS(주로 Linux CI의 ABI 계약 테스트)에는 CoreText 브리지 심볼이 없다. OS
        // 게이트는 comptime이라 Linux 빌드는 macOS 분기를 codegen에서 제외하므로 extern
        // 참조가 생기지 않고, frame loop 계약만 fake backend로 유지한다.
        var tick_result = if (builtin.os.tag == .macos) blk: {
            const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
                .appearance = self.appearance,
                .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
                .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
            };
            break :blk try self.frame_loop.tickWithFrameBuilder(frame_builder);
        } else try self.frame_loop.tick(renderer.FakeFontBackend{});
        defer tick_result.deinit(self.allocator);

        // 생명주기 회계(이벤트 합산, 종료 reap)를 먼저 끝낸다. Metal 투영은 이 뒤에 둬야
        // 투영 실패가 drained 이벤트나 finishAfterTermination(reader join/child reap)을
        // 건너뛰게 만들지 않는다.
        self.total_output_events += tick_result.frame.drain_summary.output_events;
        self.total_exit_events += tick_result.frame.drain_summary.exit_events;
        if (tick_result.ended() and !self.termination_finished) {
            self.ended_seen = true;
            self.live_pty.finishAfterTermination();
            self.termination_finished = true;
        }

        // 새 output이 있을 때만 frame이 바뀐다(resize는 resize()가 dirty를 세운다). idle tick은
        // 재투영하지 않아 generation이 그대로이고, 소비자는 재업로드를 건너뛸 수 있다.
        if (tick_result.frame.drain_summary.output_events > 0) self.metal_dirty = true;
        if (self.metal_dirty) {
            // Metal view 데이터 투영 실패(OOM 등)는 터미널 코어 동작과 무관하다. 마지막
            // frame을 유지하고 dirty를 남겨 다음 tick에 재시도한다(세션을 죽이지 않는다).
            if (self.metal_buffer.replace(self.allocator, tick_result.frame.render_frame, self.renderer_state.atlas.config, self.cell_px, self.cell_px)) |_| {
                self.metal_dirty = false;
            } else |_| {}
        }

        self.writeSummaryFromTick(tick_result);
        // 세션이 종료되면 host가 frame loop를 멈추고 우아하게 내려가도록 app_should_terminate를
        // 싣는다. ABI의 tick export는 이 ended를 SessionEnded status로 올려준다.
        self.last_summary.last_event_kind = @intFromEnum(
            if (self.ended_seen) EventKind.app_should_terminate else EventKind.frame_tick,
        );
        return self.last_summary;
    }

    pub fn close(self: *DevSession) FrameSummary {
        self.total_close_events += 1;
        if (self.live_initialized and self.runtime_initialized) {
            self.live_pty.closeAndDetach(&self.runtime);
        } else if (self.live_initialized) {
            self.live_pty.close();
        }
        if (self.surface_initialized) {
            // App/window close는 더 이상 이 surface가 live input/output을 받을 수 없다는
            // 뜻이다. exit event를 기다리지 않고 close가 child를 정리한 경우에도 summary가
            // running으로 남으면 close lifecycle을 오해하므로 dev session summary에서는
            // 종료 상태로 latch한다.
            self.surfaces[0].process_state = .exited;
            self.ended_seen = true;
        }
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.close_requested);
        return self.last_summary;
    }

    pub fn metalFrame(self: *const DevSession) MetalFrame {
        return self.metal_buffer.view();
    }

    pub fn deinit(self: *DevSession) void {
        self.metal_buffer.deinit(self.allocator);
        if (self.live_initialized) {
            if (self.runtime_initialized) {
                self.live_pty.closeAndDetach(&self.runtime);
            }
            self.live_pty.deinit();
            self.live_initialized = false;
        }
        if (self.renderer_initialized) {
            self.renderer_state.deinit();
            self.renderer_initialized = false;
        }
        if (self.runtime_initialized) {
            self.runtime.deinit();
            self.runtime_initialized = false;
        }
        if (self.surface_initialized) {
            self.surfaces[0].deinit();
            self.surface_initialized = false;
        }
        self.* = undefined;
    }

    fn writeSummaryFromTick(self: *DevSession, tick_result: app.AppFrameLoopTick) void {
        // 공유 counter/size/state는 writeSummaryFromState가 단일 출처로 채운다. tick만 아는
        // per-frame render 통계와 tick index만 여기서 덧씌운다. 이렇게 해야 두 writer가
        // 필드별로 어긋나지 않고, 새 counter가 추가돼도 한 곳만 고치면 된다. key/resize/close
        // summary의 render 필드는 "마지막으로 그려진 frame" 값(화면의 현재 상태)을 그대로
        // 유지한다.
        self.writeSummaryFromState();
        const stats = tick_result.render_stats;
        self.last_summary.last_tick_index = @intCast(tick_result.index);
        self.last_summary.glyph_count = @intCast(stats.glyph_count);
        self.last_summary.draw_cells = @intCast(stats.draw_cells);
        self.last_summary.atlas_entries = @intCast(stats.atlas_entries);
        self.last_summary.frame_prepared = boolCode(stats.prepared());
        self.last_summary.frame_consistent = boolCode(stats.consistent);
        self.last_summary.glyph_uv_ready = boolCode(stats.glyph_uv_ready);
        self.last_summary.glyph_raster_ready = boolCode(stats.glyph_raster_ready);
    }

    fn writeSummaryFromState(self: *DevSession) void {
        self.last_summary.abi_version = abi_version;
        self.last_summary.terminal_surface = boolCode(self.surface_initialized);
        self.last_summary.frame_loop_ticks = if (self.renderer_initialized) @intCast(self.frame_loop.frame_index) else 0;
        self.last_summary.output_events = self.total_output_events;
        self.last_summary.exit_events = self.total_exit_events;
        self.last_summary.key_events = self.total_key_events;
        self.last_summary.terminal_input_events = self.total_terminal_input_events;
        self.last_summary.terminal_input_bytes = self.total_terminal_input_bytes;
        self.last_summary.app_key_events = self.total_app_key_events;
        self.last_summary.ignored_key_events = self.total_ignored_key_events;
        self.last_summary.resize_events = self.total_resize_events;
        self.last_summary.close_events = self.total_close_events;
        self.last_summary.ended = boolCode(self.ended_seen);
        self.last_summary.metal_generation = @truncate(self.metal_buffer.generation);
        if (self.surface_initialized) {
            self.last_summary.surface_id = self.surfaces[0].id;
            self.last_summary.cols = self.surfaces[0].core.size.cols;
            self.last_summary.rows = self.surfaces[0].core.size.rows;
            self.last_summary.process_state = processStateCode(self.surfaces[0].process_state);
        }
    }
};

pub fn normalizeConfig(config: SessionConfig) !NormalizedConfig {
    if (config.abi_version != abi_version) return error.UnsupportedAbi;
    if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
    if (config.cols > std.math.maxInt(u16) or config.rows > std.math.maxInt(u16)) return error.InvalidConfig;

    const command_kind = std.enums.fromInt(CommandKind, config.command_kind) orelse return error.InvalidConfig;

    return .{
        .size = .{ .cols = @intCast(config.cols), .rows = @intCast(config.rows) },
        .queue_capacity = if (config.queue_capacity == 0) default_queue_capacity else config.queue_capacity,
        .command_kind = command_kind,
    };
}

fn spawnRequest(config: NormalizedConfig) maru.pty.SpawnRequest {
    return switch (config.command_kind) {
        .controlled_smoke => .{
            .command = "/bin/sh",
            .args = &.{
                "-c",
                "printf 'Maru app dev shell\\r\\n'; IFS= read -r line; printf 'Maru app dev input:%s\\r\\n' \"$line\"; printf 'Maru app dev frame loop\\r\\n'",
            },
            .size = config.size,
        },
        .interactive_shell => .{
            .command = maru.pty.resolveInteractiveShell(),
            .args = &.{"-i"},
            .size = config.size,
        },
    };
}

fn commandName(kind: CommandKind) []const u8 {
    return switch (kind) {
        .controlled_smoke => "/bin/sh -c maru-app-dev-smoke",
        .interactive_shell => maru.pty.resolveInteractiveShell(),
    };
}

fn processStateCode(state: app.ProcessState) u32 {
    return switch (state) {
        .starting => 0,
        .running => 1,
        .exited => 2,
    };
}

fn boolCode(value: bool) u32 {
    return if (value) 1 else 0;
}

test "macOS app dev session config rejects unsafe fixed-width ABI input" {
    // Swift가 넘긴 config는 Zig allocator나 slice를 포함하지 않는 fixed-width record다.
    // 이 검증이 있어야 잘못된 window size나 오래된 ABI가 PTY spawn까지 내려가지 않는다.
    try std.testing.expectError(error.UnsupportedAbi, normalizeConfig(.{
        .abi_version = abi_version - 1,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    }));
    try std.testing.expectError(error.InvalidConfig, normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 0,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    }));
    try std.testing.expectError(error.InvalidConfig, normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = 999,
    }));
}

test "macOS app dev session config defaults queue capacity without changing command intent" {
    const normalized = try normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 0,
        .command_kind = @intFromEnum(CommandKind.interactive_shell),
    });
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 24 }, normalized.size);
    try std.testing.expectEqual(@as(usize, default_queue_capacity), normalized.queue_capacity);
    try std.testing.expectEqual(CommandKind.interactive_shell, normalized.command_kind);
}
