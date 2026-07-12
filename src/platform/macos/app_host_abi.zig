const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const session_mod = @import("app_session.zig");
const keycode = @import("keycode.zig");
const keyhint_hold = maru.session.keyhint_hold; // OS-중립 홀드 gesture 정책(session L2 — session/keyhint_hold.zig)
const command_catalog = @import("command_catalog.zig");
const control_server_mod = @import("control_server.zig"); // Track C A2b: 라이브 컨트롤 서버(소켓+accept 스레드+marshal)
const control_socket = @import("control_socket.zig"); // 1b: formatInstanceKey(인스턴스 키)
const control_dispatch = maru.session.control_dispatch; // 1d: read-only 바이트→바이트 디스패치 라우터 + 1e dispatchAuthenticated
const control_browser = maru.session.control_browser; // 5e: browser.* op·응답 직렬화(dispatchAuthenticated가 산출한 op을 marshal)
const control_surface = maru.session.control_surface; // 1c: Surface DTO/CollectorSnapshot
const control_capability = maru.session.control_capability; // 1e: capability fd resolve(라이브 auth 배선)

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
    // cross-window 이동(M3d-2a) 실패 — 잘못된 워크스페이스 인덱스(InvalidCoordinate)·dst 용량 확보 실패(OOM)·범위 밖
    // 워크스페이스(UnsupportedMove: pinned·그룹은 M3d-2a-ii). Swift 미소비(M3d-2b가 배선하며 app_host_abi.h에 미러). 이
    // 한 event만 거부이고 세션은 유지(fault 아님).
    move_failed = 10,
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
    frame_loop_rate_hz: u32,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    app_session.setFrameLoopRateHz(frame_loop_rate_hz);
    app_session.maybeDebugOpenSettings(); // MARU_OPEN_SETTINGS 시각 확인 훅 — tick(렌더) 전에 열어야 이 frame에 모달이 든다(env 미설정이면 무동작)
    app_session.maybeDebugOpenWebPanel(); // MARU_WEB_PANEL 시각 확인 훅 — 활성 pane에 web Term을 열고 활성화(4e-2, 본문 blank·크래시 0; env 미설정이면 무동작)
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

/// 호스트가 매 tick 주입하는 "이 세션이 앱의 마지막(유일) 일반 창인가"(1=마지막·0=아님). Zig 리프 세션은 형제
/// NSWindow를 알 수 없으므로 platform(Swift)이 windows.count로 알려준다. 마지막 창일 때 ⌘W/사이드바·탭바 ✕로 세션을
/// 닫으면 requestClose가 창 하나 닫기 대신 Cmd+Q와 동일한 "maru를 종료할까요?" 종료 확인을 띄운다(마지막 창 닫기=앱
/// 종료). quick 스크래치·멀티 창의 비-마지막 창은 0. 순수 setter라 구조체 offset 불변. 단일 출처: docs/macos-app-host-boundary.md.
pub export fn maru_macos_app_session_set_last_window(session: ?*AppSession, is_last: u32) void {
    const app_session = session orelse return;
    app_session.is_last_window = is_last != 0;
}

/// cross-window 이동(M3d-2a) 결과 — status(ok/move_failed/null_out) + 소스 창이 비어 닫아야 하는지(§8A.2) + 이동한
/// surface 수(§8A.3). 라이브 배선(M3d-2b Swift)이 source_window_closed=1일 때 NSWindow를 닫는다(판정은 Zig, close는 platform).
pub const MoveResult = extern struct {
    status: c_int,
    source_window_closed: u32,
    moved_count: u32,
};

// 이동 에러(InvalidCoordinate/OutOfMemory/UnsupportedMove)를 MoveResult로 접는다 — 셋 다 move_failed(세션 유지, 이 event만 거부).
fn moveResultError(out: *MoveResult) c_int {
    out.* = .{ .status = @intFromEnum(Status.move_failed), .source_window_closed = 0, .moved_count = 0 };
    return @intFromEnum(Status.move_failed);
}

// moved_count는 **참 이동 개수**(code-review [6]) — caller가 넘긴다. outcome.moved_surfaces는 아래 export의 [256]u64
// 버퍼에 절단될 수 있어(>256=비현실적) len으로 세면 under-report하므로, 수술 전에 센 참값(workspaceSurfaceCount/
// totalSurfaceCount)을 쓴다.
fn moveResultOk(out: *MoveResult, outcome: maru.session.MoveOutcome, moved_count: usize) c_int {
    out.* = .{
        .status = @intFromEnum(Status.ok),
        .source_window_closed = @intFromBool(outcome.source_window_closed),
        .moved_count = @intCast(moved_count),
    };
    return @intFromEnum(Status.ok);
}

/// M3d-2a-i cross-window workspace 이동(docs/window-surface-mobility.md §8A.8) — src 세션의 src_index 워크스페이스를 dst
/// 세션으로 옮긴다. registry/routing을 안 건드리므로 surface가 재시작하지 않는다(§9). out.source_window_closed=1이면 소스
/// 창이 비어 Swift가 닫아야 한다(실제 NSWindow close·목적지 focus는 **M3d-2b**가 배선 — 현재 Swift 미호출, plan-link 주석).
/// src/dst/out null이면 null_out, 잘못된 인덱스나 OOM이면 move_failed.
pub export fn maru_macos_app_session_move_workspace_to(
    src: ?*AppSession,
    dst: ?*AppSession,
    src_index: usize,
    out: ?*MoveResult,
) c_int {
    const s = src orelse return @intFromEnum(Status.null_out);
    const d = dst orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    // 참 이동 개수를 수술 **전에** 센다(버퍼 절단과 무관, code-review [6]). idx 범위 밖이면 0 — 이동 자체도 아래서 실패.
    const moved_count = s.workspaceSurfaceCount(src_index);
    var buf: [256]u64 = undefined; // moved surface_id 버퍼(초과분은 조용히 절단 — MoveOutcome 계약, moved_count는 참값 별도 보고)
    if (moved_count > buf.len) std.log.warn("move_workspace_to: moved surface_id buffer truncated ({d} > {d}) — moved_count is exact", .{ moved_count, buf.len });
    const outcome = s.moveWorkspaceToSession(d, src_index, &buf) catch return moveResultError(o);
    return moveResultOk(o, outcome, moved_count);
}

/// M3d-2a-i 전체 window merge(§1·§4) — src 세션의 **모든** 워크스페이스를 dst로 옮기고 src를 비운다(source_window_closed
/// 항상 1). surface 무재시작(§9). Swift 미호출(M3d-2b가 배선 — plan-link). src/dst/out null이면 null_out, OOM이면 move_failed.
pub export fn maru_macos_app_session_merge_window(
    src: ?*AppSession,
    dst: ?*AppSession,
    out: ?*MoveResult,
) c_int {
    const s = src orelse return @intFromEnum(Status.null_out);
    const d = dst orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    // 참 이동 개수(버퍼 절단과 무관, [6]): self-merge(s==d)는 no-op이라 0, 아니면 src 전체 surface. 수술 전에 센다.
    const moved_count: usize = if (s == d) 0 else s.totalSurfaceCount();
    var buf: [256]u64 = undefined;
    if (moved_count > buf.len) std.log.warn("merge_window: moved surface_id buffer truncated ({d} > {d}) — moved_count is exact", .{ moved_count, buf.len });
    const outcome = s.mergeSessionInto(d, &buf) catch return moveResultError(o);
    return moveResultOk(o, outcome, moved_count);
}

// M3d-2b 단일 카드 이동 배선 — src 세션의 **활성** 워크스페이스(탭) 인덱스를 Swift에 준다. Swift 메뉴 "Move Workspace
// to Window ▸ <창>"이 이 인덱스를 move_workspace_to(src,dst,idx)에 넘겨 활성 카드 하나만 옮긴다(merge_window은 전체라
// 인덱스 불요). read-only(take_bell류 u32 반환 — 상태 코드가 아니라 값). session null·surface 미초기화·탭 전무면
// sentinel(maxInt u32)을 돌려주고 Swift가 무동작한다(이동 로직은 늘리지 않음 — 이미 있는 move_workspace_to 재사용).
pub export fn maru_macos_app_session_active_workspace_index(session: ?*AppSession) u32 {
    const app_session = session orelse return std.math.maxInt(u32);
    const idx = app_session.activeWorkspaceIndex() orelse return std.math.maxInt(u32);
    return @intCast(idx);
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

// 웹 패널 포커스 중 Cmd 조합이 maru 앱 바인딩(app_action)인지 **side-effect 없이** 조회한다(PTY write·상태 변경 0).
// Swift 웹 performKeyEquivalent가 1이면 가로채 keyDown 경로로 라우팅(⌘T·⌘⇧P·⌘F·⌘A·⌘K …), 0이면 메뉴바 keyEquivalent
// (⌘Q/H/M)·WebKit(⌘C/V) 편집·terminal 매크로(⌘Backspace/←/→)에 양보한다 — 옛 "웹 포커스 중 모든 Cmd 조합 가로채 셸로"
// 버그(⌘Q 종료 안 됨·⌘Backspace가 셸로 샘) 수정. handleKeyEvent와 같은 keyBindingResolver 단일 출처. session/event
// null이거나 event 변환 실패면 0(앱 바인딩 아님 → 양보). docs/web-panel.md §4.
pub export fn maru_macos_app_session_key_is_app_action(session: ?*AppSession, event: ?*const KeyEvent) u32 {
    const app_session = session orelse return 0;
    const raw_event = (event orelse return 0).*;
    const key_event = keyEventFromAbi(raw_event) catch return 0;
    return if (app_session.keyResolvesToAppAction(key_event)) 1 else 0;
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

// macOS app host frame-loop cadence(config render.frame-rate). Swift가 NSTimer 간격을 정할 때 읽는 config 희망값이다.
// 실제 tick 시간 환산은 maru_macos_app_session_tick의 frame_loop_rate_hz 인자로 받은 host 전역 cadence를 쓴다. (ABI v91/v93)
pub export fn maru_macos_app_session_frame_rate_hz(session: ?*AppSession) u32 {
    const app_session = session orelse return maru.config.theme.render_frame_rate_default;
    return app_session.configuredFrameRateHz();
}

test "frame_rate_hz ABI getter: null default and session config clamp" {
    try std.testing.expectEqual(maru.config.theme.render_frame_rate_default, maru_macos_app_session_frame_rate_hz(null));
    var session: AppSession = undefined;
    session.loaded_config.config = .{};
    session.frame_loop_rate_hz = maru.config.theme.render_frame_rate_default;
    try std.testing.expectEqual(@as(u32, 60), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 120;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 999;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));

    session.setFrameLoopRateHz(30);
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session)); // getter는 config 희망값
    try std.testing.expectEqual(@as(u32, 30), session.frameRateHz()); // 내부 시간 환산은 host cadence
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
    is_active: u32,
    has_frame: u32,
    frame_x: i32,
    frame_y: i32,
    frame_w: i32,
    frame_h: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    // is_active(!=0) = 이 창이 저장 시점 key 창(Swift window.isKeyWindow). 활성 창만 workspace.v1 옵션-키
    // active-window=1을 내고, 재시작 복원이 그 창을 다시 focus한다(M3e). false면 키 생략(옛 파일 flat 동일).
    // has_frame(!=0) = Swift window.frame(전역 스크린 좌표 점)을 저장. win-x/y/w/h 옵션-키를 내고 재시작 복원이
    // 그 위치·크기·모니터로 setFrame한다(M3f). 0이면 키 생략(옛 파일 flat 동일 → cascade). x/y는 음수 가능(보조 모니터).
    const frame: ?maru.session.workspace.Frame = if (has_frame != 0)
        .{ .x = frame_x, .y = frame_y, .w = frame_w, .h = frame_h }
    else
        null;
    const text = app_session.serializeWorkspaceWindow(is_active != 0, frame) catch {
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

// 저장된 workspace 텍스트에서 활성(key) 창의 인덱스를 준다(M3e — docs/window-surface-mobility.md §8A.8). Swift가 복원
// loop 뒤 이 인덱스의 창을 makeKeyAndOrderFront해 재시작 후 활성 창을 되살린다. active-window=1 마커가 있는 첫 창의
// 인덱스, 없으면(옛 파일·무마커) -1 → Swift 무동작(현행 동작 = 마지막 생성 창 key). parse 실패도 -1(count와 같은
// 조용한 폴백). 포맷 파싱은 Zig 단일 권위 — Swift는 창 경계를 안 나눈다. 세션 allocator로 parse(임시 arena, 즉시 해제).
pub export fn maru_macos_app_session_workspace_active_window(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
) i64 {
    const app_session = session orelse return -1;
    const tp = text_ptr orelse return -1;
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    const idx = maru.session.workspace.activeWindowIndex(parsed.workspace) orelse return -1;
    return @intCast(idx);
}

// 저장된 workspace 텍스트에서 window_index 창의 픽셀(점) frame(전역 스크린 좌표)을 out_x/y/w/h로 준다(M3f —
// docs/window-surface-mobility.md §8A.8). Swift 복원 loop가 창마다 이 값을 받아 clamp 후 setFrame해 재시작 후
// 위치·크기·모니터를 되살린다. 반환: 1=frame 있음(out_* 채움), 0=없음(옛 파일·부분 필드 → Swift가 현행 기본 cascade
// 유지), -1=parse 실패·null 인자(count와 같은 조용한 폴백). 포맷 파싱은 Zig 단일 권위. 세션 allocator로 parse(임시
// arena, 즉시 해제). workspace_active_window와 동형의 read-only getter다.
pub export fn maru_macos_app_session_workspace_window_frame(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
    window_index: usize,
    out_x: ?*i32,
    out_y: ?*i32,
    out_w: ?*i32,
    out_h: ?*i32,
) c_int {
    const app_session = session orelse return -1;
    const tp = text_ptr orelse return -1;
    const px = out_x orelse return -1;
    const py = out_y orelse return -1;
    const pw = out_w orelse return -1;
    const ph = out_h orelse return -1;
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    const fr = maru.session.workspace.windowFrame(parsed.workspace, window_index) orelse return 0; // 없음/부분/범위밖
    px.* = fr.x;
    py.* = fr.y;
    pw.* = fr.w;
    ph.* = fr.h;
    return 1;
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

// quick terminal 표시 옵션(config에서 파싱). Swift가 매 토글마다 읽어 auto_hide·화면 모드·chrome 재생성 판정에
// 쓴다(세션의 현재 config 라이브 스냅샷 — 세션-불변 아님, 설정 변경 반영). 패널 사각형은 quick_terminal_frames가
// 따로 계산한다. POD 복사라 소유권 문제 없음.
pub export fn maru_macos_app_session_quick_terminal_config(
    session: ?*AppSession,
    out_config: ?*session_mod.QuickTerminalConfig,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const config_out = out_config orelse return @intFromEnum(Status.null_out);
    config_out.* = app_session.quickTerminalConfig();
    return @intFromEnum(Status.ok);
}

// quick 패널 보임/숨김 사각형 — Swift가 대상 화면 visibleFrame(vf_*, macOS 좌표 minX/minY/width/height)을 넘기면
// 세션의 **현재** config(위치·두께·center 폭)로 계산해 돌려준다. quick_terminal_config와 달리 세션-불변 스냅샷이
// 아니라 매 호출 라이브라 설정 GUI 변경이 다음 토글에서 바로 반영된다. 순수 계산 + POD 복사.
pub export fn maru_macos_app_session_quick_terminal_frames(
    session: ?*AppSession,
    vf_x: f64,
    vf_y: f64,
    vf_w: f64,
    vf_h: f64,
    out_frames: ?*session_mod.QuickTerminalFrames,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const frames_out = out_frames orelse return @intFromEnum(Status.null_out);
    frames_out.* = app_session.quickTerminalFrames(vf_x, vf_y, vf_w, vf_h);
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

// Phase 4e-3: 웹 Term(WKWebView) surface 전이 ABI DTO. app_host_abi.h의 MaruAppHostWebSurfaceTransition과 layout 정합
// (아래 계약 테스트가 size/offset 강제). op·panel_kind·visible은 u32로 marshaling(session_mod.WebSurfaceOp/PanelKind ↔
// 값 정합). `visible`은 op 뒤 pad 자리에 들어가 struct size가 v99와 같다(op·visible이 8B, 이어서 surface_id 8B 정렬).
pub const WebSurfaceTransitionAbi = extern struct {
    op: u32,
    visible: u32, // create: 1=즉시 show, 0=hidden 생성. show/reframe=함의상 1, hide/destroy 무의미.
    surface_id: u64,
    panel_kind: u32,
    seam_edges: u32, // divider 맞닿는 가장자리 비트마스크(L=1·R=2·B=4). panel_kind 뒤 f64 정렬 pad 자리 → struct size 불변(ABI v103).
    frame_pt_x: f64,
    frame_pt_y: f64,
    frame_pt_w: f64,
    frame_pt_h: f64,
};

// Phase 4e-3: 이번 tick의 web surface 전이 batch 개수. Zig가 활성 워크스페이스 탭 pane 트리를 walk해 web Term 집합을
// 직전 tick 집합과 4a surfaceDiff한 batch를 **계산·보관**하고 개수를 돌려준다(command_catalog식 count+at). Swift가 tick당
// 정확히 한 번 호출해(계산·prev 전진이 여기서 일어난다) count를 받은 뒤 web_surface_transition_at으로 각 전이를 읽어
// dict[surface_id]의 WKWebView에 create/destroy/reframe/hide/show를 적용한다. session null=0.
pub export fn maru_macos_app_session_web_surface_transitions_count(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intCast(app_session.webSurfaceTransitionsCount());
}

// index번째 web surface 전이를 out에 marshaling한다(위 count 이후, 같은 tick·스레드). Zig가 4a 순수 계산으로 diff한
// 결과를 marshaling만 한다 — NSView 연산은 Swift(op 적용). session/out null이면 null_out, 범위 밖이면 op=none으로 ok.
pub export fn maru_macos_app_session_web_surface_transition_at(
    session: ?*AppSession,
    index: u32,
    out: ?*WebSurfaceTransitionAbi,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    const t = app_session.webSurfaceTransitionAt(index);
    o.* = .{
        .op = @intFromEnum(t.op),
        .visible = if (t.visible) 1 else 0,
        .surface_id = t.surface_id,
        .panel_kind = switch (t.panel_kind) {
            .markdown => 0,
            .browser => 1,
        },
        .seam_edges = t.seam_edges,
        .frame_pt_x = t.frame_pt.x,
        .frame_pt_y = t.frame_pt.y,
        .frame_pt_w = t.frame_pt.w,
        .frame_pt_h = t.frame_pt.h,
    };
    return @intFromEnum(Status.ok);
}

// Phase 7e-1a: browser(비신뢰) 웹 패널의 WKWebView nav 상태(현재 url·canGoBack·canGoForward)를 per-surface로 저장한다.
// Swift KVO(MaruWebPanelView)가 url/canGoBack/canGoForward 변화를 관측해 dirty면 tick drain에서 이걸 호출한다 —
// 관측·marshaling은 Swift(L4 어댑터), 저장·정책은 Zig(setWebNavState). can_go_back/forward는 i32 bool(0/1), url_ptr가
// null이면 빈 url. session null=null_out. 소비(주소창 렌더)는 7e-1b. provide_picked_file과 같은 Swift→Zig setter 스타일.
pub export fn maru_macos_app_session_set_web_nav_state(
    session: ?*AppSession,
    surface_id: u64,
    can_go_back: i32,
    can_go_forward: i32,
    url_ptr: ?[*]const u8,
    url_len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const url: []const u8 = if (url_ptr) |p| p[0..url_len] else &.{};
    app_session.setWebNavState(surface_id, can_go_back != 0, can_go_forward != 0, url);
    return @intFromEnum(Status.ok);
}

// surface_id에 저장된 nav url을 out에 복사하고 그 길이를 돌려준다(스모크가 Swift KVO → set_web_nav_state → 저장 →
// getter 왕복을 값으로 검증). 엔트리 없으면 0(빈 url 저장도 0), session/out이 null이면 -1, out_cap 부족이면 -2.
// url_at/notification_title_out과 같은 per-surface borrowed-string out-ptr 패턴(단 값 복사 — 여기선 out 버퍼로).
pub export fn maru_macos_app_session_web_nav_url_at(
    session: ?*AppSession,
    surface_id: u64,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const app_session = session orelse return -1;
    const out = out_ptr orelse return -1;
    const state = app_session.webNavState(surface_id) orelse return 0;
    if (state.url.len > out_cap) return -2;
    @memcpy(out[0..state.url.len], state.url);
    return @intCast(state.url.len);
}

// Phase 7e-2b: 주소창 편집 신호 drain(7e-2a Zig 코어의 1회성 pending을 Swift가 tick마다 뺀다 — take_bell 패턴).
// (1) focus-pull: 밴드 클릭으로 편집 진입 시 세워지는 "키보드 포커스를 터미널 뷰로" 신호(편집 keyDown이 Zig로
//     흐르게). Swift가 1이면 focusTerminalView. surface_id는 활성 surface라 값 불요 → bool(1=있음).
pub export fn maru_macos_app_session_take_web_addr_focus_pull(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeWebAddrFocusPull() != null) 1 else 0;
}

// (2) navigate: Enter(commit)가 세운 로드 요청 — resolved url을 out에 쓰고 surface_id를 out-ptr에 실어 url 길이를
//     돌려준다(없으면 -1). Swift가 webPanels[surface_id].webView에 BrowserControl.navigate(url). null 인자/용량 부족은
//     pending을 소비하기 전에 -1(신호 유실 방지 — Swift는 늘 유효 인자).
pub export fn maru_macos_app_session_take_web_addr_navigate(
    session: ?*AppSession,
    url_out: ?[*]u8,
    url_cap: usize,
    surface_id_out: ?*u64,
) i64 {
    const app_session = session orelse return -1;
    const uo = url_out orelse return -1;
    const so = surface_id_out orelse return -1;
    const nav = app_session.takeWebAddrNavigate() orelse return -1;
    if (nav.url.len > url_cap) return -1; // 방어(resolveNavUrl이 이미 세션 버퍼 cap 제한)
    @memcpy(uo[0..nav.url.len], nav.url);
    so.* = nav.surface_id;
    return @intCast(nav.url.len);
}

// (3) focus-restore: commit/cancel 후 키보드 포커스를 그 web 패널 WKWebView로 복원할 대상 surface_id(out-ptr).
//     Swift가 1이면 makeFirstResponder(webPanels[surface_id].webView). 없으면 0. surface_id 0은 미발급이라 out-ptr로 실어 구분.
pub export fn maru_macos_app_session_take_web_addr_focus_restore(session: ?*AppSession, surface_id_out: ?*u64) c_int {
    const app_session = session orelse return 0;
    const so = surface_id_out orelse return 0;
    if (app_session.takeWebAddrFocusRestore()) |sid| {
        so.* = sid;
        return 1;
    }
    return 0;
}

// Phase 7e-3: 주소창 nav 버튼 클릭 신호 drain(tick마다). 밴드 좌측 버튼 존(back/forward/reload) 클릭이 **활성 버튼**일 때
// Zig 코어가 세운 1회성 pending을 뺀다(take_web_addr_focus_restore 패턴). 반환: action code(-1=없음, 0=back·1=forward·
// 2=reload), surface_id는 out-ptr. Swift가 code에 따라 BrowserControl.goBack/goForward/reload(webPanels[surface_id].webView).
// session/out null이면 -1(pending 미소비 — Swift는 늘 유효 인자).
pub export fn maru_macos_app_session_take_web_nav_action(session: ?*AppSession, surface_id_out: ?*u64) i32 {
    const app_session = session orelse return -1;
    const so = surface_id_out orelse return -1;
    if (app_session.takeWebNavAction()) |act| {
        so.* = act.surface_id;
        return @intCast(act.code); // 0=back·1=forward·2=reload
    }
    return -1;
}

// Phase 7e-4: 주소창 nav 버튼 키보드 단축키(browser 웹 패널 포커스 한정 Cmd+←/→/R)를 Zig 코어로 전달한다. Swift
// performKeyEquivalent가 panelKind==browser일 때만 code(0=back·1=forward·2=reload)로 마샬링해 부른다. Zig는
// setBrowserNavAction(밴드 클릭 ①b와 공유하는 활성 판정 단일 정책)으로 web_nav_action_pending을 세우고, 같은 tick의
// take_web_nav_action drain이 BrowserControl.goBack/goForward/reload를 실행한다(클릭 경로 재사용 — 키보드는 pending을
// 세우는 진입점만 다르다). 반환: 1=전달함(활성 무관 — 활성 게이트는 코어), 0=session null/알 수 없는 code(무동작).
pub export fn maru_macos_app_session_browser_nav(session: ?*AppSession, surface_id: u64, code: u32) c_int {
    const app_session = session orelse return 0;
    const btn: session_mod.NavButton = switch (code) {
        0 => .back,
        1 => .forward,
        2 => .reload,
        else => return 0, // 알 수 없는 code — 무동작
    };
    app_session.setBrowserNavAction(surface_id, btn);
    return 1;
}

// Phase 7e-4 후속: 활성 pane의 활성 term이 browser web이면 그 surface_id, 아니면 0(browser 아님/null session). Swift
// performKeyEquivalent가 browser nav 단축키(⌘←/→/R)를 이 값 == 이 패널 surface_id일 때만 처리해, WKWebView 키보드
// 포커스 유무와 무관하게 "지금 활성 탭이 browser면" 동작하게 한다(탭만 열어 봐도 되게). split의 비활성 pane 브라우저는
// 0으로 걸러진다. 순수 read getter — 구조체 offset 불변.
pub export fn maru_macos_app_session_active_web_surface_id(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.activeWebSurfaceId();
}

// Phase 4g-0: 활성 pane 활성 term이 web(browser·markdown 무관)이면 surface_id, 아니면 0. focus-sync 불변식(§4.1)
// Direction 1(Zig 활성 pane → firstResponder)이 "활성이 web이면 그 webview 포커스, 아니면 터미널 뷰"를 정하는 데 쓴다
// (activeWebSurfaceId는 browser 전용이라 markdown 활성 시 0을 줘 터미널로 오포커스). 순수 read getter — 구조체 offset 불변.
pub export fn maru_macos_app_session_active_web_surface_id_any_kind(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.activeWebSurfaceIdAnyKind();
}

// Phase 4g-1 후속(14차 리뷰 [0][3]): 입력이 터미널 뷰→Zig 경로로 가야 하는가(모달[notice 제외] 또는 주소창 편집·
// rename·사이드바 검색 활성). focus-sync 불변식(reconcileWebFocus)의 **override 단일 출처** — 1이면 웹뷰가 아니라
// 터미널 뷰가 firstResponder여야 한다. 옛 addr_edit_surface getter를 대체(그건 rename·사이드바 검색을 빠뜨려 web pane
// 활성 중 그 편집이 웹뷰로 새고 notice까지 세는 버그였다). 순수 read — 구조체 offset 불변.
pub export fn maru_macos_app_session_terminal_owns_input(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.terminalOwnsInput()) 1 else 0;
}

// Phase 7f-0: 새 창/팝업 adopt — Swift `WKUIDelegate.createWebViewWith`가 WebKit config로 만든 WKWebView를 붙일
// browser web Term을 활성 pane에 새 탭으로 만들고 그 surface_id를 반환한다(Swift-first 동기 생성 — 소유·시점 역전).
// Swift는 이 id로 pre-created webview를 webPanels에 키잉하고, drain은 존재 시 중복 생성을 스킵한다(7f-1). 반환:
// 새 surface_id(>=1), 또는 0(null session·생성 실패 sentinel). 신규 export만 — 구조체 offset 불변.
pub export fn maru_macos_app_session_create_adopted_web_term(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.createAdoptedWebTermInActivePane() catch 0;
}

// ── Phase 5c-2: maru-app:// asset resolve (경로 샌드박스 5c-1 + realpath symlink 탈출 방어, platform I/O) ──────
//
// 신뢰 패널의 WKURLSchemeHandler(5c-2b Swift)가 `maru-app://<host>/<path>` 요청을 받으면 이 함수로 **번들 asset root
// 아래 안전한 절대 경로**를 얻어 그 파일을 CSP와 함께 서빙한다. 5c-1 `validateAppPath`(문자열: `..`·whitelist)로 못 잡는
// **symlink 탈출**을 realpath로 막는다 — candidate와 root를 각각 realpath해 canonical candidate가 canonical root **아래**인지
// 확인(심링크가 root 밖을 가리키면 realpath가 밖을 반환 → 거부). I/O라 L2가 아니라 여기(platform).
pub const AppAssetError = error{
    /// 5c-1 문자열 검증 실패(traversal `..`·whitelist 밖·너무 긺) — 요청 자체가 부적격.
    Reject,
    /// candidate가 존재하지 않거나 일반 파일이 아님(디렉터리 등) → 404.
    NotFound,
    /// realpath 결과가 asset root 밖 — symlink 탈출 등. 거부(정보 노출 방지).
    OutsideRoot,
};

fn pathIsUnder(p: []const u8, root: []const u8) bool {
    // p == root/... : root로 시작하고 그 다음 문자가 경로 구분자('/')여야 root의 **하위**다(root 자신·형제 접두 배제).
    if (p.len <= root.len) return false;
    if (!std.mem.startsWith(u8, p, root)) return false;
    return p[root.len] == '/';
}

/// `maru-app://` 요청 경로를 asset root 아래 안전한 **절대 경로**로 resolve한다(5c-1 문자열 + realpath symlink 방어).
/// 성공 시 canonical 절대 경로를 `out`에 쓰고 슬라이스를 돌려준다(Swift가 그 파일을 읽어 CSP와 서빙). `root_abs`는 절대
/// 경로(Swift가 Bundle asset root 전달). 빈 경로(`/`)는 `index.html`로 매핑한다. `io`는 platform I/O(Swift C-ABI 래퍼는
/// 5c-2b에서 host io를 전달; 여기 테스트는 std.testing.io).
pub fn resolveAppAsset(io: std.Io, root_abs: []const u8, request_path: []const u8, out: []u8) AppAssetError![]const u8 {
    var clean_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clean = maru.session.app_scheme.validateAppPath(request_path, &clean_buf) catch |e| switch (e) {
        error.Empty => "index.html", // 루트 요청(`/`·`""`) → index 문서
        else => return AppAssetError.Reject, // Traversal·InvalidChar·TooLong
    };
    var join_buf: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = std.fmt.bufPrint(&join_buf, "{s}/{s}", .{ root_abs, clean }) catch return AppAssetError.Reject;
    const dir = std.Io.Dir.cwd();
    var cand_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cn = dir.realPathFile(io, candidate, &cand_buf) catch return AppAssetError.NotFound; // symlink 따라감·부재면 실패
    const cand_real = cand_buf[0..cn];
    // root를 요청마다 canonicalize한다(리뷰11 [7]): 상수 root라 잉여 realpath지만, 이 함수는 **stateless**(호출 간
    // 상태 없음)라는 정책 계약을 지키려는 의도적 선택이다. 캐싱하려면 Zig에 상태를 두거나 canonical-root 전용 export를
    // 추가해 어댑터가 1회 canonicalize+캐시해야 하는데, 현재 asset 수(placeholder 3개, Phase 7도 modest)에선 realpath
    // 비용이 무시가능이라 그 API 복잡도/보안 계약 약화 리스크를 지지 않는다. Phase 7이 서브리소스 다량 서빙으로 실측
    // 지연이 생기면 그때 canonical-root 캐시 export로 분리한다.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rn = dir.realPathFile(io, root_abs, &root_buf) catch return AppAssetError.Reject;
    const root_real = root_buf[0..rn];
    if (!pathIsUnder(cand_real, root_real)) return AppAssetError.OutsideRoot; // symlink 탈출 방어(canonical 비교)
    const st = dir.statFile(io, cand_real, .{}) catch return AppAssetError.NotFound;
    if (st.kind != .file) return AppAssetError.NotFound; // 디렉터리·특수 파일은 서빙 안 함
    if (cand_real.len > out.len) return AppAssetError.Reject;
    @memcpy(out[0..cand_real.len], cand_real);
    return out[0..cand_real.len];
}

// maru-app:// asset resolve C-ABI(5c-2b): Swift WKURLSchemeHandler(5c-2c)가 요청 경로를 안전한 절대 경로로 resolve한다.
// 정책(경로 샌드박스·realpath 탈출 방어)은 여기 Zig가 소유하고, Swift는 반환 경로의 바이트를 읽어 CSP와 서빙만 한다
// (docs/web-panel.md §10 "정책은 테스트 가능한 Zig, Swift는 WebKit 어댑터"). 반환: **>=0** = `out`에 쓴 canonical 절대
// 경로 길이. **음수** = 에러 코드(-1 Reject=문자열 거부, -2 NotFound=부재/디렉터리, -3 OutsideRoot=symlink 탈출,
// -4 null 포인터). io는 앱 전역 single-threaded(다른 export와 동일 출처).
pub export fn maru_macos_app_resolve_app_asset(
    root_ptr: ?[*]const u8,
    root_len: usize,
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const rp = root_ptr orelse return -4;
    const qp = req_ptr orelse return -4;
    const op = out_ptr orelse return -4;
    const io = std.Io.Threaded.global_single_threaded.io();
    const resolved = resolveAppAsset(io, rp[0..root_len], qp[0..req_len], op[0..out_cap]) catch |e| return switch (e) {
        error.Reject => -1,
        error.NotFound => -2,
        error.OutsideRoot => -3,
    };
    return @intCast(resolved.len);
}

// maru-app:// 응답 CSP 헤더 문자열(5c-2c). **단일 출처 = maru.session.app_scheme.csp_header** — Swift 핸들러가 문자열을
// 중복해 들지 않고 1회 읽어 캐시한다(doc↔code drift 방지, docs/web-panel.md §7.1 ③). out에 복사하고 길이를 돌려준다.
// cap 부족이면 -1, out null이면 -2.
pub export fn maru_macos_app_csp_header(out_ptr: ?[*]u8, out_cap: usize) i64 {
    const op = out_ptr orelse return -2;
    const csp = maru.session.app_scheme.csp_header;
    if (csp.len > out_cap) return -1;
    @memcpy(op[0..csp.len], csp);
    return @intCast(csp.len);
}

// Phase 7f-2: 새 창/팝업(WKUIDelegate.createWebViewWith) 대상 URL 정책 게이트. Swift가 navigationAction.request.url을
// 넘기면 app_scheme.popupTargetAllowed(허용 = about·http·https·빈만, javascript·file·data·blob·maru-app 등 거부)로
// 판정한다 — 정책 단일 출처=Zig, 어댑터=Swift(url 추출·차단). 반환: 1=허용, 0=거부, -1=url_ptr null. 세션리스 순수
// 정책(csp_header 동형).
pub export fn maru_macos_app_popup_target_allowed(url_ptr: ?[*]const u8, url_len: usize) c_int {
    const up = url_ptr orelse return -1;
    return if (maru.session.app_scheme.popupTargetAllowed(up[0..url_len])) 1 else 0;
}

// Track C 5b: 신뢰 웹 브리지(window.maru.*) 요청 디스패치(5b-1 코어). Swift가 신뢰(markdown) 패널의 isolated
// WKContentWorld 메시지 핸들러 진입에서 **frameInfo.isMainFrame + securityOrigin(maru-app://app) exact-pin을 먼저
// 검증**(신뢰 게이트)한 뒤, 통과한 요청 JSON 한 줄을 넘기면 control_bridge.dispatchBridge로 응답 JSON을 만들어 out에
// 쓴다. 정책=Zig(디스패치·wire), 어댑터=Swift(world·핸들러·origin 검증). server_version은 소켓 hello와 같은 단일
// 출처(control_hello_version). 반환: >=0 = out에 쓴 응답 길이. -1=out 용량 부족, -2=NULL 포인터, -3=OOM.
pub export fn maru_macos_app_bridge_dispatch(
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const rp = req_ptr orelse return -2;
    const op = out_ptr orelse return -2;
    const reply = maru.session.control_bridge.dispatchBridge(allocator, rp[0..req_len], control_hello_version) catch return -3;
    defer allocator.free(reply);
    if (reply.len > out_cap) return -1;
    @memcpy(op[0..reply.len], reply);
    return @intCast(reply.len);
}

test "maru_macos_app_bridge_dispatch export: hello=len>0, 미지원=method_not_found 응답, null=-2" {
    var out: [512]u8 = undefined;
    const hello = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\"}";
    const n = maru_macos_app_bridge_dispatch(hello.ptr, hello.len, &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..@intCast(n)], "server_version") != null);
    // 미지원 method도 **응답 바이트**(method_not_found 에러)를 돌려준다(음수 아님 — dispatch가 정상 처리).
    const bad = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nope\"}";
    const m = maru_macos_app_bridge_dispatch(bad.ptr, bad.len, &out, out.len);
    try std.testing.expect(m > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..@intCast(m)], "-32601") != null);
    // NULL 포인터 → -2.
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_bridge_dispatch(null, 0, &out, out.len));
}

test "maru_macos_app_csp_header export: 단일출처 복사 + cap 부족 -1 + null -2" {
    var buf: [512]u8 = undefined;
    const n = maru_macos_app_csp_header(&buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings(maru.session.app_scheme.csp_header, buf[0..@intCast(n)]);
    var tiny: [4]u8 = undefined; // csp_header보다 작음 → -1
    try std.testing.expectEqual(@as(i64, -1), maru_macos_app_csp_header(&tiny, tiny.len));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_csp_header(null, 512));
}

test "maru_macos_app_resolve_app_asset export: 정상=len>0, traversal=-1, 부재=-2, null=-4" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];

    var out: [std.fs.max_path_bytes]u8 = undefined;
    // 정상: resolved 절대 경로 길이(양수)를 돌려주고 out에 canonical 경로를 씀.
    const n = maru_macos_app_resolve_app_asset(root_abs.ptr, root_abs.len, "index.html", 10, &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.endsWith(u8, out[0..@intCast(n)], "/index.html"));
    // traversal → -1(Reject), 부재 → -2(NotFound), null root → -4.
    try std.testing.expectEqual(@as(i64, -1), maru_macos_app_resolve_app_asset(root_abs.ptr, root_abs.len, "../x", 4, &out, out.len));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_resolve_app_asset(root_abs.ptr, root_abs.len, "nope.html", 9, &out, out.len));
    try std.testing.expectEqual(@as(i64, -4), maru_macos_app_resolve_app_asset(null, 0, "index.html", 10, &out, out.len));
}

test "resolveAppAsset: 정상 파일 서빙 + 빈 경로 → index" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<html>root</html>" });
    try root_tmp.dir.createDirPath(io, "sub");
    try root_tmp.dir.writeFile(io, .{ .sub_path = "sub/page.html", .data = "<html>sub</html>" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];

    var out: [std.fs.max_path_bytes]u8 = undefined;
    const idx = try resolveAppAsset(io, root_abs, "index.html", &out);
    try std.testing.expect(pathIsUnder(idx, root_abs));
    try std.testing.expect(std.mem.endsWith(u8, idx, "/index.html"));

    var out2: [std.fs.max_path_bytes]u8 = undefined;
    const root_req = try resolveAppAsset(io, root_abs, "/", &out2); // 빈→index
    try std.testing.expect(std.mem.endsWith(u8, root_req, "/index.html"));

    var out3: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try resolveAppAsset(io, root_abs, "sub/page.html", &out3);
    try std.testing.expect(std.mem.endsWith(u8, sub, "/sub/page.html"));
    try std.testing.expect(pathIsUnder(sub, root_abs));
}

test "resolveAppAsset: traversal(`..`)·whitelist 밖 → Reject(5c-1 문자열 단계)" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, root_abs, "../index.html", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, root_abs, "a/../../etc/passwd", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, root_abs, "%2e%2e/x", &out)); // `%` whitelist 밖
}

test "resolveAppAsset: symlink 탈출 → OutsideRoot(realpath canonical 방어)" {
    const io = std.testing.io;
    // out_tmp/secret.txt(root 밖) + root/evil → 그 절대 경로 symlink. resolve는 canonical이 root 밖이라 거부.
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    try out_tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "SECRET" });
    var sec_buf: [std.fs.max_path_bytes]u8 = undefined;
    const secret_abs = sec_buf[0..try out_tmp.dir.realPathFile(io, "secret.txt", &sec_buf)];

    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    root_tmp.dir.symLink(io, secret_abs, "evil", .{}) catch |e| switch (e) {
        error.AccessDenied => return error.SkipZigTest, // 일부 FS는 symlink 불가
        else => return e,
    };
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.OutsideRoot, resolveAppAsset(io, root_abs, "evil", &out));
}

test "resolveAppAsset: 부재 파일·디렉터리 → NotFound" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.createDirPath(io, "adir");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.NotFound, resolveAppAsset(io, root_abs, "nonexistent.html", &out));
    try std.testing.expectError(AppAssetError.NotFound, resolveAppAsset(io, root_abs, "adir", &out)); // 디렉터리는 서빙 안 함
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
// ══ 세션 컨트롤 플레인 라이브 서버(Track C A2b) ══════════════════════════════════════════════════════════════
// 단일 출처: docs/control-plane.md §2(collector 2층)·§5(메인 marshal)·§8.4(auth 한계)·§16.
//  - 소켓 bind·accept 스레드·marshal 큐는 control_server.zig(generic L4)가 소유.
//  - 실 collector 조립(창마다 collectSessionInto)·auth 판정(A2b metadata:self)·dispatch(1d)는 여기서 — AppSession을
//    아는 유일한 L4 층이라(§16 코드배치 gate: app_session.zig 인접 L4 허용).
//  - Swift는 (1) start 1회, (2) 매 tick drain(살아있는 세션 목록), (3) stop만 부른다(§2 열거만).

/// 세션(창) collector 참조 — Swift가 창마다 채운다. app_host_abi.h `MaruControlSessionRef`와 layout 일치.
pub const ControlSessionRef = extern struct {
    app_session: ?*AppSession,
    window_id: u64,
    window_kind: u32,
    reserved: u32 = 0,
};

/// 앱 인스턴스 전역 라이브 서버(주소 안정 필요 — accept 스레드가 &storage를 잡는다). 메인 스레드만 active 토글/drain을
/// 만진다(server 내부 필드는 자체 동기화). 서버 미시작(bind 실패 등)이면 컨트롤 플레인만 꺼지고 앱은 계속 산다.
var control_server_storage: control_server_mod.ControlServer = undefined;
var control_server_active: bool = false;

/// 라이브 capability store(§8.5 1e). **메인 스레드 전용**(handleControlRequest가 메인 drain에서만 read — accept
/// 스레드는 절대 안 만진다, §8.8 lock-order). 지금은 **비어 있다**: 실 fd 발급/상속(§8.5, 1e-confirm/후속)이 아직
/// 없어 nonce를 실은 요청은 전부 default-deny(unauthorized)다. nonce 없는 요청은 기존 metadata:self 경로(회귀 없음).
/// dispatchAuthenticated가 이 store로 nonce→scope를 resolve한다. 발급 경로가 붙으면 여기 issueForFd로 채운다.
var control_cap_store: control_capability.CapabilityStore = .{};

/// 5e-2b: browser op 큐 엔트리. `arg`는 cross_gpa 소유(method별 인자 — navigate=url·executeScript=script·getUrl=빈).
const BrowserOpEntry = struct { async_id: u64, surface_id: u64, op_kind: u8, arg: []const u8 };

/// 5e-2b: browser op FIFO 큐(**메인 스레드 전용** — handleControlRequest가 push, take_browser_op가 pop해 Swift가
/// 실행). accept가 serial이라 실질 ≤1이나 bounded(`max`)로 견고성 유지. push 성공 시 `arg` 소유권을 큐가 인수한다.
const BrowserOpQueue = struct {
    items: std.ArrayList(BrowserOpEntry) = .empty,
    max: usize = 8,

    /// bounded push. 초과면 `error.Full`(호출자가 arg free + 요청 에러 resolve). 성공 시 arg 소유권 인수.
    fn push(self: *BrowserOpQueue, gpa: std.mem.Allocator, e: BrowserOpEntry) error{ Full, OutOfMemory }!void {
        if (self.items.items.len >= self.max) return error.Full;
        try self.items.append(gpa, e);
    }
    /// FIFO pop(없으면 null). 반환 엔트리의 arg 소유권은 호출자로 이전(호출자가 free).
    fn take(self: *BrowserOpQueue) ?BrowserOpEntry {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
    /// 남은 op의 arg 해제 + 리스트 해제(서버 종료 시).
    fn deinit(self: *BrowserOpQueue, gpa: std.mem.Allocator, arg_gpa: std.mem.Allocator) void {
        for (self.items.items) |e| arg_gpa.free(e.arg);
        self.items.deinit(gpa);
    }
};
var browser_op_queue: BrowserOpQueue = .{};
/// take_browser_op이 pop한 op의 arg를 **다음 take까지** 살려 Swift가 이 호출 중 동기 복사하게 하는 안정 슬롯(app allocator).
var browser_op_take_buf: std.ArrayList(u8) = .empty;
/// hung WKWebView op 마감(reap) — evaluateJavaScript/navigation이 영영 안 끝나는 op가 accept 스레드를 영구 붙잡는 것 방어.
const browser_op_timeout_ns: i128 = 30 * std.time.ns_per_s;

/// hello가 광고하는 read-only 메서드(현재 구현된 것만 — §11 help gate와 같은 정직성).
const control_hello_caps = [_][]const u8{ "sessions.list", "session.get" };
const control_hello_version = "0.1.0";
/// 한 drain(tick)에서 처리할 요청 상한(§5 per-tick 예산). accept 스레드 1개·in-flight ≤1이라 실질 여유.
const control_drain_budget: usize = 32;

fn appHostIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// 결정론 컨트롤 base dir `<cache>/maru`(§4.2)를 buf에 NUL 종단으로 만든다. XDG_CACHE_HOME 우선, 없으면 HOME/.cache.
/// 못 정하면 null. Server.bind가 `<base>/control`을 mkdir하므로 caller(start)가 `<base>`까지 존재를 보장한다.
fn controlBaseDir(buf: []u8) ?[:0]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const xs = std.mem.span(x);
        if (xs.len > 0) return std.fmt.bufPrintZ(buf, "{s}/maru", .{std.mem.trimEnd(u8, xs, "/")}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    const hs = std.mem.span(home);
    if (hs.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}/.cache/maru", .{std.mem.trimEnd(u8, hs, "/")}) catch null;
}

/// 인스턴스 nonce(§4.2 "부팅 nonce") — 파일명 유일성용(암호 비밀 아님). macOS arc4random_buf로 8바이트 채운다.
fn instanceNonce() u64 {
    var bytes: [8]u8 = undefined;
    std.c.arc4random_buf(&bytes, bytes.len);
    return std.mem.readInt(u64, &bytes, .little);
}

/// 살아있는 세션들(refs)을 창마다 `collectSessionInto`로 평탄화해 하나의 CollectorSnapshot으로 조립한다(§2). 스냅샷은
/// `arena` 메모리를 빌린다(caller가 arena 수명 관리). app_session=NULL 항목은 건너뛴다. 순수 조립 — 테스트가 실 AppSession으로 커버.
fn collectSessionsInto(refs: []const ControlSessionRef, arena: std.mem.Allocator) std.mem.Allocator.Error!control_surface.CollectorSnapshot {
    var surfaces: std.ArrayList(control_surface.SurfaceDto) = .empty;
    var windows: std.ArrayList(maru.session.WindowMembershipSnapshot) = .empty;
    for (refs) |ref| {
        const app = ref.app_session orelse continue;
        const kind = std.enums.fromInt(maru.session.WindowKind, ref.window_kind) orelse .normal;
        try app.collectSessionInto(arena, ref.window_id, kind, &surfaces, &windows);
    }
    return .{ .surfaces = surfaces.items, .windows = windows.items };
}

/// 한 요청을 실 collector + auth(1e capability) + dispatch(1d)로 처리해 응답 바이트(server.cross_gpa 소유)를 만든다.
/// **1e**: `dispatchAuthenticated`가 auth 프레임의 `{selector, cap_nonce}`(pending)와 라이브 `control_cap_store`로
/// `(caller, scope)`를 발급한다 — cap_nonce 없으면 기존 metadata:self(§8.4 A2b, 회귀 없음), 있으면 resolve(빈 store라
/// 지금은 default-deny). **§8.4 self 경로 한계 유지**: nonce 없는 same-uid peer는 임의 surface를 self로 주장할 수 있고
/// tty/pgrp 검증(1g)은 없다 → 그 한 surface의 metadata만(§8.3 self 필터). `now`=**모노토닉 awake 초**(TTL 판정용, 순수
/// 코어에 주입 — 미래 fd 발급도 같은 시계로 expires_at 계산해야 정합; wall-clock 아님, 아래 impl 참조 — 리뷰 [2]).
fn handleControlRequest(
    server: *control_server_mod.ControlServer,
    refs: []const ControlSessionRef,
    pending: *control_server_mod.PendingRequest,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // 스냅샷은 dispatch 동안만 필요 — 응답(cross_gpa)은 arena와 독립
    const snapshot = collectSessionsInto(refs, arena.allocator()) catch {
        server.resolveRequest(pending, null); // collect OOM — 응답 없이 종료(accept 무한 대기 방지)
        return;
    };
    // now = 모노토닉 awake 초(TTL 판정 단위). wall-clock보다 clock 변경에 안전하고, 미래 fd 발급도 같은 시계로
    // expires_at을 계산하면 정합한다(코드베이스가 이미 std.Io.Clock.awake를 uptime에 씀). store가 빈 지금은 TTL 미사용.
    const now_ns: i128 = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    const disp = control_dispatch.dispatchAuthenticated(server.cross_gpa, pending.request_bytes, snapshot, pending.selector, pending.cap_nonce, &control_cap_store, now) catch {
        server.resolveRequest(pending, null);
        return;
    };
    switch (disp) {
        .immediate => |resp| server.resolveRequest(pending, resp),
        // 5e-2b: 인가·유효한 browser op — §5-async로 defer(즉시 resolve 안 함) + browser op 큐에 enqueue(Swift가 실행).
        .browser => |op| enqueueBrowserOp(server, pending, op, now_ns),
        // 5f-0b-3b: 인가·유효한 browser.subscribe — 메인에서 SubscriberRegistry에 **동기 등록** + `{subscriber_id}` 응답.
        .subscribe => |s| handleSubscribe(server, pending, s),
    }
}

/// 5f-0b-3b: 인가·유효한 `browser.subscribe`를 메인에서 즉시 처리한다(async 아님). 연결 outbound(pending에 실림)를
/// SubscriberRegistry에 등록하고 subscriber_id를 응답한다. outbound null(직접 구성 등 비정상)·registry OOM은 응답 없이
/// resolve(null)로 연결 종료(§5-async null 계약과 동형 — accept 무한 대기 방지). **메인 스레드 전용**(registry=leaf-mutex).
fn handleSubscribe(
    server: *control_server_mod.ControlServer,
    pending: *control_server_mod.PendingRequest,
    s: control_browser.BrowserSubscribe,
) void {
    const outbound = pending.outbound orelse return server.resolveRequest(pending, null); // 라이브는 serveConnection이 항상 세팅
    const subscriber_id = server.subscriber_reg.subscribe(s.surface_id, s.filter, outbound) catch
        return server.resolveRequest(pending, null); // registry OOM → null(연결 닫힘, 기존 관례)
    const resp = control_browser.serializeSubscribeResponse(server.cross_gpa, pending.request_bytes, subscriber_id) catch null;
    server.resolveRequest(pending, resp);
}

/// 5e-2b: 인가·유효한 browser op을 §5-async `deferRequest`(pending 붙잡음) + browser op 큐에 enqueue(Swift가 매 tick
/// take_browser_op으로 drain해 `BrowserControl` 실행 → complete_browser_op). deferRequest/큐 실패는 op.arg 해제 +
/// 에러 응답으로 즉시 resolve(누수·accept 무한 대기 방지). 성공 시 op.arg 소유권은 큐가 인수(take/deinit이 free).
fn enqueueBrowserOp(
    server: *control_server_mod.ControlServer,
    pending: *control_server_mod.PendingRequest,
    op: control_browser.BrowserOp,
    now_ns: i128,
) void {
    const async_id = server.deferRequest(pending, now_ns + browser_op_timeout_ns) catch {
        server.cross_gpa.free(op.arg);
        const resp = control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "browser op queue full") catch null;
        server.resolveRequest(pending, resp);
        return;
    };
    browser_op_queue.push(allocator, .{ .async_id = async_id, .surface_id = op.surface_id, .op_kind = @intFromEnum(op.method), .arg = op.arg }) catch {
        server.cross_gpa.free(op.arg);
        _ = server.completeInFlight(async_id, null); // deferred pending 취소(응답 없이 연결 닫힘)
    };
}

pub export fn maru_macos_control_server_start() c_int {
    // 비-macOS: 라이브 서버 없음(1b/A2b는 macOS 전용 — 소켓 부트스트랩이 fstatat/arc4random_buf 등 macOS syscall에
    // 의존). comptime-true 조기 반환이 뒤 macOS 바디(Server.bind·instanceNonce)를 linux 컴파일에서 prune한다
    // (live_pty.zig:298 선례). Linux/Win 이식 시 OS-중립 부트스트랩으로 대체.
    if (builtin.os.tag != .macos) return @intFromEnum(Status.create_failed);
    if (control_server_active) return @intFromEnum(Status.ok); // idempotent
    var base_buf: [1024]u8 = undefined;
    const base = controlBaseDir(&base_buf) orelse return @intFromEnum(Status.create_failed);
    // <base>(<cache>/maru) 존재 보장(Server.bind는 <base>/control만 mkdir). 부모(<cache>)도 best-effort mkdir.
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| {
        if (slash > 0) {
            base_buf[slash] = 0; // 부모 경로로 임시 절단
            _ = std.c.mkdir(@ptrCast(base_buf[0..slash].ptr), 0o700);
            base_buf[slash] = '/'; // 복원
        }
    }
    _ = std.c.mkdir(base.ptr, 0o700);

    var key_buf: [64]u8 = undefined;
    const key = control_socket.formatInstanceKey(&key_buf, std.c.getpid(), instanceNonce()) catch return @intFromEnum(Status.create_failed);

    control_server_storage.start(
        appHostIo(),
        allocator, // cross_gpa: smp_allocator는 thread-safe(요청/응답 cross-thread)
        allocator, // items/socket alloc
        base,
        key,
        control_hello_version,
        &control_hello_caps,
        16, // max_pending(5f-0b-2a 연결당 스레드로 최대 max_connections=16개 동시 push 가능 → queue 용량 = 그 이상)
    ) catch |e| {
        if (std.c.getenv("MARU_DEBUG") != null) std.debug.print("[maru control] start failed base={s} key={s} err={s}\n", .{ base, key, @errorName(e) });
        return @intFromEnum(Status.create_failed);
    };
    control_server_active = true;
    return @intFromEnum(Status.ok);
}

/// #4 값싼 per-tick 게이트: 대기 중인 컨트롤 요청이 하나라도 있으면 1, 없으면 0. Swift가 매 tick `drain` 전에 이걸 봐
/// pending이 없으면 refs 배열(힙 할당 + 창별 copy)을 **아예 짓지 않고** early return한다(렌더 핫패스 0-할당). 서버
/// 미시작이면 0. `take_bell` 등 predicate와 같은 u32(1/0) 패턴 — bool은 .h에 stdbool을 끌어들이고 codebase 관례와도
/// 어긋난다. (ABI 신규 export — 버전 bump 없음, drain과 동일 no-handle. 짧은 큐 락만 잡는다.)
pub export fn maru_macos_control_server_has_pending() u32 {
    if (!control_server_active) return 0;
    return if (control_server_storage.hasPendingRequest()) 1 else 0;
}

pub export fn maru_macos_control_server_drain(refs_ptr: ?[*]const ControlSessionRef, count: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const refs: []const ControlSessionRef = if (refs_ptr) |p| p[0..count] else &.{};
    var handled: usize = 0;
    while (handled < control_drain_budget) : (handled += 1) {
        const pending = server.tryPopRequest() orelse break;
        // 팝한 pending은 **반드시** resolve 또는 defer(browser op)해야 accept 스레드가 무한 대기하지 않는다.
        handleControlRequest(server, refs, pending);
    }
}

/// 5e-2b: Swift가 매 tick 호출 — (1) `reapExpiredInFlight`(hung browser op timeout), (2) browser op 큐에서 하나 pop해
/// out으로 넘긴다. 반환 1=op 있음(Swift가 surface_id로 webView 찾아 `BrowserControl`[op_kind] 실행 → 완료 시
/// `complete_browser_op`)·0=없음. `op_kind`: 0=navigate·1=getUrl·2=executeScript. `arg_ptr`는 안정 슬롯
/// (`browser_op_take_buf`)을 가리켜 **이 호출 중 동기 읽기**만 유효(다음 take가 덮어씀 — Swift가 즉시 복사). 서버
/// 미시작이면 0. **메인 스레드 전용**(reap·pop·in-flight 레지스트리는 메인).
pub export fn maru_macos_control_take_browser_op(
    out_async_id: ?*u64,
    out_surface_id: ?*u64,
    out_op_kind: ?*u8,
    out_arg_ptr: ?*?[*]const u8,
    out_arg_len: ?*usize,
) u32 {
    if (!control_server_active) return 0;
    const server = &control_server_storage;
    // §5-async reap: 매 tick hung op timeout(evaluateJavaScript/navigation이 안 끝나는 op가 accept를 영구 붙잡는 것 방어).
    _ = server.reapExpiredInFlight(std.Io.Clock.awake.now(appHostIo()).nanoseconds);
    const e = browser_op_queue.take() orelse return 0;
    // arg를 안정 슬롯에 복사(Swift가 이 호출 중 동기 읽음), 엔트리 arg(cross_gpa) 해제.
    browser_op_take_buf.clearRetainingCapacity();
    browser_op_take_buf.appendSlice(allocator, e.arg) catch {
        server.cross_gpa.free(e.arg); // 복사 OOM: op 드롭(pending은 reap-timeout으로 정리) — 0 반환
        return 0;
    };
    server.cross_gpa.free(e.arg);
    if (out_async_id) |p| p.* = e.async_id;
    if (out_surface_id) |p| p.* = e.surface_id;
    if (out_op_kind) |p| p.* = e.op_kind;
    if (out_arg_ptr) |p| p.* = if (browser_op_take_buf.items.len > 0) browser_op_take_buf.items.ptr else null;
    if (out_arg_len) |p| p.* = browser_op_take_buf.items.len;
    return 1;
}

/// 5e-2b: Swift `BrowserControl` async 완료 콜백이 호출 — `async_id`의 in-flight 요청을 결과로 응답한다. `status`:
/// 0=ok·非0=error(webView 부재·evaluateJavaScript 에러 등). `result`: method별(getUrl=url·executeScript=반환값
/// 문자열·navigate=무시; error면 message). 미지/reap된 async_id는 무시(늦은 콜백 — inFlightPending null). **메인 스레드
/// 전용**(WKWebView 콜백이 메인). serializeBrowserResponse가 pending.request_bytes 재파싱해 id·method로 응답 직렬화.
pub export fn maru_macos_control_complete_browser_op(async_id: u64, status: u32, result_ptr: ?[*]const u8, result_len: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const result: []const u8 = if (result_ptr) |p| p[0..result_len] else &.{};
    const pending = server.inFlightPending(async_id) orelse return; // 늦은/미지 콜백 — 무시
    const resp = control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, status == 0, result) catch null;
    _ = server.completeInFlight(async_id, resp); // found → resolve(resp)(accept 스레드가 write 후 free)
}

/// 5f-0b-3c: Swift가 WKWebView `url` KVO(메인 스레드)에서 호출 — 그 web surface의 `browser.navigated` 이벤트를 그 surface
/// 구독자들의 연결 outbound로 push한다(§9.5.2). 구독자 없으면 `pushEvent`가 match-first로 직렬화 없이 조기 반환(핫패스 무비용).
/// 서버 미시작이면 무동작. `url`은 이 호출 중만 유효(pushEvent가 프레임에 복사). **메인 스레드 전용**(KVO=메인; registry=leaf-mutex).
pub export fn maru_macos_control_push_browser_navigated(surface_id: u64, url_ptr: ?[*]const u8, url_len: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const url: []const u8 = if (url_ptr) |p| p[0..url_len] else "";
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .navigated = url });
}

/// 5f-3a: Swift가 WKWebView `isLoading` KVO(메인)에서 호출 — `browser.loadState` 이벤트(`loading`!=0 → loading, else idle)를
/// 구독자에 push. navigated와 동형(coalescible KVO 이벤트). 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_load_state(surface_id: u64, loading: u8) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .load_state = if (loading != 0) .loading else .idle });
}

/// 5f-3b: Swift `WKUIDelegate`(runJavaScript{Alert,Confirm,TextInput}Panel, 메인)에서 호출 — `browser.dialog` 이벤트
/// (`kind`: 0=alert·1=confirm·2=prompt, `message`=JS 다이얼로그 메시지)를 구독자에 push. 이산 이벤트(비-coalescible). `message`는
/// 이 호출 중만 유효(pushEvent가 복사). 미지 kind는 alert로 폴백. 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_dialog(surface_id: u64, kind: u8, message_ptr: ?[*]const u8, message_len: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const message: []const u8 = if (message_ptr) |p| p[0..message_len] else "";
    const dk: maru.session.control_events.DialogKind = switch (kind) {
        1 => .confirm,
        2 => .prompt,
        else => .alert,
    };
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .dialog = .{ .kind = dk, .message = message } });
}

/// 5f-3c: Swift `WKNavigationDelegate.webViewWebContentProcessDidTerminate`(메인)에서 호출 — `browser.crashed` 이벤트를
/// 구독자에 push(추가 payload 없음). 이산. 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_crashed(surface_id: u64) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .crashed);
}

/// 5f-3d: Swift가 web surface 소멸(패널 close) **직전**에 호출 — `browser.closed` 이벤트를 구독자에 push한 **뒤** 그 surface의
/// 구독을 정리한다(§9.5.2 surface close). closed는 마지막 프레임이라 큐에 남아 배달되고(제거 전 push), 이후 `purgeSurface`가
/// broker 구독 제거 + 잔여 이벤트 프레임 폐기(그 사이 push된 closed 프레임 포함될 수 있으나 outbound.close→writer drain이 배달).
/// 서버 미시작이면 무동작. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_closed(surface_id: u64) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .closed); // 마지막 closed 이벤트(구독 제거 전)
    _ = server.subscriber_reg.removeSurfaceSubs(surface_id); // 이후 그 surface 매칭 중단(broker만 — closed 프레임은 큐서 배달)
}

pub export fn maru_macos_control_server_stop() void {
    if (!control_server_active) return;
    control_server_active = false;
    control_server_storage.stop();
    // 5e-2b: 큐에 남은 browser op의 arg·안정 슬롯 해제. stop이 in-flight pending은 cancel하지만 큐 arg는 별도. arg는
    // dispatchAuthenticated가 cross_gpa로 dupe했고 cross_gpa==`allocator`(start가 그렇게 넘김)라 여기서 allocator로 free
    // (stop 후 control_server_storage.cross_gpa는 undefined라 접근 금지 — self.*=undefined).
    browser_op_queue.deinit(allocator, allocator);
    browser_op_queue = .{};
    browser_op_take_buf.deinit(allocator);
    browser_op_take_buf = .empty;
}

/// 5e-2b-2(**테스트 전용 훅**): env `MARU_TEST_BROWSER_CAP`이 설정됐을 때만 `surface_id`에 묶인 `browser` scope
/// capability를 라이브 `control_cap_store`에 발급하고 그 nonce(raw 32B)를 out으로 넘긴다. 실 fd 발급(1e-confirm)
/// 전이라 store가 비어 browser 요청이 default-deny인 상태에서, macos smoke가 소켓 `browser.navigate`(이 nonce)→실
/// WKWebView 이동을 자동 증명하게 하는 것이 유일한 목적이다. **프로덕션 무영향**: env 미설정이면 아무것도 안 하고 0을
/// 반환한다(호출자 Swift도 같은 env 게이트 뒤에서만 부른다 — 이중 게이트, capability 발급이라 방어적으로 Zig에도 게이트).
/// 발급은 §8.8대로 메인 스레드에서만(Swift tick). `generation`=0(collector가 web surface를 generation 0으로 방출 —
/// `app_session.collectSessionInto`; authz는 target id·cap.generation 앵커라 값 자체가 자기-정합). raw nonce는 store에
/// 저장 안 됨(hashNonce만). 반환 1=발급+nonce 채움, 0=env 미설정·out null·용량 부족·발급 실패. `out_nonce` 최소 32B.
pub export fn maru_macos_control_test_issue_browser_cap(surface_id: u64, out_nonce: ?[*]u8, out_nonce_cap: usize) u32 {
    if (std.c.getenv("MARU_TEST_BROWSER_CAP") == null) return 0; // env 게이트(테스트 전용 — 프로덕션 경로 무영향)
    const np = out_nonce orelse return 0;
    if (out_nonce_cap < control_capability.nonce_len) return 0;
    // 결정적 테스트 nonce(고정 바이트 파생). 실 crypto-random 생성은 1e-confirm 발급 경로 소유 — 이 훅은 smoke 왕복만.
    var nonce: control_capability.Nonce = undefined;
    for (&nonce, 0..) |*b, i| b.* = @intCast((i * 7 + 0x5e) & 0xff);
    control_cap_store.issueForFd(allocator, nonce, .{
        .surface_id = surface_id,
        .generation = 0,
        .scope = .browser,
    }) catch return 0; // validateFdIssuance(browser=allowed·TTL 불요) 통과가 정상 — OOM만 0
    @memcpy(np[0..control_capability.nonce_len], &nonce);
    return 1;
}

/// 5e-2b-2(**테스트 전용 훅**): 라이브 컨트롤 서버가 바인딩한 유닉스 소켓 경로를 out으로 복사하고 그 길이를 반환한다
/// (0=서버 미시작·out null·용량 부족). macos smoke의 인-프로세스 소켓 클라이언트가 자기 앱 소켓에 connect하는 데 쓴다
/// (경로는 비밀이 아님 — same-uid peer가 control dir을 열거 가능, §4.2). NUL 미포함 길이.
pub export fn maru_macos_control_socket_path(out: ?[*]u8, out_cap: usize) usize {
    if (!control_server_active) return 0;
    const p = out orelse return 0;
    const path = control_server_storage.server.socketPath(); // [:0]const u8
    if (path.len > out_cap) return 0;
    @memcpy(p[0..path.len], path);
    return path.len;
}

test "macOS app host ABI header and Zig declarations stay aligned" {
    // Swift는 C header를 보고, Zig는 이 파일의 extern struct를 쓴다. 둘의 숫자와
    // layout이 갈라지면 다음 제품 앱 PR에서 런타임 버그가 되므로 컴파일 단계에서 막는다.
    try std.testing.expectEqual(@as(u32, c.MARU_MACOS_APP_HOST_ABI_VERSION), abi_version);
    // url_at out_kind 계약: @intFromEnum(LinkKind)를 그대로 싣고 Swift handleUrlClick이 kind==1=file_path로 분기한다.
    // LinkKind 순서를 바꾸면 분기가 silent하게 뒤집히므로(웹↔파일) 태그 값을 고정한다(C typedef 없는 enum 가드 — Status/EventKind 선례).
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(terminal.LinkKind.url));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(terminal.LinkKind.file_path));
    // 5e-2b op_kind wire 계약: take_browser_op이 @intFromEnum(BrowserMethod)를 그대로 op_kind로 싣고 Swift
    // drainBrowserOps가 0=navigate·1=getUrl·2=executeScript로 디코드한다. BrowserMethod 순서를 바꾸면 op_kind가
    // silent하게 재매핑돼 navigate 요청이 getUrl/executeScript를 구동하므로(컴파일·테스트 무경보) 태그 값을 고정한다
    // (LinkKind 선례 — .h 주석·Swift switch와 단일 계약). 신규 메서드는 **끝에** 추가한다.
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @intFromEnum(control_browser.BrowserMethod.navigate)));
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @intFromEnum(control_browser.BrowserMethod.get_url)));
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @intFromEnum(control_browser.BrowserMethod.execute_script)));
    // workspace 헤더도 .h define과 Zig 단일 출처(session.workspace.header)가 갈라지면 저장/로드가 어긋나므로 고정.
    try std.testing.expectEqualStrings(c.MARU_WORKSPACE_HEADER, maru.session.workspace.header);
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusOk), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusNullOut), @intFromEnum(Status.null_out));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusInvalidConfig), @intFromEnum(Status.invalid_config));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusSessionEnded), @intFromEnum(Status.session_ended));
    // M3d-2b: cross-window 이동 거부 status(=10)를 Swift가 이 값으로 판정하므로 .h와 고정 정합(값 드리프트면 이동 실패를 성공으로 오독).
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusMoveFailed), @intFromEnum(Status.move_failed));
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
    // M3d-2b MoveResult(Swift가 이동/merge 결과를 이 layout으로 읽는다). 필드 타입이 달라 @sizeOf가 대부분의 reorder를
    // 잡지만, source_window_closed↔moved_count(둘 다 u32) 뒤바뀜은 못 잡으므로 @offsetOf로 세 필드 위치를 대조한다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMoveResult), @sizeOf(MoveResult));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMoveResult), @alignOf(MoveResult));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "status"), @offsetOf(MoveResult, "status"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "source_window_closed"), @offsetOf(MoveResult, "source_window_closed"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "moved_count"), @offsetOf(MoveResult, "moved_count"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostSessionConfig), @sizeOf(AppSessionConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostSessionConfig), @alignOf(AppSessionConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostQuickTerminalConfig), @sizeOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostQuickTerminalConfig), @alignOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostQuickTerminalFrames), @sizeOf(session_mod.QuickTerminalFrames));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostQuickTerminalFrames), @alignOf(session_mod.QuickTerminalFrames));
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
    // A2b ControlSessionRef ABI 정합(Swift가 창마다 채워 drain에 넘긴다). offsetOf로 필드 위치까지 대조.
    try std.testing.expectEqual(@sizeOf(c.MaruControlSessionRef), @sizeOf(ControlSessionRef));
    try std.testing.expectEqual(@alignOf(c.MaruControlSessionRef), @alignOf(ControlSessionRef));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "app_session"), @offsetOf(ControlSessionRef, "app_session"));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "window_id"), @offsetOf(ControlSessionRef, "window_id"));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "window_kind"), @offsetOf(ControlSessionRef, "window_kind"));
    // GlobalHotkey ABI 정합(전역 단축키 enumerate가 out_ptr로 노출) — 이전엔 대조가 통째로 빠져 있었다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGlobalHotkey), @sizeOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGlobalHotkey), @alignOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostFrameSummary), @sizeOf(AppFrameSummary));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostFrameSummary), @alignOf(AppFrameSummary));
    // v102(4e-5): web_surfaces_present는 quit_decision 뒤 4B tail padding을 채워 @sizeOf가 176으로 불변이라 필드 존재를
    // 못 강제한다 — offset을 C↔Zig 대조해 패딩 자리에 정확히 들어갔는지(위치 정합) 고정한다(GpuQuad 동일-폭 필드 선례).
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostFrameSummary, "web_surfaces_present"), @offsetOf(AppFrameSummary, "web_surfaces_present"));
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
    // v99 Phase 4c: 웹 패널 surface 전이 struct — mixed-width(u32/u64/f64)라 @sizeOf만으론 필드 reorder를 못 잡으므로
    // 모든 필드 offset을 C↔Zig 대조한다(surface_id↔frame_pt 뒤바뀌면 Swift가 엉뚱한 frame을 읽는다).
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostWebSurfaceTransition), @sizeOf(WebSurfaceTransitionAbi));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostWebSurfaceTransition), @alignOf(WebSurfaceTransitionAbi));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "op"), @offsetOf(WebSurfaceTransitionAbi, "op"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "visible"), @offsetOf(WebSurfaceTransitionAbi, "visible"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "surface_id"), @offsetOf(WebSurfaceTransitionAbi, "surface_id"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "panel_kind"), @offsetOf(WebSurfaceTransitionAbi, "panel_kind"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "seam_edges"), @offsetOf(WebSurfaceTransitionAbi, "seam_edges")); // v103: panel_kind 뒤 pad 자리(size 불변)
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_x"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_y"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_y"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_w"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_w"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_h"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_h"));
    // op enum 값(C ↔ session_mod.WebSurfaceOp) 정합 — Swift switch가 이 정수로 분기하므로 값이 어긋나면 안 된다.
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpNone), @intFromEnum(session_mod.WebSurfaceOp.none));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpCreate), @intFromEnum(session_mod.WebSurfaceOp.create));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpDestroy), @intFromEnum(session_mod.WebSurfaceOp.destroy));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpReframe), @intFromEnum(session_mod.WebSurfaceOp.reframe));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpHide), @intFromEnum(session_mod.WebSurfaceOp.hide));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpShow), @intFromEnum(session_mod.WebSurfaceOp.show));
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
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(AppFrameSummary)); // quit_decision(u32,v90)+web_surfaces_present(u32,v102)가 168→176 정렬 패딩을 채워 176 불변
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
        maru_macos_app_session_tick(null, maru.config.theme.render_frame_rate_default, null),
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
    // M3f workspace_window_frame: null session·null out 포인터는 -1(조용한 폴백 = count/active-window와 동형, Status가
    // 아니라 present/absent/fail의 정수 신호). Swift는 -1/0을 "frame 없음 → 현행 기본"으로 동일 처리한다.
    try std.testing.expectEqual(@as(c_int, -1), maru_macos_app_session_workspace_window_frame(null, null, 0, 0, null, null, null, null));
    // v106 Phase 7e-3 take_web_nav_action: null session·null out-ptr는 -1(신호 없음/유실 방지 — take_web_addr_navigate 동형).
    try std.testing.expectEqual(@as(i32, -1), maru_macos_app_session_take_web_nav_action(null, null));
    var nav_action_sid: u64 = 0;
    try std.testing.expectEqual(@as(i32, -1), maru_macos_app_session_take_web_nav_action(null, &nav_action_sid));
    // v107 Phase 7e-4 browser_nav: null session은 0(무동작). 알 수 없는 code(3)도 0 — 세션 있어도 매핑 안 되면 무동작이나
    // 여기선 null session이 먼저라 0. (활성 판정·pending 세움은 코어 setBrowserNavAction 헤드리스 테스트가 덮는다.)
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_session_browser_nav(null, 42, 0));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_session_browser_nav(null, 42, 3));
    // v108 Phase 7e-4 후속 active_web_surface_id: null session은 0(browser 아님 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_active_web_surface_id(null));
    // v112 Phase 4g-0 active_web_surface_id_any_kind: null session은 0(web 아님 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_active_web_surface_id_any_kind(null));
    // v114 Phase 4g-1 후속 terminal_owns_input: null session은 0.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_terminal_owns_input(null));
    // v109 Phase 7f-0 create_adopted_web_term: null session은 0(생성 실패 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_create_adopted_web_term(null));
    // v111 Phase 7f-2 popup_target_allowed: null url_ptr는 -1(정책 판정 전 방어). 실 정책은 app_scheme 헤드리스 테스트.
    try std.testing.expectEqual(@as(c_int, -1), maru_macos_app_popup_target_allowed(null, 5));
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

// 5e-2b: BrowserOpQueue FIFO push/take + bounded + deinit(남은 arg 해제). arg 소유권 이전 규약을 testing.allocator로
// 검증(누수/이중free 없음). ABI take/complete_browser_op 글루·handleControlRequest defer는 5e-2b-2 macos smoke가 e2e로.
test "5e-2b BrowserOpQueue: FIFO push/take + bounded(Full) + deinit이 남은 arg 해제" {
    const gpa = std.testing.allocator;
    var q: BrowserOpQueue = .{ .max = 2 };
    // push 2개(각 arg는 gpa 소유 — 큐가 인수).
    try q.push(gpa, .{ .async_id = 1, .surface_id = 10, .op_kind = 0, .arg = try gpa.dupe(u8, "https://a") });
    try q.push(gpa, .{ .async_id = 2, .surface_id = 11, .op_kind = 2, .arg = try gpa.dupe(u8, "1+1") });
    // 3번째는 bounded → Full(호출자가 arg free 책임 — 여기선 dupe 안 하고 바로 검사).
    try std.testing.expectError(error.Full, q.push(gpa, .{ .async_id = 3, .surface_id = 12, .op_kind = 1, .arg = "" }));
    // FIFO take: 1번 먼저. arg 소유권 이전 → 호출자 free.
    const e1 = q.take().?;
    try std.testing.expectEqual(@as(u64, 1), e1.async_id);
    try std.testing.expectEqual(@as(u8, 0), e1.op_kind);
    try std.testing.expectEqualStrings("https://a", e1.arg);
    gpa.free(e1.arg);
    // 남은 1개(async_id 2)는 deinit이 arg 해제(누수 없음 — testing.allocator가 잡음).
    q.deinit(gpa, gpa);
}
