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

pub const abi_version: u32 = 11;
pub const default_queue_capacity: u32 = 16;

// cell 메트릭이 아직 없을 때(이론상 init 전) grid 계산에 쓰는 placeholder cell 픽셀 크기.
// 실제로는 init이 refreshCellMetrics를 부르므로 resize 시점엔 항상 실제 메트릭이 있다.
const placeholder_cell_width_px: u32 = 12;
const placeholder_cell_height_px: u32 = 24;

/// backing 픽셀 크기와 cell 픽셀 크기로 터미널 grid(cols/rows)를 구한다. cell 크기가 0이면
/// placeholder로 대체하고, u16 상한으로 막은 뒤 terminal.clampGridSize로 최소 크기(cols>=2)를
/// 적용한다 — cols>=2 불변식은 TerminalCore가 단일 소유하므로 여기서 직접 하드코딩하지 않는다.
fn gridFromBacking(backing_width_px: u32, backing_height_px: u32, cell_width_px: u32, cell_height_px: u32) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px;
    const raw_cols = @min(backing_width_px / cell_w, std.math.maxInt(u16));
    const raw_rows = @min(backing_height_px / cell_h, std.math.maxInt(u16));
    return terminal.clampGridSize(.{ .cols = @intCast(raw_cols), .rows = @intCast(raw_rows) });
}

/// 휠/트랙패드 델타(포인트 또는 줄)를 정수 줄 수로 바꾼다. 정밀(트랙패드) 델타는 실제 cell 높이를
/// scale로 나눈 한 줄 포인트로 환산하고, 1줄 미만 잔여분은 accum에 누적한다 — round로 버리면
/// 천천히 굴릴 때 무반응이 된다. NaN/∞는 무시하고 누적은 ±1000줄로 clamp한다(trap 방지).
fn wheelDeltaToLines(accum: *f64, delta_y: f64, precise: bool, cell_height_px: u32, scale_milli: u32) i32 {
    if (!std.math.isFinite(delta_y)) return 0;
    var lines_f: f64 = delta_y;
    if (precise) {
        const scale: f64 = @as(f64, @floatFromInt(scale_milli)) / 1000.0;
        const ch_px: f64 = @floatFromInt(if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px);
        const line_pts: f64 = if (scale > 0) ch_px / scale else ch_px;
        if (line_pts > 0) lines_f = delta_y / line_pts;
    }
    accum.* = std.math.clamp(accum.* + lines_f, -1000.0, 1000.0);
    const whole: f64 = std.math.trunc(accum.*);
    accum.* -= whole;
    return @intFromFloat(whole);
}

// 화면 상태 진단 logger. MARU_DEBUG일 때 frame build마다 TerminalCore의 cell 격자(cursor 위치 +
// 줄별 텍스트/배경)를 찍어, "개행 안 되고 덮어씀" 같은 cursor/scroll 동작을 데이터로 확인한다.
// MARU_DEBUG 게이트는 diag.zig가 단일 출처로 소유한다.
const screen_diag = std.log.scoped(.screen);
const diag_gate = @import("diag.zig");

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
    // 한 cell의 device 픽셀 크기(advance 폭 × line-height). 실제 CoreText 메트릭에서 뽑아
    // shaper(atlas slot 크기)·rasterizer·renderer fixed-cell layout·host resize가 모두 같은 값을
    // 쓰게 한다. 메트릭 조회 전/실패 시 font_size_px × device_scale 정사각으로 대체한다.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // backing(Retina) scale을 천분율로 보관한다(예: 2000 = 2.0×, 1500 = 1.5×). 정수 배율로
    // 반올림하지 않고 분수 그대로 들고 있어, glyph rasterize 크기와 cell 메트릭을 분수 Retina
    // 해상도에 정확히 맞춘다. resize 이벤트의 scale_milli에서 갱신한다.
    scale_milli: u32 = 1000,
    // 마지막으로 적용한 grid 크기. 같은 size+scale resize 중복을 여기서 건너뛴다(Swift가 아니라).
    last_resize_size: ?terminal.Size = null,
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
    // 트랙패드 정밀 스크롤의 1줄 미만 잔여 델타(줄 단위). scrollWheel이 누적/소비한다.
    wheel_accum: f64 = 0,

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
        self.runtime.debug_input = diag_gate.maruDebugEnabled(); // MARU_DEBUG면 zsh redraw 시퀀스 로깅
        self.runtime_initialized = true;
        _ = try self.live_pty.attachSurface(&self.runtime, &self.surfaces[0]);

        self.pump = self.live_pty.pump(&self.runtime);
        self.renderer_state = renderer.RendererState.init(allocator, .{});
        self.renderer_initialized = true;
        self.appearance = try config_mod.resolveAppearance(.{});
        // 실제 폰트 메트릭에서 cell 픽셀 크기를 뽑는다. shaper(atlas slot)·rasterizer·renderer가
        // 모두 같은 값을 쓰게 하는 단일 출처다.
        self.refreshCellMetrics();
        self.frame_loop = app.AppFrameLoop.init(allocator, &self.app_window, &self.runtime, &self.pump, &self.renderer_state);
        self.writeSummaryFromState();
    }

    /// 현재 font·scale_milli에 대한 cell 픽셀 크기(advance 폭 × line-height)를 CoreText에서
    /// 뽑아 갱신한다. 분수 scale을 그대로 곱한 device 픽셀 font size로 조회한다. macOS가
    /// 아니거나(테스트/CI) 조회 실패면 같은 device 픽셀 font size의 정사각으로 대체한다.
    /// scale_milli가 바뀌는 resize에서도 호출한다.
    fn refreshCellMetrics(self: *DevSession) void {
        const device_font_size = renderer.deviceFontSizeFromMilli(self.appearance.font.size, self.scale_milli);
        const square: u32 = @intFromFloat(@round(device_font_size));
        self.cell_width_px = square;
        self.cell_height_px = square;
        // extern native 호출은 macOS에서만 컴파일/링크한다(.m을 링크하지 않는 Linux 계약
        // 빌드에서 undefined symbol이 되지 않게 comptime으로 막는다).
        if (builtin.os.tag == .macos) {
            var metrics: coretext_bridge.CellMetricsResult = .{};
            coretext_bridge.maru_macos_coretext_font_cell_metrics(
                self.appearance.font.family.ptr,
                self.appearance.font.family.len,
                device_font_size,
                &metrics,
            );
            if (metrics.status == 0 and metrics.cell_width_px > 0 and metrics.cell_height_px > 0) {
                self.cell_width_px = metrics.cell_width_px;
                self.cell_height_px = metrics.cell_height_px;
            }
        }
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
        // 타이핑하면 live(바닥)로 돌아간다 — 과거를 보다가 입력하면 현재 화면으로 점프(표준 터미널).
        // 스크롤 중이었으면 즉시 다시 그리도록 metal_dirty도 세운다(echo 출력 전에라도 뷰 복귀).
        if (self.surface_initialized and self.surfaces[0].core.viewOffset() != 0) {
            self.surfaces[0].core.scrollToBottom();
            self.metal_dirty = true;
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

    /// 뷰포트를 delta_up줄만큼 스크롤한다(+위=과거, -아래=현재). 스크롤 로직은 TerminalCore가
    /// 소유하고, 여기선 다음 tick이 새 뷰를 그리도록 metal_dirty만 세운다(Swift는 휠/키 이벤트를
    /// 이 함수로 넘기는 얇은 글루다).
    pub fn scroll(self: *DevSession, delta_up: i32) void {
        if (!self.surface_initialized) return;
        self.surfaces[0].core.scrollViewport(@as(isize, delta_up));
        self.metal_dirty = true;
    }

    /// 마우스/트랙패드 휠 스크롤. Swift는 raw NSEvent 값(델타 포인트 + 정밀 델타 여부)만 넘기고,
    /// 줄 수 환산은 여기서 실제 cell 메트릭으로 한다(네이티브 최소화). 정밀(트랙패드) 델타는 포인트
    /// 단위라 한 줄 높이(포인트)로 나눠 줄 수로 바꾸고, 줄 단위(마우스 휠) 델타는 그대로 줄 수다.
    /// 한 줄 미만의 정밀 델타는 wheel_accum에 누적해 천천히 스크롤해도 줄이 소실되지 않는다.
    /// NaN/∞·거대값은 무시/clamp한다(@intFromFloat trap 방지).
    pub fn scrollWheel(self: *DevSession, delta_y: f64, precise: bool) void {
        if (!self.surface_initialized) return;
        const lines = wheelDeltaToLines(&self.wheel_accum, delta_y, precise, self.cell_height_px, self.scale_milli);
        if (lines == 0) return;

        const core = &self.surfaces[0].core;
        if (core.alt_active and core.alternate_scroll) {
            // alternate scroll(xterm DECSET 1007): alt screen에서는 스크롤백이 잠기므로, 스크롤을
            // 화살표 키로 변환해 프로그램(less/vim)에 보내 자체 스크롤하게 한다(iTerm2/Terminal.app
            // 기본 동작). DECCKM이면 encodeKey가 자동으로 SS3 형식을 쓴다.
            const key: terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
            var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
            const bytes = core.encodeKey(.{ .key = key }, &buffer) catch return;
            var remaining: u32 = @abs(lines);
            while (remaining > 0) : (remaining -= 1) {
                // 입력 쓰기 실패(PTY 버퍼 풀 등)는 스크롤 입력 일부 드랍일 뿐이라 무시한다.
                self.runtime.writeInput(self.surfaces[0].id, .{ .bytes = bytes }) catch break;
            }
            return;
        }
        self.scroll(lines);
    }

    /// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면은 rows-1줄(한 줄 겹침)이고,
    /// rows는 dev session이 권위 있게 알고 있어 Swift가 stale 값으로 계산하지 않게 여기서 구한다.
    pub fn scrollPage(self: *DevSession, delta_pages: i32) void {
        if (!self.surface_initialized) return;
        const rows = self.surfaces[0].core.size.rows;
        const page: i32 = @max(@as(i32, 1), @as(i32, rows) - 1);
        self.scroll(delta_pages *| page);
    }

    pub fn resize(self: *DevSession, width_px: u32, height_px: u32, scale_milli: u32) !FrameSummary {
        // resize는 terminal grid와 PTY winsize가 함께 바뀌어야 한다. FrameLoop API를
        // 통해 SurfaceRuntime action으로 내려보내면 Swift가 두 책임을 다시 구현하지 않는다.
        // total_resize_events는 아래 dedup early-return 뒤(실제 변화가 있는 resize)에서만 센다.
        // Swift가 콜백마다 backing 픽셀을 보내므로, 같은 size+scale 중복은 카운트에 넣지 않는다.
        // scale_milli를 [250,8000]로 막아 손상된 값에서도 곱이 비정상으로 커지지 않게 한다.
        const next_scale = std.math.clamp(scale_milli, 250, 8000);
        const scale_changed = next_scale != self.scale_milli;
        // backing scale이 바뀌면(다른 DPI 디스플레이로 이동 등) cell 메트릭을 분수 scale로 먼저
        // 다시 뽑는다. grid 계산이 placeholder가 아니라 실제 cell 크기를 쓰도록 순서가 중요하다.
        if (scale_changed) {
            self.scale_milli = next_scale;
            self.refreshCellMetrics();
        }
        // grid(cols/rows)를 Swift가 아니라 dev session이 backing 픽셀 + 자기 cell 메트릭에서 직접
        // 계산한다. init이 메트릭을 미리 뽑으므로 cell 크기는 항상 준비돼 있어, Swift가 첫 resize에서
        // placeholder 크기로 cols/rows를 잘못 잡던(창과 grid가 어긋나던) 문제가 사라진다.
        const size = gridFromBacking(width_px, height_px, self.cell_width_px, self.cell_height_px);
        const size_changed = self.last_resize_size == null or
            self.last_resize_size.?.cols != size.cols or self.last_resize_size.?.rows != size.rows;
        // 같은 size+scale이면 비싼 재작업(TerminalCore.resize alloc/memcpy + PTY winsize/SIGWINCH)을
        // 건너뛴다. Swift의 windowDidResize·backing 콜백·tick 폴링이 한 변화에 여러 번 부를 수
        // 있는데, 매번 적용하면 셸이 SIGWINCH storm으로 다시 그린다(중복방지를 Swift가 아니라
        // 여기서 한 곳에서 처리).
        if (!scale_changed and !size_changed) {
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
            return self.last_summary;
        }
        // dedup을 통과한(실제 size/scale 변화가 있는) resize만 센다.
        self.total_resize_events += 1;
        // 종료된 세션의 resize도 live surface가 없어 실패한다. 닫히는 창의 late resize는
        // 치명적 오류가 아니므로 무시하고 정상으로 닫는다(key와 같은 정책).
        if (self.ended_seen) {
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
            return self.last_summary;
        }
        try self.frame_loop.resizeActiveSurface(size);
        self.last_resize_size = size;
        // grid가 reflow됐으므로 다음 tick이 Metal frame을 재투영하게 dirty로 표시한다.
        self.metal_dirty = true;
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
        return self.last_summary;
    }

    /// MARU_DEBUG일 때 활성 surface의 cell 격자를 찍는다. CJK 등 비-ASCII는 텍스트 줄에서
    /// 공백으로 보이지만 배경 줄(b...)의 'B'로 영역을 알 수 있어, 파란 배경 줄과 프롬프트 줄이
    /// 같은 row에 겹치는지(개행 안 됨) 다른 row인지 데이터로 구분한다.
    fn logScreenIfDebug(self: *DevSession) void {
        if (!diag_gate.maruDebugEnabled() or !self.surface_initialized) return;
        const core = &self.surfaces[0].core;
        const cols = @min(@as(usize, core.size.cols), 240);
        screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) ===", .{
            core.size.cols, core.size.rows, core.cursor.row, core.cursor.col,
        });
        var text: [240]u8 = undefined;
        var bg: [240]u8 = undefined;
        const grid_cols: usize = core.size.cols;
        for (0..core.size.rows) |row| {
            var any = false;
            for (0..cols) |col| {
                const cell = core.cells[row * grid_cols + col];
                const cp = cell.codepoint;
                text[col] = if (cp >= 0x20 and cp < 0x7f) @intCast(cp) else ' ';
                const has_bg = switch (cell.style.background) {
                    .default => false,
                    else => true,
                };
                bg[col] = if (has_bg) 'B' else '.';
                if ((cp != 0 and cp != ' ') or has_bg) any = true;
            }
            // soft-wrap 플래그를 함께 찍는다(w=다음 줄로 이어짐, .=hard 줄끝). reflow 피드백 루프
            // 회귀는 hard 줄(프롬프트)이 w로 잘못 찍히는 것으로 드러나므로, wrapped인 빈 줄도 보인다.
            const w_mark: u8 = if (row < core.wrapped.len and core.wrapped[row]) 'w' else '.';
            if (!any and w_mark != 'w') continue;
            screen_diag.info("r{d:0>2} {c} t|{s}|", .{ row, w_mark, text[0..cols] });
            screen_diag.info("r{d:0>2} {c} b|{s}|", .{ row, w_mark, bg[0..cols] });
        }
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
        // PTY queue를 non-blocking으로 비운다(output/exit 감지). 이 drain은 매 tick 필요하지만
        // 싸다. 생명주기 회계(이벤트 합산, 종료 reap)도 build 여부와 무관하게 매 tick 한다 —
        // Metal 투영이나 비싼 build가 실패/생략돼도 drained 이벤트나 finishAfterTermination
        // (reader join/child reap)을 건너뛰지 않게 한다.
        const drain_summary = try self.pump.drainAvailable();
        self.total_output_events += drain_summary.output_events;
        self.total_exit_events += drain_summary.exit_events;
        if (drain_summary.ended != null and !self.termination_finished) {
            self.ended_seen = true;
            self.live_pty.finishAfterTermination();
            self.termination_finished = true;
        }

        // 새 output이 있을 때만 frame이 바뀐다(resize는 resize()가 dirty를 세운다). idle tick은
        // 비싼 부분(buildDrawList + 전체 grid CoreText shape + atlas/raster 준비)을 통째로
        // 건너뛴다 — 출력 없는 셸이 매 30Hz tick마다 grid를 다시 shape하느라 CPU를 태우거나
        // 머신이 idle/sleep으로 못 들어가게 하지 않는다. generation도 그대로라 재드로우도 생략된다.
        // 가정: 모든 시각 변화는 PTY output(또는 resize)에서 온다. cursor blink나 주기적 redraw
        // 같은 PTY와 무관한 변화를 넣게 되면, 그 트리거에서도 metal_dirty를 세워야 한다.
        if (drain_summary.output_events > 0) self.metal_dirty = true;
        if (self.metal_dirty) {
            var tick_result = if (builtin.os.tag == .macos) blk: {
                const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
                    .appearance = self.appearance,
                    .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
                    .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
                    .scale_milli = self.scale_milli,
                    .cell_width_px = @intCast(self.cell_width_px),
                    .cell_height_px = @intCast(self.cell_height_px),
                };
                break :blk try self.frame_loop.tickAfterDrainWithFrameBuilder(drain_summary, frame_builder);
            } else try self.frame_loop.tickAfterDrain(drain_summary, renderer.FakeFontBackend{});
            defer tick_result.deinit(self.allocator);

            // Metal view 데이터 투영 실패(OOM 등)는 터미널 코어 동작과 무관하다. 마지막
            // frame을 유지하고 dirty를 남겨 다음 tick에 재시도한다(세션을 죽이지 않는다).
            const cell_colors: metal_frame.CellColors = .{
                .default_fg = self.appearance.theme.foreground,
                .default_bg = self.appearance.theme.background, // SGR reverse의 default 색 스왑용

                // 커서는 반전 블록으로 그린다: 칸 배경=theme.cursor, 그 위 glyph=theme.background.
                .cursor = .{
                    .block = self.appearance.theme.cursor,
                    .text = self.appearance.theme.background,
                },
            };
            if (self.metal_buffer.replace(self.allocator, tick_result.frame.render_frame, self.renderer_state.atlas.config, self.cell_width_px, self.cell_height_px, cell_colors)) |_| {
                self.metal_dirty = false;
            } else |_| {}

            // tick만 아는 per-frame render 통계와 tick index를 summary에 덧씌운다.
            self.writeSummaryFromTick(tick_result);
            self.logScreenIfDebug();
        } else {
            // idle: build/project를 건너뛰므로 summary는 마지막 frame render 통계를 그대로 둔다.
            self.writeSummaryFromState();
        }
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
        // PTY spawn winsize와 Surface의 TerminalCore grid가 같은 최소 크기를 쓰도록 clamp한다
        // (cols>=2). 안 그러면 cols=1 config에서 grid는 2칸(core가 clamp)인데 PTY winsize는 1칸이
        // 되어 셸과 어긋난다.
        .size = terminal.clampGridSize(.{ .cols = @intCast(config.cols), .rows = @intCast(config.rows) }),
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

test "gridFromBacking divides backing pixels by cell size with placeholder + clamps" {
    // 960×600 backing at 8×18 cell -> 120×33 (이전엔 Swift가 placeholder 12×24로 80×25를 잡아
    // 창과 grid가 어긋났다). 이제 dev session이 실제 메트릭으로 직접 계산한다.
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 33 }, gridFromBacking(960, 600, 8, 18));
    // cell 크기 0(메트릭 없음, 이론상) -> placeholder 12×24.
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 25 }, gridFromBacking(960, 600, 0, 0));
    // floor 동작 + 최소 1×1.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(25, 16, 10, 16));
    // cols는 최소 2(TerminalCore가 wide glyph continuation 때문에 요구). 1픽셀/100px cell이라도 2칸.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(1, 1, 100, 100));
}

test "wheelDeltaToLines accumulates sub-line trackpad deltas instead of dropping them" {
    var accum: f64 = 0;
    // cell 34px @2.0x -> 한 줄 17pt. 6pt씩 천천히 굴리면 3번째에 1줄이 나와야 한다(이전엔 전부 0).
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 1), wheelDeltaToLines(&accum, 6, true, 34, 2000));
    // 비정밀(휠)은 델타가 곧 줄 수.
    accum = 0;
    try std.testing.expectEqual(@as(i32, 3), wheelDeltaToLines(&accum, 3, false, 34, 2000));
    try std.testing.expectEqual(@as(i32, -2), wheelDeltaToLines(&accum, -2, false, 34, 2000));
    // NaN/∞는 무시.
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, std.math.nan(f64), true, 34, 2000));
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, std.math.inf(f64), false, 34, 2000));
}

test "scrollPage scrolls one screen (rows-1) per page using the core's authoritative rows" {
    var session: DevSession = undefined;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 5 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.metal_dirty = false;
    // 9줄 출력 -> 5행 화면 위로 4줄이 스크롤백에 쌓인다.
    try session.surfaces[0].core.write("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9");
    try std.testing.expectEqual(@as(usize, 4), session.surfaces[0].core.scrollbackLen());

    session.scrollPage(1); // 위로 한 화면 = rows-1 = 4줄
    try std.testing.expectEqual(@as(usize, 4), session.surfaces[0].core.view_offset);
    try std.testing.expect(session.metal_dirty);

    session.scrollPage(-1); // 아래로 한 화면 -> 바닥
    try std.testing.expectEqual(@as(usize, 0), session.surfaces[0].core.view_offset);
}
