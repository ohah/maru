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
const shell_integration = @import("shell_integration.zig");

// Metal DTO·view·owned 버퍼는 순수 모듈 metal_frame이 소유한다. ABI 표면으로 re-export만 한다.
pub const MetalCell = metal_frame.NativeMetalCell;
pub const MetalRasterUpload = metal_frame.NativeMetalRasterUpload;
pub const MetalFrame = metal_frame.MetalFrame;

pub const abi_version: u32 = 22;
pub const default_queue_capacity: u32 = 16;

// cell 메트릭이 아직 없을 때(이론상 init 전) grid 계산에 쓰는 placeholder cell 픽셀 크기.
// 실제로는 init이 refreshCellMetrics를 부르므로 resize 시점엔 항상 실제 메트릭이 있다.
const placeholder_cell_width_px: u32 = 12;
const placeholder_cell_height_px: u32 = 24;

// 커서 깜빡임 반주기(30Hz tick 단위). 15틱 = 500ms — 일반 터미널 관례(on 500ms / off 500ms).
const blink_interval_ticks: u32 = 15;

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
    // 시작 시 로드한 raw config(~/.config/maru/config). arena가 font.family 문자열을 소유하고,
    // resolve된 appearance.font.family가 그 슬라이스를 빌리므로 세션 동안 살아 있어야 한다.
    loaded_config: config_mod.ParsedConfig = undefined,
    // loaded_config가 실제로 초기화됐는지. init 초반(live/surface 생성)이 실패하면 deinit이 아직
    // undefined인 arena를 free하지 않도록, 다른 자원과 같은 *_initialized 가드 패턴을 쓴다.
    config_loaded: bool = false,
    // input.page-keys=scroll이면 메인 화면에서 PageUp/Down이 Maru 스크롤백을 스크롤한다. 기본
    // (false=passthrough)은 xterm/Ghostty처럼 \e[5~/\e[6~를 PTY로 보낸다.
    page_keys_scroll: bool = false,
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
    // copyText()가 돌려준 추출 텍스트의 소유 버퍼(다음 copyText/destroy까지 유효 — ABI 수명 계약).
    copy_buffer: []u8 = &.{},
    // urlAt()이 돌려준 URL의 소유 버퍼(다음 urlAt/destroy까지 유효).
    url_buffer: []u8 = &.{},
    // Cmd+hover 중인 URL 시작 셀의 절대 좌표(밑줄 렌더용). 뷰포트가 아니라 절대 좌표라 스크롤/출력
    // 으로 내용이 움직여도 따라간다(매 frame hoverLinkSpan이 현재 뷰포트로 클립).
    hover_url_anchor: ?terminal.SelectionPoint = null,
    // 현재 선택이 down(1) 드래그로 시작했는지. 더블/트리플클릭(4/5) 선택은 직후의 up(3)이
    // "이동 없는 클릭 -> 해제" 판정을 타면 안 되므로 이 플래그로 구분한다.
    mouse_drag_selecting: bool = false,
    // 드래그 자동 스크롤 방향(+1=위/과거, -1=아래, 0=없음). 드래그 좌표가 grid 위/아래 밖으로
    // 나가면 세워지고, 30Hz tick마다 한 줄 스크롤하며 선택을 가장자리 행으로 확장한다.
    drag_autoscroll: i8 = 0,
    // 자동 스크롤 중 선택 확장에 쓸 마지막 드래그 열.
    last_drag_col: u16 = 0,
    // 큰 붙여넣기의 미전송 잔여(인코딩 완료분). 자식이 stdin을 읽는 속도에 맞춰 tick마다
    // non-blocking으로 흘려보낸다 — 멀티MB 붙여넣기가 UI를 동결시키지 않게.
    pending_paste: std.ArrayList(u8) = .empty,
    pending_paste_offset: usize = 0,
    // IME 키 트랜잭션 상태(Ghostty의 keyTextAccumulator 패턴과 같은 구조). Swift keyDown이
    // imeBegin으로 열고 입력기 콜백(imeInsert/imeMarked)이 쌓은 것을 imeEnd가 일괄 판정한다 —
    // 콜백마다 즉석 판단하면 입력기의 비동기/다중 호출에서 이중 전송·유실이 생긴다(라이브에서
    // 실제 발생했던 클래스). 판정 로직이 Zig에 있어 전부 unit으로 고정된다.
    ime_active: bool = false,
    ime_inserted: std.ArrayList(u8) = .empty,
    ime_had_marked: bool = false,
    ime_marked_changed: bool = false,
    // 이번 키 트랜잭션에서 입력기가 deleteBackward 편집 명령을 보냈는지. 한글 마지막 자모
    // 백스페이스에서 입력기는 insertText(조합 글자) + deleteBackward를 같은 keyDown에 보내는데
    // (커밋 후 삭제 = net 0), 이게 있으면 확정 텍스트의 마지막 글자를 그 삭제가 상쇄한다.
    ime_did_delete: bool = false,
    // 이번 트랜잭션에서 imeInsert가 OOM으로 일부를 못 담았는지. 그러면 imeEnd는 잘린 텍스트를
    // 보내지 않고 통째로 버린다(fail-closed — 반쪽 문자열이 PTY에 들어가지 않게).
    ime_insert_failed: bool = false,
    // 커서 깜빡임 위상(DECSCUSR blink가 켜진 커서만). 30Hz tick 15회(=500ms)마다 토글하고,
    // 입력/출력이 있으면 보이는 상태로 리셋한다(타이핑 중 커서가 사라지지 않게).
    blink_visible: bool = true,
    blink_ticks: u32 = 0,

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

        // 사용자 config(~/.config/maru/config 또는 $MARU_CONFIG)를 가장 먼저 로드한다 — PTY를 띄울 때
        // 셸에 줄 TERM 값(`term =`)이 필요하기 때문이다(셸 설정/통합이 $TERM에 따라 키바인딩을 다르게
        // 잡는다). 단위 테스트에서는 개발자의 실제 config를 읽으면 비결정적이라 빈 config로 고정한다
        // (파싱 규칙은 loader 단위 테스트가 본다). loaded_config는 세션 동안 보관(family 슬라이스 빌림).
        // config_loaded 가드를 세워 이후 init 실패가 이 arena를 이중 해제하지 않게 한다.
        self.loaded_config = if (builtin.is_test)
            try config_mod.parseConfig(allocator, "")
        else
            try config_mod.loadConfigDefault(io, allocator);
        self.config_loaded = true;
        self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;

        // 셸 통합: 대화형 셸이 zsh면 macOS 편집키(Cmd+←/→ 등) 바인딩을 주입한다(사용자 .zshrc의
        // keymap 조건과 무관하게 동작하게). ZDOTDIR로 통합 .zshenv를 가리킨다. 실패 시 null(통합
        // 없이 정상 동작). dir 슬라이스는 spawn(EnvStorage가 dupe)까지만 필요하므로 init 끝에 해제.
        const integ_dir: ?[]const u8 = if (config.command_kind == .interactive_shell and
            shell_integration.detect(maru.pty.resolveInteractiveShell()) == .zsh)
            shell_integration.setupZsh(io, allocator)
        else
            null;
        defer if (integ_dir) |d| allocator.free(d);

        // Swift는 opaque handle만 보유하고, 이 구조체는 heap에 고정된다. LivePtySession의
        // reader thread가 `&live_pty.reader`를 잡고 돌기 때문에, 이 값을 만든 뒤에는
        // 절대 by-value로 이동하지 않는 것이 이번 ABI의 핵심 수명 계약이다.
        try self.live_pty.init(io, allocator, 10, spawnRequest(config, self.loaded_config.config.term, integ_dir), config.queue_capacity);
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
        // 로더가 모든 값을 valid-아니면-default로 걸러주므로 resolve는 사실상 실패하지 않지만,
        // 방어적으로 실패 시 기본값으로 떨어진다.(loaded_config는 위에서 PTY spawn 전에 로드했다.)
        self.appearance = config_mod.resolveAppearance(self.loaded_config.config) catch
            try config_mod.resolveAppearance(.{});
        // config의 무시된 줄(알 수 없는 key·잘못된 값)을 알린다 — 사용자가 오타를 눈치채게.
        for (self.loaded_config.diagnostics) |d| {
            std.log.scoped(.config).warn("config line {d}: {s}", .{ d.line, d.message });
        }
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
        // PageUp/PageDown는 메인 화면에선 Maru 스크롤백을 한 페이지씩 스크롤한다(Mac 네이티브 —
        // Terminal.app/iTerm2 동작). 셸의 기본 keymap엔 \e[5~/\e[6~가 unbound라, PTY로 보내면
        // zsh가 BEL을 울리고 남은 '~'를 입력줄에 그대로 박아 레이아웃이 깨진다(PTY 캡처로 확인:
        // \e[6~ -> 0x07 '~'). alt 화면(vim/less)에선 앱이 자체 페이징하므로 그대로 \e[5~/\e[6~를
        // 인코딩한다(아래 frame_loop 경로). 스크롤 키라 '타이핑하면 바닥으로' 로직보다 먼저 처리해
        // 매 PageUp마다 뷰가 바닥으로 튀지 않게 한다.
        if (self.surface_initialized) {
            const page_delta = pageScrollDelta(self.page_keys_scroll, self.surfaces[0].core.alt_active, event.key);
            if (page_delta != 0) {
                self.scrollPage(page_delta);
                self.total_app_key_events += 1; // 앱(터미널)이 소비 — PTY로 안 보냄
                self.writeSummaryFromState();
                self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
                return self.last_summary;
            }
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
                self.resetCursorBlink(); // 타이핑 중 커서가 사라지지 않게
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
        // 방향이 뒤집히면 1줄 미만 잔여를 버린다 — 이전 방향의 residue가 첫 반대 틱을 상쇄해
        // 방향 전환이 굼뜨게 느껴지는 것 방지(iTerm2/xterm.js 동작).
        if (std.math.isFinite(delta_y) and delta_y * self.wheel_accum < 0) self.wheel_accum = 0;
        const lines = wheelDeltaToLines(&self.wheel_accum, delta_y, precise, self.cell_height_px, self.scale_milli);
        self.scrollLines(lines);
    }

    /// 줄 수만큼 스크롤한다. alt screen + alternate scroll(DECSET 1007)이면 화살표 키로 변환해
    /// 프로그램(less/vim)에 보낸다(iTerm2/Terminal.app 동작, DECCKM이면 SS3 형식). 휠과
    /// Shift+PageUp/Down이 같은 경로를 타 일관되게 동작한다.
    fn scrollLines(self: *DevSession, lines: i32) void {
        if (lines == 0) return;
        const core = &self.surfaces[0].core;
        if (core.alt_active and core.alternate_scroll) {
            const key: terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
            var key_buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
            const bytes = core.encodeKey(.{ .key = key }, &key_buffer) catch return;
            // 시퀀스를 한 버퍼에 반복해 묶어 보낸다 — 줄마다 writeInput(쓰기 시스콜)을 하면 빠른
            // 플릭에서 초당 수백 회가 되고, PTY 버퍼가 차면 나머지가 통째로 드랍된다.
            var batch: [512]u8 = undefined;
            const per_batch = batch.len / bytes.len;
            var remaining: u32 = @abs(lines);
            while (remaining > 0) {
                const count = @min(remaining, @as(u32, @intCast(per_batch)));
                var len: usize = 0;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    @memcpy(batch[len..][0..bytes.len], bytes);
                    len += bytes.len;
                }
                // 쓰기 실패(PTY 버퍼 풀 등)는 남은 스크롤 입력 드랍일 뿐이라 중단한다.
                self.runtime.writeInput(self.surfaces[0].id, .{ .bytes = batch[0..len] }) catch break;
                remaining -= count;
            }
            return;
        }
        self.scroll(lines);
    }

    /// backing 픽셀 좌표를 (row, col) 셀로 변환한다(grid 안으로 clamp). 핵심: clamp를 float
    /// 도메인에서 먼저 한 뒤 @intFromFloat 한다 — 거대한 finite 좌표(손상/악성 입력)가 i64 변환
    /// 에서 trap(앱 패닉)하던 것을 막는다(wheelDeltaToLines와 같은 규율). 비유한값은 null.
    fn pxToCell(self: *const DevSession, x_px: f64, y_px: f64) ?struct { row: u16, col: u16 } {
        if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
        const core = &self.surfaces[0].core;
        const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        const max_col: f64 = @floatFromInt(core.size.cols - 1);
        const max_row: f64 = @floatFromInt(core.size.rows - 1);
        const col_f = std.math.clamp(@max(x_px, 0) / cw, 0, max_col);
        const row_f = std.math.clamp(@max(y_px, 0) / ch, 0, max_row);
        return .{ .row = @intFromFloat(row_f), .col = @intFromFloat(col_f) };
    }

    /// 마우스 선택. kind 1=down(선택 시작), 2=drag(확장), 3=up(확정 — 드래그 선택인데 이동이
    /// 없었으면 클릭으로 보고 해제), 4=더블클릭(단어 선택), 5=트리플클릭(논리 줄 선택). 좌표는
    /// backing 픽셀 — 셀 변환은 권위 있는 cell 메트릭을 가진 여기서 한다.
    pub fn mouse(self: *DevSession, kind: i32, x_px: f64, y_px: f64) void {
        if (!self.surface_initialized) return;
        const cell = self.pxToCell(x_px, y_px) orelse {
            // 비유한(NaN/Inf) 좌표 — 셀로 못 바꾼다. up(3)/down(1)이면 드래그 자동 스크롤을
            // 멈춘다(안 그러면 mouseUp이 좌표 손상으로 와도 autoscroll이 30Hz로 영원히 돈다).
            if (kind == 1 or kind == 3) {
                self.drag_autoscroll = 0;
                self.mouse_drag_selecting = false;
            }
            return;
        };
        const col = cell.col;
        const row = cell.row;
        const core = &self.surfaces[0].core;
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        switch (kind) {
            1 => {
                self.mouse_drag_selecting = true;
                self.drag_autoscroll = 0;
                core.selectionStart(row, col);
            },
            2 => {
                // 드래그가 grid 위/아래 밖으로 나가면 자동 스크롤을 건다(tick이 수행).
                const grid_height: f64 = @as(f64, @floatFromInt(core.size.rows)) * ch;
                self.drag_autoscroll = if (y_px < 0) 1 else if (y_px > grid_height) -1 else 0;
                self.last_drag_col = col;
                core.selectionExtend(row, col);
            },
            3 => {
                self.drag_autoscroll = 0;
                // 더블/트리플클릭 직후의 up은 그 선택을 건드리면 안 된다(단어가 1칸이면 "이동 없는
                // 클릭" 판정에 걸려 즉시 해제돼 버린다).
                if (!self.mouse_drag_selecting) return;
                self.mouse_drag_selecting = false;
                core.selectionExtend(row, col);
                // 이동 없는 클릭은 선택이 아니라 해제다(다른 터미널과 동일).
                if (core.selection_anchor) |a| {
                    if (core.selection_head != null and a.row == core.selection_head.?.row and a.col == core.selection_head.?.col) {
                        core.selectionClear();
                    }
                }
            },
            4 => {
                self.mouse_drag_selecting = false;
                core.selectWordAt(row, col);
            },
            5 => {
                self.mouse_drag_selecting = false;
                core.selectLineAt(row);
            },
            else => return,
        }
        self.metal_dirty = true;
    }

    /// 커서 깜빡임 한 스텝(30Hz tick마다). steady 커서(DECSCUSR 2/4/6)나 ?25l(숨김)이면 위상을
    /// 보이는 상태로 고정한다 — 토글 자체가 없으니 idle 재투영도 없다.
    fn updateCursorBlink(self: *DevSession) void {
        const core = &self.surfaces[0].core;
        // IME 조합 중에는 깜빡이지 않는다 — 커서가 preedit 끝에 고정 표시되어 조합 글자 옆에서
        // 반짝이지 않는다(Terminal.app/Ghostty와 같은 사용감).
        if (!core.cursor_blink or !core.cursor_visible or core.preedit != null) {
            self.resetCursorBlink();
            return;
        }
        self.blink_ticks += 1;
        if (self.blink_ticks >= blink_interval_ticks) {
            self.blink_ticks = 0;
            self.blink_visible = !self.blink_visible;
            // frame rebuild 없이 커서 suffix 노출만 토글한다(generation이 올라 Swift가 다시
            // 그린다). 500ms마다 full-grid reshape를 돌리지 않게 — idle 절전을 깨지 않는다.
            self.metal_buffer.setCursorVisible(self.blink_visible);
        }
    }

    /// 깜빡임을 보이는 위상으로 리셋한다(입력/출력 직후 — 커서가 항상 보이며 새 주기를 시작).
    fn resetCursorBlink(self: *DevSession) void {
        self.blink_ticks = 0;
        if (!self.blink_visible) {
            self.blink_visible = true;
            self.metal_buffer.setCursorVisible(true);
        }
    }

    /// 드래그 자동 스크롤 한 스텝(30Hz tick마다). 드래그가 grid 밖에 머무는 동안 한 줄씩
    /// 스크롤하며 선택을 가장자리 행으로 확장한다 — 화면보다 긴 내용을 드래그로 선택하는 표준 UX.
    fn applyDragAutoscroll(self: *DevSession) void {
        if (self.drag_autoscroll == 0) return;
        const core = &self.surfaces[0].core;
        // 게이트는 "확장할 선택이 있는가"다 — mouse_drag_selecting로 걸면 더블/트리플클릭(4/5)으로
        // 시작한 선택을 드래그로 화면 밖까지 늘릴 때 자동 스크롤이 영원히 안 걸린다.
        if (core.selection_anchor == null) return;
        const before_offset = core.view_offset;
        const before_head = core.selection_head;
        core.scrollViewport(@as(isize, self.drag_autoscroll));
        const row: u16 = if (self.drag_autoscroll > 0) 0 else core.size.rows - 1;
        core.selectionExtend(row, self.last_drag_col);
        // 변화가 없으면(스크롤백 끝/alt screen에서 잠겨 view도 head도 그대로) 재투영하지 않는다 —
        // 포인터를 grid 밖에 누른 채 둬도 30Hz full rebuild 루프가 돌지 않게.
        if (core.view_offset != before_offset or !pointEql(core.selection_head, before_head)) {
            self.metal_dirty = true;
        }
    }

    /// IME 키 트랜잭션 시작(Swift keyDown 진입 — 수정자 없는 키). 이번 키에서 입력기가 만들
    /// 텍스트/조합 변화를 모으기 시작한다.
    pub fn imeBegin(self: *DevSession) void {
        if (!self.surface_initialized) return;
        // 조합도 타이핑이다 — 과거를 보는 중이면 바닥으로 스냅해 preedit이 보이게 한다
        // (handleKeyEvent의 "입력하면 live 복귀"와 같은 동작; 조합 키는 그 경로를 안 타므로 여기서).
        if (self.surfaces[0].core.viewOffset() != 0) {
            self.surfaces[0].core.scrollToBottom();
            self.metal_dirty = true;
        }
        self.ime_active = true;
        self.ime_inserted.clearRetainingCapacity();
        self.ime_marked_changed = false;
        self.ime_did_delete = false;
        self.ime_insert_failed = false;
        self.ime_had_marked = self.surfaces[0].core.preedit != null;
    }

    /// 입력기가 확정한 텍스트(insertText). 즉시 보내지 않고 누적한다 — 전송 여부·시점은
    /// imeEnd가 일괄 판정한다(이중 전송 차단). 트랜잭션 밖(드물게 입력기가 keyDown 없이 직접
    /// 커밋 — 포커스 전환 등)이면 그대로 확정 전송한다.
    pub fn imeInsert(self: *DevSession, bytes: []const u8) void {
        if (!self.surface_initialized) return;
        if (!self.ime_active) {
            self.sendCommittedText(bytes);
            return;
        }
        self.ime_inserted.appendSlice(self.allocator, bytes) catch {
            self.ime_insert_failed = true; // imeEnd가 잘린 커밋을 보내지 않게
        };
    }

    /// 입력기의 조합 중(marked) 텍스트 갱신(빈 입력 = 조합 해제). 표시는 core 합성이 한다.
    pub fn imeMarked(self: *DevSession, bytes: []const u8) void {
        if (!self.surface_initialized) return;
        self.surfaces[0].core.setPreedit(bytes) catch return;
        self.metal_dirty = true; // 조합 글자는 즉시 보여야 한다
        if (self.ime_active) self.ime_marked_changed = true;
    }

    /// 입력기의 deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 하고 판정은 imeEnd가 한다.
    pub fn imeDeleteBackward(self: *DevSession) void {
        if (self.ime_active) self.ime_did_delete = true;
    }

    /// imeEnd의 순수 판정 결과. 부작용(PTY 전송)에서 분리해 라이브 PTY 없이 unit 테스트한다
    /// (Ghostty가 shouldSuppressComposingControlInput를 순수 함수로 테스트하는 것과 같은 방식).
    pub const ImeDecision = union(enum) {
        commit_text: []const u8, // 확정 텍스트만 전송(키 자체는 입력기가 소비)
        ignore, // 조합 조작 키(자모 삭제) / 조합 중 단일 C0 — 아무것도 안 보냄
        encode_key, // 일반 키 — 기존 인코딩 경로
    };

    /// IME 키의 일괄 판정(순수). 규칙(위에서 첫 일치):
    /// 1. 확정 텍스트가 쌓였으면 그것만 보낸다. 단 조합 중 단일 C0(조합 조작용 Ctrl+H류)은 버림.
    /// 2. 텍스트는 없지만 조합이 변했으면(자모 삭제) 키를 보내지 않는다.
    /// 3. 둘 다 아니면 일반 키.
    pub fn imeDecide(composing: bool, inserted: []const u8, marked_changed: bool, did_delete: bool) ImeDecision {
        if (inserted.len > 0) {
            const lone_c0 = inserted.len == 1 and inserted[0] < 0x20;
            if (composing and lone_c0) return .ignore;
            if (did_delete) {
                // insertText + deleteBackward가 한 keyDown에 왔다(한글 마지막 자모 백스페이스):
                // 입력기가 조합 글자를 커밋한 뒤 그 삭제를 보낸 것 — 삭제가 확정 텍스트의 마지막
                // 코드포인트를 상쇄한다. 남는 게 있으면 그만 커밋하고, 없으면 아무것도 안 보낸다
                // (PTY에 글자가 박혔다가 다음 BS로 지워야 하는 문제를 없앤다 — 실측 기반).
                const kept = dropLastCodepoint(inserted);
                if (kept.len == 0) return .ignore;
                return .{ .commit_text = kept };
            }
            return .{ .commit_text = inserted };
        }
        if (marked_changed) return .ignore;
        return .encode_key;
    }

    /// UTF-8 문자열에서 마지막 코드포인트를 뗀 슬라이스. continuation 바이트(0x80~0xBF)를 지나
    /// lead 바이트까지 되돌린다. 잘못된 UTF-8이면 1바이트만 뗀다(안전).
    fn dropLastCodepoint(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        var i: usize = s.len - 1;
        while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
        return s[0..i];
    }

    /// IME 키 트랜잭션 종료(Swift keyDown이 interpretKeyEvents 직후 호출) — 일괄 판정.
    /// 규칙(위에서부터 첫 일치):
    /// 1. 확정 텍스트가 쌓였으면 그것만 보낸다(키 자체는 입력기가 소비). 단 조합 중 단일
    ///    C0(예: 조합 조작용 Ctrl+H)는 입력기 소유라 버린다(Ghostty와 같은 보호).
    /// 2. 텍스트는 없지만 조합이 변했으면(자모 삭제 등) 키를 보내지 않는다 — 안 막으면 조합
    ///    중 Backspace가 자모도 줄이고 셸 글자까지 지운다(라이브에서 발생).
    /// 3. 둘 다 아니면 일반 키 — 기존 인코딩 경로(Enter/Backspace/기능키).
    /// IME 키 트랜잭션 종료. event가 null이면(정규화 불가 키 — 정의되지 않은 codepoint/keyCode)
    /// 트랜잭션은 그래도 닫고(누적 텍스트 커밋/조합 무시 판정), 일반 키 인코딩만 건너뛴다 —
    /// ime_begin 후 ime_end를 영영 안 닫아 ime_active가 박히고 누적 텍스트가 유실되던 누수를
    /// 막는다(라이브 회귀 클래스).
    pub fn imeEnd(self: *DevSession, event: ?terminal.KeyEvent) void {
        if (!self.surface_initialized) return;
        const composing = self.surfaces[0].core.preedit != null or self.ime_had_marked;
        defer {
            self.ime_active = false;
            self.ime_inserted.clearRetainingCapacity();
            self.ime_marked_changed = false;
            self.ime_did_delete = false;
            self.ime_insert_failed = false;
        }
        // OOM으로 누적이 잘렸으면 통째로 버린다 — 반쪽 문자열을 PTY에 보내지 않는다(#14).
        if (self.ime_insert_failed) return;
        switch (imeDecide(composing, self.ime_inserted.items, self.ime_marked_changed, self.ime_did_delete)) {
            .commit_text => |text| {
                self.sendCommittedText(text);
                // 한글 후보를 화살표로 확정하는 경우(insertText('안') + 화살표): 텍스트만 보내고
                // 화살표를 버리면 커서가 안 움직인다. 확정 후 그 화살표를 다시 보낸다(Ghostty
                // shouldReplayCommittedPreeditKey와 같은 의미론 — 위/오른/아래는 항상, 왼쪽은
                // 수정자 있을 때만; plain 왼쪽은 AppKit이 이미 커서를 제자리에 둬 중복 이동 방지).
                if (event) |ev| if (shouldReplayAfterCommit(ev)) {
                    _ = self.handleKeyEvent(ev) catch {};
                };
            },
            .ignore => {}, // 조합 조작 키(자모 삭제) 또는 조합 중 단일 C0 — 입력기 소유
            .encode_key => if (event) |ev| {
                _ = self.handleKeyEvent(ev) catch {};
            },
        }
    }

    /// 한글 후보를 확정시키며 함께 온 키를 확정 후 다시 보낼지(Ghostty 정책 동작 비교).
    fn shouldReplayAfterCommit(event: terminal.KeyEvent) bool {
        return switch (event.key) {
            .arrow_up, .arrow_right, .arrow_down => true,
            .arrow_left => event.modifiers.shift or event.modifiers.control or
                event.modifiers.option or event.modifiers.command,
            else => false,
        };
    }

    /// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점 — 마우스 좌표와 같은 규약).
    /// 입력기가 firstRect로 물어보면 Swift가 이 값을 화면 좌표로 바꿔 후보창을 커서 위치에
    /// 띄운다. 조합 중에는 커서가 preedit 시작(core.cursor)에 있어 후보창이 조합 글자 옆에 뜬다.
    /// 반환: row*cell_h, col*cell_w, cell_w, cell_h.
    pub fn imeCursorRect(self: *const DevSession) struct { x: f64, y: f64, w: f64, h: f64 } {
        const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        if (!self.surface_initialized) return .{ .x = 0, .y = 0, .w = cw, .h = ch };
        const cursor = self.surfaces[0].core.cursor;
        return .{
            .x = @as(f64, @floatFromInt(cursor.col)) * cw,
            .y = @as(f64, @floatFromInt(cursor.row)) * ch,
            .w = cw,
            .h = ch,
        };
    }

    /// 진행 중인 IME 조합(preedit)을 확정(커밋)한다 — 조합 글자를 PTY로 보내고 preedit을 비운다.
    /// 포커스 상실(setFocused)과, IME를 우회하는 특수키/단축키(PageUp 등) '직전'에 호출해 Swift의
    /// marked text와 core의 preedit·화면이 어긋나지 않게 한다. 조합이 없으면 무동작.
    pub fn commitComposition(self: *DevSession) void {
        if (!self.surface_initialized) return;
        const core = &self.surfaces[0].core;
        if (core.preedit) |pending| {
            // setPreedit가 버퍼를 해제하므로 먼저 사본을 떠서 보낸다.
            const copy = self.allocator.dupe(u8, pending) catch return;
            defer self.allocator.free(copy);
            core.setPreedit("") catch {};
            self.metal_dirty = true;
            self.sendCommittedText(copy);
        }
    }

    /// 포커스 변화. 잃으면 조합 중 텍스트를 버리지 않고 확정(커밋)한다 — 버리면 글자가
    /// 사라졌다가 재포커스 후 입력 위치가 어긋나는 사용감(라이브 제보)이 된다.
    /// Terminal.app/Ghostty와 같은 의미론.
    pub fn setFocused(self: *DevSession, focused: bool) void {
        if (!self.surface_initialized) return;
        if (focused) return;
        self.commitComposition();
    }

    /// 확정 텍스트를 코드포인트 단위로 기존 key event 경로에 태운다 — 인코딩 단일 출처
    /// (encodeKey)와 입력 회계(terminal_input 카운터)를 유지한다.
    fn sendCommittedText(self: *DevSession, bytes: []const u8) void {
        const view = std.unicode.Utf8View.init(bytes) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // 개행은 .enter로 보낸다(\r로 인코딩) — Services/받아쓰기 등 멀티라인 insertText가
            // LF를 그대로 PTY에 넣으면 셸 line discipline이 어긋난다(paste 경로와 같은 규칙).
            const key: terminal.input.Key = if (cp == '\n' or cp == '\r')
                .enter
            else
                (terminal.input.charKeyFromCodepoint(cp) catch continue);
            _ = self.handleKeyEvent(.{ .key = key, .modifiers = .{} }) catch return;
        }
    }

    /// 클립보드 텍스트 붙여넣기(Cmd+V). 인코딩(개행 정규화 + bracketed paste 감싸기)은 core가
    /// 하고, 여기선 한 번의 writeInput으로 보낸다(부분 쓰기 실패로 감싸기가 깨지지 않게).
    pub fn pasteText(self: *DevSession, bytes: []const u8) void {
        if (!self.surface_initialized or bytes.len == 0) return;
        const encoded = self.surfaces[0].core.encodePaste(self.allocator, bytes) catch return;
        defer self.allocator.free(encoded);
        // 큐에 쌓고 즉시 flush를 시도한다. 자식이 읽는 중이면 보통 이 자리에서 다 들어가고,
        // 안 읽으면(vim 다이얼로그 등) 잔여가 tick마다 흘러나간다 — blocking 단일 write로 UI가
        // 동결되던 것을 없앤다. 큐는 FIFO라 bracketed paste 감싸기 순서는 깨지지 않는다.
        self.pending_paste.appendSlice(self.allocator, encoded) catch return;
        self.flushPendingPaste();
    }

    /// pending paste를 지금 쓸 수 있는 만큼 non-blocking으로 흘려보낸다(0이 나오면 다음 tick).
    fn flushPendingPaste(self: *DevSession) void {
        while (self.pending_paste_offset < self.pending_paste.items.len) {
            const remaining = self.pending_paste.items[self.pending_paste_offset..];
            const written = self.runtime.writeInputNonBlocking(self.surfaces[0].id, remaining) catch {
                // 세션 종료 등 — 잔여는 버린다(다시 쓸 수 없는 대상).
                self.pending_paste.clearRetainingCapacity();
                self.pending_paste_offset = 0;
                return;
            };
            if (written == 0) return; // PTY 버퍼가 찼다 — 다음 tick에 이어서
            self.pending_paste_offset += written;
        }
        self.pending_paste.clearRetainingCapacity();
        self.pending_paste_offset = 0;
    }

    /// Cmd+hover 갱신. cmd_held가 아니거나 URL이 아니면 hover를 해제한다. URL 위면 밑줄 범위를
    /// 저장하고 true를 돌려준다 — Swift가 이 값으로 마우스 커서(pointingHand)를 정한다.
    pub fn hoverUrl(self: *DevSession, x_px: f64, y_px: f64, cmd_held: bool) bool {
        if (!self.surface_initialized) return false;
        var next: ?terminal.SelectionPoint = null;
        if (cmd_held) {
            if (self.pxToCell(x_px, y_px)) |cell| {
                const core = &self.surfaces[0].core;
                // URL이면 그 시작 셀의 절대 좌표를 저장한다(뷰포트 좌표가 아님) — 스크롤/출력으로
                // 내용이 움직여도 밑줄이 내용을 따라가고, 좁아진 폭에서도 매 frame 뷰포트로 다시
                // 클립(아래 hoverLinkSpan)되므로 stale·OOB가 안 생긴다.
                if (core.urlAnchorAt(cell.row, cell.col)) |anchor| next = anchor;
            }
        }
        const changed = !pointEql(self.hover_url_anchor, next);
        self.hover_url_anchor = next;
        if (changed) self.metal_dirty = true; // 밑줄이 생기거나 사라지면 다시 그린다
        return next != null;
    }

    /// hover URL의 현재 뷰포트 밑줄 범위. 매 frame 절대 좌표 anchor에서 다시 계산해 클립하므로
    /// 스크롤·출력·resize 후에도 항상 현재 폭/위치에 맞는다(stale 좌표 OOB 차단).
    pub fn hoverLinkSpan(self: *DevSession) ?terminal.SelectionSpan {
        const anchor = self.hover_url_anchor orelse return null;
        return self.surfaces[0].core.urlSpanAtAbs(anchor);
    }

    fn pointEql(a: ?terminal.SelectionPoint, b: ?terminal.SelectionPoint) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.meta.eql(a.?, b.?);
    }

    /// Cmd+클릭 위치의 URL(없으면 빈 슬라이스). Swift가 NSWorkspace로 연다 — URL 인식(단어 경계,
    /// soft-wrap 이어 붙임, http(s) 검사, 끝 문장부호 다듬기)은 core가 소유한다.
    pub fn urlAt(self: *DevSession, x_px: f64, y_px: f64) []const u8 {
        if (!self.surface_initialized) return &.{};
        if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return &.{};
        const core = &self.surfaces[0].core;
        const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        const col: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@max(x_px, 0) / cw)), 0, @as(i64, core.size.cols) - 1));
        const row: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@max(y_px, 0) / ch)), 0, @as(i64, core.size.rows) - 1));
        if (self.url_buffer.len > 0) {
            self.allocator.free(self.url_buffer);
            self.url_buffer = &.{};
        }
        const url = core.extractUrlAt(self.allocator, row, col) catch null orelse return &.{};
        self.url_buffer = url;
        return self.url_buffer;
    }

    /// 선택 텍스트를 추출해 내부 버퍼로 돌려준다(없으면 빈 슬라이스). Swift가 NSPasteboard에 쓴다.
    pub fn copyText(self: *DevSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        if (self.copy_buffer.len > 0) {
            self.allocator.free(self.copy_buffer);
            self.copy_buffer = &.{};
        }
        const extracted = self.surfaces[0].core.extractSelection(self.allocator) catch null orelse return &.{};
        self.copy_buffer = extracted;
        return self.copy_buffer;
    }

    /// OSC 7로 셸이 보고한 현재 cwd(percent-decode된 경로). 한 번도 안 받았으면 빈 슬라이스.
    /// 반환은 core 소유로 다음 OSC 7/RIS/destroy까지 유효하다(별도 복사 없음 — native 최소).
    /// Swift가 창 제목에 쓴다.
    pub fn currentCwd(self: *DevSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        return self.surfaces[0].core.currentCwd();
    }

    /// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면은 rows-1줄(한 줄 겹침)이고,
    /// rows는 dev session이 권위 있게 알고 있어 Swift가 stale 값으로 계산하지 않게 여기서 구한다.
    /// alt screen에서는 휠과 동일하게 화살표 변환으로 폴백한다(이전엔 완전 무반응이었다).
    /// 메인 화면에서 PageUp/PageDown를 스크롤백 페이지 스크롤로 돌릴 때의 페이지 델타
    /// (+1=위/과거, -1=아래/현재). scroll_mode(input.page-keys=scroll)가 아니거나 alt 화면이거나
    /// page 키가 아니면 0 — 그땐 일반 인코딩 경로로 보내 앱(vim/less)이 \e[5~/\e[6~로 페이징하거나,
    /// 셸이 그대로 받는다. 기본(passthrough)은 xterm/Ghostty와 일치, scroll은 Terminal.app/iTerm2식.
    fn pageScrollDelta(scroll_mode: bool, alt_active: bool, key: terminal.input.Key) i32 {
        if (!scroll_mode or alt_active) return 0;
        return switch (key) {
            .page_up => 1,
            .page_down => -1,
            else => 0,
        };
    }

    pub fn scrollPage(self: *DevSession, delta_pages: i32) void {
        if (!self.surface_initialized) return;
        const rows = self.surfaces[0].core.size.rows;
        const page: i32 = @max(@as(i32, 1), @as(i32, rows) - 1);
        self.scrollLines(delta_pages *| page);
    }

    /// 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트를 점프한다(OSC 133 셸 통합 필요 — Cmd+↑/↓).
    /// 분류·이동 로직은 core가 소유하고, 여기선 스크롤됐으면 다음 tick이 다시 그리도록 metal_dirty만
    /// 세운다(Swift는 방향만 넘기는 얇은 글루 — scrollPage와 같은 규율).
    pub fn jumpToPrompt(self: *DevSession, dir: i8) void {
        if (!self.surface_initialized) return;
        if (self.surfaces[0].core.jumpToPrompt(dir)) self.metal_dirty = true;
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
        // 헤더에 OSC 133 마지막 명령 종료코드도 찍는다(셸 통합이 emit하면 채워진다).
        if (core.last_command_exit) |code| {
            screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) last_exit={d} ===", .{
                core.size.cols, core.size.rows, core.cursor.row, core.cursor.col, code,
            });
        } else {
            screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) ===", .{
                core.size.cols, core.size.rows, core.cursor.row, core.cursor.col,
            });
        }
        // OSC 7로 셸이 보고한 cwd(셸 통합이 emit하면 채워진다). 창 제목이 읽는 값을 데이터로 확인.
        const cwd = core.currentCwd();
        if (cwd.len > 0) screen_diag.info("cwd={s}", .{cwd});
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
            // OSC 133 semantic 분류(P=프롬프트 I=입력 C=명령출력 ·=미분류). 셸 통합이 마커를 emit하면
            // 채워진다 — 프롬프트/입력/출력이 어떤 행으로 잡히는지 데이터로 본다(거터 PR 전 조기 확인).
            const p_mark: u8 = if (row < core.prompt_marks.len) switch (core.prompt_marks[row].kind) {
                .unknown => '.',
                .prompt => 'P',
                .input => 'I',
                .command => 'C',
            } else '.';
            if (!any and w_mark != 'w' and p_mark == '.') continue;
            screen_diag.info("r{d:0>2} {c}{c} t|{s}|", .{ row, w_mark, p_mark, text[0..cols] });
            screen_diag.info("r{d:0>2} {c}{c} b|{s}|", .{ row, w_mark, p_mark, bg[0..cols] });
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
        self.applyDragAutoscroll(); // 드래그가 grid 밖에 머무는 동안 30Hz로 한 줄씩 스크롤+확장
        self.flushPendingPaste(); // 큰 붙여넣기의 잔여를 자식이 읽는 속도에 맞춰 흘려보낸다
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
        // 깜빡임: 출력이 흐르면 보이는 위상으로 리셋(커서가 움직이는 동안 항상 보이게), idle이면
        // 500ms마다 토글. steady/숨김 커서는 updateCursorBlink가 무토글로 고정한다.
        if (drain_summary.output_events > 0) self.resetCursorBlink() else self.updateCursorBlink();
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
                .selection_bg = self.appearance.theme.selection,
                .selection = self.surfaces[0].core.selectionViewportSpan(),
                .hover_link = self.hoverLinkSpan(),

                // 커서는 반전 블록으로 그린다: 칸 배경=theme.cursor, 그 위 glyph=theme.background.
                // blink와 무관하게 항상 투영한다 — off 위상 숨김은 metal_buffer가 커서 suffix 노출
                // 길이로 처리해(setCursorVisible) frame rebuild가 필요 없다.
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
        if (self.copy_buffer.len > 0) self.allocator.free(self.copy_buffer);
        if (self.url_buffer.len > 0) self.allocator.free(self.url_buffer);
        self.pending_paste.deinit(self.allocator);
        self.ime_inserted.deinit(self.allocator);

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
        // appearance가 family를 빌리므로 surface 정리 뒤에 해제. 가드로 init 초반 실패 시 undefined
        // arena를 free하지 않게(다른 자원과 같은 패턴).
        if (self.config_loaded) {
            self.loaded_config.deinit();
            self.config_loaded = false;
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

fn spawnRequest(config: NormalizedConfig, term: []const u8, zdotdir: ?[]const u8) maru.pty.SpawnRequest {
    var request: maru.pty.SpawnRequest = switch (config.command_kind) {
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
            // login shell로 띄운다(macOS backend가 login(1)으로 감싼다 — Terminal.app·Ghostty와
            // 동일하게 전체 로그인 세션 셋업). PATH·EDITOR·키바인딩 등 사용자 환경이 완전히 잡힌다.
            // controlled_smoke(/bin/sh -c)는 login이 아니다.
            .login = true,
            .size = config.size,
        },
    };
    // 사용자 config의 TERM을 셸에 준다(기본 xterm-256color). env는 빈 채로 둬 부모 상속 +
    // TERM/COLORTERM override 경로를 타게 한다. zdotdir이 있으면 셸 통합용 ZDOTDIR을 주입한다.
    request.term = term;
    request.zdotdir = zdotdir;
    return request;
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

test "commitComposition is a safe no-op when there is no active preedit" {
    // 조합이 없으면(preedit==null) 아무것도 안 보내고 무해해야 한다 — IME 우회 특수키(PageUp)마다
    // 호출되므로 일반 타이핑 경로를 망가뜨리면 안 된다. commit 경로(preedit 있을 때)는 frame_loop가
    // 필요해 헤드리스로 못 돌리고 GUI 수동 검증으로 본다(PR 본문).
    var session: DevSession = undefined;
    session.allocator = std.testing.allocator;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.metal_dirty = false;
    try std.testing.expect(session.surfaces[0].core.preedit == null);
    session.commitComposition(); // 무동작이어야(no preedit)
    try std.testing.expect(session.surfaces[0].core.preedit == null);
    try std.testing.expect(!session.metal_dirty); // 보낼 게 없으니 다시 그릴 것도 없다
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

test "wheelDeltaToLines drops sub-line residue when the scroll direction flips" {
    var accum: f64 = 0;
    // 위로 0.9줄 잔여를 만든다(6pt×2 @ 17pt/줄 — 아래 scrollWheel의 방향 리셋과 짝).
    _ = wheelDeltaToLines(&accum, 6, true, 34, 2000);
    _ = wheelDeltaToLines(&accum, 6, true, 34, 2000);
    try std.testing.expect(accum > 0.5);
    // 방향 반전 잔여 리셋은 scrollWheel이 수행한다 — 여기선 그 계약(잔여가 반대 틱을 상쇄하면
    // 첫 반응이 사라짐)을 수치로 고정한다: 리셋 없이 -6pt를 주면 0줄이 나온다(굼뜬 반전).
    try std.testing.expectEqual(@as(i32, 0), wheelDeltaToLines(&accum, -6, true, 34, 2000));
}

test "drag autoscroll scrolls one line per tick and extends the selection to the edge row" {
    var session: DevSession = undefined;
    session.allocator = std.testing.allocator;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.metal_dirty = false;
    session.mouse_drag_selecting = true;
    session.drag_autoscroll = 0;
    session.last_drag_col = 1;
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.scale_milli = 1000;

    const core = &session.surfaces[0].core;
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백 2(a,b) + 화면 c,d
    core.selectionStart(1, 0); // 화면 행1(d)에서 드래그 시작

    // 드래그가 grid 위 밖으로(y<0) — kind 2가 자동 스크롤 방향을 세운다.
    session.mouse(2, 0.0, -5.0); // col 0, grid 위 밖
    try std.testing.expectEqual(@as(i8, 1), session.drag_autoscroll);

    session.applyDragAutoscroll(); // tick 1: 한 줄 위로 + 선택이 뷰 최상단으로 확장
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    session.applyDragAutoscroll(); // tick 2: 맨 위까지
    try std.testing.expectEqual(@as(usize, 2), core.view_offset);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // 선택이 a(맨 위)까지 닿았다.
    try std.testing.expectEqualStrings("a\nb\nc\nd", text);

    // up(3)이 자동 스크롤을 멈춘다.
    session.mouse(3, 8.0, 8.0);
    try std.testing.expectEqual(@as(i8, 0), session.drag_autoscroll);
}

test "cursor blink toggles every interval, stays solid for steady cursors, and resets on activity" {
    var session: DevSession = undefined;
    session.allocator = std.testing.allocator;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.metal_dirty = false;
    session.metal_buffer = .{};
    session.blink_visible = true;
    session.blink_ticks = 0;

    // 기본(DECSCUSR 1 = 깜빡 block): interval 틱마다 토글. rebuild(metal_dirty) 없이 metal
    // generation만 올라야 한다(커서 suffix 노출 토글).
    var i: u32 = 0;
    while (i < blink_interval_ticks) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(!session.blink_visible);
    try std.testing.expect(!session.metal_dirty);
    try std.testing.expectEqual(@as(u64, 1), session.metal_buffer.generation);
    try std.testing.expect(!session.metal_buffer.show_cursor);
    while (i < blink_interval_ticks * 2) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);

    // 입력/출력 리셋: off 위상이어도 즉시 보이게.
    session.blink_visible = false;
    session.blink_ticks = 7;
    session.resetCursorBlink();
    try std.testing.expect(session.blink_visible);
    try std.testing.expectEqual(@as(u32, 0), session.blink_ticks);

    // steady 커서(DECSCUSR 2): 토글하지 않고 보이는 위상 고정.
    try session.surfaces[0].core.write("\x1b[2 q");
    session.blink_visible = true;
    i = 0;
    while (i < blink_interval_ticks * 3) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);

    // IME 조합 중(preedit): 깜빡이지 않고 보이는 위상 고정 — 조합 글자 옆에서 반짝이지 않는다.
    try session.surfaces[0].core.write("\x1b[1 q"); // 다시 blink 커서로
    try session.surfaces[0].core.setPreedit("\xec\x95\x88");
    session.blink_visible = true;
    i = 0;
    while (i < blink_interval_ticks * 3) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);
    try session.surfaces[0].core.setPreedit("");
}

test "headless ticks toggle the blink phase and bump the metal generation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실제 CoreText frame builder 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(DevSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 출력 타이밍에 흔들리지 않게(느린 CI에서 controlled 출력이 여러 tick에 걸쳐 와 위상을
    // 계속 리셋할 수 있다) "첫 토글이 관측될 때까지" 충분한 상한으로 tick한다 — 출력은 유한하니
    // 멎은 뒤 interval 틱이 지나면 반드시 토글된다.
    var toggles: usize = 0;
    var gen_changes: usize = 0;
    var last_vis = session.blink_visible;
    var last_gen: u64 = session.metal_buffer.generation;
    var i: usize = 0;
    while (i < blink_interval_ticks * 20 and toggles == 0) : (i += 1) {
        _ = try session.tick();
        if (session.blink_visible != last_vis) {
            toggles += 1;
            last_vis = session.blink_visible;
        }
        if (session.metal_buffer.generation != last_gen) {
            gen_changes += 1;
            last_gen = session.metal_buffer.generation;
        }
    }
    try std.testing.expect(toggles >= 1);
    // 토글은 rebuild 없이도 재드로우를 유발해야 한다(setCursorVisible의 generation 증가).
    try std.testing.expect(gen_changes >= toggles);
}

test "drag autoscroll works after a double-click word selection and skips redraw when nothing moves" {
    var session: DevSession = undefined;
    session.allocator = std.testing.allocator;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.metal_dirty = false;
    session.metal_buffer = .{};
    session.mouse_drag_selecting = false; // 더블클릭(kind 4) 후 상태
    session.drag_autoscroll = 0;
    session.last_drag_col = 0;
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.scale_milli = 1000;

    const core = &session.surfaces[0].core;
    try core.write("aa\r\nbb\r\ncc"); // 스크롤백 1(aa) + 화면 bb,cc
    core.selectWordAt(1, 0); // 더블클릭 단어 선택(cc)
    try std.testing.expect(core.selection_anchor != null);

    // 더블클릭 직후 드래그가 grid 위 밖으로 — mouse_drag_selecting=false여도 autoscroll이 돈다.
    session.mouse(2, 0.0, -5.0);
    try std.testing.expectEqual(@as(i8, 1), session.drag_autoscroll);
    session.applyDragAutoscroll();
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try std.testing.expect(session.metal_dirty);

    // 더 갈 곳이 없으면(스크롤백 끝 + head 그대로) 재투영을 걸지 않는다 — 30Hz 루프 방지.
    session.metal_dirty = false;
    session.applyDragAutoscroll();
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try std.testing.expect(!session.metal_dirty);
}

test "large paste drains through the non-blocking queue without freezing ticks" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실제 PTY 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(DevSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // PTY 입력 버퍼보다 큰 페이로드 — blocking 단일 write라면 여기서 동결됐을 크기. 개행을
    // 포함한 줄 단위로 만든다: controlled 자식(read -r line)은 canonical 모드라 개행 없는
    // 대용량은 줄을 영영 못 끝내 read에 갇히고, deinit의 자식 reap(wait4)이 hang된다 — 첫
    // 줄이 들어가면 자식이 진행해 정상 종료한다.
    const big = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    var li: usize = 79;
    while (li < big.len) : (li += 80) big[li] = '\n';
    session.pasteText(big);

    // pasteText는 즉시 반환해야 하고(동결 없음), 잔여는 tick들이 흘려보낸다.
    var i: usize = 0;
    while (i < 600 and session.pending_paste.items.len > session.pending_paste_offset) : (i += 1) {
        _ = try session.tick();
    }
    // 자식(read 대기 중)이 소비하므로 결국 큐가 빈다.
    try std.testing.expectEqual(session.pending_paste_offset, session.pending_paste.items.len);
}

test "imeDecide routes IME keys: commit text once, ignore composition edits, encode plain keys" {
    const D = DevSession.ImeDecision;
    // 1) 확정 텍스트가 있으면 그것만 보낸다(키는 입력기 소비 — 조합 확정 Enter는 개행 없음).
    try std.testing.expect(DevSession.imeDecide(true, "\xec\x95\x88", false, false) == .commit_text);
    try std.testing.expectEqualStrings("\xec\x95\x88", DevSession.imeDecide(true, "\xec\x95\x88", false, false).commit_text);
    // 2) 텍스트 없이 조합만 변하면(자모 삭제) 키 무전송.
    try std.testing.expect(DevSession.imeDecide(true, "", true, false) == .ignore);
    // 3) 조합 중 단일 C0(조합 조작용 Ctrl+H류)은 버린다.
    try std.testing.expect(DevSession.imeDecide(true, "\x08", false, false) == .ignore);
    // 4) 조합 아닐 때의 C0는 정상 텍스트로 본다(commit) — 조합 보호는 composing일 때만.
    try std.testing.expect(DevSession.imeDecide(false, "\x08", false, false) == .commit_text);
    // 5) 텍스트도 조합 변화도 없으면 일반 키(Enter/Backspace/기능키).
    try std.testing.expect(DevSession.imeDecide(false, "", false, false) == .encode_key);
    // 6) 여러 글자 확정도 통째로 commit(영문 일반 타이핑 포함).
    try std.testing.expectEqualStrings("ab", DevSession.imeDecide(false, "ab", false, false).commit_text);
    // 7) 마지막 자모 백스페이스: insertText("ㄴ") + deleteBackward 상쇄 -> 아무것도 안 보냄
    //    (실측: 가나->BS->가ㄴ->BS->가. ㄴ이 PTY에 박히지 않는다).
    try std.testing.expect(DevSession.imeDecide(true, "\xe3\x84\xb4", false, true) == .ignore); // "ㄴ"
    // 8) 다중 글자 insert + 삭제: 마지막 코드포인트만 상쇄, 나머지는 commit.
    try std.testing.expectEqualStrings("a", DevSession.imeDecide(false, "ab", false, true).commit_text);
    _ = D;
}

test "imeEnd always closes the transaction even with a null key (no leak) and fails closed on OOM" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(DevSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // null 키로 닫아도 트랜잭션이 닫히고(ime_active=false), 누적 텍스트는 커밋된다.
    session.imeBegin();
    session.imeInsert("\xec\x95\x88"); // '안'
    const before = session.total_terminal_input_bytes;
    session.imeEnd(null); // 정규화 불가 키
    try std.testing.expect(!session.ime_active);
    try std.testing.expectEqual(before + 3, session.total_terminal_input_bytes);

    // OOM 플래그면 커밋을 통째로 버린다(잘린 문자열 방지).
    session.imeBegin();
    session.imeInsert("ab");
    session.ime_insert_failed = true;
    const before2 = session.total_terminal_input_bytes;
    session.imeEnd(.{ .key = .{ .char = 'x' }, .modifiers = .{} });
    try std.testing.expectEqual(before2, session.total_terminal_input_bytes);
    try std.testing.expect(!session.ime_active);
}

test "shouldReplayAfterCommit: arrows replay after candidate commit (left only when modified)" {
    try std.testing.expect(DevSession.shouldReplayAfterCommit(.{ .key = .arrow_right, .modifiers = .{} }));
    try std.testing.expect(DevSession.shouldReplayAfterCommit(.{ .key = .arrow_down, .modifiers = .{} }));
    try std.testing.expect(DevSession.shouldReplayAfterCommit(.{ .key = .arrow_up, .modifiers = .{} }));
    try std.testing.expect(!DevSession.shouldReplayAfterCommit(.{ .key = .arrow_left, .modifiers = .{} }));
    try std.testing.expect(DevSession.shouldReplayAfterCommit(.{ .key = .arrow_left, .modifiers = .{ .shift = true } }));
    try std.testing.expect(!DevSession.shouldReplayAfterCommit(.{ .key = .enter, .modifiers = .{} }));
}

test "sendCommittedText normalizes newlines to CR and imeBegin snaps to bottom" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(DevSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const core = &session.surfaces[0].core;

    // 스크롤백을 만들고 과거를 본 뒤 imeBegin → 바닥으로 스냅(조합이 보이게).
    try core.write("a\r\nb\r\nc\r\nd\r\ne\r\nf");
    core.scrollViewport(3);
    try std.testing.expect(core.viewOffset() != 0);
    session.imeBegin();
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    session.imeEnd(null);

    // 멀티라인 확정 텍스트의 \n이 \r로 정규화돼 PTY에 들어간다(LF 아님).
    // (controlled 셸의 read가 \r에 반응하도록 — 바이트 카운트만 확인: "a\nb" → 'a',\r,'b' = 3바이트)
    const before = session.total_terminal_input_bytes;
    session.imeBegin();
    session.imeInsert("a\nb");
    session.imeEnd(null);
    try std.testing.expectEqual(before + 3, session.total_terminal_input_bytes);
}

test "imeCursorRect returns the cursor cell rect in backing px for IME candidate placement" {
    var session: DevSession = undefined;
    session.allocator = std.testing.allocator;
    session.surfaces[0] = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 10, .rows = 5 });
    defer session.surfaces[0].deinit();
    session.surface_initialized = true;
    session.cell_width_px = 8;
    session.cell_height_px = 16;

    const core = &session.surfaces[0].core;
    try core.write("ab"); // 커서가 (0,2)로
    const r = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, 16), r.x); // col 2 * 8
    try std.testing.expectEqual(@as(f64, 0), r.y); // row 0 * 16
    try std.testing.expectEqual(@as(f64, 8), r.w);
    try std.testing.expectEqual(@as(f64, 16), r.h);

    try core.write("\r\nXY"); // 둘째 줄로
    const r2 = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, 16), r2.x); // col 2
    try std.testing.expectEqual(@as(f64, 16), r2.y); // row 1 * 16
}

test "pageScrollDelta: scroll mode + main screen scrolls; passthrough/alt sends to app" {
    // scroll 모드 + 메인 화면: PageUp=위(+1), PageDown=아래(-1) 스크롤.
    try std.testing.expectEqual(@as(i32, 1), DevSession.pageScrollDelta(true, false, .page_up));
    try std.testing.expectEqual(@as(i32, -1), DevSession.pageScrollDelta(true, false, .page_down));
    // scroll 모드라도 alt 화면(vim/less): 0 — 앱이 \e[5~/\e[6~로 페이징.
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(true, true, .page_up));
    // passthrough(opt-in, xterm/Ghostty): 메인 화면이어도 0 — \e[5~/\e[6~를 그대로 PTY로.
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(false, false, .page_up));
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(false, false, .page_down));
    // page 키가 아니면 무조건 0(일반 키 경로).
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(true, false, .{ .function = 5 }));
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(true, false, .home));
    try std.testing.expectEqual(@as(i32, 0), DevSession.pageScrollDelta(true, false, .{ .char = 'a' }));
}
