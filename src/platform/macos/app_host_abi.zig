const std = @import("std");
const maru = @import("maru");
const app_dev_session = @import("app_dev_session.zig");
const keycode = @import("keycode.zig");

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
    // PC-style 기능키. Swift normalizedKeyEvent가 NSEvent.keyCode를 이 값으로 매핑하고,
    // keyEventFromAbi가 terminal.Key로 바꿔 input.encodeKey가 xterm legacy 시퀀스를 낸다.
    home = 9,
    end = 10,
    insert = 11,
    delete = 12,
    page_up = 13,
    page_down = 14,
    f1 = 15,
    f2 = 16,
    f3 = 17,
    f4 = 18,
    f5 = 19,
    f6 = 20,
    f7 = 21,
    f8 = 22,
    f9 = 23,
    f10 = 24,
    f11 = 25,
    f12 = 26,
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
    // macOS 물리 키코드(NSEvent.keyCode). Ctrl/Cmd 단축키를 레이아웃과 무관하게(한글 입력
    // 모드에서도) 매칭하기 위해 Swift가 그대로 싣는다 — 변환은 Zig(keycode.zig)가 소유한다.
    raw_key_code: u32,
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
    if (raw_event.width_px == 0 or raw_event.height_px == 0) return @intFromEnum(Status.invalid_config);
    // grid(cols/rows)는 dev session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다. Swift는
    // 창의 backing 픽셀과 scale만 넘기고 cols/rows를 계산하지 않는다(event.cols/rows는 무시).
    // dev session이 분수 scale로 cell 메트릭을 device 해상도에 맞춘 뒤 grid를 잡으므로, Swift가
    // 메트릭 준비 전 placeholder로 grid를 잘못 잡던(창과 grid가 어긋나던) 문제가 사라진다.
    out.* = dev_session.resize(raw_event.width_px, raw_event.height_px, raw_event.scale_milli) catch return @intFromEnum(Status.resize_failed);
    return @intFromEnum(Status.ok);
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

// 휠 스크롤: Swift는 raw 델타(포인트)와 정밀 델타 여부만 넘기고, 줄 수 환산(매직 상수·clamp·NaN
// 가드)은 dev session이 실제 cell 메트릭으로 한다. 스크롤 자체는 TerminalCore가 소유한다.
pub export fn maru_macos_app_dev_session_scroll_wheel(
    session: ?*DevSession,
    delta_y: f64,
    precise: i32,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.scrollWheel(delta_y, precise != 0);
    return @intFromEnum(Status.ok);
}

// 마우스 선택(kind 1=down/2=drag/3=up/4=더블클릭 단어/5=트리플클릭 줄, backing px). 셀 변환·선택 모델은 Zig가 소유한다.
pub export fn maru_macos_app_dev_session_mouse(
    session: ?*DevSession,
    kind: i32,
    x_px: f64,
    y_px: f64,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.mouse(kind, x_px, y_px);
    return @intFromEnum(Status.ok);
}

// 클립보드 붙여넣기. 개행 정규화(\n->\r)와 bracketed paste(DECSET 2004) 감싸기는 Zig가 한다.
pub export fn maru_macos_app_dev_session_paste_text(
    session: ?*DevSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    dev_session.pasteText(ptr[0..len]);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션(v20). Swift keyDown은 begin -> interpretKeyEvents -> end 순서로 부르고,
// 입력기 콜백은 insert/marked로 쌓는다. 판정(전송/무시/인코딩)은 전부 Zig가 한다 — Swift엔
// IME 분기 로직이 없다(unit 테스트 가능).
pub export fn maru_macos_app_dev_session_ime_begin(session: ?*DevSession) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.imeBegin();
    return @intFromEnum(Status.ok);
}

// 입력기가 확정한 텍스트(insertText, UTF-8). 누적만 — 전송 판정은 ime_end가 한다.
pub export fn maru_macos_app_dev_session_ime_insert(
    session: ?*DevSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    dev_session.imeInsert(slice);
    return @intFromEnum(Status.ok);
}

// 입력기의 조합 중(marked) 텍스트(UTF-8). len 0 = 조합 해제. 커서 위치에 반전 합성 표시된다.
pub export fn maru_macos_app_dev_session_ime_marked(
    session: ?*DevSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    dev_session.imeMarked(slice);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션 종료 — 일괄 판정(확정 텍스트 전송 / 조합 조작 무시 / 일반 키 인코딩).
pub export fn maru_macos_app_dev_session_ime_end(
    session: ?*DevSession,
    event: ?*const KeyEvent,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    // event가 null이면 정규화 불가 키 — 트랜잭션은 닫되 일반 키 인코딩은 생략한다(imeEnd가 처리).
    const key_event: ?terminal.KeyEvent = if (event) |e|
        (keyEventFromAbi(e.*) catch return @intFromEnum(Status.invalid_config))
    else
        null;
    dev_session.imeEnd(key_event);
    return @intFromEnum(Status.ok);
}

// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). Swift가 화면 좌표로 변환해
// 후보창을 커서 위치에 띄운다(firstRect).
pub export fn maru_macos_app_dev_session_ime_cursor_rect(
    session: ?*DevSession,
    out_x: ?*f64,
    out_y: ?*f64,
    out_w: ?*f64,
    out_h: ?*f64,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const rx = out_x orelse return @intFromEnum(Status.null_out);
    const ry = out_y orelse return @intFromEnum(Status.null_out);
    const rw = out_w orelse return @intFromEnum(Status.null_out);
    const rh = out_h orelse return @intFromEnum(Status.null_out);
    const rect = dev_session.imeCursorRect();
    rx.* = rect.x;
    ry.* = rect.y;
    rw.* = rect.w;
    rh.* = rect.h;
    return @intFromEnum(Status.ok);
}

// IME deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 — 한글 마지막 자모 백스페이스의
// insertText+deleteBackward 상쇄 판정에 쓴다.
pub export fn maru_macos_app_dev_session_ime_delete_backward(session: ?*DevSession) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.imeDeleteBackward();
    return @intFromEnum(Status.ok);
}

// 포커스 변화. 잃으면 조합 중 텍스트를 확정(커밋)한다 — Terminal.app/Ghostty 의미론.
pub export fn maru_macos_app_dev_session_set_focus(session: ?*DevSession, focused: i32) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.setFocused(focused != 0);
    return @intFromEnum(Status.ok);
}

// Cmd+hover 갱신(backing px). URL 위면 *out_is_url=1 — Swift가 마우스 커서(pointingHand)를 정하고,
// Zig는 밑줄 하이라이트를 다음 frame에 투영한다. cmd_held=0이면 hover 해제.
pub export fn maru_macos_app_dev_session_hover(
    session: ?*DevSession,
    x_px: f64,
    y_px: f64,
    cmd_held: i32,
    out_is_url: ?*i32,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_is_url orelse return @intFromEnum(Status.null_out);
    out.* = if (dev_session.hoverUrl(x_px, y_px, cmd_held != 0)) 1 else 0;
    return @intFromEnum(Status.ok);
}

// Cmd+클릭 위치의 URL(backing px). 버퍼는 Zig 소유로 다음 url_at/destroy까지 유효, 없으면 len 0.
pub export fn maru_macos_app_dev_session_url_at(
    session: ?*DevSession,
    x_px: f64,
    y_px: f64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const url = dev_session.urlAt(x_px, y_px);
    ptr_out.* = if (url.len > 0) url.ptr else null;
    len_out.* = url.len;
    return @intFromEnum(Status.ok);
}

// 선택 텍스트 추출. 반환 버퍼는 Zig 소유로 다음 copy_text/destroy까지 유효하다. 비어 있으면 len 0.
pub export fn maru_macos_app_dev_session_copy_text(
    session: ?*DevSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = dev_session.copyText();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면(rows-1) 계산은 dev session이
// 권위 있는 rows로 한다(Swift가 stale frame summary로 계산하지 않게).
pub export fn maru_macos_app_dev_session_scroll_page(
    session: ?*DevSession,
    delta_pages: i32,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    dev_session.scrollPage(delta_pages);
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
    // 레이아웃 독립 단축키: Ctrl/Cmd 조합인데 현재 입력 소스의 글자가 라틴이 아니면(한글 'ㅂ'
    // 등 >= 0x80) 물리 키코드를 US 배열 라틴으로 되돌린다 — 한글 모드에서도 Ctrl+B가 0x02로
    // 인코딩된다(tmux prefix 등). 라틴 레이아웃(영어/Dvorak)의 결과는 존중해 건드리지 않는다.
    var codepoint = event.codepoint;
    if ((event.modifier_control != 0 or event.modifier_command != 0) and codepoint >= 0x80) {
        if (keycode.usAsciiForKeyCode(event.raw_key_code)) |latin| codepoint = latin;
    }

    // codepoint -> char 변환과 surrogate/범위 거부는 terminal.input이 단일 출처로 소유한다.
    // native keyDown smoke(keyEventFromNativeKeyDown)와 같은 변환을 공유해, 한쪽만 고치면
    // 두 입력 경계가 키 의미를 다르게 해석하는 일을 막는다. 잘못된 codepoint/key_code는 ABI
    // 계약대로 InvalidConfig로 닫는다.
    const key: terminal.Key = if (codepoint != 0)
        (terminal.input.charKeyFromCodepoint(codepoint) catch return error.InvalidConfig)
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
        .home => .home,
        .end => .end,
        .insert => .insert,
        .delete => .delete,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .{ .function = 1 },
        .f2 => .{ .function = 2 },
        .f3 => .{ .function = 3 },
        .f4 => .{ .function = 4 },
        .f5 => .{ .function = 5 },
        .f6 => .{ .function = 6 },
        .f7 => .{ .function = 7 },
        .f8 => .{ .function = 8 },
        .f9 => .{ .function = 9 },
        .f10 => .{ .function = 10 },
        .f11 => .{ .function = 11 },
        .f12 => .{ .function = 12 },
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
    // PC-style 기능키 C 상수 ↔ enum 정합(경계 1개씩 + F12로 확인).
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeHome)), @intFromEnum(KeyCode.home));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodePageDown)), @intFromEnum(KeyCode.page_down));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeF1)), @intFromEnum(KeyCode.f1));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeF12)), @intFromEnum(KeyCode.f12));
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
    // v18~v21 신규 IME/focus export도 null session을 ABI 오류로 닫는지 — 헤더에 선언만 되고
    // 계약 테스트가 안 건드리던 공백(리뷰 #13)을 메운다(심볼 존재 + null-safety 동시 확인).
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_begin(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_insert(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_marked(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_end(null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_delete_backward(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_set_focus(null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_dev_session_ime_cursor_rect(null, null, null, null, null));
}

test {
    std.testing.refAllDecls(app_dev_session);
}

test "layout-independent shortcut: Hangul-mode Ctrl+B normalizes to latin b via the physical keycode" {
    // 한글 입력 모드에서 Ctrl+B: AppKit 글자는 'ㅂ'(0x3142)이지만 물리 키코드는 B(0x0B).
    const event = KeyEvent{
        .codepoint = 0x3142, // 'ㅂ'
        .key_code = 0, // unknown
        .modifier_shift = 0,
        .modifier_control = 1,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x0B, // kVK_ANSI_B
    };
    const key_event = try keyEventFromAbi(event);
    try std.testing.expectEqual(terminal.Key{ .char = 'b' }, key_event.key);
    try std.testing.expect(key_event.modifiers.control);
    // 인코딩까지: Ctrl+b -> 0x02 (tmux prefix가 한글 모드에서도 동작).
    var buffer: [8]u8 = undefined;
    const encoded = try terminal.input.encodeKey(key_event, &buffer, .{});
    try std.testing.expectEqualSlices(u8, &.{0x02}, encoded);
}

test "latin layouts are preserved: Ctrl+B with an ascii codepoint does not consult the keycode table" {
    // Dvorak 등 라틴 배열: 현재 레이아웃 결과(ASCII)를 존중한다 — 물리 키코드로 덮지 않는다.
    const event = KeyEvent{
        .codepoint = 'x', // Dvorak에서 다른 물리 키가 'x'를 낼 수 있다
        .key_code = 0,
        .modifier_shift = 0,
        .modifier_control = 1,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x0B, // 물리 B여도
    };
    const key_event = try keyEventFromAbi(event);
    try std.testing.expectEqual(terminal.Key{ .char = 'x' }, key_event.key);
}

test "keyEventFromAbi maps function keys to terminal.Key" {
    const mk = struct {
        fn f(code: KeyCode) KeyEvent {
            return .{ .codepoint = 0, .key_code = @intFromEnum(code), .modifier_shift = 0, .modifier_control = 0, .modifier_option = 0, .modifier_command = 0, .is_repeat = 0, .raw_key_code = 0 };
        }
    }.f;
    try std.testing.expectEqual(terminal.input.Key.delete, (try keyEventFromAbi(mk(.delete))).key);
    try std.testing.expectEqual(terminal.input.Key.page_up, (try keyEventFromAbi(mk(.page_up))).key);
    try std.testing.expectEqual(terminal.input.Key.home, (try keyEventFromAbi(mk(.home))).key);
    try std.testing.expectEqual(@as(u8, 1), (try keyEventFromAbi(mk(.f1))).key.function);
    try std.testing.expectEqual(@as(u8, 12), (try keyEventFromAbi(mk(.f12))).key.function);
}

test "Option+Backspace chains through ABI to meta-DEL (\\e\\x7f, word delete)" {
    const abi_event = KeyEvent{
        .codepoint = 0,
        .key_code = @intFromEnum(KeyCode.backspace),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 1,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 51,
    };
    const ev = try keyEventFromAbi(abi_event);
    try std.testing.expect(ev.modifiers.option);
    try std.testing.expectEqual(terminal.input.Key.backspace, ev.key);
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b\x7f", try terminal.input.encodeKey(ev, &buf, .{}));
}
