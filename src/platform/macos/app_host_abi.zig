const std = @import("std");
const maru = @import("maru");
const app_dev_session = @import("app_dev_session.zig");

const c = @cImport({
    @cInclude("app_host_abi.h");
});

pub const abi_version: u32 = app_dev_session.abi_version;
const allocator = std.heap.smp_allocator;
const terminal = maru.terminal;

pub const Status = enum(c_int) {
    ok = 0,
    null_out = 1,
    unsupported_abi = 2,
    invalid_config = 3,
    create_failed = 4,
    tick_failed = 5,
    close_failed = 6,
    key_failed = 7,
    resize_failed = 8,
    // tick이 PTY 세션 종료를 관측했다(shell exit/read_error). fault가 아니라 정상 종료
    // 신호이므로 host는 frame loop를 멈추고 우아하게 내려간다.
    session_ended = 9,
};

// EventKind는 app_dev_session.zig가 소유한다(FrameSummary.last_event_kind에 실린다).
// 여기서는 ABI 표면으로 re-export만 한다.
pub const EventKind = app_dev_session.EventKind;

pub const KeyCode = enum(u32) {
    unknown = 0,
    enter = 1,
    escape = 2,
    tab = 3,
    backspace = 4,
    arrow_up = 5,
    arrow_down = 6,
    arrow_left = 7,
    arrow_right = 8,
};

pub const Capabilities = extern struct {
    abi_version: u32,
    swift_owns_ns_application: u32,
    swift_owns_window_lifecycle: u32,
    swift_owns_focus_and_input: u32,
    zig_owns_live_pty_sessions: u32,
    zig_owns_frame_loop: u32,
    objective_c_smokes_remain: u32,
};

pub const KeyEvent = extern struct {
    codepoint: u32,
    key_code: u32,
    modifier_shift: u32,
    modifier_control: u32,
    modifier_option: u32,
    modifier_command: u32,
    is_repeat: u32,
    reserved: u32,
};

pub const ResizeEvent = extern struct {
    width_px: u32,
    height_px: u32,
    scale_milli: u32,
    cols: u32,
    rows: u32,
    reserved: u32,
};

pub const DevCommandKind = app_dev_session.CommandKind;
pub const DevSession = app_dev_session.DevSession;
pub const DevSessionConfig = app_dev_session.SessionConfig;
pub const DevFrameSummary = app_dev_session.FrameSummary;
pub const DevMetalCell = app_dev_session.MetalCell;
pub const DevMetalRasterUpload = app_dev_session.MetalRasterUpload;
pub const DevMetalFrame = app_dev_session.MetalFrame;

pub fn defaultCapabilities() Capabilities {
    // Swift host는 macOS 앱 생명주기와 focus/input만 소유한다. PTY와 frame loop는
    // Zig에 남겨야 smoke, headless test, future Swift host가 같은 터미널 동작을 공유한다.
    return .{
        .abi_version = abi_version,
        .swift_owns_ns_application = 1,
        .swift_owns_window_lifecycle = 1,
        .swift_owns_focus_and_input = 1,
        .zig_owns_live_pty_sessions = 1,
        .zig_owns_frame_loop = 1,
        .objective_c_smokes_remain = 1,
    };
}

pub export fn maru_macos_app_host_abi_version() u32 {
    return abi_version;
}

pub export fn maru_macos_app_host_capabilities(out_capabilities: ?*Capabilities) c_int {
    const out = out_capabilities orelse return @intFromEnum(Status.null_out);
    out.* = defaultCapabilities();
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_create(
    config: ?*const DevSessionConfig,
    out_session: ?*?*DevSession,
) c_int {
    const raw_config = (config orelse return @intFromEnum(Status.null_out)).*;
    const out = out_session orelse return @intFromEnum(Status.null_out);
    out.* = null;

    _ = app_dev_session.normalizeConfig(raw_config) catch |err| switch (err) {
        error.UnsupportedAbi => return @intFromEnum(Status.unsupported_abi),
        error.InvalidConfig => return @intFromEnum(Status.invalid_config),
    };

    const session = allocator.create(DevSession) catch return @intFromEnum(Status.create_failed);
    errdefer allocator.destroy(session);

    session.init(std.Io.Threaded.global_single_threaded.io(), allocator, raw_config) catch {
        return @intFromEnum(Status.create_failed);
    };

    out.* = session;
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_tick(
    session: ?*DevSession,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = dev_session.tick() catch return @intFromEnum(Status.tick_failed);
    // PTY 세션이 종료되면 ok가 아니라 session_ended를 올려, host가 죽은 세션을 무한 tick하지
    // 않고 frame loop를 멈춰 우아하게 내려가게 한다. ended는 latch라 이후 tick도 동일 신호다.
    if (out.ended != 0) return @intFromEnum(Status.session_ended);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_key_down(
    session: ?*DevSession,
    event: ?*const KeyEvent,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    const key_event = keyEventFromAbi(raw_event) catch return @intFromEnum(Status.invalid_config);
    out.* = dev_session.handleKeyEvent(key_event) catch return @intFromEnum(Status.key_failed);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_resize(
    session: ?*DevSession,
    event: ?*const ResizeEvent,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    const size = sizeFromAbi(raw_event) catch return @intFromEnum(Status.invalid_config);
    // backing scale은 천분율(scale_milli)을 그대로 dev session에 넘긴다. dev session이 분수 scale로
    // glyph rasterize 크기와 cell 메트릭을 device 해상도에 정확히 맞춘다(정수 반올림은 atlas
    // fallback에서만, renderer.deviceScaleFromMilli).
    out.* = dev_session.resize(size, raw_event.scale_milli) catch return @intFromEnum(Status.resize_failed);
    return @intFromEnum(Status.ok);
}

// cell 메트릭이 아직 없을 때(첫 frame 전) grid 계산에 쓰는 placeholder cell 픽셀 크기.
const placeholder_cell_width_px: u32 = 12;
const placeholder_cell_height_px: u32 = 24;

/// backing 픽셀 크기와 cell 픽셀 크기로 터미널 grid(cols/rows)를 구한다. cell 크기가 0이면
/// (아직 메트릭 없음) placeholder로 대체하고, 최소 1×1, u16 상한으로 막는다. Swift가 직접
/// floor/clamp 계산을 들고 있던 것을 Zig로 옮겨 std.testing으로 고정한다.
fn gridFromBacking(backing_width_px: u32, backing_height_px: u32, cell_width_px: u32, cell_height_px: u32) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px;
    const cols = @max(@as(u32, 1), backing_width_px / cell_w);
    const rows = @max(@as(u32, 1), backing_height_px / cell_h);
    return .{
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(rows, std.math.maxInt(u16))),
    };
}

/// Swift host가 창 backing 픽셀 크기에서 grid를 계산할 때 부르는 순수 helper(상태 없음, 세션
/// ABI 버전과 무관). out_cols/out_rows에 결과를 쓴다.
pub export fn maru_macos_grid_from_backing(
    backing_width_px: u32,
    backing_height_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    out_cols: ?*u32,
    out_rows: ?*u32,
) void {
    const size = gridFromBacking(backing_width_px, backing_height_px, cell_width_px, cell_height_px);
    if (out_cols) |p| p.* = size.cols;
    if (out_rows) |p| p.* = size.rows;
}

pub export fn maru_macos_app_dev_session_close(
    session: ?*DevSession,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = dev_session.close();
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_destroy(session: ?*DevSession) void {
    // 수명 계약: destroy는 단발성이다. null은 안전하게 무시하지만, 이미 해제된 handle은
    // 감지할 수 없으므로(메모리가 freed) 같은 non-null handle로 두 번 호출하면 use-after-free /
    // double-free다. caller(Swift host)는 destroy 직후 handle을 nil로 비워 재호출을 막아야
    // 한다. 반복 호출이 안전한 idempotent 종료가 필요하면 close()를 쓴다.
    const dev_session = session orelse return;
    dev_session.deinit();
    allocator.destroy(dev_session);
}

pub export fn maru_macos_app_dev_session_metal_frame(
    session: ?*DevSession,
    out_frame: ?*DevMetalFrame,
) c_int {
    // 가장 최근 tick의 RenderFrame을 Metal DTO(cells/atlas uploads/raster pixels)로 노출한다.
    // 포인터는 dev session이 소유한 retained 배열을 가리키며 다음 tick까지 유효하다. caller는
    // 같은 main thread에서 tick 직후 동기적으로 읽는다.
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_frame orelse return @intFromEnum(Status.null_out);
    out.* = dev_session.metalFrame();
    return @intFromEnum(Status.ok);
}

fn keyEventFromAbi(event: KeyEvent) !terminal.KeyEvent {
    // codepoint -> char 변환과 surrogate/범위 거부는 terminal.input이 단일 출처로 소유한다.
    // native keyDown smoke(keyEventFromNativeKeyDown)와 같은 변환을 공유해, 한쪽만 고치면
    // 두 입력 경계가 키 의미를 다르게 해석하는 일을 막는다. 잘못된 codepoint/key_code는 ABI
    // 계약대로 InvalidConfig로 닫는다.
    const key: terminal.Key = if (event.codepoint != 0)
        (terminal.input.charKeyFromCodepoint(event.codepoint) catch return error.InvalidConfig)
    else switch (std.enums.fromInt(KeyCode, event.key_code) orelse return error.InvalidConfig) {
        .unknown => return error.InvalidConfig,
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        .arrow_up => .arrow_up,
        .arrow_down => .arrow_down,
        .arrow_left => .arrow_left,
        .arrow_right => .arrow_right,
    };

    return .{
        .key = key,
        .modifiers = .{
            .shift = event.modifier_shift != 0,
            .control = event.modifier_control != 0,
            .option = event.modifier_option != 0,
            .command = event.modifier_command != 0,
        },
    };
}

fn sizeFromAbi(event: ResizeEvent) !terminal.Size {
    _ = event.width_px;
    _ = event.height_px;
    _ = event.scale_milli;
    if (event.cols == 0 or event.rows == 0) return error.InvalidConfig;
    if (event.cols > std.math.maxInt(u16) or event.rows > std.math.maxInt(u16)) {
        return error.InvalidConfig;
    }
    return .{ .cols = @intCast(event.cols), .rows = @intCast(event.rows) };
}

test "macOS app host ABI header and Zig declarations stay aligned" {
    // Swift는 C header를 보고, Zig는 이 파일의 extern struct를 쓴다. 둘의 숫자와
    // layout이 갈라지면 다음 제품 앱 PR에서 런타임 버그가 되므로 컴파일 단계에서 막는다.
    try std.testing.expectEqual(@as(u32, c.MARU_MACOS_APP_HOST_ABI_VERSION), abi_version);
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusOk), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusNullOut), @intFromEnum(Status.null_out));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusInvalidConfig), @intFromEnum(Status.invalid_config));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusSessionEnded), @intFromEnum(Status.session_ended));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostEventKeyDown), @intFromEnum(EventKind.key_down));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostEventAppShouldTerminate), @intFromEnum(EventKind.app_should_terminate));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeArrowUp)), @intFromEnum(KeyCode.arrow_up));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostDevCommandControlledSmoke)), @intFromEnum(DevCommandKind.controlled_smoke));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCapabilities), @sizeOf(Capabilities));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCapabilities), @alignOf(Capabilities));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostKeyEvent), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostResizeEvent), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevSessionConfig), @sizeOf(DevSessionConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevSessionConfig), @alignOf(DevSessionConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevFrameSummary), @sizeOf(DevFrameSummary));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevFrameSummary), @alignOf(DevFrameSummary));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevMetalCell), @sizeOf(DevMetalCell));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevMetalCell), @alignOf(DevMetalCell));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevMetalRasterUpload), @sizeOf(DevMetalRasterUpload));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevMetalRasterUpload), @alignOf(DevMetalRasterUpload));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevMetalFrame), @sizeOf(DevMetalFrame));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevMetalFrame), @alignOf(DevMetalFrame));
}

test "macOS app host capabilities describe ownership before runtime exists" {
    var capabilities: Capabilities = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_host_capabilities(&capabilities));
    try std.testing.expectEqual(abi_version, capabilities.abi_version);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_ns_application);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_window_lifecycle);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_focus_and_input);
    try std.testing.expectEqual(@as(u32, 1), capabilities.zig_owns_live_pty_sessions);
    try std.testing.expectEqual(@as(u32, 1), capabilities.zig_owns_frame_loop);
    try std.testing.expectEqual(@as(u32, 1), capabilities.objective_c_smokes_remain);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_host_capabilities(null));
}

test "macOS app host event DTOs are explicit fixed-width C ABI records" {
    // Swift struct layout을 추측해서 포인터로 넘기면 위험하다. C header와 같은 fixed-width
    // record만 ABI에 둬야 key input, resize, close event가 platform 별로 흔들리지 않는다.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DevSessionConfig));
    try std.testing.expectEqual(@as(usize, 168), @sizeOf(DevFrameSummary));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(DevFrameSummary));
}

test "macOS app host ABI converts key and resize events before session dispatch" {
    const char_event = try keyEventFromAbi(.{
        .codepoint = 'b',
        .key_code = @intFromEnum(KeyCode.unknown),
        .modifier_control = 1,
        .modifier_shift = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .reserved = 0,
    });
    try std.testing.expect(switch (char_event.key) {
        .char => |codepoint| codepoint == 'b',
        else => false,
    });
    try std.testing.expect(char_event.modifiers.control);

    const arrow_event = try keyEventFromAbi(.{
        .codepoint = 0,
        .key_code = @intFromEnum(KeyCode.arrow_up),
        .modifier_option = 1,
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .reserved = 0,
    });
    try std.testing.expect(switch (arrow_event.key) {
        .arrow_up => true,
        else => false,
    });
    try std.testing.expect(arrow_event.modifiers.option);

    try std.testing.expectError(error.InvalidConfig, keyEventFromAbi(.{
        .codepoint = 0xd800,
        .key_code = @intFromEnum(KeyCode.unknown),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .reserved = 0,
    }));
    // U+10FFFF 초과는 valid Unicode scalar가 아니다. surrogate처럼 경계에서 거부해야
    // downstream utf8Encode에서 덜 명확하게 터지지 않는다.
    try std.testing.expectError(error.InvalidConfig, keyEventFromAbi(.{
        .codepoint = 0x110000,
        .key_code = @intFromEnum(KeyCode.unknown),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .reserved = 0,
    }));
    try std.testing.expectError(error.InvalidConfig, keyEventFromAbi(.{
        .codepoint = 0,
        .key_code = 999,
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .reserved = 0,
    }));
    try std.testing.expectEqual(terminal.Size{ .cols = 100, .rows = 30 }, try sizeFromAbi(.{
        .width_px = 1200,
        .height_px = 720,
        .scale_milli = 2000,
        .cols = 100,
        .rows = 30,
        .reserved = 0,
    }));
    try std.testing.expectError(error.InvalidConfig, sizeFromAbi(.{
        .width_px = 0,
        .height_px = 0,
        .scale_milli = 0,
        .cols = 0,
        .rows = 30,
        .reserved = 0,
    }));
}

test "macOS app dev exported session API reports null outputs as ABI errors" {
    const config: DevSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(DevCommandKind.controlled_smoke),
    };
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_create(&config, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_tick(null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_key_down(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_resize(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_close(null, null),
    );
}

test {
    std.testing.refAllDecls(app_dev_session);
}

test "gridFromBacking divides backing pixels by cell size with placeholder + clamps" {
    // 960×600 backing at 8×16 cell -> 120×37.
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 37 }, gridFromBacking(960, 600, 8, 16));
    // cell 크기 0(메트릭 없음) -> placeholder 12×24 사용.
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 25 }, gridFromBacking(960, 600, 0, 0));
    // floor 동작: 부족한 픽셀은 버린다.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(25, 16, 10, 16));
    // 최소 1×1.
    try std.testing.expectEqual(terminal.Size{ .cols = 1, .rows = 1 }, gridFromBacking(1, 1, 100, 100));
}
