const std = @import("std");
const maru = @import("maru");
const session_mod = @import("app_session.zig");
const keycode = @import("keycode.zig");
const keyhint_hold = maru.session.keyhint_hold; // OS-중립 홀드 gesture 정책(session L2 — session/keyhint_hold.zig)
const command_catalog = @import("command_catalog.zig");

const c = @cImport({
    @cInclude("app_host_abi.h");
});

pub const abi_version: u32 = session_mod.abi_version;
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

// EventKind는 app_session.zig가 소유한다(FrameSummary.last_event_kind에 실린다).
// 여기서는 ABI 표면으로 re-export만 한다.
pub const EventKind = session_mod.EventKind;

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
    // codepoint의 unshifted base-layout 값(shift 미반영). kitty CSI u의 key code가 base-layout
    // key여야 해서 Swift가 characters(byApplyingModifiers:[])로 따로 싣는다. char가 아니거나
    // 단일 codepoint가 아니면 0(keyEventFromAbi가 codepoint로 폴백).
    base_codepoint: u32,
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

pub const AppCommandKind = session_mod.CommandKind;
pub const AppSession = session_mod.AppSession;
pub const AppSessionConfig = session_mod.SessionConfig;
pub const AppFrameSummary = session_mod.FrameSummary;
pub const AppMetalCell = session_mod.MetalCell;
pub const AppMetalRasterUpload = session_mod.MetalRasterUpload;
pub const AppMetalFrame = session_mod.MetalFrame;
pub const AppGpuQuad = session_mod.MetalGpuQuad;
pub const AppGpuShadow = session_mod.MetalGpuShadow;
pub const AppGpuImage = session_mod.MetalGpuImage;
pub const AppGpuImageUpload = session_mod.MetalGpuImageUpload;

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

pub export fn maru_macos_app_session_create(
    config: ?*const AppSessionConfig,
    out_session: ?*?*AppSession,
) c_int {
    const raw_config = (config orelse return @intFromEnum(Status.null_out)).*;
    const out = out_session orelse return @intFromEnum(Status.null_out);
    out.* = null;

    _ = session_mod.normalizeConfig(raw_config) catch |err| switch (err) {
        error.UnsupportedAbi => return @intFromEnum(Status.unsupported_abi),
        error.InvalidConfig => return @intFromEnum(Status.invalid_config),
    };

    const session = allocator.create(AppSession) catch return @intFromEnum(Status.create_failed);
    // 이 함수는 c_int를 반환해 정상 return(@intFromEnum)으로 끝나므로 errdefer가 발화하지 않는다 — init 실패 시
    // 바깥 struct를 catch 안에서 직접 해제해야 누수가 안 난다. (init 내부 errdefer self.deinit()는 내부 할당만
    // 정리하지 이 create로 잡은 struct 자체는 못 푼다. 호스트는 실패 시 핸들이 없어 destroy도 못 한다.)
    session.init(std.Io.Threaded.global_single_threaded.io(), allocator, raw_config) catch {
        allocator.destroy(session);
        return @intFromEnum(Status.create_failed);
    };

    out.* = session;
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_tick(
    session: ?*AppSession,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    app_session.maybeDebugOpenSettings(); // MARU_OPEN_SETTINGS 시각 확인 훅 — tick(렌더) 전에 열어야 이 frame에 모달이 든다(env 미설정이면 무동작)
    out.* = app_session.tick() catch return @intFromEnum(Status.tick_failed);
    // PTY 세션이 종료되면 ok가 아니라 session_ended를 올려, host가 죽은 세션을 무한 tick하지
    // 않고 frame loop를 멈춰 우아하게 내려가게 한다. ended는 latch라 이후 tick도 동일 신호다.
    if (out.ended != 0) return @intFromEnum(Status.session_ended);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_key_down(
    session: ?*AppSession,
    event: ?*const KeyEvent,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    const key_event = keyEventFromAbi(raw_event) catch return @intFromEnum(Status.invalid_config);
    out.* = app_session.handleKeyEvent(key_event) catch return @intFromEnum(Status.key_failed);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_resize(
    session: ?*AppSession,
    event: ?*const ResizeEvent,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    if (raw_event.width_px == 0 or raw_event.height_px == 0) return @intFromEnum(Status.invalid_config);
    // grid(cols/rows)는 app session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다. Swift는
    // 창의 backing 픽셀과 scale만 넘기고 cols/rows를 계산하지 않는다(event.cols/rows는 무시).
    // app session이 분수 scale로 cell 메트릭을 device 해상도에 맞춘 뒤 grid를 잡으므로, Swift가
    // 메트릭 준비 전 placeholder로 grid를 잘못 잡던(창과 grid가 어긋나던) 문제가 사라진다.
    out.* = app_session.resize(raw_event.width_px, raw_event.height_px, raw_event.scale_milli) catch return @intFromEnum(Status.resize_failed);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_close(
    session: ?*AppSession,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = app_session.close();
    return @intFromEnum(Status.ok);
}

/// 빨간 닫기 버튼/창 단위 닫기 요청(windowShouldClose). 닫힐 창(세션)에 실행 중인 명령이 있으면 Zig가 확인 모달을
/// 열고 1(deferred)을 돌려준다 — Swift는 false를 반환해 닫기를 보류하고, 모달 확정 시 tick의 session-ended가 실제로
/// 창을 닫는다(closeWindowOrQuit — 프로그래밍적 close라 windowShouldClose 재호출/재확인 루프가 없다). 실행 중 명령이
/// 없으면 0 — Swift가 평소대로 닫는다(windowWillClose → terminate/teardown). null session이면 0(평소 닫기).
pub export fn maru_macos_app_session_request_window_close(session: ?*AppSession) c_int {
    const app_session = session orelse return 0;
    return if (app_session.requestWindowClose()) 1 else 0;
}

/// Cmd+Q/메뉴 "Quit maru"/Dock·로그아웃에 의한 앱 전체 종료 확인 요청(applicationShouldTerminate). 창 닫기와 달리
/// **항상**(실행 중 명령 무관) "maru를 종료할까요?" 확인 모달을 띄운다(앱 종료=모든 창·탭 동시 소멸이라 더 파괴적, 사용자
/// 결정 2026-06). Swift는 이 호출 뒤 .terminateLater를 돌려주고, 모달 확정/취소가 다음 tick FrameSummary.quit_decision
/// (1=accepted·2=cancelled)에 실리면 NSApp.reply(toApplicationShouldTerminate:)로 종료를 진행/취소한다.
pub export fn maru_macos_app_session_request_app_quit(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.requestAppQuit();
}

// 휠 스크롤: Swift는 raw 델타(포인트)·정밀 델타 여부·마우스 위치(backing px)만 넘기고, 줄 수 환산(매직
// 상수·clamp·NaN 가드)과 어느 panel로 보낼지(커서 아래 pane)는 app session이 한다. 스크롤 자체는
// TerminalCore가 소유한다. x/y는 split에서 비활성 panel 위 휠을 그 panel로 라우팅하는 데 쓴다(단일 panel
// 이면 활성과 같음, 사이드바/밖이면 활성 fallback).
pub export fn maru_macos_app_session_scroll_wheel(
    session: ?*AppSession,
    delta_y: f64,
    delta_x: f64,
    precise: i32,
    x_px: f64,
    y_px: f64,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.scrollWheel(delta_y, delta_x, precise != 0, x_px, y_px);
    return @intFromEnum(Status.ok);
}

// 마우스 선택(kind 1=down/2=drag/3=up/4=더블클릭 단어/5=트리플클릭 줄, backing px). 셀 변환·선택 모델은 Zig가 소유한다.
pub export fn maru_macos_app_session_mouse(
    session: ?*AppSession,
    kind: i32,
    x_px: f64,
    y_px: f64,
    button: i32,
    mods: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.mouse(kind, x_px, y_px, button, mods);
    return @intFromEnum(Status.ok);
}

// 버튼 없는 마우스 이동(hover, backing px). Zig가 트래킹 모드를 확인해 any-event(DECSET 1003)일 때만 mouse
// reporting한다(아니면 no-op). mouseMoved마다 호출되지만 Zig가 같은 셀 반복은 스킵한다. handleHover(Cmd+링크 밑줄)와 병행.
pub export fn maru_macos_app_session_mouse_moved(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32,
) void {
    const app_session = session orelse return;
    app_session.mouseMoved(x_px, y_px, mods);
}

// 클립보드 붙여넣기(Cmd+V)·드래그앤드롭. 개행 정규화(\n->\r)와 bracketed paste(DECSET 2004) 감싸기는
// Zig가 한다. escape_each!=0이면 bytes를 NUL('\0') 구분 토큰으로 보고 각 토큰을 셸 이스케이프한 뒤 공백
// 으로 join한다(드래그된 파일 경로·URL — 셸이 공백 등 메타문자에서 단어를 쪼개지 않게). 평문·Cmd+V 웹
// URL은 0(raw)으로 보낸다(이스케이프하면 ?,&,= 등이 깨진다). 무엇을 이스케이프할지는 pasteboard 타입에
// 묶여 Swift host가 정하고, 이스케이프 '메커니즘'은 Zig(app_session.shellEscapeJoin)가 단일 출처다. (v67)
pub export fn maru_macos_app_session_paste_text(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
    escape_each: u32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.pasteText(ptr[0..len], escape_each != 0);
    return @intFromEnum(Status.ok);
}

// 드래그앤드롭한 파일 경로들(NUL '\0' 구분). maru ssh 원격 세션이면 각 파일을 control socket으로 백그라운드
// 업로드한 뒤 원격 절대경로를 paste하고, 로컬 세션이면 경로를 셸 이스케이프해 paste한다 — 분기는
// Zig(app_session.handleDroppedFiles). Swift는 fileURL 드롭일 때만 부른다(웹 URL·텍스트는 paste_text). (v68)
pub export fn maru_macos_app_session_drop_files(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.handleDroppedFiles(ptr[0..len]);
    return @intFromEnum(Status.ok);
}

// 클립보드 이미지(Cmd+V)를 paste한다. maru ssh 원격이면 control socket으로 업로드 후 원격 절대경로를 paste하고
// 1을 돌려준다(Swift는 더 안 함). 로컬/미처리면 0(Swift가 기존 텍스트·URL paste 진행). 파일 드롭과 달리
// 경로가 없어 바이트를 직접 받는다(app_session.handleDroppedImage). (v69)
pub export fn maru_macos_app_session_drop_image(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return 0;
    if (len == 0) return 0;
    const ptr = bytes orelse return 0;
    return if (app_session.handleDroppedImage(ptr[0..len])) 1 else 0;
}

// chrome Notice 모달(손상 알림 등)을 연다. Swift가 워크스페이스 복원 손상(workspace_window_count<0)을 감지하면
// UTF-8 메시지로 부른다. 세션이 복사 소유하므로 호출 뒤 버퍼는 free해도 된다. len==0이면 무동작. (v40)
pub export fn maru_macos_app_session_show_notice(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.showNotice(ptr[0..len]);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션(v20). Swift keyDown은 begin -> interpretKeyEvents -> end 순서로 부르고,
// 입력기 콜백은 insert/marked로 쌓는다. 판정(전송/무시/인코딩)은 전부 Zig가 한다 — Swift엔
// IME 분기 로직이 없다(unit 테스트 가능).
pub export fn maru_macos_app_session_ime_begin(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.imeBegin();
    return @intFromEnum(Status.ok);
}

// 입력기가 확정한 텍스트(insertText, UTF-8). 누적만 — 전송 판정은 ime_end가 한다.
pub export fn maru_macos_app_session_ime_insert(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    app_session.imeInsert(slice);
    return @intFromEnum(Status.ok);
}

// 입력기의 조합 중(marked) 텍스트(UTF-8). len 0 = 조합 해제. 커서 위치에 반전 합성 표시된다.
pub export fn maru_macos_app_session_ime_marked(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    app_session.imeMarked(slice);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션 종료 — 일괄 판정(확정 텍스트 전송 / 조합 조작 무시 / 일반 키 인코딩).
pub export fn maru_macos_app_session_ime_end(
    session: ?*AppSession,
    event: ?*const KeyEvent,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    // event가 null이면 정규화 불가 키 — 트랜잭션은 닫되 일반 키 인코딩은 생략한다(imeEnd가 처리).
    const key_event: ?terminal.KeyEvent = if (event) |e|
        (keyEventFromAbi(e.*) catch return @intFromEnum(Status.invalid_config))
    else
        null;
    app_session.imeEnd(key_event);
    return @intFromEnum(Status.ok);
}

// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). Swift가 화면 좌표로 변환해
// 후보창을 커서 위치에 띄운다(firstRect).
pub export fn maru_macos_app_session_ime_cursor_rect(
    session: ?*AppSession,
    out_x: ?*f64,
    out_y: ?*f64,
    out_w: ?*f64,
    out_h: ?*f64,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const rx = out_x orelse return @intFromEnum(Status.null_out);
    const ry = out_y orelse return @intFromEnum(Status.null_out);
    const rw = out_w orelse return @intFromEnum(Status.null_out);
    const rh = out_h orelse return @intFromEnum(Status.null_out);
    const rect = app_session.imeCursorRect();
    rx.* = rect.x;
    ry.* = rect.y;
    rw.* = rect.w;
    rh.* = rect.h;
    return @intFromEnum(Status.ok);
}

// IME deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 — 한글 마지막 자모 백스페이스의
// insertText+deleteBackward 상쇄 판정에 쓴다.
pub export fn maru_macos_app_session_ime_delete_backward(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.imeDeleteBackward();
    return @intFromEnum(Status.ok);
}

// 포커스 변화. 잃으면 조합 중 텍스트를 확정(커밋)한다 — Terminal.app/Ghostty 의미론.
pub export fn maru_macos_app_session_set_focus(session: ?*AppSession, focused: i32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.setFocused(focused != 0);
    return @intFromEnum(Status.ok);
}

// 세팅 등 chrome 오버레이가 열렸는지(keybind 녹음 중이면 settings.open=true라 포함). Swift performKeyEquivalent가 1이면
// 메뉴바 keyEquivalent(⌘T 등)를 양보해 키를 keyDown(→ handleKeyEvent 모달/녹음 가드)으로 보낸다 — ⌘조합 단축키 누수·
// chord 녹음 누락 방지(예전엔 ⌘조합이 메뉴바 keyEquivalent에 먹혀 handleKeyEvent를 통째로 우회했다).
pub export fn maru_macos_app_session_any_overlay_open(session: ?*AppSession) c_int {
    const app_session = session orelse return 0;
    return if (app_session.anyOverlayOpen()) 1 else 0;
}

// 진행 중 IME 조합을 확정(커밋)한다. Swift가 IME를 우회하는 특수키/단축키 직전에 호출해
// marked text와 core preedit가 어긋나지 않게 한다(조합 없으면 무동작).
pub export fn maru_macos_app_session_commit_composition(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.commitComposition();
    return @intFromEnum(Status.ok);
}

// 마우스 호버 갱신(backing px). *out_cursor_kind에 위치별 커서 종류를 돌려준다(CursorKind: 0=arrow/사이드바·탭
// 바, 1=iBeam/터미널, 2=pointingHand/Cmd+hover URL, 3=resizeLeftRight/세로 divider, 4=resizeUpDown/가로 divider,
// 5=openHand/pane grip 호버).
// Swift가 이 값으로 NSCursor를 세운다. Zig는 부수적으로 사이드바 슬롯·pane 탭 호버·URL 밑줄을 갱신한다.
// cmd_held=0이면 URL 호버 해제. 창 밖이면 Swift가 음수 sentinel(-1,-1)을 보내 호버를 해제한다.
pub export fn maru_macos_app_session_hover(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32, // 마우스 수식키 비트(xterm: shift=4, alt=8, ctrl=16, cmd=32) — Zig가 url-click-modifier와 비교(v71)
    out_cursor_kind: ?*i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_cursor_kind orelse return @intFromEnum(Status.null_out);
    out.* = @intFromEnum(app_session.hoverCursor(x_px, y_px, mods));
    return @intFromEnum(Status.ok);
}

// (config 수식키)+클릭 위치의 링크(backing px). mods가 url-click-modifier와 안 맞으면 len 0(일반 클릭). 버퍼는
// Zig 소유로 다음 url_at/destroy까지 유효. out_kind=링크 종류(0=url, 1=file_path; len>0일 때만 유효, NULL 허용)로
// Swift가 URL(string:) vs URL(fileURLWithPath:)를 가른다. v71: mods 인자. v89: out_kind 인자(docs/link-detection.md).
pub export fn maru_macos_app_session_url_at(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
    out_kind: ?*i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const url = app_session.urlAt(x_px, y_px, mods);
    ptr_out.* = if (url.len > 0) url.ptr else null;
    len_out.* = url.len;
    // 링크 종류(0=url, 1=file_path) — url.len>0일 때만 의미. LinkKind 태그 순서(url=0, file_path=1)에 묶인다.
    if (out_kind) |k| k.* = @intFromEnum(app_session.url_kind);
    return @intFromEnum(Status.ok);
}

// 선택 텍스트 추출. 반환 버퍼는 Zig 소유로 다음 copy_text/destroy까지 유효하다. 비어 있으면 len 0.
pub export fn maru_macos_app_session_copy_text(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.copyText();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// OSC 52 클립보드 쓰기 데이터. 반환 버퍼는 Zig 소유로 다음 pending_clipboard/destroy까지 유효하다. write는
// 정책상 기본 allow(terminal-compatibility-policy.md §OSC52). 데이터 없으면 len 0. Swift가 tick마다 호출해 NSPasteboard에 쓴다.
pub export fn maru_macos_app_session_pending_clipboard(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const data = app_session.pendingClipboard();
    ptr_out.* = if (data.len > 0) data.ptr else null;
    len_out.* = data.len;
    return @intFromEnum(Status.ok);
}

// OSC 9/777·에이전트 완료 데스크톱 알림 데이터(title, body, surface_id, foreground). has_out=1이면 알림 있음
// (title/body 채움 — title은 빈 문자열일 수 있어 len으로 판단), 0이면 없음. surface_id_out=발신 Term의 surface.id로,
// Swift가 알림 userInfo에 (창 토큰, surface_id)로 실어 클릭 시 발신 터미널로 점프한다(activate_surface).
// foreground_out=앱이 전면일 때도 배너로 띄울지(1=에이전트 완료, 안 보는 탭이라 배너 / 0=OSC, 활성 surface가 보내
// 사용자가 보고 있을 수 있어 전면이면 목록만) — Swift willPresent가 읽어 표시 스타일을 정한다. 반환 버퍼는 Zig 소유로
// 다음 pending_notification/destroy까지 유효. Swift가 tick마다 호출해 UNUserNotificationCenter로 띄운다(알림은 OS
// 소유 — 코어/Zig는 데이터만 넘긴다). 네 값을 같은 drain 한 번으로 원자적으로 돌려준다(race 없음).
pub export fn maru_macos_app_session_pending_notification(
    session: ?*AppSession,
    has_out: ?*u32,
    title_ptr: ?*?[*]const u8,
    title_len: ?*usize,
    body_ptr: ?*?[*]const u8,
    body_len: ?*usize,
    surface_id_out: ?*u64,
    foreground_out: ?*u32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const has = has_out orelse return @intFromEnum(Status.null_out);
    const tp = title_ptr orelse return @intFromEnum(Status.null_out);
    const tl = title_len orelse return @intFromEnum(Status.null_out);
    const bp = body_ptr orelse return @intFromEnum(Status.null_out);
    const bl = body_len orelse return @intFromEnum(Status.null_out);
    const sid = surface_id_out orelse return @intFromEnum(Status.null_out);
    const fg = foreground_out orelse return @intFromEnum(Status.null_out);
    const n = app_session.pendingNotification() orelse {
        has.* = 0;
        tp.* = null;
        tl.* = 0;
        bp.* = null;
        bl.* = 0;
        sid.* = 0;
        fg.* = 0;
        return @intFromEnum(Status.ok);
    };
    has.* = 1;
    tp.* = if (n.title.len > 0) n.title.ptr else null;
    tl.* = n.title.len;
    bp.* = if (n.body.len > 0) n.body.ptr else null;
    bl.* = n.body.len;
    sid.* = n.surface_id;
    fg.* = if (n.foreground_banner) 1 else 0;
    return @intFromEnum(Status.ok);
}

// 데스크톱 알림 클릭 → 발신 surface로 활성화. Swift가 알림 userInfo의 (창 토큰, surface_id)에서 토큰으로 올바른
// 창/세션을 고른 뒤(창 키 활성화 makeKeyAndOrderFront도 Swift), 이 세션에 surface_id를 넘긴다. Zig가 (탭/panel/
// Term)을 역조회해 그 자리로 포커스한다(activateSurfaceById — switchTab→focusPaneByPtr→focusTerm 순서 단일 출처).
// 찾아서 활성화했으면 1, 그 surface가 이미 닫혔으면 0(무동작 — 창 활성화까지만). session null이면 0. take_bell과
// 같은 u32 반환 패턴(상태 코드가 아니라 found 여부). 배너 클릭으로 그 surface를 봤으니 인앱 센터의 같은 surface
// 알림도 읽음 처리한다(배너↔센터 동기화 — 닫힌 surface여도 읽음은 한다).
pub export fn maru_macos_app_session_activate_surface(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    const found = app_session.activateSurfaceById(surface_id);
    app_session.markNotificationsReadBySurface(surface_id);
    return if (found) 1 else 0;
}

// G12 BEL: 활성 세션에 pending 벨이 있으면 1(코어 플래그 비움), 없으면 0. Swift가 tick마다 호출해 시스템 벨
// (NSSound.beep)을 울린다(벨은 OS 소유). session이 null이면 0.
pub export fn maru_macos_app_session_take_bell(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeBell()) 1 else 0;
}

// Dock 배지 1회성 신호(config bell.dock-badge). BEL이 창 포커스 없을 때 울리면 1, 아니면 0. Swift가 매 tick 호출해
// 1이면 NSApp.dockTile.badgeLabel을 ●로 세운다(포커스 복귀 시 Swift가 지움). take_bell과 같은 1회성 패턴. session null=0. (v76)
pub export fn maru_macos_app_session_take_bell_badge(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeBellBadge()) 1 else 0;
}

// 세팅 GUI에서 notifications.agent-complete/osc를 켠 경우 macOS 알림 권한 요청을 Swift에 맡기는 1회성 신호.
// 권한 UI/API는 OS 소유라 Swift가 처리하고, Zig는 "사용자가 데스크톱 알림을 켰다"는 의도만 latch한다. (ABI v92)
pub export fn maru_macos_app_session_take_notification_authorization_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeNotificationAuthorizationRequest()) 1 else 0;
}

// macOS 시스템 외관(NSAppearance)이 다크(is_dark!=0)/라이트(0)인지 Swift가 알려준다(생성 직후·외관 변경마다). config
// theme.follow-system이 켜져 있으면 Zig가 theme.preset-light/dark 색 세트로 라이브 교체한다(꺼져 있으면 무시, write-back
// 없음). 외관 판정·관찰은 OS(Swift), 색 정책은 Zig. session null=무동작. (v77)
pub export fn maru_macos_app_session_set_system_appearance(session: ?*AppSession, is_dark: i32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.setSystemAppearance(is_dark != 0);
    return @intFromEnum(Status.ok);
}

// 창 뒤(데스크톱) 배경 블러의 유효 반경(px) — config window.blur, 단 window.opacity>=1이면 0(불투명 창=블러 안 보임).
// 블러는 GPU가 아니라 OS 창 속성이라(Metal은 backdrop을 못 읽음) host가 이 값을 OS API에 싣는다: macOS=CGSSetWindow-
// BackgroundBlurRadius(Ghostty·Terminal.app과 동일 비공개 CGS), Win=DwmSetWindowAttribute·Linux=컴포지터 속성(추후).
// 게이트 정책은 Zig 단일 출처(windowBlurRadius). 라이브 read(reload로 갱신) — Swift가 창 생성·config 반영 시 호출.
// session null=0(블러 끔). (ABI v79)
pub export fn maru_macos_app_session_window_blur_radius(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return app_session.windowBlurRadius();
}

// macOS app host frame-loop cadence(config render.frame-rate). Swift가 NSTimer 간격을 정할 때 읽는다.
// tick 본문은 계속 Zig가 소유하고, host는 clock만 제공한다. session null=기본 60Hz. (ABI v91)
pub export fn maru_macos_app_session_frame_rate_hz(session: ?*AppSession) u32 {
    const app_session = session orelse return maru.config.theme.render_frame_rate_default;
    return app_session.frameRateHz();
}

test "frame_rate_hz ABI getter: null default and session config clamp" {
    try std.testing.expectEqual(maru.config.theme.render_frame_rate_default, maru_macos_app_session_frame_rate_hz(null));
    var session: AppSession = undefined;
    session.loaded_config.config = .{};
    try std.testing.expectEqual(@as(u32, 60), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 120;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 999;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));
}

// 타이핑(글자 입력) 중 마우스 숨김 1회성 신호(config input.mouse-hide-while-typing). pending이면 1(플래그 비움),
// 없으면 0. Swift가 tick마다 호출해 1이면 NSCursor.setHiddenUntilMouseMoves(true)(다음 마우스 이동에서 자동 복원).
// take_bell과 같은 1회성 패턴 — 한 tick에 여러 글자를 쳐도 hide 호출은 한 번. session null=0. (ABI v72)
pub export fn maru_macos_app_session_take_mouse_hide(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeMouseHide()) 1 else 0;
}

// macOS Option을 Meta(Alt)로 쓰는지(config input.option-as-meta). 1=meta(현행 — Option+키 ESC-prefix 인코딩),
// 0=조합(입력기에 맡겨 Option+키가 특수문자 조합). Swift keyDown이 호출해 Option-단독 키를 입력기 경로로 보낼지
// (0) meta 인코딩 경로로 보낼지(1) 가른다. take_*와 달리 1회성 신호가 아니라 라이브 config 값 read(reload로 갱신).
// session null=1(현행 meta 폴백). (ABI v73)
pub export fn maru_macos_app_session_option_as_meta(session: ?*AppSession) u32 {
    const app_session = session orelse return 1;
    return if (app_session.optionAsMeta()) 1 else 0;
}

// 단축키 힌트 홀드 상태머신(keyhint_hold.zig)에 이벤트를 흘리고 Action을 돌려준다 — gesture 정책은 Zig, OS 타이머
// clock만 Swift(native 최소). 반환 Action(0=none·1=arm_timer·2=cancel·3=show·4=hide): Swift가 1=타이머 시작·2/4=타이머
// 무효화·3/4=markMetalNeedsRedraw로 매핑하고, visible 토글 자체는 머신이 chrome_host에 적용한다. mods_bits =
// 현재 눌린 modifier 비트(shift=1·control=2·option=4·command=8 — command_catalog.mod_*와 동일 인코딩). session null=0(none).
//
// **루트커즈(간헐 미표시)**: 옛 set_key_hints 경로는 Swift가 타이머 만료 콜백에서 NSEvent.modifierFlags(2번째 출처)를
// 다시 읽어 트리거 단독을 재확인했는데, 그 정적 읽기가 stale/빈 값이면 트리거를 쥐고 있어도 미표시였다. 이제 단일
// 출처(flagsChanged 이벤트 스트림)로 머신이 판정하고 만료는 글로벌을 안 읽는다(armed로 살아남음 = 유지됨). (ABI v88)
pub export fn maru_macos_app_session_key_hint_on_flags(session: ?*AppSession, mods_bits: u32) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    const mods: keyhint_hold.Mods = .{
        .command = (mods_bits & command_catalog.mod_command) != 0,
        .control = (mods_bits & command_catalog.mod_control) != 0,
        .option = (mods_bits & command_catalog.mod_option) != 0,
        .shift = (mods_bits & command_catalog.mod_shift) != 0,
    };
    return @intCast(@intFromEnum(app_session.keyHintOnFlags(mods)));
}
// 타이머 만료 → 머신. armed면 show(글로벌 재읽기 없음 — 루트커즈 수정). session null=0(none). (ABI v88)
pub export fn maru_macos_app_session_key_hint_on_timer(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    return @intCast(@intFromEnum(app_session.keyHintOnTimer()));
}
// keyDown(실제 단축키)·포커스 상실 → 머신 취소(표시 중이면 hide). session null=0(none). (ABI v88)
pub export fn maru_macos_app_session_key_hint_cancel(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    return @intCast(@intFromEnum(app_session.keyHintCancel()));
}

// 단축키 힌트 config(Swift 홀드 감지가 읽어 동작 결정) — out_enabled(1/0)·out_delay_ms·out_modifier(0=command·
// 1=control·2=option)에 채운다. gesture 정책은 Zig(config) 단일 출처, 타이머 clock만 Swift. 라이브 값 read
// (reload로 갱신, 1회성 신호 아님). out 포인터는 null이면 건너뛴다. session null=null_out. (ABI v87)
pub export fn maru_macos_app_session_key_hints_config(session: ?*AppSession, out_enabled: ?*u32, out_delay_ms: ?*u32, out_modifier: ?*u32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const cfg = app_session.keyHintConfig();
    if (out_enabled) |p| p.* = if (cfg.enabled) 1 else 0;
    if (out_delay_ms) |p| p.* = cfg.delay_ms;
    if (out_modifier) |p| p.* = cfg.modifier;
    return @intFromEnum(Status.ok);
}

// OS 클립보드 1회성 동작(input.right-click=paste·menu). 0=무동작, 1=copy, 2=paste. Zig가 우클릭/터미널 메뉴에서
// pending_clipboard_action을 세우고, Swift가 매 tick 호출해 1이면 copySelectionToPasteboard·2이면 pastePasteboardText를
// 부른다(클립보드는 OS 소유). take_bell과 같은 1회성 패턴 — drain하면 비워진다. session null=0. (ABI v74)
pub export fn maru_macos_app_session_take_clipboard_action(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intFromEnum(app_session.takeClipboardAction());
}

// OSC 52 읽기(`?` 쿼리)가 대기 중이고 osc52.read=allow면 1(Swift가 시스템 클립보드를 읽어 provide_clipboard_read로
// 돌려줘야 함), 아니면 0. 정책 게이트가 여기다(deny면 클립보드 안 읽음 — 탈취 방지). pending은 1회성 소비. session null=0. (v75)
pub export fn maru_macos_app_session_take_clipboard_read_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeClipboardReadRequest()) 1 else 0;
}

// take_clipboard_read_request가 1을 준 뒤, Swift가 읽은 시스템 클립보드 바이트를 넘긴다 — Zig가 base64 OSC 52 응답을
// 요청 surface PTY로 비차단 전송한다(`ESC ] 52 ; <Pc> ; <base64> ST`). bytes/len 0이면 빈 클립보드 응답. (v75)
pub export fn maru_macos_app_session_provide_clipboard_read(session: ?*AppSession, bytes: ?[*]const u8, len: usize) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |p| p[0..len] else &.{};
    app_session.provideClipboardRead(slice);
    return @intFromEnum(Status.ok);
}

// 세팅 window.background-image 행 활성으로 파일 선택창 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다
// 호출해 1이면 NSOpenPanel(PNG)을 열고 고른 경로를 provide_picked_file로 되돌린다. take_bell과 같은 1회성 신호. session null=0. (v81)
pub export fn maru_macos_app_session_take_file_pick_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFilePickRequest()) 1 else 0;
}

// take_file_pick_request가 1을 준 뒤, Swift가 NSOpenPanel에서 고른 파일의 절대경로를 넘긴다 — Zig가 window.background-image에
// setText + 라이브 반영(다음 frame 디코드) + dirty(영속). bytes/len 0(취소 등)이면 무동작. 지우기는 행 Backspace가 담당. (v81)
pub export fn maru_macos_app_session_provide_picked_file(session: ?*AppSession, bytes: ?[*]const u8, len: usize) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |p| p[0..len] else &.{};
    app_session.providePickedFile(slice);
    return @intFromEnum(Status.ok);
}

// HSV picker `i`(스포이드)로 화면 색 추출 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면
// NSColorSampler(OS 화면 색 추출기)를 열고 고른 색을 provide_sampled_color로 되돌린다. take_bell과 같은 1회성. session null=0. (v83)
pub export fn maru_macos_app_session_take_color_sample_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeColorSampleRequest()) 1 else 0;
}

// take_color_sample_request가 1을 준 뒤, Swift NSColorSampler 콜백이 고른 화면 픽셀 RGB를 넘긴다(비동기) — Zig가 picker
// 선택값(pick h/s/v)에 반영한다. r/g/b는 0~255(상위 비트는 무시 — u8로 truncate). picker가 닫혔으면 무시. (v83)
pub export fn maru_macos_app_session_provide_sampled_color(session: ?*AppSession, r: u32, g: u32, b: u32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.provideSampledColor(.{ .r = @truncate(r), .g = @truncate(g), .b = @truncate(b) });
    return @intFromEnum(Status.ok);
}

// view options(⚙) 사이드바 토글이 바뀌어 config 파일 반영이 필요하면 1(플래그 비움), 없으면 0. Swift가 tick마다
// 호출해 1이면 serialize_sidebar_config로 받은 텍스트를 config 경로에 atomic write한다(앱→config). session null=0.
pub export fn maru_macos_app_session_take_sidebar_config_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeConfigDirty()) 1 else 0;
}

// (x,y backing px)가 사이드바 헤더의 빈 영역(아이콘·검색 아님)이면 1 — Swift가 창 이동(performDrag)·더블클릭 확대(zoom)를
// 한다(네이티브 타이틀바 대체). 사이드바 접힘/헤더 없음/세션 null이면 0.
pub export fn maru_macos_app_session_is_window_drag_region(session: ?*AppSession, x_px: f64, y_px: f64) u32 {
    const app_session = session orelse return 0;
    return if (app_session.isWindowDragRegion(x_px, y_px)) 1 else 0;
}

// OSC 7로 셸이 보고한 현재 작업 디렉터리(percent-decode된 경로). 반환 버퍼는 Zig(core) 소유로
// 다음 OSC 7/RIS/destroy까지 유효하다. 한 번도 안 받았으면 len 0. Swift가 창 제목에 쓴다.
pub export fn maru_macos_app_session_cwd(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.currentCwd();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// config 파일 경로(Open Config 메뉴 — MARU_CONFIG override·$HOME/.config/maru/config, 규칙은 Zig loader가
// 단일 출처). 버퍼는 Zig 소유로 destroy까지 유효, HOME 없음/OOM이면 *out_ptr=NULL/*out_len=0(Swift 무동작).
pub export fn maru_macos_app_session_config_path(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.configPath();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// Reload Config 메뉴 — config 파일을 재로드해 재시작 없이 반영한다(폰트·여백·테마·palette·scrollback·bell·
// page-keys). 파싱은 forgiving, 로드 실패(OOM 등)면 무동작(기존 config 유지)이라 항상 Status.ok. 규칙(경로·
// 파싱)은 Zig loader가 단일 출처. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reload_config(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.reloadConfig();
    return @intFromEnum(Status.ok);
}

// Reset to Defaults 메뉴 — requestResetAll로 **확인 모달**을 연다(커맨드 팝업 "Reset All Settings to Defaults"와 같은
// 경로). 확정 시 모든 config를 내장 기본값으로 되돌리고 config 파일을 기본 상태(빈+주석)로 덮어쓴다(파괴적이라 무확인 즉시 실행 안 함 —
// 확정/취소는 다음 tick confirm 모달 입력으로). 항상 Status.ok. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reset_defaults(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.requestResetAll();
    return @intFromEnum(Status.ok);
}

// Reset 메뉴(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus 1004·mouse·kitty keyboard)만 끈다. ssh 너머 TUI가
// SIGKILL로 죽어 정리 못 한 모드가 raw 셸 입력을 오염시키는 증상(포커스마다 CSI I·비프)의 수동 회복 경로다.
// 화면·스크롤백은 보존한다(fullReset/RIS와 다름). 항상 Status.ok. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reset_input_modes(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.resetInputModes();
    return @intFromEnum(Status.ok);
}

// 창 제목으로 보여줄 문자열(OSC 0/2 제목 우선, 없으면 OSC 7 cwd basename). 우선순위는 core가
// 정한다(native 최소). 반환 버퍼는 Zig(core) 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효, 없으면
// len 0(Swift가 앱 이름으로 폴백). Swift가 window.title에 쓴다.
pub export fn maru_macos_app_session_window_title(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.windowTitle();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 이 창(세션)의 workspace restore 블록(헤더 없는 `window …` 라인)을 직렬화해 돌려준다. Swift가 멀티 창
// 저장에서 `maru.workspace.v1` 헤더 하나 아래로 각 세션 블록을 모은다. 버퍼는 Zig 소유(다음 호출/destroy까지
// 유효). 캡처/직렬화 실패(OOM 등)면 *out_len=0(Swift가 그 창을 건너뜀) — best-effort 저장이라 한 창 실패가
// 전체 저장을 막지 않는다.
pub export fn maru_macos_app_session_serialize_workspace(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.serializeWorkspaceWindow() catch {
        ptr_out.* = null;
        len_out.* = 0;
        return @intFromEnum(Status.ok);
    };
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 현재 sidebar 토글(show-branch/show-folder)을 반영한 갱신 config 텍스트를 직렬화해 돌려준다 — Swift가
// config 경로(maru_macos_app_session_config_path)에 atomic write한다(앱 view options 토글 → config 파일
// 양방향). 원본 config를 부분 갱신하므로 주석·미파싱 키를 보존한다. 버퍼는 Zig 소유(다음 호출/destroy까지
// 유효). 직렬화 실패(OOM 등)면 *out_len=0(Swift가 write를 건너뜀) — best-effort.
pub export fn maru_macos_app_session_serialize_sidebar_config(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.serializeConfig() catch {
        ptr_out.* = null;
        len_out.* = 0;
        return @intFromEnum(Status.ok);
    };
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 시작 시 저장된 workspace 텍스트(헤더 + N개 창 블록)에서 window_index번째 창을 parse해 이 세션에 복원 적용한다
// (R4b). **포맷 파싱은 전부 Zig가 소유한다** — Swift는 전체 텍스트와 인덱스만 넘기고 'window ' 경계를 직접 안
// 나눈다(파싱 권위가 Zig·Swift로 갈려 silent divergence 나는 걸 막음). parse 실패=invalid_config, 인덱스 범위
// 밖=invalid_config, apply 실패=create_failed, ok=적용됨. best-effort라 실패해도 그 창은 기본 단일 탭으로 남는다.
pub export fn maru_macos_app_session_apply_workspace_window(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
    window_index: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const tp = text_ptr orelse return @intFromEnum(Status.null_out);
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return @intFromEnum(Status.invalid_config);
    defer parsed.deinit(); // apply가 cwd 슬라이스를 spawn에 다 쓴 뒤 arena 해제(안전)
    if (window_index >= parsed.workspace.windows.len) return @intFromEnum(Status.invalid_config);
    app_session.applyWorkspaceWindow(parsed.workspace.windows[window_index]) catch return @intFromEnum(Status.create_failed);
    return @intFromEnum(Status.ok);
}

// 저장된 workspace 텍스트의 창 개수를 센다(Swift가 창마다 NSWindow를 만들기 위해). 헤더·포맷 검증도 겸한다:
// parse 실패(헤더 불일치·손상)면 -1을 돌려 Swift가 복원을 건너뛰게 한다(0이면 빈 workspace). 포맷 파싱은 Zig
// 단일 권위 — Swift는 'window ' 경계를 직접 안 나눈다. 세션 allocator로 parse(임시 arena, 즉시 해제).
pub export fn maru_macos_app_session_workspace_window_count(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
) i64 {
    const app_session = session orelse return -1;
    const tp = text_ptr orelse return -1;
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    return @intCast(parsed.workspace.windows.len);
}

// 전역(OS) 단축키 등록 기술자 목록. config에서 한 번 만들어 세션 동안 불변이라, Swift가 시작 시 한 번
// 읽어 Carbon RegisterEventHotKey로 등록한다. 배열은 app session 소유(destroy까지 유효). 비어 있으면
// out_ptr=null/out_count=0. 매핑 가능한 chord(가상 키코드 있음)만 담긴다.
pub export fn maru_macos_app_session_global_hotkeys(
    session: ?*AppSession,
    out_ptr: ?*?[*]const session_mod.GlobalHotkey,
    out_count: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const count_out = out_count orelse return @intFromEnum(Status.null_out);
    const hotkeys = app_session.globalHotkeys();
    ptr_out.* = if (hotkeys.len > 0) hotkeys.ptr else null;
    count_out.* = hotkeys.len;
    return @intFromEnum(Status.ok);
}

// quick terminal 표시 옵션(config에서 파싱, 세션 동안 불변). Swift가 시작/토글 시 읽어 패널 크기·화면·
// 자동 숨김에 쓴다. POD 복사라 소유권 문제 없음.
pub export fn maru_macos_app_session_quick_terminal_config(
    session: ?*AppSession,
    out_config: ?*session_mod.QuickTerminalConfig,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const config_out = out_config orelse return @intFromEnum(Status.null_out);
    config_out.* = app_session.quickTerminalConfig();
    return @intFromEnum(Status.ok);
}

// 커맨드 카탈로그(메뉴바·커맨드 팝업이 그릴 액션 목록). config/액션에서 만들고, keybind 변경(GUI rebind/unbind·config
// reload·reset)마다 Zig가 rebuildCommandCatalog로 재빌드한다 — 더는 세션-불변이 아니다. 재빌드 시 command_catalog_dirty를
// 세우고 Swift가 tick마다 take_command_catalog_dirty(v85)로 drain해 buildMainMenu로 메뉴바 keyEquivalent를 다시 깐다(reset은
// 모달-확정 후 tick에서 갱신). Zig-side 커맨드 팔레트는 command_key_displays를 매 빌드 라이브로 읽어 즉시 갱신된다. 배열·
// 문자열 전부 app session 소유(destroy까지 유효). 비어 있으면 out_ptr=null/out_count=0. global_hotkeys와 같은 패턴.
pub export fn maru_macos_app_session_command_catalog(
    session: ?*AppSession,
    out_ptr: ?*?[*]const session_mod.CommandEntry,
    out_count: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const count_out = out_count orelse return @intFromEnum(Status.null_out);
    const items = app_session.commandCatalog();
    ptr_out.* = if (items.len > 0) items.ptr else null;
    count_out.* = items.len;
    return @intFromEnum(Status.ok);
}

// 메뉴/팝업이 고른 액션 한 개를 실행한다 — action_key(카탈로그가 준 식별자) 바이트를 받아 Zig가
// parseAction → dispatchAppAction. 모르는 키면 invalid_config(무동작). 판정·실행은 Zig가 소유하고
// Swift는 문자열만 왕복한다(native 최소 — keybind 디스패치와 같은 규율).
pub export fn maru_macos_app_session_run_action(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    if (!app_session.runAction(ptr[0..len])) return @intFromEnum(Status.invalid_config);
    return @intFromEnum(Status.ok);
}

// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면(rows-1) 계산은 app session이
// 권위 있는 rows로 한다(Swift가 stale frame summary로 계산하지 않게).
pub export fn maru_macos_app_session_scroll_page(
    session: ?*AppSession,
    delta_pages: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.scrollPage(delta_pages);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_focus_changed(
    session: ?*AppSession,
    gained: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.focusChanged(gained != 0);
    return @intFromEnum(Status.ok);
}

// 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트 점프(OSC 133 semantic prompt — Cmd+↑/↓).
// 분류·이동은 app session/core가 권위 있게 하고 Swift는 방향만 넘긴다(native 최소).
pub export fn maru_macos_app_session_jump_prompt(
    session: ?*AppSession,
    dir: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.jumpToPrompt(if (dir < 0) -1 else 1);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_destroy(session: ?*AppSession) void {
    // 수명 계약: destroy는 단발성이다. null은 안전하게 무시하지만, 이미 해제된 handle은
    // 감지할 수 없으므로(메모리가 freed) 같은 non-null handle로 두 번 호출하면 use-after-free /
    // double-free다. caller(Swift host)는 destroy 직후 handle을 nil로 비워 재호출을 막아야
    // 한다. 반복 호출이 안전한 idempotent 종료가 필요하면 close()를 쓴다.
    const app_session = session orelse return;
    app_session.deinit();
    allocator.destroy(app_session);
}

pub export fn maru_macos_app_session_metal_frame(
    session: ?*AppSession,
    out_frame: ?*AppMetalFrame,
) c_int {
    // 가장 최근 tick의 RenderFrame을 Metal DTO(cells/atlas uploads/raster pixels)로 노출한다.
    // 포인터는 app session이 소유한 retained 배열을 가리키며 다음 tick까지 유효하다. caller는
    // 같은 main thread에서 tick 직후 동기적으로 읽는다.
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_frame orelse return @intFromEnum(Status.null_out);
    out.* = app_session.metalFrame();
    return @intFromEnum(Status.ok);
}

// 전역(OS) 단축키가 라이브로 바뀌어(세팅 GUI 녹음/해제·reload·reset) OS 재등록이 필요하면 1(플래그 비움), 없으면 0.
// Swift가 tick마다 호출해 1이면 unregisterGlobalHotkeys 후 registerGlobalHotkeys로 새 global_hotkeys를 OS에 다시 깐다.
// take_bell과 같은 1회성 신호 — drain하면 비워진다. session null=0. (v82)
pub export fn maru_macos_app_session_take_global_hotkeys_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeGlobalHotkeysDirty()) 1 else 0;
}

// 커맨드 카탈로그가 런타임에 재빌드돼(keybind rebind/unbind·reload·reset → rebuildCommandCatalog) 메뉴바 재빌드가
// 필요하면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면 buildMainMenu로 NSMenu keyEquivalent를 새 카탈로그로
// 다시 깐다. reset은 확인 모달 확정 후 다음 tick에 갱신되므로 동기 호출이 아니라 이 신호가 단일 경로다(인앱 rebind·멀티창
// 활성 세션도 같이 커버). take_global_hotkeys_dirty와 같은 1회성 신호. session null=0. (v85)
pub export fn maru_macos_app_session_take_command_catalog_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeCommandCatalogDirty()) 1 else 0;
}

fn keyEventFromAbi(event: KeyEvent) !terminal.KeyEvent {
    // 레이아웃 독립 단축키: Ctrl/Cmd 조합인데 현재 입력 소스의 글자가 라틴이 아니면(한글 'ㅂ'
    // 등 >= 0x80) 물리 키코드를 US 배열 라틴으로 되돌린다 — 한글 모드에서도 Ctrl+B가 0x02로
    // 인코딩된다(멀티플렉서 prefix 등). 라틴 레이아웃(영어/Dvorak)의 결과는 존중해 건드리지 않는다.
    var codepoint = event.codepoint;
    if ((event.modifier_control != 0 or event.modifier_command != 0) and codepoint >= 0x80) {
        if (keycode.usAsciiForKeyCode(event.raw_key_code)) |latin| codepoint = latin;
    }

    // base codepoint(kitty CSI u의 key code용 — shift 미반영 base-layout)도 codepoint와 같은
    // 레이아웃 독립 처리를 받는다(한글 모드 Ctrl+Shift도 US 라틴 base로 매칭). 유효 Unicode scalar가
    // 아니면 null로 두어 encodeKitty가 Key.char codepoint로 폴백한다.
    var base_codepoint = event.base_codepoint;
    if ((event.modifier_control != 0 or event.modifier_command != 0) and base_codepoint >= 0x80) {
        if (keycode.usAsciiForKeyCode(event.raw_key_code)) |latin| base_codepoint = latin;
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
        .base_codepoint = if (base_codepoint != 0 and base_codepoint <= 0x10ffff and (base_codepoint < 0xd800 or base_codepoint > 0xdfff))
            @intCast(base_codepoint)
        else
            null,
        // G10: numpad 키 판정은 macOS 물리 키코드로(platform). application keypad 모드면 encodeKey가 SS3로.
        .keypad = keycode.isKeypad(event.raw_key_code),
    };
}
test "macOS app host ABI header and Zig declarations stay aligned" {
    // Swift는 C header를 보고, Zig는 이 파일의 extern struct를 쓴다. 둘의 숫자와
    // layout이 갈라지면 다음 제품 앱 PR에서 런타임 버그가 되므로 컴파일 단계에서 막는다.
    try std.testing.expectEqual(@as(u32, c.MARU_MACOS_APP_HOST_ABI_VERSION), abi_version);
    // url_at out_kind 계약: @intFromEnum(LinkKind)를 그대로 싣고 Swift handleUrlClick이 kind==1=file_path로 분기한다.
    // LinkKind 순서를 바꾸면 분기가 silent하게 뒤집히므로(웹↔파일) 태그 값을 고정한다(C typedef 없는 enum 가드 — Status/EventKind 선례).
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(terminal.LinkKind.url));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(terminal.LinkKind.file_path));
    // workspace 헤더도 .h define과 Zig 단일 출처(session.workspace.header)가 갈라지면 저장/로드가 어긋나므로 고정.
    try std.testing.expectEqualStrings(c.MARU_WORKSPACE_HEADER, maru.session.workspace.header);
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
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostCommandControlledSmoke)), @intFromEnum(AppCommandKind.controlled_smoke));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCapabilities), @sizeOf(Capabilities));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCapabilities), @alignOf(Capabilities));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostKeyEvent), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostResizeEvent), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostSessionConfig), @sizeOf(AppSessionConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostSessionConfig), @alignOf(AppSessionConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostQuickTerminalConfig), @sizeOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostQuickTerminalConfig), @alignOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostQuickTerminalChromeMinimal), @intFromEnum(maru.config.theme.QuickTerminalChrome.minimal));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostQuickTerminalPositionCenter), @intFromEnum(maru.config.theme.QuickTerminalPosition.center));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCommand), @sizeOf(session_mod.CommandEntry));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCommand), @alignOf(session_mod.CommandEntry));
    // CommandEntry는 동일-폭 포인터 4개라 @sizeOf가 필드 reorder를 못 잡는다 — @offsetOf로 C↔Zig 위치를
    // 대조한다(AppMetalFrame 포인터 필드 선례와 동형). title↔action_key 등이 뒤바뀌면 Swift가 잘못된 문자열을 읽는다.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "action_key"), @offsetOf(session_mod.CommandEntry, "action_key"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "title"), @offsetOf(session_mod.CommandEntry, "title"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_display"), @offsetOf(session_mod.CommandEntry, "key_display"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_equivalent"), @offsetOf(session_mod.CommandEntry, "key_equivalent"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_modifiers"), @offsetOf(session_mod.CommandEntry, "key_modifiers"));
    // GlobalHotkey ABI 정합(전역 단축키 enumerate가 out_ptr로 노출) — 이전엔 대조가 통째로 빠져 있었다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGlobalHotkey), @sizeOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGlobalHotkey), @alignOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostFrameSummary), @sizeOf(AppFrameSummary));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostFrameSummary), @alignOf(AppFrameSummary));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalCell), @sizeOf(AppMetalCell));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalCell), @alignOf(AppMetalCell));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalRasterUpload), @sizeOf(AppMetalRasterUpload));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalRasterUpload), @alignOf(AppMetalRasterUpload));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalFrame), @sizeOf(AppMetalFrame));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalFrame), @alignOf(AppMetalFrame));
    // append-only면 @sizeOf가 필드 존재를 강제하지만, 같은 폭(포인터/usize) 필드 reorder는 못 잡는다 — C4b가
    // 추가한 포인터/인덱스 필드는 @offsetOf로 C↔Zig 위치를 대조한다(GpuQuad 선례와 동형).
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_quads"), @offsetOf(AppMetalFrame, "gpu_quads"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_shadows"), @offsetOf(AppMetalFrame, "gpu_shadows"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "modal_cells_start"), @offsetOf(AppMetalFrame, "modal_cells_start"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuQuad), @sizeOf(AppGpuQuad));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuQuad), @alignOf(AppGpuQuad));
    // 모든 필드가 4B라 @sizeOf만으론 필드 reorder(예: corner_radii↔border_widths)를 못 잡는다 — offset도 대조한다.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "corner_radii"), @offsetOf(AppGpuQuad, "corner_radii"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "border_widths"), @offsetOf(AppGpuQuad, "border_widths"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "fill_color0"), @offsetOf(AppGpuQuad, "fill_color0"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "gradient_kind"), @offsetOf(AppGpuQuad, "gradient_kind"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "layer"), @offsetOf(AppGpuQuad, "layer"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuShadow), @sizeOf(AppGpuShadow));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuShadow), @alignOf(AppGpuShadow));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "corner_radii"), @offsetOf(AppGpuShadow, "corner_radii"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "blur_radius"), @offsetOf(AppGpuShadow, "blur_radius"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "color"), @offsetOf(AppGpuShadow, "color"));
    // kitty graphics(K2c): 이미지 드로우/업로드 프리미티브 + frame 채널. append-only라 @sizeOf가 필드 존재를
    // 강제하지만, 같은 폭 필드(GpuImage는 전부 4B, frame은 포인터/usize)는 reorder를 못 잡으므로 offset도 대조한다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuImage), @sizeOf(AppGpuImage));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuImage), @alignOf(AppGpuImage));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "dest_x"), @offsetOf(AppGpuImage, "dest_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "origin_x"), @offsetOf(AppGpuImage, "origin_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "src_u0"), @offsetOf(AppGpuImage, "src_u0"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "z"), @offsetOf(AppGpuImage, "z"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "pass"), @offsetOf(AppGpuImage, "pass"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuImageUpload), @sizeOf(AppGpuImageUpload));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuImageUpload), @alignOf(AppGpuImageUpload));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "generation"), @offsetOf(AppGpuImageUpload, "generation"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "pixels_offset"), @offsetOf(AppGpuImageUpload, "pixels_offset"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "pixels_len"), @offsetOf(AppGpuImageUpload, "pixels_len"));
    // frame에 추가된 kitty graphics 채널 필드(append-only) — 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_images"), @offsetOf(AppMetalFrame, "gpu_images"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "image_uploads"), @offsetOf(AppMetalFrame, "image_uploads"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "image_pixels"), @offsetOf(AppMetalFrame, "image_pixels"));
    // K4c: 텍스처 eviction용 live image id 집합 채널.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "live_image_ids"), @offsetOf(AppMetalFrame, "live_image_ids"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "live_image_id_count"), @offsetOf(AppMetalFrame, "live_image_id_count"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "terminal_bg"), @offsetOf(AppMetalFrame, "terminal_bg"));
    // v66: 상단 타이틀바 띠 높이(접힘 펼치기 토글 ◧ 세로 중앙 정렬용) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "titlebar_strip_px"), @offsetOf(AppMetalFrame, "titlebar_strip_px"));
    // v70: 창 배경 투명도 × 1000(clear color alpha) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "window_opacity_milli"), @offsetOf(AppMetalFrame, "window_opacity_milli"));
    // v86: 사이드바 세로 스크롤량(px) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "sidebar_scroll_offset_px"), @offsetOf(AppMetalFrame, "sidebar_scroll_offset_px"));
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
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(AppSessionConfig)); // 10 u32(abi/cols/rows/queue/cmd/chrome_minimal/minimal_tabs + width_px/height_px/scale_milli)
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(AppFrameSummary)); // +quit_decision(u32) + 8 정렬 패딩(168→176, ABI v90)
    try std.testing.expectEqual(@as(usize, 8), @alignOf(AppFrameSummary));
}
test "macOS app exported session API reports null outputs as ABI errors" {
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_create(&config, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_tick(null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_key_down(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_resize(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_close(null, null),
    );
    // v18~v21 신규 IME/focus export도 null session을 ABI 오류로 닫는지 — 헤더에 선언만 되고
    // 계약 테스트가 안 건드리던 공백(리뷰 #13)을 메운다(심볼 존재 + null-safety 동시 확인).
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_begin(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_insert(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_marked(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_end(null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_delete_backward(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_set_focus(null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_cursor_rect(null, null, null, null, null));
    // v40 chrome Notice: null session은 ABI 오류, null bytes(len>0)도 오류, len==0은 무동작 ok(붙여넣기와 같은 규율).
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_show_notice(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_show_notice(null, "x", 1));
}

test {
    std.testing.refAllDecls(session_mod);
    // 전역 핫키 descriptor 매핑(a2의 Swift가 ABI로 소비)도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("global_hotkey.zig"));
    // 커맨드 카탈로그(메뉴바·팝업 공유) round-trip·chord 포맷 테스트도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("command_catalog.zig"));
    // 커맨드 팝업 상태머신(필터·선택·selectedAction) 테스트도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("command_palette.zig"));
    // 스크롤백 Find는 chrome 컴포넌트(maru.chrome.components.find)로 이주 — 그 테스트는 maru.chrome 집계가 포함.
}

test "layout-independent shortcut: Hangul-mode Ctrl+B normalizes to latin b via the physical keycode" {
    // 한글 입력 모드에서 Ctrl+B: AppKit 글자는 'ㅂ'(0x3142)이지만 물리 키코드는 B(0x0B).
    const event = KeyEvent{
        .codepoint = 0x3142, // 'ㅂ'
        .base_codepoint = 0x3142, // shift 없음 → base도 'ㅂ'; keyEventFromAbi가 US 'b'로 정규화
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
    // 인코딩까지: Ctrl+b -> 0x02 (멀티플렉서 prefix가 한글 모드에서도 동작).
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const encoded = try terminal.input.encodeKey(key_event, &buffer, .{});
    try std.testing.expectEqualSlices(u8, &.{0x02}, encoded);
}

test "latin layouts are preserved: Ctrl+B with an ascii codepoint does not consult the keycode table" {
    // Dvorak 등 라틴 배열: 현재 레이아웃 결과(ASCII)를 존중한다 — 물리 키코드로 덮지 않는다.
    const event = KeyEvent{
        .codepoint = 'x', // Dvorak에서 다른 물리 키가 'x'를 낼 수 있다
        .base_codepoint = 'x',
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
            return .{ .codepoint = 0, .base_codepoint = 0, .key_code = @intFromEnum(code), .modifier_shift = 0, .modifier_control = 0, .modifier_option = 0, .modifier_command = 0, .is_repeat = 0, .raw_key_code = 0 };
        }
    }.f;
    try std.testing.expectEqual(terminal.input.Key.delete, (try keyEventFromAbi(mk(.delete))).key);
    try std.testing.expectEqual(terminal.input.Key.page_up, (try keyEventFromAbi(mk(.page_up))).key);
    try std.testing.expectEqual(terminal.input.Key.home, (try keyEventFromAbi(mk(.home))).key);
    try std.testing.expectEqual(@as(u8, 1), (try keyEventFromAbi(mk(.f1))).key.function);
    try std.testing.expectEqual(@as(u8, 12), (try keyEventFromAbi(mk(.f12))).key.function);
}

test "keypad Enter chains through ABI to terminal .enter (keypad=true) — confirm 모달이 닫히고, app keypad는 SS3" {
    // 키패드 Enter는 Swift normalizedKeyEvent가 메인 Return과 같이 key_code=Enter로 매핑하고 codepoint=0으로 넘긴다.
    // raw_key_code=0x4C(kVK_ANSI_KeypadEnter)라 keycode.isKeypad가 keypad=true를 채운다. 회귀: 이 매핑이 빠지면
    // codepoint(NSEnterCharacter 0x03)가 흘러 `.char`가 되고, chrome 확인 모달의 `.enter` 분기가 안 잡혀 안 닫혔다.
    const abi_event = KeyEvent{
        .codepoint = 0, // Swift가 keypad Enter를 잡아 codepoint를 비운다(default로 안 떨어짐)
        .base_codepoint = 0,
        .key_code = @intFromEnum(KeyCode.enter),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x4C, // kVK_ANSI_KeypadEnter
    };
    const ev = try keyEventFromAbi(abi_event);
    try std.testing.expectEqual(terminal.input.Key.enter, ev.key); // chrome 모달의 `.enter` 경로를 탄다
    try std.testing.expect(ev.keypad); // numpad 판정은 물리 키코드로 보존
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    // numeric(기본) keypad → CR. application keypad(DECKPAM) → SS3 `ESC O M`. raw 0x03이 아니다.
    try std.testing.expectEqualStrings("\r", try terminal.input.encodeKey(ev, &buf, .{}));
    try std.testing.expectEqualStrings("\x1bOM", try terminal.input.encodeKey(ev, &buf, .{ .application_keypad = true }));
}

test "Option+Backspace chains through ABI to meta-DEL (\\e\\x7f, word delete)" {
    const abi_event = KeyEvent{
        .codepoint = 0,
        .base_codepoint = 0,
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
